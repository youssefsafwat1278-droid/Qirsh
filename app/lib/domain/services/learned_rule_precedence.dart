import '../../data/catalog/catalog_daos.dart';
import '../../engine/dedup/transaction_dedup.dart';
import '../repositories/merchant_category_repository.dart';

/// The `merchant_keywords.priority` the server reserves for a mapping
/// published by shared category learning (auto-approved, or approved by an
/// admin on the shared-learning page): `merchant_category_shared_priority()`
/// in 20261116190000_shared_mapping_marker.sql. No other writer uses it.
const sharedLearningKeywordPriority = 1000;

/// A category that outranks an external (AI / server) category.
/// [userConfirmed] is true for the user's own rule, false for a shared
/// mapping.
typedef CategoryOverAi = ({String categoryKey, bool userConfirmed});

/// The ONE place a category supplied from outside the on-device categorizer
/// (the cloud AI parse, or a server-analysed capture) meets the merchant
/// rules that outrank it.
///
/// Precedence:
/// 1. A rule the user confirmed ("Remember for this merchant") — the user has
///    said what this merchant means.
/// 2. A shared-learning mapping for EXACTLY this merchant (normalised name
///    equal to the keyword, reserved [sharedLearningKeywordPriority]) — many
///    users agreed, or an admin approved it.
/// 3. Otherwise null: the external category is used exactly as before.
///    Other catalog keywords (curated lists, Places enrichment, seed) do NOT
///    outrank it: they are substring guesses, and the AI is better informed.
///
/// [loadRemoteKeywords] is only called when there is no confirmed rule.
Future<CategoryOverAi?> learnedRuleCategoryFor(
  MerchantCategoryRepository? rules,
  String? rawMerchant, {
  Future<List<RemoteMerchantKeyword>> Function()? loadRemoteKeywords,
}) async {
  final merchant = rawMerchant?.trim();
  if (merchant == null || merchant.isEmpty) return null;
  final confirmed = await rules?.userConfirmedCategoryFor(merchant);
  if (confirmed != null) {
    return (categoryKey: confirmed, userConfirmed: true);
  }
  if (loadRemoteKeywords == null) return null;
  final key = TransactionDedup.normalizeMerchant(merchant);
  if (key.isEmpty) return null;
  for (final kw in await loadRemoteKeywords()) {
    if (kw.priority == sharedLearningKeywordPriority &&
        kw.isActive &&
        !kw.isDeleted &&
        TransactionDedup.normalizeMerchant(kw.keyword) == key) {
      return (categoryKey: kw.categoryKey, userConfirmed: false);
    }
  }
  return null;
}
