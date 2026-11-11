import 'package:flutter/material.dart';

import '../../../core/utils/l10n_ext.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/mali_tokens.dart';
import '../../../core/theme/widgets/mali_card.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_format.dart';
import '../../cards/brand_mark.dart';
import '../../common/app_transaction_row.dart';
import '../../common/category_catalog.dart';
import '../../common/transaction_direction.dart';
import 'home_v2_style.dart';

/// One rendered day inside [TransactionsPanel].
class TransactionDay {
  const TransactionDay({required this.day, required this.transactions});

  final DateTime day;
  final List<TransactionEntity> transactions;
}

/// Groups rows into days, newest day first, preserving each day's row order.
List<TransactionDay> groupByDay(List<TransactionEntity> rows) {
  final byDay = <DateTime, List<TransactionEntity>>{};
  for (final tx in rows) {
    final key =
        DateTime(tx.occurredAt.year, tx.occurredAt.month, tx.occurredAt.day);
    (byDay[key] ??= <TransactionEntity>[]).add(tx);
  }
  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in days) TransactionDay(day: day, transactions: byDay[day]!),
  ];
}

/// Home's «العمليات» panel — the full list, scrolling INSIDE a fixed-height
/// card so every row is reachable without the page growing without end.
///
/// Two honesty rules are load-bearing here:
///   * the day header's total sums **the rows shown**, and says so, because the
///     panel renders a bounded slice of the ledger rather than the whole day;
///   * the counter above the card reports the same bounded slice.
///
/// Presentation only. Rows reuse [AppTransactionRow], the same component the
/// Transactions tab uses, so the two surfaces read as one product.
class TransactionsPanel extends StatelessWidget {
  const TransactionsPanel({
    super.key,
    required this.days,
    required this.catalog,
    required this.privacyMode,
    this.merchantLogos = const <String, String>{},
    this.maxHeight = 352,
    this.compact = false,
    this.onTap,
  });

  final List<TransactionDay> days;
  final CategoryCatalog catalog;
  final bool privacyMode;
  final Map<String, String> merchantLogos;
  final double maxHeight;
  final bool compact;
  final void Function(TransactionEntity tx)? onTap;

  @override
  Widget build(BuildContext context) {
    final t = MaliTokens.of(context);
    if (days.isEmpty) {
      return MaliCard(
        style: MaliSurfaceStyle.floating,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s3),
          child: Text(
            context.l10n.homeNoTxInPeriod,
            textAlign: TextAlign.center,
            style: AppTypography.caption(t.textOnCanvasMuted),
          ),
        ),
      );
    }

    if (compact) {
      final rows = days.expand((day) => day.transactions).toList();
      // v2 Group: the rows live inside one card (light white + e1, dark
      // #121317 + hairline), dividers inset to the text edge.
      return MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(
                    height: 1,
                    indent: 66,
                    endIndent: 14,
                    color: HomeV2.hairline(context)),
              _row(context, rows[i]),
            ],
          ],
        ),
      );
    }

    return MaliCard(
      style: MaliSurfaceStyle.raised,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.builder(
              shrinkWrap: true,
              padding: const EdgeInsets.only(bottom: 4),
              itemCount: days.length,
              itemBuilder: (context, i) => _daySection(context, t, days[i]),
            ),
          ),
          if (days.expand((day) => day.transactions).length > 1)
            _hint(context, t),
        ],
      ),
    );
  }

  Widget _daySection(BuildContext context, MaliTokens t, TransactionDay day) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _dayHeader(context, t, day),
        for (final tx in day.transactions) _row(context, tx),
      ],
    );
  }

  Widget _dayHeader(BuildContext context, MaliTokens t, TransactionDay day) {
    // Net of the SHOWN rows: debits subtract, credits add. Money.sum refuses to
    // mix currencies, so a day is folded per currency and only the display
    // currency's net is stated.
    final currency = day.transactions.isEmpty
        ? 'SAR'
        : day.transactions.first.amountMoney.currency;
    var net = Money.zero(currency);
    for (final tx in day.transactions) {
      if (tx.amountMoney.currency != currency) continue;
      net =
          transactionIsDebit(tx) ? net - tx.amountMoney : net + tx.amountMoney;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              Formatters.dateGroupLabel(day.day, context),
              style: AppTypography.caption(t.textOnCanvasMuted)
                  .copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            privacyMode
                ? '••••'
                // v2: a true minus (U+2212) leads the digits.
                : net.isNegative
                    ? '\u2212${formatMoney(-net)}'
                    : '+${formatMoney(net)}',
            style: AppTypography.custom(
              size: 13,
              weight: FontWeight.w600,
              height: 1.3,
              tabular: true,
              color: t.textOnCanvasSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, TransactionEntity tx) {
    final category = catalog.byId(tx.categoryId);
    final title =
        tx.rawMerchant ?? category?.name ?? context.l10n.txnTransactionWord;
    return AppTransactionRow(
      title: title,
      amount: tx.amount,
      amountMoney: tx.amountMoney,
      currency: Currency.label(context, tx.currency),
      subtitle:
          '${compact ? '${MaterialLocalizations.of(context).formatShortDate(tx.occurredAt.toLocal())} · ' : ''}${Formatters.time(tx.occurredAt, context)} · ${category?.name ?? context.l10n.homeUncategorised}',
      categoryIconName: category?.iconName,
      categoryColor: category?.color,
      brandLogoUrl: BrandMark.logoFor(title, merchantLogos),
      isPending: tx.status == TransactionStatus.pending,
      awaitingPrice: tx.pricingState == TransactionPricingState.awaitingFx,
      isAi: tx.source == TransactionSourceEntity.aiParsed,
      isDebit: transactionIsDebit(tx),
      privacyMode: privacyMode,
      horizontalPadding: 14,
      onTap: onTap == null ? null : () => onTap!(tx),
    );
  }

  /// The affordance that makes a nested scroller discoverable. Without it a
  /// fixed-height list that scrolls inside a scrolling page reads as a list
  /// that simply ends.
  Widget _hint(BuildContext context, MaliTokens t) => Container(
        padding: const EdgeInsets.symmetric(vertical: 9),
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: t.strokeSoft)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(AppLucideIcons.arrowDown,
                size: 13, color: t.textOnCanvasMuted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                context.l10n.homeSwipeForMore,
                textAlign: TextAlign.center,
                style: AppTypography.micro(t.textOnCanvasMuted),
              ),
            ),
          ],
        ),
      );
}
