import 'dart:ui';

import 'package:flutter/material.dart';
import '../../core/utils/formatters.dart';
import '../../core/utils/l10n_ext.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/async_reload_safe.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/large_text.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/theme/widgets/segmented_control.dart';
import '../../core/utils/currency.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/money_input.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/budget_entity.dart';
import '../achievements/achievements_providers.dart';
import '../budgets/budgets_providers.dart';
import '../cards/mini_card_art.dart';
import '../capture/services/captured_message_processor.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/app_error_state.dart';
import '../common/category_catalog.dart';
import '../common/transaction_direction.dart';
import '../dashboard/dashboard_providers.dart';
import '../subscriptions/subscriptions_providers.dart';
import 'transactions_providers.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../common/repo_error_messages.dart';
import '../capture/services/local_notification_service.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_pickers.dart';
import '../../core/theme/widgets/glass_dropdown_field.dart';

/// What a new manual entry starts from when the user records a captured
/// bank message by hand (Gemini-first phase 2: «سجّلها على أي حال», an amount
/// to check). Nothing is saved until the user taps save.
class ManualEntryPrefill {
  const ManualEntryPrefill({
    this.amountText,
    this.currency,
    this.merchant,
    this.isDebit,
    this.occurredAt,
    this.messageText,
  });

  final String? amountText;
  final String? currency;
  final String? merchant;
  final bool? isDebit;
  final DateTime? occurredAt;

  /// The bank message, already masked, shown above the form.
  final String? messageText;
}

class ManualTransactionSheet extends ConsumerStatefulWidget {
  const ManualTransactionSheet({
    super.key,
    this.transaction,
    this.initialCardLast4,
    this.prefill,
  });

  final TransactionEntity? transaction;

  /// لما تُفتح من صفحة بطاقة معيّنة: العملية الجديدة تُنسب لهذه البطاقة.
  final String? initialCardLast4;

  /// A new entry recorded from a captured bank message (never an edit).
  final ManualEntryPrefill? prefill;

  /// Completes with true only when a transaction was saved from the sheet.
  static Future<bool> show(
    BuildContext context, {
    TransactionEntity? transaction,
    String? cardLast4,
    ManualEntryPrefill? prefill,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(ManualTransactionSheet(
        transaction: transaction,
        initialCardLast4: cardLast4,
        prefill: prefill,
      )),
    );
    return saved ?? false;
  }

  @override
  ConsumerState<ManualTransactionSheet> createState() =>
      _ManualTransactionSheetState();
}

class _ManualTransactionSheetState
    extends ConsumerState<ManualTransactionSheet> {
  final _amount = TextEditingController();
  final _merchant = TextEditingController();
  final _note = TextEditingController();
  final _currency = TextEditingController(text: 'SAR');

  TransactionTypeEntity _type = TransactionTypeEntity.payment;
  String? _categoryKey;
  String? _categoryId;
  String? _accountId;
  DateTime _occurredAt = DateTime.now();
  bool _busy = false;

  /// Transfer To: an own account id, [_outside], or null for the default.
  static const _outside = '__outside__';
  String? _toAccountId;

  /// The other leg when editing one side of a transfer between own accounts.
  TransactionEntity? _sibling;

  bool get _isEditing => widget.transaction != null;
  bool get _isPairEdit => _sibling != null;

  @override
  void initState() {
    super.initState();
    final tx = widget.transaction;
    if (tx != null) {
      _amount.text = tx.amountMoney.toDecimalString();
      _merchant.text = tx.rawMerchant ?? '';
      _note.text = tx.note ?? '';
      _currency.text = tx.currency;
      _accountId = tx.accountId;
      _type = tx.type;
      _categoryId = tx.categoryId;
      _occurredAt = tx.occurredAt.toLocal();
      // Editing never invents a second leg: To starts outside unless the
      // row already has a sibling (the debit leg's account is From).
      _toAccountId = _outside;
      if (tx.transferGroupId != null) {
        _busy = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          try {
            final other =
                await ref.read(transferPairServiceProvider).sibling(tx);
            if (!mounted || other == null) return;
            setState(() {
              _sibling = other;
              final txIsDebit = transactionIsDebit(tx);
              _accountId = txIsDebit ? tx.accountId : other.accountId;
              _toAccountId = txIsDebit ? other.accountId : tx.accountId;
            });
          } finally {
            if (mounted) setState(() => _busy = false);
          }
        });
      }
    } else {
      final prefill = widget.prefill;
      if (prefill != null) {
        _amount.text = prefill.amountText ?? '';
        _merchant.text = prefill.merchant ?? '';
        if (prefill.currency != null) _currency.text = prefill.currency!;
        if (prefill.isDebit == false) _type = TransactionTypeEntity.income;
        if (prefill.occurredAt != null) {
          _occurredAt = prefill.occurredAt!.toLocal();
        }
      }
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // الحساب الافتراضي يحدّد العملة المبدئية.
        final account = await ref.read(accountRepositoryProvider).getDefault();
        if (mounted && account != null && _accountId == null) {
          setState(() {
            _accountId = account.id;
            // A currency read from the bank message is kept.
            if (prefill?.currency == null) _currency.text = account.currency;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _amount.dispose();
    _merchant.dispose();
    _note.dispose();
    _currency.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime() async {
    final date = await showGlassDatePicker(
      context: context,
      initialDate: _occurredAt,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) return;
    final time = await showGlassTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_occurredAt),
    );
    if (time == null || !mounted) return;
    setState(() {
      _occurredAt = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  /// From, the same-currency own accounts To may be, and the resolved To.
  ({AccountEntity from, List<AccountEntity> choices, String to})?
      _transferEnds(List<AccountEntity> accounts) {
    if (accounts.isEmpty) return null;
    final from = accounts.firstWhere((a) => a.id == _accountId,
        orElse: () => accounts.first);
    final choices = [
      for (final a in accounts)
        if (a.id != from.id && a.currency == from.currency) a,
    ];
    final picked = _toAccountId;
    final String to;
    if (picked == _outside && !_isPairEdit) {
      to = _outside;
    } else if (choices.any((a) => a.id == picked)) {
      to = picked!;
    } else {
      to = choices.isEmpty ? _outside : choices.first.id;
    }
    return (from: from, choices: choices, to: to);
  }

  Future<void> _save(CategoryCatalog catalog) async {
    if (_busy) return;
    final normalizedCurrency = _currency.text.trim().toUpperCase();
    final Money amount;
    try {
      amount = parseLocalizedMoney(_amount.text, normalizedCurrency);
    } on Exception {
      _error(context.l10n.mtEnterValidAmount);
      return;
    }
    if (amount.minorUnits <= 0) {
      _error(context.l10n.mtEnterValidAmount);
      return;
    }
    final categoryKey = _categoryKey ?? catalog.byId(_categoryId)?.key;
    final categoryId = _categoryId ?? catalog.byKey(_categoryKey)?.id;
    final isTransfer = _type == TransactionTypeEntity.transfer;
    if (categoryKey == null && !_isEditing && !isTransfer) {
      _error(context.l10n.mtPickCategory);
      return;
    }
    final ends = isTransfer
        ? _transferEnds(ref.read(accountsProvider).valueOrNull ?? const [])
        : null;
    // A pair cannot lose its other leg here (e.g. a cross-currency pair).
    if (_isPairEdit && ends?.to == _outside) {
      _error(context.l10n.mtSaveFailed);
      return;
    }

    setState(() => _busy = true);
    try {
      final List<TransactionEntity> committedTransactions;
      if (ends != null && ends.to != _outside) {
        final pairs = ref.read(transferPairServiceProvider);
        final pair = _isEditing
            ? await pairs.updatePair(
                widget.transaction!,
                fromAccountId: ends.from.id,
                toAccountId: ends.to,
                amountOut: amount,
                amountIn: amount,
                currencyOut: normalizedCurrency,
                currencyIn: normalizedCurrency,
                occurredAt: _occurredAt,
                note: _note.text,
              )
            : await pairs.savePair(
                fromAccountId: ends.from.id,
                toAccountId: ends.to,
                amountOut: amount,
                amountIn: amount,
                currencyOut: normalizedCurrency,
                currencyIn: normalizedCurrency,
                occurredAt: _occurredAt,
                note: _note.text,
              );
        committedTransactions = [pair.debit, pair.credit];
      } else if (ends != null && !_isEditing) {
        committedTransactions = [
          await ref.read(transferPairServiceProvider).saveOutside(
                accountId: ends.from.id,
                amount: amount,
                currency: normalizedCurrency,
                direction: TransactionDirectionEntity.debit,
                occurredAt: _occurredAt,
                note: _note.text,
              ),
        ];
      } else if (_isEditing) {
        committedTransactions = [
          await ref.read(transactionRepositoryProvider).updateTransaction(
              transactionId: widget.transaction!.id,
              amount: amount,
              currency: normalizedCurrency,
              type: _type,
              occurredAt: _occurredAt,
              rawMerchant: _merchant.text,
              categoryId: categoryId,
              note: _note.text,
              accountId: _accountId,
            ),
        ];
      } else {
        committedTransactions = [
          await ref.read(saveManualTransactionUseCaseProvider)(
            amount: amount,
            currency: normalizedCurrency,
            type: _type,
            occurredAt: _occurredAt,
            // Transfer with no accounts at all: the service's category.
            categoryKey: categoryKey ?? 'transfers',
            merchant: _merchant.text,
            note: _note.text,
            accountId: _accountId,
            cardLast4: widget.initialCardLast4,
          ),
        ];
      }
      if (!mounted) return;
      if (_isEditing) {
        ref.invalidate(transactionByIdProvider(widget.transaction!.id));
      }
      if (_sibling != null) {
        ref.invalidate(transactionByIdProvider(_sibling!.id));
      }
      refreshTransactions(ref);
      refreshBudgets(ref);
      refreshAchievements(ref);
      ref.invalidate(dashboardDataProvider);
      // Added or edited transactions can cross a budget threshold just
      // like SMS-captured ones — reuse the same checker so both paths alert.
      final prefs =
          await ref.read(loadNotificationPreferencesUseCaseProvider)();
      await CapturedMessageProcessor.checkBudgetAlert(
        ref.read(appDatabaseProvider),
        prefs,
        committedTransactions: committedTransactions,
        lang: LocalNotificationService.instance.notificationLanguage,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on RepoException catch (e) {
      if (mounted) _error(repoErrorMessage(context, e));
    } catch (_) {
      if (mounted) _error(context.l10n.mtSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final tx = widget.transaction;
    if (tx == null || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => GlassAlertDialog(
        title: Text(context.l10n.txdDeleteTitle),
        content: Text(_isPairEdit
            ? context.l10n.txdDeletePairBody
            : context.l10n.mtDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: context.colors.danger),
            child: Text(context.l10n.setDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      final transactionRepository = ref.read(transactionRepositoryProvider);
      final billRepository = ref.read(billRepositoryProvider);
      final affectedBillIds = _isPairEdit
          ? await ref.read(transferPairServiceProvider).deletePair(tx)
          : await ref.read(appDatabaseProvider).transaction(
              () async {
                await transactionRepository.deleteTransaction(tx.id);
                return billRepository.deletePaymentForTransaction(tx.id);
              },
            );
      if (!mounted) return;
      for (final billId in affectedBillIds) {
        ref.invalidate(billPaymentsProvider(billId));
      }
      if (affectedBillIds.isNotEmpty) {
        ref.invalidate(savedBillsProvider);
        ref.invalidate(billsViewProvider);
      }
      refreshTransactions(ref);
      refreshBudgets(ref);
      ref.invalidate(dashboardDataProvider);
      Navigator.of(context).pop();
      Navigator.of(context).maybePop();
    } on RepoException catch (e) {
      if (mounted) _error(repoErrorMessage(context, e));
    } catch (_) {
      if (mounted) _error(context.l10n.mtDeleteFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmTransaction() async {
    final tx = widget.transaction;
    if (tx == null ||
        _busy ||
        tx.status == TransactionStatus.confirmed ||
        tx.pricingState == TransactionPricingState.awaitingFx) {
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(confirmTransactionUseCaseProvider)(tx.id);
      if (!mounted) return;
      ref.invalidate(transactionByIdProvider(tx.id));
      refreshTransactions(ref);
      refreshBudgets(ref);
      refreshAchievements(ref);
      ref.invalidate(dashboardDataProvider);
      AppToast.show(context, context.l10n.txdConfirmedToast);
    } catch (_) {
      if (mounted) _error(context.l10n.mtConfirmFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _error(String message) {
    AppToast.showError(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final catalogAsync = ref.watch(categoryCatalogProvider);

    return AppSheetScaffold(
      title: _isEditing ? context.l10n.txnEditTx : context.l10n.mtAddManually,
      body: catalogAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => SingleChildScrollView(child: AppErrorState(
          title: context.l10n.mtCategoriesFailed,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(categoryCatalogProvider),
        )),
        data: (catalog) => _buildForm(context, catalog),
      ),
    );
  }

  /// UX-09 / SP-10: at large text, or on an SE-width phone, a field's label
  /// sits above it and wraps, instead of the one-line floating label that was
  /// cut off («Merchant or source (optional)» at 320 pt). The field keeps the
  /// label as its semantics label.
  Widget _labelled(BuildContext context, String label,
      Widget Function(String? labelText) field) {
    if (!isLargeText(context) && MediaQuery.sizeOf(context).width >= 360) {
      return field(label);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: 4, bottom: 4),
            child: Text(label,
                style: AppTypography.subhead(context.colors.textSecondary)),
          ),
        ),
        Semantics(label: label, child: field(null)),
      ],
    );
  }

  /// The account picker; [extra] items follow the accounts.
  Widget _accountField(
    BuildContext context,
    String label, {
    Key? key,
    required List<AccountEntity> accounts,
    required String? value,
    required ValueChanged<String?> onChanged,
    List<DropdownMenuItem<String>> extra = const [],
  }) {
    return _labelled(context, label,
        (labelText) => GlassDropdownField<String>(
      key: key,
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: labelText,
        prefixIcon: const Icon(AppLucideIcons.wallet),
      ),
      items: [
        for (final account in accounts)
          DropdownMenuItem(
            value: account.id,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // بنك/بطاقة بيتمثّلوا ببطاقة مصغّرة حقيقية بدل
                // نص مجرد — نفس لغة صفوف البطاقات.
                if (account.type == AccountType.bank ||
                    account.type == AccountType.card) ...[
                  MiniCardArt(
                    width: 36,
                    themeKey: account.type == AccountType.bank
                        ? 'navy'
                        : 'graphite',
                  ),
                  const SizedBox(width: 10),
                ],
                Flexible(
                  child: Text(
                    '${account.name} · ${Currency.label(context, account.currency)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ...extra,
      ],
      onChanged: onChanged,
    ));
  }

  /// Transfer mode: From, a swap, and To — the user's other accounts in the
  /// same currency, then someone outside them (not offered for a pair).
  Widget _transferFields(BuildContext context, List<AccountEntity> accounts) {
    final ends = _transferEnds(accounts)!;
    // Editing a pair keeps both legs in its currency.
    final fromAccounts = _isPairEdit
        ? [
            for (final a in accounts)
              if (a.currency == widget.transaction!.currency) a,
          ]
        : accounts;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _accountField(context, context.l10n.mtFromAccount,
            key: const ValueKey('manual-transfer-from'),
            accounts: fromAccounts,
            value: ends.from.id, onChanged: (id) {
          if (id == null) return;
          final account = accounts.firstWhere((a) => a.id == id);
          setState(() {
            _accountId = id;
            _currency.text = account.currency;
          });
        }),
        IconButton(
          tooltip: context.l10n.mtSwapAccounts,
          onPressed: ends.to == _outside
              ? null
              : () => setState(() {
                    _accountId = ends.to;
                    _toAccountId = ends.from.id;
                  }),
          icon: const Icon(AppLucideIcons.arrowUpDown),
        ),
        _accountField(context, context.l10n.mtToAccount,
            key: const ValueKey('manual-transfer-to'),
            accounts: ends.choices,
            value: ends.to,
            onChanged: (id) => setState(() => _toAccountId = id),
            extra: [
              if (!_isPairEdit)
                DropdownMenuItem(
                  value: _outside,
                  child: Text(context.l10n.mtSomeoneElse,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
            ]),
      ],
    );
  }

  Widget _buildForm(BuildContext context, CategoryCatalog catalog) {
    final c = context.colors;
    // The budget-scope sentinel is not a transaction category (same filter
    // as the change-category sheet), and nothing is pre-selected so the
    // existing «pick a category» check applies to a new entry.
    // FR-12: a legacy row stored under the sentinel keeps it as its own
    // choice, so editing shows the stored category instead of an empty field.
    final categories = catalog.all.where((category) {
      if (category.key == BudgetEntity.allExpensesCategoryKey) {
        return _categoryId != null && category.id == _categoryId;
      }
      if (_type == TransactionTypeEntity.income) {
        return category.entity.isIncome;
      }
      return !category.entity.isIncome;
    }).toList();
    final isTransfer = _type == TransactionTypeEntity.transfer;

    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(
        left: AppSpacing.gutter,
        right: AppSpacing.gutter,
        bottom: AppSpacing.s6,
      ),
      children: [
        const SizedBox(height: AppSpacing.s4),
        if (widget.prefill?.messageText?.isNotEmpty == true) ...[
          Text(context.l10n.mtFromMessage,
              style: AppTypography.subhead(c.textSecondary)),
          const SizedBox(height: 4),
          Text(widget.prefill!.messageText!,
              key: const ValueKey('manual-prefill-message'),
              style: AppTypography.caption(c.textMuted)),
          const SizedBox(height: AppSpacing.s4),
        ],
        // A pair cannot change type in place: it is two rows.
        IgnorePointer(
          ignoring: _isPairEdit,
          child: Opacity(
            opacity: _isPairEdit ? 0.5 : 1,
            child: SegmentedControl<TransactionTypeEntity>(
          value: _type,
          accent: true,
          onChanged: (value) {
            setState(() {
              _type = value;
              _categoryKey = null;
              _categoryId = null;
            });
          },
          options: [
            SegmentOption(
                value: TransactionTypeEntity.payment,
                label: context.l10n.mtKindExpense,
                icon: AppLucideIcons.minus),
            SegmentOption(
                value: TransactionTypeEntity.income,
                label: context.l10n.txnKindIncome,
                icon: AppLucideIcons.plus),
            SegmentOption(
                value: TransactionTypeEntity.transfer,
                label: context.l10n.txdTypeTransfer,
                icon: AppLucideIcons.arrowLeftRight),
          ],
            ),
          ),
        ),
        if (_isPairEdit) ...[
          const SizedBox(height: AppSpacing.s2),
          Text(context.l10n.mtTransferTypeLocked,
              textAlign: TextAlign.center,
              style: AppTypography.caption(c.textSecondary)),
        ],
        const SizedBox(height: AppSpacing.s4),
        // Big centered amount entry (mockup `.amountfield`), tinted by kind.
        _AmountField(
          controller: _amount,
          currency: _currency.text,
          color: switch (_type) {
            TransactionTypeEntity.income => c.income,
            TransactionTypeEntity.payment ||
            TransactionTypeEntity.withdrawal =>
              c.expense,
            _ => c.textMain,
          },
          autofocus: !_isEditing,
          onChanged: () => setState(() {}),
        ),
        const SizedBox(height: AppSpacing.s3),
        ref.watch(accountsProvider).dataOrWhen(
              data: (accounts) {
                if (accounts.isEmpty) return const SizedBox.shrink();
                if (isTransfer) return _transferFields(context, accounts);
                final value = accounts.any((a) => a.id == _accountId)
                    ? _accountId
                    : accounts.first.id;
                return _accountField(context, context.l10n.commonAccountDefinite,
                    accounts: accounts, value: value, onChanged: (id) {
                  if (id == null) return;
                  final account = accounts.firstWhere((a) => a.id == id);
                  setState(() {
                    _accountId = id;
                    _currency.text = account.currency;
                  });
                });
              },
              orElse: () => const SizedBox.shrink(),
            ),
        if (!isTransfer) ...[
        const SizedBox(height: AppSpacing.s3),
        _labelled(context, context.l10n.txnCategory,
            (labelText) => GlassDropdownField<String>(
          value: _categoryKey ?? catalog.byId(_categoryId)?.key,
          decoration: InputDecoration(
            labelText: labelText,
            prefixIcon: const Icon(AppLucideIcons.shapes),
          ),
          items: categories
              .map(
                (category) => DropdownMenuItem(
                  value: category.key,
                  child: Row(
                    children: [
                      CategoryGlyph(
                          name: category.iconName,
                          size: 18,
                          color: category.color),
                      const SizedBox(width: 8),
                      Text(category.name),
                    ],
                  ),
                ),
              )
              .toList(),
          onChanged: (value) => setState(() {
            _categoryKey = value;
            _categoryId = catalog.byKey(value)?.id;
          }),
        )),
        // Transfer saves keep no merchant, so the field is not offered.
        const SizedBox(height: AppSpacing.s3),
        _labelled(context, context.l10n.mtMerchantOptional,
            (labelText) => TextField(
          controller: _merchant,
          decoration: InputDecoration(
            labelText: labelText,
            prefixIcon: const Icon(AppLucideIcons.store),
          ),
        )),
        ],
        const SizedBox(height: AppSpacing.s3),
        OutlinedButton.icon(
          onPressed: _pickDateTime,
          icon: const Icon(AppLucideIcons.calendar),
          label: Text(
            '${_occurredAt.year}/${_occurredAt.month.toString().padLeft(2, '0')}/${_occurredAt.day.toString().padLeft(2, '0')} · ${Formatters.time(_occurredAt, context)}',
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        _labelled(context, context.l10n.mtNoteOptional,
            (labelText) => TextField(
          controller: _note,
          minLines: 2,
          maxLines: 4,
          decoration: InputDecoration(
            labelText: labelText,
            prefixIcon: const Icon(AppLucideIcons.fileText),
          ),
        )),
        if (isTransfer) ...[
          const SizedBox(height: AppSpacing.s3),
          Text(context.l10n.mtTransferHint,
              style: AppTypography.caption(c.textSecondary)),
        ],
        const SizedBox(height: AppSpacing.s4),
        FilledButton.icon(
          onPressed: _busy ? null : () => _save(catalog),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(AppLucideIcons.check),
          label: Text(_isEditing ? context.l10n.mtSaveEdits : context.l10n.mtAddTransaction),
        ),
        if (_isEditing) ...[
          const SizedBox(height: AppSpacing.s2),
          FilledButton.icon(
            onPressed: _busy ||
                    widget.transaction!.status == TransactionStatus.confirmed ||
                    widget.transaction!.pricingState == TransactionPricingState.awaitingFx
                ? null
                : _confirmTransaction,
            icon: Icon(
              widget.transaction!.status == TransactionStatus.confirmed
                  ? AppLucideIcons.badgeCheck
                  : AppLucideIcons.badgeCheck,
            ),
            label: Text(
              widget.transaction!.status == TransactionStatus.confirmed
                  ? context.l10n.mtTxConfirmed
                  : context.l10n.txdConfirmTx,
            ),
          ),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton.icon(
            onPressed: _busy ? null : _delete,
            icon: const Icon(AppLucideIcons.trash2),
            label: Text(context.l10n.txdDeleteTx),
            style: OutlinedButton.styleFrom(
              foregroundColor: c.danger,
              side: _busy ? null : BorderSide(color: c.danger),
            ),
          ),
        ],
      ],
    );
  }
}

/// Big centered amount entry — mockup `.amountfield` (44px, tinted by kind,
/// with the currency as a smaller trailing label).
class _AmountField extends StatelessWidget {
  const _AmountField({
    required this.controller,
    required this.currency,
    required this.color,
    required this.autofocus,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String currency;
  final Color color;
  final bool autofocus;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Text(
          context.l10n.bdgAmount,
          style: AppTypography.subhead(c.textSecondary)
              .copyWith(fontSize: 12.5, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: IntrinsicWidth(
                child: TextField(
                  controller: controller,
                  autofocus: autofocus,
                  onChanged: (_) => onChanged(),
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  cursorColor: c.cta,
                  style: AppTypography.balanceHero(color).copyWith(fontSize: 44),
                  decoration: InputDecoration(
                    filled: false,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    hintText: '0',
                    hintStyle: AppTypography.balanceHero(c.textMuted)
                        .copyWith(fontSize: 44),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              currency,
              style: AppTypography.title2(c.textSecondary)
                  .copyWith(fontSize: 17, fontWeight: FontWeight.w500),
            ),
          ],
        ),
      ],
    );
  }
}
