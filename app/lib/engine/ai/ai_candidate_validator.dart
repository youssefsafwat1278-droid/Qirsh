import '../../domain/finance/currency_scale.dart';
import '../models/parsed_transaction.dart';
import '../models/transaction_type.dart';
import '../parser/capture_money.dart';
import '../parser/completion_certainty.dart';
import '../parser/currency_table.dart';
import '../parser/direction_signal.dart';
import '../parser/merchant_sanity.dart';
import '../parser/message_meaning.dart';
import '../parser/normalizer.dart';
import '../parser/parser_engine.dart';
import '../parser/transaction_state_cues.dart';
import 'ai_parser_client.dart';
import 'grounding_check.dart';

/// Outcome of [AiCandidateValidator.validate]. When [accepted] is false the AI
/// candidate must be discarded entirely.
class AiCandidateValidation {
  const AiCandidateValidation.rejected(this.rejectionReason)
      : accepted = false,
        currency = '',
        merchantName = null,
        occurredAt = null,
        currencyFromAccount = false;

  const AiCandidateValidation.accepted({
    required this.currency,
    required this.merchantName,
    required this.occurredAt,
    this.currencyFromAccount = false,
  })  : accepted = true,
        rejectionReason = null;

  final bool accepted;
  final String? rejectionReason;

  /// Upper-cased, validated currency (empty when rejected).
  final String currency;

  /// The AI merchant when grounded in the text, else the local one (or null).
  final String? merchantName;

  /// The AI date when inside the plausibility window, else the local one.
  final DateTime? occurredAt;

  /// 4.4: the message names no currency; [currency] is the matched account's.
  final bool currencyFromAccount;
}

/// Deterministic, side-effect-free gate for an AI parse candidate. It never
/// reads anything that resembles an AI confidence: the tier is decided by the
/// caller from local agreement alone.
class AiCandidateValidator {
  const AiCandidateValidator({DateTime Function()? clock}) : _clock = clock;

  final DateTime Function()? _clock;

  static const Duration _maxAge = Duration(days: 31);
  static const Duration _maxFuture = Duration(days: 1);

  /// Currency spellings beyond what [Normalizer.normalizeCurrencyTokens]
  /// already maps to an ISO code.
  static const Map<String, List<String>> _extraAliases = {
    'USD': [r'$'],
    'EUR': ['€'],
    'GBP': ['£'],
    'JOD': ['دينار أردني', 'دينار اردني'],
  };

  AiCandidateValidation validate({
    required AiParseResponse response,
    required String sanitizedText,
    required ParsedTransaction? localParsed,
    DateTime? referenceTime,
    String? messageText,
    TransactionType? normalizedType,
    String? accountCurrency,
  }) {
    // 4.2: a structured answer that is not a completed movement is never a
    // transaction (the server already returns it as is_transaction=false;
    // checked again here for any other server).
    final messageType = response.messageType;
    if (messageType != null && messageType != 'transaction') {
      return const AiCandidateValidation.rejected(
          'message_type_not_transaction');
    }
    final status = response.status;
    if (status != null && status != 'completed') {
      return const AiCandidateValidation.rejected('status_not_completed');
    }
    // DATA-01 — a declined/failed purchase moved no money, whatever the AI says.
    // Follow-up 13: any meaning other than `record` rejects. The not-completed
    // reason comes first, before any direction check; another non-record
    // meaning rejects after the specific checks, just before acceptance.
    final meaningRejection = meaningRejectionOf(messageText ?? sanitizedText,
        amount: response.amount,
        // A model's "transfer" never decides: transfers are read locally.
        modelDecided: normalizedType != TransactionType.transfer);
    if (meaningRejection == 'transaction_not_completed') {
      return const AiCandidateValidation.rejected('transaction_not_completed');
    }
    // LR-06 — an OTP or an advert / account notice is never a transaction,
    // whatever the AI says (an ignore word inside the grounded merchant name
    // does not count).
    // V1-086: an account-notice line unrelated to the amount (a footer next
    // to a completed movement) does not count.
    if (ParserEngine.isNonTransactionText(
        withoutUnrelatedNotices(messageText ?? sanitizedText, response.amount),
        merchant: _merchantGrounded(response.merchantName, sanitizedText)
            ? response.merchantName
            : null)) {
      return const AiCandidateValidation.rejected('not_a_transaction');
    }
    if (!GroundingCheck.verify(
      amount: response.amount,
      sanitizedText: sanitizedText,
    )) {
      return const AiCandidateValidation.rejected('amount_not_grounded');
    }
    // OR-03 — a limit, balance or minimum-due figure is never the amount.
    if (ParserEngine.isAccountFigure(
        messageText ?? sanitizedText, response.amount)) {
      return const AiCandidateValidation.rejected('amount_is_account_figure');
    }
    // Closure round (follow-up 6 (5)): base + tip/fee/VAT with a stated
    // total — the total charged is the amount, counted once.
    final total = chargedTotal(messageText ?? sanitizedText);
    if (total != null && (response.amount - total).abs() >= 0.005) {
      return const AiCandidateValidation.rejected('amount_not_charged_total');
    }
    final currency = response.currency.trim().toUpperCase();
    var fromAccount = false;
    if (localParsed != null) {
      if (!((response.amount - localParsed.amount).abs() < 0.01)) {
        return const AiCandidateValidation.rejected('amount_mismatch_local');
      }
      if (currency != localParsed.currency.trim().toUpperCase()) {
        return const AiCandidateValidation.rejected('currency_mismatch_local');
      }
    } else if (!currencyGrounded(currency, sanitizedText)) {
      // 4.4: never an AI guess — only the matched account's own currency,
      // and only when the text names no currency that could contradict it.
      final account = accountCurrency?.trim().toUpperCase();
      final named = currencyCodes
          .any((code) => currencyGrounded(code, messageText ?? sanitizedText));
      if (account == null || account != currency || named) {
        return const AiCandidateValidation.rejected('currency_not_grounded');
      }
      fromAccount = true;
    }

    // The exact amount text must be present and canonical for the currency
    // (the same parse the commit path uses), so an accepted candidate can never
    // be legacy-lossy money that forces review.
    final amountText = response.amountText;
    if (amountText == null) {
      return const AiCandidateValidation.rejected('amount_text_missing');
    }
    try {
      parseCaptureMoney(amountText, currency);
    } catch (_) {
      return const AiCandidateValidation.rejected('amount_text_not_canonical');
    }
    // DATA-03 — the committed value is amountText: it must be the grounded
    // amount itself, not a fragment of another number in the text.
    final textAmount =
        double.tryParse(Normalizer.normalize(amountText).replaceAll(',', ''));
    if (textAmount == null ||
        (textAmount - response.amount).abs() >= 0.005 ||
        !GroundingCheck.verify(
            amount: textAmount, sanitizedText: sanitizedText)) {
      return const AiCandidateValidation.rejected('amount_text_not_grounded');
    }

    // The AI type must not contradict the message's own direction wording.
    // Closure round (follow-up 6 (4)): the direction the device books — the
    // structure of the sentence carrying this amount — so a cashback/points
    // line or a footer never contradicts a correct answer.
    if (messageText != null &&
        normalizedType != null &&
        contradictsBooked(messageText, normalizedType,
            amount: response.amount,
            merchant: _merchantGrounded(response.merchantName, sanitizedText)
                ? response.merchantName
                : null)) {
      return const AiCandidateValidation.rejected('direction_contradiction');
    }

    // Direction is required (ValidatedCapture v1): an explicit AI direction or a
    // type that maps to one. Transfer/unknown alone is unresolved.
    final aiDirection = response.direction;
    final hasDirection = aiDirection == 'debit' ||
        aiDirection == 'credit' ||
        (normalizedType != null &&
            (normalizedType.isExpense ||
                normalizedType == TransactionType.income ||
                normalizedType == TransactionType.refund));
    if (!hasDirection) {
      return const AiCandidateValidation.rejected('direction_unresolved');
    }

    final merchant = _merchantGrounded(response.merchantName, sanitizedText)
        ? response.merchantName
        : localParsed?.rawMerchant;

    final reference = (referenceTime ?? _clock?.call() ?? DateTime.now());
    final aiDate = response.occurredAt;
    final dateOk = aiDate != null &&
        !aiDate.isBefore(reference.subtract(_maxAge)) &&
        !aiDate.isAfter(reference.add(_maxFuture));

    if (meaningRejection != null) {
      return AiCandidateValidation.rejected(meaningRejection);
    }
    return AiCandidateValidation.accepted(
      currency: currency,
      merchantName: merchant,
      // The local parser reads the written digits and AM/PM/ص/م exactly; the
      // AI only fills a date the local parse could not find.
      occurredAt: localParsed?.occurredAt ?? (dateOk ? aiDate : null),
      currencyFromAccount: fromAccount,
    );
  }

  /// The ISO codes the server validator accepts (CURRENCY_CODES): the
  /// parser's currency table limited to the DETECTION registry
  /// (`kDetectionCurrencyScale`, a subset of what persisted Money can hold)
  /// (closure round; drift tests ai_currency_codes_test.dart and
  /// _shared/ai_currency_table_drift_test.ts).
  static final List<String> currencyCodes = List.unmodifiable([
    for (final code in CurrencyTable.iso)
      if (kDetectionCurrencyScale.containsKey(code)) code,
  ]);

  /// V1-086 / RR-03 — words that report a completed card or account movement
  /// but are not money words (round 10 removed them from the deterministic
  /// money list). Here they only decide whether an account-notice line
  /// elsewhere may be set aside; they never type or record anything.
  static const List<String> _completionWords = [
    'authorised', 'authorized', 'approved', 'posted', 'direct debit', //
    'standing order', 'payroll',
  ];

  static final RegExp _sentenceCut = RegExp(r'[\n!?؟;؛]|\.(?![0-9])');

  /// V1-086 — [text] without the account-notice sentences ("Credit limit:
  /// SAR 20,000", "Your e-statement is available", "Card activated") that
  /// are unrelated to [amount]: only when a sentence holding the amount
  /// itself names a completed movement (a money word or a completion word),
  /// and only sentences with a notice word and no ignore word or OTP code.
  /// Otherwise unchanged, so an advert, an OTP or a notice whose own
  /// sentence carries the amount stays "not a transaction". Mirrors
  /// `withoutUnrelatedNotices` in `_shared/ai_candidate_validator.ts`.
  static String withoutUnrelatedNotices(String text, double amount) {
    final sentences = Normalizer.normalize(text).split(_sentenceCut);
    bool holds(String s) =>
        GroundingCheck.verify(amount: amount, sanitizedText: s);
    bool completed(String s) {
      final lower = s.toLowerCase();
      return ParserEngine.hasMoneyWord(lower) ||
          _completionWords
              .any((w) => ParserEngine.containsIgnoreWord(lower, w));
    }

    if (!sentences.any((s) => holds(s) && completed(s))) return text;
    final kept = sentences.where((s) {
      if (holds(s)) return true;
      final lower = s.toLowerCase();
      final notice = ParserEngine.noticeWords
          .any((w) => ParserEngine.containsIgnoreWord(lower, w));
      final marker = ParserEngine.hasIgnoreWord(lower) ||
          ParserEngine.isNonTransactionText(lower.replaceAll(
              RegExp(ParserEngine.noticeWords.map(RegExp.escape).join('|')),
              ' '));
      return !notice || marker;
    });
    return kept.join('\n');
  }

  /// Closure round (follow-up 6 (4)): the direction the device books for
  /// [text] — the clause structure ([DirectionSignal.detect]) of the first
  /// sentence that carries [amount] when it decides it, else of the whole
  /// message. "POS purchase SAR 45.00 at SHOP. Credited points 45" is a
  /// debit; "Your account was credited. Amount SAR 300.00" stays a credit.
  ///
  /// A [merchant] name is masked first, as the parser masks it for the type
  /// ("Purchase … at Salary Store" is a purchase).
  static TxnDirection bookedDirection(String text,
      {double? amount, String? merchant}) {
    final name = merchant?.trim() ?? '';
    if (name.length >= 3) {
      text = text.replaceAll(
          RegExp(RegExp.escape(name), caseSensitive: false), ' ');
    }
    if (amount != null && amount.isFinite) {
      // The first sentence naming the amount is the event; a later figure
      // equal to it ("Credited points 45") is not.
      final clause = text.split(_sentenceCut).firstWhere(
          (s) => GroundingCheck.verify(amount: amount, sanitizedText: s),
          orElse: () => '');
      if (clause.isNotEmpty) {
        final d = DirectionSignal.detect(clause);
        if (d != TxnDirection.unknown) return d;
      }
    }
    return DirectionSignal.detect(text);
  }

  /// [DirectionSignal.contradicts] against [bookedDirection].
  static bool contradictsBooked(String text, TransactionType type,
      {double? amount, String? merchant}) {
    final booked = bookedDirection(text, amount: amount, merchant: merchant);
    final typed = DirectionSignal.ofType(type);
    return booked != TxnDirection.unknown &&
        typed != TxnDirection.unknown &&
        booked != typed;
  }

  static final RegExp _totalComponent = RegExp(
    r'(?<![a-z])(?:tips?|gratuity|service charge|fees?|vat|tax)(?![a-z])|'
    r'بقشيش|إكرامية|اكرامية|ضريبة|رسوم|عمولة',
    caseSensitive: false,
  );
  // SM-05: the optional currency slot is a detection currency code (never
  // any three letters: "Total bal 12,345.00" is a balance, not a total), and
  // «الرصيد الإجمالي» (total balance) is not a charged total.
  static final RegExp _chargedTotal = RegExp(
    r'(?:(?<![a-z])(?:grand total|total(?: amount)?(?: charged| paid| debited| deducted)?)'
    r'|(?<!الرصيد\s)(?:الإجمالي|الاجمالي)|إجمالي المبلغ|اجمالي المبلغ|المبلغ الإجمالي|المبلغ الاجمالي|المجموع)'
    r'\s*(?:of|is|:|=)?\s*'
    '(?:(?:${currencyCodes.join('|')})(?![a-z])\\s?)?'
    r'([0-9][0-9,]*(?:\.[0-9]+)?)',
    caseSensitive: false,
  );

  /// The total charged a message states next to a tip, fee, VAT or tax
  /// component ("SAR 100.00 + tip SAR 15.00. Total charged SAR 115.00"), or
  /// null. That total is the amount that left the account; a same-currency
  /// fee is part of it (never a second row). Server twin: `chargedTotal`.
  static double? chargedTotal(String text) {
    final t =
        Normalizer.normalizeCurrencyTokens(Normalizer.normalizeDigits(text));
    if (!_totalComponent.hasMatch(t)) return null;
    final m = _chargedTotal.firstMatch(t);
    if (m == null) return null;
    return double.tryParse(m.group(1)!.replaceAll(',', ''));
  }

  // Several movements in one message (dev siblings, family d): two or more
  // distinct amounts of one currency in the message's movement text
  // ("SAR 120.00 at A; SAR 45.50 at B"). Not when the figures are parts of
  // one movement (a stated total, a tip, fee, VAT or subtotal, an
  // original/equivalent amount, one figure the sum of the others), an account
  // figure (any balance, limit or due word) or a reward: the check is
  // conservative. The caller passes only the sentences the parser reads as
  // movements. Server twin: `separateMovementAmounts`.
  static final RegExp _partOfOneMovement = RegExp(
    r'(?<![a-z])(?:total|subtotal|sub-total|incl\.?|including|inclusive|of which|plus|tips?|gratuity|vat|tax|fees?|'
    r'service|delivery|commission|original(?:ly)?|equivalent|approx(?:\.|imately)?|exchange|rate|cashback|cash back|'
    r'points?|rewards?|miles|refund(?:ed)?|reversal|reversed|instal?ments?|monthly|remaining|outstanding|due|'
    r'balance|bal|avl|available|limit)(?![a-z])|[+=]|'
    r'الإجمالي|الاجمالي|إجمالي|اجمالي|المجموع|شامل|بقشيش|إكرامية|اكرامية|ضريبة|رسوم|عمولة|خدمة|يعادل|'
    r'استرداد|مسترد|نقاط|مكافأة|كاش باك|قسط|أقساط|اقساط|المتبقي|المستحق|رصيد|المتاح|متاح|الحد|حد |'
    // Follow-up 6 (NEW-2r): a month-to-date total is an account figure.
    r'مجموع|مصروفاتك|مشترياتك|هذا الشهر|الشهر الحالي',
    caseSensitive: false,
  );

  static final RegExp _moneyToken =
      RegExp(r'^(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]+)?$');

  /// Every currency-tagged amount of [text] (digits and currency words
  /// normalized), by currency code. Server twin: `taggedAmounts`.
  static (String, Map<String, Set<double>>) _taggedAmounts(String text) {
    final ascii = Normalizer.normalizeDigits(text)
        .replaceAll('٬', ',')
        .replaceAll('٫', '.');
    final movement = Normalizer.normalizeCurrencyTokens(ascii);
    final codes = currencyCodes.join('|');
    final tagged = RegExp(
      '(?<![A-Za-z])($codes)\\s?([0-9][0-9,]*(?:\\.[0-9]+)?)(?![0-9])'
      '|(?<![0-9.,])([0-9][0-9,]*(?:\\.[0-9]+)?)\\s?($codes)(?![A-Za-z])',
    );
    final byCurrency = <String, Set<double>>{};
    for (final m in tagged.allMatches(movement)) {
      final code = m.group(1) ?? m.group(4)!;
      final token = m.group(2) ?? m.group(3)!;
      // As the server's canonicalMoneyText: plain digits or thousands groups.
      if (!_moneyToken.hasMatch(token)) continue;
      final value = double.tryParse(token.replaceAll(',', ''));
      if (value == null || value <= 0) continue;
      byCurrency.putIfAbsent(code, () => <double>{}).add(value);
    }
    return (movement, byCurrency);
  }

  /// The distinct amounts when [text] names several of one currency, or null.
  static List<double>? separateMovementAmounts(String text) {
    final (movement, byCurrency) = _taggedAmounts(text);
    if (_partOfOneMovement.hasMatch(movement.toLowerCase())) return null;
    for (final values in byCurrency.values) {
      if (values.length < 2) continue;
      final list = values.toList();
      final sum = list.fold<double>(0, (a, b) => a + b);
      if (list.any((v) => (v * 2 - sum).abs() < 0.005)) return null;
      return list;
    }
    return null;
  }

  /// The total a message states for one movement made of parts (dev
  /// siblings, family e): the labelled charged total ([chargedTotal]), or the
  /// one figure of a currency that is the sum of all the others ("SAR 230.00
  /// (SAR 200.00 + SAR 30.00 tip)"); null when there is none. Server twin:
  /// `statedTotal`.
  static final RegExp _includesPart = RegExp(
      r'(?<![a-z])(?:incl\.?|including|inclusive of|of which)(?![a-z])|شامل',
      caseSensitive: false);

  /// Follow-up 13 — why a candidate [amount] for [text] is never accepted
  /// from the parser's meaning, or null when the meaning is `record`:
  /// `transaction_not_completed` when the meaning is not completed, or is any
  /// other non-record meaning (an over-length text among them) and the whole
  /// text carries a not-completed cue; otherwise `message_meaning_<reason>`.
  /// A tip/fee form (`tip_component`, `total_with_parts`) answered at the
  /// total the message states ([statedTotal]) is not rejected. Server twin:
  /// `meaningRejectionOf` in `process-ios-sms/meaning_gate.ts`.
  static String? meaningRejectionOf(String text,
      {num? amount, bool modelDecided = false}) {
    final meaning = ParserEngine.meaningOf(text);
    if (meaning.disposition == MessageDisposition.record) return null;
    // Round 5 (owner decision): no doubt, only a wording the rules do not
    // know as a completed form — a model's validated answer decides it
    // (never a transfer: the device's own reading decides those).
    if (modelDecided &&
        meaning.kind == MessageKind.uncertain &&
        meaning.reason == 'no_completed_form' &&
        !CompletionCertainty.isTransfer(text)) {
      return null;
    }
    if (meaning.kind == MessageKind.notCompleted ||
        TransactionStateCues.isNotCompleted(text)) {
      return 'transaction_not_completed';
    }
    // Follow-up 6 (VAL-1 leftover): a bill that carries any status or
    // reversal word («عملية معكوسة: …», "… Transaction reversed") is never
    // released at its total.
    if ((meaning.reason == 'tip_component' ||
            meaning.reason == 'total_with_parts') &&
        amount != null &&
        !TransactionStateCues.hasStatusCue(text) &&
        // Round 5: and only a clearly completed one (no doubt, a completed
        // form): "total SAR 230 can be paid" is not a payment.
        CompletionCertainty.uncertaintyOf(text,
                hasFlow: meaning.direction != TxnDirection.unknown) ==
            null) {
      final total = statedTotal(text);
      if (total != null && (total - amount).abs() < 0.005) return null;
    }
    return 'message_meaning_${meaning.reason}';
  }

  static double? statedTotal(String text) {
    final labelled = chargedTotal(text);
    if (labelled != null) return labelled;
    final (movement, byCurrency) = _taggedAmounts(text);
    for (final values in byCurrency.values) {
      // "AED 315.00 … incl. AED 15.00 tip": the figure that includes the
      // other.
      if (values.length == 2 && _includesPart.hasMatch(movement)) {
        return values.reduce((a, b) => a > b ? a : b);
      }
      if (values.length < 3) continue;
      final sum = values.fold<double>(0, (a, b) => a + b);
      for (final v in values) {
        if ((v * 2 - sum).abs() < 0.005) return v;
      }
    }
    return null;
  }

  /// A core parser code counts in any case as a whole word; any other table
  /// code only in capitals right next to a figure ("NGN 5,000"), so words such
  /// as "ALL" or "TOP" are never a currency (server `currencyGrounded`).
  static bool currencyGrounded(String iso, String text) {
    if (iso.isEmpty) return false;
    final normalized = Normalizer.normalizeCurrencyTokens(text);
    final e = RegExp.escape(iso);
    final code = Normalizer.isoCurrencyAlternation.split('|').contains(iso)
        ? RegExp('(?<![A-Za-z])$e(?![A-Za-z])', caseSensitive: false)
        : RegExp('(?<![A-Za-z])$e(?=\\s?[0-9])|(?<=[0-9]\\s?)$e(?![A-Za-z])');
    if (code.hasMatch(normalized)) return true;
    final extras = _extraAliases[iso] ?? const <String>[];
    return extras.any(text.contains);
  }

  static bool _merchantGrounded(String? merchant, String text) {
    // "01" is a substring of almost any SMS; a time/date/reference is never
    // a grounded merchant.
    if (merchant == null || MerchantSanity.isNumericOnly(merchant)) {
      return false;
    }
    // A sanitizer placeholder ("[NAME]", "[CARD]" …) is in the text by
    // construction, so it would always "ground" — but it is never a merchant.
    // Mirrors REDACTION_PLACEHOLDER in the server validator.
    if (_redactionPlaceholder.hasMatch(merchant)) return false;
    final needle = _collapse(merchant);
    if (needle.isEmpty) return false;
    return _collapse(text).contains(needle);
  }

  static final RegExp _redactionPlaceholder = RegExp(
    r'\[(?:CARD|PHONE|ACCOUNT|IBAN|OTP|REDACTED|NAME|REF|EMAIL)\]',
    caseSensitive: false,
  );

  static String _collapse(String value) =>
      value.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}
