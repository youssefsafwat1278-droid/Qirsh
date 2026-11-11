import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_goal_repository.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/usecases/save_goal_usecase.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

void main() {
  late AppDatabase db;
  late DriftGoalRepository goals;
  late DriftAccountRepository accounts;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
    goals = DriftGoalRepository(db);
    accounts = DriftAccountRepository(db);
    final now = DateTime.utc(2026, 1, 1);
    await accounts.create(AccountEntity(id: 'sofa', name: 'Synthetic KWD', currency: 'KWD',
      type: AccountType.bank, isDefault: true, sortOrder: 0, createdAt: now, updatedAt: now,
      initialBalanceMoney: Money.zero('KWD'), currentBalanceMoney: Money.zero('KWD')));
  });
  tearDown(() async => db.close());

  GoalEntity original({bool autoSave = true}) => GoalEntity(
    id: 'synthetic-goal', name: 'Synthetic goal', accountId: 'sofa', currency: 'KWD',
    targetMoney: Money(50000, 'KWD'), savedMoney: Money(12345, 'KWD'),
    lastNotifiedSavedMoney: Money(10000, 'KWD'),
    deadline: DateTime.now().toUtc().add(const Duration(days: 60)),
    vaultSkin: 'photo:travel', status: 'active', createdAt: DateTime.utc(2026, 1, 1),
    autoSaveMoney: autoSave ? Money(2345, 'KWD') : null,
    autoSavePeriod: autoSave ? 'weekly' : null,
    autoSaveLastRun: autoSave ? DateTime.utc(2026, 10, 1, 4, 2, 3) : null,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (!tester.binding.hasScheduledFrame) return;
    }
  }

  Future<AppL10n> open(WidgetTester tester, String language,
      {GoalEntity? existing, bool compact = false}) async {
    tester.view.physicalSize = compact ? const Size(375, 667) : const Size(402, 1600);
    tester.view.devicePixelRatio = 1;
    if (compact) tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.reset);
    if (existing != null) await goals.save(existing);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
      goalRepositoryProvider.overrideWithValue(goals),
      accountRepositoryProvider.overrideWithValue(accounts),
      activeAccountIdProvider.overrideWith((ref) => null),
      baseCurrencyProvider.overrideWith((ref) async => existing == null ? 'KWD' : 'EGP'),
      saveGoalUseCaseProvider.overrideWithValue(SaveGoalUseCase(goals)),
    ], child: MaterialApp(theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => GoalFormScreen(goal: existing))), child: const Text('Open goal'),
      ))),
    )));
    await settle(tester);
    await tester.tap(find.text('Open goal'));
    await settle(tester);
    return AppL10n.of(tester.element(find.byType(GoalFormScreen)));
  }

  Future<void> save(WidgetTester tester, AppL10n l10n, {bool editing = true}) async {
    tester.testTextInput.hide();
    final submit = find.text(editing ? l10n.gfSaveEdit : l10n.gfCreateGoal);
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await settle(tester);
  }

  Future<List<Map<String, Object?>>> rows() async =>
      (await db.customSelect('SELECT * FROM goals ORDER BY id').get()).map((r) => r.data).toList();

  for (final language in ['ar', 'en']) {
    for (final spec in [('١٢٫٣٤٥', 12345), ('12,345.678', 12345678)]) {
      testWidgets('new goal saves exact localized target ${spec.$1} in $language', (tester) async {
        final l10n = await open(tester, language);
        await tester.enterText(find.byType(TextFormField).at(0), 'Localized goal');
        await tester.enterText(find.byType(TextFormField).at(1), spec.$1);
        await save(tester, l10n, editing: false);
        final result = (await goals.getAll()).single;
        expect(result.targetMoney, Money(spec.$2, 'KWD'));
        expect(result.currency, 'KWD');
        expect(result.accountId, 'sofa');
        expect(find.byType(GoalFormScreen), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('KWD edit parses target and autosave in own currency and preserves other financial fields in $language', (tester) async {
      final existing = original();
      final l10n = await open(tester, language, existing: existing);
      await tester.enterText(find.byType(TextFormField).at(1), '٥٠٫٠٠١');
      await tester.enterText(find.byType(TextField).last, '١٢٫٣٤٥');
      await save(tester, l10n);
      final result = (await goals.getById(existing.id))!;
      expect(result.targetMoney, Money(50001, 'KWD'));
      expect(result.autoSaveMoney, Money(12345, 'KWD'));
      expect(result.hasAutoSave, isTrue);
      expect(result.autoSavePeriod, existing.autoSavePeriod);
      expect(result.autoSaveLastRun, existing.autoSaveLastRun);
      expect(result.accountId, existing.accountId);
      expect(result.currency, existing.currency);
      expect(result.savedMoney, existing.savedMoney);
      expect(result.lastNotifiedSavedMoney, existing.lastNotifiedSavedMoney);
      expect(result.vaultSkin, existing.vaultSkin);
      expect(result.status, existing.status);
      expect(result.createdAt, existing.createdAt);
      expect(result.deadline, existing.deadline);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Arabic autosave cannot silently switch off when target is already canonical in $language', (tester) async {
      final existing = original();
      final l10n = await open(tester, language, existing: existing);
      await tester.enterText(find.byType(TextField).last, '١٢٫٣٤٥');
      await save(tester, l10n);
      final result = (await goals.getById(existing.id))!;
      expect(result.autoSaveMoney, Money(12345, 'KWD'));
      expect(result.autoSavePeriod, 'weekly');
      expect(result.autoSaveLastRun, existing.autoSaveLastRun);
      expect(result.targetMoney, existing.targetMoney);
      expect(tester.takeException(), isNull);
    });

    testWidgets('invalid target and autosave retain draft without any financial write in $language', (tester) async {
      final existing = original();
      final l10n = await open(tester, language, existing: existing);
      final before = await rows();
      for (final target in [true, false]) {
        for (final input in ['0', '-1', '12.3456', '1,23', 'abc']) {
          if (!target && input == '0') continue; // Existing zero-autosave means off.
          final field = target ? find.byType(TextFormField).at(1) : find.byType(TextField).last;
          await tester.enterText(field, input);
          await save(tester, l10n);
          expect(await rows(), before);
          expect(find.text(l10n.gfEnterValidAmount), findsWidgets);
          expect(tester.widget<TextField>(target ? find.byType(TextField).at(1) : find.byType(TextField).last).controller!.text, input);
          expect(find.byType(GoalFormScreen), findsOneWidget);
          await tester.pump(const Duration(seconds: 4));
          await settle(tester);
        }
        await tester.enterText(find.byType(TextFormField).at(1), '50.000');
      }
      expect(tester.takeException(), isNull);
    });

    for (final mode in ['off', 'empty', 'zero']) {
      testWidgets('autosave $mode keeps existing off semantics in $language', (tester) async {
        final existing = original();
        final l10n = await open(tester, language, existing: existing);
        if (mode == 'off') {
          await tester.tap(find.byType(Switch));
        } else {
          await tester.enterText(find.byType(TextField).last, mode == 'zero' ? '0' : '');
        }
        await save(tester, l10n);
        final result = (await goals.getById(existing.id))!;
        expect(result.autoSaveMoney, isNull);
        expect(result.autoSavePeriod, isNull);
        expect(result.autoSaveLastRun, isNull);
        expect(result.targetMoney, existing.targetMoney);
        expect(result.accountId, existing.accountId);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('localized target still yields daily suggestion without a financial write in $language', (tester) async {
      final existing = original();
      final l10n = await open(tester, language, existing: existing);
      final before = await rows();
      await tester.enterText(find.byType(TextFormField).at(1), '١٢٫٣٤٥');
      await settle(tester);
      expect(find.text(l10n.gfRecommendedAfterDate), findsNothing);
      expect(await rows(), before);
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact goal rejects offstage empty name without changing valid target in $language', (tester) async {
      final existing = original(autoSave: false);
      final l10n = await open(tester, language, existing: existing, compact: true);
      final before = await rows();
      await tester.enterText(find.byType(TextFormField).at(0), '');
      tester.testTextInput.hide();
      // Save sits in the sticky dock (v2), always on screen: scroll the FORM
      // to its end so the edited fields are offstage before submitting.
      await tester.scrollUntilVisible(find.byType(Switch), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await settle(tester);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.text(l10n.gfSaveEdit));
      await settle(tester);
      expect(await rows(), before);
      expect(find.text(l10n.gfEnterGoalName), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      final name = find.byWidgetPredicate((widget) => widget is TextFormField &&
          widget.controller?.text.isEmpty == true);
      await tester.scrollUntilVisible(name, -400,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<TextFormField>(name).controller!.text, isEmpty);
      final target = find.byWidgetPredicate((widget) => widget is TextFormField &&
          widget.controller?.text == '50.000');
      await tester.scrollUntilVisible(target, 200,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<TextFormField>(target).controller!.text, '50.000');
      expect(tester.takeException(), isNull);
    });

    testWidgets('compact goal rejects offstage negative target before Save in $language', (tester) async {
      final existing = original(autoSave: false);
      final l10n = await open(tester, language, existing: existing, compact: true);
      final before = await rows();
      await tester.enterText(find.byType(TextFormField).at(1), '-1');
      tester.testTextInput.hide();
      // Save sits in the sticky dock (v2), always on screen: scroll the FORM
      // to its end so the edited fields are offstage before submitting.
      await tester.scrollUntilVisible(find.byType(Switch), 400,
          scrollable: find.byType(Scrollable).first);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
      await settle(tester);
      expect(find.byType(TextFormField), findsNothing);
      await tester.tap(find.text(l10n.gfSaveEdit));
      await settle(tester);
      expect(await rows(), before);
      expect(find.text(l10n.gfEnterValidAmount), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await settle(tester);
      final amount = find.byWidgetPredicate((widget) => widget is TextFormField &&
          widget.controller?.text == '-1');
      await tester.scrollUntilVisible(amount, -400,
          scrollable: find.byType(Scrollable).first);
      expect(tester.widget<TextFormField>(amount).controller!.text, '-1');
      expect(tester.takeException(), isNull);
    });
  }
}
