import '../../engine/ai/ai_candidate_validator.dart';
import '../finance/currency_scale.dart';
import '../../engine/parser/direction_signal.dart';
import '../../engine/parser/message_meaning.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/parser_engine.dart';

/// ValidatedCapture v1, the Dart side of the contract the server enforces in
/// `supabase/functions/_shared/ai_candidate_validator.ts`. Both sides run the
/// golden cases in `contract_fixtures/validated_capture_v1.json`; a case that
/// one side fails must be reported, never weakened.
///
/// Required: `amount > 0` as a whole numeric token of the text, an
/// ASCII-canonical `amount_text` for the same value, a whitelisted currency
/// grounded in the text, and a direction (`debit` | `credit`, explicit or from
/// the type) that does not contradict the wording.
/// Optional and dropped when ungrounded: merchant, last4, occurred_at.
///
/// Pure and side-effect free. It reads no confidence and decides nothing about
/// consent or ownership.
class CaptureCandidate {
  const CaptureCandidate({
    this.amount,
    this.amountText,
    this.currency,
    this.direction,
    this.type,
    this.merchant,
    this.last4,
    this.occurredAt,
  });

  final double? amount;
  final String? amountText;
  final String? currency;
  final String? direction;
  final String? type;
  final String? merchant;
  final String? last4;
  final String? occurredAt;
}

class ValidatedCapture {
  const ValidatedCapture({
    required this.amount,
    required this.amountText,
    required this.currency,
    required this.direction,
    this.merchant,
    this.last4,
    this.occurredAt,
  });

  final double amount;

  /// Canonical exact amount text.
  final String amountText;
  final String currency;

  /// `debit` or `credit`.
  final String direction;

  /// The three optional fields are null when ungrounded.
  final String? merchant;
  final String? last4;
  final DateTime? occurredAt;
}

class CaptureValidation {
  const CaptureValidation.rejected(String this.reason) : capture = null;
  const CaptureValidation.accepted(ValidatedCapture this.capture)
      : reason = null;

  final String? reason;
  final ValidatedCapture? capture;

  bool get accepted => capture != null;
}

/// The parser currency table limited to persistable codes — the same list as
/// the server CURRENCY_CODES.
final List<String> kCaptureCurrencyCodes = AiCandidateValidator.currencyCodes;

const Duration _maxAge = Duration(days: 31);
const Duration _maxFuture = Duration(days: 1);

final RegExp _canonicalMoney = RegExp(
  r'^(-?)(?:(0|[1-9][0-9]*)|([1-9][0-9]{0,2}(?:,[0-9]{3})+))(?:\.([0-9]+))?$',
);

/// Mirror of the server `canonicalMoneyText` (no negatives): grouping only in
/// 3-digit groups and removed, fraction kept exactly, excess scale rejected.
String? canonicalCaptureMoneyText(String token, [String? currency]) {
  if (token.isEmpty || token.length > 256) return null;
  final m = _canonicalMoney.firstMatch(token);
  if (m == null || m.group(1)!.isNotEmpty) return null;
  final fraction = m.group(4);
  final scale = currency == null
      ? null
      : kDetectionCurrencyScale[currency.trim().toUpperCase()];
  if (scale != null && (fraction?.length ?? 0) > scale) return null;
  final integer = (m.group(2) ?? m.group(3))!.replaceAll(',', '');
  return fraction == null ? integer : '$integer.$fraction';
}

// A numeric token is a maximal digit run with digit-flanked group/decimal
// separators (ASCII or Arabic), so a longer number never yields a sub-token.
final RegExp _numericToken = RegExp('[0-9٠-٩]+(?:[,٬.٫][0-9٠-٩]+)*');
final RegExp _dateTimeSepBefore = RegExp('[0-9٠-٩][-/:]\$');
final RegExp _dateTimeSepAfter = RegExp('^[-/:][0-9٠-٩]');
final RegExp _last4Prefix = RegExp(
  r'(?:[*•xX]|(?:ending|ends|acct|account|a/c|card|بطاقة|حساب|رقم|تنتهي|منتهية)'
  r'(?:\s+(?:in|with|no\.?|number|#|بـ|ب))?[\s:#.-]*)$',
  caseSensitive: false,
);

String? _canonicalTokenText(String token) {
  final ascii = token
      .replaceAllMapped(RegExp('[٠-٩]'),
          (d) => String.fromCharCode(d[0]!.codeUnitAt(0) - 0x0660 + 0x30))
      .replaceAll('٬', ',')
      .replaceAll('٫', '.');
  return canonicalCaptureMoneyText(ascii);
}

/// Canonical text of every standalone numeric token that may be an amount
/// (not part of a date, time, card/account number or larger number).
List<String> captureAmountTokens(String text) {
  final out = <String>[];
  for (final m in _numericToken.allMatches(text)) {
    final before = text.substring(0, m.start);
    final after = text.substring(m.end);
    if (_dateTimeSepBefore.hasMatch(before) ||
        _dateTimeSepAfter.hasMatch(after)) {
      continue;
    }
    if (_last4Prefix.hasMatch(before)) continue;
    final canonical = _canonicalTokenText(m[0]!);
    if (canonical != null) out.add(canonical);
  }
  return out;
}

bool _amountGrounded(double? amount, String text) {
  if (amount == null || !amount.isFinite || amount <= 0) return false;
  return captureAmountTokens(text)
      .any((t) => ((double.tryParse(t) ?? double.nan) - amount).abs() < 0.005);
}

String _collapse(String v) =>
    v.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

bool _merchantGrounded(String? merchant, String text) {
  if (merchant == null) return false;
  final needle = _collapse(merchant);
  return needle.isNotEmpty && _collapse(text).contains(needle);
}

bool _last4Grounded(String? last4, String text) =>
    last4 != null &&
    RegExp(r'^[0-9]{4}$').hasMatch(last4) &&
    text.contains(last4);

TxnDirection _asDirection(String? value) => switch (value) {
      'credit' => TxnDirection.credit,
      'debit' => TxnDirection.debit,
      _ => TxnDirection.unknown,
    };

TxnDirection _directionOfType(String? type) => switch (type) {
      'income' || 'refund' => TxnDirection.credit,
      'payment' || 'withdrawal' => TxnDirection.debit,
      _ => TxnDirection.unknown,
    };

bool _contradicts(TxnDirection wording, TxnDirection other) =>
    wording != TxnDirection.unknown &&
    other != TxnDirection.unknown &&
    wording != other;

/// FR-02 — true when the device's own deterministic parse of [text] (with
/// the capture's [senderId], LR-09) reads a transaction whose money direction
/// (debit vs credit) is the OPPOSITE of the server's [direction] (or the one
/// its [type] implies). Only the direction counts: payment vs transfer is not
/// a disagreement, and a text the local parser cannot read (or reads as a
/// transfer) never blocks the server result. An import-path policy applied by
/// the callers, not part of the ValidatedCapture v1 contract (which the
/// server mirrors).
///
/// Closure round (follow-up 6 (4)): the direction the device would BOOK —
/// the clause structure of the sentence carrying [amount]
/// ([AiCandidateValidator.bookedDirection]) — overrules the local type when
/// it agrees with the server, so a cue word in a merchant name, a points or
/// footer line, or a deposit word on an outgoing transfer never opposes a
/// correct answer. It never adds an opposition the type did not have (a
/// transfer still keeps the server result here; the wording check in
/// [localParseContradictsServer] still applies).
bool localParseOpposesDirection({
  required String text,
  String? direction,
  String? type,
  String? senderId,
  num? amount,
  String? merchant,
}) {
  final server = _asDirection(direction) != TxnDirection.unknown
      ? _asDirection(direction)
      : _directionOfType(type);
  if (server == TxnDirection.unknown) return false;
  final local = const ParserEngine().parse(text, senderId: senderId);
  if (!local.isTransaction) return false;
  final localType = local.transaction!.type;
  final localDirection = localType.isExpense
      ? TxnDirection.debit
      : localType == TransactionType.refund ||
              localType == TransactionType.income
          ? TxnDirection.credit
          : TxnDirection.unknown;
  if (!_contradicts(localDirection, server)) return false;
  // The local type opposes the server; the direction the device would book
  // (the amount's clause structure) agreeing with the server overrules it.
  final booked = AiCandidateValidator.bookedDirection(text,
      amount: amount?.toDouble(),
      merchant: local.transaction!.rawMerchant ?? merchant);
  return booked != server;
}

/// Closure round (parser meaning, owner brief 4.1 / §5): the reason a message
/// is never recorded from ANY reading (a server's or a model's) — a clear
/// notice, an OTP, or a review kind (not completed, an ATM cash deposit, own
/// accounts, several movements) — or null when it may be recorded. Import
/// paths keep such a capture in Smart Inbox with this reason.
///
/// Dev siblings (family e): a tip/fee form (`tip_component`,
/// `total_with_parts`) whose [amount]
/// (the server's or model's answer) is the total the message states
/// ([AiCandidateValidator.statedTotal]) may be recorded.
String? meaningHoldReason(String text,
    {num? amount, bool modelDecided = false}) {
  final meaning = ParserEngine.meaningOf(text);
  // Follow-up 15 (VAL-1): released only by the single rule, which reads
  // not-completed first. (Round 5: [modelDecided] — the row is a model's
  // answer, which decides a message with no completed-event form.)
  if (meaning.disposition != MessageDisposition.record) {
    return AiCandidateValidator.meaningRejectionOf(text,
                amount: amount, modelDecided: modelDecided) ==
            null
        ? null
        : meaning.reason;
  }
  return severalMovements(text, meaning) ? 'multiple_amounts' : null;
}

/// Round 5 (direction hazard): the direction [text] names, as the server's
/// `namedDirection` (process-ios-sms/parse.ts): the meaning's flow, else the
/// earliest money keyword of [namedDebitKeywords] / [namedCreditKeywords]
/// ("credit card/limit" is a product; a standing order or direct debit names
/// the instrument and decides only when nothing else does). Used only to
/// reject a row that books the other direction (review), never to record.
TxnDirection namedDirection(String text) {
  final flow = ParserEngine.meaningOf(text).direction;
  if (flow != TxnDirection.unknown) return flow;
  final lower = text.toLowerCase();
  int? earliest(String s, List<String> words) {
    int? at;
    for (final w in words) {
      final i = s.indexOf(w);
      if (i >= 0 && (at == null || i < at)) at = i;
    }
    return at;
  }

  const instrument = ['standing order', 'أمر مستديم', 'direct debit'];
  var debitText = lower;
  for (final w in instrument) {
    debitText = debitText.replaceAll(w, ' ' * w.length);
  }
  final debit = earliest(debitText, namedDebitKeywords);
  final credit = earliest(
      lower.replaceAll(RegExp(r'credit(?= card| limit)'), '      '),
      namedCreditKeywords);
  if (debit == null && credit == null) {
    return earliest(lower, instrument) == null
        ? TxnDirection.unknown
        : TxnDirection.debit;
  }
  if (credit == null) return TxnDirection.debit;
  if (debit == null) return TxnDirection.credit;
  return debit <= credit ? TxnDirection.debit : TxnDirection.credit;
}

/// Equal to `debitKeywords` / `creditKeywords` in
/// `process-ios-sms/parser_rules.json` (drift test:
/// completion_certainty_test.dart).
const List<String> namedDebitKeywords = [
  'عملية شراء', 'شراء', 'خصم', 'سحب', 'مدى', 'سداد', 'مشتريات', 'مدفوعات',
  'pos', 'purchase', 'debit', 'withdraw', 'payment', 'paid', 'spent',
  'standing order', 'أمر مستديم',
];
const List<String> namedCreditKeywords = [
  'إيداع', 'ايداع', 'حوالة واردة', 'حواله وارده', 'تحويل وارد', 'استرداد',
  'تم استرجاع', 'استرجاع مبلغ', 'راتب', 'credited', 'credit', 'deposit',
  'received', 'refund', 'salary', 'reversal', 'reversed',
];

/// Round 5: a server row whose figure is a model's validated answer (the
/// rule parse + model or AI-primary path), not the rule parse alone, and not
/// a transfer (transfers are decided on the device's own reading).
bool isModelDecidedRow(Map<String, dynamic>? parsed) =>
    (parsed?['parserSource'] == 'ai_hybrid' ||
        parsed?['parserSource'] == 'ai') &&
    parsed?['type'] != 'transfer';

final RegExp _sentenceCut = RegExp(r'[\n!?؟;؛]|\.(?![0-9])');

/// Dev siblings (family d): a message the meaning reads as one completed
/// movement, with no footer set aside, whose movement sentences (the ones the
/// parser itself reads as a movement) name several amounts of one currency
/// ([AiCandidateValidator.separateMovementAmounts]): several purchases, so no
/// single reading (a server's, a model's or the device's) is the movement.
/// Server twin: `gatedMeaning` in `process-ios-sms/meaning_gate.ts`.
bool severalMovements(String text, [MessageMeaning? meaning]) {
  meaning ??= ParserEngine.meaningOf(text);
  if (meaning.kind != MessageKind.completedMovement || meaning.footerCount > 0) {
    return false;
  }
  final movement = text
      .split(_sentenceCut)
      .where((s) =>
          RegExp('[0-9٠-٩]').hasMatch(s) &&
          ParserEngine.meaningOf(s).disposition == MessageDisposition.record)
      .join('\n');
  return AiCandidateValidator.separateMovementAmounts(movement) != null;
}

/// LR-03 / LR-04 — the device's own reading contradicts a server result for
/// [text]: the opposite money direction ([localParseOpposesDirection]), or
/// the device drops the text as not a transaction (an OTP, an advert, an
/// account notice: [ParserEngine.isIgnoredMessage], or a notice the device
/// keeps for review: [ParserEngine.isNoticeMessage]). Neither reading is
/// trusted then: every import path takes its recoverable review outcome
/// (Smart Inbox), never a confirmed row from either side.
/// OR-03 — so does a server [amount] that is neither the amount the device
/// itself reads from the text nor its foreign amount ("a credit limit taken
/// for the purchase"); when the device reads no amount, only the rules above
/// apply.
bool localParseContradictsServer({
  required String text,
  String? direction,
  String? type,
  String? senderId,
  num? amount,
  String? merchant,
}) =>
    ParserEngine.isIgnoredMessage(text, senderId: senderId) ||
    // V1-086: as the AI candidate validator, a notice line unrelated to the
    // server's amount (a footer next to a completed movement) does not count.
    ParserEngine.isNoticeMessage(
        amount == null || amount.isNaN
            ? text
            : AiCandidateValidator.withoutUnrelatedNotices(
                text, amount.toDouble()),
        senderId: senderId) ||
    localParseOpposesDirection(
        text: text,
        direction: direction,
        type: type,
        senderId: senderId,
        amount: amount,
        merchant: merchant) ||
    // PR-04 — the wording alone names the opposite direction, even when the
    // device reads no transaction (no sender): "Standing order SAR 1,000.00
    // received from Ali" is never a confirmed payment.
    _contradicts(
        AiCandidateValidator.bookedDirection(text,
            amount: amount == null || amount.isNaN ? null : amount.toDouble(),
            merchant: merchant),
        _asDirection(direction) != TxnDirection.unknown
            ? _asDirection(direction)
            : _directionOfType(type)) ||
    (amount != null &&
        _localAmountDiffers(text, amount.toDouble(), senderId: senderId));

bool _localAmountDiffers(String text, double amount, {String? senderId}) {
  final local = const ParserEngine().parse(text, senderId: senderId);
  if (!local.isTransaction) return false;
  final t = local.transaction!;
  bool same(double? v) => v != null && (v - amount).abs() < 0.005;
  if (same(t.amount) || same(t.foreignAmount)) return false;
  // PR-06 — another amount the text names with its currency (a foreign or
  // local equivalent the device did not pair: "EUR 35.00 … Amount in SAR
  // 143.20") is the server's honest reading, unless it is an account figure
  // (a limit, a balance). An unreadable server amount (NaN) never matches.
  return !(captureAmountTokens(text).any((v) => same(double.tryParse(v))) &&
      !ParserEngine.isAccountFigure(text, amount));
}

DateTime? _inWindow(String? iso, DateTime receivedAt) {
  if (iso == null || iso.trim().isEmpty) return null;
  final clean = iso.trim();
  final zoned =
      RegExp(r'(?:z|[+-]\d{2}:?\d{2})$', caseSensitive: false).hasMatch(clean)
          ? clean
          : '${clean}Z';
  final at = DateTime.tryParse(zoned)?.toUtc();
  if (at == null) return null;
  final delta = at.difference(receivedAt.toUtc());
  return delta >= -_maxAge && delta <= _maxFuture ? at : null;
}

/// Validates [candidate] against the message [text] (the raw or sanitized
/// text the device holds). [receivedAt] anchors the date window.
CaptureValidation validateCaptureCandidate({
  required CaptureCandidate candidate,
  required String text,
  required DateTime receivedAt,
  bool modelDecided = false,
}) {
  const reject = CaptureValidation.rejected;
  // DATA-01 / REV-03 — a declined/failed/cancelled message moved no money,
  // whatever a server (including one deployed before the fix) concluded. The
  // caller then takes its existing rejected path (local parse → Smart Inbox).
  // Follow-up 13: any meaning other than `record` rejects
  // ([AiCandidateValidator.meaningRejectionOf]): the not-completed reason
  // first, another non-record meaning just before acceptance.
  final meaningRejection = AiCandidateValidator.meaningRejectionOf(text,
      amount: candidate.amount, modelDecided: modelDecided);
  if (meaningRejection == 'transaction_not_completed') {
    return reject('transaction_not_completed');
  }
  if (!_amountGrounded(candidate.amount, text)) {
    return reject('amount_not_grounded');
  }
  final amount = candidate.amount!;
  // Round 5: a limit, balance or minimum-due figure is never the amount, from
  // any server build (as the AI validator, OR-03).
  if (ParserEngine.isAccountFigure(text, amount)) {
    return reject('amount_is_account_figure');
  }
  // Closure round (follow-up 6 (5)): a stated total next to a tip/fee/VAT is
  // the amount — a server (any build) that answered the base is not trusted.
  final total = AiCandidateValidator.chargedTotal(text);
  if (total != null && (amount - total).abs() >= 0.005) {
    return reject('amount_not_charged_total');
  }
  final currency = (candidate.currency ?? '').trim().toUpperCase();
  if (!kCaptureCurrencyCodes.contains(currency)) {
    return reject('currency_not_whitelisted');
  }
  if (!AiCandidateValidator.currencyGrounded(currency, text)) {
    return reject('currency_not_grounded');
  }

  final rawAmountText = candidate.amountText;
  if (rawAmountText == null) return reject('amount_text_missing');
  final amountText = canonicalCaptureMoneyText(rawAmountText, currency);
  if (amountText == null) return reject('amount_text_not_canonical');
  if (!(((double.tryParse(amountText) ?? double.nan) - amount).abs() < 0.01)) {
    return reject('amount_text_mismatch');
  }
  if (!captureAmountTokens(text).contains(amountText)) {
    return reject('amount_text_not_grounded');
  }

  final wording = AiCandidateValidator.bookedDirection(text,
      amount: amount,
      merchant: _merchantGrounded(candidate.merchant, text)
          ? candidate.merchant
          : null);
  final aiDirection = _asDirection(candidate.direction);
  final typeDirection = _directionOfType(candidate.type);
  // Round 5 (direction hazard): a direction the text names ("Direct debit",
  // "Payroll credit", «خصم», «إيداع») is never flipped by a row.
  final named = namedDirection(text);
  if (_contradicts(wording, typeDirection) ||
      _contradicts(wording, aiDirection) ||
      _contradicts(named, aiDirection) ||
      _contradicts(named, typeDirection)) {
    return reject('direction_contradiction');
  }
  // Direction is required: the explicit direction, else the one the type implies.
  final direction =
      aiDirection != TxnDirection.unknown ? aiDirection : typeDirection;
  if (direction == TxnDirection.unknown) return reject('direction_unresolved');
  if (meaningRejection != null) return reject(meaningRejection);

  return CaptureValidation.accepted(ValidatedCapture(
    amount: amount,
    amountText: amountText,
    currency: currency,
    direction: direction == TxnDirection.credit ? 'credit' : 'debit',
    merchant:
        _merchantGrounded(candidate.merchant, text) ? candidate.merchant : null,
    last4: _last4Grounded(candidate.last4, text) ? candidate.last4 : null,
    occurredAt: _inWindow(candidate.occurredAt, receivedAt),
  ));
}
