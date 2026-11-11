import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_format.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../cards/brand_mark.dart';
import '../cards/cards_providers.dart';
import '../../domain/entities/card_entity.dart';
import '../common/category_catalog.dart';
import '../common/transaction_direction.dart';
import '../common/widgets.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/app_screen_scaffold.dart';
import '../common/app_header.dart';
import '../common/app_card.dart';
import '../common/app_missing_record_state.dart';
import '../common/app_button.dart';
import '../../core/di/app_providers.dart';
import '../dashboard/dashboard_providers.dart';
import '../subscriptions/subscriptions_providers.dart';
import 'manual_transaction_sheet.dart';
import 'transactions_providers.dart';
import 'widgets/change_category_sheet.dart';
import '../common/motion.dart';
import '../common/money_text.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';

class TransactionDetailsScreen extends ConsumerWidget {
  const TransactionDetailsScreen({super.key, required this.transactionId});

  final String transactionId;

  // Was a `static const` map. Localized copy cannot be const, and a lookup
  // table that is built once at class-load would freeze whichever language
  // happened to be active then.
  static String _typeLabel(BuildContext context, TransactionTypeEntity type) =>
      switch (type) {
        TransactionTypeEntity.payment => context.l10n.txdTypePurchase,
        TransactionTypeEntity.withdrawal => context.l10n.txdTypeCashWithdrawal,
        TransactionTypeEntity.transfer => context.l10n.txdTypeTransfer,
        TransactionTypeEntity.refund => context.l10n.txdTypeRefund,
        TransactionTypeEntity.income => context.l10n.txnKindIncome,
        TransactionTypeEntity.unknown => context.l10n.txdTypeUnknown,
      };

  static String _sourceLabel(
          BuildContext context, TransactionSourceEntity source) =>
      switch (source) {
        TransactionSourceEntity.bank => context.l10n.accTypeBank,
        TransactionSourceEntity.card => context.l10n.txdSourceCard,
        TransactionSourceEntity.wallet => context.l10n.accTypeWallet,
        TransactionSourceEntity.unknown => context.l10n.txdTypeUnknown,
        TransactionSourceEntity.aiParsed => context.l10n.txdSourceAi,
        TransactionSourceEntity.imported => context.l10n.txdSourceImport,
      };

  static Future<void> showSheet(BuildContext context, String transactionId) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      barrierColor: context.colors.scrim,
      builder: (_) => navySheetTheme(
          _TransactionDetailsSheet(transactionId: transactionId)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _TransactionDetailsContent(
        transactionId: transactionId, isSheet: false);
  }
}

class _TransactionDetailsSheet extends StatelessWidget {
  const _TransactionDetailsSheet({required this.transactionId});

  final String transactionId;

  @override
  Widget build(BuildContext context) {
    return _TransactionDetailsContent(
        transactionId: transactionId, isSheet: true);
  }
}

class _TransactionDetailsContent extends ConsumerStatefulWidget {
  const _TransactionDetailsContent(
      {required this.transactionId, required this.isSheet});

  final String transactionId;
  final bool isSheet;

  @override
  ConsumerState<_TransactionDetailsContent> createState() => _TransactionDetailsContentState();
}

class _TransactionDetailsContentState extends ConsumerState<_TransactionDetailsContent> {
  bool _confirming = false;
  bool _deleting = false;
  bool get _busy => _confirming || _deleting;
  String get transactionId => widget.transactionId;
  bool get isSheet => widget.isSheet;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final txAsync = ref.watch(transactionByIdProvider(transactionId));
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;

    return txAsync.when(
      skipLoadingOnReload: true,
      loading: () => _buildScaffold(
          context, c, const Center(child: CircularProgressIndicator())),
      error: (e, _) => _buildScaffold(context, c, AppErrorState(
        title: context.l10n.txnError,
        description: context.l10n.annTryAgainSoon,
        retryLabel: context.l10n.startRetry,
        onRetry: () => ref.invalidate(transactionByIdProvider(transactionId)),
      )),
      data: (tx) {
        if (tx == null) {
          return _buildScaffold(
              context, c, AppMissingRecordState(
                message: context.l10n.txdNotFound, illustration: 'emptyTx'));
        }

        final category = catalog?.byId(tx.categoryId);
        final isDebit = transactionIsDebit(tx);
        final amountColor = isDebit ? c.textPrimary : c.success;
        final merchantTitle = tx.rawMerchant?.trim().isNotEmpty == true
            ? tx.rawMerchant!.trim()
            : category?.name ?? context.l10n.txnTransactionWord;
        // v2 QStatusChip: warningBg/warningText for review, successBg for
        // confirmed (the old beige-on-beige chip failed contrast in light).
        final statusTone = switch (tx.status) {
          TransactionStatus.confirmed => AppStatusTone.success,
          TransactionStatus.pending => AppStatusTone.warning,
          TransactionStatus.ignored => AppStatusTone.neutral,
        };
        final statusLabel = switch (tx.status) {
          TransactionStatus.confirmed => context.l10n.txdConfirmed,
          TransactionStatus.pending => context.l10n.txdNeedsReview,
          TransactionStatus.ignored => context.l10n.txdIgnored,
        };
        final editButton = IconButton(
          tooltip: context.l10n.txnEditTx,
          onPressed: () => ManualTransactionSheet.show(
            context,
            transaction: tx,
          ),
          icon: Icon(AppLucideIcons.pencil, color: c.textPrimary),
        );

        final displayMoney =
            (tx.pricingState == TransactionPricingState.awaitingFx)
                ? tx.foreignMoney!
                : tx.amountMoney;
        final displayCurrency =
            (tx.pricingState == TransactionPricingState.awaitingFx)
                ? '${tx.foreignCurrency}'
                : Currency.label(context, tx.currency);
        final isDark = Theme.of(context).brightness == Brightness.dark;
        // v2 hero aurora: the category colour as a faint radial wash
        // (dark @14% on black, light @10% on the paper canvas).
        final wash = (category?.accent(Theme.of(context).brightness) ??
                c.actionText)
            .withValues(alpha: isDark ? 0.14 : 0.10);
        final confirmAction = tx.status == TransactionStatus.confirmed
            ? null
            : SizedBox(
                width: double.infinity,
                height: AppSpacing.buttonHeight,
                child: FilledButton.icon(
                  onPressed: _busy ? null : () => _confirmTransaction(context, ref, tx.id),
                  style: FilledButton.styleFrom(
                    backgroundColor: c.cta,
                    foregroundColor: c.onCta,
                    disabledBackgroundColor: c.disabled,
                    disabledForegroundColor: c.textMuted,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.button)),
                  ),
                  icon: _confirming
                      ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.38)))
                      : const Icon(AppLucideIcons.check),
                  label: Text(
                    tx.status == TransactionStatus.ignored
                        ? context.l10n.txdConfirmIgnored
                        : context.l10n.txdConfirmTx,
                  ),
                ),
              );

        final body = Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter,
            AppSpacing.s2,
            AppSpacing.gutter,
            AppSpacing.s6,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // v2 hero (no card): 64pt tile → merchant → signed amount with
              // the currency AFTER it → date → status chip, on a faint
              // category-coloured wash.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.35),
                    radius: 0.9,
                    colors: [wash, wash.withValues(alpha: 0)],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(
                      top: AppSpacing.s2, bottom: AppSpacing.s2),
                  child: Center(
                child: Column(
                  children: [
                    (tx.rawMerchant != null &&
                            BrandMark.hasBrand(tx.rawMerchant!))
                        ? AppAvatar.brand(
                            name: tx.rawMerchant!,
                            size: _heroTile,
                            fallback: AppAvatar.category(
                                category: category,
                                size: _heroTile))
                        : AppAvatar.category(
                            category: category, size: _heroTile),
                    const SizedBox(height: AppSpacing.s3),
                    Text(
                      merchantTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: AppTypography.cardTitle(c.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          _HeroAmount(
                            money: displayMoney,
                            isDebit: isDebit,
                            color: amountColor,
                          ),
                          const SizedBox(width: AppSpacing.s2),
                          Text(
                            displayCurrency,
                            style: AppTypography.subhead(c.textMuted),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s1),
                    Text(
                      '${Formatters.dateWithWeekday(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt, context)}',
                      textAlign: TextAlign.center,
                      style: AppTypography.caption(c.textMuted),
                    ),
                    const SizedBox(height: AppSpacing.s3),
                    AppStatusPill(
                      label: statusLabel,
                      tone: statusTone,
                      icon: tx.status == TransactionStatus.pending
                          ? AppLucideIcons.clock
                          : tx.status == TransactionStatus.confirmed
                              ? AppLucideIcons.check
                              : null,
                    ),
                    if (tx.pricingState == TransactionPricingState.awaitingFx &&
                        tx.foreignCurrency != null) ...[
                      const SizedBox(height: AppSpacing.s3),
                      AppButton(
                        label:
                            context.l10n.txdAddValueIn(Currency.label(context, tx.currency)),
                        onPressed: () => _promptForPrice(context, ref, tx),
                        isPrimary: true,
                        height: 42,
                      ),
                    ],
                  ],
                ),
              ),
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              // v2: the category is the one editable thing that matters during
              // review — its own Group row with a tinted «تغيير التصنيف». Edit
              // lives ONLY in the nav bar (no duplicate «تعديل» button).
              AppCard(
                padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
                child: Row(
                  children: [
                    AppAvatar.category(category: category),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            category?.name ?? context.l10n.txdUncategorised,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppTypography.bodyStrong(c.textPrimary),
                          ),
                          Text(
                            context.l10n.txnCategory,
                            style: AppTypography.caption(c.textMuted),
                          ),
                        ],
                      ),
                    ),
                    if (catalog != null) ...[
                      const SizedBox(width: AppSpacing.s2),
                      Flexible(
                        child: _TintedPill(
                          label: context.l10n.txnChangeCategory,
                          onTap: () =>
                              showChangeCategorySheet(context, tx, catalog),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s3),

              // Details Group
              AppCard(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    _buildDetailRow(
                      context,
                      context.l10n.txdType,
                      TransactionDetailsScreen._typeLabel(context, tx.type),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.txdSource,
                      TransactionDetailsScreen._sourceLabel(context, tx.source),
                    ),
                    // UX-034 — the account and the card were compressed into
                    // one «المصدر» line («بطاقة · 1234») with the account
                    // missing entirely. The finding is that linking, unlinking
                    // and reassigning a card is hard to understand, and its
                    // binding constraint is that the UI must "never hide
                    // whether changing a card also changes its account".
                    //
                    // They are separate facts, so they are separate rows. The
                    // account is stated even when there is no card, because a
                    // transaction always belongs to one.
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.commonAccountDefinite,
                      _accountName(ref, tx.accountId),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.txdCard,
                      tx.cardLast4 == null
                          ? context.l10n.txdNoCard
                          : '•••• ${tx.cardLast4}',
                      trailing: TextButton(
                        onPressed: () => _editCard(context, ref, tx),
                        style: TextButton.styleFrom(
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 0),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(context.l10n.txdChange,
                            style: AppTypography.subhead(c.actionText)),
                      ),
                    ),
                    _divider(c),
                    _buildDetailRow(
                      context,
                      context.l10n.dtxCurrency,
                      Currency.label(context, tx.currency),
                    ),
                    if (tx.foreignAmount != null &&
                        tx.foreignCurrency != null) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdOriginalCurrency,
                        '${formatMoney(tx.foreignMoney!)} ${tx.foreignCurrency!}',
                        valueTextDirection: TextDirection.ltr,
                      ),
                    ],
                    if (tx.balanceAfter != null) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdBalanceAfter,
                        '${formatMoney(tx.balanceAfterMoney!)} ${tx.currency}',
                        valueTextDirection: TextDirection.ltr,
                      ),
                    ],
                    if (tx.note != null && tx.note!.isNotEmpty) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdNote,
                        tx.note!,
                      ),
                    ],
                    if (tx.status == TransactionStatus.pending) ...[
                      _divider(c),
                      _buildDetailRow(
                        context,
                        context.l10n.txdStatus,
                        _pendingLabel(context, tx.createdAt),
                        isPending: true,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.s3),

              // Raw text — a disclosure row in its own Group; the message
              // itself sits in an Inset well, monospaced.
              AppCard(
                padding: EdgeInsets.zero,
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding:
                        const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
                    childrenPadding: const EdgeInsets.fromLTRB(
                        AppSpacing.s3, 0, AppSpacing.s3, AppSpacing.s3),
                    shape: const Border(),
                    collapsedShape: const Border(),
                    title: Text(context.l10n.txdOriginalText,
                        style: AppTypography.callout(c.textPrimary)),
                    collapsedIconColor: c.textMuted,
                    iconColor: c.actionText,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(AppSpacing.s3),
                        decoration: BoxDecoration(
                          // v2 Inset: dark well #0C0D11; light #EEF1F8.
                          color: isDark ? c.surfaceMuted : c.surfaceElevated,
                          borderRadius: BorderRadius.circular(AppRadius.button),
                        ),
                        child: SelectableText(
                          tx.rawMessage,
                          style: AppTypography.mono(
                              size: 13, height: 1.5, color: c.textPrimary),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.s5),
              // Destructive = plain danger text, well away from the primary
              // (which now lives in the sticky dock).
              TextButton.icon(
                onPressed: _busy ? null : () => _confirmDelete(context, ref, tx.id),
                style: TextButton.styleFrom(foregroundColor: c.danger),
                icon: const Icon(AppLucideIcons.trash2),
                label: Text(context.l10n.txdDeleteTx,
                    style: AppTypography.bodyStrong(_busy ? Theme.of(context).disabledColor : c.danger)),
              ),
            ],
          ),
        );

        return _buildScaffold(context, c, body,
            title: context.l10n.txdTitle,
            trailing: editButton,
            bottomAction: confirmAction);
      },
    );
  }

  /// UX-034 — the account a transaction belongs to, by name.
  ///
  /// Falls back to a plain «—» rather than the raw id: a UUID on a detail sheet
  /// answers nothing, and an unresolvable account is a data question rather
  /// than something to render at the user.
  String _accountName(WidgetRef ref, String? accountId) {
    if (accountId == null) return '—';
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    for (final a in accounts) {
      if (a.id == accountId) return a.name;
    }
    return '—';
  }

  /// UX-034 — reassign or detach the transaction's card.
  ///
  /// The repository's `updateCard` writes `card_last4` and nothing else, so the
  /// account genuinely does not move with it. That is the finding's binding
  /// constraint — *"never hide whether changing a card also changes its
  /// account"* — and since the answer is "it doesn't", the sheet says so
  /// outright instead of leaving the user to infer it.
  ///
  /// Only cards belonging to the transaction's OWN account are offered.
  /// Offering every card in the app would invite a pairing that contradicts the
  /// account shown one row above.
  Future<void> _editCard(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity tx,
  ) async {
    final choice = await showModalBottomSheet<String?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => navySheetTheme(Consumer(
        builder: (sheetContext, sheetRef, _) {
          final sc = sheetContext.colors;
          final cardsAsync = sheetRef.watch(allCardsProvider);
          final cards = (cardsAsync.valueOrNull ?? const <CardEntity>[])
              .where((card) => card.accountId == tx.accountId)
              .toList(growable: false);
          return AppSheetScaffold(
            title: context.l10n.txdCardSheetTitle,
            subtitle: context.l10n.txdCardSheetNote,
            scrollable: true,
            body: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (cardsAsync.isLoading)
                    const Padding(
                      padding: EdgeInsets.all(AppSpacing.s4),
                      child: Center(child: CircularProgressIndicator(
                        key: ValueKey('transaction-card-picker-loading'))),
                    ),
                  if (cardsAsync.hasError) ...[
                    Text(context.l10n.cardLoadFailed,
                      key: const ValueKey('transaction-card-picker-error'),
                      style: AppTypography.caption(sc.textSecondary),
                      textAlign: TextAlign.center),
                    TextButton(
                      key: const ValueKey('transaction-card-picker-retry'),
                      onPressed: () => sheetRef.invalidate(allCardsProvider),
                      child: Text(context.l10n.startRetry),
                    ),
                  ],
                  for (final card in cards)
                    ListTile(
                      leading: Icon(AppLucideIcons.creditCard, color: sc.cta),
                      title: Text('•••• ${card.last4}',
                          style: AppTypography.subhead(sc.textMain)),
                      trailing: card.last4 == tx.cardLast4
                          ? Icon(AppLucideIcons.check, color: sc.success)
                          : null,
                      onTap: () =>
                          Navigator.of(sheetContext).pop(card.last4),
                    ),
                  if (!cardsAsync.isLoading && !cardsAsync.hasError && cards.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.s3),
                      child: Text(
                        context.l10n.txdNoCardsOnAccount,
                        style: AppTypography.caption(sc.textSecondary),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: AppSpacing.s2),
                  ListTile(
                    leading: Icon(AppLucideIcons.unlink, color: sc.textLight),
                    title: Text(context.l10n.txdNoCard,
                        style: AppTypography.subhead(sc.textMain)),
                    subtitle: Text(
                      context.l10n.txdStaysInAccount,
                      style: AppTypography.caption(sc.textSecondary),
                    ),
                    trailing: tx.cardLast4 == null
                        ? Icon(AppLucideIcons.check, color: sc.success)
                        : null,
                    // Sentinel rather than null: null is also what a dismissed
                    // sheet returns, and "the user backed out" must not be
                    // read as "the user chose to detach the card".
                    onTap: () => Navigator.of(sheetContext).pop('__none__'),
                  ),
                ],
              ),
            ),
          );
        },
      )),
    );

    if (choice == null || !context.mounted) return;
    final next = choice == '__none__' ? null : choice;
    if (next == tx.cardLast4) return;

    await ref
        .read(transactionRepositoryProvider)
        .updateCard(transactionId: tx.id, cardLast4: next);
    ref.invalidate(transactionByIdProvider(tx.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    ref.invalidate(cardSummariesProvider);
    ref.invalidate(allCardsProvider);
    if (!context.mounted) return;
    AppToast.show(context, next == null
        ? context.l10n.txdCardRemoved
        : context.l10n.txdLinkedToCard(next));
  }

  Future<void> _confirmTransaction(
      BuildContext context, WidgetRef ref, String id) async {
    if (_busy) return;
    setState(() => _confirming = true);
    try {
      await ref.read(confirmTransactionUseCaseProvider)(id);
      if (!mounted || !context.mounted) return;
      ref.invalidate(transactionByIdProvider(id));
      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      AppToast.show(context, context.l10n.txdConfirmedToast);
    } on RepoException catch (e) {
      if (context.mounted) AppToast.showError(context, repoErrorMessage(context, e));
    } catch (_) {
      if (context.mounted) AppToast.showError(context, context.l10n.repoErrUnknown);
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, String id) async {
    if (_busy) return;
    setState(() => _deleting = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QirshIllustration(name: 'transactions', width: 120, height: 90),
              const SizedBox(height: AppSpacing.s2),
              Text(context.l10n.txdDeleteTitle, textAlign: TextAlign.center),
            ],
          ),
          content: Text(context.l10n.txdDeleteBody, textAlign: TextAlign.center),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(context.l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(context.l10n.setDelete, style: TextStyle(color: ctx.colors.danger)),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted || !context.mounted) return;
      late final List<String> affectedBillIds;
      try {
        final transactionRepository = ref.read(transactionRepositoryProvider);
        final billRepository = ref.read(billRepositoryProvider);
        affectedBillIds = await ref.read(appDatabaseProvider).transaction(
          () async {
            await transactionRepository.deleteTransaction(id);
            return billRepository.deletePaymentForTransaction(id);
          },
        );
      } on RepoException catch (e) {
        if (!context.mounted) return;
        AppToast.showError(context, repoErrorMessage(context, e));
        return;
      } catch (_) {
        if (!context.mounted) return;
        AppToast.showError(context, context.l10n.repoErrUnknown);
        return;
      }
      if (!mounted) return;
      for (final billId in affectedBillIds) {
        ref.invalidate(billPaymentsProvider(billId));
      }
      if (affectedBillIds.isNotEmpty) {
        ref.invalidate(savedBillsProvider);
        ref.invalidate(billsViewProvider);
      }
      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      if (context.mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Widget _buildScaffold(BuildContext context, AppColors c, Widget body,
      {String? title, Widget? trailing, Widget? bottomAction}) {
    if (isSheet) {
      return AppSheetScaffold(
        title: title ?? context.l10n.txdTitle,
        trailing: trailing,
        // v2 QStickyDock: the one primary stays pinned under the content.
        bottomAction: bottomAction,
        showCloseButton: false,
        leading: IconButton(
          tooltip: context.l10n.annClose,
          onPressed: () => Navigator.of(context).pop(),
          icon: Icon(AppLucideIcons.x, color: c.textSecondary),
        ),
        scrollable: true,
        body: body,
      );
    } else {
      return AppScreenScaffold(
        header: AppHeader(
          title: title ?? context.l10n.txdTitle,
          action: trailing,
          showBack: true,
        ),
        // Immersive: scrolls under the glass bar; content starts below it.
        body: Builder(
          builder: (bodyContext) => SingleChildScrollView(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(bodyContext).top),
            child: body,
          ),
        ),
        bottomArea: bottomAction,
      );
    }
  }

  String _pendingLabel(BuildContext context, DateTime createdAt) {
    final days = DateTime.now().difference(createdAt).inDays;
    if (days == 0) return context.l10n.txdPendingToday;
    return context.l10n.txdPendingDays(days);
  }

  /// Prompts for the home-currency value of a foreign spend that is still
  /// "awaiting pricing" (amount 0), then stores it so it counts in totals.
  Future<void> _promptForPrice(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity tx,
  ) async {
    final controller = TextEditingController();
    String? validationError;
    ModalRoute<dynamic>? priceRoute;
    final value = await showDialog<Money>(
      context: context,
      builder: (ctx) {
        priceRoute = ModalRoute.of(ctx);
        return StatefulBuilder(builder: (ctx, setDialogState) => GlassAlertDialog(
        title: Text(context.l10n.txdValueIn(Currency.label(context, tx.currency))),
        content: TextField(
          key: const ValueKey('transaction-price-amount'),
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: context.l10n.txdAmountIn(Currency.label(context, tx.currency)),
            hintText: '${tx.foreignMoney == null ? '' : formatMoney(tx.foreignMoney!)} '
                '${tx.foreignCurrency ?? ''}',
            errorText: validationError,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () {
              try {
                final amount = parseLocalizedMoney(controller.text, tx.currency);
                if (amount.minorUnits <= 0) {
                  setDialogState(() => validationError = context.l10n.bfInvalidAmount);
                  return;
                }
                Navigator.of(ctx).pop(amount);
              } on Exception {
                setDialogState(() => validationError = context.l10n.bfInvalidAmount);
              }
            },
            child: Text(context.l10n.txdSave),
          ),
        ],
      ));
      },
    );
    await priceRoute?.completed;
    controller.dispose();
    if (!context.mounted) return;
    if (value == null || value.minorUnits <= 0) return;
    try {
      await ref
          .read(transactionRepositoryProvider)
          .updateAmount(transactionId: tx.id, amount: value);
    } on RepoException catch (e) {
      if (!context.mounted) return;
      AppToast.showError(context, repoErrorMessage(context, e));
      return;
    }
    ref.invalidate(transactionByIdProvider(tx.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }

  /// صف تفاصيل: الاسم على جنب والقيمة على الجنب التاني — أهدأ من عمود
  /// بعرض ثابت، والقيم الطويلة بتاخد المساحة اللي فاضلة.
  Widget _buildDetailRow(BuildContext context, String label, String value,
      {Widget? trailing, bool isPending = false, TextDirection? valueTextDirection}) {
    final c = context.colors;
    // v2 details row: 52pt, label muted leading, value body.strong trailing.
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s4, vertical: AppSpacing.s3),
      child: Row(
        children: [
          Text(
            label,
            style: AppTypography.callout(c.textMuted),
          ),
          const SizedBox(width: AppSpacing.s3),
          Expanded(
            child: Text(
              value,
              textDirection: valueTextDirection,
              textAlign: TextAlign.end,
              style: AppTypography.callout(c.textPrimary)
                  .copyWith(fontWeight: FontWeight.w500),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: AppSpacing.s2),
            trailing,
          ],
        ],
      ),
      ),
    );
  }

  Widget _divider(AppColors c) {
    return Divider(
      height: 1,
      thickness: 1,
      color: c.border.withValues(alpha: 0.5),
      indent: AppSpacing.s4,
      endIndent: AppSpacing.s4,
    );
  }
}

/// v2 hero tile: 64pt (the list row's 40pt tile, enlarged).
const double _heroTile = 64;

/// v2 hero amount (`amount.hero`): the sign leads the digits, decimals at 62%
/// (via [MoneyText]), counting up once from 0 (`m.count`; final value
/// immediately under Reduce Motion). The sign is its own run so the digits
/// stay one exact, LTR text.
class _HeroAmount extends StatelessWidget {
  const _HeroAmount({
    required this.money,
    required this.isDebit,
    required this.color,
  });

  final Money money;
  final bool isDebit;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final magnitude = money.isNegative ? -money : money;
    final style = AppTypography.amountHero(color);
    final sign = magnitude.isZero ? '' : isDebit ? '\u2212' : '+';
    final duration = shouldReduceMotion(context)
        ? Duration.zero
        : AppMotion.countFor(magnitude.minorUnits / 100);
    return Row(
      mainAxisSize: MainAxisSize.min,
      textDirection: TextDirection.ltr,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        if (sign.isNotEmpty)
          Text(sign, textDirection: TextDirection.ltr, style: style),
        TweenAnimationBuilder<int>(
          tween: IntTween(begin: 0, end: 1000),
          duration: duration,
          curve: AppMotion.easeOut,
          builder: (context, progress, _) {
            final minor = (BigInt.from(magnitude.minorUnits) *
                    BigInt.from(progress) ~/
                    BigInt.from(1000))
                .toInt();
            return MoneyText(Money(minor, magnitude.currency), style: style);
          },
        ),
      ],
    );
  }
}

/// v2 tinted pill button (`action.soft` fill + `action.text` label).
class _TintedPill extends StatelessWidget {
  const _TintedPill({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: c.ctaSoft,
      borderRadius: BorderRadius.circular(AppRadius.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 36),
          child: Padding(
            padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s3, vertical: 6),
            child: Center(
              widthFactor: 1,
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.subhead(c.actionText),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
