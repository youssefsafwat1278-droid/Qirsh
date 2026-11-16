import '../repositories/merchant_category_repository.dart';

/// The ONE place a category supplied from outside the on-device categorizer
/// (the cloud AI parse, or a server-analysed capture) meets the user's own
/// merchant rules.
///
/// Precedence: a rule the user confirmed ("Remember for this merchant") wins
/// over an external category — the user has said what this merchant means.
/// Catalog seed mappings do NOT: they are the app's guess, and the AI's guess
/// is the better-informed one. With no confirmed rule the external category is
/// used exactly as before.
///
/// Returns the confirmed rule's category key, or null when there is none.
Future<String?> learnedRuleCategoryFor(
  MerchantCategoryRepository? rules,
  String? rawMerchant,
) async {
  final merchant = rawMerchant?.trim();
  if (rules == null || merchant == null || merchant.isEmpty) return null;
  return rules.userConfirmedCategoryFor(merchant);
}
