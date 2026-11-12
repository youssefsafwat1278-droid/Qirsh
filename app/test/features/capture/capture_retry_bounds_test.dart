// F5 / F7 / F2 — bounded, backed-off retries that end in a visible state, and
// one failing capture never blocking the others.
//
// Real in-memory Drift DB, real repositories, real CaptureSyncService /
// CaptureImportService / AddTransactionUseCase. The relay backend, the server
// port, the native queue and the clock are local fakes; messages are synthetic.
import 'dart:convert';

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
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_retry_ledger.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/shared_capture_handoff_service.dart';

import '../../domain/local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<void> syncBackendState() async {}

  @override
  Future<String?> readDeviceSecret() async => 'device-secret';

  @override
  Future<bool> isLinkedForCloud() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');

  @override
  Future<AdmissionToken> capture() async => _token;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

class _Backend implements CaptureBackendClient {
  _Backend(this.captures);
  final List<ProcessedCaptureDto> captures;
  final acked = <String>[];
  Object? uploadError;
  var uploads = 0;

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    acked.addAll(ackPayloadIds);
    return ackPayloadIds.isEmpty
        ? [
            for (final c in captures)
              if (!acked.contains(c.payloadId)) c
          ]
        : const [];
  }

  @override
  Future<void> processIosSms({
    required String installId,
    required String deviceSecret,
    required String payloadId,
    required String smsText,
    required DateTime receivedAt,
    required bool allowAi,
    String? sender,
    String? locale,
    required String ownerUid,
    required int ownerGeneration,
    bool schemaV2 = false,
  }) async {
    uploads++;
    if (uploadError != null) throw uploadError!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected backend call: ${invocation.memberName}');
}

/// A repository whose save fails for one transaction id (a poison capture).
class _PoisonRepo extends DriftTransactionRepository {
  _PoisonRepo(super.db, {super.outboxQueue});
  String? poisonId;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    String? categoryKey,
    String? resolvedCategoryId,
  }) {
    if (transaction.id == poisonId) throw StateError('poison row');
    return super.saveTransaction(
      transaction: transaction,
      categoryKey: categoryKey,
      resolvedCategoryId: resolvedCategoryId,
    );
  }
}

class _Queue implements CaptureImportQueue {
  final List<SharedCapturedMessage> items = [];
  final acked = <String>[];

  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);

  @override
  Future<bool> acknowledge(String payloadId) async {
    acked.add(payloadId);
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _Server implements CaptureServerPort {
  CaptureUploadStatus upload = CaptureUploadStatus.unavailable;
  final uploaded = <String>[];

  /// Results listed by the server; an accepted upload adds [analysed].
  final results = <String, ProcessedCaptureDto>{};
  ProcessedCaptureDto Function(String id)? analysed;

  @override
  Future<CaptureServerFetch> fetchResults() async =>
      CaptureServerFetch(CaptureFetchStatus.ok, Map.of(results));

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async {
    uploaded.add(m.id!);
    if (upload == CaptureUploadStatus.sent && analysed != null) {
      results[m.id!] = analysed!(m.id!);
    }
    return upload;
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}

const _bankPurchase = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _poisonText = 'synthetic message whose local processing always throws';
final _received = DateTime.utc(2026, 4, 8, 9, 45);
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

ProcessedCaptureDto _processed(String id) => ProcessedCaptureDto(
      payloadId: id,
      status: 'processed',
      state: 'processed',
      parsed: const {
        'amount': 45.0,
        'amount_text': '45.00',
        'currency': 'SAR',
        'direction': 'debit',
        'type': 'payment',
        'merchant': 'NETFLIX',
        'occurredAt': '2026-04-08T09:45:00.000Z',
        'rawMessage': 'sanitized purchase',
        'parserSource': 'deterministic',
        'confidence': 0.95,
      },
      notification: const {},
      sanitizedText: 'sanitized purchase',
    );

/// A processed result that validates against [_bankPurchase] on the device.
ProcessedCaptureDto _processedFor(String id) => ProcessedCaptureDto(
      payloadId: id,
      status: 'processed',
      state: 'processed',
      parsed: const {
        'amount': 45.0,
        'amount_text': '45.00',
        'currency': 'SAR',
        'direction': 'debit',
        'type': 'payment',
        'merchant': 'NETFLIX',
        'last4': '4521',
        'occurredAt': '2026-04-08T09:45:00.000Z',
        'rawMessage': 'sanitized',
        'parserSource': 'ai',
        'confidence': 0.95,
      },
      notification: const {},
    );

ProcessedCaptureDto _rejected(String id, String parserSource) =>
    ProcessedCaptureDto(
      payloadId: id,
      status: 'rejected',
      state: 'rejected',
      parsed: {
        'parserSource': parserSource,
        'rawMessage': 'sanitized bank text',
        'senderId': 'SNB',
      },
      notification: const {},
      sanitizedText: 'sanitized bank text',
      failureReason: 'not_parseable',
    );

void main() {
  late AppDatabase db;
  late _PoisonRepo txRepo;
  var now = DateTime.utc(2026, 5, 1, 8);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final settings = DriftUserSettingsRepository(db);
    await settings.saveSettings((await settings.getSettings()).copyWith(
      cloudConsentState: ConsentState.accepted,
      aiConsentState: ConsentState.accepted,
    ));
    txRepo = _PoisonRepo(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    now = DateTime.utc(2026, 5, 1, 8);
  });

  tearDown(() async => db.close());

  CaptureRetryLedger ledger() => CaptureRetryLedger(now: () => now);

  CaptureSyncService buildSync(_Backend backend, {CaptureRetryLedger? ledger}) =>
      CaptureSyncService(
        settingsRepository: DriftUserSettingsRepository(db),
        transactionRepository: txRepo,
        dedupStore: DriftDedupStore(db),
        smartInboxRepository: DriftSmartInboxRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        registrationService: _Registration(),
        ownershipGuard: _Guard(),
        currentUserId: () => 'user-A',
        accountRepository: DriftAccountRepository(db),
        client: backend,
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
        authorizeUpload: (_) async => const CaptureUploadAuthorization(
            CaptureUploadDecision.allowed,
            ownerUid: 'user-A',
            ownerGeneration: 1),
        retryLedger: ledger,
      );

  Future<List<Map<String, Object?>>> reviewRows() async => (await db
          .customSelect(
              'SELECT id, title, body, metadata_json FROM smart_inbox_items '
              'ORDER BY id;')
          .get())
      .map((r) => r.data)
      .toList();

  String? reasonOf(Map<String, Object?> row) =>
      (jsonDecode(row['metadata_json']! as String) as Map)['review_reason']
          as String?;

  Future<List<String>> txIds() async =>
      (await db.customSelect('SELECT id FROM transactions ORDER BY id;').get())
          .map((r) => r.read<String>('id'))
          .toList();

  group('CaptureRetryLedger', () {
    test('backs off exponentially and is due only after the wait', () async {
      final l = ledger();
      expect(await l.isDue('a'), isTrue);
      final first = await l.recordFailure('a', CaptureFailureKind.temporary);
      expect(first.attempts, 1);
      expect(first.exhausted, isFalse);
      expect(await l.isDue('a'), isFalse);
      now = now.add(const Duration(seconds: 29));
      expect(await l.isDue('a'), isFalse);
      now = now.add(const Duration(seconds: 1));
      expect(await l.isDue('a'), isTrue);
      final second = await l.recordFailure('a', CaptureFailureKind.temporary);
      expect(second.nextDue.difference(now), const Duration(minutes: 2));
    });

    test('a rate-limited failure waits at least an hour', () async {
      final l = ledger();
      final d = await l.recordFailure('a', CaptureFailureKind.temporary,
          rateLimited: true);
      expect(d.nextDue.difference(now), const Duration(hours: 1));
    });

    test('temporary failures are bounded; the end state is temporary',
        () async {
      final l = ledger();
      late CaptureRetryDecision d;
      for (var i = 0; i < CaptureRetryLedger.maxAttempts; i++) {
        d = await l.recordFailure('a', CaptureFailureKind.temporary);
        expect(d.exhausted, i == CaptureRetryLedger.maxAttempts - 1);
      }
      expect(d.kind, CaptureFailureKind.temporary);
    });

    test('permanent failures stop sooner and stay distinguishable', () async {
      final l = ledger();
      late CaptureRetryDecision d;
      for (var i = 0; i < CaptureRetryLedger.maxPermanentAttempts; i++) {
        d = await l.recordFailure('a', CaptureFailureKind.permanent);
      }
      expect(d.exhausted, isTrue);
      expect(d.kind, CaptureFailureKind.permanent);
    });

    test('state survives a restart and is cleared on success', () async {
      final store = MemoryCaptureRetryStore();
      await CaptureRetryLedger(store: store, now: () => now)
          .recordFailure('a', CaptureFailureKind.temporary);
      final reopened = CaptureRetryLedger(store: store, now: () => now);
      expect(await reopened.isDue('a'), isFalse);
      await reopened.clear('a');
      expect(await CaptureRetryLedger(store: store, now: () => now).isDue('a'),
          isTrue);
      expect(await store.read(), isNot(contains('a')));
    });

    test('an unreadable store never throws into a drain', () async {
      final store = MemoryCaptureRetryStore();
      await store.write('not json');
      final l = CaptureRetryLedger(store: store, now: () => now);
      expect(await l.isDue('a'), isTrue);
    });

    test('classification: transport is temporary, local is permanent', () {
      expect(
          CaptureRetryLedger.classify(
              const CaptureBackendException('process_ios_sms_failed_503')),
          CaptureFailureKind.temporary);
      expect(CaptureRetryLedger.classify(StateError('parser crashed')),
          CaptureFailureKind.permanent);
      expect(
          CaptureRetryLedger.isRateLimited(
              const CaptureBackendException('process_ios_sms_failed_429')),
          isTrue);
      expect(isTemporaryAiFailure('ai_deferred'), isTrue);
      expect(isTemporaryAiFailure('http_503'), isTrue);
      expect(isTemporaryAiFailure('ai_response_rejected_by_grounding'), isFalse);
      expect(isTemporaryAiFailure('on_device_only'), isFalse);
      expect(isTemporaryAiFailure(null), isFalse);
    });
  });

  group('F7 — one failing relay capture does not block the others', () {
    test('the good capture is imported and ACKed; the bad one is kept',
        () async {
      txRepo.poisonId = _id(1);
      final backend = _Backend([_processed(_id(1)), _processed(_id(2))]);
      final result = await buildSync(backend).sync();
      expect(await txIds(), [_id(2)],
          reason: 'the capture after the failing one must still import');
      expect(backend.acked, [_id(2)],
          reason: 'the failing capture is never ACKed away');
      expect(result.importedPayloadIds, {_id(2)});
      expect(result.failedPayloadIds, {_id(1)});
    });

    test('a capture that keeps failing is parked for review, then ACKed',
        () async {
      txRepo.poisonId = _id(1);
      final backend = _Backend([_processed(_id(1))]);
      final sync = buildSync(backend, ledger: ledger());
      for (var i = 0; i < CaptureRetryLedger.maxPermanentAttempts - 1; i++) {
        await sync.sync();
        expect(await reviewRows(), isEmpty);
        expect(backend.acked, isEmpty);
      }
      await sync.sync();
      final rows = await reviewRows();
      expect(rows.single['id'], 'local_capture:${_id(1)}');
      expect(rows.single['body'], 'sanitized purchase');
      expect(reasonOf(rows.single),
          SmartInboxReviewReason.processingFailed);
      expect(await sync.transactionIdForPayload(_id(1)),
          'smart_inbox:local_capture:${_id(1)}');
      expect(backend.acked, [_id(1)], reason: 'ACK only after the local row');
    });
  });

  group('F5 — a temporary analysis failure is distinguishable', () {
    test('server ai_pending (analysis did not complete) is marked temporary',
        () async {
      final sync = buildSync(_Backend([_rejected(_id(3), 'ai_pending')]));
      await sync.sync();
      final row = (await reviewRows()).single;
      expect(reasonOf(row), SmartInboxReviewReason.analysisUnavailable);
      expect(row['title'], 'Bank message awaiting analysis');
    });

    test('a deterministic rejection is not marked temporary', () async {
      final sync = buildSync(_Backend([_rejected(_id(4), 'deterministic')]));
      await sync.sync();
      final row = (await reviewRows()).single;
      expect(reasonOf(row), isNull);
      expect(row['title'], 'An unsupported bank message that needs review');
    });

    test('the handoff labels an in-app temporary AI failure', () async {
      final sync = buildSync(_Backend(const []));
      await SharedCaptureHandoffService(
        captureSyncService: sync,
        isOwnerCurrent: () async => true,
        acknowledge: (_) async => true,
      ).complete(
        message: SharedCapturedMessage(
          id: _id(5),
          text: _bankPurchase,
          sender: 'SNB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: _received,
        ),
        disposition: CapturedMessageDisposition.unprocessable,
        transactionId: null,
        reviewReason: SmartInboxReviewReason.analysisUnavailable,
      );
      expect(reasonOf((await reviewRows()).single),
          SmartInboxReviewReason.analysisUnavailable);
    });
  });

  group('F2 — a terminal upload refusal is remembered, not repeated', () {
    SharedCapturedMessage pending(String id) => SharedCapturedMessage(
          id: id,
          text: _bankPurchase,
          sender: 'SNB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: _received,
          status: 'pendingSend',
        );

    test('409 marks the upload terminally refused', () async {
      final backend = _Backend(const [])
        ..uploadError =
            const CaptureBackendException('process_ios_sms_failed_409');
      final sync = buildSync(backend);
      expect(sync.uploadTerminallyRefused(_id(6)), isFalse);
      expect(await sync.retryPendingSend(pending(_id(6))), isFalse);
      expect(sync.uploadTerminallyRefused(_id(6)), isTrue,
          reason: 'the drain must be able to tell 409 from "not allowed"');
    });

    test('a transient failure is not a terminal refusal', () async {
      final backend = _Backend(const [])
        ..uploadError =
            const CaptureBackendException('process_ios_sms_failed_503');
      final sync = buildSync(backend);
      await expectLater(sync.retryPendingSend(pending(_id(7))),
          throwsA(isA<CaptureBackendException>()));
      expect(sync.uploadTerminallyRefused(_id(7)), isFalse);
    });
  });

  group('F5/F7 — v3 import: bounded, backed-off, ends visible', () {
    late _Queue queue;
    late _Server server;
    late CaptureSyncService sync;

    CaptureImportService buildV3(CaptureRetryLedger? l,
        {bool aiPrimary = true}) {
      final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        installId: 'install',
      ));
      final inner = CaptureImportService.localIngest(ingest);
      return CaptureImportService(
        aiPrimarySelected: () async => aiPrimary,
        queue: queue,
        server: server,
        captureSyncService: sync,
        receipts: CaptureReceipts(db),
        ingestLocal: (m, c) {
          if (m.text == _poisonText) throw StateError('local crash');
          return inner(m, c);
        },
        sessionUid: () => 'user-A',
        replicaOwnerUid: () async => 'user-A',
        ownershipGuard: _Guard(),
        retryLedger: l,
      );
    }

    SharedCapturedMessage item(String id,
            {String text = _bankPurchase,
            String status = 'pendingSend',
            bool? localOnly}) =>
        SharedCapturedMessage(
          id: id,
          text: text,
          sender: 'SNB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: _received,
          status: status,
          ownerUid: 'user-A',
          localOnly: localOnly,
        );

    setUp(() {
      queue = _Queue();
      server = _Server();
      sync = buildSync(_Backend(const []));
    });

    test('a failed upload is not repeated before its backoff elapses',
        () async {
      queue.items.add(item(_id(8)));
      final service = buildV3(ledger());
      await service.run();
      await service.run();
      expect(server.uploaded, hasLength(1),
          reason: 'the second run is inside the backoff window');
      now = now.add(const Duration(seconds: 31));
      await service.run();
      expect(server.uploaded, hasLength(2));
      expect(queue.items, hasLength(1), reason: 'still durable');
    });

    test('429 stops further uploads on the run and waits an hour', () async {
      queue.items.addAll([item(_id(9)), item(_id(10))]);
      server.upload = CaptureUploadStatus.rateLimited;
      final service = buildV3(ledger());
      await service.run();
      expect(server.uploaded, [_id(9)],
          reason: 'a rate-limited run sends nothing else');
      now = now.add(const Duration(minutes: 59));
      await service.run();
      expect(server.uploaded, hasLength(1));
      now = now.add(const Duration(minutes: 2));
      await service.run();
      expect(server.uploaded, hasLength(2));
    });

    test('retries are bounded and end as a retryable Smart Inbox row',
        () async {
      queue.items.add(item(_id(11)));
      final service = buildV3(ledger());
      for (var i = 0; i < CaptureRetryLedger.maxAttempts; i++) {
        await service.run();
        now = now.add(const Duration(hours: 7));
      }
      expect(server.uploaded, hasLength(CaptureRetryLedger.maxAttempts));
      final row = (await reviewRows()).single;
      expect(row['id'], 'local_capture:${_id(11)}');
      expect(row['body'], _bankPurchase, reason: 'the full text is kept');
      expect(reasonOf(row), SmartInboxReviewReason.analysisUnavailable);
      expect(queue.acked, [_id(11)], reason: 'removed only after the row');
      await service.run();
      expect(server.uploaded, hasLength(CaptureRetryLedger.maxAttempts),
          reason: 'nothing is retried after the bound');
    });

    test('a never-uploaded item is sent with its own id, then imported',
        () async {
      // Share Extension `pending`, and `.waiting` stored as `sent`.
      queue.items.addAll([
        item(_id(20), status: 'pending'),
        item(_id(21), status: 'sent'),
      ]);
      server
        ..upload = CaptureUploadStatus.sent
        ..analysed = _processedFor;
      await buildV3(ledger()).run();
      expect(server.uploaded, [_id(20), _id(21)]);
      // Both items hold the SAME bank message (identical results at the same
      // instant): identity is uncertain, so the later one is kept for review
      // as a suspected duplicate, never a second confirmed transaction.
      expect(await txIds(), [_id(20)]);
      final suspected = await db
          .customSelect('SELECT id, existing_transaction_id e '
              'FROM suspected_duplicates;')
          .get();
      expect(suspected.map((r) => '${r.data['id']}->${r.data['e']}'),
          ['${_id(21)}->${_id(20)}']);
      expect(await reviewRows(), isEmpty);
      expect(queue.items, isEmpty);
    });

    test('an upload the gate refuses is parsed on device, not parked',
        () async {
      queue.items.add(item(_id(22), status: 'pending'));
      server.upload = CaptureUploadStatus.notAllowed;
      await buildV3(ledger()).run();
      expect(await txIds(), [_id(22)]);
      expect(await reviewRows(), isEmpty);
      expect(queue.items, isEmpty);
    });

    test('a locally failing item is parked and never blocks its neighbour',
        () async {
      queue.items.addAll([
        item(_id(12), text: _poisonText, status: 'sent', localOnly: true),
        item(_id(13), status: 'sent', localOnly: true),
      ]);
      final service = buildV3(ledger(), aiPrimary: false);
      await service.run();
      expect(await txIds(), [_id(13)]);
      expect(await reviewRows(), isEmpty);
      for (var i = 1; i < CaptureRetryLedger.maxPermanentAttempts; i++) {
        now = now.add(const Duration(hours: 7));
        await service.run();
      }
      final row = (await reviewRows()).single;
      expect(row['id'], 'local_capture:${_id(12)}');
      expect(reasonOf(row), SmartInboxReviewReason.processingFailed);
      expect(queue.items, isEmpty);
    });
  });
}
