import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/app_transaction_row.dart';
import '../common/category_catalog.dart';
import '../common/transaction_direction.dart';
import '../transactions/transaction_details_screen.dart';

/// The transactions-list (06) component for a scoped list (an account, a
/// card): one Group per local day under a date header — never one card per
/// transaction — with v2 `QRow`s (amount without the repeated currency).
class DayGroupedTransactions extends ConsumerWidget {
  const DayGroupedTransactions({
    super.key,
    required this.transactions,
    required this.catalog,
  });

  final List<TransactionEntity> transactions;
  final CategoryCatalog? catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};
    final days = <DateTime, List<TransactionEntity>>{};
    for (final tx in transactions) {
      final d = tx.occurredAt.toLocal();
      days.putIfAbsent(DateTime(d.year, d.month, d.day), () => []).add(tx);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final day in days.entries) ...[
          Padding(
            padding: const EdgeInsetsDirectional.only(
                start: 4, bottom: AppSpacing.s2),
            child: Text(Formatters.dateGroupLabel(day.key, context),
                style: AppTypography.subhead(c.textSecondary)),
          ),
          MaliCard(
            style: MaliSurfaceStyle.floating,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              children: [
                for (final tx in day.value) _row(context, tx, logos),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s4),
        ],
      ],
    );
  }

  Widget _row(
      BuildContext context, TransactionEntity tx, Map<String, String> logos) {
    final category = catalog?.byId(tx.categoryId);
    final title =
        tx.rawMerchant ?? category?.name ?? context.l10n.txnTransactionWord;
    return AppTransactionRow(
      title: title,
      amount: tx.amount,
      amountMoney: tx.amountMoney,
      currency: Currency.label(context, tx.currency),
      subtitle:
          '${Formatters.time(tx.occurredAt, context)} · ${category?.name ?? context.l10n.homeUncategorised}',
      categoryIconName: category?.iconName,
      categoryColor: category?.color,
      brandLogoUrl: BrandMark.logoFor(title, logos),
      isPending: tx.status == TransactionStatus.pending,
      awaitingPrice: tx.pricingState == TransactionPricingState.awaitingFx,
      isAi: tx.source == TransactionSourceEntity.aiParsed,
      isDebit: transactionIsDebit(tx),
      horizontalPadding: 14,
      onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
    );
  }
}
