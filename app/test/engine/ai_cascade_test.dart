import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/repositories/dedup_store.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/domain/services/duplicate_transaction_detector.dart';
import 'package:money_companion/domain/capture/proof_commit_gate.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/resolve_bank_for_sender_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';
import 'package:money_companion/engine/parser/catalog_rule_matcher.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_isolate.dart';
import 'package:money_companion/domain/entities/sender_bank_mapping_entity.dart';

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
  Future<TransactionEntity> confirm(String id) async =>
      throw UnimplementedError();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CapturingTransactionRepo extends _StubTransactionRepo {
  _CapturingTransactionRepo({required this.onSave, this.onSaveCategory});

  final void Function(TransactionEntity transaction) onSave;
  final void Function(String? categoryKey)? onSaveCategory;

  @override
  Future<TransactionEntity> saveTransaction({
    required TransactionEntity transaction,
    required String? categoryKey,
    String? resolvedCategoryId,
  }) async {
    onSave(transaction);
    onSaveCategory?.call(categoryKey);
    return transaction;
  }
}

class _StubMerchantRepo implements MerchantCategoryRepository {
  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async => null;

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => false;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _StubMerchantRepoWithKnownMerchant implements MerchantCategoryRepository {
  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async => null;

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async => true;

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async =>
      {'STARBUCKS': 'restaurants'};

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A merchant repo whose learned map AND user-confirmed rules are given.
/// [learned] models the whole map (seed rows included); [confirmed] only the
/// rows the user confirmed — exactly the split `merchant_category_map` keeps.
class _RulesMerchantRepo implements MerchantCategoryRepository {
  _RulesMerchantRepo({this.learned = const {}, this.confirmed = const {}});

  final Map<String, String> learned;
  final Map<String, String> confirmed;

  @override
  Future<String?> userConfirmedCategoryFor(String rawMerchant) async =>
      confirmed[rawMerchant.toUpperCase()];

  @override
  Future<bool> hasCategoryForMerchant(String rawMerchant) async =>
      learned.containsKey(rawMerchant.toUpperCase());

  @override
  Future<Map<String, String>> getLearnedCategoryMap() async => learned;

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
}

/// Account repo with a single default account in [_default]'s currency. Used to
/// give the use case a "home currency" so foreign spends can be relocated.
class _SingleAccountRepo implements AccountRepository {
  _SingleAccountRepo(this._default);
  final AccountEntity _default;
  final List<AccountEntity> _created = [];
  List<AccountEntity> get created => _created;

  @override
  Future<AccountEntity?> getDefault() async => _default;

  @override
  Future<List<AccountEntity>> getAll() async => [_default, ..._created];

  @override
  Future<AccountEntity?> getById(String id) async {
    if (id == _default.id) return _default;
    return _created.where((a) => a.id == id).firstOrNull;
  }

  @override
  Future<AccountEntity> create(AccountEntity account) async {
    final created = AccountEntity(
      id: 'auto-${account.currency}',
      name: account.name,
      currency: account.currency,
      type: account.type,
      isDefault: account.isDefault,
      sortOrder: account.sortOrder,
      createdAt: account.createdAt,
      updatedAt: account.updatedAt,
    );
    _created.add(created);
    return created;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stores saved transactions by id so dedup (which re-reads via getById) works
/// realistically, and counts saves to catch double-counting.
class _StoringTransactionRepo implements TransactionRepository {
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

class _MemoryDedupStore implements DedupStore {
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
}

class _CapturingAiClient implements AiParserClient {
  _CapturingAiClient({required this.onParse, this.response});

  final void Function(String sanitizedSms, String senderId, String installId)
      onParse;
  final AiParseResponse? response;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    onParse(sanitizedSms, senderId, installId);
    return response;
  }
}

class _FixedResponseAiClient implements AiParserClient {
  const _FixedResponseAiClient(this.response);

  final AiParseResponse response;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async =>
      response;
}

class _ThrowingAiClient implements AiParserClient {
  const _ThrowingAiClient(this.reason);

  final String reason;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    throw AiParseException(reason);
  }
}

class _SingleSenderMappingRepository implements SenderBankMappingRepository {
  const _SingleSenderMappingRepository(this.mapping);

  final SenderBankMappingEntity? mapping;

  @override
  Future<SenderBankMappingEntity?> getBySender(String senderId) async {
    if (mapping == null) return null;
    return senderId.trim().toLowerCase() ==
            mapping!.senderId.trim().toLowerCase()
        ? mapping
        : null;
  }

  @override
  Future<SenderBankMappingEntity?> getConfirmedBySender(String senderId) async {
    final value = await getBySender(senderId);
    return value?.status == SenderBankMappingStatus.confirmed ? value : null;
  }

  @override
  Future<SenderBankMappingEntity?> getActiveSuggestionBySender(
    String senderId, {
    DateTime? now,
  }) async =>
      getBySender(senderId);

  @override
  Future<bool> suppressesDiscoveryPrompt(
    String senderId, {
    DateTime? now,
  }) async {
    final value = await getBySender(senderId);
    return value?.suppressesDiscovery(now ?? DateTime.now().toUtc()) ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUp(() {
    AiSenderFailureTracker.instance.resetForTest();
  });

  test('a confident local parse still consults AI', () async {
    // A resolved bank and high confidence do not bypass consented AI.
    final countingClient = _CountingAiClient();
    final fakeParsed = ParsedTransaction(
      amountText: '500',
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    final fakeParseResult = ParseResult.success(fakeParsed, bankKey: 'alrajhi');

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
      resolveBankForSenderUseCase: const ResolveBankForSenderUseCase(
        mappingRepository: _SingleSenderMappingRepository(null),
      ),
    );
    await useCase(rawMessage: 'dummy');

    expect(countingClient.callCount, 1);
  });

  test('temporarily blocked AI keeps a locally readable message for review',
      () async {
    final client = _CountingAiClient();
    final local = ParsedTransaction(
      amountText: '250',
      amount: 250,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 11, 6),
      parseConfidence: 0.95,
    );
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) => fail('AI-selected capture must not save a local result'),
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(local)),
      aiPrimarySelected: () async => true,
      loadAiConsent: () async => false,
      aiClient: client,
    );

    final result = await useCase(
      rawMessage: 'Purchase EGP 250 at STARBUCKS',
      senderId: 'QNB',
    );

    expect(client.callCount, 0);
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.droppedByParser, isTrue);
  });

  test(
      'over-precision capture token is retained only as pending legacy fallback',
      () async {
    final fakeParsed = ParsedTransaction(
      amountText: '1.234',
      amount: 1.234,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
          onSave: (transaction) => saved = transaction),
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );

    await useCase(rawMessage: 'Purchase SAR 1.234 At STARBUCKS');

    expect(saved, isNotNull);
    expect(saved!.amountMoney, Money.parse('1.23', 'SAR'));
    expect(saved!.status, TransactionStatus.pending);
  });

  test('unsupported-bank generic parse still consults AI', () async {
    // A missing AI result preserves the local parse (pending).
    final countingClient = _CountingAiClient();
    TransactionEntity? savedTransaction;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => savedTransaction = t,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    await useCase(
      rawMessage: 'Trx. of AED 50.00 on your a/c ****0535 at ABU DHABI '
          'NATIONAL OIL ABU DHABI AE. Avl Bal is AED 12956.50',
      senderId: 'ADIB',
    );

    expect(countingClient.callCount, 1);
    expect(savedTransaction, isNotNull);
    expect(savedTransaction!.amount, 50.00);
    expect(savedTransaction!.currency, 'AED');
    expect(savedTransaction!.rawMerchant, 'ABU DHABI NATIONAL OIL');
    expect(savedTransaction!.balanceAfter, 12956.50);
    expect(savedTransaction!.status, TransactionStatus.pending);
  });

  test('sender-bank mapping does not bypass AI', () async {
    // Use a sender NOT in BankProfiles.all so the mapping-based resolution fires.
    const unknownSender = 'GULFCORP-XYZ';
    final countingClient = _CountingAiClient();
    final now = DateTime.utc(2026, 6, 16, 12, 0, 0);
    final mapping = SenderBankMappingEntity(
      id: 'mapping-gulfcorp',
      senderId: unknownSender,
      normalizedSenderId: unknownSender.toUpperCase(),
      bankKey: 'dubai_bank',
      suggestedBankName: 'Unknown Gulf Bank',
      suggestedCountry: 'AE',
      confidence: 0.98,
      status: SenderBankMappingStatus.confirmed,
      source: SenderBankMappingSource.userManual,
      firstSeenAt: now,
      lastSeenAt: now,
      confirmedAt: now,
      rejectedAt: null,
      rejectionExpiresAt: null,
      createdAt: now,
      updatedAt: now,
      syncedAt: null,
      syncStatus: SenderBankMappingSyncStatus.pending,
    );
    final fakeParsed = ParsedTransaction(
      amountText: '50',
      amount: 50.0,
      currency: 'AED',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'MERCHANT STORE',
      occurredAt: now,
      parseConfidence: 0.50,
    );
    final fakeParseResult =
        ParseResult.success(fakeParsed, bankKey: 'dubai_bank');

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
      resolveBankForSenderUseCase: ResolveBankForSenderUseCase(
        mappingRepository: _SingleSenderMappingRepository(mapping),
      ),
    );

    final result = await useCase(
      rawMessage: 'Trx. of AED 50.00 on your a/c ****0535 at MERCHANT STORE.',
      senderId: unknownSender,
    );

    expect(countingClient.callCount, 1);
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction?.status, TransactionStatus.pending);
  });

  test('transfer to AI: beneficiary name absent in outgoing payload', () async {
    String? capturedSanitized;
    const rawTransferSms = 'تم تحويل مبلغ 200.00 ريال إلى: سارة العمري';
    // Local parse fails, so the message reaches the AI (sanitized).
    final fakeParseResult = ParseResult.notTransaction();
    final capturingClient = _CapturingAiClient(
      onParse: (s, _, __) => capturedSanitized = s,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: capturingClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawTransferSms);

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(capturedSanitized, isNull);
  });

  test('AI fabricated amount is ignored while the local parse is saved',
      () async {
    const rawSms = 'خصم 200.00 ريال من حسابك';
    final fakeParsed = ParsedTransaction(
      amountText: '200',
      amount: 200.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: null,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.50,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const lyingClient = _FixedResponseAiClient(AiParseResponse(
      amount: 999.99,
      amountText: '999.99',
      currency: 'SAR',
      type: 'payment',
    ));

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: lyingClient,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(rawMessage: rawSms);

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 200.0);
    expect(saved!.source, TransactionSourceEntity.bank);
  });

  test('AI grounded but mismatched amount is ignored for IPN transfer sent',
      () async {
    const rawSms =
        'IPN transfer sent with amount of EGP 31.43 from 1938 on 15/03 '
        'at 02:18 PM. Ref# 22762b03. For more details call 16607';
    final fakeParsed = ParsedTransaction(
      amountText: '31.43',
      amount: 31.43,
      currency: 'EGP',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      rawMerchant: null,
      parseConfidence: 0.95,
    );
    final fakeParseResult =
        ParseResult.success(fakeParsed, bankKey: 'instapay_eg');
    const confusedAiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 1938.0,
      amountText: '1938.0',
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
    ));

    TransactionEntity? saved;
    String? savedCategory;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => saved = t,
      onSaveCategory: (category) => savedCategory = category,
    );

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: confusedAiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'IPN');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amount, 31.43);
    // Outgoing transfer → counts as an expense (payment), shown under transfers.
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(savedCategory, 'transfers');
  });

  test('transfer person name from AI is not treated as merchant or place',
      () async {
    const rawSms =
        'Transfer sent with amount of EGP 250.00 to Ahmed Hassan on 08/06';
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 250,
      amountText: '250',
      currency: 'EGP',
      type: 'transfer',
      merchantName: 'Ahmed Hassan',
      categoryKey: 'other',
      direction: 'debit',
    ));
    TransactionEntity? saved;
    String? savedCategory;
    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (_) async {
        mapsLookupCount++;
        return 'shopping';
      },
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(saved, isNull);
    expect(savedCategory, isNull);
    expect(mapsLookupCount, 0);
  });

  test('IPN credited from a person counts as income, name dropped', () async {
    const rawSms =
        'Your account was credited by EGP 2000 on 14-06 23:10 IPN REF# '
        '92420545267 from **نبيل نصير عبدالسيد ميخائ for details please call 19342.';
    final aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 2000,
      amountText: '2000',
      currency: 'EGP',
      type: 'income',
      merchantName: 'نبيل نصير عبدالسيد ميخائ',
      categoryKey: 'income',
      direction: 'credit',
      occurredAt: DateTime(2026, 6, 14, 23, 10),
    ));
    TransactionEntity? saved;
    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    // The AI date must fall inside the plausibility window around the capture's
    // receivedAt, so pin receivedAt instead of relying on the wall clock.
    final result = await useCase(
      rawMessage: rawSms,
      senderId: 'IPN',
      smsReceivedAt: DateTime.utc(2026, 6, 15),
    );

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(saved, isNull);
    expect(savedCategory, isNull);
  });

  test('same-amount transfers with different references are not duplicates',
      () async {
    final dedup = _MemoryDedupStore();
    final repo = _CapturingTransactionRepo(onSave: (_) {});
    AddTransactionUseCase buildUseCase(String rawSms) {
      return AddTransactionUseCase(
        transactionRepository: repo,
        merchantCategoryRepository: _StubMerchantRepo(),
        parserIsolate: _FakeParserIsolate(ParseResult.success(
          ParsedTransaction(
            amountText: '9000',
            amount: 9000,
            currency: 'EGP',
            type: TransactionType.transfer,
            source: TransactionSource.aiParsed,
            parseConfidence: 0.79,
          ),
        )),
        loadAiConsent: () async => false,
        dedupStore: dedup,
      );
    }

    const first = 'تم إضافة تحويل لحظي بمبلغ 9000.00 جم رقم مرجعي 111 يوم 06';
    const second = 'تم إضافة تحويل لحظي بمبلغ 9000.00 جم رقم مرجعي 222 يوم 06';

    final firstResult = await buildUseCase(first).call(rawMessage: first);
    final secondResult = await buildUseCase(second).call(rawMessage: second);

    expect(firstResult.outcome, AddTransactionOutcome.added);
    expect(secondResult.outcome, AddTransactionOutcome.added);
  });

  test('AI null on an Arabic transfer SMS saves nothing (no last-resort row)',
      () async {
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
          onSave: (transaction) => saved = transaction),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );
    const rawSms = 'تم إضافة تحويل لحظي لبطاقتكم مسبقة الدفع بمبلغ 9000.00 جم '
        'رقم مرجعي 743706614607 يوم 06 الساعة 13:29';

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(saved, isNull);
  });

  test('AI category wins over the merchant keyword category', () async {
    const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
    final fakeParseResult = ParseResult.notTransaction();
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 85.0,
      amountText: '85.0',
      currency: 'EGP',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'shopping',
    ));

    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(savedCategory, 'shopping');
  });

  // Learned rules vs the AI's category: a rule the user confirmed wins, then a
  // shared-learning mapping for the exact merchant; the catalog seed and
  // non-shared keywords do not; with neither the AI category is used.
  RemoteMerchantKeyword kw(String keyword, String category, int priority) =>
      RemoteMerchantKeyword(
        id: 'kw-$keyword-$priority',
        keyword: keyword,
        categoryKey: category,
        language: 'any',
        countryCode: 'ALL',
        priority: priority,
        isActive: true,
        isDeleted: false,
        updatedAt: '2026-11-16T00:00:00Z',
      );
  for (final (label, repo, expected, keywords) in [
    (
      'a user-confirmed rule beats the AI category',
      _RulesMerchantRepo(
        learned: {'STARBUCKS': 'restaurants'},
        confirmed: {'STARBUCKS': 'restaurants'},
      ),
      'restaurants',
      <RemoteMerchantKeyword>[],
    ),
    (
      'a seed-only mapping does not beat the AI category',
      _RulesMerchantRepo(learned: {'STARBUCKS': 'cafes'}),
      'shopping',
      <RemoteMerchantKeyword>[],
    ),
    (
      'with no rule the AI category is used',
      _RulesMerchantRepo(),
      'shopping',
      <RemoteMerchantKeyword>[],
    ),
    (
      'a shared-learning mapping for the exact merchant beats the AI category',
      _RulesMerchantRepo(),
      'cafes',
      [kw('STARBUCKS', 'cafes', 1000)],
    ),
    (
      'a user-confirmed rule beats a shared mapping and the AI category',
      _RulesMerchantRepo(
        learned: {'STARBUCKS': 'restaurants'},
        confirmed: {'STARBUCKS': 'restaurants'},
      ),
      'restaurants',
      [kw('STARBUCKS', 'cafes', 1000)],
    ),
    (
      'a non-shared keyword (curated / Places) does not beat the AI category',
      _RulesMerchantRepo(),
      'shopping',
      [kw('STARBUCKS', 'cafes', 0)],
    ),
    (
      'a shared mapping matching only a substring does not beat the AI',
      _RulesMerchantRepo(),
      'shopping',
      [kw('STAR', 'cafes', 1000), kw('STARBUCKS COFFEE', 'cafes', 1000)],
    ),
  ]) {
    test(label, () async {
      const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
      String? savedCategory;
      final useCase = AddTransactionUseCase(
        transactionRepository: _CapturingTransactionRepo(
          onSave: (_) {},
          onSaveCategory: (category) => savedCategory = category,
        ),
        merchantCategoryRepository: repo,
        loadRemoteKeywords: () async => keywords,
        parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
        loadAiConsent: () async => true,
        aiClient: const _FixedResponseAiClient(AiParseResponse(
          amount: 85.0,
          amountText: '85.0',
          currency: 'EGP',
          type: 'payment',
          merchantName: 'STARBUCKS',
          categoryKey: 'shopping',
        )),
        dedupStore: _NoDedupStore(),
      );

      final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

      expect(result.outcome, AddTransactionOutcome.added);
      expect(savedCategory, expected);
    });
  }

  test('AI runs on a valid local parse and its category and type win',
      () async {
    const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
    final localParse = ParseResult.success(
      ParsedTransaction(
        amountText: '85.00',
        amount: 85.0,
        currency: 'EGP',
        type: TransactionType.withdrawal,
        source: TransactionSource.bank,
        rawMerchant: 'STARBUCKS',
        parseConfidence: 0.95,
      ),
      bankKey: 'cib',
    );
    var aiCalls = 0;
    final aiClient = _CapturingAiClient(
      onParse: (_, __, ___) => aiCalls++,
      response: const AiParseResponse(
        amount: 85.0,
        amountText: '85.00',
        currency: 'EGP',
        type: 'payment',
        merchantName: 'STARBUCKS',
        categoryKey: 'shopping',
      ),
    );

    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(localParse),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: rawSms,
      senderId: 'CIB',
    );

    expect(aiCalls, 1);
    expect(result.outcome, AddTransactionOutcome.added);
    expect(savedCategory, 'shopping');
    expect(result.transaction?.type, TransactionTypeEntity.payment);
    expect(result.transaction?.source, TransactionSourceEntity.aiParsed);
  });

  test('on-device-only capture never invokes AI despite consent', () async {
    final ai = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: ai,
      dedupStore: _NoDedupStore(),
    );
    await useCase(
        rawMessage: 'Purchase EGP 56.78 at Orange', onDeviceOnly: true);
    expect(ai.callCount, 0);
  });

  test(
      'unknown sender with previous failures still gets sanitized AI categorization',
      () async {
    const sender = 'UNKNOWN';
    for (var i = 0; i < 3; i++) {
      AiSenderFailureTracker.instance.recordFailure(sender);
    }
    var calls = 0;
    String? category;
    final ai = _CapturingAiClient(
      onParse: (sms, _, __) {
        calls++;
        expect(sms, isNot(contains('4111111111115398')));
        expect(sms, contains('56.78'));
      },
      response: const AiParseResponse(
          amount: 56.78,
          amountText: '56.78',
          currency: 'EGP',
          type: 'payment',
          categoryKey: 'bills',
          merchantName: 'Orange - Home Internet'),
    );
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
          onSave: (_) {}, onSaveCategory: (value) => category = value),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: ai,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(
        rawMessage:
            'Purchase EGP 56.78 at Orange - Home Internet with card 4111111111115398',
        senderId: sender);
    expect(calls, 1);
    expect(result.outcome, AddTransactionOutcome.added);
    expect(category, 'bills');
  });

  test('valid local parse with consent off makes zero AI calls', () async {
    final countingClient = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(
        ParsedTransaction(
          amountText: '500',
          amount: 500.0,
          currency: 'SAR',
          type: TransactionType.payment,
          source: TransactionSource.bank,
          rawMerchant: 'STARBUCKS',
          parseConfidence: 0.95,
        ),
        bankKey: 'alrajhi',
      )),
      loadAiConsent: () async => false,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    await useCase(rawMessage: 'dummy');
    expect(countingClient.callCount, 0);
  });

  test('validated AI-only transaction is confirmed even for a new merchant',
      () async {
    const rawSms = 'خصم 150.00 ريال من حسابك في مطعم البيك';
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 150.0,
      amountText: '150.00',
      currency: 'SAR',
      type: 'payment',
      merchantName: 'البيك',
    ));

    TransactionEntity? savedTransaction;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (t) => savedTransaction = t,
      ),
      // hasCategoryForMerchant == false: the merchant is new.
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(rawMessage: rawSms, senderId: 'SABB');

    expect(savedTransaction, isNotNull);
    expect(savedTransaction!.status, TransactionStatus.confirmed);
    expect(savedTransaction!.source, TransactionSourceEntity.aiParsed);
    expect(result.isNewMerchant, isFalse);
    expect(result.requiresConfirmation, isFalse);
  });

  test('consent off → zero AI calls regardless of trigger conditions',
      () async {
    final countingClient = _CountingAiClient();
    final fakeParsed = ParsedTransaction(
      amountText: '300',
      amount: 300.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: null,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.40,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);

    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => false,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'dummy 300.00 SAR');

    expect(
      countingClient.callCount,
      0,
      reason: 'AI must never be called when user has not granted consent',
    );
  });

  test('AI is skipped for locally ignored messages (OTP, promo, etc.)',
      () async {
    final countingClient = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'رمز التحقق الخاص بك هو 123456 ولا تشاركه مع أحد',
      senderId: 'BANKOTP',
    );

    // OTP messages are ignored by the local parser → AI must not be called.
    expect(countingClient.callCount, 0);
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.droppedByParser, isFalse);
  });

  test('manual paste empty sender is never suppressed after AI failures',
      () async {
    const rawSms =
        'IPN transfer sent with amount of EGP 31.43 from 1938 on 15/03 '
        'at 02:18 PM. Ref# 22762b03. For more details call 16607';
    AiSenderFailureTracker.instance.recordFailure('');
    AiSenderFailureTracker.instance.recordFailure('');
    AiSenderFailureTracker.instance.recordFailure('');

    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 31.43,
      amountText: '31.43',
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
      direction: 'debit',
    ));
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository:
          _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(saved, isNull);
  });

  test('AI failure reason is surfaced when parser also fails', () async {
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: const _ThrowingAiClient('http_429:rate_limit_exceeded'),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: 'رسالة بنك غامضة بدون مبلغ');

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.aiFailureReason, 'http_429:rate_limit_exceeded');
  });

  test('AI null response is treated as a soft miss, not a visible failure',
      () async {
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: 'رسالة بنك غامضة بدون مبلغ');

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.aiFailureReason, isNull);
  });

  test('AI null on an amount+currency message saves nothing (no last resort)',
      () async {
    TransactionEntity? saved;
    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (transaction) => saved = transaction,
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: _CountingAiClient(),
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'Purchase EGP 40.00 At RANDOM SHOP on 08/06 at 06:55 AM',
      senderId: 'CIB',
    );

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(saved, isNull);
    expect(savedCategory, isNull);
  });

  test(
      'validated AI-only result (category + grounded direction) is confirmed '
      'for a known merchant', () async {
    const rawSms = 'خصم 150.00 ريال من حسابك في ستاربكس';
    final fakeParseResult = ParseResult.notTransaction();
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 150.0,
      amountText: '150.00',
      currency: 'SAR',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'restaurants',
    ));

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawSms);

    expect(saved, isNotNull);
    expect(saved!.status, TransactionStatus.confirmed);
    expect(saved!.source, TransactionSourceEntity.aiParsed);
  });

  test('validated AI category and type win over ATM inference and Maps',
      () async {
    const rawSms =
        'Your Debit Card **5398 had a Successful transaction of EGP 200.00 '
        '@BDC OROBA,your available bal.EGP1204.74 for lost/stolen card call '
        '16607.';
    final fakeParsed = ParsedTransaction(
      amountText: '200',
      amount: 200.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'BDC OROBA',
      parseConfidence: 0.79,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 200.0,
      amountText: '200.0',
      currency: 'EGP',
      type: 'payment',
      merchantName: 'BDC OROBA',
      categoryKey: 'other',
    ));

    TransactionEntity? saved;
    String? savedCategory;
    final capturingRepo = _CapturingTransactionRepo(
      onSave: (t) => saved = t,
      onSaveCategory: (category) => savedCategory = category,
    );

    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      mayEnrichMerchant: () async => true,
      resolveMerchantCategory: (merchant) async {
        mapsLookupCount++;
        expect(merchant, 'BDC OROBA');
        return 'cash';
      },
    );
    await useCase(rawMessage: rawSms, senderId: 'BDC');

    expect(mapsLookupCount, 0);
    expect(savedCategory, 'other');
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(saved!.status, TransactionStatus.confirmed);
  });

  test('validated AI other remains authoritative over Maps', () async {
    const rawSms = 'Purchase EGP 85.00 At STARBUCKS on 08/06 at 06:55 AM';
    final fakeParseResult = ParseResult.notTransaction();
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 85.0,
      amountText: '85.0',
      currency: 'EGP',
      type: 'payment',
      merchantName: 'STARBUCKS',
      categoryKey: 'other',
    ));

    String? savedCategory;
    var mapsLookupCount = 0;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      mayEnrichMerchant: () async => true,
      resolveMerchantCategory: (merchant) async {
        mapsLookupCount++;
        expect(merchant, 'STARBUCKS');
        return 'cafes';
      },
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(mapsLookupCount, 0);
    expect(savedCategory, 'other');
  });

  test('validated AI other is retained without speculative categorization',
      () async {
    const rawSms = 'Purchase EGP 40.00 At RANDOM SHOP on 08/06 at 06:55 AM';
    final fakeParsed = ParsedTransaction(
      amountText: '40',
      amount: 40.0,
      currency: 'EGP',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'RANDOM SHOP',
      parseConfidence: 0.79,
    );
    final fakeParseResult = ParseResult.success(fakeParsed);
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 40.0,
      amountText: '40.0',
      currency: 'EGP',
      type: 'payment',
      merchantName: 'RANDOM SHOP',
      categoryKey: 'other',
    ));

    String? savedCategory;
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(
        onSave: (_) {},
        onSaveCategory: (category) => savedCategory = category,
      ),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
      resolveMerchantCategory: (_) async => 'other',
    );

    final result = await useCase(rawMessage: rawSms, senderId: 'CIB');

    expect(result.outcome, AddTransactionOutcome.added);
    expect(savedCategory, 'other');
    expect(result.requiresConfirmation, isFalse);
  });

  group('merchant enrichment consent gate', () {
    Future<({int calls, String? category, AddTransactionResult result})> run({
      Future<bool> Function()? consent,
      bool hasConsentCallback = true,
      bool onDeviceOnly = false,
      Future<String?> Function()? resolve,
    }) async {
      final parsed = ParsedTransaction(
        amountText: '40',
        amount: 40.0,
        currency: 'EGP',
        type: TransactionType.payment,
        source: TransactionSource.bank,
        rawMerchant: 'RANDOM SHOP',
        parseConfidence: 0.79,
      );
      const aiClient = _FixedResponseAiClient(AiParseResponse(
        amount: 40.0,
        amountText: '40.0',
        currency: 'EGP',
        type: 'payment',
        merchantName: 'RANDOM SHOP',
      ));
      var calls = 0;
      String? savedCategory;
      TransactionEntity? saved;
      final useCase = AddTransactionUseCase(
        transactionRepository: _CapturingTransactionRepo(
          onSave: (t) => saved = t,
          onSaveCategory: (category) => savedCategory = category,
        ),
        merchantCategoryRepository: _StubMerchantRepo(),
        parserIsolate: _FakeParserIsolate(ParseResult.success(parsed)),
        loadAiConsent: () async => true,
        aiClient: aiClient,
        dedupStore: _NoDedupStore(),
        resolveMerchantCategory: (_) async {
          calls++;
          return resolve != null ? resolve() : 'cafes';
        },
        mayEnrichMerchant: hasConsentCallback ? consent : null,
      );
      final result = await useCase(
        rawMessage: 'Purchase EGP 40.00 At RANDOM SHOP on 08/06',
        senderId: 'CIB',
        onDeviceOnly: onDeviceOnly,
      );
      expect(saved, isNotNull);
      return (calls: calls, category: savedCategory, result: result);
    }

    test('consent OFF: resolver not called, transaction saved', () async {
      final r = await run(consent: () async => false);
      expect(r.calls, 0);
      expect(r.category, 'shopping');
    });

    test('callback absent: fails closed', () async {
      final r = await run(hasConsentCallback: false);
      expect(r.calls, 0);
      expect(r.category, 'shopping');
    });

    test('callback throws: fails closed, transaction saved', () async {
      final r = await run(consent: () async => throw StateError('boom'));
      expect(r.calls, 0);
      expect(r.category, 'shopping');
    });

    test('consent ON: resolver runs once and its category is applied',
        () async {
      final r = await run(consent: () async => true);
      expect(r.calls, 1);
      expect(r.category, 'cafes');
    });

    test('consent ON + resolver throws: saved with fallback category',
        () async {
      final r = await run(
        consent: () async => true,
        resolve: () async => throw StateError('network'),
      );
      expect(r.calls, 1);
      expect(r.category, 'shopping');
    });

    test('onDeviceOnly + consent ON: resolver not called', () async {
      final r = await run(consent: () async => true, onDeviceOnly: true);
      expect(r.calls, 0);
      expect(r.category, 'shopping');
    });
  });

  test(
      'AI rescue: a bank-like message the parser dropped is recovered as '
      'a confirmed transaction', () async {
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 75.0,
      amountText: '75.00',
      currency: 'SAR',
      type: 'payment',
      merchantName: 'NOON',
      categoryKey: 'shopping',
    ));
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح',
      senderId: 'SABB',
    );

    expect(result.outcome, AddTransactionOutcome.added);
    expect(saved, isNotNull);
    expect(saved!.amountMoney, Money.parse('75.00', 'SAR'));
    expect(saved!.amount, 75.0);
    expect(saved!.status, TransactionStatus.confirmed);
    expect(result.requiresConfirmation, isFalse);
    expect(saved!.source, TransactionSourceEntity.aiParsed);
  });

  test(
      'AI rescue: manual IPN transfer paste uses lazy install id and saves '
      'an incoming transfer as income', () async {
    const rawSms =
        'IPN transfer received with amount of EGP 10.00 on 1938 on 08/06 '
        'at 06:55 AM. Ref# db8a9b1e. For more details call 16607';
    String? seenInstallId;
    final aiClient = _CapturingAiClient(
      onParse: (sms, sender, installId) => seenInstallId = installId,
      response: const AiParseResponse(
        amount: 10.0,
        amountText: '10.0',
        currency: 'EGP',
        type: 'income',
        categoryKey: 'transfers',
        direction: 'credit',
      ),
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      loadInstallId: () async => 'lazy-install-id',
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(seenInstallId, isNull);
    expect(saved, isNull);
  });

  test('AI rescue: without consent a dropped message stays notTransaction',
      () async {
    final countingClient = _CountingAiClient();
    final useCase = AddTransactionUseCase(
      transactionRepository: _StubTransactionRepo(),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => false,
      aiClient: countingClient,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(
      rawMessage: 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح',
      senderId: 'SABB',
    );

    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(countingClient.callCount, 0);
  });

  test('incoming external transfer counts as income (money received)',
      () async {
    final fakeParsed = ParsedTransaction(
      amountText: '500',
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'حوالة واردة بمبلغ 500 ريال إلى حسابك');

    // Money received from outside is income (counts toward income totals).
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.income);
  });

  test('foreign purchase + fee/tax line is saved as two transactions',
      () async {
    const rawSms = 'شراء إنترنت\n'
        'بطاقة:7640; urpay بطاقة;\n'
        'مبلغ:99 USD\n'
        'الرسوم/الضريبة:SAR 7.44\n'
        'من:APPLE.CO..\n'
        '24-6-2026 11:42';
    final fakeParsed = ParsedTransaction(
      amountText: '99',
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    final saves = <TransactionEntity>[];
    final useCase = AddTransactionUseCase(
      transactionRepository: _CapturingTransactionRepo(onSave: saves.add),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );

    final result = await useCase(rawMessage: rawSms);

    // Main purchase (foreign currency).
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction!.amount, 99.0);
    expect(result.transaction!.currency, 'USD');
    // Fee/tax surfaced as a separate transaction in the local currency.
    expect(result.secondary, isNotNull);
    expect(result.secondary!.outcome, AddTransactionOutcome.added);
    expect(
        result.secondary!.transaction!.amountMoney, Money.parse('7.44', 'SAR'));
    expect(result.secondary!.transaction!.amount, 7.44);
    expect(result.secondary!.transaction!.currency, 'SAR');
    expect(result.secondary!.transaction!.type, TransactionTypeEntity.payment);
    expect(saves.length, 2);
  });

  test(
      'foreign currency SMS auto-creates an account in that currency '
      'and saves the transaction there', () async {
    final fakeParsed = ParsedTransaction(
      amountText: '99',
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final repo = _SingleAccountRepo(_homeAccount('SAR'));
    final useCase = AddTransactionUseCase(
      transactionRepository:
          _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
      accountRepository: repo,
    );

    await useCase(rawMessage: 'شراء إنترنت مبلغ:99 USD من:APPLE.CO');

    expect(saved, isNotNull);
    // Transaction is stored in a newly created USD account with real amount.
    expect(saved!.currency, 'USD');
    expect(saved!.amount, 99.0);
    expect(saved!.accountId, 'auto-USD');
    expect(saved!.foreignAmount, isNull);
    // Auto-created account → one extra account was created.
    expect(repo.created, hasLength(1));
    expect(repo.created.first.currency, 'USD');
  });

  test('foreign purchase + fee processed twice does NOT double-count',
      () async {
    final fakeParsed = ParsedTransaction(
      amountText: '99',
      amount: 99.0,
      currency: 'USD',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: 'APPLE.CO',
      cardLast4: '7640',
      parseConfidence: 0.95,
    );
    const sms = 'شراء إنترنت\n'
        'بطاقة:7640; urpay بطاقة;\n'
        'مبلغ:99 USD\n'
        'الرسوم/الضريبة:SAR 7.44\n'
        'من:APPLE.CO..\n'
        '24-6-2026 11:42';
    final repo = _StoringTransactionRepo();
    final dedup = _MemoryDedupStore();
    AddTransactionUseCase build() => AddTransactionUseCase(
          transactionRepository: repo,
          merchantCategoryRepository: _StubMerchantRepo(),
          parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
          loadAiConsent: () async => false,
          dedupStore: dedup,
          accountRepository: _SingleAccountRepo(_homeAccount('SAR')),
        );

    await build()(rawMessage: sms);
    // SMS has SAR fee → foreignUnpriced: purchase parked as SAR 0 + fee SAR 7.44.
    expect(repo.saveCount, 2);
    final unpricedPurchase = repo.byId.values.singleWhere(
      (transaction) => transaction.amountMoney.isZero,
    );
    expect(unpricedPurchase.amountMoney, Money.zero('SAR'));
    expect(unpricedPurchase.foreignMoney, Money.parse('99', 'USD'));
    expect(unpricedPurchase.foreignCurrency, 'USD');

    final second = await build()(rawMessage: sms);
    // Re-processing the same SMS adds nothing.
    expect(repo.saveCount, 2);
    expect(second.outcome, AddTransactionOutcome.suspiciousDuplicate);

    final sarAmounts = repo.byId.values
        .where((t) => t.currency == 'SAR')
        .map((t) => t.amount)
        .toList()
      ..sort();
    expect(sarAmounts, [0.0, 7.44]);
  });

  test('internal own-account transfer stays neutral (excluded from totals)',
      () async {
    final fakeParsed = ParsedTransaction(
      amountText: '500',
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تم تحويل داخلي بمبلغ 500 ريال بين حساباتك');

    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.transfer);
    // Round 5 (owner decision): a notice with no completed form and no
    // stated flow is kept for review (decided locally, never by the model).
    saved = null;
    await useCase(rawMessage: 'تحويل داخلي بمبلغ 500 ريال بين حساباتك');
    expect(saved, isNull);
  });

  // Round 3 closure (owner brief §5; parser meaning gate in the use case):
  // an ATM cash deposit is not proven income or a transfer — it is held for
  // review (Smart Inbox, reason cash_deposit), never booked from a local
  // reading. (Was: booked as a transfer.)
  test('ATM cash deposit (withdrawal-typed + إيداع wording) is held for review',
      () async {
    final fakeParsed = ParsedTransaction(
      amountText: '300',
      amount: 300.0,
      currency: 'SAR',
      type: TransactionType.withdrawal,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    final result = await useCase(
        rawMessage: 'إيداع نقدي بمبلغ 300 ريال في حسابك عبر الصراف');

    expect(saved, isNull);
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.droppedByParser, isTrue);
    expect(result.reviewReason, 'cash_deposit');
  });

  test('outgoing external transfer counts as expense (money sent)', () async {
    final fakeParsed = ParsedTransaction(
      amountText: '500',
      amount: 500.0,
      currency: 'SAR',
      type: TransactionType.transfer,
      source: TransactionSource.bank,
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);
    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.success(fakeParsed)),
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تم تحويل 500 ريال إلى أحمد');

    // Money sent outside is an expense (payment type → counts in spend totals),
    // beneficiary name dropped for privacy.
    expect(saved, isNotNull);
    expect(saved!.type, TransactionTypeEntity.payment);
    expect(saved!.rawMerchant, isNull);
  });

  test('AI credit direction wins: incoming transfer is income, not expense',
      () async {
    // The wording alone is ambiguous (DirectionSignal can't tell), but the AI
    // says credit. The classified TYPE must agree with the stored direction so
    // the amount lands in income — never in the expense total with a green "+".
    const aiClient = _FixedResponseAiClient(AiParseResponse(
      amount: 750.0,
      amountText: '750.0',
      currency: 'EGP',
      type: 'transfer',
      categoryKey: 'transfers',
      direction: 'credit',
    ));
    TransactionEntity? saved;
    final useCase = AddTransactionUseCase(
      transactionRepository:
          _CapturingTransactionRepo(onSave: (t) => saved = t),
      merchantCategoryRepository: _StubMerchantRepo(),
      parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
      loadAiConsent: () async => true,
      aiClient: aiClient,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: 'تحويل 750 جنيه');

    // Round 5 (owner decision): a transfer to or from a person never goes to
    // the model; the device's own reading decides it (here none: review).
    expect(saved, isNull);
  });

  test('direction contradiction forces pending even at high confidence',
      () async {
    // Text clearly says money came IN (إيداع/راتب) but the type was classified
    // as a payment (money out). Even with a 0.95 on-device confidence and a
    // known merchant, this must route to pending.
    const rawSms = 'تم إيداع راتب 5000.00 ريال في حسابك';
    final fakeParsed = ParsedTransaction(
      amountText: '5000',
      amount: 5000.0,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.bank,
      rawMerchant: 'STARBUCKS',
      occurredAt: DateTime.utc(2026, 6, 16, 12, 0, 0),
      parseConfidence: 0.95,
    );
    final fakeParseResult = ParseResult.success(fakeParsed, bankKey: 'alrajhi');

    TransactionEntity? saved;
    final capturingRepo = _CapturingTransactionRepo(onSave: (t) => saved = t);

    final useCase = AddTransactionUseCase(
      transactionRepository: capturingRepo,
      merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
      parserIsolate: _FakeParserIsolate(fakeParseResult),
      // Consent off so the on-device parse (not AI) is what we are grounding.
      loadAiConsent: () async => false,
      dedupStore: _NoDedupStore(),
    );
    await useCase(rawMessage: rawSms);

    expect(saved, isNotNull);
    expect(saved!.status, TransactionStatus.pending);
  });

  group('always-consult AI and deterministic validation', () {
    ParsedTransaction local(double confidence) => ParsedTransaction(
          amountText: '125.75',
          amount: 125.75,
          currency: 'SAR',
          type: TransactionType.payment,
          source: TransactionSource.bank,
          rawMerchant: 'STARBUCKS',
          occurredAt: DateTime.utc(2026, 6, 16, 12),
          parseConfidence: confidence,
        );

    AddTransactionUseCase build({
      required ParseResult parse,
      required AiParserClient ai,
      bool consent = true,
      void Function(TransactionEntity)? onSave,
    }) =>
        AddTransactionUseCase(
          transactionRepository:
              _CapturingTransactionRepo(onSave: onSave ?? (_) {}),
          merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
          parserIsolate: _FakeParserIsolate(parse),
          loadAiConsent: () async => consent,
          aiClient: ai,
          dedupStore: _NoDedupStore(),
        );

    setUp(() => AiSenderFailureTracker.instance.resetForTest());

    test('locally confident message reaches the AI client', () async {
      final ai = _CountingAiClient();
      final result = await build(
        parse: ParseResult.success(local(0.95), bankKey: 'alrajhi'),
        ai: ai,
      )(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');
      expect(result.outcome, AddTransactionOutcome.added);
      expect(ai.callCount, 1);
    });

    test('a local transaction without a resolved bank consults AI', () async {
      final ai = _CountingAiClient();
      await build(parse: ParseResult.success(local(0.95)), ai: ai)(
        rawMessage: 'شراء 125.75 ر.س',
        senderId: 'NEWBANK',
      );
      expect(ai.callCount, 1);
    });

    test('a low-confidence local transaction consults AI', () async {
      final ai = _CountingAiClient();
      TransactionEntity? saved;
      await build(
        parse: ParseResult.success(local(0.60), bankKey: 'alrajhi'),
        ai: ai,
        onSave: (t) => saved = t,
      )(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');
      expect(ai.callCount, 1);
      // Legacy local behaviour is unchanged: still pending.
      expect(saved!.status, TransactionStatus.pending);
    });

    test('a low-confidence local transaction without a bank consults AI',
        () async {
      final ai = _CountingAiClient();
      await build(parse: ParseResult.success(local(0.30)), ai: ai)(
        rawMessage: 'شراء 125.75 ر.س',
        senderId: 'AlRajhi',
      );
      expect(ai.callCount, 1);
    });

    test('consent off never calls the AI even when local is not confident',
        () async {
      final ai = _CapturingAiClient(
        onParse: (_, __, ___) => fail('AI must not be called'),
      );
      await build(
        parse: ParseResult.success(local(0.60)),
        ai: ai,
        consent: false,
      )(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');
    });

    test('validator rejection writes nothing and keeps droppedByParser',
        () async {
      TransactionEntity? saved;
      final result = await build(
        parse: ParseResult.notTransaction(),
        ai: const _FixedResponseAiClient(
          AiParseResponse(amount: 999, amountText: '999', currency: 'SAR'),
        ),
        onSave: (t) => saved = t,
      )(rawMessage: 'تم خصم مبلغ من حسابك لدى متجر', senderId: 'SABB');
      expect(saved, isNull);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
      expect(result.aiFailureReason, 'ai_response_rejected_by_grounding');
    });

    const smsText = 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح';

    Future<AddTransactionResult> runAi(
      AiParseResponse response, {
      String raw = smsText,
      String sender = 'SABB',
      void Function(TransactionEntity)? onSave,
    }) =>
        build(
          parse: ParseResult.notTransaction(),
          ai: _FixedResponseAiClient(response),
          onSave: onSave,
        )(rawMessage: raw, senderId: sender);

    test('AI-only validated success is confirmed and opens no confirm sheet',
        () async {
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(
          amount: 75,
          amountText: '75',
          currency: 'SAR',
          merchantName: 'نون',
          direction: 'debit',
        ),
        onSave: (t) => saved = t,
      );
      expect(saved!.source, TransactionSourceEntity.aiParsed);
      expect(saved!.status, TransactionStatus.confirmed);
      // The drain opens the confirm sheet only when this getter is true.
      expect(result.requiresConfirmation, isFalse);
    });

    test('AI candidate without amountText is rejected: no transaction',
        () async {
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(amount: 75, currency: 'SAR'),
        onSave: (t) => saved = t,
      );
      expect(saved, isNull);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
    });

    test('AI amount not grounded in the text: no transaction, dropped',
        () async {
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(amount: 76, amountText: '76', currency: 'SAR'),
        onSave: (t) => saved = t,
      );
      expect(saved, isNull);
      expect(result.droppedByParser, isTrue);
    });

    test('AI currency not grounded in the text: no transaction, dropped',
        () async {
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(amount: 75, amountText: '75', currency: 'USD'),
        onSave: (t) => saved = t,
      );
      expect(saved, isNull);
      expect(result.droppedByParser, isTrue);
    });

    test('AI type contradicting the direction wording: no transaction, dropped',
        () async {
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(
          amount: 5000,
          amountText: '5000',
          currency: 'SAR',
          type: 'payment',
        ),
        raw: 'تم إيداع راتب 5000.00 ريال في حسابك',
        onSave: (t) => saved = t,
      );
      expect(saved, isNull);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
    });

    test('AI "not a transaction" (null response): no transaction, dropped',
        () async {
      TransactionEntity? saved;
      final result = await build(
        parse: ParseResult.notTransaction(),
        ai: _CountingAiClient(),
        onSave: (t) => saved = t,
      )(rawMessage: smsText, senderId: 'SABB');
      expect(saved, isNull);
      expect(result.droppedByParser, isTrue);
    });

    test(
        'a rejected AI candidate from a non-bank sender is still surfaced (not silent)',
        () async {
      final result = await runAi(
        const AiParseResponse(amount: 76, amountText: '76', currency: 'SAR'),
        sender: '0501234567',
        raw: 'مشترياتك بقيمة 75 ريال من نون تمت بنجاح',
      );
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      // Transaction-shaped (AI returned a candidate): never acked silently,
      // whatever the sender.
      expect(result.droppedByParser, isTrue);
    });

    test('AI confidence-like metadata has no effect on acceptance or status',
        () async {
      Future<TransactionStatus?> statusFor(
          String? model, String? category) async {
        TransactionEntity? saved;
        await runAi(
          AiParseResponse(
            amount: 75,
            amountText: '75',
            currency: 'SAR',
            merchantName: 'نون',
            direction: 'debit',
            categoryKey: category,
            modelUsed: model,
          ),
          onSave: (t) => saved = t,
        );
        return saved?.status;
      }

      final high = await statusFor('confidence=0.99', 'shopping');
      final low = await statusFor('confidence=0.01', 'other');
      expect(high, TransactionStatus.confirmed);
      expect(low, high);
    });

    test(
        'final type contradicting the wording after reclassification: rejected',
        () async {
      // AI type "transfer" passes the validator (direction-neutral), but the AI
      // direction "debit" reclassifies the external transfer to a payment,
      // which contradicts the "received" wording.
      TransactionEntity? saved;
      final result = await runAi(
        const AiParseResponse(
          amount: 750,
          amountText: '750',
          currency: 'EGP',
          type: 'transfer',
          direction: 'debit',
        ),
        raw: 'received EGP 750.00 from Ali',
        onSave: (t) => saved = t,
      );
      expect(saved, isNull);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
    });

    AddTransactionUseCase armed(
      ParseResult parse,
      AiParserClient ai,
      void Function(TransactionEntity) onSave,
    ) =>
        AddTransactionUseCase(
          transactionRepository: _CapturingTransactionRepo(onSave: onSave),
          merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
          parserIsolate: _FakeParserIsolate(parse),
          loadAiConsent: () async => true,
          aiClient: ai,
          dedupStore: _NoDedupStore(),
          proofGateMode: () => ProofGateMode.armed,
        );

    test('armed proof gate does not withhold a validated AI transaction',
        () async {
      TransactionEntity? saved;
      await armed(
        ParseResult.notTransaction(),
        const _FixedResponseAiClient(AiParseResponse(
          amount: 75,
          amountText: '75',
          currency: 'SAR',
          merchantName: 'نون',
          direction: 'debit',
        )),
        (t) => saved = t,
      )(rawMessage: smsText, senderId: 'SABB');
      expect(saved!.source, TransactionSourceEntity.aiParsed);
      expect(saved!.status, TransactionStatus.confirmed);
    });

    test('armed proof gate still withholds a local parse below 990 permille',
        () async {
      TransactionEntity? saved;
      await armed(
        ParseResult.success(local(0.95), bankKey: 'alrajhi'),
        _CountingAiClient(),
        (t) => saved = t,
      )(rawMessage: 'شراء 125.75 ر.س', senderId: 'AlRajhi');
      expect(saved!.status, TransactionStatus.pending);
    });

    test('a validated AI foreign spend awaiting pricing stays pending',
        () async {
      // Home currency SAR, USD purchase with a SAR fee: the existing
      // "awaiting pricing" rule still wins over an AI-validated capture.
      final saves = <TransactionEntity>[];
      final useCase = AddTransactionUseCase(
        transactionRepository: _CapturingTransactionRepo(
          onSave: saves.add,
        ),
        merchantCategoryRepository: _StubMerchantRepoWithKnownMerchant(),
        parserIsolate: _FakeParserIsolate(ParseResult.notTransaction()),
        loadAiConsent: () async => true,
        aiClient: const _FixedResponseAiClient(AiParseResponse(
          amount: 99,
          amountText: '99',
          currency: 'USD',
          type: 'payment',
          merchantName: 'APPLE.CO..',
        )),
        accountRepository: _SingleAccountRepo(_homeAccount('SAR')),
        dedupStore: _NoDedupStore(),
      );
      await useCase(
        rawMessage: 'مبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE.CO..\n'
            '24-6-2026 11:42',
        senderId: 'SABB',
      );
      final primary = saves.singleWhere((t) => t.amountMoney.isZero);
      expect(primary.status, TransactionStatus.pending);
    });
  });
}
