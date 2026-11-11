import 'package:flutter/material.dart';
import '../common/money_text.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
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
import '../common/app_button.dart';
import '../common/motion.dart';
import '../../core/theme/app_motion.dart';
import 'account_hero_surface.dart';

class AccountsScreen extends ConsumerWidget {
  const AccountsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    final unassigned =
        ref.watch(accountCardGroupsProvider).valueOrNull?.unassigned ??
            const <CardSummary>[];
    final baseCurrency = ref.watch(baseCurrencyProvider).valueOrNull;
    return AppScreenScaffold(
      scrollHeader: true,
      header: AppHeader(
        title: context.l10n.accTitle,
        subtitle: context.l10n.accSubtitle,
        sectionPhoto: QirshSectionPhoto.accounts,
      ),
      body: accountsAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => SingleChildScrollView(
            child: AppErrorState(
          title: context.l10n.txnError,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(accountsProvider),
        )),
        data: (accounts) {
          final shares = _AccountShares.of(accounts);
          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s4,
              AppSpacing.gutter,
              120,
            ),
            children: [
              PremiumMotion(
                child: _CurrencyTotals(accounts: accounts, shares: shares),
              ),
              if (accounts.isEmpty)
                const Center(
                  child: QirshIllustration(name: 'accounts'),
                )
              else ...[
                Padding(
                  padding: const EdgeInsetsDirectional.only(
                      top: AppSpacing.s6, bottom: AppSpacing.s3),
                  child: Text(context.l10n.accV2YourAccounts,
                      style: AppTypography.sectionTitle(c.textMain)),
                ),
                PremiumMotion(
                  delay: AppMotion.stagger,
                  child: MaliCard(
                    style: MaliSurfaceStyle.floating,
                    padding: EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      child: Column(
                        children: [
                          for (var i = 0; i < accounts.length; i++) ...[
                            if (i > 0)
                              Padding(
                                padding: const EdgeInsetsDirectional.only(
                                    start: 72),
                                child: Divider(height: 1, color: c.border),
                              ),
                            _AccountCard(
                              account: accounts[i],
                              shareIndex: shares.indexOf(accounts[i].id),
                              baseCurrency: baseCurrency,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: AppSpacing.s4),
              AppSecondaryButton(
                onTap: () => showAccountForm(context, ref),
                icon: AppLucideIcons.plus,
                label: context.l10n.accAddAccount,
              ),
              if (unassigned.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.s6),
                _UnassignedCardsSection(cards: unassigned),
              ],
            ],
          );
        },
      ),
    );
  }
}

/// The accounts that make up the composition bar: positive balances in the
/// dominant currency (no FX — a share across currencies would be invented),
/// in list order. Index = colour key shared by the bar and the row keyline.
class _AccountShares {
  _AccountShares(this.ids, this.minor);

  final List<String> ids;
  final List<int> minor;

  int? indexOf(String id) {
    final i = ids.indexOf(id);
    return i < 0 ? null : i;
  }

  static _AccountShares of(List<AccountEntity> accounts) {
    final totals = <String, int>{};
    for (final a in accounts) {
      final m = a.currentBalanceMoney;
      if (m == null) continue;
      totals[m.currency] = (totals[m.currency] ?? 0) + m.minorUnits.abs();
    }
    if (totals.isEmpty) return _AccountShares(const [], const []);
    final dominant = (totals.entries.toList()
          ..sort((x, y) => y.value.compareTo(x.value)))
        .first
        .key;
    final ids = <String>[];
    final minor = <int>[];
    for (final a in accounts) {
      final m = a.currentBalanceMoney;
      if (m == null || m.currency != dominant || m.minorUnits <= 0) continue;
      ids.add(a.id);
      minor.add(m.minorUnits);
    }
    // A one-segment bar says nothing; the row keys then stay off as well.
    if (ids.length < 2) return _AccountShares(const [], const []);
    return _AccountShares(ids, minor);
  }
}

/// UX-013 — totals, grouped BY CURRENCY.
///
/// A single "total across accounts" is not available to this app: summing money
/// of different currencies is forbidden by the financial-semantics contract and
/// there is no FX layer. Grouping is the honest form of the same answer — it
/// tells the user how much they have without inventing a rate.
class _CurrencyTotals extends StatelessWidget {
  const _CurrencyTotals({required this.accounts, required this.shares});

  final List<AccountEntity> accounts;
  final _AccountShares shares;

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
    final lead = entries.first;

    // v2 Hero: the currency moves onto the label line above the hero amount
    // («إجمالي الأرصدة · جنيه»); further currencies follow as their own lines.
    return AccountHeroSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
              '${context.l10n.accTotalBalance} · '
              '${Currency.label(context, lead.key)}',
              style: AppTypography.caption(
                  Colors.white.withValues(alpha: 0.8))),
          const SizedBox(height: AppSpacing.s1),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: CountUpMoneyText(
              Money(lead.value, lead.key),
              style: AppTypography.amountHero(Colors.white),
            ),
          ),
          for (final e in entries.skip(1))
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                MoneyText(
                  Money(e.value, e.key),
                  style: AppTypography.amountMedium(
                      Colors.white.withValues(alpha: 0.8)),
                ),
                Text(Currency.label(context, e.key),
                    style: AppTypography.caption(
                        Colors.white.withValues(alpha: 0.64))),
              ],
            ),
          if (shares.ids.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            _CompositionBar(minor: shares.minor),
          ],
        ],
      ),
    );
  }
}

/// 8pt account-share bar on the hero, white tints @100/70/45/25% in both
/// themes; segments grow from the leading edge, 60ms apart, once.
class _CompositionBar extends StatelessWidget {
  const _CompositionBar({required this.minor});

  final List<int> minor;

  @override
  Widget build(BuildContext context) {
    final total = minor.fold<int>(0, (a, b) => a + b);
    final reduce = shouldReduceMotion(context);
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ExcludeSemantics(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: SizedBox(
          height: 8,
          child: Row(
            children: [
              for (var i = 0; i < minor.length; i++)
                Expanded(
                  // At least 1 flex so a tiny share still shows as a sliver.
                  flex: ((minor[i] / total) * 1000).round().clamp(1, 1000),
                  child: Padding(
                    padding: EdgeInsetsDirectional.only(
                        end: i == minor.length - 1 ? 0 : 2),
                    child: reduce
                        ? _segment(i)
                        // Ticker-only stagger (no delay Timers): each
                        // segment grows from the leading edge, 60ms apart.
                        : TweenAnimationBuilder<double>(
                            tween: Tween(begin: 0, end: 1),
                            duration: AppMotion.moderate +
                                Duration(milliseconds: 60 * i),
                            curve: Interval(
                              (60 * i) /
                                  (AppMotion.moderate.inMilliseconds + 60 * i),
                              1,
                              curve: AppMotion.easeOut,
                            ),
                            builder: (context, t, child) => Transform.scale(
                              scaleX: t,
                              scaleY: 1,
                              alignment: rtl
                                  ? Alignment.centerRight
                                  : Alignment.centerLeft,
                              child: child,
                            ),
                            child: _segment(i),
                          ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(int i) => ColoredBox(
        color: Colors.white.withValues(alpha: accountShareAlpha(i)),
        child: const SizedBox.expand(),
      );
}

class _AccountCard extends ConsumerWidget {
  const _AccountCard({
    required this.account,
    required this.shareIndex,
    required this.baseCurrency,
  });

  final AccountEntity account;

  /// Position in the hero's composition bar, or null when not part of it.
  final int? shareIndex;

  /// The currency code is only shown when it differs from this.
  final String? baseCurrency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final showCurrency = baseCurrency == null ||
        account.currency.toUpperCase() != baseCurrency!.toUpperCase();
    return InkWell(
      onTap: () => context.push('/account/${account.id}'),
      child: Stack(
        children: [
          if (shareIndex != null)
            PositionedDirectional(
              start: 0,
              top: 16,
              bottom: 16,
              width: 3,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.cta.withValues(alpha: accountShareAlpha(shareIndex!)),
                  borderRadius: const BorderRadiusDirectional.horizontal(
                      end: Radius.circular(3)),
                ),
              ),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  BankMark(
                    accountName: account.name,
                    accountType: account.type,
                    size: 44,
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
                        Wrap(
                          spacing: 6,
                          runSpacing: 2,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(accountTypeLabel(context, account.type),
                                style: AppTypography.caption(c.textLight)),
                            if (account.isDefault) const AccountDefaultChip(),
                          ],
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
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: AlignmentDirectional.centerEnd,
                            child: MoneyText(balance,
                                style: AppTypography.amountSmall(
                                    balance.minorUnits < 0
                                        ? c.warningText
                                        : c.textMain)),
                          ),
                          if (showCurrency) ...[
                            const SizedBox(height: 3),
                            Text(Currency.labelWithCode(context, account.currency),
                                style: AppTypography.caption(c.textLight)),
                          ],
                        ],
                      ),
                    )
                  else
                    Text(Currency.labelWithCode(context, account.currency),
                        style: AppTypography.caption(c.textLight)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// «افتراضي» — the gold-soft chip (spec §3.0 11/12), shared with the account
/// detail hero.
class AccountDefaultChip extends StatelessWidget {
  const AccountDefaultChip({super.key, this.onHero = false});

  /// On the brand gradient the chip is a white tint with gold-lit text.
  final bool onHero;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: onHero ? Colors.white.withValues(alpha: 0.16) : c.goldSoft,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Text(context.l10n.accDefault,
          style: AppTypography.overline(
              onHero ? AppBrandAccent.goldLit : c.goldText)),
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
        MaliCard(
          style: MaliSurfaceStyle.floating,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < cards.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(start: 50),
                    child: Divider(height: 1, color: c.border),
                  ),
                _UnassignedCardTile(card: cards[i]),
              ],
            ],
          ),
        ),
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
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.s4),
        child: Row(
          children: [
            Icon(AppLucideIcons.creditCard, color: c.textLight, size: 22),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Row(
                textDirection: TextDirection.ltr,
                children: [
                  Flexible(
                    child: Text('•••• ${card.last4}',
                        maxLines: 1,
                        overflow: TextOverflow.fade,
                        softWrap: false,
                        style: AppTypography.mono(
                            size: 15,
                            weight: FontWeight.w700,
                            letterSpacing: 1.5,
                            color: c.textMain)),
                  ),
                  const SizedBox(width: 8),
                  CardNetworkBadge(network: card.network, height: 18),
                ],
              ),
            ),
            Text(formatMoney(net),
                textDirection: TextDirection.ltr,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(width: 6),
            DirectionalChevron(color: c.textLight, size: 20),
          ],
        ),
      ),
    );
  }
}
