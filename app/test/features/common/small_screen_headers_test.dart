import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'package:drift/native.dart';
import 'package:flutter/rendering.dart';
import 'package:money_companion/core/theme/widgets/section_photo_header.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/budgets/widgets/planning_hero_tabs.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
final _now = DateTime.now();
final _today = DateUtils.dateOnly(_now);
final _catalog = CategoryCatalog(const [
  CategoryEntity(
      id: 'groceries',
      key: 'groceries',
      nameAr: 'بقالة',
      icon: 'shopping-cart',
      color: '#31D0AA',
      isIncome: false,
      sort: 1)
]);

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'small-screen-headers';
  @override
  Future<String?> readStoredKey() async => 'small-screen-headers';
}

BudgetProgressEntry _entry(String id, String currency, int spent, int limit,
    {BudgetHealth health = BudgetHealth.safe, int endDays = 8}) {
  final budget = BudgetEntity(
      id: id,
      categoryId: 'groceries',
      currency: currency,
      amountMoney: Money(limit, currency),
      lastNotifiedSpentMoney: Money.zero(currency),
      period: BudgetPeriod.monthly,
      startDate: _today,
      isActive: true,
      lastNotifiedPeriodStart: _today);
  return BudgetProgressEntry(
      budget: budget,
      spent: Money(spent, currency),
      remaining: Money(limit - spent, currency),
      ratio: spent / limit,
      health: health,
      periodStart: _today.subtract(const Duration(days: 20)),
      periodEnd: _today.add(Duration(days: endDays)));
}

const _sizes = [Size(320, 568), Size(375, 667)];

Future<void> _pump(WidgetTester tester, Widget child, Size size,
    {required String language, List<Override> overrides = const []}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 20);
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
  });
  await tester.pumpWidget(UncontrolledProviderScope(
      container: ProviderContainer(overrides: overrides),
      child: MaterialApp(
          theme: AppTheme.light,
          locale: Locale(language),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          // The app's maximum text scale (`app.dart` clamps to 1.25x).
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.25)),
              child: child!),
          home: child)));
  await tester.runAsync(
      () async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

void _fullText(WidgetTester tester, Finder text) {
  expect(text, findsWidgets);
  for (final element in text.evaluate()) {
    final paragraph = element.renderObject! as RenderParagraph;
    expect(paragraph.didExceedMaxLines, isFalse,
        reason: '"${paragraph.text.toPlainText()}" is cut off at '
            '${paragraph.size.width} wide');
    // No word is split across lines ("Budget / s").
    final plain = paragraph.text.toPlainText();
    var start = 0;
    for (final word in plain.split(' ')) {
      final boxes = paragraph.getBoxesForSelection(TextSelection(
          baseOffset: start, extentOffset: start + word.length));
      expect(boxes.map((box) => box.top).toSet(), hasLength(1),
          reason: '"$word" in "$plain" breaks mid-word');
      start += word.length + 1;
    }
  }
}

void _heroTitleOnOneLine(WidgetTester tester, String title) {
  final hero = find.byType(QirshSectionHero);
  expect(tester.widget<QirshSectionHero>(hero).fitTitle, isTrue);
  final text = find.descendant(of: hero, matching: find.text(title)).first;
  final paragraph = tester.renderObject<RenderParagraph>(text);
  expect(paragraph.didExceedMaxLines, isFalse);
  final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: title.length));
  expect(boxes.map((box) => box.top).toSet(), hasLength(1),
      reason: 'the page title must not break mid-word (UX-06)');
}

void _headerActionsAre44(WidgetTester tester) {
  for (final element in find.byType(CalmHeaderAction).evaluate()) {
    final size = tester.getSize(find.byWidget(element.widget));
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  }
}

// UX-03, UX-05, UX-06, UX-08 on the smallest supported screens at the app's
// maximum text scale.
void main() {
  for (final language in ['en', 'ar']) {
    for (final size in _sizes) {
      testWidgets('Budgets header, tabs and chips fit $size 1.25x $language',
          (tester) async {
        final view = BudgetsView(
            snapshot: BudgetProgressSnapshot(entries: [
              _entry('over', 'SAR', 12000, 10000, health: BudgetHealth.over),
              _entry('near', 'SAR', 9000, 10000, health: BudgetHealth.warning),
              _entry('safe', 'SAR', 2345, 20000),
            ]),
            historyEntries: const [],
            catalog: _catalog,
            accounts: const [],
            goals: const []);
        await _pump(tester, const BudgetsScreen(), size,
            language: language,
            overrides: [
              planningCutoverCoordinatorProvider.overrideWithValue(
                  const FixedPlanningCutoverCoordinator(
                      PlanningCutoverState.canonical)),
              baseCurrencyProvider.overrideWith((ref) async => 'SAR'),
              budgetsViewProvider.overrideWith((ref) async => view),
              budgetsPageTabProvider.overrideWith((ref) => 0),
            ]);
        expect(tester.takeException(), isNull);
        final l10n = AppL10n.of(tester.element(find.byType(BudgetsScreen)));
        // UX-08: tab labels and summary chip labels are not truncated.
        for (final tab in [
          l10n.bdgTabBudgets,
          l10n.bdgTabGoals,
          l10n.bdgTabHistory
        ]) {
          final label = find.descendant(
              of: find.byType(PlanningHeroTabs), matching: find.text(tab));
          _fullText(tester, label);
          // UX-05: each tab is at least a 44 pt target.
          final target = find.ancestor(
              of: label, matching: find.byType(GestureDetector)).first;
          expect(tester.getSize(target).height, greaterThanOrEqualTo(44));
        }
        for (final chip in [
          l10n.bdgStateSafeF,
          l10n.bdgStateNear,
          l10n.bdgStateOverF,
          l10n.bdgBudgetsWord,
        ]) {
          final label = find.text(chip);
          await tester.ensureVisible(label.first);
          await tester.pumpAndSettle();
          _fullText(tester, label);
        }
        _headerActionsAre44(tester);
        expect(tester.takeException(), isNull);
      });

      testWidgets('Transactions header fits $size 1.25x $language',
          (tester) async {
        final db = (await tester.runAsync(() => AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _Keys(),
            initialLanguage: language)))!;
        addTearDown(() async {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(db.close);
        });
        await _pump(tester, const TransactionsScreen(), size,
            language: language,
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              baseCurrencyProvider.overrideWith((_) async => 'SAR'),
            ]);
        expect(tester.takeException(), isNull);
        final l10n =
            AppL10n.of(tester.element(find.byType(TransactionsScreen)));
        // UX-03: the icon-only Add action has an accessible name.
        expect(find.bySemanticsLabel(l10n.mtAddTransaction), findsOneWidget);
        // UX-05: header actions (search and add) are 44 pt.
        _headerActionsAre44(tester);
        final search = tester.getSize(find.bySemanticsLabel(l10n.txnSearchHint).first);
        expect(search.width, greaterThanOrEqualTo(44));
        expect(search.height, greaterThanOrEqualTo(44));
        // UX-06: the title stays on one line.
        _heroTitleOnOneLine(tester, l10n.txnTabTransactions);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
