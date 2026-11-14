import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/consent_capability.dart';
import 'package:flutter/foundation.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
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

class _FakeRegistrationService implements CaptureDeviceRegistrationService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  void dispose() {}

  @override
  Future<void> retryPendingRevocation() async {}

  @override
  Future<int?> pendingRevocationGeneration(String owner) async => null;

  _FakeRegistrationService({this.linked = true});

  final bool linked;

  @override
  Future<void> disableCloud({
    required Future<void> Function() commitLocalOff,
  }) =>
      commitLocalOff();

  @override
  bool isDisablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      false;

  @override
  Future<void> resolvePendingDisable(
      {EgressResolutionToken? resolution}) async {}
  @override
  Future<void> reconcileAfterAdmission({
    required AdmissionAuthority authority,
    required bool Function() isCurrentScope,
  }) async {}

  @override
  Future<void> enableCloud({required ConsentWrite write}) async {}

  @override
  Future<void> enableCloudForTest({
    required Future<void> Function() commitLocalOn,
    AdmissionAuthority? authority,
  }) =>
      commitLocalOn();

  @override
  bool isEnablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      false;

  @override
  Future<ExplicitEnableRoute> explicitEnableRoute(
          UserSettingsEntity current, UserSettingsEntity updated,
          {required String ownerUid}) async =>
      ExplicitEnableRoute.plainSave;

  @override
  Future<PendingEnableState> pendingEnableState(UserSettingsEntity stored,
          {required String ownerUid}) async =>
      PendingEnableState.none;

  @override
  Future<bool> pendingProvenanceUnresolved({required String ownerUid}) async =>
      false;

  @override
  Future<void> withdrawPendingEnable({
    required ConsentCapability capability,
    required Future<void> Function() commitLocalOff,
  }) async {}

  @override
  Future<bool> liveOnVerified({String? owner}) async => false;

  @override
  Future<({ServerRevocation status, int generation})?>
      serverRevocation() async => null;

  @override
  Future<({bool cloud, bool ai, int version})?> consentAckSnapshot() async =>
      null;

  @override
  int? get mirroredConsentVersion => null;

  @override
  ValueListenable<CaptureRegistrationStatus> get status => ValueNotifier(
      const CaptureRegistrationStatus(CaptureRegistrationPhase.notRequested));

  @override
  Future<void> retry() async {}

  @override
  Future<void> syncBackendState() async {}

  @override
  Future<bool> isLinkedForCloud() async => linked;

  @override
  Future<void> syncNativeState() async {}

  @override
  Future<String?> readDeviceSecret() async => 'device-secret';

  @override
  Future<void> linkToCurrentUser(
      {AdmissionAuthority? admissionAuthority}) async {}

  @override
  Future<void> unlinkCurrentDevice() async {}

  @override
  Future<void> syncApnsToken(ApnsTokenInfo token) async {}
}

class _FakeCaptureBackendClient implements CaptureBackendClient {
  _FakeCaptureBackendClient(
    this._captures, {
    this.afterFetch,
    this.beforeRelayAck,
  });

  final List<ProcessedCaptureDto> _captures;
  final Future<void> Function()? afterFetch;
  final Future<void> Function(List<String> payloadIds)? beforeRelayAck;
  final ackedPayloadIds = <String>[];
  final processedPayloadIds = <String>[];
  var syncCalls = 0;
  bool? lastAllowAi;
  String? lastOwnerUid;
  int? lastOwnerGeneration;
  bool? lastSchemaV2;
  String? lastLocale;
  Object? processError;

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
    processedPayloadIds.add(payloadId);
    if (processError != null) throw processError!;
    lastAllowAi = allowAi;
    lastOwnerUid = ownerUid;
    lastOwnerGeneration = ownerGeneration;
    lastSchemaV2 = schemaV2;
    lastLocale = locale;
  }

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    syncCalls++;
    if (ackPayloadIds.isNotEmpty) {
      await beforeRelayAck?.call(ackPayloadIds);
    } else {
      await afterFetch?.call();
    }
    ackedPayloadIds.addAll(ackPayloadIds);
    return ackPayloadIds.isEmpty ? _captures : const [];
  }

  @override
  Future<void> linkDevice({
    required String installId,
    required String deviceSecret,
    required String jwt,
  }) async {}

  @override
  Future<void> setDeviceConsent({
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {}

  @override
  Future<void> unlinkDevice({
    required String installId,
    required String deviceSecret,
  }) async {}

  @override
  Future<void> registerPushToken({
    required String installId,
    required String deviceSecret,
    required String apnsToken,
    required String apnsEnvironment,
  }) async {}

  @override
  Future<String> registerDevice({
    required String installId,
    String platform = 'ios',
  }) async =>
      'device-secret';
}

class _MutableOwnershipGuard extends OwnershipGuard {
  _MutableOwnershipGuard(String? uid, String? generation)
      : _current = AdmissionToken(ownerUid: uid, generation: generation);

  AdmissionToken _current;

  void rotate(String? uid, String? generation) {
    _current = AdmissionToken(ownerUid: uid, generation: generation);
  }

  @override
  Future<AdmissionToken> capture() async => _current;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _current;
}

void main() {
  late AppDatabase db;
  late DriftUserSettingsRepository settingsRepository;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    settingsRepository = DriftUserSettingsRepository(db);
    final settings = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(
      settings.copyWith(cloudConsentState: ConsentState.accepted),
    );
  });

  tearDown(() async {
    await db.close();
  });

  CaptureSyncService service(
    _FakeCaptureBackendClient client, {
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    OwnershipGuard? ownershipGuard,
    String? Function()? currentUserId,
    bool linked = true,
    CaptureUploadAuthorization authorization = const CaptureUploadAuthorization(
        CaptureUploadDecision.allowed,
        ownerUid: 'user-A',
        ownerGeneration: 4),
  }) {
    return CaptureSyncService(
      settingsRepository: settingsRepository,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(linked: linked),
      ownershipGuard:
          ownershipGuard ?? _MutableOwnershipGuard('user-A', 'generation-A'),
      currentUserId: currentUserId ?? () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      coordinator: coordinator,
      authorizeUpload: (_) async => authorization,
    );
  }

  test('MALI-029: a batch of captures prefetches accounts ONCE, not per row',
      () async {
    final counting = _CountingAccountRepository(DriftAccountRepository(db));
    final client = _FakeCaptureBackendClient([
      for (var i = 0; i < 8; i++)
        _capture(
          payloadId: 'batch-$i',
          status: 'processed',
          currency: i.isEven ? 'SAR' : 'EGP',
        ),
    ]);
    final svc = CaptureSyncService(
      settingsRepository: settingsRepository,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _FakeRegistrationService(),
      ownershipGuard: _MutableOwnershipGuard('user-A', 'generation-A'),
      currentUserId: () => 'user-A',
      accountRepository: counting,
      client: client,
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
    );

    await svc.sync();

    // 8 captures across 2 currencies → the accounts table is read ONCE for the
    // whole run (was one getAll() per captured row before batching).
    expect(counting.getAllCalls, 1,
        reason: 'accounts prefetched once per sync run, not per capture');
  });

  test(
      'relay redelivery repairs a missing receipt without blocking newer captures',
      () async {
    final older = _capture(payloadId: 'older-capture', status: 'processed');
    await service(_FakeCaptureBackendClient([older])).sync();
    // A ledger restore/pull can preserve the transaction without its local
    // capture receipt. A redelivery must adopt it, not INSERT its ID again.
    await db.customStatement('DELETE FROM dedup_hashes;');
    final client = _FakeCaptureBackendClient([
      older,
      // A different purchase (identical results would be a suspected
      // duplicate of the older one, by design).
      _capture(
          payloadId: 'newer-capture',
          status: 'processed',
          amountText: '43',
          numericAmount: 43),
    ]);
    final result = await service(client).sync();
    expect(result.importedPayloadIds, {'older-capture', 'newer-capture'});
    expect((await DriftTransactionRepository(db).getAll()).length, 2);
    expect(client.ackedPayloadIds, ['older-capture', 'newer-capture']);
  });

  test('needs_review capture records its transaction id', () async {
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: 'payload-needs-review', status: 'needs_review'),
    ]);
    final syncService = service(client);

    final result = await syncService.sync();
    final transactionId =
        await syncService.transactionIdForPayload('payload-needs-review');
    final transactions = await DriftTransactionRepository(db).getAll();

    expect(result.needsReviewTransactionIds, [transactionId]);
    expect(client.ackedPayloadIds, ['payload-needs-review']);
    expect(transactions.single.status, TransactionStatus.pending);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty,
        reason: 'needs_review keeps its existing pending-transaction path');
  });

  test(
      'a backend merchant that is the SMS hour ("01") is never stored; '
      'an IPN/InstaPay transfer is named InstaPay', () async {
    const ipn = 'IPN transfer sent with amount of EGP 1.00 from 1938 on '
        '28/10 at 01:43 AM. Ref# 22762b03. For more details call 16607';
    final client = _FakeCaptureBackendClient([
      _capture(
          payloadId: 'ipn-hour',
          status: 'processed',
          currency: 'EGP',
          type: 'transfer',
          direction: 'debit', // outgoing: stored as a payment, merchant kept
          rawMessage: ipn,
          merchant: '01'),
      _capture(
          payloadId: 'card-hour',
          status: 'processed',
          rawMessage: 'Debited SAR 42 from card ending 1234 at 10:37 AM',
          merchant: '10'),
      _capture(payloadId: 'real-merchant', status: 'processed'),
    ]);

    await service(client).sync();

    final byId = {
      for (final tx in await DriftTransactionRepository(db).getAll()) tx.id: tx
    };
    expect(byId['ipn-hour']!.rawMerchant, 'InstaPay');
    expect(byId['card-hour']!.rawMerchant, isNull);
    expect(byId['real-merchant']!.rawMerchant, 'Coffee');
  });

  test('budget event report excludes already-imported relay deliveries',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: 'budget-redelivery', status: 'processed'),
    ]);
    final syncService = service(client);
    final first = await syncService.sync();
    expect(
        first.committedTransactions.map((tx) => tx.id), ['budget-redelivery']);
    final second = await syncService.sync();
    expect(second.committedTransactions, isEmpty);
  });

  test('processed capture is not recorded for review', () async {
    final client = _FakeCaptureBackendClient([
      _capture(payloadId: 'payload-processed', status: 'processed'),
    ]);

    final result = await service(client).sync();

    expect(result.needsReviewTransactionIds, isEmpty);
    expect(client.ackedPayloadIds, ['payload-processed']);
    expect(
        result.committedTransactions.map((tx) => tx.id), ['payload-processed']);
    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions.single.amountMoney, Money.parse('42', 'SAR'));
    expect(transactions.single.status, TransactionStatus.confirmed);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
  });

  group('NEW-H-2 backend-import ownership admission', () {
    test('A -> B after fetch aborts before transaction import or relay ack',
        () async {
      final guard = _MutableOwnershipGuard('user-A', 'generation-A');
      var currentUserId = 'user-A';
      final client = _FakeCaptureBackendClient(
        [_capture(payloadId: 'payload-owned-by-A', status: 'processed')],
        afterFetch: () async {
          guard.rotate('user-B', 'generation-B');
          currentUserId = 'user-B';
        },
      );
      final syncService = service(
        client,
        ownershipGuard: guard,
        currentUserId: () => currentUserId,
      );
      final accountIdsBefore =
          (await DriftAccountRepository(db).getAll()).map((a) => a.id).toSet();

      await expectLater(
        syncService.sync(),
        throwsA(isA<StaleOwnershipException>()),
      );

      expect(await DriftTransactionRepository(db).getAll(), isEmpty,
          reason: "A's capture must not enter B's transaction context");
      expect(
        (await DriftAccountRepository(db).getAll()).map((a) => a.id).toSet(),
        accountIdsBefore,
        reason: "A's currency account must not enter B's context",
      );
      expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty);
      expect(
        await syncService.transactionIdForPayload('payload-owned-by-A'),
        isNull,
      );
      expect(client.ackedPayloadIds, isEmpty,
          reason: 'a stale admission must leave the relay capture retryable');
    });

    test('A -> B after fetch aborts before Smart Inbox review or relay ack',
        () async {
      final guard = _MutableOwnershipGuard('user-A', 'generation-A');
      var currentUserId = 'user-A';
      final client = _FakeCaptureBackendClient(
        [
          const ProcessedCaptureDto(
            payloadId: 'rejected-owned-by-A',
            status: 'rejected',
            parsed: {},
            notification: {},
            sanitizedText: 'Unparseable capture owned by A',
          ),
        ],
        afterFetch: () async {
          guard.rotate('user-B', 'generation-B');
          currentUserId = 'user-B';
        },
      );
      final syncService = service(
        client,
        ownershipGuard: guard,
        currentUserId: () => currentUserId,
      );

      await expectLater(
        syncService.sync(),
        throwsA(isA<StaleOwnershipException>()),
      );

      expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty,
          reason: "A's review row must not enter B's Smart Inbox context");
      expect(
        await syncService.transactionIdForPayload('rejected-owned-by-A'),
        isNull,
      );
      expect(client.ackedPayloadIds, isEmpty);
    });

    test('same admission imports transaction and review then acks both',
        () async {
      final guard = _MutableOwnershipGuard('user-A', 'generation-A');
      final client = _FakeCaptureBackendClient([
        _capture(payloadId: 'same-owner-transaction', status: 'processed'),
        const ProcessedCaptureDto(
          payloadId: 'same-owner-review',
          status: 'rejected',
          parsed: {},
          notification: {},
          sanitizedText: 'Same-owner unparseable capture',
        ),
      ]);

      final result = await service(
        client,
        ownershipGuard: guard,
        currentUserId: () => 'user-A',
      ).sync();

      expect(await DriftTransactionRepository(db).getAll(), hasLength(1));
      expect(await DriftSmartInboxRepository(db).getOpen(), hasLength(1));
      expect(result.importedPayloadIds,
          {'same-owner-transaction', 'same-owner-review'});
      expect(client.ackedPayloadIds,
          ['same-owner-transaction', 'same-owner-review']);
    });
  });

  test('backend rejected capture leaves a durable review, not a bare marker',
      () async {
    const payloadId = 'payload-backend-rejected';
    const sanitizedRaw = 'Card activity could not be parsed [ACCOUNT]';
    late CaptureSyncService syncService;
    var relayAckObservedDurableState = false;
    final client = _FakeCaptureBackendClient(
      [
        ProcessedCaptureDto(
          payloadId: payloadId,
          status: 'rejected',
          parsed: const {},
          notification: const {},
          sanitizedText: sanitizedRaw,
          failureReason: 'not_parseable',
          createdAt: DateTime.utc(2026, 8, 20, 12),
        ),
      ],
      beforeRelayAck: (payloadIds) async {
        final reviews = await DriftSmartInboxRepository(db).getOpen();
        relayAckObservedDurableState = payloadIds.single == payloadId &&
            reviews.length == 1 &&
            reviews.single.payloadId == payloadId &&
            await syncService.transactionIdForPayload(payloadId) ==
                'smart_inbox:local_capture:$payloadId';
      },
    );
    syncService = service(client);

    await syncService.sync();

    expect(relayAckObservedDurableState, isTrue,
        reason: 'review row + marker must commit before relay/native ack');
    final reviews = await DriftSmartInboxRepository(db).getOpen();
    expect(reviews, hasLength(1));
    expect(reviews.single.payloadId, payloadId);
    expect(reviews.single.body, sanitizedRaw);
    expect(
      await syncService.transactionIdForPayload(payloadId),
      'smart_inbox:local_capture:$payloadId',
    );
    expect(await db.count('transactions'), 0);
  });

  test('backend rejected redelivery creates exactly one review item', () async {
    const payloadId = 'payload-backend-rejected-redelivery';
    final client = _FakeCaptureBackendClient([
      const ProcessedCaptureDto(
        payloadId: payloadId,
        status: 'rejected',
        parsed: {},
        notification: {},
        sanitizedText: 'Unparseable transfer [ACCOUNT]',
        failureReason: 'not_parseable',
      ),
    ]);
    final syncService = service(client);

    await syncService.sync();
    await syncService.sync();

    final reviews = await DriftSmartInboxRepository(db).getOpen();
    expect(reviews, hasLength(1));
    expect(reviews.single.id, 'local_capture:$payloadId');
    expect(client.ackedPayloadIds, [payloadId, payloadId]);
  });

  test('backend rejected review and marker roll back together', () async {
    const payloadId = 'payload-backend-rejected-atomic';
    final client = _FakeCaptureBackendClient([
      const ProcessedCaptureDto(
        payloadId: payloadId,
        status: 'rejected',
        parsed: {},
        notification: {},
        sanitizedText: 'Atomic unparseable capture',
      ),
    ]);
    final syncService = service(client);
    await db.customStatement('''
      CREATE TRIGGER fail_rejected_payload_marker
      BEFORE INSERT ON dedup_hashes
      WHEN NEW.hash = 'capture_payload:$payloadId'
      BEGIN
        SELECT RAISE(ABORT, 'forced_marker_failure');
      END;
    ''');

    // F7: a failing capture no longer aborts the whole relay run (it would
    // block every later capture); it is reported as failed and left un-ACKed.
    final result = await syncService.sync();
    expect(result.failedPayloadIds, {payloadId});
    expect(result.importedPayloadIds, isEmpty);

    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty,
        reason: 'the preceding review insert must roll back with the marker');
    expect(await syncService.transactionIdForPayload(payloadId), isNull);
    expect(client.ackedPayloadIds, isEmpty,
        reason: 'the relay/native copy remains when the DB commit fails');
  });

  test('bare legacy rejected marker cannot authorize ack until repaired',
      () async {
    const payloadId = 'payload-legacy-bare-rejected';
    final client = _FakeCaptureBackendClient([
      const ProcessedCaptureDto(
        payloadId: payloadId,
        status: 'rejected',
        parsed: {},
        notification: {},
        sanitizedText: 'Legacy unparseable capture',
      ),
    ]);
    final syncService = service(client);
    await syncService.markPayloadImported(
      payloadId: payloadId,
      transactionId: 'rejected:$payloadId',
    );

    expect(await syncService.isPayloadImported(payloadId), isFalse,
        reason: 'a bare marker must not delete the last durable native copy');

    await syncService.sync();

    expect(await DriftSmartInboxRepository(db).getOpen(), hasLength(1));
    expect(await syncService.isPayloadImported(payloadId), isTrue,
        reason: 'the legacy marker is safe only after its review row commits');
    expect(client.ackedPayloadIds, [payloadId]);
  });

  test('replay uses current app language instead of the old device locale',
      () async {
    final client = _FakeCaptureBackendClient([]);
    final syncService = service(client);
    final native = SharedCapturedMessage(
      id: 'language-replay',
      text: 'IPN transfer EGP 1.00',
      source: CapturedMessageSource.iosShortcut,
      status: 'pendingSend',
      receivedAt: DateTime.utc(2026, 11, 9),
      locale: 'en_US',
    );
    final settings = await settingsRepository.getSettings();
    await settingsRepository.saveSettings(settings.copyWith(language: 'ar'));
    expect(await syncService.retryPendingSend(native), isTrue);
    expect(client.lastLocale, 'ar');
    await settingsRepository.saveSettings(settings.copyWith(language: 'en'));
    expect(await syncService.retryPendingSend(native), isTrue);
    expect(client.lastLocale, 'en');
  });

  test('pendingSend rejected replay is durable before native ack is allowed',
      () async {
    const payloadId = 'payload-pending-send-rejected';
    const sanitizedRaw = 'Unsupported debit [CARD] [AMOUNT]';
    final client = _FakeCaptureBackendClient([
      const ProcessedCaptureDto(
        payloadId: payloadId,
        status: 'rejected',
        parsed: {},
        notification: {},
        sanitizedText: sanitizedRaw,
        failureReason: 'not_parseable',
      ),
    ]);
    final syncService = service(client);
    final native = SharedCapturedMessage(
      id: payloadId,
      text: 'Unsupported debit 1234 500',
      source: CapturedMessageSource.iosShortcut,
      status: 'pendingSend',
      receivedAt: DateTime.utc(2026, 8, 20, 12),
    );

    expect(await syncService.retryPendingSend(native), isTrue);
    await syncService.sync();

    // This is the exact predicate used by app_shell's marker-driven native ack
    // path after pendingSend succeeds. It becomes true only after the review
    // row and marker transaction above has committed.
    expect(await syncService.isPayloadImported(payloadId), isTrue);
    final reviews = await DriftSmartInboxRepository(db).getOpen();
    expect(reviews, hasLength(1));
    expect(reviews.single.payloadId, payloadId);
    expect(reviews.single.body, sanitizedRaw);
    expect(client.processedPayloadIds, [payloadId]);
  });

  group('A-12-min R2/R5: the replay and the legacy sync are gated', () {
    SharedCapturedMessage pending() => SharedCapturedMessage(
          id: 'payload-gate',
          text: 'Debit 1234 500',
          source: CapturedMessageSource.iosShortcut,
          status: 'pendingSend',
          receivedAt: DateTime.utc(2026, 8, 20, 12),
        );

    test(
        'a localOnly pendingSend (a killed Cloud-OFF intent) never uploads '
        'even with Cloud ON', () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc =
          service(client, authorization: CaptureUploadAuthorization.denied);
      expect(await svc.retryPendingSend(pending()), isFalse);
      expect(client.processedPayloadIds, isEmpty);
    });

    test('a waiting item is retried later, never uploaded', () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client,
          authorization:
              const CaptureUploadAuthorization(CaptureUploadDecision.waiting));
      await expectLater(svc.retryPendingSend(pending()),
          throwsA(isA<CaptureBackendException>()));
      expect(client.processedPayloadIds, isEmpty);
    });

    test('a localOnly item that is still .pending is never replayed', () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client);
      final item = SharedCapturedMessage(
        id: 'payload-pending-local',
        text: 'Debit 1234 500',
        source: CapturedMessageSource.iosShortcut,
        status: 'pending',
        localOnly: true,
        receivedAt: DateTime.utc(2026, 8, 20, 12),
      );
      expect(await svc.retryPendingSend(item), isFalse);
      expect(client.processedPayloadIds, isEmpty);
    });

    test('an unlinked install (no uid-bound ack) never replays', () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client, linked: false);
      expect(await svc.retryPendingSend(pending()), isFalse);
      expect(client.processedPayloadIds, isEmpty);
    });

    test('an allowed replay uses the owner mirror\'s AI flag, not settings',
        () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client,
          authorization: const CaptureUploadAuthorization(
              CaptureUploadDecision.allowed,
              ownerUid: 'user-A',
              allowAi: false,
              contractV2: true,
              ownerGeneration: 4));
      expect(await svc.retryPendingSend(pending()), isTrue);
      expect(client.processedPayloadIds, ['payload-gate']);
      expect(client.lastAllowAi, isFalse);
      expect(client.lastOwnerUid, 'user-A', reason: 'v2 contract sends owner');
      expect(client.lastOwnerGeneration, 4);
      expect(client.lastSchemaV2, isTrue);
    });

    // Astra G C.1 (updated truthfully): this test used to pin "the legacy
    // contract replay sends no owner_uid". The replay now ALWAYS sends the
    // stamped owner and its generation, on schema v1 too.
    test('the legacy (v1) replay still sends owner_uid and owner_generation',
        () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client);
      expect(await svc.retryPendingSend(pending()), isTrue);
      expect(client.lastOwnerUid, 'user-A');
      expect(client.lastOwnerGeneration, 4);
      expect(client.lastSchemaV2, isFalse);
    });

    test('an ownerless authorization (no owner generation) is never uploaded',
        () async {
      final client = _FakeCaptureBackendClient(const []);
      final svc = service(client,
          authorization: const CaptureUploadAuthorization(
              CaptureUploadDecision.allowed,
              ownerUid: 'user-A'));
      expect(await svc.retryPendingSend(pending()), isFalse);
      expect(client.processedPayloadIds, isEmpty);
    });

    for (final code in const [
      'capture_owner_mismatch',
      'capture_owner_conflict',
      'capture_id_conflict',
      'capture_expired',
    ]) {
      test(
          'a 409 $code is terminal: no upload retry, the caller parses locally',
          () async {
        final client = _FakeCaptureBackendClient(const [])
          ..processError =
              const CaptureBackendException('process_ios_sms_failed_409');
        final svc = service(client);
        // false = "not uploaded": app_shell falls through to the local
        // deterministic parser (no AI) instead of retrying forever.
        expect(await svc.retryPendingSend(pending()), isFalse);
        expect(await svc.retryPendingSend(pending()), isFalse);
      });
    }

    test('a 5xx replay failure still propagates (retried later)', () async {
      final client = _FakeCaptureBackendClient(const [])
        ..processError =
            const CaptureBackendException('process_ios_sms_failed_503');
      await expectLater(service(client).retryPendingSend(pending()),
          throwsA(isA<CaptureBackendException>()));
    });

    test('the legacy sync-captures never runs without a uid-bound ack',
        () async {
      final client = _FakeCaptureBackendClient([
        _capture(payloadId: 'p-unlinked', status: 'processed'),
      ]);
      final result = await service(client, linked: false).sync();
      expect(result.importedPayloadIds, isEmpty);
      expect(client.ackedPayloadIds, isEmpty);
      expect(client.syncCalls, 0, reason: 'zero legacy sync-captures calls');
    });
  });

  test('malformed non-rejected relay also becomes durable review work',
      () async {
    const payloadId = 'payload-malformed-needs-review';
    final client = _FakeCaptureBackendClient([
      const ProcessedCaptureDto(
        payloadId: payloadId,
        status: 'needs_review',
        parsed: {'rawMessage': 'Malformed legacy relay capture'},
        notification: {},
        sanitizedText: 'Malformed legacy relay capture',
      ),
    ]);
    final syncService = service(client);

    await syncService.sync();

    final reviews = await DriftSmartInboxRepository(db).getOpen();
    expect(reviews, hasLength(1));
    expect(reviews.single.payloadId, payloadId);
    expect(
      await syncService.transactionIdForPayload(payloadId),
      'smart_inbox:local_capture:$payloadId',
    );
    expect(await db.count('transactions'), 0);
  });

  test('processed capture prefers exact amount_text over legacy JSON number',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-exact-text',
        status: 'processed',
        amountText: '19.99',
        numericAmount: 42,
      ),
    ]);

    await service(client).sync();
    final transactions = await DriftTransactionRepository(db).getAll();

    expect(transactions.single.amountMoney, Money.parse('19.99', 'SAR'));
    expect(transactions.single.status, TransactionStatus.confirmed);
  });

  test('numeric-only legacy capture is imported as pending review', () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-legacy-numeric',
        status: 'processed',
        includeAmountText: false,
      ),
    ]);

    final result = await service(client).sync();
    final transactions = await DriftTransactionRepository(db).getAll();

    expect(transactions, hasLength(1));
    expect(transactions.single.status, TransactionStatus.pending);
    expect(transactions.single.amountMoney.currency, 'SAR');
    expect(result.needsReviewTransactionIds, [transactions.single.id]);
  });

  // MALI-026 (B8-2.10 §12/§13) — canonical-mode old-backend enforcement through
  // the REAL CaptureSyncService (not the pure resolver).
  test('§12 canonical mode: numeric-only old backend can NEVER auto-confirm',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-canonical-numeric',
        status: 'processed',
        includeAmountText: false, // old numeric-only backend
      ),
    ]);
    await service(
      client,
      coordinator:
          const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
    ).sync();
    final tx = (await DriftTransactionRepository(db).getAll()).single;
    expect(tx.status, TransactionStatus.pending); // forced to review
  });

  test('§13 canonical mode: exact amount_text enters canonical authority',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-canonical-exact',
        status: 'processed',
        includeAmountText: true,
        amountText: '42.00',
      ),
    ]);
    await service(
      client,
      coordinator:
          const FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical),
    ).sync();
    final tx = (await DriftTransactionRepository(db).getAll()).single;
    expect(tx.status, TransactionStatus.confirmed);
  });

  test('AI hybrid relay capture keeps the smart transaction source', () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-ai-hybrid',
        status: 'processed',
        parserSource: 'ai_hybrid',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions.single.source, TransactionSourceEntity.aiParsed);
  });

  test('processed capture is assigned to a matching currency account',
      () async {
    final accountRepo = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 7, 5, 9);
    await accountRepo.create(AccountEntity(
      id: '',
      name: 'Main SAR',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-egp',
        status: 'processed',
        currency: 'EGP',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.currency, 'EGP');
    expect(transactions.single.accountId, isNotNull);

    final account = await accountRepo.getById(transactions.single.accountId!);
    expect(account?.currency, 'EGP');
  });

  test('outward transfer is grounded to payment so it counts as spending',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-out',
        status: 'processed',
        type: 'transfer',
        direction: 'debit',
        rawMessage: 'تم تحويل EGP 42 من حسابك إلى أحمد',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.payment);
  });

  test('inward transfer is grounded to income', () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-in',
        status: 'processed',
        type: 'transfer',
        direction: 'credit',
        rawMessage: 'حوالة واردة EGP 42 من أحمد',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.income);
  });

  test('internal transfer between own accounts stays a neutral transfer',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-transfer-internal',
        status: 'processed',
        type: 'transfer',
        direction: 'debit',
        rawMessage: 'تحويل داخلي EGP 42 بين حساباتك',
      ),
    ]);

    await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionTypeEntity.transfer);
  });

  test('failed ack followed by dedup prune must not re-import the capture',
      () async {
    // ack يفشل دائمًا — يبقى صف الـ relay على الخادم، وسجل الاستيراد المحلي
    // (capture_payload:) هو الحماية الوحيدة من الاستيراد الثاني.
    final client = _AckFailingBackendClient([
      _capture(payloadId: 'payload-ack-fails', status: 'processed'),
    ]);
    final syncService = service(client);

    // فشل الـ ack يصل للمستدعي (يلتقطه app_shell) — الاستيراد نفسه اكتمل.
    await expectLater(
      syncService.sync(),
      throwsA(isA<CaptureBackendException>()),
    );
    expect(await db.count('transactions'), 1);

    // كان prune يحذف كل علامات capture_payload: لأنها مخزّنة عند epoch-0.
    await db.pruneOldDedupHashes();
    expect(await syncService.isPayloadImported('payload-ack-fails'), isTrue);

    // الخادم ما يزال يعيد نفس الـ capture (لم يُؤكَّد حذفها) — يجب تخطّيها.
    await expectLater(
      syncService.sync(),
      throwsA(isA<CaptureBackendException>()),
    );
    expect(await db.count('transactions'), 1);
  });

  test('prune still removes ordinary dedup hashes older than the cutoff',
      () async {
    final dedupStore = DriftDedupStore(db);
    final old = DateTime.utc(2020, 1, 1);
    await dedupStore.mark('ordinary-old-hash',
        transactionId: 'tx-old', occurredAt: old);
    await db.pruneOldDedupHashes();
    expect(await dedupStore.transactionIdFor('ordinary-old-hash', old), isNull);
  });

  test('concurrent sync calls share one run and import the capture once',
      () async {
    final client = _SlowFetchBackendClient([
      _capture(payloadId: 'payload-concurrent', status: 'processed'),
    ]);
    final syncService = service(client);

    // الاستئناف + ضغطة الإشعار يستدعيان sync() في نفس اللحظة تقريبًا.
    final results = await Future.wait([syncService.sync(), syncService.sync()]);

    expect(client.fetchCalls, 1);
    expect(results[0].importedPayloadIds, {'payload-concurrent'});
    expect(results[1].importedPayloadIds, {'payload-concurrent'});
    expect(await db.count('transactions'), 1);

    // بعد اكتمال الجولة، استدعاء جديد يبدأ جولة جديدة (القفل يتحرّر).
    await syncService.sync();
    expect(client.fetchCalls, 2);
    expect(await db.count('transactions'), 1);
  });

  test('duplicate capture with unresolved original imports as pending review',
      () async {
    final client = _FakeCaptureBackendClient([
      _capture(
        payloadId: 'payload-orphan-duplicate',
        status: 'duplicate',
        duplicateOfPayloadId: 'payload-unknown-original',
      ),
    ]);

    final result = await service(client).sync();

    final transactions = await DriftTransactionRepository(db).getAll();
    expect(transactions, hasLength(1));
    expect(transactions.single.status, TransactionStatus.pending);
    expect(
      transactions.single.duplicateStatus,
      DuplicateStatus.suspiciousDuplicate,
    );
    expect(result.needsReviewTransactionIds, [transactions.single.id]);
    expect(await DriftSmartInboxRepository(db).getOpen(), isEmpty,
        reason: 'duplicate retains its existing pending-transaction path');
  });
}

class _AckFailingBackendClient extends _FakeCaptureBackendClient {
  _AckFailingBackendClient(super.captures);

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    if (ackPayloadIds.isNotEmpty) {
      throw const CaptureBackendException('ack_failed_503');
    }
    return _captures;
  }
}

class _SlowFetchBackendClient extends _FakeCaptureBackendClient {
  _SlowFetchBackendClient(super.captures);

  int fetchCalls = 0;

  @override
  Future<List<ProcessedCaptureDto>> syncCaptures({
    required String installId,
    required String deviceSecret,
    List<String> ackPayloadIds = const [],
  }) async {
    if (ackPayloadIds.isNotEmpty) return const [];
    fetchCalls++;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _captures;
  }
}

ProcessedCaptureDto _capture({
  required String payloadId,
  required String status,
  String currency = 'SAR',
  String type = 'payment',
  String? direction,
  String? rawMessage,
  String? duplicateOfPayloadId,
  String? parserSource,
  bool includeAmountText = true,
  String amountText = '42',
  num numericAmount = 42,
  String? merchant = 'Coffee',
}) {
  return ProcessedCaptureDto(
    payloadId: payloadId,
    status: status,
    parsed: {
      'amount': numericAmount,
      if (includeAmountText) 'amount_text': amountText,
      'currency': currency,
      'type': type,
      if (direction != null) 'direction': direction,
      if (parserSource != null) 'parserSource': parserSource,
      if (duplicateOfPayloadId != null) ...{
        'duplicateStatus': 'suspicious_duplicate',
        'possibleDuplicateOfPayloadId': duplicateOfPayloadId,
      },
      'rawMessage': rawMessage ?? 'Paid $currency 42 at Coffee',
      if (merchant != null) 'merchant': merchant,
      'occurredAt': DateTime.utc(2026, 7, 5, 10).toIso8601String(),
    },
    notification: const {},
    sanitizedText: 'Paid $currency 42 at Coffee',
    createdAt: DateTime.utc(2026, 7, 5, 10),
  );
}

/// Counts getAll() calls to prove MALI-029 pull-batching: accounts are prefetched
/// once per sync run, not reloaded per captured row.
class _CountingAccountRepository implements AccountRepository {
  _CountingAccountRepository(this._inner);
  final AccountRepository _inner;
  int getAllCalls = 0;

  @override
  Future<List<AccountEntity>> getAll() {
    getAllCalls++;
    return _inner.getAll();
  }

  @override
  Future<AccountEntity?> getById(String id) => _inner.getById(id);
  @override
  Future<AccountEntity?> getDefault() => _inner.getDefault();
  @override
  Future<AccountEntity> create(AccountEntity account) => _inner.create(account);
  @override
  Future<AccountEntity> update(AccountEntity account) => _inner.update(account);
  @override
  Future<void> delete(String id) => _inner.delete(id);
  @override
  Future<void> setDefault(String id) => _inner.setDefault(id);
}
