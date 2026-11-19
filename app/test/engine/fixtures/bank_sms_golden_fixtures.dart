import 'package:money_companion/engine/models/transaction_type.dart';

/// `review`: no transaction, with the amount kept for a review row (round 3
/// closure, owner brief §5: an ATM cash deposit is not proven income).
enum ExpectedSmsStatus { autoConfirm, pending, ignored, review }

class BankSmsGoldenFixture {
  const BankSmsGoldenFixture({
    required this.id,
    required this.description,
    required this.rawSms,
    required this.expectedStatus,
    this.sender,
    this.expectedType,
    this.expectedAmount,
    this.expectedCurrency,
    this.expectedMerchant,
    this.expectedLast4,
    this.expectedBalance,
    this.expectedOccurredAt,
    this.expectedForeignAmount,
    this.expectedForeignCurrency,
    this.expectedFundingSource,
    this.knownMerchantCategoryKey,
  });

  final String id;
  final String description;
  final String rawSms;
  final String? sender;
  final TransactionType? expectedType;
  final double? expectedAmount;
  final String? expectedCurrency;
  final String? expectedMerchant;
  final String? expectedLast4;
  final double? expectedBalance;
  final DateTime? expectedOccurredAt;
  final double? expectedForeignAmount;
  final String? expectedForeignCurrency;
  final String? expectedFundingSource;
  final ExpectedSmsStatus expectedStatus;

  /// Simulates a user-confirmed merchant map for final auto-confirm gating.
  final String? knownMerchantCategoryKey;
}

/// Golden corpus for the parser safety contract.
///
/// These samples are anonymized. They keep only safe last4 digits and do not
/// include real account numbers, personal names, phone numbers, or raw inbox
/// metadata.
final realWorldBankSmsFixtures = [
  const BankSmsGoldenFixture(
    id: 'eg_cib_prepaid_fawry_debit',
    description:
        'CIB Egypt prepaid card debit at Fawry — DD/MM date, المتاح balance',
    sender: 'CIB',
    rawSms:
        'تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 عند FAWRY*SNTRAL NWR ALA '
        'يوم 14/03 الساعه 22:29 المتاح 28.14  للمزيد إتصل ب 19623',
    expectedType: TransactionType.payment,
    expectedAmount: 60.00,
    expectedCurrency: 'EGP',
    expectedMerchant: 'FAWRY*SNTRAL NWR ALA',
    expectedLast4: '4907',
    expectedBalance: 28.14,
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  const BankSmsGoldenFixture(
    id: 'eg_debit_orange_available_balance_text',
    description:
        'EGP debit-card purchase with support/balance text after amount',
    sender: 'BANK-EG',
    rawSms: 'Your Debit Card **5398 had a Successful transaction of EGP 33.00 '
        '@Orange, your available bal. is hidden. for lost/stolen card call 00000',
    expectedType: TransactionType.payment,
    expectedAmount: 33.00,
    expectedCurrency: 'EGP',
    expectedMerchant: 'Orange',
    expectedLast4: '5398',
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  const BankSmsGoldenFixture(
    id: 'ae_adib_unsupported_trx_of_aed_avl_balance',
    description:
        'ADIB unsupported bank — generic parser extracts AED trx and ignores Avl Bal',
    sender: 'ADIB',
    rawSms: 'Trx. of AED 50.00 on your a/c ****0535 at ABU DHABI NATIONAL '
        'OIL ABU DHABI AE. Avl Bal is AED 12956.50',
    expectedType: TransactionType.payment,
    expectedAmount: 50.00,
    expectedCurrency: 'AED',
    expectedMerchant: 'ABU DHABI NATIONAL OIL',
    expectedLast4: '0535',
    expectedBalance: 12956.50,
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_ar_pos_starbucks_short_date',
    description: 'Arabic POS purchase with SAR before amount and d/M/yy date',
    sender: 'BANK-SA',
    rawSms: '''
شراء PoS
عبر:6826;مدى-ابل باي
بـSAR 24
لـSTARBUCKS
13/6/26 16:03''',
    expectedType: TransactionType.payment,
    expectedAmount: 24,
    expectedCurrency: 'SAR',
    expectedMerchant: 'STARBUCKS',
    expectedLast4: '6826',
    expectedOccurredAt: DateTime(2026, 6, 13, 16, 3),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_international_online_purchase_fee_balance',
    description:
        'International purchase with original amount, conversion, fee, and balance',
    sender: 'BANK-SA',
    rawSms: '''
International Online Purchase
Amount: USD 4.91 (SAR 18.44)
Card: *2948 - VISA (Ecommerce)
Fee: SAR 0.59
At: SNAP INC SNAP SNAP ADS
Country: United States
On: 2026-06-13 12:16
Available Balance: SAR 225.80''',
    expectedType: TransactionType.payment,
    expectedAmount: 18.44,
    expectedCurrency: 'SAR',
    expectedForeignAmount: 4.91,
    expectedForeignCurrency: 'USD',
    expectedMerchant: 'SNAP INC SNAP SNAP ADS',
    expectedLast4: '2948',
    expectedBalance: 225.80,
    expectedOccurredAt: DateTime(2026, 6, 13, 12, 16),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_ar_online_purchase_account_masked',
    description: 'Arabic online purchase with masked account and ISO date',
    sender: 'BANK-SA',
    rawSms: '''
شراء إنترنت
بطاقة:6089*;مدى Apple Pay
مبلغ:700.00 SAR
حساب:9940*
من:barq
في:2026-05-21 14:06''',
    expectedType: TransactionType.payment,
    expectedAmount: 700,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: 'barq',
    expectedLast4: '6089',
    expectedOccurredAt: DateTime(2026, 5, 21, 14, 6),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_ar_online_purchase_fee_zero',
    description: 'Arabic online purchase where zero fee must not become amount',
    sender: 'BANK-SA',
    rawSms: '''
شراء إنترنت
بطاقة:7640; urpay بطاقة; ; Apple Pay
مبلغ:300 SAR
الرسوم/الضريبة:SAR 0.00
من:barq
10-6-2026 14:32''',
    expectedType: TransactionType.payment,
    expectedAmount: 300,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: 'barq',
    expectedLast4: '7640',
    expectedOccurredAt: DateTime(2026, 6, 10, 14, 32),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_en_online_purchase_account_and_card',
    description:
        'English purchase with account last4 and card last4 in separate lines',
    sender: 'BANK-SA',
    rawSms: '''
Online Purchase
Amount 8 SAR
Account *1202
At barq
Mada-Apple pay *5172
on 21/05/26 at 19:11''',
    expectedType: TransactionType.payment,
    expectedAmount: 8,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: 'barq',
    expectedLast4: '5172',
    expectedOccurredAt: DateTime(2026, 5, 21, 19, 11),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_ar_pos_merchant_label_balance',
    description:
        'Arabic POS purchase with explicit merchant label and available balance',
    sender: 'BANK-SA',
    rawSms: '''
شراء عبر نقاط البيع
بطاقة: ***1046;ائتمانية
اسم التاجر: EAST BUFFET FOR SECRET ME
مبلغ العملية: 14.00 SAR
الرصيد المتاح: 5.88 SAR
تاريخ العملية : 2026-05-28 09:09:19''',
    expectedType: TransactionType.payment,
    expectedAmount: 14,
    expectedCurrency: 'SAR',
    expectedMerchant: 'EAST BUFFET FOR SECRET ME',
    expectedLast4: '1046',
    expectedBalance: 5.88,
    expectedOccurredAt: DateTime(2026, 5, 28, 9, 9),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'kwd_international_purchase_fx_wallet_balance',
    description:
        'KWD purchase with SAR conversion, FX rate, and wallet balance',
    sender: 'BANK-SA',
    rawSms: '''
POS International Purchase
Visa card: **1056 (Apple Pay)
Amount: 0.1 KWD (1.22 SAR) FX 12.2000
Wallet balance: 201.04
At: CAESARS
Country: Kuwait
2026-06-12 22:16''',
    expectedType: TransactionType.payment,
    expectedAmount: 1.22,
    expectedCurrency: 'SAR',
    expectedForeignAmount: 0.1,
    expectedForeignCurrency: 'KWD',
    expectedMerchant: 'CAESARS',
    expectedLast4: '1056',
    expectedBalance: 201.04,
    expectedOccurredAt: DateTime(2026, 6, 12, 22, 16),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_internal_outward_transfer',
    description: 'Internal outward transfer with anonymized recipient',
    sender: 'BANK-SA',
    rawSms: '''
Internal outward transfer
Amount:21.00SAR
To:SAMPLE RECIPIENT
Acc:3583*
At:19/04/26 11:07''',
    expectedType: TransactionType.transfer,
    expectedAmount: 21,
    expectedCurrency: 'SAR',
    expectedMerchant: 'SAMPLE RECIPIENT',
    expectedLast4: '3583',
    expectedOccurredAt: DateTime(2026, 4, 19, 11, 7),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  const BankSmsGoldenFixture(
    id: 'eg_nbe_prepaid_fawry',
    description: 'NBE Egypt prepaid card debit at Fawry (NBE profile, not CIB)',
    sender: 'NBE',
    rawSms:
        'تم خصم 60.00EGP من بطاقة المدفوعة مقدماً رقم 4907 عند FAWRY*SNTRAL NWR ALA '
        'يوم 14/03 الساعه 22:29 المتاح 28.14  للمزيد إتصل ب 19623',
    expectedType: TransactionType.payment,
    expectedAmount: 60.00,
    expectedCurrency: 'EGP',
    expectedMerchant: 'FAWRY*SNTRAL NWR ALA',
    expectedLast4: '4907',
    expectedBalance: 28.14,
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_rajhi_mada_pos_starbucks',
    description:
        'Al Rajhi real sender ID — mada POS, SAR before amount, lam-merchant',
    sender: 'الراجحي',
    rawSms:
        'شراء PoS\nعبر:6826;مدى-ابل باي\nبـSAR 24\nلـSTARBUCKS\n؜13/6/26 16:03',
    expectedType: TransactionType.payment,
    expectedAmount: 24,
    expectedCurrency: 'SAR',
    expectedMerchant: 'STARBUCKS',
    expectedLast4: '6826',
    expectedOccurredAt: DateTime(2026, 6, 13, 16, 3),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_d360_intl_purchase_local_amount',
    description:
        'D360 international purchase — local SAR amount from parentheses, fee+balance ignored',
    sender: 'D360',
    rawSms: 'International Online Purchase\n'
        'Amount: USD 4.91 (SAR 18.44)\n'
        'Card: *2948 - VISA (Ecommerce)\n'
        'Fee: SAR 0.59\n'
        'At: SNAP INC SNAP SNAP ADS\n'
        'Country: United States\n'
        'On: 2026-06-13 12:16\n'
        'Available Balance: SAR 225.80',
    expectedType: TransactionType.payment,
    expectedAmount: 18.44,
    expectedCurrency: 'SAR',
    expectedForeignAmount: 4.91,
    expectedForeignCurrency: 'USD',
    expectedMerchant: 'SNAP INC SNAP SNAP ADS',
    expectedLast4: '2948',
    expectedBalance: 225.80,
    expectedOccurredAt: DateTime(2026, 6, 13, 12, 16),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_riyad_online_barq_funding',
    description:
        'Riyad Bank Arabic online — من:barq is funding source, not merchant',
    sender: 'riyad',
    rawSms:
        'شراء إنترنت\nبطاقة:6089*;مدى Apple Pay\nمبلغ:700.00 SAR\nحساب:369940*\nمن:barq\nفي:2026-05-21 14:06',
    expectedType: TransactionType.payment,
    expectedAmount: 700.00,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: 'barq',
    expectedLast4: '6089',
    expectedOccurredAt: DateTime(2026, 5, 21, 14, 6),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_snb_en_online_barq_funding',
    description:
        'SNB English online — At barq is funding source, card from Mada line',
    sender: 'Snb الاهلي',
    rawSms:
        'Online Purchase\nAmount 8 SAR\nAccount *1202\nAt barq\nMada-Apple pay *5172\non 21/05/26 at 19:11',
    expectedType: TransactionType.payment,
    expectedAmount: 8,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: 'barq',
    expectedLast4: '5172',
    expectedOccurredAt: DateTime(2026, 5, 21, 19, 11),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_saib_pos_txn_vs_balance',
    description:
        'SAIB POS — مبلغ العملية vs الرصيد المتاح: only take transaction amount',
    sender: 'saib',
    rawSms:
        'شراء عبر نقاط البيع\nبطاقة: ***1046;ائتمانية\nاسم التاجر: EAST BUFFET FOR SECRET ME\nمبلغ العملية: 14.00 SAR\nالرصيد المتاح: 5.88 SAR\nتاريخ العملية : 2026-05-28 09:09:19',
    expectedType: TransactionType.payment,
    expectedAmount: 14.00,
    expectedCurrency: 'SAR',
    expectedMerchant: 'EAST BUFFET FOR SECRET ME',
    expectedLast4: '1046',
    expectedBalance: 5.88,
    expectedOccurredAt: DateTime(2026, 5, 28, 9, 9),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_barq_kwd_intl_local_amount',
    description:
        'barq international KWD purchase — SAR local amount from parentheses',
    sender: 'barq',
    rawSms:
        'POS International Purchase\nVisa card: **1056 (Apple Pay)\nAmount: 0.1 KWD (1.22 SAR) FX 12.2000\nWallet balance: 201.04\nAt: CAESARS\nCountry: Kuwait\n2026-06-12 22:16',
    expectedType: TransactionType.payment,
    expectedAmount: 1.22,
    expectedCurrency: 'SAR',
    expectedForeignAmount: 0.1,
    expectedForeignCurrency: 'KWD',
    expectedMerchant: 'CAESARS',
    expectedLast4: '1056',
    expectedBalance: 201.04,
    expectedOccurredAt: DateTime(2026, 6, 12, 22, 16),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_transfer_outward',
    description:
        'STC Bank outward transfer — glued SAR currency, To: beneficiary',
    sender: 'stcbank',
    rawSms:
        'Internal outward transfer\nAmount:21.00SAR\nTo:ABDELRAHMAN ABDALLA\nAcc:3583*\nAt:19/04/26 11:07',
    expectedType: TransactionType.transfer,
    expectedAmount: 21.00,
    expectedCurrency: 'SAR',
    expectedMerchant: 'ABDELRAHMAN ABDALLA',
    expectedLast4: '3583',
    expectedOccurredAt: DateTime(2026, 4, 19, 11, 7),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  // Round 3 closure (owner brief §5): an ATM cash deposit may be the user's
  // own cash, so it is a review row with its amount, not income. (Was:
  // income, pending.) The id is kept for traceability.
  const BankSmsGoldenFixture(
    id: 'sa_anb_atm_deposit_income',
    description:
        'ANB ATM deposit — review row (not proven income), بـ:SAR pattern',
    sender: 'anb',
    rawSms:
        'إيداع ATM\nبـ:SAR 4000.00\nالحساب:0017\nبطاقة، مدى،1922\nفي:26-06-15 10:47',
    expectedStatus: ExpectedSmsStatus.review,
  ),
  BankSmsGoldenFixture(
    id: 'sa_anb_govt_traffic_fine',
    description: 'ANB government payment — مدفوعات type, الجهة: payee label',
    sender: 'anb',
    rawSms:
        'مدفوعات وزارة الداخلية\nمن:0017\nبـ:SAR 113\nالجهة:المخالفات المرورية\nالخدمة:سداد مخالفات مرورية-رقم المخالفة\nرقم مرجعي:6824106852\nفي:26-06-15 10:49',
    expectedType: TransactionType.governmentPayment,
    expectedAmount: 113,
    expectedCurrency: 'SAR',
    expectedMerchant: 'المخالفات المرورية',
    expectedOccurredAt: DateTime(2026, 6, 15, 10, 49),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_bsf_pos_three_amounts',
    description:
        'BSF POS — 3 amounts: take بـ SAR 150.00, ignore total-due and balance',
    sender: 'BSF',
    rawSms:
        'شراء عبر نقاط البيع بـ SAR 150.00\nرسوم العملية:0.00\nمن Al-Rajul Al-Amthal for Me\nبطاقة ائتمانية 9221* من خلال Apple Pay\nالمبلغ الإجمالي المستحق SAR 5620.87\nالرصيد المتوفر: SAR 14379.13\nفي 26-06-14 20:12',
    expectedType: TransactionType.payment,
    expectedAmount: 150.00,
    expectedCurrency: 'SAR',
    expectedMerchant: 'Al-Rajul Al-Amthal for Me',
    expectedLast4: '9221',
    expectedBalance: 14379.13,
    expectedOccurredAt: DateTime(2026, 6, 14, 20, 12),
    // Round 5 (owner decision): the text carries a due/doubt word
    // ("المستحق"), so it is kept for review (was pending).
    expectedStatus: ExpectedSmsStatus.review,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_income_sar_glued',
    description:
        'STC Bank add-funds income — ر.س glued to amount, M/D/YYYY date (4-digit year = mdy)',
    sender: 'stcbank',
    rawSms:
        'إضافة أموال لحسابك\nبـ:300.56 ر.س\nعبر:*XXXX\nفي:3/9/2026 11:17 PM',
    expectedType: TransactionType.income,
    expectedAmount: 300.56,
    expectedCurrency: 'SAR',
    expectedOccurredAt: DateTime(2026, 3, 9, 23, 17),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_intl_purchase_april_mdy',
    description:
        'STC Bank international purchase — 4/16/2026 proves 4-digit year is M/D/YYYY (month=16 impossible in dmy)',
    sender: 'stcbank',
    rawSms:
        'عملية انترنت\nبـ:USD 19.99\nمن:NETFLIX\nبطاقة:*7238\nفي:4/16/2026 09:30',
    expectedType: TransactionType.payment,
    expectedAmount: 19.99,
    expectedCurrency: 'USD',
    expectedMerchant: 'NETFLIX',
    expectedLast4: '7238',
    expectedOccurredAt: DateTime(2026, 4, 16, 9, 30),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_pos_april_dmy',
    description:
        'STC Bank POS — 16/04/26 proves 2-digit year is D/M/YY (day=16>12, unambiguous dmy)',
    sender: 'stcbank',
    rawSms:
        'شراء PoS\nبـ:SAR 45.00\nمن:STARBUCKS\nبطاقة:*7238\nفي:16/04/26 14:00',
    expectedType: TransactionType.payment,
    expectedAmount: 45.00,
    expectedCurrency: 'SAR',
    expectedMerchant: null,
    expectedFundingSource: null,
    expectedLast4: '7238',
    expectedOccurredAt: DateTime(2026, 4, 16, 14, 0),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_transfer_arabic',
    description:
        'STC Bank Arabic outward transfer — حوالة type, ر.س glued, DD/MM/YY',
    sender: 'stcbank',
    rawSms:
        'حوالة داخلية صادرة\nبـ:300.56ر.س\nإلى:SARRAA ALASMARI\nحساب:5438*\nفي:09/03/26 23:23',
    expectedType: TransactionType.transfer,
    expectedAmount: 300.56,
    expectedCurrency: 'SAR',
    expectedMerchant: 'SARRAA ALASMARI',
    expectedOccurredAt: DateTime(2026, 3, 9, 23, 23),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_stc_bank_intl_foreign_only',
    description:
        'STC Bank international — foreign amount only (no local conversion shown)',
    sender: 'stcbank',
    rawSms:
        'عملية انترنت\nبـ:USD 248.95\nمن:ALIEXP\nبطاقة:*7238\nفي:16/04/26 10:48',
    expectedType: TransactionType.payment,
    expectedAmount: 248.95,
    expectedCurrency: 'USD',
    expectedMerchant: 'ALIEXP',
    expectedLast4: '7238',
    expectedOccurredAt: DateTime(2026, 4, 16, 10, 48),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_albilad_mada_pos',
    description: 'Albilad mada POS — مبلغ: amount, لدى: merchant',
    sender: 'البلاد',
    rawSms:
        'مشتريات نقاط البيع\nبطاقة: **1519; مدى, Apple PAY\nمبلغ: 7.00 SAR\nلدى: BOOFAYAH NJOOD\nفي: 2023-10-22 07:24',
    expectedType: TransactionType.payment,
    expectedAmount: 7.00,
    expectedCurrency: 'SAR',
    expectedMerchant: 'BOOFAYAH NJOOD',
    expectedLast4: '1519',
    expectedOccurredAt: DateTime(2023, 10, 22, 7, 24),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'sa_aljazira_biqeema_label',
    description: 'Bank Aljazira — بقيمة amount label, لدى merchant',
    sender: 'هذا الجزيرة',
    rawSms:
        'معاملة التجارة الإلكترونية عبر مدى - الشراء عبر الإنترنت (Apple Pay)\nبقيمة 143.80 SAR\nمن:6001\nلدى Ninja\nبطاقة مدى 8277\nفي 2026-06-13 19:19',
    expectedType: TransactionType.payment,
    expectedAmount: 143.80,
    expectedCurrency: 'SAR',
    expectedMerchant: 'Ninja',
    expectedLast4: '8277',
    expectedOccurredAt: DateTime(2026, 6, 13, 19, 19),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
  BankSmsGoldenFixture(
    id: 'ae_dubai_bank_card_payment',
    description:
        'Dubai Bank credit card payment — تأكيد السداد type, DD-MM-YYYY, thousands balance',
    sender: 'بنك دبي',
    rawSms:
        'بطاقة إئتمانية: تأكيد السداد\nبطاقة: XX2678;إئتمانية\nمبلغ: 250.93  SAR\nرصيد: 18,000.00 SAR\nفي: 24-01-2025',
    expectedType: TransactionType.creditCardPayment,
    expectedAmount: 250.93,
    expectedCurrency: 'SAR',
    expectedLast4: '2678',
    expectedBalance: 18000.00,
    expectedOccurredAt: DateTime(2025, 1, 24),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
];

final parserGateFixtures = [
  BankSmsGoldenFixture(
    id: 'known_bank_known_merchant_auto_confirm',
    description:
        'Known sender and previously confirmed merchant can auto-confirm',
    sender: 'SNB',
    rawSms: '''
عملية شراء
بطاقة:مدى;****4521
مبلغ:SAR 45.00
لدى:NETFLIX
في:2026-04-08 12:45
الرصيد:SAR 2,310.50''',
    expectedType: TransactionType.payment,
    expectedAmount: 45,
    expectedCurrency: 'SAR',
    expectedMerchant: 'NETFLIX',
    expectedLast4: '4521',
    expectedBalance: 2310.50,
    expectedOccurredAt: DateTime(2026, 4, 8, 12, 45),
    expectedStatus: ExpectedSmsStatus.autoConfirm,
    knownMerchantCategoryKey: 'subscriptions',
  ),
  BankSmsGoldenFixture(
    id: 'unknown_merchant_high_parse_pending',
    description:
        'High parse confidence still stays pending for unknown merchant',
    sender: 'SNB',
    rawSms: '''
عملية شراء
بطاقة:مدى;****4521
مبلغ:SAR 82.00
لدى:LOCAL ROASTER
في:2026-04-08 18:30''',
    expectedType: TransactionType.payment,
    expectedAmount: 82,
    expectedCurrency: 'SAR',
    expectedMerchant: 'LOCAL ROASTER',
    expectedLast4: '4521',
    expectedOccurredAt: DateTime(2026, 4, 8, 18, 30),
    expectedStatus: ExpectedSmsStatus.pending,
  ),
];
