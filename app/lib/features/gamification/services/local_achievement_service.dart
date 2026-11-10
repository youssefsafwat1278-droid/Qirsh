import 'package:drift/drift.dart' show Variable;

import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_budget_repository.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/achievement_catalog.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/finance/budget_period.dart';
import '../../../domain/finance/financial_period.dart';
import '../../../domain/finance/money.dart';
import '../../../engine/categorization/category.dart';
import 'achievement_unlocks.dart';

/// Derives badges from this device's committed data, including with Cloud off.
/// The Cloud service still owns XP and never receives client-computed awards.
class LocalAchievementService {
  LocalAchievementService(this.db);

  final AppDatabase db;

  Future<List<AchievementDefinition>> reconcile({
    required DateTime now,
    required bool Function() isCurrent,
  }) async {
    if (!isCurrent()) return [];
    return db.transaction(() async {
      final locked = {
        for (final row in await db
            .customSelect(
                'SELECT key FROM achievements WHERE unlocked_at IS NULL')
            .get())
          row.read<String>('key'),
      };
      if (locked.isEmpty || !isCurrent()) return [];
      final earned = <AchievementDefinition>[];
      bool needs(AchievementDefinition badge) => locked.contains(badge.key);
      const first = AchievementCatalog.firstTransaction;
      const tenth = AchievementCatalog.tenthTransaction;
      const century = AchievementCatalog.centuryTransaction;
      const streak = AchievementCatalog.streak7Days;
      const firstBudget = AchievementCatalog.firstBudget;
      const firstGoal = AchievementCatalog.firstGoal;
      const underBudget = AchievementCatalog.monthWithoutOverrun;
      const saved = AchievementCatalog.saved500;
      const restaurants = AchievementCatalog.restaurantsMinus20;

      if ([first, tenth, century].any(needs)) {
        final count = (await db
                .customSelect(
                  "SELECT COUNT(*) AS n FROM transactions WHERE status = 'confirmed'",
                )
                .getSingle())
            .read<int>('n');
        if (count >= 1) earned.add(first);
        if (count >= 10) earned.add(tenth);
        if (count >= 100) earned.add(century);
      }
      if (needs(streak) && await _hasSevenDayStreak(now)) earned.add(streak);
      if (needs(firstGoal) &&
          (await db
                  .customSelect(
                    'SELECT 1 FROM goals WHERE deleted_at IS NULL AND '
                    'target_amount_minor > 0 AND saved_amount_minor >= target_amount_minor LIMIT 1',
                  )
                  .getSingleOrNull()) !=
              null) {
        earned.add(firstGoal);
      }

      final current = FinancialPeriod.month(now);
      final previous = FinancialPeriod.month(
        current.from.subtract(const Duration(microseconds: 1)),
      );
      final tx = DriftTransactionRepository(db);
      if (needs(firstBudget) || needs(underBudget)) {
        final budgets = await DriftBudgetRepository(db).getAll();
        if (budgets.isNotEmpty) earned.add(firstBudget);
        if (needs(underBudget)) {
          for (final budget in budgets) {
            if (!budget.isActive ||
                budget.period != BudgetPeriod.monthly ||
                budget.startDate.isAfter(previous.from)) {
              continue;
            }
            final spent = await budgetSpent(tx, budget, previous);
            if (spent.minorUnits > 0 &&
                spent.compareTo(budget.amountMoney) <= 0) {
              earned.add(underBudget);
              break;
            }
          }
        }
      }
      if (needs(saved) || needs(restaurants)) {
        final currency =
            (await DriftUserSettingsRepository(db).getSettings()).currency;
        if (needs(saved)) {
          final (last, thisMonth) = await (
            tx.expenseTotalBetween(
                from: previous.from, to: previous.to, currency: currency),
            tx.expenseTotalBetween(
                from: current.from, to: current.to, currency: currency),
          ).wait;
          // Use the dashboard's month-over-month expense savings.
          if (!thisMonth.isZero &&
              (last - thisMonth).compareTo(Money.parse('500', currency)) >= 0) {
            earned.add(saved);
          }
        }
        if (needs(restaurants)) {
          final category = await db.customSelect(
            'SELECT id FROM categories WHERE key = ?',
            variables: [Variable.withString(Categories.restaurants.key)],
          ).getSingleOrNull();
          if (category != null) {
            final before = FinancialPeriod.month(
              previous.from.subtract(const Duration(microseconds: 1)),
            );
            final id = category.read<String>('id');
            final (baseline, recent, expenses) = await (
              tx.categoryExpenseTotalBetween(
                categoryId: id,
                from: before.from,
                to: before.to,
                currency: currency,
              ),
              tx.categoryExpenseTotalBetween(
                categoryId: id,
                from: previous.from,
                to: previous.to,
                currency: currency,
              ),
              tx.expenseTotalBetween(
                  from: previous.from, to: previous.to, currency: currency),
            ).wait;
            if (baseline.minorUnits > 0 &&
                expenses.minorUnits > 0 &&
                recent.minorUnits / baseline.minorUnits <= 0.8) {
              earned.add(restaurants);
            }
          }
        }
      }

      final unlocked = <AchievementDefinition>[];
      for (final badge in earned) {
        if (!isCurrent()) break;
        if (needs(badge) && await unlockAchievement(db, badge.key, now)) {
          unlocked.add(badge);
        }
      }
      return unlocked;
    });
  }

  Future<bool> _hasSevenDayStreak(DateTime now) async {
    final longest = await db
        .customSelect(
          'SELECT MAX(longest_streak) AS longest FROM streaks',
        )
        .getSingle();
    if ((longest.readNullable<int>('longest') ?? 0) >= 7) return true;

    final days = await db.customSelect(
      "SELECT DISTINCT date(occurred_at, 'localtime') AS day FROM transactions "
      "WHERE status = 'confirmed' AND occurred_at <= ? ORDER BY day",
      variables: [Variable.withString(dateTimeToSql(now))],
    ).get();
    DateTime? previous;
    var consecutive = 0;
    for (final row in days) {
      final date = row.readNullable<String>('day');
      if (date == null) continue;
      // Compare UTC representations of local calendar dates to ignore DST.
      final day = DateTime.parse('${date}T00:00:00Z');
      consecutive = previous != null && day.difference(previous).inDays == 1
          ? consecutive + 1
          : 1;
      if (consecutive >= 7) return true;
      previous = day;
    }
    return false;
  }
}
