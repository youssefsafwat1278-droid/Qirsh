import 'dart:convert';

import '../../../core/sync/conflict_policy.dart';
import '../../../core/sync/outbox_receipt.dart';
import '../../../core/sync/sync_conflict_store.dart';
import '../../../core/sync/sync_health.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'ledger_sync_engine.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/utils/id_generator.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/merchant_identity.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_dedup_store.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../data/sync/seq_pull.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';
import 'ledger_payload.dart';

typedef LedgerPullStop = SyncPullStop;

/// A pulled row whose identity cannot be bound without breaking the §4.11 rule
/// (its `client_request_id` is already a local transaction id owned by a
/// different server row). Never resolved with a random replacement id.
class LedgerIdentityCollision implements Exception {
  const LedgerIdentityCollision();

  @override
  String toString() => 'LedgerIdentityCollision';
}

class LedgerSyncResult {
  const LedgerSyncResult({
    this.imported = 0,
    this.updated = 0,
    this.conflicts = 0,
    this.tombstoned = 0,
    this.status = SyncPullStatus.deferred,
    this.stopped,
  });

  final LedgerPullStop? stopped;
  final int imported;
  final int updated;
  final int conflicts;
  final int tombstoned;
  final SyncPullStatus status;
}

const ledgerTransactionSelect =
    '*, amount_text:amount::text, balance_after_text:balance_after::text, '
    'foreign_amount_text:foreign_amount::text';
const ledgerTransactionOrderColumns = ['updated_at', 'id'];

String ledgerTransactionKeysetFilter(SyncCursor after) =>
    'updated_at.gt.${after.updatedAt},'
    'and(updated_at.eq.${after.updatedAt},id.gt.${after.id})';

({Money amountMoney, Money? balanceAfterMoney, Money? foreignMoney})
    deserializeLedgerTransactionMoney(Map<String, dynamic> row) {
  final currency = row['currency'];
  if (currency is! String) {
    throw const MoneyTransportException(
        'transaction pull requires a String currency');
  }
  final foreignCurrency = row['foreign_currency'];
  if (foreignCurrency != null && foreignCurrency is! String) {
    throw const MoneyTransportException(
        'transaction pull foreign_currency must be a String or null');
  }
  final foreignText = row['foreign_amount_text'];
  if ((foreignText == null) != (foreignCurrency == null)) {
    throw const MoneyTransportException(
        'foreign_amount_text and foreign_currency must be supplied together');
  }
  final amountMoney = moneyFromPulledValueRequired(row['amount_text'], currency);
  // A-6: amount 0 is valid ONLY as an awaiting-FX row (foreign amount present).
  if (amountMoney.isZero && foreignText == null) {
    throw const MoneyTransportException(
        'a zero amount requires a foreign amount (awaiting-FX transaction)');
  }
  return (
    amountMoney: amountMoney,
    balanceAfterMoney:
        moneyFromPulledValue(row['balance_after_text'], currency),
    foreignMoney: foreignCurrency == null
        ? null
        : moneyFromPulledValue(foreignText, foreignCurrency as String),
  );
}

/// Injectable remote source — real impl calls Supabase; test impl returns
/// fixture rows without network access.
abstract class LedgerRemoteSource {
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit,
  });
}

/// Optional capability of a [LedgerRemoteSource]: fetch one row by server id
/// (conflict keep-remote).
abstract interface class LedgerRowByIdSource {
  Future<Map<String, dynamic>?> fetchRowById(String serverId);
}

class SupabaseLedgerRemoteSource
    implements LedgerRemoteSource, LedgerRowByIdSource {
  const SupabaseLedgerRemoteSource();

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final query = Supabase.instance.client
        .from('user_transactions')
        .select(ledgerTransactionSelect);
    final filtered = after.id.isEmpty
        ? query
        : query.or(ledgerTransactionKeysetFilter(after));
    final response = await filtered
        .order(ledgerTransactionOrderColumns[0], ascending: true)
        .order(ledgerTransactionOrderColumns[1], ascending: true)
        .limit(limit);
    return (response as List).cast<Map<String, dynamic>>();
  }

  @override
  Future<Map<String, dynamic>?> fetchRowById(String serverId) async {
    final row = await Supabase.instance.client
        .from('user_transactions')
        .select(ledgerTransactionSelect)
        .eq('id', serverId)
        .maybeSingle();
    return row == null ? null : Map<String, dynamic>.from(row);
  }
}

class LedgerSyncService implements LedgerPullAdapter {
  LedgerSyncService({
    required AppDatabase db,
    required DriftTransactionRepository transactionRepository,
    required DriftDedupStore dedupStore,
    required bool Function() isPullEnabled,

    /// C-3 — financial PULL downloads this user's money from the server.
    /// Consent is asked fresh at egress and defaults to DENY, so a caller that
    /// omits it performs no network at all.
    Future<bool> Function()? mayEgress,
    LedgerRemoteSource? remoteSource,
    Future<String?> Function()? getAuthUserId,
    int pageSize = 200,

    /// Per-cycle page cap for a NORMAL incremental pull: after this many pages
    /// the pull stops (not completed) and the next cycle continues from the
    /// persisted cursor, so a first sync with a large server history never runs
    /// as one unbounded loop. Epoch/reconcile pulls (`from` given) are exempt —
    /// they restart from epoch each time and must reach EOF to clear their marker.
    int maxPagesPerRun = 10,
    SyncHealth? health,

    /// WP-4: sequence pull gate. Null (the default) keeps the legacy timestamp
    /// pull unconditionally; with a gate a verified `sync_seq` capability
    /// selects the sequence pull, unsupported the legacy pull, and an unknown
    /// answer pulls nothing this cycle.
    SeqPullGate? seqGate,
  })  : assert(pageSize > 0),
        _seqGate = seqGate,
        _health = health,
        _db = db,
        _conflicts = SyncConflictStore(db),
        _transactionRepository = transactionRepository,
        _dedupStore = dedupStore,
        _isPullEnabled = isPullEnabled,
        _mayEgress = mayEgress ?? _denyEgressByDefault,
        _remoteSource = remoteSource ?? const SupabaseLedgerRemoteSource(),
        _pageSize = pageSize,
        _maxPagesPerRun = maxPagesPerRun,
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId;

  static final _payloadMarkerTime =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  static String _payloadHash(String payloadId) => 'capture_payload:$payloadId';

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  final AppDatabase _db;
  final SyncConflictStore _conflicts;
  final DriftTransactionRepository _transactionRepository;
  final DriftDedupStore _dedupStore;
  final bool Function() _isPullEnabled;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;

  static Future<bool> _denyEgressByDefault() async => false;
  final LedgerRemoteSource _remoteSource;
  final Future<String?> Function() _getAuthUserId;
  final int _pageSize;
  final int _maxPagesPerRun;
  final SeqPullGate? _seqGate;

  // MALI-029 (pull batching) — resolution snapshots primed ONCE per pull instead
  // of a SELECT per row. A ledger pull only WRITES transactions; it never creates
  // accounts/categories (accounts are pulled earlier in the same single-flight
  // pump), so a start-of-pull snapshot is valid for every page. Cleared when pull
  // finishes; a null cache falls back to the original per-call SELECT.
  Map<String, String>?
      _accountServerToLocal; // accounts.server_id → accounts.id
  Set<String>? _localAccountIds; // non-deleted accounts.id
  Map<String, String>? _categoryKeyToLocal; // categories.key → categories.id

  Future<void> _primeResolutionCaches() async {
    final accounts = await _db
        .customSelect(
          'SELECT id, server_id FROM accounts WHERE deleted_at IS NULL;',
        )
        .get();
    final serverToLocal = <String, String>{};
    final ids = <String>{};
    for (final a in accounts) {
      final id = a.read<String>('id');
      ids.add(id);
      final serverId = a.readNullable<String>('server_id');
      if (serverId != null) serverToLocal[serverId] = id;
    }
    final categories =
        await _db.customSelect('SELECT id, key FROM categories;').get();
    final keyToLocal = <String, String>{
      for (final c in categories) c.read<String>('key'): c.read<String>('id'),
    };
    _accountServerToLocal = serverToLocal;
    _localAccountIds = ids;
    _categoryKeyToLocal = keyToLocal;
  }

  void _clearResolutionCaches() {
    _accountServerToLocal = null;
    _localAccountIds = null;
    _categoryKeyToLocal = null;
  }

  static const _cursorKey = 'ledger_transactions';

  @override
  Future<LedgerSyncResult> pull({
    SyncCursor? from,
    bool Function()? isAdmitted,
  }) async {
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.ledger);
      return const LedgerSyncResult();
    }
    if (!_isPullEnabled()) {
      // Blocked by an unverified/unsupported transport: an observable STATE.
      _health?.noteCapabilityParked(SyncDomain.ledger);
      return const LedgerSyncResult();
    }

    final userId = await _getAuthUserId();
    if (userId == null) return const LedgerSyncResult();
    final admitted = isAdmitted ?? alwaysAdmitted;

    // WP-4: protocol selection. A reconcile pull (`from` given) always runs the
    // legacy epoch re-pull; so does a service without the capability hook.
    var plan = const SeqPlan(SeqMode.legacy);
    if (_seqGate != null && from == null) {
      plan = await _seqGate.plan(userId);
      if (plan.mode == SeqMode.stopped) {
        return LedgerSyncResult(
          status: SyncPullStatus.failed,
          stopped: _seqGate.lastStop,
        );
      }
    }
    final useSeq = plan.mode == SeqMode.seq;

    int imported = 0;
    int updated = 0;
    int conflicts = 0;
    int tombstoned = 0;

    var reachedEof = false;
    try {
      // Prime the account/category resolution snapshots once for the whole pull.
      await _primeResolutionCaches();
      await _retryQuarantined(admitted);
      var cursor = from ?? await readSyncCursor(_db, _cursorKey);
      var seqCursor = 0;
      if (useSeq) seqCursor = await readSeqCursor(_db, userId, _cursorKey);
      // Server-head short-circuit: nothing newer than this cursor exists, so
      // an idle pull cost exactly the one head call made by the plan.
      final skipPages = useSeq && plan.isIdle(seqCursor);
      var pages = 0;
      if (skipPages) reachedEof = true;
      while (!skipPages) {
        if (!admitted()) break;
        final List<Map<String, dynamic>> rows;
        if (useSeq) {
          rows = await _seqGate!.fetch(
            table: 'user_transactions',
            userId: userId,
            afterSeq: seqCursor,
            limit: _pageSize,
            select: ledgerTransactionSelect,
          );
        } else {
          rows = await _remoteSource.fetchRows(after: cursor, limit: _pageSize);
        }
        if (!admitted()) break;
        if (rows.isEmpty) {
          reachedEof = true;
          break;
        }

        // A non-advancing page would loop forever / skip rows: throws.
        final nextSeq = useSeq ? nextSeqOf(rows, seqCursor) : 0;
        final nextCursor =
            useSeq ? cursor : SyncCursor.fromServerRow(rows.last);
        final pageResult = await _db.transaction(() async {
          var pageImported = 0;
          var pageUpdated = 0;
          var pageConflicts = 0;
          var pageTombstoned = 0;
          final appliedIds = <String>[];
          for (final row in rows) {
            // B12: a row that throws is quarantined (raw JSON, durable) and the
            // page + cursor still advance. Each row runs in its own savepoint so
            // a poison row's partial writes roll back without the rest of the page.
            final outcome = await _applyRowOrQuarantine(row);
            if (outcome == _RowOutcome.quarantined) continue;
            switch (outcome) {
              case _RowOutcome.imported:
                pageImported++;
              case _RowOutcome.updated:
                pageUpdated++;
              case _RowOutcome.tombstoned:
                pageTombstoned++;
              case _RowOutcome.conflict:
                pageConflicts++;
              case _RowOutcome.skipped:
              case _RowOutcome.quarantined:
                break;
            }
            final id = row['id'];
            if (id is String) appliedIds.add(id);
          }
          // A row that applied cleanly supersedes any earlier quarantined copy.
          await _clearQuarantined(appliedIds);
          if (!admitted()) throw const ReconcilePullCancelled();
          // The cursor advances in the SAME transaction as the page it covers.
          if (useSeq) {
            await writeSeqCursor(_db, userId, _cursorKey, nextSeq);
          } else {
            await writeSyncCursor(_db, _cursorKey, nextCursor);
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
          reachedEof = true;
          break;
        }
        if (from == null && ++pages >= _maxPagesPerRun) break;
      }
      // EOF: everything up to the head read before the fetches is applied.
      if (useSeq && reachedEof) {
        await _seqGate!.markCaughtUp(userId, _cursorKey, seqCursor, plan);
      }
    } on ReconcilePullCancelled {
      // Lifecycle/ownership cancellation, not a transport failure.
      if (kDebugMode) debugPrint('[LedgerSync] reconciliation cancelled');
    } catch (e) {
      _health?.noteFailure(SyncDomain.ledger, e);
      if (kDebugMode) debugPrint('[LedgerSync] pull error: $e');
    } finally {
      _clearResolutionCaches();
    }
    final status =
        reachedEof ? SyncPullStatus.completed : SyncPullStatus.failed;

    if (kDebugMode) {
      debugPrint(
        '[LedgerSync] done: imported=$imported updated=$updated '
        'conflicts=$conflicts tombstoned=$tombstoned',
      );
    }
    return LedgerSyncResult(
      imported: imported,
      updated: updated,
      conflicts: conflicts,
      tombstoned: tombstoned,
      status: status,
    );
  }

  /// Conflict keep-remote, step 1: fetch the CURRENT server row by id. Gated
  /// exactly like [pull] (consent, enablement, signed-in owner); any refusal or
  /// transport error throws so the caller leaves the conflict untouched.
  Future<Map<String, dynamic>?> fetchServerRow(String serverId) async {
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.ledger);
      throw StateError('keep-remote refetch blocked: no cloud consent');
    }
    if (!_isPullEnabled()) {
      throw StateError('keep-remote refetch blocked: pull not enabled');
    }
    if (await _getAuthUserId() == null) {
      throw StateError('keep-remote refetch blocked: not signed in');
    }
    final source = _remoteSource;
    if (source is! LedgerRowByIdSource) {
      throw UnsupportedError('remote source cannot fetch by id');
    }
    return (source as LedgerRowByIdSource).fetchRowById(serverId);
  }

  /// Step 2: apply a fetched row through the SAME path the pull uses (exact
  /// money decode, tombstones, base token) without touching the cursor.
  Future<void> applyServerRow(Map<String, dynamic> row) async {
    await _primeResolutionCaches();
    try {
      await _applyRow(row);
    } finally {
      _clearResolutionCaches();
    }
  }

  Future<_RowOutcome> _processRow(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _RowOutcome.skipped;

    final payloadId = row['source_payload_id'] as String?;
    final serverUpdatedAt = row['updated_at'] as String?;
    // MALI-022 / 0068 — the server revision (CAS base). Null when the server
    // predates 0068 (the column is simply absent from the pulled row); stored as
    // NULL locally, which the push treats as fail-safe (guarded, not blind).
    final serverRevision = (row['revision'] as num?)?.toInt();
    final now = dateTimeToSql(DateTime.now().toUtc());

    final localId =
        await _findLocalId(serverId, payloadId, _clientRequestId(row));

    if (localId != null) {
      final meta = await _db
          .customSelect(
            'SELECT sync_status, server_id, server_updated_at, server_revision, '
            'account_id, category_id, category_source, raw_merchant, merchant_id, '
            'imported_from_file '
            'FROM transactions WHERE id = ${sqlString(localId)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (meta == null) return _RowOutcome.skipped;

      final syncStatus = meta.readNullable<String>('sync_status');
      if (syncStatus == 'conflict') {
        return _RowOutcome.conflict;
      }

      // A local edit is awaiting push (MALI-009). If the server row moved past
      // the base version the edit was made against, that's a genuine
      // concurrent edit — surface a conflict WITHOUT touching the fields or
      // the base token (overwriting server_updated_at here would disarm the
      // push's optimistic check and silently pick a winner). If the server row
      // is still at our base, leave the row alone and let the push proceed.
      if (syncStatus == 'pending') {
        final baseToken = meta.readNullable<String>('server_updated_at');
        final baseRevision = meta.readNullable<int>('server_revision');
        // WP-5: with a known revision on both sides the revision decides; the
        // legacy timestamp compare is the fallback.
        final moved = (serverRevision != null && baseRevision != null)
            ? serverRevision != baseRevision
            : canonicalServerTimestamp(serverUpdatedAt) !=
                canonicalServerTimestamp(baseToken);
        if (moved) {
          // WP-5 lost-ACK receipt: the cloud's last write is OUR queued op.
          final own = await settleOwnOperation(
            db: _db,
            outboxTable: 'ledger_sync_outbox',
            outboxWhere: 'transaction_id = ${sqlString(localId)}',
            localTable: 'transactions',
            localId: localId,
            serverRow: row,
          );
          if (own != OwnOpResult.none) return _RowOutcome.updated;
          await _db.transaction(() async {
            await _conflicts.flag(
              entityType: ConflictEntities.transaction,
              localId: localId,
              kind: await _pendingIsDelete(localId)
                  ? SyncConflictKind.delete
                  : SyncConflictKind.update,
              serverId: serverId,
              theirs: row,
              theirsRevision: serverRevision,
            );
            // The server row demonstrably exists: a kept (ambiguous) in-flight
            // marker would hold the conflict unresolvable forever (the hold stops
            // the row being pushed, and keep-remote refuses while it is set).
            await _db.customStatement(
              'UPDATE ledger_sync_outbox SET in_flight_seq = NULL '
              'WHERE transaction_id = ${sqlString(localId)};',
            );
          });
          return _RowOutcome.conflict;
        }
        return _RowOutcome.skipped;
      }

      // Account repair: a sign-out wipe regenerates local account ids, so a
      // previously-imported transaction can point at an account id that no
      // longer exists — invisible in every account-scoped screen. Resolve the
      // authoritative local account (server_account_id → accounts.server_id)
      // and re-point synced rows whose stored account is stale. Pending local
      // edits are left untouched.
      final currentAccountId = meta.readNullable<String>('account_id');
      final resolvedAccountId = await _resolveLocalAccountId(row);
      final currentAccountValid = currentAccountId == null ||
          await _localAccountExists(currentAccountId);
      final accountNeedsRepair = syncStatus == 'synced' &&
          (!currentAccountValid ||
              (resolvedAccountId != null &&
                  resolvedAccountId != currentAccountId));

      // No-op when the server row is unchanged since we last synced it —
      // re-writing synced_at every pull cycle ticks dbRevisionProvider and
      // forces a visible reload of every screen (the "flicker"). Only write
      // when something actually differs.
      final alreadySynced = syncStatus == 'synced' &&
          meta.readNullable<String>('server_id') == serverId &&
          canonicalServerTimestamp(
                  meta.readNullable<String>('server_updated_at')) ==
              canonicalServerTimestamp(serverUpdatedAt);
      if (alreadySynced && !accountNeedsRepair) return _RowOutcome.skipped;

      // The server row changed since we last saw it and there is no pending
      // local edit — apply the REMOTE FINANCIAL FIELDS, not just sync
      // metadata (MALI-009). Before this, an edit made on another device
      // never landed here, while the new server_updated_at was still
      // recorded — making the staleness permanent.
      final pulledMoney = deserializeLedgerTransactionMoney(row);
      final currency = row['currency'] as String;
      final occurredAt = row['occurred_at'] as String?;
      final localCategoryId =
          await _localCategoryIdForKey(row['category_id'] as String?);
      // MALI-056n — converge to the remote canonical type/source/direction, not
      // a coarse approximation (symmetric with the push).
      final metadata = row['metadata'];
      final mappedType = LedgerPayloadCodec.typeFromPull(
        canonicalType: _canonicalMeta(metadata, 'canonical_type'),
        serverTransactionType: row['transaction_type'] as String? ?? 'unknown',
      );
      final mappedSource = LedgerPayloadCodec.sourceFromPull(
        canonicalSource: _canonicalMeta(metadata, 'canonical_source'),
        serverSource: row['source'] as String? ?? 'unknown',
      );
      final mappedDirection = LedgerPayloadCodec.directionFromPull(
        canonicalDirection: _canonicalMeta(metadata, 'canonical_direction'),
        type: mappedType,
        serverDirection: row['direction'] as String?,
      );
      // A transfer row that says nothing about its direction keeps the local
      // one: unknown is never better than a known debit/credit.
      final keepLocalDirection = mappedType == TransactionTypeEntity.transfer &&
          mappedDirection == TransactionDirectionEntity.unknown;
      // Category provenance travels in its own column. A server that predates
      // it sends no key: then a changed category could have been anyone's
      // choice, so it becomes 'unknown'; an unchanged one keeps its provenance.
      final currentProvenance = meta.readNullable<String>('category_source');
      final pulledProvenance = row['category_source'] as String?;
      final categoryProvenance = pulledProvenance != null
          ? categoryProvenanceFromSql(pulledProvenance).name
          : localCategoryId != meta.readNullable<String>('category_id')
              ? CategoryProvenance.unknown.name
              : (currentProvenance ?? CategoryProvenance.unknown.name);
      // A changed merchant name moves the row to that merchant's identity
      // (the same deterministic key captures use); transfers and income never
      // carry a merchant link.
      final pulledMerchant = (row['merchant'] as String?)?.trim();
      final merchantless = mappedType == TransactionTypeEntity.transfer ||
          mappedType == TransactionTypeEntity.income;
      final merchantId = merchantless ||
              pulledMerchant == null ||
              pulledMerchant.isEmpty
          ? null
          : pulledMerchant == meta.readNullable<String>('raw_merchant')?.trim() &&
                  meta.readNullable<String>('merchant_id') != null
              ? meta.readNullable<String>('merchant_id')
              : await resolveOrCreateMerchantId(_db, pulledMerchant);
      final serverStatus = row['status'] as String?;
      final mappedStatus = switch (serverStatus) {
        'pending' => 'pending',
        'ignored' => 'ignored',
        _ => 'confirmed',
      };
      await _db.customStatement('''
        UPDATE transactions
        SET amount = ${kMoneyCodec.sqlRealLiteral(pulledMoney.amountMoney)},
            amount_minor = ${kMoneyCodec.sqlMinorLiteral(pulledMoney.amountMoney)},
            currency = ${sqlString(currency)},
            raw_merchant = ${sqlNullableString(row['merchant'] as String?)},
            merchant_id = ${sqlNullableString(merchantId)},
            category_source = ${sqlString(categoryProvenance)},
            -- Sticky: a pull can mark a row imported, never unmark it.
            imported_from_file = ${(meta.readNullable<int>('imported_from_file') ?? 0) == 1 || row['imported_from_file'] == true ? 1 : 0},
            note = ${sqlNullableString(row['description'] as String?)},
            type = ${sqlString(mappedType.name)},
            source = ${sqlString(mappedSource.name)},
            direction = ${keepLocalDirection ? 'direction' : sqlString(mappedDirection.name)},
            status = ${sqlString(mappedStatus)},
            ${occurredAt != null ? 'occurred_at = ${sqlString(dateTimeToSql(DateTime.tryParse(occurredAt)?.toUtc() ?? DateTime.now().toUtc()))},' : ''}
            category_id = ${sqlNullableString(localCategoryId)},
            card_last4 = ${sqlNullableString(_last4FromMetadata(row['metadata']))},
            balance_after = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.balanceAfterMoney)},
            balance_after_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.balanceAfterMoney)},
            foreign_amount = ${kMoneyCodec.sqlNullableRealLiteral(pulledMoney.foreignMoney)},
            foreign_amount_minor = ${kMoneyCodec.sqlNullableMinorLiteral(pulledMoney.foreignMoney)},
            foreign_currency = ${sqlNullableString(row['foreign_currency'] as String?)},
            account_id = ${sqlNullableString(resolvedAccountId)},
            -- A write from an older build drops the key: keep the local link.
            transfer_group_id = COALESCE(${sqlNullableString(_canonicalMeta(metadata, 'transfer_group_id'))}, transfer_group_id),
            updated_at = ${sqlString(now)},
            server_id = ${sqlString(serverId)},
            synced_at = ${sqlString(now)},
            server_updated_at = ${sqlNullableString(canonicalServerTimestamp(serverUpdatedAt))},
            server_revision = ${sqlNullableNum(serverRevision)},
            sync_status = 'synced'
        WHERE id = ${sqlString(localId)};
      ''');
      return _RowOutcome.updated;
    }

    // No local row — import from server.
    final entity = _rowToEntity(
      row,
      accountId: await _resolveLocalAccountId(row),
    );
    if (entity == null) return _RowOutcome.skipped;

    await _transactionRepository.saveTransaction(
      transaction: entity,
      // Server stores the stable category KEY; saveTransaction resolves it
      // back to the local category id, so a pulled row keeps its category.
      categoryKey: row['category_id'] as String?,
      // MALI-029: reuse the pull's primed key→id snapshot so the shared
      // saveTransaction doesn't re-run `_categoryIdByKey` per imported row. Null
      // (key not in the local snapshot) falls back to the validating key path,
      // which seeds a known category exactly as before.
      resolvedCategoryId:
          await _localCategoryIdForKey(row['category_id'] as String?),
    );

    await _db.customStatement('''
      UPDATE transactions
      SET server_id = ${sqlString(serverId)},
          synced_at = ${sqlString(now)},
          server_updated_at = ${sqlNullableString(canonicalServerTimestamp(serverUpdatedAt))},
          server_revision = ${sqlNullableNum(serverRevision)},
          sync_status = 'synced'
      WHERE id = ${sqlString(entity.id)};
    ''');

    if (payloadId != null) {
      await _dedupStore.mark(
        _payloadHash(payloadId),
        transactionId: entity.id,
        occurredAt: _payloadMarkerTime,
      );
    }

    return _RowOutcome.imported;
  }

  Future<_RowOutcome> _processTombstone(Map<String, dynamic> row) async {
    final serverId = row['id'] as String?;
    if (serverId == null) return _RowOutcome.skipped;
    final localId = await _findLocalId(serverId, null, _clientRequestId(row));
    if (localId == null) return _RowOutcome.skipped;

    final meta = await _db
        .customSelect(
          "SELECT status, sync_status, EXISTS(SELECT 1 FROM ledger_sync_outbox "
          "WHERE transaction_id = ${sqlString(localId)}) AS has_op "
          "FROM transactions WHERE id = ${sqlString(localId)} LIMIT 1;",
        )
        .getSingleOrNull();
    if (meta == null) return _RowOutcome.skipped;

    final syncStatus = meta.readNullable<String>('sync_status');
    final status = meta.read<String>('status');
    if (syncStatus == 'conflict' || status == 'ignored') {
      return _RowOutcome.skipped;
    }

    // B7: a remote tombstone vs a pending local edit is a CONFLICT, never a
    // silent delete — same representation as the live-row conflict in
    // _processRow (local fields and the outbox op are kept; the ambiguous
    // in-flight marker is cleared so keep-local / keep-remote can resolve it).
    if (syncStatus == 'pending' || meta.read<bool>('has_op')) {
      // WP-5 lost-ACK receipt: the tombstone is our own queued delete.
      final own = await settleOwnOperation(
        db: _db,
        outboxTable: 'ledger_sync_outbox',
        outboxWhere: 'transaction_id = ${sqlString(localId)}',
        localTable: 'transactions',
        localId: localId,
        serverRow: row,
      );
      if (own != OwnOpResult.none) return _RowOutcome.tombstoned;
      await _db.transaction(() async {
        await _conflicts.flag(
          entityType: ConflictEntities.transaction,
          localId: localId,
          kind: SyncConflictKind.tombstone,
          serverId: serverId,
          theirs: row,
          theirsRevision: (row['revision'] as num?)?.toInt(),
        );
        await _db.customStatement(
          'UPDATE ledger_sync_outbox SET in_flight_seq = NULL '
          'WHERE transaction_id = ${sqlString(localId)};',
        );
      });
      return _RowOutcome.conflict;
    }

    await _db.customStatement('''
      UPDATE transactions
      SET status = 'ignored',
          updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(localId)};
    ''');
    return _RowOutcome.tombstoned;
  }

  Future<bool> _pendingIsDelete(String localId) async =>
      (await _db
              .customSelect(
                  "SELECT 1 AS x FROM ledger_sync_outbox WHERE transaction_id = "
                  "${sqlString(localId)} AND operation = 'delete' LIMIT 1;")
              .getSingleOrNull()) !=
      null;

  Future<_RowOutcome> _applyRow(Map<String, dynamic> row) =>
      row['deleted_at'] != null ? _processTombstone(row) : _processRow(row);

  // ---- B12: per-row quarantine --------------------------------------------
  // Reuses the existing `parked_child_rows` table (no schema change) with
  // table_name='transactions' and reason 'quarantine' (bounded retry) or
  // 'terminal' (given up, still countable). Child sync only reads rows for its
  // own child table names, so these are never picked up by it.
  static const _quarantineTable = 'transactions';
  static const _quarantineMaxAttempts = 5;

  Future<_RowOutcome> _applyRowOrQuarantine(Map<String, dynamic> row) async {
    try {
      return await _db.transaction(() => _applyRow(row));
    } on ReconcilePullCancelled {
      rethrow;
    } catch (e) {
      final id = row['id'];
      if (id is! String || id.isEmpty) rethrow; // no durable key: cannot park
      _health?.noteFailure(SyncDomain.ledger, e);
      // An identity collision can never succeed on retry: park it as
      // 'integrity' (kept, countable, not retried) instead of 'quarantine'.
      final reason = e is LedgerIdentityCollision ? 'integrity' : 'quarantine';
      final now = sqlString(dateTimeToSql(DateTime.now().toUtc()));
      await _db.customStatement('''
        INSERT INTO parked_child_rows(
          table_name, server_id, row_json, reason, attempt_count,
          first_seen_at, updated_at
        ) VALUES (
          ${sqlString(_quarantineTable)}, ${sqlString(id)},
          ${sqlString(jsonEncode(row))}, ${sqlString(reason)}, 0, $now, $now
        ) ON CONFLICT(table_name, server_id) DO UPDATE SET
          row_json = excluded.row_json,
          reason = CASE WHEN excluded.reason = 'integrity'
                        THEN 'integrity' ELSE parked_child_rows.reason END,
          updated_at = excluded.updated_at;
      ''');
      return _RowOutcome.quarantined;
    }
  }

  Future<void> _clearQuarantined(List<String> serverIds) async {
    if (serverIds.isEmpty) return;
    await _db.customStatement(
      'DELETE FROM parked_child_rows '
      'WHERE table_name = ${sqlString(_quarantineTable)} '
      'AND server_id IN (${serverIds.map(sqlString).join(',')});',
    );
  }

  /// Bounded retry of quarantined rows at the start of a pull. Success clears
  /// the row; a failure bumps the attempt count and becomes 'terminal' (kept,
  /// countable) at the cap so it stops looping.
  Future<void> _retryQuarantined(bool Function() admitted) async {
    final parked = await _db
        .customSelect(
          'SELECT server_id, row_json, attempt_count FROM parked_child_rows '
          'WHERE table_name = ${sqlString(_quarantineTable)} '
          "AND reason = 'quarantine' ORDER BY first_seen_at LIMIT 50;",
        )
        .get();
    for (final p in parked) {
      if (!admitted()) return;
      final serverId = p.read<String>('server_id');
      final attempts = p.read<int>('attempt_count') + 1;
      try {
        final row =
            jsonDecode(p.read<String>('row_json')) as Map<String, dynamic>;
        await _db.transaction(() async {
          await _applyRow(row);
          await _clearQuarantined([serverId]);
        });
      } catch (e) {
        final reason = e is LedgerIdentityCollision
            ? 'integrity'
            : attempts >= _quarantineMaxAttempts
                ? 'terminal'
                : 'quarantine';
        await _db.customStatement(
          'UPDATE parked_child_rows SET attempt_count = $attempts, '
          'reason = ${sqlString(reason)}, '
          'updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))} '
          'WHERE table_name = ${sqlString(_quarantineTable)} '
          'AND server_id = ${sqlString(serverId)};',
        );
      }
    }
  }

  static String? _clientRequestId(Map<String, dynamic> row) {
    final v = row['client_request_id'];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// §4.11 identity: `server_id`, then `client_request_id` (a local transaction
  /// id), then the legacy payload marker. A local row that already owns the
  /// `client_request_id` as its id but is bound to a DIFFERENT server row is an
  /// integrity error ([LedgerIdentityCollision] -> quarantine), never a reason
  /// to mint a replacement id.
  Future<String?> _findLocalId(
    String serverId,
    String? payloadId,
    String? clientRequestId,
  ) async {
    final byServer = await _db
        .customSelect(
          "SELECT id FROM transactions "
          "WHERE server_id = ${sqlString(serverId)} AND status != 'ignored' "
          "LIMIT 1;",
        )
        .getSingleOrNull();
    if (byServer != null) return byServer.read<String>('id');

    if (clientRequestId != null) {
      final byId = await _db
          .customSelect(
            'SELECT id, server_id FROM transactions '
            'WHERE id = ${sqlString(clientRequestId)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (byId != null) {
        final boundTo = byId.readNullable<String>('server_id');
        if (boundTo == null || boundTo == serverId) {
          return byId.read<String>('id');
        }
        throw const LedgerIdentityCollision();
      }
    }

    if (payloadId != null) {
      return _dedupStore.transactionIdFor(
        _payloadHash(payloadId),
        _payloadMarkerTime,
      );
    }
    return null;
  }

  /// Maps a pulled server row to a local entity. [accountId] must be the
  /// pre-resolved LOCAL account id (see [_resolveLocalAccountId]) — the raw
  /// `local_account_id` column is a device-local id from whichever install
  /// pushed the row and is meaningless after a sign-out wipe regenerated the
  /// local accounts; importing it verbatim orphans the transaction.
  TransactionEntity? _rowToEntity(
    Map<String, dynamic> row, {
    String? accountId,
  }) {
    final currency = row['currency'] as String?;
    final occurredAt = row['occurred_at'] as String?;
    if (currency == null || occurredAt == null) return null;
    final pulledMoney = deserializeLedgerTransactionMoney(row);

    final now = DateTime.now().toUtc();
    // MALI-056n — recover the EXACT client type/source/direction from the
    // canonical metadata (authoritative); fall back to the documented coarse
    // rule for older rows. Never silently turns an unknown/future type into
    // payment.
    final metadata = row['metadata'];
    final canonicalType = LedgerPayloadCodec.typeFromPull(
      canonicalType: _canonicalMeta(metadata, 'canonical_type'),
      serverTransactionType: row['transaction_type'] as String? ?? 'unknown',
    );
    return TransactionEntity(
      // §4.11: a pulled row carrying a client_request_id keeps it as the local
      // id; only a legacy row without one gets a generated id.
      id: _clientRequestId(row) ?? IdGenerator.next(),
      amountMoney: pulledMoney.amountMoney,
      currency: currency,
      rawMerchant: row['merchant'] as String?,
      note: row['description'] as String?,
      type: canonicalType,
      source: LedgerPayloadCodec.sourceFromPull(
        canonicalSource: _canonicalMeta(metadata, 'canonical_source'),
        serverSource: row['source'] as String? ?? 'unknown',
      ),
      direction: LedgerPayloadCodec.directionFromPull(
        canonicalDirection: _canonicalMeta(metadata, 'canonical_direction'),
        type: canonicalType,
        serverDirection: row['direction'] as String?,
      ),
      accountId: accountId,
      // Who chose the category, from its own server column. Absent (an older
      // server) or null: nobody can say, so 'unknown' — never auto-changed.
      categoryProvenance:
          categoryProvenanceFromSql(row['category_source'] as String?),
      importedFromFile: row['imported_from_file'] == true,
      // Card linkage lives in metadata.last4 on the server (no dedicated
      // column); restore it so pulled transactions stay linked to their card.
      cardLast4: _last4FromMetadata(row['metadata']),
      transferGroupId: _canonicalMeta(metadata, 'transfer_group_id'),
      balanceAfterMoney: pulledMoney.balanceAfterMoney,
      foreignMoney: pulledMoney.foreignMoney,
      foreignCurrency: row['foreign_currency'] as String?,
      occurredAt: DateTime.tryParse(occurredAt)?.toUtc() ?? now,
      rawMessage: '',
      parseConfidence: (row['confidence'] as num?)?.toDouble() ?? 0.0,
      // Direct-written needs_review captures land server-side as 'pending' —
      // keep that so the confirm flow still applies; everything else confirmed.
      status: row['status'] == 'pending'
          ? TransactionStatus.pending
          : TransactionStatus.confirmed,
      createdAt: now,
      updatedAt: now,
    );
  }

  /// Resolves the LOCAL account a pulled transaction belongs to.
  /// `server_account_id` is authoritative: it survives sign-out wipes because
  /// the accounts pull re-attaches `accounts.server_id` on import. The raw
  /// `local_account_id` is only trusted when that account actually exists
  /// locally. Returns null (unassigned) otherwise — visible via the
  /// currency-scoped fallback, unlike a dangling account reference.
  Future<String?> _resolveLocalAccountId(Map<String, dynamic> row) async {
    final serverAccountId = row['server_account_id'] as String?;
    if (serverAccountId != null) {
      final cache = _accountServerToLocal;
      if (cache != null) {
        final hit = cache[serverAccountId];
        if (hit != null) return hit;
      } else {
        final match = await _db
            .customSelect(
              'SELECT id FROM accounts '
              'WHERE server_id = ${sqlString(serverAccountId)} '
              'AND deleted_at IS NULL LIMIT 1;',
            )
            .getSingleOrNull();
        if (match != null) return match.read<String>('id');
      }
    }
    final localAccountId = row['local_account_id'] as String?;
    if (localAccountId != null && await _localAccountExists(localAccountId)) {
      return localAccountId;
    }
    return null;
  }

  /// Resolves the server's stable category KEY to the local category id
  /// (categories are keyed by stable strings across devices).
  Future<String?> _localCategoryIdForKey(String? key) async {
    if (key == null || key.isEmpty) return null;
    final cache = _categoryKeyToLocal;
    if (cache != null) return cache[key];
    final row = await _db
        .customSelect(
          'SELECT id FROM categories WHERE key = ${sqlString(key)} LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.read<String>('id');
  }

  Future<bool> _localAccountExists(String id) async {
    final cache = _localAccountIds;
    if (cache != null) return cache.contains(id);
    final row = await _db
        .customSelect(
          'SELECT 1 AS x FROM accounts '
          'WHERE id = ${sqlString(id)} AND deleted_at IS NULL LIMIT 1;',
        )
        .getSingleOrNull();
    return row != null;
  }

  /// Server `metadata` is jsonb (a Map from postgrest); pull the card last4 out
  /// of it, tolerating a missing/oddly-typed value.
  String? _last4FromMetadata(dynamic metadata) {
    if (metadata is Map && metadata['last4'] != null) {
      return metadata['last4'].toString();
    }
    return null;
  }

  /// MALI-056n — read a canonical string from the server `metadata` JSONB.
  String? _canonicalMeta(dynamic metadata, String key) =>
      metadata is Map ? metadata[key] as String? : null;
}

/// Number of pulled transaction rows parked for an identity-integrity error
/// (WP-4, §4.11). Counts only; never row content.
Future<int> ledgerIntegrityQuarantineCount(AppDatabase db) async {
  final r = await db
      .customSelect(
        "SELECT COUNT(*) AS n FROM parked_child_rows "
        "WHERE table_name = 'transactions' AND reason = 'integrity';",
      )
      .getSingle();
  return r.read<int>('n');
}

enum _RowOutcome {
  imported,
  updated,
  tombstoned,
  conflict,
  skipped,
  quarantined,
}
