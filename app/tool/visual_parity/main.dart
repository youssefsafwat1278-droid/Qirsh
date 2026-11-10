import 'report_surface.dart';
import 'package:money_companion/features/dashboard/home_hero_period_controller.dart';
// SIMULATOR PREVIEW ONLY — separate tool entry point, never imported by lib/. Runs the REAL screens over an in-memory, unencrypted demo database
// seeded through the app's own repositories, so every screen can be inspected on
// the Simulator without a sign-in. No Supabase config is passed, so nothing here
// can reach a backend. The shell below stands in for AppShell (which is bound to
// the session/sync machinery); every other route is the app's own GoRouter route.
//
// Floating pill (bottom-left): language AR/EN and data state.
// Switch the Simulator's appearance for dark mode.
import 'package:money_companion/features/consent/cloud_resume_banner.dart';
import 'package:money_companion/features/onboarding/story_screen.dart';
import 'extra_surfaces.dart';
import 'extended_surfaces.dart';
import 'local_read_surfaces.dart';
import 'form_outcome_surfaces.dart';
import 'paste_outcome_surfaces.dart';
import 'deletion_status_surfaces.dart';
import 'registration_state_surfaces.dart';
import 'settings_preference_surfaces.dart';
import 'bank_discovery_outcome_surfaces.dart';
import 'confirmation_outcome_surfaces.dart';
import 'account_guard_surfaces.dart';
import 'budget_outcome_surfaces.dart';
import 'manual_paste_result_surfaces.dart';
import 'pending_age_surfaces.dart';
import 'local_read_notice_surfaces.dart';
import 'goal_contribution_outcome_surfaces.dart';
import 'manual_edit_outcome_surfaces.dart';
import 'card_outcome_surfaces.dart';
import 'brand_asset_atlas.dart';
import 'brand_mark_visibility_surfaces.dart';
import 'confirmation_awaiting_surfaces.dart';
import 'plan_delete_outcome_surfaces.dart';
import 'bill_payment_outcome_surfaces.dart';
import 'bill_partial_link_surfaces.dart';
import 'paste_batch_confirm_surfaces.dart';
import 'coupon_artwork_fallback_surfaces.dart';
import 'conflict_failure_surfaces.dart';
import 'auth_failure_surfaces.dart';
import 'country_save_failure_surfaces.dart';
import 'privacy_refresh_surfaces.dart';
import 'restore_negative_surfaces.dart';
import 'restore_confirmation_cancel_surface.dart';
import 'brand_continue_failure_surfaces.dart';
import 'app_lock_failure_surfaces.dart';
import 'transaction_details_failure_surfaces.dart';
import 'coupon_eligibility_readback.dart';
import 'secondary_fixtures.dart';
import 'read_state_fixtures.dart';
import 'dart:math';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:money_companion/features/cards/brand_mark.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/core/router/app_router.dart';
import 'package:money_companion/core/theme/app_colors.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/core/theme/widgets/native_glass.dart';
import 'package:money_companion/core/theme/widgets/native_tab_bar.dart';
import 'package:money_companion/core/theme/widgets/glass_scaffold_messenger.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/features/budgets/budgets_screen.dart';
import 'package:money_companion/features/dashboard/dashboard_screen.dart';
import 'package:money_companion/features/reports/reports_screen.dart';
import 'package:money_companion/features/settings/settings_screen.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';
import 'package:money_companion/core/utils/l10n_ext.dart';
import 'package:money_companion/l10n/app_localizations.dart';
import 'package:drift/drift.dart' show Variable;

import 'package:money_companion/features/plans/plans_screen.dart';
import 'package:money_companion/features/capture/capture_entry_sheet.dart';
import 'package:money_companion/features/capture/manual_paste_screen.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/features/budgets/budget_form_screen.dart';
import 'package:money_companion/features/goals/goal_form_screen.dart';
import 'package:money_companion/features/goals/goal_details_screen.dart';
import 'package:money_companion/features/dashboard/dashboard_providers.dart';
import 'package:money_companion/features/goals/goals_providers.dart';
import 'package:money_companion/features/budgets/budgets_providers.dart';
import 'package:money_companion/features/reports/reports_providers.dart';

const _egp = 'EGP';
Money egp(int minor) => Money(minor, _egp);

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// (merchant, categoryKey, min, max minor units, weight). Mixes merchants that
/// have bundled logos (Netflix, Uber, Carrefour, Vodafone…) with ones that do
/// not, so both the logo and the fallback mark are exercised.
const _catalogue = <(String, String, int, int, int)>[
  ('Carrefour', 'groceries', 30000, 160000, 5),
  ('Gourmet Egypt', 'groceries', 25000, 90000, 2),
  ('Uber', 'transport', 4500, 22000, 4),
  ('Careem', 'transport', 4000, 18000, 2),
  ('Talabat', 'restaurants', 12000, 48000, 4),
  ('KFC', 'restaurants', 15000, 42000, 2),
  ('Starbucks', 'cafes', 9000, 21000, 4),
  ('Costa Coffee', 'cafes', 8000, 17000, 2),
  ('Amazon.eg', 'shopping', 25000, 260000, 2),
  ('IKEA', 'shopping', 40000, 350000, 1),
  ('Seif Pharmacy', 'health', 6000, 45000, 2),
  ('Shell', 'fuel', 30000, 70000, 2),
];

Future<String?> _categoryId(AppDatabase db, String key) async {
  final rows = await db.customSelect(
    'SELECT id FROM categories WHERE key = ? LIMIT 1',
    variables: [Variable.withString(key)],
  ).get();
  return rows.isEmpty ? null : rows.first.read<String>('id');
}

Future<void> _seed(ProviderContainer c, AppDatabase db) async {
  final accounts = c.read(accountRepositoryProvider);
  final txs = c.read(transactionRepositoryProvider);
  final budgets = c.read(budgetRepositoryProvider);
  final goals = c.read(goalRepositoryProvider);
  final bills = c.read(billRepositoryProvider);
  final now = DateTime.now();
  final rng = Random(7);

  final main = await accounts.create(AccountEntity(
    id: 'p-acc-1',
    name: 'CIB الجاري',
    currency: _egp,
    type: AccountType.bank,
    isDefault: true,
    sortOrder: 0,
    createdAt: now.subtract(const Duration(days: 120)),
    updatedAt: now,
    initialBalanceMoney: egp(4825000),
    currentBalanceMoney: egp(4825000),
  ));
  for (final (i, spec) in <(String, AccountType, int)>[
    ('بنك مصر توفير', AccountType.bank, 11240000),
    ('فودافون كاش', AccountType.wallet, 186050),
    ('نقدي', AccountType.cash, 230000),
  ].indexed) {
    await accounts.create(AccountEntity(
      id: 'p-acc-${i + 2}',
      name: spec.$1,
      currency: _egp,
      type: spec.$2,
      isDefault: false,
      sortOrder: i + 1,
      createdAt: now.subtract(const Duration(days: 100)),
      updatedAt: now,
      initialBalanceMoney: egp(spec.$3),
      currentBalanceMoney: egp(spec.$3),
    ));
  }

  final weighted = [
    for (final e in _catalogue)
      for (var i = 0; i < e.$5; i++) e,
  ];
  for (var day = 75; day >= 0; day--) {
    final count = rng.nextInt(day < 30 ? 3 : 2) + (day == 0 ? 2 : 0);
    for (var i = 0; i < count; i++) {
      final p = weighted[rng.nextInt(weighted.length)];
      final amount = p.$3 + rng.nextInt(p.$4 - p.$3);
      final at = day == 0
          ? now.subtract(Duration(minutes: 40 + i * 95))
          : now.subtract(Duration(days: day, hours: rng.nextInt(10) + 8));
      await txs.saveTransaction(
        transaction: TransactionEntity(
          id: 'p-tx-$day-$i',
          amountMoney: egp(amount),
          currency: _egp,
          type: TransactionTypeEntity.payment,
          source: TransactionSourceEntity.card,
          occurredAt: at,
          rawMessage: 'preview',
          parseConfidence: 0.97,
          status: TransactionStatus.confirmed,
          createdAt: at,
          updatedAt: at,
          rawMerchant: p.$1,
          accountId: main.id,
          cardLast4: '4471',
          direction: TransactionDirectionEntity.debit,
        ),
        categoryKey: p.$2,
      );
    }
    final d = now.subtract(Duration(days: day));
    if (d.day == 25) {
      await txs.saveTransaction(
        transaction: TransactionEntity(
          id: 'p-tx-salary-${d.month}',
          amountMoney: egp(3200000),
          currency: _egp,
          type: TransactionTypeEntity.income,
          source: TransactionSourceEntity.bank,
          occurredAt: DateTime(d.year, d.month, d.day, 9),
          rawMessage: 'preview',
          parseConfidence: 0.99,
          status: TransactionStatus.confirmed,
          createdAt: d,
          updatedAt: d,
          rawMerchant: 'Salary',
          accountId: main.id,
          direction: TransactionDirectionEntity.credit,
        ),
        categoryKey: 'income',
      );
    }
  }
  // Two captures waiting for review.
  for (final (i, spec) in <(String, int, String)>[
    ('POS 7731', 64000, 'restaurants'),
    ('NETFLIX.COM', 25000, 'subscriptions'),
  ].indexed) {
    final at = now.subtract(Duration(hours: 2 + i * 5));
    await txs.saveTransaction(
      transaction: TransactionEntity(
        id: 'p-tx-pending-$i',
        amountMoney: egp(spec.$2),
        currency: _egp,
        type: TransactionTypeEntity.payment,
        source: TransactionSourceEntity.card,
        occurredAt: at,
        rawMessage: 'Synthetic bank SMS\nCard ending 4471 debited EGP '
            '${egp(spec.$2).toDecimalString()} at ${spec.$1}.',
        parseConfidence: 0.6,
        status: TransactionStatus.pending,
        createdAt: at,
        updatedAt: at,
        rawMerchant: spec.$1,
        accountId: main.id,
        direction: TransactionDirectionEntity.debit,
      ),
      categoryKey: spec.$3,
    );
  }

  final monthStart = DateTime(now.year, now.month);
  var b = 0;
  for (final spec in <(String, int)>[
    ('restaurants', 300000),
    ('groceries', 480000),
    ('transport', 160000),
    ('cafes', 90000),
  ]) {
    final catId = await _categoryId(db, spec.$1);
    if (catId == null) continue;
    await budgets.save(BudgetEntity(
      id: 'p-budget-${++b}',
      categoryId: catId,
      currency: _egp,
      amountMoney: egp(spec.$2),
      lastNotifiedSpentMoney: egp(0),
      period: BudgetPeriod.monthly,
      startDate: monthStart,
      isActive: true,
      lastNotifiedPeriodStart: monthStart,
      accountId: main.id,
    ));
  }

  for (final (i, spec) in <(String, String, int, int, int)>[
    ('رحلة الساحل', 'summer_trip', 2500000, 1550000, 270),
    ('صندوق الطوارئ', 'emergency_fund', 6000000, 2100000, 420),
    ('لابتوب جديد', 'photo:laptop', 3500000, 980000, 200),
  ].indexed) {
    await goals.save(GoalEntity(
      id: 'p-goal-$i',
      name: spec.$1,
      currency: _egp,
      targetMoney: egp(spec.$3),
      savedMoney: egp(spec.$4),
      lastNotifiedSavedMoney: egp(0),
      vaultSkin: spec.$2,
      status: 'active',
      createdAt: now.subtract(const Duration(days: 90)),
      deadline: now.add(Duration(days: spec.$5)),
      accountId: main.id,
    ));
  }

  for (final (i, spec) in <(String, int, int)>[
    ('Netflix', 25000, 3),
    ('Spotify', 9900, 9),
    ('Vodafone', 45000, 12),
    ('YouTube Premium', 6500, 18),
  ].indexed) {
    await bills.save(BillEntity(
      id: 'p-bill-$i',
      name: spec.$1,
      amountMoney: egp(spec.$2),
      currency: _egp,
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime(now.year, now.month, now.day + spec.$3),
      reminderOn: true,
      isConfirmed: true,
      createdAt: now,
    ));
  }
}

final _previewTheme = StateProvider<ThemeMode>((ref) => ThemeMode.light);
final _previewCloudResume = StateProvider<bool>((ref) => false);
// Opt-in QA only: public sheets may be inspected without the debug UIKit tab overlay.
final _previewHideNativeFooter = StateProvider<bool>((ref) => false);
WidgetRef? _bridgeRef;
late ProviderContainer _container;
late AppDatabase _database;
String _fixtureMode = 'data';
String? _outcomeTarget;
int _fixtureGeneration = 0;
final _errors = <String>[];
Map<String, Object?>? _lastScroll;
final _previewLocale = StateProvider<Locale>((ref) => const Locale('ar'));

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await HomeHeroPeriodController.preload();
  FlutterError.onError = (details) {
    _errors.add(details.exceptionAsString());
    FlutterError.presentError(details);
  };
  await NativeGlassSupport.probe();
  // Mirrors bootstrap_runner's _registerBrandLogos so logos resolve as shipped.
  final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
  BrandMark.registerAssetSlugs(manifest
      .listAssets()
      .where((a) => a.startsWith('assets/brands/') && a.endsWith('.svg'))
      .map((a) => a.split('/').last.replaceAll('.svg', '')));
  await _loadFixture(const bool.fromEnvironment('PREVIEW_EMPTY') ? 'empty' : 'data');
  await _servePreview();
}

Future<T> _fixtureOutcome<T>(String mode) {
  if (mode == 'error') return Future<T>.error(StateError('Synthetic visual fixture failure'));
  return Completer<T>().future;
}

Future<void> _loadFixture(String mode, {String? outcomeTarget}) async {
  if (outcomeTarget != null &&
      (!visualParityReadStateTargets.containsKey(outcomeTarget) ||
       (mode != 'loading' && mode != 'error'))) {
    throw ArgumentError.value(outcomeTarget, 'outcomeTarget',
        'Choose a documented target with loading or error mode.');
  }
  if (_fixtureGeneration > 0) {
    // Extra public sheets/pages also push directly on the Navigator. Drain
    // those routes before closing their memory database or changing providers.
    final navigator = _router.routerDelegate.navigatorKey.currentState;
    while (navigator?.canPop() ?? false) {
      navigator!.pop();
    }
    await WidgetsBinding.instance.endOfFrame;
    _router.go('/');
    runApp(const SizedBox.shrink());
    await WidgetsBinding.instance.endOfFrame;
    _container.dispose();
    await _database.close();
  }
  _database = await AppDatabase.open(executor: NativeDatabase.memory(),
    keyStore: _MemoryKeyStore(), initialLanguage: 'ar');
  final readStateOverrides = await visualParityReadStateOverrides(
      database: _database, mode: mode, outcomeTarget: outcomeTarget);
  final simulated = outcomeTarget == null &&
      (mode == 'loading' || mode == 'error');
  _container = ProviderContainer(overrides: [
    ...visualParitySecondaryOverrides(
        mode: outcomeTarget == null ? mode : 'data'),
    ...readStateOverrides,
    appDatabaseProvider.overrideWithValue(_database),
    // Presentation-only state of this disposable fixture, never the phone app.
    cloudResumeReminderProvider.overrideWith((ref) async =>
        ref.watch(_previewCloudResume) ? 'synthetic-cloud-resume' : null),
    localeProvider.overrideWith((ref) => ref.watch(_previewLocale)),
    for (final p in AdPlacement.values)
      bannerEligibilityProvider(p).overrideWith((ref) async => false),
    if (simulated) ...[
      dashboardDataProvider.overrideWith((ref) => _fixtureOutcome<DashboardData>(mode)),
      goalsListProvider.overrideWith((ref) => _fixtureOutcome<List<GoalEntity>>(mode)),
      budgetsViewProvider.overrideWith((ref) => _fixtureOutcome<BudgetsView>(mode)),
      reportsProvider.overrideWith((ref) => _fixtureOutcome<ReportsBundle>(mode)),
      accountsProvider.overrideWith((ref) => _fixtureOutcome<List<AccountEntity>>(mode)),
    ],
  ]);
  await initFeatureFlagService(_database,
    installIdOverride: 'visual-parity-fixture', applyRemoteOverrides: false);
  final settingsRepo = _container.read(userSettingsRepositoryProvider);
  final settings = await settingsRepo.getSettings();
  await settingsRepo.saveSettings(settings.copyWith(currency: 'EGP', country: 'EG'));
  if (mode != 'empty') {
    await _seed(_container, _database);
    // Same local discovery step as production bootstrap, on this memory DB.
    // Account detail reads managed cards; card summaries also read the ledger.
    await _container.read(cardRepositoryProvider).backfillFromTransactions();
    await seedVisualParitySecondaryFixtures(_container, _database);
  }
  _fixtureMode = mode;
  _outcomeTarget = outcomeTarget;
  runApp(UncontrolledProviderScope(key: ValueKey(++_fixtureGeneration),
    container: _container, child: const _App()));
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

final _router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const _PreviewShell()),
    GoRoute(path: '/preview/plans', builder: (context, state) => const PlansScreen()),
    GoRoute(path: '/preview/story-reduced-motion', builder: (context, state) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: true),
      child: const OnboardingStoryScreen())),
    ...appRouter.configuration.routes.where(
        (r) => r is! GoRoute || r.path != '/'),
  ],
);

class _App extends ConsumerWidget {
  const _App();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      routerConfig: _router,
      locale: ref.watch(_previewLocale),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      themeMode: ref.watch(_previewTheme),
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      scrollBehavior:
          const MaterialScrollBehavior().copyWith(scrollbars: false),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: Theme.of(context).brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
        child: GlassScaffoldMessenger(child: Stack(children: [
          child!,
          ValueListenableBuilder<Widget?>(
            valueListenable: visualParityPasteBatchConfirmOverlay,
            builder: (_, overlay, __) => overlay ?? const SizedBox.shrink(),
          ),
          ValueListenableBuilder<Widget?>(
            valueListenable: visualParityBillPartialLinkOverlay,
            builder: (_, overlay, __) => overlay ?? const SizedBox.shrink(),
          ),
          ValueListenableBuilder<Widget?>(
            valueListenable: visualParityBillPaymentOutcomeOverlay,
            builder: (_, overlay, __) => overlay ?? const SizedBox.shrink(),
          ),
          ValueListenableBuilder<Widget?>(
            valueListenable: visualParityPlanDeleteOutcomeOverlay,
            builder: (_, overlay, __) => overlay ?? const SizedBox.shrink(),
          ),
          ValueListenableBuilder<Widget?>(
            valueListenable: visualParityCardOutcomeOverlay,
            builder: (_, overlay, __) => overlay ?? const SizedBox.shrink(),
          ),
          VisualParitySurfaceBridge(onReady: (context, ref) {
            _bridgeRef = ref;
          }),
        ])),
      ),
    );
  }
}

/// Stand-in for AppShell: the same five pages and the same native tab bar
/// ordering, without the session/sync lifecycle.
class _PreviewShell extends ConsumerWidget {
  const _PreviewShell();

  static const _slots = [0, 1, 2, 4, 3];
  static const _symbols = {
    0: 'house',
    1: 'list.bullet.rectangle',
    2: 'banknote',
    3: 'gearshape',
    4: 'chart.pie',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(shellIndexProvider);
    final l = context.l10n;
    final titles = {
      0: l.navHome,
      1: l.navTransactions,
      2: l.navBudgets,
      3: l.navMore,
      4: l.navAnalytics,
    };
    final pages = [
      const DashboardScreen(),
      const TransactionsScreen(),
      const BudgetsScreen(),
      const SettingsScreen(),
      index == 4 ? const ReportsScreen() : const SizedBox.shrink(),
    ];
    return Scaffold(
      extendBody: true,
      backgroundColor: context.colors.bg,
      body: IndexedStack(index: index, children: pages),
      bottomNavigationBar: ValueListenableBuilder<bool>(
        valueListenable: NativeGlassSupport.supported,
        builder: (context, native, _) => ref.watch(_previewHideNativeFooter)
            ? const SizedBox.shrink()
            : native
            ? NativeTabBar(
                items: [
                  for (final p in _slots)
                    NativeTabBarItem(symbol: _symbols[p]!, title: titles[p]!),
                ],
                selectedIndex: _slots.indexOf(index),
                onSelect: (slot) =>
                    ref.read(shellIndexProvider.notifier).state = _slots[slot],
                dark: Theme.of(context).brightness == Brightness.dark,
                rtl: Directionality.of(context) == TextDirection.rtl,
                tint: context.colors.cta,
              )
            : NavigationBar(
                selectedIndex: _slots.indexOf(index),
                onDestinationSelected: (slot) =>
                    ref.read(shellIndexProvider.notifier).state = _slots[slot],
                destinations: [
                  for (final p in _slots)
                    NavigationDestination(
                        icon: const Icon(Icons.circle_outlined),
                        label: titles[p]!),
                ],
              ),
      ),
    );
  }
}


// Loopback-only control for this in-memory visual fixture. This file is never
// imported by lib/main.dart and no production credentials are passed to it.
void _inspectPreviewTree(void Function(Element) visitor) {
  final element = visualParityPasteBatchInspectionContext ??
      visualParityBillPartialLinkInspectionContext ??
      visualParityBillPaymentOutcomeInspectionContext ??
      visualParityPlanDeleteOutcomeInspectionContext ??
      visualParityCardOutcomeInspectionContext ??
      _router.routerDelegate.navigatorKey.currentContext;
  if (element is Element && element.mounted) visitor(element);
}

List<Map<String, Object?>> _visibleText() {
  final result = <Map<String, Object?>>[];
  void visit(Element element) {
    if (element.widget case final Text text) {
      final r = element.findRenderObject();
      if (r is RenderBox && r.hasSize && r.attached) {
        final at = r.localToGlobal(Offset.zero);
        result.add({'text': text.data ?? text.textSpan?.toPlainText(),
          'currentRoute': ModalRoute.of(element)?.isCurrent ?? true,
          'x': at.dx, 'y': at.dy, 'w': r.size.width, 'h': r.size.height});
      }
    }
    element.debugVisitOnstageChildren(visit);
  }
  _inspectPreviewTree(visit);
  return result;
}

Future<void> _servePreview() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4,
      const int.fromEnvironment('PREVIEW_CONTROL_PORT', defaultValue: 9876));
  await for (final request in server) {
    try {
      if (request.method == 'POST') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        if (body['fixture'] case final String fixture) {
          await _loadFixture(fixture,
              outcomeTarget: body['outcomeTarget'] as String?);
        }
        if (body['clearErrors'] == true) _errors.clear();
        if (body['cloudResumeBanner'] case final bool visible) {
          _container.read(_previewCloudResume.notifier).state = visible;
        }
        if (body['hideNativeFooter'] case final bool hidden) {
          _container.read(_previewHideNativeFooter.notifier).state = hidden;
        }
        if (body['locale'] case final String lang) {
          _container.read(_previewLocale.notifier).state = Locale(lang);
        }
        if (body['theme'] case final String theme) {
          _container.read(_previewTheme.notifier).state =
              theme == 'dark' ? ThemeMode.dark : ThemeMode.light;
        }
        if (body['route'] case final String path) {
          if (path == '/') { _router.go('/'); }
          else { unawaited(_router.push(path)); }
        }
        if (body['tab'] case final int tab) {
          _router.go('/');
          _container.read(shellIndexProvider.notifier).state = tab;
        }
        if (body['closeCardOutcome'] == true) await closeVisualParityCardOutcome();
        if (body['closePlanDeleteOutcome'] == true) await closeVisualParityPlanDeleteOutcome();
        if (body['closeBillPaymentOutcome'] == true) await closeVisualParityBillPaymentOutcome();
        if (body['releaseBrandContinueFailure'] == true) releaseVisualParityBrandContinueFailure();
        if (body['releaseAppLockFailure'] == true) releaseVisualParityAppLockFailure();
        if (body['releaseRestoreNegative'] == true) releaseVisualParityRestoreNegative();
        if (body['releaseConflictFailure'] == true) releaseVisualParityConflictFailure();
        if (body['releaseAuthFailure'] == true) releaseVisualParityAuthFailure();
        if (body['releaseCountryFailure'] == true) releaseVisualParityCountryFailure();
        if (body['releaseTransactionFailure'] == true) releaseVisualParityTransactionFailure();
        if (body['releasePasteBatchConfirm'] == true) releaseVisualParityPasteBatchConfirm();
        if (body['closePasteBatchConfirm'] == true) await closeVisualParityPasteBatchConfirm();
        if (body['closeBillPartialLink'] == true) await closeVisualParityBillPartialLink();
        if (body['pop'] == true) {
          final nav = _router.routerDelegate.navigatorKey.currentState;
          if (nav?.canPop() ?? false) nav!.pop();
        }
        if (body['extra'] case final String key) {
          final navigatorContext = _router.routerDelegate.navigatorKey.currentContext;
          if (navigatorContext == null || !navigatorContext.mounted || _bridgeRef == null) throw StateError('Preview not ready');
          if (!await openVisualParitySurface(navigatorContext, _bridgeRef!, key)) {
            throw StateError('Unsupported or unseeded visual surface: $key');
          }
        }
        if (body['sheet'] case final String sheet) {
          final context = _router.routerDelegate.navigatorKey.currentContext!;
          if (!context.mounted) throw StateError('Preview navigator unmounted');
          switch (sheet) {
            case 'capture': unawaited(showCaptureEntrySheet(context));
            case 'manual': unawaited(ManualTransactionSheet.show(context));
            case 'paste': unawaited(ManualPasteScreen.showSheet(context));
            case 'budgetNew': unawaited(BudgetFormScreen.showSheet(context));
            case 'goalNew': unawaited(GoalFormScreen.showSheet(context));
            case 'goal': unawaited(GoalDetailsScreen.showSheet(context, 'p-goal-0'));
            default: throw ArgumentError('Unknown sheet');
          }
        }
        if (body['focusField'] case final int index) {
          final fields = <EditableTextState>[];
          void collect(Element element) {
            if (element is StatefulElement && element.state is EditableTextState &&
                (ModalRoute.of(element)?.isCurrent ?? true)) {
              fields.add(element.state as EditableTextState);
            }
            element.debugVisitOnstageChildren(collect);
          }
          _inspectPreviewTree(collect);
          if (body.containsKey('userInput') && index >= fields.length) {
            throw StateError('Visible editable fixture field not found: $index');
          }
          if (index < fields.length) {
            final field = fields[index];
            field.widget.focusNode.requestFocus();
            if (body['input'] case final String text) field.widget.controller.text = text;
            // Opt-in platform editing path for formatters and onChanged (search).
            if (body['userInput'] case final String text) {
              field.updateEditingValue(TextEditingValue(text: text,
                selection: TextSelection.collapsed(offset: text.length)));
            }
          }
        }
        if (body['unfocus'] == true) FocusManager.instance.primaryFocus?.unfocus();
        if (body['scroll'] case final num delta) {
          Offset? requestedPoint;
          if (body['scrollAt'] case [final num x, final num y]) {
            requestedPoint = Offset(x.toDouble(), y.toDouble());
          }
          ScrollableState? target;
          void visit(Element element) {
            if (element is StatefulElement && element.state is ScrollableState) {
              final scroll = element.state as ScrollableState;
              final canMove = delta >= 0
                  ? scroll.position.pixels < scroll.position.maxScrollExtent
                  : scroll.position.pixels > scroll.position.minScrollExtent;
              final render = element.findRenderObject();
              final containsPoint = requestedPoint == null ||
                  (render is RenderBox && render.hasSize &&
                   (render.localToGlobal(Offset.zero) & render.size).contains(requestedPoint));
              if ((ModalRoute.of(element)?.isCurrent ?? true) &&
                  scroll.position.axis == Axis.vertical &&
                  scroll.position.maxScrollExtent > 0 && canMove && containsPoint &&
                  (target == null || (requestedPoint == null
                      ? scroll.position.viewportDimension > target!.position.viewportDimension
                      : scroll.position.viewportDimension <= target!.position.viewportDimension))) {
                target = scroll;
              }
            }
            element.debugVisitOnstageChildren(visit);
          }
          _inspectPreviewTree(visit);
          final p = target?.position;
          final before = p?.pixels;
          if (p != null) p.jumpTo((p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent));
          _lastScroll = {'before': before, 'after': p?.pixels,
            'viewport': p?.viewportDimension, 'maxScrollExtent': p?.maxScrollExtent,
            if (requestedPoint != null) 'requestedPoint': [requestedPoint.dx, requestedPoint.dy],
            if (requestedPoint != null) 'pointTargeted': true};
        }
        if (body['scrollHorizontal'] case final num delta) {
          ScrollableState? target;
          final bounds = MediaQuery.sizeOf(
              _router.routerDelegate.navigatorKey.currentContext!);
          void visit(Element element) {
            if (element is StatefulElement && element.state is ScrollableState) {
              final scroll = element.state as ScrollableState;
              final render = element.findRenderObject();
              if ((ModalRoute.of(element)?.isCurrent ?? true) &&
                  scroll.position.axis == Axis.horizontal &&
                  scroll.position.maxScrollExtent > 0 &&
                  render is RenderBox && render.hasSize && render.attached) {
                final center = render.localToGlobal(render.size.center(Offset.zero));
                if (center.dx > 0 && center.dx < bounds.width &&
                    center.dy > 0 && center.dy < bounds.height &&
                    (target == null || scroll.position.viewportDimension >
                        target!.position.viewportDimension)) {
                  target = scroll;
                }
              }
            }
            element.debugVisitOnstageChildren(visit);
          }
          _inspectPreviewTree(visit);
          final position = target?.position;
          if (position == null) throw StateError('No visible horizontal fixture rail');
          final before = position.pixels;
          position.jumpTo((before + delta).clamp(
              position.minScrollExtent, position.maxScrollExtent));
          _lastScroll = {'axis': 'horizontal', 'before': before,
            'after': position.pixels, 'viewport': position.viewportDimension,
            'maxScrollExtent': position.maxScrollExtent};
        }
        if (body['tapTooltip'] case final String tooltip) {
          RenderBox? target;
          final bounds = Offset.zero & MediaQuery.sizeOf(
              _router.routerDelegate.navigatorKey.currentContext!);
          void visit(Element element) {
            if (element.widget case IconButton(tooltip: final label)
                when label == tooltip && (ModalRoute.of(element)?.isCurrent ?? true)) {
              if (body['tooltipWithinText'] case final String title) {
                var matches = false;
                element.visitAncestorElements((ancestor) {
                  if (ancestor.widget case ListTile(title: Text(data: final text))
                      when text == title) {
                    matches = true;
                  }
                  return !matches;
                });
                if (!matches) return;
              }
              final render = element.findRenderObject();
              if (render is RenderBox && render.hasSize && render.attached &&
                  bounds.contains(render.localToGlobal(render.size.center(Offset.zero)))) {
                final hit = HitTestResult();
                RendererBinding.instance.hitTestInView(hit,
                    render.localToGlobal(render.size.center(Offset.zero)),
                    WidgetsBinding.instance.platformDispatcher.views.first.viewId);
                if (hit.path.any((entry) => identical(entry.target, render))) {
                  target ??= render;
                }
              }
            }
            element.debugVisitOnstageChildren(visit);
          }
          _inspectPreviewTree(visit);
          final render = target;
          if (render == null) throw StateError('No visible fixture tooltip: $tooltip');
          final point = render.localToGlobal(render.size.center(Offset.zero));
          GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 1, position: point));
          await Future<void>.delayed(const Duration(milliseconds: 90));
          GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 1, position: point));
        }
        if (body['tapKey'] case final String key) {
          RenderBox? target;
          void visit(Element element) {
            if (element.widget.key == ValueKey<String>(key)) {
              final render = element.findRenderObject();
              if (render is RenderBox && render.hasSize && render.attached) target = render;
            }
            element.debugVisitOnstageChildren(visit);
          }
          _inspectPreviewTree(visit);
          final render = target;
          if (render == null) throw StateError('Visible fixture control not found: $key');
          final point = render.localToGlobal(render.size.center(Offset.zero));
          final bounds = MediaQuery.sizeOf(_router.routerDelegate.navigatorKey.currentContext!);
          if (point.dy < 0 || point.dy > bounds.height || point.dx < 0 || point.dx > bounds.width) {
            throw StateError('Fixture control outside viewport: $key');
          }
          GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 1, position: point));
          await Future<void>.delayed(const Duration(milliseconds: 90));
          GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 1, position: point));
        }
        if (body['tap'] case final List<dynamic> coordinates) {
          final point = Offset((coordinates[0] as num).toDouble(), (coordinates[1] as num).toDouble());
          GestureBinding.instance.handlePointerEvent(PointerDownEvent(pointer: 1, position: point));
          await Future<void>.delayed(const Duration(milliseconds: 90));
          GestureBinding.instance.handlePointerEvent(PointerUpEvent(pointer: 1, position: point));
        }
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'route': _router.routeInformationProvider.value.uri.toString(),
        'tab': _container.read(shellIndexProvider),
        'homeHeroPeriod': _container.read(heroPeriodProvider).name,
        'locale': _container.read(_previewLocale).languageCode,
        'theme': _container.read(_previewTheme).name,
        'qaNativeFooterHidden': _container.read(_previewHideNativeFooter),
        'errors': _errors,
        'texts': _visibleText(),
        'editableFields': _editableFieldEvidence(),
        'syntheticOnly': true,
        'textScaleAt16': _router.routerDelegate.navigatorKey.currentContext == null
            ? null : MediaQuery.textScalerOf(
                _router.routerDelegate.navigatorKey.currentContext!).scale(16) / 16,
        'viewport': {
          'width': WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.width / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio,
          'height': WidgetsBinding.instance.platformDispatcher.views.first.physicalSize.height / WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio,
        },
        'fixture': _fixtureMode,
        'outcomeTarget': _outcomeTarget,
        'fixtureOutcomes': visualParityReadStateManifest,
        'extraSurfaces': visualParityExtraSurfaceKeys,
        'fixtureEvents': visualParityExtendedEvents(),
        'localReadPresentationEvents': visualParityLocalReadEvents(),
        'formOutcomeEvents': visualParityFormOutcomeEvents(),
        'pasteOutcomeEvents': visualParityPasteOutcomeEvents(),
        'deletionStatusPresentationEvents': visualParityDeletionStatusEvents(),
        'registrationStatusPresentationEvents': visualParityRegistrationStateEvents(),
        'settingsPreferenceEvents': visualParitySettingsPreferenceEvents(),
        'bankDiscoveryOutcomeEvents': visualParityBankDiscoveryOutcomeEvents(),
        'confirmationOutcomeEvents': visualParityConfirmationOutcomeEvents(),
        'accountGuardEvents': visualParityAccountGuardEvents(),
        'budgetOutcomeEvents': visualParityBudgetOutcomeEvents(),
        'pendingAgeEvents': visualParityPendingAgeEvents(),
        'localReadNoticeEvents': visualParityLocalReadNoticeEvents(),
        'goalContributionOutcomeEvents': visualParityGoalContributionOutcomeEvents(),
        'manualEditOutcomeEvents': visualParityManualEditOutcomeEvents(),
        'manualEditOutcomeReceipts': visualParityManualEditOutcomeReceipts(),
        'cardOutcomeEvents': visualParityCardOutcomeEvents(),
        'brandAssetAtlasEvents': visualParityBrandAssetAtlasEvents(),
        'brandAssetAtlasErrors': visualParityBrandAssetAtlasErrors(),
        'brandMarkVisibilityEvents': visualParityBrandMarkVisibilityEvents(),
        'confirmationAwaitingEvents': visualParityConfirmationAwaitingEvents(),
        'confirmationAwaitingReceipts': visualParityConfirmationAwaitingReceipts(),
        'planDeleteOutcomeEvents': visualParityPlanDeleteOutcomeEvents(),
        'billPaymentOutcomeEvents': visualParityBillPaymentOutcomeEvents(),
        'couponArtworkFallbackEvents': visualParityCouponArtworkFallbackEvents(),
        'couponArtworkFallbackReceipts': visualParityCouponArtworkFallbackReceipts(),
        'conflictFailureEvents': visualParityConflictFailureEvents(),
        'pasteBatchEvents': visualParityPasteBatchConfirmEvents(),
        'pasteBatchReceipt': visualParityPasteBatchConfirmReceipt(),
        'pasteBatchSample': visualParityPasteBatchMessage(),
        'billPartialLinkEvents': visualParityBillPartialLinkEvents(),
        'billPartialLinkReceipt': visualParityBillPartialLinkReceipt(),
        'privacyRefreshEvents': visualParityPrivacyRefreshEvents(),
        'restoreNegativeEvents': visualParityRestoreNegativeEvents(),
        'restoreCancelEvents': visualParityRestoreCancelEvents(),
        'brandContinueFailureEvents': visualParityBrandContinueFailureEvents(),
        if (request.uri.queryParameters['brandReadback'] == '1')
          'brandContinueFailureReadback': await visualParityBrandContinueFailureReadback(),
        'appLockFailureEvents': visualParityAppLockFailureEvents(),
        'switches': _switchEvidence(),
        'countryFailureEvents': visualParityCountryFailureEvents(),
        'transactionFailureEvents': visualParityTransactionFailureEvents(),
        'authFailureEvents': visualParityAuthFailureEvents(),
        'manualPasteResultEvents': visualParityManualPasteResultEvents(),
        'manualPasteResultReceipts': visualParityManualPasteResultReceipts(),
        'manualPasteSyntheticInputs': {for (final key in visualParityManualPasteResultKeys) key: visualParityManualPasteMessage(key)},
        'lastScroll': _lastScroll,
        'syntheticReport': visualParityLastReport(),
        if (request.uri.queryParameters['couponEligibility'] == '1')
          'couponEligibility': await readVisualParityCouponEligibility(_container),
        if (request.uri.queryParameters['readback'] == '1')
          'fixtureReadback': await _readFixtureState(),
        'unsupported': visualParityUnsupportedSurfaces,
      }));
    } catch (error) {
      request.response.statusCode = 500;
      request.response.write(jsonEncode({'error': error.toString()}));
    } finally {
      await request.response.close();
    }
  }
}

// Values of actual rendered settings switches, never a platform permission grant.
List<Map<String, Object?>> _switchEvidence() {
  final switches = <Map<String, Object?>>[];
  void visit(Element element) {
    final widget = element.widget;
    if (widget is SwitchListTile &&
        (ModalRoute.of(element)?.isCurrent ?? true)) {
      final title = widget.title;
      switches.add({
        'label': title is Text ? title.data : null,
        'value': widget.value,
        'enabled': widget.onChanged != null,
      });
    }
    element.debugVisitOnstageChildren(visit);
  }
  _inspectPreviewTree(visit);
  return switches;
}

// Current-route draft diagnostics for this disposable fixture only.
List<Map<String, Object?>> _editableFieldEvidence() {
  final fields = <Map<String, Object?>>[];
  void visit(Element element) {
    if (element is StatefulElement && element.state is EditableTextState &&
        (ModalRoute.of(element)?.isCurrent ?? true)) {
      final state = element.state as EditableTextState;
      fields.add({'index': fields.length, 'text': state.widget.controller.text,
        'focused': state.widget.focusNode.hasFocus});
    }
    element.debugVisitOnstageChildren(visit);
  }
  _inspectPreviewTree(visit);
  return fields;
}

// Opt-in readback of this tool's disposable memory fixture. Never shipped from
// lib/: lets Simulator actions be checked against the actual repositories.
Future<Map<String, Object?>> _readFixtureState() async {
  final databases = await _database.customSelect('PRAGMA database_list').get();
  if (!databases.any((row) => row.read<String>('name') == 'main' &&
      row.read<String>('file').isEmpty)) {
    throw StateError('readback_requires_memory');
  }
  final accounts = await _container.read(accountRepositoryProvider).getAll();
  final cards = await _container.read(cardRepositoryProvider).getAll();
  final goals = await _container.read(goalRepositoryProvider).getAll();
  final plans = await _container.read(planRepositoryProvider).getAll();
  final budgets = await _container.read(budgetRepositoryProvider).getAll();
  final bills = await _container.read(billRepositoryProvider).getAll();
  final settings = await _container.read(userSettingsRepositoryProvider).getSettings();
  final categories = await _container.read(categoryRepositoryProvider).getAll();
  final pricedTransaction = await _container.read(transactionRepositoryProvider)
      .getById('qa-txAwaitingFx');
  return {
    'syntheticOnly': true,
    'categories': [for (final category in categories) {
      'id': category.id, 'key': category.key, 'nameAr': category.nameAr,
      'icon': category.icon, 'color': category.color,
      'isIncome': category.isIncome, 'sort': category.sort,
    }],
    'notificationPreferencesJson': settings.notificationsJson,
    'accounts': [for (final a in accounts) {'id': a.id, 'name': a.name,
      'currency': a.currency, 'initialMinor': a.initialBalanceMoney?.minorUnits,
      'currentMinor': a.currentBalanceMoney?.minorUnits, 'type': a.type.name,
      'isDefault': a.isDefault, 'excludeFromTotals': a.excludeFromTotals,
      'walletProvider': a.walletProvider, 'bankAccountNumber': a.bankAccountNumber,
      'creditLimitMinor': a.creditLimitMoney?.minorUnits,
      'availableCreditMinor': a.availableCreditMoney?.minorUnits,
      'paymentDueDay': a.paymentDueDay, 'metadata': a.metadata}],
    'cards': [for (final c in cards) {'id': c.id, 'accountId': c.accountId,
      'last4': c.last4, 'theme': c.colorTheme, 'accent': c.accentHex,
      'nickname': c.nickname, 'network': c.network.name}],
    if (pricedTransaction != null) 'pricedTransaction': {
      'id': pricedTransaction.id, 'accountId': pricedTransaction.accountId,
      'cardLast4': pricedTransaction.cardLast4,
      'amountMinor': pricedTransaction.amountMoney.minorUnits,
      'currency': pricedTransaction.currency,
      'foreignMinor': pricedTransaction.foreignMoney?.minorUnits,
      'foreignCurrency': pricedTransaction.foreignCurrency,
      'pricingState': pricedTransaction.pricingState.name,
    },
    'goals': [for (final g in goals) {'id': g.id, 'name': g.name,
      'currency': g.currency, 'savedMinor': g.savedMoney.minorUnits,
      'targetMinor': g.targetMoney.minorUnits, 'accountId': g.accountId,
      'autoSaveMinor': g.autoSaveMoney?.minorUnits,
      'autoSavePeriod': g.autoSavePeriod,
      'autoSaveLastRun': g.autoSaveLastRun?.toUtc().toIso8601String(),
      'deadline': g.deadline?.toUtc().toIso8601String(),
      'cover': g.vaultSkin}],
    'plans': [for (final p in plans) {'id': p.id, 'name': p.name,
      'currency': p.currency, 'budgetMinor': p.budgetAmountMoney.minorUnits,
      'icon': p.icon, 'start': p.startDate.toUtc().toIso8601String(),
      'end': p.endDate.toUtc().toIso8601String(), 'accountIds': p.accountIds,
      'cardLast4s': p.cardLast4s, 'status': p.status.name}],
    'budgets': [for (final b in budgets) {'id': b.id, 'categoryId': b.categoryId,
      'currency': b.currency, 'amountMinor': b.amountMoney.minorUnits,
      'accountId': b.accountId}],
    'bills': [for (final b in bills) {'id': b.id, 'name': b.name,
      'currency': b.currency, 'amountMinor': b.amountMoney.minorUnits,
      'accountId': b.accountId, 'type': b.type.name,
      'frequency': b.frequency.name, 'customDays': b.customIntervalDays,
      'due': b.nextDueDate.toUtc().toIso8601String(),
      'manualPaidMinor': b.manualPaidMoney?.minorUnits,
      'totalPurchaseMinor': b.totalPurchaseMoney?.minorUnits,
      'status': b.status.name, 'reminderOn': b.reminderOn,
      'isConfirmed': b.isConfirmed}],
  };
}
