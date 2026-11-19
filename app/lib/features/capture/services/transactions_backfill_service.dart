import 'package:drift/drift.dart' show Variable;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/backend/supabase_config.dart';
import '../../../core/session/app_session.dart';
import '../../../core/sync/outbox_failure.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/money_codec.dart';
import '../../../data/db/planning_cutover.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_transaction_repository.dart';
import '../../../domain/finance/money.dart';
import '../../../data/sync/transaction_server_mappers.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../../../domain/finance/money_transport.dart';
import 'ledger_outbox_queue.dart';
import 'ledger_payload.dart';

const _transactionMoneySelect =
    '*, amount_text:amount::text, balance_after_text:balance_after::text, '
    'foreign_amount_text:foreign_amount::text';

class TransactionBackfillReport {
  const TransactionBackfillReport({
    required this.total,
    required this.created,
    required this.matched,
    required this.mismatchedLocalIds,
    required this.unresolvedAccountLocalIds,
    this.queuedAwaitingFxLocalIds = const [],
    this.failedLocalIds = const [],
    this.hasMore = false,
  });

  final int total;
  final int created;
  final int matched;
  final List<String> mismatchedLocalIds;
  final List<String> unresolvedAccountLocalIds;

  /// A-6: awaiting-FX rows (amount 0 + foreign amount) are never sent directly;
  /// they were handed to the ledger outbox (parked until the server is verified
  /// to accept them). Not unresolved — the outbox owns them.
  final List<String> queuedAwaitingFxLocalIds;

  /// Rows the server rejected permanently (CHECK / business key / schema). They
  /// were recorded as outbox dead letters (observable) and the run continued.
  final List<String> failedLocalIds;

  /// The run stopped at its row/time budget with rows left to process. Not
  /// clean: the next cycle continues (already-sent rows are marked synced).
  final bool hasMore;

  bool get isClean =>
      !hasMore &&
      mismatchedLocalIds.isEmpty &&
      unresolvedAccountLocalIds.isEmpty &&
      failedLocalIds.isEmpty;
}

/// يُرحِّل كل العمليات المحلية (Drift) إلى user_transactions — بلا ثقة
/// بعمود sync_status، ويشمل العمليات المحذوفة محليًا (status='ignored')
/// حتى لا تُعاد كعمليات نشطة لاحقًا. يجب ألا يبدأ قبل نجاح واكتمال
/// AccountsBackfillService والتحقق منه (كل حساب محلي غير محذوف له server_id).
class TransactionsBackfillService {
  TransactionsBackfillService({
    required AppDatabase db,
    SupabaseClient Function()? getClient,
    Future<String?> Function()? getAuthUserId,
    Future<String?> Function()? getLocalDataOwnerUid,
    // MALI-026 (B8-3 §12): defaults to schema-v29 legacy — the historical
    // backfill keeps the JSON-number wire shape until canonical, matching the
    // LedgerOutboxQueue. At canonical it serializes money as the EXACT decimal
    // STRING (never a JSON number for a canonical Money push).
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    LedgerOutboxQueue? outboxQueue,
  })  : _db = db,
        _outboxOverride = outboxQueue,
        _getClient = getClient ?? (() => Supabase.instance.client),
        _getAuthUserId = getAuthUserId ?? _defaultGetAuthUserId,
        _getLocalDataOwnerUid =
            getLocalDataOwnerUid ?? AppSession.instance.readLocalDataOwnerUid,
        _coordinator = coordinator;

  final AppDatabase _db;
  final SupabaseClient Function() _getClient;
  final Future<String?> Function() _getAuthUserId;
  final Future<String?> Function() _getLocalDataOwnerUid;
  final PlanningCutoverCoordinator _coordinator;
  final LedgerOutboxQueue? _outboxOverride;

  late final LedgerOutboxQueue _outbox = _outboxOverride ??
      LedgerOutboxQueue(
        db: _db,
        isPushEnabled: () => true,
        getAuthUserId: _getAuthUserId,
        getOwnerUid: _getLocalDataOwnerUid,
        coordinator: _coordinator,
      );

  static Future<String?> _defaultGetAuthUserId() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// يتحقق أن كل حساب محلي غير محذوف قد رُحِّل (له server_id) قبل السماح
  /// ببدء ترحيل العمليات — يرفض البدء بدل التخمين.
  Future<bool> accountsBackfillVerified() async {
    final unresolved = await _db
        .customSelect(
          "SELECT COUNT(*) AS n FROM accounts WHERE deleted_at IS NULL AND server_id IS NULL;",
        )
        .getSingle();
    return unresolved.read<int>('n') == 0;
  }

  /// دفاع في العمق: يرفض الترحيل إن كانت البيانات المحلية مسجَّلة كملك لهوية
  /// Supabase مختلفة عن الهوية الحالية — حماية إضافية إن فشل مسح تسجيل
  /// الخروج بصمت (انظر AppSession.signOut). `null` (لا تعارض معروف بعد) يُسمح
  /// به عمداً، وإلا لتعطّل أول ترحيل لمستخدم حالي قبل هذا التحديث.
  Future<void> _assertLocalDataOwnership(String uid) async {
    final ownerUid = await _getLocalDataOwnerUid();
    if (ownerUid != null && ownerUid != uid) {
      throw const ValidationRepoException(
        'Local transactions are recorded as owned by a different signed-in '
        'identity than the one currently authenticated — refusing to '
        'upload them to avoid cross-account data leakage.',
      );
    }
  }

  /// Rows read per keyset page (memory bound), independent of [run]'s send budget.
  static const int _pageRows = 200;

  /// Default per-run send budget.
  static const int defaultMaxRows = 200;

  Future<TransactionBackfillReport> run({
    int maxRows = defaultMaxRows,
    DateTime? deadline,
  }) async {
    final uid = await _getAuthUserId();
    if (uid == null) throw const AuthRepoException();
    await _assertLocalDataOwnership(uid);
    // No all-accounts gate: a transaction is only ever sent with a verified
    // account mapping. Rows whose account has no server_id (for example an
    // account the server rejected) are skipped into `unresolvedAccountLocalIds`
    // below, so one bad account never blocks the other accounts' history.

    // Only rows that never reached the server (server_id IS NULL). A pulled/
    // pushed row already exists server-side; re-pushing it here would mint a
    // DUPLICATE, because pull-imports regenerate the local id on every
    // sign-in cycle so 'backfill_transaction_<localId>' never matches the
    // existing server row (observed in production: one extra server copy of
    // every transaction per reconcile run — 6 → 12 rows).
    // Rows already queued on the ledger outbox are likewise the outbox push's
    // responsibility — it keys server rows on client_request_id = local_id.
    var scanned = 0;
    var attempted = 0;
    var hasMore = false;
    var lastId = '';

    var created = 0;
    var matched = 0;
    final mismatched = <String>[];
    final unresolvedAccounts = <String>[];
    final queuedAwaitingFx = <String>[];
    final failed = <String>[];

    // Bounded per run: at most [maxRows] rows are SENT (network) and the run
    // stops at [deadline]; rows are read in keyset pages (never SELECT * of the
    // whole history). Remaining work is reported as [hasMore] so the caller
    // returns `partial` and the next cycle continues — every row written is
    // marked synced/queued, so a continuation never re-sends or duplicates.
    pages:
    while (true) {
      final localRows = await _db.customSelect(
        'SELECT * FROM transactions t '
        'WHERE t.server_id IS NULL '
        'AND t.id NOT IN (SELECT transaction_id FROM ledger_sync_outbox) '
        'AND t.id > ? ORDER BY t.id LIMIT $_pageRows;',
        variables: [Variable.withString(lastId)],
      ).get();
      if (localRows.isEmpty) break;
      for (final local in localRows) {
        lastId = local.read<String>('id');
        if (attempted >= maxRows ||
            (deadline != null && DateTime.now().isAfter(deadline))) {
          hasMore = true;
          break pages;
        }
        scanned++;
        final localId = local.read<String>('id');
        final localAccountId = local.readNullable<String>('account_id');

        // A-6: an awaiting-FX row (amount 0 + foreign amount, including legacy
        // pending foreign-unpriced rows) must never be sent directly — the server
        // CHECK rejects it until migration 0102 is verified, and one such row used
        // to abort the whole run. Hand it to the ledger outbox, whose push applies
        // the capability / park rules (parked `awaiting_server_fx_support`).
        final probeCurrency = local.read<String>('currency');
        final probeForeignCurrency =
            local.readNullable<String>('foreign_currency');
        if (probeForeignCurrency != null &&
            kMoneyCodec.readColumn(local, 'amount', probeCurrency).isZero &&
            kMoneyCodec.readColumnNullable(
                    local, 'foreign_amount', probeForeignCurrency) !=
                null) {
          final entity = await _loadEntity(localId);
          if (entity != null) {
            await _outbox.enqueue(OutboxOperation.create, entity);
            queuedAwaitingFx.add(localId);
          } else {
            // Unreadable legacy row: never sent, never aborts the run.
            failed.add(localId);
          }
          continue;
        }

        String? serverAccountId;
        if (localAccountId != null) {
          final row = await _db.customSelect(
            'SELECT server_id FROM accounts WHERE id = ? LIMIT 1;',
            variables: [Variable.withString(localAccountId)],
          ).getSingleOrNull();
          serverAccountId = row?.readNullable<String>('server_id');
          if (serverAccountId == null) {
            // لا نخمّن العلاقة أبدًا — نتخطى هذا الصف ونبلّغ عنه.
            unresolvedAccounts.add(localId);
            continue;
          }
        }

        final categoryLocalId = local.readNullable<String>('category_id');
        final categoryKey = await _categoryKeyForLocalId(categoryLocalId);
        final direction =
            _directionFromSql(local.readNullable<String>('direction'));
        final type = TransactionTypeEntity.values.firstWhere(
            (t) => t.name == local.read<String>('type'),
            orElse: () => TransactionTypeEntity.unknown);
        final cardLast4 = local.readNullable<String>('card_last4');
        final isDeleted = local.read<String>('status') == 'ignored';
        final clientRequestId = 'backfill_transaction_$localId';
        final localCurrency = local.read<String>('currency');
        final localAmount =
            kMoneyCodec.readColumn(local, 'amount', localCurrency);
        final localBalance =
            kMoneyCodec.readColumnNullable(local, 'balance_after', localCurrency);
        final localForeignCurrency =
            local.readNullable<String>('foreign_currency');
        final localForeignAmount = localForeignCurrency == null
            ? null
            : kMoneyCodec.readColumnNullable(
                local,
                'foreign_amount',
                localForeignCurrency,
              );

        // §12: canonical mode serializes money as the EXACT decimal STRING
        // (Money -> moneyToNumericText -> NUMERIC); legacy keeps the JSON number.
        // Never a JSON-number for a canonical Money push; no Money.toDouble() runs
        // on the canonical path.
        final canonical = _coordinator.state() == PlanningCutoverState.canonical;
        Object amountWire(Money m) =>
            canonical ? moneyToNumericText(m) : moneyToLegacyJsonNumber(m);
        Object? amountWireOrNull(Money? m) => canonical
            ? moneyToNumericTextOrNull(m)
            : moneyToLegacyJsonNumberOrNull(m);
        final payload = <String, dynamic>{
          'user_id': uid,
          'client_request_id': clientRequestId,
          'amount': amountWire(localAmount),
          'currency': localCurrency,
          'merchant': local.readNullable<String>('raw_merchant'),
          'description': local.readNullable<String>('note'),
          'category_id': categoryKey,
          'occurred_at': dateTimeFromSql(local.read<String>('occurred_at'))
              .toIso8601String(),
          'source': transactionSourceToServer(
            TransactionSourceEntity.values.firstWhere(
              (s) => s.name == local.read<String>('source'),
              orElse: () => TransactionSourceEntity.unknown,
            ),
          ),
          'confidence': local.read<double>('parse_confidence'),
          'direction': transactionDirectionToServer(direction),
          'transaction_type': transactionTypeToServer(type, direction),
          'server_account_id': serverAccountId,
          'balance_after': amountWireOrNull(localBalance),
          'status': isDeleted ? 'ignored' : local.read<String>('status'),
          'foreign_amount': amountWireOrNull(localForeignAmount),
          'foreign_currency': localForeignCurrency,
          'comparison_timestamp':
              local.readNullable<String>('comparison_timestamp'),
          'comparison_timestamp_source':
              local.readNullable<String>('comparison_timestamp_source') ??
                  'received_at',
          'deleted_at': isDeleted ? dateTimeToSql(DateTime.now().toUtc()) : null,
          'metadata': {
            'transaction_source': local.read<String>('source'),
            if (cardLast4 != null) 'last4': cardLast4,
            if (local.readNullable<String>('transfer_group_id') != null)
              'transfer_group_id': local.read<String>('transfer_group_id'),
            if (local.readNullable<String>('transaction_time_from_sms') != null)
              'transaction_time_from_sms':
                  local.read<String>('transaction_time_from_sms'),
            if (local.readNullable<String>('sms_received_at') != null)
              'sms_received_at': local.read<String>('sms_received_at'),
            'duplicate_status':
                local.readNullable<String>('duplicate_status') ?? 'normal',
            if (local.readNullable<String>(
                    'possible_duplicate_of_transaction_id') !=
                null)
              'possible_duplicate_of_transaction_id':
                  local.read<String>('possible_duplicate_of_transaction_id'),
            if (local.readNullable<String>('duplicate_reason') != null)
              'duplicate_reason': local.read<String>('duplicate_reason'),
          },
        };

        attempted++;
        Map<String, dynamic> serverRow;
        try {
          // V1-020: the outbox push keys a server row on client_request_id =
          // the LOCAL id. A row that already reached the cloud that way (and
          // lost its server_id locally, e.g. through a backup restore) is bound
          // to that row and reconciled exactly like a backfill match below
          // (equal -> synced, money differs -> conflict), never re-inserted
          // under a second, backfill key — that copy would be double-counted on
          // every other device. A cloud TOMBSTONE is never un-deleted. Decision
          // 3.3: a live local row against it with no local change waiting
          // (none queued — see the query — and not `pending`) takes the cloud
          // deletion, as a pulled tombstone does; one with a pending change is
          // bound as a conflict for the user.
          final own = await _getClient()
              .from('user_transactions')
              .select(_transactionMoneySelect)
              .eq('user_id', uid)
              .eq('client_request_id', localId)
              .maybeSingle();
          if (own != null && own['deleted_at'] != null && !isDeleted) {
            if (local.readNullable<String>('sync_status') == 'pending') {
              mismatched.add(localId);
              await _db.customStatement(
                "UPDATE transactions SET server_id = ?, sync_status = 'conflict' "
                'WHERE id = ?;',
                [own['id'] as String, localId],
              );
            } else {
              final now = dateTimeToSql(DateTime.now().toUtc());
              await _db.customStatement(
                "UPDATE transactions SET status = 'ignored', updated_at = ?, "
                "server_id = ?, synced_at = ?, sync_status = 'synced' "
                'WHERE id = ?;',
                [now, own['id'] as String, now, localId],
              );
            }
            continue;
          }
          final existing = own ??
              await _getClient()
                  .from('user_transactions')
                  .select(_transactionMoneySelect)
                  .eq('user_id', uid)
                  .eq('client_request_id', clientRequestId)
                  .maybeSingle();
          if (existing != null) {
            serverRow = existing;
            matched++;
          } else {
            serverRow = await _getClient()
                .from('user_transactions')
                .insert(payload)
                .select(_transactionMoneySelect)
                .single();
            created++;
          }
        } catch (e) {
          // Per-row isolation: a PERMANENT server rejection of this one row
          // (23514 / 23505 business key / 42P10 / ...) must not block every other
          // row's history. Record it observably as an outbox dead letter via the
          // normal classifier and continue. Transient / auth / network errors
          // still stop the run (retried later), as before.
          final failureClass = classifyOutboxError(e);
          if (e is PostgrestException && failureClass.isPermanent) {
            await _recordPermanentFailure(localId, e, failureClass);
            failed.add(localId);
            continue;
          }
          throw mapSupabaseError(e);
        }

        // A row is proven only when every money dimension we transmitted is
        // returned through an exact NUMERIC::text projection and equals the
        // canonical local Money. Missing fields, parse failures, and required
        // remote-null currency all fail closed.
        final mismatch = !_moneyTextMatches(
                serverRow['amount_text'], localAmount, localCurrency) ||
            !_requiredCurrencyMatches(serverRow['currency'], localCurrency) ||
            !_moneyTextMatches(
                serverRow['balance_after_text'], localBalance, localCurrency) ||
            !_nullableCurrencyMatches(
                serverRow['foreign_currency'], localForeignCurrency) ||
            !_moneyTextMatches(
              serverRow['foreign_amount_text'],
              localForeignAmount,
              localForeignCurrency ?? localCurrency,
            ) ||
            // A row the outbox push wrote (bound above by its own id) carries
            // the push's mapping (LedgerPayloadCodec), which derives direction
            // from the type when none is stored; either mapping is a match.
            (serverRow['direction'] != payload['direction'] &&
                serverRow['direction'] !=
                    LedgerPayloadCodec.serverDirection(type, direction)) ||
            (serverRow['transaction_type'] != payload['transaction_type'] &&
                serverRow['transaction_type'] !=
                    LedgerPayloadCodec.serverTransactionType(type));
        if (mismatch) {
          mismatched.add(localId);
          // Audit H-2 — see AccountsBackfillService. A remote row that disagrees
          // with local money is NOT proof of persistence; stamping it `synced`
          // hid it from the sign-out inventory and let a later pull overwrite the
          // local amount. `transactions` has an interactive conflict policy, so
          // this lands in the existing keep-mine/keep-theirs picker.
          await _db.customStatement(
            '''
              UPDATE transactions
              SET server_id = ?, sync_status = 'conflict'
              WHERE id = ?;
            ''',
            [serverRow['id'] as String, localId],
          );
        } else {
          await _db.customStatement(
            '''
              UPDATE transactions
              SET server_id = ?, synced_at = ?, sync_status = 'synced'
              WHERE id = ?;
            ''',
            [
              serverRow['id'] as String,
              dateTimeToSql(DateTime.now().toUtc()),
              localId,
            ],
          );
        }
      }
      if (localRows.length < _pageRows) break;
    }

    return TransactionBackfillReport(
      total: scanned,
      hasMore: hasMore,
      created: created,
      matched: matched,
      mismatchedLocalIds: mismatched,
      unresolvedAccountLocalIds: unresolvedAccounts,
      queuedAwaitingFxLocalIds: queuedAwaitingFx,
      failedLocalIds: failed,
    );
  }

  /// The local entity, or null when the row cannot be parsed (legacy values).
  Future<TransactionEntity?> _loadEntity(String localId) async {
    try {
      return await DriftTransactionRepository(_db).getById(localId);
    } catch (_) {
      return null;
    }
  }

  /// Records a permanently-rejected backfill row as a ledger outbox dead letter
  /// (so it is counted by SyncHealth.queueCounts and excluded from later runs).
  Future<void> _recordPermanentFailure(
    String localId,
    Object error,
    OutboxFailureClass failureClass,
  ) async {
    final entity = await _loadEntity(localId);
    if (entity == null) return;
    await _outbox.enqueue(OutboxOperation.create, entity);
    final rowId = await _outbox.outboxRowIdForTransaction(localId);
    if (rowId != null) {
      await _outbox.markFailed(rowId, error.toString(), failureClass);
    }
  }

  Future<String?> _categoryKeyForLocalId(String? categoryId) async {
    if (categoryId == null) return null;
    final row = await _db.customSelect(
      'SELECT key FROM categories WHERE id = ? LIMIT 1;',
      variables: [Variable.withString(categoryId)],
    ).getSingleOrNull();
    return row?.readNullable<String>('key');
  }

  static TransactionDirectionEntity _directionFromSql(String? value) {
    switch (value) {
      case 'credit':
        return TransactionDirectionEntity.credit;
      case 'debit':
        return TransactionDirectionEntity.debit;
      default:
        return TransactionDirectionEntity.unknown;
    }
  }
}

bool _moneyTextMatches(Object? remote, Money? local, String currency) {
  try {
    return moneyFromPulledValue(remote, currency) == local;
  } catch (_) {
    return false;
  }
}

bool _requiredCurrencyMatches(Object? remote, String local) =>
    remote is String && remote.toUpperCase() == local.toUpperCase();

bool _nullableCurrencyMatches(Object? remote, String? local) {
  if (local == null) return remote == null;
  return _requiredCurrencyMatches(remote, local);
}
