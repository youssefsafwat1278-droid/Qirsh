import '../../../core/sync/outbox_receipt.dart';
import '../../../core/sync/sync_conflict_store.dart';
import '../../../core/sync/sync_health.dart';
import 'dart:convert';

import 'package:drift/drift.dart' show QueryRow;
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/security/lock_prompt_language.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/bounded_lookup.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_repository_support.dart';
import '../../../data/sync/seq_pull.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../domain/entities/budget_entity.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/finance/currency_scale.dart';
import '../../../domain/finance/decimal_minor.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';
import 'planning_outbox_queue.dart';

int? _pulledBudgetThreshold(Map<String, dynamic> row) {
  final value = row['alert_threshold_percent'];
  return value is num
      ? BudgetEntity.normalizeAlertThreshold(value.toInt())
      : null;
}

const planningSubscriptionsPullSelect = '*, amount_text:amount::text, '
    'manual_paid_amount_text:manual_paid_amount::text, '
    'total_purchase_amount_text:total_purchase_amount::text';
const planningPlansPullSelect = '*, budget_amount_text:budget_amount::text';
// MALI-026 (B8-3 §9): canonical budget/goal pull projects every NUMERIC money
// column as ::text so it is parsed EXACTLY (no double on the path) with the row's
// own currency (server column 0077). Deferred until the planning-currency + exact
// pull transport capabilities are both verified.
const planningBudgetsPullSelect = '*, amount_text:amount::text, '
    'last_notified_spent_amount_text:last_notified_spent_amount::text';
const planningGoalsPullSelect = '*, target_amount_text:target_amount::text, '
    'saved_amount_text:saved_amount::text, '
    'last_notified_saved_amount_text:last_notified_saved_amount::text, '
    'auto_save_amount_text:auto_save_amount::text';
const planningPullOrderColumns = ['updated_at', 'id'];

String planningPullSelectForTable(String table) => switch (table) {
      'user_subscriptions' => planningSubscriptionsPullSelect,
      'user_plans' => planningPlansPullSelect,
      'user_budgets' => planningBudgetsPullSelect,
      'user_goals' => planningGoalsPullSelect,
      _ => '*',
    };

String planningPullKeysetFilter(SyncCursor after) =>
    'updated_at.gt.${after.updatedAt},'
    'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})';

({Money? amountMoney, Money? manualPaidMoney, Money? totalPurchaseMoney})
    deserializeSubscriptionsPullMoney(Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException(
        'subscription pull requires a String currency');
  }
  return (
    amountMoney: moneyFromPulledValue(row['amount_text'], currency),
    manualPaidMoney:
        moneyFromPulledValue(row['manual_paid_amount_text'], currency),
    totalPurchaseMoney:
        moneyFromPulledValue(row['total_purchase_amount_text'], currency),
  );
}

Money? deserializePlansPullMoney(Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException('plan pull requires a String currency');
  }
  return moneyFromPulledValue(row['budget_amount_text'], currency);
}

/// MALI-026 (B8-3 §9): exact budget pull money. Amount + last-notified are
/// required (server NOT NULL) so a missing ::text projection or null fails
/// closed. The row currency is the sole authority — NEVER a base fallback.
({Money amountMoney, Money lastNotifiedSpentMoney}) deserializeBudgetsPullMoney(
    Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException(
        'budget pull requires a String currency');
  }
  return (
    amountMoney: moneyFromPulledValueRequired(row['amount_text'], currency),
    lastNotifiedSpentMoney: _pulledBookkeepingMoney(
        row['last_notified_spent_amount_text'], currency),
  );
}

/// The `last_notified_*` columns are alert BOOKKEEPING (the progress last
/// notified about), not user money. Older clients pushed them as binary
/// doubles, so a server row can hold e.g. `1234.560000000002` for EGP. The
/// strict user-money parse rejects that, which used to abort the WHOLE budgets
/// pull on a fresh install (every budget missing after restore). These values
/// are quantized to the currency scale instead (half away from zero); the
/// budget/goal amounts themselves stay strict.
Money _pulledBookkeepingMoney(Object? raw, String currency) {
  if (raw is String) {
    final code = currency.trim().toUpperCase();
    return Money(quantizeDecimalToMinor(raw, currencyScale(code)), code);
  }
  return moneyFromPulledValueRequired(raw, currency);
}

/// MALI-026 (B8-3 §9): exact goal pull money. Target/saved/last-notified are
/// required; auto-save is nullable. The row currency is the sole authority.
({
  Money targetMoney,
  Money savedMoney,
  Money lastNotifiedSavedMoney,
  Money? autoSaveMoney,
}) deserializeGoalsPullMoney(Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException('goal pull requires a String currency');
  }
  return (
    targetMoney:
        moneyFromPulledValueRequired(row['target_amount_text'], currency),
    savedMoney:
        moneyFromPulledValueRequired(row['saved_amount_text'], currency),
    lastNotifiedSavedMoney: _pulledBookkeepingMoney(
        row['last_notified_saved_amount_text'], currency),
    autoSaveMoney: moneyFromPulledValue(row['auto_save_amount_text'], currency),
  );
}

class PlanningPullResult {
  const PlanningPullResult({
    this.imported = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.tombstoned = 0,
    this.completedEntities = const {},
  });

  final int imported;
  final int updated;
  final int conflicts;
  final int tombstoned;

  /// Planning is pulled per entity type, each with its own cursor. This is the
  /// set of entity types whose paginated pull reached server EOF this pass —
  /// the Batch-3 reconciler clears a planning dirty marker only for an entity
  /// present here (an entity that errored mid-page is absent, so its marker
  /// survives).
  final Set<String> completedEntities;
}

abstract class PlanningRemoteSource {
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit,
  });
}

/// Optional capability of a [PlanningRemoteSource]: fetch one row by server id
/// (conflict keep-remote).
abstract interface class PlanningRowByIdSource {
  Future<Map<String, dynamic>?> fetchRowById(String table, String serverId);
}

class SupabasePlanningRemoteSource
    implements PlanningRemoteSource, PlanningRowByIdSource {
  const SupabasePlanningRemoteSource();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
    String table, {
    required SyncCursor after,
    int limit = 200,
  }) async {
    final select = planningPullSelectForTable(table);
    final query = select == '*'
        ? _client.from(table).select()
        : _client.from(table).select(select);
    final filtered =
        after.id.isEmpty ? query : query.or(planningPullKeysetFilter(after));
    final response = await filtered
        .order(planningPullOrderColumns[0], ascending: true)
        .order(planningPullOrderColumns[1], ascending: true)
        .limit(limit);
    return (response as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>?> fetchRowById(
      String table, String serverId) async {
    final select = planningPullSelectForTable(table);
    final query = select == '*'
        ? _client.from(table).select()
        : _client.from(table).select(select);
    final row = await query.eq('id', serverId).maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }
}

class PlanningPullService {
  PlanningPullService({
    required AppDatabase db,
    required bool Function(String entityType) isEnabled,
    Future<String?> Function()? getAuthUserId,
    PlanningRemoteSource? remoteSource,
    PlanningOutboxQueue? outboxQueue,

    /// C-3 — financial PULL downloads this user's money from the server.
    /// Consent is asked fresh at egress and defaults to DENY, so a caller that
    /// omits it performs no network at all.
    Future<bool> Function()? mayEgress,

    /// `user_settings` carries PII (profile) — a separate egress class. Falls
    /// back to [mayEgress] (and therefore to DENY) when omitted.
    Future<bool> Function()? mayEgressProfile,
    SyncHealth? health,
    int pageSize = 200,

    /// Per-cycle page cap for a NORMAL incremental pull: after this many pages
    /// the pull stops (not completed) and the next cycle continues from the
    /// persisted cursor, so a first sync with a large server history never runs
    /// as one unbounded loop. Epoch/reconcile pulls (`from` given) are exempt —
    /// they restart from epoch each time and must reach EOF to clear their marker.
    int maxPagesPerRun = 10,

    /// WP-4: sequence pull gate. Null keeps the legacy timestamp pull.
    SeqPullGate? seqGate,
  })  : assert(pageSize > 0),
        _seqGate = seqGate,
        _mayEgressProfile =
            mayEgressProfile ?? mayEgress ?? _denyEgressByDefault,
        _health = health,
        _db = db,
        _conflicts = SyncConflictStore(db),
        _isEnabled = isEnabled,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _pageSize = pageSize,
        _maxPagesPerRun = maxPagesPerRun,
        _outboxQueue = outboxQueue,
        _mayEgress = mayEgress ?? _denyEgressByDefault,
        _remoteSource = remoteSource ?? const SupabasePlanningRemoteSource();

  final AppDatabase _db;
  final SyncConflictStore _conflicts;
  final bool Function(String entityType) _isEnabled;
  final int _maxPagesPerRun;
  final SeqPullGate? _seqGate;
  final Future<String?> Function() _getAuthUserId;
  final PlanningRemoteSource _remoteSource;
  final PlanningOutboxQueue? _outboxQueue;
  final Future<bool> Function() _mayEgress;
  final Future<bool> Function() _mayEgressProfile;
  final SyncHealth? _health;

  static Future<bool> _denyEgressByDefault() async => false;
  final int _pageSize;

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

  /// Conflict keep-remote, step 1: fetch the CURRENT server row of
  /// [entityType] by id, gated like [pull] (financial consent, per-entity
  /// enablement, signed-in owner). Throws on any refusal or transport error so
  /// the conflict is left untouched.
  Future<Map<String, dynamic>?> fetchServerRow(
      String entityType, String serverId) async {
    final table = _entityTable[entityType];
    if (table == null) throw ArgumentError('unsupported entity $entityType');
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.planning);
      throw StateError('keep-remote refetch blocked: no cloud consent');
    }
    if (!_isEnabled(entityType)) {
      throw StateError('keep-remote refetch blocked: pull not enabled');
    }
    if (await _getAuthUserId() == null) {
      throw StateError('keep-remote refetch blocked: not signed in');
    }
    final source = _remoteSource;
    if (source is! PlanningRowByIdSource) {
      throw UnsupportedError('remote source cannot fetch by id');
    }
    return (source as PlanningRowByIdSource).fetchRowById(table, serverId);
  }

  /// Step 2: apply a fetched row through the pull's own apply path (exact
  /// money, row currency, tombstones) without touching the cursor.
  Future<void> applyServerRow(
      String entityType, Map<String, dynamic> row) async {
    final ctx =
        await _buildPageContext(entityType, _localTable[entityType], [row]);
    if (row['deleted_at'] != null) {
      await _processTombstone(entityType, row, ctx);
    } else {
      await _processRow(entityType, row, ctx);
    }
  }

  /// [fromEpochEntities] names the planning entity types to force from epoch for
  /// a reconciliation full re-pull; each has its own independent `planning_<e>`
  /// cursor, so entities NOT named keep their normal incremental cursor and are
  /// untouched. [isAdmitted] is checked at every page boundary (per entity).
  Future<PlanningPullResult> pull({
    Set<String>? fromEpochEntities,
    bool Function()? isAdmitted,
  }) async {
    // C-3 — one check for the whole pull, before any cursor is read. Placing it
    // per-entity inside the loop would let a revocation mid-pull leave some
    // entities advanced and others not.
    final financialAllowed = await _mayEgress();
    final profileAllowed = await _mayEgressProfile();
    if (!financialAllowed && !profileAllowed) {
      _health?.noteConsentBlocked(SyncDomain.planning);
      return const PlanningPullResult();
    }
    if (!financialAllowed || !profileAllowed) {
      _health?.noteConsentBlocked(SyncDomain.planning);
    }
    final userId = await _getAuthUserId();
    if (userId == null) return const PlanningPullResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    var imported = 0;
    var updated = 0;
    var conflicts = 0;
    var tombstoned = 0;
    final completedEntities = <String>{};

    // WP-4: one protocol decision (and one head read) for all entities.
    final plan = _seqGate != null
        ? await _seqGate.plan(userId)
        : const SeqPlan(SeqMode.legacy);
    if (plan.mode == SeqMode.stopped) return const PlanningPullResult();

    for (final entry in _entityTable.entries) {
      final entityType = entry.key;
      final remoteTable = entry.value;
      if (!_isEnabled(entityType)) {
        // Every pulled entity is feature-enabled, so a disabled gate here is a
        // capability block (exact pull transport / planning currency): an
        // observable STATE, not a silent skip.
        _health?.noteCapabilityParked(SyncDomain.planning);
        continue;
      }
      final isSettings = entityType == PlanningOutboxQueue.settingsEntityType;
      if (!(isSettings ? profileAllowed : financialAllowed)) continue;

      try {
        final cursorKey = 'planning_$entityType';
        // Once per local owner, revisit legacy budgets without mutating any
        // server rows merely to bump their cursors. NULL keeps the local choice.
        final thresholdMarker = 'budget_warning_v1:$userId';
        final upgradeThresholds = entityType == PlanningOutboxQueue.budgetsEntityType &&
            _outboxQueue != null &&
            (await readSyncCursor(_db, thresholdMarker)).id != 'done';
        final forcedFromEpoch = upgradeThresholds ||
            (fromEpochEntities?.contains(entityType) ?? false);
        final useSeq = plan.mode == SeqMode.seq && !forcedFromEpoch;
        var cursor = forcedFromEpoch
            ? const SyncCursor.epoch()
            : await readSyncCursor(_db, cursorKey);
        var seqCursor =
            useSeq ? await readSeqCursor(_db, userId, cursorKey) : 0;
        var entityReachedEof = useSeq && plan.isIdle(seqCursor);
        final capped = !forcedFromEpoch;
        var pages = 0;
        while (!entityReachedEof) {
          if (!admitted()) break;
          final rows = useSeq
              ? await _seqGate!.fetch(
                  table: remoteTable,
                  userId: userId,
                  afterSeq: seqCursor,
                  limit: _pageSize,
                  select: planningPullSelectForTable(remoteTable),
                )
              : await _remoteSource.fetchRows(
                  remoteTable,
                  after: cursor,
                  limit: _pageSize,
                );
          if (!admitted()) break;
          if (rows.isEmpty) {
            entityReachedEof = true;
            break;
          }

          final nextSeq = useSeq ? nextSeqOf(rows, seqCursor) : 0;
          final nextCursor =
              useSeq ? cursor : SyncCursor.fromServerRow(rows.last);
          final pageResult = await _db.transaction(() async {
            var pageImported = 0;
            var pageUpdated = 0;
            var pageConflicts = 0;
            var pageTombstoned = 0;
            // MALI-029: resolve the whole page's identity + merchant/category
            // keys in a handful of bounded lookups instead of per-row SELECTs.
            final ctx = await _buildPageContext(
              entityType,
              _localTable[entityType],
              rows,
            );
            for (final row in rows) {
              final rowServerId = row['id'] as String?;
              if (row['deleted_at'] != null) {
                if (await _processTombstone(entityType, row, ctx)) {
                  pageTombstoned++;
                }
                // §5: a tombstoned parent is never a currency-repair obligation;
                // clear any stale quarantine so delete-after-quarantine converges.
                if (_planningCurrencyEntities.contains(entityType)) {
                  await _clearQuarantine(remoteTable, rowServerId);
                }
                continue;
              }
              try {
                final outcome = await _processRow(entityType, row, ctx);
                // §12: a canonical apply that succeeds clears any prior quarantine
                // (e.g. a repaired row re-pulled with its now-persisted currency).
                if (_planningCurrencyEntities.contains(entityType) &&
                    outcome != _PlanningPullOutcome.skipped) {
                  await _clearQuarantine(remoteTable, rowServerId);
                }
                switch (outcome) {
                  case _PlanningPullOutcome.imported:
                    pageImported++;
                  case _PlanningPullOutcome.updated:
                    pageUpdated++;
                  case _PlanningPullOutcome.conflict:
                    pageConflicts++;
                  case _PlanningPullOutcome.skipped:
                    break;
                }
              } catch (e) {
                // A strict money parse that rejects one row's amount (excess
                // precision → DecimalFormatException) is row-level too: it must
                // not roll back the page and block every other budget/goal.
                if (e is! MoneyTransportException &&
                    e is! DecimalFormatException) {
                  rethrow;
                }
                // MALI-026 (Phase-9F §4): an ACTIVE budget/goal whose persisted
                // server currency is NULL/unsupported is UNRESOLVED. Quarantine it
                // durably (NEVER invent currency — no base/account/settings
                // fallback) and CONTINUE so the healthy rows in this page still
                // commit and the cursor advances — no head-of-line block. ONLY
                // this expected unresolved-currency class is quarantined; any
                // other error still surfaces (rethrow → page rolls back as before).
                if (_planningCurrencyEntities.contains(entityType)) {
                  await _quarantineUnresolved(remoteTable, row);
                  continue;
                }
                rethrow;
              }
            }
            if (!admitted()) throw const ReconcilePullCancelled();
            if (useSeq) {
              await writeSeqCursor(_db, userId, cursorKey, nextSeq);
            } else {
              await writeSyncCursor(_db, cursorKey, nextCursor);
            }
            return (
              imported: pageImported,
              updated: pageUpdated,
              conflicts: pageConflicts,
              tombstoned: pageTombstoned,
            );
          });
          imported += pageResult.imported;
          updated += pageResult.updated;
          conflicts += pageResult.conflicts;
          tombstoned += pageResult.tombstoned;
          cursor = nextCursor;
          if (useSeq) seqCursor = nextSeq;
          if (rows.length < _pageSize) {
            entityReachedEof = true;
            break;
          }
          if (capped && ++pages >= _maxPagesPerRun) break;
        }
        if (useSeq && entityReachedEof) {
          await _seqGate!.markCaughtUp(userId, cursorKey, seqCursor, plan);
        }
        if (entityReachedEof && admitted()) {
          completedEntities.add(entityType);
          if (upgradeThresholds) {
            await writeSyncCursor(_db, thresholdMarker,
                const SyncCursor(updatedAt: syncCursorEpoch, id: 'done'));
          }
        }
      } on ReconcilePullCancelled {
        // Lifecycle/ownership cancellation for this entity — not transport.
        if (kDebugMode) {
          debugPrint('[PlanningPull] $entityType reconciliation cancelled');
        }
      } catch (e) {
        _health?.noteFailure(SyncDomain.planning, e);
        if (kDebugMode) debugPrint('[PlanningPull] $entityType pull: $e');
      }
    }

    if (kDebugMode) {
      debugPrint(
        '[PlanningPull] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned',
      );
    }
    return PlanningPullResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
      completedEntities: completedEntities,
    );
  }

  /// The planning parents whose per-row server currency may legitimately be
  /// NULL until the owner repairs it — the ONLY entities eligible for the
  /// unresolved-currency quarantine.
  static const _planningCurrencyEntities = {
    PlanningOutboxQueue.budgetsEntityType,
    PlanningOutboxQueue.goalsEntityType,
  };

  /// Durably record an ACTIVE budget/goal server row whose currency is
  /// unresolved, so pull progress is not blocked and the row can be repaired
  /// later. Reuses the existing v30 `parked_child_rows` durable table (no schema
  /// bump); (table_name, server_id) is the natural idempotency key, so a repeated
  /// pull of the same unresolved row refreshes one entry, never duplicates it.
  Future<void> _quarantineUnresolved(
      String remoteTable, Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT INTO parked_child_rows(
        table_name, server_id, row_json, reason, attempt_count,
        first_seen_at, updated_at
      ) VALUES (
        ${sqlString(remoteTable)}, ${sqlString(serverId)},
        ${sqlString(jsonEncode(row))}, 'unresolved_currency', 0,
        ${sqlString(now)}, ${sqlString(now)}
      ) ON CONFLICT(table_name, server_id) DO UPDATE SET
        row_json = excluded.row_json,
        reason = 'unresolved_currency',
        updated_at = excluded.updated_at;
    ''');
  }

  /// Clear a resolved/removed budget/goal from the unresolved-currency
  /// quarantine (only that reason — never touches child `missing_parent` parks).
  Future<void> _clearQuarantine(String remoteTable, String? serverId) async {
    if (serverId == null) return;
    await _db.customStatement(
      'DELETE FROM parked_child_rows '
      'WHERE table_name = ${sqlString(remoteTable)} '
      'AND server_id = ${sqlString(serverId)} '
      "AND reason = 'unresolved_currency';",
    );
  }

  /// MALI-026 (Phase-9F-2 §7): apply ONE authoritatively-refetched planning row
  /// through the SAME canonical decode/apply path production sync uses, then clear
  /// its unresolved-currency quarantine. Used by the owner-repair flow after a
  /// guarded server currency resolution — repair converges onto the normal sync
  /// contract, never onto stale quarantined data. Throws (leaving the quarantine
  /// intact, applying nothing) if the row is still non-canonical (currency still
  /// null → MoneyTransportException). A tombstoned row applies deletion semantics
  /// and clears the repair obligation.
  Future<void> applyRepairedRow(
      String entityType, Map<String, dynamic> row) async {
    final remoteTable = _entityTable[entityType];
    if (remoteTable == null) return;
    await _db.transaction(() async {
      final ctx =
          await _buildPageContext(entityType, _localTable[entityType], [row]);
      final serverId = row['id'] as String?;
      if (row['deleted_at'] != null) {
        await _processTombstone(entityType, row, ctx);
        await _clearQuarantine(remoteTable, serverId);
        return;
      }
      final outcome = await _processRow(entityType, row, ctx);
      if (outcome != _PlanningPullOutcome.skipped) {
        await _clearQuarantine(remoteTable, serverId);
      }
    });
  }

  Future<_PlanningPullOutcome> _processRow(
    String entityType,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    // الإعدادات singleton: يوجد صف واحد محلي دائمًا — نحدّثه ولا نُدرج صفًا ثانيًا.
    if (entityType == PlanningOutboxQueue.settingsEntityType) {
      return _processSettingsRow(row);
    }
    final serverId = row['id'] as String?;
    final localTable = _localTable[entityType];
    if (serverId == null || localTable == null) {
      return _PlanningPullOutcome.skipped;
    }

    final existing = ctx.identity.resolve(serverId, row['local_id'] as String?);
    if (existing != null) {
      final localId = existing.id;
      final status = existing.syncStatus;
      if (status == 'conflict') return _PlanningPullOutcome.conflict;
      if (status == 'pending') {
        // MALI-022: a pending local edit is a real conflict ONLY if the server
        // row moved since our base version. If the server is unchanged, this
        // local edit is the only edit and will push cleanly — don't false-flag
        // it (the old code conflicted every pending row unconditionally). Never
        // clobber the base token on a pending row.
        final base = existing.serverUpdatedAt;
        final serverMoved = base != _dateString(row['updated_at']);
        if (serverMoved) {
          // WP-5 lost-ACK receipt: the cloud's last write is OUR queued op.
          final own = await _settleOwn(entityType, localTable, localId, row);
          if (own != OwnOpResult.none) return _PlanningPullOutcome.updated;
          await _flagConflict(
              entityType,
              localTable,
              localId,
              row,
              await _pendingIsDelete(entityType, localId)
                  ? SyncConflictKind.delete
                  : SyncConflictKind.update);
          return _PlanningPullOutcome.conflict;
        }
        return _PlanningPullOutcome.skipped;
      }
      // No-op when unchanged since the last sync — stops the pull re-writing
      // every planning row each cycle (which ticks dbRevisionProvider and
      // flickers the UI). Only write when the server row actually moved.
      if (status == 'synced' &&
          existing.serverId == serverId &&
          existing.serverUpdatedAt == _dateString(row['updated_at'])) {
        await _uploadMissingBudgetThreshold(entityType, localId, row);
        return _PlanningPullOutcome.skipped;
      }
      await _updateLocal(entityType, localTable, localId, row, ctx);
      await _applyServerRevision(localTable, serverId, row);
      ctx.identity.remember(
        id: localId,
        serverId: serverId,
        serverUpdatedAt: _dateString(row['updated_at']),
      );
      await _uploadMissingBudgetThreshold(entityType, localId, row);
      return _PlanningPullOutcome.updated;
    }

    final insertedId = await _insertLocal(entityType, row, ctx);
    await _applyServerRevision(localTable, serverId, row);
    if (insertedId != null) {
      await _uploadMissingBudgetThreshold(entityType, insertedId, row);
      ctx.identity.remember(
        id: insertedId,
        serverId: serverId,
        serverUpdatedAt: _dateString(row['updated_at']),
      );
    }
    return _PlanningPullOutcome.imported;
  }

  Future<void> _uploadMissingBudgetThreshold(
      String entityType, String localId, Map<String, dynamic> row) async {
    if (entityType != PlanningOutboxQueue.budgetsEntityType ||
        !row.containsKey('alert_threshold_percent') ||
        row['alert_threshold_percent'] != null ||
        _outboxQueue == null) {
      return;
    }
    final local = await _db
        .customSelect(
          'SELECT * FROM budgets WHERE id = ${sqlString(localId)} AND deleted_at IS NULL;',
        )
        .getSingleOrNull();
    if (local != null) {
      await _outboxQueue.enqueueBudget(
          PlanningSyncOperation.update, budgetFromRow(local));
    }
  }

  /// MALI-022 / 0068 — persist the pulled server revision (the CAS base) on the
  /// just-written row. Centralised so every entity's insert/update path is
  /// covered in one place. A null revision (server predates 0068) is left as-is,
  /// so no extra write happens in the OFF/shipping state.
  Future<void> _applyServerRevision(
    String localTable,
    String serverId,
    Map<String, dynamic> row,
  ) async {
    final revision = (row['revision'] as num?)?.toInt();
    if (revision == null) return;
    await _db.customStatement(
      'UPDATE $localTable SET server_revision = $revision '
      'WHERE server_id = ${sqlString(serverId)};',
    );
  }

  Future<bool> _processTombstone(
    String entityType,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final serverId = row['id'] as String?;
    final localTable = _localTable[entityType];
    if (serverId == null || localTable == null) return false;
    final existing = ctx.identity.resolve(serverId, row['local_id'] as String?);
    if (existing == null) return false;

    final localId = existing.id;
    final status = existing.syncStatus;
    if (status == 'conflict') return false;
    if (status == 'pending') {
      // WP-5 lost-ACK receipt: the tombstone is our own queued delete.
      if (await _settleOwn(entityType, localTable, localId, row) !=
          OwnOpResult.none) {
        return true;
      }
      await _flagConflict(
          entityType, localTable, localId, row, SyncConflictKind.tombstone);
      return false;
    }

    final now = dateTimeToSql(DateTime.now().toUtc());
    final deletedAt = _dateString(row['deleted_at']) ?? now;
    await _db.customStatement('''
      UPDATE $localTable
      SET deleted_at = ${sqlString(deletedAt)},
          server_id = ${sqlString(serverId)},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          synced_at = ${sqlString(now)},
          sync_status = 'synced'
      WHERE id = ${sqlString(localId)};
    ''');
    await _applyServerRevision(localTable, serverId, row);
    ctx.identity.remember(
      id: localId,
      serverId: serverId,
      serverUpdatedAt: _dateString(row['updated_at']),
    );
    return true;
  }

  Future<String?> _insertLocal(
    String entityType,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final id = row['local_id'] as String? ?? IdGenerator.next();
    switch (entityType) {
      case PlanningOutboxQueue.budgetsEntityType:
        await _insertBudget(id, row, ctx);
      case PlanningOutboxQueue.subscriptionsEntityType:
        await _insertSubscription(id, row, ctx);
      case PlanningOutboxQueue.goalsEntityType:
        await _insertGoal(id, row);
      case PlanningOutboxQueue.plansEntityType:
        await _insertPlan(id, row);
      case PlanningOutboxQueue.cardsEntityType:
        await _insertCard(id, row);
      case PlanningOutboxQueue.categoriesEntityType:
        await _insertCategory(id, row);
    }
    return id;
  }

  Future<void> _updateLocal(
    String entityType,
    String table,
    String id,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    switch (entityType) {
      case PlanningOutboxQueue.budgetsEntityType:
        await _updateBudget(id, row, ctx);
      case PlanningOutboxQueue.subscriptionsEntityType:
        await _updateSubscription(id, row, ctx);
      case PlanningOutboxQueue.goalsEntityType:
        await _updateGoal(id, row);
      case PlanningOutboxQueue.plansEntityType:
        await _updatePlan(id, row);
      case PlanningOutboxQueue.cardsEntityType:
        await _updateCard(id, row);
      case PlanningOutboxQueue.categoriesEntityType:
        await _updateCategory(id, row);
    }
  }

  Future<void> _insertBudget(
    String id,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final categoryId = ctx.categories.resolve(row);
    // §9: exact — parse the ::text NUMERIC with the row currency into Money, then
    // write currency + `_minor` (authority) + the REAL shadow derived FROM Money.
    final money = deserializeBudgetsPullMoney(row);
    final currency = money.amountMoney.currency;
    await _db.customStatement('''
      INSERT OR IGNORE INTO budgets(
        id, category_id, currency, amount, amount_minor, period, start_date, is_active,
        last_notified_spent_amount, last_notified_spent_amount_minor,
        last_notified_period_start, show_on_header, account_id, alert_threshold_percent,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(categoryId)},
        ${sqlString(currency)},
        ${kMoneyCodec.sqlRealLiteral(money.amountMoney)},
        ${kMoneyCodec.sqlMinorLiteral(money.amountMoney)},
        ${sqlString(row['period'] as String? ?? 'monthly')},
        ${sqlString(_dateString(row['start_date']) ?? now)},
        ${row['is_active'] == false ? 0 : 1},
        ${kMoneyCodec.sqlRealLiteral(money.lastNotifiedSpentMoney)},
        ${kMoneyCodec.sqlMinorLiteral(money.lastNotifiedSpentMoney)},
        ${sqlString(row['last_notified_period_start'] as String? ?? '2000-01-01T00:00:00Z')},
        ${row['show_on_header'] == true ? 1 : 0},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${_pulledBudgetThreshold(row) ?? BudgetEntity.defaultAlertThresholdPercent},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateBudget(
    String id,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final categoryId = ctx.categories.resolve(row);
    final money = deserializeBudgetsPullMoney(row);
    await _db.customStatement('''
      UPDATE budgets
      SET category_id = ${sqlString(categoryId)},
          currency = ${sqlString(money.amountMoney.currency)},
          amount = ${kMoneyCodec.sqlRealLiteral(money.amountMoney)},
          amount_minor = ${kMoneyCodec.sqlMinorLiteral(money.amountMoney)},
          period = ${sqlString(row['period'] as String? ?? 'monthly')},
          start_date = ${sqlString(_dateString(row['start_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          is_active = ${row['is_active'] == false ? 0 : 1},
          last_notified_spent_amount = ${kMoneyCodec.sqlRealLiteral(money.lastNotifiedSpentMoney)},
          last_notified_spent_amount_minor = ${kMoneyCodec.sqlMinorLiteral(money.lastNotifiedSpentMoney)},
          last_notified_period_start = ${sqlString(row['last_notified_period_start'] as String? ?? '2000-01-01T00:00:00Z')},
          show_on_header = ${row['show_on_header'] == true ? 1 : 0},
          alert_threshold_percent = ${_pulledBudgetThreshold(row) ?? 'alert_threshold_percent'},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertCard(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // حقول التصميم تُكتَب فقط بعد ترقية 0064 (kUserCardsCloudV2) — قبلها
    // يُبقيها الخادم غير موجودة، ولا نلمس القيمة المحلية.
    const designCols = kUserCardsCloudV2 ? ', color_theme, accent_hex' : '';
    final designVals = kUserCardsCloudV2
        ? ', ${sqlNullableString(row['color_theme'] as String?)}, '
            '${sqlNullableString(row['accent_hex'] as String?)}'
        : '';
    await _db.customStatement('''
      INSERT OR IGNORE INTO cards(
        id, account_id, nickname, last4, network, source,
        created_at, updated_at,
        server_id, synced_at, server_updated_at, sync_status, deleted_at$designCols
      ) VALUES (
        ${sqlString(id)},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${sqlNullableString(row['nickname'] as String?)},
        ${sqlString(row['last4'] as String? ?? '')},
        ${sqlString(row['network'] as String? ?? 'unknown')},
        ${sqlString(row['source'] as String? ?? 'auto')},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(_dateString(row['updated_at']) ?? now)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL$designVals
      );
    ''');
  }

  Future<void> _updateCard(String id, Map<String, dynamic> row) async {
    final designSet = kUserCardsCloudV2
        ? 'color_theme = ${sqlNullableString(row['color_theme'] as String?)}, '
            'accent_hex = ${sqlNullableString(row['accent_hex'] as String?)}, '
        : '';
    await _db.customStatement('''
      UPDATE cards
      SET account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          nickname = ${sqlNullableString(row['nickname'] as String?)},
          last4 = ${sqlString(row['last4'] as String? ?? '')},
          network = ${sqlString(row['network'] as String? ?? 'unknown')},
          source = ${sqlString(row['source'] as String? ?? 'auto')},
          ${designSet}server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// singleton pull للإعدادات: يحدّث الصف الوحيد المحلي بالأعمدة السحابية فقط،
  /// ولا يمسّ الأعمدة المحلية (مفتاح التشفير/الأفاتار/الملف الشخصي). حارس التعارض
  /// نفسه: تعديل محلي معلّق (pending) يمنع الكتابة فوقه.
  Future<_PlanningPullOutcome> _processSettingsRow(
      Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _PlanningPullOutcome.skipped;
    final local = await _db
        .customSelect('SELECT * FROM user_settings LIMIT 1;')
        .getSingleOrNull();
    if (local == null) return _PlanningPullOutcome.skipped;
    final id = local.read<String>('id');
    final status = local.readNullable<String>('sync_status');
    final isUnbound = local.readNullable<String>('server_id') == null;
    final hasLocalRevocation =
        local.readNullable<String>('ai_consent_state') == 'declined' ||
            local.readNullable<String>('cloud_consent_state') == 'declined';

    // A consent choice made before the singleton was server-bound used to be
    // lost here: the pull attached the server id and marked the row synced, but
    // nothing remained to push the local OFF authority. Merge the remote's
    // ordinary settings, preserve the local consent columns, refresh the CAS
    // base, then coalesce a consent-carrying update back into the durable outbox.
    if (isUnbound && hasLocalRevocation) {
      final queue = _outboxQueue;
      if (queue == null) {
        await _markConflict('user_settings', id);
        return _PlanningPullOutcome.conflict;
      }
      await _updateSettings(
          id, serverId, row, local.read<String>('notifications_json'));
      await _applyServerRevision('user_settings', serverId, row);
      final rebound = await _db
          .customSelect(
              'SELECT * FROM user_settings WHERE id = ${sqlString(id)};')
          .getSingle();
      await queue.enqueueSettings(
        PlanningSyncOperation.update,
        userSettingsFromRow(rebound),
      );
      return _PlanningPullOutcome.updated;
    }
    if (status == 'conflict') return _PlanningPullOutcome.conflict;
    if (status == 'pending') {
      await _markConflict('user_settings', id);
      return _PlanningPullOutcome.conflict;
    }
    await _updateSettings(
        id, serverId, row, local.read<String>('notifications_json'));
    await _applyServerRevision('user_settings', serverId, row);
    return _PlanningPullOutcome.updated;
  }

  Future<void> _updateSettings(String id, String serverId,
      Map<String, dynamic> row, String localNotifications) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // نبقي القيمة المحلية إن كان الخادم لم يرسلها (أعمدة محلية NOT NULL).
    String keep(String col, Object? v) =>
        v == null ? col : sqlString(v as String);
    await _db.customStatement('''
      UPDATE user_settings
      SET display_name = ${keep('display_name', row['display_name'])},
          phone_number = ${keep('phone_number', row['phone_number'])},
          date_of_birth = ${keep('date_of_birth', row['date_of_birth'])},
          theme = ${keep('theme', row['theme'])},
          currency = ${keep('currency', row['currency'])},
          language = ${keep('language', row['language'])},
          country = ${keep('country', row['country'])},
          input_method = ${keep('input_method', row['input_method'])},
          notifications_json = ${keep('notifications_json', row['notifications_json'] is String ? NotificationInboxState.mergeHistoryJson(row['notifications_json'] as String, localNotifications) : null)},
          privacy_mode_enabled = ${(row['privacy_mode_enabled'] == true) ? 1 : 0},
          -- MALI-059n: consent is device-local + explicit. A server pull must
          -- NEVER set/inherit cloud/AI consent (that would auto-authorize a new
          -- device). The consent columns are deliberately left untouched here.
          server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced'
      WHERE id = ${sqlString(id)};
    ''');
    // The unlock prompt is composed before the database can be opened, so the
    // language is mirrored into the keychain wherever it changes — here, a
    // second device inheriting the choice made on the first. `keep()` above
    // leaves the local value alone when the server sends none, and so does
    // this. See core/security/lock_prompt_language.dart.
    final pulledLanguage = row['language'] as String?;
    if (pulledLanguage != null) {
      await LockPromptLanguage.set(pulledLanguage);
    }
  }

  Future<void> _insertCategory(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // key فريد؛ لو تعارض مع فئة موجودة (مثل فئات البذور) نتجاهل الإدراج بأمان.
    await _db.customStatement('''
      INSERT OR IGNORE INTO categories(
        id, key, name_ar, icon, color, is_income, sort_order,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['key'] as String? ?? id)},
        ${sqlString(row['name_ar'] as String? ?? '')},
        ${sqlString(row['icon'] as String? ?? 'tag')},
        ${sqlString(row['color'] as String? ?? '#888888')},
        ${(row['is_income'] == true) ? 1 : 0},
        (SELECT COALESCE(MAX(sort_order), 0) + 1 FROM categories),
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateCategory(String id, Map<String, dynamic> row) async {
    // نُبقي key و sort_order المحليّين؛ نُحدّث الحقول القابلة للتعديل فقط.
    await _db.customStatement('''
      UPDATE categories
      SET name_ar = ${sqlString(row['name_ar'] as String? ?? '')},
          icon = ${sqlString(row['icon'] as String? ?? 'tag')},
          color = ${sqlString(row['color'] as String? ?? '#888888')},
          is_income = ${(row['is_income'] == true) ? 1 : 0},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertSubscription(
    String id,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final pulledMoney = deserializeSubscriptionsPullMoney(row);
    final merchantId = await ctx.merchants.resolve(
        row['merchant_id'] as String?, row['name'] as String? ?? 'فاتورة');
    await _db.customStatement('''
      INSERT OR IGNORE INTO subscriptions(
        id, merchant_id, name, amount, amount_minor, currency, period, frequency, type,
        next_due_date, is_confirmed, reminder_on, custom_interval_days,
        note, created_at, status, account_id, total_installments, paid_count,
        manual_paid_amount, manual_paid_amount_minor,
        total_purchase_amount, total_purchase_amount_minor, lender_name, interest_rate,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)}, ${sqlString(merchantId)},
        ${sqlString(row['name'] as String? ?? 'فاتورة')},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.amountMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.amountMoney)},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(row['frequency'] as String? ?? 'monthly')},
        ${sqlString(row['frequency'] as String? ?? 'monthly')},
        ${sqlString(row['type'] as String? ?? 'subscription')},
        ${sqlString(_dateString(row['next_due_date']) ?? now)},
        ${row['is_confirmed'] == true ? 1 : 0},
        ${row['reminder_on'] == false ? 0 : 1},
        ${sqlNullableNum(row['custom_interval_days'] as num?)},
        ${sqlNullableString(row['note'] as String?)},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${sqlNullableNum(row['total_installments'] as num?)},
        ${sqlNullableNum(row['paid_count'] as num?)},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.manualPaidMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.manualPaidMoney)},
        ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.totalPurchaseMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.totalPurchaseMoney)},
        ${sqlNullableString(row['lender_name'] as String?)},
        ${sqlNullableNum(row['interest_rate'] as num?)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateSubscription(
    String id,
    Map<String, dynamic> row,
    _PlanningPageContext ctx,
  ) async {
    final pulledMoney = deserializeSubscriptionsPullMoney(row);
    final merchantId = await ctx.merchants.resolve(
        row['merchant_id'] as String?, row['name'] as String? ?? 'فاتورة');
    await _db.customStatement('''
      UPDATE subscriptions
      SET merchant_id = ${sqlString(merchantId)},
          name = ${sqlString(row['name'] as String? ?? 'فاتورة')},
          amount = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.amountMoney)},
          amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.amountMoney)},
          currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
          period = ${sqlString(row['frequency'] as String? ?? 'monthly')},
          frequency = ${sqlString(row['frequency'] as String? ?? 'monthly')},
          type = ${sqlString(row['type'] as String? ?? 'subscription')},
          next_due_date = ${sqlString(_dateString(row['next_due_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          is_confirmed = ${row['is_confirmed'] == true ? 1 : 0},
          reminder_on = ${row['reminder_on'] == false ? 0 : 1},
          custom_interval_days = ${sqlNullableNum(row['custom_interval_days'] as num?)},
          note = ${sqlNullableString(row['note'] as String?)},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          total_installments = ${sqlNullableNum(row['total_installments'] as num?)},
          paid_count = ${sqlNullableNum(row['paid_count'] as num?)},
          manual_paid_amount = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.manualPaidMoney)},
          manual_paid_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.manualPaidMoney)},
          total_purchase_amount = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.totalPurchaseMoney)},
          total_purchase_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.totalPurchaseMoney)},
          lender_name = ${sqlNullableString(row['lender_name'] as String?)},
          interest_rate = ${sqlNullableNum(row['interest_rate'] as num?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertGoal(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // §9: exact — parse every ::text NUMERIC with the row currency into Money,
    // then write currency + `_minor` authority + the REAL shadow from Money.
    final money = deserializeGoalsPullMoney(row);
    await _db.customStatement('''
      INSERT OR IGNORE INTO goals(
        id, name, account_id, currency,
        target_amount, target_amount_minor,
        saved_amount, saved_amount_minor,
        last_notified_saved_amount, last_notified_saved_amount_minor,
        deadline, vault_skin, status, created_at,
        auto_save_amount, auto_save_amount_minor, auto_save_period,
        auto_save_last_run, server_id, synced_at, server_updated_at,
        sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['name'] as String? ?? 'هدف')},
        ${sqlNullableString(row['local_account_id'] as String?)},
        ${sqlString(money.targetMoney.currency)},
        ${kMoneyCodec.sqlRealLiteral(money.targetMoney)},
        ${kMoneyCodec.sqlMinorLiteral(money.targetMoney)},
        ${kMoneyCodec.sqlRealLiteral(money.savedMoney)},
        ${kMoneyCodec.sqlMinorLiteral(money.savedMoney)},
        ${kMoneyCodec.sqlRealLiteral(money.lastNotifiedSavedMoney)},
        ${kMoneyCodec.sqlMinorLiteral(money.lastNotifiedSavedMoney)},
        ${sqlNullableString(_dateString(row['deadline']))},
        ${sqlString(row['vault_skin'] as String? ?? 'classic')},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${kMoneyCodec.sqlNullableRealLiteral(money.autoSaveMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(money.autoSaveMoney)},
        ${sqlNullableString(row['auto_save_period'] as String?)},
        ${sqlNullableString(_dateString(row['auto_save_last_run']))},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updateGoal(String id, Map<String, dynamic> row) async {
    final money = deserializeGoalsPullMoney(row);
    await _db.customStatement('''
      UPDATE goals
      SET name = ${sqlString(row['name'] as String? ?? 'هدف')},
          account_id = ${sqlNullableString(row['local_account_id'] as String?)},
          currency = ${sqlString(money.targetMoney.currency)},
          target_amount = ${kMoneyCodec.sqlRealLiteral(money.targetMoney)},
          target_amount_minor = ${kMoneyCodec.sqlMinorLiteral(money.targetMoney)},
          saved_amount = ${kMoneyCodec.sqlRealLiteral(money.savedMoney)},
          saved_amount_minor = ${kMoneyCodec.sqlMinorLiteral(money.savedMoney)},
          last_notified_saved_amount = ${kMoneyCodec.sqlRealLiteral(money.lastNotifiedSavedMoney)},
          last_notified_saved_amount_minor = ${kMoneyCodec.sqlMinorLiteral(money.lastNotifiedSavedMoney)},
          deadline = ${sqlNullableString(_dateString(row['deadline']))},
          vault_skin = ${sqlString(row['vault_skin'] as String? ?? 'classic')},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          auto_save_amount = ${kMoneyCodec.sqlNullableRealLiteral(money.autoSaveMoney)},
          auto_save_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(money.autoSaveMoney)},
          auto_save_period = ${sqlNullableString(row['auto_save_period'] as String?)},
          auto_save_last_run = ${sqlNullableString(_dateString(row['auto_save_last_run']))},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<void> _insertPlan(String id, Map<String, dynamic> row) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final budgetMoney = deserializePlansPullMoney(row);
    await _db.customStatement('''
      INSERT OR IGNORE INTO plans(
        id, name, budget_amount, budget_amount_minor, currency, start_date, end_date,
        account_ids, card_last4s, status, icon, created_at,
        server_id, synced_at, server_updated_at, sync_status, deleted_at
      ) VALUES (
        ${sqlString(id)},
        ${sqlString(row['name'] as String? ?? 'خطة')},
        ${kMoneyCodec.sqlNullableRealLiteral(budgetMoney)},
        ${kMoneyCodec.sqlNullableMinorLiteral(budgetMoney)},
        ${sqlString(row['currency'] as String? ?? 'SAR')},
        ${sqlString(_dateString(row['start_date']) ?? now)},
        ${sqlString(_dateString(row['end_date']) ?? now)},
        ${sqlString(_csv(row['local_account_ids']))},
        ${sqlString(_csv(row['card_last4s']))},
        ${sqlString(row['status'] as String? ?? 'active')},
        ${sqlNullableString(row['icon'] as String?)},
        ${sqlString(_dateString(row['created_at']) ?? now)},
        ${sqlString(row['id'] as String)},
        ${sqlString(now)},
        ${sqlNullableString(_dateString(row['updated_at']))},
        'synced',
        NULL
      );
    ''');
  }

  Future<void> _updatePlan(String id, Map<String, dynamic> row) async {
    final budgetMoney = deserializePlansPullMoney(row);
    await _db.customStatement('''
      UPDATE plans
      SET name = ${sqlString(row['name'] as String? ?? 'خطة')},
          budget_amount = ${kMoneyCodec.sqlNullableRealLiteral(budgetMoney)},
          budget_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(budgetMoney)},
          currency = ${sqlString(row['currency'] as String? ?? 'SAR')},
          start_date = ${sqlString(_dateString(row['start_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          end_date = ${sqlString(_dateString(row['end_date']) ?? dateTimeToSql(DateTime.now().toUtc()))},
          account_ids = ${sqlString(_csv(row['local_account_ids']))},
          card_last4s = ${sqlString(_csv(row['card_last4s']))},
          status = ${sqlString(row['status'] as String? ?? 'active')},
          icon = ${sqlNullableString(row['icon'] as String?)},
          server_id = ${sqlString(row['id'] as String)},
          synced_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
          server_updated_at = ${sqlNullableString(_dateString(row['updated_at']))},
          sync_status = 'synced',
          deleted_at = NULL
      WHERE id = ${sqlString(id)};
    ''');
  }

  Future<OwnOpResult> _settleOwn(String entityType, String localTable,
          String localId, Map<String, dynamic> row) =>
      settleOwnOperation(
        db: _db,
        outboxTable: 'planning_sync_outbox',
        outboxWhere: 'entity_type = ${sqlString(entityType)} '
            'AND entity_id = ${sqlString(localId)}',
        localTable: localTable,
        localId: localId,
        serverRow: row,
      );

  Future<bool> _pendingIsDelete(String entityType, String localId) async =>
      (await _db
          .customSelect(
              'SELECT 1 AS x FROM planning_sync_outbox WHERE entity_type = '
              "${sqlString(entityType)} AND entity_id = ${sqlString(localId)} "
              "AND operation = 'delete' LIMIT 1;")
          .getSingleOrNull()) !=
      null;

  /// WP-5: the durable conflict record (snapshots) + the flag, then the same
  /// in-flight clearing as before.
  Future<void> _flagConflict(String entityType, String table, String localId,
      Map<String, dynamic> row, SyncConflictKind kind) async {
    await _db.transaction(() async {
      await _conflicts.flag(
        entityType: entityType,
        localId: localId,
        kind: kind,
        serverId: row['id'] as String?,
        theirs: row,
        theirsRevision: (row['revision'] as num?)?.toInt(),
      );
      await _markConflict(table, localId);
    });
  }

  Future<void> _markConflict(String table, String localId) async {
    await _db.transaction(() async {
      await _db.customStatement('''
        UPDATE $table
        SET sync_status = 'conflict'
        WHERE id = ${sqlString(localId)};
      ''');
      // The server row demonstrably exists: clear the ambiguous in-flight marker
      // so the held conflict can be resolved (keep-remote refuses while set).
      await _db.customStatement(
        'UPDATE planning_sync_outbox SET in_flight_seq = NULL '
        'WHERE entity_id = ${sqlString(localId)};',
      );
    });
  }

  /// MALI-029: resolve one pull page's identity + (merchant | category) keys in
  /// a handful of bounded lookups instead of per-row SELECTs. Merchants are only
  /// primed for subscription pages; categories only for budget pages — other
  /// entity types get no-op resolvers that are never consulted.
  Future<_PlanningPageContext> _buildPageContext(
    String entityType,
    String? localTable,
    List<Map<String, dynamic>> rows,
  ) async {
    final identity = await _prefetchIdentity(localTable, rows);
    final merchants = entityType == PlanningOutboxQueue.subscriptionsEntityType
        ? await _prefetchMerchants(rows)
        : _PlanningMerchantResolver.empty(_db);
    final categories = entityType == PlanningOutboxQueue.budgetsEntityType
        ? await _prefetchCategories(rows)
        : const _PlanningCategoryResolver.empty();
    return _PlanningPageContext(
      identity: identity,
      merchants: merchants,
      categories: categories,
    );
  }

  Future<_PlanningIdentityIndex> _prefetchIdentity(
    String? localTable,
    List<Map<String, dynamic>> rows,
  ) async {
    final index = _PlanningIdentityIndex();
    if (localTable == null) {
      return index; // settings singleton — no identity map
    }
    final serverIds = <String>{};
    final localIds = <String>{};
    for (final row in rows) {
      final sid = row['id'] as String?;
      if (sid != null) serverIds.add(sid);
      final lid = row['local_id'] as String?;
      if (lid != null) localIds.add(lid);
    }
    // $localTable is a fixed internal table name from _localTable, never user
    // input — same as every other `FROM $localTable` in this file. The IDs are
    // bound variables via the chunk primitive, never interpolated.
    final cols =
        'SELECT id, server_id, sync_status, server_updated_at FROM $localTable';
    for (final r in await selectByIdChunks(_db, serverIds,
        sql: (ph) => '$cols WHERE server_id IN ($ph);')) {
      index._add(_PlanningMeta.fromRow(r));
    }
    for (final r in await selectByIdChunks(_db, localIds,
        sql: (ph) => '$cols WHERE id IN ($ph);')) {
      index._add(_PlanningMeta.fromRow(r));
    }
    return index;
  }

  Future<_PlanningMerchantResolver> _prefetchMerchants(
    List<Map<String, dynamic>> rows,
  ) async {
    final merchantIds = <String>{};
    final normNames = <String>{};
    for (final row in rows) {
      final mid = row['merchant_id'] as String?;
      if (mid != null && mid.isNotEmpty) merchantIds.add(mid);
      final name = row['name'] as String? ?? 'فاتورة';
      normNames.add(AppDatabase.normalizeMerchant(name));
    }
    final existingIds = <String>{};
    for (final r in await selectByIdChunks(_db, merchantIds,
        sql: (ph) => 'SELECT id FROM merchants WHERE id IN ($ph);')) {
      existingIds.add(r.read<String>('id'));
    }
    final byNorm = <String, String>{};
    for (final r in await selectByIdChunks(_db, normNames,
        sql: (ph) => 'SELECT id, normalized_name FROM merchants '
            'WHERE normalized_name IN ($ph);')) {
      byNorm[r.read<String>('normalized_name')] = r.read<String>('id');
    }
    return _PlanningMerchantResolver(_db, existingIds, byNorm);
  }

  Future<_PlanningCategoryResolver> _prefetchCategories(
    List<Map<String, dynamic>> rows,
  ) async {
    final keys = <String>{};
    final serverIds = <String>{};
    for (final row in rows) {
      final key = row['category_id'] as String?;
      if (key != null &&
          key != BudgetEntity.allExpensesCategoryKey &&
          key != BudgetEntity.allExpensesCategoryId) {
        keys.add(key);
      }
      final scid = row['user_category_id'] as String?;
      if (scid != null) serverIds.add(scid);
    }
    final byKey = <String, String>{};
    for (final r in await selectByIdChunks(_db, keys,
        sql: (ph) => 'SELECT id, key FROM categories WHERE key IN ($ph);')) {
      byKey[r.read<String>('key')] = r.read<String>('id');
    }
    final byServer = <String, String>{};
    for (final r in await selectByIdChunks(_db, serverIds,
        sql: (ph) =>
            'SELECT id, server_id FROM categories WHERE server_id IN ($ph);')) {
      final sid = r.readNullable<String>('server_id');
      if (sid != null) byServer[sid] = r.read<String>('id');
    }
    final otherRow = await _db
        .customSelect("SELECT id FROM categories WHERE key = 'other' LIMIT 1;")
        .getSingleOrNull();
    return _PlanningCategoryResolver(
        byKey, byServer, otherRow?.read<String>('id'));
  }

  String? _dateString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  String _csv(Object? value) {
    if (value is List) {
      return value.map((e) => '$e').where((e) => e.isNotEmpty).join(',');
    }
    if (value is String) return value;
    return '';
  }
}

enum _PlanningPullOutcome { imported, updated, conflict, skipped }

/// Per-page resolvers for one planning entity type, built once from a handful of
/// bounded lookups. Page-scoped (never an instance/static field), so a same-UID
/// relogin under a new admission generation always resolves against freshly
/// committed local state and can never reuse a stale cross-owner map.
class _PlanningPageContext {
  const _PlanningPageContext({
    required this.identity,
    required this.merchants,
    required this.categories,
  });

  final _PlanningIdentityIndex identity;
  final _PlanningMerchantResolver merchants;
  final _PlanningCategoryResolver categories;
}

/// One local row's identity + sync-meta for a pull page.
class _PlanningMeta {
  const _PlanningMeta({
    required this.id,
    required this.serverId,
    required this.syncStatus,
    required this.serverUpdatedAt,
  });

  factory _PlanningMeta.fromRow(QueryRow row) => _PlanningMeta(
        id: row.read<String>('id'),
        serverId: row.readNullable<String>('server_id'),
        syncStatus: row.readNullable<String>('sync_status'),
        serverUpdatedAt: row.readNullable<String>('server_updated_at'),
      );

  final String id;
  final String? serverId;
  final String? syncStatus;
  final String? serverUpdatedAt;
}

/// server_id → meta and local id → meta for one page — replaces `_findLocalId`
/// (up to 2 SELECTs) + the meta SELECT, resolving server-id-first then local-id.
class _PlanningIdentityIndex {
  final Map<String, _PlanningMeta> _byServer = {};
  final Map<String, _PlanningMeta> _byLocal = {};

  void _add(_PlanningMeta meta) {
    _byLocal[meta.id] = meta;
    final serverId = meta.serverId;
    if (serverId != null) _byServer.putIfAbsent(serverId, () => meta);
  }

  _PlanningMeta? resolve(String serverId, String? localId) {
    final byServer = _byServer[serverId];
    if (byServer != null) return byServer;
    if (localId == null) return null;
    return _byLocal[localId];
  }

  /// Keep the index consistent after a write so a later same-page row that
  /// resolves to this row (e.g. a duplicate local_id) stays bit-identical to the
  /// old per-row re-read.
  void remember({
    required String id,
    required String serverId,
    required String? serverUpdatedAt,
  }) {
    final meta = _PlanningMeta(
      id: id,
      serverId: serverId,
      syncStatus: 'synced',
      serverUpdatedAt: serverUpdatedAt,
    );
    _byLocal[id] = meta;
    _byServer[serverId] = meta;
  }
}

/// Batches subscription merchant resolution: existing-by-id + existing-by-
/// normalized-name are prefetched once per page; a genuinely new merchant is
/// created once and memoised by normalized name (so repeated merchant values in
/// a page resolve to one row, exactly as the old per-row `_ensureMerchant`).
class _PlanningMerchantResolver {
  _PlanningMerchantResolver(this._db, this._existingIds, this._byNorm);
  _PlanningMerchantResolver.empty(this._db)
      : _existingIds = <String>{},
        _byNorm = <String, String>{};

  final AppDatabase _db;
  final Set<String> _existingIds;
  final Map<String, String> _byNorm;

  Future<String> resolve(String? merchantId, String name) async {
    if (merchantId != null &&
        merchantId.isNotEmpty &&
        _existingIds.contains(merchantId)) {
      return merchantId;
    }
    final normalized = AppDatabase.normalizeMerchant(name);
    final existing = _byNorm[normalized];
    if (existing != null) return existing;

    final id =
        merchantId?.isNotEmpty == true ? merchantId! : IdGenerator.next();
    final now = dateTimeToSql(DateTime.now().toUtc());
    await _db.customStatement('''
      INSERT OR IGNORE INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
      VALUES (${sqlString(id)}, ${sqlString(name)}, ${sqlString(normalized)}, ${sqlString(now)}, ${sqlString(now)});
    ''');
    _byNorm[normalized] = id;
    _existingIds.add(id);
    return id;
  }
}

/// Batches budget category resolution from prefetched key → id and server_id →
/// id maps plus the shared `'other'` fallback. Prefers the canonical category
/// key over the server-id match (the key is the stable identity per CLAUDE.md);
/// the old per-row `key = ? OR server_id = ?` had undefined precedence but the
/// two point at the same category in every realistic case.
class _PlanningCategoryResolver {
  const _PlanningCategoryResolver(this._byKey, this._byServer, this._otherId);
  const _PlanningCategoryResolver.empty()
      : _byKey = const {},
        _byServer = const {},
        _otherId = null;

  final Map<String, String> _byKey;
  final Map<String, String> _byServer;
  final String? _otherId;

  String resolve(Map<String, dynamic> row) {
    final key = row['category_id'] as String?;
    if (key == null ||
        key == BudgetEntity.allExpensesCategoryKey ||
        key == BudgetEntity.allExpensesCategoryId) {
      return BudgetEntity.allExpensesCategoryId;
    }
    final byKey = _byKey[key];
    if (byKey != null) return byKey;
    final scid = row['user_category_id'] as String?;
    if (scid != null) {
      final byServer = _byServer[scid];
      if (byServer != null) return byServer;
    }
    return _otherId ?? BudgetEntity.allExpensesCategoryId;
  }
}
