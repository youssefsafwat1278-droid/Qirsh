import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'active-count-memory-only';
  @override
  Future<String?> readStoredKey() async => 'active-count-memory-only';
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _MemoryKeys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('active header excludes completed goals with exact canonical money $language dark$dark', (tester) async {
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
        final repository = DriftGoalRepository(db);
        final seeds = [
          ('active', 'QA active', 100000, 1000000, 'EGP'),
          ('exact', 'QA exact target', 2500000, 2500000, 'EGP'),
          ('above', 'QA above target', 3500000, 3000000, 'EGP'),
          ('huge', 'QA exact minor active', 9007199254740995, 9007199254740996, 'EGP'),
          ('foreign', 'QA foreign active', 1000, 10000, 'KWD'),
        ];
        for (final seed in seeds) {
          await repository.save(GoalEntity(id: seed.$1, name: seed.$2,
            currency: seed.$5, savedMoney: Money(seed.$3, seed.$5),
            targetMoney: Money(seed.$4, seed.$5),
            lastNotifiedSavedMoney: Money.zero(seed.$5), vaultSkin: 'default_vault',
            status: 'active', createdAt: DateTime.utc(2026, 10, 29)));
        }
        final before = (await db.customSelect('SELECT * FROM goals ORDER BY id').get())
            .map((row) => row.data).toList();
        expect(Money(9007199254740995, 'EGP').toDouble(),
            Money(9007199254740996, 'EGP').toDouble(),
            reason: 'This adjacent-minor case would be lost through double comparison.');
        await tester.pumpWidget(ProviderScope(overrides: [
          appDatabaseProvider.overrideWithValue(db),
          baseCurrencyProvider.overrideWith((_) async => 'EGP'),
        ], child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
          locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const GoalsScreen())));
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pumpAndSettle();
        final l10n = AppL10n.of(tester.element(find.byType(GoalsScreen)));
        final summary = find.byType(CalmFinancialSummary);
        final header = tester.widget<CalmFinancialSummary>(summary);
        final hero = find.byKey(const ValueKey('section-hero-goals'));
        expect(find.descendant(of: hero, matching: find.text(l10n.bdgTabHistory)),
            findsOneWidget);
        // Only the active count changes: all four EGP goals still enter totals.
        final saved = formatMoney(Money(9007199260840995, 'EGP'));
        expect(header.amount, saved);
        expect(find.descendant(of: summary, matching: find.text(saved)),
            findsOneWidget);
        expect(header.metrics.singleWhere((m) => m.label == l10n.goalTargetLabel).value,
            formatMoney(Money(9007199261240996, 'EGP')));
        expect(header.metrics.singleWhere((m) => m.label == l10n.bdgStatActiveGoals).value, '2');
        final scrollable = find.byType(Scrollable).first;
        for (final name in ['QA active', 'QA exact target', 'QA above target', 'QA exact minor active']) {
          await tester.scrollUntilVisible(find.text(name), 200, scrollable: scrollable);
          expect(find.text(name), findsOneWidget);
        }
        expect(find.text('QA foreign active'), findsNothing);
        expect(find.text(l10n.bdgGoalDone), findsNWidgets(2));
        expect((await db.customSelect('SELECT * FROM goals ORDER BY id').get())
            .map((row) => row.data).toList(), before);
        expect((await repository.getAll()).every((goal) => goal.status == 'active'), isTrue);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
