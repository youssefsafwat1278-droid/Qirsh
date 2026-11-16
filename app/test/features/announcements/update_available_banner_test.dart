import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/app_version.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/common/widgets/announcement_banner.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

final _from = DateTime.utc(2026, 1, 1);

RemoteAnnouncement _row({
  String id = 'upd',
  String severity = 'update_available',
  String? maxAppVersion,
  bool isDismissible = true,
  String titleEn = 'A new version is ready',
}) =>
    RemoteAnnouncement(
      id: id,
      titleAr: 'إصدار جديد جاهز',
      titleEn: titleEn,
      bodyAr: null,
      bodyEn: null,
      severity: severity,
      minAppVersion: null,
      maxAppVersion: maxAppVersion,
      actionLabelAr: null,
      actionLabelEn: null,
      actionUrl: null,
      validFrom: _from,
      validUntil: null,
      isDismissible: isDismissible,
      priority: 0,
      isDismissed: false,
      dismissedAt: null,
      syncedAt: _from,
    );

Future<void> _pumpBanner(WidgetTester tester, AppDatabase db) async {
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(), // a fresh scope = a fresh app process
    overrides: [
      announcementServiceProvider.overrideWithValue(
          AnnouncementService(dao: RemoteAnnouncementsDao(db))),
      activeDashboardCampaignsProvider.overrideWith((ref) async => []),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: const Scaffold(body: SafeArea(child: AnnouncementBanner())),
    ),
  ));
  await tester.runAsync(() => Future<void>.delayed(
      const Duration(milliseconds: 50))); // let the real DB query complete
  await tester.pumpAndSettle();
}

void main() {
  late Directory dir;
  late File file;

  Future<AppDatabase> openDb() => AppDatabase.open(
      executor: NativeDatabase(file), keyStore: _MemoryKeyStore());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('update_banner_');
    file = File('${dir.path}/app.db');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets(
      'update_available shows, dismisses, and stays dismissed after '
      'a restart and a re-sync', (tester) async {
    var db = (await tester.runAsync(openDb))!;
    await tester
        .runAsync(() => RemoteAnnouncementsDao(db).replaceAll([_row()]));
    await _pumpBanner(tester, db);

    expect(find.text('A new version is ready'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget,
        reason: 'no server label: the localized default offers the update');

    await tester.tap(find.byTooltip('Hide'));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('A new version is ready'), findsNothing);

    // Restart: close the database, reopen the same file, new provider scope,
    // and the server pushes the same row again.
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
    db = (await tester.runAsync(openDb))!;
    await tester
        .runAsync(() => RemoteAnnouncementsDao(db).replaceAll([_row()]));
    await _pumpBanner(tester, db);
    expect(find.text('A new version is ready'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  });

  testWidgets(
      'update_available is dismissible even when the row says it is '
      'not, and release_notes never become a banner', (tester) async {
    final db = (await tester.runAsync(openDb))!;
    await tester.runAsync(() => RemoteAnnouncementsDao(db).replaceAll([
          _row(isDismissible: false),
          _row(id: 'notes', severity: 'release_notes', titleEn: 'Notes row'),
        ]));
    await _pumpBanner(tester, db);
    expect(find.text('A new version is ready'), findsOneWidget);
    expect(find.byTooltip('Hide'), findsOneWidget);
    expect(find.text('Notes row'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  });

  testWidgets(
      'a cached update_available aimed at older versions is hidden '
      'from the running version', (tester) async {
    final db = (await tester.runAsync(openDb))!;
    await tester.runAsync(() =>
        RemoteAnnouncementsDao(db).replaceAll([_row(maxAppVersion: '0.9.9')]));
    await _pumpBanner(tester, db);
    expect(find.text('A new version is ready'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(db.close);
  });

  test('update_available and release_notes never block the app', () async {
    final container = ProviderContainer(overrides: [
      activeAnnouncementsProvider.overrideWith((ref) async => [
            _row(),
            _row(id: 'notes', severity: 'release_notes'),
          ]),
    ]);
    addTearDown(container.dispose);
    expect(await container.read(hasForceUpdateProvider.future), isFalse);
  });

  test('version targeting is inclusive and numeric', () {
    expect(compareAppVersions('1.0.10', '1.0.9'), greaterThan(0));
    expect(compareAppVersions('1.0', '1.0.0'), 0);
    expect(
        _row(maxAppVersion: kAppVersion).targetsVersion(kAppVersion), isTrue);
    expect(_row(maxAppVersion: '0.9.9').targetsVersion('1.0.0'), isFalse);
  });
}
