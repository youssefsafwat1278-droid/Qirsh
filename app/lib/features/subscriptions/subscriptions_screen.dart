import '../help/coach_marks.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_spacing.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/app_error_state.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/entities/report_models.dart' show RecurringCandidate;
import '../../domain/finance/bill_metrics.dart';
import '../common/premium_loading.dart';
import '../common/qirsh_summary_card.dart';
import '../../core/utils/currency.dart';
import '../../domain/finance/money_format.dart';
import '../transactions/transactions_providers.dart' show BillSuggestion;
import 'bill_form_sheet.dart';
import 'subscriptions_providers.dart';
import 'widgets/bills_overview.dart';

/// «الفواتير والاشتراكات» — the pushed page (More / Home). Same photo hero as
/// the Activity tab and the SAME bills body ([BillsOverview]); only the photo
/// and the Back button differ.
class SubscriptionsScreen extends ConsumerWidget {
  const SubscriptionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final billsAsync = ref.watch(savedBillsProvider);
    final suggestionsAsync = ref.watch(subscriptionsProvider);
    final baseCur = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    // UX-024 — the same account the list was filtered by, not a second guess.
    final scopeAccount = ref.watch(billsScopeAccountProvider).valueOrNull;

    Widget hero({String? subtitle}) => QirshSectionHero(
          photo: QirshSectionPhoto.bills,
          title: context.l10n.txnBillsAndSubs,
          subtitle: subtitle,
          // One line: the page name shrinks to fit rather than wrapping.
          fitTitle: true,
          height: 132,
          leading: Navigator.of(context).canPop()
              ? const BackButton(color: Colors.white)
              : null,
          trailing: CoachAnchor(
            target: 'billAdd',
            child: _AddButton(
              onTap: () => BillFormSheet.show(context,
                  initialType: BillType.subscription),
            ),
          ),
        );

    Widget page(Widget body) => Scaffold(
          body: QirshSectionBackdrop(
            // Short (132) hero: glass before the title reaches the clock.
            glassFrom: 8,
            child: SafeArea(
              // Immersive: the photo runs under the status bar.
              top: false,
              bottom: false,
              child: body,
            ),
          ),
        );

    return FirstUseGuide(
        id: CoachMarkIds.bills,
        marks: billCoachMarks,
        child: billsAsync.when(
          skipLoadingOnReload: true,
          loading: () => page(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              hero(),
              const Expanded(child: SkeletonList(rows: 4)),
            ],
          )),
          error: (e, _) => page(Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              hero(),
              Expanded(
                child: SingleChildScrollView(
                    child: AppErrorState(
                  title: context.l10n.txnError,
                  description: context.l10n.annTryAgainSoon,
                  retryLabel: context.l10n.startRetry,
                  onRetry: () => ref.invalidate(savedBillsProvider),
                )),
              ),
            ],
          )),
          data: (bills) {
            final subs =
                bills.where((b) => b.type == BillType.subscription).toList();
            final insts =
                bills.where((b) => b.type == BillType.installment).toList();
            final suggestions = [
              for (final item in suggestionsAsync.valueOrNull ??
                  const <RecurringCandidate>[])
                BillSuggestion(
                  merchantId: item.merchantId,
                  name: item.name,
                  estimatedAmountMoney: item.estimatedAmountMoney,
                  monthsSeen: item.monthsSeen,
                ),
            ];
            // MALI-064n: projected monthly recurring obligation (frequency-
            // normalized, active subscriptions only) — the ONE canonical metric.
            // Summed EXACTLY as Money in the base display currency (currency-
            // isolated); converted to double only here at the display leaf.
            final monthlyTotal = subscriptionMonthlyTotalMoney(subs, baseCur);
            // UX-023 — the installment obligation as its OWN line, so the
            // summary's metric and the counters beside it describe the same
            // world.
            //
            // `monthlyEquivalentsTotalMoney` is deliberately filter-free ("the
            // caller decides"), which is precisely the footgun that produced
            // F-027 when a caller forgot. The active filter is therefore
            // explicit here rather than assumed.
            final installmentMonthly = monthlyEquivalentsTotalMoney(
              insts.where((b) => b.status == BillStatus.active),
              baseCur,
            );

            return page(ListView(
              padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom + 24),
              children: [
                hero(
                    subtitle:
                        context.l10n.billsV3Counts(subs.length, insts.length)),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      AppSpacing.gutter, 0, AppSpacing.gutter, 0),
                  child: BillsOverview(
                    bills: bills,
                    suggestions: suggestions,
                    baseCurrency: baseCur,
                    subscriptionsMonthly: monthlyTotal,
                    instalmentsMonthly: installmentMonthly,
                    // Shown only when there is one, so the strip does not
                    // carry a permanent «0.00».
                    subscriptionsExtraStat: installmentMonthly.minorUnits > 0
                        ? QirshSummaryStat(
                            value: Text(
                                '${formatMoney(installmentMonthly)} ${Currency.label(context, baseCur)}',
                                maxLines: 1),
                            label: context.l10n.subsMonthlyInstCommit,
                          )
                        : null,
                    subscriptionsLabel:
                        _SubscriptionsLabel(scopeAccount?.name).of(context),
                    afterSummary: const Padding(
                      padding: EdgeInsets.only(top: AppSpacing.s3),
                      child: QirshAdBanner(
                          placement: AdPlacement.subscriptions),
                    ),
                  ),
                ),
              ],
            ));
          },
        ));
  }
}

/// UX-023/024 — the summary caption: «monthly subscriptions», naming the
/// account the list is scoped to (or nothing, when nothing scopes it — there
/// is then nothing honest to claim).
class _SubscriptionsLabel {
  const _SubscriptionsLabel(this.scopeAccountName);

  final String? scopeAccountName;

  String of(BuildContext context) => scopeAccountName == null
      ? context.l10n.subsMonthlyTotal
      : context.l10n.subsMonthlyScoped(scopeAccountName!);
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CalmHeaderAction(
      icon: AppLucideIcons.plus,
      primary: true,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}
