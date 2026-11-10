import 'dart:async';

import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/account_fence_retry.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/sync/guarded_mutation.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_conflict_store.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/exact_transport_capability.dart';
import '../../../data/sync/revision_cas.dart';
import 'planning_outbox_queue.dart';

/// Acknowledgement columns a legacy guarded write reads back (the CAS path
/// gets the whole row from the RPC).
const String _ackCols = 'id, updated_at';

/// A-3 (G7): remote tables whose `(user_id, local_id)` uniqueness is only a
/// PARTIAL index (migrations 0021/0055) — `ON CONFLICT (user_id, local_id)`
/// cannot target it, so creates are INSERT + replay-by-lookup, not upsert.
const Set<String> kPartialLocalIdIndexTables = {
  'user_budgets',
  'user_goals',
  'user_plans',
  'user_subscriptions',
};

class PlanningPushResult {
  const PlanningPushResult({
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

  /// MALI-026 (B8-2.10 §8): money rows held for unverified exact transport.
  final int parked;
}

abstract class PlanningRemoteSink {
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  );

  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  );

  /// MALI-022 (Phase-9K) — guarded tombstone without a revision base. Sets
  /// `deleted_at` only if the row still matches [expectedUpdatedAt] (an
  /// optimistic timestamp compare); when that is null, only if the row is not
  /// already tombstoned. Returns the ack, or null when no row matched. NEVER an
  /// id-only blind overwrite.
  Future<Map<String, dynamic>?> guardedTombstone(
    String table,
    String serverId,
    String? expectedUpdatedAt,
  );

  /// MALI-022 (Phase-9K) — the row's current `{deleted_at}` (null if the row is
  /// gone). Classifies a zero-row guarded tombstone: already-tombstoned (delete
  /// converged) vs still-live (a newer update advanced past our base) vs absent.
  Future<Map<String, dynamic>?> fetchRowState(String table, String serverId);

  /// MALI-022 — the current server `updated_at` for a known server row, used as
  /// the optimistic-concurrency compare on update. Null if the row is gone.
  Future<String?> fetchServerUpdatedAt(String table, String serverId);

  /// MALI-022 — targeted update of a known server row (used only after the
  /// base-token guard passes), returning the new id + updated_at, or null when
  /// 0 rows matched (the row vanished in the race window → a conflict).
  Future<Map<String, dynamic>?> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  );

  /// C-6 — atomic guarded update. Applies [row] only if the server row's
  /// `updated_at` still equals [expectedUpdatedAt], so the comparison and the
  /// write are ONE statement the database evaluates. Returns the ack, or null
  /// when no row matched — a genuine conflict, not a failure.
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  );

}

class SupabasePlanningRemoteSink implements PlanningRemoteSink {
  const SupabasePlanningRemoteSink();

  SupabaseClient get _client {
    (Zone.current[_parentInvocationKey] as _ParentInvocation?)?.requireCurrent();
    return Supabase.instance.client;
  }

  @override
  Future<Map<String, dynamic>?> findByLocalId(
    String table,
    String userId,
    String localId,
  ) async {
    return await _client
        .from(table)
        .select(_ackCols)
        .eq('user_id', userId)
        .eq('local_id', localId)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>?> guardedTombstone(
    String table,
    String serverId,
    String? expectedUpdatedAt,
  ) async {
    // Never id-only: guard on the last-known updated_at, or (when unknown) on
    // the row not already being tombstoned. Each branch is a single chained
    // statement so the guard predicate always travels with the deleted_at write.
    final deletedAt = (Zone.current[_parentCallKey] as _ParentCall?)
            ?.command
            ?.tombstoneStamp(table, serverId, expectedUpdatedAt) ??
        DateTime.now().toUtc().toIso8601String();
    _SinkMutation stamp() => _SinkMutation('guardedTombstone', table, serverId,
        expectedUpdatedAt, <String, dynamic>{'deleted_at': deletedAt});
    final rows = expectedUpdatedAt != null
        ? await retryAccountFenceMutation(() => _tagMutation(stamp(), (body) => _client
            .from(table)
            .update(body)
            .eq('id', serverId)
            .eq('updated_at', expectedUpdatedAt)
            .select('id, updated_at')))
        : await retryAccountFenceMutation(() => _tagMutation(stamp(), (body) => _client
            .from(table)
            .update(body)
            .eq('id', serverId)
            .isFilter('deleted_at', null)
            .select('id, updated_at')));
    return guardedAck(rows, 'planning.guardedTombstone[$table]');
  }

  @override
  Future<Map<String, dynamic>?> fetchRowState(
    String table,
    String serverId,
  ) async {
    return await _client
        .from(table)
        .select('deleted_at')
        .eq('id', serverId)
        .maybeSingle();
  }

  @override
  Future<Map<String, dynamic>> upsert(
    String table,
    Map<String, dynamic> row,
  ) async {
    // A-3 (G7): these tables only have a PARTIAL unique index
    // `(user_id, local_id) WHERE local_id IS NOT NULL`, which PostgREST's
    // `on_conflict=user_id,local_id` cannot target (42P10). A plain INSERT is
    // used instead; a replay of the same create surfaces as 23505, which the
    // push service resolves by fetching the existing row.
    if (kPartialLocalIdIndexTables.contains(table)) {
      return await _tagMutation(_SinkMutation('upsert', table, null, null, row),
          (row) => _client.from(table).insert(row).select(_ackCols).single());
    }
    return await _tagMutation(_SinkMutation('upsert', table, null, null, row),
        (row) => _client
            .from(table)
            .upsert(row, onConflict: 'user_id,local_id')
            .select(_ackCols)
            .single());
  }

  @override
  Future<String?> fetchServerUpdatedAt(String table, String serverId) async {
    final row = await _client
        .from(table)
        .select('updated_at')
        .eq('id', serverId)
        .maybeSingle();
    return row?['updated_at'] as String?;
  }

  @override
  Future<Map<String, dynamic>?> updateByServerId(
    String table,
    String serverId,
    Map<String, dynamic> row,
  ) async {
    // MALI-026 (Phase-9M): the guarded OFF update runs after the base-token
    // compare; a 0-row result (the row vanished in the race window) is a
    // conflict, decoded from the LIST — never a single-cardinality throw.
    final rows = await retryAccountFenceMutation(() => _tagMutation(
        _SinkMutation('updateByServerId', table, serverId, null, row),
        (row) => _client.from(table).update(row).eq('id', serverId).select(_ackCols)));
    return guardedAck(rows, 'planning.guardedUpdate[$table]');
  }

  @override
  Future<Map<String, dynamic>?> guardedUpdateByServerId(
    String table,
    String serverId,
    String expectedUpdatedAt,
    Map<String, dynamic> row,
  ) async {
    // C-6: the predicate travels WITH the write, so the database enforces it.
    final rows = await retryAccountFenceMutation(() => _tagMutation(
        _SinkMutation('guardedUpdate', table, serverId, expectedUpdatedAt, row),
        (row) => _client.from(table).update(row).eq('id', serverId)
            .eq('updated_at', expectedUpdatedAt).select(_ackCols)));
    return guardedAck(rows, 'planning.atomicGuardedUpdate[$table]');
  }
}

class PlanningPushService {
  PlanningPushService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    required bool Function(String entityType) isEnabled,
    Future<String?> Function()? getAuthUserId,
    PlanningRemoteSink? remoteSink,
    // WP-5: null (or a legacy plan) keeps the legacy guarded push unchanged.
    RevisionCasGate? casGate,
    CasRemote? casRemote,
    // MALI-026 (B8-2.10 §8/§9): both defaults preserve schema-v29 behavior:
    // legacy authority never parks, regardless of the unknown capability.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    ExactTransportCapability Function() pushCapability = _defaultPushCapability,
    // MALI-026 (B8-3 §30): whether the SERVER carries per-row planning currency
    // (0077). Budgets/goals push parks on THIS (they need a server currency
    // column), independent of the exact decimal-string transport capability.
    ExactTransportCapability Function() planningCurrencyCapability =
        _defaultPushCapability,
    /// C-3 / G13 — budgets, goals, plans, subscriptions, cards and categories
    /// are financial data. Consent is asked fresh per push and defaults to
    /// DENY, so a caller that omits it performs no network at all.
    Future<bool> Function()? mayEgress,
    /// `user_settings` carries PII (profile) — a separate egress class. Falls
    /// back to [mayEgress] (and therefore to DENY) when omitted.
    Future<bool> Function()? mayEgressProfile,
    SyncHealth? health,
    AccountFenceRetry? fenceRetry,
  })  : _mayEgress = mayEgress ?? _denyEgressByDefault,
        _mayEgressProfile =
            mayEgressProfile ?? mayEgress ?? _denyEgressByDefault,
        _fenceRetry = fenceRetry ?? AccountFenceRetry(),
        _health = health,
        _db = db,
        _queue = queue,
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _remoteSink = remoteSink ?? const SupabasePlanningRemoteSink(),
        _casGate = casGate,
        _casRemote = casRemote ?? const SupabaseCasRemote(),
        _conflicts = SyncConflictStore(db),
        _coordinator = coordinator,
        _pushCapability = pushCapability,
        _planningCurrencyCapability = planningCurrencyCapability;

  static ExactTransportCapability _defaultPushCapability() =>
      ExactTransportCapability.unknown;

  static Future<bool> _denyEgressByDefault() async => false;

  final Future<bool> Function() _mayEgress;
  final Future<bool> Function() _mayEgressProfile;
  final SyncHealth? _health;
  final AccountFenceRetry _fenceRetry;

  /// Outbox ids whose consent revocation was already delivered while consent is
  /// off — the row stays pending (its full payload must not egress) so this
  /// avoids re-sending the same narrow patch on every drain.
  final Set<String> _revocationDelivered = <String>{};

  static const _planningCurrencyEntityTypes = {
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final bool Function(String entityType) _isEnabled;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSink _remoteSink;

  final RevisionCasGate? _casGate;
  final CasRemote _casRemote;
  RevisionCasEngine get _cas =>
      RevisionCasEngine(_ParentCasRemote(_casRemote, _invocation!, _intent));
  final SyncConflictStore _conflicts;
  CasPlan _plan = const CasPlan(CasMode.legacy);

  final PlanningCutoverCoordinator _coordinator;
  final ExactTransportCapability Function() _pushCapability;
  final ExactTransportCapability Function() _planningCurrencyCapability;

  static const _moneyEntityTypes = {
    PlanningOutboxQueue.accountsEntityType,
    PlanningOutboxQueue.subscriptionsEntityType,
    PlanningOutboxQueue.plansEntityType,
    PlanningOutboxQueue.billPaymentsEntityType,
    // MALI-026 (B8-3 §30) — budgets/goals become canonical planning money at v30.
    // Their exact push depends on the server per-row currency column (0077, still
    // UNDEPLOYED), so canonical push parks until that capability is verified.
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  static const _entityTable = {
    PlanningOutboxQueue.budgetsEntityType: 'user_budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'user_subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'user_goals',
    PlanningOutboxQueue.plansEntityType: 'user_plans',
    PlanningOutboxQueue.cardsEntityType: 'user_cards',
    PlanningOutboxQueue.categoriesEntityType: 'user_categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
  };

  static const _localTable = {
    PlanningOutboxQueue.budgetsEntityType: 'budgets',
    PlanningOutboxQueue.subscriptionsEntityType: 'subscriptions',
    PlanningOutboxQueue.goalsEntityType: 'goals',
    PlanningOutboxQueue.plansEntityType: 'plans',
    PlanningOutboxQueue.cardsEntityType: 'cards',
    PlanningOutboxQueue.categoriesEntityType: 'categories',
    PlanningOutboxQueue.settingsEntityType: 'user_settings',
  };

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  bool _busy = false;
  _ParentInvocation? _invocation;
  AccountFenceParentIntent? _intent;
  AccountFenceHandle? _revocationHandle;
  static final _operationId = RegExp(
      r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  Future<PlanningPushResult> push() => pushWithPhase(SyncPhaseBinding());

  Future<PlanningPushResult> pushWithPhase(SyncPhaseBinding phase) async {
    if (_busy) throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.overlap);
    _busy = true;
    final inherited = phase.isBound ? phase : null;
    void supplied() {
      if (inherited != null && (!inherited.isCurrent || !identical(inherited.database, _db))) {
        throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
      }
    }
    try {
      supplied();
      final authority = AccountFenceAuthority.shared;
      final handle = await authority.captureForDatabase(AppSession.instance, _db);
      supplied();
      if (handle == null) throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.unbound);
      final invocation = _ParentInvocation(authority, handle, _db, phase, inherited);
      _invocation = invocation;
      if (!phase.isBound) phase.bind(invocation);
      if (_revocationHandle == null || !authority.isCurrentForDatabase(_revocationHandle!, _db)) {
        _revocationDelivered.clear();
      }
      _revocationHandle = handle;
      final result = await _pushBound();
      _requireCurrent();
      return result;
    } on StaleAdmissionException {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
    } finally {
      _intent = null; _invocation = null; _busy = false;
    }
  }

  void _requireCurrent() => _invocation!.requireCurrent();
  Future<T> _local<T>(Future<T> Function() action) async {
    _requireCurrent();
    try { return await _invocation!.runLocal(action); }
    on StaleAdmissionException { throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale); }
  }

  Future<void> _itemLocal(PlanningOutboxItem item, Future<void> Function() action) =>
      _local(() => _db.transaction(() async {
        if (!await _queue.parentHolderCurrent(item)) return;
        await action();
      }));

  Future<T> _remote<T>(Future<T> Function() action, {_ParentCommand? command}) async {
    _requireCurrent();
    // Fresh per call: a prior call's dispatch can never arm a later one. Without
    // a command (a read) nothing can be minted or dispatched as a mutation.
    final call = _ParentCall(_invocation!, _intent, command);
    try {
      final result = await runZoned(action,
          zoneValues: {_parentInvocationKey: _invocation!, _parentCallKey: call});
      _requireCurrent(); return result;
    } catch (error) {
      // A genuine awaited refusal stays eligible for negative acceptance.
      if (error is _ParentMutationRefusal && identical(error, call.minted)) rethrow;
      if (error is AccountFenceDeliveryCancellation) rethrow;
      if (error is _ParentMutationRefusal) {
        throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
      }
      _requireCurrent(); rethrow;
    } finally {
      call.active = false;
    }
  }

  Future<void> _prepare(PlanningOutboxItem item, {required bool off}) async {
    if (item.operationId == null || !_operationId.hasMatch(item.operationId!)) {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
    }
    final current = _invocation!;
    _intent = off ? await current.authority.captureParentSettingsOffIntent(current.handle, _db,
        rowId: item.id, entityId: item.entityId, opSeq: item.opSeq, operationId: item.operationId!)
        : await current.authority.captureParentIntent(current.handle, _db,
        rowId: item.id, entityType: item.entityType, entityId: item.entityId,
        opSeq: item.opSeq, operationId: item.operationId!);
    _requireCurrent();
    if (_intent == null) throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
  }

  Future<bool> _retryCurrent(PlanningOutboxItem item, String uid, {required bool off}) async {
    _requireCurrent();
    if (!_isEnabled(item.entityType)) return false;
    final liveUid = await _getAuthUserId(); _requireCurrent();
    if (liveUid != uid) return false;
    if (!off) {
      final allowed = item.entityType == PlanningOutboxQueue.settingsEntityType
          ? await _mayEgressProfile() : await _mayEgress();
      _requireCurrent();
      if (!allowed) return false;
    }
    final current = await _local(() => _queue.accountFenceCurrent(item));
    _requireCurrent(); return current;
  }

  /// Accepts ONLY a refusal minted at an awaited concrete mutation, using the
  /// invocation and intent captured when that mutation was dispatched.
  Future<Never> _deny(PlanningOutboxItem item, _ParentMutationRefusal refusal) async {
    final current = _invocation;
    final intent = refusal.intent;
    final state = decodeParentAccountDenial(refusal.raw);
    if (refusal.used || current == null || !identical(refusal.invocation, current) ||
        intent == null || !identical(intent, _intent) || state == null) {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
    }
    refusal.used = true;
    final result = await current.authority.acceptParentDenial(current.handle, _db,
        intent, state,
        park: (ticket) => _queue.parkParentDenial(item, state, ticket));
    throw PlanningDeliveryStopped(PlanningDeliveryStopReason.denial,
        accepted: result.accepted, parked: result.parked, complete: result.complete);
  }

  Future<PlanningPushResult> _pushBound() async {
    final userId = await _getAuthUserId();
    _requireCurrent();
    if (userId == null) return const PlanningPushResult();
    if (userId != _invocation!.authority.ownerUid(_invocation!.handle)) {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
    }

    // WP-5: legacy push or revision CAS; unprovable capability = nothing sent.
    _plan = _casGate == null ? const CasPlan(CasMode.legacy) : await _casGate.planForPlanningParent(userId, authority: _invocation!.authority,
        handle: _invocation!.handle, database: _db);
    _requireCurrent();
    if (_plan.mode == CasMode.stopped) return const PlanningPushResult();
    var epochStale = false;

    // D-7: the AuthSessionValid broadcast has no replay, so a cold start can miss
    // it. A valid authenticated session at the start of a cycle re-arms rows
    // parked `auth_required` (cheap UPDATE; no attempt was ever consumed).
    if (outboxHasValidSession()) {
      await _local(() => _queue.reArmAuthParked(entityTypes: _entityTable.keys));
    }

    // MALI-026 (B8-2.10 §9): a verified exact transport re-arms the SAME
    // durable rows before this drain starts.
    if (_pushCapability() == ExactTransportCapability.verifiedExact) {
      await _local(() => _queue.reArmParked());
    }
    var pushed = 0;
    var conflicts = 0;
    var failed = 0;
    var abandoned = 0;
    var parked = 0;
    var fenceStopped = false;

    // Consent is read fresh, per egress class, before any row is touched. A
    // denied class leaves its rows pending: no network, no attempt consumed.
    final financialAllowed = await _mayEgress();
    _requireCurrent();
    final profileAllowed = await _mayEgressProfile();
    _requireCurrent();
    if (!financialAllowed || !profileAllowed) {
      _invocation!.phase.noteConsentBlocked(_health);
    }

    // A-2: unpark rows whose dependency resolved (settings bound / budget
    // category / card account), THEN enforce row ownership so a dependency row
    // recorded for another owner is parked again before anything is sent (G18).
    // Skipped entirely while BOTH egress classes are denied: with consent off
    // the outbox is left exactly as it is.
    if (financialAllowed || profileAllowed) {
      await _queue.resolveParentDependencies(_invocation!.authority, _invocation!.handle, _invocation!.phase);
      _requireCurrent();
      final verified = await _queue.ownershipVerified(userId);
      _requireCurrent();
      await _local(() => _queue.reconcileVerifiedOwnership(userId, verified));
    }

    for (final entityType in _entityTable.keys) {
      if (epochStale || fenceStopped) break;
      if (!_isEnabled(entityType)) continue;
      final isSettings = entityType == PlanningOutboxQueue.settingsEntityType;
      final allowed = isSettings ? profileAllowed : financialAllowed;
      if (!allowed && !isSettings) continue;
      final items = await _local(() => _queue.pendingItems(entityType: entityType));
      for (final item in items) {
        try {
          if (!allowed) {
            // The ONE deliberate exception: a consent REVOCATION must still
            // reach the server (user_settings is its consent authority).
            if (_consentOffPatch(item) == null) continue;
            if (item.payloadJson['consent_only'] != true &&
                await _serverIdForLocal('user_settings', item.entityId) == null) {
              continue; // Existing unbound full intent remains deferred.
            }
            await _prepare(item, off: true);
            if (item.payloadJson['consent_only'] != true) {
              await _fenceRetry.runItem(
                  isCurrent: () => _retryCurrent(item, userId, off: true),
                  body: () => _deliverRevocationOnly(item));
              continue;
            }
            // A pre-bind consent-only create carries no other column: send it
            // exactly as before.
          }
          if (allowed) await _prepare(item, off: false);
          final outcome = await _fenceRetry.runItem(
              isCurrent: () => _retryCurrent(item, userId, off: !allowed),
              body: () => _process(item, userId));
          switch (outcome) {
            case _PlanningPushOutcome.pushed:
              pushed++;
            case _PlanningPushOutcome.conflict:
              conflicts++;
            case _PlanningPushOutcome.abandoned:
              abandoned++;
            case _PlanningPushOutcome.deferred:
              // Edited while being examined: left pending for the next cycle.
              break;
            case _PlanningPushOutcome.parked:
              // Held durably; not sent, synced, failed, or retried.
              parked++;
              _invocation!.phase.noteCapabilityParked(_health);
          }
        } on CasEpochMismatch {
          // Stale epoch: nothing was written; stop the cycle (WP-7 rebootstraps).
          await _itemLocal(item, () => _queue.releaseInFlight(item.id));
          epochStale = true;
          break;
        } on AccountFenceRetryStopped {
          fenceStopped = true;
          break;
        } on AccountFenceDeliveryCancellation {
          rethrow;
        } on _ParentMutationRefusal catch (refusal) {
          await _deny(item, refusal);
        } catch (e) {
          // A raw QD (or a stray CAS proof) that was not minted at an awaited
          // concrete mutation is not mutation proof: stop, no hold/ACK/attempt.
          if (decodeParentAccountDenial(e) != null ||
              e is CasMutationAwaitDenial ||
              e is CasMutationObservationRejected) {
            throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
          }
          _requireCurrent();
          final fence = classifyOutboxError(e);
          if (fence == OutboxFailureClass.accountFenceContention ||
              fence == OutboxFailureClass.accountDeletionPending) {
            final held = await _local(() => _queue.recordAccountFenceFailure(item, fence,
                _fenceRetry.clock().add(_fenceRetry.cooldown)));
            _invocation!.phase.noteFailure(_health, e);
            if (fence == OutboxFailureClass.accountDeletionPending) {
              if (held) parked++; fenceStopped = true; break;
            }
            continue;
          }
          failed++;
          _invocation!.phase.noteFailure(_health, e);
          await _itemLocal(item, () => _queue.markFailed(
              item.id, e.toString(), classifyOutboxError(e)));
          if (kDebugMode) debugPrint('[PlanningPush] item error: $e');
        }
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[PlanningPush] done: pushed=$pushed conflicts=$conflicts '
        'failed=$failed abandoned=$abandoned',
      );
    }
    return PlanningPushResult(
      pushed: pushed,
      conflicts: conflicts,
      failed: failed,
      abandoned: abandoned,
      parked: parked,
    );
  }

  /// Consent is OFF and this settings row is a revocation whose payload is a
  /// full row (display name, phone, date of birth, ...). Only the consent-OFF
  /// columns may leave the device; the full row stays pending until consent
  /// returns. Needs a bound server row — an unbound singleton is covered by the
  /// separate consent-only create.
  Future<void> _deliverRevocationOnly(PlanningOutboxItem item) async {
    final intent = _intent!;
    if (!intent.isBoundOff) return;
    final key = '${item.id}:${item.opSeq}:${item.operationId}';
    if (_revocationDelivered.contains(key)) return;
    final response = await retryAccountFenceMutation(() => _remote(() =>
        _remoteSink.updateByServerId('user_settings', intent.offTarget!, intent.offPayload!),
        command: _ParentCommand.update('user_settings', intent.offTarget!, intent.offPayload!)));
    if (response == null) throw StateError('settings_consent_revocation_not_synced');
    _requireCurrent(); _revocationDelivered.add(key);
  }

  Future<_PlanningPushOutcome> _process(
    PlanningOutboxItem item,
    String userId,
  ) async {
    // MALI-026 (B8-2.10 §8 / B8-3 §30): money entities park on the relevant
    // capability. Budgets/goals need BOTH the exact decimal-string transport AND
    // the SERVER per-row currency column (0077), so they park unless BOTH are
    // verified (the weaker of the two) — never unpark on one alone. Everything
    // else parks on the exact decimal-string transport capability. Non-delete
    // writes only.
    final capability = _planningCurrencyEntityTypes.contains(item.entityType)
        ? weakerCapability(_planningCurrencyCapability(), _pushCapability())
        : _pushCapability();
    if (item.operation != PlanningSyncOperation.delete &&
        _moneyEntityTypes.contains(item.entityType) &&
        shouldParkExactMoneyWrite(
          cutoverState: _coordinator.state(),
          pushCapability: capability,
        )) {
      final parkedNow = await _local(() => _db.transaction(() async {
        if (!await _queue.parentHolderCurrent(item)) return false;
        return _queue.park(item.id, exactMoneyTransportUnverifiedReason,
            ifOpSeq: item.opSeq);
      }));
      return parkedNow
          ? _PlanningPushOutcome.parked
          : _PlanningPushOutcome.deferred;
    }

    final remoteTable = _entityTable[item.entityType];
    final localTable = _localTable[item.entityType];
    if (remoteTable == null || localTable == null) {
      await _itemLocal(item, () => _queue.markSuccess(item));
      return _PlanningPushOutcome.abandoned;
    }

    final cas = _plan.isCas;
    final isSettings = item.entityType == PlanningOutboxQueue.settingsEntityType;
    switch (item.operation) {
      case PlanningSyncOperation.create:
      case PlanningSyncOperation.update:
        if (cas && isSettings) {
          return _pushSettingsLww(item, userId, remoteTable, localTable);
        }
        return cas
            ? _casUpsert(item, userId, remoteTable, localTable)
            : _pushUpsert(item, userId, remoteTable, localTable);
      case PlanningSyncOperation.delete:
        // D1: categories tombstone through their own CAS RPC (0116), which
        // re-parents dependants like delete_user_category_safely does.
        return cas
            ? _casDelete(item, userId, remoteTable, localTable)
            : _pushDelete(item, userId, remoteTable, localTable);
    }
  }

  Future<_PlanningPushOutcome> _pushUpsert(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    final row = _intent!.isPrebindOff ? _intent!.offPayload!
        : _toServerRow(item.entityType, item.payloadJson, userId);
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    if (_intent!.isPrebindOff && serverId != null) {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
    }
    // Tokens of the row we are about to update. Normally the locally stored
    // base; after an idempotent create REPLAY they are the freshly fetched ones.
    int? expectedRevision = item.payloadJson['server_revision'] as int?;
    String? base = item.payloadJson['server_updated_at'] as String?;
    try {
      // CREATE (never synced): establish the server row.
      if (serverId == null) {
        Map<String, dynamic> response;
        try {
          response = await retryAccountFenceMutation(() => _remote(() => _remoteSink.upsert(remoteTable, row),
              command: _ParentCommand.upsert(remoteTable, row)));
        } on PostgrestException catch (e) {
          // A-3 (G7/G16): 23505 on a partial-index table is a REPLAY of a create
          // that already landed (the ack was lost) only if the row for this
          // (user_id, local_id) exists. Anything else is a different unique
          // constraint → rethrown and classified duplicate_business_key.
          if (e.code != '23505' ||
              !kPartialLocalIdIndexTables.contains(remoteTable)) {
            rethrow;
          }
          final existing = await _remote(() => _remoteSink.findByLocalId(
              remoteTable, userId, item.entityId));
          if (existing == null) rethrow;
          // Replay: the create landed. Continue as an UPDATE of that row, guarded
          // by the token we just fetched, so a newer local payload (edits folded
          // into the create row) is applied without clobbering a concurrent
          // server change.
          serverId = existing['id'] as String;
          expectedRevision = existing['revision'] as int?;
          base = existing['updated_at'] as String?;
          return await _guardedUpdate(item, serverId, remoteTable, localTable,
              row, expectedRevision, base);
        }
        // Audit NEW-H-3 — a pre-bind CONSENT-ONLY push delivers the revocation
        // and nothing else. It deliberately does NOT bind the local singleton:
        // attaching server_id here would lift the pre-bind guard and let the
        // next automatic full-row update clobber the user's real cloud settings
        // with this device's fresh defaults before the first pull merges them.
        // The row stays unbound; the genuine pull binds it and (for a local
        // revocation) preserves the OFF consent, re-queuing the merged update.
        if (item.payloadJson['consent_only'] == true) {
          await _itemLocal(item, () => _queue.markSuccess(item));
          return _PlanningPushOutcome.pushed;
        }
        await _attachServerId(localTable, item.entityId,
            response['id'] as String, response['updated_at'] as String?,
            serverRevision: response['revision'] as int?, item: item);
        return _PlanningPushOutcome.pushed;
      }

      return await _guardedUpdate(item, serverId, remoteTable, localTable, row,
          expectedRevision, base);
    } catch (e) {
      if (isTransportConflict(e)) {
        return _resolveUpsertConflict(item, serverId, remoteTable, localTable);
      }
      rethrow;
    }
  }

  /// UPDATE of a known server row — ALWAYS guarded, never a blind write.
  ///
  /// MALI-022 / 0068 — atomic compare-and-set on `revision` when the capability
  /// is on AND a base revision is known. Otherwise the guard is the server
  /// `updated_at`: the locally stored base token, or — A-3 (G17) — when there is
  /// none, the row's CURRENT `updated_at` fetched just now. The guard travels
  /// WITH the write (C-6), so a change landing between the fetch and the write
  /// yields zero rows = conflict. Semantics when no base is held: the local
  /// pending edit wins only if the server row is unchanged since that fetch;
  /// a zero-row result (changed or vanished) takes the conflict path and the
  /// local edit is kept, never discarded and never overwriting the server.
  Future<_PlanningPushOutcome> _guardedUpdate(
    PlanningOutboxItem item,
    String serverId,
    String remoteTable,
    String localTable,
    Map<String, dynamic> row,
    int? expectedRevision,
    String? base,
  ) async {
    base ??= await _remote(() => _remoteSink.fetchServerUpdatedAt(remoteTable, serverId));
    if (base == null) {
      // The server row is gone: nothing to guard against → conflict.
      return await _resolveUpsertConflict(
          item, serverId, remoteTable, localTable);
    }
    final expectedBase = base;
    final response = await retryAccountFenceMutation(() => _remote(() => _remoteSink.guardedUpdateByServerId(
        remoteTable, serverId, expectedBase, row),
        command: _ParentCommand.guardedUpdate(remoteTable, serverId, expectedBase, row)));
    if (response == null) {
      return await _resolveUpsertConflict(
          item, serverId, remoteTable, localTable);
    }
    await _attachServerId(localTable, item.entityId, response['id'] as String,
        response['updated_at'] as String?,
        serverRevision: response['revision'] as int?, item: item);
    return _PlanningPushOutcome.pushed;
  }

  /// Settings normally keep the deterministic prefer-remote policy. Consent is
  /// the security exception: after a stale full-row write loses its CAS, apply
  /// only the OFF fields as a narrow update. Concurrent non-consent edits are
  /// therefore untouched, while the outbox is consumed only after the server
  /// acknowledges the revocation. A failed acknowledgement throws, retaining
  /// the durable row for normal retry/backoff instead of silently resolving it.
  Future<_PlanningPushOutcome> _resolveUpsertConflict(
    PlanningOutboxItem item,
    String? serverId,
    String remoteTable,
    String localTable,
  ) async {
    final consentOff = _consentOffPatch(item);
    if (consentOff != null && serverId != null) {
      final response =
          await retryAccountFenceMutation(() => _remote(() => _remoteSink.updateByServerId(remoteTable, serverId, consentOff),
              command: _ParentCommand.update(remoteTable, serverId, consentOff)));
      if (response == null) {
        throw StateError('settings_consent_revocation_not_synced');
      }
      await _attachServerId(
        localTable,
        item.entityId,
        response['id'] as String,
        response['updated_at'] as String?,
        serverRevision: response['revision'] as int?,
        item: item,
      );
      return _PlanningPushOutcome.pushed;
    }

    await _conflictAndAck(localTable, item);
    return _PlanningPushOutcome.conflict;
  }

  Map<String, dynamic>? _consentOffPatch(PlanningOutboxItem item) {
    if (item.entityType != PlanningOutboxQueue.settingsEntityType) return null;
    final payload = item.payloadJson;
    final aiOff = payload['ai_consent_granted'] == false;
    final cloudOff = payload['cloud_processing_enabled'] == false;
    if (!aiOff && !cloudOff) return null;
    return <String, dynamic>{
      if (aiOff || cloudOff) 'ai_consent_granted': false,
      if (cloudOff) 'cloud_processing_enabled': false,
    };
  }

  Future<_PlanningPushOutcome> _pushDelete(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    serverId ??= (await _remote(() => _remoteSink.findByLocalId(
      remoteTable,
      userId,
      item.entityId,
    )))?['id'] as String?;
    if (serverId == null) {
      // Never reached the server — nothing to tombstone.
      await _markSynced(localTable, item.entityId, null, item: item);
      return _PlanningPushOutcome.pushed;
    }

    try {
      // MALI-022 / 0068 (Phase-9K): the tombstone is GUARDED, never an
      // unconditional id-only overwrite. CAS on the base revision when we have
      // one; otherwise an optimistic updated_at compare. A zero-row result is
      // classified (already-deleted / advanced / absent) — a stale delete can
      // never clobber a newer accepted update.
      final base = item.payloadJson['server_updated_at'] as String?;
      final target = serverId;
      final ack =
          await _remote(() => _remoteSink.guardedTombstone(remoteTable, target, base),
              command: _ParentCommand.tombstone(remoteTable, target, base));
      if (ack != null) {
        await _markSynced(localTable, item.entityId, serverId, item: item);
        return _PlanningPushOutcome.pushed;
      }
      return await _resolveDeleteConflict(remoteTable, serverId, localTable, item);
    } catch (e) {
      if (isTransportConflict(e)) {
        await _conflictAndAck(localTable, item);
        return _PlanningPushOutcome.conflict;
      }
      rethrow;
    }
  }

  // ── WP-5: revision CAS (capability `revision_cas`) ───────────────────────

  Future<_PlanningPushOutcome> _casUpsert(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    final row = _toServerRow(item.entityType, item.payloadJson, userId);
    final serverId = await _serverIdForLocal(localTable, item.entityId);
    var d = serverId == null
        ? await _cas.create(
            table: remoteTable,
            epoch: _plan.epoch!,
            opId: item.operationId!,
            row: row)
        : await _cas.update(
            table: remoteTable,
            epoch: _plan.epoch!,
            opId: item.operationId!,
            priorOpIds: item.priorOpIds,
            serverId: serverId,
            baseRevision: item.baseRevision ??
                (item.payloadJson['server_revision'] as int?),
            baseUpdatedAt: item.payloadJson['server_updated_at'] as String?,
            patch: row,
          );
    var created = serverId == null;
    if (d.kind == CasDecisionKind.missing) {
      // No such cloud row: create it again by identity (never un-deletes).
      d = await _cas.create(
          table: remoteTable,
          epoch: _plan.epoch!,
          opId: item.operationId!,
          row: row);
      created = true;
    }
    if (d.kind == CasDecisionKind.acked) {
      await _attachServerId(
          localTable, item.entityId, d.row!['id'] as String,
          d.row!['updated_at'] as String?,
          serverRevision: (d.row!['revision'] as num?)?.toInt(), item: item);
      return _PlanningPushOutcome.pushed;
    }
    return _casConflict(
        item,
        d,
        d.cloudTombstoned
            ? SyncConflictKind.tombstone
            : created
                ? SyncConflictKind.create
                : SyncConflictKind.update);
  }

  Future<_PlanningPushOutcome> _casDelete(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    var serverId = await _serverIdForLocal(localTable, item.entityId);
    serverId ??= (await _remote(() => _remoteSink.findByLocalId(
      remoteTable,
      userId,
      item.entityId,
    )))?['id'] as String?;
    if (serverId == null) {
      await _markSynced(localTable, item.entityId, null, item: item);
      return _PlanningPushOutcome.pushed;
    }
    final d = await _cas.tombstone(
      table: remoteTable,
      epoch: _plan.epoch!,
      opId: item.operationId!,
      priorOpIds: item.priorOpIds,
      serverId: serverId,
      baseRevision:
          item.baseRevision ?? (item.payloadJson['server_revision'] as int?),
      baseUpdatedAt: item.payloadJson['server_updated_at'] as String?,
    );
    if (d.kind == CasDecisionKind.acked || d.kind == CasDecisionKind.gone) {
      await _markSynced(localTable, item.entityId, serverId, item: item);
      return _PlanningPushOutcome.pushed;
    }
    return _casConflict(item, d, SyncConflictKind.delete);
  }

  /// Stored durably BEFORE the outbox op is consumed, in one local transaction.
  Future<_PlanningPushOutcome> _casConflict(
    PlanningOutboxItem item,
    CasDecision d,
    SyncConflictKind kind,
  ) async {
    await _itemLocal(item, () async {
      await _conflicts.flag(
        entityType: item.entityType,
        localId: item.entityId,
        kind: kind,
        serverId: d.row?['id'] as String?,
        theirs: d.row,
        theirsRevision: (d.row?['revision'] as num?)?.toInt(),
        operationId: item.operationId,
      );
      await _queue.markSuccess(item);
    });
    return _PlanningPushOutcome.conflict;
  }

  /// Settings are last-writer-wins PER FIELD in server order, never a conflict:
  /// only the fields this device changed are sent, and the consent columns only
  /// when the user explicitly changed consent on this device (`consent` in
  /// `changed_fields`). A row not yet bound to the cloud keeps the legacy
  /// create (merge-upsert) path.
  Future<_PlanningPushOutcome> _pushSettingsLww(
    PlanningOutboxItem item,
    String userId,
    String remoteTable,
    String localTable,
  ) async {
    final serverId = await _serverIdForLocal(localTable, item.entityId);
    if (serverId == null || item.payloadJson['consent_only'] == true) {
      return _pushUpsert(item, userId, remoteTable, localTable);
    }
    final changed =
        ((item.payloadJson['changed_fields'] as List?) ?? const []).cast<String>();
    final row = _toServerRow(item.entityType, item.payloadJson, userId)
      ..remove('user_id')
      ..remove('local_id');
    const consentKeys = {
      'ai_consent_granted',
      'cloud_processing_enabled',
      'consent_version',
    };
    final patch = <String, dynamic>{
      for (final e in row.entries)
        if (consentKeys.contains(e.key)
            ? changed.contains('consent')
            : (changed.isEmpty || changed.contains(e.key)))
          e.key: e.value,
    };
    if (patch.isEmpty) {
      await _markSynced(localTable, item.entityId, serverId, item: item);
      return _PlanningPushOutcome.pushed;
    }
    final response = await retryAccountFenceMutation(() => _remote(() => _remoteSink.updateByServerId(remoteTable, serverId, patch),
        command: _ParentCommand.update(remoteTable, serverId, patch)));
    if (response == null) throw StateError('settings_row_missing');
    await _attachServerId(localTable, item.entityId, serverId,
        response['updated_at'] as String?,
        serverRevision: response['revision'] as int?, item: item);
    return _PlanningPushOutcome.pushed;
  }

  /// A guarded tombstone matched zero rows. Classify it (Phase-9K §5):
  ///   A. already tombstoned  → the delete already converged → idempotent success
  ///   B. still live, advanced → a newer accepted update → conflict, do NOT delete
  ///   C. absent               → fail-closed → conflict (surface, never silent)
  /// On B/C the local (soft-deleted) row stays flagged 'conflict', so the delete
  /// intent is recoverable via keep-mine / keep-theirs and the server is intact.
  Future<_PlanningPushOutcome> _resolveDeleteConflict(
    String remoteTable,
    String serverId,
    String localTable,
    PlanningOutboxItem item,
  ) async {
    final state = await _remote(() => _remoteSink.fetchRowState(remoteTable, serverId));
    if (state != null && state['deleted_at'] != null) {
      await _markSynced(localTable, item.entityId, serverId, item: item); // A
      return _PlanningPushOutcome.pushed;
    }
    await _conflictAndAck(localTable, item); // B (live) or C (absent)
    return _PlanningPushOutcome.conflict;
  }

  Future<String?> _serverIdForLocal(String table, String localId) async {
    final row = await _local(() => _db
        .customSelect(
          'SELECT server_id FROM $table WHERE id = ${sqlString(localId)} LIMIT 1;',
        )
        .getSingleOrNull());
    return row?.readNullable<String>('server_id');
  }

  /// A-2 (G3): ACK [item] and persist the server row identity in ONE local
  /// transaction. The entity is marked `synced` only when no outbox row remains
  /// for it (an edit folded in while the push was in flight keeps it pending);
  /// its server id / version are persisted regardless, so the next push is an
  /// update of the same server row.
  Future<void> _attachServerId(
    String table,
    String localId,
    String serverId,
    String? serverUpdatedAt, {
    int? serverRevision,
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _itemLocal(item, () async {
      await _queue.acknowledge(
        item,
        serverUpdatedAt: serverUpdatedAt,
        serverRevision: serverRevision,
      );
      await _db.customStatement('''
        UPDATE $table
        SET server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(serverUpdatedAt)},
            ${serverRevision != null ? 'server_revision = $serverRevision,' : ''}
            -- D-1: a 'conflict' entity is never flipped to 'synced' implicitly.
            sync_status = CASE WHEN sync_status = 'conflict'
                OR ${_outboxRowExists(item.entityType, localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  /// SQL predicate: an outbox row still exists for this entity.
  static String _outboxRowExists(String entityType, String localId) =>
      'EXISTS (SELECT 1 FROM planning_sync_outbox '
      'WHERE entity_type = ${sqlString(entityType)} '
      'AND entity_id = ${sqlString(localId)})';

  /// A-2 (G15): a tombstone/idempotent-delete ACK settles the entity (guarded
  /// the same way: never while another edit is still queued for it).
  Future<void> _markSynced(
    String table,
    String localId,
    String? serverId, {
    required PlanningOutboxItem item,
  }) {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _itemLocal(item, () async {
      await _queue.acknowledge(item);
      await _db.customStatement('''
        UPDATE $table
        SET ${serverId == null ? '' : 'server_id = ${sqlString(serverId)},'}
            synced_at = ${sqlString(now)},
            -- D-1: a 'conflict' entity is never flipped to 'synced' implicitly.
            sync_status = CASE WHEN sync_status = 'conflict'
                OR ${_outboxRowExists(item.entityType, localId)}
              THEN sync_status ELSE 'synced' END
        WHERE id = ${sqlString(localId)};
      ''');
    });
  }

  Future<void> _conflictAndAck(String table, PlanningOutboxItem item) => _itemLocal(item, () async {
    await _markConflict(table, item.entityId);
    await _queue.markSuccess(item);
  });

  Future<void> _markConflict(String table, String localId) async {
    await _db.customStatement('''
      UPDATE $table
      SET sync_status = 'conflict'
      WHERE id = ${sqlString(localId)};
    ''');
  }

  Map<String, dynamic> _toServerRow(
    String entityType,
    Map<String, dynamic> payload,
    String userId,
  ) {
    return switch (entityType) {
      PlanningOutboxQueue.budgetsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'category_id': payload['category_id'],
          'amount': payload['amount'],
          // §7/§30: canonical push carries the row currency (server column 0077).
          // Legacy payloads omit it, so it is only sent when present.
          if (payload['currency'] != null) 'currency': payload['currency'],
          if (payload['alert_threshold_percent'] != null)
            'alert_threshold_percent': payload['alert_threshold_percent'],
          'period': payload['period'],
          'start_date': payload['start_date'],
          'is_active': payload['is_active'] == true,
          'last_notified_spent_amount': payload['last_notified_spent_amount'],
          'last_notified_period_start': payload['last_notified_period_start'],
          'show_on_header': payload['show_on_header'] == true,
        },
      PlanningOutboxQueue.subscriptionsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'merchant_id': payload['merchant_id'],
          'name': payload['name'],
          'amount': payload['amount'],
          'currency': payload['currency'],
          'type': payload['type'],
          'frequency': payload['frequency'],
          'next_due_date': payload['next_due_date'],
          'reminder_on': payload['reminder_on'] == true,
          'is_confirmed': payload['is_confirmed'] == true,
          'custom_interval_days': payload['custom_interval_days'],
          'note': payload['note'],
          'status': payload['status'],
          'total_installments': payload['total_installments'],
          'paid_count': payload['paid_count'],
          'manual_paid_amount': payload['manual_paid_amount'],
          'total_purchase_amount': payload['total_purchase_amount'],
          'lender_name': payload['lender_name'],
          'interest_rate': payload['interest_rate'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.goalsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'name': payload['name'],
          'target_amount': payload['target_amount'],
          'saved_amount': payload['saved_amount'],
          // §7/§30: canonical push carries the row currency (server column 0077).
          if (payload['currency'] != null) 'currency': payload['currency'],
          'deadline': payload['deadline'],
          'vault_skin': payload['vault_skin'],
          'status': payload['status'],
          'auto_save_amount': payload['auto_save_amount'],
          'auto_save_period': payload['auto_save_period'],
          'auto_save_last_run': payload['auto_save_last_run'],
          'last_notified_saved_amount': payload['last_notified_saved_amount'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.plansEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'name': payload['name'],
          'budget_amount': payload['budget_amount'],
          'currency': payload['currency'],
          'start_date': payload['start_date'],
          'end_date': payload['end_date'],
          'local_account_ids': payload['local_account_ids'] ?? const [],
          'card_last4s': payload['card_last4s'] ?? const [],
          'status': payload['status'],
          'icon': payload['icon'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.cardsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'local_account_id': payload['local_account_id'],
          'nickname': payload['nickname'],
          'last4': payload['last4'],
          'network': payload['network'],
          'source': payload['source'],
          // حقول التصميم لا تُرسَل حتى نشر ترقية 0064 (العمودان غير موجودين
          // على الخادم بعد) — انظر kUserCardsCloudV2.
          if (kUserCardsCloudV2) 'color_theme': payload['color_theme'],
          if (kUserCardsCloudV2) 'accent_hex': payload['accent_hex'],
          'created_at': payload['created_at'],
        },
      PlanningOutboxQueue.categoriesEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'key': payload['key'],
          'name_ar': payload['name_ar'],
          'icon': payload['icon'],
          'color': payload['color'],
          'is_income': payload['is_income'] == true,
        },
      // تفضيلات المستخدم — أعمدة سحابية فقط (لا مفتاح تشفير/أفاتار/ملف شخصي).
      //
      // Audit NEW-H-3: a consent-only payload (pre-bind revocation) must send
      // ONLY the consent authority columns. Every additional key here would be
      // written by the merge-upsert — on a fresh/wiped device those values are
      // reseeded defaults/nulls and would destroy the user's real cloud
      // settings and profile. user_id is the AUTHENTICATED uid (never caller
      // input), so RLS scope is preserved.
      PlanningOutboxQueue.settingsEntityType when payload['consent_only'] == true => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'ai_consent_granted': payload['ai_consent_granted'] == true,
          'cloud_processing_enabled':
              payload['cloud_processing_enabled'] == true,
          if (payload['consent_version'] is int)
            'consent_version': payload['consent_version'],
        },
      PlanningOutboxQueue.settingsEntityType => {
          'user_id': userId,
          'local_id': payload['local_id'],
          'display_name': payload['display_name'],
          'phone_number': payload['phone_number'],
          'date_of_birth': payload['date_of_birth'],
          'theme': payload['theme'],
          'currency': payload['currency'],
          'language': payload['language'],
          'country': payload['country'],
          'input_method': payload['input_method'],
          'notifications_json': payload['notifications_json'],
          'privacy_mode_enabled': payload['privacy_mode_enabled'] == true,
          // These booleans authorize the JWT cloud/AI endpoints. The outbox
          // already normalizes AI OFF when the cloud master gate is OFF.
          // CREATE carries an explicit local choice too; this leaves the server
          // column defaults unchanged for rows created without client values.
          if (payload.containsKey('ai_consent_granted'))
            'ai_consent_granted': payload['ai_consent_granted'] == true,
          if (payload.containsKey('cloud_processing_enabled'))
            'cloud_processing_enabled':
                payload['cloud_processing_enabled'] == true,
          if (payload['consent_version'] is int)
            'consent_version': payload['consent_version'],
        },
      _ => throw ArgumentError('Unsupported planning entity: $entityType'),
    };
  }
}

enum _PlanningPushOutcome { pushed, conflict, abandoned, parked, deferred }

final Object _parentInvocationKey = Object();
final Object _parentCallKey = Object();

/// The one mutation a `_remote` call is allowed to perform: immutable, built by
/// the parent itself (a custom delegate can never select or rewrite it). A read
/// carries none, so a real mutation reached from a read is rejected.
class _ParentCommand {
  _ParentCommand._(this.method, this.table, this.target, this.guard,
      Map<String, dynamic> body, this.deletedAt)
      : body = _freezeWire(body) as Map<String, Object?>;
  factory _ParentCommand.upsert(String table, Map<String, dynamic> row) =>
      _ParentCommand._('upsert', table, null, null, row, null);
  factory _ParentCommand.update(
          String table, String serverId, Map<String, dynamic> row) =>
      _ParentCommand._('updateByServerId', table, serverId, null, row, null);
  factory _ParentCommand.guardedUpdate(String table, String serverId,
          String expectedUpdatedAt, Map<String, dynamic> row) =>
      _ParentCommand._(
          'guardedUpdate', table, serverId, expectedUpdatedAt, row, null);
  factory _ParentCommand.tombstone(
      String table, String serverId, String? expectedUpdatedAt) {
    final deletedAt = DateTime.now().toUtc().toIso8601String();
    return _ParentCommand._('guardedTombstone', table, serverId,
        expectedUpdatedAt, <String, dynamic>{'deleted_at': deletedAt}, deletedAt);
  }
  final String method;
  final String table;
  final String? target;
  final String? guard;
  final Map<String, Object?> body;
  final String? deletedAt;

  /// The tombstone stamp captured once with the command, released only to the
  /// exact matching method/table/target/guard.
  String? tombstoneStamp(String table, String target, String? guard) =>
      method == 'guardedTombstone' &&
              table == this.table &&
              target == this.target &&
              guard == this.guard
          ? deletedAt
          : null;
}

/// What the concrete sink is about to dispatch, compared with the command.
class _SinkMutation {
  const _SinkMutation(this.method, this.table, this.target, this.guard, this.body);
  final String method;
  final String table;
  final String? target;
  final String? guard;
  final Map<String, dynamic> body;
}

/// One `_remote` call: read/non-minting unless it carries a [command]. Created
/// fresh per call and deactivated when the call ends. It permits one dispatch at
/// a time; the next dispatch is allowed only after an awaited 55P03.
class _ParentCall {
  _ParentCall(this.invocation, this.intent, this.command);
  final _ParentInvocation invocation;
  final AccountFenceParentIntent? intent;
  final _ParentCommand? command;
  bool active = true;
  bool open = false;
  _ParentMutationRefusal? minted;

  Map<String, dynamic> begin(_SinkMutation actual) {
    const stop = PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
    final expected = command;
    if (!active || open || expected == null) throw stop;
    open = true;
    final Map<String, Object?> frozen;
    try {
      frozen = _freezeWire(actual.body) as Map<String, Object?>;
    } on ArgumentError {
      throw stop;
    }
    if (actual.method != expected.method ||
        actual.table != expected.table ||
        actual.target != expected.target ||
        actual.guard != expected.guard ||
        !_wireEquals(expected.body, frozen)) {
      throw stop;
    }
    invocation.requireCurrent();
    return frozen;
  }
}

Object? _freezeWire(Object? value, [List<Object> path = const []]) {
  if (value == null || value is bool || value is String || value is int) {
    return value;
  }
  if (value is double) {
    if (!value.isFinite) throw ArgumentError('non-finite number');
    return value;
  }
  if (value is Map || value is List) {
    if (path.any((ancestor) => identical(ancestor, value))) {
      throw ArgumentError('cyclic value');
    }
    final next = <Object>[...path, value];
    if (value is Map) {
      final out = <String, Object?>{};
      for (final entry in value.entries) {
        final key = entry.key;
        if (key is! String) throw ArgumentError('non-string key');
        out[key] = _freezeWire(entry.value, next);
      }
      return Map<String, Object?>.unmodifiable(out);
    }
    return List<Object?>.unmodifiable(
        [for (final item in value as List) _freezeWire(item, next)]);
  }
  throw ArgumentError('unsupported value');
}

bool _wireEquals(Object? a, Object? b) {
  if (a == null || b == null) return a == null && b == null;
  if (a is bool || a is String) return b.runtimeType == a.runtimeType && a == b;
  if (a is int) return b is int && a == b;
  if (a is double) return b is double && a == b;
  if (a is Map) {
    if (b is! Map || a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_wireEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List) {
    if (b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_wireEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return false;
}

/// A structured QD refusal observed by awaiting a concrete SDK mutation future,
/// with the invocation and intent captured when that mutation was dispatched.
class _ParentMutationRefusal implements Exception {
  _ParentMutationRefusal(this.invocation, this.intent, this.raw);
  final _ParentInvocation invocation;
  final AccountFenceParentIntent? intent;
  final PostgrestException raw;
  bool used = false;
}

/// The SDK future is built by a synchronous factory OUTSIDE the tagging catch,
/// only after the dispatch matched the call's command; only awaiting that exact
/// future can mint a refusal or release the attempt (on 55P03). With no call
/// context (a plain sink use) the original behavior is unchanged.
Future<T> _tagMutation<T>(_SinkMutation actual,
    Future<T> Function(Map<String, dynamic> body) factory) async {
  final call = Zone.current[_parentCallKey] as _ParentCall?;
  final body = call == null ? actual.body : call.begin(actual);
  final Future<T> sdk = factory(body);
  try {
    return await sdk;
  } on PostgrestException catch (error) {
    if (call != null) {
      if (call.active && decodeParentAccountDenial(error) != null) {
        throw call.minted = _ParentMutationRefusal(call.invocation, call.intent, error);
      }
      if (error.code == '55P03') call.open = false;
    }
    rethrow;
  }
}

class _ParentInvocation implements SyncPhaseLifecycle {
  _ParentInvocation(this.authority, this.handle, this.database, this.phase, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding phase;
  final SyncPhaseBinding? inherited;
  void requireCurrent() {
    if (!isCurrent) throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
  }
  String get ownerUid => authority.ownerUid(handle);
  @override
  bool get isCurrent => authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent);
  @override
  Future<T> runLocal<T>(Future<T> Function() action) =>
      authority.runCurrentLocal(handle, database, action);
}


/// Guard the actual underlying method after the retry predicate's final await.
/// Each semantic mutation gets a fresh observation; only a proof that escapes
/// that observation's own run becomes a refusal for the captured invocation and
/// intent. A raw QD from a custom delegate or a read is never mutation proof.
class _ParentCasRemote implements CasRemote {
  _ParentCasRemote(this.delegate, this.invocation, this.intent);
  final CasRemote delegate;
  final _ParentInvocation invocation;
  final AccountFenceParentIntent? intent;

  void _check() {
    if (!invocation.isCurrent) {
      throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.stale);
    }
  }

  Future<T> _send<T>(Future<T> Function() send) async {
    _check();
    try {
      final result = await send();
      _check();
      return result;
    } catch (_) {
      _check();
      rethrow;
    }
  }

  Future<CasResult> _mutate(CasMutationObservation observation,
      Future<CasResult> Function() send) async {
    _check();
    try {
      final result = await observation.run(send, requireCurrent: invocation.requireCurrent);
      _check();
      return result;
    } catch (error) {
      final raw = observation.takeDenial(error);
      if (raw != null) throw _ParentMutationRefusal(invocation, intent, raw);
      if (error is AccountFenceDeliveryCancellation) rethrow;
      _check();
      if (error is CasMutationAwaitDenial ||
          error is CasMutationObservationRejected ||
          decodeParentAccountDenial(error) != null) {
        throw const PlanningDeliveryStopped(PlanningDeliveryStopReason.provenance);
      }
      rethrow;
    }
  }

  @override
  Future<CasResult> insertIfAbsent({required String table, required String epoch,
      required String opId, required Map<String, dynamic> row}) async =>
      _mutate(CasMutationObservation.insertIfAbsent(table: table, epoch: epoch, opId: opId, row: row),
          () => delegate.insertIfAbsent(table: table, epoch: epoch, opId: opId, row: row));

  @override
  Future<CasResult> casUpdate({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision,
      required Map<String, dynamic> patch}) async => _mutate(
      CasMutationObservation.update(table: table, epoch: epoch, opId: opId,
          serverId: serverId, expectedRevision: expectedRevision, patch: patch),
      () => delegate.casUpdate(
          table: table, epoch: epoch, opId: opId, serverId: serverId,
          expectedRevision: expectedRevision, patch: patch));

  @override
  Future<CasResult> casTombstone({required String table, required String epoch,
      required String opId, required String serverId, required int expectedRevision}) async =>
      _mutate(CasMutationObservation.tombstone(table: table, epoch: epoch, opId: opId,
          serverId: serverId, expectedRevision: expectedRevision),
          () => delegate.casTombstone(table: table, epoch: epoch, opId: opId,
              serverId: serverId, expectedRevision: expectedRevision));

  @override
  Future<Map<String, dynamic>?> fetchRow(String table, String serverId) =>
      _send(() => delegate.fetchRow(table, serverId));
}
