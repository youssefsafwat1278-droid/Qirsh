// Shared harness for the round-2 accessibility scans (UX-05 tap targets,
// UX-09 text scale): pumps a primary screen over an in-memory database with
// the real theme, l10n and bundled font, and walks what it rendered.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/dashboard/dashboard_screen.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'primary-screen-scan';
  @override
  Future<String?> readStoredKey() async => 'primary-screen-scan';
}

/// Set by a probe to print each error's full report (creator chain).
bool debugPrintScanErrors = false;

void Function()? _restoreErrors;

/// Gives FlutterError.onError back to the test binding. Call it before any
/// `expect`: flutter_test requires the handler restored before a failure is
/// reported (otherwise the failing test hangs at shutdown).
void stopCollectingErrors() {
  _restoreErrors?.call();
  _restoreErrors = null;
}

/// A primary screen and how to open it.
class PrimaryScreen {
  const PrimaryScreen(this.name, this.build,
      {this.budgetsTab, this.overrides = const []});
  final String name;
  final Widget Function() build;
  final int? budgetsTab;
  final List<Override> overrides;
}

final _today = DateUtils.dateOnly(DateTime.now());

BudgetProgressEntry _budget(String id, int spent, int limit, BudgetHealth health) {
  final budget = BudgetEntity(
      id: id,
      categoryId: 'groceries',
      currency: 'SAR',
      amountMoney: Money(limit, 'SAR'),
      lastNotifiedSpentMoney: Money.zero('SAR'),
      period: BudgetPeriod.monthly,
      startDate: _today,
      isActive: true,
      lastNotifiedPeriodStart: _today);
  return BudgetProgressEntry(
      budget: budget,
      spent: Money(spent, 'SAR'),
      remaining: Money(limit - spent, 'SAR'),
      ratio: spent / limit,
      health: health,
      periodStart: _today.subtract(const Duration(days: 20)),
      periodEnd: _today.add(const Duration(days: 8)));
}

final _budgetsView = BudgetsView(
    snapshot: BudgetProgressSnapshot(entries: [
      _budget('over', 12000, 10000, BudgetHealth.over),
      _budget('near', 9000, 10000, BudgetHealth.warning),
      _budget('safe', 2345, 20000, BudgetHealth.safe),
    ]),
    historyEntries: const [],
    catalog: CategoryCatalog(const [
      CategoryEntity(
          id: 'groceries',
          key: 'groceries',
          nameAr: 'بقالة',
          icon: 'shopping-cart',
          color: '#31D0AA',
          isIncome: false,
          sort: 1)
    ]),
    accounts: const [],
    goals: const []);

BillEntity _bill(String id, BillType type) => BillEntity(
    id: id,
    name: id,
    amountMoney: Money(4500, 'SAR'),
    currency: 'SAR',
    type: type,
    frequency: BillFrequency.monthly,
    status: BillStatus.active,
    nextDueDate: DateTime.now().add(const Duration(days: 5)),
    reminderOn: true,
    isConfirmed: true,
    createdAt: DateTime(2026, 1, 15));

final primaryScreens = <PrimaryScreen>[
  PrimaryScreen('Home', () => const DashboardScreen()),
  PrimaryScreen('Transactions', () => const TransactionsScreen()),
  PrimaryScreen('Budgets', () => const BudgetsScreen(),
      budgetsTab: 0,
      overrides: [budgetsViewProvider.overrideWith((ref) async => _budgetsView)]),
  PrimaryScreen('Goals', () => const BudgetsScreen(), budgetsTab: 2),
  PrimaryScreen('Budget history', () => const BudgetsScreen(), budgetsTab: 1),
  PrimaryScreen('Reports', () => const ReportsScreen()),
  PrimaryScreen('Bills', () => const SubscriptionsScreen(), overrides: [
    savedBillsProvider.overrideWith((ref) async => [
          _bill('Streaming', BillType.subscription),
          _bill('Phone plan', BillType.installment),
        ]),
    subscriptionsProvider.overrideWith((ref) async => const []),
  ]),
  PrimaryScreen('Budget form', () => const BudgetFormScreen()),
  PrimaryScreen('Settings', () => const SettingsScreen()),
  PrimaryScreen('Settings account',
      () => const SettingsScreen(page: SettingsPage.account)),
];

Future<void> loadAppFont(WidgetTester tester) => tester.runAsync(() async {
      final loader = FontLoader('Vazirmatn');
      for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
        loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
      }
      await loader.load();
    });

/// Pumps [screen] at [size] (logical, DPR 1) and [textScale]. Returns the
/// FlutterErrors reported while building and settling (overflows included).
Future<List<String>> pumpPrimaryScreen(WidgetTester tester, PrimaryScreen screen,
    {required Size size,
    required String language,
    double textScale = 1,
    bool dark = false}) async {
  // A fresh ProviderScope per screen (a scope's override list is fixed).
  await tester.pumpWidget(const SizedBox.shrink());
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 20, bottom: 34);
  addTearDown(tester.view.reset);
  await loadAppFont(tester);
  final db = (await tester.runAsync(() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: language)))!;
  await tester.runAsync(() async {
    final repo = DriftTransactionRepository(db);
    var n = 0;
    for (final (type, amount, status, merchant) in [
      (TransactionTypeEntity.income, 1240000, TransactionStatus.confirmed, null),
      (TransactionTypeEntity.payment, 8730, TransactionStatus.confirmed, 'Corner Grocery'),
      (TransactionTypeEntity.payment, 2150, TransactionStatus.pending, 'Coffee Kiosk'),
    ]) {
      final at = DateTime.now().subtract(Duration(hours: 3 + n));
      await repo.saveTransaction(
          transaction: TransactionEntity(
            id: 'scan-${n++}',
            amountMoney: Money(amount, 'SAR'),
            currency: 'SAR',
            type: type,
            source: TransactionSourceEntity.bank,
            occurredAt: at,
            rawMessage: 'synthetic',
            rawMerchant: merchant,
            parseConfidence: 1,
            status: status,
            createdAt: at,
            updatedAt: at,
          ),
          categoryKey: type == TransactionTypeEntity.income ? 'income' : 'groceries');
    }
  });
  final errors = <String>[];
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    errors.add(details.exceptionAsString().split('\n').first);
    if (debugPrintScanErrors) debugPrint(details.toString());
  };
  _restoreErrors = () => FlutterError.onError = previous;
  addTearDown(() async {
    stopCollectingErrors();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
        planningCutoverCoordinatorProvider.overrideWithValue(
            const FixedPlanningCutoverCoordinator(
                PlanningCutoverState.canonical)),
        if (screen.budgetsTab != null)
          budgetsPageTabProvider.overrideWith((ref) => screen.budgetsTab!),
        notificationPreferencesProvider
            .overrideWith((ref) async => const NotificationPreferences()),
        captureHealthStatusProvider.overrideWith((ref) async =>
            CaptureHealthStatus(lastCaptureAt: null, now: DateTime(2026, 7, 18))),
        supportedCountriesProvider.overrideWith((ref) async => const []),
        activeCurrenciesProvider.overrideWith((ref) async => const []),
        // Seeded-off product flags (the flag service is not initialised here).
        couponsEnabledProvider.overrideWithValue(false),
        merchantOffersEnabledProvider.overrideWithValue(false),
        ...screen.overrides,
        for (final placement in AdPlacement.values)
          bannerEligibilityProvider(placement).overrideWith((ref) async => false),
      ],
      child: MaterialApp(
          theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(textScale)),
              child: child!),
          home: screen.build())));
  for (var i = 0; i < 4; i++) {
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 400));
  }
  await tester.pump(const Duration(seconds: 2));
  final pending = tester.takeException();
  if (pending != null) errors.add('$pending'.split('\n').first);
  return errors;
}

/// A tappable semantics node and its on-screen size.
class TapTarget {
  TapTarget(this.label, this.size, this.rect);
  final String label;
  final Size size;
  final Rect rect;
  @override
  String toString() =>
      '"$label" ${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}'
      ' at ${rect.topLeft.dx.toStringAsFixed(0)},${rect.topLeft.dy.toStringAsFixed(0)}';
}

/// Every tappable node (tap or long-press action) on screen, with the skip
/// rules of Flutter's `iOSTapTargetGuideline` (merged, hidden, link and
/// action-less nodes, and nodes touching the screen edge), except that a
/// scrollable only hides nodes touching its edges ALONG its scroll axis: the
/// guideline also skips every chip in a horizontal chip row, because those
/// chips touch the row's top and bottom, which is how undersized filter chips
/// went unreported.
List<TapTarget> tapTargets(WidgetTester tester) {
  final out = <TapTarget>[];
  for (final view in tester.binding.renderViews) {
    final viewRect = Offset.zero & view.flutterView.physicalSize;
    void walk(SemanticsNode node) {
      node.visitChildren((child) {
        walk(child);
        return true;
      });
      if (node.isMergedIntoParent) return;
      final data = node.getSemanticsData();
      if (data.flagsCollection.isHidden || data.flagsCollection.isLink) return;
      if (!data.hasAction(SemanticsAction.tap) &&
          !data.hasAction(SemanticsAction.longPress)) {
        return;
      }
      var bounds = node.rect;
      SemanticsNode? current = node;
      while (current != null) {
        final transform = current.transform;
        if (transform != null) {
          bounds = MatrixUtils.transformRect(transform, bounds);
        }
        if (current.flagsCollection.hasImplicitScrolling &&
            _clippedByScroll(bounds, current)) {
          return;
        }
        current = current.parent;
      }
      if (_atBoundary(bounds, viewRect)) return;
      final label = [data.label, data.tooltip, data.value]
          .where((s) => s.isNotEmpty)
          .join(' / ')
          .replaceAll('\n', ' ');
      out.add(TapTarget(label, bounds.size, bounds));
    }

    walk(view.owner!.semanticsOwner!.rootSemanticsNode!);
  }
  return out;
}

bool _clippedByScroll(Rect child, SemanticsNode scrollable) {
  final data = scrollable.getSemanticsData();
  final parent = scrollable.rect;
  const gap = 0.001;
  final horizontal = data.hasAction(SemanticsAction.scrollLeft) ||
      data.hasAction(SemanticsAction.scrollRight);
  final vertical = data.hasAction(SemanticsAction.scrollUp) ||
      data.hasAction(SemanticsAction.scrollDown);
  if (horizontal &&
      (child.left - parent.left <= gap || parent.right - child.right <= gap)) {
    return true;
  }
  if (vertical &&
      (child.top - parent.top <= gap || parent.bottom - child.bottom <= gap)) {
    return true;
  }
  return false;
}

bool _atBoundary(Rect child, Rect parent) =>
    !(child.left - parent.left > 0.001 &&
        parent.right - child.right > 0.001 &&
        child.top - parent.top > 0.001 &&
        parent.bottom - child.bottom > 0.001);

/// Scrolls the first vertical scrollable down in steps, calling [visit] on
/// each screenful (the scan only sees what is laid out on screen).
Future<void> eachScreenful(
    WidgetTester tester, Future<void> Function() visit,
    {int maxSteps = 8}) async {
  await visit();
  final scrollables = find.byWidgetPredicate((w) =>
      w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical);
  if (scrollables.evaluate().isEmpty) return;
  for (var i = 0; i < maxSteps; i++) {
    final state = tester.state<ScrollableState>(scrollables.first);
    final position = state.position;
    if (position.pixels >= position.maxScrollExtent - 1) return;
    position.jumpTo((position.pixels + position.viewportDimension * 0.6)
        .clamp(0, position.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 400));
    await visit();
  }
}
