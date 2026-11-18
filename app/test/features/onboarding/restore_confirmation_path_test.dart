// SP-12: the restore confirmation tells the user which restore applies to THIS
// device (merge or full), not both. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/restore_confirmation_cancel_surface.dart';
import '../../harness/seed_test_account.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'restore-path-memory';
  @override
  Future<String?> readStoredKey() async => 'restore-path-memory';
}

const _merge = {
  'en': [
    'already has your records',
    'a transaction you deleted is not brought back',
    'rules that are only in the backup are not added',
  ],
  'ar': [
    'يحتوي هذا الجهاز على سجلاتك',
    'لا تُستعاد عملية حذفتها',
    'ولا تُضاف القواعد الموجودة في النسخة فقط',
  ],
};
const _full = {
  'en': ['has no records yet', 'restored as it is'],
  'ar': ['لا يحتوي هذا الجهاز على سجلات بعد', 'كما هي'],
};

Future<String> _dialogText(
    WidgetTester tester, String lang, AppDatabase db) async {
  await tester.pumpWidget(ProviderScope(
      overrides: [
        appDatabaseProvider.overrideWithValue(db),
        backupServiceProvider
            .overrideWithValue(PresentationOnlyPreparedRestore()),
      ],
      child: MaterialApp(
          theme: AppTheme.light,
          locale: Locale(lang),
          supportedLocales: AppL10n.supportedLocales,
          localizationsDelegates: AppL10n.localizationsDelegates,
          home: const RestorePromptScreen(onboardingFlow: false))));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, 'qa-restore-secret');
  tester.testTextInput.hide();
  await tester.pumpAndSettle();
  final restore = find.byKey(const Key('restore_cta'));
  await tester.ensureVisible(restore);
  await tester.tap(restore);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.byType(GlassAlertDialog), findsOneWidget);
  return [
    for (final t in tester.widgetList<Text>(find.descendant(
        of: find.byType(GlassAlertDialog), matching: find.byType(Text))))
      t.data ?? '',
  ].join('\n');
}

void main() {
  for (final lang in ['en', 'ar']) {
    for (final hasRecords in [true, false]) {
      testWidgets(
          '$lang: the confirmation states only the '
          '${hasRecords ? 'merge' : 'full restore'} that applies', (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        if (hasRecords) await seedTestAccount(db);

        final text = await _dialogText(tester, lang, db);
        for (final s in hasRecords ? _merge[lang]! : _full[lang]!) {
          expect(text, contains(s));
        }
        for (final s in hasRecords ? _full[lang]! : _merge[lang]!) {
          expect(text, isNot(contains(s)));
        }

        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      });
    }
  }
}
