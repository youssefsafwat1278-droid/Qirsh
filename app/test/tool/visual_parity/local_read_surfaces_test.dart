import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/utils/app_lucide_icons.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/app/local_read_shell.dart';
import 'package:money_companion/features/help/coach_marks.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:money_companion/core/sync/sync_status.dart';
import 'package:money_companion/features/settings/sync_status_providers.dart';
import 'package:money_companion/features/settings/sync_status_ui.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart' hide SyncStatus;
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/common/app_button.dart';
import 'package:money_companion/features/common/app_category_chip.dart';
import 'package:money_companion/features/common/category_catalog.dart';

import '../../../tool/visual_parity/local_read_surfaces.dart';

class _Keys implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory';
  @override
  Future<String?> readStoredKey() async => 'memory';
}

class _Launch extends ConsumerWidget {
  const _Launch(this.keyName);
  final String keyName;
  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: TextButton(onPressed: () =>
        openVisualParityLocalReadSurface(context, ref, keyName),
        child: const Text('Open fixture')),
  );
}

void main() {
  late AppDatabase db;
  setUp(() async {
    db = await AppDatabase.open(executor: NativeDatabase.memory(), keyStore: _Keys());
  });
  tearDown(() async => db.close());

  Future<void> open(WidgetTester tester, String key, String language) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(overrides: [
      appDatabaseProvider.overrideWithValue(db),
    ], child: MaterialApp(
      theme: language == 'ar' ? AppTheme.dark : AppTheme.light,
      locale: Locale(language), supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: AppL10n.localizationsDelegates,
      home: _Launch(key),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open fixture'));
    await tester.runAsync(() async =>
        Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pumpAndSettle();
  }

  Future<Map<String, List<Map<String, Object?>>>> ledgerSnapshot() async {
    final tables = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").get();
    return {for (final table in tables)
      table.read<String>('name'): (await db.customSelect(
        'SELECT * FROM "${table.read<String>('name')}" ORDER BY rowid').get())
          .map((row) => row.data).toList()};
  }

  for (final language in ['ar', 'en']) {
    for (final key in ['changeCategorySaving', 'changeCategoryError']) {
      testWidgets('$key uses real public category sheet and leaves all memory tables unchanged in $language', (tester) async {
        final now = DateTime.utc(2026, 11, 1);
        final repository = DriftTransactionRepository(db);
        await repository.saveTransaction(transaction: TransactionEntity(
          id: visualParityChangeCategoryTransactionId,
          amountMoney: Money(12345, 'EGP'), currency: 'EGP',
          type: TransactionTypeEntity.payment, source: TransactionSourceEntity.bank,
          occurredAt: now, createdAt: now, updatedAt: now,
          rawMerchant: 'QA category merchant', rawMessage: 'synthetic',
          parseConfidence: 1, status: TransactionStatus.confirmed,
        ), categoryKey: 'cafes');
        final before = await ledgerSnapshot();
        final attemptsBefore = visualParityLocalReadEvents()['${key}CorrectionAttempt'] ?? 0;
        final closedBefore = visualParityLocalReadEvents()['${key}Closed'] ?? 0;
        await open(tester, key, language);
        final context = tester.element(find.byType(AppPrimaryButton));
        final l10n = AppL10n.of(context);
        final catalog = CategoryCatalog(await ProviderScope.containerOf(context)
            .read(categoryRepositoryProvider).getAll(), languageCode: language);
        final chosen = catalog.byKey('groceries')!;
        await tester.ensureVisible(find.widgetWithText(AppCategoryChip, chosen.name));
        await tester.tap(find.widgetWithText(AppCategoryChip, chosen.name));
        await tester.ensureVisible(find.text(l10n.ccScopeMerchant));
        await tester.tap(find.text(l10n.ccScopeMerchant));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(l10n.ccSave));
        await tester.tap(find.text(l10n.ccSave));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(visualParityLocalReadEvents()['${key}CorrectionAttempt'], attemptsBefore + 1);
        expect(find.text(l10n.ccTitle), findsOneWidget);
        expect(tester.widget<AppPrimaryButton>(find.byType(AppPrimaryButton)).onTap,
            key == 'changeCategorySaving' ? isNull : isNotNull);
        expect(find.text(l10n.ctsCategoryUpdateFailed),
            key == 'changeCategoryError' ? findsOneWidget : findsNothing);
        expect(find.textContaining('synthetic_category_repository_failure'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        expect(tester.takeException(), isNull);
        expect(await ledgerSnapshot(), before);
        // This is the actual public sheet's navigator; closing restores the
        // original parent scope with its normal transaction repository.
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        expect(find.text('Open fixture'), findsOneWidget);
        expect(visualParityLocalReadEvents()['${key}Closed'], closedBefore + 1);
        final parentContext = tester.element(find.byType(_Launch));
        expect(ProviderScope.containerOf(parentContext).read(transactionRepositoryProvider),
            isA<DriftTransactionRepository>());
        expect(await ledgerSnapshot(), before);
        await tester.pump(const Duration(seconds: 4));
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final language in ['ar', 'en']) {
    for (final (key, kind) in [
      ('syncStatusAllSynced', SyncStatusKind.allSynced),
      ('syncStatusSyncing', SyncStatusKind.syncing),
      ('syncStatusWaiting', SyncStatusKind.waiting),
      ('syncStatusConsentOff', SyncStatusKind.consentOff),
      ('syncStatusSignedOut', SyncStatusKind.signedOut),
      ('syncStatusFailed', SyncStatusKind.failed),
      ('syncStatusNeedsAttention', SyncStatusKind.needsAttention),
      ('syncStatusBreakdown', SyncStatusKind.failed),
    ]) {
      testWidgets('$key presents local viewmodel without recovery or ledger changes in $language', (tester) async {
        final before = await db.customSelect('SELECT * FROM transactions').get();
        final readsBefore = visualParityLocalReadEvents()['${key}PresentationRead'] ?? 0;
        await open(tester, key, language);
        final context = tester.element(find.byType(SyncStatusSheet));
        final l10n = AppL10n.of(context);
        final container = ProviderScope.containerOf(context);
        final status = container.read(syncStatusProvider).requireValue;
        expect(status.kind, kind);
        expect(find.text(syncStatusLabel(context, status)), findsOneWidget);
        expect(find.text(l10n.syncSheetTitle), findsOneWidget);
        expect(find.byKey(const Key('sync-retry-button')),
            status.canRetry ? findsOneWidget : findsNothing);
        if (kind == SyncStatusKind.consentOff || kind == SyncStatusKind.signedOut) {
          expect(find.text(l10n.syncSheetKeptOnDevice(status.count)), findsOneWidget);
        }
        if (key == 'syncStatusBreakdown') {
          expect(find.text(l10n.syncSheetWaitingConnection), findsOneWidget);
          expect(find.text(l10n.syncSheetWaitingServer), findsOneWidget);
          expect(find.text(l10n.syncSheetNeedsAttention), findsOneWidget);
          expect(find.text(l10n.syncSheetStayFailed(2)), findsOneWidget);
        }
        expect(visualParityLocalReadEvents()['${key}PresentationRead'], readsBefore + 1);
        expect(tester.takeException(), isNull);
        Navigator.of(context).pop();
        await tester.pumpAndSettle();
        expect(find.byType(SyncStatusSheet), findsNothing);
        expect((await db.customSelect('SELECT * FROM transactions').get()).map((r) => r.data).toList(),
            before.map((r) => r.data).toList());
      });
    }
    for (final key in ['localReadLoading', 'localReadError']) {
      testWidgets('$key shows recovery actions without reading or inventing balances in $language', (tester) async {
        await open(tester, key, language);
        final context = tester.element(find.byType(LocalReadShell));
        final l10n = AppL10n.of(context);
        expect(find.byKey(const Key('local_read_banner')), findsNothing);
        expect(find.text(l10n.sessionRecoveryTitle), findsOneWidget);
        expect(find.text(l10n.localReadReconnect), findsNothing);
        expect(find.byKey(const Key('local_read_reconnect')), findsOneWidget);
        expect(find.byKey(const Key('local_read_logout')), findsOneWidget);
        expect(find.text('Synthetic savings'), findsNothing);
        expect(find.text('Carrefour'), findsNothing);
        expect(find.text(l10n.localReadNoAccounts), findsNothing);
        expect(find.text(l10n.localReadNoTransactions), findsNothing);
        expect(find.text(l10n.localReadLoadError), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('synthetic logout failure uses real localized error toast and retains local view in $language', (tester) async {
      final before = visualParityLocalReadEvents();
      await open(tester, 'localReadLogoutError', language);
      final context = tester.element(find.byType(LocalReadShell));
      final l10n = AppL10n.of(context);
      await tester.tap(find.byKey(const Key('local_read_logout')));
      await tester.pumpAndSettle();
      final events = visualParityLocalReadEvents();
      expect(events['localReadLogoutFailurePresentationCallback'],
          (before['localReadLogoutFailurePresentationCallback'] ?? 0) + 1);
      expect(events['localReadLogoutPresentationCallback'],
          before['localReadLogoutPresentationCallback']);
      expect(find.byType(LocalReadShell), findsOneWidget);
      expect(find.text('Synthetic savings'), findsNothing);
      expect(find.text(l10n.localReadLogoutFailed), findsOneWidget);
      expect(find.byIcon(AppLucideIcons.alertCircle), findsOneWidget);
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
    });

    testWidgets('local-read presentation callbacks do not run security transitions in $language', (tester) async {
      final before = visualParityLocalReadEvents();
      await open(tester, 'localReadPresentation', language);
      expect(find.byType(LocalReadShell), findsOneWidget);
      expect(find.text('Synthetic savings'), findsNothing);
      expect(find.text('Carrefour'), findsNothing);
      await tester.tap(find.byKey(const Key('local_read_reconnect')));
      await tester.pumpAndSettle();
      expect(visualParityLocalReadEvents()['localReadReconnectPresentationCallback'],
          (before['localReadReconnectPresentationCallback'] ?? 0) + 1);
      await tester.tap(find.byKey(const Key('local_read_logout')));
      await tester.pumpAndSettle();
      expect(visualParityLocalReadEvents()['localReadLogoutPresentationCallback'],
          (before['localReadLogoutPresentationCallback'] ?? 0) + 1);
      expect(find.byType(LocalReadShell), findsOneWidget,
          reason: 'the fixture only records presentation callbacks');
      expect(tester.takeException(), isNull);
    });

    testWidgets('actual coach tour advances to Done without a once-only preference in $language', (tester) async {
      final before = visualParityLocalReadEvents()['coachMarksPresentationClosed'] ?? 0;
      await open(tester, 'coachMarks', language);
      final context = tester.element(find.byType(CoachMarkTourForTest));
      final l10n = AppL10n.of(context);
      final marks = dashboardCoachMarks(context);
      for (var index = 0; index < marks.length; index++) {
        expect(find.text(marks[index].title), findsOneWidget);
        await tester.tap(find.text(index == marks.length - 1
            ? l10n.coachMarkDone : l10n.coachMarkNext));
        await tester.pumpAndSettle();
      }
      expect(find.byType(CoachMarkTourForTest), findsNothing);
      expect(visualParityLocalReadEvents()['coachMarksPresentationClosed'], before + 1);
      expect(tester.takeException(), isNull);
    });
  }
}
