import '../../engine/intelligence/merchant_intelligence_store.dart';
import '../repositories/merchant_category_repository.dart';

/// The Settings "Learned rules" list: only rules the user confirmed, with
/// delete and undo. The persisted map stays the source of truth; the on-device
/// model is kept in step after each successful write (OD-13 — it only ever
/// mirrors the user's choices, it never writes a rule itself).
class LearnedRulesUseCase {
  LearnedRulesUseCase({
    required MerchantCategoryRepository merchantCategoryRepository,
    MerchantIntelligenceStore? merchantIntelligence,
  })  : _repository = merchantCategoryRepository,
        _merchantIntelligence = merchantIntelligence;

  final MerchantCategoryRepository _repository;
  final MerchantIntelligenceStore? _merchantIntelligence;

  Future<List<LearnedMerchantRule>> list() =>
      _repository.getUserConfirmedRules();

  Future<void> delete(LearnedMerchantRule rule) async {
    await _repository.forgetUserConfirmedRule(rule.rawMerchant);
    _merchantIntelligence?.forgetUserCorrection(rule.rawMerchant);
  }

  /// Undo of [delete]: puts the same user-confirmed rule back.
  Future<void> restore(LearnedMerchantRule rule) async {
    await _repository.confirmMerchantCategory(
      rawMerchant: rule.rawMerchant,
      categoryKey: rule.categoryKey,
      isUserConfirmed: true,
    );
    _merchantIntelligence?.learnFromUserCorrection(
        rule.rawMerchant, rule.categoryKey);
  }
}
