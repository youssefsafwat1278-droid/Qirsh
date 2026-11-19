import 'capture_money.dart';
import 'direction_signal.dart';
import 'parse_result.dart';
import '../models/transaction_type.dart';

/// Why a local parse is not a VALID transaction.
enum LocalInvalidReason {
  notTransaction,
  nonExactMoney,
  missingCurrency,
  currencyDefaulted,
  unknownType,
  directionContradiction,
  uncorroboratedCatalogAmount,
  amountAmbiguous,
  dateAmbiguous,
  proofWithheld,
}

class LocalValidityResult {
  const LocalValidityResult._(this.reason);
  const LocalValidityResult.valid() : this._(null);
  const LocalValidityResult.invalid(LocalInvalidReason reason) : this._(reason);

  /// Null when valid.
  final LocalInvalidReason? reason;

  bool get isValid => reason == null;
}

/// Binary acceptance of a LOCAL parse: valid means confirmed, invalid means
/// "local produced no transaction". Deliberately does NOT consider parse
/// confidence, category confidence or merchant novelty — those describe
/// certainty and taste, not whether the reading is grounded.
class LocalValidity {
  const LocalValidity._();

  /// [proofWithholds] is the armed Proof gate's finding (always false in shadow
  /// mode); the caller computes it because it needs the evaluated proof.
  static LocalValidityResult check({
    required ParseResult parse,
    required String rawMessage,
    required bool proofWithholds,
  }) {
    final txn = parse.transaction;
    if (!parse.isTransaction || txn == null) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.notTransaction);
    }
    // Round 5: a reading of no money ("POS45.00" read as "00") is never a
    // confirmed movement; the capture stays a visible review row.
    if (txn.amount <= 0) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.nonExactMoney);
    }
    if (txn.currency.trim().isEmpty) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.missingCurrency);
    }
    // No currency token in the message: the engine filled in the account's
    // default. That is a guess, so the local reading is not valid.
    if (parse.currencyDefaulted) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.currencyDefaulted);
    }
    if (txn.type == TransactionType.unknown || parse.typeUndetected) {
      return const LocalValidityResult.invalid(LocalInvalidReason.unknownType);
    }
    if (!hasExactCaptureMoney(txn.amountText, txn.currency,
            required: true) ||
        !hasExactCaptureMoney(txn.balanceAfterText, txn.currency,
            required: txn.balanceAfter != null) ||
        !hasExactCaptureMoney(
            txn.foreignAmountText, txn.foreignCurrency ?? txn.currency,
            required: txn.foreignAmount != null)) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.nonExactMoney);
    }
    if (DirectionSignal.contradicts(rawMessage, txn.type)) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.directionContradiction);
    }
    if (parse.catalogAmountCorroborated == false) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.uncorroboratedCatalogAmount);
    }
    if (parse.amountAmbiguous) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.amountAmbiguous);
    }
    if (parse.dateAmbiguous) {
      return const LocalValidityResult.invalid(
          LocalInvalidReason.dateAmbiguous);
    }
    if (proofWithholds) {
      return const LocalValidityResult.invalid(LocalInvalidReason.proofWithheld);
    }
    return const LocalValidityResult.valid();
  }

  /// The SAME exactness test the capture path uses to decide legacy-lossy
  /// review: an exact text token that [parseCaptureMoney] accepts. A value with
  /// no text is legacy-lossy; an absent optional value is fine.
  static bool hasExactCaptureMoney(String? text, String currency,
      {required bool required}) {
    if (text == null) return !required;
    try {
      parseCaptureMoney(text, currency);
      return true;
    } on Exception {
      return false;
    }
  }
}
