import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

// MALI-027 — failure-atomic, version-aware initialization pipeline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A fully-initialized DB (mirrors production AppDatabase.open).
  Future<AppDatabase> open() => seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      ));

  // An UN-initialized DB so a test can drive the real initialize() pipeline
  // itself (memoization / retry / first-run concurrency / historical fixtures).
  AppDatabase uninitialized() => AppDatabase.createForTesting(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );

  Future<int> userVersion(AppDatabase db) async =>
      (await db.customSelect('PRAGMA user_version;').getSingle())
          .read<int>('user_version');

  Future<bool> tableExists(AppDatabase db, String name) async =>
      (await db.customSelect(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?;",
        variables: [Variable.withString(name)],
      ).get())
          .isNotEmpty;

  Future<bool> columnExists(AppDatabase db, String table, String col) async =>
      (await db.customSelect('PRAGMA table_info($table);').get())
          .any((r) => r.read<String>('name') == col);

  // Whether a column is declared NOT NULL (notnull==1) in the live schema.
  Future<bool> columnNotNull(AppDatabase db, String table, String col) async =>
      (await db.customSelect('PRAGMA table_info($table);').get())
          .where((r) => r.read<String>('name') == col)
          .first
          .read<int>('notnull') ==
      1;

  Future<int> count(AppDatabase db, String sql) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $sql;').getSingle())
          .read<int>('n');

  // A marker account (works on a fully-initialized DB).
  Future<void> insertMarker(AppDatabase db) async {
    await db.customStatement(
        "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
        "VALUES ('marker', 'Marker', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
      );
    await backfillNonPlanningMoneyV30(db);
  }

  Future<bool> markerPresent(AppDatabase db) async =>
      await count(db, "accounts WHERE id='marker'") == 1;

  // A marker transaction using only the ORIGINAL (v1-era) columns, so it can be
  // inserted into both a legacy fixture and the current schema.
  Future<void> insertTxMarker(AppDatabase db, String id) => db.customStatement(
        "INSERT INTO transactions(id, amount, currency, type, source, "
        "occurred_at, raw_message, parse_confidence, status, created_at, "
        "updated_at) VALUES ('$id', 12, 'SAR', 'payment', 'bank', "
        "'2026-01-01', 'marker', 0.9, 'confirmed', '2026-01-01', '2026-01-01');",
      );

  Future<bool> txPresent(AppDatabase db, String id) async =>
      await count(db, "transactions WHERE id='$id'") == 1;

  Future<List<Map<String, dynamic>>> fkViolations(AppDatabase db) async =>
      (await db.customSelect('PRAGMA foreign_key_check;').get())
          .map((r) => r.data)
          .toList();

  Future<void> assertFullyMigrated(AppDatabase db) async {
    expect(await userVersion(db), 45, reason: 'must reach target version');
    for (final t in const [
      'accounts',
      'transactions',
      'categories',
      'user_settings',
      'cards',
      'budgets',
      'goals',
      'subscriptions',
      'remote_banks',
      'planning_sync_outbox',
      'ledger_sync_outbox',
      'smart_inbox_items',
    ]) {
      expect(await tableExists(db, t), isTrue, reason: 'missing table $t');
    }
    // A representative sampling of columns added across the version history.
    expect(await columnExists(db, 'transactions', 'account_id'), isTrue);
    expect(await columnExists(db, 'transactions', 'direction'), isTrue);
    expect(await columnExists(db, 'transactions', 'server_updated_at'), isTrue);
    expect(await columnExists(db, 'categories', 'deleted_at'), isTrue);
    expect(await columnExists(db, 'user_settings', 'cloud_processing_enabled'),
        isTrue);
    expect(await columnExists(db, 'accounts', 'exclude_from_totals'), isTrue);
    expect(await fkViolations(db), isEmpty, reason: 'FK integrity');
  }

  // ─────────────────────────────── Fresh creation ──────────────────────────
  test('fresh database creation succeeds at the target version', () async {
    final db = await open();
    addTearDown(db.close);
    await assertFullyMigrated(db);
    expect(await count(db, 'accounts'), greaterThan(0)); // default account
    expect(await count(db, 'categories'), greaterThan(0)); // catalog seeded
  });

  test('foreign_key_check passes after a successful init', () async {
    final db = await open();
    addTearDown(db.close);
    expect(await fkViolations(db), isEmpty);
  });

  test('repeated initialization is idempotent', () async {
    final db = await open();
    addTearDown(db.close);
    await db.debugReinitialize();
    await db.debugReinitialize();
    expect(await userVersion(db), 45);
    expect(await count(db, 'accounts'), greaterThan(0));
  });

  // ───────────────────── Runtime integrity (NOT assert) ─────────────────────
  test(
      'post-migration foreign_key_check violation throws MigrationIntegrityException '
      '(runtime path, not an assert)', () async {
    final db = await open();
    addTearDown(db.close);
    // Insert a dangling FK with enforcement OFF (bypasses insert-time checks).
    // budgets.category_id -> categories(id); no backfill touches budgets, so the
    // orphan survives untouched to the unconditional postflight check.
    await db.customStatement('PRAGMA foreign_keys = OFF;');
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('b_orphan', 'no_such_category', 10, 'monthly', "
      "'2026-01-01', 1);",
    );

    await expectLater(
      db.debugReinitialize(),
      throwsA(isA<MigrationIntegrityException>()),
    );
  });

  test('a missing core table throws MigrationIntegrityException', () async {
    // Inject a fault that drops a core table just before the postflight
    // required-table check so it fails (and the whole migration rolls back).
    final db = await open(); // v27
    addTearDown(db.close);
    await db.customStatement('PRAGMA user_version = 1;'); // simulate an upgrade
    db.debugFailAtPhase = (p) async {
      if (p == 'postBackfill') {
        await db.customStatement('DROP TABLE user_settings;');
      }
    };
    await expectLater(
      db.debugReinitialize(),
      throwsA(isA<MigrationIntegrityException>()),
    );
    // Rolled back atomically: version not advanced, the dropped table restored.
    expect(await userVersion(db), 1);
    expect(await tableExists(db, 'user_settings'), isTrue);
  });

  // ─────────────────────── Downgrade guard (fail closed) ────────────────────
  test('a newer-than-app schema FAILS CLOSED with a distinguishable exception',
      () async {
    final db = await open();
    addTearDown(db.close);
    await insertMarker(db);
    await db.customStatement('PRAGMA user_version = 999;'); // newer than app

    // Fail closed: initialization throws, and the type is distinct from
    // corruption / migration-integrity failures so the caller can prompt an
    // app update rather than a wipe.
    Object? caught;
    try {
      await db.debugReinitialize();
    } catch (e) {
      caught = e;
    }
    expect(caught, isA<UnsupportedDatabaseVersionException>());
    expect(caught, isNot(isA<MigrationIntegrityException>()));
    expect((caught! as UnsupportedDatabaseVersionException).databaseVersion,
        999);
    expect((caught as UnsupportedDatabaseVersionException).supportedVersion, 45);

    // No schema/data change; user_version untouched; marker preserved.
    expect(await userVersion(db), 999);
    expect(await markerPresent(db), isTrue);
  });

  // ────────────── Deterministic failure injection: full rollback ────────────
  for (final phase in const [
    'preSchema',
    'postAlter',
    'postSeed',
    'postBackfill',
    'preVersion',
  ]) {
    test('failure at "$phase" rolls back: user_version + data unchanged',
        () async {
      final db = await open(); // fully initialized at v27
      addTearDown(db.close);
      await insertMarker(db);

      // Simulate an upgrade being needed, then inject a failure at this phase.
      await db.customStatement('PRAGMA user_version = 1;');
      db.debugFailAtPhase = (p) async {
        if (p == phase) throw StateError('boom-$phase');
      };

      await expectLater(db.debugReinitialize(), throwsA(isA<StateError>()));

      // Rollback: version NOT bumped, user data preserved.
      expect(await userVersion(db), 1, reason: 'user_version must not advance');
      expect(await markerPresent(db), isTrue, reason: 'data must survive');

      // Recovery: removing the injected failure lets init complete cleanly.
      db.debugFailAtPhase = null;
      await db.debugReinitialize();
      expect(await userVersion(db), 45);
      expect(await markerPresent(db), isTrue);
    });
  }

  // ─────────────── Memoization, failed-Future retry semantics ───────────────
  test('concurrent initialize() calls share ONE in-flight future (success)',
      () async {
    final db = uninitialized();
    addTearDown(db.close);
    final a = db.initialize();
    final b = db.initialize();
    expect(identical(a, b), isTrue); // same in-flight future → single run
    await Future.wait([a, b]);
    expect(await userVersion(db), 45);
  });

  test('a successful init runs exactly once (later initialize() is a no-op)',
      () async {
    final db = uninitialized();
    addTearDown(db.close);
    var runs = 0;
    db.debugFailAtPhase = (p) async {
      if (p == 'preSchema') runs++;
    };
    await db.initialize();
    final again = db.initialize();
    await again;
    expect(runs, 1, reason: 'the pipeline must not re-run on a cached success');
    expect(await userVersion(db), 45);
  });

  test('concurrent callers during a FAILING init share one execution',
      () async {
    final db = uninitialized();
    addTearDown(db.close);
    var runs = 0;
    db.debugFailAtPhase = (p) async {
      if (p == 'preSchema') {
        runs++;
        throw StateError('boom');
      }
    };
    final a = db.initialize();
    final b = db.initialize();
    expect(identical(a, b), isTrue); // one shared execution, not two
    await expectLater(a, throwsA(isA<StateError>()));
    await expectLater(b, throwsA(isA<StateError>()));
    expect(runs, 1);
  });

  test('a failed init is NOT cached — an explicit retry succeeds', () async {
    final db = uninitialized();
    addTearDown(db.close);
    db.debugFailAtPhase = (p) async {
      if (p == 'preSchema') throw StateError('transient');
    };
    await expectLater(db.initialize(), throwsA(isA<StateError>()));
    // The failed attempt built nothing (its transaction rolled back; the fault
    // fired at preSchema, before any table was created).
    expect(await tableExists(db, 'accounts'), isFalse);

    // The failure was NOT cached: a later explicit initialize() re-runs (rather
    // than replaying the cached failed future) and completes successfully.
    db.debugFailAtPhase = null;
    await db.initialize();
    expect(await userVersion(db), 45);
    expect(await count(db, 'accounts'), 0,
        reason: 'A-7: initialization never seeds an account');
  });

  // ───────────────── Historical-version support fixture matrix ──────────────
  // The migration model is SHAPE-BASED idempotent repair (CREATE ... IF NOT
  // EXISTS / ADD COLUMN IF NOT EXISTS + version-gated CREATE blocks), NOT
  // per-version snapshots. The meaningful structural variable is therefore
  // "which tables/columns are absent", so each fixture below reconstructs a
  // genuinely different absent-structure shape (not merely a changed
  // user_version on the current schema). See FULL_APP_AUDIT.md for the policy.

  // The minimal ORIGINAL (v1-era) core tables — columns absent that later
  // versions add via ADD COLUMN, tables absent that later versions CREATE.
  const legacyV1Schema = <String>[
    '''
      CREATE TABLE categories(
        id TEXT PRIMARY KEY, key TEXT NOT NULL UNIQUE, name_ar TEXT NOT NULL,
        icon TEXT NOT NULL, color TEXT NOT NULL, is_income INTEGER NOT NULL,
        sort_order INTEGER NOT NULL);
    ''',
    '''
      CREATE TABLE merchants(
        id TEXT PRIMARY KEY, raw_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE, first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL);
    ''',
    '''
      CREATE TABLE transactions(
        id TEXT PRIMARY KEY, amount REAL NOT NULL, currency TEXT NOT NULL,
        merchant_id TEXT NULL, raw_merchant TEXT NULL, category_id TEXT NULL,
        type TEXT NOT NULL, source TEXT NOT NULL, card_last4 TEXT NULL,
        balance_after REAL NULL, occurred_at TEXT NOT NULL,
        raw_message TEXT NOT NULL, parse_confidence REAL NOT NULL,
        status TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE SET NULL,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL);
    ''',
    '''
      CREATE TABLE user_settings(
        id TEXT PRIMARY KEY, country TEXT NOT NULL, currency TEXT NOT NULL,
        language TEXT NOT NULL, theme TEXT NOT NULL, input_method TEXT NOT NULL,
        notifications_json TEXT NOT NULL, db_encryption_key_ref TEXT NOT NULL);
    ''',
  ];

  test('fixture A — empty database (user_version 0) builds forward to v28',
      () async {
    final db = uninitialized(); // no user tables
    addTearDown(db.close);
    // Drift stamps user_version = schemaVersion on first open; reset it to 0 so
    // the pipeline genuinely discovers a from-scratch version and builds forward.
    await db.customStatement('PRAGMA user_version = 0;');
    expect(await userVersion(db), 0);
    await db.initialize();
    await assertFullyMigrated(db);
  });

  test('fixture B — legacy pre-accounts shape (v1) upgrades faithfully',
      () async {
    final db = uninitialized();
    addTearDown(db.close);
    for (final stmt in legacyV1Schema) {
      await db.customStatement(stmt);
    }
    await db.customStatement('PRAGMA user_version = 1;');
    // A real user's row, using only columns that existed at v1.
    await insertTxMarker(db, 'legacy_tx');
    // Prove the later columns/tables are genuinely absent before the upgrade.
    expect(await columnExists(db, 'transactions', 'account_id'), isFalse);
    expect(await tableExists(db, 'accounts'), isFalse);
    expect(await tableExists(db, 'cards'), isFalse);

    await db.initialize();

    await assertFullyMigrated(db);
    expect(await txPresent(db, 'legacy_tx'), isTrue, reason: 'data preserved');
    // A-7: no account is seeded, so with zero accounts the legacy row is left
    // untouched (orphan, account_id NULL) rather than attached to an invented
    // account.
    final accountId = (await db.customSelect(
      "SELECT account_id FROM transactions WHERE id='legacy_tx';",
    ).getSingle())
        .data['account_id'];
    expect(accountId, isNull);
    expect(await count(db, 'accounts'), 0);
  });

  test(
      'fixture C — pre-v27 cards (account_id NOT NULL) is rebuilt NULLable, '
      'data preserved', () async {
    // Start from the current schema, then structurally REVERT the cards table to
    // its faithful pre-v27 shape (account_id NOT NULL, no color_theme/accent_hex
    // — those are added at v27 right before the relax). Nothing references cards,
    // so a drop/recreate is safe.
    final db = await open();
    addTearDown(db.close);
    await db.customStatement('PRAGMA foreign_keys = OFF;');
    await db.customStatement('DROP TABLE cards;');
    await db.customStatement('''
      CREATE TABLE cards(
        id TEXT PRIMARY KEY,
        account_id TEXT NOT NULL,
        nickname TEXT NULL,
        last4 TEXT NOT NULL,
        network TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual','auto')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only','synced','pending','conflict')),
        deleted_at TEXT NULL
      );
    ''');
    await db.customStatement(
      "INSERT INTO cards(id, account_id, last4, network, created_at, updated_at) "
      "VALUES ('card_marker', 'acct_x', '1234', 'visa', '2026-01-01', "
      "'2026-01-01');",
    );
    await db.customStatement('PRAGMA user_version = 26;');
    expect(await columnNotNull(db, 'cards', 'account_id'), isTrue);
    expect(await columnExists(db, 'cards', 'color_theme'), isFalse);

    await db.debugReinitialize();

    expect(await userVersion(db), 45);
    expect(await columnNotNull(db, 'cards', 'account_id'), isFalse,
        reason: 'account_id relaxed to NULLable');
    expect(await columnExists(db, 'cards', 'color_theme'), isTrue);
    expect(await count(db, "cards WHERE id='card_marker'"), 1,
        reason: 'card row preserved across the rebuild');
    final acct = (await db.customSelect(
      "SELECT account_id FROM cards WHERE id='card_marker';",
    ).getSingle())
        .data['account_id'];
    expect(acct, 'acct_x', reason: 'value preserved');
    expect(await fkViolations(db), isEmpty);
  });

  test(
      'stale user_version on an already-current schema is a safe idempotent '
      'no-op (not a fake upgrade)', () async {
    // Distinct from the faithful fixtures above: this is the defensive case
    // where the schema is already current but user_version lags. The idempotent
    // repairs must simply re-affirm and bump the version — changing nothing.
    final db = await open();
    addTearDown(db.close);
    await insertMarker(db);
    await db.customStatement('PRAGMA user_version = 5;');

    await db.debugReinitialize();

    expect(await userVersion(db), 45);
    expect(await markerPresent(db), isTrue);
    expect(await fkViolations(db), isEmpty);
  });
}
