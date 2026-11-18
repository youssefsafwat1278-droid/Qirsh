import 'currency_table.dart';

/// تطبيع نص الرسالة قبل الاستخراج (خاص بالسوق السعودي + عام).
///
/// المسؤوليات:
/// - تحويل الأرقام العربية/الهندية إلى غربية (٠-٩ و ۰-۹ → 0-9).
/// - إزالة التطويل (ـ) والمسافات الزائدة.
/// - توحيد كلمات ورموز العملات إلى رموز ISO.
class Normalizer {
  Normalizer._();

  /// Round 3: the ISO codes of [CurrencyTable.iso] that are not in
  /// [isoCurrencyAlternation] — recognised only in capitals next to a number.
  static final String extendedCurrencyAlternation = CurrencyTable.iso
      .where((c) => !isoCurrencyAlternation.split('|').contains(c))
      .join('|');

  /// An extended ISO code in capitals right before or after a number.
  static final RegExp extendedCurrency =
      RegExp('(?<![A-Za-z])(?:$extendedCurrencyAlternation)(?=\\s?[0-9])|'
          '(?<=[0-9]\\s?)(?:$extendedCurrencyAlternation)(?![A-Za-z])');

  static final List<(RegExp, String)> _localForms = [
    for (final f in CurrencyTable.localForms)
      (
        RegExp('(?<![A-Za-z])${RegExp.escape(f[0])}(?=\\s?[0-9])|'
            '(?<=[0-9]\\s?)${RegExp.escape(f[0])}(?![A-Za-z])'),
        f[1]
      ),
  ];

  // الأرقام العربية-الهندية (U+0660..0669) والممتدة (U+06F0..06F9).
  static const int _arabicIndicZero = 0x0660;
  static const int _extendedArabicIndicZero = 0x06F0;

  /// يحوّل كل الأرقام غير اللاتينية إلى 0-9.
  static String normalizeDigits(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= _arabicIndicZero && rune <= _arabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - _arabicIndicZero));
      } else if (rune >= _extendedArabicIndicZero &&
          rune <= _extendedArabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - _extendedArabicIndicZero));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// ISO codes the parser recognises, as a regex alternation.
  ///
  /// Single source of truth: [ParserEngine] builds its currency matcher from
  /// this, and [separateGluedCurrency] uses the same list. Two independent
  /// lists that must agree is how a code gets de-glued but never detected.
  static const String isoCurrencyAlternation =
      r'SAR|AED|EGP|KWD|QAR|BHD|OMR|USD|EUR|GBP|TRY|INR|PKR|CAD|AUD|JPY|CNY|CHF|MAD|DZD|TND|JOD|IQD|LBP';

  /// توحيد رموز وكلمات العملات إلى رموز ISO.
  ///
  /// Order matters: every specific form must precede the generic one, or the
  /// generic swallows it. `ر.ع` has to be handled before the bare `ريال`
  /// fallback, and `دينار كويتي`/`دينار بحريني` before any bare `دينار`.
  static String normalizeCurrencyTokens(String input) {
    return _applyLocalForms(input
        // Round 9: "Saudi Riyals" (once read as AUD, a substring of "Saudi").
        .replaceAll(
            RegExp(r'(?<![A-Za-z])saudi riyals?(?![A-Za-z])',
                caseSensitive: false),
            'SAR')
        .replaceAll(RegExp(r'ر\.س\.?', caseSensitive: false), 'SAR')
        .replaceAll(RegExp(r'ر\.ع\.?', caseSensitive: false), 'OMR')
        .replaceAll(RegExp(r'ر\.ق\.?', caseSensitive: false), 'QAR')
        .replaceAll(RegExp(r'د\.إ\.?', caseSensitive: false), 'AED')
        .replaceAll(RegExp(r'د\.ك\.?', caseSensitive: false), 'KWD')
        .replaceAll(RegExp(r'د\.ب\.?', caseSensitive: false), 'BHD')
        .replaceAll(RegExp(r'ج\.م\.?', caseSensitive: false), 'EGP')
        .replaceAll('﷼', 'SAR')
        .replaceAll(RegExp(r'ريال\s+سعودي'), 'SAR')
        .replaceAll(RegExp(r'ريال\s+قطري'), 'QAR')
        .replaceAll(RegExp(r'ريال\s+عماني'), 'OMR')
        .replaceAll(RegExp(r'درهم\s+إماراتي|درهم\s+اماراتي|درهم'), 'AED')
        .replaceAll(RegExp(r'جنيه\s+مصري|جنيه'), 'EGP')
        .replaceAll(RegExp(r'دينار\s+كويتي'), 'KWD')
        .replaceAll(RegExp(r'دينار\s+بحريني'), 'BHD')
        .replaceAll(RegExp(r'دولار\s+أمريكي|دولار\s+امريكي|دولار'), 'USD')
        .replaceAll(RegExp(r'ريال'), 'SAR'));
  }

  /// Round 3: a local currency form next to a number ("SR1,250.00", "50 LE",
  /// "€20") becomes its ISO code ([CurrencyTable.localForms]).
  static String _applyLocalForms(String input) {
    var text = input;
    for (final (re, code) in _localForms) {
      text = text.replaceAll(re, code);
    }
    return text;
  }

  static final RegExp _currencyBeforeDigits = RegExp(
    '(?<![A-Za-z])($isoCurrencyAlternation)(?=[0-9])',
    caseSensitive: false,
  );
  static final RegExp _currencyAfterDigits = RegExp(
    '(?<=[0-9])($isoCurrencyAlternation)(?![A-Za-z])',
    caseSensitive: false,
  );

  /// Inserts the missing space in `SAR129.90` / `129.90SAR`.
  ///
  /// Banks emit the currency glued to the amount, and every downstream matcher
  /// assumes a token boundary there. The amount matcher in particular anchors
  /// on `\b`, and in `SAR129.90` there is NO word boundary between `R` and `1`
  /// — so the first boundary it finds is the one before the decimals, and it
  /// extracts `90` from `129.90`. That is a silent 99.3% under-capture of a
  /// financial value.
  ///
  /// Fixing it here rather than by loosening the number regex is deliberate.
  /// Relaxing `\b` would make the matcher accept digits glued to ANY letters,
  /// so reference numbers like `REF123456` would start being read as amounts.
  /// The real defect is a missing token boundary, so the boundary is what gets
  /// repaired — once, for every consumer of the normalised text.
  static String separateGluedCurrency(String input) {
    var text = input.replaceAllMapped(
        _currencyBeforeDigits, (m) => '${m[1]} ');
    text = text.replaceAllMapped(_currencyAfterDigits, (m) => ' ${m[1]}');
    text = text.replaceAllMapped(
        RegExp('(?<![A-Za-z])($extendedCurrencyAlternation)(?=[0-9])'),
        (m) => '${m[1]} ');
    return text.replaceAllMapped(
        RegExp('(?<=[0-9])($extendedCurrencyAlternation)(?![A-Za-z])'),
        (m) => ' ${m[1]}');
  }

  static String stripTashkeel(String input) {
    return input.replaceAll(RegExp(r'[ً-ٰٟ]'), '');
  }

  /// التطبيع الكامل: أرقام + تطويل + مسافات (مع الحفاظ على أسطر جديدة).
  static String normalize(String input) {
    // Preserve grouping until the exact money boundary validates it. Deleting
    // every comma here turned ambiguous `12,50` into `1250` before capture.
    var text = input;
    text = stripTashkeel(text);
    text = normalizeDigits(text);
    text = text.replaceAll('٬', ',').replaceAll('،', ',').replaceAll('٫', '.');
    text = text.replaceAll('ـ', ''); // إزالة التطويل
    // توحيد المسافات داخل كل سطر دون دمج الأسطر.
    text = text
        .split(RegExp(r'[\r\n]+'))
        .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trim())
        .where((line) => line.isNotEmpty)
        .join('\n');
    return text.trim();
  }
}
