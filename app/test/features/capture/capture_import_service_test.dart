// CAP-5 — CaptureImportService (gate G3 T-I1..T-I6): triple-equality guard,
// receipt-or-transaction check, ValidatedCapture v1 server import, Q5
// local-after-reject, no AI, ACK only after commit, quiescence barrier.
//
// Real in-memory Drift DB, real repositories, real AddTransactionUseCase /
// CaptureSyncService; only the native queue, the server and the session are
// fakes.
import 'dart:async';

import 'package:drift/drift.dart' show Variable;
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

/// The admission of user-A, revocable by the test.
class _Guard extends OwnershipGuard {
  _Guard(this.isLive);
  final bool Function() isLive;
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async =>
      isLive() && token == _token;
}

/// Counts every AI request; the iOS import path must make none.
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

class _FakeQueue implements CaptureImportQueue {
  final List<SharedCapturedMessage> items = [];
  final acked = <String>[];
  Future<void> Function(String id)? onAck;
  bool ackThrows = false;

  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);

  @override
  Future<bool> acknowledge(String payloadId) async {
    await onAck?.call(payloadId);
    if (ackThrows) throw StateError('killed before native ack');
    acked.add(payloadId);
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _FakeServer implements CaptureServerPort {
  CaptureServerFetch fetch = const CaptureServerFetch(CaptureFetchStatus.ok);
  CaptureServerFetch? refetch;
  CaptureUploadStatus upload = CaptureUploadStatus.unavailable;
  final acks = <List<String>>[];
  var fetches = 0;
  var uploads = 0;
  Future<void> Function(List<String> ids)? onAck;

  @override
  Future<CaptureServerFetch> fetchResults() async =>
      (fetches++ > 0 ? refetch : null) ?? fetch;

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async {
    uploads++;
    return upload;
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {
    await onAck?.call(payloadIds);
    acks.add(payloadIds);
  }
}

const _raw = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _unparseable = 'Your transaction could not be completed. Call us.';
// REV-03: the same layout as [_raw], but the purchase was declined.
const _declinedRaw = 'تم رفض عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
final _received = DateTime.utc(2026, 4, 8, 9, 45);
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

ProcessedCaptureDto _processed(String id, {String amount = '45.00'}) =>
    ProcessedCaptureDto(
      payloadId: id,
      status: 'processed',
      state: 'processed',
      parsed: {
        'amount': double.parse(amount),
        'amount_text': amount,
        'currency': 'SAR',
        'direction': 'debit',
        'type': 'payment',
        'merchant': 'NETFLIX',
        'last4': '4521',
        'occurredAt': '2026-04-08T09:45:00.000Z',
        'rawMessage': 'sanitized',
        'parserSource': 'deterministic',
        'confidence': 0.95,
      },
      notification: const {},
    );

ProcessedCaptureDto _rejected(String id) => ProcessedCaptureDto(
      payloadId: id,
      status: 'rejected',
      state: 'rejected',
      parsed: const {},
      notification: const {},
      sanitizedText: 'redacted',
      failureReason: 'not_parseable',
    );

void main() {
  late AppDatabase db;
  late CaptureSyncService sync;
  late _FakeQueue queue;
  late _FakeServer server;
  late _SpyAi ai;
  late DriftTransactionRepository txRepo;
  String? sessionUid;
  String? replicaUid;
  var admissionCurrent = true;
  var ingestCalls = 0;
  Future<void> Function()? beforeIngest;

  SharedCapturedMessage item(
    String id, {
    String text = _raw,
    String? owner = 'user-A',
    String? status = 'sent',
    String? failureReason,
    bool? localOnly,
  }) =>
      SharedCapturedMessage(
        id: id,
        text: text,
        sender: 'SNB',
        source: CapturedMessageSource.iosShortcut,
        receivedAt: _received,
        status: status,
        failureReason: failureReason,
        ownerUid: owner,
        localOnly: localOnly,
      );

  CaptureImportService buildService(
      {bool aiPrimary = false, bool parkWithoutSmartAnalysis = false}) {
    final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      // The AI client is wired and consent is granted on purpose: the import
      // path must still never reach it.
      aiClient: ai,
      loadAiConsent: () async => true,
      installId: 'install',
    ));
    final inner = CaptureImportService.localIngest(ingest);
    return CaptureImportService(
      queue: queue,
      server: server,
      captureSyncService: sync,
      receipts: CaptureReceipts(db),
      ingestLocal: (m, c) async {
        ingestCalls++;
        await beforeIngest?.call();
        return inner(m, c);
      },
      sessionUid: () => sessionUid,
      replicaOwnerUid: () async => replicaUid,
      ownershipGuard: _Guard(() => admissionCurrent),
      aiPrimarySelected: aiPrimary ? () async => true : null,
      parkWithoutSmartAnalysis: parkWithoutSmartAnalysis,
    );
  }

  Future<List<String>> txIds() async =>
      (await db.customSelect('SELECT id FROM transactions ORDER BY id;').get())
          .map((r) => r.read<String>('id'))
          .toList();

  Future<int> count(String table, [String where = '1=1']) async => (await db
          .customSelect('SELECT COUNT(*) c FROM $table WHERE $where;')
          .getSingle())
      .read<int>('c');

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    sync = CaptureSyncService(
      settingsRepository: DriftUserSettingsRepository(db),
      transactionRepository: txRepo,
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(() => true),
      currentUserId: () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      backendConfigured: true,
      loadInstallId: () async => 'install',
    );
    queue = _FakeQueue();
    server = _FakeServer();
    ai = _SpyAi();
    sessionUid = 'user-A';
    replicaUid = 'user-A';
    admissionCurrent = true;
    ingestCalls = 0;
    beforeIngest = null;
  });

  tearDown(() async => db.close());

  test('WP-8: the service remembers the outcome of its latest run only',
      () async {
    final service = buildService();
    expect(service.lastReport, isNull);
    queue.items.addAll([item(_id(1)), item(_id(2), owner: 'user-B')]);
    final report = await service.run();
    expect(service.lastReport, same(report));
    expect(service.lastReport!.skippedForeignOwner, 1);
    expect(service.lastReport!.imported, hasLength(1));
    await service.run();
    expect(service.lastReport!.imported, isEmpty,
        reason: 'the second run found nothing new');
  });

  group('triple-equality guard (capture.owner == replica owner == session)',
      () {
    test('items stamped to another uid, or unstamped, are skipped and left',
        () async {
      queue.items.addAll([
        item(_id(1)),
        item(_id(2), owner: 'user-B'),
        item(_id(3), owner: null),
      ]);
      final report = await buildService().run();

      expect(await txIds(), [_id(1)]);
      expect(report.skippedForeignOwner, 2);
      expect(queue.items.map((m) => m.id), [_id(2), _id(3)],
          reason: 'foreign items stay in the queue untouched');
    });

    test('replica owner != session uid: nothing is imported or consumed',
        () async {
      replicaUid = 'user-B';
      queue.items.add(item(_id(1)));
      final report = await buildService().run();

      expect(report.guardFailed, isTrue);
      expect(await txIds(), isEmpty);
      expect(queue.items, hasLength(1));
      expect(server.fetches, 0, reason: 'no server call under a failed guard');
    });

    test('no session or no replica owner: nothing runs', () async {
      queue.items.add(item(_id(1)));
      sessionUid = null;
      expect((await buildService().run()).guardFailed, isTrue);
      sessionUid = 'user-A';
      replicaUid = null;
      expect((await buildService().run()).guardFailed, isTrue);
      expect(await txIds(), isEmpty);
      expect(ingestCalls, 0);
    });

    test('a rotated admission (same-uid re-login) stops the run', () async {
      queue.items.add(item(_id(1)));
      admissionCurrent = false;

      final report = await buildService().run();

      expect(report.guardFailed, isTrue);
      expect(await txIds(), isEmpty);
      expect(queue.items, hasLength(1));
    });

    test('the owner changing inside the import transaction rolls it back',
        () async {
      queue.items.add(item(_id(1)));
      beforeIngest = () async => sessionUid = 'user-B';
      final report = await buildService().run();

      expect(report.guardFailed, isTrue);
      expect(await txIds(), isEmpty, reason: 'A capture never lands under B');
      expect(await count('dedup_hashes', "hash LIKE 'capture_payload:%'"), 0);
      expect(queue.items, hasLength(1));
      expect(queue.acked, isEmpty);
    });
  });

  group('receipt-or-transaction exists: consume without re-import', () {
    test('receipt exists (no transaction): consumed, no ingest, ACKed',
        () async {
      await sync.markPayloadImported(
          payloadId: _id(1), transactionId: 'smart_inbox:x');
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

      final report = await buildService().run();

      expect(ingestCalls, 0);
      expect(await txIds(), isEmpty);
      expect(queue.acked, [_id(1)]);
      expect(server.acks.single, [_id(1)]);
      expect(report.imported.single.path, CaptureImportPath.alreadyImported);
      expect(report.imported.single.committedTransactions, isEmpty);
    });

    test('transaction with id == capture_id exists (no receipt): consumed',
        () async {
      await db.customStatement(
          "INSERT INTO transactions(id, amount, amount_minor, currency, type, source, occurred_at, raw_message, parse_confidence, status, created_at, updated_at, direction) "
          "VALUES ('${_id(1)}', 1, 100, 'SAR', 'payment', 'bank', '2026-04-08T00:00:00Z', 'x', 0.9, 'confirmed', '2026-04-08T00:00:00Z', '2026-04-08T00:00:00Z', 'debit');");
      queue.items.add(item(_id(1)));

      await buildService().run();

      expect(ingestCalls, 0);
      expect(await txIds(), [_id(1)]);
      expect(queue.acked, [_id(1)]);
    });

    test('a receipt outlives the deleted transaction: no resurrection',
        () async {
      final svc = buildService();
      queue.items.add(item(_id(1)));
      await svc.run();
      expect(await txIds(), [_id(1)]);
      await db
          .customStatement("DELETE FROM transactions WHERE id = '${_id(1)}';");
      queue.items.add(item(_id(1)));
      final before = ingestCalls;

      await svc.run();

      expect(ingestCalls, before);
      expect(await txIds(), isEmpty);
    });

    test('an old-build rejected: marker without its review row is not proof',
        () async {
      await sync.markPayloadImported(
          payloadId: _id(1), transactionId: 'rejected:old');
      queue.items.add(item(_id(1)));

      await buildService().run();

      expect(await txIds(), [_id(1)], reason: 'imported, not silently dropped');
    });
  });

  group('crash between import and ACK', () {
    test('killed before the native ack: next run acks only (no double import)',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _rejected(_id(1))});
      queue.ackThrows = true;
      final svc = buildService();

      final first = await svc.run();
      expect(first.skippedAwaiting, 1, reason: 'the throw left it queued');
      expect(await txIds(), [_id(1)], reason: 'committed with its receipt');
      expect(await count('ledger_sync_outbox'), 1);
      expect(server.acks.single, [_id(1)],
          reason: 'the receipt committed, so the server row may be ACKed');

      queue.ackThrows = false;
      final before = ingestCalls;
      await svc.run();

      expect(ingestCalls, before, reason: 'no second ingest');
      expect(await txIds(), [_id(1)]);
      expect(await count('ledger_sync_outbox'), 1);
      expect(queue.items, isEmpty);
      expect(server.acks, everyElement([_id(1)]));
    });

    test('a lost server ACK is repeated; the capture is not imported again',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});
      var failOnce = true;
      server.onAck = (_) async {
        if (failOnce) {
          failOnce = false;
          throw StateError('response lost');
        }
      };
      final svc = buildService();

      await svc.run(); // import committed, ACK lost
      expect(await txIds(), [_id(1)]);
      expect(queue.items, isEmpty);

      await svc.run(); // the server still lists it; the receipt short-circuits
      expect(await txIds(), [_id(1)]);
      expect(await count('ledger_sync_outbox'), 1);
      expect(server.acks.single, [_id(1)]);
    });

    test('native removal and server ACK both happen AFTER the commit',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});
      int? txAtNativeAck;
      int? txAtServerAck;
      queue.onAck = (_) async => txAtNativeAck = await count('transactions');
      server.onAck = (_) async => txAtServerAck = await count('transactions');

      await buildService().run();

      expect(txAtNativeAck, 1);
      expect(txAtServerAck, 1);
    });

    test('an ingest failure persists nothing and acks nothing', () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _rejected(_id(1))});
      beforeIngest = () async => throw StateError('boom');

      final report = await buildService().run();

      expect(report.skippedAwaiting, 1);
      expect(await txIds(), isEmpty);
      expect(queue.acked, isEmpty);
      expect(server.acks, isEmpty);
    });
  });

  // Gemini-first phase 3, as wired in production: without Smart Analysis
  // nothing is recorded on the device's own reading; the message waits in
  // Smart Inbox (the analysis log's "awaiting analysis — turn on Smart
  // Analysis") and nothing is uploaded or sent to AI.
  group('phase 3: Smart Analysis off (production wiring)', () {
    Future<String?> reasonOf(String id) async {
      final row = await db
          .customSelect(
              "SELECT metadata_json FROM smart_inbox_items WHERE payload_id = '$id';")
          .getSingleOrNull();
      final m = RegExp(r'"review_reason":"([a-z_]+)"')
          .firstMatch(row?.read<String?>('metadata_json') ?? '');
      return m?.group(1);
    }

    test('a capture waits as awaiting analysis; nothing sent, nothing recorded',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.notConfigured);

      await buildService(parkWithoutSmartAnalysis: true).run();

      expect(await txIds(), isEmpty);
      expect(ingestCalls, 0, reason: 'the device reading records nothing');
      expect(server.uploads, 0);
      expect(await reasonOf(_id(1)), 'smart_analysis_off');
      expect(queue.items, isEmpty, reason: 'kept in Smart Inbox, then removed');
    });

    test('a localOnly item waits too, even with Smart Analysis on', () async {
      queue.items.add(item(_id(1), localOnly: true));
      await buildService(aiPrimary: true, parkWithoutSmartAnalysis: true).run();
      expect(await txIds(), isEmpty);
      expect(server.uploads, 0);
      expect(await reasonOf(_id(1)), 'smart_analysis_off');
    });

    test('an OTP is still dropped by the deterministic filter, never kept',
        () async {
      queue.items.add(item(_id(1), text: 'Your OTP is 123456. Do not share it.'));
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.notConfigured);
      await buildService(parkWithoutSmartAnalysis: true).run();
      expect(await reasonOf(_id(1)), isNull);
      expect(await txIds(), isEmpty);
    });
  });

  group('server result handling', () {
    test(
        'processed + ValidatedCapture v1: imported from the result, tx.id = '
        'capture_id, outbox + receipt, no local parse', () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

      final report = await buildService().run();

      expect(report.imported.single.path, CaptureImportPath.server);
      expect(report.imported.single.committedTransactions.map((tx) => tx.id),
          [_id(1)]);
      expect(ingestCalls, 0);
      expect(await txIds(), [_id(1)]);
      expect(
          await count('ledger_sync_outbox', "transaction_id = '${_id(1)}'"), 1);
      expect(await sync.transactionIdForPayload(_id(1)), _id(1));
      final tx = await txRepo.getById(_id(1));
      expect(tx!.status, TransactionStatus.confirmed);
      expect(ai.calls, 0);
    });

    test('processed but NOT grounded in the device text: local parser instead',
        () async {
      queue.items.add(item(_id(1)));
      // 16 occurs only inside the date; the validator must refuse it.
      final dto = _processed(_id(1), amount: '16.00');
      server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {_id(1): dto});

      final report = await buildService().run();

      expect(report.imported.single.path, CaptureImportPath.local);
      final tx = await txRepo.getById(_id(1));
      expect(tx!.amountMoney.minorUnits, 4500,
          reason: 'the local parse of the raw text, not the unverified result');
    });

    for (final aiPrimary in [false, true]) {
      test(
          'REV-03 (aiPrimary=$aiPrimary): a server that still returns a '
          'declined purchase as processed is not imported; Smart Inbox',
          () async {
        queue.items.add(item(_id(1), text: _declinedRaw));
        // What a process-ios-sms deployed before DATA-01 returns.
        server.fetch = CaptureServerFetch(
            CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

        await buildService(aiPrimary: aiPrimary).run();

        expect(await txIds(), isEmpty, reason: 'no confirmed money');
        expect(await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
        expect(await sync.isPayloadImported(_id(1)), isTrue);
        expect(queue.acked, [_id(1)]);
        expect(ai.calls, 0);
      });
    }

    for (final aiPrimary in [false, true]) {
      // LR-03: a direction conflict means neither reading is trusted. Both
      // import paths keep the full message in Smart Inbox; neither the
      // server's debit nor the device's own credit is confirmed (the
      // non-AI-primary path used to fall through to the local parse and
      // confirm the device's reading).
      test(
          'FR-02 / LR-03 (aiPrimary=$aiPrimary): a server debit for a text the '
          'device reads as a credit is not confirmed either way: Smart Inbox',
          () async {
        const credit = 'تم استرجاع مبلغ 100.00 ريال إلى حسابك';
        queue.items.add(item(_id(1), text: credit));
        server.fetch = CaptureServerFetch(CaptureFetchStatus.ok,
            {_id(1): _processed(_id(1), amount: '100.00')});

        final report = await buildService(aiPrimary: aiPrimary).run();

        expect(report.imported.single.path, CaptureImportPath.server);
        expect(await db.customSelect('SELECT type FROM transactions;').get(),
            isEmpty,
            reason: 'no confirmed money from either reading');
        expect(
            await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
      });

      // OR-03: a server amount that is not the amount the device reads from
      // the same text (a credit limit taken for the purchase) is not
      // confirmed: Smart Inbox, as for a direction conflict.
      test(
          'OR-03 (aiPrimary=$aiPrimary): a server amount the device does not '
          'read is not confirmed: Smart Inbox', () async {
        const text = 'Purchase of SAR 89.50 at Test Mart with card *4521. '
            'Credit limit: SAR 20,000';
        queue.items.add(item(_id(1), text: text));
        server.fetch = CaptureServerFetch(CaptureFetchStatus.ok,
            {_id(1): _processed(_id(1), amount: '20000')});

        final report = await buildService(aiPrimary: aiPrimary).run();

        expect(report.imported.single.path, CaptureImportPath.server);
        expect(await db.customSelect('SELECT type FROM transactions;').get(),
            isEmpty);
        expect(await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
      });

      // LR-03: the repository's IPN credit fixture
      // (sms_redaction_cases.json `en_ipn_credited_by`). The server's credit
      // 500 is right; the device used to read it as a payment 500, so the
      // direction rule replaced a correct credit with a wrong payment on the
      // non-AI-primary path. Neither path may record spending for it.
      test(
          'LR-03 (aiPrimary=$aiPrimary): the IPN credit fixture is never '
          'recorded as spending', () async {
        const ipn = 'Your account **1234 was credited by EGP 500.00 from '
            'AHMED M*** via IPN on 12/05 IPN REF# 123456789';
        queue.items.add(item(_id(1), text: ipn));
        server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
          _id(1): ProcessedCaptureDto(
            payloadId: _id(1),
            status: 'processed',
            state: 'processed',
            parsed: const {
              'amount': 500.0,
              'amount_text': '500.00',
              'currency': 'EGP',
              'direction': 'credit',
              'type': 'income',
              'merchant': 'InstaPay',
              'rawMessage': 'sanitized',
              'parserSource': 'deterministic',
              'confidence': 0.85,
            },
            notification: const {},
          ),
        });

        await buildService(aiPrimary: aiPrimary).run();

        final rows =
            await db.customSelect('SELECT type FROM transactions;').get();
        expect(rows.map((r) => r.read<String>('type')), isNot(contains('payment')),
            reason: 'a credit is never spending');
        expect(rows.map((r) => r.read<String>('type')), ['income']);
      });

      // LR-04: a server (one deployed before the fix) that processed a
      // credit-limit notice as income is not imported: the device drops the
      // text as not a transaction, so the item is kept for review.
      test(
          'LR-04 (aiPrimary=$aiPrimary): a processed credit-limit notice is '
          'not imported as money: Smart Inbox', () async {
        const notice = 'Your credit limit has been changed to SAR 15,000.00';
        queue.items.add(item(_id(1), text: notice));
        server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
          _id(1): ProcessedCaptureDto(
            payloadId: _id(1),
            status: 'processed',
            state: 'processed',
            parsed: const {
              'amount': 15000.0,
              'amount_text': '15000.00',
              'currency': 'SAR',
              'direction': 'credit',
              'type': 'income',
              'rawMessage': 'sanitized',
              'parserSource': 'deterministic',
              'confidence': 0.7,
            },
            notification: const {},
          ),
        });

        await buildService(aiPrimary: aiPrimary).run();

        expect(await db.customSelect('SELECT type FROM transactions;').get(),
            isEmpty);
        expect(
            await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
      });
    }

    // Closure round, follow-up 6: the parser's message meaning and the
    // validator's direction check decide on every import path.
    Future<String?> reviewReason(String id) async {
      final rows = await db.customSelect(
          "SELECT metadata_json FROM smart_inbox_items WHERE payload_id = '$id';")
          .get();
      if (rows.isEmpty) return 'no row';
      final meta = rows.single.read<String?>('metadata_json');
      final m = RegExp(r'"review_reason":"([a-z_]+)"').firstMatch(meta ?? '');
      return m?.group(1);
    }

    test(
        'follow-up 6 (2): a validator direction contradiction goes to Smart '
        'Inbox with the reason, not to the local reading', () async {
      const credit = 'SAR 45.00 credited to your account *4521 from Ali';
      queue.items.add(item(_id(1), text: credit));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

      final report = await buildService().run();

      expect(report.imported.single.path, CaptureImportPath.server);
      expect(await db.customSelect('SELECT type FROM transactions;').get(),
          isEmpty,
          reason: 'neither the server debit nor the device credit');
      expect(await reviewReason(_id(1)), 'direction_contradiction');
      expect(queue.acked, [_id(1)]);
    });

    for (final aiPrimary in [false, true]) {
      test(
          'follow-up 6 (1) (aiPrimary=$aiPrimary): a server that processed an '
          'ATM cash deposit as income is not imported: Smart Inbox + reason',
          () async {
        const deposit = 'Cash deposit SAR 45.00 to account *4521 via ATM';
        queue.items.add(item(_id(1), text: deposit));
        server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
          _id(1): ProcessedCaptureDto(
            payloadId: _id(1),
            status: 'processed',
            state: 'processed',
            parsed: const {
              'amount': 45.0,
              'amount_text': '45.00',
              'currency': 'SAR',
              'direction': 'credit',
              'type': 'income',
              'rawMessage': 'sanitized',
              'parserSource': 'ai',
              'confidence': 0.9,
            },
            notification: const {},
          ),
        });

        await buildService(aiPrimary: aiPrimary).run();

        expect(await db.customSelect('SELECT type FROM transactions;').get(),
            isEmpty,
            reason: 'a cash deposit is not proven income');
        expect(await reviewReason(_id(1)), 'cash_deposit');
      });

      test(
          'follow-up 6 (1) (aiPrimary=$aiPrimary): a bill-due notice the '
          'server processed is not imported: Smart Inbox + reason', () async {
        const bill =
            'Your bill of SAR 45.00 is due on 25/06. Pay now to avoid late fees.';
        queue.items.add(item(_id(1), text: bill));
        server.fetch = CaptureServerFetch(
            CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

        await buildService(aiPrimary: aiPrimary).run();

        expect(await db.customSelect('SELECT type FROM transactions;').get(),
            isEmpty);
        expect(await reviewReason(_id(1)), 'bill_due');
      });
    }

    test(
        'follow-up 6 (1): AI-primary keeps the server meaning reason on a '
        'rejected capture', () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
        _id(1): ProcessedCaptureDto(
          payloadId: _id(1),
          status: 'rejected',
          state: 'rejected',
          parsed: const {'parserSource': 'ai', 'reviewReason': 'own_accounts'},
          notification: const {},
          sanitizedText: 'redacted',
          failureReason: 'not_parseable',
        ),
      });

      await buildService(aiPrimary: true).run();

      expect(await txIds(), isEmpty);
      expect(await reviewReason(_id(1)), 'own_accounts');
    });

    for (final entry in {
      'rejected': (String id) => _rejected(id),
      'retryable (unresolved)': (String id) => ProcessedCaptureDto(
            payloadId: id,
            status: 'rejected',
            state: 'retryable',
            parsed: const {},
            notification: const {},
          ),
    }.entries) {
      test('${entry.key}: local parser; valid is confirmed + outbox', () async {
        queue.items.add(item(_id(1)));
        server.fetch = CaptureServerFetch(
            CaptureFetchStatus.ok, {_id(1): entry.value(_id(1))});

        final report = await buildService().run();

        expect(report.imported.single.path, CaptureImportPath.local);
        expect(report.imported.single.committedTransactions.map((tx) => tx.id),
            [_id(1)]);
        expect(await txIds(), [_id(1)]);
        expect(
            (await txRepo.getById(_id(1)))!.status, TransactionStatus.confirmed,
            reason:
                'Q5: valid means confirmed, whatever local_auto_confirm_v2');
        expect(await count('ledger_sync_outbox'), 1);
        expect(queue.acked, [_id(1)]);
        expect(server.acks.single, [_id(1)]);
        expect(ai.calls, 0, reason: 'never a second AI call');
      });

      test('${entry.key}: invalid local parse goes to Smart Inbox', () async {
        queue.items.add(item(_id(1), text: _unparseable));
        server.fetch = CaptureServerFetch(
            CaptureFetchStatus.ok, {_id(1): entry.value(_id(1))});

        await buildService().run();

        expect(await txIds(), isEmpty);
        expect(await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
        expect(await sync.isPayloadImported(_id(1)), isTrue);
        expect(queue.acked, [_id(1)]);
        expect(ai.calls, 0);
      });
    }

    test(
        'expired / consumed (absent from the results) while the device copy '
        'exists: local parser', () async {
      queue.items.add(item(_id(1)));
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.ok);

      await buildService().run();

      expect(await txIds(), [_id(1)]);
      expect(server.acks, isEmpty, reason: 'no server row to ACK');
      expect(ai.calls, 0);
    });

    test('server refuses the owner (409/403): local parser, never skipped',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.refused);

      await buildService().run();

      expect(await txIds(), [_id(1)]);
      expect(ai.calls, 0);
    });

    // Astra H1 build-50 regression: the App Intent got 409
    // capture_owner_conflict (no server row was created), stored the item `.sent`
    // with failureReason `http(409)` and showed its local banner. The app import
    // must take the local deterministic parser, with no second AI call.
    group('build-50 ownerless 409 fallback (sent + http(409), no server row)',
        () {
      test('valid local parse: normal local transaction + outbox, no AI',
          () async {
        queue.items.add(item(_id(1), failureReason: 'http(409)'));
        server.fetch = const CaptureServerFetch(CaptureFetchStatus.ok);

        final report = await buildService().run();

        expect(report.imported.single.path, CaptureImportPath.local);
        expect(await txIds(), [_id(1)]);
        expect(
            (await txRepo.getById(_id(1)))!.status, TransactionStatus.confirmed);
        expect(await count('ledger_sync_outbox'), 1);
        expect(server.acks, isEmpty, reason: 'no server row exists to ACK');
        expect(server.uploads, 0, reason: 'a `.sent` item is never re-uploaded');
        expect(ai.calls, 0, reason: 'never a second AI call');
      });

      test('invalid local parse: Smart Inbox, no AI', () async {
        queue.items
            .add(item(_id(1), text: _unparseable, failureReason: 'http(409)'));
        server.fetch = const CaptureServerFetch(CaptureFetchStatus.ok);

        await buildService().run();

        expect(await txIds(), isEmpty);
        expect(await count('smart_inbox_items', "payload_id = '${_id(1)}'"), 1);
        expect(server.uploads, 0);
        expect(ai.calls, 0);
      });
    });

    test('cloud off / unconfigured: local parser', () async {
      queue.items.add(item(_id(1)));
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.notConfigured);

      await buildService().run();

      expect(await txIds(), [_id(1)]);
      expect(server.uploads, 0);
    });

    test(
        'server unreachable: an uploaded item waits, one the backend never '
        'saw is parsed locally', () async {
      queue.items.addAll([
        item(_id(1)),
        item(_id(2), failureReason: 'backend_unreachable'),
      ]);
      server.fetch = const CaptureServerFetch(CaptureFetchStatus.unavailable);

      final report = await buildService().run();

      expect(report.skippedAwaiting, 1);
      expect(await txIds(), [_id(2)]);
      expect(queue.items.single.id, _id(1));
    });

    test(
        'a locally bound (claimed) item never uploads and never trusts a '
        'server result', () async {
      queue.items.add(item(_id(1), status: 'pendingSend', localOnly: true));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1), amount: '45.00')});

      await buildService().run();

      expect(server.uploads, 0);
      expect(ingestCalls, 1, reason: 'local deterministic parser only');
      expect(await txIds(), [_id(1)]);
      expect(ai.calls, 0);
    });

    test('a localOnly item that is still .pending never uploads either',
        () async {
      queue.items.add(item(_id(1), status: 'pending', localOnly: true));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1), amount: '45.00')});

      await buildService().run();

      expect(server.uploads, 0);
      expect(ai.calls, 0);
      expect(await txIds(), [_id(1)]);
    });

    test('server results with no device copy are never imported', () async {
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

      await buildService().run();

      expect(await txIds(), isEmpty);
      expect(server.acks, isEmpty);
    });
  });

  group('pendingSend upload retry', () {
    test('accepted: results are refetched and the processed result imported',
        () async {
      queue.items.add(item(_id(1), status: 'pendingSend'));
      server.upload = CaptureUploadStatus.sent;
      server.refetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});

      final report = await buildService().run();

      expect(report.imported.single.path, CaptureImportPath.server);
      expect(server.uploads, 1);
    });

    test('409 conflict: local parser, no AI', () async {
      queue.items.add(item(_id(1), status: 'pendingSend'));
      server.upload = CaptureUploadStatus.conflict;

      await buildService().run();

      expect(await txIds(), [_id(1)]);
      expect(ai.calls, 0);
    });

    test('in progress / unavailable: the item waits', () async {
      queue.items.add(item(_id(1), status: 'pendingSend'));
      server.upload = CaptureUploadStatus.unavailable;

      final report = await buildService().run();

      expect(report.skippedAwaiting, 1);
      expect(await txIds(), isEmpty);
      expect(queue.items, hasLength(1));
    });
  });

  group('quiescence barrier (§4.10 hook)', () {
    test(
        'acquire waits for the open import transaction; ACKs are deferred; '
        'release replays them guarded by the receipt', () async {
      queue.items.addAll([
        item(_id(1)),
        item(_id(2), text: _raw.replaceAll('45.00', '46.00')),
      ]);
      server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
        _id(1): _rejected(_id(1)),
        _id(2): _rejected(_id(2)),
      });
      final inIngest = Completer<void>();
      final release = Completer<void>();
      beforeIngest = () async {
        if (!inIngest.isCompleted) {
          inIngest.complete();
          await release.future;
        }
      };
      final svc = buildService();

      final running = svc.run();
      await inIngest.future;
      var acquired = false;
      final barrier = svc.acquireBarrier().then((_) => acquired = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(acquired, isFalse, reason: 'waits for the open import');

      release.complete();
      await barrier;
      final report = await running;

      expect(await txIds(), [_id(1)],
          reason: 'the open import finished; the next item never started');
      expect(report.barrierHeld, isTrue);
      expect(queue.acked, isEmpty, reason: 'native removal deferred');
      expect(server.acks, isEmpty, reason: 'server ACK deferred');
      expect(svc.deferredCaptureIds, {_id(1)});
      expect((await svc.run()).barrierHeld, isTrue,
          reason: 'no new import while held');

      await svc.releaseBarrier();

      expect(queue.acked, [_id(1)]);
      expect(server.acks.single, [_id(1)]);
      expect(svc.deferredCaptureIds, isEmpty);

      await svc.run();
      expect(await txIds(), [_id(1), _id(2)]);
      expect(await count('ledger_sync_outbox'), 2, reason: 'no duplicate');
    });

    test('a deferred removal whose receipt is not in the replica is dropped',
        () async {
      queue.items.add(item(_id(1)));
      server.fetch = CaptureServerFetch(
          CaptureFetchStatus.ok, {_id(1): _rejected(_id(1))});
      final svc = buildService();
      final inIngest = Completer<void>();
      final release = Completer<void>();
      beforeIngest = () async {
        inIngest.complete();
        await release.future;
      };
      final running = svc.run();
      await inIngest.future;
      final barrier = svc.acquireBarrier();
      release.complete();
      await barrier;
      await running;
      expect(svc.deferredCaptureIds, {_id(1)});
      // The recovery swapped in a replica that does not carry this capture.
      await db.customStatement('DELETE FROM transactions;');
      await db.customStatement('DELETE FROM dedup_hashes;');

      await svc.releaseBarrier();

      expect(queue.acked, isEmpty, reason: 'left queued, imported by a run');
      expect(server.acks, isEmpty);
      beforeIngest = null;
      await svc.run();
      expect(await txIds(), [_id(1)]);
    });
  });

  // 4.5: a late or repeated server (AI) result never overwrites a category
  // the user chose by hand, and its provenance survives the redelivery.
  test('a redelivered AI result leaves a manual category and its provenance',
      () async {
    server.fetch = CaptureServerFetch(
        CaptureFetchStatus.ok, {_id(1): _processed(_id(1))});
    queue.items.add(item(_id(1)));
    await buildService(aiPrimary: true).run();
    expect(await txIds(), [_id(1)]);
    await txRepo.updateCategory(transactionId: _id(1), categoryKey: 'travel');

    // The same capture again, now with a different AI category.
    final late = _processed(_id(1));
    server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
      _id(1): ProcessedCaptureDto(
        payloadId: late.payloadId,
        status: late.status,
        state: late.state,
        parsed: {...late.parsed, 'category': 'shopping'},
        notification: late.notification,
      ),
    });
    queue.items.add(item(_id(1)));
    final report = await buildService(aiPrimary: true).run();
    expect(report.imported.single.path, CaptureImportPath.alreadyImported);
    final tx = (await txRepo.getById(_id(1)))!;
    expect(tx.categoryProvenance, CategoryProvenance.user);
    final key = await db
        .customSelect('SELECT c.key FROM transactions t JOIN categories c '
            'ON c.id = t.category_id WHERE t.id = ?;',
            variables: [Variable.withString(_id(1))])
        .getSingle();
    expect(key.read<String>('key'), 'travel');
  });
}
