/// Every ISO 3166-1 country the user can live in, with localized names and a
/// default currency — and, kept separate, the much smaller set of countries
/// whose bank messages Qirsh has actually been tested against.
///
/// The list is generated (`tool/generate_countries.swift`), not hand-typed, so
/// adding or renaming a country is a regeneration, not an edit.
library;

import '../../domain/finance/currency_scale.dart';

part 'countries.g.dart';

class IsoCountry {
  const IsoCountry(this.code, this.nameEn, this.nameAr, this.defaultCurrency);

  /// ISO 3166-1 alpha-2, upper case.
  final String code;
  final String nameEn;
  final String nameAr;

  /// CLDR's default currency for the territory; null where it has none
  /// (Antarctica). A starting preference only — never evidence of the currency
  /// of any particular transaction.
  final String? defaultCurrency;

  String nameIn(String languageCode) => languageCode == 'en' ? nameEn : nameAr;

  /// Regional-indicator flag built from the code.
  String get flag =>
      String.fromCharCodes(code.codeUnits.map((unit) => 0x1F1E6 + unit - 0x41));

  /// Whether bank-message recognition has been tested for some banks here.
  bool get hasVerifiedBankCoverage =>
      verifiedBankCoverageCountries.contains(code);
}

/// Countries with bank profiles in the bundled, tested catalog
/// (`assets/catalog/banks.json`). A test keeps the two in step. This says
/// "some banks were tested", never "every bank or format works".
const Set<String> verifiedBankCoverageCountries = {'EG', 'SA'};

/// The currencies a user can choose: exactly those stored money supports
/// (`kCurrencyScale`), sorted. A country whose own currency is not among them
/// gets no default; the user picks one of these instead.
final List<String> storableCurrencies =
    List.unmodifiable(kCurrencyScale.keys.toList()..sort());

List<IsoCountry> get isoCountries => _isoCountries;

IsoCountry? countryByCode(String code) {
  final wanted = code.trim().toUpperCase();
  for (final country in _isoCountries) {
    if (country.code == wanted) return country;
  }
  return null;
}

/// The country's default currency when the app can store amounts in it;
/// null when it cannot (or the territory has none), so the user must choose
/// one of [storableCurrencies].
String? defaultCurrencyFor(String code) {
  final currency = countryByCode(code)?.defaultCurrency;
  return currency != null && isSupportedCurrency(currency) ? currency : null;
}

/// All countries sorted by their name in [languageCode], filtered by [query]
/// against either name and the code. Arabic letter variants (hamza forms, taa
/// marbuta, alef maqsura) and diacritics are ignored.
List<IsoCountry> searchCountries(String query, String languageCode) {
  final q = _fold(query);
  final matches = q.isEmpty
      ? _isoCountries.toList()
      : _isoCountries
          .where((c) =>
              c.code.toLowerCase() == q ||
              _fold(c.nameEn).contains(q) ||
              _fold(c.nameAr).contains(q))
          .toList();
  matches.sort((a, b) =>
      _fold(a.nameIn(languageCode)).compareTo(_fold(b.nameIn(languageCode))));
  return matches;
}

final RegExp _arabicMarks = RegExp('[\u064B-\u065F\u0670\u0640]');

String _fold(String value) => value
    .trim()
    .toLowerCase()
    .replaceAll(_arabicMarks, '')
    .replaceAll(RegExp('[أإآٱ]'), 'ا')
    .replaceAll('ة', 'ه')
    .replaceAll('ى', 'ي');
