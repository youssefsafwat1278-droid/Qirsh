import '../../data/db/sql_value_codec.dart';
import 'package:drift/drift.dart';

import '../security/lock_prompt_language.dart';
import '../../data/db/app_database.dart';
import '../../data/db/merchant_identity.dart';
import '../../data/db/planning_cutover.dart';
import '../../data/db/money_v30_backfill.dart';
import '../../data/db/planning_canonical_invariants.dart';
import '../../domain/finance/financial_semantics.dart';
import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'planning_restore_preflight.dart';
import 'restore_journal.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

class RestoreBackupUseCase {
  // MALI-026 (B8-2.10 §5): [coordinator] defaults to schema-v29 legacy, so the
  // planning-currency preflight below is a NO-OP today and restore behaves
  // exactly as before; only a canonical (future v30) live DB makes a
  // currency-less planning payload abort before any destructive mutation.
  const RestoreBackupUseCase(
    this._db, {
    PlanningCutoverCoordinator coordinator =
        const SchemaV29PlanningCutoverCoordinator(),
  }) : _coordinator = coordinator;

  final AppDatabase _db;
  final PlanningCutoverCoordinator _coordinator;
  // MALI-026 (B8-3 §1/§3): v4 business snapshots carry exact minor units +
  // currency; v3 and older are the legacy REAL-only shape. Both restore (version
  // dispatch below); a version ABOVE this is rejected before any mutation.
  static const currentSchemaVersion = 4;

  // accounts must come before tables that FK into it; categories before the
  // rows that reference category_id (merchant_category_map, transactions,
  // budgets). sender_bank_mappings is independent.
  static const _restoreOrder = [
    'accounts',
    'categories',
    'cards',
    'merchants',
    'merchant_category_map',
    'transactions',
    'budgets',
    'goals',
    'goal_contributions',
    'achievements',
    'streaks',
    'user_settings',
    'subscriptions',
    'bill_payments',
    'plans',
    'plan_transaction_links',
    'sender_bank_mappings',
    // No declared FK, so ordering is free; last keeps it out of the way of the
    // parent-before-child chain above.
    'local_offer_savings',
  ];

  // Delete in reverse FK order — children before parents.
  static const _deleteOrder = [
    'local_offer_savings',
    'sender_bank_mappings',
    'plan_transaction_links',
    'plans',
    'bill_payments',
    'subscriptions',
    'goal_contributions',
    'goals',
    'budgets',
    'transactions',
    'merchant_category_map',
    'cards',
    'merchants',
    'achievements',
    'streaks',
    'user_settings',
    'categories',
    'accounts',
  ];

  /// Apply [snapshot] destructively. When [plan] is supplied (Batch-5 pipeline),
  /// an in-transaction verification runs against it before commit, so any
  /// row-count / financial-total / integrity mismatch rolls the WHOLE restore back
  /// and leaves the original database unchanged.
  Future<void> call(
    Map<String, dynamic> snapshot, {
    RestorePlan? plan,
    RestoreJournal? journal,
    String? operationId,
    String? nowIso,
    // MALI-026 (B8-2.10 §7): a fresh, RESTORE_PAYLOAD-scoped repair decision that
    // lets the restore continue when the live DB is canonical (its fingerprint
    // must match this payload). Null on the first attempt.
    RestorePayloadRepairDecision? planningRepairDecision,
    // Test-only deterministic fault injection at named transaction-boundary
    // points (Batch-5 closure §Blocker-3). The callback throws to simulate a
    // failure; the whole restore must then roll back with the DB unchanged.
    void Function(String point)? onFaultPoint,
  }) async {
    void fault(String point) => onFaultPoint?.call(point);
    final schemaVersion = _schemaVersion(snapshot);
    if (schemaVersion > currentSchemaVersion) {
      // Reject BEFORE touching the DB — the delete/restore transaction below
      // must never start against a backup this app build doesn't know how
      // to fully apply (a newer backup format may reference columns/tables
      // this build hasn't created yet, and skipping unknown post-restore
      // migrations would leave the DB silently half-migrated).
      throw const BackupException(
        'هذه النسخة الاحتياطية من إصدار أحدث من التطبيق. حدّث التطبيق ثم '
        'أعد المحاولة.',
        code: BackupError.backupFromNewerApp,
      );
    }
    // Validate the WHOLE payload BEFORE any destructive DELETE runs, so a
    // malformed or truncated backup fails safely instead of half-wiping the
    // DB. A v3 backup with a missing/empty categories payload must be rejected
    // here — otherwise conditional-delete would wipe the catalog and restore
    // nothing.
    final tables = validateTables(snapshot, schemaVersion);

    // MALI-026 (B8-2.10 §5) — planning-currency RESTORE preflight. Runs AFTER
    // validation and BEFORE any destructive PRAGMA/DELETE, so a repair-required
    // payload aborts with the original database byte-for-byte unchanged. It only
    // bites when the LIVE db is canonical (P3): restoring currency-less legacy
    // planning rows into a canonical DB would insert ambiguous money. At schema
    // v29 (legacy) [inspectRestoreSnapshotPlanning] returns RestoreReady, so this
    // is a no-op and every existing restore path is unchanged.
    final planningPreflight = inspectRestoreSnapshotPlanning(
      tables: tables,
      cutoverState: _coordinator.state(),
      decision: planningRepairDecision,
    );
    if (planningPreflight is RestorePlanningCurrencyRepairRequired) {
      throw RestorePlanningRepairRequiredException(
          planningPreflight.payloadFingerprint);
    }

    // MALI-045n: `PRAGMA foreign_keys` is connection-scoped and a documented
    // NO-OP while a transaction is pending, so it MUST be toggled OUTSIDE
    // _db.transaction() to genuinely suspend enforcement for the bulk restore.
    // (A self-consistent v3 snapshot — parents backed up FULL — would restore
    // fine with enforcement ON via the parent-before-child ordering; suspension
    // is retained only so legacy/cross-catalog backups restore gracefully
    // instead of failing on the first dangling reference.) After the inserts we
    // sanitize dangling references to satisfy the declared FK semantics, then
    // run `PRAGMA foreign_key_check` INSIDE the txn: any residual violation
    // throws and rolls the WHOLE restore back, leaving the original database
    // unchanged. `finally` re-enables enforcement no matter what.
    await _db.customStatement('PRAGMA foreign_keys = OFF;');
    try {
      await _db.transaction(() async {
        var deletedCount = 0;
        for (final table in _deleteOrder) {
          // Conditional delete: only empty a table the backup actually carries
          // (back-compat). A v2 backup has no cards/categories/sender_mappings
          // keys, so its restore must NOT wipe the fresh DB's seeded catalog.
          if (!tables.containsKey(table)) continue;
          await _db.customStatement('DELETE FROM $table;');
          deletedCount++;
          if (deletedCount == 1) fault('afterFirstDelete');
          if (deletedCount == 3) fault('afterSeveralDeletes');
        }
        var insertedTables = 0;
        for (final table in _restoreOrder) {
          final rows = (tables[table] as List<dynamic>?) ?? const [];
          var rowIndex = 0;
          for (final row in rows.cast<Map<String, dynamic>>()) {
            await _insertRow(table, row);
            if (insertedTables == 0 && rowIndex == 0) fault('afterFirstInsert');
            rowIndex++;
          }
          insertedTables++;
          if (insertedTables == 2) fault('afterPartialInsert');
        }
        fault('duringRelationshipReconstruction');
        // Idempotent no-op for a self-consistent v3 snapshot; heals legacy /
        // cross-catalog dangling references so the committed DB is FK-clean.
        await _sanitizeDanglingReferences();
        // Postflight INSIDE the txn — a residual violation aborts + rolls back.
        final violations =
            await _db.customSelect('PRAGMA foreign_key_check;').get();
        if (violations.isNotEmpty) {
          throw const BackupException(
            'تعذّرت الاستعادة: النسخة الاحتياطية تنتهك سلامة العلاقات بين '
            'البيانات.',
            code: BackupError.relationalIntegrityViolated,
          );
        }
        // MALI-026 (B8-3 §26/§7 continuation) — when a RESTORE_PAYLOAD-scoped
        // repair decision was supplied, convert the just-restored planning rows to
        // canonical (row.currency + `_minor`) using THAT decision (never the base
        // currency), so a canonical live DB ends canonical. Contributions inherit
        // the parent goal's confirmed currency. Any id not covered → throw → rollback.
        if (planningRepairDecision != null) {
          await _canonicalizeRestoredPlanning(planningRepairDecision);
        }
        // MALI-026 (B8-3 §3) — version dispatch for NON-planning money:
        //   • v4+ exact snapshot: the exact `_minor` (+ currency) were inserted
        //     DIRECTLY as the authority — NOTHING to reconstruct. A REAL→minor
        //     parity check is deliberately NOT run: the REAL is a derived shadow
        //     (Money.toDouble) that rounds beyond 2^53, whereas the exact minor is
        //     preserved verbatim (§5). Envelope authentication guards integrity;
        //     a malformed minor string already failed closed in _insertRow.
        //   • v3- legacy snapshot: REAL + currency only, so populate `_minor` from
        //     the restored REAL via the same exact converter as the v30 upgrade.
        if (schemaVersion < 4) {
          await backfillNonPlanningMoneyV30(_db);
        }

        // MALI-026 (B8-3 §26/§8) — reconcile the PLANNING cutover marker with the
        // ACTUAL restored planning data; NEVER trust a marker carried in the
        // backup. Legacy planning rows (no currency/minor) -> unresolved; empty or
        // fully-canonical -> canonical. If the LIVE db was canonical and the restore
        // ends with planning violations, that is corruption -> roll the whole
        // restore back (atomic; no partial planning restore, no false marker).
        final planningViolations = await planningCanonicalViolations(_db);
        if (_coordinator.state() == PlanningCutoverState.canonical &&
            planningViolations.isNotEmpty) {
          throw const BackupException(
            'تعذّرت الاستعادة: بيانات التخطيط غير متسقة بعد الاستعادة.',
            code: BackupError.planningInconsistent,
          );
        }
        await _db.customStatement(
          'UPDATE user_settings SET planning_cutover_state = '
          '${planningViolations.isEmpty ? 1 : 0};',
        );
        fault('beforeVerification');
        // MALI-014/076n §6 — in-transaction verification against the immutable
        // plan. Any mismatch throws BEFORE commit → the whole restore rolls back
        // and the original database is preserved.
        if (plan != null) await _verifyAgainstPlan(plan, fault);
        fault('afterVerification');
        // A backup keeps each transaction's merchant link, but a legacy or
        // cross-catalog snapshot can carry a link the sanitizer above had to
        // null. Relink by the exact normalised merchant name — deterministic,
        // never fuzzy — AFTER verification, so the plan is checked against the
        // snapshot as restored. Category and provenance are untouched.
        await repairMissingMerchantLinks(_db);
        // Audit H-20: these steps are required for CORRECTNESS, not
        // convenience, so they belong inside the atomic transaction.
        // `runPostRestoreSetup` resets ai/cloud consent (MALI-059n) so a
        // restore cannot import consent as authorization on a new device. Run
        // post-commit, a crash or failure in that window committed the restored
        // data with a legacy backup's consent flags intact — an authorization
        // the user never gave. Placed AFTER verification so the plan is still
        // checked against the snapshot as restored, not as adjusted.
        for (final step in _postRestoreMigrations) {
          if (step.appliesTo(schemaVersion)) {
            await step.run(_db);
          }
        }
        // MALI-014 §Blocker-1 — the DURABLE committed marker is written INSIDE
        // this transaction, so it commits atomically with the restored data and
        // rolls back with it. A crash after commit is then discoverable at restart.
        if (journal != null && operationId != null && nowIso != null) {
          fault('duringJournalCommit');
          await journal.markCommittedInTransaction(operationId, nowIso);
        }
      });
    } finally {
      await _db.customStatement('PRAGMA foreign_keys = ON;');
    }
    // ── POST-COMMIT ───────────────────────────────────────────────────────
    // Everything below runs AFTER the destructive transaction committed. The
    // replacement data is already on disk, so a failure here must NEVER be
    // reported as a rollback (audit H-20). It is raised as a distinct typed
    // exception so the caller can say what is actually true: committed, with an
    // ancillary step incomplete. Nothing is swallowed.
    try {
      // Enforcement MUST be back on for the rest of this connection's lifetime.
      final fkEnabled =
          (await _db.customSelect('PRAGMA foreign_keys;').getSingle())
              .read<int>('foreign_keys');
      if (fkEnabled != 1) {
        throw const BackupException(
          'تعذّر إعادة تفعيل قيود العلاقات بعد الاستعادة.',
          code: BackupError.foreignKeysNotReenabled,
        );
      }
    } catch (_) {
      throw const RestoreCommittedPostStepException('foreignKeyReenable');
    }
    // The unlock prompt is composed on the first frame of a cold start, before
    // the database can be opened, so the restored language is mirrored into the
    // keychain for it to read. Post-commit, because a rolled-back restore must
    // not leave the mirror describing data that was never written. See
    // core/security/lock_prompt_language.dart.
    try {
      // `getSingleOrNull`: a synthetic or partial snapshot can leave the
      // settings row absent, and there is then no language to mirror. Absent is
      // not a failure — the mirror keeps its current value, which is what the
      // app will still be reading.
      final row = await _db
          .customSelect('SELECT language FROM user_settings LIMIT 1;')
          .getSingleOrNull();
      if (row != null) {
        await LockPromptLanguage.set(row.read<String>('language'));
      }
    } catch (_) {
      throw const RestoreCommittedPostStepException('lockPromptLanguage');
    }
  }

  /// MALI-026 (B8-3 §26/§7) — canonicalize the just-restored planning rows using
  /// the RESTORE_PAYLOAD-scoped [decision] (never the base currency, never the
  /// local live rows): set row.currency + every `_minor` field exactly from the
  /// restored REAL amounts. Contributions inherit their parent goal's confirmed
  /// currency. Any budget/goal id the decision doesn't cover, or a contribution
  /// whose parent goal wasn't converted, throws → the whole restore rolls back
  /// (§8, no partial planning restore). Runs INSIDE the restore transaction.
  Future<void> _canonicalizeRestoredPlanning(
      RestorePayloadRepairDecision decision) async {
    for (final b in await _db
        .customSelect(
            'SELECT id, amount, last_notified_spent_amount FROM budgets;')
        .get()) {
      final id = b.read<String>('id');
      final cur = decision.currencyForId(id);
      await _db.customStatement(
        'UPDATE budgets SET currency = ?, amount_minor = ?, '
        'last_notified_spent_amount_minor = ?, $kMarkPendingIfServerBacked '
        'WHERE id = ?;',
        [
          cur,
          restoreLegacyAmountToMinor(b.read<double>('amount'), cur),
          restoreLegacyAmountToMinor(
              b.read<double>('last_notified_spent_amount'), cur),
          id,
        ],
      );
    }

    // Build the parent-goal currency map ONCE (no N+1) so contributions resolve
    // from their converted parent, not a per-row decision lookup.
    final goalCurrency = <String, String>{};
    for (final g in await _db
        .customSelect('SELECT id, target_amount, saved_amount, '
            'last_notified_saved_amount, auto_save_amount FROM goals;')
        .get()) {
      final id = g.read<String>('id');
      final cur = decision.currencyForId(id);
      goalCurrency[id] = cur;
      final autoSave = g.readNullable<double>('auto_save_amount');
      await _db.customStatement(
        'UPDATE goals SET currency = ?, target_amount_minor = ?, '
        'saved_amount_minor = ?, last_notified_saved_amount_minor = ?, '
        'auto_save_amount_minor = ?, $kMarkPendingIfServerBacked '
        'WHERE id = ?;',
        [
          cur,
          restoreLegacyAmountToMinor(g.read<double>('target_amount'), cur),
          restoreLegacyAmountToMinor(g.read<double>('saved_amount'), cur),
          restoreLegacyAmountToMinor(
              g.read<double>('last_notified_saved_amount'), cur),
          autoSave == null ? null : restoreLegacyAmountToMinor(autoSave, cur),
          id,
        ],
      );
    }

    for (final c in await _db
        .customSelect('SELECT id, amount, goal_id FROM goal_contributions;')
        .get()) {
      final parentGoalId = c.read<String>('goal_id');
      final cur = goalCurrency[parentGoalId];
      if (cur == null) {
        throw BackupException(
          'تعذّرت الاستعادة: مساهمة هدف يتيمة (${c.read<String>('id')}).',
          code: BackupError.orphanGoalContribution,
          args: [c.read<String>('id')],
        );
      }
      await _db.customStatement(
        'UPDATE goal_contributions SET amount_minor = ? WHERE id = ?;',
        [
          restoreLegacyAmountToMinor(c.read<double>('amount'), cur),
          c.read<String>('id'),
        ],
      );
    }
  }

  /// FK-safe repair applied inside the restore transaction (with enforcement
  /// suspended). For a self-consistent v3 snapshot every statement matches zero
  /// rows. It heals legacy/cross-catalog inconsistencies (e.g. a v2 backup whose
  /// category ids don't exist on this install) so the committed database
  /// satisfies every declared foreign key: `SET NULL` references are nulled
  /// (matching ON DELETE SET NULL), and NOT-NULL child rows whose parent is
  /// genuinely absent are dropped in cascade-safe order (matching ON DELETE
  /// CASCADE) — orphan parents are removed before their own orphan children so
  /// no new dangling row is left behind.
  Future<void> _sanitizeDanglingReferences() async {
    // transactions.{category_id,merchant_id} — ON DELETE SET NULL.
    await _db.customStatement(
      'UPDATE transactions SET category_id = NULL, $kMarkPendingIfServerBacked '
      'WHERE category_id IS NOT NULL '
      'AND category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'UPDATE transactions SET merchant_id = NULL, $kMarkPendingIfServerBacked '
      'WHERE merchant_id IS NOT NULL '
      'AND merchant_id NOT IN (SELECT id FROM merchants);',
    );
    // NOT-NULL children invalid without their parent — drop (ON DELETE CASCADE).
    await _db.customStatement(
      'DELETE FROM merchant_category_map '
      'WHERE merchant_id NOT IN (SELECT id FROM merchants) '
      'OR category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'DELETE FROM budgets '
      'WHERE category_id NOT IN (SELECT id FROM categories);',
    );
    await _db.customStatement(
      'DELETE FROM goal_contributions '
      'WHERE goal_id NOT IN (SELECT id FROM goals);',
    );
    // subscriptions.merchant_id is NOT NULL → drop an orphan subscription BEFORE
    // its bill_payments so the payment orphan check below then also fires.
    await _db.customStatement(
      'DELETE FROM subscriptions '
      'WHERE merchant_id NOT IN (SELECT id FROM merchants);',
    );
    await _db.customStatement(
      'DELETE FROM bill_payments '
      'WHERE bill_id NOT IN (SELECT id FROM subscriptions);',
    );
    await _db.customStatement(
      'DELETE FROM plan_transaction_links '
      'WHERE plan_id NOT IN (SELECT id FROM plans) '
      'OR transaction_id NOT IN (SELECT id FROM transactions);',
    );
  }

  /// MALI-014/076n §6 — verify the freshly-written (uncommitted) database state
  /// against the immutable plan. Throws [RestoreVerificationException] on any
  /// mismatch so the transaction rolls back before commit. Runs INSIDE the restore
  /// transaction. No data is surfaced — only protocol labels.
  Future<void> _verifyAgainstPlan(RestorePlan plan,
      [void Function(String point)? fault]) async {
    Future<int> count(String table) async {
      final row = await _db
          .customSelect('SELECT COUNT(*) AS c FROM $table;')
          .getSingle();
      return row.read<int>('c');
    }

    // (1) Required singleton — the single user_settings row must exist — and at
    // least one (default) account.
    if (await count('user_settings') != 1) {
      throw const RestoreVerificationException('missing_singleton');
    }
    if (await count('accounts') < 1) {
      throw const RestoreVerificationException('missing_default_account');
    }

    // (2) Transactions are never sanitized away, so their count must match the
    // plan exactly; and no duplicate primary id may exist (INSERT OR REPLACE
    // dedupes, so a mismatch means the plan itself carried duplicates).
    final expectedTxns = plan.expectedRowCounts['transactions'] ?? 0;
    final actualTxns = await count('transactions');
    if (actualTxns != expectedTxns) {
      throw const RestoreVerificationException('row_count_mismatch');
    }
    final distinctTxnIds = (await _db
            .customSelect('SELECT COUNT(DISTINCT id) AS c FROM transactions;')
            .getSingle())
        .read<int>('c');
    if (distinctTxnIds != actualTxns) {
      throw const RestoreVerificationException('duplicate_identifier');
    }

    // (3) Tables that CAN be sanitized (orphans dropped) must never have MORE rows
    // than the plan — more rows means a stray insert leaked in.
    for (final entry in plan.expectedRowCounts.entries) {
      if (entry.key == 'transactions') continue;
      if (await count(entry.key) > entry.value) {
        throw const RestoreVerificationException('row_count_mismatch');
      }
    }

    fault?.call('duringVerification');

    // (4) Financial fidelity PER CURRENCY — the canonical net-expense confirmed
    // total computed over the RESTORED transactions, grouped by currency, must
    // equal the totals computed over the PLAN's transactions (Phase-4 semantics).
    // A silent value/currency corruption fails here.
    final restoredByCurrency = <String, double>{};
    for (final row in await _db
        .customSelect(
          'SELECT currency AS cur, '
          'COALESCE(SUM(${FinancialSql.netExpenseSignedAmount()}), 0) AS t '
          'FROM transactions WHERE ${FinancialSql.confirmedPredicate()} '
          'GROUP BY currency;',
        )
        .get()) {
      restoredByCurrency[row.read<String>('cur')] = row.read<double>('t');
    }
    final planByCurrency = _planNetExpensePerCurrency(plan);
    final currencies = {...restoredByCurrency.keys, ...planByCurrency.keys};
    for (final currency in currencies) {
      final a = restoredByCurrency[currency] ?? 0.0;
      final b = planByCurrency[currency] ?? 0.0;
      if ((a - b).abs() > 1e-6) {
        throw const RestoreVerificationException('total_mismatch');
      }
    }

    // (5) No SQLCipher key reference may survive the restore.
    final keyRef = (await _db
            .customSelect(
                "SELECT COALESCE(db_encryption_key_ref, '') AS k FROM user_settings LIMIT 1;")
            .getSingle())
        .read<String>('k');
    if (keyRef.isNotEmpty) {
      throw const RestoreVerificationException('key_ref_present');
    }

    // (6) No intentionally-excluded (remote/pending relay/cache) table may be in
    // the plan — those must never be restored.
    for (final table in plan.tables.keys) {
      if (BackupSnapshotBuilder.intentionallyExcluded.contains(table)) {
        throw const RestoreVerificationException('remote_row_present');
      }
    }
  }

  /// Canonical net-expense confirmed total PER CURRENCY over the plan's
  /// transaction rows (refund subtracts; payment/withdrawal add; confirmed only) —
  /// mirrors [FinancialSql.netExpenseSignedAmount] + [FinancialSql.confirmedPredicate].
  Map<String, double> _planNetExpensePerCurrency(RestorePlan plan) {
    final totals = <String, double>{};
    for (final row in plan.tables['transactions'] ?? const []) {
      if (row['status'] != 'confirmed') continue;
      final currency = (row['currency'] as String?) ?? '';
      final amount = (row['amount'] as num?)?.toDouble() ?? 0.0;
      final delta = switch (row['type']) {
        'refund' => -amount,
        'payment' || 'withdrawal' => amount,
        _ => 0.0,
      };
      totals[currency] = (totals[currency] ?? 0.0) + delta;
    }
    return totals;
  }

  int _schemaVersion(Map<String, dynamic> snapshot) {
    final value = snapshot['schemaVersion'];
    if (value is int && value > 0) return value;
    return 1;
  }

  /// Structural preflight — runs before any DELETE. Rejects malformed/truncated
  /// backups so a bad file can never leave the DB half-restored, and refuses a
  /// v3 backup whose categories payload is missing/empty (which would let the
  /// conditional delete wipe the catalog with nothing to restore).
  static Map<String, dynamic> validateTables(
    Map<String, dynamic> snapshot,
    int schemaVersion,
  ) {
    final rawTables = snapshot['tables'];
    if (rawTables is! Map<String, dynamic>) {
      throw const BackupException(
        'النسخة الاحتياطية تالفة أو غير مكتملة. تعذّرت الاستعادة.',
        code: BackupError.backupCorrupt,
      );
    }
    // Every present table must be a list of row-maps.
    for (final entry in rawTables.entries) {
      final value = entry.value;
      if (value is! List) {
        throw BackupException(
          'النسخة الاحتياطية تالفة عند الجدول "${entry.key}". تعذّرت الاستعادة.',
          code: BackupError.tableCorrupt,
          args: [entry.key],
        );
      }
      for (final row in value) {
        if (row is! Map<String, dynamic>) {
          throw BackupException(
            'النسخة الاحتياطية تالفة عند الجدول "${entry.key}". '
            'تعذّرت الاستعادة.',
            code: BackupError.tableCorrupt,
            args: [entry.key],
          );
        }
        // MALI-058n §4/§6 — fail CLOSED on an unexpected key/secret-like field
        // BEFORE any destructive step. The one known-deprecated field
        // (db_encryption_key_ref from a legacy snapshot) is tolerated — it is
        // dropped on insert, so an otherwise-valid legacy backup still restores.
        // Any OTHER security-sensitive column outside the backup-safe whitelist
        // is rejected, so a tampered/foreign snapshot can never smuggle key
        // material (or a mismatched location) into the restored database.
        final allowed = BackupSnapshotBuilder.restorableColumns[entry.key];
        for (final key in row.keys) {
          if (allowed != null && allowed.contains(key)) continue;
          if (_knownDeprecatedColumns.contains(key)) continue;
          if (_looksSensitive(key)) {
            throw BackupException(
              'النسخة الاحتياطية تحتوي على حقل حسّاس غير متوقع '
              '("${entry.key}"). تعذّرت الاستعادة.',
              code: BackupError.unexpectedSensitiveField,
              args: [entry.key],
            );
          }
        }
      }
    }
    // v3+ must carry every REQUIRED table as a non-empty list. These three
    // always exist in a healthy DB (seeded catalog, ≥1 default account, the
    // single user_settings row), so their absence/emptiness signals a
    // truncated or corrupt backup — reject BEFORE any delete. (categories is
    // additionally load-bearing: the conditional delete would otherwise wipe
    // the catalog with nothing to restore.)
    if (schemaVersion >= 3) {
      for (final table in _requiredV3Tables) {
        final value = rawTables[table];
        if (value is! List || value.isEmpty) {
          throw BackupException(
            'النسخة الاحتياطية تالفة أو غير مكتملة (جدول "$table" مفقود). '
            'تعذّرت الاستعادة.',
            code: BackupError.requiredTableMissing,
            args: [table],
          );
        }
      }
    }
    // Audit H-21 — v4+ COMPLETENESS CONTRACT.
    //
    // A table absent from the snapshot is skipped by the conditional DELETE in
    // the restore transaction, so its LIVE rows survive and merge with the
    // restored data. `expectedRowCounts` is derived only from tables that ARE
    // present, so verification never noticed: an omitted `budgets` (or goals,
    // plans, cards, …) committed as a "successful full restore" that was really
    // a partial merge. Only `transactions` was accidentally protected, because
    // its check uses `?? 0` and the surviving live rows tripped the count.
    //
    // v4 is advertised as a COMPLETE snapshot, and the builder always writes a
    // key for every backed-up table (empty list when the user has no rows), so
    // requiring every key is exactly the contract the format already claims.
    // A missing KEY is a truncated backup and is rejected here — BEFORE any
    // destructive mutation. An EMPTY list stays legal: that is a real, complete
    // snapshot of a user who has none of those rows.
    //
    // Deliberately v4+ ONLY (PART 6): v2/v3 legitimately omit tables — a v2
    // backup carries no cards/categories/sender_bank_mappings — and their
    // partial-merge semantics are preserved rather than retroactively
    // reinterpreted as complete.
    if (schemaVersion >= 4) {
      for (final table in BackupSnapshotBuilder.backedUpTables) {
        if (rawTables[table] is! List) {
          throw BackupException(
            'النسخة الاحتياطية غير مكتملة (جدول "$table" مفقود). '
            'تعذّرت الاستعادة.',
            code: BackupError.requiredTableMissing,
            args: [table],
          );
        }
      }
    }
    return rawTables;
  }

  /// Tables that a healthy v3 snapshot must always carry (non-empty). A
  /// truncated/corrupt backup missing any of these is rejected before the
  /// restore transaction. Everything else in the backup is optional (may be
  /// present but empty); tables outside the backup are intentionally excluded
  /// (see BackupSnapshotBuilder.intentionallyExcluded).
  static const _requiredV3Tables = {
    'categories',
    'accounts',
    'user_settings',
  };

  // MALI-058n §3/§7 — a legacy snapshot may carry the deprecated raw-key column;
  // it is never written to the destination DB.
  static const _knownDeprecatedColumns = {'db_encryption_key_ref'};

  // Any snapshot column outside the backup-safe whitelist whose NAME looks like
  // key/secret material and is not a known-deprecated field → fail closed.
  static final _sensitivePattern = RegExp(
    r'(?:^|_)(key|secret|token|password|passphrase|credential|cipher)(?:$|_)',
    caseSensitive: false,
  );
  static bool _looksSensitive(String column) =>
      _sensitivePattern.hasMatch(column);

  Future<void> _insertRow(String table, Map<String, dynamic> row) async {
    final data = Map<String, dynamic>.from(row);
    // MALI-026 (B8-3 §2/§3): a v4 snapshot carries every `_minor` as a decimal
    // integer STRING (JS-safe). Parse it back to an int64 so it lands in the
    // INTEGER column as the exact minor authority; a malformed value fails the
    // whole restore closed rather than silently truncating via type affinity.
    for (final key in data.keys) {
      final value = data[key];
      if (key.endsWith('_minor') && value is String) {
        final parsed = int.tryParse(value);
        if (parsed == null) {
          throw BackupException(
            'تعذّرت الاستعادة: قيمة نقدية غير صالحة ("$key").',
            code: BackupError.invalidMoneyValue,
            args: [key],
          );
        }
        data[key] = parsed;
      }
    }
    if (table == 'transactions') {
      data['raw_message'] = '[restored: raw message intentionally excluded]';
    }
    if (table == 'user_settings') {
      // MALI-058n §4 — the deprecated key column is NOT NULL, so the restore
      // must write it, but it writes ONLY '' — never the (possibly key-bearing)
      // value a legacy/foreign snapshot may carry.
      data['db_encryption_key_ref'] = '';
    }
    // MALI-058n §6 — column names are fixed by application code, NEVER taken
    // from arbitrary snapshot keys. Restrict to the backup-safe whitelist; any
    // other key (a legacy db_encryption_key_ref value, or any unrecognized
    // field) is dropped here and never reaches the SQL or the destination DB.
    final allowed = BackupSnapshotBuilder.restorableColumns[table];
    if (allowed == null) {
      // A restore-order table must have a defined whitelist — refuse to build
      // SQL from arbitrary identifiers rather than trust the snapshot.
      throw BackupException(
        'تعذّرت الاستعادة: جدول غير مدعوم ("$table").',
        code: BackupError.unsupportedTable,
        args: [table],
      );
    }
    final restorable = <String>{
      ...allowed,
      if (table == 'transactions') 'raw_message',
      // Written as '' above; included so the NOT NULL column is satisfied.
      if (table == 'user_settings') 'db_encryption_key_ref',
    };
    final columns = [
      for (final column in restorable)
        if (data.containsKey(column)) column,
    ];
    if (columns.isEmpty) return;
    final placeholders = List.filled(columns.length, '?').join(', ');
    await _db.customInsert(
      'INSERT OR REPLACE INTO $table(${columns.join(', ')}) VALUES ($placeholders);',
      variables: <Variable>[
        for (final column in columns) _variable(data[column]),
      ],
    );
  }

  Variable _variable(Object? value) {
    if (value == null) return const Variable<String>(null);
    if (value is int) return Variable<int>(value);
    if (value is double) return Variable<double>(value);
    if (value is num) return Variable<double>(value.toDouble());
    return Variable<String>(value.toString());
  }
}

class _PostRestoreMigration {
  const _PostRestoreMigration({
    required this.fromInclusive,
    required this.toInclusive,
    required this.run,
  });

  final int fromInclusive;
  final int toInclusive;
  final Future<void> Function(AppDatabase db) run;

  bool appliesTo(int schemaVersion) =>
      schemaVersion >= fromInclusive && schemaVersion <= toInclusive;
}

final _postRestoreMigrations = <_PostRestoreMigration>[
  _PostRestoreMigration(
    fromInclusive: 1,
    toInclusive: RestoreBackupUseCase.currentSchemaVersion,
    run: (db) => db.runPostRestoreSetup(),
  ),
];
