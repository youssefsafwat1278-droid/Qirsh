import 'dart:convert';

import '../../../core/session/account_fence_authority.dart';
import '../../../core/session/account_fence_store.dart';

import '../../../core/sync/outbox_failure.dart';
import '../../../core/sync/outbox_owner.dart';
import '../../../core/utils/id_generator.dart';
import '../../../core/sync/outbox_operation_id.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../data/sync/transaction_server_mappers.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/finance/money.dart';
import '../../../domain/finance/money_transport.dart';
import 'ledger_payload.dart';

enum OutboxOperation { create, update, delete }

class OutboxItem {
  const OutboxItem({
    required this.id,
    required this.transactionId,
    required this.operation,
    required this.payloadJson,
    required this.attemptCount,
    this.opSeq = 0,
    this.operationId,
    this.baseRevision,
    this.ownerUid,
    this.lastError,
    this.nextRetryAt,
  });

  final String id;
  final String transactionId;
  final OutboxOperation operation;
  final Map<String, dynamic> payloadJson;
  final int attemptCount;

  /// A-2 (G3): the row's edit counter when it was read. An ACK deletes the row
  /// only while this still matches, so an edit folded in while the push was in
  /// flight is never lost.
  final int opSeq;

  /// WP-5: the operation receipt id (the server's `last_op_id`). Regenerated
  /// whenever the row is edited; a retry of the same op_seq reuses it, so a lost
  /// ACK is recognised instead of reported as a conflict.
  final String? operationId;

  /// WP-5: the server revision the edit was made against (CAS base).
  final int? baseRevision;

  /// Operation ids this row carried earlier while possibly on the wire.
  List<String> get priorOpIds => priorOpIdsOf(payloadJson);

  /// A-2 (G18): the local-data owner the row was recorded for (null = legacy).
  final String? ownerUid;
  final String? lastError;
  final DateTime? nextRetryAt;
}

class LedgerOutboxQueue {
  LedgerOutboxQueue({
    required AppDatabase db,
    required bool Function() isPushEnabled,
    required Future<String?> Function() getAuthUserId,
    // A-2 (G18/G5): the LOCAL DATA OWNER uid (AppSession's owner marker) — the
    // identity admitted as owner of this local DB. Rows are stamped with it and
    // intent is recorded whenever it exists, even if the live session is
    // momentarily absent. Defaults to [getAuthUserId] for callers that have no
    // separate owner concept.
    Future<String?> Function()? getOwnerUid,
    void Function()? onQueued,
    // MALI-026 (B8-2.10 §10): the money-authority mode. Legacy (v29 today) emits
    // the current JSON-number wire shape; canonical emits the exact decimal
    // STRING. Defaults to legacy, so today's payloads are byte-identical.
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  })  : _db = db,
        _isPushEnabled = isPushEnabled,
        _getAuthUserId = getAuthUserId,
        _getOwnerUid = getOwnerUid ?? getAuthUserId,
        _onQueued = onQueued,
        _coordinator = coordinator;

  final AppDatabase _db;
  final bool Function() _isPushEnabled;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getOwnerUid;
  final void Function()? _onQueued;
  final PlanningCutoverCoordinator _coordinator;

  Future<void> enqueue(
    OutboxOperation op,
    TransactionEntity tx,
  ) async {
    // A-2 (G5): a local mutation records sync intent whenever a local owner
    // identity exists — even with no live session right now or the push flag off
    // (the push service still requires both before anything is sent). ONLY a
    // true guest (no owner uid and no session) stays local-only with no intent.
    final intent = await resolveOutboxIntent(_getOwnerUid, _getAuthUserId);
    if (intent == null) return;
    final ownerUid = intent.ownerUid;

    final now = dateTimeToSql(DateTime.now().toUtc());
    final payload = _buildPayload(op, tx);

    // MALI-022 / 0068 — attach the locally-cached server revision as the CAS
    // base token. Phase-9K: deletes carry it too, so the tombstone is a GUARDED
    // compare-and-set (a stale delete can never overwrite a newer accepted
    // update), not an unconditional overwrite. Null (unknown revision) is left
    // absent → the push uses the guarded server_updated_at compare.
    final revRow = await _db
        .customSelect(
          'SELECT server_revision FROM transactions '
          'WHERE id = ${sqlString(tx.id)} LIMIT 1;',
        )
        .getSingleOrNull();
    final baseRevision = revRow?.readNullable<int>('server_revision');
    if (baseRevision != null) payload['server_revision'] = baseRevision;

    await _db.transaction(() async {
      // MALI-052n: coalesce into any existing PENDING row for this transaction
      // (or a row parked by the A-2 self-healing layer, which is never in
      // flight). Every coalesce bumps op_seq (A-2 G3).
      final existing = await _db
          .customSelect(
            "SELECT id, operation, status, failure_class, in_flight_seq, operation_id, payload_json FROM ledger_sync_outbox "
            "WHERE transaction_id = ${sqlString(tx.id)} AND ($kOutboxCoalescibleSql OR (status = 'parked' AND failure_class = '$kParkAccountDeletionGone')) "
            "AND ${outboxOwnerMatchSql(ownerUid)} "
            "ORDER BY created_at ASC LIMIT 1;",
          )
          .getSingleOrNull();
      if (existing != null) {
        final existingId = existing.read<String>('id');
        final deletionHeld = existing.read<String>('status') == 'parked' &&
            const {kParkAccountDeletionPending, kParkAccountDeletionGone}
                .contains(existing.readNullable<String>('failure_class'));
        final coalesced = coalesceOutboxOperation(
            existing.read<String>('operation'), op.name);
        // WP-5: the edited row gets a NEW operation id; the previous one is
        // remembered only if it may already have reached the server.
        withPriorOpIds(
          payload,
          existingPayloadJson: existing.read<String>('payload_json'),
          previousOpId: existing.readNullable<String>('operation_id'),
          possiblySent: existing.readNullable<int>('in_flight_seq') != null,
        );
        if (!deletionHeld && coalesced == null &&
            existing.readNullable<int>('in_flight_seq') == null) {
          // Never on the wire (never handed to a push — the durable
          // in_flight_seq marker is NULL; D-6: a PARKED row keeps the marker, so
          // parking alone never proves it was not sent): create+delete cancels.
          await _db.customStatement(
            'DELETE FROM ledger_sync_outbox WHERE id = ${sqlString(existingId)};',
          );
        } else {
          // A-2 (G3): a create cancelled by a delete while it is IN FLIGHT is
          // never dropped — it becomes a delete. The push resolves it by
          // client_request_id: confirmed-absent is ACKed, a row that landed is
          // tombstoned. Nothing is silently lost.
          await _db.customStatement('''
            UPDATE ledger_sync_outbox
            SET operation = ${sqlString(coalesced ?? 'delete')},
                payload_json = ${sqlString(jsonEncode(payload))},
                attempt_count = ${deletionHeld ? 'attempt_count' : '0'},
                status = ${sqlString(deletionHeld ? 'parked' : 'pending')},
                failure_class = ${sqlNullableString(deletionHeld ? existing.readNullable<String>('failure_class') : null)},
                last_error = NULL, next_retry_at = NULL,
                op_seq = op_seq + 1,
                operation_id = ${sqlString(IdGenerator.uuidV4())},
                base_revision = ${baseRevision ?? 'NULL'},
                owner_uid = COALESCE(owner_uid, ${sqlNullableString(ownerUid)}),
                updated_at = ${sqlString(now)}
            WHERE id = ${sqlString(existingId)};
          ''');
        }
      } else {
        await _db.customStatement('''
          INSERT INTO ledger_sync_outbox(
            id, transaction_id, operation, payload_json,
            attempt_count, status, created_at, updated_at, op_seq, owner_uid,
            operation_id, base_revision
          ) VALUES (
            ${sqlString(IdGenerator.next())}, ${sqlString(tx.id)},
            ${sqlString(op.name)}, ${sqlString(jsonEncode(payload))},
            0, 'pending', ${sqlString(now)}, ${sqlString(now)},
            1, ${sqlNullableString(ownerUid)},
            ${sqlString(IdGenerator.uuidV4())}, ${baseRevision ?? 'NULL'}
          );
        ''');
      }
      await _db.customStatement('''
        UPDATE transactions
        SET sync_status = 'pending'
        WHERE id = ${sqlString(tx.id)};
      ''');
    });
    if (_isPushEnabled()) _onQueued?.call();
  }

  Future<List<OutboxItem>> pendingItems({int limit = 50}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    // A-3: hand-out and the durable "possibly sent" marker are ONE transaction.
    final rows = await _db.transaction(() async {
      final picked = await _db.customSelect('''
        SELECT id, transaction_id, operation, payload_json,
               attempt_count, last_error, next_retry_at, op_seq, owner_uid,
               operation_id, base_revision
        FROM ledger_sync_outbox
        WHERE status = 'pending'
          AND (next_retry_at IS NULL OR next_retry_at <= ${sqlString(now)})
          -- D-1: an entity awaiting the user's conflict resolution is never pushed.
          AND NOT EXISTS (
            SELECT 1 FROM transactions t
            WHERE t.id = ledger_sync_outbox.transaction_id
              AND t.sync_status = 'conflict')
        ORDER BY created_at ASC
        LIMIT $limit;
      ''').get();
      for (final row in picked) {
        await _db.customStatement(
          'UPDATE ledger_sync_outbox SET in_flight_seq = op_seq, '
          // WP-5: rows queued before v41 get their operation id here, before
          // anything is sent.
          'operation_id = COALESCE(operation_id, ${sqlString(IdGenerator.uuidV4())}) '
          'WHERE id = ${sqlString(row.read<String>('id'))};',
        );
      }
      return [
        for (final row in picked)
          (await _db
              .customSelect(
                  'SELECT operation_id FROM ledger_sync_outbox WHERE id = '
                  '${sqlString(row.read<String>('id'))};')
              .getSingle()
              .then((r) => (row, r.read<String>('operation_id')))),
      ];
    });
    return rows.map((pair) {
      final row = pair.$1;
      final opStr = row.read<String>('operation');
      final op = OutboxOperation.values.firstWhere(
        (e) => e.name == opStr,
        orElse: () => OutboxOperation.update,
      );
      final retryStr = row.readNullable<String>('next_retry_at');
      return OutboxItem(
        id: row.read<String>('id'),
        transactionId: row.read<String>('transaction_id'),
        operation: op,
        payloadJson:
            (jsonDecode(row.read<String>('payload_json')) as Map).cast(),
        attemptCount: row.read<int>('attempt_count'),
        opSeq: row.read<int>('op_seq'),
        operationId: pair.$2,
        baseRevision: row.readNullable<int>('base_revision'),
        ownerUid: row.readNullable<String>('owner_uid'),
        lastError: row.readNullable<String>('last_error'),
        nextRetryAt:
            retryStr == null ? null : DateTime.tryParse(retryStr)?.toUtc(),
      );
    }).toList();
  }

  /// A-2 (G3): ACK [item]. The row is deleted ONLY while its `op_seq` still
  /// equals the one that was pushed. If the entity was edited while the push was
  /// in flight the edit was folded into this same row (op_seq bumped): the row
  /// stays pending, carrying the server id/version this ACK just produced as its
  /// new base, so the next cycle is an UPDATE of the same server row — and the
  /// caller must NOT mark the entity synced. Returns true when the row was
  /// consumed.
  Future<bool> acknowledge(
    OutboxItem item, {
    String? serverId,
    String? serverUpdatedAt,
    int? serverRevision,
  }) {
    return _db.transaction(() async {
      final deleted = await _db.customUpdate(
        'DELETE FROM ledger_sync_outbox '
        'WHERE id = ${sqlString(item.id)} AND op_seq = ${item.opSeq};',
      );
      if (deleted > 0) return true;
      final row = await _db
          .customSelect(
            'SELECT operation, payload_json FROM ledger_sync_outbox '
            'WHERE id = ${sqlString(item.id)} LIMIT 1;',
          )
          .getSingleOrNull();
      if (row == null) return false;
      final payload =
          (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
      if (serverId != null) payload['server_id'] = serverId;
      // D-1: base tokens are replaced ONLY when this ACK produced new ones. A
      // token-less ACK (conflict / idempotent delete) must keep the existing
      // base: stripping it made the next push fetch the server's CURRENT token
      // and overwrite the other device's edit.
      if (serverUpdatedAt != null) {
        payload['server_updated_at'] = canonicalServerTimestamp(serverUpdatedAt);
      }
      if (serverRevision != null) {
        payload['server_revision'] = serverRevision;
      }
      final op = row.read<String>('operation');
      final now = dateTimeToSql(DateTime.now().toUtc());
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET payload_json = ${sqlString(jsonEncode(payload))},
            operation = ${sqlString(op == 'create' && serverId != null ? 'update' : op)},
            ${serverRevision != null ? 'base_revision = $serverRevision,' : ''}
            attempt_count = 0, next_retry_at = NULL, in_flight_seq = NULL,
            updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(item.id)};
      ''');
      return false;
    });
  }

  /// WP-5: nothing was written (stale epoch) — the row is simply not in flight.
  Future<void> releaseInFlight(String id) => _db.customStatement(
      'UPDATE ledger_sync_outbox SET in_flight_seq = NULL '
      'WHERE id = ${sqlString(id)};');

  /// ACK without a server row to persist (conflict/abandon/idempotent delete).
  Future<bool> markSuccess(OutboxItem item) => acknowledge(item);

  /// A-2 (G18): park rows recorded for another owner / unverified legacy rows,
  /// and re-arm the ones whose owner is the current identity again. Runs at the
  /// start of every push cycle, so nothing is ever sent under a different uid.
  Future<void> reconcileOwnership(String currentUid) async {
    final verified = await ownershipVerified(currentUid);
    await reconcileVerifiedOwnership(currentUid, verified);
  }

  Future<bool> ownershipVerified(String currentUid) =>
      isOutboxOwnerVerified(_getOwnerUid, currentUid);

  Future<void> reconcileVerifiedOwnership(String currentUid, bool verified) async {
    await reconcileOutboxOwnership(
      db: _db,
      table: 'ledger_sync_outbox',
      currentUid: currentUid,
      ownershipVerified: verified,
    );
  }

  /// The same queued snapshot must still own the mutation before every retry.
  Future<bool> accountFenceCurrent(OutboxItem item) async {
    final row = await _db.customSelect(
      "SELECT 1 FROM ledger_sync_outbox WHERE id = ${sqlString(item.id)} "
      "AND status = 'pending' AND op_seq = ${item.opSeq} "
      "AND in_flight_seq = ${item.opSeq} "
      "AND operation_id = ${sqlNullableString(item.operationId)} "
      "AND owner_uid IS ${sqlNullableString(item.ownerUid)};").getSingleOrNull();
    return row != null;
  }

  /// A refusal is not an ACK or business attempt. Preserve payload, operation
  /// identity and ALL possibly-sent history. A stale outcome cannot overwrite
  /// a newer in-flight holder. A queued edit may inherit QD001's same-row hold.
  Future<bool> recordAccountFenceFailure(OutboxItem item,
      OutboxFailureClass failure, DateTime retryAt) async {
    final pending = failure == OutboxFailureClass.accountDeletionPending;
    final now = dateTimeToSql(DateTime.now().toUtc());
    final changed = await _db.customUpdate("""
      UPDATE ledger_sync_outbox
      SET status = '${pending ? 'parked' : 'pending'}',
          failure_class = ${sqlString(failure.reason)}, last_error = NULL,
          next_retry_at = ${pending ? 'NULL' : sqlString(dateTimeToSql(retryAt.toUtc()))},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(item.id)} AND status = 'pending'
        AND owner_uid IS ${sqlNullableString(item.ownerUid)}
        AND ${pending
          ? 'in_flight_seq = ${item.opSeq}'
          : 'op_seq = ${item.opSeq} AND in_flight_seq = ${item.opSeq} AND operation_id = ${sqlNullableString(item.operationId)}'};
    """);
    return changed > 0;
  }

  /// Only an authority-issued one-use ticket can finalize after retirement.
  Future<bool> parkAccountDenial(OutboxItem item, AccountFenceState state,
      AccountFenceParking ticket) async {
    ticket.requireExact(_db, rowId: item.id, transactionId: item.transactionId,
        ownerUid: item.ownerUid, opSeq: item.opSeq,
        operationId: item.operationId, state: state);
    final reason = state == AccountFenceState.gone
        ? kParkAccountDeletionGone : kParkAccountDeletionPending;
    final changed = await _db.customUpdate("""
      UPDATE ledger_sync_outbox
      SET status = 'parked', failure_class = ${sqlString(reason)},
          last_error = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
      WHERE id = ${sqlString(item.id)} AND transaction_id = ${sqlString(item.transactionId)}
        AND status = 'pending' AND owner_uid IS ${sqlNullableString(item.ownerUid)}
        AND in_flight_seq = ${item.opSeq};
    """);
    return changed > 0;
  }

  /// MALI-023: typed failure handling. Permanent failures dead-letter
  /// immediately (no retry storm). Retryable failures use bounded exponential
  /// backoff and dead-letter after [kOutboxMaxAttempts]. Conflicts are handled
  /// by the push (markConflict), never here.
  Future<void> markFailed(
    String id,
    String error,
    OutboxFailureClass failureClass,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT attempt_count FROM ledger_sync_outbox WHERE id = ${sqlString(id)} LIMIT 1;',
        )
        .getSingleOrNull();
    if (row == null) return;
    final now = dateTimeToSql(DateTime.now().toUtc());

    // A-3: the marker is cleared on a definite outcome. A transport/5xx failure
    // is AMBIGUOUS (the request may have landed), so the row stays possibly-sent.
    if (failureClass != OutboxFailureClass.transientNetwork &&
        failureClass != OutboxFailureClass.serverError) {
      await _db.customStatement(
        'UPDATE ledger_sync_outbox SET in_flight_seq = NULL WHERE id = ${sqlString(id)};',
      );
    }

    // A-5: an auth rejection is not this row's fault and not a retry — park it
    // WITHOUT consuming an attempt; re-armed on the next authenticated session /
    // token refresh or an explicit Retry. The raw error is not retained.
    if (failureClass == OutboxFailureClass.auth) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'parked', failure_class = '$kParkAuthRequired',
            last_error = NULL, next_retry_at = NULL, in_flight_seq = NULL,
            updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)} AND status = 'pending';
      ''');
      return;
    }

    if (failureClass.isPermanent) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'dead_letter', failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final attempts = row.read<int>('attempt_count') + 1;
    if (attempts >= kOutboxMaxAttempts) {
      await _db.customStatement('''
        UPDATE ledger_sync_outbox
        SET status = 'dead_letter', attempt_count = $attempts,
            failure_class = ${sqlString(failureClass.reason)},
            last_error = ${sqlString(error)}, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(id)};
      ''');
      return;
    }

    final nextRetry = dateTimeToSql(
      DateTime.now().toUtc().add(Duration(seconds: _backoff(attempts))),
    );
    await _db.customStatement('''
      UPDATE ledger_sync_outbox
      SET attempt_count = $attempts, failure_class = ${sqlString(failureClass.reason)},
          last_error = ${sqlString(error)}, next_retry_at = ${sqlString(nextRetry)},
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)};
    ''');
  }

  /// MALI-023: re-arm dead-lettered rows (e.g. after an app/schema upgrade that
  /// may fix a previously-permanent failure). Returns the number re-armed.
  Future<int> reArmDeadLetter() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE status = 'dead_letter';
    ''');
  }

  /// A-5: user-triggered Retry — re-arms every dead letter that a retry can
  /// plausibly fix; business-rule duplicates and unsupported operations stay
  /// dead-lettered ([kRetryableDeadLetterSql]). Returns the number re-armed.
  Future<int> reArmRetryableDeadLetters() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', attempt_count = 0, next_retry_at = NULL,
          failure_class = NULL, updated_at = ${sqlString(now)}
      WHERE $kRetryableDeadLetterSql;
    ''');
  }

  /// A-5: re-arm rows parked `auth_required` (authenticated session restored or
  /// Retry). The SAME durable rows; no attempt was ever consumed. Also clears the
  /// backoff of pending rows so a user Retry runs them now.
  Future<int> reArmAuthParked() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked' AND failure_class = '$kParkAuthRequired';
    ''');
  }

  /// A-5: Retry-now — drop the backoff wait of pending rows (no attempt reset).
  Future<int> clearRetryBackoff() => _db.customUpdate(
        "UPDATE ledger_sync_outbox SET next_retry_at = NULL "
        "WHERE status = 'pending' AND next_retry_at IS NOT NULL "
        "AND COALESCE(failure_class, '') != '$kFailAccountFenceContention';",
      );

  /// MALI-026 (B8-2.10 §8): park a canonical money row whose exact push transport
  /// is unverified. Reuses the Phase-3 status+reason model: a distinct `parked`
  /// status (excluded from [pendingItems], so never sent/retried) carrying the
  /// [reason]. The local write already stands; the row is retained DURABLY, is
  /// NOT marked synced, and does NOT consume a retry attempt. Only pending rows
  /// park (a dead-lettered row stays dead-lettered).
  /// Returns true when the row was parked (false: it was no longer pending, or
  /// [ifOpSeq] no longer matched because an edit was folded in meanwhile).
  Future<bool> park(String id, String reason, {int? ifOpSeq}) async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    final n = await _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'parked', failure_class = ${sqlString(reason)},
          last_error = NULL, next_retry_at = NULL, in_flight_seq = NULL,
          updated_at = ${sqlString(now)}
      WHERE id = ${sqlString(id)} AND status = 'pending'
        ${ifOpSeq == null ? '' : 'AND op_seq = $ifOpSeq'};
    ''');
    return n > 0;
  }

  /// A-6: true when [payload] is an awaiting-FX create/update body — amount 0
  /// with a positive foreign amount and a foreign currency. The server only
  /// accepts that shape once `awaiting_fx_transactions` is verified.
  static bool isAwaitingFxPayload(Map<String, dynamic> payload) {
    num? n(Object? v) => v is num ? v : (v is String ? num.tryParse(v) : null);
    final amount = n(payload['amount']);
    final foreign = n(payload['foreign_amount']);
    return amount != null &&
        amount == 0 &&
        foreign != null &&
        foreign > 0 &&
        payload['foreign_currency'] is String;
  }

  /// The outbox row id recorded for [transactionId] (most recent), if any.
  Future<String?> outboxRowIdForTransaction(String transactionId) async {
    final row = await _db
        .customSelect(
          'SELECT id FROM ledger_sync_outbox '
          'WHERE transaction_id = ${sqlString(transactionId)} '
          'ORDER BY created_at DESC LIMIT 1;',
        )
        .getSingleOrNull();
    return row?.read<String>('id');
  }

  /// A-6: whether any row is parked awaiting server FX support.
  Future<bool> hasAwaitingFxParked() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM ledger_sync_outbox WHERE status = 'parked' "
          "AND failure_class = ${sqlString(kParkAwaitingServerFxSupport)};",
        )
        .getSingle();
    return row.read<int>('n') > 0;
  }

  /// A-6: the server now accepts awaiting-FX rows — re-arm the rows parked for
  /// that reason (same durable rows, no attempt consumed).
  Future<int> reArmAwaitingFxParked() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked'
        AND failure_class = ${sqlString(kParkAwaitingServerFxSupport)};
    ''');
  }

  /// A-6: recover awaiting-FX creates/updates dead-lettered by the server CHECK
  /// (amount > 0) before this build: move them to parked
  /// `awaiting_server_fx_support`. Only rows whose failure was the CHECK class
  /// (or legacy `permanentValidation` from SQLSTATE 23514) AND whose payload is
  /// awaiting-FX shaped, and only when no newer active row exists for the same
  /// transaction. Every other dead letter is left untouched. Returns the count.
  Future<int> recoverAwaitingFxDeadLetters() async {
    final rows = await _db.customSelect('''
      SELECT d.id, d.payload_json FROM ledger_sync_outbox d
      WHERE d.status = 'dead_letter' AND d.operation != 'delete'
        AND (d.failure_class = ${sqlString(kFailServerCheckViolation)}
             OR (d.failure_class = ${sqlString(OutboxFailureClass.permanentValidation.reason)}
                 AND d.last_error LIKE '%23514%'))
        AND NOT EXISTS (
          SELECT 1 FROM ledger_sync_outbox o
          WHERE o.transaction_id = d.transaction_id
            AND o.status IN ('pending', 'parked'));
    ''').get();
    var recovered = 0;
    final now = dateTimeToSql(DateTime.now().toUtc());
    for (final row in rows) {
      final payload =
          (jsonDecode(row.read<String>('payload_json')) as Map).cast<String, dynamic>();
      if (!isAwaitingFxPayload(payload)) continue;
      recovered += await _db.customUpdate('''
        UPDATE ledger_sync_outbox
        SET status = 'parked', failure_class = ${sqlString(kParkAwaitingServerFxSupport)},
            attempt_count = 0, last_error = NULL, next_retry_at = NULL,
            in_flight_seq = NULL, updated_at = ${sqlString(now)}
        WHERE id = ${sqlString(row.read<String>('id'))} AND status = 'dead_letter';
      ''');
    }
    return recovered;
  }

  /// MALI-026 (B8-2.10 §9): re-arm parked rows once exact push transport is
  /// verified. The SAME durable rows become drainable again (their payload was
  /// already built as the exact decimal string). Returns the number re-armed.
  Future<int> reArmParked() async {
    final now = dateTimeToSql(DateTime.now().toUtc());
    return _db.customUpdate('''
      UPDATE ledger_sync_outbox
      SET status = 'pending', failure_class = NULL, next_retry_at = NULL,
          updated_at = ${sqlString(now)}
      WHERE status = 'parked'
        AND COALESCE(failure_class, '') NOT IN $kOutboxSelfHealingParkReasonsSql
        AND COALESCE(failure_class, '') NOT IN ('$kParkAccountDeletionPending', '$kParkAccountDeletionGone');
    ''');
  }

  /// Parked-row count for diagnostics (no financial payload exposed).
  Future<int> parkedCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM ledger_sync_outbox WHERE status = 'parked';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  /// Queue health for diagnostics (no financial payload exposed).
  Future<int> deadLetterCount() async {
    final row = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM ledger_sync_outbox WHERE status = 'dead_letter';",
        )
        .getSingle();
    return row.read<int>('n');
  }

  // Capped exponential backoff (30s → ~64min) for retryable failures.
  static int _backoff(int attempt) => 30 * (1 << (attempt - 1).clamp(0, 7));

  Map<String, dynamic> _buildPayload(OutboxOperation op, TransactionEntity tx) {
    if (op == OutboxOperation.delete) {
      return {
        'local_id': tx.id,
        'server_id': tx.serverId,
        // Phase-9K optimistic base token: the guarded tombstone compares this
        // against the live server row when the CAS revision is unknown, so a
        // stale delete never clobbers a newer accepted update.
        'server_updated_at': tx.serverUpdatedAt?.toUtc().toIso8601String(),
      };
    }

    // MALI-026 (B8-2.10 §10): canonical mode serializes money as the EXACT
    // decimal STRING (Money -> moneyToNumericText -> NUMERIC); legacy mode keeps
    // the JSON-number shape. No Money.toDouble() ever runs on the canonical path.
    final canonical = _coordinator.state() == PlanningCutoverState.canonical;
    Object amountWire(Money m) =>
        canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
    Object? amountWireOrNull(Money? m) => canonical
        ? moneyToNumericTextOrNull(m)
        : moneyToLegacyJsonNumberOrNull(m);

    final payload = <String, dynamic>{
      'local_id': tx.id,
      'server_id': tx.serverId,
      'amount': amountWire(tx.amountMoney),
      'currency': tx.currency,
      'type': _mapType(tx.type),
      'merchant': tx.rawMerchant,
      'note': tx.note,
      'occurred_at': tx.occurredAt.toUtc().toIso8601String(),
      'account_id': tx.accountId,
      'card_last4': tx.cardLast4,
      'confidence': tx.parseConfidence,
      // Fields the push previously dropped — without these the server row lands
      // with no category, empty metadata and no card link, so a sync round-trip
      // (2nd device / reinstall) returns the transaction uncategorized and
      // unlinked. Kept in parity with TransactionsBackfillService.
      'category_id': tx.categoryId,
      'balance_after': amountWireOrNull(tx.balanceAfterMoney),
      'foreign_amount': amountWireOrNull(tx.foreignMoney),
      'foreign_currency': tx.foreignCurrency,
      // Confirmation state must round-trip (MALI-010): without it a locally
      // confirmed relay capture stays 'pending' on the server and re-imports
      // as pending on every other device.
      'status': tx.status.name,
      // Optimistic-concurrency base token (MALI-009): the server version this
      // change was made against. The push conflict check compares it with the
      // live row before updating — omitted, the check could never fire.
      'server_updated_at': tx.serverUpdatedAt?.toUtc().toIso8601String(),
      // MALI-056n — the explicit, versioned canonical payload. These preserve
      // the EXACT type/source/direction through the server round-trip (the
      // coarse server columns cannot). The legacy 'type' above is kept for
      // downgrade safety (an older build ignores these and reads 'type').
      'payload_version': kLedgerPayloadVersion,
      'canonical_type': tx.type.name,
      'canonical_source': tx.source.name,
      // Null direction is carried as absent → the pull derives it from the
      // canonical type (lossless for income/refund/payment/withdrawal).
      'canonical_direction': tx.direction?.name,
      // Who chose the category. Sent to the server only once it advertises
      // `transaction_category_source` (see LedgerPushService._toServerRow).
      'category_source': tx.categoryProvenance?.name,
      // Came in through a file import (sticky; separate from source).
      'imported_from_file': tx.importedFromFile,
    };

    // Include source only for create operations.
    // For updates, omitting source means the server row keeps its original value
    // (e.g. 'ios_shortcut' for relay-imported transactions via process-ios-sms).
    if (op == OutboxOperation.create) {
      payload['source'] = _mapSource(tx.source);
    }

    return payload;
  }

  static String _mapType(TransactionTypeEntity type) => switch (type) {
        TransactionTypeEntity.income => 'credit',
        TransactionTypeEntity.transfer => 'transfer',
        // Refund must survive the round-trip (MALI-010): collapsing it to
        // 'debit' made the server store it as an EXPENSE, flipping its
        // meaning on every other device. The server accepts 'refund'
        // (migration 0022's transaction_type check).
        TransactionTypeEntity.refund => 'refund',
        _ => 'debit',
      };

  // Every create carries its real provenance via the canonical server mapping:
  // captured transactions push as their true source (bank/card/ai → import/
  // share_extension), manual adds as 'manual'. Updates strip source (see
  // LedgerPushService._pushUpdate) so a server source already set by the relay
  // is never clobbered.
  static String _mapSource(TransactionSourceEntity source) =>
      transactionSourceToServer(source);
}
