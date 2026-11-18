import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/merchant_category_map.dart';
import 'package:money_companion/engine/parser/parse_result.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

import 'fixtures/bank_sms_golden_fixtures.dart';
import 'fixtures/ambiguous_amount_fixtures.dart';
import 'fixtures/ignore_fixtures.dart';

void main() {
  const engine = ParserEngine();

  group('Parser golden corpus — anonymized real-world shapes', () {
    for (final fixture in realWorldBankSmsFixtures) {
      test('${fixture.id}: ${fixture.description}', () {
        final result = engine.parse(
          fixture.rawSms,
          senderId: fixture.sender,
        );

        _expectParsedFields(result, fixture);
        expect(_finalStatus(result, fixture), fixture.expectedStatus);
      });
    }
  });

  group('Parser confidence gates', () {
    for (final fixture in parserGateFixtures) {
      test('${fixture.id}: ${fixture.description}', () {
        final result = engine.parse(
          fixture.rawSms,
          senderId: fixture.sender,
        );

        _expectParsedFields(result, fixture);
        expect(_finalStatus(result, fixture), fixture.expectedStatus);
      });
    }

    test('generic parser never reaches auto-confirm confidence', () {
      final result = engine.parse(
        'Purchase SAR 42.00 At STARBUCKS 2026-04-08 12:00',
        senderId: 'UNKNOWN-BANK',
      );

      expect(result.isTransaction, isTrue);
      expect(result.transaction!.parseConfidence,
          lessThan(AddTransactionUseCase.autoConfirmThreshold));
      expect(result.transaction!.parseConfidence,
          lessThanOrEqualTo(ParserEngine.genericMaxConfidence));
      expect(
        _finalStatus(
          result,
          const BankSmsGoldenFixture(
            id: 'generic',
            description: 'generic confidence gate',
            rawSms: '',
            expectedStatus: ExpectedSmsStatus.pending,
            expectedMerchant: 'STARBUCKS',
          ),
        ),
        ExpectedSmsStatus.pending,
      );
    });

    test('ambiguous amount from trusted sender remains pending', () {
      final result = engine.parse(
        '''
Purchase SAR 45.00 At GROCERY
Amount SAR 50.00
2026-04-08 12:00''',
        senderId: 'SNB',
      );

      expect(result.isTransaction, isTrue);
      expect(result.transaction!.parseConfidence,
          greaterThanOrEqualTo(ParserEngine.pendingThreshold));
      expect(result.transaction!.parseConfidence,
          lessThan(AddTransactionUseCase.autoConfirmThreshold));
      expect(
        _finalStatus(
          result,
          const BankSmsGoldenFixture(
            id: 'ambiguous',
            description: 'ambiguous amount',
            rawSms: '',
            expectedStatus: ExpectedSmsStatus.pending,
            expectedMerchant: 'GROCERY',
          ),
        ),
        ExpectedSmsStatus.pending,
      );
    });

    test('missing merchant stays pending even when amount is clear', () {
      final result = engine.parse(
        'Purchase SAR 42.00 2026-04-08 12:00',
        senderId: 'UNKNOWN-BANK',
      );

      expect(result.isTransaction, isTrue);
      expect(result.transaction!.rawMerchant, isNull);
      expect(_finalStatus(result, _pendingFixture), ExpectedSmsStatus.pending);
    });
  });

  group('Parser ignore corpus — must never produce a transaction', () {
    for (final fixture in ignoreFixtures) {
      test('${fixture.id}: ${fixture.description}', () {
        final result = engine.parse(fixture.rawSms, senderId: fixture.sender);
        _expectParsedFields(result, fixture);
        expect(_finalStatus(result, fixture), fixture.expectedStatus);
      });
    }
  });

  group('Parser ambiguous amount corpus — must pick the right amount', () {
    for (final fixture in ambiguousAmountFixtures) {
      test('${fixture.id}: ${fixture.description}', () {
        final result = engine.parse(fixture.rawSms, senderId: fixture.sender);
        _expectParsedFields(result, fixture);
        expect(_finalStatus(result, fixture), fixture.expectedStatus);
      });
    }
  });

  group('Parser ambiguous date safety — must never auto-confirm', () {
    for (final fixture in ambiguousDateFixtures) {
      test('${fixture.id}: ${fixture.description}', () {
        final result = engine.parse(fixture.rawSms, senderId: fixture.sender);
        _expectParsedFields(result, fixture);
        // Ambiguous date must stay in pending — never ignored, never auto-confirmed.
        expect(_finalStatus(result, fixture), ExpectedSmsStatus.pending);
        if (result.isTransaction) {
          expect(
            result.transaction!.parseConfidence,
            lessThan(AddTransactionUseCase.autoConfirmThreshold),
            reason:
                'Ambiguous date must not ride through at auto-confirm confidence',
          );
        }
      });
    }
  });

  group('Parser negative corpus — never transactions', () {
    const ignoredMessages = {
      'otp_with_amount_context':
          'Your OTP is 123456 for SAR 50.00 purchase. Do not share it.',
      'arabic_otp': 'رمز التحقق 123456 لعملية شراء SAR 50 لا تشاركه مع أحد',
      'promo_with_currency':
          'عرض خاص! وفر SAR 50 هذا الأسبوع فقط باستخدام بطاقة البنك',
      'scam_like_link':
          'Congratulations, you won SAR 1000. Click https://example.invalid now',
      'balance_only': 'Available Balance: SAR 225.80',
      'arabic_balance_only': 'الرصيد المتاح في حسابك SAR 225.80',
    };

    for (final entry in ignoredMessages.entries) {
      test('${entry.key} is ignored', () {
        final result = engine.parse(entry.value, senderId: 'SNB');

        expect(result.isTransaction, isFalse);
        expect(
            _finalStatus(result, _ignoredFixture), ExpectedSmsStatus.ignored);
      });
    }
  });
}

const _pendingFixture = BankSmsGoldenFixture(
  id: 'pending',
  description: 'pending helper',
  rawSms: '',
  expectedStatus: ExpectedSmsStatus.pending,
);

const _ignoredFixture = BankSmsGoldenFixture(
  id: 'ignored',
  description: 'ignored helper',
  rawSms: '',
  expectedStatus: ExpectedSmsStatus.ignored,
);

void _expectParsedFields(ParseResult result, BankSmsGoldenFixture fixture) {
  if (fixture.expectedStatus == ExpectedSmsStatus.ignored) {
    expect(result.isTransaction, isFalse);
    return;
  }
  if (fixture.expectedStatus == ExpectedSmsStatus.review) {
    // Never recorded, never silent: the amount is kept for review.
    expect(result.isTransaction, isFalse);
    expect(result.amountDetected, isTrue);
    return;
  }

  expect(result.isTransaction, isTrue);
  final transaction = result.transaction!;

  if (fixture.expectedType != null) {
    expect(transaction.type, fixture.expectedType);
  }
  if (fixture.expectedAmount != null) {
    expect(transaction.amount, closeTo(fixture.expectedAmount!, 0.001));
  }
  if (fixture.expectedCurrency != null) {
    expect(transaction.currency, fixture.expectedCurrency);
  }
  if (fixture.expectedMerchant != null) {
    expect(transaction.rawMerchant, fixture.expectedMerchant);
  }
  if (fixture.expectedFundingSource != null) {
    expect(transaction.rawMerchant, isNull);
    expect(transaction.fundingSource, fixture.expectedFundingSource);
  }
  if (fixture.expectedForeignAmount != null) {
    expect(transaction.foreignAmount,
        closeTo(fixture.expectedForeignAmount!, 0.001));
  }
  if (fixture.expectedForeignCurrency != null) {
    expect(transaction.foreignCurrency, fixture.expectedForeignCurrency);
  }
  if (fixture.expectedLast4 != null) {
    expect(transaction.cardLast4, fixture.expectedLast4);
  }
  if (fixture.expectedBalance != null) {
    expect(transaction.balanceAfter, closeTo(fixture.expectedBalance!, 0.001));
  }
  if (fixture.expectedOccurredAt != null) {
    expect(transaction.occurredAt, fixture.expectedOccurredAt);
  }
}

ExpectedSmsStatus _finalStatus(
  ParseResult result,
  BankSmsGoldenFixture fixture,
) {
  if (!result.isTransaction || result.transaction == null) {
    return result.amountDetected &&
            fixture.expectedStatus == ExpectedSmsStatus.review
        ? ExpectedSmsStatus.review
        : ExpectedSmsStatus.ignored;
  }

  final knownMerchant = fixture.expectedMerchant;
  final knownCategory = fixture.knownMerchantCategoryKey;
  final map = knownMerchant == null || knownCategory == null
      ? null
      : MerchantCategoryMap({knownMerchant: knownCategory});
  final categoryResult = Categorizer(map: map).categorize(result.transaction!);
  final hasUserConfirmedMerchant =
      knownMerchant != null && knownCategory != null;

  final canAutoConfirm = result.transaction!.parseConfidence >=
          AddTransactionUseCase.autoConfirmThreshold &&
      categoryResult.confidence >=
          AddTransactionUseCase.categoryAutoConfirmThreshold &&
      hasUserConfirmedMerchant;

  return canAutoConfirm
      ? ExpectedSmsStatus.autoConfirm
      : ExpectedSmsStatus.pending;
}
