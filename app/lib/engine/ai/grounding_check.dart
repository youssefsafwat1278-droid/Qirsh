import '../parser/normalizer.dart';

/// Amount grounding for an AI candidate: the amount must equal a WHOLE numeric
/// token of the text — never a fragment of a card number, balance or date
/// (DATA-03). Port of `amountTokens` / `amountGrounded` in
/// `supabase/functions/_shared/ai_candidate_validator.ts`.
class GroundingCheck {
  static bool verify({required double amount, required String sanitizedText}) {
    if (amount <= 0) return false;
    return amountTokens(sanitizedText).any((t) => (t - amount).abs() < 0.005);
  }

  /// A maximal digit run with digit-flanked group/decimal separators (ASCII
  /// or Arabic), so a longer number never yields a sub-token.
  static final RegExp _numericToken =
      RegExp(r'[0-9٠-٩۰-۹]+(?:[,٬.٫][0-9٠-٩۰-۹]+)*');
  static final RegExp _dateTimeSepBefore = RegExp(r'[0-9٠-٩۰-۹][-/:]$');
  static final RegExp _dateTimeSepAfter = RegExp(r'^[-/:][0-9٠-٩۰-۹]');
  static final RegExp _last4Prefix = RegExp(
    r'(?:[*•xX]|(?:ending|ends|acct|account|a/c|card|بطاقة|حساب|رقم|تنتهي|منتهية)'
    r'(?:\s+(?:in|with|no\.?|number|#|بـ|ب))?[\s:#.-]*)$',
    caseSensitive: false,
  );
  static final RegExp _canonical =
      RegExp(r'^(?:0|[1-9][0-9]*|[1-9][0-9]{0,2}(?:,[0-9]{3})+)(?:\.[0-9]+)?$');

  /// Values of every standalone numeric token that may be an amount.
  static List<double> amountTokens(String text) {
    final out = <double>[];
    for (final m in _numericToken.allMatches(text)) {
      if (_dateTimeSepBefore.hasMatch(text.substring(0, m.start)) ||
          _dateTimeSepAfter.hasMatch(text.substring(m.end))) {
        continue;
      }
      if (_last4Prefix.hasMatch(text.substring(0, m.start))) continue;
      final ascii = Normalizer.normalizeDigits(m.group(0)!)
          .replaceAll('٬', ',')
          .replaceAll('٫', '.');
      if (!_canonical.hasMatch(ascii)) continue;
      final value = double.tryParse(ascii.replaceAll(',', ''));
      if (value != null) out.add(value);
    }
    return out;
  }
}
