import '../models/transaction_type.dart';
import 'completion_certainty.dart';
import 'currency_table.dart';
import 'message_meaning.dart';
import 'parser_engine.dart';

/// Money-movement direction derived **independently** from explicit wording in
/// the message. It is used as a grounding cross-check against the classified
/// [TransactionType]: when the words say money came in but the type says it went
/// out (or vice-versa), the transaction must never auto-confirm.
enum TxnDirection {
  /// Money in (deposit, salary, incoming transfer, refund).
  credit,

  /// Money out (purchase, withdrawal, payment).
  debit,

  /// The text is not decisive on its own (both or neither family of words).
  unknown,
}

class DirectionSignal {
  const DirectionSignal._();

  // Words that clearly mean "money in". Intentionally avoids the bare tokens
  // "credit"/"debit" because they appear in "credit card" / "debit card".
  static const List<String> _creditWords = [
    'إيداع',
    'ايداع',
    'أُضيف',
    'أضيف',
    'اضيف',
    'إضافة',
    'اضافة',
    'تم إضافة',
    'تم اضافة',
    'تم استلام',
    'استلمت',
    'استلام',
    'مبلغ وارد',
    'حوالة واردة',
    // OR-04 (O-own P59/P60): an incoming transfer named as such ("تحويل
    // وارد", "Instant transfer in: SAR …"), as `creditKeywords` on the
    // server. Not a bare "transfer in" ("transfer initiated").
    'تحويل وارد',
    'transfer in:',
    'راتب',
    'deposit',
    'salary',
    'credited',
    'received',
    'incoming',
    // ── refund / reversal ────────────────────────────────────────────────
    // `TransactionType.refund` is declared direction-unambiguous (incoming) by
    // the D2 polarity map, but this list could not recognise a single refund
    // message, so all 31 refund rows in the rev-4 baseline resolved to
    // `direction_ambiguous` and none could auto-commit. The architecture
    // asserted a polarity the lexicon was unable to detect.
    //
    // Admitted forms are unambiguous refund/reversal language ONLY. Matching
    // is substring-based, so a short token is a liability: bare `رد` is
    // deliberately ABSENT because it occurs inside `وارد` (incoming), `ترد`
    // and `يرد`, and bare `عكس` is ABSENT because it occurs inside `بالعكس`,
    // `عكسية` and `انعكاس`. Both would manufacture false INCOMING polarity on
    // ordinary text. The refund senses are reached through longer forms and
    // phrases instead.
    'استرداد',
    'مسترد',
    'مستردة',
    'رد مبلغ',
    'ردّ مبلغ',
    'إعادة مبلغ',
    'اعادة مبلغ',
    'عكس قيد',
    'عكس العملية',
    'refund',
    'refunded',
    'reversal',
    'reversed',
  ];

  // Words that clearly mean "money out".
  static const List<String> _debitWords = [
    'خصم',
    'خُصم',
    'تم الخصم',
    'شراء',
    'مشتريات',
    'دفع',
    'مدفوعات',
    'سحب',
    'مبلغ صادر',
    'صادر',
    'purchase',
    'payment',
    'paid',
    'debited',
    'withdrawn',
    'withdrawal',
    'deducted',
    'spent',
    'نقاط بيع',
  ];

  /// The direction strongly implied by the raw message text.
  /// Returns [TxnDirection.unknown] when both or neither family appears.
  /// The credit/debit vocabularies, exposed READ-ONLY so the proof evidence
  /// layer can reuse the SAME words this class matches on instead of keeping a
  /// second copy. Two lists would be two definitions of "what means money in",
  /// and they would drift.
  ///
  /// Additive only: `detect`/`ofType`/`contradicts` are unchanged.
  static List<String> get creditWords => _creditWords;
  static List<String> get debitWords => _debitWords;

  /// Round 3 (owner brief 4.1, V1-082): the direction of the message's
  /// transaction clause. Footer sentences ([ParserEngine.clauseScope]) do
  /// not count; the clause's own verb and preposition structure
  /// ([flowOf]: "debited", "paid to", "credited", "received from") decides
  /// first, and only when it is silent do the money words decide (a noun such
  /// as "deposit" or "salary" alone no longer outweighs "paid to …").
  ///
  /// A bare "to your account" (`إلى حسابك`) with no credit verb and no
  /// outgoing structure does not decide here, as the bare English phrase
  /// never did: the money words do (this is the cross-check the import paths
  /// hold a server or AI direction against).
  static TxnDirection detect(String text) {
    final core = ParserEngine.clauseScope(text).core;
    final flow = flowOf(core);
    if (flow == TxnDirection.credit &&
        !hasDebitFlow(core) &&
        !_creditVerbFlow.hasMatch(core.toLowerCase())) {
      return detectWords(core);
    }
    if (flow != TxnDirection.unknown) return flow;
    // A flow that moves reward points ("12 miles credited to your account")
    // is not a money word either (follow-up 3, SM-03).
    final lower = withoutRewardFlows(core.toLowerCase());
    final words = detectWords(lower);
    if (words != TxnDirection.unknown) return words;
    final families = wordFamilies(lower);
    return !families.debit && !families.credit && _merchantMark.hasMatch(lower)
        ? TxnDirection.debit
        : TxnDirection.unknown;
  }

  /// [lower] without its reward flows and side-credit clauses: what the
  /// money words of the movement are read on.
  static String withoutRewardFlows(String lower) {
    for (final flow in [_debitFlow, _creditFlow]) {
      for (final m in flow.allMatches(lower).toList().reversed) {
        // A side credit's whole clause goes ("…, تم إيداع استرداد نقدي 2
        // ريال": its noun is not a money word of the transaction either).
        final side = sideCreditClause(lower, m.start, m.end);
        if (side != null) {
          lower = lower.replaceRange(side.$1, side.$2, ' ' * (side.$2 - side.$1));
        } else if (isRewardFlow(lower, m.start, m.end)) {
          lower = lower.replaceRange(m.start, m.end, ' ' * (m.end - m.start));
        }
      }
    }
    return lower;
  }

  static final RegExp _creditVerbFlow = _flowPattern([
    for (final w in creditFlow)
      if (w != 'إلى حسابك' && w != 'الى حسابك') w,
  ]);

  /// The word-family reading of [text] (both or neither family: unknown).
  static TxnDirection detectWords(String text) {
    final (:debit, :credit) = wordFamilies(text);
    final hasCredit = credit;
    final hasDebit = debit;
    if (hasCredit && !hasDebit) return TxnDirection.credit;
    if (hasDebit && !hasCredit) return TxnDirection.debit;
    return TxnDirection.unknown;
  }

  /// Round 5 (review X, X-M1): direction families the word lists missed,
  /// English as whole words ("fee", never "coffee"). Only the direction
  /// reading ([detectWords]) uses them. The server's `debitKeywords` /
  /// `creditKeywords` (process-ios-sms/parser_rules.json) carry the same.
  /// With the server's bare "debit" / "credit" (never "debit card", "credit
  /// card" or "credit limit"), "POS", a standing order and «سداد».
  static final RegExp _namedCredit = RegExp(
      r'(?<![a-z])(?:payroll|wages|bonus|dividends?|cash ?back|arrived in|landed in|transfer received)(?![a-z])'
      r'|(?<![a-z])credit(?![a-z])(?! card| limit)'
      r'|أودع|اودع|مكافأة|مكافاة|حواله وارده|استرجاع|وصلك');
  static final RegExp _namedDebit = RegExp(
      r'(?<![a-z])(?:fees?|billed|charged?|renewed|atm cash|used for|authori[sz]ed|pos|mpos|epos|standing order|booked on|approved on|transfer sent|installments?|instalments?)(?![a-z])'
      r'|(?<![a-z])debit(?![a-z])(?! card)'
      r'|المخصوم|سدد|سُدد|سداد|عمولة|أمر مستديم|استخدمت|على بطاقتك|على حسابك|قسط');

  /// Round 5 (X-M3): with no money word, an amount spent at a merchant ("SAR
  /// 45.00 at Test Mart", "@ Test Bakery", «لدى») is a debit. Mirrors
  /// `MERCHANT_MARK` in `process-ios-sms/parse.ts`.
  // "at" at the end: the merchant after it was blanked (localOf).
  static final RegExp _merchantMark =
      RegExp(r'(?<![a-z])at(?: (?![0-9])|$)|@|لدى');

  /// Which direction families the money words of [text] name.
  static ({bool debit, bool credit}) wordFamilies(String text) {
    final lower = text
        .toLowerCase()
        .replaceAllMapped(namedNoun, (m) => ' ' * m[0]!.length);
    return (
      debit: _debitWords.any(lower.contains) || _namedDebit.hasMatch(lower),
      credit: _creditWords.any(lower.contains) || _namedCredit.hasMatch(lower),
    );
  }

  /// Round 5 (X-M1): the direction the device's rule parser itself reads in
  /// [text] — the reading that books it with the AI off: none when the event
  /// carries conflicting cues ([ParserEngine.conflictingCues]); else the
  /// clause flow and money words ([detect]); else the direction of the rule
  /// parse's type.
  static TxnDirection localOf(String text) {
    if (ParserEngine.conflictingCues(text)) return TxnDirection.unknown;
    // With no flow phrase, a merchant's name after "at" ("at Arrived In
    // Account Cafe") names no direction.
    final core = ParserEngine.clauseScope(text).core;
    final words = flowOf(core) == TxnDirection.unknown &&
            _merchantMark.hasMatch(core.toLowerCase())
        ? detect(ParserEngine.merchantMasked(text))
        : detect(text);
    if (words != TxnDirection.unknown) return words;
    // Review Y (N-M1): else the direction the wording states ("topped up
    // with", «قيد … لحسابك»), as the server's `localDirection`.
    final stated = CompletionCertainty.statedCredit(text);
    if (stated != null) {
      return stated ? TxnDirection.credit : TxnDirection.debit;
    }
    final type = const ParserEngine().parse(text).transaction?.type;
    if (type == null) return TxnDirection.unknown;
    if (type.isExpense) return TxnDirection.debit;
    return type == TransactionType.income || type == TransactionType.refund
        ? TxnDirection.credit
        : TxnDirection.unknown;
  }

  /// Round 5 (X-M1/X-M2): a model's [direction] for [text] is accepted only
  /// when it is the one the rule parser reads ([localOf]). When the text
  /// gives the rule parser no direction, only a message with no
  /// completed-event form (`no_completed_form`, decided by the model) takes
  /// the model's. Server twin: `modelDirectionRefused` in
  /// `process-ios-sms/parse.ts`.
  static bool modelDirectionRefused(String text, TxnDirection direction) {
    final local = localOf(text);
    if (local != TxnDirection.unknown) return direction != local;
    final meaning = ParserEngine.meaningOf(text);
    return !(meaning.kind == MessageKind.uncertain &&
        meaning.reason == 'no_completed_form');
  }

  /// Outgoing structure: a debit verb or "… to / from your account".
  /// Equal to `messageMeaning.debitFlow` in `process-ios-sms/parser_rules.json`.
  static const List<String> debitFlow = [
    'debited', 'deducted', 'charged', 'withdrawn', 'spent', 'sent to',
    'paid to', 'paid at', 'paid for', 'paid using', 'paid by card',
    'transferred to', 'transfer to', 'transferred from your',
    'from your account', 'from your card', 'from account', 'money out', 'outgoing', 'outward', 'was used for',
    'has been used for',
    'تم خصم', 'خصم مبلغ', 'تم سحب', 'مبلغ صادر', 'حوالة صادرة',
    'تحويل صادر', 'من حسابك', 'من بطاقتك', 'تم الدفع', 'تم دفع', 'تم سداد',
    'منك إلى', 'منك الى',
    // Follow-up 6 (NEW-2r): «استخدمت بطاقتك … بمبلغ …», the Arabic twin of
    // "was used for".
    'استخدمت بطاقتك', 'تم استخدام بطاقتك',
  ];

  /// Incoming structure: a credit verb or "… into / to your account".
  /// Equal to `messageMeaning.creditFlow` in `process-ios-sms/parser_rules.json`.
  static const List<String> creditFlow = [
    'credited', 'received', 'deposited to', 'deposited into',
    'deposited in your', 'paid into', 'paid to your account',
    'transferred to your account', 'transferred into your account',
    'transfer to your account', 'sent to you', 'refunded', 'money in',
    'inward', 'incoming', 'تم إيداع', 'تم ايداع',
    'حوالة واردة', 'تحويل وارد', 'تم استلام', 'استلمت', 'مبلغ وارد',
    'إلى حسابك', 'الى حسابك', 'تمت إضافة', 'تم إضافة', 'إضافتها',
    'إليك', 'اليك',
    // Follow-up 6 (PRE-RF009): money returned. The refund leads the clause
    // and the purchase it names is what is refunded («استرجاع عملية شراء …»,
    // «تم رد مبلغ … عن عملية شراء»): incoming, not a purchase.
    'تم استرجاع', 'استرجاع مبلغ', 'استرجاع عملية', 'مرتجع مشتريات',
    'رد مبلغ', 'تم إرجاع', 'تم ارجاع', 'تمت إعادة', 'إعادة مبلغ', 'اعادة مبلغ',
  ];

  static final RegExp _debitFlow = _flowPattern(debitFlow);
  static final RegExp _creditFlow = _flowPattern(creditFlow);
  static RegExp _flowPattern(List<String> words) => RegExp(
      '(?<![a-z\u0621-\u064a])[وفب]?(?:${(List.of(words)..sort((a, b) => b.length - a.length)).map(RegExp.escape).join('|')})(?![a-z])');

  /// A store's name ("Cashback Store", «متجر أودع»), a card product
  /// ("Cashback card") or a "security deposit" names no direction. Mirrors
  /// `NAMED_NOUN` in process-ios-sms/parse.ts.
  static final RegExp namedNoun = RegExp(
      r'(?<![a-z])[a-z]+ (?:store|mart|shop|market)(?![a-z])|cash ?back (?:credit )?card|security deposit|(?:متجر|محل|مطعم) [ء-ي]+');

  /// Which flow families [text] names. A phrase inside a longer phrase of
  /// the other family ("sent to" in "sent to you") is that longer phrase.
  static ({bool debit, bool credit}) flowFamilies(String text) {
    final lower = text.toLowerCase();
    List<RegExpMatch> live(RegExp re) => re
        .allMatches(lower)
        .where((m) => !isRewardFlow(lower, m.start, m.end))
        .toList();
    bool inside(RegExpMatch m, List<RegExpMatch> other) => other.any((o) =>
        o.start <= m.start && o.end >= m.end && o.end - o.start > m.end - m.start);
    final d = live(_debitFlow), c = live(_creditFlow);
    return (
      debit: d.any((m) => !inside(m, c)),
      credit: c.any((m) => !inside(m, d)),
    );
  }

  /// [lower] with every flow phrase blanked.
  static String withoutFlows(String lower) => lower
      .replaceAllMapped(_debitFlow, (m) => ' ' * m[0]!.length)
      .replaceAllMapped(_creditFlow, (m) => ' ' * m[0]!.length);

  static bool hasDebitFlow(String text) =>
      _firstMoneyFlow(_debitFlow, text.toLowerCase()) != null;
  static bool hasCreditFlow(String text) =>
      _firstMoneyFlow(_creditFlow, text.toLowerCase()) != null;

  /// The direction of the earliest flow phrase in [text] (a longer phrase
  /// wins at the same position: "transferred to your" is incoming).
  ///
  /// "Payment … received" with no payer ("Your card payment of SAR 500 has
  /// been received") acknowledges the user's own payment: not decisive.
  static TxnDirection flowOf(String text) {
    final lower = text.toLowerCase();
    final d = _firstMoneyFlow(_debitFlow, lower);
    var c = _firstMoneyFlow(_creditFlow, lower);
    if (c != null && d == null && c[0] == 'received') {
      final sentence = lower.split(RegExp(r'[\n!?؟;؛]|\.(?![0-9])')).firstWhere(
          (x) => x.contains('received'),
          orElse: () => '');
      final before = sentence.substring(0, sentence.indexOf('received'));
      if (RegExp(r'(?<![a-z])payment(?![a-z])').hasMatch(before) &&
          !RegExp(r'(?<![a-z])from(?![a-z])').hasMatch(sentence)) {
        c = null;
      }
    }
    if (d == null && c == null) return TxnDirection.unknown;
    if (c == null) return TxnDirection.debit;
    if (d == null) return TxnDirection.credit;
    final credit = c.start < d.start || (c.start == d.start && c.end >= d.end);
    // "SAR 500 credited to Ali from your account": the money left the
    // user's own account, and no clause names it as the destination.
    if (credit &&
        MessageMeaning.sourceOfFunds.any(lower.contains) &&
        !MessageMeaning.ownDestination.any(lower.contains)) {
      return TxnDirection.debit;
    }
    return credit ? TxnDirection.credit : TxnDirection.debit;
  }

  /// The first [flow] phrase in [lower] that moves money: "تم إيداع نقاط
  /// المكافآت" / "credited points 45" move loyalty points, not money, and so
  /// does a flow whose own clause names the points ("Purchase SAR 450 …, 45
  /// points credited to your account": follow-up 3, SM-03).
  /// Mirrors `firstMoneyFlow` in `process-ios-sms/message_meaning.ts` and
  /// `isRewardFlow` in `_shared/money_text.ts`.
  static RegExpMatch? _firstMoneyFlow(RegExp flow, String lower) {
    for (final m in flow.allMatches(lower)) {
      if (!isRewardFlow(lower, m.start, m.end)) return m;
    }
    return null;
  }

  /// Whether the flow phrase at [start]..[end] of [lower] moves reward points
  /// or miles: a reward unit right after it (a count may come first), or in
  /// its own clause before it; or whether it is a side credit
  /// ([sideCreditClause]).
  static bool isRewardFlow(String lower, int start, int end) {
    if (_rewardAfter.hasMatch(lower.substring(end))) return true;
    var from = 0;
    for (final c in _rewardClauseCut.allMatches(lower.substring(0, start))) {
      from = c.end;
    }
    return _rewardUnit.hasMatch(lower.substring(from, start)) ||
        sideCreditClause(lower, start, end) != null;
  }

  /// Follow-up 4 (NEW-1): the message's direction and amount come from its
  /// primary clause, the one that carries the first currency figure (the
  /// transaction amount). A flow phrase in a later clause that names a
  /// reward, cashback, bonus or loyalty credit, and whose own figure (if it
  /// has one) is smaller than the primary figure, is a side event: it never
  /// sets the direction. Returns that clause's span, or null. A message
  /// whose only event is a cashback or redemption credit has no earlier
  /// primary figure, so its credit stands. Mirrors `sideCreditClause` in
  /// `_shared/money_text.ts`.
  static (int, int)? sideCreditClause(String lower, int start, int end) {
    var from = 0;
    for (final c in _sideClauseCut.allMatches(lower.substring(0, start))) {
      from = c.end;
    }
    final next = _sideClauseCut.firstMatch(lower.substring(end));
    final to = next == null ? lower.length : end + next.start;
    final clause = lower.substring(from, to);
    if (!_sideReward.hasMatch(clause)) return null;
    final primary = _currencyFigure.firstMatch(lower);
    if (primary == null || primary.start >= from) return null;
    final own = _currencyFigure.firstMatch(clause);
    if (own != null && !(_figureValue(own) < _figureValue(primary))) {
      return null;
    }
    return (from, to);
  }

  /// [lower] with every side-credit clause ([sideCreditClause]) blanked.
  static String withoutSideCredits(String lower) {
    for (final m in _creditFlow.allMatches(lower).toList().reversed) {
      final side = sideCreditClause(lower, m.start, m.end);
      if (side != null) {
        lower = lower.replaceRange(side.$1, side.$2, ' ' * (side.$2 - side.$1));
      }
    }
    return lower;
  }

  /// Whether [lower] names a reward, cashback, bonus or loyalty credit.
  static bool namesReward(String lower) => _sideReward.hasMatch(lower);

  static final RegExp _sideClauseCut =
      RegExp(r'[\n,،;!?؟؛]|\.(?![0-9])| [-–—] | and (?=[a-z])');
  static final RegExp _sideReward = RegExp(
      r'(?<![a-z])(?:cash ?back|rewards?|bonus|qitaf|loyalty|points|miles)(?![a-z])'
      r'|استرداد نقدي|كاش ?باك|مكافأة|المكافأة|مكافآت|المكافآت|مكافاة|المكافاة|قطاف'
      r'|(?:ال)?نقاط(?!\s*البيع)|نقطة|نقطه|أميال|اميال');
  static final String _codes =
      [for (final c in CurrencyTable.iso) c.toLowerCase(), 'sr', r'ر\.س'].join('|');
  static final RegExp _currencyFigure = RegExp(
      '(?<![a-z])(?:$_codes)\\s?([0-9٠-٩][0-9٠-٩,٬]*(?:[.٫][0-9٠-٩]+)?)'
      '|([0-9٠-٩][0-9٠-٩,٬]*(?:[.٫][0-9٠-٩]+)?)\\s?(?:$_codes|ريال|جنيه|درهم|دينار)(?![a-z])');
  static final RegExp _codedFigure = RegExp(
      '(?<![a-z])($_codes)\\s?([0-9٠-٩][0-9٠-٩,٬]*(?:[.٫][0-9٠-٩]+)?)'
      '|([0-9٠-٩][0-9٠-٩,٬]*(?:[.٫][0-9٠-٩]+)?)\\s?($_codes|ريال|جنيه|درهم|دينار)(?![a-z])');

  /// Follow-up 5: every currency figure of [lower] (lower-cased text), with
  /// its value and currency word, in order.
  static List<({int start, int end, String code, double value})> currencyFigures(
      String lower) {
    return [
      for (final m in _codedFigure.allMatches(lower))
        (
          start: m.start,
          end: m.end,
          code: m.group(1) ?? m.group(4)!,
          value: _valueOf(m.group(2) ?? m.group(3)!),
        )
    ];
  }

  static double _valueOf(String raw) {
    raw = raw.replaceAllMapped(
        RegExp('[٠-٩]'), (d) => '${d[0]!.codeUnitAt(0) - 0x660}');
    return double.tryParse(raw.replaceAll(RegExp('[,٬]'), '').replaceAll('٫', '.')) ??
        double.infinity;
  }

  static double _figureValue(RegExpMatch m) {
    final raw = (m.group(1) ?? m.group(2)!).replaceAllMapped(
        RegExp('[٠-٩]'), (d) => '${d[0]!.codeUnitAt(0) - 0x660}');
    return double.tryParse(raw.replaceAll(RegExp('[,٬]'), '').replaceAll('٫', '.')) ??
        double.infinity;
  }

  static const String _rewardUnits =
      r'(?:(?:reward|loyalty|bonus|cashback)\s+)?(?:points|miles)(?![a-z])|(?:ال)?نقاط(?!\s*البيع)|نقطة|نقطه|أميال|اميال';
  static final RegExp _rewardAfter =
      RegExp('^\\s*(?:[0-9][0-9,.]*\\s*)?(?:$_rewardUnits)');
  static final RegExp _rewardUnit = RegExp('(?<![a-z])(?:$_rewardUnits)');
  static final RegExp _rewardClauseCut =
      RegExp(r'[\n,،:;!?؟؛]|\.(?![0-9])| [-–—] ');

  /// The direction implied by a classified [TransactionType], or
  /// [TxnDirection.unknown] when the type is inherently ambiguous (transfer).
  static TxnDirection ofType(TransactionType type) {
    switch (type) {
      case TransactionType.income:
      case TransactionType.refund:
        return TxnDirection.credit;
      case TransactionType.payment:
      case TransactionType.withdrawal:
      case TransactionType.creditCardPayment:
      case TransactionType.governmentPayment:
        return TxnDirection.debit;
      case TransactionType.transfer:
      case TransactionType.unknown:
        return TxnDirection.unknown;
    }
  }

  /// True only when the text direction and the type direction are **both known
  /// and opposite**. A contradicting transaction must be routed to pending.
  static bool contradicts(String text, TransactionType type) {
    final textDir = detect(text);
    final typeDir = ofType(type);
    if (textDir == TxnDirection.unknown || typeDir == TxnDirection.unknown) {
      return false;
    }
    return textDir != typeDir;
  }
}
