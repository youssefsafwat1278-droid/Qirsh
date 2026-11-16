import 'dart:math' as math;

import '../categorization/category_seeds.dart';
import 'text_normalizer.dart';

/// On-device merchant understanding and category prediction (OD-13).
///
/// ## Why this shape, and not a neural model
///
/// The measured labelled message corpus is ~37 examples and is known to be
/// contaminated by a prior parser defect (F-015). That is too small to TRAIN on
/// and — the decisive part — too small to EVALUATE with, so a shipped neural
/// model's accuracy could not be stated, let alone defended. Consent is
/// off-by-default and fail-closed, so no corpus-collection pipeline exists that
/// would change that.
///
/// The training data the app actually has is the merchant→category catalog it
/// already ships: ~330 real labelled pairs, Arabic and Latin, uncontaminated.
/// Read that way this is not a consolation prize — a char-n-gram model is the
/// RIGHT tool for short, noisy, transliterated merchant strings, which is a
/// character-level entity-matching problem rather than a sentence-semantics one.
///
/// Cost: zero per request, zero model asset, zero native dependency, no app-size
/// or battery story to defend. It runs in pure Dart in well under a millisecond.
///
/// ## The write fence (OD-11, OD-13)
///
/// This model may influence exactly two things: a suggested CATEGORY, and a
/// normalised merchant DISPLAY name. It must never touch amount, currency,
/// direction, date, account or card identity, balances, any canonical `_minor`
/// money field, or dedup/identity/sync keys. [normalizedMerchant] is a matching
/// key and a display candidate — never a join key, never a persisted identity.
///
/// ## Abstention is the product promise
///
/// Below [confidenceFloor] the model returns null rather than guessing. The
/// promise is precision when it speaks, not coverage.

/// A single scored suggestion. Carries its own provenance so a caller cannot
/// accidentally launder a model guess into deterministic-looking state.
class MerchantPrediction {
  const MerchantPrediction({
    required this.categoryKey,
    required this.confidence,
    required this.normalizedMerchant,
    required this.matchedSeed,
  });

  final String categoryKey;

  /// Cosine similarity in [0, 1]. Never a probability — it is not calibrated as
  /// one, and treating it as one would overstate what it knows.
  final double confidence;

  /// The matching key (lossy — see `normalizeMerchant`).
  final String normalizedMerchant;

  /// Which catalog entry produced this. Makes every suggestion explainable and
  /// lets a wrong prediction be traced to the seed responsible.
  final String matchedSeed;
}

/// The boundary the app depends on. A different implementation (including an
/// embedded neural one, should a real corpus ever justify it) may be swapped in
/// without the domain layer knowing.
abstract class MerchantIntelligence {
  /// Returns null when the model is not confident enough to speak.
  MerchantPrediction? predict(String rawMerchant);
}

/// TF-IDF weighted character n-gram nearest-neighbour over the seeded catalog.
class CharNgramMerchantClassifier implements MerchantIntelligence {
  CharNgramMerchantClassifier({
    Map<String, String>? seeds,
    this.confidenceFloor = 0.62,
    this.minN = 2,
    this.maxN = 4,
  }) : _seeds = seeds ?? CategorySeeds.keywordRules {
    _fit();
  }

  final Map<String, String> _seeds;

  /// Below this cosine similarity the model abstains. Tuned so that near-variant
  /// forms match while unrelated merchants do not; the evaluation harness pins
  /// the precision this buys.
  final double confidenceFloor;
  final int minN;
  final int maxN;

  /// Per-seed L2-normalised sparse vectors, keyed by normalised seed text.
  final List<_Exemplar> _exemplars = [];

  /// Inverse document frequency per n-gram, learned from the seed catalog.
  final Map<String, double> _idf = {};

  /// User corrections learned on-device. These take part in matching exactly
  /// like catalog seeds, so the model measurably diverges from its shipped state
  /// as the user corrects it — with zero data leaving the device.
  final List<_Exemplar> _learned = [];

  void _fit() {
    final docs = <String, List<String>>{};
    for (final entry in _seeds.entries) {
      final norm = normalizeMerchant(entry.key);
      if (norm.isEmpty) continue;
      docs[norm] = _ngrams(norm);
    }

    // Document frequency over the seed catalog.
    final df = <String, int>{};
    for (final grams in docs.values) {
      for (final g in grams.toSet()) {
        df[g] = (df[g] ?? 0) + 1;
      }
    }
    final n = docs.length;
    for (final e in df.entries) {
      // Smoothed IDF: a gram shared by every merchant carries no signal.
      _idf[e.key] = math.log((n + 1) / (e.value + 1)) + 1.0;
    }

    for (final entry in _seeds.entries) {
      final norm = normalizeMerchant(entry.key);
      if (norm.isEmpty) continue;
      _exemplars.add(_Exemplar(
        normalized: norm,
        categoryKey: entry.value,
        vector: _vectorize(norm),
        seedLabel: entry.key,
      ));
    }
  }

  List<String> _ngrams(String s) {
    // Pad so prefixes and suffixes are distinguishable: "carrefour" and
    // "mycarrefour" should not look identical at their shared core.
    final padded = ' $s ';
    final out = <String>[];
    for (var n = minN; n <= maxN; n++) {
      if (padded.length < n) continue;
      for (var i = 0; i + n <= padded.length; i++) {
        out.add(padded.substring(i, i + n));
      }
    }
    return out;
  }

  /// L2-normalised TF-IDF vector, so cosine is a plain dot product.
  Map<String, double> _vectorize(String normalized) {
    final counts = <String, double>{};
    for (final g in _ngrams(normalized)) {
      counts[g] = (counts[g] ?? 0) + 1;
    }
    var norm = 0.0;
    final vec = <String, double>{};
    for (final e in counts.entries) {
      // Unseen grams get the maximum IDF: a gram absent from the whole catalog
      // is maximally informative, not worthless.
      final idf = _idf[e.key] ?? (math.log(_exemplars.length + 1.0) + 1.0);
      final w = (1 + math.log(e.value)) * idf;
      vec[e.key] = w;
      norm += w * w;
    }
    if (norm == 0) return const {};
    final inv = 1 / math.sqrt(norm);
    return vec.map((k, v) => MapEntry(k, v * inv));
  }

  double _cosine(Map<String, double> a, Map<String, double> b) {
    // Iterate the smaller vector — both are already L2-normalised.
    final small = a.length <= b.length ? a : b;
    final large = identical(small, a) ? b : a;
    var dot = 0.0;
    for (final e in small.entries) {
      final o = large[e.key];
      if (o != null) dot += e.value * o;
    }
    return dot;
  }

  @override
  MerchantPrediction? predict(String rawMerchant) {
    final norm = normalizeMerchant(rawMerchant);
    if (norm.isEmpty) return null;

    final query = _vectorize(norm);
    if (query.isEmpty) return null;

    _Exemplar? best;
    var bestScore = 0.0;
    // User corrections are considered first and win ties: a merchant the user
    // has personally categorised should not be overridden by a catalog seed.
    for (final ex in [..._learned, ..._exemplars]) {
      final score = _cosine(query, ex.vector);
      if (score > bestScore) {
        bestScore = score;
        best = ex;
      }
    }

    if (best == null || bestScore < confidenceFloor) return null;
    return MerchantPrediction(
      categoryKey: best.categoryKey,
      confidence: bestScore,
      normalizedMerchant: norm,
      matchedSeed: best.seedLabel,
    );
  }

  /// Adds a user correction as a first-class exemplar.
  ///
  /// This is the part a lookup table cannot do: the model personalises to this
  /// user's own merchants, on-device, with no egress.
  void learn(String rawMerchant, String categoryKey) {
    final norm = normalizeMerchant(rawMerchant);
    if (norm.isEmpty) return;
    _learned.removeWhere((e) => e.normalized == norm);
    _learned.add(_Exemplar(
      normalized: norm,
      categoryKey: categoryKey,
      vector: _vectorize(norm),
      seedLabel: rawMerchant,
    ));
  }

  /// Drops a user correction, e.g. when the user deletes the rule it came from.
  /// Catalog seeds are never removed.
  void forget(String rawMerchant) {
    final norm = normalizeMerchant(rawMerchant);
    _learned.removeWhere((e) => e.normalized == norm);
  }

  /// Exposed for the evaluation harness.
  int get exemplarCount => _exemplars.length;
  int get learnedCount => _learned.length;
}

class _Exemplar {
  const _Exemplar({
    required this.normalized,
    required this.categoryKey,
    required this.vector,
    required this.seedLabel,
  });

  final String normalized;
  final String categoryKey;
  final Map<String, double> vector;
  final String seedLabel;
}
