import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/capture/proof_commit_gate.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/ai_sender_failure_tracker.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parse_result.dart';

import 'local_v2_support.dart';

const _raw = 'Purchase SAR 42.00 At STARBUCKS';

ParsedTransaction _txn({
  String? amountText = '42.00',
  double amount = 42.0,
  String currency = 'SAR',
  TransactionType type = TransactionType.payment,
  double confidence = 0.75,
  String? merchant = 'STARBUCKS',
  String? foreignText,
  double? foreign,
  String? foreignCurrency,
}) =>
    ParsedTransaction(
      amountText: amountText,
      amount: amount,
      currency: currency,
      type: type,
      source: TransactionSource.card,
      rawMerchant: merchant,
      foreignAmountText: foreignText,
      foreignAmount: foreign,
      foreignCurrency: foreignCurrency,
      parseConfidence: confidence,
    );

AddTransactionUseCase _useCase({
  required StoringTransactionRepo repo,
  ParseResult? parse,
  bool Function()? flag,
  CountingAiClient? ai,
  bool consent = true,
  ProofGateMode Function()? proofMode,
  SingleAccountRepo? accounts,
  MemoryDedupStore? dedup,
}) =>
    AddTransactionUseCase(
      transactionRepository: repo,
      merchantCategoryRepository: NewMerchantRepo(),
      parserIsolate: FakeParserIsolate(parse),
      aiClient: ai,
      loadAiConsent: () async => consent,
      dedupStore: dedup ?? MemoryDedupStore(),
      accountRepository: accounts,
      proofGateMode: proofMode,
      isLocalAutoConfirmV2: flag,
    );

void main() {
  setUp(() => AiSenderFailureTracker.instance.resetForTest());

  for (final local in [true, false]) {
    test(
        'manual paste always consults AI (${local ? 'with' : 'without'} a local parse) and reports AI as its source',
        () async {
      final ai = CountingAiClient(const AiParseResponse(
        amount: 42,
        amountText: '42.00',
        currency: 'SAR',
        type: 'payment',
        merchantName: 'STARBUCKS',
      ));
      final ingest = IngestCapturedMessageUseCase(_useCase(
        repo: StoringTransactionRepo(),
        parse: local
            ? ParseResult.success(_txn(), catalogAmountCorroborated: true)
            : ParseResult.notTransaction(),
        flag: () => true,
        ai: ai,
      ));
      final result = await ingest.fromCapturedMessage(CapturedMessage(
        text: _raw,
        source: CapturedMessageSource.manualPaste,
        receivedAt: DateTime.utc(2026, 10, 27),
      ));
      expect(ai.callCount, 1);
      expect(result.addTransactionResult.outcome, AddTransactionOutcome.added);
      expect(result.addTransactionResult.transaction!.source,
          TransactionSourceEntity.aiParsed);
    });
  }

  group('flag OFF / rollback switch', () {
    test('absent, false and throwing flag all keep today\'s pending outcome',
        () async {
      for (final flag in <bool Function()?>[
        null,
        () => false,
        () => throw StateError('flags not ready'),
      ]) {
        final repo = StoringTransactionRepo();
        final result = await _useCase(
          repo: repo,
          parse: ParseResult.success(_txn(confidence: 0.75)),
          flag: flag,
        )(rawMessage: _raw, senderId: 'SNB');
        expect(result.outcome, AddTransactionOutcome.added);
        expect(result.transaction!.status, TransactionStatus.pending);
        expect(result.requiresConfirmation, isTrue);
      }
    });

    test('the flag is actually read: true changes the outcome', () async {
      Future<AddTransactionResult> run(bool on) => _useCase(
            repo: StoringTransactionRepo(),
            parse: ParseResult.success(_txn(confidence: 0.75)),
            flag: () => on,
          )(rawMessage: _raw, senderId: 'SNB');
      final off = await run(false);
      final on = await run(true);
      expect(off.transaction!.status, TransactionStatus.pending);
      expect(on.transaction!.status, TransactionStatus.confirmed);
    });

    test('flag OFF: foreign unpriced and non-exact money stay pending',
        () async {
      final repo = StoringTransactionRepo();
      final foreign = await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(
            amountText: '99', amount: 99, currency: 'USD', confidence: 0.95)),
        accounts: SingleAccountRepo(homeAccount('SAR')),
        flag: () => false,
      // (Round 5: a completed-event form, else the text is review.)
      )(rawMessage: 'شراء انترنت\nمبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE');
      expect(foreign.transaction!.status, TransactionStatus.pending);
    });
  });

  group('flag OFF: AI validator FAIL means no transaction (no last resort)',
      () {
    // Parses fine for the old last-resort regex (currency + amount).
    const text = 'Purchase SAR 42.00 At STARBUCKS';

    test('AI response rejected by the validator => no transaction', () async {
      final repo = StoringTransactionRepo();
      final ai = CountingAiClient(const AiParseResponse(
        amount: 99.0, // not grounded in the message => validator rejects
        amountText: '99.00',
        currency: 'SAR',
        type: 'payment',
        merchantName: 'STARBUCKS',
      ));
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.notTransaction(),
        flag: () => false,
        ai: ai,
      )(rawMessage: text, senderId: 'SNB');
      expect(ai.callCount, 1);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
      expect(result.aiFailureReason, 'ai_response_rejected_by_grounding');
      expect(repo.saveCount, 0);
    });

    test('AI returns nothing (is_transaction false) => no transaction',
        () async {
      final repo = StoringTransactionRepo();
      final ai = CountingAiClient(); // null response
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.notTransaction(),
        flag: () => false,
        ai: ai,
      )(rawMessage: text, senderId: 'SNB');
      expect(ai.callCount, 1);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
      expect(repo.saveCount, 0);
    });

    test('AI skipped (no consent) and locally unparseable => unchanged',
        () async {
      final repo = StoringTransactionRepo();
      final ai = CountingAiClient();
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.notTransaction(),
        flag: () => false,
        ai: ai,
        consent: false,
      )(rawMessage: text, senderId: 'SNB');
      expect(ai.callCount, 0);
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
      expect(repo.saveCount, 0);
    });
  });

  group('flag ON: valid local parse is confirmed', () {
    for (final entry in {
      'generic 0.75': (0.75, 'STARBUCKS'),
      'catalog-capped 0.89': (0.89, 'STARBUCKS'),
      'new merchant': (0.95, 'BRAND NEW SHOP'),
      'low category confidence (no merchant)': (0.55, null),
    }.entries) {
      test(entry.key, () async {
        final repo = StoringTransactionRepo();
        final ai = CountingAiClient();
        final result = await _useCase(
          repo: repo,
          parse: ParseResult.success(
              _txn(confidence: entry.value.$1, merchant: entry.value.$2)),
          flag: () => true,
          ai: ai,
        )(rawMessage: _raw, senderId: 'SNB');

        expect(result.outcome, AddTransactionOutcome.added);
        expect(result.transaction!.status, TransactionStatus.confirmed);
        expect(result.requiresConfirmation, isFalse);
        expect(result.isNewMerchant, isFalse);
        // AI is always consulted; a null AI answer keeps the local parse.
        expect(ai.callCount, 1);
        final disposition = await IngestCapturedMessageUseCase(_useCase(
          repo: StoringTransactionRepo(),
          parse: ParseResult.success(
              _txn(confidence: entry.value.$1, merchant: entry.value.$2)),
          flag: () => true,
        )).call(rawMessage: _raw, senderId: 'SNB');
        expect(disposition.disposition, CapturedMessageDisposition.notifyOnly);
      });
    }

    test('real ParserEngine parse of a generic message is confirmed', () async {
      final repo = StoringTransactionRepo();
      final result = await _useCase(
        repo: repo,
        flag: () => true,
      )(
          rawMessage: 'Purchase SAR 42.00 At STARBUCKS 2026-04-08 12:00',
          senderId: 'UNKNOWN-BANK');
      expect(result.transaction!.status, TransactionStatus.confirmed);
      expect(result.requiresConfirmation, isFalse);
    });
  });

  group('flag ON: invalid local parse == local produced nothing', () {
    final cases = <String, (ParseResult, String)>{
      'non-canonical money': (
        ParseResult.success(_txn(amountText: '1.234', amount: 1.234)),
        'Purchase SAR 1.234 At STARBUCKS'
      ),
      'unknown type': (ParseResult.success(_txn(), typeUndetected: true), _raw),
      'direction contradiction': (
        ParseResult.success(_txn()),
        // (Round 5: a completed-event form, else the meaning holds it.)
        'Salary SAR 42.00 deposited'
      ),
      'uncorroborated catalog amount': (
        ParseResult.success(_txn(), catalogAmountCorroborated: false),
        _raw
      ),
    };

    for (final entry in cases.entries) {
      test('${entry.key}: no transaction, Smart Inbox when AI not allowed',
          () async {
        final repo = StoringTransactionRepo();
        final ai = CountingAiClient();
        final result = await _useCase(
          repo: repo,
          parse: entry.value.$1,
          flag: () => true,
          ai: ai,
          consent: false,
        )(rawMessage: entry.value.$2, senderId: 'SNB');
        expect(result.outcome, AddTransactionOutcome.notTransaction);
        expect(result.droppedByParser, isTrue);
        expect(result.parseResult!.isTransaction, isFalse);
        expect(repo.saveCount, 0);
        expect(ai.callCount, 0);
      });

      test('${entry.key}: AI is attempted when consent allows', () async {
        final repo = StoringTransactionRepo();
        final ai = CountingAiClient(); // returns null -> rejected
        final result = await _useCase(
          repo: repo,
          parse: entry.value.$1,
          flag: () => true,
          ai: ai,
        )(rawMessage: entry.value.$2, senderId: 'SNB');
        expect(ai.callCount, 1);
        expect(result.outcome, AddTransactionOutcome.notTransaction);
        expect(repo.saveCount, 0, reason: 'no pending last-resort row');
      });
    }

    test('proof gate withholding (armed) is invalid', () async {
      final repo = StoringTransactionRepo();
      final ai = CountingAiClient();
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(confidence: 0.75)),
        flag: () => true,
        ai: ai,
        consent: false,
        proofMode: () => ProofGateMode.armed,
      )(rawMessage: _raw, senderId: 'SNB');
      expect(result.outcome, AddTransactionOutcome.notTransaction);
      expect(result.droppedByParser, isTrue);
      expect(repo.saveCount, 0);

      // Same input, shadow mode: valid.
      final shadow = await _useCase(
        repo: StoringTransactionRepo(),
        parse: ParseResult.success(_txn(confidence: 0.75)),
        flag: () => true,
        consent: false,
        proofMode: () => ProofGateMode.shadow,
      )(rawMessage: _raw, senderId: 'SNB');
      expect(shadow.transaction!.status, TransactionStatus.confirmed);
    });

    test('invalid local + validator-accepted AI => confirmed AI transaction',
        () async {
      final repo = StoringTransactionRepo();
      final ai = CountingAiClient(const AiParseResponse(
        amount: 42.0,
        amountText: '42.00',
        currency: 'SAR',
        type: 'payment',
        merchantName: 'STARBUCKS',
      ));
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(), catalogAmountCorroborated: false),
        flag: () => true,
        ai: ai,
      )(rawMessage: _raw, senderId: 'SNB');
      expect(ai.callCount, 1);
      expect(result.transaction!.status, TransactionStatus.confirmed);
      expect(result.transaction!.source, TransactionSourceEntity.aiParsed);
    });
  });

  group('flag ON: foreign unpriced is confirmed with awaitingFx pricing', () {
    const raw =
        'شراء إنترنت\nمبلغ:99 USD\nالرسوم/الضريبة:SAR 7.44\nمن:APPLE.CO';
    Future<(AddTransactionResult, StoringTransactionRepo)> run(
        {bool on = true}) async {
      final repo = StoringTransactionRepo();
      final result = await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(
            amountText: '99',
            amount: 99,
            currency: 'USD',
            confidence: 0.95,
            merchant: 'APPLE.CO')),
        accounts: SingleAccountRepo(homeAccount('SAR')),
        flag: () => on,
      )(rawMessage: raw);
      return (result, repo);
    }

    test('confirmed, amount 0, foreign kept, no confirmation', () async {
      final (result, _) = await run();
      final tx = result.transaction!;
      expect(tx.status, TransactionStatus.confirmed);
      expect(tx.amountMoney, Money.zero('SAR'));
      expect(tx.foreignMoney, Money.parse('99', 'USD'));
      expect(tx.foreignCurrency, 'USD');
      expect(tx.pricingState, TransactionPricingState.awaitingFx);
      expect(result.requiresConfirmation, isFalse);
    });

    test('the details price prompt stays available (derived, not status)',
        () async {
      final (result, _) = await run();
      final tx = result.transaction!;
      // transaction_details_screen shows the prompt on exactly this predicate.
      expect(
          tx.pricingState == TransactionPricingState.awaitingFx &&
              tx.foreignCurrency != null,
          isTrue);
      final priced = tx.copyWith(amountMoney: Money.parse('370.00', 'SAR'));
      expect(priced.pricingState, TransactionPricingState.priced);
    });

    test('OFF for comparison: pending', () async {
      final (result, _) = await run(on: false);
      expect(result.transaction!.status, TransactionStatus.pending);
    });
  });

  group('duplicates and legacy rows', () {
    test('a re-processed message is still a duplicate under the flag',
        () async {
      final repo = StoringTransactionRepo();
      final dedup = MemoryDedupStore();
      final useCase = _useCase(
        repo: repo,
        parse: ParseResult.success(_txn()),
        flag: () => true,
        dedup: dedup,
      );
      final first = await useCase(
          rawMessage: _raw,
          senderId: 'SNB',
          smsReceivedAt: DateTime.utc(2026, 6, 1, 10));
      final second = await useCase(
          rawMessage: _raw,
          senderId: 'SNB',
          smsReceivedAt: DateTime.utc(2026, 6, 1, 10));
      expect(first.outcome, AddTransactionOutcome.added);
      expect(second.outcome, AddTransactionOutcome.suspiciousDuplicate);
      expect(repo.saveCount, 1);
    });

    test('a legacy pending row is untouched by new captures', () async {
      final repo = StoringTransactionRepo();
      final legacy = await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(amountText: '10.00', amount: 10)),
        flag: () => false,
      )(rawMessage: 'Purchase SAR 10.00 At OLD SHOP', senderId: 'SNB');
      expect(legacy.transaction!.status, TransactionStatus.pending);
      final before = repo.byId[legacy.transaction!.id]!;

      await _useCase(
        repo: repo,
        parse: ParseResult.success(_txn(amountText: '77.00', amount: 77)),
        flag: () => true,
      )(rawMessage: 'Purchase SAR 77.00 At NEW SHOP', senderId: 'SNB');

      expect(repo.byId[legacy.transaction!.id], same(before));
      expect(
          repo.byId[legacy.transaction!.id]!.status, TransactionStatus.pending);
      expect(repo.saveCount, 2);
    });
  });

  group('an SMS date with no clock time', () {
    Future<DateTime> occurredAt(DateTime fromSms, DateTime receivedAt) async {
      final parsed = _txn().copyWith(occurredAt: fromSms);
      final result = await _useCase(
        repo: StoringTransactionRepo(),
        parse: ParseResult.success(parsed),
        flag: () => true,
      )(rawMessage: _raw, senderId: 'SNB', smsReceivedAt: receivedAt);
      return result.transaction!.occurredAt;
    }

    test('keeps the received time on the received day, not 12:00 AM', () async {
      final received = DateTime(2026, 10, 29, 14, 37).toUtc();
      expect(await occurredAt(DateTime(2026, 10, 29), received), received);
    });

    test('keeps the SMS date on another day, and a written time as is',
        () async {
      final received = DateTime(2026, 10, 29, 14, 37).toUtc();
      expect(await occurredAt(DateTime(2026, 10, 25), received),
          DateTime(2026, 10, 25).toUtc());
      expect(await occurredAt(DateTime(2026, 10, 29, 0, 2), received),
          DateTime(2026, 10, 29, 0, 2).toUtc());
    });
  });
}
