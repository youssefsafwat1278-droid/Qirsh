import '../finance/money.dart';

enum TransactionTypeEntity {
  payment,
  withdrawal,
  transfer,
  refund,
  income,
  unknown,
}

enum TransactionSourceEntity {
  bank,
  card,
  wallet,
  unknown,
  aiParsed,
  imported,
}

enum TransactionStatus { confirmed, pending, ignored }

enum TransactionDirectionEntity { credit, debit, unknown }

enum ComparisonTimestampSource { smsBody, receivedAt }

enum DuplicateStatus { normal, suspiciousDuplicate }

/// Pricing is a separate axis from [TransactionStatus]: a foreign-currency
/// spend parked with amount 0 is CONFIRMED and merely awaits a home value.
enum TransactionPricingState { priced, awaitingFx }

enum SyncStatus { localOnly, synced, pending, conflict }

/// Who chose a transaction's CATEGORY (stored as `transactions.category_source`
/// and synced as `user_transactions.category_source`). It is the one thing
/// "also update past transactions" reads to decide what it may change:
///   * [auto]    — the engine categorised it at capture; a rule may change it.
///   * [rule]    — a confirmed merchant rule set it; a newer rule may change it.
///   * [user]    — the user picked it by hand; never changed by default.
///   * [unknown] — history that predates this field, an imported file, or a
///                 change made by an older app version; never changed by default.
/// Only an explicit category choice writes [user]; editing the note, amount,
/// date or account never touches it.
enum CategoryProvenance { auto, rule, user, unknown }

CategoryProvenance categoryProvenanceFromSql(String? value) =>
    CategoryProvenance.values.firstWhere((v) => v.name == value,
        orElse: () => CategoryProvenance.unknown);

class TransactionEntity {
  TransactionEntity({
    required this.id,
    required this.amountMoney,
    required this.currency,
    required this.type,
    required this.source,
    required this.occurredAt,
    required this.rawMessage,
    required this.parseConfidence,
    required this.status,
    required this.createdAt,
    required this.updatedAt,
    this.merchantId,
    this.rawMerchant,
    this.categoryId,
    this.cardLast4,
    this.balanceAfterMoney,
    this.note,
    this.accountId,
    this.foreignMoney,
    this.foreignCurrency,
    this.direction,
    this.transactionTimeFromSms,
    this.smsReceivedAt,
    this.comparisonTimestamp,
    this.comparisonTimestampSource = ComparisonTimestampSource.receivedAt,
    this.duplicateStatus = DuplicateStatus.normal,
    this.possibleDuplicateOfTransactionId,
    this.duplicateReason,
    this.serverId,
    this.syncedAt,
    this.serverUpdatedAt,
    this.syncStatus = SyncStatus.localOnly,
    this.categoryProvenance,
    this.importedFromFile = false,
    this.transferGroupId,
  })  : assert((foreignMoney == null) == (foreignCurrency == null)),
        assert(foreignMoney == null ||
            foreignMoney.currency == foreignCurrency!.trim().toUpperCase());

  final String id;
  final Money amountMoney;
  final String currency;
  final String? accountId;
  final String? merchantId;
  final String? rawMerchant;
  final String? categoryId;
  final TransactionTypeEntity type;
  final TransactionSourceEntity source;
  final String? cardLast4;
  final Money? balanceAfterMoney;
  final String? note;
  final DateTime occurredAt;
  final String rawMessage;
  final double parseConfidence;
  final TransactionStatus status;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Money? foreignMoney;
  final String? foreignCurrency;
  final TransactionDirectionEntity? direction;
  final DateTime? transactionTimeFromSms;
  final DateTime? smsReceivedAt;
  final DateTime? comparisonTimestamp;
  final ComparisonTimestampSource comparisonTimestampSource;
  final DuplicateStatus duplicateStatus;
  final String? possibleDuplicateOfTransactionId;
  final String? duplicateReason;
  final String? serverId;
  final DateTime? syncedAt;
  final DateTime? serverUpdatedAt;
  final SyncStatus syncStatus;

  /// Null only on an entity that was never stored (a fresh capture or a pulled
  /// row before saving): the repository then derives it from [source].
  final CategoryProvenance? categoryProvenance;

  /// Came in through a file import. Recorded on its own, separately from
  /// [source] (which keeps the original bank/SMS/manual origin) and from
  /// [categoryProvenance]; once set it is never cleared. Imported rows are
  /// excluded from bulk category updates unless the user opts in to them.
  final bool importedFromFile;

  /// Shared by the two legs of a transfer between the user's own accounts
  /// (debit on From, credit on To). Local only; null for every other row.
  final String? transferGroupId;

  /// DISPLAY-ONLY compatibility getters. Never use these as a persistence,
  /// calculation, comparison, validation, dedup-input, or transport source.
  double get amount => amountMoney.toDouble();
  double? get balanceAfter => balanceAfterMoney?.toDouble();
  double? get foreignAmount => foreignMoney?.toDouble();

  /// Derived, never stored: amount 0 with a foreign amount means the home-currency
  /// value has not been entered yet.
  TransactionPricingState get pricingState =>
      amountMoney.isZero && foreignMoney != null
          ? TransactionPricingState.awaitingFx
          : TransactionPricingState.priced;

  TransactionEntity copyWith({
    String? id,
    Money? amountMoney,
    String? currency,
    String? accountId,
    String? merchantId,
    String? rawMerchant,
    String? categoryId,
    TransactionTypeEntity? type,
    TransactionSourceEntity? source,
    String? cardLast4,
    Money? balanceAfterMoney,
    String? note,
    DateTime? occurredAt,
    String? rawMessage,
    double? parseConfidence,
    TransactionStatus? status,
    DateTime? createdAt,
    DateTime? updatedAt,
    Money? foreignMoney,
    String? foreignCurrency,
    TransactionDirectionEntity? direction,
    DateTime? transactionTimeFromSms,
    DateTime? smsReceivedAt,
    DateTime? comparisonTimestamp,
    ComparisonTimestampSource? comparisonTimestampSource,
    DuplicateStatus? duplicateStatus,
    String? possibleDuplicateOfTransactionId,
    String? duplicateReason,
    String? serverId,
    DateTime? syncedAt,
    DateTime? serverUpdatedAt,
    SyncStatus? syncStatus,
    CategoryProvenance? categoryProvenance,
    bool? importedFromFile,
    String? transferGroupId,
  }) {
    return TransactionEntity(
      id: id ?? this.id,
      amountMoney: amountMoney ?? this.amountMoney,
      currency: currency ?? this.currency,
      accountId: accountId ?? this.accountId,
      merchantId: merchantId ?? this.merchantId,
      rawMerchant: rawMerchant ?? this.rawMerchant,
      categoryId: categoryId ?? this.categoryId,
      type: type ?? this.type,
      source: source ?? this.source,
      cardLast4: cardLast4 ?? this.cardLast4,
      balanceAfterMoney: balanceAfterMoney ?? this.balanceAfterMoney,
      note: note ?? this.note,
      occurredAt: occurredAt ?? this.occurredAt,
      rawMessage: rawMessage ?? this.rawMessage,
      parseConfidence: parseConfidence ?? this.parseConfidence,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      foreignMoney: foreignMoney ?? this.foreignMoney,
      foreignCurrency: foreignCurrency ?? this.foreignCurrency,
      direction: direction ?? this.direction,
      transactionTimeFromSms:
          transactionTimeFromSms ?? this.transactionTimeFromSms,
      smsReceivedAt: smsReceivedAt ?? this.smsReceivedAt,
      comparisonTimestamp: comparisonTimestamp ?? this.comparisonTimestamp,
      comparisonTimestampSource:
          comparisonTimestampSource ?? this.comparisonTimestampSource,
      duplicateStatus: duplicateStatus ?? this.duplicateStatus,
      possibleDuplicateOfTransactionId: possibleDuplicateOfTransactionId ??
          this.possibleDuplicateOfTransactionId,
      duplicateReason: duplicateReason ?? this.duplicateReason,
      serverId: serverId ?? this.serverId,
      syncedAt: syncedAt ?? this.syncedAt,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      syncStatus: syncStatus ?? this.syncStatus,
      categoryProvenance: categoryProvenance ?? this.categoryProvenance,
      importedFromFile: importedFromFile ?? this.importedFromFile,
      transferGroupId: transferGroupId ?? this.transferGroupId,
    );
  }
}

class MerchantEntity {
  const MerchantEntity({
    required this.id,
    required this.rawName,
    required this.normalizedName,
    required this.firstSeenAt,
    required this.lastSeenAt,
  });

  final String id;
  final String rawName;
  final String normalizedName;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
}

class MerchantCategoryMappingEntity {
  const MerchantCategoryMappingEntity({
    required this.id,
    required this.merchantId,
    required this.categoryId,
    required this.isUserConfirmed,
    required this.confidence,
    required this.updatedAt,
  });

  final String id;
  final String merchantId;
  final String categoryId;
  final bool isUserConfirmed;
  final double confidence;
  final DateTime updatedAt;
}
