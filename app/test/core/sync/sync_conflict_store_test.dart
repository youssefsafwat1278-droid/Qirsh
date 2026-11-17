import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_fields.dart';
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/sync_conflict_store.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';

// WP-5 / SYNC-Q5 — the durable conflict store, the field differences and the
// Keep Mine / Keep Cloud resolution that uses them.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

void main() {
  group('field differences', () {
    test('only fields whose normalised values differ; equal values and '
        'representation artefacts are not differences', () {
      final d = diffConflictFields(
        ConflictEntities.transaction,
        {
          'amount': 100.0,
          'currency': 'SAR',
          'raw_merchant': ' Cafe ',
          'note': null,
          'occurred_at': '2026-01-01T12:00:00+02:00',
          'status': 'confirmed',
          'category_key': 'food',
        },
        {
          'amount': '100.00',
          'currency': 'SAR',
          'merchant': 'Cafe',
          'description': 'lunch',
          'occurred_at': '2026-01-01T10:00:00.000Z',
          'status': 'confirmed',
          'category_id': 'dining',
        },
      );
      expect({for (final f in d) f.key}, {
        ConflictFieldKey.note,
        ConflictFieldKey.category,
      });
      final note = d.firstWhere((f) => f.key == ConflictFieldKey.note);
      expect(note.mine, isNull);
      expect(note.cloud, 'lunch');
    });

    test('the same wall-clock time with different offsets is a date conflict', () {
      final differences = diffConflictFields(
        ConflictEntities.transaction,
        {'occurred_at': '2026-01-01T10:00:00+02:00'},
        {'occurred_at': '2026-01-01T10:00:00.000Z'},
      );
      expect(differences.map((field) => field.key), [ConflictFieldKey.date]);
    });

    // DATA-07 / REL-09: a zone-less value means UTC (every writer emits `Z`),
    // so it must not become a false date conflict outside UTC. Run under
    // TZ=Africa/Cairo or TZ=Asia/Riyadh to exercise it.
    test('a zone-less timestamp is read as UTC, in any device time zone', () {
      final differences = diffConflictFields(
        ConflictEntities.transaction,
        {'occurred_at': '2026-01-01 10:00:00'},
        {'occurred_at': '2026-01-01T10:00:00Z'},
      );
      expect(differences, isEmpty);
    });

    test('a missing snapshot or an entity without a list shows no fields', () {
      expect(diffConflictFields(ConflictEntities.goal, null, {'name': 'x'}), isEmpty);
      expect(diffConflictFields(ConflictEntities.settings, {'a': 1}, {'a': 2}), isEmpty);
    });

    test('every interactive entity has a field list', () {
      for (final p in interactiveConflictPolicies) {
        expect(kConflictFields.containsKey(p.entityType), isTrue, reason: p.entityType);
      }
    });
  });

  group('store + resolver', () {
    late AppDatabase db;
    late SyncConflictStore store;
    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      store = SyncConflictStore(db);
    });
    tearDown(() => db.close());

    Future<void> seedTx(String id, {double amount = 100}) async {
      await db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at, server_id, server_updated_at, server_revision, sync_status) "
        "VALUES ('$id', $amount, 'SAR', 'payment', 'bank', '2026-07-01', 'm', "
        "0.9, 'confirmed', '2026-07-01', '2026-07-01', 'srv-$id', 'base-ts', 5, "
        "'pending');",
      );
      await backfillNonPlanningMoneyV30(db);
    }

    Future<void> seedGoal(String id) async {
      await db.customStatement(
        "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
        "status, created_at, server_id, server_updated_at, server_revision, "
        "sync_status) VALUES ('$id', 'Travel', 5000, 0, 'classic', 'active', "
        "'2026-07-01', 'srv-$id', 'base-ts', 5, 'pending');",
      );
      await backfillNonPlanningMoneyV30(db);
    }

    test('flag stores the snapshots and flags the entity; one OPEN record per '
        'entity, the first base is kept', () async {
      await seedTx('t1', amount: 111);
      await store.flag(
        entityType: ConflictEntities.transaction,
        localId: 't1',
        kind: SyncConflictKind.update,
        base: {'amount': 100},
        theirs: {'amount': 250, 'revision': 6},
        theirsRevision: 6,
      );
      await store.flag(
        entityType: ConflictEntities.transaction,
        localId: 't1',
        kind: SyncConflictKind.update,
        base: {'amount': 999},
        theirs: {'amount': 300, 'revision': 7},
        theirsRevision: 7,
      );
      final rec = (await store.open()).single;
      expect(rec.base, {'amount': 100}, reason: 'first base kept');
      expect(rec.theirsRevision, 7);
      expect(rec.mine!['amount'], 111, reason: 'local row snapshot');
      expect((await db.customSelect("SELECT sync_status FROM transactions WHERE id='t1'").getSingle())
          .read<String>('sync_status'), 'conflict');
      await store.resolve(ConflictEntities.transaction, 't1', 'mine');
      expect(await store.open(), isEmpty);
      // History is kept; a new conflict opens a new record.
      await store.flag(entityType: ConflictEntities.transaction, localId: 't1',
          kind: SyncConflictKind.update, theirs: {});
      expect(await store.open(), hasLength(1));
      expect((await db.customSelect('SELECT COUNT(*) n FROM sync_conflicts').getSingle())
          .read<int>('n'), 2);
    });

    test('listConflicts carries the field differences and the keep-mine '
        'availability', () async {
      await seedTx('t1', amount: 111);
      await store.flag(
        entityType: ConflictEntities.transaction,
        localId: 't1',
        kind: SyncConflictKind.update,
        theirs: {'amount': 250, 'currency': 'SAR', 'revision': 6},
        theirsRevision: 6,
      );
      final resolver = UniversalConflictResolver(db: db, reEnqueue: const {});
      final c = (await resolver.listConflicts()).single;
      expect(c.kind, SyncConflictKind.update);
      expect(c.fields.map((f) => f.key), contains(ConflictFieldKey.amount));
      expect(c.canKeepMine, isTrue);
    });

    test('keep mine rebases to the stored cloud revision WITHOUT a network call, '
        're-enqueues and resolves the record', () async {
      await seedTx('t1', amount: 111);
      var reEnq = 0;
      await store.flag(
        entityType: ConflictEntities.transaction,
        localId: 't1',
        kind: SyncConflictKind.update,
        serverId: 'srv-t1',
        theirs: {'amount': 250, 'updated_at': '2026-07-09T00:00:00.000Z', 'revision': 8},
        theirsRevision: 8,
      );
      final resolver = UniversalConflictResolver(
        db: db,
        reEnqueue: {ConflictEntities.transaction: (id) async => reEnq++},
        baseFetcher: (t, s) async => throw StateError('no network'),
      );
      await resolver.resolveKeepLocal(ConflictEntities.transaction, 't1');
      final row = await db
          .customSelect("SELECT server_revision, sync_status FROM transactions WHERE id='t1'")
          .getSingle();
      expect(row.read<int>('server_revision'), 8);
      expect(row.read<String>('sync_status'), 'pending');
      expect(reEnq, 1);
      expect(await store.open(), isEmpty);
    });

    test('keep cloud (no remote sync registered) drops the op, settles and '
        'resolves the record', () async {
      await seedTx('t1');
      await db.customStatement(
          "INSERT INTO ledger_sync_outbox(id, transaction_id, operation, payload_json, "
          "created_at, updated_at) VALUES ('o', 't1', 'update', '{}', '2026-07-01', '2026-07-01');");
      await store.flag(entityType: ConflictEntities.transaction, localId: 't1',
          kind: SyncConflictKind.update, theirs: {'amount': 1});
      final resolver = UniversalConflictResolver(db: db, reEnqueue: const {});
      expect(await resolver.resolveKeepRemote(ConflictEntities.transaction, 't1'), isTrue);
      expect(await store.open(), isEmpty);
      expect((await db.customSelect("SELECT COUNT(*) n FROM ledger_sync_outbox").getSingle())
          .read<int>('n'), 0);
    });

    test('cloud tombstone: a transaction can be kept as a NEW copy (never '
        'undeleted); a goal cannot be kept', () async {
      await seedTx('t1');
      await seedGoal('g1');
      await store.flag(entityType: ConflictEntities.transaction, localId: 't1',
          kind: SyncConflictKind.tombstone, theirs: {'deleted_at': 'x'});
      await store.flag(entityType: ConflictEntities.goal, localId: 'g1',
          kind: SyncConflictKind.tombstone, theirs: {'deleted_at': 'x'});
      final restored = <String>[];
      final resolver = UniversalConflictResolver(
        db: db,
        reEnqueue: const {},
        restoreAsNew: {ConflictEntities.transaction: (id) async => restored.add(id)},
      );
      final byType = {for (final c in await resolver.listConflicts()) c.entityType: c};
      expect(byType[ConflictEntities.transaction]!.canKeepMine, isTrue);
      expect(byType[ConflictEntities.goal]!.canKeepMine, isFalse);

      await resolver.resolveKeepLocal(ConflictEntities.goal, 'g1');
      expect((await db.customSelect("SELECT sync_status FROM goals WHERE id='g1'").getSingle())
          .read<String>('sync_status'), 'conflict', reason: 'no safe keep-mine');

      await resolver.resolveKeepLocal(ConflictEntities.transaction, 't1');
      expect(restored, ['t1']);
      final old = await db
          .customSelect("SELECT status, sync_status FROM transactions WHERE id='t1'")
          .getSingle();
      expect(old.read<String>('status'), 'ignored');
      expect(old.read<String>('sync_status'), 'synced');
      expect((await db.customSelect("SELECT resolution FROM sync_conflicts WHERE local_id='t1'").getSingle())
          .read<String>('resolution'), 'mine_as_new');
    });
  });
}
