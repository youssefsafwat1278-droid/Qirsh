import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/auth_coordinator.dart';
import 'package:money_companion/core/auth/auth_diagnostics.dart';
import 'package:money_companion/core/auth/owned_tls_socket.dart';
import 'package:money_companion/core/auth/refresh_transport.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_record.dart';
import 'package:money_companion/core/auth/session_store.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../harness/egress_test_support.dart';
import 'session_fixtures.dart';
import 'store_fakes.dart';

/// ASR v7.2 WP4: the AuthCoordinator — section, intents, exclusions, tags,
/// alignment, explicit commit, removal and the routine/accountControl refresh
/// engine over fakes (SDK port, refresh channel, Keychain).
const _uid = 'uid-a';

int _now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

class FakeSdk implements SdkAuthPort {
  final _events = StreamController<AuthState>.broadcast(sync: true);
  Session? current;
  int recovers = 0;
  int signOuts = 0;
  Object? serverSignOutError;

  void emit(AuthChangeEvent e) => _events.add(AuthState(e, current));

  @override
  Session? get currentSession => current;

  @override
  Stream<AuthState> get syncEvents => _events.stream;

  @override
  Future<void> recoverSession(String canonical) async {
    recovers++;
    final s = Session.fromJson(jsonDecode(canonical) as Map<String, dynamic>)!;
    if (s.isExpired) throw const AuthException('expired');
    final emitEvent = current == null || current!.user.id != s.user.id;
    current = s;
    if (emitEvent) emit(AuthChangeEvent.tokenRefreshed);
  }

  @override
  Future<void> signOutLocal() async {
    signOuts++;
    current = null;
    emit(AuthChangeEvent.signedOut);
    // admin.signOut: a request through the gate (denied in the zone).
    try {
      final t = await CloudEgressGate.instance.admit();
      CloudEgressGate.instance.release(t);
    } catch (e) {
      serverSignOutError = e;
      rethrow;
    }
  }
}

class FakeChannel implements RefreshChannel {
  FakeChannel(this.script);
  final ChannelScript script;
  bool _sent = false;
  bool cancelled = false;
  bool opened = false;
  final Completer<void> _cancel = Completer<void>();

  @override
  bool get sent => _sent;

  @override
  Future<void> open() async {
    script.opens++;
    if (script.openError != null) throw script.openError!;
    opened = true;
  }

  @override
  Future<RefreshHttpResult> send(String refreshToken) {
    _sent = true;
    script.sentTokens.add(refreshToken);
    final hold = script.holdResponse;
    if (hold == null) return Future.value(script.result());
    return Future.any([
      hold.future.then((_) => script.result()),
      _cancel.future.then<RefreshHttpResult>(
          (_) => throw const RefreshCancelled('cancel')),
    ]);
  }

  @override
  void cancel() {
    cancelled = true;
    if (!_cancel.isCompleted) _cancel.complete();
  }

  @override
  void close() {}

  @override
  Future<void> quiesced() async {
    await script.quiesceHold?.future;
    if (script.quiesceError != null) throw script.quiesceError!;
  }
}

class ChannelScript {
  int opens = 0;
  final sentTokens = <String>[];
  Object? openError;

  /// Thrown by the channel's quiescence (e.g. an unconfirmed closure).
  Object? quiesceError;

  /// When set, the channel's quiescence waits for it.
  Completer<void>? quiesceHold;
  Completer<void>? holdResponse;
  RefreshHttpResult Function() result = () => ok();

  static RefreshHttpResult ok({String uid = _uid, String token = 'refresh-2'}) {
    final exp = _now() + 3600;
    return RefreshHttpResult(
        statusCode: 200,
        json: sessionJson(uid: uid, exp: exp, refreshToken: token)
          ..['expires_at'] = exp,
        isRedirect: false);
  }
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
  late List<SessionRecord> writes;

  SessionStore newStore() => SessionStore(
        keychain: keychain,
        files: SessionFiles(dir),
        origin: origin,
        legacy: FakeLegacy(),
        localInstallDataPresent: () async => true,
      );

  Future<SessionRecord> seed(
      {int expIn = 20,
      AdmissionDisposition admission = AdmissionDisposition.ordinary,
      bool inSdk = true}) async {
    final r = SessionRecord(
      ns: store.ns,
      installId: store.installId!,
      seq: store.nextSeqFloor + 1,
      lifecycle: store.lifecycleFloor + 1,
      kind: RecordKind.session,
      owner: _uid,
      session: canonicalSession(
          sessionJson(uid: _uid, exp: _now() + expIn, refreshToken: 'refresh-1')),
      admission: admission,
    );
    expect(await store.write(r), WriteOutcome.committed);
    writes.clear();
    if (inSdk) {
      sdk.current = r.sdkSession;
      coord.endInit(served: r);
    } else {
      coord.endInit();
    }
    return r;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('auth_coord_');
    keychain = FakeKeychain();
    egress = TestEgress(seedOn: true).install();
    store = newStore();
    await store.load();
    sdk = FakeSdk();
    script = ChannelScript();
    writes = [];
    coord = AuthCoordinator(
        store: store,
        gate: egress.gate,
        channelFactory: () => FakeChannel(script))
      ..attach(sdk);
    // Observe every confirmed record write.
    keychain.onWrite = (v) => writes.add(SessionRecord.decode(v));
  });
  tearDown(() async {
    coord.dispose();
    await dir.delete(recursive: true);
  });

  RefreshOpSpec routine() => const RefreshOpSpec(
      kind: RefreshOpKind.routine, deadline: Duration(seconds: 30));

  group('same-owner identity linking', () {
    test('persists updated identity without changing lifecycle or dispatch limits', () async {
      final original = await seed(expIn: 3600);
      final limited = original.copyWith(seq: original.seq + 1, tokenDispatches: () =>
          const TokenDispatches(digest: 'previous-token', count: 3));
      await store.write(limited);
      sdk.current = limited.sdkSession;
      coord.endInit(served: limited);
      coord.ordinaryAdmissionHeld = () => true;
      await coord.updateLinkedIdentity(owner: _uid, current: () => true, exchange: () async {
        final json = sdk.current!.toJson();
        json['user'] = {...(json['user'] as Map<String, dynamic>), 'email': 'linked@example.test'};
        sdk.current = Session.fromJson(json);
        sdk.emit(AuthChangeEvent.userUpdated);
      });
      expect(store.committed!.owner, _uid);
      expect(store.committed!.sdkSession!.user.email, 'linked@example.test');
      expect(store.committed!.lifecycle, original.lifecycle);
      expect(store.committed!.tokenDispatches!.count, 3);
      expect(coord.automaticAdmissionDenial(), isNull);
    });

    test('refuses a linked response for another owner and restores SDK memory', () async {
      final original = await seed(expIn: 3600);
      coord.ordinaryAdmissionHeld = () => true;
      await expectLater(coord.updateLinkedIdentity(owner: _uid, current: () => true,
        exchange: () async {
          sdk.current = Session.fromJson(sessionJson(uid: 'uid-b', exp: _now() + 3600));
          sdk.emit(AuthChangeEvent.signedIn);
        }), throwsA(isA<ExplicitRefused>()));
      expect(store.committed!.digest, original.digest);
      expect(sdk.current!.user.id, _uid);
    });

    test('removal during linking cannot commit the returned identity', () async {
      final original = await seed(expIn: 3600);
      coord.ordinaryAdmissionHeld = () => true;
      await expectLater(coord.updateLinkedIdentity(owner: _uid, current: () => true,
        exchange: () async {
          coord.beginRemovalIntent();
          sdk.emit(AuthChangeEvent.userUpdated);
        }), throwsA(isA<ExplicitRefused>()));
      expect(store.committed!.digest, original.digest);
    });

    test('no admitted account means no network exchange', () async {
      await seed(expIn: 3600);
      var called = false;
      await expectLater(coord.updateLinkedIdentity(owner: _uid, current: () => true,
        exchange: () async { called = true; }), throwsA(isA<ExplicitRefused>()));
      expect(called, isFalse);
    });
  });

  group('routine refresh (§10.3)', () {
    test('reserve → mark → send → commit → silent install', () async {
      await seed();
      final rotated = <RefreshReceipt>[];
      coord.onCredentialRotated = rotated.add;
      final out = await coord.runRefresh(routine());
      expect(out.kind, RefreshOutcomeKind.committed);
      expect(out.installed, isTrue);
      expect(script.sentTokens, ['refresh-1']);
      expect(writes.map((w) => w.refreshOp?.state), [
        RefreshOpState.reserved,
        RefreshOpState.dispatchMarked,
        null,
      ]);
      expect(writes[1].tokenDispatches!.count, 1);
      final c = store.committed!;
      expect(c.admission, AdmissionDisposition.ordinary);
      expect(c.tokenDispatches, isNull);
      expect(c.sdkSession!.refreshToken, 'refresh-2');
      expect(sdk.current!.refreshToken, 'refresh-2');
      expect(coord.sdkBaseline, c.digest);
      expect(rotated.single.digest, c.digest);
      expect(egress.gate.inFlightCount, 0);
      expect(coord.refreshing, isFalse);
    });

    test('connect failure → retryable, no credential byte', () async {
      await seed();
      script.openError = const SocketException('down');
      final out = await coord.runRefresh(routine());
      expect(out.kind, RefreshOutcomeKind.notSent);
      expect(script.sentTokens, isEmpty);
      expect(store.committed!.refreshOp!.state, RefreshOpState.retryable);
      expect(store.committed!.tokenDispatches!.count, 0);
    });

    test('definitive 400 → RefreshDead, owner and data kept', () async {
      await seed();
      var dead = 0;
      coord.onCredentialDead = () => dead++;
      script.result = () => const RefreshHttpResult(
          statusCode: 400,
          json: {'error_code': 'refresh_token_already_used'},
          isRedirect: false);
      final out = await coord.runRefresh(routine());
      expect(out.kind, RefreshOutcomeKind.dead);
      expect(store.committed!.credential, CredentialState.dead);
      expect(store.committed!.owner, _uid);
      expect(dead, 1);
    });

    test('invalid 200 (wrong sub / same token) → possibly sent, stays marked',
        () async {
      await seed();
      for (final bad in [
        () => ChannelScript.ok(uid: 'uid-b'),
        () => ChannelScript.ok(token: 'refresh-1'),
        () => const RefreshHttpResult(
            statusCode: 302, json: null, isRedirect: true),
      ]) {
        script.result = bad;
        final out = await coord.runRefresh(routine());
        expect(out.kind, RefreshOutcomeKind.possiblySent);
        expect(store.committed!.refreshOp!.state, RefreshOpState.dispatchMarked);
      }
      expect(store.committed!.tokenDispatches!.count, 3);
      // Q1: the budget of 3 dispatches per token digest is durable.
      final out = await coord.runRefresh(routine());
      expect(out.kind, RefreshOutcomeKind.exhausted);
      expect(script.opens, 3);
      // A fresh process sees the same count.
      final reloaded = newStore();
      await reloaded.load();
      expect(reloaded.committed!.tokenDispatches!.count, 3);
    });

    // Beta 1 diagnostic trail: why each attempt ended, constants only.
    test('the diagnostic trail names each outcome and never a secret',
        () async {
      AuthDiagnostics.debugReset();
      await seed();
      final digest = store.committed!.tokenDispatches?.digest;
      script.result = () => ChannelScript.ok(uid: 'uid-b');
      await coord.runRefresh(routine());
      script.result = () => const RefreshHttpResult(
          statusCode: 503, json: null, isRedirect: false);
      await coord.runRefresh(routine());
      final lines = AuthDiagnostics.entries.value;
      expect(lines, hasLength(2));
      expect(lines[0],
          contains('routine possiblySent:invalid_response'));
      expect(lines[0], contains('http=503'));
      expect(lines[0], contains('invalid=status'));
      expect(lines[1], contains('invalid=sub'));
      for (final l in lines) {
        expect(l, matches(RegExp(r'open=\d+ mark=\d+ send=\d+ reply=\d+')));
        for (final secret in [
          'refresh-1',
          _uid,
          'uid-b',
          store.committed!.tokenDispatches!.digest,
          if (digest != null) digest,
        ]) {
          expect(l, isNot(contains(secret)));
        }
      }
    });

    test('an IDENTITY cause after send cancels the op; nothing is installed',
        () async {
      await seed();
      script.holdResponse = Completer<void>();
      final f = coord.runRefresh(routine());
      while (script.sentTokens.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      egress.gate.advanceEpoch(EpochCause.accountSwitch);
      final out = await f;
      expect(out.kind, RefreshOutcomeKind.possiblySent);
      expect(sdk.current!.refreshToken, 'refresh-1');
      expect(store.committed!.refreshOp!.state, RefreshOpState.dispatchMarked);
    });

    test('a POLICY cause after send: custody only, no installation', () async {
      await seed();
      script.holdResponse = Completer<void>();
      final f = coord.runRefresh(routine());
      while (script.sentTokens.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      egress.gate.advanceEpoch(EpochCause.consentLoss);
      script.holdResponse!.complete();
      final out = await f;
      expect(out.kind, RefreshOutcomeKind.committed);
      expect(out.noInstall, isTrue);
      expect(out.installed, isFalse);
      expect(store.committed!.sdkSession!.refreshToken, 'refresh-2');
      expect(sdk.current!.refreshToken, 'refresh-1');
    });

    test('a POLICY cause before send: not sent', () async {
      await seed();
      final hold = Completer<void>();
      final f = coord.runRefresh(RefreshOpSpec(
          kind: RefreshOpKind.routine,
          deadline: const Duration(seconds: 30),
          preSend: () async {
            await hold.future;
            return true;
          }));
      while (store.committed!.refreshOp?.state != RefreshOpState.dispatchMarked) {
        await Future<void>.delayed(Duration.zero);
      }
      egress.gate.advanceEpoch(EpochCause.consentLoss);
      hold.complete();
      final out = await f;
      expect(out.kind, RefreshOutcomeKind.notSent);
      expect(script.sentTokens, isEmpty);
      expect(store.committed!.tokenDispatches!.count, 1,
          reason: 'markedNotSent consumes the count');
    });

    test('routine refuses a requiresAdoption record and local read', () async {
      await seed(admission: AdmissionDisposition.requiresAdoption);
      expect((await coord.runRefresh(routine())).reason, 'requires_adoption');
      final r = await seed();
      expect(r.admission, AdmissionDisposition.ordinary);
      egress.gate.localReadActive = () => true;
      final out = await coord.runRefresh(routine());
      expect(out.kind, RefreshOutcomeKind.denied);
      expect(script.opens, 0);
    });

    test('a removal during the op wins; the result is discarded', () async {
      await seed();
      script.holdResponse = Completer<void>();
      final f = coord.runRefresh(routine());
      while (script.sentTokens.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      final removed = coord.removal();
      script.holdResponse!.complete();
      expect((await f).kind, isNot(RefreshOutcomeKind.committed));
      expect(await removed, isTrue);
      expect(store.committed, isNull);
      expect(sdk.current, isNull);
      final reloaded = newStore();
      expect((await reloaded.load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('one op at a time; quiesced() waits for it', () async {
      await seed();
      script.holdResponse = Completer<void>();
      final f = coord.runRefresh(routine());
      await Future<void>.delayed(Duration.zero);
      expect((await coord.runRefresh(routine())).reason, 'busy');
      var quiet = false;
      final q = coord.quiesced().then((_) => quiet = true);
      while (script.sentTokens.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(quiet, isFalse);
      script.holdResponse!.complete();
      await f;
      await q;
      expect(quiet, isTrue);
    });

    test('Phase 4c B8: an unconfirmed transport closure latches for the '
        'process — every later exchange is refused, even after an explicit '
        'commit cleared the terminal denial', () async {
      await seed();
      script.quiesceError = const TransportCloseUnconfirmed();
      await coord.runRefresh(routine());
      expect(egress.gate.terminalDenied, isTrue);
      expect(coord.transportUnconfirmed, isTrue);
      expect(coord.refreshing, isFalse, reason: 'no hang: ticket released');
      script.quiesceError = null;
      final opens = script.opens;
      expect((await coord.runRefresh(routine())).reason,
          'transport_unconfirmed');
      // No authentication exchange starts beside the unconfirmed descriptor:
      // the explicit SDK callback is never invoked.
      var invoked = 0;
      final id = coord.registerAttemptIntent();
      await expectLater(
          coord.explicitExchange(id, () async => invoked++),
          throwsA(isA<ExplicitRefused>().having(
              (e) => e.reason, 'reason', 'transport_unconfirmed')));
      expect(invoked, 0);
      expect(coord.explicitExclusion, isNull);
      // Nor when the latch is set while the exchange waits for the section.
      await coord.quiesced();
      expect((await coord.runRefresh(routine())).reason,
          'transport_unconfirmed');
      expect(script.opens, opens, reason: 'no replacement exchange opened');
      expect(coord.transportUnconfirmed, isTrue);
    });

    test('Phase 4c B8: the latch is rechecked immediately before the explicit '
        'SDK call (set while the exchange waited for the section)', () async {
      await seed();
      script
        ..quiesceHold = Completer<void>()
        ..quiesceError = const TransportCloseUnconfirmed();
      // The op finished its section work and now awaits its (failing)
      // transport quiescence, outside the section.
      final op = coord.runRefresh(routine());
      while (script.sentTokens.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(coord.transportUnconfirmed, isFalse);
      // The explicit exchange passes its entry check and queues behind a busy
      // section; the op's failed closure sets the latch meanwhile.
      final busy = Completer<void>();
      final held = coord.section.run(() => busy.future);
      var invoked = 0;
      final id = coord.registerAttemptIntent();
      final ex = coord.explicitExchange(id, () async => invoked++);
      script.quiesceHold!.complete();
      await op;
      expect(coord.transportUnconfirmed, isTrue);
      busy.complete();
      await held;
      await expectLater(
          ex,
          throwsA(isA<ExplicitRefused>().having(
              (e) => e.reason, 'reason', 'transport_unconfirmed')));
      expect(invoked, 0);
      expect(coord.explicitExclusion, isNull);
    });

    test('refreshIfDue only near expiry', () async {
      await seed(expIn: 3600);
      expect(await coord.refreshIfDue(), isNull);
      await seed(expIn: 20);
      expect((await coord.refreshIfDue())!.kind, RefreshOutcomeKind.committed);
    });

    group('B10: routine continuation of a custody successor', () {
      /// A routine op that committed B but, after a POLICY cause past P_send,
      /// left SDK memory at A (custody only).
      Future<void> custody({int bExpIn = 3600}) async {
        await seed();
        final exp = _now() + bExpIn;
        script
          ..holdResponse = Completer<void>()
          ..result = () => RefreshHttpResult(
              statusCode: 200,
              json: sessionJson(uid: _uid, exp: exp, refreshToken: 'refresh-2')
                ..['expires_at'] = exp,
              isRedirect: false);
        final f = coord.runRefresh(routine());
        while (script.sentTokens.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        egress.gate.advanceEpoch(EpochCause.consentLoss);
        script.holdResponse!.complete();
        script.holdResponse = null;
        expect((await f).noInstall, isTrue);
        expect(sdk.current!.refreshToken, 'refresh-1');
      }

      test('distinguished from an SDK mutation; installed without network',
          () async {
        await custody();
        expect(coord.automaticAdmissionDenial(),
            AuthCoordinator.custodySuccessor);
        final opens = script.opens;
        final rotated = <RefreshReceipt>[];
        coord.onCredentialRotated = rotated.add;
        final out = await coord.refreshIfDue();
        expect(out!.kind, RefreshOutcomeKind.committed);
        expect(out.installed, isTrue);
        expect(script.opens, opens, reason: 'no network');
        final c = store.committed!;
        expect(sdk.current!.refreshToken, 'refresh-2');
        expect(coord.sdkBaseline, c.digest);
        expect(coord.automaticAdmissionDenial(), isNull);
        expect(rotated.single.digest, c.digest);
      });

      test('only under the routine policy', () async {
        await custody();
        coord.routinePermitted = () async => false;
        expect(await coord.refreshIfDue(), isNull);
        expect(sdk.current!.refreshToken, 'refresh-1');
        expect(coord.automaticAdmissionDenial(),
            AuthCoordinator.custodySuccessor);
      });

      test('Phase 4c B10: a policy cause while the policy check is awaited '
          'refuses the continuation', () async {
        await custody();
        coord.routinePermitted = () async {
          egress.gate.advanceEpoch(EpochCause.consentLoss);
          return true;
        };
        final out = await coord.refreshIfDue();
        expect(out!.kind, RefreshOutcomeKind.denied);
        expect(out.reason, 'continuation_policy');
        expect(sdk.current!.refreshToken, 'refresh-1');
        expect(coord.automaticAdmissionDenial(),
            AuthCoordinator.custodySuccessor);
      });

      test('Phase 4c B10: a policy cause while waiting for the section '
          'refuses the continuation (revalidated right before install)',
          () async {
        await custody();
        coord.routinePermitted = () async => true;
        final busy = Completer<void>();
        final held = coord.section.run(() => busy.future);
        final f = coord.refreshIfDue();
        await Future<void>.delayed(Duration.zero);
        egress.gate.advanceEpoch(EpochCause.consentLoss);
        busy.complete();
        await held;
        final out = await f;
        expect(out!.reason, 'continuation_policy');
        expect(sdk.current!.refreshToken, 'refresh-1');
      });

      test('an unattributed SDK change is a mismatch, never continued',
          () async {
        await custody();
        sdk.current = Session.fromJson(sessionJson(
            uid: _uid, exp: _now() + 3600, refreshToken: 'elsewhere'));
        expect(coord.automaticAdmissionDenial(), 'sdk_mismatch');
        expect(await coord.refreshIfDue(), isNull);
        expect(sdk.current!.refreshToken, 'elsewhere');
      });

      test('a record not committed by this lineage is a mismatch', () async {
        await seed();
        // B written by something other than a coordinator refresh.
        final c = store.committed!;
        expect(
            await store.write(c.copyWith(
                seq: c.seq + 1,
                session: canonicalSession(sessionJson(
                    uid: _uid, exp: _now() + 3600, refreshToken: 'other')))),
            WriteOutcome.committed);
        expect(coord.automaticAdmissionDenial(), 'sdk_mismatch');
        expect(await coord.refreshIfDue(), isNull);
      });

      test('a due custody successor is refreshed and installed via lineage',
          () async {
        await custody(bExpIn: 80); // valid (> 60 s) but within the lead
        script.result = () => ChannelScript.ok(token: 'refresh-3');
        final out = await coord.refreshIfDue();
        expect(out!.kind, RefreshOutcomeKind.committed);
        expect(out.installed, isTrue);
        expect(script.sentTokens.last, 'refresh-2');
        expect(sdk.current!.refreshToken, 'refresh-3');
        expect(coord.automaticAdmissionDenial(), isNull);
      });
    });
  });

  group('account-control refresh (§3.5, V3)', () {
    test('requires the delete/cancel grant; Cloud OFF works', () async {
      final off = TestEgress().install();
      coord = AuthCoordinator(
          store: store,
          gate: off.gate,
          channelFactory: () => FakeChannel(script))
        ..attach(sdk);
      await seed();
      expect((await coord.refreshForAccountControl(
              ordinaryAdmissionHeld: () => true))!
          .kind,
          RefreshOutcomeKind.denied);
      final out = await off.gate.runAccountControl(
          AccountControlOp.deleteAccount,
          () => coord.refreshForAccountControl(
              ordinaryAdmissionHeld: () => true));
      expect(out!.kind, RefreshOutcomeKind.committed);
      expect(store.committed!.admission, AdmissionDisposition.ordinary);
    });

    test('without a held ordinary admission the commit requires adoption',
        () async {
      await seed();
      var rotated = 0;
      coord.onCredentialRotated = (_) => rotated++;
      final out = await egress.gate.runAccountControl(
          AccountControlOp.cancelDelete,
          () => coord.refreshForAccountControl(
              ordinaryAdmissionHeld: () => false));
      expect(out!.kind, RefreshOutcomeKind.committed);
      // §4.10: installed while the grant is active (the RPC needs the fresh
      // token), but no admission follows and no rotation is announced.
      expect(out.installed, isTrue);
      expect(rotated, 0);
      expect(store.committed!.admission, AdmissionDisposition.requiresAdoption);
      expect(coord.automaticAdmissionDenial(), 'requires_adoption');
    });
  });

  group('explicit attempts (§4.4, §4.6)', () {
    Session signedIn() => Session.fromJson(
        sessionJson(uid: 'uid-b', exp: _now() + 3600, refreshToken: 'rb'))!;

    test('exchange sets the exclusion; commit writes lifecycle+1, ordinary',
        () async {
      final old = await seed();
      final id = coord.registerAttemptIntent();
      await coord.explicitExchange(id, () async {
        expect(coord.explicitExclusion, id);
        sdk.current = signedIn();
        sdk.emit(AuthChangeEvent.signedIn);
      });
      expect(coord.explicitExclusion, id, reason: 'held until commit');
      expect(coord.automaticAdmissionDenial(), 'explicit_exclusion');
      final r = await coord.commitExplicit(id, attemptCurrent: () => true);
      expect(r, isNotNull);
      expect(r!.lifecycle, old.lifecycle + 1);
      expect(r.owner, 'uid-b');
      expect(r.admission, AdmissionDisposition.ordinary);
      expect(coord.explicitExclusion, isNull);
      expect(coord.sdkBaseline, r.digest);
      expect(coord.automaticAdmissionDenial(), isNull);
    });

    test('events during the exchange are tagged explicit', () async {
      await seed();
      final tags = <AuthTag?>[];
      sdk.syncEvents.listen((s) => tags.add(coord.tagOf(s)));
      final id = coord.registerAttemptIntent();
      await coord.explicitExchange(id, () async {
        sdk.current = signedIn();
        sdk.emit(AuthChangeEvent.signedIn);
      });
      expect(tags.single!.kind, AuthTagKind.explicit);
      expect(coord.unattributedMutation, isFalse);
    });

    test('a stale attempt is refused and memory aligned', () async {
      await seed(expIn: 3600);
      final id = coord.registerAttemptIntent();
      await coord.explicitExchange(id, () async {
        sdk.current = signedIn();
        sdk.emit(AuthChangeEvent.signedIn);
      });
      final r = await coord.commitExplicit(id, attemptCurrent: () => false);
      expect(r, isNull);
      expect(coord.explicitExclusion, isNull);
      expect(sdk.current!.user.id, isNot('uid-b'),
          reason: 'memory realigned to the committed record');
    });

    test('a removal after the attempt began refuses the exchange', () async {
      await seed();
      final id = coord.registerAttemptIntent();
      coord.beginRemovalIntent();
      await expectLater(
          coord.explicitExchange(id, () async {}), throwsA(isA<ExplicitRefused>()));
    });

    test('a refused exchange aligns, then releases the exclusion', () async {
      await seed(expIn: 3600);
      final id = coord.registerAttemptIntent();
      await expectLater(
          coord.explicitExchange(id, () async => throw const AuthException('x')),
          throwsA(isA<AuthException>()));
      expect(coord.explicitExclusion, isNull);
    });
  });

  group('tags and automatic admission (§4.5, §4.7)', () {
    test('an unattributed session event is reported and denies', () async {
      await seed();
      final seen = <AuthState>[];
      coord.onUnattributedMutation = seen.add;
      sdk.current = Session.fromJson(
          sessionJson(uid: _uid, exp: _now() + 999, refreshToken: 'x'));
      sdk.emit(AuthChangeEvent.tokenRefreshed);
      expect(seen, hasLength(1));
      expect(coord.tagOf(seen.single)!.kind, AuthTagKind.unattributed);
      expect(coord.automaticAdmissionDenial(), 'unattributed');
    });

    test('init bracket tags the initial event', () async {
      final r = await seed(inSdk: false);
      final tags = <AuthTag?>[];
      sdk.syncEvents.listen((s) => tags.add(coord.tagOf(s)));
      coord.beginInit();
      sdk.current = r.sdkSession;
      sdk.emit(AuthChangeEvent.initialSession);
      coord.endInit(served: r);
      expect(tags.single!.kind, AuthTagKind.init);
      expect(coord.automaticAdmissionDenial(), isNull);
    });

    test('denials: requiresAdoption, dead, SDK mismatch, ASR exclusion',
        () async {
      await seed(admission: AdmissionDisposition.requiresAdoption);
      expect(coord.automaticAdmissionDenial(), 'requires_adoption');
      await seed();
      expect(coord.automaticAdmissionDenial(), isNull);
      coord.setAsrExclusion('op');
      expect(coord.automaticAdmissionDenial(), 'asr_exclusion');
      coord.releaseAsrExclusion('op');
      sdk.current = null;
      expect(coord.automaticAdmissionDenial(), 'sdk_mismatch');
    });
  });

  group('alignment (§4.8)', () {
    test('fresh same-owner record → silent recover', () async {
      await seed(expIn: 3600);
      sdk.current = null;
      expect(await coord.align(), isTrue);
      expect(sdk.current, isNotNull);
      expect(sdk.signOuts, 0);
    });

    test('otherwise local sign-out; its server call is denied in the zone',
        () async {
      await seed(expIn: 3600, admission: AdmissionDisposition.requiresAdoption);
      expect(await coord.align(), isTrue);
      expect(sdk.current, isNull);
      expect(sdk.signOuts, 1);
      expect(sdk.serverSignOutError, isA<EgressDeniedException>());
      expect((sdk.serverSignOutError! as EgressDeniedException).reason,
          'alignment');
      expect(coord.sdkBaseline, emptyDigest);
    });
  });
}
