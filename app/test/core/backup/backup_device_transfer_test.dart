import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:money_companion/core/backup/backup_crypto.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase sourceDevice;
  late AppDatabase targetDevice;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    sourceDevice = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    await seedTestAccount(sourceDevice);
    targetDevice = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    // A new device has no account yet (A-7), so the restore applies the whole
    // backup (SP-02: a device holding any user record merges instead).
  });

  tearDown(() async {
    await sourceDevice.close();
    await targetDevice.close();
  });

  test('encrypted backup moves data from one device to another', () async {
    await _seedSourceDevice(sourceDevice);

    final sourceSnapshot = await BackupSnapshotBuilder(sourceDevice).build();
    final crypto = BackupCrypto(
      kdf: Argon2id(
        memory: 1024,
        parallelism: 1,
        iterations: 1,
        hashLength: 32,
      ),
    );
    final encryptedBlob = await crypto.encryptJson(
      json: sourceSnapshot,
      passphrase: 'my backup passphrase',
      salt: List<int>.filled(16, 9),
    );

    final downloadedSnapshot = await crypto.decryptJson(
      blob: EncryptedBackupBlob.fromBytes(encryptedBlob.toBytes()),
      passphrase: 'my backup passphrase',
    );
    await RestoreBackupUseCase(targetDevice)(downloadedSnapshot);

    final restoredTransaction = await targetDevice.customSelect(
      '''
        SELECT amount, currency, raw_merchant, raw_message, status
        FROM transactions
        WHERE id = 'tx_device_a_1';
      ''',
    ).getSingle();
    expect(restoredTransaction.read<double>('amount'), 470);
    expect(restoredTransaction.read<String>('currency'), 'EGP');
    expect(restoredTransaction.read<String>('raw_merchant'), 'IPN Transfer');
    expect(restoredTransaction.read<String>('status'), 'confirmed');
    expect(
      restoredTransaction.read<String>('raw_message'),
      '[restored: raw message intentionally excluded]',
    );

    final restoredBudget = await targetDevice
        .customSelect(
          "SELECT amount, period FROM budgets WHERE id = 'budget_device_a_1';",
        )
        .getSingle();
    expect(restoredBudget.read<double>('amount'), 5000);
    expect(restoredBudget.read<String>('period'), 'monthly');

    final restoredGoal = await targetDevice
        .customSelect(
          "SELECT name, target_amount FROM goals WHERE id = 'goal_device_a_1';",
        )
        .getSingle();
    expect(restoredGoal.read<String>('name'), 'سفر');
    expect(restoredGoal.read<double>('target_amount'), 20000);

    final restoredSettings = await targetDevice
        .customSelect(
          'SELECT country, currency FROM user_settings LIMIT 1;',
        )
        .getSingle();
    expect(restoredSettings.read<String>('country'), 'EG');
    expect(restoredSettings.read<String>('currency'), 'EGP');

    final restoredPayment = await targetDevice
        .customSelect(
          "SELECT amount, transaction_id FROM bill_payments WHERE id = 'payment_device_a_1';",
        )
        .getSingle();
    expect(restoredPayment.read<double>('amount'), 125);
    expect(restoredPayment.read<String>('transaction_id'), 'tx_device_a_1');

    final restoredPlanLink = await targetDevice
        .customSelect(
          "SELECT transaction_id FROM plan_transaction_links WHERE plan_id = 'plan_device_a_1';",
        )
        .getSingle();
    expect(restoredPlanLink.read<String>('transaction_id'), 'tx_device_a_1');
  });
}

Future<void> _seedSourceDevice(AppDatabase db) async {
  const now = '2026-06-28T10:00:00.000Z';
  final category = await db
      .customSelect(
        "SELECT id FROM categories WHERE key = 'transfers' LIMIT 1;",
      )
      .getSingle();
  final categoryId = category.read<String>('id');

  await db.customStatement(
    "UPDATE user_settings SET country = 'EG', currency = 'EGP';",
  );
  await db.customInsert(
    '''
      INSERT INTO transactions(
        id, amount, currency, merchant_id, raw_merchant, category_id, type,
        source, card_last4, balance_after, note, occurred_at, raw_message,
        parse_confidence, status, created_at, updated_at
      )
      VALUES (?, 470.0, 'EGP', NULL, 'IPN Transfer', ?, 'transfer',
        'aiParsed', NULL, NULL, 'device A transfer', ?, ?,
        0.91, 'confirmed', ?, ?);
    ''',
    variables: [
      Variable.withString('tx_device_a_1'),
      Variable.withString(categoryId),
      Variable.withString(now),
      Variable.withString('SECRET RAW BANK SMS FROM DEVICE A'),
      Variable.withString(now),
      Variable.withString(now),
    ],
  );
  await db.customInsert(
    '''
      INSERT INTO budgets(
        id, category_id, currency, amount, amount_minor, period, start_date,
        is_active, last_notified_spent_amount,
        last_notified_spent_amount_minor, last_notified_period_start
      )
      VALUES (?, ?, 'EGP', 5000.0, 500000, 'monthly', ?, 1, 0, 0,
        '2000-01-01T00:00:00Z');
    ''',
    variables: [
      Variable.withString('budget_device_a_1'),
      Variable.withString(categoryId),
      Variable.withString('2026-06-01T00:00:00.000Z'),
    ],
  );
  await db.customInsert(
    '''
      INSERT INTO goals(
        id, name, currency, target_amount, target_amount_minor, saved_amount,
        saved_amount_minor, last_notified_saved_amount_minor, deadline,
        vault_skin, status, created_at
      )
      VALUES (?, 'سفر', 'EGP', 20000.0, 2000000, 3500.0, 350000, 0,
        '2026-12-31T00:00:00.000Z', 'default', 'active', ?);
    ''',
    variables: [
      Variable.withString('goal_device_a_1'),
      Variable.withString(now),
    ],
  );
  await db.customInsert(
    '''
      INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
      VALUES ('merchant_backup_bill', 'Internet', 'internet', ?, ?);
    ''',
    variables: [Variable.withString(now), Variable.withString(now)],
  );
  await db.customInsert(
    '''
      INSERT INTO subscriptions(
        id, merchant_id, amount, period, next_due_date, is_confirmed,
        reminder_on, name, type, currency, frequency, created_at
      ) VALUES (
        'bill_device_a_1', 'merchant_backup_bill', 125, 'monthly', ?, 1,
        1, 'Internet', 'subscription', 'EGP', 'monthly', ?
      );
    ''',
    variables: [Variable.withString(now), Variable.withString(now)],
  );
  await db.customInsert(
    '''
      INSERT INTO bill_payments(
        id, bill_id, amount, currency, period_start, period_end, paid_at,
        transaction_id
      ) VALUES (
        'payment_device_a_1', 'bill_device_a_1', 125, 'EGP', ?, ?, ?,
        'tx_device_a_1'
      );
    ''',
    variables: [
      Variable.withString('2026-06-01T00:00:00.000Z'),
      Variable.withString('2026-06-30T23:59:59.000Z'),
      Variable.withString(now),
    ],
  );
  await db.customInsert(
    '''
      INSERT INTO plans(
        id, name, budget_amount, currency, start_date, end_date,
        account_ids, card_last4s, status, created_at
      ) VALUES (
        'plan_device_a_1', 'Summer', 10000, 'EGP', ?, ?, '', '', 'active', ?
      );
    ''',
    variables: [
      Variable.withString('2026-06-01T00:00:00.000Z'),
      Variable.withString('2026-08-31T23:59:59.000Z'),
      Variable.withString(now),
    ],
  );
  await db.customInsert(
    '''
      INSERT INTO plan_transaction_links(plan_id, transaction_id, created_at)
      VALUES ('plan_device_a_1', 'tx_device_a_1', ?);
    ''',
    variables: [Variable.withString(now)],
  );
  await backfillNonPlanningMoneyV30(db);
}
