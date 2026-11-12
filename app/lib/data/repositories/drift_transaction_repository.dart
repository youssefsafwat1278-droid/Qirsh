import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/category_spend.dart';
import '../../domain/entities/report_models.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/financial_semantics.dart';
import '../../domain/finance/money.dart';
import '../../domain/repositories/transaction_repository.dart';
import '../../domain/services/card_account_grouper.dart';
import '../../domain/services/duplicate_transaction_detector.dart';
import '../../engine/parser/card_network.dart';
import '../../features/capture/services/ledger_outbox_queue.dart';
import '../capture/proof_correction_log.dart';
import '../db/app_database.dart';
import '../db/database_seed.dart';
import '../db/money_codec.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

enum _FinancialAggregateFlow { expense, income, expenseAndIncome }

class DriftTransactionRepository implements TransactionRepository {
  DriftTransactionRepository(this._db, {LedgerOutboxQueue? outboxQueue})
      : _outboxQueue = outboxQueue;

  final AppDatabase _db;
  final LedgerOutboxQueue? _outboxQueue;

  /// PHASE 11 correctness provenance. Constructed lazily from the same
  /// database so no call site has to wire it, and so an event can never be
  /// forgotten at one of the write methods.
  ProofCorrectionLog get _proofLog => ProofCorrectionLog(_db);

  @override
  Future<TransactionEntity> confirm(String id) async {
    return _db.transaction(() async {
      // A confirmed transaction must land in a totals bucket. 'unknown' matches
      // neither the expense filter (payment/withdrawal) nor income, so it would
      // stay confirmed-but-uncounted forever — ground it by direction here.
      await _db.customUpdate(
        '''
          UPDATE transactions
          SET status = 'confirmed',
              type = CASE
                WHEN type = 'unknown' AND direction = 'credit' THEN 'income'
                WHEN type = 'unknown' THEN 'payment'
                ELSE type
              END,
              updated_at = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(id),
        ],
      );

      final updated = await getById(id);
      if (updated == null) {
        throw StateError('Transaction not found: $id');
      }
      await _outboxQueue?.enqueue(OutboxOperation.update, updated);
      // PHASE 11: the user ACCEPTED the parse as-is. Distinguishable from an
      // edit only because this is an explicit event — confirm() also bumps
      // updated_at, which is why the timestamp could never carry this.
      await _proofLog.record(
        transactionId: id, event: ProofCorrectionEvent.confirmed);

      return updated;
    });
  }

  @override
  Future<TransactionEntity?> findDuplicate({
    required Money amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async {
    final merchantId = await _merchantIdByRawName(rawMerchant);
    if (merchantId == null) {
      return null;
    }

    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM transactions
        WHERE merchant_id = ?
          AND amount = ?
          AND occurred_at = ?
        ORDER BY occurred_at DESC
        LIMIT 1;
      ''',
      variables: [
        Variable.withString(merchantId),
        kMoneyCodec.realVar(amount),
        Variable.withString(dateTimeToSql(occurredAt.toUtc())),
      ],
    ).getSingleOrNull();

    return rows == null ? null : transactionFromRow(rows);
  }

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required Money amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) async {
    final timestampSql = dateTimeToSql(comparisonTimestamp.toUtc());
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM transactions
        WHERE status != 'ignored'
          AND (
            (amount = ? AND UPPER(currency) = ?)
            OR (foreign_amount = ? AND UPPER(foreign_currency) = ?)
          )
          AND (
            comparison_timestamp = ?
            OR (comparison_timestamp IS NULL AND occurred_at = ?)
          )
        ORDER BY occurred_at DESC;
      ''',
      variables: [
        kMoneyCodec.realVar(amount),
        Variable.withString(currency.trim().toUpperCase()),
        kMoneyCodec.realVar(amount),
        Variable.withString(currency.trim().toUpperCase()),
        Variable.withString(timestampSql),
        Variable.withString(timestampSql),
      ],
    ).get();
    final candidates = rows.map(transactionFromRow).toList();
    final result = const DuplicateTransactionDetector().detect(
      input: DuplicateTransactionInput(
        amount: amount,
        currency: currency,
        merchantOrDescription: merchantOrDescription,
        cardLast4: cardLast4,
        comparisonTimestamp: comparisonTimestamp,
        comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
      ),
      existingTransactions: candidates,
    );
    return result.existing;
  }

  /// How far apart two captures of the same text may be and still be treated
  /// as a possible re-capture of one message.
  static const Duration sameTextWindow = Duration(hours: 72);

  /// F9 — an earlier, still-live transaction created from the SAME message
  /// text (whitespace-insensitive), with the same amount and currency, whose
  /// comparison time is within [sameTextWindow] of [comparisonTimestamp].
  ///
  /// This is NOT proof of a duplicate: the same SMS captured through two paths
  /// and two genuinely identical purchases look alike when the body carries no
  /// time. The caller therefore never merges or drops — it keeps the new
  /// capture as a suspected duplicate for the user to decide.
  Future<TransactionEntity?> findSameTextCapture({
    required String rawMessage,
    required Money amount,
    required String currency,
    required DateTime comparisonTimestamp,
  }) async {
    String normalize(String text) =>
        text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final wanted = normalize(rawMessage);
    if (wanted.isEmpty) return null;
    final rows = await _db.customSelect(
      '''
        SELECT *
        FROM transactions
        WHERE status != 'ignored'
          AND amount = ? AND UPPER(currency) = ?
        ORDER BY occurred_at DESC
        LIMIT 100;
      ''',
      variables: [
        kMoneyCodec.realVar(amount),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).get();
    final at = comparisonTimestamp.toUtc();
    for (final candidate in rows.map(transactionFromRow)) {
      final other =
          (candidate.comparisonTimestamp ?? candidate.occurredAt).toUtc();
      if (other.difference(at).abs() > sameTextWindow) continue;
      if (normalize(candidate.rawMessage) == wanted) return candidate;
    }
    return null;
  }

  @override
  Future<TransactionEntity?> getById(String id) async {
    final row = await _db.customSelect(
      'SELECT * FROM transactions WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(id)],
    ).getSingleOrNull();
    return row == null ? null : transactionFromRow(row);
  }

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    String? resolvedCategoryId,
  }) async {
    return _db.transaction(() async {
      final normalizedCategoryKey =
          _categoryKeyForType(transaction.type, categoryKey);
      final normalizedMerchant =
          transaction.type == TransactionTypeEntity.transfer ||
                  transaction.type == TransactionTypeEntity.income
              ? null
              : transaction.rawMerchant?.trim();
      final merchantId =
          normalizedMerchant == null || normalizedMerchant.isEmpty
              ? null
              : await _resolveOrCreateMerchantId(normalizedMerchant);
      // MALI-029: a bulk caller that already batch-resolved the category id
      // passes it straight through — no per-row `_categoryIdByKey` SELECT. The
      // enforced FK on category_id keeps it fail-closed for a bad id. The fast
      // path is used ONLY when the type does not override the key (transfer /
      // withdrawal / income force 'transfers'/'cash'/'income' regardless of the
      // caller's key, so the caller's resolved id must NOT win there). A null
      // resolved id falls back to the validating key resolution unchanged.
      final categoryId =
          (resolvedCategoryId != null && normalizedCategoryKey == categoryKey)
              ? resolvedCategoryId
              : (normalizedCategoryKey == null
                  ? null
                  : await _categoryIdByKey(normalizedCategoryKey));
      final accountId = transaction.accountId ?? await _defaultAccountId();

      await _db.customStatement('''
        INSERT INTO transactions(
          id, amount, amount_minor, currency, account_id, merchant_id, raw_merchant, category_id, type, source,
          card_last4, balance_after, balance_after_minor, note, occurred_at, raw_message, parse_confidence, status,
          created_at, updated_at, foreign_amount, foreign_amount_minor, foreign_currency, direction,
          transaction_time_from_sms, sms_received_at, comparison_timestamp,
          comparison_timestamp_source, duplicate_status,
          possible_duplicate_of_transaction_id, duplicate_reason
        ) VALUES (
          ${sqlString(transaction.id)},
          ${kMoneyCodec.sqlRealLiteral(transaction.amountMoney)},
          ${kMoneyCodec.sqlMinorLiteral(transaction.amountMoney)},
          ${sqlString(transaction.currency)},
          ${sqlNullableString(accountId)},
          ${sqlNullableString(merchantId)},
          ${sqlNullableString(normalizedMerchant)},
          ${sqlNullableString(categoryId)},
          ${sqlString(transaction.type.name)},
          ${sqlString(transaction.source.name)},
          ${sqlNullableString(transaction.cardLast4)},
          ${kMoneyCodec.sqlNullableRealLiteral(transaction.balanceAfterMoney)},
          ${kMoneyCodec.sqlNullableMinorLiteral(transaction.balanceAfterMoney)},
          ${sqlNullableString(transaction.note)},
          ${sqlString(dateTimeToSql(transaction.occurredAt))},
          ${sqlString(transaction.rawMessage)},
          ${transaction.parseConfidence},
          ${sqlString(transaction.status.name)},
          ${sqlString(dateTimeToSql(transaction.createdAt))},
          ${sqlString(dateTimeToSql(transaction.updatedAt))},
          ${kMoneyCodec.sqlNullableRealLiteral(transaction.foreignMoney)},
          ${kMoneyCodec.sqlNullableMinorLiteral(transaction.foreignMoney)},
          ${sqlNullableString(transaction.foreignCurrency)},
          ${sqlNullableString(transactionDirectionToSql(transaction.direction))},
          ${sqlNullableString(transaction.transactionTimeFromSms == null ? null : dateTimeToSql(transaction.transactionTimeFromSms!))},
          ${sqlNullableString(transaction.smsReceivedAt == null ? null : dateTimeToSql(transaction.smsReceivedAt!))},
          ${sqlNullableString(transaction.comparisonTimestamp == null ? null : dateTimeToSql(transaction.comparisonTimestamp!))},
          ${sqlString(comparisonTimestampSourceToSql(transaction.comparisonTimestampSource))},
          ${sqlString(duplicateStatusToSql(transaction.duplicateStatus))},
          ${sqlNullableString(transaction.possibleDuplicateOfTransactionId)},
          ${sqlNullableString(transaction.duplicateReason)}
        );
      ''');

      final saved = await getById(transaction.id);
      if (saved == null) {
        throw StateError('Failed to load saved transaction: ${transaction.id}');
      }
      await _outboxQueue?.enqueue(OutboxOperation.create, saved);
      return saved;
    });
  }

  @override
  Future<TransactionEntity> updateCategory({
    required String transactionId,
    required String categoryKey,
  }) async {
    return _db.transaction(() async {
      final existing = await getById(transactionId);
      final normalizedCategoryKey =
          _categoryKeyForType(existing?.type, categoryKey) ?? categoryKey;
      final categoryId = await _categoryIdByKey(normalizedCategoryKey);
      if (categoryId == null) {
        throw StateError('Unknown category key: $categoryKey');
      }

      await _db.customUpdate(
        '''
          UPDATE transactions
          SET category_id = ?, status = 'confirmed', updated_at = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withString(categoryId),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(transactionId),
        ],
      );

      final updated = await getById(transactionId);
      if (updated == null) {
        throw StateError('Transaction not found: $transactionId');
      }
      await _outboxQueue?.enqueue(OutboxOperation.update, updated);
      // PHASE 11: category is NOT a Proof-relevant field. Recorded so the
      // population stays visible, explicitly as a non-financial edit.
      await _proofLog.record(
          transactionId: transactionId,
          event: ProofCorrectionEvent.nonFinancialEdit);

      return updated;
    });
  }

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
  }) async {
    return _db.transaction(() async {
      // PHASE 11 correctness provenance: capture the PRE-EDIT row so only
      // Proof-relevant changes count as a financial correction. A
      // category-only, merchant-only, note-only or date-only edit must not be
      // recorded as the parse having been wrong.
      // GUARDED for the same reason as updateAccount: getById() maps the whole
      // row and can throw on a value it does not recognise, and this method did
      // not read the row before provenance existed. A diagnostic concern must
      // never be able to break a user's edit. A null `beforeEdit` makes
      // financialDelta() see null old values, which it treats as "no change" —
      // so an unreadable row logs a non-financial edit rather than inventing a
      // correction it cannot substantiate.
      TransactionEntity? beforeEdit;
      try {
        beforeEdit = await getById(transactionId);
      } catch (_) {
        beforeEdit = null;
      }
      if (amount.currency != currency.trim().toUpperCase()) {
        throw ArgumentError(
          'transaction amount currency ${amount.currency} does not match '
          '${currency.trim().toUpperCase()}',
        );
      }
      final normalizedCategoryId = categoryId ?? await _categoryIdForType(type);
      final trimmedMerchant = type == TransactionTypeEntity.transfer ||
              type == TransactionTypeEntity.income
          ? null
          : rawMerchant?.trim();
      final merchantId = trimmedMerchant == null || trimmedMerchant.isEmpty
          ? null
          : await _resolveOrCreateMerchantId(trimmedMerchant);
      final normalizedNote = note?.trim();
      final accountClause = accountId == null ? '' : 'account_id = ?, ';
      await _db.customUpdate(
        '''
          UPDATE transactions
          SET ${accountClause}amount = ?, amount_minor = ?, currency = ?, type = ?, occurred_at = ?,
              comparison_timestamp = ?, merchant_id = ?, raw_merchant = ?,
              category_id = ?, note = ?,
              status = 'confirmed', updated_at = ?
          WHERE id = ?;
        ''',
        variables: [
          if (accountId != null) Variable.withString(accountId),
          kMoneyCodec.realVar(amount),
          kMoneyCodec.minorVar(amount),
          Variable.withString(currency),
          Variable.withString(type.name),
          Variable.withString(dateTimeToSql(occurredAt.toUtc())),
          Variable.withString(dateTimeToSql(occurredAt.toUtc())),
          merchantId == null
              ? const Variable<String>(null)
              : Variable.withString(merchantId),
          trimmedMerchant == null || trimmedMerchant.isEmpty
              ? const Variable<String>(null)
              : Variable.withString(trimmedMerchant),
          normalizedCategoryId == null || normalizedCategoryId.isEmpty
              ? const Variable<String>(null)
              : Variable.withString(normalizedCategoryId),
          normalizedNote == null || normalizedNote.isEmpty
              ? const Variable<String>(null)
              : Variable.withString(normalizedNote),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(transactionId),
        ],
      );

      final updated = await getById(transactionId);
      if (updated == null) {
        throw StateError('Transaction not found: $transactionId');
      }
      await _outboxQueue?.enqueue(OutboxOperation.update, updated);
      // PHASE 11: only the Proof-relevant classes decide whether this edit is a
      // correctness failure. financialDelta() returns an EMPTY set for a
      // non-financial edit, which recordEdit logs as nonFinancialEdit.
      final proofChanged = ProofCorrectionLog.financialDelta(
        oldAmountMinor: beforeEdit?.amountMoney.minorUnits,
        newAmountMinor: amount.minorUnits,
        oldCurrency: beforeEdit?.currency,
        newCurrency: currency,
        oldType: beforeEdit?.type.name,
        newType: type.name,
        oldAccountId: beforeEdit?.accountId,
        newAccountId: accountId ?? beforeEdit?.accountId,
      );
      await _proofLog.recordEdit(
          transactionId: transactionId, changedFields: proofChanged);

      return updated;
    });
  }

  @override
  Future<void> updateAccount({
    required String transactionId,
    required String accountId,
    /// Declared, never inferred. AccountCurrencyRepairService runs at EVERY
    /// BOOT and backfills orphaned rows through this method with no user
    /// involved; without this it would append a false `corrected_financial`
    /// per row from the first shipped boot.
    ProofEditOrigin origin = ProofEditOrigin.user,
  }) async {
    await _db.transaction(() async {
      // Provenance read, GUARDED. getById() maps the whole row and throws on
      // values it does not recognise (an unmapped `source`, for instance), and
      // updateAccount never read the row before this change — so an unguarded
      // read would let a diagnostic concern break a real update. On failure the
      // old value is unknown, and the emit below treats unknown as "changed",
      // which is the conservative direction for a safety metric.
      String? beforeAccount;
      var beforeKnown = false;
      try {
        beforeAccount = (await getById(transactionId))?.accountId;
        beforeKnown = true;
      } catch (_) {
        beforeKnown = false;
      }
      await _db.customUpdate(
        'UPDATE transactions SET account_id = ?, updated_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(accountId),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(transactionId),
        ],
      );
      if (_outboxQueue != null) {
        final tx = await getById(transactionId);
        if (tx != null) await _outboxQueue.enqueue(OutboxOperation.update, tx);
      }
      // PHASE 11: conservative — Proof does not corroborate an account today,
      // so counting a real user reassignment can only make the gate STRICTER.
      // Emitted INSIDE the transaction so a rolled-back edit leaves no event,
      // and only when the account actually CHANGES.
      if (!beforeKnown || beforeAccount != accountId) {
        await _proofLog.recordEdit(
          transactionId: transactionId,
          changedFields: const {ProofField.account},
          origin: origin,
        );
      }
    });
  }

  @override
  Future<void> updateCard({
    required String transactionId,
    required String? cardLast4,
  }) async {
    await _db.transaction(() async {
      await _db.customUpdate(
        'UPDATE transactions SET card_last4 = ?, updated_at = ? WHERE id = ?;',
        variables: [
          cardLast4 == null
              ? const Variable<String>(null)
              : Variable.withString(cardLast4),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(transactionId),
        ],
      );
      if (_outboxQueue != null) {
        final tx = await getById(transactionId);
        if (tx != null) await _outboxQueue.enqueue(OutboxOperation.update, tx);
      }
    });
  }

  @override
  Future<void> updateAmount({
    required String transactionId,
    required Money amount,
  }) async {
    await _db.transaction(() async {
      final existing = await getById(transactionId);
      if (existing == null) {
        throw StateError('Transaction not found: $transactionId');
      }
      if (amount.currency != existing.currency.trim().toUpperCase()) {
        throw ArgumentError(
          'transaction amount currency ${amount.currency} does not match '
          '${existing.currency.trim().toUpperCase()}',
        );
      }
      await _db.customUpdate(
        'UPDATE transactions SET amount = ?, amount_minor = ?, updated_at = ? WHERE id = ?;',
        variables: [
          kMoneyCodec.realVar(amount),
          kMoneyCodec.minorVar(amount),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(transactionId),
        ],
      );
      if (_outboxQueue != null) {
        final tx = await getById(transactionId);
        if (tx != null) await _outboxQueue.enqueue(OutboxOperation.update, tx);
      }
      // PHASE 11: an amount edit is the clearest financial correction there is
      // — with one exception. A foreign capture on a home-currency card is
      // stored with amount 0 ("awaiting pricing") BY DESIGN, because the SMS
      // carried no home-currency amount. The user typing it in is completing a
      // parse that never claimed an amount, not correcting a wrong one.
      // Counting it would systematically inflate the correction rate with the
      // app's own designed behaviour.
      final awaitingPricing = existing.amountMoney.minorUnits == 0;
      if (!awaitingPricing &&
          existing.amountMoney.minorUnits != amount.minorUnits) {
        await _proofLog.recordEdit(
          transactionId: transactionId,
          changedFields: const {ProofField.amount},
        );
      }
    });

  }

  @override
  Future<void> deleteTransaction(String id) async {
    await _db.transaction(() async {
      // Fetch before the soft-delete so we have the full entity for the outbox payload.
      final tx = _outboxQueue != null ? await getById(id) : null;
      await _db.customUpdate(
        '''
          UPDATE transactions
          SET status = 'ignored', updated_at = ?
          WHERE id = ?;
        ''',
        variables: [
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
          Variable.withString(id),
        ],
      );
      if (tx != null) await _outboxQueue!.enqueue(OutboxOperation.delete, tx);
      // PHASE 11: rejection is a correctness outcome in its own right — the
      // user threw the parse away rather than fixing it. Inside the
      // transaction: a delete that rolls back must not leave a rejection event,
      // and a committed delete must not lose one to a crash in the gap.
      await _proofLog.record(
          transactionId: id, event: ProofCorrectionEvent.rejectedOrDeleted);
    });

  }

  // MALI-074n: a specific account's scope is EXACT ownership (`account_id = ?`).
  // An unassigned (`account_id IS NULL`) row belongs to NO specific account and
  // must never be attributed to one just because its currency matches — that
  // made a single orphan row appear in every same-currency account. Unassigned
  // rows appear only in the all-accounts scope (`accountId == null`, no clause).
  static String _accountClause(String? accountId, {String tableAlias = ''}) {
    if (accountId == null) return '';
    final prefix = tableAlias.isEmpty ? '' : '$tableAlias.';
    return ' AND ${prefix}account_id = ?';
  }

  static List<Variable> _accountVars(String? accountId) =>
      accountId == null ? const [] : [Variable.withString(accountId)];

  // MALI-063n: restrict an aggregate to a single currency so a multi-currency
  // scope never sums different currencies under one label.
  static String _currencyClause(String? currency) =>
      currency == null ? '' : ' AND UPPER(currency) = ?';

  static List<Variable> _currencyVars(String? currency) => currency == null
      ? const []
      : [Variable.withString(currency.trim().toUpperCase())];

  static String _includedTotalsAccountClause({String tableAlias = ''}) {
    final prefix = tableAlias.isEmpty ? '' : '$tableAlias.';
    return ''' AND (${prefix}account_id IS NULL OR NOT EXISTS (
      SELECT 1
      FROM accounts aggregate_account
      WHERE aggregate_account.id = ${prefix}account_id
        AND aggregate_account.exclude_from_totals = 1
    ))''';
  }

  /// سياسة المجاميع المالية الموحّدة: تقبل المؤكّد فقط، وتحصر الدخل في
  /// `income` والمصروف في `payment|withdrawal|refund` مع توقيع الاسترداد
  /// بالسالب، وتستبعد التحويلات و`unknown` والمعلّقة/المتجاهلة من كل إجمالي.
  ///
  /// MALI-028 / Phase-4: كل نافذة زمنية في هذه المجمِّعات نصف-مفتوحة
  /// `[from, to)` — الحد الأدنى شامل والحد الأعلى غير شامل
  /// (`occurred_at >= from AND occurred_at < to`) بدلاً من `BETWEEN` الشامل
  /// للطرفين، فلا تُحسب لحظة الحد الأعلى في فترتين متجاورتين. المتصلون الحاليون
  /// يمرّرون `to` بلحظة أخيرة شاملة (مثل `now` أو `نهاية الشهر − 1ms`) فلا يتغيّر
  /// أي مجموع فعلي؛ الفائدة تظهر لمن يمرّر حدّ فترة نظيفًا (`بداية الفترة التالية`).
  ///
  /// استبعاد الحسابات المُعلَّمة `exclude_from_totals` يسري فقط عند التجميع عبر
  /// كل الحسابات (`accountId == null`) مع إبقاء `account_id IS NULL` داخل
  /// النطاق. عند فتح حساب بعينه (`accountId != null`) يظهر الحساب بمجاميعه
  /// كاملةً حتى لو كان مستبعَدًا من الإجماليات — فالعَلَم يمنع دخوله في المجموع
  /// المشترك، لا في عرض تفاصيله الخاصة.
  static ({String where, String signedAmount, String signedAmountMinor})
      _financialAggregateSql(
    _FinancialAggregateFlow flow, {
    String tableAlias = '',
    String? accountId,
  }) {
    final prefix = tableAlias.isEmpty ? '' : '$tableAlias.';
    final typeFilter = switch (flow) {
      _FinancialAggregateFlow.expense =>
        "${prefix}type IN ('payment', 'withdrawal', 'refund')",
      _FinancialAggregateFlow.income => "${prefix}type = 'income'",
      _FinancialAggregateFlow.expenseAndIncome =>
        "${prefix}type IN ('payment', 'withdrawal', 'refund', 'income')",
    };
    final signedAmount = flow == _FinancialAggregateFlow.income
        ? '${prefix}amount'
        : "CASE WHEN ${prefix}type = 'refund' "
            "THEN -${prefix}amount "
            "WHEN ${prefix}type IN ('payment', 'withdrawal') "
            "THEN ${prefix}amount ELSE 0 END";
    // MALI-026 (B8-3 §16): the exact int64 counterpart. Summed WITHOUT
    // `CAST(... AS REAL)` so an int64 overflow fails exact (SQLite raises), and
    // only ever within a single-currency scope.
    final signedAmountMinor = flow == _FinancialAggregateFlow.income
        ? '${prefix}amount_minor'
        : "CASE WHEN ${prefix}type = 'refund' "
            "THEN -${prefix}amount_minor "
            "WHEN ${prefix}type IN ('payment', 'withdrawal') "
            "THEN ${prefix}amount_minor ELSE 0 END";
    final accountExclusion = accountId == null
        ? _includedTotalsAccountClause(tableAlias: tableAlias)
        : '';
    return (
      where: "${prefix}status = 'confirmed' "
          'AND $typeFilter'
          '$accountExclusion',
      signedAmount: signedAmount,
      signedAmountMinor: signedAmountMinor,
    );
  }

  @override
  Future<List<TransactionEntity>> getRecent({
    int limit = 5,
    String? accountId,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status = 'confirmed'${_accountClause(accountId)}
        ORDER BY occurred_at DESC
        LIMIT ?;
      ''',
      variables: [..._accountVars(accountId), Variable.withInt(limit)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<TransactionEntity>> getAll() async {
    return getPage(offset: 0, limit: 1 << 30);
  }

  @override
  Future<List<TransactionEntity>> getPage({
    required int offset,
    int limit = 500,
  }) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status != 'ignored'
        ORDER BY occurred_at DESC, id DESC
        LIMIT ? OFFSET ?;
      ''',
      variables: [Variable.withInt(limit), Variable.withInt(offset)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<DateTime?> latestBankCaptureAt() async {
    final row = await _db
        .customSelect(
          "SELECT MAX(COALESCE(sms_received_at, created_at)) AS latest "
          "FROM transactions WHERE source = 'bank';",
        )
        .getSingleOrNull();
    final latest = row?.readNullable<String>('latest');
    return latest == null ? null : DateTime.tryParse(latest)?.toUtc();
  }

  @override
  Future<List<String>> distinctCurrencies() async {
    final rows = await _db
        .customSelect(
          "SELECT DISTINCT currency FROM transactions "
          "WHERE currency IS NOT NULL AND currency != '';",
        )
        .get();
    return rows.map((r) => r.read<String>('currency')).toList();
  }

  @override
  Future<List<TransactionEntity>> transactionsWithoutAccount({
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  }) async {
    final hasCursor = beforeOccurredAt != null && beforeId != null;
    final vars = <Variable>[];
    if (hasCursor) {
      final cur = dateTimeToSql(beforeOccurredAt);
      vars
        ..add(Variable.withString(cur))
        ..add(Variable.withString(cur))
        ..add(Variable.withString(beforeId));
    }
    vars.add(Variable.withInt(limit));
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE account_id IS NULL
          ${hasCursor ? 'AND (occurred_at < ? OR (occurred_at = ? AND id < ?))' : ''}
        ORDER BY occurred_at DESC, id DESC
        LIMIT ?;
      ''',
      variables: vars,
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<TransactionEntity>> getTransactionPage({
    required int limit,
    TransactionPageCursor? after,
    TransactionPageFilter filter = const TransactionPageFilter(),
  }) async {
    // B2-C — every supported filter pushed into SQL, keyset paged. The predicate
    // list below matches the transactions screen's Dart filter EXACTLY (see
    // transactions_providers _viewForLoaded, now removed): pending-only forces
    // status='pending' and drops the date/kind predicates (the notifier passes
    // from/to=null, kind=all in that mode); otherwise status!='ignored'.
    final where = <String>[];
    final vars = <Variable>[];

    if (filter.pendingOnly) {
      where.add("t.status = 'pending'");
    } else {
      where.add("t.status != 'ignored'");
    }
    if (filter.accountId != null) {
      where.add('t.account_id = ?');
      vars.add(Variable.withString(filter.accountId!));
    }
    if (filter.from != null) {
      where.add('t.occurred_at >= ?'); // half-open [from, to)
      vars.add(Variable.withString(dateTimeToSql(filter.from!)));
    }
    if (filter.to != null) {
      where.add('t.occurred_at < ?');
      vars.add(Variable.withString(dateTimeToSql(filter.to!)));
    }
    switch (filter.kind) {
      case TransactionPageKind.all:
        break;
      case TransactionPageKind.expenses:
        where.add("t.type IN ('payment', 'withdrawal')");
      case TransactionPageKind.income:
        where.add("t.type IN ('income', 'refund')");
      case TransactionPageKind.transfers:
        where.add("t.type = 'transfer'");
    }
    if (filter.categoryId != null) {
      where.add('t.category_id = ?');
      vars.add(Variable.withString(filter.categoryId!));
    }

    // Free-text search: matched PER FIELD (raw_merchant, currency, the 2-dp
    // amount, the joined category name_ar/key, note) with LIKE. This is a
    // documented refinement of the old naive whole-haystack `String.contains`
    // (which could match across a field boundary in the space-joined string);
    // per-field is the sane, expected semantics. LIKE wildcards in the query are
    // escaped so the match stays a literal substring. SQLite LOWER is ASCII-only
    // (Arabic/CJK have no case; only accented-Latin uppercase — rare in merchant
    // names — differs from Dart toLowerCase).
    // B2-C search case-fold contract: fold BOTH the column and the query with
    // SQLite's LOWER so the two are consistent. Do NOT Dart-`.toLowerCase()` the
    // query (that folded the query with Unicode rules while the column folded
    // with ASCII rules — the two diverged for a non-ASCII-Latin uppercase letter
    // like 'É'). Now both use ASCII LOWER: ASCII case-insensitivity is guaranteed
    // in BOTH directions; Arabic (no case) matches exactly; a non-ASCII-Latin
    // letter must be typed in its own case (documented ASCII-only fold). LOWER
    // leaves the '\' escape char and the %/_ wildcards untouched.
    final search = filter.search?.trim();
    final needsCategoryJoin = search != null && search.isNotEmpty;
    if (needsCategoryJoin) {
      final escaped = search
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      final likeParam = '%$escaped%';
      where.add(
        "("
        "LOWER(COALESCE(t.raw_merchant, '')) LIKE LOWER(?) ESCAPE '\\' "
        "OR LOWER(COALESCE(t.currency, '')) LIKE LOWER(?) ESCAPE '\\' "
        "OR printf('%.2f', t.amount) LIKE LOWER(?) ESCAPE '\\' "
        "OR LOWER(COALESCE(c.name_ar, '')) LIKE LOWER(?) ESCAPE '\\' "
        "OR LOWER(COALESCE(c.key, '')) LIKE LOWER(?) ESCAPE '\\' "
        "OR LOWER(COALESCE(t.note, '')) LIKE LOWER(?) ESCAPE '\\'"
        ")",
      );
      for (var i = 0; i < 6; i++) {
        vars.add(Variable.withString(likeParam));
      }
    }

    if (after != null) {
      // Keyset (occurred_at DESC, id DESC): strictly older than the last row.
      where.add('(t.occurred_at < ? OR (t.occurred_at = ? AND t.id < ?))');
      final cur = dateTimeToSql(after.occurredAt);
      vars
        ..add(Variable.withString(cur))
        ..add(Variable.withString(cur))
        ..add(Variable.withString(after.id));
    }

    vars.add(Variable.withInt(limit));
    final join = needsCategoryJoin
        ? 'LEFT JOIN categories c ON c.id = t.category_id'
        : '';
    final rows = await _db.customSelect(
      '''
        SELECT t.* FROM transactions t
        $join
        WHERE ${where.join(' AND ')}
        ORDER BY t.occurred_at DESC, t.id DESC
        LIMIT ?;
      ''',
      variables: vars,
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<TransactionEntity>> largestExpenses({
    required DateTime from,
    required DateTime to,
    String? accountId,
    int limit = 10,
  }) async {
    // MALI-030 — real bounded top-N: SQL ORDER BY amount + LIMIT so only the top
    // rows enter Dart (was: load the WHOLE table via getAll() then Dart-sort and
    // take N). Matches the report's "largest transactions" predicate exactly —
    // confirmed payment/withdrawal spends in [from, to), the excluded-account
    // policy for the all-accounts scope (via _includedTotalsAccountClause, the
    // same the canonical totals use) and exact account ownership otherwise.
    // Deterministic tie-break (occurred_at DESC, id DESC) mirrors the previous
    // stable Dart sort over the occurred_at-DESC page order.
    final accountExclusion = accountId == null
        ? _includedTotalsAccountClause()
        : _accountClause(accountId);
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status = 'confirmed'
          AND type IN ('payment', 'withdrawal')
          AND occurred_at >= ? AND occurred_at < ?$accountExclusion
        ORDER BY amount DESC, occurred_at DESC, id DESC
        LIMIT ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withInt(limit),
      ],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<TransactionEntity>> confirmedInRangePage({
    required DateTime from,
    required DateTime to,
    String? accountId,
    DateTime? beforeOccurredAt,
    String? beforeId,
    int limit = 500,
  }) async {
    // MALI-030 — keyset page for the report appendix: bounded [limit] rows per
    // read (never the whole table), ordered (occurred_at DESC, id DESC). The
    // cursor advances by the last row so pages never overlap or gap, with NO
    // OFFSET. Same excluded-account/ownership policy as the totals.
    final accountExclusion = accountId == null
        ? _includedTotalsAccountClause()
        : _accountClause(accountId);
    final hasCursor = beforeOccurredAt != null && beforeId != null;
    final keyset = hasCursor
        ? ' AND (occurred_at < ? OR (occurred_at = ? AND id < ?))'
        : '';
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE status = 'confirmed'
          AND occurred_at >= ? AND occurred_at < ?$accountExclusion$keyset
        ORDER BY occurred_at DESC, id DESC
        LIMIT ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        if (hasCursor) ...[
          Variable.withString(dateTimeToSql(beforeOccurredAt.toUtc())),
          Variable.withString(dateTimeToSql(beforeOccurredAt.toUtc())),
          Variable.withString(beforeId),
        ],
        Variable.withInt(limit),
      ],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<Money> expenseTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      accountId: accountId,
    );
    final row = await _db.customSelect(
      '''
        SELECT COALESCE(SUM(${aggregate.signedAmountMinor}), 0) AS t
        FROM transactions
        WHERE ${aggregate.where}
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}
          AND UPPER(currency) = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).getSingle();
    return Money(row.read<int>('t'), currency);
  }

  @override
  /// UX-022 — the REFUND component of the netted expense total, as a positive
  /// magnitude.
  ///
  /// `expenseTotalBetween` implements the documented contract
  /// `net expense = Σpayment + Σwithdrawal − Σrefund`, so a refund subtracts
  /// SILENTLY and no surface can explain the difference. In the QA's concrete
  /// case the Reports total read 2,120.00 against transactions of 420.00 +
  /// 1,899.00 with a 199.00 refund: correct, and unexplainable on screen.
  ///
  /// This does NOT change that contract — it reports one of its inputs so the
  /// UI can show `gross − refunds = net`. Same window, same scope, same
  /// exclusions, so the three figures always reconcile.
  Future<Money> refundTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      accountId: accountId,
    );
    final row = await _db.customSelect(
      '''
        SELECT COALESCE(SUM(amount_minor), 0) AS t
        FROM transactions
        WHERE ${aggregate.where}
          AND type = 'refund'
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}
          AND UPPER(currency) = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).getSingle();
    return Money(row.read<int>('t'), currency);
  }

  @override
  Future<Money> incomeTotalBetween({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.income,
      accountId: accountId,
    );
    final row = await _db.customSelect(
      '''
        SELECT COALESCE(SUM(${aggregate.signedAmountMinor}), 0) AS t
        FROM transactions
        WHERE ${aggregate.where}
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}
          AND UPPER(currency) = ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).getSingle();
    return Money(row.read<int>('t'), currency);
  }

  @override
  Future<Money?> latestBalanceAfter({String? accountId}) async {
    final row = await _db.customSelect(
      '''
        SELECT balance_after_minor AS m, currency
        FROM transactions
        WHERE status = 'confirmed'
          AND balance_after IS NOT NULL${_accountClause(accountId)}${accountId == null ? _includedTotalsAccountClause() : ''}
        ORDER BY occurred_at DESC
        LIMIT 1;
      ''',
      variables: _accountVars(accountId),
    ).getSingleOrNull();
    final minor = row?.readNullable<int>('m');
    if (row == null || minor == null) return null;
    return Money(minor, row.read<String>('currency'));
  }

  @override
  Future<List<CurrencyTotal>> currencyTotalsBetween({
    required DateTime from,
    required DateTime to,
  }) async {
    final aggregate =
        _financialAggregateSql(_FinancialAggregateFlow.expenseAndIncome);
    final rows = await _db.customSelect(
      '''
        SELECT UPPER(currency) AS currency,
          COALESCE(SUM(${aggregate.signedAmountMinor}), 0) AS expense,
          COALESCE(SUM(${FinancialSql.incomeSignedAmountMinor()}), 0) AS income
        FROM transactions
        WHERE ${aggregate.where}
          AND occurred_at >= ? AND occurred_at < ?
        GROUP BY UPPER(currency)
        ORDER BY currency ASC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
      ],
    ).get();
    return rows.map((r) {
      final currency = r.read<String>('currency');
      return CurrencyTotal(
        currency: currency,
        expense: Money(r.read<int>('expense'), currency),
        income: Money(r.read<int>('income'), currency),
      );
    }).toList();
  }

  /// A confirmed foreign spend still awaiting its home value (amount 0 with a
  /// foreign amount) is not a priced row: it must not add to row counts, day
  /// denominators or recurrence detection. Sums are unaffected (it is 0).
  String _pricedOnly([String? alias]) {
    final p = alias == null ? '' : '$alias.';
    return 'NOT (${p}amount_minor = 0 AND ${p}foreign_amount IS NOT NULL)';
  }

  @override
  Future<List<DailySpend>> dailyExpenseTotals({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      accountId: accountId,
    );
    final rows = await _db.customSelect(
      '''
        SELECT date(occurred_at, 'localtime') AS day,
               COALESCE(SUM(${aggregate.signedAmountMinor}), 0) AS total
        FROM transactions
        WHERE ${aggregate.where}
          AND ${_pricedOnly()}
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}
          AND UPPER(currency) = ?
        GROUP BY date(occurred_at, 'localtime')
        ORDER BY day ASC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).get();
    return rows
        .map(
          (r) => DailySpend(
            day: DateTime.parse(r.read<String>('day')),
            total: Money(r.read<int>('total'), currency),
          ),
        )
        .toList();
  }

  @override
  Future<List<CategorySpend>> categoryBreakdown({
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      accountId: accountId,
    );
    final rows = await _db.customSelect(
      '''
        SELECT category_id AS cid,
               SUM(${aggregate.signedAmountMinor}) AS total,
               COUNT(*) AS tx_count,
               -- UX-022: the refund magnitude folded into `total`, computed in
               -- the SAME pass so the two can never disagree about scope. The
               -- netting expression above is untouched.
               SUM(CASE WHEN type = 'refund' THEN amount_minor ELSE 0 END)
                 AS refund_total
        FROM transactions
        WHERE ${aggregate.where}
          AND category_id IS NOT NULL
          AND ${_pricedOnly()}
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}${_currencyClause(currency)}
        GROUP BY category_id
        ORDER BY total DESC;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        ..._currencyVars(currency),
      ],
    ).get();
    return rows
        .map(
          (r) => CategorySpend(
            categoryId: r.read<String>('cid'),
            total: Money(r.read<int>('total'), currency),
            count: r.read<int>('tx_count'),
            refunds: Money(r.read<int>('refund_total'), currency),
          ),
        )
        .toList();
  }

  @override
  Future<Money> categoryExpenseTotalBetween({
    required String categoryId,
    required DateTime from,
    required DateTime to,
    required String currency,
    String? accountId,
  }) async {
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      accountId: accountId,
    );
    final row = await _db.customSelect(
      '''
        SELECT COALESCE(SUM(${aggregate.signedAmountMinor}), 0) AS total
        FROM transactions
        WHERE ${aggregate.where}
          AND category_id = ?
          AND occurred_at >= ? AND occurred_at < ?${_accountClause(accountId)}
          AND UPPER(currency) = ?;
      ''',
      variables: [
        Variable.withString(categoryId),
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
      ],
    ).getSingle();
    return Money(row.read<int>('total'), currency);
  }

  @override
  Future<List<MerchantSpend>> merchantBreakdown({
    required DateTime from,
    required DateTime to,
    required String currency,
    int limit = 3,
    String? accountId,
  }) async {
    final accountClause = _accountClause(accountId, tableAlias: 't');
    final aggregate = _financialAggregateSql(
      _FinancialAggregateFlow.expense,
      tableAlias: 't',
      accountId: accountId,
    );
    final rows = await _db.customSelect(
      '''
        SELECT m.raw_name AS name,
               SUM(${aggregate.signedAmountMinor}) AS total,
               COUNT(*) AS tx_count,
               -- UX-022: same pass, same scope. `COUNT(*)` stays the true row
               -- count — a refund IS one of the rows the total is built from.
               -- What was missing was the refund itself, which is what made
               -- «1,700.00 · 2 عمليات» impossible to reconcile.
               SUM(CASE WHEN t.type = 'refund' THEN t.amount_minor ELSE 0 END)
                 AS refund_total
        FROM transactions t
        INNER JOIN merchants m ON m.id = t.merchant_id
        WHERE ${aggregate.where}
          AND ${_pricedOnly('t')}
          AND t.occurred_at >= ? AND t.occurred_at < ?$accountClause
          AND UPPER(t.currency) = ?
        GROUP BY t.merchant_id
        ORDER BY total DESC
        LIMIT ?;
      ''',
      variables: [
        Variable.withString(dateTimeToSql(from.toUtc())),
        Variable.withString(dateTimeToSql(to.toUtc())),
        ..._accountVars(accountId),
        Variable.withString(currency.trim().toUpperCase()),
        Variable.withInt(limit),
      ],
    ).get();
    return rows
        .map((r) => MerchantSpend(
              name: r.read<String>('name'),
              total: Money(r.read<int>('total'), currency),
              count: r.read<int>('tx_count'),
              refunds: Money(r.read<int>('refund_total'), currency),
            ))
        .toList();
  }

  @override
  Future<List<CardSummary>> getCardSummaries() async {
    final rows = await _db.customSelect(
      '''
        SELECT card_last4 AS last4,
               UPPER(currency) AS currency,
               SUM(${FinancialSql.netExpenseSignedAmountMinor()}) AS out_total,
               SUM(${FinancialSql.incomeSignedAmountMinor()}) AS in_total,
               COUNT(*) AS cnt,
               MAX(raw_message) AS sample,
               (SELECT color_theme FROM cards
                  WHERE cards.last4 = transactions.card_last4
                    AND cards.deleted_at IS NULL
                  ORDER BY cards.updated_at DESC LIMIT 1) AS color_theme,
               (SELECT accent_hex FROM cards
                  WHERE cards.last4 = transactions.card_last4
                    AND cards.deleted_at IS NULL
                  ORDER BY cards.updated_at DESC LIMIT 1) AS accent_hex
        FROM transactions
        WHERE card_last4 IS NOT NULL AND status = 'confirmed' AND ${_pricedOnly()}
        GROUP BY card_last4, UPPER(currency)
        ORDER BY card_last4 ASC, currency ASC;
      ''',
    ).get();
    return rows.map((r) {
      final currency = r.read<String>('currency');
      return CardSummary(
        last4: r.read<String>('last4'),
        currency: currency,
        network:
            CardNetworkDetector.detect(r.readNullable<String>('sample') ?? ''),
        totalOut: Money(r.read<int>('out_total'), currency),
        totalIn: Money(r.read<int>('in_total'), currency),
        count: r.read<int>('cnt'),
        colorTheme: r.readNullable<String>('color_theme'),
        accentHex: r.readNullable<String>('accent_hex'),
      );
    }).toList();
  }

  @override
  Future<List<CardAccountBreakdownRow>> getCardAccountBreakdown() async {
    final rows = await _db.customSelect(
      '''
        SELECT card_last4 AS last4,
               account_id AS account_id,
               UPPER(currency) AS currency,
               SUM(${FinancialSql.netExpenseSignedAmountMinor()}) AS out_total,
               SUM(${FinancialSql.incomeSignedAmountMinor()}) AS in_total,
               COUNT(*) AS cnt,
               MAX(raw_message) AS sample,
               (SELECT color_theme FROM cards
                  WHERE cards.last4 = transactions.card_last4
                    AND cards.account_id IS transactions.account_id
                    AND cards.deleted_at IS NULL
                  ORDER BY cards.updated_at DESC LIMIT 1) AS color_theme,
               (SELECT accent_hex FROM cards
                  WHERE cards.last4 = transactions.card_last4
                    AND cards.account_id IS transactions.account_id
                    AND cards.deleted_at IS NULL
                  ORDER BY cards.updated_at DESC LIMIT 1) AS accent_hex
        FROM transactions
        WHERE card_last4 IS NOT NULL AND status = 'confirmed' AND ${_pricedOnly()}
        GROUP BY card_last4, account_id, UPPER(currency);
      ''',
    ).get();
    return rows.map((r) {
      final currency = r.read<String>('currency');
      return CardAccountBreakdownRow(
        last4: r.read<String>('last4'),
        currency: currency,
        accountId: r.readNullable<String>('account_id'),
        totalOut: Money(r.read<int>('out_total'), currency),
        totalIn: Money(r.read<int>('in_total'), currency),
        count: r.read<int>('cnt'),
        sample: r.readNullable<String>('sample') ?? '',
        colorTheme: r.readNullable<String>('color_theme'),
        accentHex: r.readNullable<String>('accent_hex'),
      );
    }).toList();
  }

  /// F-032 / OD-02 — history for ONE physical card, by canonical identity.
  ///
  /// Prefer this over [getByCard]. `last4` is four digits and is not identity:
  /// two different cards can share it, and [getByCard] returns both, merging
  /// their histories across accounts.
  Future<List<TransactionEntity>> getByCardId(String cardId) async {
    final rows = await _db.customSelect(
      """
        SELECT * FROM transactions
        WHERE card_id = ? AND status = 'confirmed'
        ORDER BY occurred_at DESC;
      """,
      variables: [Variable.withString(cardId)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  /// Legacy last4 lookup.
  ///
  /// F-032: this matches across EVERY account, so it merges distinct physical
  /// cards that share four digits. Retained for the display surfaces that still
  /// group by last4; new callers should use [getByCardId].
  @override
  Future<List<TransactionEntity>> getByCard(String last4) async {
    final rows = await _db.customSelect(
      '''
        SELECT * FROM transactions
        WHERE card_last4 = ? AND status = 'confirmed'
        ORDER BY occurred_at DESC;
      ''',
      variables: [Variable.withString(last4)],
    ).get();
    return rows.map(transactionFromRow).toList();
  }

  @override
  Future<List<RecurringCandidate>> recurringCandidates(
      {String? accountId}) async {
    final accountClause = _accountClause(accountId, tableAlias: 't');
    final rows = await _db.customSelect(
      '''
        SELECT mid, name, currency, sum_m, cnt, months FROM (
          SELECT m.id AS mid, m.raw_name AS name,
                 MAX(UPPER(t.currency)) AS currency,
                 SUM(t.amount_minor) AS sum_m,
                 COUNT(*) AS cnt,
                 MIN(t.amount_minor) AS min_m,
                 MAX(t.amount_minor) AS max_m,
                 COUNT(DISTINCT strftime('%Y-%m', t.occurred_at)) AS months
          FROM transactions t
          INNER JOIN merchants m ON m.id = t.merchant_id
          WHERE t.type = 'payment' AND t.status = 'confirmed'
            AND ${_pricedOnly('t')}
            $accountClause
          GROUP BY t.merchant_id, UPPER(t.currency)
        )
        -- MALI-026 (B8-3 §16 correction): the recurrence-STABILITY gate is a pure
        -- INTEGER heuristic — |max-min| <= 15% of the exact average — expressed
        -- as `(max-min)*cnt*100 <= sum*15` so no floating money is constructed.
        -- The monetary estimate itself (sum/cnt) is built EXACTLY in Dart below.
        WHERE months >= 2 AND (max_m - min_m) * cnt * 100 <= sum_m * 15
        ORDER BY sum_m DESC;
      ''',
      variables: _accountVars(accountId),
    ).get();
    return rows.map((r) {
      final currency = r.read<String>('currency');
      final sumMinor = r.read<int>('sum_m');
      final cnt = r.read<int>('cnt');
      // Exact average payment = sum/cnt, ROUND_HALF_AWAY_FROM_ZERO once. Payments
      // are non-negative, and `rem` is bounded by `cnt` (a row count), so `2*rem`
      // cannot overflow — no floating average, no lossy double.
      final q = cnt == 0 ? 0 : sumMinor ~/ cnt;
      final rem = cnt == 0 ? 0 : sumMinor.remainder(cnt);
      final avgMinor = (cnt != 0 && 2 * rem >= cnt) ? q + 1 : q;
      return RecurringCandidate(
        merchantId: r.read<String>('mid'),
        name: r.read<String>('name'),
        estimatedAmountMoney: Money(avgMinor, currency),
        currency: currency,
        monthsSeen: r.read<int>('months'),
      );
    }).toList();
  }

  Future<String?> _defaultAccountId() async {
    final row = await _db
        .customSelect(
          'SELECT id FROM accounts ORDER BY is_default DESC, sort_order ASC LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String?> _categoryIdByKey(String categoryKey) async {
    final row = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(categoryKey)],
    ).getSingleOrNull();
    final existing = row?.read<String>('id');
    if (existing != null) return existing;

    final seeded = DatabaseSeed.categories
        .where((category) => category.key == categoryKey)
        .firstOrNull;
    if (seeded == null) return null;

    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
        VALUES (?, ?, ?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(seeded.id),
        Variable.withString(seeded.key),
        Variable.withString(seeded.nameAr),
        Variable.withString(seeded.icon),
        Variable.withString(seeded.color),
        Variable.withInt(seeded.isIncome ? 1 : 0),
        Variable.withInt(seeded.sort),
      ],
    );
    final inserted = await _db.customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(categoryKey)],
    ).getSingleOrNull();
    return inserted?.read<String>('id');
  }

  String? _categoryKeyForType(
    TransactionTypeEntity? type,
    String? requestedCategoryKey,
  ) {
    return switch (type) {
      TransactionTypeEntity.transfer => 'transfers',
      TransactionTypeEntity.withdrawal => 'cash',
      TransactionTypeEntity.income => 'income',
      _ => requestedCategoryKey,
    };
  }

  Future<String?> _categoryIdForType(TransactionTypeEntity type) async {
    final key = _categoryKeyForType(type, null);
    return key == null ? null : _categoryIdByKey(key);
  }

  Future<String?> _merchantIdByRawName(String rawMerchant) async {
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    final row = await _db.customSelect(
      'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
      variables: [Variable.withString(normalized)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<String> _resolveOrCreateMerchantId(String rawMerchant) async {
    final existing = await _merchantIdByRawName(rawMerchant);
    final now = dateTimeToSql(DateTime.now().toUtc());
    if (existing != null) {
      await _db.customUpdate(
        'UPDATE merchants SET last_seen_at = ? WHERE id = ?;',
        variables: [
          Variable.withString(now),
          Variable.withString(existing),
        ],
      );
      return existing;
    }

    final merchantId = IdGenerator.next();
    final normalized = AppDatabase.normalizeMerchant(rawMerchant);
    await _db.customInsert(
      '''
        INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
        VALUES (?, ?, ?, ?, ?);
      ''',
      variables: [
        Variable.withString(merchantId),
        Variable.withString(rawMerchant),
        Variable.withString(normalized),
        Variable.withString(now),
        Variable.withString(now),
      ],
    );
    return merchantId;
  }
}
