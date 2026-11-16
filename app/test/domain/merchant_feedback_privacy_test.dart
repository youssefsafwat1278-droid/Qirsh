import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';

// ── Stub helpers ─────────────────────────────────────────────────────────────

/// Injects a pre-built ParseResult instead of running the real isolate.
class _FakeParserIsolate extends ParserIsolate {
  const _FakeParserIsolate(this._result);
  final ParseResult _result;

  @override
  Future<ParseResult?> parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    List<CatalogParserRule> catalogRules = const [],
    String defaultCurrency = 'SAR',
  }) async =>
      _result;
}

final _now = DateTime.utc(2026, 6, 16, 12, 0, 0);

TransactionEntity _stubEntity({
  required double amount,
  String merchant = 'TEST',
}) =>
    TransactionEntity(
      id: 'test-id',
      amountMoney: Money.fromLegacyReal(amount, 'SAR'),
      currency: 'SAR',
      type: TransactionTypeEntity.payment,
      source: TransactionSourceEntity.bank,
      occurredAt: _now,
      rawMessage: 'raw',
      parseConfidence: 0.75,
      status: TransactionStatus.pending,
      createdAt: _now,
      updatedAt: _now,
      rawMerchant: merchant,
    );

/// Minimal stubs — only the methods `AddTransactionUseCase` actually calls.
class _StubTransactionRepo implements TransactionRepository {
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
  }) async =>
      null;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    String? resolvedCategoryId,
  }) async =>
      transaction;

  @override
  Future<TransactionEntity?> getById(String id) async => null;

  @override
  Future<TransactionEntity> confirm(String id) async => _stubEntity(amount: 0);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMerchantRepo implements MerchantCategoryRepository {
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

/// No-op dedup store — always says "not a duplicate".
class _NoDedupStore implements DedupStore {
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      null;
  @override
  Future<void> mark(String hash,
      {required String transactionId, required DateTime occurredAt}) async {}
}

AddTransactionUseCase _makeUseCase({
  required ParsedTransaction parsedTxn,
  required List<String> recorded,
}) {
  final result = ParseResult.success(parsedTxn);
  return AddTransactionUseCase(
    transactionRepository: _StubTransactionRepo(),
    merchantCategoryRepository: _StubMerchantRepo(),
    parserIsolate: _FakeParserIsolate(result),
    dedupStore: _NoDedupStore(),
    noteMerchantFeedback: (keyword) async => recorded.add(keyword),
  );
}

// ── Tests ─────────────────────────────────────────────────────────────────────

void main() {
  group('merchant feedback privacy — type gating', () {
    // ── REQUIRED TEST 1: transfer beneficiary NOT recorded ────────────────
    test(
      'uncategorized transfer beneficiary is NOT recorded in pending_merchant_feedback',
      () async {
        final recorded = <String>[];
        final useCase = _makeUseCase(
          parsedTxn: ParsedTransaction(
            amountText: '500',
            amount: 500.0,
            currency: 'SAR',
            type: TransactionType.transfer, // ← transfer type
            source: TransactionSource.bank,
            rawMerchant: 'SARRAA ALASMARI', // ← real person name as merchant
            occurredAt: _now,
            parseConfidence: 0.75,
          ),
          recorded: recorded,
        );

        await useCase(rawMessage: 'dummy');

        expect(recorded, isEmpty,
            reason: 'Transfer beneficiary names must never enter the feedback '
                'loop — they are real people, not businesses');
      },
    );

    // ── REQUIRED TEST 2: uncategorized purchase merchant IS recorded ──────
    test(
      'uncategorized purchase/POS merchant IS recorded for admin review',
      () async {
        final recorded = <String>[];
        final useCase = _makeUseCase(
          parsedTxn: ParsedTransaction(
            amountText: '45',
            amount: 45.0,
            currency: 'SAR',
            type: TransactionType.payment, // ← POS/payment type
            source: TransactionSource.bank,
            rawMerchant:
                'HALA BOUTIQUE XYZ 123', // ← business name, truly not in seeds
            occurredAt: _now,
            parseConfidence: 0.75,
          ),
          recorded: recorded,
        );

        await useCase(rawMessage: 'dummy');

        expect(recorded, isNotEmpty,
            reason: 'Uncategorized payment merchants should be recorded '
                'so admins can add them to the remote catalog');
        // Normalization strips digits and collapses spaces
        expect(recorded.first, equals('HALA BOUTIQUE XYZ'),
            reason: 'Normalized form has digits stripped');
      },
    );

    // ── Income type (salary sender) also excluded ─────────────────────────
    test(
      'income-type transaction with uncategorized sender is NOT recorded',
      () async {
        final recorded = <String>[];
        final useCase = _makeUseCase(
          parsedTxn: ParsedTransaction(
            amountText: '8500',
            amount: 8500.0,
            currency: 'SAR',
            type: TransactionType.income, // ← income
            source: TransactionSource.bank,
            rawMerchant: 'MOHAMMED ALGHAMDI', // ← could be a person
            occurredAt: _now,
            parseConfidence: 0.75,
          ),
          recorded: recorded,
        );

        await useCase(rawMessage: 'dummy');

        expect(recorded, isEmpty,
            reason: 'Income senders may be individuals (salary payments) '
                'and must not enter the feedback loop');
      },
    );

    // ── Unknown type also excluded ────────────────────────────────────────
    test(
      'unknown-type transaction with merchant is NOT recorded',
      () async {
        final recorded = <String>[];
        final useCase = _makeUseCase(
          parsedTxn: ParsedTransaction(
            amountText: '100',
            amount: 100.0,
            currency: 'SAR',
            type: TransactionType.unknown,
            source: TransactionSource.bank,
            rawMerchant: 'SOME ENTITY',
            occurredAt: _now,
            parseConfidence: 0.35,
          ),
          recorded: recorded,
        );

        await useCase(rawMessage: 'dummy');

        expect(recorded, isEmpty,
            reason: 'Unknown type could be anything — excluded for safety');
      },
    );

    // ── Refund type IS recorded (business refund, not a person) ──────────
    test(
      'refund-type with uncategorized merchant IS recorded',
      () async {
        final recorded = <String>[];
        final useCase = _makeUseCase(
          parsedTxn: ParsedTransaction(
            amountText: '30',
            amount: 30.0,
            currency: 'SAR',
            type: TransactionType.refund,
            source: TransactionSource.bank,
            rawMerchant: 'NEW BOUTIQUE STORE', // business refund
            occurredAt: _now,
            parseConfidence: 0.75,
          ),
          recorded: recorded,
        );

        await useCase(rawMessage: 'dummy');

        expect(recorded, isNotEmpty,
            reason: 'Refunds come from businesses, not individuals');
      },
    );
  });
}
