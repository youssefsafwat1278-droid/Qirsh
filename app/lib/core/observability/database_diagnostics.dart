import 'package:drift/drift.dart';

import 'app_diagnostics.dart';

/// Observe the shared SQL boundary without retaining SQL text, arguments,
/// result rows, affected row counts or database paths. Successful hot queries
/// are counted; only failures/slow queries enter the bounded event journal.
class DatabaseDiagnostics extends QueryInterceptor {
  DatabaseDiagnostics();

  static final _mutation = RegExp(
      r'^\s*(?:INSERT(?: OR \w+)? INTO|UPDATE|DELETE FROM)\s+["`]?([a-z_]+)',
      caseSensitive: false);
  static AppOperation _operation(String sql) =>
      switch (_mutation.firstMatch(sql)?.group(1)?.toLowerCase()) {
        'accounts' => AppOperation.accountWrite,
        'transactions' => AppOperation.transactionWrite,
        'budgets' => AppOperation.budgetWrite,
        'goals' || 'goal_contributions' => AppOperation.goalWrite,
        'bills' || 'bill_payments' => AppOperation.billWrite,
        'cards' => AppOperation.cardWrite,
        'coupons' || 'coupon_events' => AppOperation.couponWrite,
        'engagement_events' || 'achievements' => AppOperation.engagementWrite,
        'user_settings' => AppOperation.settingsWrite,
        'banks' || 'sms_parsers' || 'categories' => AppOperation.catalogWrite,
        _ => AppOperation.databaseWrite,
      };

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) =>
      AppDiagnostics.measure(
          AppOperation.databaseOpen, () => executor.ensureOpen(user));

  @override
  Future<void> runBatched(
          QueryExecutor executor, BatchedStatements statements) =>
      AppDiagnostics.measure(
          AppOperation.databaseWrite, () => executor.runBatched(statements));

  @override
  Future<void> runCustom(
          QueryExecutor executor, String statement, List<Object?> args) =>
      AppDiagnostics.measure(
          _operation(statement), () => executor.runCustom(statement, args));

  @override
  Future<int> runInsert(
          QueryExecutor executor, String statement, List<Object?> args) =>
      AppDiagnostics.measure(
          _operation(statement), () => executor.runInsert(statement, args));

  @override
  Future<int> runUpdate(
          QueryExecutor executor, String statement, List<Object?> args) =>
      AppDiagnostics.measure(
          _operation(statement), () => executor.runUpdate(statement, args));

  @override
  Future<int> runDelete(
          QueryExecutor executor, String statement, List<Object?> args) =>
      AppDiagnostics.measure(
          _operation(statement), () => executor.runDelete(statement, args));

  @override
  Future<List<Map<String, Object?>>> runSelect(
          QueryExecutor executor, String statement, List<Object?> args) =>
      AppDiagnostics.measure(
          AppOperation.databaseRead, () => executor.runSelect(statement, args));

  @override
  Future<void> commitTransaction(TransactionExecutor inner) =>
      AppDiagnostics.measure(AppOperation.databaseCommit, inner.send);

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) =>
      AppDiagnostics.measure(AppOperation.databaseRollback, inner.rollback);
}
