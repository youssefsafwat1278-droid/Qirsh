// Transfer between two of the user's own accounts, through the real manual
// sheet and details screen on an in-memory database. Synthetic data only.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/glass_dropdown_field.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'manual-transfer-memory';
  @override
  Future<String?> readStoredKey() async => 'manual-transfer-memory';
}

const _fromKey = ValueKey('manual-transfer-from');
const _toKey = ValueKey('manual-transfer-to');
const _outside = '__outside__';

/// Accounts as (id, name, currency); the first one is the default.
const _three = [
  ('acc-a', 'Alpha', 'SAR'),
  ('acc-b', 'Beta', 'SAR'),
  ('acc-u', 'Dollar', 'USD'),
];

Future<AppDatabase> _db(WidgetTester tester,
    List<(String, String, String)> accounts) async {
  late AppDatabase db;
  await tester.runAsync(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _Keys());
    for (var i = 0; i < accounts.length; i++) {
      final (id, name, currency) = accounts[i];
      await db.customStatement(
        "INSERT INTO accounts(id, name, currency, type, is_default, "
        "sort_order, created_at, updated_at) VALUES('$id', '$name', "
        "'$currency', 'bank', ${i == 0 ? 1 : 0}, $i, "
        "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z');",
      );
    }
  });
  addTearDown(() async => tester.runAsync(db.close));
  return db;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
        () async => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 350));
  }
}

/// Pumps a launcher; [open] then opens the manual sheet (or details screen).
Future<ProviderContainer> _app(WidgetTester tester, AppDatabase db,
    {String lang = 'en', required Widget Function(BuildContext) open}) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
    await tester.pump(const Duration(seconds: 5));
  });
  await tester.pumpWidget(ProviderScope(
    overrides: [appDatabaseProvider.overrideWithValue(db)],
    child: MaterialApp(
      locale: Locale(lang),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      theme: AppTheme.light,
      home: Scaffold(body: Builder(builder: open)),
    ),
  ));
  return ProviderScope.containerOf(tester.element(find.byType(Scaffold)));
}

Widget Function(BuildContext) _sheet(TransactionEntity? Function() tx) =>
    (context) => TextButton(
          onPressed: () =>
              ManualTransactionSheet.show(context, transaction: tx()),
          child: const Text('open'),
        );

Future<AppL10n> _tapOpen(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await _settle(tester);
  return AppL10n.of(tester.element(find.byType(Scaffold).last));
}

GlassDropdownField<String> _field(WidgetTester tester, Key key) =>
    tester.widget<GlassDropdownField<String>>(find.byKey(key));

List<String?> _items(WidgetTester tester, Key key) =>
    [for (final item in _field(tester, key).items) item.value];

Future<void> _save(WidgetTester tester, AppL10n l10n, String label) async {
  final save = find.widgetWithText(FilledButton, label);
  await tester.ensureVisible(save);
  await tester.pump();
  await tester.tap(save);
  await _settle(tester);
}

Future<List<Map<String, Object?>>> _transfers(
        WidgetTester tester, AppDatabase db) async =>
    (await tester.runAsync(() => db
        .customSelect("SELECT id, account_id, direction, amount, currency, "
            "transfer_group_id, status FROM transactions "
            "WHERE type = 'transfer' ORDER BY direction DESC;")
        .get()))!
        .map((r) => r.data)
        .toList();

void main() {
  testWidgets('Transfer mode shows From and To; Expense and Income do not',
      (tester) async {
    final db = await _db(tester, _three);
    await _app(tester, db, open: _sheet(() => null));
    final l10n = await _tapOpen(tester);

    expect(find.byKey(_fromKey), findsNothing);
    expect(find.byKey(_toKey), findsNothing);
    expect(find.text(l10n.txnCategory), findsOneWidget);
    await tester.tap(find.text(l10n.txnKindIncome));
    await _settle(tester);
    expect(find.byKey(_fromKey), findsNothing);
    expect(find.byKey(_toKey), findsNothing);

    await tester.tap(find.text(l10n.txdTypeTransfer));
    await _settle(tester);
    expect(find.byKey(_fromKey), findsOneWidget);
    expect(find.byKey(_toKey), findsOneWidget);
    expect(find.text(l10n.mtFromAccount), findsOneWidget);
    expect(find.text(l10n.mtToAccount), findsOneWidget);
    expect(find.text(l10n.txnCategory), findsNothing);
    expect(find.text(l10n.mtTransferHint), findsOneWidget);
  });

  testWidgets('To never offers From or another currency; swap exchanges them',
      (tester) async {
    final db = await _db(tester, _three);
    await _app(tester, db, open: _sheet(() => null));
    final l10n = await _tapOpen(tester);
    await tester.tap(find.text(l10n.txdTypeTransfer));
    await _settle(tester);

    expect(_field(tester, _fromKey).value, 'acc-a');
    expect(_field(tester, _toKey).value, 'acc-b');
    expect(_items(tester, _toKey), ['acc-b', _outside]);

    await tester.tap(find.byTooltip(l10n.mtSwapAccounts));
    await _settle(tester);
    expect(_field(tester, _fromKey).value, 'acc-b');
    expect(_field(tester, _toKey).value, 'acc-a');
    expect(_items(tester, _toKey), ['acc-a', _outside]);

    // A USD From has no other USD account: To falls back to someone else.
    _field(tester, _fromKey).onChanged!('acc-u');
    await _settle(tester);
    expect(_field(tester, _toKey).value, _outside);
    expect(_items(tester, _toKey), [_outside]);
  });

  testWidgets('one account: To is someone else and save writes one debit row',
      (tester) async {
    final db = await _db(tester, [_three.first]);
    await _app(tester, db, open: _sheet(() => null));
    final l10n = await _tapOpen(tester);
    await tester.tap(find.text(l10n.txdTypeTransfer));
    await _settle(tester);

    expect(_field(tester, _toKey).value, _outside);
    await tester.enterText(find.byType(TextField).first, '120');
    await _save(tester, l10n, l10n.mtAddTransaction);

    final rows = await _transfers(tester, db);
    expect(rows, hasLength(1));
    expect(rows.single['account_id'], 'acc-a');
    expect(rows.single['direction'], 'debit');
    expect(rows.single['transfer_group_id'], isNull);
    expect(find.byType(ManualTransactionSheet), findsNothing);
  });

  testWidgets('two accounts: save writes a linked pair, totals unchanged',
      (tester) async {
    final db = await _db(tester, _three);
    final now = DateTime.now();
    await tester.runAsync(() async {
      final at = now.toUtc().toIso8601String();
      final food = (await db
              .customSelect("SELECT id FROM categories WHERE key = 'restaurants';")
              .getSingle())
          .read<String>('id');
      for (final (id, type, amount) in [
        ('pay-a', 'payment', 40.0),
        ('inc-a', 'income', 1000.0),
      ]) {
        await db.customStatement(
          "INSERT INTO transactions(id, amount, currency, type, source, "
          "occurred_at, raw_message, parse_confidence, status, created_at, "
          "updated_at, account_id, category_id) VALUES ('$id', $amount, "
          "'SAR', '$type', 'bank', '$at', 'sms', 1.0, 'confirmed', '$at', "
          "'$at', 'acc-a', '$food');",
        );
      }
      await backfillNonPlanningMoneyV30(db);
    });
    final container = await _app(tester, db, open: _sheet(() => null));
    final repo = container.read(transactionRepositoryProvider);
    final monthStart = DateTime(now.year, now.month);
    final monthEnd = DateTime(now.year, now.month + 1);
    Future<List<Money>> totals() async => (await tester.runAsync(() async => [
          for (final account in [null, 'acc-a', 'acc-b']) ...[
            await repo.expenseTotalBetween(
                from: monthStart,
                to: monthEnd,
                currency: 'SAR',
                accountId: account),
            await repo.incomeTotalBetween(
                from: monthStart,
                to: monthEnd,
                currency: 'SAR',
                accountId: account),
          ],
        ]))!;
    final before = await totals();
    expect(before.first, Money.parse('40', 'SAR'));

    final l10n = await _tapOpen(tester);
    await tester.tap(find.text(l10n.txdTypeTransfer));
    await _settle(tester);
    await tester.enterText(find.byType(TextField).first, '300');
    await _save(tester, l10n, l10n.mtAddTransaction);

    final rows = await _transfers(tester, db);
    expect(rows, hasLength(2));
    expect([for (final r in rows) (r['account_id'], r['direction'])],
        [('acc-a', 'debit'), ('acc-b', 'credit')]);
    expect(rows[0]['transfer_group_id'], isNotNull);
    expect(rows[0]['transfer_group_id'], rows[1]['transfer_group_id']);
    expect(rows.map((r) => r['amount']), [300.0, 300.0]);
    expect(rows.map((r) => r['currency']), ['SAR', 'SAR']);
    expect(await totals(), before);
  });

  Future<({TransactionEntity debit, TransactionEntity credit})> pair(
          WidgetTester tester, ProviderContainer container) async =>
      (await tester.runAsync(() =>
          container.read(transferPairServiceProvider).savePair(
                fromAccountId: 'acc-a',
                toAccountId: 'acc-b',
                amountOut: Money.parse('300', 'SAR'),
                amountIn: Money.parse('300', 'SAR'),
                currencyOut: 'SAR',
                currencyIn: 'SAR',
                occurredAt: DateTime.utc(2026, 7, 15, 10),
              )))!;

  testWidgets('editing the credit leg shows the pair; saving updates both',
      (tester) async {
    final db = await _db(tester, _three);
    TransactionEntity? open;
    final container = await _app(tester, db, open: _sheet(() => open));
    open = (await pair(tester, container)).credit;
    final l10n = await _tapOpen(tester);

    expect(_field(tester, _fromKey).value, 'acc-a');
    expect(_field(tester, _toKey).value, 'acc-b');
    expect(find.text(l10n.mtTransferTypeLocked), findsOneWidget);
    await tester.tap(find.text(l10n.mtKindExpense), warnIfMissed: false);
    await _settle(tester);
    expect(find.byKey(_toKey), findsOneWidget,
        reason: 'the type selector is disabled while editing a pair');

    await tester.enterText(find.byType(TextField).first, '450');
    await _save(tester, l10n, l10n.mtSaveEdits);

    final rows = await _transfers(tester, db);
    expect([for (final r in rows) (r['account_id'], r['direction'])],
        [('acc-a', 'debit'), ('acc-b', 'credit')]);
    expect(rows.map((r) => r['amount']), [450.0, 450.0]);
  });

  testWidgets('deleting a paired leg says both sides and removes both',
      (tester) async {
    final db = await _db(tester, _three);
    TransactionEntity? open;
    final container = await _app(tester, db, open: _sheet(() => open));
    open = (await pair(tester, container)).debit;
    final l10n = await _tapOpen(tester);

    final delete = find.widgetWithText(OutlinedButton, l10n.txdDeleteTx);
    await tester.ensureVisible(delete);
    await tester.pump();
    await tester.tap(delete);
    await _settle(tester);
    expect(find.text(l10n.txdDeletePairBody), findsOneWidget);
    await tester.tap(find.text(l10n.setDelete));
    await _settle(tester);

    final rows = await _transfers(tester, db);
    expect(rows, hasLength(2));
    expect(rows.map((r) => r['status']), ['ignored', 'ignored']);
  });

  testWidgets('Arabic: RTL sheet with Arabic labels', (tester) async {
    final db = await _db(tester, _three);
    await _app(tester, db, lang: 'ar', open: _sheet(() => null));
    final l10n = await _tapOpen(tester);
    expect(l10n.localeName, 'ar');
    await tester.tap(find.text(l10n.txdTypeTransfer));
    await _settle(tester);

    expect(Directionality.of(tester.element(find.byKey(_toKey))),
        TextDirection.rtl);
    expect(find.text('من حساب'), findsOneWidget);
    expect(find.text('إلى حساب'), findsOneWidget);
  });

  testWidgets('Arabic details screen states «من … إلى …» for a paired leg',
      (tester) async {
    final db = await _db(tester, _three);
    String? id;
    final container = await _app(tester, db,
        lang: 'ar',
        open: (context) => TextButton(
              onPressed: () =>
                  TransactionDetailsScreen.showSheet(context, id!),
              child: const Text('open'),
            ));
    id = (await pair(tester, container)).credit.id;
    await _tapOpen(tester);

    expect(find.text('من Alpha إلى Beta'), findsOneWidget);
  });

  testWidgets('details: English sentence; delete removes both sides',
      (tester) async {
    final db = await _db(tester, _three);
    String? id;
    final container = await _app(tester, db,
        open: (context) => TextButton(
              onPressed: () =>
                  TransactionDetailsScreen.showSheet(context, id!),
              child: const Text('open'),
            ));
    id = (await pair(tester, container)).debit.id;
    final l10n = await _tapOpen(tester);
    expect(find.text('From Alpha → To Beta'), findsOneWidget);

    final delete = find.text(l10n.txdDeleteTx);
    await tester.ensureVisible(delete);
    await tester.pump();
    await tester.tap(delete);
    await _settle(tester);
    expect(find.text(l10n.txdDeletePairBody), findsOneWidget);
    await tester.tap(find.text(l10n.setDelete));
    await _settle(tester);

    final rows = await _transfers(tester, db);
    expect(rows.map((r) => r['status']), ['ignored', 'ignored']);
  });

  testWidgets('old single-row transfer: To is someone else; an own To adds '
      'the second leg', (tester) async {
    final db = await _db(tester, _three);
    TransactionEntity? open;
    final container = await _app(tester, db, open: _sheet(() => open));
    open = (await tester.runAsync(() =>
        container.read(transferPairServiceProvider).saveOutside(
              accountId: 'acc-a',
              amount: Money.parse('80', 'SAR'),
              currency: 'SAR',
              direction: TransactionDirectionEntity.debit,
              occurredAt: DateTime.utc(2026, 7, 15, 10),
            )))!;
    final l10n = await _tapOpen(tester);

    expect(_field(tester, _fromKey).value, 'acc-a');
    expect(_field(tester, _toKey).value, _outside);
    expect(find.text(l10n.mtTransferTypeLocked), findsNothing);
    _field(tester, _toKey).onChanged!('acc-b');
    await _settle(tester);
    await _save(tester, l10n, l10n.mtSaveEdits);

    final rows = await _transfers(tester, db);
    expect([for (final r in rows) (r['account_id'], r['direction'])],
        [('acc-a', 'debit'), ('acc-b', 'credit')]);
    expect(rows[0]['id'], open.id);
    expect(rows[0]['transfer_group_id'], rows[1]['transfer_group_id']);
    expect(rows[0]['transfer_group_id'], isNotNull);
  });
}
