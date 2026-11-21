// Root-cause investigation (iOS, build 44): a bank SMS captured by the App
// Intent while the person's COMMITTED settings had Cloud Sync ON and Smart
// Analysis ON was parked in Smart Inbox as `smart_analysis_off`.
//
// The Dart side decides only from `settings.aiConsentGranted` and the native
// item's `localOnly` stamp. With the settings ON, the only way to the park is a
// `localOnly == true` item. Native (SharedCaptureStore.enqueue) stamps it when
// the owner's consent mirror is missing or has neither cloud nor ai at the
// moment of capture. These tests show that the native mirror can be left
// restrictive ({cloud:false, ai:false}) while the settings are ON, that the
// ordinary resume / startup sync (`syncBackendState`) does NOT repair it, and
// that a capture taken in that state ends up `smart_analysis_off` through the
// production import wiring.
//
// The native side is MODELLED here (the mirror map and the enqueue stamping
// rule of SharedCaptureStore.swift:519-530); everything else is the real Dart
// code. Tests named "BUG:" assert the current, faulty behaviour, so they PASS
// while the bug exists.
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/smart_analysis_consent.dart';
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
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
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

class _Backend extends CaptureBackendClient {
  _Backend() : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  @override
  Future<String> registerDevice(
          {required String installId, String platform = 'ios'}) async =>
      'device-secret';
}

class _ConsentServer extends CaptureConsentClient {
  _ConsentServer() : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  int calls = 0;
  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
    required int clientGeneration,
  }) async =>
      calls++;
  @override
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
    required int clientGeneration,
  }) async =>
      calls++;
}

/// The native App Group state that matters here: the per-owner consent
/// mirror, and the enqueue stamping rule of SharedCaptureStore.enqueue
/// (SharedCaptureStore.swift:519-530).
class _NativeModel {
  final Map<String, ({bool cloud, bool ai})> mirror = {};
  final writes = <String>[];

  void write(String uid, bool cloud, bool ai, String by) {
    mirror[uid] = (cloud: cloud, ai: ai);
    writes.add('$by:cloud=$cloud,ai=$ai');
  }

  /// SharedCaptureStore.publishRestrictiveCaptureOwner (swift:3592): every
  /// successful restrictive owner publication writes {false,false}. Reached
  /// from Dart by `_publishNativeLifetime` on a fresh / explicit admission and
  /// on the ASR successor adoption (app_session.dart:2041, :3266).
  void publishRestrictiveOwner(String uid) =>
      write(uid, false, false, 'publishRestrictiveCaptureOwner');

  /// `stamped.localOnly = true` when the mirror is missing or has neither
  /// Cloud nor smart analysis.
  bool stampsLocalOnly(String uid) {
    final m = mirror[uid];
    return m == null || (m.cloud != true && m.ai != true);
  }
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<bool> isLinkedForCloud() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'uid-a', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
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
  var uploads = 0;
  @override
  Future<CaptureServerFetch> fetchResults() async =>
      const CaptureServerFetch(CaptureFetchStatus.ok);
  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async {
    uploads++;
    return CaptureUploadStatus.unavailable;
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}

class _NoAi implements AiParserClient {
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async =>
      throw StateError('no AI on the import path');
}

const _raw = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late _NativeModel native;
  late _ConsentServer server;
  var linkPublishes = 0;

  CaptureDeviceRegistrationService registration() =>
      CaptureDeviceRegistrationService(
        settingsRepository: repo,
        smartAnalysisRecord: SmartAnalysisConsentRecord.memory({}),
        client: _Backend(),
        consentClient: server,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
          String? ownerUid,
          int? transitionGeneration,
        }) async {},
        loadApnsToken: () async => null,
        readSession: () => (uid: 'uid-a', jwt: 'jwt-a'),
        readReplicaOwnerUid: () async => 'uid-a',
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
          int? transitionGeneration,
        }) async =>
            native.write(uid, cloud, ai, 'setConsentMirror'),
        readOwnerEpoch: () async => 0,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
          int? transitionGeneration,
        }) async {
          linkPublishes++;
          native.write(uid, cloud, ai, 'publishActiveOwner');
        },
      );

  Future<void> consent({required bool cloud, required bool ai}) async =>
      repo.saveSettings((await repo.getSettings()).copyWith(
        cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
        aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
      ));

  /// A normal, fully linked Cloud ON + Smart Analysis ON device: verified ack
  /// equal to the settings snapshot, mirror {true,true}.
  Future<CaptureDeviceRegistrationService> linkedDevice() async {
    await consent(cloud: true, ai: true);
    final s = registration();
    await s.linkToCurrentUser();
    expect(native.mirror['uid-a'], (cloud: true, ai: true));
    expect(native.stampsLocalOnly('uid-a'), isFalse);
    native.writes.clear();
    linkPublishes = 0;
    return s;
  }

  setUp(() async {
    CaptureDeviceRegistrationService.debugResetSmartAnalysisEligibility();
    CaptureDeviceRegistrationService.debugResetUnlinkTarget();
    FlutterSecureStorage.setMockInitialValues({});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    native = _NativeModel();
    server = _ConsentServer();
    linkPublishes = 0;
  });
  tearDown(() async => db.close());

  group('the ordinary sync repairs a restrictive native mirror', () {
    test(
        'after a restrictive owner publication (ASR successor / admission), '
        'syncBackendState with Cloud+AI ON and an unchanged ack republishes '
        'the acknowledged mirror; captures are no longer stamped localOnly',
        () async {
      final s = await linkedDevice();

      // SE1 of an ASR adoption (or any fresh admission) — native writes
      // {false,false} itself; no Dart mirror writer is involved.
      native.publishRestrictiveOwner('uid-a');
      expect(native.stampsLocalOnly('uid-a'), isTrue);
      native.writes.clear();

      // What every resume (AppShell._onResume -> _syncNativeCaptureState)
      // and the startup capture_registration step run.
      final callsBefore = server.calls;
      await s.syncBackendState();
      await s.syncBackendState();

      expect(native.writes, isNotEmpty,
          reason: '_projectConsent rewrites the mirror on `ack == snapshot`');
      expect(server.calls, callsBefore,
          reason: 'a verified ack needs no network round trip');
      expect(native.mirror['uid-a'], (cloud: true, ai: true));
      expect(native.stampsLocalOnly('uid-a'), isFalse);
      expect((await repo.getSettings()).aiConsentGranted, isTrue);
      expect((await repo.getSettings()).cloudProcessingEnabled, isTrue);
    });

    test(
        'linkToCurrentUser (AppShell cold-start post-frame) still widens it',
        () async {
      final s = await linkedDevice();
      native.publishRestrictiveOwner('uid-a');
      expect(native.stampsLocalOnly('uid-a'), isTrue);

      await s.linkToCurrentUser();
      expect(linkPublishes, 1);
      expect(native.mirror['uid-a'], (cloud: true, ai: true));
      expect(native.stampsLocalOnly('uid-a'), isFalse);
    });

    test(
        'restrictSmartAnalysisNow whose OFF choice is never committed is '
        'undone by the next syncBackendState (settings still ON)',
        () async {
      final s = await linkedDevice();
      // saveSmartAnalysisChoice(on: false) step 1 — then the commit does not
      // happen (stale scope, write error, app killed).
      await s.restrictSmartAnalysisNow();
      expect(native.mirror['uid-a'], (cloud: false, ai: false));

      await s.syncBackendState();
      expect(native.mirror['uid-a'], (cloud: true, ai: true),
          reason: 'the next syncBackendState republishes the mirror from the '
              'committed settings, as restrictSmartAnalysisNow documents');
      expect(native.stampsLocalOnly('uid-a'), isFalse);
    });
  });

  group('end to end: restrictive mirror at capture time -> smart_analysis_off',
      () {
    late CaptureSyncService sync;
    late DriftTransactionRepository txRepo;
    late _Queue queueRef;
    late _Server serverRef;

    CaptureImportService importService() {
      final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        aiClient: _NoAi(),
        loadAiConsent: () async => false,
        installId: 'install',
      ));
      // Exactly the production wiring (app_providers.dart:1684-1694), iOS.
      return CaptureImportService(
        aiPrimarySelected: () async =>
            smartAnalysisSelected(await repo.getSettings(), ios: true),
        parkWithoutSmartAnalysis: true,
        queue: queueRef,
        server: serverRef,
        captureSyncService: sync,
        receipts: CaptureReceipts(db),
        ingestLocal: CaptureImportService.localIngest(ingest),
        sessionUid: () => 'uid-a',
        replicaOwnerUid: () async => 'uid-a',
        ownershipGuard: _Guard(),
      );
    }

    setUp(() {
      txRepo = DriftTransactionRepository(
        db,
        outboxQueue: LedgerOutboxQueue(
          db: db,
          isPushEnabled: () => true,
          getAuthUserId: () async => 'uid-a',
        ),
      );
      sync = CaptureSyncService(
        settingsRepository: repo,
        transactionRepository: txRepo,
        dedupStore: DriftDedupStore(db),
        smartInboxRepository: DriftSmartInboxRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        registrationService: _Registration(),
        ownershipGuard: _Guard(),
        currentUserId: () => 'uid-a',
        accountRepository: DriftAccountRepository(db),
        backendConfigured: true,
        loadInstallId: () async => 'install',
      );
      queueRef = _Queue();
      serverRef = _Server();
    });

    SharedCapturedMessage capture(String id) => SharedCapturedMessage(
          id: id,
          text: _raw,
          sender: 'SNB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: DateTime.utc(2026, 11, 21, 6, 50),
          // The App Intent's `.localOnly` branch stores it as `sent`
          // (BankMessageShortcuts.swift:135-137).
          status: 'sent',
          ownerUid: 'uid-a',
          localOnly: native.stampsLocalOnly('uid-a') ? true : null,
        );

    Future<String?> reasonOf(String id) async {
      final row = await db
          .customSelect(
              "SELECT metadata_json FROM smart_inbox_items WHERE payload_id = '$id';")
          .getSingleOrNull();
      return RegExp(r'"review_reason":"([a-z_]+)"')
          .firstMatch(row?.read<String?>('metadata_json') ?? '')
          ?.group(1);
    }

    test(
        'settings Cloud ON + Smart Analysis ON: after a restrictive '
        'publication, the resume sync repairs the mirror, so the next capture '
        'is sent for analysis, not parked smart_analysis_off', () async {
      final s = await linkedDevice();
      native.publishRestrictiveOwner('uid-a');
      await s.syncBackendState(); // resume: repairs the mirror

      queueRef.items.add(capture('cap-0950'));
      await importService().run();

      expect(smartAnalysisSelected(await repo.getSettings(), ios: true), isTrue);
      expect(await reasonOf('cap-0950'), isNull);
      expect(serverRef.uploads, 1);
    });

    test('control: mirror {true,true} at capture time -> not parked', () async {
      await linkedDevice();
      queueRef.items.add(capture('cap-ok'));
      await importService().run();
      expect(await reasonOf('cap-ok'), isNull);
      expect(serverRef.uploads, 1, reason: 'sent for analysis instead');
    });
  });
}
