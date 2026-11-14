import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';

import '../core/session/fake_account_scope.dart';

/// Adversarial scenarios 2, 5 and 7 against the real [AppSession] with the
/// production wiring of lifecycle_residue_test / app_session_test (injected
/// account scope and residue purge).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final s = AppSession.instance;
  late FakeAccountScope scope;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    s.configureCaptureDeviceUnlink(null);
    s.configureCaptureUnlinkTicket(null);
    s.configureSignOutFlush(null);
    s.configureCaptureOwnerClear(() async => true);
    s.configureAccountScope(null);
    await s.wipeAndReset();
    scope = FakeAccountScope();
    s.configureAccountScope(scope);
  });

  tearDown(() async {
    s.configureSignOutFlush(null);
    s.configureCaptureUnlinkTicket(null);
    s.configureAccountScope(null);
    await s.wipeAndReset();
  });

  Future<String> outcome(Future<void> f) =>
      f.then((_) => 'ok', onError: (Object e) {
        if (e is StaleAdmissionException) return 'stale';
        return 'error:${e.runtimeType}';
      });

  /// The persisted identity, as the next process would read it.
  Future<(SessionStatus, String?)> relaunch() async {
    s.debugResetAdmissionState();
    await s.load();
    return (s.status, s.email);
  }

  group('scenario 2 — sign-in tapped twice quickly', () {
    test(
        'two concurrent admissions of the same account: exactly one is '
        'admitted, the state is consistent', () async {
      // Both taps captured their attempt before either provider returned.
      final a1 = s.beginAuthAttempt();
      final a2 = s.beginAuthAttempt();
      final results = await Future.wait([
        outcome(s.setIdentity(
            method: 'apple', email: 'a@x.test', userId: 'uid-a', attempt: a1)),
        outcome(s.setIdentity(
            method: 'apple', email: 'a@x.test', userId: 'uid-a', attempt: a2)),
      ]);
      expect(results.where((r) => r == 'ok'), hasLength(1),
          reason: 'results=$results');
      expect(results.where((r) => r != 'ok'), everyElement('stale'));
      await s.finishOnboarding();
      expect(s.status, SessionStatus.authenticated);
      expect(s.email, 'a@x.test');
      expect(await s.readLocalDataOwnerUid(), 'uid-a');
      expect(scope.activeUid, 'uid-a');
      expect(await relaunch(), (SessionStatus.authenticated, 'a@x.test'));
    });

    test(
        'two concurrent admissions of DIFFERENT accounts: the later one '
        'wins everywhere (identity, owner, replica)', () async {
      final a1 = s.beginAuthAttempt();
      final a2 = s.beginAuthAttempt();
      final results = await Future.wait([
        outcome(s.setIdentity(
            method: 'apple', email: 'a@x.test', userId: 'uid-a', attempt: a1)),
        outcome(s.setIdentity(
            method: 'google', email: 'b@x.test', userId: 'uid-b', attempt: a2)),
      ]);
      expect(results.where((r) => r == 'ok'), hasLength(1),
          reason: 'results=$results');
      await s.finishOnboarding();
      final winner = s.email;
      final uid = winner == 'a@x.test' ? 'uid-a' : 'uid-b';
      expect(await s.readLocalDataOwnerUid(), uid);
      expect(scope.activeUid, uid);
      expect(s.status, SessionStatus.authenticated);
      expect(await relaunch(), (SessionStatus.authenticated, winner));
    });
  });

  group('scenario 5 — sign-out while offline', () {
    test(
        'a flush and a server unlink that never answer: local sign-out '
        'completes, nothing hangs past its bound', () async {
      await s.completeOnboarding(
          method: 'google', email: 'a@x.test', userId: 'uid-a');
      // Offline: the outbox flush and the server unlink never complete.
      s.configureSignOutFlush(() => Completer<void>().future);
      s.configureCaptureUnlinkTicket(() => () => Completer<void>().future);
      final sw = Stopwatch()..start();
      await s.flushPendingForSignOut().timeout(const Duration(seconds: 8));
      expect(sw.elapsed, lessThan(const Duration(seconds: 7)));
      final out = await s.signOut().timeout(const Duration(seconds: 2));
      expect(out, SignOutOutcome.complete);
      expect(s.status, SessionStatus.needsOnboarding);
      expect(s.authMethod, isNull);
      expect(scope.calls, contains('lock'));
      expect(await relaunch(), (SessionStatus.needsOnboarding, null));
    });
  });

  group('scenario 7 — sign-out and sign-in at the same moment', () {
    Future<void> expectConsistent() async {
      // Either cleanly signed out, or cleanly signed in as B — never a mix.
      final owner = await s.readLocalDataOwnerUid();
      if (s.status == SessionStatus.authenticated) {
        expect(s.email, 'b@x.test');
        expect(owner, 'uid-b');
        expect(scope.activeUid, 'uid-b');
      } else {
        expect(s.email, isNot('a@x.test'),
            reason: 'never left on the outgoing account');
      }
      final (status, email) = await relaunch();
      expect(email, isNot('a@x.test'),
          reason: 'relaunch never restores the outgoing account');
      if (status == SessionStatus.authenticated) {
        expect(email, 'b@x.test');
        expect(await s.readLocalDataOwnerUid(), 'uid-b');
      }
    }

    test('sign-in (attempt captured first) racing a sign-out', () async {
      await s.completeOnboarding(
          method: 'google', email: 'a@x.test', userId: 'uid-a');
      final attempt = s.beginAuthAttempt();
      final results = await Future.wait([
        outcome(s.setIdentity(
            method: 'google',
            email: 'b@x.test',
            userId: 'uid-b',
            attempt: attempt)),
        outcome(s.signOut()),
      ]);
      expect(results[1], 'ok');
      await expectConsistent();
    });

    test('sign-out started first, sign-in tapped during it', () async {
      await s.completeOnboarding(
          method: 'google', email: 'a@x.test', userId: 'uid-a');
      final hold = Completer<bool>();
      s.configureCaptureOwnerClear(() => hold.future);
      final out = outcome(s.signOut());
      await pumpEventQueue();
      final attempt = s.beginAuthAttempt();
      final signIn = outcome(s.setIdentity(
          method: 'google',
          email: 'b@x.test',
          userId: 'uid-b',
          attempt: attempt));
      hold.complete(true);
      final results = await Future.wait([out, signIn]);
      expect(results[0], 'ok');
      expect(results[1], 'stale',
          reason: 'an attempt begun during the logout cannot admit');
      s.configureCaptureOwnerClear(() async => true);
      await expectConsistent();
      // And the retry after the sign-out succeeds.
      await s.completeOnboarding(
          method: 'google', email: 'b@x.test', userId: 'uid-b');
      expect(s.status, SessionStatus.authenticated);
      expect(await s.readLocalDataOwnerUid(), 'uid-b');
    });
  });
}
