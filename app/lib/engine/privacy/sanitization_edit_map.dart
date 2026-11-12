/// PHASE 6 — the sanitization edit map.
///
/// ## The problem this exists to solve
///
/// Evidence spans are computed on the ORIGINAL message. The text actually sent
/// for interpretation is the SANITIZED one, and sanitization changes lengths: a
/// 16-digit card becomes `[CARD]`, an account number becomes `[ACCOUNT]`, a
/// greeting disappears entirely. Every offset after an edit shifts.
///
/// So an evidence span carried across that boundary unchanged is a STALE
/// OFFSET. It still looks well-formed — two integers and a piece of text — but
/// it now points at different characters. A proof built on it would be a proof
/// about the wrong part of the message, and nothing downstream could tell.
///
/// This map makes the translation explicit and total:
///
///   · every original offset maps to a sanitized offset, or to NOTHING;
///   · a span that touches redacted text is DROPPED, never remapped. There is
///     no "nearest surviving offset" — an amount that overlapped a redaction is
///     not a slightly different amount, it is unknown;
///   · a surviving span must still reproduce its own text in the sanitized
///     string, and that is asserted rather than assumed.
///
/// ## Why it composes passes instead of rewriting them
///
/// `SmsSanitizer.sanitize` applies its patterns SEQUENTIALLY, each pass reading
/// the previous pass's output. That ordering is load-bearing: after the account
/// pass turns `عزيزي 12345678901` into `عزيزي [ACCOUNT]`, the greeting pass
/// matches the result and removes the whole thing. A single-pass rewrite with
/// priority ordering would redact a different span and produce different text.
///
/// So this file does not reimplement sanitization. It runs the SAME passes in
/// the SAME order and composes their edit maps, which makes the output
/// byte-identical to `SmsSanitizer.sanitize` by construction — asserted by
/// `sanitizeWithMap(...).text == SmsSanitizer.sanitize(...)` in tests.
///
/// ## Offsets are UTF-16 code units
///
/// Dart string indices are UTF-16 code units, and `evidence.dart` already spans
/// in the same units. Emoji and other astral characters occupy two units; the
/// map is index-based and never interprets characters, so it is agnostic to
/// what those units mean. The adversarial tests cover emoji, Arabic-Indic
/// digits and RTL marks explicitly.
library;

import '../models/transaction_type.dart';
import 'sms_sanitizer.dart';

/// One replaced region, in ORIGINAL coordinates, with what replaced it.
class Redaction {
  const Redaction(this.sourceStart, this.sourceEnd, this.label);

  /// Half-open span in the ORIGINAL message.
  final int sourceStart;
  final int sourceEnd;

  /// The sanitizer token that replaced it, e.g. `[CARD]`, or `trim`.
  final String label;

  bool intersects(int start, int end) =>
      start < sourceEnd && sourceStart < end;

  @override
  String toString() => '$label[$sourceStart,$sourceEnd)';
}

/// A sanitized message plus a total, deterministic offset translation back to
/// the text it came from.
class SanitizedSms {
  const SanitizedSms({
    required this.source,
    required this.text,
    required this.redactions,
    required List<int?> offsetMap,
  }) : _offsetMap = offsetMap;

  /// The original message. Never leaves the device.
  final String source;

  /// The sanitized message — the only text that may be transmitted.
  final String text;

  /// Regions of [source] that did not survive, in original coordinates.
  final List<Redaction> redactions;

  /// `_offsetMap[i]` is the sanitized index of original index `i`, or null when
  /// that character was redacted or trimmed away.
  final List<int?> _offsetMap;

  /// The sanitized offset for an original one, or null if it did not survive.
  int? mapOffset(int sourceOffset) {
    if (sourceOffset < 0 || sourceOffset >= _offsetMap.length) return null;
    return _offsetMap[sourceOffset];
  }

  /// The sanitized span for an original one, or null when the span may not be
  /// carried across.
  ///
  /// Returns null when ANY of these hold, and each is a real hazard:
  ///   · the span touches a redaction — it would silently describe different
  ///     characters;
  ///   · any interior character was dropped — the span would still have two
  ///     endpoints but no longer be contiguous;
  ///   · the surviving offsets are not contiguous and ascending — the text
  ///     between them is not the text that was there.
  (int, int)? mapSpan(int sourceStart, int sourceEnd) {
    if (sourceStart < 0 || sourceEnd > source.length || sourceStart >= sourceEnd) {
      return null;
    }
    for (final r in redactions) {
      if (r.intersects(sourceStart, sourceEnd)) return null;
    }
    final first = mapOffset(sourceStart);
    if (first == null) return null;
    var expected = first;
    for (var i = sourceStart; i < sourceEnd; i++) {
      final m = mapOffset(i);
      if (m == null || m != expected) return null; // hole or reordering
      expected++;
    }
    return (first, expected);
  }

  /// Every surviving span must still quote its own text. Cheap, and it is the
  /// difference between believing the map and knowing it.
  bool verifySpan(int sourceStart, int sourceEnd) {
    final mapped = mapSpan(sourceStart, sourceEnd);
    if (mapped == null) return false;
    return text.substring(mapped.$1, mapped.$2) ==
        source.substring(sourceStart, sourceEnd);
  }
}

/// Sanitize [rawSms] and return the text together with its offset map.
///
/// The text is byte-identical to `SmsSanitizer.sanitize(rawSms, ...)`; this
/// runs the same passes in the same order and only additionally records where
/// everything went.
SanitizedSms sanitizeWithMap(String rawSms, {TransactionType? detectedType}) {
  // Current position of every ORIGINAL index; null once destroyed.
  final pos = List<int?>.generate(rawSms.length, (i) => i);
  final redactions = <Redaction>[];
  var current = rawSms;

  /// Apply one pass and fold its edits into `pos`.
  void pass(RegExp re, String Function(Match) replace, String label) {
    final matches = re.allMatches(current).toList();
    if (matches.isEmpty) return;
    // Snapshot liveness so "destroyed by THIS pass" is unambiguous.
    final alive = [for (final p in pos) p != null];

    final buf = StringBuffer();
    // oldIndex -> newIndex for surviving characters of `current`.
    final moved = List<int?>.filled(current.length, null);
    var cursor = 0;
    for (final m in matches) {
      for (var i = cursor; i < m.start; i++) {
        moved[i] = buf.length;
        buf.writeCharCode(current.codeUnitAt(i));
      }
      buf.write(replace(m)); // replacement chars belong to no original index
      cursor = m.end;
    }
    for (var i = cursor; i < current.length; i++) {
      moved[i] = buf.length;
      buf.writeCharCode(current.codeUnitAt(i));
    }

    // Fold: an original index survives only if its current position survives.
    for (var o = 0; o < pos.length; o++) {
      final p = pos[o];
      if (p == null) continue;
      pos[o] = moved[p];
    }

    // Record, in ORIGINAL coordinates, the contiguous runs this pass killed.
    var runStart = -1;
    for (var o = 0; o <= pos.length; o++) {
      final killedHere = o < pos.length && alive[o] && pos[o] == null;
      if (killedHere && runStart < 0) {
        runStart = o;
      } else if (!killedHere && runStart >= 0) {
        redactions.add(Redaction(runStart, o, label));
        runStart = -1;
      }
    }

    current = buf.toString();
  }

  pass(SmsSanitizer.emailPattern, (_) => '[EMAIL]', '[EMAIL]');
  pass(SmsSanitizer.cardNumberPattern, (_) => '[CARD]', '[CARD]');
  pass(SmsSanitizer.saudiPhonePattern, (_) => '[PHONE]', '[PHONE]');
  pass(SmsSanitizer.egyptPhonePattern, (_) => '[PHONE]', '[PHONE]');
  pass(SmsSanitizer.intlPhonePattern, (_) => '[PHONE]', '[PHONE]');
  pass(SmsSanitizer.ibanPattern, (_) => '[IBAN]', '[IBAN]');
  pass(SmsSanitizer.otpPattern, (m) => '${m.group(1)!}[OTP]', '[OTP]');
  pass(SmsSanitizer.accountNumberPattern, (_) => '[ACCOUNT]', '[ACCOUNT]');
  pass(SmsSanitizer.referencePattern, (m) => '${m.group(1)!}[REF]', '[REF]');
  pass(SmsSanitizer.salutationPattern, (m) => '${m.group(1)!}[NAME]',
      '[NAME]');
  if (SmsSanitizer.isCounterpartyContext(current)) {
    pass(SmsSanitizer.counterpartyPattern, (m) => '${m.group(1)!}[NAME]',
        '[NAME]');
  }

  final stripBeneficiary = detectedType == null ||
      detectedType == TransactionType.transfer ||
      detectedType == TransactionType.income;
  if (stripBeneficiary) {
    pass(SmsSanitizer.beneficiaryArPattern, (m) => '${m.group(1)!}: [REDACTED]',
        '[REDACTED]');
    pass(SmsSanitizer.beneficiaryEnPattern, (_) => 'To: [REDACTED]',
        '[REDACTED]');
  }
  pass(SmsSanitizer.greetingPattern, (_) => '[REDACTED]', '[REDACTED]');

  // `sanitize` finishes with .trim(); trimmed characters are dropped, and the
  // remainder shifts left. Modelled as an edit like any other.
  final trimmed = current.trim();
  if (trimmed.length != current.length) {
    final lead = current.length - current.trimLeft().length;
    for (var o = 0; o < pos.length; o++) {
      final p = pos[o];
      if (p == null) continue;
      final np = p - lead;
      pos[o] = (np < 0 || np >= trimmed.length) ? null : np;
    }
    current = trimmed;
  }

  return SanitizedSms(
    source: rawSms,
    text: current,
    redactions: List.unmodifiable(redactions),
    offsetMap: List.unmodifiable(pos),
  );
}
