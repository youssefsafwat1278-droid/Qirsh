import 'package:drift/native.dart';
import '../security/lock_prompt_language.dart';
import '../theme/theme_mode_controller.dart';
import '../../features/dashboard/home_hero_period_controller.dart';
import '../sync/pending_sync_reconciler.dart';
import '../sync/sync_health.dart';
import '../sync/outbox_failure.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Directory, File;

import '../session/admission_authority.dart';
import '../session/account_fence_authority.dart';
import '../session/account_fence_store.dart';
import '../auth/immediate_deletion_receipt_store.dart';
import 'asr_storage_reads.dart';
import 'automatic_session_recovery.dart';
import '../session/auth_stream_boundary.dart';
import '../session/rebootstrap_service.dart';
import '../di/rebootstrap_providers.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../data/catalog/seed_loader.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/usecases/user_settings_usecases.dart' show LoadUserSettingsUseCase;
import '../../data/db/app_database.dart';
import '../../data/db/creation_policy.dart';
import '../../data/db/database_access_broker.dart';
import '../../data/db/replica_store.dart';
import '../../data/db/planning_canonical_invariants.dart';
import '../../data/db/planning_cutover.dart';
import '../exporting/managed_export_store.dart';
import '../../data/repositories/account_currency_repair_service.dart';
import '../../data/repositories/drift_account_repository.dart';
import '../../data/repositories/drift_card_repository.dart';
import '../../data/repositories/drift_goal_repository.dart';
import '../../data/repositories/drift_transaction_repository.dart';
import '../../data/repositories/drift_user_settings_repository.dart';
import '../privacy/cloud_egress_gate.dart';
import '../auth/auth_coordinator.dart';
import '../auth/auth_diagnostics.dart';
import '../auth/legacy_session_source.dart';
import '../auth/refresh_transport.dart';
import '../auth/session_files.dart';
import '../auth/session_keychain.dart';
import '../auth/session_store.dart';
import '../../data/db/replica_location.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../privacy/consent_authority.dart';
import '../tracking/user_activity_service.dart';
import '../privacy/diagnostics_consent_gate.dart';
import '../../data/sync/sender_bank_mapping_sync_service.dart';
import '../../data/sync/seq_pull.dart';
import '../../data/sync/server_capabilities.dart';
import '../../domain/usecases/run_goal_auto_saves_usecase.dart';
import '../../features/capture/capture_runtime.dart';
import '../../features/capture/services/capture_device_registration_service.dart';
import '../../features/capture/services/native_capture_bridge.dart'
    show CaptureRemovalBarrierPresence, NativeCaptureBridge;
import '../../features/capture/services/pending_notification_actions.dart';
import '../../features/capture/services/local_notification_service.dart';
import '../../features/app/app_boot_loader.dart';
import '../../features/capture/services/notification_log_service.dart';
import '../../features/cards/brand_mark.dart';
import '../../features/planning_sync/services/outbox_queue_factory.dart';
import '../backend/metrics_client.dart';
import '../backend/supabase_config.dart';
import '../di/app_providers.dart';
import '../session/account_scope.dart';
import '../session/app_session.dart';
import '../session/capture_queue.dart';
import '../session/local_read_authority.dart';
import '../session/remove_data_flow.dart';

/// Thrown when [BootstrapRunner.run] exceeds [BootstrapRunner.timeout].
class BootstrapTimeoutException implements Exception {
  const BootstrapTimeoutException(this.lastStep);
  final String? lastStep;
  @override
  String toString() => 'BootstrapTimeoutException(lastStep: $lastStep)';
}

/// C1: the database-access coordinator could not be created or proven. Startup
/// stops here (an enforced outcome with a database-independent error screen and
/// Retry); nothing persistent has been opened, recovered, adopted or maintained.
class BootstrapCoordinatorUnavailable implements Exception {
  const BootstrapCoordinatorUnavailable(this.reason);
  final String reason;
  @override
  String toString() => 'BootstrapCoordinatorUnavailable($reason)';
}

/// ASR §6.7: a read the session store needs was temporarily unavailable
/// (protected data locked). `Supabase.initialize` was NOT called, no latch was
/// set and nothing restrictive was published; bootstrap re-runs from
/// `supabase_init` when protected data becomes available or on the next
/// foreground.
class BootstrapAuthDeferred implements Exception {
  const BootstrapAuthDeferred(this.reason);
  final String reason;
  @override
  String toString() => 'BootstrapAuthDeferred($reason)';
}

/// O-LC-1b: the Supabase SDK initialization failed (or its state in this
/// process cannot be proven to be a completed initialization). The SDK keeps a
/// half-built process-wide singleton after a failed `Supabase.initialize`, and a
/// later "already initialized" return is not evidence that the failed
/// initialization completed, so this and every later startup in the same process
/// stays failed closed until a fresh process.
class BootstrapSdkInitializationFailed implements Exception {
  const BootstrapSdkInitializationFailed(this.reason);
  final String reason;
  @override
  String toString() => 'BootstrapSdkInitializationFailed($reason)';
}

/// Runs every startup initialization step (Supabase, session restore, local
/// database, seed data, feature flags, capture registration) that used to run
/// unconditionally before `runApp()` in `main.dart`. Moved into a retained
/// object with its own state so [run] can be called again on retry without
/// re-opening the database or re-registering listeners a second time —
/// each side-effecting step below is memoized against a field on this class.
class BootstrapRunner {
  BootstrapRunner(
      {@visibleForTesting SupabaseClient? debugAuthClient,
      @visibleForTesting this.debugStorageEvent,
      @visibleForTesting this.debugCoordinatorEvent,
      @visibleForTesting this.debugAuthInitialize,
      @visibleForTesting this.debugSdk,
      @visibleForTesting this.debugAfterWithdraw})
      : _debugAuthClient = debugAuthClient;

  /// Test seam: runs the REAL production `Supabase.initialize` wiring (observing
  /// store, gated transport) without a compile-time backend configuration. Only
  /// the inner session store and the transport behind the gate are supplied.
  final BootstrapSdkTestConfig? debugSdk;
  bool get _realSdk => SupabaseConfig.isConfigured || debugSdk != null;

  /// Test seam standing in for `Supabase.initialize` when only a debug auth
  /// client exists: it runs (with that client) at the exact point where the real
  /// SDK initialization restores the persisted session and may emit auth events.
  final Future<void> Function(SupabaseClient client)? debugAuthInitialize;

  /// Test seam: an auth client standing in for `Supabase.instance.client` in the
  /// session-binding steps (the real SDK needs a configured backend and the
  /// network). Null in production.
  final SupabaseClient? _debugAuthClient;
  final void Function(String event)? debugStorageEvent;

  /// Test seam: `coordinator` when this runner created the inert coordinator,
  /// `coordinator-reused` when it adopted the retained one. Kept apart from
  /// [debugStorageEvent], which records storage effects only.
  final void Function(String event)? debugCoordinatorEvent;
  final Future<void> Function()? debugAfterWithdraw;
  SupabaseClient? get _authClient =>
      _realSdk ? Supabase.instance.client : _debugAuthClient;

  // A brand-new install pays a one-time cost here: SQLCipher key generation,
  // creating the encrypted DB file, and seeding the bundled catalog. Measured
  // ~20s on a debug build / cold simulator for that exact path (session
  // restore + database_open dominate). 30s leaves real margin above that
  // without letting a genuinely hung bootstrap spin indefinitely.
  static const Duration timeout = Duration(seconds: 30);

  AppDatabase? _database;
  ReplicaStore? _replicaStore;
  AccountScopeHost? _host;

  /// O: the inert coordinator, created once in this genuine foreground
  /// bootstrap before its first opener or destructive recovery entry. A retry of
  /// this runner (and a rebuilt runner, via the process-retained instance)
  /// reuses it; nothing is ever replaced. C1: when creation is refused (name
  /// collision, dead coordinator, no foreground root isolate) startup FAILS
  /// CLOSED with [BootstrapCoordinatorUnavailable] before any recovery, opener,
  /// adoption or maintenance; there is no fallback and no empty replacement.
  DatabaseAccessBroker? _coordinator;

  @visibleForTesting
  DatabaseAccessBroker? get debugCoordinator => _coordinator;

  void _ensureCoordinator() {
    final existing = _coordinator;
    if (existing != null && existing.isProven) return;
    final reused = DatabaseAccessBroker.hasRetained;
    try {
      // A retry reuses a PROVEN existing coordinator or stays denied: it never
      // unregisters another registration and never fabricates a replacement.
      _coordinator = DatabaseAccessBroker.createInert();
      debugCoordinatorEvent
          ?.call(reused ? 'coordinator-reused' : 'coordinator');
    } on DatabaseAccessUnavailable catch (e) {
      _coordinator = null;
      throw BootstrapCoordinatorUnavailable(e.reason);
    }
    AppSession.instance.configureDatabaseCoordinator(_coordinator!);
  }

  StreamSubscription<AuthState>? _senderBankAuthSubscription;
  RemoveDataFlow? _removeData;
  bool _residueHookRegistered = false;
  bool _supabaseInitialized = false;

  /// O-LC-1b: process-wide (static, so a replacement runner is covered too). Set
  /// the moment a `Supabase.initialize` call throws, or when the SDK is found
  /// initialized without this process having proven that initialization. Never
  /// cleared in production: the SDK's half-built singleton cannot be disposed,
  /// and only a fresh process is a proven reset boundary.
  static bool _sdkInitLatched = false;

  /// Set only when this process's own `Supabase.initialize` returned normally on
  /// an SDK that was not initialized before the call.
  static bool _sdkInitProven = false;

  /// Test-only: models a fresh process (the only supported reset boundary).
  @visibleForTesting
  static void debugResetSdkInitializationLatch() {
    _sdkInitLatched = false;
    _sdkInitProven = false;
  }

  static bool _sdkAlreadyInitialized() {
    try {
      return Supabase.instance.isInitialized;
    } catch (_) {
      return false;
    }
  }

  final AuthInitEventBuffer _initEvents = AuthInitEventBuffer();

  /// The startup provenance buffer, for tests that drive it through the debug
  /// auth seam (the real SDK path is covered with the observing store itself).
  @visibleForTesting
  AuthInitEventBuffer get debugAuthInitEvents => _initEvents;
  bool _debugAuthInitialized = false;
  final List<Future<void>> _provenanceDenials = [];
  LocalReadStartupBinding? _lrBinding;

  /// Completes when every denial started by a late storage classification did.
  @visibleForTesting
  Future<void> get debugProvenanceDenials =>
      Future.wait(List.of(_provenanceDenials));
  bool _senderBankSyncStarted = false;
  bool _senderShutdown = false;
  bool _senderObserversInstalled = false;
  Future<void>? _senderShutdownCompletion;
  final Set<Future<void>> _senderJobs = {};
  final Set<(AccountScope, String, int, int)> _senderReceiving = {};
  (AccountScope, String, int, int)? _senderSessionReadyKey;
  final List<(Object, StackTrace)> _senderUnexpected = [];
  final Set<Future<void>> _pendingBootstrapWork = {};
  final List<(Object, StackTrace)> _unexpectedBootstrapWork = [];

  bool _goalAutoSavesRan = false;
  bool _cardBackfillRan = false;
  bool _accountCurrencyRepairRan = false;
  bool _cardIdentityBackfillRan = false;
  bool _dbKeyRefCleanupRan = false;
  String? _lastStep;

  /// Whether any transaction existed when bootstrap finished — read by
  /// `startupHasLocalDataProvider` so Home only shows the first-launch
  /// skeleton when there is truly nothing to render yet. Defaults to `true`
  /// (no skeleton) so a failed check can never cause a data-having user to
  /// see skeletons.
  bool hasLocalData = true;

  /// MALI-026 (B8-3) — the planning cutover state resolved from the opened DB.
  PlanningCutoverState planningCutoverState = PlanningCutoverState.canonical;

  /// The consent gate the last-seen activity ping is wired to (C-3). The callback
  /// is RETAINED by the static service for the life of the process, over the
  /// database of the scope that configured it, so it is consulted at the moment of
  /// egress and ends in `CloudEgressGate.permits()`: after a writable-to-local-read
  /// replacement the gate denies (and a closed old database throws, which the
  /// ping swallows), whatever consent that old scope had saved (R15). Signed-out:
  /// always closed.
  @visibleForTesting
  static Future<bool> Function() activityConsentGate({
    required String? uid,
    required Future<UserSettingsEntity> Function() settings,
  }) =>
      uid == null
          ? () async => false
          : () =>
              ConsentAuthority(settings).allows(EgressClass.profileAndSettings);

  /// Name of the step that was running when the most recent [run] call
  /// failed (or is currently running). `'database_open'` specifically means
  /// the local encrypted DB could not be opened (corrupt file/key mismatch)
  /// — callers should offer a reset action rather than a plain retry.
  String? get lastStep => _lastStep;

  /// Deletes the unopenable encrypted DB file so the next [run] can create a
  /// fresh one. Only relevant when [lastStep] is `'database_open'`.
  Future<void> resetDatabaseAndRetry() async {
    _ensureCoordinator(); // before this destructive entry
    // WP-3b: the file that failed to open is the signed-in account's replica
    // (or the legacy file still in use), never a shared one.
    final location = await (_replicaStore ??= ReplicaStore()).activeLocation();
    if (location != null) {
      await AppDatabase.deleteDatabaseFile(location: location);
    }
    _database = null;
  }

  /// The account-scope host (WP-3b). Valid once [run] has completed; the root
  /// widget listens to it and rebuilds its `ProviderScope` on every switch.
  AccountScopeHost get accountScope => _host!;

  /// Runs the full startup sequence, or resumes/retries a previous attempt
  /// without repeating steps that already completed. Returns the ready
  /// [AppDatabase] to be handed to `appDatabaseProvider`.
  Future<AppDatabase> run() {
    return _runSteps().timeout(
      timeout,
      onTimeout: () => throw BootstrapTimeoutException(_lastStep),
    );
  }

  Future<AppDatabase> _runSteps() async {
    // Runs in EVERY build mode. In release a missing/non-production Supabase
    // configuration throws (fail closed → startup error screen) instead of
    // silently proceeding into stub auth / no cloud (MALI-003).
    _assertRuntimeConfig();

    await _loadInitialSettingsLanguage();

    // O: the inert coordinator exists before any recovery, session load or
    // Drift opener below. It authorizes nothing by existing.
    _ensureCoordinator();
    AppSession.instance.configureLocalRead(LocalReadAuthority(
      store: SecureLocalReadStore(),
      // ASR §12 E7: the status-preserving read of the same Keychain item.
      strictRead: () {
        final coord = AuthCoordinator.active;
        if (coord == null) throw StateError('no_coordinator');
        return AsrStrictReads(coord.store.keychain)
            .read(SecureLocalReadStore.storageKey);
      },
    ));
    // O-LC-1a: this startup's identity for late classifications, captured once
    // per runner before any SDK initialization can classify anything.
    final binding =
        _lrBinding ??= await AppSession.instance.beginLocalReadStartupBinding();

    // Astra G (P1): the ONE admission gate. The owner it judges is the admitted
    // replica's owner marker; background token auto-refresh follows the gate
    // (stopped while Cloud is OFF / DISABLING / uncertain).
    final egressGate = CloudEgressGate.instance
      ..configureActiveOwner(localDataOwnerUid)
      ..configureSessionUsable(() {
        if (!_supabaseInitialized) return false;
        final s = Supabase.instance.client.auth.currentSession;
        // A retained SDK token is not committed application admission.
        // Explicit auth recovery remains available if launch could not admit
        // this identity; ordinary egress is still governed by the frozen gate.
        final admitted = AppSession.instance.captureConsentCapability();
        return s != null &&
            !s.isExpired &&
            admitted != null &&
            admitted.uid == s.user.id;
      })
      // D6: under a verified local-read scope the gate admits only an explicit
      // account-control exchange, whatever Cloud/AI state was saved.
      ..localReadActive = (() => AppSession.instance.localReadEgressDenied)
      // ASR §12: the session-only refresh reads the secure layers keeping the
      // OS status (only a confirmed not-found is absence).
      ..strictSecureSlot = ((key) {
        final coord = AuthCoordinator.active;
        if (coord == null) throw StateError('no_coordinator');
        return AsrStrictReads(coord.store.keychain).slot(key);
      })
      ..nativeVerifiedOff = ((owner) async =>
          (await NativeCaptureBridge.inspectRecoveryEvidence(ownerUid: owner))
              ?.verifiedOff ??
          false)
      ..onPermitChanged = (permits) async {
        if (!_supabaseInitialized) return;
        final auth = Supabase.instance.client.auth;
        // ASR §3.3: the coordinator scheduler is the single refresher; the SDK
        // ticker is never started. Owner decision (2026-10-29): it runs with
        // Cloud OFF too; each tick asks the session-only refresh policy.
        final coord = AuthCoordinator.active;
        if (coord != null) {
          auth.stopAutoRefresh();
          coord.setSchedulerEnabled(true);
          return;
        }
        if (permits) {
          auth.startAutoRefresh();
        } else {
          auth.stopAutoRefresh();
        }
      };

    // WP-3b — the account-scope host. The actual launch ORDER (Astra D1) is:
    //   1. durable removal state (below), before anything can admit or open;
    //   2. Supabase initialization, observed for auth events (D2);
    //   3. the offline local-read decision (this may publish a read-only scope);
    //   4. ONLY if no local-read scope was published: replica recovery + legacy
    //      adoption, which still precede the session reconcile that could claim
    //      the owner marker (an unowned legacy database is quarantined, never
    //      adopted by whoever is restored, B4).
    // Recovery, adoption and the retired purge therefore do NOT run first on the
    // local-read path: they are deferred to a launch under ordinary authority.
    final host = _host ??= _buildAccountScopeHost();
    // O-LC-1: unknown persisted-state provenance, whenever it is established
    // (during `Supabase.initialize` or later in the SDK's unawaited recovery),
    // locks the process and starts the durable denial at that moment.
    _initEvents.onUnknownProvenance = (_) {
      _provenanceDenials.add(AppSession.instance
          .denyLocalReadAfterInitializationLoss(host, binding: binding)
          .then<void>((_) {}, onError: (Object _) {}));
    };
    _installSenderObservers();

    // F2 — the durable removal state is loaded and acted on BEFORE anything can
    // admit, adopt or open: auth is not yet bound, no legacy adoption has run, no
    // replica is open. A pending/unreadable removal or a native barrier of
    // unknown uid BLOCKS the launch: no legacy adoption, no auth binding or
    // reconcile, no replica opened or admitted, nothing routed as authenticated —
    // the signed-out scope is opened and that is all. A stale owner marker of a
    // removed uid is cleared, not opened.
    var launchBlocked = !await _step(
        'account_fence_readiness', AccountFenceAuthority.shared.initialize);
    await _step('removal_recovery', () async {
      _registerRemoveData();
      await AppSession.instance.load();
      launchBlocked =
          (await AppSession.instance.prepareLaunchAdmission()).blocked ||
              launchBlocked;
    });

    // SDK initialization restores the persisted session from local storage, and
    // may also run recovery work in the background (gotrue's recoverSession is
    // not awaited by `Supabase.initialize`). That is NOT a network guarantee by
    // itself: what keeps it off the network is the gated transport below (the
    // gate is unresolved, so every request is denied), and what keeps it from
    // being misread is the auth-event buffer (D2). The offline decision below
    // needs to know whether the session is fresh, expired or absent AND whether
    // the SDK emitted a restrictive loss while initializing.
    if (_realSdk && !_supabaseInitialized) {
      await _step('supabase_init', () async {
        // SDK init restores the persisted session from LOCAL storage and
        // refreshes the token in the background — it does not block the first
        // frame on a network round-trip. Required before session binding (owner
        // identity), so it stays on the critical path.
        // Every Supabase request (auth, postgrest, functions, storage) goes
        // through the gated transport. Astra H2.3: the gate is UNRESOLVED here
        // (the egress reconciliation runs in `capture_registration`, once the
        // replica is open), so it denies EVERYTHING — the restore of an expired
        // session, gotrue's own refresh retries and the recovery timer reach
        // nothing. `autoRefreshToken: false` is deliberately NOT used: gotrue's
        // `recoverSession` (gotrue_client.dart:1127-1133) signs the user OUT
        // locally when the persisted token is expired and auto-refresh is off,
        // i.e. on nearly every cold start after an hour. Instead the ticker the
        // SDK starts is stopped immediately below and (re)started only when the
        // gate permits (onPermitChanged / the resume guard).
        // O-LC-1b: a failed initialization is never retried and an "already
        // initialized" SDK is never taken as proof of success.
        final alreadyInitialized = _sdkAlreadyInitialized();
        if (_sdkInitLatched || (alreadyInitialized && !_sdkInitProven)) {
          _sdkInitLatched = true;
          throw const BootstrapSdkInitializationFailed(
              'sdk_initialization_not_proven');
        }
        await debugSdk?.beforeInitialize?.call();
        final sdkUrl = debugSdk?.url ?? SupabaseConfig.url;
        // ASR §6.7/§6.8: the coordinator's store is loaded BEFORE the SDK
        // exists; a temporarily unavailable read defers auth (no init, no latch).
        final coord = await _prepareAuthCoordinator();
        final load = coord?.loadResult;
        AuthDiagnostics.add('session_start '
            '${load?.loadClass.name ?? 'legacy'} '
            'record=${load?.record == null ? 'no' : 'yes'} '
            'served=${load?.served == null ? 'no' : 'yes'}');
        if (load?.loadClass == LoadClass.unknownProvenance) {
          _initEvents.markUnknownProvenance('session_store');
        }
        final serve = coord == null
            ? null
            : CoordinatedSessionServe(
                served: load!.served?.session,
                onInitialize: () {
                  coord.attach(GoTrueAuthPort(Supabase.instance.client.auth));
                  coord.beginInit();
                });
        try {
          if (debugSdk == null) {
            await Supabase.initialize(
              url: SupabaseConfig.url,
              anonKey: SupabaseConfig.anonKey,
              httpClient: GatedHttpClient(),
              // D2: the event buffer is installed by the session store's initialize,
              // which runs before any initial/recovery event can be emitted.
              authOptions: FlutterAuthClientOptions(
                // ASR §3.4: the app has no redirect flow.
                detectSessionInUri: false,
                localStorage: ObservingAuthLocalStorage(
                    _initEvents, SupabaseConfig.url,
                    coordinated: serve),
              ),
            );
          } else {
            // Test wiring: the same observing store and gated transport over a
            // scripted inner store / counting transport.
            await Supabase.initialize(
              url: sdkUrl,
              anonKey: 'synthetic-anon',
              httpClient: GatedHttpClient(debugSdk!.innerHttp),
              authOptions: FlutterAuthClientOptions(
                detectSessionInUri: false,
                localStorage: ObservingAuthLocalStorage(_initEvents, sdkUrl,
                    inner: debugSdk!.innerStorage, coordinated: serve),
              ),
            );
          }
          if (coord != null) {
            coord.endInit(served: load!.served);
            AuthCoordinator.active = coord;
            egressGate.asrQuiesced = coord.handoverQuiesced;
            // Owner decision (2026-10-29): the session-only refresh, also
            // while Cloud is OFF (never any other egress).
            coord.routinePermitted = egressGate.permitsSessionRefresh;
            coord.ordinaryAdmissionHeld = () =>
                AppSession.instance.status == SessionStatus.authenticated &&
                !AppSession.instance.localReadEgressDenied;
          }
        } catch (_) {
          _sdkInitLatched = true;
          // O-LC-1: a failure the storage layer itself classified (an inner
          // initialize / hasAccessToken / accessToken failure marks the buffer)
          // is connected to the process lock and the durable denial BEFORE the
          // startup failure is returned. A failure that did not come from the
          // storage layer classifies nothing, whatever it is named. The denial
          // reports its own incompleteness (`localReadCleanupIncomplete`).
          if (_initEvents.unknownProvenance) {
            if (_provenanceDenials.isEmpty) {
              _provenanceDenials.add(AppSession.instance
                  .denyLocalReadAfterInitializationLoss(host, binding: binding)
                  .then<void>((_) {}, onError: (Object _) {}));
            }
            await Future.wait(List.of(_provenanceDenials));
          }
          rethrow;
        }
        if (!alreadyInitialized) _sdkInitProven = true;
        _supabaseInitialized = true;
        final auth = Supabase.instance.client.auth;
        auth.stopAutoRefresh();
        _resumeGuard ??= AutoRefreshResumeGuard()..attach();
        _wireAutomaticSessionRecovery(egressGate);
        final active = AuthCoordinator.active;
        if (active != null) {
          active.setSchedulerEnabled(true);
        } else if (await egressGate.permits()) {
          auth.startAutoRefresh();
        }
      });
    }

    final debugInit = debugAuthInitialize;
    final debugClient = _debugAuthClient;
    if (!SupabaseConfig.isConfigured &&
        debugInit != null &&
        debugClient != null &&
        !_debugAuthInitialized) {
      await _step('supabase_init', () async {
        _initEvents.attach(debugClient);
        await debugInit(debugClient);
        _debugAuthInitialized = true;
      });
    }

    // Offline local read: an expired or absent SDK session with a valid grant
    // restores the account's own replica READ-ONLY. Decided after the removal-
    // first handling above and BEFORE ordinary replica recovery, legacy
    // adoption, the retired purge and any service init; those are deferred (they
    // run under their own normal authorization, never under a local-read grant).
    var localRead = false;
    if (_database == null && !launchBlocked) {
      await _step('local_read_decision', () async {
        final client = _authClient;
        final sdk = client?.auth.currentSession;
        AuthDiagnostics.add('local_read_start '
            'sdk=${sdk == null ? 'absent' : sdk.isExpired ? 'expired' : 'fresh'} '
            'provenance=${_initEvents.provenanceIntact ? 'intact' : 'denied'}');
        if (client != null && (sdk == null || sdk.isExpired)) {
          if (!_initEvents.provenanceIntact) {
            // D2/R12: a signedOut/userDeleted was emitted during SDK
            // initialization, or the persisted state could not be verified as
            // empty or valid. The null/expired session is then a LOSS (or an
            // unknown cause), never plain absence or ordinary expiry:
            // restrictive, durably denied.
            await AppSession.instance
                .denyLocalReadAfterInitializationLoss(host);
          } else {
            // R10.1: the event buffer is also the publication fence: a loss
            // observed at ANY await of the restoration refuses publication.
            localRead = await AppSession.instance.restoreLocalReadAccess(
              host: host,
              provenanceIntact: () => _initEvents.provenanceIntact,
              binding: binding,
            );
          }
        }
      });
    }

    if (_database == null && !launchBlocked && !localRead) {
      await _step('replica_recovery', host.recoverAtLaunch);
      // WP-7: an unfinished rebootstrap keeps capture delivery and egress frozen
      // until the next sync cycle resumes it from its phase marker.
      if ((await _replicaStore!.pendingRebootstraps()).isNotEmpty) {
        ReplicaFreeze.instance.freeze();
      }
    }

    await _step('session_restore', () async {
      final client = _authClient;
      if (client != null && !launchBlocked) {
        await AppSession.instance.bindSupabaseAuth(client);
        // D2: a loss emitted after the decision above but before this binding
        // listened is replayed from the buffer: it must not be missed.
        if (!_initEvents.provenanceIntact &&
            (client.auth.currentSession?.isExpired ?? true)) {
          await AppSession.instance.denyLocalReadAfterInitializationLoss(host);
        }
      }
      // AppSession now listens to the same client; the buffer's job is done.
      await _initEvents.release();
    });

    // No notification service in local-read: it can raise and act on captures.
    final initialCaptureTransactionId = localRead
        ? null
        : await _step(
            'notifications_init',
            () => LocalNotificationService.instance.initialize(),
          );

    // The residue purge is DB-independent, so it is registered before the replica
    // opens: a changed owner's purge then resolves BEFORE any replica is opened,
    // and bootstrap opens the right one straight away (never the previous
    // owner's first).
    await _step('residue_purge_registration', () async {
      _registerCaptureOwnerHooks();
      // Owner gate (MALI-002): the first session reconcile ran before this hook
      // existed. If it deferred a changed-owner purge, resolve it now so the
      // marker names the signed-in uid before its replica is opened.
      final client = _authClient;
      if (client != null && !launchBlocked) {
        await AppSession.instance.resolvePendingLocalDataOwnerConflict(client);
      }
    });

    // §4.4 crash safety: a removal still pending resumes here again (it could not
    // finish earlier) and blocks the launch owner while it cannot. Open-existing
    // only: a launch never creates a replica.
    final launch = launchBlocked
        ? const LaunchAdmission.blocked()
        : await AppSession.instance.prepareLaunchAdmission();
    final launchUid = launch.blocked ? null : launch.uid;
    if (host.current == null) {
      // The launch-specific private reservation is minted by AppSession for the
      // owner it chose above; the open is tracked before any opener runs.
      final reserveLaunch = AppSession.instance.coldLaunchReserver(launch);
      await _step('database_open',
          () => host.openAtLaunch(launchUid, reserveLaunch: reserveLaunch));
      // The owner marker names a uid whose replica could not be opened (missing,
      // locked, quarantined): the signed-out scope is open, so the session must
      // not look authenticated. Routing to sign-in lets an explicit sign-in
      // create or unlock it.
      if (launchUid != null && host.current?.uid == null) {
        AppSession.instance.markSessionInvalid();
      }
    }
    AppSession.instance.configureAccountScope(host);
    _receiveSenderBankMapping();
    final scope = host.current!;
    // A usable scope whose initialization never resolved the egress latch (an
    // offline local-read scope runs no account initialization; a recovered
    // failure) is resolved here, restrictively and read-only with respect to the
    // account database. Settings alignment, pending-disable completion and the
    // owner-generation repair wait for the authorized writable reconcile.
    if (!egressGate.isResolved) {
      await _step(
          'egress_resolution',
          () => egressGate.resolveRestrictively(egressGate.beginResolution(),
              owner: scope.uid,
              freezeTag: scope.isLocalRead ? null : 'startup_unresolved'));
    }
    final database = _database = scope.database;
    hasLocalData = scope.hasLocalData;
    planningCutoverState = scope.planningCutoverState;

    if (initialCaptureTransactionId != null) {
      CaptureRuntime.instance
          .seedInitialConfirmation(initialCaptureTransactionId);
    }

    // B2-C — the safety-critical phase (config, DB open, liveness, admission/
    // owner-conflict, seed, local flags, owner-safe backfills) is complete: the
    // local financial UI is usable. Flip the milestone, then run the deferred,
    // non-critical, off-the-first-frame work (housekeeping only) WITHOUT gating
    // the return.
    localFinancialUiUsable.value = true;
    // ASR §8: from local read on cold start, after the shell's first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _asrFirstFrame = true;
      AutomaticSessionRecovery.active?.trigger();
    });
    if (!localRead) _observeBootstrapWork(_runDeferredStartupWork);
    // B2-C — the `app_open` metric is a REMOTE, best-effort telemetry RPC, fired
    // off the critical path. Astra H2.3: only when the gate PERMITS (resolved and
    // a durable ON record), so it is checked here, after the reconciliation, and
    // never at Supabase init.
    if (SupabaseConfig.isConfigured && !localRead) {
      _observeBootstrapWork(_logAppOpenIfPermitted);
    }

    if (kDebugMode) {
      debugPrint(
        '[Bootstrap] done — session=${AppSession.instance.status.name}',
      );
    }
    return database;
  }

  bool _asrFirstFrame = false;
  String? _asrLocalReadOwner;
  _AsrLifecycleObserver? _asrLifecycle;

  /// ASR (design v7.2 §8): one orchestrator per coordinator. Triggers: the
  /// first frame (above), every resume, and every transition into local read
  /// once the first frame was drawn.
  void _wireAutomaticSessionRecovery(CloudEgressGate egressGate) {
    final coord = AuthCoordinator.active;
    if (coord == null) return;
    final previous = AutomaticSessionRecovery.active;
    if (previous != null && identical(previous.coordinator, coord)) return;
    previous?.dispose();
    final session = AppSession.instance;
    final asr = AutomaticSessionRecovery(
      coordinator: coord,
      gate: egressGate,
      host: AppSessionAsrHost(session, Supabase.instance.client),
      capture: RegistrationAsrCapture(
          () => _captureRegistration, egressGate, session,
          consentAccepted: () async {
        final db = _host?.current?.database;
        if (db == null) return false;
        return (await DriftUserSettingsRepository(db).getSettings())
            .cloudProcessingEnabled;
      }),
    );
    AutomaticSessionRecovery.active = asr;
    egressGate.asrQuiesced = () async {
      await asr.quiesced();
      // Phase 4c B8: refuses promptly when a transport closure is unconfirmed.
      await coord.handoverQuiesced();
    };
    egressGate.asrSuccessorUnsettled =
        () => asr.unsettledFinalizationOwner != null;
    // §12: every read whose absence passes keeps the OS status; only a
    // confirmed not-found is absence, anything else throws and denies.
    final reads = AsrStrictReads(coord.store.keychain);
    session.configureAsrEligibility((owner) async {
      // E5 native.
      final barrier = await captureQueue.getCaptureRemovalBarrier();
      if (barrier.presence != CaptureRemovalBarrierPresence.absent) {
        return 'barrier';
      }
      // E5 Dart: no removal in progress, [owner] not removed since.
      if (RemoveDataFlow.barrierPending(
              await reads.read(RemoveDataFlow.barrierKey)) ||
          RemoveDataFlow.parseRevokedUids(
                  await reads.read(RemoveDataFlow.revokedKey))
              .contains(owner)) {
        return 'removal';
      }
      // E3 Dart: both pending layers, the secure one status-preserving.
      final pending = await egressGate
          .readPendingVia(reads.slot(CloudEgressStore.kPendingSecureKey));
      if (pending.blocks(owner)) return 'pending';
      // E6: the authority's cleanup lane, then a confirmed read of the store.
      try {
        await AccountFenceAuthority.shared.guard(owner);
      } catch (_) {
        return 'fence';
      }
      final fence = reads.fenceStore();
      if (!await fence.load() ||
          !fence.allows(AccountFenceStore.ownerDigest(owner))) {
        return 'fence';
      }
      // E10.
      if (await ImmediateDeletionReceiptStore(read: reads.read).load(owner) !=
          null) {
        return 'deletion';
      }
      // E11.
      final store = _replicaStore;
      if (store == null ||
          !await store.asrRegistryPermits(owner, read: reads.read)) {
        return 'registry';
      }
      return null;
    });
    if (_asrLifecycle == null) {
      _asrLifecycle = _AsrLifecycleObserver()..attach();
      session.addListener(() {
        final owner = session.asrLocalReadOwner;
        if (owner != null && owner != _asrLocalReadOwner && _asrFirstFrame) {
          AutomaticSessionRecovery.active?.trigger();
        }
        _asrLocalReadOwner = owner;
      });
    }
  }

  Future<void> _logAppOpenIfPermitted() async {
    try {
      if (!await CloudEgressGate.instance.permits()) return;
      await MetricsClient().logEvent('app_open');
    } catch (_) {
      // Best-effort telemetry; never surfaces.
    }
  }

  AutoRefreshResumeGuard? _resumeGuard;

  /// WP-3b — the per-account startup steps. Run by the account-scope host on
  /// EVERY database it opens (launch, sign-in of another uid, sign-out), before
  /// the scope is published. [uid] is null for the signed-out scope: only the
  /// steps that make the database and the process-wide singletons safe to use are
  /// run; nothing that reads, repairs or syncs account data.
  Future<AccountScopeInit> _initializeAccount(
      AppDatabase database, String? uid) async {
    // Everything bound to the previous account's database is released first.
    await _senderBankAuthSubscription?.cancel();
    _senderBankAuthSubscription = null;
    _senderBankSyncStarted = false;
    _goalAutoSavesRan = false;
    _cardBackfillRan = false;
    _accountCurrencyRepairRan = false;
    _cardIdentityBackfillRan = false;
    _dbKeyRefCleanupRan = false;
    var localData = true;
    var cutover = PlanningCutoverState.canonical;
    // This scope's claim to resolve the egress latch, taken before any service
    // exists; a successor scope's initialization supersedes it.
    final resolution = CloudEgressGate.instance.beginResolution();

    await _step('has_local_data', () async {
      try {
        final row = await database
            .customSelect('SELECT EXISTS(SELECT 1 FROM transactions) AS d')
            .getSingle();
        localData = row.read<int>('d') != 0;
      } catch (_) {
        localData = true;
      }
    });

    // MALI-026 (B8-3 §1/§12) — resolve the REAL planning cutover state from the
    // opened DB (marker + canonical invariants). A fresh v30 install is canonical;
    // an upgraded-with-data DB is unresolved (P1). main() provides this as the
    // coordinator's initial state so guard/nav/reads react correctly from launch.
    await _step('planning_cutover_state', () async {
      cutover = await computePlanningCutoverState(
        () async =>
            (await database.customSelect('PRAGMA user_version;').getSingle())
                .read<int>('user_version'),
        () async => (await database
                .customSelect(
                    'SELECT planning_cutover_state AS s FROM user_settings;')
                .getSingle())
            .read<int>('s'),
        () async => (await planningCanonicalViolations(database)).length,
      );
    });

    await _step('seed_catalog', () async {
      await const SeedLoader().seedIfEmpty(database);
      bool currentScope() => _host?.current?.uid == uid &&
          identical(_host?.current?.database, database);
      final settings = DriftUserSettingsRepository(database);
      final notifications = LocalNotificationService.instance;
      notifications.historyStore = (entry) =>
          settings.appendNotificationHistory(entry, isCurrent: currentScope);
      notifications.logService =
          NotificationLogService(database, isCurrentScope: currentScope);
      await _registerBrandLogos();
    });

    // B2-C — LOCAL feature-flag init only (cached flags; makes `featureFlags`
    // usable and thus critical). The NETWORK override refresh is deferred: the
    // post-frame `syncCatalog` re-runs this with overrides, so the first frame
    // never blocks on a remote flag fetch (§12: no remote config on the critical
    // path).
    await _step(
      'feature_flags_init',
      () => initFeatureFlagService(database, applyRemoteOverrides: false),
    );

    await _step('capture_registration', () async {
      // New account scope (P4). ASR §11.2: the scope an ASR adoption opens is
      // that op's own transition, named by its admission authority.
      CloudEgressGate.instance.advanceEpoch(
          EpochCause.scopeInit, _host?.initializingAuthority?.causeAuthority);
      final captureRegistration = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(database),
        isIos: debugCaptureIsIos,
        isCurrentScope: () =>
            identical(_host?.current?.database, database) &&
            _host?.current?.uid == uid,
        publishOwner: captureQueue.publishCaptureOwner,
        readOwnerEpoch: captureQueue.captureOwnerEpoch,
      );
      _captureRegistration = captureRegistration;
      _captureRegistrationBinding =
          (service: captureRegistration, database: database, uid: uid);
      // ASR §7.5.2: a session record left in `finalizing` settles its successor
      // before anything below reconciles capture state; one left unsettled
      // keeps generic reconciliation blocked (B2) until a later attempt.
      final asr = AutomaticSessionRecovery.active;
      if (uid != null && asr != null && !asr.running) {
        await asr.reconcileSuccessorFinalization(uid);
      }
      // E1: a Cloud-OFF transition that a dead process left half-done is
      // committed (without any revoke) before anything else can egress.
      await captureRegistration.resolvePendingDisable(resolution: resolution);
      AppSession.instance.configureCaptureDeviceUnlink(
        captureRegistration.unlinkCurrentDevice,
      );
      // C-3 — last-seen tracking is an egress about this person's behaviour.
      // The service is static and cannot reach the database, so the gate is
      // wired here, where it can. It defaults CLOSED, so a build that never
      // reaches this line transmits nothing. Re-pointed on every account switch,
      // and closed again for the signed-out scope.
      UserActivityService.configureConsentGate(activityConsentGate(
        uid: uid,
        settings: () => DriftUserSettingsRepository(database).getSettings(),
      ));
      if (uid != null) {
        _observeBootstrapWork(
          () => captureRegistration.syncBackendState().catchError((_) {
            // Capture backend registration is optional; local fallback remains active.
          }),
        );
      }
    });

    // Binds health persistence to THIS database (and drops the previous
    // account's in-memory state).
    _observeBootstrapWork(() => SyncHealth.shared.attach(database));
    if (uid == null) {
      DiagnosticsConsentGate.revoke();
      return AccountScopeInit(
          hasLocalData: localData, planningCutoverState: cutover);
    }

    // MALI-058n — clear any legacy raw-key value from the deprecated
    // db_encryption_key_ref column. Runs AFTER admission (the identity above is
    // established), is idempotent (no-op once empty), touches only that column,
    // and never reads the value into logs/errors. Best-effort: a failure leaves
    // the value in place but backup generation already refuses to serialize it.
    if (!_dbKeyRefCleanupRan) {
      await _step('db_key_ref_cleanup', () async {
        try {
          await database.clearDeprecatedDbKeyRef();
        } catch (_) {
          // Never block startup; the value never leaves the device regardless.
        } finally {
          _dbKeyRefCleanupRan = true;
        }
      });
    }

    if (!_goalAutoSavesRan) {
      await _step('goal_autosaves', () async {
        try {
          await RunGoalAutoSavesUseCase(
            DriftGoalRepository(
              database,
              outboxQueue: buildPlanningOutboxQueue(database,
                  coordinator: FixedPlanningCutoverCoordinator(cutover)),
            ),
          ).call();
        } catch (_) {
          // Auto-save is best-effort; never block startup on it.
        } finally {
          _goalAutoSavesRan = true;
        }
      });
    }

    // OD-05 (C-3) — settings are readable now, so resolve the diagnostics gate.
    // Sentry was armed in main() before the DB existed and defaults to DENY, so
    // this is the first moment crash reporting can legitimately open. Failure
    // leaves it shut: an unsent crash report costs a diagnostic, an unconsented
    // one costs a privacy promise.
    await _step('diagnostics_consent_gate', () async {
      try {
        final settings =
            await LoadUserSettingsUseCase(DriftUserSettingsRepository(database))
                .call();
        DiagnosticsConsentGate.set(
          ConsentAuthority.decide(EgressClass.diagnostics, settings),
        );
      } catch (_) {
        DiagnosticsConsentGate.revoke();
      }
    });

    if (!_accountCurrencyRepairRan) {
      await _step('account_currency_repair', () async {
        try {
          // C-9 — the legacy per-currency account repair. This used to run
          // inside `dashboardDataProvider`, so opening Home created accounts,
          // reassigned transactions and (because both repositories enqueue)
          // produced cloud sync intent from a READ. It belongs here: an
          // explicit, owner-scoped startup command, before the financial UI is
          // marked usable.
          //
          // Idempotent by construction — it only creates a currency that has no
          // account and only touches `account_id IS NULL` rows — so a repaired
          // install writes nothing on later boots and therefore queues no
          // duplicate outbox rows.
          final settings = await LoadUserSettingsUseCase(
                  DriftUserSettingsRepository(database))
              .call();
          await AccountCurrencyRepairService(
            database: database,
            accounts: DriftAccountRepository(
              database,
              outboxQueue: buildPlanningOutboxQueue(database,
                  coordinator: FixedPlanningCutoverCoordinator(cutover)),
            ),
            // Both outboxes are wired deliberately: the repair changes real
            // financial state, so it must still reach other devices exactly as
            // it did from the dashboard. Idempotence — not the absence of a
            // queue — is what stops repeat boots from re-enqueueing.
            transactions: DriftTransactionRepository(
              database,
              outboxQueue: buildLedgerOutboxQueue(database,
                  coordinator: FixedPlanningCutoverCoordinator(cutover)),
            ),
          ).run(fallbackCurrency: settings.currency);
        } catch (_) {
          // Opportunistic, exactly like the card backfill: a failure leaves the
          // legacy rows for the next boot, it never blocks startup.
        } finally {
          _accountCurrencyRepairRan = true;
        }
      });
    }

    await _step('goal_account_repoint', () async {
      try {
        // G6: link account-less goals to the default account WITH sync intent
        // (this was a raw migration write that left no outbox row). Idempotent.
        await DriftGoalRepository(
          database,
          outboxQueue: buildPlanningOutboxQueue(database,
              coordinator: FixedPlanningCutoverCoordinator(cutover)),
          coordinator: FixedPlanningCutoverCoordinator(cutover),
        ).repointOrphanGoalsToDefaultAccount();
      } catch (_) {
        // Best-effort: a refused mutation (unresolved cutover) retries next boot.
      }
    });

    await _step('pending_sync_reconcile', () async {
      try {
        // A-4b: bypass writers (backfills, cutover, import, restore repair) mark
        // server-backed rows pending without outbox rows; record their intent
        // now that admission is complete. Idempotent, consent/owner-gated.
        final coordinator = FixedPlanningCutoverCoordinator(cutover);
        await PendingSyncReconciler(
          db: database,
          ledgerQueue:
              buildLedgerOutboxQueue(database, coordinator: coordinator),
          planningQueue:
              buildPlanningOutboxQueue(database, coordinator: coordinator),
          getOwnerUid: localDataOwnerUid,
          getAuthUserId: currentSupabaseUserId,
          health: SyncHealth.shared,
          mayEgress: () => ConsentAuthority(
            () => DriftUserSettingsRepository(database).getSettings(),
          ).allows(EgressClass.financialSync),
        ).run();
      } catch (_) {
        // Best-effort: the pending marker persists for the next sync cycle.
      }
    });

    if (!_cardBackfillRan) {
      await _step('card_backfill', () async {
        try {
          // Seed the real cards table from existing transactions (auto cards
          // per confident account). Idempotent — skips existing, never touches
          // manual cards. Best-effort; never block startup.
          await DriftCardRepository(
            database,
            outboxQueue: buildPlanningOutboxQueue(database,
                coordinator: FixedPlanningCutoverCoordinator(cutover)),
          ).backfillFromTransactions();
        } catch (_) {
          // Backfill is opportunistic; a failure leaves cards empty, not broken.
        } finally {
          _cardBackfillRan = true;
        }
      });
    }

    if (!_cardIdentityBackfillRan) {
      await _step('card_identity_backfill', () async {
        try {
          // F-032 / OD-02 — attribute historical transactions to a canonical
          // card_id. Runs AFTER card_backfill so auto-discovered cards exist to
          // match against. Unambiguous matches only; anything else stays NULL
          // rather than being guessed.
          await database.backfillCardIdentity();
        } catch (_) {
          // Opportunistic: a failure leaves rows unattributed for the next boot,
          // which is the same truthful state as "not attributable".
        } finally {
          _cardIdentityBackfillRan = true;
        }
      });
    }

    if (SupabaseConfig.isConfigured && !_senderBankSyncStarted) {
      await _step('sender_bank_sync_start', () async {
        if (!_senderShutdown) {
          final client = Supabase.instance.client;
          const boundary = AuthStreamBoundary('senderBankMapping');
          _senderBankAuthSubscription =
              client.auth.onAuthStateChange.listen((state) {
            switch (state.event) {
              case AuthChangeEvent.initialSession:
              case AuthChangeEvent.signedIn:
              case AuthChangeEvent.tokenRefreshed:
              case AuthChangeEvent.userUpdated:
                if (identical(_host?.current?.database, database)) {
                  _receiveSenderBankMapping();
                }
                return;
              case AuthChangeEvent.signedOut:
              case AuthChangeEvent.userDeleted:
              case AuthChangeEvent.passwordRecovery:
              case AuthChangeEvent.mfaChallengeVerified:
                return;
            }
          }, onError: boundary.onError);
          _senderBankSyncStarted = true;
        }
      });
    }

    return AccountScopeInit(
        hasLocalData: localData, planningCutoverState: cutover);
  }

  /// The native capture queue seam (CAP-6a queue v3); tests substitute a fake.
  CaptureQueueBridge captureQueue = NativeCaptureQueue();

  /// Test seam: the platform check of the account scopes' capture registration
  /// service (null in production: `Platform.isIOS`). Lets a host test run the
  /// real iOS capture lanes against a simulated native channel.
  @visibleForTesting
  bool Function()? debugCaptureIsIos;

  /// The ACTIVE account's device-registration service (set by every
  /// `_initializeAccount`); the capture-owner publish hook drives it.
  CaptureDeviceRegistrationService? _captureRegistration;

  /// The service installed above, with the exact database and uid it was built
  /// for (the admission-recovery callback must not act through another's).
  ({
    CaptureDeviceRegistrationService service,
    AppDatabase database,
    String? uid
  })? _captureRegistrationBinding;

  /// WP-3b: account transitions RELEASE the capture owner (never purge waiting
  /// items, §4.2); the queue is purged only by the Remove-data barrier. Also
  /// clears device-wide non-queue residue and the previous account's OS reminders.
  void _registerCaptureOwnerHooks() {
    if (_residueHookRegistered) return;
    _residueHookRegistered = true;
    Future<bool> release({required bool clearHint}) async {
      // P4: an account transition / sign-out advances the epoch first, so every
      // in-flight async mutation of the previous owner is stale from here on.
      CloudEgressGate.instance.advanceEpoch(EpochCause.scopeSwap);
      final cleared =
          await captureQueue.clearCaptureOwner(clearHint: clearHint);
      final filesCleared = await PendingNotificationActions.clear();
      // MALI-019 §10 — clear the previous user's pending OS reminders too.
      await LocalNotificationService.instance.cancelScheduledReminders();
      return cleared && filesCleared;
    }

    AppSession.instance.configureCaptureOwnerClear(
      () => release(clearHint: true),
      atSignOut: () => release(clearHint: false),
    );
    // Immediate deletion never runs the owner clear above (it has no remote
    // unlink either); the deleted owner's OS reminders are cleared locally here.
    AppSession.instance.configureLocalReminderClear(
      LocalNotificationService.instance.clearAllForRemovedOwner,
    );
    // N2: the admission publishes a RESTRICTIVE native owner, locally and
    // awaited: the session needs the verified receipt to fence this lifetime
    // later. There is no backend link here, so nothing leaves the device while
    // Cloud is OFF; widening the mirror stays with the existing link triggers
    // (resume, sync) and the enable phase. No registration service or a receipt
    // that does not verify is null, which the session treats as not published.
    Future<Object?> publishRestrictiveOwner(
        String uid, AdmissionAuthority authority) async {
      // Enqueue only: the receiver drains admissions outside this hook.
      _receiveSenderBankMapping(uid: uid, received: authority);
      final registration = _captureRegistration;
      if (registration == null) return null;
      // ASR §7.5 SE1: only the adoption of an ASR op asks for a successor; the
      // publication is that op's own transition (§11.2).
      final successor = AppSession.instance.asrSuccessorFor(authority);
      return registration.publishRestrictiveOwnerDetailed(
          admissionAuthority: authority,
          plan: AppSession.instance.explicitPublishPlanFor(authority),
          successorOf: successor?.evidenceId == null
              ? null
              : (
                  evidenceId: successor!.evidenceId!,
                  expectedCounter: successor.expectedCounter,
                ),
          successorCauseAuthority: successor?.causeAuthority);
    }

    AppSession.instance.configureCaptureOwnerPublish(publishRestrictiveOwner);
  }

  /// F2 — builds the §4.4 Remove-data flow and the rebootstrap wiring that
  /// reuses it. Needs only the store and the scope host (no capture hooks, no
  /// database), so launch registers it before anything can admit. Idempotent.
  void _registerRemoveData() {
    if (_removeData != null) return;
    _removeData = RemoveDataFlow(
      store: _replicaStore!,
      scope: _host!,
      barrier: CaptureQueueRemoveBarrier(captureQueue),
      clearOwnerMarker: AppSession.instance.clearLocalDataOwnerMarker,
      quiesce: AppSession.instance.drainAdmissions,
      invalidateAdmissionGeneration:
          AppSession.instance.invalidateRemovalGeneration,
    );
    AppSession.instance.configureRemoveData(_removeData);
    // WP-7: the rebootstrap reuses the §4.4 Remove-data flow for epoch_reason
    // purge, and re-admits the account afterwards. The purge is NOT a user
    // removal (it does not revoke the uid), and the rebootstrap holds a
    // maintenance authority that an explicit Remove data revokes for good.
    RebootstrapRuntime.instance
      ..store = _replicaStore
      ..scope = _host
      ..removeData = ((uid) => _removeData!.remove(uid, revokeAdmission: false))
      ..maintenanceAuthority = AppSession.instance.maintenanceAuthority
      ..readmit = (String _, AdmissionAuthority? authority) async {
        final client = _authClient;
        if (client != null) {
          await AppSession.instance.revalidateSupabaseSessionOnResume(
            client,
            authority: authority,
          );
        }
      };
  }

  Future<void> _loadInitialSettingsLanguage() async {
    try {
      await Future.wait([
        LockPromptLanguage.read(),
        ThemeModeController.preload(),
        HomeHeroPeriodController.preload(),
      ]);
    } catch (_) {
      // An optional preference cannot block startup. Keep the last loaded
      // choice, or English if no choice has been loaded in this process.
    }
  }

  AccountScopeHost _buildAccountScopeHost() {
    final store = _replicaStore = ReplicaStore(
      debugAfterAdoptionStep: (step) async =>
          debugStorageEvent?.call("adoption:$step"),
      opener: ({
        location,
        runMigrations = true,
        creation = const CreationPolicy.unrestricted(),
      }) async {
        debugStorageEvent?.call("opener");
        // Process liveness (Contract B) is per database file; the legacy file is
        // only ever read during adoption and takes none.
        if (location != null &&
            location.dbFileName == ReplicaStore.dbFileName) {
          // F2: liveness files are created next to the database; an open that may
          // not create — or whose authority was revoked — must not even make the
          // directory.
          if (!await File(location.dbPath).exists()) {
            creation.requireMayCreate();
          }
          creation.requireCurrent();
          debugStorageEvent?.call("liveness");
          await AppDatabase.initProcessLiveness(location: location);
          creation.requireCurrent();
        }
        creation.requireCurrent();
        debugStorageEvent?.call("native-open");
        return AppDatabase.open(
          location: location,
          runMigrations: runMigrations,
          creation: creation,
          initialLanguage: LockPromptLanguage.initialSettingsLanguage,
        );
      },
    );
    // R8: a host exists only with a proven coordinator; startup already failed
    // closed (C1) before this point when none could be created.
    final coordinator = _coordinator;
    if (coordinator == null) {
      throw const BootstrapCoordinatorUnavailable('coordinator_required');
    }
    return AccountScopeHost(
      store: store,
      initialize: _initializeAccount,
      openSignedOut: () async => AppDatabase.open(
        executor: NativeDatabase.memory(),
        initialLanguage: LockPromptLanguage.initialSettingsLanguage,
      ),
      prepareLocation: (location) =>
          AppDatabase.initProcessLiveness(location: location),
      afterWithdraw:
          debugAfterWithdraw ?? (() => WidgetsBinding.instance.endOfFrame),
      coordinator: coordinator,
      reconcileReusedScope: _reconcileReusedScope,
    );
  }

  /// An admission re-admitted the published same-uid writable scope, which runs
  /// no initialization: when egress is frozen, the registration service bound to
  /// exactly that database and uid reconciles under the admission's authority.
  /// Healthy (unfrozen) reuse does nothing. Never throws.
  Future<void> _reconcileReusedScope(
      AccountScope scope, AdmissionAuthority authority) async {
    if (!ConsentAuthority.egressFrozen) return;
    final bound = _captureRegistrationBinding;
    if (bound == null ||
        scope.isLocalRead ||
        bound.uid != scope.uid ||
        !identical(bound.database, scope.database)) {
      return;
    }
    try {
      await bound.service.reconcileAfterAdmission(
          authority: authority,
          isCurrentScope: () => identical(_host?.current, scope));
    } catch (_) {
      // Recovery is best-effort; the freeze stays.
    }
  }

  /// B2-C — deferred, non-critical startup housekeeping that must NOT gate the
  /// first financial frame. Owner-independent (temp files only, so no admission
  /// guard is needed), idempotent, and best-effort: a failure here can never
  /// turn a usable local DB into a fatal startup error. Runs outside the 30s
  /// bootstrap timeout.
  Future<void> _runDeferredStartupWork() async {
    // MALI-065n: on a fresh process no export share can be in flight, so any
    // file left in the managed export dir is a crash orphan — reclaim them all.
    try {
      await ManagedExportStore().sweep();
    } catch (_) {
      // Housekeeping only; never surface as a startup failure.
    }
  }

  void _observeBootstrapWork(Future<void> Function() start) {
    final terminal = Completer<void>();
    _pendingBootstrapWork.add(terminal.future);
    void settled() {
      _pendingBootstrapWork.remove(terminal.future);
      terminal.complete();
    }

    try {
      final actual = start();
      unawaited(actual.then<void>((_) => settled(),
          onError: (Object error, StackTrace stack) {
        _unexpectedBootstrapWork.add((error, stack));
        settled();
      }));
    } catch (_) {
      settled();
      rethrow;
    }
  }

  /// Observes already-started bootstrap work after its external producers stop.
  /// This neither shuts down producers nor starts replacement work.
  Future<void> waitPendingBootstrapWork() async {
    while (_pendingBootstrapWork.isNotEmpty) {
      await Future.wait(_pendingBootstrapWork.toList());
    }
    if (_unexpectedBootstrapWork.isNotEmpty) {
      Error.throwWithStackTrace(
          _unexpectedBootstrapWork.first.$1, _unexpectedBootstrapWork.first.$2);
    }
  }

  void _installSenderObservers() {
    if (_senderShutdown ||
        _senderObserversInstalled ||
        !SupabaseConfig.isConfigured) {
      return;
    }
    _senderObserversInstalled = true;
    _host!.addListener(_senderHostChanged);
    AppSession.instance.addListener(_senderSessionChanged);
  }

  void _senderHostChanged() => _receiveSenderBankMapping();
  void _senderSessionChanged() {
    final session = AppSession.instance;
    final scope = _host?.current;
    final ordinary = session.captureLocalWorkAuthority();
    if (session.status != SessionStatus.authenticated ||
        scope == null ||
        ordinary == null ||
        !ordinary.isCurrent ||
        ordinary.uid != scope.uid) {
      _senderSessionReadyKey = null;
      return;
    }
    final key =
        (scope, ordinary.uid, ordinary.epoch, CloudEgressGate.instance.epoch);
    if (_senderSessionReadyKey == key) {
      return;
    }
    _senderSessionReadyKey = key;
    _receiveSenderBankMapping(received: ordinary);
  }

  void _receiveSenderBankMapping({String? uid, AdmissionAuthority? received}) {
    if (_senderShutdown ||
        !SupabaseConfig.isConfigured ||
        AppSession.instance.localReadEgressDenied) {
      return;
    }
    final host = _host;
    final scope = host?.current;
    if (host == null ||
        scope == null ||
        scope.uid == null ||
        !identical(
            AppSession.instance.accountFenceHostForDatabase(scope.database),
            host)) {
      return;
    }
    final original =
        received ?? AppSession.instance.captureLocalWorkAuthority();
    if (original == null ||
        original.uid != scope.uid ||
        (uid != null && uid != scope.uid) ||
        !original.isCurrent) {
      return;
    }
    final egressEpoch = CloudEgressGate.instance.epoch;
    final key = (scope, original.uid, original.epoch, egressEpoch);
    if (!_senderReceiving.add(key)) return;
    final completion = Completer<void>();
    _senderJobs.add(completion.future); // Reserve before invoking any work.
    bool receivingCurrent() =>
        !_senderShutdown &&
        !AppSession.instance.localReadEgressDenied &&
        identical(host.current, scope) &&
        host.generation == scope.generation &&
        original.isCurrent &&
        CloudEgressGate.instance.epoch == egressEpoch;
    unawaited(Future<void>.microtask(() async {
      try {
        if (!receivingCurrent()) return;
        await AppSession.instance.drainAdmissions();
        // Exactly one bounded continuation after the tracked work settles.
        // Ordinary capture remains mandatory, never inferred from this yield.
        await Future<void>.value();
        if (!receivingCurrent()) return;
        final ordinary = AppSession.instance.captureLocalWorkAuthority();
        if (ordinary == null ||
            !ordinary.isCurrent ||
            ordinary.uid != original.uid ||
            ordinary.epoch != original.epoch) {
          return;
        }
        final client = Supabase.instance.client;
        if (client.auth.currentUser?.id != original.uid) return;
        if (!receivingCurrent()) return;
        _senderSessionReadyKey = key;
        // A successor epoch can legitimately keep the same DB. It owns a fresh
        // service instance, rather than being dropped by an old busy instance.
        final service = SenderBankMappingSyncService(
            db: scope.database,
            remoteStore: SupabaseSenderBankMappingRemoteStore(client),
            currentUserId: () => client.auth.currentUser?.id,
            mayEgress: () => ConsentAuthority(() =>
                    DriftUserSettingsRepository(scope.database).getSettings())
                .allows(EgressClass.senderBankMappings),
            health: SyncHealth.shared,
            seqGate: SeqPullGate(
                db: scope.database,
                capability: ServerCapabilitiesService(
                        getAuthUserId: () async => client.auth.currentUser?.id,
                        getClient: () => client,
                        mayEgress: () => ConsentAuthority(() =>
                                DriftUserSettingsRepository(scope.database)
                                    .getSettings())
                            .allows(EgressClass.financialSync),
                        health: SyncHealth.shared)
                    .syncSeq));
        await service.syncWithPhase(SyncPhaseBinding(),
            originalAuthority: original);
      } on AccountFenceDeliveryCancellation {
        // Expected old-lifetime refusal, not an ordinary sync failure.
      } on StaleAdmissionException {
        // The genuine receiving admission was superseded before dispatch.
      } catch (error, stack) {
        _senderUnexpected.add((error, stack));
        const AuthStreamBoundary('senderBankMapping').onError(error, stack);
      } finally {
        _senderReceiving.remove(key);
        _senderJobs.remove(completion.future);
        completion.complete();
      }
    }));
  }

  /// Observes current and retired sender jobs without changing scheduling.
  Future<void> waitPendingSenderBankMappingSync() async {
    while (_senderJobs.isNotEmpty) {
      await Future.wait(_senderJobs.toList());
    }
    if (_senderUnexpected.isNotEmpty) {
      Error.throwWithStackTrace(
          _senderUnexpected.first.$1, _senderUnexpected.first.$2);
    }
  }

  /// Stops only sender scheduling; it neither signs out nor closes the host/SDK.
  /// Started jobs (including retired scopes) remain owned until they settle.
  Future<void> shutdownSenderBankMappingSync() {
    final existing = _senderShutdownCompletion;
    if (existing != null) return existing;
    _senderShutdown = true; // No reinstallation/registration after this point.
    if (_senderObserversInstalled) {
      _host?.removeListener(_senderHostChanged);
      AppSession.instance.removeListener(_senderSessionChanged);
      _senderObserversInstalled = false;
    }
    final subscription = _senderBankAuthSubscription;
    _senderBankAuthSubscription = null;
    final done = Completer<void>();
    _senderShutdownCompletion = done.future;
    unawaited(() async {
      Object? cancellationError;
      StackTrace? cancellationStack;
      try {
        await subscription?.cancel();
      } catch (error, stack) {
        cancellationError = error;
        cancellationStack = stack;
      }
      while (_senderJobs.isNotEmpty) {
        await Future.wait(_senderJobs.toList());
      }
      if (cancellationError != null) {
        done.completeError(cancellationError, cancellationStack);
      } else if (_senderUnexpected.isNotEmpty) {
        done.completeError(
            _senderUnexpected.first.$1, _senderUnexpected.first.$2);
      } else {
        done.complete();
      }
    }());
    return done.future;
  }

  void _assertRuntimeConfig() {
    if (kDebugMode) {
      debugPrint(
        '[SupabaseConfig] env=${SupabaseConfig.environment.name}'
        ' configured=${SupabaseConfig.isConfigured}',
      );
    }
    if (!kReleaseMode) return;
    // Release builds fail closed: a production binary must never run with
    // fake/local auth or a non-production backend.
    if (!SupabaseConfig.isConfigured) {
      throw StateError(
        'Release build launched without SUPABASE_URL/SUPABASE_ANON_KEY — '
        'refusing to start with stub auth.',
      );
    }
    if (SupabaseConfig.environment != SupabaseEnvironment.production) {
      throw StateError(
        'Non-production SUPABASE_ENV '
        '"${SupabaseConfig.environment.name}" in release build.',
      );
    }
  }

  AuthCoordinator? _authCoordinator;

  /// ASR §6.7: protected-data availability events, once a coordinator exists.
  Stream<void>? get protectedDataAvailableEvents =>
      _authCoordinator?.store.keychain.protectedDataBecameAvailable;

  /// ASR: creates (once) and loads the AuthCoordinator. Null when no backend is
  /// configured or a test runs the legacy SDK storage path.
  Future<AuthCoordinator?> _prepareAuthCoordinator() async {
    final debug = debugSdk;
    final create = debug != null
        ? debug.authCoordinator
        : (SupabaseConfig.isConfigured ? _productionAuthCoordinator : null);
    if (create == null) return null;
    final coord = _authCoordinator ??= await create();
    final loaded = coord.loadResult;
    if (loaded == null || loaded.loadClass == LoadClass.deferred) {
      final r = await coord.load();
      if (r.loadClass == LoadClass.deferred) {
        throw BootstrapAuthDeferred(r.reason ?? 'deferred');
      }
    }
    return coord;
  }

  static Future<AuthCoordinator> _productionAuthCoordinator() async {
    final support = await getApplicationSupportDirectory();
    // Beta 1 diagnostic trail of refresh attempts (constants only, local).
    await AuthDiagnostics.attach(support);
    final gate = CloudEgressGate.instance;
    return AuthCoordinator(
      store: SessionStore(
        keychain: MethodChannelSessionKeychain(),
        files: SessionFiles(support),
        origin: Uri.parse(SupabaseConfig.url),
        legacy: SharedPrefsLegacySessionSource(
            ObservingAuthLocalStorage.sdkStorageKey(SupabaseConfig.url)),
        localInstallDataPresent: () => localInstallDataPresent(support.path),
      ),
      gate: gate,
      channelFactory: () => RefreshExchange(
          tokenUri: gate.refreshTokenUri()!, apiKey: SupabaseConfig.anonKey),
    );
  }

  /// §6.5: whether this install already holds local app data (a replica or
  /// the pre-WP-3a database). Null when it cannot be told (→ deferred).
  static Future<bool?> localInstallDataPresent(String support) async {
    try {
      if (await File(p.join(support, ReplicaLocation.legacyDbFileName))
          .exists()) {
        return true;
      }
      final replicas = Directory(p.join(support, 'replicas'));
      if (!await replicas.exists()) return false;
      return await replicas
          .list()
          .any((e) => e is Directory && !p.basename(e.path).startsWith('_'));
    } catch (_) {
      return null;
    }
  }

  Future<T> _step<T>(String name, Future<T> Function() run) async {
    _lastStep = name;
    final start = DateTime.now();
    if (kDebugMode) debugPrint('[Bootstrap] $name start');
    try {
      final result = await run();
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Bootstrap] $name ok (${ms}ms)');
      }
      return result;
    } catch (error) {
      if (kDebugMode) {
        final ms = DateTime.now().difference(start).inMilliseconds;
        debugPrint('[Bootstrap] $name failed after ${ms}ms: '
            '${error.runtimeType}');
      }
      rethrow;
    }
  }
}

/// Loads every bundled `assets/brands/*.svg` slug once so [BrandMark] can show
/// any of them automatically (drop a new SVG in the folder → it just works).
Future<void> _registerBrandLogos() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final slugs = manifest
        .listAssets()
        .where((a) => a.startsWith('assets/brands/') && a.endsWith('.svg'))
        .map((a) => a.split('/').last.replaceAll('.svg', ''))
        .toList();
    BrandMark.registerAssetSlugs(slugs);
  } catch (_) {
    // Logos are optional; ignore manifest read failures.
  }
}

/// Test seam for the D6 guard of [_startSenderBankMappingSync].
@visibleForTesting
StreamSubscription<AuthState> debugStartSenderBankMappingSync(
  AppDatabase database,
  SupabaseClient client, {
  required bool Function() egressDenied,
}) =>
    _startSenderBankMappingSync(database, client, egressDenied: egressDenied);

/// This listener lives as long as the process: it is NOT released when an
/// in-process expiry swaps the writable scope for the read-only one. D6: while
/// the session says local-read egress is denied it syncs nothing (it would reach
/// a closed writable database and the network); the transport gate refuses it
/// regardless.
StreamSubscription<AuthState> _startSenderBankMappingSync(
  AppDatabase database,
  SupabaseClient client, {
  bool Function()? egressDenied,
}) {
  final denied =
      egressDenied ?? () => AppSession.instance.localReadEgressDenied;
  unawaited(SyncHealth.shared.attach(database));
  final service = SenderBankMappingSyncService(
    db: database,
    remoteStore: SupabaseSenderBankMappingRemoteStore(client),
    currentUserId: () => client.auth.currentUser?.id,
    // C-3 — same gate as the provider construction site. Startup is exactly
    // where an ungated sync would run before any UI could reflect consent.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(database).getSettings(),
    ).allows(EgressClass.senderBankMappings),
    health: SyncHealth.shared,
    // WP-4: the same sync_seq gate as the provider construction site, so this
    // startup instance does not stay on the timestamp pull (B6).
    seqGate: SeqPullGate(
      db: database,
      capability: ServerCapabilitiesService(
        getAuthUserId: () async => client.auth.currentUser?.id,
        getClient: () => client,
        mayEgress: () => ConsentAuthority(
          () => DriftUserSettingsRepository(database).getSettings(),
        ).allows(EgressClass.financialSync),
        health: SyncHealth.shared,
      ).syncSeq,
    ),
  );
  const boundary = AuthStreamBoundary('senderBankMapping');
  if (!denied()) unawaited(boundary.run(service.sync));
  return client.auth.onAuthStateChange.listen((state) {
    switch (state.event) {
      case AuthChangeEvent.initialSession:
      case AuthChangeEvent.signedIn:
      case AuthChangeEvent.tokenRefreshed:
      case AuthChangeEvent.userUpdated:
        if (denied()) return;
        unawaited(boundary.run(service.sync));
        return;
      case AuthChangeEvent.signedOut:
      case AuthChangeEvent.userDeleted:
      case AuthChangeEvent.passwordRecovery:
      case AuthChangeEvent.mfaChallengeVerified:
        return;
    }
  }, onError: boundary.onError);
}

/// Test configuration for [BootstrapRunner.debugSdk].
@visibleForTesting
class BootstrapSdkTestConfig {
  const BootstrapSdkTestConfig({
    required this.url,
    this.innerStorage,
    this.innerHttp,
    this.beforeInitialize,
    this.authCoordinator,
  });
  final String url;
  final LocalStorage? innerStorage;
  final http.Client? innerHttp;
  final Future<void> Function()? beforeInitialize;

  /// Runs the coordinated (ASR) storage path with this coordinator.
  final Future<AuthCoordinator> Function()? authCoordinator;
}

/// Astra D2 / R12: the provenance of the SDK's initial session.
///
/// A final null/expired session cannot say whether initialization began with plain
/// absence, ordinary expiry, or the loss of a session. Two sources are observed
/// from the moment the SDK client exists (during `Supabase.initialize`, i.e.
/// BEFORE ordinary binding) until [AppSession] has taken over the stream:
///
///  * attributable auth events: any `signedOut`/`userDeleted` is a restrictive
///    loss of unknown cause. Stream ERRORS are deliberately not classified here
///    (the established `AuthStreamBoundary` treats an identityless error as
///    telemetry, not account authority; a retryable refresh failure of a valid
///    expired session is ordinary), and nothing is decided by exception name;
///  * the persisted state itself ([ObservingAuthLocalStorage]): verified empty
///    storage and a valid (possibly expired) session are benign; unreadable,
///    malformed, wrongly shaped or inconsistently loaded state is UNKNOWN
///    provenance, because the SDK turns such a failure into a plain null initial
///    session that no event distinguishes from absence.
///
/// Restoration of local read requires [provenanceIntact]: unknown provenance
/// denies, exactly like an observed loss.
@visibleForTesting
class AuthInitEventBuffer {
  StreamSubscription<AuthState>? _subscription;
  SupabaseClient? _client;
  bool _sawRestrictive = false;
  String? _unknownReason;

  /// True once a `signedOut`/`userDeleted` was seen. Sticky for this runner.
  bool get sawRestrictiveLoss => _sawRestrictive;

  /// True once the persisted state could not be verified as empty or as a valid
  /// session. Sticky for this runner.
  bool get unknownProvenance => _unknownReason != null;

  /// Why the provenance is unknown (a stable code), else null.
  String? get unknownProvenanceReason => _unknownReason;

  /// Whether the initialization provenance is known benign.
  bool get provenanceIntact => !_sawRestrictive && _unknownReason == null;

  /// O-LC-1: notified synchronously, once, when the provenance first becomes
  /// unknown: during initialization (the runner then holds the startup failure
  /// until the denial settled) or LATER, from the SDK's unawaited recovery read.
  /// This is the handoff of every storage classification to the session's
  /// denial; nothing waits on a timer.
  void Function(String reason)? onUnknownProvenance;

  void markUnknownProvenance(String reason) {
    final first = _unknownReason == null;
    _unknownReason ??= reason;
    if (!first) return;
    try {
      onUnknownProvenance?.call(reason);
    } catch (_) {
      // The denial is best effort here; the decision points deny again.
    }
  }

  /// Idempotent per client.
  void attach(SupabaseClient client) {
    if (identical(_client, client) && _subscription != null) return;
    _subscription?.cancel();
    _client = client;
    _subscription = client.auth.onAuthStateChange.listen((state) {
      switch (state.event) {
        case AuthChangeEvent.signedOut:
        case AuthChangeEvent.userDeleted:
          _sawRestrictive = true;
        case AuthChangeEvent.initialSession:
        case AuthChangeEvent.signedIn:
        case AuthChangeEvent.tokenRefreshed:
        case AuthChangeEvent.userUpdated:
        case AuthChangeEvent.passwordRecovery:
        case AuthChangeEvent.mfaChallengeVerified:
          break;
      }
    }, onError: (Object _) {
      // Neutral: a stream error carries no identity and no account authority.
    });
  }

  /// Stops observing once the ordinary binding listens to the same client.
  Future<void> release() async {
    final sub = _subscription;
    _subscription = null;
    _client = null;
    await sub?.cancel();
  }
}

/// A session store handed to `Supabase.initialize` that behaves exactly like the
/// SDK's default (shared preferences, same key) and, in [initialize] (which the
/// SDK calls after its client exists and BEFORE it emits the initial session or
/// recovers a persisted one), installs the [AuthInitEventBuffer]. It also
/// classifies what the SDK reads from storage (R12): verified empty and valid
/// states stay benign, everything else marks the buffer's provenance unknown.
///
/// R11: the storage key is the SDK default (`Supabase.initialize` derives
/// `sb-<first host label>-auth-token` when no store is given). It is duplicated
/// here only so existing persisted sessions are found; the dependency-contract
/// guard (`auth_init_sdk_contract_test.dart`) fails when the locked SDK versions
/// or that derivation change, until the contract is re-reviewed.
@visibleForTesting
class ObservingAuthLocalStorage extends LocalStorage {
  ObservingAuthLocalStorage(this._buffer, String url,
      {LocalStorage? inner, this.coordinated})
      : _inner = inner ??
            SharedPreferencesLocalStorage(
                persistSessionKey: sdkStorageKey(url));

  /// ASR §3.2 / I4: with an AuthCoordinator the SDK never reads or writes
  /// persisted state itself. The store answers exactly the first
  /// `hasAccessToken`/`accessToken` pair (the `initialize` pair) from the
  /// coordinator's loaded record and every later call with nothing, so the
  /// unawaited lazy `recoverSession()` finds no session; persistence callbacks
  /// are no-ops.
  final CoordinatedSessionServe? coordinated;
  bool _servedOnce = false;

  /// The SDK's own default key derivation (supabase_flutter `Supabase.initialize`).
  static String sdkStorageKey(String url) =>
      'sb-${Uri.parse(url).host.split('.').first}-auth-token';

  final AuthInitEventBuffer _buffer;
  final LocalStorage _inner;

  // Loads happen twice during startup (`initialize` then the unawaited
  // `recoverSession`). Every load must show a state this store is KNOWN to hold:
  // what the first load saw, or what the SDK itself wrote or removed since.
  // Anything else (the store changed under the SDK, or answered inconsistently)
  // is unknown provenance.
  bool? _lastHas;
  final Set<String> _expected = {};
  bool _firstLoadSeen = false;

  void _observeLoad(String load) {
    if (!_firstLoadSeen) {
      _firstLoadSeen = true;
      _expected.add(load);
    } else if (!_expected.contains(load)) {
      _buffer.markUnknownProvenance('inconsistent_storage');
    }
  }

  /// The SDK accepts a stored session only when it parses to a [Session] with
  /// its required fields; anything else becomes a plain null initial session.
  bool _isValidSession(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return false;
      return Session.fromJson(decoded) != null;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> initialize() async {
    _buffer.attach(Supabase.instance.client);
    final c = coordinated;
    if (c != null) {
      c.onInitialize();
      return;
    }
    try {
      await _inner.initialize();
    } catch (_) {
      // The store itself could not start: the SDK cannot say what was persisted.
      _buffer.markUnknownProvenance('storage_init_failed');
      rethrow;
    }
  }

  @override
  Future<bool> hasAccessToken() async {
    final c = coordinated;
    if (c != null) {
      if (_servedOnce) return false;
      final has = c.served != null;
      if (!has) _servedOnce = true;
      return has;
    }
    final bool has;
    try {
      has = await _inner.hasAccessToken();
    } catch (_) {
      _buffer.markUnknownProvenance('storage_unreadable');
      rethrow;
    }
    _lastHas = has;
    if (!has) _observeLoad('empty');
    return has;
  }

  @override
  Future<String?> accessToken() async {
    final c = coordinated;
    if (c != null) {
      if (_servedOnce) return null;
      _servedOnce = true;
      return c.served;
    }
    final String? raw;
    try {
      raw = await _inner.accessToken();
    } catch (_) {
      _buffer.markUnknownProvenance('storage_unreadable');
      rethrow;
    }
    if (raw == null || raw.isEmpty) {
      // `hasAccessToken` said there is one, but nothing could be loaded.
      if (_lastHas != false) {
        _buffer.markUnknownProvenance('inconsistent_storage');
      }
      return raw;
    }
    if (_lastHas == false) {
      _buffer.markUnknownProvenance('inconsistent_storage');
    }
    if (!_isValidSession(raw)) {
      _buffer.markUnknownProvenance('malformed_session');
    }
    _observeLoad(raw);
    return raw;
  }

  @override
  Future<void> removePersistedSession() {
    if (coordinated != null) return Future.value();
    _expected.add('empty');
    return _inner.removePersistedSession();
  }

  @override
  Future<void> persistSession(String persistSessionString) {
    if (coordinated != null) return Future.value();
    _expected.add(persistSessionString);
    return _inner.persistSession(persistSessionString);
  }
}

/// What the coordinated one-shot store serves (ASR §3.2).
class CoordinatedSessionServe {
  const CoordinatedSessionServe(
      {required this.served, required this.onInitialize});

  /// The canonical session of a valid ordinary record, or null (§6.8).
  final String? served;

  /// Runs when the SDK initializes the store: the client exists and has not
  /// emitted yet, so the coordinator attaches here (§4.5).
  final void Function() onInitialize;
}

/// Astra H2.3: `supabase_flutter` calls `startAutoRefresh()` on EVERY app resume
/// (supabase_auth.dart `didChangeAppLifecycleState`), whatever Cloud says. Right
/// after that observer ran, this one stops the ticker again unless the gate
/// permits, so a resume while OFF / unresolved / DISABLING schedules no refresh.
/// (The transport would deny the refresh anyway; this keeps the timer from
/// existing.)
@visibleForTesting
class AutoRefreshResumeGuard with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  /// Test seam: removes the observer (a real app keeps it for its lifetime).
  @visibleForTesting
  void detach() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    unawaited(() async {
      try {
        // ASR §3.3: with the coordinator the SDK ticker is stopped
        // unconditionally; the coordinator scheduler is the only refresher.
        if (AuthCoordinator.active == null &&
            await CloudEgressGate.instance.permits()) {
          return;
        }
        Supabase.instance.client.auth.stopAutoRefresh();
      } catch (_) {}
    }());
  }
}

/// ASR §8: a resume triggers recovery; backgrounding cancels an op before
/// acceptance (decision (a)) and any pending retry.
class _AsrLifecycleObserver with WidgetsBindingObserver {
  void attach() => WidgetsBinding.instance.addObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final asr = AutomaticSessionRecovery.active;
    if (asr == null) return;
    switch (state) {
      case AppLifecycleState.resumed:
        asr.trigger();
      case AppLifecycleState.inactive:
        // Still visible on iOS (Face ID / native view transitions). The ASR
        // host refuses new exchanges here but can finish an accepted adoption.
        break;
      // Actual backgrounding always cancels continuation.
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        asr.onBackground();
    }
  }
}
