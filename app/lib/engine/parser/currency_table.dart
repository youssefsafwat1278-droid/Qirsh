/// Round 3 (owner brief 3.7 / 4.4): currency recognition driven by a table
/// rather than a Saudi/Egyptian list. Recognising a currency is not a claim
/// that any bank's messages in it are supported.
///
/// - Codes already in [Normalizer.isoCurrencyAlternation] keep their
///   case-insensitive, whole-word matching.
/// - Every other ISO 4217 code in [iso] counts only when written in capitals
///   right next to a number ("NGN 5,000", "250.00 MYR"), so words such as
///   "ALL", "TOP" or "CUP" in a sentence are never a currency.
/// - [localForms] map common local writings ("SR", "LE", "KD", "€") to their
///   ISO code, again only next to a number.
///
/// Equal to `currencyTable` in `process-ios-sms/parser_rules.json` (drift
/// test `transaction_state_cues_drift_test.dart`).
class CurrencyTable {
  const CurrencyTable._();

  static const List<String> iso = [
    'AED', 'AFN', 'ALL', 'AMD', 'ANG', 'AOA', 'ARS', 'AUD', 'AWG', 'AZN',
    'BAM', 'BBD', 'BDT', 'BGN', 'BHD', 'BIF', 'BMD', 'BND', 'BOB', 'BRL',
    'BSD', 'BTN', 'BWP', 'BYN', 'BZD', 'CAD', 'CDF', 'CHF', 'CLP', 'CNY',
    'COP', 'CRC', 'CUP', 'CVE', 'CZK', 'DJF', 'DKK', 'DOP', 'DZD', 'EGP',
    'ERN', 'ETB', 'EUR', 'FJD', 'FKP', 'GBP', 'GEL', 'GHS', 'GIP', 'GMD',
    'GNF', 'GTQ', 'GYD', 'HKD', 'HNL', 'HTG', 'HUF', 'IDR', 'ILS', 'INR',
    'IQD', 'IRR', 'ISK', 'JMD', 'JOD', 'JPY', 'KES', 'KGS', 'KHR', 'KMF',
    'KPW', 'KRW', 'KWD', 'KYD', 'KZT', 'LAK', 'LBP', 'LKR', 'LRD', 'LSL',
    'LYD', 'MAD', 'MDL', 'MGA', 'MKD', 'MMK', 'MNT', 'MOP', 'MRU', 'MUR',
    'MVR', 'MWK', 'MXN', 'MYR', 'MZN', 'NAD', 'NGN', 'NIO', 'NOK', 'NPR',
    'NZD', 'OMR', 'PAB', 'PEN', 'PGK', 'PHP', 'PKR', 'PLN', 'PYG', 'QAR',
    'RON', 'RSD', 'RUB', 'RWF', 'SAR', 'SBD', 'SCR', 'SDG', 'SEK', 'SGD',
    'SHP', 'SLE', 'SOS', 'SRD', 'SSP', 'STN', 'SYP', 'SZL', 'THB', 'TJS',
    'TMT', 'TND', 'TOP', 'TRY', 'TTD', 'TWD', 'TZS', 'UAH', 'UGX', 'USD',
    'UYU', 'UZS', 'VES', 'VND', 'VUV', 'WST', 'XAF', 'XCD', 'XOF', 'XPF',
    'YER', 'ZAR', 'ZMW', 'ZWL',
  ];

  /// `[form, ISO code]`, in matching order (a longer form first).
  static const List<List<String>> localForms = [
    ['L.E.', 'EGP'], ['L.E', 'EGP'], ['LE', 'EGP'], ['E£', 'EGP'],
    ['£E', 'EGP'], ['SR', 'SAR'], ['KD', 'KWD'], ['QR', 'QAR'],
    ['BD', 'BHD'], ['€', 'EUR'], ['£', 'GBP'], ['₹', 'INR'], ['₺', 'TRY'],
    ['₦', 'NGN'], ['₱', 'PHP'], ['₩', 'KRW'], ['₪', 'ILS'],
  ];
}
