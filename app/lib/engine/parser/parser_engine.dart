import '../../domain/finance/money_input.dart';
import '../models/parsed_transaction.dart';
import '../models/transaction_source.dart';
import '../models/transaction_type.dart';
import 'amount_candidate.dart';
import 'bank_profile.dart';
import 'catalog_rule_matcher.dart';
import 'merchant_sanity.dart';
import 'normalizer.dart';
import 'parse_result.dart';
import 'transaction_timestamp_extractor.dart';

/// محرّك تحليل رسائل البنك → [ParsedTransaction].
///
/// Dart نقي بالكامل (لا يستورد flutter) ليُختبر بـ golden tests.
/// مبدئي وقابل للتوسعة: يغطّي القوالب التمثيلية السعودية (docs/specs/SAUDI_MARKET_SPEC.md).
class ParserEngine {
  const ParserEngine();

  // ── تعابير الاستخراج ──
  // Shared with Normalizer.separateGluedCurrency — a code this engine can match
  // but the normaliser cannot un-glue (or vice versa) is exactly the gap that
  // let `SAR129.90` parse as `90`.
  static const String _currencyPattern = Normalizer.isoCurrencyAlternation;
  static final RegExp _currency =
      RegExp('(?:$_currencyPattern)', caseSensitive: false);
  static final RegExp _last4Star = RegExp(r'\*{2,}\s*([0-9]{4})');
  static final RegExp _last4SingleStar = RegExp(r'\*\s*([0-9]{4})');
  static final RegExp _last4TrailingStar = RegExp(
    r'(?:card|بطاقة|account|حساب|acc)\s*:?\s*\*?([0-9]{4,6})\*',
    caseSensitive: false,
  );
  static final RegExp _last4CardLoose = RegExp(
    r'(?:card|بطاقة|credit|ائتمانية|إئتمانية)[^0-9]{0,40}(?:xx|\*\*)?([0-9]{4})(?:\*|;|\b)',
    caseSensitive: false,
  );
  static final RegExp _last4CardContext = RegExp(
    r'(?:card|بطاقة|mada|مدى|visa|apple pay|ابل باي|عبر|via)\s*:?\s*\*?([0-9]{4})(?![0-9])',
    caseSensitive: false,
  );
  static final RegExp _last4Ending =
      RegExp(r'(?:ending|تنتهي\s*بـ?)\s*([0-9]{4})', caseSensitive: false);
  static final RegExp _dateTime = RegExp(
    r'([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[ T]([0-9]{2}):([0-9]{2})'
    '${TransactionTimestampExtractor.meridiem}'
    r')?',
    caseSensitive: false,
  );
  static final RegExp _dateTimeDmy = RegExp(
    r'\b([0-9]{1,2})[/-]([0-9]{1,2})[/-]([0-9]{2,4})(?:\s+(?:at\s*)?([0-9]{1,2}):([0-9]{2})'
    '${TransactionTimestampExtractor.meridiem}'
    r')?(?![0-9a-z_])',
    caseSensitive: false,
  );
  // DD/MM with no year (e.g. "14/03 الساعه 22:29") — assumes current year.
  static final RegExp _dateDmNoYear = RegExp(
    r'\b([0-9]{1,2})/([0-9]{1,2})\b'
    r'(?:[^\d]{1,20}([0-9]{1,2}):([0-9]{2})'
    '${TransactionTimestampExtractor.meridiem}'
    r')?',
    caseSensitive: false,
  );
  static final RegExp _dateYmdShort =
      RegExp(r'\b([0-9]{2})-([0-9]{2})-([0-9]{2})\b(?!-[0-9])'
          r'(?:\s+([0-9]{1,2}):([0-9]{2}))?');
  static final RegExp _dateDmyDash =
      RegExp(r'\b([0-9]{1,2})-([0-9]{1,2})-([0-9]{4})\b');
  // Matches "CURRENCY AMOUNT (CURRENCY AMOUNT)" — international purchase
  // with local conversion.
  static final RegExp _intlParens = RegExp(
    r'\b([A-Z]{3})\s*([\d,.]+)\s*\(([A-Z]{3})\s*([\d,.]+)\)',
    caseSensitive: false,
  );
  static final RegExp _intlParensAmountFirst = RegExp(
    r'\b([\d,.]+)\s*([A-Z]{3})\s*\(([\d,.]+)\s*([A-Z]{3})\)',
    caseSensitive: false,
  );
  // "رقم 4907" after a card context word (Egyptian bank style).
  static final RegExp _last4AfterRaqam = RegExp(
    r'(?:card|بطاقة|account|حساب)[^0-9]{0,40}رقم\s*([0-9]{4})(?![0-9])',
    caseSensitive: false,
  );
  // رقم حساب بنكي يتبع كلمة «حساب/account/acct/a/c» (قد يكون مُقنّعًا بـ */x).
  // نمط منفصل عن البطاقة (بطاقة/card) لتجنّب الخلط مع آخر 4 أرقام البطاقة.
  static final RegExp _accountNumberCtx = RegExp(
    r'(?:حساب[ء-ي]*|الحساب|account|acct|a/c)\s*(?:no\.?|number|رقم|#|:)?\s*[x×\*•]*\s*([0-9]{4,20})',
    caseSensitive: false,
  );
  // At/To require a following space or colon to avoid matching "AT" inside "ATM".
  static final RegExp _merchant = RegExp(
      r'(?:^|\b)(لدى|لدي|لـ|عند|الجهة|اسم\s+التاجر|At(?=[\s:])|Merchant|من|إلى|الى|To(?=[\s:]))\s*:?\s*(.+)',
      caseSensitive: false);
  // `\b` above is ASCII-only, so a mid-line Arabic label (`… لدى:CAFE في:…`,
  // a one-line SMS) never matched. Mid-line, only an explicit `label:` counts —
  // a bare preposition (`من حسابك`) is far too common to be a merchant cue.
  static final RegExp _merchantInlineLabel = RegExp(
      r'(?<=[\s;،,])(لدى|لدي|عند|الجهة|اسم\s+التاجر)\s*:\s*(.+)');
  static final RegExp _merchantArabicTo = RegExp(r'^\s*ل(?!ل)\s*:?\s*(.+)');
  static final RegExp _merchantAtSign = RegExp(r'@([^,\n]+)');
  static final RegExp _plainNumber =
      RegExp(r'\b([0-9][0-9,]*(?:\.[0-9]{1,4})?)(?![0-9])');

  static const double pendingThreshold = 0.70;
  static const double genericMaxConfidence = 0.79;

  /// F-016: fixed confidence for a message an admin-authored catalog rule
  /// explicitly matched (with a captured amount) — deterministic, above the
  /// heuristic ceiling, below 1.0 so downstream review affordances survive.
  ///
  /// Only granted when the rule's amount is CORROBORATED — see
  /// [catalogUncorroboratedMaxConfidence].
  static const double catalogRuleConfidence = 0.95;

  /// C-1 — ceiling for a rule-captured amount this engine's own heuristics
  /// could not independently reproduce.
  ///
  /// Catalog rules are admin-authored content, and the server-side gate that is
  /// supposed to admit only validated rules
  /// (`supabase/functions/catalog-delta/index.ts`, `validation_status='passed'`)
  /// was defeated at the data layer: `0004_parser_lab.sql:15` blanket-stamped
  /// every pre-existing parser `'passed'` without running a golden test. A rule
  /// that has never been validated could therefore set CONFIRMED money with no
  /// human review, on the automatic capture path.
  ///
  /// So confirmation authority is not granted by the rule alone. When the rule
  /// and the independent heuristic extraction agree on the amount, two separate
  /// readings corroborate each other and the deterministic confidence stands.
  /// When only the rule produced the amount, the parse still happens and still
  /// reaches the review queue (≥ [pendingThreshold]) — it just cannot ride
  /// through to auto-confirm. Identical treatment to the `dateAmbiguous` cap in
  /// [_confidence], and deliberately independent of any server state.
  static const double catalogUncorroboratedMaxConfidence = 0.89;

  /// Half a minor unit at 2dp — the two readings come from the same text, so
  /// this only absorbs float representation, never a genuine disagreement.
  static const double _catalogAmountAgreementEpsilon = 0.005;
  static const List<String> _globalFundingWallets = [
    'barq',
    'urpay',
    'stcpay',
    'stc pay',
    'd360',
  ];

  static bool isIgnoredMessage(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
  }) {
    final text = Normalizer.normalizeCurrencyTokens(
      Normalizer.normalize(rawText),
    );
    final bank = BankProfiles.detect(
      text,
      senderId: senderId,
      extraProfiles: bankProfiles,
    );
    return const ParserEngine()._isIgnored(text.toLowerCase(), bank);
  }

  ParseResult parse(
    String rawText, {
    String? senderId,
    List<BankProfile> bankProfiles = const [],
    List<CatalogParserRule> catalogRules = const [],
    String defaultCurrency = 'SAR',
  }) {
    var text = Normalizer.normalizeCurrencyTokens(
      Normalizer.normalize(rawText),
    );
    final bank = BankProfiles.detect(
      text,
      senderId: senderId,
      extraProfiles: bankProfiles,
    );
    text = _applyCurrencyAliases(text, bank);
    // After bank aliases too: an alias maps a bank's own token to an ISO code
    // and can itself produce a glued `SAR129.90`.
    text = Normalizer.separateGluedCurrency(text);
    final lines = text.split('\n');
    final lower = text.toLowerCase();

    if (_isIgnored(lower, bank)) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

    // F-016 — catalog rules are the FIRST authority. The winning rule (sender
    // eligibility + message match + priority) supplies transaction type and
    // every field it actually captured; the engine's own extraction below
    // remains the explicit fallback for fields the rule does not produce and
    // for messages no rule matches (zero behavioural change in that case).
    // Rules match the RAW text — the same contract the admin authors against
    // and the Parser Lab / parser-test verify.
    final catalogMatch = matchCatalogRule(
      catalogRules,
      senderId: senderId,
      messageText: rawText,
    );

    var type = catalogMatch != null
        ? _catalogRuleType(catalogMatch.rule)
        : _detectType(lower, bank);
    final amountExtraction = _extractAmounts(lines, text: text, bank: bank);
    final ruleAmount = parseCatalogAmount(catalogMatch?.amountText);
    final amount = ruleAmount ?? amountExtraction.transactionAmount;

    // ليست معاملة مالية واضحة → تُتجاهَل (§24.6).
    if (amount == null && type == TransactionType.unknown) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }
    if (amount == null) {
      return ParseResult.notTransaction(bankKey: bank?.bankKey);
    }

    final source = _detectSource(lower, bank);
    final merchantResult = _extractMerchantAndSource(lines, bank: bank);
    // F-015 — a rule-captured merchant passes through the SAME cleaner as the
    // heuristic one. All 12 seeded catalog rules capture the merchant greedily
    // to end of line, so accepting the raw capture put the trailing date clause
    // into every rule-matched merchant.
    //
    // Normalisation belongs in the engine, not in each rule's regex: the rules
    // are admin-authored DATA, and requiring every future author to get the
    // boundary right is exactly how all twelve got it wrong. The rule remains
    // the extraction authority; the engine only trims the boundary.
    final ruleMerchant = catalogMatch?.merchant;
    final merchant = (ruleMerchant != null
            ? _cleanMerchant(ruleMerchant) ?? ruleMerchant
            : null) ??
        merchantResult.merchant;
    if (catalogMatch == null &&
        type == TransactionType.payment &&
        _looksLikeBankAtmCardTransaction(
          lower,
          merchant: merchant,
        )) {
      type = TransactionType.withdrawal;
    }
    final readCurrency = parseCatalogCurrency(catalogMatch?.currencyText) ??
        amountExtraction.currency ??
        _extractCurrency(text);
    final currency = readCurrency ?? defaultCurrency;
    final last4 = _extractLast4(text);
    final accountNumber = _extractAccountNumber(text);
    final ruleBalance = parseCatalogAmount(catalogMatch?.balanceText);
    final balance = ruleBalance ?? amountExtraction.balance;
    final dateResult = _extractDateResult(text, bank: bank);
    final occurredAt = dateResult.date;

    // F-016: an explicitly matched catalog rule that captured the amount is a
    // deterministic admin-authored decision — it does not compete with the
    // heuristic confidence ladder (and must not fall under pendingThreshold
    // just because the heuristics found the message unusual).
    //
    // C-1: but it only carries CONFIRMATION authority when this engine's own
    // extraction independently reproduced the same amount. An admin rule that
    // reads an amount nothing else in the message corroborates is capped below
    // the auto-confirm threshold and routed to review instead.
    final catalogAmountCorroborated = ruleAmount != null &&
        amountExtraction.transactionAmount != null &&
        (ruleAmount - amountExtraction.transactionAmount!).abs() <
            _catalogAmountAgreementEpsilon;
    final confidence = catalogMatch != null && ruleAmount != null
        ? (catalogAmountCorroborated
            ? catalogRuleConfidence
            : catalogUncorroboratedMaxConfidence)
        : _confidence(
            bank: bank,
            senderMatched: bank?.matchesSender(senderId) ?? false,
            amount: amount,
            type: type,
            currencyResolved: _extractCurrency(text) != null,
            merchant: merchant,
            date: occurredAt,
            ambiguousAmount: amountExtraction.hasAmbiguity,
            dateAmbiguous: dateResult.ambiguous,
          );
    if (confidence < pendingThreshold) {
      return ParseResult.notTransaction(
          bankKey: bank?.bankKey, amountDetected: true);
    }

    final txn = ParsedTransaction(
      amountText: catalogMatch?.amountText != null && ruleAmount != null
          ? catalogMatch!.amountText
          : amountExtraction.transactionAmountText,
      amount: amount,
      currency: currency,
      type: type == TransactionType.unknown ? TransactionType.payment : type,
      source: source,
      rawMerchant: MerchantSanity.forMessage(merchant, text),
      cardLast4: last4,
      accountNumber: accountNumber,
      balanceAfterText: ruleBalance != null
          ? catalogMatch!.balanceText
          : amountExtraction.balanceText,
      balanceAfter: balance,
      occurredAt: occurredAt,
      foreignAmountText: amountExtraction.foreignAmountText,
      foreignAmount: amountExtraction.foreignAmount,
      foreignCurrency: amountExtraction.foreignCurrency,
      fundingSource: merchantResult.fundingSource,
      parseConfidence: confidence,
    );

    return ParseResult.success(
      txn,
      bankKey: bank?.bankKey,
      catalogRuleId: catalogMatch?.rule.id,
      catalogAmountCorroborated:
          catalogMatch != null && ruleAmount != null
              ? catalogAmountCorroborated
              : null,
      typeUndetected: type == TransactionType.unknown,
      amountAmbiguous: amountExtraction.hasAmbiguity,
      dateAmbiguous: dateResult.ambiguous,
      currencyDefaulted: readCurrency == null,
    );
  }

  // ── helpers ──

  /// F-016: the matched rule's declared type. `extracted_fields.type` (a
  /// literal, not a group name) wins over the coarser `transaction_type`
  /// column when both are present.
  TransactionType _catalogRuleType(CatalogParserRule rule) =>
      catalogRuleType(rule);

  TransactionType _detectType(String lower, BankProfile? bank) {
    if (bank != null) {
      for (final entry in bank.typeRules.entries) {
        if (_containsAny(
            lower, entry.value.map((e) => e.toLowerCase()).toList())) {
          return entry.key;
        }
      }
    }
    if (_containsAny(lower, ['استرداد', 'رد مبلغ', 'refund', 'reversal'])) {
      return TransactionType.refund;
    }
    if (_containsAny(lower, ['سحب', 'صراف', 'atm'])) {
      return TransactionType.withdrawal;
    }
    if (_containsAny(lower, ['تحويل', 'حوالة', 'transfer'])) {
      return TransactionType.transfer;
    }
    if (_containsAny(lower, ['راتب', 'إيداع', 'ايداع', 'deposit', 'salary'])) {
      return TransactionType.income;
    }
    if (_containsAny(lower, [
      'شراء',
      'دفع',
      'خصم',
      'purchase',
      'payment',
      'نقاط بيع',
      'pos',
      'trx.',
      'trx of',
      'trx. of',
      'successful transaction',
      'transaction of',
      'debit card',
    ])) {
      return TransactionType.payment;
    }
    return TransactionType.unknown;
  }

  TransactionSource _detectSource(String lower, BankProfile? bank) {
    if (_containsAny(lower, ['stc pay', 'stcpay', 'محفظة', 'wallet'])) {
      return TransactionSource.wallet;
    }
    if (_containsAny(lower, ['بطاقة', 'مدى', 'mada', 'card', 'ending'])) {
      return TransactionSource.card;
    }
    return bank?.defaultSource ?? TransactionSource.bank;
  }

  bool _looksLikeBankAtmCardTransaction(
    String lower, {
    required String? merchant,
  }) {
    if (merchant == null || merchant.trim().isEmpty) return false;
    final hasDebitCard = lower.contains('debit card');
    final hasGenericTransaction = _containsAny(lower, const [
      'successful transaction',
      'transaction of',
    ]);
    if (!hasDebitCard || !hasGenericTransaction) return false;
    return BankProfiles.isBankMerchant(merchant);
  }

  _AmountExtraction _extractAmounts(
    List<String> lines, {
    required String text,
    required BankProfile? bank,
  }) {
    final intl = _extractInternationalParens(text);
    if (intl != null) return intl;

    final candidates = <AmountCandidate>[];
    for (final line in lines) {
      for (final match in _plainNumber.allMatches(line)) {
        final raw = match.group(1)!;
        String normalized;
        try {
          normalized = normalizeLocalizedDecimal(raw);
        } on Exception {
          continue;
        }
        final parsed = double.tryParse(normalized);
        if (parsed == null) continue;
        candidates.add(_classifyAmountCandidate(
          line: line,
          raw: raw,
          value: parsed,
          start: match.start,
          end: match.end,
          bank: bank,
        ));
      }
    }

    final balanceCandidates =
        candidates.where((c) => c.kind == AmountCandidateKind.balance);
    final balanceCandidate =
        balanceCandidates.isEmpty ? null : balanceCandidates.first;
    // HEURISTIC-ONLY projection; durable balance uses balanceText.
    final balance = balanceCandidate?.value;
    final balanceText = balanceCandidate == null
        ? null
        : normalizeLocalizedDecimal(balanceCandidate.raw);
    final transactionCandidates = candidates
        .where((c) => c.isStrongTransaction)
        .toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    if (transactionCandidates.isEmpty) {
      return _AmountExtraction(
        transactionAmount: null,
        transactionAmountText: null,
        currency: null,
        balance: balance,
        balanceText: balanceText,
        hasAmbiguity: false,
        candidates: candidates,
        foreignAmount: null,
        foreignAmountText: null,
        foreignCurrency: null,
      );
    }

    final top = transactionCandidates.first;
    // HEURISTIC-ONLY ambiguity ranking. Persisted money comes from top.raw.
    final strongDistinct = transactionCandidates
        .where((c) => (c.value - top.value).abs() > 0.009)
        .where((c) => (top.score - c.score).abs() <= 0.20)
        .isNotEmpty;
    return _AmountExtraction(
      // HEURISTIC-ONLY ParsedTransaction projection; canonical text is top.raw.
      transactionAmount: top.value,
      transactionAmountText: normalizeLocalizedDecimal(top.raw),
      currency: _extractCurrency(
          _window(top.line, top.line.indexOf(top.raw), before: 16, after: 16)),
      balance: balance,
      balanceText: balanceText,
      hasAmbiguity: strongDistinct,
      candidates: candidates,
      foreignAmount: null,
      foreignAmountText: null,
      foreignCurrency: null,
    );
  }

  _AmountExtraction? _extractInternationalParens(String text) {
    final match = _intlParens.firstMatch(text);
    if (match != null) {
      final foreignText = normalizeLocalizedDecimal(match.group(2)!);
      final localText = normalizeLocalizedDecimal(match.group(4)!);
      final foreignAmount = double.tryParse(foreignText);
      final localAmount = double.tryParse(localText);
      if (foreignAmount != null && localAmount != null) {
        final balance = _extractBalanceFromText(text);
        return _AmountExtraction(
          transactionAmount: localAmount,
          transactionAmountText: localText,
          currency: match.group(3)!.toUpperCase(),
          balance: balance?.value,
          balanceText: balance?.text,
          hasAmbiguity: false,
          candidates: const [],
          foreignAmount: foreignAmount,
          foreignAmountText: foreignText,
          foreignCurrency: match.group(1)!.toUpperCase(),
        );
      }
    }

    final amountFirst = _intlParensAmountFirst.firstMatch(text);
    if (amountFirst == null) return null;
    final foreignText = normalizeLocalizedDecimal(amountFirst.group(1)!);
    final localText = normalizeLocalizedDecimal(amountFirst.group(3)!);
    final foreignAmount = double.tryParse(foreignText);
    final localAmount = double.tryParse(localText);
    if (foreignAmount == null || localAmount == null) return null;
    final balance = _extractBalanceFromText(text);
    return _AmountExtraction(
      transactionAmount: localAmount,
      transactionAmountText: localText,
      currency: amountFirst.group(4)!.toUpperCase(),
      balance: balance?.value,
      balanceText: balance?.text,
      hasAmbiguity: false,
      candidates: const [],
      foreignAmount: foreignAmount,
      foreignAmountText: foreignText,
      foreignCurrency: amountFirst.group(2)!.toUpperCase(),
    );
  }

  ({double value, String text})? _extractBalanceFromText(String text) {
    final lines = text.split('\n');
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (!_containsAny(lower, const [
        'الرصيد',
        'رصيد:',
        'balance',
        'available',
        'wallet balance',
        'المتاح',
      ])) {
        continue;
      }
      final number = _plainNumber.firstMatch(line);
      if (number == null) continue;
      try {
        final normalized = normalizeLocalizedDecimal(number.group(1)!);
        final value = double.tryParse(normalized);
        if (value != null) return (value: value, text: normalized);
      } on Exception {
        continue;
      }
    }
    return null;
  }

  AmountCandidate _classifyAmountCandidate({
    required String line,
    required String raw,
    required double value,
    required int start,
    required int end,
    required BankProfile? bank,
  }) {
    final l = line.toLowerCase();
    final balanceWords = [
      'الرصيد',
      'رصيد',
      'الرصيد المتوفر',
      'رصيد:',
      'رصيد ',
      'balance',
      'available',
      'available bal',
      'avl bal',
      'bal.',
      'bal',
      'المتاح',
      'الرصيد المتاح',
      ...?bank?.balanceRules.map((item) => item.toLowerCase()),
    ];
    final amountWords = [
      'مبلغ',
      'مبلغ العملية',
      'المبلغ',
      'amount',
      'amt',
      'transaction of',
      'بقيمة',
      ...?bank?.amountRules.map((item) => item.toLowerCase()),
    ];
    const transactionWords = [
      'شراء',
      'خصم',
      'دفع',
      'سحب',
      'تحويل',
      'purchase',
      'payment',
      'paid',
      'spent',
      'debit',
      'successful transaction',
      'transaction of',
      'withdrawal',
      'transfer',
      'pos',
    ];
    const referenceWords = [
      'ref',
      'reference',
      'auth',
      'authorization',
      'رقم العملية',
      'مرجع',
      'عملية رقم',
      'otp',
      'رمز',
      'code',
    ];
    final feeWords = [
      'fee',
      'fees',
      'tax',
      'vat',
      'charge',
      'commission',
      'الرسوم/الضريبة',
      'رسوم العملية',
      'الرسوم',
      'رسوم',
      'الضريبة',
      'عمولة',
      ...?bank?.feeRules.map((item) => item.toLowerCase()),
    ];
    final totalDueWords = [
      'المبلغ الإجمالي المستحق',
      'total due',
      'إجمالي مستحق',
      ...?bank?.totalDueRules.map((item) => item.toLowerCase()),
    ];
    const phoneHelpWords = [
      'call',
      'phone',
      'hotline',
      'اتصل',
      'للاتصال',
    ];
    const fxWords = [
      'fx',
      'rate',
      'exchange',
      'سعر الصرف',
    ];

    if (_numberBelongsToDate(line, raw)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.dateTime,
        score: 1,
      );
    }
    if (_hasNearbyKeyword(
      l,
      start,
      const ['from', 'from account', 'account', 'acct', 'a/c'],
      before: 16,
      after: 0,
    )) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.referenceNumber,
        score: 0.95,
      );
    }
    // A card suffix is exactly four DIGITS. `9.75` or `99.5` is four characters
    // and used to be taken for one on any card line, dropping the amount (and
    // with it the whole parse). A bare four-digit number written against a
    // currency is money unless a mask marker (`****`, `ending`) introduces it.
    if (_fourDigits.hasMatch(raw) &&
        !_isCurrencyAdjacentAmount(line, start, end) &&
        (_hasNearbyKeyword(
                l,
                start,
                const [
                  '****',
                  '*',
                  'ending',
                  'بطاقة',
                  'card',
                  'mada',
                  'مدى',
                  'visa',
                  'apple pay',
                  'ابل باي',
                  'عبر',
                  'via',
                ],
                before: 24,
                after: 24) ||
            _lineHasCardContext(l))) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.cardLast4,
        score: 1,
      );
    }
    if (_isParenthesized(line, start, end) ||
        _hasNearbyKeyword(l, start, referenceWords, before: 24, after: 10) ||
        _hasNearbyKeyword(l, start, feeWords, before: 24, after: 12) ||
        _hasNearbyKeyword(l, start, totalDueWords, before: 32, after: 12) ||
        _hasNearbyKeyword(l, start, phoneHelpWords, before: 16, after: 6) ||
        _hasNearbyKeyword(l, start, fxWords, before: 12, after: 4)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.referenceNumber,
        score: 0.95,
      );
    }
    if (_hasNearbyKeyword(l, start, balanceWords, before: 32, after: 8)) {
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.balance,
        score: 0.95,
      );
    }

    final hasAmountWord =
        _hasNearbyKeyword(l, start, amountWords, before: 36, after: 10);
    final hasTransactionWord = _containsAny(l, transactionWords);
    final hasCurrency =
        _currency.hasMatch(_window(line, start, before: 12, after: 12));
    if (hasAmountWord || hasTransactionWord || hasCurrency) {
      var score = 0.55;
      if (hasAmountWord) score += 0.20;
      if (hasTransactionWord) score += 0.15;
      if (hasCurrency) score += 0.10;
      return AmountCandidate(
        value: value,
        raw: raw,
        line: line,
        kind: AmountCandidateKind.transactionAmount,
        score: score.clamp(0.0, 1.0),
      );
    }

    return AmountCandidate(
      value: value,
      raw: raw,
      line: line,
      kind: AmountCandidateKind.unknown,
      score: 0.2,
    );
  }

  ({String? merchant, String? fundingSource}) _extractMerchantAndSource(
    List<String> lines, {
    required BankProfile? bank,
  }) {
    final bankTokens = bank?.merchantRules ?? const <String>[];
    for (final line in lines) {
      final m = _merchant.firstMatch(line);
      if (m != null) {
        final value = _cleanMerchant(m.group(2)!);
        if (value != null) {
          return _resolveMerchantSource(value, m.group(1), bank);
        }
      }
      final inline = _merchantInlineLabel.firstMatch(line);
      if (inline != null) {
        final value = _cleanMerchant(inline.group(2)!);
        if (value != null) {
          return _resolveMerchantSource(value, inline.group(1), bank);
        }
      }
      final arabicTo = _merchantArabicTo.firstMatch(line);
      if (arabicTo != null) {
        final value = _cleanMerchant(arabicTo.group(1)!);
        if (value != null) {
          return (merchant: value, fundingSource: null);
        }
      }
      final atSign = _merchantAtSign.firstMatch(line);
      if (atSign != null) {
        final value = _cleanMerchant(atSign.group(1)!);
        if (value != null) {
          return (merchant: value, fundingSource: null);
        }
      }
      for (final token in bankTokens) {
        final idx = line.toLowerCase().indexOf(token.toLowerCase());
        if (idx == -1) continue;
        final value = _cleanMerchant(line.substring(idx + token.length));
        if (value != null) return _resolveMerchantSource(value, token, bank);
      }
    }
    return (merchant: null, fundingSource: null);
  }

  ({String? merchant, String? fundingSource}) _resolveMerchantSource(
    String value,
    String? preposition,
    BankProfile? bank,
  ) {
    final wallets = [
      ..._globalFundingWallets,
      ...?bank?.fundingWallets,
    ].map((item) => item.toLowerCase()).toSet();
    final lowerValue = value.toLowerCase();
    final isWallet = wallets.any((wallet) => lowerValue == wallet);
    final prep = preposition?.toLowerCase().trim();
    final isFundingContext = prep == 'من' || prep == 'من:' || prep == 'at';
    if (isWallet && isFundingContext) {
      return (merchant: null, fundingSource: value);
    }
    return (merchant: value, fundingSource: null);
  }

  String? _cleanMerchant(String raw) {
    var value = raw.trim();
    // تنظيف لاحقات/علامات شائعة.
    value = value
        .replaceAll(
            // F-015: `بتاريخ` ("on date") is the form the Saudi and Egyptian
            // banks actually use, and it was missing here — so the date rode
            // into the merchant name and then into categorisation.
            //
            // F-015b: the clause must START at a word boundary. Without the
            // leading `(?:^|\s)` this alternation matched the "ON" inside
            // "AMAZON" and truncated the merchant to "AMAZ" — silently, in
            // shipped code, for one of the most common merchants there is.
            // `في:` (one-line SNB layout) ends the merchant just like `في `.
            RegExp(r'(?:^|\s)(?:بتاريخ|في|on|يوم|الساعه|الساعة)(?:[\s:]|$).*$',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'(?:ref|reference|for more details|call)(?:[#\s]|$).*$',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(r'(?:الرصيد|balance|available|avl\s+bal|المتاح)(?:[\s:]|$).*$',
                caseSensitive: false),
            '')
        .replaceAll(
            RegExp(
              r'\s+(?:ABU DHABI|DUBAI|SHARJAH|AJMAN|FUJAIRAH|RAS AL KHAIMAH|UMM AL QUWAIN)\s+AE[.;]?\s*$',
              caseSensitive: false,
            ),
            '')
        .replaceAll(RegExp(r'[.;،]+$'), '')
        .trim();
    if (RegExp(r'^\d{1,2}:\d{2}\s*(?:am|pm)?\b', caseSensitive: false)
        .hasMatch(value)) {
      return null;
    }
    if (value.isNotEmpty &&
        !_startsWithCurrency(value) &&
        !RegExp(r'^\d+$').hasMatch(value)) {
      return value;
    }
    return null;
  }

  String? _extractCurrency(String text) {
    final m = _currency.firstMatch(text);
    return m?.group(0)?.toUpperCase();
  }

  /// يستخرج رقم/جزء رقم الحساب البنكي إذا ذُكر صراحةً بجوار كلمة «حساب/account».
  /// أفضل جهد فقط — يُستخدم لاحقًا للمطابقة مع bank_account_number؛ لو لم يطابق
  /// أي حساب فلا ضرر (يُتجاهَل). لا يمسّ استخراج آخر 4 أرقام البطاقة.
  String? _extractAccountNumber(String text) {
    final match = _accountNumberCtx.firstMatch(text);
    if (match == null) return null;
    final digits = match.group(1)!.replaceAll(RegExp(r'[^0-9]'), '');
    return digits.length >= 4 ? digits : null;
  }

  String? _extractLast4(String text) {
    final m = _last4Star.firstMatch(text) ?? _last4Ending.firstMatch(text);
    if (m != null) return m.group(1);
    final trailingStar = _last4TrailingStar.firstMatch(text);
    if (trailingStar != null) return _last4(trailingStar.group(1)!);
    final cardLoose = _last4CardLoose.firstMatch(text);
    if (cardLoose != null) return cardLoose.group(1);
    final cardContext = _last4CardContext.firstMatch(text);
    if (cardContext != null) return cardContext.group(1);
    final afterRaqam = _last4AfterRaqam.firstMatch(text);
    if (afterRaqam != null) return afterRaqam.group(1);
    final singleStar = _last4SingleStar.firstMatch(text);
    return singleStar?.group(1);
  }

  // Returns the extracted date plus a flag indicating whether the date was
  // genuinely ambiguous (day and month both ≤ 12 with no profile disambiguation).
  // Ambiguous = true means the result must stay in pending, not auto-confirm.
  ({DateTime? date, bool ambiguous}) _extractDateResult(String text,
      {required BankProfile? bank}) {
    final m = _dateTime.firstMatch(text);
    if (m != null) {
      final year = int.parse(m.group(1)!);
      final month = int.parse(m.group(2)!);
      final day = int.parse(m.group(3)!);
      final hour = m.group(4) != null
          ? _hourWithMeridiem(int.parse(m.group(4)!), m.group(6))
          : 0;
      final minute = m.group(5) != null ? int.parse(m.group(5)!) : 0;
      return (
        date: _safeDate(year, month, day, hour, minute),
        ambiguous: false
      );
    }
    final ymdShort = _dateYmdShort.firstMatch(text);
    if (ymdShort != null) {
      final year = int.parse(ymdShort.group(1)!);
      final month = int.parse(ymdShort.group(2)!);
      final day = int.parse(ymdShort.group(3)!);
      if (year <= 50 && month <= 12 && day <= 31) {
        final hour =
            ymdShort.group(4) != null ? int.parse(ymdShort.group(4)!) : 0;
        final minute =
            ymdShort.group(5) != null ? int.parse(ymdShort.group(5)!) : 0;
        return (
          date: _safeDate(2000 + year, month, day, hour, minute),
          ambiguous: false,
        );
      }
    }
    final dmy = _dateTimeDmy.firstMatch(text);
    if (dmy != null) {
      var day = int.parse(dmy.group(1)!);
      var month = int.parse(dmy.group(2)!);
      final year = _normalizeYear(int.parse(dmy.group(3)!));
      final preferredDateOrder = bank?.preferredDateOrder;
      final yearDigits = dmy.group(3)!.length;

      if (bank?.bankKey == 'stc_bank') {
        // STC Bank uses M/D/YYYY with 4-digit year and D/M/YY with 2-digit year.
        // 4/16/2026 is proof: month=16 is impossible in dmy, so 4-digit = mdy.
        if (yearDigits == 4) {
          final tmp = day;
          day = month;
          month = tmp;
        }
        // 2-digit year keeps dmy order (e.g. 09/03/26 = March 9).
      } else if (preferredDateOrder == 'mdy') {
        final tmp = day;
        day = month;
        month = tmp;
      } else if (day <= 12 &&
          month <= 12 &&
          preferredDateOrder != 'dmy' &&
          preferredDateOrder != 'ymd') {
        // Genuinely ambiguous — both values could be day or month and the
        // profile gives no guidance. Return null with ambiguous=true so the
        // confidence engine routes the transaction to pending_confirmation.
        return (date: null, ambiguous: true);
      }
      final hour = dmy.group(4) != null
          ? _hourWithMeridiem(int.parse(dmy.group(4)!), dmy.group(6))
          : 0;
      final minute = dmy.group(5) != null ? int.parse(dmy.group(5)!) : 0;
      return (
        date: _safeDate(year, month, day, hour, minute),
        ambiguous: false
      );
    }
    // DD/MM with no year — use current year.
    final dm = _dateDmNoYear.firstMatch(text);
    if (dm != null) {
      final day = int.parse(dm.group(1)!);
      final month = int.parse(dm.group(2)!);
      final year = DateTime.now().year;
      final hour = dm.group(3) != null
          ? _hourWithMeridiem(int.parse(dm.group(3)!), dm.group(5))
          : 0;
      final minute = dm.group(4) != null ? int.parse(dm.group(4)!) : 0;
      return (
        date: _safeDate(year, month, day, hour, minute),
        ambiguous: false
      );
    }
    final dashDmy = _dateDmyDash.firstMatch(text);
    if (dashDmy == null) return (date: null, ambiguous: false);
    final day = int.parse(dashDmy.group(1)!);
    final month = int.parse(dashDmy.group(2)!);
    final year = int.parse(dashDmy.group(3)!);
    return (date: _safeDate(year, month, day, 0, 0), ambiguous: false);
  }

  double _confidence({
    required BankProfile? bank,
    required bool senderMatched,
    required double? amount,
    required TransactionType type,
    required bool currencyResolved,
    required String? merchant,
    required DateTime? date,
    required bool ambiguousAmount,
    required bool dateAmbiguous,
  }) {
    var score = 0.10;
    if (bank != null) score += 0.15;
    if (senderMatched) score += 0.10;
    if (amount != null) score += 0.25;
    if (type != TransactionType.unknown) score += 0.15;
    if (currencyResolved) score += 0.10;
    if (merchant != null) score += 0.10;
    if (date != null) score += 0.05;
    if (!ambiguousAmount) score += 0.10;
    if (ambiguousAmount) score -= 0.25;
    final afterGenericCap =
        bank == null ? score.clamp(0.0, genericMaxConfidence) : score;
    // Ambiguous date (day ≤ 12 AND month ≤ 12, unresolvable from profile):
    // cap at 0.89 — just below the 0.92 auto-confirm threshold.
    // This preserves the transaction in the pending queue (≥ 0.70) while
    // guaranteeing a wrong date can never ride through to auto-confirm.
    final afterDateCap =
        dateAmbiguous ? afterGenericCap.clamp(0.0, 0.89) : afterGenericCap;
    return afterDateCap.clamp(0.0, 1.0);
  }

  bool _isIgnored(String lower, BankProfile? bank) {
    final ignoreRules = [
      ...?bank?.ignoreRules.map((item) => item.toLowerCase()),
      'otp',
      'one time password',
      'verification code',
      'security code',
      'رمز الدخول',
      'رمز التحقق',
      'كود التحقق',
      'لا تشاركه',
      'عرض خاص',
      'promo',
      'promotion',
      'marketing',
      'offer',
      'coupon',
      'chequebook',
      'cheque book',
      'checkbook',
      'request will be fulfilled',
      'prize',
      'winner',
      'won',
      'مبروك',
      'جائزة',
      'اربح',
      'اضغط',
      'click',
      'http://',
      'https://',
    ];
    if (_containsAny(lower, ignoreRules)) return true;
    if (_containsAny(lower, [
      'تجميد',
      'تحديث بياناتك',
      'تسجيل خروج',
    ])) {
      return true;
    }
    return _containsAny(lower, [
      'complaint',
      'شكوى',
      'has been closed',
      'تم إغلاق',
    ]);
  }

  String _applyCurrencyAliases(String text, BankProfile? bank) {
    var output = text;
    final aliases = bank?.currencyAliases ?? const <String, String>{};
    for (final entry in aliases.entries) {
      output = output.replaceAll(
        RegExp(RegExp.escape(entry.key), caseSensitive: false),
        entry.value.toUpperCase(),
      );
    }
    return output;
  }

  static final RegExp _fourDigits = RegExp(r'^[0-9]{4}$');
  static final RegExp _maskMarkerBefore = RegExp(
    r'(?:[*xX•]|ending|ends\s+with|تنتهي\s*بـ?|رقم)\s*:?\s*$',
    caseSensitive: false,
  );
  static final RegExp _currencyBefore =
      RegExp('(?:$_currencyPattern)\\s*:?\\s*\$', caseSensitive: false);
  static final RegExp _currencyAfter =
      RegExp('^\\s*(?:$_currencyPattern)\\b', caseSensitive: false);

  /// `SAR 1500` / `1500 SAR`: a four-digit number with a currency token right
  /// against it, and no mask marker in front of it.
  bool _isCurrencyAdjacentAmount(String line, int start, int end) {
    final before = line.substring(start < 12 ? 0 : start - 12, start);
    if (_maskMarkerBefore.hasMatch(before)) return false;
    final after = line.substring(end, end + 8 > line.length ? line.length : end + 8);
    return _currencyBefore.hasMatch(before) || _currencyAfter.hasMatch(after);
  }

  bool _numberBelongsToDate(String line, String raw) {
    for (final pattern in [
      _dateTime,
      _dateYmdShort,
      _dateTimeDmy,
      _dateDmNoYear,
      _dateDmyDash,
    ]) {
      final date = pattern.firstMatch(line);
      if (date == null) continue;
      for (var i = 1; i <= date.groupCount; i++) {
        if (date.group(i) == raw) return true;
      }
    }
    return false;
  }

  bool _containsAny(String haystack, List<String> needles) =>
      needles.any(haystack.contains);

  bool _startsWithCurrency(String value) => RegExp(
        r'^\s*(?:' + _currencyPattern + r')\b',
        caseSensitive: false,
      ).hasMatch(value);

  bool _lineHasCardContext(String lowerLine) => _containsAny(lowerLine, const [
        'بطاقة',
        'card',
        'mada',
        'مدى',
        'visa',
        'apple pay',
        'ابل باي',
      ]);

  bool _hasNearbyKeyword(
    String lowerLine,
    int start,
    List<String> needles, {
    required int before,
    required int after,
  }) {
    final from = (start - before).clamp(0, lowerLine.length).toInt();
    final to = (start + after).clamp(0, lowerLine.length).toInt();
    final context = lowerLine.substring(from, to);
    return needles.any((needle) => context.contains(needle.toLowerCase()));
  }

  String _window(
    String line,
    int start, {
    required int before,
    required int after,
  }) {
    final from = (start - before).clamp(0, line.length).toInt();
    final to = (start + after).clamp(0, line.length).toInt();
    return line.substring(from, to);
  }

  bool _isParenthesized(String line, int start, int end) {
    final open = line.lastIndexOf('(', start);
    if (open == -1) return false;
    final close = line.indexOf(')', end);
    return close != -1 && open < start && close >= end;
  }

  String _last4(String digits) =>
      digits.length <= 4 ? digits : digits.substring(digits.length - 4);

  int _normalizeYear(int year) {
    if (year >= 100) return year;
    return year >= 70 ? 1900 + year : 2000 + year;
  }

  int _hourWithMeridiem(int hour, String? meridiem) =>
      TransactionTimestampExtractor.hourWithMeridiem(hour, meridiem);

  DateTime? _safeDate(int year, int month, int day, int hour, int minute) {
    try {
      final date = DateTime(year, month, day, hour, minute);
      if (date.year != year || date.month != month || date.day != day) {
        return null;
      }
      return date;
    } catch (_) {
      return null;
    }
  }
}

class _AmountExtraction {
  const _AmountExtraction({
    required this.transactionAmount,
    required this.transactionAmountText,
    required this.currency,
    required this.balance,
    required this.balanceText,
    required this.hasAmbiguity,
    required this.candidates,
    this.foreignAmount,
    this.foreignAmountText,
    this.foreignCurrency,
  });

  final double? transactionAmount;
  final String? transactionAmountText;
  final String? currency;
  final double? balance;
  final String? balanceText;
  final bool hasAmbiguity;
  final List<AmountCandidate> candidates;
  final double? foreignAmount;
  final String? foreignAmountText;
  final String? foreignCurrency;
}
