import 'dart:convert';
import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
// Use pinned plugin public test boundary; no production dependency added.
// ignore: depend_on_referenced_packages
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

class _FailingLockStorage extends TestFlutterSecureStoragePlatform {
  _FailingLockStorage()
      : super({'app_lock_enabled': '1', 'qa_unrelated_key': 'retained'});
  final gate = Completer<void>();
  int calls = 0;
  @override
  Future<void> write(
      {required String key,
      required String value,
      required Map<String, String> options}) async {
    if (key != 'app_lock_enabled' || value != '0') {
      throw StateError('unexpected lock write');
    }
    calls++;
    await gate.future;
    throw PlatformException(
        code: 'qa_storage_failure', message: 'private_lock_diagnostic');
  }
}

Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      )
      .get();
  return jsonEncode({
    for (final row in tables)
      row.read<String>('name'): (await db
              .customSelect(
                'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid',
              )
              .get())
          .map((r) => r.data)
          .toList(),
  });
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      {
        testWidgets(
            'lock failed OFF keeps stored ON and permits retry $language dark=$dark',
            (tester) async {
          tester.view.physicalSize = const Size(375, 667);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final previousStorage = FlutterSecureStoragePlatform.instance;
          final storage = _FailingLockStorage();
          FlutterSecureStoragePlatform.instance = storage;
          addTearDown(
              () => FlutterSecureStoragePlatform.instance = previousStorage);
          final db = await AppDatabase.open(
            executor: NativeDatabase.memory(),
            keyStore: _MemoryKeys(),
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
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 100));
          }
          await tester.pumpAndSettle();
          final l10n = AppL10n.of(tester.element(find.byType(SettingsScreen)));
          final tile = find.widgetWithText(SwitchListTile, l10n.setAppLock);
          await tester.ensureVisible(tile);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          await tester.tap(tile);
          await tester.pump();
          expect(storage.calls, 1);
          await tester.tap(tile);
          await tester.pump();
          expect(storage.calls, 1,
              reason: 'held storage write must not admit another toggle');
          storage.gate.complete();
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull,
              reason: 'storage failure is a recoverable UI error');
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          expect(find.text(l10n.setupSaveFailed), findsOneWidget);
          expect(find.textContaining('private_lock_diagnostic'), findsNothing);
          await tester.pump(const Duration(seconds: 4));
          await tester.pumpAndSettle();
          await tester.ensureVisible(tile);
          await tester.tap(tile);
          await tester.pumpAndSettle();
          expect(storage.calls, 2,
              reason: 'failure clears busy and allows deliberate retry');
          expect(tester.widget<SwitchListTile>(tile).value, isTrue);
          expect(storage.data,
              {'app_lock_enabled': '1', 'qa_unrelated_key': 'retained'});
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
