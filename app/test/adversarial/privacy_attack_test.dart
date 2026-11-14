// Adversarial privacy tests, scenarios 33-40. Each test states the EXPECTED
// (correct) behaviour; a failure here is a product defect, not a test bug.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/observability/diagnostics.dart';
import 'package:money_companion/core/observability/telemetry_sanitizer.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/onboarding/auth_screen.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/session/recording_secure_storage.dart';
import '../harness/egress_test_support.dart';

const _base = 'https://example.supabase.co';
const _uid = '3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c';
const _email = 'victim.person@example.com';
const _jwtToken =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIzZjJhOWMxZSJ9.c2lnbmF0dXJlLXNpZw';
const _merchant = 'Coffee Corner';

String _read(String p) => File(p).readAsStringSync();

void main() {
  _apns();
  _signOutNotifications();
  _signedOutCapture();
  _egressInventory();
  _grantScope();
  _diagnostics();
}

// ── 33 / 34: APNs environment ──────────────────────────────────────────────
void _apns() {
  group('33/34 APNs environment', () {
    final src = _read('ios/Runner/AppDelegate.swift');
    String fn(String name) {
      final s = src.indexOf('static func $name(');
      final e = src.indexOf('\n  }\n', s);
      return src.substring(s, e);
    }

    test('33: a store build is recognised from the receipt URL NAME alone', () {
      final body = fn('isStoreDistributed');
      expect(body, contains('appStoreReceiptURL?.lastPathComponent'));
      expect(body.contains('fileExists'), isFalse);
      expect(body.contains('Data(contentsOf'), isFalse);
      expect(fn('isStoreReceiptName'),
          contains('name == "receipt" || name == "sandboxReceipt"'));
      // No profile + store receipt -> production (TestFlight host).
      expect(fn('resolve'),
          contains('return isStoreDistributed ? "production" : nil'));
    });

    test(
        '34: a simulator never claims store distribution (so never production '
        'without a signed production profile)', () {
      final body = fn('isStoreDistributed');
      final sim = body.indexOf('#if targetEnvironment(simulator)');
      final ret = body.indexOf('return false', sim);
      final receipt = body.indexOf('appStoreReceiptURL');
      expect(sim, isNot(-1));
      expect(ret, greaterThan(sim));
      expect(receipt, greaterThan(ret),
          reason: 'the simulator branch must short-circuit before the receipt');
      // The handler withholds the token when the environment is unresolved.
      final h = src.substring(
          src.indexOf('didRegisterForRemoteNotificationsWithDeviceToken'),
          src.indexOf('didFailToRegisterForRemoteNotificationsWithError'));
      expect(h.indexOf('guard let environment = ApnsEnvironment.current()'),
          lessThan(h.indexOf('SharedCaptureStore.setApnsToken')));
    });
  });
}

// ── 35: sign-out clears delivered + pending notifications ──────────────────
class _SpyNotifications extends FlutterLocalNotificationsPlatform {
  int cancelAllCalls = 0;
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
  @override
  Future<void> cancelAll() async => cancelAllCalls++;
  @override
  Future<List<PendingNotificationRequest>>
      pendingNotificationRequests() async => const [];
  @override
  Future<void> cancel({required int id, String? tag}) async {}
}

class _MemStorage extends GotrueAsyncStorage {
  final _m = <String, String>{};
  @override
  Future<String?> getItem({required String key}) async => _m[key];
  @override
  Future<void> removeItem({required String key}) async => _m.remove(key);
  @override
  Future<void> setItem({required String key, required String value}) async =>
      _m[key] = value;
}

class _Queue implements CaptureQueueBridge {
  bool failClear = false;
  int clearCalls = 0;
  @override
  Future<CaptureRemovalBarrierRead> getCaptureRemovalBarrier() async =>
      const CaptureRemovalBarrierRead.absent();
  @override
  Future<void> beginCaptureRemoval(String uid) async {}
  @override
  Future<void> finishCaptureRemoval(String uid) async {}
  @override
  Future<int> captureOwnerEpoch() async => 0;
  @override
  Future<bool> clearCaptureOwner({bool clearHint = false}) async {
    clearCalls++;
    // What NativeCaptureBridge.clearCaptureOwner does when the native
    // `clearActiveOwner` throws (lock / Keychain error): a CaptureQueueException.
    if (failClear) throw const CaptureQueueException('queue_unavailable');
    return true;
  }

  @override
  Future<void> publishCaptureOwner({
    required String uid,
    required bool cloud,
    required bool ai,
    required int version,
    required int expectedEpoch,
    int? transitionGeneration,
  }) async {}
}

void _signOutNotifications() {
  group('35 sign-out removes delivered and pending notifications', () {
    late Directory support;
    late _Queue queue;
    late _SpyNotifications spy;
    final runners = <BootstrapRunner>[];
    final clients = <SupabaseClient>[];
    Timer? frames;

    setUp(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      CloudEgressGate.instance = CloudEgressGate();
      support = Directory.systemTemp.createTempSync('adv_p2_');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => support.path,
      );
      RecordingSecureStorage().install();
      spy = _SpyNotifications();
      FlutterLocalNotificationsPlatform.instance = spy;
      queue = _Queue();
      final session = AppSession.instance;
      session.debugResetAdmissionState();
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      session.configureLocalRead(null);
      await session.wipeAndReset();
      final binding = TestWidgetsFlutterBinding.instance;
      frames = Timer.periodic(const Duration(milliseconds: 20), (_) {
        binding.scheduleFrame();
        binding.handleBeginFrame(Duration.zero);
        binding.handleDrawFrame();
      });
    });

    tearDown(() async {
      for (final r in runners) {
        try {
          await r.accountScope.lock();
          r.accountScope.dispose();
        } catch (_) {}
      }
      runners.clear();
      for (final c in clients) {
        await c.dispose();
      }
      clients.clear();
      frames?.cancel();
      final session = AppSession.instance;
      session.configureRemoveData(null);
      session.configureAccountScope(null);
      session.configureLocalRead(null);
      session.configureCaptureOwnerClear(null);
      support.deleteSync(recursive: true);
      CloudEgressGate.instance = CloudEgressGate();
    });

    Future<void> boot() async {
      final c = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((_) async => http.Response('{}', 200)));
      clients.add(c);
      final runner = BootstrapRunner(debugAuthClient: c)..captureQueue = queue;
      runners.add(runner);
      await runner.run();
    }

    test('control: the owner-clear hook removes every OS notification',
        () async {
      await boot();
      spy.cancelAllCalls = 0;
      await AppSession.instance.wipeAndReset();
      expect(queue.clearCalls, greaterThan(0));
      expect(spy.cancelAllCalls, greaterThan(0),
          reason: 'cancelAll = removeAllPending + removeAllDelivered on iOS');
    });

    test(
        'a failing native owner clear must not keep the outgoing account\'s '
        'delivered notifications (merchant + amount) on the lock screen',
        () async {
      await boot();
      queue.failClear = true;
      spy.cancelAllCalls = 0;
      await AppSession.instance.wipeAndReset();
      expect(queue.clearCalls, greaterThan(0));
      expect(spy.cancelAllCalls, greaterThan(0),
          reason: 'bootstrap_runner.dart release(): clearAllForRemovedOwner '
              'runs only after clearCaptureOwner returned');
    });
  });
}

// ── 36: signed-out capture is never attributed ─────────────────────────────
void _signedOutCapture() {
  group('36 a bank SMS while signed out is not attributed', () {
    test('both native capture entry points refuse before persisting', () {
      final intent =
          _read('ios/BankMessageShortcuts/BankMessageShortcuts.swift');
      final perform = intent.substring(intent.indexOf('func perform()'));
      final check =
          perform.indexOf('SharedCaptureStore.isSignedOutForCertain()');
      expect(check, isNot(-1));
      expect(check, lessThan(perform.indexOf('service.capture(')));
      expect(check, lessThan(perform.indexOf('authorizeUpload')));
      final share = _read('ios/ShareBankMessage/ShareViewController.swift');
      final sCheck =
          share.indexOf('SharedCaptureStore.isSignedOutForCertain()');
      expect(sCheck, isNot(-1));
      expect(sCheck, lessThan(share.indexOf('SharedCaptureStore.enqueue(')));
    });

    test(
        'an unbound capture (owner raced away) is only claimable by its '
        'hinted uid, explicitly, and never uploads', () {
      final store = _read('ios/Runner/SharedCaptureStore.swift');
      final claim = store.substring(store.indexOf('static func claimUnbound('),
          store.indexOf('static func discardUnbound('));
      expect(claim, contains('queue[index].localOnly = true'));
      final cas =
          store.substring(store.indexOf('private static func casUnbound('));
      expect(cas, contains('queue[\$0].ownerHint == hash'));
      expect(
          cas, contains('owner.uid == target, owner.generation == generation'));
      // The upload requires an `.allowed(uid, generation, ai)` decision.
      final intent =
          _read('ios/BankMessageShortcuts/BankMessageShortcuts.swift');
      expect(intent, contains('case let .allowed(uid, generation, allowAi):'));
      expect(intent, contains('body["owner_uid"] = ownerUid'));
    });
  });
}

// ── 38: every egress path with Cloud OFF ───────────────────────────────────
void _egressInventory() {
  group('38 Cloud OFF: only the documented exceptions reach the network', () {
    test('the grant vocabulary is exactly the documented set', () {
      expect(EgressGrantKind.values.map((e) => e.name).toSet(),
          {'accountControl', 'revoke', 'revokeRetry', 'deviceUnlink'});
      // signIn/reauthenticate, delete/cancel, onboarding lookup and identity
      // linking (explicit account management; not in the brief's list).
      expect(AccountControlOp.values.map((e) => e.name).toSet(), {
        'signIn',
        'reauthenticate',
        'deleteAccount',
        'cancelDelete',
        'onboardingStatus',
        'linkIdentity',
      });
    });

    test('no raw HTTP client in lib bypasses GatedHttpClient', () {
      final raw = RegExp(
          r'\bhttp\.Client\(\)|\bHttpClient\(\)|\bIOClient\(|\bDio\(|'
          r'\bImage\.network\(|\bNetworkImage\(|\bWebSocketChannel\.connect|'
          r'\bRetryClient\(|\bhttp\.(get|post|put|patch|delete|head|read)\(');
      final hits = <String>{};
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        final lines = f.readAsLinesSync();
        for (final l in lines) {
          final t = l.trimLeft();
          if (t.startsWith('//')) continue;
          if (raw.hasMatch(l)) hits.add(f.path);
        }
      }
      expect(hits, {
        // GatedHttpClient's own default inner client.
        'lib/core/privacy/cloud_egress_gate.dart',
        // Only handed to ImmediateAccountDeletionRecovery, which wraps it.
        'lib/core/di/app_providers.dart',
        // The coordinator's session-only refresh (its own ticket, no redirects).
        'lib/core/auth/refresh_transport.dart',
      });
      final gw =
          _read('lib/core/auth/prepared_immediate_deletion_gateway.dart');
      // Declared, assigned, and passed once: to the recovery only.
      expect(RegExp(r'_transport\b').allMatches(gw).length, 3);
      expect(gw, contains('transport: _transport,'));
      expect(_read('lib/core/auth/immediate_account_deletion.dart'),
          contains('httpClient: GatedHttpClient(transport)'));
      expect(_read('lib/core/startup/bootstrap_runner.dart'),
          isNot(contains('httpClient: http.Client()')));
    });

    test('every injectable service client defaults to GatedHttpClient', () {
      final dflt = RegExp(r'httpClient \?\? ([A-Za-z_.]+)\(');
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        for (final m in dflt.allMatches(f.readAsStringSync())) {
          expect(m.group(1), 'GatedHttpClient', reason: f.path);
        }
      }
      // And no lib call site injects an ungated client.
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        expect(
            RegExp(r'httpClient:\s*(http\.Client|IOClient|MockClient)\(')
                .hasMatch(f.readAsStringSync()),
            isFalse,
            reason: f.path);
      }
    });

    group('runtime: Cloud OFF with no grant denies every Supabase surface', () {
      late TestEgress egress;
      late List<http.BaseRequest> seen;
      late SupabaseClient client;
      setUp(() {
        egress = TestEgress().install(); // no record = OFF
        seen = [];
        client = SupabaseClient(_base, 'anon',
            httpClient: GatedHttpClient(MockClient((r) async {
          seen.add(r);
          return http.Response('{}', 200);
        })),
            authOptions: AuthClientOptions(
                autoRefreshToken: false, pkceAsyncStorage: _MemStorage()));
      });
      tearDown(() => client.dispose());

      Future<void> denied(Future<Object?> Function() f) async {
        Object? err;
        try {
          await f();
        } catch (e) {
          err = e;
        }
        expect(err, isNotNull);
      }

      test('tables, RPCs, functions (AI parse, catalog), storage, auth user',
          () async {
        await denied(() => client.from('transactions').select());
        await denied(() => client.rpc('record_metric'));
        await denied(() => client.functions.invoke('parse-sms'));
        await denied(() => client.functions.invoke('sync-captures'));
        await denied(() => client.from('catalog_coupons').select());
        await denied(() => client.storage
            .from('backups')
            .uploadBinary('x.bin', Uint8List.fromList([1])));
        await denied(() => client.auth.signInWithOtp(email: _email));
        expect(seen, isEmpty);
        expect(await egress.gate.permits(), isFalse);
      });

      test('a raw GatedHttpClient (images, AI clients) is denied too',
          () async {
        final c = GatedHttpClient(MockClient((r) async {
          seen.add(r);
          return http.Response('x', 200);
        }));
        await denied(
            () => c.get(Uri.parse('https://cdn.example.com/logo.png')));
        await denied(() => c.post(Uri.parse('$_base/functions/v1/parse-sms')));
        expect(seen, isEmpty);
      });

      test('each documented exception is admitted only inside its own grant',
          () async {
        await egress.gate.runAccountControl(AccountControlOp.signIn,
            () => client.auth.signInWithOtp(email: _email));
        expect(seen.map((r) => r.url.path), ['/auth/v1/otp']);
        await denied(() => egress.gate.runAccountControl(
            AccountControlOp.signIn, () => client.from('profiles').select()));
        await denied(() => egress.gate.runAccountControl(
            AccountControlOp.deleteAccount,
            () => client.functions.invoke('parse-sms')));
        await denied(() => egress.gate.runDeviceUnlink(
            'uid-a', () => client.functions.invoke('parse-sms')));
        expect(seen, hasLength(1));
      });
    });
  });
}

// ── 39: grant scope, host, path and redirects ──────────────────────────────
void _grantScope() {
  group('39 an allowed grant cannot leave its endpoint', () {
    late TestEgress egress;
    late CloudEgressGate gate;
    setUp(() {
      egress = TestEgress().install();
      gate = egress.gate;
    });

    Future<String?> admit(EgressGrant g, String method, String url) async {
      try {
        final t = await gate.admit(
            grant: g, request: AdmissionRequest(method, Uri.parse(url)));
        gate.release(t);
        return null;
      } on EgressDeniedException catch (e) {
        return e.reason;
      }
    }

    Future<DisableFreeze> disabling() async {
      await gate.enable(owner: 'uid-a', reservedVersion: 1);
      return gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
    }

    test(
        'account-control: another host, port, userinfo, path or query is denied',
        () async {
      final control = await _captureControl(gate, AccountControlOp.signIn);
      expect(control.op, AccountControlOp.signIn);
    });

    test('one-shot revoke: only the revoke POST on the backend host', () async {
      final freeze = await disabling();
      expect(
          await admit(freeze.revokeGrant, 'POST',
              '$_base/functions/v1/set-device-consent'),
          isNull);
      for (final (m, u) in const [
        ('POST', 'https://evil.example/collect'),
        ('GET', '$_base/rest/v1/transactions'),
        ('POST', '$_base/functions/v1/parse-sms'),
      ]) {
        expect(await admit(freeze.revokeGrant, m, u), isNotNull,
            reason: 'revoke grant admitted $m $u');
      }
    });

    test('one-shot revoke is sent with followRedirects=false', () async {
      final freeze = await disabling();
      final sent = <http.BaseRequest>[];
      final c = GatedHttpClient(MockClient.streaming((r, _) async {
        sent.add(r);
        return http.StreamedResponse(const Stream.empty(), 200, request: r);
      }));
      await gate.runRevoke(
          freeze,
          const Duration(seconds: 5),
          () => c.post(Uri.parse('$_base/functions/v1/set-device-consent'),
              body: '{}'));
      expect(sent, hasLength(1));
      expect(sent.single.followRedirects, isFalse,
          reason: 'a 303 would be followed outside admission');
    });

    test(
        'unlink and revoke-retry grants: same host but another port, a '
        'prefixed path or a query are denied', () async {
      await gate.enable(owner: 'uid-a', reservedVersion: 1);
      final f = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await gate.commitOff(f);
      final retry = EgressGrant.revokeRetry(
          owner: 'uid-a', generation: f.transitionGeneration);
      const unlink = EgressGrant.deviceUnlink(owner: 'uid-a');
      final admitted = <String>[];
      for (final (g, fn) in [
        (unlink, 'unlink-capture-device'),
        (retry, 'set-device-consent')
      ]) {
        expect(await admit(g, 'POST', '$_base/functions/v1/$fn'), isNull);
        for (final u in [
          'https://example.supabase.co:8443/functions/v1/$fn',
          '$_base/other/functions/v1/$fn',
          '$_base/functions/v1/$fn?leak=1',
        ]) {
          if (await admit(g, 'POST', u) == null) admitted.add(u);
        }
      }
      expect(admitted, isEmpty);
    });

    test('unlink / retry grants carry followRedirects=false', () async {
      final sent = <http.BaseRequest>[];
      final c = GatedHttpClient(MockClient.streaming((r, _) async {
        sent.add(r);
        return http.StreamedResponse(const Stream.empty(), 200, request: r);
      }));
      await gate.runDeviceUnlink('uid-a',
          () => c.post(Uri.parse('$_base/functions/v1/unlink-capture-device')));
      expect(sent.single.followRedirects, isFalse);
    });
  });
}

/// Returns a live account-control grant (probing scope inside its zone).
Future<AccountControlGrant> _captureControl(
    CloudEgressGate gate, AccountControlOp op) async {
  late AccountControlGrant control;
  await gate.runAccountControl(op, () async {
    for (final (m, u) in const [
      ('POST', 'https://evil.example/auth/v1/otp'),
      ('POST', 'https://example.supabase.co:444/auth/v1/otp'),
      ('POST', 'https://user@example.supabase.co/auth/v1/otp'),
      ('POST', 'http://example.supabase.co/auth/v1/otp'),
      ('POST', '$_base/auth/v1/otp?x=1'),
      ('POST', '$_base/rest/v1/profiles'),
      ('GET', '$_base/auth/v1/otp'),
      ('POST', '$_base/auth/v1/token?grant_type=refresh_token'),
    ]) {
      Object? err;
      try {
        final t = await gate.admit(request: AdmissionRequest(m, Uri.parse(u)));
        gate.release(t);
      } on EgressDeniedException catch (e) {
        err = e;
      }
      expect(err, isNotNull, reason: '$m $u admitted under signIn');
    }
    final t = await gate.admit(
        request: AdmissionRequest('POST', Uri.parse('$_base/auth/v1/otp')));
    control = t.grant!.control!;
    gate.release(t);
  });
  expect(control.active, isFalse, reason: 'ended after the op');
  return control;
}

// ── 40: diagnostics never carry identity, secrets, amounts or merchants ────
void _diagnostics() {
  group('40 diagnostic codes and log lines', () {
    final secrets = [_email, _uid, _jwtToken, _merchant, '12550', '1,250'];

    void clean(String out) {
      for (final s in secrets) {
        expect(out.contains(s), isFalse, reason: 'leaked "$s" in: $out');
      }
    }

    test('signInFailureCode: hostile exception messages', () {
      for (final e in <Object>[
        const AuthException('User $_email ($_uid) token $_jwtToken'),
        AuthApiException('$_email already registered', statusCode: '422'),
        AuthRetryableFetchException(
            message: 'ClientException: egress_denied:frozen, '
                'uri=$_base/auth/v1/otp?email=$_email'),
        const PostgrestException(
            message: 'row $_uid', details: '$_merchant 12550'),
        Exception('$_merchant paid 1,250 SAR'),
        EgressDeniedException('frozen'),
      ]) {
        clean(signInFailureCode(e));
      }
      ConsentAuthority.egressFreezeTag = 'disable:begin:StateError';
      ConsentAuthority.egressFrozen = true;
      addTearDown(() {
        ConsentAuthority.egressFrozen = false;
        ConsentAuthority.egressFreezeTag = '';
      });
      expect(signInFailureCode(EgressDeniedException('frozen')),
          'EgressDenied:frozen/disable:begin:StateError');
    });

    test('consentFailureCode: hostile exceptions report only the type', () {
      for (final e in <Object>[
        const AuthException('$_email $_jwtToken'),
        const CaptureQueueException('private', '$_uid $_email'),
        StateError('$_merchant 12550'),
        const CloudEnableIncompleteException('preflight_conflict/dart_pending'),
      ]) {
        clean(consentFailureCode(e));
      }
    });

    test('Sentry breadcrumbs lose message and data', () {
      final c = TelemetrySanitizer.sanitizeBreadcrumb(Breadcrumb(
          message: '$_email $_merchant 12550',
          data: {'uid': _uid, 'token': _jwtToken}))!;
      clean('${c.message} ${c.data}');
    });

    test('Diag / the release debugPrint sink: email, uid, token are redacted',
        () {
      clean(Diag.redactLine('[Auth] failed for $_email uid=$_uid '
          'Authorization: Bearer $_jwtToken'));
    });

    test(
        'Diag / the release debugPrint sink: a Drift SqliteException carrying '
        'a merchant and an integer minor amount is not logged verbatim', () {
      // Exact `SqliteException.toString()` shape (sqlite3 3.3.3), as printed by
      // e.g. app_shell.dart:697 `debugPrint('[Reconcile] failed: $error')` or
      // dashboard_screen.dart:110 in a RELEASE build (the sink redacts, it does
      // not drop).
      // A short statement: the 240-char bound does not cut the parameters.
      const sqlite = 'SqliteException(11): while selecting from statement, '
          'database disk image is malformed (code 11)\n'
          '  Causing statement: SELECT * FROM transactions WHERE raw_merchant '
          '= ? AND amount_minor = ?, parameters: $_merchant, 12550';
      final out = Diag.redactLine('[dashboard] load failed: $sqlite');
      clean(out);
    });

    test('Diag: an integer amount with a thousands separator is redacted', () {
      clean(
          Diag.redactLine('[Notif] show failed: body=Paid SAR 1,250 at card'));
    });
  });
}
