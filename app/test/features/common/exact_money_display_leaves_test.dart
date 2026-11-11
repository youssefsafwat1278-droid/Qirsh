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
import 'package:money_companion/data/repositories/drift_plan_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/report_models.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/finance/money_format.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/subscriptions/bill_details_sheet.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'exact-display-memory-only';
  @override
  Future<String?> readStoredKey() async => 'exact-display-memory-only';
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 100)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(finder, 180,
      scrollable: find.byType(Scrollable).last);
  await tester.pumpAndSettle();
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(),
        keyStore: _MemoryKeys(), initialLanguage: 'en');
  });
  tearDown(() async => db.close());

  for (final component in ['accounts', 'plans', 'subscriptions', 'billDetails', 'remainingSubs', 'remainingBillDetails']) {
    for (final language in ['ar', 'en']) {
      for (final dark in [false, true]) {
        for (final minor in [12345, 9007199254740993]) {
          testWidgets('$component exact KWD$minor $language dark$dark uses canonical leaves without writes', (tester) async {
            tester.view.physicalSize = const Size(375, 812);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            await tester.runAsync(() async {
              final font = FontLoader('Vazirmatn');
              for (final weight in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
                font.addFont(rootBundle.load('assets/fonts/Vazirmatn-$weight.ttf'));
              }
              await font.load();
            });
            final now = DateTime.now().toUtc();
            Money money(int delta) => Money(minor + delta, 'KWD');
            final accounts = DriftAccountRepository(db);
            final transactions = DriftTransactionRepository(db);
            for (final spec in [('picker', 5, null, null), ('unassigned', 6, null, '8888'),
                ('linked', 3, 'qa-main', '7777'),
                if (component == 'remainingBillDetails') ('suggested', 13, 'qa-main', null)]) {
              if (spec.$1 == 'linked') {
            await accounts.create(AccountEntity(id: 'qa-main', name: 'QA KWD account',
              currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0,
              initialBalanceMoney: Money.zero('KWD'), currentBalanceMoney: Money.zero('KWD'),
              createdAt: now, updatedAt: now));
              }
              await transactions.saveTransaction(transaction: TransactionEntity(
                id: spec.$1, amountMoney: money(spec.$2), currency: 'KWD',
                type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
                occurredAt: now, createdAt: now, updatedAt: now,
                accountId: spec.$3, cardLast4: spec.$4,
                rawMerchant: spec.$1 == 'suggested' ? 'QA exact subscription' : 'QA ${spec.$1}', rawMessage: 'Synthetic exact-money display only',
                parseConfidence: 1, status: TransactionStatus.confirmed,
              ), categoryKey: 'groceries');
            }
            final plans = DriftPlanRepository(db);
            await plans.save(PlanEntity(id: 'qa-plan', name: 'QA exact plan',
              budgetAmountMoney: money(4), currency: 'KWD',
              startDate: now.subtract(const Duration(days: 1)),
              endDate: now.add(const Duration(days: 14)), accountIds: const ['qa-main'],
              cardLast4s: const [], status: PlanStatus.active, createdAt: now));
            await plans.linkTransactionToPlan(planId: 'qa-plan', transactionId: 'linked');
            final bills = DriftBillRepository(db);
            final subscription = await bills.save(BillEntity(id: 'qa-sub', name: 'QA exact subscription',
              amountMoney: money(0), manualPaidMoney: component == 'remainingBillDetails'
                  ? Money(minor * 2 + 34, 'KWD') : money(1), currency: 'KWD',
              type: BillType.subscription, frequency: BillFrequency.monthly,
              nextDueDate: now.add(const Duration(days: 10)), reminderOn: false,
              isConfirmed: true, createdAt: now, accountId: 'qa-main'));
            final installment = await bills.save(BillEntity(id: 'qa-inst', name: 'QA exact installment',
              amountMoney: money(2), currency: 'KWD',
              type: BillType.installment, frequency: BillFrequency.monthly,
              totalInstallments: 3, paidCount: 1,
              manualPaidMoney: component == 'remainingSubs' ? money(20) : null,
              totalPurchaseMoney: component == 'remainingSubs' ? money(21) : null,
              nextDueDate: now.add(const Duration(days: 11)), reminderOn: false,
              isConfirmed: true, createdAt: now, accountId: 'qa-main'));
            await bills.recordPayment(BillPaymentEntity(id: 'qa-payment', billId: subscription.id,
              amountMoney: money(7), currency: 'KWD', periodStart: now,
              periodEnd: now.add(const Duration(days: 30)), paidAt: now));
            Future<Map<String, Object>> snapshot() async => {
              for (final table in ['accounts', 'transactions', 'plans',
                  'plan_transaction_links', 'subscriptions', 'bill_payments'])
                table: (await db.customSelect('SELECT * FROM $table ORDER BY rowid').get())
                    .map((row) => row.data).toList(),
            };
            final before = await snapshot();
            final Widget home = switch (component) {
              'accounts' => const AccountsScreen(),
              'plans' => const PlansScreen(),
              'subscriptions' || 'remainingSubs' => const SubscriptionsScreen(),
              _ => Builder(builder: (context) => Scaffold(body: TextButton(
                onPressed: () => BillDetailsSheet.show(context, subscription),
                child: const Text('Open details')))),
            };
            await tester.pumpWidget(ProviderScope(overrides: [
              appDatabaseProvider.overrideWithValue(db),
              baseCurrencyProvider.overrideWith((_) async => 'KWD'),
              subscriptionsProvider.overrideWith((_) async => component == 'remainingSubs'
                  ? [RecurringCandidate(merchantId: 'qa-suggestion', name: 'QA exact suggestion',
                      estimatedAmountMoney: money(18), currency: 'KWD', monthsSeen: 3)]
                  : const []),
              bannerEligibilityProvider(AdPlacement.subscriptions).overrideWith((_) async => false),
            ], child: MaterialApp(theme: dark ? AppTheme.dark : AppTheme.light,
              locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
              localizationsDelegates: AppL10n.localizationsDelegates, home: home)));
            await _settle(tester);
            final context = tester.element(find.byType(Scaffold).first);
            final l10n = AppL10n.of(context);
            final currency = Currency.label(context, 'KWD');
            if (component == 'accounts') {
              final exact = find.text(formatMoney(-money(6)));
              await _reveal(tester, find.text(l10n.accUnassignedCards));
              expect(exact, findsOneWidget);
            } else if (component == 'plans') {
              await _reveal(tester, find.text('QA exact plan'));
              await tester.tap(find.text('QA exact plan'));
              await _settle(tester);
              expect(find.text('${formatMoney(money(3))} $currency'), findsWidgets);
              expect(find.text(l10n.plOfBudget(formatMoney(money(4)), currency)), findsOneWidget);
              await _reveal(tester, find.text('QA linked'));
              final history = find.ancestor(of: find.text('QA linked'), matching: find.byType(Row)).first;
              expect(find.descendant(of: history,
                  matching: find.text('${formatMoney(money(3))} $currency')), findsOneWidget);
              final link = find.widgetWithText(FilledButton, l10n.plLinkTransaction);
              await tester.ensureVisible(link);
              await tester.tap(link);
              await _settle(tester);
              await _reveal(tester, find.text('QA picker'));
              final picker = find.ancestor(of: find.text('QA picker'), matching: find.byType(Row)).first;
              expect(find.descendant(of: picker,
                  matching: find.text('${formatMoney(money(5))} $currency')), findsOneWidget);
            } else if (component == 'subscriptions') {
              // v3: one shared bills body in a plain list (was a NestedScrollView
              // with Subscriptions / Instalments tabs).
              await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
              await _settle(tester);
              await _reveal(tester, find.text('QA exact subscription'));
              final card = find.ancestor(of: find.text('QA exact subscription'), matching: find.byType(MaliCard)).first;
              expect(find.descendant(of: card, matching: find.text(formatMoney(money(0)))), findsOneWidget);
              expect(find.descendant(of: card,
                  matching: find.text('${formatMoney(money(1))} $currency')), findsOneWidget);
              for (final textFinder in [
                find.descendant(of: card, matching: find.text(formatMoney(money(0)))),
                find.descendant(of: card, matching: find.text('${formatMoney(money(1))} $currency')),
                // v3 second line: «status · cadence».
                find.descendant(of: card, matching: find.byWidgetPredicate((widget) =>
                    widget is Text && (widget.data?.endsWith(' · ${l10n.txnCycleMonthly}') ?? false))),
              ]) {
                final paragraph = tester.renderObject<RenderParagraph>(textFinder);
                expect(paragraph.didExceedMaxLines, isFalse);
                final bounds = tester.getRect(textFinder);
                expect(bounds.left, greaterThanOrEqualTo(0));
                expect(bounds.right, lessThanOrEqualTo(375));
              }
              // Subscriptions / Instalments is a chips row now.
              final tab = find.text(l10n.txnBillsInstalments);
              await tester.ensureVisible(tab);
              await tester.tap(tab);
              await _settle(tester);
              final remaining = money(2) * 2;
              await _reveal(tester, find.text(l10n.subsTotalInstDebt));
              expect(find.text('${formatMoney(remaining)} $currency'), findsOneWidget);
            } else if (component == 'remainingSubs') {
              await tester.drag(find.byType(Scrollable).first, const Offset(0, -450));
              await _settle(tester);
              await _reveal(tester, find.text('QA exact suggestion'));
              final suggestionCard = find.ancestor(of: find.text('QA exact suggestion'),
                  matching: find.byType(MaliCard)).first;
              expect(find.descendant(of: suggestionCard, matching: find.text(
                  l10n.txnEstPerMonth(formatMoney(money(18)), currency))), findsOneWidget);
              await tester.ensureVisible(find.text(l10n.txnBillsInstalments));
              await tester.tap(find.text(l10n.txnBillsInstalments));
              await _settle(tester);
              // v3: the old debt card's «nearest instalment» line is gone; the
              // «Upcoming» list is sorted by due date and carries the same
              // exact amount on the row (checked below).
              await _reveal(tester, find.text('QA exact installment'));
              final installmentCard = find.ancestor(of: find.text('QA exact installment'),
                  matching: find.byType(MaliCard)).first;
              expect(find.descendant(of: installmentCard,
                  matching: find.text(formatMoney(money(2)))), findsOneWidget);
              expect(find.descendant(of: installmentCard,
                  matching: find.text('${formatMoney(money(21))} $currency')), findsOneWidget);
              expect(find.descendant(of: installmentCard,
                  matching: find.text('${formatMoney(money(20))} $currency')), findsOneWidget);
            } else if (component == 'remainingBillDetails') {
              await tester.tap(find.text('Open details'));
              await _settle(tester);
              expect(find.text('${formatMoney(Money(minor * 2 + 34, 'KWD'))} $currency'), findsOneWidget);
              final totalPaidParagraph = tester.renderObject<RenderParagraph>(
                  find.text('${formatMoney(Money(minor * 2 + 34, 'KWD'))} $currency'));
              expect(totalPaidParagraph.didExceedMaxLines, isFalse,
                  reason: 'Every canonical amount glyph must remain visible, including large money.');

              expect(find.text(l10n.bdsIncludesLegacyManual(formatMoney(money(27)), currency)), findsOneWidget);
              final suggestedAmount = find.text('${formatMoney(money(13))} $currency');
              await _reveal(tester, find.text('QA exact subscription').last);
              await _reveal(tester, suggestedAmount);
              expect(suggestedAmount, findsOneWidget);
              Navigator.of(tester.element(find.byType(BillDetailsSheet))).pop();
              await tester.pumpAndSettle();
              final launcherContext = tester.element(find.text('Open details'));
              BillDetailsSheet.show(launcherContext, installment);
              await _settle(tester);
              final record = find.widgetWithText(FilledButton, l10n.bdsRecordInstalmentPayment);
              await _reveal(tester, record);
              await tester.tap(record);
              await tester.pumpAndSettle();
              expect(find.text(l10n.bdsPayRemainingInFull(formatMoney(money(2) * 2), currency)), findsOneWidget);
              await tester.tap(find.widgetWithText(TextButton, l10n.commonCancel));
              await tester.pumpAndSettle();
              expect(find.byKey(const ValueKey('bill-payment-amount')), findsNothing);
            } else {
              await tester.tap(find.text('Open details'));
              await _settle(tester);
              expect(find.text('${formatMoney(money(0))} $currency'), findsOneWidget);
              final paymentRow = find.ancestor(of: find.text(l10n.bdsPaymentNamed('QA exact subscription')),
                  matching: find.byType(Row)).first;
              final paymentAmount = find.descendant(of: paymentRow,
                  matching: find.text('${formatMoney(money(7))} $currency'));
              await _reveal(tester, find.text(l10n.bdsPaymentHistory));
              expect(paymentAmount, findsOneWidget);
            }
            // Only display/navigation is exercised: no link/pay/delete mutations.
            expect(await snapshot(), before);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
