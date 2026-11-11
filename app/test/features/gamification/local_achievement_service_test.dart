import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_gamification_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/achievement_catalog.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/budget_progress_usecase.dart';
import 'package:money_companion/domain/usecases/save_budget_usecase.dart';
import 'package:money_companion/features/gamification/services/achievement_unlocks.dart';
import 'package:money_companion/features/gamification/services/local_achievement_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  late AppDatabase db;
  final now = DateTime(2026, 11, 10, 12);

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });
  tearDown(() => db.close());

  Future<List<AchievementDefinition>> reconcile() =>
      LocalAchievementService(db).reconcile(now: now, isCurrent: () => true);

  Future<void> saveBudget(DateTime start) =>
      SaveBudgetUseCase(DriftBudgetRepository(db))(BudgetEntity(
        id: 'first-budget',
        categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'EGP',
        amountMoney: Money.parse('1000', 'EGP'),
        period: BudgetPeriod.monthly,
        startDate: start,
        isActive: true,
        lastNotifiedSpentMoney: Money.zero('EGP'),
        lastNotifiedPeriodStart: start,
      ));

  Future<void> put(
    String id,
    DateTime at, {
    String amount = '10',
    TransactionStatus status = TransactionStatus.confirmed,
  }) =>
      DriftTransactionRepository(db).saveTransaction(
        transaction: TransactionEntity(
          id: id,
          amountMoney: Money.parse(amount, 'EGP'),
          currency: 'EGP',
          type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.bank,
          occurredAt: at,
          rawMessage: id,
          parseConfidence: 1,
          status: status,
          createdAt: at,
          updatedAt: at,
          rawMerchant: 'Test',
        ),
        categoryKey: 'restaurants',
      );

  test('saving the first budget unlocks and announces exactly once', () async {
    expect(await reconcile(), isEmpty);
    await saveBudget(now);

    final runs = await Future.wait([reconcile(), reconcile()]);
    final earned = runs.expand((badges) => badges).toList();
    expect(earned, [AchievementCatalog.firstBudget]);
    final badge = await DriftGamificationRepository(db)
        .getAchievementByKey(AchievementCatalog.firstBudget.key);
    expect(badge?.unlockedAt, now.toUtc());
    final settings = DriftUserSettingsRepository(db);
    await settings
        .saveSettings((await settings.getSettings()).copyWith(language: 'en'));
    final titles = <String>[];
    await notifyAchievementUnlocks(db, earned,
        isCurrent: () => true,
        notify: (
            {required achievementKey,
            required title,
            required body,
            required preferences}) async {
          expect(achievementKey, 'first_budget');
          expect(preferences.achievements, isTrue);
          titles.add(title);
        });
    expect(titles.single, contains('First budget'));
    expect(await reconcile(), isEmpty);
    expect(await unlockAchievement(db, 'first_budget', now), isFalse);
  });

  test(
      'pending transactions do not count; confirmed transactions earn milestones',
      () async {
    await put('pending', now, status: TransactionStatus.pending);
    expect(await reconcile(), isEmpty);
    for (var i = 0; i < 100; i++) {
      await put('tx-$i', now.subtract(Duration(days: i % 7)));
    }
    expect(
        await reconcile(),
        unorderedEquals([
          AchievementCatalog.firstTransaction,
          AchievementCatalog.tenthTransaction,
          AchievementCatalog.centuryTransaction,
          AchievementCatalog.streak7Days,
        ]));
  });

  test('budget, savings, goal and restaurant badges use saved records',
      () async {
    final settings = DriftUserSettingsRepository(db);
    await settings
        .saveSettings((await settings.getSettings()).copyWith(currency: 'EGP'));
    await saveBudget(DateTime(2026, 9, 1));
    await put('september', DateTime(2026, 9, 5), amount: '950');
    await put('october', DateTime(2026, 10, 5), amount: '700');
    await put('november', DateTime(2026, 11, 5), amount: '100');
    final goals = DriftGoalRepository(db);
    final goal = await goals.save(GoalEntity(
      id: 'g',
      name: 'Trip',
      currency: 'EGP',
      targetMoney: Money.parse('500', 'EGP'),
      savedMoney: Money.parse('100', 'EGP'),
      lastNotifiedSavedMoney: Money.zero('EGP'),
      vaultSkin: 'summer_trip',
      status: 'active',
      createdAt: now,
    ));

    expect(
        await reconcile(),
        unorderedEquals([
          AchievementCatalog.firstTransaction,
          AchievementCatalog.firstBudget,
          AchievementCatalog.monthWithoutOverrun,
          AchievementCatalog.saved500,
          AchievementCatalog.restaurantsMinus20,
        ]));
    await goals.save(goal.copyWith(savedMoney: goal.targetMoney));
    expect(await reconcile(), [AchievementCatalog.firstGoal]);
  });

  test('progress is read-only and follows the badge rules', () async {
    final service = LocalAchievementService(db);
    final empty = await service.progress();
    expect(empty[AchievementCatalog.firstTransaction.key], 0);
    expect(empty[AchievementCatalog.firstGoal.key], 0);
    // Badges without a gradual measure carry no progress at all.
    expect(empty.containsKey(AchievementCatalog.firstBudget.key), isFalse);
    expect(empty.containsKey(AchievementCatalog.saved500.key), isFalse);

    await put('pending', now, status: TransactionStatus.pending);
    for (var i = 0; i < 4; i++) {
      await put('tx-$i', now);
    }
    await DriftGoalRepository(db).save(GoalEntity(
      id: 'g',
      name: 'Trip',
      currency: 'EGP',
      targetMoney: Money.parse('500', 'EGP'),
      savedMoney: Money.parse('125', 'EGP'),
      lastNotifiedSavedMoney: Money.zero('EGP'),
      vaultSkin: 'summer_trip',
      status: 'active',
      createdAt: now,
    ));
    final writesBefore = (await db
            .customSelect('SELECT total_changes() AS n')
            .getSingle())
        .read<int>('n');
    final progress = await service.progress();
    expect(progress[AchievementCatalog.firstTransaction.key], 1);
    expect(progress[AchievementCatalog.tenthTransaction.key], closeTo(.4, 1e-9));
    expect(progress[AchievementCatalog.centuryTransaction.key], closeTo(.04, 1e-9));
    expect(progress[AchievementCatalog.firstGoal.key], closeTo(.25, 1e-9));
    expect(
        (await db.customSelect('SELECT total_changes() AS n').getSingle())
            .read<int>('n'),
        writesBefore);
  });

  test('rollover records a full completed month before advancing the budget',
      () async {
    await saveBudget(DateTime(2026, 10, 1));
    await put('october', DateTime(2026, 10, 5), amount: '700');
    final repo = DriftBudgetRepository(db);
    final reported = <DateTime>[];
    final progress = BudgetProgressUseCase(
      budgetRepository: repo,
      transactionRepository: DriftTransactionRepository(db),
      onMonthUnderBudget: (at) async {
        final stored = await repo.getById('first-budget');
        expect(stored?.startDate, DateTime(2026, 10, 1).toUtc());
        reported.add(at);
      },
    );
    await progress(now: now);
    await progress(now: now);
    expect(reported, [DateTime(2026, 11, 1)]);
  });
}
