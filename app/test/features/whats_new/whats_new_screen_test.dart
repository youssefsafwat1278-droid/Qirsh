import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/app_version.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/features/whats_new/release_notes.dart';
import 'package:money_companion/features/whats_new/whats_new_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

final _from = DateTime.utc(2026, 1, 1);
RemoteAnnouncement _serverNotes() => RemoteAnnouncement(
      id: 'notes',
      titleAr: 'ملاحظة من الخادم',
      titleEn: 'Server note',
      bodyAr: null,
      bodyEn: null,
      severity: 'release_notes',
      minAppVersion: null,
      maxAppVersion: null,
      actionLabelAr: null,
      actionLabelEn: null,
      actionUrl: null,
      validFrom: _from,
      validUntil: null,
      isDismissible: true,
      priority: 0,
      isDismissed: false,
      dismissedAt: null,
      syncedAt: _from,
    );

Future<void> _pump(WidgetTester tester, String language,
    List<RemoteAnnouncement> server) async {
  tester.view.physicalSize = const Size(390, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      // Drift only — the page never touches the network.
      activeAnnouncementsProvider.overrideWith((ref) async => server),
    ],
    child: MaterialApp(
      theme: AppTheme.light,
      locale: Locale(language),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: const WhatsNewScreen(),
    ),
  ));
  // The bundled asset loads through the real asset bundle.
  await tester
      .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

void main() {
  final asset = jsonDecode(File(kReleaseNotesAsset).readAsStringSync())
      as Map<String, Object?>;
  final releases = (asset['releases'] as List).cast<Map<String, Object?>>();
  // rootBundle caches the load future inside the previous test's fake zone.
  setUp(() => rootBundle.evict(kReleaseNotesAsset));

  test('the bundled notes cover the running version in both languages', () {
    final current = releases.firstWhere((r) => r['version'] == kAppVersion);
    expect((current['ar'] as List), isNotEmpty);
    expect((current['ar'] as List).length, (current['en'] as List).length);
    expect(releases.first['version'], kAppVersion,
        reason: 'newest release first');
  });

  for (final language in ['ar', 'en']) {
    testWidgets('renders the bundled notes in $language without a network',
        (tester) async {
      await _pump(tester, language, const []);
      final l10n = AppL10n.of(tester.element(find.byType(WhatsNewScreen)));
      expect(find.text(l10n.whatsNewTitle), findsWidgets);
      expect(find.text(l10n.whatsNewVersion(kAppVersion)), findsOneWidget);
      final current = releases.firstWhere((r) => r['version'] == kAppVersion);
      for (final note in (current[language] as List).cast<String>()) {
        expect(find.text(note), findsOneWidget, reason: note);
      }
      expect(find.text(l10n.whatsNewFromQirsh), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('server release_notes show above the bundled notes',
      (tester) async {
    await _pump(tester, 'en', [_serverNotes()]);
    expect(find.text('From the Qirsh team'), findsOneWidget);
    final server = tester.getTopLeft(find.text('Server note')).dy;
    final bundled = tester.getTopLeft(find.text('Version $kAppVersion')).dy;
    expect(server, lessThan(bundled));
  });
}
