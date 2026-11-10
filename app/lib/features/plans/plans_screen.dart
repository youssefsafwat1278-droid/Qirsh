import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/entities/plan_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/plan_scope.dart';
import '../../domain/finance/money_format.dart';
import '../common/app_card.dart';
import '../common/app_missing_record_state.dart';
import '../common/money_text.dart';
import '../common/app_empty_state.dart';
import '../common/app_error_state.dart';
import '../common/app_header.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_sheet_scaffold.dart';
import '../dashboard/dashboard_providers.dart';
import '../transactions/transaction_details_screen.dart';
import 'plan_form_sheet.dart';
import 'plans_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_actions.dart';

class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PlansScreen()),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(plansWithSpentProvider);
    return AppScreenScaffold(
      scrollHeader: true,
      header: AppHeader(
        sectionPhoto: QirshSectionPhoto.plans,
        title: context.l10n.homePlans,
        subtitle: context.l10n.plSubtitle,
        showBack: true,
        action: IconButton(
          tooltip: context.l10n.homeNewPlan,
          onPressed: () => PlanFormSheet.show(context),
          icon: const Icon(AppLucideIcons.plus, color: Colors.white),
        ),
      ),
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => SingleChildScrollView(
            child: AppErrorState(
          title: context.l10n.plLoadFailed,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(plansWithSpentProvider),
        )),
        data: (plans) {
          if (plans.isEmpty) {
            return Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
                child: AppEmptyState(
                  icon: AppLucideIcons.luggage,
                  illustration: const QirshIllustration(
                      name: 'plans', width: 220, height: 165),
                  title: context.l10n.plNoPlans,
                  subtitle: context.l10n.plEmptyBody,
                  primaryLabel: context.l10n.homeNewPlan,
                  onPrimary: () => PlanFormSheet.show(context),
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(
                AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 120),
            children: [
              for (final progress in plans) ...[
                _PlanCard(progress: progress),
                const SizedBox(height: AppSpacing.s4),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// UX-004 — names the accounts and cards a plan actually counts.
///
/// Account names are read from the already-loaded [accountsProvider] rather
/// than fetched per card. An id with no matching account is skipped rather than
/// printed raw: a stale id is a data question, and a UUID on a plan card
/// answers nothing.
String _planScopeLabel(BuildContext context, PlanEntity plan, WidgetRef ref) {
  if (plan.scopeMode == PlanScopeMode.allExpenses) {
    return context.l10n.plAllSpendInPeriod;
  }
  final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
  final byId = {for (final a in accounts) a.id: a.name};
  final parts = <String>[
    for (final id in plan.accountIds)
      if (byId[id] != null) byId[id]!,
    for (final last4 in plan.cardLast4s) context.l10n.plCardShort(last4),
  ];
  // The scope predicate is `account IN (...) OR card IN (...)`, so an id that
  // no longer resolves still widens the plan. Saying «حسابات محددة» is honest
  // about that; naming only the resolvable half would not be.
  if (parts.isEmpty) return context.l10n.plSpecificAccounts;
  return parts.join(' · ');
}

class _PlanCard extends ConsumerWidget {
  const _PlanCard({required this.progress});

  final PlanProgress progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final plan = progress.plan;
    final currency = Currency.label(context, plan.currency);
    final barColor = progress.isOver
        ? c.danger
        : (progress.ratio >= 0.8 ? c.warning : c.success);

    return AppCard(
      onTap: () => _PlanDetailsSheet.show(context, plan.id),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  // تايل هادي مصبوغ بدل التدرّج الأزرق القديم.
                  color: c.cta.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Icon(AppLucideIcons.luggage, color: c.cta, size: 22),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            plan.name,
                            style: AppTypography.bodyStrong(c.textMain),
                          ),
                        ),
                        // UX-006 — a closed plan sat in the main list looking
                        // identical to an active one. Whether closed plans
                        // belong in a separate tab is a product call the QA
                        // left open; labelling them is not, and it is what
                        // makes the list readable either way.
                        if (plan.status == PlanStatus.closed) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: c.textLight.withValues(alpha: 0.14),
                              borderRadius:
                                  BorderRadius.circular(AppRadius.pill),
                            ),
                            child: Text(context.l10n.plEnded,
                                style: AppTypography.caption(c.textSecondary)),
                          ),
                        ],
                      ],
                    ),
                    Text(
                      '${Formatters.fullDate(plan.startDate, context)} - ${Formatters.fullDate(plan.endDate, context)}',
                      style: AppTypography.caption(c.textLight),
                    ),
                    // UX-004 — a plan is bound to accounts in the data and the
                    // UI surfaced none of them, so a user could not tell which
                    // accounts a plan covers. The inconsistency was internal:
                    // the Subscriptions screen already names its owning
                    // account.
                    //
                    // The empty case is NOT "unconfigured" — MALI-048n makes an
                    // empty selection permanently mean «all expenses in the
                    // period», and that is the contract stated in the plan
                    // form. Rendering it as blank would hide the widest scope
                    // the app has.
                    Text(
                      _planScopeLabel(context, plan, ref),
                      style: AppTypography.caption(c.textLight),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              // UX-027 — delete was the ONLY control on the card, so the most
              // prominent affordance was the most destructive one. Worse, the
              // list also shows CLOSED plans (UX-006) that a user would
              // reasonably want to tidy away — and permanent deletion was the
              // only tool offered for that.
              //
              // Same family as F-017 (Admin confirmed deleting a draft but not
              // publishing a force-update): the destructive action is the
              // easiest one to reach. Edit now leads; delete is one level in and
              // still confirmed.
              IconButton(
                tooltip: context.l10n.plPlanOptions,
                icon: Icon(AppLucideIcons.moreVertical,
                    color: c.textLight, size: 20),
                onPressed: () async {
                  final value = await showGlassActions<String>(
                    context: context,
                    actions: [
                      GlassAction(value: 'edit', label: context.l10n.cardEdit),
                      GlassAction(
                        value: 'delete',
                        label: context.l10n.setDelete,
                        destructive: true,
                      ),
                    ],
                  );
                  if (!context.mounted) return;
                  if (value == 'edit') {
                    PlanFormSheet.show(context, existing: plan);
                  } else if (value == 'delete') {
                    _confirmDelete(context, ref);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s3),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // R-8 / UX-001 — spent and budget are exact Money. Formatting one
              // through a double and the other through the legacy REAL field is
              // how a card ends up contradicting itself.
              MoneyText(
                progress.spent,
                style: AppTypography.bodyStrong(c.textMain)
                    .copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(width: 4),
              Text(currency, style: AppTypography.caption(c.textLight)),
              const SizedBox(width: 6),
              Text('${context.l10n.plansFrom} ',
                  style: AppTypography.caption(c.textLight)),
              Flexible(
                child: MoneyText(
                  plan.budgetAmountMoney,
                  style: AppTypography.caption(c.textLight),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            child: LinearProgressIndicator(
              value: progress.ratio,
              minHeight: 9,
              backgroundColor: c.surface2,
              valueColor: AlwaysStoppedAnimation(barColor),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: 12,
            runSpacing: 6,
            children: [
              Wrap(
                spacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    progress.isOver
                        ? '${context.l10n.plansOverBudget} '
                        : '${context.l10n.plansRemaining} ',
                    style: AppTypography.caption(
                        progress.isOver ? c.danger : c.textSecondary),
                  ),
                  MoneyText(
                    progress.isOver ? -progress.remaining : progress.remaining,
                    style: AppTypography.caption(
                        progress.isOver ? c.danger : c.textSecondary),
                  ),
                ],
              ),
              if (plan.daysLeft > 0 && !progress.isOver)
                Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    MoneyText(
                      progress.perDayLeft,
                      style: AppTypography.caption(c.textLight),
                    ),
                    Text(context.l10n.plPerDayLeft(plan.daysLeft),
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(context.l10n.plDeleteTitle),
        content: Text(context.l10n.plDeleteBody(progress.plan.name)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.l10n.commonCancel)),
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: TextButton.styleFrom(foregroundColor: ctx.colors.danger),
              child: Text(context.l10n.setDelete)),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      await ref.read(planRepositoryProvider).delete(progress.plan.id);
      ref.invalidate(plansWithSpentProvider);
      ref.invalidate(planProgressProvider(progress.plan.id));
      ref.invalidate(planTransactionsProvider(progress.plan.id));
      ref.invalidate(dashboardDataProvider);
      if (context.mounted) Navigator.of(context).pop();
    } on RepoException catch (error) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppToast.showError(context, repoErrorMessage(context, error));
    } catch (_) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      AppToast.showError(context, context.l10n.plDeleteFailed);
    }
  }
}

class _PlanDetailsSheet extends ConsumerWidget {
  const _PlanDetailsSheet({required this.planId});

  final String planId;

  static Future<void> show(BuildContext context, String planId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_PlanDetailsSheet(planId: planId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final progressAsync = ref.watch(planProgressProvider(planId));
    final txAsync = ref.watch(planTransactionsProvider(planId));
    final c = context.colors;
    return progressAsync.when(
      skipLoadingOnReload: true,
      loading: () => AppSheetScaffold(
        title: context.l10n.plDetails,
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => AppSheetScaffold(
        title: context.l10n.plDetails,
        scrollable: true,
        body: AppErrorState(
          title: context.l10n.plLoadFailed,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(planProgressProvider(planId)),
        ),
      ),
      data: (progress) {
        if (progress == null) {
          return AppSheetScaffold(
            title: context.l10n.plDetails,
            scrollable: true,
            body: AppMissingRecordState(
                message: context.l10n.plNotFound, illustration: 'plans'),
          );
        }
        final plan = progress.plan;
        final currency = Currency.label(context, plan.currency);
        return AppSheetScaffold(
          title: plan.name,
          subtitle:
              '${Formatters.fullDate(plan.startDate, context)} - ${Formatters.fullDate(plan.endDate, context)}',
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          bottomAction: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => PlanFormSheet.show(context, existing: plan),
                  icon: const Icon(AppLucideIcons.pencil),
                  label: Text(context.l10n.cardEdit),
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Expanded(
                child: FilledButton.icon(
                  onPressed: () => _showLinkTransactionSheet(
                    context,
                    ref,
                    plan,
                    txAsync.valueOrNull ?? const [],
                  ),
                  icon: const Icon(AppLucideIcons.link2),
                  label: Text(context.l10n.plLinkTransaction),
                ),
              ),
            ],
          ),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AppCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${formatMoney(progress.spent)} $currency',
                      style: AppTypography.title1(c.textMain)
                          .copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      context.l10n.plOfBudget(
                          formatMoney(plan.budgetAmountMoney), currency),
                      style: AppTypography.caption(c.textLight),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: LinearProgressIndicator(
                        value: progress.ratio,
                        minHeight: 9,
                        backgroundColor: c.surface2,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s4),
              Text(context.l10n.plHistory,
                  style: AppTypography.sectionTitle(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              txAsync.when(
                skipLoadingOnReload: true,
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => AppErrorState(
                  title: context.l10n.plTxLoadFailed,
                  description: context.l10n.annTryAgainSoon,
                  retryLabel: context.l10n.startRetry,
                  onRetry: () =>
                      ref.invalidate(planTransactionsProvider(planId)),
                ),
                data: (transactions) {
                  if (transactions.isEmpty) {
                    return AppEmptyState(
                      icon: AppLucideIcons.receipt,
                      title: context.l10n.plNoLinkedTx,
                      subtitle: context.l10n.plLinkHint,
                      primaryLabel: context.l10n.plLinkTransaction,
                      onPrimary: () => _showLinkTransactionSheet(
                        context,
                        ref,
                        plan,
                        transactions,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final tx in transactions)
                        _PlanTransactionTile(
                          tx: tx,
                          onTap: () => TransactionDetailsScreen.showSheet(
                              context, tx.id),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlanTransactionTile extends StatelessWidget {
  const _PlanTransactionTile({required this.tx, required this.onTap});

  final TransactionEntity tx;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return AppCard(
      onTap: onTap,
      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Row(
        children: [
          Icon(AppLucideIcons.receipt, color: c.cta),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.rawMerchant?.trim().isNotEmpty == true
                      ? tx.rawMerchant!
                      : context.l10n.txnTransactionWord,
                  style: AppTypography.bodyStrong(c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  Formatters.fullDate(tx.occurredAt, context),
                  style: AppTypography.caption(c.textLight),
                ),
              ],
            ),
          ),
          Text(
            '${formatMoney(tx.amountMoney)} ${Currency.label(context, tx.currency)}',
            style: AppTypography.bodyStrong(c.danger),
          ),
        ],
      ),
    );
  }
}

Future<void> _showLinkTransactionSheet(
  BuildContext context,
  WidgetRef ref,
  PlanEntity plan,
  List<TransactionEntity> linkedTransactions,
) {
  final linkedIds = linkedTransactions.map((tx) => tx.id).toSet();
  String? linkingId;
  Future<List<TransactionEntity>>? transactionPage;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(StatefulBuilder(
      builder: (context, setState) {
        final c = context.colors;
        return AppSheetScaffold(
          title: context.l10n.plLinkToPlan,
          subtitle: plan.name,
          scrollable: true,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
          body: FutureBuilder<List<TransactionEntity>>(
            // B2-C — bounded recent-expenses page (kind pushed to SQL) instead of
            // the whole ledger; the picker shows the 40 most-recent confirmed,
            // not-yet-linked expenses.
            future: transactionPage ??=
                ref.read(transactionRepositoryProvider).getTransactionPage(
                      limit: 500,
                      filter: const TransactionPageFilter(
                          kind: TransactionPageKind.expenses),
                    ),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return AppErrorState(
                  title: context.l10n.txnError,
                  description: context.l10n.annTryAgainSoon,
                  retryLabel: context.l10n.startRetry,
                  onRetry: () => setState(() => transactionPage = null),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final transactions = snapshot.data!
                  .where((tx) =>
                      !linkedIds.contains(tx.id) &&
                      tx.status == TransactionStatus.confirmed)
                  .take(40)
                  .toList(growable: false);
              if (transactions.isEmpty) {
                return AppEmptyState(
                  icon: AppLucideIcons.unlink,
                  illustration: const QirshIllustration(
                      name: 'emptyTx', width: 160, height: 120),
                  title: context.l10n.plNoSuitableTx,
                  subtitle: context.l10n.plAllLinkedAlready,
                );
              }
              return Column(
                children: [
                  for (final tx in transactions)
                    AppCard(
                      margin: const EdgeInsets.only(bottom: AppSpacing.s2),
                      padding: const EdgeInsets.all(AppSpacing.s3),
                      onTap: linkingId == null
                          ? () async {
                              setState(() => linkingId = tx.id);
                              await ref
                                  .read(planRepositoryProvider)
                                  .linkTransactionToPlan(
                                    planId: plan.id,
                                    transactionId: tx.id,
                                  );
                              ref.invalidate(plansWithSpentProvider);
                              ref.invalidate(planProgressProvider(plan.id));
                              ref.invalidate(planTransactionsProvider(plan.id));
                              ref.invalidate(dashboardDataProvider);
                              if (context.mounted) Navigator.of(context).pop();
                            }
                          : null,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              tx.rawMerchant?.trim().isNotEmpty == true
                                  ? tx.rawMerchant!
                                  : Formatters.fullDate(tx.occurredAt, context),
                              style: AppTypography.bodyStrong(c.textMain),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (linkingId == tx.id)
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Text(
                              '${formatMoney(tx.amountMoney)} ${Currency.label(context, tx.currency)}',
                              style: AppTypography.caption(c.textSecondary),
                            ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
        );
      },
    )),
  );
}
