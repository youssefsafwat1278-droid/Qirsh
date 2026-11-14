import '../startup/install_presentation_store.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart' show DatabaseLifecycleState;
import '../../data/db/database_key_store.dart';
import '../../data/db/app_database.dart';
import '../../data/db/database_access_broker.dart';
import '../../data/db/ownership_guard.dart' show StaleOwnershipException;
import '../../features/capture/services/native_capture_bridge.dart';
import '../backend/supabase_config.dart';
import '../privacy/cloud_egress_gate.dart';
import '../auth/auth_coordinator.dart';
import '../auth/auth_diagnostics.dart';
import '../auth/email_sign_in_status.dart' show emailSignInReceiptStorageKey;
import '../auth/immediate_deletion_receipt_store.dart';
import '../auth/session_record.dart' show AdmissionDisposition;
import '../privacy/consent_authority.dart';
import '../startup/asr_storage_reads.dart';
import '../startup/automatic_session_recovery.dart';
import '../tracking/user_activity_service.dart';
import '../security/secure_storage_options.dart';
import '../sync/sync_wakeup.dart' show AuthSessionValid;
import 'account_scope.dart';
import 'auth_stream_boundary.dart';
import 'local_read_authority.dart';
import 'admission_authority.dart';
import 'consent_capability.dart';
import 'account_fence_authority.dart';
import 'remove_data_flow.dart';

/// [sessionExpired] is distinct from [needsOnboarding]: onboarding metadata
/// (auth method, completed-account keys) stays intact — only the *live*
/// Supabase session was found invalid. A router redirect to auth must never
/// clear onboarding completion for this case (see `AppSession.signOut` for
/// the separate, intentional full-reset path).
enum SessionStatus { unknown, needsOnboarding, authenticated, sessionExpired }

/// Why a session judgment was lost (ASR §7.3/§7.7). Only a plain expiry keeps
/// the native expiry evidence; [awaitingAdoption] is ASR's own wait for a
/// committed `requiresAdoption` record (not a loss); everything else is
/// [other] and durably bars automatic recovery of the lifecycle.
enum SessionLossCause { sessionExpiry, awaitingAdoption, other }

/// Only the original local operation; never an account-deletion certificate.
enum PreparedOriginalLocalRemovalOutcome {
  staleBeforeAcceptance,
  operationUnavailable,
  localRemovalIncomplete,
  originalLocalRemovalConfirmed,
}

/// O: opaque host-issued writable admission. Metadata cannot construct one.
/// This deliberately grants no local-read admission: that scope is not wired.
class DatabaseHostAdmission {
  DatabaseHostAdmission._(this._owner, this._scope, this._client, this._epoch,
      this._loss, this._sdkSession);
  final AppSession _owner;
  final AccountScope _scope;
  final supabase.SupabaseClient _client;
  final int _epoch;
  final int _loss;
  final supabase.Session _sdkSession;
  bool _revoked = false;

  String get uid => _scope.uid!;
  int get scopeGeneration => _scope.generation;
  AppDatabase get database => _scope.database;
  bool get isCurrent => _owner._databaseAdmissionCurrent(this);
}

/// The account's setup state could not be verified and can be retried.
class OnboardingStatusUnavailable implements Exception {
  const OnboardingStatusUnavailable([this.cause]);

  /// The lookup's own failure, for a non-sensitive reason code only.
  final Object? cause;
}

/// MALI-054n: thrown when a new identity cannot be admitted because the previous
/// owner's local data / native capture residue could not be fully cleared. The
/// admission path fails closed rather than exposing one user's data to another.
class LocalDataOwnershipException implements Exception {
  const LocalDataOwnershipException();

  @override
  String toString() =>
      'LocalDataOwnershipException: refused to admit a new identity onto '
      'un-purged data/residue from a previous account.';
}

/// Outcome of reconciling the local-data owner marker with an identity.
enum LocalDataOwnership {
  /// The marker was READ BACK equal to the identity. Safe to admit.
  owned,

  /// The wipe hook is not registered yet (the first reconcile runs before
  /// `database_open`). Nothing was attempted; bootstrap resolves it through
  /// [AppSession.resolvePendingLocalDataOwnerConflict].
  deferred,

  /// Ownership could not be conclusively established. Local data is
  /// PRESERVED and the identity must not be admitted.
  unresolved,

  /// F2: admission was refused BEFORE any side effect because it is revoked: a
  /// Remove data was accepted (or is running), the caller's authority/attempt
  /// predates it, or the uid completed a removal and has not authenticated
  /// explicitly since. Nothing was written, opened or created.
  revoked,
}

/// One admission: the uid, its authority, and whether it is an EXPLICIT
/// authentication attempt (the only kind that may lift a removal revocation).
class _Admission {
  _Admission(this.uid, this.authority,
      {this.explicit = false, this.sessionCurrent, this.asrCause});
  final bool Function()? sessionCurrent;

  /// ASR §9.7 adoption of the same owner: its expiry fence retired the native
  /// lifetime, so the reconcile must publish SE1 (`successorOf`) again. The
  /// op's authority: the scope initialization this admission opens is its own
  /// transition (§11.2).
  final Object? asrCause;
  bool get asrSuccessor => asrCause != null;
  final String uid;

  /// Replaced (never mutated) when an automatic admission switches the device to
  /// another account: the switch invalidates every authority captured before it.
  AdmissionAuthority authority;
  final bool explicit;

  /// This explicit admission re-admits a uid whose Remove data completed. Its
  /// failure at any stage rolls the partial admission back, and only its full
  /// commit lifts the revocation.
  bool wasRevoked = false;
  bool get current => authority.isCurrent;
}

/// N2: how a native lifecycle step settled. Only [confirmed] is a verified native
/// receipt. [incomplete] keeps Dart denied and further publication closed.
/// [unknown] means there was no verified native proof to act on: it is never
/// success.
enum NativeLifecycleOutcome { confirmed, incomplete, unknown }

/// The verified owner proof behind a consent capability, or why there is none:
/// [reason] is `owner_publication/<proof>[/<detail>]` built only from allowlisted
/// constants. Diagnostic text; it grants nothing.
class OwnerLifetimeProof {
  const OwnerLifetimeProof(this.binding, this.reason);
  final CloudEgressEnableBinding? binding;
  final String reason;
}

/// One native authorization lifetime this process is publishing or holds, bound
/// to the exact admission (uid, epoch, database) it belongs to. [binding] stays
/// null until a verified restrictive receipt or exact pending-resume proof is
/// accepted; the revocation request identity is allocated once, so every retry
/// of its fence is the same request.
class _NativeLifetime {
  _NativeLifetime(this.uid, this.epoch, this.database);
  final String uid;
  final int epoch;
  final Object database;
  CloudEgressEnableBinding? binding;

  /// Set synchronously by the loss that retired this lifetime.
  bool lost = false;

  /// ASR §7.2: the session lifecycle when that loss was a plain expiry (the
  /// fence may then mint expiry evidence); null for every other loss.
  int? expiryLifecycle;

  /// Allowlisted constant naming why its publication did not confirm (never an
  /// identifier, message or number). Diagnostic only.
  String? reason;

  /// Completes, never with an error, when its publication has settled.
  final Completer<NativeLifecycleOutcome> published =
      Completer<NativeLifecycleOutcome>();
}

/// Private evidence of a successful exact identity publication. Never callable
/// or constructible outside this session library; not a status-derived grant.
class _DatabaseIdentityPublication {
  const _DatabaseIdentityPublication(
      this.scope, this.client, this.sdk, this.epoch, this.loss);
  final AccountScope scope;
  final supabase.SupabaseClient client;
  final supabase.Session sdk;
  final int epoch;
  final int loss;
}

/// Private evidence that a fresh explicit admission was published (never a
/// caller boolean or a number): the exact scope, issuer client and generations.
class _GrantProof {
  _GrantProof(this.uid, this.scope, this.client, this.epoch, this.loss);
  final String uid;
  final AccountScope scope;
  final supabase.SupabaseClient client;
  final int epoch;
  final int loss;
}

/// The host-side proof that the published scope is the verified local-read one.
/// What [AppSession.signOut] achieved. Signing out always locks the process;
/// [durableDenyIncomplete] says the on-disk deny could not be established, so a
/// restart is NOT guaranteed to stay locked.
enum SignOutOutcome { complete, durableDenyIncomplete }

/// What the DURABLE OFFLINE-ACCESS DENIAL of [AppSession.removeDataFromDevice]
/// achieved. It says nothing else: it is NOT a statement that data was removed.
/// Removal is reported separately and only when confirmed: a removal that cannot
/// be confirmed throws [RemoveDataIncompleteException]; a request with no target
/// (no admitted or published uid) removes nothing, raises no data-removed notice
/// and still returns [complete] when its denial step needed nothing.
/// [durableDenyIncomplete] says the denial could not be established, so a restart
/// is NOT guaranteed to stay locked and may restore offline access; Retry only
/// repeats that denial, never the removal.
enum RemoveDataOutcome { complete, durableDenyIncomplete }

/// Set by `setIdentity` once it has retired a local-read proof, so the wrapper
/// knows a failure happened after a mode transition began.
/// D3: what a failed reconnect attempt left behind — the admission epoch and the
/// scope that was published when it failed. A queued failure recovery holds only
/// while both are unchanged; a newer admission changes at least the epoch.
class _FailedAttemptBinding {
  _FailedAttemptBinding(this.epoch, this.scope);
  final int epoch;
  final AccountScope? scope;

  bool holds(int currentEpoch, AccountScope? currentScope) =>
      currentEpoch == epoch && identical(currentScope, scope);
}

class _ReconnectProbe {
  bool began = false;

  /// R10.2: the admission epoch this attempt itself took (`++_admissionEpoch`),
  /// i.e. the identity of the initiating attempt. Null until the attempt began.
  int? epoch;
}

/// O-LC-1a: the identity of ONE startup as far as local-read denial is
/// concerned. Captured by the runner at the start of its startup
/// ([AppSession.beginLocalReadStartupBinding]) and handed back with every late
/// storage classification, so the denial reaches exactly what that startup
/// derived: the grant it found (by operation id) and the local-read scope it
/// published (by identity), and never an independently admitted successor.
class LocalReadStartupBinding {
  LocalReadStartupBinding._(this._lifecycle, this.operationId, this.uid);
  final int _lifecycle;

  /// The stored grant operation found at startup (null: none readable).
  final String? operationId;
  final String? uid;
  _LocalReadHostProof? _proof;
}

class _LocalReadHostProof {
  _LocalReadHostProof(this.capability, this.scope, this.host);
  final LocalReadCapability capability;
  final AccountScope scope;
  final AccountScopeHost host;
}

/// What launch found out about removal state, BEFORE anything can be admitted.
///
/// [blocked] is not "signed out": it means the durable removal state could not be
/// resolved (an unfinishable or unreadable removal, a native barrier of unknown
/// uid or unreadable answer, an unreadable owner marker or revocation list), so
/// the launch must adopt nothing, bind no auth, open no replica and route
/// nowhere authenticated. Otherwise [uid] is the owner whose EXISTING replica may
/// be opened, or null for the signed-out scope.
class LaunchAdmission {
  const LaunchAdmission.blocked()
      : blocked = true,
        uid = null;
  // Not const: the identity of the admission chosen at launch is meaningful.
  LaunchAdmission.open(this.uid) : blocked = false;
  final bool blocked;
  final String? uid;
}

/// حالة الجلسة (للتحكّم في عرض الـ Onboarding مقابل التطبيق).
///
/// ValueNotifier حتى يُستخدم كـ refreshListenable في go_router دون Riverpod.
/// تُخزَّن الأعلام في flutter_secure_storage (لا بيانات مالية هنا).
class AppSession extends ValueNotifier<SessionStatus> {
  AppSession._() : super(SessionStatus.unknown);

  static final AppSession instance = AppSession._();

  supabase.SupabaseClient? _databaseIssuerClient;
  DatabaseHostAdmission? _databaseHostAdmission;

  /// O: the inert coordinator, owned by the bootstrap host. Production startup
  /// fails closed when it cannot be created or proven (C1), so a null here only
  /// exists in tests / headless processes; with none there is NO local read.
  DatabaseAccessBroker? _databaseCoordinator;

  /// The reservation whose REAL handle is the published primary, kept for its
  /// physical lifetime so committed publication can promote exactly it.
  DatabaseOpenReservation? _databaseOpenReservation;

  /// How long a local-read restoration waits for the coordinator ledger to drain
  /// (pending opens and physical handles) before it denies. Test seam.
  @visibleForTesting
  Duration debugLocalReadDrainTimeout = const Duration(seconds: 5);

  /// R8: production configuration REQUIRES a coordinator.
  void configureDatabaseCoordinator(DatabaseAccessBroker coordinator) {
    _databaseCoordinator = coordinator;
    _databaseOpenReservation = null;
  }

  /// R8: forgets the coordinator (a fixture between tests, or a session that
  /// models a process which never had one). Without a coordinator there is no
  /// local read. An architecture pin forbids any use of this name under `lib/`.
  @visibleForTesting
  void configureUncoordinatedForTesting() {
    _databaseCoordinator = null;
    _databaseOpenReservation = null;
  }

  @visibleForTesting
  DatabaseOpenReservation? get debugDatabaseOpenReservation =>
      _databaseOpenReservation;

  int _databaseLossGeneration = 0;
  bool _databasePublicationDenied = false;
  _Admission? _databaseOpeningAdmission;
  _DatabaseIdentityPublication? _databaseIdentityPublication;

  void _revokeDatabasePublication({bool authenticationLoss = true}) {
    _databaseIdentityPublication = null;
    _databaseLossGeneration++;
    if (authenticationLoss) _databasePublicationDenied = true;
    _databaseHostAdmission?._revoked = true;
  }

  /// Retrieval only. Authority is minted solely at successful publication.
  DatabaseHostAdmission? captureDatabaseHostAdmission() {
    final receipt = _databaseHostAdmission;
    return receipt != null && receipt.isCurrent ? receipt : null;
  }

  void _recordDatabaseIdentityPublication(int lossGeneration) {
    if (_databasePublicationDenied ||
        lossGeneration != _databaseLossGeneration) {
      return;
    }
    final host = _accountScope;
    final client = _databaseIssuerClient;
    if (host is! AccountScopeHost || client == null) return;
    final scope = host.current;
    final sdk = client.auth.currentSession;
    if (scope == null ||
        sdk == null ||
        sdk.isExpired ||
        isGuest ||
        _admittedUid != scope.uid ||
        sdk.user.id != scope.uid ||
        _explicitAdmissionEpoch != null ||
        _admissionClosed ||
        scope.database.isReadOnly ||
        !scope.database.admitsSecondary) {
      return;
    }
    _databaseIdentityPublication = _DatabaseIdentityPublication(
        scope, client, sdk, _admissionEpoch, lossGeneration);
  }

  void _commitDatabasePublication(int lossGeneration) {
    if (_databasePublicationDenied ||
        lossGeneration != _databaseLossGeneration) {
      return;
    }
    final host = _accountScope;
    final client = _databaseIssuerClient;
    if (host is! AccountScopeHost || client == null) return;
    final scope = host.current;
    final sdk = client.auth.currentSession;
    if (scope == null || sdk == null) return;
    if (_admissionClosed ||
        (_removeData?.isRunning ?? false) ||
        _explicitAdmissionEpoch != null ||
        _admittedUid != scope.uid ||
        !_onboardingDone ||
        isGuest ||
        status != SessionStatus.authenticated ||
        sdk.isExpired ||
        sdk.user.id != scope.uid ||
        scope.database.isReadOnly ||
        !scope.database.admitsSecondary) {
      return;
    }
    final publication = _databaseIdentityPublication;
    if (publication == null ||
        publication.loss != lossGeneration ||
        publication.epoch != _admissionEpoch ||
        !identical(publication.scope, scope) ||
        !identical(publication.client, client) ||
        publication.sdk.accessToken != sdk.accessToken) {
      return;
    }
    // O: when the published primary was opened under a reservation, committed
    // publication promotes exactly that tracked handle, or issues nothing. A
    // primary no reservation tracks (launch open) keeps the existing rule.
    final reservation = _databaseOpenReservation;
    if (reservation != null &&
        reservation.ownsDatabase(scope.database) &&
        !reservation.promoteCommitted(scope.database, uid: scope.uid!)) {
      return;
    }
    final previous = _databaseHostAdmission;
    if (previous != null && previous.isCurrent) return;
    if (previous != null &&
        previous._revoked &&
        previous._epoch == _admissionEpoch &&
        previous._loss == lossGeneration &&
        identical(previous._scope, scope)) {
      return;
    }
    final receipt = DatabaseHostAdmission._(
        this, scope, client, _admissionEpoch, lossGeneration, sdk);
    _databaseHostAdmission = receipt;
    if (!_databaseAdmissionCurrent(receipt)) _databaseHostAdmission = null;
  }

  bool _databaseAdmissionCurrent(DatabaseHostAdmission receipt) {
    if (receipt._revoked) return false;
    final host = _accountScope;
    final sdk = receipt._client.auth.currentSession;
    final current = identical(receipt._owner, this) &&
        identical(_databaseHostAdmission, receipt) &&
        identical(_databaseIssuerClient, receipt._client) &&
        host is AccountScopeHost &&
        identical(host.current, receipt._scope) &&
        !_admissionClosed &&
        !(_removeData?.isRunning ?? false) &&
        _explicitAdmissionEpoch == null &&
        _admissionEpoch == receipt._epoch &&
        _databaseLossGeneration == receipt._loss &&
        !_databasePublicationDenied &&
        _admittedUid == receipt._scope.uid &&
        _onboardingDone &&
        !isGuest &&
        status == SessionStatus.authenticated &&
        sdk != null &&
        !sdk.isExpired &&
        sdk.user.id == receipt._scope.uid &&
        sdk.accessToken == receipt._sdkSession.accessToken &&
        !receipt.database.isReadOnly &&
        receipt.database.admitsSecondary;
    if (!current) receipt._revoked = true;
    return current;
  }

  static const FlutterSecureStorage _storage = SecureStorageOptions.storage;
  static const String _kDone = 'onboarding_done';
  static const String _kMethod = 'auth_method';
  static const String _kEmail = 'auth_email';
  static const String _kWelcomeManifestoSeen = 'welcome_manifesto_seen';

  /// Coach marks already shown, as a comma-separated id list. One key rather
  /// than one per mark, so [sessionStorageKeys] — which the sign-out wipe walks
  /// explicitly — cannot fall out of date as marks are added.
  static const String _kCoachMarksSeen = 'coach_marks_seen';
  static const String _kCurrentAccount = 'onboarding_current_account_v1';
  static const String _kCompletedAccounts = 'onboarding_completed_accounts_v1';
  static const String _kLocalDataOwnerUid = 'local_data_owner_uid';
  // MALI-069n §Blocker-1: the ADMISSION GENERATION. A cryptographically-random
  // nonce rotated on every genuine admission and invalidated before sign-out /
  // wipe / ownership change, so a background job bound to a previous session is
  // rejected even when the SAME UID signs in again. Read cross-isolate by
  // OwnershipGuard. Not a secret; carries no financial data.
  static const String _kLocalDataOwnerGeneration =
      'local_data_owner_generation';

  /// W5: a sign-out that started and has not completed. Written as the first
  /// await of [signOut] and deleted when it completes; cleared by an explicit
  /// successful admission. While present, [load] never publishes the persisted
  /// identity as authenticated and automatic admission stays closed.
  static const String _kLogoutPending = 'logout_pending_v1';

  /// Deterministic fallback for the H-8 wipe when secure storage cannot
  /// enumerate its entries. The sweep prefers `readAll()` (which also catches
  /// other modules' keys, e.g. backup material) and only falls back to this
  /// list, so a session key can never be missed on a platform where
  /// enumeration is unavailable.
  static const Set<String> sessionStorageKeys = {
    _kDone,
    _kMethod,
    _kEmail,
    emailSignInReceiptStorageKey,
    _kWelcomeManifestoSeen,
    _kCoachMarksSeen,
    _kCurrentAccount,
    _kCompletedAccounts,
    _kLocalDataOwnerUid,
    _kLocalDataOwnerGeneration,
    SecureLocalReadStore.storageKey,
  };

  String? authMethod;
  String? email;
  bool _onboardingDone = false;
  InstallPresentationStore? _installPresentation;
  void configureInstallPresentation(InstallPresentationStore? store) {
    _installPresentation = store;
  }

  /// Called only before bootstrap on a positively identified new installation.
  /// These are onboarding UI flags, never auth, owner, consent or key material.
  Future<void> resetInstallPresentation() async {
    _languageChoiceMade = false;
    for (final key in [_kDone, _kWelcomeManifestoSeen, _kCoachMarksSeen,
      _kCurrentAccount, 'app_theme_mode']) {
      await _storage.delete(key: key);
    }
  }

  bool _languageChoiceMade = false;
  bool get hasChosenOnboardingLanguage => hasSeenWelcomeManifesto ||
      _languageChoiceMade || (_installPresentation?.languageChosen ?? false);

  Future<void> markOnboardingLanguageChosen() async {
    await _installPresentation?.chooseLanguage();
    _languageChoiceMade = true;
    notifyListeners();
  }

  bool _welcomeManifestoSeen = false;
  Set<String> _coachMarksSeen = <String>{};
  String? _currentAccountKey;
  final Set<String> _completedAccountKeys = <String>{};
  StreamSubscription<supabase.AuthState>? _supabaseAuthSubscription;
  Future<void> Function()? _unlinkCaptureDevice;
  Future<void> Function()? Function()? _takeCaptureUnlinkTicket;
  Future<void> Function()? _flushPendingSync;

  /// WP-3b: the account-scope layer. Null before bootstrap has opened a database
  /// (the first reconcile runs before `database_open`): the owner marker is then
  /// the whole admission and bootstrap opens the replica the marker names.
  AccountScopeControl? _accountScope;

  /// WP-3b: the §4.4 Remove-data flow. Null until bootstrap registers it.
  RemoveDataFlow? _removeData;

  /// MALI-054n/070n, reshaped by WP-3b: releases the native capture OWNER and
  /// clears device-wide non-queue residue (pending notification actions, OS
  /// reminders) at an account transition. It does NOT purge waiting queue items:
  /// a non-active owner's items wait (§4.2); only the Remove-data barrier purges.
  /// Returns true only when confirmed. Injected by bootstrap so the session layer
  /// stays decoupled from the capture/native layer.
  Future<bool> Function()? _captureOwnerClear;

  /// Same, for a PLAIN sign-out (the owner hint is kept). Falls back to
  /// [_captureOwnerClear] when not registered.
  Future<bool> Function()? _captureOwnerClearAtSignOut;

  /// Publishes the admitted uid as a RESTRICTIVE native capture owner (local only,
  /// cloud and AI off; no backend link). The typed result is `Future<void>` only
  /// so hooks that return nothing still compile: a hook that publishes completes
  /// with its [RestrictiveCaptureOwnerReceipt], and anything else (null, a
  /// failure, a timeout, a receipt that does not verify) is NOT a publication.
  Future<void> Function(String uid, AdmissionAuthority authority)?
      _publishCaptureOwner;

  /// N2: the native lifetime this process publishes or holds, and the one tail
  /// that orders every fence and publication. A loss queues the fence of the
  /// lifetime it retired; a later publication queues behind it.
  _NativeLifetime? _nativeLifetime;
  Future<NativeLifecycleOutcome> _nativeTail =
      Future<NativeLifecycleOutcome>.value(NativeLifecycleOutcome.unknown);
  int _nativeJobs = 0;

  /// A fence of a verified lifetime that was not confirmed. It keeps Dart denied
  /// and every later publication closed for this process; there is no automatic
  /// retry (a later explicit recovery owns clearing it).
  bool _fenceIncomplete = false;

  /// The lifetimes whose outgoing fence was not confirmed (their exact binding is
  /// kept so an explicit retry is the SAME revocation request) and the allowlisted
  /// reason of the last failure.
  final List<_NativeLifetime> _unconfirmedFences = [];
  String? _fenceReason;

  /// Longest an admission waits for its publication, and a fence for its receipt.
  static const Duration _kNativePublishTimeout = Duration(seconds: 2);
  static const Duration _kNativeFenceTimeout = Duration(seconds: 10);

  /// UID whose admission is deferred because another account's native residue
  /// has to be purged first and the purge hook wasn't registered yet (the first
  /// session reconcile runs before bootstrap registers it). Bootstrap resolves it
  /// via [resolvePendingLocalDataOwnerConflict] right after registering the purge.
  String? _pendingOwnerConflictUid;

  /// Owner-marker value an OLDER build left while its wipe-and-reclaim
  /// transition was in flight. Never a valid uid, so every reader of the marker
  /// treats it as "not this user" and fails closed. This build no longer writes
  /// it (there is no wipe-and-reclaim: each uid has its own replica); a leftover
  /// is just a conflict, resolved by purging residue and claiming for the uid.
  static const String _kOwnerTransitionPrefix = 'owner-transition-pending:';

  /// Serialises every ownership reconcile. Bootstrap, the auth stream
  /// (initialSession / signedIn / tokenRefreshed), AppShell resume
  /// revalidation and interactive sign-in can all reach
  /// [_ensureLocalDataOwnedBy] in the same instant; running them one at a time
  /// means a transition happens once and the rest observe its verified result.
  Future<void> _ownershipTail = Future<void>.value();

  /// A uid whose ownership could not be resolved in THIS process. Automatic
  /// paths (auth events, resume, bootstrap re-entry) short-circuit to
  /// [LocalDataOwnership.unresolved] instead of re-attempting on every event;
  /// an interactive sign-in ([setIdentity]) clears it for one fresh attempt.
  String? _unresolvedOwnerUid;

  /// Bumped by every server-driven auth loss. A reconcile that started before one
  /// must not overwrite its `sessionExpired` once its (now slower: it opens a
  /// replica) admission finishes.
  int _authLossSeq = 0;

  /// F2 — the admission epoch and gate. Accepting an explicit Remove data
  /// advances the epoch and closes admission SYNCHRONOUSLY (before its first
  /// await or notification), so every authority/attempt captured earlier is stale
  /// from that instant. Router state and the Supabase session are NOT the fence.
  int _admissionEpoch = 0;
  int? _explicitAdmissionEpoch;
  Future<void> _identityTail = Future<void>.value();

  /// Removal requests currently accepted and not finished (a counter, so one
  /// finishing never reopens admission under another still running).
  int _removalsAccepted = 0;
  Object? _preparedRemovalOperation;

  /// Logouts accepted and not finished (a counter, like removals). A logout
  /// closes admission SYNCHRONOUSLY, before its first await, and holds the
  /// closure through the scope lock and all identity/native cleanup, so nothing
  /// can be admitted, captured or issued in between. Its end bumps the epoch once
  /// more, so an attempt or authority taken during the closure never becomes
  /// current afterwards.
  int _logoutsAccepted = 0;
  bool get _admissionClosed => _removalsAccepted > 0 || _logoutsAccepted > 0;

  /// Set (to the new epoch) when an AUTOMATIC account switch has accepted and
  /// invalidated every outgoing authority: capture stays closed while the old
  /// scope is torn down. Epoch-owned: only the successful, still-current
  /// publication of that very epoch reopens it, an older finally never does.
  int? _accountSwitchEpoch;

  /// The consent-only capability of the committed identity publication.
  ConsentCapability? _consentCapability;

  /// Advances at EVERY loss of consent authority (`markSessionInvalid`, a
  /// server-driven auth loss, an expired/absent SDK session, logout, removal,
  /// rollback, reset). An admission captures it BEFORE its first await and may
  /// issue a capability only while it is unchanged, so an admission overtaken by
  /// a loss can never restore the authority the loss revoked, whatever its other
  /// (ordinary F2) admission state still says.
  int _consentLossSeq = 0;

  /// A logout that FAILED part-way (the scope could not be locked, a cleanup
  /// threw): the old status and scope may still look authenticated/open, so local
  /// and consent work stay closed and no automatic admission can restore the old
  /// authority. Only a later successful logout, Remove data, or an explicit
  /// successful admission clears it.
  bool _logoutIncomplete = false;

  /// Test/production seam for the SDK client that provides identity evidence.
  supabase.SupabaseClient? Function()? _consentSdkClient;

  /// The uid whose admission completed in this process; the removal target when
  /// the owner marker is missing.
  String? _admittedUid;

  /// Ownership work already dispatched (marker/generation writes, scope
  /// activation). Removal drains it before deleting anything.
  final Set<Future<void>> _inflightAdmissions = {};

  /// Bounded LOCAL operations already dispatched (settings/gate/database work
  /// under a local-work authority or a consent capability). Tracked apart from
  /// the admissions so an admission can drain only the local work, never itself;
  /// Remove data and logout drain both.
  final Set<Future<void>> _inflightLocal = {};

  SessionStatus get status => value;

  /// F2 — captured BEFORE the sign-in provider is awaited. Only an attempt that
  /// is still current when it completes can authorize (re)creating a removed
  /// uid's data.
  AuthAttempt beginAuthAttempt() {
    // ASR §4.4/§11.3: the intent is registered synchronously; its cause is
    // IDENTITY for an in-flight ASR op (POLICY for the other kinds).
    final intent = AuthCoordinator.active?.registerAttemptIntent() ?? 0;
    AutomaticSessionRecovery.active?.yieldToExplicitAttempt();
    // Reauthentication may reuse the same open replica and skip bootstrap.
    // Retire older request responses before the explicit provider exchange.
    if (!_admissionClosed && !(_removeData?.isRunning ?? false)) {
      CloudEgressGate.instance.advanceEpoch(EpochCause.explicitAttempt);
    } else if (intent != 0) {
      CloudEgressGate.instance.noteCause(EpochCause.explicitAttempt);
    }
    return AuthAttempt(_admissionEpoch, intent);
  }

  AccountFenceAuthority get _accountFence => AccountFenceAuthority.shared;
  (String, String, int)? _accountFenceOwner;

  bool get accountFenceCanReplace => _accountScope == null &&
      _inflightAdmissions.isEmpty && _explicitAdmissionEpoch == null;

  AccountScopeHost? accountFenceHostForDatabase(AppDatabase database) {
    final host = _accountScope;
    return host is AccountScopeHost && identical(host.current?.database, database)
        ? host : null;
  }

  /// Denial-only reservation. The session verifies its own committed proof;
  /// callers cannot supply a Boolean in place of the original capability.
  void Function() reserveAccountFenceParking(AccountScopeHost host,
      AccountScope scope, AdmissionAuthority capability, String ownerToken,
      int egressEpoch) {
    if (CloudEgressGate.instance.epoch != egressEpoch ||
        accountFenceCapturedLifetimeToken(host, scope, capability) != ownerToken) {
      throw const StaleAdmissionException();
    }
    final reservation = Completer<void>();
    _inflightAdmissions.add(reservation.future);
    var settled = false;
    return () {
      if (settled) return;
      settled = true;
      _inflightAdmissions.remove(reservation.future);
      reservation.complete();
    };
  }

  String? accountFenceOwnerToken(AccountScopeHost host, AccountScope scope,
      AdmissionAuthority capability) {
    if (!capability.isCurrent) return null;
    return accountFenceCapturedLifetimeToken(host, scope, capability);
  }

  /// Deny-only proof for a handle captured earlier with a real current capability.
  /// This does not authorize local work when durable readiness is unresolved.
  String? accountFenceCapturedLifetimeToken(AccountScopeHost host, AccountScope scope,
      AdmissionAuthority capability) {
    final owner = _accountFenceOwner;
    if (!identical(_accountScope, host) || !identical(host.current, scope) ||
        scope.database.lifecycleState != DatabaseLifecycleState.open ||
        scope.uid != _admittedUid || capability.uid != scope.uid ||
        capability.epoch != _admissionEpoch ||
        status != SessionStatus.authenticated || _explicitAdmissionEpoch != null ||
        _admissionClosed || (_removeData?.isRunning ?? false) ||
        owner == null || owner.$1 != scope.uid || owner.$3 != _admissionEpoch) {
      return null;
    }
    return owner.$2;
  }

  Future<(String?, String?)> readAccountFenceOwnerProof() async => (
    await _storage.read(key: _kLocalDataOwnerUid),
    await _storage.read(key: _kLocalDataOwnerGeneration),
  );

  Future<void> retireAccountFence(AccountScopeHost host, AccountScope scope) {
    if (!identical(_accountScope, host) || !identical(host.current, scope)) {
      throw const StaleAdmissionException();
    }
    _accountFenceOwner = null;
    _admissionEpoch++;
    _explicitAdmissionEpoch = null;
    _authLossSeq++;
    _revokeDatabasePublication();
    _revokeConsentProof();
    CloudEgressGate.instance.advanceEpoch(EpochCause.consentLoss);
    return Future.wait(_inflightAdmissions.toList()).then<void>((_) {});
  }

  void publishAccountFenceRetirement() {
    value = SessionStatus.sessionExpired;
  }

  bool _attemptCurrent(AuthAttempt a) =>
      !_admissionClosed && a.epoch == _admissionEpoch;

  AdmissionAuthority _authorityAt(
    int epoch,
    String uid, {
    required bool canCreate,
    bool Function()? sessionCurrent,
  }) =>
      AdmissionAuthority(
        uid,
        () =>
            !_admissionClosed &&
            !(_removeData?.isRunning ?? false) &&
            _admissionEpoch == epoch &&
            _accountFence.permits(uid) &&
            (sessionCurrent?.call() ?? true),
        canCreate: canCreate,
        epoch: epoch,
      );

  /// Authority a rebootstrap holds for [uid] (it may create the fresh staging
  /// replica and re-admit after a purge). Refused for a uid with a removal
  /// pending/completed; an explicit Remove data accepted later revokes it.
  Future<AdmissionAuthority> maintenanceAuthority(String uid) async {
    final epoch = _admissionEpoch;
    await _accountFence.guard(uid, current: () =>
        _admissionEpoch == epoch && !_admissionClosed);
    if (_admissionClosed || _logoutIncomplete) {
      throw const StaleAdmissionException();
    }
    final removal = _removeData;
    if (removal != null) {
      try {
        if (await removal.hasPending() ||
            (await removal.revokedUids()).contains(uid)) {
          throw const StaleAdmissionException();
        }
      } on StaleAdmissionException {
        rethrow;
      } catch (_) {
        throw const StaleAdmissionException();
      }
    }
    final authority = _authorityAt(epoch, uid, canCreate: true);
    authority.requireCurrent();
    return authority;
  }

  /// Test-only: drops the process-wide ownership chain and in-flight set. A
  /// widget test runs the shell inside a fake-async zone that dies with the test,
  /// and a chain link created there would otherwise never complete for the next
  /// test sharing this singleton.
  @visibleForTesting
  void debugResetAdmissionState() {
    _ownershipTail = Future<void>.value();
    _identityTail = Future<void>.value();
    _explicitAdmissionEpoch = null;
    _inflightAdmissions.clear();
    _inflightLocal.clear();
    _removalsAccepted = 0;
    _logoutsAccepted = 0;
    _logoutIncomplete = false;
    _accountSwitchEpoch = null;
    // Resets injected state only: it never dispatches physical native work.
    _consentCapability = null;
    _consentLossSeq++;
    _nativeLifetime = null;
    _nativeTail =
        Future<NativeLifecycleOutcome>.value(NativeLifecycleOutcome.unknown);
    _nativeJobs = 0;
    _fenceIncomplete = false;
    _unconfirmedFences.clear();
    _fenceReason = null;
    _consentSdkClient = null;
    _admittedUid = null;
    _localReadLocked = false;
    _localReadCleanupIncomplete = false;
    _outstandingOperationDenials.clear();
    _localReadStorageContinuity = null;
    _localReadProof = null;
    _localReadHandoffProof = null;
    _localReadEgressHold = false;
    _localReadTransition = null;
    _pendingFirstGrant = null;
    _localReadTail = Future<void>.value();
  }

  /// Drops the consent proof SYNCHRONOUSLY and advances the loss generation, so
  /// every admission that captured the earlier generation is barred from issuing.
  void _revokeConsentProof({bool expiry = false}) {
    _consentCapability = null;
    _consentLossSeq++;
    _retireNativeLifetime(
        expiryLifecycle:
            expiry ? AuthCoordinator.active?.store.committed?.lifecycle : null);
  }

  /// Runs [job] after every earlier native lifecycle job. A job maps every failure
  /// to an outcome, so the tail never carries an error and never hangs.
  Future<NativeLifecycleOutcome> _enqueueNative(
      Future<NativeLifecycleOutcome> Function() job) {
    _nativeJobs++;
    final run = _nativeTail.then((_) => job()).whenComplete(() {
      if (_nativeJobs > 0) _nativeJobs--;
    });
    _nativeTail = run.catchError((Object _) => NativeLifecycleOutcome.incomplete);
    return run;
  }

  /// Completes with the outcome of the newest native lifecycle job queued so far.
  Future<NativeLifecycleOutcome> nativeLifecycleSettled() => _nativeTail;

  /// N-E owner prerequisite: the exact native lifecycle the restrictive
  /// publication of the committed identity behind [capability] produced.
  ///
  /// Waits (bounded) for THAT lifetime's publication to settle, and returns its
  /// verified binding only while the lifetime is still the one this process holds
  /// for exactly the capability's uid, epoch and database, was never lost, and
  /// the capability is still current. Null for anything else: no hook, a receipt
  /// that did not verify, a fence that is incomplete, a lost or replaced
  /// lifetime. It publishes nothing, links nothing and grants no authority; it
  /// reads proof the admission already obtained.
  Future<CloudEgressEnableBinding?> committedOwnerLifetime(
          ConsentCapability capability) async =>
      (await _awaitOwnerProof(capability)).binding;

  String _proofReason(String proof, [String? detail]) =>
      detail == null ? 'owner_publication/$proof' : 'owner_publication/$proof/$detail';

  String _fenceDetail() => _fenceReason ?? 'fence_unconfirmed';

  Future<OwnerLifetimeProof> _awaitOwnerProof(
      ConsentCapability capability) async {
    bool matches(_NativeLifetime? l) =>
        l != null &&
        !l.lost &&
        l.uid == capability.uid &&
        l.epoch == capability.epoch &&
        (capability.database == null ||
            identical(l.database, capability.database));
    final lifetime = _nativeLifetime;
    if (lifetime == null) {
      return OwnerLifetimeProof(null, _proofReason('no_lifetime', 'not_attempted'));
    }
    if (lifetime.lost) return OwnerLifetimeProof(null, _proofReason('lifetime_lost'));
    if (!matches(lifetime)) return OwnerLifetimeProof(null, _proofReason('mismatch'));
    if (!capability.isCurrent) {
      return OwnerLifetimeProof(null, _proofReason('not_current'));
    }
    if (_fenceIncomplete) {
      return OwnerLifetimeProof(
          null, _proofReason('fence_incomplete', _fenceDetail()));
    }
    NativeLifecycleOutcome outcome;
    try {
      outcome = await lifetime.published.future
          .timeout(_kNativePublishTimeout + _kNativeFenceTimeout);
    } catch (_) {
      return OwnerLifetimeProof(null, _proofReason('wait_timeout'));
    }
    if (!identical(_nativeLifetime, lifetime)) {
      return OwnerLifetimeProof(null, _proofReason('replaced'));
    }
    if (!matches(lifetime)) {
      return OwnerLifetimeProof(null, _proofReason('lifetime_lost'));
    }
    if (!capability.isCurrent) {
      return OwnerLifetimeProof(null, _proofReason('not_current'));
    }
    if (_fenceIncomplete) {
      return OwnerLifetimeProof(
          null, _proofReason('fence_incomplete', _fenceDetail()));
    }
    if (outcome != NativeLifecycleOutcome.confirmed || lifetime.binding == null) {
      return OwnerLifetimeProof(
          null,
          _proofReason('publication_incomplete',
              lifetime.reason ?? 'not_attempted'));
    }
    return OwnerLifetimeProof(lifetime.binding, '');
  }

  /// Enable Phase 1's owner prerequisite. Like [committedOwnerLifetime], but when
  /// this process holds no confirmed native proof for the capability's lifetime
  /// (a returning same-marker admission publishes none) the explicit enable
  /// authorizes ONE bounded restrictive publication for exactly that capability,
  /// uid, writable scope and database. Existing confirmed proof is returned
  /// unchanged. No admission or local-operation drain, no timer, no wait on the
  /// calling enable. An unconfirmed outgoing fence is retried as the SAME local
  /// revocation and only an exactly confirmed retirement (with no other
  /// unresolved fence) reopens publication; otherwise it stays denied.
  Future<OwnerLifetimeProof> ensureCommittedOwnerLifetime(
      ConsentCapability capability,
      {RestrictivePublishPlan? plan}) async {
    final scope = _accountScope?.activeScope;
    bool valid() {
      final live = _accountScope?.activeScope;
      return capability.isCurrent &&
          scope != null &&
          identical(live, scope) &&
          !scope.isLocalRead &&
          !scope.database.isReadOnly &&
          scope.uid == capability.uid &&
          (capability.database == null ||
              identical(scope.database, capability.database)) &&
          scope.database.lifecycleState == DatabaseLifecycleState.open &&
          _sdkSessionFresh(capability.uid);
    }

    if (!valid()) return OwnerLifetimeProof(null, _proofReason('not_current'));
    if (_fenceIncomplete) {
      await _retryUnconfirmedFences();
      if (!valid()) return OwnerLifetimeProof(null, _proofReason('not_current'));
      if (_fenceIncomplete) {
        return OwnerLifetimeProof(
            null, _proofReason('fence_incomplete', _fenceDetail()));
      }
    }
    final held = _nativeLifetime;
    final heldUsable = !(plan?.requiresFreshLifetime ?? false) && held != null &&
        !held.lost &&
        held.uid == capability.uid &&
        held.epoch == capability.epoch &&
        identical(held.database, scope!.database) &&
        (held.binding != null || !held.published.isCompleted);
    if (!heldUsable) {
      if (_publishCaptureOwner == null) {
        return OwnerLifetimeProof(
            null, _proofReason('publication_incomplete', 'hook_missing'));
      }
      final authority = _authorityAt(capability.epoch, capability.uid,
          canCreate: false, sessionCurrent: valid);
      if (!authority.isCurrent) {
        return OwnerLifetimeProof(
            null, _proofReason('publication_incomplete', 'authority'));
      }
      final before = _nativeLifetime;
      _explicitPublish = plan == null ? null : (authority: authority, plan: plan);
      try {
        await _publishNativeLifetime(_Admission(capability.uid, authority));
      } finally {
        _explicitPublish = null;
      }
      if (!identical(_nativeLifetime, before) && _nativeLifetime == null) {
        return OwnerLifetimeProof(null, _proofReason('lifetime_lost'));
      }
      if (identical(_nativeLifetime, before)) {
        // Nothing was queued: the publication guard refused it before any job.
        return OwnerLifetimeProof(
            null, _proofReason('publication_incomplete', 'scope'));
      }
    }
    return _awaitOwnerProof(capability);
  }

  /// Explicit enable only: restore fencing ownership of an already-live native
  /// lifetime after a cold restart. Never publishes or clears a pending denial.
  Future<OwnerLifetimeProof> resumeCommittedOwnerLifetime(
      ConsentCapability capability, PendingEnableLifetimeProof proof) async {
    final scope = _accountScope?.activeScope;
    final before = _nativeLifetime;
    bool valid() => capability.isCurrent && identical(_consentCapability, capability) &&
        scope != null && identical(_accountScope?.activeScope, scope) &&
        !scope.isLocalRead && !scope.database.isReadOnly &&
        scope.uid == capability.uid && identical(capability.database, scope.database) &&
        scope.database.lifecycleState == DatabaseLifecycleState.open &&
        _sdkSessionFresh(capability.uid) && !_fenceIncomplete &&
        _unconfirmedFences.isEmpty && _nativeJobs == 0 && identical(_nativeLifetime, before);
    if (!valid()) return OwnerLifetimeProof(null, _proofReason('not_current'));
    final b = proof.pending.binding;
    if (b == null || (before != null && (before.lost || before.uid != capability.uid ||
        before.epoch != capability.epoch || !identical(before.database, scope!.database) ||
        before.binding?.ownerGeneration != b.ownerGeneration ||
        before.binding?.ownerEpoch != b.ownerEpoch || !before.published.isCompleted))) {
      return OwnerLifetimeProof(null, _proofReason('mismatch'));
    }
    try {
      await proof.verify(capability);
      if (!valid()) return OwnerLifetimeProof(null, _proofReason('not_current'));
    } catch (_) {
      return OwnerLifetimeProof(null, _proofReason('mismatch'));
    }
    if (before != null) return _awaitOwnerProof(capability);
    final random = Random.secure();
    final lifetime = _NativeLifetime(capability.uid, capability.epoch, scope!.database);
    lifetime.binding = CloudEgressEnableBinding(
        operationId: [for (var i = 0; i < 16; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0')].join(),
        transitionGeneration: b.transitionGeneration, reservedVersion: b.reservedVersion,
        ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch);
    lifetime.published.complete(NativeLifecycleOutcome.confirmed);
    _nativeLifetime = lifetime;
    return OwnerLifetimeProof(lifetime.binding, '');
  }

  ({AdmissionAuthority authority, RestrictivePublishPlan plan})? _explicitPublish;

  /// The publication plan of the explicit Cloud enable that is publishing under
  /// exactly [authority] right now (null for every ordinary admission).
  RestrictivePublishPlan? explicitPublishPlanFor(AdmissionAuthority authority) {
    final held = _explicitPublish;
    return held != null && identical(held.authority, authority)
        ? held.plan
        : null;
  }

  /// Retries each outgoing fence that was not confirmed, as the same revocation
  /// request. The blocker clears only when none remains unresolved.
  Future<void> _retryUnconfirmedFences() async {
    if (_unconfirmedFences.isEmpty) return;
    final gate = CloudEgressGate.instance;
    for (final lifetime in List.of(_unconfirmedFences)) {
      await _enqueueNative(() => _fenceLifetime(lifetime, gate));
    }
    if (_unconfirmedFences.isEmpty) {
      _fenceIncomplete = false;
      _fenceReason = null;
      gate.releaseLifecycleDenial();
    }
  }

  /// SYNCHRONOUS, before any await of any loss origin: ends the native lifetime
  /// this process published (or is publishing), denies Dart egress and queues the
  /// fence of exactly that captured lifetime. Idempotent: a lifetime is retired
  /// once, so repeated loss events never mint a second fence operation. A
  /// publication that already failed has nothing native to fence.
  void _retireNativeLifetime({int? expiryLifecycle}) {
    final lifetime = _nativeLifetime;
    if (lifetime == null) return;
    _nativeLifetime = null;
    if (lifetime.published.isCompleted && lifetime.binding == null) return;
    lifetime.lost = true;
    lifetime.expiryLifecycle = expiryLifecycle;
    final gate = CloudEgressGate.instance;
    gate.denyForLifecycleLoss();
    unawaited(_enqueueNative(() => _fenceLifetime(lifetime, gate)));
  }

  /// Fences the captured [lifetime] natively with its exact outgoing binding.
  /// Confirmed only by a reply that independently proves the retirement in both
  /// layers; anything else leaves the lifetime unconfirmed and Dart denied.
  Future<NativeLifecycleOutcome> _fenceLifetime(
      _NativeLifetime lifetime, CloudEgressGate gate) async {
    final binding = lifetime.binding;
    if (binding == null) {
      // No verified native proof of the lifetime: nothing exact to revoke.
      if (!_fenceIncomplete) gate.releaseLifecycleDenial();
      return NativeLifecycleOutcome.unknown;
    }
    var outcome = NativeLifecycleOutcome.incomplete;
    var reason = 'fence_unconfirmed';
    try {
      final reply = await NativeCaptureBridge.revokeCaptureAuthorizationLifetime(
        ownerUid: lifetime.uid,
        binding: binding,
        expirySessionLifecycle: lifetime.expiryLifecycle,
      ).timeout(_kNativeFenceTimeout);
      if (reply != null && reply.confirmsLifetimeRevoked(binding)) {
        outcome = NativeLifecycleOutcome.confirmed;
        final evidence = reply.expiryEvidence;
        if (evidence != null) {
          _expiryEvidence = (owner: lifetime.uid, evidenceId: evidence.evidenceId);
        }
      }
    } on TimeoutException {
      reason = 'fence_timeout';
    } catch (_) {
      // Failed or malformed: not a receipt.
    }
    if (outcome == NativeLifecycleOutcome.confirmed) {
      _unconfirmedFences.remove(lifetime);
    } else {
      _fenceIncomplete = true;
      _fenceReason = reason;
      if (!_unconfirmedFences.contains(lifetime)) _unconfirmedFences.add(lifetime);
    }
    if (!_fenceIncomplete) gate.releaseLifecycleDenial();
    return outcome;
  }

  /// Android's owner-scoped capture queue (no egress state there: the iOS
  /// restrictive lifetime below is a separate thing). The epoch is read first
  /// and the publish is a compare-and-swap on it, sent only while [adm] is
  /// current, so a sign-out / switch / removal clear can never be overtaken by
  /// a stale publish. Awaited and bounded; a failure leaves capture unbound
  /// (claimable, never another account's) and never fails the admission.
  Future<void> _publishOwnerScopedCaptureOwner(_Admission adm) async {
    final scope = _accountScope?.activeScope;
    if (scope == null ||
        scope.isLocalRead ||
        scope.database.isReadOnly ||
        scope.uid != adm.uid ||
        !adm.current) {
      return;
    }
    try {
      await NativeCaptureBridge.publishOwnerScopedCaptureOwner(adm.uid,
              stillCurrent: () => adm.current)
          .timeout(_kNativePublishTimeout);
    } catch (_) {
      // Refused (another clear won, a removal barrier) or unavailable: no
      // owner is claimed. Codes only are known here; nothing is logged.
    }
  }

  /// Publishes a fresh restrictive native lifetime for [adm], ordered behind any
  /// earlier fence, and waits (bounded) for the verified receipt. Never throws.
  /// The same uid, epoch and database with a lifetime already published or being
  /// published is an idempotent reconcile: it publishes nothing again.
  Future<NativeLifecycleOutcome> _publishNativeLifetime(_Admission adm) {
    final publish = _publishCaptureOwner;
    final scope = _accountScope?.activeScope;
    final authority = adm.authority;
    if (publish == null ||
        scope == null ||
        scope.isLocalRead ||
        scope.database.isReadOnly ||
        scope.uid != adm.uid ||
        !authority.isCurrent) {
      return Future<NativeLifecycleOutcome>.value(NativeLifecycleOutcome.unknown);
    }
    final held = _nativeLifetime;
    if (!(explicitPublishPlanFor(authority)?.requiresFreshLifetime ?? false) &&
        held != null &&
        held.uid == adm.uid &&
        held.epoch == authority.epoch &&
        identical(held.database, scope.database) &&
        (held.binding != null || !held.published.isCompleted)) {
      return held.published.future;
    }
    final lifetime = _NativeLifetime(adm.uid, authority.epoch, scope.database);
    _nativeLifetime = lifetime;
    final gate = CloudEgressGate.instance;
    return _enqueueNative(() async {
      var outcome = NativeLifecycleOutcome.incomplete;
      if (_fenceIncomplete) {
        // An unconfirmed fence keeps every later publication closed.
        lifetime.reason = _fenceDetail();
      } else if (lifetime.lost || !authority.isCurrent) {
        outcome = NativeLifecycleOutcome.unknown;
        lifetime.reason = 'authority';
      } else {
        try {
          final Future<Object?> reply = publish(adm.uid, authority);
          final answer = await reply.timeout(_kNativePublishTimeout);
          if (answer is RestrictiveOwnerRefusal) lifetime.reason = answer.reason;
          lifetime.binding = _lifetimeBinding(adm.uid, answer);
          _noteAsrSuccessorReceipt(adm.uid, lifetime, answer);
          if (lifetime.binding != null) {
            outcome = NativeLifecycleOutcome.confirmed;
          } else {
            lifetime.reason ??= answer == null
                ? 'receipt_null'
                : answer is RestrictiveCaptureOwnerReceipt
                    ? 'binding_rejected'
                    : 'receipt_unconfirmed';
          }
        } on TimeoutException {
          lifetime.reason = 'timeout';
        } catch (_) {
          // Failed: no receipt, so no native proof is claimed.
          lifetime.reason = 'hook_error';
        }
      }
      if (outcome == NativeLifecycleOutcome.confirmed &&
          !lifetime.lost &&
          !_fenceIncomplete) {
        gate.releaseLifecycleDenial();
      }
      lifetime.published.complete(outcome);
      return outcome;
    });
  }

  /// The exact native lifecycle a verified restrictive [reply] publishes for
  /// [uid], with a stable 128-bit revocation request identity allocated now.
  /// Null unless the receipt verifies for that uid and both layers agree; the
  /// numbers come from the receipt itself, never from a status or a stored uid.
  CloudEgressEnableBinding? _lifetimeBinding(String uid, Object? reply) {
    if (reply is! RestrictiveCaptureOwnerReceipt) return null;
    final phase = reply.phase;
    if (phase.egress.isEmpty) return null;
    final generation = phase.egress.first.transitionGeneration;
    final version = phase.egress.first.reservedVersion;
    final ownerGeneration = phase.ownerGeneration;
    final ownerEpoch = phase.ownerEpoch;
    if (generation == null ||
        version == null ||
        ownerGeneration == null ||
        ownerEpoch == null ||
        !phase.egress.every((r) => r.transitionGeneration == generation) ||
        !reply.confirms(uid: uid, expectedEpoch: ownerEpoch, version: version)) {
      return null;
    }
    final random = Random.secure();
    return CloudEgressEnableBinding(
      operationId: [
        for (var i = 0; i < 16; i++)
          random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ].join(),
      transitionGeneration: generation,
      reservedVersion: version,
      ownerGeneration: ownerGeneration,
      ownerEpoch: ownerEpoch,
    );
  }

  /// The actual SDK client whose live session is the identity evidence a consent
  /// capability needs. Production reads the bound `Supabase.instance.client`;
  /// this typed seam lets a test inject the existing MockClient-backed client.
  /// It grants nothing by itself: a capability is still issued only from a
  /// committed publication, and only while this client holds a fresh,
  /// non-expired session of exactly that uid.
  void configureConsentSdkClient(supabase.SupabaseClient? Function()? provider) {
    _consentSdkClient = provider;
  }

  supabase.SupabaseClient? _clientForConsent() {
    final provider = _consentSdkClient;
    if (provider != null) return provider();
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return supabase.Supabase.instance.client;
    } catch (_) {
      return null;
    }
  }

  /// True only while the SDK client holds a non-expired session of [uid].
  bool _sdkSessionFresh(String uid, [supabase.SupabaseClient? client]) {
    final session = (client ?? _clientForConsent())?.auth.currentSession;
    return session != null && !session.isExpired && session.user.id == uid;
  }

  /// Captures a read-only epoch for a bounded local unit on the admitted scope.
  AdmissionAuthority? captureLocalWorkAuthority() {
    final uid = _accountScope?.activeUid;
    final scope = _accountScope;
    if (uid == null ||
        localReadActive ||
        (scope is AccountScopeHost && (scope.current?.isLocalRead ?? false)) ||
        status != SessionStatus.authenticated ||
        _explicitAdmissionEpoch != null ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete ||
        _admissionClosed) {
      return null;
    }
    return _authorityAt(_admissionEpoch, uid, canCreate: false);
  }

  /// O-LC-2 — the account lifecycle a foreground callback (notification tap or
  /// quick action) STARTED in. Null when no writable lifecycle is admitted (signed
  /// out, offline read-only, a pending or running local-read transition, removal,
  /// an explicit admission in flight): such a callback authorises nothing. The
  /// returned authority stops being current the moment the lifecycle is replaced
  /// in any way: writable -> local-read, logout, same-UID readmission, another
  /// UID, or removal, so a handler paused at an await cannot act for a successor.
  AdmissionAuthority? captureCallbackOrigin() {
    final base = captureLocalWorkAuthority();
    if (base == null || localReadEgressDenied) return null;
    final host = _accountScope;
    final scope = host is AccountScopeHost ? host.current : null;
    return _authorityAt(base.epoch, base.uid,
        canCreate: false,
        sessionCurrent: () =>
            status == SessionStatus.authenticated &&
            _explicitAdmissionEpoch == null &&
            !localReadEgressDenied &&
            (host is! AccountScopeHost || identical(host.current, scope)));
  }

  /// Only local database work belongs here: never await network or removal.
  static const _localAdmissionChain = #localAdmissionReservationChain;

  Future<T> runAdmittedLocalOperation<T>(
      AdmissionAuthority authority, Future<T> Function() action) {
    authority.requireCurrent();
    if (status != SessionStatus.authenticated ||
        _explicitAdmissionEpoch != null ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete) {
      throw const StaleAdmissionException();
    }
    authority.requireCurrent();
    return _localOp(action, current: () => authority.isCurrent &&
        status == SessionStatus.authenticated && _explicitAdmissionEpoch == null &&
        _accountSwitchEpoch == null && !_logoutIncomplete);
  }

  /// The consent-only capability of the CURRENT lifecycle, or null. It is exactly
  /// the one a committed identity publication issued (an explicit sign-in, or a
  /// guarded automatic publication of an actually fresh SDK session). Nothing is
  /// ever derived here from the authenticated status, the local-work authority or
  /// the active database: those do not prove a fresh matching identity, and a
  /// revoked proof is never renewed from them. Null during any explicit
  /// admission, logout (including a failed one), removal or account switch.
  ConsentCapability? captureConsentCapability() {
    if (_explicitAdmissionEpoch != null ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete ||
        _admissionClosed) {
      return null;
    }
    final issued = _consentCapability;
    return issued != null && issued.isCurrent ? issued : null;
  }

  /// Runs ONE bounded local consent operation (the typed repository write and the
  /// gate/settings reads around it) under [capability]. No network, retry,
  /// removal or revoke belongs inside: it is drained by logout, an account
  /// switch, a same-uid readmission and Remove data, which wait for it to settle.
  /// Unlike [runAdmittedLocalOperation] it is also open to the committed fresh
  /// identity (needsOnboarding), and ONLY through this typed capability.
  Future<T> runConsentLocalOperation<T>(
      ConsentCapability capability, Future<T> Function() action) {
    // A newer explicit admission advanced the epoch when it was accepted, so a
    // capability of the lifecycle it replaces is already stale here.
    capability.requireCurrent();
    return _localOp(action, current: () => capability.isCurrent);
  }

  /// Issues the consent-only capability from an actual COMMITTED identity
  /// publication (an explicit sign-in after its durable revocation clearance, or
  /// a guarded automatic publication). Every condition is checked synchronously
  /// at the publication, and the result is bound to this admission epoch, uid,
  /// auth-loss and consent-loss generations (captured before the admission's
  /// first await), live scope generation and database, to the actual SDK
  /// session evidence ([sdkFresh]) and to the caller's own freshness predicate
  /// when it passed one. A predicate alone never suffices. canCreate is false.
  /// Anything weaker (guest, no SDK session, deferred/unresolved/pending
  /// ownership, a failed or unfinished admission, no live scope) issues nothing.
  /// An existing, still-current capability of the same lifecycle is kept, so a
  /// token refresh does not revoke an operation in flight.
  void _issueConsentCapability(
    _Admission adm, {
    required String method,
    required bool Function() sdkFresh,
    required bool Function()? sessionCurrent,
    required int authLossSeq,
    required int consentLossSeq,
  }) {
    final scope = _accountScope?.activeScope;
    final epoch = adm.authority.epoch;
    final uid = adm.uid;
    final existing = _consentCapability;
    if (existing != null &&
        existing.uid == uid &&
        existing.epoch == epoch &&
        existing.isCurrent) {
      return;
    }
    _consentCapability = null;
    // The generations were captured BEFORE the admission's first await; any loss
    // since (including one raised by a synchronous publication listener) bars it.
    if (_authLossSeq != authLossSeq ||
        _consentLossSeq != consentLossSeq ||
        status == SessionStatus.sessionExpired ||
        method == 'guest' ||
        !sdkFresh() ||
        (sessionCurrent != null && !sessionCurrent()) ||
        !adm.current ||
        _admissionEpoch != epoch ||
        _admittedUid != uid ||
        _unresolvedOwnerUid != null ||
        _pendingOwnerConflictUid != null ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete ||
        scope == null ||
        scope.isLocalRead ||
        scope.database.isReadOnly ||
        scope.uid != uid ||
        _accountScope?.activeUid != uid ||
        scope.database.lifecycleState != DatabaseLifecycleState.open) {
      return;
    }
    final database = scope.database;
    final generation = scope.generation;
    late final ConsentCapability capability;
    // Defence in depth only: the primary revocation is SYNCHRONOUS at the real
    // origin (the proof object is dropped when the loss/transition happens, and
    // this closure compares identity), so a recovery can never revive it.
    var revoked = false;
    capability = ConsentCapability(
      uid: uid,
      epoch: epoch,
      database: database,
      isCurrent: () {
        if (revoked) return false;
        final live = _accountScope?.activeScope;
        final holds = identical(_consentCapability, capability) &&
            !_admissionClosed &&
            !_logoutIncomplete &&
            !(_removeData?.isRunning ?? false) &&
            _admissionEpoch == epoch &&
            _authLossSeq == authLossSeq &&
            _consentLossSeq == consentLossSeq &&
            status != SessionStatus.sessionExpired &&
            _admittedUid == uid &&
            _accountSwitchEpoch == null &&
            sdkFresh() &&
            (sessionCurrent?.call() ?? true) &&
            live != null &&
            live.uid == uid &&
            live.generation == generation &&
            identical(live.database, database) &&
            database.lifecycleState == DatabaseLifecycleState.open;
        if (!holds) revoked = true;
        return holds;
      },
    );
    _consentCapability = capability;
  }

  Future<T> _admissionOp<T>(Future<T> Function() f,
      {required bool Function() current, bool localOperation = false}) {
    if (!current()) throw const StaleAdmissionException();
    final reservation = Completer<void>();
    final done = reservation.future;
    _inflightAdmissions.add(done);
    if (localOperation) _inflightLocal.add(done);
    void settle() {
      _inflightAdmissions.remove(done);
      _inflightLocal.remove(done);
      reservation.complete();
    }

    try {
      final inherited = Zone.current[_localAdmissionChain] as List<Future<void>>? ?? const [];
      final run = localOperation
          ? runZoned(f, zoneValues: {_localAdmissionChain: List<Future<void>>.unmodifiable([...inherited, done])})
          : f();
      run.then<void>((_) => settle(), onError: (Object _, StackTrace __) => settle());
      return run;
    } catch (_) {
      settle();
      rethrow;
    }
  }

  /// O-BX-1 — every exclusive-maintenance entrance that is not Remove data (the
  /// backup restore) takes part in the admission drain. The local-read
  /// restoration drains it ([drainAdmissions]) before it begins its exclusion, and
  /// a maintenance operation that has not started yet is REFUSED, creating
  /// nothing, from the moment a restoration begins until its outcome is known
  /// (and for as long as a read scope is published). The database additionally
  /// refuses or awaits maintenance when it is closed ([AppDatabase.close]).
  Future<void> runMaintenanceParticipant(Future<void> Function() run) async {
    if (_preparedRemovalOperation != null ||
        _localReadTransitionFence ||
        _localReadEgressHold ||
        localReadActive) {
      throw const StaleOwnershipException();
    }
    return _admissionOp(run,
        current: () =>
            _preparedRemovalOperation == null &&
            !_localReadTransitionFence &&
            !_localReadEgressHold &&
            !localReadActive);
  }

  /// True from the point a local-read restoration starts draining admitted work
  /// until its exclusion is owned ([_localReadEgressHold] then takes over).
  bool _localReadTransitionFence = false;

  /// Completes when no admission work is in flight. Called by the removal flow
  /// after admission was closed, so the set can only shrink.
  /// Local work shares the whole-Future reservation ledger with admissions,
  /// and also has its own set so an admission never waits on itself.
  Future<T> _localOp<T>(Future<T> Function() f,
      {required bool Function() current}) =>
      _admissionOp(f, current: current, localOperation: true);

  Future<void> drainAdmissions() async {
    while (_inflightAdmissions.isNotEmpty || _inflightLocal.isNotEmpty) {
      await Future.wait([..._inflightAdmissions, ..._inflightLocal]);
    }
  }

  /// Drains ONLY the bounded local operations: what an admission calls before it
  /// closes or reuses a database. Draining the admissions here would wait on the
  /// admission itself.
  Future<void> _drainLocalOperations() async {
    while (_inflightLocal.isNotEmpty) {
      await Future.wait(_inflightLocal.toList());
    }
  }

  void configureCaptureDeviceUnlink(Future<void> Function()? unlink) {
    _unlinkCaptureDevice = unlink;
  }

  /// P3: registers the synchronous taker of the sign-out unlink ticket (the
  /// capture service arms it when a Cloud-ON link is acknowledged). [take]
  /// returns the ticket's send, or null when nothing is linked.
  void configureCaptureUnlinkTicket(
      Future<void> Function()? Function()? take) {
    _takeCaptureUnlinkTicket = take;
  }

  Future<void> Function()? _localReminderClear;

  /// Registers the LOCAL-ONLY clear of the removed owner's scheduled and
  /// delivered OS notifications. Used by immediate deletion, which suppresses
  /// the owner-clear and remote unlink hooks but must not leave reminders.
  void configureLocalReminderClear(Future<void> Function()? clear) {
    _localReminderClear = clear;
  }

  /// After a confirmed immediate-deletion local removal of [target]: clears the
  /// OS reminders and signs the deleted owner's SDK session out of THIS device.
  /// Local scope; with Cloud OFF the gated client sends nothing, and a denied
  /// logout request is swallowed. A session of another uid is never touched.
  ///
  /// The reminder clear is device-wide, so it and the sign-out run only while
  /// [stillCurrent] holds: a successor admitted meanwhile keeps its own.
  Future<void> _clearRemovedOwnerDeviceResidue(String target,
      {required bool Function() stillCurrent}) async {
    final clear = _localReminderClear;
    if (clear != null && stillCurrent()) {
      try {
        await clear().timeout(const Duration(seconds: 4));
      } catch (_) {}
    }
    if (!stillCurrent()) return;
    final client = _databaseIssuerClient ?? _clientForConsent();
    if (client == null || client.auth.currentSession?.user.id != target) return;
    try {
      // ASR §4.9: with a coordinator the removal is durable (store tombstone)
      // before the same server revocation `signOut(local)` sends.
      await (AuthCoordinator.active != null
              ? AuthCoordinator.logout(client.auth)
              : client.auth.signOut(scope: supabase.SignOutScope.local))
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// WP-3b: wires the per-uid replica layer. Sign-out then LOCKS the active
  /// replica instead of wiping it, and an admitted uid unlocks and opens its own.
  void configureAccountScope(AccountScopeControl? scope) {
    if (!identical(_accountScope, scope)) {
      _revokeDatabasePublication(authenticationLoss: false);
    }
    _accountScope = scope;
  }

  /// WP-3b: wires the §4.4 Remove-data flow (see [removeDataFromDevice]).
  void configureRemoveData(RemoveDataFlow? flow) {
    _removeData = flow;
  }

  /// دفعة أخيرة للـ outbox قبل مسح تسجيل الخروج — التغييرات الأخيرة (مثلاً
  /// تغيير الدولة قبل الخروج بثوانٍ) كانت تُمسح من الطابور قبل رفعها فتضيع
  /// نهائياً. best-effort: فشلها (أوفلاين) لا يمنع تسجيل الخروج.
  void configureSignOutFlush(Future<void> Function()? flush) {
    _flushPendingSync = flush;
  }

  /// Registers the native/filesystem residue purge (MALI-054n/070n). See
  /// [_captureOwnerClear]. Wired by bootstrap to the capture bridge + pending
  /// actions file.
  void configureCaptureOwnerClear(Future<bool> Function()? atTransition,
      {Future<bool> Function()? atSignOut}) {
    _captureOwnerClear = atTransition;
    _captureOwnerClearAtSignOut = atSignOut;
  }

  void configureCaptureOwnerPublish(
      Future<void> Function(String uid, AdmissionAuthority authority)?
          publish) {
    _publishCaptureOwner = publish;
  }

  /// Runs the injected residue purge. Returns false (cannot confirm) when the
  /// hook is not yet registered or the purge throws/reports failure — callers
  /// at identity-admission boundaries MUST treat false as "residue may remain"
  /// and fail closed.
  Future<bool> _runOwnerClear({bool signOut = false}) async {
    final purge = signOut
        ? (_captureOwnerClearAtSignOut ?? _captureOwnerClear)
        : _captureOwnerClear;
    if (purge == null) return false;
    // The outgoing lifetime's fence reaches native BEFORE the owner is cleared:
    // a cleared owner would otherwise turn it into a mismatch.
    if (_nativeJobs > 0) await _nativeTail;
    try {
      return await purge();
    } catch (_) {
      return false;
    }
  }

  /// آخر هوية Supabase مُؤكَّدة أنها "تملك" البيانات المالية المحلية الحالية
  /// — طبقة حماية إضافية (دفاع في العمق) تستخدمها خدمات الترحيل (backfill)
  /// لرفض رفع صفوف محلية قد تخصّ مستخدماً سابقاً لم يُمسح بياناته فعلياً
  /// (مثلاً بسبب إغلاق التطبيق أثناء مسح جزئي). `null` تعني "لا تعارض معروف"
  /// وليست إذناً غير مشروط — الترحيل يسمح بها فقط لتوافق التركيبات القديمة.
  Future<String?> readLocalDataOwnerUid() =>
      _storage.read(key: _kLocalDataOwnerUid);

  /// Writes [value] to the owner marker and reads it back. True ONLY when the
  /// read-back equals [value].
  ///
  /// Always writes — never gated on the prior read. On iOS the plugin's
  /// `delete` filters on kSecAttrAccessible while `read` does not, so an owner
  /// marker written by an older build survives `delete` silently and keeps
  /// reading back as the previous uid (proven on a real keychain). Its `write`
  /// path does repair such an item. The read-back is the only evidence that
  /// counts; a claim that is not verified must never be reported as success.
  Future<bool> _writeOwnerMarkerVerified(
    String value,
    AdmissionAuthority authority,
  ) async {
    try {
      authority.requireFor(value);
      try {
        await _storage.write(key: _kLocalDataOwnerUid, value: value);
      } on PlatformException catch (e) {
        if (e.code != '-25299') return false;
        authority.requireFor(value);
        await _storage.delete(key: _kLocalDataOwnerUid);
        authority.requireFor(value);
        await _storage.write(key: _kLocalDataOwnerUid, value: value);
      }
      authority.requireFor(value);
      return await _storage.read(key: _kLocalDataOwnerUid) == value;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// Records [uid] as unresolved for this process and reports it.
  LocalDataOwnership _markOwnershipUnresolved(String uid) {
    _unresolvedOwnerUid = uid;
    return LocalDataOwnership.unresolved;
  }

  /// Writes a fresh cryptographically-random admission generation iff none is
  /// currently stored.
  Future<void> _mintOwnerGenerationIfAbsent([_Admission? adm]) async {
    _accountFenceOwner = null;
    var generation = await _storage.read(key: _kLocalDataOwnerGeneration);
    if (adm != null && !adm.current) return;
    if (generation == null) {
      generation = _newOwnerGeneration();
      await _storage.write(key: _kLocalDataOwnerGeneration, value: generation);
      if (adm != null && !adm.current) return;
      if (await _storage.read(key: _kLocalDataOwnerGeneration) != generation) return;
    }
    if (adm != null && adm.current && generation.isNotEmpty) {
      _accountFenceOwner = (adm.uid, generation, adm.authority.epoch);
    }
  }

  Future<void> _invalidateOwnerGeneration({_Admission? incoming}) async {
    // The actual private explicit turn already retired the outgoing issuer
    // before its first await. Its own metadata rotation is not another loss of
    // the incoming lifetime. External/sign-out/removal callers never supply it.
    // A genuine loss still advances the independent publication generation and
    // remains denied; nothing here clears that denial or recaptures generation.
    if (incoming == null ||
        !identical(incoming, _databaseOpeningAdmission) ||
        !incoming.explicit ||
        !incoming.current ||
        _explicitAdmissionEpoch != incoming.authority.epoch) {
      _revokeDatabasePublication();
    }
    _accountFenceOwner = null;
    await _storage.delete(key: _kLocalDataOwnerGeneration);
  }

  static String _newOwnerGeneration() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Serialised entry point for every ownership reconcile. See
  /// [_ownershipTail] and [_resolveLocalDataOwnership].
  Future<LocalDataOwnership> _ensureLocalDataOwnedBy(
    String uid, [
    _Admission? admission,
  ]) {
    // Automatic callers (auth events, resume, bootstrap) hold an open-existing
    // authority captured NOW; only setIdentity passes an explicit one.
    final adm = admission ??
        _Admission(uid, _authorityAt(_admissionEpoch, uid, canCreate: false));
    final run = _ownershipTail.then(
      (_) => _resolveLocalDataOwnership(uid, adm),
    );
    _ownershipTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Admits [uid] BEFORE the session is shown (MALI-002): the owner marker names
  /// [uid] (read back), and its own replica is the open database.
  ///
  /// WP-3b: there is no wipe. Each uid has its own encrypted replica, so a marker
  /// that names ANOTHER uid (the previous owner's session ended without a
  /// sign-out: expiry, revocation, crash) is not a conflict over rows. The
  /// previous owner's replica is simply locked and left untouched, and [uid]
  /// gets or creates its own. What still has to be cleared is device-wide native
  /// residue that is not stamped with an owner, and that is purged BEFORE the
  /// claim and fails closed (MALI-054n): an unconfirmed purge never admits.
  ///
  /// INVARIANT: if ownership is unresolved, preserve local data and deny
  /// access. Admission ([owned]) only after the new owner has been READ BACK from
  /// the marker. A database nobody provably owns is never adopted by whoever
  /// signs in next (B4): such a file is quarantined by the replica layer.
  ///
  /// If the purge hook is not registered (first reconcile runs before bootstrap
  /// registers it), nothing is attempted for a changed owner: the conflict is
  /// recorded and [LocalDataOwnership.deferred] returned until
  /// [resolvePendingLocalDataOwnerConflict] runs.
  Future<LocalDataOwnership> _resolveLocalDataOwnership(
    String uid,
    _Admission adm,
  ) async {
    // An automatic account switch closed capture when it was accepted
    // ([_switchAccount]). The ownership result does NOT reopen it: the identity
    // writes and the status publication that follow are still async, and local
    // work in a not-yet-published account must stay closed. Only the actual,
    // current publication of the very same epoch reopens it (see the publication
    // closures); a failed or older one leaves it closed, and a logout or removal
    // resets it.
    return _resolveLocalDataOwnershipInner(uid, adm);
  }

  Future<LocalDataOwnership> _resolveLocalDataOwnershipInner(
    String uid,
    _Admission adm,
  ) async {
    if (!adm.current || (!adm.explicit && _explicitAdmissionEpoch != null)) {
      return LocalDataOwnership.revoked;
    }
    // After a FAILED logout no automatic path may restore the old authority; only
    // an explicit, successful admission recovers.
    if (!adm.explicit && _logoutIncomplete) return LocalDataOwnership.revoked;
    try {
      await _accountFence.guard(uid, current: () => adm.current);
    } on AccountFenceDeniedException {
      return LocalDataOwnership.revoked;
    }
    final removal = _removeData;
    // ASR Phase 4c B1: the adoption never runs removal recovery or any other
    // generic maintenance. A removal running, pending or completed for this uid
    // is a refusal (its strict storage probe re-reads the barrier and the
    // revoked set inside the admission section); the barrier stays owned by the
    // removal workflow.
    if (adm.asrSuccessor) {
      if (removal?.isRunning ?? false) return LocalDataOwnership.revoked;
      try {
        return await _admissionOp(() => _resolveAsrAdmitted(uid, adm),
            current: () => adm.current);
      } on StaleAdmissionException {
        return LocalDataOwnership.revoked;
      }
    }
    if (removal != null) {
      // A removal this process is executing is NEVER waited on: it drains
      // admission work first, so waiting here would deadlock. It blocks admission.
      if (removal.isRunning) return LocalDataOwnership.revoked;
      // A removal a crash interrupted finishes BEFORE anyone is admitted: its
      // sweep would otherwise delete this uid's fresh captures (created after the
      // barrier). Completing it never authorizes the session that asked.
      if (!await removal.resumePending()) return _markOwnershipUnresolved(uid);
      if (!adm.current) return LocalDataOwnership.revoked;
      // `removed_requires_explicit_auth`: no automatic path admits this uid.
      try {
        adm.wasRevoked = (await removal.revokedUids()).contains(uid);
      } catch (_) {
        return _markOwnershipUnresolved(uid);
      }
      if (adm.wasRevoked && !adm.explicit) return LocalDataOwnership.revoked;
      if (!adm.current) return LocalDataOwnership.revoked;
    }
    final LocalDataOwnership outcome;
    try {
      outcome = await _admissionOp(() => _resolveAdmitted(uid, adm),
          current: () => adm.current);
    } on StaleAdmissionException {
      if (adm.explicit && adm.wasRevoked) await _rollbackFreshAdmission(adm);
      return LocalDataOwnership.revoked;
    } catch (_) {
      if (adm.explicit && adm.wasRevoked) await _rollbackFreshAdmission(adm);
      rethrow;
    }
    // A fresh admission of a removed uid is all-or-nothing: whatever stage
    // stopped it, what it already wrote (owner marker, generation, registry
    // entry, key, database) is removed again and the revocation stays in force.
    if (adm.explicit &&
        adm.wasRevoked &&
        outcome != LocalDataOwnership.owned &&
        outcome != LocalDataOwnership.deferred) {
      await _rollbackFreshAdmission(adm);
    }
    return outcome;
  }

  /// ASR §9.7 (Phase 4 B1): the adoption's restricted ownership step. It
  /// admits only the exact existing state local read was verified against —
  /// owner marker and owner generation confirmed by status-preserving reads,
  /// no unresolved or pending owner conflict, every §12 storage predicate
  /// (registry entry active and settled, no removal, fence, deletion or
  /// pending enable) re-confirmed — and opens that existing replica. It never
  /// claims, repairs, mints, migrates or switches: anything else refuses with
  /// the data untouched.
  Future<LocalDataOwnership> _resolveAsrAdmitted(
      String uid, _Admission adm) async {
    final keychain = AuthCoordinator.active?.store.keychain;
    final probe = _asrStorageDenial;
    if (keychain == null ||
        probe == null ||
        _pendingOwnerConflictUid != null ||
        _unresolvedOwnerUid != null) {
      return LocalDataOwnership.revoked;
    }
    final reads = AsrStrictReads(keychain);
    final String? marker;
    final String? generation;
    try {
      marker = await reads.read(_kLocalDataOwnerUid);
      generation = await reads.read(_kLocalDataOwnerGeneration);
      if (await probe(uid) != null) return LocalDataOwnership.revoked;
    } catch (_) {
      return LocalDataOwnership.revoked;
    }
    if (!adm.current ||
        marker != uid ||
        generation == null ||
        generation.isEmpty) {
      return LocalDataOwnership.revoked;
    }
    _accountFenceOwner = (uid, generation, adm.authority.epoch);
    return _admitReplica(uid, adm, publishOwner: true);
  }

  /// Undoes a failed fresh admission of [uid] through the same durable removal
  /// the user's Remove data uses (barrier, replica, key, registry, consent,
  /// native sweep). Runs OUTSIDE the admission operations it follows: the removal
  /// drains them. Best effort: if it cannot finish, its barrier is kept and
  /// resumes at the next launch or admission, which stay blocked meanwhile.
  Future<void> _rollbackFreshAdmission(_Admission adm) async {
    // A removal or a later admission owns a newer epoch. Its state and replica
    // must never be swept by this failed continuation.
    // Freshness can revoke admission while this lifecycle still owns its
    // partial writes. Cleanup needs lifecycle ownership, never fresh login
    // authority; a newer epoch or accepted removal still prevents this sweep.
    if (!_authorityAt(adm.authority.epoch, adm.uid, canCreate: false)
        .isCurrent) {
      return;
    }
    final removal = _removeData;
    if (removal == null) return;
    _removalsAccepted++;
    _admissionEpoch++;
    _localReadLifecycle++;
    _authLossSeq++;
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _admittedUid = null;
    _revokeConsentProof();
    _accountSwitchEpoch = null;
    value = SessionStatus.needsOnboarding;
    try {
      try {
        await removal.remove(adm.uid);
      } catch (_) {
        // The durable barrier remains; startup cannot admit until it completes.
      }
      await _finishSignedOut(releaseOwner: false);
    } finally {
      _removalsAccepted--;
    }
  }

  /// An AUTOMATIC admission is about to move the device to another account: every
  /// authority captured before the switch is stale from here, and the admission
  /// itself carries a fresh one. (An explicit sign-in advanced the epoch when it
  /// was accepted.)
  void _switchAccount(_Admission adm) {
    if (adm.explicit) return;
    _revokeDatabasePublication();
    _admissionEpoch++;
    final previous = _admittedUid;
    if (previous != null && previous != adm.uid) _localReadLifecycle++;
    adm.authority = _authorityAt(
      _admissionEpoch,
      adm.uid,
      canCreate: adm.authority.canCreate,
      sessionCurrent: adm.sessionCurrent,
    );
    // Capture closes with the same synchronous step, and the outgoing consent
    // proof is gone: nothing new may start on the account being left. The loss
    // generation is NOT advanced: this runs inside the very admission that goes on
    // to publish the new account, whose captured generation must stay valid. The
    // epoch move above already fences every other admission.
    _accountSwitchEpoch = _admissionEpoch;
    _consentCapability = null;
    // The outgoing native lifetime is fenced with the same synchronous step.
    _retireNativeLifetime();
  }

  Future<LocalDataOwnership> _resolveAdmitted(
    String uid,
    _Admission adm,
  ) async {
    if (adm.asrSuccessor) return _resolveAsrAdmitted(uid, adm);
    final String? existing;
    try {
      existing = await _storage.read(key: _kLocalDataOwnerUid);
    } catch (_) {
      return _markOwnershipUnresolved(uid);
    }
    if (!adm.current) return LocalDataOwnership.revoked;

    if (existing == uid) {
      // The read itself proves the marker is consistent. No write needed.
      _pendingOwnerConflictUid = null;
      _unresolvedOwnerUid = null;
      // MALI-069n §Blocker-1: mint a fresh admission generation ONLY when none
      // exists (a genuine (re-)admission — sign-out/ownership-change cleared
      // it). An idempotent reconcile of the SAME live session keeps its
      // generation, so its own in-flight background jobs stay valid; a real
      // re-login always sees the generation absent and rotates, rejecting the
      // previous session's jobs — even for the same UID.
      await _mintOwnerGenerationIfAbsent(adm);
      if (!adm.current) return LocalDataOwnership.revoked;
      // An idempotent reconcile of the same account publishes nothing again: it
      // would re-publish OFF over an already confirmed ON. An ASR adoption is
      // not idempotent: its lifetime was retired at expiry and SE1 is required.
      return _admitReplica(uid, adm, publishOwner: adm.asrSuccessor);
    }

    if (existing == null) {
      _pendingOwnerConflictUid = null;
      // Claiming a device nobody currently owns. Best-effort residue purge as
      // defense in depth (e.g. a prior reset whose purge failed): a genuinely
      // fresh install has nothing to purge, so this is a no-op and never blocks
      // first-run admission (the hook may not be registered this early).
      await _runOwnerClear();
      if (!adm.current) return LocalDataOwnership.revoked;
      if (!await _writeOwnerMarkerVerified(uid, adm.authority)) {
        return _markOwnershipUnresolved(uid);
      }
      if (!adm.current) return LocalDataOwnership.revoked;
      await _mintOwnerGenerationIfAbsent(adm);
      if (!adm.current) return LocalDataOwnership.revoked;
      _unresolvedOwnerUid = null;
      return _admitReplica(uid, adm);
    }

    // ANOTHER uid (or a leftover transition sentinel from an older build).
    if (_unresolvedOwnerUid == uid) {
      // Already failed in this process; do not retry on every auth event.
      return LocalDataOwnership.unresolved;
    }
    if (_captureOwnerClear == null) {
      _pendingOwnerConflictUid = uid;
      return LocalDataOwnership.deferred;
    }
    // The device is switching accounts: authorities captured for the previous one
    // are stale from here.
    if (!adm.current) return LocalDataOwnership.revoked;
    _switchAccount(adm);
    // MALI-069n §Blocker-1: invalidate the admission generation BEFORE anything
    // changes, so a background job from the previous owner is rejected and the
    // incoming owner mints a fresh generation on claim below.
    await _invalidateOwnerGeneration(incoming: adm);
    if (!adm.current) return LocalDataOwnership.revoked;

    // Purge first. The purge calls a native method channel that, under the
    // UIScene lifecycle, does not exist during `didFinishLaunchingWithOptions`
    // (Dart bootstrap runs inside that window), so it can fail transiently. A
    // failure is a safe stop: the marker still names the previous owner, nothing
    // was changed, and the next attempt redoes it.
    final residuePurged = await _runOwnerClear();
    if (!residuePurged) {
      _pendingOwnerConflictUid = uid;
      return _markOwnershipUnresolved(uid);
    }
    if (!adm.current) return LocalDataOwnership.revoked;

    if (!await _writeOwnerMarkerVerified(uid, adm.authority)) {
      _pendingOwnerConflictUid = uid;
      return _markOwnershipUnresolved(uid);
    }
    if (!adm.current) return LocalDataOwnership.revoked;
    await _mintOwnerGenerationIfAbsent(adm);
    if (!adm.current) return LocalDataOwnership.revoked;
    _pendingOwnerConflictUid = null;
    _unresolvedOwnerUid = null;
    return _admitReplica(uid, adm);
  }

  /// Unlocks and opens [uid]'s replica (locking the previously active uid's),
  /// once the scope layer exists. Before bootstrap has opened a database the
  /// marker is the whole admission and bootstrap opens the replica it names. A
  /// replica that cannot be opened is a safe stop (fail closed), never an
  /// adoption of someone else's file.
  Future<LocalDataOwnership> _admitReplica(String uid, _Admission adm,
      {bool publishOwner = true}) async {
    final scope = _accountScope;
    if (scope == null) {
      _admittedUid = uid;
      return LocalDataOwnership.owned;
    }
    if (!adm.current) return LocalDataOwnership.revoked;
    // The previous scope's bounded local operations (a consent write holding a
    // transaction on the database about to be closed or reused) settle FIRST:
    // only local work is drained, never this admission itself. Their authorities
    // were invalidated synchronously when this admission was accepted, so the
    // ones still running roll back at their next guard instead of landing.
    await _drainLocalOperations();
    if (!adm.current) return LocalDataOwnership.revoked;
    // O: the private single-opener reservation is minted HERE, inside this
    // admission turn, after the attempt / fresh SDK and removal / ownership
    // policy were validated and before the scope layer can open anything.
    var authority = adm.authority;
    final asrCause = adm.asrCause;
    if (asrCause != null) authority = authority.withCauseAuthority(asrCause);
    DatabaseOpenReservation? reservation;
    final coordinator = _databaseCoordinator;
    if (coordinator != null) {
      final lossAtMint = _databaseLossGeneration;
      try {
        // R7: the controlled path out of a quiescing state no transition owns
        // any more (a timed-out restoration). It acts only when every uncertain
        // holder has ACTUALLY closed and never opens writable access; otherwise
        // the reservation below is refused and ownership stays unresolved.
        coordinator.recoverFromQuiescing();
        reservation = coordinator.reserveAdmissionOpen(
          uid: uid,
          admissionIdentity: adm,
          lossGeneration: lossAtMint,
          stillValid: () =>
              adm.current && _databaseLossGeneration == lossAtMint,
        );
      } on DatabaseAccessUnavailable {
        return _markOwnershipUnresolved(uid);
      }
      authority = authority.withOpenReservation(reservation);
    }
    try {
      await scope.activate(uid, authority: authority);
    } on StaleAdmissionException {
      return LocalDataOwnership.revoked;
    } catch (_) {
      return _markOwnershipUnresolved(uid);
    }
    if (reservation != null && reservation.hasOpened) {
      _databaseOpenReservation = reservation;
    }
    if (!adm.current) return LocalDataOwnership.revoked;
    _admittedUid = uid;
    // Android: every admission (re)publishes the owner of the owner-scoped
    // capture queue, so new captures are stamped to this account and only its
    // captures are drained. Idempotent for the same account (an app update of a
    // signed-in user publishes it for the first time). Checked synchronously:
    // other platforms take no extra async step here.
    if (NativeCaptureBridge.hasOwnerScopedQueue &&
        !NativeCaptureBridge.hasNativeQueue) {
      await _publishOwnerScopedCaptureOwner(adm);
    }
    if (!adm.explicit && publishOwner) {
      // Awaited and bounded; a publication that did not verify leaves capture
      // unbound until the next admission, and never fails the admission.
      await _publishNativeLifetime(adm);
    }
    return LocalDataOwnership.owned;
  }

  /// Completes an owner conflict deferred by [_ensureLocalDataOwnedBy] once
  /// the purge hook exists (bootstrap calls this right after registering it,
  /// with the DB open). Purges the previous account's native residue, claims
  /// ownership for the pending UID and switches to its replica, then re-runs the
  /// session reconcile so the gated identity is finally admitted.
  /// A changed-owner purge is deferred, or an owner is latched unresolved. The
  /// headless cold-start drain does no work then (the foreground resolves it).
  bool get hasUnsettledLocalDataOwner =>
      _pendingOwnerConflictUid != null || _unresolvedOwnerUid != null;

  Future<void> resolvePendingLocalDataOwnerConflict(
    supabase.SupabaseClient client,
  ) async {
    if (_pendingOwnerConflictUid == null) return;
    if (_captureOwnerClear == null) return;
    await _reconcileSupabaseSession(client.auth.currentSession, client: client);
  }

  // ------------------------------------------------------ offline local read
  //
  // A second, independent authority: a device-local grant that lets the SAME
  // existing replica be VIEWED (SQLite read-only) when the SDK session is expired
  // or absent. It is never an admission: no write, no cloud, no capture.

  LocalReadAuthority? _localRead;
  LocalReadAuthority? _localReadStorageContinuity;

  /// Set by every restrictive event (logout, removal, known revocation, an
  /// unknown signedOut/auth_required). Cleared only by a fresh explicit
  /// admission. While set, no local-read restoration is attempted.
  bool _localReadLocked = false;

  /// O-LC-1a: advanced by every event that starts an independent lifecycle
  /// (explicit admission, sign-out, removal, an automatic switch of account).
  int _localReadLifecycle = 0;

  /// Test-only: whether the process-wide local-read lock is set.
  @visibleForTesting
  bool get debugLocalReadLocked => _localReadLocked;

  /// Test-only: models an independent successor lifecycle that has begun but
  /// not yet replaced the published scope.
  @visibleForTesting
  void debugBeginSuccessorLifecycle() => _localReadLifecycle++;
  bool _localReadCleanupIncomplete = false;

  /// O8-3: operations whose bound denial is not durable yet (operationId ->
  /// uid). Held by the session so a supported replacement of the authority
  /// ([configureLocalRead]) does not forget them; retried per operation only.
  final Map<String, String> _outstandingOperationDenials = {};
  _LocalReadHostProof? _localReadProof;
  _LocalReadHostProof? _localReadHandoffProof;
  _GrantProof? _pendingFirstGrant;
  Future<void> _localReadTail = Future<void>.value();
  AccountScopeHost? _localReadHostListening;

  void configureLocalRead(LocalReadAuthority? authority) {
    final outgoing = _localRead;
    final proof = _localReadProof;
    // Share the denial ledger before replacement, including an operation whose
    // queued durable write has not returned yet. Its eventual completion then
    // updates the same ledger that the replacement consults.
    _localRead?.adoptPendingOperationDenials(_outstandingOperationDenials);
    if (authority != null) {
      final previous = _localReadStorageContinuity;
      if (previous != null) authority.takeOverStorageOrdering(previous);
      authority.adoptPendingOperationDenials(_outstandingOperationDenials);
      _localReadStorageContinuity = authority;
    } else {
      _localRead?.releaseStorageSelection();
    }
    _localRead = authority;
    if (!identical(outgoing, authority) && proof != null &&
        identical(proof.host.current, proof.scope) &&
        proof.scope.database.lifecycleState != DatabaseLifecycleState.closed) {
      // Retiring authority does not withdraw its published physical scope.
      // Keep its exact identity for same-host re-verification and keep every
      // ordinary presentation/egress path restrictive until close completes.
      _localReadHandoffProof = proof;
      CloudEgressGate.instance.advanceEpoch(EpochCause.localRead);
      notifyListeners();
    }
  }

  /// True only while a verified local-read scope is the published one AND its
  /// grant is the live one AND no admission, logout or removal has begun.
  bool get localReadActive {
    final proof = _localReadProof;
    if (proof == null) return false;
    final ok = !_localReadLocked &&
        proof.capability.isCurrent &&
        identical(proof.host.current, proof.scope) &&
        proof.scope.database.lifecycleState == DatabaseLifecycleState.open &&
        _explicitAdmissionEpoch == null &&
        !_admissionClosed &&
        !(_removeData?.isRunning ?? false);
    return ok;
  }

  /// A durable denial could not be established. UID-wide denials retain the
  /// process lock; an operation denial refuses only its own grant.
  bool get localReadCleanupIncomplete =>
      _localReadCleanupIncomplete || _outstandingOperationDenials.isNotEmpty;

  /// D6: whether the one egress gate must admit only an account-control
  /// exchange: from the moment a local-read restoration holds its exclusion until
  /// no verified local-read scope is published any more. A saved Cloud/AI ON
  /// record changes nothing about this.
  bool get localReadPresentationRestricted {
    final host = _accountScope;
    return localReadTransitionPending ||
        _localReadEgressHold ||
        (_localReadHandoffProof != null &&
            _localReadHandoffProof!.scope.database.lifecycleState !=
                DatabaseLifecycleState.closed) ||
        (host is AccountScopeHost && (host.current?.isLocalRead ?? false)) ||
        (_localReadHostListening?.current?.isLocalRead ?? false);
  }

  bool get localReadEgressDenied =>
      localReadPresentationRestricted || localReadActive;
  bool _localReadEgressHold = false;

  // Presentation only: no replica, session or egress authority is issued by
  // this ticket. Keep the router on the branded recovery shell BEFORE the
  // synchronous expiry notification, until the existing grant is verified.
  Object? _localReadTransition;
  bool get localReadTransitionPending => _localReadTransition != null;

  /// Test-only: detaches the auth-stream subscription and the issuer client, so
  /// the next [bindSupabaseAuth] listens to ITS client (the singleton otherwise
  /// keeps the first client of the process).
  @visibleForTesting
  Future<void> debugResetAuthBinding() async {
    await _supabaseAuthSubscription?.cancel();
    _supabaseAuthSubscription = null;
    _databaseIssuerClient = null;
    _databaseHostAdmission = null;
  }

  /// Completes when no in-process local-read transition is pending (tests).
  @visibleForTesting
  Future<void> get debugLocalReadIdle => _localReadTail;

  Future<T> _localReadSerial<T>(Future<T> Function() f) {
    final run = _localReadTail.then((_) => f());
    _localReadTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  void _onLocalReadHostChanged() {
    if (_localReadHandoffProof?.scope.database.lifecycleState ==
        DatabaseLifecycleState.closed) {
      _localReadHandoffProof = null;
    }
    if (_localReadProof != null && !localReadActive) {
      _localReadProof = null;
      notifyListeners();
    }
  }

  void _dropLocalReadProof() {
    if (_localReadProof == null) return;
    _localReadProof = null;
    notifyListeners();
  }

  /// Restores the account's own replica READ-ONLY from its committed grant.
  ///
  /// Phase one validates the grant, the durable deny/removal/registry evidence
  /// and the existing resources; phase two reserves a read-only candidate open
  /// with the coordinator, opens it, verifies the decrypted owner/replica/schema
  /// and the final grant/lifecycle, and only then publishes. Nothing is created,
  /// repaired, migrated, written or sent; every loser is tracked and closed.
  ///
  /// When [host] currently holds a writable scope of the same uid (an in-process
  /// expiry) that scope is first drained and closed, never flipped. Returns
  /// whether a local-read scope is now published.
  ///
  /// [provenanceIntact] (R10.1) is the startup provenance fence: while it returns
  /// false (an authentication loss was observed during SDK initialization, or the
  /// persisted state's provenance is unknown) nothing may be published. It is
  /// consulted wherever the restoration validates itself, including as part of
  /// the candidate reservation's own currency and in the very check that
  /// precedes publication (no await in between), so a loss at any await of the
  /// restoration ends in zero publication rather than a later correction.
  Future<bool> restoreLocalReadAccess({
    AccountScopeHost? host,
    bool Function()? provenanceIntact,
    LocalReadStartupBinding? binding,
  }) =>
      _localReadSerial(() => _restoreLocalReadAccess(host,
          provenanceIntact: provenanceIntact, binding: binding));

  /// O-LC-1a: captures the identity of the startup that is beginning (its
  /// lifecycle, and the grant operation it will act on) BEFORE any SDK
  /// initialization can classify anything.
  Future<LocalReadStartupBinding> beginLocalReadStartupBinding() async {
    final lifecycle = _localReadLifecycle;
    LocalReadGrantRecord? record;
    try {
      record = await _localRead?.peekRecord();
    } catch (_) {
      record = null;
    }
    // O8-1: a lifecycle that began while the record was being read may have
    // written the very record that came back; it is then NOT this startup's.
    // Refuse the target (the binding keeps the old lifecycle, so a late
    // classification retracts only this startup's own scope).
    if (_localReadLifecycle != lifecycle) record = null;
    return LocalReadStartupBinding._(
        lifecycle, record?.operationId, record?.uid);
  }

  /// Test-only: awaited at the named awaits of a restoration ('record_read',
  /// 'exclusion_drained', 'restore_returned'), so a test can deliver an event at
  /// exactly that point. Grants nothing.
  @visibleForTesting
  Future<void> Function(String point)? debugLocalReadAwaitPoint;

  Future<bool> _restoreLocalReadAccess(AccountScopeHost? hostArg,
      {_FailedAttemptBinding? failedAttempt,
      bool Function()? provenanceIntact,
      LocalReadStartupBinding? binding}) async {
    bool denied(String reason) {
      // Local Beta 1 evidence only. Call sites pass constants or enum names,
      // never an owner, replica, credential or exception message.
      AuthDiagnostics.add('local_read_restore $reason');
      return false;
    }
    final afterFailedReconnect = failedAttempt != null;
    final auth = _localRead;
    final host = hostArg ?? (_accountScope is AccountScopeHost
        ? _accountScope as AccountScopeHost
        : null);
    if (auth == null || host == null) return denied('unwired');
    bool blocked() =>
        _localReadLocked ||
        _explicitAdmissionEpoch != null ||
        _admissionClosed ||
        (_removeData?.isRunning ?? false);
    if (blocked()) return denied('process_blocked');
    if (localReadActive) return true;
    final epoch = _admissionEpoch;
    String? fencedUid;
    // R10.1: startup provenance is part of validity everywhere the restoration
    // validates itself; the candidate reservation carries this same predicate, so
    // the publication check (no await before the scope is installed) rejects a
    // loss that arrived at any earlier await.
    bool stillValid() =>
        !blocked() &&
        identical(_localRead, auth) &&
        _admissionEpoch == epoch &&
        (fencedUid == null || _accountFence.permits(fencedUid)) &&
        (provenanceIntact?.call() ?? true);
    if (!stillValid()) return denied('not_current');

    // B1/C1: no coordinator, no local read. The exclusion below is the only
    // source of a candidate reservation.
    final coordinator = _databaseCoordinator;
    if (coordinator == null ||
        !identical(host.localReadCoordinator, coordinator)) {
      return denied('coordinator');
    }

    // D3: a recovery queued by a FAILED reconnect is bound to that attempt: it
    // may act only on exactly the state the failure left (same admission epoch,
    // same published scope). Anything newer was admitted independently and is
    // never downgraded; the same uid is not proof of current write authority.
    bool attemptStillBound() =>
        failedAttempt == null ||
        failedAttempt.holds(_admissionEpoch, host.current);
    if (!attemptStillBound()) return denied('attempt_superseded');

    final LocalReadGrantRecord? record;
    try {
      record = await auth.peekRecord();
    } catch (_) {
      return denied('grant_unreadable');
    }
    if (record == null || record.state != LocalReadGrantState.committed) {
      return denied('grant_absent_or_uncommitted');
    }
    try {
      await _accountFence.guard(record.uid, current: stillValid);
    } on AccountFenceDeniedException {
      return denied('fence');
    } on StaleAdmissionException {
      return denied('fence_superseded');
    }
    fencedUid = record.uid;
    // O8-3: a record whose own denial is still outstanding is not a grant; refuse
    // before the writable scope is touched (the authority refuses it again).
    if (auth.pendingOperationDenials.containsKey(record.operationId)) {
      return denied('operation_denial');
    }
    await debugLocalReadAwaitPoint?.call('record_read');
    if (!stillValid() || !attemptStillBound()) {
      return denied('record_superseded');
    }
    final current = host.current;
    if (current != null) {
      // Only the SAME uid's writable scope is replaced; any other scope (the
      // signed-out one, another uid's) is none of this restoration's business.
      // After a failed reconnect the retired local-read scope (same uid) or the
      // signed-out one the failed switch left behind is replaced too.
      final staleAfterFailure = afterFailedReconnect &&
          ((current.isLocalRead && current.uid == record.uid) ||
              current.uid == null);
      final handoff = _localReadHandoffProof;
      final staleAfterHandoff = handoff != null &&
          identical(handoff.host, host) &&
          identical(handoff.scope, current) &&
          current.isLocalRead &&
          !handoff.capability.isCurrent &&
          current.uid == record.uid &&
          handoff.capability.operationId == record.operationId;
      if (!staleAfterFailure && !staleAfterHandoff &&
          (current.isLocalRead || current.uid != record.uid)) {
        return denied('scope_mismatch');
      }
      _localReadTransitionFence = true;
      await drainAdmissions();
      if (!stillValid() || !attemptStillBound()) {
        _localReadTransitionFence = false;
        return denied('drain_superseded');
      }
    } else if (host.swapInProgress) {
      return denied('scope_swap');
    }

    // B2: ONE atomic quiescing transition. From here every old job, reservation
    // and opener is stale and every incompatible reservation is refused. The
    // fence is retained through the drain, the candidate open, the decrypted
    // verification and publication, and released only afterwards.
    final DatabaseLocalReadExclusion exclusion;
    try {
      exclusion = coordinator.beginLocalReadExclusion();
    } on DatabaseAccessUnavailable {
      _localReadTransitionFence = false;
      return denied('exclusion');
    }
    var suspended = false;
    AccountScope? published;
    // D6: egress is refused from the moment the writable scope starts to be
    // suspended; anything admitted before is discarded (epoch) once published.
    _localReadEgressHold = true;
    _localReadTransitionFence = false;
    try {
      if (current != null) {
        _revokeConsentProof();
        await host.suspendForLocalRead();
        suspended = true;
        if (identical(_localReadHandoffProof?.scope, current)) {
          _localReadHandoffProof = null;
        }
      }
      // Pending opens and every physical handle (including secondaries other
      // isolates registered) must be ACTUALLY closed and acknowledged. A timeout
      // or failed close denies; nothing is published.
      await exclusion.awaitDrained(timeout: debugLocalReadDrainTimeout);
      await debugLocalReadAwaitPoint?.call('exclusion_drained');
      if (!stillValid()) throw const StaleLocalReadException();
      final verified = await auth.restore(
        host.store,
        reserve: host.localReadReserver(
            exclusion: exclusion, stillValid: stillValid),
        verifyExclusion: (location) => exclusion.verifyLegacyHolders(
            LegacyHolderEvidence.inspect(
                replicaDirectory: location.directory,
                leaseDir: location.leaseDir,
                intentPath: location.maintPath)),
      );
      await debugLocalReadAwaitPoint?.call('restore_returned');
      if (verified.isGranted) {
        published = await host.restoreLocalRead(verified, stillValid: stillValid);
      } else {
        AuthDiagnostics.add('local_read_restore authority_'
            '${verified.denial?.name ?? 'unknown'}/'
            '${verified.replicaDenial?.name ?? 'none'}');
      }
    } on StaleLocalReadException {
      AuthDiagnostics.add('local_read_restore stale_open');
      published = null;
    } catch (_) {
      AuthDiagnostics.add('local_read_restore open_exception');
      published = null;
    } finally {
      exclusion.release(published: published != null);
    }
    if (published == null) {
      _localReadEgressHold = false;
      if (suspended) await host.ensureScopePublished();
      return denied('not_published');
    }
    if (!identical(_localReadHostListening, host)) {
      _localReadHostListening?.removeListener(_onLocalReadHostChanged);
      host.addListener(_onLocalReadHostChanged);
      _localReadHostListening = host;
    }
    _localReadProof =
        _LocalReadHostProof(published.localReadCapability!, published, host);
    binding?._proof = _localReadProof;
    _localReadEgressHold = false;
    // D6: whatever was admitted for the writable session is now stale, and the
    // gate's synchronous mirror (auto-refresh, diagnostics, images) re-reads.
    CloudEgressGate.instance.advanceEpoch(EpochCause.localRead);
    unawaited(CloudEgressGate.instance.refresh().catchError((Object _) {}));
    notifyListeners();
    AuthDiagnostics.add('local_read_restore granted');
    return true;
  }

  /// Fires the in-process writable-to-local-read transition for an expired or
  /// absent SDK. Only when a committed grant of the current uid exists.
  void _scheduleLocalReadTransition() {
    if (_localRead == null || _localReadLocked || localReadActive ||
        localReadTransitionPending) {
      return;
    }
    final ticket = Object();
    final epoch = _admissionEpoch;
    final authority = _localRead;
    _localReadTransition = ticket;
    unawaited(_localReadSerial(() async {
      try {
        if (_admissionEpoch == epoch && identical(_localRead, authority)) {
          await _restoreLocalReadAccess(null);
        }
      } finally {
        if (identical(_localReadTransition, ticket)) {
          _localReadTransition = null;
          notifyListeners();
        }
      }
    }).then<void>((_) {}, onError: (Object _) {}));
    notifyListeners();
  }

  /// Test-only: models a queued failure recovery that starts LATE (the serial
  /// lane was busy). Awaited at the start of that lane item; grants nothing.
  @visibleForTesting
  Future<void> Function()? debugFailureRecoveryGate;

  /// Test-only: runs inside a failed reconnect's catch BEFORE its failure
  /// recovery is captured, modelling a successor admission that arrives in the
  /// gap between the failure and its capture. Grants nothing.
  @visibleForTesting
  Future<void> Function()? debugBeforeFailureCapture;

  void _scheduleFreshLocalReadRestore(_ReconnectProbe attempt) {
    if (_localRead == null || _localReadLocked) return;
    // R10.2: the recovery belongs to THIS failed attempt. If any successor has
    // already superseded it (every admission, sign-out and removal advances the
    // epoch), the state now visible is the successor's, not what this attempt
    // left behind: decline instead of binding to it. A successor arriving after
    // this point is caught by the binding's own check when the lane runs.
    final epoch = attempt.epoch;
    if (epoch == null || _admissionEpoch != epoch) return;
    final accountScope = _accountScope;
    final bound = _FailedAttemptBinding(
        epoch, accountScope is AccountScopeHost ? accountScope.current : null);
    unawaited(_localReadSerial(() async {
      await debugFailureRecoveryGate?.call();
      return _restoreLocalReadAccess(null, failedAttempt: bound);
    }).then<void>((_) {}, onError: (Object _) {}));
  }

  /// Lock + durable deny (logout, removal, known loss, unknown loss). Everything
  /// in memory happens before the first await: the host proof is dropped, the
  /// restrictive flag set and issuance cancelled. Then the core queues its
  /// durable denial; a failed one is reported, never invented.
  /// D2: a `signedOut`/`userDeleted` was observed while the SDK was
  /// initializing, before this session bound to its stream. The resulting
  /// null/expired session is a loss of unknown cause: lock and durably deny
  /// (never restore). [host] is the launch's account-scope host (not configured
  /// on this session yet at that point).
  ///
  /// O-LC-1a: with a [binding] (late classifications from a startup's SDK
  /// recovery) the denial is bound to that startup. While no independent
  /// lifecycle (explicit admission, sign-out, removal, account switch) has begun
  /// since, it is the full process lock above. Afterwards it retracts only what
  /// that startup derived (its published local-read scope and its stored grant
  /// operation) and never selects, locks or revokes whatever is now current.
  Future<void> denyLocalReadAfterInitializationLoss(AccountScopeHost host,
          {LocalReadStartupBinding? binding}) =>
      _denyLocalRead(hostOverride: host, binding: binding);

  /// Records the outcome of one operation-specific denial: a durable one clears
  /// the operation, an incomplete one is kept (and reported) until a retry lands.
  void _noteOperationDenial(
      String operationId, String uid, LocalReadRevocation result) {
    if (result.isDurable) {
      _outstandingOperationDenials.remove(operationId);
    } else {
      _outstandingOperationDenials[operationId] = uid;
    }
  }

  Future<void> _denyOriginatingLocalRead(
      LocalReadStartupBinding binding, AccountScopeHost? hostOverride) async {
    final proof = binding._proof;
    if (proof != null && identical(_localReadProof, proof)) {
      _dropLocalReadProof();
    }
    final auth = _localRead;
    if (auth == null) return;
    final host = hostOverride ?? proof?.host;
    final opId = binding.operationId;
    final opUid = binding.uid;
    // O8-2: what the registry fallback may lock is judged when it EXECUTES
    // (inside the authority's queue), not only when it was requested: any
    // lifecycle that began meanwhile, or a uid a successor now holds, refuses.
    final requestedLifecycle = _localReadLifecycle;
    Future<bool> Function()? fallback(String uid) {
      if (host == null) return null;
      bool successorHolds() =>
          _localReadLifecycle != requestedLifecycle ||
          (binding._lifecycle != requestedLifecycle &&
              {_admittedUid, _accountScope?.activeUid, host.activeUid}
                  .contains(uid));
      if (successorHolds()) return null;
      return () async {
        if (successorHolds()) return false;
        return host.store.lockVerified(uid,
            stillValid: () => !successorHolds());
      };
    }

    Future<LocalReadRevocation>? revocation;
    if (opId != null && opUid != null) {
      revocation = auth.revokeOperation(
        operationId: opId,
        uid: opUid,
        lockRegistry: fallback(opUid),
      );
    }
    try {
      // O8-2: the lock is queued for exactly the scope this startup published;
      // it re-checks that scope when its own turn starts.
      if (proof != null && host != null && identical(host.current, proof.scope)) {
        await host.lockIfCurrent(proof.scope);
      }
    } catch (_) {
      // Best effort: the scope is not published any more or the lock failed.
    }
    if (revocation != null) {
      LocalReadRevocation result;
      try {
        result = await revocation;
      } catch (_) {
        result = LocalReadRevocation.incomplete;
      }
      // O8-3: an incomplete denial is never ignored: it stays pending in the
      // authority, is reported through the notice state, and keeps a reachable
      // operation-specific retry ([retryLocalReadDeny]).
      _noteOperationDenial(opId!, opUid!, result);
      if (!result.isDurable) {
        denyIncompleteNoticePending.value = true;
        notifyListeners();
      }
    }
  }

  Future<void> _denyLocalRead(
      {String? uid,
      bool lockScope = true,
      AccountScopeHost? hostOverride,
      LocalReadStartupBinding? binding}) async {
    if (binding != null) {
      // The process lock belongs to the still-current startup, but even its
      // durable mutation is bound to the captured operation. A successor may
      // begin after this check while the authority's mutation read is pending.
      if (binding._lifecycle == _localReadLifecycle) {
        _localReadLocked = true;
        _pendingFirstGrant = null;
      }
      return _denyOriginatingLocalRead(binding, hostOverride);
    }
    _localReadLocked = true;
    _pendingFirstGrant = null;
    final proof = _localReadProof;
    final auth = _localRead;
    _dropLocalReadProof();
    if (auth == null) return;
    final host = hostOverride ??
        (_accountScope is AccountScopeHost
            ? _accountScope as AccountScopeHost
            : proof?.host);
    final uids = <String>{
      ...[uid, proof?.scope.uid, _admittedUid, _accountScope?.activeUid]
          .whereType<String>()
          .where((u) => u.isNotEmpty),
    };
    try {
      if (uids.isEmpty) {
        final stored = await auth.peekRecord();
        if (stored != null) uids.add(stored.uid);
      }
      final results = [
        for (final id in uids)
          auth.revoke(
            uid: id,
            lockRegistry: host == null ? null : () => host.store.lockVerified(id),
          ),
      ];
      if (lockScope && host != null && (host.current?.isLocalRead ?? false)) {
        await host.lock();
      }
      var incomplete = false;
      for (final r in results) {
        if (!(await r).isDurable) incomplete = true;
      }
      _localReadCleanupIncomplete = incomplete;
    } catch (_) {
      _localReadCleanupIncomplete = true;
    }
  }

  /// Re-runs ONLY the durable deny for every uid whose denial is still pending
  /// (the secure `blocked` record, falling back to a verified registry lock). It
  /// deletes no key, wipes no data and touches no scope. Returns true once the
  /// denial is durable; the process stays locked either way.
  Future<bool> retryLocalReadDeny() async {
    final auth = _localRead;
    if (auth == null) return !localReadCleanupIncomplete;
    final host =
        _accountScope is AccountScopeHost ? _accountScope as AccountScopeHost : null;
    try {
      final uids = {...auth.pendingDenialUids};
      // O8-3: the stored-record lookup answers ONLY an unknown-uid uid-wide
      // denial. An outstanding operation denial is retried per operation below
      // and must never make the lookup pick whatever record is stored now (a
      // successor's) for a uid-wide revocation.
      if (uids.isEmpty && _localReadCleanupIncomplete) {
        final stored = await auth.peekRecord();
        if (stored != null) uids.add(stored.uid);
      }
      var uidIncomplete = false;
      for (final uid in uids) {
        final result = await auth.revoke(
          uid: uid,
          lockRegistry: host == null ? null : () => host.store.lockVerified(uid),
        );
        if (!result.isDurable) uidIncomplete = true;
      }
      _localReadCleanupIncomplete = uidIncomplete;
    } catch (_) {
      _localReadCleanupIncomplete = true;
    }
    for (final entry in auth.pendingOperationDenials.entries.toList()) {
      var result = LocalReadRevocation.incomplete;
      try {
        result = await auth.revokeOperation(
          operationId: entry.key,
          uid: entry.value,
          lockRegistry: null,
        );
      } catch (_) {}
      _noteOperationDenial(entry.key, entry.value, result);
    }
    notifyListeners();
    return !localReadCleanupIncomplete;
  }

  bool _grantProofCurrent(_GrantProof p) {
    final sdk = p.client.auth.currentSession;
    final host = _accountScope;
    return !_localReadLocked &&
        identical(_databaseIssuerClient, p.client) &&
        host is AccountScopeHost &&
        identical(host.current, p.scope) &&
        !p.scope.isLocalRead &&
        !_admissionClosed &&
        !(_removeData?.isRunning ?? false) &&
        _explicitAdmissionEpoch == null &&
        _admissionEpoch == p.epoch &&
        _databaseLossGeneration == p.loss &&
        !_databasePublicationDenied &&
        _admittedUid == p.uid &&
        !isGuest &&
        sdk != null &&
        !sdk.isExpired &&
        sdk.user.id == p.uid;
  }

  /// Persists the committed receipt for a genuine fresh explicit admission whose
  /// identity publication has returned (and, for a first account, whose
  /// onboarding finished). A refusal means no offline access, never a sign-in
  /// failure.
  Future<void> _issueLocalReadGrant(_GrantProof p) {
    final auth = _localRead;
    if (auth == null) return Future<void>.value();
    bool current() =>
        _grantProofCurrent(p) &&
        _onboardingDone &&
        status == SessionStatus.authenticated;
    if (!current()) return Future<void>.value();
    return _admissionOp(() async {
      if (!current()) return;
      try {
        final row = await p.scope.database
            .customSelect('SELECT replica_id FROM replica_meta;')
            .get();
        if (row.length != 1 || !current()) return;
        final replicaId = row.single.read<String>('replica_id');
        final issue =
            await auth.beginIssue(uid: p.uid, replicaId: replicaId);
        await auth.commit(issue,
            proof: LocalReadIssueProof(uid: p.uid, isCurrent: current));
        AuthDiagnostics.add('local_read_issue committed');
      } catch (_) {
        // No grant: offline viewing simply is not available until the next
        // explicit sign-in.
        if (auth.pendingOperationDenials.isNotEmpty) {
          // Replacement can make the outgoing commit's cleanup incomplete.
          // Its shared exact-operation ledger already refuses restoration;
          // expose the existing truthful notice and its operation-only retry.
          denyIncompleteNoticePending.value = true;
          notifyListeners();
        }
      }
    }, current: current);
  }

  bool get isGuest => authMethod == 'guest';
  bool get hasCompletedOnboarding => _onboardingDone;
  bool get hasSeenWelcomeManifesto => _welcomeManifestoSeen;

  Future<void> load() async {
    final epoch = _admissionEpoch;
    final lossSeq = _authLossSeq;
    bool current() => epoch == _admissionEpoch && lossSeq == _authLossSeq;
    void check() {
      if (!current()) throw const StaleAdmissionException();
    }

    Future<String?> read(String key) async {
      final result = await _storage.read(key: key);
      check();
      return result;
    }

    try {
      final legacyOnboardingDone = await read(_kDone) == '1' &&
          !(_installPresentation?.requiresSetup ?? false);
      final welcomeSeen = await read(_kWelcomeManifestoSeen);
      final coachMarks = await read(_kCoachMarksSeen);
      final method = await read(_kMethod);
      final storedEmail = await read(_kEmail);
      // W5: a sign-out the previous process accepted but never completed.
      final logoutPending = await read(_kLogoutPending) != null;
      final completed = await _readCompletedAccountKeys();
      check();
      var accountKey = await read(_kCurrentAccount);
      final owner = await read(_kLocalDataOwnerUid);
      var fenceAllows = false;
      try {
        if (method != 'guest' && (owner == null || owner.isEmpty ||
            owner.startsWith(_kOwnerTransitionPrefix))) {
          fenceAllows = false;
        } else if (owner == null || owner.isEmpty) {
          fenceAllows = await _accountFence.initialize();
        } else {
          await _accountFence.guard(owner, current: current);
          fenceAllows = true;
        }
      } on StaleAdmissionException {
        return;
      } on AccountFenceDeniedException {
        fenceAllows = false;
      }
      check();
      if (fenceAllows && legacyOnboardingDone) {
        final migration = _ownershipTail.then((_) async {
          bool live() => current() && (owner == null || owner.isEmpty
              ? _accountFence.store.ready : _accountFence.permits(owner));
          if (!live()) throw const StaleAdmissionException();
          await _admissionOp(() async {
            if (welcomeSeen != '1') {
              await _storage.write(key: _kWelcomeManifestoSeen, value: '1');
              check();
            }
            if (method != null) {
              final storedCurrent = accountKey;
              accountKey ??= _identityKey(method, storedEmail);
              if (accountKey != null) {
                if (completed.add(accountKey!)) {
                  final sorted = completed.toList()..sort();
                  if (!live()) throw const StaleAdmissionException();
                  await _storage.write(key: _kCompletedAccounts, value: jsonEncode(sorted));
                  check();
                }
                if (storedCurrent != accountKey) {
                  if (!live()) throw const StaleAdmissionException();
                  await _storage.write(key: _kCurrentAccount, value: accountKey);
                  check();
                }
              }
            }
          }, current: live);
        });
        _ownershipTail = migration.then<void>((_) {}, onError: (Object _) {});
        await migration;
        check();
      }
      _welcomeManifestoSeen = welcomeSeen == '1' || legacyOnboardingDone;
      _coachMarksSeen = (coachMarks ?? '').split(',')
          .map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
      if (logoutPending) {
        // W5: the persisted identity is the outgoing one of an interrupted
        // sign-out. It is presented exactly as a completed sign-out leaves it
        // (signed out, onboarding not done) and no automatic path may restore
        // it: only an explicit successful admission (or a completed sign-out)
        // clears the pending key and reopens automatic admission.
        _logoutIncomplete = true;
        _completedAccountKeys..clear()..addAll(completed);
        authMethod = null;
        email = null;
        _currentAccountKey = null;
        _onboardingDone = false;
        _unresolvedOwnerUid = null;
        _admittedUid = null;
        value = SessionStatus.needsOnboarding;
        return;
      }
      authMethod = method;
      email = storedEmail;
      _completedAccountKeys..clear()..addAll(completed);
      _currentAccountKey = accountKey;
      _onboardingDone = !(_installPresentation?.requiresSetup ?? false) &&
          accountKey != null && completed.contains(accountKey);
      value = fenceAllows && _onboardingDone && method != null
          ? SessionStatus.authenticated : SessionStatus.needsOnboarding;
    } on StaleAdmissionException {
      // An old read may neither republish nor clear a committed successor.
      return;
    }
  }

  /// Whether a given coach mark has already been shown on this device for the
  /// current account. Unknown ids read as unseen, so adding a mark shows it.
  bool hasSeenCoachMark(String id) => _coachMarksSeen.contains(id);

  /// Records a coach mark as shown. Idempotent.
  Future<void> markCoachMarkSeen(String id) async {
    if (_coachMarksSeen.contains(id)) return;
    _coachMarksSeen = {..._coachMarksSeen, id};
    await _storage.write(
      key: _kCoachMarksSeen,
      value: _coachMarksSeen.join(','),
    );
    notifyListeners();
  }

  /// Clears every coach mark so the guided tour can be replayed on demand —
  /// the Help screen offers this, because a user who has dismissed guidance
  /// once should not be locked out of it forever.
  Future<void> resetCoachMarks() async {
    if (_coachMarksSeen.isEmpty) return;
    _coachMarksSeen = <String>{};
    await _storage.delete(key: _kCoachMarksSeen);
    notifyListeners();
  }

  /// يعلّم شاشة الترحيب السينمائية كمرئية حتى لا تظهر إلا مرة واحدة.
  Future<void> markWelcomeManifestoSeen() async {
    if (_welcomeManifestoSeen) return;
    await _storage.write(key: _kWelcomeManifestoSeen, value: '1');
    _welcomeManifestoSeen = true;
    notifyListeners();
  }

  /// يخزّن هوية الدخول دون إنهاء الـ onboarding (تبقى خطوة الطريقة بعدها).
  ///
  /// [attempt] is the [beginAuthAttempt] captured BEFORE the provider was
  /// awaited (F2): one that predates an accepted Remove data is stale and throws
  /// [StaleAdmissionException] before anything is written, opened or created.
  /// Without one, the attempt starts now (this call IS the explicit sign-in).
  ///
  /// F2: this is the explicit admission TRANSACTION. Accepting it is an account
  /// switch (every authority captured earlier is stale from that instant). It
  /// commits, in order: the ownership resolution (authority, owner marker,
  /// generation, registry, database/key, scope publication), then the identity
  /// (an admission operation, so a Remove data accepted meanwhile drains it, with
  /// the authority re-checked immediately before each write and the status
  /// publication). Identity publication is staged until the uid's
  /// `removed_requires_explicit_auth` revocation successfully commits. A failure at any stage leaves the revocation in force and rolls
  /// the partial admission back.
  Future<void> setIdentity({
    required String method,
    String? email,
    String? userId,
    AuthAttempt? attempt,
    bool Function()? sessionCurrent,
  }) async {
    final probe = _ReconnectProbe();
    try {
      await _setIdentity(
        method: method,
        email: email,
        userId: userId,
        attempt: attempt,
        sessionCurrent: sessionCurrent,
        probe: probe,
      );
    } catch (_) {
      // ASR §4.6: a refused admission aligns SDK memory and releases the
      // attempt's exclusion (a no-op when it was committed or never set).
      final intent = attempt?.intent ?? 0;
      if (intent != 0) {
        await AuthCoordinator.active?.abandonExplicit(intent);
      }
      // Strict reconnect: the outgoing local-read proof was retired when the
      // transition began and is NEVER reinstated. The only way back is a fresh
      // two-phase restore from the durable grant (new reservation, new proof);
      // if that fails the signed-out scope is published.
      await debugBeforeFailureCapture?.call();
      if (probe.began) _scheduleFreshLocalReadRestore(probe);
      rethrow;
    }
  }

  Future<void> _setIdentity({
    required String method,
    String? email,
    String? userId,
    AuthAttempt? attempt,
    bool Function()? sessionCurrent,
    required _ReconnectProbe probe,
  }) async {
    final inherited = Zone.current[_localAdmissionChain] as List<Future<void>>? ?? const [];
    if (inherited.any(_inflightAdmissions.contains)) {
      throw StateError('identity_transition_inside_local_operation');
    }
    final auth = attempt ?? beginAuthAttempt();
    if (!_attemptCurrent(auth) || !(sessionCurrent?.call() ?? true)) {
      throw const StaleAdmissionException();
    }
    // Also retire refreshes started while the provider exchange was pending.
    // This runs only after the successful response and attempt are validated.
    CloudEgressGate.instance.advanceEpoch(EpochCause.localRead);
    final epoch = ++_admissionEpoch;
    _localReadLifecycle++;
    probe.epoch = epoch;
    _explicitAdmissionEpoch = epoch;
    // Fixed old reservations only: never wait inside our own admission/host lane.
    // Capture before publication listeners can start a superseding transition.
    final priorAdmissions = _inflightAdmissions.toList(growable: false);
    _databaseHostAdmission?._revoked = true;
    _databaseIdentityPublication = null;
    _databasePublicationDenied = false;
    final databaseLoss = _databaseLossGeneration;
    // Reauthentication is a mode transition (same UID included): the local-read
    // proof AND the process capability are retired synchronously, for good.
    final hadLocalRead = _localReadProof != null;
    _pendingFirstGrant = null;
    _dropLocalReadProof();
    if (hadLocalRead) {
      _localRead?.retireProcessCapabilities();
      probe.began = true;
    }
    // The previous lifecycle's consent proof ends with this acceptance; a new one
    // is issued only by this admission's own committed publication. The loss
    // generations are captured here, before the first await: a loss raised while
    // this admission is in flight (a held identity write, a publication
    // listener) bars it from issuing.
    _revokeConsentProof();
    final authLossAtAcceptance = _authLossSeq;
    final consentLossAtAcceptance = _consentLossSeq;
    value = SessionStatus.needsOnboarding;
    bool live() =>
        !_admissionClosed &&
        !(_removeData?.isRunning ?? false) &&
        _admissionEpoch == epoch &&
        (sessionCurrent?.call() ?? true);
    try {
      await Future.wait(priorAdmissions);
      if (!live()) throw const StaleAdmissionException();
      if (userId != null && userId.isNotEmpty) {
        await _accountFence.guard(userId, current: live);
      }
    } catch (_) {
      if (_explicitAdmissionEpoch == epoch) _explicitAdmissionEpoch = null;
      rethrow;
    }
    _Admission? adm;
    // Owner gate (MALI-002): interactive sign-in happens long after bootstrap,
    // so the new uid's own replica is unlocked and opened inline here before the
    // new identity is stored — user B works in B's replica, never on top of user
    // A's rows, and A's replica is locked and untouched.
    var ownership = LocalDataOwnership.owned;
    if (userId != null && userId.isNotEmpty) {
      // Interactive sign-in is explicit user intent: allow one fresh attempt
      // even if an earlier automatic reconcile latched this uid unresolved.
      if (_unresolvedOwnerUid == userId) _unresolvedOwnerUid = null;
      adm = _Admission(
        userId,
        _authorityAt(epoch, userId,
            canCreate: true, sessionCurrent: sessionCurrent),
        explicit: true,
        sessionCurrent: sessionCurrent,
      );
      _databaseOpeningAdmission = adm;
      try {
        ownership = await _ensureLocalDataOwnedBy(userId, adm);
      } catch (_) {
        if (_explicitAdmissionEpoch == epoch) _explicitAdmissionEpoch = null;
        rethrow;
      }
      if (ownership == LocalDataOwnership.revoked) {
        if (_explicitAdmissionEpoch == epoch) _explicitAdmissionEpoch = null;
        throw const StaleAdmissionException();
      }
      if (ownership == LocalDataOwnership.unresolved) {
        if (_explicitAdmissionEpoch == epoch) _explicitAdmissionEpoch = null;
        // Ownership could not be established (previous owner's residue not
        // cleared, the owner marker could not be verified, or the replica could
        // not be opened). Fail closed (MALI-054n): do NOT admit this identity.
        // Local data is preserved. The interactive sign-in caller catches this
        // and surfaces an error. (`deferred` — purge hook absent before
        // bootstrap registers it — continues as before: admission is deferred,
        // not blocked.)
        throw const LocalDataOwnershipException();
      }
    }
    try {
      await _admissionOp(() {
        final run = _identityTail.then((_) async {
          final publish = await _commitIdentity(
            method: method,
            email: email,
            userId: userId,
            live: live,
          );
          // ASR §4.2: ExplicitCommit — the attempt's SDK session becomes the
          // committed record (lifecycle L+1, ordinary) before publication.
          final coord = AuthCoordinator.active;
          if (coord != null && auth.intent != 0 && userId != null) {
            final committed =
                await coord.commitExplicit(auth.intent, attemptCurrent: live);
            if (committed == null || committed.owner != userId) {
              throw const StaleAdmissionException();
            }
          }
          if (adm != null &&
              adm.wasRevoked &&
              ownership == LocalDataOwnership.owned) {
            await _removeData?.clearRevocation(adm.uid,
                authority: adm.authority);
          }
          if (!live()) throw const StaleAdmissionException();
          publish();
          // Publication listeners can synchronously accept removal or another
          // admission. Dispatch explicit capture publication only while this
          // committed authority still belongs to the current lifecycle.
          if (adm != null &&
              ownership == LocalDataOwnership.owned &&
              adm.current) {
            // A successful explicit admission is the recovery from an unfinished
            // logout or a closed switch: it is a new epoch with its own commit.
            _accountSwitchEpoch = null;
            _logoutIncomplete = false;
            // W5: the durable half of the same recovery. Not awaited, so the
            // publication's ordering is unchanged; a later sign-out's write of
            // the key is issued after this delete on the same storage channel.
            unawaited(_storage
                .delete(key: _kLogoutPending)
                .catchError((Object _) {}));
            // The consent-only capability is issued HERE, from the committed
            // publication and after the durable revocation clearance above, and
            // only while every condition still holds, including the ACTUAL SDK
            // session of exactly this uid (see the method).
            final uid = adm.uid;
            _issueConsentCapability(adm,
                method: method,
                sdkFresh: () => _sdkSessionFresh(uid),
                sessionCurrent: sessionCurrent,
                authLossSeq: authLossAtAcceptance,
                consentLossSeq: consentLossAtAcceptance);
            // A genuine (re)admission publishes a fresh restrictive native
            // lifetime: awaited, ordered behind any earlier fence and bounded. A
            // publication that does not verify never fails the sign-in; capture
            // simply stays unbound.
            await _publishNativeLifetime(adm);
          }
        });
        _identityTail = run.then<void>((_) {}, onError: (Object _) {});
        return run;
      }, current: live);
    } catch (_) {
      if (adm != null &&
          adm.wasRevoked &&
          ownership == LocalDataOwnership.owned) {
        await _rollbackFreshAdmission(adm);
      }
      rethrow;
    } finally {
      if (_explicitAdmissionEpoch == epoch) _explicitAdmissionEpoch = null;
      if (identical(_databaseOpeningAdmission, adm)) {
        _databaseOpeningAdmission = null;
      }
    }
    _recordDatabaseIdentityPublication(databaseLoss);
    _commitDatabasePublication(databaseLoss);
    // A genuine fresh explicit admission: lift the restrictive flag and issue
    // the receipt (a first account waits for finishOnboarding).
    if (adm != null && ownership == LocalDataOwnership.owned) {
      final pub = _databaseIdentityPublication;
      if (pub != null &&
          pub.loss == databaseLoss &&
          pub.scope.uid == adm.uid &&
          !isGuest) {
        _localReadLocked = false;
        final proof =
            _GrantProof(adm.uid, pub.scope, pub.client, pub.epoch, pub.loss);
        if (_grantProofCurrent(proof)) {
          if (_onboardingDone && status == SessionStatus.authenticated) {
            await _issueLocalReadGrant(proof);
          } else {
            _pendingFirstGrant = proof;
          }
        }
      }
    }
  }

  /// Writes the identity half of [setIdentity] and returns its final publication.
  /// [setIdentity] publishes only after durable revocation clearance succeeds. [live] is
  /// checked immediately before EVERY write and before the status publication: an
  /// accepted Remove data (or any later account switch / sign-out) stops it there,
  /// and the removal that drains it clears whatever it already wrote.
  Future<void Function()> _commitIdentity({
    required String method,
    String? email,
    String? userId,
    required bool Function() live,
  }) async {
    void check() {
      if (!live()) throw const StaleAdmissionException();
    }

    check();
    await _storage.write(key: _kMethod, value: method);
    check();
    if (email != null && email.trim().isNotEmpty) {
      await _storage.write(key: _kEmail, value: email);
      check();
    } else if (method == 'guest') {
      await _storage.delete(key: _kEmail);
      check();
    }
    final accountKey = _accountKey(
      method: method,
      email: email,
      userId: userId,
    );
    final fallbackKey = _identityKey(method, email);
    final completed = !(_installPresentation?.requiresSetup ?? false) &&
        (_completedAccountKeys.contains(accountKey) ||
        (fallbackKey != null && _completedAccountKeys.contains(fallbackKey)));
    await _storage.write(key: _kCurrentAccount, value: accountKey);
    check();
    if (completed && !_completedAccountKeys.contains(accountKey)) {
      final completedKeys = {..._completedAccountKeys, accountKey}.toList()
        ..sort();
      await _storage.write(
          key: _kCompletedAccounts, value: jsonEncode(completedKeys));
      check();
    }
    return () {
      check();
      authMethod = method;
      this.email = email;
      _currentAccountKey = accountKey;
      if (completed) _completedAccountKeys.add(accountKey);
      _onboardingDone = completed;
      value = completed
          ? SessionStatus.authenticated
          : SessionStatus.needsOnboarding;
      if (completed) unawaited(UserActivityService.onSignIn());
      notifyListeners();
    };
  }

  /// ينهي الـ onboarding بالكامل → ينتقل للتطبيق.
  ///
  /// F2: an admission operation whose authority (the admission epoch at entry) is
  /// re-checked before every write and before the status publication; one
  /// overtaken by Remove data, sign-out or an account switch returns without
  /// touching anything.
  Future<void> finishOnboarding({supabase.SupabaseClient? client}) async {
    final databaseLoss = _databaseLossGeneration;
    if (_explicitAdmissionEpoch != null) return;
    final epoch = _admissionEpoch;
    final lossSeq = _authLossSeq;
    final expectedUid = _admittedUid ?? _accountScope?.activeUid;
    final marker = await _storage.read(key: _kLocalDataOwnerUid);
    if (epoch != _admissionEpoch || lossSeq != _authLossSeq ||
        (expectedUid != null && marker != expectedUid)) {
      return;
    }
    final uid = expectedUid ?? marker;
    if (!isGuest && (uid == null || uid.isEmpty ||
        uid.startsWith(_kOwnerTransitionPrefix))) {
      return;
    }
    try {
      if (uid != null && uid.isNotEmpty) {
        await _accountFence.guard(uid, current: () => epoch == _admissionEpoch &&
            lossSeq == _authLossSeq);
      } else if (!await _accountFence.initialize()) {
        return;
      }
    } on AccountFenceDeniedException {
      return;
    } on StaleAdmissionException {
      return;
    }
    final authClient = client ??
        (SupabaseConfig.isConfigured
            ? supabase.Supabase.instance.client
            : null);
    bool fresh() {
      if (isGuest || authClient == null) return true;
      final session = authClient.auth.currentSession;
      return session != null && !session.isExpired && session.user.id == uid;
    }

    bool live() =>
        _explicitAdmissionEpoch == null &&
        !_admissionClosed &&
        !(_removeData?.isRunning ?? false) &&
        _admissionEpoch == epoch &&
        _authLossSeq == lossSeq &&
        status != SessionStatus.sessionExpired &&
        (uid == null ? _accountFence.store.ready : _accountFence.permits(uid)) &&
        fresh();
    if (!live()) return;
    final published = await _admissionOp(() async {
      if (!live()) return false;
      authMethod ??= await _storage.read(key: _kMethod);
      if (!live()) return false;
      _currentAccountKey ??= _identityKey(authMethod, email);
      if (_currentAccountKey != null) {
        _completedAccountKeys.add(_currentAccountKey!);
        await _persistCompletedAccountKeys();
        if (!live()) return false;
        await _storage.write(key: _kCurrentAccount, value: _currentAccountKey);
        if (!live()) return false;
      }
      await _storage.write(key: _kDone, value: '1');
      if (!live()) return false;
      // The onboarding consent steps just asked on this device.
      await _markConsentPromptSeen(epoch, uid);
      if (!live()) return false;
      await _installPresentation?.completeSetup();
      if (!live()) return false;
      _onboardingDone = true;
      value = authMethod == null
          ? SessionStatus.needsOnboarding
          : SessionStatus.authenticated;
      return true;
    }, current: live);
    if (!published || !live()) return;
    _commitDatabasePublication(databaseLoss);
    final firstGrant = _pendingFirstGrant;
    _pendingFirstGrant = null;
    if (firstGrant != null &&
        captureDatabaseHostAdmission() != null &&
        _grantProofCurrent(firstGrant)) {
      await _issueLocalReadGrant(firstGrant);
    }
    await syncRemoteOnboardingCompletion();
    unawaited(UserActivityService.onSignIn());
  }

  /// Whether the consent question was already shown for the admitted uid on this
  /// device. True when no uid is admitted (nothing to ask for; consent stays
  /// unset = denied).
  Future<bool> consentPromptSeen() async {
    final uid = await _storage.read(key: _kLocalDataOwnerUid);
    if (uid == null || uid.isEmpty || uid.startsWith(_kOwnerTransitionPrefix)) {
      return true;
    }
    return await _storage.read(key: '$kConsentAskedKeyPrefix$uid') != null;
  }

  Future<void> markConsentPromptSeen() async {
    final epoch = _admissionEpoch;
    final expectedUid = _admittedUid ?? _accountScope?.activeUid;
    final marker = await _storage.read(key: _kLocalDataOwnerUid);
    if (epoch != _admissionEpoch || marker == null || marker.isEmpty ||
        (expectedUid != null && marker != expectedUid)) {
      return;
    }
    try {
      await _accountFence.guard(marker, current: () => epoch == _admissionEpoch);
    } on AccountFenceDeniedException {
      return;
    } on StaleAdmissionException {
      return;
    }
    if (epoch != _admissionEpoch || !_accountFence.permits(marker)) return;
    await _markConsentPromptSeen(epoch, marker);
  }

  /// The nested onboarding call is already tracked: it must never wait on its
  /// own cleanup barrier. Only synchronous permission is used in this unit.
  Future<void> _markConsentPromptSeen(int epoch, String? expectedUid) {
    bool live() => expectedUid != null &&
        _explicitAdmissionEpoch == null && !_admissionClosed &&
        !(_removeData?.isRunning ?? false) && _admissionEpoch == epoch &&
        _accountFence.permits(expectedUid);
    if (!live()) return Future<void>.value();
    return _admissionOp(() async {
      if (!live()) return;
      final uid = await _storage.read(key: _kLocalDataOwnerUid);
      if (!live() || uid != expectedUid || uid == null || uid.isEmpty ||
          uid.startsWith(_kOwnerTransitionPrefix)) {
        return;
      }
      await _storage.write(key: '$kConsentAskedKeyPrefix$uid', value: '1');
    }, current: live);
  }

  /// Reconciles the account-scoped server marker after an interactive sign-in.
  /// Auth events can arrive before [setIdentity] stores the chosen method, so
  /// the auth screen calls this once more after setting the local identity.
  Future<bool> reconcileAccountOnboarding(
    supabase.SupabaseClient client, {
    bool requireRemoteResult = false,
  }) async {
    final firstGrant = _pendingFirstGrant;
    final resolved = await _reconcileSupabaseSession(
      client.auth.currentSession,
      client: client,
      requireOnboardingResult: requireRemoteResult,
    );
    if (requireRemoteResult && resolved == null) {
      throw const StaleAdmissionException();
    }
    // The auth screen skips finishOnboarding when a returning account's
    // completion is learned here. Complete only the proof retained by this
    // process's explicit admission; ordinary restores have no such proof.
    if (firstGrant != null &&
        identical(_pendingFirstGrant, firstGrant) &&
        identical(firstGrant.client, client) &&
        _onboardingDone &&
        status == SessionStatus.authenticated &&
        captureDatabaseHostAdmission() != null &&
        _grantProofCurrent(firstGrant)) {
      _pendingFirstGrant = null;
      await _issueLocalReadGrant(firstGrant);
    }
    return _onboardingDone;
  }

  /// Idempotently records a locally completed setup on the authenticated
  /// profile. Failure never revokes local completion; cold start/resume retries
  /// it, preserving offline-first access while making the next device correct.
  Future<bool> syncRemoteOnboardingCompletion() async {
    if (!_onboardingDone || isGuest || !SupabaseConfig.isConfigured) {
      return false;
    }
    try {
      final client = supabase.Supabase.instance.client;
      if (client.auth.currentSession == null) return false;
      await client.rpc('mark_onboarding_completed');
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[AppSession] onboarding completion sync deferred: '
          '${error.runtimeType}',
        );
      }
      return false;
    }
  }

  /// (توافق) دخول كامل في خطوة واحدة.
  Future<void> completeOnboarding(
      {required String method, String? email, String? userId}) async {
    await setIdentity(method: method, email: email, userId: userId);
    await finishOnboarding();
  }

  /// Signs the current identity out (WP-3b: LOCKS the replica, never wipes it).
  ///
  /// The uid's encrypted replica, its outboxes, cursors and consent stay on the
  /// device. Locking marks it `locked` and closes it, so it opens again only after
  /// the SAME uid authenticates successfully (SYNC-Q3: no offline reopen). A lock
  /// failure aborts the sign-out (rethrows, no identity state touched) rather than
  /// leaving the account's database open behind a signed-out UI. Safe to call
  /// repeatedly: an already-locked replica and an already-signed-out state are
  /// no-ops for every step below. "Remove data from this device" is a separate,
  /// explicit action ([removeDataFromDevice]).
  /// Runs the registered best-effort outbox flush with a bounded timeout.
  /// Public (MALI-053n) so the sign-out UI can flush and then RE-CHECK the
  /// unsynced inventory before deciding — a timeout/failure here is NEVER
  /// treated as a successful sync (the inventory re-check is the source of
  /// truth). Offline/slow network must not block the flow.
  Future<void> flushPendingForSignOut({bool skipRemote = false}) async {
    final flush = skipRemote ? null : _flushPendingSync;
    if (flush == null) return;
    try {
      await flush().timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline/slow network — surfaced by the inventory re-check, not here.
    }
  }

  Future<SignOutOutcome> signOut() async {
    // D6: a logout from the offline read-only scope has no remote effect: nothing
    // is pushed (the outbox flush) and no backend call is made (device unlink).
    // Captured BEFORE the denial below drops the local-read proof.
    final fromLocalRead = localReadEgressDenied;
    // P3: the capture-device unlink is taken BEFORE any authority is revoked
    // below (afterwards the capture gate refuses it and the server keeps
    // pushing the outgoing user's notifications to this phone). Null when the
    // install has no Cloud-ON link: a Cloud-OFF sign-out sends nothing.
    final unlinkTicket =
        fromLocalRead ? null : _takeCaptureUnlinkTicket?.call();
    // Lock + durable deny start NOW (synchronously revoked in memory); the scope
    // is locked just below, so the denial does not lock it a second time.
    final denial = _denyLocalRead(lockScope: false);
    _revokeDatabasePublication();
    // F2: a sign-out invalidates, synchronously, every authority captured before
    // it: a reconcile or rebootstrap still in flight for the outgoing session can
    // no longer admit, write or open anything. It also CLOSES admission for as
    // long as the logout runs (a counter, like removals): no admission, automatic
    // authority, local capture or consent capability can be issued or become
    // current meanwhile, and the outgoing consent proof is never restored, even
    // if the logout fails.
    _logoutsAccepted++;
    _admissionEpoch++;
    _localReadLifecycle++;
    _revokeConsentProof();
    // ----------------------------------------------------------------
    var completed = false;
    var locked = false;
    try {
      await _storage.write(key: _kLogoutPending, value: '1').catchError((Object _) {}); // W5
      // Bounded local/admission work already dispatched (a consent write holding
      // a transaction on the database about to be locked) settles BEFORE the
      // generation is invalidated and the scope locked: its authority is already
      // revoked, so it rolls back at its next guard rather than landing. The
      // network flush below is deliberately NOT part of this drain.
      await drainAdmissions();
      // MALI-069n §Blocker-1: invalidate the admission generation before any
      // close/purge begins, so an in-flight background job bound to this session
      // is rejected at its next validation boundary and can neither commit nor
      // acknowledge under the outgoing (or a subsequent) admission.
      await _invalidateOwnerGeneration();
      // Lock + close the active replica and publish the signed-out scope.
      await _accountScope?.lock();
      locked = true;
      // The ticket replaces the gated unlink hook (remoteEffects: false).
      await _finishSignedOut(remoteEffects: false, unlinkTicket: unlinkTicket);
      await denial;
      await _storage.delete(key: _kLogoutPending).catchError((Object _) {}); // W5
      completed = true;
    } finally {
      // Whatever was issued DURING the closure (an auth attempt, an authority)
      // never becomes current once it ends: the epoch moves again, synchronously,
      // before the closure is released. Only this counter's own decrement
      // reopens admission, and only after every concurrent logout finished.
      _admissionEpoch++;
      _revokeConsentProof();
      if (completed) {
        _accountSwitchEpoch = null;
        _logoutIncomplete = false;
      } else {
        // FAILED part-way: the old status/scope may still look authenticated and
        // open. The counter is released (never leaked), but local and consent
        // work stay closed and nothing restores the outgoing authority; the
        // failure is rethrown to the caller as an incomplete logout.
        _logoutIncomplete = true;
        // W2: once the replica is locked nothing saves any more, so an
        // authenticated status would be a dead end. Route to sign-in instead (an
        // explicit admission clears _logoutIncomplete). A lock failure keeps
        // the old status: the database may still be open behind it.
        if (locked && !isGuest && authMethod != null) {
          value = SessionStatus.sessionExpired;
        }
      }
      _logoutsAccepted--;
    }
    return localReadCleanupIncomplete
        ? SignOutOutcome.durableDenyIncomplete
        : SignOutOutcome.complete;
  }

  /// Everything after the replica is locked/removed: native residue purge, owner
  /// release, capture unlink and identity cleanup. Shared by [signOut] and
  /// [removeDataFromDevice].
  ///
  /// [releaseOwner] false leaves the owner marker and the native owner alone;
  /// [onlyOwner] releases them only when the marker still names that uid (or none):
  /// a Remove data for X must not release an owner that moved to Y meanwhile.
  Future<void> _finishSignedOut({
    bool releaseOwner = true,
    String? onlyOwner,
    bool remoteEffects = true,
    Future<void> Function()? unlinkTicket,
    bool Function()? current,
  }) async {
    bool live() => current?.call() ?? true;
    if (!live()) return;
    // P3: a sign-out's pre-captured unlink is sent FIRST, before the owner
    // marker is released below: the HTTP egress gate judges the active owner's
    // Cloud state, which must still be the outgoing (Cloud-ON) user's.
    if (unlinkTicket != null) {
      unawaited(
        unlinkTicket().timeout(const Duration(seconds: 4)).catchError((_) {
          // Best effort, like the hook below; the ack it could not clear is
          // superseded by the next link.
        }),
      );
    }
    var release = releaseOwner;
    if (release && onlyOwner != null) {
      try {
        final marker = await _storage.read(key: _kLocalDataOwnerUid);
        if (!live()) return;
        if (marker != null && marker.isNotEmpty && marker != onlyOwner) {
          release = false;
        }
      } catch (_) {
        release = false;
      }
    }
    if (release) {
      // MALI-054n/070n: release the native capture owner BEFORE releasing
      // ownership. If the purge cannot be confirmed, KEEP the owner uid: the next
      // DIFFERENT user then hits the changed-owner path (_ensureLocalDataOwnedBy),
      // which re-purges and fails closed rather than admitting them onto un-purged
      // residue. (Same user re-login is unaffected: their own residue is not a
      // cross-user leak.)
      final residuePurged = await _runOwnerClear(signOut: true);
      if (!live()) return;
      if (residuePurged) {
        await _storage.delete(key: _kLocalDataOwnerUid);
        if (!live()) return;
      }
    }
    if (!live()) return;
    UserActivityService.onSignOut();
    final unlink = remoteEffects ? _unlinkCaptureDevice : null;
    if (unlink != null) {
      unawaited(
        unlink().timeout(const Duration(seconds: 4)).catchError((_) {
          // Sign-out is authoritative locally. A failed best-effort unlink is
          // safe because per-row claimed_user_id still prevents cross-user sync.
        }),
      );
    }
    if (!live()) return;
    await _storage.delete(key: _kMethod);
    if (!live()) return;
    await _storage.delete(key: _kEmail);
    if (!live()) return;
    await _storage.delete(key: _kCurrentAccount);
    if (!live()) return;
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _unresolvedOwnerUid = null;
    _admittedUid = null;
    value = SessionStatus.needsOnboarding;
  }

  /// Consumes genuine original local authority, not remote-response evidence.
  Future<PreparedOriginalLocalRemovalOutcome>
      removePreparedOriginalLocalReplica({
    required DatabaseHostAdmission originalAdmission,
    required AdmissionAuthority originalOrigin,
  }) async {
    final inherited =
        Zone.current[_localAdmissionChain] as List<Future<void>>? ?? const [];
    if (inherited.any(_inflightAdmissions.contains) ||
        _admissionClosed ||
        _explicitAdmissionEpoch != null ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete ||
        _localReadTransitionFence ||
        localReadEgressDenied) {
      return PreparedOriginalLocalRemovalOutcome.operationUnavailable;
    }
    final flow = _removeData;
    if (flow == null || flow.isRunning) {
      return PreparedOriginalLocalRemovalOutcome.operationUnavailable;
    }
    // Callback currency first; private receipt/state checks last, without an
    // intervening caller callback, await or notification before reservation.
    if (!originalOrigin.isCurrent ||
        originalOrigin.uid != originalAdmission.uid ||
        originalOrigin.epoch != originalAdmission._epoch ||
        !identical(originalAdmission._owner, this) ||
        !_databaseAdmissionCurrent(originalAdmission) ||
        _admissionClosed ||
        _accountSwitchEpoch != null ||
        _logoutIncomplete ||
        _localReadTransitionFence ||
        localReadEgressDenied) {
      return PreparedOriginalLocalRemovalOutcome.staleBeforeAcceptance;
    }
    final reservation =
        flow.reservePreparedRemoval(originalAdmission, originalOrigin);
    if (reservation == null) {
      return PreparedOriginalLocalRemovalOutcome.operationUnavailable;
    }
    // Reservation itself revoked the proof via isRunning. Never recheck it.
    final target = originalAdmission.uid;
    final operation = Object();
    _preparedRemovalOperation = operation;
    _removalsAccepted++;
    _admissionEpoch++;
    _authLossSeq++;
    _localReadLifecycle++;
    _localReadLocked = true;
    _pendingFirstGrant = null;
    _localReadProof = null;
    _accountFenceOwner = null;
    _revokeDatabasePublication();
    _revokeConsentProof();
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _unresolvedOwnerUid = null;
    _pendingOwnerConflictUid = null;
    _admittedUid = null;
    _accountSwitchEpoch = null;
    bool owned() =>
        identical(_preparedRemovalOperation, operation) &&
        _removalsAccepted > 0;
    var confirmed = false;
    var started = false;
    try {
      value = SessionStatus.needsOnboarding;
      started = true;
      await flow.runPreparedRemoval(reservation);
      await _finishPreparedOriginalIdentity(target, stillCurrent: owned);
      await _denyLocalRead(uid: target, lockScope: false);
      await nativeLifecycleSettled();
      if (!owned() || localReadCleanupIncomplete || _fenceIncomplete) {
        throw const RemoveDataIncompleteException();
      }
      await flow.settlePreparedRemoval(reservation,
          localCleanupConfirmed: true);
      await _clearRemovedOwnerDeviceResidue(target, stillCurrent: owned);
      _logoutIncomplete = false;
      confirmed = true;
    } catch (_) {
      _logoutIncomplete = true;
      await drainAdmissions();
      await nativeLifecycleSettled();
      if (started) {
        try {
          await flow.settlePreparedRemoval(reservation,
              localCleanupConfirmed: false);
        } catch (_) {}
      } else {
        flow.abandonPreparedRemoval(reservation);
      }
    } finally {
      // Even preflight refusal observes old actual work, never this operation.
      await drainAdmissions();
      await nativeLifecycleSettled();
      _admissionEpoch++;
      _authLossSeq++;
      _revokeDatabasePublication();
      if (identical(_preparedRemovalOperation, operation)) {
        _preparedRemovalOperation = null;
      }
      _removalsAccepted--;
    }
    return confirmed
        ? PreparedOriginalLocalRemovalOutcome.originalLocalRemovalConfirmed
        : PreparedOriginalLocalRemovalOutcome.localRemovalIncomplete;
  }

  /// Strict cleanup after an actual target-specific native/replica removal.
  /// The guard only denies stale continuations; it never creates authority.
  Future<void> _finishPreparedOriginalIdentity(String target,
      {required bool Function() stillCurrent}) async {
    void requireCurrent() {
      if (!stillCurrent()) throw const StaleAdmissionException();
    }

    requireCurrent();
    final marker = await _storage.read(key: _kLocalDataOwnerUid);
    requireCurrent();
    if (marker != null && marker.isNotEmpty) {
      throw const RemoveDataIncompleteException();
    }
    final generation = await _storage.read(key: _kLocalDataOwnerGeneration);
    requireCurrent();
    if (generation != null) throw const RemoveDataIncompleteException();
    final account = await _storage.read(key: _kCurrentAccount);
    requireCurrent();
    if (account != null && account.isNotEmpty && account != 'uid:$target') {
      throw const RemoveDataIncompleteException();
    }
    for (final key in [_kMethod, _kEmail, _kCurrentAccount]) {
      requireCurrent();
      await _storage.delete(key: key);
      requireCurrent();
      final retained = await _storage.read(key: key);
      requireCurrent();
      if (retained != null) throw const RemoveDataIncompleteException();
    }
    requireCurrent();
    UserActivityService.onSignOut();
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _unresolvedOwnerUid = null;
    _admittedUid = null;
    value = SessionStatus.needsOnboarding;
  }

  /// "Remove data from this device" for the signed-in uid (manifest §4.4):
  /// deletes that uid's replica, key and native residue, then signs out. Throws
  /// [RemoveDataIncompleteException] when a step could not be confirmed; the
  /// barrier is then kept and resumes at the next launch or admission, and the
  /// caller must not report completion.
  ///
  /// F2: accepting the request SYNCHRONOUSLY revokes admission, before the first
  /// await or notification: admission closes, the epoch advances (every retained
  /// authority/attempt is stale), `_authLossSeq` advances (retained reconciles
  /// stop) and the in-memory identity/status is cleared, so nothing — the remounted
  /// shell's revalidation, an auth event, a rebootstrap — can authorize this uid
  /// while the removal runs. After a completed removal the uid additionally stays
  /// revoked, durably, until a NEW explicit authentication ([RemoveDataFlow.revokedKey]).
  ///
  /// [signOutRemote] (provider/SDK logout) runs at the end, best effort, from
  /// here rather than from the Settings widget the scope swap disposes. It is not
  /// the fence and not a prerequisite of the deletion.
  Future<void> removeDataFromDevice({
    Future<void> Function()? signOutRemote,
  }) async {
    _revokeDatabasePublication();
    // ---- synchronous revocation: NOTHING above this line may await ----
    // The uid this request authorizes is fixed HERE and is the only uid it may
    // remove: the one admitted in this process, else the one whose scope is
    // published. The owner marker is never consulted to choose it — it may have
    // moved to another account meanwhile. With neither known nothing is removed.
    final target = _admittedUid ?? _accountScope?.activeUid;
    final denial = _denyLocalRead(uid: target, lockScope: false);
    _removalsAccepted++;
    _admissionEpoch++;
    _localReadLifecycle++;
    _authLossSeq++;
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _unresolvedOwnerUid = null;
    _pendingOwnerConflictUid = null;
    _admittedUid = null;
    _revokeConsentProof();
    _accountSwitchEpoch = null;
    value = SessionStatus.needsOnboarding;
    // ---------------------------------------------------------------------
    var denyIncomplete = false;
    try {
      var removed = false;
      if (target != null && target.isNotEmpty) {
        final flow = _removeData;
        try {
          if (flow == null) throw const RemoveDataIncompleteException();
          await flow.remove(target);
        } on RemoveDataIncompleteException {
          // The barrier is kept and resumes at the next launch/admission. Until
          // then the device must not sit signed in on a half-removed account:
          // lock whatever is still open and sign out locally, then report it.
          await _accountScope?.lock();
          await _finishSignedOut(onlyOwner: target);
          rethrow;
        }
        removed = true;
      }
      // Without a target nothing was removed: the device is signed out locally
      // and the owner marker (whatever it names) is left alone.
      await _finishSignedOut(
        releaseOwner: target != null && target.isNotEmpty,
        onlyOwner: target,
      );
      _logoutIncomplete = false;
      // §4.4 step 6. Held here, not in a widget: the scope swap disposes the
      // screen that asked, and the root shows it once on the screen that follows.
      if (removed) removalNoticePending.value = true;
    } finally {
      _removalsAccepted--;
      await denial;
      // D4: whether the durable offline-access denial landed is reported to the
      // ROOT (the screen that asked is disposed by the scope swap), on the
      // returning AND the throwing path, and apart from the data-removed notice.
      // The notice states only the denial fact (R10.3): this finally block also
      // runs when the removal threw or when there was no target, so it can never
      // claim that data was removed or that a restart completes the denial.
      denyIncomplete = localReadCleanupIncomplete;
      _lastRemoveDataOutcome = denyIncomplete
          ? RemoveDataOutcome.durableDenyIncomplete
          : RemoveDataOutcome.complete;
      if (denyIncomplete) denyIncompleteNoticePending.value = true;
      if (signOutRemote != null) {
        try {
          await signOutRemote();
        } catch (_) {
          // The local removal above is authoritative; a provider logout failure
          // must not reopen access to this account's local data.
        }
      }
    }
  }

  RemoveDataOutcome _lastRemoveDataOutcome = RemoveDataOutcome.complete;

  /// D4: [removeDataFromDevice] reporting what its durable-denial step achieved.
  /// The outcome speaks ONLY to the offline-access denial (see
  /// [RemoveDataOutcome]); whether data was removed is a separate fact: a removal
  /// that could not be confirmed throws [RemoveDataIncompleteException] and a
  /// request with no target removes nothing. The root denial notice is raised by
  /// the call itself, on the returning and the throwing path alike, with neutral
  /// copy that claims no removal and promises no restart; the data-removed notice
  /// is raised only by a confirmed removal.
  Future<RemoveDataOutcome> removeDataFromDeviceWithOutcome({
    Future<void> Function()? signOutRemote,
  }) async {
    await removeDataFromDevice(signOutRemote: signOutRemote);
    return _lastRemoveDataOutcome;
  }

  /// Invalidates the admission generation, but only while the owner marker still
  /// names [uid] (or none): a generation that already belongs to another account's
  /// admission is not the removed uid's to invalidate.
  Future<void> invalidateRemovalGeneration(String uid) =>
      _invalidateOwnerGenerationOf(uid);

  Future<void> _invalidateOwnerGenerationOf(String? uid) async {
    if (uid == null) return;
    final String? marker;
    try {
      marker = await _storage.read(key: _kLocalDataOwnerUid);
    } catch (_) {
      return;
    }
    if (marker != null && marker.isNotEmpty && marker != uid) return;
    await _invalidateOwnerGeneration();
  }

  /// One-shot "data removed" notice (set only by a COMPLETED removal; consumed by
  /// the root widget). In memory on the singleton, so it survives the
  /// ProviderScope rebuild the removal causes.
  final ValueNotifier<bool> removalNoticePending = ValueNotifier<bool>(false);

  /// Set when a removal / sign-out finished with the durable offline-access
  /// denial still unestablished. Consumed by the ROOT widget (not by the screen
  /// that started the removal, which the scope swap disposes).
  final ValueNotifier<bool> denyIncompleteNoticePending =
      ValueNotifier<bool>(false);

  /// Step 1 of the removal of [uid]: the owner record is cleared (the native
  /// owner record is cleared by the barrier's `begin`) — but only while it still
  /// names [uid]. A marker that moved to another account meanwhile belongs to that
  /// account and is neither read as ours nor deleted; its generation likewise.
  ///
  /// F2: the delete is VERIFIED by reading the marker back. On iOS a delete can
  /// silently miss an item written under another accessibility class, which then
  /// keeps naming the removed uid; the write path repairs such an item, so it is
  /// overwritten and deleted once more. A marker that still reads back throws.
  Future<void> clearLocalDataOwnerMarker(String uid,
      {bool Function()? current, bool strictOriginalOwner = false}) async {
    bool live() => current?.call() ?? true;
    if (!live()) return;
    final marker = await _storage.read(key: _kLocalDataOwnerUid);
    if (!live()) return;
    if (marker != null && marker.isNotEmpty && marker != uid) {
      if (strictOriginalOwner) throw const RemoveDataIncompleteException();
      if (!marker.startsWith(_kOwnerTransitionPrefix)) return;
    }
    if (!live()) return;
    await _invalidateOwnerGeneration();
    if (!live()) return;
    await _storage.delete(key: _kLocalDataOwnerUid);
    if (!live()) return;
    final afterDelete = await _storage.read(key: _kLocalDataOwnerUid);
    if (!live() || afterDelete == null) return;
    if (strictOriginalOwner && afterDelete.isNotEmpty && afterDelete != uid) {
      throw const RemoveDataIncompleteException();
    }
    if (!live()) return;
    await _storage.write(key: _kLocalDataOwnerUid, value: '');
    if (!live()) return;
    await _storage.delete(key: _kLocalDataOwnerUid);
    if (!live()) return;
    final afterRetry = await _storage.read(key: _kLocalDataOwnerUid);
    if (!live()) return;
    if (afterRetry != null) {
      throw const RemoveDataIncompleteException();
    }
  }

  /// F2 — launch ordering, BEFORE any auth binding, legacy adoption or replica
  /// open: finishes a pending removal (a pending record, an unreadable record or
  /// a native barrier of unknown uid all block), verifies the owner marker did
  /// not survive for a removed uid, and says whether the launch is [blocked] or
  /// which uid's EXISTING replica may be opened (null = the signed-out scope).
  /// Idempotent.
  ///
  /// A blocked launch also holds the in-memory session signed out, so the
  /// persisted identity cannot route anywhere authenticated while it lasts.
  /// A completed removal whose identity cleanup a crash interrupted (the durable
  /// record is already gone) is finished here: the leftover identity of a removed
  /// uid is cleared and the status forced signed out.
  Future<LaunchAdmission> prepareLaunchAdmission() async {
    final epoch = _admissionEpoch;
    String? intendedOwner;
    LaunchAdmission blocked() => epoch == _admissionEpoch
        ? _blockedLaunch() : const LaunchAdmission.blocked();
    Future<void> mutate(Future<void> Function() action) {
      final run = _ownershipTail.then((_) async {
        if (epoch != _admissionEpoch) return;
        await action();
      });
      _ownershipTail = run.then<void>((_) {}, onError: (Object _) {});
      return run;
    }

    try {
      final owner = await _storage.read(key: _kLocalDataOwnerUid);
      if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      intendedOwner = owner;
      if (owner == null || owner.isEmpty) {
        if (!await _accountFence.initialize()) return blocked();
      } else {
        await _accountFence.guard(owner, current: () => epoch == _admissionEpoch);
      }
    } catch (_) {
      return blocked();
    }
    if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
    final removal = _removeData;
    var revoked = <String>{};
    if (removal != null) {
      final hadRecord = await removal.hasPending();
      if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      final recovered = await removal.resumePendingWithOutcome();
      if (!recovered.completed) return blocked();
      if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      try {
        revoked = await removal.revokedUids();
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      } catch (_) {
        return blocked();
      }
      final String? markerNow;
      try {
        markerNow = await _storage.read(key: _kLocalDataOwnerUid);
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      } catch (_) {
        return blocked();
      }
      // The identity half of a removal the crashed process never reached.
      if (hadRecord ||
          revoked.any(
            (uid) =>
                _currentAccountKey == 'uid:$uid' ||
                (markerNow != null && markerNow == uid),
          )) {
        final recoveredOwner = recovered.uid;
        String? identityOwner;
        for (final uid in revoked) {
          if (_currentAccountKey == 'uid:$uid' || markerNow == uid) {
            identityOwner = uid;
            break;
          }
        }
        // Only a record that says local-only is the strict path: an ordinary
        // interrupted Remove data (false) or an unknown mode (null) finishes
        // through the normal sign-out below.
        final strictTarget = recovered.localOnly == true
            ? (recoveredOwner ?? identityOwner)
            : null;
        if (strictTarget != null) {
          try {
            await mutate(() async {
              if (markerNow == strictTarget && revoked.contains(strictTarget)) {
                await clearLocalDataOwnerMarker(strictTarget,
                    strictOriginalOwner: true,
                    current: () => epoch == _admissionEpoch);
              }
              await _finishPreparedOriginalIdentity(strictTarget,
                  stillCurrent: () => epoch == _admissionEpoch);
              await _clearRemovedOwnerDeviceResidue(strictTarget,
                  stillCurrent: () => epoch == _admissionEpoch);
            });
          } catch (_) {
            return blocked();
          }
        } else {
          await mutate(() => _finishSignedOut(
              remoteEffects: recovered.localOnly == false,
              current: () => epoch == _admissionEpoch));
        }
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      }
      // P4: the server confirmed this owner's account deletion (a durable
      // COMPLETED receipt, retained until the original local removal), but the
      // process died before that removal ran. The prepared cleanup needs a live
      // admission and SDK session the deleted account can never obtain again,
      // so the receipt itself is the evidence here: the replica, key, marker and
      // identity are removed by uid, and the uid stays revoked. An unconfirmed
      // removal keeps its barrier and blocks; the next launch resumes it.
      final String? deletedOwner;
      try {
        final m = await _storage.read(key: _kLocalDataOwnerUid);
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
        deletedOwner = m != null &&
                m.isNotEmpty &&
                m == intendedOwner &&
                !m.startsWith(_kOwnerTransitionPrefix)
            ? m
            : null;
      } catch (_) {
        return blocked();
      }
      if (deletedOwner != null) {
        final receipts = ImmediateDeletionReceiptStore();
        ImmediateDeletionReceipt? receipt;
        try {
          receipt =
              await receipts.serialized(() => receipts.load(deletedOwner!));
        } catch (_) {
          // An unreadable receipt is not completion evidence.
          receipt = null;
        }
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
        if (receipt != null &&
            receipt.phase == ImmediateDeletionPhase.completed) {
          try {
            await removal.remove(deletedOwner);
          } catch (_) {
            return blocked();
          }
          if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
          await mutate(() => _finishSignedOut(
              onlyOwner: deletedOwner,
              remoteEffects: false,
              current: () => epoch == _admissionEpoch));
          if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
          await _retireCompletedDeletionReceipt(receipts, receipt);
          try {
            revoked = await removal.revokedUids();
            if (epoch != _admissionEpoch) {
              return const LaunchAdmission.blocked();
            }
          } catch (_) {
            return blocked();
          }
        }
      }
    }
    final String? marker;
    try {
      marker = await _storage.read(key: _kLocalDataOwnerUid);
    } catch (_) {
      return blocked();
    }
    if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
    if (marker != null && marker.isNotEmpty && marker != intendedOwner) return blocked();
    if (marker == null || marker.isEmpty) {
      return _chosenLaunch(LaunchAdmission.open(null));
    }
    if (revoked.contains(marker)) {
      // A stale marker naming a removed uid is never opened (and is cleared).
      try {
        await mutate(() => clearLocalDataOwnerMarker(marker!,
            current: () => epoch == _admissionEpoch));
        if (epoch != _admissionEpoch) return const LaunchAdmission.blocked();
      } catch (_) {
        return blocked();
      }
      return _chosenLaunch(LaunchAdmission.open(null));
    }
    return _chosenLaunch(LaunchAdmission.open(marker));
  }

  /// P4: erases the secret of a COMPLETED receipt once its local removal was
  /// confirmed at launch, exactly as the prepared gateway's retirement does
  /// after a confirmed original local removal: only that same operation's
  /// record, still completed. Best effort: a leftover completed receipt only
  /// ever allows a read-only status call.
  Future<void> _retireCompletedDeletionReceipt(
      ImmediateDeletionReceiptStore receipts,
      ImmediateDeletionReceipt removed) async {
    if (removed.receiptSecret == null) return;
    try {
      await receipts.serialized(() async {
        final record = await receipts.load(removed.owner);
        if (record == null ||
            record.operationId != removed.operationId ||
            record.phase != ImmediateDeletionPhase.completed ||
            record.receiptSecret != removed.receiptSecret) {
          return;
        }
        await receipts.writeVerified(ImmediateDeletionReceipt(
            owner: removed.owner,
            operationId: removed.operationId,
            receiptSecret: null,
            phase: ImmediateDeletionPhase.completed));
      });
    } catch (_) {}
  }

  /// The launch admission this session itself chose last (identity only): the
  /// sole thing a cold-launch reservation may be minted for.
  LaunchAdmission? _chosenLaunchAdmission;
  bool _chosenLaunchReserved = false;

  LaunchAdmission _chosenLaunch(LaunchAdmission launch) {
    _chosenLaunchAdmission = launch;
    _chosenLaunchReserved = false;
    return launch;
  }

  /// The cold-launch reservation minter for [launch], or null when none may be
  /// minted: no coordinator, a blocked launch, a signed-out launch, a launch this
  /// session did not choose (a forged or stale one) or one already reserved.
  ///
  /// The returned callback is handed to `AccountScopeHost.openAtLaunch`; it mints
  /// the private reservation BEFORE the opener and remembers it, so committed
  /// publication can promote exactly that tracked primary (and nothing else).
  /// Removal, session invalidation and a loss of the launch itself make the
  /// reservation stale. It never creates, never issues a job and is not
  /// committed authority.
  DatabaseOpenReservation? Function(String uid)? coldLaunchReserver(
      LaunchAdmission launch) {
    final coordinator = _databaseCoordinator;
    if (coordinator == null ||
        launch.blocked ||
        launch.uid == null ||
        !identical(_chosenLaunchAdmission, launch) ||
        _chosenLaunchReserved) {
      return null;
    }
    final lossAtMint = _databaseLossGeneration;
    final epochAtMint = _admissionEpoch;
    return (uid) {
      if (uid != launch.uid ||
          !identical(_chosenLaunchAdmission, launch) ||
          _chosenLaunchReserved) {
        return null;
      }
      _chosenLaunchReserved = true;
      final reservation = coordinator.reserveColdLaunchOpen(
        uid: uid,
        launchIdentity: launch,
        lossGeneration: lossAtMint,
        stillValid: () =>
            identical(_chosenLaunchAdmission, launch) &&
            _databaseLossGeneration == lossAtMint &&
            !_admissionClosed &&
            !(_removeData?.isRunning ?? false) &&
            // A later explicit sign-in/sign-out bumps the epoch past the launch.
            _admissionEpoch == epochAtMint,
      );
      _databaseOpenReservation = reservation;
      return reservation;
    };
  }

  LaunchAdmission _blockedLaunch() {
    _revokeDatabasePublication();
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    _admittedUid = null;
    _revokeConsentProof();
    value = SessionStatus.needsOnboarding;
    return const LaunchAdmission.blocked();
  }

  Future<void> bindSupabaseAuth(supabase.SupabaseClient client) async {
    // A different SDK binding retires every retained broker issuer immediately.
    if (!identical(_databaseIssuerClient, client)) {
      _databaseHostAdmission?._revoked = true;
      _databaseLossGeneration++;
      _databaseHostAdmission = null;
      _databaseIssuerClient = client;
    }
    const boundary = AuthStreamBoundary('appSession');
    _supabaseAuthSubscription ??= client.auth.onAuthStateChange.listen(
      (state) => unawaited(
          boundary.run(() => _handleSupabaseAuthChange(state, client))),
      onError: boundary.onError,
    );
    await _reconcileSupabaseSession(client.auth.currentSession, client: client);
  }

  /// Re-checks the live Supabase session against the current in-memory
  /// client state. Call on app resume (a refresh token can be revoked or
  /// expire while backgrounded, with no auth-state event delivered until the
  /// app is foregrounded again and something touches the client).
  Future<void> revalidateSupabaseSessionOnResume(
    supabase.SupabaseClient client, {
    AdmissionAuthority? authority,
  }) async {
    // No isConfigured gate here: the caller (AppShell) already checks it
    // before ever obtaining a client to pass in — a redundant check on the
    // already-injected client only makes this harder to exercise in tests
    // (SupabaseConfig reads compile-time dart-defines, empty under a plain
    // `flutter test` run) for no behavioral benefit.
    await _reconcileSupabaseSession(
      client.auth.currentSession,
      client: client,
      authority: authority,
    );
  }

  /// The shell's cold-start/resume revalidation (F2). A shell runs its
  /// Supabase-primary startup work only while the session is `authenticated`
  /// BEFORE and AFTER the reconcile; `needsOnboarding` (what Remove data leaves
  /// while the generation-keyed scope remounts) is not enough. [client] is null
  /// when Supabase is not configured.
  Future<bool> revalidateForShell(supabase.SupabaseClient? client) async {
    if (_explicitAdmissionEpoch != null ||
        status != SessionStatus.authenticated) {
      return false;
    }
    // ASR §8 warm resume: refresh first (when due and the gate permits, under a
    // 5 s foreground bound; the op itself keeps custody past it).
    final coord = AuthCoordinator.active;
    if (client != null && coord != null) {
      try {
        await coord.refreshIfDue().timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    if (client != null) await revalidateSupabaseSessionOnResume(client);
    return _explicitAdmissionEpoch == null &&
        status == SessionStatus.authenticated;
  }

  /// Capture before starting repository work, never when its error arrives.
  /// A response for an older admission or credential cannot revoke its successor.
  Future<void> Function() captureAuthRequiredFailure(
    supabase.SupabaseClient? client,
  ) {
    final epoch = _admissionEpoch;
    final sdk = client?.auth.currentSession;
    return () async {
      final actual = client?.auth.currentSession;
      if (epoch != _admissionEpoch ||
          _explicitAdmissionEpoch != null ||
          actual?.user.id != sdk?.user.id ||
          actual?.accessToken != sdk?.accessToken) {
        return;
      }
      // An expired access token is recoverable. Do not turn the repository's
      // expiry response into an unknown/revoked-session barrier.
      if (client != null && actual != null && actual.isExpired) {
        await _reconcileSupabaseSession(actual, client: client);
        return;
      }
      await handleAuthRequiredFailure();
    };
  }

  /// Called by a Supabase-primary repository consumer (see
  /// `RepoException`/`AuthRepoException`) when a call fails specifically
  /// because there is no valid authenticated session. Downgrades status to
  /// [SessionStatus.sessionExpired] so the router redirects to sign-in.
  ///
  /// Idempotent and safe to call from multiple concurrent failures: setting
  /// [value] to its current value is a no-op in [ValueNotifier] (no repeated
  /// `notifyListeners()`), so N simultaneous `auth_required` failures produce
  /// exactly one status transition and one router redirect, never a storm.
  Future<void> handleAuthRequiredFailure() async {
    if (isGuest || authMethod == null) return;
    // auth_required with an unknown cause is never read as harmless expiry.
    // Publish loss before durable cleanup yields: cleanup must never resume
    // later and invalidate a successful intervening admission.
    markSessionInvalid();
    await _denyLocalRead();
  }

  /// Downgrades an authenticated (or unknown) status to [sessionExpired]
  /// without touching onboarding completion, the stored identity, or any
  /// unrelated local preference — only the *live* session judgment changes.
  void markSessionInvalid({SessionLossCause cause = SessionLossCause.other}) {
    // ASR §7.7: every loss that is not a plain expiry (or ASR's own wait for
    // adoption) durably bars automatic recovery of this lifecycle and
    // invalidates the expiry evidence, before anything else can run.
    if (cause == SessionLossCause.other) _invalidateAsrEvidence();
    _revokeDatabasePublication();
    // The consent proof is dropped HERE, synchronously, at the origin of the
    // loss and before any early return, and the loss generation advances with it:
    // a later recovery of the status (or a call that changes nothing) never
    // revives it, and an admission already in flight (explicit or automatic)
    // that captured the earlier generation can never issue a replacement.
    _revokeConsentProof();
    if (isGuest || authMethod == null) return;
    if (value == SessionStatus.sessionExpired) return;
    value = SessionStatus.sessionExpired;
    if (kDebugMode) {
      debugPrint('[AppSession] session invalid/expired → sessionExpired');
    }
  }

  // ── Automatic Session Recovery host (design v7.2 §8–§11) ─────────────────

  /// The expiry evidence the last expiry fence of this process minted.
  ({String owner, String evidenceId})? _expiryEvidence;

  /// §7.7: `autoAdmissionBlocked = L` (the coordinator also holds it in
  /// process) and native `invalidateExpiryEvidence`. Synchronous start; the
  /// durable writes run behind it and are best-effort (the in-process bar
  /// holds when they cannot be confirmed).
  void _invalidateAsrEvidence() {
    final coord = AuthCoordinator.active;
    final owner = coord?.store.committed?.owner;
    final lifecycle = coord?.blockAutoAdmission();
    final known = _expiryEvidence;
    _expiryEvidence = null;
    if (coord == null && known == null) return;
    unawaited(() async {
      try {
        if (lifecycle != null) {
          await coord?.markAutoAdmissionBlocked(lifecycle: lifecycle);
        }
      } catch (_) {}
      final target = known?.owner ?? owner;
      if (target == null) return;
      try {
        final id = known?.evidenceId ??
            (await NativeCaptureBridge.inspectRecoveryEvidence(
                    ownerUid: target))
                ?.expiryEvidence
                ?.evidenceId;
        if (id != null) {
          await NativeCaptureBridge.invalidateExpiryEvidence(
              ownerUid: target, evidenceId: id);
        }
      } catch (_) {}
    }());
  }

  AsrAdoptionContext? _asrAdoption;
  bool _asrSuccessorRequested = false;
  Future<String?> Function(String owner)? _asrStorageDenial;

  /// E5/E6/E10/E11 storage reads (status-preserving), wired by bootstrap.
  /// Null denies every ASR attempt.
  void configureAsrEligibility(Future<String?> Function(String owner)? probe) {
    _asrStorageDenial = probe;
  }

  /// The owner of the verified, active local-read scope, or null.
  String? get asrLocalReadOwner =>
      localReadActive ? _localReadProof?.capability.uid : null;

  /// E8 (and the process part of E3/E5): synchronous. Before installation
  /// ([adopting] false) it also requires the active local read of [owner], no
  /// hold and no freeze; afterwards those are ASR's own and foreign changes
  /// arrive as causes.
  String? asrProcessDenial(String owner, {required bool adopting}) {
    final gate = CloudEgressGate.instance;
    final coord = AuthCoordinator.active;
    if (!adopting) {
      if (asrLocalReadOwner != owner) return 'local_read';
      if (gate.holdActive) return 'hold';
      if (ConsentAuthority.egressFrozen) return 'frozen';
    }
    if (_localReadLocked || localReadCleanupIncomplete) return 'local_read_lock';
    if (_explicitAdmissionEpoch != null) return 'explicit';
    if (_admissionClosed || (_removeData?.isRunning ?? false)) return 'closing';
    if (_logoutIncomplete) return 'logout_incomplete';
    if (_accountSwitchEpoch != null) return 'account_switch';
    if (_unresolvedOwnerUid != null || _pendingOwnerConflictUid != null) {
      return 'owner_unresolved';
    }
    if (_fenceIncomplete) return 'fence';
    if (gate.terminalDenied) return 'terminal';
    if (coord == null || coord.unattributedMutation) return 'unattributed';
    return null;
  }

  /// E3–E11 (read-only). Null when [owner] is eligible.
  Future<String?> asrEligibilityDenial(String owner) async {
    final process = asrProcessDenial(owner, adopting: false);
    if (process != null) return process;
    final probe = _asrStorageDenial;
    if (probe == null) return 'unwired';
    // E7: the durable grant is exactly the live capability's.
    final proof = _localReadProof;
    final auth = _localRead;
    if (proof == null || auth == null) return 'local_read';
    try {
      final record = await auth.peekRecordStrict();
      if (record == null ||
          record.state != LocalReadGrantState.committed ||
          record.uid != owner ||
          record.operationId != proof.capability.operationId ||
          record.replicaId != proof.capability.replicaId) {
        return 'grant';
      }
    } catch (_) {
      return 'grant';
    }
    final String? storage;
    try {
      storage = await probe(owner);
    } catch (_) {
      return 'storage';
    }
    if (storage != null) return storage;
    // E5: no removal in progress and [owner] not removed since its last
    // explicit admission (an unreadable record denies).
    final removal = _removeData;
    if (removal == null) return 'removal';
    try {
      if (await removal.hasPending() ||
          (await removal.revokedUids()).contains(owner)) {
        return 'removal';
      }
    } catch (_) {
      return 'removal';
    }
    // E3 Dart: no pending enable of anyone, confirmed.
    try {
      final pending = await CloudEgressGate.instance.readPending();
      if (pending.unreadable || pending.blocks(owner)) return 'pending';
    } catch (_) {
      return 'pending';
    }
    return asrProcessDenial(owner, adopting: false);
  }

  /// SE1 (§7.5): the successor publication is requested once, by the
  /// restrictive owner publication of the ASR adoption of [authority]'s uid.
  /// A session-only adoption (Cloud OFF) has no [evidenceId]: its publication
  /// is the plain restrictive one, still attributed to the op.
  ({String? evidenceId, int expectedCounter, Object causeAuthority})?
      asrSuccessorFor(
      AdmissionAuthority authority) {
    final ctx = _asrAdoption;
    if (ctx == null ||
        _asrSuccessorRequested ||
        authority.uid != ctx.owner ||
        !authority.isCurrent ||
        !ctx.mayProceed()) {
      return null;
    }
    _asrSuccessorRequested = true;
    return (
      evidenceId: ctx.evidence.evidence?.evidenceId,
      expectedCounter: ctx.evidence.counter,
      causeAuthority: ctx.authority,
    );
  }

  void _noteAsrSuccessorReceipt(
      String uid, _NativeLifetime lifetime, Object? answer) {
    final ctx = _asrAdoption;
    if (ctx == null ||
        !_asrSuccessorRequested ||
        ctx.successorGeneration != null ||
        uid != ctx.owner ||
        lifetime.binding == null ||
        answer is! RestrictiveCaptureOwnerReceipt) {
      return;
    }
    final counter = answer.phase.mutationCounter;
    final generation = answer.phase.ownerGeneration;
    final epoch = answer.phase.ownerEpoch;
    if (counter == null || generation == null || epoch == null) return;
    ctx
      ..successorGeneration = generation
      ..successorOwnerEpoch = epoch;
    ctx.evidence.counter = counter;
  }

  /// §7.5 SE3: the native lifetime this process fences is now the successor's
  /// enable transition; a later fence names exactly it (and stays idempotent
  /// against `retireSuccessor`, which retires under the same operation).
  bool asrRebindNativeLifetime(String owner, CloudEgressEnableBinding binding) {
    final lifetime = _nativeLifetime;
    final held = lifetime?.binding;
    if (lifetime == null ||
        held == null ||
        lifetime.lost ||
        lifetime.uid != owner ||
        held.ownerGeneration != binding.ownerGeneration ||
        held.ownerEpoch != binding.ownerEpoch) {
      return false;
    }
    lifetime.binding = binding;
    return true;
  }

  /// §9.7/§9.8: withdraws local read and admits [ctx.owner] writable through
  /// the automatic admission route, exempted only for this op.
  Future<AsrAdoptResult> asrAdopt(
      AsrAdoptionContext ctx, supabase.SupabaseClient client) async {
    if (!ctx.mayProceed() || asrLocalReadOwner != ctx.owner) {
      return AsrAdoptResult.notWithdrawn;
    }
    _asrAdoption = ctx;
    _asrSuccessorRequested = false;
    try {
      await _reconcileSupabaseSession(client.auth.currentSession,
          client: client, asr: ctx);
    } finally {
      _asrAdoption = null;
      _asrSuccessorRequested = false;
    }
    final scope = _accountScope?.activeScope;
    if (ctx.published &&
        ctx.mayProceed() &&
        value == SessionStatus.authenticated &&
        scope != null &&
        !scope.isLocalRead &&
        scope.uid == ctx.owner) {
      return AsrAdoptResult.published;
    }
    return asrLocalReadOwner == ctx.owner
        ? AsrAdoptResult.notWithdrawn
        : AsrAdoptResult.failedAfterWithdrawal;
  }

  /// §11.4 step 2: sign-in screen, data preserved — the replica is locked and
  /// local read durably denied (never wiped); the gate resolves signed out.
  Future<void> asrFailAfterWithdrawal(String owner) async {
    final host = _accountScope is AccountScopeHost
        ? _accountScope as AccountScopeHost
        : null;
    final adopted = host?.current;
    _authLossSeq++;
    markSessionInvalid(cause: SessionLossCause.other);
    try {
      await _denyLocalRead(uid: owner);
    } catch (_) {}
    // Phase 4 B1: a scope the adoption already opened writable is locked
    // (registry `locked`) and closed, and the signed-out scope published —
    // exactly that scope, nothing deleted. A local-read scope was locked above.
    if (host != null &&
        adopted != null &&
        adopted.uid == owner &&
        !adopted.isLocalRead) {
      try {
        await host.lockIfCurrent(adopted);
      } catch (_) {}
    }
    await CloudEgressGate.instance.resolveSignedOut();
  }

  /// Whether the onboarding completion of [session]'s account is known on
  /// this device (the condition under which no network read is needed).
  bool _onboardingKnownLocally(supabase.Session session) {
    final method = authMethod;
    if (method == null) return false;
    final remoteEmail = session.user.email;
    final accountKey = _accountKey(
        method: method,
        email: remoteEmail ?? email,
        userId: session.user.id);
    final fallbackKey = _identityKey(method, email);
    final sameIdentity = remoteEmail != null &&
        email != null &&
        remoteEmail.trim().toLowerCase() == email!.trim().toLowerCase();
    return _completedAccountKeys.contains(accountKey) ||
        (sameIdentity &&
            fallbackKey != null &&
            _completedAccountKeys.contains(fallbackKey));
  }

  @visibleForTesting
  void Function(supabase.AuthChangeEvent event)? debugAuthEventCompleted;

  Future<void> _handleSupabaseAuthChange(
    supabase.AuthState state,
    supabase.SupabaseClient client,
  ) async {
    try {
      // ASR §4.7: no admission from any event. The coordinator's own explicit,
      // install and alignment mutations are handled by the operation that made
      // them; an unattributed session-bearing mutation is restrictive.
      final coord = AuthCoordinator.active;
      if (coord != null) {
        final tag = coord.tagOf(state);
        switch (tag?.kind) {
          case AuthTagKind.explicit:
          case AuthTagKind.install:
          case AuthTagKind.alignment:
            return;
          case AuthTagKind.init:
            break;
          case AuthTagKind.unattributed:
          case null:
            if (state.session != null) {
              _authLossSeq++;
              _revokeDatabasePublication();
              _revokeConsentProof();
              _scheduleLocalReadTransition();
              if (_onboardingDone) markSessionInvalid();
              return;
            }
        }
      }
      switch (state.event) {
        case supabase.AuthChangeEvent.signedOut:
        case supabase.AuthChangeEvent.userDeleted:
          // A queued loss event must not invalidate a newer live SDK session.
          if (client.auth.currentSession?.isExpired == false) return;
          _authLossSeq++;
          _revokeConsentProof();
          // A server-driven auth loss is not an explicit request to destroy the
          // local-first database. It can be emitted during cold-start token
          // recovery, resume, revocation, or account deletion. With the old call
          // to signOut() here, every such emission wiped every user-scoped Drift
          // table, including settings and the persisted notification journey
          // state. Keep the encrypted local data owned by this UID and withhold
          // access until the user re-authenticates. Explicit UI logout still
          // calls signOut() directly, which LOCKS the replica (never wipes it).
          markSessionInvalid();
          // Unknown cause (or known revocation/deletion): lock + durable deny.
          await _denyLocalRead();
          return;
        case supabase.AuthChangeEvent.initialSession:
        case supabase.AuthChangeEvent.signedIn:
        case supabase.AuthChangeEvent.tokenRefreshed:
        case supabase.AuthChangeEvent.userUpdated:
          await _reconcileSupabaseSession(state.session, client: client);
          // A-5: an admitted authenticated session re-arms auth-parked sync rows.
          if (value == SessionStatus.authenticated) AuthSessionValid.notify();
          return;
        case supabase.AuthChangeEvent.passwordRecovery:
        case supabase.AuthChangeEvent.mfaChallengeVerified:
          return;
      }
    } finally {
      debugAuthEventCompleted?.call(state.event);
    }
  }

  Future<bool?> _reconcileSupabaseSession(
    supabase.Session? session, {
    required supabase.SupabaseClient client,
    AdmissionAuthority? authority,
    AsrAdoptionContext? asr,
    bool requireOnboardingResult = false,
  }) async {
    final databaseLoss = _databaseLossGeneration;
    if (isGuest || authMethod == null) return null;
    final epoch = _admissionEpoch;
    bool current() {
      final actual = client.auth.currentSession;
      return _admissionEpoch == epoch &&
          _explicitAdmissionEpoch == null &&
          (session == null
              ? actual == null
              : actual?.user.id == session.user.id &&
                  actual?.accessToken == session.accessToken);
    }

    if (!current()) return null;
    if (authority != null &&
        (!authority.isCurrent || authority.uid != session?.user.id)) {
      return null;
    }
    if (session != null && session.isExpired) {
      _revokeDatabasePublication();
      // A plain expiry (§7.2): native keeps its expiry evidence.
      _revokeConsentProof(expiry: true); // an expired SDK session proves nothing
      _scheduleLocalReadTransition();
      if (_onboardingDone) {
        markSessionInvalid(cause: SessionLossCause.sessionExpiry);
      }
      return null;
    }
    if (session == null) {
      _revokeDatabasePublication();
      _revokeConsentProof(); // no SDK session: the proof ends here
      // A null session here is only ambiguous mid-onboarding (identity set,
      // setup not finished yet) — that's already correctly `needsOnboarding`
      // and must be left alone. Once onboarding was actually completed once
      // before, a null session is unambiguous: the previously-valid Supabase
      // session is gone (refresh-token failure, revocation, expiry). Local
      // onboarding/account metadata is NOT sufficient by itself to grant
      // access — downgrade to sessionExpired so the router sends the user
      // back to sign-in, without erasing onboarding completion.
      _scheduleLocalReadTransition();
      // ASR §6.8/§9.9: a loaded `requiresAdoption` record serves nothing; that
      // null is ASR's wait, not a loss.
      if (_onboardingDone) {
        markSessionInvalid(
            cause: AuthCoordinator.active?.store.committed?.admission ==
                    AdmissionDisposition.requiresAdoption
                ? SessionLossCause.awaitingAdoption
                : SessionLossCause.other);
      }
      return null;
    }
    // ASR §4.7: every automatic admission route also requires the committed
    // record to be valid, ordinary and equal to SDK memory, with no explicit or
    // ASR exclusion. An exclusion only defers (the operation holding it
    // decides); anything else takes the existing no-session branch.
    final coord = AuthCoordinator.active;
    // ASR §9.7: only the adoption of the op holding the exclusion may admit its
    // own `requiresAdoption` record (and keep it through finalization).
    // The exemption lasts only while this op holds the exclusion: afterwards
    // (ordinary established, or AdoptionFailed) the ordinary rule decides.
    String? coordinatorDenial() {
      final ordinary = coord?.automaticAdmissionDenial();
      if (asr == null ||
          ordinary == null ||
          coord?.asrExclusion != asr.receipt.opId) {
        return ordinary;
      }
      return asr.mayProceed() ? coord?.asrAdoptionDenial(asr.receipt) : 'asr';
    }

    final denial = coordinatorDenial();
    if (denial == 'explicit_exclusion' || denial == 'asr_exclusion') return null;
    if (denial == AuthCoordinator.custodySuccessor) {
      // B10: the coordinator's own routine successor in custody, never an SDK
      // mutation and never a loss. The routine continuation installs it (under
      // the routine policy); its SDK event reconciles again.
      unawaited(coord?.refreshIfDue().catchError((Object _) => null));
      return null;
    }
    if (denial != null) {
      _revokeDatabasePublication();
      _revokeConsentProof();
      _scheduleLocalReadTransition();
      // Only `requiresAdoption` is ASR's wait (§4.7); every other denial is a
      // loss.
      if (_onboardingDone) {
        markSessionInvalid(
            cause: denial == 'requires_adoption'
                ? SessionLossCause.awaitingAdoption
                : SessionLossCause.other);
      }
      return null;
    }
    // Owner gate (MALI-002): never admit a UID while the local DB still holds
    // a different account's data. When the wipe hook isn't registered yet
    // (first reconcile runs before database_open), leave the coarse status
    // untouched — the boot loader is showing — and let bootstrap resolve the
    // conflict via resolvePendingLocalDataOwnerConflict, which re-enters here.
    final lossSeq = _authLossSeq;
    final consentLossSeq = _consentLossSeq;
    final uid = session.user.id;
    // ASR publishes only a returning user whose completion is known locally
    // (no network under the hold); anything else stays in local read.
    if (asr != null &&
        (uid != asr.owner || !_onboardingKnownLocally(session))) {
      return null;
    }
    // An automatic reconcile holds an open-existing authority captured NOW (or a
    // rebootstrap's maintenance authority); it never holds explicit authority.
    // Freshness remains part of the capability through every ownership await.
    // Epoch is checked by the authority (and may renew on an account switch).
    bool fresh() {
      final actual = client.auth.currentSession;
      return !session.isExpired &&
          actual?.user.id == uid &&
          actual?.accessToken == session.accessToken &&
          _explicitAdmissionEpoch == null &&
          coordinatorDenial() == null &&
          (authority == null || (authority.uid == uid && authority.isCurrent));
    }

    try {
      await _accountFence.guard(uid, current: current);
    } on AccountFenceDeniedException {
      if (current()) value = SessionStatus.sessionExpired;
      return null;
    } on StaleAdmissionException {
      return null;
    }
    final base = authority ?? _authorityAt(epoch, uid, canCreate: false);
    final guarded = AdmissionAuthority(
        uid, () => base.uid == uid && base.isCurrent && fresh(),
        canCreate: base.canCreate, epoch: base.epoch);
    final adm = _Admission(uid, guarded,
        sessionCurrent: fresh, asrCause: asr?.authority);
    final ownership = await _ensureLocalDataOwnedBy(uid, adm);
    if (lossSeq != _authLossSeq || !adm.current) return null; // lost or superseded
    if (ownership == LocalDataOwnership.revoked) return null;
    if (ownership == LocalDataOwnership.deferred) return null;
    if (ownership == LocalDataOwnership.unresolved) {
      // Fail closed: local data is preserved but must not be shown to an
      // identity whose ownership could not be verified. Route to sign-in.
      markSessionInvalid();
      return null;
    }
    // ASR §11.2: SE2/SE3 and P_publish between SE1 (the owner publication
    // above) and writable publication.
    if (asr != null &&
        (!await asr.beforePublication() ||
            lossSeq != _authLossSeq ||
            !adm.current)) {
      return null;
    }
    final remoteEmail = session.user.email;
    final previousEmail = email;
    final accountKey = _accountKey(
      method: authMethod!,
      email: remoteEmail ?? previousEmail,
      userId: session.user.id,
    );
    final fallbackKey = _identityKey(authMethod, previousEmail);
    final sameIdentity = remoteEmail != null &&
        previousEmail != null &&
        remoteEmail.trim().toLowerCase() == previousEmail.trim().toLowerCase();
    final localSetupRequired = _installPresentation?.requiresSetup ?? false;
    // Only the exact authenticated UID can reuse a surviving completion
    // record on a new installation. Legacy email keys are for ordinary reopen.
    final uidCompleted = _completedAccountKeys.contains(accountKey);
    var completed = localSetupRequired
        ? requireOnboardingResult && uidCompleted
        : uidCompleted ||
            (sameIdentity &&
                fallbackKey != null &&
                _completedAccountKeys.contains(fallbackKey));
    if (!completed &&
        asr == null &&
        (!localSetupRequired || requireOnboardingResult)) {
      // On a fresh install, the signed-in checkpoint checks completion after
      // language and welcome. Read outside admission so removal never waits
      // for network.
      final remoteCompleted = await _readRemoteOnboardingCompletion(
        client,
        session,
        authority: requireOnboardingResult ? adm.authority : null,
      );
      if (!adm.current || lossSeq != _authLossSeq) return null;
      if (remoteCompleted == null && requireOnboardingResult) {
        throw OnboardingStatusUnavailable(_lastOnboardingLookupError);
      }
      completed = remoteCompleted ?? false;
    }
    // The identity/status half is an admission operation: Remove data drains it,
    // and its authority is re-checked immediately before every write and before
    // the status publication.
    bool? publishedCompletion;
    await _admissionOp(() {
      final run = _identityTail.then((_) async {
        bool live() =>
            lossSeq == _authLossSeq &&
            adm.current &&
            _explicitAdmissionEpoch == null &&
            (asr?.mayProceed() ?? true);
        if (!live()) return;
        // A concurrent reconciliation may have verified this same account while
        // this lookup was in flight. Keep that durable completion.
        final accountCompleted = completed ||
            (_installPresentation?.requiresSetup != true &&
                _completedAccountKeys.contains(accountKey));
        await _storage.write(key: _kCurrentAccount, value: accountKey);
        if (!live()) return;
        if (accountCompleted && !_completedAccountKeys.contains(accountKey)) {
          final keys = {..._completedAccountKeys, accountKey}.toList()..sort();
          await _storage.write(
              key: _kCompletedAccounts, value: jsonEncode(keys));
          if (!live()) return;
        }
        if (remoteEmail != null && remoteEmail.trim().isNotEmpty) {
          await _storage.write(key: _kEmail, value: remoteEmail);
          if (!live()) return;
        }
        if (accountCompleted && localSetupRequired) {
          await _installPresentation?.completeSetup();
          if (!live()) return;
        }
        _currentAccountKey = accountKey;
        if (accountCompleted) _completedAccountKeys.add(accountKey);
        _onboardingDone = accountCompleted;
        if (remoteEmail != null && remoteEmail.trim().isNotEmpty) {
          email = remoteEmail;
        }
        // The account switch (if this admission was one) stays closed through
        // every async identity write above; it reopens HERE, in the same
        // synchronous step as the status publication, and only for the very
        // epoch that owns it. A failed or older admission never gets here.
        if (_accountSwitchEpoch != null &&
            _accountSwitchEpoch == adm.authority.epoch) {
          _accountSwitchEpoch = null;
        }
        value = accountCompleted
            ? SessionStatus.authenticated
            : SessionStatus.needsOnboarding;
        // ValueNotifier listeners may have revoked authority synchronously.
        if (!live()) return;
        notifyListeners();
        if (!live()) return;
        _recordDatabaseIdentityPublication(databaseLoss);
        asr?.published = accountCompleted;
        publishedCompletion = accountCompleted;
        // The committed, guarded automatic publication is the other place a
        // consent proof is issued (a returning, already-authenticated user): the
        // evidence is the REAL SDK session of this client for exactly this uid.
        if (adm.current && _explicitAdmissionEpoch == null) {
          _issueConsentCapability(adm,
              method: authMethod ?? '',
              sdkFresh: () => _sdkSessionFresh(uid, client),
              // No token-identity predicate: a routine token refresh keeps the
              // same lifecycle and must not revoke an operation in flight. The
              // evidence is the live SDK session of exactly this uid; a loss is
              // revoked synchronously at its origin.
              sessionCurrent: null,
              authLossSeq: lossSeq,
              consentLossSeq: consentLossSeq);
        }
      });
      _identityTail = run.then<void>((_) {}, onError: (Object _) {});
      return run;
    }, current: () => lossSeq == _authLossSeq && adm.current &&
        _explicitAdmissionEpoch == null);
    if (!adm.current || lossSeq != _authLossSeq ||
        _explicitAdmissionEpoch != null) {
      return null;
    }
    _commitDatabasePublication(databaseLoss);
    return publishedCompletion;
  }

  Object? _lastOnboardingLookupError;

  Future<bool?> _readRemoteOnboardingCompletion(
    supabase.SupabaseClient client,
    supabase.Session session, {
    AdmissionAuthority? authority,
  }) async {
    _lastOnboardingLookupError = null;
    try {
      Future<bool> read() async {
        final row = await client
            .from('profiles')
            .select('onboarding_completed_at')
            .eq('id', session.user.id)
            .maybeSingle()
            .retry(enabled: false)
            .timeout(const Duration(seconds: 8));
        return row?['onboarding_completed_at'] != null;
      }

      if (authority == null) return await read();
      return await CloudEgressGate.instance.runAccountControl(
        AccountControlOp.onboardingStatus,
        read,
        onboarding: (authority: authority, accessToken: session.accessToken),
      );
    } catch (error) {
      _lastOnboardingLookupError = error;
      // An unavailable lookup is distinct from confirmed incomplete setup.
      // Interactive sign-in can retry, while automatic startup keeps its fallback.
      if (kDebugMode) {
        debugPrint(
          '[AppSession] remote onboarding lookup skipped: '
          '${error.runtimeType}',
        );
      }
      return null;
    }
  }

  String _accountKey({
    required String method,
    String? email,
    String? userId,
  }) {
    final cleanUserId = userId?.trim();
    if (cleanUserId != null && cleanUserId.isNotEmpty) {
      return 'uid:$cleanUserId';
    }
    return _identityKey(method, email) ?? 'method:$method';
  }

  String? _identityKey(String? method, String? email) {
    if (method == null) return null;
    final cleanEmail = email?.trim().toLowerCase();
    if (cleanEmail != null && cleanEmail.isNotEmpty) {
      return '$method:$cleanEmail';
    }
    if (method == 'guest') return 'guest';
    return null;
  }

  Future<Set<String>> _readCompletedAccountKeys() async {
    final raw = await _storage.read(key: _kCompletedAccounts);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _persistCompletedAccountKeys() {
    final values = _completedAccountKeys.toList()..sort();
    return _storage.write(
      key: _kCompletedAccounts,
      value: jsonEncode(values),
    );
  }

  /// B15 — the ONE full-reset sequence (Settings "erase all data", Privacy
  /// account deletion). WP-3b: the database step is the §4.4 Remove-data flow
  /// ([removeDataFromDevice]: the admission generation is invalidated FIRST, then
  /// the uid's replica, key and native residue are deleted); then [wipeAndReset];
  /// and finally the remote auth sign-out ([signOutRemote], best effort — the
  /// local removal already protects the device if the network call fails). A
  /// removal that cannot be confirmed throws before anything else runs.
  Future<void> resetAllLocalData({
    Future<void> Function()? signOutRemote,
  }) async {
    await removeDataFromDevice();
    await wipeAndReset();
    if (signOutRemote != null) {
      try {
        await signOutRemote();
      } catch (_) {
        // Local reset above is authoritative.
      }
    }
  }

  /// حذف الحساب وكل البيانات المحلية (Privacy → حذف كل بياناتي).
  Future<void> wipeAndReset() async {
    _revokeDatabasePublication();
    // The authority loss is synchronous, before the first await below.
    _revokeConsentProof();
    _accountFenceOwner = null;
    // MALI-054n/070n: purge native + filesystem capture residue as part of the
    // full reset (account deletion / reset-all), BEFORE the secure-storage wipe
    // drops the owner marker — otherwise leftover native captures could be
    // imported by the next identity that null-claims the reset device.
    await _runOwnerClear();
    // Audit H-8. The SQLCipher key must survive this wipe: the caller empties
    // the DB tables, but the encrypted FILE stays on disk, so destroying its key
    // would orphan that file and make the database unopenable next launch
    // ("تعذّر فتح بياناتك").
    //
    // This used to be `read(dbKey) → deleteAll() → write(dbKey)`, which left a
    // window where the database existed with no key. A crash or a failing write
    // in that window destroyed the data irreversibly. The key is now NEVER
    // deleted, so that state is unreachable by construction; an interruption
    // can only leave some non-key entries behind, which re-running clears.
    final wipe = await wipeSecureStoragePreservingDatabaseKey(
      readAll: () => _storage.readAll(),
      delete: (key) => _storage.delete(key: key),
      knownKeys: sessionStorageKeys,
    );
    authMethod = null;
    email = null;
    _onboardingDone = false;
    _welcomeManifestoSeen = false;
    _languageChoiceMade = false;
    _currentAccountKey = null;
    _completedAccountKeys.clear();
    _unresolvedOwnerUid = null;
    _revokeConsentProof();
    // A full local reset leaves the device signed out: nothing remains of an
    // unfinished logout's old authority to protect.
    _logoutIncomplete = false;
    value = SessionStatus.needsOnboarding;
    // In-memory state is signed-out first, so a reported failure still leaves
    // the app in a safe state — but the failure IS reported: a wipe that left
    // credentials or backup material behind must not look like success.
    if (!wipe.isComplete) {
      throw SecureStorageWipeIncompleteException(wipe.failed.length);
    }
  }
}
