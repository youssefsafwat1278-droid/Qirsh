import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../harness/egress_test_support.dart';

/// ASR design v7.2 WP3: the gate half of the single refresher (§3.1), typed
/// causes and the cause log (§5), refresh tickets (§9.3/§9.4), transition holds,
/// terminal denial, the alignment zone (§4.8, §11) and account-control
/// quiescence (§11.3).
const _url = 'https://example.supabase.co';

void main() {
  late TestEgress egress;
  late List<http.BaseRequest> seen;
  late GatedHttpClient client;
  var localRead = false;

  setUp(() {
    egress = TestEgress(seedOn: true).install();
    egress.gate.localReadActive = () => localRead;
    localRead = false;
    seen = [];
    client = GatedHttpClient(MockClient((req) async {
      seen.add(req);
      return http.Response('{}', 200);
    }));
  });

  tearDown(() => ConsentAuthority.egressFrozen = false);

  Future<String?> denial(Future<Object?> Function() f) async {
    try {
      await f();
      return null;
    } on EgressDeniedException catch (e) {
      return e.reason;
    }
  }

  http.Request req(String path,
      {String method = 'POST', String? body, String type = 'application/json'}) {
    final r = http.Request(method, Uri.parse('$_url$path'));
    if (body != null) {
      r.headers['content-type'] = type;
      r.body = body;
    }
    return r;
  }

  group('§3.1 SR: SDK refresh denied before admission', () {
    final denied = <String, http.BaseRequest Function()>{
      'gotrue shape (query grant, JSON token)': () => req(
          '/auth/v1/token?grant_type=refresh_token',
          body: jsonEncode({'refresh_token': 'r'})),
      'refresh_token in body only': () =>
          req('/auth/v1/token', body: jsonEncode({'refresh_token': 'r'})),
      'grant in form body': () => req('/auth/v1/token',
          body: 'grant_type=refresh_token&refresh_token=r',
          type: 'application/x-www-form-urlencoded'),
      'grant in JSON body': () => req('/auth/v1/token',
          body: jsonEncode({'grant_type': 'refresh_token'})),
      'duplicate grant_type': () =>
          req('/auth/v1/token?grant_type=id_token&grant_type=id_token'),
      'conflicting query/body grant': () => req(
          '/auth/v1/token?grant_type=id_token',
          body: jsonEncode({'grant_type': 'password'})),
      'malformed percent encoding': () => req('/auth/v1/token',
          body: 'grant_type=%zz', type: 'application/x-www-form-urlencoded'),
      'malformed JSON': () =>
          req('/auth/v1/token?grant_type=id_token', body: '{oops'),
      'unknown content type': () => req('/auth/v1/token?grant_type=id_token',
          body: 'x', type: 'text/plain'),
      'percent-encoded path': () =>
          req('/auth/v1/%74oken?grant_type=refresh_token'),
      'trailing slash / doubled slash': () =>
          req('//auth/v1/token/?grant_type=refresh_token'),
      'streamed body': () => http.StreamedRequest(
          'POST', Uri.parse('$_url/auth/v1/token?grant_type=id_token'))
        ..sink.close(),
    };
    for (final e in denied.entries) {
      test(e.key, () async {
        expect(await denial(() => client.send(e.value())), 'sdk_refresh');
        expect(seen, isEmpty);
        expect(egress.gate.inFlightCount, 0, reason: 'never admitted');
      });
    }

    test('denied under every grant, including delete/cancel', () async {
      for (final op in AccountControlOp.values) {
        final r = await denial(() => egress.gate.runAccountControl(
            op,
            () => client.send(req('/auth/v1/token?grant_type=refresh_token',
                body: jsonEncode({'refresh_token': 'r'})))));
        expect(r, 'sdk_refresh', reason: op.name);
      }
      expect(seen, isEmpty);
    });

    test('other grants are unchanged (id_token admitted under signIn)',
        () async {
      await egress.gate.runAccountControl(
          AccountControlOp.signIn,
          () async => (await client.send(req(
                  '/auth/v1/token?grant_type=id_token',
                  body: jsonEncode({'id_token': 'x', 'provider': 'google'}))))
              .stream
              .drain<void>());
      expect(seen, hasLength(1));
    });

    test(
        'Phase 4 B9: the classified snapshot is what is sent; a body swapped '
        'during admission never reaches transport', () async {
      await egress.gate.runAccountControl(AccountControlOp.signIn, () async {
        final r = req('/auth/v1/token?grant_type=id_token',
            body: jsonEncode({'id_token': 'x', 'provider': 'google'}));
        final sent = client.send(r);
        // While admission awaits, the caller replaces the allowed body with a
        // forbidden refresh body and adds a header.
        r.body = jsonEncode(
            {'grant_type': 'refresh_token', 'refresh_token': 'stolen'});
        r.headers['authorization'] = 'Bearer injected';
        await (await sent).stream.drain<void>();
      });
      expect(seen, hasLength(1));
      final out = seen.single as http.Request;
      expect(jsonDecode(out.body), {'id_token': 'x', 'provider': 'google'});
      expect(out.headers.keys.map((k) => k.toLowerCase()),
          isNot(contains('authorization')));
    });

    test('other hosts and paths are not classified', () async {
      expect(
          egress.gate.sdkRefreshViolation(http.Request('POST',
              Uri.parse('https://other.example/auth/v1/token?grant_type=refresh_token'))),
          isNull);
      expect(
          egress.gate.sdkRefreshViolation(
              req('/auth/v1/user', method: 'GET')),
          isNull);
    });

    test('the coordinator endpoint is the classified path', () {
      final uri = egress.gate.refreshTokenUri()!;
      expect(uri.toString(), '$_url/auth/v1/token?grant_type=refresh_token');
      expect(egress.gate.sdkRefreshViolation(http.Request('POST', uri)),
          'sdk_refresh');
    });
  });

  group('§5 PR: typed causes and the cause log', () {
    test('every epoch advance appends a cause; untyped is IDENTITY', () {
      final p0 = egress.gate.causePosition;
      final e0 = egress.gate.epoch;
      egress.gate.advanceEpoch(EpochCause.consentLoss);
      egress.gate.advanceEpoch();
      expect(egress.gate.epoch, e0 + 2);
      expect(egress.gate.causePosition, p0 + 2);
      expect(
          egress.gate.foreignCauseSince(p0 + 1,
              kind: RefreshOpKind.routine, atLeast: CauseClass.identity),
          isTrue);
      expect(
          egress.gate.foreignCauseSince(p0,
              kind: RefreshOpKind.routine, atLeast: CauseClass.identity),
          isTrue);
      expect(
          egress.gate.foreignCauseSince(p0 + 2, kind: RefreshOpKind.routine),
          isFalse);
    });

    test('lifecycle denial and freeze advance through typed causes', () {
      final p0 = egress.gate.causePosition;
      egress.gate.denyForLifecycleLoss();
      egress.gate.freezeEnable('uid-a');
      expect(egress.gate.causePosition, p0 + 2);
      expect(
          egress.gate.foreignCauseSince(p0,
              kind: RefreshOpKind.asr, atLeast: CauseClass.identity),
          isFalse,
          reason: 'both are POLICY');
      egress.gate.releaseLifecycleDenial();
    });

    test('explicitAttempt is IDENTITY for ASR, POLICY otherwise', () {
      expect(EpochCause.explicitAttempt.classFor(RefreshOpKind.asr),
          CauseClass.identity);
      expect(EpochCause.explicitAttempt.classFor(RefreshOpKind.routine),
          CauseClass.policy);
      expect(EpochCause.explicitAttempt.classFor(RefreshOpKind.accountControl),
          CauseClass.policy);
    });

    test('an op\'s own causes are not foreign for it', () {
      final me = Object();
      final p0 = egress.gate.causePosition;
      egress.gate.noteCause(EpochCause.captureTransition, authority: me);
      expect(
          egress.gate.foreignCauseSince(p0,
              kind: RefreshOpKind.asr, authority: me),
          isFalse);
      expect(egress.gate.foreignCauseSince(p0, kind: RefreshOpKind.asr),
          isTrue);
    });

    test('an overflowed log answers foreign for an op that started before it',
        () {
      final p0 = egress.gate.causePosition;
      for (var i = 0; i <= CloudEgressGate.causeLogCapacity; i++) {
        egress.gate.noteCause(EpochCause.localRead, authority: #self);
      }
      expect(
          egress.gate.foreignCauseSince(p0,
              kind: RefreshOpKind.routine, authority: #self),
          isTrue);
    });

    test('noteCause does not advance the epoch', () {
      final e0 = egress.gate.epoch;
      egress.gate.noteCause(const EpochCause.native('setCloudEgressState'));
      expect(egress.gate.epoch, e0);
    });

    test('protected native writes append their cause before the channel call',
        () async {
      NativeCaptureBridge.debugTreatHostAsNative = true;
      addTearDown(() => NativeCaptureBridge.debugTreatHostAsNative = false);
      final p0 = egress.gate.causePosition;
      // No native handler in the test host: the call fails after the append.
      try {
        await NativeCaptureBridge.clearCaptureOwner(clearHint: false);
      } catch (_) {}
      expect(egress.gate.causePosition, p0 + 1);
      expect(
          egress.gate.foreignCauseSince(p0,
              kind: RefreshOpKind.routine, atLeast: CauseClass.identity),
          isTrue,
          reason: 'owner clear is IDENTITY');
      // Reads are not causes.
      try {
        await NativeCaptureBridge.getCaptureOwner();
      } catch (_) {}
      expect(egress.gate.causePosition, p0 + 1);
    });
  });

  group('§9.3/§9.4 refresh tickets', () {
    Future<EgressTicket> admit(RefreshOpKind kind,
            {Object? authority, bool Function()? predicate}) =>
        egress.gate.admitRefreshOp(
            kind: kind,
            owner: 'uid-a',
            startPosition: egress.gate.causePosition,
            authority: authority ?? Object(),
            predicate: predicate);

    test('routine admitted in normal mode; registered in flight', () async {
      final t = await admit(RefreshOpKind.routine);
      expect(t.refresh!.kind, RefreshOpKind.routine);
      expect(egress.gate.inFlightCount, 1);
      expect(egress.gate.confirmRefreshSend(t), isNull);
      expect(t.refresh!.passedSend, isTrue);
      egress.gate.release(t);
    });

    test('routine denied in local read; ASR requires it', () async {
      expect(await denial(() => admit(RefreshOpKind.asr)), 'not_local_read');
      localRead = true;
      expect(await denial(() => admit(RefreshOpKind.routine)),
          'routine_not_permitted');
      final t = await admit(RefreshOpKind.asr);
      egress.gate.release(t);
    });

    // Owner decision (2026-10-29): the session-only refresh with Cloud OFF.
    group('session-only routine refresh (Cloud OFF)', () {
      String layers(EgressState state) => jsonEncode({
            'v': 1,
            'records': {
              'uid-a': CloudEgressRecord(
                      state: state,
                      ownerUid: 'uid-a',
                      transitionGeneration: 2,
                      reservedVersion: 1)
                  .toJson()
            }
          });
      Future<String?> routine(TestEgress e) => denial(() async {
            final t = await e.gate.admitRefreshOp(
                kind: RefreshOpKind.routine,
                owner: 'uid-a',
                startPosition: e.gate.causePosition,
                authority: Object());
            e.gate.release(t);
            return null;
          });
      TestEgress withLayers(String? body, {NativeEgressSlot? native}) {
        final e = TestEgress(native: native);
        e.secure.value = body;
        e.file.value = body;
        return e.install()..gate.localReadActive = () => localRead;
      }

      test(
          'durable OFF and never-enabled admit it; ordinary egress stays denied',
          () async {
        for (final e in [
          withLayers(layers(EgressState.off)),
          withLayers(null)
        ]) {
          expect(await e.gate.permits(), isFalse);
          expect(await e.gate.permitsSessionRefresh(), isTrue);
          expect(await routine(e), isNull);
          expect(await denial(() => e.gate.admit()), isNotNull);
        }
      });

      // L2 (2026-11-14): no Cloud consent state stops the session-only
      // exchange; ordinary egress stays denied in every one of them.
      test(
          'L2: DISABLING, ON, an uncertain store, a native DISABLING or '
          'unavailable read, pending, partial or mixed layers all admit the '
          'refresh; ordinary egress stays denied', () async {
        Future<void> admits(TestEgress e) async {
          expect(await e.gate.permitsSessionRefresh(), isTrue);
          expect(await routine(e), isNull);
          expect(await denial(() => e.gate.admit()), isNotNull);
        }

        await admits(withLayers(layers(EgressState.disabling)));
        await admits(withLayers('not-json'));
        await admits(withLayers(layers(EgressState.off),
            native: NativeEgressSlot(
                read: (_) async =>
                    throw const FormatException('native_egress_uncertain:io'),
                write: (_) async {})));
        await admits(withLayers(layers(EgressState.off),
            native: NativeEgressSlot(
                read: (o) async => CloudEgressRecord(
                    state: EgressState.disabling,
                    ownerUid: o,
                    transitionGeneration: 3,
                    reservedVersion: 1),
                write: (_) async {})));
        await admits(withLayers(layers(EgressState.off))..nativeOff = false);
        final pending = withLayers(layers(EgressState.off));
        pending.pendingSecure.value = 'not-a-pending-record';
        await admits(pending);
        await admits(withLayers(null)..secure.value = layers(EgressState.off));
        await admits(withLayers(layers(EgressState.off))
          ..file.value = layers(EgressState.on));
        final frozenEnable = withLayers(layers(EgressState.off));
        frozenEnable.gate.freezeEnable('uid-a');
        await admits(frozenEnable);
        ConsentAuthority.egressFrozen = true;
        try {
          await admits(withLayers(layers(EgressState.disabling)));
        } finally {
          ConsentAuthority.egressFrozen = false;
        }
      });

      test('dartLayersVerifiedOff still tells absence, partial and mixed apart',
          () async {
        final partial = withLayers(null)..secure.value = layers(EgressState.off);
        expect(
            await partial.gate.dartLayersVerifiedOff('uid-a', allowAbsent: true),
            isFalse);
        final mixed = withLayers(layers(EgressState.off))
          ..file.value = layers(EgressState.on);
        expect(await mixed.gate.dartLayersVerifiedOff('uid-a', allowAbsent: true),
            isFalse);
        final absent = withLayers(null);
        expect(
            await absent.gate.dartLayersVerifiedOff('uid-a', allowAbsent: false),
            isFalse);
        expect(
            await absent.gate.dartLayersVerifiedOff('uid-a', allowAbsent: true),
            isTrue);
      });

      test('every process denial that is not Cloud consent still applies',
          () async {
        Future<void> denied(void Function(TestEgress e) arrange,
            [void Function()? undo]) async {
          final e = withLayers(layers(EgressState.off));
          arrange(e);
          expect(await e.gate.permitsSessionRefresh(), isFalse);
          expect(await routine(e), isNotNull);
          undo?.call();
        }

        await denied((_) => localRead = true, () => localRead = false);
        await denied((e) => e.gate.terminalDeny());
        await denied((e) => e.gate.beginTransitionHold());
        await denied((e) => e.gate.denyForLifecycleLoss());
        final unresolved = TestEgress(resolved: false).install();
        expect(await unresolved.gate.permitsSessionRefresh(), isFalse);
      });
    });

    test('a foreign cause after start denies admission', () async {
      final start = egress.gate.causePosition;
      egress.gate.advanceEpoch(EpochCause.consentLoss);
      expect(
          await denial(() => egress.gate.admitRefreshOp(
              kind: RefreshOpKind.routine,
              owner: 'uid-a',
              startPosition: start,
              authority: Object())),
          'foreign_cause');
    });

    test('the op predicate is evaluated last, synchronously', () async {
      expect(await denial(() => admit(RefreshOpKind.routine, predicate: () => false)),
          'predicate');
      expect(
          await denial(() => admit(RefreshOpKind.routine,
              predicate: () => throw StateError('x'))),
          'predicate');
    });

    test('owner mismatch is denied', () async {
      egress.owner = 'uid-b';
      expect(await denial(() => admit(RefreshOpKind.routine)), 'owner');
    });

    test('IDENTITY cause cancels every refresh ticket, even past send',
        () async {
      final t = await admit(RefreshOpKind.routine);
      expect(egress.gate.confirmRefreshSend(t), isNull);
      egress.gate.advanceEpoch(EpochCause.accountSwitch);
      expect(t.isCancelled, isTrue);
      egress.gate.release(t);
    });

    test('POLICY before send cancels; after send marks noInstall only',
        () async {
      final before = await admit(RefreshOpKind.routine);
      final after = await admit(RefreshOpKind.routine);
      expect(egress.gate.confirmRefreshSend(after), isNull);
      egress.gate.advanceEpoch(EpochCause.consentLoss);
      expect(before.isCancelled, isTrue);
      expect(after.isCancelled, isFalse);
      expect(after.refresh!.noInstall, isTrue);
      expect(egress.gate.confirmRefreshSend(before), 'cancelled');
      egress.gate.release(before);
      egress.gate.release(after);
    });

    test('explicitAttempt cancels ASR past send, not routine past send',
        () async {
      final routine = await admit(RefreshOpKind.routine);
      expect(egress.gate.confirmRefreshSend(routine), isNull);
      localRead = true;
      final asr = await admit(RefreshOpKind.asr);
      expect(egress.gate.confirmRefreshSend(asr), isNull);
      egress.gate.advanceEpoch(EpochCause.explicitAttempt);
      expect(asr.isCancelled, isTrue);
      expect(routine.isCancelled, isFalse);
      expect(routine.refresh!.noInstall, isTrue);
      egress.gate.release(routine);
      egress.gate.release(asr);
    });

    test('the op\'s own causes never cancel its ticket', () async {
      final me = Object();
      final t = await admit(RefreshOpKind.routine, authority: me);
      egress.gate.advanceEpoch(EpochCause.removal, me);
      expect(t.isCancelled, isFalse);
      expect(egress.gate.confirmRefreshSend(t), isNull);
      egress.gate.release(t);
    });

    test('P_send rechecks a foreign cause and a hold', () async {
      final t = await admit(RefreshOpKind.routine);
      final hold = egress.gate.beginTransitionHold();
      expect(egress.gate.confirmRefreshSend(t), 'transition_hold');
      await egress.gate.endTransitionHold(hold);
      expect(egress.gate.confirmRefreshSend(t), isNull);
      egress.gate.release(t);
    });

    test('accountControl needs the delete/cancel grant zone', () async {
      expect(await denial(() => admit(RefreshOpKind.accountControl)),
          'grant_scope');
      expect(
          await denial(() => egress.gate.runAccountControl(
              AccountControlOp.signIn, () => admit(RefreshOpKind.accountControl))),
          'grant_scope');
      for (final op in [
        AccountControlOp.deleteAccount,
        AccountControlOp.cancelDelete
      ]) {
        await egress.gate.runAccountControl(op, () async {
          final t = await admit(RefreshOpKind.accountControl);
          expect(t.grant, isNotNull);
          expect(egress.gate.confirmRefreshSend(t), isNull);
          egress.gate.release(t);
        });
      }
    });

    test('accountControl works with Cloud OFF and under terminal denial',
        () async {
      final off = TestEgress().install();
      off.gate.terminalDeny();
      await off.gate.runAccountControl(AccountControlOp.deleteAccount,
          () async {
        final t = await off.gate.admitRefreshOp(
            kind: RefreshOpKind.accountControl,
            owner: 'uid-a',
            startPosition: off.gate.causePosition,
            authority: Object());
        off.gate.release(t);
      });
    });

    test('a drain cancels refresh tickets too', () async {
      final t = await admit(RefreshOpKind.routine);
      final r = await egress.gate.drain();
      expect(r.cancelled, 1);
      expect(t.isCancelled, isTrue);
      expect(egress.gate.inFlightCount, 0);
    });
  });

  group('§11.1 transition hold', () {
    test('denies every Dart permit path; ends only by its token', () async {
      expect(await egress.gate.permits(), isTrue);
      final a = egress.gate.beginTransitionHold();
      final b = egress.gate.beginTransitionHold();
      expect(await egress.gate.permits(), isFalse);
      expect(egress.gate.permitsNetworkSync, isFalse);
      expect(egress.gate.permitNotifier.value, isFalse);
      expect(await egress.gate.mayLaunchExternal(Uri.parse('$_url/x')), isFalse);
      expect(await denial(() => egress.gate.admit()), 'transition_hold');
      expect(
          await denial(() => egress.gate.runAccountControl(
              AccountControlOp.signIn,
              () => egress.gate.admit(
                  request: AdmissionRequest(
                      'POST', Uri.parse('$_url/auth/v1/otp'))))),
          'transition_hold');
      await egress.gate.endTransitionHold(a);
      await egress.gate.endTransitionHold(a); // idempotent
      expect(await egress.gate.permits(), isFalse, reason: 'b still held');
      await egress.gate.endTransitionHold(b);
      expect(await egress.gate.permits(), isTrue);
      expect(egress.gate.permitsNetworkSync, isTrue);
    });

    test('cancels outstanding ordinary tickets, not refresh tickets', () async {
      final ordinary = await egress.gate.admit();
      final refresh = await egress.gate.admitRefreshOp(
          kind: RefreshOpKind.routine,
          owner: 'uid-a',
          startPosition: egress.gate.causePosition,
          authority: Object());
      final h = egress.gate.beginTransitionHold();
      expect(ordinary.isCancelled, isTrue);
      expect(refresh.isCancelled, isFalse);
      egress.gate.release(ordinary);
      egress.gate.release(refresh);
      await egress.gate.endTransitionHold(h);
    });

    test('a hold begun while permits() awaits wins (recheck after await)',
        () async {
      final pending = egress.gate.permits();
      final h = egress.gate.beginTransitionHold();
      expect(await pending, isFalse);
      await egress.gate.endTransitionHold(h);
    });
  });

  group('§11.4 terminal denial', () {
    test('denies everything except explicit account control', () async {
      egress.gate.terminalDeny();
      expect(await egress.gate.permits(), isFalse);
      expect(egress.gate.permitsNetworkSync, isFalse);
      expect(await denial(() => egress.gate.admit()), 'terminal');
      await egress.gate.runAccountControl(AccountControlOp.signIn, () async {
        final t = await egress.gate.admit(
            request:
                AdmissionRequest('POST', Uri.parse('$_url/auth/v1/otp')));
        egress.gate.release(t);
      });
      egress.gate.clearTerminalDenial();
      await Future<void>.delayed(Duration.zero);
      expect(await egress.gate.permits(), isTrue);
    });

    test('resolveSignedOut keeps the process resolved and bumps the generation',
        () async {
      final g = egress.gate.resolutionGeneration;
      await egress.gate.resolveSignedOut();
      expect(egress.gate.resolvedSignedOut, isTrue);
      expect(egress.gate.resolutionGeneration, g + 1);
      final tok = egress.gate.beginResolution();
      expect(egress.gate.resolvedSignedOut, isFalse);
      expect(egress.gate.markResolved(tok), isTrue);
      expect(egress.gate.resolutionGeneration, g + 3);
    });
  });

  group('§4.8 alignment zone', () {
    test('every request in the zone is denied before admission', () async {
      final r = await denial(() => egress.gate.runAlignment(() =>
          client.send(req('/auth/v1/logout?scope=local', body: '{}'))));
      expect(r, 'alignment');
      expect(seen, isEmpty);
      expect(egress.gate.inFlightCount, 0);
      // Outside the zone the gate is unchanged.
      expect(await egress.gate.permits(), isTrue);
    });

    test('a timer spawned in the zone stays denied after it returned',
        () async {
      final late = Completer<String?>();
      await egress.gate.runAlignment(() async {
        Timer(const Duration(milliseconds: 10), () async {
          late.complete(await denial(() => egress.gate.admit()));
        });
      });
      expect(await late.future, 'alignment');
    });
  });

  group('§11.3 explicit attempt waits for ASR quiescence', () {
    test('awaits the hook before the grant starts', () async {
      final quiet = Completer<void>();
      egress.gate.asrQuiesced = () => quiet.future;
      addTearDown(() => egress.gate.asrQuiesced = null);
      var ran = false;
      final f = egress.gate.runAccountControl(AccountControlOp.signIn,
          () async => ran = true, attempt: true);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(ran, isFalse);
      quiet.complete();
      await f;
      expect(ran, isTrue);
    });

    test('non-attempt account control does not wait', () async {
      egress.gate.asrQuiesced = () => Completer<void>().future;
      addTearDown(() => egress.gate.asrQuiesced = null);
      expect(
          await egress.gate
              .runAccountControl(AccountControlOp.deleteAccount, () async => 1),
          1);
    });
  });

  test('source audit: no untyped epoch advance in lib/', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('advanceEpoch()')) offenders.add('${f.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty);
  });
}
