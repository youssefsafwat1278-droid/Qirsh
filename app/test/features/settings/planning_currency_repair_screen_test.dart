import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/planning_currency_repair.dart';
import 'package:money_companion/features/settings/planning_currency_repair_providers.dart';
import 'package:money_companion/features/settings/planning_currency_repair_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryDatabaseKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';

  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _MemoryRepairStore implements RepairKeyValueStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late _MemoryRepairStore store;
  late PlanningCurrencyRepairService service;
  late String categoryId;

  Future<void> addBudget({
    String id = 'budget-1',
    double amount = 1250,
  }) async {
    await db.customStatement(
      "INSERT INTO budgets(id, category_id, amount, period, start_date, "
      "is_active) VALUES ('$id', '$categoryId', $amount, 'monthly', "
      "'2026-01-01T00:00:00Z', 1);",
    );
  }

  Future<void> addGoal({
    String id = 'goal-1',
    String name = 'رحلة',
    double amount = 5000,
  }) async {
    await db.customStatement(
      "INSERT INTO goals(id, name, target_amount, saved_amount, vault_skin, "
      "status, created_at) VALUES ('$id', '$name', $amount, 0, 'default', "
      "'active', '2026-01-01T00:00:00Z');",
    );
  }

  List<Override> overrides({String proposedCurrency = 'EGP'}) => [
        appDatabaseProvider.overrideWithValue(db),
        baseCurrencyProvider.overrideWith((ref) async => proposedCurrency),
        planningCurrencyRepairServiceProvider.overrideWith(
          (ref) async => service,
        ),
      ];

  Future<void> pumpRepairScreen(
    WidgetTester tester, {
    String proposedCurrency = 'EGP',
  }) async {
    tester.view.physicalSize = const Size(390, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(proposedCurrency: proposedCurrency),
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: const Locale('ar'),
          theme: AppTheme.light,
          home: const PlanningCurrencyRepairScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  setUp(() async {
    store = _MemoryRepairStore();
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryDatabaseKeyStore(),
    );
    categoryId = (await db
            .customSelect('SELECT id FROM categories ORDER BY id LIMIT 1;')
            .getSingle())
        .read<String>('id');
    service = PlanningCurrencyRepairService(
      db: db,
      store: store,
      installId: 'repair-ui-test-install',
    );
  });

  tearDown(() => db.close());

  test('provider exposes legacy-safe budget and goal REAL projections',
      () async {
    await addBudget(amount: 1250.5);
    await addGoal(amount: 5000.25);
    final container = ProviderContainer(overrides: overrides());
    addTearDown(container.dispose);

    final data = await container.read(planningCurrencyRepairProvider.future);

    expect(data.status, PlanningRepairStatus.needsConfirmation);
    expect(data.proposedCurrency, 'EGP');
    expect(data.budgets, hasLength(1));
    expect(data.budgets.single.id, 'budget-1');
    expect(data.budgets.single.legacyAmount, 1250.5);
    expect(data.goals, hasLength(1));
    expect(data.goals.single.title, 'رحلة');
    expect(data.goals.single.legacyAmount, 5000.25);
  });

  testWidgets('global confirm flow saves proposal and evaluates satisfied',
      (tester) async {
    await addBudget();
    await addGoal();
    await pumpRepairScreen(tester);

    expect(find.text('لماذا نحتاج تأكيدك؟'), findsOneWidget);
    expect(
      find.textContaining('لا تحفظ عملة مع المبلغ'),
      findsOneWidget,
    );
    final field = tester.widget<TextFormField>(
      find.byKey(const ValueKey('repair-global-currency')),
    );
    expect(field.controller!.text, 'EGP');

    await tapVisible(
      tester,
      find.byKey(const ValueKey('repair-confirm-global')),
    );

    expect(await service.evaluate(), PlanningRepairStatus.satisfied);
    final manifest = await service.currentValidManifest();
    expect(manifest!.mode, PlanningRepairMode.global);
    expect(manifest.globalCurrency, 'EGP');
    expect(find.text('تم تأكيد العملات'), findsOneWidget);
  });

  testWidgets('§14 copy is semantically truthful (treat-as, not detected-original)',
      (tester) async {
    await addBudget();
    await addGoal();
    await pumpRepairScreen(tester);

    // The screen must NEVER imply it rediscovered a historical/original currency.
    expect(find.textContaining('العملة الأصلية'), findsNothing);
    expect(find.textContaining('اكتشفنا'), findsNothing);
    expect(find.textContaining('الأصلية'), findsNothing);
    // It MUST frame the choice as how to TREAT the current items.
    expect(find.textContaining('تختار أنت كيف تريد معاملتها'), findsOneWidget);
    expect(
      find.textContaining('كل الميزانيات والأهداف الحالية تستخدم'),
      findsWidgets,
    );
  });

  testWidgets('per-row flow saves different budget and goal currencies',
      (tester) async {
    await addBudget();
    await addGoal();
    await pumpRepairScreen(tester);

    await tapVisible(
      tester,
      find.byKey(const ValueKey('repair-mode-per-row')),
    );
    expect(find.textContaining('المبلغ القديم: 1,250.00'), findsOneWidget);
    expect(
      find.textContaining('المبلغ المستهدف القديم: 5,000.00'),
      findsOneWidget,
    );
    expect(find.textContaining('مساهمة'), findsNothing);

    final goalCurrency = find.byKey(const ValueKey('repair-currency-goal-1'));
    await tester.ensureVisible(goalCurrency);
    await tester.tap(goalCurrency);
    await tester.pumpAndSettle();
    // Closure round (decision 3.7): the menu lists every ISO-4217 currency,
    // so EUR may be off-screen in the lazily built menu.
    await tester.scrollUntilVisible(find.text('EUR — يورو'), 100,
        scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('EUR — يورو'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EUR — يورو').last);
    await tester.pumpAndSettle();

    await tapVisible(
      tester,
      find.byKey(const ValueKey('repair-confirm-per-row')),
    );

    expect(await service.evaluate(), PlanningRepairStatus.satisfied);
    final manifest = await service.currentValidManifest();
    expect(manifest!.mode, PlanningRepairMode.perRow);
    expect(
      manifest.perRowCurrency,
      {'budget-1': 'EGP', 'goal-1': 'EUR'},
    );
  });

  testWidgets('unsupported currency shows validation and writes no manifest',
      (tester) async {
    await addBudget();
    await pumpRepairScreen(tester);

    await tester.enterText(
      find.byKey(const ValueKey('repair-global-currency')),
      'ZZZ',
    );
    await tapVisible(
      tester,
      find.byKey(const ValueKey('repair-confirm-global')),
    );

    expect(
      find.byKey(const ValueKey('repair-validation-error')),
      findsOneWidget,
    );
    expect(store.values, isEmpty);
    expect(
      await service.evaluate(),
      PlanningRepairStatus.needsConfirmation,
    );
  });

  testWidgets('cancel defers without writing a manifest', (tester) async {
    await addBudget();
    tester.view.physicalSize = const Size(390, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides(),
        child: MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: const Locale('ar'),
          theme: AppTheme.light,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PlanningCurrencyRepairScreen(),
                  ),
                ),
                child: const Text('افتح الإصلاح'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('افتح الإصلاح'));
    await tester.pumpAndSettle();
    await tapVisible(tester, find.byKey(const ValueKey('repair-defer')));

    expect(find.text('افتح الإصلاح'), findsOneWidget);
    expect(store.values, isEmpty);
    expect(
      await service.evaluate(),
      PlanningRepairStatus.needsConfirmation,
    );
  });

  testWidgets('stale state refreshes rows and allows re-confirmation',
      (tester) async {
    await addBudget();
    await service.confirmGlobal('EGP');
    await addGoal(id: 'goal-added-later', name: 'سيارة');
    await pumpRepairScreen(tester);

    expect(find.text('تغيّرت الميزانيات أو الأهداف'), findsOneWidget);
    expect(await service.evaluate(), PlanningRepairStatus.stale);

    await tapVisible(tester, find.byKey(const ValueKey('repair-refresh')));
    expect(find.text('تغيّرت الميزانيات أو الأهداف'), findsOneWidget);

    await tapVisible(
      tester,
      find.byKey(const ValueKey('repair-confirm-global')),
    );
    expect(await service.evaluate(), PlanningRepairStatus.satisfied);
    expect(find.text('تم تأكيد العملات'), findsOneWidget);
  });
}
