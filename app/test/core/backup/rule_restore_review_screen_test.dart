// Round 4 — the reviewable list of backup rules a restore left for the user's
// choice (Settings → Learned rules): merchant, category, Add / Leave out per
// rule and for all, in English and Arabic, at the default and the largest text
// size, over a real in-memory database. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/merchant_rule_restore.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/settings/learned_rules_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

const _english = 'Synthetic Rule Shop With A Rather Long Trading Name';
const _arabic = 'متجر اصطناعي للتجربة باسم تجاري طويل';

void main() {
  late AppDatabase db;
  late DriftMerchantCategoryRepository rules;

  Future<void> settle(WidgetTester tester) async {
    // The database answers in real time while the widgets run on the test
    // clock: alternate the two until the provider chain has resolved.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
  }

  Future<AppL10n> open(WidgetTester tester, String language,
      {double textScale = 1, Size size = const Size(390, 844)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      rules = DriftMerchantCategoryRepository(db);
      for (final (merchant, category) in const [
        (_english, 'restaurants'),
        (_arabic, 'shopping'),
      ]) {
        await db.customStatement(
            'INSERT INTO merchant_rule_restore_choices(merchant_key, '
            'raw_merchant, category_key, rule_updated_at) VALUES (?, ?, ?, ?);',
            [
              AppDatabase.normalizeMerchant(merchant),
              merchant,
              category,
              '2026-07-01T00:00:00.000Z',
            ]);
      }
    });
    addTearDown(() => tester.runAsync(() => db.close()));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        learnedRulesUseCaseProvider.overrideWithValue(
            LearnedRulesUseCase(merchantCategoryRepository: rules)),
        categoryCatalogProvider
            .overrideWith((ref) async => CategoryCatalog(const [
                  CategoryEntity(
                      id: 'r',
                      key: 'restaurants',
                      nameAr: 'مطاعم',
                      icon: 'utensils',
                      color: '#22C55E',
                      isIncome: false,
                      sort: 1),
                  CategoryEntity(
                      id: 's',
                      key: 'shopping',
                      nameAr: 'تسوق',
                      icon: 'shopping-bag',
                      color: '#3B82F6',
                      isIncome: false,
                      sort: 2),
                ], languageCode: language)),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        locale: Locale(language),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: AppL10n.localizationsDelegates,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const LearnedRulesScreen(),
      ),
    ));
    await settle(tester);
    return AppL10n.of(tester.element(find.byType(LearnedRulesScreen)));
  }

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await settle(tester);
  }

  for (final language in ['en', 'ar']) {
    testWidgets(
        'undecided rules are listed with merchant and category, explained, '
        'and decided one by one ($language)', (tester) async {
      final l10n = await open(tester, language);

      expect(find.text(l10n.lrRestoreCount(2)), findsOneWidget);
      expect(find.text(l10n.lrRestoreExplanation), findsOneWidget);
      expect(find.text(_english), findsOneWidget);
      expect(find.text(_arabic), findsOneWidget);
      expect(
          await tester.runAsync(() => rules.getUserConfirmedRules()), isEmpty,
          reason: 'an undecided rule is not a rule');

      // Add the first, leave the second out.
      final englishRow = find.byKey(
          ValueKey('restore-rule-${AppDatabase.normalizeMerchant(_english)}'));
      await tap(
          tester,
          find.descendant(
              of: englishRow, matching: find.text(l10n.lrRestoreAdd)));
      expect(englishRow, findsNothing);
      expect(
          await tester.runAsync(() => rules.userConfirmedCategoryFor(_english)),
          'restaurants');
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          hasLength(1));
      expect(
          find.byKey(const ValueKey('learned-rule-$_english')), findsOneWidget,
          reason: 'the added rule is now in the ordinary list');

      final arabicRow = find.byKey(
          ValueKey('restore-rule-${AppDatabase.normalizeMerchant(_arabic)}'));
      await tap(
          tester,
          find.descendant(
              of: arabicRow, matching: find.text(l10n.lrRestoreLeave)));
      expect(find.text(l10n.lrRestoreExplanation), findsNothing);
      expect(
          await tester.runAsync(() => rules.userConfirmedCategoryFor(_arabic)),
          isNull);
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          isEmpty);
      expect(
          await tester.runAsync(() => db
              .customSelect(
                  'SELECT merchant_key FROM merchant_rule_tombstones;')
              .get()),
          hasLength(1),
          reason: 'leaving a rule out is recorded');
      expect(tester.takeException(), isNull);
    });

    testWidgets('"Add all" and "Leave all out" decide every rule ($language)',
        (tester) async {
      final l10n = await open(tester, language);
      await tap(tester, find.text(l10n.lrRestoreAddAll));
      expect(find.text(l10n.lrRestoreExplanation), findsNothing);
      expect(await tester.runAsync(() => rules.getUserConfirmedRules()),
          hasLength(2));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        '"Leave all out" does nothing until it is confirmed; cancelling keeps '
        'every rule waiting ($language)', (tester) async {
      final l10n = await open(tester, language);
      await tap(tester, find.byKey(const ValueKey('restore-rules-leave-all')));
      expect(find.text(l10n.lrRestoreLeaveAllTitle(2)), findsOneWidget);
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          hasLength(2),
          reason: 'one tap removes nothing');
      await tap(tester, find.text(l10n.rpCancel));
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          hasLength(2));
      expect(
          await tester.runAsync(() =>
              db.customSelect('SELECT 1 FROM merchant_rule_tombstones;').get()),
          isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'the review list does not overflow at the largest text size on a '
        'small phone ($language)', (tester) async {
      final l10n = await open(tester, language,
          textScale: 2, size: const Size(320, 568));
      // Walk the whole list: every row is laid out at this size.
      for (final text in [
        l10n.lrRestoreCount(2),
        l10n.lrRestoreExplanation,
        _english,
        _arabic,
      ]) {
        await tester.dragUntilVisible(find.text(text),
            find.byType(Scrollable).first, const Offset(0, -120));
        expect(tester.takeException(), isNull, reason: 'layout at "$text"');
      }
      // "Leave all out" asks first (review R4R-03), also at this size.
      await tap(tester, find.byKey(const ValueKey('restore-rules-leave-all')));
      expect(find.text(l10n.lrRestoreLeaveAllTitle(2)), findsOneWidget);
      expect(find.text(l10n.lrRestoreLeaveAllBody), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tap(tester,
          find.byKey(const ValueKey('restore-rules-leave-all-confirm')));
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          isEmpty);
      expect(
          await tester.runAsync(() => rules.getUserConfirmedRules()), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
