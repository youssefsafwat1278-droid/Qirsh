import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/widgets/section_photo_header.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../domain/finance/money_format.dart';
import '../../domain/finance/money.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_check_mark.dart';
import '../common/app_screen_scaffold.dart';
import '../common/money_text.dart';
import '../common/motion.dart';
import '../common/app_header.dart';
import '../common/app_card.dart';
import '../common/app_error_state.dart';
import '../common/app_empty_state.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../transactions/manual_transaction_sheet.dart';
import 'mini_card_art.dart';
import 'bank_mark.dart';
import 'card_form_sheet.dart';
import 'card_network_badge.dart';
import 'card_theme.dart';
import 'cards_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';

/// مفتاح مطابقة بطاقة مُدارة (CardEntity) بصفّ معروض: (الحساب، آخر 4 أرقام).
String _cardKey(String? accountId, String last4) => '${accountId ?? ''}|$last4';

/// ملخّص بلا عمليات لبطاقة يدوية أُضيفت للتوّ (لا تظهر بعد في التجميع المشتقّ).
CardSummary _zeroSummary(CardEntity card, String currency) => CardSummary(
      last4: card.last4,
      currency: currency,
      network: card.network,
      totalOut: Money.zero(currency),
      totalIn: Money.zero(currency),
      count: 0,
      colorTheme: card.colorTheme,
      accentHex: card.accentHex,
    );

/// صفحة «بطاقاتي»: كل البطاقات + داخل/خارج/الصافي لكل بطاقة، مع إضافة بطاقة
/// جديدة بتصميم مخصّص، أو إضافة/ربط عملية. تُفتح من الإعدادات.
class MyCardsScreen extends ConsumerWidget {
  const MyCardsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return context.push('/cards');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(accountCardGroupsProvider);
    final grouping = async.valueOrNull;
    final accountsAsync = ref.watch(accountsProvider);
    final cardsAsync = ref.watch(allCardsProvider);
    final accounts = accountsAsync.valueOrNull ?? const [];
    final allCards = cardsAsync.valueOrNull ?? const <CardEntity>[];
    final displayCurrency =
        ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final accountName = {for (final a in accounts) a.id: a.name};
    // بطاقة مُدارة مطابقة لكل صفّ — لتفعيل التعديل (الملخّص وحده بلا id).
    final entityByKey = {
      for (final card in allCards) _cardKey(card.accountId, card.last4): card,
    };

    // بناء أقسام: لكل حساب بطاقاته (مشتقّة + يدوية بلا عمليات) + قسم غير المخصّصة.
    final sections = <Widget>[];
    if (grouping != null) {
      // last4 المملوكة يدويًا لحساب — لإسقاطها من «غير مخصّصة» تفاديًا للتكرار.
      final managedAssigned = <String>{
        for (final card in allCards)
          if (card.accountId != null) card.last4,
      };

      for (final account in accounts) {
        final summaries =
            grouping.byAccount[account.id] ?? const <CardSummary>[];
        final shown = {for (final s in summaries) s.last4};
        final extras = [
          for (final card in allCards)
            if (card.accountId == account.id && !shown.contains(card.last4))
              _zeroSummary(card, account.currency),
        ];
        final combined = [...summaries, ...extras];
        if (combined.isEmpty) continue;
        sections.add(_SectionHeader(title: account.name));
        for (final card in combined) {
          sections.add(_CardRow(
            card: card,
            account: account,
            entity: entityByKey[_cardKey(account.id, card.last4)],
          ));
        }
      }

      // حسابات مربوطة لم تعد في قائمة الحسابات (نادر) — لا نُسقطها.
      for (final entry in grouping.byAccount.entries) {
        if (accountName.containsKey(entry.key)) continue;
        sections.add(_SectionHeader(title: context.l10n.cardAccountWord));
        for (final card in entry.value) {
          sections.add(_CardRow(
            card: card,
            entity: entityByKey[_cardKey(entry.key, card.last4)],
          ));
        }
      }

      // غير المخصّصة: مشتقّة بلا حساب موثوق (وغير مملوكة يدويًا) + يدوية بلا حساب.
      final unassignedBase = [
        for (final s in grouping.unassigned)
          if (!managedAssigned.contains(s.last4)) s,
      ];
      final shownUnassigned = {for (final s in unassignedBase) s.last4};
      final unassignedExtras = [
        for (final card in allCards)
          if (card.accountId == null && !shownUnassigned.contains(card.last4))
            _zeroSummary(card, displayCurrency),
      ];
      final unassigned = [...unassignedBase, ...unassignedExtras];
      if (unassigned.isNotEmpty) {
        sections.add(_SectionHeader(title: context.l10n.cardUnassigned));
        for (final card in unassigned) {
          sections.add(_CardRow(
            card: card,
            entity: entityByKey[_cardKey(null, card.last4)],
          ));
        }
      }
    }

    // v2: «حركة البطاقات» is the one heading; per-account headings only
    // remain when there is more than one group to tell apart (the card row
    // already names its account).
    final groupCount = sections.whereType<_SectionHeader>().length;
    final displaySections = <Widget>[
      if (sections.isNotEmpty) ...[
        PremiumMotion(
          child: _CardDeck(
              rows: sections.whereType<_CardRow>().toList(growable: false)),
        ),
        _SectionHeader(title: context.l10n.cardActivityTitle, primary: true),
      ],
      for (final section in sections)
        if (section is! _SectionHeader || groupCount > 1) section,
    ];

    return AppScreenScaffold(
      scrollHeader: true,
      header: AppHeader(
        sectionPhoto: QirshSectionPhoto.cards,
        title: context.l10n.cardAllCards,
        action: IconButton(
          icon: const Icon(AppLucideIcons.plus, color: Colors.white, size: 22),
          tooltip: context.l10n.cardAddCard,
          onPressed: () => showCardForm(context, ref),
        ),
      ),
      body: async.hasError || accountsAsync.hasError || cardsAsync.hasError
          ? AppErrorState(
              title: context.l10n.cardLoadFailed,
              description: context.l10n.cardLoadFailedBody,
              retryLabel: context.l10n.startRetry,
              onRetry: () {
                ref.invalidate(accountCardGroupsProvider);
                ref.invalidate(accountsProvider);
                ref.invalidate(allCardsProvider);
              },
            )
          : (async.isLoading && grouping == null) ||
                  (accountsAsync.isLoading && !accountsAsync.hasValue) ||
                  (cardsAsync.isLoading && !cardsAsync.hasValue)
              ? const Center(child: CircularProgressIndicator())
              : sections.isEmpty
                  ? _empty(context, ref)
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                          AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
                      itemCount: displaySections.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: AppSpacing.s3),
                      itemBuilder: (_, i) => displaySections[i],
                    ),
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.gutter),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QirshIllustration(
                  name: 'accounts', width: 220, height: 165),
              const SizedBox(height: AppSpacing.s4),
              Text(context.l10n.cardEmptyTitle,
                  style: AppTypography.title2(c.textMain)),
              const SizedBox(height: AppSpacing.s2),
              Text(
                context.l10n.cardEmptyBody,
                textAlign: TextAlign.center,
                style: AppTypography.subhead(c.textLight),
              ),
              const SizedBox(height: AppSpacing.s4),
              FilledButton.icon(
                onPressed: () => showCardForm(context, ref),
                icon: const Icon(AppLucideIcons.plus),
                label: Text(context.l10n.cardAddCardCta),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.primary = false});

  final String title;

  /// The screen's one section title; account group labels are quieter.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: EdgeInsets.only(
          top: primary ? AppSpacing.s5 : AppSpacing.s2, bottom: 2),
      child: Text(title,
          style: primary
              ? AppTypography.sectionTitle(c.textMain)
              : AppTypography.subhead(c.textSecondary)),
    );
  }
}

class _CardRow extends ConsumerWidget {
  const _CardRow({required this.card, this.account, this.entity});

  final CardSummary card;
  final AccountEntity? account;

  /// البطاقة المُدارة المطابقة (إن وُجدت) — أساس التعديل. للبطاقات المشتقّة
  /// فقط تكون null، فيُفتح النموذج مُهيّأً بآخر 4 أرقام/الشبكة لإنشائها.
  final CardEntity? entity;

  void _edit(BuildContext context, WidgetRef ref) {
    final e = entity;
    if (e != null) {
      showCardForm(context, ref, accountId: e.accountId, card: e);
    } else {
      showCardForm(
        context,
        ref,
        accountId: account?.id,
        initialLast4: card.last4,
        initialNetwork: card.network,
      );
    }
  }

  String _title(BuildContext context) =>
      entity?.nickname?.trim().isNotEmpty == true
          ? entity!.nickname!.trim()
          : account?.name ?? context.l10n.cardUnassigned;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final net = card.totalIn - card.totalOut;
    return AppCard(
      key: ValueKey(
          'card-activity-${_cardKey(account?.id ?? entity?.accountId, card.last4)}'),
      onTap: () => context.push('/card/${card.last4}'),
      padding: const EdgeInsets.all(AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(children: [
            MiniCardArt(
                network: card.network,
                themeKey: card.colorTheme,
                accentHex: card.accentHex,
                width: 56),
            const SizedBox(width: AppSpacing.s3),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_title(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTypography.bodyStrong(c.textMain)),
                Text('•••• ${card.last4}',
                    textDirection: TextDirection.ltr,
                    style: AppTypography.mono(
                        size: 13, letterSpacing: 1, color: c.textSecondary)),
                if (entity?.nickname?.trim().isNotEmpty == true &&
                    account != null)
                  Text(account!.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.caption(c.textSecondary)),
              ],
            )),
            IconButton(
                onPressed: () => _edit(context, ref),
                tooltip: context.l10n.cardEdit,
                icon: Icon(AppLucideIcons.pencil, color: c.actionText, size: 18)),
          ]),
          const SizedBox(height: AppSpacing.s3),
          // v2 QStats: in = income colour, out = NEUTRAL text with a coral
          // dot (red is reserved for over-budget / failed / destructive),
          // net neutral; hairline separators, no boxes.
          IntrinsicHeight(
            child: Row(children: [
              Expanded(
                  child: _flow(context, context.l10n.cardIn, card.totalIn,
                      c.success, dot: c.success)),
              VerticalDivider(width: AppSpacing.s4, color: c.border),
              Expanded(
                  child: _flow(context, context.l10n.cardOut, card.totalOut,
                      c.textMain, dot: c.expense)),
              VerticalDivider(width: AppSpacing.s4, color: c.border),
              Expanded(
                  child: _flow(context, context.l10n.rptNet, net, c.textMain)),
            ]),
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(children: [
            Expanded(
                child: _action(context,
                    icon: AppLucideIcons.plus,
                    label: context.l10n.cardAddTx,
                    onTap: () => ManualTransactionSheet.show(context,
                        cardLast4: card.last4))),
            const SizedBox(width: AppSpacing.s2),
            Expanded(
                child: _action(context,
                    icon: AppLucideIcons.link,
                    label: context.l10n.cardLinkExistingTx,
                    onTap: () => _showAttachSheet(context, card.last4))),
          ]),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) =>
      // v2 tinted pill (action.soft + action.text), equal width.
      TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(label,
            maxLines: 2,
            textAlign: TextAlign.center,
            style: AppTypography.subhead(context.colors.actionText)
                .copyWith(fontWeight: FontWeight.w600)),
        style: TextButton.styleFrom(
            minimumSize: const Size(48, 44),
            foregroundColor: context.colors.actionText,
            backgroundColor: context.colors.ctaSoft,
            shape: const StadiumBorder(),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8)),
      );

  Widget _flow(BuildContext context, String label, Money value, Color color,
      {Color? dot}) {
    final c = context.colors;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        if (dot != null) ...[
          Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
          const SizedBox(width: 4),
        ],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTypography.caption(c.textSecondary)),
        ),
      ]),
      const SizedBox(height: 2),
      // Number first, the currency after it as a muted caption run — never
      // «جنيه 0.00».
      FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            textDirection: TextDirection.ltr,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              MoneyText(value, style: AppTypography.amountSmall(color)),
              const SizedBox(width: 4),
              Text(Currency.label(context, value.currency),
                  style: AppTypography.caption(c.textMuted)),
            ],
          )),
    ]);
  }
}

/// Original account-grouped activity follows the approved overlapping art.
/// Each card keeps its own identity and theme; no financial totals are combined.
class _CardDeck extends ConsumerWidget {
  const _CardDeck({required this.rows});
  final List<_CardRow> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SizedBox(
        height: 188 + (rows.length - 1) * 56.0,
        child: Stack(children: [
          for (var i = 0; i < rows.length; i++)
            Positioned(
                top: i * 56.0,
                left: 0,
                right: 0,
                height: 188,
                child: _tile(context, ref, rows[i])),
        ]),
      );

  Widget _tile(BuildContext context, WidgetRef ref, _CardRow row) {
    final card = row.card;
    return Semantics(
      button: true,
      label: '${row._title(context)} •••• ${card.last4}',
      child: Container(
        key: ValueKey(
            'card-deck-${_cardKey(row.account?.id ?? row.entity?.accountId, card.last4)}'),
        decoration: BoxDecoration(
            gradient: cardGradient(context,
                themeKey: card.colorTheme, accentHex: card.accentHex),
            borderRadius: BorderRadius.circular(22),
            boxShadow: [
              // Upward edge so each stacked card separates from the one it
              // overlaps; the front card also carries the v2 bank-card lift.
              BoxShadow(
                  color: Colors.black.withValues(alpha: .18),
                  blurRadius: 24,
                  offset: const Offset(0, -8)),
              if (identical(row, rows.last)) ...bankCardShadow(context),
            ]),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(22),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => context.push('/card/${card.last4}'),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(children: [
                    if (row.account != null) ...[
                      BankMark(
                          accountName: row.account!.name,
                          accountType: row.account!.type,
                          size: 24),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                        child: Text(row._title(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.cardTitle(Colors.white))),
                    CardNetworkBadge(network: card.network),
                    const SizedBox(width: 4),
                    IconButton(
                        key: ValueKey(
                            'card-deck-edit-${_cardKey(row.account?.id ?? row.entity?.accountId, card.last4)}'),
                        tooltip: '${context.l10n.cardEdit} •••• ${card.last4}',
                        onPressed: () => row._edit(context, ref),
                        icon: const Icon(AppLucideIcons.pencil,
                            color: Colors.white, size: 18),
                        constraints:
                            const BoxConstraints(minWidth: 48, minHeight: 48),
                        padding: EdgeInsets.zero),
                  ]),
                  Container(
                      width: 38,
                      height: 28,
                      decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(7),
                          gradient: bankCardChipGradient)),
                  Row(children: [
                    Expanded(
                        child: Text('•••• ${card.last4}',
                            textDirection: TextDirection.ltr,
                            style: AppTypography.mono(
                                size: 20,
                                weight: FontWeight.w700,
                                letterSpacing: 2,
                                color: Colors.white))),
                    Flexible(
                        child: Text(
                            row.account?.name ?? context.l10n.cardUnassigned,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.caption(
                                Colors.white.withValues(alpha: .8)))),
                  ]),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// شيت اختيار عملية موجودة وربطها بالبطاقة [last4].
Future<void> _showAttachSheet(
  BuildContext context,
  String last4,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(_AttachExistingSheet(last4: last4)),
  );
}

class _AttachExistingSheet extends ConsumerStatefulWidget {
  const _AttachExistingSheet({required this.last4});

  final String last4;

  @override
  ConsumerState<_AttachExistingSheet> createState() =>
      _AttachExistingSheetState();
}

class _AttachExistingSheetState extends ConsumerState<_AttachExistingSheet> {
  final _search = TextEditingController();
  // B2-C — the query drives a bounded SQL search (pickTransactionsProvider), so
  // debounce it exactly like the main list: a keystroke burst runs one search,
  // not one DB query per character.
  String _query = '';
  Timer? _searchDebounce;

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// The SQL query already applied the search; only the display order remains —
  /// transactions NOT linked to this card appear first.
  List<TransactionEntity> _sortForCard(List<TransactionEntity> items) {
    final last4 = widget.last4;
    final sorted = [...items]..sort((a, b) {
        final aOwn = a.cardLast4 == last4 ? 1 : 0;
        final bOwn = b.cardLast4 == last4 ? 1 : 0;
        return aOwn.compareTo(bOwn);
      });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final last4 = widget.last4;
    final async = ref.watch(pickTransactionsProvider(_query));
    final items =
        _sortForCard(async.valueOrNull ?? const <TransactionEntity>[]);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Material(
        // The populated list owns another Material inside the colored surface,
        // so ListTile ink paints above that surface rather than beneath it.
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.s3),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textLight.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                    AppSpacing.gutter, AppSpacing.gutter, AppSpacing.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.cardLinkTxTo(last4),
                        style: AppTypography.title2(c.textMain)),
                    const SizedBox(height: AppSpacing.s3),
                    TextField(
                      controller: _search,
                      style: AppTypography.body(c.textMain),
                      onChanged: _onQueryChanged,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: context.l10n.cardSearchHint,
                        prefixIcon: const Icon(AppLucideIcons.search, size: 20),
                        filled: true,
                        fillColor: c.surface2.withValues(alpha: 0.45),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: c.border),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : async.hasError
                        ? SingleChildScrollView(
                            controller: controller,
                            child: AppErrorState(
                              title: context.l10n.txnError,
                              description: context.l10n.annTryAgainSoon,
                              retryLabel: context.l10n.startRetry,
                              onRetry: () => ref
                                  .invalidate(pickTransactionsProvider(_query)),
                            ),
                          )
                        : items.isEmpty
                            ? SingleChildScrollView(
                                controller: controller,
                                child: AppEmptyState(
                                  icon: AppLucideIcons.receipt,
                                  title: context.l10n.cardNoTx,
                                  subtitle: '',
                                  illustration: const QirshIllustration(
                                      name: 'emptyTx', width: 120, height: 90),
                                ),
                              )
                            : Material(
                                type: MaterialType.transparency,
                                child: ListView.builder(
                                  controller: controller,
                                  itemCount: items.length,
                                  itemBuilder: (_, i) {
                                    final tx = items[i];
                                    final linked = tx.cardLast4 == last4;
                                    return ListTile(
                                      title: Text(
                                          tx.rawMerchant ??
                                              context.l10n.txnTransactionWord,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style:
                                              AppTypography.body(c.textMain)),
                                      subtitle: Text(
                                        '${formatMoney(tx.amountMoney)} ${tx.currency}'
                                        '${tx.cardLast4 != null ? ' • •••• ${tx.cardLast4}' : ''}',
                                        style:
                                            AppTypography.footnote(c.textLight),
                                      ),
                                      trailing: AppCheckMark(selected: linked),
                                      onTap: linked
                                          ? null
                                          : () async {
                                              try {
                                                await ref
                                                    .read(
                                                        transactionRepositoryProvider)
                                                    .updateCard(
                                                      transactionId: tx.id,
                                                      cardLast4: last4,
                                                    );
                                              } on RepoException catch (e) {
                                                if (!context.mounted) return;
                                                AppToast.showError(
                                                    context,
                                                    repoErrorMessage(
                                                        context, e));
                                                return;
                                              }
                                              ref.invalidate(
                                                  cardSummariesProvider);
                                              ref.invalidate(
                                                  accountCardGroupsProvider);
                                              ref.invalidate(
                                                  pickTransactionsProvider);
                                              ref.invalidate(
                                                  cardTransactionsProvider(
                                                      last4));
                                              if (context.mounted) {
                                                Navigator.of(context).pop();
                                                AppToast.show(
                                                    context,
                                                    context.l10n
                                                        .cardTxLinkedTo(last4));
                                              }
                                            },
                                    );
                                  },
                                ),
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
