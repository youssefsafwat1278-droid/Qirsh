import 'merchant_classifier.dart';
import 'text_normalizer.dart';

/// The single owner of the on-device merchant model's lifetime.
///
/// ## Why this exists (lifecycle)
///
/// [CharNgramMerchantClassifier] fits ~330 catalog exemplars in its
/// constructor. Capture used to build a fresh one **twice per transaction**
/// (`AddTransactionUseCase`, pre-category and main categorizer), paying ~8.6 ms
/// of construction on this machine to make a ~0.3 ms prediction — and, because
/// no instance outlived a single call, anything the model learned was discarded
/// immediately.
///
/// One long-lived instance fixes both. This is purely a lifecycle change:
/// [predict] delegates unchanged, so for any given input the category a fresh
/// classifier would return and the one this returns are identical.
///
/// ## Why user corrections live here (persistence)
///
/// Corrections are NOT given a new store. They are already persisted by
/// `MerchantCategoryRepository.confirmMerchantCategory`, and this model is
/// rehydrated from that same learned map via [seedFromLearnedMap]. The user's
/// confirmed map stays the single source of truth, so the model cannot drift
/// away from what the user actually chose, and there is no second copy to
/// migrate, back up or reconcile.
///
/// ## What may teach it
///
/// Only an EXPLICIT user category correction, via [learnFromUserCorrection].
/// The model never learns from its own predictions, never from an accepted
/// suggestion, and never from anything off-device. There is no network path in
/// this layer at all — `test/architecture/ai_privacy_test.dart` enforces that
/// structurally.
class MerchantIntelligenceStore implements MerchantIntelligence {
  MerchantIntelligenceStore({CharNgramMerchantClassifier? classifier})
      : _classifier = classifier ?? CharNgramMerchantClassifier();

  final CharNgramMerchantClassifier _classifier;

  /// Merchants already taught to [_classifier], so a repeated seed or a
  /// re-confirmation of the same pair is a no-op rather than a duplicate
  /// exemplar.
  final Set<String> _taught = <String>{};

  @override
  MerchantPrediction? predict(String rawMerchant) =>
      _classifier.predict(rawMerchant);

  /// Rehydrates the model from the user's persisted confirmations.
  ///
  /// Safe to call more than once (app start, and after a restore): re-teaching
  /// the same merchant replaces its exemplar rather than adding another.
  void seedFromLearnedMap(Map<String, String> learnedMap) {
    for (final entry in learnedMap.entries) {
      _teach(entry.key, entry.value);
    }
  }

  /// Records an EXPLICIT user correction as a first-class exemplar.
  ///
  /// Call this only from a user-initiated category correction. Passing a
  /// prediction back in would make the model reinforce its own guesses, which
  /// is the one way an on-device learner can quietly degrade with no signal.
  void learnFromUserCorrection(String rawMerchant, String categoryKey) {
    _teach(rawMerchant, categoryKey);
  }

  /// Withdraws a correction the user has since deleted, so the model stops
  /// suggesting a category the user no longer wants for this merchant.
  void forgetUserCorrection(String rawMerchant) {
    final norm = normalizeMerchant(rawMerchant);
    _taught.removeWhere(
        (key) => normalizeMerchant(key.split('\u0000').first) == norm);
    _classifier.forget(rawMerchant);
  }

  void _teach(String rawMerchant, String categoryKey) {
    if (rawMerchant.trim().isEmpty || categoryKey.trim().isEmpty) return;
    // NUL separator: it cannot occur in a merchant name, so the composite
    // key is unambiguous. Written as an ESCAPE, never a raw byte — a
    // literal NUL in source makes git treat the whole file as binary, so
    // it stops producing diffs and silently drops out of code review.
    final key = '$rawMerchant\u0000$categoryKey';
    if (!_taught.add(key)) return;
    _classifier.learn(rawMerchant, categoryKey);
  }

  /// Diagnostics only.
  int get learnedCount => _classifier.learnedCount;
  int get exemplarCount => _classifier.exemplarCount;
}
