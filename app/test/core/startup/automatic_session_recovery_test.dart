import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_record.dart';
import 'package:money_companion/core/auth/session_store.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/startup/automatic_session_recovery.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, Session;

import '../../harness/egress_test_support.dart';
import '../auth/auth_coordinator_test.dart'
    show ChannelScript, FakeChannel, FakeSdk;
import '../auth/session_fixtures.dart';
import '../auth/store_fakes.dart';

/// ASR v7.2 WP7/WP9: the orchestrator (§8–§11) over the real coordinator and
/// gate, with fakes for the SDK, transport, native evidence, capture lane and
/// session host. Every identifier here is synthetic.
const _uid = 'uid-a';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class FakeNative implements AsrNativePort {
  FakeNative(this.lifecycle);
  int lifecycle;
  int counter = 10;
  RecoveryEvidenceKind kind = RecoveryEvidenceKind.expiryEvidence;

  /// The agreed record's state native reports (null: no record, i.e. native
  /// could not prove the layers readable and agreeing), and whether the active
  /// owner was proven.
  String? state = 'OFF';
  bool ownerProven = true;
  bool mintRefused = false;
  int mints = 0;

  NativeExpiryEvidence get evidence => NativeExpiryEvidence(
      evidenceId: 'ev-1',
      ownerGeneration: 4,
      ownerEpoch: 2,
      sessionLifecycle: lifecycle);

  /// Simulates another protected writer right after P_elig's inspection.
  bool bumpAfterInspect = false;
  Completer<void>? inspectionGate;

  @override
  Future<RecoveryEvidenceSnapshot?> inspect(String owner) async {
    await inspectionGate?.future;
    final s = _snapshot();
    if (bumpAfterInspect) counter++;
    return s;
  }

  RecoveryEvidenceSnapshot _snapshot() => RecoveryEvidenceSnapshot(
        kind: kind,
        ownerGeneration: ownerProven ? 4 : null,
        ownerEpoch: ownerProven ? 2 : null,
        state: kind == RecoveryEvidenceKind.liveOn ? 'ON' : state,
        mutationCounter: counter,
        transitionGeneration: 3,
        reservedVersion: 1,
        expiryEvidence:
            kind == RecoveryEvidenceKind.expiryEvidence ? evidence : null,
      );

  @override
  Future<bool> confirm(int expectedCounter) async => expectedCounter == counter;

  @override
  Future<CloudEgressEnableResult?> mintLiveOn(String owner,
      RecoveryEvidenceSnapshot snapshot, int sessionLifecycle) async {
    mints++;
    if (mintRefused || snapshot.mutationCounter != counter) return null;
    counter++;
    return CloudEgressEnableResult(
      operation: 'mintExpiry',
      status: CloudEgressTransitionStatus.done,
      barrier: const [],
      egress: const [],
      expiryEvidence: NativeExpiryEvidence(
          evidenceId: 'ev-minted',
          ownerGeneration: 4,
          ownerEpoch: 2,
          sessionLifecycle: sessionLifecycle),
      mutationCounter: counter,
    );
  }
}

class FakeCapture implements AsrCapturePort {
  FakeCapture(this.native);
  final FakeNative native;
  bool dartOn = true;
  bool consent = true;
  bool refusePrepare = false;
  String finishResult = 'confirmed';
  Completer<void>? finishGate;
  bool clearOk = true;
  bool compensateOk = true;
  bool retireOrphanOk = true;

  /// Runs inside clearDart (e.g. a loss during the awaited clearance).
  void Function()? duringClear;
  final calls = <String>[];
  AsrPreparedSuccessor? recovered;
  bool recoverUnreadable = false;
  String inspectResult = 'confirmed';

  @override
  Future<bool> dartEgressOn(String owner) async => dartOn;

  /// Session-only: both Dart layers verified OFF (or never written).
  bool dartOff = false;
  @override
  Future<bool> dartEgressOff(String owner) async => dartOff;
  @override
  Future<bool> consentAccepted(String owner) async => consent;

  @override
  Future<AsrPreparedSuccessor?> prepare(AsrAdoptionContext ctx) async {
    calls.add('prepare');
    if (refusePrepare) return null;
    // SE2 + SE3 each advance native by one own receipt.
    native.counter += 2;
    ctx.evidence.counter = native.counter;
    return AsrPreparedSuccessor(
        successorGeneration: ctx.successorGeneration!,
        ownerEpoch: ctx.successorOwnerEpoch!,
        pendingOpId: 'op-successor');
  }

  @override
  Future<String> finish(AsrPreparedSuccessor p) async {
    calls.add('finish');
    await finishGate?.future;
    return finishResult;
  }

  @override
  Future<bool> clearDart(AsrPreparedSuccessor p) async {
    calls.add('clearDart');
    duringClear?.call();
    return clearOk;
  }

  @override
  Future<bool> compensate(AsrPreparedSuccessor p,
      {required bool finished}) async {
    calls.add(finished ? 'retire' : 'compensate');
    return compensateOk;
  }

  @override
  Future<AsrPreparedSuccessor?> recover(String owner, SuccessorRecord s) async {
    calls.add('recover');
    if (recoverUnreadable) throw StateError('unreadable');
    return recovered;
  }

  @override
  Future<bool> retireOrphan(String owner, SuccessorRecord s) async {
    calls.add('retireOrphan');
    return retireOrphanOk;
  }

  @override
  Future<String> inspect(AsrPreparedSuccessor p) async {
    calls.add('inspect');
    return inspectResult;
  }

  @override
  Future<void> reconcile(String owner) async => calls.add('reconcile');
}

class FakeHost implements AsrSessionHost {
  FakeHost(this.native, this.gate);
  final FakeNative native;
  final CloudEgressGate gate;
  bool isResumed = true;
  String? owner = _uid;
  String? eligibility;
  String? process;
  bool failed = false;
  int adopts = 0;

  /// Hooks run inside adoption (after SE1, before publication).
  void Function(AsrAdoptionContext ctx)? duringAdoption;

  @override
  bool get resumed => isResumed;
  @override
  bool get foreground => isResumed;
  @override
  String? get localReadOwner => owner;
  @override
  Future<String?> eligibilityDenial(String o) async => eligibility;
  @override
  String? processDenial(String o, {required bool adopting}) => process;

  @override
  Future<AsrAdoptResult> adopt(AsrAdoptionContext ctx) async {
    adopts++;
    if (!ctx.mayProceed()) return AsrAdoptResult.notWithdrawn;
    // Local read is withdrawn; the writable scope's initialization is the
    // op's own transition, attributed explicitly (§11.2).
    owner = null;
    gate.noteCause(EpochCause.scopeInit, authority: ctx.authority);
    // SE1: the successor publication advances native by one own receipt.
    native.counter++;
    ctx
      ..successorGeneration = 5
      ..successorOwnerEpoch = 2;
    ctx.evidence.counter = native.counter;
    duringAdoption?.call(ctx);
    if (!await ctx.beforePublication()) {
      return AsrAdoptResult.failedAfterWithdrawal;
    }
    ctx.published = true;
    return AsrAdoptResult.published;
  }

  @override
  Future<void> failAfterWithdrawal(String o) async => failed = true;
}

void main() {
  final origin = Uri.parse('https://example.supabase.co');
  late Directory dir;
  late FakeKeychain keychain;
  late TestEgress egress;
  late SessionStore store;
  late FakeSdk sdk;
  late ChannelScript script;
  late AuthCoordinator coord;
  late FakeNative native;
  late FakeCapture capture;
  late FakeHost host;
  late AutomaticSessionRecovery asr;
  late List<SessionRecord> writes;
  var wallSkew = Duration.zero;

  Future<SessionRecord> seed(
      {int expIn = -100,
      AdmissionDisposition admission = AdmissionDisposition.ordinary,
      bool inSdk = true,
      AdoptionRecord? adoption}) async {
    final r = SessionRecord(
      ns: store.ns,
      installId: store.installId!,
      seq: store.nextSeqFloor + 1,
      lifecycle: store.lifecycleFloor + 1,
      kind: RecordKind.session,
      owner: _uid,
      session: canonicalSession(sessionJson(
          uid: _uid, exp: _now() + expIn, refreshToken: 'refresh-1')),
      admission: admission,
      adoption: adoption,
    );
    expect(await store.write(r), WriteOutcome.committed);
    writes.clear();
    if (inSdk) {
      sdk.current = r.sdkSession;
      coord.endInit(served: r);
    } else {
      coord.endInit();
    }
    native.lifecycle = r.lifecycle;
    return r;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('asr_orch_');
    keychain = FakeKeychain();
    egress = TestEgress(seedOn: true).install();
    store = SessionStore(
      keychain: keychain,
      files: SessionFiles(dir),
      origin: origin,
      legacy: FakeLegacy(),
      localInstallDataPresent: () async => true,
    );
    await store.load();
    sdk = FakeSdk();
    script = ChannelScript();
    writes = [];
    wallSkew = Duration.zero;
    coord = AuthCoordinator(
        wallClock: () => DateTime.now().add(wallSkew),
        store: store,
        gate: egress.gate,
        channelFactory: () => FakeChannel(script))
      ..attach(sdk);
    keychain.onWrite = (v) => writes.add(SessionRecord.decode(v));
    native = FakeNative(1);
    capture = FakeCapture(native);
    host = FakeHost(native, egress.gate);
    // Bootstrap wires this to the session: local read until adoption withdraws it.
    egress.gate.localReadActive = () => host.owner != null;
    asr = AutomaticSessionRecovery(
        coordinator: coord,
        gate: egress.gate,
        host: host,
        capture: capture,
        native: native);
  });

  tearDown(() async {
    asr.dispose();
    AutomaticSessionRecovery.recoveryTimedOut.value = false;
    coord.dispose();
    await dir.delete(recursive: true);
  });

  void expectReleased() {
    expect(coord.asrExclusion, isNull);
    expect(egress.gate.holdActive, isFalse);
    expect(coord.refreshing, isFalse);
  }

  group('recovery (§11.2 order)', () {
    test(
        'expired token + valid refresh credential + evidence → normal mode '
        '(acceptance criterion)', () async {
      await seed();
      expect(await asr.run(), AsrOutcome.recovered);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.ordinary);
      expect(c.adoption, isNull);
      expect(c.sdkSession!.refreshToken, 'refresh-2');
      expect(sdk.current!.refreshToken, 'refresh-2');
      expect(coord.sdkBaseline, c.digest);
      expect(coord.automaticAdmissionDenial(), isNull);
      expect(script.sentTokens, ['refresh-1']);
      // Durable order: commit (requiresAdoption) → pending → finalizing
      // (ordinary) → dispatched → confirmed → complete.
      final shapes = [
        for (final w in writes.skipWhile((w) => w.refreshOp != null))
          (w.admission, w.adoption?.state, w.adoption?.successor?.finish)
      ];
      expect(shapes, [
        (AdmissionDisposition.requiresAdoption, null, null),
        (AdmissionDisposition.requiresAdoption, AdoptionState.pending, null),
        (
          AdmissionDisposition.ordinary,
          AdoptionState.finalizing,
          FinishState.awaiting
        ),
        (
          AdmissionDisposition.ordinary,
          AdoptionState.finalizing,
          FinishState.dispatched
        ),
        (
          AdmissionDisposition.ordinary,
          AdoptionState.finalizing,
          FinishState.confirmed
        ),
        (AdmissionDisposition.ordinary, null, null),
      ]);
      final successor = writes
          .firstWhere((w) => w.adoption?.successor != null)
          .adoption!
          .successor!;
      expect(successor.generation, 5);
      expect(successor.evidenceId, 'ev-1');
      expect(successor.pendingOpId, 'op-successor');
      expect(capture.calls, ['prepare', 'finish', 'clearDart', 'reconcile']);
      expectReleased();
    });

    test('the cold-start ON branch mints evidence first (E2-b)', () async {
      await seed();
      native.kind = RecoveryEvidenceKind.liveOn;
      expect(await asr.run(), AsrOutcome.recovered);
      expect(native.mints, 1);
      final s = store.committed;
      expect(s!.admission, AdmissionDisposition.ordinary);
    });

    test('a refused mint stops before anything is written or sent', () async {
      await seed();
      native
        ..kind = RecoveryEvidenceKind.liveOn
        ..mintRefused = true;
      expect(await asr.run(), AsrOutcome.skipped);
      expect(writes, isEmpty);
      expect(script.opens, 0);
    });

    test(
        'receipt-only continuation: a fresh requiresAdoption record is adopted '
        'without network', () async {
      await seed(
          expIn: 3600,
          admission: AdmissionDisposition.requiresAdoption,
          inSdk: false);
      expect(await asr.run(), AsrOutcome.recovered);
      expect(script.opens, 0);
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
      expectReleased();
    });

    test('own transitions during adoption are not foreign', () async {
      await seed();
      host.duringAdoption = (ctx) => egress.gate
          .noteCause(EpochCause.captureTransition, authority: ctx.authority);
      // explicitly attributed to the op: its own cause.
      expect(await asr.run(), AsrOutcome.recovered);
    });

    test('B4: a cause from a microtask scheduled by adoption is foreign',
        () async {
      await seed();
      host.duringAdoption = (_) => scheduleMicrotask(
          () => egress.gate.noteCause(EpochCause.captureTransition));
      expect(await asr.run(), AsrOutcome.signInRequired);
      expect(asr.lastStop, 'failed_after_withdrawal');
      expectReleased();
    });

    test('single flight: a second trigger while running is skipped', () async {
      await seed();
      script.holdResponse = Completer<void>();
      final first = asr.run();
      await pumpEventQueue();
      expect(await asr.run(), AsrOutcome.skipped);
      script.holdResponse!.complete();
      expect(await first, AsrOutcome.recovered);
    });
  });

  // Owner decision (2026-10-29): with Cloud OFF the session alone recovers.
  group('session-only recovery (Cloud OFF)', () {
    void cloudOff() {
      capture
        ..dartOn = false
        ..dartOff = true
        ..consent = false;
      native.kind = RecoveryEvidenceKind.none;
    }

    test(
        'expired token + valid refresh credential + Cloud OFF → normal mode, '
        'no successor and no Cloud transition', () async {
      await seed();
      cloudOff();
      expect(await asr.run(), AsrOutcome.recovered);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.ordinary);
      expect(c.adoption, isNull);
      expect(sdk.current!.refreshToken, 'refresh-2');
      expect(coord.automaticAdmissionDenial(), isNull);
      // Only the token exchange left the device.
      expect(script.sentTokens, ['refresh-1']);
      expect(native.mints, 0);
      // No SE2–SE5, no capture reconciliation: Cloud is untouched.
      expect(capture.calls, isEmpty);
      final shapes = [
        for (final w in writes.skipWhile((w) => w.refreshOp != null))
          (w.admission, w.adoption?.state, w.adoption?.successor)
      ];
      expect(shapes, [
        (AdmissionDisposition.requiresAdoption, null, null),
        (AdmissionDisposition.requiresAdoption, AdoptionState.pending, null),
        (AdmissionDisposition.ordinary, AdoptionState.finalizing, null),
        (AdmissionDisposition.ordinary, null, null),
      ]);
      expectReleased();
    });

    test('expiry evidence left from an earlier ON lifetime is not consumed',
        () async {
      await seed();
      cloudOff();
      native.kind = RecoveryEvidenceKind.expiryEvidence;
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, isEmpty);
      expect(native.mints, 0);
    });

    Future<void> expectDenied(void Function() arrange) async {
      await seed();
      cloudOff();
      arrange();
      expect(await asr.run(), AsrOutcome.skipped);
      expect(writes, isEmpty);
      expect(script.opens, 0);
      expect(host.adopts, 0);
      expect(native.mints, 0);
      expectReleased();
    }

    // L2 (2026-11-14): the Cloud state no longer stops the session-only
    // recovery; it recovers the session alone and leaves Cloud untouched.
    Future<void> expectSessionOnly(void Function() arrange) async {
      await seed();
      cloudOff();
      arrange();
      expect(await asr.run(), AsrOutcome.recovered);
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
      expect(script.sentTokens, ['refresh-1']);
      expect(capture.calls, isEmpty);
      expect(native.mints, 0);
      expectReleased();
    }

    test('L2: native ON while Dart is OFF recovers the session only',
        () => expectSessionOnly(() => native.kind = RecoveryEvidenceKind.liveOn));
    test('L2: native none without a record recovers the session only',
        () => expectSessionOnly(() => native.state = null));
    test('L2: a stale native ON that is not liveOn recovers the session only',
        () => expectSessionOnly(() => native.state = 'ON'));
    test('L2: a native DISABLING record recovers the session only',
        () => expectSessionOnly(() => native.state = 'DISABLING'));
    test(
        'L2: Dart not verified OFF (DISABLING, mixed, uncertain) with the '
        'saved choice not accepted recovers the session only',
        () => expectSessionOnly(() => capture.dartOff = false));
    // A Cloud the user's saved choice keeps ON is never restricted by
    // recovery.
    test('Dart not verified ON or OFF while the saved choice is ON: denied, '
        'Cloud untouched',
        () => expectDenied(() => capture
          ..dartOff = false
          ..consent = true));
    test('the diagnostic names the Dart layer state', () async {
      await expectDenied(() => capture
        ..dartOff = false
        ..consent = true);
      expect(AutomaticSessionRecovery.diagnostic.value, startsWith('cloud:'));
    });
    test('native none for an unproven owner or barrier denies',
        () => expectDenied(() => native.ownerProven = false));
    test('every other P_elig denial still applies',
        () => expectDenied(() => host.eligibility = 'pending'));
    test('process denial (frozen, hold, terminal…) still applies',
        () => expectDenied(() => host.process = 'frozen'));
    test('in-process §7.7 bar still applies',
        () => expectDenied(coord.blockAutoAdmission));
    // Beta 1 diagnostic: the failed check, as constants only.
    test('the diagnostic names a native denial', () async {
      await expectDenied(() => native.ownerProven = false);
      expect(AutomaticSessionRecovery.diagnostic.value,
          allOf(startsWith('native_evidence:'), endsWith('/no_owner')));
    });
    test('the diagnostic names an eligibility denial', () async {
      await expectDenied(() => host.eligibility = 'pending');
      expect(AutomaticSessionRecovery.diagnostic.value, 'elig:pending');
    });

    test('a native write since inspection denies at P_admit', () async {
      await seed();
      cloudOff();
      native.bumpAfterInspect = true;
      expect(await asr.run(), AsrOutcome.stayedLocalRead);
      expect(script.opens, 0);
      expect(host.adopts, 0);
      expectReleased();
    });

    test('a foreign cause during adoption is a failure after withdrawal',
        () async {
      await seed();
      cloudOff();
      host.duringAdoption =
          (_) => egress.gate.noteCause(EpochCause.captureTransition);
      expect(await asr.run(), AsrOutcome.signInRequired);
      expect(host.failed, isTrue);
      expect(capture.calls, isEmpty);
      expectReleased();
    });

    test('a restart in finalizing with no successor completes it', () async {
      await seed(
          expIn: 3600,
          adoption: const AdoptionRecord(
              state: AdoptionState.finalizing, lifecycle: 0, opId: 'op-x'));
      expect(asr.unsettledFinalizationOwner, _uid);
      expect(await asr.reconcileSuccessorFinalization(_uid), isTrue);
      expect(store.committed!.adoption, isNull);
      expect(capture.calls, isEmpty);
    });
  });

  group('P_elig denies without writing or sending (§9.2)', () {
    Future<void> expectSkipped(
        void Function() arrange, AsrOutcome outcome) async {
      await seed();
      arrange();
      expect(await asr.run(), outcome);
      expect(writes, isEmpty);
      expect(script.opens, 0);
      expect(host.adopts, 0);
      expectReleased();
    }

    test('background (E9)',
        () => expectSkipped(() => host.isResumed = false, AsrOutcome.skipped));
    test('not in local read',
        () => expectSkipped(() => host.owner = null, AsrOutcome.skipped));
    test('E3–E11 denial',
        () => expectSkipped(() => host.eligibility = 'x', AsrOutcome.skipped));
    test('Cloud OFF in Dart (E2)',
        () => expectSkipped(() => capture.dartOn = false, AsrOutcome.skipped));
    test('consent not accepted (E4)',
        () => expectSkipped(() => capture.consent = false, AsrOutcome.skipped));
    test(
        'no native evidence (decision d: expiry only)',
        () => expectSkipped(
            () => native.kind = RecoveryEvidenceKind.none, AsrOutcome.skipped));
    test('evidence of another lifecycle', () async {
      await expectSkipped(() => native.lifecycle = 99, AsrOutcome.skipped);
    });
    test('process flag (E8)',
        () => expectSkipped(() => host.process = 'x', AsrOutcome.skipped));
    test('in-process §7.7 bar', () async {
      await expectSkipped(coord.blockAutoAdmission, AsrOutcome.skipped);
    });
  });

  test('choosing explicit sign-in cancels a scheduled automatic retry', () async {
    await seed();
    script.openError = const SocketException('synthetic offline');
    asr.trigger();
    await asr.quiesced();
    await pumpEventQueue();
    expect(script.opens, 1);
    expect(asr.lastStop, 'refresh:connect');
    asr.yieldToExplicitAttempt();
    await Future<void>.delayed(const Duration(milliseconds: 2200));
    expect(script.opens, 1,
        reason: 'the backoff must not take the user away from explicit sign-in');
    expect(AutomaticSessionRecovery.restoringSession.value, isFalse);
    expectReleased();
  });

  test('a stalled Cloud finalization does not hide an already admitted home', () async {
    await seed();
    final finish = Completer<void>();
    capture.finishGate = finish;
    final run = asr.run();
    try {
      await pumpEventQueue(times: 40);
      expect(capture.calls, contains('finish'));
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
      expect(coord.asrExclusion, isNull);
      expect(AutomaticSessionRecovery.restoringSession.value, isFalse,
          reason: 'the verified session and scope are usable before Cloud cleanup finishes');
      expect(asr.running, isTrue,
          reason: 'cleanup ownership remains held until the operation really ends');
    } finally {
      finish.complete();
      await run;
    }
  });

  test('stalled native inspection ends the loader without releasing operation custody', () async {
    await seed();
    asr.dispose();
    asr = AutomaticSessionRecovery(
        coordinator: coord, gate: egress.gate, host: host, capture: capture,
        native: native, presentationDeadline: const Duration(milliseconds: 40));
    final hold = native.inspectionGate = Completer<void>();
    final attempt = asr.run();
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(AutomaticSessionRecovery.restoringSession.value, isFalse);
      expect(AutomaticSessionRecovery.recoveryTimedOut.value, isTrue);
      expect(asr.running, isTrue);
      expect(host.adopts, 0);
      hold.complete();
      await attempt;
      expect(host.adopts, 0, reason: 'late evidence cannot admit after the UI deadline');
    } finally {
      if (!hold.isCompleted) hold.complete();
      await attempt;
    }
  });

  test('temporarily missing native evidence is retried without another resume', () async {
    await seed();
    native.kind = RecoveryEvidenceKind.none;
    asr.trigger();
    await asr.quiesced();
    expect(asr.lastStop, 'native_evidence');
    native.kind = RecoveryEvidenceKind.expiryEvidence;
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    await asr.quiesced();
    expect(asr.lastStop, 'recovered');
    expect(host.adopts, 1);
  });

  test('ordinary resume without local read does not cover the current page', () async {
    await seed();
    host.owner = null;
    final changes = <bool>[];
    void observe() => changes.add(AutomaticSessionRecovery.restoringSession.value);
    AutomaticSessionRecovery.restoringSession.addListener(observe);
    try {
      expect(await asr.run(), AsrOutcome.skipped);
      expect(changes, isEmpty);
    } finally {
      AutomaticSessionRecovery.restoringSession.removeListener(observe);
    }
  });

  group('cancellation before acceptance (decision a, §11.3)', () {
    test('an explicit attempt during the request discards the response',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      expect(script.sentTokens, ['refresh-1']);
      coord.registerAttemptIntent();
      egress.gate.noteCause(EpochCause.explicitAttempt);
      asr.yieldToExplicitAttempt();
      script.holdResponse!.complete();
      expect(await run, AsrOutcome.stayedLocalRead);
      final c = store.committed!;
      expect(c.sdkSession!.refreshToken, 'refresh-1');
      expect(c.adoption, isNull);
      expect(host.adopts, 0);
      expectReleased();
    });

    test('a native protected write since inspection denies at P_admit',
        () async {
      await seed();
      // The counter moves (another writer) after P_elig read it.
      native.bumpAfterInspect = true;
      expect(await asr.run(), AsrOutcome.stayedLocalRead);
      expect(asr.lastStop, 'refresh:pre_admit');
      expect(script.sentTokens, isEmpty);
      expectReleased();
    });

    test('a suspension past the deadline (wall clock) discards the response',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      expect(script.sentTokens, ['refresh-1']);
      // The monotonic clock and timer did not advance while suspended.
      wallSkew = const Duration(seconds: 6);
      script.holdResponse!.complete();
      expect(await run, AsrOutcome.stayedLocalRead);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-1');
      expect(host.adopts, 0);
      expectReleased();
    });

    test('a wall clock that went backwards also discards the response',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      wallSkew = const Duration(seconds: -2);
      script.holdResponse!.complete();
      expect(await run, AsrOutcome.stayedLocalRead);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-1');
    });

    test('backgrounding cancels the running op', () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      host.isResumed = false;
      asr.onBackground();
      expect(await run, AsrOutcome.stayedLocalRead);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-1');
      expectReleased();
    });

    test('B5: a background blip resumed before the response still discards it',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      host.isResumed = false;
      asr.onBackground();
      host.isResumed = true; // resumed again before the response arrives
      script.holdResponse!.complete();
      expect(await run, AsrOutcome.stayedLocalRead);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-1');
      expectReleased();
    });

    test('B5: P_accept requires the foreground even without a lifecycle event',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final run = asr.run();
      await pumpEventQueue();
      host.isResumed = false; // no onBackground: acceptance itself checks
      script.holdResponse!.complete();
      expect(await run, AsrOutcome.stayedLocalRead);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-1');
      expectReleased();
    });

    test('B5: background then resume during adoption never continues it',
        () async {
      await seed();
      host.duringAdoption = (_) {
        host.isResumed = false;
        asr.onBackground();
        host.isResumed = true;
      };
      expect(await asr.run(), AsrOutcome.signInRequired);
      expect(asr.lastStop, 'failed_after_withdrawal');
      expect(store.committed!.adoption?.state, AdoptionState.failed);
      expectReleased();
    });
  });

  group('failure after withdrawal (§11.4, decision c)', () {
    test('SE2/SE3 refused → terminal deny, sign-in, AdoptionFailed, released',
        () async {
      await seed();
      capture.refusePrepare = true;
      expect(await asr.run(), AsrOutcome.signInRequired);
      expect(egress.gate.terminalDenied, isTrue);
      expect(host.failed, isTrue);
      final c = store.committed!;
      expect(c.adoption?.state, AdoptionState.failed);
      expect(c.admission, AdmissionDisposition.requiresAdoption);
      expect(coord.automaticAdmissionDenial(), 'requires_adoption');
      expectReleased();
      // The failed record bars a later ASR attempt too (§7.7).
      host.owner = _uid;
      expect(await asr.run(), AsrOutcome.skipped);
      expect(host.adopts, 1);
    });

    test('a foreign POLICY cause during adoption aborts publication', () async {
      await seed();
      // Not attributed to the op: e.g. the user turned Cloud OFF.
      host.duringAdoption =
          (_) => egress.gate.noteCause(EpochCause.cloudDisable);
      expect(await asr.run(), AsrOutcome.signInRequired);
      expect(store.committed!.adoption?.state, AdoptionState.failed);
      // Refused before SE2: nothing was prepared, so nothing to undo.
      expect(capture.calls, isEmpty);
      expect(asr.lastStop, 'failed_after_withdrawal');
      expectReleased();
    });

    test('a removal intent during adoption stops it', () async {
      await seed();
      host.duringAdoption = (_) => coord.beginRemovalIntent();
      expect(await asr.run(), AsrOutcome.signInRequired);
      expectReleased();
    });

    test('AdoptionPending not confirmed → never withdrawn, safe local read',
        () async {
      await seed();
      var writesSeen = 0;
      keychain.onWrite = (v) {
        writes.add(SessionRecord.decode(v));
        // reserve, mark, commit → the next write (pending) fails.
        if (++writesSeen == 3) keychain.failNextWrite = true;
      };
      expect(await asr.run(), AsrOutcome.stayedLocalRead);
      expect(host.adopts, 0);
      expect(egress.gate.terminalDenied, isFalse);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.requiresAdoption);
      expect(c.adoption, isNull);
      expect(coord.automaticAdmissionDenial(), 'requires_adoption');
      expectReleased();
    });
  });

  group('finalization (§7.5.1): never a sign-out', () {
    test('lost SE4 reply → exact retirement of G\'; admitted', () async {
      await seed();
      capture.finishResult = 'unknown';
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, ['prepare', 'finish', 'retire']);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.ordinary);
      expect(c.adoption, isNull);
      expect(egress.gate.terminalDenied, isFalse);
      expectReleased();
    });

    test('SE4 not executed → compensation; admitted', () async {
      await seed();
      capture.finishResult = 'notExecuted';
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, ['prepare', 'finish', 'compensate']);
      expect(store.committed!.adoption, isNull);
    });

    test('SE5 not confirmed → retirement after a confirmed finish', () async {
      await seed();
      capture.clearOk = false;
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, ['prepare', 'finish', 'clearDart', 'retire']);
      expect(store.committed!.adoption, isNull);
    });

    test(
        'B2: unsettled retirement keeps `finalizing`, blocks generic '
        'reconcile, and the next run reconciles it in order', () async {
      await seed();
      egress.gate.asrSuccessorUnsettled =
          () => asr.unsettledFinalizationOwner != null;
      capture
        ..finishResult = 'unknown'
        ..compensateOk = false;
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, ['prepare', 'finish', 'retire']);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.ordinary);
      expect(c.adoption?.state, AdoptionState.finalizing);
      expect(c.adoption?.successor?.finish, FinishState.dispatched);
      expect(asr.unsettledFinalizationOwner, _uid);
      expect(egress.gate.successorUnsettled, isTrue);
      expectReleased(); // never a hold or exclusion left up

      // The next trigger reconciles the successor first, in order.
      capture
        ..calls.clear()
        ..compensateOk = true
        ..inspectResult = 'unknown'
        ..recovered = AsrPreparedSuccessor(
            successorGeneration: 5, ownerEpoch: 2, pendingOpId: 'p');
      expect(await asr.run(), AsrOutcome.skipped);
      expect(asr.lastStop, 'finalization');
      expect(capture.calls, ['recover', 'inspect', 'retire']);
      expect(store.committed!.adoption, isNull);
      expect(egress.gate.successorUnsettled, isFalse);
    });

    test("B2: a loss during the awaited clearance retires G'", () async {
      await seed();
      capture.duringClear = () {
        host.isResumed = false;
        asr.onBackground();
        host.isResumed = true;
      };
      expect(await asr.run(), AsrOutcome.recovered);
      expect(capture.calls, ['prepare', 'finish', 'clearDart', 'retire']);
      expect(store.committed!.adoption, isNull);
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
    });

    test('B2: an indeterminate Finalizing write that landed is resolved, '
        'not failed on stale memory', () async {
      await seed();
      var armed = true;
      keychain.onWrite = (v) {
        final r = SessionRecord.decode(v);
        writes.add(r);
        if (armed && r.adoption?.state == AdoptionState.finalizing) {
          armed = false;
          keychain
            ..loseNextWriteReply = true
            ..failNextReads = 1; // the write's own reload fails
        }
      };
      expect(await asr.run(), AsrOutcome.recovered);
      expect(host.failed, isFalse);
      expect(store.committed!.adoption, isNull);
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
    });

    test('Phase 4c B2: an unresolvable Finalizing write selects no branch; '
        'the exclusion is held until the durable record decides', () async {
      await seed();
      var armed = true;
      keychain.onWrite = (v) {
        final r = SessionRecord.decode(v);
        writes.add(r);
        if (armed && r.adoption?.state == AdoptionState.finalizing) {
          armed = false;
          keychain
            ..loseNextWriteReply = true
            ..failNextReads = 2; // reload and the resolution both fail
        }
      };
      expect(await asr.run(), AsrOutcome.stayedLocalRead);
      expect(asr.lastStop, 'adoption_unresolved');
      expect(asr.adoptionUnresolved, isTrue);
      expect(host.failed, isFalse, reason: 'never signed out on an unknown');
      expect(egress.gate.terminalDenied, isFalse);
      expect(capture.calls, isNot(contains('finish')));
      expect(capture.calls, isNot(contains('compensate')));
      expect(coord.asrExclusion, isNotNull, reason: 'exclusion held');
      expect(egress.gate.holdActive, isFalse);
      // Readable again: the write landed, so `finalizing` is reconciled.
      expect(await asr.run(), AsrOutcome.skipped);
      expect(asr.adoptionUnresolved, isFalse);
      expect(host.failed, isFalse);
      expect(store.committed!.adoption, isNull);
      expectReleased();
    });
  });

  group('restart in finalizing (§7.5.2)', () {
    AdoptionRecord finalizing(FinishState f) => AdoptionRecord(
        state: AdoptionState.finalizing,
        lifecycle: store.lifecycleFloor + 1,
        opId: 'op-1',
        successor: SuccessorRecord(
            generation: 5,
            evidenceId: 'ev-1',
            pendingOpId: 'op-successor',
            finish: f));
    final p = AsrPreparedSuccessor(
        successorGeneration: 5, ownerEpoch: 2, pendingOpId: 'op-successor');

    test('awaiting → compensation (never an automatic finish) → complete',
        () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.awaiting));
      capture.recovered = p;
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'compensate']);
      expect(store.committed!.adoption, isNull);
    });

    test('Phase 4c: dispatched and executed → retired, never cleared to ON',
        () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.dispatched));
      capture.recovered = p;
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'inspect', 'retire']);
      expect(store.committed!.adoption, isNull);
    });

    test('dispatched but not executed → exact compensation', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.dispatched));
      capture
        ..recovered = p
        ..inspectResult = 'notExecuted';
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'inspect', 'compensate']);
      expect(store.committed!.adoption, isNull);
    });

    test('dispatched + unreadable → retirement', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.dispatched));
      capture
        ..recovered = p
        ..inspectResult = 'unknown';
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'inspect', 'retire']);
    });

    test('Phase 4c: confirmed but not completed → retired (a loss may have '
        'required it), never cleared to ON', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.confirmed));
      capture.recovered = p;
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'retire']);
      expect(store.committed!.adoption, isNull);
    });

    test('Phase 4c: confirmed with no pending left → G\' retired, then '
        'complete', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.confirmed));
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'retireOrphan']);
      expect(store.committed!.adoption, isNull);
    });

    test('no pending left and not confirmed → G\' retired, then complete',
        () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.awaiting));
      await asr.reconcileSuccessorFinalization(_uid);
      expect(capture.calls, ['recover', 'retireOrphan']);
      expect(store.committed!.adoption, isNull);
    });

    test('B2: unsettled compensation keeps `finalizing`', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.awaiting));
      capture
        ..recovered = p
        ..compensateOk = false;
      expect(await asr.reconcileSuccessorFinalization(_uid), isFalse);
      expect(store.committed!.adoption?.state, AdoptionState.finalizing);
    });

    test('B2: a failed orphan retirement keeps `finalizing`', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.dispatched));
      capture.retireOrphanOk = false;
      expect(await asr.reconcileSuccessorFinalization(_uid), isFalse);
      expect(capture.calls, ['recover', 'retireOrphan']);
      expect(store.committed!.adoption?.state, AdoptionState.finalizing);
    });

    test('B2: settled reconciliation reports true', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.confirmed));
      capture.recovered = p;
      expect(await asr.reconcileSuccessorFinalization(_uid), isTrue);
      expect(store.committed!.adoption, isNull);
    });

    test('unreadable before dispatch: native barrier still denies; retried',
        () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.awaiting));
      capture.recoverUnreadable = true;
      expect(await asr.reconcileSuccessorFinalization(_uid), isFalse);
      expect(capture.calls, ['recover']);
      expect(store.committed!.adoption?.state, AdoptionState.finalizing);
    });

    for (final f in [FinishState.dispatched, FinishState.confirmed]) {
      test('unreadable after $f: G\' retired, never ON with Dart disagreeing',
          () async {
        await seed(expIn: 3600, adoption: finalizing(f));
        capture.recoverUnreadable = true;
        await asr.reconcileSuccessorFinalization(_uid);
        expect(capture.calls, ['recover', 'retireOrphan']);
        // Completion waits for a readable Dart state.
        expect(store.committed!.adoption?.state, AdoptionState.finalizing);
      });
    }

    test('another owner\'s record is left alone', () async {
      await seed(expIn: 3600, adoption: finalizing(FinishState.awaiting));
      await asr.reconcileSuccessorFinalization('uid-other');
      expect(capture.calls, isEmpty);
      expect(store.committed!.adoption?.state, AdoptionState.finalizing);
    });
  });

  group('loss vs. explicit sign-in (Phase 4 B7)', () {
    Future<SessionRecord?> explicitSignIn({bool current = true}) async {
      final id = coord.registerAttemptIntent();
      await coord.explicitExchange(id, () async {
        sdk.current = Session.fromJson(sessionJson(
            uid: _uid, exp: _now() + 3600, refreshToken: 'explicit'))!;
        sdk.emit(AuthChangeEvent.signedIn);
      });
      return coord.commitExplicit(id, attemptCurrent: () => current);
    }

    test('an old loss queued behind an explicit commit never bars it',
        () async {
      final old = await seed();
      final lost = coord.blockAutoAdmission();
      expect(lost, old.lifecycle);
      final fresh = await explicitSignIn();
      expect(fresh!.lifecycle, old.lifecycle + 1);
      expect(await coord.markAutoAdmissionBlocked(lifecycle: lost!), isTrue);
      expect(store.committed!.autoAdmissionBlocked, isNull);
      expect(coord.committedBarred, isFalse);
      expect(coord.automaticAdmissionDenial(), isNull);
    });

    test('the loss\'s own lifecycle is barred durably', () async {
      final old = await seed();
      final lost = coord.blockAutoAdmission()!;
      expect(await coord.markAutoAdmissionBlocked(lifecycle: lost), isTrue);
      expect(store.committed!.autoAdmissionBlocked, old.lifecycle);
    });

    test('terminal denial ends only with a confirmed current explicit commit',
        () async {
      await seed();
      egress.gate.terminalDeny();
      expect(await explicitSignIn(current: false), isNull);
      expect(egress.gate.terminalDenied, isTrue);
      expect(await explicitSignIn(), isNotNull);
      expect(egress.gate.terminalDenied, isFalse);
    });
  });

  group('coordinator ASR writes', () {
    test('asrAdoptionDenial exempts only the exclusion holder', () async {
      await seed(
          expIn: 3600,
          admission: AdmissionDisposition.requiresAdoption,
          inSdk: false);
      final r = coord.continuationReceipt(_uid)!;
      final install = await coord.installForAsr(r, predicate: () => true);
      expect(install!.installed, isTrue);
      expect(coord.automaticAdmissionDenial(), 'asr_exclusion');
      expect(coord.asrAdoptionDenial(r), 'barred'); // no pending yet
      expect(await coord.writeAdoption(r, AdoptionState.pending), isTrue);
      expect(coord.asrAdoptionDenial(r), isNull);
      final other = RefreshReceipt(
          opId: 'other',
          lifecycle: r.lifecycle,
          seq: r.seq,
          digest: r.digest,
          predecessorDigest: r.digest,
          sdkBaseline: r.sdkBaseline,
          owner: _uid,
          intentSeq: r.intentSeq);
      expect(coord.asrAdoptionDenial(other), 'asr_exclusion');
      coord.releaseAsrExclusion(r.opId);
      await egress.gate.endTransitionHold(install.hold);
      // After release the record still denies every automatic route.
      expect(coord.automaticAdmissionDenial(), 'requires_adoption');
    });

    test('install refuses a record that is not the receipt', () async {
      await seed(
          expIn: 3600,
          admission: AdmissionDisposition.requiresAdoption,
          inSdk: false);
      final r = coord.continuationReceipt(_uid)!;
      expect(
          await coord.markAutoAdmissionBlocked(
              lifecycle: store.committed!.lifecycle),
          isTrue);
      expect(await coord.installForAsr(r, predicate: () => true), isNull);
      expect(coord.asrExclusion, isNull);
      expect(egress.gate.holdActive, isFalse);
    });

    test('the durable §7.7 barrier bars ASR and every automatic route',
        () async {
      await seed();
      expect(
          await coord.markAutoAdmissionBlocked(
              lifecycle: store.committed!.lifecycle),
          isTrue);
      expect(store.committed!.autoAdmissionBlocked, store.committed!.lifecycle);
      expect(coord.automaticAdmissionDenial(), 'barred');
      expect(await asr.run(), AsrOutcome.skipped);
    });
  });
}
