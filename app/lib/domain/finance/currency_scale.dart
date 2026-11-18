/// MALI-026 (Phase-8 B8-0) — the explicit, tested currency-scale registry.
///
/// Decision 2: a KNOWN supported currency maps to an explicit ISO-4217 minor-unit
/// scale; an UNKNOWN code is an explicit UNSUPPORTED state. There is NO silent
/// "assume 2 decimals" for PERSISTED Money (migration / backup restore / sync /
/// machine import / Money construction). A separate display-only fallback lives
/// in `money_format.dart` (`currencyDecimalDigits`, default 2) for non-financial
/// presentation surfaces — it must never mint canonical persisted minor units.
library;

/// Thrown when persisted-Money code encounters a currency with no registered
/// scale. Callers (migration preflight, sync, import) must handle it explicitly
/// — never guess a scale.
class UnsupportedCurrencyException implements Exception {
  const UnsupportedCurrencyException(this.currencyCode);
  final String currencyCode;
  @override
  String toString() =>
      'UnsupportedCurrencyException: no registered minor-unit scale for '
      '"$currencyCode"';
}

/// STORAGE registry: the ISO-4217 minor-unit scale of every currency persisted
/// Money can hold — all active ISO-4217 codes with a 0, 2 or 3 digit minor
/// unit, funds excluded (decision 3.7: every country can keep its own
/// currency). Everything NOT listed is unsupported for persisted Money.
///
/// Generated: `python3 -I tool/generate_currency_scale.py <list-one.xml>`
/// from ISO 4217 List One (SIX, published 2026-09-17). Do not hand-edit the
/// generated region; the server stores any `^[A-Z]{3}$` code with an
/// unconstrained numeric amount, so every code here can sync.
///
/// This is NOT the set of codes the parser recognises in message text — that
/// is [kDetectionCurrencyScale]. Many ISO codes are ordinary words (ALL, TOP,
/// CUP, PEN), so the detection set stays a reviewed subset.
const Map<String, int> kCurrencyScale = {
  // BEGIN GENERATED (tool/generate_currency_scale.py)
  // ISO 4217 List One, published 2026-09-17; 155 codes.
  // ── 3 minor digits (7) ──
  'BHD': 3, 'IQD': 3, 'JOD': 3, 'KWD': 3, 'LYD': 3, 'OMR': 3, 'TND': 3,
  // ── 0 minor digits (16) ──
  'BIF': 0, 'CLP': 0, 'DJF': 0, 'GNF': 0, 'ISK': 0, 'JPY': 0, 'KMF': 0,
  'KRW': 0, 'PYG': 0, 'RWF': 0, 'UGX': 0, 'VND': 0, 'VUV': 0, 'XAF': 0,
  'XOF': 0, 'XPF': 0,
  // ── 2 minor digits (132) ──
  'AED': 2, 'AFN': 2, 'ALL': 2, 'AMD': 2, 'AOA': 2, 'ARS': 2, 'AUD': 2,
  'AWG': 2, 'AZN': 2, 'BAM': 2, 'BBD': 2, 'BDT': 2, 'BMD': 2, 'BND': 2,
  'BOB': 2, 'BRL': 2, 'BSD': 2, 'BTN': 2, 'BWP': 2, 'BYN': 2, 'BZD': 2,
  'CAD': 2, 'CDF': 2, 'CHF': 2, 'CNY': 2, 'COP': 2, 'CRC': 2, 'CUP': 2,
  'CVE': 2, 'CZK': 2, 'DKK': 2, 'DOP': 2, 'DZD': 2, 'EGP': 2, 'ERN': 2,
  'ETB': 2, 'EUR': 2, 'FJD': 2, 'FKP': 2, 'GBP': 2, 'GEL': 2, 'GHS': 2,
  'GIP': 2, 'GMD': 2, 'GTQ': 2, 'GYD': 2, 'HKD': 2, 'HNL': 2, 'HTG': 2,
  'HUF': 2, 'IDR': 2, 'ILS': 2, 'INR': 2, 'IRR': 2, 'JMD': 2, 'KES': 2,
  'KGS': 2, 'KHR': 2, 'KPW': 2, 'KYD': 2, 'KZT': 2, 'LAK': 2, 'LBP': 2,
  'LKR': 2, 'LRD': 2, 'LSL': 2, 'MAD': 2, 'MDL': 2, 'MGA': 2, 'MKD': 2,
  'MMK': 2, 'MNT': 2, 'MOP': 2, 'MRU': 2, 'MUR': 2, 'MVR': 2, 'MWK': 2,
  'MXN': 2, 'MYR': 2, 'MZN': 2, 'NAD': 2, 'NGN': 2, 'NIO': 2, 'NOK': 2,
  'NPR': 2, 'NZD': 2, 'PAB': 2, 'PEN': 2, 'PGK': 2, 'PHP': 2, 'PKR': 2,
  'PLN': 2, 'QAR': 2, 'RON': 2, 'RSD': 2, 'RUB': 2, 'SAR': 2, 'SBD': 2,
  'SCR': 2, 'SDG': 2, 'SEK': 2, 'SGD': 2, 'SHP': 2, 'SLE': 2, 'SOS': 2,
  'SRD': 2, 'SSP': 2, 'STN': 2, 'SVC': 2, 'SYP': 2, 'SZL': 2, 'THB': 2,
  'TJS': 2, 'TMT': 2, 'TOP': 2, 'TRY': 2, 'TTD': 2, 'TWD': 2, 'TZS': 2,
  'UAH': 2, 'USD': 2, 'UYU': 2, 'UZS': 2, 'VED': 2, 'VES': 2, 'WST': 2,
  'XCD': 2, 'XCG': 2, 'YER': 2, 'ZAR': 2, 'ZMW': 2, 'ZWG': 2,
  // END GENERATED
};

/// DETECTION registry: the codes the evidence layer, the proof checker and the
/// AI validators recognise in message text, with their scales. Unchanged by
/// the storage split; its sorted key set is pinned by
/// test/domain/finance/currency_storage_detection_split_test.dart because the
/// evidence ISO regex (part of the Phase-4 seal) is derived from it. Every
/// entry must also be in [kCurrencyScale] with the same scale (tested).
const Map<String, int> kDetectionCurrencyScale = {
  // ── 3 minor digits ──────────────────────────────────────────────────────
  'KWD': 3, 'BHD': 3, 'OMR': 3, 'JOD': 3, 'TND': 3, 'LYD': 3, 'IQD': 3,
  // ── 0 minor digits ──────────────────────────────────────────────────────
  'JPY': 0, 'KRW': 0, 'ISK': 0, 'CLP': 0, 'VND': 0, 'XAF': 0, 'XOF': 0,
  'UGX': 0, 'RWF': 0, 'DJF': 0, 'GNF': 0, 'PYG': 0, 'KMF': 0,
  // ── 2 minor digits (all remaining supported codes) ──────────────────────
  'SAR': 2, 'AED': 2, 'EGP': 2, 'QAR': 2, 'ILS': 2, 'LBP': 2, 'SYP': 2,
  'MAD': 2, 'MRU': 2, 'DZD': 2, 'SDG': 2, 'YER': 2, 'SOS': 2, 'TRY': 2,
  'USD': 2, 'EUR': 2, 'GBP': 2, 'INR': 2, 'PKR': 2, 'BDT': 2, 'PHP': 2,
  'IDR': 2, 'MYR': 2, 'SGD': 2, 'NGN': 2, 'KES': 2, 'ZAR': 2, 'ETB': 2,
  'GHS': 2, 'TZS': 2,
};

String _normalize(String code) => code.trim().toUpperCase();

/// Whether [currencyCode] has a registered scale (is supported for persisted
/// Money).
bool isSupportedCurrency(String currencyCode) =>
    kCurrencyScale.containsKey(_normalize(currencyCode));

/// The minor-unit scale for a SUPPORTED currency. Throws
/// [UnsupportedCurrencyException] for an unknown code — persisted Money never
/// guesses a scale.
int currencyScale(String currencyCode) {
  final code = _normalize(currencyCode);
  final scale = kCurrencyScale[code];
  if (scale == null) throw UnsupportedCurrencyException(code);
  return scale;
}
