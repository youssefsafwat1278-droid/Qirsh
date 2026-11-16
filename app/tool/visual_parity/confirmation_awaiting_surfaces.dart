// Actual public awaiting-price UI, owned synthetic memory, never a confirmation.
import 'dart:async';
import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/backend/rules_client.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/capture/proof_correction_log.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/confirm_transaction_usecase.dart';
import 'package:money_companion/features/transactions/widgets/confirm_transaction_sheet.dart';

const visualParityConfirmationAwaitingKeys = [
  'confirmationAwaitingPricing',
  'confirmationActualFeeNotice'
];
final _events = <String, int>{};
final _receipts = <String, Map<String, Object?>>{};
Map<String, int> visualParityConfirmationAwaitingEvents() =>
    Map.unmodifiable(_events);
Map<String, Map<String, Object?>> visualParityConfirmationAwaitingReceipts() =>
    Map.unmodifiable(_receipts);
void _record(String key) =>
    _events.update(key, (n) => n + 1, ifAbsent: () => 1);
Future<String> _snapshot(AppDatabase db) async {
  final tables = await db
      .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .get();
  return jsonEncode({
    for (final table in tables)
      table.read<String>('name'): (await db
              .customSelect(
                  'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid')
              .get())
          .map((r) => r.data)
          .toList()
  });
}

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'owned-awaiting-memory';
  @override
  Future<String?> readStoredKey() async => 'owned-awaiting-memory';
}

class _ReadOnlyTransactions extends DriftTransactionRepository {
  _ReadOnlyTransactions(super.db, this.key);
  final String key;
  Never _deny() {
    _record('${key}ForbiddenWrite');
    throw StateError('awaiting_price_write_forbidden');
  }

  @override
  Future<TransactionEntity> confirm(String id) async => _deny();
  @override
  Future<void> updateAmount(
          {required String transactionId, required Money amount}) async =>
      _deny();
  @override
  Future<void> updateAccount(
          {required String transactionId,
          required String accountId,
          ProofEditOrigin origin = ProofEditOrigin.user}) async =>
      _deny();
  @override
  Future<TransactionEntity> updateCategory(
          {required String transactionId,
          required String categoryKey,
          bool appliedByRule = false}) async =>
      _deny();
  @override
  Future<TransactionEntity> updateTransaction({
    required String transactionId,
    required Money amount,
    required String currency,
    required TransactionTypeEntity type,
    required DateTime occurredAt,
    required String? rawMerchant,
    required String? categoryId,
    required String? note,
    String? accountId,
  }) async =>
      _deny();
  @override
  Future<void> deleteTransaction(String transactionId) async => _deny();
  @override
  Future<TransactionEntity> saveTransaction(
          {required TransactionEntity transaction,
          required String? categoryKey,
          String? resolvedCategoryId}) async =>
      _deny();
}

Future<bool> openVisualParityConfirmationAwaiting(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityConfirmationAwaitingKeys.contains(key)) return false;
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('awaiting_price_requires_offline_debug');
  }
  if (!context.mounted) return false;
  final locale = Localizations.localeOf(context);
  final parent = ref.read(appDatabaseProvider);
  final databases = await parent.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) =>
      row.read<String>('name') == 'main' && row.read<String>('file').isEmpty)) {
    throw StateError('awaiting_price_requires_memory_database');
  }
  final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _Keys(),
      initialLanguage: 'en');
  ProviderContainer? container;
  String? baseline;
  Future<void>? closing;
  Future<void> close() => closing ??= (() async {
        try {
          if (baseline != null) {
            final unchanged = await _snapshot(db) == baseline;
            _receipts[key] = Map.unmodifiable({
              ..._receipts[key]!,
              'childAllSqlUnchanged': unchanged,
              'phase': 'closed'
            });
            if (!unchanged) {
              throw StateError('awaiting_price_child_sql_changed');
            }
            _record('${key}AllSqlUnchanged');
          }
        } finally {
          container?.dispose();
          await db.close();
          _record('${key}Closed');
        }
      })();
  try {
    final feeCase = key == 'confirmationActualFeeNotice';
    final settings = await DriftUserSettingsRepository(db).getSettings();
    if (settings.cloudProcessingEnabled) {
      throw StateError('awaiting_price_requires_actual_denied_consent');
    }
    final accounts = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 11, 1);
    final account = await accounts.create(AccountEntity(
        id: feeCase ? 'qa-fee-sar' : 'qa-awaiting-egp',
        name: feeCase ? 'QA SAR account' : 'QA EGP account',
        currency: feeCase ? 'SAR' : 'EGP',
        type: AccountType.bank,
        isDefault: true,
        sortOrder: 0,
        initialBalanceMoney: Money.zero(feeCase ? 'SAR' : 'EGP'),
        currentBalanceMoney: Money.zero(feeCase ? 'SAR' : 'EGP'),
        createdAt: now,
        updatedAt: now));
    final TransactionEntity actual;
    AddTransactionResult? secondary;
    CapturedMessageResult? actualCapture;
    if (feeCase) {
      final setup = ProviderContainer(
          overrides: [appDatabaseProvider.overrideWithValue(db)]);
      try {
        final coordinator = setup.read(planningCutoverCoordinatorProvider)
            as DbBackedPlanningCutoverCoordinator;
        await coordinator.refreshFromDatabase();
        final transactions = DriftTransactionRepository(db);
        final rules = RulesClient(database: db);
        final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
            transactionRepository: transactions,
            accountRepository: accounts,
            merchantCategoryRepository: DriftMerchantCategoryRepository(db),
            suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
            dedupStore: DriftDedupStore(db),
            coordinator: coordinator,
            loadBankProfiles: ({String? senderId}) =>
                rules.localBankProfiles(senderId: senderId),
            loadCatalogRules: rules.catalogRulesForSender));
        const raw =
            'شراء إنترنت\nبطاقة:7640; urpay بطاقة;\nمبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE.CO..\n24-6-2026 11:42';
        final returned = await ingest.fromCapturedMessage(CapturedMessage(
            text: raw,
            source: CapturedMessageSource.manualPaste,
            receivedAt: DateTime.utc(2026, 6, 24, 11, 42)));
        final result = returned.addTransactionResult;
        actualCapture = returned;
        secondary = result.secondary;
        final main = result.transaction;
        final fee = secondary?.transaction;
        if (result.outcome != AddTransactionOutcome.added ||
            secondary?.outcome != AddTransactionOutcome.added ||
            main == null ||
            fee == null ||
            main.id == fee.id ||
            main.amountMoney != Money.zero('SAR') ||
            main.foreignMoney != Money(9900, 'USD') ||
            main.status != TransactionStatus.pending ||
            main.source != TransactionSourceEntity.card ||
            main.pricingState != TransactionPricingState.awaitingFx ||
            returned.disposition !=
                CapturedMessageDisposition.requestConfirmation ||
            result.aiFailureReason != 'no_ai_client' ||
            fee.amountMoney != Money(744, 'SAR') ||
            fee.status != TransactionStatus.confirmed ||
            coordinator.state() != PlanningCutoverState.canonical) {
          throw StateError('actual_fee_pipeline_changed');
        }
        final rows = await db.customSelect('SELECT * FROM transactions').get();
        if (rows.length != 2) throw StateError('actual_fee_row_count_changed');
        for (final tx in [main, fee]) {
          final row =
              rows.singleWhere((row) => row.read<String>('id') == tx.id);
          final readback = await transactions.getById(tx.id);
          if (row.read<int>('amount_minor') != tx.amountMoney.minorUnits ||
              row.read<String>('currency') != tx.currency ||
              row.read<String>('status') != tx.status.name ||
              readback?.amountMoney != tx.amountMoney ||
              readback?.foreignMoney != tx.foreignMoney ||
              readback?.accountId != account.id) {
            throw StateError('actual_fee_canonical_readback_changed');
          }
        }
        final mainRow =
            rows.singleWhere((row) => row.read<String>('id') == main.id);
        if (mainRow.read<int>('foreign_amount_minor') != 9900 ||
            mainRow.read<String>('foreign_currency') != 'USD') {
          throw StateError('actual_fee_foreign_canonical_changed');
        }
        actual = main;
        _record('${key}ActualIngest');
      } finally {
        setup.dispose();
      }
    } else {
      actual = await DriftTransactionRepository(db).saveTransaction(
          transaction: TransactionEntity(
              id: 'qa-confirm-awaiting',
              accountId: account.id,
              amountMoney: Money.zero('EGP'),
              currency: 'EGP',
              foreignMoney: Money(12345, 'KWD'),
              foreignCurrency: 'KWD',
              type: TransactionTypeEntity.payment,
              source: TransactionSourceEntity.bank,
              occurredAt: now,
              rawMessage: 'Synthetic foreign purchase',
              rawMerchant: 'QA purchase',
              parseConfidence: .6,
              status: TransactionStatus.pending,
              createdAt: now,
              updatedAt: now),
          categoryKey: 'groceries');
    }
    final transactions = _ReadOnlyTransactions(db, key);
    container = ProviderContainer(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      localeProvider.overrideWithValue(locale),
      accountRepositoryProvider.overrideWithValue(accounts),
      categoryRepositoryProvider.overrideWithValue(DriftCategoryRepository(db)),
      transactionRepositoryProvider.overrideWithValue(transactions),
      confirmTransactionUseCaseProvider
          .overrideWithValue(ConfirmTransactionUseCase(transactions))
    ]);
    baseline = await _snapshot(db);
    _receipts[key] = Map.unmodifiable({
      'syntheticOnly': true,
      'transactionId': actual.id,
      'amountMinor': actual.amountMoney.minorUnits,
      'currency': actual.currency,
      'foreignMinor': actual.foreignMoney!.minorUnits,
      'foreignCurrency': actual.foreignCurrency,
      'status': actual.status.name,
      'pricingState': actual.pricingState.name,
      'actualCloudProcessingEnabled': settings.cloudProcessingEnabled,
      'actualOutcome': actualCapture?.addTransactionResult.outcome.name,
      'actualDisposition': actualCapture?.disposition.name,
      'aiFailureReason': actualCapture?.addTransactionResult.aiFailureReason,
      'secondaryOutcome': secondary?.outcome.name,
      'feeId': secondary?.transaction?.id,
      'feeMinor': secondary?.transaction?.amountMoney.minorUnits,
      'feeCurrency': secondary?.transaction?.currency,
      'feeStatus': secondary?.transaction?.status.name,
      'phase': 'ready'
    });
    if (!context.mounted) {
      await close();
      return false;
    }
    _record('${key}Opened');
    final owned = container;
    unawaited(Navigator.of(context)
        .push<void>(MaterialPageRoute<void>(
            builder: (_) => _Lifetime(
                close: close,
                child: UncontrolledProviderScope(
                    container: owned,
                    child: Navigator(
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                            builder: (_) => _Host(
                                id: actual.id,
                                secondary: secondary,
                                closeOuter: () {
                                  if (context.mounted) {
                                    Navigator.of(context).pop();
                                  }
                                })))))))
        .whenComplete(close));
    return true;
  } catch (_) {
    await close();
    rethrow;
  }
}

class _Lifetime extends StatefulWidget {
  const _Lifetime({required this.close, required this.child});
  final Future<void> Function() close;
  final Widget child;
  @override
  State<_Lifetime> createState() => _LifetimeState();
}

class _LifetimeState extends State<_Lifetime> {
  @override
  void dispose() {
    unawaited(widget.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _Host extends StatefulWidget {
  const _Host({required this.id, required this.closeOuter, this.secondary});
  final String id;
  final AddTransactionResult? secondary;
  final VoidCallback closeOuter;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showConfirmTransactionSheet(context, widget.id,
          secondaryNotice: feeNoticeFor(context, widget.secondary));
      if (mounted) widget.closeOuter();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Isolated awaiting-price QA'));
}
