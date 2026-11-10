import 'package:flutter/material.dart';
import '../common/money_text.dart';
import '../../domain/finance/money.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/currency.dart';
import '../../domain/finance/money_format.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../cards/bank_mark.dart';
import '../cards/card_network_badge.dart';
import '../cards/cards_providers.dart';
import 'account_form_sheet.dart';
import '../../core/di/app_providers.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../common/app_error_state.dart';
import '../common/app_header.dart';
import '../common/app_screen_scaffold.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    final unassigned =
        ref.watch(accountCardGroupsProvider).valueOrNull?.unassigned ??
            const <CardSummary>[];
    return AppScreenScaffold(
      scrollHeader: true,
      header: AppHeader(
        title: context.l10n.accTitle,
        sectionPhoto: QirshSectionPhoto.accounts,
      ),
      body: Column(
        children: [
          const _AccountsHeader(),
          Expanded(
            child: accountsAsync.when(
              skipLoadingOnReload: true,
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => SingleChildScrollView(
                  child: AppErrorState(
                title: context.l10n.txnError,
                description: context.l10n.annTryAgainSoon,
                retryLabel: context.l10n.startRetry,
                onRetry: () => ref.invalidate(accountsProvider),
              )),
              data: (accounts) => ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.gutter,
                  AppSpacing.s4,
                  AppSpacing.gutter,
                  120,
                ),
                children: [
                  _CurrencyTotals(accounts: accounts),
                  const SizedBox(height: AppSpacing.s3),
                  if (accounts.isEmpty)
                    const Center(
                      child: QirshIllustration(name: 'accounts'),
                    )
                  else
                    MaliCard(
                      style: MaliSurfaceStyle.floating,
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < accounts.length; i++) ...[
                            if (i > 0)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                child: Divider(height: 1, color: c.border),
                              ),
                            _AccountCard(account: accounts[i]),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: AppSpacing.s3),
                  OutlinedButton.icon(
                    onPressed: () => showAccountForm(context, ref),
                    icon: const Icon(AppLucideIcons.plus),
                    label: Text(context.l10n.accAddAccount),
                    style: OutlinedButton.styleFrom(
                      minimumSize:
                          const Size.fromHeight(AppSpacing.buttonHeight),
                      side: BorderSide(color: c.primary.withValues(alpha: 0.4)),
                    ),
                  ),
                  if (unassigned.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s5),
                    _UnassignedCardsSection(cards: unassigned),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// UX-013 — totals, grouped BY CURRENCY.
///
/// A single "total across accounts" is not available to this app: summing money
/// of different currencies is forbidden by the financial-semantics contract and
/// there is no FX layer. Grouping is the honest form of the same answer — it
/// tells the user how much they have without inventing a rate.
class _CurrencyTotals extends StatelessWidget {
  const _CurrencyTotals({required this.accounts});

  final List<AccountEntity> accounts;

  @override
  Widget build(BuildContext context) {
    final totals = <String, int>{};
    for (final a in accounts) {
      final m = a.currentBalanceMoney;
      if (m == null) continue;
      totals[m.currency] = (totals[m.currency] ?? 0) + m.minorUnits;
    }
    if (totals.isEmpty) return const SizedBox.shrink();

    final entries = totals.entries.toList()
      ..sort((x, y) => y.value.abs().compareTo(x.value.abs()));

    final c = context.colors;
    return MaliCard(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.accTotalBalance,
              style: AppTypography.caption(c.textSecondary)),
          const SizedBox(height: 5),
          for (final e in entries)
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MoneyText(
                  Money(e.value, e.key),
                  style: AppTypography.custom(
                      size: entries.length == 1 ? 24 : 20,
                      weight: FontWeight.w700,
                      height: 1.35,
                      color: e.value < 0 ? c.danger : c.textMain),
                ),
                Text(Currency.label(context, e.key),
                    style: AppTypography.caption(c.textSecondary)),
              ],
            ),
        ],
      ),
    );
  }
}

class _AccountsHeader extends StatelessWidget {
  const _AccountsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding:
          const EdgeInsets.fromLTRB(AppSpacing.gutter, 8, AppSpacing.gutter, 0),
      child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(context.l10n.accSubtitle,
              style: AppTypography.caption(context.colors.textSecondary))),
    );
  }
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({required this.account});

  final AccountEntity account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return InkWell(
      onTap: () => context.push('/account/${account.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            BankMark(
              accountName: account.name,
              accountType: account.type,
              size: 34,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(account.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.bodyStrong(c.textMain)),
                  const SizedBox(height: 3),
                  Text(
                    '${accountTypeLabel(context, account.type)}'
                    '${account.isDefault ? ' · ${context.l10n.accDefault}' : ''}',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            if (account.currentBalanceMoney case final balance?)
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    MoneyText(balance,
                        style: AppTypography.bodyStrong(
                            balance.minorUnits < 0 ? c.warning : c.textMain)),
                    const SizedBox(height: 3),
                    Text(Currency.labelWithCode(context, account.currency),
                        style: AppTypography.caption(c.textLight)),
                  ],
                ),
              )
            else
              Text(Currency.labelWithCode(context, account.currency),
                  style: AppTypography.caption(c.textLight)),
          ],
        ),
      ),
    );
  }
}

/// بطاقات ظهرت في الرسائل لكن بلا حساب موثوق — متوقّع في تطبيق SMS-first.
class _UnassignedCardsSection extends StatelessWidget {
  const _UnassignedCardsSection({required this.cards});

  final List<CardSummary> cards;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.accUnassignedCards,
            style: AppTypography.sectionTitle(c.textMain)),
        const SizedBox(height: 2),
        Text(
          context.l10n.accUnassignedCardsBody,
          style: AppTypography.caption(c.textLight),
        ),
        const SizedBox(height: AppSpacing.s3),
        for (final card in cards) ...[
          _UnassignedCardTile(card: card),
          const SizedBox(height: AppSpacing.s3),
        ],
      ],
    );
  }
}

class _UnassignedCardTile extends StatelessWidget {
  const _UnassignedCardTile({required this.card});

  final CardSummary card;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final net = card.totalIn - card.totalOut;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/card/${card.last4}'),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          children: [
            Icon(AppLucideIcons.creditCard, color: c.textLight, size: 22),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Row(
                textDirection: TextDirection.ltr,
                children: [
                  Text('•••• ${card.last4}',
                      style: AppTypography.bodyStrong(c.textMain)
                          .copyWith(letterSpacing: 1.5)),
                  const SizedBox(width: 8),
                  CardNetworkBadge(network: card.network, height: 18),
                ],
              ),
            ),
            Text(formatMoney(net), style: AppTypography.caption(c.textLight)),
            const SizedBox(width: 6),
            DirectionalChevron(color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}
