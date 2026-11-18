/// PHASE 2 — the MINIMAL deterministic evidence layer.
///
/// ## What this is
///
/// A pure function from a captured message to the smallest set of deterministic
/// facts a future proof checker needs to decide a financial commit: the numbers,
/// the currencies, the transaction-state cues and the direction cues — each with
/// its EXACT source span, so any later claim can be traced back to characters in
/// the original text.
///
/// ## What it deliberately is NOT
///
/// Not the research evidence graph. Merchant spans, dates, times, IBAN and
/// masked-card nodes are **deferred** until a measured need appears: every extra
/// class costs code, privacy surface and — because a later phase serialises this
/// into a request bounded by `MAX_BODY_BYTES = 8192` — payload budget.
/// [EvidenceClass] plus the versioned envelope are the extension mechanism.
///
/// ## No second money tokenizer
///
/// The complete-token boundary and the canonical value both come from the
/// EXISTING money contract: [normalizeLocalizedDecimal] decides what a valid,
/// unambiguous amount is, and it is the same function `parseCaptureMoney` uses
/// for ledger ingress. This layer only finds token BOUNDARIES and asks that
/// function what they mean. A competing normalizer here would be a second
/// definition of "how much money is this", which is precisely the class of bug
/// the whole proof architecture exists to prevent.
///
/// No AI is involved at any point in this file.
library;

import '../../domain/finance/currency_scale.dart';
import '../../domain/finance/money_input.dart';
import '../parser/direction_signal.dart';
import '../privacy/sanitization_edit_map.dart';

/// The evidence classes this phase produces. Values are wire-stable: they are
/// serialised, so they may be ADDED to but never renumbered or renamed.
enum EvidenceClass {
  number('NUMBER'),
  currency('CURRENCY'),
  stateCue('STATE_CUE'),
  directionCue('DIRECTION_CUE');

  const EvidenceClass(this.wire);
  final String wire;
}

/// What a state cue proves — and nothing more. A cue is lexical evidence, not a
/// conclusion: `declined` means the word "declined" appeared at this span, not
/// that the transaction is definitively void.
enum StateCueKind {
  completed('completed'),
  declined('declined'),
  pending('pending'),
  otp('otp'),
  promotional('promotional'),
  balanceOnly('balance_only'),

  /// An UNPAID FUTURE OBLIGATION — a bill reminder, a statement due date, a
  /// minimum payment. Distinct from `pending`, which is a transaction already
  /// in flight.
  ///
  /// This exists because `Payment due SAR 90.00 on 12/07` reached
  /// commitability in the rev-5 supplement: the direction layer read
  /// `Payment` as an outgoing cue and one clean amount candidate survived, so
  /// nothing deterministic stood between a bill reminder and a booked
  /// transaction except the model's own `state` field. A future obligation is
  /// money that has NOT moved, and that must not depend on the model.
  obligationDue('obligation_due');

  const StateCueKind(this.wire);
  final String wire;
}

/// Direction polarity carried by a lexical cue. This is the D1 source of the
/// approved Phase-0 direction policy — the only class of evidence in this layer
/// that may corroborate a direction claim.
enum DirectionCuePolarity {
  incoming('incoming'),
  outgoing('outgoing');

  const DirectionCuePolarity(this.wire);
  final String wire;
}

/// One deterministic fact with an exact source span.
///
/// ## Span convention — declared once, used end-to-end
///
/// [start] and [end] are **UTF-16 code-unit offsets** into the ORIGINAL,
/// unmodified message string, matching Dart's native `String` indexing and
/// `substring` semantics. This is stated explicitly because a later phase
/// serialises spans across a JSON boundary to a JavaScript runtime, which also
/// indexes UTF-16 — so the two agree by construction. Astral-plane characters
/// (emoji) therefore consume TWO units on both sides, and a Dart-vs-JS span
/// mismatch cannot silently arise. `text` is always exactly
/// `source.substring(start, end)`, which [EvidenceSet.verifySpans] asserts.
class Evidence {
  const Evidence({
    required this.id,
    required this.evidenceClass,
    required this.text,
    required this.start,
    required this.end,
    this.canonical,
    this.iso,
    this.scale,
    this.stateCue,
    this.directionPolarity,
  });

  /// Stable within one [EvidenceSet]: `NUMBER_1`, `CURRENCY_2`, …
  final String id;
  final EvidenceClass evidenceClass;

  /// The exact source substring. Never normalised, never trimmed.
  final String text;
  final int start;
  final int end;

  /// For [EvidenceClass.number]: the canonical decimal string produced by the
  /// EXISTING money normalizer, or null when the token is not an unambiguous
  /// amount (e.g. `12,50`). A null canonical is a deliberate refusal, not a
  /// failure: the token stays visible as evidence but can never be read as
  /// money.
  final String? canonical;

  /// For [EvidenceClass.currency]: ISO code and minor-unit scale.
  final String? iso;
  final int? scale;

  final StateCueKind? stateCue;
  final DirectionCuePolarity? directionPolarity;

  /// Number of fractional digits in [canonical], or null when there is none.
  int? get decimals {
    final c = canonical;
    if (c == null) return null;
    final dot = c.indexOf('.');
    return dot < 0 ? 0 : c.length - dot - 1;
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'k': evidenceClass.wire,
        't': text,
        's': start,
        'e': end,
        if (canonical != null) 'c': canonical,
        if (iso != null) 'iso': iso,
        if (scale != null) 'sc': scale,
        if (stateCue != null) 'st': stateCue!.wire,
        if (directionPolarity != null) 'd': directionPolarity!.wire,
      };

  @override
  String toString() => '$id(${evidenceClass.wire} "$text" $start-$end)';
}

/// The versioned envelope. Versioning exists from day one so Phase 4 can freeze
/// a contract without rewriting this layer; the version is NOT the proof-v1
/// contract, which is not frozen yet.
class EvidenceSet {
  const EvidenceSet({required this.source, required this.items});

  /// Wire format version of the evidence envelope itself.
  static const int version = 1;

  final String source;
  final List<Evidence> items;

  Iterable<Evidence> ofClass(EvidenceClass c) =>
      items.where((e) => e.evidenceClass == c);

  Evidence? byId(String id) {
    for (final e in items) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Every span must reproduce its own text from the source. A violation means
  /// an offset bug, which would let a later phase attribute a number to the
  /// wrong characters — so it is an assertion, not a warning.
  bool verifySpans() {
    for (final e in items) {
      if (e.start < 0 || e.end > source.length || e.start >= e.end) return false;
      if (source.substring(e.start, e.end) != e.text) return false;
    }
    return true;
  }

  /// The node cap that makes the envelope BOUNDED BY CONSTRUCTION.
  ///
  /// Measured: a typical bank SMS yields 7–8 nodes / ~600 bytes, but a dense
  /// 2000-character message — the server's own `MAX_SMS_LENGTH` — yields 287
  /// nodes / ~24 KB, three times the `MAX_BODY_BYTES = 8192` request cap. An
  /// unbounded envelope therefore cannot satisfy the payload constraint, so the
  /// cap is part of the design rather than a hope about input size.
  ///
  /// Sized against the DECLARED 3 KB budget rather than the budget being moved
  /// to fit a chosen cap: measured Arabic evidence runs ~85 bytes/node (Arabic
  /// is multi-byte, so a character-count estimate understates it), 40 nodes
  /// produced 3.2–3.4 KB and overran. 32 nodes lands under 3 KB with margin and
  /// is still 4x the 7–8 nodes a typical bank SMS produces.
  static const int maxNodes = 32;

  /// Deterministic serialisation. The `src` field is deliberately EXCLUDED: the
  /// raw message is not evidence, it is the thing evidence points at, and a
  /// later phase sends a sanitized text separately. Including it here would
  /// double the payload and leak raw content into every consumer.
  ///
  /// TRUNCATION IS REPORTED, NEVER SILENT. When a message produces more than
  /// [maxNodes] items the envelope keeps the first [maxNodes] in source order
  /// (deterministic) and sets `tr: true` with the omitted count. A truncated
  /// set means THE EVIDENCE IS INCOMPLETE — a later checker must refuse to
  /// prove from it rather than assume the amount survived the cut. Silently
  /// dropping evidence would be the worst possible failure here: it could
  /// remove the very token that made a wrong answer detectable.
  Map<String, Object?> toJson({int? maxNodes}) {
    final cap = maxNodes ?? EvidenceSet.maxNodes;
    final kept = items.length <= cap ? items : items.sublist(0, cap);
    final omitted = items.length - kept.length;
    return {
      'v': version,
      'n': items.length,
      if (omitted > 0) 'tr': true,
      if (omitted > 0) 'om': omitted,
      'ev': [for (final e in kept) e.toJson()],
    };
  }

  /// True when this set exceeds the serialisation cap, i.e. any serialised form
  /// of it is incomplete. Exposed so a caller can branch BEFORE serialising.
  bool get exceedsNodeCap => items.length > maxNodes;
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Any run of digits (Western, Arabic-Indic U+0660–0669, Persian U+06F0–06F9)
/// together with the separators that may appear INSIDE one number. Matching is
/// MAXIMAL: `9,500.00` is one token, so no sub-run such as `9` or `500.00` can
/// ever be offered as an independent financial candidate.
final RegExp _numberToken = RegExp(
  r'[0-9٠-٩۰-۹]'
  r'[0-9٠-٩۰-۹,٬،.٫  ]*'
  r'[0-9٠-٩۰-۹]'
  r'|[0-9٠-٩۰-۹]',
);

/// Trailing separators are punctuation, not part of the number: in
/// `... 45.750.` the final dot ends the sentence.
const _trailing = {',', '٬', '،', '.', '٫', ' ', ' ', ' '};

/// State cues, longest-first per kind so `تم رفض` wins over `تم`.
const Map<StateCueKind, List<String>> _stateCues = {
  StateCueKind.declined: [
    'مرفوضة', 'مرفوض', 'رفض', 'فشلت', 'فشل', 'لم يتم',
    'declined', 'rejected', 'failed', 'unsuccessful', 'insufficient',
  ],
  StateCueKind.pending: [
    'معلقة', 'معلق', 'قيد المعالجة', 'قيد',
    'pending', 'on hold', 'pre-auth', 'preauth', 'authorization', 'authorisation',
  ],
  StateCueKind.otp: [
    'رمز التحقق', 'كلمة المرور لمرة واحدة', 'رمز', 'كود التحقق',
    'لا تشاركه', 'لا تشارك',
    'otp', 'one-time', 'one time password', 'verification code', 'do not share',
  ],
  StateCueKind.promotional: [
    'عرض خاص', 'خصومات', 'اشترك الآن', 'تهانينا', 'ربحت',
    'offer', 'discount', 'sale', 'congratulations', 'unsubscribe', 'promo',
  ],
  StateCueKind.balanceOnly: [
    'رصيدكم الحالي', 'الرصيد المتاح', 'الرصيد', 'رصيد', 'المتاح', 'المتبقي',
    'available balance', 'current balance', 'balance', 'avl bal', 'avlbl',
  ],
  StateCueKind.completed: [
    'تمت العملية', 'تم بنجاح', 'تم خصم', 'تم إضافة', 'تم اضافة', 'تم السحب',
    // Settlement wording. An explicit statement that money HAS moved outranks
    // an obligation phrase in the same message: `Amount due has been settled`
    // is a completed transaction that merely mentions the obligation it
    // cleared. Latin needles are boundary-matched, so `paid` cannot fire
    // inside `unpaid`.
    'تم السداد', 'تم الدفع', 'مدفوع',
    'completed', 'successful', 'approved', 'settled', 'paid',
  ],
  // PHRASE-SCOPED, never the bare word `due`. `due` alone appears in `due to`,
  // in `total due` as an amount label, and in ordinary prose; on its own it
  // says nothing about whether money has moved. Each entry below asserts an
  // obligation as a STATE.
  //
  // Deliberately ABSENT: `المبلغ الإجمالي المستحق`. That is an AMOUNT label —
  // it names which number is not the transaction, which is `totalDueRules`
  // territory — and it appears inside completed purchase notifications. The
  // two axes are kept separate: total-due decides WHICH NUMBER, obligation-due
  // decides WHETHER MONEY MOVED.
  StateCueKind.obligationDue: [
    'minimum payment due', 'min payment due', 'minimum amount due',
    'payment is due', 'payment due', 'amount due', 'total due by',
    'due by', 'due on', 'please pay', 'kindly pay', 'pay before',
    'مستحق السداد', 'تستحق السداد', 'يستحق السداد',
    'تاريخ الاستحقاق', 'موعد الاستحقاق', 'الحد الأدنى للسداد',
    'يرجى السداد', 'برجاء السداد', 'يرجى الدفع',
  ],
};

/// Builds the minimal evidence set for [source].
///
/// Pure: same input, same output. No clock, no network, no model, no I/O.
EvidenceSet extractEvidence(String source) {
  final items = <Evidence>[];
  var numberSeq = 0;
  var currencySeq = 0;
  var stateSeq = 0;
  var directionSeq = 0;

  // ---- NUMBER ------------------------------------------------------------
  for (final m in _numberToken.allMatches(source)) {
    final start = m.start;
    var end = m.end;
    while (end > start && _trailing.contains(source[end - 1])) {
      end--;
    }
    if (end <= start) continue;
    final text = source.substring(start, end);

    // The canonical value comes from the EXISTING money contract. When that
    // contract refuses the token (ambiguous grouping such as `12,50`), the
    // node is still emitted — visible, but with no readable amount.
    String? canonical;
    try {
      canonical = normalizeLocalizedDecimal(text);
    } on MoneyInputException {
      canonical = null;
    } catch (_) {
      canonical = null;
    }

    items.add(Evidence(
      id: 'NUMBER_${++numberSeq}',
      evidenceClass: EvidenceClass.number,
      text: text,
      start: start,
      end: end,
      canonical: canonical,
    ));
  }

  // ---- CURRENCY ----------------------------------------------------------
  // Deterministic aliases only, sourced from the production Normalizer's own
  // rule set. This layer may not invent a currency.
  for (final span in _currencySpans(source)) {
    final iso = span.iso;
    items.add(Evidence(
      id: 'CURRENCY_${++currencySeq}',
      evidenceClass: EvidenceClass.currency,
      text: source.substring(span.start, span.end),
      start: span.start,
      end: span.end,
      iso: iso,
      scale: isSupportedCurrency(iso) ? currencyScale(iso) : null,
    ));
  }

  // ---- STATE CUES --------------------------------------------------------
  final lower = source.toLowerCase();
  for (final entry in _stateCues.entries) {
    for (final span in _matchLongestFirst(lower, entry.value)) {
      items.add(Evidence(
        id: 'STATE_CUE_${++stateSeq}',
        evidenceClass: EvidenceClass.stateCue,
        text: source.substring(span.$1, span.$2),
        start: span.$1,
        end: span.$2,
        stateCue: entry.key,
      ));
    }
  }

  // ---- DIRECTION CUES (D1 only) ------------------------------------------
  // Reuses the production DirectionSignal vocabulary so the proof layer and the
  // existing contradiction guard can never disagree about what a cue means.
  for (final span in _matchLongestFirst(lower, DirectionSignal.creditWords)) {
    items.add(Evidence(
      id: 'DIRECTION_CUE_${++directionSeq}',
      evidenceClass: EvidenceClass.directionCue,
      text: source.substring(span.$1, span.$2),
      start: span.$1,
      end: span.$2,
      directionPolarity: DirectionCuePolarity.incoming,
    ));
  }
  for (final span in _matchLongestFirst(lower, DirectionSignal.debitWords)) {
    items.add(Evidence(
      id: 'DIRECTION_CUE_${++directionSeq}',
      evidenceClass: EvidenceClass.directionCue,
      text: source.substring(span.$1, span.$2),
      start: span.$1,
      end: span.$2,
      directionPolarity: DirectionCuePolarity.outgoing,
    ));
  }

  items.sort((a, b) => a.start.compareTo(b.start));
  return EvidenceSet(source: source, items: items);
}

class _CurrencySpan {
  const _CurrencySpan(this.start, this.end, this.iso);
  final int start;
  final int end;
  final String iso;
}

/// Currency alias → ISO, mirroring `Normalizer.normalizeCurrencyTokens` in the
/// same first-match-wins order. Kept as spans (the Normalizer rewrites text and
/// therefore cannot report offsets).
final List<(RegExp, String)> _currencyRules = [
  (RegExp(r'ر\.س\.?'), 'SAR'),
  (RegExp(r'ر\.ع\.?'), 'OMR'),
  (RegExp(r'ر\.ق\.?'), 'QAR'),
  (RegExp(r'د\.إ\.?'), 'AED'),
  (RegExp(r'د\.ك\.?'), 'KWD'),
  (RegExp(r'د\.ب\.?'), 'BHD'),
  (RegExp(r'ج\.م\.?'), 'EGP'),
  (RegExp('﷼'), 'SAR'),
  (RegExp(r'ريال\s+سعودي'), 'SAR'),
  (RegExp(r'ريال\s+عماني'), 'OMR'),
  (RegExp(r'ريال\s+قطري'), 'QAR'),
  (RegExp(r'درهم\s+إماراتي|درهم\s+اماراتي'), 'AED'),
  (RegExp(r'دينار\s+كويتي'), 'KWD'),
  (RegExp(r'دينار\s+بحريني'), 'BHD'),
  (RegExp(r'جنيه\s+مصري'), 'EGP'),
  // ISO literals are derived from `kDetectionCurrencyScale` (closure round:
  // split from the STORAGE registry `kCurrencyScale`, which now holds every
  // ISO code — many of them ordinary words) rather than from a hand-maintained
  // list. A hardcoded alternation here had silently drifted from the registry:
  // JPY is a supported currency with a registered scale of 0, but the literal
  // list omitted it, so the evidence layer emitted no CURRENCY node for
  // `JPY 259` and the amount had nothing to anchor it. That divergence was
  // measured at 29 of 817 corpus rows against the research extractor.
  //
  // Deriving the pattern means a currency added to the registry is exposed as
  // evidence automatically, and the two can no longer disagree about what
  // money this app understands.
  (_isoLiteralPattern, r'$1'),
];

/// `(?<![A-Za-z])(AED|BHD|…)(?![A-Za-z])` over every registered currency.
///
/// SORTED and ESCAPED, both deliberately:
///
///   sorted  — `Map.keys` iterates in insertion order, so the pattern would
///             otherwise change shape whenever someone reordered an entry in
///             `kDetectionCurrencyScale`. This regex is hashed into the
///             Phase-4 seal;
///             a contract artefact whose bytes depend on the order of an
///             unrelated literal is not a contract. Sorting makes the derived
///             pattern a pure function of the SET of supported currencies.
///
///   escaped — every ISO-4217 code is three ASCII letters today, so escaping
///             is a no-op right now. It is here because the alternative is a
///             registry edit silently becoming regex syntax: a stray `.` or
///             `|` in a key would turn a currency into a wildcard that matches
///             text which is not a currency at all, and the evidence layer
///             would start anchoring amounts to nothing. Escaping costs
///             nothing and removes the possibility.
///
/// Ordering within the alternation does not affect which code matches: all
/// codes are the same length and the boundaries are anchored.
final RegExp _isoLiteralPattern = _buildIsoLiteralPattern();

/// The exact source of the ISO literal regex, so a test can pin it byte for
/// byte (currency_storage_detection_split_test.dart).
String get isoLiteralPatternSource => _isoLiteralPattern.pattern;

RegExp _buildIsoLiteralPattern() {
  final codes = kDetectionCurrencyScale.keys.toList()..sort();
  final escaped = codes.map(RegExp.escape).join('|');
  return RegExp('(?<![A-Za-z])($escaped)(?![A-Za-z])', caseSensitive: false);
}

List<_CurrencySpan> _currencySpans(String source) {
  final claimed = <(int, int)>[];
  final out = <_CurrencySpan>[];
  bool overlaps(int s, int e) =>
      claimed.any((c) => !(e <= c.$1 || s >= c.$2));

  for (final (rx, iso) in _currencyRules) {
    for (final m in rx.allMatches(source)) {
      if (overlaps(m.start, m.end)) continue;
      claimed.add((m.start, m.end));
      out.add(_CurrencySpan(
        m.start,
        m.end,
        iso == r'$1' ? m.group(1)!.toUpperCase() : iso,
      ));
    }
  }
  out.sort((a, b) => a.start.compareTo(b.start));
  return out;
}

final RegExp _latinNeedle = RegExp(r'^[a-z0-9 /.-]+$');
final RegExp _latinWordChar = RegExp('[a-z0-9]');

/// True when a Latin match is a whole word rather than a fragment of one.
///
/// Without this, `refund` matches inside `non-refundable` and a "no refunds"
/// promotional line acquires INCOMING polarity — the precise false-incoming
/// risk that admitting refund vocabulary introduces. `refunded` is therefore
/// carried as its own needle rather than relied on as a `refund` prefix.
///
/// Latin needles only. Arabic attaches clitic prefixes directly to the stem
/// (`وارد`, `بالرصيد`), so a boundary requirement there would silently stop
/// matching real cues — the same asymmetry `cue_roles.dart` already applies.
bool _needleBoundaryOk(String lower, int i, int j) {
  final before = i > 0 ? lower[i - 1] : ' ';
  final after = j < lower.length ? lower[j] : ' ';
  return !_latinWordChar.hasMatch(before) && !_latinWordChar.hasMatch(after);
}

/// Non-overlapping literal matches, longest needle first so a longer cue is
/// never fragmented by a shorter one it contains.
List<(int, int)> _matchLongestFirst(String lowerSource, List<String> needles) {
  final claimed = <(int, int)>[];
  final sorted = [...needles]..sort((a, b) => b.length.compareTo(a.length));
  for (final n in sorted) {
    if (n.isEmpty) continue;
    final needle = n.toLowerCase();
    final latin = _latinNeedle.hasMatch(needle);
    var from = 0;
    while (true) {
      final i = lowerSource.indexOf(needle, from);
      if (i < 0) break;
      final j = i + needle.length;
      from = i + 1;
      if (latin && !_needleBoundaryOk(lowerSource, i, j)) continue;
      if (claimed.any((c) => !(j <= c.$1 || i >= c.$2))) continue;
      claimed.add((i, j));
    }
  }
  claimed.sort((a, b) => a.$1.compareTo(b.$1));
  return claimed;
}

/// PHASE 6 — project an evidence set computed on the ORIGINAL message onto the
/// SANITIZED text that is actually transmitted.
///
/// Evidence is extracted from the original because that is where the money
/// contract, the deterministic parser and the true token boundaries live. But
/// the model only ever sees the sanitized text, so it selects evidence by
/// looking at THAT. Shipping original-coordinate spans alongside sanitized text
/// is the stale-offset bug in its purest form: the ids resolve, the spans look
/// valid, and they describe different characters.
///
/// Rules, in order of importance:
///   · a node whose span touches a redaction is DROPPED. Not shortened, not
///     moved to the nearest surviving offset — an amount that overlapped a
///     card number is not a slightly different amount, it is unknown;
///   · a surviving node must quote its own text in the sanitized string, and
///     that is verified here rather than trusted;
///   · dropping is not truncation. `exceedsNodeCap` still means "the envelope
///     was too small", which is a different failure from "this evidence was
///     redacted", and the two must not be conflated.
EvidenceSet projectOntoSanitized(EvidenceSet evidence, SanitizedSms sanitized) {
  final kept = <Evidence>[];
  for (final e in evidence.items) {
    final mapped = sanitized.mapSpan(e.start, e.end);
    if (mapped == null) continue; // redacted or straddling — dropped
    if (sanitized.text.substring(mapped.$1, mapped.$2) != e.text) {
      continue; // refuses to emit a span that does not quote itself
    }
    kept.add(Evidence(
      id: e.id,
      evidenceClass: e.evidenceClass,
      text: e.text,
      start: mapped.$1,
      end: mapped.$2,
      canonical: e.canonical,
      iso: e.iso,
      scale: e.scale,
      stateCue: e.stateCue,
      directionPolarity: e.directionPolarity,
    ));
  }
  return EvidenceSet(source: sanitized.text, items: kept);
}
