import '../../domain/entities/transaction_entity.dart';
import '../../core/backend/auth_client_provider.dart';
import '../../core/sync/sync_health.dart';
import '../../core/sync/outbox_failure.dart';
import '../../core/sync/sync_recovery.dart';
import '../../core/sync/sync_status.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../core/backend/supabase_config.dart';
import '../../core/di/app_providers.dart';
import '../../core/observability/diagnostics.dart';
import '../../data/db/app_database.dart';
import '../../core/session/admission_authority.dart';
import '../ads/banner_ads_providers.dart';
import '../report_ads/report_ads_providers.dart';
import 'sync_cadence.dart';
import '../../data/db/financial_cache_reconcile_map.dart';
import '../../data/db/legacy_financial_cache_reconciler.dart';
import 'legacy_reconcile_domains.dart';
import '../../core/diagnostics/duplicate_trace_service.dart';
import '../../core/exporting/export_providers.dart';
import '../../core/exporting/managed_export_store.dart';
import '../../core/router/modal_route_observer.dart';
import 'app_boot_loader.dart';
import '../planning_sync/services/startup_sync_reconcile_service.dart';
import '../../core/session/app_session.dart';
import '../../core/session/rebootstrap_service.dart';
import '../../core/di/rebootstrap_providers.dart';
import '../../core/sync/sync_wakeup.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/services/notification_planner.dart';
import '../../domain/usecases/ingest_captured_message_usecase.dart';
import '../budgets/budgets_providers.dart';
import '../budgets/budgets_screen.dart';
import '../capture/capture_runtime.dart';
import '../common/top_banner.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import '../transactions/manual_transaction_sheet.dart';
import '../../core/privacy/consent_authority.dart';
import '../capture/services/capture_import_service.dart';
import '../capture/services/unbound_capture_prompt_service.dart';
import 'capture_notification_actions.dart';
import '../capture/services/captured_message_processor.dart';
import '../capture/services/capture_notification_authority.dart';
import '../capture/services/local_notification_service.dart';
import '../capture/services/notification_log_service.dart';
import '../capture/services/notification_log_sync_service.dart';
import '../capture/services/pending_notification_actions.dart';
import '../capture/services/native_capture_bridge.dart';
import '../capture/background/background_capture_drain.dart';
import '../capture/background/capture_alerts.dart';
import '../capture/services/capture_identity_metrics.dart';
import '../../core/tracking/user_activity_service.dart';
import '../cards/cards_providers.dart';
import '../onboarding/force_update_screen.dart';
import '../dashboard/dashboard_providers.dart';
import '../dashboard/dashboard_screen.dart';
import '../settings/settings_providers.dart';
import '../gamification/services/engagement_event_service.dart';
import '../gamification/services/gamification_sync_service.dart';
import '../gamification/services/achievement_unlocks.dart';
import '../gamification/services/local_achievement_service.dart';
import '../goals/goals_providers.dart';
import '../plans/plans_providers.dart';
import '../reports/reports_providers.dart';
import '../reports/reports_screen.dart';
import '../settings/settings_screen.dart';
import '../settings/delete_account_screen.dart'
    show deleteAccountAfterCompletionProvider;
import '../../core/auth/immediate_deletion_flow.dart';
import '../subscriptions/subscriptions_providers.dart';
import '../transactions/transactions_providers.dart';
import '../transactions/transactions_screen.dart';
import '../transactions/widgets/confirm_transaction_sheet.dart';
import 'celebration_runtime.dart';
import '../../core/theme/widgets/mali_glass.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/i18n/locale_provider.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/native_glass.dart';
import '../../core/theme/widgets/native_tab_bar.dart';

final shellIndexProvider = StateProvider<int>((ref) => 0);

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  late final AppLifecycleListener _lifecycleListener;
  StreamSubscription<CaptureConfirmRequest>? _confirmSubscription;
  StreamSubscription<CaptureQuickAction>? _quickActionSubscription;
  StreamSubscription<CaptureNavigationRequest>? _navigationSubscription;
  StreamSubscription<void>? _syncWakeupSubscription;
  StreamSubscription<void>? _authRearmSubscription;
  Timer? _syncDebounceTimer;
  Timer? _syncPollTimer;
  CelebrationEvent? _activeCelebration;
  Timer? _celebrationTimer;
  bool _isBottomBarVisible = true;
  bool _isConsumingSharedInput = false;
  SessionStatus? _lastSessionStatus;

  /// The process-wide drain lease shared with every other engine's drain.
  final CaptureDrainLease _drainLease = CaptureDrainLease();

  /// Set while a background-triggered pass runs: false = the OS cancelled it.
  bool Function()? _backgroundIsActive;
  BackgroundCaptureDrainRunner? _backgroundDrain;

  /// What the last leased drain pass reported (written by the pass itself).
  CaptureDrainPass? _lastDrainPass;
  CaptureDrainPass _drainPass = const CaptureDrainPass();

  /// The admission this shell was mounted under. A shell disposed after that
  /// admission ended (sign-out, Remove data, account switch) withdraws any
  /// scheduled background drain; one disposed by navigation does not.
  AdmissionAuthority? _mountAdmission;
  bool _remoteOnboardingCompletionSynced = false;
  bool _isReconcilingAfterResume = false;

  /// Post-sign-in restore gate: after a sign-out wipe the local DB holds only
  /// reseeded defaults, and offline-first screens would render those "wrong"
  /// values until the first pull replaces them under the user's eyes. While
  /// open, the root-level [appDataRestoring] loader covers the app; it drops
  /// the moment the first full sync round completes (or the DB turns out to
  /// already have data / a 20s safety timeout fires). Normal daily opens with
  /// existing data never show it — offline-first stays instant. This flag
  /// tracks whether THIS shell opened the gate, so it only ever closes its own.
  bool _openedRestoreGate = false;
  Timer? _restoreGateTimeout;

  /// Transaction ids already auto-opened (confirm sheet or a `/transaction/`
  /// route push) by a notification-driven path this session. A single
  /// notification tap can be observed by more than one of this app's
  /// overlapping routing mechanisms at once — the native pending-route queue
  /// drained in [_drainPendingNotificationRoutes], flutter_local_notifications'
  /// own cold-launch details (`CaptureRuntime.takeInitialConfirmation`/
  /// `takeInitialNavigation`), and the live [CaptureRuntime] streams — and
  /// without this guard two of them can both fire for the same tap, stacking
  /// a confirm sheet and a full transaction-details route push on top of each
  /// other (visible as the screen "loading twice"/flickering right after
  /// opening a transaction notification). Each transaction id is claimed at
  /// most once per app session; a later, genuinely separate notification for
  /// a different transaction is unaffected since ids are unique per capture.
  final Set<String> _autoNavigatedTransactionIds = {};

  /// O-LC-2: [origin] is the lifecycle a foreground callback started in. It
  /// qualifies only while still current AND equal (uid and admission epoch) to
  /// the lifecycle this shell is admitted under right now.
  bool _originIsMine(AdmissionAuthority origin) {
    if (!origin.isCurrent || !mounted) return false;
    final mine = AppSession.instance.captureLocalWorkAuthority();
    return mine != null && mine.uid == origin.uid && mine.epoch == origin.epoch;
  }

  /// Restart recovery for an immediate account deletion that was already sent
  /// or already completed remotely. Status only, current owner only (the flow
  /// captures the admitted account; another owner's receipt is unreachable), no
  /// request and no challenge, and the same egress/local-read gating as the
  /// Delete Account screen. Silent unless the deletion is confirmed complete.
  void _recoverImmediateDeletionAtStart() {
    if (!mounted || AppSession.instance.status != SessionStatus.authenticated) {
      return;
    }
    final ImmediateDeletionFlow flow;
    final void Function() afterCompletion;
    try {
      flow = ref.read(immediateDeletionFlowProvider);
      afterCompletion = ref.read(deleteAccountAfterCompletionProvider);
    } catch (_) {
      return;
    }
    unawaited(recoverImmediateDeletionAtStart(flow).then((result) {
      if (result is DeletionFlowCompleted) afterCompletion();
    }));
  }

  bool _claimAutoNavigation(String transactionId) =>
      _autoNavigatedTransactionIds.add(transactionId);

  @override
  void initState() {
    super.initState();
    _lastSessionStatus = AppSession.instance.status;
    _mountAdmission = AppSession.instance.captureLocalWorkAuthority();
    // First-use guidance (charter RC-5 Layer A). Deferred to after the first
    // frame: the shell is still building here, and the restore gate above may
    // still be covering the screen — showing a dialog into that is how a tour
    // ends up behind a loader with no way to reach it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (AppSession.instance.status != SessionStatus.authenticated) return;

      // After the restore gate has had its frame to open (see below).
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _scheduleConsentReask());
    });
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _recoverImmediateDeletionAtStart());
    AppSession.instance.addListener(_handleSessionStatusChange);
    // CAP-7: generic lock-screen text for every capture alert behind the flag.
    LocalNotificationService.instance.captureNotifyV2 = _captureNotifyV2Enabled;
    // Final push before the sign-out wipe destroys the outboxes — otherwise a
    // change made seconds before signing out is deleted un-uploaded and lost.
    AppSession.instance.configureSignOutFlush(_flushPendingForSignOut);
    if (SupabaseConfig.isConfigured &&
        AppSession.instance.status == SessionStatus.authenticated) {
      _openedRestoreGate = true;
      // Deferred one frame: initState runs during the parent's build, and the
      // gate's ValueListenableBuilder sits above this widget — setting the
      // notifier synchronously here is a setState-during-build error.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _openedRestoreGate) appDataRestoring.value = true;
      });
      unawaited(_resolveRestoreGate());
      _restoreGateTimeout = Timer(const Duration(seconds: 20), () {
        // Safety: never trap the user behind the loader (e.g. offline).
        _closeRestoreGate();
      });
    }
    _lifecycleListener = AppLifecycleListener(onResume: _onResume);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_reconcileAchievements(announce: false));
    });
    // O-LC-2: events carry the lifecycle they were raised in; this shell acts
    // only for events of ITS OWN lifecycle (a shell mounted for a successor never
    // inherits a stale callback).
    _confirmSubscription = CaptureRuntime.instance.confirmEvents.listen(
      (request) {
        if (!_originIsMine(request.origin)) return;
        unawaited(
            _openConfirmSheet(request.transactionId, origin: request.origin));
      },
    );
    _quickActionSubscription =
        CaptureRuntime.instance.quickActionRequests.listen(
      _applyQuickAction,
    );
    _navigationSubscription = CaptureRuntime.instance.navigationEvents.listen(
      (request) {
        if (!_originIsMine(request.origin)) return;
        _handleNotificationRoute(request.route);
      },
    );
    // A-5: an authenticated session / token refresh re-arms auth-parked rows.
    _authRearmSubscription = bindAuthRearm(
      AuthSessionValid.events,
      ref.read(syncRecoveryServiceProvider),
    );
    _syncWakeupSubscription = SyncWakeup.events.listen((_) {
      // Local activity → return the poll cadence to its base interval so the app
      // is responsive; the 750ms debounce coalesces rapid local commits.
      _syncCadence.recordActivity();
      _syncDebounceTimer?.cancel();
      // Local activity is a background trigger: gated by the offline gate so a
      // burst of offline edits coalesces into one pending intent rather than
      // each firing a doomed sync.
      _syncDebounceTimer = Timer(
        const Duration(milliseconds: 750),
        () => _runLedgerSync(),
      );
      _scheduleAdaptivePoll();
    });
    // Pull remote changes made on another device and retry offline outbox items.
    // ADAPTIVE cadence (MALI-029): a self-rescheduling timer that widens the
    // interval after consecutive idle polls (30s → up to 5min) so an idle/offline
    // app stops polling — and burning outbox retries — every 30s; local activity
    // or a lifecycle resume resets it to the base interval.
    _scheduleAdaptivePoll();
    NativeCaptureBridge.setPendingMessagesHandler(() async {
      if (!mounted) return;
      await _consumeSharedInput();
    });
    NativeCaptureBridge.setApnsTokenUpdatedHandler((token) async {
      try {
        await ref
            .read(captureDeviceRegistrationServiceProvider)
            .syncApnsToken(token);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Capture] APNs token sync skipped: $error');
        }
      }
    });
    NativeCaptureBridge.setNotificationRouteHandler(() async {
      if (!mounted) return;
      await _drainPendingNotificationRoutes();
    });
    // The OS-scheduled background drain (Android WorkManager, iOS BGTask)
    // runs THIS shell's drain: same provider graph, same account scope, same
    // admission checks, same lease and retry ledger as the foreground.
    NativeCaptureBridge.setBackgroundDrainHandler(
      () async => (await _runBackgroundTriggeredDrain()).name,
      cancel: () => _backgroundDrain?.cancel(),
    );
    unawaited(NativeCaptureBridge.setBackgroundDrainReady(true));

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final work = AdmittedLocalWork.capture(ref);
      if (work == null) return;
      // Defensive: the router should already have redirected away from this
      // shell for a non-authenticated status before it ever mounted, but
      // never run Supabase-primary startup work without re-confirming.
      if (!await _revalidateAuthSession()) return;
      if (!work.current) return;
      unawaited(_syncRemoteOnboardingCompletion());
      await syncCatalog(ref, force: true, work: work);
      if (!work.current) return;
      // Same coordinated path as app resume — drains any Confirm/Dismiss
      // notification action applied while the app was closed, repairs any
      // dirty Supabase-mirror cache, and refreshes financial providers.
      await _reconcileDataAfterResume(work: work);
      if (!work.current) return;
      unawaited(UserActivityService.ping()); // cold start — always writes
      await _syncNativeCaptureState();
      if (!work.current) return;
      unawaited(_linkCaptureDeviceToUser());
      await _consumeSharedInput();
      if (!work.current) return;
      // Cold start is a recovery-eligible trigger (always attempt).
      unawaited(_runLedgerSync(recoveryProbe: true));
      await _drainPendingNotificationRoutes();
      if (!work.current) return;
      if (!await _syncEngagement(originalWork: work)) return;
      if (!work.current) return;
      // Cold-start work is a long await chain inside initState's closure, and
      // the shell is a route: opening a top-level page disposes it part-way
      // through, after which this read throws. Nothing below is required for
      // correctness on this pass — the next resume repeats it.
      if (!mounted) return;
      unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
      // R4 §11: cold-start UMP gathering — the primary fix for the missing
      // production caller. Fire-and-forget, fail-open, once per session.
      unawaited(_orchestrateReportAdsConsent());
      _drainCelebrations();
      final initialTransactionId =
          CaptureRuntime.instance.takeInitialConfirmation();
      if (initialTransactionId != null && mounted) {
        await _openConfirmSheet(initialTransactionId);
      }
      final initialRoute = CaptureRuntime.instance.takeInitialNavigation();
      if (initialRoute != null && mounted) {
        _handleNotificationRoute(initialRoute);
      }
    });
  }

  VoidCallback? _reaskGateListener;

  /// §4.6 "a new device re-asks": asks the consent question once the root restore
  /// loader is gone, so the sheet is never opened behind it.
  void _scheduleConsentReask() {
    if (!mounted) return;
    if (!appDataRestoring.value) {
      unawaited(maybeReaskConsent(context, ref));
      return;
    }
    void onChange() {
      if (appDataRestoring.value) return;
      appDataRestoring.removeListener(onChange);
      _reaskGateListener = null;
      if (mounted) unawaited(maybeReaskConsent(context, ref));
    }

    _reaskGateListener = onChange;
    appDataRestoring.addListener(onChange);
  }

  @override
  void dispose() {
    final reask = _reaskGateListener;
    if (reask != null) appDataRestoring.removeListener(reask);
    AppSession.instance.removeListener(_handleSessionStatusChange);
    AppSession.instance.configureSignOutFlush(null);
    _restoreGateTimeout?.cancel();
    if (_openedRestoreGate) {
      _openedRestoreGate = false;
      appDataRestoring.value = false; // never leave the root loader stuck up
    }
    _celebrationTimer?.cancel();
    _confirmSubscription?.cancel();
    _quickActionSubscription?.cancel();
    _navigationSubscription?.cancel();
    _syncWakeupSubscription?.cancel();
    _authRearmSubscription?.cancel();
    _syncDebounceTimer?.cancel();
    _syncPollTimer?.cancel();
    NativeCaptureBridge.setPendingMessagesHandler(null);
    NativeCaptureBridge.setApnsTokenUpdatedHandler(null);
    NativeCaptureBridge.setNotificationRouteHandler(null);
    NativeCaptureBridge.setBackgroundDrainHandler(null);
    unawaited(NativeCaptureBridge.setBackgroundDrainReady(false));
    _backgroundDrain?.cancel();
    final admission = _mountAdmission;
    if (admission != null && !admission.isCurrent) {
      // The account this shell drained for is gone (sign-out, Remove data,
      // account switch): nothing scheduled for it may run later.
      unawaited(NativeCaptureBridge.cancelBackgroundCaptureDrain());
    }
    _lifecycleListener.dispose();
    super.dispose();
  }

  /// Centralized reaction to any session-status change while this shell is
  /// mounted — covers both an explicit sign-out (Settings) and the
  /// auth-required recovery path (`captureAuthRequiredFailure`) in one place,
  /// satisfying "financial providers invalidated" for either trigger without
  /// duplicating the provider list at each call site. The router redirects
  /// away from this shell on the same notification; invalidating here just
  /// ensures no stale cached data from the previous session is still held by
  /// the (app-lifetime) ProviderScope for whoever signs in next.
  void _handleSessionStatusChange() {
    final now = AppSession.instance.status;
    final wasAuthenticated = _lastSessionStatus == SessionStatus.authenticated;
    _lastSessionStatus = now;
    // R4 §7: drop the in-memory report-export entitlement cache on ANY session
    // transition (sign-in / sign-out / account switch / expiry) so one user's
    // ad-free decision can never leak into another session.
    if (mounted) ref.read(reportEntitlementResolverProvider).clear();
    // Any session change (sign-in or sign-out) re-arms the one-shot reconcile
    // so a freshly signed-in identity backfills its own local data once.
    _didReconcile = false;
    // MALI-029 ownership: bump the admission generation so any in-flight or
    // queued sync run captured under the previous owner is no longer admitted,
    // and cancel the old owner's poll timer. A same-UID relogin gets a fresh
    // generation too, so stale scheduled work can never execute under it. Re-arm
    // the poll for the (new) owner only while authenticated; a sign-out leaves it
    // cancelled.
    _syncGate.invalidate();
    // A background-triggered drain belongs to the admission it started under.
    _backgroundDrain?.cancel();
    if (now != SessionStatus.authenticated) {
      unawaited(NativeCaptureBridge.cancelBackgroundCaptureDrain());
    }
    _resumeCoalescer.reset(); // the new owner's first resume must fully refresh
    _syncPollTimer?.cancel();
    if (now == SessionStatus.authenticated && mounted) {
      _scheduleAdaptivePoll();
    }
    if (wasAuthenticated && now != SessionStatus.authenticated) {
      if (!mounted) return;
      _invalidateFinancialProviders();
      ref.read(activeAccountIdProvider.notifier).state = null;
      if (kDebugMode) {
        debugPrint(
          '[AppShell] session status → $now: financial providers invalidated',
        );
      }
    }
  }

  Future<void> _onResume() async {
    final work = AdmittedLocalWork.capture(ref);
    if (work == null) return;
    unawaited(_reconcileAchievements());
    // Resume = the user is back → reset the poll cadence to its base interval.
    _syncCadence.recordActivity();
    _scheduleAdaptivePoll();
    // A refresh token can be revoked/expire while backgrounded with no
    // auth-state event ever delivered until something touches the client
    // again — re-check before running any Supabase-primary-dependent work.
    if (!await _revalidateAuthSession()) return;
    if (!work.current) return;
    // B2-C — coalesce the NON-CRITICAL, idempotent refreshes so rapid repeated
    // resumes don't re-run them each time. Safety-critical work below (reconcile,
    // capture import of NEW shared input, the SyncGate-coalesced sync) always
    // runs regardless.
    final runNonCritical =
        _resumeCoalescer.shouldRunNonCritical(DateTime.now());
    unawaited(_syncRemoteOnboardingCompletion());
    // Same disposal race as below: an await preceded this — syncCatalog reads ref immediately.
    if (!mounted) return;
    // A-5: a cached `unsupported`/`unknown` server capability is re-probed on
    // resume (throttled to 15 min inside the service) so awaiting-FX rows parked
    // before the server upgrade drain without an app restart. Consent-gated.
    unawaited(ref
        .read(serverCapabilitiesServiceProvider)
        .reprobeIfStale()
        .then((_) {})
        .catchError((_) {}));
    // Same for the planning-currency capability (0077): re-probed on resume,
    // throttled inside, consent-gated, never throws into the resume path.
    unawaited(ref
        .read(planningCurrencyCapabilityProbeProvider)
        .reprobeIfStale()
        .then((_) {})
        .catchError((_) {}));
    if (runNonCritical) await syncCatalog(ref, work: work);
    if (!work.current) return;
    if (runNonCritical) {
      // R4 §7/§11/§21: warm the report-export entitlement decision on resume,
      // then run the one UMP orchestration point (gather consent → refresh the
      // privacy-options state → gated preload) so no ad is ever preloaded
      // before UMP permits requests. Fire-and-forget.
      // Same disposal race as below: an await preceded this — this read is synchronous.
      if (!mounted) return;
      unawaited(ref
          .read(reportEntitlementResolverProvider)
          .refresh()
          .then((_) => _orchestrateReportAdsConsent()));
    }
    // Reconciles writes that landed through a connection other than this
    // shell's live `appDatabaseProvider` instance while the app was
    // backgrounded — background notification Confirm/Dismiss actions open
    // their own `AppDatabase` connection (local_notification_service.dart),
    // so `dbRevisionProvider` never ticks for them on its own. See
    // docs/STALE_UI_ROOT_CAUSE_REPORT.md.
    await _reconcileDataAfterResume(work: work);
    if (!work.current) return;
    unawaited(UserActivityService.ping()); // resume — writes only if > 30 min
    if (runNonCritical) await _syncNativeCaptureState();
    if (!work.current) return;
    // Always: a capture may have arrived while backgrounded — never coalesce it.
    await _consumeSharedInput();
    // Resume is a recovery-eligible trigger (always attempt).
    unawaited(_runLedgerSync(recoveryProbe: true));
    await _drainPendingNotificationRoutes();
    if (!await _syncEngagement(originalWork: work)) return;
    // Resume work is a long await chain and the shell is a route: opening a
    // top-level page (/accounts, /goals, …) disposes it part-way through, and
    // every `ref` use below then throws. This method has no try, so that
    // escaped as an unhandled async error instead of resume work simply
    // stopping. Nothing here is required for correctness on this pass — the
    // next resume repeats it.
    if (!mounted) return;
    unawaited(ref.read(notificationJourneyServiceProvider).evaluate());
    // MALI-065n: bounded-lease sweep of any export temp file a crash orphaned
    // while backgrounded — never touches one still inside its lease (an
    // in-flight share). Housekeeping → coalesced with the other non-critical work.
    if (runNonCritical) {
      unawaited(ref
          .read(managedExportStoreProvider)
          .sweep(olderThan: ManagedExportStore.defaultLease));
    }
    _drainCelebrations();
  }

  /// R4 §11 — the ONE session-level UMP orchestration point. Gathers UMP consent
  /// (idempotent per session via [sessionAdConsentProvider]), refreshes the
  /// Settings privacy-options state, then — and only then — allows a gated
  /// interstitial preload. UMP is the sole ad-consent authority; nothing is
  /// persisted here.
  ///
  /// Fully fail-open: it never blocks startup/resume, never throws, and a UMP
  /// failure simply leaves ads not requestable (the export still generates).
  /// Consent is gathered whenever an ad may actually be served — i.e. the flag
  /// is on — or in any non-release build, so a human R6 test can exercise the
  /// flow without flipping the staging flag. A release build with the flag off
  /// gathers nothing (no consent UI for a disabled feature).
  Future<void> _orchestrateReportAdsConsent() async {
    if (!mounted) return;
    // ANY ads product, not just the report interstitial. Both reviewers of the
    // banner plan found the same latent bug here independently: this used to
    // read only `reportAdsEnabledProvider`, so a release with banners ON and
    // report ads OFF would never gather UMP consent, `canRequestAds()` would
    // stay false forever, and banners would fail closed with nothing anywhere
    // saying why.
    final adsMayServe = ref.read(reportAdsEnabledProvider) ||
        ref.read(bannerAdsEnabledProvider);
    if (kReleaseMode && !adsMayServe) return;
    try {
      await ref.read(sessionAdConsentProvider).ensureGathered();
      if (!mounted) return;
      // Settings entry now reflects the freshly-known UMP requirement (§4).
      ref.invalidate(adPrivacyOptionsRequiredProvider);
      // ...and so must the banner gates. Consent has just been gathered; an
      // eligibility answer computed before that would have cached "no consent"
      // for the session. Entitlement is invalidated alongside it because this
      // runs on resume, which is exactly when an ad-free reward earned
      // elsewhere becomes true.
      ref.invalidate(bannerConsentProvider);
      ref.invalidate(bannerEntitlementProvider);
      // Only after UMP has been gathered is a preload allowed (§2.5);
      // maybePreload re-checks flag + config + entitlement + canRequestAds.
      await ref.read(reportExportCoordinatorProvider).maybePreload();
    } catch (_) {
      // Fail-open: consent/preload failure must never break the app.
    }
  }

  /// Returns false (recovery already triggered, router about to redirect
  /// away from this shell) when the live Supabase session turned out to be
  /// invalid — callers must stop running further Supabase-primary work.
  ///
  /// F2: acts only for a mounted shell whose session is currently
  /// `authenticated` ([AppSession.revalidateForShell]) — not merely "not
  /// expired", which also accepts `needsOnboarding` (what a Remove data leaves
  /// while its scope remounts).
  Future<bool> _revalidateAuthSession() async {
    if (!mounted) return false;
    final stillAuthenticated = await AppSession.instance
        .revalidateForShell(ref.read(authClientProvider));
    return stillAuthenticated && mounted;
  }

  Future<void> _syncRemoteOnboardingCompletion() async {
    if (_remoteOnboardingCompletionSynced) return;
    final synced = await AppSession.instance.syncRemoteOnboardingCompletion();
    if (synced) _remoteOnboardingCompletionSynced = true;
  }

  /// Financial-data providers that may hold stale results after a write that
  /// bypassed this shell's live `dbRevisionProvider` connection (background
  /// notification actions, a repaired dirty mirror, or a session change).
  /// Shared by [_handleSessionStatusChange] and [_reconcileDataAfterResume]
  /// so both stay in sync with one list instead of two.
  void _invalidateFinancialProviders() {
    ref.invalidate(accountsProvider);
    ref.invalidate(transactionsListProvider);
    ref.invalidate(billsViewProvider);
    ref.invalidate(budgetsViewProvider);
    ref.invalidate(goalsListProvider);
    ref.invalidate(savedBillsProvider);
    ref.invalidate(plansWithSpentProvider);
    ref.invalidate(smartInboxItemsProvider);
    ref.invalidate(cardSummariesProvider);
    ref.invalidate(subscriptionsProvider);
    ref.invalidate(reportsProvider);
    ref.invalidate(dashboardDataProvider);
  }

  /// Coordinated reconciliation for writes that `dbRevisionProvider` cannot
  /// see on its own — background notification Confirm/Dismiss actions write
  /// through a separate `AppDatabase` connection
  /// (local_notification_service.dart's `_backgroundTapHandler`), and a
  /// Supabase-primary mirror-write failure only marks the cache dirty
  /// without ticking the revision counter. Runs on both initial startup and
  /// every app resume (see `initState` and [_onResume]) so the two paths
  /// can't drift apart. See docs/STALE_UI_ROOT_CAUSE_REPORT.md.
  ///
  /// The broad safety-net invalidation only fires when step A or B actually
  /// found something to reconcile — an idle resume with no pending
  /// background actions and no dirty cache does not force every screen back
  /// into a loading state; `dbRevisionProvider` already covers any write
  /// that landed through this shell's own live connection.
  ///
  /// Guarded against re-entry: a second resume firing while the first is
  /// still running is a no-op rather than a duplicate reconciliation pass.
  Future<void> _reconcileDataAfterResume({AdmittedLocalWork? work}) async {
    work ??= AdmittedLocalWork.capture(ref);
    if (work == null || !work.current) return;
    if (_isReconcilingAfterResume) {
      if (kDebugMode) {
        debugPrint('[Reconcile] already running — skipping duplicate trigger');
      }
      return;
    }
    _isReconcilingAfterResume = true;
    final start = DateTime.now();
    if (kDebugMode) debugPrint('[Reconcile] start');
    try {
      // A. Pending notification actions — idempotent (PendingNotificationActions
      // .drain() empties the queue first; _applyQuickAction tolerates a
      // confirm/delete that already landed via the background path).
      final drainedActions = await _drainPendingNotificationActions(work);
      if (!work.current) return;
      // B. (MALI-034) The recurring Supabase-authoritative cache repair was
      // retired; a legacy dirty marker is now reconciled IN-SLOT during the
      // normal push/pull sync body (see _runLedgerSyncBody), which writes
      // through the live AppDatabase connection and ticks dbRevisionProvider.
      // C. Explicit invalidation as a safety net for writes that landed
      // through a connection dbRevisionProvider can't observe — only when
      // A actually found something (see doc comment above).
      final needsInvalidation = drainedActions;
      if (needsInvalidation) {
        _invalidateFinancialProviders();
      }
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Reconcile] success (${ms}ms) drainedActions='
            '$drainedActions invalidated=$needsInvalidation');
      }
    } catch (error, stackTrace) {
      if (kDebugMode) {
        debugPrint('[Reconcile] failed: $error\n$stackTrace');
      }
    } finally {
      _isReconcilingAfterResume = false;
    }
  }

  Future<void> _syncNativeCaptureState() async {
    try {
      await ref
          .read(captureDeviceRegistrationServiceProvider)
          .syncBackendState();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] native state sync skipped: $error');
      }
    }
  }

  Future<void> _linkCaptureDeviceToUser() async {
    try {
      await ref
          .read(captureDeviceRegistrationServiceProvider)
          .linkToCurrentUser();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] device link skipped: $error');
      }
    }
  }

  // MALI-029 cadence — adaptive backoff when idle/offline + coalescing of
  // overlapping run requests (a request during a run fires exactly one follow-up
  // instead of being dropped). See sync_cadence.dart (unit-tested).
  final SyncCadence _syncCadence = SyncCadence();
  final SyncCoalescer _syncCoalescer = SyncCoalescer();

  /// MALI-029 offline/ownership gate. Since there is no platform connectivity
  /// source, reachability is inferred from the outbox network-stall signal after
  /// each run; sign-out/relogin bumps its generation so old-owner scheduled work
  /// can never execute under a new owner. See sync_cadence.dart (unit-tested).
  final SyncGate _syncGate = SyncGate();

  /// B2-C — coalesces non-critical resume refreshes (catalog / native capture
  /// state / export sweep) so rapid repeated resumes don't re-run them.
  final ResumeCoalescer _resumeCoalescer = ResumeCoalescer();

  /// Whether the one-shot local→server reconcile has run for the current
  /// session. Re-armed on any session change (see [_handleSessionStatusChange]).
  bool _didReconcile = false;

  /// Whether the read-only duplicate trace has printed this session (debug).
  bool _didDupTrace = false;

  /// Called unawaited on every resume — guarded so a resume firing again
  /// before the previous sync round finished doesn't run the ledger/smart
  /// inbox/planning/gamification sync engines concurrently with themselves.
  /// Drops the restore gate immediately when the local DB already holds real
  /// data (normal daily open) — the overlay then never gets a visible frame.
  /// After a sign-out wipe the transactions table is empty, so the gate stays
  /// up until the first sync round completes.
  Future<void> _resolveRestoreGate() async {
    try {
      final row = await ref
          .read(appDatabaseProvider)
          .customSelect('SELECT EXISTS(SELECT 1 FROM transactions) AS d')
          .getSingle();
      if (row.read<int>('d') != 0) _closeRestoreGate();
    } catch (_) {
      _closeRestoreGate();
    }
  }

  void _closeRestoreGate() {
    _restoreGateTimeout?.cancel();
    _restoreGateTimeout = null;
    if (!_openedRestoreGate) return;
    _openedRestoreGate = false;
    appDataRestoring.value = false;
    // Everything the pull imported must render fresh in one shot.
    if (mounted) _invalidateFinancialProviders();
    unawaited(_reconcileAchievements(announce: false));
  }

  Future<void> _reconcileAchievements({bool announce = true}) async {
    if (!mounted || _openedRestoreGate) return;
    final work = AdmittedLocalWork.capture(ref);
    if (work == null) return;
    bool current() => work.current && !_openedRestoreGate;
    try {
      final earned = await work.local(() => LocalAchievementService(
            work.database,
          ).reconcile(now: DateTime.now(), isCurrent: current));
      if (announce && earned.isNotEmpty && current()) {
        await work.local(() => notifyAchievementUnlocks(
              work.database, earned, isCurrent: current,
            ));
      }
    } on StaleAdmissionException {
      // The owner changed while evaluating the last batch.
    } catch (error) {
      if (kDebugMode) debugPrint('[AppShell] badge reconcile skipped: $error');
    }
  }

  /// Push-only flush run by [AppSession.signOut] right before the wipe (no
  /// pulls — we are leaving this identity, we only need pending local changes
  /// to reach the server so they aren't destroyed with the outboxes).
  Future<void> _flushPendingForSignOut() async {
    // MALI-053n: flush EVERY outbox — including the child entities (goal
    // contributions / bill payments / plan links via PlanningChildSyncService),
    // smart-inbox status, notification log, and sender mappings — so pending
    // local changes reach the server before the wipe deletes the queues. Each
    // attempt is best-effort and independent: one offline/failed queue must not
    // skip the rest. A failure/timeout here is NEVER treated as a successful
    // sync — the sign-out flow re-checks the unsynced inventory afterward.
    final work = AdmittedLocalWork.capture(ref);
    if (work == null) return;
    final generation = _syncGate.generation;
    final notificationPhase = SyncPhaseBinding();
    bool originalCurrent() =>
        mounted && _syncGate.admits(generation) && work.current;
    notificationPhase.bind(_NotificationCallerLifecycle(work, originalCurrent));
    final startupPhase = SyncPhaseBinding();
    startupPhase.bind(_NotificationCallerLifecycle(work, originalCurrent));
    var stopped = false;
    Future<void> attempt(Future<void> Function() push) async {
      if (stopped || !originalCurrent()) {
        stopped = true;
        return;
      }
      try {
        await push();
      } on AccountFenceDeliveryCancellation {
        stopped = true;
      } catch (_) {
        // Re-checked by the unsynced inventory; do not block the other queues.
      }
    }

    // Audit H-3: the outbox pushes below can only flush QUEUED intents. Rows
    // that never reached the cloud and were never queued (the legacy /
    // failed-backfill class) have no outbox entry, so pushing does nothing for
    // them. Give them a real chance to persist before the user is asked to
    // discard anything — this is the retry the sign-out path was missing.
    await attempt(() async {
      // Bounded: the whole flush has a 6 s hard timeout (AppSession), which
      // cannot cancel running work. A cooperative 3 s budget stops the backfill
      // cleanly; whatever remains is NOT claimed as synced — the sign-out flow's
      // unsynced-inventory re-check surfaces it in the existing warning dialog.
      await ref
          .read(startupSyncReconcileServiceProvider)
          .run(timeBudget: const Duration(seconds: 3), phase: startupPhase);
    });
    await attempt(() async {
      await ref.read(accountsPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(planningPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(ledgerPushServiceProvider).push();
    });
    await attempt(() async {
      await ref.read(planningChildSyncServiceProvider).sync();
    });
    await attempt(() async {
      await ref.read(smartInboxSyncServiceProvider).push();
    });
    await attempt(() async {
      final outcome = await ref
          .read(notificationLogSyncServiceProvider)
          .syncWithPhase(notificationPhase);
      if (outcome == NotificationUploadOutcome.deferred) stopped = true;
    });
    if (!originalCurrent() ||
        (notificationPhase.isBound && !notificationPhase.isCurrent)) {
      stopped = true;
    }
    await attempt(() async {
      await ref.read(senderBankMappingSyncServiceProvider)?.sync();
    });
  }

  /// Schedules the next background poll using the adaptive [SyncCadence] delay,
  /// rescheduling itself after each fire. Each fire counts as an idle poll
  /// (widening the next interval); a wakeup/resume resets the cadence to base.
  void _scheduleAdaptivePoll() {
    _syncPollTimer?.cancel();
    _syncPollTimer = Timer(_syncCadence.nextDelay(), () {
      _syncCadence.recordIdlePoll();
      // The periodic poll is the sole auto-recovery probe: it runs even while the
      // gate believes we are offline, so a returned connection is re-detected.
      unawaited(_runLedgerSync(recoveryProbe: true));
      unawaited(_drainQueuedCapturesOnPoll());
      if (mounted) _scheduleAdaptivePoll();
    });
  }

  /// Foreground-only capture recovery on the adaptive poll: when the native
  /// queue still holds captures (an upload that failed while offline, an SMS
  /// that arrived while the app is on screen), run the same drain a resume
  /// runs. The timer exists only while this shell is mounted, so nothing here
  /// runs in the background. The drain re-reads consent and the egress gates
  /// for every message and backs off per item — a returned connection only
  /// lets an already-authorized retry succeed; it authorizes nothing itself.
  /// An empty queue, or one whose items are all backing off, costs one local
  /// peek and no network request.
  Future<void> _drainQueuedCapturesOnPoll() async {
    if (!mounted || AdmittedLocalWork.capture(ref) == null) return;
    try {
      final queued = await NativeCaptureBridge.peekPendingSharedMessages();
      if (queued.isEmpty || !mounted) return;
      // Items still inside their retry backoff do not trigger a drain: a
      // capture that is waiting costs no request until it is due again.
      final retryLedger = ref.read(captureRetryLedgerProvider);
      var anyDue = false;
      for (final message in queued) {
        final id = message.id?.trim();
        if (id == null || id.isEmpty || await retryLedger.isDue(id)) {
          anyDue = true;
          break;
        }
      }
      if (!anyDue || !mounted) return;
      await _consumeSharedInput();
    } on NativeCaptureReadException {
      // Unreadable is not empty: nothing was touched; the next tick retries.
      if (mounted) _reportCaptureQueueRead(failed: true);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Capture] poll drain skipped: ${error.runtimeType}');
      }
    }
  }

  bool _captureReadErrorShown = false;

  /// A native queue that cannot be READ is an error, not an empty queue. The
  /// drain wrote and acknowledged nothing; the next resume / poll retries. The
  /// user is told once per failure streak (not on every poll tick).
  void _reportCaptureQueueRead({required bool failed}) {
    if (!failed) {
      _captureReadErrorShown = false;
      return;
    }
    if (_captureReadErrorShown || !mounted) return;
    _captureReadErrorShown = true;
    showTopError(context, context.l10n.captureQueueReadFailed);
  }

  /// Android: tells the user once when the durable queue had to refuse a
  /// capture (queue at its bound, or the store could not be written), and logs
  /// the counts. Counts only — the refused message itself was never stored.
  Future<void> _surfaceAndroidQueueRefusals() async {
    final health = await NativeCaptureBridge.androidCaptureQueueHealth();
    if (health == null) return;
    if (health.refusedFull > 0 ||
        health.notPersisted > 0 ||
        health.quarantined > 0) {
      Diag.log(
          '[Capture]',
          'android_queue size=${health.size}/${health.capacity} '
              'refused_full=${health.refusedFull} '
              'not_persisted=${health.notPersisted} '
              'quarantined=${health.quarantined}');
    }
    if (health.unseen <= 0 || !mounted) return;
    showTopError(context, context.l10n.captureQueueNotSaved);
    await NativeCaptureBridge.acknowledgeAndroidCaptureQueueNotice();
  }

  /// Android: tells the signed-in account, once, that its OWN automatic SMS
  /// capture was turned back on when it signed in again (the opt-in is
  /// remembered per account; another account never inherits it). Native
  /// answers true only for the active owner whose remembered opt-in it
  /// restored and only while capture is effective (RECEIVE_SMS still granted),
  /// and clears the notice when asked. A background-triggered pass, or an app
  /// not in the foreground, does not ask, so the notice waits to be seen.
  Future<void> _surfaceAndroidCaptureRestored() async {
    if (_backgroundIsActive != null) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    final uid = AppSession.instance.captureLocalWorkAuthority()?.uid;
    if (uid == null) return;
    if (!await NativeCaptureBridge.consumeCaptureRestoredNotice(uid)) return;
    if (!mounted) return;
    // The Settings switch renders from the platform: re-read it.
    ref.invalidate(captureCapabilitiesProvider);
    showTopInfo(context, context.l10n.smsAutoCaptureRestoredNotice);
  }

  Future<void> _runLedgerSync(
      {bool recoveryProbe = false, bool manual = false}) async {
    // MALI-029 offline gate: a plain background/local-activity trigger while
    // offline is coalesced into ONE pending intent instead of firing a doomed
    // remote sync that would burn outbox retries. Manual (user) and recovery
    // probes (resume/periodic poll) always run so connectivity can be detected.
    if (!_syncGate.shouldRun(manual: manual, recoveryProbe: recoveryProbe)) {
      return;
    }
    // Coalesce: if a run is already in flight, remember the request and let the
    // in-flight run fire exactly one follow-up when it finishes (never a queue of
    // duplicate concurrent syncs, never a dropped request).
    if (!_syncCoalescer.requestRun()) return;
    final gen = _syncGate.generation;
    // A-5: the status surface shows "Syncing…" while a run is in progress.
    SyncRunState.instance.begin();
    try {
      do {
        try {
          await _runLedgerSyncBody(gen);
        } on StateError catch (_) {
          // The body holds ~7 `ref` uses across as many awaits; the shell is a
          // route and can be disposed under any of them. Guarding each one is
          // whack-a-mole, and deciding on `mounted` here is exact: disposed means
          // stop this cycle (the outbox is durable, the next cycle retries),
          // while a StateError raised while still mounted is a real bug and must
          // keep propagating.
          if (mounted) rethrow;
          if (kDebugMode) {
            debugPrint('[LedgerSync] stopped: shell disposed mid-cycle');
          }
        } finally {
          // First completed round after sign-in: the pull has landed — reveal the
          // real data in one shot instead of defaults morphing under the user.
          _closeRestoreGate();
        }
      } while (_syncCoalescer.finishRun());
    } finally {
      SyncRunState.instance.end();
    }
    // Infer reachability from the outbox's own network-stall signal (there is no
    // platform connectivity source) so the gate can go offline / recover. Skip
    // when the owner changed mid-run — the reading would belong to a new owner.
    if (_syncGate.admits(gen)) {
      final reached = !await _networkStalledOutbox();
      _syncGate.recordReachability(reachedNetwork: reached);
    }
  }

  /// Cheap, no-network reachability signal: true when a financial outbox still
  /// holds pending items whose last push failed with a transient NETWORK error —
  /// i.e. the push services just experienced "offline". Server 5xx / auth / rate
  /// limit map to other failure classes and are deliberately NOT treated as
  /// offline.
  Future<bool> _networkStalledOutbox() async {
    try {
      final db = ref.read(appDatabaseProvider);
      for (final table in const [
        'ledger_sync_outbox',
        'planning_sync_outbox'
      ]) {
        final row = await db
            .customSelect(
              "SELECT 1 AS x FROM $table WHERE status = 'pending' "
              "AND failure_class = 'transientNetwork' LIMIT 1;",
            )
            .getSingleOrNull();
        if (row != null) return true;
      }
    } catch (_) {
      // A read failure must not wedge the gate offline — assume reachable.
    }
    return false;
  }

  Future<void> _runLedgerSyncBody(int gen) async {
    // Same as _syncEngagementBody: awaited from a chain that can outlive the
    // shell, so guard on entry as well as after each await below.
    if (!mounted) return;
    // MALI-029 ownership guard: if the owner changed (sign-out / relogin) since
    // this run was scheduled, abort before doing any work — old-owner sync must
    // not write or refresh under a new owner. Sub-services also fail-safe (no
    // auth user id after sign-out); this is the belt-and-braces entry check.
    if (!_syncGate.admits(gen)) return;
    // The ORIGINAL admitted work is captured synchronously, before the first
    // await below, and `gen` stays the generation this run was scheduled under.
    final work = AdmittedLocalWork.capture(ref);
    bool originalCurrent() =>
        mounted && _syncGate.admits(gen) && work != null && work.current;
    SyncPhaseBinding? reconcilePhase;
    if (work != null) {
      reconcilePhase = SyncPhaseBinding();
      reconcilePhase.bind(_NotificationCallerLifecycle(work, originalCurrent));
    }
    // WP-7: an epoch change rebootstraps the replica (behind `replica_epoch`);
    // egress is frozen while one is in progress.
    final uid = supabase.Supabase.instance.client.auth.currentUser?.id;
    final trigger = ref.read(rebootstrapTriggerProvider);
    if (trigger != null && uid != null) {
      final outcome = await trigger.check(uid);
      if (outcome != RebootstrapOutcome.notNeeded) return;
    }
    if (ReplicaFreeze.instance.frozen) return;
    // Reconcile local accounts/transactions that never reached Supabase BEFORE
    // the normal push/pull, so back-filled rows are marked synced and the
    // outbox path takes over cleanly. One-shot per session; the service guards
    // itself to be cheap when nothing is pending. On transient failure we leave
    // the flag unset so the next cycle retries.
    if (!_didReconcile) {
      if (!originalCurrent()) return;
      final ReconcileOutcome outcome;
      try {
        outcome = await ref
            .read(startupSyncReconcileServiceProvider)
            .run(phase: reconcilePhase);
      } on AccountFenceDeliveryCancellation {
        // A typed stop ends this body; `_didReconcile` stays unlatched.
        return;
      }
      // The original lifetime may have ended during the run: neither latch nor
      // continue the rest of this body on it.
      if (!originalCurrent()) return;
      // Audit H-1: a PARTIAL reconcile must retry too. Latching the one-shot
      // flag on anything short of proven-complete meant a half-finished
      // backfill was never attempted again this session, while the unresolved
      // rows stayed invisible to the pre-sign-out inventory.
      if (!outcome.shouldRetry) _didReconcile = true;
    }
    // A-4b: record sync intent for server-backed rows a bypass writer left
    // `pending` with no outbox row, BEFORE the push/pull phases (consent and
    // owner rules are enforced inside). Never blocks the cycle.
    try {
      await ref.read(pendingSyncReconcilerProvider).run();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PendingSync] reconcile skipped: ${error.runtimeType}');
      }
    }
    // MALI-034: in-slot legacy financial-cache reconciliation, built once with
    // THIS run's admission generation. A domain carrying a legacy dirty marker is
    // re-pulled from epoch at its normal post-push pull slot (replacing the
    // incremental pull) and its marker cleared on completion; otherwise the
    // normal incremental pull runs. A `cancelled` outcome (owner changed mid-run)
    // aborts the rest of this body before any later owner-sensitive phase. This
    // replaces the retired recurring FinancialCacheRepairService cycle.
    final reconciler = LegacyFinancialCacheReconciler(
      db: ref.read(appDatabaseProvider),
      generation: gen,
      isAdmitted: _syncGate.admits,
    );
    if (kDebugMode) {
      final unsupported =
          await unsupportedDirtyMarkers(ref.read(appDatabaseProvider));
      if (unsupported.isNotEmpty) {
        debugPrint(
            '[FinancialCache] unsupported dirty markers remain: $unsupported');
      }
    }
    final planning = ref.read(planningSyncEngineProvider);
    final health = ref.read(syncHealthProvider);
    var cancelled = false;
    try {
      final parents = await planning.syncParents(reconciler: reconciler);
      cancelled = parents.cancelled;
    } catch (error) {
      health.recordFailure(SyncDomain.planning, error);
      if (kDebugMode) {
        debugPrint('[PlanningSync] parent sync skipped: ${error.runtimeType}');
      }
    }
    if (cancelled) return;
    // S5 reads are Drift-only. Background workers are a signed-in capability
    // and never depend on obsolete *_supabase_primary routing flags.
    try {
      final ledger =
          await ref.read(ledgerSyncEngineProvider).sync(reconciler: reconciler);
      if (ledger == ReconcileDomainResult.cancelled) return;
    } catch (error) {
      health.recordFailure(SyncDomain.ledger, error);
      if (kDebugMode) {
        debugPrint('[LedgerEngine] sync skipped: ${error.runtimeType}');
      }
    }
    // S3: ادفع تغييرات الحالة المحلية (رفض/معالجة) أولاً ثم اسحب. الخدمة تتحقق
    // داخليًا من التفعيل، فنستدعيها دائمًا (offline-safe).
    final phase = SyncPhaseBinding();
    bool currentInbox() => mounted && _syncGate.admits(gen) && phase.isCurrent;
    try {
      final smartInbox = ref.read(smartInboxSyncServiceProvider);
      bool current() => currentInbox();
      await health.runPhase(SyncDomain.smartInbox, SyncDirection.push,
          () => smartInbox.pushWithPhase(phase),
          binding: phase, rethrowErrors: true);
      if (!current()) return;
      final pullPhase = phase.forNextPhase();
      final domain = smartInboxReconcileDomain(smartInbox);
      final inbox = await reconcileOrPull(
        reconciler: reconciler,
        domain: ReconcileDomain(
            name: domain.name,
            entities: domain.entities,
            isEnabled: () => current() && domain.isEnabled(),
            runFromEpoch: ({required dirtyEntities, required isAdmitted}) {
              if (!current() || !isAdmitted()) {
                throw const SmartInboxDeliveryStopped(
                    SmartInboxDeliveryStopReason.stale);
              }
              return domain.runFromEpoch(
                  dirtyEntities: dirtyEntities,
                  isAdmitted: () => current() && isAdmitted());
            }),
        normalPull: (admitted) async {
          if (!current() || !admitted()) {
            throw const SmartInboxDeliveryStopped(
                SmartInboxDeliveryStopReason.stale);
          }
          await health.runPhase(SyncDomain.smartInbox, SyncDirection.pull,
              () => smartInbox.pull(isAdmitted: () => current() && admitted()),
              binding: pullPhase, rethrowErrors: true);
        },
      );
      if (!current() || inbox == ReconcileDomainResult.cancelled) return;
    } on AccountFenceDeliveryCancellation {
      return;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[SmartInboxSync] sync skipped: ${error.runtimeType}');
      }
    }
    if (!currentInbox()) return;
    try {
      await planning.syncChildren();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PlanningSync] child sync skipped: ${error.runtimeType}');
      }
    }

    // Gamification: submit durable engagement events (server awards exactly
    // once), then pull the acknowledged server aggregate (MALI-024 — the client
    // never uploads a total).
    final engagementPhase = SyncPhaseBinding();
    bool currentEngagement() =>
        mounted && _syncGate.admits(gen) && engagementPhase.isCurrent;
    try {
      await health.runPhase(
          SyncDomain.engagement,
          SyncDirection.push,
          () => ref
              .read(engagementEventServiceProvider)
              .pushWithPhase(engagementPhase),
          binding: engagementPhase,
          rethrowErrors: true);
    } on AccountFenceDeliveryCancellation {
      return;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[Engagement] push skipped: ${error.runtimeType}');
      }
    }
    if (!currentEngagement()) return;
    try {
      await health.runPhase(SyncDomain.engagement, SyncDirection.pull,
          () => ref.read(gamificationSyncServiceProvider).performSync(),
          binding: engagementPhase.forNextPhase(), rethrowErrors: true);
    } on AccountFenceDeliveryCancellation {
      return;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[GamificationSync] sync skipped: ${error.runtimeType}');
      }
    }

    if (!currentEngagement()) return;

    // Read-only duplicate trace — runs once per session after a full
    // push/pull/reconcile cycle so any duplicate is visible in its final state.
    // Debug builds only; writes nothing.
    if (kDebugMode && !_didDupTrace) {
      _didDupTrace = true;
      try {
        final report =
            await DuplicateTraceService(ref.read(appDatabaseProvider)).run();
        for (final line in report.split('\n')) {
          debugPrint(line);
        }
      } catch (error) {
        debugPrint('[DupTrace] failed: $error');
      }
    }
  }

  Future<void>? _sharedInputInFlight;

  Future<void> _consumeSharedInput() {
    final existing = _sharedInputInFlight;
    if (existing != null) return existing;
    late final Future<void> run;
    run = _consumeSharedInputOnce().whenComplete(() {
      if (identical(_sharedInputInFlight, run)) _sharedInputInFlight = null;
    });
    _sharedInputInFlight = run;
    return run;
  }

  Future<void> _consumeSharedInputOnce() async {
    // WP-7 §4.10: capture delivery stays off until the swap has committed.
    if (ReplicaFreeze.instance.frozen) return;
    if (_isConsumingSharedInput) return;
    _isConsumingSharedInput = true;
    try {
      // One process-wide lease for every engine's drain; the retry ledger is
      // re-read from its durable store under it, and captures left queued
      // request the next background run for when the earliest is due.
      _lastDrainPass = await runLeasedCaptureDrain(
        lease: _drainLease,
        holder: 'app_shell',
        ledger: ref.read(captureRetryLedgerProvider),
        drain: () async {
          _drainPass = const CaptureDrainPass();
          await _consumeSharedInputLeased();
          return _drainPass;
        },
      );
    } on StateError catch (_) {
      // Same discipline as the leased body below: disposed means stop (the
      // lease was released on the way out); a StateError while mounted is a
      // real bug and keeps propagating.
      if (mounted) rethrow;
    } finally {
      _isConsumingSharedInput = false;
    }
  }

  /// A background-triggered drain (see [BackgroundCaptureDrainRunner]). Runs
  /// only under the same admission the foreground drain needs: a signed-in
  /// user whose replica is the admitted active account, and no replica swap
  /// or account transition in flight. Otherwise nothing is touched.
  Future<BackgroundDrainOutcome> _runBackgroundTriggeredDrain() async {
    final runner = BackgroundCaptureDrainRunner(
      mayRun: () async =>
          mounted &&
          !ReplicaFreeze.instance.frozen &&
          AppSession.instance.status == SessionStatus.authenticated &&
          (AdmittedLocalWork.capture(ref)?.current ?? false),
      pass: (isActive) async {
        _lastDrainPass = null;
        _backgroundIsActive = isActive;
        try {
          await _consumeSharedInput();
        } finally {
          _backgroundIsActive = null;
        }
        // No pass ran (the replica froze meanwhile): try again later.
        return _lastDrainPass ?? const CaptureDrainPass(busy: true);
      },
    );
    _backgroundDrain = runner;
    try {
      return await runner.run();
    } finally {
      if (identical(_backgroundDrain, runner)) _backgroundDrain = null;
    }
  }

  Future<void> _consumeSharedInputLeased() async {
    final authFailure = AppSession.instance
        .captureAuthRequiredFailure(ref.read(authClientProvider));
    try {
      // §4.7: queue hygiene after adoption; independent of the import flag.
      try {
        await ref.read(legacyCaptureResolverProvider).resolve();
      } catch (_) {}
      // CAP-7: keep the App Intent's flag mirror current (iOS; best-effort).
      unawaited(
          NativeCaptureBridge.setCaptureNotifyV2(_captureNotifyV2Enabled()));
      unawaited(ref
          .read(loadNotificationPreferencesUseCaseProvider)
          .call()
          .then((p) => NativeCaptureBridge.setHideCaptureDetails(
              p.hideLockScreenContent))
          .catchError((Object _) {}));
      if (_captureImportV3Enabled()) {
        await _runCaptureImportV3();
        return;
      }
      // The per-message loop lives in LegacyCaptureDrain (executed by tests
      // against a mocked native channel and a fake network); this shell only
      // supplies its UI callbacks and reacts to the report. Every `ref` the
      // drain needs is read BEFORE the first await below.
      final drain = ref.read(legacyCaptureDrainProvider);
      final database = ref.read(appDatabaseProvider);
      final notificationPreferences =
          await ref.read(loadNotificationPreferencesUseCaseProvider).call();
      if (!mounted) return;
      await _surfaceAndroidQueueRefusals();
      if (!mounted) return;
      await _surfaceAndroidCaptureRestored();
      if (!mounted) return;
      final report = await drain.run(
        // A background-triggered pass also stops when the OS cancels it.
        isActive: () => mounted && (_backgroundIsActive?.call() ?? true),
        // R9: one count per acknowledged capture (counts only, no content).
        onAcknowledged: (message) => CaptureIdentityMetrics.record(
          database,
          message.receivedAtInferred,
        ),
        showLocalReview: (item) => _showCapturedMessageNotification(
          item.result,
          notificationPreferences,
        ),
      );
      _drainPass = CaptureDrainPass(
        stopped: report.stopped,
        authRequired: report.authRequired || report.authRequiredBeforeDrain,
        readFailed: report.readFailed,
      );
      if (report.authRequiredBeforeDrain) {
        await authFailure();
        return;
      }
      if (!mounted) return;
      _reportCaptureQueueRead(failed: report.readFailed);
      if (report.authRequired) await authFailure();
      if (!mounted) return;
      if (report.queued > 0) {
        // Prune old dedup hashes opportunistically on each drain cycle.
        unawaited(ref.read(appDatabaseProvider).pruneOldDedupHashes());
      }
      if (report.smartInboxChanged) ref.invalidate(smartInboxItemsProvider);
      final backendSync = report.backendSync;
      final budgetCommits = report.budgetCommits;
      String? pendingConfirmationId;
      String? pendingSecondaryNotice;
      for (final item in report.ingested) {
        final result = item.result;
        if (result.transactionId != null &&
            result.addTransactionResult.requiresConfirmation) {
          pendingConfirmationId = result.transactionId;
          pendingSecondaryNotice =
              feeNoticeFor(context, result.addTransactionResult.secondary);
        }
      }
      if (pendingConfirmationId == null &&
          backendSync?.needsReviewTransactionIds.isNotEmpty == true) {
        pendingConfirmationId = backendSync!.needsReviewTransactionIds.last;
      }
      unawaited(
        ref.read(notificationJourneyServiceProvider).evaluateAfterCapture(),
      );
      // Budget alerts for spend that arrived through THIS path: the relay
      // import and the foreground shared-message ingest both add transactions
      // without going through CapturedMessageProcessor, so its budget check
      // never ran for them — budgets crossed 75%/90%/100% silently on iOS.
      if (budgetCommits.isNotEmpty) {
        try {
          await CapturedMessageProcessor.checkBudgetAlert(
            ref.read(appDatabaseProvider),
            notificationPreferences,
            committedTransactions: budgetCommits,
            lang: LocalNotificationService.instance.notificationLanguage,
          );
        } catch (error) {
          if (kDebugMode) {
            debugPrint('[BudgetAlert] check skipped: ${error.runtimeType}');
          }
        }
      }
      if (!mounted) return;

      _refreshAll();

      // Android: captures that arrived with no active owner (signed out,
      // mid account change) or before the owner model existed are imported
      // only after the user claims them here; never automatically.
      if (Platform.isAndroid) unawaited(_maybePromptUnboundCaptures());

      if (pendingConfirmationId != null) {
        await _openConfirmSheet(
          pendingConfirmationId,
          secondaryNotice: pendingSecondaryNotice,
        );
      }
    } on StateError catch (_) {
      // The shell is a route, not a permanent host: opening a top-level page
      // (/accounts, /goals, …) disposes it mid-drain, and any of the 22 awaits
      // above can return to a dead `ref`. This method already returns early on
      // !mounted in two places — being disposed means STOP, not fail — but the
      // outer block was try/finally with no catch, so the StateError escaped as
      // an unhandled async error instead. Guarding each await individually is
      // whack-a-mole; deciding on `mounted` is exact. A StateError raised while
      // still mounted is a real bug and must keep propagating.
      if (mounted) rethrow;
      if (kDebugMode) {
        debugPrint('[Capture] drain stopped: shell disposed mid-drain');
      }
    }
  }

  bool _captureImportV3Enabled() {
    if (!Platform.isIOS) return false;
    try {
      return featureFlags.getBool('capture_import_v3');
    } catch (_) {
      return false;
    }
  }

  /// CAP-7 (`capture_notify_v2`): the notification journey. OFF = shipped.
  bool _captureNotifyV2Enabled() {
    try {
      return featureFlags.getBool('capture_notify_v2');
    } catch (_) {
      return false;
    }
  }

  /// CAP-5 (`capture_import_v3`): the single iOS import. Android and manual
  /// paste keep the path below.
  Future<void> _runCaptureImportV3() async {
    await _importAndNotifyV3();
    unawaited(_maybePromptUnboundCaptures());
  }

  Future<void> _importAndNotifyV3() async {
    final CaptureImportReport report;
    final authFailure = AppSession.instance
        .captureAuthRequiredFailure(ref.read(authClientProvider));
    try {
      report = await ref.read(captureImportServiceProvider).run();
    } on AuthRepoException {
      _drainPass = const CaptureDrainPass(authRequired: true);
      await authFailure();
      return;
    }
    _drainPass = CaptureDrainPass(readFailed: report.readFailed);
    if (!mounted) return;
    if (!report.guardFailed && !report.barrierHeld) {
      _reportCaptureQueueRead(failed: report.readFailed);
    }
    if (report.imported.isEmpty) return;
    unawaited(ref.read(appDatabaseProvider).pruneOldDedupHashes());
    final preferences =
        await ref.read(loadNotificationPreferencesUseCaseProvider).call();
    final notifyV2 = _captureNotifyV2Enabled();
    String? pendingConfirmationId;
    for (final item in report.imported) {
      if (item.path == CaptureImportPath.alreadyImported) continue;
      await CaptureIdentityMetrics.record(
        ref.read(appDatabaseProvider),
        item.message?.receivedAtInferred,
      );
      final local = item.local;
      if (local != null) {
        if (local.disposition == CapturedMessageDisposition.unprocessable) {
          ref.invalidate(smartInboxItemsProvider);
        }
        if (!notifyV2 &&
            CaptureNotificationAuthority.shouldShowLocalReview(
              status: item.message?.status,
              alreadyImported: false,
              ownerValid: true,
            )) {
          await _showCapturedMessageNotification(local, preferences);
        }
        if (local.transactionId != null &&
            local.addTransactionResult.requiresConfirmation) {
          pendingConfirmationId = local.transactionId;
        }
      } else if (item.reviewTransactionId != null) {
        pendingConfirmationId = item.reviewTransactionId;
      }
    }
    if (notifyV2) await _alertImportedV2(report.imported, preferences);
    unawaited(
      ref.read(notificationJourneyServiceProvider).evaluateAfterCapture(),
    );
    try {
      await CapturedMessageProcessor.checkBudgetAlert(
        ref.read(appDatabaseProvider),
        preferences,
        committedTransactions: report.imported
            // Server captures have already been evaluated for APNs budget
            // delivery. Importing them is not a new local alert event.
            .where((item) => item.path == CaptureImportPath.local)
            .expand((item) => item.committedTransactions),
        lang: LocalNotificationService.instance.notificationLanguage,
      );
    } catch (_) {}
    if (!mounted) return;
    _refreshAll();
    if (pendingConfirmationId != null) {
      await _openConfirmSheet(pendingConfirmationId);
    }
  }

  /// CAP-7: the owner rule, backlog summary and corrections. Every alert text
  /// is generic ([LocalNotificationService] enforces it again at the OS edge).
  Future<void> _alertImportedV2(
    List<CaptureImportItem> imported,
    NotificationPreferences preferences,
  ) =>
      alertImportedV2(ref.read(appDatabaseProvider), imported, preferences);

  bool _isPromptingUnbound = false;
  bool _unboundPromptDismissed = false;

  /// BL-2: offered only to the hinted uid, and only a count and the senders.
  Future<void> _maybePromptUnboundCaptures() async {
    if (_isPromptingUnbound || _unboundPromptDismissed || !mounted) return;
    _isPromptingUnbound = true;
    try {
      final service = ref.read(unboundCapturePromptServiceProvider);
      final offer = await service.check();
      if (offer == null || !mounted) return;
      final l = context.l10n;
      final add = await showDialog<bool>(
        context: context,
        builder: (ctx) => GlassAlertDialog(
          title: Text(l.captureUnboundTitle),
          content: Text([
            l.captureUnboundBody(offer.count),
            if (offer.senders.isNotEmpty)
              l.captureUnboundSenders(offer.senders.join(', ')),
          ].join('\n')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.captureUnboundDiscard),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l.captureUnboundAdd),
            ),
          ],
        ),
      );
      if (add == null) {
        _unboundPromptDismissed = true; // asked again on the next launch
        return;
      }
      final choice =
          add ? await service.add(offer) : await service.discard(offer);
      if (add && choice == UnboundCaptureChoice.applied) {
        await _consumeSharedInput();
      }
    } catch (_) {
    } finally {
      _isPromptingUnbound = false;
    }
  }

  Future<void> _showCapturedMessageNotification(
    CapturedMessageResult result,
    NotificationPreferences preferences,
  ) =>
      showCapturedMessageNotification(result, preferences);

  bool _syncEngagementInFlight = false;

  /// Wraps the actual engagement sync so an `auth_required` failure from any
  /// Supabase-primary repository call inside it (budgets/goals/bills — all
  /// now require a live session) triggers the one centralized session-invalid
  /// recovery instead of surfacing as an unhandled exception. Any other error
  /// type is intentionally left to propagate — this must not become a
  /// blanket catch-all that hides unrelated bugs.
  Future<bool> _syncEngagement({AdmittedLocalWork? originalWork}) async {
    if (_syncEngagementInFlight || !mounted) return false;
    final work = originalWork ?? AdmittedLocalWork.capture(ref);
    if (work == null || !work.current) return false;
    final generation = _syncGate.generation;
    final phase = SyncPhaseBinding();
    bool rawCurrent() =>
        mounted && _syncGate.admits(generation) && work.current;
    phase.bind(_NotificationCallerLifecycle(work, rawCurrent));
    bool current() =>
        rawCurrent() &&
        phase.isCurrent &&
        identical(phase.database, work.database);
    _syncEngagementInFlight = true;
    final authFailure = AppSession.instance
        .captureAuthRequiredFailure(ref.read(authClientProvider));
    try {
      return await _syncEngagementBody(work, current, phase) && current();
    } on AccountFenceDeliveryCancellation {
      return false;
    } on AuthRepoException {
      if (!current()) return false;
      await authFailure();
      return false;
    } on StateError {
      if (current()) rethrow;
      return false;
    } catch (_) {
      if (!current()) return false;
      rethrow;
    } finally {
      _syncEngagementInFlight = false;
    }
  }

  /// Re-compose the scheduled notifications in the current language.
  ///
  /// Deliberately narrower than [_syncEngagement]: that one also does network
  /// work, and a language switch is not a reason to sync anything.
  Future<void> _replanScheduledNotifications() async {
    try {
      final preferences =
          await ref.read(loadNotificationPreferencesUseCaseProvider).call();
      if (!mounted) return;
      final bills = await ref.read(billRepositoryProvider).getAll();
      if (!mounted) return;
      final planned = const NotificationPlanner().planScheduled(
        preferences: preferences,
        bills: bills,
        nowRiyadh: DateTime.now(),
        lang: LocalNotificationService.instance.notificationLanguage,
      );
      await LocalNotificationService.instance
          .schedulePlannedNotifications(planned);
    } catch (error) {
      // A failed re-plan leaves the previous language's pending requests in
      // place, which is strictly better than cancelling them and scheduling
      // nothing.
      if (kDebugMode) {
        debugPrint('[Notifications] re-plan after language switch skipped: '
            '${error.runtimeType}');
      }
    }
  }

  Future<bool> _syncEngagementBody(AdmittedLocalWork work,
      bool Function() current, SyncPhaseBinding phase) async {
    // Entry is already a disposal window: this is awaited from _onResume after
    // other awaits, so the shell can be gone before the first line runs.
    if (!current()) return false;
    final preferences =
        await ref.read(loadNotificationPreferencesUseCaseProvider).call();
    // Same reason as _onResume: the shell can be disposed across this await.
    if (!current()) return false;

    // Streak reminder, weekly report, and bill/subscription reminders are
    // scheduled locally (no server-side equivalent exists) — this was
    // dropped when gamification/budgets moved to Supabase edge functions
    // (commit 8bf8259b) and never restored, so these three notification
    // types stopped firing entirely.
    // Same disposal race as below: an await preceded this.
    if (!current()) return false;
    final bills = await ref.read(billRepositoryProvider).getAll();
    if (!current()) return false;
    final planned = const NotificationPlanner().planScheduled(
      preferences: preferences,
      bills: bills,
      // Device-local wall-clock time — the notification service now schedules
      // in the device timezone (tz.local), so plan in the same frame. (The
      // `Riyadh` names are legacy; the values are device-local.)
      nowRiyadh: DateTime.now(),
      lang: LocalNotificationService.instance.notificationLanguage,
    );
    await LocalNotificationService.instance.schedulePlannedNotifications(
      planned,
    );
    if (!current()) return false;
    // V1 retired the streak reminder. Deleting the scheduling code does not
    // unschedule what the OS already holds, so every planning cycle also
    // cancels any reminder a pre-V1 build left pending.
    await LocalNotificationService.instance.cancelRetiredStreakReminder();

    // Opportunistic — drains native (iOS Shortcut) notification events and
    // syncs the local outbox to notification_logs. Never blocks engagement
    // evaluation after the original lifetime has retired.
    // Same disposal race as below: an await preceded this.
    if (!current()) return false;
    try {
      final outcome = await ref
          .read(notificationLogSyncServiceProvider)
          .syncWithPhase(phase);
      if (!current() || outcome == NotificationUploadOutcome.deferred) {
        return false;
      }
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } on AuthRepoException {
      rethrow;
    } catch (_) {
      // Current ordinary upload failure remains best effort; stale work stops.
      if (!current()) return false;
    }
    return current();
  }

  /// Invalidates only the providers a transaction mutation (confirm/dismiss/
  /// capture) can actually affect — the transaction list, budget spend,
  /// account balance, and dashboard aggregates. Achievements and
  /// notification preferences have no correctness relationship to a
  /// transaction change and are refreshed by their own triggers instead
  /// ([_syncEngagement], the settings screens).
  void _refreshAll() {
    refreshTransactions(ref);
    refreshBudgets(ref);
    ref.invalidate(accountsProvider);
    ref.invalidate(dashboardDataProvider);
  }

  void _drainCelebrations() {
    if (!mounted || _activeCelebration != null) {
      return;
    }
    final next = CelebrationRuntime.instance.takeNext();
    if (next == null) {
      return;
    }
    setState(() => _activeCelebration = next);
    final disableAnimations =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    _celebrationTimer = Timer(
      disableAnimations
          ? const Duration(milliseconds: 10)
          : const Duration(seconds: 2),
      () {
        if (!mounted) {
          return;
        }
        setState(() => _activeCelebration = null);
        _drainCelebrations();
      },
    );
  }

  Future<void> _openConfirmSheet(
    String transactionId, {
    String? secondaryNotice,
    AdmissionAuthority? origin,
  }) async {
    if (!mounted) {
      return;
    }
    // Before the id is claimed: a stale request must not consume it.
    if (origin != null && !_originIsMine(origin)) return;
    final work = AdmittedLocalWork.capture(ref);
    if (work == null) return;
    final transaction = await ref.read(transactionRepositoryProvider).getById(transactionId);
    if (!mounted || !work.current) return;
    if (transaction?.status == TransactionStatus.confirmed) {
      _handleNotificationRoute('/transaction/$transactionId');
      return;
    }
    if (!_claimAutoNavigation(transactionId)) {
      return;
    }
    // No pre-emptive _refreshAll() here — the sheet reads its own
    // transactionByIdProvider fresh, and refreshing the list/dashboard
    // providers before the sheet is even visible only caused a visible
    // flash right as a notification was tapped, with no data it needed.
    await showConfirmTransactionSheet(
      context,
      transactionId,
      secondaryNotice: secondaryNotice,
    );
    if (!await _syncEngagement(originalWork: work)) return;
    _drainCelebrations();
  }

  /// زر "تأكيد ✓" أو "تجاهل" من الإشعار والتطبيق شغال — ينفَّذ مباشرة
  /// عبر نفس مسار الشاشات (usecase/repository) ثم تحديث الواجهة.
  Future<void> _applyQuickAction(CaptureQuickAction action,
      {AdmittedLocalWork? work}) async {
    work ??= AdmittedLocalWork.capture(ref);
    if (work == null || !work.current) return;
    // O-LC-2: an action raised in another lifecycle than this shell's current
    // admitted work is dropped before any effect.
    final origin = action.origin;
    if (origin != null &&
        !(origin.isCurrent &&
            origin.uid == work.authority.uid &&
            origin.epoch == work.authority.epoch)) {
      return;
    }
    try {
      if (action.confirm) {
        await work.local(() =>
            ref.read(confirmTransactionUseCaseProvider)(action.transactionId));
      } else {
        await work.local(() => ref
            .read(transactionRepositoryProvider)
            .deleteTransaction(action.transactionId));
      }
    } catch (_) {
      // العملية قد تكون أُكّدت/حُذفت من مكان آخر بالفعل.
    }
    if (!work.current) return;
    _refreshAll();
    if (!await _syncEngagement(originalWork: work)) return;
    if (!work.current) return;
    _drainCelebrations();
  }

  /// إجراءات فشلت في الـ background (جهاز مقفول → Keychain غير متاح) —
  /// تُطبَّق هنا عند أول فتح. Returns true iff at least one action was
  /// actually drained — callers use this to skip a broad refresh when the
  /// queue was already empty.
  Future<bool> _drainPendingNotificationActions(AdmittedLocalWork work) async {
    final actions = await PendingNotificationActions.drain();
    if (!work.current) return false;
    for (final action in actions) {
      if (!work.current) return false;
      await _applyQuickAction(
        CaptureQuickAction(
          transactionId: action.transactionId,
          confirm: action.confirm,
        ),
        work: work,
      );
    }
    return actions.isNotEmpty;
  }

  bool _isDrainingNotificationRoutes = false;

  /// Guarded against re-entry: [_onResume] and the cold-start post-frame
  /// callback can both reach this in quick succession (e.g. a resume firing
  /// while the initial drain from cold start is still awaiting
  /// `captureSyncServiceProvider.sync()`) — a second call while one is
  /// in-flight is a no-op rather than a duplicate sync + duplicate refresh.
  Future<void> _drainPendingNotificationRoutes() async {
    if (_isDrainingNotificationRoutes) return;
    _isDrainingNotificationRoutes = true;
    try {
      final routes =
          await NativeCaptureBridge.consumePendingNotificationRoutes();
      if (routes.isEmpty) return;
      _recordOpenedForRoutes(routes);
      final route = routes.last;
      try {
        // Join the entire drain, including owner/legacy resolution before
        // either importer starts. A second tap must not outrun that work.
        await _consumeSharedInput();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[Capture] notification route sync skipped: $error');
        }
      }
      _refreshAll();
      if (!mounted) return;
      final action = route.action;
      if (action == kActionAddManually ||
          action == kActionEnableSmartAnalysis) {
        await _handleCaptureNotificationAction(route, action!);
        return;
      }
      final work = AdmittedLocalWork.capture(ref);
      if (work == null) return;
      final target = await _routeForCaptureNotification(route);
      if (!mounted || !work.current) return;
      _handleNotificationRoute(target);
    } finally {
      _isDrainingNotificationRoutes = false;
    }
  }

  /// Records the 'opened' lifecycle event for every drained route that
  /// carries a notificationLogId (remote APNs pushes and the iOS Shortcut's
  /// local fallback both attach one — see local_notification_service.dart
  /// and BankMessageShortcuts.swift). Idempotent and never awaited by the
  /// caller — routing must not wait on this. See
  /// docs/NOTIFICATION_PIPELINE_AUDIT.md.
  void _recordOpenedForRoutes(List<CaptureNotificationRoute> routes) {
    final service = ref.read(notificationLogServiceProvider);
    for (final route in routes) {
      final logId = route.notificationLogId;
      if (logId == null) continue;
      unawaited(service.recordOpened(
        logId: logId,
        channel: NotificationLogChannel.apns,
        notificationType: route.notificationType ?? 'unknown',
        relatedEntityType: route.transactionId != null ? 'transaction' : null,
        relatedEntityId: route.transactionId,
      ));
    }
  }

  Future<String> _routeForCaptureNotification(
    CaptureNotificationRoute route,
  ) async {
    final section = notificationSectionRoute(route.notificationType);
    if (section != null) return section;
    final payloadId = route.payloadId ?? route.smartInboxItemId;
    final payloadTransactionId = payloadId == null || payloadId.isEmpty
        ? null
        : await ref
            .read(captureSyncServiceProvider)
            .transactionIdForPayload(payloadId);
    final repository = ref.read(transactionRepositoryProvider);
    for (final id in {
      route.transactionId,
      payloadTransactionId,
      // Import V3 commits the transaction under the payload id atomically.
      payloadId,
    }) {
      if (id == null ||
          id.isEmpty ||
          id.startsWith('smart_inbox:') ||
          id.startsWith('rejected:')) {
        continue;
      }
      final transaction = await repository.getById(id);
      if (transaction?.status == TransactionStatus.confirmed) {
        return captureRouteFor(confirmedTransactionId: transaction!.id);
      }
    }
    return captureRouteFor(
      type: route.notificationType,
      transactionId: route.transactionId,
      payloadTransactionId: payloadTransactionId,
    );
  }

  Future<void> _handleCaptureNotificationAction(
    CaptureNotificationRoute route,
    String action,
  ) async {
    final payloadId = route.payloadId ?? route.smartInboxItemId;
    final marker = payloadId == null || payloadId.isEmpty
        ? route.transactionId
        : await ref
            .read(captureSyncServiceProvider)
            .transactionIdForPayload(payloadId);
    if (!mounted) return;
    await handleCaptureNotificationAction(
      action: action,
      smartInboxMarker: marker,
      showSmartInbox: () => _handleNotificationRoute('/smart-inbox'),
      openManualSheet: () => ManualTransactionSheet.show(context),
      resolveItem: (itemId) async {
        await ref.read(smartInboxRepositoryProvider).resolve(itemId);
        ref.invalidate(smartInboxItemsProvider);
      },
      isSmartAnalysisGranted: () async => ConsentAuthority.decide(
        EgressClass.aiProcessing,
        await ref.read(userSettingsRepositoryProvider).getSettings(),
      ),
      openConsentSheet: () => showSmartAnalysisConsentSheet(context, ref),
      openPrivacy: () => context.push('/privacy'),
    );
  }

  void _handleNotificationRoute(String route) {
    if (!mounted) return;
    if (const {'/budgets', '/goals', '/achievements', '/subscriptions', '/settings', '/privacy', '/announcements'}
        .contains(route) || route.startsWith('/goals/')) {
      context.push(route);
      return;
    }
    if (route == '/dashboard') {
      ref.read(shellIndexProvider.notifier).state = 0;
      return;
    }
    if (route == '/reports') {
      context.push('/reports');
      return;
    }
    if (route.startsWith('/transaction/')) {
      final transactionId = route.substring('/transaction/'.length);
      if (!_claimAutoNavigation(transactionId)) return;
      ref.read(transactionsPendingFilterProvider.notifier).state = false;
      context.push(route);
      return;
    }
    if (route == '/smart-inbox') {
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPageTabProvider.notifier).state = 0;
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
      return;
    }
    if (route == '/transactions') {
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPageTabProvider.notifier).state = 0;
      ref.read(transactionsPendingFilterProvider.notifier).state = false;
      return;
    }
    if (route == '/') {
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPageTabProvider.notifier).state = 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(scopedRevisionProvider('budgets,goals,streaks,transactions'),
        (previous, next) {
      if (next.hasValue) unawaited(_reconcileAchievements());
    });
    // A scheduled notification is composed NOW and delivered hours or days
    // later, so it carries the language that was current when it was planned.
    // Re-planning otherwise happens only on cold start and on resume, which
    // means someone who switched to English and did not background the app
    // would still get that evening's reminder in Arabic. Re-plan on the switch
    // itself. The ids are fixed, so this REPLACES the pending requests rather
    // than stacking new ones.
    ref.listen<Locale>(localeProvider, (previous, next) {
      if (previous == null || previous.languageCode == next.languageCode) {
        return;
      }
      unawaited(_replanScheduledNotifications());
    });

    // Force update blocks the entire app — check before rendering anything else.
    final forceUpdateAsync = ref.watch(hasForceUpdateProvider);
    if (forceUpdateAsync.valueOrNull == true) {
      return const ForceUpdateScreen();
    }

    final c = context.colors;
    final index = ref.watch(shellIndexProvider);
    // Reports embeds a TabBarView (needs bounded height). IndexedStack lays out
    // every child even when offstage, so build it only when its tab is active.
    final pages = [
      const DashboardScreen(),
      const TransactionsScreen(),
      const BudgetsScreen(),
      const SettingsScreen(),
      index == 4 ? const ReportsScreen() : const SizedBox.shrink(),
    ];

    final shell = NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        if (notification.direction == ScrollDirection.reverse) {
          if (_isBottomBarVisible) {
            setState(() => _isBottomBarVisible = false);
          }
        } else if (notification.direction == ScrollDirection.forward) {
          if (!_isBottomBarVisible) {
            setState(() => _isBottomBarVisible = true);
          }
        }
        return true;
      },
      child: Scaffold(
        extendBody: true,
        backgroundColor: c.bg,
        appBar: null,
        body: Stack(
          children: [
            // محتوى الصفحة الرئيسي — بدون SafeArea علوي حتى يمتد الهيدر
            // المتدرّج خلف شريط الحالة (كل شاشة تتكفّل بالمساحة الآمنة داخليًا).
            IndexedStack(index: index, children: pages),
            // No shell-wide status-bar blur: it smeared each tab's
            // immersive photo/content into a flat band. Every tab now draws
            // its own scroll-edge glass (transparent at rest).
            if (_activeCelebration != null)
              Positioned(
                top: AppSpacing.s5,
                left: AppSpacing.gutter,
                right: AppSpacing.gutter,
                child: _CelebrationBanner(event: _activeCelebration!),
              ),
          ],
        ),
        bottomNavigationBar: ValueListenableBuilder<bool>(
          valueListenable: modalRouteOpen,
          builder: (context, modalOpen, child) {
            // The native glass tab bar is a platform view a sheet can't cover;
            // drop it from the tree while a sheet/dialog is open so it doesn't
            // bleed a glass band over the sheet's bottom.
            if (modalOpen) return const SizedBox.shrink();
            return child!;
          },
          // البار مابيختفيش وانت بتنزل — بيتلمّ في كبسولة صغيّرة فيها
          // الأيقونة النشطة بس، وبيترجع يفتح لما تطلع فوق أو تدوس عليه.
          child: _BottomNavBar(
            currentIndex: index,
            expanded: _isBottomBarVisible,
            onExpand: () => setState(() => _isBottomBarVisible = true),
            onSelect: (next) =>
                ref.read(shellIndexProvider.notifier).state = next,
          ),
        ),
      ),
    );

    // The post-sign-in restore loader lives at the app root (see MoneyApp /
    // [appDataRestoring]), so it is one continuous screen with the cold-start
    // loader instead of a second loader flashing over the shell here.
    return shell;
  }
}

class _CelebrationBanner extends StatelessWidget {
  const _CelebrationBanner({required this.event});

  final CelebrationEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.s4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(AppRadius.card),
          border: Border.all(color: c.border),
          boxShadow: AppShadows.float,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(event.title, style: AppTypography.bodyStrong(c.textPrimary)),
            const SizedBox(height: AppSpacing.s1),
            Text(event.message, style: AppTypography.callout(c.textSecondary)),
          ],
        ),
      ),
    );
  }
}

class _BottomNavBar extends StatelessWidget {
  const _BottomNavBar({
    required this.currentIndex,
    required this.onSelect,
    this.expanded = true,
    this.onExpand,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// مفتوح = كل الأيقونات. مقفول (وانت نازل بالسكرول) = كبسولة صغيّرة فيها
  /// الأيقونة النشطة بس — مابتختفيش.
  final bool expanded;
  final VoidCallback? onExpand;

  static const _items = [
    _BottomBarItem(
      page: 0,
      icon: AppLucideIcons.home,
    ),
    _BottomBarItem(
      page: 1,
      icon: AppLucideIcons.receipt,
    ),
    _BottomBarItem(
      page: 2,
      icon: AppLucideIcons.walletCards,
    ),
    _BottomBarItem(
      page: 4,
      icon: AppLucideIcons.shapes,
    ),
    _BottomBarItem(
      page: 3,
      icon: AppLucideIcons.settings,
    ),
  ];

  /// ارتفاع صف الأيقونات جوّه الكبسولة.
  static const double _slotHeight = 52;

  /// SF Symbols for Apple's native tab bar, by page.
  static String _symbolFor(int page) => switch (page) {
        0 => 'house',
        1 => 'list.bullet.rectangle',
        2 => 'banknote',
        3 => 'gearshape',
        4 => 'chart.pie',
        _ => 'circle',
      };

  @override
  Widget build(BuildContext context) {
    // iOS 26+: Apple's own UITabBar, so the bar is the real system Liquid
    // Glass — including its own Increase Contrast / Reduce Transparency
    // treatment. Everywhere else: the Flutter capsule below.
    return ValueListenableBuilder<bool>(
      valueListenable: NativeGlassSupport.supported,
      builder: (context, native, _) {
        if (!native) {
          return _flutterBar(context);
        }
        final selectedSlot = _items.indexWhere((i) => i.page == currentIndex);
        return NativeTabBar(
          items: [
            for (final item in _items)
              NativeTabBarItem(
                symbol: _symbolFor(item.page),
                title: item.label(context),
              ),
          ],
          selectedIndex: selectedSlot,
          onSelect: (slot) => onSelect(_items[slot].page),
          dark: Theme.of(context).brightness == Brightness.dark,
          rtl: Directionality.of(context) == TextDirection.rtl,
          // v2 QTabBar: selected = action.text (#8FB0FF dark / #0336BF light).
          tint: context.colors.actionText,
        );
      },
    );
  }

  Widget _flutterBar(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final safeBottom = MediaQuery.paddingOf(context).bottom;
    final selectedSlot = _items.indexWhere((i) => i.page == currentIndex);

    final active = selectedSlot >= 0 ? _items[selectedSlot] : _items.first;

    // كبسولة عايمة على طريقة إنستجرام: أيقونات بس، وحبّة (pill) بتزحلق
    // تحت الأيقونة النشطة بدل ما كل تبويب يبقى ليه خلفية. وانت بتنزل
    // بالسكرول بتتلمّ لكبسولة صغيّرة فيها الأيقونة النشطة — من غير ما تختفي.
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        0,
        AppSpacing.gutter,
        safeBottom > 0 ? safeBottom : AppSpacing.s4,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          // زجاج حقيقي (BackdropFilter) زي بار إنستجرام — المحتوى بيبان
          // مضبّب تحته. الشعاع ده استثناء مقصود مع الشيتات وأزرار الهيدر.
          child: MaliGlass(
            variant: MaliGlassVariant.navigation,
            radius: 999,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            nativeMaterial: true,
            child: expanded
                ? _expandedRow(context, c, isDark, selectedSlot)
                : _collapsedPill(context, c, isDark, active),
          ),
        ),
      ),
    );
  }

  /// الحالة المفتوحة — كل الأيقونات وحبّة بتزحلق تحت النشطة.
  Widget _expandedRow(
      BuildContext context, AppColors c, bool isDark, int selectedSlot) {
    return LayoutBuilder(
      builder: (context, box) {
        final slotWidth = box.maxWidth / _items.length;
        return SizedBox(
          height: _slotHeight,
          child: Stack(
            children: [
              if (selectedSlot >= 0)
                AnimatedPositioned(
                  duration: AppMotion.moderate,
                  curve: AppMotion.springSmoothCurve,
                  left: slotWidth * selectedSlot,
                  top: 0,
                  bottom: 0,
                  width: slotWidth,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: DecoratedBox(
                      // v2 lens: white@10% dark / action@10% light.
                      decoration: ShapeDecoration(
                        color: isDark
                            ? const Color(0x1AFFFFFF)
                            : c.cta.withValues(alpha: 0.10),
                        shape: const StadiumBorder(),
                      ),
                    ),
                  ),
                ),
              Row(
                textDirection: TextDirection.ltr,
                children: [
                  for (final item in _items)
                    Expanded(
                      child: _NavTab(
                        item: item,
                        selected: item.page == currentIndex,
                        onTap: onSelect,
                      ),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// الحالة المقفولة — كبسولة صغيّرة فيها الأيقونة النشطة؛ الدوس عليها
  /// بيفتح البار تاني (زي ما الطلوع بالسكرول بيفتحه).
  Widget _collapsedPill(
      BuildContext context, AppColors c, bool isDark, _BottomBarItem active) {
    return Semantics(
      label: context.l10n.navExpandBar(active.label(context)),
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onExpand?.call();
        },
        child: SizedBox(
          height: _slotHeight,
          width: _slotHeight,
          child: DecoratedBox(
            decoration: ShapeDecoration(
              color: isDark
                  ? const Color(0x1AFFFFFF)
                  : c.cta.withValues(alpha: 0.10),
              shape: const StadiumBorder(),
            ),
            child: Center(
              child: Icon(active.icon, color: c.actionText, size: 24),
            ),
          ),
        ),
      ),
    );
  }
}

class _BottomBarItem {
  const _BottomBarItem({
    required this.page,
    required this.icon,
  });

  final int page;
  final IconData icon;

  /// The tab's name, in the reader's language. The list is `static const`, so
  /// it cannot hold localized copy; `page` is the stable key and the words
  /// live in the ARB. Only the Semantics layer reads this — the bar itself
  /// draws icons only.
  String label(BuildContext context) {
    final l = context.l10n;
    return switch (page) {
      0 => l.navHome,
      1 => l.navTransactions,
      2 => l.navBudgets,
      3 => l.navMore,
      4 => l.navAnalytics,
      _ => '',
    };
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _BottomBarItem item;
  final bool selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // أيقونة بس — الاسم بيفضل في الـ Semantics للقارئ الصوتي.
    final activeColor = c.actionText;
    final inactiveColor = c.textSecondary;

    return Semantics(
      label: item.label(context),
      selected: selected,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onTap(item.page);
        },
        child: AnimatedScale(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          scale: selected ? 1.06 : 1,
          child: Center(
            child: Icon(
              item.icon,
              color: selected ? activeColor : inactiveColor,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}

/// An additional caller restriction backed by the original admitted work.
/// The uploader still captures and validates its own real host capability.
class _NotificationCallerLifecycle implements SyncPhaseLifecycle {
  _NotificationCallerLifecycle(this.work, this.current);
  final AdmittedLocalWork work;
  final bool Function() current;
  @override
  AppDatabase get database => work.database;
  @override
  bool get isCurrent => current();
  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    if (!isCurrent) throw const StaleAdmissionException();
    return work.local(() {
      if (!isCurrent) throw const StaleAdmissionException();
      return action();
    });
  }
}
