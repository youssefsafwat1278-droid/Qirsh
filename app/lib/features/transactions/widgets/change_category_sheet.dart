import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/widgets/navy_sheet_theme.dart';
import '../../../core/theme/widgets/segmented_control.dart';
import '../../../core/theme/widgets/app_toast.dart';
import '../../../core/theme/widgets/glass_dialog.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/usecases/correct_category_usecase.dart';
import '../../common/app_sheet_scaffold.dart';
import '../../common/app_category_chip.dart';
import '../../common/app_button.dart';
import '../../common/category_catalog.dart';
import '../../dashboard/dashboard_providers.dart';
import '../../settings/settings_providers.dart';
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

  /// What updating past transactions would do; null while computing.
  PastCategoryUpdatePlan? _plan;
  int _countRequest = 0;

  /// Separate, explicit opt-ins (both off by default).
  bool _includeUnknown = false;
  bool _includeChosen = false;
  bool _includeImported = false;

  PastUpdateOverrides get _overrides => PastUpdateOverrides(
      includeUnknown: _includeUnknown,
      includeChosenByYou: _includeChosen,
      includeImported: _includeImported);

  bool get _updatesPast =>
      _scope == CategoryCorrectionScope.allMerchantTransactions &&
      _alsoUpdatePast;

  /// The plan is shown BEFORE applying and follows the selected category and
  /// the opt-ins. Saving applies the same plan through the same code.
  Future<void> _refreshPastCount() async {
    final request = ++_countRequest;
    setState(() => _plan = null);
    final key = _selectedKey;
    if (!_updatesPast || key == null) return;
    try {
      final plan = await ref.read(correctCategoryUseCaseProvider).previewPastUpdate(
          transaction: widget.transaction,
          categoryKey: key,
          overrides: _overrides);
      if (mounted && request == _countRequest) {
        setState(() => _plan = plan);
      }
    } catch (_) {
      // The preview is advisory; saving still works and reports its own errors.
    }
  }

  /// Turning on an opt-in that overwrites protected rows takes its own
  /// confirmation, naming how many rows it would add.
  Future<bool> _confirmOptIn({
    required String title,
    required String body,
    required String yes,
    required Key yesKey,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(ctx.l10n.commonCancel)),
          TextButton(
              key: yesKey,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(yes)),
        ],
      ),
    );
    return ok == true && mounted;
  }

  Future<void> _setIncludeChosen(bool v) async {
    if (v) {
      final n = _plan?.excludedCount(PastUpdateExclusion.chosenByYou) ?? 0;
      final l = context.l10n;
      if (!await _confirmOptIn(
          title: l.ccIncludeChosenConfirmTitle,
          body: l.ccIncludeChosenConfirmBody(n),
          yes: l.ccIncludeChosenConfirmYes,
          yesKey: const ValueKey('cc-include-chosen-confirm'))) {
        return;
      }
    }
    setState(() => _includeChosen = v);
    _refreshPastCount();
  }

  Future<void> _setIncludeImported(bool v) async {
    if (v) {
      final n = _plan?.excludedCount(PastUpdateExclusion.imported) ?? 0;
      final l = context.l10n;
      if (!await _confirmOptIn(
          title: l.ccIncludeImportedConfirmTitle,
          body: l.ccIncludeImportedConfirmBody(n),
          yes: l.ccIncludeImportedConfirmYes,
          yesKey: const ValueKey('cc-include-imported-confirm'))) {
        return;
      }
    }
    setState(() => _includeImported = v);
    _refreshPastCount();
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
        overrides: _overrides,
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
                    : ref.watch(sharedLearningActiveProvider).valueOrNull == true
                        ? '${context.l10n.ccRememberHint}\n'
                            '${context.l10n.ccSharedLearningHint}'
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
                      ? _plan == null
                          ? context.l10n.ccPastManualKept
                          : context.l10n.ccPastCount(_plan!.eligible.length)
                      : null,
                  value: _alsoUpdatePast,
                  onChanged: (v) {
                    setState(() {
                      _alsoUpdatePast = v;
                      if (!v) {
                        _includeUnknown = _includeChosen = false;
                        _includeImported = false;
                      }
                    });
                    _refreshPastCount();
                  },
                ),
              ),
              if (_alsoUpdatePast && _plan != null) ..._planDetails(context),
            ],
          ],
          const SizedBox(height: AppSpacing.s2),
        ],
      ),
    );
  }

  /// Every exclusion with its reason, then the separate opt-ins.
  List<Widget> _planDetails(BuildContext context) {
    final c = context.colors;
    final plan = _plan!;
    final l = context.l10n;
    final unknown = plan.excludedCount(PastUpdateExclusion.unknownOrigin);
    final chosen = plan.excludedCount(PastUpdateExclusion.chosenByYou);
    final imported = plan.excludedCount(PastUpdateExclusion.imported);
    final lines = <String>[
      if (chosen > 0) l.ccPastExclChosen(chosen),
      if (unknown > 0) l.ccPastExclUnknown(unknown),
      if (plan.excludedCount(PastUpdateExclusion.ignored) > 0)
        l.ccPastExclIgnored(plan.excludedCount(PastUpdateExclusion.ignored)),
      if (imported > 0) l.ccPastExclImported(imported),
      if (plan.excludedCount(PastUpdateExclusion.manual) > 0)
        l.ccPastExclManual(plan.excludedCount(PastUpdateExclusion.manual)),
      if (plan.excludedCount(PastUpdateExclusion.typeLocked) > 0)
        l.ccPastExclTypeLocked(
            plan.excludedCount(PastUpdateExclusion.typeLocked)),
    ];
    return [
      if (lines.isNotEmpty) ...[
        const SizedBox(height: AppSpacing.s3),
        Padding(
          padding: const EdgeInsetsDirectional.symmetric(horizontal: 4),
          child: Text(
            [l.ccPastExcludedTitle, ...lines.map((e) => '• $e')].join('\n'),
            key: const ValueKey('cc-past-excluded'),
            style: AppTypography.caption(c.textMuted),
          ),
        ),
      ],
      if (unknown > 0 || _includeUnknown) ...[
        const SizedBox(height: AppSpacing.s3),
        Material(
          color: c.surfaceElevated,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: SettingsV2SwitchRow(
            key: const ValueKey('cc-include-unknown'),
            title: l.ccIncludeUnknown,
            value: _includeUnknown,
            onChanged: (v) {
              setState(() => _includeUnknown = v);
              _refreshPastCount();
            },
          ),
        ),
      ],
      if (chosen > 0 || _includeChosen) ...[
        const SizedBox(height: AppSpacing.s3),
        Material(
          color: c.surfaceElevated,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: SettingsV2SwitchRow(
            key: const ValueKey('cc-include-chosen'),
            title: l.ccIncludeChosen,
            value: _includeChosen,
            onChanged: (v) => _setIncludeChosen(v),
          ),
        ),
      ],
      if (imported > 0 || _includeImported) ...[
        const SizedBox(height: AppSpacing.s3),
        Material(
          color: c.surfaceElevated,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(AppRadius.card),
          child: SettingsV2SwitchRow(
            key: const ValueKey('cc-include-imported'),
            title: l.ccIncludeImported,
            value: _includeImported,
            onChanged: (v) => _setIncludeImported(v),
          ),
        ),
      ],
    ];
  }
}
