import 'report_surface.dart';
// Offline, in-memory visual QA entry points only. Never imported from lib/.
// These expose actual production widgets; they do not manufacture authentication,
// ConsentCapability, startup authority, durable denial, or a force-update gate.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/startup/bootstrap_runner.dart';
import 'package:money_companion/core/sync/sync_diagnostics_report.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/domain/repositories/transaction_repository.dart';
import 'package:money_companion/features/app/local_read_cleanup_notice.dart';
import 'package:money_companion/features/app/startup_loading_screen.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/features/onboarding/force_update_screen.dart';
import 'package:money_companion/features/onboarding/onboarding_account_step.dart';
import 'package:money_companion/features/onboarding/onboarding_consent_steps.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/features/bank_discovery/bank_discovery_confirmation_sheet.dart';
import 'package:money_companion/features/coupons/coupons_providers.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:money_companion/features/coupons/affiliate_click_gateway.dart';
import 'package:money_companion/features/coupons/coupon_widgets.dart';
import 'package:money_companion/features/coupons/savings_confirm_sheet.dart';
import 'package:money_companion/features/coupons/savings_math.dart';
import 'package:money_companion/features/coupons/savings_providers.dart';
import 'package:money_companion/features/coupons/savings_repository.dart';
import 'package:money_companion/features/coupons/savings_screen.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/backup/restore_payload_repair_view.dart';
import 'package:money_companion/core/backup/planning_restore_preflight.dart';
import 'package:money_companion/features/transactions/transactions_providers.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/transactions/transaction_details_screen.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/accounts/accounts_screen.dart';
import 'package:money_companion/features/subscriptions/subscriptions_providers.dart';
import 'package:money_companion/features/subscriptions/subscriptions_screen.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/domain/entities/card_entity.dart';
import 'package:money_companion/engine/parser/card_network.dart';
import 'package:money_companion/features/cards/cards_providers.dart';
import 'package:money_companion/features/goals/goals_screen.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/features/plans/plans_providers.dart';
import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/settings/delete_account_screen.dart';
import 'package:money_companion/features/settings/sync_diagnostics_screen.dart';

const visualParityExtendedSurfaceKeys = <String>[
  'consentManagement',
  'startupLoading',
  'startupUpdating',
  'startupError',
  'startupTimeout',
  'signoutIncompleteFailure',
  'signoutIncompleteSuccess',
  'forceUpdate',
  'forceUpdateFallback',
  'activityReviewed',
  'onboardingAccount',
  'onboardingConsent',
  'onboardingReadiness',
  'setupShortcutGuide',
  'bankDiscovery',
  'couponDetail',
  'couponExpired',
  'couponInvalidUrl',
  'savingsConfirm',
  'savingsConfirmComputable',
  'savingsConfirmPending',
  'savingsConfirmError',
  'savingsPopulated',
  'restorePayloadRepair',
  'reportPreview',
  'reportPreviewError',
  'goalLongTitle',
  'goalCompletion',
  'exactMoneyKwd',
  'exactMoneyLarge',
  'exactMoneyRemainingKwd',
  'exactMoneyRemainingLarge',
  'txExactKwd',
  'txExactLarge',
  'txExactJpy',
  'txAwaitingFx',
  'todayDailyBudget',
  'cardDeckFixture',
  'goalsExactKwd',
  'missingTransactionSheet',
  'missingGoalSheet',
  'missingPlanDetails',
  'planEmptyLinks',
  'deleteAccountIdle',
  'syncDiagnosticsError',
  'syncDiagnosticsLoading',
  'subscriptionsSuggestionsOnly',
  'settingsQuietHours',
];

final _events = <String, int>{};

/// Optional loopback GET evidence. Counters record fixture callbacks only, never
/// claim a real bootstrap retry, logout, grant, or remote operation succeeded.
Map<String, int> visualParityExtendedEvents() => Map.unmodifiable(_events);

void _record(String event) => _events.update(event, (n) => n + 1, ifAbsent: () => 1);

void _open(Future<Object?> future) {
  unawaited(future.then<void>((_) {}, onError: (Object error, StackTrace stack) {
    FlutterError.reportError(FlutterErrorDetails(
      exception: error, stack: stack, library: 'Qirsh extended visual fixture'));
  }));
}

Future<void> _requireMemory(WidgetRef ref) async {
  if (!kDebugMode || SupabaseConfig.isConfigured) {
    throw StateError('extended_visual_surfaces_require_offline_debug');
  }
  final rows = await ref.read(appDatabaseProvider)
      .customSelect('PRAGMA database_list').get();
  if (!rows.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('extended_visual_surfaces_require_memory_database');
  }
}

/// Called after the existing dispatcher guard. Guarded again because the helper
/// can be exercised independently in its own component tests.
Future<bool> openVisualParityExtendedSurface(
    BuildContext context, WidgetRef ref, String key) async {
  if (!visualParityExtendedSurfaceKeys.contains(key)) return false;
  await _requireMemory(ref);
  if (!context.mounted) return false;
  final navigator = Navigator.of(context);
  switch (key) {
    case 'exactMoneyKwd':
    case 'exactMoneyLarge':
    case 'exactMoneyRemainingKwd':
    case 'exactMoneyRemainingLarge':
      // This fixture requires an empty disposable ledger on first use. Null-
      // account transactions must precede the first account: saveTransaction
      // correctly assigns a default when any account already exists.
      final remainingLeaves = key.startsWith('exactMoneyRemaining');
      final small = key.endsWith('Kwd');
      final prefix = 'qa-exact-money-${remainingLeaves ? 'remaining-' : ''}${small ? 'kwd' : 'large'}';
      final minor = small ? 12345 : 9007199254740993;
      final db = ref.read(appDatabaseProvider);
      final accounts = ref.read(accountRepositoryProvider);
      final accountId = '$prefix-account';
      final existing = await accounts.getById(accountId);
      for (final entry in {
        'accounts': 'id', 'transactions': 'id', 'plans': 'id',
        'subscriptions': 'id', 'bill_payments': 'id',
        'plan_transaction_links': 'plan_id',
      }.entries) {
        final rows = await db.customSelect(
            "SELECT COUNT(*) AS n FROM ${entry.key} WHERE ${entry.value} NOT LIKE '$prefix%'").getSingle();
        if (rows.read<int>('n') != 0) {
          throw StateError('exact_money_fixture_requires_empty_ledger');
        }
        if (existing == null && (await db.customSelect(
            'SELECT COUNT(*) AS n FROM ${entry.key}').getSingle()).read<int>('n') != 0) {
          throw StateError('exact_money_fixture_requires_empty_ledger');
        }
      }
      if (existing == null) {
        final now = DateTime.now().toUtc();
        Money amount(int delta) => Money(minor + delta, 'KWD');
        final transactions = ref.read(transactionRepositoryProvider);
        for (final spec in [
          ('picker', 5, null, null), ('unassigned', 6, null, '8888'),
          ('linked', 3, accountId, '7777'),
          if (remainingLeaves) ('suggested', 13, accountId, null),
        ]) {
          if (spec.$1 == 'linked') {
            await accounts.create(AccountEntity(id: accountId, name: 'QA exact KWD account',
              currency: 'KWD', type: AccountType.bank, isDefault: true, sortOrder: 0,
              initialBalanceMoney: Money.zero('KWD'), currentBalanceMoney: Money.zero('KWD'),
              createdAt: now, updatedAt: now));
          }
          await transactions.saveTransaction(transaction: TransactionEntity(
            id: '$prefix-${spec.$1}', amountMoney: amount(spec.$2), currency: 'KWD',
            type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
            accountId: spec.$3, cardLast4: spec.$4,
            occurredAt: spec.$1 == 'suggested' ? now.subtract(const Duration(days: 3)) : now,
            rawMerchant: spec.$1 == 'suggested' ? 'QA exact subscription' : 'QA exact ${spec.$1}',
            rawMessage: 'Synthetic exact-money visual QA',
            parseConfidence: 1, status: TransactionStatus.confirmed,
            createdAt: now, updatedAt: now,
          ), categoryKey: 'groceries');
        }
        if (remainingLeaves) {
          // Real local recurrence query: three equal own-currency payments in
          // distinct past months, outside the active Plan's date window.
          for (var month = 1; month <= 3; month++) {
            await transactions.saveTransaction(transaction: TransactionEntity(
              id: '$prefix-recurring-$month', amountMoney: amount(18), currency: 'KWD',
              type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
              accountId: accountId, occurredAt: DateTime.utc(now.year, now.month - month, 15),
              rawMerchant: 'QA exact recurring', rawMessage: 'Synthetic recurrence visual QA',
              parseConfidence: 1, status: TransactionStatus.confirmed,
              createdAt: now, updatedAt: now,
            ), categoryKey: 'groceries');
          }
        }
        final plans = ref.read(planRepositoryProvider);
        for (final closed in [false, true]) {
          await plans.save(PlanEntity(id: '$prefix-plan-${closed ? 'closed' : 'active'}',
            name: closed ? 'QA exact closed plan' : 'QA exact active plan',
            budgetAmountMoney: amount(closed ? 9 : 4), currency: 'KWD',
            startDate: now.subtract(Duration(days: closed ? 30 : 1)),
            endDate: closed ? now.subtract(const Duration(days: 15)) : now.add(const Duration(days: 14)),
            accountIds: [accountId], cardLast4s: const [],
            status: closed ? PlanStatus.closed : PlanStatus.active, createdAt: now));
        }
        await plans.linkTransactionToPlan(planId: '$prefix-plan-active', transactionId: '$prefix-linked');
        final bills = ref.read(billRepositoryProvider);
        await bills.save(BillEntity(id: '$prefix-sub', name: 'QA exact subscription',
          amountMoney: amount(0),
          manualPaidMoney: remainingLeaves ? Money(minor * 2 + 34, 'KWD') : amount(1), currency: 'KWD',
          type: BillType.subscription, frequency: BillFrequency.monthly,
          accountId: accountId, nextDueDate: now.add(const Duration(days: 10)),
          reminderOn: false, isConfirmed: true, createdAt: now));
        await bills.save(BillEntity(id: '$prefix-inst', name: 'QA exact installment',
          amountMoney: amount(2), currency: 'KWD', type: BillType.installment,
          manualPaidMoney: remainingLeaves ? amount(20) : null,
          totalPurchaseMoney: remainingLeaves ? amount(21) : null,
          frequency: BillFrequency.monthly, totalInstallments: 3, paidCount: 1,
          accountId: accountId, nextDueDate: now.add(const Duration(days: 11)),
          reminderOn: false, isConfirmed: true, createdAt: now));
        await bills.recordPayment(BillPaymentEntity(id: '$prefix-payment', billId: '$prefix-sub',
          amountMoney: amount(7), currency: 'KWD', periodStart: now,
          periodEnd: now.add(const Duration(days: 30)), paidAt: now));
        _record('exactMoneyMemoryLedgerSeeded');
      }
      // Never overwrite an existing seeded entity on repeated opens.
      final settingsRepo = ref.read(userSettingsRepositoryProvider);
      final settings = await settingsRepo.getSettings();
      if (settings.currency != 'KWD') {
        await settingsRepo.saveSettings(settings.copyWith(currency: 'KWD'));
      }
      ref.read(activeAccountIdProvider.notifier).state = accountId;
      ref.invalidate(accountsProvider);
      ref.invalidate(accountCardGroupsProvider);
      ref.invalidate(cardSummariesProvider);
      ref.invalidate(baseCurrencyProvider);
      ref.invalidate(billsScopeAccountProvider);
      ref.invalidate(savedBillsProvider);
      ref.invalidate(subscriptionsProvider);
      ref.invalidate(billPaymentsProvider('$prefix-sub'));
      ref.invalidate(plansWithSpentProvider);
      ref.invalidate(planProgressProvider('$prefix-plan-active'));
      ref.invalidate(planTransactionsProvider('$prefix-plan-active'));
      if (!context.mounted) return false;
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => const AccountsScreen())));
    case 'goalCompletion':
      // Only the real local milestone-notification preference is changed. The
      // user/test must contribute through the public production form; this
      // fixture never alters goal amounts, status or contribution use cases.
      final goal = await ref.read(goalRepositoryProvider).getById('p-goal-0');
      if (goal == null || goal.currency != 'EGP') {
        throw StateError('goal_completion_requires_normal_egp_goal');
      }
      final settingsRepo = ref.read(userSettingsRepositoryProvider);
      final settings = await settingsRepo.getSettings();
      final original = jsonDecode(settings.notificationsJson) as Map<String, dynamic>;
      final preferences = NotificationPreferences.fromJson(original);
      await settingsRepo.saveSettings(settings.copyWith(notificationsJson:
          jsonEncode({...original, ...preferences.copyWith(goalMilestone: false).toJson()})));
      ref.invalidate(notificationPreferencesProvider);
      ref.invalidate(userSettingsProvider);
      if (!context.mounted) return false;
      _record('goalCompletionMemoryMilestoneDisabled');
      _open(GoalDetailsScreen.showSheet(context, 'p-goal-0'));
    case 'settingsQuietHours':
      // Seed only this disposable memory preference; never call notification
      // scheduling/permissions. The actual Settings control opens its own sheet.
      final settingsRepo = ref.read(userSettingsRepositoryProvider);
      final settings = await settingsRepo.getSettings();
      await settingsRepo.saveSettings(settings.copyWith(notificationsJson:
          jsonEncode(const NotificationPreferences(quietHoursEnabled: true).toJson())));
      ref.invalidate(notificationPreferencesProvider);
      ref.invalidate(userSettingsProvider);
      if (!context.mounted) return false;
      _record('quietHoursMemoryPreferenceSeeded');
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const SettingsScreen(
            page: SettingsPage.alerts, showBackButton: true))));
    case 'deleteAccountIdle':
      // The typed provider cannot return null. Its blocked construction is
      // caught by the production screen's existing _flow() guard, yielding
      // null before resume/begin/auth/service work. Idle presentation only.
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ProviderScope(
        overrides: [immediateDeletionFlowProvider.overrideWith((ref) {
          _record('deleteAccountIdleFlowBlocked');
          throw StateError('visual_deletion_flow_disabled');
        })],
        child: const DeleteAccountScreen(),
      ))));
    case 'syncDiagnosticsLoading':
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ProviderScope(
        overrides: [syncDiagnosticsProvider.overrideWith((ref) {
          _record('syncDiagnosticsReadLoading');
          return Completer<SyncDiagnosticsReport>().future;
        })],
        child: const SyncDiagnosticsScreen(),
      ))));
    case 'subscriptionsSuggestionsOnly':
      const prefix = 'qa-subscriptions-suggestions';
      const accountId = '$prefix-account';
      final db = ref.read(appDatabaseProvider);
      final accounts = ref.read(accountRepositoryProvider);
      final transactions = ref.read(transactionRepositoryProvider);
      final existingAccount = await accounts.getById(accountId);
      final expectedTxIds = {for (var month = 1; month <= 3; month++) '$prefix-$month'};
      for (final table in ['subscriptions', 'bill_payments', 'plans',
          'plan_transaction_links', 'goals', 'budgets']) {
        if ((await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
            .read<int>('n') != 0) {
          throw StateError('suggestions_only_fixture_requires_empty_ledger');
        }
      }
      final accountRows = await accounts.getAll();
      final txRows = await transactions.getAll();
      if (accountRows.any((account) => account.id != accountId) ||
          txRows.any((transaction) => !expectedTxIds.contains(transaction.id)) ||
          (existingAccount == null && txRows.isNotEmpty)) {
        throw StateError('suggestions_only_fixture_requires_empty_ledger');
      }
      if (existingAccount != null &&
          (existingAccount.currency != 'KWD' || txRows.length != 3 ||
          txRows.any((transaction) => transaction.accountId != accountId ||
            transaction.amountMoney != Money(12345, 'KWD') ||
            transaction.rawMerchant != 'QA suggestions only' ||
            transaction.type != TransactionTypeEntity.payment ||
            transaction.status != TransactionStatus.confirmed))) {
        throw StateError('suggestions_only_fixture_existing_rows_mismatch');
      }
      if (existingAccount == null) {
        final now = DateTime.now().toUtc();
        await accounts.create(AccountEntity(id: accountId,
          name: 'QA suggestions KWD account', currency: 'KWD',
          type: AccountType.bank, isDefault: true, sortOrder: 0,
          initialBalanceMoney: Money.zero('KWD'), currentBalanceMoney: Money.zero('KWD'),
          createdAt: now, updatedAt: now));
        for (var month = 1; month <= 3; month++) {
          await transactions.saveTransaction(transaction: TransactionEntity(
            id: '$prefix-$month', amountMoney: Money(12345, 'KWD'), currency: 'KWD',
            type: TransactionTypeEntity.payment, source: TransactionSourceEntity.card,
            accountId: accountId, occurredAt: DateTime.utc(now.year, now.month - month, 15),
            rawMerchant: 'QA suggestions only', rawMessage: 'Synthetic recurrence visual QA',
            parseConfidence: 1, status: TransactionStatus.confirmed,
            createdAt: now, updatedAt: now,
          ), categoryKey: 'groceries');
        }
      }
      ref.invalidate(accountsProvider);
      ref.invalidate(billsScopeAccountProvider);
      ref.invalidate(savedBillsProvider);
      ref.invalidate(subscriptionsProvider);
      if (!context.mounted) return false;
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const SubscriptionsScreen(),
      )));
    case 'syncDiagnosticsError':
      // Replace only the read outcome. No diagnostics collection, Run Sync,
      // clipboard action or successful synchronization is simulated.
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ProviderScope(
        overrides: [syncDiagnosticsProvider.overrideWith((ref) async {
          _record('syncDiagnosticsReadError');
          throw StateError('synthetic_visual_diagnostics_read_failure');
        })],
        child: const SyncDiagnosticsScreen(),
      ))));
    case 'missingTransactionSheet':
      const id = 'qa-missing-transaction-visual';
      if (await ref.read(transactionRepositoryProvider).getById(id) != null) {
        throw StateError('missing_transaction_fixture_id_exists');
      }
      if (!context.mounted) return false;
      _open(TransactionDetailsScreen.showSheet(context, id));
    case 'missingGoalSheet':
      const id = 'qa-missing-goal-visual';
      if (await ref.read(goalRepositoryProvider).getById(id) != null) {
        throw StateError('missing_goal_fixture_id_exists');
      }
      if (!context.mounted) return false;
      _open(GoalDetailsScreen.showSheet(context, id));
    case 'planEmptyLinks':
      // Parent/list/detail/link picker all read actual disposable data. This
      // fixture is admitted only with an empty ledger, not an artificial
      // successful provider read. It does not add a search control to Plans.
      final db = ref.read(appDatabaseProvider);
      final ledger = await ref.read(transactionRepositoryProvider)
          .getTransactionPage(limit: 1);
      final count = (await db.customSelect(
          'SELECT COUNT(*) AS n FROM transactions').getSingle()).read<int>('n');
      if (ledger.isNotEmpty || count != 0) {
        throw StateError('plan_empty_links_requires_empty_ledger');
      }
      final accounts = ref.read(accountRepositoryProvider);
      final existingAccounts = await accounts.getAll();
      var account = existingAccounts.where((a) => a.currency == 'EGP').firstOrNull;
      final now = DateTime.now().toUtc();
      final day = DateTime(now.year, now.month, now.day);
      account ??= await accounts.create(AccountEntity(
        id: 'qa-plan-empty-links-account', name: 'Synthetic EGP', currency: 'EGP',
        type: AccountType.bank, isDefault: existingAccounts.isEmpty, sortOrder: 99,
        createdAt: now, updatedAt: now, initialBalanceMoney: Money.zero('EGP'),
        currentBalanceMoney: Money.zero('EGP'),
      ));
      const planId = 'qa-plan-empty-links';
      final plans = ref.read(planRepositoryProvider);
      if (await plans.getById(planId) == null) {
        await plans.save(PlanEntity(
          id: planId, name: 'Empty-link fixture plan',
          budgetAmountMoney: Money(100000, 'EGP'), currency: 'EGP',
          startDate: day.subtract(const Duration(days: 1)),
          endDate: day.add(const Duration(days: 14)), accountIds: [account.id],
          cardLast4s: const [], status: PlanStatus.active, createdAt: now,
          icon: 'plane',
        ));
      }
      ref.invalidate(accountsProvider);
      ref.invalidate(plansWithSpentProvider);
      ref.invalidate(planProgressProvider(planId));
      ref.invalidate(planTransactionsProvider(planId));
      if (!context.mounted) return false;
      _record('planEmptyLinksMemorySeeded');
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const PlansScreen())));
    case 'missingPlanDetails':
      // The list and saved plan remain real memory data. Only the selected
      // detail read returns null; tap the actual active plan to reach its
      // private production sheet. No cutover or session authority is replaced.
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ProviderScope(
        overrides: [planProgressProvider('p-plan-active').overrideWith((ref) async => null)],
        child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const PlansScreen())),
      ))));
    case 'cardDeckFixture':
    case 'goalsExactKwd':
      final accounts = ref.read(accountRepositoryProvider);
      const kwdAccount = 'qa-exact-KWD';
      final now = DateTime.now().toUtc();
      if (await accounts.getById(kwdAccount) == null) {
        await accounts.create(AccountEntity(id: kwdAccount, name: 'Synthetic KWD',
          currency: 'KWD', type: AccountType.bank, isDefault: false, sortOrder: 99,
          createdAt: now, updatedAt: now, initialBalanceMoney: Money.zero('KWD'),
          currentBalanceMoney: Money.zero('KWD')));
      }
      if (key == 'cardDeckFixture') {
        final cards = ref.read(cardRepositoryProvider);
        for (final spec in <(String, String?, String, CardNetwork, String, String)>[
          ('qa-deck-gold', 'p-acc-1', '8821', CardNetwork.visa, 'sunset', '#F59E0B'),
          ('qa-deck-mint', null, '6670', CardNetwork.mastercard, 'emerald', '#10B981'),
          ('qa-deck-kwd', kwdAccount, '1234', CardNetwork.visa, 'navy', '#3B82F6'),
        ]) {
          if (await cards.getById(spec.$1) == null) {
            await cards.create(CardEntity(id: spec.$1, accountId: spec.$2, last4: spec.$3,
              network: spec.$4, source: CardSource.manual, createdAt: now, updatedAt: now,
              colorTheme: spec.$5, accentHex: spec.$6, nickname: 'Synthetic ${spec.$3}'));
          }
        }
        ref.invalidate(accountsProvider);
        ref.invalidate(allCardsProvider);
        ref.invalidate(accountCardGroupsProvider);
        _record('syntheticDeckCardsSeeded');
      } else {
        final goals = ref.read(goalRepositoryProvider);
        final original = await goals.getById('p-goal-0');
        if (original == null) return false;
        await goals.save(original.copyWith(id: 'qa-goal-exact-KWD', name: 'Synthetic KWD goal',
          currency: 'KWD', accountId: kwdAccount, targetMoney: Money(50000, 'KWD'),
          savedMoney: Money(12345, 'KWD'), lastNotifiedSavedMoney: Money.zero('KWD')));
        ref.read(activeAccountIdProvider.notifier).state = kwdAccount;
        ref.invalidate(goalsListProvider);
        await ref.read(baseCurrencyProvider.future);
        if (!context.mounted) return false;
        _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => const GoalsScreen())));
      }
    case 'todayDailyBudget':
      final now = DateTime.now();
      await ref.read(budgetRepositoryProvider).save(BudgetEntity(
        id: 'qa-today-daily-budget', categoryId: BudgetEntity.allExpensesCategoryId,
        currency: 'EGP', amountMoney: Money(80000, 'EGP'),
        lastNotifiedSpentMoney: Money.zero('EGP'), period: BudgetPeriod.daily,
        startDate: DateTime(now.year, now.month, now.day).toUtc(),
        isActive: true, lastNotifiedPeriodStart: DateTime(now.year, now.month, now.day).toUtc(),
        accountId: 'p-acc-1'));
      ref.invalidate(dashboardDataProvider);
      _record('syntheticDailyBudgetSaved');
    case 'txExactKwd':
    case 'txExactLarge':
    case 'txExactJpy':
    case 'txAwaitingFx':
      final repository = ref.read(transactionRepositoryProvider);
      final original = await repository.getById('p-tx-0-0');
      if (original == null) return false;
      final currency = key == 'txExactJpy' ? 'JPY' : key == 'txAwaitingFx' ? 'EGP' : 'KWD';
      final minor = key == 'txExactLarge' ? 9007199254740993 : key == 'txExactJpy' ? 123 : key == 'txAwaitingFx' ? 0 : 12345;
      final accountId = key == 'txAwaitingFx' ? 'p-acc-1' : 'qa-exact-$currency';
      if (key != 'txAwaitingFx') {
        final accounts = ref.read(accountRepositoryProvider);
        if (await accounts.getById(accountId) == null) {
          final now = DateTime.now().toUtc();
          await accounts.create(AccountEntity(id: accountId, name: 'Synthetic $currency',
            currency: currency, type: AccountType.bank, isDefault: false,
            sortOrder: 99, createdAt: now, updatedAt: now,
            initialBalanceMoney: Money.zero(currency), currentBalanceMoney: Money.zero(currency)));
        }
      }
      final fixture = original.copyWith(id: 'qa-$key', accountId: accountId,
        amountMoney: Money(minor, currency), currency: currency,
        foreignMoney: key == 'txAwaitingFx' ? Money(12345, 'KWD') : null,
        foreignCurrency: key == 'txAwaitingFx' ? 'KWD' : null,
        balanceAfterMoney: key == 'txAwaitingFx' ? null : Money(minor + 5, currency));
      await repository.saveTransaction(transaction: fixture, categoryKey: 'cafes');
      if (!context.mounted) return false;
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) =>
        TransactionDetailsScreen(transactionId: fixture.id))));
    case 'goalLongTitle':
      final goals = ref.read(goalRepositoryProvider);
      final original = await goals.getById('p-goal-0');
      if (original == null || !context.mounted) return false;
      final isArabic = Localizations.localeOf(context).languageCode == 'ar';
      final fixture = original.copyWith(id: 'p-goal-long-title', name: isArabic
          ? 'ادخار لرحلة عائلية طويلة إلى الساحل الشمالي في العطلة الصيفية القادمة'
          : 'Saving for a long family trip to the north coast during the next summer holiday');
      await goals.save(fixture);
      if (!context.mounted) return false;
      _open(GoalDetailsScreen.showSheet(context, fixture.id));
    case 'consentManagement':
      // A management Cancel renders and dismisses the actual disclosure without
      // writing a choice. Accept has no lifecycle capability and cannot grant.
      if (ref.read(consentLocalWorkProvider)() != null) {
        throw StateError('visual_consent_fixture_must_have_no_capability');
      }
      _open(showSmartAnalysisConsentSheet(context, ref, management: true)
          .then((_) => _record('consentManagementClosed')));
    case 'startupLoading':
    case 'startupUpdating':
    case 'startupError':
    case 'startupTimeout':
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => StartupLoadingScreen(
          updatingData: key == 'startupUpdating',
          error: key == 'startupTimeout'
              ? const BootstrapTimeoutException('visual_fixture')
              : key == 'startupError' ? StateError('visual_fixture_error') : null,
          lastStep: key == 'startupError' || key == 'startupTimeout'
              ? 'visual_fixture' : null,
          onRetry: () => _record('startupRetryCallback'),
        ),
      )));
    case 'signoutIncompleteFailure':
    case 'signoutIncompleteSuccess':
      _open(showSignOutIncompleteNotice(navigator, context.l10n, retry: () async {
        _record('noticeRetryCallback');
        // Keep the actual busy UI visible long enough for a real screenshot.
        // Only this presentation callback is simulated; no session method runs.
        await Future<void>.delayed(const Duration(seconds: 2));
        return key == 'signoutIncompleteSuccess';
      }));
    case 'forceUpdate':
    case 'forceUpdateFallback':
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => key == 'forceUpdateFallback'
            ? const ForceUpdateScreen()
            : ProviderScope(overrides: [
                activeAnnouncementsProvider.overrideWith((ref) async => [
                  _forceUpdateContent(),
                ]),
              ], child: const ForceUpdateScreen()),
      )));
      // This pushes a component, not the real AppShell force-update gate.
      // QA must not tap its external App Store CTA.
    case 'onboardingAccount':
    case 'onboardingConsent':
    case 'onboardingReadiness':
      // Independently inspect the public production step widgets. This is not
      // a completed wizard transition or a substitute for consent authority.
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => Scaffold(body: SafeArea(child: switch (key) {
          'onboardingAccount' => OnboardingAccountStep(currency: 'EGP',
            onDark: false, onDone: () => _record('accountStepContinueCallback')),
          'onboardingConsent' => OnboardingConsentStep(
            kind: OnboardingConsentKind.cloud, onDark: false,
            onDone: (_) => _record('consentStepDoneCallback')),
          _ => OnboardingReadinessStep(onDark: false,
            onDone: () => _record('readinessContinueCallback')),
        })),
      )));
    case 'setupShortcutGuide':
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const OnboardingSetupScreen(
          entry: OnboardingSetupEntry.captureGuide),
      )));
    case 'bankDiscovery':
      if (ref.read(senderBankMappingSyncServiceProvider) != null) {
        throw StateError('visual_sender_fixture_must_have_no_remote_sync');
      }
      final mapping = await ref.read(senderBankMappingRepositoryProvider)
          .saveSuggestion(const SenderBankMappingDraft(
            senderId: 'QA-BANK', suggestedBankName: 'Demo Bank',
            suggestedCountry: 'EG', confidence: .87,
            reason: 'Synthetic visual QA suggestion',
          ));
      if (!context.mounted) return false;
      _open(showBankDiscoveryConfirmationSheet(context, mapping));
    case 'couponExpired':
    case 'couponInvalidUrl':
      // Reach only the public widget's actual eligibility/URL denial branches.
      // No cached catalog mutation, view analytics, permit or external launch.
      final expired = key == 'couponExpired';
      final offer = CouponOffer(
        id: expired ? 'qa-coupon-expired' : 'qa-coupon-invalid-url',
        slug: expired ? 'qa-expired' : 'qa-invalid-url',
        partnerName: 'Qirsh QA',
        titleAr: 'عرض تجريبي غير حقيقي',
        titleEn: 'Synthetic offer only',
        descriptionAr: 'بيانات محلية لاختبار رسالة الخطأ فقط.',
        descriptionEn: 'Local fixture for the actual failure notice only.',
        redemptionType: expired ? CouponRedemptionType.code : CouponRedemptionType.link,
        code: expired ? 'QA-EXPIRED' : null,
        partnerUrl: expired ? null : 'http://example.invalid/never-launch',
        category: const CouponCategory(key: 'qa', labelAr: 'تجريبي', labelEn: 'Demo'),
        validFrom: DateTime.utc(2020),
        validUntil: DateTime.utc(expired ? 2021 : 2040),
      );
      _open(showModalBottomSheet<void>(context: context,
        isScrollControlled: true, builder: (_) => ProviderScope(
          overrides: [
            affiliateTrackingEnabledProvider.overrideWithValue(false),
            // Scope the actual gateway too; its provider has no declared scoped
            // dependency and could otherwise retain an ancestor tracking read.
            affiliateClickGatewayProvider.overrideWithValue(AffiliateClickGateway(
              database: ref.read(appDatabaseProvider),
              trackingEnabled: () => false,
              prepareClick: (_) async {
                _record('couponGuardUnexpectedPreparation');
                throw StateError('coupon_guard_must_not_prepare');
              },
            )),
          ],
          child: CouponDetailsSheet(offer: offer))));
    case 'savingsPopulated':
      final db = ref.read(appDatabaseProvider);
      final repository = ref.read(savingsRepositoryProvider);
      const seed = [
        ('egp-verified', 12345, 'EGP', SavingsEvidence.conversionVerified),
        ('egp-estimated', 3456, 'EGP', SavingsEvidence.conversionEstimated),
        ('egp-user', 5000, 'EGP', SavingsEvidence.userConfirmed),
        ('kwd-verified', 5001, 'KWD', SavingsEvidence.conversionVerified),
        ('kwd-user', 12345, 'KWD', SavingsEvidence.userConfirmed),
        ('jpy-estimated', 12345, 'JPY', SavingsEvidence.conversionEstimated),
      ];
      final rows = await db.customSelect('SELECT * FROM local_offer_savings').get();
      final expectedIds = seed.map((spec) => 'qa-savings-populated-${spec.$1}').toSet();
      if (rows.any((row) => !expectedIds.contains(row.read<String>('coupon_id'))) ||
          rows.map((row) => row.read<String>('coupon_id')).toSet().length != rows.length) {
        throw StateError('savings_fixture_requires_empty_or_own_ledger');
      }
      // Validate every existing fixture row before any remaining seed writes.
      for (final row in rows) {
        final spec = seed.firstWhere((spec) =>
          'qa-savings-populated-${spec.$1}' == row.read<String>('coupon_id'));
        if (row.read<int>('amount_minor') != spec.$2 ||
            row.read<String>('currency') != spec.$3 ||
            row.read<String>('evidence_kind') != spec.$4.name ||
            row.read<String>('state') != 'active') {
          throw StateError('savings_fixture_existing_row_mismatch');
        }
      }
      for (final spec in seed) {
        final couponId = 'qa-savings-populated-${spec.$1}';
        final existing = rows.where((row) => row.read<String>('coupon_id') == couponId).toList();
        if (existing.isNotEmpty) {
          continue;
        }
        await repository.record(SavingsOutcome.saved(amountMinor: spec.$2,
          currency: spec.$3, evidence: spec.$4), couponId: couponId,
          occurredAt: DateTime.utc(2026, 1, 1));
        _record('savingsSyntheticLedgerRowSeeded');
      }
      ref.invalidate(savingsTotalsProvider);
      ref.invalidate(savingsHistoryProvider);
      if (!context.mounted) return false;
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const SavingsScreen(),
      )));
    case 'savingsConfirmComputable':
    case 'savingsConfirmPending':
    case 'savingsConfirmError':
      final db = ref.read(appDatabaseProvider);
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) => ProviderScope(
        overrides: [
          if (key != 'savingsConfirmComputable') ...[
            savingsRepositoryProvider.overrideWithValue(
              _VisualSavingsWriteOutcome(db, pending: key == 'savingsConfirmPending')),
            // Preserve actual local reads inside the scoped repository. These
            // providers do not declare scoped dependencies in production.
            savingsTotalsProvider.overrideWith((ref) =>
              ref.watch(savingsRepositoryProvider).totals()),
            savingsHistoryProvider.overrideWith((ref) =>
              ref.watch(savingsRepositoryProvider).history()),
          ],
        ],
        // The public bottom sheet uses its own WidgetRef. Keep its Navigator
        // overlay inside this scope so it cannot resolve the ancestor writer.
        child: Navigator(onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const _SavingsConfirmationPreview())),
      ))));
    case 'couponDetail':
    case 'savingsConfirm':
      final offers = await ref.read(cachedCouponsProvider.future);
      final offer = offers.where((item) => item.id == 'p-coupon-talabat').firstOrNull;
      if (offer == null || !context.mounted) return false;
      if (key == 'couponDetail') {
        // Render the real public component without recording a view or
        // launching the partner URL; copy/savings actions retain their guards.
        _open(showModalBottomSheet<void>(context: context,
          isScrollControlled: true, builder: (_) => CouponDetailsSheet(offer: offer)));
      } else {
        _open(showSavingsConfirmSheet(context, ref, offer));
      }
    case 'restorePayloadRepair':
      _open(navigator.push<void>(MaterialPageRoute<void>(builder: (_) =>
        RestorePayloadRepairView(rows: const [
          RestorePlanningRow(id: 'qa-payload-budget', isGoal: false, legacyAmount: 500),
          RestorePlanningRow(id: 'qa-payload-goal', isGoal: true, legacyAmount: 2500),
        ], onConfirm: (_) => _record('payloadRepairPresentationCallback'),
          onCancel: () { _record('payloadRepairCancelCallback'); navigator.pop(); }),
      )));
    case 'reportPreview':
    case 'reportPreviewError':
      return openVisualParityReportPreview(context, ref,
          invalidPreview: key == 'reportPreviewError');
    case 'activityReviewed':
      // Use the real repository operation on the asserted memory fixture, not
      // a static "all reviewed" widget or a fabricated status provider.
      final repository = ref.read(transactionRepositoryProvider);
      final pending = await repository.getTransactionPage(
        limit: 501, filter: const TransactionPageFilter(pendingOnly: true));
      if (pending.length > 500) {
        throw StateError('visual_review_fixture_exceeds_bounded_limit');
      }
      for (final transaction in pending) {
        await repository.confirm(transaction.id);
      }
      if (!context.mounted) return false;
      ref.read(transactionsPageTabProvider.notifier).state = 0;
      ref.read(transactionCategoryFilterProvider.notifier).state = null;
      ref.read(transactionSearchQueryProvider.notifier).state = '';
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
      refreshTransactions(ref);
      _events['syntheticTransactionsConfirmed'] = pending.length;
      _open(navigator.push<void>(MaterialPageRoute<void>(
        builder: (_) => const TransactionsScreen(),
      )));
      // The real pending-only empty state remains scoped to the current
      // account, period and filters; it does not claim the full ledger is clear.
  }
  return true;
}

/// Only the record admission is controlled for a pending/failing presentation.
/// Reads stay on the real guarded memory database; neither branch writes or
/// fabricates a successful ledger record.
class _VisualSavingsWriteOutcome extends SavingsRepository {
  _VisualSavingsWriteOutcome(AppDatabase db, {required this.pending}) : super(db);
  final bool pending;

  @override
  Future<String?> record(SavingsOutcome outcome, {required String couponId,
      String? merchantId, String? clickId, DateTime? occurredAt}) async {
    _record(pending ? 'savingsRecordPendingAdmission' : 'savingsRecordErrorAdmission');
    if (pending) return Completer<String?>().future;
    throw StateError('synthetic_visual_savings_record_failure');
  }
}

/// Calls the existing public sheet from inside its scoped WidgetRef. Its
/// presentation-only parent is the actual SavingsScreen, not a fake balance.
class _SavingsConfirmationPreview extends ConsumerStatefulWidget {
  const _SavingsConfirmationPreview();
  @override
  ConsumerState<_SavingsConfirmationPreview> createState() => _SavingsConfirmationPreviewState();
}

class _SavingsConfirmationPreviewState extends ConsumerState<_SavingsConfirmationPreview> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await showSavingsConfirmSheet(context, ref, CouponOffer(
        id: 'qa-computable-savings', slug: 'qa-computable-savings',
        partnerName: 'Local QA', titleAr: 'عرض اختبار', titleEn: 'Test offer',
        descriptionAr: 'اختبار محلي', descriptionEn: 'Local test',
        redemptionType: CouponRedemptionType.code,
        category: const CouponCategory(key: 'qa', labelAr: 'اختبار'),
        validFrom: DateTime.utc(2020), benefitType: 'percent',
        discountBps: 1000, benefitCurrency: 'KWD',
      ));
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  Widget build(BuildContext context) => const SavingsScreen();
}

RemoteAnnouncement _forceUpdateContent() {
  final now = DateTime.now().toUtc();
  return RemoteAnnouncement(
    id: 'visual-force-update-content',
    titleAr: 'تحديث متاح للاختبار', titleEn: 'A test update is available',
    bodyAr: 'رسالة محلية تجريبية لمراجعة مظهر شاشة التحديث.',
    bodyEn: 'A local demo notice for reviewing the update screen.',
    severity: 'force_update', minAppVersion: null, maxAppVersion: null,
    actionLabelAr: 'عرض التحديث', actionLabelEn: 'View update',
    actionUrl: 'https://apps.apple.com/app/mali/id0000000000',
    validFrom: now.subtract(const Duration(days: 1)), validUntil: null,
    isDismissible: false, priority: 100, isDismissed: false,
    dismissedAt: null, syncedAt: now,
  );
}
