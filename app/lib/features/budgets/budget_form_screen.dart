import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../core/utils/l10n_ext.dart';

import '../../core/di/app_providers.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/entities/account_entity.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/widgets/segmented_control.dart';
import '../common/app_card.dart';
import '../common/motion.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/budget_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_button.dart';
import '../common/category_catalog.dart';
import '../common/app_avatar.dart';
import 'budgets_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../common/app_header.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';
import '../common/app_error_state.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return AppTypography.custom(
    size: size,
    weight: weight,
    height: height,
    color: color,
    shadows: shadows,
    tabular: tabular,
  );
}

class BudgetFormScreen extends ConsumerStatefulWidget {
  const BudgetFormScreen({super.key, this.budgetId});

  final String? budgetId;

  static Future<void> showSheet(BuildContext context, {String? budgetId}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: navySheetTheme(_BudgetFormSheet(budgetId: budgetId)),
      ),
    );
  }

  @override
  ConsumerState<BudgetFormScreen> createState() => _BudgetFormScreenState();
}

class _BudgetFormScreenState extends ConsumerState<BudgetFormScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppHeader(
        title: widget.budgetId == null ? context.l10n.bfsNewBudget : context.l10n.bdgEditBudget,
      ),
      body: _BudgetFormContent(budgetId: widget.budgetId, fullScreen: true),
    );
  }
}

class _BudgetFormSheet extends StatelessWidget {
  const _BudgetFormSheet({this.budgetId});

  final String? budgetId;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Directionality(
      textDirection: Directionality.of(context),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        child: MaliGlass(
          variant: MaliGlassVariant.sheet,
          nativeMaterial: true,
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.85,
            child: Column(
              children: [
                const SizedBox(height: 12),
                Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.textLight.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(99),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                  child: Row(
                    children: [
                      Text(
                        budgetId == null ? context.l10n.bfsNewBudget : context.l10n.bdgEditBudget,
                        style: AppTypography.title2(c.textMain),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: Icon(AppLucideIcons.x, color: c.textMain),
                        style: IconButton.styleFrom(
                          backgroundColor: c.surface.withValues(alpha: 0.4),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SafeArea(
                    top: false,
                    child: _BudgetFormContent(budgetId: budgetId, fullScreen: false),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BudgetFormContent extends ConsumerStatefulWidget {
  const _BudgetFormContent({
    required this.fullScreen,
    this.budgetId,
  });

  final String? budgetId;
  final bool fullScreen;

  @override
  ConsumerState<_BudgetFormContent> createState() => _BudgetFormContentState();
}

class _BudgetFormContentState extends ConsumerState<_BudgetFormContent> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  BudgetPeriod _period = BudgetPeriod.monthly;
  int _alertThreshold = BudgetEntity.defaultAlertThresholdPercent;
  String? _categoryId;
  String? _accountId;
  bool _didSeedInitialState = false;
  bool _suggestionLoading = false;
  bool _saving = false;
  bool _showAllCategories = false;
  Money? _suggestedAmount;
  String? _suggestionKey;

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final budgetAsync = widget.budgetId == null
        ? const AsyncValue<BudgetEntity?>.data(null)
        : ref.watch(budgetByIdProvider(widget.budgetId!));
    final categoriesAsync = ref.watch(categoryCatalogProvider);
    final accounts =
        ref.watch(accountsProvider).valueOrNull ?? <AccountEntity>[];
    final selectedAccount = _selectedAccount(accounts);
    final baseCurrency = ref.watch(baseCurrencyProvider).valueOrNull ?? 'SAR';
    final currencyLabel =
        Currency.label(context, selectedAccount?.currency ?? baseCurrency);
    // Full screen: the body runs under the glass nav bar, whose height
    // arrives as the top inset. The sheet has its own header — no inset.
    final topInset =
        widget.fullScreen ? MediaQuery.paddingOf(context).top : 0.0;

    return budgetAsync.when(
      skipLoadingOnReload: true,
      loading: () => Padding(
          padding: EdgeInsets.only(top: topInset),
          child: const Center(child: CircularProgressIndicator())),
      error: (error, _) => SingleChildScrollView(
          padding: EdgeInsets.only(top: topInset),
          child: AppErrorState(
        title: context.l10n.txnError,
        description: context.l10n.annTryAgainSoon,
        retryLabel: context.l10n.startRetry,
        onRetry: () => ref.invalidate(budgetByIdProvider(widget.budgetId!)),
      )),
      data: (budget) {
        return categoriesAsync.when(
          skipLoadingOnReload: true,
          loading: () => Padding(
              padding: EdgeInsets.only(top: topInset),
              child: const Center(child: CircularProgressIndicator())),
          error: (error, _) => SingleChildScrollView(
              padding: EdgeInsets.only(top: topInset),
              child: AppErrorState(
            title: context.l10n.txnError,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.startRetry,
            onRetry: () => ref.invalidate(categoryCatalogProvider),
          )),
          data: (catalog) {
            _seedInitialState(budget);
            return Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ListView(
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                padding: EdgeInsets.fromLTRB(
                    AppSpacing.gutter, topInset + 8, AppSpacing.gutter, 8),
                children: [
                  // v2: the amount comes first and is the hero of the form.
                  _FormField(
                    padding: const EdgeInsets.fromLTRB(
                        AppSpacing.s4, AppSpacing.s3, AppSpacing.s4, AppSpacing.s2),
                    child: Column(
                      children: [
                        Text('${context.l10n.bdgAmount} · $currencyLabel',
                            style: AppTypography.caption(c.textMuted)),
                        TextFormField(
                          controller: _amountController,
                          keyboardType: const TextInputType.numberWithOptions(
                              decimal: true),
                          textAlign: TextAlign.center,
                          style: AppTypography.amountHero(c.textMain),
                          decoration: InputDecoration(
                            hintText: '0',
                            hintStyle: AppTypography.amountHero(c.textFaint),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            errorBorder: InputBorder.none,
                            focusedErrorBorder: InputBorder.none,
                            filled: false,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 6),
                          ),
                          validator: (value) {
                            try {
                              final amount = parseLocalizedMoney(
                                  value ?? '', budget?.currency ?? baseCurrency);
                              if (amount.minorUnits > 0) return null;
                            } catch (_) {
                              return context.l10n.gfEnterValidAmount;
                            }
                            return context.l10n.gfEnterValidAmount;
                          },
                        ),
                      ],
                    ),
                  ),
                  if (budget == null) ...[
                    const SizedBox(height: AppSpacing.s2),
                    _BudgetSuggestionCard(
                      loading: _suggestionLoading,
                      amount: _suggestedAmount,
                      period: _period,
                      onApply: _suggestedAmount == null
                          ? null
                          : () {
                              HapticFeedback.lightImpact();
                              setState(() {
                                _amountController.text =
                                    _suggestedAmount!.toDecimalString();
                              });
                            },
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s5),
                  _PeriodSelector(
                    value: _period,
                    onChanged: (value) {
                      setState(() => _period = value);
                      _refreshSuggestedAmount();
                    },
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  FormField<String>(
                    key: ValueKey('budget-category-$_categoryId'),
                    initialValue: _categoryId,
                    validator: (value) => value == null ? context.l10n.bfsPickCategory : null,
                    builder: (field) {
                      final choices = <(String, String, CategoryView?)>[
                        (BudgetEntity.allExpensesCategoryId, context.l10n.bdgAllExpenses, null),
                        for (final category in catalog.all.where((it) =>
                            it.key != 'income' && it.key != BudgetEntity.allExpensesCategoryKey))
                          (category.id, category.name, category),
                      ];
                      // Two rows (8 tiles) + «عرض الكل»; a selection beyond the
                      // first two rows keeps the grid open so it stays visible.
                      final selectedAt =
                          choices.indexWhere((it) => it.$1 == _categoryId);
                      final canCollapse = choices.length > 8;
                      final expanded =
                          !canCollapse || _showAllCategories || selectedAt >= 8;
                      final visible =
                          expanded ? choices : choices.take(8).toList();
                      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Text(context.l10n.txnCategory,
                                style: AppTypography.sectionTitle(c.textMain)),
                          ),
                          if (canCollapse && selectedAt < 8)
                            TextButton(
                              style: TextButton.styleFrom(
                                  foregroundColor: c.actionText),
                              onPressed: () => setState(() =>
                                  _showAllCategories = !_showAllCategories),
                              child: Text(_showAllCategories
                                  ? context.l10n.bfsV2ShowLess
                                  : context.l10n.bfsV2ShowAll),
                            ),
                        ]),
                        const SizedBox(height: AppSpacing.s2),
                        AnimatedSize(
                          duration: AppMotion.moderate,
                          curve: AppMotion.easeInOut,
                          alignment: Alignment.topCenter,
                          child: GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          itemCount: visible.length,
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 4,
                            crossAxisSpacing: 8, mainAxisSpacing: 8,
                            mainAxisExtent: 100 * MediaQuery.textScalerOf(context).scale(1)),
                          itemBuilder: (context, index) {
                            final choice = visible[index];
                            final selected = _categoryId == choice.$1;
                            final avatar = choice.$3 == null
                                ? AppAvatar.icon(icon: AppLucideIcons.wallet, color: c.cta, size: 40)
                                : AppAvatar.category(category: choice.$3, size: 40);
                            return Semantics(selected: selected, button: true,
                              child: InkWell(
                                key: ValueKey('budget-category-${choice.$1}'),
                                borderRadius: BorderRadius.circular(AppRadius.button),
                                onTap: () {
                                  if (!selected) HapticFeedback.selectionClick();
                                  field.didChange(choice.$1);
                                  setState(() => _categoryId = choice.$1);
                                  _refreshSuggestedAmount();
                                },
                                // v2 selected tile: action.soft fill, 1.5pt
                                // action ring, action.text label (§3.0).
                                child: AnimatedContainer(
                                  duration: AppMotion.base,
                                  curve: AppMotion.springSmoothCurve,
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                                  decoration: BoxDecoration(
                                    color: selected ? c.ctaSoft : Colors.transparent,
                                    borderRadius: BorderRadius.circular(AppRadius.button),
                                    border: Border.all(color: selected ? c.cta : Colors.transparent, width: 1.5)),
                                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                    selected && !shouldReduceMotion(context)
                                        ? TweenAnimationBuilder<double>(
                                            tween: Tween(begin: .85, end: 1),
                                            duration: AppMotion.moderate,
                                            curve: AppMotion.springLivelyCurve,
                                            builder: (context, v, child) =>
                                                Transform.scale(scale: v, child: child),
                                            child: avatar)
                                        : avatar,
                                    const SizedBox(height: 6),
                                    Text(choice.$2, textAlign: TextAlign.center, maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTypography.caption(selected ? c.actionText : c.textSecondary)
                                          .copyWith(fontWeight: selected ? FontWeight.w600 : null, height: 1.25)),
                                  ]),
                                ),
                              ));
                          },
                        )),
                        if (field.hasError) Padding(padding: const EdgeInsets.only(top: 6),
                          child: Text(field.errorText!, style: AppTypography.caption(c.danger))),
                      ]);
                    },
                  ),
                  const SizedBox(height: AppSpacing.s5),
                  _AlertThresholdField(
                    value: _alertThreshold,
                    onChanged: (value) =>
                        setState(() => _alertThreshold = value),
                  ),
                  if (accounts.isNotEmpty) ...[
                    const SizedBox(height: AppSpacing.s3),
                    _FormField(
                      padding: EdgeInsets.zero,
                      child: GlassDropdownField<String>(
                      value: selectedAccount?.id,
                      style: AppTypography.bodyStrong(c.textMain),
                      decoration: InputDecoration(
                        labelText: context.l10n.commonAccountDefinite,
                        labelStyle: AppTypography.subhead(c.textMuted),
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                      ),
                      items: [
                        for (final acc in accounts)
                          DropdownMenuItem<String>(
                            value: acc.id,
                            child: Text(acc.name),
                          ),
                      ],
                      onChanged: (v) {
                        setState(() => _accountId = v);
                        _refreshSuggestedAmount();
                      },
                    ),
                    ),
                  ],
                  if (budget != null) ...[
                    const SizedBox(height: AppSpacing.s5),
                    SizedBox(
                      height: 52,
                      width: double.infinity,
                      child: OutlinedButton(
                        onPressed: () => _confirmDelete(context, budget.id),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: c.danger,
                          side: BorderSide(color: c.danger, width: 1.5),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: Text(
                          context.l10n.bdgDeleteBudget,
                          style: _alex(15, FontWeight.w700, 1.2, c.danger),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: AppSpacing.s4),
                ],
              ),
                  ),
                  // v2 QStickyDock: the one primary stays pinned under the
                  // scrolling form.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border(top: BorderSide(color: c.border)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                          AppSpacing.s3, AppSpacing.gutter, AppSpacing.s3),
                      child: AppPrimaryButton(
                        label: context.l10n.bfsSaveBudget,
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          _submit(budget);
                        },
                        loading: _saving,
                        height: AppSpacing.buttonHeight,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _submit(BudgetEntity? existing) async {
    if (_saving) return;
    // The amount field can be disposed while the long category list scrolls.
    // Validate its retained controller text even when FormState has no field.
    // §25 — an existing budget keeps its persisted currency; a new one is
    // seeded from the effective base. The amount is parsed EXACTLY from the
    // input string into that currency (never double -> Money.fromLegacyReal).
    final currency = existing?.currency ??
        (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final Money amountMoney;
    try {
      amountMoney = parseLocalizedMoney(_amountController.text, currency);
      if (amountMoney.minorUnits <= 0) {
        _formKey.currentState!.validate();
        AppToast.showError(context, context.l10n.gfEnterValidAmount);
        return;
      }
    } catch (_) {
      _formKey.currentState!.validate();
      AppToast.showError(context, context.l10n.gfEnterValidAmount);
      return;
    }
    if (!_formKey.currentState!.validate() || _categoryId == null) return;
    setState(() => _saving = true);
    try {
      final accounts =
          ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
      final selectedAccount = _selectedAccount(accounts);
      final navigator = Navigator.of(context);
      final budget = (existing ??
              BudgetEntity(
                id: IdGenerator.next(),
                categoryId: _categoryId!,
                currency: currency,
                amountMoney: amountMoney,
                lastNotifiedSpentMoney: Money(0, currency),
                period: _period,
                startDate: DateTime.now().toUtc(),
                isActive: true,
                lastNotifiedPeriodStart: DateTime.now().toUtc(),
              ))
          .copyWith(
        categoryId: _categoryId,
        amountMoney: amountMoney,
        period: _period,
        showOnHeader: false,
        accountId: selectedAccount?.id,
        alertThresholdPercent: _alertThreshold,
      );
      await ref.read(saveBudgetUseCaseProvider).call(budget);
      if (!mounted) return;
      refreshBudgets(ref);
      navigator.pop();
    } catch (error) {
      if (!mounted) return;
      final message = error is RepoException
          ? repoErrorMessage(context, error)
          : context.l10n.bfSaveFailed;
      AppToast.showError(context, message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete(BuildContext context, String budgetId) async {
    final c = context.colors;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(context.l10n.bdgDeleteTitle,
            style: _alex(18, FontWeight.w700, 1.2, c.textMain)),
        content: Text(context.l10n.bfsDeleteBody,
            style: _alex(14, FontWeight.w500, 1.4, c.textLight)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel,
                style: _alex(14, FontWeight.w700, 1.2, c.textLight)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: c.danger, foregroundColor: c.onDanger),
            child: Text(context.l10n.setDelete,
                style: _alex(14, FontWeight.w700, 1.2, c.onDanger)),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) {
      return;
    }
    final navigator = Navigator.of(context);
    await ref.read(deleteBudgetUseCaseProvider).call(budgetId);
    if (!mounted) {
      return;
    }
    refreshBudgets(ref);
    navigator.pop();
  }

  void _seedInitialState(BudgetEntity? budget) {
    if (_didSeedInitialState) {
      return;
    }
    _didSeedInitialState = true;
    if (budget == null) {
      _categoryId = BudgetEntity.allExpensesCategoryId;
      Future.microtask(_refreshSuggestedAmount);
      return;
    }
    // Seed from the CANONICAL money, not the display double: `_save()` parses
    // this text straight back into Money, so any rounding here silently
    // rewrites the stored amount on an untouched Save (1500.50 → 1501).
    _amountController.text = budget.amountMoney.toDecimalString();
    _period = budget.period;
    _categoryId = budget.categoryId;
    _accountId = budget.accountId;
    _alertThreshold =
        BudgetEntity.normalizeAlertThreshold(budget.alertThresholdPercent);
  }

  AccountEntity? _selectedAccount(List<AccountEntity> accounts) {
    if (accounts.isEmpty) return null;
    final selectedId = _accountId;
    if (selectedId != null) {
      for (final account in accounts) {
        if (account.id == selectedId) return account;
      }
    }
    return accounts.firstWhere(
      (account) => account.isDefault,
      orElse: () => accounts.first,
    );
  }

  Future<void> _refreshSuggestedAmount() async {
    final categoryId = _categoryId;
    if (categoryId == null || widget.budgetId != null) return;
    final accounts =
        ref.read(accountsProvider).valueOrNull ?? <AccountEntity>[];
    final selectedAccount = _selectedAccount(accounts);
    final accountId = selectedAccount?.id;
    final currency = selectedAccount?.currency ??
        (ref.read(baseCurrencyProvider).valueOrNull ?? 'SAR');
    final key =
        '$categoryId:${_period.name}:$accountId:${currency.toUpperCase()}';
    if (_suggestionKey == key && _suggestedAmount != null) return;
    setState(() {
      _suggestionKey = key;
      _suggestionLoading = true;
      _suggestedAmount = null;
    });
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day)
        .subtract(const Duration(days: 29));
    final txRepo = ref.read(transactionRepositoryProvider);
    final total = categoryId == BudgetEntity.allExpensesCategoryId
        ? await txRepo.expenseTotalBetween(
            from: from,
            to: now,
            currency: currency,
            accountId: accountId,
          )
        : await txRepo.categoryExpenseTotalBetween(
            categoryId: categoryId,
            from: from,
            to: now,
            currency: currency,
            accountId: accountId,
          );
    if (!mounted || _suggestionKey != key) return;
    final amount = switch (_period) {
      BudgetPeriod.daily => total.applyRate(
          rateNumerator: BigInt.one,
          rateDenominator: BigInt.from(30),
        ),
      BudgetPeriod.weekly => total.applyRate(
          rateNumerator: BigInt.from(7),
          rateDenominator: BigInt.from(30),
        ),
      BudgetPeriod.monthly => total,
      BudgetPeriod.yearly => total.applyRate(
          rateNumerator: BigInt.from(365),
          rateDenominator: BigInt.from(30),
        ),
    };
    final zero = Money.zero(currency);
    setState(() {
      _suggestionLoading = false;
      _suggestedAmount =
          amount.compareTo(zero) <= 0 ? null : _roundBudgetSuggestion(amount);
    });
  }

  Money _roundBudgetSuggestion(Money amount) {
    final stepMajor = amount.compareTo(Money.parse('50', amount.currency)) < 0
        ? 1
        : amount.compareTo(Money.parse('500', amount.currency)) < 0
            ? 10
            : 50;
    final scaleFactor =
        switch (amount.scale) { 0 => 1, 2 => 100, 3 => 1000, _ => 1 };
    final stepMinor = stepMajor * scaleFactor;
    final roundedMinor =
        ((amount.minorUnits + stepMinor - 1) ~/ stepMinor) * stepMinor;
    return Money(roundedMinor, amount.currency);
  }
}

/// v2 form field surface (§3.0 «17 / 18 / 28 form fields»): dark Inset
/// #0C0D11; light white + 1px strokeSoft + e1 on the canvas.
class _FormField extends StatelessWidget {
  const _FormField({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? c.surfaceMuted : c.surface,
        borderRadius: BorderRadius.circular(AppRadius.button),
        border: isDark ? null : Border.all(color: c.strokeSoft),
        boxShadow: AppShadows.group(Theme.of(context).brightness),
      ),
      child: child,
    );
  }
}

class _BudgetSuggestionCard extends StatelessWidget {
  const _BudgetSuggestionCard({
    required this.loading,
    required this.amount,
    required this.period,
    required this.onApply,
  });

  final bool loading;
  final Money? amount;
  final BudgetPeriod period;
  final VoidCallback? onApply;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = switch (period) {
      BudgetPeriod.daily => context.l10n.bfsPeriodDaily,
      BudgetPeriod.weekly => context.l10n.bfsPeriodWeekly,
      BudgetPeriod.monthly => context.l10n.bfsPeriodMonthly,
      BudgetPeriod.yearly => context.l10n.bfsPeriodYearly,
    };
    final value = amount?.toDecimalString();
    // v2 suggestion chip: sparkle on action.soft + a Plain «استخدمه».
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(
          AppSpacing.s3, AppSpacing.s1, AppSpacing.s1, AppSpacing.s1),
      constraints: const BoxConstraints(minHeight: 44),
      decoration: BoxDecoration(
        color: c.ctaSoft,
        borderRadius: BorderRadius.circular(AppRadius.button),
      ),
      child: Row(
        children: [
          SizedBox.square(
            dimension: 18,
            child: loading
                ? CircularProgressIndicator(
                    strokeWidth: 2, color: c.actionText)
                : Icon(AppLucideIcons.sparkles, color: c.actionText, size: 18),
          ),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(
              loading
                  ? context.l10n.bfsComputingSuggestion
                  : value == null
                      ? context.l10n.bfsSuggestAfterMoreTx(label)
                      : context.l10n.bfsSuggestion(label, value),
              style: AppTypography.subhead(c.textMain),
            ),
          ),
          if (value != null) ...[
            const SizedBox(width: AppSpacing.s1),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: c.actionText),
              onPressed: onApply,
              child: Text(context.l10n.bfsUseIt,
                  style: AppTypography.subhead(c.actionText)
                      .copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ],
      ),
    );
  }
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({
    required this.value,
    required this.onChanged,
  });

  final BudgetPeriod value;
  final ValueChanged<BudgetPeriod> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // v2 QSegmented, primary filter: thumb in the action fill #155DFC in
    // both themes — never brand navy (§3.0 «18 New budget»).
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.l10n.bfsBudgetPeriod,
          style: AppTypography.sectionTitle(c.textMain),
        ),
        const SizedBox(height: AppSpacing.s3),
        SegmentedControl<BudgetPeriod>(
          accent: true,
          value: value,
          onChanged: onChanged,
          options: [
            SegmentOption(
                value: BudgetPeriod.daily, label: context.l10n.bdgFilterDaily),
            SegmentOption(
                value: BudgetPeriod.weekly,
                label: context.l10n.txnCycleWeekly),
            SegmentOption(
                value: BudgetPeriod.monthly,
                label: context.l10n.txnCycleMonthly),
            SegmentOption(
                value: BudgetPeriod.yearly,
                label: context.l10n.txnCycleYearly),
          ],
        ),
      ],
    );
  }
}

/// WHEN this budget should warn you — a real persisted setting, not a
/// decoration on the form.
///
/// Per budget, because the answer is per budget: the grocery budget you want to
/// hear about at 50% is not the rent budget you only want to hear about when it
/// is nearly gone. 10–100 in 5% steps, so 30 / 50 / 80 are all reachable
/// without hunting, and the chosen value stays on screen while the thumb moves —
/// a slider whose value you can only read after letting go is a slider you
/// cannot aim.
class _AlertThresholdField extends StatelessWidget {
  const _AlertThresholdField({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final l10n = context.l10n;
    // The percentage in the reader's own digits — Arabic copy in this app uses
    // Eastern Arabic numerals, and a bare Latin "50%" inside an Arabic sentence
    // reads as untranslated.
    final display = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    ).format(value);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // v2: a Group — title + live value (action.text), the slider, then the
    // helper line.
    return AppCard(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.s4, AppSpacing.s4, AppSpacing.s4, AppSpacing.s3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.bfBudgetAlert,
                  style: AppTypography.cardTitle(c.textMain),
                ),
              ),
              // Stays visible while dragging: this is the value being chosen,
              // not a summary of a choice already made.
              Text(
                l10n.bfBudgetAlertValue(display),
                style: _alex(15, FontWeight.w700, 1.2, c.actionText,
                    tabular: true),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.s1),
          SliderTheme(
            // Themed rather than replaced: a custom-painted control would lose
            // the platform's own slider semantics and keyboard/VoiceOver
            // handling, which this one keeps.
            // v2 (§3.0): action fill #155DFC in both themes (never navy),
            // 6pt track on the theme's progress track, white 28pt thumb.
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: c.cta,
              inactiveTrackColor: isDark
                  ? Colors.white.withValues(alpha: .12)
                  : c.surfaceMuted,
              thumbColor: Colors.white,
              overlayColor: c.cta.withValues(alpha: 0.12),
              trackHeight: 6,
              activeTickMarkColor: Colors.transparent,
              inactiveTickMarkColor: Colors.transparent,
              thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 14, elevation: 3, pressedElevation: 5),
            ),
            child: Slider(
              value: value.toDouble(),
              min: BudgetEntity.minAlertThresholdPercent.toDouble(),
              max: BudgetEntity.maxAlertThresholdPercent.toDouble(),
              divisions: (BudgetEntity.maxAlertThresholdPercent -
                      BudgetEntity.minAlertThresholdPercent) ~/
                  BudgetEntity.alertThresholdStepPercent,
              // VoiceOver reads the purpose and the value, not "slider, 50".
              label: l10n.bfBudgetAlertValue(display),
              semanticFormatterCallback: (v) =>
                  '${l10n.bfBudgetAlert}: ${l10n.bfBudgetAlertValue(
                NumberFormat.decimalPattern(
                  Localizations.localeOf(context).toString(),
                ).format(v.round()),
              )}',
              onChanged: (v) {
                final next = BudgetEntity.normalizeAlertThreshold(v.round());
                // selectionClick at each 5% step, not on every pixel.
                if (next != value) HapticFeedback.selectionClick();
                onChanged(next);
              },
            ),
          ),
          Text(
            l10n.bfBudgetAlertHint,
            style: AppTypography.caption(c.textMuted),
          ),
        ],
      ),
    );
  }
}
