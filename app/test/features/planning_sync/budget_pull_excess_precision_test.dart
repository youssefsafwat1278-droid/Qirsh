// Regression: a fresh install restored every planning entity except budgets.
// One server budget carried last_notified_spent_amount with 12 decimals (an
// old client pushed a double); the strict parse threw DecimalFormatException,
// which rolled back the whole budgets page on every sync.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';

const _goal = PlanningOutboxQueue.goalsEntityType; // 'goal'

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

/// A cursor-aware fake: returns the rows strictly after `after` (like the server),
/// so once the cursor advances past the page a re-pull returns empty.
class _PageRemote implements PlanningRemoteSource {
  _PageRemote(this.table, this.rows);
  final String table;
  final List<Map<String, dynamic>> rows;
  int fetches = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String t, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    if (t != table) return const [];
    fetches++;
    return rows.where((r) => _gt(r, after)).take(limit).toList();
  }

  bool _gt(Map<String, dynamic> r, SyncCursor after) {
    if (after.id.isEmpty) return true;
    final u = r['updated_at'] as String;
    if (u != after.updatedAt) return u.compareTo(after.updatedAt) > 0;
    return (r['id'] as String).compareTo(after.id) > 0;
  }
}

Map<String, dynamic> _goalRow(String id, String? currency,
        {bool deleted = false}) =>
    {
      'id': id,
      'local_id': null,
      'name': 'g-$id',
      'currency': currency, // null → unresolved currency
      'target_amount_text': '100.000',
      'saved_amount_text': '0.000',
      'last_notified_saved_amount_text': '0.000',
      'auto_save_amount_text': null,
      'vault_skin': 'classic',
      'status': 'active',
      'created_at': '2026-01-01T00:00:00.000Z',
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': deleted ? '2026-08-02T00:00:00.000Z' : null,
    };

const _budget = PlanningOutboxQueue.budgetsEntityType;

Map<String, dynamic> _budgetRow(String id, String? currency,
        {bool deleted = false}) =>
    {
      'id': id,
      'local_id': null,
      'category_id': 'other',
      'amount_text': '200.00',
      'currency': currency,
      'last_notified_spent_amount_text': '0.00',
      'period': 'monthly',
      'start_date': '2026-01-01',
      'is_active': true,
      'last_notified_period_start': '2026-01-01T00:00:00Z',
      'show_on_header': false,
      'local_account_id': null,
      'updated_at': '2026-08-01T00:00:00.000Z',
      'deleted_at': deleted ? '2026-08-02T00:00:00.000Z' : null,
    };

PlanningPullService _svc(AppDatabase db, PlanningRemoteSource remote) =>
    PlanningPullService(
      db: db,
      isEnabled: (e) => e == _goal || e == _budget,
      getAuthUserId: () async => 'user-1',
      remoteSource: remote,
      mayEgress: () async => true,
    );

Future<int> _count(AppDatabase db, String sql) async =>
    (await db.customSelect(sql).getSingle()).read<int>('n');

Future<AppDatabase> _db() async {
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
  addTearDown(db.close);
  return db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a double-noisy last_notified_spent_amount is quantized, and every '
      'budget in the page restores', () async {
    final db = await _db();
    final noisy = _budgetRow('b-noisy', 'EGP')
      ..['last_notified_spent_amount_text'] = '1234.560000000002';
    final healthy = _budgetRow('b-ok', 'EGP')
      ..['updated_at'] = '2026-08-03T00:00:00.000Z';
    await _svc(db, _PageRemote('user_budgets', [noisy, healthy])).pull();

    expect(await _count(db, 'SELECT COUNT(*) n FROM budgets WHERE server_id IS NOT NULL'), 2);
    final minor = (await db
            .customSelect("SELECT last_notified_spent_amount_minor m FROM budgets WHERE server_id='b-noisy'")
            .getSingle())
        .read<int>('m');
    expect(minor, 123456);
  });

  test('a budget AMOUNT with excess precision stays strict but is row-level: '
      'it is quarantined and the rest of the page still restores', () async {
    final db = await _db();
    final bad = _budgetRow('b-bad', 'EGP')..['amount_text'] = '10.123';
    final ok = _budgetRow('b-ok', 'EGP')
      ..['updated_at'] = '2026-08-03T00:00:00.000Z';
    await _svc(db, _PageRemote('user_budgets', [bad, ok])).pull();

    expect(await _count(db, "SELECT COUNT(*) n FROM budgets WHERE server_id='b-ok'"), 1);
    expect(await _count(db, "SELECT COUNT(*) n FROM budgets WHERE server_id='b-bad'"), 0);
  });

  test('goal last_notified_saved_amount noise is quantized too', () async {
    final db = await _db();
    final g = _goalRow('g-1', 'EGP')
      ..['target_amount_text'] = '100.00'
      ..['saved_amount_text'] = '0.00'
      ..['last_notified_saved_amount_text'] = '10.000000000001';
    await _svc(db, _PageRemote('user_goals', [g])).pull();
    expect(await _count(db, "SELECT COUNT(*) n FROM goals WHERE server_id='g-1'"), 1);
  });
}
