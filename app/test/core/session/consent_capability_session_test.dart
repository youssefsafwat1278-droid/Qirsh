import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/core/session/app_session.dart';

import '../../harness/consent_session_support.dart';
import 'f2_fixture.dart';

// Consent-security amendment, session layer: the consent-only capability and the
// logout / readmission closure, over the REAL AppSession, scope host and replica
// store (F2Fixture). The identity evidence is the existing MockClient-backed fake
// GoTrue SDK client: nothing here reaches a network.

/// A scope whose lock fails, to make a logout fail part-way. Everything else is
/// the real host.
class _FailingLockScope implements AccountScopeControl {
  _FailingLockScope(this._inner);
  final AccountScopeControl _inner;
  bool failLock = true;

  @override
  String? get activeUid => _inner.activeUid;
  @override
  AccountScope? get activeScope => _inner.activeScope;
  @override
  Future<void> activate(String uid, {AdmissionAuthority? authority}) =>
      _inner.activate(uid, authority: authority);
  @override
  Future<void> detach() => _inner.detach();
  @override
  Future<void> suspendForSwap() => _inner.suspendForSwap();
  @override
  Future<void> lock() {
    if (failLock) throw StateError('lock failed');
    return _inner.lock();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;

  setUp(() async {
    f = await F2Fixture.create();
  });

  tearDown(() async {
    await f.dispose();
  });

  group('issuance from the committed identity publication', () {
    test('needsOnboarding: a capability is issued (canCreate false) and the '
        'general local API stays closed', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      expect(f.session.status, SessionStatus.needsOnboarding);
      expect(capability.uid, 'uid-x');
      expect(capability.canCreate, isFalse);
      expect(capability.isCurrent, isTrue);
      expect(capability.database, same(f.host.current!.database),
          reason: 'bound to the exact live database');
      expect(f.session.captureLocalWorkAuthority(), isNull,
          reason: 'general local work still requires an authenticated session');
      expect(
          () => f.session.runAdmittedLocalOperation(
              const AdmissionAuthority.forTest('uid-x'), () async => 1),
          throwsA(isA<StaleAdmissionException>()));
      expect(await f.session.runConsentLocalOperation(capability, () async => 7),
          7);
      expect(identical(f.session.captureConsentCapability(), capability),
          isTrue);
    });

    test('NO fallback: the authenticated status, the local-work authority and '
        'the active database do not mint a capability', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      await f.session.finishOnboarding();
      expect(f.session.status, SessionStatus.authenticated);
      expect(identical(f.session.captureConsentCapability(), capability), isTrue);
      // A sign-in with no SDK evidence issues nothing, and nothing is derived.
      f.session.configureConsentSdkClient(() => null);
      await f.signIn('uid-x');
      expect(f.session.status, SessionStatus.authenticated);
      expect(f.session.captureLocalWorkAuthority(), isNotNull);
      expect(capability.isCurrent, isFalse);
      expect(f.session.captureConsentCapability(), isNull,
          reason: 'a revoked proof is never renewed from weaker evidence');
    });

    test('a returning authenticated user: the guarded automatic publication '
        'of a fresh SDK session issues one capability, kept across refreshes',
        () async {
      f.session.configureConsentSdkClient(() => null);
      await f.signIn('uid-x');
      expect(f.session.captureConsentCapability(), isNull);
      final client = await F2Fixture.liveClient('uid-x');
      await f.session.revalidateSupabaseSessionOnResume(client);
      final capability = f.session.captureConsentCapability();
      expect(capability, isNotNull);
      expect(capability!.uid, 'uid-x');
      expect(capability.canCreate, isFalse);
      expect(capability.database, same(f.host.current!.database));
      // A later token refresh / resume re-publishes the same lifecycle: the
      // proof (and any operation holding it) is not churned.
      await f.session.revalidateSupabaseSessionOnResume(client);
      expect(identical(f.session.captureConsentCapability(), capability), isTrue);
    });

    final denied = <String, Future<void> Function(F2Fixture f)>{
      'no SDK session at all': (f) async {
        expect(await freshSignIn(f, 'uid-x', noSdk: true), isNull);
      },
      'a blind always-true predicate with no real SDK session': (f) async {
        expect(
            await freshSignIn(f, 'uid-x',
                noSdk: true, sessionCurrent: () => true),
            isNull);
      },
      'a blind always-true predicate beside another user\'s SDK session':
          (f) async {
        final other = await F2Fixture.liveClient('uid-y');
        expect(
            await freshSignIn(f, 'uid-x',
                client: other, sessionCurrent: () => true),
            isNull);
      },
      // A stale or foreign predicate does not even admit: the sign-in itself is
      // refused, so there is nothing to issue a capability for.
      'an expired or missing SDK session': (f) async {
        await expectLater(freshSignIn(f, 'uid-x', sessionCurrent: () => false),
            throwsA(isA<StaleAdmissionException>()));
      },
      'an SDK session of another user': (f) async {
        final other = await F2Fixture.liveClient('uid-y');
        await expectLater(
            freshSignIn(f, 'uid-x',
                sessionCurrent: sdkSessionFresh(other, 'uid-x')),
            throwsA(isA<StaleAdmissionException>()));
      },
      'a guest identity': (f) async {
        expect(await freshSignIn(f, 'uid-x', method: 'guest'), isNull);
      },
      'no published scope': (f) async {
        f.session.configureAccountScope(null);
        expect(await freshSignIn(f, 'uid-x'), isNull);
      },
    };
    for (final entry in denied.entries) {
      test('denied: ${entry.key}', () async {
        await entry.value(f);
        expect(f.session.captureConsentCapability(), isNull);
      });
    }

    test('denied: ownership failed (unresolved) issues nothing', () async {
      // Only the ADMITTED OWNER's replica fails to open; the signed-out recovery
      // scope (uid == null) and every other scope initialise normally.
      await f.dispose();
      f = await F2Fixture.create(initialize: (db, uid) async {
        if (uid == 'uid-x') throw StateError('open failed');
        return const AccountScopeInit();
      });
      await expectLater(
          freshSignIn(f, 'uid-x'), throwsA(isA<LocalDataOwnershipException>()));
      expect(f.session.captureConsentCapability(), isNull);
      expect(f.host.activeUid, isNull,
          reason: 'the signed-out recovery scope was published normally');
    });

    test('denied: ownership deferred (purge hook not registered) issues '
        'nothing', () async {
      await f.signIn('uid-x'); // the owner marker now names uid-x
      f.session.configureCaptureOwnerClear(null);
      expect(await freshSignIn(f, 'uid-y'), isNull);
      expect(f.session.captureConsentCapability(), isNull);
    });
  });

  group('permanent staleness', () {
    Future<void> end(String how) async {
      switch (how) {
        case 'logout':
          final t = f.session.signOut();
          expect(f.session.captureConsentCapability(), isNull);
          await t;
        case 'removal':
          final t = f.session.removeDataFromDevice();
          expect(f.session.captureConsentCapability(), isNull);
          await t;
        case 'same uid, new epoch':
          await freshSignIn(f, 'uid-x');
        case 'another uid':
          await freshSignIn(f, 'uid-y');
        case 'auth loss':
          await f.session.finishOnboarding();
          f.session.markSessionInvalid();
      }
    }

    for (final how in [
      'logout',
      'removal',
      'same uid, new epoch',
      'another uid',
      'auth loss',
    ]) {
      test('$how: the previous proof is stale and never comes back', () async {
        final old = (await freshSignIn(f, 'uid-x'))!;
        await end(how);
        expect(old.isCurrent, isFalse);
        // A later admission of the same uid issues a NEW capability; it never
        // revives the old one.
        final next = await freshSignIn(f, 'uid-x');
        expect(next, isNotNull);
        expect(next!.isCurrent, isTrue);
        expect(old.isCurrent, isFalse, reason: 'permanently stale');
        expect(() => f.session.runConsentLocalOperation(old, () async => 1),
            throwsA(isA<StaleAdmissionException>()));
      });
    }

    test('auth loss revokes at the ORIGIN: no isCurrent call in between, and '
        'a recovered status cannot revive the proof', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      await f.session.finishOnboarding();
      // Nothing observes the capability until after the status has recovered.
      f.session.markSessionInvalid();
      f.session.value = SessionStatus.authenticated; // a "recovery"
      expect(f.session.captureConsentCapability(), isNull,
          reason: 'the proof object was dropped synchronously at the loss');
      expect(capability.isCurrent, isFalse);
    });

    test('an SDK session that is gone or expired revokes the proof at the '
        'reconcile that sees it, and recovery cannot revive it', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      await f.session.revalidateSupabaseSessionOnResume(
          F2Fixture.fakeClient('uid-x')); // a client with NO session
      expect(capability.isCurrent, isFalse);
      final live = await F2Fixture.liveClient('uid-x');
      await f.session.revalidateSupabaseSessionOnResume(live);
      expect(capability.isCurrent, isFalse, reason: 'permanently stale');
    });
  });

  // Astra run08 P1: an auth loss that lands WHILE an admission is in flight must
  // not be undone by that admission. The SDK session stays present and
  // nonexpired throughout (the MockClient-backed client is never touched), so
  // only the dedicated loss generation, captured before the admission's first
  // await, can bar the issue.
  group('an auth loss during admission is never undone by the admission', () {
    const firstIdentityWrite = 'onboarding_current_account_v1';
    bool isFirstIdentityWrite(String op, String key) =>
        op == 'write' && key == firstIdentityWrite;

    test('explicit: a loss raised while the identity write is held (even one '
        'markSessionInvalid answers with an early return) issues nothing',
        () async {
      // No prior identity: markSessionInvalid returns early (no authMethod).
      final sdk = await F2Fixture.liveClient('uid-x');
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final signIn = freshSignIn(f, 'uid-x', client: sdk);
      await hold.reached.future;
      expect(sdk.auth.currentSession!.isExpired, isFalse,
          reason: 'the SDK session is still present and nonexpired');
      f.session.markSessionInvalid();
      hold.release.complete();
      expect(await signIn, isNull);
      expect(f.session.captureConsentCapability(), isNull);
      expect(sdk.auth.currentSession!.isExpired, isFalse);
    });

    test('explicit: the same with a known account (status really downgrades)',
        () async {
      await f.signIn('uid-x');
      final sdk = await F2Fixture.liveClient('uid-x');
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final signIn = freshSignIn(f, 'uid-x', client: sdk);
      await hold.reached.future;
      f.session.markSessionInvalid();
      hold.release.complete();
      expect(await signIn, isNull);
      expect(f.session.captureConsentCapability(), isNull);
    });

    test('automatic: a loss raised while the publication is held issues '
        'nothing', () async {
      f.session.configureConsentSdkClient(() => null);
      await f.signIn('uid-x');
      final client = await F2Fixture.liveClient('uid-x');
      f.session.configureConsentSdkClient(() => client);
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final reconcile = f.session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;
      f.session.markSessionInvalid();
      hold.release.complete();
      await reconcile;
      expect(client.auth.currentSession!.isExpired, isFalse);
      expect(f.session.captureConsentCapability(), isNull);
    });

    test('automatic: an existing proof dropped by the loss is not restored by '
        'the held publication either', () async {
      final existing = (await freshSignIn(f, 'uid-x'))!;
      final client = await F2Fixture.liveClient('uid-x');
      f.session.configureConsentSdkClient(() => client);
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final reconcile = f.session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;
      f.session.markSessionInvalid();
      hold.release.complete();
      await reconcile;
      expect(existing.isCurrent, isFalse);
      expect(f.session.captureConsentCapability(), isNull);
    });

    test('explicit: a SYNCHRONOUS publication listener that invalidates the '
        'session leaves no replacement proof', () async {
      await f.signIn('uid-x');
      final sdk = await F2Fixture.liveClient('uid-x');
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final signIn = freshSignIn(f, 'uid-x', client: sdk);
      await hold.reached.future;
      var fired = false;
      void invalidate() {
        if (fired) return;
        fired = true;
        f.session.markSessionInvalid();
      }

      f.session.addListener(invalidate);
      addTearDown(() => f.session.removeListener(invalidate));
      hold.release.complete();
      expect(await signIn, isNull);
      expect(fired, isTrue, reason: 'the publication notified its listeners');
      expect(f.session.status, SessionStatus.sessionExpired);
      expect(f.session.captureConsentCapability(), isNull);
    });

    test('automatic: a SYNCHRONOUS publication listener that invalidates the '
        'session leaves no replacement proof', () async {
      f.session.configureConsentSdkClient(() => null);
      await f.signIn('uid-x');
      final client = await F2Fixture.liveClient('uid-x');
      f.session.configureConsentSdkClient(() => client);
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final reconcile = f.session.revalidateSupabaseSessionOnResume(client);
      await hold.reached.future;
      var fired = false;
      void invalidate() {
        if (fired) return;
        fired = true;
        f.session.markSessionInvalid();
      }

      f.session.addListener(invalidate);
      addTearDown(() => f.session.removeListener(invalidate));
      hold.release.complete();
      await reconcile;
      expect(fired, isTrue);
      expect(f.session.status, SessionStatus.sessionExpired);
      expect(f.session.captureConsentCapability(), isNull);
    });

    test('a LATER, genuinely fresh recovery issues a new proof; the revoked '
        'one stays stale', () async {
      // explicit recovery
      final sdk = await F2Fixture.liveClient('uid-x');
      final hold = f.storage.holdOnce(isFirstIdentityWrite);
      final lost = freshSignIn(f, 'uid-x', client: sdk);
      await hold.reached.future;
      f.session.markSessionInvalid();
      hold.release.complete();
      expect(await lost, isNull);
      final recovered = await freshSignIn(f, 'uid-x', client: sdk);
      expect(recovered, isNotNull);
      expect(recovered!.isCurrent, isTrue);
      expect(identical(f.session.captureConsentCapability(), recovered), isTrue);

      // automatic recovery after a further loss
      f.session.markSessionInvalid();
      expect(recovered.isCurrent, isFalse);
      await f.session.revalidateSupabaseSessionOnResume(sdk);
      final again = f.session.captureConsentCapability();
      expect(again, isNotNull);
      expect(identical(again, recovered), isFalse);
      expect(again!.isCurrent, isTrue);
      expect(recovered.isCurrent, isFalse, reason: 'permanently stale');
    });
  });

  group('logout closes admission synchronously and holds the closure', () {
    test('a held local operation: everything is invalid or refused at once, '
        'the scope is locked only after it settles, and an attempt taken '
        'during the closure never becomes current', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      await f.session.finishOnboarding();
      final authority = f.session.captureLocalWorkAuthority()!;
      final hold = Completer<void>();
      var opSettled = false;
      final op = f.session
          .runConsentLocalOperation(capability, () => hold.future)
          .whenComplete(() => opSettled = true);

      // Started, NOT awaited: awaiting it would wait for the held operation.
      var done = false;
      final logout = f.session.signOut().whenComplete(() => done = true);
      expect(capability.isCurrent, isFalse);
      expect(authority.isCurrent, isFalse);
      expect(f.session.captureConsentCapability(), isNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      // An attempt issued DURING the closure is refused now...
      final attempt = f.session.beginAuthAttempt();
      await expectLater(
          f.session.setIdentity(
              method: 'google', userId: 'uid-y', attempt: attempt),
          throwsA(isA<StaleAdmissionException>()));
      await expectLater(
          f.session.setIdentity(method: 'google', userId: 'uid-y'),
          throwsA(isA<StaleAdmissionException>()),
          reason: 'concurrent admissions are rejected while the closure is held');

      await pumpEventQueue(times: 40);
      expect(opSettled, isFalse);
      expect(done, isFalse, reason: 'logout waits for the bounded operation');
      expect(f.scope.calls, isNot(contains('lock')),
          reason: 'the scope is not locked while the operation holds the database');

      hold.complete();
      await op;
      await logout;
      expect(f.scope.calls, contains('lock'));
      expect(f.host.activeUid, isNull);
      // ...and still refused once it ended (the closure's end moved the epoch).
      await expectLater(
          f.session.setIdentity(
              method: 'google', userId: 'uid-y', attempt: attempt),
          throwsA(isA<StaleAdmissionException>()));
      // A genuinely new sign-in afterwards works.
      expect(await freshSignIn(f, 'uid-y'), isNotNull);
    });

    test('a concurrent sign-in during the logout flush is rejected, and the '
        'old cleanup never touches the new owner', () async {
      await f.signIn('uid-x');
      // W4: signOut no longer flushes; park it on the owner-marker release.
      final hold = f.storage.holdOnce(
          (op, key) => op == 'delete' && key == 'local_data_owner_uid');
      var done = false;
      final logout = f.session.signOut().whenComplete(() => done = true);
      await hold.reached.future;
      expect(done, isFalse, reason: 'parked mid-logout');
      // The closure is held through the flush: an admission is refused.
      await expectLater(
          f.session.setIdentity(method: 'google', userId: 'uid-y'),
          throwsA(isA<StaleAdmissionException>()));
      expect(await f.session.readLocalDataOwnerUid(), 'uid-x',
          reason: 'nothing of the new owner was written');
      hold.release.complete();
      await logout;
      expect(await f.session.readLocalDataOwnerUid(), isNull,
          reason: 'the logout cleaned up exactly the outgoing owner');
      expect(f.host.activeUid, isNull);
      await f.signIn('uid-y');
      expect(f.host.activeUid, 'uid-y');
      expect(await f.session.readLocalDataOwnerUid(), 'uid-y');
    });

    test('two logouts: the first one finishing does not reopen admission '
        'under the second', () async {
      await f.signIn('uid-x');
      final flushHold = Completer<void>();
      f.session.configureSignOutFlush(() => flushHold.future);
      addTearDown(() => f.session.configureSignOutFlush(null));
      final first = f.session.signOut();
      final second = f.session.signOut();
      flushHold.complete();
      await Future.wait([first, second]);
      expect(f.host.activeUid, isNull);
      await f.signIn('uid-x');
      expect(f.host.activeUid, 'uid-x');
    });

    test('a FAILED logout stays fail closed: no local or consent work, no '
        'restored authority, the counter is released and the failure is '
        'reported; only a later successful admission or logout recovers',
        () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      await f.session.finishOnboarding();
      final failing = _FailingLockScope(f.scope);
      f.session.configureAccountScope(failing);

      await expectLater(f.session.signOut(), throwsA(isA<StateError>()),
          reason: 'the incomplete logout is reported, not swallowed');

      // The old status and scope still look authenticated/open...
      expect(f.session.status, SessionStatus.authenticated);
      expect(f.host.activeUid, 'uid-x');
      // ...but nothing may use them, and the outgoing proof is never restored.
      expect(capability.isCurrent, isFalse);
      expect(f.session.captureConsentCapability(), isNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);
      expect(
          () => f.session.runAdmittedLocalOperation(
              const AdmissionAuthority.forTest('uid-x'), () async => 1),
          throwsA(isA<StaleAdmissionException>()));
      await expectLater(f.session.maintenanceAuthority('uid-x'),
          throwsA(isA<StaleAdmissionException>()));
      // An AUTOMATIC admission cannot restore the old authority either.
      final client = await F2Fixture.liveClient('uid-x');
      await f.session.revalidateSupabaseSessionOnResume(client);
      expect(f.session.captureConsentCapability(), isNull);
      expect(f.session.captureLocalWorkAuthority(), isNull);

      // The counter was released (not leaked): a retried logout runs and succeeds.
      failing.failLock = false;
      await f.session.signOut();
      expect(f.host.activeUid, isNull);
      // ...and a genuine explicit admission recovers.
      f.session.configureAccountScope(f.scope);
      expect(await freshSignIn(f, 'uid-x'), isNotNull);
    });

    test('a failed logout is also recovered by an explicit successful sign-in',
        () async {
      await freshSignIn(f, 'uid-x');
      await f.session.finishOnboarding();
      final failing = _FailingLockScope(f.scope);
      f.session.configureAccountScope(failing);
      await expectLater(f.session.signOut(), throwsA(isA<StateError>()));
      expect(f.session.captureLocalWorkAuthority(), isNull);
      failing.failLock = false;
      final recovered = await freshSignIn(f, 'uid-x');
      expect(recovered, isNotNull);
      expect(recovered!.isCurrent, isTrue);
    });
  });

  group('same-uid readmission and account switch drain only the local work',
      () {
    test('the readmission waits for a held consent operation, which then '
        'ends stale; nothing from it reaches the newer scope', () async {
      final capability = (await freshSignIn(f, 'uid-x'))!;
      final sdk = await F2Fixture.liveClient('uid-x');
      final hold = Completer<void>();
      final op = f.session
          .runConsentLocalOperation(capability, () => hold.future)
          .then<Object?>((_) => null, onError: (Object e) => e);
      final activations =
          f.scope.calls.where((c) => c == 'activate:uid-x').length;
      var readmitted = false;
      // The client is created BEFORE, so the call below reaches setIdentity (and
      // its synchronous acceptance) without suspending first.
      final readmission = freshSignIn(f, 'uid-x', client: sdk)
          .whenComplete(() => readmitted = true);
      expect(capability.isCurrent, isFalse,
          reason: 'invalidated synchronously when the readmission was accepted');
      expect(f.session.captureConsentCapability(), isNull);
      await pumpEventQueue(times: 40);
      expect(readmitted, isFalse);
      expect(f.scope.calls.where((c) => c == 'activate:uid-x').length,
          activations,
          reason: 'the database is not closed or reused under the held operation');
      hold.complete();
      expect(await op, isNull, reason: 'the bounded operation itself settled');
      final next = await readmission;
      expect(next, isNotNull);
      expect(next!.isCurrent, isTrue);
      expect(capability.isCurrent, isFalse);
    });
  });
}
