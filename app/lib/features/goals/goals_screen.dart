import 'package:go_router/go_router.dart';
import 'package:flutter/material.dart';
import '../common/money_text.dart';
import '../../domain/finance/goal_pacing.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/liquid_bar.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/planning_repair_gate.dart';
import '../common/premium_loading.dart';
import '../common/app_error_state.dart';
import '../budgets/budgets_providers.dart';
import '../budgets/widgets/planning_hero_tabs.dart';
import 'goal_details_screen.dart';
import 'goal_form_screen.dart';
import 'goals_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class GoalsScreen extends ConsumerWidget {
  const GoalsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      PlanningRepairGate(child: _buildScreen(context, ref));

  Widget _buildScreen(BuildContext context, WidgetRef ref) {
    final async = ref.watch(goalsListProvider);
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final currencyLabel = Currency.label(context, displayCurrency);

    final hero = CalmPageHeader(
      sectionPhoto: QirshSectionPhoto.goals,
      sectionHeight: 174,
      useSafeAreaTop: false,
      title: context.l10n.bdgTabGoals,
      leading: Navigator.of(context).canPop() ? const BackButton() : null,
      trailing: IconButton(
        tooltip: context.l10n.bdgAddGoal,
        icon: const Icon(AppLucideIcons.plus, color: Colors.white),
        onPressed: () => GoalFormScreen.showSheet(context),
      ),
      coverBottom: PlanningHeroTabs(
        tab: 2,
        onSelected: (tab) {
          if (tab == 2) return;
          ref.read(budgetsPageTabProvider.notifier).state = tab;
          context.push('/budgets');
        },
      ),
    );
    return Scaffold(
      backgroundColor: context.colors.bg,
      body: QirshSectionBackdrop(
        child: SafeArea(
          bottom: false,
          child: async.when(
            skipLoadingOnReload: true,
            loading: () => Column(
                children: [hero, const Expanded(child: SkeletonList(rows: 4))]),
            error: (error, _) => ListView(padding: EdgeInsets.zero, children: [
              hero,
              AppErrorState(
                title: context.l10n.txnError,
                description: context.l10n.annTryAgainSoon,
                retryLabel: context.l10n.startRetry,
                onRetry: () => ref.invalidate(goalsListProvider),
              )
            ]),
            data: (goals) {
              final visibleGoals = goals
                  .where((goal) =>
                      goal.currency.toUpperCase() ==
                      displayCurrency.toUpperCase())
                  .toList(growable: false);
              final saved = Money.sum(
                  visibleGoals.map((goal) => goal.savedMoney), displayCurrency);
              final target = Money.sum(
                  visibleGoals.map((goal) => goal.targetMoney),
                  displayCurrency);
              if (visibleGoals.isEmpty) {
                return ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    hero,
                    _GoalsHeader(
                      count: 0,
                      saved: Money.zero(displayCurrency),
                      target: Money.zero(displayCurrency),
                      currencyLabel: currencyLabel,
                    ),
                    Padding(
                      padding: const EdgeInsets.all(AppSpacing.gutter),
                      child: _EmptyGoalsCard(
                        onAdd: () => GoalFormScreen.showSheet(context),
                      ),
                    ),
                    // BELOW the create-your-first-goal card, never beside it: the
                    // card is the screen's call to action and an ad flush against it
                    // reads as part of it. A placement may not depend on the user
                    // having goals, but it must not compete with the prompt either.
                    const Padding(
                      padding:
                          EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                      child: QirshAdBanner(placement: AdPlacement.goals),
                    ),
                    const SizedBox(height: 120),
                  ],
                );
              }
              return RefreshIndicator(
                onRefresh: () async => refreshGoals(ref),
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    hero,
                    _GoalsHeader(
                      count: visibleGoals
                          .where((goal) =>
                              goal.savedMoney.compareTo(goal.targetMoney) < 0)
                          .length,
                      saved: saved,
                      target: target,
                      currencyLabel: currencyLabel,
                    ),
                    // The FIRST goal card, on its own, so the banner can follow
                    // it. Splitting the list this way is what lets the ad sit after
                    // the first meaningful content block instead of at the foot of
                    // the page, while every card keeps the same gutter and rhythm.
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                          AppSpacing.gutter, AppSpacing.gutter, 0),
                      child: _GoalCard(
                        goal: visibleGoals.first,
                        currencyLabel: Currency.label(
                            context, visibleGoals.first.currency),
                      ),
                    ),
                    // A DIRECT child of the ListView, bracketed by real content:
                    // one card above, the rest below. The old position was after
                    // ALL the cards and required scrolling to the bottom.
                    //
                    // The `visibleGoals.length >= 2` gate is gone — availability no
                    // longer depends on how many goals exist.
                    const Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: AppSpacing.gutter,
                          vertical: AppSpacing.s4),
                      child: QirshAdBanner(placement: AdPlacement.goals),
                    ),
                    if (visibleGoals.length > 1)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.gutter),
                        child: Column(
                          children: [
                            for (final goal in visibleGoals.skip(1)) ...[
                              _GoalCard(
                                goal: goal,
                                currencyLabel:
                                    Currency.label(context, goal.currency),
                              ),
                              const SizedBox(height: AppSpacing.s4),
                            ],
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 0,
                          AppSpacing.gutter, AppSpacing.s4),
                      child: FilledButton.tonalIcon(
                        onPressed: () => GoalFormScreen.showSheet(context),
                        icon: const Icon(AppLucideIcons.plus, size: 18),
                        label: Text(context.l10n.bdgAddGoal),
                      ),
                    ),
                    // The nav-bar clearance that used to close the Column above.
                    // Moved out so it sits BELOW the banner rather than between the
                    // last goal and it — an ad the floating bar covers is an
                    // obscured ad.
                    const SizedBox(height: 120),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.currencyLabel,
  });

  final GoalEntity goal;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final progress =
        goal.targetAmount == 0 ? 0.0 : goal.savedAmount / goal.targetAmount;
    final clampedProgress = progress.clamp(0, 1).toDouble();
    final percent = (progress * 100).round();
    final pacing = goalPacing(
      target: goal.targetMoney,
      saved: goal.savedMoney,
      deadline: goal.deadline,
      now: DateTime.now(),
    );
    final remaining = pacing.remaining;
    final tone = remaining.isZero ? c.success : c.cta;
    return MaliCard(
      style: MaliSurfaceStyle.floating,
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.xxl),
        onTap: () => GoalDetailsScreen.showSheet(context, goal.id),
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(6, 6, 16, 6),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: QirshPhotoFrame(
                  photo: qirshGoalPhoto(goal.vaultSkin),
                  width: 96,
                  height: 96,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(goal.name, style: AppTypography.cardTitle(c.textMain)),
                    const SizedBox(height: 3),
                    if (pacing.requiredPerMonth case final rate?)
                      Wrap(
                        spacing: 4,
                        runSpacing: 2,
                        children: [
                          Text(
                            _goalDeadlineLabel(context, pacing.daysRemaining),
                            style: AppTypography.caption(c.textLight),
                          ),
                          MoneyText(rate,
                              style: AppTypography.caption(c.textLight)),
                          Text(context.l10n.goalPerMonth,
                              style: AppTypography.caption(c.textLight)),
                        ],
                      ),
                    Text(
                      remaining.isZero
                          ? context.l10n.bdgGoalDone
                          : context.l10n.goalRemainingToReach(
                              formatMoney(remaining), currencyLabel),
                      style: AppTypography.caption(
                          pacing.isOverdue ? c.warning : c.textLight),
                    ),
                    if (pacing.isOverdue && !remaining.isZero)
                      Text(context.l10n.goalOverdue,
                          style: AppTypography.caption(c.warning)),
                    const SizedBox(height: 9),
                    LiquidBar(value: clampedProgress, color: tone, height: 6),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                text: formatMoney(goal.savedMoney),
                                style: AppTypography.caption(c.textMain)
                                    .copyWith(fontWeight: FontWeight.w700),
                              ),
                              TextSpan(
                                text: ' / ${formatMoney(goal.targetMoney)}',
                                style: AppTypography.caption(c.textLight),
                              ),
                            ]),
                            maxLines: 2,
                            textDirection: TextDirection.ltr,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text('$percent%',
                            style: AppTypography.caption(tone)
                                .copyWith(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GoalsHeader extends StatelessWidget {
  const _GoalsHeader({
    required this.count,
    required this.saved,
    required this.target,
    required this.currencyLabel,
  });

  final int count;
  final Money saved;
  final Money target;
  final String currencyLabel;

  @override
  Widget build(BuildContext context) {
    final ratio = target.isZero
        ? 0
        : (saved.toDouble() / target.toDouble() * 100).round();
    return CalmFinancialSummary(
      label: context.l10n.goalTotalSavedAll,
      amount: formatMoney(saved),
      currency: currencyLabel,
      metrics: [
        CalmMetric(label: context.l10n.bdgStatActiveGoals, value: '$count'),
        CalmMetric(label: context.l10n.bdgStatProgress, value: '$ratio%'),
        CalmMetric(
            label: context.l10n.goalTargetLabel, value: formatMoney(target)),
      ],
    );
  }
}

class _EmptyGoalsCard extends StatelessWidget {
  const _EmptyGoalsCard({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: double.infinity,
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s6),
        child: Column(
          children: [
            const QirshIllustration(name: 'savings', width: 170, height: 128),
            const SizedBox(height: AppSpacing.s3),
            Text(context.l10n.bdgEmptyGoalsTitle,
                textAlign: TextAlign.center,
                style: AppTypography.cardTitle(c.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text(context.l10n.goalEmptyBody,
                textAlign: TextAlign.center,
                style: AppTypography.callout(c.textLight)),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(AppLucideIcons.plus),
              label: Text(context.l10n.bdgAddGoal),
            ),
          ],
        ),
      ),
    );
  }
}


/// UX-025 — time to target, in the same voice Subscriptions already uses
/// («بعد 3 يوم»), so the two surfaces read as one product.
String _goalDeadlineLabel(BuildContext context, int days) {
  if (days == 0) return context.l10n.goalDueToday;
  if (days < 60) return context.l10n.goalDaysLeft(days);
  return context.l10n.goalMonthsLeft((days / 30).round());
}
