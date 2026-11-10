import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/mali_card.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_bill_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/bill_metrics.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'activity-header-memory';
  @override
  Future<String?> readStoredKey() async => 'activity-header-memory';
}

Future<Map<String, Object>> _snapshot(AppDatabase db) async {
  final tables = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
  return {for (final row in tables)
    row.read<String>('name'): (await db.customSelect(
      'SELECT * FROM "${row.read<String>('name')}" ORDER BY rowid').get())
        .map((value) => value.data).toList()};
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

void _fullNumber(WidgetTester tester, Finder finder, String number) {
  expect(finder, findsOneWidget);
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.didExceedMaxLines, isFalse);
  final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: number.length));
  expect(boxes, isNotEmpty);
  expect(boxes.map((box) => box.top).toSet(), hasLength(1),
      reason: 'The complete canonical number must fit one visual line.');
  final bounds = tester.getRect(finder);
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(375));
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _Keys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final language in ['ar', 'en']) {
    for (final dark in [false, true]) {
      for (final minor in [12345, 9007199254740993]) {
        testWidgets('Activity Bills aggregate header/hero canonical KWD$minor $language dark$dark remain read-only', (tester) async {
          tester.view.physicalSize = const Size(375, 812);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          await tester.runAsync(() async {
            final fonts = FontLoader('Vazirmatn');
            for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
              fonts.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
            }
            await fonts.load();
          });
          final now = DateTime.now().toUtc();
          final accounts = DriftAccountRepository(db);
          for (final currency in ['KWD', 'EGP']) {
            await accounts.create(AccountEntity(id: 'qa-$currency', name: 'QA $currency',
              currency: currency, type: AccountType.bank, isDefault: currency == 'KWD',
              sortOrder: 0, createdAt: now, updatedAt: now,
              initialBalanceMoney: Money.zero(currency), currentBalanceMoney: Money.zero(currency)));
          }
          final bills = DriftBillRepository(db);
          for (final spec in [
            ('foreign', BillType.subscription, 'EGP', BillStatus.active, 7777700),
            ('paused', BillType.subscription, 'KWD', BillStatus.paused, minor + 100),
            ('sub', BillType.subscription, 'KWD', BillStatus.active, minor),
            ('inst', BillType.installment, 'KWD', BillStatus.active, minor + 2),
          ]) {
            await bills.save(BillEntity(id: 'qa-header-${spec.$1}', name: 'QA ${spec.$1}',
              amountMoney: Money(spec.$5, spec.$3), currency: spec.$3,
              type: spec.$2, frequency: BillFrequency.monthly, status: spec.$4,
              accountId: 'qa-${spec.$3}', nextDueDate: now.add(const Duration(days: 10)),
              totalInstallments: spec.$2 == BillType.installment ? 3 : null,
              paidCount: spec.$2 == BillType.installment ? 1 : null,
              reminderOn: false, isConfirmed: true, createdAt: now));
          }
          final before = await _snapshot(db);
          final container = ProviderContainer(overrides: [
            appDatabaseProvider.overrideWithValue(db),
            baseCurrencyProvider.overrideWith((_) async => 'KWD'),
          ]);
          addTearDown(container.dispose);
          await tester.pumpWidget(UncontrolledProviderScope(container: container,
            child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates,
              home: const TransactionsScreen())));
          await _settle(tester);
          final context = tester.element(find.byType(TransactionsScreen));
          final l10n = AppL10n.of(context);
          final currency = Currency.label(context, 'KWD');
          await tester.ensureVisible(find.text(l10n.txnTabBills));
          await tester.tap(find.text(l10n.txnTabBills));
          await _settle(tester);
          final view = container.read(billsViewProvider).requireValue;
          expect(view.bills.map((bill) => bill.id), isNot(contains('qa-header-foreign')));
          expect(subscriptionMonthlyTotalMoney(view.bills, 'KWD'), Money(minor, 'KWD'));
          expect(find.text(l10n.txnActiveMonthlySpend), findsNothing,
              reason: 'the duplicate aggregate no longer delays the bills list');
          for (final installment in [false, true]) {
            if (installment) {
              final tab = find.descendant(
                of: find.byKey(const ValueKey('section-hero-bills')),
                matching: find.text(l10n.txnBillsInstalments),
              );
              // The subtype control now scrolls with the photo. Bring the
              // photo back before exercising the same canonical money checks.
              for (var scroll = 0;
                  scroll < 12 && tab.hitTestable().evaluate().isEmpty;
                  scroll++) {
                await tester.drag(
                  find.byType(Scrollable).last,
                  const Offset(0, 220),
                );
                await tester.pumpAndSettle();
              }
              expect(tab.hitTestable(), findsOneWidget);
              await tester.tap(tab);
              await _settle(tester);
            }
            final caption = installment ? l10n.txnTotalMonthlyInst : l10n.txnTotalMonthlySubs;
            await tester.scrollUntilVisible(find.text(caption), 140,
                scrollable: find.byType(Scrollable).last);
            await tester.pumpAndSettle();
            final hero = find.ancestor(of: find.text(caption), matching: find.byType(MaliCard)).first;
            final monthly = Money(minor + (installment ? 2 : 0), 'KWD');
            final monthlyText = formatMoney(monthly);
            _fullNumber(tester, find.descendant(of: hero,
                matching: find.text('$monthlyText $currency')), monthlyText);
            final yearlyText = formatMoney(monthly * 12);
            _fullNumber(tester, find.descendant(of: hero,
                matching: find.text('$yearlyText $currency')), yearlyText);
          }
          expect(tester.takeException(), isNull);
          expect(await _snapshot(db), before);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpAndSettle();
        });
      }
    }
  }
}
