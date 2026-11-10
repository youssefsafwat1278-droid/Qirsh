import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/id_generator.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/usecases/account_deletion.dart';
import 'account_deletion_sheet.dart';
import '../dashboard/dashboard_providers.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

String accountTypeLabel(BuildContext context, AccountType type) =>
    switch (type) {
      AccountType.cash => context.l10n.accTypeCash,
      AccountType.bank => context.l10n.accTypeBank,
      AccountType.wallet => context.l10n.accTypeWallet,
      // نعيد استخدام قيمة enum card لتعني «بطاقة ائتمانية» في الواجهة فقط.
      AccountType.card => context.l10n.accTypeCreditCard,
    };

IconData accountTypeIcon(AccountType type) => switch (type) {
      AccountType.cash => AppLucideIcons.banknote,
      AccountType.bank => AppLucideIcons.landmark,
      AccountType.wallet => AppLucideIcons.wallet,
      AccountType.card => AppLucideIcons.creditCard,
    };

/// مزوّدو المحافظ الإلكترونية الشائعون (key → label).
///
/// A function rather than a `const` map: the labels come from the ARB now, so
/// the language has to be resolved when the form builds, not at class-load.
Map<String, String> _walletProviders(BuildContext context) => {
      'vodafone_cash': context.l10n.afVodafoneCash,
      'orange_cash': context.l10n.afOrangeCash,
      'etisalat_cash': context.l10n.afEtisalatCash,
      'we_pay': context.l10n.afWePay,
    };

Future<void> showAccountForm(
  BuildContext context,
  WidgetRef ref, {
  AccountEntity? account,
}) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => navySheetTheme(Directionality(
      textDirection: Directionality.of(context),
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: AccountFormPanel(account: account),
      ),
    )),
  );
}

/// The Create/Edit Account form body, shared by [showAccountForm] (sheet) and
/// the onboarding Account Setup step so there is ONE create path and ONE
/// validation implementation.
///
/// [initialCurrency] seeds a NEW account's currency (ignored when editing).
/// [onSaved] runs after a successful save; it defaults to popping the sheet.
/// The creation id is generated once per State, so a failed save that is
/// retried re-sends the same id (no duplicate); give the widget a new Key to
/// start a fresh account.
class AccountFormPanel extends ConsumerStatefulWidget {
  const AccountFormPanel({
    super.key,
    this.account,
    this.initialCurrency,
    this.onSaved,
    this.showTitle = true,
  });

  final AccountEntity? account;
  final String? initialCurrency;
  final VoidCallback? onSaved;
  final bool showTitle;

  @override
  ConsumerState<AccountFormPanel> createState() => _AccountFormState();
}

class _AccountFormState extends ConsumerState<AccountFormPanel> {
  late final TextEditingController _name;
  late final TextEditingController _startingBalance;
  late final TextEditingController _bankAccountNumber;
  late final TextEditingController _creditLimit;
  late final TextEditingController _availableCredit;
  late final TextEditingController _paymentDueDay;
  late AccountType _type;
  late String _currency;
  late bool _isDefault;
  late bool _excludeFromTotals;
  late String? _walletProvider;
  late final String _creationId;
  bool _advancedOpen = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _startingBalance = TextEditingController(
      text: a?.initialBalanceMoney?.toDecimalString() ?? '',
    );
    _bankAccountNumber =
        TextEditingController(text: a?.bankAccountNumber ?? '');
    _creditLimit = TextEditingController(
      text: a?.creditLimitMoney?.toDecimalString() ?? '',
    );
    _availableCredit = TextEditingController(
      text: a?.availableCreditMoney?.toDecimalString() ?? '',
    );
    _paymentDueDay =
        TextEditingController(text: a?.paymentDueDay?.toString() ?? '');
    _type = a?.type ?? AccountType.bank;
    _currency = a?.currency ?? widget.initialCurrency ?? 'SAR';
    _isDefault = a?.isDefault ?? false;
    _excludeFromTotals = a?.excludeFromTotals ?? false;
    _walletProvider = a?.walletProvider;
    _creationId = a?.id ?? IdGenerator.next();
  }

  @override
  void dispose() {
    _name.dispose();
    _startingBalance.dispose();
    _bankAccountNumber.dispose();
    _creditLimit.dispose();
    _availableCredit.dispose();
    _paymentDueDay.dispose();
    super.dispose();
  }

  /// Parse a localized money field to canonical [Money] (exact — no double).
  /// Throws on invalid/ambiguous/over-precision input; the caller validates.
  Money? _parseMoney(TextEditingController c, String currency) {
    final t = c.text.trim();
    if (t.isEmpty) return null;
    return parseLocalizedMoney(t, currency);
  }

  bool _hasNonZeroBalance(AccountEntity? account) {
    if (account == null) return false;
    return account.initialBalanceMoney?.isZero == false ||
        account.currentBalanceMoney?.isZero == false;
  }

  bool get _hasPersistedNonZeroBalance => _hasNonZeroBalance(widget.account);

  void _showCurrencyChangeBlocked() {
    AppToast.showError(context, context.l10n.afCurrencyLockedInUse);
  }

  Future<bool> _canChangePersistedCurrency(String submittedCurrency) async {
    final account = widget.account;
    if (account == null) return true;

    try {
      // Re-read at submit time: balances may have changed while the sheet was
      // open, and the defensive guard must compare against persisted state.
      final persisted =
          await ref.read(accountRepositoryProvider).getById(account.id);
      if (persisted == null) {
        throw StateError('Account disappeared during currency validation.');
      }
      if (submittedCurrency == persisted.currency) return true;
      if (_hasNonZeroBalance(persisted)) {
        _showCurrencyChangeBlocked();
        return false;
      }
      final hasTransactions = await ref.refresh(
        accountHasTransactionsProvider(account.id).future,
      );
      if (hasTransactions) {
        if (mounted) _showCurrencyChangeBlocked();
        return false;
      }
      return true;
    } catch (_) {
      if (mounted) {
        AppToast.showError(
          context,
          context.l10n.afUsageCheckFailed,
        );
      }
      return false;
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      AppToast.showError(context, context.l10n.afEnterAccountName);
      return;
    }
    final dueDayText = _paymentDueDay.text.trim();
    int? dueDay;
    if (_type == AccountType.card && dueDayText.isNotEmpty) {
      try {
        dueDay = int.parse(normalizeLocalizedDecimal(dueDayText));
      } on Exception {
        AppToast.showError(context, context.l10n.afPaymentDayRange);
        return;
      }
      if (dueDay < 1 || dueDay > 31) {
        AppToast.showError(context, context.l10n.afPaymentDayRange);
        return;
      }
    }
    final submittedCurrency = _currency;
    // Parse the money inputs exactly (localized → canonical Money). Ambiguous /
    // over-precision input now fails validation instead of changing magnitude.
    final Money? startingBalanceMoney;
    final Money? creditLimitMoney;
    final Money? availableCreditMoney;
    try {
      // F-021 (NULL↔0 normalization): a card account has no starting-balance
      // field, so saving one must PRESERVE the persisted value, not overwrite
      // it with NULL — the destructive rewrite that made local NULL fight a
      // server 0.00 on every sync compare. Same currency-change treatment as
      // current_balance below: a zero is recreated in the new currency, never
      // carried across.
      // F-021 (NULL↔0 normalization): a card account has no starting-balance
      // field, so saving one must PRESERVE the persisted value, not overwrite
      // it with NULL — the destructive rewrite that made local NULL fight a
      // server 0.00 on every sync compare. Same currency-change treatment as
      // current_balance below: a zero is recreated in the new currency, never
      // carried across.
      startingBalanceMoney = _type == AccountType.card
          ? (widget.account == null ||
                  submittedCurrency != widget.account!.currency
              ? (widget.account?.initialBalanceMoney == null
                  ? null
                  : Money.zero(submittedCurrency))
              : widget.account!.initialBalanceMoney)
          : _parseMoney(_startingBalance, submittedCurrency);
      creditLimitMoney = _type == AccountType.card
          ? _parseMoney(_creditLimit, submittedCurrency)
          : null;
      availableCreditMoney = _type == AccountType.card
          ? _parseMoney(_availableCredit, submittedCurrency)
          : null;
    } on Exception {
      AppToast.showError(context, context.l10n.bfInvalidAmount);
      return;
    }

    setState(() => _busy = true);
    if (!await _canChangePersistedCurrency(submittedCurrency)) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    final repo = ref.read(accountRepositoryProvider);
    final now = DateTime.now().toUtc();
    final currencyChanged =
        widget.account != null && submittedCurrency != widget.account!.currency;

    AccountEntity build(String id, DateTime created) => AccountEntity(
          id: id,
          name: name,
          currency: submittedCurrency,
          type: _type,
          isDefault: _isDefault,
          sortOrder: widget.account?.sortOrder ?? 0,
          createdAt: created,
          updatedAt: now,
          initialBalanceMoney: startingBalanceMoney,
          // Current balance is running/derived state and is not editable here.
          // Preserve it verbatim only while its currency authority is unchanged.
          // An empty account may change currency, but its optional zero is then
          // recreated in the new currency rather than carrying a Money across.
          currentBalanceMoney: currencyChanged
              ? (widget.account?.currentBalanceMoney == null
                  ? null
                  : Money.zero(submittedCurrency))
              : widget.account?.currentBalanceMoney,
          bankAccountNumber: _type == AccountType.bank
              ? (_bankAccountNumber.text.trim().isEmpty
                  ? null
                  : _bankAccountNumber.text.trim())
              : null,
          creditLimitMoney: creditLimitMoney,
          availableCreditMoney: availableCreditMoney,
          paymentDueDay: _type == AccountType.card ? dueDay : null,
          walletProvider: _type == AccountType.wallet ? _walletProvider : null,
          excludeFromTotals: _excludeFromTotals,
          metadata: widget.account?.metadata,
        );

    var saved = false;
    try {
      if (widget.account == null) {
        await repo.create(build(_creationId, now));
      } else {
        await repo.update(build(widget.account!.id, widget.account!.createdAt));
        if (_isDefault && !widget.account!.isDefault) {
          await repo.setDefault(widget.account!.id);
        }
      }
      saved = true;
    } on RepoException catch (e) {
      if (!mounted) return;
      AppToast.showError(context, repoErrorMessage(context, e));
    } catch (_) {
      if (!mounted) return;
      AppToast.showError(context, context.l10n.afSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!saved) return;
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
    if (!mounted) return;
    final onSaved = widget.onSaved;
    if (onSaved != null) {
      onSaved();
    } else {
      Navigator.of(context).pop();
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    // A-7: never start the delete flow for the only remaining account.
    if ((await ref.read(accountRepositoryProvider).getAll()).length <= 1) {
      if (mounted) {
        AppToast.showError(context, context.l10n.afCannotDeleteLast);
      }
      return;
    }
    // MALI-016: dependency-aware deletion. Show the impact first; force an
    // explicit reassign-or-archive decision for goals/subscriptions before
    // anything is touched, then execute atomically.
    final service = ref.read(financialAccountDeletionServiceProvider);
    final accountId = widget.account!.id;
    if (!mounted) return;
    setState(() => _busy = true);

    AccountDeletionRequest? request;
    try {
      final impact = await service.plan(accountId);
      if (!mounted) return;
      if (impact.requiresDecision) {
        request = await AccountDeletionSheet.show(context, impact);
      } else {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => GlassAlertDialog(
            title: Text(context.l10n.afDeleteAccount),
            content: Text(_impactSummary(context, impact)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(context.l10n.commonCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(backgroundColor: ctx.colors.danger,
                    foregroundColor: ctx.colors.onDanger),
                child: Text(context.l10n.setDelete),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          request = AccountDeletionRequest(accountId: accountId);
        }
      }
    } catch (_) {
      if (mounted) {
        AppToast.showError(context, context.l10n.afDeletePrepFailed);
      }
    }

    if (request == null) {
      if (mounted) setState(() => _busy = false);
      return; // cancelled, or plan failed
    }

    var deleted = false;
    try {
      final result = await service.execute(request);
      deleted = true;
      if (mounted) {
        AppToast.show(context, _resultSummary(context, result));
      }
    } on StateError {
      if (mounted) {
        AppToast.showError(context, context.l10n.afCannotDeleteLast);
      }
    } on AccountDeletionBlocked {
      if (mounted) {
        AppToast.showError(context, context.l10n.afNeedsExplicitDecision);
      }
    } on RepoException catch (e) {
      if (mounted) {
        AppToast.showError(
          context,
          e is ValidationRepoException && e.message.contains('last_account')
              ? context.l10n.afCannotDeleteLast
              : repoErrorMessage(context, e),
        );
      }
    } catch (_) {
      if (mounted) {
        AppToast.showError(context, context.l10n.afDeleteFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!deleted) return;
    ref.invalidate(accountsProvider);
    ref.read(dashboardAccountProvider.notifier).state = null;
    ref.invalidate(dashboardDataProvider);
    if (mounted) Navigator.of(context).pop();
  }

  String _impactSummary(BuildContext context, AccountDeletionImpact i) {
    final l10n = context.l10n;
    final parts = <String>[l10n.accWillDetachTx(i.transactionsToDetach)];
    if (i.cardsToArchive > 0) {
      parts.add(l10n.accWillArchiveCards(i.cardsToArchive));
    }
    if (i.budgetsToArchive > 0) {
      parts.add(l10n.accWillArchiveBudgets(i.budgetsToArchive));
    }
    return '${parts.join(l10n.setListSeparator)}.';
  }

  String _resultSummary(BuildContext context, AccountDeletionResult r) {
    final l10n = context.l10n;
    final parts = <String>[l10n.accDetachedTx(r.transactionsDetached)];
    if (r.cardsArchived > 0) parts.add(l10n.accArchivedCards(r.cardsArchived));
    if (r.goalsReassigned > 0) {
      parts.add(l10n.accReassignedGoals(r.goalsReassigned));
    }
    if (r.goalsArchived > 0) parts.add(l10n.accArchivedGoals(r.goalsArchived));
    if (r.subscriptionsReassigned > 0) {
      parts.add(l10n.accReassignedSubs(r.subscriptionsReassigned));
    }
    if (r.subscriptionsArchived > 0) {
      parts.add(l10n.accArchivedSubs(r.subscriptionsArchived));
    }
    return l10n.accDeletedSummary(parts.join(l10n.setListSeparator));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final editing = widget.account != null;
    final transactionUsage = editing && !_hasPersistedNonZeroBalance
        ? ref.watch(accountHasTransactionsProvider(widget.account!.id))
        : const AsyncValue.data(false);
    // Fail closed while the transaction check is loading or if it errors. Only
    // an authoritative `false`, combined with zero persisted balances, unlocks.
    final currencyLocked = editing &&
        (_hasPersistedNonZeroBalance || transactionUsage.valueOrNull != false);
    final currencyCodes = ref
            .watch(activeCurrenciesProvider)
            .valueOrNull
            ?.map((currency) => currency.code)
            .toList(growable: false) ??
        const ['SAR', 'AED', 'EGP', 'USD', 'EUR', 'GBP'];
    final currencies = {_currency, ...currencyCodes}.toList(growable: false);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
      child: SingleChildScrollView(
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.showTitle) ...[
              Text(
                  editing
                      ? context.l10n.afEditAccount
                      : context.l10n.afNewAccount,
                  style: AppTypography.title2(c.textMain)),
              const SizedBox(height: AppSpacing.s4),
            ],
            _field(
              key: const ValueKey('account-name-field'),
              controller: _name,
              label: context.l10n.afAccountName,
              hint: context.l10n.afAccountNameHint,
            ),
            const SizedBox(height: AppSpacing.s3),
            Text(context.l10n.txdType,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final type in AccountType.values)
                  ChoiceChip(
                    label: Text(accountTypeLabel(context, type)),
                    avatar: Icon(accountTypeIcon(type), size: 16,
                      color: _type == type ? c.onCta : c.textSecondary),
                    selected: _type == type,
                    onSelected:
                        _busy ? null : (_) => setState(() => _type = type),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(context.l10n.dtxCurrency,
                style: AppTypography.caption(c.textLight)),
            const SizedBox(height: AppSpacing.s2),
            GlassDropdownField<String>(
              key: const ValueKey('account-currency-field'),
              value: _currency,
              isExpanded: true,
              decoration: InputDecoration(
                helperText:
                    currencyLocked ? context.l10n.afCurrencyLockedShort : null,
                helperMaxLines: 3,
                helperStyle: TextStyle(color: c.textMuted),
              ),
              items: [
                for (final code in currencies)
                  DropdownMenuItem(
                    value: code,
                    child: Text(Currency.codeWithLabel(context, code)),
                  ),
              ],
              onChanged: _busy || currencyLocked
                  ? null
                  : (v) {
                      if (v != null) setState(() => _currency = v);
                    },
            ),
            // ── حقول حسب النوع ──
            ..._typeFields(),
            const SizedBox(height: AppSpacing.s3),
            _AdvancedSection(
              open: _advancedOpen,
              onToggle: () => setState(() => _advancedOpen = !_advancedOpen),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _isDefault,
                  onChanged: _busy || widget.account?.isDefault == true
                      ? null
                      : (v) => setState(() => _isDefault = v),
                  title: Text(context.l10n.dtxDefaultAccount,
                      style: AppTypography.body(c.textMain)),
                  subtitle: Text(context.l10n.afDefaultAccountHint,
                      style: AppTypography.caption(c.textLight)),
                  activeColor: c.primary,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _excludeFromTotals,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _excludeFromTotals = v),
                  title: Text(context.l10n.afExcludeFromTotals,
                      style: AppTypography.body(c.textMain)),
                  activeColor: c.primary,
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton(
              key: const ValueKey('account-save-button'),
              onPressed: _busy ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              child: _busy
                  ? SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: c.onInk))
                  : Text(editing ? context.l10n.txdSave : context.l10n.txnAdd,
                      style: AppTypography.bodyStrong(c.onInk)),
            ),
            if (editing && !widget.account!.isDefault) ...[
              const SizedBox(height: AppSpacing.s2),
              TextButton.icon(
                onPressed: _busy ? null : _delete,
                icon: Icon(AppLucideIcons.trash2, color: c.danger),
                label: Text(context.l10n.afDeleteAccount,
                    style: AppTypography.body(c.danger)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  List<Widget> _typeFields() {
    final c = context.colors;
    switch (_type) {
      case AccountType.bank:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: context.l10n.afOpeningBalance,
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _bankAccountNumber,
              label: context.l10n.afBankAccountNumber,
              hint: context.l10n.afHelpsMatching,
              number: true),
        ];
      case AccountType.card:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _creditLimit,
              label: context.l10n.afCreditLimit,
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _availableCredit,
              label: context.l10n.afAvailableBalance,
              number: true),
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _paymentDueDay,
              label: context.l10n.afPaymentDay,
              number: true),
        ];
      case AccountType.wallet:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: context.l10n.afOpeningBalance,
              number: true),
          const SizedBox(height: AppSpacing.s3),
          Text(context.l10n.afProvider,
              style: AppTypography.caption(c.textLight)),
          const SizedBox(height: AppSpacing.s2),
          GlassDropdownField<String?>(
            value: _walletProviders(context).containsKey(_walletProvider)
                ? _walletProvider
                : null,
            isExpanded: true,
            items: [
              DropdownMenuItem<String?>(
                  value: null, child: Text(context.l10n.afUnspecified)),
              for (final e in _walletProviders(context).entries)
                DropdownMenuItem(value: e.key, child: Text(e.value)),
            ],
            onChanged:
                _busy ? null : (v) => setState(() => _walletProvider = v),
          ),
        ];
      case AccountType.cash:
        return [
          const SizedBox(height: AppSpacing.s3),
          _field(
              controller: _startingBalance,
              label: context.l10n.afOpeningBalance,
              number: true),
        ];
    }
  }

  Widget _field({
    Key? key,
    required TextEditingController controller,
    required String label,
    String? hint,
    bool number = false,
  }) {
    final c = context.colors;
    return TextField(
      key: key,
      controller: controller,
      enabled: !_busy,
      keyboardType: number
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      style: AppTypography.body(c.textMain),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: c.surface2.withValues(alpha: 0.45),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: c.border),
        ),
      ),
    );
  }
}

class _AdvancedSection extends StatelessWidget {
  const _AdvancedSection({
    required this.open,
    required this.onToggle,
    required this.children,
  });

  final bool open;
  final VoidCallback onToggle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.s2),
            child: Row(
              children: [
                Icon(
                    open
                        ? AppLucideIcons.chevronUp
                        : AppLucideIcons.chevronDown,
                    color: c.textLight,
                    size: 20),
                const SizedBox(width: 6),
                Text(context.l10n.afAdvancedOptions,
                    style: AppTypography.body(c.textMain)),
              ],
            ),
          ),
        ),
        if (open) ...children,
      ],
    );
  }
}
