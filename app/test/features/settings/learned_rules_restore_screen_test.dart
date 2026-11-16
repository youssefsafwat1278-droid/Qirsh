import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/entities/category_entity.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:money_companion/features/settings/learned_rules_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../capture/ledger_admission_fixture.dart';

/// The server holds one rule; the device has none (fresh install).
class _CloudRules implements MerchantRuleRemote {
  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) async =>
      throw StateError('nothing to push on a fresh install');

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) async =>
      after.id.isNotEmpty
          ? const []
          : [
              {
                'id': 'srv-1',
                'merchant_key': 'ZARYAB DIMASHQI',
                'category_key': 'restaurants',
                'updated_at': '2026-11-16T10:00:00.000Z',
                'deleted_at': null,
              }
            ];
}

void main() {
  testWidgets('the Learned rules page lists rules restored from the cloud',
      (tester) async {
    late LedgerAdmissionFixture fixture;
    late DriftMerchantCategoryRepository rules;
    await tester.runAsync(() async {
      fixture = await LedgerAdmissionFixture.open('user-1');
      final db = fixture.database;
      rules = DriftMerchantCategoryRepository(db);
      final res = await MerchantRuleSyncService(
        db: db,
        queue: PlanningOutboxQueue(
            db: db,
            isSyncEnabled: (_) => true,
            getAuthUserId: () async => 'user-1'),
        remote: _CloudRules(),
        getAuthUserId: () async => 'user-1',
        mayEgress: () async => true,
        serverReady: () async => true,
      ).sync();
      expect(res.applied, 1);
    });
    addTearDown(() => tester.runAsync(() => fixture.finish()));

    await tester.runAsync(() async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
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
                  ], languageCode: 'en')),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          locale: const Locale('en'),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const LearnedRulesScreen(),
        ),
      ));
      // Let the list query complete on the real database.
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pumpAndSettle();
    final l10n = AppL10n.of(tester.element(find.byType(LearnedRulesScreen)));
    expect(find.text('ZARYAB DIMASHQI'), findsOneWidget);
    expect(find.text(l10n.lrEmptyTitle), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
