import 'dart:convert';

import 'parser_engine.dart';
import 'transaction_state_cues.dart';

/// المرآة الـ Dart لقواعد المعاينة المشتركة `assets/catalog/parser_rules.json`.
///
/// نفس الخوارزمية منفَّذة حرفياً في Swift داخل
/// `ios/BankMessageShortcuts/BankMessageShortcuts.swift` (PreviewParser) —
/// أي تعديل هنا أو في الـ JSON يجب أن يُطبَّق هناك أيضاً.
///
/// هذا المحلّل يغذّي الإشعار الفوري فقط؛ ParserEngine يبقى مصدر الحقيقة
/// للعملية النهائية. الاختبارات تضمن عدم تعارض الاثنين على أمثلة الـ JSON.
enum PreviewOutcome { debit, credit, unknown, ignored }

class PreviewResult {
  const PreviewResult({
    required this.outcome,
    this.amount,
    this.currency,
    this.merchant,
    this.last4,
  });

  final PreviewOutcome outcome;
  final double? amount;
  final String? currency;
  final String? merchant;
  final String? last4;

  /// إشعار مفصَّل فقط عند وضوح النوع + المبلغ + العملة، وإلا إشعار عام.
  bool get isHighConfidence =>
      (outcome == PreviewOutcome.debit || outcome == PreviewOutcome.credit) &&
      amount != null &&
      currency != null;
}

class SharedPreviewParser {
  SharedPreviewParser._({
    required List<({RegExp pattern, String replacement})> currencyReplacements,
    required List<String> decimalMarks,
    required List<String> thousandsMarks,
    required RegExp currencyPattern,
    required List<String> ignoreKeywords,
    required List<String> debitKeywords,
    required List<String> creditKeywords,
    required List<RegExp> amountPatterns,
    required List<RegExp> merchantPatterns,
    required RegExp merchantStopPattern,
    required List<RegExp> last4Patterns,
  })  : _currencyReplacements = currencyReplacements,
        _decimalMarks = decimalMarks,
        _thousandsMarks = thousandsMarks,
        _currencyPattern = currencyPattern,
        _ignoreKeywords = ignoreKeywords,
        _debitKeywords = debitKeywords,
        _creditKeywords = creditKeywords,
        _amountPatterns = amountPatterns,
        _merchantPatterns = merchantPatterns,
        _merchantStopPattern = merchantStopPattern,
        _last4Patterns = last4Patterns;

  factory SharedPreviewParser.fromJsonString(String jsonString) {
    final json = jsonDecode(jsonString) as Map<String, dynamic>;
    final normalization = json['normalization'] as Map<String, dynamic>;

    RegExp ci(String pattern) => RegExp(pattern, caseSensitive: false);
    List<String> strings(Object? value) =>
        (value as List).cast<String>().toList();
    List<RegExp> patterns(Object? value) => strings(value).map(ci).toList();

    return SharedPreviewParser._(
      currencyReplacements: [
        for (final item in (normalization['currencyReplacements'] as List)
            .cast<Map<String, dynamic>>())
          (
            pattern: ci(item['pattern'] as String),
            replacement: item['replacement'] as String,
          ),
      ],
      decimalMarks: strings(normalization['decimalMarks']),
      thousandsMarks: strings(normalization['thousandsMarks']),
      currencyPattern: ci(json['currencyPattern'] as String),
      // V1-061: declined cues are judged by [TransactionStateCues] (whole
      // tokens, folded, names and advice excluded), not by substring; the
      // asset keeps them for the Swift preview.
      ignoreKeywords: strings(json['ignoreKeywords'])
          .where((k) =>
              !_declinedCues.contains(TransactionStateCues.foldForCues(k)))
          .toList(),
      debitKeywords: strings(json['debitKeywords']),
      creditKeywords: strings(json['creditKeywords']),
      amountPatterns: patterns(json['amountPatterns']),
      merchantPatterns: patterns(json['merchantPatterns']),
      merchantStopPattern: ci(json['merchantStopPattern'] as String),
      last4Patterns: patterns(json['last4Patterns']),
    );
  }

  static final Set<String> _declinedCues = TransactionStateCues.declined
      .map(TransactionStateCues.foldForCues)
      .toSet();

  final List<({RegExp pattern, String replacement})> _currencyReplacements;
  final List<String> _decimalMarks;
  final List<String> _thousandsMarks;
  final RegExp _currencyPattern;
  final List<String> _ignoreKeywords;
  final List<String> _debitKeywords;
  final List<String> _creditKeywords;
  final List<RegExp> _amountPatterns;
  final List<RegExp> _merchantPatterns;
  final RegExp _merchantStopPattern;
  final List<RegExp> _last4Patterns;

  PreviewResult parse(String text) {
    final normalized = _normalize(text);
    final lower = normalized.toLowerCase();

    // LR-05: an ignore word inside the merchant name ("Offer Mart") is part
    // of the name; the device's own ignore words (links, complaint lines,
    // account notices with no money movement: NR-01) also get the generic
    // preview. (The Swift preview still matches the asset's list by
    // substring.)
    final outside =
        ParserEngine.outsideMerchant(lower, _extractMerchant(normalized));
    if (_ignoreKeywords
            .any((k) => ParserEngine.containsIgnoreWord(outside, k)) ||
        ParserEngine.hasIgnoreWord(outside) ||
        ParserEngine.isNoticeMessage(text) ||
        TransactionStateCues.isNotCompleted(text)) {
      return const PreviewResult(outcome: PreviewOutcome.ignored);
    }

    final outcome = _detectOutcome(lower);
    return PreviewResult(
      outcome: outcome,
      amount: _extractAmount(normalized),
      currency: _extractCurrency(normalized),
      merchant: _extractMerchant(normalized),
      last4: _extractGroup1(_last4Patterns, normalized),
    );
  }

  String _normalize(String input) {
    var text = _normalizeDigits(input);
    for (final mark in _decimalMarks) {
      text = text.replaceAll(mark, '.');
    }
    for (final mark in _thousandsMarks) {
      text = text.replaceAll(mark, '');
    }
    for (final rule in _currencyReplacements) {
      text = text.replaceAll(rule.pattern, rule.replacement);
    }
    // فواصل الآلاف بين رقمين: 12,500.00 → 12500.00 (حلقة لأن التطابقات تتداخل).
    final thousands = RegExp(r'(\d),(\d)');
    while (thousands.hasMatch(text)) {
      text = text.replaceAllMapped(
        thousands,
        (m) => '${m.group(1)}${m.group(2)}',
      );
    }
    return text;
  }

  static String _normalizeDigits(String input) {
    const arabicIndicZero = 0x0660;
    const extendedArabicIndicZero = 0x06F0;
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= arabicIndicZero && rune <= arabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - arabicIndicZero));
      } else if (rune >= extendedArabicIndicZero &&
          rune <= extendedArabicIndicZero + 9) {
        buffer.writeCharCode(0x30 + (rune - extendedArabicIndicZero));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  PreviewOutcome _detectOutcome(String lower) {
    final debitIndex = _earliestIndex(lower, _debitKeywords);
    final creditIndex = _earliestIndex(lower, _creditKeywords);
    if (debitIndex == null && creditIndex == null) {
      return PreviewOutcome.unknown;
    }
    if (creditIndex == null) return PreviewOutcome.debit;
    if (debitIndex == null) return PreviewOutcome.credit;
    // الاثنان موجودان — الأسبق في النص يحسم (وعند التساوي: خصم).
    return debitIndex <= creditIndex
        ? PreviewOutcome.debit
        : PreviewOutcome.credit;
  }

  static int? _earliestIndex(String lower, List<String> keywords) {
    int? earliest;
    for (final keyword in keywords) {
      final index = lower.indexOf(keyword);
      if (index >= 0 && (earliest == null || index < earliest)) {
        earliest = index;
      }
    }
    return earliest;
  }

  double? _extractAmount(String normalized) {
    final raw = _extractGroup1(_amountPatterns, normalized);
    return raw == null ? null : double.tryParse(raw);
  }

  String? _extractCurrency(String normalized) {
    return _currencyPattern.firstMatch(normalized)?.group(1)?.toUpperCase();
  }

  String? _extractMerchant(String normalized) {
    final raw = _extractGroup1(_merchantPatterns, normalized);
    if (raw == null) return null;
    var merchant = raw.replaceFirst(_merchantStopPattern, '');
    merchant = merchant
        .replaceAll(RegExp(r'^[\s.,:;؛*\-]+'), '')
        .replaceAll(RegExp(r'[\s.,:;؛*\-]+$'), '');
    return merchant.isEmpty ? null : merchant;
  }

  static String? _extractGroup1(List<RegExp> patterns, String text) {
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final value = match?.group(1)?.trim();
      if (value != null && value.isNotEmpty) {
        return value;
      }
    }
    return null;
  }
}
