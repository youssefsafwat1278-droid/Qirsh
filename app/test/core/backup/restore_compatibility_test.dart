import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/backup/restore_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import '../../harness/seed_test_account.dart';

// MALI-014 / MALI-076n (Batch-5 closure) §Blocker-2 — preparation-time compatibility
// adapters, exercised with synthetic legacy snapshot fixtures (not only envelope
// decoding). A legacy snapshot is normalized to the current plan shape BEFORE
// mutation; the restore then succeeds and the plan records a version warning.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'k';
  @override
  Future<String?> readStoredKey() async => 'k';
}

void main() {
  // A restore mirrors the restored language into the keychain for the unlock
  // prompt (core/security/lock_prompt_language.dart); this suite has no
  // keychain, so it gets an in-memory one.
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  TestWidgetsFlutterBinding.ensureInitialized();

  Future<AppDatabase> open() => seededDb(AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore()));

  Future<int> count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');

  Future<Map<String, dynamic>> fullSnapshot(AppDatabase src) async {
    final categoryId = (await src
            .customSelect('SELECT id FROM categories LIMIT 1;')
            .getSingle())
        .read<String>('id');
    const now = '2026-04-01T00:00:00.000Z';
    await src.customInsert(
      'INSERT INTO transactions(id, amount, currency, raw_merchant, category_id, '
      'type, source, occurred_at, raw_message, parse_confidence, status, '
      'created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
      variables: [
        Variable.withString('legacyTx'),
        Variable.withReal(120.0),
        Variable.withString('SAR'),
        Variable.withString('Legacy'),
        Variable.withString(categoryId),
        Variable.withString('payment'),
        Variable.withString('manual'),
        Variable.withString(now),
        Variable.withString('RAW'),
        Variable.withReal(1.0),
        Variable.withString('confirmed'),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
    await backfillNonPlanningMoneyV30(src);
    return BackupSnapshotBuilder(src).build();
  }

  test('the current (v5) snapshot prepares with no legacy warning', () async {
    final src = await open();
    addTearDown(src.close);
    final snap = await fullSnapshot(src);
    final plan = RestorePreparation.build(
      snapshot: snap,
      // Crypto envelope stays v3; the BUSINESS snapshot is now v5 (exact minor
      // since v4, saved-rule deletion history since v5).
      envelopeVersion: 3,
      sourceBytes: const [3],
      operationId: 'op-v4',
    );
    expect(plan.snapshotSchemaVersion, 5);
    expect(plan.warnings.where((w) => w.startsWith('legacy_schema')), isEmpty);
  });

  test('a synthetic v2 snapshot (no cards/sender_mappings) normalizes + restores; '
      'plan records legacy_schema_v2', () async {
    final src = await open();
    addTearDown(src.close);
    final full = await fullSnapshot(src);
    // Downgrade to a v2-shaped fixture: drop tables that postdate v2.
    final tables = Map<String, dynamic>.from(full['tables'] as Map)
      ..remove('cards')
      ..remove('sender_bank_mappings');
    final v2 = {'schemaVersion': 2, 'tables': tables};

    final plan = RestorePreparation.build(
      snapshot: v2,
      envelopeVersion: 2,
      sourceBytes: const [2],
      operationId: 'op-v2',
    );
    expect(plan.snapshotSchemaVersion, 2);
    expect(plan.warnings, contains('legacy_schema_v2'));

    final dst = await open();
    addTearDown(dst.close);
    expect((await RestoreService(dst).execute(plan: plan)).outcome,
        RestoreOutcome.success);
    expect(await count(dst, 'transactions'), 1);
    // The seeded catalog was preserved (v2 fixture carried no cards to wipe them).
    expect(await count(dst, 'categories') > 0, isTrue);
  });

  test('a synthetic v1 snapshot (pre-accounts) normalizes + restores; plan '
      'records legacy_schema_v1', () async {
    final src = await open();
    addTearDown(src.close);
    final full = await fullSnapshot(src);
    final fullTables = full['tables'] as Map;
    // v1 fixture: only user_settings + transactions (account_id nulled — v1
    // predates multi-account). The default account is ensured post-restore.
    final txns = (fullTables['transactions'] as List)
        .map((r) =>
            Map<String, dynamic>.from(r as Map)..['account_id'] = null)
        .toList();
    final v1 = {
      'schemaVersion': 1,
      'tables': {
        'user_settings': fullTables['user_settings'],
        'transactions': txns,
      },
    };

    final plan = RestorePreparation.build(
      snapshot: v1,
      envelopeVersion: 1,
      sourceBytes: const [1],
      operationId: 'op-v1',
    );
    expect(plan.snapshotSchemaVersion, 1);
    expect(plan.warnings, contains('legacy_schema_v1'));

    final dst = await open();
    addTearDown(dst.close);
    expect((await RestoreService(dst).execute(plan: plan)).outcome,
        RestoreOutcome.success);
    expect(await count(dst, 'transactions'), 1);
    expect(await count(dst, 'accounts') >= 1, isTrue,
        reason: 'a default account is ensured for a pre-accounts backup');
  });

  test('a future snapshot schema is rejected before mutation', () async {
    expect(
      () => RestorePreparation.build(
        snapshot: {'schemaVersion': 999, 'tables': {}},
        envelopeVersion: 3,
        sourceBytes: const [9],
        operationId: 'op-future',
      ),
      throwsA(isA<BackupException>()),
    );
  });
}
