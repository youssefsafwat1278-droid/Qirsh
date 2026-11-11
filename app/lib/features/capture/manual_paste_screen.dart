import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/backend/supabase_config.dart';
import '../../core/utils/id_generator.dart';
import '../../data/repositories/drift_smart_inbox_repository.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/captured_message.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/usecases/add_transaction_usecase.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/transactions_screen.dart'
    show showSuspectedDuplicateReviewSheet;
import '../transactions/widgets/confirm_transaction_sheet.dart';
import '../common/top_banner.dart';
import 'manual_paste_splitter.dart';
import '../common/app_header.dart';
import '../common/app_status_pill.dart';

class ManualPasteScreen extends ConsumerStatefulWidget {
  const ManualPasteScreen({super.key, this.onTransactionAdded});

  final ValueChanged<String>? onTransactionAdded;

  /// When [onTransactionAdded] is provided, the sheet calls it with the
  /// transaction id instead of opening the confirm sheet inline.
  static Future<void> showSheet(
    BuildContext context, {
    ValueChanged<String>? onTransactionAdded,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.colors.scrim,
      builder: (_) => navySheetTheme(
        _ManualPasteSheet(onTransactionAdded: onTransactionAdded),
      ),
    );
  }

  @override
  ConsumerState<ManualPasteScreen> createState() => _ManualPasteScreenState();
}

class _ManualPasteSheet extends StatelessWidget {
  const _ManualPasteSheet({this.onTransactionAdded});

  final ValueChanged<String>? onTransactionAdded;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.78,
            child: Column(
              children: [
                const SizedBox(height: AppSpacing.s3),
                Container(
                  width: 36,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textMuted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.s3,
                    AppSpacing.gutter,
                    0,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(context.l10n.pasteTitle,
                            style: AppTypography.sectionTitle(c.textPrimary)),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(AppLucideIcons.x, size: 20),
                        style: IconButton.styleFrom(
                          foregroundColor: c.textSecondary,
                          backgroundColor:
                              Theme.of(context).brightness == Brightness.dark
                                  ? c.surfaceMuted
                                  : c.surfaceElevated,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                    child: _ManualPasteContent(
                        fullScreen: false,
                        onTransactionAdded: onTransactionAdded)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ManualPasteScreenState extends ConsumerState<ManualPasteScreen> {
  @override
  Widget build(BuildContext context) =>
      _ManualPasteContent(onTransactionAdded: widget.onTransactionAdded);
}

class _ManualPasteContent extends ConsumerStatefulWidget {
  const _ManualPasteContent({this.fullScreen = true, this.onTransactionAdded});

  final bool fullScreen;
  final ValueChanged<String>? onTransactionAdded;

  @override
  ConsumerState<_ManualPasteContent> createState() =>
      _ManualPasteContentState();
}

class _ManualPasteContentState extends ConsumerState<_ManualPasteContent> {
  final _controller = TextEditingController();
  final _fieldFocus = FocusNode();
  bool _busy = false;
  int _processedCount = 0;
  int _totalCount = 0;
  List<_PasteBatchItem> _batchItems = const [];

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) {
      _controller.text = data!.text!;
      HapticFeedback.lightImpact();
    }
  }

  /// Closes the paste sheet, then opens the review/confirm sheet on the root
  /// navigator (so it isn't a fragile modal-on-modal that can fail to show).
  Future<void> _openReview(String txId, String? notice) async {
    if (widget.onTransactionAdded != null) {
      if (mounted && notice != null) showTopInfo(context, notice);
      if (mounted) Navigator.of(context).pop();
      widget.onTransactionAdded!(txId);
      return;
    }
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    if (mounted) Navigator.of(context).pop();
    await showConfirmTransactionSheet(rootContext, txId,
        secondaryNotice: notice);
  }

  Future<void> _openDuplicate(TransactionEntity tx, String? notice) async {
    if (tx.status == TransactionStatus.pending || notice != null) {
      await _openReview(tx.id, notice);
      return;
    }
    if (widget.onTransactionAdded != null) {
      if (mounted) {
        showTopInfo(context, context.l10n.pasteAlreadyExists);
        Navigator.of(context).pop();
      }
      widget.onTransactionAdded!(tx.id);
      return;
    }
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    if (mounted) Navigator.of(context).pop();
    await TransactionDetailsScreen.showSheet(rootContext, tx.id);
  }

  Future<void> _analyze() async {
    final messages = ManualPasteSplitter.split(_controller.text);
    if (messages.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _processedCount = 0;
      _totalCount = messages.length;
      _batchItems = const [];
    });

    try {
      if (messages.length == 1) {
        final item = await _ingestOne(messages.first);
        if (!mounted) return;
        setState(() => _busy = false);
        await _handleSingleResult(item);
        return;
      }

      final items = <_PasteBatchItem>[];
      for (final message in messages) {
        final item = await _ingestOne(message);
        items.add(item);
        if (!mounted) return;
        setState(() {
          _processedCount = items.length;
          _batchItems = List.unmodifiable(items);
        });
      }

      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      if (!mounted) return;
      setState(() => _busy = false);
      await _showBatchResults(items);
    } catch (_) {
      if (mounted) showTopError(context, context.l10n.txnError);
    } finally {
      if (mounted && _busy) setState(() => _busy = false);
    }
  }

  Future<_PasteBatchItem> _ingestOne(String text) async {
    final ingest = ref.read(ingestCapturedMessageUseCaseProvider);
    final admission = AppSession.instance.captureLocalWorkAuthority();
    final settings = admission == null
        ? null
        : await ref.read(userSettingsRepositoryProvider).getSettings();
    if (admission?.isCurrent == false || !mounted) {
      throw StateError('paste_admission_changed');
    }
    DriftSmartInboxRepository? drafts;
    String? draftId;
    if (admission != null && settings?.cloudProcessingEnabled == true &&
        settings?.aiConsentGranted == true) {
      drafts = DriftSmartInboxRepository(ref.read(appDatabaseProvider));
      draftId = await drafts.saveUnprocessableCapture(
        payloadId: IdGenerator.uuidV4(),
        rawMessage: text,
        source: CapturedMessageSource.manualPaste.name,
        lang: settings!.language,
        awaitingAnalysis: true,
      );
      if (!admission.isCurrent) throw StateError('paste_admission_changed');
    }
    final result = await ingest.fromCapturedMessage(CapturedMessage(
      text: text,
      source: CapturedMessageSource.manualPaste,
      receivedAt: DateTime.now().toUtc(),
    ));
    final savedForAnalysis = draftId != null &&
        result.disposition == CapturedMessageDisposition.unprocessable;
    if (draftId != null && !savedForAnalysis && admission?.isCurrent == true) {
      await drafts!.removeManualAnalysisDraft(draftId);
    }
    if (draftId != null && mounted) ref.invalidate(smartInboxItemsProvider);
    return _PasteBatchItem(message: text, result: result, savedForAnalysis: savedForAnalysis);
  }

  Future<void> _handleSingleResult(_PasteBatchItem item) async {
    final addResult = item.addResult;
    switch (addResult.outcome) {
      case AddTransactionOutcome.added:
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        await _openReview(
          addResult.transaction!.id,
          [
            pasteAnalysisNotice(context, addResult),
            if (feeNoticeFor(context, addResult.secondary) case final notice?)
              notice,
          ].whereType<String>().join('\n'),
        );
      case AddTransactionOutcome.duplicate:
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        final existing = addResult.transaction;
        final feeNotice = feeNoticeFor(context, addResult.secondary);
        // Re-pasting may have added a missing fee, or the existing operation may
        // still need review. If it is already confirmed, open its details
        // instead of blocking the user with a dead-end duplicate message.
        if (existing != null) {
          await _openDuplicate(existing, feeNotice);
        } else {
          showTopError(context, context.l10n.pasteAlreadyRecorded);
        }
      case AddTransactionOutcome.suspiciousDuplicate:
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        final existing = addResult.transaction;
        if (existing == null) {
          showTopError(context, context.l10n.pasteSimilarNeedsReview);
          return;
        }
        final dupe = await ref
            .read(suspectedDuplicateRepositoryProvider)
            .getByExistingTransactionId(existing.id);
        if (!mounted) return;
        if (dupe != null) {
          await showSuspectedDuplicateReviewSheet(context, dupe);
        } else {
          showTopError(context, context.l10n.pasteSimilarNeedsReview);
        }
      case AddTransactionOutcome.notTransaction:
        if (item.savedForAnalysis) {
          showTopInfo(context, context.l10n.pasteSavedForAnalysis);
        } else if (!SupabaseConfig.isConfigured) {
          showTopError(context, context.l10n.pasteAiOffline);
        } else {
          showTopError(
              context, _unreadableMessage(context, addResult.aiFailureReason));
        }
    }
  }

  /// Honest copy for a message we could not read.
  ///
  /// `aiFailureReason` carries TWO different things: reasons the AI was never
  /// invoked (consent not granted, no client, sender suppressed, the message
  /// classified as non-transactional, an on-device-only drain) and reasons a
  /// real attempt produced nothing. The old copy interpolated the raw token, so
  /// the DEFAULT install — AI consent is `unset` until the user grants it —
  /// read "فشل الذكاء الاصطناعي: consent_off": an internal identifier, and a
  /// claim that something failed when nothing had run.
  static String _unreadableMessage(BuildContext context, String? reason) {
    const notAttempted = {
      'no_ai_client',
      'consent_off',
      'sender_suppressed',
      'message_ignored',
      'on_device_only',
    };
    if (reason == 'consent_off') return context.l10n.pasteAiConsentOff;
    if (reason != null && notAttempted.contains(reason)) {
      // Local reading only — say so instead of blaming a service that was
      // never asked.
      return context.l10n.pasteUnreadableOnDevice;
    }
    return context.l10n.pasteNotATransaction;
  }

  Future<void> _openBatchItem(
    BuildContext hostContext,
    _PasteBatchItem item,
  ) async {
    final result = item.addResult;
    final tx = result.transaction;
    if (tx == null) {
      showTopError(context, context.l10n.pasteNothingToOpen);
      return;
    }
    final feeNotice = feeNoticeFor(context, result.secondary);
    if (result.outcome == AddTransactionOutcome.added &&
        result.requiresConfirmation) {
      await showConfirmTransactionSheet(hostContext, tx.id,
          secondaryNotice: feeNotice);
      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      return;
    }
    if (result.outcome == AddTransactionOutcome.duplicate ||
        result.outcome == AddTransactionOutcome.suspiciousDuplicate) {
      final dupe = await ref
          .read(suspectedDuplicateRepositoryProvider)
          .getByExistingTransactionId(tx.id);
      if (!hostContext.mounted) return;
      if (dupe != null) {
        await showSuspectedDuplicateReviewSheet(hostContext, dupe);
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        return;
      }
      await TransactionDetailsScreen.showSheet(hostContext, tx.id);
      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      return;
    }
    await TransactionDetailsScreen.showSheet(hostContext, tx.id);
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _showBatchResults(List<_PasteBatchItem> items) async {
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    await showModalBottomSheet<void>(
      context: rootContext,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        return navySheetTheme(_BatchResultsSheet(
          items: items,
          onOpenItem: (item) async {
            await _openBatchItem(sheetContext, item);
          },
          onConfirm: () {
            Navigator.of(sheetContext).pop();
            if (mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          },
        ));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final summary = _BatchSummary.from(_batchItems);


    // v2 field on the canvas: dark = Inset well; light = white + 1px
    // stroke.soft + e1 (the old field was nearly invisible in light, L2).
    final field = ListenableBuilder(
      listenable: Listenable.merge([_controller, _fieldFocus]),
      builder: (context, _) {
        final hasText = _controller.text.trim().isNotEmpty;
        // The SAME split the analyse path runs — a count, no new parsing.
        final detected =
            hasText ? ManualPasteSplitter.split(_controller.text).length : 0;
        final focused = _fieldFocus.hasFocus;
        return AnimatedContainer(
          duration: AppMotion.micro,
          decoration: BoxDecoration(
            color: isDark ? c.surfaceMuted : c.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: focused
                  ? c.cta
                  : isDark
                      ? Colors.transparent
                      : c.strokeSoft,
              width: focused ? 1.5 : 1,
            ),
            boxShadow: isDark ? null : AppShadows.e1,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                focusNode: _fieldFocus,
                minLines: 7,
                maxLines: 12,
                style: AppTypography.callout(c.textPrimary),
                decoration: InputDecoration(
                  hintText: context.l10n.pasteFieldHint,
                  hintStyle: AppTypography.callout(c.textFaint),
                  filled: false,
                  isDense: true,
                  contentPadding: const EdgeInsets.fromLTRB(
                      AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, 0),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s2),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSpacing.s2,
                  runSpacing: AppSpacing.s2,
                  children: [
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (detected > 0)
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: AppStatusPill(
                              label:
                                  context.l10n.pasteV2DetectedCount(detected),
                              tone: AppStatusTone.info,
                              icon: AppLucideIcons.messageSquare,
                            ),
                          ),
                        if (hasText)
                          IconButton(
                            tooltip: context.l10n.pasteV2Clear,
                            onPressed: _busy ? null : _controller.clear,
                            icon: Icon(AppLucideIcons.x,
                                size: 18, color: c.textMuted),
                          ),
                      ],
                    ),
                    OutlinedButton.icon(
                      onPressed: _pasteFromClipboard,
                      icon: const Icon(AppLucideIcons.clipboardPaste, size: 16),
                      label: Text(context.l10n.pasteFromClipboard),
                      // v2 tinted pill inside the field's corner.
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.s3),
                        backgroundColor: c.ctaSoft,
                        foregroundColor: c.actionText,
                        textStyle: AppTypography.subhead(c.actionText),
                        side: BorderSide.none,
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );

    // [topInset]: the full-screen page runs under the glass nav bar, so its
    // content starts below it (0 in the sheet).
    Widget scroll(double topInset) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(AppSpacing.gutter,
          topInset + AppSpacing.s3, AppSpacing.gutter, AppSpacing.gutter),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            context.l10n.pasteHint,
            style: AppTypography.callout(c.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s4),
          field,
          const SizedBox(height: AppSpacing.s3),
          // Privacy note — the same copy, now a compact info row.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(AppLucideIcons.shieldCheck,
                    size: 16, color: c.actionText),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(context.l10n.pasteAnalysisHowItWorks,
                    style: AppTypography.caption(c.textMuted)),
              ),
            ],
          ),
          if (_busy) ...[
            const SizedBox(height: AppSpacing.s3),
            _BatchProgressCard(
              busy: _busy,
              processed: _processedCount,
              total: _totalCount,
              summary: summary,
            ),
          ],
        ],
      ),
    );

    // v2 QStickyDock: the one primary, disabled until there is text; in the
    // sheet it rides above the keyboard.
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    final dock = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: c.border, width: .5)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.gutter,
          AppSpacing.s3,
          AppSpacing.gutter,
          AppSpacing.s3 +
              (widget.fullScreen
                  ? MediaQuery.paddingOf(context).bottom
                  : insets > 0
                      ? insets
                      : MediaQuery.paddingOf(context).bottom),
        ),
        child: SizedBox(
          height: AppSpacing.buttonHeight,
          child: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, value, _) => FilledButton(
              onPressed:
                  _busy || value.text.trim().isEmpty ? null : _analyze,
              style: FilledButton.styleFrom(
                backgroundColor: c.cta,
                foregroundColor: c.onCta,
                disabledBackgroundColor: c.disabled,
                disabledForegroundColor: c.textMuted,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.button)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.white),
                    )
                  : Text(context.l10n.pasteAnalyse,
                      style: AppTypography.bodyStrong(
                          value.text.trim().isEmpty ? c.textMuted : c.onCta)),
            ),
          ),
        ),
      ),
    );

    Widget content(double topInset) => Column(
      children: [
        Expanded(child: scroll(topInset)),
        dock,
      ],
    );
    if (!widget.fullScreen) return content(0);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppHeader(title: context.l10n.pasteTitle),
      body: Builder(
        builder: (bodyContext) => content(MediaQuery.paddingOf(bodyContext).top),
      ),
    );
  }
}

class _PasteBatchItem {
  const _PasteBatchItem({
    required this.message,
    required this.result,
    this.savedForAnalysis = false,
  });

  final String message;
  final CapturedMessageResult result;
  final bool savedForAnalysis;

  AddTransactionResult get addResult => result.addTransactionResult;

  bool needsReview({Set<String> confirmedIds = const {}}) {
    final tx = addResult.transaction;
    return addResult.outcome == AddTransactionOutcome.added &&
        tx != null &&
        tx.status == TransactionStatus.pending &&
        !confirmedIds.contains(tx.id);
  }

  String get title {
    final tx = addResult.transaction;
    if (tx?.rawMerchant != null && tx!.rawMerchant!.trim().isNotEmpty) {
      return tx.rawMerchant!;
    }
    final firstLine = message.split(RegExp(r'\r?\n')).first.trim();
    return firstLine.length > 48
        ? '${firstLine.substring(0, 48)}...'
        : firstLine;
  }

  String statusLabel(BuildContext context,
      {Set<String> confirmedIds = const {}}) {
    return switch (addResult.outcome) {
      AddTransactionOutcome.added => needsReview(confirmedIds: confirmedIds)
          ? context.l10n.pasteNeedsReview
          : context.l10n.pasteAdded,
      AddTransactionOutcome.duplicate => context.l10n.pasteDuplicate,
      AddTransactionOutcome.suspiciousDuplicate => context.l10n.pasteSimilar,
      AddTransactionOutcome.notTransaction => context.l10n.pasteNotUnderstood,
    };
  }
}

class _BatchSummary {
  const _BatchSummary({
    required this.added,
    required this.review,
    required this.duplicate,
    required this.failed,
  });

  final int added;
  final int review;
  final int duplicate;
  final int failed;

  factory _BatchSummary.from(
    List<_PasteBatchItem> items, {
    Set<String> confirmedIds = const {},
  }) {
    var added = 0;
    var review = 0;
    var duplicate = 0;
    var failed = 0;
    for (final item in items) {
      switch (item.addResult.outcome) {
        case AddTransactionOutcome.added:
          added++;
          if (item.needsReview(confirmedIds: confirmedIds)) review++;
        case AddTransactionOutcome.duplicate:
          duplicate++;
        case AddTransactionOutcome.suspiciousDuplicate:
          duplicate++;
        case AddTransactionOutcome.notTransaction:
          failed++;
      }
    }
    return _BatchSummary(
      added: added,
      review: review,
      duplicate: duplicate,
      failed: failed,
    );
  }
}

class _BatchProgressCard extends StatelessWidget {
  const _BatchProgressCard({
    required this.busy,
    required this.processed,
    required this.total,
    required this.summary,
  });

  final bool busy;
  final int processed;
  final int total;
  final _BatchSummary summary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress = total <= 0 ? 0.0 : processed / total;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface2.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                busy ? AppLucideIcons.sparkles : AppLucideIcons.checkCheck,
                color: busy ? c.cta : c.success,
                size: 18,
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: Text(
                  busy
                      ? context.l10n.pasteAnalysing(processed, total)
                      : context.l10n.pasteSummary,
                  style: AppTypography.subhead(c.textMain),
                ),
              ),
            ],
          ),
          if (busy) ...[
            const SizedBox(height: AppSpacing.s2),
            LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              minHeight: 6,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.s2),
            Text(
              context.l10n.pasteSummaryLine(summary.added, summary.duplicate,
                  summary.review, summary.failed),
              style: AppTypography.caption(c.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}

class _BatchResultsSheet extends ConsumerStatefulWidget {
  const _BatchResultsSheet({
    required this.items,
    required this.onOpenItem,
    required this.onConfirm,
  });

  final List<_PasteBatchItem> items;
  final ValueChanged<_PasteBatchItem> onOpenItem;
  final VoidCallback onConfirm;

  @override
  ConsumerState<_BatchResultsSheet> createState() => _BatchResultsSheetState();
}

class _BatchResultsSheetState extends ConsumerState<_BatchResultsSheet> {
  bool _confirming = false;
  final Set<String> _confirmedIds = {};

  Future<void> _confirmAll() async {
    if (_confirming) return;
    setState(() => _confirming = true);
    final pendingIds = widget.items
        .map((item) => item.addResult.transaction)
        .whereType<TransactionEntity>()
        .where((tx) =>
            tx.status == TransactionStatus.pending &&
            tx.pricingState != TransactionPricingState.awaitingFx)
        .map((tx) => tx.id)
        .toSet();
    try {
      final repository = ref.read(transactionRepositoryProvider);
      final confirm = ref.read(confirmTransactionUseCaseProvider);
      for (final id in pendingIds.difference(_confirmedIds)) {
        final current = await repository.getById(id);
        if (!mounted) return;
        if (current?.status != TransactionStatus.confirmed) {
          await confirm(id);
        }
        _confirmedIds.add(id);
        if (!mounted) return;
      }
      widget.onConfirm();
    } catch (_) {
      if (mounted) showTopError(context, context.l10n.txnError);
    } finally {
      if (mounted) {
        refreshTransactions(ref);
        ref.invalidate(dashboardDataProvider);
        setState(() => _confirming = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final summary =
        _BatchSummary.from(widget.items, confirmedIds: _confirmedIds);
    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.72,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s3,
                  AppSpacing.gutter,
                  AppSpacing.gutter,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: Alignment.center,
                      child: Container(
                        width: 44,
                        height: 5,
                        decoration: BoxDecoration(
                          color: c.textLight.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Row(
                      children: [
                        Container(
                          width: 42,
                          height: 42,
                          decoration: BoxDecoration(
                            color: c.success.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(AppLucideIcons.checkCheck,
                              color: c.success, size: 22),
                        ),
                        const SizedBox(width: AppSpacing.s3),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                context.l10n.pasteSummary,
                                style: AppTypography.headline(c.textMain),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                context.l10n
                                    .pasteAnalysedCount(widget.items.length),
                                style: AppTypography.caption(c.textMuted),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    _BatchProgressCard(
                      busy: false,
                      processed: widget.items.length,
                      total: widget.items.length,
                      summary: summary,
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    Expanded(
                      child: ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: widget.items.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: AppSpacing.s2),
                        itemBuilder: (context, index) {
                          final item = widget.items[index];
                          return _BatchResultTile(
                            index: index,
                            item: item,
                            confirmedIds: _confirmedIds,
                            onOpen: () => widget.onOpenItem(item),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    SizedBox(
                      height: 52,
                      child: FilledButton(
                        onPressed: _confirming ? null : _confirmAll,
                        style: FilledButton.styleFrom(
                          backgroundColor: c.cta,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: _confirming
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              )
                            : Text(
                                context.l10n.txnConfirm,
                                style: AppTypography.bodyStrong(Colors.white),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BatchResultTile extends StatelessWidget {
  const _BatchResultTile({
    required this.index,
    required this.item,
    required this.confirmedIds,
    required this.onOpen,
  });

  final int index;
  final _PasteBatchItem item;
  final Set<String> confirmedIds;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tx = item.addResult.transaction;
    final canOpen = tx != null;
    final needsReview = item.needsReview(confirmedIds: confirmedIds);
    final statusColor = switch (item.addResult.outcome) {
      AddTransactionOutcome.added => needsReview ? c.warning : c.success,
      AddTransactionOutcome.duplicate => c.textMuted,
      AddTransactionOutcome.suspiciousDuplicate => c.warning,
      AddTransactionOutcome.notTransaction => c.danger,
    };
    final amount = tx == null
        ? null
        : '${Formatters.amount(tx.amount)} ${tx.currency.toUpperCase()}';
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Text(
              '${index + 1}',
              style: AppTypography.caption(statusColor)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.subhead(c.textMain),
                ),
                const SizedBox(height: 2),
                Text(
                  amount == null
                      ? item.statusLabel(context, confirmedIds: confirmedIds)
                      : '${item.statusLabel(context, confirmedIds: confirmedIds)} · $amount',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.caption(statusColor),
                ),
                if (pasteAnalysisNotice(context, item.addResult)
                    case final notice?)
                  Text(notice, style: AppTypography.caption(c.textMuted)),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.s2),
          TextButton(
            onPressed: canOpen ? onOpen : null,
            child: Text(needsReview
                ? context.l10n.pasteReview
                : context.l10n.commonOpenImperative),
          ),
        ],
      ),
    );
  }
}

/// A duplicate's stored source says nothing about this paste attempt.
String? pasteAnalysisNotice(BuildContext context, AddTransactionResult result) {
  if (result.outcome != AddTransactionOutcome.added) return null;
  if (result.transaction?.source == TransactionSourceEntity.aiParsed) {
    return context.l10n.pasteReadWithAi;
  }
  final l10n = context.l10n;
  return switch (result.aiFailureReason) {
    'consent_off' => l10n.pasteAiOff,
    'no_ai_client' => l10n.pasteAiUnavailable,
    'ai_response_rejected_by_grounding' => l10n.pasteAiMismatch,
    null || 'message_ignored' || 'on_device_only' => l10n.pasteReadOnDevice,
    final code => l10n.pasteAiFailed(code),
  };
}
