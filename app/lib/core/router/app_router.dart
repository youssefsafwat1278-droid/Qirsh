import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../session/app_session.dart';
import '../startup/automatic_session_recovery.dart';
import 'modal_route_observer.dart';
import '../observability/flutter_diagnostics.dart';
import '../theme/widgets/navy_sheet_theme.dart';
import '../../features/accounts/account_detail_screen.dart';
import '../../features/accounts/accounts_screen.dart';
import '../../features/achievements/achievements_screen.dart';
import '../../features/announcements/announcements_screen.dart';
import '../../features/app/app_shell.dart';
import '../../features/app/local_read_shell.dart';
import '../../features/app/app_boot_loader.dart';
import '../../features/onboarding/auth_screen.dart';
import '../../features/onboarding/brand_screen.dart';
import '../../features/onboarding/restore_prompt_screen.dart';
import '../../features/onboarding/setup_screen.dart';
import '../../features/onboarding/story_screen.dart';
import '../../features/onboarding/language_screen.dart';
import '../../features/onboarding/account_completion_screen.dart';
import '../backend/supabase_config.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;
import '../../features/reports/reports_screen.dart';
import '../../features/help/help_screen.dart';
import '../../features/settings/delete_account_screen.dart';
import '../../features/settings/privacy_screen.dart';
import '../../features/settings/data_transfer_screen.dart';
import '../../features/settings/planning_currency_repair_screen.dart';
import '../../features/subscriptions/subscriptions_screen.dart';
import '../../features/budgets/budget_form_screen.dart';
import '../../features/budgets/budgets_screen.dart';
import '../../features/cards/card_details_screen.dart';
import '../../features/cards/my_cards_screen.dart';
import '../../features/capture/manual_paste_screen.dart';
import '../../features/capture/sms_permission_screen.dart';
import '../../features/coupons/coupons_screen.dart';
import '../../features/coupons/merchant_offers_screen.dart';
import '../../features/coupons/savings_screen.dart';
import '../../features/referrals/referrals_screen.dart';
import '../../features/design_gallery/design_gallery_screen.dart';
import '../../features/settings/sync_diagnostics_screen.dart';
import '../../features/goals/goal_details_screen.dart';
import '../../features/goals/goal_form_screen.dart';
import '../../features/goals/goals_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/transactions/transaction_details_screen.dart';

/// Offline local read: the only locations reachable while a verified local-read
/// scope is published. Null = allowed; otherwise the location to redirect to.
String? localReadRedirect(String location, {bool reconnectAllowed = true}) {
  final path = Uri.tryParse(location)?.path;
  if (path == '/' || (reconnectAllowed && path == '/onboarding/auth')) return null;
  return '/';
}

String onboardingEntryPathForSession(AppSession session) {
  // Only ever consulted after the welcome/story gate has been passed, so the
  // signed-out returning user lands directly on mandatory auth.
  return '/onboarding/auth';
}

/// موجّه التطبيق (go_router).
final appRouter = GoRouter(
  initialLocation: '/',
  refreshListenable: Listenable.merge([
    AppSession.instance,
    AutomaticSessionRecovery.restoringSession,
    AutomaticSessionRecovery.recoveryTimedOut,
  ]),
  // Hides the native glass tab bar while a bottom sheet/dialog is open (it is
  // a platform view that Flutter modals can't cover). See ModalRouteObserver.
  observers: [modalRouteObserver, DiagnosticNavigationObserver()],
  redirect: (context, state) {
    final session = AppSession.instance;
    if (AutomaticSessionRecovery.recoveryTimedOut.value) {
      return state.uri.path == '/' ? null : '/';
    }
    // A writable scope can be published before the recovered identity/status.
    // Keep Auth and the financial shell out of that intermediate frame.
    if (AutomaticSessionRecovery.restoringSession.value) {
      return state.uri.path == '/' ? null : '/';
    }
    // A retained read-only scope stays restrictive during authority handoff.
    // The home builder exposes its data only after selected-authority proof.
    if (session.localReadPresentationRestricted) {
      return localReadRedirect(state.uri.toString(),
          reconnectAllowed: !session.localReadTransitionPending);
    }
    if (!session.hasChosenOnboardingLanguage) {
      return state.uri.path == '/onboarding/language' ? null : '/onboarding/language';
    }
    final status = session.status;
    if (state.uri.path == '/onboarding/language') {
      if (!session.hasSeenWelcomeManifesto) return '/welcome';
      return status == SessionStatus.authenticated
          ? '/'
          : onboardingEntryPathForSession(session);
    }
    final inWelcome = state.matchedLocation == '/welcome';
    final inOnboarding = state.matchedLocation.startsWith('/onboarding');
    if (!session.hasSeenWelcomeManifesto) {
      // The cinematic sequence spans /welcome (story) → /onboarding/brand, and
      // the welcome-seen flag is only set at the end (brand's CTA), so allow the
      // brand route through the pre-welcome gate too.
      final inWelcomeFlow =
          inWelcome || state.matchedLocation == '/onboarding/brand';
      return inWelcomeFlow ? null : '/welcome';
    }
    if (inWelcome) {
      return status == SessionStatus.authenticated
          ? '/'
          : onboardingEntryPathForSession(session);
    }
    // needsOnboarding (never/not-yet authenticated) and sessionExpired (was
    // authenticated; the live Supabase session is no longer valid) both send
    // a non-guest user to the same mandatory sign-in screen. Once there,
    // `inOnboarding` is true, so this same check does not fire again on the
    // next redirect evaluation — no loop, exactly one hop per status change.
    if ((status == SessionStatus.needsOnboarding ||
            status == SessionStatus.sessionExpired) &&
        !inOnboarding) {
      if (status == SessionStatus.sessionExpired && kDebugMode) {
        debugPrint(
          '[AppSession] router redirecting to sign-in: session expired',
        );
      }
      return onboardingEntryPathForSession(session);
    }
    if (status == SessionStatus.authenticated && inOnboarding) {
      return '/';
    }
    return null;
  },
  routes: [
    GoRoute(
      path: '/onboarding/language',
      builder: (context, state) => const OnboardingLanguageScreen(),
    ),
    GoRoute(
      path: '/welcome',
      name: 'welcome-story',
      builder: (context, state) => const OnboardingStoryScreen(),
    ),
    GoRoute(
      path: '/',
      name: 'home',
      builder: (context, state) => ListenableBuilder(
        listenable: Listenable.merge([
          AppSession.instance,
          AutomaticSessionRecovery.restoringSession,
          AutomaticSessionRecovery.recoveryTimedOut,
        ]),
        builder: (context, _) {
          // null = the loader. Same conditions as before; the reveal only
          // changes how the loader leaves (its exit motion over the screen).
          final Widget? screen = AutomaticSessionRecovery.restoringSession.value
            ? null
            : AutomaticSessionRecovery.recoveryTimedOut.value
                ? const LocalReadShell()
            : AppSession.instance.localReadActive
                ? const LocalReadShell()
                : AppSession.instance.localReadPresentationRestricted
                    ? null
                    : const AppShell();
          return AppBootLoaderReveal(loading: screen == null, child: screen);
        },
      ),
    ),
    GoRoute(
      path: '/onboarding/brand',
      name: 'onboarding-brand',
      builder: (context, state) => const OnboardingBrandScreen(),
    ),
    GoRoute(
      path: '/onboarding/auth',
      name: 'onboarding-auth',
      builder: (context, state) => const OnboardingAuthScreen(),
    ),
    GoRoute(
      path: '/onboarding/check',
      builder: (context, state) => SupabaseConfig.isConfigured
          ? OnboardingAccountCompletionScreen(
              client: supabase.Supabase.instance.client)
          : const OnboardingSetupScreen(),
    ),
    GoRoute(
      path: '/onboarding/setup',
      name: 'onboarding-setup',
      builder: (context, state) => const OnboardingSetupScreen(),
    ),
    GoRoute(
      path: '/onboarding/privacy',
      name: 'onboarding-privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/data-transfer',
      name: 'data-transfer',
      builder: (context, state) => DataTransferScreen(
        initialAction: state.uri.queryParameters['intent'],
      ),
    ),
    GoRoute(
      path: '/backup',
      name: 'backup',
      redirect: (context, state) => '/data-transfer',
    ),
    GoRoute(
      path: '/backup/restore',
      name: 'backup-restore',
      builder: (context, state) =>
          const RestorePromptScreen(onboardingFlow: false),
    ),
    GoRoute(
      path: '/privacy',
      name: 'privacy',
      builder: (context, state) => const PrivacyScreen(),
    ),
    GoRoute(
      path: '/delete-account',
      name: 'delete-account',
      builder: (context, state) => const DeleteAccountScreen(),
    ),
    GoRoute(
      path: '/help',
      name: 'help',
      builder: (context, state) => const HelpScreen(),
    ),
    GoRoute(
      path: '/reports',
      name: 'reports',
      builder: (context, state) => const ReportsScreen(),
    ),
    GoRoute(
      path: '/accounts',
      name: 'accounts',
      builder: (context, state) => const AccountsScreen(),
    ),
    GoRoute(
      path: '/account/:id',
      name: 'account',
      builder: (context, state) =>
          AccountDetailScreen(accountId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/announcements',
      name: 'announcements',
      builder: (context, state) => const AnnouncementsScreen(),
    ),
    GoRoute(
      path: '/subscriptions',
      name: 'subscriptions',
      builder: (context, state) => const SubscriptionsScreen(),
    ),
    // COUPONS Phase 1 — one merchant's live offers. The id is a CATALOG id, not
    // the device-local merchants.id: local ids are normalization-derived and
    // differ between users, so one could never survive a link or a
    // notification. The screen fails soft on an unknown id.
    // COUPONS Phase 4 — the savings ledger. Local-only data, so the route is
    // always safe to open: with nothing recorded it shows a calm empty state.
    GoRoute(
      path: '/savings',
      name: 'savings',
      builder: (context, state) => const SavingsScreen(),
    ),
    GoRoute(
      path: '/coupons/merchant/:merchantId',
      name: 'coupon-merchant',
      builder: (context, state) => MerchantOffersScreen(
        merchantId: state.pathParameters['merchantId'] ?? '',
      ),
    ),
    GoRoute(
      path: '/coupons',
      name: 'coupons',
      // `?highlight={slug}` focuses one offer (campaigns/notifications can link
      // straight to it). Eligibility is still enforced by the screen, so the
      // parameter can never surface an expired or ineligible offer.
      builder: (context, state) => CouponsScreen(
        highlightSlug: state.uri.queryParameters['highlight'],
      ),
    ),
    GoRoute(
      path: '/referrals',
      name: 'referrals',
      builder: (context, state) => const ReferralsScreen(),
    ),
    GoRoute(
      path: '/paste',
      name: 'paste',
      builder: (context, state) => const ManualPasteScreen(),
    ),
    GoRoute(
      path: '/capture/sms-permission',
      name: 'sms-permission',
      // SmsPermissionScreen is a SHEET body, not a page: it returns
      // Directionality > ClipRRect > MaliGlass(sheet) > Column with no
      // Scaffold and no bounded height, and its own SmsPermissionScreen
      // .showSheet supplies navySheetTheme + FractionallySizedBox. Building it
      // bare here produced an ErrorWidget the moment the route was opened —
      // found by the exhaustive control sweep, which navigates every route.
      // The route now supplies the same ancestors the screen declares it needs.
      builder: (context, state) => Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: navySheetTheme(const FractionallySizedBox(
            heightFactor: 0.82,
            alignment: Alignment.bottomCenter,
            child: SmsPermissionScreen(),
          )),
        ),
      ),
    ),
    GoRoute(
      path: '/transaction/:id',
      name: 'transaction',
      builder: (context, state) =>
          TransactionDetailsScreen(transactionId: state.pathParameters['id']!),
    ),
    GoRoute(
      path: '/cards',
      name: 'cards',
      builder: (context, state) => const MyCardsScreen(),
    ),
    GoRoute(
      path: '/card/:last4',
      name: 'card',
      builder: (context, state) =>
          CardDetailsScreen(last4: state.pathParameters['last4']!),
    ),
    GoRoute(
      path: '/budgets',
      name: 'budgets',
      builder: (context, state) => const BudgetsScreen(),
    ),
    GoRoute(
      path: '/budgets/new',
      name: 'budget-new',
      builder: (context, state) => const BudgetFormScreen(),
    ),
    GoRoute(
      path: '/budgets/:id/edit',
      name: 'budget-edit',
      builder: (context, state) => BudgetFormScreen(
        budgetId: state.pathParameters['id'],
      ),
    ),
    GoRoute(
      path: '/goals',
      name: 'goals',
      builder: (context, state) => const GoalsScreen(),
    ),
    GoRoute(
      path: '/goals/new',
      name: 'goal-new',
      builder: (context, state) => const GoalFormScreen(),
    ),
    GoRoute(
      path: '/goals/:id',
      name: 'goal-details',
      builder: (context, state) => GoalDetailsScreen(
        goalId: state.pathParameters['id']!,
      ),
    ),
    GoRoute(
      path: '/achievements',
      name: 'achievements',
      builder: (context, state) => const AchievementsScreen(),
    ),
    GoRoute(
      path: '/settings',
      name: 'settings',
      builder: (context, state) => SettingsScreen(
        showBackButton: context.canPop(),
      ),
    ),
    GoRoute(
      path: '/settings/planning-currency-repair',
      name: 'planning-currency-repair',
      builder: (context, state) => const PlanningCurrencyRepairScreen(),
    ),
    GoRoute(
      path: '/profile',
      name: 'profile',
      // v2 «بيانات حسابك»: the profile route opens the account sub-page of
      // the More hub (spec screen 23).
      builder: (context, state) => SettingsScreen(
        page: SettingsPage.account,
        showBackButton: context.canPop(),
      ),
    ),
    // A-5: QA sync diagnostics — debug builds only; no route exists in release.
    if (syncDiagnosticsAvailable())
      GoRoute(
        path: '/settings/sync-diagnostics',
        name: 'sync-diagnostics',
        builder: (context, state) => const SyncDiagnosticsScreen(),
      ),
    // Mali flagship design system review surface — debug builds only, never
    // reachable in release. See docs/MALI_DESIGN_SYSTEM.md.
    if (kDebugMode)
      GoRoute(
        path: '/design',
        name: 'design-gallery',
        builder: (context, state) => const DesignGalleryScreen(),
      ),
  ],
);
