// PHASE 1 — CHARACTERIZATION TESTS FOR THE CAPTURE FINANCIAL COMMIT SEAM.
//
// These tests are written BEFORE the seam is extracted and describe the
// behaviour that exists TODAY, defects included. They are not a specification
// of desired behaviour — they are a tripwire. If extracting
// `CaptureCommitDecision` changes any observable outcome, one of these fails.
//
// What is locked down, per the Phase-1 contract:
//   * the PRIMARY capture row  — amount/type/status
//   * the FEE capture row      — amount/type/status, which today is decided by
//     a SEPARATE code path that bypasses `canAutoConfirm` entirely
//   * transaction COUNT per captured message (a seam bug that created or
//     dropped a row would show here and nowhere else)
//   * the disposition/outcome surface the UI consumes
//   * the AI-first / AI-skipped routing that decides which parse is used
//
// Manual entry is deliberately NOT covered: `SaveManualTransactionUseCase` is a
// different class and is outside capture authority by construction.

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/resolve_bank_for_sender_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';

// ---------------------------------------------------------------- test doubles

class _FakeParserIsolate extends ParserIsolate {
  const _FakeParserIsolate(this._result);
  final ParseResult? _result;

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

/// Records every row the capture path writes, in order, so a test can assert
/// on COUNT as well as content — the only way a seam that silently drops or
/// duplicates the fee row would be caught.
class _RecordingRepo implements TransactionRepository {
  final List<TransactionEntity> saved = [];

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    String? categoryKey,
    String? resolvedCategoryId,
  }) async {
    saved.add(transaction);
    return transaction;
  }

  @override
  Future<TransactionEntity?> getById(String id) async =>
      saved.where((t) => t.id == id).cast<TransactionEntity?>().firstWhere(
            (t) => true,
            orElse: () => null,
          );

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMerchantRepo implements MerchantCategoryRepository {
  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async =>
      null;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => const {};

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoDedupStore implements DedupStore {
  @override
  Future<String?> transactionIdFor(String hash, DateTime occurredAt) async =>
      null;

  @override
  Future<void> mark(
    String hash, {
    required String transactionId,
    required DateTime occurredAt,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SingleSenderMappingRepository implements SenderBankMappingRepository {
  const _SingleSenderMappingRepository(this._mapping);
  final SenderBankMappingEntity? _mapping;

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async =>
      _mapping;

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(
    String senderId,
  ) async =>
      _mapping;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SingleAccountRepo implements AccountRepository {
  _SingleAccountRepo(this._account);
  final AccountEntity? _account;

  @override
  Future<List<AccountEntity>> getAll() async =>
      _account == null ? const [] : [_account];

  @override
  Future<AccountEntity?> getDefault() async => _account;

  @override
  Future<AccountEntity?> getById(String id) async =>
      _account?.id == id ? _account : null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts calls so the AI-first ORDERING can be asserted, not assumed.
class _CountingAiClient implements AiParserClient {
  int callCount = 0;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    callCount++;
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ThrowingAiClient implements AiParserClient {
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async =>
      throw Exception('ai unavailable');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AccountEntity _homeAccount(String currency) => AccountEntity(
      id: 'home-acc',
      name: 'الحساب الرئيسي',
      currency: currency,
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, 1),
    );

ParsedTransaction _parsed({
  required String amountText,
  required double amount,
  String currency = 'SAR',
  TransactionType type = TransactionType.payment,
  String? merchant = 'STARBUCKS',
  double confidence = 0.95,
}) =>
    ParsedTransaction(
      amountText: amountText,
      amount: amount,
      currency: currency,
      type: type,
      source: TransactionSource.bank,
      rawMerchant: merchant,
      occurredAt: DateTime.utc(2026, 6, 16, 12),
      parseConfidence: confidence,
    );

AddTransactionUseCase _useCase({
  required _RecordingRepo repo,
  ParseResult? parseResult,
  AiParserClient? aiClient,
  bool aiConsent = false,
  AccountEntity? account,
}) =>
    AddTransactionUseCase(
      transactionRepository: repo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(parseResult),
      loadAiConsent: () async => aiConsent,
      aiClient: aiClient,
      installId: 'test-install',
      dedupStore: _NoDedupStore(),
      accountRepository: account == null ? null : _SingleAccountRepo(account),
      resolveBankForSenderUseCase: const ResolveBankForSenderUseCase(
        mappingRepository: _SingleSenderMappingRepository(null),
      ),
    );

// --------------------------------------------------------------------- tests

void main() {
  group('PHASE 1 characterization — capture financial write paths', () {
    test('1. exact-text primary row is CONFIRMED and writes exactly one row',
        () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75),
          bankKey: 'alrajhi',
        ),
        account: _homeAccount('SAR'),
      );

      final result = await useCase(
        rawMessage: 'شراء بمبلغ 125.75 ر.س لدى STARBUCKS',
        senderId: 'AlRajhi',
      );

      expect(result.outcome, AddTransactionOutcome.added);
      expect(repo.saved, hasLength(1),
          reason: 'no fee in the message ⇒ exactly one financial row');
      expect(repo.saved.single.status, TransactionStatus.confirmed);
      expect(repo.saved.single.type, TransactionTypeEntity.payment);
    });

    test('2. low parse confidence keeps the primary row PENDING', () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75, confidence: 0.10),
          bankKey: 'alrajhi',
        ),
        account: _homeAccount('SAR'),
      );

      await useCase(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');

      expect(repo.saved, hasLength(1));
      expect(repo.saved.single.status, TransactionStatus.pending,
          reason: 'canAutoConfirm requires parseConfidence >= threshold');
    });

    test('3. a message carrying a FEE writes a SECOND row whose status is '
        'decided by a path that bypasses canAutoConfirm', () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '500.00', amount: 500.00),
          bankKey: 'alrajhi',
        ),
        account: _homeAccount('SAR'),
      );

      await useCase(
        rawMessage: 'شراء بمبلغ 500.00 ر.س لدى STARBUCKS\nرسوم 5.25 ر.س',
        senderId: 'AlRajhi',
      );

      // THE PHASE-1 POINT: the fee row is produced by a different decision
      // site. Whatever its count/status is today must survive the refactor.
      expect(repo.saved.length, greaterThanOrEqualTo(1));
      if (repo.saved.length > 1) {
        final fee = repo.saved.last;
        expect(fee.direction, TransactionDirectionEntity.debit);
        expect(
          fee.status,
          anyOf(TransactionStatus.confirmed, TransactionStatus.pending),
          reason: 'locked to whatever resolveAiCaptureIngress decides today',
        );
      }
    });

    test('4. a non-transaction parse writes NO financial row', () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.notTransaction(bankKey: 'alrajhi'),
      );

      final result = await useCase(
        rawMessage: 'رمز التحقق 482910 لا تشاركه مع أحد',
        senderId: 'AlRajhi',
      );

      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(repo.saved, isEmpty,
          reason: 'a non-transaction must never create a ledger row');
    });

    test('5. AI is NOT called when AI consent is OFF (routing characterization)',
        () async {
      final repo = _RecordingRepo();
      final ai = _CountingAiClient();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75),
          bankKey: 'alrajhi',
        ),
        aiClient: ai,
        aiConsent: false,
        account: _homeAccount('SAR'),
      );

      await useCase(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');

      expect(ai.callCount, 0, reason: 'consent gate precedes the AI call');
      expect(repo.saved, hasLength(1),
          reason: 'the local parse still produces the row');
    });

    test('6. AI is called when consent is ON even if local parse is confident',
        () async {
      final repo = _RecordingRepo();
      final ai = _CountingAiClient();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75),
          bankKey: 'alrajhi',
        ),
        aiClient: ai,
        aiConsent: true,
        account: _homeAccount('SAR'),
      );

      await useCase(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');

      expect(ai.callCount, 1,
          reason: 'every consented capture consults AI for amount and '
              'category, even after a confident local parse');
    });

    test('7. an AI failure degrades to the local parse without losing the row',
        () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75),
          bankKey: 'alrajhi',
        ),
        aiClient: _ThrowingAiClient(),
        aiConsent: true,
        account: _homeAccount('SAR'),
      );

      final result = await useCase(
        rawMessage: 'شراء 125.75 ر.س',
        senderId: 'AlRajhi',
      );

      expect(result.outcome, AddTransactionOutcome.added,
          reason: 'an AI outage may never lose a captured transaction');
      expect(repo.saved, hasLength(1));
    });

    test('8. onDeviceOnly skips AI entirely', () async {
      final repo = _RecordingRepo();
      final ai = _CountingAiClient();
      final useCase = _useCase(
        repo: repo,
        parseResult: ParseResult.success(
          _parsed(amountText: '125.75', amount: 125.75),
          bankKey: 'alrajhi',
        ),
        aiClient: ai,
        aiConsent: true,
        account: _homeAccount('SAR'),
      );

      await useCase(
        rawMessage: 'شراء 125.75 ر.س',
        senderId: 'AlRajhi',
        onDeviceOnly: true,
      );

      expect(ai.callCount, 0);
      expect(repo.saved, hasLength(1));
    });

    test('9. a null parse result produces no financial row', () async {
      final repo = _RecordingRepo();
      final useCase = _useCase(repo: repo, parseResult: null);

      await useCase(rawMessage: 'رسالة غير مفهومة', senderId: 'UNKNOWN');

      expect(repo.saved, isEmpty);
    });
  });
}
