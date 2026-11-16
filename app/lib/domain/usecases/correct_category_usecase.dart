import 'dart:async';

import '../../engine/categorization/categorizer.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/intelligence/merchant_intelligence_store.dart';
import '../entities/engagement_entities.dart';
import '../entities/transaction_entity.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/transaction_repository.dart';
import 'engagement_usecase.dart';

/// OD-13: the default is [thisTransactionOnly] — a one-off that teaches
/// nothing. [allMerchantTransactions] is the explicit "remember for this
/// merchant" choice: it saves a user-confirmed merchant rule that future
/// captures of the same normalised merchant follow.
enum CategoryCorrectionScope { thisTransactionOnly, allMerchantTransactions }

/// Why "also update past transactions" leaves a transaction alone.
enum PastUpdateExclusion {
  /// The user picked this category by hand. Changed only with
  /// [PastUpdateOverrides.includeChosenByYou].
  chosenByYou,

  /// Nobody can say who chose it (older history, an older app version).
  /// Changed only with [PastUpdateOverrides.includeUnknown].
  unknownOrigin,

  /// Ignored transactions are never re-categorised.
  ignored,

  /// Added by hand. Never re-categorised in bulk.
  manual,

  /// Came in through a file import ([TransactionEntity.importedFromFile]).
  /// Changed only with [PastUpdateOverrides.includeImported] — never by
  /// [PastUpdateOverrides.includeUnknown].
  imported,

  /// Its type fixes the category (a cash withdrawal is always "cash", a
  /// transfer "transfers", income "income"), so a write could not change it.
  /// Counting it as eligible would promise a change that never happens and
  /// keep reappearing on every repeat. Never re-categorised in bulk: change
  /// the transaction's type first.
  typeLocked,
}

/// Types whose category the repository forces regardless of the requested
/// key (see `DriftTransactionRepository._categoryKeyForType`).
const kCategoryLockedTransactionTypes = {
  TransactionTypeEntity.withdrawal,
  TransactionTypeEntity.transfer,
  TransactionTypeEntity.income,
};

/// Explicit, separate opt-ins, all off by default. Ignored and manual rows
/// have no override at all.
class PastUpdateOverrides {
  const PastUpdateOverrides({
    this.includeUnknown = false,
    this.includeChosenByYou = false,
    this.includeImported = false,
  });

  final bool includeUnknown;
  final bool includeChosenByYou;

  /// Imported rows whose category was not picked by hand. A hand-picked one
  /// still needs [includeChosenByYou] as well.
  final bool includeImported;
}

/// What "also update past transactions" would do — computed by the same code
/// that applies it, so the preview and the result cannot disagree.
class PastCategoryUpdatePlan {
  const PastCategoryUpdatePlan({
    required this.eligible,
    required this.excluded,
    required this.alreadyInCategory,
  });

  static const empty =
      PastCategoryUpdatePlan(eligible: [], excluded: {}, alreadyInCategory: 0);

  final List<TransactionEntity> eligible;
  final Map<PastUpdateExclusion, List<TransactionEntity>> excluded;

  /// Same merchant and already in the chosen category: nothing to do.
  final int alreadyInCategory;

  int excludedCount(PastUpdateExclusion reason) =>
      excluded[reason]?.length ?? 0;

  int get totalExcluded =>
      excluded.values.fold(0, (sum, rows) => sum + rows.length);
}

/// Sorts [candidates] for a bulk change to [categoryId]. The first matching
/// reason wins, in the order below, so a row is counted exactly once.
PastCategoryUpdatePlan planPastCategoryUpdate(
  List<TransactionEntity> candidates,
  String categoryId, {
  PastUpdateOverrides overrides = const PastUpdateOverrides(),
}) {
  final eligible = <TransactionEntity>[];
  final excluded = <PastUpdateExclusion, List<TransactionEntity>>{};
  var already = 0;
  void exclude(PastUpdateExclusion r, TransactionEntity t) =>
      (excluded[r] ??= []).add(t);
  for (final t in candidates) {
    if (t.categoryId == categoryId) {
      already++;
    } else if (kCategoryLockedTransactionTypes.contains(t.type)) {
      exclude(PastUpdateExclusion.typeLocked, t);
    } else if (t.status == TransactionStatus.ignored) {
      exclude(PastUpdateExclusion.ignored, t);
    } else if (t.source == TransactionSourceEntity.unknown) {
      exclude(PastUpdateExclusion.manual, t);
    } else if (t.importedFromFile ||
        t.source == TransactionSourceEntity.imported) {
      if (!overrides.includeImported) {
        exclude(PastUpdateExclusion.imported, t);
      } else if (t.categoryProvenance == CategoryProvenance.user &&
          !overrides.includeChosenByYou) {
        exclude(PastUpdateExclusion.chosenByYou, t);
      } else {
        eligible.add(t);
      }
    } else {
      switch (t.categoryProvenance ?? CategoryProvenance.unknown) {
        case CategoryProvenance.auto:
        case CategoryProvenance.rule:
          eligible.add(t);
        case CategoryProvenance.user:
          overrides.includeChosenByYou
              ? eligible.add(t)
              : exclude(PastUpdateExclusion.chosenByYou, t);
        case CategoryProvenance.unknown:
          overrides.includeUnknown
              ? eligible.add(t)
              : exclude(PastUpdateExclusion.unknownOrigin, t);
      }
    }
  }
  return PastCategoryUpdatePlan(
      eligible: eligible, excluded: excluded, alreadyInCategory: already);
}

class CorrectCategoryUseCase {
  CorrectCategoryUseCase({
    required TransactionRepository transactionRepository,
    required MerchantCategoryRepository merchantCategoryRepository,
    this.recordEngagementUseCase,
    // OD-13: the on-device model that should learn from this correction.
    // Optional — when absent the correction still persists exactly as before,
    // so the model is never load-bearing for a user action.
    MerchantIntelligenceStore? merchantIntelligence,
    // Shared category learning: offered ONLY a rule the user just confirmed.
    // The receiver decides eligibility and consent; it is never awaited, so a
    // slow or failing network never delays or breaks the user's correction.
    Future<void> Function(TransactionEntity transaction, String categoryKey)?
        offerSharedRule,
  })  : _transactionRepository = transactionRepository,
        _merchantCategoryRepository = merchantCategoryRepository,
        _merchantIntelligence = merchantIntelligence,
        _offerSharedRule = offerSharedRule;

  final TransactionRepository _transactionRepository;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final MerchantIntelligenceStore? _merchantIntelligence;
  final Future<void> Function(TransactionEntity, String)? _offerSharedRule;
  final RecordEngagementUseCase? recordEngagementUseCase;

  Future<TransactionEntity> call({
    required String transactionId,
    required String categoryKey,
    required CategoryCorrectionScope scope,
    // Only honoured with "remember": also re-categorise this merchant's past
    // transactions per [planPastCategoryUpdate]. Hand-picked and unknown-origin
    // ones change only through their explicit [overrides].
    bool alsoUpdatePast = false,
    PastUpdateOverrides overrides = const PastUpdateOverrides(),
  }) async {
    final before = await _transactionRepository.getById(transactionId);
    final updated = await _transactionRepository.updateCategory(
      transactionId: transactionId,
      categoryKey: categoryKey,
    );
    final rowChanged = before == null ||
        before.categoryId != updated.categoryId ||
        before.categoryProvenance != updated.categoryProvenance ||
        before.status != updated.status;
    var ruleChanged = false;

    if (scope == CategoryCorrectionScope.allMerchantTransactions &&
        updated.rawMerchant != null) {
      ruleChanged = await _merchantCategoryRepository
              .userConfirmedCategoryFor(updated.rawMerchant!) !=
          categoryKey;
    }
    if (ruleChanged) {
      final learnedMap =
          await _merchantCategoryRepository.getLearnedCategoryMap();
      final categorizer = Categorizer(map: MerchantCategoryMap(learnedMap));
      categorizer.confirmMerchant(updated.rawMerchant!, categoryKey);
      await _merchantCategoryRepository.confirmMerchantCategory(
        rawMerchant: updated.rawMerchant!,
        categoryKey: categoryKey,
        isUserConfirmed: true,
      );
      // OD-13 — the ONLY place the on-device model learns.
      //
      // Deliberately confined to `allMerchantTransactions`: that scope IS the
      // user saying "this merchant means this category". `thisTransactionOnly`
      // is the user saying the opposite — a one-off — so teaching the model
      // from it would contradict the choice they just made.
      //
      // Ordering matters: the durable write above is the source of truth, and
      // the in-memory model is updated only after it succeeds. If the write
      // throws, the model is not taught something that was never persisted.
      _merchantIntelligence?.learnFromUserCorrection(
        updated.rawMerchant!,
        categoryKey,
      );
      final offer = _offerSharedRule;
      if (offer != null) {
        unawaited(offer(updated, categoryKey).catchError((Object _) {}));
      }

    }

    var pastChanged = 0;
    // The target id comes from the key exactly as in [previewPastUpdate], so
    // what is applied is what was shown.
    final targetCategoryId =
        scope == CategoryCorrectionScope.allMerchantTransactions &&
                alsoUpdatePast &&
                updated.rawMerchant != null
            ? await _transactionRepository.categoryIdForKey(categoryKey)
            : null;
    if (targetCategoryId != null) {
      // Through the same repository write as a single edit, one row at a
      // time, so every change is enqueued for sync exactly like a normal
      // category edit — never a bulk SQL update that skips the outbox. Rows
      // already in the category are skipped, so a repeat run changes nothing.
      final plan = planPastCategoryUpdate(
        await _transactionRepository.sameMerchantTransactions(
          rawMerchant: updated.rawMerchant!,
          excludeTransactionId: updated.id,
        ),
        targetCategoryId,
        overrides: overrides,
      );
      for (final tx in plan.eligible) {
        await _transactionRepository.updateCategory(
          transactionId: tx.id,
          categoryKey: categoryKey,
          appliedByRule: true,
        );
        pastChanged++;
      }
    }

    // Nothing changed (a repeat of the same choice): no correction feedback.
    if (recordEngagementUseCase != null &&
        (rowChanged || ruleChanged || pastChanged > 0)) {
      await recordEngagementUseCase!(
        action: EngagementAction.categoryCorrected,
        occurredAt: updated.updatedAt,
      );
    }

    return updated;
  }

  /// What "also update past transactions" would change for [transaction] →
  /// [categoryKey], and what it would leave alone and why. Shown to the user
  /// before applying; [call] applies exactly this plan.
  Future<PastCategoryUpdatePlan> previewPastUpdate({
    required TransactionEntity transaction,
    required String categoryKey,
    PastUpdateOverrides overrides = const PastUpdateOverrides(),
  }) async {
    final merchant = transaction.rawMerchant;
    if (merchant == null) return PastCategoryUpdatePlan.empty;
    final categoryId =
        await _transactionRepository.categoryIdForKey(categoryKey);
    if (categoryId == null) return PastCategoryUpdatePlan.empty;
    return planPastCategoryUpdate(
      await _transactionRepository.sameMerchantTransactions(
        rawMerchant: merchant,
        excludeTransactionId: transaction.id,
      ),
      categoryId,
      overrides: overrides,
    );
  }
}
