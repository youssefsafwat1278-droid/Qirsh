// F4 — an AI "not a transaction" verdict is not a deletion order.
//
// A model can misread a real bank message. On every device path the verdict
// must leave a reviewable Smart Inbox row (with its receipt, in one local
// transaction) BEFORE the native copy is removed or the server row is ACKed.
// The DETERMINISTIC OTP/promo filter is intended behaviour and keeps ignoring.
//
// Real in-memory Drift DB, real repositories, real AddTransactionUseCase /
// CaptureSyncService / CaptureImportService / SharedCaptureHandoffService.
// Only the AI client, the relay backend and the native queue are fakes; every
// message is synthetic.
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
import 'package:money_companion/domain/entities/supporting_entities.dart';
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

/// The production client shape (AI-primary): `null` IS the model's
/// "is_transaction: false" verdict.
class _AiSaysNotATransaction implements PrimaryAiParserClient {
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

/// Relay backend that records the order of ACKs against the local commit.
class _Backend implements CaptureBackendClient {
  _Backend(this.captures, this.events);
  final List<ProcessedCaptureDto> captures;
  final List<String> events;

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    if (ackPayloadIds.isEmpty) return captures;
    events.add('server_ack:${ackPayloadIds.join(',')}');
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected backend call: ${invocation.memberName}');
}

class _Queue implements CaptureImportQueue {
  _Queue(this.events);
  final List<String> events;
  final List<SharedCapturedMessage> items = [];
  Future<void> Function(String id)? beforeAck;

  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);

  @override
  Future<bool> acknowledge(String payloadId) async {
    await beforeAck?.call(payloadId);
    events.add('native_ack:$payloadId');
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _Server implements CaptureServerPort {
  _Server(this.results, this.events);
  final Map<String, ProcessedCaptureDto> results;
  final List<String> events;

  @override
  Future<CaptureServerFetch> fetchResults() async =>
      CaptureServerFetch(CaptureFetchStatus.ok, results);

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async =>
      CaptureUploadStatus.unavailable;

  @override
  Future<void> acknowledge(List<String> payloadIds) async =>
      events.add('server_ack:${payloadIds.join(',')}');
}

// Synthetic messages.
const _bankPurchase = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _otp = 'Your OTP is 123456. Do not share it. SAR 50.00';
final _received = DateTime.utc(2026, 4, 8, 9, 45);
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

ProcessedCaptureDto _aiIgnored(String id, String sanitizedText) =>
    ProcessedCaptureDto(
      payloadId: id,
      status: 'rejected',
      state: 'rejected',
      parsed: const {'parserSource': 'ai_ignored'},
      notification: const {},
      sanitizedText: sanitizedText,
      failureReason: 'not_parseable',
    );

void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late List<String> events;

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
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    events = [];
  });

  tearDown(() async => db.close());

  CaptureSyncService buildSync([List<ProcessedCaptureDto> relay = const []]) =>
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
        client: _Backend(relay, events),
        backendConfigured: true,
        loadInstallId: () async => 'install-id',
      );

  IngestCapturedMessageUseCase buildIngest(AiParserClient ai) =>
      IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        aiClient: ai,
        loadAiConsent: () async => true,
        installId: 'install',
      ));

  Future<List<Map<String, Object?>>> reviewRows() async => (await db
          .customSelect('SELECT id, body, status FROM smart_inbox_items;')
          .get())
      .map((r) => r.data)
      .toList();

  Future<int> txCount() async =>
      (await db.customSelect('SELECT COUNT(*) c FROM transactions;').getSingle())
          .read<int>('c');

  group('in-app AI call (drain AI fallback / manual paste / inbox retry)', () {
    test('a bank message the model calls "not a transaction" is reviewable',
        () async {
      final ai = _AiSaysNotATransaction();
      final result = await buildIngest(ai).fromCapturedMessage(CapturedMessage(
        text: _bankPurchase,
        senderId: 'SNB',
        source: CapturedMessageSource.androidShare,
        receivedAt: _received,
      ));
      expect(ai.calls, 1);
      expect(await txCount(), 0, reason: 'AI-primary never guesses locally');
      expect(result.disposition, CapturedMessageDisposition.unprocessable,
          reason: 'an AI verdict must become a review item, never a silent '
              'ignore');
    });

    test('the review row and receipt commit before the native ack', () async {
      final sync = buildSync();
      final message = SharedCapturedMessage(
        id: _id(1),
        text: _bankPurchase,
        sender: 'SNB',
        source: CapturedMessageSource.iosShortcut,
        receivedAt: _received,
        status: 'sent',
        failureReason: 'timeout',
      );
      final result = await buildIngest(_AiSaysNotATransaction())
          .fromCapturedMessage(
        CapturedMessage(
          text: message.text,
          senderId: message.sender,
          source: message.source,
          receivedAt: message.receivedAt,
        ),
        capture: sync.captureCommitFor(_id(1)),
      );
      var rowsAtAck = -1;
      String? receiptAtAck;
      final outcome = await SharedCaptureHandoffService(
        captureSyncService: sync,
        isOwnerCurrent: () async => true,
        acknowledge: (id) async {
          rowsAtAck = (await reviewRows()).length;
          receiptAtAck = await sync.transactionIdForPayload(id);
          return true;
        },
      ).complete(
        message: message,
        disposition: result.disposition,
        transactionId: result.transactionId,
      );
      expect(outcome, SharedCaptureHandoffOutcome.acknowledged);
      expect(rowsAtAck, 1, reason: 'the row must exist when the ack runs');
      expect(receiptAtAck, 'smart_inbox:local_capture:${_id(1)}');
      expect((await reviewRows()).single['body'], _bankPurchase);
    });

    test('a non-bank message the model rejects is still reviewable', () async {
      final result = await buildIngest(_AiSaysNotATransaction())
          .fromCapturedMessage(CapturedMessage(
        text: 'Paid my friend back for dinner yesterday, all settled.',
        source: CapturedMessageSource.androidShare,
        receivedAt: _received,
      ));
      expect(result.disposition, CapturedMessageDisposition.unprocessable);
    });

    test('the deterministic OTP filter still ignores, with no AI request',
        () async {
      final ai = _AiSaysNotATransaction();
      final result = await buildIngest(ai).fromCapturedMessage(CapturedMessage(
        text: _otp,
        senderId: 'SNB',
        source: CapturedMessageSource.androidShare,
        receivedAt: _received,
      ));
      expect(ai.calls, 0, reason: 'an OTP never reaches AI');
      expect(result.disposition, CapturedMessageDisposition.ignored);
    });
  });

  group('legacy relay import (CaptureSyncService.sync)', () {
    test('a server ai_ignored result becomes a review row before the ACK',
        () async {
      final sync = buildSync([_aiIgnored(_id(2), _bankPurchase)]);
      // Observe the local state at the moment the server ACK is sent.
      final result = await sync.sync();
      expect(result.importedPayloadIds, {_id(2)});
      final rows = await reviewRows();
      expect(rows, hasLength(1),
          reason: 'the verdict must leave a reviewable record');
      expect(rows.single['id'], 'local_capture:${_id(2)}');
      expect(rows.single['body'], _bankPurchase);
      expect(await sync.transactionIdForPayload(_id(2)),
          'smart_inbox:local_capture:${_id(2)}');
      expect(events, ['server_ack:${_id(2)}']);
      expect(await txCount(), 0);
    });

    test('a server ai_ignored OTP stays ignored (deterministic filter)',
        () async {
      final sync = buildSync([_aiIgnored(_id(3), _otp)]);
      await sync.sync();
      expect(await reviewRows(), isEmpty);
      expect(await sync.transactionIdForPayload(_id(3)), 'ignored');
      expect(events, ['server_ack:${_id(3)}']);
    });

    test('a server ai_ignored result with no text is left for the native copy',
        () async {
      // Without text the device cannot judge the verdict. Acknowledging it
      // would also make the drain ack the native copy: a silent deletion.
      final sync = buildSync([_aiIgnored(_id(4), '')]);
      final result = await sync.sync();
      expect(result.importedPayloadIds, isEmpty);
      expect(result.failedPayloadIds, isEmpty);
      expect(events, isEmpty, reason: 'no server ACK');
      expect(await sync.transactionIdForPayload(_id(4)), isNull,
          reason: 'no receipt: the native copy still gets processed');
      expect(await reviewRows(), isEmpty);
    });
  });

  group('v3 import (CaptureImportService, AI-primary)', () {
    CaptureImportService buildV3(_Queue queue, _Server server) {
      final sync = buildSync();
      return CaptureImportService(
        aiPrimarySelected: () async => true,
        queue: queue,
        server: server,
        captureSyncService: sync,
        receipts: CaptureReceipts(db),
        ingestLocal: CaptureImportService.localIngest(
            buildIngest(_AiSaysNotATransaction())),
        sessionUid: () => 'user-A',
        replicaOwnerUid: () async => 'user-A',
        ownershipGuard: _Guard(),
      );
    }

    SharedCapturedMessage item(String id, String text) => SharedCapturedMessage(
          id: id,
          text: text,
          sender: 'SNB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: _received,
          status: 'sent',
          ownerUid: 'user-A',
        );

    test('ai_ignored writes the review row before native removal and ACK',
        () async {
      final queue = _Queue(events)..items.add(item(_id(4), _bankPurchase));
      var rowsAtNativeAck = -1;
      queue.beforeAck = (_) async => rowsAtNativeAck = (await reviewRows()).length;
      final server =
          _Server({_id(4): _aiIgnored(_id(4), 'sanitized')}, events);
      await buildV3(queue, server).run();
      expect(rowsAtNativeAck, 1,
          reason: 'the Smart Inbox row must be committed before removal');
      final rows = await reviewRows();
      expect(rows.single['body'], _bankPurchase,
          reason: 'the device keeps its own full text');
      expect(events, ['native_ack:${_id(4)}', 'server_ack:${_id(4)}']);
      expect(queue.items, isEmpty);
    });

    test('ai_ignored OTP is still dropped without a review row', () async {
      final queue = _Queue(events)..items.add(item(_id(5), _otp));
      final server = _Server({_id(5): _aiIgnored(_id(5), 'sanitized')}, events);
      await buildV3(queue, server).run();
      expect(await reviewRows(), isEmpty);
      expect(events, ['native_ack:${_id(5)}', 'server_ack:${_id(5)}']);
    });
  });
}
