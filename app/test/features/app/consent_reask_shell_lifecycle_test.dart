import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
// ignore: depend_on_referenced_packages
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/session/f2_fixture.dart';

// F1/F2: the REAL AppShell drives ConsentReaskTrigger from its lifecycle
// listener. The ask itself is replaced through [reaskConsentProvider]; every
// other part of the shell is production code over a real (local) replica.
// SupabaseConfig is unconfigured (no defines), so the shell's cloud paths stay
// off; the SDK singleton is still initialised (the adaptive poll touches
// `Supabase.instance`) over a mock HTTP client with an EMPTY allowlist: every
// request is recorded and refused, and the suite asserts none was made.

final _requests = <String>[];

class _PkceStorage extends GotrueAsyncStorage {
  const _PkceStorage();
  @override
  Future<String?> getItem({required String key}) async => null;
  @override
  Future<void> setItem({required String key, required String value}) async {}
  @override
  Future<void> removeItem({required String key}) async {}
}

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => null;
}

/// Records each ask, the shell's foreground callback, and its value at call
/// time; each ask returns a future the test completes.
class _FakeAsk {
  final pending = <Completer<ReaskOutcome>>[];
  final foregroundAtCall = <bool>[];
  bool Function()? isForeground;
  int get calls => pending.length;

  Future<ReaskOutcome> call(BuildContext context, WidgetRef ref,
      {bool Function()? isForeground}) {
    this.isForeground = isForeground;
    foregroundAtCall.add(isForeground!());
    final c = Completer<ReaskOutcome>();
    pending.add(c);
    return c.future;
  }

  void complete(ReaskOutcome outcome) => pending.last.complete(outcome);

  void completeAll() {
    for (final c in pending) {
      if (!c.isCompleted) c.complete(ReaskOutcome.notNeeded);
    }
  }
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 400 && !ready(); i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

/// Runs real async work without blocking the frame pump: the shell's own
/// work may hold an admission or the database while it waits for a frame.
Future<void> _bg(WidgetTester tester, Future<void> Function() work) async {
  var done = false;
  Object? failure;
  StackTrace? stack;
  await tester.runAsync(() async {
    unawaited(work().then((_) => done = true, onError: (Object e, StackTrace s) {
      failure = e;
      stack = s;
      done = true;
    }));
  });
  await _until(tester, () => done);
  if (failure != null) Error.throwWithStackTrace(failure!, stack!);
}

/// Lets the shell's real async work (database, resume chain) progress.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump();
  }
}

Future<void> _background(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
}

Future<void> _resume(WidgetTester tester) async {
  for (final s in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
    await tester.pump();
  }
  await _settle(tester);
}

/// Mounts the real shell for an authenticated account (F2Fixture replica,
/// Supabase unconfigured) with [reaskConsentProvider] replaced by a fake.
Future<_FakeAsk> _mount(WidgetTester tester) async {
  expect(SupabaseConfig.isConfigured, isFalse,
      reason: 'this harness must run without Supabase defines (no network)');
  final ask = _FakeAsk();
  final fixture = (await tester.runAsync(F2Fixture.create))!;
  await tester.runAsync(() => fixture.signIn('reask-owner'));
  expect(AppSession.instance.status, SessionStatus.authenticated);
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => fixture.support.path);
  FlutterLocalNotificationsPlatform.instance = _Notifications();
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  final container = ProviderContainer(overrides: [
    appDatabaseProvider.overrideWithValue(fixture.host.current!.database),
    reaskConsentProvider.overrideWithValue(ask.call),
  ]);
  await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
          theme: AppTheme.light,
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          home: const AppShell())));
  addTearDown(() async {
    ask.completeAll();
    await _bg(tester, AppSession.instance.drainAdmissions);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    container.dispose();
    appDataRestoring.value = false;
    await _bg(tester, fixture.dispose);
    await tester.pump(const Duration(seconds: 30));
  });
  return ask;
}

void main() {
  setUpAll(() async {
    await Supabase.initialize(
        url: 'https://example.supabase.co',
        anonKey: 'anon',
        authOptions: const FlutterAuthClientOptions(
            autoRefreshToken: false,
            detectSessionInUri: false,
            localStorage: EmptyLocalStorage(),
            pkceAsyncStorage: _PkceStorage()),
        httpClient: MockClient((request) async {
          _requests.add('${request.method} ${request.url}');
          return http.Response('{"message":"not allowlisted"}', 500,
              request: request);
        }));
  });
  tearDownAll(() async => Supabase.instance.dispose());
  setUp(() => rootBundle.clear());
  tearDown(() => expect(_requests, isEmpty, reason: 'no request may be made'));

  testWidgets(
      'never asks behind the restore loader; a dismissed sheet is asked again '
      'once per resume, never while backgrounded, never twice at once',
      (tester) async {
    appDataRestoring.value = true;
    final ask = await _mount(tester);
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(ask.calls, 0, reason: 'the root restore loader is up');
    appDataRestoring.value = false;
    await _until(tester, () => ask.calls == 1);
    ask.complete(ReaskOutcome.shown); // swiped away: nothing recorded
    await _settle(tester);
    expect(ask.calls, 1);

    await _background(tester);
    await tester.pump(const Duration(minutes: 1));
    expect(ask.calls, 1, reason: 'never asked off-screen');

    await _resume(tester);
    await _until(tester, () => ask.calls == 2);
    expect(ask.pending.last.isCompleted, isFalse);

    await _background(tester);
    await _resume(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(ask.calls, 2, reason: 'one ask at a time');
  });

  testWidgets(
      'unknown preference: the 15 s retry is dropped by backgrounding; the '
      'next resume asks exactly once', (tester) async {
    final ask = await _mount(tester);
    await _until(tester, () => ask.calls == 1);
    ask.complete(ReaskOutcome.unknownPreference);
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
    await _background(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(ask.calls, 1, reason: 'no retry while backgrounded');

    await _resume(tester);
    await _until(tester, () => ask.calls == 2);
    ask.complete(ReaskOutcome.notNeeded);
    await _settle(tester);
    await tester.pump(const Duration(minutes: 2));
    expect(ask.calls, 2);
  });

  testWidgets(
      'an ask pending across backgrounding that reports deferred is asked '
      'again on resume only, and isForeground follows the lifecycle',
      (tester) async {
    final ask = await _mount(tester);
    await _until(tester, () => ask.calls == 1);
    expect(ask.foregroundAtCall.single, isTrue);
    expect(ask.isForeground!(), isTrue);

    await _background(tester);
    expect(ask.isForeground!(), isFalse,
        reason: 'the shell callback reports background');
    ask.complete(ReaskOutcome.deferred);
    await _settle(tester);
    await tester.pump(const Duration(minutes: 2));
    expect(ask.calls, 1, reason: 'no new ask while backgrounded');

    await _resume(tester);
    await _until(tester, () => ask.calls == 2);
    expect(ask.isForeground!(), isTrue);
    expect(ask.foregroundAtCall, [true, true]);
    await tester.pump(const Duration(seconds: 1));
    expect(ask.calls, 2);
  });
}
