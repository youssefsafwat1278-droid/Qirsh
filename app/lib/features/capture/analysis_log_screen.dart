import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/smart_analysis_consent.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/l10n_ext.dart';
import '../../data/repositories/analysis_log_repository.dart';
import '../../domain/capture/analysis_outcome.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../common/app_empty_state.dart';
import '../common/app_loading_state.dart';
import '../settings/settings_providers.dart';
import '../settings/widgets/settings_v2.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_screen.dart' show SmartInboxCard;
import 'services/capture_receipts.dart';
import 'services/native_capture_bridge.dart';
import 'services/outcome_notification_content.dart';

/// The captures still queued on this device: their analysis has not run yet.
/// Only the replica owner's (the data this app shows); never another user's.
final analysisLogQueueProvider =
    Provider<Future<List<SharedCapturedMessage>> Function()>((ref) {
  final db = ref.watch(appDatabaseProvider);
  return () async {
    try {
      final owner = await replicaOwnerUid(db);
      if (owner == null) return const [];
      return [
        for (final m in await NativeCaptureBridge.peekPendingSharedMessages())
          if (m.ownerUid == owner && (m.id?.trim().isNotEmpty ?? false)) m,
      ];
    } catch (_) {
      return const [];
    }
  };
});

/// Every captured bank message, newest first, with its outcome.
final analysisLogProvider =
    FutureProvider.autoDispose<List<AnalysisLogEntry>>((ref) async {
  ref.watch(dbRevisionProvider);
  final imported =
      await AnalysisLogRepository(ref.watch(appDatabaseProvider)).recent();
  final done = {for (final e in imported) e.payloadId};
  final waiting = [
    for (final m in await ref.watch(analysisLogQueueProvider)())
      if (!done.contains(m.id!.trim()))
        AnalysisLogEntry(
          payloadId: m.id!.trim(),
          at: (m.receivedAt ?? DateTime.now()).toUtc(),
          state: AnalysisOutcomeState.awaiting,
          text: m.text,
        ),
  ];
  return [...waiting, ...imported]..sort((a, b) => b.at.compareTo(a.at));
});

/// «سجل التحليل»: every captured bank message and what became of it — saved,
/// not added (with the reason), needs your confirmation, or awaiting
/// analysis. Reached from the transactions header and the Smart Inbox.
class AnalysisLogScreen extends ConsumerWidget {
  const AnalysisLogScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const AnalysisLogScreen()));

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final entries = ref.watch(analysisLogProvider);
    return SettingsV2Page(
      title: l10n.analysisLogTitle,
      onRefresh: () async => ref.invalidate(analysisLogProvider),
      children: [
        entries.when(
          // A background sync bumps the DB revision and reloads the list:
          // keep the rows on screen instead of flashing the spinner.
          skipLoadingOnReload: true,
          loading: () => const Padding(
            padding: EdgeInsets.only(top: AppSpacing.s8),
            child: AppLoadingState(),
          ),
          error: (_, __) => _empty(context),
          data: (list) =>
              list.isEmpty ? _empty(context) : AnalysisLogList(entries: list),
        ),
      ],
    );
  }

  Widget _empty(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s8),
        child: AppEmptyState(
          icon: AppLucideIcons.inbox,
          title: context.l10n.analysisLogEmpty,
          subtitle: '',
        ),
      );
}

/// The log's rows (separate from the page so it is testable on its own),
/// grouped by day in cards like the transactions list.
class AnalysisLogList extends StatelessWidget {
  const AnalysisLogList({super.key, required this.entries});

  final List<AnalysisLogEntry> entries;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final groups = <String, List<AnalysisLogEntry>>{};
    for (final e in entries) {
      groups
          .putIfAbsent(Formatters.dateGroupLabel(e.at.toLocal(), context),
              () => [])
          .add(e);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in groups.entries) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(4, AppSpacing.s3, 4, AppSpacing.s2),
              child: Text(group.key, style: AppTypography.caption(c.textMuted)),
            ),
            Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.border),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < group.value.length; i++) ...[
                    if (i > 0) Divider(height: 1, indent: 66, color: c.divider),
                    AnalysisLogTile(entry: group.value[i]),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s8),
        ],
      ),
    );
  }
}

class AnalysisLogTile extends ConsumerWidget {
  const AnalysisLogTile({super.key, required this.entry});

  final AnalysisLogEntry entry;

  /// Heading and sentence: the same words as the outcome's notification.
  ///
  /// [smartOnAwaitingLine], when given, replaces «turn on Smart Analysis» for
  /// a capture kept while it was off (or before the device knew it was on):
  /// it is on now, but that capture is never sent on its own.
  static ({String title, String body}) textOf(
      AnalysisLogEntry entry, String lang, String ignoredLine,
      {String? smartOnAwaitingLine}) {
    final content = buildOutcomeNotice(
      state: entry.state,
      reasonCode: entry.reasonCode,
      unanalysed: entry.unanalysed,
      tx: entry.transaction,
      proposal: entry.inboxItem?.proposal,
      lang: lang,
      smartAnalysisOff: entry.inboxItem != null &&
          AnalysisOutcome.awaitsSmartAnalysis(entry.inboxItem!),
    );
    final ignored = entry.transaction == null &&
        entry.inboxItem == null &&
        entry.state == AnalysisOutcomeState.notAdded;
    final keptWhileOff = entry.inboxItem != null &&
        AnalysisOutcome.awaitsSmartAnalysis(entry.inboxItem!);
    return (
      title: content.title,
      body: ignored
          ? ignoredLine
          : keptWhileOff && smartOnAwaitingLine != null
              ? smartOnAwaitingLine
              : content.body,
    );
  }

  static IconData _icon(AnalysisOutcomeState state) => switch (state) {
        AnalysisOutcomeState.saved => AppLucideIcons.check,
        AnalysisOutcomeState.notAdded => AppLucideIcons.x,
        AnalysisOutcomeState.needsConfirmation => AppLucideIcons.sparkles,
        AnalysisOutcomeState.awaiting => AppLucideIcons.clock,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final lang = Localizations.localeOf(context).languageCode;
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    final smartOn = settings != null && smartAnalysisSelected(settings);
    final text = textOf(entry, lang, context.l10n.outcomeIgnoredMessage,
        smartOnAwaitingLine:
            smartOn ? context.l10n.outcomeAwaitingSmartOnBody : null);
    final raw = entry.text?.trim();
    // Masked only: card, account and phone numbers and a person's name never
    // appear here.
    final masked = raw == null || raw.isEmpty ? null : SmsSanitizer.sanitize(raw);
    final (Color fg, Color bg) = switch (entry.state) {
      AnalysisOutcomeState.saved => (c.success, c.successBg),
      AnalysisOutcomeState.notAdded => (c.textMuted, c.surfaceMuted),
      AnalysisOutcomeState.needsConfirmation => (c.warning, c.warningBg),
      AnalysisOutcomeState.awaiting => (c.info, c.infoBg),
    };
    return InkWell(
      onTap: _onTap(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              child: Icon(_icon(entry.state), size: 18, color: fg),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(text.title,
                            style: AppTypography.bodyStrong(c.textPrimary)),
                      ),
                      const SizedBox(width: 8),
                      Text(Formatters.time(entry.at.toLocal(), context),
                          style: AppTypography.caption(c.textMuted)),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(text.body,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textSecondary)),
                  if (masked != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: c.surfaceMuted,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(masked,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption(c.textMuted)),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _onTap(BuildContext context) {
    final tx = entry.transaction;
    if (tx != null) {
      return () => TransactionDetailsScreen.showSheet(context, tx.id);
    }
    final item = entry.inboxItem;
    if (item != null) {
      return () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            backgroundColor: context.colors.surface,
            builder: (_) => navySheetTheme(Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              child: SmartInboxCard(item: item),
            )),
          );
    }
    return null;
  }
}
