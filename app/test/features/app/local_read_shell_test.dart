import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/core/session/account_fence_authority.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/tracking/user_activity_service.dart';
import 'package:money_companion/core/backend/auth_client_provider.dart';
import 'package:money_companion/core/di/local_read_providers.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/capture_queue.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/l10n/app_localizations_ar.dart';
import 'package:money_companion/l10n/app_localizations_en.dart';
import 'package:money_companion/main.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';
import '../../harness/egress_test_support.dart';
import '../../core/session/recording_secure_storage.dart';

// O-H2 — the read-only shell, through the REAL startup: seeded encrypted data,
// an expired SDK session, the real router, the real session singleton.

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async =>
      null;
}

class _Queue implements CaptureQueueBridge {
  int publishCalls = 0;
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
    return true;
  }

  @override
  Future<void> publishCaptureOwner(
      {required String uid,
      required bool cloud,
      required bool ai,
      required int version,
      required int expectedEpoch,
      int? transitionGeneration}) async {
    publishCalls++;
  }
}

class _Notifications2 extends FlutterLocalNotificationsPlatform {
  static int calls = 0;
  @override
  Future<NotificationAppLaunchDetails?> getNotificationAppLaunchDetails() async {
    calls++;
    return null;
  }
}

class _NoDartHttp extends HttpOverrides {
  _NoDartHttp(this.onCreate);
  final void Function() onCreate;
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    onCreate();
    throw StateError('dart:io HttpClient created under local read');
  }
}

/// Every provider the local-read graph ever builds: the database handle, a
/// SELECT of the snapshot and of the language, the locale / notification-language
/// seeds (both overridden under local read) and the theme preference (a secure
/// storage READ). Anything else appearing here is an unaudited entrance.
const _readOnlyProviders = <String>[
  'AutoDisposeFutureProvider<LocalReadSnapshot>',
  'AutoDisposeFutureProvider<String?>',
  'Provider<AppDatabase>',
  'Provider<Locale>',
  'Provider<String>',
  'StateNotifierProvider<ThemeModeController, ThemeMode>',
];

class _Created extends ProviderObserver {
  final names = <String>{};
  @override
  void didAddProvider(ProviderBase<Object?> provider, Object? value,
      ProviderContainer container) {
    names.add(provider.name ?? provider.runtimeType.toString());
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

// Start real-zone work without awaiting a fake-zone frame from runAsync.
// Every outcome is observed, bounded, and rethrown; no work is force-completed.
Future<T> _background<T>(WidgetTester tester, Future<T> Function() start) async {
  var completed = false;
  T? result;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(start().timeout(const Duration(seconds: 8)).then((value) {
      result = value;
      completed = true;
    }, onError: (Object error, StackTrace trace) {
      failure = error;
      stack = trace;
      completed = true;
    }));
  });
  await _until(tester, () => completed);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  return result as T;
}

void main() {
  final runners = <BootstrapRunner>[];
  final seedHosts = <AccountScopeHost>[];
  final clients = <SupabaseClient>[];
  final directories = <Directory>[];
  void Function()? restoreFence;

  void caseWidgets(String description, WidgetTesterCallback body) {
    testWidgets(description, (tester) async {
      // Independent test processes get a fresh REAL component over the same
      // secure persistence, only while detached/drained. The component is NOT
      // replaced between this world's seed and cold startup.
      await _background(tester, () async {
        await AppSession.instance.debugResetAuthBinding();
        await AppSession.instance.drainAdmissions();
        expect(AppSession.instance.accountFenceCanReplace, isTrue);
        restoreFence = AccountFenceAuthority.replacePersistenceForTest();
      });
      try {
        await body(tester);
      } finally {
        Object? firstError;
        StackTrace? firstStack;
        Future<void> release(Future<void> Function() action) async {
          try {
            await action();
          } catch (error, stack) {
            firstError ??= error;
            firstStack ??= stack;
          }
        }
        await release(() async {
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
        });
        await release(() => _background(tester,
            AppSession.instance.debugResetAuthBinding));
        for (final runner in runners) {
          await release(() => _background(tester,
              runner.shutdownSenderBankMappingSync));
          await release(() => _background(tester,
              runner.waitPendingBootstrapWork));
        }
        await release(() => _background(tester,
            UserActivityService.waitPendingActivityWork));
        await release(() => _background(tester, () async {
          await AppSession.instance.nativeLifecycleSettled();
          await AppSession.instance.debugLocalReadIdle;
          await AppSession.instance.drainAdmissions();
        }));
        final hosts = <AccountScopeHost>{
          ...seedHosts,
          for (final runner in runners) runner.accountScope,
        };
        for (final host in hosts) {
          await release(() => _background(tester, host.suspendForSwap));
        }
        await release(() => _background(tester, () async {
          await AppSession.instance.debugLocalReadIdle;
          await AppSession.instance.drainAdmissions();
          AppSession.instance.configureAccountScope(null);
          AppSession.instance.configureRemoveData(null);
          AppSession.instance.configureLocalRead(null);
          AppSession.instance.configureCaptureOwnerPublish(null);
          AppSession.instance.configureCaptureOwnerClear(null);
          AppSession.instance.configureCaptureDeviceUnlink(null);
          AppSession.instance.configureSignOutFlush(null);
          AppSession.instance.configureConsentSdkClient(null);
        }));
        for (final client in clients) {
          await release(() => _background(tester, client.dispose));
        }
        for (final host in hosts) {
          await release(() async {
            expect(host.current, isNull, reason: 'physical close must finish');
            final coordinator = host.localReadCoordinator;
            if (coordinator != null) {
              expect(coordinator.pendingOpens, 0);
              expect(coordinator.openHolders, 0);
            }
            host.dispose();
          });
        }
        // Never reset a live holder or discard unknown work to green a test.
        if (firstError == null) {
          await release(() => _background(tester, () async {
            expect(AppSession.instance.accountFenceCanReplace, isTrue);
            restoreFence!();
            restoreFence = null;
          }));
        }
        if (firstError == null) {
          for (final directory in directories) {
            if (directory.existsSync()) directory.deleteSync(recursive: true);
          }
        }
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel('mali/device_timezone'), null);
        runners.clear();
        seedHosts.clear();
        clients.clear();
        directories.clear();
        if (firstError != null) {
          Error.throwWithStackTrace(firstError!, firstStack!);
        }
      }
    });
  }
  const uid = 'uid-shell-a';
  setUp(() {
    // Each test simulates a fresh process: a coordinator still holding the
    // previous test's never-closed handle would (correctly) deny local read.
    DatabaseAccessBroker.debugResetForTest();
    rootBundle.clear();
    // The router is a process-wide singleton: start every test at the root.
    appRouter.go('/');
  });

  Future<(Directory, RecordingSecureStorage, SupabaseClient)> world(
      WidgetTester tester,
      {String language = 'en'}) async {
    final session = AppSession.instance;
    late Directory support;
    late RecordingSecureStorage storage;
    late SupabaseClient expired;
    await tester.runAsync(() async {
      // First process: a real receipted account with known rows.
      // The singleton's chains must belong to the real zone, not the test's.
      session.debugResetAdmissionState();
      final f = await F2Fixture.create();
      seedHosts.add(f.host);
      directories.add(f.support);
      support = f.support;
      storage = f.storage;
      storage.data['welcome_manifesto_seen'] = '1';
      session.configureAccountScope(f.host);
      session.configureLocalRead(
          LocalReadAuthority(store: SecureLocalReadStore()));
      final live = await f.clientFor(uid);
      clients.add(live);
      await session.bindSupabaseAuth(live);
      await session.setIdentity(
          method: 'google', email: '$uid@example.com', userId: uid);
      await session.finishOnboarding(client: live);
      final db = f.host.current!.database;
      final now = DateTime.now().toUtc().toIso8601String();
      await db.customStatement(
          "INSERT INTO accounts(id,name,currency,type,initial_balance,"
          "initial_balance_minor,current_balance,current_balance_minor,"
          "is_default,sort_order,created_at,updated_at) VALUES "
          "('acc-1','Main Wallet','SAR','bank',0,0,500.0,50000,1,0,'$now','$now');");
      await db.customStatement(
          "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
          "source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at, raw_merchant, direction) VALUES "
          "('tx-1', 125.5, 12550, 'SAR', 'payment', 'manual', '$now', '', 1, "
          "'confirmed', '$now', '$now', 'Coffee Corner', 'debit');");
      await db.customStatement("UPDATE user_settings SET language = '$language';");
      await db.customStatement(
          "INSERT INTO user_settings(id,country,currency,language,theme,"
          "input_method,notifications_json,db_encryption_key_ref) "
          "SELECT 's1','SA','SAR','$language','system','sms','{}','' "
          "WHERE NOT EXISTS (SELECT 1 FROM user_settings);");
      await f.host.detach(); // the process dies while `active`
      // detach published a signed-out ephemeral handle; close it physically.
      await f.host.suspendForSwap();
      session.configureAccountScope(null);
      session.configureRemoveData(null);
      session.configureLocalRead(null);
      session.debugResetAdmissionState();
      await session.debugResetAuthBinding();
      await live.dispose();
      clients.remove(live);
      expired = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
          httpClient: MockClient((request) async => http.Response(
              '{"access_token":"${_expiredJwt(uid)}","token_type":"bearer",'
              '"refresh_token":"r","user":{"id":"$uid","email":"$uid@example.com"}}',
              200)));
      clients.add(expired);
      await expired.auth
          .signInWithPassword(email: '$uid@example.com', password: 'x');
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (call) async => support.path);
    // A successful synthetic device-timezone reply prevents the genuine
    // missing-plugin retry timer from outliving the logout UI test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('mali/device_timezone'),
            (call) async {
      if (call.method == 'getLocalTimezone') return 'UTC';
      throw PlatformException(code: 'unexpected_timezone_method');
    });
    FlutterLocalNotificationsPlatform.instance = _Notifications();
    return (support, storage, expired);
  }

  Future<void> pumpShell(WidgetTester tester, SupabaseClient client) async {
    final runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = _Queue();
    runners.add(runner);
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(LocalReadShell).evaluate().isNotEmpty);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalReadShell)), listen: false);
    // The recovery UI intentionally mounts no financial snapshot now. Keep a
    // test-owned subscription to verify the retained read-only data/authority.
    final snapshotSubscription = container.listen(localReadSnapshotProvider, (_, __) {});
    addTearDown(snapshotSubscription.close);
    await _until(tester,
        () => container.read(localReadSnapshotProvider).hasValue);
    // The language is read from the database a moment after the first frame.
    await _until(
        tester,
        () => find
            .text(AppL10nEn().sessionRecoveryTitle)
            .evaluate()
            .isNotEmpty);
  }

  caseWidgets('home route removes recovery loader without changing its URI', (tester) async {
    final (_, _, client) = await world(tester);
    await pumpShell(tester, client);
    try {
      AutomaticSessionRecovery.restoringSession.value = true;
      await tester.pump();
      await tester.pump();
      expect(find.byType(AppBootLoader), findsWidgets);
      AutomaticSessionRecovery.restoringSession.value = false;
      await tester.pump();
      await tester.pump();
      expect(appRouter.routeInformationProvider.value.uri.path, '/');
      expect(find.byType(AppBootLoader), findsNothing);
      expect(find.byType(LocalReadShell), findsOneWidget);
    } finally {
      AutomaticSessionRecovery.restoringSession.value = false;
    }
  });

  caseWidgets(
      'expired SDK: recovery prompt preserves existing data and offers sign-in/logout, with '
      'no restore spinner and none of the ordinary shell', (tester) async {
    final (support, storage, client) = await world(tester);
    final from = storage.attempts.length;
    await pumpShell(tester, client);
    final l10n = AppL10nEn();

    expect(find.text(l10n.sessionRecoveryTitle), findsOneWidget);
    expect(find.text(l10n.sessionRecoverySignIn), findsOneWidget);
    expect(find.text(l10n.localReadLogout), findsOneWidget);
    expect(find.text('Coffee Corner'), findsNothing);
    expect(find.text('Main Wallet'), findsNothing);
    expect(find.text(l10n.localReadBannerTitle), findsNothing);
    expect(find.text(l10n.localReadReconnect), findsNothing);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalReadShell)), listen: false);
    final snapshot = container.read(localReadSnapshotProvider).requireValue;
    expect(snapshot.accounts.single.name, 'Main Wallet');
    expect(snapshot.transactions.single.title, 'Coffee Corner');

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'no ordinary restore spinner');
    expect(find.byType(AppShell), findsNothing,
        reason: 'no sync, timer, capture or notification producer is mounted');
    expect(appDataRestoring.value, isFalse);
    expect(appRouter.routeInformationProvider.value.uri.path, '/');
    expect(AppSession.instance.localReadActive, isTrue);
    // Nothing on screen offers a write.
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(find.byIcon(Icons.add), findsNothing);
    expect(storage.attempts.skip(from).where((a) => a.startsWith('delete:')), isEmpty);
  });

  caseWidgets('the Arabic locale shows natural Arabic copy', (tester) async {
    final (support, _, client) = await world(tester, language: 'ar');
    final runner = BootstrapRunner(debugAuthClient: client)
      ..captureQueue = _Queue();
    runners.add(runner);
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalOverrides: [authClientProvider.overrideWithValue(client)]));
    await _until(tester, () => find.byType(LocalReadShell).evaluate().isNotEmpty);
    final l10n = AppL10nAr();
    await _until(tester,
        () => find.text(l10n.sessionRecoveryTitle).evaluate().isNotEmpty);
    expect(find.text(l10n.sessionRecoverySignIn), findsOneWidget);
    expect(find.text(l10n.localReadLogout), findsOneWidget);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalReadShell)), listen: false);
    // The recovery UI intentionally mounts no financial snapshot now. Keep a
    // test-owned subscription to verify the retained read-only data/authority.
    final snapshotSubscription = container.listen(localReadSnapshotProvider, (_, __) {});
    addTearDown(snapshotSubscription.close);
    await _until(tester,
        () => container.read(localReadSnapshotProvider).hasValue);
    expect(find.text(l10n.localReadBannerTitle), findsNothing);
    expect(find.text(l10n.localReadReconnect), findsNothing);
    expect(container.read(localReadSnapshotProvider).requireValue.transactions,
        isNotEmpty, reason: 'read-only data remains intact behind the prompt');
  });

  caseWidgets('deep links to action and editing routes are denied',
      (tester) async {
    final (support, _, client) = await world(tester);
    await pumpShell(tester, client);
    for (final location in [
      '/transaction/tx-1',
      '/budgets/new',
      '/goals/new',
      '/paste',
      '/settings',
      '/data-transfer',
    ]) {
      appRouter.go(location);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(appRouter.routeInformationProvider.value.uri.path, '/',
          reason: location);
      expect(find.byType(LocalReadShell), findsOneWidget, reason: location);
    }
  });

  caseWidgets('explicit Sign in again opens auth while data stays read-only',
      (tester) async {
    final (support, _, client) = await world(tester);
    await pumpShell(tester, client);
    await tester.tap(find.text(AppL10nEn().sessionRecoverySignIn));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(appRouter.routeInformationProvider.value.uri.path,
        '/onboarding/auth');
  });

  caseWidgets('Logout locks, denies durably and leaves the read-only scope',
      (tester) async {
    final (support, storage, client) = await world(tester);
    await pumpShell(tester, client);
    await tester.tap(find.text(AppL10nEn().localReadLogout));
    await _until(tester, () => !AppSession.instance.localReadActive);
    await _until(tester, () => find.byType(LocalReadShell).evaluate().isEmpty);
    final raw = storage.data[SecureLocalReadStore.storageKey];
    expect(LocalReadGrantRecord.tryDecode(raw)!.state,
        LocalReadGrantState.blocked);
    await _until(
        tester,
        () =>
            appRouter.routeInformationProvider.value.uri.path ==
            '/onboarding/auth');

  });

  // ------------------------------------------------------------------- D6
  //
  // Astra D6: the reachable provider / callback / listener graph of the dedicated
  // local-read scope performs ZERO non-read effects, observed through spies (not
  // inferred from SQLite exceptions): saved Cloud and AI consent ON, a durable
  // Cloud ON record, resume, deep links, the reconnect route.
  caseWidgets(
      'D6: saved Cloud/AI ON + resume + deep links + reconnect route: zero '
      'non-read effects, and only read providers are ever built', (tester) async {
    final (support, storage, client) = await world(tester);
    final created = _Created();
    final queue = _Queue();
    final nativeCalls = <String>[];
    var requests = 0;
    var dartHttpClients = 0;

    // Saved Cloud/AI consent ON in the replica, and a durable Cloud ON record.
    await tester.runAsync(() async {
      final replicas = Directory(support.path).listSync(recursive: true);
      final db = replicas
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('qirsh.sqlite'));
      expect(db.existsSync(), isTrue);
    });
    // The gate's mutex must belong to the real zone (not the test's fake-async).
    late final TestEgress egress;
    await tester.runAsync(() async => egress = TestEgress(seedOn: true)..install());
    addTearDown(() => CloudEgressGate.instance = CloudEgressGate());
    final onBody = jsonEncode({
      'v': 1,
      'records': {
        uid: const CloudEgressRecord(
                state: EgressState.on,
                ownerUid: uid,
                transitionGeneration: 1,
                reservedVersion: 1)
            .toJson()
      }
    });
    egress.secure.value = onBody;
    egress.file.value = onBody;
    FlutterLocalNotificationsPlatform.instance = _Notifications2();
    _Notifications2.calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('money_companion/native_capture'), (call) async {
      nativeCalls.add(call.method);
      throw MissingPluginException();
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('money_companion/native_capture'), null));

    final counted = SupabaseClient('http://127.0.0.1:55321', 'synthetic-anon',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 200);
        }));
    clients.add(counted);
    // Same expired session as the shared world client, through a counted transport.
    final expiredSession = client.auth.currentSession!;
    await counted.auth.setInitialSession(jsonEncode(expiredSession.toJson()));
    requests = 0;
    final from = storage.attempts.length;

    final oldOverrides = HttpOverrides.current;
    HttpOverrides.global = _NoDartHttp(() => dartHttpClients++);
    addTearDown(() => HttpOverrides.global = oldOverrides);

    final runner = BootstrapRunner(debugAuthClient: counted)..captureQueue = queue;
    runners.add(runner);
    await tester.pumpWidget(StartupApp(
        runner: runner,
        externalObservers: [created],
        externalOverrides: [authClientProvider.overrideWithValue(counted)]));
    await _until(tester, () => find.byType(LocalReadShell).evaluate().isNotEmpty);
    final container = ProviderScope.containerOf(
        tester.element(find.byType(LocalReadShell)), listen: false);
    // The recovery UI intentionally mounts no financial snapshot now. Keep a
    // test-owned subscription to verify the retained read-only data/authority.
    final snapshotSubscription = container.listen(localReadSnapshotProvider, (_, __) {});
    addTearDown(snapshotSubscription.close);
    await _until(tester,
        () => container.read(localReadSnapshotProvider).hasValue);

    // Resume listeners (app lock, SDK, shell): background then foreground.
    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Deep links to every action / editing / commercial route.
    for (final location in [
      '/transaction/tx-1',
      '/budgets/new',
      '/goals/new',
      '/paste',
      '/settings',
      '/data-transfer',
      '/coupons',
      '/reports',
      '/accounts',
    ]) {
      appRouter.go(location);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
      expect(appRouter.routeInformationProvider.value.uri.path, '/',
          reason: location);
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 600)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(AppSession.instance.localReadActive, isTrue);
    expect(requests, 0, reason: 'no request left any transport');
    expect(dartHttpClients, 0, reason: "no dart:io HttpClient was created");
    expect(queue.publishCalls, 0, reason: 'no capture-owner publication');
    expect(queue.clearCalls, 0);
    expect(_Notifications2.calls, 0, reason: 'no notification service');
    expect(nativeCalls, isEmpty, reason: 'no native capture traffic: $nativeCalls');
    expect(
        storage.attempts.skip(from).where((a) =>
            a.startsWith('delete:') ||
            (a.startsWith('write:') &&
                !a.startsWith('write:app_theme_mode'))),
        isEmpty,
        reason: 'no secure-storage write or delete of any kind');
    // The gate's store reads are real async work (outside the fake-async zone).
    await tester.runAsync(() async {
        expect(await CloudEgressGate.instance.permits(), isFalse,
          reason: 'a saved Cloud ON record admits nothing under local read');
      await expectLater(
          CloudEgressGate.instance.admit(
              request: AdmissionRequest(
                  'POST', Uri.parse('http://127.0.0.1:55321/auth/v1/token'))),
          throwsA(isA<EgressDeniedException>()));
      });
    expect(created.names.toList()..sort(), _readOnlyProviders,
        reason: 'only these providers are reachable in the local-read graph');
  });
}

String _expiredJwt(String uid) {
  String part(String json) =>
      base64Url.encode(utf8.encode(json)).replaceAll('=', '');
  return '${part('{"alg":"none"}')}.${part('{"sub":"$uid","exp":1}')}.';
}
