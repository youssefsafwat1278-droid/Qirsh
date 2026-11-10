import 'package:drift/drift.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/app_session.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/finance/money_transport.dart';

class PlanningBackfillReport {
  const PlanningBackfillReport({
    required this.created,
    required this.matched,
    required this.failures,
    this.mismatched = const [],
  });

  final Map<String, int> created;
  final Map<String, int> matched;
  final List<String> failures;

  /// Rows whose pre-existing remote copy disagreed with local money. They are
  /// left in `sync_status='conflict'` — NOT synced — so the local value
  /// survives and stays visible to the pre-sign-out inventory (audit H-2).
  final List<String> mismatched;

  /// Clean means "every row is now positively proven persisted". A mismatch is
  /// NOT clean: it is unresolved, and treating it as success is exactly the
  /// false-success that authorised destroying the only local copy (audit H-1).
  bool get isClean => failures.isEmpty && mismatched.isEmpty;
}

/// Deterministic, insert-only planning backfill. Existing server rows always
/// win and are reported as matches; this service never overwrites remote edits.
class PlanningPrimaryBackfillService {
  PlanningPrimaryBackfillService({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
    Future<String?> Function()? getLocalDataOwnerUid,
    // MALI-026 (B8-3 §12/§13): canonical mode reads the exact `_minor` (never the
    // REAL shadow as authority) and serializes money as the exact decimal STRING
    // — the backfill is a canonical sync path and must not emit a JSON-number for
    // a canonical Money, matching the ledger/transactions backfill.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _client = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultUserId,
        _getLocalDataOwnerUid =
            getLocalDataOwnerUid ?? AppSession.instance.readLocalDataOwnerUid,
        _coordinator = coordinator;

  final AppDatabase _db;
  final SupabaseClient Function() _client;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getLocalDataOwnerUid;
  final PlanningCutoverCoordinator _coordinator;

  bool get _canonical => _coordinator.state() == PlanningCutoverState.canonical;

  /// §12: read a money column as EXACT Money (from `_minor`, currency-scoped),
  /// then serialize canonical → decimal STRING / legacy → JSON number. Never the
  /// REAL shadow as authority, never a JSON number for a canonical Money.
  Object _money(QueryRow row, String col, String currency) {
    final m = kMoneyCodec.readColumn(row, col, currency);
    return _canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
  }

  Object? _moneyOrNull(QueryRow row, String col, String currency) {
    final m = kMoneyCodec.readColumnNullable(row, col, currency);
    return _canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);
  }

  static Future<String?> _defaultUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    return Supabase.instance.client.auth.currentUser?.id;
  }

  /// دفاع في العمق: يرفض ترحيل بيانات التخطيط إن كانت البيانات المحلية مسجَّلة
  /// كملك لهوية Supabase مختلفة عن الهوية الحالية — يمنع رفع بيانات مستخدم سابق
  /// تحت هوية المستخدم الحالي. مطابق لعقد AccountsBackfillService/
  /// TransactionsBackfillService؛ `null` (بيانات قديمة قبل تسجيل الملكية) مسموح
  /// به عمداً حسب سياسة الترحيل المقبولة. يجب أن يسبق أي نداء شبكي.
  Future<void> _assertLocalDataOwnership(String uid) async {
    final ownerUid = await _getLocalDataOwnerUid();
    if (ownerUid != null && ownerUid != uid) {
      throw const ValidationRepoException(
        'Local planning data is recorded as owned by a different signed-in '
        'identity than the one currently authenticated — refusing to upload '
        'it to avoid cross-account data leakage.',
      );
    }
  }

  Future<PlanningBackfillReport> run({Set<String>? onlyEntities}) async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    await _assertLocalDataOwnership(uid);
    final created = <String, int>{};
    final matched = <String, int>{};
    final failures = <String>[];
    final mismatched = <String>[];

    Future<void> phase(
      String name,
      Future<void> Function(String, Map<String, int>, Map<String, int>,
              List<String>, List<String>)
          work,
    ) async {
      try {
        await work(uid, created, matched, failures, mismatched);
      } catch (error) {
        // Deliberately non-fatal per phase so one broken entity cannot abort the
        // others — but the failure is RECORDED and makes the report unclean, and
        // the caller must treat an unclean report as "not proven" (audit H-1).
        failures.add('$name: ${error.runtimeType}');
      }
    }

    bool enabled(String entity) =>
        onlyEntities == null || onlyEntities.contains(entity);

    if (enabled('budgets')) await phase('budgets', _backfillBudgets);
    if (enabled('goals')) {
      await phase('goals', _backfillGoals);
      await phase('goal_contributions', _backfillGoalContributions);
    }
    if (enabled('subscriptions')) {
      await phase('subscriptions', _backfillSubscriptions);
      await phase('bill_payments', _backfillBillPayments);
    }
    if (enabled('plans')) {
      await phase('plans', _backfillPlans);
      await phase('plan_transaction_links', _backfillPlanLinks);
    }

    return PlanningBackfillReport(
      created: created,
      matched: matched,
      failures: failures,
      mismatched: mismatched,
    );
  }

  Future<void> _backfillBudgets(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows = await _db.customSelect('SELECT * FROM budgets;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      // Planning money has base/external currency authority: budgets carry a
      // per-row currency only AFTER the planning-currency repair (P3), which
      // sets currency + `_minor` atomically. An un-repaired (P1) row has
      // currency = NULL / `_minor` = NULL — defer it rather than push
      // unknown-currency money to the cloud (or fail-close on the NULL minor).
      final currency = row.readNullable<String>('currency');
      if (currency == null) {
        failures.add('budgets:$localId:planning_currency_unrepaired');
        continue;
      }
      final account = await _optionalParent(
        table: 'accounts',
        localParentId: row.readNullable<String>('account_id'),
        entity: 'budgets',
        localId: localId,
        failures: failures,
      );
      if (!account.$2) continue;
      await _insertParent(
        uid: uid,
        entity: 'budgets',
        table: 'user_budgets',
        localTable: 'budgets',
        localId: localId,
        payload: {
          'category_id': await _categoryKey(row.read<String>('category_id')),
          'amount': _money(row, 'amount', currency),
          // MALI-026 (Phase-9F / WS-5): a canonical (P3) budget remote write MUST
          // persist the row's own supported currency. `currency` is the non-null,
          // repair-set value (the NULL case is deferred above); NEVER a base/
          // account/settings fallback. Omitting it made the server store NULL.
          'currency': currency,
          'alert_threshold_percent': row.read<int>('alert_threshold_percent'),
          'period': row.read<String>('period'),
          'start_date': row.read<String>('start_date'),
          'is_active': row.read<int>('is_active') == 1,
          'last_notified_spent_amount':
              _money(row, 'last_notified_spent_amount', currency),
          'last_notified_period_start':
              row.read<String>('last_notified_period_start'),
          'show_on_header': row.read<int>('show_on_header') == 1,
          'server_account_id': account.$1,
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {'amount', 'last_notified_spent_amount'},
        moneyCurrency: currency,
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillGoals(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows = await _db.customSelect('SELECT * FROM goals;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      // See _backfillBudgets: defer un-repaired (P1) planning rows whose
      // currency / `_minor` are still NULL until the P3 currency repair.
      final currency = row.readNullable<String>('currency');
      if (currency == null) {
        failures.add('goals:$localId:planning_currency_unrepaired');
        continue;
      }
      final account = await _optionalParent(
        table: 'accounts',
        localParentId: row.readNullable<String>('account_id'),
        entity: 'goals',
        localId: localId,
        failures: failures,
      );
      if (!account.$2) continue;
      await _insertParent(
        uid: uid,
        entity: 'goals',
        table: 'user_goals',
        localTable: 'goals',
        localId: localId,
        payload: {
          'name': row.read<String>('name'),
          'server_account_id': account.$1,
          'target_amount': _money(row, 'target_amount', currency),
          'saved_amount': _money(row, 'saved_amount', currency),
          // MALI-026 (Phase-9F / WS-5): a canonical (P3) goal remote write MUST
          // persist the row's own supported currency (never a base/account/
          // settings fallback). The NULL case is deferred above.
          'currency': currency,
          'deadline': row.readNullable<String>('deadline'),
          'vault_skin': row.read<String>('vault_skin'),
          'status': row.read<String>('status'),
          'created_at': row.read<String>('created_at'),
          'auto_save_amount': _moneyOrNull(row, 'auto_save_amount', currency),
          'auto_save_period': row.readNullable<String>('auto_save_period'),
          'auto_save_last_run': row.readNullable<String>('auto_save_last_run'),
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {'target_amount', 'saved_amount', 'auto_save_amount'},
        moneyCurrency: currency,
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillGoalContributions(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows =
        await _db.customSelect('SELECT * FROM goal_contributions;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      final localGoalId = row.read<String>('goal_id');
      final goalId = await _serverId('goals', localGoalId);
      if (goalId == null) {
        failures.add('goal_contributions:$localId:missing_parent');
        continue;
      }
      // §10 — a contribution has no currency of its own; its parent goal is the
      // currency authority. Money is read exactly with that currency.
      final goalCurrency = (await _db.customSelect(
              'SELECT currency FROM goals WHERE id = ? LIMIT 1;',
              variables: [Variable.withString(localGoalId)]).getSingleOrNull())
          ?.readNullable<String>('currency');
      if (goalCurrency == null) {
        failures.add('goal_contributions:$localId:parent_currency_missing');
        continue;
      }
      await _insertChild(
        uid: uid,
        entity: 'goal_contributions',
        table: 'user_goal_contributions',
        localTable: 'goal_contributions',
        localId: localId,
        payload: {
          'goal_id': goalId,
          'client_request_id': 'backfill_goal_contribution_$localId',
          'amount': _money(row, 'amount', goalCurrency),
          'note': row.readNullable<String>('note'),
          'created_at': row.read<String>('created_at'),
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {'amount'},
        moneyCurrency: goalCurrency,
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillSubscriptions(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows = await _db.customSelect('SELECT * FROM subscriptions;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      final account = await _optionalParent(
        table: 'accounts',
        localParentId: row.readNullable<String>('account_id'),
        entity: 'subscriptions',
        localId: localId,
        failures: failures,
      );
      if (!account.$2) continue;
      await _insertParent(
        uid: uid,
        entity: 'subscriptions',
        table: 'user_subscriptions',
        localTable: 'subscriptions',
        localId: localId,
        payload: {
          'merchant_id': row.readNullable<String>('merchant_id'),
          'name': row.read<String>('name'),
          'amount': _money(row, 'amount', row.read<String>('currency')),
          'currency': row.read<String>('currency').toUpperCase(),
          'type': row.read<String>('type'),
          'frequency': row.read<String>('frequency'),
          'next_due_date': row.readNullable<String>('next_due_date') ??
              row.read<String>('created_at'),
          'reminder_on': row.read<int>('reminder_on') == 1,
          'is_confirmed': row.read<int>('is_confirmed') == 1,
          'custom_interval_days': row.readNullable<int>('custom_interval_days'),
          'note': row.readNullable<String>('note'),
          'status': row.read<String>('status'),
          'server_account_id': account.$1,
          'total_installments': row.readNullable<int>('total_installments'),
          'paid_count': row.readNullable<int>('paid_count'),
          'manual_paid_amount': _moneyOrNull(
              row, 'manual_paid_amount', row.read<String>('currency')),
          'total_purchase_amount': _moneyOrNull(
              row, 'total_purchase_amount', row.read<String>('currency')),
          'lender_name': row.readNullable<String>('lender_name'),
          'interest_rate': row.readNullable<double>('interest_rate'),
          'created_at': row.read<String>('created_at'),
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {
          'amount',
          'manual_paid_amount',
          'total_purchase_amount'
        },
        moneyCurrency: row.read<String>('currency'),
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillBillPayments(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows = await _db.customSelect('SELECT * FROM bill_payments;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      final subscriptionId =
          await _serverId('subscriptions', row.read<String>('bill_id'));
      final localTransactionId = row.readNullable<String>('transaction_id');
      final transactionId = await _serverId('transactions', localTransactionId);
      if (subscriptionId == null ||
          (localTransactionId != null && transactionId == null)) {
        failures.add('bill_payments:$localId:missing_parent');
        continue;
      }
      await _insertChild(
        uid: uid,
        entity: 'bill_payments',
        table: 'user_bill_payments',
        localTable: 'bill_payments',
        localId: localId,
        payload: {
          'subscription_id': subscriptionId,
          'transaction_id': transactionId,
          'client_request_id': 'backfill_bill_payment_$localId',
          'amount': _money(row, 'amount', row.read<String>('currency')),
          'currency': row.read<String>('currency').toUpperCase(),
          'period_start': row.read<String>('period_start'),
          'period_end': row.read<String>('period_end'),
          'paid_at': row.read<String>('paid_at'),
          'installment_index': row.readNullable<int>('installment_index'),
          'note': row.readNullable<String>('note'),
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {'amount'},
        moneyCurrency: row.read<String>('currency'),
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillPlans(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows = await _db.customSelect('SELECT * FROM plans;').get();
    for (final row in rows) {
      final localId = row.read<String>('id');
      final accountIds = row
          .read<String>('account_ids')
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty);
      final serverAccounts = <String>[];
      var missingAccount = false;
      for (final accountId in accountIds) {
        final serverId = await _serverId('accounts', accountId);
        if (serverId == null) {
          missingAccount = true;
          failures.add('plans:$localId:missing_parent');
          break;
        }
        serverAccounts.add(serverId);
      }
      if (missingAccount) continue;
      await _insertParent(
        uid: uid,
        entity: 'plans',
        table: 'user_plans',
        localTable: 'plans',
        localId: localId,
        payload: {
          'name': row.read<String>('name'),
          'budget_amount':
              _money(row, 'budget_amount', row.read<String>('currency')),
          'currency': row.read<String>('currency').toUpperCase(),
          'start_date': row.read<String>('start_date'),
          'end_date': row.read<String>('end_date'),
          'server_account_ids': serverAccounts,
          'card_last4s': row
              .read<String>('card_last4s')
              .split(',')
              .map((value) => value.trim())
              .where((value) => value.isNotEmpty)
              .toList(),
          'status': row.read<String>('status'),
          'icon': row.readNullable<String>('icon'),
          'created_at': row.read<String>('created_at'),
          'deleted_at': row.readNullable<String>('deleted_at'),
        },
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: const {'budget_amount'},
        moneyCurrency: row.read<String>('currency'),
        moneyRow: row,
      );
    }
  }

  Future<void> _backfillPlanLinks(
      String uid,
      Map<String, int> created,
      Map<String, int> matched,
      List<String> failures,
      List<String> mismatched) async {
    final rows =
        await _db.customSelect('SELECT * FROM plan_transaction_links;').get();
    for (final row in rows) {
      final planLocal = row.read<String>('plan_id');
      final txLocal = row.read<String>('transaction_id');
      final planId = await _serverId('plans', planLocal);
      final transactionId = await _serverId('transactions', txLocal);
      final key = '$planLocal:$txLocal';
      if (planId == null || transactionId == null) {
        failures.add('plan_transaction_links:$key:missing_parent');
        continue;
      }
      try {
        final requestId = 'backfill_plan_link_$key';
        final existing = await _client()
            .from('user_plan_transaction_links')
            .select('id')
            .eq('user_id', uid)
            .eq('client_request_id', requestId)
            .maybeSingle();
        final serverRow = existing ??
            await _client()
                .from('user_plan_transaction_links')
                .insert({
                  'user_id': uid,
                  'plan_id': planId,
                  'transaction_id': transactionId,
                  'client_request_id': requestId,
                  'created_at': row.read<String>('created_at'),
                  'deleted_at': row.readNullable<String>('deleted_at'),
                })
                .select()
                .single();
        _bump(existing == null ? created : matched, 'plan_transaction_links');
        await _db.customStatement(
          "UPDATE plan_transaction_links SET server_id = ?, synced_at = ?, sync_status = 'synced' "
          'WHERE plan_id = ? AND transaction_id = ?;',
          [
            serverRow['id'] as String,
            dateTimeToSql(DateTime.now().toUtc()),
            planLocal,
            txLocal,
          ],
        );
      } catch (error) {
        failures.add('plan_transaction_links:$key:${error.runtimeType}');
      }
    }
  }

  /// Exact money comparison between the payload we would have written and the
  /// remote row that already exists. Audit H-2: an existing remote row was
  /// previously accepted as a "match" with NO comparison at all, and the local
  /// row was stamped `synced` — so a remote copy holding different money made
  /// the local (still-authoritative) value invisible to the sign-out inventory
  /// and eligible to be overwritten by the next pull.
  ///
  /// Parsing failure counts as a mismatch: uncertainty must never resolve to
  /// "proven persisted".
  bool _moneyDiffers({
    required Map<String, dynamic> payload,
    required Map<String, dynamic> serverRow,
    required Set<String> moneyKeys,
    required String? currency,
    required QueryRow localRow,
  }) {
    if (moneyKeys.isEmpty) return false; // link tables carry no money
    if (currency == null) return true; // cannot verify ⇒ not proven
    if (payload.containsKey('currency')) {
      final localCurrency = payload['currency'];
      final remoteCurrency = serverRow['currency'];
      if (localCurrency is! String ||
          remoteCurrency is! String ||
          remoteCurrency.toUpperCase() != localCurrency.toUpperCase()) {
        return true;
      }
    }
    for (final key in moneyKeys) {
      try {
        final local = kMoneyCodec.readColumnNullable(localRow, key, currency);
        final remote = moneyFromPulledValue(
          serverRow['${key}_text'],
          currency,
        );
        if (local != remote) {
          return true;
        }
      } catch (_) {
        return true;
      }
    }
    return false;
  }

  String _moneySelect(Set<String> moneyKeys) => [
        '*',
        for (final key in moneyKeys) '${key}_text:$key::text',
      ].join(', ');

  Future<void> _insertParent({
    required String uid,
    required String entity,
    required String table,
    required String localTable,
    required String localId,
    required Map<String, dynamic> payload,
    required Map<String, int> created,
    required Map<String, int> matched,
    required List<String> failures,
    required List<String> mismatched,
    required Set<String> moneyKeys,
    required String? moneyCurrency,
    required QueryRow moneyRow,
  }) =>
      _insertChild(
        uid: uid,
        entity: entity,
        table: table,
        localTable: localTable,
        localId: localId,
        payload: payload,
        created: created,
        matched: matched,
        failures: failures,
        mismatched: mismatched,
        moneyKeys: moneyKeys,
        moneyCurrency: moneyCurrency,
        moneyRow: moneyRow,
      );

  Future<void> _insertChild({
    required String uid,
    required String entity,
    required String table,
    required String localTable,
    required String localId,
    required Map<String, dynamic> payload,
    required Map<String, int> created,
    required Map<String, int> matched,
    required List<String> failures,
    required List<String> mismatched,
    required Set<String> moneyKeys,
    required String? moneyCurrency,
    required QueryRow moneyRow,
  }) async {
    try {
      final select = _moneySelect(moneyKeys);
      final existing = await _client()
          .from(table)
          .select(select)
          .eq('user_id', uid)
          .eq('local_id', localId)
          .maybeSingle();
      final serverRow = existing ??
          await _client()
              .from(table)
              .insert({
                'user_id': uid,
                'local_id': localId,
                ...payload,
              })
              .select(select)
              .single();
      _bump(existing == null ? created : matched, entity);
      // The returned row (whether matched or newly inserted) is proof only when
      // its exact money and currency authority agree with the canonical local row.
      final conflicted = _moneyDiffers(
        payload: payload,
        serverRow: serverRow,
        moneyKeys: moneyKeys,
        currency: moneyCurrency,
        localRow: moneyRow,
      );
      if (conflicted) {
        mismatched.add('$entity:$localId');
        // Preserve the local copy and surface it: these tables have interactive
        // conflict policies, so this lands in the keep-mine/keep-theirs picker
        // instead of being silently overwritten by the next pull.
        await _db.customStatement(
          "UPDATE $localTable SET server_id = ?, sync_status = 'conflict' WHERE id = ?;",
          [serverRow['id'] as String, localId],
        );
      } else {
        await _db.customStatement(
          "UPDATE $localTable SET server_id = ?, synced_at = ?, sync_status = 'synced' WHERE id = ?;",
          [
            serverRow['id'] as String,
            dateTimeToSql(DateTime.now().toUtc()),
            localId,
          ],
        );
      }
    } catch (error) {
      failures.add('$entity:$localId:${error.runtimeType}');
    }
  }

  Future<String?> _serverId(String table, String? localId) async {
    if (localId == null) return null;
    final row = await _db.customSelect(
      'SELECT server_id FROM $table WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(localId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('server_id');
  }

  Future<(String?, bool)> _optionalParent({
    required String table,
    required String? localParentId,
    required String entity,
    required String localId,
    required List<String> failures,
  }) async {
    if (localParentId == null) return (null, true);
    final serverId = await _serverId(table, localParentId);
    if (serverId != null) return (serverId, true);
    failures.add('$entity:$localId:missing_parent');
    return (null, false);
  }

  Future<String> _categoryKey(String localId) async {
    if (localId == BudgetEntity.allExpensesCategoryId) {
      return BudgetEntity.allExpensesCategoryKey;
    }
    final row = await _db.customSelect(
      'SELECT key FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(localId)],
    ).getSingleOrNull();
    if (row == null) throw const ValidationRepoException('Missing category.');
    return row.read<String>('key');
  }

  void _bump(Map<String, int> values, String key) {
    values[key] = (values[key] ?? 0) + 1;
  }
}
