import '../../core/utils/id_generator.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../engine/ai/ai_candidate_validator.dart';
import '../../engine/ai/ai_parser_client.dart';
import '../../engine/ai/ai_sender_failure_tracker.dart';
import '../../engine/categorization/category.dart';
import '../../engine/categorization/categorizer.dart';
import '../../engine/intelligence/merchant_intelligence_store.dart';
import '../../engine/categorization/merchant_category_map.dart';
import '../../engine/dedup/transaction_dedup.dart';
import '../../engine/models/parsed_transaction.dart';
import '../../engine/models/transaction_source.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/bank_profile.dart';
import '../../engine/parser/catalog_rule_matcher.dart';
import '../../engine/parser/payment_aggregators.dart';
import '../../engine/parser/bank_sender_filter.dart';
import '../../data/db/ownership_guard.dart' show StaleOwnershipException;
import '../../data/db/planning_cutover.dart';
import '../../engine/parser/capture_money.dart';
import '../../engine/parser/direction_signal.dart';
import '../../engine/parser/local_validity.dart';
import '../../engine/parser/parser_engine.dart';
import '../../engine/parser/parser_isolate.dart';
import '../../engine/parser/parse_result.dart';
import '../../engine/parser/transaction_timestamp_extractor.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../entities/account_entity.dart';
import '../entities/engagement_entities.dart';
import '../entities/suspected_duplicate_entity.dart';
import '../entities/transaction_entity.dart';
import '../finance/money.dart';
import '../finance/money_input.dart';
import '../entities/bank_discovery_models.dart';
import '../repositories/account_repository.dart';
import '../repositories/dedup_store.dart';
import '../repositories/merchant_category_repository.dart';
import '../repositories/sender_bank_mapping_repository.dart';
import '../repositories/suspected_duplicate_repository.dart';
import '../repositories/transaction_repository.dart';
import '../services/bank_discovery_service.dart';
import 'engagement_usecase.dart';
import 'resolve_bank_for_sender_usecase.dart';
import '../capture/proof_proposal_builder.dart';
import '../../engine/proof/evidence.dart';
import '../../engine/proof/proof_checker.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../capture/proof_shadow_record.dart';
import '../capture/proof_commit_gate.dart';
import 'capture_commit_decision.dart';

/// Identity and atomic-persistence contract for a capture that carries a stable
/// payload id (I-3 / I-5).
///
/// Every row the ingest persists for the capture gets an id derived from
/// [captureId]: the primary transaction is exactly [captureId], the fee/tax
/// line is `<captureId>:fee`. The rows, their ledger outbox rows and the
/// payload receipt ([writeReceipt]) commit in ONE [runAtomically] transaction
/// that holds no network call: parsing, AI and enrichment finish before it.
///
/// [captureId] is PROOF of identity: a capture whose id already has a
/// transaction (`tx.id == captureId`) or a receipt ([readReceipt]) is a
/// redelivery of the same capture and is never committed a second time — not
/// before parsing, not inside the commit transaction, and not after losing a
/// commit race to another connection (a background engine draining the same
/// file). Such a redelivery yields one transaction and no review noise.
class CaptureCommit {
  const CaptureCommit({
    required this.captureId,
    required this.runAtomically,
    required this.writeReceipt,
    this.readReceipt,
  });

  final String captureId;
  final Future<void> Function(Future<void> Function() action) runAtomically;

  /// Writes `capture_payload:<captureId>` -> [transactionId].
  final Future<void> Function(String transactionId) writeReceipt;

  /// What `capture_payload:<captureId>` durably points at (a transaction id
  /// or a `smart_inbox:`/`ignored` marker), or null when there is no durable
  /// receipt. Absent => only `tx.id == captureId` proves a redelivery.
  final Future<String?> Function()? readReceipt;

  String get feeId => '$captureId:fee';
}

class AddTransactionResult {
  const AddTransactionResult._({
    required this.outcome,
    this.transaction,
    this.parseResult,
    this.isNewMerchant = false,
    this.droppedByParser = false,
    this.aiFailureReason,
    this.secondary,
    this.suspectedDuplicateId,
    this.duplicateReason,
  });

  const AddTransactionResult.added(
      TransactionEntity transaction, ParseResult parseResult,
      {bool isNewMerchant = false,
      AddTransactionResult? secondary,
      String? aiFailureReason})
      : this._(
          outcome: AddTransactionOutcome.added,
          transaction: transaction,
          parseResult: parseResult,
          isNewMerchant: isNewMerchant,
          secondary: secondary,
          aiFailureReason: aiFailureReason,
        );

  const AddTransactionResult.duplicate(TransactionEntity transaction,
      {AddTransactionResult? secondary})
      : this._(
          outcome: AddTransactionOutcome.duplicate,
          transaction: transaction,
          secondary: secondary,
        );

  const AddTransactionResult.suspiciousDuplicate(
    TransactionEntity transaction, {
    String? suspectedDuplicateId,
    String? duplicateReason,
  }) : this._(
          outcome: AddTransactionOutcome.suspiciousDuplicate,
          transaction: transaction,
          suspectedDuplicateId: suspectedDuplicateId,
          duplicateReason: duplicateReason,
        );

  const AddTransactionResult.notTransaction(ParseResult parseResult,
      {bool droppedByParser = false, String? aiFailureReason})
      : this._(
          outcome: AddTransactionOutcome.notTransaction,
          parseResult: parseResult,
          droppedByParser: droppedByParser,
          aiFailureReason: aiFailureReason,
        );

  final AddTransactionOutcome outcome;
  final TransactionEntity? transaction;
  final ParseResult? parseResult;
  final bool isNewMerchant;

  /// True when a bank-like message was not OTP/promo but couldn't be parsed.
  final bool droppedByParser;
  final String? aiFailureReason;
  final String? suspectedDuplicateId;
  final String? duplicateReason;

  /// A second transaction extracted from the same SMS — currently a fee/tax
  /// line charged in a different currency than the main amount. Null when the
  /// message holds a single operation.
  final AddTransactionResult? secondary;

  bool get requiresConfirmation {
    if (outcome != AddTransactionOutcome.added || transaction == null) {
      return false;
    }
    return transaction!.status == TransactionStatus.pending || isNewMerchant;
  }
}

enum AddTransactionOutcome {
  added,
  duplicate,
  suspiciousDuplicate,
  notTransaction,
}

class _AiFirstAttempt {
  const _AiFirstAttempt({
    required this.senderId,
    this.sanitizedSms,
    this.response,
    this.failureReason,
  });

  const _AiFirstAttempt.skipped([String? reason])
      : senderId = '',
        sanitizedSms = null,
        response = null,
        failureReason = reason;

  final String senderId;
  final String? sanitizedSms;
  final AiParseResponse? response;
  final String? failureReason;
}

class _AppliedAiParse {
  const _AppliedAiParse({
    required this.transaction,
    required this.categoryKey,
    required this.direction,
  });

  final ParsedTransaction transaction;
  final String? categoryKey;
  final TransactionDirectionEntity? direction;
}

class _CaptureMoneyResolution {
  const _CaptureMoneyResolution(this.money, {required this.legacyLossy});
  final Money money;
  final bool legacyLossy;
}

class _NullableCaptureMoneyResolution {
  const _NullableCaptureMoneyResolution(this.money,
      {required this.legacyLossy});
  final Money? money;
  final bool legacyLossy;
}

_CaptureMoneyResolution _captureMoney({
  required String? exactText,
  required double heuristicValue,
  required String currency,
}) {
  if (exactText != null) {
    try {
      return _CaptureMoneyResolution(parseCaptureMoney(exactText, currency),
          legacyLossy: false);
    } on Exception {
      // LEGACY_LOSSY capture fallback (pending review): never silently round a
      // rejected exact bank token into a confirmed transaction.
    }
  }
  return _CaptureMoneyResolution(
      legacyLossyNumberToMoney(heuristicValue, currency),
      legacyLossy: true);
}

_NullableCaptureMoneyResolution _captureMoneyOrNull({
  required String? exactText,
  required double? heuristicValue,
  required String currency,
}) {
  if (exactText == null && heuristicValue == null) {
    return const _NullableCaptureMoneyResolution(null, legacyLossy: false);
  }
  final resolved = _captureMoney(
      exactText: exactText,
      heuristicValue: heuristicValue ?? 0,
      currency: currency);
  return _NullableCaptureMoneyResolution(resolved.money,
      legacyLossy: resolved.legacyLossy);
}

Future<AccountEntity?> _accountForCurrency(
  AccountRepository? repository,
  String currency, {
  AccountEntity? fallback,
}) async {
  final normalized = currency.trim().toUpperCase();
  if (normalized.isEmpty) return fallback;
  if (fallback != null && fallback.currency.toUpperCase() == normalized) {
    return fallback;
  }
  if (repository == null) return fallback;

  final accounts = await repository.getAll();
  for (final account in accounts) {
    if (account.currency.toUpperCase() == normalized) {
      return account;
    }
  }

  final now = DateTime.now().toUtc();
  return repository.create(
    AccountEntity(
      id: '',
      name: 'حساب $normalized',
      currency: normalized,
      type: AccountType.bank,
      isDefault: accounts.isEmpty,
      sortOrder: accounts.length,
      createdAt: now,
      updatedAt: now,
    ),
  );
}

/// يطابق رقم الحساب المُستخرَج من الرسالة مع bank_account_number لحساب موجود.
/// أولوية أعلى من مطابقة العملة، لكن لا يُنشئ حسابًا أبدًا (يعيد null لو لا مطابقة).
/// المطابقة: تطابق تام، أو تطابق لاحقة (لأرقام مُقنّعة/جزئية) بطول 4+ خانات.
Future<AccountEntity?> _accountByNumber(
  AccountRepository? repository,
  String? parsedAccountNumber, {
  List<AccountEntity>? accounts,
}) async {
  if (repository == null) return null;
  final needle = parsedAccountNumber?.replaceAll(RegExp(r'[^0-9]'), '');
  if (needle == null || needle.length < 4) return null;
  final list = accounts ?? await repository.getAll();
  AccountEntity? suffixMatch;
  for (final account in list) {
    final stored = account.bankAccountNumber?.replaceAll(RegExp(r'[^0-9]'), '');
    if (stored == null || stored.length < 4) continue;
    if (stored == needle) return account; // تطابق تام له الأولوية.
    final shorter = stored.length <= needle.length ? stored : needle;
    final longer = stored.length <= needle.length ? needle : stored;
    if (shorter.length >= 4 && longer.endsWith(shorter)) {
      suffixMatch ??= account;
    }
  }
  return suffixMatch;
}

/// What one Proof evaluation produced, carried from the gate to the recorder so
/// the observation can be persisted AFTER the transaction id exists.
class _ProofGateEvaluation {
  const _ProofGateEvaluation({
    required this.decision,
    required this.proof,
    required this.refusal,
    required this.parsedDirection,
    required this.parsedAmountCanonical,
  });

  final ProofGateDecision decision;
  final ProofResult? proof;
  final ProofProposalRefusal? refusal;
  final String? parsedDirection;
  final String? parsedAmountCanonical;
}

class AddTransactionUseCase {
  AddTransactionUseCase({
    required TransactionRepository transactionRepository,
    required MerchantCategoryRepository merchantCategoryRepository,
    ParserIsolate? parserIsolate,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
    // PHASE 11. Injected, never read from a global: the domain layer stays
    // flag-free, and a test can exercise armed mode without touching runtime
    // flag state. Defaults keep Proof inert for every existing caller.
    ProofGateMode Function()? proofGateMode,
    int Function()? proofParserConfidenceMinPermille,
    void Function(ProofShadowRecord record)? recordProofShadow,
    Future<List<BankProfile>> Function({String? senderId})? loadBankProfiles,
    Future<List<CatalogParserRule>> Function(String? senderId)?
        loadCatalogRules,
    Future<List<RemoteMerchantKeyword>> Function()? loadRemoteKeywords,
    Future<void> Function(String normalizedMerchant)? noteMerchantFeedback,
    Future<String?> Function(String normalizedMerchant)?
        resolveMerchantCategory,
    // Merchant enrichment sends a name derived from a financial message to the
    // cloud, so it needs FRESH cloud consent. Absent or throwing = no enrichment.
    Future<bool> Function()? mayEnrichMerchant,
    AccountRepository? accountRepository,
    DedupStore? dedupStore,
    AiParserClient? aiClient,
    Future<bool> Function()? loadAiConsent,
    Future<bool> Function()? aiPrimarySelected,
    // F9: an earlier capture of the SAME message text (see the call site).
    // Absent => only the exact-timestamp duplicate check runs.
    Future<TransactionEntity?> Function({
      required String rawMessage,
      required Money amount,
      required String currency,
      required DateTime comparisonTimestamp,
    })? findSameTextCapture,
    String? installId,
    Future<String> Function()? loadInstallId,
    ResolveBankForSenderUseCase? resolveBankForSenderUseCase,
    BankDiscoveryService? bankDiscoveryService,
    SuspectedDuplicateRepository? suspectedDuplicateRepository,
    // MALI-026 (B8-2.10 §12): money-authority mode; defaults to legacy so v29
    // add/AI ingestion is unchanged. Canonical mode forces a non-exact capture
    // to pending review (never auto-confirmed into canonical authority).
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    // OD-13 lifecycle fix: ONE long-lived model, not one per categorizer per
    // transaction. Optional so every existing construction site (and every
    // test) keeps working unchanged; when omitted this instance owns its own,
    // which still collapses the previous two constructions per call into one.
    MerchantIntelligenceStore? merchantIntelligence,
    // `local_auto_confirm_v2`: binary local acceptance (valid => confirmed,
    // invalid => "local produced no transaction"). Injected so the domain layer
    // stays flag-free; absent or throwing fails CLOSED (legacy behaviour).
    bool Function()? isLocalAutoConfirmV2,
    // `ai_sender_mapping_auto`: persist a sender->bank mapping after a
    // validated AI capture matched exactly one catalog bank. Injected and
    // fail-closed: absent, throwing or non-true means nothing is persisted.
    SenderBankMappingRepository? senderBankMappingRepository,
    bool Function()? isAiSenderMappingAuto,
    // The account identity this capture is processed under: an opaque value
    // (e.g. the replica owner + admission generation) that is non-null ONLY
    // while the local replica's owner IS the signed-in user. Read when the
    // capture starts and again IMMEDIATELY before every external AI request
    // (AI parse, AI bank discovery); a null, a throw or any change aborts the
    // capture with [StaleOwnershipException] BEFORE the request, so nothing is
    // sent and nothing is committed or acknowledged (the capture stays
    // recoverable in its queue). Absent => no identity re-check.
    Future<Object?> Function()? loadAccountIdentity,
  })  : _isLocalAutoConfirmV2 = isLocalAutoConfirmV2,
        _loadAccountIdentity = loadAccountIdentity,
        _senderBankMappingRepository = senderBankMappingRepository,
        _isAiSenderMappingAuto = isAiSenderMappingAuto,
        _transactionRepository = transactionRepository,
        _merchantIntelligence =
            merchantIntelligence ?? MerchantIntelligenceStore(),
        _coordinator = coordinator,
        _merchantCategoryRepository = merchantCategoryRepository,
        _parserIsolate = parserIsolate ?? const ParserIsolate(),
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _proofGateMode = proofGateMode,
        _proofParserConfidenceMinPermille = proofParserConfidenceMinPermille,
        _recordProofShadow = recordProofShadow,
        _loadBankProfiles = loadBankProfiles,
        _loadCatalogRules = loadCatalogRules,
        _loadRemoteKeywords = loadRemoteKeywords,
        _noteMerchantFeedback = noteMerchantFeedback,
        _resolveMerchantCategory = resolveMerchantCategory,
        _mayEnrichMerchant = mayEnrichMerchant,
        _accountRepository = accountRepository,
        _dedupStore = dedupStore,
        _aiClient = aiClient,
        _loadAiConsent = loadAiConsent,
        _aiPrimarySelected = aiPrimarySelected,
        _findSameTextCapture = findSameTextCapture,
        _installId = installId,
        _loadInstallId = loadInstallId,
        _resolveBankForSenderUseCase = resolveBankForSenderUseCase,
        _bankDiscoveryService = bankDiscoveryService,
        _suspectedDuplicateRepository = suspectedDuplicateRepository;

  /// PHASE 11 — run Proof for one capture and return the gate's finding.
  ///
  /// Never throws into the commit path. Proof is corroboration; if the engine
  /// fails for any reason the capture must still be processed exactly as it
  /// would have been, so every failure degrades to `notEvaluated` — which the
  /// gate treats as "not agreement", never as agreement.
  /// Run Proof for one capture. NEVER throws: corroboration must not be able to
  /// lose a transaction. Every failure mode returns a decision carrying an
  /// explicit outcome, so no attempted evaluation is silently lost.
  _ProofGateEvaluation _evaluateProofGate({
    required String rawMessage,
    required TransactionType type,
    required int amountMinorUnits,
    required String currencyIso,
    required double parseConfidence,
  }) {
    // Mode and threshold are read INDEPENDENTLY, on purpose.
    //
    // They were in one try block, so a THRESHOLD failure after a successful
    // mode read silently disarmed a gate the operator had turned ON — losing a
    // safety mechanism because an unrelated lookup threw. Now a threshold
    // failure falls back to the shipped floor (the strictest value, and the
    // tune-upward-only baseline) while the known mode is preserved.
    ProofGateMode mode = ProofGateMode.shadow;
    try {
      mode = _proofGateMode?.call() ?? ProofGateMode.shadow;
    } catch (_) {
      // Shadow only when the MODE ITSELF is unknown: guessing "armed" could
      // withhold a confirmation on the strength of a bug.
      mode = ProofGateMode.shadow;
    }
    int minPermille = ProofCommitGate.defaultParserConfidenceMinPermille;
    try {
      minPermille = _proofParserConfidenceMinPermille?.call() ?? minPermille;
    } catch (_) {
      minPermille = ProofCommitGate.defaultParserConfidenceMinPermille;
    }

    ProofResult? proof;
    String? canonical;
    String? direction;
    ProofProposalRefusal? refusal;
    ProofGateOutcome? errorOutcome;
    try {
      final evidence = extractEvidence(rawMessage);
      final outcome = const ProofProposalBuilder().build(
        evidence: evidence,
        type: type,
        amountMinorUnits: amountMinorUnits,
        currencyIso: currencyIso,
      );
      final proposal = outcome.proposal;
      refusal = outcome.refusal;
      if (proposal != null) {
        direction = proposal.direction;
        final currencyNode =
            evidence.items.firstWhere((e) => e.id == proposal.currencyId);
        canonical = ProofProposalBuilder.canonicalAmount(
            amountMinorUnits, currencyNode.scale ?? 2);
        try {
          proof = const ProofChecker().check(evidence, proposal);
        } catch (_) {
          errorOutcome = ProofGateOutcome.checkerError;
        }
      }
    } catch (_) {
      // Evidence extraction or proposal construction failed. Distinct from a
      // refusal: a refusal is the engine working, an error is it failing, and
      // conflating them would let a rising defect rate hide inside a benign
      // refusal rate.
      errorOutcome = ProofGateOutcome.evidenceError;
    }

    ProofGateDecision decision;
    try {
      decision = const ProofCommitGate().evaluate(
        mode: mode,
        proof: proof,
        parseConfidence: parseConfidence,
        parsedDirection: direction,
        parsedAmountCanonical: canonical,
        parsedCurrency: currencyIso,
        confidenceMinPermille: minPermille,
      );
    } catch (_) {
      decision = ProofGateDecision(
        mode: mode,
        outcome: ProofGateOutcome.checkerError,
        parseConfidencePermille: 0,
        confidenceMinPermille: minPermille,
      );
    }

    // An error outcome overrides whatever the gate concluded, so the persisted
    // observation names the failure rather than reporting a clean disagreement.
    if (errorOutcome != null) {
      decision = ProofGateDecision(
        mode: decision.mode,
        outcome: errorOutcome,
        parseConfidencePermille: decision.parseConfidencePermille,
        confidenceMinPermille: decision.confidenceMinPermille,
      );
    }
    return _ProofGateEvaluation(
      decision: decision,
      proof: proof,
      refusal: refusal,
      parsedDirection: direction,
      parsedAmountCanonical: canonical,
    );
  }

  /// Persist ONE durable observation for an attempted evaluation.
  ///
  /// Called for EVERY attempt, including refusals and internal errors: a
  /// denominator that silently omits the cases where the engine struggled would
  /// overstate how well it performs, and crash probability correlates with
  /// message shape.
  ///
  /// Field comparisons are recorded as MATCH OUTCOMES, never as the compared
  /// values — storing amount and currency would reconstruct the transaction
  /// inside a diagnostic table with a different purpose and lifetime.
  /// DURABILITY TRADE-OFF, stated explicitly.
  ///
  /// The write is fire-and-forget and swallows failures, so an observation can
  /// be lost on an abrupt process death. That is deliberate and required: the
  /// standing constraint is that a diagnostic write must NEVER affect the
  /// financial commit path, and awaiting the insert would make a locked or slow
  /// database able to delay a save. Tier 2 therefore counts what was durably
  /// recorded, which is a floor on what was attempted — the bias is toward
  /// UNDER-counting, never toward overstating how well the engine performed.
  void _emitShadowRecord({
    required String rawMessage,
    required _ProofGateEvaluation evaluation,
    required String? transactionId,
  }) {
    final record = _recordProofShadow;
    if (record == null) return;
    try {
      ProofFieldMatch cmp(String? a, String? b) {
        if (a == null || b == null || a.trim().isEmpty || b.trim().isEmpty) {
          return ProofFieldMatch.absent;
        }
        return a.trim().toLowerCase() == b.trim().toLowerCase()
            ? ProofFieldMatch.matched
            : ProofFieldMatch.mismatched;
      }

      final d = evaluation.decision;
      // One-way, local, and only for idempotency — see ProofShadowRecord.
      final key = sha256
          .convert(utf8.encode('$_proofEngineVersion|$rawMessage'))
          .toString()
          .substring(0, 32);

      record(ProofShadowRecord(
        evaluationKey: key,
        evaluatedAt: DateTime.now().toUtc(),
        transactionId: transactionId,
        engineVersion: _proofEngineVersion,
        gateMode: d.mode,
        outcome: d.outcome,
        wouldHaveCommitted: d.agrees,
        parseConfidencePermille: d.parseConfidencePermille,
        confidenceMinPermille: d.confidenceMinPermille,
        proofVerdict: evaluation.proof?.verdict,
        amountMatch: cmp(
            evaluation.proof?.amountCanonical, evaluation.parsedAmountCanonical),
        directionMatch:
            cmp(evaluation.proof?.direction, evaluation.parsedDirection),
        currencyMatch: cmp(evaluation.proof?.currency, null),
        refusal: evaluation.refusal,
      ));
    } catch (_) {
      // Recording is best-effort and must never be load-bearing.
    }
  }

  /// Reproducibility stamp. Bump when the gate, builder or thresholds change in
  /// a way that makes older observations non-comparable — otherwise a mixed
  /// population would be silently averaged during Tier 2.
  static const String _proofEngineVersion = 'proof-gate-1';

  static const double autoConfirmThreshold = 0.92;
  static const double categoryAutoConfirmThreshold = 0.80;

  final bool Function()? _isLocalAutoConfirmV2;

  bool _localAutoConfirmV2Enabled() {
    final read = _isLocalAutoConfirmV2;
    if (read == null) return false;
    try {
      return read() == true;
    } catch (_) {
      return false;
    }
  }

  /// Local validity for the V2 flow, computed before the AI decision. The
  /// proof gate is evaluated here on the local parse's own values; the final
  /// (post-reclassification) values are re-guarded before saving.
  LocalValidityResult _checkLocalValidity(
      ParseResult parseResult, String rawMessage) {
    final base = LocalValidity.check(
        parse: parseResult, rawMessage: rawMessage, proofWithholds: false);
    if (!base.isValid) return base;
    final txn = parseResult.transaction!;
    final money = parseCaptureMoney(txn.amountText!, txn.currency);
    final eval = _evaluateProofGate(
      rawMessage: rawMessage,
      type: txn.type,
      amountMinorUnits: money.minorUnits,
      currencyIso: txn.currency.trim().toUpperCase(),
      parseConfidence: txn.parseConfidence,
    );
    return LocalValidity.check(
      parse: parseResult,
      rawMessage: rawMessage,
      proofWithholds: eval.decision.withholdsConfirmation,
    );
  }

  final TransactionRepository _transactionRepository;
  final PlanningCutoverCoordinator _coordinator;
  final MerchantCategoryRepository _merchantCategoryRepository;
  final SuspectedDuplicateRepository? _suspectedDuplicateRepository;
  final ParserIsolate _parserIsolate;

  /// The on-device merchant model, built once. See [MerchantIntelligenceStore].
  final MerchantIntelligenceStore _merchantIntelligence;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;

  /// PHASE 11 Proof gate wiring. All three default to "inert": shadow mode, the
  /// shipped floor, and no recorder.
  final ProofGateMode Function()? _proofGateMode;
  final int Function()? _proofParserConfidenceMinPermille;
  final void Function(ProofShadowRecord record)? _recordProofShadow;
  final Future<List<BankProfile>> Function({String? senderId})?
      _loadBankProfiles;
  // F-016: the raw catalog rules the engine applies as first authority.
  final Future<List<CatalogParserRule>> Function(String? senderId)?
      _loadCatalogRules;
  final Future<List<RemoteMerchantKeyword>> Function()? _loadRemoteKeywords;
  final Future<void> Function(String normalizedMerchant)? _noteMerchantFeedback;
  final Future<String?> Function(String normalizedMerchant)?
      _resolveMerchantCategory;
  final Future<bool> Function()? _mayEnrichMerchant;
  final AccountRepository? _accountRepository;
  final DedupStore? _dedupStore;
  final AiParserClient? _aiClient;
  final Future<bool> Function()? _loadAiConsent;
  final Future<bool> Function()? _aiPrimarySelected;
  final Future<TransactionEntity?> Function({
    required String rawMessage,
    required Money amount,
    required String currency,
    required DateTime comparisonTimestamp,
  })? _findSameTextCapture;
  final String? _installId;
  final Future<String> Function()? _loadInstallId;
  final ResolveBankForSenderUseCase? _resolveBankForSenderUseCase;
  final BankDiscoveryService? _bankDiscoveryService;
  final SenderBankMappingRepository? _senderBankMappingRepository;
  final bool Function()? _isAiSenderMappingAuto;
  final Future<Object?> Function()? _loadAccountIdentity;

  /// The identity snapshot, or [_identityUnavailable] when it cannot be read.
  Future<Object> _readAccountIdentity() async {
    try {
      return await _loadAccountIdentity!() ?? _identityUnavailable;
    } catch (_) {
      return _identityUnavailable;
    }
  }

  static const Object _identityUnavailable = Object();

  /// Throws [StaleOwnershipException] unless the account identity read now is
  /// available and equal to [atStart]. Called immediately before each
  /// external AI request; a no-op when no identity source is wired.
  Future<void> _requireSameAccountIdentity(Object? atStart) async {
    if (_loadAccountIdentity == null) return;
    final now = await _readAccountIdentity();
    if (atStart == null ||
        identical(atStart, _identityUnavailable) ||
        identical(now, _identityUnavailable) ||
        now != atStart) {
      throw const StaleOwnershipException();
    }
  }

  /// Proven redelivery of [capture]: a transaction holding its id, or a
  /// durable receipt. Returns the already-committed result (never a review
  /// item), or null when the capture has no local result yet.
  Future<AddTransactionResult?> _alreadyCommitted(CaptureCommit capture) async {
    final own = await _transactionRepository.getById(capture.captureId);
    if (own != null) return AddTransactionResult.duplicate(own);
    final target = await capture.readReceipt?.call();
    if (target == null) return null;
    final pointed = await _transactionRepository.getById(target);
    if (pointed != null) return AddTransactionResult.duplicate(pointed);
    // A Smart Inbox / ignored marker: already handled, nothing to add.
    return AddTransactionResult.notTransaction(ParseResult.notTransaction(),
        aiFailureReason: 'already_imported');
  }

  /// Commits [action] for a capture: inside ONE transaction that first
  /// re-checks the capture's identity (another call on this connection may
  /// have committed it meanwhile), and — when the commit fails because a
  /// second connection to the same file won the race (unique id, busy
  /// snapshot) — returns the winner's committed result instead of failing.
  /// Without a [capture] the action runs as before (its own transactions).
  Future<AddTransactionResult> _commitCapture(
    CaptureCommit? capture,
    Future<AddTransactionResult> Function() action,
  ) async {
    if (capture == null) return action();
    AddTransactionResult? result;
    try {
      await capture.runAtomically(() async {
        result = await _alreadyCommitted(capture) ?? await action();
      });
    } on StaleOwnershipException {
      rethrow;
    } catch (error, stack) {
      AddTransactionResult? winner;
      try {
        winner = await _alreadyCommitted(capture);
      } catch (_) {
        winner = null;
      }
      if (winner != null) return winner;
      Error.throwWithStackTrace(error, stack);
    }
    return result!;
  }

  /// Fail closed: no callback, a throw, or anything but `true` means no
  /// enrichment egress.
  Future<bool> _mayEnrichMerchantNow() async {
    final check = _mayEnrichMerchant;
    if (check == null) return false;
    try {
      return await check() == true;
    } catch (_) {
      return false;
    }
  }

  Future<AddTransactionResult> call({
    required String rawMessage,
    String? senderId,
    bool skipDedup = false,
    DateTime? smsReceivedAt,
    bool onDeviceOnly = false,
    CaptureCommit? capture,
    // CAP-5 (Q5): the iOS local-after-reject path always applies binary local
    // acceptance (valid => confirmed, invalid => Smart Inbox), whatever the
    // `local_auto_confirm_v2` rollout flag says. Default keeps every other
    // caller on the flag.
    bool forceLocalAutoConfirm = false,
  }) async {
    // Proven redelivery (same capture id): the committed result, before any
    // parse or AI request — one transaction, no review noise.
    if (capture != null) {
      final redelivered = await _alreadyCommitted(capture);
      if (redelivered != null) return redelivered;
    }
    // The identity this capture is processed under, compared again right
    // before every external AI request. Read only when a request is possible.
    final identityAtStart = _loadAccountIdentity != null &&
            !onDeviceOnly &&
            (_aiClient != null || _bankDiscoveryService != null)
        ? await _readAccountIdentity()
        : null;
    final loadedBankProfiles = await _safeLoadBankProfiles(senderId: senderId);
    final catalogRules = await _safeLoadCatalogRules(senderId);
    final bankResolution = await _resolveBankForSender(
      rawMessage: rawMessage,
      senderId: senderId,
      bankProfiles: loadedBankProfiles,
    );
    final bankProfiles = bankResolution.bankProfiles;
    await _dropContradictedAiMapping(senderId, bankResolution.contentBankKey);
    final defaultAccount = await _accountRepository?.getDefault();

    // Pre-classify message before parsing so we can surface unprocessable cases.
    final isLikelyBank =
        BankSenderFilter.isLikelyBank(senderId, text: rawMessage);
    final wasIgnored = isLikelyBank
        ? ParserEngine.isIgnoredMessage(rawMessage,
            senderId: senderId, bankProfiles: bankProfiles)
        : false;

    final parseResult = await _parserIsolate.parse(
          rawMessage,
          senderId: senderId,
          bankProfiles: bankProfiles,
          catalogRules: catalogRules,
          defaultCurrency: defaultAccount?.currency ?? 'SAR',
        ) ??
        ParseResult.notTransaction();

    // `local_auto_confirm_v2`: a local parse is either VALID (confirmed) or
    // INVALID, and invalid means "local produced no transaction".
    final localV2 = forceLocalAutoConfirm || _localAutoConfirmV2Enabled();
    final localAccepted = localV2
        ? _checkLocalValidity(parseResult, rawMessage).isValid
        : parseResult.isTransaction;
    // What a rejected result reports as the local parse: nothing.
    final reportedParse = localV2 && parseResult.isTransaction && !localAccepted
        ? ParseResult.notTransaction(bankKey: parseResult.bankKey)
        : parseResult;

    // Every egress-eligible capture consults consented AI, even when local
    // parsing succeeded. Local money still constrains the candidate validator.
    final aiFirstAttempt = wasIgnored || onDeviceOnly
        ? _AiFirstAttempt.skipped(
            wasIgnored ? 'message_ignored' : 'on_device_only',
          )
        : await _tryAiParseFirst(
            rawMessage: rawMessage,
            senderId: senderId,
            beforeRequest: () => _requireSameAccountIdentity(identityAtStart),
          );

    // A "no transaction" result is acked away silently UNLESS it is surfaced to
    // the Smart Inbox. It is surfaced when the sender looks like a bank, OR the
    // message was transaction-shaped (the local parser read an amount, even if
    // V2 judged it invalid, or the AI returned a candidate the validator
    // rejected) — whatever the sender (e.g. a letterless numeric short code).
    // Intentionally ignored messages (OTP/promo/...) always stay ignored.
    final transactionShaped = parseResult.isTransaction ||
        parseResult.amountDetected ||
        aiFirstAttempt.response != null;
    final aiPrimary = !onDeviceOnly &&
        !wasIgnored &&
        ((await _aiPrimarySelected?.call() ?? false) ||
            (_aiClient is PrimaryAiParserClient &&
                aiFirstAttempt.sanitizedSms != null));
    final aiSaysNotTransaction = aiPrimary &&
        aiFirstAttempt.response == null && aiFirstAttempt.failureReason == null;
    // An AI "not a transaction" verdict is NOT an intentional drop: a model can
    // misread a real bank message, so it becomes a review item (Smart Inbox)
    // unless the DETERMINISTIC OTP/promo filter also rejects the text.
    final intentionallyIgnored = wasIgnored ||
        ((transactionShaped || aiSaysNotTransaction) &&
            ParserEngine.isIgnoredMessage(rawMessage,
                senderId: senderId, bankProfiles: bankProfiles));
    final droppedByParser =
        !intentionallyIgnored && (aiPrimary || isLikelyBank || transactionShaped);

    BankDiscoveryResult? discovery;
    if (!onDeviceOnly) {
      // AI bank discovery is an external AI request too, gated by the same AI
      // consent: with consent it may send, so the identity is re-checked first.
      if (_bankDiscoveryService != null &&
          _loadAccountIdentity != null &&
          (await _loadAiConsent?.call() ?? false)) {
        await _requireSameAccountIdentity(identityAtStart);
      }
      discovery = await _runBankDiscoveryIfEligible(
        rawMessage: rawMessage,
        senderId: senderId,
        bankProfiles: loadedBankProfiles,
        parseResult: parseResult,
        localeHint: defaultAccount?.currency,
      );
    }

    // An eligible production AI request owns the result even when the local
    // parser found a different amount/category. It is never replaced on failure.
    final localParsed =
        !aiPrimary && localAccepted ? parseResult.transaction : null;
    if (localParsed != null) {
      await _logMetric?.call('parse_success', dimension: parseResult.bankKey);
    }

    final aiParsed = _applyAiResponse(
      attempt: aiFirstAttempt,
      rawMessage: rawMessage,
      localParsed: localParsed,
      referenceTime: (smsReceivedAt ?? DateTime.now()).toUtc(),
    );

    ParsedTransaction parsed;
    String? aiCategoryKey;
    TransactionDirectionEntity? aiDirection;
    // Acceptance comes from deterministic grounding, including local agreement.
    final aiValidated = aiParsed != null;
    if (aiParsed != null) {
      parsed = aiParsed.transaction;
      aiCategoryKey = aiParsed.categoryKey;
      aiDirection = aiParsed.direction;
      if (localParsed == null) {
        await _logMetric?.call('ai_first_parse');
      }
    } else if (localParsed != null) {
      parsed = localParsed;
    } else {
      // AI validator FAIL (or no transaction) means NO transaction: no
      // low-confidence pending fallback is offered.
      // The AI had the first chance and the rule-based parser still couldn't
      // read it. For a bank-like sender, surface that it was dropped by parsing
      // so the UI can avoid a noisy "unreadable message" dead end.
      return AddTransactionResult.notTransaction(reportedParse,
          droppedByParser: droppedByParser,
          aiFailureReason: aiFirstAttempt.failureReason ??
              (aiFirstAttempt.response == null
                  ? null
                  : 'ai_response_rejected_by_grounding'));
    }
    final now = DateTime.now().toUtc();
    final receivedAt = (smsReceivedAt ?? now).toUtc();
    final transactionTimeFromSms = _keepReceivedTimeForBareDate(
        (parsed.occurredAt ?? TransactionTimestampExtractor.extract(rawMessage))
            ?.toUtc(),
        receivedAt);
    final comparisonTimestamp = transactionTimeFromSms ?? receivedAt;
    final comparisonTimestampSource = transactionTimeFromSms == null
        ? ComparisonTimestampSource.receivedAt
        : ComparisonTimestampSource.smsBody;
    final occurredAt = comparisonTimestamp;
    if (parsed.occurredAt == null && transactionTimeFromSms != null) {
      parsed = parsed.copyWith(occurredAt: transactionTimeFromSms);
    }

    // Payment aggregators (Fawry, …) are gateways, not the real merchant. When
    // the SMS reads "Fawry <merchant>", strip the gateway so the underlying
    // merchant (e.g. the restaurant) drives dedup, categorization, and the
    // brand logo instead of the gateway.
    parsed = parsed.copyWith(
      rawMerchant: PaymentAggregators.resolveMerchant(parsed.rawMerchant),
    );

    final merchant = parsed.rawMerchant;
    final parsedAmountForDedup = _captureMoney(
      exactText: parsed.amountText,
      heuristicValue: parsed.amount,
      currency: parsed.currency,
    );
    // Pre-categorize to determine if keyword match exists — known merchants
    // (Starbucks, Amazon, etc.) should not require confirmation even on first visit.
    final preCategory = Categorizer(
      remoteKeywords: const [],
      intelligence: _merchantIntelligence,
    ).categorize(parsed);
    final isNewMerchant = merchant == null
        ? false
        : preCategory.source == CategorySource.fallback &&
            !await _merchantCategoryRepository.hasCategoryForMerchant(merchant);

    if (!skipDedup) {
      final duplicate = await _transactionRepository.findSuspiciousDuplicate(
        amount: parsedAmountForDedup.money,
        currency: parsed.currency,
        merchantOrDescription: parsed.rawMerchant ?? rawMessage,
        cardLast4: parsed.cardLast4,
        comparisonTimestamp: comparisonTimestamp,
      );
      // Exact-identity signal, independent of any window: the same amount,
      // currency, merchant (and card) at the SAME comparison instant.
      if (duplicate != null) {
        const reason = 'same amount, currency, merchant and comparison time';
        return _commitCapture(capture, () async {
          final suspectedId = await _saveSuspectedDuplicate(
            rawMessage: rawMessage,
            senderId: senderId,
            existingTransactionId: duplicate.id,
            parsed: parsed,
            amountMoney: parsedAmountForDedup.money,
            occurredAt: occurredAt,
            cardLast4: parsed.cardLast4,
            comparisonTimestamp: comparisonTimestamp,
            comparisonTimestampSource: comparisonTimestampSource,
            duplicateReason: reason,
            id: capture?.captureId,
          );
          await capture?.writeReceipt(duplicate.id);
          return AddTransactionResult.suspiciousDuplicate(
            duplicate,
            suspectedDuplicateId: suspectedId,
            duplicateReason: reason,
          );
        });
      }
      // F9 — the SAME message text was already captured recently (e.g. once by
      // the SMS receiver and once by a manual share, or a body with no time so
      // the exact-timestamp check above cannot match). Identity is uncertain:
      // it may be one message twice or two identical purchases. Never merge and
      // never drop — keep this capture as a suspected duplicate for review.
      // Outside the window nothing is claimed either way: the text match is
      // simply no longer used as a signal, and the capture is saved normally.
      final sameText = await _findSameTextCapture?.call(
        rawMessage: rawMessage,
        amount: parsedAmountForDedup.money,
        currency: parsed.currency,
        comparisonTimestamp: comparisonTimestamp,
      );
      if (sameText != null) {
        const reason = 'same message text captured again';
        return _commitCapture(capture, () async {
          final suspectedId = await _saveSuspectedDuplicate(
            rawMessage: rawMessage,
            senderId: senderId,
            existingTransactionId: sameText.id,
            parsed: parsed,
            amountMoney: parsedAmountForDedup.money,
            occurredAt: occurredAt,
            cardLast4: parsed.cardLast4,
            comparisonTimestamp: comparisonTimestamp,
            comparisonTimestampSource: comparisonTimestampSource,
            duplicateReason: reason,
            id: capture?.captureId,
          );
          await capture?.writeReceipt(sameText.id);
          return AddTransactionResult.suspiciousDuplicate(
            sameText,
            suspectedDuplicateId: suspectedId,
            duplicateReason: reason,
          );
        });
      }
    }

    final learnedMap =
        await _merchantCategoryRepository.getLearnedCategoryMap();
    final loader = _loadRemoteKeywords;
    final remoteKeywords =
        loader != null ? await loader() : const <RemoteMerchantKeyword>[];
    final categorizer = Categorizer(
      map: MerchantCategoryMap(learnedMap),
      remoteKeywords: remoteKeywords,
      // OD-13 — on-device merchant model. It runs ONLY where every
      // deterministic source has already declined (see `Categorizer`), and
      // performs no I/O, so it neither delays capture nor egresses anything.
      // Shared instance: constructing it here fitted ~330 exemplars on every
      // single transaction, twice.
      intelligence: _merchantIntelligence,
    );
    var effectiveParsed = parsed;
    final hasAiCategory = aiCategoryKey != null;
    final hasSpecificAiCategory = hasAiCategory &&
        aiCategoryKey != Categories.other.key &&
        Categories.byKey(aiCategoryKey) != Categories.other;
    var effectiveCategory = hasAiCategory
        ? CategoryResult(
            Categories.byKey(aiCategoryKey).key,
            hasSpecificAiCategory
                ? CategorySource.keyword
                : CategorySource.fallback,
            hasSpecificAiCategory ? 0.85 : 0.3,
          )
        : categorizer.categorize(effectiveParsed);

    // Transfer accounting — mirrors mainstream finance apps:
    //   • internal / own-account move → neutral transfer (excluded from totals)
    //   • a cash/ATM deposit (إيداع)   → neutral transfer (cash you already had)
    //   • money RECEIVED from outside  → income  (counts toward income)
    //   • money SENT outside           → expense (counts toward spending)
    // Beneficiary/payer names are dropped (real people, not businesses). The
    // wording grounds the direction, so it works for both the rule parser and AI.
    // Resolve the money direction ONCE from all signals (AI → wording → type)
    // so the income/expense bucket, the stored direction and the row's +/− can
    // never disagree (an AI "credit" must not land in the expense total).
    final resolvedDirection = aiDirection ??
        _directionFromText(rawMessage) ??
        _directionFromType(effectiveParsed.type);
    final incoming = resolvedDirection == TransactionDirectionEntity.credit;
    final isNeutralTransfer = looksLikeInternalTransfer(rawMessage) ||
        (incoming && effectiveParsed.type == TransactionType.withdrawal);
    final isExternalTransfer = !isNeutralTransfer &&
        (effectiveParsed.type == TransactionType.transfer ||
            _looksLikeTransferMessage(rawMessage));
    if (isNeutralTransfer) {
      effectiveParsed = _replaceMerchant(
        effectiveParsed.copyWith(type: TransactionType.transfer),
        null,
      );
      effectiveCategory = CategoryResult(
        Categories.transfers.key,
        CategorySource.typeRule,
        0.95,
      );
    } else if (isExternalTransfer) {
      effectiveParsed = _replaceMerchant(
        effectiveParsed.copyWith(
          type: incoming ? TransactionType.income : TransactionType.payment,
        ),
        null,
      );
      effectiveCategory = CategoryResult(
        incoming ? Categories.income.key : Categories.transfers.key,
        CategorySource.typeRule,
        0.9,
      );
    } else if (effectiveParsed.type == TransactionType.income) {
      effectiveParsed = _replaceMerchant(effectiveParsed, null);
      if (!hasAiCategory) {
        effectiveCategory = CategoryResult(
          Categories.income.key,
          CategorySource.typeRule,
          0.95,
        );
      }
    } else if (effectiveParsed.type == TransactionType.withdrawal &&
        !hasAiCategory) {
      effectiveCategory = CategoryResult(
        Categories.cash.key,
        CategorySource.typeRule,
        0.95,
      );
    }

    // The AI validator checked the AI's own type; reclassification above can
    // still change the stored type (e.g. transfer -> payment from the AI
    // direction). If the FINAL type contradicts the wording, treat it as a
    // validator rejection: no transaction.
    if (aiValidated &&
        DirectionSignal.contradicts(rawMessage, effectiveParsed.type)) {
      AiSenderFailureTracker.instance
          .recordFailure(aiFirstAttempt.senderId);
      return AddTransactionResult.notTransaction(reportedParse,
          droppedByParser: droppedByParser,
          aiFailureReason: 'ai_response_rejected_by_grounding');
    }

    // Anonymous merchant feedback — ONLY for POS/payment types.
    // Transfers and income carry beneficiary/payer names (real people), not
    // business names. Recording those would be the same privacy leak fixed in
    // 4A via SmsSanitizer. Unknown type also excluded (cannot confirm it is a
    // business).
    final noter = _noteMerchantFeedback;
    final isBusinessMerchant =
        effectiveParsed.type == TransactionType.payment ||
            effectiveParsed.type == TransactionType.refund;
    if (!hasAiCategory &&
        effectiveCategory.source == CategorySource.fallback &&
        effectiveParsed.rawMerchant != null &&
        isBusinessMerchant) {
      final normalized =
          TransactionDedup.normalizeMerchant(effectiveParsed.rawMerchant!);
      if (normalized.isNotEmpty) {
        // Real-time assist: rules and AI both fell back to "other", so ask the
        // server (Google Places via enrich-merchant) to resolve a category. The
        // function also writes the result into merchant_keywords, so every other
        // device picks it up on the next catalog sync.
        final resolver = onDeviceOnly ? null : _resolveMerchantCategory;
        String? resolved;
        if (resolver != null && await _mayEnrichMerchantNow()) {
          try {
            resolved = await resolver(normalized);
          } catch (_) {
            resolved = null; // enrichment is best-effort; keep the fallback.
          }
        }
        if (resolved != null && resolved.isNotEmpty && resolved != 'other') {
          effectiveCategory =
              CategoryResult(resolved, CategorySource.keyword, 0.85);
        } else if (noter != null) {
          // Places couldn't resolve it either — keep the anonymous feedback
          // queue so an admin can map it manually.
          await noter(normalized);
        }
        if (effectiveCategory.categoryKey == Categories.other.key) {
          effectiveCategory = CategoryResult(
            _bestEffortMerchantCategory(normalized),
            CategorySource.fallback,
            0.55,
          );
        }
      }
    }
    if (!aiValidated &&
        effectiveCategory.categoryKey == Categories.cash.key &&
        effectiveParsed.type == TransactionType.payment &&
        _looksLikeBankAtmCardTransaction(
          rawMessage,
          merchantName: effectiveParsed.rawMerchant,
        )) {
      effectiveParsed =
          effectiveParsed.copyWith(type: TransactionType.withdrawal);
    }
    // Independent direction grounding: if the wording clearly contradicts the
    // classified type (e.g. an "إيداع/deposit" message tagged as a payment),
    // never auto-confirm — route it to pending for review regardless of score.
    final directionContradiction =
        DirectionSignal.contradicts(rawMessage, effectiveParsed.type);
    // A validator-accepted AI transaction bypasses the confidence / category /
    // new-merchant gates (AI confidence never decides acceptance). Its final
    // direction contradiction was already rejected above.
    final canAutoConfirm = aiValidated || localV2
        ? true
        : effectiveParsed.parseConfidence >= autoConfirmThreshold &&
            effectiveCategory.confidence >= categoryAutoConfirmThreshold &&
            !isNewMerchant &&
            !directionContradiction;
    // Foreign-currency spend on a home-currency card: park it in the home
    // account with amount=0 ("awaiting pricing") so the user can enter the
    // home-currency value later via the details screen.
    // Only applies when the SMS itself contains a fee in the home currency —
    // that fee proves the card is a home-currency card paying in a foreign
    // currency (e.g. SAR card used for a USD purchase). Without that signal
    // we assume the SMS belongs to a different account and auto-create one.
    final homeCurrency = defaultAccount?.currency.trim().toUpperCase();
    final txCurrency = effectiveParsed.currency.trim().toUpperCase();
    final isSpend = effectiveParsed.type == TransactionType.payment ||
        effectiveParsed.type == TransactionType.withdrawal;
    final fee = _extractFeeAmount(rawMessage);
    final hasHomeCurrencyFee = fee != null &&
        homeCurrency != null &&
        fee.currency.trim().toUpperCase() == homeCurrency;
    final foreignUnpriced = homeCurrency != null &&
        homeCurrency.isNotEmpty &&
        txCurrency.isNotEmpty &&
        txCurrency != homeCurrency &&
        isSpend &&
        hasHomeCurrencyFee &&
        await _existingAccountForCurrency(txCurrency) == null;

    // أولوية الإسناد: (1) رقم الحساب المطابق لـ bank_account_number إن وُجد،
    // ثم (2) مطابقة العملة، ثم (3) الحساب الافتراضي. لا يمسّ ربط البطاقة (A2).
    final byAccountNumber = foreignUnpriced
        ? null
        : await _accountByNumber(
            _accountRepository,
            effectiveParsed.accountNumber,
          );
    final effectiveAccount = foreignUnpriced
        ? defaultAccount
        : (byAccountNumber ??
            await _accountForCurrency(
              _accountRepository,
              effectiveParsed.currency,
              fallback: defaultAccount,
            ));

    final transactionCurrency = foreignUnpriced
        ? homeCurrency
        : effectiveParsed.currency.trim().toUpperCase();
    final mainAmount = foreignUnpriced
        ? _CaptureMoneyResolution(Money.zero(transactionCurrency),
            legacyLossy: false)
        : _captureMoney(
            exactText: effectiveParsed.amountText,
            heuristicValue: effectiveParsed.amount,
            currency: transactionCurrency,
          );
    final balanceAfter = _captureMoneyOrNull(
      exactText: effectiveParsed.balanceAfterText,
      heuristicValue: effectiveParsed.balanceAfter,
      currency: transactionCurrency,
    );
    final String? finalForeignCurrency = foreignUnpriced
        ? txCurrency
        : effectiveParsed.foreignCurrency?.trim().toUpperCase();
    if (!foreignUnpriced &&
        (effectiveParsed.foreignAmount == null) !=
            (finalForeignCurrency == null)) {
      throw StateError(
          'foreign amount and foreign currency must be supplied together');
    }
    final foreignAmount = finalForeignCurrency == null
        ? const _NullableCaptureMoneyResolution(null, legacyLossy: false)
        : _captureMoneyOrNull(
            exactText: foreignUnpriced
                ? effectiveParsed.amountText
                : effectiveParsed.foreignAmountText,
            heuristicValue: foreignUnpriced
                ? effectiveParsed.amount
                : effectiveParsed.foreignAmount,
            currency: finalForeignCurrency,
          );
    final legacyLossyReview = parsedAmountForDedup.legacyLossy ||
        mainAmount.legacyLossy ||
        balanceAfter.legacyLossy ||
        foreignAmount.legacyLossy;
    // MALI-026 (B8-2.10 §12/§13): the explicit ingress contract. In canonical
    // mode any non-exact (legacy-lossy) money forces pending review — a
    // numeric-only old-backend response can never auto-confirm into canonical
    // authority. Legacy (v29) is unchanged (non-exact already reviews).
    final requiresReview = resolveAiCaptureIngress(
          hasExactText: !legacyLossyReview,
          canonicalMode:
              _coordinator.state() == PlanningCutoverState.canonical,
        ) ==
        AiCaptureIngress.legacyPendingReview;

    // ---- PHASE 11: Proof gate -------------------------------------------
    //
    // Evaluated for EVERY capture so shadow measurement sees the real
    // population, not a filtered one. In shadow mode the decision below is
    // byte-identical to what it would be without Proof — which is what makes
    // the recorded numbers describe the decision that was actually made.
    //
    // `proofResult` is null until the Proof engine is fed by the capture
    // pipeline; a null is recorded as `notEvaluated` and is never agreement.
    final proofEval = _evaluateProofGate(
      rawMessage: rawMessage,
      type: effectiveParsed.type,
      amountMinorUnits: mainAmount.money.minorUnits,
      currencyIso: transactionCurrency,
      parseConfidence: effectiveParsed.parseConfidence,
    );
    // Outcome label plus two integers. No message text, no amount, no merchant:
    // recording a shadow verdict must never become an exfiltration path.
    // V2: a local parse that was VALID when read must still be valid after
    // reclassification (type/direction/proof). If not, it is "local produced no
    // transaction" — never a pending row. AI was already decided upstream.
    if (localV2 &&
        localParsed != null &&
        (directionContradiction ||
            (!foreignUnpriced && proofEval.decision.withholdsConfirmation))) {
      return AddTransactionResult.notTransaction(reportedParse,
          droppedByParser: droppedByParser,
          aiFailureReason: 'local_invalid_after_reclassification');
    }
    final primaryCommit = CaptureCommitDecision.primary(
      canAutoConfirm: canAutoConfirm,
      // V2: pricing uncertainty is not a confirmation state (the row is
      // confirmed with amount 0 and its pricing state is awaitingFx).
      foreignUnpriced: localV2 ? false : foreignUnpriced,
      requiresReview: requiresReview,
      // The deterministic validator is the gate for AI captures: the proof
      // gate withholds local parses only. (Still evaluated/recorded above.)
      // V2 folds the proof gate into local validity, checked above.
      proofGate: aiValidated || localV2 ? null : proofEval.decision,
    );

    final transaction = TransactionEntity(
      id: capture?.captureId ?? IdGenerator.next(),
      amountMoney: mainAmount.money,
      currency: transactionCurrency,
      accountId: effectiveAccount?.id,
      merchantId: null,
      rawMerchant: effectiveParsed.rawMerchant,
      categoryId: null,
      type: _mapType(effectiveParsed.type),
      source: _mapSource(effectiveParsed.source),
      cardLast4: effectiveParsed.cardLast4,
      balanceAfterMoney: balanceAfter.money,
      occurredAt: occurredAt.toUtc(),
      rawMessage: rawMessage,
      parseConfidence: effectiveParsed.parseConfidence,
      direction: resolvedDirection,
      // PHASE 1 seam: the primary row's commit status now flows through the
      // single capture authority. The decision itself is unchanged.
      status: primaryCommit.status,
      createdAt: now,
      updatedAt: now,
      foreignMoney: foreignAmount.money,
      foreignCurrency: finalForeignCurrency,
      transactionTimeFromSms: transactionTimeFromSms,
      smsReceivedAt: receivedAt,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateStatus: DuplicateStatus.normal,
    );

    // Persisted AFTER the transaction exists so the observation carries its id
    // — the attribution key that lets Tier 2 ask whether a would-have-committed
    // decision was later corrected. Emitted for EVERY attempt, including
    // refusals and internal errors, so the denominator is not silently pruned
    // of the cases where the engine struggled.
    _emitShadowRecord(
      rawMessage: rawMessage,
      evaluation: proofEval,
      transactionId: transaction.id,
    );

    // Persistence only: every network step (AI, discovery, enrichment) is done.
    // With a [capture], the primary row, any fee row, their outbox rows and the
    // payload receipt commit together or not at all.
    final committed = await _commitCapture(capture, () async {
      final saved = await _transactionRepository.saveTransaction(
        transaction: transaction,
        categoryKey: effectiveCategory.categoryKey,
      );
      if (_recordEngagementUseCase != null) {
        await _recordEngagementUseCase(
          action: saved.status == TransactionStatus.confirmed
              ? EngagementAction.transactionConfirmed
              : EngagementAction.transactionAdded,
          occurredAt: saved.occurredAt,
        );
      }

      // Only an AI-only read teaches a sender->bank mapping; a local parse
      // that AI merely enriched never does.
      if (aiValidated &&
          localParsed == null &&
          saved.status == TransactionStatus.confirmed) {
        await _persistAiSenderMapping(senderId: senderId, discovery: discovery);
      }

      // Mark dedup hash after successful save. Keyed on the originally parsed
      // identity (not the reclassified type) so it matches the pre-save lookup
      // even when an external transfer is re-typed to income/expense.
      if (_dedupStore != null) {
        final hash = await TransactionDedup.computeHash(
          // HEURISTIC-ONLY fingerprint derived deterministically from the token.
          amount: parsed.amount,
          currency: parsed.currency,
          cardLast4: parsed.cardLast4,
          merchantNormalized: _dedupFingerprint(
            parsed,
            rawMessage: rawMessage,
          ),
          type: parsed.type.name,
        );
        await _dedupStore.mark(
          hash,
          transactionId: transaction.id,
          occurredAt: occurredAt,
        );
      }

      // Only now that the primary spend is genuinely new do we add any fee/tax
      // line from the same SMS. Doing it here (not before the dedup checks) means
      // re-pasting the same message — primary already a duplicate — can never add
      // a second fee.
      final secondary = await _maybeSaveFee(
        primaryWithheldByProof:
            primaryCommit.reason == CaptureCommitReason.proofNotCorroborated,
        rawMessage: rawMessage,
        primary: parsed,
        occurredAt: occurredAt,
        defaultAccount: defaultAccount,
        transactionTimeFromSms: transactionTimeFromSms,
        smsReceivedAt: receivedAt,
        comparisonTimestampSource: comparisonTimestampSource,
        feeId: capture?.feeId,
      );
      await capture?.writeReceipt(saved.id);
      return AddTransactionResult.added(
        saved,
        parseResult,
        // A validated AI capture is confirmed: a new merchant must not reopen
        // the confirm sheet through `requiresConfirmation`.
        isNewMerchant: aiValidated || localV2 ? false : isNewMerchant,
        secondary: secondary,
        // Why AI did not read this one (a reason code, never content).
        aiFailureReason: aiParsed != null
            ? null
            : aiFirstAttempt.failureReason ??
                (aiFirstAttempt.response != null
                    ? 'ai_response_rejected_by_grounding'
                    : 'ai_no_answer'),
      );
    });

    if (committed.outcome == AddTransactionOutcome.added) {
      await _logMetric?.call('first_transaction_captured');
    }
    return committed;
  }

  Future<String?> _saveSuspectedDuplicate({
    required String rawMessage,
    required String? senderId,
    required String existingTransactionId,
    required ParsedTransaction parsed,
    required Money amountMoney,
    required DateTime occurredAt,
    String? cardLast4,
    DateTime? comparisonTimestamp,
    ComparisonTimestampSource? comparisonTimestampSource,
    String? duplicateReason,
    String? id,
  }) async {
    final repo = _suspectedDuplicateRepository;
    if (repo == null) return null;
    id ??= IdGenerator.next();
    await repo.save(SuspectedDuplicateEntity(
      id: id,
      rawMessage: rawMessage,
      senderId: senderId,
      existingTransactionId: existingTransactionId,
      amountMoney: amountMoney,
      currency: parsed.currency,
      rawMerchant: parsed.rawMerchant,
      occurredAt: occurredAt,
      cardLast4: cardLast4,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateReason: duplicateReason,
      createdAt: DateTime.now().toUtc(),
    ));
    return id;
  }

  Future<AccountEntity?> _existingAccountForCurrency(String currency) async {
    final repo = _accountRepository;
    final normalized = currency.trim().toUpperCase();
    if (repo == null || normalized.isEmpty) return null;
    final accounts = await repo.getAll();
    for (final account in accounts) {
      if (account.currency.trim().toUpperCase() == normalized) return account;
    }
    return null;
  }

  Future<AddTransactionResult?> _maybeSaveFee({
    required String rawMessage,
    required ParsedTransaction primary,
    required DateTime occurredAt,
    AccountEntity? defaultAccount,
    DateTime? transactionTimeFromSms,
    DateTime? smsReceivedAt,
    required ComparisonTimestampSource comparisonTimestampSource,

    /// True when Proof withheld the PRIMARY row. The fee is a leg of the same
    /// captured message, so it must not stand alone as a confirmed row.
    bool primaryWithheldByProof = false,
    String? feeId,
  }) async {
    final fee = _extractFeeAmount(rawMessage);
    if (fee == null) return null;
    final amount = fee.heuristicAmount;
    final currency = fee.currency;
    // Same currency as the main amount → part of one charge, not a second
    // transaction; skip to avoid double counting.
    if (currency.toUpperCase() == primary.currency.trim().toUpperCase()) {
      return null;
    }

    Future<String> feeHash() => TransactionDedup.computeHash(
          // HEURISTIC-ONLY dedup fingerprint; money is parsed from fee text.
          amount: amount,
          currency: currency,
          cardLast4: primary.cardLast4,
          merchantNormalized: 'FEE',
          type: TransactionType.payment.name,
        );

    if (_dedupStore != null) {
      final existingId =
          await _dedupStore.transactionIdFor(await feeHash(), occurredAt);
      if (existingId != null) {
        final existing = await _transactionRepository.getById(existingId);
        if (existing != null) return AddTransactionResult.duplicate(existing);
      }
    }

    final account = await _accountForCurrency(
      _accountRepository,
      currency,
      fallback: defaultAccount,
    );
    final now = DateTime.now().toUtc();
    final feeAmount = _captureMoney(
      exactText: fee.amountText,
      heuristicValue: fee.heuristicAmount,
      currency: currency,
    );
    final feeTx = TransactionEntity(
      id: feeId ?? IdGenerator.next(),
      amountMoney: feeAmount.money,
      currency: currency,
      accountId: account?.id,
      merchantId: null,
      rawMerchant: null,
      categoryId: null,
      type: TransactionTypeEntity.payment,
      source: _mapSource(primary.source),
      cardLast4: primary.cardLast4,
      note: 'رسوم/ضريبة',
      occurredAt: occurredAt.toUtc(),
      rawMessage: rawMessage,
      parseConfidence: 1.0,
      direction: TransactionDirectionEntity.debit,
      // MALI-026 (B8-2.10 §12): the fee line obeys the same ingress contract —
      // a non-exact fee amount cannot auto-confirm in canonical mode.
      // PHASE 1 seam: routed through the same capture authority as the primary
      // row so a future proof gate cannot secure one and miss the other. The
      // decision itself is unchanged.
      status: CaptureCommitDecision.fee(
        hasExactText: !feeAmount.legacyLossy,
        canonicalMode:
            _coordinator.state() == PlanningCutoverState.canonical,
        // The fee follows the primary: a Proof-withheld primary must never
        // leave a confirmed fee row behind it.
        primaryWithheldByProof: primaryWithheldByProof,
      ).status,
      createdAt: now,
      updatedAt: now,
      transactionTimeFromSms: transactionTimeFromSms,
      smsReceivedAt: smsReceivedAt,
      comparisonTimestamp: occurredAt.toUtc(),
      comparisonTimestampSource: comparisonTimestampSource,
      duplicateStatus: DuplicateStatus.normal,
    );
    final saved = await _transactionRepository.saveTransaction(
      transaction: feeTx,
      categoryKey: Categories.bills.key,
    );
    if (_dedupStore != null) {
      await _dedupStore.mark(
        await feeHash(),
        transactionId: feeTx.id,
        occurredAt: occurredAt,
      );
    }
    return AddTransactionResult.added(saved, ParseResult.notTransaction());
  }

  /// Extracts a fee/tax amount that appears AFTER a fee keyword
  /// (الرسوم/الضريبة/fee/VAT/tax). Returns null when no such line exists.
  static ({String amountText, double heuristicAmount, String currency})?
      _extractFeeAmount(String rawMessage) {
    final keyword = RegExp(
      r'(?:الرسوم|الرسم|الضريبة|الضرائب|رسوم|ضريبة|fees?|vat|tax)',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    if (keyword == null) return null;
    final fee = _extractAmountCurrency(rawMessage.substring(keyword.end));
    if (fee == null || fee.heuristicAmount <= 0) return null;
    return fee;
  }

  Future<List<CatalogParserRule>> _safeLoadCatalogRules(
      String? senderId) async {
    final loader = _loadCatalogRules;
    if (loader == null) return const [];
    try {
      return await loader(senderId);
    } catch (_) {
      return const [];
    }
  }

  Future<List<BankProfile>> _safeLoadBankProfiles({String? senderId}) async {
    final loader = _loadBankProfiles;
    if (loader == null) return const [];
    try {
      return await loader(senderId: senderId);
    } catch (_) {
      return const [];
    }
  }

  Future<BankSenderResolution> _resolveBankForSender({
    required String rawMessage,
    required String? senderId,
    required List<BankProfile> bankProfiles,
  }) async {
    final resolver = _resolveBankForSenderUseCase;
    if (resolver == null) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }
    try {
      return await resolver(
        rawMessage: rawMessage,
        senderId: senderId,
        bankProfiles: bankProfiles,
      );
    } catch (_) {
      return BankSenderResolution(
        source: BankSenderResolutionSource.unknown,
        bankProfiles: bankProfiles,
      );
    }
  }

  /// Side effect only: content-detected bank Y contradicts an AI mapping to X
  /// for this sender, so the AI mapping is tombstoned. Swallows everything.
  Future<void> _dropContradictedAiMapping(
      String? senderId, String? contentBankKey) async {
    final repo = _senderBankMappingRepository;
    final sender = senderId?.trim();
    if (repo == null || contentBankKey == null) return;
    if (sender == null || sender.isEmpty) return;
    try {
      await repo.tombstoneAiMappingIfContradicted(
        senderId: sender,
        contentBankKey: contentBankKey,
      );
    } catch (_) {}
  }

  /// Fail closed; never throws into the capture path.
  Future<void> _persistAiSenderMapping({
    required String? senderId,
    required BankDiscoveryResult? discovery,
  }) async {
    final repo = _senderBankMappingRepository;
    final flag = _isAiSenderMappingAuto;
    final suggestion = discovery?.suggestion;
    final sender = senderId?.trim();
    if (repo == null || flag == null || suggestion == null) return;
    if (sender == null || sender.isEmpty) return;
    final bankKey = suggestion.bankKeySuggestion;
    if (bankKey == null || bankKey.isEmpty) return;
    try {
      if (flag() != true) return;
      await repo.upsertAiValidated(
        senderId: sender,
        bankKey: bankKey,
        bankName: suggestion.suggestedBankName,
        country: suggestion.country,
      );
    } catch (_) {
      // Advisory: a mapping failure must never affect the saved transaction.
    }
  }

  Future<BankDiscoveryResult?> _runBankDiscoveryIfEligible({
    required String rawMessage,
    required String? senderId,
    required List<BankProfile> bankProfiles,
    required ParseResult parseResult,
    String? localeHint,
  }) async {
    final service = _bankDiscoveryService;
    if (service == null) return null;
    try {
      return await service.discoverIfEligible(
        rawSms: rawMessage,
        senderId: senderId,
        availableProfiles: bankProfiles,
        parseResult: parseResult,
        localeHint: localeHint,
      );
    } catch (_) {
      // Bank discovery is advisory only; parsing and local capture must continue.
      return null;
    }
  }

  Future<String> _effectiveInstallId() async {
    final cached = _installId;
    if (cached != null && cached.isNotEmpty) return cached;
    final loader = _loadInstallId;
    if (loader == null) return '';
    try {
      return await loader();
    } catch (_) {
      return '';
    }
  }

  Future<_AiFirstAttempt> _tryAiParseFirst({
    required String rawMessage,
    required String? senderId,
    required Future<void> Function() beforeRequest,
  }) async {
    if (_aiClient == null) return const _AiFirstAttempt.skipped('no_ai_client');
    final consent = await _loadAiConsent?.call() ?? false;
    if (!consent) return const _AiFirstAttempt.skipped('consent_off');
    final sid = senderId ?? '';

    final sanitized = SmsSanitizer.sanitize(
      rawMessage,
      detectedType: _privacyTypeHint(rawMessage),
    );
    // Immediately before the request: the account must be unchanged. Throws
    // (no request, nothing committed) — deliberately outside the catch below.
    await beforeRequest();
    AiParseResponse? response;
    String? failureReason;
    try {
      response = await _aiClient.parse(
        sanitizedSms: sanitized,
        senderId: sid,
        installId: await _effectiveInstallId(),
      );
    } on AiParseException catch (error) {
      failureReason = error.reason;
    } catch (_) {
      failureReason = 'unexpected_ai_error';
    }
    return _AiFirstAttempt(
      senderId: sid,
      sanitizedSms: sanitized,
      response: response,
      failureReason: failureReason,
    );
  }

  _AppliedAiParse? _applyAiResponse({
    required _AiFirstAttempt attempt,
    required String rawMessage,
    required ParsedTransaction? localParsed,
    required DateTime referenceTime,
  }) {
    final aiResponse = attempt.response;
    final sanitized = attempt.sanitizedSms;
    if (aiResponse == null || sanitized == null) return null;
    final validation = const AiCandidateValidator().validate(
      response: aiResponse,
      sanitizedText: sanitized,
      localParsed: localParsed,
      referenceTime: referenceTime,
      messageText: rawMessage,
      normalizedType: _normalizeAiType(
        rawMessage: rawMessage,
        categoryKey: aiResponse.categoryKey,
        fallback: _parseTypeFromString(aiResponse.type) ??
            localParsed?.type ??
            TransactionType.unknown,
        merchantName: aiResponse.merchantName,
      ),
    );
    if (!validation.accepted) {
      AiSenderFailureTracker.instance.recordFailure(attempt.senderId);
      return null;
    }

    AiSenderFailureTracker.instance.recordSuccess(attempt.senderId);
    final aiType = _normalizeAiType(
      rawMessage: rawMessage,
      categoryKey: aiResponse.categoryKey,
      fallback: _parseTypeFromString(aiResponse.type) ??
          localParsed?.type ??
          TransactionType.unknown,
      merchantName: validation.merchantName,
    );
    final aiCategoryKey = aiResponse.categoryKey;

    return _AppliedAiParse(
      categoryKey: aiCategoryKey,
      direction: _parseAiDirection(aiResponse.direction),
      transaction: ParsedTransaction(
        // Null means the old AI backend omitted amount_text: LEGACY_LOSSY and
        // pending review at the transaction construction boundary.
        amountText: aiResponse.amountText,
        amount: aiResponse.amount,
        currency: validation.currency,
        type: aiType,
        source: TransactionSource.aiParsed,
        rawMerchant: PaymentAggregators.resolveMerchant(
              validation.merchantName,
            ) ??
            localParsed?.rawMerchant,
        cardLast4: localParsed?.cardLast4,
        accountNumber: localParsed?.accountNumber,
        balanceAfterText: localParsed?.balanceAfterText,
        balanceAfter: localParsed?.balanceAfter,
        occurredAt: validation.occurredAt,
        foreignAmountText: localParsed?.foreignAmountText,
        foreignAmount: localParsed?.foreignAmount,
        foreignCurrency: localParsed?.foreignCurrency,
        fundingSource: localParsed?.fundingSource,
        parseConfidence: 0.79,
      ),
    );
  }

  static TransactionSourceEntity _mapSource(TransactionSource source) {
    switch (source) {
      case TransactionSource.bank:
        return TransactionSourceEntity.bank;
      case TransactionSource.card:
        return TransactionSourceEntity.card;
      case TransactionSource.wallet:
        return TransactionSourceEntity.wallet;
      case TransactionSource.unknown:
        return TransactionSourceEntity.unknown;
      case TransactionSource.aiParsed:
        return TransactionSourceEntity.aiParsed;
    }
  }

  static TransactionType _normalizeAiType({
    required String rawMessage,
    required String? categoryKey,
    required TransactionType fallback,
    String? merchantName,
  }) {
    final isTransferCategory = categoryKey == Categories.transfers.key;
    if (isTransferCategory || _looksLikeTransferMessage(rawMessage)) {
      return TransactionType.transfer;
    }
    return fallback;
  }

  /// An explicit own-account / internal transfer: money the user moves between
  /// their own accounts. Neutral — excluded from both income and expense.
  /// Public: the backend capture import (CaptureSyncService) applies the same
  /// transfer accounting without going through this use case.
  static bool looksLikeInternalTransfer(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    return lower.contains('internal transfer') ||
        lower.contains('own account') ||
        lower.contains('self transfer') ||
        lower.contains('between your accounts') ||
        lower.contains('تحويل داخلي') ||
        lower.contains('بين حساباتك') ||
        lower.contains('بين حساباتكم') ||
        lower.contains('لحسابك الآخر') ||
        lower.contains('من حسابك إلى حسابك');
  }

  static bool _looksLikeTransferMessage(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    return lower.contains('ipn transfer') ||
        lower.contains('ipn ref') ||
        lower.contains('instapay') ||
        lower.contains('transfer sent') ||
        lower.contains('transfer received') ||
        lower.contains('outward transfer') ||
        lower.contains('inward transfer') ||
        lower.contains('internal transfer') ||
        (lower.contains('credited by') && lower.contains(' from ')) ||
        lower.contains('received from') ||
        lower.contains('sent to') ||
        (lower.contains('debited by') && lower.contains(' to ')) ||
        lower.contains('انستاباي') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة');
  }

  static ParsedTransaction _replaceMerchant(
    ParsedTransaction transaction,
    String? rawMerchant,
  ) {
    return ParsedTransaction(
      amountText: transaction.amountText,
      amount: transaction.amount,
      currency: transaction.currency,
      type: transaction.type,
      source: transaction.source,
      rawMerchant: rawMerchant,
      cardLast4: transaction.cardLast4,
      accountNumber: transaction.accountNumber,
      balanceAfterText: transaction.balanceAfterText,
      balanceAfter: transaction.balanceAfter,
      occurredAt: transaction.occurredAt,
      foreignAmountText: transaction.foreignAmountText,
      foreignAmount: transaction.foreignAmount,
      foreignCurrency: transaction.foreignCurrency,
      fundingSource: transaction.fundingSource,
      parseConfidence: transaction.parseConfidence,
    );
  }

  static TransactionType? _privacyTypeHint(String rawMessage) {
    final lower = rawMessage.toLowerCase();
    final hasTransferWord = lower.contains('transfer') ||
        lower.contains('تحويل') ||
        lower.contains('حوالة');
    final hasPaymentWord = lower.contains('debit card') ||
        lower.contains('purchase') ||
        lower.contains('payment') ||
        lower.contains('successful transaction') ||
        lower.contains('transaction of') ||
        lower.contains('خصم') ||
        lower.contains('شراء') ||
        lower.contains('مشتريات') ||
        lower.contains('دفع');
    if (hasTransferWord) {
      return TransactionType.transfer;
    }
    if (lower.contains('salary') || lower.contains('راتب')) {
      return TransactionType.income;
    }
    if (hasPaymentWord) {
      return TransactionType.payment;
    }
    if (lower.contains('إلى') || lower.contains('الى')) {
      return TransactionType.transfer;
    }
    return null;
  }

  static ({String amountText, double heuristicAmount, String currency})?
      _extractAmountCurrency(String rawMessage) {
    const codes = 'EGP|SAR|AED|USD|EUR|GBP|KWD|QAR|BHD|OMR|JOD';
    const aliases = 'جم|جنيه';
    final currencyBefore = RegExp(
      '\\b($codes)\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)',
      caseSensitive: false,
    );
    final currencyAfter = RegExp(
      '([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*\\b($codes)\\b',
      caseSensitive: false,
    );
    final egyptianPoundAfter = RegExp(
      '([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(?:$aliases)',
      caseSensitive: false,
    );
    final amountWord = RegExp(
      '(?:amount(?:\\s+of)?|مبلغ)\\s*(?:of\\s*)?\\b($codes)\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)',
      caseSensitive: false,
    );

    final match = amountWord.firstMatch(rawMessage) ??
        currencyBefore.firstMatch(rawMessage);
    if (match != null) {
      return _amountCurrencyToken(match.group(2)!, match.group(1)!);
    }

    final reverse = currencyAfter.firstMatch(rawMessage);
    if (reverse != null) {
      return _amountCurrencyToken(reverse.group(1)!, reverse.group(2)!);
    }
    final egp = egyptianPoundAfter.firstMatch(rawMessage);
    if (egp != null) {
      return _amountCurrencyToken(egp.group(1)!, 'EGP');
    }
    return null;
  }

  static ({String amountText, double heuristicAmount, String currency})?
      _amountCurrencyToken(String token, String currency) {
    final heuristicAmount = double.tryParse(token.replaceAll(',', ''));
    if (heuristicAmount == null) return null;
    try {
      final amountText = normalizeLocalizedDecimal(token);
      return (
        amountText: amountText,
        heuristicAmount: heuristicAmount,
        currency: currency.toUpperCase(),
      );
    } on Exception {
      // Keep the lexical token so the construction boundary can explicitly
      // route an ambiguous fee through its pending LEGACY_LOSSY fallback.
      return (
        amountText: token,
        heuristicAmount: heuristicAmount,
        currency: currency.toUpperCase(),
      );
    }
  }

  static String _bestEffortMerchantCategory(String merchantName) {
    final upper = merchantName.toUpperCase();
    bool hasAny(Iterable<String> needles) =>
        needles.any((needle) => upper.contains(needle));

    if (hasAny(const [
      'CAFE',
      'COFFEE',
      'ESPRESSO',
      'BAKERY',
      'PATISSERIE',
      'كافيه',
      'قهوة',
      'مخبز',
    ])) {
      return Categories.cafes.key;
    }
    if (hasAny(const [
      'RESTAURANT',
      'REST',
      'BURGER',
      'PIZZA',
      'CHICKEN',
      'GRILL',
      'KITCHEN',
      'FOOD',
      'مطعم',
      'بيتزا',
      'برجر',
      'مشويات',
    ])) {
      return Categories.restaurants.key;
    }
    if (hasAny(const [
      'MARKET',
      'MART',
      'GROCERY',
      'SUPERMARKET',
      'HYPER',
      'BAQALA',
      'بقالة',
      'سوبر',
      'ماركت',
    ])) {
      return Categories.groceries.key;
    }
    if (hasAny(const [
      'PHARMACY',
      'PHARMA',
      'CLINIC',
      'HOSPITAL',
      'MEDICAL',
      'صيدلية',
      'عيادة',
      'مستشفى',
    ])) {
      return Categories.health.key;
    }
    if (hasAny(const [
      'PETROL',
      'FUEL',
      'GAS',
      'STATION',
      'بنزين',
      'وقود',
    ])) {
      return Categories.fuel.key;
    }
    if (hasAny(const [
      'UBER',
      'CAREEM',
      'TAXI',
      'BUS',
      'METRO',
      'TRAIN',
      'TRANSPORT',
      'تاكسي',
      'مترو',
      'مواصلات',
    ])) {
      return Categories.transport.key;
    }
    if (hasAny(const [
      'TELECOM',
      'MOBILE',
      'INTERNET',
      'ELECTRIC',
      'WATER',
      'UTILITY',
      'فاتورة',
      'كهرباء',
      'مياه',
      'انترنت',
    ])) {
      return Categories.bills.key;
    }
    if (hasAny(const ['GYM', 'FITNESS', 'SPORT', 'نادي', 'جيم'])) {
      return Categories.fitness.key;
    }
    if (hasAny(const ['SALON', 'BEAUTY', 'BARBER', 'SPA', 'صالون', 'حلاق'])) {
      return Categories.beauty.key;
    }
    if (hasAny(const [
      'HOTEL',
      'AIR',
      'TRAVEL',
      'FLIGHT',
      'TOUR',
      'فندق',
      'طيران',
      'سفر',
    ])) {
      return Categories.travel.key;
    }
    if (hasAny(const ['CINEMA', 'MOVIE', 'GAME', 'PLAY', 'سينما', 'العاب'])) {
      return Categories.entertainment.key;
    }
    return Categories.shopping.key;
  }

  static bool _looksLikeBankAtmCardTransaction(
    String rawMessage, {
    required String? merchantName,
  }) {
    if (merchantName == null || merchantName.trim().isEmpty) return false;
    final lower = rawMessage.toLowerCase();
    final hasDebitCard = lower.contains('debit card');
    final hasGenericTransaction = lower.contains('successful transaction') ||
        lower.contains('transaction of');
    if (!hasDebitCard || !hasGenericTransaction) return false;
    return BankProfiles.isBankMerchant(merchantName);
  }

  // An SMS date with no clock time parses as local midnight. On the day the
  // SMS arrived, the received time is closer than 12:00 AM; other days keep
  // the bare date.
  static DateTime? _keepReceivedTimeForBareDate(
      DateTime? fromSms, DateTime receivedAt) {
    if (fromSms == null) return null;
    final sms = fromSms.toLocal();
    final received = receivedAt.toLocal();
    final bareDate = sms.hour == 0 && sms.minute == 0 && sms.second == 0;
    final sameDay = sms.year == received.year &&
        sms.month == received.month &&
        sms.day == received.day;
    return bareDate && sameDay ? receivedAt : fromSms;
  }

  static TransactionType? _parseTypeFromString(String? raw) {
    switch (raw) {
      case 'payment':
        return TransactionType.payment;
      case 'withdrawal':
        return TransactionType.withdrawal;
      case 'transfer':
        return TransactionType.transfer;
      case 'income':
        return TransactionType.income;
      case 'refund':
        return TransactionType.refund;
      default:
        return null;
    }
  }

  static String? _dedupFingerprint(
    ParsedTransaction transaction, {
    required String rawMessage,
  }) {
    if (transaction.type != TransactionType.transfer) {
      return transaction.rawMerchant == null
          ? null
          : TransactionDedup.normalizeMerchant(transaction.rawMerchant!);
    }
    final reference = RegExp(
      r'(?:ref(?:erence)?#?|رقم\s*مرجعي)\s*:?\s*([A-Za-z0-9]+)',
      caseSensitive: false,
    ).firstMatch(rawMessage);
    if (reference != null) {
      return 'TRANSFER_REF_${reference.group(1)!.toUpperCase()}';
    }
    return 'TRANSFER_MSG_${TransactionDedup.normalizeMerchant(rawMessage)}';
  }

  static TransactionDirectionEntity? _parseAiDirection(String? raw) {
    return switch (raw) {
      'credit' => TransactionDirectionEntity.credit,
      'debit' => TransactionDirectionEntity.debit,
      'unknown' => TransactionDirectionEntity.unknown,
      _ => null,
    };
  }

  static TransactionDirectionEntity? _directionFromText(String rawMessage) {
    return switch (DirectionSignal.detect(rawMessage)) {
      TxnDirection.credit => TransactionDirectionEntity.credit,
      TxnDirection.debit => TransactionDirectionEntity.debit,
      TxnDirection.unknown => null,
    };
  }

  static TransactionDirectionEntity _directionFromType(TransactionType type) {
    return switch (DirectionSignal.ofType(type)) {
      TxnDirection.credit => TransactionDirectionEntity.credit,
      TxnDirection.debit => TransactionDirectionEntity.debit,
      TxnDirection.unknown => TransactionDirectionEntity.unknown,
    };
  }

  static TransactionTypeEntity _mapType(TransactionType type) {
    switch (type) {
      case TransactionType.payment:
        return TransactionTypeEntity.payment;
      case TransactionType.withdrawal:
        return TransactionTypeEntity.withdrawal;
      case TransactionType.transfer:
        return TransactionTypeEntity.transfer;
      case TransactionType.refund:
        return TransactionTypeEntity.refund;
      case TransactionType.income:
        return TransactionTypeEntity.income;
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return TransactionTypeEntity.payment;
      case TransactionType.unknown:
        return TransactionTypeEntity.unknown;
    }
  }
}

class SaveManualTransactionUseCase {
  SaveManualTransactionUseCase({
    required TransactionRepository transactionRepository,
    RecordEngagementUseCase? recordEngagementUseCase,
    Future<void> Function(String key, {String? dimension})? logMetric,
    AccountRepository? accountRepository,
    SuspectedDuplicateRepository? suspectedDuplicateRepository,
  })  : _transactionRepository = transactionRepository,
        _recordEngagementUseCase = recordEngagementUseCase,
        _logMetric = logMetric,
        _accountRepository = accountRepository,
        _suspectedDuplicateRepository = suspectedDuplicateRepository;

  final TransactionRepository _transactionRepository;
  final RecordEngagementUseCase? _recordEngagementUseCase;
  final Future<void> Function(String key, {String? dimension})? _logMetric;
  final AccountRepository? _accountRepository;
  final SuspectedDuplicateRepository? _suspectedDuplicateRepository;

  Future<TransactionEntity> call({
    required Money amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String categoryKey,
    String? merchant,
    String? note,
    String? accountId,
    String? cardLast4,
  }) async {
    final now = DateTime.now().toUtc();
    final normalizedCurrency = currency.trim().toUpperCase();
    if (amount.currency != normalizedCurrency) {
      throw ArgumentError(
          'manual amount currency ${amount.currency} does not match $normalizedCurrency');
    }
    final normalizedMerchant = merchant?.trim();
    final normalizedNote = note?.trim();
    final comparisonTimestamp = occurredAt.toUtc();
    final description = normalizedMerchant == null || normalizedMerchant.isEmpty
        ? (normalizedNote == null || normalizedNote.isEmpty
            ? 'Manual transaction'
            : normalizedNote)
        : normalizedMerchant;
    final possibleDuplicate =
        await _transactionRepository.findSuspiciousDuplicate(
      amount: amount,
      currency: normalizedCurrency,
      merchantOrDescription: description,
      cardLast4: cardLast4,
      comparisonTimestamp: comparisonTimestamp,
    );
    if (possibleDuplicate != null && _suspectedDuplicateRepository != null) {
      final rawMessage = _manualRawMessage(
        amount: amount,
        currency: normalizedCurrency,
        merchant: normalizedMerchant,
        note: normalizedNote,
        occurredAt: comparisonTimestamp,
      );
      await _suspectedDuplicateRepository.save(SuspectedDuplicateEntity(
        id: IdGenerator.next(),
        rawMessage: rawMessage,
        senderId: null,
        existingTransactionId: possibleDuplicate.id,
        amountMoney: amount,
        currency: normalizedCurrency,
        rawMerchant: normalizedMerchant,
        occurredAt: comparisonTimestamp,
        cardLast4: cardLast4,
        comparisonTimestamp: comparisonTimestamp,
        comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
        duplicateReason:
            'same amount, currency, merchant and manual comparison time',
        createdAt: now,
      ));
      return possibleDuplicate;
    }
    final effectiveAccount = accountId == null
        ? await _accountForCurrency(_accountRepository, normalizedCurrency)
        : null;
    final transaction = TransactionEntity(
      id: IdGenerator.next(),
      amountMoney: amount,
      currency: normalizedCurrency,
      accountId: accountId ?? effectiveAccount?.id,
      merchantId: null,
      rawMerchant: normalizedMerchant == null || normalizedMerchant.isEmpty
          ? null
          : normalizedMerchant,
      categoryId: null,
      type: type,
      source: TransactionSourceEntity.unknown,
      cardLast4: (cardLast4 == null || cardLast4.isEmpty) ? null : cardLast4,
      note: normalizedNote == null || normalizedNote.isEmpty
          ? null
          : normalizedNote,
      occurredAt: occurredAt.toUtc(),
      rawMessage: normalizedNote == null || normalizedNote.isEmpty
          ? 'Manual transaction'
          : normalizedNote,
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
      smsReceivedAt: now,
      comparisonTimestamp: comparisonTimestamp,
      comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
      duplicateStatus: DuplicateStatus.normal,
    );

    final saved = await _transactionRepository.saveTransaction(
      transaction: transaction,
      categoryKey: categoryKey,
    );
    if (_recordEngagementUseCase != null) {
      await _recordEngagementUseCase(
        action: EngagementAction.transactionConfirmed,
        occurredAt: saved.occurredAt,
      );
    }
    await _logMetric?.call('manual_transaction_added');
    return saved;
  }

  String _manualRawMessage({
    required Money amount,
    required String currency,
    required String? merchant,
    required String? note,
    required DateTime occurredAt,
  }) {
    final buffer = StringBuffer()
      ..writeln('Manual transaction')
      ..writeln('مبلغ:$currency ${amount.toDecimalString()}');
    if (merchant != null && merchant.isNotEmpty) {
      buffer.writeln('لدى:$merchant');
    }
    if (note != null && note.isNotEmpty) {
      buffer.writeln('ملاحظة:$note');
    }
    buffer.writeln('في:${occurredAt.toIso8601String().substring(0, 16)}');
    return buffer.toString().trim();
  }
}
