import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Server-authored rows carry BOTH `*Ar` and `*En`. A widget that reads the
/// `*Ar` field directly shows Arabic to an English reader, and no ARB check can
/// see it: the strings are not in the ARB at all, they are database columns.
///
/// Four surfaces did exactly that, and the worst of them blocked the whole app:
/// `ForceUpdateScreen` read `titleAr`, `bodyAr` AND `actionLabelAr`, so its
/// English and Arabic captures came back byte-for-byte identical. The dashboard
/// announcement banner did the same for both announcements and campaigns, and
/// `AnnouncementsScreen.fromAnnouncement` read `actionLabelAr` on the line
/// directly below two that chose by locale correctly.
///
/// None of it ever reached the bilingual walk, because the QA catalog seeds
/// zero announcements. The surfaces rendered empty, so there was no copy to
/// measure and nothing to report — "0 untranslated strings" was true and said
/// nothing about any of them.
///
/// `core/i18n/bilingual_copy.dart` is where the locale choice belongs: widgets
/// call `titleFor(context)` through the adapter in
/// `features/announcements/announcement_text.dart`, and code with no element
/// tree calls `titleIn(languageCode)` directly.
///
/// `notification_journey_service.dart` was the last exemption to this rule and
/// held it for a reason that expired: it composes campaign notifications with
/// no `BuildContext`, so there was nowhere context-free to make the choice. It
/// was also unreachable as a defect while English was — English shipped
/// complete and with no way for a user to select it. Settings → Language ended
/// both, so the exemption is gone and the file resolves campaign copy from
/// `user_settings.language`.
void main() {
  /// Files allowed to name the Arabic column directly.
  const allowed = <String>{
    // The extension that makes the choice.
    'lib/features/announcements/announcement_text.dart',
    // The DAO that defines and parses the columns.
    'lib/data/catalog/catalog_daos.dart',
    // Chooses inline with an explicit `en ?` on every line; correct, and left
    // alone rather than refactored.
    'lib/features/announcements/announcements_screen.dart',
  };

  test('no widget reads the Arabic column of a bilingual server row', () {
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (allowed.contains(file.path)) continue;
      if (file.path.startsWith('lib/l10n/')) continue;

      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        // The defect shape: reading `.titleAr` / `.bodyAr` / `.actionLabelAr`
        // off a row, without an `en ?` on the same line choosing it.
        // `this.titleAr` in a constructor is a DECLARATION, not a read —
        // `CouponOffer` tripped the first version of this rule that way.
        final readsArabic =
            RegExp(r'(?<!this)\.(titleAr|bodyAr|actionLabelAr)\b')
                .hasMatch(line);
        if (!readsArabic) continue;
        if (line.contains('en ?') || line.contains("== 'en'")) continue;
        offenders.add('${file.path}:${i + 1}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'these show Arabic server copy to an English reader. Use the '
            'titleFor/bodyFor/actionLabelFor extensions in '
            'features/announcements/announcement_text.dart: '
            '${offenders.join(", ")}');
  });

  test('text alignment follows locale except exact approved photo copy', () {
    // `TextAlign.right` is what an Arabic-only app writes when it means
    // "start". Under English it right-aligns body copy, and on the welcome
    // story it also pushed the text into the halftone illustration, leaving
    // words unreadable on the first screen a new user sees.
    // Approved HTML photo copy stays on the physical right of an unmirrored
    // photograph/scrim in AR and EN. These exact eight statements are the
    // complete exception; other copy in these files must still follow locale.
    // qirsh_visuals_test.dart asserts the actual physical position in both directions.
    const approvedPhotoCopy = <String, Set<String>>{
      'lib/core/theme/widgets/calm_page_header.dart': {
        "if (label != null) Text(label!, textAlign: TextAlign.right,",
        "]), textAlign: TextAlign.right),",
        // The budget's remaining/deadline line belongs to the same approved
        // physical-right photo overlay as its label and amount above it.
        "Text(footnote!, textAlign: TextAlign.right,",
      },
    };
    final approvedUses = <String, int>{};
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      // The PDF renderer's one use is a fixed-width numeric column, where
      // right-alignment is a typographic choice rather than a direction; a PDF
      // also has no Directionality to inherit from.
      if (file.path.endsWith('pdf/report_pdf_renderer.dart')) continue;
      final source = file
          .readAsLinesSync()
          .where((line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      String compact(String value) => value.replaceAll(RegExp(r'\s+'), '');
      final normalized = compact(source);
      var approvedCount = 0;
      for (final statement in approvedPhotoCopy[file.path] ?? <String>{}) {
        final count = RegExp(RegExp.escape(compact(statement)))
            .allMatches(normalized)
            .length;
        approvedUses['${file.path}:$statement'] = count;
        approvedCount += count;
      }
      final total = RegExp(r'(?<!pw\.)TextAlign\.(right|left)\b')
          .allMatches(source)
          .length;
      if (total != approvedCount) offenders.add(file.path);
    }
    for (final entry in approvedPhotoCopy.entries) {
      for (final statement in entry.value) {
        expect(approvedUses['${entry.key}:$statement'], 1,
            reason: 'each named photo exception must exist exactly once; stale '
                'or duplicated exceptions require a design review');
      }
    }
    expect(offenders, isEmpty,
        reason: 'use TextAlign.start / TextAlign.end, which follow the '
            'reader direction: ${offenders.join(", ")}');
  });

  test('no picker pins its own locale', () {
    // `showDatePicker(locale: const Locale('ar'))` at two of eleven call sites
    // — the goal deadline and the manual-transaction date. An English user
    // tapping "Deadline" got a fully Arabic calendar over a visibly English
    // app: «اختيار التاريخ», Arabic weekday headers, Eastern Arabic numerals,
    // «الإلغاء»/«حسنًا», laid out right-to-left. The other nine call sites
    // inherited the app locale and were correct, so the app disagreed with
    // itself depending on which date field you touched.
    //
    // A picker with no `locale` inherits from Localizations, which is the app's
    // language. `locale_provider.dart` is the one place that decides it.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      if (file.path.endsWith('core/i18n/locale_provider.dart')) continue;
      if (file.path.startsWith('lib/l10n/')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        if (RegExp(r"locale:\s*const Locale\(").hasMatch(lines[i])) {
          offenders.add('${file.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'these force one language on a picker regardless of the '
            "reader's: ${offenders.join(", ")}");
  });

  test('no widget pins a Stack child to an absolute side', () {
    // `Positioned(left:)` on a decorative element is the same mistake one layer
    // down: the welcome story pinned its illustration to the far left, which is
    // away from Arabic text and directly under English text.
    final offenders = <String>[];
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      // Only the onboarding story is pinned here today; the rule exists to keep
      // it that way rather than to sweep the whole app, which has many
      // legitimate absolute positions inside already-mirrored parents.
      if (!file.path.contains('features/onboarding/story_screen.dart')) {
        continue;
      }
      if (RegExp(r'Positioned\(\s*\n?\s*(left|right):').hasMatch(source)) {
        offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty,
        reason: 'use PositionedDirectional(start:/end:) so the layout mirrors: '
            '${offenders.join(", ")}');
  });
}
