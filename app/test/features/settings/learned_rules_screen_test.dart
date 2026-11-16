import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/engine/intelligence/merchant_intelligence_store.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/settings/learned_rules_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// In-memory map of merchant → (category, user confirmed?).
class _Merchants implements MerchantCategoryRepository {
  final rows = <String, (String, bool)>{
    'ZARYAB DIMASHQI': ('restaurants', true),
    // A catalog seed row: never a "learned rule".
    'CARREFOUR': ('groceries', false),
  };

  @override
  Future<List<LearnedMerchantRule>> getUserConfirmedRules() async => [
        for (final e in rows.entries)
          if (e.value.$2)
            LearnedMerchantRule(rawMerchant: e.key, categoryKey: e.value.$1),
      ];

  @override
  Future<void> forgetUserConfirmedRule(String rawMerchant) async {
    if (rows[rawMerchant]?.$2 == true) rows.remove(rawMerchant);
  }

  @override
  Future<void> confirmMerchantCategory(
      {required String rawMerchant,
      required String categoryKey,
      required bool isUserConfirmed,
      double confidence = 1}) async {
    rows[rawMerchant] = (categoryKey, isUserConfirmed);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected ${invocation.memberName}');
}

Future<AppL10n> _open(WidgetTester tester, _Merchants merchants,
    MerchantIntelligenceStore model, String language) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      learnedRulesUseCaseProvider.overrideWithValue(LearnedRulesUseCase(
          merchantCategoryRepository: merchants, merchantIntelligence: model)),
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
              ], languageCode: language)),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: const LearnedRulesScreen(),
    ),
  ));
  await tester.pumpAndSettle();
  return AppL10n.of(tester.element(find.byType(LearnedRulesScreen)));
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets(
        'lists only confirmed rules; delete then undo restores ($language)',
        (tester) async {
      final merchants = _Merchants();
      final model = MerchantIntelligenceStore()
        ..learnFromUserCorrection('ZARYAB DIMASHQI', 'restaurants');
      final l10n = await _open(tester, merchants, model, language);

      expect(find.text(l10n.setLearnedRules), findsOneWidget);
      expect(find.text('ZARYAB DIMASHQI'), findsOneWidget);
      expect(find.text('CARREFOUR'), findsNothing);

      await tester.tap(find.byTooltip(l10n.lrDelete));
      await tester.pumpAndSettle();
      expect(find.text('ZARYAB DIMASHQI'), findsNothing);
      expect(find.text(l10n.lrEmptyTitle), findsOneWidget);
      expect(find.text(l10n.lrDeleted), findsOneWidget);
      expect(merchants.rows.containsKey('ZARYAB DIMASHQI'), isFalse);
      expect(model.predict('ZARYAB DIMASHQI'), isNull);

      await tester.tap(find.text(l10n.lrUndo));
      await tester.pumpAndSettle();
      expect(find.text('ZARYAB DIMASHQI'), findsOneWidget);
      expect(merchants.rows['ZARYAB DIMASHQI'], ('restaurants', true));
      expect(model.predict('ZARYAB DIMASHQI')?.categoryKey, 'restaurants');
      expect(merchants.rows['CARREFOUR'], ('groceries', false));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('shows the empty state when nothing was confirmed',
      (tester) async {
    final merchants = _Merchants()..rows.remove('ZARYAB DIMASHQI');
    final l10n =
        await _open(tester, merchants, MerchantIntelligenceStore(), 'en');
    expect(find.text(l10n.lrEmptyTitle), findsOneWidget);
    expect(find.text('CARREFOUR'), findsNothing);
  });
}
