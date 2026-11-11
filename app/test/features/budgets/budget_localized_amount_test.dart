import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_budget_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/save_budget_usecase.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  late AppDatabase db;
  late DriftBudgetRepository repository;
  late List<AccountEntity> accounts;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    repository = DriftBudgetRepository(db);
    final accountRepository = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 10, 1);
    accounts = [
      for (final spec in [('mina', 'EGP', true), ('sofa', 'KWD', false)])
        AccountEntity(id: spec.$1, name: spec.$1, currency: spec.$2,
          type: AccountType.bank, isDefault: spec.$3, sortOrder: 0,
          createdAt: now, updatedAt: now,
          initialBalanceMoney: Money.zero(spec.$2), currentBalanceMoney: Money.zero(spec.$2)),
    ];
    for (final account in accounts) {
      await accountRepository.create(account);
    }
  });
  tearDown(() async => db.close());

  BudgetEntity budget(String currency, String accountId) => BudgetEntity(
    id: 'existing-budget', categoryId: BudgetEntity.allExpensesCategoryId,
    currency: currency, amountMoney: Money.parse('25', currency),
    lastNotifiedSpentMoney: Money.parse('5', currency), period: BudgetPeriod.weekly,
    startDate: DateTime.utc(2026, 10, 1), isActive: true,
    lastNotifiedPeriodStart: DateTime.utc(2026, 10, 15),
    accountId: accountId, alertThresholdPercent: 55,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  Future<AppL10n> open(WidgetTester tester, {String language = 'ar',
      String baseCurrency = 'KWD', BudgetEntity? existing,
      DriftBudgetRepository? savingRepository, bool denseCatalog = false}) async {
    tester.view.physicalSize = denseCatalog ? const Size(375, 667) : const Size(402, 874);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    if (existing != null) await repository.save(existing);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      budgetRepositoryProvider.overrideWithValue(repository),
      saveBudgetUseCaseProvider.overrideWithValue(SaveBudgetUseCase(savingRepository ?? repository)),
      transactionRepositoryProvider.overrideWithValue(DriftTransactionRepository(db)),
      categoryCatalogProvider.overrideWith((_) async => CategoryCatalog([
        if (denseCatalog) for (var index = 0; index < 30; index++)
          CategoryEntity(id: 'category-$index', key: 'synthetic-$index',
            nameAr: 'فئة $index', icon: 'shopping-cart',
            color: '#16A37F', isIncome: false, sort: index),
      ], languageCode: language)),
      accountsProvider.overrideWith((_) async => accounts),
      baseCurrencyProvider.overrideWith((_) async => baseCurrency),
    ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => BudgetFormScreen(budgetId: existing?.id))),
        child: const Text('Open budget'),
      ))),
    )));
    await settle(tester);
    await tester.tap(find.text('Open budget'));
    await settle(tester);
    return AppL10n.of(tester.element(find.byType(BudgetFormScreen)));
  }

  Future<void> submit(WidgetTester tester, AppL10n l10n, String input) async {
    await tester.enterText(find.byType(TextFormField).first, input);
    tester.testTextInput.hide();
    await settle(tester);
    await tester.ensureVisible(find.text(l10n.bfsSaveBudget));
    await tester.tap(find.text(l10n.bfsSaveBudget));
    await settle(tester);
  }

  for (final language in ['ar', 'en']) {
    for (final input in ['0', '-1', '12.345', '١٢٫٣٤']) {
      testWidgets('virtualized budget amount remains validated at Save $input in $language', (tester) async {
        final l10n = await open(tester, language: language,
            baseCurrency: 'EGP', denseCatalog: true);
        await tester.enterText(find.byType(TextFormField).first, input);
        tester.testTextInput.hide();
        await settle(tester);
        final save = find.text(l10n.bfsSaveBudget);
        // v2: Save lives in a sticky dock and the category grid starts
        // collapsed, so open the full grid and scroll to its end to push the
        // amount field out of the list.
        await tester.tap(find.text(l10n.bfsV2ShowAll));
        await settle(tester);
        await tester.scrollUntilVisible(find.text('فئة 29'), 500,
            scrollable: find.byType(Scrollable).first);
        await tester.drag(find.byType(Scrollable).first, const Offset(0, -2000));
        await settle(tester);
        expect(find.byType(TextFormField), findsNothing,
            reason: 'the amount field must actually be disposed by the long category list');
        await tester.tap(save);
        await settle(tester);
        final saved = await repository.getAll();
        if (input == '١٢٫٣٤') {
          expect(saved, hasLength(1));
          expect(saved.single.amountMoney, Money(1234, 'EGP'));
          expect(saved.single.currency, 'EGP');
          expect(saved.single.accountId, 'mina');
          expect(find.byType(BudgetFormScreen), findsNothing);
        } else {
          expect(saved, isEmpty);
          expect(find.text(l10n.gfEnterValidAmount), findsOneWidget);
          expect(find.text(l10n.bfSaveFailed), findsNothing);
          expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
          expect(find.byType(BudgetFormScreen), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
          await settle(tester);
          await tester.scrollUntilVisible(find.byType(TextFormField), -500,
              scrollable: find.byType(Scrollable).first);
          await settle(tester);
          expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, input);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final spec in [('ar', '١٢٫٣٤٥', 12345), ('en', '12,345.678', 12345678)]) {
    testWidgets('new budget saves exact localized base-currency amount ${spec.$2} in real Drift', (tester) async {
      final l10n = await open(tester, language: spec.$1);
      await submit(tester, l10n, spec.$2);
      final saved = (await repository.getAll()).single;
      expect(saved.currency, 'KWD');
      expect(saved.amountMoney.minorUnits, spec.$3);
      expect(saved.accountId, 'mina', reason: 'new budget keeps existing default-account selection');
      expect(find.byType(BudgetFormScreen), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('editing KWD uses persisted currency despite EGP base and preserves account and metadata', (tester) async {
    final existing = budget('KWD', 'sofa');
    final l10n = await open(tester, existing: existing, baseCurrency: 'EGP');
    await submit(tester, l10n, '١٢٫٣٤٥');
    final saved = (await repository.getById(existing.id))!;
    expect(saved.amountMoney, Money(12345, 'KWD'));
    expect(saved.currency, existing.currency);
    expect(saved.accountId, existing.accountId);
    expect(saved.categoryId, existing.categoryId);
    expect(saved.period, existing.period);
    expect(saved.startDate, existing.startDate);
    expect(saved.isActive, existing.isActive);
    expect(saved.lastNotifiedSpentMoney, existing.lastNotifiedSpentMoney);
    expect(saved.lastNotifiedPeriodStart, existing.lastNotifiedPeriodStart);
    expect(saved.alertThresholdPercent, existing.alertThresholdPercent);
    expect((await repository.getAll()), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid amount remains inline with original input and no budget writes', (tester) async {
    final l10n = await open(tester);
    for (final input in ['abc', '0', '-1', '12.3456', '1,23']) {
      await tester.ensureVisible(find.byType(TextFormField).first);
      await submit(tester, l10n, input);
      expect(find.text(l10n.gfEnterValidAmount), findsNWidgets(2),
          reason: 'mounted inline validation and shared error notice both remain visible');
      expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, input);
      expect(await repository.getAll(), isEmpty);
      expect(find.text(l10n.bfSaveFailed), findsNothing,
          reason: 'invalid amounts are rejected before persistence, not as a save failure');
      expect(tester.takeException(), isNull);
    }
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });

  testWidgets('EGP edit rejects three decimals even when base currency is KWD', (tester) async {
    final existing = budget('EGP', 'mina');
    final l10n = await open(tester, existing: existing);
    await submit(tester, l10n, '12.345');
    expect(find.text(l10n.gfEnterValidAmount), findsNWidgets(2));
    expect(tester.widget<TextFormField>(find.byType(TextFormField).first).controller!.text, '12.345');
    final saved = (await repository.getById(existing.id))!;
    expect(saved.amountMoney, existing.amountMoney);
    expect(saved.currency, 'EGP');
    expect(saved.accountId, 'mina');
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });

  testWidgets('repository refusal retains form and shows error alert rather than success', (tester) async {
    final refused = DriftBudgetRepository(db, coordinator:
      const FixedPlanningCutoverCoordinator(PlanningCutoverState.unresolved));
    final l10n = await open(tester, savingRepository: refused);
    await submit(tester, l10n, '12.345');
    expect(find.text(l10n.bfSaveFailed), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
    expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
    expect(find.byType(BudgetFormScreen), findsOneWidget);
    expect(await repository.getAll(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pump(const Duration(seconds: 4));
    await settle(tester);
  });
}
