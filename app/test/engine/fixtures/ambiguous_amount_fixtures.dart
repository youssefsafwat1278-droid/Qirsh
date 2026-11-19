import 'package:money_companion/engine/models/transaction_type.dart';

import 'bank_sms_golden_fixtures.dart';

/// Messages where a numeric date is genuinely ambiguous (day AND month both ≤ 12
/// with no bank profile to resolve the order).
/// Safety contract: such dates must never auto-confirm — they must stay pending.
final ambiguousDateFixtures = [
  const BankSmsGoldenFixture(
    id: 'ambiguous_date_unknown_bank_5_6_2026',
    description:
        'Unknown bank: date 5/6/2026 — day=5 month=6 both ≤12, unresolvable → pending (never auto-confirm)',
    sender: 'UNKNOWN-BANK',
    rawSms: 'Purchase SAR 99.00 at RESTAURANT on 5/6/2026 12:00',
    expectedType: TransactionType.payment,
    expectedAmount: 99.00,
    expectedCurrency: 'SAR',
    expectedStatus: ExpectedSmsStatus.pending,
  ),
];

/// Messages with multiple amounts where the parser must pick the correct one.
final ambiguousAmountFixtures = [
  const BankSmsGoldenFixture(
    id: 'ambiguous_bsf_three_amounts',
    description:
        'BSF: 3 amounts (txn 150 + fee 0 + totalDue 5620 + balance 14379) — take only txn',
    sender: 'BSF',
    rawSms: 'شراء عبر نقاط البيع بـ SAR 150.00\nرسوم العملية:0.00\n'
        'من Al-Rajul Al-Amthal for Me\nبطاقة ائتمانية 9221* من خلال Apple Pay\n'
        'المبلغ الإجمالي المستحق SAR 5620.87\nالرصيد المتوفر: SAR 14379.13\n'
        'في 26-06-14 20:12',
    expectedType: TransactionType.payment,
    expectedAmount: 150.00,
    expectedCurrency: 'SAR',
    // Round 5 (owner decision): the text carries a due/doubt word
    // ("المستحق"), so it is kept for review (was pending).
    expectedStatus: ExpectedSmsStatus.review,
  ),
  const BankSmsGoldenFixture(
    id: 'ambiguous_d360_intl_fee_balance',
    description:
        'D360: foreign + local + fee + balance — take local SAR, ignore fee and balance',
    sender: 'D360',
    rawSms: 'International Online Purchase\nAmount: USD 4.91 (SAR 18.44)\n'
        'Card: *2948 - VISA (Ecommerce)\nFee: SAR 0.59\n'
        'At: SNAP INC SNAP SNAP ADS\nOn: 2026-06-13 12:16\nAvailable Balance: SAR 225.80',
    expectedType: TransactionType.payment,
    expectedAmount: 18.44,
    expectedCurrency: 'SAR',
    expectedForeignAmount: 4.91,
    expectedForeignCurrency: 'USD',
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  const BankSmsGoldenFixture(
    id: 'ambiguous_dubai_bank_amount_vs_balance_thousands',
    description:
        'Dubai Bank: amount 250.93 vs balance 18,000 (thousands commas) — take amount',
    sender: 'بنك دبي',
    rawSms: 'بطاقة إئتمانية: تأكيد السداد\nبطاقة: XX2678;إئتمانية\n'
        'مبلغ: 250.93  SAR\nرصيد: 18,000.00 SAR\nفي: 24-01-2025',
    expectedType: TransactionType.creditCardPayment,
    expectedAmount: 250.93,
    expectedCurrency: 'SAR',
    expectedBalance: 18000.00,
    expectedStatus: ExpectedSmsStatus.pending,
  ),
];
