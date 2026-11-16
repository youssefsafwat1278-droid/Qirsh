import 'dart:async';

import '../../engine/intelligence/merchant_intelligence_store.dart';
import '../repositories/merchant_category_repository.dart';

/// The Settings "Learned rules" list: only rules the user confirmed, with
/// delete and undo. The persisted map stays the source of truth; the on-device
/// model is kept in step after each successful write (OD-13 — it only ever
/// mirrors the user's choices, it never writes a rule itself).
class LearnedRulesUseCase {
  LearnedRulesUseCase({
    required MerchantCategoryRepository merchantCategoryRepository,
    MerchantIntelligenceStore? merchantIntelligence,
    Future<void> Function(String rawMerchant)? withdrawSharedRule,
  })  : _repository = merchantCategoryRepository,
        _merchantIntelligence = merchantIntelligence,
        _withdrawSharedRule = withdrawSharedRule;

  final MerchantCategoryRepository _repository;
  final MerchantIntelligenceStore? _merchantIntelligence;

  /// Takes back the shared-learning vote this rule may have made. Fired and
  /// not awaited: the local delete never waits on, or fails with, the network.
  final Future<void> Function(String rawMerchant)? _withdrawSharedRule;

  Future<List<LearnedMerchantRule>> list() =>
      _repository.getUserConfirmedRules();

  Future<void> delete(LearnedMerchantRule rule) async {
    await _repository.forgetUserConfirmedRule(rule.rawMerchant);
    _merchantIntelligence?.forgetUserCorrection(rule.rawMerchant);
    final withdraw = _withdrawSharedRule;
    if (withdraw != null) {
      unawaited(
          Future(() => withdraw(rule.rawMerchant)).catchError((Object _) {}));
    }
  }

  /// Undo of [delete]: puts the same user-confirmed rule back. It does not
  /// re-share: the vote stays withdrawn until the user confirms it again.
  Future<void> restore(LearnedMerchantRule rule) async {
    await _repository.confirmMerchantCategory(
      rawMerchant: rule.rawMerchant,
      categoryKey: rule.categoryKey,
      isUserConfirmed: true,
    );
    _merchantIntelligence?.learnFromUserCorrection(
        rule.rawMerchant, rule.categoryKey);
  }
}
