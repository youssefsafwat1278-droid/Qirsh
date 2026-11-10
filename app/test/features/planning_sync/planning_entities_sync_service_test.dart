import '../capture/ledger_admission_fixture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/planning_sync/services/planning_pull_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';


class _FakePlanningRemote implements PlanningRemoteSink, PlanningRemoteSource {
  final rows = <String, Map<String, Map<String, dynamic>>>{};
  final tombstones = <String, List<Map<String, dynamic>>>{};
  int upserts = 0;
  int deletes = 0;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final byId = <String, Map<String, dynamic>>{};
    for (final row in <Map<String, dynamic>>[
      ...?rows[table]?.values,
      ...?tombstones[table],
    ]) {
      byId[row['id'] as String] = row;
    }
    final ordered = byId.values.map(Map<String, dynamic>.from).toList()
      ..sort((left, right) {
        final timestamp = normalizeCursorTimestamp(left['updated_at'])
            .compareTo(normalizeCursorTimestamp(right['updated_at']));
        if (timestamp != 0) return timestamp;
        return (left['id'] as String).compareTo(right['id'] as String);
      });
    return ordered
        .where((row) {
          if (after.id.isEmpty) return true;
          final timestamp = normalizeCursorTimestamp(row['updated_at']);
          final comparison = timestamp.compareTo(after.updatedAt);
          return comparison > 0 ||
              (comparison == 0 &&
                  (row['id'] as String).compareTo(after.id) > 0);
        })
        .map(_projectTextAliases)
        .take(limit)
        .toList();
  }

  // MALI-026 (B8-3 §9): mirror the server's `amount::text` projection — the exact
  // pull reads `<col>_text` decimal strings. This lets a canonical-pushed row
  // round-trip through pull exactly, just as PostgREST would return it.
  static const _moneyTextColumns = [
    'amount',
    'last_notified_spent_amount',
    'target_amount',
    'saved_amount',
    'last_notified_saved_amount',
    'auto_save_amount',
    'budget_amount',
    'manual_paid_amount',
    'total_purchase_amount',
  ];

  Map<String, dynamic> _projectTextAliases(Map<String, dynamic> row) {
    final out = Map<String, dynamic>.from(row);
    for (final col in _moneyTextColumns) {
      if (out.containsKey(col)) {
        out.putIfAbsent('${col}_text', () => out[col]?.toString());
      }
    }
    return out;
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  ) async {
    return rows[table]?[localId];
  }

  Future<void> _tombstone(String table, String serverId) async {
    deletes++;
    final match = rows[table]?.values.firstWhere(
          (row) => row['id'] == serverId,
          orElse: () => <String, dynamic>{},
        );
    if (match == null || match.isEmpty) return;
    final deletedAt = DateTime.utc(2026, 7, 6).toIso8601String();
    match['deleted_at'] = deletedAt;
    match['updated_at'] = deletedAt;
    tombstones.putIfAbsent(table, () => []).add(Map.of(match));
  }

    Future<Map<String, dynamic>?> casTombstone(
      String table, String serverId, int expectedRevision) async {
    await _tombstone(table, serverId);
    return {'id': serverId, 'revision': expectedRevision + 1};
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
      String table, String serverId, String? expectedUpdatedAt) async {
    await _tombstone(table, serverId);
    return {'id': serverId};
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(
          String table, String serverId) async =>
      null;

  @override
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  ) async {
    upserts++;
    final localId = row['local_id'] as String;
    final now = DateTime.utc(2026, 7, 5, 1).toIso8601String();
    final saved = {
      ...row,
      'id': rows[table]?[localId]?['id'] ?? 'server-$table-$localId',
      'updated_at': now,
      'deleted_at': null,
    };
    rows.putIfAbsent(table, () => {})[localId] = saved;
    return {'id': saved['id'], 'updated_at': now};
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    for (final row in rows[table]?.values ?? const <Map<String, dynamic>>[]) {
      if (row['id'] == serverId) return row['updated_at'] as String?;
    }
    return null;
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: this fake genuinely SIMULATES the database predicate — it refuses
    // the write when the server row has moved past the caller's base. A fake
    // that merely delegated to the unguarded update would make the
    // conflict-without-clobbering test pass for the wrong reason: the write
    // would land, and the assertion would be measuring the old racy behaviour.
    final current = await fetchServerUpdatedAt(table, serverId);
    if (current != null && current != expectedUpdatedAt) return null;
    return updateByServerId(table, serverId, row);
  }

  @override
  Future<Map<String, dynamic>> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  ) {
    // Keyed by (user_id, local_id) in the fake store — upsert is equivalent.
    return upsert(table, row);
  }



    Future<Map<String, dynamic>?> casUpdateByServerId(
    String table,
    String serverId,
    int expectedRevision,
    Map<String, dynamic> row,
  ) {
    throw UnimplementedError('CAS is exercised by the dedicated CAS test');
  }
}


PlanningOutboxQueue _queue(
  AppDatabase db, {
  required bool enabled,
  String? userId = 'user-1',
}) {
  return PlanningOutboxQueue(
    db: db,
    isSyncEnabled: (_) => enabled,
    getAuthUserId: () async => userId,
  );
}

Future<int> _outboxCount(AppDatabase db) async {
  final row = await db
      .customSelect('SELECT COUNT(*) AS total FROM planning_sync_outbox;')
      .getSingle();
  return row.read<int>('total');
}

BudgetEntity _budget(String id) => BudgetEntity(
      id: id,
      categoryId: BudgetEntity.allExpensesCategoryId,
      currency: 'SAR',
      amountMoney: Money.parse('500', 'SAR'),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7, 1),
      isActive: true,
      lastNotifiedSpentMoney: Money(0, 'SAR'),
      lastNotifiedPeriodStart: DateTime.utc(2000, 1, 1),
      showOnHeader: true,
    );

BillEntity _bill(String id) => BillEntity(
      id: id,
      name: 'Netflix',
      amountMoney: Money.fromLegacyReal(39, 'SAR'),
      currency: 'SAR',
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 7, 10),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 7, 1),
    );

GoalEntity _goal(String id) => GoalEntity(
      id: id,
      name: 'Travel',
      currency: 'SAR',
      targetMoney: Money.parse('5000', 'SAR'),
      savedMoney: Money.parse('300', 'SAR'),
      lastNotifiedSavedMoney: Money(0, 'SAR'),
      vaultSkin: 'classic',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

PlanEntity _plan(String id) => PlanEntity(
      id: id,
      name: 'Summer',
      budgetAmountMoney: Money.fromLegacyReal(2000, 'SAR'),
      currency: 'SAR',
      startDate: DateTime.utc(2026, 7, 1),
      endDate: DateTime.utc(2026, 7, 31),
      accountIds: const [],
      cardLast4s: const ['1234'],
      status: PlanStatus.active,
      createdAt: DateTime.utc(2026, 7, 1),
    );

late LedgerAdmissionFixture _parentAdmission;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planning entity sync foundations', () {
    late AppDatabase db;

    setUp(() async {
      _parentAdmission = await LedgerAdmissionFixture.open('user-1');
    db = _parentAdmission.database;
    });

    tearDown(() async {
      await _parentAdmission.finish();
    });

    test('planning flags OFF still record sync intent (A-2 G5)', () async {
      final queue = _queue(db, enabled: false);
      await DriftBudgetRepository(db, outboxQueue: queue).save(_budget('b1'));
      await DriftBillRepository(db, outboxQueue: queue).save(_bill('s1'));
      await DriftGoalRepository(db, outboxQueue: queue).save(_goal('g1'));
      await DriftPlanRepository(db, outboxQueue: queue).save(_plan('p1'));

      // The flag gates sending (the push checks it), never recording intent.
      expect(await _outboxCount(db), 4);
    });

    test('guest user does not queue planning writes when flags are ON',
        () async {
      final queue = _queue(db, enabled: true, userId: null);
      await DriftBudgetRepository(db, outboxQueue: queue).save(_budget('b1'));
      await DriftBillRepository(db, outboxQueue: queue).save(_bill('s1'));
      await DriftGoalRepository(db, outboxQueue: queue).save(_goal('g1'));
      await DriftPlanRepository(db, outboxQueue: queue).save(_plan('p1'));

      expect(await _outboxCount(db), 0);
    });

    test('legacy cloud NULL preserves local custom warning and queues its upgrade', () async {
      final queue = _queue(db, enabled: true);
      await DriftBudgetRepository(db).save(_budget('legacy').copyWith(alertThresholdPercent: 70));
      await db.customStatement("UPDATE budgets SET server_id='server-legacy', sync_status='synced', server_updated_at='2026-07-01T00:00:00Z' WHERE id='legacy';");
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {'legacy': {
        'id':'server-legacy', 'local_id':'legacy', 'category_id':'all_expenses',
        'currency':'SAR', 'amount':500, 'period':'monthly',
        'start_date':'2026-07-01T00:00:00Z', 'is_active':true,
        'last_notified_spent_amount':0, 'last_notified_period_start':'2000-01-01T00:00:00Z',
        'alert_threshold_percent':null, 'updated_at':'2026-07-02T00:00:00Z', 'deleted_at':null,
      }};
      final pull = PlanningPullService(db: db, isEnabled: (e) => e == 'budget',
        getAuthUserId: () async => 'user-1', remoteSource: remote,
        outboxQueue: queue, mayEgress: () async => true);
      await pull.pull();
      expect((await DriftBudgetRepository(db).getById('legacy'))!.alertThresholdPercent, 70);
      final pending = await db.customSelect("SELECT payload_json FROM planning_sync_outbox WHERE entity_type='budget';").get();
      expect(pending, hasLength(1));
      expect(pending.single.read<String>('payload_json'), contains('"alert_threshold_percent":70'));
    });

    test('signed-in flag ON queues and pushes create update delete', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );

      final budgets = DriftBudgetRepository(db, outboxQueue: queue);
      final bills = DriftBillRepository(db, outboxQueue: queue);
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      final plans = DriftPlanRepository(db, outboxQueue: queue);

      await budgets.save(_budget('b1'));
      await budgets.save(
        _budget('b1').copyWith(amountMoney: Money.parse('600', 'SAR'), alertThresholdPercent: 70),
      );
      await budgets.save(_budget('b-delete'));
      await budgets.delete('b-delete');
      await bills.save(_bill('s1'));
      await goals.save(_goal('g1'));
      await plans.save(_plan('p1'));

      final result = await push.push();

      expect(result.failed, 0);
      // MALI-052n coalescing: b1's create+update fold into one create carrying
      // the latest amount; b-delete's create+delete (both offline, never synced)
      // drop entirely (no server round-trip). So exactly 4 pushes: b1, s1, g1, p1.
      expect(result.pushed, 4);
      expect(await _outboxCount(db), 0);
      expect(remote.rows['user_budgets']?['b1']?['amount'], 600);
      expect(remote.rows['user_budgets']?['b1']?['alert_threshold_percent'], 70);
      expect(remote.rows['user_subscriptions']?['s1']?['name'], 'Netflix');
      expect(remote.rows['user_goals']?['g1']?['saved_amount'], 300);
      expect(remote.rows['user_plans']?['p1']?['name'], 'Summer');
      expect(remote.deletes, 0,
          reason: 'b-delete was created+deleted offline → coalesced away');
    });

    test(
        'pull imports once, duplicate pull does not duplicate, tombstone hides',
        () async {
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {
        'remote-budget': {
          'id': 'server-budget',
          'local_id': 'remote-budget',
          // The server stores the portable key, while Drift uses a synthetic
          // local FK id for the all-expenses budget.
          'category_id': BudgetEntity.allExpensesCategoryKey,
          'currency': 'SAR',
          'amount': 750,
          'alert_threshold_percent': 95,
          'period': 'monthly',
          'start_date': DateTime.utc(2026, 7, 1).toIso8601String(),
          'is_active': true,
          'last_notified_spent_amount': 0,
          'last_notified_period_start': '2000-01-01T00:00:00Z',
          'show_on_header': true,
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': null,
        },
      };
      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

      final first = await pull.pull();
      final second = await pull.pull();

      expect(first.imported, 1);
      expect(second.imported, 0);
      final count = await db
          .customSelect(
            "SELECT COUNT(*) AS total FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(count.read<int>('total'), 1);
      expect((await DriftBudgetRepository(db).getById('remote-budget'))!.alertThresholdPercent, 95);
      final importedCategory = await db
          .customSelect(
            "SELECT category_id FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(
        importedCategory.read<String>('category_id'),
        BudgetEntity.allExpensesCategoryId,
      );

      remote.tombstones['user_budgets'] = [
        {
          'id': 'server-budget',
          'local_id': 'remote-budget',
          'deleted_at': DateTime.utc(2026, 7, 3).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 3).toIso8601String(),
        }
      ];

      final tombstone = await pull.pull();

      expect(tombstone.tombstoned, 1);
      expect(await DriftBudgetRepository(db).getById('remote-budget'), isNull);
      final deleted = await db
          .customSelect(
            "SELECT deleted_at FROM budgets WHERE id = 'remote-budget';",
          )
          .getSingle();
      expect(deleted.readNullable<String>('deleted_at'), isNotNull);
    });

    test('parent pull paginates each planning entity with its own cursor',
        () async {
      final remote = _FakePlanningRemote();
      remote.rows['user_budgets'] = {
        for (var index = 0; index < 3; index++)
          'budget-$index': {
            'id': 'server-budget-$index',
            'local_id': 'budget-$index',
            'category_id': BudgetEntity.allExpensesCategoryKey,
            'currency': 'SAR',
            'amount': 100 + index,
            'last_notified_spent_amount': 0,
            'period': 'monthly',
            'start_date': '2026-07-01T00:00:00.000Z',
            'is_active': true,
            'updated_at': '2026-07-10T00:00:00.000Z',
            'deleted_at': null,
          },
      };

      final result = await PlanningPullService(
        db: db,
        isEnabled: (entity) => entity == PlanningOutboxQueue.budgetsEntityType,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        pageSize: 2,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  ).pull();

      expect(result.imported, 3);
      expect(await db.count('budgets'), 3);
      expect(
        (await readSyncCursor(db, 'planning_budget')).id,
        'server-budget-2',
      );
    });

    test('pull marks pending local planning row as conflict', () async {
      final remote = _FakePlanningRemote();
      await DriftGoalRepository(db).save(_goal('conflict-goal'));
      await db.customStatement(
        "UPDATE goals SET sync_status = 'pending' WHERE id = 'conflict-goal';",
      );
      remote.rows['user_goals'] = {
        'conflict-goal': {
          'id': 'server-conflict-goal',
          'local_id': 'conflict-goal',
          'name': 'Remote',
          'currency': 'SAR',
          'target_amount': 9000,
          'saved_amount': 100,
          'last_notified_saved_amount': 0,
          'vault_skin': 'classic',
          'status': 'active',
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': null,
        }
      };

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

      final result = await pull.pull();

      expect(result.conflicts, 1);
      final row = await db
          .customSelect(
            "SELECT name, sync_status FROM goals WHERE id = 'conflict-goal';",
          )
          .getSingle();
      expect(row.read<String>('name'), 'Travel');
      expect(row.readNullable<String>('sync_status'), 'conflict');
    });

    test('pull marks pending local planning row as conflict — clears the ambiguous in-flight marker so keep-remote can resolve (D)', () async {
      final remote = _FakePlanningRemote();
      await DriftGoalRepository(db).save(_goal('conflict-goal'));
      await db.customStatement(
        "UPDATE goals SET sync_status = 'pending' WHERE id = 'conflict-goal';",
      );
      await db.customStatement(
        "INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation, "
        "payload_json, attempt_count, status, created_at, updated_at, op_seq, "
        "in_flight_seq) VALUES ('o1', 'goal', 'conflict-goal', 'update', "
        "'{}', 0, 'pending', '2026-07-01T00:00:00Z', '2026-07-01T00:00:00Z', 1, 1);",
      );
      remote.rows['user_goals'] = {
        'conflict-goal': {
          'id': 'server-conflict-goal',
          'local_id': 'conflict-goal',
          'name': 'Remote',
          'currency': 'SAR',
          'target_amount': 9000,
          'saved_amount': 100,
          'last_notified_saved_amount': 0,
          'vault_skin': 'classic',
          'status': 'active',
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': null,
        }
      };

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );

      final result = await pull.pull();

      expect(result.conflicts, 1);
      expect(
          (await db.customSelect("SELECT in_flight_seq AS m FROM planning_sync_outbox WHERE id = 'o1';").getSingle())
              .readNullable<int>('m'),
          isNull,
          reason: 'a pull-raised conflict clears the ambiguous marker');
      final row = await db
          .customSelect(
            "SELECT name, sync_status FROM goals WHERE id = 'conflict-goal';",
          )
          .getSingle();
      expect(row.read<String>('name'), 'Travel');
      expect(row.readNullable<String>('sync_status'), 'conflict');
      await db.customStatement("UPDATE goals SET server_id = 'server-conflict-goal' WHERE id = 'conflict-goal';");
      expect(
          await UniversalConflictResolver(db: db, reEnqueue: const {})
              .resolveKeepRemote('goal', 'conflict-goal'),
          isTrue);
    });

    test(
        'push conflicts WITHOUT clobbering when the server moved past the base '
        '(MALI-022)', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final budgets = DriftBudgetRepository(db, outboxQueue: queue);

      // Create + push → synced; base token captured.
      await budgets.save(_budget('b1'));
      await push.push();

      // Another device moves the server row past our base.
      remote.rows['user_budgets']!['b1']!['updated_at'] =
          DateTime.utc(2030, 1, 1).toIso8601String();
      remote.rows['user_budgets']!['b1']!['amount'] = 999;

      // Local edit against the OLD base, then push.
      await budgets.save(
        _budget('b1').copyWith(amountMoney: Money.parse('123', 'SAR')),
      );
      final result = await push.push();

      expect(result.conflicts, 1);
      expect(result.pushed, 0);
      // Remote edit NOT clobbered.
      expect(remote.rows['user_budgets']!['b1']!['amount'], 999);
      // Local edit preserved and flagged for resolution.
      final local = await db
          .customSelect(
              "SELECT amount, sync_status FROM budgets WHERE id='b1';")
          .getSingle();
      expect(local.read<double>('amount'), 123);
      expect(local.readNullable<String>('sync_status'), 'conflict');
    });

    test(
        'pull does NOT conflict a pending edit when the server is unchanged '
        '(MALI-022 false-positive fix)', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      await goals.save(_goal('g1'));
      await push.push(); // synced; base == server updated_at

      // Local edit → pending; the server row is NOT touched.
      await goals.save(
        _goal('g1').copyWith(savedMoney: Money.parse('777', 'SAR')),
      );
      // §9: the exact pull reads the server row currency; a canonical server row
      // carries it (0077). The legacy push fake omits it, so supply it here.
      remote.rows['user_goals']!['g1']!['currency'] = 'SAR';

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );
      final result = await pull.pull();

      expect(result.conflicts, 0);
      final row = await db
          .customSelect(
              "SELECT sync_status, saved_amount FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.readNullable<String>('sync_status'), 'pending');
      expect(row.read<double>('saved_amount'), 777);
    });

    test(
        'pull conflicts a pending edit only when the server actually moved '
        '(MALI-022)', () async {
      final remote = _FakePlanningRemote();
      final queue = _queue(db, enabled: true);
      final push = PlanningPushService(
        mayEgress: () async => true,
        db: db,
        queue: queue,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSink: remote,
      );
      final goals = DriftGoalRepository(db, outboxQueue: queue);
      await goals.save(_goal('g1'));
      await push.push();

      await goals.save(
        _goal('g1').copyWith(savedMoney: Money.parse('777', 'SAR')),
      );
      // Server moves past our base.
      remote.rows['user_goals']!['g1']!['updated_at'] =
          DateTime.utc(2030, 1, 1).toIso8601String();
      remote.rows['user_goals']!['g1']!['currency'] = 'SAR';

      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
      
    // C-3: covers pull MECHANICS; consent is asserted in
    // financial_pull_consent_test.dart.
    mayEgress: () async => true,
  );
      final result = await pull.pull();

      expect(result.conflicts, 1);
      final row = await db
          .customSelect(
              "SELECT sync_status, saved_amount FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.readNullable<String>('sync_status'), 'conflict');
      expect(row.read<double>('saved_amount'), 777); // local edit not clobbered
    });
  });

  // ---- WP-5: lost-ACK receipt + durable conflict on the planning pull ------
  group('WP-5 planning pull: receipts and durable conflicts', () {
    late AppDatabase db;
    setUp(() async { _parentAdmission = await LedgerAdmissionFixture.open('user-1'); db = _parentAdmission.database; });
    tearDown(() => _parentAdmission.finish());

    Map<String, dynamic> remoteGoal({String? lastOp, String? deletedAt, int revision = 2}) => {
          'id': 'server-g1',
          'local_id': 'g1',
          'name': 'Remote',
          'currency': 'SAR',
          'target_amount': 9000,
          'saved_amount': 100,
          'last_notified_saved_amount': 0,
          'vault_skin': 'classic',
          'status': 'active',
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
          'updated_at': DateTime.utc(2026, 7, 2).toIso8601String(),
          'deleted_at': deletedAt,
          'revision': revision,
          'last_op_id': lastOp,
        };

    Future<void> pendingGoal({String op = 'op-1', String operation = 'update'}) async {
      await DriftGoalRepository(db).save(_goal('g1'));
      await db.customStatement(
          "UPDATE goals SET sync_status = 'pending', server_id = 'server-g1', "
          "server_revision = 1 WHERE id = 'g1';");
      await db.customStatement('''
        INSERT INTO planning_sync_outbox(id, entity_type, entity_id, operation,
          payload_json, attempt_count, status, created_at, updated_at, op_seq,
          in_flight_seq, operation_id)
        VALUES ('o-$op', 'goal', 'g1', '$operation', '{}', 0, 'pending',
          '2026-07-01', '2026-07-01', 1, 1, '$op');
      ''');
    }

    Future<LedgerLikeResult> pullWith(Map<String, dynamic> row) async {
      final remote = _FakePlanningRemote();
      if (row['deleted_at'] != null) {
        remote.tombstones['user_goals'] = [row];
      } else {
        remote.rows['user_goals'] = {'g1': row};
      }
      final pull = PlanningPullService(
        db: db,
        isEnabled: (_) => true,
        getAuthUserId: () async => 'user-1',
        remoteSource: remote,
        mayEgress: () async => true,
      );
      final r = await pull.pull();
      return LedgerLikeResult(r.conflicts);
    }

    Future<int> openConflicts() async => (await db
            .customSelect('SELECT COUNT(*) n FROM sync_conflicts WHERE resolved_at IS NULL;')
            .getSingle())
        .read<int>('n');

    test('own queued op is the cloud last write: settled, no conflict', () async {
      await pendingGoal();
      final r = await pullWith(remoteGoal(lastOp: 'op-1'));
      expect(r.conflicts, 0);
      final row = await db
          .customSelect("SELECT sync_status, server_revision, name FROM goals WHERE id='g1';")
          .getSingle();
      expect(row.read<String>('sync_status'), 'synced');
      expect(row.read<int>('server_revision'), 2);
      expect(row.read<String>('name'), 'Travel', reason: 'our edit stays');
      expect(await _outboxCount(db), 0);
      expect(await openConflicts(), 0);
    });

    test('foreign op: conflict stored durably with both versions', () async {
      await pendingGoal();
      final r = await pullWith(remoteGoal(lastOp: 'someone-else'));
      expect(r.conflicts, 1);
      final rec = await db.customSelect('SELECT * FROM sync_conflicts').getSingle();
      expect(rec.read<String>('entity_type'), 'goal');
      expect(rec.read<String>('kind'), 'update');
      expect(rec.read<String>('mine_json'), contains('Travel'));
      expect(rec.read<String>('theirs_json'), contains('Remote'));
      expect(await _outboxCount(db), 1);
    });

    test('own tombstone (our delete landed): settled, no conflict', () async {
      await pendingGoal(op: 'op-del', operation: 'delete');
      final r = await pullWith(
          remoteGoal(lastOp: 'op-del', deletedAt: '2026-07-03T00:00:00Z'));
      expect(r.conflicts, 0);
      expect(await _outboxCount(db), 0);
      expect(await openConflicts(), 0);
    });

    test('foreign tombstone vs pending edit: durable conflict kind tombstone',
        () async {
      await pendingGoal(op: 'op-edit');
      await pullWith(
          remoteGoal(lastOp: 'foreign', deletedAt: '2026-07-03T00:00:00Z'));
      expect(await openConflicts(), 1);
      expect((await db.customSelect('SELECT kind FROM sync_conflicts').getSingle())
          .read<String>('kind'), 'tombstone');
      expect(await _outboxCount(db), 1);
    });
  });
}

class LedgerLikeResult {
  const LedgerLikeResult(this.conflicts);
  final int conflicts;
}
