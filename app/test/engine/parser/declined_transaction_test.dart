import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/engine/parser/transaction_state_cues.dart';

/// DATA-01 — a bank message announcing a purchase that did NOT complete must
/// never become a confirmed transaction or count toward spend. Synthetic data.
const _sender = 'AlRajhi';

const _declined = <String>[
  'تم رفض عملية شراء بمبلغ 250.00 ريال لدى CAFE ONE بطاقة مدى **1234',
  'Purchase declined: SAR 250.00 at CAFE ONE card **1234',
  'Transaction failed. Purchase of SAR 99.00 at SHOP TWO card **1234',
  'عملية غير ناجحة: شراء بمبلغ 75.00 ريال لدى SHOP TWO بطاقة **1234',
  'عملية شراء مرفوضة بمبلغ ١٢٠٫٥٠ ريال لدى CAFE ONE بطاقة **١٢٣٤',
  'تعذر إتمام عملية شراء بمبلغ 300.00 ريال لدى SHOP TWO لعدم كفاية الرصيد',
  'رفضت عملية شراء 80.00 ريال لدى CAFE ONE: الرصيد غير كافٍ',
  'Purchase of SAR 410.00 at SHOP TWO was rejected: insufficient funds',
  'Purchase of SAR 410.00 at SHOP TWO not processed - credit limit exceeded',
  'فشلت عملية الشراء بمبلغ 60.00 ريال لدى CAFE ONE بسبب تجاوز الحد',
  'Purchase SAR 55.00 at CAFE ONE unsuccessful. Card **1234',
];

const _completedPurchases = <String>[
  'عملية شراء بمبلغ 250.00 ريال لدى CAFE ONE بطاقة مدى **1234',
  'Purchase of SAR 99.00 at SHOP TWO card **1234',
  // Unrelated negations / dispute instructions in a COMPLETED purchase.
  'عملية شراء بمبلغ 45.00 ريال لدى CAFE ONE. إذا لم تقم بهذه العملية اتصل بنا لرفض العملية',
  'عملية شراء بمبلغ 45.00 ريال لدى CAFE ONE. إذا لم يتم التعرف على العملية اتصل بنا',
  'Purchase of SAR 45.00 at CAFE ONE. If you did not make this transaction, call us. Failure to report may delay a dispute.',
];

const _refundsOfFailed = <String>[
  'تم استرجاع مبلغ العملية المرفوضة 250.00 ريال لدى CAFE ONE',
  'Refund for failed transaction: SAR 99.00 from SHOP TWO',
  'Reversal of declined purchase SAR 99.00 at SHOP TWO',
];

/// SNB layout a known bank auto-confirms (see test/data/reports_query_test).
String _snb(String header, double amount) {
  final d = DateTime.now();
  final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return '$header\nمبلغ:SAR ${amount.toStringAsFixed(2)}\nلدى:NETFLIX\nفي:$date 00:01';
}

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

void main() {
  const engine = ParserEngine();

  group('ParserEngine — declined/failed purchases', () {
    for (final sms in _declined) {
      test('not a transaction, but transaction-shaped: $sms', () {
        final r = engine.parse(sms, senderId: _sender);
        expect(r.isTransaction, isFalse);
        // Transaction-shaped → the capture becomes a Smart Inbox review row,
        // never a silent OTP-style drop.
        expect(r.amountDetected, isTrue);
        expect(ParserEngine.isIgnoredMessage(sms, senderId: _sender), isFalse);
      });
    }

    for (final sms in _completedPurchases) {
      test('completed purchase still parses as payment: $sms', () {
        final r = engine.parse(sms, senderId: _sender);
        expect(r.isTransaction, isTrue);
        expect(r.transaction!.type, TransactionType.payment);
        expect(TransactionStateCues.isNotCompleted(sms), isFalse);
      });
    }

    // V1-RES3 (owner policy): a refund/reversal of a declined or failed
    // original returns money that was never recorded — ambiguous, so it goes
    // to review with no total change (it was recorded as a refund before).
    for (final sms in _refundsOfFailed) {
      test('refund/reversal of a failed purchase goes to review: $sms', () {
        expect(TransactionStateCues.isNotCompleted(sms), isTrue);
        final r = engine.parse(sms, senderId: _sender);
        expect(r.isTransaction, isFalse);
        expect(r.amountDetected, isTrue);
      });
    }

    test('cue stems inside longer words do not match', () {
      for (final text in [
        'رفضكم', // not a listed form
        'failedness', 'undeclined',
      ]) {
        expect(TransactionStateCues.isNotCompleted(text), isFalse,
            reason: text);
      }
    });
  });

  group('AiCandidateValidator — declined text', () {
    test('an AI candidate for a declined purchase is rejected', () {
      const sms = 'Purchase declined: SAR 250.00 at CAFE ONE card **1234';
      final v = const AiCandidateValidator().validate(
        response: const AiParseResponse(
            amount: 250, amountText: '250.00', currency: 'SAR', type: 'payment'),
        sanitizedText: sms,
        localParsed: null,
        messageText: sms,
        normalizedType: TransactionType.payment,
      );
      expect(v.accepted, isFalse);
      expect(v.rejectionReason, 'transaction_not_completed');
    });

    test('an AI candidate for a refund of a failed purchase is too (V1-RES3)',
        () {
      const sms = 'Refund for failed transaction: SAR 99.00 from SHOP TWO';
      final v = const AiCandidateValidator().validate(
        response: const AiParseResponse(
            amount: 99, amountText: '99.00', currency: 'SAR', type: 'refund'),
        sanitizedText: sms,
        localParsed: null,
        messageText: sms,
        normalizedType: TransactionType.refund,
      );
      expect(v.accepted, isFalse);
      expect(v.rejectionReason, 'transaction_not_completed');
    });
  });

  group('AddTransactionUseCase (in-memory DB) — declined spend', () {
    late AppDatabase db;
    late DriftTransactionRepository txRepo;
    late AddTransactionUseCase addTransaction;

    setUp(() async {
      db = await AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      );
      txRepo = DriftTransactionRepository(db);
      addTransaction = AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      );
    });

    tearDown(() async => db.close());

    test('declined messages produce zero confirmed spend for the month',
        () async {
      final now = DateTime.now();
      for (final sms in [
        _snb('تم رفض عملية شراء', 250),
        _snb('عملية شراء مرفوضة - رصيد غير كاف', 180),
        _snb('Purchase declined', 75),
      ]) {
        final r = await addTransaction(
            rawMessage: sms, senderId: 'SNB', onDeviceOnly: true);
        expect(r.outcome, AddTransactionOutcome.notTransaction, reason: sms);
        expect(r.droppedByParser, isTrue, reason: sms);
      }
      final from = DateTime(now.year, now.month);
      final to = DateTime(now.year, now.month + 1);
      final total = await txRepo.expenseTotalBetween(
          from: from, to: to, currency: 'SAR');
      expect(total.isZero, isTrue);
      final recent = await txRepo.getRecent(limit: 10, accountId: null);
      expect(
          recent.where((t) => t.status == TransactionStatus.confirmed), isEmpty);
    });

    test(
        'REV-01: "declined … will be refunded" is zero confirmed spend AND '
        'zero confirmed income, on device and with consented AI', () async {
      final ai = _SpyAi();
      final withAi = AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        aiClient: ai,
        loadAiConsent: () async => true,
      );
      const plain = 'Your purchase of SAR 250.00 at Shop X was declined. '
          'If amount was deducted it will be refunded.';
      final snb = _snb(
          'Your purchase was declined. If amount was deducted it will be '
          'refunded.',
          250);
      for (final sms in [plain, snb]) {
        for (final onDeviceOnly in [true, false]) {
          final r = await withAi(
              rawMessage: sms, senderId: 'SNB', onDeviceOnly: onDeviceOnly);
          expect(r.outcome, AddTransactionOutcome.notTransaction, reason: sms);
          expect(r.droppedByParser, isTrue, reason: sms);
        }
      }
      expect(ai.requests, isEmpty);
      final now = DateTime.now();
      final from = DateTime(now.year, now.month);
      final to = DateTime(now.year, now.month + 1);
      expect(
          (await txRepo.expenseTotalBetween(from: from, to: to, currency: 'SAR'))
              .isZero,
          isTrue);
      expect(
          (await txRepo.refundTotalBetween(from: from, to: to, currency: 'SAR'))
              .isZero,
          isTrue);
      expect(
          (await txRepo.incomeTotalBetween(from: from, to: to, currency: 'SAR'))
              .isZero,
          isTrue);
      final recent = await txRepo.getRecent(limit: 10, accountId: null);
      expect(
          recent.where((t) => t.status == TransactionStatus.confirmed), isEmpty);
    });

    test('a declined message is never sent to consented AI', () async {
      final ai = _SpyAi();
      final withAi = AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        aiClient: ai,
        loadAiConsent: () async => true,
      );
      final r = await withAi(
          rawMessage: _snb('تم رفض عملية شراء', 250), senderId: 'SNB');
      expect(r.outcome, AddTransactionOutcome.notTransaction);
      expect(r.droppedByParser, isTrue);
      expect(ai.requests, isEmpty);
    });

    test('a completed purchase in the same setup still counts', () async {
      final r = await addTransaction(
          rawMessage: _snb('عملية شراء', 250), senderId: 'SNB', onDeviceOnly: true);
      expect(r.outcome, AddTransactionOutcome.added);
      expect(r.transaction!.status, TransactionStatus.confirmed);
      final now = DateTime.now();
      final total = await txRepo.expenseTotalBetween(
          from: DateTime(now.year, now.month),
          to: DateTime(now.year, now.month + 1),
          currency: 'SAR');
      expect(total.isZero, isFalse);
    });
  });
}

/// Counts every external AI request; answers "no transaction".
class _SpyAi implements AiParserClient {
  final requests = <String>[];

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    requests.add(sanitizedSms);
    return null;
  }
}
