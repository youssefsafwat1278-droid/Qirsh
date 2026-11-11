import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'announcement_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/privacy/gated_url_launcher.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/app_card.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../data/db/sql_value_codec.dart';
import '../../domain/entities/engagement_entities.dart';
import '../common/widgets.dart';
import '../settings/settings_providers.dart';
import '../settings/settings_screen.dart';
import '../settings/widgets/settings_v2.dart';
import '../common/motion.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';

// Importing and reading are separate: a write to the local log refreshes the
// list, but cannot trigger another import. This path does no telemetry upload.
final _importShortcutHistoryProvider =
    FutureProvider.autoDispose<void>((ref) async {
  final service = ref.watch(notificationLogSyncServiceProvider);
  try {
    await service.importNativeHistory();
  } catch (_) {
    // The saved inbox remains usable if the owner changed or iOS is unavailable.
  }
});

typedef ShortcutHistoryEntry = ({String id, String kind, DateTime sentAt});

final shortcutHistoryProvider = FutureProvider.autoDispose<List<ShortcutHistoryEntry>>((ref) async {
  ref.watch(scopedRevisionProvider('notification_log_events,replica_meta'));
  final db = ref.watch(appDatabaseProvider);
  final rows = await db.customSelect(r"""
    SELECT notification_log_id, notification_type, MAX(occurred_at) AS sent_at
    FROM notification_log_events
    WHERE channel = 'ios_shortcut_local' AND event_type = 'sent'
      AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json END,
          '$._notification_origin.kind') = 'native'
      AND json_extract(CASE WHEN json_valid(payload_json) THEN payload_json END,
          '$._notification_origin.uid') =
          (SELECT owner_uid FROM replica_meta WHERE id = 1)
    GROUP BY notification_log_id, notification_type
    ORDER BY sent_at DESC
    LIMIT 80;
  """).get();
  return [
    for (final row in rows)
      (
        id: 'shortcut:${row.read<String>('notification_log_id')}',
        kind: row.read<String>('notification_type'),
        sentAt: dateTimeFromSql(row.read<String>('sent_at')),
      ),
  ];
});

class AnnouncementsScreen extends ConsumerWidget {
  const AnnouncementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final announcementsAsync = ref.watch(activeAnnouncementsProvider);
    final campaignsAsync = ref.watch(activeDashboardCampaignsProvider);
    final prefsAsync = ref.watch(notificationPreferencesProvider);
    final shortcutHistory = ref.watch(shortcutHistoryProvider);
    ref.watch(_importShortcutHistoryProvider);

    Future<void> refresh() async {
      ref.invalidate(_importShortcutHistoryProvider);
      ref.invalidate(shortcutHistoryProvider);
      ref.invalidate(activeAnnouncementsProvider);
      ref.invalidate(activeDashboardCampaignsProvider);
      ref.invalidate(notificationPreferencesProvider);
    }

    // v2 §29: QNavBar + QLargeTitle «مركز رسائل قِرش»; the empty state is
    // centred in the free area with one useful action.
    return prefsAsync.when(
      skipLoadingOnReload: true,
      loading: () => SettingsV2Page(
        title: context.l10n.annTitle,
        children: [
          const SizedBox(height: AppSpacing.s8),
          AppLoadingState(label: context.l10n.annLoading),
        ],
      ),
      error: (_, __) => SettingsV2Page(
        title: context.l10n.annTitle,
        children: [
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(
            title: context.l10n.annLoadFailed,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.annRetry,
            onRetry: () => ref.invalidate(notificationPreferencesProvider),
          ),
        ],
      ),
      data: (prefs) {
        final inbox = prefs.inboxState;
        final history = [
          ...inbox.history,
          for (final event in shortcutHistory.valueOrNull ?? const <ShortcutHistoryEntry>[])
            NotificationHistoryEntry(
              id: event.id,
              kind: event.kind,
              title: switch (event.kind) {
                'new_transaction' => context.l10n.annShortcutCaptured,
                'needs_review' => context.l10n.txnPendingReview,
                _ => context.l10n.annShortcutReceived,
              },
              body: '',
              sentAt: event.sentAt,
            ),
        ].where((entry) => !inbox.hasDismissed(entry.id));
        final announcements = (announcementsAsync.valueOrNull ?? [])
            .where((item) => !item.isForceUpdate)
            .toList();
        final campaigns = campaignsAsync.valueOrNull ?? const [];
        final items = <_MessageItem>[
          ...history.map((e) => _MessageItem.fromHistory(context, e)),
          ...campaigns.map((e) => _MessageItem.fromCampaign(context, e)),
          ...announcements
              .map((e) => _MessageItem.fromAnnouncement(context, e)),
        ]..sort((a, b) => b.sortAt.compareTo(a.sortAt));

        if (items.isEmpty && shortcutHistory.isLoading) {
          return SettingsV2Page(
            title: context.l10n.annTitle,
            children: [
              const SizedBox(height: AppSpacing.s8),
              AppLoadingState(label: context.l10n.annLoading),
            ],
          );
        }

        return SettingsV2Page(
          title: context.l10n.annTitle,
          onRefresh: refresh,
          bottomPadding: 120,
          children: [
            if (items.isEmpty)
              Padding(
                // Optical centre of the free area (≈44% from the top).
                padding: EdgeInsets.fromLTRB(AppSpacing.gutter,
                    MediaQuery.sizeOf(context).height * 0.08,
                    AppSpacing.gutter, 0),
                child: AppEmptyState(
                  icon: AppLucideIcons.bell,
                  illustration: const _SwingingBell(
                    child: QirshIllustration(
                        name: 'notifications', width: 240, height: 180),
                  ),
                  title: context.l10n.annEmpty,
                  subtitle: context.l10n.annEmptyBody,
                  primaryLabel: context.l10n.annPreferencesAction,
                  onPrimary: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const SettingsScreen(
                        page: SettingsPage.alerts,
                        showBackButton: true,
                      ),
                    ),
                  ),
                ),
              )
            else ...[
              const SizedBox(height: AppSpacing.s4),
              settingsV2Enter(
                0,
                SettingsV2Group(
                  dividerIndent: 68,
                  children: [
                    for (final item in items) _MessageCard(item: item),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              settingsV2Enter(
                1,
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                  child: AppCard(
                    child: Row(children: [
                      Expanded(
                          child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(context.l10n.setSettings,
                              style: AppTypography.caption(
                                  context.colors.actionText)),
                          const SizedBox(height: 4),
                          Text(context.l10n.annPreferencesTitle,
                              style: AppTypography.bodyStrong(
                                  context.colors.textPrimary)),
                          TextButton(
                            onPressed: () => context.push('/settings'),
                            style: TextButton.styleFrom(
                                foregroundColor: context.colors.actionText,
                                padding: EdgeInsets.zero,
                                alignment: AlignmentDirectional.centerStart),
                            child: Text(context.l10n.annPreferencesAction),
                          ),
                        ],
                      )),
                      const QirshIllustration(
                          name: 'notifications', width: 100, height: 75),
                    ]),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// v2 §29 motion: the bell swings once on enter (±10°, pivot at the top,
/// lively settle, ~700ms). Reduce Motion: still.
class _SwingingBell extends StatelessWidget {
  const _SwingingBell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (shouldReduceMotion(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 700),
      builder: (context, t, child) => Transform.rotate(
        alignment: Alignment.topCenter,
        // Two damped swings of up to 10° (0.1745 rad).
        angle: math.sin(t * math.pi * 3) * (1 - t) * 0.1745,
        child: child,
      ),
      child: child,
    );
  }
}

class _MessageCard extends ConsumerWidget {
  const _MessageCard({required this.item});

  final _MessageItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsetsDirectional.fromSTEB(16, 0, 16, 12),
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: c.textMuted,
      collapsedIconColor: c.textMuted,
      maintainState: true,
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: item.accent(c).withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.22
                  : 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(item.icon, size: 18, color: item.accent(c)),
      ),
      title: Text(item.title,
          style: AppTypography.custom(
              size: 14.5,
              weight: FontWeight.w600,
              height: 1.4,
              color: c.textPrimary)),
      subtitle: Text('${item.dateLabel(context)} · ${item.badge}',
          style: AppTypography.caption(c.textMuted)),
      children: [
        if (item.body.trim().isNotEmpty)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child:
                Text(item.body, style: AppTypography.callout(c.textSecondary)),
          ),
        if (item.actionLabel != null || item.dismissible) ...[
          const SizedBox(height: 8),
          Row(children: [
            if (item.actionLabel != null)
              TextButton.icon(
                onPressed: () => _openAction(context, item),
                icon: const Icon(AppLucideIcons.externalLink, size: 16),
                label: Text(item.actionLabel!),
              ),
            const Spacer(),
            if (item.dismissible)
              TextButton(
                onPressed: () => _dismiss(ref, item),
                child: Text(context.l10n.txnHide),
              ),
          ]),
        ],
      ],
    );
  }

  Future<void> _dismiss(WidgetRef ref, _MessageItem item) async {
    if (item.source == _MessageSource.announcement) {
      await ref.read(announcementServiceProvider).dismiss(item.id);
      ref.invalidate(activeAnnouncementsProvider);
      return;
    }
    await ref.read(growthCampaignServiceProvider).dismiss(item.id);
    ref.invalidate(activeDashboardCampaignsProvider);
    ref.invalidate(notificationPreferencesProvider);
  }

  void _openAction(BuildContext context, _MessageItem item) {
    final route = item.route?.trim();
    if (route != null && route.isNotEmpty) {
      context.push(route);
      return;
    }
    final url = item.url?.trim();
    if (url != null && url.isNotEmpty) {
      launchExternalUrl(Uri.parse(url));
    }
  }
}

enum _MessageSource { history, campaign, announcement }

class _MessageItem {
  const _MessageItem({
    required this.id,
    required this.source,
    required this.title,
    required this.body,
    required this.badge,
    required this.sortAt,
    required this.icon,
    required this.accent,
    this.route,
    this.url,
    this.actionLabel,
    this.dismissible = false,
  });

  final String id;
  final _MessageSource source;
  final String title;
  final String body;
  final String badge;
  final DateTime sortAt;
  final IconData icon;
  final Color Function(AppColors c) accent;
  final String? route;
  final String? url;
  final String? actionLabel;
  final bool dismissible;

  /// UX-031 — the date, said accurately for what each source actually records.
  ///
  /// `sortAt` is not one kind of instant. For a delivered notification it is
  /// `sentAt` — genuinely when the user received it. For a campaign or an
  /// announcement it is `validFrom` — when the item BEGAN being shown, which is
  /// not the same claim. Printing one undifferentiated timestamp would date a
  /// server-side publication window as though it were a delivery.
  String dateLabel(BuildContext context) {
    final date = Formatters.dateGroupLabel(sortAt, context);
    return switch (source) {
      _MessageSource.history => date,
      _MessageSource.campaign ||
      _MessageSource.announcement =>
        context.l10n.annFromDate(date),
    };
  }

  static _MessageItem fromHistory(
      BuildContext context, NotificationHistoryEntry entry) {
    return _MessageItem(
      id: entry.id,
      source: _MessageSource.history,
      title: entry.title,
      body: entry.body,
      badge: context.l10n.annNotificationSent,
      sortAt: entry.sentAt,
      icon: AppLucideIcons.bellRing,
      accent: (c) => c.primary,
      route: entry.route,
      actionLabel: entry.route == null ? null : context.l10n.annOpen,
      dismissible: true,
    );
  }

  static _MessageItem fromCampaign(
      BuildContext context, RemoteGrowthCampaign campaign) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return _MessageItem(
      id: campaign.id,
      source: _MessageSource.campaign,
      title: en ? campaign.titleEn : campaign.titleAr,
      body: (en ? campaign.bodyEn : campaign.bodyAr) ?? '',
      badge: context.l10n.annInAppCampaign,
      sortAt: campaign.validFrom,
      icon: AppLucideIcons.megaphone,
      accent: (c) => c.cta,
      route: campaign.actionRoute,
      url: campaign.actionUrl,
      actionLabel: en ? campaign.actionLabelEn : campaign.actionLabelAr,
      dismissible: campaign.isDismissible,
    );
  }

  static _MessageItem fromAnnouncement(
      BuildContext context, RemoteAnnouncement announcement) {
    final en = Localizations.localeOf(context).languageCode == 'en';
    return _MessageItem(
      id: announcement.id,
      source: _MessageSource.announcement,
      title: en ? announcement.titleEn : announcement.titleAr,
      body: (en ? announcement.bodyEn : announcement.bodyAr) ?? '',
      badge: context.l10n.annFromQirsh,
      sortAt: announcement.validFrom,
      icon: AppLucideIcons.badgeAlert,
      accent: (c) => switch (announcement.severity) {
        'warning' => c.warning,
        'maintenance' => c.accent,
        _ => c.cta,
      },
      url: announcement.actionUrl,
      // Was `announcement.actionLabelAr`, one line below two that chose by
      // locale correctly.
      actionLabel: announcement.actionLabelFor(context),
      dismissible: announcement.isDismissible,
    );
  }
}
