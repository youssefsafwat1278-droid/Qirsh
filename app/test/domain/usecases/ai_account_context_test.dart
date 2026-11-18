// Owner brief 4.3 / 4.4 through the real AddTransactionUseCase: the local
// reading and the matched account's currency go to the AI as evidence, and a
// message that names no currency is saved in the matched account's currency
// only when exactly one account matches. Real in-memory Drift DB; the AI
// client is a fake returning SYNTHETIC answers.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parse_result.dart';

import '../local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Ai implements PrimaryAiParserClient, ContextualAiParserClient {
  _Ai(this.answer);
  final AiParseResponse? answer;
  AiParseContext? context;
  int calls = 0;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    calls++;
    return answer;
  }

  @override
  Future<AiParseResponse?> parseWithContext({
    required String sanitizedSms,
    required String senderId,
    required String installId,
    required AiParseContext context,
  }) async {
    this.context = context;
    calls++;
    return answer;
  }
}

const _text = 'Purchase of 45.00 at Test Diner from account no 1234';

// The engine reads no currency and fills in the default account's (EGP).
final _defaulted = ParseResult.success(
  ParsedTransaction(
    amountText: '45.00',
    amount: 45,
    currency: 'EGP',
    type: TransactionType.payment,
    source: TransactionSource.bank,
    rawMerchant: 'Test Diner',
    accountNumber: '1234',
    parseConfidence: 0.9,
  ),
  currencyDefaulted: true,
);

const _sarAnswer = AiParseResponse(
  amount: 45,
  amountText: '45.00',
  currency: 'SAR',
  merchantName: 'Test Diner',
  type: 'payment',
  direction: 'debit',
  categoryKey: 'restaurants',
  messageType: 'transaction',
  status: 'completed',
  currencySource: 'account_context',
);

void main() {
  late AppDatabase db;
  late DriftAccountRepository accounts;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    accounts = DriftAccountRepository(db);
  });

  tearDown(() async => db.close());

  Future<AccountEntity> account(String name, String currency,
      {String? number, bool isDefault = false}) {
    final now = DateTime.utc(2026, 1, 1);
    return accounts.create(AccountEntity(
      id: '',
      name: name,
      currency: currency,
      type: AccountType.bank,
      bankAccountNumber: number,
      isDefault: isDefault,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
  }

  AddTransactionUseCase useCase(_Ai ai,
          {bool consent = true, Future<bool> Function()? loadConsent}) =>
      AddTransactionUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: accounts,
        dedupStore: DriftDedupStore(db),
        parserIsolate: FakeParserIsolate(_defaulted),
        aiClient: ai,
        loadAiConsent: loadConsent ?? () async => consent,
        installId: 'install',
      );

  test('one matched account: its currency is sent as context and used',
      () async {
    await account('Main', 'EGP', isDefault: true);
    final sar = await account('Salary', 'SAR', number: '9988771234');
    final ai = _Ai(_sarAnswer);
    final result = await useCase(ai).call(
        rawMessage: _text,
        senderId: 'SNB',
        smsReceivedAt: DateTime.utc(2026, 6, 16, 12));

    expect(ai.context?.accountCurrency, 'SAR');
    // The defaulted EGP is not offered as the local currency.
    expect(ai.context?.localCurrency, isNull);
    expect(ai.context?.localAmountText, '45.00');
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.transaction!.currency, 'SAR');
    expect(result.transaction!.accountId, sar.id);
    expect(result.currencyFromAccount, isTrue);
  });

  test('two accounts with the same ending: no context, the AI currency is a '
      'guess and nothing is saved', () async {
    await account('Main', 'EGP', isDefault: true, number: '5551234');
    await account('Salary', 'SAR', number: '9988771234');
    final ai = _Ai(_sarAnswer);
    final result = await useCase(ai).call(
        rawMessage: _text,
        senderId: 'SNB',
        smsReceivedAt: DateTime.utc(2026, 6, 16, 12));

    expect(ai.context?.accountCurrency, isNull);
    expect(result.outcome, AddTransactionOutcome.notTransaction);
    expect(result.droppedByParser, isTrue,
        reason: 'kept for review (Smart Inbox), never silently dropped');
  });

  test('without AI consent nothing is sent and the defaulted currency is not '
      'confirmed', () async {
    await account('Main', 'EGP', isDefault: true);
    await account('Salary', 'SAR', number: '9988771234');
    final ai = _Ai(_sarAnswer);
    final result = await useCase(ai, consent: false).call(
        rawMessage: _text,
        senderId: 'SNB',
        smsReceivedAt: DateTime.utc(2026, 6, 16, 12));
    expect(ai.calls, 0);
    expect(result.transaction?.currency == 'SAR', isFalse);
  });

  test('consent withdrawn while the request was out: the answer is not used',
      () async {
    await account('Main', 'EGP', isDefault: true);
    await account('Salary', 'SAR', number: '9988771234');
    final ai = _Ai(_sarAnswer);
    var consent = true;
    final result = await useCase(ai, loadConsent: () async {
      final now = consent;
      // Turned off by the user while the (fake) request is in flight.
      if (ai.calls > 0) consent = false;
      return now && ai.calls == 0;
    }).call(
        rawMessage: _text,
        senderId: 'SNB',
        smsReceivedAt: DateTime.utc(2026, 6, 16, 12));
    expect(ai.calls, 1);
    expect(result.transaction?.currency == 'SAR', isFalse,
        reason: 'an answer received after withdrawal is never applied');
    expect(result.currencyFromAccount, isFalse);
  });
}
