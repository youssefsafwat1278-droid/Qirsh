import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/replica_location.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import '../../core/session/recording_secure_storage.dart';

// WP-3a — the per-UID encrypted replica core. Real SQLCipher files in temp
// directories; secure storage is the plugin's in-memory mock.

/// A simulated process death: an Error, so the store's `on Exception` failure
/// handling does NOT swallow it and partial on-disk state is left exactly as a
/// kill would leave it.
class _Crash extends Error {}

const _uidA = 'uid-aaaa';
const _uidB = 'uid-bbbb';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late FlutterSecureStorage storage;
  var clock = DateTime.utc(2026, 10, 1);

  ReplicaStore store({
    String? marker,
    bool markerSet = true,
    String? crashAt,
  }) =>
      ReplicaStore(
        requireCreationAuthority: false,
        appSupportDirectory: support.path,
        now: () => clock,
        readOwnerMarker: markerSet ? () async => marker : null,
        debugAfterAdoptionStep: crashAt == null
            ? null
            : (step) async {
                if (step == crashAt) throw _Crash();
              },
      );

  ReplicaLocation legacyLoc() => ReplicaLocation(
        directory: support.path,
        dbFileName: ReplicaLocation.legacyDbFileName,
        keyName: ReplicaLocation.legacyKeyName,
      );

  /// A legacy shared DB as a v38 build left it: no replica_meta, one probe row.
  Future<void> makeLegacy({bool wal = false}) async {
    final db = await AppDatabase.open(location: legacyLoc());
    await db.customStatement('DROP TABLE replica_meta;');
    await db.customStatement('PRAGMA user_version = 38;');
    await db.customStatement('CREATE TABLE probe(v TEXT);');
    await db.customStatement("INSERT INTO probe(v) VALUES ('before');");
    if (wal) {
      await db.customSelect('PRAGMA journal_mode = WAL;').get();
      await db.customStatement("INSERT INTO probe(v) VALUES ('in-wal');");
      // Crash image: main file + live -wal, as a killed process leaves them.
      final snap = Directory(p.join(support.path, '_snap'))..createSync();
      for (final s in ['', '-wal', '-shm']) {
        final f = File('${legacyLoc().dbPath}$s');
        if (f.existsSync()) f.copySync(p.join(snap.path, p.basename(f.path)));
      }
      await db.close();
      for (final s in ['', '-wal', '-shm']) {
        final f = File('${legacyLoc().dbPath}$s');
        if (f.existsSync()) f.deleteSync();
      }
      for (final f in snap.listSync().whereType<File>()) {
        f.copySync(p.join(support.path, p.basename(f.path)));
      }
      snap.deleteSync(recursive: true);
      return;
    }
    await db.close();
  }

  Future<List<String>> probeRows(AppDatabase db) async =>
      (await db.customSelect('SELECT v FROM probe ORDER BY rowid;').get())
          .map((r) => r.read<String>('v'))
          .toList();

  bool exists(String path) => File(path).existsSync();
  String legacyAdopted() => '${legacyLoc().dbPath}.adopted';

  setUp(() {
    support = Directory.systemTemp.createTempSync('replica_store_test_');
    FlutterSecureStorage.setMockInitialValues({});
    storage = const FlutterSecureStorage();
    clock = DateTime.utc(2026, 10, 1);
  });

  tearDown(() {
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  group('layout, keys and ownership', () {
    test('two uids get two files and two keys and cannot open each other',
        () async {
      final s = store();
      final a = await s.openReplica(_uidA);
      await a.customStatement('CREATE TABLE probe(v TEXT);');
      await a.customStatement("INSERT INTO probe VALUES ('a-data');");
      await s.openReplica(_uidB);
      final ha = await s.uidHash(_uidA);
      final hb = await s.uidHash(_uidB);
      expect(ha, isNot(hb));
      expect(ha, hasLength(32));
      expect(ha, isNot(contains('aaaa')), reason: 'raw uid must not leak');

      expect(
          exists(p.join(support.path, 'replicas', ha, 'qirsh.sqlite')), isTrue);
      expect(
          exists(p.join(support.path, 'replicas', hb, 'qirsh.sqlite')), isTrue);
      final ka = await storage.read(key: 'qirsh.db_key.$ha');
      final kb = await storage.read(key: 'qirsh.db_key.$hb');
      expect(ka, isNotEmpty);
      expect(kb, isNotEmpty);
      expect(ka, isNot(kb));
      expect(await storage.read(key: ReplicaLocation.legacyKeyName), isNull,
          reason: 'a replica must never mint or touch the legacy key');

      // replica_meta carries the owner.
      final meta =
          await a.customSelect('SELECT owner_uid FROM replica_meta;').get();
      expect(meta.single.read<String>('owner_uid'), _uidA);

      // Put A's file (and A's key) where B's replica lives: the path and the key
      // both say "B", the file says "A" -> fail closed.
      await s.closeReplica(_uidA);
      await s.closeReplica(_uidB);
      File(p.join(support.path, 'replicas', ha, 'qirsh.sqlite'))
          .copySync(p.join(support.path, 'replicas', hb, 'qirsh.sqlite'));
      await storage.write(key: 'qirsh.db_key.$hb', value: ka!);
      await expectLater(store().openReplica(_uidB),
          throwsA(isA<ReplicaOwnershipException>()));
      // A is unharmed.
      final a2 = await store().openReplica(_uidA);
      expect(await probeRows(a2), ['a-data']);
      await a2.close();
    });

    test('an existing file with no replica_meta row is refused, not claimed',
        () async {
      final s = store();
      final a = await s.openReplica(_uidA);
      await a.customStatement('DELETE FROM replica_meta;');
      await s.closeReplica(_uidA);
      await expectLater(store().openReplica(_uidA),
          throwsA(isA<ReplicaOwnershipException>()));
    });

    test('replica_meta holds at most one row', () async {
      final a = await store().openReplica(_uidA);
      await expectLater(
        a.customStatement(
            "INSERT INTO replica_meta(id, owner_uid, replica_id, created_at) "
            "VALUES (2, 'x', 'y', 'z');"),
        throwsA(anything),
      );
      await a.close();
    });

    test('every sidecar path of a replica is inside its own directory', () {
      final loc = ReplicaLocation(
          directory: p.join(support.path, 'replicas', 'h'),
          dbFileName: 'qirsh.sqlite',
          keyName: 'qirsh.db_key.h');
      for (final path in [
        loc.dbPath,
        loc.walPath,
        loc.shmPath,
        loc.maintPath,
        loc.plockPath,
        loc.instancePath,
        loc.leaseDir,
      ]) {
        expect(p.isWithin(loc.directory, path), isTrue, reason: path);
      }
    });

    test('v39 migration adds replica_meta to a v38 database', () async {
      final db = await AppDatabase.open(executor: NativeDatabase.memory());
      await db.customStatement('DROP TABLE replica_meta;');
      await db.customStatement('PRAGMA user_version = 38;');
      await db.debugReinitialize();
      expect(
          (await db.customSelect('PRAGMA user_version;').getSingle())
              .read<int>('user_version'),
          44);
      expect(await db.count('replica_meta'), 0,
          reason: 'the migration never assigns an owner');
      await db.close();
    });
  });

  group('registry', () {
    test('round-trip, lock/unlock, and the device salt is stable', () async {
      final s = store();
      final db = await s.openReplica(_uidA);
      final h = await s.uidHash(_uidA);
      var entries = await s.list();
      expect(entries.single.uidHash, h);
      expect(entries.single.state, ReplicaState.active);
      expect(entries.single.schemaVersion, 44);
      expect(entries.single.createdAt, clock);

      clock = clock.add(const Duration(hours: 1));
      await s.closeReplica(_uidA);
      expect(await s.setState(_uidA, ReplicaState.locked), isTrue);
      await expectLater(
          s.openReplica(_uidA), throwsA(isA<ReplicaUnavailableException>()));
      expect(await s.setState(_uidA, ReplicaState.active), isTrue);
      final again = await s.openReplica(_uidA);
      entries = await s.list();
      expect(entries.single.lastOpenedAt, clock);
      expect(entries.single.createdAt, DateTime.utc(2026, 10, 1));
      expect(await s.setState('nobody', ReplicaState.locked), isFalse);

      // A new instance (new process) sees the same salt, hence same hash/registry.
      expect(await store().uidHash(_uidA), h);
      expect((await store().list()).single.state, ReplicaState.active);
      expect(await storage.read(key: 'qirsh.replicas.v1'), contains(h));
      await again.close();
      expect(db, isNotNull);
    });

    test('an unreadable registry is treated as empty and rebuilt on open',
        () async {
      final s = store();
      final db = await s.openReplica(_uidA);
      await s.closeReplica(_uidA);
      await storage.write(key: 'qirsh.replicas.v1', value: '{not json');
      expect(await store().list(), isEmpty);
      final again = await store().openReplica(_uidA);
      expect(await store().list(), hasLength(1));
      await again.close();
      expect(db, isNotNull);
    });
  });

  group('remove', () {
    test('removes only that uid\'s dir, key and entry; idempotent', () async {
      final s = store();
      await s.openReplica(_uidA);
      await s.openReplica(_uidB);
      final ha = await s.uidHash(_uidA);
      final hb = await s.uidHash(_uidB);

      await s.remove(_uidA);
      expect(Directory(p.join(support.path, 'replicas', ha)).existsSync(),
          isFalse);
      expect(await storage.read(key: 'qirsh.db_key.$ha'), isNull);
      expect((await s.list()).map((e) => e.uidHash), [hb]);
      expect(
          Directory(p.join(support.path, 'replicas', hb)).existsSync(), isTrue);
      expect(await storage.read(key: 'qirsh.db_key.$hb'), isNotNull);

      await s.remove(_uidA); // second time: no-op
      await s.remove('never-existed');
      expect((await s.list()).map((e) => e.uidHash), [hb]);
      // B still opens.
      expect(await (await s.openReplica(_uidB)).count('replica_meta'), 1);
    });

    test('a crash after the directory rename is finished on the next launch',
        () async {
      final s = store();
      await s.openReplica(_uidA);
      final h = await s.uidHash(_uidA);
      await s.closeReplica(_uidA);
      // State a kill leaves after step 1 (rename) of remove().
      Directory(p.join(support.path, 'replicas', h))
          .renameSync(p.join(support.path, 'replicas', '_removing.$h'));
      expect(await storage.read(key: 'qirsh.db_key.$h'), isNotNull);

      await store().recoverPendingRemovals();
      expect(
          Directory(p.join(support.path, 'replicas', '_removing.$h'))
              .existsSync(),
          isFalse);
      expect(await storage.read(key: 'qirsh.db_key.$h'), isNull);
      expect(await store().list(), isEmpty);
    });
  });

  group('session wipe', () {
    test('wipeSecureStoragePreservingDatabaseKey keeps every qirsh.* secret',
        () async {
      await storage.write(key: 'qirsh.db_key.abc', value: 'k');
      await storage.write(key: 'qirsh.replicas.v1', value: '{}');
      await storage.write(key: 'qirsh.device_salt', value: 's');
      await storage.write(key: 'some_session_key', value: 'gone');
      final r = await wipeSecureStoragePreservingDatabaseKey(
        readAll: storage.readAll,
        delete: (k) => storage.delete(key: k),
        knownKeys: {'qirsh.db_key.abc', 'some_session_key'},
      );
      expect(r.isComplete, isTrue);
      expect(await storage.read(key: 'qirsh.db_key.abc'), 'k');
      expect(await storage.read(key: 'qirsh.replicas.v1'), '{}');
      expect(await storage.read(key: 'qirsh.device_salt'), 's');
      expect(await storage.read(key: 'some_session_key'), isNull);
    });
  });

  group('legacy adoption', () {
    test('happy path: data copied, key copied, legacy renamed .adopted',
        () async {
      await makeLegacy();
      final legacyKey = await storage.read(key: ReplicaLocation.legacyKeyName);
      final s = store(marker: _uidA);
      expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.adopted);

      expect(exists(legacyLoc().dbPath), isFalse);
      expect(exists(legacyAdopted()), isTrue);
      final h = await s.uidHash(_uidA);
      expect(await storage.read(key: 'qirsh.db_key.$h'), legacyKey);
      expect(await storage.read(key: ReplicaLocation.legacyKeyName), legacyKey,
          reason: 'legacy key kept for the rollback grace');
      final e = (await s.list()).single;
      expect(e.state, ReplicaState.active);
      expect(e.adoptPending, isFalse);
      expect(e.legacyAdoptedAt, clock);
      expect(e.schemaVersion, 44);

      final db = await s.openReplica(_uidA);
      expect(await probeRows(db), ['before']);
      expect(
          (await db
                  .customSelect('SELECT owner_uid FROM replica_meta;')
                  .getSingle())
              .read<String>('owner_uid'),
          _uidA);
      await db.close();
      // Idempotent next launch.
      expect(await store(marker: _uidA).adoptLegacyIfPresent(),
          AdoptionOutcome.none);
    });

    test('the .adopted copy is still a complete, openable legacy database',
        () async {
      await makeLegacy();
      await store(marker: _uidA).adoptLegacyIfPresent();
      // The documented P2 rollback recovery: put the file back at the legacy path.
      File(legacyAdopted()).renameSync(legacyLoc().dbPath);
      final db =
          await AppDatabase.open(location: legacyLoc(), runMigrations: false);
      expect(await probeRows(db), ['before']);
      await db.close();
    });

    for (final step in kAdoptionSteps) {
      test('crash after "$step" -> next launch completes adoption, data intact',
          () async {
        await makeLegacy();
        await expectLater(
            store(marker: _uidA, crashAt: step).adoptLegacyIfPresent(),
            throwsA(isA<_Crash>()));

        final next = store(marker: _uidA);
        final outcome = await next.adoptLegacyIfPresent();
        expect(
            outcome,
            step == 'afterRename'
                ? AdoptionOutcome.none
                : AdoptionOutcome.adopted);

        expect(exists(legacyLoc().dbPath), isFalse);
        expect(exists(legacyAdopted()), isTrue);
        final e = (await next.list()).single;
        expect(e.state, ReplicaState.active);
        expect(e.adoptPending, isFalse);
        expect(e.legacyAdoptedAt, isNotNull);
        final db = await next.openReplica(_uidA);
        expect(await probeRows(db), ['before']);
        await db.close();
      });
    }

    test('a failure leaves the legacy file in place and in use', () async {
      await makeLegacy();
      await storage.delete(key: ReplicaLocation.legacyKeyName);
      final s = store(marker: _uidA);
      expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.failed);
      expect(exists(legacyLoc().dbPath), isTrue);
      expect(exists(legacyAdopted()), isFalse);
      expect((await s.list()).single.state, ReplicaState.migrating);
      await expectLater(
          s.openReplica(_uidA), throwsA(isA<ReplicaUnavailableException>()));
    });

    test('a half-built replica from a dead attempt is discarded and redone',
        () async {
      await makeLegacy();
      await expectLater(
          store(marker: _uidA, crashAt: 'afterReplicaMeta')
              .adoptLegacyIfPresent(),
          throwsA(isA<_Crash>()));
      // Garbage next to the half-built file must not survive the redo.
      final h = await store().uidHash(_uidA);
      File(p.join(support.path, 'replicas', h, 'stale.tmp'))
          .writeAsStringSync('x');
      await store(marker: _uidA).adoptLegacyIfPresent();
      expect(exists(p.join(support.path, 'replicas', h, 'stale.tmp')), isFalse);
    });

    test('WAL edge: rows only in the -wal are carried into the replica',
        () async {
      await makeLegacy(wal: true);
      expect(exists('${legacyLoc().dbPath}-wal'), isTrue,
          reason: 'fixture must really have an uncheckpointed WAL');
      final s = store(marker: _uidA);
      expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.adopted);
      final db = await s.openReplica(_uidA);
      expect(await probeRows(db), ['before', 'in-wal']);
      await db.close();
    });

    test(
        'a reappeared legacy file next to an active replica is never overwritten',
        () async {
      await makeLegacy();
      final s = store(marker: _uidA);
      await s.adoptLegacyIfPresent();
      final db = await s.openReplica(_uidA);
      await db.customStatement("INSERT INTO probe(v) VALUES ('newer');");
      await s.closeReplica(_uidA);
      File(legacyAdopted()).renameSync(legacyLoc().dbPath); // downgrade+upgrade
      expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.legacyLeftover);
      final again = await s.openReplica(_uidA);
      expect(await probeRows(again), ['before', 'newer']);
      await again.close();
    });
  });

  group('quarantine', () {
    for (final entry in <String, String?>{
      'no marker': null,
      'empty marker': '',
      'transition sentinel': 'owner-transition-pending:uid-old',
    }.entries) {
      test('${entry.key}: legacy file is quarantined, never adopted', () async {
        await makeLegacy();
        final s = store(marker: entry.value);
        expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.quarantined);

        expect(exists(legacyLoc().dbPath), isFalse);
        expect(exists(legacyAdopted()), isFalse);
        expect(await s.hasQuarantinedLegacyData(), isTrue);
        final q = Directory(p.join(support.path, 'replicas', '_quarantine'));
        final moved = q
            .listSync(recursive: true)
            .whereType<File>()
            .map((f) => p.basename(f.path));
        expect(moved, contains('money_companion.sqlite'));
        expect(await s.list(), isEmpty, reason: 'no registry entry, no owner');

        // Whoever signs in next gets a fresh, EMPTY replica, not this file.
        final db = await s.openReplica(_uidA);
        final t = await db
            .customSelect(
                "SELECT name FROM sqlite_master WHERE name = 'probe';")
            .get();
        expect(t, isEmpty);
        await db.close();
        expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.none);
      });
    }

    test('quarantine is never opened (works with the key absent)', () async {
      await makeLegacy();
      await storage.delete(key: ReplicaLocation.legacyKeyName);
      final s = store(marker: null);
      expect(await s.adoptLegacyIfPresent(), AdoptionOutcome.quarantined);
    });
  });

  group('.adopted grace (P2 rollback window)', () {
    test('kept for 7 days, then deleted together with the legacy key',
        () async {
      await makeLegacy();
      final s = store(marker: _uidA);
      await s.adoptLegacyIfPresent();
      expect(exists(legacyAdopted()), isTrue);

      clock = clock.add(const Duration(days: 6, hours: 23));
      await s.adoptLegacyIfPresent();
      expect(exists(legacyAdopted()), isTrue, reason: 'still inside the grace');
      expect(await storage.read(key: ReplicaLocation.legacyKeyName), isNotNull);

      clock = DateTime.utc(2026, 10, 8, 0, 0, 1);
      await s.adoptLegacyIfPresent();
      expect(exists(legacyAdopted()), isFalse);
      expect(await storage.read(key: ReplicaLocation.legacyKeyName), isNull);
      expect((await s.list()).single.legacyAdoptedAt, isNull);
      final db = await s.openReplica(_uidA);
      expect(await probeRows(db), ['before']);
      await db.close();
    });
  });

  // ---------------------------------------------------------------- F2 ------
  // Creating a replica needs a current admission authority that may create. A
  // missing registry entry, file or key is never permission. Every case asserts
  // that NOTHING was written (no file, no key, no registry entry).
  group('F2: open-existing vs create-with-authority', () {
    late RecordingSecureStorage rec;

    ReplicaStore strict() => ReplicaStore(
          appSupportDirectory: support.path,
          now: () => clock,
        );

    Future<List<String>> artifacts(ReplicaStore s, String uid) async {
      final h = await s.uidHash(uid);
      return [
        if (Directory(p.join(support.path, 'replicas', h)).existsSync()) 'dir',
        if (rec.data.containsKey('qirsh.db_key.$h')) 'key',
        if ((await s.list()).any((e) => e.uidHash == h)) 'registry',
      ];
    }

    setUp(() => rec = RecordingSecureStorage().install());

    test(
        'absent registry + file + key: no authority, stale, or non-creating '
        'authority all refuse BEFORE any effect', () async {
      final s = strict();
      await s.uidHash(_uidA); // the device salt exists; nothing else
      final before = rec.attempts.length;

      await expectLater(
          s.openReplica(_uidA), throwsA(isA<ReplicaMissingException>()));
      var live = true;
      final revocable = AdmissionAuthority(_uidA, () => live, canCreate: true);
      live = false;
      await expectLater(s.openReplica(_uidA, authority: revocable),
          throwsA(isA<StaleAdmissionException>()));
      await expectLater(
          s.openReplica(_uidA,
              authority:
                  const AdmissionAuthority.forTest(_uidA, canCreate: false)),
          throwsA(isA<ReplicaMissingException>()));
      await expectLater(
          s.openStaging(_uidA), throwsA(isA<ReplicaMissingException>()));

      expect(rec.attempts.skip(before), isEmpty, reason: 'no storage write');
      expect(await artifacts(s, _uidA), isEmpty);
    });

    test('a stale registry entry with no file is not permission to create',
        () async {
      final s = strict();
      await s.openReplica(_uidA,
          authority: const AdmissionAuthority.forTest(_uidA));
      await s.closeAll();
      final h = await s.uidHash(_uidA);
      Directory(p.join(support.path, 'replicas', h))
          .deleteSync(recursive: true); // registry + key survive, file gone
      await expectLater(
          strict().openReplica(_uidA), throwsA(isA<ReplicaMissingException>()));
      expect(
          Directory(p.join(support.path, 'replicas', h)).existsSync(), isFalse);
    });

    test(
        'a valid creating authority creates exactly once; reopening needs none',
        () async {
      final s = strict();
      final db = await s.openReplica(_uidA,
          authority: const AdmissionAuthority.forTest(_uidA));
      expect(await artifacts(s, _uidA), ['dir', 'key', 'registry']);
      final h = await s.uidHash(_uidA);
      expect(rec.attempts.where((a) => a.startsWith('write:qirsh.db_key.$h')),
          hasLength(1));
      await db.close();
      await s.closeAll();

      final relaunch = strict();
      final again = await relaunch.openReplica(_uidA); // open-existing only
      expect(again, isNotNull);
      expect(rec.attempts.where((a) => a.startsWith('write:qirsh.db_key.$h')),
          hasLength(1),
          reason: 'no second key');
      await relaunch.closeAll();
    });

    test(
        'an authority revoked after the existence check, before the open, '
        'creates nothing', () async {
      final s = strict();
      var live = true;
      final authority = AdmissionAuthority(_uidA, () => live, canCreate: true);
      // The device salt read happens between requireCurrent calls; revoke there.
      rec.gate = (op, key) async {
        if (op == 'read' && key == ReplicaStore.registryKey) live = false;
      };
      await expectLater(s.openReplica(_uidA, authority: authority),
          throwsA(isA<StaleAdmissionException>()));
      rec.gate = null;
      expect(await artifacts(s, _uidA), isEmpty);
    });

    test('staging creation follows the same rule', () async {
      final s = strict();
      await s.openReplica(_uidA,
          authority: const AdmissionAuthority.forTest(_uidA));
      await expectLater(
          s.openStaging(_uidA), throwsA(isA<ReplicaMissingException>()));
      final h = await s.uidHash(_uidA);
      expect(Directory(p.join(support.path, 'replicas', '$h.rb')).existsSync(),
          isFalse);
      expect(rec.data.containsKey('qirsh.db_key.$h.rb'), isFalse);
      final staging = await s.openStaging(_uidA,
          authority: const AdmissionAuthority.forTest(_uidA));
      expect(staging, isNotNull);
      await s.closeAll();
    });

    test(
        'an unrelated replica, its key and registry entry are untouched by a '
        'refused creation and by a removal', () async {
      final s = strict();
      await s.openReplica(_uidB,
          authority: const AdmissionAuthority.forTest(_uidB));
      await s.closeAll();
      final hB = await s.uidHash(_uidB);
      final keyB = rec.data['qirsh.db_key.$hB'];
      final entryB = (await s.list()).single.toJson();

      await expectLater(
          s.openReplica(_uidA), throwsA(isA<ReplicaMissingException>()));
      await s.remove(_uidA); // removing a uid that does not exist
      expect(rec.data['qirsh.db_key.$hB'], keyB);
      expect((await s.list()).single.toJson(), entryB);
      expect(
          Directory(p.join(support.path, 'replicas', hB)).existsSync(), isTrue);
    });

    test(
        'remove() drains an open already dispatched, so it cannot finish '
        'AFTER the deletion and recreate the replica or key', () async {
      final started = Completer<void>();
      final proceed = Completer<void>();
      final s = ReplicaStore(
        appSupportDirectory: support.path,
        opener: ({
          location,
          runMigrations = true,
          creation = const CreationPolicy.unrestricted(),
        }) async {
          started.complete();
          await proceed.future;
          return AppDatabase.open(
              location: location,
              runMigrations: runMigrations,
              creation: creation);
        },
      );
      final opening = s.openReplica(_uidA,
          authority: const AdmissionAuthority.forTest(_uidA));
      await started.future; // dispatched, held inside the opener
      var removed = false;
      final removal = s.remove(_uidA).then((_) => removed = true);
      for (var i = 0; i < 20; i++) {
        await Future<void>.value();
      }
      expect(removed, isFalse, reason: 'removal waits for the dispatched open');
      final rejected =
          expectLater(opening, throwsA(isA<StaleAdmissionException>()));
      proceed.complete();
      await rejected;
      await removal;
      expect(await artifacts(s, _uidA), isEmpty);
    });

    test(
        'a process-liveness handle for a deleted replica is not reused when '
        'it is explicitly recreated (fresh lock files)', () async {
      final loc = await strict().locationFor(_uidA);
      Directory(loc.directory).createSync(recursive: true);
      final first = await AppDatabase.initProcessLiveness(location: loc);
      expect(File(loc.plockPath).existsSync(), isTrue);
      AppDatabase.dropProcessLiveness(loc);
      Directory(loc.directory).deleteSync(recursive: true);

      Directory(loc.directory).createSync(recursive: true);
      final second = await AppDatabase.initProcessLiveness(location: loc);
      expect(identical(first, second), isFalse);
      expect(File(loc.plockPath).existsSync(), isTrue);
      expect(File(loc.instancePath).existsSync(), isTrue);
      AppDatabase.dropProcessLiveness(loc);
    });
  });
}
