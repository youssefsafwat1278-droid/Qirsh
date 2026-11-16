import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/backend/app_version.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/utils/l10n_ext.dart';
import 'release_notes.dart';
import 'whats_new_screen.dart';

/// The one-time sheet after an update: the bundled notes of the running
/// version. Returns false (and shows nothing) when there are none.
Future<bool> showWhatsNewSheet(BuildContext context) async {
  final List<ReleaseNotes> releases;
  try {
    releases = await loadBundledReleaseNotes();
  } catch (_) {
    return false;
  }
  final current = releases.where((r) => r.version == kAppVersion).firstOrNull;
  if (current == null || !context.mounted) return false;
  final notes =
      current.forLanguage(Localizations.localeOf(context).languageCode);
  if (notes.isEmpty) return false;
  await showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) {
      final c = sheetContext.colors;
      final l10n = sheetContext.l10n;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
              AppSpacing.s2, AppSpacing.s2, AppSpacing.s2, AppSpacing.s4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: Text(l10n.whatsNewSheetTitle(kAppVersion),
                    style: AppTypography.sectionTitle(c.textPrimary)),
              ),
              const SizedBox(height: AppSpacing.s2),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(children: [
                    for (final note in notes) WhatsNewNote(text: note),
                  ]),
                ),
              ),
              const SizedBox(height: AppSpacing.s3),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                child: FilledButton(
                  onPressed: () => Navigator.of(sheetContext).pop(),
                  child: Text(l10n.gotIt),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  if (context.mounted) context.push('/whats-new');
                },
                child: Text(l10n.whatsNewSeeAll),
              ),
            ],
          ),
        ),
      );
    },
  );
  return true;
}
