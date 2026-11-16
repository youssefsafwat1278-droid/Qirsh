import 'package:flutter/material.dart';

import '../../announcements/announcement_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/backend/app_version.dart';
import '../../../core/privacy/gated_url_launcher.dart';
import '../../onboarding/force_update_screen.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../common/app_avatar.dart';
import '../../common/app_button.dart';
import '../../../data/catalog/catalog_daos.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/l10n_ext.dart';

class AnnouncementBanner extends ConsumerWidget {
  const AnnouncementBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaignsAsync = ref.watch(activeDashboardCampaignsProvider);
    final campaigns = campaignsAsync.valueOrNull ?? [];

    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final announcements = announcementsAsync.valueOrNull
            ?.where((a) =>
                !a.isForceUpdate &&
                !a.isDismissed &&
                !a.isReleaseNotes &&
                (!a.isUpdateAvailable || a.targetsVersion(kAppVersion)))
            .toList() ??
        [];

    final allItems = <Widget>[
      for (final c in campaigns) _CampaignBannerTile(campaign: c),
      for (final a in announcements) _BannerTile(announcement: a),
    ];

    if (allItems.isEmpty) return const SizedBox.shrink();

    // UX-032 — the banner carried horizontal padding and no bottom margin, so
    // with an announcement active it sat flush against the smart-inbox card
    // below it («1 عملية في انتظار مراجعتك») and the two read as one merged
    // blob. The operator's rule, adopted verbatim: **no widget may intrude into
    // another widget.**
    //
    // The margin lives HERE rather than at the Home call site because this
    // widget collapses to `SizedBox.shrink()` when there is nothing to show. A
    // spacer added beside it on Home would leave a permanent gap on the far
    // more common no-announcement screen — trading one rhythm defect for
    // another. Placing it inside means the space exists exactly when the banner
    // does, at every announcement length and in both the single and scrolling
    // layouts.
    if (allItems.length == 1) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          0,
          AppSpacing.gutter,
          AppSpacing.s4,
        ),
        child: allItems.first,
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        AppSpacing.s4,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: allItems.asMap().entries.map((entry) {
          final isLast = entry.key == allItems.length - 1;
          return Padding(
            padding:
                EdgeInsetsDirectional.only(end: isLast ? 0 : AppSpacing.s3),
            child: SizedBox(
              width: MediaQuery.of(context).size.width -
                  (AppSpacing.gutter * 2) -
                  24,
              child: entry.value,
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _CampaignBannerTile extends ConsumerStatefulWidget {
  const _CampaignBannerTile({required this.campaign});

  final RemoteGrowthCampaign campaign;

  @override
  ConsumerState<_CampaignBannerTile> createState() =>
      _CampaignBannerTileState();
}

class _CampaignBannerTileState extends ConsumerState<_CampaignBannerTile> {
  bool _recorded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_recorded) return;
    _recorded = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(growthCampaignServiceProvider)
          .recordImpression(widget.campaign.id)
          .then((_) => ref.invalidate(activeDashboardCampaignsProvider));
    });
  }

  @override
  Widget build(BuildContext context) {
    return _CompactAnnouncementTile(
      title: widget.campaign.titleFor(context),
      body: widget.campaign.bodyFor(context)?.trim(),
      actionLabel: widget.campaign.actionLabelFor(context)?.trim(),
      icon: AppLucideIcons.sparkles,
      iconColor: context.colors.primary,
      onTap: () => _handleTap(context),
      dismiss: widget.campaign.isDismissible
          ? _CampaignDismissButton(campaignId: widget.campaign.id)
          : null,
    );
  }

  void _handleTap(BuildContext context) {
    final route = widget.campaign.actionRoute?.trim();
    if (route != null && route.isNotEmpty) {
      context.push(route);
      return;
    }
    final url = widget.campaign.actionUrl?.trim();
    if (url != null && url.isNotEmpty) {
      launchExternalUrl(Uri.parse(url));
    }
  }
}

class _BannerTile extends ConsumerWidget {
  const _BannerTile({required this.announcement});

  final RemoteAnnouncement announcement;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    if (announcement.isUpdateAvailable) return _updateTile(context);
    final (icon, color) = switch (announcement.severity) {
      'warning' => (AppLucideIcons.alertTriangle, c.warning),
      'maintenance' => (AppLucideIcons.wrench, c.accent),
      _ => (AppLucideIcons.sparkles, c.primary),
    };
    return _CompactAnnouncementTile(
      title: announcement.titleFor(context),
      body: announcement.bodyFor(context)?.trim(),
      actionLabel: announcement.actionUrl != null
          ? announcement.actionLabelFor(context)?.trim()
          : null,
      icon: icon,
      iconColor: color,
      onTap: () => _handleTap(context, announcement.actionUrl),
      dismiss: announcement.isDismissible
          ? _DismissButton(announcementId: announcement.id)
          : null,
    );
  }

  /// Optional update: always dismissible (even if the row says otherwise, it
  /// must never trap anyone) and always offers the App Store.
  Widget _updateTile(BuildContext context) {
    final url = announcement.actionUrl?.trim();
    final storeUrl =
        url == null || url.isEmpty ? ForceUpdateScreen.appStoreUrl : url;
    final label = announcement.actionLabelFor(context)?.trim();
    return _CompactAnnouncementTile(
      title: announcement.titleFor(context),
      body: announcement.bodyFor(context)?.trim(),
      actionLabel: label == null || label.isEmpty
          ? context.l10n.updateAvailableAction
          : label,
      icon: AppLucideIcons.download,
      iconColor: context.colors.primary,
      onTap: () => launchExternalUrl(Uri.parse(storeUrl)),
      dismiss: _DismissButton(announcementId: announcement.id),
      prominentAction: true,
    );
  }

  void _handleTap(BuildContext context, String? url) {
    if (url == null || url.trim().isEmpty) {
      context.push('/announcements');
      return;
    }
    if (url.startsWith('/')) {
      context.push(url);
      return;
    }
    launchExternalUrl(Uri.parse(url));
  }
}

/// The approved compact, neutral announcement card. Severity colours its
/// glyph; the complete localized message and existing destination stay intact.
class _CompactAnnouncementTile extends StatelessWidget {
  const _CompactAnnouncementTile({
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.icon,
    required this.iconColor,
    required this.onTap,
    required this.dismiss,
    this.prominentAction = false,
  });

  final String title;
  final String? body;
  final String? actionLabel;
  final IconData icon;
  final Color iconColor;
  final VoidCallback onTap;
  final Widget? dismiss;

  /// The action is the point of the card (an optional update): a compact
  /// primary button instead of the quiet text link.
  final bool prominentAction;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MaliCard(
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppAvatar.icon(
                icon: icon,
                color: iconColor,
                tone: AppAvatarTone.soft,
                size: 36),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: AppTypography.custom(
                          size: 14,
                          weight: FontWeight.w600,
                          height: 1.4,
                          color: c.textMain)),
                  if (body?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 3),
                    Text(body!, style: AppTypography.caption(c.textLight)),
                  ],
                  if (prominentAction && (actionLabel?.isNotEmpty ?? false))
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.s3),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: AppPrimaryButton(
                          label: actionLabel!,
                          onTap: onTap,
                          height: 40,
                        ),
                      ),
                    )
                  else if (actionLabel?.isNotEmpty ?? false)
                    TextButton(
                      onPressed: onTap,
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        alignment: AlignmentDirectional.centerStart,
                        minimumSize: const Size(44, 36),
                      ),
                      child: Text(actionLabel!,
                          style: AppTypography.caption(c.primary)
                              .copyWith(fontWeight: FontWeight.w600)),
                    ),
                ],
              ),
            ),
            if (dismiss != null) ...[
              const SizedBox(width: AppSpacing.s2),
              dismiss!,
            ],
          ],
        ),
      ),
    );
  }
}

class _DismissButton extends ConsumerWidget {
  const _DismissButton({required this.announcementId});

  final String announcementId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox.square(
      dimension: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: context.colors.surface2,
          foregroundColor: context.colors.textMain,
          shape: const CircleBorder(),
        ),
        onPressed: () =>
            ref.read(announcementServiceProvider).dismiss(announcementId).then(
                  (_) => ref.invalidate(activeAnnouncementsProvider),
                ),
        icon: const Icon(AppLucideIcons.x, size: 18),
        tooltip: context.l10n.commonHide,
      ),
    );
  }
}

class _CampaignDismissButton extends ConsumerWidget {
  const _CampaignDismissButton({required this.campaignId});

  final String campaignId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SizedBox.square(
      dimension: 34,
      child: IconButton(
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: context.colors.surface2,
          foregroundColor: context.colors.textMain,
          shape: const CircleBorder(),
        ),
        onPressed: () => ref
            .read(growthCampaignServiceProvider)
            .dismiss(campaignId)
            .then((_) => ref.invalidate(activeDashboardCampaignsProvider)),
        icon: const Icon(AppLucideIcons.x, size: 18),
        tooltip: context.l10n.commonHide,
      ),
    );
  }
}
