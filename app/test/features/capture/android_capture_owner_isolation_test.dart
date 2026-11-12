// Android capture-queue account isolation and deletion, behavioural.
//
// Executes the REAL Dart flows — NativeCaptureBridge (Android gates),
// NativeCaptureQueue (the sign-out / account-change owner clear bootstrap
// wires), CaptureQueueRemoveBarrier + RemoveDataFlow (Remove data / account
// deletion, real replicas), LegacyCaptureDrain (the Android drain, real Drift DB,
// real AddTransactionUseCase, real AI client over a fake HTTP server) and
// UnboundCapturePromptService (the claim) — against a mocked
// `money_companion/native_capture` channel that models the Android native queue
// contract (DurableCaptureQueue.kt + the MainActivity handlers). The Kotlin side
// of that contract is executed by the JVM harness (scratchpad kt_harness).
//
// `--dart-define=QIRSH_HEAD_NATIVE_MODEL=true` models the HEAD native layer
// instead (no owner methods; peek/ack see every item), for before/after evidence.
// Every message and uid is synthetic.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_retry_ledger.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/legacy_capture_drain.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/unbound_capture_prompt_service.dart';

import '../../core/session/recording_secure_storage.dart';
import '../../domain/local_v2_support.dart';

const bool _headModel = bool.fromEnvironment('QIRSH_HEAD_NATIVE_MODEL');

const _uidA = 'aaaaaaaa-1111-4aaa-8aaa-aaaaaaaaaaaa';
const _uidB = 'bbbbbbbb-2222-4bbb-8bbb-bbbbbbbbbbbb';

// Synthetic bank SMS.
String _purchase(int amount) =>
    'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR $amount.00\n'
    'لدى:SHOP$amount\nفي:2026-04-08 12:45\nالرصيد:SAR 9,000.00';

/// The Android native capture queue as its channel contract defines it
/// (DurableCaptureQueue.kt + MainActivity). Hashes stand in for the Keystore
/// HMAC; no uid is kept.
class _AndroidNative {
  final List<Map<String, Object?>> items = [];
  final calls = <String>[];
  String? owner;
  int generation = 0;
  int counter = 0;
  int epoch = 0;
  String? hint;
  Map<String, Object?>? barrier;
  bool optedIn = false;
  String? optInOwner;
  int backgroundCancels = 0;

  /// The next finishCaptureRemoval cannot delete everything.
  bool failFinish = false;

  String hash(String uid) => sha256
      .convert(utf8.encode('fixed-test-key|${uid.trim().toLowerCase()}'))
      .toString();

  bool visible(Map<String, Object?> i) =>
      owner != null && i['ownerState'] == 'stamped' && i['ownerHash'] == owner;

  bool claimable(Map<String, Object?> i, String h) =>
      i['ownerState'] != 'stamped' && (i['ownerHint'] == null || i['ownerHint'] == h);

  bool sweptBy(Map<String, Object?> i, String h) =>
      i['ownerHash'] == h || i['ownerHint'] == h;

  /// The Settings toggle (MainActivity `setAutomaticSmsCaptureEnabled`).
  void optIn() {
    optedIn = true;
    optInOwner = owner;
  }

  /// SmsCaptureReceiver.onReceive → DurableCaptureQueue.enqueue.
  void sms(String id, String text) {
    if (!optedIn) return; // the two-key lock: no opt-in, nothing read
    if (barrier != null && !_headModel) return; // refused during removal
    items.add({
      'id': id,
      'text': text,
      'sender': 'SNB',
      'source': 'sms',
      'receivedAtEpochMs': DateTime.utc(2026, 4, 8, 9, 45).millisecondsSinceEpoch,
      if (!_headModel) ...owner != null
          ? {'ownerState': 'stamped', 'ownerHash': owner}
          : {'ownerState': 'unbound', 'ownerHint': optInOwner ?? hint},
    });
  }

  /// A queue item written by the pre-upgrade build: no owner fields at all.
  void preUpgradeItem(String id, String text) => items.add({
        'id': id,
        'text': text,
        'sender': 'SNB',
        'source': 'sms',
        'receivedAtEpochMs':
            DateTime.utc(2026, 4, 8, 9, 45).millisecondsSinceEpoch,
      });

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    final args = (call.arguments as Map?)?.cast<String, Object?>() ?? const {};
    if (_headModel) return _headHandle(call, args);
    switch (call.method) {
      case 'peekPendingSharedMessages':
        final mine = items.where(visible).toList();
        return mine.isEmpty ? null : jsonEncode(mine);
      case 'acknowledgeSharedMessage':
        final id = args['payloadId'];
        final hit = items.where((i) => i['id'] == id && visible(i)).toList();
        if (hit.isEmpty) return false;
        items.remove(hit.single);
        return true;
      case 'captureOwnerEpoch':
        return epoch;
      case 'publishCaptureOwner':
        if (barrier != null) {
          throw PlatformException(code: 'removal_in_progress');
        }
        if (args['expectedEpoch'] != epoch) {
          throw PlatformException(code: 'owner_changed');
        }
        final h = hash(args['uid']! as String);
        if (optedIn && optInOwner != null && optInOwner != h) {
          optedIn = false; // another account's opt-in is never inherited
          optInOwner = null;
        } else if (optedIn && optInOwner == null) {
          optInOwner = h;
        }
        if (owner != h) {
          owner = h;
          generation = ++counter;
        }
        hint = h;
        return {'uidHash': h, 'generation': generation};
      case 'getCaptureOwner':
        final uid = args['uid'] as String?;
        if (uid == null || owner != hash(uid)) return null;
        return {'uid': uid, 'uidHash': owner, 'generation': generation};
      case 'clearCaptureOwner':
        if (args['clearHint'] == true && optedIn && optInOwner == null) {
          optedIn = false;
        }
        owner = null;
        epoch++;
        if (args['clearHint'] == true) hint = null;
        backgroundCancels++;
        return null;
      case 'unboundCaptureSummary':
        final h = hash(args['uid']! as String);
        final mine = items.where((i) => claimable(i, h)).toList();
        return {
          'ids': [for (final i in mine) i['id']],
          'senders': {for (final i in mine) i['sender']}.toList(),
          'count': mine.length,
        };
      case 'claimUnboundCaptures':
      case 'discardUnboundCaptures':
        final uid = args['uid']! as String;
        final h = hash(uid);
        if (args['replicaOwnerUid'] != uid ||
            args['sessionUid'] != uid ||
            owner != h ||
            args['generation'] != generation) {
          return {'status': 'owner_mismatch', 'count': 0};
        }
        final ids = (args['ids']! as List).cast<String>().toSet();
        final hits = items.where((i) => ids.contains(i['id'])).toList();
        if (hits.length != ids.length || !hits.every((i) => claimable(i, h))) {
          return {'status': 'stale', 'count': 0};
        }
        for (final i in hits) {
          if (call.method == 'discardUnboundCaptures') {
            items.remove(i);
          } else {
            i
              ..['ownerState'] = 'stamped'
              ..['ownerHash'] = h
              ..remove('ownerHint')
              ..['localOnly'] = true;
          }
        }
        return {'status': 'applied', 'count': hits.length};
      case 'beginCaptureRemoval':
        final h = hash(args['uid']! as String);
        backgroundCancels++;
        optedIn = false;
        optInOwner = null;
        barrier ??= {'nonce': 'n-1', 'uidHash': h, 'startedAt': 'now'};
        if (owner == h) {
          owner = null;
          epoch++;
        }
        return barrier;
      case 'getCaptureRemovalBarrier':
        return barrier;
      case 'finishCaptureRemoval':
        if (barrier == null) return 0;
        final h = hash(args['uid']! as String);
        backgroundCancels++;
        optedIn = false;
        optInOwner = null;
        if (failFinish) {
          failFinish = false;
          throw PlatformException(code: 'removal_incomplete');
        }
        final before = items.length;
        items.removeWhere((i) => sweptBy(i, h));
        if (hint == h) hint = null;
        barrier = null;
        return before - items.length;
      case 'authorizeCaptureUpload':
      case 'setCaptureConsentMirror':
      case 'getCloudEgressState':
        throw StateError('iOS egress call reached the Android queue');
      default:
        return null;
    }
  }

  /// HEAD's Android native layer: no owner methods (`notImplemented`), peek
  /// and ack see every queued item.
  Object? _headHandle(MethodCall call, Map<String, Object?> args) {
    switch (call.method) {
      case 'peekPendingSharedMessages':
        return items.isEmpty ? null : jsonEncode(items);
      case 'acknowledgeSharedMessage':
        final before = items.length;
        items.removeWhere((i) => i['id'] == args['payloadId']);
        return items.length < before;
      case 'purgeAllCaptureState':
        items.clear();
        return true;
      default:
        throw MissingPluginException();
    }
  }
}

class _FakeAi {
  final requests = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path.endsWith('/parse-sms')) {
      requests.add(body['sanitized_sms'] as String);
      return http.Response(
          jsonEncode({
            'is_transaction': true,
            'amount': 45.0,
            'amount_text': '45.00',
            'currency': 'SAR',
            'merchant_name': 'SHOP',
            'type': 'payment',
            'direction': 'debit',
            'category_key': 'shopping',
            'model_used': 'test-model',
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path.endsWith('/sync-captures')) {
      return http.Response(jsonEncode({'captures': []}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 404);
  }
}

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
  _Guard(String uid) : _token = AdmissionToken(ownerUid: uid, generation: 'g');
  final AdmissionToken _token;

  @override
  Future<AdmissionToken> capture() async => _token;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

/// One account's replica and its Android drain (production object graph).
class _Account {
  _Account(this.uid, this.db, this.ai);
  final String uid;
  final AppDatabase db;
  final _FakeAi ai;

  static Future<_Account> open(String uid, _FakeAi ai) async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    final settings = DriftUserSettingsRepository(db);
    // Cloud AND AI consent ON: anything the drain sees would go to AI.
    await settings.saveSettings((await settings.getSettings()).copyWith(
      cloudConsentState: ConsentState.accepted,
      aiConsentState: ConsentState.accepted,
    ));
    return _Account(uid, db, ai);
  }

  LegacyCaptureDrain drain() {
    final settings = DriftUserSettingsRepository(db);
    final httpClient = MockClient(ai.handle);
    final txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => false,
        getAuthUserId: () async => uid,
      ),
    );
    final ledger = CaptureRetryLedger(now: () => DateTime.utc(2026, 5, 1));
    final sync = CaptureSyncService(
      settingsRepository: settings,
      transactionRepository: txRepo,
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(uid),
      currentUserId: () => uid,
      accountRepository: DriftAccountRepository(db),
      client: CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'anon',
        httpClient: httpClient,
      ),
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      retryLedger: ledger,
    );
    final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      aiClient: SupabaseAiParserClient(
        edgeFunctionUrl: 'https://example.supabase.co/functions/v1/parse-sms',
        getAnonJwt: () async => 'jwt',
        httpClient: httpClient,
      ),
      loadAiConsent: () async => ConsentAuthority.decide(
          EgressClass.aiProcessing, await settings.getSettings()),
      aiPrimarySelected: () async {
        final s = await settings.getSettings();
        return s.cloudProcessingEnabled && s.aiConsentGranted;
      },
      findSameTextCapture: txRepo.findSameTextCapture,
      installId: 'install',
    ));
    // Production defaults for peek / ack / uploadsNatively (the bridge).
    return LegacyCaptureDrain(
      captureSync: sync,
      ingest: ingest,
      loadSettings: settings.getSettings,
      retryLedger: ledger,
      flag: (key) => key == 'android_capture_ai_enabled',
      ownershipGuard: _Guard(uid),
      aiAvailable: () => true,
    );
  }

  Future<List<String>> transactionIds() async => (await db
          .customSelect('SELECT id FROM transactions ORDER BY rowid;')
          .get())
      .map((r) => r.read<String>('id'))
      .toList();

  UnboundCapturePromptService prompt() => UnboundCapturePromptService(
        queue: const NativeCaptureImportQueue(),
        sessionUid: () => uid,
        replicaOwnerUid: () async => uid,
        isEnabled: () => true,
        ownerFor: (u) => NativeCaptureBridge.getCaptureOwner(forUid: u),
      );
}

// ── The Android session events, exactly as production issues them ───────────
// Admission: AppSession._admitReplica → publishOwnerScopedCaptureOwner.
// Sign-out: bootstrap's release(atSignOut) → NativeCaptureQueue.clearCaptureOwner(false).
// Account change / fresh sign-in: release(atTransition) → clearCaptureOwner(true).
Future<void> _admit(String uid) async {
  await NativeCaptureBridge.publishOwnerScopedCaptureOwner(uid);
}

Future<void> _signOut() =>
    NativeCaptureQueue().clearCaptureOwner(clearHint: false);

Future<void> _signInAfterSignOut(String uid) async {
  await NativeCaptureQueue().clearCaptureOwner(clearHint: true);
  await _admit(uid);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _AndroidNative native;
  late _FakeAi ai;
  final protectedWrites = <String>[];

  setUp(() {
    native = _AndroidNative();
    ai = _FakeAi();
    protectedWrites.clear();
    NativeCaptureBridge.debugTreatHostAsAndroid = true;
    NativeCaptureBridge.onProtectedNativeWrite =
        (method, {required identity, authority}) => protectedWrites.add(method);
    messenger.setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() {
    NativeCaptureBridge.debugTreatHostAsAndroid = false;
    NativeCaptureBridge.onProtectedNativeWrite = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
      'sign-out, then ANOTHER account signs in: the previous account\'s SMS is '
      'not imported and no AI request is made for it', () async {
    final a = await _Account.open(_uidA, ai);
    final b = await _Account.open(_uidB, ai);
    addTearDown(a.db.close);
    addTearDown(b.db.close);

    await _admit(_uidA);
    native.optIn();
    native.sms('sms-a-1', _purchase(45)); // received while A is signed in
    await _signOut();
    native.sms('sms-a-2', _purchase(46)); // received after A signed out

    await _signInAfterSignOut(_uidB);
    final report = await b.drain().run();

    expect(await b.transactionIds(), isEmpty,
        reason: 'B never imports A\'s bank SMS');
    expect(ai.requests, isEmpty,
        reason: 'no AI request under B\'s consent for A\'s SMS');
    expect(report.queued, 0);
    expect(native.items.map((i) => i['id']),
        containsAll(<String>['sms-a-1', 'sms-a-2']),
        reason: 'A\'s captures are kept (waiting), not lost');
    expect(await b.prompt().check(), isNull,
        reason: 'A\'s signed-out SMS is never offered to B');
    expect(native.optedIn, isFalse,
        reason: 'A\'s SMS auto-capture opt-in is not inherited by B');
    native.sms('sms-while-b', _purchase(47));
    expect(native.items.where((i) => i['id'] == 'sms-while-b'), isEmpty,
        reason: 'nothing is read until B opts in itself');

    // A comes back: its waiting SMS imports; the signed-out one needs a claim.
    await _signOut();
    await _signInAfterSignOut(_uidA);
    await a.drain().run();
    expect(await a.transactionIds(), ['sms-a-1']);
    final offer = await a.prompt().check();
    expect(offer?.ids, ['sms-a-2']);
    expect(protectedWrites, isEmpty,
        reason: 'Android owner calls never record iOS egress causes');
    expect(native.calls, isNot(contains('authorizeCaptureUpload')));
  });

  test(
      'an SMS received while signed out is imported ONLY after the claim, on '
      'device (never AI)', () async {
    final a = await _Account.open(_uidA, ai);
    addTearDown(a.db.close);
    await _admit(_uidA);
    native.optIn();
    await _signOut();
    native.sms('sms-u', _purchase(52));
    await _signInAfterSignOut(_uidA);

    await a.drain().run();
    expect(await a.transactionIds(), isEmpty,
        reason: 'unbound: not imported automatically');
    final service = a.prompt();
    final offer = await service.check();
    expect(offer, isNotNull);
    expect(offer!.count, 1);
    expect(offer.senders, ['SNB']);

    expect(await service.add(offer), UnboundCaptureChoice.applied);
    await a.drain().run();
    expect(await a.transactionIds(), ['sms-u']);
    expect(ai.requests, isEmpty,
        reason: 'a claimed capture is localOnly: parsed on device only');
    expect(native.items, isEmpty, reason: 'acknowledged after the import');
  });

  test(
      'a capture queued by the pre-upgrade build is not auto-imported into '
      'the active account and is not lost: it goes through the claim', () async {
    final a = await _Account.open(_uidA, ai);
    addTearDown(a.db.close);
    native.preUpgradeItem('old-1', _purchase(60));
    await _admit(_uidA); // the upgraded app's first admission

    await a.drain().run();
    expect(await a.transactionIds(), isEmpty);
    expect(native.items.single['id'], 'old-1');
    final offer = await a.prompt().check();
    expect(offer?.ids, ['old-1']);
    expect(await a.prompt().add(offer!), UnboundCaptureChoice.applied);
    await a.drain().run();
    expect(await a.transactionIds(), ['old-1']);
    expect(ai.requests, isEmpty);
  });

  group('Remove data / account deletion (real RemoveDataFlow)', () {
    late Directory support;
    late ReplicaStore store;
    late AccountScopeHost host;

    setUp(() async {
      support = Directory.systemTemp.createTempSync('android_remove_');
      RecordingSecureStorage().install();
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => support.path);
      store = ReplicaStore(
          requireCreationAuthority: false, appSupportDirectory: support.path);
      host = AccountScopeHost.uncoordinatedForTesting(
        store: store,
        initialize: (db, uid) async => const AccountScopeInit(),
      );
      await host.activate(_uidA);
    });

    tearDown(() async {
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'), null);
      await host.lock();
      host.dispose();
      support.deleteSync(recursive: true);
    });

    RemoveDataFlow flow() => RemoveDataFlow(
          store: store,
          scope: host,
          barrier: CaptureQueueRemoveBarrier(NativeCaptureQueue()),
          clearOwnerMarker: (_) async {},
        );

    test(
        'purges that owner\'s captures, resets the SMS opt-in and cancels '
        'background work; another account\'s captures stay', () async {
      await _admit(_uidB);
      native.optIn();
      native.sms('sms-b', _purchase(70));
      await _signOut();
      await _signInAfterSignOut(_uidA);
      native.optIn();
      native.sms('sms-a-1', _purchase(71));
      await _signOut();
      native.sms('sms-a-2', _purchase(72)); // signed-out, hinted to A
      await _signInAfterSignOut(_uidA);
      final cancelsBefore = native.backgroundCancels;

      await flow().remove(_uidA);

      expect(native.items.map((i) => i['id']), ['sms-b'],
          reason: 'every A capture is gone; B\'s waiting capture is kept');
      expect(native.optedIn, isFalse, reason: 'opt-in reset');
      expect(native.backgroundCancels, greaterThan(cancelsBefore),
          reason: 'scheduled background work cancelled');
      expect(native.barrier, isNull);
      expect(native.owner, isNull);
      expect(native.calls,
          containsAllInOrder(['beginCaptureRemoval', 'finishCaptureRemoval']));
      expect(await flow().hasPending(), isFalse);
    });

    test('a sweep that cannot delete everything is reported, barrier kept',
        () async {
      await _admit(_uidA);
      native.optIn();
      native.sms('sms-a', _purchase(80));
      native.failFinish = true;

      await expectLater(flow().remove(_uidA),
          throwsA(isA<RemoveDataIncompleteException>()));
      expect(native.barrier, isNotNull, reason: 'resumes at the next launch');
      expect(await flow().hasPending(), isTrue);
      native.sms('sms-during', _purchase(81));
      expect(native.items.map((i) => i['id']), ['sms-a'],
          reason: 'nothing new is captured while the removal is pending');
    });
  });

  group('the real AppSession drives the Android owner', () {
    late Directory support;
    late AccountScopeHost host;

    setUp(() async {
      support = Directory.systemTemp.createTempSync('android_session_');
      FlutterSecureStorage.setMockInitialValues({});
      host = AccountScopeHost.uncoordinatedForTesting(
        store: ReplicaStore(
            requireCreationAuthority: false,
            appSupportDirectory: support.path),
        initialize: (db, uid) async => const AccountScopeInit(),
      );
      AppSession.instance.configureCaptureDeviceUnlink(null);
      AppSession.instance.configureAccountScope(host);
      // Exactly bootstrap's release hooks (_registerCaptureOwnerHooks), minus
      // the iOS-only / OS-notification side effects.
      AppSession.instance.configureCaptureOwnerClear(
        () async =>
            NativeCaptureQueue().clearCaptureOwner(clearHint: true),
        atSignOut: () async =>
            NativeCaptureQueue().clearCaptureOwner(clearHint: false),
      );
      await AppSession.instance.wipeAndReset();
      native.calls.clear();
    });

    tearDown(() async {
      AppSession.instance.configureCaptureOwnerClear(null);
      await AppSession.instance.wipeAndReset();
      await host.lock();
      host.dispose();
      support.deleteSync(recursive: true);
    });

    test(
        'sign-in publishes the account, sign-out releases it, the next '
        'account is published only after the transition clear', () async {
      await AppSession.instance.setIdentity(method: 'google', userId: _uidA);
      expect(native.owner, native.hash(_uidA),
          reason: 'the admission published A as the capture owner');
      native.optIn();
      native.sms('sms-a', _purchase(90));

      await AppSession.instance.signOut();
      expect(native.owner, isNull, reason: 'sign-out released the owner');
      expect(native.items.single['ownerHash'], native.hash(_uidA),
          reason: 'A\'s capture is kept, waiting for A');

      native.calls.clear();
      await AppSession.instance.setIdentity(method: 'google', userId: _uidB);
      expect(native.owner, native.hash(_uidB));
      expect(
          native.calls.where((c) =>
              c == 'clearCaptureOwner' || c == 'publishCaptureOwner'),
          ['clearCaptureOwner', 'publishCaptureOwner'],
          reason: 'the transition clear lands before B is published');
      expect(
          await NativeCaptureBridge.peekPendingSharedMessages(), isEmpty,
          reason: 'B\'s drain sees nothing of A');
      expect(native.optedIn, isFalse, reason: 'A\'s opt-in not inherited');
      expect(protectedWrites, isEmpty);
    });
  });

  test('Android gets owner calls but none of the iOS egress semantics',
      () async {
    expect(NativeCaptureBridge.hasNativeQueue, isFalse);
    expect(NativeCaptureBridge.hasOwnerScopedQueue, isTrue);
    expect(await NativeCaptureBridge.authorizeCaptureUpload('x'),
        same(CaptureUploadAuthorization.denied));
    expect(await NativeCaptureBridge.captureOwnerEpoch(), 0);
    expect(await NativeCaptureBridge.getCaptureOwner(), isNull);
    expect(await NativeCaptureBridge.captureQueueStats(), isNull);
    expect(native.calls, isEmpty,
        reason: 'no iOS-only call reaches the Android channel');
  });
}
