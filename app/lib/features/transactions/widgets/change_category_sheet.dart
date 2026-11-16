import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../core/theme/widgets/segmented_control.dart';
import '../../../core/theme/widgets/app_toast.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/usecases/correct_category_usecase.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/app_category_chip.dart';
import '../../common/app_button.dart';
import '../../common/category_catalog.dart';
import '../../dashboard/dashboard_providers.dart';
import '../../settings/widgets/settings_v2.dart';
import '../transactions_providers.dart';
import '../../../core/utils/l10n_ext.dart';

Future<void> showChangeCategorySheet(
  BuildContext context,
  TransactionEntity transaction,
  CategoryCatalog catalog,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(
        _ChangeCategorySheet(transaction: transaction, catalog: catalog)),
  );
}

class _ChangeCategorySheet extends ConsumerStatefulWidget {
  const _ChangeCategorySheet(
      {required this.transaction, required this.catalog});

  final TransactionEntity transaction;
  final CategoryCatalog catalog;

  @override
  ConsumerState<_ChangeCategorySheet> createState() => _State();
}

class _State extends ConsumerState<_ChangeCategorySheet> {
  String? _selectedKey;
  CategoryCorrectionScope _scope = CategoryCorrectionScope.thisTransactionOnly;
  bool _saving = false;

  /// "Also update past transactions" — only offered with "remember".
  bool _alsoUpdatePast = false;

  /// How many past transactions that would change; null while counting.
  int? _pastCount;
  int _countRequest = 0;

  bool get _updatesPast =>
      _scope == CategoryCorrectionScope.allMerchantTransactions &&
      _alsoUpdatePast;

  /// The count is shown BEFORE applying, and follows the selected category.
  Future<void> _refreshPastCount() async {
    final request = ++_countRequest;
    setState(() => _pastCount = null);
    final key = _selectedKey;
    if (!_updatesPast || key == null) return;
    try {
      final count = await ref
          .read(correctCategoryUseCaseProvider)
          .countPastToUpdate(transaction: widget.transaction, categoryKey: key);
      if (mounted && request == _countRequest) {
        setState(() => _pastCount = count);
      }
    } catch (_) {
      // The count is advisory; saving still works and reports its own errors.
    }
  }

  @override
  void initState() {
    super.initState();
    _selectedKey = widget.catalog.byId(widget.transaction.categoryId)?.key;
  }

  Future<void> _save() async {
    if (_selectedKey == null || _saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(correctCategoryUseCaseProvider)(
        transactionId: widget.transaction.id,
        categoryKey: _selectedKey!,
        scope: _scope,
        alsoUpdatePast: _updatesPast,
      );
      refreshTransactions(ref);
      ref.invalidate(dashboardDataProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        AppToast.showError(context, context.l10n.ctsCategoryUpdateFailed);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasMerchant = widget.transaction.rawMerchant != null;

    return AppSheetScaffold(
      title: context.l10n.ccTitle,
      scrollable: true,
      // v2 QStickyDock: the one primary, full width, pinned under the content.
      bottomAction: AppPrimaryButton(
        label: context.l10n.ccSave,
        onTap: _saving ? null : _save,
        loading: _saving,
      ),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.s2,
            runSpacing: AppSpacing.s2,
            children: [
              for (final cat in widget.catalog.all.where(
                (it) =>
                    it.key != 'income' &&
                    it.key != BudgetEntity.allExpensesCategoryKey,
              ))
                AppCategoryChip(
                  label: cat.name,
                  icon: cat.icon,
                  color: _selectedKey == cat.key ? c.primary : c.textLight,
                  selected: _selectedKey == cat.key,
                  onTap: () {
                    setState(() => _selectedKey = cat.key);
                    if (_updatesPast) _refreshPastCount();
                  },
                ),
            ],
          ),
          if (hasMerchant) ...[
            const SizedBox(height: AppSpacing.s6),
            Text(context.l10n.ccScope,
                style: AppTypography.caption(c.textMuted)),
            const SizedBox(height: AppSpacing.s2),
            SegmentedControl<CategoryCorrectionScope>(
              value: _scope,
              onChanged: (v) {
                if (v == _scope) return;
                setState(() {
                  _scope = v;
                  if (v == CategoryCorrectionScope.thisTransactionOnly) {
                    _alsoUpdatePast = false;
                  }
                });
              },
              options: [
                SegmentOption(
                    value: CategoryCorrectionScope.thisTransactionOnly,
                    label: context.l10n.ccScopeThis),
                SegmentOption(
                    value: CategoryCorrectionScope.allMerchantTransactions,
                    label: context.l10n.ccScopeMerchant),
              ],
            ),
            const SizedBox(height: AppSpacing.s2),
            Padding(
              padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
              child: Text(
                _scope == CategoryCorrectionScope.thisTransactionOnly
                    ? context.l10n.ccThisOnlyHint
                    : context.l10n.ccRememberHint,
                style: AppTypography.caption(c.textMuted),
              ),
            ),
            if (_scope == CategoryCorrectionScope.allMerchantTransactions) ...[
              const SizedBox(height: AppSpacing.s4),
              // The v2 switch row on a raised fill (the switch's off track is
              // the segmented well's colour); a floating card's drop shadow
              // would be clipped by the sheet's scroll view.
              Material(
                color: c.surfaceElevated,
                clipBehavior: Clip.antiAlias,
                borderRadius: BorderRadius.circular(AppRadius.card),
                child: SettingsV2SwitchRow(
                  key: const ValueKey('cc-past-count'),
                  title: context.l10n.ccAlsoUpdatePast,
                  subtitle: _alsoUpdatePast
                      ? _pastCount == null
                          ? context.l10n.ccPastManualKept
                          : '${context.l10n.ccPastCount(_pastCount!)} '
                              '${context.l10n.ccPastManualKept}'
                      : null,
                  value: _alsoUpdatePast,
                  onChanged: (v) {
                    setState(() => _alsoUpdatePast = v);
                    _refreshPastCount();
                  },
                ),
              ),
            ],
          ],
          const SizedBox(height: AppSpacing.s2),
        ],
      ),
    );
  }
}
