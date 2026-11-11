import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
// Use the pinned local_auth plugin's public test boundary.
// ignore: depend_on_referenced_packages
import 'package:local_auth_platform_interface/local_auth_platform_interface.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'lock-review-memory';
  @override
  Future<String?> readStoredKey() async => 'lock-review-memory';
}

class _UnsupportedAuthentication extends LocalAuthPlatform {
  int checks = 0;
  @override
  Future<bool> isDeviceSupported() async {
    checks++;
    return false;
  }
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
    "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
  ).get();
  return jsonEncode({
    for (final row in tables)
      row.read<String>('name'): (await db.customSelect(
        'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid',
      ).get()).map((r) => r.data).toList(),
  });
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final initiallyOn in [false, true]) {
        testWidgets('lock stored=$initiallyOn and denied enable $language dark=$dark', (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          FlutterSecureStorage.setMockInitialValues({
            'app_lock_enabled': initiallyOn ? '1' : '0',
            'qa_unrelated_key': 'retained',
          });
          final previousPlatform = LocalAuthPlatform.instance;
          final unsupported = _UnsupportedAuthentication();
          LocalAuthPlatform.instance = unsupported;
          addTearDown(() => LocalAuthPlatform.instance = previousPlatform);
          final db = await AppDatabase.open(
            executor: NativeDatabase.memory(), keyStore: _MemoryKeys(),
          );
          final before = await _snapshot(db);
          await tester.pumpWidget(ProviderScope(
            overrides: [appDatabaseProvider.overrideWithValue(db)],
            child: MaterialApp(
              theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language),
              supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              // v2: app lock lives on the «الأمان والخصوصية» sub-page.
              home: const SettingsScreen(page: SettingsPage.security),
            ),
          ));
          for (var i = 0; i < 6; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
          final tile = find.widgetWithText(SwitchListTile, l10n.setAppLock);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, initiallyOn);
          if (initiallyOn) {
            await tester.tap(tile);
            await tester.pumpAndSettle();
            expect(tester.widget<SwitchListTile>(tile).value, isFalse);
            expect(unsupported.checks, 0);
          }
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, isFalse);
          expect(find.text(l10n.setAppLockFailed), findsOneWidget);
          expect(unsupported.checks, 1);
          const storage = FlutterSecureStorage();
          expect(await storage.read(key: 'app_lock_enabled'), '0');
          expect(await storage.read(key: 'qa_unrelated_key'), 'retained');
          expect(await _snapshot(db), before);
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
          await db.close();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
