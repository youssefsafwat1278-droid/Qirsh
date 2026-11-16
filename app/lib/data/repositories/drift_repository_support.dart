import 'package:drift/drift.dart';

import '../../domain/entities/budget_entity.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/entities/goal_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/finance/money.dart';
import '../db/app_database.dart';
import '../db/money_codec.dart';
import '../db/sql_value_codec.dart';

/// Canonical persistence seam for a per-row-currency bill-payment pulled by
/// the shared planning-child coordinator. Keeping the SQL here prevents the
/// coordinator itself from becoming an unregistered money writer.
Future<void> writePulledBillPayment({
  required AppDatabase db,
  required Map<String, dynamic> row,
  required String localId,
  required String billLocalId,
  required String? transactionLocalId,
  required Money amountMoney,
  required String now,
}) async {
  await db.customStatement('''
    INSERT INTO bill_payments(
      id, bill_id, amount, amount_minor, currency, period_start, period_end, paid_at,
      installment_index, transaction_id, note, server_id, synced_at,
      server_updated_at, sync_status, deleted_at
    ) VALUES (
      ${sqlString(localId)}, ${sqlString(billLocalId)},
      ${kMoneyCodec.sqlRealLiteral(amountMoney)},
      ${kMoneyCodec.sqlMinorLiteral(amountMoney)},
      ${sqlString(amountMoney.currency)},
      ${sqlString(row['period_start'] as String)},
      ${sqlString(row['period_end'] as String)},
      ${sqlString(row['paid_at'] as String)},
      ${sqlNullableNum(row['installment_index'] as num?)},
      ${sqlNullableString(transactionLocalId)},
      ${sqlNullableString(row['note'] as String?)},
      ${sqlString(row['id'] as String)}, ${sqlString(now)},
      ${sqlNullableString(row['updated_at'] as String?)}, 'synced',
      ${sqlNullableString(row['deleted_at'] as String?)}
    ) ON CONFLICT(id) DO UPDATE SET
      bill_id=excluded.bill_id, amount=excluded.amount,
      amount_minor=excluded.amount_minor,
      currency=excluded.currency, period_start=excluded.period_start,
      period_end=excluded.period_end, paid_at=excluded.paid_at,
      installment_index=excluded.installment_index,
      transaction_id=excluded.transaction_id, note=excluded.note,
      server_id=excluded.server_id, synced_at=excluded.synced_at,
      server_updated_at=excluded.server_updated_at,
      sync_status='synced', deleted_at=excluded.deleted_at;
  ''');
}

/// Canonical money binding for the subscription counter returned by the
/// record-payment RPC. The coordinator resolves/decodes transport values;
/// this approved persistence module owns the actual money-column write.
Future<void> writePulledSubscriptionCounter({
  required AppDatabase db,
  required String serverId,
  required int? paidCount,
  required Money? manualPaidMoney,
  required String? serverUpdatedAt,
}) async {
  await db.customStatement('''
    UPDATE subscriptions
    SET paid_count = ${sqlNullableNum(paidCount)},
        manual_paid_amount = ${kMoneyCodec.sqlNullableRealLiteral(manualPaidMoney)},
        manual_paid_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(manualPaidMoney)},
        synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
        server_updated_at = ${sqlNullableString(serverUpdatedAt)},
        sync_status = 'synced'
    WHERE server_id = ${sqlString(serverId)};
  ''');
}

BudgetPeriod budgetPeriodFromSql(String value) {
  switch (value) {
    case 'daily':
      return BudgetPeriod.daily;
    case 'weekly':
      return BudgetPeriod.weekly;
    case 'monthly':
      return BudgetPeriod.monthly;
    case 'yearly':
      return BudgetPeriod.yearly;
    default:
      throw ArgumentError.value(value, 'value', 'Unknown budget period.');
  }
}

String budgetPeriodToSql(BudgetPeriod value) => value.name;

TransactionStatus transactionStatusFromSql(String value) {
  switch (value) {
    case 'confirmed':
      return TransactionStatus.confirmed;
    case 'pending':
      return TransactionStatus.pending;
    case 'ignored':
      return TransactionStatus.ignored;
    default:
      throw ArgumentError.value(value, 'value', 'Unknown transaction status.');
  }
}

TransactionTypeEntity transactionTypeFromSql(String value) {
  switch (value) {
    case 'payment':
      return TransactionTypeEntity.payment;
    case 'withdrawal':
      return TransactionTypeEntity.withdrawal;
    case 'transfer':
      return TransactionTypeEntity.transfer;
    case 'refund':
      return TransactionTypeEntity.refund;
    case 'income':
      return TransactionTypeEntity.income;
    case 'unknown':
      return TransactionTypeEntity.unknown;
    default:
      throw ArgumentError.value(value, 'value', 'Unknown transaction type.');
  }
}

TransactionSourceEntity transactionSourceFromSql(String value) {
  switch (value) {
    case 'bank':
      return TransactionSourceEntity.bank;
    case 'card':
      return TransactionSourceEntity.card;
    case 'wallet':
      return TransactionSourceEntity.wallet;
    case 'unknown':
      return TransactionSourceEntity.unknown;
    case 'aiParsed':
      return TransactionSourceEntity.aiParsed;
    case 'imported':
      return TransactionSourceEntity.imported;
    default:
      throw ArgumentError.value(value, 'value', 'Unknown transaction source.');
  }
}

TransactionDirectionEntity? transactionDirectionFromSql(String? value) {
  return switch (value) {
    'credit' => TransactionDirectionEntity.credit,
    'debit' => TransactionDirectionEntity.debit,
    'unknown' => TransactionDirectionEntity.unknown,
    null => null,
    _ => null,
  };
}

String? transactionDirectionToSql(TransactionDirectionEntity? value) {
  return switch (value) {
    TransactionDirectionEntity.credit => 'credit',
    TransactionDirectionEntity.debit => 'debit',
    TransactionDirectionEntity.unknown => 'unknown',
    null => null,
  };
}

ComparisonTimestampSource comparisonTimestampSourceFromSql(String? value) {
  return switch (value) {
    'sms_body' => ComparisonTimestampSource.smsBody,
    'received_at' => ComparisonTimestampSource.receivedAt,
    null => ComparisonTimestampSource.receivedAt,
    _ => ComparisonTimestampSource.receivedAt,
  };
}

String comparisonTimestampSourceToSql(ComparisonTimestampSource value) {
  return switch (value) {
    ComparisonTimestampSource.smsBody => 'sms_body',
    ComparisonTimestampSource.receivedAt => 'received_at',
  };
}

DuplicateStatus duplicateStatusFromSql(String? value) {
  return switch (value) {
    'suspicious_duplicate' => DuplicateStatus.suspiciousDuplicate,
    'normal' => DuplicateStatus.normal,
    null => DuplicateStatus.normal,
    _ => DuplicateStatus.normal,
  };
}

String duplicateStatusToSql(DuplicateStatus value) {
  return switch (value) {
    DuplicateStatus.normal => 'normal',
    DuplicateStatus.suspiciousDuplicate => 'suspicious_duplicate',
  };
}

SyncStatus syncStatusFromSql(String? value) {
  return switch (value) {
    'synced' => SyncStatus.synced,
    'pending' => SyncStatus.pending,
    'conflict' => SyncStatus.conflict,
    _ => SyncStatus.localOnly,
  };
}

TransactionEntity transactionFromRow(QueryRow row) {
  final currency = row.read<String>('currency');
  final accountId = row.readNullable<String>('account_id');
  final merchantId = row.readNullable<String>('merchant_id');
  final rawMerchant = row.readNullable<String>('raw_merchant');
  final categoryId = row.readNullable<String>('category_id');
  final type = row.read<String>('type');
  final source = row.read<String>('source');
  final cardLast4 = row.readNullable<String>('card_last4');
  final note = row.readNullable<String>('note');
  final occurredAt = row.read<String>('occurred_at');
  final rawMessage = row.read<String>('raw_message');
  final parseConfidence = row.read<double>('parse_confidence');
  final status = row.read<String>('status');
  final createdAt = row.read<String>('created_at');
  final updatedAt = row.read<String>('updated_at');
  final foreignCurrency = row.readNullable<String>('foreign_currency');
  final hasForeignAmount = row.readNullable<double>('foreign_amount') != null;
  if (hasForeignAmount != (foreignCurrency != null)) {
    throw StateError(
        'foreign_amount and foreign_currency must be stored together');
  }
  final direction = row.readNullable<String>('direction');
  final transactionTimeFromSms =
      row.readNullable<String>('transaction_time_from_sms');
  final smsReceivedAt = row.readNullable<String>('sms_received_at');
  final comparisonTimestamp = row.readNullable<String>('comparison_timestamp');
  final comparisonTimestampSource =
      row.readNullable<String>('comparison_timestamp_source');
  final duplicateStatus = row.readNullable<String>('duplicate_status');
  final possibleDuplicateOfTransactionId =
      row.readNullable<String>('possible_duplicate_of_transaction_id');
  final duplicateReason = row.readNullable<String>('duplicate_reason');
  final serverId = row.readNullable<String>('server_id');
  final syncedAt = row.readNullable<String>('synced_at');
  final serverUpdatedAt = row.readNullable<String>('server_updated_at');
  final syncStatus = row.readNullable<String>('sync_status');
  final categoryProvenance = row.data.containsKey('category_source')
      ? categoryProvenanceFromSql(row.readNullable<String>('category_source'))
      : null;
  final importedFromFile = row.data.containsKey('imported_from_file') &&
      (row.readNullable<int>('imported_from_file') ?? 0) == 1;
  return TransactionEntity(
    categoryProvenance: categoryProvenance,
    importedFromFile: importedFromFile,
    id: row.read<String>('id'),
    amountMoney: kMoneyCodec.readColumn(row, 'amount', currency),
    currency: currency,
    accountId: accountId,
    merchantId: merchantId,
    rawMerchant: rawMerchant,
    categoryId: categoryId,
    type: transactionTypeFromSql(type),
    source: transactionSourceFromSql(source),
    cardLast4: cardLast4,
    balanceAfterMoney:
        kMoneyCodec.readColumnNullable(row, 'balance_after', currency),
    note: note,
    occurredAt: dateTimeFromSql(occurredAt),
    rawMessage: rawMessage,
    parseConfidence: parseConfidence,
    status: transactionStatusFromSql(status),
    createdAt: dateTimeFromSql(createdAt),
    updatedAt: dateTimeFromSql(updatedAt),
    foreignMoney: foreignCurrency == null
        ? null
        : kMoneyCodec.readColumnNullable(
            row, 'foreign_amount', foreignCurrency),
    foreignCurrency: foreignCurrency,
    direction: transactionDirectionFromSql(direction),
    transactionTimeFromSms: transactionTimeFromSms == null
        ? null
        : dateTimeFromSql(transactionTimeFromSms),
    smsReceivedAt:
        smsReceivedAt == null ? null : dateTimeFromSql(smsReceivedAt),
    comparisonTimestamp: comparisonTimestamp == null
        ? null
        : dateTimeFromSql(comparisonTimestamp),
    comparisonTimestampSource:
        comparisonTimestampSourceFromSql(comparisonTimestampSource),
    duplicateStatus: duplicateStatusFromSql(duplicateStatus),
    possibleDuplicateOfTransactionId: possibleDuplicateOfTransactionId,
    duplicateReason: duplicateReason,
    serverId: serverId,
    syncedAt: syncedAt == null ? null : dateTimeFromSql(syncedAt),
    serverUpdatedAt:
        serverUpdatedAt == null ? null : dateTimeFromSql(serverUpdatedAt),
    syncStatus: syncStatusFromSql(syncStatus),
  );
}

/// MALI-026 (B8-3 §8) — P3 CANONICAL budget mapper. The row's `currency` is the
/// authority; money is read from the `_minor` columns (via the v30 codec — a NULL
/// required minor throws, never a REAL fallback). Only ever called in canonical
/// state; in P1 the repository refuses before mapping.
BudgetEntity budgetFromRow(QueryRow row) {
  final currency = row.read<String>('currency');
  final period = row.read<String>('period');
  final startDate = row.read<String>('start_date');
  return BudgetEntity(
    id: row.read<String>('id'),
    categoryId: row.read<String>('category_id'),
    currency: currency,
    amountMoney: kMoneyCodec.readColumn(row, 'amount', currency),
    lastNotifiedSpentMoney:
        kMoneyCodec.readColumn(row, 'last_notified_spent_amount', currency),
    period: budgetPeriodFromSql(period),
    startDate: dateTimeFromSql(startDate),
    isActive: sqlToBool(row.read<int>('is_active')),
    lastNotifiedPeriodStart: dateTimeFromSql(
        row.readNullable<String>('last_notified_period_start') ??
            '2000-01-01T00:00:00Z'),
    showOnHeader: sqlToBool(row.readNullable<int>('show_on_header') ?? 0),
    accountId: row.readNullable<String>('account_id'),
    // `readNullable` + normalize: a row written by an older build has no such
    // column, and a row that arrived from a server or a backup could carry any
    // integer. Normalizing on the way out means the rest of the app only ever
    // sees a threshold the form could have produced.
    alertThresholdPercent: BudgetEntity.normalizeAlertThreshold(
      row.readNullable<int>('alert_threshold_percent') ??
          BudgetEntity.defaultAlertThresholdPercent,
    ),
  );
}

/// MALI-026 (B8-3 §8) — P3 CANONICAL goal mapper (row.currency + `_minor`).
GoalEntity goalFromRow(QueryRow row) {
  final currency = row.read<String>('currency');
  final deadlineValue = row.readNullable<String>('deadline');
  final autoSaveLastRun = row.readNullable<String>('auto_save_last_run');
  return GoalEntity(
    id: row.read<String>('id'),
    name: row.read<String>('name'),
    accountId: row.readNullable<String>('account_id'),
    currency: currency,
    targetMoney: kMoneyCodec.readColumn(row, 'target_amount', currency),
    savedMoney: kMoneyCodec.readColumn(row, 'saved_amount', currency),
    lastNotifiedSavedMoney:
        kMoneyCodec.readColumn(row, 'last_notified_saved_amount', currency),
    deadline: deadlineValue == null ? null : dateTimeFromSql(deadlineValue),
    vaultSkin: row.read<String>('vault_skin'),
    status: row.read<String>('status'),
    createdAt: dateTimeFromSql(row.read<String>('created_at')),
    autoSaveMoney:
        kMoneyCodec.readColumnNullable(row, 'auto_save_amount', currency),
    autoSavePeriod: row.readNullable<String>('auto_save_period'),
    autoSaveLastRun:
        autoSaveLastRun == null ? null : dateTimeFromSql(autoSaveLastRun),
  );
}

/// MALI-026 (B8-3 §14) — P3 CANONICAL contribution mapper. A contribution has NO
/// own currency; its Money currency is the PARENT GOAL's [goalCurrency], resolved
/// by a JOIN in the caller (no N+1). Money is read from `amount_minor`.
GoalContributionEntity goalContributionFromRow(QueryRow row, String goalCurrency) {
  final createdAt = row.read<String>('created_at');
  return GoalContributionEntity(
    id: row.read<String>('id'),
    goalId: row.read<String>('goal_id'),
    amountMoney: kMoneyCodec.readColumn(row, 'amount', goalCurrency),
    createdAt: dateTimeFromSql(createdAt),
    note: row.readNullable<String>('note'),
  );
}

AchievementEntity achievementFromRow(QueryRow row) {
  final unlockedAt = row.readNullable<String>('unlocked_at');
  return AchievementEntity(
    id: row.read<String>('id'),
    key: row.read<String>('key'),
    nameAr: row.read<String>('name_ar'),
    unlockedAt: unlockedAt == null ? null : dateTimeFromSql(unlockedAt),
    progress: row.read<double>('progress'),
  );
}

StreakEntity streakFromRow(QueryRow row) {
  return StreakEntity(
    id: row.read<String>('id'),
    currentStreak: row.read<int>('current_streak'),
    longestStreak: row.read<int>('longest_streak'),
    lastActiveDate: dateTimeFromSql(row.read<String>('last_active_date')),
    freezesAvailable: row.read<int>('freezes_available'),
  );
}

XpLevelEntity xpLevelFromRow(QueryRow row) {
  return XpLevelEntity(
    id: row.read<String>('id'),
    totalXp: row.read<int>('total_xp'),
    level: row.read<int>('level'),
    levelKey: row.read<String>('level_key'),
  );
}

/// MALI-059n: read the versioned tri-state consent value. NULL (or anything
/// unexpected) maps to `unset`, which is treated as OFF everywhere — fail closed.
ConsentState _consentStateFromRow(QueryRow row, String column) {
  switch (row.readNullable<String>(column)) {
    case 'accepted':
      return ConsentState.accepted;
    case 'declined':
      return ConsentState.declined;
    default:
      return ConsentState.unset;
  }
}

DateTime? _consentAtFromRow(QueryRow row, String column) {
  final raw = row.readNullable<String>(column);
  return raw == null ? null : dateTimeFromSql(raw);
}

UserSettingsEntity userSettingsFromRow(QueryRow row) {
  final dateOfBirth = row.readNullable<String>('date_of_birth');
  return UserSettingsEntity(
    id: row.read<String>('id'),
    displayName: row.readNullable<String>('display_name'),
    phoneNumber: row.readNullable<String>('phone_number'),
    avatarPath: row.readNullable<String>('avatar_path'),
    dateOfBirth: dateOfBirth == null ? null : dateTimeFromSql(dateOfBirth),
    country: row.read<String>('country'),
    currency: row.read<String>('currency'),
    language: row.read<String>('language'),
    theme: row.read<String>('theme'),
    inputMethod: row.read<String>('input_method'),
    notificationsJson: row.read<String>('notifications_json'),
    // MALI-058n — the deprecated key column is never surfaced into app memory;
    // the entity always sees ''. The SQLCipher key comes only from secure storage.
    dbEncryptionKeyRef: '',
    privacyModeEnabled: sqlToBool(row.read<int>('privacy_mode_enabled')),
    // Read defensively: a row written before v34 has no such column on an
    // older database file, and a missing local preference must read as OFF
    // rather than crash the settings load.
    merchantPersonalizationEnabled:
        sqlToBool(row.readNullable<int>('merchant_personalization_enabled') ?? 0),
    // MALI-059n: consent is the persisted, versioned choice — no runtime clamp.
    // An unset/declined state means the cloud/AI gates fail closed.
    cloudConsentState: _consentStateFromRow(row, 'cloud_consent_state'),
    aiConsentState: _consentStateFromRow(row, 'ai_consent_state'),
    cloudConsentVersion: row.readNullable<int>('cloud_consent_version') ?? 0,
    cloudConsentAt: _consentAtFromRow(row, 'cloud_consent_at'),
    aiConsentVersion: row.readNullable<int>('ai_consent_version') ?? 0,
    aiConsentAt: _consentAtFromRow(row, 'ai_consent_at'),
  );
}
