/// A-6 — the explicit server capability probe.
///
/// The server advertises app-visible capabilities through the read-only RPC
/// `qirsh_server_capabilities()` (authenticated, returns jsonb). Before the
/// deferred migration 0102 is deployed the RPC does not exist, which is itself
/// the answer: the capability is UNSUPPORTED. Authority is positive-proof only:
/// a capability is [ServerCapabilityState.verified] only when the RPC returned
/// its key as `true`, or a send of that shape was accepted ([noteVerified]).
library;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/sync/sync_health.dart';

enum ServerCapabilityState {
  /// Probe not possible / failed transiently (network, auth, server error,
  /// consent off). NOT proof of anything; rows stay held.
  unknown,
  verified,

  /// RPC missing, or the key is absent/false.
  unsupported,
}

/// RPC key for awaiting-FX (amount 0 + foreign amount/currency) transactions.
const String kCapAwaitingFxTransactions = 'awaiting_fx_transactions';

/// RPC key for the v2 capture contract (CAP-5): JWT `sync-captures`, leased
/// states. False in production until its gate passes.
const String kCapCaptureContractV2 = 'capture_contract_v2';

/// RPC key for the WP-4 sequence pull (manifest §8). It is the kill switch:
/// withdrawing it sends clients back to the legacy timestamp pull.
const String kCapSyncSeq = 'sync_seq';

/// RPC key for WP-5 revision CAS / insert-if-absent. Kill switch like [kCapSyncSeq].
const String kCapRevisionCas = 'revision_cas';

/// RPC key for WP-7 rebootstrap on an epoch change (manifest §8). False in
/// production until G5; false keeps today's typed `epochMismatch` stop.
const String kCapReplicaEpoch = 'replica_epoch';

/// 20261116180000: the server holds `user_merchant_rules`. A kill switch like
/// [kCapSyncSeq]; false/absent keeps the user's learned rules device-local.
const String kCapMerchantRulesSync = 'merchant_rules_sync';

class ServerCapabilitiesService {
  ServerCapabilitiesService({
    required Future<String?> Function() getAuthUserId,
    required SupabaseClient Function() getClient,
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    String Function()? getServerUrl,
    DateTime Function()? clock,
    this.unknownRetryAfter = const Duration(minutes: 2),
  })  : _getAuthUserId = getAuthUserId,
        _getClient = getClient,
        _mayEgress = mayEgress ?? _deny,
        _health = health,
        _getServerUrl = getServerUrl ?? (() => SupabaseConfig.url),
        _clock = clock ?? DateTime.now;

  static Future<bool> _deny() async => false;

  final Future<String?> Function() _getAuthUserId;
  final SupabaseClient Function() _getClient;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final String Function() _getServerUrl;
  final DateTime Function() _clock;

  /// Minimum gap between probes while the answer is still [unknown], so an
  /// offline device does not probe on every push cycle.
  final Duration unknownRetryAfter;

  // Per-session cache keyed by server URL + uid (never persisted).
  final Map<String, ServerCapabilityState> _awaitingFx = {};
  final Map<String, DateTime> _unknownAt = {};
  final Map<String, DateTime> _probedAt = {};

  final List<void Function(String uid, ServerCapabilityState)> _listeners = [];

  // WP-4: unlike awaiting-FX a `verified` sync_seq must NOT stick for the whole
  // session (it is a kill switch), so every answer expires after [syncSeqTtl].
  final Map<String, ServerCapabilityState> _syncSeq = {};
  final Map<String, DateTime> _syncSeqAt = {};
  static const Duration syncSeqTtl = Duration(minutes: 15);
  final Map<String, ServerCapabilityState> _replicaEpoch = {};
  final Map<String, DateTime> _replicaEpochAt = {};
  final Map<String, ServerCapabilityState> _revisionCas = {};
  final Map<String, DateTime> _revisionCasAt = {};
  final Map<String, ServerCapabilityState> _merchantRules = {};
  final Map<String, DateTime> _merchantRulesAt = {};

  String _key(String uid) => '${_getServerUrl()}|$uid';

  /// Cached state with no network.
  ServerCapabilityState cachedAwaitingFx(String uid) =>
      _awaitingFx[_key(uid)] ?? ServerCapabilityState.unknown;

  /// Called whenever the cached state for a user changes.
  void addListener(void Function(String uid, ServerCapabilityState) l) =>
      _listeners.add(l);

  /// Resolves the awaiting-FX capability for [uid]: cached verified/unsupported
  /// answers are returned as-is (one probe per session); an unknown answer is
  /// re-probed at most every [unknownRetryAfter] unless [force]. Consent-gated:
  /// with financialSync off nothing is sent and the result is unknown.
  Future<ServerCapabilityState> awaitingFxTransactions({
    String? uid,
    bool force = false,
  }) async {
    final user = uid ?? await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final cached = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    if (!force && cached != ServerCapabilityState.unknown) return cached;
    final last = _unknownAt[key];
    if (!force &&
        last != null &&
        _clock().difference(last) < unknownRetryAfter) {
      return cached;
    }

    if (!await _mayEgress()) {
      _health?.recordConsentBlocked(SyncDomain.ledger);
      return ServerCapabilityState.unknown;
    }

    _probedAt[key] = _clock();
    ServerCapabilityState result;
    try {
      final raw = await _getClient().rpc('qirsh_server_capabilities');
      result = raw is Map && raw[kCapAwaitingFxTransactions] == true
          ? ServerCapabilityState.verified
          : ServerCapabilityState.unsupported;
    } catch (e) {
      if (_isRpcMissing(e)) {
        result = ServerCapabilityState.unsupported;
      } else {
        result = ServerCapabilityState.unknown;
        _health?.noteFailure(SyncDomain.ledger, e);
      }
    }
    _set(user, result);
    return result;
  }

  /// WP-4: whether the server advertises `sync_seq` for [uid]. Positive proof
  /// only: [ServerCapabilityState.unsupported] means the RPC is missing or the
  /// key is absent/false (-> legacy timestamp pull); auth/network/server errors
  /// are [ServerCapabilityState.unknown] (never treated as "absent"). Consent
  /// gated by the caller (the ledger pull checks egress first).
  Future<ServerCapabilityState> syncSeq({String? uid}) =>
      _killSwitch(kCapSyncSeq, _syncSeq, _syncSeqAt, uid);

  /// WP-7: whether the server advertises `replica_epoch` (kill switch, same
  /// rules as [syncSeq]).
  Future<ServerCapabilityState> replicaEpoch({String? uid}) =>
      _killSwitch(kCapReplicaEpoch, _replicaEpoch, _replicaEpochAt, uid);

  /// WP-5: whether the server advertises `revision_cas` (same rules as
  /// [syncSeq]; withdrawing it returns the client to the legacy guarded push).
  Future<ServerCapabilityState> revisionCas({String? uid}) =>
      _killSwitch(kCapRevisionCas, _revisionCas, _revisionCasAt, uid);

  /// Whether the server advertises `merchant_rules_sync` (same rules as
  /// [syncSeq]). Until verified, learned rules are neither pushed nor pulled.
  Future<ServerCapabilityState> merchantRulesSync({String? uid}) =>
      _killSwitch(kCapMerchantRulesSync, _merchantRules, _merchantRulesAt, uid);

  /// WP-8 (diagnostics): the last cached answer for a kill-switch capability
  /// with no network and no TTL check; [ServerCapabilityState.unknown] when
  /// nothing was probed. [capKey] is one of [kCapSyncSeq], [kCapReplicaEpoch],
  /// [kCapRevisionCas], [kCapCaptureContractV2].
  ServerCapabilityState cachedCapability(String capKey, String uid) {
    final cache = switch (capKey) {
      kCapSyncSeq => _syncSeq,
      kCapReplicaEpoch => _replicaEpoch,
      kCapRevisionCas => _revisionCas,
      kCapCaptureContractV2 => _captureV2,
      kCapMerchantRulesSync => _merchantRules,
      _ => null,
    };
    return cache?[_key(uid)] ?? ServerCapabilityState.unknown;
  }

  Future<ServerCapabilityState> _killSwitch(
    String capKey,
    Map<String, ServerCapabilityState> cache,
    Map<String, DateTime> stamps,
    String? uid,
  ) async {
    final user = uid ?? await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final at = stamps[key];
    final cached = cache[key];
    if (cached != null &&
        cached != ServerCapabilityState.unknown &&
        at != null &&
        _clock().difference(at) < syncSeqTtl) {
      return cached;
    }
    if (!await _mayEgress()) return ServerCapabilityState.unknown;
    ServerCapabilityState result;
    try {
      final raw = await _getClient().rpc('qirsh_server_capabilities');
      result = raw is Map && raw[capKey] == true
          ? ServerCapabilityState.verified
          : ServerCapabilityState.unsupported;
    } catch (e) {
      if (_isRpcMissing(e)) {
        result = ServerCapabilityState.unsupported;
      } else {
        result = ServerCapabilityState.unknown;
        _health?.noteFailure(SyncDomain.ledger, e);
      }
    }
    cache[key] = result;
    stamps[key] = _clock();
    return result;
  }

  final Map<String, ServerCapabilityState> _captureV2 = {};
  final Map<String, DateTime> _captureV2At = {};

  /// CAP-5: whether the server advertises `capture_contract_v2` for [uid]. Same
  /// rules as [syncSeq]: positive proof only, a short TTL because it is a kill
  /// switch, and never an answer without cloud consent.
  Future<ServerCapabilityState> captureContractV2({String? uid}) async {
    final user = uid ?? await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final at = _captureV2At[key];
    final cached = _captureV2[key];
    if (cached != null &&
        cached != ServerCapabilityState.unknown &&
        at != null &&
        _clock().difference(at) < syncSeqTtl) {
      return cached;
    }
    if (!await _mayEgress()) return ServerCapabilityState.unknown;
    ServerCapabilityState result;
    try {
      final raw = await _getClient().rpc('qirsh_server_capabilities');
      result = raw is Map && raw[kCapCaptureContractV2] == true
          ? ServerCapabilityState.verified
          : ServerCapabilityState.unsupported;
    } catch (e) {
      result = _isRpcMissing(e)
          ? ServerCapabilityState.unsupported
          : ServerCapabilityState.unknown;
    }
    _captureV2[key] = result;
    _captureV2At[key] = _clock();
    return result;
  }

  /// A-5: re-probes a cached `unsupported` / `unknown` answer (the server may
  /// have deployed the capability since — migration 0102 — while this process
  /// kept running), at most once per [minInterval]. A `verified` answer is never
  /// re-probed. Called on app resume; Retry uses `force: true` directly.
  Future<ServerCapabilityState> reprobeIfStale({
    Duration minInterval = const Duration(minutes: 15),
  }) async {
    final user = await _getAuthUserId();
    if (user == null) return ServerCapabilityState.unknown;
    final key = _key(user);
    final cached = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    if (cached == ServerCapabilityState.verified) return cached;
    final last = _probedAt[key];
    if (last != null && _clock().difference(last) < minInterval) return cached;
    return awaitingFxTransactions(uid: user, force: true);
  }

  /// A send of the awaiting-FX shape was accepted by the server: proof.
  void noteVerified(String uid) => _set(uid, ServerCapabilityState.verified);

  /// The server rejected the awaiting-FX shape (23514) this session.
  void noteUnsupported(String uid) =>
      _set(uid, ServerCapabilityState.unsupported);

  void _set(String uid, ServerCapabilityState state) {
    final key = _key(uid);
    final before = _awaitingFx[key] ?? ServerCapabilityState.unknown;
    _awaitingFx[key] = state;
    if (state == ServerCapabilityState.unknown) {
      _unknownAt[key] = _clock();
    } else {
      _unknownAt.remove(key);
    }
    if (before != state) {
      for (final l in List.of(_listeners)) {
        l(uid, state);
      }
    }
  }

  /// The RPC does not exist (PostgREST schema-cache miss / HTTP 404 / undefined
  /// function). Auth, network and server errors are NOT "missing".
  static bool _isRpcMissing(Object e) {
    if (e is! PostgrestException) return false;
    final code = e.code ?? '';
    return code == 'PGRST202' || code == '404' || code == '42883';
  }
}
