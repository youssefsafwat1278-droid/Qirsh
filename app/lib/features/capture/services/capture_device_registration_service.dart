import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/observability/diagnostics.dart';
import '../../../core/privacy/cloud_egress_gate.dart';
import '../../../core/privacy/cloud_resume_reminder.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/session/consent_capability.dart';
import '../../../core/sync/sync_wakeup.dart';
import '../../../core/utils/install_id.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/supporting_entities.dart';
import '../../planning_sync/services/outbox_queue_factory.dart'
    show localDataOwnerUid;
import 'capture_backend_client.dart';
import 'capture_consent_client.dart';
import 'native_capture_bridge.dart';
import '../../../core/security/secure_storage_options.dart';

typedef NativeBackendConfigWriter = Future<void> Function({
  required bool cloudProcessingEnabled,
  required String installId,
  String? deviceSecret,
  required String backendUrl,
  required String anonKey,
  required bool aiConsentGranted,
  String? ownerUid,
  int? transitionGeneration,
});

typedef ApnsTokenLoader = Future<ApnsTokenInfo?> Function();

/// WP-6: the signed-in user as the capture backend sees it.
typedef CaptureSession = ({String uid, String jwt});

typedef ConsentMirrorWriter = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
  int? transitionGeneration,
});

/// A-12-min R4: publishes the owner together with its consent mirror in one
/// native flock, compare-and-swap on [expectedEpoch].
typedef OwnerPublisher = Future<void> Function({
  required String uid,
  required bool cloud,
  required bool ai,
  required int version,
  required int expectedEpoch,
  int? transitionGeneration,
});

/// A-12.4 / E1 / Astra G C.3 — the single one-shot revoke
/// (`revoke_capture_consent`, JWT) sent as the ONLY control-plane exception while
/// DISABLING, inside [CaptureDeviceRegistrationService.disableCloud]. Set this to
/// false to drop it: the transition then only freezes and commits OFF with zero
/// requests, and already-stored server content is left to CAP-3 retention.
const bool kRevokeAtCloudSwitchOff = true;

/// Upper bound on the one revoke request. The user is waiting on the toggle and
/// OFF is committed only after the request settles, so the bound must be short;
/// 5 s covers a normal mobile round trip of this tiny content-free call, and a
/// slower server is covered by CAP-3 retention. Timing out never blocks OFF.
const Duration kCloudOffRevokeTimeout = Duration(seconds: 5);

/// Approved 2026-11-12 (product owner): a revoke whose one-shot send did not
/// land is retried with this bounded backoff (the last step repeats) until the
/// server answers, a newer grant supersedes it, or it can never apply. Only the
/// revoke itself is retried (identifiers only), only for its own signed-in
/// owner, and only while Cloud stays OFF at that revoke's generation
/// ([CloudEgressGate.runRevokeRetry]). Local AI never reopens because of it.
const List<Duration> kRevokeRetryBackoff = [
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
];

/// WP-6: the consent the replica holds, as projected to the server and to the
/// native mirror. Derived ONLY from the replica's own explicit, versioned choice
/// (cloud is the master gate, so AI is on only when cloud is on); never from a
/// server value.
typedef _ConsentSnapshot = ({bool cloud, bool ai, int version});

/// P4: what an async mutation captured when it started. Every write after an
/// await re-checks it ([CaptureDeviceRegistrationService._holds]): the
/// in-process epoch (advanced by disable / enable / account transitions /
/// sign-out), the session uid and the replica owner must all be unchanged.
typedef _Tx = ({
  int epoch,
  String? sessionUid,
  String? owner,
  bool Function() current
});

/// The persistent gate as the registration service needs it.
enum _Gate { open, off, blocked }

/// C.3 / C.4: the outcome of the one-shot revoke. NOT_ATTEMPTED = nothing was
/// sent (no frozen-owner JWT, ack or secret, or no durable attempt record);
/// UNCONFIRMED = it was sent (or may have been) and no `applied` answer came
/// back; CONFIRMED = the server answered `{ok, applied}`. Never a claim that
/// content was nulled or that work stopped.
enum ServerRevocation { confirmed, unconfirmed, notAttempted }

/// Thrown by [CaptureDeviceRegistrationService.disableCloud] when the UI must
/// NOT be told that OFF succeeded (DISABLING could not be made durable, or the
/// owner changed under the transition).
class CloudDisableException implements Exception {
  const CloudDisableException(this.reason);
  final String reason;
  @override
  String toString() => 'CloudDisableException($reason)';
}

/// Thrown by [CaptureDeviceRegistrationService.enableCloud] when Cloud was NOT
/// turned on and the user must be told so ("couldn't turn on, try again"): the
/// native/Dart transition was refused, failed or could not be confirmed. Cloud
/// stays denied (a durable pending denial remains whenever the outcome is
/// uncertain). [reason] is a coarse code only, never an exception message, uid,
/// secret or URL. A lifecycle that ended meanwhile is reported as
/// [StaleAdmissionException] instead (nothing is shown into the live scope).
class CloudEnableIncompleteException implements Exception {
  const CloudEnableIncompleteException(this.reason);
  final String reason;
  @override
  String toString() => 'CloudEnableIncompleteException($reason)';
}

/// Thrown when an explicit Turn on is asked over a stored Cloud ON whose live
/// authority cannot be verified and no exactly resumable pending enable exists
/// (native unset, OFF or unreadable, a corrupt or disagreeing layer, a pending
/// operation of another reserved version). Nothing was written and nothing was
/// sent; a plain settings save is never proof that a native enable completed.
/// The person must turn the permission off (the verified restrictive disable)
/// before it can be turned on again. [reason] is a coarse code only.
class CloudEnableWithdrawFirstException implements Exception {
  const CloudEnableWithdrawFirstException([this.reason = 'withdraw_first']);
  final String reason;
  @override
  String toString() => 'CloudEnableWithdrawFirstException($reason)';
}

/// R17/R18 — the state of this owner's pending explicit enable relative to the
/// stored consent row (see [CaptureDeviceRegistrationService.pendingEnableState]).
enum PendingEnableState {
  /// No pending enable of this owner anywhere.
  none,

  /// Exactly one operation, consistent in every layer, reserved at exactly the
  /// version the stored row implies: an explicit Turn on can resume it.
  resumable,

  /// Anything else (conflicting, corrupt, unreadable, mismatched or stale
  /// layers, another version, an enable still running): no Turn on; the only
  /// way out is the verified withdrawal.
  unresolved,
}

/// R18 — thrown by [CaptureDeviceRegistrationService.withdrawPendingEnable]
/// when the withdrawal could not be verified. Egress stays denied and whatever
/// pending evidence could not be proven cleared stays in place; the person is
/// told it did not finish. [reason] is a coarse code only.
class CloudWithdrawIncompleteException implements Exception {
  const CloudWithdrawIncompleteException(this.reason);
  final String reason;
  @override
  String toString() => 'CloudWithdrawIncompleteException($reason)';
}

/// R17 — thrown by the explicit choice protocol when the operation that ran
/// (an exact resume of an older pending enable) did not persist the choice the
/// person asked for. [persisted] is the row actually stored; nothing requested
/// beyond it was saved, and no success path may act on the request.
class ConsentChoiceNotPersistedException implements Exception {
  const ConsentChoiceNotPersistedException(this.persisted);
  final UserSettingsEntity persisted;
  @override
  String toString() => 'ConsentChoiceNotPersistedException()';
}

/// How an explicit consent choice must reach durable state, chosen from the
/// stored choice AND the live/pending authority (see
/// [CaptureDeviceRegistrationService.explicitEnableRoute]).
enum ExplicitEnableRoute {
  /// Cloud is not stored ON: the durable explicit enable (a fresh one, or the
  /// exact resume of this owner's pending operation, decided inside it).
  enable,

  /// Cloud is stored ON and a pending enable of exactly the stored reserved
  /// version exists: the durable enable resumes that operation (no second save).
  resumePending,

  /// No Cloud widening: either Cloud stays OFF, or Cloud is stored ON AND its
  /// live ON is verified in every layer, so the change cannot claim an enable.
  plainSave,

  /// Stored ON without a verifiable live enable: refuse; withdraw first.
  withdrawFirst,
}

class _RevokeInputs {
  const _RevokeInputs(this.installId, this.secret, this.jwt);
  final String installId;
  final String secret;
  final String jwt;
}

/// Two independent durable copies of one small record (secure storage + file).
class _DualSlot {
  _DualSlot(this._a, this._b);
  final DurableSlot _a;
  final DurableSlot _b;

  Future<bool> write(String value) async {
    var ok = false;
    try {
      await _a.write(value);
      ok = true;
    } catch (_) {}
    try {
      await _b.write(value);
      ok = true;
    } catch (_) {}
    return ok;
  }

  Future<String?> read() async {
    final a = await _a.read();
    if (a.status == SlotStatus.value) return a.raw;
    final b = await _b.read();
    return b.status == SlotStatus.value ? b.raw : null;
  }
}

/// Per-run outcome, so overlapping syncs can never pollute each other.
class _SyncOutcome {
  bool registerFailed = false;
  bool consentPushFailed = false;
}

enum CaptureRegistrationPhase { notRequested, connecting, connected, failed }

/// User-visible device-registration state. [failureCode] is a coarse code only
/// ('register_failed', 'consent_sync_failed', 'unknown') — never an exception
/// message, secret, install id or URL.
@immutable
class CaptureRegistrationStatus {
  const CaptureRegistrationStatus(this.phase, [this.failureCode]);

  final CaptureRegistrationPhase phase;
  final String? failureCode;

  @override
  bool operator ==(Object other) =>
      other is CaptureRegistrationStatus &&
      other.phase == phase &&
      other.failureCode == failureCode;

  @override
  int get hashCode => Object.hash(phase, failureCode);
}

/// P3: a sign-out's one-shot unlink of this install from the outgoing user,
/// captured synchronously BEFORE the session's authority is revoked
/// ([CaptureDeviceRegistrationService.takeUnlinkTicket]). [send] posts the same
/// `unlink-capture-device` request as
/// [CaptureDeviceRegistrationService.unlinkCurrentDevice] (install id + device
/// secret, no user JWT) without the capture gate: the unlink only narrows server
/// state (it nulls the user/APNs association), so the revoked authority the gate
/// checks is not needed. No 401 recovery (that would register a new credential).
class CaptureUnlinkTicket {
  CaptureUnlinkTicket._(this.uid, this._send);

  /// The user the install is unlinked from.
  final String uid;
  final Future<void> Function() _send;

  /// Hands the request to the HTTP client synchronously (no await before it),
  /// then forgets the acknowledgement if it is still [uid]'s.
  Future<void> send() => _send();
}

typedef _UnlinkTarget = ({
  String uid,
  String installId,
  String secret,
  CaptureDeviceRegistrationService service,
});

class CaptureDeviceRegistrationService {
  CaptureDeviceRegistrationService({
    required DriftUserSettingsRepository settingsRepository,
    CaptureBackendClient? client,
    FlutterSecureStorage? storage,
    bool Function()? isIos,
    bool Function()? isAndroid,
    bool Function()? isBackendConfigured,
    Future<String> Function()? loadInstallId,
    NativeBackendConfigWriter? writeNativeBackendConfig,
    NativeBackendConfigWriter? writeRestrictiveNativeBackendConfig,
    ApnsTokenLoader? loadApnsToken,
    CaptureConsentClient? consentClient,
    CaptureSession? Function()? readSession,
    Future<String?> Function()? readReplicaOwnerUid,
    ConsentMirrorWriter? writeConsentMirror,
    OwnerPublisher? publishOwner,
    Future<bool> Function(String uid)? repairOwnerGeneration,
    Future<int> Function()? readOwnerEpoch,
    Future<CaptureOwnerRecord?> Function()? readCaptureOwner,
    Future<NativeEgressWithdrawal?> Function(String ownerUid)?
        withdrawNativeEgress,
    bool revokeAtSwitchOff = kRevokeAtCloudSwitchOff,
    Duration revokeTimeout = kCloudOffRevokeTimeout,
    List<Duration> revokeRetryBackoff = kRevokeRetryBackoff,
    DateTime Function()? now,
    Future<Directory> Function()? markerDirectory,
    CloudEgressGate? gate,
    bool Function()? isCurrentScope,
    AdmissionAuthority? Function()? captureWorkAuthority,
  })  : _isCurrentScope = isCurrentScope ?? (() => true),
        _captureWorkAuthority = captureWorkAuthority ??
            (readSession == null
                ? AppSession.instance.captureLocalWorkAuthority
                : (() => null)),
        _requiresAdmission =
            readSession == null || captureWorkAuthority != null,
        _initializationEpoch = (gate ?? CloudEgressGate.instance).epoch,
        _gateOverride = gate,
        _revokeAtSwitchOff = revokeAtSwitchOff,
        _revokeTimeout = revokeTimeout,
        _revokeRetryBackoff = revokeRetryBackoff,
        _now = now ?? DateTime.now,
        _markerDirectory = markerDirectory ?? getApplicationSupportDirectory,
        _settingsRepository = settingsRepository,
        _client = client,
        _storage = storage ?? SecureStorageOptions.storage,
        _isIos = isIos ?? (() => Platform.isIOS),
        _isAndroid = isAndroid ?? (() => Platform.isAndroid),
        _isBackendConfigured =
            isBackendConfigured ?? (() => SupabaseConfig.isConfigured),
        _loadInstallId = loadInstallId ?? InstallId.get,
        _writeNativeBackendConfig =
            writeNativeBackendConfig ?? NativeCaptureBridge.setBackendConfig,
        // N-R8: the restriction receipt must be a real native acknowledgment, so
        // its default propagates a missing method (the ordinary writer swallows
        // it). A caller that injects only [writeNativeBackendConfig] stands in
        // for both.
        _writeRestrictiveBackendConfig = writeRestrictiveNativeBackendConfig ??
            writeNativeBackendConfig ??
            NativeCaptureBridge.setBackendConfigAcknowledged,
        _loadApnsTokenOverride = loadApnsToken,
        _consentClient = consentClient,
        _readSession = readSession ?? _defaultReadSession,
        _readReplicaOwnerUid = readReplicaOwnerUid ?? localDataOwnerUid,
        _writeConsentMirror =
            writeConsentMirror ?? NativeCaptureBridge.setCaptureConsentMirror,
        _publishOwner = publishOwner ?? NativeCaptureBridge.publishCaptureOwner,
        _repairOwnerGeneration = repairOwnerGeneration ?? _defaultRepairOwnerGeneration,
        _readOwnerEpoch =
            readOwnerEpoch ?? NativeCaptureBridge.captureOwnerEpoch,
        _readCaptureOwner =
            readCaptureOwner ?? NativeCaptureBridge.getCaptureOwner,
        _withdrawNativeEgress = withdrawNativeEgress ??
            ((uid) => NativeCaptureBridge.withdrawCloudEgress(ownerUid: uid));

  static const _secretKey = 'qirsh_capture_device_secret';

  /// WP-6: the last consent the server ACKNOWLEDGED for this install, as
  /// `uid|cloud|ai|version` (single slot). It proves the projection is linked to
  /// that uid at that version, which lets a repeat admission skip the network
  /// call, and it is the floor for a restrictive-first mirror write. Cleared on
  /// unlink and whenever the device credential is replaced.
  static const _ackKey = 'qirsh_capture_consent_ack';
  static const _verifiedAckKey = 'qirsh_capture_consent_verified_ack';
  static const _grantAttemptKey = 'qirsh_capture_consent_grant_attempt';

  /// C.4: the durable, consumed `revoke_attempt = {owner, transition_generation,
  /// consumed: true}`, written BEFORE the single send and SEPARATE from the
  /// DISABLING record (`disable_pending` is the `cloud_egress_state` DISABLING
  /// record of [CloudEgressGate]). Nothing ever replays it: a crash after this
  /// write means the revoke is never sent (the status is then UNCONFIRMED).
  static const _revokeAttemptKey = 'qirsh.capture_revoke_attempt.v1';
  static const _revokeAttemptFile = 'capture_revoke_attempt.v1';

  /// `{owner, transition_generation, status}` of the last revoke outcome,
  /// exposed read-only through [serverRevocation].
  static const _serverRevocationKey = 'qirsh.capture_server_revocation.v1';
  static const _serverRevocationFile = 'capture_server_revocation.v1';

  /// Revokes the server has not confirmed yet, per owner:
  /// `{owner: {g: transition_generation, v: consent_version, n: attempts,
  /// at: next attempt (epoch ms)}}`. Written BEFORE the one-shot send, removed
  /// once the server answered or a newer grant superseded it. Identifiers only.
  static const _pendingRevocationKey = 'qirsh.capture_pending_revocation.v1';
  static const _pendingRevocationFile = 'capture_pending_revocation.v1';

  /// One transition at a time, process-wide (the UI and startup own different
  /// service instances).
  static Future<void>? _disableInFlight;
  static Future<void>? _enableInFlight;

  /// R18 / N-CR-2: advanced synchronously, PER OWNER, by every withdrawal of a
  /// pending enable whose capability is current. An enable of that owner that
  /// captured an older value has lost its authority at its next check (it
  /// compensates and reports staleness), so it can never finish over the
  /// withdrawal. A withdrawal never advances it before its own authority is
  /// validated, and never for another owner's enable.
  static final Map<String, int> _withdrawalEpochs = {};
  static int _withdrawalEpochOf(String uid) => _withdrawalEpochs[uid] ?? 0;

  /// P3: what a sign-out needs to unlink this install from the user it is
  /// linked to, known in memory (process-wide: the UI and startup own different
  /// instances) from the moment a Cloud-ON link ack is written or confirmed.
  /// Dropped wherever the ack is cleared. A Cloud-OFF install never has one, so
  /// its sign-out sends nothing.
  static _UnlinkTarget? _unlinkTarget;

  /// Advanced by every clear/take, so an arm whose storage reads straddle one
  /// never re-arms a target that was already dropped.
  static int _unlinkTargetSeq = 0;

  @visibleForTesting
  static void debugResetUnlinkTarget() => _disarmUnlink();

  static void _disarmUnlink() {
    _unlinkTarget = null;
    _unlinkTargetSeq++;
  }

  /// P3: synchronously takes (and forgets) the pending unlink target. Null when
  /// this install has no Cloud-ON link (Cloud OFF, never linked, already
  /// unlinked). [AppSession.signOut] takes it before it revokes anything.
  static CaptureUnlinkTicket? takeUnlinkTicket() {
    final target = _unlinkTarget;
    _disarmUnlink();
    if (target == null) return null;
    return CaptureUnlinkTicket._(target.uid, () {
      final svc = target.service;
      // The same request as [unlinkCurrentDevice], no 401 recovery. Sign-out
      // has already set the lifecycle fence, so it runs under the gate's
      // narrow unlink grant (only this POST, only narrowing server state).
      final request = svc._gate.runDeviceUnlink(
          target.uid,
          () => svc._backendClient.unlinkDevice(
                installId: target.installId,
                deviceSecret: target.secret,
              ));
      final forget = svc._forgetAckOf(target.uid);
      return Future.wait([request, forget]).then((_) {});
    });
  }

  /// Arms the unlink target for [uid] after its Cloud-ON ack was written or
  /// confirmed. [seq] is [_unlinkTargetSeq] as read before that ack was.
  Future<void> _armUnlink(String uid, int seq) async {
    try {
      if (!_isIos() || !_isBackendConfigured()) return;
      final installId = await _loadInstallId();
      final secret = await _storage.read(key: _secretKey);
      if (seq != _unlinkTargetSeq || secret == null || secret.isEmpty) return;
      _unlinkTarget =
          (uid: uid, installId: installId, secret: secret, service: this);
      AppSession.instance
          .configureCaptureUnlinkTicket(() => takeUnlinkTicket()?.send);
    } catch (_) {
      // Best effort: without a target the sign-out simply sends nothing.
    }
  }

  /// Deletes the ack only while it is still [uid]'s (a successor may already
  /// have linked). Never touches the in-memory target.
  Future<void> _forgetAckOf(String uid) async {
    try {
      final ack = await _readAckAny();
      if (ack != null && ack.uid == uid) {
        await _storage.delete(key: _ackKey);
        await _storage.delete(key: _verifiedAckKey);
      }
    } catch (_) {}
  }

  final DriftUserSettingsRepository _settingsRepository;
  final bool Function() _isCurrentScope;
  final AdmissionAuthority? Function() _captureWorkAuthority;
  final bool _requiresAdmission;
  bool _disposed = false;
  int _initializationEpoch;

  /// Provider teardown retires this instance even if the same DB is reused.
  void dispose() {
    _disposed = true;
    _syncGeneration++;
    _revokeRetryTimer?.cancel();
    _revokeRetryTimer = null;
    consentServerRevision.dispose();
  }

  bool Function() _captureLifetime({
    bool requireAdmission = false,
    bool initializing = false,
    AdmissionAuthority? admissionAuthority,
  }) {
    final uid = _readSession()?.uid;
    final authority = admissionAuthority ?? _captureWorkAuthority();
    return () =>
        !_disposed &&
        _settingsRepository.isDatabaseOpen &&
        (initializing || _isCurrentScope()) &&
        _readSession()?.uid == uid &&
        (authority?.isCurrent ?? !(_requiresAdmission && requireAdmission)) &&
        (authority == null || authority.uid == uid);
  }

  final CaptureBackendClient? _client;
  final FlutterSecureStorage _storage;
  final bool Function() _isIos;
  final bool Function() _isAndroid;
  final bool Function() _isBackendConfigured;
  final Future<String> Function() _loadInstallId;
  final NativeBackendConfigWriter _writeNativeBackendConfig;
  final NativeBackendConfigWriter _writeRestrictiveBackendConfig;
  final ApnsTokenLoader? _loadApnsTokenOverride;
  final CaptureConsentClient? _consentClient;
  final CaptureSession? Function() _readSession;
  final Future<String?> Function() _readReplicaOwnerUid;
  final ConsentMirrorWriter _writeConsentMirror;
  final OwnerPublisher _publishOwner;
  final Future<bool> Function(String uid) _repairOwnerGeneration;
  final Future<NativeEgressWithdrawal?> Function(String ownerUid)
      _withdrawNativeEgress;

  /// The diagnostic of the last native withdrawal in this process (constant
  /// strings and counts only).
  @visibleForTesting
  static String lastNativeWithdrawal = '';

  /// Fail-closed native gate (iOS): restricts every native content upload
  /// path of [owner] BEFORE any other step of a withdrawal, so no new SMS
  /// upload or AI request can start from the App Intent / Shortcuts / share
  /// handoff even if a later consent-state write fails. Restrictive and
  /// owner-scoped only; never throws. Returns whether native now denies.
  Future<bool> _withdrawNativeFirst(String? owner, String stage) async {
    if (!_isIos() || owner == null || owner.isEmpty) return false;
    NativeEgressWithdrawal? report;
    try {
      report = await _withdrawNativeEgress(owner);
    } catch (_) {}
    lastNativeWithdrawal =
        '$stage:${report?.diagnostic ?? 'native_withdraw_failed'}';
    debugPrint('[ConsentDisable] native_withdraw $lastNativeWithdrawal');
    return report?.denies ?? false;
  }

  /// D-SO1: a start-up reconciliation that aligns Cloud consent DOWN must close
  /// the native upload paths BEFORE it completes: the App Intent decides from
  /// the native consent mirror alone, so a downgrade Dart keeps to itself leaves
  /// SMS uploads running while the app shows Cloud as off.
  ///
  /// [record] is why the downgrade happens: `missing` (no activation record),
  /// `disabled` (an OFF record) or `new_lifetime`. Returns false when native
  /// could not be confirmed closed; the caller then keeps Dart egress frozen.
  /// The release log line carries constants only (no uid, no content).
  Future<bool> _closeNativeForDowngrade(String owner, String record,
      {required bool settingsOn}) async {
    // No native lane (Android) or no owner: native holds nothing to close for
    // this account (an ownerless capture is never admitted for upload).
    if (!_isIos() || owner.isEmpty) return true;
    final closed = await _withdrawNativeFirst(owner, 'reconcile_record_$record');
    Diag.log(
        '[ConsentDisable]',
        'reconcile_downgrade record=$record settings=${settingsOn ? 'on' : 'off'} '
            'native=${closed ? 'closed' : 'unconfirmed'}');
    return closed;
  }

  /// Once per process: the OFF + missing-record state is re-closed natively.
  bool _missingRecordNativeClosed = false;

  static Future<bool> _defaultRepairOwnerGeneration(String uid) async =>
      await NativeCaptureBridge.repairActiveOwnerGeneration(uid: uid) != null;
  final Future<int> Function() _readOwnerEpoch;
  final Future<CaptureOwnerRecord?> Function() _readCaptureOwner;
  final bool _revokeAtSwitchOff;
  final Duration _revokeTimeout;
  final List<Duration> _revokeRetryBackoff;
  final DateTime Function() _now;
  Timer? _revokeRetryTimer;
  Future<void>? _revokeRetryInFlight;
  final CloudEgressGate? _gateOverride;

  /// App-support directory for the file copies of the revoke records.
  final Future<Directory> Function() _markerDirectory;
  Future<bool>? _linkInFlight;
  ({String? uid, int? epoch})? _linkAdmission;
  final Map<String, int> _mirrorVersions = {};
  Future<String>? _credentialRecovery;
  Future<void>? _apnsSyncInFlight;
  String? _lastSyncedApnsTokenKey;
  DateTime? _apnsRetryBlockedUntil;

  final ValueNotifier<CaptureRegistrationStatus> _status = ValueNotifier(
    const CaptureRegistrationStatus(CaptureRegistrationPhase.notRequested),
  );
  int _syncGeneration = 0;

  ValueListenable<CaptureRegistrationStatus> get status => _status;

  final ValueNotifier<int> consentServerRevision = ValueNotifier(0);

  Future<bool> serverConsentMatches(UserSettingsEntity settings) async {
    if (!_isBackendConfigured() || (!_isIos() && !_isAndroid())) return true;
    final current = _captureLifetime();
    final owner = _readSession()?.uid;
    if (owner == null || !current()) return false;
    try {
      return await _hasVerifiedAck(owner, _snapshotOf(settings)) && current();
    } catch (_) {
      return false;
    }
  }

  Future<bool> serverOffUnconfirmed(String owner, int generation) async {
    final pending = await _readPendingRevocations();
    if (pending[owner]?['g'] == generation) return true;
    final raw = await _serverRevocationSlots.read();
    if (raw == null) return false;
    final record = jsonDecode(raw);
    return record is Map &&
        record['owner'] == owner &&
        record['transition_generation'] == generation &&
        record['status'] == ServerRevocation.unconfirmed.name;
  }

  CloudEgressGate get _gate => _gateOverride ?? CloudEgressGate.instance;

  _DualSlot get _revokeAttemptSlots => _DualSlot(
      SecureStorageSlot(_storage, _revokeAttemptKey),
      FileSlot(_markerDirectory, _revokeAttemptFile));

  _DualSlot get _serverRevocationSlots => _DualSlot(
      SecureStorageSlot(_storage, _serverRevocationKey),
      FileSlot(_markerDirectory, _serverRevocationFile));

  _DualSlot get _pendingRevocationSlots => _DualSlot(
      SecureStorageSlot(_storage, _pendingRevocationKey),
      FileSlot(_markerDirectory, _pendingRevocationFile));

  bool _cloudOn(UserSettingsEntity s) => _isAndroid()
      ? s.cloudProcessingEnabled || s.aiConsentGranted
      : s.cloudProcessingEnabled;

  Future<_Tx> _beginTx({bool Function()? lifetime}) async {
    final current = lifetime ?? _captureLifetime();
    if (!current()) throw const StaleAdmissionException();
    final epoch = _gate.epoch;
    final uid = _readSession()?.uid;
    final owner = await _readReplicaOwnerUid();
    if (!current()) throw const StaleAdmissionException();
    return (epoch: epoch, sessionUid: uid, owner: owner, current: current);
  }

  /// P4: whether the async mutation that captured [tx] may still write. False
  /// after a disable / enable / account transition / sign-out advanced the
  /// epoch, after an account or session switch, or while frozen.
  Future<bool> _holds(_Tx tx) async {
    if (!tx.current() ||
        _gate.epoch != tx.epoch ||
        ConsentAuthority.egressFrozen) {
      return false;
    }
    if (_readSession()?.uid != tx.sessionUid) return false;
    try {
      final owner = await _readReplicaOwnerUid();
      return tx.current() &&
          _gate.epoch == tx.epoch &&
          !ConsentAuthority.egressFrozen &&
          _readSession()?.uid == tx.sessionUid &&
          owner == tx.owner;
    } catch (_) {
      return false;
    }
  }

  /// The APNs registration. Astra H3 cross-unit: the native call carries the
  /// CURRENT transition generation of the active owner so the native side can
  /// refuse a stale call, and it is made only while the gate permits.
  Future<ApnsTokenInfo?> _loadApnsToken(String owner) async {
    final override = _loadApnsTokenOverride;
    if (override != null) return override();
    if (!await _gate.permits()) return null;
    final generation = await _clientGeneration(owner);
    return await NativeCaptureBridge.registerForRemoteNotifications(
            transitionGeneration: generation) ??
        await NativeCaptureBridge.getApnsToken();
  }

  static CaptureSession? _defaultReadSession() {
    try {
      final session = Supabase.instance.client.auth.currentSession;
      final user = session?.user;
      if (session == null || user == null) return null;
      return (uid: user.id, jwt: session.accessToken);
    } catch (_) {
      return null;
    }
  }

  CaptureConsentClient get _consent =>
      _consentClient ??
      CaptureConsentClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  CaptureBackendClient get _backendClient =>
      _client ??
      CaptureBackendClient(
        supabaseUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
      );

  /// Platform dispatcher for keeping the backend in sync (MALI-060n Android
  /// tail). iOS writes the native App-Intent config AND pushes consent; Android
  /// registers the device and pushes consent (no native App-Intent config).
  /// Both keep the verified server consent row current. Call this from every
  /// trigger point (registration, consent change, startup, resume) instead of
  /// [syncNativeState] directly.
  Future<void> syncBackendState() async {
    final current = _captureLifetime();
    if (!current()) return;
    // Startup, resume and the periodic poll all land here: the moments a
    // revoke that did not land may be retried (its own gate and backoff).
    await retryPendingRevocation();
    if (!current()) return;
    final ios = _isIos();
    if (!ios && !_isAndroid()) return;
    if (await _gateState(current: current) == _Gate.blocked || !current()) {
      return;
    }
    final generation = ++_syncGeneration;
    void record(CaptureRegistrationStatus next) {
      // A newer sync owns the status; never let a stale run overwrite it.
      if (current() && generation == _syncGeneration) _status.value = next;
    }

    final outcome = _SyncOutcome();
    var tracked = false;
    try {
      final settings = await _settingsRepository.getSettings();
      if (!current()) return;
      final wantsCloud = ios
          ? settings.cloudProcessingEnabled
          : settings.cloudProcessingEnabled || settings.aiConsentGranted;
      tracked = _isBackendConfigured() && wantsCloud;
      record(CaptureRegistrationStatus(
        tracked
            ? CaptureRegistrationPhase.connecting
            : CaptureRegistrationPhase.notRequested,
      ));
      if (ios) {
        await _syncNativeState(outcome);
      } else {
        await _syncAndroidConsentState(outcome);
      }
      if (tracked) {
        record(outcome.consentPushFailed
            ? const CaptureRegistrationStatus(
                CaptureRegistrationPhase.failed, 'consent_sync_failed')
            : outcome.registerFailed
                ? const CaptureRegistrationStatus(
                    CaptureRegistrationPhase.failed, 'register_failed')
                : const CaptureRegistrationStatus(
                    CaptureRegistrationPhase.connected));
      }
    } catch (_) {
      if (tracked) {
        record(CaptureRegistrationStatus(
          CaptureRegistrationPhase.failed,
          outcome.registerFailed ? 'register_failed' : 'unknown',
        ));
      }
      if (ios) rethrow;
    }
  }

  /// UI-friendly re-run of [syncBackendState]; failures are reflected in
  /// [status] instead of thrown.
  Future<void> retry() async {
    try {
      await syncBackendState();
    } catch (_) {
      // Recorded in [status].
    }
  }

  /// Android consent propagation. Registers a device (to obtain the verified
  /// secret the hardened AI endpoints require) ONLY once the user has opted into
  /// cloud/AI — a purely-local user never gets a server device row — then
  /// mirrors consent onto that verified row. Fail-closed and best-effort: a
  /// failure never blocks local parsing, and a stale/absent server row defaults
  /// consent OFF (never open). No SMS/financial payload is ever sent here.
  ///
  /// Cloud OFF = ZERO EGRESS here too (A-12-min R6, no platform carve-out): with
  /// no opt-in nothing is sent, ever, even when a secret exists. The only
  /// exception is the revoke inside [disableCloud].
  Future<void> _syncAndroidConsentState(_SyncOutcome outcome) async {
    if (!_isBackendConfigured()) return;
    // OFF (persistent gate) or unset: nothing is sent, ever, even with a secret.
    if (await _gateState() != _Gate.open) return;
    final tx = await _beginTx();
    if (!await _holds(tx)) return;
    final settings = await _settingsRepository.getSettings();
    if (!await _holds(tx)) return;
    final wantsCloudOrAi =
        settings.cloudProcessingEnabled || settings.aiConsentGranted;
    if (!wantsCloudOrAi) return;
    final installId = await _loadInstallId();
    if (!await _holds(tx)) return;
    var secret = await _storage.read(key: _secretKey);
    if (!await _holds(tx)) return;

    if (secret == null || secret.isEmpty) {
      try {
        secret = await _backendClient.registerDevice(
          installId: installId,
          platform: 'android',
        );
        if (!await _holds(tx)) return;
        if (!await _holds(tx)) return;
        await _storage.write(key: _secretKey, value: secret);
        if (!await _holds(tx)) return;
        if (!await _holds(tx)) return;
        await _clearAck();
      } catch (_) {
        outcome.registerFailed = true;
        return; // retried on the next sync; nothing leaks, nothing breaks
      }
    }

    // C.3 / P7: the Android device row is linked to its owner with the JWT link
    // (`link_capture_device(consent)`), exactly like iOS, so the revoke can be
    // authorised by the same contract. Only a session whose uid IS the admitted
    // replica owner may link; otherwise (signed out) the legacy device-secret
    // consent push below is all that exists, and it creates no owner proof.
    final session = _readSession();
    if (session != null &&
        tx.owner == session.uid &&
        tx.sessionUid == session.uid) {
      final snapshot = _snapshotOf(settings);
      if (await _hasVerifiedAck(session.uid, snapshot)) return;
      if (!await _linkWithConsent(session, snapshot, tx)) {
        outcome.consentPushFailed = true;
      }
      return;
    }

    if (!await _holds(tx)) return;
    await _pushDeviceConsent(
      outcome,
      installId: installId,
      deviceSecret: secret,
      aiConsentGranted: settings.aiConsentGranted,
      cloudProcessingEnabled: settings.cloudProcessingEnabled,
    );
  }

  Future<void> syncNativeState() => _syncNativeState(_SyncOutcome());

  Future<void> _syncNativeState(_SyncOutcome outcome) async {
    if (!_isIos()) return;
    final gateState = await _gateState();
    if (gateState == _Gate.blocked) return;
    final tx = await _beginTx();
    if (!await _holds(tx)) return;
    final settings = await _settingsRepository.getSettings();
    if (!await _holds(tx)) return;
    final installId = await _loadInstallId();
    if (!await _holds(tx)) return;
    var secret = await _storage.read(key: _secretKey);
    if (!await _holds(tx)) return;

    if (!settings.cloudProcessingEnabled ||
        !_isBackendConfigured() ||
        gateState == _Gate.off) {
      final nativeGeneration = await _clientGeneration(tx.owner ?? '');
      if (!await _holds(tx)) return;
      await _writeNativeBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
        ownerUid: tx.owner ?? '',
        transitionGeneration: nativeGeneration,
      );
      // Cloud OFF = ZERO EGRESS (A-12-min R6): no link, no registerDevice, no
      // setConsent, no APNs registration and no 401 recovery. The owner and its
      // restrictive mirror are published LOCALLY. This branch NEVER sends a
      // revoke: the only one lives inside [disableCloud].
      if (!settings.cloudProcessingEnabled) await _linkOnce();
      return;
    }

    if (!settings.aiConsentGranted || secret == null || secret.isEmpty) {
      // Clear stale native consent before any later step that can fail. If the
      // final write does not happen, the App Intent stays local/no-AI.
      final nativeGeneration = await _clientGeneration(tx.owner ?? '');
      if (!await _holds(tx)) return;
      await _writeNativeBackendConfig(
        cloudProcessingEnabled: false,
        installId: installId,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
        ownerUid: tx.owner ?? '',
        transitionGeneration: nativeGeneration,
      );
    }

    if (secret == null || secret.isEmpty) {
      try {
        secret = await _backendClient.registerDevice(installId: installId);
      } catch (_) {
        outcome.registerFailed = true;
        rethrow;
      }
      if (!await _holds(tx)) return;
      await _storage.write(key: _secretKey, value: secret);
      if (!await _holds(tx)) return;
    }

    // P4: the registration round trip may have outlived an account switch or a
    // transition; the (widening) native config is written only if nothing moved.
    if (!await _holds(tx)) return;
    final nativeGeneration = await _clientGeneration(tx.owner ?? '');
    if (!await _holds(tx)) return;
    await _writeNativeBackendConfig(
      cloudProcessingEnabled: _isBackendConfigured(),
      installId: installId,
      deviceSecret: secret,
      backendUrl: SupabaseConfig.url,
      anonKey: SupabaseConfig.anonKey,
      aiConsentGranted: settings.aiConsentGranted,
      ownerUid: tx.owner ?? '',
      transitionGeneration: nativeGeneration,
    );
    // MALI-060n — mirror consent onto the verified server device row so the
    // AI/paid endpoints enforce it authoritatively (revocation propagates the
    // moment the user toggles it, since syncNativeState re-runs). Best-effort:
    // a failure here must never block native config or local capture.
    if (!await _holds(tx)) return;
    await _projectConsent(outcome, tx);
    if (!await _holds(tx)) return;
    try {
      final token = await _loadApnsToken(tx.owner ?? '');
      if (!await _holds(tx)) return;
      if (token != null) {
        await syncApnsToken(token);
      }
    } catch (error) {
      // Push delivery is optional. A throttled/unavailable APNs registration
      // must never prevent relay sync or local capture processing.
      if (kDebugMode) {
        debugPrint('[Capture] APNs registration deferred: $error');
      }
    }
  }

  Future<bool> _pushDeviceConsent(
    _SyncOutcome outcome, {
    required String installId,
    required String deviceSecret,
    required bool aiConsentGranted,
    required bool cloudProcessingEnabled,
  }) async {
    try {
      await _backendClient.setDeviceConsent(
        installId: installId,
        deviceSecret: deviceSecret,
        aiConsentGranted: aiConsentGranted,
        cloudProcessingEnabled: cloudProcessingEnabled,
      );
      return true;
    } catch (_) {
      // Best-effort: startup/resume/next capture sync retries the same absolute
      // consent state. No SMS or financial payload is sent by this call.
      // While granting, the caller surfaces this as consent_sync_failed.
      if (cloudProcessingEnabled) outcome.consentPushFailed = true;
      return false;
    }
  }

  /// WP-6 / A-12-min — the capture-owner gate (manifest §4.2/§4.6).
  ///
  /// Cloud OFF or unset: the owner and its restrictive mirror are published
  /// LOCALLY with no network call at all (the session uid must equal the
  /// admitted replica's owner). Cloud ON: the install is linked to the
  /// authenticated user with the replica's consent first, and ONLY IF the server
  /// accepted it is the owner published (mirror and owner in one native call).
  /// Any failure (offline, 4xx/5xx, no secret, the session and the admitted
  /// replica disagree, a clear since the epoch was read) leaves the owner
  /// unpublished, so captures stay unbound (fail closed). Safe to call
  /// repeatedly; concurrent calls share one run. [_linkOnce] reports whether the
  /// owner is published.
  Future<bool> _linkOnce({AdmissionAuthority? admissionAuthority}) {
    final authority = admissionAuthority ?? _captureWorkAuthority();
    final current = _captureLifetime(
        requireAdmission: true, admissionAuthority: authority);
    if (!current()) return Future.value(false);
    final admission = (uid: _readSession()?.uid, epoch: authority?.epoch);
    final inFlight = _linkInFlight;
    if (inFlight != null && _linkAdmission == admission) return inFlight;
    final run = _linkAndPublish(current).catchError((_) => false);
    _linkAdmission = admission;
    _linkInFlight = run;
    return run.whenComplete(() {
      if (identical(_linkInFlight, run)) {
        _linkInFlight = null;
        _linkAdmission = null;
      }
    });
  }

  /// The admission hook forwards its already committed authority. Other
  /// callers can only capture the existing authenticated local-work authority.
  Future<void> linkToCurrentUser({
    AdmissionAuthority? admissionAuthority,
  }) async {
    await _linkOnce(admissionAuthority: admissionAuthority);
  }

  Future<bool> _linkAndPublish(bool Function() current) async {
    // P6: OFF (a committed persistent gate) still publishes LOCALLY with a
    // restrictive mirror; DISABLING / frozen / uncertain authority fails closed.
    if (!current() || !_isIos()) return false;
    // P3 (10b): arm the sign-out unlink from the SAVED Cloud-ON ack of this
    // account first, whatever the gate says now: a link from an earlier
    // process must still be undone at sign-out even when this launch's link
    // check is blocked (frozen/uncertain) or has not finished.
    final signedIn = _readSession();
    if (signedIn != null) {
      final seq = _unlinkTargetSeq;
      try {
        final saved = await _readAckAny();
        if (saved != null &&
            saved.uid == signedIn.uid &&
            saved.snapshot.cloud) {
          await _armUnlink(saved.uid, seq);
        }
      } catch (_) {
        // Best effort: an unreadable ack arms nothing.
      }
      if (!current()) return false;
    }
    final gateState = await _gateState(current: current);
    if (!current()) return false;
    if (gateState == _Gate.blocked) {
      Diag.log('[CaptureOwner]', 'publish skipped gate=blocked');
      return false;
    }
    final session = _readSession();
    if (session == null) return false;
    if (await _readReplicaOwnerUid() != session.uid || !current()) return false;
    final tx = await _beginTx(lifetime: current);
    // Read BEFORE any await that can take long: a sign-out / transition / removal
    // clear after this point bumps the epoch and the native publish refuses.
    if (!current()) return false;
    final epoch = await _readOwnerEpoch();
    if (!current()) return false;
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    if (!current()) return false;
    var linked = (cloud: false, ai: false, version: snapshot.version);
    if (snapshot.cloud && gateState == _Gate.open) {
      if (!_isBackendConfigured()) return false;
      final seq = _unlinkTargetSeq;
      final ack = await _readAck(session.uid);
      if (!current()) return false;
      if (ack != snapshot || !await _hasVerifiedAck(session.uid, snapshot)) {
        if (!await _linkWithConsent(session, snapshot, tx)) return false;
      } else {
        // P3: an ack from an earlier process is known now; arm its unlink.
        await _armUnlink(session.uid, seq);
      }
      linked = snapshot;
    }
    // Re-checked after the round trip: an account switch in between must not
    // publish the previous user as the owner, and a Cloud-OFF transition that
    // began meanwhile must not have its restricted mirror widened.
    if (!await _holds(tx)) return false;
    // The mirror is never wider than what is proven (OFF, or what the server
    // acknowledged), even if consent changed while the link was in flight.
    final now = _snapshotOf(await _settingsRepository.getSettings());
    final mirror = (
      cloud: now.cloud && linked.cloud,
      ai: now.ai && linked.ai,
      version: now.version,
    );
    if (!await _holds(tx)) return false;
    final transitionGeneration = await _clientGeneration(session.uid);
    if (!current() || !await _holds(tx)) return false;
    // Release diagnostic (booleans and a state name only): what the native
    // capture paths are told. A capture goes local when this says cloud=false.
    Diag.log(
        '[CaptureOwner]',
        'publish mirror_cloud=${mirror.cloud} mirror_ai=${mirror.ai} '
            'gate=${gateState.name} settings_cloud=${now.cloud} '
            'linked_cloud=${linked.cloud}');
    await _publishOwner(
      uid: session.uid,
      cloud: mirror.cloud,
      ai: mirror.ai,
      version: mirror.version,
      expectedEpoch: epoch,
      transitionGeneration: transitionGeneration,
    );
    if (!current()) return false;
    _mirrorVersions[session.uid] = mirror.version;
    return true;
  }

  Future<bool> _linkWithConsent(
      CaptureSession session, _ConsentSnapshot snapshot, _Tx tx) async {
    if (!await _holds(tx)) return false;
    final installId = await _loadInstallId();
    if (!await _holds(tx)) return false;
    var secret = await _storage.read(key: _secretKey);
    if (!await _holds(tx)) return false;
    final generation = await _clientGeneration(session.uid);
    if (!await _holds(tx)) return false;
    try {
      if (secret == null || secret.isEmpty) {
        secret = await _backendClient.registerDevice(
            installId: installId, platform: _isAndroid() ? 'android' : 'ios');
        if (!await _holds(tx)) return false;
        await _storage.write(key: _secretKey, value: secret);
        if (!await _holds(tx)) return false;
        await _clearAck();
        if (!await _holds(tx)) return false;
      }
      await _withSecretRecovery(installId, secret, (deviceSecret) async {
        if (!await _holds(tx)) throw const StaleAdmissionException();
        if (snapshot.cloud) {
          await _storage.write(key: _grantAttemptKey, value: session.uid);
          if (!await _holds(tx)) throw const StaleAdmissionException();
        }
        return _consent.link(
          installId: installId,
          deviceSecret: deviceSecret,
          jwt: session.jwt,
          cloud: snapshot.cloud,
          ai: snapshot.ai,
          version: snapshot.version,
          clientGeneration: generation,
        );
      }, lifetime: tx.current);
    } catch (_) {
      return false;
    }
    // P4: an ack for a link that completed after an account switch or a
    // transition is never written; the next admission links again.
    if (!await _holds(tx)) return false;
    await _writeAck(session.uid, snapshot);
    return true;
  }

  /// The client transition generation sent as `p_client_generation` (C.2): the
  /// owner's durable `cloud_egress_state` generation (0 before any record).
  Future<int> _clientGeneration(String uid) async {
    try {
      return (await _gate.view(owner: uid)).record?.transitionGeneration ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// WP-6 — projects a consent CHANGE after the install is linked. A revocation
  /// reaches the device first (restrictive mirror: never wider than what the
  /// server last acknowledged); the widened/final mirror is written only after
  /// the server accepted `set_capture_consent` with the newer version. A failure
  /// leaves the restrictive mirror and the old acknowledgement, so the next sync
  /// retries the same absolute state. A never-linked install goes through the
  /// full gate instead. Cloud ON only: Cloud OFF never reaches this (R6).
  Future<void> _projectConsent(_SyncOutcome outcome, _Tx tx) async {
    if (ConsentAuthority.egressFrozen) return;
    final session = _readSession();
    if (session == null || await _readReplicaOwnerUid() != session.uid) return;
    final snapshot = _snapshotOf(await _settingsRepository.getSettings());
    if (!await _holds(tx)) return;
    final ack = await _readAck(session.uid);
    if (!await _holds(tx)) return;
    if (ack == null || ack.version > snapshot.version) {
      // Setup can have a committed consent capability before the ordinary
      // writable app shell is admitted. Confirm the device row for that
      // capability; the normal admission hook will publish the native owner.
      final capability = AppSession.instance.captureConsentCapability();
      final linked = AppSession.instance.status == SessionStatus.needsOnboarding &&
              capability?.uid == session.uid
          ? await _linkWithConsent(session, snapshot, tx)
          : await _linkOnce();
      if (!linked && snapshot.cloud) {
        outcome.consentPushFailed = true;
      }
      return;
    }
    if (ack == snapshot) {
      if (!await _hasVerifiedAck(session.uid, snapshot) && !await _linkOnce()) {
        outcome.consentPushFailed = snapshot.cloud;
      }
      return;
    }
    if (!await _holds(tx)) return;
    await _writeMirror(session.uid, (
      cloud: snapshot.cloud && ack.cloud,
      ai: snapshot.ai && ack.ai,
      version: snapshot.version,
    ), lifetime: tx.current);
    final generation = await _clientGeneration(session.uid);
    if (!await _holds(tx)) return;
    try {
      final installId = await _loadInstallId();
      if (!await _holds(tx)) return;
      final secret = await _storage.read(key: _secretKey);
      if (!await _holds(tx)) return;
      if (secret == null || secret.isEmpty) {
        throw const CaptureBackendException('no_secret');
      }
      await _withSecretRecovery(installId, secret, (deviceSecret) async {
        if (!await _holds(tx)) throw const StaleAdmissionException();
        return _consent.setConsent(
          installId: installId,
          deviceSecret: deviceSecret,
          jwt: session.jwt,
          cloud: snapshot.cloud,
          ai: snapshot.ai,
          version: snapshot.version,
          clientGeneration: generation,
        );
      }, lifetime: tx.current);
    } catch (_) {
      if (snapshot.cloud) outcome.consentPushFailed = true;
      return;
    }
    // P4: the answer of a set that outlived an account switch / transition has
    // no state effect (no widened mirror, no ack).
    if (!await _holds(tx)) return;
    await _writeMirror(session.uid, snapshot, lifetime: tx.current);
    if (!await _holds(tx)) return;
    await _writeAck(session.uid, snapshot);
  }

  _ConsentSnapshot _snapshotOf(UserSettingsEntity settings) => (
        cloud: settings.cloudProcessingEnabled,
        ai: settings.cloudProcessingEnabled && settings.aiConsentGranted,
        version: settings.consentVersion,
      );

  /// Runs [call] with [secret]; a 401 replaces the credential exactly once
  /// (shared with every other caller) and retries with the fresh one.
  Future<void> _withSecretRecovery(
    String installId,
    String secret,
    Future<void> Function(String deviceSecret) call, {
    bool Function()? lifetime,
  }) async {
    final current = lifetime ?? _captureLifetime();
    if (!current()) throw const StaleAdmissionException();
    try {
      await call(secret);
    } on CaptureBackendException catch (error) {
      if (!_isUnauthorized(error)) rethrow;
      if (!current()) throw const StaleAdmissionException();
      final fresh = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
        current: current,
      );
      if (!current()) throw const StaleAdmissionException();
      await call(fresh);
    }
  }

  /// The mirror never moves to an older version within a process (a slow link
  /// finishing after a newer consent change must not overwrite it).
  Future<void> _writeMirror(String uid, _ConsentSnapshot snapshot,
      {bool Function()? lifetime}) async {
    final live = lifetime ?? _captureLifetime();
    final epoch = _gate.epoch;
    bool current() => live() && _gate.epoch == epoch &&
        !ConsentAuthority.egressFrozen;
    if (!current() || ConsentAuthority.egressFrozen) return;
    final last = _mirrorVersions[uid];
    if (last != null && snapshot.version < last) return;
    final generation = await _clientGeneration(uid);
    if (!current()) return;
    // Release diagnostic (booleans only).
    Diag.log('[CaptureOwner]',
        'mirror write cloud=${snapshot.cloud} ai=${snapshot.ai}');
    await _writeConsentMirror(
      uid: uid,
      cloud: snapshot.cloud,
      ai: snapshot.ai,
      version: snapshot.version,
      transitionGeneration: generation,
    );
    if (current()) _mirrorVersions[uid] = snapshot.version;
  }

  Future<_ConsentSnapshot?> _readAck(String uid) async {
    final ack = await _readAckAny();
    return ack != null && ack.uid == uid ? ack.snapshot : null;
  }

  Future<({String uid, _ConsentSnapshot snapshot})?> _readAckAny() async {
    final raw = await _storage.read(key: _ackKey);
    final parts = raw?.split('|');
    if (parts == null || parts.length != 4) return null;
    final version = int.tryParse(parts[3]);
    if (version == null) return null;
    return (
      uid: parts[0],
      snapshot: (cloud: parts[1] == '1', ai: parts[2] == '1', version: version),
    );
  }

  String _encodeAck(String uid, _ConsentSnapshot snapshot) =>
      '$uid|${snapshot.cloud ? 1 : 0}|${snapshot.ai ? 1 : 0}|${snapshot.version}';

  Future<bool> _hasVerifiedAck(String uid, _ConsentSnapshot snapshot) async =>
      await _readAck(uid) == snapshot &&
      await _storage.read(key: _verifiedAckKey) == _encodeAck(uid, snapshot);

  Future<void> _writeAck(String uid, _ConsentSnapshot snapshot) async {
    final seq = _unlinkTargetSeq;
    final encoded = _encodeAck(uid, snapshot);
    await _storage.write(key: _ackKey, value: encoded);
    await _storage.write(key: _verifiedAckKey, value: encoded);
    await _storage.delete(key: _grantAttemptKey);
    if (!_disposed) {
      consentServerRevision.value++;
      if (snapshot.cloud) SyncWakeup.notify();
    }
    // P3: a Cloud-ON ack is what a sign-out unlinks; any other ack is not.
    if (snapshot.cloud) {
      await _armUnlink(uid, seq);
    } else {
      _disarmUnlink();
    }
  }

  Future<void> _clearAck() async {
    _disarmUnlink();
    try {
      await _storage.delete(key: _ackKey);
      await _storage.delete(key: _verifiedAckKey);
      if (!_disposed) consentServerRevision.value++;
    } catch (_) {}
  }

  Future<String?> readDeviceSecret() => _storage.read(key: _secretKey);

  /// WP-8 (diagnostics, read-only): what the server last acknowledged for the
  /// current session user and the newest mirror version written this process.
  /// Flags and a version only; null when nothing was acknowledged / mirrored.
  Future<({bool cloud, bool ai, int version})?> consentAckSnapshot() async {
    final uid = _readSession()?.uid;
    if (uid == null) return null;
    return _readAck(uid);
  }

  int? get mirroredConsentVersion {
    final uid = _readSession()?.uid;
    return uid == null ? null : _mirrorVersions[uid];
  }

  /// Whether saving [after] over [before] switches the capture cloud from ON to
  /// OFF on this platform (Android treats AI like cloud, see
  /// [_syncAndroidConsentState]). Such a change MUST go through [disableCloud].
  bool isDisablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      _cloudOn(before) && !_cloudOn(after);

  /// The opposite change: OFF/unset -> ON. Such a change MUST go through
  /// [enableCloud] (an explicit user action; the only way out of the persistent
  /// OFF gate).
  bool isEnablingCloud(UserSettingsEntity before, UserSettingsEntity after) =>
      !_cloudOn(before) && _cloudOn(after);

  /// A1/A3(c) — which protocol an explicit choice must take, from the stored row
  /// AND the live/pending authority. A stored ON alone never proves that the
  /// two-runtime enable completed: a plain save over it is allowed only when the
  /// resolved, unfrozen gate holds a durable ON that the native layers confirm
  /// for the same generation and version, with no pending operation. An exact
  /// pending resume is allowed only for this [ownerUid]'s operation reserved at
  /// exactly the stored consent version. Everything else is [withdrawFirst].
  /// Reads local stores and the native layer only; it never writes or sends.
  Future<ExplicitEnableRoute> explicitEnableRoute(
    UserSettingsEntity current,
    UserSettingsEntity updated, {
    required String ownerUid,
  }) async {
    final enabling = isEnablingCloud(current, updated);
    if (!enabling && !_cloudOn(updated)) return ExplicitEnableRoute.plainSave;
    try {
      final owner = await _readReplicaOwnerUid() ?? '';
      if (owner.isEmpty || owner != ownerUid) {
        return enabling
            ? ExplicitEnableRoute.enable
            : ExplicitEnableRoute.withdrawFirst;
      }
      // R17: Turn on resumes a pending operation only when it is exactly
      // resumable; an unresolved pending is never enabled over or resumed.
      switch (await pendingEnableState(current, ownerUid: owner)) {
        case PendingEnableState.resumable:
          return enabling
              ? ExplicitEnableRoute.enable
              : ExplicitEnableRoute.resumePending;
        case PendingEnableState.unresolved:
          return ExplicitEnableRoute.withdrawFirst;
        case PendingEnableState.none:
          if (enabling) return ExplicitEnableRoute.enable;
      }
      return await liveOnVerified(owner: owner)
          ? ExplicitEnableRoute.plainSave
          : ExplicitEnableRoute.withdrawFirst;
    } catch (_) {
      return ExplicitEnableRoute.withdrawFirst;
    }
  }

  /// R17 — whether the owner's pending enable is exactly resumable. Reads only
  /// (local stores and the native inspection); never writes or sends. Resumable
  /// requires, together: a readable, consistent Dart pending (one record, or the
  /// same record in both layers); the reserved version the stored row implies
  /// (an already committed Cloud ON at exactly that version, or a not-yet-saved
  /// operation reserved at stored + 1); no enable or disable running in this
  /// process; and, on iOS, a native barrier that is that same operation in both
  /// layers for the still-live owner lifecycle (or, before the Dart record was
  /// bound, no native barrier and no ON for the operation's generation).
  Future<PendingEnableState> pendingEnableState(
    UserSettingsEntity stored, {
    required String ownerUid,
  }) async {
    try {
      final owner = await _readReplicaOwnerUid() ?? '';
      if (owner.isEmpty || owner != ownerUid) {
        return PendingEnableState.unresolved;
      }
      final readout = await _gate.readPending();
      if (readout.unreadable) return PendingEnableState.unresolved;
      if (!readout.blocks(owner)) {
        // Nothing durable; a marker of a running enable is not "none".
        return await _gate.pendingBlocks(owner: owner)
            ? PendingEnableState.unresolved
            : PendingEnableState.none;
      }
      if (_enableInFlight != null || _disableInFlight != null) {
        return PendingEnableState.unresolved;
      }
      final rec = readout.agreed(owner) ?? readout.partial(owner);
      if (rec == null || rec.ownerUid != owner) {
        return PendingEnableState.unresolved;
      }
      final expectedReserved =
          _cloudOn(stored) ? stored.consentVersion : stored.consentVersion + 1;
      if (rec.reservedVersion != expectedReserved) {
        return PendingEnableState.unresolved;
      }
      if (!_usesNativeBarrier) return PendingEnableState.resumable;

      final native =
          await NativeCaptureBridge.getCloudEgressPending(ownerUid: owner);
      final nativeOwner = await _readCaptureOwner();
      final nativeEpoch = await _readOwnerEpoch();
      if (native == null ||
          native.operation != 'inspect' ||
          native.barrier.length != 2 ||
          nativeOwner == null ||
          nativeOwner.uid != owner) {
        return PendingEnableState.unresolved;
      }
      bool barrierIs(CloudEgressEnableBinding b) =>
          native.status == CloudEgressTransitionStatus.pending &&
          native.binding == b &&
          native.barrier.every((l) =>
              l.outcome == CloudEgressLayerOutcome.verified &&
              l.operationId == b.operationId &&
              l.transitionGeneration == b.transitionGeneration &&
              l.reservedVersion == b.reservedVersion &&
              l.ownerGeneration == b.ownerGeneration &&
              l.ownerEpoch == b.ownerEpoch) &&
          b.ownerGeneration == nativeOwner.generation &&
          b.ownerEpoch == nativeEpoch;
      final bound = rec.binding;
      if (bound != null) {
        return barrierIs(bound)
            ? PendingEnableState.resumable
            : PendingEnableState.unresolved;
      }
      // Denied stage: native `begin` may or may not have run.
      if (native.status == CloudEgressTransitionStatus.noBarrier) {
        final cleanNative = native.barrier
                .every((l) => l.outcome == CloudEgressLayerOutcome.absent) &&
            !native.egress.any((l) => l.state == 'ON');
        final dartOn = (await _gate.store.readOwnerLayers(owner)).records.any(
            (r) =>
                r.state == EgressState.on &&
                r.transitionGeneration == rec.transitionGeneration);
        return cleanNative && !dartOn
            ? PendingEnableState.resumable
            : PendingEnableState.unresolved;
      }
      final adopted = native.binding;
      return adopted != null &&
              adopted.transitionGeneration == rec.transitionGeneration &&
              adopted.reservedVersion == rec.reservedVersion &&
              barrierIs(adopted)
          ? PendingEnableState.resumable
          : PendingEnableState.unresolved;
    } catch (_) {
      return PendingEnableState.unresolved;
    }
  }

  /// R18 / N-CR — the explicit, verified withdrawal from a pending or uncertain
  /// enable.
  ///
  /// Serialized against every enable/disable (an enable in flight of the SAME
  /// owner loses its authority at once and is awaited; a new enable waits for
  /// this). The capability is validated BEFORE any shared authority is touched:
  /// an obsolete call changes nothing and throws [StaleAdmissionException].
  /// Order: the durable DISABLING record (the restrictive state) and the
  /// restrictive native config/mirror first, then a READ-BACK of every
  /// independently admitting runtime (Dart store, native egress record, and the
  /// native config and mirror execution acknowledgments; anything unverified
  /// BEFORE the local OFF ends in [CloudWithdrawIncompleteException] and nothing
  /// has been cleared yet); then, exactly as
  /// [disableCloud] does, the bounded drain and the one-shot, credential- and
  /// acknowledgment-bound revoke when an effective, acknowledged permission is
  /// being withdrawn (nothing is revoked, linked, retried or acknowledged
  /// otherwise; its outcome is [serverRevocation] and never gates the local
  /// OFF); then the typed local OFF ([commitLocalOff]); only then the EXACT
  /// attributable evidence is cleared (the native operation by a confirmed
  /// abandon, the Dart record by a read-back-verified clear); last the durable
  /// OFF, read back again. The FINAL read-back runs after the local OFF and the
  /// evidence were already cleared, so a failure there still ends in
  /// [CloudWithdrawIncompleteException] with egress denied, but it does NOT leave
  /// the earlier steps undone: no later failure is a promise that all evidence
  /// is still in place. Evidence that is unreadable, conflicting or cannot be
  /// attributed to one operation is never cleared. It
  /// never clears a pending merely to display Off, and it never touches another
  /// owner's records.
  Future<void> withdrawPendingEnable({
    required ConsentCapability capability,
    required Future<void> Function() commitLocalOff,
  }) async {
    final admission = AdmissionAuthority(capability.uid, () => capability.isCurrent,
        epoch: capability.epoch);
    final current =
        _captureLifetime(requireAdmission: true, admissionAuthority: admission);
    // N-CR-2: validate the supplied authority BEFORE invalidating anything. An
    // obsolete capability must not end a successor's running enable.
    if (!current()) throw const StaleAdmissionException();
    // The outgoing enable of THIS owner loses its authority NOW.
    _withdrawalEpochs[capability.uid] = _withdrawalEpochOf(capability.uid) + 1;
    while (true) {
      if (!current()) throw const StaleAdmissionException();
      final inFlight = _disableInFlight ?? _enableInFlight;
      if (inFlight == null) break;
      try {
        await inFlight;
      } catch (_) {}
    }
    late final Future<void> flight;
    flight = _withdrawPendingEnable(capability, current, commitLocalOff)
        .whenComplete(() {
      if (identical(_disableInFlight, flight)) _disableInFlight = null;
    });
    _disableInFlight = flight;
    return flight;
  }

  /// What the withdrawal can attribute: the exact Dart record and native
  /// operation to clear, or the coarse [reason] it cannot (nothing is cleared
  /// then). Reads only.
  Future<({String? reason, PendingEnableRecord? rec, CloudEgressEnableBinding? nativeOp})>
      _attributePending(String owner) async {
    final readout = await _gate.readPending();
    if (readout.unreadable) {
      return (reason: 'pending_unreadable', rec: null, nativeOp: null);
    }
    final rec = readout.agreed(owner) ?? readout.partial(owner);
    if (readout.blocks(owner) && (rec == null || rec.ownerUid != owner)) {
      return (reason: 'pending_conflict', rec: null, nativeOp: null);
    }
    CloudEgressEnableBinding? nativeOp;
    if (_usesNativeBarrier) {
      CloudEgressEnableResult? inspected;
      try {
        inspected =
            await NativeCaptureBridge.getCloudEgressPending(ownerUid: owner);
      } catch (_) {}
      if (inspected == null ||
          inspected.operation != 'inspect' ||
          inspected.barrier.length != 2) {
        return (reason: 'native_unreadable', rec: rec, nativeOp: null);
      }
      switch (inspected.status) {
        case CloudEgressTransitionStatus.noBarrier:
          if (inspected.barrier
              .any((l) => l.outcome != CloudEgressLayerOutcome.absent)) {
            return (reason: 'native_unresolved', rec: rec, nativeOp: null);
          }
        case CloudEgressTransitionStatus.pending:
          final nb = inspected.binding;
          if (rec == null ||
              nb == null ||
              nb.transitionGeneration != rec.transitionGeneration ||
              nb.reservedVersion != rec.reservedVersion ||
              (rec.binding != null && rec.binding != nb) ||
              !inspected.barrier.every((l) =>
                  l.outcome == CloudEgressLayerOutcome.verified &&
                  l.operationId == nb.operationId &&
                  l.transitionGeneration == nb.transitionGeneration &&
                  l.reservedVersion == nb.reservedVersion &&
                  l.ownerGeneration == nb.ownerGeneration &&
                  l.ownerEpoch == nb.ownerEpoch)) {
            return (reason: 'native_mismatch', rec: rec, nativeOp: null);
          }
          nativeOp = nb;
        default:
          return (reason: 'native_unresolved', rec: rec, nativeOp: null);
      }
    }
    return (reason: null, rec: rec, nativeOp: nativeOp);
  }

  /// N-CR-4: true when [ownerUid]'s pending evidence cannot be attributed to
  /// one operation (corrupt, unreadable, conflicting or mismatched layers), i.e.
  /// the verified withdrawal would refuse to clear it. Independent of whether a
  /// pending record is readable; any failure to decide answers true (never a
  /// claim that a withdrawal could finish). Reads only; nothing is repaired.
  Future<bool> pendingProvenanceUnresolved({required String ownerUid}) async {
    try {
      return (await _attributePending(ownerUid)).reason != null;
    } catch (_) {
      return true;
    }
  }

  Future<void> _withdrawPendingEnable(
    ConsentCapability capability,
    bool Function() current,
    Future<void> Function() commitLocalOff,
  ) async {
    Never incomplete(String reason) =>
        throw CloudWithdrawIncompleteException(reason);
    void stillCurrent() {
      if (!current()) throw const StaleAdmissionException();
    }

    stillCurrent();
    final String owner;
    try {
      owner = await _readReplicaOwnerUid() ?? '';
    } catch (_) {
      stillCurrent();
      incomplete('owner_readback');
    }
    stillCurrent();
    if (owner.isEmpty || owner != capability.uid) {
      throw const StaleAdmissionException();
    }

    // N-CR-2: the process-wide freeze is owned by THIS flight through a token.
    // A flight that is no longer current never lifts (or re-imposes) a freeze a
    // successor may hold.
    final token = Object();
    _enableFreeze = token;
    ConsentAuthority.freeze('enable_flight');
    _gate.advanceEpoch(EpochCause.captureTransition);
    _gate.freezeEnable(owner);
    var success = false;
    try {
      final settings = await _settingsRepository.getSettings();
      stillCurrent();

      // The exact attributable evidence (Dart record, native operation).
      final attribution = await _attributePending(owner);
      stillCurrent();
      final reason = attribution.reason;
      if (reason != null) incomplete(reason);
      final rec = attribution.rec;
      final nativeOp = attribution.nativeOp;

      // Restrictive state FIRST: the durable DISABLING record and the
      // restrictive native config + mirror.
      final DisableFreeze freeze;
      try {
        freeze = await _gate.beginDisabling(
            owner: owner,
            reservedVersion: settings.consentVersion + 1,
            isCurrent: current);
      } on StaleAdmissionException {
        rethrow;
      } catch (_) {
        stillCurrent();
        incomplete('restrictive_not_durable');
      }
      stillCurrent();
      final nativeAcked = await _restrictNativeSideAcked(freeze);
      stillCurrent();

      // N-CR-1: nothing below runs until every independently admitting runtime
      // is READ BACK as restricted. A best-effort write is not evidence.
      Future<void> verifyRestricted(String stage, {required bool acks}) async {
        if (acks && !nativeAcked) incomplete('native_restriction_$stage');
        final RestrictionReadback readback;
        try {
          readback = await _gate.verifyRestriction(freeze);
        } catch (_) {
          stillCurrent();
          incomplete('restriction_readback_$stage');
        }
        stillCurrent();
        if (!readback.dart) incomplete('dart_restriction_$stage');
        if (readback.native == false) incomplete('native_restriction_$stage');
      }

      await verifyRestricted('begin', acks: true);

      // N-CR-3: an effective, acknowledged permission is withdrawn the way
      // [disableCloud] withdraws it: frozen revoke inputs, the bounded drain,
      // then at most ONE ack- and credential-bound revoke. Without a stored ON,
      // an acknowledgment for this owner, a secret and the owner's JWT the revoke
      // is not attempted (revoke not attempted; that is NOT proof that no server
      // permission exists, and a leftover acknowledgment alone never qualifies).
      // Its outcome never gates the local OFF.
      try {
        _RevokeInputs? inputs;
        try {
          inputs = await _captureRevokeInputs(freeze, settings);
        } catch (_) {}
        stillCurrent();
        await _gate.drain();
        stillCurrent();
        await _gate.drainNative(freeze.owner);
        stillCurrent();
        await _revokeOnce(freeze, inputs);
      } on StaleAdmissionException {
        rethrow;
      } catch (_) {
        // Nothing here may block the local OFF below.
      }
      stillCurrent();

      // The typed local OFF (both permissions).
      try {
        await commitLocalOff();
      } on StaleAdmissionException {
        rethrow;
      } catch (_) {
        stillCurrent();
        await _gate.rewriteDisabling(freeze, isCurrent: current);
        stillCurrent();
        incomplete('local_off');
      }
      stillCurrent();

      // Only now the exact evidence, and only over a restriction that is still
      // verified: native abandon (confirmed), then the Dart record (read back),
      // never anything unattributed.
      await verifyRestricted('clear', acks: false);
      final op = nativeOp;
      if (op != null) {
        CloudEgressEnableResult? abandoned;
        try {
          abandoned = await NativeCaptureBridge.finishCloudEgressEnable(
              ownerUid: owner, binding: op, abandon: true);
        } catch (_) {}
        stillCurrent();
        if (abandoned == null || !abandoned.confirmsAbandoned(op)) {
          incomplete('native_abandon');
        }
      }
      if (rec != null) {
        final cleared = await _gate.clearPendingEnable(rec, isCurrent: current);
        stillCurrent();
        if (!cleared.all || (await _gate.readPending()).blocks(owner)) {
          incomplete('pending_not_cleared');
        }
      }
      stillCurrent();
      final committed = await _gate.commitOff(freeze, isCurrent: current);
      stillCurrent();
      if (!committed) incomplete('off_not_durable');
      // The durable OFF (or the DISABLING it replaces) must still be held by
      // every admitting runtime: the completion is reported only on read-back.
      await verifyRestricted('final', acks: false);
      stillCurrent();
      success = true;
    } finally {
      try {
        // A flight that no longer owns the freeze token, or whose lifecycle
        // ended, leaves the process-wide freeze alone: a successor (or the next
        // initialization) owns it. The owner lifts it only on a verified
        // completion and keeps it otherwise.
        if (identical(_enableFreeze, token)) {
          _enableFreeze = null;
          if (current()) {
            ConsentAuthority.egressFrozen = !success;
            if (!success) ConsentAuthority.egressFreezeTag = 'enable_flight_end';
          }
        }
        await _gate.thawEnable(owner);
        if (success && current()) await _gate.refresh();
      } catch (_) {}
    }
  }

  /// True only for a resolved, unfrozen process whose active owner has no
  /// pending enable, a clean durable Dart ON, and (where a native barrier
  /// exists) the SAME ON (generation and version) read back from BOTH native
  /// layers with no native barrier outstanding. Any failure, absence or
  /// disagreement is false: "can't confirm", never "on".
  Future<bool> liveOnVerified({String? owner}) async {
    try {
      final o = owner ?? await _readReplicaOwnerUid() ?? '';
      if (o.isEmpty ||
          !_gate.isResolved ||
          ConsentAuthority.egressFrozen ||
          await _gate.pendingBlocks(owner: o)) {
        return false;
      }
      final view = await _gate.view(owner: o);
      final dart = view.record;
      if (view.uncertain || dart == null || dart.state != EgressState.on) {
        return false;
      }
      if (_usesNativeBarrier) {
        // R16: the REAL native inspection of a completed enable is `noBarrier`
        // (nothing pending) with the ON in both egress layers; absence of a
        // pending is read together with the full owner/lifecycle-valid ON, never
        // as a `done` completion (native never answers that to an inspection).
        final native =
            await NativeCaptureBridge.getCloudEgressPending(ownerUid: o);
        final nativeOwner = await _readCaptureOwner();
        final nativeEpoch = await _readOwnerEpoch();
        if (native == null ||
            native.operation != 'inspect' ||
            native.status != CloudEgressTransitionStatus.noBarrier ||
            native.barrier.length != 2 ||
            native.barrier
                .any((l) => l.outcome != CloudEgressLayerOutcome.absent) ||
            nativeOwner == null ||
            nativeOwner.uid != o ||
            native.egress.length != 2 ||
            !native.egress.every((l) =>
                l.outcome == CloudEgressLayerOutcome.verified &&
                l.state == 'ON' &&
                l.operationId == null &&
                l.transitionGeneration == dart.transitionGeneration &&
                l.reservedVersion == dart.reservedVersion &&
                l.ownerGeneration == nativeOwner.generation &&
                l.ownerEpoch == nativeEpoch)) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Astra G C.4 — the Cloud ON->OFF transition. In order:
  ///  (a) FREEZE, synchronously: the in-process flag and the epoch advance
  ///      first; then, under the admission lock, `cloud_egress_state = DISABLING`
  ///      (owner, a NEW transition generation, reserved version = current + 1)
  ///      is written durably to every store. No request newly passes admission
  ///      after that, concurrent attempts included. If not one store takes the
  ///      record NOTHING is sent (no revoke), local OFF is still attempted, and
  ///      the UI is told ([CloudDisableException]);
  ///  (b) the native side is restricted (no network), the revoke inputs are
  ///      FROZEN (owner, generation, version, install, JWT of THAT owner, secret,
  ///      uid-bound ack), the in-flight requests are drained (bounded, then
  ///      cancelled) and at most ONE revoke is sent: its `revoke_attempt` is
  ///      durably written (consumed) BEFORE the send, there is no retry, no
  ///      relink, no 401 recovery and no startup replay; the outcome is
  ///      [serverRevocation];
  ///  (c) [commitLocalOff] persists Cloud OFF, then durable OFF replaces
  ///      DISABLING and only then is the freeze lifted. If the local write fails
  ///      the freeze stays on, DISABLING is re-written and the error is rethrown.
  /// A crash leaves DISABLING: [resolvePendingDisable] commits OFF locally at
  /// the next start (never a revoke). The callback is skipped when the account
  /// changed under the transition (the marker stays for its owner). Bytes
  /// already transmitted before DISABLING cannot be recalled.
  Future<void> disableCloud({
    required Future<void> Function() commitLocalOff,
  }) =>
      _disableInFlight ??= _disableCloud(commitLocalOff)
          .whenComplete(() => _disableInFlight = null);

  Future<void> _disableCloud(Future<void> Function() commitLocalOff) async {
    ConsentAuthority.freeze('disable');
    _gate.advanceEpoch(EpochCause.cloudDisable); // P4: advance BEFORE any transition work
    final sessionUid = _readSession()?.uid;
    // The user confirmed OFF: the native upload paths are closed FIRST, by
    // restrictive owner-scoped writes that do not depend on the DISABLING
    // allocation below (which can fail on its own). Dart egress is already
    // frozen above; nothing in this transition reopens either.
    String? nativeOwner;
    try {
      nativeOwner = await _readReplicaOwnerUid();
    } catch (_) {}
    await _withdrawNativeFirst(
        (nativeOwner?.isNotEmpty ?? false) ? nativeOwner : sessionUid,
        'disable');
    String? owner;
    DisableFreeze? freeze;
    try {
      try {
        owner = await _readReplicaOwnerUid() ?? '';
        final settings = await _settingsRepository.getSettings();
        freeze = await _gate.beginDisabling(
            owner: owner, reservedVersion: settings.consentVersion + 1);
        await _restrictNativeSide(freeze);
        final inputs = await _captureRevokeInputs(freeze, settings);
        await _gate.drain();
        await _gate.drainNative(freeze.owner);
        await _revokeOnce(freeze, inputs);
      } catch (e) {
        // Nothing above may block the local OFF below. Without a durable
        // DISABLING record no revoke can have been sent (see beginDisabling).
        final refusal = freeze == null ? CloudEgressStore.lastWriteRefusal : '';
        ConsentAuthority.egressFreezeTag =
            'disable:${freeze == null ? 'begin' : 'after_begin'}:'
            '${e.runtimeType}${refusal.isEmpty ? '' : ':$refusal'}';
        debugPrint('[ConsentDisable] ${ConsentAuthority.egressFreezeTag}');
      }
    } finally {
      await _finishDisable(commitLocalOff, owner, sessionUid, freeze);
    }
  }

  Future<void> _finishDisable(
    Future<void> Function() commitLocalOff,
    String? owner,
    String? sessionUid,
    DisableFreeze? freeze,
  ) async {
    // P4: the callback writes the CURRENT replica. If the account changed under
    // the transition it must not touch the new owner; the DISABLING marker stays
    // for the old owner's next admission and the new owner is evaluated alone.
    var sameOwner = false;
    try {
      sameOwner = owner != null &&
          (await _readReplicaOwnerUid() ?? '') == owner &&
          _readSession()?.uid == sessionUid;
    } catch (_) {}
    if (!sameOwner) {
      ConsentAuthority.egressFrozen = false;
      throw const CloudDisableException('owner_changed');
    }
    // FAIL CLOSED: if the local OFF write fails, the process-wide freeze stays
    // on, Cloud is never restored to ON, nothing more is sent, and DISABLING is
    // re-written so the next launch completes OFF.
    try {
      await commitLocalOff();
    } catch (_) {
      if (freeze != null) await _gate.rewriteDisabling(freeze);
      rethrow;
    }
    if (freeze == null) {
      // DISABLING never became durable: egress stays denied in this process and
      // the UI is NOT told that OFF succeeded.
      throw const CloudDisableException('disabling_not_durable');
    }
    if (await _gate.commitOff(freeze)) {
      ConsentAuthority.egressFrozen = false;
      await _gate.refresh();
    }
    // else: durable OFF could not be written; DISABLING (denied) is still
    // there and the freeze stays, so nothing reopens.
  }

  /// Astra G: an explicit enable (the only way out of the persistent OFF gate).
  /// Advances to a NEW transition generation and version (strictly greater),
  /// writes ON to every store, lifts the freeze, then commits the local consent
  /// (the typed [write]) and the existing ON path ([syncBackendState]).
  ///
  /// The bounded local part (gate write, settings commit) runs inside the
  /// session's local drain; a revoked or mismatched capability fails with
  /// [StaleAdmissionException] and leaves nothing ON. Calls are SERIALIZED, never
  /// coalesced: every caller's own commit runs (or the call fails), so a caller is
  /// never told its settings were saved by somebody else's commit; a stale call
  /// neither joins nor outlives another scope's in-flight enable.
  ///
  /// The local phase is a typed [write]: a [ConsentCapability] plus the changed
  /// [ConsentChoices]. It runs under the consent runner, which is also open to the
  /// committed fresh identity (needsOnboarding) and ONLY through that typed
  /// capability, and its commit is the repository's typed transaction: the
  /// capability, database and replica owner are verified inside it, and the
  /// settings and outbox roll back together if the lifecycle ended before its
  /// final synchronous check. A commit that passed that check is a legitimate
  /// local persistence and is not claimed to be rolled back; the gate is then
  /// restricted again if the lifecycle ended before the freeze lifts. There is no
  /// caller-supplied save callback on this public API: a callback is not
  /// evidence of authorization.
  ///
  /// On iOS (a native barrier exists) the enable is the durable two-runtime
  /// transition of [_enableCloudNative]: the owner prerequisite, Dart denial
  /// first, the native barrier, ON only under both barriers, the typed local
  /// choice, native completion and only then the clearing of the Dart denial.
  /// It throws [CloudEnableIncompleteException] when Cloud did not turn on and
  /// [StaleAdmissionException] when the lifecycle ended; a crash or any failure
  /// leaves Cloud denied. Other platforms keep the separate Dart-only path.
  Future<void> enableCloud({required ConsentWrite write}) =>
      _enableCloudWith(write: write);

  /// Test-only entry that keeps the pre-existing contract tests of the gate and
  /// the registration service (which have no AppSession lifecycle to hold a
  /// capability) on the callback form. [commitLocalOn] is the caller's local save
  /// and [authority] the committed local-work authority it captured before its
  /// first await (default: captured now). Production code must not call it: that
  /// is enforced by source (a contract test), not by a runtime boundary.
  @visibleForTesting
  Future<void> enableCloudForTest({
    required Future<void> Function() commitLocalOn,
    AdmissionAuthority? authority,
  }) =>
      _enableCloudWith(commitLocalOn: commitLocalOn, authority: authority);

  Future<void> _enableCloudWith({
    Future<void> Function()? commitLocalOn,
    ConsentWrite? write,
    AdmissionAuthority? authority,
  }) async {
    if ((commitLocalOn == null) == (write == null)) {
      throw ArgumentError('pass exactly one of commitLocalOn and write');
    }
    final capability = write?.capability;
    final admission = capability != null
        ? AdmissionAuthority(capability.uid, () => capability.isCurrent,
            epoch: capability.epoch)
        : (authority ?? _captureWorkAuthority());
    final epochOwner = admission?.uid ?? _readSession()?.uid ?? '';
    final enableWithdrawalEpoch = _withdrawalEpochOf(epochOwner);
    final lifetime =
        _captureLifetime(requireAdmission: true, admissionAuthority: admission);
    bool current() =>
        lifetime() && _withdrawalEpochOf(epochOwner) == enableWithdrawalEpoch;
    while (true) {
      if (!current()) throw const StaleAdmissionException();
      final pending = _disableInFlight ?? _enableInFlight;
      if (pending == null) break;
      try {
        await pending;
      } catch (_) {}
    }
    if (write != null && _usesNativeBarrier) {
      // iOS: the durable two-runtime transition (N-E). The Dart-only path below
      // is the separate explicit path of platforms without a native barrier.
      late final Future<void> nativeFlight;
      nativeFlight = _enableCloudNative(write, current).whenComplete(() {
        if (identical(_enableInFlight, nativeFlight)) _enableInFlight = null;
      });
      _enableInFlight = nativeFlight;
      return nativeFlight;
    }
    final Future<void> Function() commit = write != null
        ? () async {
            await _settingsRepository.saveConsentChoice(
                write.capability, write.choices);
          }
        : commitLocalOn!;
    Future<void> run() => _enableCloud(commit, current, admission);
    late final Future<void> flight;
    flight = (capability != null
            ? AppSession.instance.runConsentLocalOperation(capability, run)
            : admission == null
                ? run()
                : AppSession.instance.runAdmittedLocalOperation(admission, run))
        .whenComplete(() {
      if (identical(_enableInFlight, flight)) _enableInFlight = null;
    });
    _enableInFlight = flight;
    return flight;
  }

  Future<void> _enableCloud(
    Future<void> Function() commitLocalOn,
    bool Function() current,
    AdmissionAuthority? admission,
  ) async {
    if (!current()) throw const StaleAdmissionException();
    _gate.advanceEpoch(EpochCause.cloudEnable);
    final owner = await _readReplicaOwnerUid() ?? '';
    if (!current() || (admission != null && owner != admission.uid)) {
      throw const StaleAdmissionException();
    }
    final settings = await _settingsRepository.getSettings();
    if (!current()) throw const StaleAdmissionException();
    final written = await _gate.enable(
        owner: owner,
        reservedVersion: settings.consentVersion + 1,
        isCurrent: current);
    // From here on a failure restricts exactly the record written above (the
    // gate leaves any newer one alone). The freeze is NOT lifted until the
    // consent is saved, so a failure never leaves a usable widening behind. If
    // the restriction itself cannot be established that is reported as such
    // (never as the original error or a success), and a still-current scope
    // fails closed; a revoked one must not freeze a newer scope.
    Future<Never> abandon(Object error) async {
      var restricted = false;
      try {
        restricted = await _gate.restrictWrittenOn(written);
      } catch (_) {}
      if (restricted) throw error;
      if (current()) ConsentAuthority.freeze('enable_not_restricted');
      throw const EgressWriteFailedException('enable_not_restricted');
    }

    if (!current()) await abandon(const StaleAdmissionException());
    try {
      await commitLocalOn();
    } catch (error) {
      // Not saved: the gate must not stay ON without the consent. A failure
      // after the scope was revoked (its database closed) is staleness.
      await abandon(current() ? error : const StaleAdmissionException());
    }
    if (!current()) await abandon(const StaleAdmissionException());
    ConsentAuthority.egressFrozen = false;
    await _gate.refresh();
    if (!current()) await abandon(const StaleAdmissionException());
  }

  // ── N-E: the native-backed enable ─────────────────────────────────────────

  /// iOS (a native barrier exists): the enable is a durable two-runtime
  /// transition. Platforms without the native queue use the separate explicit
  /// Dart-only path in [_enableCloud].
  bool get _usesNativeBarrier => _isIos() && NativeCaptureBridge.hasNativeQueue;

  /// The owner whose process-wide freeze the running native enable holds, so a
  /// stale flight never releases a newer one's freeze.
  static Object? _enableFreeze;

  static String _randomOperationId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }

  /// Phase 0 of [_enableCloudNative]: the preflight of a NEW explicit operation.
  /// It has exactly three outcomes. A verified new operation (no pending
  /// operation of the owner; both native egress layers absent, or agreeing on the
  /// same OFF record with no barrier) reserves the consent version and returns
  /// the publication plan, carrying the recovery expectation when native holds
  /// that OFF record. An exact resume (the owner already has a pending operation
  /// of its own) returns null: Phase 1 reconciles it before lifetime proof. Anything
  /// else (native ON or DISABLING ahead of the local history, disagreeing or
  /// unreadable layers, a barrier native holds that Dart does not, a failed
  /// inspection) is REFUSED with an allowlisted reason; it never falls through to
  /// an ordinary publication or an unverified local version.
  Future<RestrictivePublishPlan?> _reserveEnableVersion(
      ConsentCapability capability,
      bool Function() current,
      String operationId,
      {PendingEnableRecord? cleanupPending, bool repaired = false}) async {
    final String owner;
    try {
      owner = await _readReplicaOwnerUid() ?? '';
    } catch (_) {
      if (!current()) throw const StaleAdmissionException();
      throw const CloudEnableIncompleteException(
          'preflight_uncertain[owner_read]');
    }
    if (!current() || owner != capability.uid) {
      throw const StaleAdmissionException();
    }
    // TEMPORARY diagnostic suffixes on every `preflight_uncertain` below: which
    // check refused, as fixed literals, enum names and layer labels only (never
    // a uid, hash, generation, version or operation id).
    final PendingReadout pendingReadout;
    try {
      pendingReadout = await _gate.readPending();
    } catch (_) {
      throw const CloudEnableIncompleteException(
          'preflight_uncertain[pending_read]');
    }
    if (!current()) throw const StaleAdmissionException();
    if (pendingReadout.unreadable) {
      throw CloudEnableIncompleteException(
          'preflight_uncertain[pending_layers'
          '|s:${pendingReadout.secure.status.name}'
          ',f:${pendingReadout.file.status.name}]');
    }
    final pending =
        pendingReadout.agreed(owner) ?? pendingReadout.partial(owner);
    if (pending == null && pendingReadout.blocks(owner)) {
      throw const CloudEnableIncompleteException('preflight_conflict/dart_pending');
    }
    final CloudEgressEnableResult inspected;
    final ({List<CloudEgressRecord> records, bool uncertain}) dart;
    try {
      inspected =
          (await NativeCaptureBridge.getCloudEgressPending(ownerUid: owner))!;
    } catch (e) {
      if (!current()) throw const StaleAdmissionException();
      throw CloudEnableIncompleteException('preflight_uncertain[native_inspect'
          '|${e is CaptureQueueException ? e.safeDiagnostic : e.runtimeType}]');
    }
    try {
      dart = await _gate.store.readDartOwnerLayers(owner);
    } catch (_) {
      if (!current()) throw const StaleAdmissionException();
      throw const CloudEnableIncompleteException(
          'preflight_uncertain[dart_layers_read]');
    }
    if (!current()) throw const StaleAdmissionException();
    bool physical(List<CloudEgressLayerReport> reports) =>
        reports.length == 2 &&
        reports[0].layer == 'file' &&
        reports[1].layer == 'keychain';
    final reports = inspected.egress;
    if (dart.uncertain ||
        inspected.operation != 'inspect' ||
        !physical(reports) ||
        !physical(inspected.barrier) ||
        [...reports, ...inspected.barrier].any((r) =>
            r.outcome != CloudEgressLayerOutcome.verified &&
            r.outcome != CloudEgressLayerOutcome.absent)) {
      String outcomes(List<CloudEgressLayerReport> layers) =>
          layers.map((r) => r.outcome.name).join(',');
      final flags = [
        if (dart.uncertain) 'dart',
        if (inspected.operation != 'inspect') 'op',
        if (!physical(reports)) 'eshape',
        if (!physical(inspected.barrier)) 'bshape',
      ].join(',');
      throw CloudEnableIncompleteException('preflight_uncertain[layers|$flags'
          '|e:${outcomes(reports)}|b:${outcomes(inspected.barrier)}'
          '|${inspected.status.name}]');
    }
    for (final (i, r) in [...reports, ...inspected.barrier].indexed) {
      if (r.outcome == CloudEgressLayerOutcome.absent &&
          (r.state != null ||
              r.transitionGeneration != null ||
              r.reservedVersion != null ||
              r.operationId != null ||
              r.ownerGeneration != null ||
              r.ownerEpoch != null)) {
        // `physical` above proved the order file, keychain in both lists.
        throw CloudEnableIncompleteException('preflight_uncertain[absent_fields'
            '|${i < 2 ? 'e' : 'b'}:${i.isEven ? 'file' : 'keychain'}]');
      }
    }
    final held = reports
        .where((r) => r.outcome == CloudEgressLayerOutcome.verified)
        .toList();
    // F1: a lifetime fence leaves OFF + retirement in native. That exact shape
    // (EVERY held layer OFF under the SAME complete retirement) is recognised
    // here and only here; it is normalised below under strict conditions. Any
    // other operation id on a held layer stays refused.
    final retiredOff = held.isNotEmpty &&
        held.every((r) =>
            r.state == 'OFF' &&
            r.operationId != null &&
            r.operationId == held.first.operationId &&
            r.transitionGeneration != null &&
            r.transitionGeneration! >= 0 &&
            r.transitionGeneration == held.first.transitionGeneration &&
            r.reservedVersion != null &&
            r.reservedVersion! >= 0 &&
            r.reservedVersion == held.first.reservedVersion &&
            r.ownerGeneration != null &&
            r.ownerGeneration == held.first.ownerGeneration &&
            r.ownerEpoch != null &&
            r.ownerEpoch == held.first.ownerEpoch);
    if (!retiredOff) {
      for (final r in held) {
        final flags = [
          if (r.transitionGeneration == null || r.transitionGeneration! < 0)
            'gen',
          if (r.reservedVersion == null || r.reservedVersion! < 0) 'ver',
          if (r.operationId != null) 'op',
          if ((r.ownerGeneration == null) != (r.ownerEpoch == null)) 'life',
        ];
        final known = const {'ON', 'OFF', 'DISABLING'}.contains(r.state);
        if (!known || flags.isNotEmpty) {
          throw CloudEnableIncompleteException('preflight_uncertain[held_fields'
              '|${r.layer}:${known ? r.state : 'bad'}:${flags.join(',')}]');
        }
      }
    }
    var frontier = 0;
    for (final v in [
      ...dart.records.map((r) => r.reservedVersion),
      ...held.map((r) => r.reservedVersion!),
      // A layer report substitutes a retirement's version for the entry's own;
      // native names the true stored maximum separately. It can only raise.
      inspected.egressVersionFrontier ?? 0,
    ]) {
      if (v > frontier) frontier = v;
    }
    final nativeBinding = inspected.binding;
    final exactBarrier = pending != null &&
        nativeBinding != null &&
        (pending.binding == null || pending.binding == nativeBinding) &&
        nativeBinding.transitionGeneration == pending.transitionGeneration &&
        nativeBinding.reservedVersion == pending.reservedVersion &&
        inspected.status == CloudEgressTransitionStatus.pending &&
        inspected.barrier.every((r) =>
            r.outcome == CloudEgressLayerOutcome.verified &&
            r.operationId == nativeBinding.operationId &&
            r.transitionGeneration == nativeBinding.transitionGeneration &&
            r.reservedVersion == nativeBinding.reservedVersion &&
            r.ownerGeneration == nativeBinding.ownerGeneration &&
            r.ownerEpoch == nativeBinding.ownerEpoch);
    bool ownOn(int generation, int version) =>
        exactBarrier &&
        generation == pending.transitionGeneration &&
        version == pending.reservedVersion;
    final dartAhead = [
      for (final (i, r) in dart.records.indexed)
        if (r.state != EgressState.off &&
            !(r.state == EgressState.on &&
                ownOn(r.transitionGeneration, r.reservedVersion)))
          'd$i:${r.state.wire}',
    ];
    final nativeAhead = [
      for (final r in held)
        if (r.state != 'OFF' &&
            !(r.state == 'ON' &&
                ownOn(r.transitionGeneration!, r.reservedVersion!) &&
                r.ownerGeneration == nativeBinding?.ownerGeneration &&
                r.ownerEpoch == nativeBinding?.ownerEpoch))
          '${r.layer}:${r.state}',
    ];
    final noBarrier =
        inspected.status == CloudEgressTransitionStatus.noBarrier &&
            inspected.barrier
                .every((r) => r.outcome == CloudEgressLayerOutcome.absent);
    // Reinstalling can remove the App Group file while Keychain retains OFF.
    // Divergent generation/version copies with the SAME lifetime are likewise
    // restrictive, readable evidence. Normalize them to a verified newer OFF
    // before reserving anything. Different lifetimes use the conditional
    // restrictive publication below.
    final repairOffCopies = !retiredOff && held.isNotEmpty &&
        held.every((r) => r.state == 'OFF' &&
            r.ownerGeneration == held.first.ownerGeneration &&
            r.ownerEpoch == held.first.ownerEpoch) &&
        (held.length != 2 || held.any((r) =>
            r.transitionGeneration != held.first.transitionGeneration ||
            r.reservedVersion != held.first.reservedVersion));
    final recoverUnboundFreeze = ConsentAuthority.egressFrozen &&
        ConsentAuthority.egressFreezeTag ==
            'reconcile_uncertain:native:lifetime_fields_unbound';
    final freezeGeneration = ConsentAuthority.freezeGeneration;
    if (retiredOff) {
      // F1: only an explicit enable with NOTHING else unresolved may replace the
      // retired OFF, and only by a fresh restrictive publication that native
      // compares against exactly this snapshot under its write lock. Every
      // refusal leaves all layers untouched; nothing here writes ON.
      if (pending != null || cleanupPending != null) {
        throw const CloudEnableIncompleteException(
            'preflight_conflict/retired_pending');
      }
      if (!noBarrier) {
        throw const CloudEnableIncompleteException(
            'preflight_conflict/native_barrier');
      }
      if (_gate.holdActive || _gate.successorUnsettled) {
        // The retirement may carry expiry evidence a session-recovery successor
        // is about to consume: never overwrite it underneath that chain.
        throw const CloudEnableIncompleteException(
            'preflight_conflict/retired_successor');
      }
      if (!await _storedCloudOff(current)) {
        throw const CloudEnableIncompleteException(
            'preflight_conflict/retired_stored_on');
      }
      if (inspected.egressVersionFrontier == null) {
        throw const CloudEnableIncompleteException(
            'preflight_uncertain[retired_frontier]');
      }
      if (dartAhead.isNotEmpty && !repaired) {
        // A sign-out retires native but leaves the Dart layers' ON behind. The
        // allocating repair cannot run over a retired native record, so restrict
        // exactly the observed Dart ON records (the existing exact-record
        // compensation, read back), then judge again from fresh evidence.
        if (dart.records.any((r) => r.state == EgressState.disabling)) {
          throw const CloudEnableIncompleteException(
              'preflight_conflict/retired_dart_disabling');
        }
        for (final r in dart.records) {
          if (r.state != EgressState.on) continue;
          final PendingWriteResult restricted;
          try {
            restricted = await _gate.restrictDartLayers(r);
          } catch (_) {
            if (!current()) throw const StaleAdmissionException();
            throw const CloudEnableIncompleteException(
                'preflight_repair_incomplete/retired_dart_write');
          }
          if (!current()) throw const StaleAdmissionException();
          if (!restricted.all) {
            throw const CloudEnableIncompleteException(
                'preflight_repair_incomplete/retired_dart_write');
          }
        }
        return _reserveEnableVersion(capability, current, operationId,
            repaired: true);
      }
    }
    if ((dartAhead.isNotEmpty || nativeAhead.isNotEmpty ||
            recoverUnboundFreeze || repairOffCopies) &&
        !repaired &&
        pending == null &&
        cleanupPending == null &&
        noBarrier &&
        await _storedCloudOff(current)) {
      // A previous session left ON/DISABLING residue, or reinstall left only
      // one native OFF copy. Cloud is stored OFF and no operation is pending:
      // drive every layer to a verified OFF, then rerun this preflight once
      // from fresh evidence.
      await _repairStaleEgressOff(owner, frontier, current);
      if (!current()) throw const StaleAdmissionException();
      // This exact reconciliation freeze is obsolete only after all four
      // layers have been verified restrictive. A concurrent freeze survives.
      if (recoverUnboundFreeze) {
        ConsentAuthority.releaseFreeze(freezeGeneration, wasFrozen: false);
      }
      return _reserveEnableVersion(capability, current, operationId,
          repaired: true);
    }
    if (dartAhead.isNotEmpty || nativeAhead.isNotEmpty) {
      // Which layer is ahead (layer label and state only), so a field report
      // names the stale layer. TEMPORARY diagnostic suffix.
      throw CloudEnableIncompleteException(
        'preflight_on_ahead[${[...dartAhead, ...nativeAhead].join(',')}'
        '|${inspected.status.name}]',
      );
    }
    if (!noBarrier && !exactBarrier) {
      throw const CloudEnableIncompleteException('preflight_conflict/native_barrier');
    }
    if (cleanupPending != null) {
      if (pending != cleanupPending || pending?.binding != null || !noBarrier) {
        throw const CloudEnableIncompleteException('preflight_conflict/cleanup_pending');
      }
      final liveOwner = await _readCaptureOwner();
      final liveEpoch = await _readOwnerEpoch();
      if (!current()) throw const StaleAdmissionException();
      if (liveOwner == null || liveOwner.uid != owner || held.any((r) =>
          r.ownerGeneration != null &&
          (r.ownerGeneration != liveOwner.generation || r.ownerEpoch != liveEpoch))) {
        throw const CloudEnableIncompleteException('preflight_conflict/cleanup_lifetime');
      }
    }
    int? expectGeneration;
    int? expectVersion;
    int? expectLifetimeGeneration;
    int? expectLifetimeEpoch;
    if (pending != null) {
      // An unbound denial with verified absent native barriers is cleaned in
      // Phase 1, never resumed as ON. An older pending generation may coexist
      // with a newer OFF publication; the next operation allocates afresh.
      // Keep the version frontier and native agreement checks even for cleanup.
      final deniedCleanup = pending.binding == null && noBarrier &&
          (held.isEmpty || (held.length == 2 && held.every((r) =>
              r.transitionGeneration == held.first.transitionGeneration &&
              r.reservedVersion == held.first.reservedVersion &&
              r.ownerGeneration == held.first.ownerGeneration &&
              r.ownerEpoch == held.first.ownerEpoch)));
      if ((pending.binding == null && noBarrier && !deniedCleanup) ||
          frontier > pending.reservedVersion ||
          (!deniedCleanup && dart.records.any(
              (r) => r.transitionGeneration > pending.transitionGeneration)) ||
          held.any((r) =>
              (!deniedCleanup && r.transitionGeneration! > pending.transitionGeneration) ||
              (nativeBinding != null &&
                  r.ownerGeneration != null &&
                  (r.ownerGeneration != nativeBinding.ownerGeneration ||
                      r.ownerEpoch != nativeBinding.ownerEpoch)))) {
        throw const CloudEnableIncompleteException('preflight_conflict/pending_frontier');
      }
      return null; // Phase 1 reconciles pending before lifetime acquisition.
    }
    List<CloudEgressLayerReport>? expectedOffCopies;
    List<CloudEgressLayerReport>? expectedRetiredCopies;
    if (retiredOff) {
      // Both physical reports (a retired OFF, or a verified absence beside one),
      // exactly as inspected: native republishes only over this snapshot.
      expectedRetiredCopies = List.unmodifiable(reports);
    } else if (held.isNotEmpty) {
      final first = held.first;
      if (held.length != 2 ||
          held.any((r) =>
              r.transitionGeneration != first.transitionGeneration ||
              r.reservedVersion != first.reservedVersion ||
              r.ownerGeneration != first.ownerGeneration ||
              r.ownerEpoch != first.ownerEpoch)) {
        if (noBarrier && held.length == 2 &&
            held.every((r) => r.state == 'OFF') &&
            await _storedCloudOff(current)) {
          // A partial earlier publication can leave OFF copies naming
          // different lifetimes. The explicit consent reserves above their
          // frontier, then native compares BOTH snapshots under the write lock
          // and publishes a fresh restrictive lifetime before enable begins.
          expectedOffCopies = List.unmodifiable(reports);
        } else {
          throw const CloudEnableIncompleteException(
              'preflight_conflict/native_copies');
        }
      } else {
        expectGeneration = first.transitionGeneration;
        expectVersion = first.reservedVersion;
        expectLifetimeGeneration = first.ownerGeneration;
        expectLifetimeEpoch = first.ownerEpoch;
      }
    }
    final int version;
    try {
      version = await _settingsRepository.reserveConsentVersion(capability,
          verifiedFrontier: frontier, operationId: operationId);
    } on StaleAdmissionException {
      rethrow;
    } catch (e) {
      throw CloudEnableIncompleteException(
          'preflight_uncertain[reserve|${e.runtimeType}]');
    }
    if (!current()) throw const StaleAdmissionException();
    return RestrictivePublishPlan(version,
        expectedTransitionGeneration: expectGeneration,
        expectedReservedVersion: expectVersion,
        expectedLifetimeOwnerGeneration: expectLifetimeGeneration,
        expectedLifetimeOwnerEpoch: expectLifetimeEpoch,
        expectedOffCopies: expectedOffCopies,
        expectedRetiredCopies: expectedRetiredCopies);
  }

  /// True only when the stored Cloud choice is not accepted (unset or
  /// declined): the repair below never runs over a stored ON.
  Future<bool> _storedCloudOff(bool Function() current) async {
    try {
      final settings = await _settingsRepository.getSettings();
      if (!current()) throw const StaleAdmissionException();
      return settings.cloudConsentState != ConsentState.accepted;
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      return false;
    }
  }

  /// Restrictive repair of stale ON/DISABLING layers of [owner] before a new
  /// enable. Writes one allocated OFF to every layer (generation above every
  /// verified layer, version never below [frontier]) and then requires EVERY
  /// physical layer — Dart secure and file, native file and keychain — to read
  /// back OFF (or absent) with no barrier. A merged OFF or a write reporting
  /// "any" is not enough. Anything less keeps Cloud off and fails the enable
  /// honestly; nothing here can make egress more permissive.
  Future<void> _repairStaleEgressOff(
      String owner, int frontier, bool Function() current) async {
    Never incomplete(String stage) =>
        throw CloudEnableIncompleteException('preflight_repair_incomplete/$stage');
    final EgressWriteResult? written;
    try {
      written = await _gate.alignOff(
          CloudEgressRecord(
            state: EgressState.off,
            ownerUid: owner,
            transitionGeneration: 0,
            reservedVersion: frontier,
          ),
          isCurrent: current,
          onlyOwner: true);
    } on StaleAdmissionException {
      rethrow;
    } catch (_) {
      incomplete('write_error');
    }
    if (!current()) throw const StaleAdmissionException();
    // Null: an unverifiable layer, nothing written. A refused native write
    // (it holds its own lifetime guards) is judged by the readback below: it
    // passes only if native already reads OFF.
    if (written == null) incomplete('allocation');
    final CloudEgressEnableResult inspected;
    final ({List<CloudEgressRecord> records, bool uncertain}) dart;
    try {
      inspected =
          (await NativeCaptureBridge.getCloudEgressPending(ownerUid: owner))!;
      dart = await _gate.store.readDartOwnerLayers(owner);
    } catch (_) {
      if (!current()) throw const StaleAdmissionException();
      incomplete('read_error');
    }
    if (!current()) throw const StaleAdmissionException();
    bool offOrAbsent(CloudEgressLayerReport r) =>
        r.outcome == CloudEgressLayerOutcome.absent ||
        (r.outcome == CloudEgressLayerOutcome.verified && r.state == 'OFF');
    if (dart.uncertain ||
        dart.records.length != 2 ||
        dart.records.any((r) => r.state != EgressState.off) ||
        inspected.operation != 'inspect' ||
        inspected.status != CloudEgressTransitionStatus.noBarrier ||
        inspected.egress.length != 2 ||
        !inspected.egress.every(offOrAbsent) ||
        !inspected.barrier
            .every((r) => r.outcome == CloudEgressLayerOutcome.absent)) {
      incomplete('unverified_off');
    }
  }

  /// Phases 1-6 of the ratified enable. Dart denies first; the native barrier is
  /// established; ON is written only under both barriers; the typed local choice
  /// is committed (the only work inside the consent local drain); native
  /// completes; only then is the Dart denial cleared. Any failure or crash leaves
  /// Cloud denied. NO backend registration, link or consent push happens here:
  /// they follow a successful return only.
  Future<void> _enableCloudNative(
      ConsentWrite write, bool Function() current) async {
    final capability = write.capability;
    if (!current()) throw const StaleAdmissionException();
    Never incomplete(String reason) => throw CloudEnableIncompleteException(reason);

    // Phase 1 — owner prerequisite, BEFORE any freeze and before anything is
    // enabled: the committed identity's verified restrictive owner publication
    // and a native read-back of exactly that lifecycle.
    // Phase 0 — the version this explicit operation will commit at, reserved
    // strictly above the device's local history AND the owner's verified native
    // egress frontier (a replica reset to unset/v0 under native rv2 would
    // otherwise publish a stale version). Allocation metadata only: no consent
    // state changes here. Null when an unresolved operation of the owner exists.
    final reservationOp = _randomOperationId();
    var plan = await _reserveEnableVersion(capability, current, reservationOp);
    if (!current()) throw const StaleAdmissionException();
    PendingEnableLifetimeProof? resumeLifetime;
    if (plan == null) {
      final read = await _gate.readPending();
      if (!current()) throw const StaleAdmissionException();
      final pending = read.agreed(capability.uid) ?? read.partial(capability.uid);
      if (pending != null) {
        // Explicit repair is separate from proof minting; the proof itself is
        // read-only and always requires both matching durable copies.
        if (read.agreed(capability.uid) == null &&
            !(await _gate.repairPendingEnable(pending)).all) {
          incomplete('pending_unresolved');
        }
        if (!current()) throw const StaleAdmissionException();
        try {
          if (pending.binding != null) {
            resumeLifetime = await _gate.provePendingEnableLifetime(capability, pending);
          } else {
            final inspected = await NativeCaptureBridge.getCloudEgressPending(
                ownerUid: capability.uid);
            if (!current()) throw const StaleAdmissionException();
            if (inspected != null &&
                inspected.status == CloudEgressTransitionStatus.pending &&
                inspected.binding != null) {
              resumeLifetime = await _gate.bindPendingEnableLifetime(
                  capability, pending, inspected.binding!);
            } else {
              // A denied stage that never reached native begin must be cleared
              // before publication. Reuse the physical frontier preflight and
              // require a coherent live lifetime before clearing exact copies.
              if (await _reserveEnableVersion(capability, current, reservationOp,
                      cleanupPending: pending) != null ||
                  (await _gate.readPending()).agreed(capability.uid) != pending) {
                incomplete('pending_unresolved');
              }
              if (!current()) throw const StaleAdmissionException();
              if (!(await _gate.clearPendingEnable(pending)).all) {
                incomplete('pending_unresolved');
              }
              if (!current()) throw const StaleAdmissionException();
              plan = await _reserveEnableVersion(capability, current, reservationOp);
              if (plan == null) incomplete('pending_unresolved');
            }
          }
        } catch (_) {
          if (!current()) throw const StaleAdmissionException();
          incomplete('pending_unresolved');
        }
      }
    }
    final proof = resumeLifetime == null
        ? await AppSession.instance.ensureCommittedOwnerLifetime(capability, plan: plan)
        : await AppSession.instance.resumeCommittedOwnerLifetime(capability, resumeLifetime);
    if (!current()) throw const StaleAdmissionException();
    final lifetime = proof.binding;
    if (lifetime == null) incomplete(proof.reason);
    final String owner;
    final int nativeEpoch;
    final CaptureOwnerRecord? nativeOwner;
    try {
      owner = await _readReplicaOwnerUid() ?? '';
      nativeOwner = await _readCaptureOwner();
      nativeEpoch = await _readOwnerEpoch();
    } catch (_) {
      if (!current()) throw const StaleAdmissionException();
      incomplete('owner_readback');
    }
    if (!current() || owner != capability.uid ||
        _readSession()?.uid != owner) {
      throw const StaleAdmissionException();
    }
    if (nativeOwner == null ||
        nativeOwner.uid != owner ||
        nativeOwner.generation != lifetime.ownerGeneration ||
        nativeEpoch != lifetime.ownerEpoch) {
      incomplete('owner_mismatch');
    }

    // Phase 2 — freeze Dart admission SYNCHRONOUSLY (no await since the check
    // above), then the durable pending denial.
    final wasFrozen = ConsentAuthority.egressFrozen;
    final token = Object();
    _enableFreeze = token;
    ConsentAuthority.freeze('pending_enable');
    _gate.freezeEnable(owner);

    PendingEnableRecord? pending;
    // Every pending record shape this flow may have left in a layer (unbound,
    // and bound after a partially applied bind): compensation clears them all.
    final pendingShapes = <PendingEnableRecord>[];
    // Native `begin` was dispatched and its binding is not known (the reply was
    // lost, null or unparseable): the operation cannot be proven abandoned.
    var beginUnknown = false;
    CloudEgressEnableBinding? binding;
    CloudEgressRecord? dartOn;
    var settingsCommitted = false;
    var completeDispatched = false;
    var success = false;
    var uncertain = false;

    Future<CloudEgressEnableResult?> nativeCall(
        Future<CloudEgressEnableResult?> Function() call) async {
      try {
        return await call();
      } catch (_) {
        return null;
      }
    }

    // Exact-binding compensation. True only when nothing of this operation
    // remains: native restricted AND abandoned (both confirmed), the Dart ON the
    // flow wrote restricted, and the Dart pending cleared with read-back.
    Future<bool> compensate() async {
      final b = binding;
      if (b != null) {
        final restricted = await nativeCall(() =>
            NativeCaptureBridge.restrictCloudEgressEnable(
                ownerUid: owner, binding: b));
        if (restricted == null || !restricted.confirmsRestricted(b)) {
          return false;
        }
      }
      final on = dartOn;
      if (on != null && !(await _gate.restrictDartLayers(on)).all) {
        return false;
      }
      if (b != null) {
        final abandoned = await nativeCall(() =>
            NativeCaptureBridge.finishCloudEgressEnable(
                ownerUid: owner, binding: b, abandon: true));
        if (abandoned == null || !abandoned.confirmsAbandoned(b)) return false;
      }
      if (b == null && beginUnknown) return false;
      final latestPending = pending;
      for (final p in {if (latestPending != null) latestPending, ...pendingShapes}) {
        if (!(await _gate.clearPendingEnable(p)).all) return false;
      }
      // Only a read-back that shows no pending of this owner left in either
      // layer is a clean compensation.
      return !(await _gate.readPending()).blocks(owner);
    }

    // A lifecycle that ended at an await: undo what is provably ours, EXCEPT
    // once native completion was dispatched (it may have run; the Dart denial is
    // then kept), and report staleness.
    Future<void> guard() async {
      if (current()) return;
      if (!completeDispatched) {
        try {
          await compensate();
        } catch (_) {}
      } else {
        uncertain = true;
      }
      throw const StaleAdmissionException();
    }

    Future<Never> abort(String reason) async {
      bool clean;
      try {
        clean = await compensate();
      } catch (_) {
        clean = false;
      }
      if (!clean) uncertain = true;
      if (!current()) throw const StaleAdmissionException();
      incomplete(reason);
    }

    try {
      final settings = await _settingsRepository.getSettings();
      if (!current()) throw const StaleAdmissionException();
      final readout = await _gate.readPending();
      if (!current()) throw const StaleAdmissionException();
      if (readout.unreadable ||
          (readout.secure.records.containsKey(owner) &&
              readout.file.records.containsKey(owner) &&
              readout.agreed(owner) == null)) {
        uncertain = true;
        incomplete('pending_unresolved');
      }

      var existing = readout.agreed(owner) ?? readout.partial(owner);
      var generation = 0;
      var reserved = 0;
      var resumed = false;

      if (existing != null) {
        // An explicit retry over an unresolved operation of THIS owner.
        uncertain = true;
        pending = existing;
        if (readout.agreed(owner) == null &&
            !(await _gate.repairPendingEnable(existing)).all) {
          // Exactly one layer holds it: re-persist it in the layer that lost it
          // before anything else; if that cannot be verified, stay denied.
          incomplete('pending_unresolved');
        }
        final recordedBinding = existing.binding;
        if (recordedBinding == null) {
          // Denied stage: native `begin` may or may not have run.
          final inspected = await nativeCall(() =>
              NativeCaptureBridge.getCloudEgressPending(ownerUid: owner));
          if (!current()) throw const StaleAdmissionException();
          // R16: the real native inspection answers `noBarrier` (nothing
          // pending) or `pending` (both layers hold it); `incomplete`
          // (one layer), `conflict`, `uncertain` and anything else is unresolved.
          if (inspected == null ||
              inspected.operation != 'inspect' ||
              (inspected.status != CloudEgressTransitionStatus.noBarrier &&
                  inspected.status != CloudEgressTransitionStatus.pending) ||
              inspected.barrier.length != 2 ||
              (inspected.status == CloudEgressTransitionStatus.noBarrier &&
                  inspected.barrier.any(
                      (l) => l.outcome != CloudEgressLayerOutcome.absent))) {
            incomplete('pending_unresolved');
          }
          final nativeHolds =
              inspected.status == CloudEgressTransitionStatus.pending;
          if (!nativeHolds) {
            if (inspected.egress.any((r) => r.state == 'ON') ||
                (await _gate.store.readOwnerLayers(owner)).records.any((r) =>
                    r.state == EgressState.on &&
                    r.transitionGeneration == existing!.transitionGeneration)) {
              incomplete('pending_unresolved');
            }
            if (!(await _gate.clearPendingEnable(existing)).all) {
              incomplete('pending_unresolved');
            }
            pending = null;
            existing = null;
            uncertain = false;
          } else {
            final nb = inspected.binding;
            if (nb == null ||
                nb.transitionGeneration != existing.transitionGeneration ||
                nb.reservedVersion != existing.reservedVersion ||
                nb.ownerGeneration != lifetime.ownerGeneration ||
                nb.ownerEpoch != lifetime.ownerEpoch ||
                inspected.barrier.length != 2 ||
                !inspected.barrier.every((l) =>
                    l.outcome == CloudEgressLayerOutcome.verified &&
                    l.operationId == nb.operationId)) {
              incomplete('pending_unresolved');
            }
            final adopted = existing.bound(nb);
            if (!(await _gate.bindPendingEnable(from: existing, to: adopted))
                .all) {
              incomplete('pending_unresolved');
            }
            pending = existing = adopted;
          }
        }
        final liveBinding = existing?.binding;
        if (existing != null && liveBinding != null) {
          if (liveBinding.ownerGeneration != lifetime.ownerGeneration ||
              liveBinding.ownerEpoch != lifetime.ownerEpoch) {
            // An operation of a lifecycle that no longer exists: conservative
            // exact restrict/abandon. Only a fully confirmed cleanup lets the
            // retry begin a NEW generation; anything else stays denied.
            binding = liveBinding;
            if (!await compensate()) incomplete('stale_operation');
            binding = null;
            pending = null;
            existing = null;
            uncertain = false;
          } else {
            if (!(await _gate.repairPendingEnable(existing)).all) {
              incomplete('pending_unresolved');
            }
            final r = await nativeCall(() =>
                NativeCaptureBridge.beginCloudEgressEnable(
                    ownerUid: owner,
                    transitionGeneration: existing!.transitionGeneration,
                    reservedVersion: existing.reservedVersion,
                    resume: liveBinding));
            await guard();
            if (r == null ||
                !r.confirmsBarrierEstablished(
                    transitionGeneration: existing.transitionGeneration,
                    reservedVersion: existing.reservedVersion,
                    resumed: liveBinding)) {
              binding = liveBinding;
              await abort('native_resume');
            }
            binding = liveBinding;
            generation = existing.transitionGeneration;
            reserved = existing.reservedVersion;
            resumed = true;
          }
        }
      }

      if (!resumed) {
        if (_cloudOn(settings)) incomplete('already_on');
        // Phase 2 — durable Dart pending denial in BOTH layers, read back.
        final int allocated;
        try {
          allocated = await _gate.allocateEnableGeneration(owner);
        } on EgressWriteFailedException catch (error) {
          if (!current()) throw const StaleAdmissionException();
          incomplete('generation/${error.what}');
        } catch (_) {
          if (!current()) throw const StaleAdmissionException();
          incomplete('generation');
        }
        await guard();
        generation = allocated;
        // The reservation of Phase 0 (strictly above the local history); the
        // plain next local version when none could be made.
        // A resumed-then-cleared operation has no Phase 0 plan: preflight now.
        final newPlan = plan ??
            await _reserveEnableVersion(capability, current, reservationOp);
        await guard();
        if (newPlan == null) incomplete('preflight_unavailable');
        reserved = newPlan.version;
        final record = PendingEnableRecord(
          ownerUid: owner,
          transitionGeneration: generation,
          reservedVersion: reserved,
          localOperationId: reservationOp,
        );
        pending = record;
        pendingShapes.add(record);
        final written = await _gate.beginPendingEnable(record);
        await guard();
        if (!written.all) await abort('pending_not_durable');

        // Phase 3 — native begin (iOS: null/throw/malformed is failure).
        CloudEgressEnableResult? began;
        beginUnknown = true;
        try {
          began = await NativeCaptureBridge.beginCloudEgressEnable(
              ownerUid: owner,
              transitionGeneration: generation,
              reservedVersion: reserved);
        } catch (_) {
          began = null;
        }
        final reply = began;
        if (reply != null &&
            reply.binding != null &&
            reply.binding!.transitionGeneration == generation &&
            reply.binding!.reservedVersion == reserved &&
            reply.status != CloudEgressTransitionStatus.conflict &&
            reply.status != CloudEgressTransitionStatus.ownerMismatch) {
          binding = reply.binding;
        }
        if (reply != null &&
            (binding != null ||
                reply.status == CloudEgressTransitionStatus.conflict ||
                reply.status == CloudEgressTransitionStatus.ownerMismatch)) {
          beginUnknown = false; // the reply names the outcome of this begin
        }
        await guard();
        if (reply == null) {
          uncertain = true;
          incomplete('native_begin');
        }
        if (!reply.confirmsBarrierEstablished(
            transitionGeneration: generation, reservedVersion: reserved)) {
          if (reply.status == CloudEgressTransitionStatus.conflict ||
              reply.status == CloudEgressTransitionStatus.ownerMismatch) {
            // Definite no-op: native wrote nothing for this operation.
            if (!(await _gate.clearPendingEnable(record)).all) uncertain = true;
            incomplete('native_begin_refused');
          }
          if (binding != null) await abort('native_begin');
          uncertain = true;
          incomplete('native_begin');
        }
        final confirmed = reply.binding!;
        // Record the full native binding in BOTH Dart layers.
        final bound = record.bound(confirmed);
        pendingShapes.add(bound);
        final rebound =
            await _gate.bindPendingEnable(from: record, to: bound);
        if (rebound.all) pending = bound;
        await guard();
        if (!rebound.all) await abort('native_bind');
      }

      // Phase 4 — Dart ON (Dart layers only) and native writeOn, both under
      // the durable barriers.
      final activeBinding = binding!;
      final on = CloudEgressRecord(
          state: EgressState.on,
          ownerUid: owner,
          transitionGeneration: generation,
          reservedVersion: reserved);
      dartOn = on;
      final wroteDart = await _gate.writeDartOn(on);
      await guard();
      if (!wroteDart.all) await abort('dart_on');
      final onReply = await nativeCall(() =>
          NativeCaptureBridge.writeCloudEgressEnableOn(
              ownerUid: owner, binding: activeBinding));
      await guard();
      if (onReply == null || !onReply.confirmsOnWritten(activeBinding)) {
        await abort('native_on');
      }

      // Phase 5 — the typed local choice, the ONLY work inside the consent
      // drain. A resumed operation whose choice already committed at exactly the
      // reserved version is not saved again.
      final latest = resumed ? await _settingsRepository.getSettings() : settings;
      await guard();
      final alreadyCommitted = resumed &&
          _cloudOn(latest) &&
          latest.consentVersion == reserved;
      if (!alreadyCommitted) {
        // The reservation must still be above the committed history.
        if (resumed && latest.consentVersion >= reserved) {
          await abort('consent_version');
        }
        UserSettingsEntity saved;
        try {
          // Commits at exactly the reserved version, only as the operation that
          // owns the reservation (or the exact resume of its pending record).
          final resumeProof = resumed
              ? await _gate.provePendingEnableCommit(capability, pending!)
              : null;
          await guard();
          saved = await AppSession.instance.runConsentLocalOperation(
              capability,
              () => _settingsRepository.saveReservedConsentChoice(
                  capability, write.choices,
                  version: reserved,
                  operationId:
                      resumed ? pending!.localOperationId : reservationOp,
                  proof: resumeProof));
        } on StaleAdmissionException {
          await abort('consent_not_saved');
        } catch (_) {
          await abort('consent_not_saved');
        }
        if (!_cloudOn(saved) || saved.consentVersion != reserved) {
          settingsCommitted = true;
          await abort('consent_version');
        }
      }
      settingsCommitted = true;
      await guard();

      // Phase 6 — native completion (never abandoned over an ON), then the Dart
      // denial is cleared only after native confirmed and the proof is current.
      completeDispatched = true;
      final done = await nativeCall(() =>
          NativeCaptureBridge.finishCloudEgressEnable(
              ownerUid: owner, binding: activeBinding, abandon: false));
      if (done == null || !done.confirmsCompleted(activeBinding)) {
        uncertain = true;
        incomplete('native_complete');
      }
      if (!current()) {
        uncertain = true;
        throw const StaleAdmissionException();
      }
      final clearing = pending!;
      final cleared =
          await _gate.clearPendingEnable(clearing, isCurrent: current);
      if (!cleared.all ||
          (await _gate.pendingBlocks(owner: owner)) ||
          !current()) {
        uncertain = true;
        if (!current()) throw const StaleAdmissionException();
        incomplete('pending_not_cleared');
      }
      success = true;
    } finally {
      try {
        if (identical(_enableFreeze, token)) {
          _enableFreeze = null;
          ConsentAuthority.egressFrozen = success
              ? false
              : (uncertain && settingsCommitted && current())
                  ? true
                  : wasFrozen;
          if (ConsentAuthority.egressFrozen && !wasFrozen) {
            ConsentAuthority.egressFreezeTag = 'pending_enable_end';
          }
        }
        await _gate.thawEnable(owner);
        if (success && current()) await _gate.refresh();
      } catch (_) {}
    }
  }

  /// Restricts the native side (no network): backend config cloud=false and a
  /// restrictive mirror for the frozen owner at the reserved version.
  Future<void> _restrictNativeSide(DisableFreeze freeze) async {
    await _restrictNativeSideAcked(freeze);
  }

  /// N-CR-1: the same restriction, but it reports whether BOTH native writes
  /// (backend config cloud=false, restrictive consent mirror) were acknowledged:
  /// the native call ran and returned without error. The native side has no read
  /// API for either, and both are optional defaults writes, so an acknowledgment
  /// is an execution acknowledgment, not crash-durability proof. The config goes
  /// through the acknowledgment-preserving writer: a missing native method is
  /// not an acknowledgment. The verified native egress record is the security
  /// evidence; a swallowed failure is never evidence of restriction.
  Future<bool> _restrictNativeSideAcked(DisableFreeze freeze) async {
    if (!_isIos()) return true;
    var acked = true;
    try {
      await _writeRestrictiveBackendConfig(
        cloudProcessingEnabled: false,
        installId: await _loadInstallId(),
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted: false,
        ownerUid: freeze.owner,
        transitionGeneration: freeze.transitionGeneration,
      );
    } catch (_) {
      acked = false;
    }
    try {
      if (freeze.owner.isNotEmpty) {
        await _writeConsentMirror(
            uid: freeze.owner,
            cloud: false,
            ai: false,
            version: freeze.reservedVersion,
            transitionGeneration: freeze.transitionGeneration);
        _mirrorVersions[freeze.owner] = freeze.reservedVersion;
      }
    } catch (_) {
      acked = false;
    }
    return acked;
  }

  /// The revoke inputs, FROZEN at DISABLING: the frozen owner's JWT (the live
  /// session must be that owner), its uid-bound ack showing Cloud ON, the device
  /// secret and the install id. "Stored secret + was ON" is NEVER enough: with
  /// no JWT or no ack there is nothing to send (NOT_ATTEMPTED).
  Future<_RevokeInputs?> _captureRevokeInputs(
      DisableFreeze freeze, UserSettingsEntity settings) async {
    if (!_revokeAtSwitchOff ||
        !_cloudOn(settings) ||
        !_isBackendConfigured() ||
        freeze.owner.isEmpty ||
        (!_isIos() && !_isAndroid())) {
      return null;
    }
    final session = _readSession();
    if (session == null || session.uid != freeze.owner) return null;
    final ack = await _readAck(freeze.owner);
    final acknowledged =
        ack != null && (_isAndroid() ? ack.cloud || ack.ai : ack.cloud);
    if (!acknowledged &&
        await _storage.read(key: _grantAttemptKey) != freeze.owner) {
      return null;
    }
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return null;
    return _RevokeInputs(await _loadInstallId(), secret, session.jwt);
  }

  /// The single send opportunity. The consumed `revoke_attempt` is durably
  /// written FIRST (no durable record, no send), the ack is cleared, then ONE
  /// request is made with a hard timeout. No retry, no relink, no 401 recovery.
  Future<void> _revokeOnce(DisableFreeze freeze, _RevokeInputs? inputs) async {
    if (inputs == null) {
      await _recordRevocation(freeze, ServerRevocation.notAttempted);
      // Off -> On (never acknowledged by the server) -> Off: the server may
      // still hold the grant an earlier, still-pending revoke was for. That
      // revoke moves to THIS transition's generation (never sent here).
      if (await pendingRevocationGeneration(freeze.owner) != null) {
        await _notePendingRevocation(freeze);
        _scheduleRevokeRetry(_revokeRetryBackoff.first);
      }
      return;
    }
    if (await _attemptRecorded(freeze)) {
      // A consumed attempt for this (owner, generation) already exists: the one
      // send opportunity is gone. Never a second send.
      await _recordRevocation(freeze, ServerRevocation.unconfirmed);
      return;
    }
    final attempt = jsonEncode({
      'owner': freeze.owner,
      'transition_generation': freeze.transitionGeneration,
      'consumed': true,
    });
    // Durable BEFORE the send: a crash, a timeout or no network leaves it for
    // [retryPendingRevocation]; only the server's answer removes it.
    await _notePendingRevocation(freeze);
    if (!await _revokeAttemptSlots.write(attempt)) {
      await _recordRevocation(freeze, ServerRevocation.notAttempted);
      _scheduleRevokeRetry(_revokeRetryBackoff.first);
      return;
    }
    await _clearAck();
    var status = ServerRevocation.unconfirmed;
    try {
      final result = await _gate.runRevoke(freeze, _revokeTimeout, () {
        return _consent.revoke(
          installId: inputs.installId,
          deviceSecret: inputs.secret,
          jwt: inputs.jwt,
          ownerUid: freeze.owner,
          transitionGeneration: freeze.transitionGeneration,
          version: freeze.reservedVersion,
        );
      });
      if (result.ok && (result.applied || result.reason == 'already_revoked')) {
        status = ServerRevocation.confirmed;
      }
    } catch (_) {
      // The one-shot is final; a revoke that did not land stays pending and is
      // retried by [retryPendingRevocation] (bounded backoff, same owner, Cloud
      // still OFF at this generation).
    }
    await _recordRevocation(freeze, status);
    if (status == ServerRevocation.confirmed) {
      await _storage.delete(key: _grantAttemptKey);
      await _forgetPendingRevocation(freeze.owner, freeze.transitionGeneration);
      if (!_disposed) consentServerRevision.value++;
    } else {
      _scheduleRevokeRetry(_revokeRetryBackoff.first);
    }
  }

  // ── Approved 2026-11-12: the retry of a revoke that did not land ──────────

  Future<Map<String, Map<String, int>>> _readPendingRevocations() async {
    final raw = await _pendingRevocationSlots.read();
    if (raw == null || raw.isEmpty) return {};
    final decoded = jsonDecode(raw);
    if (decoded is! Map) throw const FormatException('pending_revocation');
    final out = <String, Map<String, int>>{};
    decoded.forEach((owner, entry) {
      if (owner is! String || entry is! Map) return;
      final g = entry['g'], v = entry['v'], n = entry['n'], at = entry['at'];
      if (g is int && v is int && n is int && at is int) {
        out[owner] = {'g': g, 'v': v, 'n': n, 'at': at};
      }
    });
    return out;
  }

  Future<bool> _writePendingRevocations(Map<String, Map<String, int>> all) =>
      _pendingRevocationSlots.write(jsonEncode(all));

  /// Records (or replaces with) [freeze]'s revoke as pending for its owner. A
  /// newer transition of the same owner replaces an older one.
  Future<void> _notePendingRevocation(DisableFreeze freeze) async {
    try {
      final all = await _readPendingRevocations();
      final held = all[freeze.owner];
      if (held != null && held['g']! > freeze.transitionGeneration) return;
      all[freeze.owner] = {
        'g': freeze.transitionGeneration,
        'v': freeze.reservedVersion,
        'n': 0,
        'at': _now()
            .add(_revokeRetryBackoff.first)
            .millisecondsSinceEpoch,
      };
      await _writePendingRevocations(all);
    } catch (_) {}
  }

  /// Removes [owner]'s pending revoke (at or below [generation] when given).
  Future<void> _forgetPendingRevocation(String owner, [int? generation]) async {
    try {
      final all = await _readPendingRevocations();
      final held = all[owner];
      if (held == null) return;
      if (generation != null && held['g']! > generation) return;
      all.remove(owner);
      await _writePendingRevocations(all);
    } catch (_) {}
  }

  /// Read-only diagnostics: whether [owner] has a revoke the server has not
  /// confirmed yet. Generation only; never a uid, secret or content.
  Future<int?> pendingRevocationGeneration(String owner) async {
    try {
      return (await _readPendingRevocations())[owner]?['g'];
    } catch (_) {
      return null;
    }
  }

  void _scheduleRevokeRetry(Duration delay) {
    if (_disposed) return;
    _revokeRetryTimer?.cancel();
    _revokeRetryTimer = Timer(delay, () {
      _revokeRetryTimer = null;
      unawaited(retryPendingRevocation().catchError((Object _) {}));
    });
  }

  /// Retries the signed-in owner's revoke that did not land, when its backoff
  /// has elapsed. Never for another account (the revoke needs that owner's own
  /// JWT), never once Cloud is ON again or a newer transition exists (then the
  /// pending revoke is superseded and dropped), never while a transition runs.
  /// It only ever sends the revoke; it never changes local consent.
  Future<void> retryPendingRevocation() {
    final running = _revokeRetryInFlight;
    if (running != null) return running;
    final run = _retryPendingRevocation().catchError((Object _) {});
    _revokeRetryInFlight = run;
    return run.whenComplete(() {
      if (identical(_revokeRetryInFlight, run)) _revokeRetryInFlight = null;
    });
  }

  Future<void> _retryPendingRevocation() async {
    if (_disposed || !_revokeAtSwitchOff || !_isBackendConfigured()) return;
    if (!_isIos() && !_isAndroid()) return;
    final Map<String, Map<String, int>> all;
    try {
      all = await _readPendingRevocations();
    } catch (_) {
      return;
    }
    if (all.isEmpty) return;
    final session = _readSession();
    if (session == null) return; // signed out: waits for its own owner
    final owner = session.uid;
    final p = all[owner];
    if (p == null) return; // another account's revoke waits for that account
    final generation = p['g']!, version = p['v']!, attempts = p['n']!;
    final due = DateTime.fromMillisecondsSinceEpoch(p['at']!);
    final now = _now();
    if (now.isBefore(due)) {
      _scheduleRevokeRetry(due.difference(now));
      return;
    }
    if (ConsentAuthority.egressFrozen ||
        _disableInFlight != null ||
        _enableInFlight != null) {
      return; // a transition is running; its own outcome decides
    }
    if (await _readReplicaOwnerUid() != owner) return;
    // A newer grant the SERVER acknowledged supersedes this revoke (the server
    // refuses it from then on: stale_generation). An explicit re-enable the
    // server never heard of does not: the revoke then waits, never sent while
    // Cloud is ON, and a later OFF moves it to that transition.
    final ack = await _readAck(owner);
    if (ack != null && ack.version > version) {
      await _forgetPendingRevocation(owner, generation);
      return;
    }
    final settings = await _settingsRepository.getSettings();
    if (_cloudOn(settings)) return; // explicitly re-enabled: dormant, not sent
    final EgressView view;
    try {
      view = await _gate.view(owner: owner);
    } catch (_) {
      return _backOffRevokeRetry(owner, generation, attempts);
    }
    final rec = view.record;
    if (view.uncertain || rec == null) {
      return _backOffRevokeRetry(owner, generation, attempts);
    }
    if (rec.state != EgressState.off) return; // ON or mid-transition: not sent
    if (rec.transitionGeneration < generation) {
      return _backOffRevokeRetry(owner, generation, attempts);
    }
    var sendGeneration = generation, sendVersion = version;
    if (rec.transitionGeneration > generation) {
      // OFF again after an unacknowledged ON: revoke at the CURRENT transition
      // (the gate admits nothing else) and keep the record in step with it.
      sendGeneration = rec.transitionGeneration;
      sendVersion = rec.reservedVersion;
      await _notePendingRevocation(DisableFreeze(
          owner: owner,
          transitionGeneration: sendGeneration,
          reservedVersion: sendVersion));
    }
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return; // nothing to authenticate
    final installId = await _loadInstallId();
    final freeze = DisableFreeze(
        owner: owner,
        transitionGeneration: sendGeneration,
        reservedVersion: sendVersion);
    try {
      final result = await _gate.runRevokeRetry(owner, sendGeneration,
          _revokeTimeout, () {
        return _consent.revoke(
          installId: installId,
          deviceSecret: secret,
          jwt: session.jwt,
          ownerUid: owner,
          transitionGeneration: sendGeneration,
          version: sendVersion,
        );
      });
      if (result.ok && (result.applied || result.reason == 'already_revoked')) {
        await _recordRevocation(freeze, ServerRevocation.confirmed);
        await _forgetPendingRevocation(owner, sendGeneration);
        if (!_disposed) consentServerRevision.value++;
        return;
      }
      if (result.ok &&
          (result.reason == 'stale_generation' ||
              result.reason == 'owner_mismatch')) {
        // The server holds a newer grant, or this device no longer carries
        // this owner's consent: nothing left for this revoke to narrow.
        await _forgetPendingRevocation(owner, sendGeneration);
        return;
      }
    } on CaptureBackendException catch (e) {
      // 409: the device row is another owner's; 400: can never apply.
      if (e.reason == 'revoke_failed_409' || e.reason == 'revoke_failed_400') {
        await _forgetPendingRevocation(owner, sendGeneration);
        return;
      }
    } catch (_) {}
    return _backOffRevokeRetry(owner, sendGeneration, attempts);
  }

  Future<void> _backOffRevokeRetry(
      String owner, int generation, int attempts) async {
    final step = attempts + 1 < _revokeRetryBackoff.length
        ? attempts + 1
        : _revokeRetryBackoff.length - 1;
    final delay = _revokeRetryBackoff[step];
    try {
      final all = await _readPendingRevocations();
      final held = all[owner];
      if (held == null || held['g'] != generation) return;
      all[owner] = {
        ...held,
        'n': attempts + 1,
        'at': _now().add(delay).millisecondsSinceEpoch,
      };
      await _writePendingRevocations(all);
    } catch (_) {
      return;
    }
    _scheduleRevokeRetry(delay);
  }

  Future<void> _recordRevocation(
      DisableFreeze freeze, ServerRevocation status) async {
    await _serverRevocationSlots.write(jsonEncode({
      'owner': freeze.owner,
      'transition_generation': freeze.transitionGeneration,
      'status': status.name,
    }));
    if (!_disposed) consentServerRevision.value++;
  }

  /// WP-8 diagnostics (read-only): how the last revoke ended. Status and
  /// generation only; never a uid, secret or content. CONFIRMED means the server
  /// answered `{ok, applied}` for that call, nothing more.
  Future<({ServerRevocation status, int generation})?>
      serverRevocation() async {
    try {
      final raw = await _serverRevocationSlots.read();
      if (raw == null) return null;
      final m = jsonDecode(raw);
      if (m is! Map) return null;
      final status = ServerRevocation.values
          .where((v) => v.name == m['status'])
          .firstOrNull;
      final gen = m['transition_generation'];
      if (status == null || gen is! int) return null;
      return (status: status, generation: gen);
    } catch (_) {
      return null;
    }
  }

  /// Startup hook: finishes a Cloud-OFF transition a dead process left behind
  /// and reconciles the durable state with the replica, before any other egress
  /// can start (C.5). No revoke, ever. Uncertain state keeps egress frozen.
  ///
  /// Two separate questions are asked of this attempt. RESOLUTION OWNERSHIP
  /// ([resolution] is still the gate's designated resolver): then it always ends
  /// by resolving the gate, restrictively when it could not finish. MUTATION
  /// AUTHORITY (the strict lifetime/epoch checks): when lost, nothing more is
  /// repaired, aligned or thawed. A superseded attempt does neither: its
  /// successor resolves for itself.
  Future<void> resolvePendingDisable({EgressResolutionToken? resolution}) async {
    // A retired provider instance never claims the resolution on its own.
    if (resolution == null && _disposed) return;
    final token = resolution ?? _gate.beginResolution();
    bool owns() => _gate.ownsResolution(token);
    // Terminal restrictive outcome: retain a freeze already in force (and its
    // tag), otherwise install one. Never a thaw, never a timer.
    void restrict(String tag) {
      if (owns()) ConsentAuthority.freeze(tag, retainTag: true);
    }

    var lifetime = () => false;
    var epoch = _initializationEpoch;
    // Ownership is part of the mutation predicate: a superseded attempt does no
    // internal recovery work either, not only a failed final resolve.
    bool current() => owns() && lifetime() && _gate.epoch == epoch;
    // N-R9 (Q9): a freeze already in force (a prior owner's incomplete
    // withdrawal, an uncertain read) is HELD while the reconciliation reads, so
    // effective admission stays denied until the durable state has been judged.
    // It ends only below, after a reconciliation that did not block; it is never
    // cleared first and never released by a timer.
    final wasFrozen = ConsentAuthority.egressFrozen;
    try {
      lifetime = _captureLifetime(initializing: true);
      if (!current()) {
        restrict('init_stale');
      } else if (_disableInFlight != null || _enableInFlight != null) {
        restrict('init_transition_in_flight');
      } else {
        final outcome = await _reconcile(
            current: current,
            didAdvanceEpoch: () {
              epoch = _gate.epoch;
              _initializationEpoch = epoch;
            });
        if (!current()) {
          restrict('init_lifetime_lost');
        } else if (wasFrozen && outcome != _Gate.blocked && owns()) {
          ConsentAuthority.egressFrozen = false;
        }
      }
    } catch (e) {
      restrict('init_throw:${e.runtimeType}');
    }
    // Astra H2.3: reconciliation (DISABLING crash recovery, the store/native
    // read) has COMPLETED or ended restrictively above, so admission may start
    // judging the durable record. Until this line the process-level latch denied
    // everything, grants too. An uncertain, restrictive or aborted outcome is
    // still denied by the record/freeze itself. A superseded attempt resolves
    // nothing.
    if (!_gate.markResolved(token)) return;
    try {
      await _gate.refresh();
    } catch (_) {
      // Resolved; a failed mirror refresh leaves the mirror closed.
    }
  }

  /// Admission recovery: the same-uid writable scope was re-admitted (explicit
  /// sign-in, re-authentication, a fresh automatic session) while egress is
  /// frozen, so no whole-scope initialization ran for it. Runs the reconciliation
  /// under the admission's own authority and epoch, NOT the construction-time
  /// startup lifetime. It thaws only on a verified non-blocked reconciliation
  /// while its whole predicate still holds; refusal, uncertainty, an exception, a
  /// lost authority or a successor attempt leave the freeze untouched. No sync,
  /// no revoke, no deletion; the startup latch is never its job.
  Future<void> reconcileAfterAdmission({
    required AdmissionAuthority authority,
    required bool Function() isCurrentScope,
  }) async {
    if (!authority.isCurrent ||
        _disposed ||
        !_settingsRepository.isDatabaseOpen ||
        !isCurrentScope() ||
        _readSession()?.uid != authority.uid ||
        !_gate.isResolved ||
        _enableInFlight != null ||
        _disableInFlight != null ||
        !ConsentAuthority.egressFrozen) {
      return;
    }
    var epoch = _gate.epoch; // this attempt's own, never refreshed after an await
    final token = _gate.beginResolution();
    final lifetime = _captureLifetime(admissionAuthority: authority);
    bool current() =>
        _gate.ownsResolution(token) &&
        lifetime() &&
        isCurrentScope() &&
        authority.isCurrent &&
        _gate.epoch == epoch &&
        _enableInFlight == null &&
        _disableInFlight == null;
    try {
      final outcome = await _reconcile(
          current: current,
          expectedOwner: authority.uid,
          didAdvanceEpoch: () => epoch = _gate.epoch);
      if (!current() || outcome == _Gate.blocked) return;
      ConsentAuthority.egressFrozen = false;
      await _gate.refresh();
    } catch (_) {
      // Before the thaw the freeze stays (the next authorized admission may try
      // again); a failed mirror refresh after a verified thaw leaves the mirror
      // closed and admission still judges the durable record.
    }
  }

  /// The persistent gate for this replica's owner. A DISABLING record with no
  /// transition running in this process means the process died mid-transition:
  /// local OFF is retried (never the revoke). Another owner's marker is left
  /// alone: it is neither applied to this owner nor discarded.
  Future<_Gate> _gateState({bool Function()? current}) async {
    current ??= _captureLifetime();
    if (!current()) return _Gate.blocked;
    // An explicit enable writes the ON record and THEN the settings: judging
    // the pair in between would read "ON record, settings OFF" (or, with no
    // record yet, "settings ON") as a divergence and align it back down.
    if (ConsentAuthority.egressFrozen ||
        _disableInFlight != null ||
        _enableInFlight != null) {
      return _Gate.blocked;
    }
    return _reconcile(current: current);
  }

  Future<_Gate> _reconcile({
    bool Function()? current,
    void Function()? didAdvanceEpoch,
    String? expectedOwner,
  }) async {
    current ??= _captureLifetime();
    if (!current()) return _Gate.blocked;
    // ASR §7.5/§11.1: while an ASR transition hold is active the native lane
    // is mid-successor (OFF behind or before its pending barrier); nothing is
    // aligned until the hold ends and `refresh()` judges the settled state.
    if (_gate.holdActive) return _Gate.blocked;
    // B2: an unsettled successor is reconciled only by its ordered
    // reconciliation (§7.5.2), never judged here.
    if (_gate.successorUnsettled) return _Gate.blocked;
    final String owner;
    EgressView view;
    try {
      owner = await _readReplicaOwnerUid() ?? '';
      if (!current()) return _Gate.blocked;
      // Admission recovery acts only on the admitted uid's own replica marker.
      if (expectedOwner != null && owner != expectedOwner) return _Gate.blocked;
      view = await _gate.view(owner: owner);
      if (!current()) return _Gate.blocked;
      // The one repairable native inconsistency: the active owner IS this
      // signed-in uid (the native side verifies uid and hash) and only the
      // generation counter disagrees (Keychain outlives an app deletion, the
      // app-group counter does not). Re-claim the SAME owner with a fresh
      // generation, then judge again: the freeze is still only ever lifted by
      // the normal reconciliation below.
      if (view.uncertain &&
          owner.isNotEmpty &&
          _readSession()?.uid == owner &&
          view.readout.problems.contains('native:owner_generation_mismatch') &&
          await _repairOwnerGeneration(owner)) {
        if (!current()) return _Gate.blocked;
        view = await _gate.view(owner: owner);
        if (!current()) return _Gate.blocked;
      }
    } catch (e) {
      if (!current()) return _Gate.blocked;
      ConsentAuthority.freeze('reconcile_throw:${e.runtimeType}'); // owner/state unknown: fail closed
      return _Gate.blocked;
    }
    if (view.uncertain &&
        view.readout.problems.length == 1 &&
        view.readout.problems.single == 'native:lifetime_fields_unbound' &&
        owner.isNotEmpty &&
        _readSession()?.uid == owner) {
      // The same UID can return under a new native lifetime after sign-out.
      // Only recover to OFF with no active enable barrier. Sign-out keeps the
      // same owner's replica, including its old accepted choice; that choice
      // cannot authorize the new native lifetime. Restrict it before repairing
      // the stores, never transfer the retired lifetime's ON to the new one.
      bool ownsRecovery() => current!() && _readSession()?.uid == owner;
      try {
        if (!await _gate.pendingBlocks(owner: owner) && ownsRecovery()) {
          final inspected =
              await NativeCaptureBridge.getCloudEgressPending(ownerUid: owner);
          if (ownsRecovery() &&
              inspected?.operation == 'inspect' &&
              inspected?.status == CloudEgressTransitionStatus.noBarrier &&
              inspected!.barrier.length == 2 &&
              inspected.barrier.every(
                  (layer) => layer.outcome == CloudEgressLayerOutcome.absent)) {
            final settings = await _settingsRepository.getSettings();
            if (!ownsRecovery()) return _Gate.blocked;
            if (settings.cloudProcessingEnabled || settings.aiConsentGranted) {
              final closed = await _closeNativeForDowngrade(owner, 'new_lifetime',
                  settingsOn: settings.cloudProcessingEnabled);
              if (!ownsRecovery()) return _Gate.blocked;
              if (!closed) {
                ConsentAuthority.freeze('reconcile_new_lifetime:native_unconfirmed');
              }
              final saved = await _settingsRepository.saveSettings(settings.copyWith(
                cloudConsentState: ConsentState.declined,
                aiConsentState: ConsentState.declined,
              ));
              if (!ownsRecovery()) return _Gate.blocked;
              if (settings.cloudProcessingEnabled) {
                await _rememberCloudResume(owner, saved, ownsRecovery,
                    aiWasOn: settings.aiConsentGranted);
              }
            }
            await _repairStaleEgressOff(owner, 0, ownsRecovery);
            if (ownsRecovery()) view = await _gate.view(owner: owner);
          }
        }
      } catch (_) {
        // Incomplete repair stays blocked.
      }
      if (!ownsRecovery()) return _Gate.blocked;
    }
    if (view.uncertain) {
      ConsentAuthority.freeze(
          'reconcile_uncertain:${view.readout.problems.join(',')}');
      // Allowlisted problem tags only (layer names and reasons, never a uid).
      Diag.log('[ConsentDisable]',
          'reconcile_downgrade record=unreadable problems=${view.readout.problems.length}');
      // Unreadable Dart state with a local choice of OFF: the native paths
      // must not stay open on a record nobody can read. Restrictive only; an
      // ON choice is left to the native layers' own (fail-closed) evidence.
      try {
        final settings = await _settingsRepository.getSettings();
        if (current() && !_cloudOn(settings)) {
          await _withdrawNativeFirst(owner, 'reconcile_uncertain');
        }
      } catch (_) {}
      return _Gate.blocked;
    }
    final rec = view.record;
    if (rec != null && rec.state == EgressState.disabling) {
      return await _completePendingDisable(rec, current, didAdvanceEpoch)
          ? _Gate.off
          : _Gate.blocked;
    }
    try {
      // N-E: an unresolved pending enable denies and is NEVER completed, aligned
      // or cleared here. Only an explicit user retry may resume it.
      if (await _gate.pendingBlocks(owner: owner)) {
        return _Gate.blocked;
      }
      if (!current()) return _Gate.blocked;
      final settings = await _settingsRepository.getSettings();
      if (!current()) return _Gate.blocked;
      final on = _cloudOn(settings);
      if (rec == null) {
        // Astra H2.2: an ABSENT record is NOT adopted as ON. Cloud only becomes
        // ON through an explicit enable ([enableCloud]), which writes ON to
        // every store. The effective cloud consent is the persisted consent AND
        // a durable ON record, so an upgraded user whose settings say ON but who
        // has no record sees Cloud as OFF until they re-enable it: the persisted
        // value is aligned DOWN (never up), exactly like the OFF-record case.
        // D-SO1: close native FIRST. Also when the settings already read OFF
        // (once per process): an earlier build aligned them down without
        // telling native, and that state must not keep uploading.
        var closed = true;
        if (on || !_missingRecordNativeClosed) {
          closed = await _closeNativeForDowngrade(owner, 'missing',
              settingsOn: on);
          if (!current()) return _Gate.blocked;
          _missingRecordNativeClosed = closed;
        }
        if (on) {
          final saved = await _settingsRepository.saveSettings(settings.copyWith(
            cloudConsentState: ConsentState.declined,
            aiConsentState:
                _isAndroid() ? ConsentState.declined : settings.aiConsentState,
          ));
          await _rememberCloudResume(owner, saved, current);
        }
        if (!closed && on) {
          // A downgrade whose native close could not be confirmed: keep every
          // Dart egress denied for this process. Captures stay in the queue
          // for local parsing. (Settings already OFF: Dart sends nothing as it
          // is; the repair is retried on the next reconciliation.)
          if (!current()) return _Gate.blocked;
          ConsentAuthority.freeze('reconcile_record_missing:native_unconfirmed');
          return _Gate.blocked;
        }
        return _Gate.off;
      }
      if (rec.state == EgressState.on && !on) {
        // Settings are more restrictive than the record (a disable that never
        // became durable): close the native upload paths first (restrictive,
        // owner-scoped, independent of the alignment below), then align the
        // record to OFF, never the other way.
        await _withdrawNativeFirst(rec.ownerUid, 'reconcile_align_off');
        if (!current()) return _Gate.blocked;
        // N-R9: the alignment allocates above the verified maximum of every
        // layer; if it cannot be established the record may still read ON, so
        // the outcome stays blocked (frozen), never "off".
        final aligned = await _gate.alignOff(rec, isCurrent: current);
        if (!current()) return _Gate.blocked;
        if (aligned == null || !aligned.any) {
          if (!current()) return _Gate.blocked;
          ConsentAuthority.freeze(
              'reconcile_align_off:${CloudEgressStore.lastWriteRefusal}');
          debugPrint('[ConsentDisable] reconcile_align_off '
              'refusal=${CloudEgressStore.lastWriteRefusal}');
          return _Gate.blocked;
        }
        return _Gate.off;
      }
      if (rec.state == EgressState.off && on) {
        // The persistent OFF gate wins over a settings value that widened
        // without an explicit enable. D-SO1: native is closed first.
        final closed =
            await _closeNativeForDowngrade(rec.ownerUid, 'disabled', settingsOn: true);
        if (!current()) return _Gate.blocked;
        if (!closed) {
          ConsentAuthority.freeze('reconcile_record_disabled:native_unconfirmed');
        }
        final saved = await _settingsRepository.saveSettings(settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState:
              _isAndroid() ? ConsentState.declined : settings.aiConsentState,
        ));
        await _rememberCloudResume(owner, saved, current,
            aiWasOn: settings.aiConsentGranted);
        if (!closed) return _Gate.blocked;
      }
    } catch (e) {
      if (!current()) return _Gate.blocked;
      ConsentAuthority.freeze('reconcile_settings_throw:${e.runtimeType}');
      return _Gate.blocked;
    }
    if (!current()) return _Gate.blocked;
    return rec.state == EgressState.off ? _Gate.off : _Gate.open;
  }

  Future<void> _rememberCloudResume(String owner, UserSettingsEntity saved,
      bool Function() current, {bool aiWasOn = false}) async {
    if (!current() || owner.isEmpty || _readSession()?.uid != owner) return;
    try {
      await CloudResumeReminder()
          .rememberPaused(owner, saved, aiWasOn: aiWasOn);
    } catch (_) {
      // Presentation failure must never change or block privacy reconciliation.
    }
  }

  /// Completes a DISABLING record a dead process left behind. This IS a path
  /// that can end the process freeze (N-R9: the code does not claim "no thaw
  /// anywhere"): only after the durable OFF was written by [CloudEgressGate.commitOff]
  /// (a corrupt, unreadable or newer layer refuses it); otherwise it stays frozen.
  Future<bool> _completePendingDisable(CloudEgressRecord rec,
      bool Function() current, void Function()? didAdvanceEpoch) async {
    if (!current()) return false;
    ConsentAuthority.freeze('pending_disable');
    _gate.advanceEpoch(EpochCause.consentWithdrawn);
    didAdvanceEpoch?.call();
    // Restart while a disable is pending: the native paths may never have been
    // restricted (a crash, or a write that failed). Close them before
    // anything else; it is restrictive and owner-scoped.
    await _withdrawNativeFirst(rec.ownerUid, 'pending_disable');
    if (!current()) return false;
    try {
      final settings = await _settingsRepository.getSettings();
      if (!current()) return false;
      if (_cloudOn(settings)) {
        await _settingsRepository.saveSettings(settings.copyWith(
          cloudConsentState: ConsentState.declined,
          aiConsentState:
              _isAndroid() ? ConsentState.declined : settings.aiConsentState,
        ));
      }
      if (!current()) return false;
      await _clearAck();
      if (!current()) return false;
      final freeze = DisableFreeze(
          owner: rec.ownerUid,
          transitionGeneration: rec.transitionGeneration,
          reservedVersion: rec.reservedVersion);
      // Never a revoke here. A consumed attempt without an outcome is UNCONFIRMED.
      if (await serverRevocation() == null ||
          (await serverRevocation())!.generation !=
              freeze.transitionGeneration) {
        if (!current()) return false;
        final attempted = await _attemptRecorded(freeze);
        if (!current()) return false;
        await _recordRevocation(
            freeze,
            attempted
                ? ServerRevocation.unconfirmed
                : ServerRevocation.notAttempted);
      }
      if (!current()) return false;
      if (!await _gate.commitOff(freeze, isCurrent: current) || !current()) {
        return false;
      }
      ConsentAuthority.egressFrozen = false;
      await _gate.refresh();
      return true;
    } catch (_) {
      return false; // not committed: stay frozen, fail closed
    }
  }

  Future<bool> _attemptRecorded(DisableFreeze freeze) async {
    try {
      final raw = await _revokeAttemptSlots.read();
      if (raw == null) return false;
      final m = jsonDecode(raw);
      return m is Map &&
          m['owner'] == freeze.owner &&
          m['transition_generation'] == freeze.transitionGeneration &&
          m['consumed'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Revokes the mutable user/APNs association without deleting the relay
  /// secret needed by the App Intent while the host app is signed out. Sent only
  /// when the uid-bound ack shows a Cloud-ON link (A-12-min R6): an install that
  /// never linked, or whose Cloud is OFF, sends nothing. The ack is cleared
  /// before sending. Always resets the in-process mirror versions (R4), because a
  /// sign-out or Remove data ends this replica's consent history.
  Future<void> unlinkCurrentDevice() async {
    _mirrorVersions.clear();
    if (!_isIos() || !_isBackendConfigured()) return;
    if (await _gateState() != _Gate.open) return;
    final ack = await _readAckAny();
    if (ack == null || !ack.snapshot.cloud) return;
    final secret = await _storage.read(key: _secretKey);
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    await _clearAck();
    try {
      await _backendClient.unlinkDevice(
        installId: installId,
        deviceSecret: secret,
      );
    } on CaptureBackendException catch (error) {
      if (!_isUnauthorized(error)) rethrow;
      final freshSecret = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
      );
      await _backendClient.unlinkDevice(
        installId: installId,
        deviceSecret: freshSecret,
      );
    }
  }

  /// A-12-min R5: whether the legacy device-credential calls (`sync-captures`,
  /// the ACK through it, `process-ios-sms`) may run. On iOS only when the
  /// uid-bound ack is for the CURRENT session user with Cloud ON, so a failed or
  /// missing link never falls through to a projection that may still belong to
  /// someone else. Android has no link and is unchanged.
  Future<bool> isLinkedForCloud() async {
    if (await _gateState() != _Gate.open) return false;
    if (!_isIos()) return true;
    final uid = _readSession()?.uid;
    if (uid == null) return false;
    final ack = await _readAck(uid);
    return ack != null && ack.cloud;
  }

  Future<void> syncApnsToken(ApnsTokenInfo token) {
    final tokenKey = '${token.environment}:${token.token}';
    if (_lastSyncedApnsTokenKey == tokenKey) return Future.value();
    final blockedUntil = _apnsRetryBlockedUntil;
    if (blockedUntil != null && DateTime.now().isBefore(blockedUntil)) {
      return Future.value();
    }
    final pending = _apnsSyncInFlight;
    if (pending != null) {
      return pending.then((_) => syncApnsToken(token));
    }
    final run = _syncApnsTokenOnce(token, tokenKey);
    _apnsSyncInFlight = run;
    return run.whenComplete(() {
      if (identical(_apnsSyncInFlight, run)) _apnsSyncInFlight = null;
    });
  }

  Future<void> _syncApnsTokenOnce(
    ApnsTokenInfo token,
    String tokenKey,
  ) async {
    if (!_isIos() || !_isBackendConfigured()) return;
    if (await _gateState() != _Gate.open) return;
    final tx = await _beginTx();
    if (!await _holds(tx)) return;
    final settings = await _settingsRepository.getSettings();
    if (!await _holds(tx)) return;
    if (!settings.cloudProcessingEnabled) return;
    final secret = await _storage.read(key: _secretKey);
    if (!await _holds(tx)) return;
    if (secret == null || secret.isEmpty) return;
    final installId = await _loadInstallId();
    if (!await _holds(tx)) return;
    try {
      await _backendClient.registerPushToken(
        installId: installId,
        deviceSecret: secret,
        apnsToken: token.token,
        apnsEnvironment: token.environment,
      );
    } on CaptureBackendException catch (error) {
      if (_isRateLimited(error)) {
        _apnsRetryBlockedUntil = DateTime.now().add(const Duration(hours: 1));
        rethrow;
      }
      if (!_isUnauthorized(error)) rethrow;
      final freshSecret = await _recoverRejectedSecret(
        rejectedSecret: secret,
        installId: installId,
        current: tx.current,
      );
      if (!await _holds(tx)) return;
      await _backendClient.registerPushToken(
        installId: installId,
        deviceSecret: freshSecret,
        apnsToken: token.token,
        apnsEnvironment: token.environment,
      );
    }
    // P4: a registration that completed after an account switch / transition is
    // not recorded as synced for the new state.
    if (!await _holds(tx)) return;
    _lastSyncedApnsTokenKey = tokenKey;
    _apnsRetryBlockedUntil = null;
  }

  bool _isUnauthorized(CaptureBackendException error) =>
      error.reason.endsWith('_401');

  bool _isRateLimited(CaptureBackendException error) =>
      error.reason.endsWith('_429');

  /// Reissues a stale relay credential exactly once across concurrent APNs,
  /// link and startup callbacks. If another callback already replaced the
  /// rejected secret, reuse that replacement instead of rotating again.
  Future<String> _recoverRejectedSecret({
    required String rejectedSecret,
    required String installId,
    bool Function()? current,
  }) async {
    final live = current ?? _captureLifetime();
    if (!live()) throw const StaleAdmissionException();
    // Cloud OFF = zero egress (R6): a 401 never re-registers the device while
    // the user's Cloud consent is OFF (e.g. switched off mid-flight).
    if (await _gateState(current: live) != _Gate.open || !live()) {
      throw const CaptureBackendException('recovery_skipped_cloud_off');
    }
    final recoverySettings = await _settingsRepository.getSettings();
    if (!live()) throw const StaleAdmissionException();
    if (!recoverySettings.cloudProcessingEnabled) {
      throw const CaptureBackendException('recovery_skipped_cloud_off');
    }
    if (!live()) throw const StaleAdmissionException();
    final stored = await _storage.read(key: _secretKey);
    if (!live()) throw const StaleAdmissionException();
    if (stored != null && stored.isNotEmpty && stored != rejectedSecret) {
      return stored;
    }
    final inFlight = _credentialRecovery;
    if (inFlight != null) return inFlight;

    final recovery = () async {
      final tx = await _beginTx();
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      final fresh = await _backendClient.registerDevice(installId: installId);
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      await _storage.write(key: _secretKey, value: fresh);
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      // A new credential is a new server row: nothing was acknowledged for it.
      await _clearAck();
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      // P4: no widening native config after an account switch / transition.
      if (!await _holds(tx)) return fresh;
      final settings = await _settingsRepository.getSettings();
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      final generation = await _clientGeneration(tx.owner ?? '');
      if (!live() || !await _holds(tx)) {
        throw const StaleAdmissionException();
      }
      await _writeNativeBackendConfig(
        cloudProcessingEnabled:
            settings.cloudProcessingEnabled && _isBackendConfigured(),
        installId: installId,
        deviceSecret: fresh,
        backendUrl: SupabaseConfig.url,
        anonKey: SupabaseConfig.anonKey,
        aiConsentGranted:
            settings.cloudProcessingEnabled && settings.aiConsentGranted,
        ownerUid: tx.owner ?? '',
        transitionGeneration: generation,
      );
      return fresh;
    }();
    _credentialRecovery = recovery;
    try {
      return await recovery;
    } finally {
      if (identical(_credentialRecovery, recovery)) {
        _credentialRecovery = null;
      }
    }
  }
}

/// N2: the LOCAL restrictive owner publication of a committed admission. It is
/// an extension so the many `implements` doubles of the service keep compiling;
/// it adds no state.
///
/// Cloud OFF by construction: native publishes the owner with cloud and AI off,
/// so there is no registerDevice, link, consent push, APNs registration or any
/// other backend call. It is separate from `linkToCurrentUser`, which widens a
/// mirror only after a server link.
extension RestrictiveOwnerPublication on CaptureDeviceRegistrationService {
  /// The strictly verified native receipt, or null when nothing was published or
  /// the reply does not confirm the captured uid, epoch and version. Every step
  /// before the native call rechecks the forwarded committed authority, the exact
  /// session, replica and gate epoch; a stale service publishes nothing. The
  /// reply is deliberately NOT rechecked against the lifetime: a loss during the
  /// publication must still hand the caller the exact lifetime it has to fence.
  Future<RestrictiveCaptureOwnerReceipt?> publishRestrictiveOwner({
    required AdmissionAuthority admissionAuthority,
  }) async {
    final result = await publishRestrictiveOwnerDetailed(
        admissionAuthority: admissionAuthority);
    return result is RestrictiveCaptureOwnerReceipt ? result : null;
  }

  /// [publishRestrictiveOwner], but a missing receipt is a
  /// [RestrictiveOwnerRefusal] naming the allowlisted reason (diagnostics only).
  Future<Object> publishRestrictiveOwnerDetailed({
    required AdmissionAuthority admissionAuthority,
    RestrictivePublishPlan? plan,
    ({String evidenceId, int expectedCounter})? successorOf,
    Object? successorCauseAuthority,
  }) async {
    final current = _captureLifetime(
        requireAdmission: true, admissionAuthority: admissionAuthority);
    if (!current() || !_isIos()) {
      return RestrictiveOwnerRefusal(
          admissionAuthority.isCurrent ? 'scope' : 'authority');
    }
    final session = _readSession();
    if (session == null) return const RestrictiveOwnerRefusal('scope');
    if (await _readReplicaOwnerUid() != session.uid) {
      return const RestrictiveOwnerRefusal('marker');
    }
    if (!current()) return const RestrictiveOwnerRefusal('hook_stale');
    final _Tx tx;
    try {
      tx = await _beginTx(lifetime: current);
    } on StaleAdmissionException {
      return const RestrictiveOwnerRefusal('hook_stale');
    }
    // Read BEFORE the publication: a clear since then makes native refuse it.
    final epoch = await _readOwnerEpoch();
    if (!current()) return const RestrictiveOwnerRefusal('hook_stale');
    // Only the explicit Cloud enable carries a plan (its reserved version and the
    // inspected OFF record); every ordinary admission publishes the local version.
    final version = plan?.version ??
        (await _settingsRepository.getSettings()).consentVersion;
    if (!await _holds(tx)) {
      return RestrictiveOwnerRefusal(
          ConsentAuthority.egressFrozen ? 'hook_frozen' : 'hook_stale');
    }
    final receipt = await NativeCaptureBridge.publishRestrictiveCaptureOwner(
      uid: session.uid,
      version: version,
      expectedEpoch: epoch,
      expectedTransitionGeneration: plan?.expectedTransitionGeneration,
      expectedReservedVersion: plan?.expectedReservedVersion,
      expectedLifetimeOwnerGeneration: plan?.expectedLifetimeOwnerGeneration,
      expectedLifetimeOwnerEpoch: plan?.expectedLifetimeOwnerEpoch,
      expectedOffCopies: plan?.expectedOffCopies,
      expectedRetiredCopies: plan?.expectedRetiredCopies,
      // ASR §7.5 SE1 (never together with an explicit plan).
      successorOf: plan == null ? successorOf : null,
      causeAuthority: plan == null ? successorCauseAuthority : null,
    );
    if (receipt == null) return const RestrictiveOwnerRefusal('receipt_null');
    if (!receipt.confirms(
        uid: session.uid, expectedEpoch: epoch, version: version)) {
      return RestrictiveOwnerRefusal(switch (receipt.phase.status) {
        CloudEgressTransitionStatus.stale => 'native_stale',
        CloudEgressTransitionStatus.conflict ||
        CloudEgressTransitionStatus.pending =>
          'native_pending',
        CloudEgressTransitionStatus.uncertain => 'native_uncertain',
        CloudEgressTransitionStatus.incomplete => 'native_incomplete',
        CloudEgressTransitionStatus.noBarrier => 'native_barrier',
        CloudEgressTransitionStatus.ownerMismatch => 'native_owner',
        CloudEgressTransitionStatus.done => 'receipt_unconfirmed',
      });
    }
    return receipt;
  }
}

/// ASR §7.5 SE2–SE5: one expiry-successor enable in flight. Holds the Dart
/// pending record, the native binding and the counter its own receipts
/// advanced native to.
/// The in-process freeze an expiry successor took: its enable token, the
/// state before it, and the [ConsentAuthority.freezeGeneration] of its freeze.
typedef SuccessorFreeze = ({Object token, bool wasFrozen, int generation});

class ExpirySuccessor {
  ExpirySuccessor._(this.owner, this.successorGeneration, this.ownerEpoch,
      this.pending, this.binding, this.counter, this._freeze,
      [this.causeAuthority]);
  final String owner;
  final int successorGeneration;
  final int ownerEpoch;
  final PendingEnableRecord pending;
  final CloudEgressEnableBinding binding;
  int counter;
  final SuccessorFreeze _freeze;

  /// §11.2: the ASR op whose own native writes these are (null after a
  /// restart: no op owns them, so they are foreign to every op).
  final Object? causeAuthority;
}

/// ASR §7.5: the narrow successor of an expiry-retired lifetime. Unlike the
/// explicit enable it reserves no new consent version and writes no Dart ON:
/// it re-establishes, behind the ordinary pending barrier, the native ON that
/// the expiry revoke retired for an owner whose Dart layers and saved consent
/// stayed ON. Every step is bound to the previous step's native counter.
extension ExpirySuccessorEnable on CaptureDeviceRegistrationService {
  /// B2: how long one successor-chain native call is awaited. An unanswered
  /// call is a lost reply: the step reports it unsettled and the durable
  /// `finalizing` record hands it to the ordered reconciliation (§7.5.2); the
  /// native queue keeps the late call ordered before that reconciliation's.
  static const Duration nativeReplyTimeout = Duration(seconds: 8);

  static Future<CloudEgressEnableResult?> _native(
      Future<CloudEgressEnableResult?> Function() call) async {
    try {
      return await call().timeout(nativeReplyTimeout);
    } catch (_) {
      return null;
    }
  }

  /// B2: the in-process freeze of a successor whose settlement is still
  /// outstanding, by its native operation id. An in-process reconciliation
  /// ([recoverExpirySuccessor]) releases exactly that freeze once settled.
  static final Map<String, SuccessorFreeze> _openFreezes = {};

  /// Phase 4c: releases only this successor's contribution — the enable token
  /// must still be its own, and a freeze taken since (e.g. Cloud disable) is
  /// kept ([ConsentAuthority.releaseFreeze]).
  static void _releaseFreeze(SuccessorFreeze f) {
    if (!identical(CaptureDeviceRegistrationService._enableFreeze, f.token)) {
      return;
    }
    CaptureDeviceRegistrationService._enableFreeze = null;
    ConsentAuthority.releaseFreeze(f.generation, wasFrozen: f.wasFrozen);
  }

  void _releaseSuccessorFreeze(ExpirySuccessor s) {
    _openFreezes.remove(s.binding.operationId);
    _releaseFreeze(s._freeze);
  }

  /// SE2 (native + Dart pending barrier) and SE3 (native ON behind it) after
  /// SE1 published lifetime [successorGeneration]/[ownerEpoch] at counter
  /// [counter]. Null when refused; whatever was written is compensated first.
  Future<ExpirySuccessor?> prepareExpirySuccessor({
    required String owner,
    required String evidenceId,
    required int successorGeneration,
    required int ownerEpoch,
    required int counter,
    required bool Function() mayProceed,
    Object? causeAuthority,
  }) async {
    if (!_usesNativeBarrier || !mayProceed()) return null;
    final settings = await _settingsRepository.getSettings();
    final layers = await _gate.store.readDartOwnerLayers(owner);
    final readout = await _gate.readPending();
    if (!mayProceed() ||
        !_cloudOn(settings) ||
        layers.uncertain ||
        layers.records.length != 2 ||
        layers.records.any((r) =>
            r.state != EgressState.on ||
            r.ownerUid != owner ||
            r.transitionGeneration != layers.records.first.transitionGeneration) ||
        readout.unreadable ||
        readout.blocks(owner)) {
      return null;
    }
    final consentVersion = settings.consentVersion;
    final dartOnGeneration = layers.records.first.transitionGeneration;
    final int generation;
    try {
      generation = await _gate.allocateEnableGeneration(owner);
    } catch (_) {
      return null;
    }
    if (!mayProceed()) return null;

    final wasFrozen = ConsentAuthority.egressFrozen;
    final token = Object();
    CaptureDeviceRegistrationService._enableFreeze = token;
    ConsentAuthority.freeze('pending_enable');
    final freeze = (
      token: token,
      wasFrozen: wasFrozen,
      generation: ConsentAuthority.freezeGeneration,
    );
    _gate.freezeEnable(owner, authority: causeAuthority);
    final record = PendingEnableRecord(
      ownerUid: owner,
      transitionGeneration: generation,
      reservedVersion: consentVersion,
      localOperationId: CaptureDeviceRegistrationService._randomOperationId(),
    );

    Future<ExpirySuccessor?> undo({CloudEgressEnableBinding? bound}) async {
      if (bound != null) {
        final r = await _native(() => NativeCaptureBridge.retireSuccessor(
            ownerUid: owner,
            successorGeneration: successorGeneration,
            ownerEpoch: ownerEpoch,
            operationId: bound.operationId,
            causeAuthority: causeAuthority));
        if (r == null ||
            (r.status != CloudEgressTransitionStatus.done &&
                r.status != CloudEgressTransitionStatus.stale)) {
          return null; // the barrier keeps native denied; freeze stays
        }
      }
      for (final p in {record, if (bound != null) record.bound(bound)}) {
        if (!(await _gate.clearPendingEnable(p)).all) return null;
      }
      if (bound != null) _openFreezes.remove(bound.operationId);
      _releaseFreeze(freeze);
      await _gate.thawEnable(owner);
      return null;
    }

    if (!(await _gate.beginPendingEnable(record)).all || !mayProceed()) {
      return undo();
    }
    final began = await _native(() => NativeCaptureBridge.beginCloudEgressEnable(
        ownerUid: owner,
        transitionGeneration: generation,
        reservedVersion: consentVersion,
        successor: (evidenceId: evidenceId, expectedCounter: counter),
        causeAuthority: causeAuthority));
    final binding = began?.binding;
    final c2 = began?.mutationCounter;
    if (began == null ||
        binding == null ||
        c2 == null ||
        !began.confirmsBarrierEstablished(
            transitionGeneration: generation,
            reservedVersion: consentVersion) ||
        binding.ownerGeneration != successorGeneration ||
        binding.ownerEpoch != ownerEpoch) {
      // A refused begin wrote nothing; an unknown one may hold the barrier,
      // which keeps native denied (and the pending keeps Dart frozen).
      return began != null &&
              (began.status == CloudEgressTransitionStatus.conflict ||
                  began.status == CloudEgressTransitionStatus.ownerMismatch)
          ? undo()
          : null;
    }
    final bound = record.bound(binding);
    _openFreezes[binding.operationId] = freeze;
    if (!(await _gate.bindPendingEnable(from: record, to: bound)).all ||
        !mayProceed()) {
      return undo(bound: binding);
    }

    // SE3: saved consent still accepted at exactly that version, Dart still ON
    // at the inspected generation.
    final latest = await _settingsRepository.getSettings();
    final again = await _gate.store.readDartOwnerLayers(owner);
    if (!mayProceed() ||
        !_cloudOn(latest) ||
        latest.consentVersion != consentVersion ||
        again.uncertain ||
        again.records.length != 2 ||
        again.records.any((r) =>
            r.state != EgressState.on ||
            r.transitionGeneration != dartOnGeneration)) {
      return undo(bound: binding);
    }
    final on = await _native(() => NativeCaptureBridge.writeCloudEgressEnableOn(
        ownerUid: owner,
        binding: binding,
        expectedCounter: c2,
        causeAuthority: causeAuthority));
    final c3 = on?.mutationCounter;
    if (on == null || c3 == null || !on.confirmsOnWritten(binding)) {
      return undo(bound: binding);
    }
    return ExpirySuccessor._(owner, successorGeneration, ownerEpoch, bound,
        binding, c3, freeze, causeAuthority);
  }

  /// SE4. `confirmed`, `notExecuted` (a definite refusal), or `unknown` (lost
  /// reply: resolved by [inspectExpirySuccessor]). The caller made the
  /// synchronous `mayContinue` check immediately before this call.
  Future<String> finishExpirySuccessor(ExpirySuccessor s) async {
    final r = await _native(() => NativeCaptureBridge.finishCloudEgressEnable(
        ownerUid: s.owner,
        binding: s.binding,
        abandon: false,
        expectedCounter: s.counter,
        causeAuthority: s.causeAuthority));
    if (r == null) return inspectExpirySuccessor(s);
    if (r.confirmsCompleted(s.binding)) return 'confirmed';
    return r.status == CloudEgressTransitionStatus.conflict ||
            r.status == CloudEgressTransitionStatus.stale ||
            r.status == CloudEgressTransitionStatus.ownerMismatch
        ? 'notExecuted'
        : inspectExpirySuccessor(s);
  }

  /// §7.5.1 lost-reply rule: G' ON with no pending → `confirmed`; this op's
  /// pending present with G' ON behind it → `notExecuted`; else `unknown`.
  Future<String> inspectExpirySuccessor(ExpirySuccessor s) async {
    final String seen;
    try {
      seen = await NativeCaptureBridge.inspectSuccessor(
              ownerUid: s.owner,
              successorGeneration: s.successorGeneration,
              ownerEpoch: s.ownerEpoch,
              operationId: s.binding.operationId)
          .timeout(nativeReplyTimeout);
    } catch (_) {
      return 'unknown';
    }
    return switch (seen) {
      'finished' => 'confirmed',
      'behindBarrier' => 'notExecuted',
      _ => 'unknown',
    };
  }

  /// SE5: the exact Dart pending clearance (read back in both layers), then
  /// the freeze release.
  Future<bool> clearExpirySuccessor(ExpirySuccessor s) async {
    if (!(await _gate.clearPendingEnable(s.pending)).all ||
        await _gate.pendingBlocks(owner: s.owner)) {
      return false;
    }
    _releaseSuccessorFreeze(s);
    await _gate.thawEnable(s.owner);
    return true;
  }

  /// §7.5.2 restart: the successor whose Dart pending record (both layers,
  /// agreeing) names [pendingOpId] for lifetime [successorGeneration]. Null
  /// when no pending of the owner is left; throws when it cannot be read.
  Future<ExpirySuccessor?> recoverExpirySuccessor({
    required String owner,
    required int successorGeneration,
    required String pendingOpId,
  }) async {
    final readout = await _gate.readPending();
    if (readout.unreadable) throw StateError('pending_unreadable');
    final pending = readout.agreed(owner);
    if (pending == null) {
      if (readout.blocks(owner)) throw StateError('pending_partial');
      return null;
    }
    final b = pending.binding;
    if (b == null ||
        b.operationId != pendingOpId ||
        b.ownerGeneration != successorGeneration) {
      throw StateError('pending_foreign');
    }
    // In process, the freeze this op's prepare set is still the one to lift;
    // after a restart there is none (a fresh token never matches).
    final open = _openFreezes[b.operationId];
    return ExpirySuccessor._(owner, successorGeneration, b.ownerEpoch, pending,
        b, -1, open ?? (token: Object(), wasFrozen: true, generation: -1));
  }

  /// §7.5.2 restart with no pending left: exact retirement of G' (a no-op
  /// when a later transition superseded it). True when settled.
  Future<bool> retireOrphanSuccessor({
    required String owner,
    required int successorGeneration,
    required String pendingOpId,
  }) async {
    final RecoveryEvidenceSnapshot? snap;
    try {
      snap = await NativeCaptureBridge.inspectRecoveryEvidence(ownerUid: owner)
          .timeout(nativeReplyTimeout);
    } catch (_) {
      return false;
    }
    final epoch = snap?.ownerEpoch;
    if (epoch == null) return false;
    final r = await _native(() => NativeCaptureBridge.retireSuccessor(
        ownerUid: owner,
        successorGeneration: successorGeneration,
        ownerEpoch: epoch,
        operationId: pendingOpId));
    return r != null &&
        (r.status == CloudEgressTransitionStatus.done ||
            r.status == CloudEgressTransitionStatus.stale);
  }

  /// Compensation. Before SE4 ([finished] false): exact restrict + abandon of
  /// this op, or `retireSuccessor` when that cannot be confirmed. After SE4 (or
  /// unknown): `retireSuccessor` of exactly G'. The Dart pending is then
  /// cleared exactly; a clearance that cannot be confirmed keeps the freeze
  /// (the existing pending-enable reconciliation owns it). True only when
  /// settled: native restricted+abandoned or retired (or superseded), AND the
  /// Dart pending cleared and read back (B2). Never throws.
  Future<bool> compensateExpirySuccessor(ExpirySuccessor s,
      {required bool finished}) async {
    try {
      var retire = finished;
      if (!finished) {
        final restricted = await _native(() =>
            NativeCaptureBridge.restrictCloudEgressEnable(
                ownerUid: s.owner,
                binding: s.binding,
                causeAuthority: s.causeAuthority));
        final abandoned = restricted != null &&
                restricted.confirmsRestricted(s.binding)
            ? await _native(() => NativeCaptureBridge.finishCloudEgressEnable(
                ownerUid: s.owner,
                binding: s.binding,
                abandon: true,
                causeAuthority: s.causeAuthority))
            : null;
        retire = abandoned == null || !abandoned.confirmsAbandoned(s.binding);
      }
      if (retire) {
        final r = await _native(() => NativeCaptureBridge.retireSuccessor(
            ownerUid: s.owner,
            successorGeneration: s.successorGeneration,
            ownerEpoch: s.ownerEpoch,
            operationId: s.binding.operationId,
            causeAuthority: s.causeAuthority));
        if (r == null ||
            (r.status != CloudEgressTransitionStatus.done &&
                r.status != CloudEgressTransitionStatus.stale)) {
          return false;
        }
      }
      return await clearExpirySuccessor(s);
    } catch (_) {
      return false;
    }
  }
}
