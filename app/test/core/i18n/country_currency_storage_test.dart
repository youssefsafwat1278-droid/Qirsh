import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/i18n/country_catalog.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/currency_scale.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';

// A country's default currency is a starting preference. Stored money supports
// only the currencies in `kCurrencyScale`, so a country whose ISO currency is
// not there gets NO default: the user chooses one from the storable set.
// Closure round, decision 3.7: `kCurrencyScale` is now every ISO-4217 currency
// with a 0/2/3-digit minor unit (155), so only Antarctica (no currency) asks.

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'country-currency-memory';
  @override
  Future<String?> readStoredKey() async => 'country-currency-memory';
}

void main() {
  test('every country default is storable, or there is none (an explicit '
      'choice)', () {
    for (final country in isoCountries) {
      final currency = defaultCurrencyFor(country.code);
      if (currency == null) continue;
      expect(isSupportedCurrency(currency), isTrue,
          reason: '${country.code} -> $currency is not storable');
      expect(() => Money.parse('1', currency), returnsNormally,
          reason: country.code);
    }
  });

  test('the choice list is exactly the storable currencies', () {
    final expected = kCurrencyScale.keys.toList()..sort();
    expect(storableCurrencies, expected);
    expect(storableCurrencies, hasLength(155));
  });

  test('countries without a default are exactly those whose ISO currency is '
      'not storable', () {
    for (final country in isoCountries) {
      final iso = country.defaultCurrency;
      final storable = iso != null && isSupportedCurrency(iso);
      expect(defaultCurrencyFor(country.code), storable ? iso : null,
          reason: country.code);
    }
    for (final code in ['EG', 'SA', 'AE', 'KW', 'JP', 'US', 'GB', 'FR']) {
      expect(defaultCurrencyFor(code), isNotNull, reason: code);
    }
    expect(defaultCurrencyFor('NO'), 'NOK');
    expect(defaultCurrencyFor('CA'), 'CAD');
    expect(defaultCurrencyFor('CN'), 'CNY');
    expect(defaultCurrencyFor('BR'), 'BRL');
    expect(defaultCurrencyFor('AQ'), isNull);
    final withoutDefault = [
      for (final c in isoCountries)
        if (defaultCurrencyFor(c.code) == null) c.code,
    ];
    expect(withoutDefault, ['AQ']);
    expect(defaultCurrencyFor('ZZ'), isNull);
  });

  test('for every country, an account in its currency (default, or the first '
      'choice offered) takes a manual transaction', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Keys());
    addTearDown(db.close);
    final accounts = DriftAccountRepository(db);
    final transactions = DriftTransactionRepository(db);
    final save = SaveManualTransactionUseCase(
        transactionRepository: transactions, accountRepository: accounts);
    final now = DateTime.utc(2026, 11, 18, 12);
    var i = 0;
    for (final country in isoCountries) {
      final currency = defaultCurrencyFor(country.code) ??
          storableCurrencies.first;
      final account = await accounts.create(AccountEntity(
        id: 'acct-${country.code}',
        name: 'Synthetic ${country.code}',
        currency: currency,
        type: AccountType.bank,
        isDefault: i == 0,
        sortOrder: i,
        createdAt: now,
        updatedAt: now,
      ));
      final saved = await save(
        amount: Money.parse('${10 + i}', currency),
        currency: currency,
        type: TransactionTypeEntity.payment,
        occurredAt: now.subtract(Duration(minutes: i)),
        categoryKey: 'other',
        merchant: 'Synthetic merchant ${country.code}',
        accountId: account.id,
      );
      expect(saved.currency, currency, reason: country.code);
      i++;
    }
    // Every storable currency the choice sheet offers also takes one.
    for (final currency in storableCurrencies) {
      await accounts.create(AccountEntity(
        id: 'choice-$currency',
        name: 'Synthetic $currency',
        currency: currency,
        type: AccountType.cash,
        isDefault: false,
        sortOrder: i,
        createdAt: now,
        updatedAt: now,
      ));
      await save(
        amount: Money.parse('${10 + i}', currency),
        currency: currency,
        type: TransactionTypeEntity.payment,
        occurredAt: now.subtract(Duration(minutes: i)),
        categoryKey: 'other',
        merchant: 'Synthetic choice $currency',
        accountId: 'choice-$currency',
      );
      i++;
    }
  });
}
