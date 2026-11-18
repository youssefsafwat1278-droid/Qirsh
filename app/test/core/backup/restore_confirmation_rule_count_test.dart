// Round 4 — the restore confirmation says, BEFORE anything changes, how many
// saved rules of this backup will be left for the user's choice. Synthetic
// data only.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/backup/restore_plan.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../harness/seed_test_account.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'rule-count-memory';
  @override
  Future<String?> readStoredKey() async => 'rule-count-memory';
}

/// Prepares a backup written without deletion history (format 4) that holds
/// two saved rules this device does not have. Nothing else is allowed.
class _PreparedOnly implements BackupService {
  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async =>
      RestorePlan(
        operationId: 'rule-count',
        envelopeVersion: 3,
        snapshotSchemaVersion: 4,
        sourceFingerprint: 'synthetic',
        tables: const {
          'categories': [
            {'id': 'c1', 'key': 'restaurants', 'deleted_at': null},
          ],
          'merchants': [
            {
              'id': 'm1',
              'raw_name': 'Synthetic Shop',
              'normalized_name': 'SYNTHETIC SHOP'
            },
            {
              'id': 'm2',
              'raw_name': 'متجر اصطناعي',
              'normalized_name': 'متجر اصطناعي'
            },
          ],
          'merchant_category_map': [
            {
              'id': 'r1',
              'merchant_id': 'm1',
              'category_id': 'c1',
              'is_user_confirmed': 1,
              'confidence': 1.0,
              'updated_at': '2026-07-01T00:00:00.000Z',
            },
            {
              'id': 'r2',
              'merchant_id': 'm2',
              'category_id': 'c1',
              'is_user_confirmed': 1,
              'confidence': 1.0,
              'updated_at': '2026-07-01T00:00:00.000Z',
            },
          ],
        },
        warnings: const [],
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('only preparation is allowed here');
}

void main() {
  for (final lang in ['en', 'ar']) {
    for (final hasRecords in [true, false]) {
      testWidgets(
          '$lang: ${hasRecords ? 'a merge names the rules waiting for a choice' : 'a full restore has none to name'}',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        if (hasRecords) await seedTestAccount(db);

        await tester.pumpWidget(ProviderScope(
            overrides: [
              appDatabaseProvider.overrideWithValue(db),
              backupServiceProvider.overrideWithValue(_PreparedOnly()),
            ],
            child: MaterialApp(
                theme: AppTheme.light,
                locale: Locale(lang),
                supportedLocales: AppL10n.supportedLocales,
                localizationsDelegates: AppL10n.localizationsDelegates,
                home: const RestorePromptScreen(onboardingFlow: false))));
        await tester.pumpAndSettle();
        final l10n =
            AppL10n.of(tester.element(find.byType(RestorePromptScreen)));
        await tester.enterText(
            find.byType(TextField).first, 'qa-restore-secret');
        tester.testTextInput.hide();
        await tester.pumpAndSettle();
        final restore = find.byKey(const Key('restore_cta'));
        await tester.ensureVisible(restore);
        await tester.tap(restore);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.byType(GlassAlertDialog), findsOneWidget);
        final text = [
          for (final t in tester.widgetList<Text>(find.descendant(
              of: find.byType(GlassAlertDialog), matching: find.byType(Text))))
            t.data ?? '',
        ].join('\n');

        if (hasRecords) {
          expect(text, contains(l10n.rpConfirmBodyMerge));
          expect(text, contains(l10n.lrRestoreCount(2)));
        } else {
          expect(text, contains(l10n.rpConfirmBodyFull));
          expect(text, isNot(contains(l10n.lrRestoreCount(2))));
        }
        expect(tester.takeException(), isNull);
        // Nothing was changed by preparing or by showing the count.
        expect(
            await db
                .customSelect('SELECT 1 FROM merchant_rule_restore_choices;')
                .get(),
            isEmpty);

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      });
    }
  }
}
