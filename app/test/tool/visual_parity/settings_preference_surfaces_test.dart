import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
// Test-process transport capture/restoration, never used by the QA helper.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/security/lock_prompt_language.dart';
import 'package:money_companion/core/security/secure_storage_options.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/theme_mode_controller.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../../../tool/visual_parity/settings_preference_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'settings-preferences-memory-only';
  @override
  Future<String?> readStoredKey() async => 'settings-preferences-memory-only';
}

Future<Map<String, List<Map<String, Object?>>>> _snapshot(
    AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return {
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((value) => value.data)
          .toList(),
  };
}

void _onlyLanguageAndTimestampChanged(
    Map<String, List<Map<String, Object?>>> before,
    Map<String, List<Map<String, Object?>>> after,
    String language) {
  expect(after.keys, before.keys);
  for (final table in before.keys) {
    if (table != 'user_settings') {
      expect(after[table], before[table], reason: table);
    } else {
      final previous = Map<String, Object?>.from(before[table]!.single);
      final current = Map<String, Object?>.from(after[table]!.single);
      expect(current.remove('language'), language);
      previous.remove('language');
      expect(current.remove('updated_at'), isNotNull);
      previous.remove('updated_at');
      expect(current, previous,
          reason: 'No consent/profile/other preference changes');
    }
  }
}

void main() {
  late AppDatabase db;
  late FlutterSecureStoragePlatform originalTransport;
  late String originalInitialLanguage;
  setUp(() async {
    originalTransport = FlutterSecureStoragePlatform.instance;
    originalInitialLanguage = LockPromptLanguage.initialSettingsLanguage;
    FlutterSecureStorage.setMockInitialValues(
        {'untouched-private-sentinel': 'keep'});
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _Keys(),
        initialLanguage: 'en');
  });
  tearDown(() async {
    await db.close();
    await LockPromptLanguage.set(originalInitialLanguage);
    FlutterSecureStoragePlatform.instance = originalTransport;
  });

  for (final priorAbsent in [false, true]) {
    testWidgets(
        'actual settings live language/theme, restore exact mirrors absent=$priorAbsent',
        (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        final font = FontLoader('Vazirmatn');
        for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
          font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
        }
        await font.load();
      });
      // Process cache intentionally differs from raw persisted mirror.
      await LockPromptLanguage.set('ar');
      if (priorAbsent) {
        await SecureStorageOptions.storage
            .delete(key: 'app_lock_prompt_language');
      } else {
        await SecureStorageOptions.storage
            .write(key: 'app_lock_prompt_language', value: 'en');
        await SecureStorageOptions.storage
            .write(key: 'app_theme_mode', value: 'dark');
      }
      final priorStorage = await SecureStorageOptions.storage.readAll();
      final initialCache = LockPromptLanguage.initialSettingsLanguage;
      final container = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      addTearDown(container.dispose);
      final originalTheme = container.read(themeModeProvider.notifier);
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 30)));
      final parentTheme = container.read(themeModeProvider);
      final before = await _snapshot(db);
      final restored = visualParitySettingsPreferenceEvents()[
              'settingsPreferenceMirrorsRestored'] ??
          0;
      final router = GoRouter(routes: [
        GoRoute(
            path: '/',
            builder: (context, state) => Consumer(
                builder: (context, ref, _) => Scaffold(
                    body: TextButton(
                        onPressed: () async {
                          await openVisualParitySettingsPreference(
                              context, ref, 'settingsLivePreferences');
                        },
                        child: const Text('Live preferences')))))
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child:
              MaterialApp.router(routerConfig: router, theme: AppTheme.light)));
      await tester.tap(find.text('Live preferences'));
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
      final screen = find.byType(SettingsScreen);
      expect(screen, findsOneWidget);
      final scoped = ProviderScope.containerOf(tester.element(screen.last));
      expect(identical(scoped.read(themeModeProvider.notifier), originalTheme),
          isFalse);
      expect(Localizations.localeOf(tester.element(screen.last)).languageCode, 'en');

      // v2: the More hub links to sub-pages; language lives on «بيانات
      // حسابك» and the theme on «المظهر». Same controls, same writes.
      Future<void> openPage(String key) async {
        // The hub is a lazy list: scroll the row into existence first.
        await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 240,
            scrollable: find
                .descendant(
                    of: find.byType(SettingsScreen).last,
                    matching: find.byType(Scrollable))
                .first);
        await tester.ensureVisible(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(key)));
        await tester.pumpAndSettle();
      }

      await openPage('settings-page-account');
      for (final language in ['ar', 'en']) {
        await tester
            .ensureVisible(find.byKey(const ValueKey('settings-language')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('settings-language')));
        await tester.pumpAndSettle();
        await tester
            .tap(find.text(language == 'ar' ? 'العربية' : 'English').last);
        await tester.pumpAndSettle();
        expect(
            (await container.read(userSettingsRepositoryProvider).getSettings())
                .language,
            language);
        expect(Localizations.localeOf(tester.element(screen.last)).languageCode,
            language);
        expect(Directionality.of(tester.element(screen.last)),
            language == 'ar' ? TextDirection.rtl : TextDirection.ltr);
        expect(
            await SecureStorageOptions.storage
                .read(key: 'app_lock_prompt_language'),
            language);
        _onlyLanguageAndTimestampChanged(before, await _snapshot(db), language);
      }
      final l10n = AppL10n.of(tester.element(screen.last));
      Navigator.of(tester.element(find.byType(SettingsScreen).last)).pop();
      await tester.pumpAndSettle();
      await openPage('settings-page-appearance');
      for (final entry in [
        (l10n.setThemeAuto, ThemeMode.system, Brightness.light),
        (l10n.setThemeLight, ThemeMode.light, Brightness.light),
        (l10n.setThemeDark, ThemeMode.dark, Brightness.dark),
      ]) {
        await tester.ensureVisible(find.text(entry.$1));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.$1));
        await tester.pumpAndSettle();
        expect(scoped.read(themeModeProvider), entry.$2);
        expect(Theme.of(tester.element(screen.last)).brightness, entry.$3);
        expect(container.read(themeModeProvider), parentTheme);
        _onlyLanguageAndTimestampChanged(before, await _snapshot(db), 'en');
      }
      expect(tester.takeException(), isNull);
      Navigator.of(tester.element(find.byType(SettingsScreen).last)).pop();
      await tester.pumpAndSettle();
      // Outer route close is the same controller operation used in native QA;
      // the helper's independent MaterialApp owns all actual picker overlays.
      router.routerDelegate.navigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.runAsync(
          () async => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pump();
      expect(
          visualParitySettingsPreferenceEvents()[
              'settingsPreferenceMirrorsRestored'],
          restored + 1);
      expect(await SecureStorageOptions.storage.readAll(), priorStorage);
      expect(LockPromptLanguage.initialSettingsLanguage, initialCache);
      expect(
          identical(container.read(themeModeProvider.notifier), originalTheme),
          isTrue);
      expect(container.read(themeModeProvider), parentTheme);
      _onlyLanguageAndTimestampChanged(before, await _snapshot(db), 'en');
      expect(find.text('Live preferences'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
