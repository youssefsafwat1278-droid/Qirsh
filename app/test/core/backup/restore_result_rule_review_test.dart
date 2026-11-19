// Round 4 (review R4R-04) — after a restore that left saved rules for the
// user's choice, a dialog says how many and why, and "Review rules" opens the
// list. A real restore (real use case, real in-memory databases) behind the
// real restore screen; only the encrypted download is replaced. Synthetic data
// only.
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/merchant_rule_restore.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/backup/restore_controller.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/backup/restore_preparation.dart';
import 'package:money_companion/core/backup/restore_result.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/features/settings/learned_rules_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../harness/seed_test_account.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'rule-review-memory';
  @override
  Future<String?> readStoredKey() async => 'rule-review-memory';
}

const _shops = ['Synthetic Rule Shop', 'متجر اصطناعي'];

/// Serves one prepared backup and commits it with the real restore use case.
class _RealRestore implements BackupService {
  _RealRestore(this.db, this.snapshot);
  final AppDatabase db;
  final Map<String, dynamic> snapshot;

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      RestorePreparation.build(
        snapshot: snapshot,
        envelopeVersion: 3,
        sourceBytes: utf8.encode(jsonEncode(snapshot)),
        operationId: 'rule-review',
      );

  @override
  Future<RestoreResult> commitRestore(
      {required RestoreConfirmation confirmation}) async {
    final plan = confirmation.plan;
    await RestoreBackupUseCase(db)(
      <String, dynamic>{
        'schemaVersion': plan.snapshotSchemaVersion,
        'tables': plan.tables,
      },
      plan: plan,
    );
    return const RestoreResult(RestoreOutcome.success,
        operationId: 'rule-review');
  }

  @override
  Future<bool> verifyRestoredDatabaseUsable() async => true;

  @override
  Future<void> acknowledgeRestore({required String operationId}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('not part of this flow: ${invocation.memberName}');
}

void main() {
  for (final lang in ['en', 'ar']) {
    testWidgets(
        '$lang: the restore ends with the count and the explanation; '
        '"Review rules" opens the list of undecided rules', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      FlutterSecureStorage.setMockInitialValues({});
      late AppDatabase db;
      late Map<String, dynamic> backup;
      await tester.runAsync(() async {
        // Another phone, on a build without deletion history, saved two rules.
        final source = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        await seedTestAccount(source);
        for (final shop in _shops) {
          await DriftMerchantCategoryRepository(source).confirmMerchantCategory(
              rawMerchant: shop,
              categoryKey: 'restaurants',
              isUserConfirmed: true);
        }
        backup =
            (jsonDecode(jsonEncode(await BackupSnapshotBuilder(source).build()))
                    as Map)
                .cast<String, dynamic>();
        backup['version'] = 4;
        backup['schemaVersion'] = 4;
        (backup['tables'] as Map).removeWhere(
            (t, _) => MerchantRuleRestore.historyTables.contains(t));
        await source.close();
        // This phone holds an account of its own: the restore merges.
        db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        await seedTestAccount(db);
      });
      addTearDown(() => tester.runAsync(() => db.close()));

      Future<void> settle() async {
        for (var i = 0; i < 10; i++) {
          await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)));
          await tester.pump(const Duration(milliseconds: 100));
        }
      }

      await tester.pumpWidget(ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
            backupServiceProvider.overrideWithValue(_RealRestore(db, backup)),
            learnedRulesUseCaseProvider.overrideWithValue(LearnedRulesUseCase(
                merchantCategoryRepository:
                    DriftMerchantCategoryRepository(db))),
          ],
          child: MaterialApp(
              theme: AppTheme.light,
              locale: Locale(lang),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: const RestorePromptScreen(onboardingFlow: false))));
      await tester.pumpAndSettle();
      final l10n = AppL10n.of(tester.element(find.byType(RestorePromptScreen)));
      await tester.enterText(find.byType(TextField).first, 'qa-restore-secret');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      final restore = find.byKey(const Key('restore_cta'));
      await tester.ensureVisible(restore);
      await tester.tap(restore);
      await settle();

      // The confirmation, then the real restore.
      expect(find.byType(GlassAlertDialog), findsOneWidget);
      await tester.tap(find.descendant(
          of: find.byType(GlassAlertDialog),
          matching: find.text(l10n.rpRestore)));
      await settle();

      // The result: how many rules wait, why, and the two ways on.
      final dialog = find.byType(GlassAlertDialog);
      expect(dialog, findsOneWidget);
      String text(Finder f) => tester.widget<Text>(f).data!;
      expect(
          find.descendant(
              of: dialog, matching: find.text(l10n.lrRestoreCount(2))),
          findsOneWidget);
      expect(
          text(find.descendant(
              of: dialog, matching: find.text(l10n.lrRestoreExplanation))),
          l10n.lrRestoreExplanation);
      expect(find.descendant(of: dialog, matching: find.text(l10n.notNow)),
          findsOneWidget);
      expect(
          await tester.runAsync(() =>
              DriftMerchantCategoryRepository(db).getUserConfirmedRules()),
          isEmpty,
          reason: 'nothing was added behind the user\'s back');

      await tester.tap(find.descendant(
          of: dialog, matching: find.text(l10n.lrRestoreReview)));
      await settle();
      await tester.pumpAndSettle();
      expect(find.byType(LearnedRulesScreen), findsOneWidget);
      for (final shop in _shops) {
        await tester.dragUntilVisible(
            find.byKey(ValueKey(
                'restore-rule-${AppDatabase.normalizeMerchant(shop)}')),
            find.byType(Scrollable).first,
            const Offset(0, -120));
      }
      expect(await tester.runAsync(() => MerchantRuleRestore(db).pending()),
          hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }
}
