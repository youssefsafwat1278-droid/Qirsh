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
import 'package:money_companion/domain/services/bank_discovery_service.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

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

/// Only the relay fetch/ack is allowed; any other network call fails the test.
class _Backend implements CaptureBackendClient {
  _Backend(this.captures);

  final List<ProcessedCaptureDto> captures;
  int syncCalls = 0;
  final acked = <String>[];

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    syncCalls++;
    acked.addAll(ackPayloadIds);
    return ackPayloadIds.isEmpty ? captures : const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected backend call: ${invocation.memberName}');
}

class _Guard extends OwnershipGuard {
  AdmissionToken current =
      const AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');

  @override
  Future<AdmissionToken> capture() async => current;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == current;
}

class _NoAi implements AiParserClient {
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

class _NoDiscovery implements BankDiscoveryService {
  int calls = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    calls++;
    return Future<Never>.error(StateError('discovery must not run'));
  }
}

const _validRaw = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _serverText = 'Unparseable sanitized capture';

ProcessedCaptureDto _rejected(String id, {String? sanitized}) =>
    ProcessedCaptureDto(
      payloadId: id,
      status: 'rejected',
      parsed: const {'senderId': 'SNB'},
      notification: const {},
      sanitizedText: sanitized ?? _serverText,
      createdAt: DateTime.utc(2026, 7, 5, 10),
    );

ProcessedCaptureDto _needsReview(String id) => ProcessedCaptureDto(
      payloadId: id,
      status: 'needs_review',
      parsed: const {
        'senderId': 'SNB',
        'amount': 45.0,
        'amount_text': '45.00',
        'currency': 'SAR',
        'type': 'payment',
        'merchant': 'NETFLIX',
      },
      notification: const {},
      sanitizedText: _serverText,
      createdAt: DateTime.utc(2026, 7, 5, 10),
    );

void main() {
  late AppDatabase db;
  late _Guard guard;
  late _NoAi ai;
  late _NoDiscovery discovery;
  var enrichCalls = 0;
  var flagOn = true;
  var recoverCalls = 0;
  final parserInputs = <String>[];

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    final settingsRepo = DriftUserSettingsRepository(db);
    final settings = await settingsRepo.getSettings();
    await settingsRepo.saveSettings(
      settings.copyWith(cloudConsentState: ConsentState.accepted),
    );
    guard = _Guard();
    ai = _NoAi();
    discovery = _NoDiscovery();
    enrichCalls = 0;
    flagOn = true;
    recoverCalls = 0;
    parserInputs.clear();
  });

  tearDown(() async => db.close());

  IngestCapturedMessageUseCase ingest() => IngestCapturedMessageUseCase(
        AddTransactionUseCase(
          transactionRepository: DriftTransactionRepository(db),
          merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
          accountRepository: DriftAccountRepository(db),
          isLocalAutoConfirmV2: () => flagOn,
          aiClient: ai,
          loadAiConsent: () async => true,
          installId: 'install',
          bankDiscoveryService: discovery,
          mayEnrichMerchant: () async => true,
          resolveMerchantCategory: (_) async {
            enrichCalls++;
            return null;
          },
        ),
      );

  CaptureSyncService service(
    _Backend backend, {
    SharedCapturedMessage? native,
    String? Function()? currentUserId,
    Future<CapturedMessageResult> Function(CapturedMessage)? recover,
  }) {
    final useCase = ingest();
    return CaptureSyncService(
      settingsRepository: DriftUserSettingsRepository(db),
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: guard,
      currentUserId: currentUserId ?? () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      client: backend,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      isLocalAutoConfirmV2: () => flagOn,
      lookupNativeCapture: (id) async => native?.id == id ? native : null,
      recoverLocally: recover ??
          (message) {
            recoverCalls++;
            parserInputs.add(message.text);
            return useCase.fromCapturedMessage(message, onDeviceOnly: true);
          },
    );
  }

  SharedCapturedMessage nativeMsg(String id, String text) =>
      SharedCapturedMessage(
        id: id,
        text: text,
        sender: 'SNB',
        source: CapturedMessageSource.iosShare,
      );

  Future<void> expectNoNetwork(_Backend backend) async {
    expect(ai.calls, 0);
    expect(discovery.calls, 0);
    expect(enrichCalls, 0);
    // Only the relay's own fetch + ack; recovery adds none.
    expect(backend.syncCalls, 2);
  }

  test('valid native raw text => confirmed tx, marker=tx id, no inbox row',
      () async {
    final backend = _Backend([_rejected('p1')]);
    final svc = service(backend, native: nativeMsg('p1', _validRaw));

    final result = await svc.sync();

    final txs = await DriftTransactionRepository(db).getAll();
    expect(txs, hasLength(1));
    expect(txs.single.status.name, 'confirmed');
    expect(await svc.transactionIdForPayload('p1'), txs.single.id);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    expect(parserInputs, [_validRaw]);
    expect(result.importedPayloadIds, {'p1'});
    expect(backend.acked, ['p1']);
    await expectNoNetwork(backend);
  });

  test('raw unavailable => server sanitized text reaches the parser',
      () async {
    final backend = _Backend([_rejected('p2', sanitized: _validRaw)]);
    final svc = service(backend); // no native match

    await svc.sync();

    expect(parserInputs, [_validRaw]);
    expect(await DriftTransactionRepository(db).getAll(), hasLength(1));
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    await expectNoNetwork(backend);
  });

  test('invalid locally => Smart Inbox row exactly as today', () async {
    final backend = _Backend([_rejected('p3')]);
    final svc =
        service(backend, native: nativeMsg('p3', 'hello, not a bank message'));

    await svc.sync();

    expect(recoverCalls, 1);
    expect(await DriftTransactionRepository(db).getAll(), isEmpty);
    final inbox = await DriftSmartInboxRepository(db).getOpen();
    expect(inbox, hasLength(1));
    expect(inbox.single.id, isNotEmpty);
    expect(await svc.transactionIdForPayload('p3'), startsWith('smart_inbox:'));
    await expectNoNetwork(backend);
  });

  test('replayed relay capture and later native drain add nothing', () async {
    final backend = _Backend([_rejected('p4')]);
    final svc = service(backend, native: nativeMsg('p4', _validRaw));

    await svc.sync();
    await svc.sync(); // relay replays the same capture

    expect(await DriftTransactionRepository(db).getAll(), hasLength(1));
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    expect(recoverCalls, 1, reason: 'marker short-circuits the replay');
    // The native drain's guard: the payload is already imported.
    expect(await svc.isPayloadImported('p4'), isTrue);
  });

  test('stale owner during recovery rolls back everything', () async {
    final backend = _Backend([_rejected('p5')]);
    final real = ingest();
    final svc = service(
      backend,
      native: nativeMsg('p5', _validRaw),
      recover: (message) async {
        final r = await real.fromCapturedMessage(message, onDeviceOnly: true);
        guard.current =
            const AdmissionToken(ownerUid: 'user-B', generation: 'gen-B');
        return r;
      },
    );

    await expectLater(svc.sync(), throwsA(isA<StaleOwnershipException>()));

    expect(await DriftTransactionRepository(db).getAll(), isEmpty);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    expect(await svc.transactionIdForPayload('p5'), isNull);
    expect(backend.acked, isEmpty);
  });

  test('flag OFF => Smart Inbox, recovery callback never invoked', () async {
    flagOn = false;
    final backend = _Backend([_rejected('p6')]);
    final svc = service(backend, native: nativeMsg('p6', _validRaw));

    await svc.sync();

    expect(recoverCalls, 0);
    expect(await DriftTransactionRepository(db).getAll(), isEmpty);
    expect(await DriftSmartInboxRepository(db).getOpen(), hasLength(1));
    expect(await svc.transactionIdForPayload('p6'), startsWith('smart_inbox:'));
  });

  test(
      'suspicious duplicate => kept as ONE suspected duplicate for review, no '
      '2nd tx, no Smart Inbox row', () async {
    final first = _Backend([_rejected('p7a')]);
    await service(first, native: nativeMsg('p7a', _validRaw)).sync();
    final original = await DriftTransactionRepository(db).getAll();
    expect(original, hasLength(1));

    final second = _Backend([_rejected('p7b')]);
    final svc = service(second, native: nativeMsg('p7b', _validRaw));
    await svc.sync();

    expect(await DriftTransactionRepository(db).getAll(), hasLength(1),
        reason: 'no second transaction');
    final suspected = await DriftSuspectedDuplicateRepository(db).getAll();
    expect(suspected, hasLength(1),
        reason: 'the later capture is preserved for review');
    expect(suspected.single.existingTransactionId, original.single.id);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    expect(await svc.transactionIdForPayload('p7b'), original.single.id);

    // The same server result listed again: nothing new.
    await service(_Backend([_rejected('p7b')]),
            native: nativeMsg('p7b', _validRaw))
        .sync();
    expect(await DriftTransactionRepository(db).getAll(), hasLength(1));
    expect(await DriftSuspectedDuplicateRepository(db).getAll(), hasLength(1));
  });

  group('server needs_review', () {
    test('flag ON + valid native raw => confirmed tx + marker, no pending',
        () async {
      final backend = _Backend([_needsReview('n1')]);
      final svc = service(backend, native: nativeMsg('n1', _validRaw));

      await svc.sync();

      final txs = await DriftTransactionRepository(db).getAll();
      expect(txs, hasLength(1));
      expect(txs.single.status.name, 'confirmed');
      expect(await svc.transactionIdForPayload('n1'), txs.single.id);
      expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
      expect(parserInputs, [_validRaw]);
      // The native drain's guard: already imported => no double transaction.
      expect(await svc.isPayloadImported('n1'), isTrue);
      await svc.sync();
      expect(await DriftTransactionRepository(db).getAll(), hasLength(1));
    });

    test('flag ON + locally invalid => Smart Inbox, no pending row', () async {
      final backend = _Backend([_needsReview('n2')]);
      final svc =
          service(backend, native: nativeMsg('n2', 'hello, not a bank text'));

      await svc.sync();

      expect(await DriftTransactionRepository(db).getAll(), isEmpty);
      expect(await DriftSmartInboxRepository(db).getOpen(), hasLength(1));
      expect(
          await svc.transactionIdForPayload('n2'), startsWith('smart_inbox:'));
    });

    test('flag OFF => unchanged pending transaction', () async {
      flagOn = false;
      final backend = _Backend([_needsReview('n3')]);
      final svc = service(backend, native: nativeMsg('n3', _validRaw));

      await svc.sync();

      expect(recoverCalls, 0);
      final txs = await DriftTransactionRepository(db).getAll();
      expect(txs, hasLength(1));
      expect(txs.single.status.name, 'pending');
      expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
    });
  });
}
