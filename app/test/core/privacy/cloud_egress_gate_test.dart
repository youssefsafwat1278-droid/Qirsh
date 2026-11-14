import 'dart:async';
import 'dart:convert';

import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/cloud_egress_gate.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';

import '../../harness/egress_test_support.dart';

/// Astra G P1 / C.4: the durable denial state and the ONE admission gate.
void main() {
  late TestEgress egress;
  late CloudEgressGate gate;

  Future<void> putOn({String owner = 'uid-a', int gen = 1}) async {
    await gate.writeRecord(CloudEgressRecord(
        state: EgressState.on,
        ownerUid: owner,
        transitionGeneration: gen,
        reservedVersion: 1));
  }

  setUp(() {
    egress = TestEgress().install();
    gate = egress.gate;
  });

  Future<Object?> admitError([EgressGrant? grant]) async {
    try {
      final t = await gate.admit(grant: grant);
      gate.release(t);
      return null;
    } on EgressDeniedException catch (e) {
      return e.reason;
    }
  }

  test('native queue failures retain only safe diagnostics in readout and freeze', () async {
    for (final error in [
      const CaptureQueueException('private-code', 'secret-message'),
      const CaptureQueueException('channel_unavailable', 'secret-message'),
      CaptureQueueException('queue_unavailable', 'secret-message',
          CaptureSnapshotDiagnostic.parse({'contract': 'snapshot_v1', 'stage': 'activeowner', 'category': 'decode'})),
    ]) {
      egress = TestEgress(native: NativeEgressSlot(
          read: (_) async => throw error, write: (_) async {})).install();
      gate = egress.gate;
      final read = await gate.store.read();
      expect(read.uncertain, isTrue);
      expect(read.problems, ['native:${error.safeDiagnostic}']);
      expect(read.problems.join(), isNot(contains('secret')));
      expect(read.problems.join(), isNot(contains('private')));
      expect(await admitError(), 'state_uncertain');
    }
  });

  test('ON refuses an older-generation higher version without changing bytes',
      () async {
    const older = CloudEgressRecord(
        state: EgressState.off,
        ownerUid: 'uid-a',
        transitionGeneration: 20,
        reservedVersion: 9);
    final bytes = jsonEncode({
      'v': 1,
      'records': {'uid-a': older.toJson()}
    });
    egress.secure.value = bytes;
    egress.file.value = bytes;
    final result = await gate.store.writeDartLayers(const CloudEgressRecord(
        state: EgressState.on,
        ownerUid: 'uid-a',
        transitionGeneration: 31,
        reservedVersion: 3));
    expect(result.all, isFalse);
    expect(egress.secure.value, bytes);
    expect(egress.file.value, bytes);
    expect(egress.secure.writes + egress.file.writes, 0);
  });

  test('restriction and compensation retain the maximum physical version', () async {
    CloudEgressRecord record(EgressState state, int gen, int version) => CloudEgressRecord(
        state: state, ownerUid: 'uid-a', transitionGeneration: gen, reservedVersion: version);
    String bytes(CloudEgressRecord r) => jsonEncode({'v': 1, 'records': {'uid-a': r.toJson()}});
    egress.secure.value = bytes(record(EgressState.on, 30, 3));
    egress.file.value = bytes(record(EgressState.off, 20, 9));
    final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 1);
    expect(freeze.reservedVersion, 9);
    var layers = await gate.store.readDartOwnerLayers('uid-a');
    expect(layers.records.every((r) => r.state == EgressState.disabling && r.reservedVersion == 9), isTrue);
    final compensated = await gate.store.restrictOwnerLayers(record(EgressState.on, freeze.transitionGeneration, 1));
    expect(compensated.all, isTrue);
    layers = await gate.store.readDartOwnerLayers('uid-a');
    expect(layers.records.every((r) => r.state == EgressState.off && r.reservedVersion == 9), isTrue);
    final off = await gate.store.writeUnlessNewer(record(EgressState.off, freeze.transitionGeneration + 1, 0));
    expect(off!.all, isTrue);
    expect((await gate.store.readDartOwnerLayers('uid-a')).records.every((r) => r.reservedVersion == 9), isTrue);
  });

  group('admission', () {
    test('no record (never enabled) and OFF deny automatic traffic', () async {
      expect(await admitError(), 'off');
      await gate.writeRecord(const CloudEgressRecord(
          state: EgressState.off,
          ownerUid: 'uid-a',
          transitionGeneration: 2,
          reservedVersion: 2));
      expect(await admitError(), 'off');
    });

    test('ON admits, and registers the request in the in-flight set', () async {
      await putOn();
      final t = await gate.admit();
      expect(gate.inFlightCount, 1);
      gate.release(t);
      expect(gate.inFlightCount, 0);
    });

    test('no request newly passes admission after DISABLING began, including '
        'concurrent attempts', () async {
      await putOn();
      final admittedBefore = <EgressTicket>[];
      final outcomes = <String>[];
      Future<void> attempt(String label) async {
        try {
          final t = await gate.admit();
          admittedBefore.add(t);
          outcomes.add('$label:admitted');
        } on EgressDeniedException {
          outcomes.add('$label:denied');
        }
      }

      final early = [for (var i = 0; i < 5; i++) attempt('early$i')];
      final disabling =
          gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      final late = [for (var i = 0; i < 20; i++) attempt('late$i')];
      await Future.wait([...early, disabling, ...late]);

      expect(outcomes.where((o) => o.startsWith('late')),
          everyElement(endsWith(':denied')));
      expect(outcomes.where((o) => o.startsWith('early')),
          everyElement(endsWith(':admitted')),
          reason: 'queued BEFORE the disable: admitted before DISABLING');
      // And everything after the durable write, from any caller:
      expect(await admitError(), 'disabling');
      expect(egress.secure.value, contains('DISABLING'));
      expect(egress.file.value, contains('DISABLING'));
    });

    test('a corrupt store denies egress', () async {
      await putOn();
      egress.file.value = '{not json';
      expect(await admitError(), 'state_uncertain');
      expect(await gate.permits(), isFalse);
      egress.file.value = '{"v":1,"records":{"uid-a":{"state":"BOGUS"}}}';
      expect(await admitError(), 'state_uncertain');
    });

    test('an unreadable store denies egress (either store)', () async {
      await putOn();
      egress.secure.failReads = true;
      expect(await admitError(), 'state_uncertain');
      egress.secure.failReads = false;
      egress.file.failReads = true;
      expect(await admitError(), 'state_uncertain');
      egress.file.failReads = false;
      expect(await admitError(), isNull, reason: 'a clean read admits again');
    });

    test('the in-process freeze denies everything but the revoke', () async {
      await putOn();
      ConsentAuthority.egressFrozen = true;
      expect(await admitError(), 'frozen');
      ConsentAuthority.egressFrozen = false;
    });
  });

  group('the only exceptions', () {
    test(
        'automatic traffic is never admitted in OFF/unset; an account-control '
        'grant is not an automatic exception (see account_control_test)',
        () async {
      expect(await admitError(), 'off');
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await admitError(), 'disabling');
    });

    test('the revoke is admitted only in DISABLING and only for its own owner '
        'and generation', () async {
      await putOn();
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await admitError(freeze.revokeGrant), isNull);
      expect(
          await admitError(
              const EgressGrant.revoke(owner: 'uid-b', generation: 2)),
          'disabling');
      expect(
          await admitError(
              const EgressGrant.revoke(owner: 'uid-a', generation: 99)),
          'disabling');
      await gate.commitOff(freeze);
      expect(await admitError(freeze.revokeGrant), 'revoke_outside_disabling');
    });
  });

  // P3 (2026-11-14): the sign-out unlink only narrows server state, so it is
  // admitted after sign-out set the lifecycle fence, under a freeze and over
  // a DISABLING record, but only as the unlink POST for its own owner.
  group('the sign-out device unlink grant', () {
    const unlinkUrl =
        'https://example.supabase.co/functions/v1/unlink-capture-device';
    Future<Object?> admitUnlink(
        {String owner = 'uid-a',
        String method = 'POST',
        String url = unlinkUrl}) async {
      try {
        final t = await gate.admit(
            grant: EgressGrant.deviceUnlink(owner: owner),
            request: AdmissionRequest(method, Uri.parse(url)));
        gate.release(t);
        return null;
      } on EgressDeniedException catch (e) {
        return e.reason;
      }
    }

    test('admitted after the lifecycle fence, under a freeze and in DISABLING; '
        'ordinary egress stays denied', () async {
      await putOn();
      gate.denyForLifecycleLoss();
      expect(await admitUnlink(), isNull);
      expect(await admitError(), isNotNull);
      ConsentAuthority.egressFrozen = true;
      addTearDown(() => ConsentAuthority.egressFrozen = false);
      expect(await admitUnlink(), isNull);
      gate.releaseLifecycleDenial();
      ConsentAuthority.egressFrozen = false;
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await admitUnlink(), isNull);
      expect(await admitError(), isNotNull);
    });

    test('only the unlink POST over https to the backend host', () async {
      await putOn();
      for (final (method, url) in const [
        ('GET', unlinkUrl),
        ('POST', 'https://example.supabase.co/functions/v1/parse-sms'),
        ('POST', 'https://example.supabase.co/functions/v1/sync-captures'),
        ('POST', 'https://example.supabase.co/rest/v1/user_settings'),
        ('POST', 'http://example.supabase.co/functions/v1/unlink-capture-device'),
        ('POST', 'https://evil.example/functions/v1/unlink-capture-device'),
      ]) {
        expect(await admitUnlink(method: method, url: url), 'unlink_scope',
            reason: '$method $url');
      }
    });

    test('a request without a URL is denied', () async {
      await putOn();
      try {
        final t =
            await gate.admit(grant: const EgressGrant.deviceUnlink(owner: 'uid-a'));
        gate.release(t);
        fail('admitted without a request');
      } on EgressDeniedException catch (e) {
        expect(e.reason, 'unlink_scope');
      }
    });
  });

  // Approved 2026-11-12 (product owner): the ONE automatic exception to the
  // Cloud-OFF rule is re-sending a revoke that did not land, identifiers only,
  // for its own owner, while OFF at its own generation, to the revoke route.
  group('the revoke retry (approved narrow exception)', () {
    Future<Object?> admitRetry(EgressGrant grant,
        {String method = 'POST',
        String url = 'https://example.supabase.co/functions/v1/set-device-consent'}) async {
      try {
        final t = await gate.admit(
            grant: grant, request: AdmissionRequest(method, Uri.parse(url)));
        gate.release(t);
        return null;
      } on EgressDeniedException catch (e) {
        return e.reason;
      }
    }

    Future<DisableFreeze> offAfterOn() async {
      await putOn();
      final freeze =
          await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await gate.commitOff(freeze);
      return freeze;
    }

    EgressGrant retryOf(DisableFreeze f, {String? owner, int? generation}) =>
        EgressGrant.revokeRetry(
            owner: owner ?? f.owner,
            generation: generation ?? f.transitionGeneration);

    test('admitted only while OFF at the revoke\'s own generation', () async {
      final freeze = await offAfterOn();
      expect(await admitRetry(retryOf(freeze)), isNull);
      // ordinary traffic stays blocked
      expect(await admitError(), 'off');
      // the one-shot grant is still DISABLING-only
      expect(await admitError(freeze.revokeGrant), 'revoke_outside_disabling');
    });

    test('never for another owner or another generation', () async {
      final freeze = await offAfterOn();
      expect(await admitRetry(retryOf(freeze, owner: 'uid-b')),
          'revoke_retry_superseded');
      expect(
          await admitRetry(
              retryOf(freeze, generation: freeze.transitionGeneration - 1)),
          'revoke_retry_superseded');
    });

    test('a newer grant supersedes it (Off -> On), and so does a newer Off',
        () async {
      final freeze = await offAfterOn();
      await gate.enable(owner: 'uid-a', reservedVersion: 3);
      expect(await admitRetry(retryOf(freeze)), 'revoke_retry_superseded');
      final again =
          await gate.beginDisabling(owner: 'uid-a', reservedVersion: 4);
      expect(await admitRetry(retryOf(freeze)), 'revoke_retry_superseded',
          reason: 'DISABLING of a newer transition');
      await gate.commitOff(again);
      expect(await admitRetry(retryOf(freeze)), 'revoke_retry_superseded');
      expect(await admitRetry(retryOf(again)), isNull);
    });

    test('a pending enable denies it', () async {
      final freeze = await offAfterOn();
      gate.freezeEnable('uid-a');
      expect(await admitRetry(retryOf(freeze)), 'pending_enable');
    });

    test('only the revoke POST: any other route, method or scheme is denied',
        () async {
      final freeze = await offAfterOn();
      for (final (method, url) in const [
        ('GET', 'https://example.supabase.co/functions/v1/set-device-consent'),
        ('POST', 'https://example.supabase.co/functions/v1/parse-sms'),
        ('POST', 'https://example.supabase.co/functions/v1/sync-captures'),
        ('POST', 'https://example.supabase.co/rest/v1/user_settings'),
        ('POST', 'http://example.supabase.co/functions/v1/set-device-consent'),
        ('POST', 'https://evil.example/functions/v1/set-device-consent'),
      ]) {
        expect(await admitRetry(retryOf(freeze), method: method, url: url),
            'revoke_retry_scope',
            reason: '$method $url');
      }
    });

    test('not exempt from the in-process freeze or an uncertain state',
        () async {
      final freeze = await offAfterOn();
      ConsentAuthority.egressFrozen = true;
      expect(await admitRetry(retryOf(freeze)), 'frozen');
      ConsentAuthority.egressFrozen = false;
      egress.file.value = '{not json';
      expect(await admitRetry(retryOf(freeze)), 'state_uncertain');
    });
  });

  group('transition and reconciliation rules', () {
    test('the generation advances before the freeze; ON on enable is strictly '
        'greater; version too', () async {
      final on1 = await gate.enable(owner: 'uid-a', reservedVersion: 2);
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 3);
      expect(freeze.transitionGeneration, greaterThan(on1.transitionGeneration));
      expect(await gate.commitOff(freeze), isTrue);
      final off = (await gate.view(owner: 'uid-a')).record!;
      expect(off.state, EgressState.off);
      expect(off.transitionGeneration, freeze.transitionGeneration,
          reason: 'OFF at commit carries the SAME generation as DISABLING');
      final on2 = await gate.enable(owner: 'uid-a', reservedVersion: 4);
      expect(on2.transitionGeneration, greaterThan(off.transitionGeneration));
      expect(on2.reservedVersion, greaterThan(off.reservedVersion));
    });

    test('DISABLING in ONE store overrides its absence in the other', () async {
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      egress.file.value = null;
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling);
      expect(await admitError(), 'disabling');
    });

    test('a restrictive record beats ON in the other store; OFF (the commit) '
        'beats DISABLING at the same generation', () async {
      await gate.enable(owner: 'uid-a', reservedVersion: 2);
      final onJson = egress.file.value!;
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 3);
      egress.file.value = onJson; // the file still says ON
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling);
      await gate.commitOff(freeze);
      egress.secure.value = egress.secure.value!.replaceAll('"OFF"', '"DISABLING"');
      expect((await gate.view(owner: 'uid-a')).record!.state, EgressState.off);
    });

    test('a marker for owner A survives B\'s writes and is not applied to B',
        () async {
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      await gate.enable(owner: 'uid-b', reservedVersion: 5);
      expect((await gate.view(owner: 'uid-a')).record!.state,
          EgressState.disabling,
          reason: 'never silently discarded');
      expect((await gate.view(owner: 'uid-b')).record!.state, EgressState.on);
      egress.owner = 'uid-b';
      expect(await admitError(), isNull, reason: 'B is evaluated on its own');
      egress.owner = 'uid-a';
      expect(await admitError(), 'disabling');
    });

    test('failure to establish DISABLING in at least one store throws', () async {
      egress.secure.failWrites = true;
      egress.file.failWrites = true;
      await expectLater(
          gate.beginDisabling(owner: 'uid-a', reservedVersion: 2),
          throwsA(isA<EgressWriteFailedException>()));
      egress.file.failWrites = false;
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(freeze.transitionGeneration, 1);
    });

    test('enable needs EVERY store; a partial write cannot widen', () async {
      egress.file.failWrites = true;
      await expectLater(gate.enable(owner: 'uid-a', reservedVersion: 2),
          throwsA(isA<EgressWriteFailedException>()));
      expect(await admitError(), isNotNull);
    });
  });

  group('native (iOS) copy', () {
    test('a native DISABLING record overrides absence in the Dart stores',
        () async {
      CloudEgressRecord? nativeRec;
      final native = NativeEgressSlot(
        read: (owner) async => nativeRec?.ownerUid == owner ? nativeRec : null,
        write: (r) async => nativeRec = r,
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      nativeRec = const CloudEgressRecord(
          state: EgressState.disabling,
          ownerUid: 'uid-a',
          transitionGeneration: 3,
          reservedVersion: 3);
      expect(await admitError(), 'disabling');
    });

    test('another account\'s owner-scoped native uncertainty does not decide '
        'this account (L3)', () async {
      var throwForA = false;
      final native = NativeEgressSlot(
        read: (o) async {
          if (o == 'uid-a' && throwForA) {
            throw const FormatException('native_egress_uncertain:pending_held');
          }
          return null;
        },
        write: (_) async {},
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      await putOn(owner: 'uid-a');
      throwForA = true;
      expect((await gate.view(owner: 'uid-b')).uncertain, isFalse);
      expect((await gate.view(owner: 'uid-a')).uncertain, isTrue);
    });

    test('another account\'s GLOBAL native uncertainty still counts', () async {
      var throwForA = false;
      final native = NativeEgressSlot(
        read: (o) async {
          if (o == 'uid-a' && throwForA) {
            throw const FormatException(
                'native_egress_uncertain:egress_view_uncertain');
          }
          return null;
        },
        write: (_) async {},
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      await putOn(owner: 'uid-a');
      throwForA = true;
      expect((await gate.view(owner: 'uid-b')).uncertain, isTrue);
    });

    test('an unavailable / uncertain native store fails closed, and every '
        'write reaches it', () async {
      var fail = true;
      CloudEgressRecord? rec;
      final native = NativeEgressSlot(
        read: (o) async {
          if (fail) throw StateError('bridge unavailable');
          return rec;
        },
        write: (r) async => rec = r,
      );
      egress = TestEgress(native: native).install();
      gate = egress.gate;
      expect(await admitError(), 'state_uncertain');
      fail = false;
      final on = await gate.enable(owner: 'uid-a', reservedVersion: 2);
      expect(rec, on, reason: 'the iOS copy is written with the same record');
      expect(await admitError(), isNull);
    });
  });

  group('in-flight handling (C.4)', () {
    test('drain waits for an admitted request, then cancels what is still '
        'running (bounded)', () async {
      await putOn();
      final fast = await gate.admit();
      final slow = await gate.admit();
      Timer(const Duration(milliseconds: 20), () => gate.release(fast));
      final sw = Stopwatch()..start();
      final r = await gate.drain();
      expect(r.cancelled, 1);
      expect(slow.isCancelled, isTrue);
      expect(fast.isCancelled, isFalse);
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 150)),
          reason: 'it waited for the bound (200 ms in this harness)');
      expect(gate.inFlightCount, 0);
    });

    test('drain returns as soon as the set is empty', () async {
      await putOn();
      final t = await gate.admit();
      Timer(const Duration(milliseconds: 20), () => gate.release(t));
      final r = await gate.drain();
      expect(r.cancelled, 0);
      expect(t.isCancelled, isFalse);
    });

    test('an in-flight transport that returns after the transition has no '
        'effect: its response is discarded', () async {
      await putOn();
      final inner = Completer<http.Response>();
      final client = GatedHttpClient(MockClient((_) => inner.future));
      final call = client.get(Uri.parse('https://x.invalid/a'));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(gate.inFlightCount, 1);
      gate.advanceEpoch(); // disable / enable / account switch began
      inner.complete(http.Response('{"ok":true}', 200));
      await expectLater(call, throwsA(isA<EgressDeniedException>()));
      expect(gate.inFlightCount, 0);
    });

    test('a request still running at the drain bound is cancelled and its '
        'caller gets an error, not a result', () async {
      await putOn();
      final client = GatedHttpClient(MockClient((_) async {
        await Future<void>.delayed(const Duration(seconds: 5));
        return http.Response('late', 200);
      }));
      final call = client.get(Uri.parse('https://x.invalid/a'));
      final caught = expectLater(call, throwsA(isA<EgressDeniedException>()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final r = await gate.drain();
      expect(r.cancelled, 1);
      await caught;
    });

    test('native extension uploads are waited for, bounded', () async {
      var polls = 0;
      final g = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 300),
        nativePoll: const Duration(milliseconds: 10),
        nativeInflight: (_) async {
          polls++;
          return (count: polls < 4 ? 1 : 0, latestDeadline: null);
        },
      );
      await g.drainNative('uid-a');
      expect(polls, 4);

      final stuck = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 120),
        nativePoll: const Duration(milliseconds: 10),
        nativeInflight: (_) async => (count: 3, latestDeadline: null),
      );
      final sw = Stopwatch()..start();
      await stuck.drainNative('uid-a');
      expect(sw.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)));
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));

      final unavailable = CloudEgressGate(
        store: egress.gate.store,
        nativeMaxWait: const Duration(milliseconds: 120),
        nativeInflight: (_) async => null,
      );
      final sw2 = Stopwatch()..start();
      await unavailable.drainNative('uid-a');
      expect(sw2.elapsed, greaterThanOrEqualTo(const Duration(milliseconds: 100)),
          reason: 'unavailable = wait out the whole bound');
    });
  });

  group('background / resume transports are the same gate', () {
    test('a gated transport sends nothing in DISABLING and after OFF, and '
        'sends again only after an explicit enable', () async {
      var sent = 0;
      final client = GatedHttpClient(MockClient((_) async {
        sent++;
        return http.Response('{}', 200);
      }));
      Future<bool> tryGet() async {
        try {
          await client.get(Uri.parse('https://x.invalid/bg'));
          return true;
        } on EgressDeniedException {
          return false;
        }
      }

      await putOn();
      expect(await tryGet(), isTrue);
      final freeze = await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(await tryGet(), isFalse);
      await gate.commitOff(freeze);
      expect(await tryGet(), isFalse);
      expect(sent, 1);
      await gate.enable(owner: 'uid-a', reservedVersion: 3);
      expect(await tryGet(), isTrue);
      expect(sent, 2);
    });

    test('the permit mirror drives the auto-refresh policy', () async {
      await putOn();
      final seen = <bool>[];
      gate.onPermitChanged = (p) async => seen.add(p);
      await gate.refresh();
      await gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
      expect(seen, [true, false]);
      expect(gate.permitsNetworkSync, isFalse);
    });
  });

  // P5 (2026-11-14): Cloud consent states (freeze, uncertain/unreadable view,
  // DISABLING, native uncertainty) no longer refuse account deletion; an
  // unresolved process and an owner mismatch still do.
  group('E6 immediate status: non-consent state still wins; consent state does not', () {
    final endpoint = Uri.parse('https://example.supabase.co/functions/v1/delete-account-immediate');
    final body = jsonEncode({'action': 'status', 'receipt_secret': 'A' * 43});
    for (final state in ['unresolved', 'frozen', 'uncertain', 'unreadable', 'owner-mismatch', 'disabling', 'native-unavailable', 'native-disabling']) {
      test('$state and an exact status grant', () async {
        NativeEgressSlot? native;
        if (state.startsWith('native-')) {
          native = NativeEgressSlot(read: (_) async {
            if (state == 'native-unavailable') throw StateError('bridge unavailable');
            return const CloudEgressRecord(state: EgressState.disabling, ownerUid: 'uid-a',
                transitionGeneration: 3, reservedVersion: 3);
          }, write: (_) async {});
        }
        final h = TestEgress(resolved: state != 'unresolved', native: native).install();
        if (state == 'frozen') ConsentAuthority.egressFrozen = true;
        if (state == 'uncertain') h.file.value = '{broken';
        if (state == 'unreadable') h.file.failReads = true;
        if (state == 'owner-mismatch') h.owner = 'uid-b';
        if (state == 'disabling') await h.gate.beginDisabling(owner: 'uid-a', reservedVersion: 2);
        var sent = 0;
        final client = GatedHttpClient(MockClient((_) async { sent++; return http.Response('{}', 200); }));
        addTearDown(() => ConsentAuthority.egressFrozen = false);
        final run = h.gate.runImmediateDeletion(action: ImmediateDeletionAction.status,
            owner: 'uid-a', activeOwner: 'uid-a', epoch: h.gate.epoch, isCurrent: () => true,
            functionUrl: endpoint, serializedBody: body,
            exchange: () => client.post(endpoint, headers: {'content-type': 'application/json'}, body: body));
        if (state == 'unresolved' || state == 'owner-mismatch') {
          await expectLater(run, throwsA(isA<EgressDeniedException>()));
          expect(sent, 0);
        } else {
          await run;
          expect(sent, 1);
        }
        expect(h.gate.inFlightCount, 0);
        expect(h.gate.permitsNetworkSync, isFalse);
      });
    }
  });

}
