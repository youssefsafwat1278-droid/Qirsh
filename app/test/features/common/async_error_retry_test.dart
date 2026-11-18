import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/achievements/achievements_providers.dart';
import 'package:money_companion/features/achievements/achievements_screen.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/accounts/account_detail_screen.dart';
import 'package:money_companion/features/accounts/accounts_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/cards/card_details_screen.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/common/app_error_state.dart';
import 'package:money_companion/features/common/app_header.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

class _FailingTransactions extends TransactionsListNotifier {
  _FailingTransactions(this.read);
  final Future<TransactionsView> Function() read;
  @override
  Future<TransactionsView> build() => read();
}

Future<void> _loadBundledFonts(WidgetTester tester) async {
  await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
  });
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final surface in ['card', 'goal', 'plans', 'achievements', 'accounts',
        'accountdetail', 'accountHistory', 'reports', 'goals', 'budgets',
        'budgetDetail', 'budgetCategories', 'activity']) {
      testWidgets('$surface read error Retry retries the same read without writes in $language', (tester) async {
        await _loadBundledFonts(tester);
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        var attempts = 0;
        Future<T> failure<T>() async {
          attempts++;
          throw StateError('synthetic local read failure');
        }
        if (surface == 'accountHistory') {
          await DriftAccountRepository(db).create(AccountEntity(
            id: 'synthetic-account', name: 'Family savings', currency: 'EGP',
            type: AccountType.bank, isDefault: true, sortOrder: 0,
            createdAt: DateTime.utc(2026, 10, 1),
            updatedAt: DateTime.utc(2026, 10, 1),
            initialBalanceMoney: Money.parse('1000.00', 'EGP'),
            currentBalanceMoney: Money.parse('1000.00', 'EGP')));
        }
        final overrides = <Override>[
          appDatabaseProvider.overrideWithValue(db),
          if (surface == 'card')
            cardTransactionsProvider('4471').overrideWith((ref) => failure()),
          if (surface == 'goal')
            goalDetailsProvider('synthetic-goal').overrideWith((ref) => failure()),
          if (surface == 'plans')
            plansWithSpentProvider.overrideWith((ref) => failure()),
          if (surface == 'achievements')
            achievementsViewProvider.overrideWith((ref) => failure()),
          if (surface == 'accounts' || surface == 'accountdetail')
            accountsProvider.overrideWith((ref) => failure()),
          if (surface == 'accountHistory')
            accountRecentTransactionsProvider('synthetic-account')
                .overrideWith((ref) => failure()),
          if (surface == 'reports')
            reportsProvider.overrideWith((ref) => failure()),
          if (surface == 'goals')
            goalsListProvider.overrideWith((ref) => failure()),
          if (surface == 'budgets')
            budgetsViewProvider.overrideWith((ref) => failure()),
          if (surface == 'budgetDetail')
            budgetByIdProvider('synthetic-budget').overrideWith((ref) => failure()),
          if (surface == 'budgetCategories')
            categoryCatalogProvider.overrideWith((ref) => failure()),
          if (surface == 'activity')
            transactionsListProvider.overrideWith(() =>
                _FailingTransactions(() => failure<TransactionsView>())),
        ];
        final Widget screen = switch (surface) {
          'card' => const CardDetailsScreen(last4: '4471'),
          'goal' => const GoalDetailsScreen(goalId: 'synthetic-goal'),
          'plans' => const PlansScreen(),
          'accounts' => const AccountsScreen(),
          'accountdetail' || 'accountHistory' =>
              const AccountDetailScreen(accountId: 'synthetic-account'),
          'reports' => const ReportsScreen(),
          'goals' => const GoalsScreen(),
          'budgets' => const BudgetsScreen(),
          'budgetDetail' => const BudgetFormScreen(budgetId: 'synthetic-budget'),
          'budgetCategories' => const BudgetFormScreen(),
          'activity' => const TransactionsScreen(),
          _ => const AchievementsScreen(),
        };
        await tester.pumpWidget(ProviderScope(overrides: overrides,
          child: MaterialApp(
            theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
            locale: Locale(language),
            supportedLocales: AppL10n.supportedLocales,
            localizationsDelegates: AppL10n.localizationsDelegates,
            home: screen,
          ),
        ));
        await tester.pumpAndSettle();
        expect(find.byType(AppErrorState), findsOneWidget);
        final context = tester.element(find.byType(AppErrorState));
        final l10n = AppL10n.of(context);
        expect(find.text(l10n.annTryAgainSoon), findsOneWidget);
        if (surface == 'achievements') {
          expect(find.text(l10n.achTitle), findsOneWidget);
          expect(find.text(l10n.achSubtitle), findsOneWidget);
        }
        final changesBefore = (await db.customSelect(
            'SELECT total_changes() AS writes').getSingle()).read<int>('writes');
        final attemptsBefore = attempts;
        final retry = find.text(l10n.startRetry);
        await tester.ensureVisible(retry);
        // ensureVisible moves the scroll offset; the new position is laid out
        // on the next frame, so pump before tapping.
        await tester.pump();
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(attempts, attemptsBefore + 1);
        expect(find.byType(AppErrorState), findsOneWidget);
        expect((await db.customSelect('SELECT total_changes() AS writes')
            .getSingle()).read<int>('writes'), changesBefore);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }

    for (final section in ['details', 'history']) {
      testWidgets('plan $section Retry keeps the real plan and only retries its read in $language', (tester) async {
        await _loadBundledFonts(tester);
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final repository = DriftPlanRepository(db);
        final plan = PlanEntity(id: 'synthetic-retry-plan', name: 'Family trip',
          budgetAmountMoney: Money.parse('2500.00', 'EGP'), currency: 'EGP',
          startDate: DateTime.now().subtract(const Duration(days: 1)),
          endDate: DateTime.now().add(const Duration(days: 2)),
          accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
          createdAt: DateTime.utc(2026, 9, 15), icon: 'plane');
        await repository.save(plan);
        var attempts = 0;
        Future<T> failure<T>() async {
          attempts++;
          throw StateError('synthetic plan read failure');
        }
        await tester.pumpWidget(ProviderScope(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          planRepositoryProvider.overrideWithValue(repository),
          if (section == 'details') planProgressProvider(plan.id)
              .overrideWith((ref) => failure()),
          if (section == 'history') planTransactionsProvider(plan.id)
              .overrideWith((ref) => failure()),
        ], child: MaterialApp(
          theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const PlansScreen(),
        )));
        await tester.pumpAndSettle();
        final planL10n = AppL10n.of(tester.element(find.byType(PlansScreen)));
        final perDay = find.text(planL10n.plPerDayLeft(plan.daysLeft));
        await tester.ensureVisible(perDay);
        expect(tester.getRect(perDay).left, greaterThanOrEqualTo(0));
        expect(tester.getRect(perDay).right, lessThanOrEqualTo(375));
        await tester.tap(find.text(plan.name));
        await tester.pumpAndSettle();
        final error = find.byType(AppErrorState);
        expect(error, findsOneWidget);
        final l10n = AppL10n.of(tester.element(error));
        expect(find.text(section == 'details'
            ? l10n.plLoadFailed : l10n.plTxLoadFailed), findsOneWidget);
        final writes = (await db.customSelect('SELECT total_changes() AS writes')
            .getSingle()).read<int>('writes');
        final before = attempts;
        final retry = find.text(l10n.startRetry);
        await tester.ensureVisible(retry);
        await tester.tap(retry);
        await tester.pumpAndSettle();
        expect(attempts, before + 1);
        expect((await db.customSelect('SELECT total_changes() AS writes')
            .getSingle()).read<int>('writes'), writes);
        expect((await repository.getById(plan.id))!.icon, 'plane');
        expect((await repository.getById(plan.id))!.budgetAmountMoney,
            plan.budgetAmountMoney);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }

    testWidgets('achievements loading keeps its title and navigation in $language', (tester) async {
      await _loadBundledFonts(tester);
      final pending = Completer<AchievementsView>();
      await tester.pumpWidget(ProviderScope(overrides: [
        achievementsViewProvider.overrideWith((ref) => pending.future),
      ], child: MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        home: Builder(builder: (context) => Scaffold(body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const AchievementsScreen())),
          child: const Text('Open achievements'),
        ))),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open achievements'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final l10n = AppL10n.of(tester.element(find.byType(AchievementsScreen)));
      expect(find.text(l10n.achTitle), findsOneWidget);
      expect(find.text(l10n.achSubtitle), findsOneWidget);
      expect(tester.widget<AppHeader>(find.byType(AppHeader)).title,
          l10n.achTitle);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      for (var frame = 0; frame < 20 &&
          find.byType(AchievementsScreen).evaluate().isNotEmpty; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(AchievementsScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
