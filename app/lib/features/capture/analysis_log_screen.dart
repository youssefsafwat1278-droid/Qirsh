import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../data/repositories/analysis_log_repository.dart';
import '../../domain/capture/analysis_outcome.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../common/app_empty_state.dart';
import '../common/app_loading_state.dart';
import '../settings/widgets/settings_v2.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_screen.dart' show SmartInboxCard;
import 'services/capture_notification_content.dart';
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

/// The log's rows (separate from the page so it is testable on its own).
class AnalysisLogList extends StatelessWidget {
  const AnalysisLogList({super.key, required this.entries});

  final List<AnalysisLogEntry> entries;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Column(
          children: [
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s2),
                child: AnalysisLogTile(entry: e),
              ),
          ],
        ),
      );
}

class AnalysisLogTile extends StatelessWidget {
  const AnalysisLogTile({super.key, required this.entry});

  final AnalysisLogEntry entry;

  /// Heading and sentence: the same words as the outcome's notification.
  static ({String title, String body}) textOf(
      AnalysisLogEntry entry, String lang, String ignoredLine) {
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
    return (title: content.title, body: ignored ? ignoredLine : content.body);
  }

  static IconData _icon(AnalysisOutcomeState state) => switch (state) {
        AnalysisOutcomeState.saved => AppLucideIcons.check,
        AnalysisOutcomeState.notAdded => AppLucideIcons.x,
        AnalysisOutcomeState.needsConfirmation => AppLucideIcons.sparkles,
        AnalysisOutcomeState.awaiting => AppLucideIcons.clock,
      };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final lang = Localizations.localeOf(context).languageCode;
    final text = textOf(entry, lang, context.l10n.outcomeIgnoredMessage);
    final raw = entry.text?.trim();
    // Masked only: card, account and phone numbers and a person's name never
    // appear here.
    final masked = raw == null || raw.isEmpty ? null : SmsSanitizer.sanitize(raw);
    final onTap = _onTap(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.surface2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: c.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(_icon(entry.state), size: 18, color: c.textMuted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text.title, style: AppTypography.bodyStrong(c.textMain)),
                  const SizedBox(height: 3),
                  Text(text.body, style: AppTypography.caption(c.textMain)),
                  const SizedBox(height: 3),
                  Text(captureTimeLabel(entry.at, lang: lang),
                      style: AppTypography.caption(c.textMuted)),
                  if (masked != null) ...[
                    const SizedBox(height: 5),
                    Text(masked,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.caption(c.textMuted)),
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
