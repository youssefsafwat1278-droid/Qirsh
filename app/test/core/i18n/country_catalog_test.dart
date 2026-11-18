import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/i18n/country_catalog.dart';

void main() {
  test('every ISO 3166-1 country is listed once with both names', () {
    final codes = isoCountries.map((c) => c.code).toList();
    expect(codes.length, greaterThanOrEqualTo(249));
    expect(codes.toSet().length, codes.length);
    for (final c in isoCountries) {
      expect(c.code, matches(RegExp(r'^[A-Z]{2}$')));
      expect(c.nameEn.trim(), isNotEmpty, reason: c.code);
      expect(c.nameAr, matches(RegExp('[؀-ۿ]')), reason: c.code);
      if (c.defaultCurrency != null) {
        expect(c.defaultCurrency, matches(RegExp(r'^[A-Z]{3}$')), reason: c.code);
      }
    }
    // Not restricted to Egypt and Saudi Arabia, nor to the old eight.
    for (final code in ['EG', 'SA', 'AE', 'JO', 'MA', 'US', 'FR', 'IN', 'NG']) {
      expect(countryByCode(code), isNotNull, reason: code);
    }
  });

  test('the generated list matches the maintained ISO source when present',
      () {
    final source = File('/usr/share/zoneinfo/iso3166.tab');
    if (!source.existsSync()) return; // Linux CI without tzdata: nothing to diff.
    final expected = source
        .readAsLinesSync()
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .map((l) => l.split('\t').first)
        .toSet();
    expect(isoCountries.map((c) => c.code).toSet(), expected,
        reason: 'regenerate with tool/generate_countries.swift');
  });

  // Decided change: a territory with no (storable) currency has no default;
  // the user chooses one (country_currency_storage_test.dart).
  test('default currencies are configuration; none without a currency', () {
    expect(defaultCurrencyFor('EG'), 'EGP');
    expect(defaultCurrencyFor('sa'), 'SAR');
    expect(defaultCurrencyFor('AE'), 'AED');
    expect(defaultCurrencyFor('FR'), 'EUR');
    expect(countryByCode('AQ')!.defaultCurrency, isNull);
    expect(defaultCurrencyFor('AQ'), isNull);
  });

  test('verified bank coverage is exactly the bundled tested bank catalog', () {
    final banks = jsonDecode(File('assets/catalog/banks.json').readAsStringSync())
        as List<dynamic>;
    final countries = {
      for (final b in banks)
        ((b as Map)['country_code'] ?? b['country']).toString().toUpperCase()
    };
    expect(verifiedBankCoverageCountries, countries);
    expect(countryByCode('EG')!.hasVerifiedBankCoverage, isTrue);
    expect(countryByCode('AE')!.hasVerifiedBankCoverage, isFalse);
    expect(countryByCode('US')!.hasVerifiedBankCoverage, isFalse);
  });

  test('search matches either language, the code, and Arabic letter variants',
      () {
    expect(searchCountries('egy', 'en').map((c) => c.code), contains('EG'));
    expect(searchCountries('مصر', 'ar').map((c) => c.code), ['EG']);
    expect(searchCountries('السعوديه', 'ar').map((c) => c.code), contains('SA'));
    expect(searchCountries('الامارات', 'ar').map((c) => c.code), contains('AE'));
    expect(searchCountries('sa', 'en').first.code, isNotEmpty);
    expect(searchCountries('zzzz', 'en'), isEmpty);
    final all = searchCountries('', 'en');
    expect(all.length, isoCountries.length);
    expect(all.first.nameEn.compareTo(all.last.nameEn), lessThan(0));
  });

  test('flag is built from the code', () {
    expect(countryByCode('EG')!.flag, '\u{1F1EA}\u{1F1EC}');
  });
}
