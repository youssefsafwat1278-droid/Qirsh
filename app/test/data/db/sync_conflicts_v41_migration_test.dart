import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';

// WP-5 — schema v41: operation_id + base_revision on both outboxes and the
// durable sync_conflicts table. ADDITIVE; a queued mutation survives the step.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  Future<AppDatabase> open() => AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());

  Future<Set<String>> cols(AppDatabase db, String t) async => (await db
          .customSelect("SELECT name FROM pragma_table_info('$t');")
          .get())
      .map((r) => r.read<String>('name'))
      .toSet();

  Future<int> version(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle()).read<int>('user_version');

  test('a fresh database has the v41 shape', () async {
    final db = await open();
    addTearDown(db.close);
    expect(await version(db), 45);
    for (final t in ['ledger_sync_outbox', 'planning_sync_outbox']) {
      expect(await cols(db, t), containsAll(['operation_id', 'base_revision']));
    }
    expect(await cols(db, 'sync_conflicts'), containsAll([
      'id', 'entity_type', 'local_id', 'server_id', 'kind', 'base_json',
      'mine_json', 'theirs_json', 'theirs_revision', 'operation_id',
      'created_at', 'updated_at', 'resolved_at', 'resolution',
    ]));
  });

  test('v40 -> v41 keeps every queued mutation (operation id NULL until '
      'pushed), adds the columns and the table; replays are safe', () async {
    final db = await open();
    addTearDown(db.close);
    await db.customStatement('''
      INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json,
        created_at, updated_at, op_seq) VALUES ('l1', 't1', 'update', '{"a":1}',
        '2026-07-01', '2026-07-01', 3);
    ''');
    await db.customStatement('''
      INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
        payload_json, created_at, updated_at, op_seq) VALUES ('p1', 'goal', 'g1',
        'update', '{"b":2}', '2026-07-01', '2026-07-01', 2);
    ''');
    // Wind back to the v40 shape.
    for (final t in ['ledger_sync_outbox', 'planning_sync_outbox']) {
      await db.customStatement('ALTER TABLE $t DROP COLUMN operation_id;');
      await db.customStatement('ALTER TABLE $t DROP COLUMN base_revision;');
    }
    await db.customStatement('DROP TABLE sync_conflicts;');
    await db.customStatement('PRAGMA user_version = 40;');

    for (var replay = 0; replay < 2; replay++) {
      await db.debugReinitialize();
      expect(await version(db), 45);
      for (final t in ['ledger_sync_outbox', 'planning_sync_outbox']) {
        expect(await cols(db, t), containsAll(['operation_id', 'base_revision']));
      }
      final l = await db.customSelect("SELECT * FROM ledger_sync_outbox WHERE id='l1'").getSingle();
      expect(l.read<String>('payload_json'), '{"a":1}');
      expect(l.read<int>('op_seq'), 3);
      expect(l.readNullable<String>('operation_id'), isNull);
      expect(l.readNullable<int>('base_revision'), isNull);
      expect((await db.customSelect("SELECT op_seq FROM planning_sync_outbox WHERE id='p1'").getSingle())
          .read<int>('op_seq'), 2);
      await db.customStatement('PRAGMA user_version = 40;');
    }
  });

  test('sync_conflicts: one OPEN record per entity, history is kept',
      () async {
    final db = await open();
    addTearDown(db.close);
    Future<void> add(String id, {String? resolvedAt}) => db.customStatement(
        "INSERT INTO sync_conflicts(id, entity_type, local_id, kind, created_at, "
        "updated_at, resolved_at) VALUES ('$id', 'goal', 'g1', 'update', 'x', 'x', "
        "${resolvedAt == null ? 'NULL' : "'$resolvedAt'"});");
    await add('a', resolvedAt: 'done');
    await add('b');
    await add('c', resolvedAt: 'done');
    await expectLater(add('d'), throwsA(anything),
        reason: 'a second OPEN conflict for the same entity is refused');
    await expectLater(
        db.customStatement("INSERT INTO sync_conflicts(id, entity_type, local_id, "
            "kind, created_at, updated_at) VALUES ('e', 'goal', 'g2', 'bogus', 'x', 'x');"),
        throwsA(anything),
        reason: 'kind is constrained');
  });
}
