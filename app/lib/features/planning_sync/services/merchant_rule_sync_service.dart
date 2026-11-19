import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/admission_authority.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/sync_health.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/merchant_rule_history.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_merchant_category_repository.dart';
import '../../../data/sync/sync_cursor.dart';
import 'planning_outbox_queue.dart';

/// The user's own learned category rules ("Remember for this merchant") in the
/// cloud (`user_merchant_rules`, migration 20261116180000).
///
/// Plugs into the planning sync framework:
///  * intent lives in the PLANNING OUTBOX (entity `merchant_rule`, keyed by the
///    normalised merchant key), written by DriftMerchantCategoryRepository in
///    the same local transaction as the rule — owner-stamped, coalescing
///    (delete + Undo folds into one upsert), counted by the unsynced inventory;
///  * delivery runs inside PlanningSyncEngine right after the planning pull, so
///    custom categories are already restored when rules are applied;
///  * consent: [EgressClass.financialSync], read fresh per run, default DENY;
///    the server must also advertise `merchant_rules_sync`.
///
/// Conflict policy: ONE precedence rule ([ruleVersionSupersedes], shared with
/// restore): per merchant, the more recent of "rule" and "removal" wins, the
/// device on a tie. The cloud's time is the row's server-owned `updated_at`
/// (so the keyset pull never skips a row); after a push or a pull the device
/// copy carries that same time. A pull never overwrites a merchant that still
/// has a local outbox row (that edit is pushed and wins). When the device's
/// state is the newer one and differs from the cloud row, the pull queues it,
/// so a removal or a newer rule on the device reaches the cloud instead of
/// being undone by an older cloud row. One exception: a newer cloud rule
/// against the user's "Leave out" of a restored rule is not applied but goes
/// back on the list for the user to choose (merchant_rule_restore_choices).
///
/// The one-time backfill (rules the cloud has never seen) runs only after a
/// pull that COMPLETED: pushing first could overwrite a removal another device
/// made and this device has not read yet.
///
/// A pulled rule whose category key is unknown here (a custom category not
/// restored yet, or deleted) is NOT dropped: it is parked in
/// `parked_child_rows` (`missing_parent`) and re-applied on every later run
/// once the category exists.
class MerchantRuleSyncResult {
  const MerchantRuleSyncResult({
    this.pushed = 0,
    this.failed = 0,
    this.applied = 0,
    this.removed = 0,
    this.parked = 0,
  });

  final int pushed;
  final int failed;
  final int applied;
  final int removed;

  /// Pulled rules still waiting for their category after this run.
  final int parked;
}

/// Injectable remote; the real one talks to PostgREST, tests use a fake.
abstract interface class MerchantRuleRemote {
  /// Upsert one rule keyed by (user_id, merchant_key); returns the stored row.
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row);

  /// Keyset page after [after], ordered by (updated_at, id) ascending.
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });
}

class SupabaseMerchantRuleRemote implements MerchantRuleRemote {
  const SupabaseMerchantRuleRemote();

  static const _table = 'user_merchant_rules';
  static const _columns = 'id,merchant_key,category_key,updated_at,deleted_at';

  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) async {
    final rows = await Supabase.instance.client
        .from(_table)
        .upsert(row, onConflict: 'user_id,merchant_key')
        .select(_columns);
    return (rows as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = Supabase.instance.client.from(_table).select(_columns);
    final filtered = after.id.isEmpty
        ? query
        : query.or(
            'updated_at.gt.${after.updatedAt},'
            'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})',
          );
    final rows = await filtered
        .order('updated_at', ascending: true)
        .order('id', ascending: true)
        .limit(limit);
    return (rows as List).cast<Map<String, dynamic>>();
  }
}

class MerchantRuleSyncService {
  MerchantRuleSyncService({
    required AppDatabase db,
    required PlanningOutboxQueue queue,
    MerchantRuleRemote? remote,
    Future<String?> Function()? getAuthUserId,

    /// Cloud consent, asked fresh per run. Defaults to DENY.
    Future<bool> Function()? mayEgress,

    /// The `merchant_rules_sync` server capability. Defaults to NOT ready.
    Future<bool> Function()? serverReady,

    /// Keeps the on-device suggestion model in step with rules that arrived
    /// from the cloud (they are the user's own confirmations).
    void Function(String merchantKey, String categoryKey)? onRuleApplied,
    void Function(String merchantKey)? onRuleRemoved,
    SyncHealth? health,
    int pageSize = 200,
  })  : _db = db,
        _queue = queue,
        _remote = remote ?? const SupabaseMerchantRuleRemote(),
        _getAuthUserId = getAuthUserId ?? _defaultUid,
        _mayEgress = mayEgress ?? _deny,
        _serverReady = serverReady ?? _deny,
        _onRuleApplied = onRuleApplied,
        _onRuleRemoved = onRuleRemoved,
        _health = health,
        _pageSize = pageSize;

  static Future<bool> _deny() async => false;
  static Future<String?> _defaultUid() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static const entityType = PlanningOutboxQueue.merchantRulesEntityType;
  static const cursorKey = 'merchant_rules';
  static const parkTable = 'user_merchant_rules';
  static String backfillKey(String uid) => 'merchant_rules_backfill:$uid';

  final AppDatabase _db;
  final PlanningOutboxQueue _queue;
  final MerchantRuleRemote _remote;
  final Future<String?> Function() _getAuthUserId;
  final Future<bool> Function() _mayEgress;
  final Future<bool> Function() _serverReady;
  final void Function(String, String)? _onRuleApplied;
  final void Function(String)? _onRuleRemoved;
  final SyncHealth? _health;
  final int _pageSize;
  late final _rules = DriftMerchantCategoryRepository(_db); // never enqueues
  bool _busy = false;

  /// Push, then pull, then the one-time backfill.
  Future<MerchantRuleSyncResult> sync() => syncWithPhase(SyncPhaseBinding());

  Future<MerchantRuleSyncResult> syncWithPhase(SyncPhaseBinding phase) =>
      _run(phase, pull: true);

  /// Push only (the sign-out flush).
  Future<MerchantRuleSyncResult> push() =>
      _run(SyncPhaseBinding(), pull: false);

  Future<MerchantRuleSyncResult> _run(SyncPhaseBinding phase,
      {required bool pull}) async {
    if (_busy) return const MerchantRuleSyncResult();
    _busy = true;
    try {
      final inherited = phase.isBound ? phase : null;
      if (inherited != null &&
          (!inherited.isCurrent || !identical(inherited.database, _db))) {
        return const MerchantRuleSyncResult();
      }
      final authority = AccountFenceAuthority.shared;
      final handle =
          await authority.captureForDatabase(AppSession.instance, _db);
      if (handle == null) return const MerchantRuleSyncResult();
      final run = _RuleInvocation(authority, handle, _db, inherited);
      if (!phase.isBound) phase.bind(run);
      final uid = await _getAuthUserId();
      if (uid == null || uid != authority.ownerUid(handle) || !run.isCurrent) {
        return const MerchantRuleSyncResult();
      }
      if (!await _mayEgress()) {
        phase.noteConsentBlocked(_health);
        return const MerchantRuleSyncResult();
      }
      if (!await _serverReady() || !run.isCurrent) {
        return const MerchantRuleSyncResult();
      }
      final pushed = await _push(run, phase, uid);
      if (!pull) {
        return MerchantRuleSyncResult(pushed: pushed.$1, failed: pushed.$2);
      }
      final pulled = await _pull(run, phase, uid);
      // Not after a failed or interrupted pull: the marker stays unset, so
      // the backfill waits for a later run whose pull completes.
      if (pulled.completed) await _backfill(run, uid, pulled.seen);
      // Rows the backfill just queued go out in this same run.
      final more = await _push(run, phase, uid);
      return MerchantRuleSyncResult(
        pushed: pushed.$1 + more.$1,
        failed: pushed.$2 + more.$2,
        applied: pulled.applied,
        removed: pulled.removed,
        parked: await run.runLocal(_parkedCount),
      );
    } on StaleAdmissionException {
      return const MerchantRuleSyncResult();
    } finally {
      _busy = false;
    }
  }

  // ─────────────────────────────────────────────────────────────── push

  Future<(int, int)> _push(
      _RuleInvocation run, SyncPhaseBinding phase, String uid) async {
    var pushed = 0, failed = 0;
    final items = await run.runLocal(
        () => _queue.pendingItems(entityType: entityType, limit: 200));
    for (final item in items) {
      if (!run.isCurrent) break;
      if (item.ownerUid != null && item.ownerUid != uid) {
        // Recorded for another identity: never sent under this uid.
        await run.runLocal(() => _queue.releaseInFlight(item.id));
        continue;
      }
      final key = item.payloadJson['merchant_key'];
      final category = item.payloadJson['category_key'];
      if (key is! String || category is! String) {
        await run.runLocal(() => _queue.markFailed(
            item.id, 'malformed_payload', OutboxFailureClass.corruptedPayload));
        failed++;
        continue;
      }
      try {
        final stored = await _remote.upsert({
          'user_id': uid,
          'merchant_key': key,
          'category_key': category,
          'deleted_at': item.operation == PlanningSyncOperation.delete
              ? DateTime.now().toUtc().toIso8601String()
              : null,
        });
        if (stored.length != 1 || stored.single['merchant_key'] != key) {
          throw StateError('merchant_rule_receipt_mismatch');
        }
        if (!run.isCurrent) break;
        await run.runLocal(() => _db.transaction(() async {
              await _queue.acknowledge(item);
              await _adoptCloudTime(key, category, stored.single,
                  removal: item.operation == PlanningSyncOperation.delete);
            }));
        pushed++;
      } on StaleAdmissionException {
        rethrow;
      } on AccountFenceDeliveryCancellation {
        rethrow;
      } catch (e) {
        failed++;
        phase.noteFailure(_health, e);
        if (kDebugMode) debugPrint('[MerchantRuleSync] push: $e');
        if (!run.isCurrent) break;
        await run.runLocal(() =>
            _queue.markFailed(item.id, e.toString(), classifyOutboxError(e)));
      }
    }
    return (pushed, failed);
  }

  // ─────────────────────────────────────────────────────────────── pull

  Future<({int applied, int removed, Set<String> seen, bool completed})> _pull(
      _RuleInvocation run, SyncPhaseBinding phase, String uid) async {
    var applied = 0, removed = 0;
    var completed = false;
    final seen = <String>{};
    void count(_Outcome o) {
      if (o == _Outcome.applied) applied++;
      if (o == _Outcome.removed) removed++;
    }

    try {
      // Rules parked on a missing category first: the planning pull that ran
      // just before may have restored it.
      for (final row in await run.runLocal(_parkedRows)) {
        count(await run.runLocal(() => _db.transaction(() => _apply(row))));
      }
      var cursor = await run.runLocal(() => readSyncCursor(_db, cursorKey));
      while (run.isCurrent) {
        final rows = await _remote.fetchRows(after: cursor, limit: _pageSize);
        if (rows.isEmpty) {
          completed = true;
          break;
        }
        await run.runLocal(() => _db.transaction(() async {
              for (final row in rows) {
                final owner = row['user_id'];
                if (owner != null && owner != uid) continue;
                final key = row['merchant_key'];
                if (key is String) seen.add(key);
                count(await _apply(row));
              }
              await writeSyncCursor(
                  _db, cursorKey, SyncCursor.fromServerRow(rows.last));
            }));
        if (rows.length < _pageSize) {
          completed = true;
          break;
        }
        cursor = SyncCursor.fromServerRow(rows.last);
      }
    } on StaleAdmissionException {
      rethrow;
    } on AccountFenceDeliveryCancellation {
      rethrow;
    } catch (e) {
      phase.noteFailure(_health, e);
      if (kDebugMode) debugPrint('[MerchantRuleSync] pull: $e');
    }
    return (
      applied: applied,
      removed: removed,
      seen: seen,
      completed: completed
    );
  }

  Future<_Outcome> _apply(Map<String, dynamic> row) async {
    final serverId = row['id'];
    final key = row['merchant_key'];
    final category = row['category_key'];
    if (serverId is! String ||
        key is! String ||
        category is! String ||
        !DriftMerchantCategoryRepository.isSyncableMerchantKey(key)) {
      return _Outcome.skipped;
    }
    // A local edit not yet pushed wins: it is newer than anything here.
    if (await _hasLocalIntent(key)) {
      await _unpark(serverId);
      return _Outcome.skipped;
    }
    final at = RuleVersion.parse('${row['updated_at']}');
    final deleted = row['deleted_at'] != null;
    final held = await deviceRuleVersion(_db, key);
    final wins = ruleVersionSupersedes(
        deleted ? RuleVersion.removal(at) : RuleVersion.rule(category, at),
        held);
    if (!wins) {
      // The device's rule or removal is at least as recent: it stands, and
      // where it differs from the cloud row it is sent, like the user's own
      // change. (`held` is non-null: nothing held always gives way.)
      await _unpark(serverId);
      final mine = held!.categoryKey;
      if (mine == null) {
        if (!deleted) {
          await _queue.enqueueMerchantRule(PlanningSyncOperation.delete,
              merchantKey: key, categoryKey: category);
        }
      } else if (deleted || mine != category) {
        await _queue.enqueueMerchantRule(PlanningSyncOperation.update,
            merchantKey: key, categoryKey: mine);
      }
      return _Outcome.skipped;
    }
    if (deleted) {
      await _unpark(serverId);
      final hadRule = held != null && !held.isRemoval;
      if (hadRule) await _rules.forgetUserConfirmedRule(key);
      // Recorded with the cloud's time (also when this device never held the
      // rule), so a backup restored here later is compared with the removal
      // itself, not with the moment of this pull.
      await setMerchantRuleTombstone(_db, key, category, at!);
      if (!hadRule) return _Outcome.skipped;
      _onRuleRemoved?.call(key);
      return _Outcome.removed;
    }
    if (held != null &&
        held.isRemoval &&
        await merchantRuleAwaitsUser(_db, key)) {
      // The user left this rule out after a restore (or a rule for it already
      // waits for the user): a newer cloud rule does not overturn that
      // silently; it goes on the list to choose.
      await _unpark(serverId);
      final raw = await _db.customSelect(
          'SELECT raw_name FROM merchants WHERE normalized_name = ? LIMIT 1;',
          variables: [Variable.withString(key)]).getSingleOrNull();
      await offerMerchantRuleChoice(
          _db,
          key,
          raw?.read<String>('raw_name') ?? key,
          category,
          '${row['updated_at']}');
      return _Outcome.skipped;
    }
    if (!await _categoryExists(category)) {
      await _park(serverId, row);
      return _Outcome.parked;
    }
    await _unpark(serverId);
    final same = held?.categoryKey == category;
    if (!same) {
      await _rules.confirmMerchantCategory(
          rawMerchant: key, categoryKey: category, isUserConfirmed: true);
    }
    // The rule now equals the cloud's and carries the cloud's change time.
    await setMerchantRuleTime(_db, key, at!);
    if (same) return _Outcome.skipped;
    _onRuleApplied?.call(key, category);
    return _Outcome.applied;
  }

  /// After a push the cloud row is this device's own version: take its time,
  /// so a later comparison with the cloud is on the cloud's clock, not this
  /// device's. Skipped when the device has moved on since (a newer edit).
  Future<void> _adoptCloudTime(
      String key, String category, Map<String, dynamic> stored,
      {required bool removal}) async {
    final at = RuleVersion.parse('${stored['updated_at']}');
    final held = await deviceRuleVersion(_db, key);
    if (at == null || held == null || await _hasLocalIntent(key)) return;
    if (removal && held.isRemoval) {
      await setMerchantRuleTombstone(_db, key, category, at);
    } else if (!removal && held.categoryKey == category) {
      await setMerchantRuleTime(_db, key, at);
    }
  }

  // ─────────────────────────────────────────────────────────── backfill

  /// Once per owner: rules confirmed before this feature (or before sign-in)
  /// have no outbox row. Queue every user-confirmed rule that has none and was
  /// not just pulled from the server. Later edits are queued as they happen.
  Future<void> _backfill(
      _RuleInvocation run, String uid, Set<String> pulled) async {
    if (!run.isCurrent) return;
    final marker = backfillKey(uid);
    final done = await run.runLocal(() => _db
        .customSelect('SELECT 1 FROM sync_cursors '
            'WHERE entity = ${sqlString(marker)} LIMIT 1;')
        .getSingleOrNull());
    if (done != null) return;
    await run.runLocal(() => _db.transaction(() async {
          for (final rule in await _rules.getUserConfirmedRules()) {
            final key = AppDatabase.normalizeMerchant(rule.rawMerchant);
            if (pulled.contains(key) ||
                !DriftMerchantCategoryRepository.isSyncableMerchantKey(key) ||
                await _hasLocalIntent(key)) {
              continue;
            }
            await _queue.enqueueMerchantRule(PlanningSyncOperation.update,
                merchantKey: key, categoryKey: rule.categoryKey);
          }
          await writeSyncCursor(_db, marker,
              const SyncCursor(updatedAt: syncCursorEpoch, id: 'done'));
        }));
  }

  // ─────────────────────────────────────────────────────────── helpers

  Future<bool> _hasLocalIntent(String key) async =>
      await _db
          .customSelect('SELECT 1 FROM planning_sync_outbox '
              'WHERE entity_type = ${sqlString(entityType)} '
              'AND entity_id = ${sqlString(key)} '
              "AND status != 'dead_letter' LIMIT 1;")
          .getSingleOrNull() !=
      null;

  Future<bool> _categoryExists(String key) async =>
      await _db
          .customSelect(
              'SELECT 1 FROM categories WHERE key = ${sqlString(key)} '
              'AND deleted_at IS NULL LIMIT 1;')
          .getSingleOrNull() !=
      null;

  Future<void> _park(String serverId, Map<String, dynamic> row) {
    final now = sqlString(dateTimeToSql(DateTime.now().toUtc()));
    return _db.customStatement('''
      INSERT INTO parked_child_rows(table_name, server_id, row_json, reason,
        attempt_count, first_seen_at, updated_at)
      VALUES (${sqlString(parkTable)}, ${sqlString(serverId)},
        ${sqlString(jsonEncode(row))}, 'missing_parent', 0, $now, $now)
      ON CONFLICT(table_name, server_id) DO UPDATE SET
        row_json = excluded.row_json, attempt_count = attempt_count + 1,
        updated_at = excluded.updated_at;
    ''');
  }

  Future<void> _unpark(String serverId) => _db.customStatement(
      'DELETE FROM parked_child_rows WHERE table_name = ${sqlString(parkTable)} '
      'AND server_id = ${sqlString(serverId)};');

  Future<List<Map<String, dynamic>>> _parkedRows() async => [
        for (final r in await _db
            .customSelect('SELECT row_json FROM parked_child_rows '
                'WHERE table_name = ${sqlString(parkTable)} '
                'ORDER BY first_seen_at;')
            .get())
          (jsonDecode(r.read<String>('row_json')) as Map)
              .cast<String, dynamic>(),
      ];

  Future<int> _parkedCount() async => (await _db
          .customSelect('SELECT COUNT(*) AS n FROM parked_child_rows '
              'WHERE table_name = ${sqlString(parkTable)};')
          .getSingle())
      .read<int>('n');
}

enum _Outcome { applied, removed, parked, skipped }

class _RuleInvocation implements SyncPhaseLifecycle {
  _RuleInvocation(this.authority, this.handle, this.database, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;

  @override
  bool get isCurrent =>
      authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent);

  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    if (!isCurrent) throw const StaleAdmissionException();
    return authority.runCurrentLocal(handle, database, action);
  }
}
