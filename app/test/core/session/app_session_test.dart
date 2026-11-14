import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'fake_account_scope.dart';
import 'recording_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Builds a [SupabaseClient] whose `auth.currentSession` can be set to a
/// not-yet-expired session with no network call (mirrors the real bug: a
/// locally-cached session can be non-null while genuinely invalid
/// server-side — `bindSupabaseAuth`/`_reconcileSupabaseSession` only ever
/// read `currentSession` synchronously, never make a request themselves).
SupabaseClient _client() {
  final http = MockClient((request) async => Response('{}', 200));
  return SupabaseClient(
    'https://example.supabase.co',
    'public-anon-key',
    httpClient: http,
  );
}

Future<void> _recoverValidSession(
  SupabaseClient client, {
  required String userId,
  String? email,
}) async {
  String segment(Map<String, dynamic> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  final header = segment({'alg': 'none', 'typ': 'JWT'});
  final payload = segment({
    'exp':
        DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch ~/
            1000,
    'sub': userId,
  });
  await client.auth.recoverSession(jsonEncode({
    'access_token': '$header.$payload.',
    'token_type': 'bearer',
    'user': {'id': userId, if (email != null) 'email': email},
  }));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    AppSession.instance.configureCaptureDeviceUnlink(null);
    AppSession.instance.configureCaptureUnlinkTicket(null);
    // MALI-054n: production always registers the native/file residue purge
    // hook (bootstrap capture_registration). Default it to success here so the
    // owner-lifecycle tests exercise the production wiring; fail-closed tests
    // override it. wipeAndReset() below now also runs this hook.
    AppSession.instance.configureCaptureOwnerClear(() async => true);
    AppSession.instance.configureAccountScope(null);
    await AppSession.instance.wipeAndReset();
  });

  test(
      'P3: sign out takes the unlink ticket before revoking and sends it '
      'exactly once (never the gated hook)', () async {
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'user@example.com',
      userId: 'uid-1',
    );
    final events = <String>[];
    var gatedHook = 0;
    AppSession.instance.configureCaptureDeviceUnlink(() async => gatedHook++);
    AppSession.instance.configureCaptureUnlinkTicket(() {
      // Taken while the outgoing admission is still current.
      events.add('take:${AppSession.instance.status.name}');
      return () async => events.add('send');
    });

    await AppSession.instance.signOut();
    await pumpEventQueue();

    expect(events, ['take:authenticated', 'send']);
    expect(gatedHook, 0);
    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
  });

  test('P3: Cloud OFF (no ticket) sign-out sends nothing', () async {
    var gatedHook = 0;
    AppSession.instance.configureCaptureDeviceUnlink(() async => gatedHook++);
    AppSession.instance.configureCaptureUnlinkTicket(() => null);

    await AppSession.instance.signOut();
    await pumpEventQueue();

    expect(gatedHook, 0);
    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
  });

  test('wipeAndReset preserves the DB encryption key', () async {
    const storage = FlutterSecureStorage();
    await storage.write(
      key: SecureDatabaseKeyStore.defaultStorageKey,
      value: 'db-key-abc',
    );
    await storage.write(key: 'some_session_key', value: 'gone');

    await AppSession.instance.wipeAndReset();

    // The DB key survives so the still-on-disk encrypted DB stays openable;
    // everything else is cleared.
    expect(
      await storage.read(key: SecureDatabaseKeyStore.defaultStorageKey),
      'db-key-abc',
    );
    expect(await storage.read(key: 'some_session_key'), isNull);
  });

  test('fresh installs start at onboarding', () async {
    await AppSession.instance.load();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isFalse);
    expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
    expect(AppSession.instance.authMethod, isNull);
  });

  test('sign out clears current onboarding state but remembers the account',
      () async {
    await AppSession.instance.completeOnboarding(
      method: 'email',
      email: 'user@example.com',
      userId: 'returning-user-fixture',
    );

    expect(AppSession.instance.status, SessionStatus.authenticated);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);

    await AppSession.instance.signOut();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isFalse);
    expect(AppSession.instance.authMethod, isNull);
    expect(AppSession.instance.email, isNull);

    await AppSession.instance.setIdentity(
      method: 'email',
      email: 'user@example.com',
      userId: 'returning-user-fixture',
    );
    expect(AppSession.instance.status, SessionStatus.authenticated);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
  });

  test('returning users become authenticated after signing in again', () async {
    await AppSession.instance.completeOnboarding(
      method: 'email',
      email: 'user@example.com',
      userId: 'returning-user-fixture',
    );
    await AppSession.instance.signOut();

    await AppSession.instance.setIdentity(
      method: 'email',
      email: 'user@example.com',
      userId: 'returning-user-fixture',
    );

    expect(AppSession.instance.status, SessionStatus.authenticated);
    expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    expect(AppSession.instance.authMethod, 'email');
    expect(AppSession.instance.email, 'user@example.com');
  });

  test('a new account on the same device must complete setup once', () async {
    await AppSession.instance.completeOnboarding(
      method: 'google',
      email: 'first@example.com',
      userId: 'user-1',
    );
    await AppSession.instance.signOut();

    await AppSession.instance.setIdentity(
      method: 'google',
      email: 'second@example.com',
      userId: 'user-2',
    );

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isFalse);

    await AppSession.instance.finishOnboarding();
    expect(AppSession.instance.status, SessionStatus.authenticated);

    await AppSession.instance.signOut();
    await AppSession.instance.setIdentity(
      method: 'google',
      email: 'first@example.com',
      userId: 'user-1',
    );
    expect(AppSession.instance.status, SessionStatus.authenticated);
  });

  test('changing account resets session-scoped selected account state',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeAccountIdProvider.notifier).state = 'old-account-id';

    await AppSession.instance.setIdentity(
      method: 'google',
      email: 'new@example.com',
      userId: 'new-user-id',
    );

    expect(container.read(activeAccountIdProvider), isNull);
  });

  test('legacy completion without an identity does not complete a new account',
      () async {
    FlutterSecureStorage.setMockInitialValues({
      'onboarding_done': '1',
    });

    await AppSession.instance.load();

    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    expect(AppSession.instance.hasCompletedOnboarding, isFalse);
    expect(AppSession.instance.hasSeenWelcomeManifesto, isTrue);
    expect(AppSession.instance.authMethod, isNull);
  });

  test('wipe reset makes the first-launch welcome eligible again', () async {
    await AppSession.instance.markWelcomeManifestoSeen();

    expect(AppSession.instance.hasSeenWelcomeManifesto, isTrue);

    await AppSession.instance.wipeAndReset();

    expect(AppSession.instance.hasSeenWelcomeManifesto, isFalse);
    expect(AppSession.instance.status, SessionStatus.needsOnboarding);
  });

  // ── Auth/session-reconciliation regression suite ─────────────────────────
  //
  // Reproduces the live defect: local onboarding metadata (auth method,
  // completed-account keys) alone used to be sufficient to mark a user
  // `authenticated`, even when the live Supabase session was actually
  // invalid — because `_reconcileSupabaseSession` returned early on a null
  // session instead of downgrading status. AppShell then mounted with no
  // valid session and every Supabase-primary repository call threw an
  // unhandled `AuthRepoException('auth_required')`.

  group('scenario A — valid local metadata + valid Supabase session', () {
    test('AppShell is reachable: status stays authenticated', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final client = _client();
      await _recoverValidSession(client,
          userId: 'uid-1', email: 'user@example.com');

      await AppSession.instance.bindSupabaseAuth(client);

      expect(AppSession.instance.status, SessionStatus.authenticated);
      expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    });
  });

  group('scenario B — valid local metadata + currentSession null', () {
    test('status downgrades to sessionExpired, never stays authenticated',
        () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      expect(AppSession.instance.status, SessionStatus.authenticated);

      final client = _client(); // currentSession is null by construction

      await AppSession.instance.bindSupabaseAuth(client);

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
      // Onboarding completion itself must be untouched — this is not a
      // sign-out, only the live-session judgment changed.
      expect(AppSession.instance.hasCompletedOnboarding, isTrue);
      expect(AppSession.instance.authMethod, 'google');
    });

    test('router sends a sessionExpired user to the sign-in screen', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      AppSession.instance.markSessionInvalid();

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
      expect(
        onboardingEntryPathForSession(AppSession.instance),
        '/onboarding/auth',
      );
    });
  });

  group('scenario C — invalid refresh token during startup (exact repro)', () {
    test(
        'reproduces the live evidence exactly: authMethod=google, '
        'onboardingDone=true, currentSession=null → sessionExpired, '
        'never an unhandled exception', () async {
      // Exact values captured live: [EVIDENCE][AppSession.load]
      // authMethod=google onboardingDone=true
      // currentAccountKey=google:qa-user@example.com
      // status=SessionStatus.authenticated; then bindSupabaseAuth observed
      // currentSession=null (refresh token invalid) with status left
      // unchanged at authenticated — the bug.
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'qa-user@example.com',
        userId: 'uid-live-repro',
      );
      final client = _client();

      // Must not throw synchronously or asynchronously.
      await expectLater(
        AppSession.instance.bindSupabaseAuth(client),
        completes,
      );

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
    });
  });

  group('scenario D — session revoked while backgrounded', () {
    test('revalidateSupabaseSessionOnResume downgrades on resume', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final client = _client();
      await _recoverValidSession(client,
          userId: 'uid-1', email: 'user@example.com');
      await AppSession.instance.bindSupabaseAuth(client);
      expect(AppSession.instance.status, SessionStatus.authenticated);

      // By the time the app is foregrounded again, the token was revoked
      // server-side — no in-memory session remains and no auth-state event
      // was ever delivered while backgrounded. A fresh client instance with
      // no recovered session isolates exactly this resume-time re-check,
      // independent of GoTrue's own async sign-out broadcast machinery
      // (already covered separately by scenario I).
      final clientOnResume = _client();

      await AppSession.instance
          .revalidateSupabaseSessionOnResume(clientOnResume);

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
    });
  });

  group('scenario E — repository throws auth_required while shell visible', () {
    test('handleAuthRequiredFailure triggers the centralized recovery',
        () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      expect(AppSession.instance.status, SessionStatus.authenticated);

      await AppSession.instance.handleAuthRequiredFailure();

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
      expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    });
  });

  group('scenario F — fresh install, onboarding incomplete', () {
    test('onboarding flow is unaffected by the new reconciliation logic',
        () async {
      await AppSession.instance.load();
      expect(AppSession.instance.status, SessionStatus.needsOnboarding);

      // A null-session reconcile before onboarding ever completed must not
      // be mistaken for an expired session — there was never a valid one.
      await AppSession.instance.setIdentity(method: 'google', userId: 'uid-1');
      final client = _client();
      await AppSession.instance.bindSupabaseAuth(client);

      expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    });
  });

  group('scenario G — onboarding complete but user signed out', () {
    test('sign-in screen shown, onboarding completion not reset', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );

      AppSession.instance.markSessionInvalid();

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
      expect(AppSession.instance.hasCompletedOnboarding, isTrue,
          reason: 'markSessionInvalid must never reset onboarding completion');
      expect(AppSession.instance.authMethod, 'google');

      // Contrast: an explicit sign-out (not a mere expired session) is the
      // one path that intentionally does reset onboarding completion.
      await AppSession.instance.signOut();
      expect(AppSession.instance.hasCompletedOnboarding, isFalse);
    });
  });

  group('scenario H — Google/Apple sign-in success', () {
    test('valid authenticated state and shell access for both providers',
        () async {
      for (final method in ['google', 'apple']) {
        await AppSession.instance.wipeAndReset();
        await AppSession.instance.completeOnboarding(
          method: method,
          email: 'user@example.com',
          userId: 'uid-$method',
        );
        final client = _client();
        await _recoverValidSession(client,
            userId: 'uid-$method', email: 'user@example.com');

        await AppSession.instance.bindSupabaseAuth(client);

        expect(AppSession.instance.status, SessionStatus.authenticated,
            reason: '$method sign-in must reach a valid authenticated state');
      }
    });
  });

  group('scenario I — sign-out', () {
    test(
        'Supabase session cleared, status moves to needsOnboarding, '
        'and a listener notification fires (drives router + provider '
        'invalidation)', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      var notified = 0;
      void listener() => notified++;
      AppSession.instance.addListener(listener);
      addTearDown(() => AppSession.instance.removeListener(listener));

      await AppSession.instance.signOut();

      expect(AppSession.instance.status, SessionStatus.needsOnboarding);
      expect(AppSession.instance.authMethod, isNull);
      expect(notified, greaterThanOrEqualTo(1),
          reason: 'go_router refreshListenable and AppShell\'s session '
              'listener both depend on this notification firing');
      expect(
        onboardingEntryPathForSession(AppSession.instance),
        '/onboarding/auth',
      );
    });
  });

  group('scenario J — multiple simultaneous auth_required failures', () {
    test('exactly one recovery transition, no redirect storm', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      var notifications = 0;
      void listener() => notifications++;
      AppSession.instance.addListener(listener);
      addTearDown(() => AppSession.instance.removeListener(listener));

      // Several concurrent repository calls all discover auth_required at
      // once (e.g. budgets + goals + transactions failing in the same
      // frame) — every one of them calls the same centralized recovery.
      await Future.wait([
        AppSession.instance.handleAuthRequiredFailure(),
        AppSession.instance.handleAuthRequiredFailure(),
        AppSession.instance.handleAuthRequiredFailure(),
        AppSession.instance.handleAuthRequiredFailure(),
      ]);

      expect(AppSession.instance.status, SessionStatus.sessionExpired);
      // ValueNotifier only notifies on an actual value change: 4 concurrent
      // callers collapse into exactly 1 notification, not 4 — no storm.
      expect(notifications, 1);
    });
  });

  // ── B1: sign-out local financial-data isolation ──────────────────────────
  //
  // A previous sign-out never wiped local Drift financial data — the DB file
  // is shared device-wide, so a second user signing in and restoring a
  // backup could push the first user's transactions into their own Supabase
  // account (TransactionsBackfillService/AccountsBackfillService trust
  // "everything in the local DB belongs to whoever is signed in now"). These
  // scenarios cover the sign-out-side half of the fix: the wipe must run,
  // must gate sign-out (not run best-effort), and must be idempotent.

  group('scenario K — sign-out LOCKS the replica before clearing identity', () {
    test('the account scope is locked (never wiped) during sign-out', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final scope = FakeAccountScope();
      AppSession.instance.configureAccountScope(scope);

      await AppSession.instance.signOut();

      expect(scope.calls, ['lock']);
      expect(AppSession.instance.status, SessionStatus.needsOnboarding);
    });

    test('a failing lock aborts sign-out entirely — fail-closed, not silent',
        () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      AppSession.instance
          .configureAccountScope(FakeAccountScope()..lockError = Exception('x'));

      await expectLater(AppSession.instance.signOut(), throwsA(isException));

      // Nothing about the signed-in identity may change if the lock failed: a
      // caller that ignored the thrown error must never observe a device that
      // looks signed-out while the account's database is still open.
      expect(AppSession.instance.status, SessionStatus.authenticated);
      expect(AppSession.instance.authMethod, 'google');
      expect(AppSession.instance.email, 'user@example.com');
      expect(AppSession.instance.hasCompletedOnboarding, isTrue);
    });

    test(
        'W2: a failure AFTER the lock routes to sign-in (sessionExpired), '
        'never a dead authenticated shell', () async {
      final storage = RecordingSecureStorage().install();
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final scope = FakeAccountScope();
      AppSession.instance.configureAccountScope(scope);
      storage.gate = (op, key) async {
        if (op == 'delete' && key == 'auth_method') {
          throw Exception('keychain');
        }
      };

      await expectLater(AppSession.instance.signOut(), throwsA(isException));

      expect(scope.calls, ['lock']);
      expect(AppSession.instance.status, SessionStatus.sessionExpired);
    });

    test('repeated sign-out is idempotent', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final scope = FakeAccountScope();
      AppSession.instance.configureAccountScope(scope);

      await AppSession.instance.signOut();
      await AppSession.instance.signOut();
      await AppSession.instance.signOut();

      expect(scope.calls, ['lock', 'lock', 'lock']);
      expect(AppSession.instance.status, SessionStatus.needsOnboarding);
      expect(AppSession.instance.authMethod, isNull);
    });

    test(
        'a reactive sign-out from a Supabase auth-state event never throws '
        'even if the lock would fail (it is not even attempted: only an '
        'explicit sign-out locks)',
        () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-1',
      );
      final scope = FakeAccountScope()..lockError = Exception('disk full');
      AppSession.instance.configureAccountScope(scope);
      final client = _client();

      // signedOut/userDeleted auth-state events are handled by the same
      // internal listener bindSupabaseAuth wires up; recoverSession then
      // signOut on the client drives that listener exactly as production
      // does. This must complete without an unhandled async error.
      await _recoverValidSession(client, userId: 'uid-1');
      await AppSession.instance.bindSupabaseAuth(client);
      await expectLater(client.auth.signOut(), completes);
      // Give the onAuthStateChange listener (fired asynchronously off the
      // signOut call above) a turn to run within this test's window, so an
      // unhandled exception from it — were the try/catch removed — surfaces
      // as a test failure here rather than silently after teardown.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(scope.calls.contains('lock'), isFalse,
          reason: 'a server-driven auth loss keeps the replica open');
    });
  });

  group('scenario L — local data owner marker (backfill defense in depth)', () {
    test('is null before any session has ever reconciled', () async {
      expect(await AppSession.instance.readLocalDataOwnerUid(), isNull);
    });

    test('is claimed by the first uid to reconcile a valid session', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-a',
      );
      final client = _client();
      await _recoverValidSession(client, userId: 'uid-a');

      await AppSession.instance.bindSupabaseAuth(client);

      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');
    });

    test('sign-out clears the marker', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'user@example.com',
        userId: 'uid-a',
      );
      final client = _client();
      await _recoverValidSession(client, userId: 'uid-a');
      await AppSession.instance.bindSupabaseAuth(client);
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');

      await AppSession.instance.signOut();

      expect(await AppSession.instance.readLocalDataOwnerUid(), isNull);
    });

    test(
        'a conflicting uid does not silently overwrite an existing marker '
        '— only a wipe (sign-out) may clear it', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'a@example.com',
        userId: 'uid-a',
      );
      final clientA = _client();
      await _recoverValidSession(clientA, userId: 'uid-a');
      await AppSession.instance.bindSupabaseAuth(clientA);
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');

      // Simulate a second identity's session reconciling against this
      // device's AppSession without an intervening sign-out (the exact
      // scenario the marker is meant to catch, e.g. a crash mid-wipe).
      final clientB = _client();
      await _recoverValidSession(clientB,
          userId: 'uid-b', email: 'b@example.com');
      AppSession.instance.authMethod = 'google';
      AppSession.instance.configureCaptureOwnerClear(null);
      await AppSession.instance.bindSupabaseAuth(clientB);

      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a',
          reason: 'must stay uid-a until the owner changes through a '
              'confirmed residue release (or an explicit sign-out)');
    });
  });

  group('owner gate — MALI-002 (user B must never see user A\'s local data)',
      () {
    test(
        'conflicting owner + registered purge hook: reconcile releases residue, '
        'claims for the new UID and switches replica (no wipe)', () async {
      // User A owned the device, session expired without a sign-out wipe.
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'a@example.com',
        userId: 'uid-a',
      );
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');

      final scope = FakeAccountScope();
      AppSession.instance.configureAccountScope(scope);

      // User B's session reconciles on the same device.
      final clientB = _client();
      await _recoverValidSession(clientB,
          userId: 'uid-b', email: 'b@example.com');
      await AppSession.instance.bindSupabaseAuth(clientB);

      expect(scope.calls, ['activate:uid-b'],
          reason: 'B gets B\'s own replica; A\'s is locked, never wiped');
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-b');
    });

    test(
        'conflicting owner + NO purge hook (pre-bootstrap): admission '
        'deferred, then resolvePendingLocalDataOwnerConflict completes it',
        () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'a@example.com',
        userId: 'uid-a',
      );

      AppSession.instance.configureCaptureOwnerClear(null);
      final clientB = _client();
      await _recoverValidSession(clientB,
          userId: 'uid-b', email: 'b@example.com');
      await AppSession.instance.bindSupabaseAuth(clientB);

      // Deferred: ownership untouched, nothing claimed for B yet.
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');

      // Bootstrap registers the purge hook and resolves.
      AppSession.instance.configureCaptureOwnerClear(() async => true);
      await AppSession.instance.resolvePendingLocalDataOwnerConflict(clientB);

      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-b');
    });

    test('same owner: reconcile never locks or switches', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'a@example.com',
        userId: 'uid-a',
      );
      final scope = FakeAccountScope();
      AppSession.instance.configureAccountScope(scope);

      final clientA = _client();
      await _recoverValidSession(clientA,
          userId: 'uid-a', email: 'a@example.com');
      await AppSession.instance.bindSupabaseAuth(clientA);

      expect(scope.calls, ['activate:uid-a'],
          reason: 'idempotent re-admission of the same uid; nothing is locked');
      expect(await AppSession.instance.readLocalDataOwnerUid(), 'uid-a');
    });
  });

  group('W5 — app killed mid sign-out', () {
    /// Completes onboarding as uid-1, then starts a sign-out whose residue
    /// purge never returns (the process is killed there: method, email and
    /// account are still persisted) and simulates a fresh process.
    Future<void> killMidSignOut() async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'one@example.com',
        userId: 'uid-1',
      );
      expect(AppSession.instance.status, SessionStatus.authenticated);
      final reached = Completer<void>();
      AppSession.instance.configureCaptureOwnerClear(() {
        if (!reached.isCompleted) reached.complete();
        return Completer<bool>().future; // never completes: the kill point
      });
      unawaited(AppSession.instance.signOut());
      await reached.future.timeout(const Duration(seconds: 2));
      const storage = FlutterSecureStorage();
      expect(await storage.read(key: 'auth_method'), 'google',
          reason: 'killed before the identity was cleared');
      expect(await storage.read(key: 'logout_pending_v1'), isNotNull);
      // New process.
      AppSession.instance.configureCaptureOwnerClear(() async => true);
      AppSession.instance.debugResetAdmissionState();
    }

    test('load() never restores the outgoing identity as authenticated',
        () async {
      await killMidSignOut();
      await AppSession.instance.load();

      expect(AppSession.instance.status, SessionStatus.needsOnboarding);
      expect(AppSession.instance.hasCompletedOnboarding, isFalse);
      expect(AppSession.instance.authMethod, isNull);
    });

    test('automatic reconcile with the outgoing SDK session does not re-admit',
        () async {
      await killMidSignOut();
      await AppSession.instance.load();
      final client = _client();
      await _recoverValidSession(client,
          userId: 'uid-1', email: 'one@example.com');
      await AppSession.instance.bindSupabaseAuth(client);

      expect(AppSession.instance.status,
          isNot(SessionStatus.authenticated));
    });

    test('an explicit sign-in (same or another account) clears the pending key',
        () async {
      await killMidSignOut();
      await AppSession.instance.load();

      await AppSession.instance.setIdentity(
        method: 'google',
        email: 'two@example.com',
        userId: 'uid-2',
      );
      await AppSession.instance.finishOnboarding();
      expect(AppSession.instance.status, SessionStatus.authenticated);
      await Future<void>.delayed(Duration.zero);

      AppSession.instance.debugResetAdmissionState();
      await AppSession.instance.load();
      expect(AppSession.instance.status, SessionStatus.authenticated);
      expect(AppSession.instance.email, 'two@example.com');
    });

    test('a completed sign-out leaves no pending key behind', () async {
      await AppSession.instance.completeOnboarding(
        method: 'google',
        email: 'one@example.com',
        userId: 'uid-1',
      );
      await AppSession.instance.signOut();
      expect(await const FlutterSecureStorage().read(key: 'logout_pending_v1'),
          isNull);
      await AppSession.instance.setIdentity(
        method: 'google',
        email: 'one@example.com',
        userId: 'uid-1',
      );
      AppSession.instance.debugResetAdmissionState();
      await AppSession.instance.load();
      expect(AppSession.instance.status, SessionStatus.authenticated);
    });
  });
}
