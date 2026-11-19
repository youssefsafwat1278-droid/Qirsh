// Round 5 (owner decision): the frozen money acceptance set
// (tools/acceptance/money_cases.jsonl) through the device's FINAL effect —
// the saved row, the dashboard totals and the review list — with the real
// CaptureImportService, CaptureSyncService and AddTransactionUseCase on an
// in-memory database, in three modes:
//   ai_off              the device alone (Cloud and AI off);
//   ai_correct          an AI-primary server row carrying the right answer
//                       (a processed row for a completed movement, a
//                       rejected "unclear" row otherwise, an ignored row for
//                       an OTP or advert);
//   ai_wrong_completed  a server row (AI-primary, and the rule parse) forged
//                       as "completed" with a figure of the text;
//   ai_flipped          the same forged row with the direction flipped.
// Rows marked model_dependent (a wrong "completed" on a text with no doubt
// and no known completed wording) are counted apart, not hidden.
// Acceptance: zero wrong financial entries and zero silent losses in every
// mode; unnecessary reviews are counted and printed, not failures.
// Synthetic messages only. ACCEPTANCE_OUT=<file> writes the per-row result.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/parser/completion_certainty.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../domain/local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<bool> isLinkedForCloud() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

/// The import path makes no AI request of its own; counted.
class _SpyAi implements AiParserClient {
  int calls = 0;
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    calls++;
    return null;
  }
}

class _Queue implements CaptureImportQueue {
  final List<SharedCapturedMessage> items = [];
  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);
  @override
  Future<bool> acknowledge(String payloadId) async {
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _Server implements CaptureServerPort {
  _Server(this.fetch);
  final CaptureServerFetch fetch;
  @override
  Future<CaptureServerFetch> fetchResults() async => fetch;
  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async =>
      CaptureUploadStatus.unavailable;
  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}

const _id = '00000000000000000000000000000000000000000000000000000000000000a5';
final _received = DateTime.utc(2026, 11, 17, 9, 45);

List<Map<String, dynamic>> _rows() => File('../tools/acceptance/money_cases.jsonl')
    .readAsLinesSync()
    .where((l) => l.trim().isNotEmpty)
    .map((l) => jsonDecode(l) as Map<String, dynamic>)
    .toList();

/// What the device ended with.
typedef _Observed = ({String outcome, String? cls, double? amount, String? currency, int rows, String? reason});

/// A second confirmed row that is the fee the message states separately
/// ("Fee SAR 3.58", «رسوم 0.58 ريال»): the money did leave; not a wrong entry.
bool _isStatedFee(String text, double amount) => RegExp(
            r'(?:fee|رسوم)[^0-9\n]{0,15}([0-9][0-9,]*(?:\.[0-9]+)?)',
            caseSensitive: false)
        .allMatches(text)
        .any((m) =>
            ((double.tryParse(m.group(1)!.replaceAll(',', '')) ?? -1) - amount)
                .abs() <
            0.005);

String _classOf(TransactionEntity t) {
  // A transfer row is neutral: it never enters the spending or income totals.
  if (t.type == TransactionTypeEntity.transfer) return 'transfer';
  if (t.direction == TransactionDirectionEntity.credit) return 'credit';
  if (t.direction == TransactionDirectionEntity.debit) return 'debit';
  return t.type == TransactionTypeEntity.income ||
          t.type == TransactionTypeEntity.refund
      ? 'credit'
      : 'debit';
}

/// ok / wrong / silent / unnecessary_review / extra_review, and
/// model_dependent: a wrong entry on a row marked so (a forged answer that is
/// by construction indistinguishable from a right one — reported, not hidden).
String _grade(Map<String, dynamic> e, _Observed o) {
  final g = _gradeOf(e, o);
  return g == 'wrong' && e['model_dependent'] == true ? 'model_dependent' : g;
}

String _gradeOf(Map<String, dynamic> e, _Observed o) {
  // alt: a recorded outcome that is not a wrong entry (the original-currency
  // figure of a foreign purchase; the paid total of a tip message).
  final alt = (e['alt'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
  if (o.outcome == 'recorded' &&
      o.rows == 1 &&
      alt.any((a) =>
          a['class'] == o.cls &&
          a['currency'] == o.currency &&
          ((a['amount'] as num) - o.amount!).abs() < 0.005)) {
    return 'ok_alt';
  }
  switch (e['outcome']) {
    case 'recorded':
      if (o.outcome == 'ignored') return 'silent';
      if (o.outcome == 'review') return 'unnecessary_review';
      if (o.rows != 1 || o.cls != e['class']) return 'wrong';
      final amount = e['amount'] as num?;
      if (amount != null && (o.amount! - amount).abs() > 0.005) return 'wrong';
      final currency = e['currency'] as String?;
      if (currency != null && o.currency != currency) return 'wrong';
      return 'ok';
    case 'review':
      if (o.outcome == 'recorded') return 'wrong';
      return o.outcome == 'ignored' ? 'silent' : 'ok';
    default: // ignored
      if (o.outcome == 'recorded') return 'wrong';
      return o.outcome == 'review' ? 'extra_review' : 'ok';
  }
}

ProcessedCaptureDto _row(String text, Map<String, dynamic> answer,
        {required bool ai}) =>
    ProcessedCaptureDto(
      payloadId: _id,
      status: 'processed',
      state: 'processed',
      parsed: {
        'amount': answer['amount'],
        'amount_text': answer['amount_text'],
        'currency': answer['currency'],
        'direction': answer['direction'],
        'type': answer['type'],
        'category': answer['type'] == 'payment' ? 'shopping' : 'other',
        'rawMessage': text,
        'parserSource': ai ? 'ai' : 'deterministic',
        'confidence': 0.95,
      },
      notification: const {},
    );

ProcessedCaptureDto _rejected({bool ignored = false}) => ProcessedCaptureDto(
      payloadId: _id,
      status: 'rejected',
      state: 'rejected',
      parsed: ignored
          ? const {'parserSource': 'ai_ignored'}
          : const {'parserSource': 'ai', 'reviewReason': 'model_unclear'},
      notification: const {},
    );

/// The right answer of a model for [r] (mode ai_correct). A transfer never
/// reaches the model: the server decides it on its own reading (covered end
/// to end by process-ios-sms/round5_money_acceptance_test.ts); here it is the
/// conservative server outcome, a review row.
ProcessedCaptureDto _correct(Map<String, dynamic> r) {
  final e = r['expected']['ai_correct'] as Map<String, dynamic>;
  final f = r['forged'] as Map<String, dynamic>?;
  if (CompletionCertainty.isTransfer(r['text'] as String)) {
    return _rejected();
  }
  if (e['outcome'] != 'recorded' || f == null) {
    return _rejected(ignored: e['outcome'] == 'ignored');
  }
  final cls = e['class'] as String;
  return _row(
      r['text'] as String,
      {
        ...f,
        'direction': cls == 'credit' ? 'credit' : 'debit',
        'type': cls == 'transfer'
            ? 'transfer'
            : cls == 'credit'
                ? (f['type'] == 'refund' ? 'refund' : 'income')
                : 'payment',
      },
      ai: true);
}

/// The forged "completed" server row (mode ai_wrong_completed); null when the
/// text has no figure to forge. A transfer never reaches the model, so the
/// server holds it on its own reading (as in [_correct]).
CaptureServerFetch? _forged(Map<String, dynamic> r, {required bool ai}) {
  final f = r['forged'] as Map<String, dynamic>?;
  if (f == null) return null;
  return CaptureServerFetch(CaptureFetchStatus.ok, {
    _id: CompletionCertainty.isTransfer(r['text'] as String)
        ? _rejected()
        : _row(r['text'] as String, f, ai: ai)
  });
}

/// The forged server row with the direction flipped (mode ai_flipped); null
/// when the row has no ai_flipped expectation (no figure, or not a debit or
/// credit). A transfer never reaches the model (as in [_forged]).
CaptureServerFetch? _flipped(Map<String, dynamic> r, {required bool ai}) {
  final f = r['forged'] as Map<String, dynamic>?;
  if (f == null || r['expected']['ai_flipped'] == null) return null;
  final credit = f['direction'] == 'credit';
  return CaptureServerFetch(CaptureFetchStatus.ok, {
    _id: CompletionCertainty.isTransfer(r['text'] as String)
        ? _rejected()
        : _row(
            r['text'] as String,
            {
              ...f,
              'direction': credit ? 'debit' : 'credit',
              'type': credit ? 'payment' : 'refund',
            },
            ai: ai)
  });
}

void main() {
  // ACCEPTANCE_ONLY=<id>,<id> runs those rows only (investigation).
  final only = Platform.environment['ACCEPTANCE_ONLY']?.split(',').toSet();
  final rows =
      _rows().where((r) => only == null || only.contains(r['id'])).toList();
  final out = Platform.environment['ACCEPTANCE_OUT'];
  final results = <String, Map<String, String>>{};

  Future<_Observed> run(Map<String, dynamic> r,
      {required CaptureServerFetch fetch, required bool aiPrimary}) async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    try {
      final txRepo = DriftTransactionRepository(db,
          outboxQueue: LedgerOutboxQueue(
              db: db,
              isPushEnabled: () => false,
              getAuthUserId: () async => 'user-A'));
      final rules = DriftMerchantCategoryRepository(db);
      final inbox = DriftSmartInboxRepository(db);
      final sync = CaptureSyncService(
        settingsRepository: DriftUserSettingsRepository(db),
        transactionRepository: txRepo,
        dedupStore: DriftDedupStore(db),
        smartInboxRepository: inbox,
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        registrationService: _Registration(),
        ownershipGuard: _Guard(),
        currentUserId: () => 'user-A',
        accountRepository: DriftAccountRepository(db),
        merchantCategoryRepository: rules,
        backendConfigured: true,
        loadInstallId: () async => 'install',
      );
      final ai = _SpyAi();
      final queue = _Queue()
        ..items.add(SharedCapturedMessage(
            id: _id,
            text: r['text'] as String,
            sender: r['sender'] as String?,
            source: CapturedMessageSource.iosShortcut,
            receivedAt: _received,
            status: 'sent',
            ownerUid: 'user-A'));
      final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: rules,
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        aiClient: ai,
        loadAiConsent: () async => false,
        installId: 'install',
      ));
      await CaptureImportService(
        queue: queue,
        server: _Server(fetch),
        captureSyncService: sync,
        receipts: CaptureReceipts(db),
        ingestLocal: CaptureImportService.localIngest(ingest),
        sessionUid: () => 'user-A',
        replicaOwnerUid: () async => 'user-A',
        ownershipGuard: _Guard(),
        aiPrimarySelected: aiPrimary ? () async => true : null,
      ).run();
      expect(ai.calls, 0, reason: 'the import path makes no AI request');
      final saved = (await txRepo.getAll())
          .where((t) => t.status == TransactionStatus.confirmed)
          .toList();
      final open = (await inbox.getOpen()).where((i) => i.payloadId == _id);
      if (saved.isNotEmpty) {
        // The movement is the largest row; a further row may only be the fee
        // the message states (reported as `fee_row`).
        saved.sort((a, b) => b.amount.compareTo(a.amount));
        final t = saved.first;
        final feeRows = saved.length > 1 &&
            saved.skip(1).every(
                (x) => _isStatedFee(r['text'] as String, x.amount.toDouble()));
        // A confirmed spending or income row moves the dashboard totals (a
        // neutral transfer does not).
        var counted = true;
        if (_classOf(t) != 'transfer') {
          final totals = await txRepo.currencyTotalsBetween(
              from: DateTime.utc(2000), to: DateTime.utc(2100));
          counted = totals.any(
              (x) => x.expense.minorUnits != 0 || x.income.minorUnits != 0);
        }
        // A foreign-currency spend parked at 0 awaits its home value: it is
        // read at its own figure (reported as `awaiting_fx`).
        final parked = t.pricingState == TransactionPricingState.awaitingFx;
        return (
          outcome: 'recorded',
          cls: _classOf(t),
          amount: parked ? t.foreignAmount : t.amount.toDouble(),
          currency: parked ? t.foreignCurrency : t.currency,
          rows: feeRows ? 1 : saved.length,
          reason: parked
              ? 'awaiting_fx'
              : !counted
              ? 'not_in_totals'
              : feeRows
                  ? 'fee_row'
                  : null
        );
      }
      // Nothing confirmed: the totals are untouched.
      final totals = await txRepo.currencyTotalsBetween(
          from: DateTime.utc(2000), to: DateTime.utc(2100));
      if (!totals.every(
          (t) => t.expense.minorUnits == 0 && t.income.minorUnits == 0)) {
        return (
          outcome: 'recorded',
          cls: 'unconfirmed_in_totals',
          amount: null,
          currency: null,
          rows: 0,
          reason: null
        );
      }
      if (open.isNotEmpty) {
        return (
          outcome: 'review',
          cls: null,
          amount: null,
          currency: null,
          rows: 0,
          reason: null
        );
      }
      // A pending (unconfirmed) row would be visible too.
      final pending = await txRepo.getAll();
      return (
        outcome: pending.isEmpty ? 'ignored' : 'review',
        cls: null,
        amount: null,
        currency: null,
        rows: 0,
        reason: null
      );
    } finally {
      await db.close();
    }
  }

  final paths = <String, (String mode, bool aiPrimary,
      CaptureServerFetch? Function(Map<String, dynamic>))>{
    'ai_off (device alone)': (
      'ai_off',
      false,
      (_) => const CaptureServerFetch(CaptureFetchStatus.notConfigured)
    ),
    'ai_correct (AI-primary row)': (
      'ai_correct',
      true,
      (r) => CaptureServerFetch(CaptureFetchStatus.ok, {_id: _correct(r)})
    ),
    'ai_wrong_completed (AI-primary row)': (
      'ai_wrong_completed',
      true,
      (r) => _forged(r, ai: true)
    ),
    'ai_wrong_completed (rule-parse row)': (
      'ai_wrong_completed',
      false,
      (r) => _forged(r, ai: false)
    ),
    'ai_flipped (AI-primary row)': (
      'ai_flipped',
      true,
      (r) => _flipped(r, ai: true)
    ),
    'ai_flipped (rule-parse row)': (
      'ai_flipped',
      false,
      (r) => _flipped(r, ai: false)
    ),
  };

  for (final MapEntry(key: name, value: (mode, aiPrimary, fetchOf))
      in paths.entries) {
    test('acceptance set — $name: no wrong entry, no silent loss', () async {
      final counts = <String, int>{};
      final failures = <String>[];
      final notInTotals = <String>[];
      for (final r in rows) {
        final fetch = fetchOf(r);
        if (fetch == null) continue; // no figure to forge
        final o = await run(r, fetch: fetch, aiPrimary: aiPrimary);
        final e = r['expected'][mode] as Map<String, dynamic>;
        final g = _grade(e, o);
        counts[g] = (counts[g] ?? 0) + 1;
        if (o.reason == 'awaiting_fx') {
          counts['recorded_awaiting_fx'] = (counts['recorded_awaiting_fx'] ?? 0) + 1;
        }
        if (o.reason == 'fee_row') {
          counts['with_stated_fee_row'] = (counts['with_stated_fee_row'] ?? 0) + 1;
        }
        if (o.reason == 'not_in_totals') {
          counts['recorded_not_in_totals'] =
              (counts['recorded_not_in_totals'] ?? 0) + 1;
          notInTotals.add('${r['id']}: ${r['text']}');
        }
        (results[r['id'] as String] ??= {})[name] =
            '$g ${o.outcome}${o.cls == null ? '' : ' ${o.cls} ${o.amount} ${o.currency}'}';
        if (g == 'wrong' || g == 'silent') {
          failures.add('$g ${r['id']}: expected ${jsonEncode(e)}, got '
              '${o.outcome} ${o.cls ?? ''} ${o.amount ?? ''} ${o.currency ?? ''} '
              '(rows ${o.rows}) — ${r['text']}');
        }
      }
      // ignore: avoid_print
      print('ROUND5 DEVICE $name: ${jsonEncode(counts)}');
      // ignore: avoid_print
      if (notInTotals.isNotEmpty) print('NOT IN TOTALS:\n${notInTotals.join('\n')}');
      if (out != null) {
        File('$out.${mode}_${aiPrimary ? 'primary' : 'rule'}.json')
            .writeAsStringSync(jsonEncode(results));
      }
      expect(failures, isEmpty, reason: failures.join('\n'));
    }, timeout: const Timeout(Duration(minutes: 30)));
  }
}
