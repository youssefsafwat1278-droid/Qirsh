// Closure round, follow-up 6: the parser's message meaning gates the AI path
// through the real AddTransactionUseCase. Synthetic messages only.
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';

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


AiParseResponse _answer(double amount, String type, String direction) =>
    AiParseResponse(
      amount: amount,
      amountText: amount.toStringAsFixed(2),
      currency: 'SAR',
      type: type,
      direction: direction,
      categoryKey: 'other',
      messageType: 'transaction',
      status: 'completed',
    );

void main() {
  late AppDatabase db;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
  });

  tearDown(() async => db.close());

  AddTransactionUseCase useCase(_Ai ai) => AddTransactionUseCase(
        transactionRepository: DriftTransactionRepository(db),
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        // The real deterministic parser.
        parserIsolate: const FakeParserIsolate(),
        aiClient: ai,
        loadAiConsent: () async => true,
        installId: 'install',
      );

  // Closure round, follow-up 6 (1)/(4)/(6): the parser's meaning decides
  // before any AI request; a model answer never turns these into money.
  final held = <(String, String, AiParseResponse)>[
    ('Cash deposit SAR 1,500.00 to account *5678 via ATM', 'cash_deposit',
        _answer(1500, 'income', 'credit')),
    ('Purchase SAR 120.00 at SHOP. Cashback SAR 12.00 credited to your card',
        'multiple_amounts', _answer(120, 'payment', 'debit')),
    ('Your bill of SAR 230.00 is due on 25/06. Pay now to avoid late fees.',
        'bill_due', _answer(230, 'payment', 'debit')),
    ('Your salary of SAR 9,000.00 is expected on 27/06',
        'scheduled_or_expected', _answer(9000, 'income', 'credit')),
  ];
  for (final (text, reason, answer) in held) {
    test('$reason: no AI request, nothing recorded, Smart Inbox with the reason',
        () async {
      final ai = _Ai(answer);
      final result = await useCase(ai).call(
          rawMessage: text,
          senderId: 'SNB',
          smsReceivedAt: DateTime.utc(2026, 6, 16, 12));
      expect(ai.calls, 0);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue, reason: 'never silent');
      expect(result.reviewReason, reason);
      expect(await DriftTransactionRepository(db).getAll(), isEmpty);
    });
  }

  test('a completed purchase still goes to the AI and is recorded', () async {
    final ai = _Ai(_answer(80, 'payment', 'debit'));
    final result = await useCase(ai).call(
        rawMessage:
            'Purchase of SAR 80.00 at SHOP with card *1234. Never share your OTP with anyone.',
        senderId: 'SNB',
        smsReceivedAt: DateTime.utc(2026, 6, 16, 12));
    expect(ai.calls, 1);
    expect(result.outcome, AddTransactionOutcome.added);
    expect(result.reviewReason, isNull);
  });
}
