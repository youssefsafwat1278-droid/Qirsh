import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/session_files.dart';
import 'package:money_companion/core/auth/session_keychain.dart';
import 'package:money_companion/core/auth/session_record.dart';
import 'package:money_companion/core/auth/session_store.dart';

import 'session_fixtures.dart';
import 'store_fakes.dart';

/// ASR v7.2 §6: storage tests ST1–ST9 and migration M1–M6, each in a fresh store
/// instance (a "process") over the same fakes.
void main() {
  final origin = Uri.parse('https://proj.supabase.co');
  final otherOrigin = Uri.parse('https://other.supabase.co');
  late Directory dir;
  late FakeKeychain keychain;
  late FakeLegacy legacy;
  bool? localData;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_store_');
    keychain = FakeKeychain();
    legacy = FakeLegacy();
    localData = true;
  });
  tearDown(() async => dir.delete(recursive: true));

  SessionStore process([Uri? o]) => SessionStore(
        keychain: keychain,
        files: SessionFiles(dir),
        origin: o ?? origin,
        legacy: legacy,
        localInstallDataPresent: () async => localData,
      );

  String legacyValue({String uid = 'u1', String iss = 'https://proj.supabase.co/auth/v1'}) {
    final j = sessionJson(uid: uid, exp: 2000000000);
    String b64(Object o) =>
        base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
    j['access_token'] =
        '${b64({'alg': 'none'})}.${b64({'sub': uid, 'exp': 2000000000, 'iss': iss})}.s';
    return jsonEncode(j);
  }

  SessionRecord fresh(SessionStore s, {String uid = 'u1',
      AdmissionDisposition admission = AdmissionDisposition.ordinary}) =>
      SessionRecord(
        ns: s.ns,
        installId: s.installId!,
        seq: s.nextSeqFloor + 1,
        lifecycle: s.lifecycleFloor + 1,
        kind: RecordKind.session,
        owner: uid,
        session: canonicalSession(sessionJson(uid: uid, exp: 2000000000)),
        admission: admission,
      );

  group('load classification', () {
    test('first launch, nothing anywhere → verified empty, marker created',
        () async {
      final s = process();
      final r = await s.load();
      expect(r.loadClass, LoadClass.verifiedEmpty);
      expect(s.installId, isNotNull);
      expect((await SessionFiles(dir).readInstallMarker()).value, s.installId);
    });

    test('ST9 protected data unavailable → deferred, nothing written', () async {
      keychain.protectedData = false;
      final r = await process().load();
      expect(r.loadClass, LoadClass.deferred);
      expect((await SessionFiles(dir).readInstallMarker()).isAbsent, isTrue);
    });

    test('ST8 item read unavailable → deferred (never absent)', () async {
      final s = process();
      await s.load();
      expect(await s.write(fresh(s)), WriteOutcome.committed);
      keychain.readStatus = KeychainStatus.unavailable;
      expect((await process().load()).loadClass, LoadClass.deferred);
    });

    test('ST3 malformed record → unknown provenance', () async {
      final s = process();
      await s.load();
      keychain.items[s.itemKey] = '{"v":2}';
      expect((await process().load()).loadClass, LoadClass.unknownProvenance);
    });

    test('classes: ordinary / finalizing / requiresAdoption / dead / barred',
        () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      expect((await process().load()).loadClass, LoadClass.valid);
      expect((await process().load()).served, isNotNull);

      Future<LoadResult> withRecord(SessionRecord Function(SessionRecord) f) async {
        final p = process();
        await p.load();
        final c = p.committed!;
        expect(await p.write(f(c).copyWith(seq: c.seq + 1)), WriteOutcome.committed);
        return process().load();
      }

      var r = await withRecord((c) => c.copyWith(
          adoption: () => const AdoptionRecord(
              state: AdoptionState.finalizing, lifecycle: 1, opId: 'o')));
      expect(r.loadClass, LoadClass.validFinalizing);
      expect(r.served, isNotNull);
      r = await withRecord((c) => c.copyWith(
          adoption: () => null,
          admission: AdmissionDisposition.requiresAdoption));
      expect(r.loadClass, LoadClass.validRequiresAdoption);
      expect(r.served, isNull);
      r = await withRecord((c) => c.copyWith(
          admission: AdmissionDisposition.ordinary,
          credential: CredentialState.dead));
      expect(r.loadClass, LoadClass.validDead);
      expect(r.served, isNull);
      r = await withRecord((c) => c.copyWith(
          credential: CredentialState.live,
          adoption: () => AdoptionRecord(
              state: AdoptionState.pending, lifecycle: c.lifecycle, opId: 'o')));
      expect(r.loadClass, LoadClass.validBarred);
      expect(r.served, isNull);
    });
  });

  group('Android unrecoverable item (Keystore key lost / damaged bytes)', () {
    Future<SessionStore> withSession() async {
      final s = process();
      await s.load();
      expect(await s.write(fresh(s)), WriteOutcome.committed);
      return s;
    }

    test('→ verified empty with a diagnostic, nothing served, item kept',
        () async {
      final s = await withSession();
      keychain.unrecoverable.add(s.itemKey);
      final r = await process().load();
      expect(r.loadClass, LoadClass.verifiedEmpty);
      expect(r.reason, 'record_unrecoverable');
      expect(r.record, isNull);
      expect(r.served, isNull);
      expect(keychain.items.containsKey(s.itemKey), isTrue,
          reason: 'never deleted by a load');
    });

    test('a transient error (not permanent) is still deferred', () async {
      await withSession();
      keychain.failNextReads = 1;
      expect((await process().load()).loadClass, LoadClass.deferred);
      expect((await process().load()).loadClass, LoadClass.valid);
    });

    test('never triggers a legacy import, even without a migration entry',
        () async {
      final s = await withSession();
      keychain.unrecoverable.add(s.itemKey);
      // Only the item's existence can forbid the import now (§6.6).
      await File('${dir.path}/session_migration.v1').delete();
      legacy.value = legacyValue(uid: 'u7');
      final readsBefore = legacy.reads;
      final r = await process().load();
      expect(r.loadClass, LoadClass.verifiedEmpty);
      expect(r.record, isNull);
      expect(legacy.reads, readsBefore, reason: 'legacy value never read');
    });

    test('the next explicit sign-in replaces it and survives a restart',
        () async {
      final s = await withSession();
      keychain.unrecoverable.add(s.itemKey);
      final p = process();
      expect((await p.load()).loadClass, LoadClass.verifiedEmpty);
      expect(await p.write(fresh(p, uid: 'u2')), WriteOutcome.committed);
      final again = await process().load();
      expect(again.loadClass, LoadClass.valid);
      expect(again.record!.owner, 'u2');
    });

    test('a sign-in after a removal fence is not fenced away', () async {
      final s = await withSession();
      expect(await s.remove(), isTrue);
      final q = process();
      await q.load();
      expect(await q.write(fresh(q, uid: 'u3')), WriteOutcome.committed);
      keychain.unrecoverable.add(s.itemKey);
      final p = process();
      expect((await p.load()).loadClass, LoadClass.verifiedEmpty);
      expect(await p.write(fresh(p, uid: 'u4')), WriteOutcome.committed);
      final again = await process().load();
      expect(again.loadClass, LoadClass.valid);
      expect(again.record!.owner, 'u4');
    });

    test('install marker lost: marker recreated, item not deleted', () async {
      final s = await withSession();
      keychain.unrecoverable.add(s.itemKey);
      await File('${dir.path}/install_marker.v1').delete();
      final p = process();
      expect((await p.load()).loadClass, LoadClass.verifiedEmpty);
      expect(p.installId, isNotNull);
      expect(keychain.items.containsKey(s.itemKey), isTrue);
    });
  });

  group('write linearization (§6.3)', () {
    test('ST1 ack lost after native success → reload adopts the new record',
        () async {
      final s = process();
      await s.load();
      final next = fresh(s);
      keychain.loseNextWriteReply = true;
      expect(await s.write(next), WriteOutcome.committed);
      expect(s.indeterminate, isFalse);
      expect(s.committed!.encode(), next.encode());
    });

    test('ST2 confirmed failed write → old record stays committed', () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      final before = s.committed!.encode();
      keychain.failNextWrite = true;
      final next = s.committed!.copyWith(seq: s.committed!.seq + 1);
      expect(await s.write(next), WriteOutcome.failed);
      expect(s.committed!.encode(), before);
      expect((await process().load()).record!.encode(), before);
    });

    test('ST5 unknown outcome with unresolved reload → indeterminate; later '
        'resolve adopts what is there', () async {
      final s = process();
      await s.load();
      keychain.unknownNextWriteDropped = true;
      keychain.readStatus = KeychainStatus.unavailable;
      expect(await s.write(fresh(s)), WriteOutcome.indeterminate);
      expect(s.indeterminate, isTrue);
      // While indeterminate, no further write is accepted.
      expect(await s.write(fresh(s)), WriteOutcome.indeterminate);
      keychain.readStatus = null;
      expect(await s.resolve(), isTrue);
      expect(s.committed, isNull, reason: 'the dropped write never landed');
    });

    test('sequence violations are programming errors', () async {
      final s = process();
      await s.load();
      expect(() => s.write(fresh(s).copyWith(seq: 9)), throwsStateError);
    });
  });

  group('removal (§6.4)', () {
    Future<SessionStore> withSession() async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      return s;
    }

    test('fence + tombstone → verified empty on reload', () async {
      final s = await withSession();
      expect(await s.remove(), isTrue);
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('tombstone fails, fence holds → the old record is void', () async {
      final s = await withSession();
      keychain.failNextWrite = true;
      expect(await s.remove(), isTrue);
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('fence and tombstone fail, delete succeeds → verified empty', () async {
      final s = await withSession();
      await File('${dir.path}/session_fence.v1').create();
      await Directory('${dir.path}/session_fence.v1.tmp').create();
      keychain.failNextWrite = true;
      expect(await s.remove(), isTrue);
      expect(keychain.items.containsKey(s.itemKey), isFalse);
    });

    test('ST4 all three fail → not durable, reported honestly', () async {
      final s = await withSession();
      await Directory('${dir.path}/session_fence.v1.tmp').create();
      keychain.failNextWrite = true;
      keychain.failDeletes = true;
      expect(await s.remove(), isFalse);
      expect(s.committed, isNotNull);
    });

    test('a record written after removal by the same install is accepted',
        () async {
      final s = await withSession();
      await s.remove();
      final p = process();
      await p.load();
      expect(await p.write(fresh(p, uid: 'u2')), WriteOutcome.committed);
      expect((await process().load()).loadClass, LoadClass.valid);
    });

    test('ST7 fences are kept per namespace', () async {
      final s = await withSession();
      await s.remove();
      final o = process(otherOrigin);
      await o.load();
      await o.write(fresh(o, uid: 'u9'));
      await o.remove();
      final fence = await SessionFiles(dir).readFence();
      expect(fence.value!.keys, containsAll([s.ns, o.ns]));
    });
  });

  group('ST6 install marker', () {
    test('marker mismatch → record voided', () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      await SessionFiles(dir).writeInstallMarker('another-install');
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('marker absent, record present, no local data → orphan deleted',
        () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      await File('${dir.path}/install_marker.v1').delete();
      localData = false;
      final p = process();
      expect((await p.load()).loadClass, LoadClass.verifiedEmpty);
      expect(keychain.items.containsKey(p.itemKey), isFalse);
    });

    test('marker absent, record present, local data present → voided', () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      await File('${dir.path}/install_marker.v1').delete();
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('marker malformed → unknown provenance, not regenerated', () async {
      await File('${dir.path}/install_marker.v1').writeAsString('[]');
      expect((await process().load()).loadClass, LoadClass.unknownProvenance);
      expect(await File('${dir.path}/install_marker.v1').readAsString(), '[]');
    });

    test('local-data probe unavailable → deferred', () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      await File('${dir.path}/install_marker.v1').delete();
      localData = null;
      expect((await process().load()).loadClass, LoadClass.deferred);
    });
  });

  group('migration (§6.6)', () {
    test('M1 valid legacy → imported as ordinary, legacy removed, never re-read',
        () async {
      legacy.value = legacyValue();
      final r = await process().load();
      expect(r.loadClass, LoadClass.valid);
      expect(r.record!.owner, 'u1');
      expect(legacy.value, isNull);
      expect(legacy.reads, 1);
      await process().load();
      expect(legacy.reads, 1, reason: 'value never read after cleanup');
      expect(legacy.blindRemoves, greaterThanOrEqualTo(2));
    });

    test('M1 wrong issuer / M5 key collision → not imported', () async {
      legacy.value = legacyValue(iss: 'https://other.supabase.co/auth/v1');
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('M1 corrupt legacy → unknown provenance, never imported later',
        () async {
      legacy.value = '{"access_token": 5}';
      expect((await process().load()).loadClass, LoadClass.unknownProvenance);
      legacy.value = legacyValue();
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
    });

    test('M2 crash after `importing` before the record → never imported',
        () async {
      final files = SessionFiles(dir);
      final p = process();
      await files.writeInstallMarker('i1');
      await files.writeMigrationEntry({}, p.ns, const MigrationEntry(
          state: MigrationState.importing, legacyCleanup: LegacyCleanup.pending));
      legacy.value = legacyValue();
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
      expect(legacy.reads, 0);
    });

    test('M3 record without marker entry → repaired, legacy NOT imported',
        () async {
      final s = process();
      await s.load();
      await s.write(fresh(s, uid: 'u7'));
      await File('${dir.path}/session_migration.v1').delete();
      legacy.value = legacyValue();
      final readsBefore = legacy.reads;
      final r = await process().load();
      expect(r.record!.owner, 'u7');
      expect(r.untrustedThisLaunch, isFalse);
      expect(legacy.reads, readsBefore, reason: 'the legacy value is not read');
      expect(legacy.value, isNull, reason: 'blind cleanup');
    });

    test('M6 repair not confirmed → record untrusted this launch', () async {
      final s = process();
      await s.load();
      await s.write(fresh(s));
      await File('${dir.path}/session_migration.v1').delete();
      await Directory('${dir.path}/session_migration.v1.tmp').create();
      final r = await process().load();
      expect(r.untrustedThisLaunch, isTrue);
      expect(r.served, isNull);
    });

    test('M4 a downgraded build\'s value is deleted blind, never imported',
        () async {
      await process().load(); // marker done, cleanup done
      legacy.value = legacyValue();
      expect((await process().load()).loadClass, LoadClass.verifiedEmpty);
      expect(legacy.reads, 1, reason: 'only the first-launch probe');
      expect(legacy.value, isNull);
    });
  });
}
