import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import '../../harness/seed_test_account.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

// MALI-014 / MALI-076n (Batch-5 closure) §Blocker-3/§Blocker-4 — complete rollback
// evidence via deterministic fault injection + a full-DB digest, plus durable
// crash/replay recovery on a FILE-BACKED database.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

// The user-data tables whose complete state must be unchanged by a rolled-back
// restore (settings' deprecated key column is always '' so it is included safely).
const _userTables = [
  'accounts', 'categories', 'cards', 'merchants', 'merchant_category_map',
  'transactions', 'budgets', 'goals', 'goal_contributions', 'subscriptions',
  'bill_payments', 'plans', 'plan_transaction_links', 'sender_bank_mappings',
  'user_settings', 'achievements', 'streaks',
];

Future<Map<String, String>> digest(AppDatabase db) async {
  final out = <String, String>{};
  for (final table in _userTables) {
    final rows = await db.customSelect('SELECT * FROM $table ORDER BY 1;').get();
    final data = rows.map((r) => r.data).toList();
    out[table] = '${data.length}:${sha256.convert(utf8.encode(jsonEncode(data)))}';
  }
  return out;
}

Future<int> committedMarkers(AppDatabase db) async => (await db
        .customSelect(
            "SELECT COUNT(*) AS c FROM restore_operations WHERE state='committed';")
        .getSingle())
    .read<int>('c');

Future<void> seedRich(AppDatabase db) async {
  final categoryId = (await db
          .customSelect('SELECT id FROM categories LIMIT 1;')
          .getSingle())
      .read<String>('id');
  const now = '2026-05-01T00:00:00.000Z';
  await db.customStatement("UPDATE user_settings SET country = 'PRESERVE-ME';");
  for (final t in [('keepA', 100.0, 'payment'), ('keepB', 40.0, 'refund')]) {
    await db.customInsert(
      'INSERT INTO transactions(id, amount, currency, raw_merchant, category_id, '
      'type, source, occurred_at, raw_message, parse_confidence, status, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      variables: [
        Variable.withString(t.$1),
        Variable.withReal(t.$2),
        Variable.withString('SAR'),
        Variable.withString('OldShop'),
        Variable.withString(categoryId),
        Variable.withString(t.$3),
        Variable.withString('manual'),
        Variable.withString(now),
        Variable.withString('OLD-RAW-KEEP'),
        Variable.withReal(1.0),
        Variable.withString('confirmed'),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
  }
  await backfillNonPlanningMoneyV30(db);
}

Future<void> seedSource(AppDatabase db) async {
  final categoryId = (await db
          .customSelect('SELECT id FROM categories LIMIT 1;')
          .getSingle())
      .read<String>('id');
  const now = '2026-06-01T00:00:00.000Z';
  await db.customInsert(
    'INSERT INTO transactions(id, amount, currency, raw_merchant, category_id, '
    'type, source, occurred_at, raw_message, parse_confidence, status, '
    'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
    variables: [
      Variable.withString('newTx'),
      Variable.withReal(999.0),
      Variable.withString('SAR'),
      Variable.withString('NewShop'),
      Variable.withString(categoryId),
      Variable.withString('payment'),
      Variable.withString('manual'),
      Variable.withString(now),
      Variable.withString('NEW-RAW'),
      Variable.withReal(1.0),
      Variable.withString('confirmed'),
      Variable.withString(now),
      Variable.withString(now),
    ],
  );
  await backfillNonPlanningMoneyV30(db);
}

Future<RestorePlan> planFrom(AppDatabase src) async => RestorePreparation.build(
      snapshot: await BackupSnapshotBuilder(src).build(),
      envelopeVersion: 3,
      sourceBytes: const [7, 7, 7],
      operationId: 'op-recovery',
    );

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> openMemory() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore()));
  Future<AppDatabase> openFile(String path) => seededDb(AppDatabase.open(
      executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore()));

  group('§Blocker-3 — rollback at every transaction-boundary fault point leaves '
      'the complete database unchanged', () {
    const faultPoints = [
      'afterFirstDelete',
      'afterSeveralDeletes',
      'afterFirstInsert',
      'afterPartialInsert',
      'duringRelationshipReconstruction',
      'beforeVerification',
      'duringVerification',
      'afterVerification',
      'duringJournalCommit',
    ];

    // Decision 3.3: a destination holding records takes the MERGE path (no
    // deletes); a destination with none takes the full-apply path. Every
    // fault point is exercised on each path that reaches it.
    const fullApplyOnly = {'afterFirstDelete', 'afterSeveralDeletes'};
    for (final point in faultPoints) {
      for (final merge in [true, false]) {
        if (merge && fullApplyOnly.contains(point)) continue;
        test(
            'failure at "$point" rolls back — full digest + no committed '
            'marker${merge ? '' : ' (new device, full apply)'}', () async {
          final src = await openMemory();
          addTearDown(src.close);
          await seedSource(src);
          final dst = await openMemory();
          addTearDown(dst.close);
          if (merge) {
            await seedRich(dst);
          } else {
            await dst.customStatement(
                "UPDATE user_settings SET country = 'PRESERVE-ME';");
          }

          final before = await digest(dst);
          final plan = await planFrom(src);
          final result = await RestoreService(dst).execute(
            plan: plan,
            onFaultPoint: (p) {
              if (p == point) throw StateError('injected fault at $point');
            },
          );

          expect(result.isCommitted, isFalse,
              reason: 'a fault must never report a committed restore');
          expect(await digest(dst), before,
              reason: 'the complete pre-restore database must be unchanged');
          expect(await committedMarkers(dst), 0,
              reason: 'the durable committed marker rolled back with the data');
          expect(
              (await dst.customSelect('PRAGMA foreign_key_check;').get())
                  .isEmpty,
              isTrue);
        });
      }
    }
  });

  group('§Blocker-4 — durable crash/replay on a file-backed database', () {
    test('crash BEFORE commit (fault mid-transaction) → reopened file is the '
        'complete old state, no committed marker', () async {
      final dir = Directory.systemTemp.createTempSync('mali_crash_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';
      final src = await openMemory();
      addTearDown(src.close);
      await seedSource(src);

      var db = await openFile(path);
      await seedRich(db);
      await db.close();
      // Reopen once so the open pipeline's idempotent backfills are already
      // applied — this is the STABLE pre-restore state that a reopen reproduces.
      db = await openFile(path);
      final before = await digest(db);
      final plan = await planFrom(src);
      final result = await RestoreService(db).execute(
        plan: plan,
        onFaultPoint: (p) {
          if (p == 'afterPartialInsert') throw StateError('killed mid-txn');
        },
      );
      expect(result.isCommitted, isFalse);
      await db.close();

      // "Restart": reopen the same file. The transaction rolled back on failure,
      // exactly as a real crash-before-commit would leave it.
      db = await openFile(path);
      addTearDown(db.close);
      expect(await digest(db), before, reason: 'complete old state preserved');
      expect(await committedMarkers(db), 0);
      expect((await db.customSelect('PRAGMA foreign_key_check;').get()).isEmpty,
          isTrue);
    });

    test('commit BEFORE acknowledgement → restart discovers the committed '
        'operation and never replays the destructive restore', () async {
      final dir = Directory.systemTemp.createTempSync('mali_ack_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/app.db';
      final src = await openMemory();
      addTearDown(src.close);
      await seedSource(src);

      var db = await openFile(path);
      await seedRich(db);
      final plan = await planFrom(src);
      // A full restore commits (data + durable journal) but is NOT acknowledged.
      expect((await RestoreService(db).execute(plan: plan)).outcome,
          RestoreOutcome.success);
      expect(await committedMarkers(db), 1);
      await db.close();

      // "Restart" with a FRESH service (empty in-memory state). The durable journal
      // in the file makes the committed operation discoverable. Baseline the digest
      // AFTER reopen so we measure only the replay's effect (not reopen backfills).
      db = await openFile(path);
      addTearDown(db.close);
      final baseline = await digest(db);
      final service = RestoreService(db);
      final replay = await service.execute(plan: plan);
      expect(replay.outcome, RestoreOutcome.committedPendingAcknowledgement,
          reason: 'discovered, not replayed');
      expect(await digest(db), baseline,
          reason: 'the retry must not mutate the already-restored data');

      // Acknowledgement is idempotent; a further replay is a plain success.
      await service.acknowledge(plan.operationId);
      expect((await service.execute(plan: plan)).outcome, RestoreOutcome.success);
      expect(await digest(db), baseline);
    });

    test('REAL Process.start kill mid-transaction → SQLite rolls back the '
        'uncommitted work (native sqlite)', () async {
      // Phase-7 B1 §Blocker-5 — this is a LOCALLY testable process test (pure Dart +
      // the on-disk sqlite native lib). A busy machine is NOT an external
      // prerequisite, so load NEVER causes a silent skip: readiness has a generous
      // 60s deadline that absorbs load, a transient post-kill lock triggers a bounded
      // SETUP retry, and the rollback result is ASSERTED — a surviving uncommitted
      // row FAILS loudly as the real durability defect it would be. The ONLY skips are
      // genuine platform absence: no `dart` executable, or the sqlite3 native library
      // cannot be loaded at all.
      try {
        final v = await Process.run('dart', const ['--version']);
        if (v.exitCode != 0) {
          markTestSkipped('dart executable unavailable (exit ${v.exitCode})');
          return;
        }
      } on ProcessException catch (e) {
        markTestSkipped('dart executable not on PATH: ${e.message}');
        return;
      }

      final dir = Directory.systemTemp.createTempSync('mali_kill_');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } catch (_) {}
      });

      final dbPath = '${dir.path}/plain.db';
      final ready = '${dir.path}/ready';
      final childErr = StringBuffer();
      File('${dir.path}/child.dart').writeAsStringSync(_childSource);

      final proc = await Process.start(
        'dart',
        ['--packages=${Directory.current.path}/.dart_tool/package_config.json',
          '${dir.path}/child.dart', dbPath, ready],
      );
      proc.stderr.transform(const SystemEncoding().decoder).listen(childErr.write);
      var childExited = false;
      int? childExit;
      unawaited(proc.exitCode.then((c) {
        childExited = true;
        childExit = c;
      }));
      addTearDown(() {
        try {
          proc.kill(ProcessSignal.sigkill);
        } catch (_) {}
      });

      // Generous readiness deadline absorbs local load — we do NOT skip because the
      // machine is busy. We only stop early if the child DIED, and then only SKIP if
      // its stderr proves native sqlite could not load.
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!File(ready).existsSync() &&
          !childExited &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!File(ready).existsSync()) {
        if (childExited && _nativeSqliteUnavailable(childErr.toString())) {
          markTestSkipped(
              'native sqlite could not load in child: ${childErr.toString().trim()}');
          return;
        }
        // Live-but-silent past 60s, or a non-native death: a genuine defect, not an
        // external prerequisite. FAIL with diagnostics rather than skip.
        fail('child never signalled ready within 60s '
            '(exited=$childExited exit=$childExit) '
            'stderr="${childErr.toString().trim()}"');
      }

      proc.kill(ProcessSignal.sigkill);
      await proc.exitCode;

      final read = await _readPlain(dir.path, dbPath);
      if (read.nativeUnavailable) {
        markTestSkipped('native sqlite reader unavailable: ${read.diagnostic}');
        return;
      }
      // A DATA answer is asserted, never skipped: a surviving "uncommitted-restore"
      // row means the killed transaction was NOT rolled back — a real durability bug.
      expect(read.value.trim(), 'committed-before',
          reason: 'SQLite must roll back the killed, uncommitted transaction; a '
              'surviving "uncommitted-restore" row is a real durability defect '
              '(reader diagnostic: ${read.diagnostic})');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

/// True when [s] (a child/reader stderr or exception text) shows the sqlite3 native
/// library itself could not be loaded — the only condition under which the local
/// process test may legitimately skip rather than fail.
bool _nativeSqliteUnavailable(String s) {
  final t = s.toLowerCase();
  return t.contains('failed to load dynamic library') ||
      t.contains('failed to lookup symbol') ||
      t.contains('libsqlite3') ||
      t.contains('cannot open shared object') ||
      t.contains('sqlitelibrarynotfound') ||
      (t.contains('sqlite3') && t.contains('could not'));
}

// A child process: opens a PLAIN native sqlite file, commits a marker row, then
// begins a transaction, mutates, signals readiness, and blocks (never commits).
const String _childSource = r'''
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
void main(List<String> args) {
  final db = sqlite3.open(args[0]);
  db.execute('CREATE TABLE IF NOT EXISTS t(id INTEGER PRIMARY KEY, v TEXT);');
  db.execute("INSERT OR REPLACE INTO t(id, v) VALUES (1, 'committed-before');");
  db.execute('BEGIN IMMEDIATE;');
  db.execute('DELETE FROM t;');
  db.execute("INSERT INTO t(id, v) VALUES (2, 'uncommitted-restore');");
  File(args[1]).writeAsStringSync('ready');
  sleep(const Duration(hours: 1)); // block until the parent kills us mid-txn
}
''';

class _ReadResult {
  const _ReadResult(this.value, {this.nativeUnavailable = false, this.diagnostic = ''});
  final String value;
  final bool nativeUnavailable;
  final String diagnostic;
}

Future<_ReadResult> _readPlain(String dir, String dbPath) async {
  final reader = File('$dir/reader.dart')
    ..writeAsStringSync('''
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
void main(List<String> args) {
  final db = sqlite3.open(args[0]);
  final rows = db.select('SELECT v FROM t;');
  stdout.write(rows.map((r) => r['v']).join(','));
}
''');
  var lastDiag = '';
  // Bounded SETUP retry: a transient "database is locked" immediately after SIGKILL
  // is an OS timing artefact, not a result — retry the read, never skip for it.
  for (var attempt = 0; attempt < 4; attempt++) {
    try {
      final res = await Process.run(
        'dart',
        ['--packages=${Directory.current.path}/.dart_tool/package_config.json',
          reader.path, dbPath],
      ).timeout(const Duration(seconds: 30));
      final err = '${res.stderr}';
      if (res.exitCode == 0) return _ReadResult('${res.stdout}');
      if (_nativeSqliteUnavailable(err)) {
        return _ReadResult('', nativeUnavailable: true, diagnostic: err.trim());
      }
      lastDiag = err.trim();
      final low = err.toLowerCase();
      if (low.contains('database is locked') || low.contains('sqlite_busy')) {
        await Future<void>.delayed(Duration(milliseconds: 100 * (attempt + 1)));
        continue; // transient — retry setup, do not skip
      }
      break; // a non-native, non-transient reader error is a genuine failure surface
    } on ProcessException catch (e) {
      return _ReadResult('', nativeUnavailable: true, diagnostic: e.message);
    } on TimeoutException catch (e) {
      lastDiag = 'reader timeout: $e';
    }
  }
  // Retries exhausted without a native-unavailable classification: return a sentinel
  // the caller ASSERTS against, so it fails loudly with diagnostics (never a skip).
  return _ReadResult('__reader_failed__', diagnostic: lastDiag);
}
