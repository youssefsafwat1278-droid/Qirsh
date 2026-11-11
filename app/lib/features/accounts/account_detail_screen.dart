import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/utils/l10n_ext.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_entity.dart';
import '../../engine/parser/card_network.dart';
import '../cards/bank_mark.dart';
import '../cards/card_form_sheet.dart';
import '../cards/card_network_label.dart';
import '../cards/card_network_badge.dart';
import '../cards/cards_providers.dart';
import '../common/app_header.dart';
import '../common/category_catalog.dart';
import '../common/widgets.dart';
import 'account_form_sheet.dart';
import 'accounts_providers.dart';
import 'account_hero_surface.dart';
import 'day_grouped_transactions.dart';
import 'accounts_screen.dart' show AccountDefaultChip;
import '../../core/theme/widgets/mali_card.dart';
import '../common/motion.dart';
import '../../core/utils/app_lucide_icons.dart';

/// تفاصيل حساب: بطاقاته المُكتشفة بثقة داخله + آخر عملياته. المسار `/account/:id`.
class AccountDetailScreen extends ConsumerWidget {
  const AccountDetailScreen({super.key, required this.accountId});

  final String accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final accountsAsync = ref.watch(accountsProvider);
    final account = accountsAsync.valueOrNull
        ?.where((a) => a.id == accountId)
        .cast<AccountEntity?>()
        .firstWhere((a) => true, orElse: () => null);

    if (account == null) {
      return Scaffold(
        backgroundColor: c.bg,
        extendBodyBehindAppBar: true,
        appBar: AppHeader(title: context.l10n.commonAccountDefinite),
        // Immersive: the body sits behind the glass nav bar; its height
        // arrives as the body's top inset (read inside the Scaffold).
        body: Builder(builder: (bodyContext) => accountsAsync.hasError
            ? SingleChildScrollView(
                padding: EdgeInsets.only(
                    top: MediaQuery.paddingOf(bodyContext).top),
                child: AppErrorState(
                title: context.l10n.txnError,
                description: context.l10n.annTryAgainSoon,
                retryLabel: context.l10n.startRetry,
                onRetry: () => ref.invalidate(accountsProvider),
              ))
            : Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(bodyContext).top),
          child: Center(
          child: accountsAsync.isLoading
              ? const CircularProgressIndicator()
              : Text(context.l10n.adNotFound, style: AppTypography.body(c.textMain)),
        ),
        )),
      );
    }

    final cards =
        ref.watch(accountCardsProvider(accountId)).valueOrNull ?? const [];
    final txAsync = ref.watch(accountRecentTransactionsProvider(accountId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return Scaffold(
      backgroundColor: c.bg,
      extendBodyBehindAppBar: true,
      appBar: AppHeader(
        title: account.name,
        // UX-014 — this title is user data, not a screen name. «الراجحي —
        // الحساب الجاري» was cut to «الراجحي — الحساب ال…» while a shorter
        // account fitted, so whether you could read your own account's name
        // depended on how long you had named it.
        titleMaxLines: 2,
        trailing: IconButton(
          tooltip: context.l10n.cardEdit,
          icon: Icon(AppLucideIcons.pencil, color: c.actionText),
          onPressed: () => showAccountForm(context, ref, account: account),
        ),
      ),
      // Immersive: the list runs under the glass nav bar, whose height
      // arrives as the body's top inset (read inside the Scaffold).
      body: Builder(builder: (bodyContext) => ListView(
        padding: EdgeInsets.fromLTRB(AppSpacing.gutter,
            MediaQuery.paddingOf(bodyContext).top + AppSpacing.s2,
            AppSpacing.gutter, 120),
        children: [
          PremiumMotion(child: _AccountHeaderCard(account: account)),
          const SizedBox(height: AppSpacing.s5),
          Row(
            children: [
              Expanded(
                child: Text(context.l10n.adCards,
                    style: AppTypography.sectionTitle(c.textMain)),
              ),
              TextButton.icon(
                onPressed: () =>
                    showCardForm(context, ref, accountId: accountId),
                style: TextButton.styleFrom(
                  foregroundColor: c.actionText,
                  minimumSize: const Size(44, 40),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(AppLucideIcons.plus, size: 18),
                label: Text(context.l10n.cardAddCard),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s2),
          if (cards.isEmpty)
            _EmptyCardsRow(label: context.l10n.adNoCards)
          else
            MaliCard(
              style: MaliSurfaceStyle.floating,
              padding: EdgeInsets.zero,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      for (var i = 0; i < cards.length; i++) ...[
                        if (i > 0)
                          Divider(height: 1, indent: AppSpacing.s3,
                              endIndent: AppSpacing.s3, color: c.divider),
                        _ManagedCardRow(accountId: accountId, card: cards[i]),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.s5),
          Text(context.l10n.adRecentTx, style: AppTypography.sectionTitle(c.textMain)),
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
              onRetry: () => ref.invalidate(accountRecentTransactionsProvider(accountId)),
            ),
            data: (txns) {
              if (txns.isEmpty) {
                return Text(context.l10n.cdNoTxYet,
                    style: AppTypography.callout(c.textLight));
              }
              return DayGroupedTransactions(
                  transactions: txns, catalog: catalog);
            },
          ),
        ],
      )),
    );
  }
}

/// Empty «البطاقات» — one dashed-outline Inset row (spec 12 / §3.0): dark
/// 1px white@14% on the well, light 1px strokeSoft on white.
class _EmptyCardsRow extends StatelessWidget {
  const _EmptyCardsRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: isDark ? Colors.white.withValues(alpha: 0.14) : c.strokeSoft,
        radius: 16,
      ),
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: isDark ? c.surfaceMuted : c.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: c.ctaSoft,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(AppLucideIcons.creditCard,
                  size: 18, color: c.actionText),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label, style: AppTypography.subhead(c.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(0.5), Radius.circular(radius)));
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        canvas.drawPath(metric.extractPath(d, d + 5), paint);
        d += 9;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}

/// v2 account hero (spec 12): bank tile + name + «type · currency», the gold
/// «افتراضي» chip, and the account's balance — the same
/// `currentBalanceMoney` the accounts list shows (no new balance logic).
class _AccountHeaderCard extends StatelessWidget {
  const _AccountHeaderCard({required this.account});

  final AccountEntity account;

  @override
  Widget build(BuildContext context) {
    final balance = account.currentBalanceMoney;
    // Spec 12: a compact 148pt hero — identity row, then the balance.
    return AccountHeroSurface(
      padding: const EdgeInsets.all(AppSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(48 * 0.30),
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.2)),
                ),
                child: BankMark(
                  accountName: account.name,
                  accountType: account.type,
                  size: 48,
                ),
              ),
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(account.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.bodyStrong(Colors.white)),
                    const SizedBox(height: 2),
                    Text(
                      '${accountTypeLabel(context, account.type)} · '
                      '${Currency.labelWithCode(context, account.currency)}',
                      style: AppTypography.caption(
                          Colors.white.withValues(alpha: 0.72)),
                    ),
                  ],
                ),
              ),
              if (account.isDefault) const AccountDefaultChip(onHero: true),
            ],
          ),
          if (balance != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Semantics(
              label: context.l10n.accV2Balance,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: CountUpMoneyText(balance,
                    style: AppTypography.amountHero(Colors.white)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// صف بطاقة مُدارة داخل الحساب: يفتح التفاصيل بالنقر، ويعدّل عبر أيقونة القلم.
class _ManagedCardRow extends ConsumerWidget {
  const _ManagedCardRow({required this.accountId, required this.card});

  final String accountId;
  final CardEntity card;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final title =
        card.nickname?.isNotEmpty == true
            ? card.nickname!
            : cardNetworkLabel(context, card.network);
    return InkWell(
      onTap: () => context.push('/card/${card.last4}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s3, vertical: 4),
        child: Row(
          children: [
            Icon(AppLucideIcons.creditCard, color: c.actionText, size: 22),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    textDirection: TextDirection.ltr,
                    children: [
                      Text('•••• ${card.last4}',
                          style: AppTypography.mono(
                              size: 15,
                              weight: FontWeight.w700,
                              letterSpacing: 1.2,
                              color: c.textMain)),
                      if (card.network != CardNetwork.unknown) ...[
                        const SizedBox(width: 8),
                        CardNetworkBadge(network: card.network, height: 16),
                      ],
                    ],
                  ),
                  // UX-015 — «تلقائية / يدوية» is how the code classifies a
                  // card's origin, not how a customer would describe it. The
                  // distinction is worth keeping (it tells the user whether new
                  // transactions will attach to this card by themselves), so it
                  // is restated in plain language rather than hidden.
                  Text(
                    '$title · ${card.source == CardSource.auto ? context.l10n.cardSourceAuto : context.l10n.cardSourceManual}',
                    style: AppTypography.caption(c.textLight),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: context.l10n.cardEdit,
              icon: Icon(AppLucideIcons.pencil, color: c.textLight, size: 20),
              onPressed: () =>
                  showCardForm(context, ref, accountId: accountId, card: card),
            ),
          ],
        ),
      ),
    );
  }
}
