import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/backend/app_version.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/l10n_ext.dart';
import '../announcements/announcement_text.dart';
import '../settings/widgets/settings_v2.dart';
import 'release_notes.dart';

/// Settings → What's new. Server `release_notes` announcements (already in
/// Drift when Cloud is ON) sit above the notes bundled in the app.
class WhatsNewScreen extends ConsumerWidget {
  const WhatsNewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final language = Localizations.localeOf(context).languageCode;
    final server = (ref.watch(activeAnnouncementsProvider).valueOrNull ?? [])
        .where((a) =>
            a.isReleaseNotes && !a.isDismissed && a.targetsVersion(kAppVersion))
        .toList();
    final bundled = ref.watch(bundledReleaseNotesProvider);

    return SettingsV2Page(
      title: l10n.whatsNewTitle,
      subtitle: l10n.whatsNewSubtitle,
      children: [
        if (server.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.s4),
          SettingsV2Group(label: l10n.whatsNewFromQirsh, children: [
            for (final a in server)
              WhatsNewNote(
                  text: a.titleFor(context), detail: a.bodyFor(context)),
          ]),
        ],
        ...switch (bundled) {
          AsyncData(:final value) => [
              for (final release in value) ...[
                const SizedBox(height: AppSpacing.s4),
                SettingsV2Group(
                  label: l10n.whatsNewVersion(release.version),
                  dividerIndent: AppSpacing.s4,
                  children: [
                    for (final note in release.forLanguage(language))
                      WhatsNewNote(text: note),
                  ],
                ),
              ],
            ],
          AsyncError() => [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.gutter),
                child: Text(l10n.whatsNewUnavailable,
                    style: AppTypography.callout(context.colors.textSecondary)),
              ),
            ],
          _ => const <Widget>[],
        },
      ],
    );
  }
}

/// One release-note line (also used by the one-time sheet).
class WhatsNewNote extends StatelessWidget {
  const WhatsNewNote({super.key, required this.text, this.detail});

  final String text;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final more = detail?.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text, style: AppTypography.callout(c.textPrimary)),
          if (more != null && more.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(more, style: AppTypography.caption(c.textSecondary)),
          ],
        ],
      ),
    );
  }
}
