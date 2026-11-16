import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import '../../../core/sync/sync_health.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/guarded_mutation.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_conflict_store.dart';
import '../../../core/sync/conflict_policy.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
import '../../../data/sync/revision_cas.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/sync/server_capabilities.dart';
import '../../../data/sync/sync_cursor.dart';
import 'ledger_outbox_queue.dart';
import 'ledger_payload.dart';
import 'ledger_sync_engine.dart';

/// The acknowledgement columns a legacy (non-CAS) write reads back. The CAS
/// path gets the whole row from the RPC.
const String _ackCols = 'id, updated_at';

class LedgerPushResult {
  const LedgerPushResult({
    this.pushed = 0,
    this.conflicts = 0,
    this.failed = 0,
    this.abandoned = 0,
    this.parked = 0,
  });

  final int pushed;
  final int conflicts;
  final int failed;
  final int abandoned;

  /// MALI-026 (B8-2.10 §8): money rows held for unverified exact push transport.
  final int parked;
}

class LedgerPushService implements LedgerPushAdapter {
  LedgerPushService({
    required AppDatabase db,
    required LedgerOutboxQueue queue,
    required bool Function() isPushEnabled,
    Future<String?> Function()? getAuthUserId,
    SupabaseClient Function()? getClient,
    // WP-5: null (or a legacy plan) keeps the legacy guarded push unchanged.
    RevisionCasGate? casGate,
    CasRemote? casRemote,
    // MALI-026 (B8-2.10 §8/§9): the money-authority mode and exact PUSH capability.
    // Both default so v29 (legacy + unknown) never parks — current behavior is
    // unchanged. Only canonical mode with an unverified push capability parks.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    /// C-3 — consulted at the moment of egress; defaults to DENY.
    Future<bool> Function()? mayEgress,
    SyncHealth? health,
    AccountFenceRetry? fenceRetry,
    // A-6: server capability probe. Null = never verified, so awaiting-FX rows
    // stay parked (fail-safe).
    ServerCapabilitiesService? capabilities,
  })  : _db = db,
        _capabilities = capabilities,
        _fenceRetry = fenceRetry ?? AccountFenceRetry(),
        _health = health,
        _queue = queue,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getClient = getClient ?? _defaultGetClient,
        _casGate = casGate,
        _casRemote = casRemote ?? const SupabaseCasRemote(),
        _conflicts = SyncConflictStore(db),
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _mayEgress = mayEgress ?? _denyEgressByDefault;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static SupabaseClient _defaultGetClient() => Supabase.instance.client;

  final AppDatabase _db;
  final LedgerOutboxQueue _queue;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final AccountFenceRetry _fenceRetry;
  final ServerCapabilitiesService? _capabilities;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final SupabaseClient Function() _getClient;

  final RevisionCasGate? _casGate;
  final CasRemote _casRemote;
  RevisionCasEngine get _cas =>
      RevisionCasEngine(_LedgerCasRemote(_casRemote, _invocation!));
  final SyncConflictStore _conflicts;
  CasPlan _plan = const CasPlan(CasMode.legacy);

  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;

  static Future<bool> _denyEgressByDefault() async => false;

  bool _busy = false;
  _LedgerInvocation? _invocation;

  @override
  Future<LedgerPushResult> push() => pushWithPhase(SyncPhaseBinding());

  Future<LedgerPushResult> pushWithPhase(SyncPhaseBinding phase) async {
    if (_busy) throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.overlap);
    _busy = true;
    try {
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      if (handle == null) {
        throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.unbound);
      }
      final invocation = _LedgerInvocation(authority, handle, _db, phase);
      _invocation = invocation;
      phase.bind(invocation);
      final result = await _pushBound();
      _requireCurrent();
      return result;
    } on StaleAdmissionException {
      throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    } finally {
      _invocation = null;
      _busy = false;
    }
  }

  void _requireCurrent() {
    if (_invocation?.isCurrent != true) {
      throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    }
  }

  Future<T> _local<T>(Future<T> Function() action) async {
    _requireCurrent();
    try {
      return await _invocation!.runLocal(action);
    } on StaleAdmissionException {
      throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    }
  }

  SupabaseClient _client() {
    _requireCurrent();
    return _getClient();
  }

  Future<T> _remote<T>(Future<T> Function() send) async {
    _requireCurrent();
    try {
      final result = await send();
      _requireCurrent();
      return result;
    } catch (error) {
      // Decode genuine negative authority before ordinary readiness checks.
      if (decodeLedgerAccountDenial(error) != null) rethrow;
      _requireCurrent();
      rethrow;
    }
  }

  Future<LedgerPushResult> _pushBound() async {
    // C-3 — transactions are money. Without cloud consent they stay on device.
    if (!await _mayEgress()) {
      _invocation!.phase.noteConsentBlocked(_health);
      return const LedgerPushResult();
    }
    _requireCurrent();
    if (!_isPushEnabled()) return const LedgerPushResult();

    final userId = await _getAuthUserId();
    _requireCurrent();
    if (userId == null) return const LedgerPushResult();
    if (userId != _invocation!.ownerUid) {
      throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
    }

    // WP-5: legacy push, or revision CAS with the replica's epoch. When the
    // capability cannot be proven this cycle nothing is sent or consumed.
    _plan = _casGate == null ? const CasPlan(CasMode.legacy) : await _casGate.planForLedger(userId,
        authority: _invocation!.authority, handle: _invocation!.handle, database: _db);
    _requireCurrent();
    if (_plan.mode == CasMode.stopped) return const LedgerPushResult();

    // D-7: the AuthSessionValid broadcast has no replay, so a cold start can miss
    // it. A valid authenticated session at the start of a cycle re-arms rows
    // parked `auth_required` (cheap UPDATE; no attempt was ever consumed).
    if (outboxHasValidSession()) await _local(() => _queue.reArmAuthParked());

    // MALI-026 (B8-2.10 §9): once exact push transport is verified, re-arm any
    // rows parked while it was unverified — the SAME durable rows drain now. A
    // no-op today (nothing is ever parked while the capability is unknown/legacy).
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _local(() => _queue.reArmParked());
    }

    // A-6: dead letters caused by the pre-A-6 CHECK rejection of awaiting-FX
    // rows are recovered to a visible park (idempotent, nothing else touched);
    // parked awaiting-FX rows drain once the server is verified to accept them.
    await _local(() => _db.transaction(() => _queue.recoverAwaitingFxDeadLetters()));
    if (await _local(() => _queue.hasAwaitingFxParked()) &&
        await _awaitingFxState(userId) == ServerCapabilityState.verified) {
      await _local(() => _queue.reArmAwaitingFxParked());
    }

    // A-2 (G18): only rows recorded for THIS identity may be sent; foreign and
    // unverified legacy rows are parked (observable, never deleted, never sent).
    final ownershipVerified = await _queue.ownershipVerified(userId);
    _requireCurrent();
    await _local(() => _queue.reconcileVerifiedOwnership(userId, ownershipVerified));

    final items = await _local(() => _queue.pendingItems());
    if (items.isEmpty) return const LedgerPushResult();

    int pushed = 0;
    int conflicts = 0;
    int failed = 0;
    int abandoned = 0;
    int parked = 0;

    for (final item in items) {
      try {
        _requireCurrent();
        if (item.operationId == null || !_ledgerOperationId.hasMatch(item.operationId!)) {
          throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.provenance);
        }
        final outcome = await _fenceRetry.runItem(
            isCurrent: () async {
              _requireCurrent();
              final currentUid = await _getAuthUserId();
              _requireCurrent();
              final consent = await _mayEgress();
              _requireCurrent();
              return _isPushEnabled() && currentUid == userId && consent &&
                  await _local(() => _queue.accountFenceCurrent(item));
            },
            body: () => _processItem(item, userId));
        switch (outcome) {
          case _PushOutcome.pushed:
            pushed++;
          case _PushOutcome.conflict:
            conflicts++;
          case _PushOutcome.abandoned:
            abandoned++;
          case _PushOutcome.deferred:
            // Edited while being examined: left pending for the next cycle.
            break;
          case _PushOutcome.parked:
            // Held durably; not sent, not synced, not a failure/retry.
            parked++;
            _invocation!.phase.noteCapabilityParked(_health);
        }
      } on CasEpochMismatch {
        // The replica's epoch is stale: nothing was written. Leave the op
        // queued (WP-7 owns the rebootstrap) and stop this cycle.
        await _local(() => _queue.releaseInFlight(item.id));
        break;
      } on LedgerDeliveryStopped {
        rethrow;
      } on AccountFenceRetryStopped {
        _requireCurrent();
        break;
      } catch (e) {
        final denial = decodeLedgerAccountDenial(e);
        if (denial != null) {
          final current = _invocation!;
          final result = await current.authority.acceptLedgerDenial(current.handle,
              _db, denial, rowId: item.id, transactionId: item.transactionId,
              ownerUid: item.ownerUid, opSeq: item.opSeq,
              operationId: item.operationId!,
              park: (ticket) => _queue.parkAccountDenial(item, denial, ticket));
          throw LedgerDeliveryStopped(LedgerDeliveryStopReason.denial,
              accepted: result.accepted, parked: result.parked, complete: result.complete);
        }
        _requireCurrent();
        final fence = classifyOutboxError(e);
        if (fence == OutboxFailureClass.accountFenceContention ||
            fence == OutboxFailureClass.accountDeletionPending) {
          final held = await _local(() => _queue.recordAccountFenceFailure(item, fence,
              _fenceRetry.clock().add(_fenceRetry.cooldown)));
          _invocation!.phase.noteFailure(_health, e);
          if (fence == OutboxFailureClass.accountDeletionPending) { if (held) parked++; break; }
          continue;
        }
        failed++;
        _invocation!.phase.noteFailure(_health, e);
        await _local(() => _db.transaction(() => _queue.markFailed(item.id, e.toString(), classifyOutboxError(e))));
        if (kDebugMode) debugPrint('[LedgerPush] item error: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[LedgerPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return LedgerPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
      parked: parked,
    );
  }

  Future<_PushOutcome> _processItem(OutboxItem item, String userId) async {
    final payload = item.payloadJson;

    // MALI-056n — a payload written by a NEWER app version (after a downgrade)
    // must not be reinterpreted by this build; dead-letter it as an unsupported
    // schema so a later compatible upgrade can re-arm and apply it correctly.
    final version = (payload['payload_version'] as num?)?.toInt() ?? 1;
    if (version > kLedgerPayloadVersion) {
      await _local(() => _db.transaction(() => _queue.markFailed(
        item.id,
        'unsupported ledger payload version $version',
        OutboxFailureClass.unsupportedSchema,
      )));
      return _PushOutcome.abandoned;
    }

    // MALI-026 (B8-2.10 §8): park money-bearing writes whose exact push transport
    // is unverified BEFORE any network send. Deletes carry no money and are never
    // parked. Legacy (v29) never parks — shouldParkExactMoneyWrite is false for it.
    if (item.operation != OutboxOperation.delete &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: _pushCapability(),
        )) {
      // Only while the row was not edited meanwhile (op_seq unchanged).
      final parkedNow = await _local(() => _queue.park(
          item.id, exactMoneyTransportUnverifiedReason,
          ifOpSeq: item.opSeq));
      return parkedNow ? _PushOutcome.parked : _PushOutcome.deferred;
    }

    // A-6: an awaiting-FX body (amount 0 + foreign amount/currency) is sent only
    // once the server is verified to accept it; otherwise it is parked, never
    // sent and never dead-lettered. No converted amount is ever fabricated.
    final awaitingFx = item.operation != OutboxOperation.delete &&
        LedgerOutboxQueue.isAwaitingFxPayload(payload);
    if (awaitingFx &&
        await _awaitingFxState(userId) != ServerCapabilityState.verified) {
      // D-3: only while the row was not edited meanwhile — the capability RPC
      // above can take a while, and a priced edit folded in during it must stay
      // pending (it is no longer an awaiting-FX body).
      final parkedNow = await _local(() => _queue.park(item.id, kParkAwaitingServerFxSupport,
          ifOpSeq: item.opSeq));
      return parkedNow ? _PushOutcome.parked : _PushOutcome.deferred;
    }

    try {
      final cas = _plan.isCas;
      final outcome = switch (item.operation) {
        OutboxOperation.create => cas
            ? await _casCreate(item, payload, userId)
            : await _pushCreate(item, payload, userId),
        OutboxOperation.update => cas
            ? await _casUpdate(item, payload, userId)
            : await _pushUpdate(item, payload, userId),
        OutboxOperation.delete => cas
            ? await _casDelete(item, payload, userId)
            : await _pushDelete(item, payload, userId),
      };
      // An accepted awaiting-FX write is positive proof of server support.
      if (awaitingFx && outcome == _PushOutcome.pushed) {
        _capabilities?.noteVerified(userId);
      }
      return outcome;
    } on PostgrestException catch (e) {
      // The CHECK still rejects the awaiting-FX shape: the server does not
      // support it. Park (not dead-letter), keep the attempt count, and treat
      // the capability as unsupported for this session. Only when the row was
      // not edited in flight (an edit may have priced it).
      if (awaitingFx && e.code == '23514') {
        _capabilities?.noteUnsupported(userId);
        final parkedNow = await _local(() => _queue.park(item.id, kParkAwaitingServerFxSupport,
            ifOpSeq: item.opSeq));
        return parkedNow ? _PushOutcome.parked : _PushOutcome.deferred;
      }
      rethrow;
    }
  }

  Future<ServerCapabilityState> _awaitingFxState(String userId) async =>
      await _capabilities?.awaitingFxTransactions(uid: userId) ??
      ServerCapabilityState.unknown;

  Future<_PushOutcome> _pushCreate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    final serverRow = await _toServerRow(payload, userId);

    try {
      final response = await _remote(() => retryAccountFenceMutation(() => _client()
          .from('user_transactions')
          .upsert(
            {...serverRow, 'client_request_id': localId},
            onConflict: 'user_id,client_request_id',
          )
          .select(_ackCols)
          .single()));

      final serverId = response['id'] as String;
      await _ackAndAttach(
        item,
        serverId,
        serverUpdatedAt: response['updated_at'] as String?,
        serverRevision: response['revision'] as int?,
      );
      return _PushOutcome.pushed;
    } catch (e) {
      // Conflict detected by server (e.g. row already exists with newer updated_at).
      if (isTransportConflict(e)) {
        await _recordConflict(item);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_PushOutcome> _pushUpdate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    String? serverId = payload['server_id'] as String?;

    // If server_id unknown, try to find it via the stable client request id.
    serverId ??= await _findServerId(localId, userId);

    if (serverId == null) {
      // Row not on server yet — treat as create.
      return _pushCreate(item, payload, userId);
    }

    final targetServerId = serverId;
    final serverRow = await _toServerRow(payload, userId);
    // Never overwrite source on existing server rows — the server already has
    // the authoritative source (e.g. 'ios_shortcut' from the relay dual-write).
    // Relay-imported transactions only appear in the outbox as updates/deletes,
    // never as creates, so their server source must be preserved.
    serverRow.remove('source');

    try {
      // C-6 — fail-safe guarded path (capability OFF, or revision unknown).
      //
      // This used to SELECT the server's updated_at, compare it, then issue a
      // blind write by id. Two round-trips, so a remote write landing between
      // them was silently clobbered: the guard had passed against a value that
      // was no longer true when the write executed.
      //
      // The predicate now travels WITH the write, exactly as the tombstone
      // branch below already did, so the database enforces it and 0 affected
      // rows IS the conflict signal.
      //
      // A-3 (G17): with no stored base token, fetch the row's CURRENT updated_at
      // and guard on that — never a blind id-only write. The local pending edit
      // wins only if the server row is unchanged since the fetch; zero rows
      // (changed or vanished) → conflict, local edit kept.
      final base = payload['server_updated_at'] as String? ??
          await _fetchServerUpdatedAt(serverId);
      final rows = base == null
          ? const <dynamic>[]
          : await _remote(() => retryAccountFenceMutation(() => _client()
              .from('user_transactions')
              .update(serverRow)
              .eq('id', targetServerId)
              .eq('updated_at', base)
              .select('updated_at')));
      final updated = guardedAck(rows, 'ledger.atomicGuardedUpdate');
      if (updated == null) {
        // 0 rows → either the row vanished or another writer moved it past our
        // base. Both are conflicts; the guard no longer needs to distinguish
        // them with a second read.
        await _recordConflict(item);
        return _PushOutcome.conflict;
      }
      await _ackAndAttach(
        item,
        serverId,
        // Store the version our update produced — the next edit's outbox
        // payload carries it as the base token (MALI-009).
        serverUpdatedAt: updated['updated_at'] as String?,
      );
      return _PushOutcome.pushed;
    } catch (e) {
      if (isTransportConflict(e)) {
        await _recordConflict(item);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  Future<_PushOutcome> _pushDelete(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    String? serverId = payload['server_id'] as String?;
    serverId ??= await _findServerId(localId, userId);

    if (serverId == null) {
      // `_findServerId` returns null ONLY on a confirmed empty result (any
      // lookup error rethrows into the retryable failure path), so the row
      // truly never reached the server; just remove the outbox item.
      await _ackTombstone(item);
      return _PushOutcome.pushed;
    }

    final targetServerId = serverId;
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    try {
      // Never id-only: guard on the last-known updated_at, or (when unknown) on
      // the row not already being tombstoned. Each branch is a single chained
      // statement so the guard predicate always travels with the deleted_at write.
      final base = payload['server_updated_at'] as String?;
      final rows = base != null
          ? await _remote(() => retryAccountFenceMutation(() => _client()
              .from('user_transactions')
              .update({'deleted_at': deletedAt})
              .eq('id', targetServerId)
              .eq('updated_at', base)
              .select('id, updated_at')))
          : await _remote(() => retryAccountFenceMutation(() => _client()
              .from('user_transactions')
              .update({'deleted_at': deletedAt})
              .eq('id', targetServerId)
              .isFilter('deleted_at', null)
              .select('id, updated_at')));
      final ack = guardedAck(rows, 'ledger.guardedTombstone');
      if (ack != null) {
        await _ackTombstone(item);
        return _PushOutcome.pushed;
      }
      return await _resolveDeleteConflict(item, serverId);
    } catch (e) {
      if (isTransportConflict(e)) {
        await _recordConflict(item);
        return _PushOutcome.conflict;
      }
      rethrow;
    }
  }

  // ── WP-5: revision CAS (capability `revision_cas`) ───────────────────────

  Future<_PushOutcome> _casCreate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    final row = {
      ...await _toServerRow(payload, userId),
      'client_request_id': localId,
    };
    final d = await _remote(() => _cas.create(
        table: 'user_transactions',
        epoch: _plan.epoch!,
        opId: item.operationId!,
        row: row));
    if (d.kind == CasDecisionKind.acked) {
      await _casAck(item, d.row!);
      return _PushOutcome.pushed;
    }
    return _casConflict(item, d,
        d.cloudTombstoned ? SyncConflictKind.tombstone : SyncConflictKind.create);
  }

  Future<_PushOutcome> _casUpdate(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    final serverId = (payload['server_id'] as String?) ??
        await _findServerId(localId, userId);
    if (serverId == null) return _casCreate(item, payload, userId);
    final patch = await _toServerRow(payload, userId)
      ..remove('source')
      ..remove('user_id');
    final d = await _remote(() => _cas.update(
      table: 'user_transactions',
      epoch: _plan.epoch!,
      opId: item.operationId!,
      priorOpIds: item.priorOpIds,
      serverId: serverId,
      baseRevision: item.baseRevision ?? (payload['server_revision'] as int?),
      baseUpdatedAt: payload['server_updated_at'] as String?,
      patch: patch,
    ));
    switch (d.kind) {
      case CasDecisionKind.acked:
        await _casAck(item, d.row!);
        return _PushOutcome.pushed;
      case CasDecisionKind.missing:
        // The cloud has no such row (never landed / purged): create it again
        // by identity. Insert-if-absent still refuses to un-delete a tombstone.
        return _casCreate(item, payload, userId);
      default:
        return _casConflict(item, d,
            d.cloudTombstoned ? SyncConflictKind.tombstone : SyncConflictKind.update);
    }
  }

  Future<_PushOutcome> _casDelete(
    OutboxItem item,
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final localId = payload['local_id'] as String? ?? item.transactionId;
    final serverId = (payload['server_id'] as String?) ??
        await _findServerId(localId, userId);
    if (serverId == null) {
      await _ackTombstone(item);
      return _PushOutcome.pushed;
    }
    final d = await _remote(() => _cas.tombstone(
      table: 'user_transactions',
      epoch: _plan.epoch!,
      opId: item.operationId!,
      priorOpIds: item.priorOpIds,
      serverId: serverId,
      baseRevision: item.baseRevision ?? (payload['server_revision'] as int?),
      baseUpdatedAt: payload['server_updated_at'] as String?,
    ));
    if (d.kind == CasDecisionKind.acked || d.kind == CasDecisionKind.gone) {
      await _ackTombstone(item);
      return _PushOutcome.pushed;
    }
    return _casConflict(item, d, SyncConflictKind.delete);
  }

  Future<void> _casAck(OutboxItem item, Map<String, dynamic> row) =>
      _ackAndAttach(
        item,
        row['id'] as String,
        serverUpdatedAt: row['updated_at'] as String?,
        serverRevision: (row['revision'] as num?)?.toInt(),
      );

  /// The conflict is stored durably BEFORE the outbox op is consumed, in one
  /// local transaction.
  Future<_PushOutcome> _casConflict(
    OutboxItem item,
    CasDecision d,
    SyncConflictKind kind,
  ) async {
    await _local(() => _db.transaction(() async {
      await _conflicts.flag(
        entityType: ConflictEntities.transaction,
        localId: item.transactionId,
        kind: kind,
        serverId: d.row?['id'] as String?,
        theirs: d.row,
        theirsRevision: (d.row?['revision'] as num?)?.toInt(),
        operationId: item.operationId,
      );
      await _queue.markSuccess(item);
    }));
    return _PushOutcome.conflict;
  }

  /// A guarded tombstone matched zero rows. Classify (Phase-9K §5):
  ///   A. already tombstoned  → the delete already converged → idempotent success
  ///   B. still live, advanced → a newer accepted update → conflict, do NOT delete
  ///   C. absent               → fail-closed → conflict
  /// On B/C the server row (its newer update) is untouched — the next pull
  /// re-materialises the transaction, so the update is never lost. Transactions
  /// soft-delete locally as status='ignored' (the row persists), so the conflict
  /// flag is durable and recoverable via keep-mine / keep-theirs.
  Future<_PushOutcome> _resolveDeleteConflict(
    OutboxItem item,
    String serverId,
  ) async {
    final state = await _remote(() => _client()
        .from('user_transactions')
        .select('deleted_at')
        .eq('id', serverId)
        .maybeSingle());
    if (state != null && state['deleted_at'] != null) {
      await _ackTombstone(item); // A
      return _PushOutcome.pushed;
    }
    await _recordConflict(item); // B (live) or C (absent)
    return _PushOutcome.conflict;
  }

  /// Resolves the server id by the stable client request id. Returns null ONLY
  /// on a confirmed empty result. Any error (network, auth, server) PROPAGATES:
  /// swallowing it made a delete look "never reached the server" and ACK the
  /// row, silently losing the remote delete on a flaky connection.
  Future<String?> _findServerId(String localId, String userId) async {
    final row = await _remote(() => _client()
        .from('user_transactions')
        .select('id')
        .eq('user_id', userId)
        .eq('client_request_id', localId)
        .maybeSingle());
    return row?['id'] as String?;
  }

  Future<String?> _fetchServerUpdatedAt(String serverId) async {
    final row = await _remote(() => _client()
        .from('user_transactions')
        .select('updated_at')
        .eq('id', serverId)
        .maybeSingle());
    return row?['updated_at'] as String?;
  }

  /// A-2 (G3): ACK + persist the server row identity in ONE local transaction
  /// (a crash cannot leave the row consumed without the server id).
  Future<void> _ackAndAttach(
    OutboxItem item,
    String serverId, {
    String? serverUpdatedAt,
    int? serverRevision,
  }) {
    return _local(() => _db.transaction(() async {
      await _queue.acknowledge(
        item,
        serverId: serverId,
        serverUpdatedAt: serverUpdatedAt,
        serverRevision: serverRevision,
      );
      await _attachServerId(
        item.transactionId,
        serverId,
        serverUpdatedAt: serverUpdatedAt,
        serverRevision: serverRevision,
      );
    }));
  }

  /// A-2 (G15): a tombstone ACK settles the entity too (it used to stay
  /// 'pending' forever) — unless another edit is still queued for it.
  Future<void> _ackTombstone(OutboxItem item) {
    return _local(() => _db.transaction(() async {
      await _queue.acknowledge(item);
      await _markSyncedIfClear(item.transactionId);
    }));
  }

  Future<void> _markSyncedIfClear(String transactionId) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE transactions
      SET sync_status = 'synced', synced_at = ${sqlString(now)}
      WHERE id = ${sqlString(transactionId)}
        AND sync_status != 'conflict'
        AND NOT EXISTS (
          SELECT 1 FROM ledger_sync_outbox
          WHERE transaction_id = ${sqlString(transactionId)});
    ''');
  }

  Future<void> _attachServerId(
    String transactionId,
    String serverId, {
    String? serverUpdatedAt,
    int? serverRevision,
  }) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          ${serverUpdatedAt != null ? 'server_updated_at = ${sqlString(canonicalServerTimestamp(serverUpdatedAt)!)},' : ''}
          ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
          -- A-2 (G3): 'synced' only when no outbox row remains for this
          -- transaction (an edit folded in while the push was in flight keeps
          -- it pending; its server id/version are persisted regardless).
          -- D-1: an entity in 'conflict' is never flipped to 'synced' implicitly.
          sync_status = CASE WHEN sync_status = 'conflict' OR EXISTS (
            SELECT 1 FROM ledger_sync_outbox
            WHERE transaction_id = ${sqlString(transactionId)})
            THEN sync_status ELSE 'synced' END
      WHERE id = ${sqlString(transactionId)};
    ''');
  }

  Future<void> _recordConflict(OutboxItem item) => _local(() =>
      _db.transaction(() async {
        await _markConflict(item.transactionId);
        await _queue.markSuccess(item);
      }));

  Future<void> _markConflict(String transactionId) async {
    await _db.customStatement('''
      UPDATE transactions
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(transactionId)};
    ''');
  }

  Future<Map<String, dynamic>> _toServerRow(
    Map<String, dynamic> payload,
    String userId,
  ) async {
    final legacyType = payload['type'] as String? ?? 'debit';
    // MALI-056n — prefer the versioned canonical type/direction when present, so
    // withdrawal/payment/unknown are mapped explicitly (not collapsed via the
    // lossy legacy debit/credit token). Old queued rows without a version fall
    // back to the legacy mapping below.
    final version = (payload['payload_version'] as num?)?.toInt() ?? 1;
    final canonicalType = payload['canonical_type'] as String?;
    final useCanonical = version >= 2 && canonicalType != null;
    final row = <String, dynamic>{
      'user_id': userId,
      'amount': payload['amount'],
      'currency': payload['currency'],
      'direction': useCanonical
          ? LedgerPayloadCodec.serverDirectionFor(
              canonicalType, payload['canonical_direction'] as String?)
          : switch (legacyType) {
              'credit' => 'credit',
              // A refund is money coming back — its direction is credit even
              // though it is not income (MALI-010).
              'refund' => 'credit',
              'debit' => 'debit',
              _ => 'unknown',
            },
      'transaction_type': useCanonical
          ? LedgerPayloadCodec.serverTransactionTypeFor(canonicalType)
          : switch (legacyType) {
              'credit' => 'income',
              'transfer' => 'transfer',
              'refund' => 'refund',
              'debit' => 'expense',
              _ => 'unknown',
            },
      // source is present for create operations; absent for update operations.
      // The fallback 'manual' is only reached when an update is redirected to
      // a create (_pushUpdate → _pushCreate) because the row is not on the
      // server yet (dual-write was OFF). _pushUpdate strips 'source' before
      // patching, so this fallback never overwrites an existing server source.
      'source': payload['source'] ?? 'manual',
      'occurred_at': payload['occurred_at'],
    };
    if (payload['merchant'] != null) row['merchant'] = payload['merchant'];
    if (payload['note'] != null) row['description'] = payload['note'];
    // Round-trip the confirmation state (MALI-010). Server check constraint
    // accepts confirmed/pending/ignored (migration 0029).
    final status = payload['status'] as String?;
    if (status == 'confirmed' || status == 'pending' || status == 'ignored') {
      row['status'] = status;
    }
    final localAccountId = payload['account_id'] as String?;
    if (localAccountId != null) {
      row['local_account_id'] = localAccountId;
      final account = await _local(() => _db
          .customSelect(
            'SELECT server_id FROM accounts '
            'WHERE id = ${sqlString(localAccountId)} LIMIT 1;',
          )
          .getSingleOrNull());
      final serverAccountId = account?.readNullable<String>('server_id');
      if (serverAccountId != null) {
        row['server_account_id'] = serverAccountId;
      }
    }
    if (payload['confidence'] != null) {
      row['confidence'] = payload['confidence'];
    }
    // Category: the server stores the stable category KEY, not the local UUID.
    final localCategoryId = payload['category_id'] as String?;
    if (localCategoryId != null) {
      final cat = await _local(() => _db
          .customSelect(
            'SELECT key FROM categories '
            'WHERE id = ${sqlString(localCategoryId)} LIMIT 1;',
          )
          .getSingleOrNull());
      final key = cat?.readNullable<String>('key');
      if (key != null) row['category_id'] = key;
    }
    if (payload['balance_after'] != null) {
      row['balance_after'] = payload['balance_after'];
    }
    if (payload['foreign_amount'] != null) {
      row['foreign_amount'] = payload['foreign_amount'];
    }
    if (payload['foreign_currency'] != null) {
      row['foreign_currency'] = payload['foreign_currency'];
    }
    // Metadata mirrors the backfill so card linkage + provenance survive the
    // round-trip (the server has no dedicated card_last4 column — last4 lives
    // in metadata). Only written when non-empty so an update never blanks
    // server metadata it has nothing to say about.
    final metadata = <String, dynamic>{};
    if (payload['card_last4'] != null) {
      metadata['last4'] = payload['card_last4'];
    }
    if (payload['source'] != null) {
      metadata['transaction_source'] = payload['source'];
    }
    // MALI-056n — round-trip the EXACT client type/source/direction through
    // metadata (the coarse server columns cannot represent them), so a second
    // device recovers the precise meaning instead of a collapsed approximation.
    if (useCanonical) {
      metadata['payload_version'] = version;
      metadata['canonical_type'] = canonicalType;
      metadata['canonical_source'] = payload['canonical_source'];
      metadata['canonical_direction'] = payload['canonical_direction'];
    }
    // Category provenance has its own server column. The server trusts it only
    // from a write that carries a FRESH `cs_op` token in metadata: an older app
    // version replaces metadata without one (or leaves it untouched), so its
    // category change is recorded as 'unknown' instead of keeping a stale
    // provenance (migration 20261117000000). Sent only with the canonical
    // metadata this write already carries, and only to a server that
    // advertises the column — an older server never sees an unknown column.
    final categorySource = payload['category_source'] as String?;
    if (useCanonical &&
        categorySource != null &&
        await _capabilities?.transactionCategorySource(uid: userId) ==
            ServerCapabilityState.verified) {
      row['category_source'] = categorySource;
      // The token names the value and the category it was minted for, so a
      // stale token echoed by another writer can never vouch for a different
      // category; the server takes the provenance from the token itself.
      metadata['cs_op'] = {
        'n': IdGenerator.next(),
        's': categorySource,
        'c': row['category_id'] ?? '',
      };
    }
    // The file-import marker shares the same server capability. Only ever
    // sent as true: the server keeps it sticky, so false could not clear it.
    if (payload['imported_from_file'] == true &&
        await _capabilities?.transactionCategorySource(uid: userId) ==
            ServerCapabilityState.verified) {
      row['imported_from_file'] = true;
    }
    if (metadata.isNotEmpty) row['metadata'] = metadata;
    return row;
  }
}

enum _PushOutcome { pushed, conflict, abandoned, parked, deferred }


final _ledgerOperationId = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

class _LedgerInvocation implements SyncPhaseLifecycle {
  _LedgerInvocation(this.authority, this.handle, this.database, this.phase);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding phase;
  String get ownerUid => authority.ownerUid(handle);
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database);
  @override
  Future<T> runLocal<T>(Future<T> Function() action) =>
      authority.runCurrentLocal(handle, database, action);
}


/// Guard the actual underlying method after the retry predicate's final await.
class _LedgerCasRemote implements CasRemote {
  _LedgerCasRemote(this.delegate, this.invocation);
  final CasRemote delegate;
  final _LedgerInvocation invocation;

  Future<T> _send<T>(Future<T> Function() send) async {
    void check() {
      if (!invocation.isCurrent) {
        throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.stale);
      }
    }
    check();
    try {
      final result = await send();
      check();
      return result;
    } catch (error) {
      if (decodeLedgerAccountDenial(error) != null) rethrow;
      check();
      rethrow;
    }
  }

  @override
  Future<CasResult> insertIfAbsent({required String table, required String epoch,
      required String opId, required Map<String, dynamic> row}) => _send(() =>
      delegate.insertIfAbsent(table: table, epoch: epoch, opId: opId, row: row));

  @override
  Future<CasResult> casUpdate({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision,
      required Map<String, dynamic> patch}) => _send(() => delegate.casUpdate(
      table: table, epoch: epoch, opId: opId, serverId: serverId,
      expectedRevision: expectedRevision, patch: patch));

  @override
  Future<CasResult> casTombstone({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision}) =>
      _send(() => delegate.casTombstone(table: table, epoch: epoch, opId: opId,
          serverId: serverId, expectedRevision: expectedRevision));

  @override
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId) =>
      _send(() => delegate.fetchRow(table, serverId));
}
