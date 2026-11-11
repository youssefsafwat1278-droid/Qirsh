import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/common/category_catalog.dart';
import 'package:money_companion/features/common/motion.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'tx-detail-memory';
  @override
  Future<String?> readStoredKey() async => 'tx-detail-memory';
}

Future<List<Map<String, Object?>>> _ledger(AppDatabase db) async =>
    (await db.customSelect('SELECT * FROM transactions ORDER BY id').get())
        .map((row) => Map<String, Object?>.from(row.data))
        .toList();

TransactionEntity _tx(Money amount, {Money? foreign, Money? balance}) {
  final now = DateTime(2026, 1, 15);
  return TransactionEntity(
    id: 'money-tx', amountMoney: amount, currency: amount.currency,
    accountId: 'own', cardLast4: '1234', rawMerchant: 'Synthetic merchant',
    foreignMoney: foreign, foreignCurrency: foreign?.currency,
    balanceAfterMoney: balance,
    type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
    occurredAt: now, rawMessage: 'Synthetic SMS', parseConfidence: 1,
    status: TransactionStatus.confirmed, createdAt: now, updatedAt: now,
  );
}

Future<AppDatabase> _open(WidgetTester tester, TransactionEntity tx,
    {String language = 'en'}) async {
  tester.view.physicalSize = const Size(375, 667);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.runAsync(() async {
    final loader = FontLoader('Vazirmatn');
    for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      loader.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
    }
    await loader.load();
  });
  final db = (await tester.runAsync(() async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeys());
    await DriftAccountRepository(db).create(AccountEntity(
      id: 'own', name: 'Synthetic account', currency: tx.currency,
      type: AccountType.bank, isDefault: true, sortOrder: 0,
      createdAt: tx.createdAt, updatedAt: tx.updatedAt,
    ));
    await DriftTransactionRepository(db).saveTransaction(
        transaction: tx, categoryKey: 'groceries');
    return db;
  }))!;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(db.close);
  });
  await tester.pumpWidget(ProviderScope(overrides: [
    appDatabaseProvider.overrideWithValue(db),
    transactionRepositoryProvider.overrideWithValue(DriftTransactionRepository(db)),
    transactionByIdProvider(tx.id).overrideWith((ref) async => tx),
    accountsProvider.overrideWith((ref) async => const []),
    categoryCatalogProvider.overrideWith((ref) async => CategoryCatalog(const [])),
  ], child: MaterialApp(
    theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
    locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
    localizationsDelegates: AppL10n.localizationsDelegates,
    home: const TransactionDetailsScreen(transactionId: 'money-tx'),
  )));
  await tester.pumpAndSettle();
  return db;
}

String _text(Text widget) => widget.data ?? widget.textSpan!.toPlainText();

Finder _exactAmount(Money amount) => find.byWidgetPredicate((widget) =>
    widget is Text && (_text(widget).replaceAll(RegExp('[\u2066-\u2069]'), '') ==
        formatMoney(amount) || _text(widget).startsWith('${formatMoney(amount)} ')));

Future<void> _openPrice(WidgetTester tester, String currency) async {
  final context = tester.element(find.byType(TransactionDetailsScreen));
  final button = find.text(AppL10n.of(context).txdAddValueIn(
      Currency.label(context, currency)));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  for (final language in ['ar', 'en']) {
    for (final amount in [Money(12345, 'KWD'),
        Money(9007199254740993, 'KWD'), Money(123, 'JPY')]) {
      testWidgets('transaction hero preserves ${amount.currency} '
          '${amount.minorUnits} minor units in $language', (tester) async {
        await _open(tester, _tx(amount), language: language);
        final heroAmount = find.descendant(
            of: find.byType(FittedBox).first, matching: _exactAmount(amount));
        expect(heroAmount, findsOneWidget);
        final text = tester.widget<Text>(heroAmount);
        expect(text.textDirection ?? Directionality.of(tester.element(heroAmount)),
            TextDirection.ltr);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('foreign original and balance retain KWD scale in $language',
        (tester) async {
      final foreign = Money(12345, 'KWD');
      final balance = Money(9007199254740993, 'KWD');
      await _open(tester, _tx(Money.zero('KWD'), foreign: foreign, balance: balance),
          language: language);
      expect(find.descendant(of: find.byType(FittedBox).first,
          matching: _exactAmount(foreign)), findsOneWidget);
      final bodyText = find.byWidgetPredicate((widget) => widget is Text &&
          _text(widget).contains(formatMoney(balance)));
      await tester.ensureVisible(bodyText);
      expect(bodyText, findsOneWidget);
      final original = find.byWidgetPredicate((widget) => widget is Text &&
          _text(widget).contains('${formatMoney(foreign)} KWD'));
      // Calm Capital v2 hero: the currency is its own run AFTER the exact
      // digits (asserted above), so only the detail row joins them.
      expect(original, findsOneWidget,
          reason: 'the original-currency detail must be exact');
      expect(find.descendant(of: find.byType(FittedBox).first,
          matching: find.text('KWD')), findsOneWidget,
          reason: 'the hero names the foreign currency next to its digits');
      expect(tester.takeException(), isNull);
    });

    testWidgets('invalid home pricing stays editable; Cancel writes nothing in $language',
        (tester) async {
      final db = await _open(tester,
          _tx(Money.zero('EGP'), foreign: Money(12345, 'KWD')), language: language);
      final before = await tester.runAsync(() => _ledger(db));
      await _openPrice(tester, 'EGP');
      final l10n = AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
      for (final invalid in ['abc', '0', '-1', '12.345']) {
        await tester.enterText(find.byType(TextField), invalid);
        await tester.tap(find.text(l10n.txdSave));
        await tester.pumpAndSettle();
        expect(find.byType(TextField), findsOneWidget,
            reason: 'invalid $invalid must not silently dismiss the price editor');
        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, invalid);
        expect(field.decoration!.errorText, isNotNull);
        expect(await tester.runAsync(() => _ledger(db)), before);
      }
      await tester.tap(find.text(l10n.commonCancel));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(await tester.runAsync(() => _ledger(db)), before);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('valid KWD home price stores exact minor units and preserves foreign/account',
      (tester) async {
    final tx = _tx(Money.zero('KWD'), foreign: Money(123, 'JPY'));
    final db = await _open(tester, tx);
    await _openPrice(tester, 'KWD');
    final l10n = AppL10n.of(tester.element(find.byType(TransactionDetailsScreen)));
    await tester.enterText(find.byType(TextField), '12.345');
    await tester.tap(find.text(l10n.txdSave));
    await tester.pumpAndSettle();
    // Drift runs outside widget fake time; allow the real repository to settle.
    await tester.runAsync(() async {
      for (var i = 0; i < 30; i++) {
        if ((await DriftTransactionRepository(db).getById(tx.id))!
            .amountMoney.minorUnits == 12345) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final stored = (await tester.runAsync(
        () => DriftTransactionRepository(db).getById(tx.id)))!;
    expect(stored.amountMoney, Money(12345, 'KWD'));
    expect(stored.accountId, tx.accountId);
    expect(stored.cardLast4, tx.cardLast4);
    expect(stored.foreignMoney, tx.foreignMoney);
    expect(stored.foreignCurrency, tx.foreignCurrency);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('exact money animation keeps full KWD scale while moving to a large signed endpoint',
      (tester) async {
    final amount = Money(-9007199254740993, 'KWD');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body:
      AnimatedAmountText.money(value: amount, color: Colors.black))));
    expect(find.text('0.000'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 325));
    final middle = tester.widget<Text>(find.descendant(
        of: find.byType(AnimatedAmountText), matching: find.byType(Text)));
    final shown = middle.data!;
    expect(shown, matches(RegExp(r'^-[\d,]+\.\d{3}$')));
    final scaled = BigInt.parse(shown.replaceAll(RegExp('[,.]'), ''));
    expect(scaled < BigInt.zero, isTrue);
    expect(scaled > BigInt.from(amount.minorUnits), isTrue,
        reason: 'the intermediate amount must not overshoot the real endpoint');
    await tester.pumpAndSettle();
    expect(find.text(formatMoney(amount)), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced-motion exact money renders the full endpoint immediately',
      (tester) async {
    final amount = Money(9007199254740993, 'KWD');
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Scaffold(body: AnimatedAmountText.money(
        value: amount, color: Colors.black)))));
    await tester.pump();
    expect(find.text(formatMoney(amount)), findsOneWidget);
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(tester.takeException(), isNull);
  });
}
