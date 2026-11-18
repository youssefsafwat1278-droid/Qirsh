import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/coupons/savings_math.dart';
import 'package:money_companion/features/coupons/savings_repository.dart';
import 'package:money_companion/features/coupons/savings_screen.dart';
// Observe external-launch boundary only; never open an external application.
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/link.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:money_companion/core/theme/widgets/qirsh_visuals.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/features/common/app_empty_state.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/app_missing_record_state.dart';
import 'package:money_companion/features/common/app_header.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/features/settings/sync_diagnostics_screen.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

import '../../../tool/visual_parity/extended_surfaces.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'visual-memory-only';
  @override
  Future<String?> readStoredKey() async => 'visual-memory-only';
}

class _NoLaunch extends UrlLauncherPlatform {
  int calls = 0;
  @override
  Widget Function(LinkInfo)? get linkDelegate => null;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    calls++;
    throw StateError('fixture_must_not_launch');
  }
}

Future<bool>? _openingSurface;

class _Launch extends ConsumerWidget {
  const _Launch(this.surface);
  final String surface;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(child: TextButton(
      onPressed: () => _openingSurface = openVisualParityExtendedSurface(context, ref, surface),
      child: const Text('Open fixture'),
    )),
  );
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
      keyStore: _MemoryKeys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  Future<void> open(WidgetTester tester, String surface, {List<Override> overrides = const [], String language = 'en', bool dark = false}) async {
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      ...overrides,
    ], child: MaterialApp(
      theme: dark ? AppTheme.dark : AppTheme.light,
      locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: _Launch(surface),
    )));
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.text('Open fixture'));
      await _openingSurface;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<Map<String, Object>> savingsSnapshot() async => {
    for (final table in ['accounts', 'transactions', 'subscriptions', 'goals',
        'budgets', 'plans', 'local_offer_savings'])
      table: (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
          .map((row) => row.data).toList(),
  };

  for (final language in ['ar', 'en']) {
    testWidgets('syncDiagnosticsLoading $language holds only public local read', (tester) async {
      final before = (await db.customSelect('SELECT * FROM user_settings').get())
          .map((row) => row.data).toList();
      final priorCount = visualParityExtendedEvents()['syncDiagnosticsReadLoading'] ?? 0;
      await open(tester, 'syncDiagnosticsLoading', language: language);
      expect(find.byType(SyncDiagnosticsScreen), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(visualParityExtendedEvents()['syncDiagnosticsReadLoading'], priorCount + 1);
      await tester.pump(const Duration(seconds: 2));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect((await db.customSelect('SELECT * FROM user_settings').get())
          .map((row) => row.data).toList(), before);
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(SyncDiagnosticsScreen))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Open fixture'), findsOneWidget);
    });

    testWidgets('subscriptionsSuggestionsOnly $language uses real recurrence with zero bills and repeat unchanged', (tester) async {
      await open(tester, 'subscriptionsSuggestionsOnly', language: language);
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final transactions = DriftTransactionRepository(db);
      final candidates = await transactions.recurringCandidates(
          accountId: 'qa-subscriptions-suggestions-account');
      expect(candidates, hasLength(1));
      expect(candidates.single.name, 'QA suggestions only');
      expect(candidates.single.estimatedAmountMoney, Money(12345, 'KWD'));
      expect(candidates.single.monthsSeen, 3);
      expect(await DriftBillRepository(db).getAll(), isEmpty);
      expect(find.text('QA suggestions only'), findsOneWidget);
      expect(find.textContaining('12.345'), findsWidgets);
      final before = await savingsSnapshot();
      Navigator.of(tester.element(find.byType(SubscriptionsScreen))).pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Open fixture'));
        await _openingSurface;
      });
      await tester.pumpAndSettle();
      expect(await savingsSnapshot(), before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('subscriptionsSuggestionsOnly rejects unrelated account before any writes', (tester) async {
    final now = DateTime.now();
    await DriftAccountRepository(db).create(AccountEntity(id: 'unrelated',
      name: 'Keep', currency: 'EGP', type: AccountType.bank,
      isDefault: true, sortOrder: 0, createdAt: now, updatedAt: now));
    final before = await savingsSnapshot();
    Object? rejection;
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ], child: MaterialApp(home: Consumer(builder: (context, ref, _) =>
      Scaffold(body: TextButton(onPressed: () async {
        try { await openVisualParityExtendedSurface(context, ref, 'subscriptionsSuggestionsOnly'); }
        catch (error) { rejection = error; }
      }, child: const Text('guard')))))));
    await tester.tap(find.text('guard'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(rejection, isA<StateError>());
    expect(await savingsSnapshot(), before);
    expect(tester.takeException(), isNull);
  });

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final key in ['savingsConfirmComputable', 'savingsConfirmPending', 'savingsConfirmError']) {
        testWidgets('$key $language dark$dark exposes only real local outcome', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final before = await savingsSnapshot();
          final event = key == 'savingsConfirmPending'
              ? 'savingsRecordPendingAdmission' : 'savingsRecordErrorAdmission';
          final priorAdmissions = visualParityExtendedEvents()[event] ?? 0;
          await open(tester, key, language: language, dark: dark);
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(TextField)));
          await tester.enterText(find.byType(TextField), '250.000');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          expect(find.text('25.000'), findsOneWidget);
          final save = find.widgetWithText(FilledButton, l10n.savingsConfirmAction);
          await tester.tap(save);
          if (key == 'savingsConfirmPending') {
            await tester.tap(save);
            await tester.pump(const Duration(milliseconds: 100));
            expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
            expect(find.byType(CircularProgressIndicator), findsOneWidget);
            expect(visualParityExtendedEvents()[event], priorAdmissions + 1);
            expect(await savingsSnapshot(), before);
            await tester.pumpWidget(const SizedBox());
            await tester.pump();
          } else {
            await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
            await tester.pumpAndSettle();
            if (key == 'savingsConfirmError') {
              expect(find.text(l10n.txnError), findsOneWidget);
              expect(find.textContaining('synthetic_visual_savings'), findsNothing);
              expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNotNull);
              expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '250.000');
              expect(visualParityExtendedEvents()[event], priorAdmissions + 1);
              expect(await savingsSnapshot(), before);
              await tester.pump(const Duration(seconds: 7));
              await tester.pumpAndSettle();
            } else {
              final entries = await SavingsRepository(db).history();
              expect(entries, hasLength(1));
              expect(entries.single.amountMinor, 25000);
              expect(entries.single.currency, 'KWD');
              expect(entries.single.evidence, SavingsEvidence.userConfirmed);
              expect(entries.single.couponId, 'qa-computable-savings');
              final after = await savingsSnapshot();
              for (final table in before.keys.where((name) => name != 'local_offer_savings')) {
                expect(after[table], before[table]);
              }
              expect(find.text('Open fixture'), findsOneWidget);
            }
          }
          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('savingsPopulated $language keeps exact separate currency evidence and repeat data', (tester) async {
      await open(tester, 'savingsPopulated', language: language);
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final repository = SavingsRepository(db);
      final totals = await repository.totals();
      expect(totals.byCurrencyAndEvidence.keys.toSet(), {'EGP', 'KWD', 'JPY'});
      expect(totals.totalFor('EGP'), 20801);
      expect(totals.totalFor('KWD'), 17346);
      expect(totals.totalFor('JPY'), 12345);
      expect(totals.byCurrencyAndEvidence['EGP'], {
        SavingsEvidence.conversionVerified: 12345,
        SavingsEvidence.conversionEstimated: 3456,
        SavingsEvidence.userConfirmed: 5000,
      });
      expect(totals.byCurrencyAndEvidence['KWD'], {
        SavingsEvidence.conversionVerified: 5001,
        SavingsEvidence.userConfirmed: 12345,
      });
      expect(await repository.history(), hasLength(6));
      for (final currency in ['EGP', 'KWD', 'JPY']) {
        expect(find.text(currency), findsOneWidget);
      }
      expect(find.text('12.345'), findsOneWidget);
      expect(find.text('12,345'), findsOneWidget);
      final before = await savingsSnapshot();
      Navigator.of(tester.element(find.byType(SavingsScreen))).pop();
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Open fixture'));
        await _openingSurface;
      });
      await tester.pumpAndSettle();
      expect(await savingsSnapshot(), before);
      expect(tester.takeException(), isNull);
    });
  }

  for (final couponId in ['unrelated-savings', 'qa-savings-populated-jpy-estimated']) {
    testWidgets('savingsPopulated refuses $couponId before any seed write', (tester) async {
      await SavingsRepository(db).record(const SavingsOutcome.saved(
        amountMinor: 777, currency: 'JPY', evidence: SavingsEvidence.userConfirmed),
        couponId: couponId);
      final before = await savingsSnapshot();
      Object? rejection;
      await tester.pumpWidget(ProviderScope(overrides: [
        appDatabaseProvider.overrideWithValue(db),
      ], child: MaterialApp(home: Consumer(builder: (context, ref, _) =>
        Scaffold(body: TextButton(onPressed: () async {
          try { await openVisualParityExtendedSurface(context, ref, 'savingsPopulated'); }
          catch (error) { rejection = error; }
        }, child: const Text('guard')))))));
      await tester.tap(find.text('guard'));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(rejection, isA<StateError>());
      expect(await savingsSnapshot(), before);
      expect(tester.takeException(), isNull);
    });
  }

  for (final key in ['exactMoneyRemainingKwd', 'exactMoneyRemainingLarge']) {
    for (final language in ['ar', 'en']) {
      testWidgets('$key $language seeds real recurrence and exact remaining display data without native notifications', (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final fonts = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await fonts.load();
        });
        final nativeCalls = <String>[];
        const channel = MethodChannel('dexterous.com/flutter/local_notifications');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
        await open(tester, key, language: language, dark: language == 'ar');
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        final minor = key.endsWith('Kwd') ? 12345 : 9007199254740993;
        final prefix = 'qa-exact-money-remaining-${key.endsWith('Kwd') ? 'kwd' : 'large'}';
        final transactions = DriftTransactionRepository(db);
        final candidates = await transactions.recurringCandidates(accountId: '$prefix-account');
        expect(candidates, hasLength(1));
        expect(candidates.single.name, 'QA exact recurring');
        expect(candidates.single.estimatedAmountMoney, Money(minor + 18, 'KWD'));
        expect(candidates.single.monthsSeen, 3);
        final suggested = (await transactions.getById('$prefix-suggested'))!;
        expect(suggested.rawMerchant, 'QA exact subscription');
        expect(suggested.amountMoney, Money(minor + 13, 'KWD'));
        final bills = DriftBillRepository(db);
        expect((await bills.getById('$prefix-sub'))!.safeManualPaidMoney,
            Money(minor * 2 + 34, 'KWD'));
        final installment = (await bills.getById('$prefix-inst'))!;
        expect(installment.totalPurchaseMoney, Money(minor + 21, 'KWD'));
        expect(installment.safeManualPaidMoney, Money(minor + 20, 'KWD'));
        Future<Map<String, Object>> snapshot() async => {
          for (final table in ['accounts', 'transactions', 'plans',
              'plan_transaction_links', 'subscriptions', 'bill_payments', 'user_settings'])
            table: (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
                .map((row) => row.data).toList(),
        };
        final before = await snapshot();
        Navigator.of(tester.element(find.byType(AccountsScreen))).pop();
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Open fixture'));
          await _openingSurface;
        });
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        expect(await snapshot(), before);
        expect(nativeCalls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final key in ['exactMoneyKwd', 'exactMoneyLarge']) {
    for (final language in ['ar', 'en']) {
      testWidgets('$key $language seeds actual exact memory ledger and preserves repeated-open data', (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final fonts = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await fonts.load();
        });
        final nativeCalls = <String>[];
        const channel = MethodChannel('dexterous.com/flutter/local_notifications');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
        await open(tester, key, language: language, dark: language == 'ar');
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        final prefix = key == 'exactMoneyKwd' ? 'qa-exact-money-kwd' : 'qa-exact-money-large';
        final minor = key == 'exactMoneyKwd' ? 12345 : 9007199254740993;
        Money money(int delta) => Money(minor + delta, 'KWD');
        final transactions = DriftTransactionRepository(db);
        expect((await transactions.getById('$prefix-unassigned'))!.accountId, isNull);
        expect((await transactions.getById('$prefix-picker'))!.accountId, isNull);
        expect((await transactions.getById('$prefix-linked'))!.accountId, '$prefix-account');
        expect((await transactions.getById('$prefix-unassigned'))!.amountMoney, money(6));
        final plans = DriftPlanRepository(db);
        final plan = (await plans.getById('$prefix-plan-active'))!;
        expect(plan.budgetAmountMoney, money(4));
        expect(await plans.spentForPlan(plan), money(3));
        expect((await plans.getById('$prefix-plan-closed'))!.status, PlanStatus.closed);
        final bills = DriftBillRepository(db);
        final subscription = (await bills.getById('$prefix-sub'))!;
        expect(subscription.amountMoney, money(0));
        expect(subscription.safeManualPaidMoney, money(1));
        final installment = (await bills.getById('$prefix-inst'))!;
        expect(installment.amountMoney, money(2));
        expect(installment.remainingInstallments, 2);
        expect((await bills.getPayments(subscription.id)).single.amountMoney, money(7));
        expect(subscription.reminderOn, isFalse);
        expect(installment.reminderOn, isFalse);
        expect(find.byType(AccountsScreen), findsOneWidget);
        final container = ProviderScope.containerOf(tester.element(find.byType(AccountsScreen)));
        expect(container.read(activeAccountIdProvider), '$prefix-account');
        expect(await container.read(baseCurrencyProvider.future), 'KWD');
        expect((await DriftUserSettingsRepository(db).getSettings()).currency, 'KWD');
        final grouping = await container.read(accountCardGroupsProvider.future);
        expect(grouping.unassigned.single.totalOut, money(6));
        expect(grouping.unassigned.single.currency, 'KWD');
        // A local edit between repeated opens must remain byte-for-byte intact.
        final accounts = DriftAccountRepository(db);
        final account = (await accounts.getById('$prefix-account'))!;
        await accounts.update(account.copyWith(name: 'QA preserved edited name'));
        Future<Map<String, Object>> snapshot() async => {
          for (final table in ['accounts', 'transactions', 'plans',
              'plan_transaction_links', 'subscriptions', 'bill_payments', 'user_settings'])
            table: (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
                .map((row) => row.data).toList(),
        };
        final before = await snapshot();
        Navigator.of(tester.element(find.byType(AccountsScreen))).pop();
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text('Open fixture'));
          await _openingSurface;
        });
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        expect(await snapshot(), before);
        expect((await accounts.getById('$prefix-account'))!.name, 'QA preserved edited name');
        expect(nativeCalls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('$key refuses an existing unrelated account without overwriting data', (tester) async {
      final now = DateTime.now().toUtc();
      await DriftAccountRepository(db).create(AccountEntity(id: 'unrelated',
        name: 'Keep existing', currency: 'EGP', type: AccountType.bank,
        isDefault: true, sortOrder: 0, createdAt: now, updatedAt: now));
      final before = (await db.customSelect('SELECT * FROM accounts').get()).map((row) => row.data).toList();
      Object? failure;
      await tester.pumpWidget(ProviderScope(overrides: [appDatabaseProvider.overrideWithValue(db)],
        child: MaterialApp(home: Consumer(builder: (context, ref, _) => Scaffold(body: TextButton(
          onPressed: () async {
            try { await openVisualParityExtendedSurface(context, ref, key); }
            catch (error) { failure = error; }
          }, child: const Text('guard')))))));
      await tester.tap(find.text('guard'));
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      expect(failure, isA<StateError>());
      expect(failure.toString(), contains('exact_money_fixture_requires_empty_ledger'));
      expect((await db.customSelect('SELECT * FROM accounts').get()).map((row) => row.data).toList(), before);
      for (final table in ['transactions', 'plans', 'subscriptions', 'bill_payments', 'plan_transaction_links']) {
        expect((await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle()).read<int>('n'), 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('goalCompletion $language dark$dark contributes through real controls without native notification calls', (tester) async {
        tester.view.physicalSize = const Size(375, 812);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.runAsync(() async {
          final fonts = FontLoader('Vazirmatn');
          for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
            fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
          }
          await fonts.load();
        });
        final now = DateTime.utc(2026, 10, 29);
        final settingsRepo = DriftUserSettingsRepository(db);
        final settings = await settingsRepo.getSettings();
        final preferences = NotificationPreferences.fromJson(
            jsonDecode(settings.notificationsJson) as Map<String, dynamic>);
        await settingsRepo.saveSettings(settings.copyWith(currency: 'EGP'));
        await DriftAccountRepository(db).create(AccountEntity(
          id: 'p-acc-1', name: 'QA unchanged account', currency: 'EGP',
          type: AccountType.bank, isDefault: true, sortOrder: 0,
          initialBalanceMoney: Money(1234567, 'EGP'),
          currentBalanceMoney: Money(1234567, 'EGP'),
          createdAt: now, updatedAt: now,
        ));
        final goalRepo = DriftGoalRepository(db);
        for (final index in [0, 1]) {
          await goalRepo.save(GoalEntity(
            id: 'p-goal-$index', name: index == 0 ? 'QA completion goal' : 'QA active goal',
            currency: 'EGP', targetMoney: Money(2500000, 'EGP'),
            savedMoney: Money(index == 0 ? 1550000 : 100000, 'EGP'),
            lastNotifiedSavedMoney: Money.zero('EGP'), vaultSkin: 'classic',
            status: 'active', accountId: 'p-acc-1', createdAt: now,
          ));
        }
        Future<List<Map<String, Object?>>> rows(String sql) async =>
            (await db.customSelect(sql).get()).map((row) => row.data).toList();
        final goalsBefore = await rows('SELECT * FROM goals ORDER BY id');
        final accountsBefore = await rows('SELECT * FROM accounts ORDER BY id');
        final nativeCalls = <String>[];
        const channel = MethodChannel('dexterous.com/flutter/local_notifications');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
          nativeCalls.add(call.method);
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null));
        await open(tester, 'goalCompletion', language: language, dark: dark);
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        // Opening this fixture changes only the local milestone preference.
        expect(await rows('SELECT * FROM goals ORDER BY id'), goalsBefore);
        expect(await rows('SELECT * FROM accounts ORDER BY id'), accountsBefore);
        expect(await goalRepo.getContributions('p-goal-0'), isEmpty);
        final prepared = await settingsRepo.getSettings();
        expect(NotificationPreferences.fromJson(jsonDecode(prepared.notificationsJson)
            as Map<String, dynamic>).toJson(), preferences.copyWith(goalMilestone: false).toJson());
        final l10n = AppL10n.of(tester.element(find.text('QA completion goal').first));
        final add = find.widgetWithText(FilledButton, l10n.gdAddToGoal);
        await tester.ensureVisible(add);
        await tester.pumpAndSettle();
        await tester.tap(add);
        await tester.pumpAndSettle();
        expect(find.text(l10n.gdAddContribution), findsOneWidget);
        await tester.enterText(find.byType(TextField).first,
            language == 'ar' ? '٩٥٠٠' : '9500');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        final save = find.widgetWithText(FilledButton, l10n.gdSaveContribution);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 200)));
        await tester.pumpAndSettle();
        // The public form invoked the real canonical repository/use case.
        final contributions = await goalRepo.getContributions('p-goal-0');
        expect(contributions, hasLength(1));
        expect(contributions.single.amountMoney, Money(950000, 'EGP'));
        final updated = (await goalRepo.getById('p-goal-0'))!;
        expect(updated.savedMoney, Money(2500000, 'EGP'));
        expect(updated.targetMoney, Money(2500000, 'EGP'));
        expect(updated.status, 'active', reason: 'Completion is computed; the fixture must not invent a status mutation.');
        expect(await rows("SELECT * FROM goals WHERE id != 'p-goal-0' ORDER BY id"),
            goalsBefore.where((row) => row['id'] != 'p-goal-0').toList());
        expect(await rows('SELECT * FROM accounts ORDER BY id'), accountsBefore);
        expect(nativeCalls, isEmpty);
        expect(find.text(l10n.gdSaveContribution), findsNothing);
        await tester.scrollUntilVisible(find.text(l10n.bdgGoalDone), -150,
            scrollable: find.byType(Scrollable).last);
        expect(find.text(l10n.bdgGoalDone), findsOneWidget);
        Navigator.of(tester.element(find.text(l10n.bdgGoalDone))).pop();
        await tester.pumpAndSettle();
        final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
        navigator.push(MaterialPageRoute<void>(builder: (_) => const GoalsScreen()));
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        expect(find.text('QA completion goal'), findsOneWidget);
        expect(find.text('QA active goal'), findsOneWidget);
        expect(find.text(l10n.bdgGoalDone), findsOneWidget);
        expect(await goalRepo.getContributions('p-goal-0'), hasLength(1));
        expect(await rows('SELECT * FROM accounts ORDER BY id'), accountsBefore);
        expect(nativeCalls, isEmpty);
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final surface in ['couponExpired', 'couponInvalidUrl']) {
    testWidgets('$surface reaches actual error guard without external effects', (tester) async {
      final launcher = _NoLaunch();
      final oldLauncher = UrlLauncherPlatform.instance;
      UrlLauncherPlatform.instance = launcher;
      addTearDown(() => UrlLauncherPlatform.instance = oldLauncher);
      final preparations = visualParityExtendedEvents()['couponGuardUnexpectedPreparation'] ?? 0;
      var clipboardWrites = 0;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') clipboardWrites++;
          return null;
        });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      final rowsBefore = (await db.customSelect(
          'SELECT * FROM user_settings').getSingle()).data;
      await open(tester, surface);
      await tester.pumpAndSettle();
      final sheet = find.byType(CouponDetailsSheet);
      expect(sheet, findsOneWidget);
      final l10n = AppL10n.of(tester.element(sheet));
      final container = ProviderScope.containerOf(tester.element(sheet));
      expect(container.read(affiliateTrackingEnabledProvider), isFalse);
      await tester.tap(find.widgetWithText(FilledButton,
          surface == 'couponExpired' ? l10n.couponsCopyCode : l10n.couponsUseOffer));
      await tester.pumpAndSettle();
      try {
        // No-effect assertions precede presentation assertions.
        expect(visualParityExtendedEvents()['couponGuardUnexpectedPreparation'] ?? 0, preparations);
        expect(launcher.calls, 0);
        expect(clipboardWrites, 0);
        expect((await db.customSelect('SELECT * FROM user_settings')
            .getSingle()).data, rowsBefore);
        expect(find.text(surface == 'couponExpired'
            ? l10n.couponsOfferUnavailable : l10n.couponsOpenFailed), findsOneWidget);
        expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
        expect(find.byIcon(AppLucideIcons.checkCircle), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpAndSettle();
      }
    });
  }

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
  testWidgets('planEmptyLinks $language dark$dark uses real empty ledger, public plan controls and no link mutation', (tester) async {
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      final fonts = FontLoader('Vazirmatn');
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
      }
      await fonts.load();
    });
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM transactions')
        .getSingle()).read<int>('n'), 0);
    await open(tester, 'planEmptyLinks', language: language, dark: dark);
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.byType(PlansScreen), findsOneWidget);
    const title = 'Empty-link fixture plan';
    final plan = (await DriftPlanRepository(db).getById('qa-plan-empty-links'))!;
    expect(plan.budgetAmountMoney, Money(100000, 'EGP'));
    expect(plan.accountIds, hasLength(1));
    final before = (await db.customSelect('SELECT * FROM plans ORDER BY id').get())
        .map((r) => r.data).toList();
    await tester.tap(find.text(title));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(tester.element(find.byType(PlansScreen)));
    final link = find.widgetWithText(FilledButton, l10n.plLinkTransaction);
    await tester.ensureVisible(link);
    await tester.pumpAndSettle();
    await tester.tap(link);
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(find.text(l10n.plLinkToPlan), findsOneWidget);
    expect(find.text(l10n.plNoSuitableTx), findsOneWidget);
    expect(find.text(l10n.plAllLinkedAlready), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is QirshIllustration &&
        w.name == 'emptyTx' && w.width == 160 && w.height == 120), findsOneWidget);
    expect(find.byType(TextField), findsNothing,
        reason: 'The actual Plan link picker does not have a search control.');
    expect(find.byType(AppEmptyState), findsWidgets);
    expect((await db.customSelect('SELECT * FROM plans ORDER BY id').get())
        .map((r) => r.data).toList(), before);
    for (final table in ['transactions', 'plan_transaction_links']) {
      expect((await db.customSelect('SELECT COUNT(*) AS n FROM $table')
          .getSingle()).read<int>('n'), 0);
    }
    expect(tester.takeException(), isNull);
  });
    }
  }

  testWidgets('planEmptyLinks rejects a nonempty ledger before seeding account or plan', (tester) async {
    final now = DateTime.now();
    await DriftTransactionRepository(db).saveTransaction(
      transaction: TransactionEntity(id: 'synthetic-nonempty',
        amountMoney: Money(100, 'EGP'), currency: 'EGP',
        type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
        occurredAt: now, rawMessage: 'Synthetic guard test', rawMerchant: 'Demo',
        categoryId: 'groceries', parseConfidence: 1,
        status: TransactionStatus.confirmed, createdAt: now, updatedAt: now),
      categoryKey: 'groceries',
    );
    Object? error;
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ], child: MaterialApp(theme: AppTheme.light, home: Consumer(
      builder: (context, ref, _) => Scaffold(body: TextButton(
        onPressed: () async {
          try { await openVisualParityExtendedSurface(context, ref, 'planEmptyLinks'); }
          catch (e) { error = e; }
        }, child: const Text('guard'))),
    ))));
    await tester.tap(find.text('guard'));
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    expect(error, isA<StateError>());
    expect(error.toString(), contains('plan_empty_links_requires_empty_ledger'));
    for (final table in ['accounts', 'plans', 'plan_transaction_links']) {
      expect((await db.customSelect('SELECT COUNT(*) AS n FROM $table')
          .getSingle()).read<int>('n'), 0);
    }
    expect((await db.customSelect('SELECT COUNT(*) AS n FROM transactions')
        .getSingle()).read<int>('n'), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('deleteAccountIdle blocks flow construction and retains actual idle header', (tester) async {
    final before = visualParityExtendedEvents()['deleteAccountIdleFlowBlocked'] ?? 0;
    await open(tester, 'deleteAccountIdle');
    await tester.pumpAndSettle();
    expect(find.byType(DeleteAccountScreen), findsOneWidget);
    final l10n = AppL10n.of(tester.element(find.byType(DeleteAccountScreen)));
    expect(find.descendant(of: find.byType(AppHeader),
        matching: find.text(l10n.deleteAccountTitle)), findsOneWidget);
    expect(visualParityExtendedEvents()['deleteAccountIdleFlowBlocked'], before + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('syncDiagnosticsError Retry repeats only its synthetic read', (tester) async {
    final before = visualParityExtendedEvents()['syncDiagnosticsReadError'] ?? 0;
    await open(tester, 'syncDiagnosticsError');
    await tester.pumpAndSettle();
    expect(find.byType(SyncDiagnosticsScreen), findsOneWidget);
    expect(find.text('Sync diagnostics'), findsOneWidget);
    final l10n = AppL10n.of(tester.element(find.byType(SyncDiagnosticsScreen)));
    expect(find.text(l10n.txnError), findsOneWidget);
    expect(visualParityExtendedEvents()['syncDiagnosticsReadError'], before + 1);
    await tester.tap(find.text(l10n.startRetry));
    await tester.pumpAndSettle();
    expect(visualParityExtendedEvents()['syncDiagnosticsReadError'], before + 2);
    expect(find.byKey(const ValueKey('run-sync-now')), findsNothing);
    expect(find.byKey(const ValueKey('copy-diagnostics')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final surface in ['missingTransactionSheet', 'missingGoalSheet']) {
    testWidgets('$surface opens the actual missing-record sheet over memory data without writes', (tester) async {
      await open(tester, surface);
      await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pumpAndSettle();
      final state = find.byType(AppMissingRecordState);
      expect(state, findsOneWidget);
      final l10n = AppL10n.of(tester.element(state));
      expect(find.text(surface == 'missingTransactionSheet' ? l10n.txdNotFound : l10n.gdNotFound), findsOneWidget);
      for (final table in ['transactions', 'goals']) {
        expect((await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle()).read<int>('n'), 0);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('missingPlanDetails preserves the saved plan while only its selected detail read returns null', (tester) async {
    final repository = DriftPlanRepository(db);
    final plan = PlanEntity(id: 'p-plan-active', name: 'Synthetic saved plan',
      budgetAmountMoney: Money.parse('1000', 'EGP'), currency: 'EGP',
      startDate: DateTime(2026, 10, 1), endDate: DateTime(2027, 1, 1),
      accountIds: const [], cardLast4s: const [], status: PlanStatus.active,
      createdAt: DateTime(2026, 10, 1));
    await repository.save(plan);
    await open(tester, 'missingPlanDetails');
    await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();
    await tester.tap(find.text(plan.name));
    await tester.pumpAndSettle();
    final state = find.byType(AppMissingRecordState);
    expect(state, findsOneWidget);
    expect(find.text(AppL10n.of(tester.element(state)).plNotFound), findsOneWidget);
    final stored = (await repository.getById(plan.id))!;
    expect(stored.name, plan.name);
    expect(stored.budgetAmountMoney, plan.budgetAmountMoney);
    expect(stored.status, plan.status);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup Retry is only a recorded presentation callback', (tester) async {
    final before = visualParityExtendedEvents()['startupRetryCallback'] ?? 0;
    await open(tester, 'startupError');
    final context = tester.element(find.byType(FilledButton).last);
    await tester.tap(find.text(AppL10n.of(context).startRetry));
    await tester.pump();
    expect(visualParityExtendedEvents()['startupRetryCallback'], before + 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending empty state scopes its claim to the current view', (tester) async {
    await open(tester, 'activityReviewed');
    await tester.runAsync(() async =>
      Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final context = tester.element(find.byType(TransactionsScreen));
    expect(ProviderScope.containerOf(context).read(transactionsPendingFilterProvider), isTrue);
    expect(find.text('No pending transactions in this view'), findsOneWidget);
    expect(find.text('Try another period or change the filters to review other transactions.'), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is QirshIllustration &&
      widget.name == 'reviewDone'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('management Cancel dismisses the real disclosure without a grant', (tester) async {
    final before = await db.customSelect(
      'SELECT cloud_consent_state, ai_consent_state FROM user_settings').getSingle();
    await open(tester, 'consentManagement');
    expect(find.byKey(const Key('consentManageCancel')), findsOneWidget);
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('consentManageCancel')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('consentManageCancel')));
    await tester.pumpAndSettle();
    final after = await db.customSelect(
      'SELECT cloud_consent_state, ai_consent_state FROM user_settings').getSingle();
    expect(after.data, before.data);
    expect(tester.takeException(), isNull);
  });

  testWidgets('incomplete-notice failure and success exercise only injected callbacks', (tester) async {
    await open(tester, 'signoutIncompleteFailure');
    await tester.tap(find.byKey(const Key('sign_out_incomplete_retry')));
    await tester.pump();
    expect(tester.widget<TextButton>(find.byKey(
      const Key('sign_out_incomplete_retry'))).onPressed, isNull);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    final context = tester.element(find.byKey(const Key('sign_out_incomplete_notice')));
    expect(find.text(AppL10n.of(context).signOutCleanupStillIncomplete), findsOneWidget);
    await tester.tap(find.byKey(const Key('sign_out_incomplete_close')));
    await tester.pumpAndSettle();
    await open(tester, 'signoutIncompleteSuccess');
    await tester.tap(find.byKey(const Key('sign_out_incomplete_retry')));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sign_out_incomplete_notice')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('force-update content renders locally without a real gate or URL launch', (tester) async {
    await open(tester, 'forceUpdate');
    await tester.pumpAndSettle();
    expect(find.text('A test update is available'), findsOneWidget);
    expect(find.text('View update'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
