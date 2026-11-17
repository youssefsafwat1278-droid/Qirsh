import '../../engine/parser/direction_signal.dart';
import '../../engine/models/transaction_type.dart';
import '../../engine/parser/normalizer.dart';
import '../../engine/parser/parser_engine.dart';
import '../../engine/parser/transaction_state_cues.dart';

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

const List<String> kCaptureCurrencyCodes = [
  'SAR',
  'AED',
  'EGP',
  'QAR',
  'OMR',
  'KWD',
  'BHD',
  'JOD',
  'USD',
  'EUR',
  'GBP',
  'JPY',
];

const Map<String, int> _minorUnits = {
  'JPY': 0,
  'EGP': 2,
  'SAR': 2,
  'AED': 2,
  'USD': 2,
  'EUR': 2,
  'GBP': 2,
  'QAR': 2,
  'KWD': 3,
  'BHD': 3,
  'OMR': 3,
  'JOD': 3,
};

const Map<String, List<String>> _extraAliases = {
  'USD': [r'$'],
  'EUR': ['€'],
  'GBP': ['£'],
  'JOD': ['دينار أردني', 'دينار اردني'],
};

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
  final scale =
      currency == null ? null : _minorUnits[currency.trim().toUpperCase()];
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

bool _currencyGrounded(String iso, String text) {
  if (iso.isEmpty) return false;
  final normalized = Normalizer.normalizeCurrencyTokens(text);
  final code = RegExp(
    '(?<![A-Za-z])${RegExp.escape(iso)}(?![A-Za-z])',
    caseSensitive: false,
  );
  if (code.hasMatch(normalized)) return true;
  return (_extraAliases[iso] ?? const <String>[]).any(text.contains);
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
bool localParseOpposesDirection({
  required String text,
  String? direction,
  String? type,
  String? senderId,
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
  return _contradicts(localDirection, server);
}

/// LR-03 / LR-04 — the device's own reading contradicts a server result for
/// [text]: the opposite money direction ([localParseOpposesDirection]), or
/// the device drops the text as not a transaction (an OTP, an advert, an
/// account notice: [ParserEngine.isIgnoredMessage], or a notice the device
/// keeps for review: [ParserEngine.isNoticeMessage]). Neither reading is
/// trusted then: every import path takes its recoverable review outcome
/// (Smart Inbox), never a confirmed row from either side.
bool localParseContradictsServer({
  required String text,
  String? direction,
  String? type,
  String? senderId,
}) =>
    ParserEngine.isIgnoredMessage(text, senderId: senderId) ||
    ParserEngine.isNoticeMessage(text, senderId: senderId) ||
    localParseOpposesDirection(
        text: text, direction: direction, type: type, senderId: senderId);

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
}) {
  const reject = CaptureValidation.rejected;
  // DATA-01 / REV-03 — a declined/failed/cancelled message moved no money,
  // whatever a server (including one deployed before the fix) concluded. The
  // caller then takes its existing rejected path (local parse → Smart Inbox).
  if (TransactionStateCues.isNotCompleted(text)) {
    return reject('transaction_not_completed');
  }
  if (!_amountGrounded(candidate.amount, text)) {
    return reject('amount_not_grounded');
  }
  final amount = candidate.amount!;
  final currency = (candidate.currency ?? '').trim().toUpperCase();
  if (!kCaptureCurrencyCodes.contains(currency)) {
    return reject('currency_not_whitelisted');
  }
  if (!_currencyGrounded(currency, text)) {
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

  final wording = DirectionSignal.detect(text);
  final aiDirection = _asDirection(candidate.direction);
  final typeDirection = _directionOfType(candidate.type);
  if (_contradicts(wording, typeDirection) ||
      _contradicts(wording, aiDirection)) {
    return reject('direction_contradiction');
  }
  // Direction is required: the explicit direction, else the one the type implies.
  final direction =
      aiDirection != TxnDirection.unknown ? aiDirection : typeDirection;
  if (direction == TxnDirection.unknown) return reject('direction_unresolved');

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
