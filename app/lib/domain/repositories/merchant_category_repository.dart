/// A merchant→category rule the user explicitly confirmed ("remember for this
/// merchant"). Seeded catalog mappings are never one of these.
class LearnedMerchantRule {
  const LearnedMerchantRule({
    required this.rawMerchant,
    required this.categoryKey,
  });

  final String rawMerchant;
  final String categoryKey;
}

abstract class MerchantCategoryRepository {
  Future<Map<String, String>> getLearnedCategoryMap();
  Future<bool> hasCategoryForMerchant(String rawMerchant);
  Future<void> confirmMerchantCategory({
    required String rawMerchant,
    required String categoryKey,
    required bool isUserConfirmed,
    double confidence = 1,
  });

  /// Only the rules the user confirmed, newest first.
  Future<List<LearnedMerchantRule>> getUserConfirmedRules();

  /// Removes the user's rule for [rawMerchant]. When the shipped catalog has a
  /// mapping for the same merchant, that seed mapping comes back instead of
  /// the merchant losing its category entirely.
  Future<void> forgetUserConfirmedRule(String rawMerchant);
}
