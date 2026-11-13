import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/onboarding/shortcut_guide_video.dart';
import 'package:money_companion/l10n/app_localizations.dart';

void main() {
  test('both language videos are bundled', () {
    for (final code in ['ar', 'en']) {
      final file = File(ShortcutGuideVideo.assetFor(code));
      expect(file.existsSync(), isTrue, reason: file.path);
      expect(file.lengthSync(), lessThan(3 * 1024 * 1024));
    }
    expect(ShortcutGuideVideo.assetFor('fr'),
        ShortcutGuideVideo.assetFor('en'));
  });

  testWidgets('shows a play row and loads nothing until tapped',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      locale: const Locale('en'),
      localizationsDelegates: AppL10n.localizationsDelegates,
      supportedLocales: AppL10n.supportedLocales,
      home: const Scaffold(body: ShortcutGuideVideo()),
    ));
    await tester.pump();
    expect(find.byKey(const Key('shortcutVideoPlay')), findsOneWidget);
    expect(find.text('Watch the video guide'), findsOneWidget);
    expect(find.byKey(const Key('shortcutVideoSurface')), findsNothing);
  });
}
