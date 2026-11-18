import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/core/utils/formatters.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/accounts/account_detail_screen.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import '../common/primary_screen_harness.dart';

// Decision 3.14 (V1-032): a balance is labelled by its real source. The
// account's `currentBalanceMoney` is only ever typed by the user in the account
// form (or synced from their own device) — never read from a bank message — so
// it is "Manually entered", not a verified current balance. A balance printed
// in a bank message (`balanceAfter`) is "reported by the bank".
final _when = DateTime(2026, 11, 1, 9);

AccountEntity _account() => AccountEntity(
      id: 'manual-balance',
      name: 'Synthetic wallet',
      currency: 'SAR',
      type: AccountType.wallet,
      isDefault: false,
      sortOrder: 9,
      createdAt: _when,
      updatedAt: _when,
      currentBalanceMoney: Money(150000, 'SAR'),
    );

void main() {
  for (final language in ['en', 'ar']) {
    testWidgets(
        'accounts list labels a typed balance as entered manually '
        '($language)', (tester) async {
      final errors = await pumpPrimaryScreen(
          tester, PrimaryScreen('Accounts', () => const AccountsScreen()),
          size: const Size(390, 844),
          language: language,
          seed: (db) => DriftAccountRepository(db).create(_account()));
      stopCollectingErrors();
      expect(errors, isEmpty);
      final l10n = AppL10n.of(tester.element(find.byType(AccountsScreen)));
      expect(find.byKey(const Key('accountRowBalanceSource')), findsOneWidget);
      expect(find.text(l10n.accBalanceManualShort), findsOneWidget);
      expect(find.textContaining(l10n.accTotalBalance), findsOneWidget);
    });

    testWidgets(
        'account details labels the balance as manually entered '
        '($language)', (tester) async {
      final errors = await pumpPrimaryScreen(
          tester,
          PrimaryScreen('Account detail',
              () => const AccountDetailScreen(accountId: 'manual-balance')),
          size: const Size(390, 844),
          language: language,
          seed: (db) => DriftAccountRepository(db).create(_account()));
      stopCollectingErrors();
      expect(errors, isEmpty);
      final l10n = AppL10n.of(tester.element(find.byType(AccountDetailScreen)));
      expect(find.byKey(const Key('accountBalanceSource')), findsOneWidget);
      expect(find.text(l10n.accBalanceManual), findsOneWidget);
    });

    testWidgets(
        'a balance from a bank message is labelled as reported by the '
        'bank ($language)', (tester) async {
      final errors = await pumpPrimaryScreen(
          tester,
          PrimaryScreen('Details',
              () => const TransactionDetailsScreen(transactionId: 'with-bal')),
          size: const Size(390, 844),
          language: language,
          seed: (db) => DriftTransactionRepository(db).saveTransaction(
              transaction: TransactionEntity(
                id: 'with-bal',
                amountMoney: Money(5000, 'SAR'),
                currency: 'SAR',
                type: TransactionTypeEntity.payment,
                source: TransactionSourceEntity.bank,
                occurredAt: _when,
                rawMessage: 'synthetic',
                rawMerchant: 'Synthetic Shop',
                parseConfidence: 1,
                status: TransactionStatus.confirmed,
                balanceAfterMoney: Money(95000, 'SAR'),
                createdAt: _when,
                updatedAt: _when,
              ),
              categoryKey: 'groceries'));
      stopCollectingErrors();
      expect(errors, isEmpty);
      final l10n =
          AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
      await tester.scrollUntilVisible(find.text(l10n.txdBalanceAfter), 200,
          scrollable: find.byType(Scrollable).first);
      expect(find.text(l10n.txdBalanceAfter), findsOneWidget);
    });
  }

  for (final language in ['en', 'ar']) {
    for (final (size, scale) in const [
      (Size(390, 844), 1.0),
      (Size(320, 568), 3.1)
    ]) {
      testWidgets(
          'account details shows the bank-reported balance with the time '
          'the bank reported it ($language, $size, ${scale}x)', (tester) async {
        final errors = await pumpPrimaryScreen(
            tester,
            PrimaryScreen('Account detail',
                () => const AccountDetailScreen(accountId: 'manual-balance')),
            size: size,
            textScale: scale,
            language: language, seed: (db) async {
          await DriftAccountRepository(db).create(_account());
          await DriftTransactionRepository(db).saveTransaction(
              transaction: TransactionEntity(
                id: 'acct-bal',
                accountId: 'manual-balance',
                amountMoney: Money(5000, 'SAR'),
                currency: 'SAR',
                type: TransactionTypeEntity.payment,
                source: TransactionSourceEntity.bank,
                occurredAt: _when,
                rawMessage: 'synthetic',
                rawMerchant: 'Synthetic Shop',
                parseConfidence: 1,
                status: TransactionStatus.confirmed,
                balanceAfterMoney: Money(95000, 'SAR'),
                createdAt: _when,
                updatedAt: _when,
              ),
              categoryKey: 'groceries');
        });
        final context = tester.element(find.byType(AccountDetailScreen));
        final l10n = AppL10n.of(context);
        // The manually entered balance keeps its own label.
        final manualShown =
            find.text(l10n.accBalanceManual).evaluate().length == 1;
        final row = find.byKey(const Key('accountBankReportedBalance'));
        await tester.scrollUntilVisible(row, 200,
            scrollable: find.byType(Scrollable).first);
        await tester.pump();
        stopCollectingErrors();
        expect(errors, isEmpty);
        expect(manualShown, isTrue);
        expect(row, findsOneWidget);
        expect(find.text(l10n.accBankReportedBalance), findsOneWidget);
        expect(
            find.text(l10n.accBankReportedAt(
                Formatters.fullDate(_when, context),
                Formatters.time(_when, context))),
            findsOneWidget);
      });
    }
  }

  test('the copy names the source, in both languages', () {
    final en = lookupAppL10n(const Locale('en'));
    final ar = lookupAppL10n(const Locale('ar'));
    expect(en.accBalanceManual, 'Manually entered balance');
    expect(en.txdBalanceAfter, 'Balance reported by the bank');
    expect(en.accTotalBalance, contains('manually entered'));
    expect(ar.accBalanceManual, contains('يدويًا'));
    expect(ar.txdBalanceAfter, contains('البنك'));
    expect(ar.accTotalBalance, contains('يدويًا'));
  });
}
