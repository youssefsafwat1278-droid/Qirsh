import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../common/motion.dart';
import '../common/widgets.dart';
import 'savings_math.dart';
import 'savings_providers.dart';
import 'savings_repository.dart';

/// COUPONS Phase 4 — what the user saved.
///
/// ## The breakdown is the feature
///
/// It would be easy to show one big number. It would also be indefensible: a
/// total built from a user's own estimates and a store's confirmed figures is a
/// claim the app cannot stand behind, and the first time someone checks an entry
/// and finds it was a guess, every other number here loses its credibility.
///
/// So the three evidence kinds are always shown separately, always labelled, and
/// the note says plainly that they are not equally certain. The confirmed figure
/// is the one we can defend without qualification, and it is the one presented
/// as such.
///
/// Currencies are likewise never combined — there is no FX design, and a sum
/// across currencies would be a number in no currency at all.
class SavingsScreen extends ConsumerWidget {
  const SavingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final totals = ref.watch(savingsTotalsProvider);

    // Immersive: the header scrolls with the content, which fills from y = 0
    // under the status bar (kept legible by the scrim).
    final topInset = MediaQuery.paddingOf(context).top;
    final headerRow = Row(
          children: [
            Expanded(
              child: Text(
                l10n.savingsTitle,
                style: AppTypography.titleLarge(c.textPrimary),
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
            ),
          ],
        );
    // Non-list states: the header leads, the state fills the rest.
    Widget withHeader(Widget state) => CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: topInset),
              sliver: SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                      AppSpacing.s3, AppSpacing.gutter, AppSpacing.s2),
                  child: headerRow,
                ),
              ),
            ),
            SliverFillRemaining(hasScrollBody: false, child: state),
          ],
        );

    return AppScreenScaffold(
      safeArea: false,
      body: StatusBarScrim(
        child: totals.when(
        skipLoadingOnReload: true,
        loading: () =>
            withHeader(AppLoadingState(label: l10n.couponsLoading)),
        error: (_, __) => withHeader(AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(savingsTotalsProvider),
        )),
        data: (data) {
          if (data.isEmpty) {
            // v2 QEmptyState at the optical centre (44%) with one useful
            // next step: the existing offers screen.
            return withHeader(Align(
                    alignment: const Alignment(0, -.12),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.gutter),
                      child: PremiumMotion(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AppEmptyState(
                              icon: AppLucideIcons.badgeCheck,
                              illustration: const QirshIllustration(
                                  name: 'savings', width: 213, height: 160),
                              title: l10n.savingsEmptyTitle,
                              subtitle: l10n.savingsEmptyBody,
                            ),
                            AppSecondaryButton(
                              label: l10n.couponsV2BrowseOffers,
                              icon: AppLucideIcons.tag,
                              height: 44,
                              onTap: () => context.push('/coupons'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ));
          }
          final currencies = data.byCurrencyAndEvidence.keys.toList()..sort();
          return ListView(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter, topInset, AppSpacing.gutter, 120),
            children: [
              // The header scrolls away with the content.
              Padding(
                padding: const EdgeInsets.only(
                    top: AppSpacing.s3, bottom: AppSpacing.s2 + AppSpacing.s2),
                child: headerRow,
              ),
              for (final currency in currencies) ...[
                _CurrencyBlock(currency: currency, totals: data),
                const SizedBox(height: AppSpacing.s4),
              ],
              Text(
                l10n.savingsBreakdownNote,
                style: AppTypography.caption(c.textMuted),
              ),
              const SizedBox(height: 4),
              if (currencies.length > 1)
                Text(
                  l10n.savingsCurrencyNote,
                  style: AppTypography.caption(c.textMuted),
                ),
            ],
          );
        },
        ),
      ),
    );
  }
}

class _CurrencyBlock extends StatelessWidget {
  const _CurrencyBlock({required this.currency, required this.totals});

  final String currency;
  final SavingsTotals totals;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    final byEvidence = totals.byCurrencyAndEvidence[currency] ?? const {};

    String money(int minor) {
      try {
        return formatMoney(Money(minor, currency));
      } catch (_) {
        // A currency the money layer cannot scale. Showing the raw integer
        // would be a number off by a factor of a hundred; showing nothing is
        // correct.
        return '';
      }
    }

    // Ordered strongest-evidence first. The number the app can defend without
    // qualification leads, rather than the largest one.
    const order = [
      SavingsEvidence.conversionVerified,
      SavingsEvidence.conversionEstimated,
      SavingsEvidence.userConfirmed,
    ];
    String label(SavingsEvidence e) => switch (e) {
          SavingsEvidence.conversionVerified => l10n.savingsVerifiedLabel,
          SavingsEvidence.conversionEstimated => l10n.savingsEstimatedLabel,
          SavingsEvidence.userConfirmed => l10n.savingsSelfReportedLabel,
        };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.card),
        // v2 Group: dark hairline, light white + e1 with no border.
        border: Theme.of(context).brightness == Brightness.dark
            ? Border.all(color: c.border)
            : null,
        boxShadow: AppShadows.group(Theme.of(context).brightness),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(currency,
              style: AppTypography.caption(c.textMuted)
                  .copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: AppSpacing.s2),
          for (final evidence in order)
            if ((byEvidence[evidence] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(
                      evidence == SavingsEvidence.conversionVerified
                          ? AppLucideIcons.badgeCheck
                          : AppLucideIcons.info,
                      size: 14,
                      color: evidence == SavingsEvidence.conversionVerified
                          ? c.success
                          : c.textMuted,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(label(evidence),
                          style: AppTypography.footnote(c.textSecondary)),
                    ),
                    Text(
                      money(byEvidence[evidence]!),
                      style: AppTypography.bodyStrong(c.textPrimary),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
