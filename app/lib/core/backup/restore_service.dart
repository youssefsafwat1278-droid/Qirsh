import '../observability/app_diagnostics.dart';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../data/db/app_database.dart';
import '../../data/db/database_lease.dart';
import '../../data/db/ownership_guard.dart';
import '../../data/db/planning_cutover.dart';
import 'backup_service.dart';
import 'planning_restore_preflight.dart';
import 'restore_backup_usecase.dart';
import 'restore_journal.dart';
import 'restore_plan.dart';
import 'restore_result.dart';

// MALI-014 / MALI-076n (Phase 6 Batch 5 + closure) §2B/§9/§10/§14 — the restore
// MUTATION orchestrator. Consumes ONLY an immutable [RestorePlan], revalidates
// admission, runs the destructive write through the accepted file-exclusive
// maintenance primitive inside one transaction, and records progress in the DURABLE
// restore-operation journal so a crash / acknowledgement loss cannot replay a
// destructive restore. Every failure maps to a typed [RestoreResult].
class RestoreService {
  RestoreService(this._db, {RestoreJournal? journal})
      : _journal = journal ?? RestoreJournal(_db);

  final AppDatabase _db;
  final RestoreJournal _journal;

  /// Execute the mutation phase for [plan].
  ///
  /// O-BX-1: the restore is an exclusive-maintenance creator. When the session
  /// supplies [maintenanceParticipant] the WHOLE execution (journal, maintenance
  /// and the post-commit tail, all of which use the database) runs inside the
  /// session's admission drain, so a local-read restoration waits for it and a
  /// restore that has not started is refused, before any journal write, lease,
  /// intent or mutation, with [RestoreOutcome.ownershipChanged].
  Future<RestoreResult> execute({
    required RestorePlan plan,
    DatabaseLeaseManager? leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
    String? preparedUserId,
    String? Function()? currentUserId,
    Future<void> Function()? afterRestore,
    Duration drainTimeout = const Duration(seconds: 10),
    Duration exclusiveTimeout = const Duration(seconds: 10),
    PlanningCutoverCoordinator planningCoordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    RestorePayloadRepairDecision? planningRepairDecision,
    void Function(String point)? onFaultPoint,
    Future<void> Function(Future<void> Function() run)? maintenanceParticipant,
  }) async {
    return AppDiagnostics.run(AppOperation.restore, () async {
      Future<RestoreResult> body() => _execute(
            plan: plan,
            leaseManager: leaseManager,
            ownershipGuard: ownershipGuard,
            admissionToken: admissionToken,
            preparedUserId: preparedUserId,
            currentUserId: currentUserId,
            afterRestore: afterRestore,
            drainTimeout: drainTimeout,
            exclusiveTimeout: exclusiveTimeout,
            planningCoordinator: planningCoordinator,
            planningRepairDecision: planningRepairDecision,
            onFaultPoint: onFaultPoint,
          );
      final participant = maintenanceParticipant;
      if (participant == null) return body();
      var entered = false;
      late RestoreResult result;
      try {
        await participant(() async {
          entered = true;
          result = await body();
        });
      } on StaleOwnershipException {
        if (entered) rethrow;
        return RestoreResult(RestoreOutcome.ownershipChanged,
            operationId: plan.operationId);
      }
      return result;
    });
  }

  Future<RestoreResult> _execute({
    required RestorePlan plan,
    DatabaseLeaseManager? leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
    String? preparedUserId,
    String? Function()? currentUserId,
    Future<void> Function()? afterRestore,
    Duration drainTimeout = const Duration(seconds: 10),
    Duration exclusiveTimeout = const Duration(seconds: 10),
    // MALI-026 (B8-2.10 §5/§7): the live cutover authority (defaults to legacy,
    // so v29 restore is unchanged) and an optional RESTORE_PAYLOAD-scoped repair
    // decision for the continuation retry.
    PlanningCutoverCoordinator planningCoordinator =
        const SchemaV29PlanningCutoverCoordinator(),
    RestorePayloadRepairDecision? planningRepairDecision,
    void Function(String point)? onFaultPoint,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    final genHash = _ownerGenerationHash(admissionToken);

    Future<bool> admissionIsCurrent() async {
      // If the higher layer supplied an account binding, require all components:
      // the prepared UID, token UID/generation, live auth UID, and guard state.
      if (preparedUserId != null) {
        if (admissionToken == null ||
            ownershipGuard == null ||
            admissionToken.ownerUid != preparedUserId ||
            admissionToken.generation == null ||
            admissionToken.generation!.isEmpty) {
          return false;
        }
        try {
          if (currentUserId?.call() != preparedUserId) return false;
        } catch (_) {
          return false;
        }
      }
      if (ownershipGuard != null && admissionToken != null) {
        return ownershipGuard.isCurrent(admissionToken);
      }
      return preparedUserId == null;
    }

    RestoreResult committedPending({required String warning}) => RestoreResult(
          RestoreOutcome.committedPendingBackupState,
          operationId: plan.operationId,
          warnings: [...plan.warnings, warning],
        );

    Future<RestoreResult> finishCommitted(
      RestoreOutcome completedOutcome,
    ) async {
      // The journal marker and restored rows are already durable. Every step in
      // this tail therefore maps failures to a COMMITTED, retryable result; none
      // may escape to RestoreController's "data did not change" catch branch.
      try {
        await _journal.prune();
        if (afterRestore != null) await afterRestore();
      } catch (_) {
        return committedPending(warning: _postStepWarning);
      }

      // Keep the ownership check distinct so an A→B change retains the specific
      // H-23 fail-closed warning. A storage/auth read exception is equally
      // ambiguous and must fail closed after the commit.
      try {
        if (!await admissionIsCurrent()) {
          return committedPending(warning: backupStateOwnershipConflictWarning);
        }
      } catch (_) {
        return committedPending(warning: backupStateOwnershipConflictWarning);
      }

      return RestoreResult(
        completedOutcome,
        operationId: plan.operationId,
        warnings: plan.warnings,
      );
    }

    // §Blocker-1 — DURABLE replay guard (survives a crash/restart, unlike the old
    // in-memory guard). A committed operation is never destructively replayed.
    final existing = await _journal.find(plan.operationId);
    if (existing != null &&
        existing.sourceFingerprint != plan.sourceFingerprint) {
      return RestoreResult(RestoreOutcome.validationFailed,
          operationId: plan.operationId);
    }
    if (existing != null && existing.isCommitted) {
      // A replay is still a side-effect boundary: bind it to the admission that
      // originally committed the journal entry, then revalidate that admission.
      // Without the hash comparison, a fresh B preparation of A's operation id
      // would be "current" for B and could publish A's key material for B.
      if (existing.ownerGenerationHash != genHash) {
        return committedPending(warning: backupStateOwnershipConflictWarning);
      }
      try {
        if (!await admissionIsCurrent()) {
          return committedPending(warning: backupStateOwnershipConflictWarning);
        }
      } catch (_) {
        return committedPending(warning: backupStateOwnershipConflictWarning);
      }
      if (existing.state == RestoreJournalState.acknowledged) {
        return RestoreResult(
          RestoreOutcome.success,
          operationId: plan.operationId,
          warnings: plan.warnings,
        );
      }
      // A prior post-commit tail failure intentionally leaves the marker
      // unacknowledged. Retrying the same operation reruns only these idempotent
      // tail steps; the destructive restore is never replayed.
      return finishCommitted(RestoreOutcome.committedPendingAcknowledgement);
    }

    // §10 — revalidate admission before acquiring the gate.
    if (!await admissionIsCurrent()) {
      await _journal.markFailedBeforeMutation(
          plan.operationId, 'ownershipChanged', now);
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    }

    await _journal.markPrepared(
      operationId: plan.operationId,
      sourceFingerprint: plan.sourceFingerprint,
      envelopeVersion: plan.envelopeVersion,
      snapshotSchemaVersion: plan.snapshotSchemaVersion,
      ownerGenerationHash: genHash,
      nowIso: now,
    );

    Future<void> mutate() async {
      // §10 — revalidate admission immediately before the transaction.
      if (!await admissionIsCurrent()) {
        throw const StaleOwnershipException();
      }
      await RestoreBackupUseCase(_db, coordinator: planningCoordinator).call(
        <String, dynamic>{
          'schemaVersion': plan.snapshotSchemaVersion,
          'tables': plan.tables,
        },
        plan: plan,
        journal: _journal,
        operationId: plan.operationId,
        nowIso: now,
        planningRepairDecision: planningRepairDecision,
        onFaultPoint: onFaultPoint,
      );
    }

    try {
      if (leaseManager != null) {
        await _db.runFileExclusiveMaintenance<void>(
          mutate,
          leaseManager: leaseManager,
          ownershipGuard: ownershipGuard,
          admissionToken: admissionToken,
          drainTimeout: drainTimeout,
          exclusiveTimeout: exclusiveTimeout,
        );
      } else {
        await _db.runExclusiveMaintenance<void>(mutate,
            drainTimeout: drainTimeout);
      }
    } on StaleOwnershipException {
      await _journal.markRolledBack(plan.operationId, 'ownershipChanged', now);
      return RestoreResult(RestoreOutcome.ownershipChanged,
          operationId: plan.operationId);
    } on DatabaseLeaseUnavailable {
      await _journal.markRolledBack(
          plan.operationId, 'maintenanceTimeout', now);
      return RestoreResult(RestoreOutcome.maintenanceTimeout,
          operationId: plan.operationId);
    } on DatabaseBusyException {
      await _journal.markRolledBack(plan.operationId, 'databaseBusy', now);
      return RestoreResult(RestoreOutcome.databaseBusy,
          operationId: plan.operationId);
    } on DatabaseLifecycleException catch (e) {
      if (e.reason == DatabaseLifecycleFailure.recoveryRequired) {
        await _journal.markRecoveryRequired(plan.operationId, now);
        return RestoreResult(RestoreOutcome.recoveryRequired,
            operationId: plan.operationId);
      }
      await _journal.markRolledBack(
          plan.operationId,
          e.reason == DatabaseLifecycleFailure.maintenanceTimeout
              ? 'maintenanceTimeout'
              : 'internal',
          now);
      return RestoreResult(
        e.reason == DatabaseLifecycleFailure.maintenanceTimeout
            ? RestoreOutcome.maintenanceTimeout
            : RestoreOutcome.internalFailure,
        operationId: plan.operationId,
      );
    } on RestorePlanningRepairRequiredException {
      // Thrown BEFORE any destructive mutation — the DB is untouched. The caller
      // repairs the RESTORE_PAYLOAD scope and retries with a decision.
      await _journal.markRolledBack(
          plan.operationId, 'planningRepairRequired', now);
      return RestoreResult(RestoreOutcome.planningCurrencyRepairRequired,
          operationId: plan.operationId);
    } on RestoreCommittedPostStepException {
      // Audit H-20: the destructive transaction COMMITTED and an ancillary
      // post-commit step then failed. Reporting rollback here would be a lie
      // about the user's data.
      return RestoreResult(
        RestoreOutcome.committedPendingBackupState,
        operationId: plan.operationId,
        warnings: [...plan.warnings, _postStepWarning],
      );
    } on RestoreVerificationException {
      return await _terminal(
          plan, 'validationFailed', RestoreOutcome.rollbackCompleted, now);
    } on BackupException {
      return await _terminal(
          plan, 'validationFailed', RestoreOutcome.rollbackCompleted, now);
    } catch (_) {
      return await _terminal(
          plan, 'internal', RestoreOutcome.internalFailure, now);
    }

    // Committed durably (the marker was written INSIDE the transaction). From
    // here onward every failure is classified by [finishCommitted].
    return finishCommitted(RestoreOutcome.success);
  }

  /// Privacy-safe note appended when the restore committed but an ancillary
  /// post-commit step did not finish.
  static const String _postStepWarning = 'post_restore_step_incomplete';

  /// Privacy-safe marker for a committed restore whose key-state publication was
  /// blocked because the prepared admission/account is no longer authoritative.
  static const String backupStateOwnershipConflictWarning =
      'backup_key_state_ownership_conflict';

  /// Audit **H-20** — resolve a failure truthfully.
  ///
  /// The typed post-commit exception covers the failures we can name, but a
  /// throw can also originate AFTER the transaction from something this method
  /// does not enumerate (lease release, connection teardown). The durable
  /// journal is the authority: its committed marker is written INSIDE the
  /// destructive transaction, so if it is present the data is on disk no matter
  /// which layer raised the error. In that case we must not claim rollback —
  /// and `markRolledBack` additionally refuses to overwrite a committed record,
  /// so the evidence survives even if a caller gets this wrong.
  Future<RestoreResult> _terminal(
    RestorePlan plan,
    String errorClass,
    RestoreOutcome rollbackOutcome,
    String now,
  ) async {
    final record = await _journal.find(plan.operationId);
    if (record != null && record.isCommitted) {
      return RestoreResult(
        RestoreOutcome.committedPendingBackupState,
        operationId: plan.operationId,
        warnings: [...plan.warnings, _postStepWarning],
      );
    }
    await _journal.markRolledBack(plan.operationId, errorClass, now);
    return RestoreResult(rollbackOutcome, operationId: plan.operationId);
  }

  /// Idempotently acknowledge a committed restore (the UI calls this after showing
  /// success). Safe to call after a restart that discovered a committed operation.
  Future<void> acknowledge(String operationId) async {
    await _journal.markAcknowledged(
        operationId, DateTime.now().toUtc().toIso8601String());
  }

  /// An opaque, privacy-safe hash of the admission identity — never the raw uid or
  /// generation. Null when no admission is bound.
  static String? _ownerGenerationHash(AdmissionToken? token) {
    if (token == null || token.generation == null) return null;
    return sha256
        .convert(utf8.encode('${token.ownerUid}:${token.generation}'))
        .toString();
  }
}
