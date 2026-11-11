import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/reports/reports_providers.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/financial_state_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'financial-fixture-memory';
  @override
  Future<String?> readStoredKey() async => 'financial-fixture-memory';
}

Future<bool>? _opening;
class _Launch extends ConsumerWidget {
  const _Launch(this.surface);
  final String surface;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(body: TextButton(
    onPressed: () {
      _opening = openVisualParityFinancialStateSurface(context, ref, surface);
      // The test awaits the original result below. Attach error handling before
      // the widget tap yields so intentional admission failures are not unhandled.
      _opening!.ignore();
    },
    child: const Text('Open fixture')));
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {for (final table in tables)
    table.read<String>('name'): (await db.customSelect(
      'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid').get())
        .map((row) => row.data).toList()};
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 120)));
  await tester.pumpAndSettle();
}

Finder get _vertical => find.byWidgetPredicate((widget) => widget is Scrollable &&
    (widget.axisDirection == AxisDirection.down || widget.axisDirection == AxisDirection.up));

Future<void> _host(WidgetTester tester, AppDatabase db, String key,
    {String language = 'en', bool dark = false}) async {
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
  await tester.pumpWidget(ProviderScope(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    localeProvider.overrideWithValue(Locale(language)),
    for (final placement in AdPlacement.values)
      bannerEligibilityProvider(placement).overrideWith((ref) async => false),
  ], child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: _Launch(key))));
  await _settle(tester);
}

Future<void> _open(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Open fixture'));
    expect(await _opening, isTrue);
  });
  await _settle(tester);
}

void main() {
  late AppDatabase db;
  final nativeCalls = <String>[];
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _Keys(), initialLanguage: 'en');
    nativeCalls.clear();
    for (final channel in ['dexterous.com/flutter/local_notifications',
        'com.youssefsafwat.mali/capture', 'plugins.flutter.io/firebase_messaging',
        'plugins.flutter.io/google_mobile_ads']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(channel), (call) async {
        nativeCalls.add('$channel:${call.method}');
        return null;
      });
    }
  });
  tearDown(() async => db.close());

  for (final key in visualParityFinancialStateSurfaceKeys) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        testWidgets('$key derives actual financial presentation and repeats without SQL writes $language dark$dark', (tester) async {
          await _host(tester, db, key, language: language, dark: dark);
          await _open(tester);
          final context = tester.element(find.byType(key == 'reportsRefundNet'
              ? ReportsScreen : BudgetsScreen));
          final container = ProviderScope.containerOf(context);
          final l10n = AppL10n.of(context);
          final afterSeed = await _snapshot(db);
          if (key == 'reportsRefundNet') {
            final bundle = container.read(reportsProvider).requireValue;
            expect(bundle.monthly.total, Money(8000, 'EGP'));
            expect(bundle.monthly.refunds, Money(2000, 'EGP'));
            expect(bundle.monthly.grossExpense, Money(10000, 'EGP'));
            expect(bundle.monthly.prevTotal, Money(7000, 'EGP'));
            expect(bundle.monthly.topCategories.single.total, Money(8000, 'EGP'));
            expect(bundle.monthly.topCategories.single.refunds, Money(2000, 'EGP'));
            expect(bundle.monthly.topMerchants.single.total, Money(8000, 'EGP'));
            expect(bundle.monthly.topMerchants.single.refunds, Money(2000, 'EGP'));
            expect(find.text(l10n.rptRefunds), findsOneWidget);
            // v3: the net is the summary card's headline, labelled as net.
            expect(find.text(l10n.rptNetPeriodSpend), findsOneWidget);
            expect(find.text(l10n.rptTotalExpenses), findsOneWidget);
            final range = container.read(transactionsDateRangeProvider);
            expect(await DriftTransactionRepository(db).incomeTotalBetween(
              from: range.from, to: DateTime.now(), currency: 'EGP',
              accountId: 'qa-financial-reports-account'), Money(25000, 'EGP'));
          } else {
            final view = container.read(budgetsViewProvider).requireValue;
            expect(view.snapshot.entries, hasLength(3));
            final current = {for (final entry in view.snapshot.entries)
              view.catalog.byId(entry.budget.categoryId)!.key: entry};
            for (final item in [('groceries', 5000, BudgetHealth.safe),
                ('cafes', 8500, BudgetHealth.warning), ('restaurants', 12000, BudgetHealth.over)]) {
              expect(current[item.$1]!.spent, Money(item.$2, 'EGP'));
              expect(current[item.$1]!.remaining, Money(10000 - item.$2, 'EGP'));
              expect(current[item.$1]!.health, item.$3);
            }
            expect(view.historyEntries, hasLength(6));
            expect(view.historyEntries.where((entry) => entry.isCurrent), hasLength(3));
            final finals = view.historyEntries.where((entry) => !entry.isCurrent).toList();
            expect(finals, hasLength(3));
            for (final item in [('groceries', 6000), ('cafes', 11000), ('restaurants', 4000)]) {
              final entry = finals.singleWhere((entry) =>
                  view.catalog.byId(entry.budget.categoryId)!.key == item.$1);
              expect(entry.progress.spent, Money(item.$2, 'EGP'));
              expect(entry.progress.periodEnd.isBefore(DateTime.now()), isTrue);
              expect(entry.transactions.single.amountMoney, Money(item.$2, 'EGP'));
              expect(entry.transactions.single.id, contains('previous-'));
            }
            // Exercise the actual history control, then its actual past-period
            // row. "Final" is the production period-date derivation, not a
            // server accounting snapshot or an irreversible close command.
            await tester.tap(find.text(l10n.bdgTabHistory));
            await _settle(tester);
            expect(container.read(budgetsPageTabProvider), 1);
            final subtitle = l10n.bdgPeriodSubtitle(l10n.bdgFilterMonthly,
                Formatters.monthYear(finals.first.progress.periodStart, context));
            await tester.scrollUntilVisible(find.text(subtitle), 140,
                scrollable: _vertical.last);
            await tester.pumpAndSettle();
            await tester.tap(find.text(subtitle).first);
            await _settle(tester);
            await tester.scrollUntilVisible(find.text(l10n.bdgRecordFinal), 140,
                scrollable: _vertical.last);
            await tester.pumpAndSettle();
            expect(find.text(l10n.bdgRecordFinal), findsOneWidget);
            Navigator.of(context).pop();
            await _settle(tester);
          }
          expect(await _snapshot(db), afterSeed);
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
          Navigator.of(context).pop();
          await _settle(tester);
          await _open(tester);
          expect(await _snapshot(db), afterSeed,
              reason: 'A repeat may open the actual UI but never overwrite even its own synthetic rows.');
          expect(nativeCalls, isEmpty);
          expect(tester.takeException(), isNull);
        });
      }
    }

    for (final unrelated in ['account', 'orphanTransaction']) {
      testWidgets('$key rejects an existing $unrelated before any write', (tester) async {
        final now = DateTime.now().toUtc();
        if (unrelated == 'account') {
          await DriftAccountRepository(db).create(AccountEntity(id: 'existing',
            name: 'Existing account', currency: 'EGP', type: AccountType.bank,
            isDefault: true, sortOrder: 0, createdAt: now, updatedAt: now));
        } else {
          await DriftTransactionRepository(db).saveTransaction(transaction: TransactionEntity(
            id: 'existing-orphan', amountMoney: Money(123, 'EGP'), currency: 'EGP',
            type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
            occurredAt: now, rawMessage: 'existing', parseConfidence: 1,
            status: TransactionStatus.confirmed, createdAt: now, updatedAt: now),
            categoryKey: 'groceries');
        }
        final before = await _snapshot(db);
        await _host(tester, db, key);
        await tester.runAsync(() async {
          await tester.tap(find.text('Open fixture'));
          await expectLater(_opening, throwsStateError);
        });
        expect(await _snapshot(db), before);
        expect(find.byType(ReportsScreen), findsNothing);
        expect(find.byType(BudgetsScreen), findsNothing);
        expect(nativeCalls, isEmpty);
      });
    }

    testWidgets('$key rejects altered synthetic records without repairing or overwriting them', (tester) async {
      await _host(tester, db, key);
      await _open(tester);
      final screen = find.byType(key == 'reportsRefundNet' ? ReportsScreen : BudgetsScreen);
      Navigator.of(tester.element(screen)).pop();
      await _settle(tester);
      final transactions = DriftTransactionRepository(db);
      final prefix = key == 'reportsRefundNet' ? 'qa-financial-reports' : 'qa-financial-budgets';
      final id = '$prefix-${key == 'reportsRefundNet' ? 'current-payment' : 'current-groceries'}';
      final existing = (await transactions.getById(id))!;
      await transactions.updateTransaction(transactionId: id, amount: Money(54321, 'EGP'),
        currency: 'EGP', type: existing.type, occurredAt: existing.occurredAt,
        rawMerchant: existing.rawMerchant, categoryId: existing.categoryId, note: null,
        accountId: existing.accountId);
      final before = await _snapshot(db);
      await tester.runAsync(() async {
        await tester.tap(find.text('Open fixture'));
        await expectLater(_opening, throwsStateError);
      });
      expect(await _snapshot(db), before);
      expect(nativeCalls, isEmpty);
    });
  }

  testWidgets('financial fixtures refuse a file-backed database before seed', (tester) async {
    await tester.runAsync(() => db.close());
    final directory = Directory.systemTemp.createTempSync('qirsh-financial-guard-');
    final fileDb = await AppDatabase.open(executor: NativeDatabase(File('${directory.path}/guard.sqlite')),
        keyStore: _Keys(), initialLanguage: 'en');
    try {
      final before = await _snapshot(fileDb);
      await _host(tester, fileDb, 'reportsRefundNet');
      await tester.runAsync(() async {
        await tester.tap(find.text('Open fixture'));
        await expectLater(_opening, throwsStateError);
      });
      expect(await _snapshot(fileDb), before);
      expect(nativeCalls, isEmpty);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await fileDb.close();
      directory.deleteSync(recursive: true);
    }
  });
}
