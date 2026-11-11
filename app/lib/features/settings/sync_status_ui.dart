import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart' show syncRecoveryServiceProvider;
import '../../core/sync/sync_status.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/app_avatar.dart';
import 'sync_status_providers.dart';
import '../../core/theme/widgets/glass_sheet.dart';

/// A-5: the single compact "did my data reach the cloud?" row. Quiet by design —
/// it only reports; it never banners or toasts on a change. Tapping opens
/// [showSyncStatusSheet].
class SyncStatusTile extends ConsumerWidget {
  const SyncStatusTile({super.key, this.banner = false});

  /// v2 «بيانات حسابك»: the same status as a tinted card on the canvas
  /// (infoBg when nothing is wrong) instead of a row inside a group.
  final bool banner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keep rendering the last value during a recompute so the row never flickers.
    final status = ref.watch(syncStatusProvider).valueOrNull;
    if (status == null) return const SizedBox.shrink();
    final c = context.colors;
    final (icon, color) = switch (status.kind) {
      SyncStatusKind.allSynced => (AppLucideIcons.checkCircle, c.success),
      SyncStatusKind.syncing => (AppLucideIcons.refreshCw, c.primary),
      SyncStatusKind.waiting => (AppLucideIcons.cloud, c.accent),
      SyncStatusKind.consentOff => (AppLucideIcons.cloudOff, c.textLight),
      SyncStatusKind.signedOut => (AppLucideIcons.cloudOff, c.textLight),
      SyncStatusKind.failed => (AppLucideIcons.alertTriangle, c.danger),
      SyncStatusKind.needsAttention => (AppLucideIcons.alertTriangle, c.accent),
    };
    if (banner) {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final (Color bg, Color accent) = switch (status.kind) {
        SyncStatusKind.allSynced => (c.successBg, c.success),
        SyncStatusKind.failed => (c.dangerBg, c.danger),
        SyncStatusKind.needsAttention ||
        SyncStatusKind.waiting => (c.warningBg, c.warning),
        _ => (c.infoBg, c.info),
      };
      return Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, 0, AppSpacing.gutter, 0),
        child: Material(
          color: bg,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.card),
            side: isDark
                ? BorderSide(color: accent.withValues(alpha: 0.24))
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const ValueKey('sync-status-tile'),
            splashFactory: NoSplash.splashFactory,
            onTap: () => showSyncStatusSheet(context),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                  AppSpacing.s4, AppSpacing.s3 + 2, AppSpacing.s3,
                  AppSpacing.s3 + 2),
              child: Row(children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: isDark ? 0.22 : 0.16),
                    borderRadius: BorderRadius.circular(AppRadius.control),
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: Text(syncStatusLabel(context, status),
                      style: AppTypography.subhead(c.textPrimary)),
                ),
                DirectionalChevron(color: c.textMuted, size: 18),
              ]),
            ),
          ),
        ),
      );
    }
    return ListTile(
      key: const ValueKey('sync-status-tile'),
      visualDensity: VisualDensity.compact,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: AppSpacing.s4, vertical: 2),
      minVerticalPadding: AppSpacing.s2,
      leading: AppAvatar.icon(
          icon: icon, color: color, tone: AppAvatarTone.soft),
      title: Text(syncStatusLabel(context, status),
          style: AppTypography.subhead(c.textMain)),
      trailing: DirectionalChevron(color: c.textMuted, size: 20),
      onTap: () => showSyncStatusSheet(context),
    );
  }
}

/// One-line human copy for a [SyncStatus].
String syncStatusLabel(BuildContext context, SyncStatus status) {
  final l10n = context.l10n;
  return switch (status.kind) {
    SyncStatusKind.allSynced => l10n.syncStatusAllSynced,
    SyncStatusKind.syncing => l10n.syncStatusSyncing,
    SyncStatusKind.waiting => l10n.syncStatusWaiting(status.count),
    SyncStatusKind.consentOff => l10n.syncStatusConsentOff,
    SyncStatusKind.signedOut => l10n.syncStatusSignedOut,
    SyncStatusKind.failed => l10n.syncStatusFailed,
    SyncStatusKind.needsAttention => l10n.syncStatusNeedsAttention,
  };
}

Future<void> showSyncStatusSheet(BuildContext context) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => navySheetTheme(const SyncStatusSheet()),
  );
}

class SyncStatusSheet extends ConsumerStatefulWidget {
  const SyncStatusSheet({super.key});

  @override
  ConsumerState<SyncStatusSheet> createState() => _SyncStatusSheetState();
}

class _SyncStatusSheetState extends ConsumerState<SyncStatusSheet> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      await ref.read(syncRecoveryServiceProvider).retryNow();
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final status = ref.watch(syncStatusProvider).valueOrNull;
    final last = status?.lastSuccessAt;
    Widget row(String label, int n) => Padding(
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.s1),
          child: Row(children: [
            Expanded(
                child: Text(label, style: AppTypography.subhead(c.textMain))),
            Text('$n', style: AppTypography.bodyStrong(c.textMain)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncSheetTitle,
              style: AppTypography.sectionTitle(c.textMain)),
          const SizedBox(height: AppSpacing.s2),
          if (status != null) ...[
            Text(syncStatusLabel(context, status),
                style: AppTypography.subhead(c.textLight)),
            const SizedBox(height: AppSpacing.s3),
            if (status.kind == SyncStatusKind.consentOff ||
                status.kind == SyncStatusKind.signedOut)
              Text(l10n.syncSheetKeptOnDevice(status.count),
                  style: AppTypography.caption(c.textLight))
            else ...[
              if (status.waitingForConnection > 0)
                row(l10n.syncSheetWaitingConnection,
                    status.waitingForConnection),
              if (status.waitingForServer > 0)
                row(l10n.syncSheetWaitingServer, status.waitingForServer),
              if (status.needsAttention > 0)
                row(l10n.syncSheetNeedsAttention, status.needsAttention),
              if (status.stayFailed > 0)
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s1),
                  child: Text(l10n.syncSheetStayFailed(status.stayFailed),
                      style: AppTypography.caption(c.textLight)),
                ),
            ],
          ],
          const SizedBox(height: AppSpacing.s3),
          Text(
            last == null
                ? l10n.syncSheetNeverSynced
                : l10n.syncSheetLastSync(
                    '${Formatters.fullDate(last, context)} '
                    '${Formatters.time(last, context)}'),
            style: AppTypography.caption(c.textLight),
          ),
          if (status != null && status.canRetry) ...[
            const SizedBox(height: AppSpacing.s4),
            SizedBox(
              height: AppSpacing.buttonHeight,
              child: FilledButton(
                key: const ValueKey('sync-retry-button'),
                onPressed: _retrying ? null : _retry,
                child: Text(l10n.syncSheetRetry),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
