import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/calm_page_header.dart';
import 'package:money_companion/core/theme/widgets/section_photo_header.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/core/utils/currency.dart';
import 'package:money_companion/features/common/qirsh_summary_card.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/subscriptions/bill_form_sheet.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Accounts implements AccountRepository {
  @override
  Future<AccountEntity?> getDefault() async => null;
  @override
  Future<AccountEntity?> getById(String id) async => null;
  @override
  Future<List<AccountEntity>> getAll() async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

BillEntity _bill(String id, int amount, {String currency = 'KWD',
    BillType type = BillType.subscription, BillFrequency frequency = BillFrequency.monthly,
    BillStatus status = BillStatus.active}) => BillEntity(id: id, name: id,
      amountMoney: Money(amount, currency), currency: currency, type: type,
      frequency: frequency, status: status,
      nextDueDate: DateTime.now().add(const Duration(days: 15)), reminderOn: true,
      isConfirmed: true, createdAt: DateTime(2026, 1, 15));

final _bills = [
  _bill('Monthly', 12345),
  _bill('Yearly', 12000, frequency: BillFrequency.yearly),
  _bill('Paused', 900000, status: BillStatus.paused),
  _bill('Foreign', 999999, currency: 'SAR'),
  _bill('Instalment', 2345, type: BillType.installment),
];

Future<AppL10n> _open(WidgetTester tester, Future<List<BillEntity>> Function() load,
    {required String language}) async {
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
  await tester.pumpWidget(ProviderScope(overrides: [
    savedBillsProvider.overrideWith((ref) => load()),
    subscriptionsProvider.overrideWith((ref) async => const []),
    billsScopeAccountProvider.overrideWith((ref) async => null),
    baseCurrencyProvider.overrideWith((ref) async => 'KWD'),
    accountRepositoryProvider.overrideWithValue(_Accounts()),
    accountsProvider.overrideWith((ref) async => const []),
    bannerEligibilityProvider(AdPlacement.subscriptions).overrideWith((ref) async => false),
  ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => const SubscriptionsScreen())),
          child: const Text('Open subscriptions')))))));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open subscriptions'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  return AppL10n.of(tester.element(find.byType(SubscriptionsScreen)));
}

void _header(WidgetTester tester, AppL10n l10n) {
  // v3: loading, error and data all open with the SAME photo hero (Back,
  // one-line title, Add) — no AppHeader bar that changes once data arrives.
  final cover = find.byType(QirshSectionHero);
  expect(cover, findsOneWidget);
  expect(tester.widget<QirshSectionHero>(cover).photo, QirshSectionPhoto.bills);
  // One page name everywhere: «الفواتير والاشتراكات» / "Bills & subscriptions".
  final title = find.descendant(of: cover, matching: find.text(l10n.txnBillsAndSubs));
  // v2 title.large (Alexandria 700 30/38), shrunk to fit on ONE line.
  expect(tester.widget<Text>(title).style!.fontSize, 30);
  expect(tester.widget<Text>(title).style!.color, Colors.white);
  expect(tester.widget<Text>(title).maxLines, 1);
  expect(tester.widget<QirshSectionHero>(cover).fitTitle, isTrue);
  expect(find.byType(BackButton), findsOneWidget);
  expect(find.descendant(of: find.byType(QirshSectionHero), matching: find.byType(CalmHeaderAction)),
      findsOneWidget);
}

Future<void> _addAndBack(WidgetTester tester, AppL10n l10n) async {
  await tester.tap(find.descendant(of: find.byType(QirshSectionHero),
      matching: find.byType(CalmHeaderAction)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  expect(find.byType(BillFormSheet), findsOneWidget);
  expect(tester.widget<BillFormSheet>(find.byType(BillFormSheet)).initialType,
      BillType.subscription);
  Navigator.of(tester.element(find.byType(BillFormSheet))).pop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.byType(BackButton));
  await tester.pumpAndSettle();
  expect(find.text('Open subscriptions'), findsOneWidget);
  expect(find.byType(SubscriptionsScreen), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  for (final language in ['ar', 'en']) {
    testWidgets('subscription loading retains the photo header, Back and Add in $language',
        (tester) async {
      final pending = Completer<List<BillEntity>>();
      final l10n = await _open(tester, () => pending.future, language: language);
      _header(tester, l10n);
      await _addAndBack(tester, l10n);
      pending.complete(const []);
      await tester.pumpAndSettle();
    });

    testWidgets('subscription error retries without losing header actions in $language',
        (tester) async {
      var reads = 0;
      final l10n = await _open(tester, () async {
        if (reads++ == 0) throw StateError('synthetic bill read failure');
        return _bills;
      }, language: language);
      await tester.pumpAndSettle();
      _header(tester, l10n);
      expect(find.text(l10n.txnError), findsOneWidget);
      await tester.tap(find.text(l10n.startRetry));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text(l10n.txnError), findsNothing);
      _header(tester, l10n);
      await _addAndBack(tester, l10n);
    });

    testWidgets('subscription data keeps exact monthly metrics in the shared bills body in $language',
        (tester) async {
      final l10n = await _open(tester, () async => _bills, language: language);
      await tester.pumpAndSettle();
      _header(tester, l10n);
      final currency = Currency.label(tester.element(find.byType(SubscriptionsScreen)), 'KWD');
      final summary = find.byType(QirshSummaryCard);
      expect(summary, findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text(l10n.subsMonthlyTotal)),
          findsOneWidget);
      // active monthly 12.345 + yearly 12/12, no SAR or paused amount.
      expect(find.descendant(of: summary, matching: find.text('13.345 $currency')),
          findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('160.140 $currency')),
          findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text(l10n.subsMonthlyInstCommit)),
          findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('2.345 $currency')),
          findsOneWidget);
      // Every subscription is listed ONCE (no «Upcoming» + «All» duplicate).
      for (final name in ['Monthly', 'Yearly', 'Paused', 'Foreign']) {
        expect(find.text(name), findsOneWidget);
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -420));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 420));
      await tester.pumpAndSettle();
      _header(tester, l10n);
      await _addAndBack(tester, l10n);
    });
  }
}
