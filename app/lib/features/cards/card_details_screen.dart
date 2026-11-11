import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/currency.dart';
import '../../domain/finance/money_format.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/card_summary.dart';
import '../common/app_header.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import '../../engine/parser/card_network.dart';
import 'card_network_badge.dart';
import 'card_theme.dart';
import 'cards_providers.dart';
import '../accounts/day_grouped_transactions.dart';
import '../../core/utils/app_lucide_icons.dart';

/// شاشة تفاصيل البطاقة (بآخر 4 أرقام): بطاقة مُشتقّة من العمليات، تُفتح عبر
/// المسار `/card/:last4`. كانت سابقًا bottom sheet زجاجية بارتفاع 86% —
/// حُوِّلت لشاشة مسارية كاملة لاتّساق التنقّل ورجوع صحيح.
class CardDetailsScreen extends ConsumerWidget {
  const CardDetailsScreen({super.key, required this.last4});

  final String last4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      extendBodyBehindAppBar: true,
      appBar: AppHeader(title: context.l10n.cdCardTitle(last4)),
      body: _CardDetailsContent(last4: last4),
    );
  }
}

class _CardDetailsContent extends ConsumerWidget {
  const _CardDetailsContent({required this.last4});

  final String last4;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final summaries = ref.watch(cardSummariesProvider).valueOrNull;
    final txAsync = ref.watch(cardTransactionsProvider(last4));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';

    final matchingSummaries = summaries
            ?.where((summary) => summary.last4 == last4)
            .toList(growable: false) ??
        const <CardSummary>[];
    final displayCurrencySummary = matchingSummaries
        .where((summary) =>
            summary.currency.toUpperCase() == displayCurrency.toUpperCase())
        .firstOrNull;
    final summary = displayCurrencySummary ?? matchingSummaries.firstOrNull;

    return ListView(
      // Immersive: the list runs under the glass nav bar, whose height
      // arrives as the top inset.
      padding: const EdgeInsets.all(AppSpacing.gutter).copyWith(
          top: MediaQuery.paddingOf(context).top + AppSpacing.gutter),
      children: [
        _CardHeader(
          last4: last4,
          network: summary?.network ?? CardNetwork.unknown,
          totalIn: summary?.totalIn ?? Money.zero(displayCurrency),
          totalOut: summary?.totalOut ?? Money.zero(displayCurrency),
          colorTheme: summary?.colorTheme,
          accentHex: summary?.accentHex,
          // MALI-074n: the summary's own currency (the totals are per-currency),
          // not a guess from the first transaction row.
          currency: (summary?.currency.isNotEmpty ?? false)
              ? summary!.currency
              : displayCurrency,
        ),
        const SizedBox(height: AppSpacing.s6),
        Text(context.l10n.cdCardTransactions,
            style: AppTypography.sectionTitle(c.textMain)),
        const SizedBox(height: AppSpacing.s3),
        txAsync.when(
          skipLoadingOnReload: true,
          loading: () => const Center(
              child: Padding(
                  padding: EdgeInsets.all(AppSpacing.cardPadding),
                  child: CircularProgressIndicator())),
          error: (e, _) => AppErrorState(
            title: context.l10n.txnError,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.startRetry,
            onRetry: () => ref.invalidate(cardTransactionsProvider(last4)),
          ),
          data: (txns) {
            if (txns.isEmpty) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const QirshIllustration(
                      name: 'emptyTx', width: 160, height: 120),
                  const SizedBox(height: AppSpacing.s2),
                  Text(context.l10n.cdNoTxYet,
                      textAlign: TextAlign.center,
                      style: AppTypography.callout(c.textLight)),
                ],
              );
            }
            return DayGroupedTransactions(transactions: txns, catalog: catalog);
          },
        ),
      ],
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({
    required this.last4,
    required this.network,
    required this.totalIn,
    required this.totalOut,
    required this.currency,
    this.colorTheme,
    this.accentHex,
  });

  final String last4;
  final CardNetwork network;
  final Money totalIn;
  final Money totalOut;
  final String currency;
  final String? colorTheme;
  final String? accentHex;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s5),
      decoration: BoxDecoration(
        gradient:
            cardGradient(context, themeKey: colorTheme, accentHex: accentHex),
        borderRadius: BorderRadius.circular(22),
        boxShadow: bankCardShadow(context),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 28,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(7),
                  gradient: bankCardChipGradient,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Icon(AppLucideIcons.wifi,
                  color: Colors.white.withValues(alpha: 0.8)),
              const Spacer(),
              CardNetworkBadge(network: network, height: 26),
            ],
          ),
          const SizedBox(height: AppSpacing.s5),
          Directionality(
            textDirection: TextDirection.ltr,
            child: Text('••••  ••••  ••••  $last4',
                style: AppTypography.mono(
                    size: 20,
                    weight: FontWeight.w700,
                    letterSpacing: 2,
                    color: Colors.white)),
          ),
          const SizedBox(height: AppSpacing.s5),
          Row(
            children: [
              Expanded(child: _flow(context, context.l10n.cardIn, totalIn, c.success)),
              const SizedBox(width: AppSpacing.s4),
              Expanded(child: _flow(context, context.l10n.cardOut, totalOut, Colors.white)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _flow(BuildContext context, String label, Money value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.caption(
                Colors.white.withValues(alpha: 0.72))),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Text(
                '${formatMoney(value)} '
                '${Currency.label(context, currency)}',
                style: AppTypography.custom(size: 17,
                    weight: FontWeight.w700, height: 1.3, color: color)),
          ),
        ),
      ],
    );
  }
}
