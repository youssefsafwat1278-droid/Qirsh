import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/backend/app_version.dart';
import '../../core/privacy/gated_url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../announcements/announcement_text.dart';

class ForceUpdateScreen extends ConsumerWidget {
  const ForceUpdateScreen({super.key});

  /// Also the fallback of the optional update banner.
  static const appStoreUrl = 'https://apps.apple.com/app/id6785476254';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = Theme.of(context).extension<AppColors>()!;
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final announcement = announcementsAsync.valueOrNull
        ?.where((a) =>
            a.isForceUpdate &&
            (kAppVersion.isEmpty || a.targetsVersion(kAppVersion)))
        .firstOrNull;

    // The announcement's own language, not always Arabic. This screen blocks
    // the whole app, so an English reader who could not read it had no way
    // forward at all.
    final titleText = announcement?.titleFor(context) ?? context.l10n.fuTitle;
    final bodyText = announcement?.bodyFor(context) ?? context.l10n.fuBody;
    final actionUrl = announcement?.actionUrl ?? appStoreUrl;
    final actionLabel =
        announcement?.actionLabelFor(context) ?? context.l10n.fuNow;

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              Icon(AppLucideIcons.download, size: 72, color: c.primary),
              const SizedBox(height: AppSpacing.s5),
              Text(
                titleText,
                style: AppTypography.title1(c.textMain),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.s3),
              Text(
                bodyText,
                style: AppTypography.body(c.textLight),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              FilledButton(
                onPressed: () => launchExternalUrl(
                  Uri.parse(actionUrl),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: c.cta,
                  minimumSize: const Size.fromHeight(52),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: AppTypography.bodyStrong(Colors.white),
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
            ],
          ),
        ),
      ),
    );
  }
}
