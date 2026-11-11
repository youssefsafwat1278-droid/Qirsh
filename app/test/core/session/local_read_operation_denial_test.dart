// SDK event injection uses the real GoTrue broadcast; no production use.
// ignore_for_file: invalid_use_of_internal_member, invalid_use_of_protected_member

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/session/account_scope.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_access_broker.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:money_companion/features/app/app_boot_loader.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/app/local_read_cleanup_notice.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'f2_fixture.dart';
import '../../harness/egress_test_support.dart';

// O-R9 (Astra R8 O8-1 / O8-2 / O8-3) — the denial boundary of a startup-bound
// late classification, over the REAL session singleton, a real encrypted replica
// store/scope host and a recording secure storage. Every pause is deterministic
// (a held storage read, or a queue order), never a delay. Each case asserts the
// stored operation, the scope, the registry state, the process lock, the notice
// state and the retry target.

const _a = 'uid-op-a';
const _other = 'uid-op-b';
const _grantKey = SecureLocalReadStore.storageKey;

class _RouteContext implements BuildContext {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Widget _selectedHome() {
  final home = appRouter.configuration.routes.whereType<GoRoute>()
      .firstWhere((route) => route.path == '/');
  final selected = home.builder!(_RouteContext(), GoRouterState(appRouter.configuration,
      uri: Uri.parse('/'), matchedLocation: '/', fullPath: '/',
      pathParameters: const {}, pageKey: const ValueKey('/')));
  // Evaluate the reactive root's current selection, as its build would.
  final root = selected is ListenableBuilder
      ? selected.builder(_RouteContext(), selected.child)
      : selected;
  // The boot reveal only animates the loader away; the selected screen is its
  // child (null while the loader is selected, so the reveal itself stands in).
  return root is AppBootLoaderReveal ? root.child ?? root : root;
}

/// A storage response can be delayed AFTER capturing its value; a dispatched
/// write can likewise be held BEFORE it persists. Neither pause is cancellable.
class _OutgoingStore implements LocalReadDurableStore {
  final inner = SecureLocalReadStore();
  final reached = Completer<void>();
  final release = Completer<void>();
  bool holdRead = false;
  bool holdWrite = false;
  bool failBlocked = false;
  LocalReadGrantState writeState = LocalReadGrantState.blocked;
  bool used = false;

  @override
  Future<String?> read() async {
    final captured = await inner.read();
    if (holdRead && !used) {
      used = true;
      reached.complete();
      await release.future;
    }
    return captured;
  }

  @override
  Future<void> write(String value) async {
    if (failBlocked && LocalReadGrantRecord.tryDecode(value)?.state ==
        LocalReadGrantState.blocked) {
      throw StateError('unexposed commit cleanup refused');
    }
    if (holdWrite && !used &&
        LocalReadGrantRecord.tryDecode(value)?.state ==
            writeState) {
      used = true;
      reached.complete();
      await release.future;
    }
    await inner.write(value);
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late LocalReadAuthority authority;
  late DatabaseAccessBroker coordinator;
  late List<SupabaseClient> clients;

  Future<SupabaseClient> liveSdk(String uid) async {
    final c = await f.clientFor(uid);
    clients.add(c);
    return c;
  }

  setUp(() async {
    await AppSession.instance.debugResetAuthBinding();
    clients = [];
    coordinator = DatabaseAccessBroker.debugUnregistered();
    f = await F2Fixture.create(
      coordinator: coordinator,
      opener: ({location, runMigrations = true, creation = const CreationPolicy.unrestricted()}) =>
          AppDatabase.open(
              location: location, runMigrations: runMigrations, creation: creation),
    );
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
    f.session.denyIncompleteNoticePending.value = false;
  });

  tearDown(() async {
    f.storage.gate = null;
    f.session.configureLocalRead(null);
    await f.session.debugLocalReadIdle;
    await f.session.debugResetAuthBinding();
    await f.dispose();
    for (final c in clients) {
      await c.dispose();
    }
    coordinator.debugDispose();
    f.session.denyIncompleteNoticePending.value = false;
  });

  Future<void> signIn(String uid) async {
    final sdk = await liveSdk(uid);
    await f.session.bindSupabaseAuth(sdk);
    await f.session.setIdentity(
        method: 'google', email: '$uid@example.com', userId: uid);
    await f.session.finishOnboarding(client: sdk);
  }

  /// A NEW process over the same persisted state, with a fresh authority.
  Future<void> coldStart() async {
    await f.restartWithoutLock();
    f.session.debugResetAdmissionState();
    f.session.configureAccountScope(f.host);
    authority = LocalReadAuthority(store: SecureLocalReadStore());
    f.session.configureLocalRead(authority);
  }

  /// A new process' host and authority over the same persisted state, WITHOUT
  /// resetting the session singleton (which is what survives in-process).
  Future<void> reopenHost(LocalReadAuthority next) async {
    await f.restartWithoutLock();
    f.session.configureAccountScope(f.host);
    f.session.configureLocalRead(next);
  }

  void failGrantWrites() {
    f.storage.gate = (op, key) async {
      if (op == 'write' && key == _grantKey) {
        throw StateError('grant write refused');
      }
    };
  }

  LocalReadGrantRecord successor(String uid, String replicaId) =>
      LocalReadGrantRecord(
        state: LocalReadGrantState.committed,
        operationId: 'successor-op',
        uid: uid,
        replicaId: replicaId,
      );

  Future<ReplicaState?> registryState(String uid) async =>
      (await f.registryEntry(uid))?.state;

  /// Account _a with a committed grant, then a new process that restored it
  /// read-only under a fresh startup binding.
  Future<(LocalReadStartupBinding, LocalReadGrantRecord, AccountScope)>
      restoredStartup() async {
    await signIn(_a);
    final origin = (await authority.peekRecord())!;
    expect(origin.state, LocalReadGrantState.committed);
    await coldStart();
    final binding = await f.session.beginLocalReadStartupBinding();
    expect(binding.operationId, origin.operationId);
    expect(
        await f.session.restoreLocalReadAccess(host: f.host, binding: binding),
        isTrue);
    return (binding, origin, f.host.current!);
  }

  // -------------------------------------------------------------- O8-1

  group('O9-4 same-host authority handoff', () {
    test('an independently admitted successor ends the handoff restriction '
        'only after the retired scope is closed', () async {
      final (_, _, oldScope) = await restoredStartup();
      f.session.configureLocalRead(
          LocalReadAuthority(store: SecureLocalReadStore()));
      await signIn(_other);
      expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(f.host.current!.uid, _other);
      expect(f.host.current!.isLocalRead, isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.session.localReadEgressDenied, isFalse,
          reason: 'the closed old handle cannot block independent admission');
      expect(_selectedHome(), isA<AppShell>());
    });

    for (final nullGap in [false, true]) {
      test('${nullGap ? 'null-gap' : 'direct'} replacement reverifies on the '
          'same host instead of permanently refusing its retired scope',
          () async {
        final (_, origin, oldScope) = await restoredStartup();
        final incoming = LocalReadAuthority(store: SecureLocalReadStore());
        if (nullGap) f.session.configureLocalRead(null);
        f.session.configureLocalRead(incoming);
        expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
        expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
        expect(identical(f.host.current, oldScope), isFalse);
        expect(f.host.current!.localReadCapability!.isCurrent, isTrue);
        expect((await incoming.peekRecord())!.operationId, origin.operationId);
      });

      test('${nullGap ? 'null-gap' : 'direct'} replacement stays restrictive '
          'until the retained read-only scope is reverified', () async {
        final (_, origin, oldScope) = await restoredStartup();
        final oldCapability = oldScope.localReadCapability!;
        final egress = TestEgress(seedOn: true)..install();
        expect(await egress.gate.permits(), isTrue,
            reason: 'the otherwise-permitting gate isolates the local-read veto');
        egress.gate.localReadActive = () => f.session.localReadEgressDenied;
        addTearDown(() => CloudEgressGate.instance = CloudEgressGate());
        var notifications = 0;
        void changed() => notifications++;
        f.session.addListener(changed);
        addTearDown(() => f.session.removeListener(changed));
        final incoming = LocalReadAuthority(store: SecureLocalReadStore());
        if (nullGap) {
          f.session.configureLocalRead(null);
          expect(oldCapability.isCurrent, isFalse);
          expect(f.session.localReadEgressDenied, isTrue);
          expect(await egress.gate.permits(), isFalse);
          expect(_selectedHome(), isNot(isA<AppShell>()));
        }
        f.session.configureLocalRead(incoming);
        expect(oldCapability.isCurrent, isFalse);
        expect(f.session.localReadActive, isFalse);
        expect(f.session.localReadEgressDenied, isTrue);
        expect(await egress.gate.permits(), isFalse);
        expect(_selectedHome(), isNot(isA<AppShell>()));
        expect(notifications, greaterThan(0));

        final reached = Completer<void>();
        final release = Completer<void>();
        f.session.debugLocalReadAwaitPoint = (point) async {
          if (point == 'exclusion_drained') {
            reached.complete();
            await release.future;
          }
        };
        addTearDown(() => f.session.debugLocalReadAwaitPoint = null);
        final restore = f.session.restoreLocalReadAccess(host: f.host);
        // Refusal must also finish the scenario instead of leaving a held gate.
        final boundary = await Future.any([
          reached.future.then((_) => true), restore.then((_) => false),
        ]);
        if (boundary) {
          expect(f.session.localReadEgressDenied, isTrue);
          expect(await egress.gate.permits(), isFalse);
          expect(oldScope.database.lifecycleState, DatabaseLifecycleState.closed);
          expect(f.host.current, isNull);
        }
        release.complete();
        expect(await restore, isTrue,
            reason: 'the same host can reverify a legitimate committed grant');
        expect(boundary, isTrue);
        expect(identical(f.host.current, oldScope), isFalse);
        expect(f.session.localReadActive, isTrue);
        expect(f.session.localReadEgressDenied, isTrue);
        expect(f.host.current!.localReadCapability!.isCurrent, isTrue);
        expect(identical(f.host.current!.localReadCapability, oldCapability), isFalse);
        expect(oldCapability.isCurrent, isFalse);
        expect((await incoming.peekRecord())!.operationId, origin.operationId);
        expect(_selectedHome(), isNot(isA<AppShell>()));
      });
    }
  });

  group('O9-5 production issuance cleanup', () {
    Future<LocalReadGrantRecord> failedProductionCleanup() async {
      await signIn(_a);
      final paused = _OutgoingStore()
        ..writeState = LocalReadGrantState.committed
        ..holdWrite = true;
      authority = LocalReadAuthority(store: paused);
      f.session.configureLocalRead(authority);
      final issuing = signIn(_a);
      await paused.reached.future;
      final origin = LocalReadGrantRecord.tryDecode(
          f.storage.data[_grantKey])!;
      f.session.configureLocalRead(null);
      paused.failBlocked = true;
      paused.release.complete();
      await issuing;
      return origin;
    }

    test('production failed cleanup reports a reachable incomplete notice',
        () async {
      final origin = await failedProductionCleanup();
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect(authority.pendingOperationDenials, {origin.operationId: _a});
      expect(f.session.denyIncompleteNoticePending.value, isTrue);
    });

    test('null-gap retry stays incomplete; replacement retries only the '
        'originating operation', () async {
      final origin = await failedProductionCleanup();
      expect(await f.session.retryLocalReadDeny(), isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect((await incoming.peekRecord())!.state, LocalReadGrantState.blocked);
      expect(incoming.pendingOperationDenials, isEmpty);
      expect(incoming.pendingDenialUids, isEmpty);
      expect(origin.uid, _a);
    });

    test('replacement retry preserves an independently stored successor',
        () async {
      final origin = await failedProductionCleanup();
      f.storage.data[_grantKey] = successor(_other, origin.replicaId).encode();
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect((await incoming.peekRecord())!.operationId, 'successor-op');
      expect((await incoming.peekRecord())!.state, LocalReadGrantState.committed);
      expect(incoming.pendingDenialUids, isEmpty);
      expect(incoming.pendingOperationDenials, isEmpty);
    });

    testWidgets('the production cleanup notice remains through null-gap retry '
        'and completes through the real replacement retry', (tester) async {
      await tester.runAsync(failedProductionCleanup);
      await tester.pumpWidget(const MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(body: DenyIncompleteNoticeHost()),
      ));
      expect(find.byKey(const Key('deny_incomplete_notice')), findsOneWidget);
      await tester.tap(find.byKey(const Key('deny_incomplete_retry')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('deny_incomplete_notice')), findsOneWidget);
      expect(f.session.denyIncompleteNoticePending.value, isTrue);
      f.session.configureLocalRead(
          LocalReadAuthority(store: SecureLocalReadStore()));
      final dismissed = Completer<void>();
      void noticeChanged() {
        if (!f.session.denyIncompleteNoticePending.value &&
            !dismissed.isCompleted) {
          dismissed.complete();
        }
      }
      f.session.denyIncompleteNoticePending.addListener(noticeChanged);
      try {
        await tester.tap(find.byKey(const Key('deny_incomplete_retry')));
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (!dismissed.isCompleted && DateTime.now().isBefore(deadline)) {
          await tester.runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 1)));
          await tester.pump();
        }
      } finally {
        f.session.denyIncompleteNoticePending.removeListener(noticeChanged);
      }
      expect(dismissed.isCompleted, isTrue,
          reason: 'await the real retry result and notice completion');
      expect(find.byKey(const Key('deny_incomplete_notice')), findsNothing);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('O9-1 replacement storage ordering', () {
    test('null-gap replacement orders an already-dispatched denial write',
        () async {
      await signIn(_a);
      final paused = _OutgoingStore();
      authority = LocalReadAuthority(store: paused);
      f.session.configureLocalRead(authority);
      final origin = (await authority.peekRecord())!;
      paused.holdWrite = true;
      final deny = authority.revokeOperation(
          operationId: origin.operationId, uid: _a);
      await paused.reached.future;
      f.session.configureLocalRead(null);
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      var prepared = false;
      final next = () async {
        final issue = await incoming.beginIssue(uid: _other,
            replicaId: origin.replicaId);
        prepared = true;
        return incoming.commit(issue, proof: LocalReadIssueProof(
            uid: _other, isCurrent: () => true));
      }();
      await Future<void>(() {});
      final beforeDrain = prepared;
      paused.release.complete();
      await deny;
      final capability = await next;
      expect(beforeDrain, isFalse);
      expect((await incoming.peekRecord())!.operationId, capability.operationId);
      expect(capability.isCurrent, isTrue);
    });

    test('rejected independently-used incoming authority preserves outgoing '
        'scope and capability', () async {
      final (_, _, oldScope) = await restoredStartup();
      final oldCapability = oldScope.localReadCapability!;
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      await incoming.peekRecord();
      expect(() => f.session.configureLocalRead(incoming), throwsStateError);
      expect(oldCapability.isCurrent, isTrue);
      expect(identical(f.host.current, oldScope), isTrue);
      expect(f.session.localReadActive, isTrue);
      expect(f.session.localReadEgressDenied, isTrue);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
    });

    test('failed outgoing commit cleanup retains an exact operation retry '
        'in the replacement', () async {
      final paused = _OutgoingStore();
      authority = LocalReadAuthority(store: paused);
      f.session.configureLocalRead(authority);
      final issue = await authority.beginIssue(uid: _a, replicaId: 'replica-a');
      paused.writeState = LocalReadGrantState.committed;
      paused.holdWrite = true;
      final oldCommit = authority.commit(issue,
          proof: LocalReadIssueProof(uid: _a, isCurrent: () => true))
          .then<Object>((value) => value, onError: (Object error) => error);
      await paused.reached.future;
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      paused.failBlocked = true;
      paused.release.complete();
      expect(await oldCommit, isA<LocalReadGrantException>());
      expect(incoming.pendingOperationDenials, {issue.operationId: _a});
      expect(incoming.pendingDenialUids, isEmpty);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      var opened = false;
      final refused = await incoming.restoreUncoordinatedForTesting(f.store,
          open: (_, __) async {
        opened = true;
        throw StateError('a pending operation cannot open');
      });
      expect(refused.denial, LocalReadRestoreDenial.denialPending);
      expect(opened, isFalse);
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect((await incoming.peekRecord())!.state, LocalReadGrantState.blocked);
      expect(incoming.pendingOperationDenials, isEmpty);
    });

    test('an unexposed outgoing dispatched commit stays denied when no '
        'successor is issued', () async {
      final paused = _OutgoingStore();
      authority = LocalReadAuthority(store: paused);
      f.session.configureLocalRead(authority);
      final issue = await authority.beginIssue(uid: _a, replicaId: 'replica-a');
      paused.writeState = LocalReadGrantState.committed;
      paused.holdWrite = true;
      final oldCommit = authority.commit(issue,
          proof: LocalReadIssueProof(uid: _a, isCurrent: () => true))
          .then<Object>((value) => value, onError: (Object error) => error);
      await paused.reached.future;
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      paused.release.complete();
      expect(await oldCommit, isA<LocalReadGrantException>());
      final stored = (await incoming.peekRecord())!;
      expect(stored.operationId, issue.operationId);
      expect(stored.state, LocalReadGrantState.blocked,
          reason: 'a commit that never exposed authority cannot leave a grant');
      expect(incoming.pendingOperationDenials, isEmpty);
    });

    test('replacement can reverify an independently committed grant through '
        'a reconstructed host', () async {
      final (_, origin, oldScope) = await restoredStartup();
      final oldCapability = oldScope.localReadCapability!;
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      await reopenHost(incoming);
      expect(oldCapability.isCurrent, isFalse);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isTrue);
      expect((await incoming.peekRecord())!.operationId, origin.operationId);
      expect(f.host.current!.localReadCapability!.operationId,
          origin.operationId);
      expect(f.session.localReadActive, isTrue);
    });

    test('an outgoing dispatched commit cannot publish after replacement',
        () async {
      final paused = _OutgoingStore();
      authority = LocalReadAuthority(store: paused);
      f.session.configureLocalRead(authority);
      final issue = await authority.beginIssue(uid: _a, replicaId: 'replica-a');
      paused.writeState = LocalReadGrantState.committed;
      paused.holdWrite = true;
      final oldCommit = authority.commit(issue,
          proof: LocalReadIssueProof(uid: _a, isCurrent: () => true))
          .then<Object>((value) => value, onError: (Object error) => error);
      await paused.reached.future;
      final incoming = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(incoming);
      final next = () async {
        final nextIssue = await incoming.beginIssue(
            uid: _other, replicaId: 'replica-b');
        return incoming.commit(nextIssue,
            proof: LocalReadIssueProof(uid: _other, isCurrent: () => true));
      }();
      await Future<void>(() {});
      paused.release.complete();
      final oldOutcome = await oldCommit;
      final capability = await next;
      expect(oldOutcome, isA<LocalReadGrantException>(),
          reason: 'an outgoing authority cannot expose a new capability');
      expect(capability.isCurrent, isTrue);
      expect((await incoming.peekRecord())!.operationId,
          capability.operationId);
    });

    test('replacement retires an already-issued outgoing capability',
        () async {
      final (_, _, scope) = await restoredStartup();
      final capability = scope.localReadCapability!;
      expect(capability.isCurrent, isTrue);
      f.session.configureLocalRead(
          LocalReadAuthority(store: SecureLocalReadStore()));
      expect(capability.isCurrent, isFalse);
      expect(f.session.localReadActive, isFalse);
    });

    for (final sameUid in [true, false]) {
      for (final heldWrite in [false, true]) {
        test('outgoing ${heldWrite ? 'dispatched write' : 'captured read'} '
            'drains before a ${sameUid ? 'same' : 'different'}-uid successor',
            () async {
          await signIn(_a);
          await coldStart();
          final paused = _OutgoingStore();
          authority = LocalReadAuthority(store: paused);
          f.session.configureLocalRead(authority);
          final binding = await f.session.beginLocalReadStartupBinding();
          final origin = (await authority.peekRecord())!;
          expect(await f.session.restoreLocalReadAccess(
              host: f.host, binding: binding), isTrue);
          final originCapability = f.host.current!.localReadCapability!;
          f.session.debugBeginSuccessorLifecycle();
          paused.holdRead = !heldWrite;
          paused.holdWrite = heldWrite;
          final deny = f.session.denyLocalReadAfterInitializationLoss(
              f.host, binding: binding);
          await paused.reached.future;
          final incoming = LocalReadAuthority(store: SecureLocalReadStore());
          f.session.configureLocalRead(incoming);
          final pendingOnReplacement = incoming.pendingOperationDenials;
          var prepared = false;
          final uid = sameUid ? _a : _other;
          final next = () async {
            final issue = await incoming.beginIssue(
                uid: uid, replicaId: origin.replicaId);
            prepared = true;
            return incoming.commit(issue,
                proof: LocalReadIssueProof(uid: uid, isCurrent: () => true));
          }();
          // A separate event turn lets every already-runnable queue item start.
          // The result is asserted only after both owned producers have ended.
          await Future<void>(() {});
          final preparedBeforeDrain = prepared;
          paused.release.complete();
          await deny;
          final capability = await next;
          final stored = (await incoming.peekRecord())!;
          expect(preparedBeforeDrain, isFalse,
              reason: 'successor mutations wait for outgoing storage work');
          expect(pendingOnReplacement, {origin.operationId: _a});
          expect(stored.operationId, capability.operationId);
          expect(stored.state, LocalReadGrantState.committed);
          expect(stored.uid, uid);
          expect(capability.isCurrent, isTrue);
          expect(originCapability.isCurrent, isFalse);
          expect(incoming.pendingOperationDenials, isEmpty);
          expect(authority.pendingOperationDenials, isEmpty);
          expect(f.session.localReadActive, isFalse);
          expect(f.session.debugLocalReadLocked, isFalse);
          expect(f.session.localReadCleanupIncomplete, isFalse);
          expect(f.session.denyIncompleteNoticePending.value, isFalse);
          expect(await f.session.retryLocalReadDeny(), isTrue);
          expect((await incoming.peekRecord())!.operationId,
              capability.operationId);
        });
      }
    }
  });

  group('O8-1 coherent startup identity', () {
    for (final sameUid in [true, false]) {
      test(
          'a lifecycle that changes while the grant is being read gives the '
          'startup no operation target (${sameUid ? 'same' : 'different'} uid)',
          () async {
        await signIn(_a);
        final origin = (await authority.peekRecord())!;
        await coldStart();
        final hold =
            f.storage.holdOnce((op, key) => op == 'read' && key == _grantKey);
        final pending = f.session.beginLocalReadStartupBinding();
        await hold.reached.future;
        // A successor lifecycle begins and its grant lands while the read is
        // still pending; the read then returns that grant.
        f.session.debugBeginSuccessorLifecycle();
        f.storage.data[_grantKey] =
            successor(sameUid ? _a : _other, origin.replicaId).encode();
        hold.release.complete();
        final binding = await pending;
        expect(binding.operationId, isNull,
            reason: 'a successor grant is never the startup\'s target');
        expect(binding.uid, isNull);

        // A late classification of this startup therefore cannot touch it.
        await f.session
            .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
        final stored = (await authority.peekRecord())!;
        expect(stored.operationId, 'successor-op');
        expect(stored.state, LocalReadGrantState.committed);
        expect(f.session.debugLocalReadLocked, isFalse);
        expect(f.session.localReadCleanupIncomplete, isFalse);
      });
    }

    test('control: an unchanged lifecycle still binds the stored grant',
        () async {
      await signIn(_a);
      final origin = (await authority.peekRecord())!;
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      expect(binding.operationId, origin.operationId);
      expect(binding.uid, _a);
    });
  });

  // -------------------------------------------------------------- O8-2

  group('O8-2 identity at the mutation boundary', () {
    test('registry fallback rechecks after its serialized registry read',
        () async {
      await signIn(_a);
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      f.session.debugBeginSuccessorLifecycle();
      failGrantWrites();
      final hold = f.storage.holdOnce(
          (op, key) => op == 'read' && key == ReplicaStore.registryKey);
      final deny = f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      await hold.reached.future;
      // The fallback passed its caller-side eligibility check, but a newer
      // lifecycle begins while its actual registry mutation is still waiting.
      f.session.debugBeginSuccessorLifecycle();
      hold.release.complete();
      await deny;
      expect(await registryState(_a), ReplicaState.active);
      expect(authority.pendingOperationDenials.values, contains(_a));
      expect(f.session.debugLocalReadLocked, isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
    });

    test('unchanged-lifecycle queued denial cannot overwrite a successor '
        'operation returned by its mutation read', () async {
      await signIn(_a);
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      final origin = (await authority.peekRecord())!;
      expect(await f.session.restoreLocalReadAccess(
          host: f.host, binding: binding), isTrue);
      final hold = f.storage.holdOnce(
          (op, key) => op == 'read' && key == _grantKey);
      final deny = f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      await hold.reached.future;
      f.session.debugBeginSuccessorLifecycle();
      f.storage.data[_grantKey] = successor(_a, origin.replicaId).encode();
      hold.release.complete();
      await deny;
      final stored = (await authority.peekRecord())!;
      expect(stored.operationId, 'successor-op');
      expect(stored.state, LocalReadGrantState.committed);
      expect(authority.pendingDenialUids, isEmpty);
    });

    test(
        'registry fallback that runs after a same-uid successor admission does '
        'not lock the successor\'s replica', () async {
      await signIn(_other);
      await signIn(_a);
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      // An earlier successor lifecycle has begun (so the denial is bound), and
      // the grant can no longer be written.
      f.session.debugBeginSuccessorLifecycle();
      failGrantWrites();
      final hold =
          f.storage.holdOnce((op, key) => op == 'read' && key == _grantKey);
      final deny = f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      await hold.reached.future;
      // Another admission of the SAME uid begins and publishes while the
      // operation denial waits in the authority queue.
      final admit = signIn(_a);
      await _until(() =>
          f.host.current?.uid == _a && !(f.host.current?.isLocalRead ?? true));
      hold.release.complete();
      await deny;
      await admit;
      expect(await registryState(_a), ReplicaState.active,
          reason: 'the fallback lock must not run against the successor');
      final scope = f.host.current!;
      expect(scope.uid, _a);
      expect(scope.isLocalRead, isFalse);
      expect(scope.database.lifecycleState, DatabaseLifecycleState.open);
      expect(f.session.debugLocalReadLocked, isFalse);
      expect(authority.pendingOperationDenials.values, contains(_a),
          reason: 'the unproven denial stays pending');
    });

    test(
        'the host lock queued for the originating scope does not lock a '
        'successor published before the lock\'s turn starts', () async {
      await signIn(_other);
      await signIn(_a);
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      expect(
          await f.session
              .restoreLocalReadAccess(host: f.host, binding: binding),
          isTrue);
      expect(f.host.current!.isLocalRead, isTrue);
      final originating = f.host.current!;
      // A real admission first passes the fence and owns the host turn. Hold
      // its outgoing registry lock before withdrawal, then queue the late
      // denial behind that turn while the originating scope is still current.
      final hold = f.storage.holdOnce(
          (op, key) => op == 'write' && key == ReplicaStore.registryKey);
      final activate = signIn(_other).then<Object?>((_) => null,
          onError: (Object error) => error);
      Future<Object?>? deny;
      try {
        await hold.reached.future.timeout(const Duration(seconds: 5));
        expect(f.host.current, same(originating));
        deny = f.session
            .denyLocalReadAfterInitializationLoss(f.host, binding: binding)
            .then<Object?>((_) => null, onError: (Object error) => error);
        hold.release.complete();
        expect(await activate.timeout(const Duration(seconds: 10)), isNull);
        expect(await deny.timeout(const Duration(seconds: 10)), isNull);
        final scope = f.host.current!;
        expect(scope.uid, _other,
            reason: 'the queued lock must not withdraw the successor');
        expect(scope.isLocalRead, isFalse);
        expect(scope.database.lifecycleState, DatabaseLifecycleState.open);
        expect(await registryState(_other), ReplicaState.active);
        expect(f.session.localReadActive, isFalse);
      } finally {
        if (!hold.release.isCompleted) hold.release.complete();
        expect(await activate.timeout(const Duration(seconds: 10)), isNull);
        if (deny != null) {
          expect(await deny.timeout(const Duration(seconds: 10)), isNull);
        }
      }
    });

    test(
        'unchanged-lifecycle denial: a successor record found by the awaited '
        'lookup is never selected for a uid-wide denial', () async {
      await signIn(_a);
      final origin = (await authority.peekRecord())!;
      await coldStart();
      final binding = await f.session.beginLocalReadStartupBinding();
      // No uid is known synchronously (cold start, nothing published), so the
      // denial looks the stored record up; hold that read.
      final hold =
          f.storage.holdOnce((op, key) => op == 'read' && key == _grantKey);
      final deny = f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      await hold.reached.future;
      f.session.debugBeginSuccessorLifecycle();
      f.storage.data[_grantKey] = successor(_other, origin.replicaId).encode();
      hold.release.complete();
      await deny;
      final stored = (await authority.peekRecord())!;
      expect(stored.operationId, 'successor-op',
          reason: 'the successor grant is untouched');
      expect(stored.state, LocalReadGrantState.committed);
      expect(authority.pendingDenialUids, isEmpty,
          reason: 'no uid-wide denial was registered against the successor');
    });
  });

  // -------------------------------------------------------------- O8-3

  group('O8-3 an incomplete operation denial keeps denying', () {
    test('authority replaced while the denial is pending retains the target '
        'before its result arrives', () async {
      final (binding, origin, _) = await restoredStartup();
      f.session.debugBeginSuccessorLifecycle();
      failGrantWrites();
      final hold = f.storage.holdOnce(
          (op, key) => op == 'read' && key == _grantKey);
      final deny = f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      await hold.reached.future;
      final replacement = LocalReadAuthority(store: SecureLocalReadStore());
      f.session.configureLocalRead(replacement);
      final pendingAtReplacement = replacement.pendingOperationDenials;
      hold.release.complete();
      await deny;
      expect(pendingAtReplacement, {origin.operationId: _a},
          reason: 'replacement refuses the operation immediately');
      expect(replacement.pendingOperationDenials,
          {origin.operationId: _a});
      f.storage.gate = null;
      expect(await f.session.retryLocalReadDeny(), isTrue);
      expect((await replacement.peekRecord())!.state,
          LocalReadGrantState.blocked);
      expect(f.session.localReadCleanupIncomplete, isFalse);
    });

    /// The originating operation's denial fails after the originating
    /// local-read scope was retracted.
    Future<(LocalReadStartupBinding, LocalReadGrantRecord)>
        failedOperationDenial() async {
      final (binding, origin, _) = await restoredStartup();
      f.session.debugBeginSuccessorLifecycle();
      failGrantWrites();
      await f.session
          .denyLocalReadAfterInitializationLoss(f.host, binding: binding);
      f.storage.gate = null;
      return (binding, origin);
    }

    test('the failure is reported through the notice state, not ignored',
        () async {
      final (_, origin) = await failedOperationDenial();
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect(f.session.denyIncompleteNoticePending.value, isTrue);
      expect(authority.pendingOperationDenials,
          {origin.operationId: _a});
      expect((await authority.peekRecord())!.state,
          LocalReadGrantState.committed,
          reason: 'nothing durable was written');
      expect(f.session.debugLocalReadLocked, isFalse,
          reason: 'an operation denial is never a global block');
    });

    test('a later restoration of the same operation is refused', () async {
      final (_, origin) = await failedOperationDenial();
      // The registry no longer masks the grant (a later activation made the
      // replica active again); only the pending operation denial can refuse.
      await f.store.setState(_a, ReplicaState.active);
      await reopenHost(authority);
      expect(f.host.current, isNull);
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.host.current?.isLocalRead ?? false, isFalse);
      expect(authority.pendingOperationDenials.keys, contains(origin.operationId));
    });

    test('the authority itself refuses a pending operation before opening',
        () async {
      await failedOperationDenial();
      var opens = 0;
      final restored = await authority.restoreUncoordinatedForTesting(f.store,
          open: (uid, replicaId) async {
        opens++;
        throw StateError('a denied operation must never open');
      });
      expect(restored.denial, LocalReadRestoreDenial.denialPending);
      expect(opens, 0);
    });

    test('denial during a pending authority restore closes its candidate '
        'before returning any capability', () async {
      final (_, origin, _) = await restoredStartup();
      final reached = Completer<void>();
      final release = Completer<void>();
      AppDatabase? candidate;
      final restore = authority.restoreUncoordinatedForTesting(f.store,
          open: (uid, replicaId) async {
        final opened = await f.store.openReadOnlyReplicaUncoordinatedForTesting(
            uid, replicaId: replicaId);
        candidate = opened.database;
        reached.complete();
        await release.future;
        return opened;
      });
      await reached.future;
      failGrantWrites();
      final result = await authority.revokeOperation(
          operationId: origin.operationId, uid: _a);
      release.complete();
      expect(result, LocalReadRevocation.incomplete);
      final restored = await restore;
      expect(restored.isGranted, isFalse);
      expect(candidate!.lifecycleState, DatabaseLifecycleState.closed);
      expect(authority.pendingOperationDenials, {origin.operationId: _a});
    });

    test('a pending originating denial allows an independent successor '
        'operation to restore', () async {
      final (_, origin) = await failedOperationDenial();
      await f.store.setState(_a, ReplicaState.active);
      f.storage.data[_grantKey] = successor(_a, origin.replicaId).encode();
      final restored = await authority.restoreUncoordinatedForTesting(f.store,
          open: (uid, replicaId) =>
              f.store.openReadOnlyReplicaUncoordinatedForTesting(
                  uid, replicaId: replicaId));
      expect(restored.isGranted, isTrue);
      expect(restored.capability!.operationId, 'successor-op');
      expect(authority.pendingOperationDenials, {origin.operationId: _a});
      await restored.replica!.database.close();
    });

    test('authority replacement keeps refusing and keeps the retry target',
        () async {
      final (_, origin) = await failedOperationDenial();
      await f.store.setState(_a, ReplicaState.active);
      final replacement = LocalReadAuthority(store: SecureLocalReadStore());
      await reopenHost(replacement);
      expect(f.host.current, isNull);
      expect(replacement.pendingOperationDenials,
          {origin.operationId: _a},
          reason: 'the outstanding denial survives a supported replacement');
      expect(await f.session.restoreLocalReadAccess(host: f.host), isFalse);
      expect(f.session.localReadActive, isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      // The retry finishes exactly that operation's denial.
      expect(await f.session.retryLocalReadDeny(), isTrue);
      final stored = (await replacement.peekRecord())!;
      expect(stored.state, LocalReadGrantState.blocked);
      expect(replacement.pendingOperationDenials, isEmpty);
      expect(f.session.localReadCleanupIncomplete, isFalse);
      expect(f.session.debugLocalReadLocked, isFalse);
    });

    test('retry completes the operation denial and stays operation-specific',
        () async {
      final (_, origin) = await failedOperationDenial();
      expect(await f.session.retryLocalReadDeny(), isTrue);
      final stored = (await authority.peekRecord())!;
      expect(stored.state, LocalReadGrantState.blocked);
      expect(stored.operationId, isNot(origin.operationId));
      expect(authority.pendingOperationDenials, isEmpty);
      expect(authority.pendingDenialUids, isEmpty);
      expect(f.session.localReadCleanupIncomplete, isFalse);
    });

    test('a retry that still fails stays incomplete and keeps the target',
        () async {
      final (_, origin) = await failedOperationDenial();
      failGrantWrites();
      expect(await f.session.retryLocalReadDeny(), isFalse);
      expect(f.session.localReadCleanupIncomplete, isTrue);
      expect(authority.pendingOperationDenials.keys, [origin.operationId]);
      expect(authority.pendingDenialUids, isEmpty);
    });

    test(
        'retry with a successor grant already stored never revokes the '
        'successor', () async {
      final (_, origin) = await failedOperationDenial();
      f.storage.data[_grantKey] = successor(_other, origin.replicaId).encode();
      final registryBefore = await registryState(_other);
      expect(await f.session.retryLocalReadDeny(), isTrue);
      final stored = (await authority.peekRecord())!;
      expect(stored.operationId, 'successor-op');
      expect(stored.state, LocalReadGrantState.committed,
          reason: 'the successor\'s grant is preserved');
      expect(authority.pendingOperationDenials, isEmpty);
      expect(authority.pendingDenialUids, isEmpty);
      expect(await registryState(_other), registryBefore);
      expect(f.session.debugLocalReadLocked, isFalse);
      expect(f.session.localReadCleanupIncomplete, isFalse);
    });

    test(
        'retry with a same-uid successor grant already stored never revokes '
        'the successor', () async {
      final (_, origin) = await failedOperationDenial();
      f.storage.data[_grantKey] = successor(_a, origin.replicaId).encode();
      expect(await f.session.retryLocalReadDeny(), isTrue);
      final stored = (await authority.peekRecord())!;
      expect(stored.operationId, 'successor-op');
      expect(stored.state, LocalReadGrantState.committed);
      expect(authority.pendingDenialUids, isEmpty);
    });
  });
}
