import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/services/duplicate_transaction_detector.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';

/// Returns a fixed result, or runs the REAL ParserEngine when [fixed] is null.
class FakeParserIsolate extends ParserIsolate {
  const FakeParserIsolate([this.fixed]);
  final ParseResult? fixed;

  @override
  Future<ParseResult?> parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    List<CatalogParserRule> catalogRules = const [],
    String defaultCurrency = 'SAR',
  }) async =>
      fixed ??
      const ParserEngine().parse(rawText,
          senderId: senderId, defaultCurrency: defaultCurrency);
}

class StoringTransactionRepo implements TransactionRepository {
  final Map<String, TransactionEntity> byId = {};
  int saveCount = 0;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    String? categoryKey,
    String? resolvedCategoryId,
  }) async {
    saveCount++;
    byId[transaction.id] = transaction;
    return transaction;
  }

  @override
  Future<TransactionEntity?> getById(String id) async => byId[id];

  @override
  Future<TransactionEntity?> findDuplicate({
    required Money amount,
    required String rawMerchant,
    required DateTime occurredAt,
  }) async =>
      null;

  @override
  Future<TransactionEntity?> findSuspiciousDuplicate({
    required Money amount,
    required String currency,
    required String merchantOrDescription,
    String? cardLast4,
    required DateTime comparisonTimestamp,
  }) async {
    final result = const DuplicateTransactionDetector().detect(
      input: DuplicateTransactionInput(
        amount: amount,
        currency: currency,
        merchantOrDescription: merchantOrDescription,
        cardLast4: cardLast4,
        comparisonTimestamp: comparisonTimestamp,
        comparisonTimestampSource: ComparisonTimestampSource.receivedAt,
      ),
      existingTransactions: byId.values,
    );
    return result.existing;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Every merchant is NEW to the user.
class NewMerchantRepo implements MerchantCategoryRepository {
  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async =>
      null;

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => false;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class MemoryDedupStore implements DedupStore {
  final Map<String, String> hashes = {};

  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      hashes[hash];

  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {
    hashes[hash] = transactionId;
  }
}

AccountEntity homeAccount(String currency) => AccountEntity(
      id: 'home-acc',
      name: 'home',
      currency: currency,
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

class SingleAccountRepo implements AccountRepository {
  SingleAccountRepo(this._default);
  final AccountEntity _default;
  final List<AccountEntity> created = [];

  @override
  Future<AccountEntity?> getDefault() async => _default;

  @override
  Future<List<AccountEntity>> getAll() async => [_default, ...created];

  @override
  Future<AccountEntity?> getById(String id) async => id == _default.id
      ? _default
      : created.where((a) => a.id == id).firstOrNull;

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    final made = AccountEntity(
      id: 'auto-${account.currency}',
      name: account.name,
      currency: account.currency,
      type: account.type,
      isDefault: account.isDefault,
      sortOrder: account.sortOrder,
      createdAt: account.createdAt,
      updatedAt: account.updatedAt,
    );
    created.add(made);
    return made;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class CountingAiClient implements AiParserClient {
  CountingAiClient([this.response]);
  final AiParseResponse? response;
  int callCount = 0;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    callCount++;
    return response;
  }
}
