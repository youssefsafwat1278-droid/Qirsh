import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/bill_repository.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../features/common/transaction_direction.dart';
import '../db/app_database.dart';
import 'drift_repository_support.dart';

typedef TransferPair = ({TransactionEntity debit, TransactionEntity credit});

/// A transfer between two of the user's own accounts: two ordinary `transfer`
/// rows sharing `transfer_group_id` — a debit leg on From, a credit leg on To.
/// Each leg is correct on its own (totals exclude transfers, account views
/// filter on account_id), so a lost link never makes a figure wrong.
///
/// Legs are written with [TransactionRepository.saveTransaction] directly, not
/// the manual-save use case: its duplicate check (same amount, currency, time)
/// would swallow the second leg. The repository queues each write for sync.
class TransferPairService {
  TransferPairService({
    required AppDatabase db,
    required TransactionRepository transactions,
    required BillRepository bills,
  })  : _db = db,
        _transactions = transactions,
        _bills = bills;

  final AppDatabase _db;
  final TransactionRepository _transactions;
  final BillRepository _bills;

  Future<TransferPair> savePair({
    required String fromAccountId,
    required String toAccountId,
    required Money amountOut,
    required Money amountIn,
    required String currencyOut,
    required String currencyIn,
    required DateTime occurredAt,
    String? note,
  }) {
    _checkPair(fromAccountId, toAccountId);
    _checkAmount(amountOut, currencyOut);
    _checkAmount(amountIn, currencyIn);
    final groupId = IdGenerator.next();
    return _db.transaction(() async => (
          debit: await _saveLeg(fromAccountId, amountOut,
              TransactionDirectionEntity.debit, occurredAt, note, groupId),
          credit: await _saveLeg(toAccountId, amountIn,
              TransactionDirectionEntity.credit, occurredAt, note, groupId),
        ));
  }

  /// One transfer leg to or from someone outside the user's accounts.
  Future<TransactionEntity> saveOutside({
    required String accountId,
    required Money amount,
    required String currency,
    required TransactionDirectionEntity direction,
    required DateTime occurredAt,
    String? note,
  }) {
    _checkAmount(amount, currency);
    return _saveLeg(accountId, amount, direction, occurredAt, note, null);
  }

  /// The other live leg of [tx]'s transfer, or null.
  Future<TransactionEntity?> sibling(TransactionEntity tx) async {
    final group = tx.transferGroupId;
    if (group == null) return null;
    final row = await _db.customSelect(
      "SELECT * FROM transactions WHERE transfer_group_id = ? AND id != ? "
      "AND status != 'ignored' LIMIT 1;",
      variables: [Variable.withString(group), Variable.withString(tx.id)],
    ).getSingleOrNull();
    return row == null ? null : transactionFromRow(row);
  }

  /// Rewrites both legs of [tx]'s transfer. A missing other leg (an old
  /// single-row transfer, or one whose leg was deleted) is created and linked.
  Future<TransferPair> updatePair(
    TransactionEntity tx, {
    required String fromAccountId,
    required String toAccountId,
    required Money amountOut,
    required Money amountIn,
    required String currencyOut,
    required String currencyIn,
    required DateTime occurredAt,
    String? note,
  }) {
    _checkPair(fromAccountId, toAccountId);
    _checkAmount(amountOut, currencyOut);
    _checkAmount(amountIn, currencyIn);
    return _db.transaction(() async {
      final other = await sibling(tx);
      final groupId = tx.transferGroupId ?? IdGenerator.next();
      final txIsDebit = transactionIsDebit(tx);
      Future<TransactionEntity> write(TransactionEntity? leg, String accountId,
              Money amount, TransactionDirectionEntity direction) =>
          leg == null
              ? _saveLeg(
                  accountId, amount, direction, occurredAt, note, groupId)
              : _updateLeg(
                  leg, accountId, amount, direction, occurredAt, note, groupId);
      return (
        debit: await write(txIsDebit ? tx : other, fromAccountId, amountOut,
            TransactionDirectionEntity.debit),
        credit: await write(txIsDebit ? other : tx, toAccountId, amountIn,
            TransactionDirectionEntity.credit),
      );
    });
  }

  /// Deletes both legs exactly as the manual delete does (soft delete, sync
  /// delete, bill-payment cleanup). Returns the affected bill ids.
  Future<List<String>> deletePair(TransactionEntity tx) {
    return _db.transaction(() async {
      final other = await sibling(tx);
      final affectedBillIds = <String>[];
      for (final leg in [tx, if (other != null) other]) {
        await _transactions.deleteTransaction(leg.id);
        affectedBillIds
            .addAll(await _bills.deletePaymentForTransaction(leg.id));
      }
      return affectedBillIds;
    });
  }

  Future<TransactionEntity> _saveLeg(
    String accountId,
    Money amount,
    TransactionDirectionEntity direction,
    DateTime occurredAt,
    String? note,
    String? groupId,
  ) {
    final now = DateTime.now().toUtc();
    final trimmedNote = note?.trim();
    final hasNote = trimmedNote != null && trimmedNote.isNotEmpty;
    return _transactions.saveTransaction(
      transaction: TransactionEntity(
        id: IdGenerator.next(),
        amountMoney: amount,
        currency: amount.currency,
        accountId: accountId,
        type: TransactionTypeEntity.transfer,
        source: TransactionSourceEntity.unknown,
        direction: direction,
        note: hasNote ? trimmedNote : null,
        occurredAt: occurredAt.toUtc(),
        rawMessage: hasNote ? trimmedNote : 'Manual transaction',
        parseConfidence: 1,
        status: TransactionStatus.confirmed,
        createdAt: now,
        updatedAt: now,
        smsReceivedAt: now,
        comparisonTimestamp: occurredAt.toUtc(),
        transferGroupId: groupId,
      ),
      categoryKey: 'transfers',
    );
  }

  /// Direction and link first, then the repository's own edit, which queues
  /// one sync update carrying the final row.
  Future<TransactionEntity> _updateLeg(
    TransactionEntity leg,
    String accountId,
    Money amount,
    TransactionDirectionEntity direction,
    DateTime occurredAt,
    String? note,
    String groupId,
  ) async {
    await _db.customUpdate(
      'UPDATE transactions SET direction = ?, transfer_group_id = ? '
      'WHERE id = ?;',
      variables: [
        Variable.withString(transactionDirectionToSql(direction)!),
        Variable.withString(groupId),
        Variable.withString(leg.id),
      ],
    );
    return _transactions.updateTransaction(
      transactionId: leg.id,
      amount: amount,
      currency: amount.currency,
      type: TransactionTypeEntity.transfer,
      occurredAt: occurredAt,
      rawMerchant: null,
      categoryId: leg.categoryId,
      note: note,
      accountId: accountId,
    );
  }

  static void _checkPair(String fromAccountId, String toAccountId) {
    if (fromAccountId == toAccountId) {
      throw ArgumentError('a transfer needs two different accounts');
    }
  }

  static void _checkAmount(Money amount, String currency) {
    if (amount.minorUnits <= 0) {
      throw ArgumentError('a transfer amount must be positive');
    }
    if (amount.currency != currency.trim().toUpperCase()) {
      throw ArgumentError(
          'transfer amount currency ${amount.currency} does not match '
          '${currency.trim().toUpperCase()}');
    }
  }
}
