import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money_input.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../budgets/budgets_providers.dart';
import '../common/app_header.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/app_error_state.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../common/money_text.dart';
import '../common/app_card.dart';
import '../common/app_missing_record_state.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../dashboard/dashboard_providers.dart';
import 'goal_form_screen.dart';
import 'goals_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../common/app_status_pill.dart';
import '../common/motion.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import 'package:flutter/services.dart';
import '../../core/theme/widgets/glass_dialog.dart';

class GoalDetailsScreen extends ConsumerWidget {
  const GoalDetailsScreen({super.key, required this.goalId});

  final String goalId;

  static Future<void> showSheet(BuildContext context, String goalId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_GoalDetailsSheet(goalId: goalId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goal = ref.watch(goalDetailsProvider(goalId)).valueOrNull?.goal;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppHeader(
        title: goal?.name ?? context.l10n.gdTitle,
        // v2: edit lives in the nav bar; the screen keeps ONE primary action.
        trailing: goal == null
            ? null
            : IconButton(
                tooltip: context.l10n.cardEdit,
                icon: Icon(AppLucideIcons.pencil, color: context.colors.actionText),
                onPressed: () => GoalFormScreen.showSheet(context, goal: goal),
              ),
      ),
      body: _GoalDetailsContent(goalId: goalId),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: FilledButton.icon(
            onPressed: () => _showAddContributionSheet(context, ref, goalId),
            label: Text(context.l10n.gdAddToGoal),
            icon: const Icon(AppLucideIcons.plus),
          ),
        ),
      ),
    );
  }
}

class _GoalDetailsSheet extends ConsumerWidget {
  const _GoalDetailsSheet({required this.goalId});

  final String goalId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final media = MediaQuery.of(context);
    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(28),
        ),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: Material(
            color: Colors.transparent,
            child: SizedBox(
              height: media.size.height * 0.86,
              child: Column(
                children: [
                  const SizedBox(height: AppSpacing.s3),
                  Container(
                    width: 44,
                    height: 5,
                    decoration: BoxDecoration(
                      color: c.textLight.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter,
                      AppSpacing.s4,
                      AppSpacing.gutter,
                      AppSpacing.s2,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(ref.watch(goalDetailsProvider(goalId)).valueOrNull?.goal.name ??
                              context.l10n.gdTitle,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.sectionTitle(c.textMain)),
                        ),
                        if (ref.watch(goalDetailsProvider(goalId)).valueOrNull?.goal
                            case final goal?)
                          IconButton(
                            tooltip: context.l10n.cardEdit,
                            onPressed: () =>
                                GoalFormScreen.showSheet(context, goal: goal),
                            icon: Icon(AppLucideIcons.pencil, color: c.actionText),
                          ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(AppLucideIcons.x),
                          style: IconButton.styleFrom(
                            backgroundColor: c.surface.withValues(alpha: 0.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                      child:
                          _GoalDetailsContent(goalId: goalId, sheetMode: true)),
                  // v2 QStickyDock — the one primary action, pinned.
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                          AppSpacing.s3, AppSpacing.gutter, AppSpacing.s3),
                      child: SizedBox(
                        width: double.infinity,
                        height: AppSpacing.buttonHeight,
                        child: FilledButton.icon(
                          onPressed: () =>
                              _showAddContributionSheet(context, ref, goalId),
                          icon: const Icon(AppLucideIcons.plus),
                          label: Text(context.l10n.gdAddToGoal),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GoalDetailsContent extends ConsumerWidget {
  const _GoalDetailsContent({
    required this.goalId,
    this.sheetMode = false,
  });

  final String goalId;
  final bool sheetMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalDetailsProvider(goalId));
    // Immersive page: the body sits behind the glass nav bar, whose height
    // arrives as the top inset. The sheet has its own header — no inset.
    final topInset = sheetMode ? 0.0 : MediaQuery.paddingOf(context).top;
    return async.when(
      skipLoadingOnReload: true,
      loading: () => Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const Center(child: CircularProgressIndicator())),
      error: (error, _) => SingleChildScrollView(
          padding: EdgeInsets.only(top: topInset),
          child: AppErrorState(
        title: context.l10n.txnError,
        description: context.l10n.annTryAgainSoon,
        retryLabel: context.l10n.startRetry,
        onRetry: () => ref.invalidate(goalDetailsProvider(goalId)),
      )),
      data: (data) {
        if (data == null) {
          return Center(child: SingleChildScrollView(
            padding: EdgeInsets.only(top: topInset),
            child: AppMissingRecordState(
            message: context.l10n.gdNotFound, illustration: 'savings')));
        }
        final c = context.colors;
        // `arabicLabel`, not `label(context, …)` — so an English reader saw
        // "Saved 12,750 of 15,000 ريال". Found by capturing this screen, which
        // has no route without an id and had therefore never been walked.
        final cur = Currency.label(
            context, data.goal.currency);
        final overdue =
            data.daysRemaining != null && data.daysRemaining! < 0;
        final done = data.remainingAmount.minorUnits <= 0;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            sheetMode ? AppSpacing.s2 : topInset + AppSpacing.s4,
            AppSpacing.gutter,
            sheetMode ? AppSpacing.s4 : 140,
          ),
          children: [
            _GoalPhotoHeader(
              photo: qirshGoalPhoto(data.goal.vaultSkin),
              title: data.goal.name,
              status: AppStatusPill(
                label: done
                    ? context.l10n.bdgGoalDone
                    : overdue
                        ? context.l10n.goalOverdue
                        : context.l10n.txnActive,
                tone: overdue && !done
                    ? AppStatusTone.warning
                    : AppStatusTone.success,
              ),
            ),
            // Progress card overlaps the photo by 32pt (spec 16).
            Transform.translate(
              offset: const Offset(0, -32),
              child: _GoalProgressCard(data: data, currencyLabel: cur),
            ),
            Text(context.l10n.gdContributions,
                style: AppTypography.sectionTitle(c.textMain)),
            const SizedBox(height: AppSpacing.s3),
            if (data.contributions.isEmpty)
              Container(
                padding: const EdgeInsets.all(AppSpacing.s4),
                decoration: BoxDecoration(
                  color: Theme.of(context).brightness == Brightness.dark
                      ? c.surfaceMuted
                      : c.surfaceElevated,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    Icon(AppLucideIcons.piggyBank, size: 22, color: c.goldText),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        context.l10n.gdNoContributions,
                        style: AppTypography.subhead(c.textSecondary),
                      ),
                    ),
                  ],
                ),
              )
            else
              AppCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  children: [
                    for (var i = 0; i < data.contributions.length; i++) ...[
                      if (i > 0)
                        Divider(height: 1, indent: 16, endIndent: 16,
                            color: c.border),
                      ListTile(
                        title: Text(
                          '${formatMoney(data.contributions[i].amountMoney)} $cur',
                          textDirection: TextDirection.ltr,
                          style: AppTypography.amountSmall(c.textMain),
                        ),
                        subtitle: Text(
                          data.contributions[i].note ??
                              Formatters.fullDate(
                                  data.contributions[i].createdAt, context),
                          style: AppTypography.caption(c.textMuted),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            // Delete is a quiet destructive row at the foot — no red button
            // in the user's face; the confirmation dialog is unchanged.
            const SizedBox(height: AppSpacing.s6),
            AppCard(
              padding: EdgeInsets.zero,
              onTap: () => _confirmDeleteGoal(context, ref, goalId),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4, vertical: 14),
                child: Row(
                  children: [
                    Icon(AppLucideIcons.trash2, size: 20, color: c.danger),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Text(context.l10n.gdDeleteGoal,
                          style: AppTypography.bodyStrong(c.danger)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Photo header (spec 16 / §3.0): the goal photo with a per-theme scrim —
/// dark fades to black, light lays `#011341`@0→70% over the lower 45% — and
/// the title + status chip in white on it.
class _GoalPhotoHeader extends StatelessWidget {
  const _GoalPhotoHeader({
    required this.photo,
    required this.title,
    required this.status,
  });

  final QirshPhoto photo;
  final String title;
  final Widget status;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.card),
      child: SizedBox(
        height: 236,
        child: Stack(
          children: [
            Positioned.fill(
              child: QirshPhotoFrame(photo: photo, height: 236),
            ),
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: isDark ? const [0.35, 1] : const [0.55, 1],
                    colors: isDark
                        ? const [Color(0x00000000), Color(0xE6000000)]
                        : const [Color(0x00011341), Color(0xB3011341)],
                  ),
                ),
              ),
            ),
            PositionedDirectional(
              start: AppSpacing.s4,
              end: AppSpacing.s4,
              bottom: 32 + AppSpacing.s4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.sectionTitle(Colors.white)),
                  const SizedBox(height: AppSpacing.s2),
                  status,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The raised progress card: gold ring with the %, saved / target, ONE pair of
/// stats (remaining · days to deadline) and the recommended-daily chip — no
/// wrapped 3-up tiles. Reaching 100% while on screen bursts gold coins once.
class _GoalProgressCard extends StatefulWidget {
  const _GoalProgressCard({required this.data, required this.currencyLabel});

  final GoalDetailsEntity data;
  final String currencyLabel;

  @override
  State<_GoalProgressCard> createState() => _GoalProgressCardState();
}

class _GoalProgressCardState extends State<_GoalProgressCard> {
  int _burst = 0;

  @override
  void didUpdateWidget(_GoalProgressCard old) {
    super.didUpdateWidget(old);
    if (old.data.progress < 1 && widget.data.progress >= 1) {
      HapticFeedback.heavyImpact();
      setState(() => _burst++);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final data = widget.data;
    final cur = widget.currencyLabel;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        color: isDark ? c.surfaceElevated : c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: isDark
            ? Border.all(color: Colors.white.withValues(alpha: 0.10))
            : null,
        boxShadow: AppShadows.raised(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  RingProgress(
                    value: data.progress,
                    size: 96,
                    strokeWidth: 10,
                    color: c.accent,
                    trackColor: isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : c.surfaceMuted,
                    child: Center(
                      child: Text('${(data.progress * 100).round()}%',
                          style: AppTypography.amountMedium(c.textMain)),
                    ),
                  ),
                  if (_burst > 0 && !shouldReduceMotion(context))
                    _CoinBurst(key: ValueKey(_burst)),
                ],
              ),
              const SizedBox(width: AppSpacing.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.gdSavedLabel,
                        style: AppTypography.caption(c.textLight)),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: AlignmentDirectional.centerStart,
                      child: MoneyText(data.goal.savedMoney,
                          style: AppTypography.amountLarge(c.textMain)),
                    ),
                    Text('/ ${formatMoney(data.goal.targetMoney)} $cur',
                        textDirection: TextDirection.ltr,
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s4),
            child: Divider(height: 1, color: c.border),
          ),
          IntrinsicHeight(
            child: Row(
              children: [
                Expanded(
                  child: _GoalDetailMetric(
                    label: context.l10n.bdgRemaining,
                    value: '${formatMoney(data.remainingAmount)} $cur',
                    valueTextDirection: TextDirection.ltr,
                  ),
                ),
                VerticalDivider(width: AppSpacing.s5, color: c.border),
                Expanded(
                  child: _GoalDetailMetric(
                    label: data.goal.deadline == null
                        ? context.l10n.gfDeadline
                        : Formatters.fullDate(data.goal.deadline!, context),
                    value: data.goal.deadline == null
                        ? context.l10n.gfOptional
                        : data.daysRemaining != null && data.daysRemaining! < 0
                            ? context.l10n.goalOverdue
                            : context.l10n
                                .gdV2DaysCount(data.daysRemaining ?? 0),
                    tone: data.daysRemaining != null && data.daysRemaining! < 0
                        ? c.warningText
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (data.remainingAmount.minorUnits > 0) ...[
            const SizedBox(height: AppSpacing.s4),
            // Info chip (infoBg + action.text); wraps instead of clipping on
            // compact widths / long currency names.
            Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.s3, vertical: 6),
              decoration: BoxDecoration(
                color: c.infoBg,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppLucideIcons.sparkles, size: 14, color: c.actionText),
                  const SizedBox(width: AppSpacing.s1),
                  Flexible(
                    child: Text(
                      context.l10n.gdRecommendedDaily(
                          formatMoney(data.recommendedDailyAmount), cur),
                      style: AppTypography.caption(c.actionText)
                          .copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One-shot celebration: 14 gold coins burst from the ring (700ms). Colours
/// per theme (spec §3.0 16): dark `#FFE880` / `#FBC926`, light `#E4BA41` /
/// `#B76F27` so they read on white.
class _CoinBurst extends StatelessWidget {
  const _CoinBurst({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colors = isDark
        ? const [AppBrandAccent.goldLit, Color(0xFFFBC926)]
        : const [AppBrandAccent.gold, AppBrandAccent.goldDeep];
    return IgnorePointer(
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 700),
        curve: AppMotion.easeOut,
        builder: (context, t, _) => SizedBox(
          width: 1,
          height: 1,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i < 14; i++)
                Transform.translate(
                  offset: Offset.fromDirection(
                      i / 14 * 2 * math.pi, t * (70 + (i % 3) * 14)),
                  child: Opacity(
                    opacity: (1 - t).clamp(0.0, 1.0),
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colors[i % 2],
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalDetailMetric extends StatelessWidget {
  const _GoalDetailMetric({
    required this.label,
    required this.value,
    this.tone,
    this.valueTextDirection,
  });

  final String label;
  final String value;
  final Color? tone;
  final TextDirection? valueTextDirection;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // v2 QStat: value first, label beneath, no box.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(value,
              maxLines: 1,
              textDirection: valueTextDirection,
              style: AppTypography.amountSmall(tone ?? c.textMain)),
        ),
        const SizedBox(height: 2),
        Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTypography.caption(c.textLight)),
      ],
    );
  }
}

Future<void> _confirmDeleteGoal(
  BuildContext context,
  WidgetRef ref,
  String goalId,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => GlassAlertDialog(
      title: Text(context.l10n.gdDeleteTitle),
      content: Text(context.l10n.gdDeleteBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(context.l10n.commonCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(backgroundColor: context.colors.danger,
              foregroundColor: context.colors.onDanger),
          child: Text(context.l10n.setDelete),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) {
    return;
  }
  await ref.read(deleteGoalUseCaseProvider).call(goalId);
  refreshGoals(ref);
  refreshBudgets(ref);
  ref.invalidate(dashboardDataProvider);
  ref.invalidate(goalDetailsProvider(goalId));
  if (context.mounted) {
    Navigator.of(context).pop();
  }
}

Future<void> _showAddContributionSheet(
  BuildContext context,
  WidgetRef ref,
  String goalId,
) async {
  final controller = TextEditingController();
  final noteController = TextEditingController();
  final c = context.colors;
  // §14 — the contribution inherits the PARENT GOAL's currency; the amount is
  // parsed exactly into it (the repository rejects any mismatch).
  final goalCurrency =
      ref.read(goalDetailsProvider(goalId)).valueOrNull?.goal.currency ??
          (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
  final cur = Currency.label(context, goalCurrency);
  final isDark = Theme.of(context).brightness == Brightness.dark;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) {
      var saving = false;
      return navySheetTheme(StatefulBuilder(
        builder: (context, setSheetState) {
          Future<void> saveContribution() async {
            if (saving) return;
            final Money amount;
            try {
              amount = parseLocalizedMoney(controller.text, goalCurrency);
            } on Exception {
              AppToast.showError(context, context.l10n.bfInvalidAmount);
              return;
            }
            if (amount.minorUnits <= 0) {
              AppToast.showError(context, context.l10n.bfInvalidAmount);
              return;
            }
            setSheetState(() => saving = true);
            try {
              await ref.read(addGoalContributionUseCaseProvider).call(
                    GoalContributionEntity(
                      id: IdGenerator.next(),
                      goalId: goalId,
                      amountMoney: amount,
                      createdAt: DateTime.now().toUtc(),
                      note: noteController.text.isEmpty
                          ? null
                          : noteController.text,
                    ),
                  );
              if (context.mounted) {
                Navigator.of(context).pop();
              }
              refreshGoals(ref);
              refreshBudgets(ref);
              ref.invalidate(dashboardDataProvider);
              ref.invalidate(goalDetailsProvider(goalId));
            } on RepoException catch (error) {
              if (!context.mounted) return;
              AppToast.showError(context, repoErrorMessage(context, error));
            } catch (_) {
              if (!context.mounted) return;
              AppToast.showError(context, context.l10n.gdSaveFailed);
            } finally {
              if (context.mounted) {
                setSheetState(() => saving = false);
              }
            }
          }

          return AppSheetScaffold(
            title: context.l10n.gdAddContribution,
            scrollable: true,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
            body: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: controller,
                  onChanged: (_) => setSheetState(() {}),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  style: AppTypography.body(c.textMain),
                  decoration: InputDecoration(
                    labelText: context.l10n.bdgAmount,
                    suffixText: cur,
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : c.surface2.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                          color: c.border.withValues(alpha: 0.5)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.primary, width: 2),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.s3),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: [
                    for (final amount in [250, 500, 1000, 2000])
                      ChoiceChip(
                        key: ValueKey('goal-contribution-preset-$amount'),
                        label: Text('$amount'),
                        selected: controller.text ==
                            Money.parse('$amount', goalCurrency).toDecimalString(),
                        onSelected: saving ? null : (_) => setSheetState(() {
                          controller.text = Money.parse('$amount', goalCurrency)
                              .toDecimalString();
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s3),
                TextField(
                  controller: noteController,
                  style: AppTypography.body(c.textMain),
                  decoration: InputDecoration(
                    labelText: context.l10n.txdNote,
                    filled: true,
                    fillColor: isDark
                        ? Colors.white.withValues(alpha: 0.05)
                        : c.surface2.withValues(alpha: 0.5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.border),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(
                          color: c.border.withValues(alpha: 0.5)),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide(color: c.primary, width: 2),
                    ),
                  ),
                ),
              ],
            ),
            bottomAction: SizedBox(
              height: AppSpacing.buttonHeight,
              width: double.infinity,
              child: FilledButton(
                onPressed: saving ? null : saveContribution,
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: saving
                    ? SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: c.onInk,
                        ),
                      )
                    : Text(context.l10n.gdSaveContribution,
                        style: AppTypography.bodyStrong(c.onInk)),
              ),
            ),
          );
        },
      ));
    },
  );
  // Do NOT dispose controllers here – the sheet's exit animation may still
  // reference them. They will be GC'd when the method scope ends.
}
