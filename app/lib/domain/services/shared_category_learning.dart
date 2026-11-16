import '../../engine/categorization/category.dart';
import '../../engine/dedup/transaction_dedup.dart';
import '../../engine/privacy/sms_sanitizer.dart';
import '../entities/transaction_entity.dart';
import '../usecases/add_transaction_usecase.dart';

/// What a confirmed merchant rule shares to improve the shared catalog: a
/// normalised merchant key and a category key. Nothing else — no amount,
/// date, message, account, card or free text.
class SharedCategoryContribution {
  const SharedCategoryContribution(this.merchantKey, this.categoryKey);

  final String merchantKey;
  final String categoryKey;

  /// The exact request body. Its keys are pinned by a test and by the server,
  /// which refuses any other key.
  Map<String, String> toJson() =>
      {'merchant_key': merchantKey, 'category_key': categoryKey};
}

/// Categories that describe people or money movement, or say nothing.
const _neverShared = {'transfers', 'income', 'cash', 'other'};

final _anyDigit = RegExp(r'[0-9٠-٩۰-۹]');
final _letter = RegExp(r'\p{L}', unicode: true);

/// The contribution a user-confirmed rule for [transaction] → [categoryKey]
/// may make, or null when it must not be shared at all.
///
/// Only merchant-like rows qualify. A transfer, P2P or wallet movement carries
/// a person's name where the merchant would be, so those are never shared —
/// decided from the stored type, direction and source and from the same
/// transfer wording the parser uses, before anything is built.
SharedCategoryContribution? sharedContributionFor(
  TransactionEntity transaction,
  String categoryKey,
) {
  final raw = transaction.rawMerchant;
  if (raw == null) return null;

  final isRefund = transaction.type == TransactionTypeEntity.refund;
  if (transaction.type != TransactionTypeEntity.payment && !isRefund) {
    return null;
  }
  if (!isRefund && transaction.direction == TransactionDirectionEntity.credit) {
    return null;
  }
  // Wallet movements cannot be told apart from wallet-to-person transfers.
  if (transaction.source == TransactionSourceEntity.wallet) return null;
  final message = transaction.rawMessage;
  if (AddTransactionUseCase.looksLikeTransferMessage(message) ||
      AddTransactionUseCase.looksLikeInternalTransfer(message) ||
      SmsSanitizer.isCounterpartyContext(message)) {
    return null;
  }

  // Built-in spending categories only; a custom category's key is the user's.
  if (_neverShared.contains(categoryKey) ||
      Categories.byKey(categoryKey).key != categoryKey) {
    return null;
  }

  final key = sharedMerchantKeyFor(raw);
  return key == null ? null : SharedCategoryContribution(key, categoryKey);
}

/// The shared-catalog key for [raw], or null when that merchant text could
/// carry an identifier and must never leave the device.
String? sharedMerchantKeyFor(String raw) {
  final key = TransactionDedup.normalizeMerchant(raw);
  if (key.length < 3 ||
      key.length > 64 ||
      _anyDigit.hasMatch(key) ||
      key.contains('@') ||
      !_letter.hasMatch(key) ||
      SmsSanitizer.containsIdentifier(raw) ||
      SmsSanitizer.containsIdentifier(key)) {
    return null;
  }
  return key;
}
