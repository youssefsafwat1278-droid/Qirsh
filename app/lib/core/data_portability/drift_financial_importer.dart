import '../../domain/entities/budget_entity.dart';
import 'dart:convert';

import 'package:drift/drift.dart';

import '../../data/db/app_database.dart';
import '../../data/db/merchant_identity.dart';
import '../../data/db/money_codec.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/repositories/drift_repository_support.dart'
    show goalContributionFromRow, transactionFromRow;
import '../../data/repositories/drift_bill_repository.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../../domain/finance/money.dart';
import '../../engine/parser/capture_money.dart';
import '../../core/utils/id_generator.dart';
import 'data_portability_models.dart';
import 'qirsh_package_codec.dart';

/// Imports a trusted Qirsh package into Drift in one database transaction.
///
/// Package record IDs are deliberately preserved: rerunning the same package
/// is idempotent and relationships never depend on Supabase UUIDs.
class DriftFinancialImporter {
  const DriftFinancialImporter(this._db,
      {LedgerOutboxQueue? ledgerOutbox, PlanningOutboxQueue? planningOutbox})
      : _ledgerOutbox = ledgerOutbox,
        _planningOutbox = planningOutbox;

  final AppDatabase _db;

  /// G6: when set, every transaction the import hides or writes records sync
  /// intent in the SAME database transaction (hidden rows → delete; written
  /// rows → create/update). Null keeps the importer purely local (tests).
  final LedgerOutboxQueue? _ledgerOutbox;
  final PlanningOutboxQueue? _planningOutbox;

  Future<ImportResult> importPackage(
    QirshPackageData package,
    ImportMode mode,
  ) async {
    final previous = await _db.customSelect(
      'SELECT mode, result_json FROM financial_import_runs WHERE package_id = ?;',
      variables: [Variable.withString(package.packageId)],
    ).getSingleOrNull();
    if (previous != null) {
      if (previous.read<String>('mode') != mode.name) {
        throw const DataPortabilityException(
          'تم استيراد هذه الحزمة سابقًا بوضع مختلف.', code: DataPortabilityError.packageAlreadyImported,
        );
      }
      return _resultFromJson(previous.read<String>('result_json'));
    }

    var imported = 0;
    var duplicates = 0;
    var quarantined = 0;
    await _db.transaction(() async {
      if (mode == ImportMode.replace) {
        final hiddenIds = _ledgerOutbox == null
            ? const <String>[]
            : (await _db.customSelect(
                "SELECT id FROM transactions WHERE status != 'ignored';",
              ).get())
                .map((r) => r.read<String>('id'))
                .toList();
        await _softHideFinancialData();
        for (final id in hiddenIds) {
          await _enqueueTransaction(id, OutboxOperation.delete);
        }
      }

      // Resolved once: the base-currency planning tables need an authority, and
      // re-reading it per row would be a query per imported record.
      final baseCurrency = await _resolveBaseCurrency();

      for (final table in qirshPackageTables) {
        for (final row in package.tables[table]!.rows) {
          if (table == 'goal_contributions' &&
              await _contributionCurrencyMismatchesGoal(row)) {
            // A contribution has no currency column locally. Writing its minor
            // integer beneath a goal with another scale would silently change
            // its amount, so quarantine the entire row before any upsert.
            quarantined += 1;
            continue;
          }
          final existed = await _exists(table, row);
          if (existed && mode == ImportMode.merge) {
            duplicates += 1;
            continue;
          }
          await _upsert(table, row, baseCurrency);
          if (table == 'transactions') {
            await _enqueueTransaction(
              _required(row, 'record_id'),
              existed ? OutboxOperation.update : OutboxOperation.create,
            );
          }
          if (!existed) await _enqueueNewChild(table, row);
          imported += 1;
        }
      }

      // A file says nothing trustworthy about who chose a category (rows above
      // are 'unknown'), but its merchant names are real: link every imported
      // row to its stable merchant identity, by the exact normalised name.
      await repairMissingMerchantLinks(_db);

      final result = ImportResult(
        imported: imported,
        duplicates: duplicates,
        skipped: quarantined,
        failed: 0,
      );
      await _db.customInsert(
        '''
          INSERT INTO financial_import_runs(
            package_id, format, mode, result_json, completed_at
          ) VALUES (?, 'qirsh_package', ?, ?, ?);
        ''',
        variables: [
          Variable.withString(package.packageId),
          Variable.withString(mode.name),
          Variable.withString(jsonEncode(_resultToJson(result))),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        ],
      );
    });
    return ImportResult(
      imported: imported,
      duplicates: duplicates,
      skipped: quarantined,
      failed: 0,
    );
  }

  Future<void> _enqueueTransaction(String id, OutboxOperation op) async {
    final queue = _ledgerOutbox;
    if (queue == null) return;
    final row = await _db.customSelect(
      'SELECT * FROM transactions WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    if (row != null) await queue.enqueue(op, transactionFromRow(row));
  }

  /// A child row inserted by the import (MERGE, or REPLACE of an absent id) must
  /// record sync intent in the same transaction: the startup backfill only
  /// triggers on unsynced PARENTS, so a new child under an already-synced
  /// parent would otherwise never reach the server.
  Future<void> _enqueueNewChild(String table, Map<String, String> row) async {
    final queue = _planningOutbox;
    if (queue == null) return;
    switch (table) {
      case 'bill_payments':
        final id = _required(row, 'record_id');
        final billId = _required(row, 'subscription_record_id');
        final payment = (await DriftBillRepository(_db).getPayments(billId))
            .where((p) => p.id == id)
            .firstOrNull;
        if (payment != null) {
          await queue.enqueueBillPayment(PlanningSyncOperation.create, payment);
        }
      case 'goal_contributions':
        final contribution = await _db.customSelect(
          'SELECT * FROM goal_contributions WHERE id = ? LIMIT 1;',
          variables: [Variable.withString(_required(row, 'record_id'))],
        ).getSingleOrNull();
        final currency = contribution == null
            ? null
            : await _goalCurrency(contribution.read<String>('goal_id'));
        if (contribution != null && currency != null) {
          await queue.enqueueGoalContribution(PlanningSyncOperation.create,
              goalContributionFromRow(contribution, currency));
        }
      case 'plan_transaction_links':
        final link = await _db.customSelect(
          'SELECT created_at FROM plan_transaction_links '
          'WHERE plan_id = ? AND transaction_id = ? LIMIT 1;',
          variables: [
            Variable.withString(_required(row, 'plan_record_id')),
            Variable.withString(_required(row, 'transaction_record_id')),
          ],
        ).getSingleOrNull();
        if (link != null) {
          await queue.enqueuePlanLink(
            PlanningSyncOperation.create,
            planId: _required(row, 'plan_record_id'),
            transactionId: _required(row, 'transaction_record_id'),
            createdAt: DateTime.parse(link.read<String>('created_at')).toUtc(),
          );
        }
    }
  }

  Future<void> _softHideFinancialData() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement(
      "UPDATE transactions SET status = 'ignored', updated_at = ?, "
      "$kMarkPendingIfServerBacked WHERE status != 'ignored';",
      [now],
    );
    // Only LIVE rows are hidden: re-stamping an already-deleted row would
    // rewrite its tombstone time and (for server-backed rows) re-mark it pending.
    for (final table in const [
      'budgets',
      'subscriptions',
      'goals',
      'plans',
      'accounts',
    ]) {
      await _db.customStatement(
          'UPDATE $table SET deleted_at = ?, $kMarkPendingIfServerBacked '
          'WHERE deleted_at IS NULL;',
          [now]);
    }
    // Children are immutable and have no server-delete path, so hiding them
    // must not flip their sync_status: a same-id child restored by the import
    // (deleted_at = NULL) then keeps exactly the status it had before.
    for (final table in const [
      'bill_payments',
      'goal_contributions',
      'plan_transaction_links',
    ]) {
      await _db.customStatement(
          'UPDATE $table SET deleted_at = ? WHERE deleted_at IS NULL;', [now]);
    }
    await _db.customStatement(
      'UPDATE categories SET deleted_at = ?, $kMarkPendingIfServerBacked '
      "WHERE key GLOB 'custom_*' AND deleted_at IS NULL;",
      [now],
    );
  }

  Future<bool> _exists(String table, Map<String, String> row) async {
    final (localTable, where, args) = switch (table) {
      'custom_categories' => (
          'categories',
          'id = ? OR key = ?',
          <Object?>[_required(row, 'record_id'), _required(row, 'key')]
        ),
      'plan_transaction_links' => (
          'plan_transaction_links',
          'plan_id = ? AND transaction_id = ?',
          <Object?>[
            _required(row, 'plan_record_id'),
            _required(row, 'transaction_record_id'),
          ],
        ),
      _ => (table, 'id = ?', <Object?>[_required(row, 'record_id')]),
    };
    final found = await _db.customSelect(
      'SELECT 1 FROM $localTable WHERE $where LIMIT 1;',
      variables: [for (final arg in args) Variable<String>(arg as String)],
    ).getSingleOrNull();
    return found != null;
  }

  /// The importing device's base currency (`user_settings.currency`), which is
  /// the domain authority for budgets/goals/goal_contributions.
  Future<String> _resolveBaseCurrency() async {
    final row = await _db
        .customSelect('SELECT currency FROM user_settings LIMIT 1;')
        .getSingleOrNull();
    final stored = row?.read<String?>('currency');
    return _currencyOr(stored, 'SAR');
  }

  /// The parent goal's currency, for contributions (which carry none of their
  /// own). Goals precede contributions in `qirshPackageTables`, so within this
  /// transaction the parent is already present.
  Future<String?> _goalCurrency(String goalId) async {
    final row = await _db.customSelect(
      'SELECT currency FROM goals WHERE id = ?;',
      variables: [Variable.withString(goalId)],
    ).getSingleOrNull();
    final stored = row?.read<String?>('currency');
    return _nullable(stored) == null ? null : _currency(stored);
  }

  /// New packages export the contribution's inherited currency explicitly.
  /// Compare it with the goal that now exists in the target transaction (the
  /// preserved local goal in MERGE, or the imported goal otherwise). Legacy
  /// rows without `currency` retain their existing parent/base fallback.
  Future<bool> _contributionCurrencyMismatchesGoal(
    Map<String, String> row,
  ) async {
    final exported = _nullable(row['currency']);
    if (exported == null) return false;
    final effectiveGoalCurrency =
        await _goalCurrency(_required(row, 'goal_record_id'));
    return effectiveGoalCurrency != null &&
        _currency(exported) != effectiveGoalCurrency;
  }

  /// [baseCurrency] is the DOMAIN CONTRACT currency for the base-currency
  /// planning tables (budgets / goals / goal_contributions). Packages written
  /// before audit C-2 carry no per-row currency for those tables, so the
  /// importing device's own base currency is the only available authority.
  Future<void> _upsert(
    String table,
    Map<String, String> row,
    String baseCurrency,
  ) async {
    switch (table) {
      case 'accounts':
        final accountCurrency = _currency(row['currency']);
        final initialBalanceMoney = _portableMoneyOrNull(
          row,
          minorKey: 'initial_balance_minor',
          legacyKey: 'initial_balance',
          currency: accountCurrency,
        );
        final currentBalanceMoney = _portableMoneyOrNull(
          row,
          minorKey: 'current_balance_minor',
          legacyKey: 'current_balance',
          currency: accountCurrency,
        );
        final creditLimitMoney = _portableMoneyOrNull(
          row,
          minorKey: 'credit_limit_minor',
          legacyKey: 'credit_limit',
          currency: accountCurrency,
        );
        final availableCreditMoney = _portableMoneyOrNull(
          row,
          minorKey: 'available_credit_minor',
          legacyKey: 'available_credit',
          currency: accountCurrency,
        );
        await _db.customStatement('''
          INSERT INTO accounts(id,name,currency,type,initial_balance,initial_balance_minor,
            current_balance,current_balance_minor,credit_limit,credit_limit_minor,
            available_credit,available_credit_minor,
            is_default,sort_order,created_at,updated_at,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name,currency=excluded.currency,
            type=excluded.type,initial_balance=excluded.initial_balance,
            initial_balance_minor=excluded.initial_balance_minor,
            current_balance=excluded.current_balance,
            current_balance_minor=excluded.current_balance_minor,
            credit_limit=excluded.credit_limit,credit_limit_minor=excluded.credit_limit_minor,
            available_credit=excluded.available_credit,
            available_credit_minor=excluded.available_credit_minor,
            is_default=excluded.is_default,
            sort_order=excluded.sort_order,updated_at=excluded.updated_at,deleted_at=NULL,
            sync_status=CASE WHEN accounts.server_id IS NOT NULL THEN 'pending' ELSE accounts.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _required(row, 'name'),
          accountCurrency,
          _or(row['type'], 'bank'),
          initialBalanceMoney == null
              ? null
              : kMoneyCodec.toReal(initialBalanceMoney),
          initialBalanceMoney == null
              ? null
              : kMoneyCodec.toMinor(initialBalanceMoney),
          currentBalanceMoney == null
              ? null
              : kMoneyCodec.toReal(currentBalanceMoney),
          currentBalanceMoney == null
              ? null
              : kMoneyCodec.toMinor(currentBalanceMoney),
          creditLimitMoney == null
              ? null
              : kMoneyCodec.toReal(creditLimitMoney),
          creditLimitMoney == null
              ? null
              : kMoneyCodec.toMinor(creditLimitMoney),
          availableCreditMoney == null
              ? null
              : kMoneyCodec.toReal(availableCreditMoney),
          availableCreditMoney == null
              ? null
              : kMoneyCodec.toMinor(availableCreditMoney),
          _boolInt(row['is_default']),
          _int(row['sort_order']),
          _date(row['created_at']),
          _date(row['updated_at']),
        ]);
      case 'custom_categories':
        final recordId = _required(row, 'record_id');
        final key = _required(row, 'key');
        final existing = await _db.customSelect(
          'SELECT id FROM categories WHERE id = ? OR key = ? LIMIT 1;',
          variables: [Variable.withString(recordId), Variable.withString(key)],
        ).getSingleOrNull();
        if (existing == null) {
          await _db.customStatement('''
            INSERT INTO categories(id,key,name_ar,icon,color,is_income,sort_order,
              sync_status,deleted_at)
            VALUES(?,?,?,?,?,?,?,'local_only',NULL);
          ''', [
            recordId,
            key,
            _required(row, 'name_ar'),
            _or(row['icon'], 'category'),
            _or(row['color'], '#64748B'),
            _boolInt(row['is_income']),
            _int(row['sort_order']),
          ]);
        } else {
          await _db.customStatement('''
            UPDATE categories SET name_ar=?,icon=?,color=?,is_income=?,
              sort_order=?,deleted_at=NULL,
              sync_status=CASE WHEN server_id IS NOT NULL THEN 'pending' ELSE sync_status END
            WHERE id=?;
          ''', [
            _required(row, 'name_ar'),
            _or(row['icon'], 'category'),
            _or(row['color'], '#64748B'),
            _boolInt(row['is_income']),
            _int(row['sort_order']),
            existing.read<String>('id'),
          ]);
        }
      case 'transactions':
        final categoryId = await _categoryId(row);
        final transactionCurrency = _currency(row['currency']);
        final amountMoney = _portablePositiveMoney(
          row,
          minorKey: 'amount_minor',
          legacyKey: 'amount',
          currency: transactionCurrency,
        );
        final balanceAfterMoney = _portableMoneyOrNull(
          row,
          minorKey: 'balance_after_minor',
          legacyKey: 'balance_after',
          currency: transactionCurrency,
        );
        final foreignCurrency = _nullable(row['foreign_currency']);
        final hasForeignAmount = _nullable(row[
                row.containsKey('foreign_amount_minor')
                    ? 'foreign_amount_minor'
                    : 'foreign_amount']) !=
            null;
        if (hasForeignAmount != (foreignCurrency != null)) {
          throw const DataPortabilityException(
              'المبلغ والعملة الأجنبية يجب أن يوجدا معًا.', code: DataPortabilityError.foreignPairRequired);
        }
        final foreignMoney = foreignCurrency == null
            ? null
            : _portableMoneyOrNull(
                row,
                minorKey: 'foreign_amount_minor',
                legacyKey: 'foreign_amount',
                currency: foreignCurrency,
              );
        await _db.customStatement('''
          INSERT INTO transactions(id,account_id,amount,amount_minor,currency,raw_merchant,
            category_id,type,source,card_last4,balance_after,balance_after_minor,note,occurred_at,
            raw_message,parse_confidence,status,created_at,updated_at,
            foreign_amount,foreign_amount_minor,foreign_currency,direction,transaction_time_from_sms,
            sms_received_at,comparison_timestamp,comparison_timestamp_source,
            duplicate_status,possible_duplicate_of_transaction_id,duplicate_reason,
            category_source,imported_from_file,transfer_group_id)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?, '',1,?,?,?,?,?,?,?,?,?,?,?,?,?,?, 'unknown',1,?)
          ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,
            amount=excluded.amount,amount_minor=excluded.amount_minor,currency=excluded.currency,
            raw_merchant=excluded.raw_merchant,
            category_source=CASE WHEN transactions.category_id IS excluded.category_id
                                 THEN transactions.category_source ELSE 'unknown' END,
            category_id=excluded.category_id,
            -- The row's content now comes from a file. The marker is sticky
            -- and separate: `source` keeps the file's original bank/SMS origin.
            imported_from_file=1,
            type=excluded.type,source=excluded.source,card_last4=excluded.card_last4,
            balance_after=excluded.balance_after,
            balance_after_minor=excluded.balance_after_minor,note=excluded.note,
            occurred_at=excluded.occurred_at,status=excluded.status,
            updated_at=excluded.updated_at,foreign_amount=excluded.foreign_amount,
            foreign_amount_minor=excluded.foreign_amount_minor,
            foreign_currency=excluded.foreign_currency,direction=excluded.direction,
            transaction_time_from_sms=excluded.transaction_time_from_sms,
            sms_received_at=excluded.sms_received_at,
            comparison_timestamp=excluded.comparison_timestamp,
            comparison_timestamp_source=excluded.comparison_timestamp_source,
            duplicate_status=excluded.duplicate_status,
            possible_duplicate_of_transaction_id=excluded.possible_duplicate_of_transaction_id,
            duplicate_reason=excluded.duplicate_reason,
            transfer_group_id=excluded.transfer_group_id,
            sync_status=CASE WHEN transactions.server_id IS NOT NULL THEN 'pending' ELSE transactions.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _nullable(row['account_record_id']),
          kMoneyCodec.toReal(amountMoney),
          kMoneyCodec.toMinor(amountMoney),
          transactionCurrency,
          _nullable(row['merchant']),
          categoryId,
          _or(row['type'], 'unknown'),
          _or(row['source'], 'imported'),
          _nullable(row['card_last4']),
          balanceAfterMoney == null
              ? null
              : kMoneyCodec.toReal(balanceAfterMoney),
          balanceAfterMoney == null
              ? null
              : kMoneyCodec.toMinor(balanceAfterMoney),
          _nullable(row['note']),
          _date(row['occurred_at']),
          _or(row['status'], 'confirmed'),
          _date(row['created_at']),
          _date(row['updated_at']),
          foreignMoney == null ? null : kMoneyCodec.toReal(foreignMoney),
          foreignMoney == null ? null : kMoneyCodec.toMinor(foreignMoney),
          foreignCurrency,
          _nullable(row['direction']),
          _nullableDate(row['transaction_time_from_sms']),
          _nullableDate(row['sms_received_at']),
          _nullableDate(row['comparison_timestamp']),
          _or(row['comparison_timestamp_source'], 'received_at'),
          _or(row['duplicate_status'], 'normal'),
          _nullable(row['possible_duplicate_record_id']),
          _nullable(row['duplicate_reason']),
          _nullable(row['transfer_group_id']),
        ]);
      case 'budgets':
        final categoryId = await _categoryId(row) ?? await _fallbackCategory();
        // Audit C-2: budgets/goals are CANONICAL money (kV30MinorColumns), so
        // the `_minor` columns and the currency MUST be written. Omitting them
        // left canonical rows with NULL minors, which makes every planning read
        // throw (money_codec: "v30 read requires a minor value") and the
        // cutover marker cover non-canonical rows. Mirrors the `plans` case.
        final budgetCurrency = _currencyOr(row['currency'], baseCurrency);
        final budgetAmount = _portablePositiveMoney(
          row,
          minorKey: 'amount_minor',
          legacyKey: 'amount',
          currency: budgetCurrency,
        );
        final budgetNotified = _portableMoneyOrNull(
              row,
              minorKey: 'last_notified_spent_amount_minor',
              legacyKey: 'last_notified_spent_amount',
              currency: budgetCurrency,
            ) ??
            Money.zero(budgetCurrency);
        await _db.customStatement('''
          INSERT INTO budgets(id,account_id,category_id,currency,amount,amount_minor,period,start_date,
            is_active,last_notified_spent_amount,last_notified_spent_amount_minor,
            last_notified_period_start,show_on_header,alert_threshold_percent,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,
            category_id=excluded.category_id,currency=excluded.currency,
            amount=excluded.amount,amount_minor=excluded.amount_minor,
            period=excluded.period,start_date=excluded.start_date,
            is_active=excluded.is_active,last_notified_spent_amount=excluded.last_notified_spent_amount,
            last_notified_spent_amount_minor=excluded.last_notified_spent_amount_minor,
            last_notified_period_start=excluded.last_notified_period_start,
            show_on_header=excluded.show_on_header,
            alert_threshold_percent=excluded.alert_threshold_percent,deleted_at=NULL,
            sync_status=CASE WHEN budgets.server_id IS NOT NULL THEN 'pending' ELSE budgets.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _nullable(row['account_record_id']),
          categoryId,
          budgetCurrency,
          kMoneyCodec.toReal(budgetAmount),
          kMoneyCodec.toMinor(budgetAmount),
          _or(row['period'], 'monthly'),
          _date(row['start_date']),
          _boolInt(row['is_active']),
          kMoneyCodec.toReal(budgetNotified),
          kMoneyCodec.toMinor(budgetNotified),
          _or(row['last_notified_period_start'], '2000-01-01T00:00:00Z'),
          _boolInt(row['show_on_header']),
          // A file written by an older build has no such column; those budgets
          // import at the default, which is what they behaved as.
          BudgetEntity.normalizeAlertThreshold(
            int.tryParse(row['alert_threshold_percent']?.toString() ?? '') ??
                BudgetEntity.defaultAlertThresholdPercent,
          ),
        ]);
      case 'subscriptions':
        final merchantId =
            await _merchantId(_or(row['merchant'], row['name'] ?? 'اشتراك'));
        final subscriptionCurrency = _currency(row['currency']);
        final subscriptionAmountMoney = _portablePositiveMoney(
          row,
          minorKey: 'amount_minor',
          legacyKey: 'amount',
          currency: subscriptionCurrency,
        );
        final manualPaidMoney = _portableMoneyOrNull(
          row,
          minorKey: 'manual_paid_amount_minor',
          legacyKey: 'manual_paid_amount',
          currency: subscriptionCurrency,
        );
        final totalPurchaseMoney = _portableMoneyOrNull(
          row,
          minorKey: 'total_purchase_amount_minor',
          legacyKey: 'total_purchase_amount',
          currency: subscriptionCurrency,
        );
        await _db.customStatement('''
          INSERT INTO subscriptions(id,account_id,merchant_id,name,amount,amount_minor,currency,
            period,frequency,type,next_due_date,is_confirmed,reminder_on,
            custom_interval_days,note,created_at,status,total_installments,paid_count,
            manual_paid_amount,manual_paid_amount_minor,total_purchase_amount,
            total_purchase_amount_minor,lender_name,interest_rate,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,
            merchant_id=excluded.merchant_id,name=excluded.name,amount=excluded.amount,
            amount_minor=excluded.amount_minor,
            currency=excluded.currency,period=excluded.period,frequency=excluded.frequency,
            type=excluded.type,next_due_date=excluded.next_due_date,
            is_confirmed=excluded.is_confirmed,reminder_on=excluded.reminder_on,
            custom_interval_days=excluded.custom_interval_days,note=excluded.note,
            status=excluded.status,total_installments=excluded.total_installments,
            paid_count=excluded.paid_count,manual_paid_amount=excluded.manual_paid_amount,
            manual_paid_amount_minor=excluded.manual_paid_amount_minor,
            total_purchase_amount=excluded.total_purchase_amount,
            total_purchase_amount_minor=excluded.total_purchase_amount_minor,
            lender_name=excluded.lender_name,interest_rate=excluded.interest_rate,
            deleted_at=NULL,
            sync_status=CASE WHEN subscriptions.server_id IS NOT NULL THEN 'pending' ELSE subscriptions.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _nullable(row['account_record_id']),
          merchantId,
          _or(row['name'], 'اشتراك'),
          kMoneyCodec.toReal(subscriptionAmountMoney),
          kMoneyCodec.toMinor(subscriptionAmountMoney),
          subscriptionCurrency,
          _or(row['period'], 'monthly'),
          _or(row['frequency'], 'monthly'),
          _or(row['type'], 'subscription'),
          _nullableDate(row['next_due_date']),
          _boolInt(row['is_confirmed']),
          _boolInt(row['reminder_on']),
          _intOrNull(row['custom_interval_days']),
          _nullable(row['note']),
          _date(row['created_at']),
          _or(row['status'], 'active'),
          _intOrNull(row['total_installments']),
          _intOrNull(row['paid_count']),
          manualPaidMoney == null ? null : kMoneyCodec.toReal(manualPaidMoney),
          manualPaidMoney == null ? null : kMoneyCodec.toMinor(manualPaidMoney),
          totalPurchaseMoney == null
              ? null
              : kMoneyCodec.toReal(totalPurchaseMoney),
          totalPurchaseMoney == null
              ? null
              : kMoneyCodec.toMinor(totalPurchaseMoney),
          _nullable(row['lender_name']),
          _double(row['interest_rate']),
        ]);
      case 'bill_payments':
        final paymentCurrency = _currency(row['currency']);
        final paymentAmountMoney = _portablePositiveMoney(
          row,
          minorKey: 'amount_minor',
          legacyKey: 'amount',
          currency: paymentCurrency,
        );
        await _db.customStatement('''
          INSERT INTO bill_payments(id,bill_id,amount,amount_minor,currency,period_start,
            period_end,paid_at,installment_index,transaction_id,note,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET bill_id=excluded.bill_id,
            amount=excluded.amount,amount_minor=excluded.amount_minor,currency=excluded.currency,
            period_start=excluded.period_start,period_end=excluded.period_end,
            paid_at=excluded.paid_at,installment_index=excluded.installment_index,
            transaction_id=excluded.transaction_id,note=excluded.note,deleted_at=NULL;
        ''', [
          _required(row, 'record_id'),
          _required(row, 'subscription_record_id'),
          kMoneyCodec.toReal(paymentAmountMoney),
          kMoneyCodec.toMinor(paymentAmountMoney),
          paymentCurrency,
          _date(row['period_start']),
          _date(row['period_end']),
          _date(row['paid_at']),
          _intOrNull(row['installment_index']),
          _nullable(row['transaction_record_id']),
          _nullable(row['note']),
        ]);
      case 'goals':
        // Audit C-2 — see the `budgets` case. All four goal money columns are
        // canonical and must carry their `_minor` authority plus a currency.
        final goalCurrency = _currencyOr(row['currency'], baseCurrency);
        final goalTarget = _portablePositiveMoney(
          row,
          minorKey: 'target_amount_minor',
          legacyKey: 'target_amount',
          currency: goalCurrency,
        );
        final goalSaved = _portableMoneyOrNull(
              row,
              minorKey: 'saved_amount_minor',
              legacyKey: 'saved_amount',
              currency: goalCurrency,
            ) ??
            Money.zero(goalCurrency);
        final goalAutoSave = _portableMoneyOrNull(
          row,
          minorKey: 'auto_save_amount_minor',
          legacyKey: 'auto_save_amount',
          currency: goalCurrency,
        );
        final goalNotified = _portableMoneyOrNull(
              row,
              minorKey: 'last_notified_saved_amount_minor',
              legacyKey: 'last_notified_saved_amount',
              currency: goalCurrency,
            ) ??
            Money.zero(goalCurrency);
        await _db.customStatement('''
          INSERT INTO goals(id,account_id,name,currency,target_amount,target_amount_minor,
            saved_amount,saved_amount_minor,deadline,
            vault_skin,status,created_at,auto_save_amount,auto_save_amount_minor,auto_save_period,
            auto_save_last_run,last_notified_saved_amount,last_notified_saved_amount_minor,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET account_id=excluded.account_id,name=excluded.name,
            currency=excluded.currency,
            target_amount=excluded.target_amount,target_amount_minor=excluded.target_amount_minor,
            saved_amount=excluded.saved_amount,saved_amount_minor=excluded.saved_amount_minor,
            deadline=excluded.deadline,vault_skin=excluded.vault_skin,status=excluded.status,
            auto_save_amount=excluded.auto_save_amount,
            auto_save_amount_minor=excluded.auto_save_amount_minor,
            auto_save_period=excluded.auto_save_period,
            auto_save_last_run=excluded.auto_save_last_run,
            last_notified_saved_amount=excluded.last_notified_saved_amount,
            last_notified_saved_amount_minor=excluded.last_notified_saved_amount_minor,
            deleted_at=NULL,
            sync_status=CASE WHEN goals.server_id IS NOT NULL THEN 'pending' ELSE goals.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _nullable(row['account_record_id']),
          _required(row, 'name'),
          goalCurrency,
          kMoneyCodec.toReal(goalTarget),
          kMoneyCodec.toMinor(goalTarget),
          kMoneyCodec.toReal(goalSaved),
          kMoneyCodec.toMinor(goalSaved),
          _nullableDate(row['deadline']),
          _or(row['vault_skin'], 'default'),
          _or(row['status'], 'active'),
          _date(row['created_at']),
          goalAutoSave == null ? null : kMoneyCodec.toReal(goalAutoSave),
          goalAutoSave == null ? null : kMoneyCodec.toMinor(goalAutoSave),
          _nullable(row['auto_save_period']),
          _nullableDate(row['auto_save_last_run']),
          kMoneyCodec.toReal(goalNotified),
          kMoneyCodec.toMinor(goalNotified),
        ]);
      case 'goal_contributions':
        // Audit C-2 — mismatched new-package rows were quarantined before this
        // method. The package currency remains the parsing authority when it
        // matches; genuinely legacy rows without it retain the parent/base
        // fallback used before contribution currency was exported.
        final contributionGoalId = _required(row, 'goal_record_id');
        final exportedContributionCurrency = _nullable(row['currency']);
        final contributionCurrency = exportedContributionCurrency == null
            ? await _goalCurrency(contributionGoalId) ?? baseCurrency
            : _currency(exportedContributionCurrency);
        final contributionAmount = _portablePositiveMoney(
          row,
          minorKey: 'amount_minor',
          legacyKey: 'amount',
          currency: contributionCurrency,
        );
        await _db.customStatement('''
          INSERT INTO goal_contributions(id,goal_id,amount,amount_minor,created_at,note,deleted_at)
          VALUES(?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET goal_id=excluded.goal_id,
            amount=excluded.amount,amount_minor=excluded.amount_minor,
            created_at=excluded.created_at,note=excluded.note,
            deleted_at=NULL;
        ''', [
          _required(row, 'record_id'),
          contributionGoalId,
          kMoneyCodec.toReal(contributionAmount),
          kMoneyCodec.toMinor(contributionAmount),
          _date(row['created_at']),
          _nullable(row['note']),
        ]);
      case 'plans':
        final planCurrency = _currency(row['currency']);
        final budgetAmountMoney = _portablePositiveMoney(
          row,
          minorKey: 'budget_amount_minor',
          legacyKey: 'budget_amount',
          currency: planCurrency,
        );
        await _db.customStatement('''
          INSERT INTO plans(id,name,budget_amount,budget_amount_minor,currency,start_date,end_date,
            account_ids,card_last4s,status,icon,created_at,deleted_at)
          VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)
          ON CONFLICT(id) DO UPDATE SET name=excluded.name,
            budget_amount=excluded.budget_amount,
            budget_amount_minor=excluded.budget_amount_minor,currency=excluded.currency,
            start_date=excluded.start_date,end_date=excluded.end_date,
            account_ids=excluded.account_ids,card_last4s=excluded.card_last4s,
            status=excluded.status,icon=excluded.icon,deleted_at=NULL,
            sync_status=CASE WHEN plans.server_id IS NOT NULL THEN 'pending' ELSE plans.sync_status END;
        ''', [
          _required(row, 'record_id'),
          _required(row, 'name'),
          kMoneyCodec.toReal(budgetAmountMoney),
          kMoneyCodec.toMinor(budgetAmountMoney),
          planCurrency,
          _date(row['start_date']),
          _date(row['end_date']),
          _or(row['account_record_ids'], ''),
          _or(row['card_last4s'], ''),
          _or(row['status'], 'active'),
          _nullable(row['icon']),
          _date(row['created_at']),
        ]);
      case 'plan_transaction_links':
        await _db.customStatement('''
          INSERT INTO plan_transaction_links(plan_id,transaction_id,created_at,deleted_at)
          VALUES(?,?,?,NULL)
          ON CONFLICT(plan_id,transaction_id) DO UPDATE SET
            created_at=excluded.created_at,deleted_at=NULL;
        ''', [
          _required(row, 'plan_record_id'),
          _required(row, 'transaction_record_id'),
          _date(row['created_at']),
        ]);
      default:
        throw DataPortabilityException('جدول غير مدعوم: $table', code: DataPortabilityError.unsupportedTable, args: [table]);
    }
  }

  Future<String?> _categoryId(Map<String, String> row) async {
    final recordId = _nullable(row['category_record_id']);
    if (recordId != null) {
      final found = await _db.customSelect(
        'SELECT id FROM categories WHERE id = ? AND deleted_at IS NULL;',
        variables: [Variable.withString(recordId)],
      ).getSingleOrNull();
      if (found != null) return recordId;
    }
    final key = _nullable(row['category_key']);
    if (key == null) return null;
    final found = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? AND deleted_at IS NULL;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return found?.read<String>('id');
  }

  Future<String> _fallbackCategory() async {
    final row = await _db
        .customSelect(
          "SELECT id FROM categories WHERE key = 'other' LIMIT 1;",
        )
        .getSingleOrNull();
    if (row == null) {
      throw const DataPortabilityException('تصنيف «أخرى» غير موجود.', code: DataPortabilityError.otherCategoryMissing);
    }
    return row.read<String>('id');
  }

  Future<String> _merchantId(String name) async {
    final normalized = name.trim().toLowerCase();
    final found = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    if (found != null) return found.read<String>('id');
    final id = IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customInsert(
      '''INSERT INTO merchants(id,raw_name,normalized_name,first_seen_at,last_seen_at)
         VALUES(?,?,?,?,?);''',
      variables: [
        Variable.withString(id),
        Variable.withString(name),
        Variable.withString(normalized),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
    return id;
  }
}

String _required(Map<String, String> row, String key) {
  final value = _nullable(row[key]);
  if (value == null) throw DataPortabilityException('قيمة $key مفقودة.', code: DataPortabilityError.missingValue, args: [key]);
  return value;
}

String? _nullable(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

String _or(String? value, String fallback) => _nullable(value) ?? fallback;

String _currency(String? value) {
  final code = _or(value, '').toUpperCase();
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(code)) {
    throw DataPortabilityException('رمز عملة غير صالح: $value', code: DataPortabilityError.invalidCurrencyCode, args: ['$value']);
  }
  return code;
}

/// Currency for the base-currency planning tables: use the row's own value when
/// the package carries one (post-C-2 exports), otherwise fall back to the
/// importing device's base currency. Never returns null — a null currency would
/// reintroduce the C-2 corruption it exists to prevent.
String _currencyOr(String? value, String fallback) =>
    _nullable(value) == null ? fallback : _currency(value);

double? _double(String? value) =>
    _nullable(value) == null ? null : double.tryParse(value!.trim());

/// New Qirsh packages carry the canonical signed int64 minor units. Presence of
/// [minorKey] makes it authoritative even when the cell is empty (canonical
/// NULL); an invalid exact value fails closed instead of consulting the REAL
/// shadow. Only genuinely legacy packages, whose header omits [minorKey], use
/// the explicitly lossy REAL-number migration fallback below.
Money? _portableMoneyOrNull(
  Map<String, String> row, {
  required String minorKey,
  required String legacyKey,
  required String currency,
}) {
  if (!row.containsKey(minorKey)) {
    return _legacyMoneyOrNull(row[legacyKey], currency);
  }
  final text = _nullable(row[minorKey]);
  if (text == null) return null;
  final minor = int.tryParse(text);
  if (minor == null) {
    throw DataPortabilityException('قيمة مالية دقيقة غير صالحة: $minorKey', code: DataPortabilityError.invalidMinorAmount, args: [minorKey]);
  }
  return Money(minor, currency);
}

Money _portablePositiveMoney(
  Map<String, String> row, {
  required String minorKey,
  required String legacyKey,
  required String currency,
}) {
  final money = _portableMoneyOrNull(
    row,
    minorKey: minorKey,
    legacyKey: legacyKey,
    currency: currency,
  );
  if (money == null || money.isZero || money.isNegative) {
    throw DataPortabilityException('قيمة مالية غير صالحة: ${row[legacyKey]}', code: DataPortabilityError.invalidAmountLegacy, args: ['${row[legacyKey]}']);
  }
  return money;
}

/// Qirsh is a legacy numeric payload. Keep its quantization explicitly lossy;
/// new generic CSV ingress parses lexical text directly into Money.
Money? _legacyMoneyOrNull(String? value, String currency) {
  final text = _nullable(value);
  if (text == null) return null;
  final numeric = num.tryParse(text);
  if (numeric == null) {
    throw DataPortabilityException('قيمة مالية غير صالحة: $value', code: DataPortabilityError.invalidAmount, args: ['$value']);
  }
  return legacyLossyNumberToMoney(numeric, currency);
}

int _int(String? value) => int.tryParse(value?.trim() ?? '') ?? 0;
int? _intOrNull(String? value) => int.tryParse(value?.trim() ?? '');
int _boolInt(String? value) =>
    const {'1', 'true', 'yes'}.contains(value?.trim().toLowerCase()) ? 1 : 0;

String _date(String? value) {
  final parsed = DateTime.tryParse(value?.trim() ?? '');
  if (parsed == null) throw DataPortabilityException('تاريخ غير صالح: $value', code: DataPortabilityError.invalidDate, args: ['$value']);
  return dateTimeToSql(parsed.toUtc());
}

String? _nullableDate(String? value) =>
    _nullable(value) == null ? null : _date(value);

Map<String, Object> _resultToJson(ImportResult result) => {
      'imported': result.imported,
      'duplicates': result.duplicates,
      'skipped': result.skipped,
      'failed': result.failed,
    };

ImportResult _resultFromJson(String value) {
  final json = jsonDecode(value) as Map<String, dynamic>;
  return ImportResult(
    imported: json['imported'] as int? ?? 0,
    duplicates: json['duplicates'] as int? ?? 0,
    skipped: json['skipped'] as int? ?? 0,
    failed: json['failed'] as int? ?? 0,
  );
}
