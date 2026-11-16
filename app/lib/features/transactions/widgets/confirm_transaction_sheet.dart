import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/async_reload_safe.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../core/utils/app_lucide_icons.dart';
import '../../../core/utils/currency.dart';
import '../../../core/utils/l10n_ext.dart';
import '../../../core/utils/formatters.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money_input.dart';
import '../../../domain/finance/money_format.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/usecases/add_transaction_usecase.dart';
import '../../../domain/usecases/correct_category_usecase.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../settings/settings_providers.dart';
import '../../settings/widgets/settings_v2.dart';
import '../../common/app_category_chip.dart';
import '../../common/app_button.dart';
import '../../common/category_catalog.dart';
import '../../dashboard/dashboard_providers.dart';
import '../manual_transaction_sheet.dart';
import '../transactions_providers.dart';
import '../../../core/theme/widgets/app_toast.dart';
import '../../common/repo_error_messages.dart';
import '../../../core/theme/widgets/glass_dropdown_field.dart';

Future<void> showConfirmTransactionSheet(
  BuildContext context,
  String transactionId, {
  String? secondaryNotice,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(_ConfirmSheet(
      transactionId: transactionId,
      secondaryNotice: secondaryNotice,
    )),
  );
}

/// Builds the "we also found a fee/tax in another currency" note for a capture
/// result, or null when the SMS held a single operation.
String? feeNoticeFor(BuildContext context, AddTransactionResult? secondary) {
  if (secondary?.outcome != AddTransactionOutcome.added ||
      secondary?.transaction == null) {
    return null;
  }
  final fee = secondary!.transaction!;
  return context.l10n.ctsFeeAlsoAdded(
      formatMoney(fee.amountMoney), fee.currency);
}

class _ConfirmSheet extends ConsumerStatefulWidget {
  const _ConfirmSheet({required this.transactionId, this.secondaryNotice});

  final String transactionId;

  /// A note shown when the same SMS held a second operation (e.g. a fee/tax in
  /// a different currency) that was saved as its own transaction.
  final String? secondaryNotice;

  @override
  ConsumerState<_ConfirmSheet> createState() => _ConfirmSheetState();
}

class _ConfirmSheetState extends ConsumerState<_ConfirmSheet> {
  String? _selectedCategoryKey;
  final _priceController = TextEditingController();
  bool _confirming = false;

  /// "Remember for this merchant" — off by default (OD-13): picking a chip
  /// here is a one-off unless the user explicitly asks for a rule.
  bool _rememberForMerchant = false;

  @override
  void dispose() {
    _priceController.dispose();
    super.dispose();
  }

  /// A foreign-currency spend parked in the home account with no home value yet
  /// (amount 0). The user prices it by entering the home-currency amount.
  bool _awaitingPricing(TransactionEntity tx) =>
      tx.pricingState == TransactionPricingState.awaitingFx;

  /// Selectable categories with the currently-selected one pinned first, so it
  /// is always visible (otherwise a selection like "أخرى" sits off-screen at the
  /// end of the horizontal list and looks unselected).
  List<CategoryView> _orderedCategories(
      CategoryCatalog catalog, String? selectedKey) {
    final cats = catalog.all
        .where((it) => it.key != 'income' && it.key != 'all_expenses')
        .toList();
    if (selectedKey == null) return cats;
    return [
      ...cats.where((c) => c.key == selectedKey),
      ...cats.where((c) => c.key != selectedKey),
    ];
  }

  /// Why this transaction landed in review — shown to make the AI/parse
  /// decision transparent (most actionable reason first).
  String _pendingReason(TransactionEntity tx, String? categoryKey) {
    if (categoryKey == null) {
      return context.l10n.ctsNeedsCategory;
    }
    if (tx.source == TransactionSourceEntity.aiParsed) {
      return context.l10n.ctsAiParsed;
    }
    if (tx.parseConfidence < 0.92) {
      return context.l10n.ctsLowConfidence;
    }
    return context.l10n.ctsReviewBeforeConfirm;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final txAsync = ref.watch(transactionByIdProvider(widget.transactionId));
    final catalogAsync = ref.watch(categoryCatalogProvider);

    final tx = txAsync.valueOrNull;
    final catalog = catalogAsync.valueOrNull;
    if (tx == null || catalog == null) {
      return const SizedBox(
          height: 200, child: Center(child: CircularProgressIndicator()));
    }

    final currentCategoryKey =
        _selectedCategoryKey ?? catalog.byId(tx.categoryId)?.key;

    return AppSheetScaffold(
      title: context.l10n.ctsTitle,
      scrollable: true,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Amount + Badge (foreign amount shown until it is priced locally)
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              _awaitingPricing(tx)
                  ? '${formatMoney(tx.foreignMoney!)} ${tx.foreignCurrency}'
                  : '${formatMoney(tx.amountMoney)} ${tx.currency}',
              textDirection: TextDirection.ltr,
              style: AppTypography.amountHero(c.textMain),
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: c.accent.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(AppLucideIcons.sparkles, size: 14, color: c.textPrimary),
                const SizedBox(width: 6),
                Text(context.l10n.txnPendingReview,
                    style: AppTypography.caption(c.textPrimary)
                        .copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          Text(
            _pendingReason(tx, currentCategoryKey),
            textAlign: TextAlign.center,
            style: AppTypography.caption(c.textLight),
          ),
          if (widget.secondaryNotice != null) ...[
            const SizedBox(height: AppSpacing.s3),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.successBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.success.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Icon(AppLucideIcons.split, size: 18, color: c.success),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.secondaryNotice!,
                      style: AppTypography.caption(c.textPrimary),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (tx.rawMerchant != null) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(tx.rawMerchant!, style: AppTypography.headline(c.textMain)),
          ],
          if (tx.rawMessage.trim().isNotEmpty) ...[
            const SizedBox(height: AppSpacing.s4),
            Container(
              key: const ValueKey('confirmation-original-message'),
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.surface2,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.txdOriginalText,
                      style: AppTypography.caption(c.textLight)),
                  const SizedBox(height: AppSpacing.s2),
                  SelectableText(tx.rawMessage,
                      textAlign: TextAlign.start,
                      style: AppTypography.callout(c.textMain)),
                ],
              ),
            ),
          ],

          if (_awaitingPricing(tx)) ...[
            const SizedBox(height: AppSpacing.s4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.s3),
              decoration: BoxDecoration(
                color: c.warningBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.warning.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.ctsForeignCurrencyHint(
                        formatMoney(tx.foreignMoney!),
                        tx.foreignCurrency ?? '',
                        Currency.label(context, tx.currency)),
                    style: AppTypography.caption(c.textMain),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  TextField(
                    controller: _priceController,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText:
                          context.l10n.txdValueIn(Currency.label(context, tx.currency)),
                      filled: true,
                      fillColor: c.surface2.withValues(alpha: 0.5),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide(color: c.border),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.s4),

          // Inline Category Quick-Pick
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: Text(context.l10n.ctsCategoryLabel, style: AppTypography.caption(c.textLight)),
          ),
          const SizedBox(height: AppSpacing.s2),
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final cat
                    in _orderedCategories(catalog, currentCategoryKey))
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: AppCategoryChip(
                      label: cat.name,
                      icon: cat.icon,
                      color: cat.key == currentCategoryKey
                          ? c.primary
                          : c.textLight,
                      selected: cat.key == currentCategoryKey,
                      onTap: () {
                        setState(() {
                          _selectedCategoryKey = cat.key;
                        });
                        // Update transaction category quietly — through the
                        // same use case as the details screen, as a one-off.
                        ref
                            .read(correctCategoryUseCaseProvider)(
                              transactionId: tx.id,
                              categoryKey: cat.key,
                              scope:
                                  CategoryCorrectionScope.thisTransactionOnly,
                            )
                            .then((_) {
                          ref.invalidate(transactionByIdProvider(tx.id));
                          refreshTransactions(ref);
                          ref.invalidate(dashboardDataProvider);
                        }).catchError((Object e) {
                          if (!context.mounted) return;
                          final message = e is RepoException
                              ? repoErrorMessage(context, e)
                              : context.l10n.ctsCategoryUpdateFailed;
                          AppToast.showError(context, message);
                        });
                      },
                    ),
                  ),
              ],
            ),
          ),

          if (tx.rawMerchant != null && _selectedCategoryKey != null) ...[
            const SizedBox(height: AppSpacing.s3),
            // Same v2 switch row as the change-category sheet's options.
            Material(
              color: c.surfaceElevated,
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(AppRadius.card),
              child: SettingsV2SwitchRow(
                key: const ValueKey('confirm-remember-merchant'),
                title: context.l10n.ccAllMerchant,
                subtitle:
                    ref.watch(sharedLearningActiveProvider).valueOrNull == true
                        ? '${context.l10n.ccRememberHint}\n'
                            '${context.l10n.ccSharedLearningHint}'
                        : context.l10n.ccRememberHint,
                value: _rememberForMerchant,
                onChanged: (v) => setState(() => _rememberForMerchant = v),
              ),
            ),
          ],

          const SizedBox(height: AppSpacing.s4),

          // Account & Date Inline Row
          Container(
            padding: const EdgeInsets.all(AppSpacing.s3),
            decoration: BoxDecoration(
              color: c.surface2.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: c.border),
            ),
            child: Row(
              children: [
                Icon(AppLucideIcons.calendar, size: 18, color: c.textLight),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: Text(
                    '${Formatters.dateWithWeekday(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt, context)}',
                    style: AppTypography.caption(c.textMain),
                  ),
                ),
                if (tx.cardLast4 != null) ...[
                  Container(
                      width: 1,
                      height: 16,
                      color: c.border,
                      margin: const EdgeInsets.symmetric(horizontal: 8)),
                  Text(context.l10n.pfCardNamed(tx.cardLast4 ?? ''),
                      style: AppTypography.caption(c.textLight)),
                ],
              ],
            ),
          ),

          ref.watch(accountsProvider).dataOrWhen(
                data: (accounts) {
                  if (accounts.length < 2) return const SizedBox.shrink();
                  final value = accounts.any((a) => a.id == tx.accountId)
                      ? tx.accountId
                      : accounts.first.id;
                  return Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s3),
                    child: GlassDropdownField<String>(
                      value: value,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: context.l10n.commonAccountDefinite,
                        prefixIcon: const Icon(AppLucideIcons.walletCards),
                        filled: true,
                        fillColor: c.surface2.withValues(alpha: 0.5),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: c.border),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(16),
                          borderSide: BorderSide(color: c.border),
                        ),
                      ),
                      items: [
                        for (final account in accounts)
                          DropdownMenuItem(
                            value: account.id,
                            child: Text(
                              '${account.name} · ${Currency.label(context, account.currency)}',
                            ),
                          ),
                      ],
                      onChanged: (id) async {
                        if (id == null) return;
                        try {
                          await ref
                              .read(transactionRepositoryProvider)
                              .updateAccount(
                                transactionId: tx.id,
                                accountId: id,
                              );
                        } on RepoException catch (e) {
                          if (!context.mounted) return;
                          AppToast.showError(context, repoErrorMessage(context, e));
                          return;
                        }
                        ref.invalidate(
                            transactionByIdProvider(widget.transactionId));
                        ref.invalidate(dashboardDataProvider);
                      },
                    ),
                  );
                },
                orElse: () => const SizedBox.shrink(),
              ),

          const SizedBox(height: AppSpacing.s5),

          AppButton(
            label: context.l10n.txdConfirmTx,
            loading: _confirming,
            onPressed: _confirming
                ? null
                : () async {
                    setState(() => _confirming = true);
                    try {
                      // Price a foreign "awaiting pricing" spend if a value was typed.
                      if (_awaitingPricing(tx)) {
                        try {
                          final priced = parseLocalizedMoney(
                              _priceController.text, tx.currency);
                          if (priced.minorUnits <= 0) return;
                          try {
                            await ref
                                .read(transactionRepositoryProvider)
                                .updateAmount(
                                  transactionId: tx.id,
                                  amount: priced,
                                );
                          } on RepoException catch (e) {
                            if (!context.mounted) return;
                            AppToast.showError(context, repoErrorMessage(context, e));
                            return;
                          }
                        } on Exception {
                          return;
                        }
                      }
                      // Teach only on an explicit "remember".
                      final pickedKey = _selectedCategoryKey;
                      if (_rememberForMerchant &&
                          pickedKey != null &&
                          tx.rawMerchant != null) {
                        await ref.read(correctCategoryUseCaseProvider)(
                          transactionId: tx.id,
                          categoryKey: pickedKey,
                          scope:
                              CategoryCorrectionScope.allMerchantTransactions,
                        );
                      }
                      if (tx.status == TransactionStatus.pending) {
                        await ref.read(confirmTransactionUseCaseProvider)(
                          tx.id,
                        );
                      }
                      refreshTransactions(ref);
                      ref.invalidate(dashboardDataProvider);
                      if (context.mounted) Navigator.of(context).pop();
                    } on RepoException catch (e) {
                      if (!context.mounted) return;
                      AppToast.showError(context, repoErrorMessage(context, e));
                    } catch (_) {
                      if (!context.mounted) return;
                      AppToast.showError(
                          context, context.l10n.ctsConfirmFailed);
                    } finally {
                      if (mounted) setState(() => _confirming = false);
                    }
                  },
            isPrimary: true,
          ),
          const SizedBox(height: AppSpacing.s2),
          AppButton(
            label: context.l10n.ctsEditDetails,
            onPressed: () async {
              await ManualTransactionSheet.show(
                context,
                transaction: tx,
              );
              if (!context.mounted) return;
              ref.invalidate(transactionByIdProvider(widget.transactionId));
              refreshTransactions(ref);
              ref.invalidate(dashboardDataProvider);
            },
            isPrimary: false,
          ),
        ],
      ),
    );
  }
}
