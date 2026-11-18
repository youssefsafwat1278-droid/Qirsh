import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/backup_service.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/onboarding/restore_prompt_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import '../../../tool/visual_parity/restore_confirmation_cancel_surface.dart';
import 'package:money_companion/core/theme/widgets/glass_dialog.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'restore-negative-memory';
  @override
  Future<String?> readStoredKey() async => 'restore-negative-memory';
}

Future<Map<String, List<Map<String, Object?>>>> _sql(AppDatabase db) async {
  final names = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final n in names)
      n.read<String>('name'): [
        for (final row in await db
            .customSelect('SELECT * FROM "${n.read<String>('name')}"')
            .get())
          row.data
      ]
  };
}

void main() {
  for (final lang in ['ar', 'en']) {
    for (final dark in [false, true]) {
      testWidgets('synthetic prepared DTO real Cancel only $lang dark$dark',
          (tester) async {
        tester.view.physicalSize = const Size(375, 667);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _Keys());
        final before = await _sql(db);
        final service = PresentationOnlyPreparedRestore();
        var http = 0;
        await HttpOverrides.runZoned(() async {
          await tester.pumpWidget(ProviderScope(
              overrides: [
                appDatabaseProvider.overrideWithValue(db),
                backupServiceProvider.overrideWithValue(service)
              ],
              child: MaterialApp(
                  theme: dark ? AppTheme.dark : AppTheme.light,
                  locale: Locale(lang),
                  supportedLocales: AppL10n.supportedLocales,
                  localizationsDelegates: AppL10n.localizationsDelegates,
                  home: const RestorePromptScreen(onboardingFlow: false))));
          await tester.pumpAndSettle();
          final l =
              AppL10n.of(tester.element(find.byType(RestorePromptScreen)));
          final field = find.byType(TextField).first;
          await tester.enterText(field, 'qa-restore-secret');
          tester.testTextInput.hide();
          await tester.pumpAndSettle();
          for (var attempt = 0; attempt < 2; attempt++) {
            final restore = find.byKey(const Key('restore_cta'));
            await tester.ensureVisible(restore);
            await tester.tap(restore);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 500));
            expect(find.byType(GlassAlertDialog), findsOneWidget);
            expect(find.text(l.rpConfirmTitle), findsOneWidget);
            // SP-12: a fresh database has no records -> the full-restore text.
            expect(find.text(l.rpConfirmBodyFull), findsOneWidget);
            expect(service.calls, attempt + 1);
            expect(service.forbiddenCalls, 0);
            await tester.tap(find.descendant(
                of: find.byType(GlassAlertDialog),
                matching: find.text(l.rpCancel)));
            await tester.pumpAndSettle();
            expect(find.byType(GlassAlertDialog), findsNothing);
            expect(tester.widget<FilledButton>(restore).onPressed, isNotNull);
            expect(tester.widget<TextField>(field).controller!.text,
                'qa-restore-secret');
            expect(service.forbiddenCalls, 0);
            expect(tester.takeException(), isNull);
          }
          expect(http, 0);
        }, createHttpClient: (context) {
          http++;
          throw StateError('restore_cancel_must_not_network');
        });
        expect(await _sql(db), before);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await db.close();
      });
    }
  }
}
