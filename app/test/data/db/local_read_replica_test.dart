import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/uncoordinated_local_read.dart';
import 'package:money_companion/core/session/local_read_authority.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/creation_policy.dart';
import 'package:money_companion/data/db/database_lease.dart';
import 'package:money_companion/data/db/replica_store.dart';
import 'package:path/path.dart' as p;

import '../../core/session/recording_secure_storage.dart';

// Offline local read — the strict existing-replica verifier and the genuine
// SQLite read-only opener (core unit). Real SQLCipher files in temp
// directories; secure storage is the plugin's recording in-memory mock. These
// are HOST fixtures: they prove nothing about a simulator or device.

const _uid = 'uid-aaaa';
const _other = 'uid-bbbb';

/// Observes admission to the real file-lease protocol, without replacing it.
class _ObservedLeaseManager extends DatabaseLeaseManager {
  _ObservedLeaseManager({required super.leaseDir, required super.intentPath});

  int sharedAttempts = 0;

  @override
  Future<DatabaseFileLease> acquireShared() {
    sharedAttempts++;
    return super.acquireShared();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  late RecordingSecureStorage rec;
  late String? marker;
  final stores = <ReplicaStore>[];

  // Instrumentation of every read-only open/close the stores perform: each handle
  // the opener produced, how many opens ran at once, and optional pause points.
  final opened = <AppDatabase>[];
  var openCalls = 0;
  var openersActive = 0;
  var openersMax = 0;
  var closeCalls = 0;
  Future<void> Function(int call)? beforeOpen;
  Future<void> Function(int call)? beforeClose;
  Future<void> Function(AppDatabase db)? beforeFactoryClose;

  ReplicaStore store({
    Future<void> Function(String step)? crashAt,
  }) {
    final s = ReplicaStore(
      requireCreationAuthority: false,
      appSupportDirectory: support.path,
      readOwnerMarker: () async => marker,
      debugAfterAdoptionStep: crashAt,
      readOnlyOpener: ({required location, required readKey}) async {
        final call = ++openCalls;
        openersMax = ++openersActive > openersMax ? openersActive : openersMax;
        try {
          await beforeOpen?.call(call);
          final db = await AppDatabase.openReadOnlyExisting(
              location: location,
              readKey: readKey,
              debugBeforeClose: (db) async => beforeFactoryClose?.call(db));
          opened.add(db);
          return db;
        } finally {
          openersActive--;
        }
      },
      debugBeforeReadOnlyClose: (db) async {
        await beforeClose?.call(++closeCalls);
      },
    );
    stores.add(s);
    return s;
  }

  setUp(() {
    support = Directory.systemTemp.createTempSync('local_read_replica_');
    rec = RecordingSecureStorage().install();
    marker = _uid;
    opened.clear();
    openCalls = openersActive = openersMax = closeCalls = 0;
    beforeOpen = null;
    beforeClose = null;
    beforeFactoryClose = null;
  });

  tearDown(() async {
    for (final s in stores) {
      await s.closeAll();
    }
    stores.clear();
    if (support.existsSync()) support.deleteSync(recursive: true);
  });

  /// A normal, fully initialized replica for [uid] holding one known row; returns
  /// its replica id. The owner marker is left naming [uid].
  Future<String> seed(String uid) async {
    marker = uid;
    final s = store();
    final db = await s.openReplica(uid);
    await db.customStatement('CREATE TABLE probe(v TEXT);');
    await db.customStatement("INSERT INTO probe VALUES ('known');");
    final id = (await db
            .customSelect('SELECT replica_id FROM replica_meta;')
            .getSingle())
        .read<String>('replica_id');
    await s.closeAll();
    return id;
  }

  /// Every file (with its content hash) and directory under the app-support
  /// directory: any creation, deletion or byte change shows up.
  Map<String, String> snapshot() => {
        for (final e in support.listSync(recursive: true))
          p.relative(e.path, from: support.path): e is File
              ? sha256.convert(e.readAsBytesSync()).toString()
              : 'dir',
      };

  Future<void> expectDenied(
    String uid,
    String replicaId,
    LocalReadDenial reason, {
    ReplicaStore? using,
  }) async {
    final files = snapshot();
    final secrets = Map<String, String>.of(rec.data);
    rec.attempts.clear();
    final s = using ?? store();
    final handlesBefore = opened.length;
    await expectLater(
      s.openReadOnlyReplicaUncoordinatedForTesting(uid, replicaId: replicaId),
      throwsA(isA<LocalReadUnavailableException>()
          .having((e) => e.reason, 'reason', reason)),
    );
    expect(snapshot(), files, reason: 'files, directories and bytes untouched');
    expect(rec.data, secrets, reason: 'secure storage untouched');
    expect(rec.attempts, isEmpty, reason: 'no write or delete attempted');
    expect(s.debugReadOnlyLive, isEmpty, reason: 'no handle is left tracked');
    for (final db in opened.skip(handlesBefore)) {
      expect(db.lifecycleState, DatabaseLifecycleState.closed,
          reason: 'a handle opened for a refused call is closed');
    }
  }

  /// Every handle any opener produced is either still tracked by [s] or closed.
  void expectTrackedOrClosed(ReplicaStore s) {
    final live = s.debugReadOnlyLive.toSet();
    for (final db in opened) {
      expect(
          live.contains(db) ||
              db.lifecycleState == DatabaseLifecycleState.closed,
          isTrue,
          reason: 'a live handle is untracked');
    }
  }

  /// Rewrites the stored registry entry of [uid] through [edit].
  Future<void> editRegistryEntry(
      String uid, void Function(Map<String, Object?> entry) edit) async {
    final hash = await store().uidHash(uid);
    final registry = (jsonDecode(rec.data[ReplicaStore.registryKey]!) as Map)
        .cast<String, Object?>();
    final entry = (registry[hash]! as Map).cast<String, Object?>();
    edit(entry);
    registry[hash] = entry;
    rec.data[ReplicaStore.registryKey] = jsonEncode(registry);
  }

  Future<void> normalOpenSet(String uid, String sql) async {
    final loc = await store().locationFor(uid);
    final db = await AppDatabase.open(
      location: loc,
      runMigrations: false,
      creation: const CreationPolicy.denied(),
    );
    await db.customStatement(sql);
    await db.close();
  }

  group('read-only connection', () {
    test('reads the known rows and verifies owner and replica id', () async {
      final id = await seed(_uid);
      rec.attempts.clear();
      final files = snapshot();

      final replica = await store()
          .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      final db = replica.database;
      expect(replica.uid, _uid);
      expect(replica.replicaId, id);
      expect(db.isReadOnly, isTrue);
      expect(db.isEncrypted, isTrue);
      expect(db.lifecycleState, DatabaseLifecycleState.open);
      expect(
          (await db.customSelect('SELECT v FROM probe;').get())
              .map((r) => r.read<String>('v')),
          ['known']);
      expect(
          (await db.customSelect('PRAGMA user_version;').getSingle())
              .read<int>('user_version'),
          45);
      await db.close();

      expect(snapshot(), files,
          reason: 'no migration, seed, version stamp or any byte changed');
      expect(rec.attempts, isEmpty, reason: 'no secure-storage write/delete');
    });

    test('read-only owner refuses writable secondary before lease or key reads',
        () async {
      final id = await seed(_uid);
      final s = store();
      final loc = await s.locationFor(_uid);
      final owner = (await s.openReadOnlyReplicaUncoordinatedForTesting(_uid,
              replicaId: id))
          .database;
      expect(owner.isEncrypted, isTrue);
      expect(owner.lifecycleState, DatabaseLifecycleState.open);
      final leases = _ObservedLeaseManager(
          leaseDir: loc.leaseDir, intentPath: loc.maintPath);
      final files = snapshot();
      final secrets = Map<String, String>.of(rec.data);
      var keyReads = 0;
      rec.gate = (op, key) async {
        if (op == 'read' && key == loc.keyName) keyReads++;
      };
      rec.attempts.clear();
      AppDatabase? secondary;
      Object? failure;
      try {
        secondary = await AppDatabase.openSecondary(
            location: loc, owner: owner, leaseManager: leases);
      } catch (error) {
        failure = error;
      } finally {
        // Keeps the failing-before-fix fixture from leaking a wrongly admitted
        // secondary; its admission still fails the assertions below.
        await secondary?.close();
      }
      expect(failure, isA<DatabaseLifecycleException>());
      expect(leases.sharedAttempts, 0,
          reason: 'owner refusal precedes the file-lease protocol');
      expect(keyReads, 0, reason: 'no encryption-key read was attempted');
      expect(rec.attempts, isEmpty);
      expect(rec.data, secrets);
      expect(snapshot(), files,
          reason: 'no lease directory, sidecar or database byte changed');
      expect(
          (await owner.customSelect('SELECT v FROM probe;').getSingle())
              .read<String>('v'),
          'known');
    });

    test('read-only owner is refused EXPLICITLY, before any lease or key work',
        () async {
      final id = await seed(_uid);
      final s = store();
      final loc = await s.locationFor(_uid);
      final owner = (await s.openReadOnlyReplicaUncoordinatedForTesting(_uid,
              replicaId: id))
          .database;
      final leases = _ObservedLeaseManager(
          leaseDir: loc.leaseDir, intentPath: loc.maintPath);
      var keyReads = 0;
      rec.gate = (op, key) async {
        if (op == 'read' && key == loc.keyName) keyReads++;
      };
      Object? failure;
      AppDatabase? secondary;
      try {
        secondary = await AppDatabase.openSecondary(
            location: loc, owner: owner, leaseManager: leases);
      } catch (error) {
        failure = error;
      } finally {
        await secondary?.close();
      }
      expect(failure, isA<DatabaseLifecycleException>());
      expect((failure as DatabaseLifecycleException).reason,
          DatabaseLifecycleFailure.readOnlyOwner);
      expect(leases.sharedAttempts, 0);
      expect(keyReads, 0);
    });

    test('writable encrypted owner still admits a writable secondary',
        () async {
      await seed(_uid);
      final s = store();
      final owner = await s.openReplica(_uid);
      final loc = await s.locationFor(_uid);
      final leases = _ObservedLeaseManager(
          leaseDir: loc.leaseDir, intentPath: loc.maintPath);
      expect(owner.isReadOnly, isFalse);
      final secondary = await AppDatabase.openSecondary(
          location: loc, owner: owner, leaseManager: leases);
      try {
        expect(secondary.isEncrypted, isTrue);
        expect(secondary.isReadOnly, isFalse);
        await secondary
            .customStatement("INSERT INTO probe VALUES ('secondary');");
        expect(leases.sharedAttempts, 1);
        expect(
            (await secondary.customSelect('SELECT v FROM probe;').get())
                .map((row) => row.read<String>('v')),
            ['known', 'secondary']);
      } finally {
        await secondary.close();
      }
    });

    test(
        'SQLite itself rejects every write, even with query_only switched '
        'off', () async {
      final id = await seed(_uid);
      final db = (await store()
              .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id))
          .database;
      for (final sql in [
        "INSERT INTO probe VALUES ('x');",
        "UPDATE probe SET v = 'y';",
        'DELETE FROM probe;',
        'CREATE TABLE t2(a);',
        'DROP TABLE probe;',
        'ALTER TABLE probe ADD COLUMN c TEXT;',
        "UPDATE replica_meta SET owner_uid = 'evil';",
        'PRAGMA user_version = 99;',
      ]) {
        await expectLater(db.customStatement(sql), throwsA(anything),
            reason: sql);
      }
      // query_only is defence in depth: the OPEN MODE is the boundary.
      await db.customStatement('PRAGMA query_only = OFF;');
      await expectLater(db.customStatement("INSERT INTO probe VALUES ('x');"),
          throwsA(anything));
      expect(
          (await db.customSelect('SELECT v FROM probe;').get())
              .map((r) => r.read<String>('v')),
          ['known']);
      await db.close();
    });

    test('a read-only handle is never initialized or migrated', () async {
      final id = await seed(_uid);
      final db = (await store()
              .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id))
          .database;
      await expectLater(db.initialize(), throwsA(isA<StateError>()));
      await db.close();
    });

    test('a WAL crash image is read without checkpointing the main file',
        () async {
      final id = await seed(_uid);
      final loc = await store().locationFor(_uid);
      final db = await AppDatabase.open(
        location: loc,
        runMigrations: false,
        creation: const CreationPolicy.denied(),
      );
      await db.customSelect('PRAGMA journal_mode = WAL;').get();
      await db.customStatement("INSERT INTO probe VALUES ('in-wal');");
      final snap = Directory(p.join(support.path, '_snap'))..createSync();
      for (final s in ['', '-wal', '-shm']) {
        final f = File('${loc.dbPath}$s');
        if (f.existsSync()) f.copySync(p.join(snap.path, p.basename(f.path)));
      }
      await db.close();
      for (final s in ['', '-wal', '-shm']) {
        final f = File('${loc.dbPath}$s');
        if (f.existsSync()) f.deleteSync();
      }
      for (final f in snap.listSync().whereType<File>()) {
        f.copySync(p.join(loc.directory, p.basename(f.path)));
      }
      snap.deleteSync(recursive: true);
      final mainBefore = sha256.convert(File(loc.dbPath).readAsBytesSync());

      final replica = await store()
          .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      expect(
          (await replica.database.customSelect('SELECT v FROM probe;').get())
              .map((r) => r.read<String>('v')),
          ['known', 'in-wal']);
      await replica.database.close();
      expect(sha256.convert(File(loc.dbPath).readAsBytesSync()), mainBefore,
          reason: 'a read-only open never checkpoints into the main file');
    });
  });

  group('refusals change nothing', () {
    test('missing device salt: none is minted', () async {
      final id = await seed(_uid);
      rec.data.remove(ReplicaStore.saltKey);
      await expectDenied(_uid, id, LocalReadDenial.salt);
      expect(rec.data.containsKey(ReplicaStore.saltKey), isFalse);
    });

    test('an uid with no replica creates no replica, file or key', () async {
      final id = await seed(_uid);
      marker = 'uid-ghost';
      await expectDenied('uid-ghost', id, LocalReadDenial.registry);
    });

    test('empty identity or transition marker', () async {
      final id = await seed(_uid);
      await expectDenied('', id, LocalReadDenial.identity);
      await expectDenied(_uid, '', LocalReadDenial.identity);
      await expectDenied(
          'owner-transition-pending:x', id, LocalReadDenial.identity);
    });

    test('owner marker absent or naming another uid', () async {
      final id = await seed(_uid);
      marker = null;
      await expectDenied(_uid, id, LocalReadDenial.ownerMarker);
      marker = _other;
      await expectDenied(_uid, id, LocalReadDenial.ownerMarker);
    });

    test('registry missing, corrupt, or not active', () async {
      final id = await seed(_uid);
      final registry = rec.data[ReplicaStore.registryKey]!;
      rec.data.remove(ReplicaStore.registryKey);
      await expectDenied(_uid, id, LocalReadDenial.registry);
      rec.data[ReplicaStore.registryKey] = '{not json';
      await expectDenied(_uid, id, LocalReadDenial.unavailable);
      rec.data[ReplicaStore.registryKey] = registry;

      for (final state in [
        ReplicaState.locked,
        ReplicaState.migrating,
        ReplicaState.quarantined,
      ]) {
        await store().setState(_uid, state);
        await expectDenied(_uid, id, LocalReadDenial.replicaState);
      }
    });

    test('rebootstrap in progress', () async {
      final id = await seed(_uid);
      await store().beginRebootstrap(_uid, 'reset');
      await expectDenied(_uid, id, LocalReadDenial.replicaState);
    });

    test('removal barrier, revoked entry, unreadable list or tombstone',
        () async {
      final id = await seed(_uid);
      rec.data[ReplicaStore.removalBarrierKey] = '{"uid":"x"}';
      await expectDenied(_uid, id, LocalReadDenial.removal);
      rec.data.remove(ReplicaStore.removalBarrierKey);

      rec.data[ReplicaStore.removalRevokedKey] = '["$_uid"]';
      await expectDenied(_uid, id, LocalReadDenial.removal);
      rec.data[ReplicaStore.removalRevokedKey] = '{}';
      await expectDenied(_uid, id, LocalReadDenial.removal);
      rec.data[ReplicaStore.removalRevokedKey] = 'garbage';
      await expectDenied(_uid, id, LocalReadDenial.unavailable);
      rec.data.remove(ReplicaStore.removalRevokedKey);

      final hash = await store().uidHash(_uid);
      Directory(p.join(support.path, 'replicas', '_removing.$hash'))
          .createSync();
      await expectDenied(_uid, id, LocalReadDenial.removal);
    });

    test("another uid's revoked entry does not deny", () async {
      final id = await seed(_uid);
      rec.data[ReplicaStore.removalRevokedKey] = '["$_other"]';
      final replica = await store()
          .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      await replica.database.close();
    });

    test('missing database file or missing key', () async {
      final id = await seed(_uid);
      final loc = await store().locationFor(_uid);
      final key = rec.data[loc.keyName]!;
      rec.data.remove(loc.keyName);
      await expectDenied(_uid, id, LocalReadDenial.key);
      expect(rec.data.containsKey(loc.keyName), isFalse, reason: 'not minted');
      rec.data[loc.keyName] = key;

      File(loc.dbPath).deleteSync();
      await expectDenied(_uid, id, LocalReadDenial.files);
      expect(File(loc.dbPath).existsSync(), isFalse, reason: 'not recreated');
    });

    test('a key that does not open the file', () async {
      final id = await seed(_uid);
      final loc = await store().locationFor(_uid);
      rec.data[loc.keyName] = 'A-DIFFERENT-KEY';
      await expectDenied(_uid, id, LocalReadDenial.unavailable);
    });

    test('another replica id, or a file that names another owner', () async {
      final id = await seed(_uid);
      await expectDenied(_uid, '${id}x', LocalReadDenial.ownership);

      final idB = await seed(_other);
      marker = _other;
      final locA = await store().locationFor(_uid);
      final locB = await store().locationFor(_other);
      File(locA.dbPath).copySync(locB.dbPath);
      rec.data[locB.keyName] = rec.data[locA.keyName]!;
      await expectDenied(_other, idB, LocalReadDenial.ownership);
    });

    test(
        'failed verification close retains the real live handle and blocks removal',
        () async {
      final id = await seed(_uid);
      await normalOpenSet(_uid, 'PRAGMA user_version = 99;');
      final s = store();
      final files = snapshot();
      final secrets = Map<String, String>.of(rec.data);
      AppDatabase? failedHandle;
      beforeFactoryClose = (db) async {
        failedHandle = db;
        throw StateError('injected before underlying close');
      };
      await expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      final db = failedHandle!;
      try {
        expect(db.isEncrypted, isTrue);
        expect(db.isReadOnly, isTrue);
        expect(db.lifecycleState, isNot(DatabaseLifecycleState.closed));
        expect(s.debugReadOnlyLive, contains(same(db)));
        await expectLater(s.remove(_uid), throwsStateError);
        expect(snapshot(), files);
        expect(rec.data, secrets);
        expect(s.debugReadOnlyLive, contains(same(db)));
        beforeFactoryClose = null;
        await s.closeAll();
        expect(db.lifecycleState, DatabaseLifecycleState.closed);
        expect(s.debugReadOnlyLive, isEmpty);
      } finally {
        // Red-run fixture cleanup only. Never substitutes for store tracking or
        // the successful store-mediated close asserted above.
        beforeFactoryClose = null;
        await db.close();
      }
    });

    test(
        'failed schema verification closes the real factory handle successfully',
        () async {
      final id = await seed(_uid);
      await normalOpenSet(_uid, 'PRAGMA user_version = 99;');
      final s = store();
      final files = snapshot();
      AppDatabase? failedHandle;
      beforeFactoryClose = (db) async {
        failedHandle = db;
      };
      await expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      expect(failedHandle!.lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, isEmpty);
      expect(snapshot(), files);
    });

    test('a schema this build does not run is unavailable, never migrated',
        () async {
      final id = await seed(_uid);
      for (final version in [40, 46]) {
        await normalOpenSet(_uid, 'PRAGMA user_version = $version;');
        await expectDenied(_uid, id, LocalReadDenial.schema);
      }
    });
  });

  group('lockVerified', () {
    test('O9-2 stale registry-read completion leaves a newer target candidate '
        'untouched', () async {
      final id = await seed(_uid);
      final s = store();
      var valid = true;
      final registryBefore = rec.data[ReplicaStore.registryKey];
      final hold = rec.holdOnce(
          (op, key) => op == 'read' && key == ReplicaStore.registryKey);
      final lock = s.lockVerified(_uid, stillValid: () => valid);
      await hold.reached.future;
      valid = false;
      final opening = Completer<void>();
      final releaseOpen = Completer<void>();
      beforeOpen = (_) async {
        opening.complete();
        await releaseOpen.future;
      };
      final candidate = s.openReadOnlyReplicaUncoordinatedForTesting(
          _uid, replicaId: id).then<Object>((v) => v,
              onError: (Object error) => error);
      await opening.future;
      hold.release.complete();
      final locked = await lock;
      releaseOpen.complete();
      final result = await candidate;
      expect(locked, isFalse);
      expect(rec.data[ReplicaStore.registryKey], registryBefore);
      expect(result, isA<LocalReadReplica>(),
          reason: 'a refused fallback must not invalidate a newer candidate');
      await (result as LocalReadReplica).database.close();
    });

    test('O9-2 an eligible old-uid lock leaves an unrelated candidate current',
        () async {
      await seed(_uid);
      final otherId = await seed(_other);
      final s = store();
      final opening = Completer<void>();
      final releaseOpen = Completer<void>();
      beforeOpen = (_) async {
        opening.complete();
        await releaseOpen.future;
      };
      final candidate = s.openReadOnlyReplicaUncoordinatedForTesting(
          _other, replicaId: otherId).then<Object>((v) => v,
              onError: (Object error) => error);
      await opening.future;
      final locked = await s.lockVerified(_uid, stillValid: () => true);
      releaseOpen.complete();
      final result = await candidate;
      expect(locked, isTrue);
      expect(result, isA<LocalReadReplica>(),
          reason: 'a targeted denial cannot invalidate an unrelated uid');
      await (result as LocalReadReplica).database.close();
    });

    test('locks an existing entry and reads it back; reading then refuses',
        () async {
      final id = await seed(_uid);
      final s = store();
      expect(await s.lockVerified(_uid), isTrue);
      expect((await s.list()).single.state, ReplicaState.locked);
      await expectDenied(_uid, id, LocalReadDenial.replicaState);
    });

    test('claims nothing without salt, entry or a parseable registry',
        () async {
      await seed(_uid);
      final s = store();
      final registry = rec.data[ReplicaStore.registryKey]!;

      expect(await s.lockVerified('uid-ghost'), isFalse);
      expect(rec.data[ReplicaStore.registryKey], registry,
          reason: 'no entry is created');

      rec.data[ReplicaStore.registryKey] = '{not json';
      expect(await s.lockVerified(_uid), isFalse);
      expect(rec.data[ReplicaStore.registryKey], '{not json',
          reason: 'a registry that cannot be parsed is never replaced');
      rec.data[ReplicaStore.registryKey] = registry;

      rec.data.remove(ReplicaStore.saltKey);
      expect(await s.lockVerified(_uid), isFalse);
      expect(rec.data.containsKey(ReplicaStore.saltKey), isFalse);
    });
  });

  group('removal', () {
    test('Remove data closes the read-only handle and then refuses', () async {
      final id = await seed(_uid);
      final s = store();
      final loc = await s.locationFor(_uid);
      final replica = await s.openReadOnlyReplicaUncoordinatedForTesting(_uid,
          replicaId: id);
      expect(replica.database.lifecycleState, DatabaseLifecycleState.open);

      await s.remove(_uid);
      AppDatabase.dropProcessLiveness(loc);
      expect(replica.database.lifecycleState, DatabaseLifecycleState.closed);
      await expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
    });

    test('the mirrored removal key names match RemoveDataFlow', () {
      expect(ReplicaStore.removalBarrierKey, RemoveDataFlow.barrierKey);
      expect(ReplicaStore.removalRevokedKey, RemoveDataFlow.revokedKey);
    });
  });

  group('malformed restricting records deny: no handle, no mutation', () {
    const startedAt = '2026-10-01T00:00:00.000Z';

    test('every revoked-list element must be a uid string', () async {
      final id = await seed(_uid);
      for (final bad in [
        '[123]',
        '[null]',
        '[{"a":1}]',
        '[[]]',
        '[true]',
        '[""]',
        '["$_other",7]',
      ]) {
        rec.data[ReplicaStore.removalRevokedKey] = bad;
        await expectDenied(_uid, id, LocalReadDenial.removal);
      }
      // A well-formed list of OTHER uids still reads.
      rec.data[ReplicaStore.removalRevokedKey] = '["$_other"]';
      final replica = await store()
          .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      await replica.database.close();
    });

    test('adoptPending, when present, must be a bool', () async {
      final id = await seed(_uid);
      final good = rec.data[ReplicaStore.registryKey]!;
      for (final bad in <Object?>['true', 'false', 'yes', 1, 0, null]) {
        rec.data[ReplicaStore.registryKey] = good;
        await editRegistryEntry(_uid, (e) => e['adoptPending'] = bad);
        await expectDenied(_uid, id, LocalReadDenial.unavailable);
      }
      rec.data[ReplicaStore.registryKey] = good;
      await editRegistryEntry(_uid, (e) => e['adoptPending'] = false);
      await (await store()
              .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id))
          .database
          .close();
    });

    test('rebootstrap.swapping, when present, must be a bool', () async {
      final id = await seed(_uid);
      final good = rec.data[ReplicaStore.registryKey]!;
      for (final bad in <Object?>['true', 'false', 1, 0, null]) {
        rec.data[ReplicaStore.registryKey] = good;
        await editRegistryEntry(
            _uid,
            (e) => e['rebootstrap'] = {
                  'phase': 'swapped',
                  'reason': 'reset',
                  'startedAt': startedAt,
                  'swapping': bad,
                });
        await expectDenied(_uid, id, LocalReadDenial.unavailable);
      }
    });

    test('an unknown or malformed rebootstrap phase denies', () async {
      final id = await seed(_uid);
      final good = rec.data[ReplicaStore.registryKey]!;
      for (final bad in <Map<String, Object?>>[
        {'phase': 'bogus', 'reason': 'r', 'startedAt': startedAt},
        {'phase': 3, 'reason': 'r', 'startedAt': startedAt},
        {'phase': null, 'reason': 'r', 'startedAt': startedAt},
        {'reason': 'r', 'startedAt': startedAt},
        {'phase': 'swapped', 'reason': 'r', 'startedAt': 'not a date'},
      ]) {
        rec.data[ReplicaStore.registryKey] = good;
        await editRegistryEntry(_uid, (e) => e['rebootstrap'] = bad);
        await expectDenied(_uid, id, LocalReadDenial.unavailable);
      }
    });

    test(
        'a swap in progress denies whatever later phase is recorded, while a '
        'finished swap with the optional flag omitted is readable', () async {
      final id = await seed(_uid);
      final good = rec.data[ReplicaStore.registryKey]!;
      await editRegistryEntry(
          _uid,
          (e) => e['rebootstrap'] = {
                'phase': 'swapped',
                'reason': 'reset',
                'startedAt': startedAt,
                'swapping': true,
              });
      await expectDenied(_uid, id, LocalReadDenial.replicaState);

      rec.data[ReplicaStore.registryKey] = good;
      await editRegistryEntry(
          _uid,
          (e) => e['rebootstrap'] = {
                'phase': 'swapped',
                'reason': 'reset',
                'startedAt': startedAt,
              });
      await (await store()
              .openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id))
          .database
          .close();
    });

    test('a real interrupted swap leaves swapping set and denies', () async {
      final id = await seed(_uid);
      final crashing = store(crashAt: (step) async {
        if (step == 'swap:afterOldMoved') throw StateError('simulated crash');
      });
      await crashing.beginRebootstrap(_uid, 'reset');
      await crashing.openStaging(_uid);
      await expectLater(crashing.swapStaging(_uid), throwsA(isA<StateError>()));
      expect((await crashing.list()).single.rebootstrap!.swapping, isTrue);
      await expectDenied(_uid, id, LocalReadDenial.replicaState);
    });

    test('a lock never replaces a registry whose flags are malformed',
        () async {
      await seed(_uid);
      await editRegistryEntry(_uid, (e) => e['adoptPending'] = 'true');
      final before = rec.data[ReplicaStore.registryKey];
      expect(await store().lockVerified(_uid), isFalse);
      expect(rec.data[ReplicaStore.registryKey], before);
    });
  });

  group('concurrent read-only opens', () {
    test(
        'overlapping opens are serialized; the newest handle is published '
        'and the older one is closed', () async {
      final id = await seed(_uid);
      final s = store();
      final first =
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      final second =
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id);
      final r1 = await first;
      final r2 = await second;
      expect(openersMax, 1, reason: 'never two opens of one replica at once');
      expect(opened, hasLength(2));
      expect(r1.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(r2.database.lifecycleState, DatabaseLifecycleState.open);
      expect(s.debugReadOnlyLive.toList(), [r2.database]);
      expect((await r2.database.customSelect('SELECT v FROM probe;').get()),
          hasLength(1));
      expectTrackedOrClosed(s);
    });

    test(
        'a lock while the previous handle is still closing: the replacement '
        'is not published and nothing is left live', () async {
      final id = await seed(_uid);
      final s = store();
      final a = await s.openReadOnlyReplicaUncoordinatedForTesting(_uid,
          replicaId: id);
      final reached = Completer<void>();
      final release = Completer<void>();
      beforeClose = (n) async {
        if (n == 1) {
          reached.complete();
          await release.future;
        }
      };
      final second = expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      await reached.future;
      expect(s.debugReadOnlyLive, hasLength(2),
          reason: 'old (closing) and new are both tracked');
      expectTrackedOrClosed(s);

      expect(await s.lockVerified(_uid), isTrue);
      release.complete();
      await second;

      expect(s.debugReadOnlyLive, isEmpty);
      expect(a.database.lifecycleState, DatabaseLifecycleState.closed);
      for (final db in opened) {
        expect(db.lifecycleState, DatabaseLifecycleState.closed);
      }
    });

    test('a lock while the open is in flight: the handle it returns is closed',
        () async {
      final id = await seed(_uid);
      final s = store();
      final reached = Completer<void>();
      final release = Completer<void>();
      beforeOpen = (n) async {
        reached.complete();
        await release.future;
      };
      final open = expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      await reached.future;
      expect(await s.lockVerified(_uid), isTrue);
      release.complete();
      await open;
      expect(opened, hasLength(1));
      expect(opened.single.lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, isEmpty);
    });

    test('closeAll during the initial salt read invalidates the open',
        () async {
      final id = await seed(_uid);
      final s = store();
      final hold = rec
          .holdOnce((op, key) => op == 'read' && key == ReplicaStore.saltKey);
      final open = expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      await hold.reached.future;
      await s.closeAll();
      hold.release.complete();
      await open;
      expect(opened, isEmpty);
    });

    for (final mutation in ['setState', 'beginRebootstrap']) {
      test('$mutation during an open prevents publication', () async {
        final id = await seed(_uid);
        final s = store();
        final reached = Completer<void>();
        final release = Completer<void>();
        beforeOpen = (_) async {
          reached.complete();
          await release.future;
        };
        final open = expectLater(
            s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
            throwsA(isA<LocalReadUnavailableException>()));
        await reached.future;
        if (mutation == 'setState') {
          await s.setState(_uid, ReplicaState.locked);
          await s.setState(_uid, ReplicaState.active);
        } else {
          await s.beginRebootstrap(_uid, 'test');
          await s.advanceRebootstrap(_uid, RebootstrapPhase.captureResumed);
        }
        release.complete();
        await open;
        expect(opened.single.lifecycleState, DatabaseLifecycleState.closed);
        expectTrackedOrClosed(s);
      });
    }

    test('closing the replica while the open is in flight', () async {
      final id = await seed(_uid);
      final s = store();
      final reached = Completer<void>();
      final release = Completer<void>();
      beforeOpen = (n) async {
        reached.complete();
        await release.future;
      };
      final open = expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      await reached.future;
      await s.closeReplica(_uid);
      release.complete();
      await open;
      expect(opened.single.lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, isEmpty);
    });

    test(
        'Remove data while the open is in flight: the open is drained and its '
        'handle closed', () async {
      final id = await seed(_uid);
      final s = store();
      final loc = await s.locationFor(_uid);
      final reached = Completer<void>();
      final release = Completer<void>();
      beforeOpen = (n) async {
        reached.complete();
        await release.future;
      };
      final open = expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      await reached.future;
      final removal = s.remove(_uid);
      await pumpEventQueue();
      release.complete();
      await open;
      await removal;
      AppDatabase.dropProcessLiveness(loc);
      expect(opened.single.lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, isEmpty);
      expect(Directory(loc.directory).existsSync(), isFalse);
    });

    test(
        'a previous handle whose close fails still cannot leave the new '
        'handle open', () async {
      final id = await seed(_uid);
      final s = store();
      final a = await s.openReadOnlyReplicaUncoordinatedForTesting(_uid,
          replicaId: id);
      beforeClose = (n) async {
        if (n == 1) throw StateError('close failed');
      };
      await expectLater(
          s.openReadOnlyReplicaUncoordinatedForTesting(_uid, replicaId: id),
          throwsA(isA<LocalReadUnavailableException>()));
      expect(opened, hasLength(2));
      expect(opened[1].lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, contains(a.database));
      expectTrackedOrClosed(s);
      beforeClose = (_) async => throw StateError('still cannot close');
      final files = snapshot();
      final secrets = Map<String, String>.of(rec.data);
      await expectLater(s.closeAll(), throwsStateError);
      await expectLater(s.remove(_uid), throwsStateError);
      expect(snapshot(), files);
      expect(rec.data, secrets);
      expect(s.debugReadOnlyLive, contains(a.database));
      expectTrackedOrClosed(s);
      beforeClose = null;
      await s.closeAll();
      await s.closeAll();
      expect(a.database.lifecycleState, DatabaseLifecycleState.closed);
      expect(s.debugReadOnlyLive, isEmpty);
    });
  });

  group('grant + replica, end to end (no SDK session anywhere)', () {
    LocalReadAuthority fresh([LocalReadDurableStore? s]) =>
        LocalReadAuthority(store: s ?? SecureLocalReadStore());

    Future<void> issue(String uid, String replicaId) async {
      final a = fresh();
      final i = await a.beginIssue(uid: uid, replicaId: replicaId);
      await a.commit(i,
          proof: LocalReadIssueProof(uid: uid, isCurrent: () => true));
    }

    test('a preparing record does not restore; a committed one does', () async {
      final id = await seed(_uid);
      final a = fresh();
      final pending = await a.beginIssue(uid: _uid, replicaId: id);
      final denied = await fresh().restoreUncoordinated(store());
      expect(denied.isGranted, isFalse);
      expect(denied.denial, LocalReadRestoreDenial.grant);

      await a.commit(pending,
          proof: LocalReadIssueProof(uid: _uid, isCurrent: () => true));
      rec.attempts.clear();
      final files = snapshot();
      final restored = await fresh().restoreUncoordinated(store());
      expect(restored.isGranted, isTrue);
      expect(restored.capability!.isCurrent, isTrue);
      expect(restored.capability!.uid, _uid);
      expect(restored.capability!.replicaId, id);
      expect(
          (await restored.replica!.database
                  .customSelect('SELECT v FROM probe;')
                  .get())
              .map((r) => r.read<String>('v')),
          ['known']);
      await restored.replica!.database.close();
      expect(rec.attempts, isEmpty,
          reason: 'restoration writes nothing: no grant renewal, no registry '
              'update, no marker or key write');
      expect(snapshot(), files);
    });

    test(
        'restart denies after revoke; other evidence still wins over a '
        'committed record', () async {
      final id = await seed(_uid);
      await issue(_uid, id);

      final restored = await fresh().restoreUncoordinated(store());
      expect(restored.isGranted, isTrue);
      await restored.replica!.database.close();

      final authority = fresh();
      final again = await authority.restoreUncoordinated(store());
      expect(again.isGranted, isTrue);
      expect(await authority.revoke(uid: _uid), LocalReadRevocation.denied);
      expect(again.capability!.isCurrent, isFalse);
      await again.replica!.database.close();
      final afterRestart = await fresh().restoreUncoordinated(store());
      expect(afterRestart.denial, LocalReadRestoreDenial.grant);
    });

    test(
        'a committed record is refused when the registry says locked, the '
        'replica id differs or removal is recorded', () async {
      final id = await seed(_uid);
      await issue(_uid, id);

      await store().setState(_uid, ReplicaState.locked);
      var r = await fresh().restoreUncoordinated(store());
      expect(r.denial, LocalReadRestoreDenial.replica);
      expect(r.replicaDenial, LocalReadDenial.replicaState);
      await store().setState(_uid, ReplicaState.active);

      rec.data[ReplicaStore.removalRevokedKey] = '["$_uid"]';
      r = await fresh().restoreUncoordinated(store());
      expect(r.replicaDenial, LocalReadDenial.removal);
      rec.data.remove(ReplicaStore.removalRevokedKey);

      await issue(_uid, '${id}x');
      r = await fresh().restoreUncoordinated(store());
      expect(r.replicaDenial, LocalReadDenial.ownership);
    });

    test(
        'when the secure record cannot be written, a verified registry lock '
        'is the durable denial', () async {
      final id = await seed(_uid);
      await issue(_uid, id);
      final s = store();
      final failing = _FailingWrites(SecureLocalReadStore());
      final authority = fresh(failing);

      final result = await authority.revoke(
          uid: _uid, lockRegistry: () => s.lockVerified(_uid));
      expect(result, LocalReadRevocation.registryLocked);
      final r = await fresh().restoreUncoordinated(store());
      expect(r.isGranted, isFalse);
      expect(r.replicaDenial, LocalReadDenial.replicaState,
          reason: 'the committed record survived, the registry lock denies');
    });
  });
}

class _FailingWrites implements LocalReadDurableStore {
  _FailingWrites(this._inner);
  final LocalReadDurableStore _inner;
  @override
  Future<String?> read() => _inner.read();
  @override
  Future<void> write(String value) async => throw StateError('write');
}
