import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/session/admission_authority.dart';
import '../../core/privacy/cloud_egress_gate.dart';
import '../../core/session/consent_capability.dart';
import '../../core/session/merchant_preference_writer.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../../features/planning_sync/services/planning_outbox_queue.dart';
import '../../core/observability/app_diagnostics.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';
import 'drift_repository_support.dart';

/// MALI-059n: the versioned tri-state consent → nullable TEXT column
/// (unset ⇒ NULL). Read back by `_consentStateFromRow` in the support layer.
Variable _consentStateVariable(ConsentState state) {
  switch (state) {
    case ConsentState.accepted:
      return Variable.withString('accepted');
    case ConsentState.declined:
      return Variable.withString('declined');
    case ConsentState.unset:
      return const Variable<String>(null);
  }
}

class DriftUserSettingsRepository
    implements
        UserSettingsRepository,
        ConsentSettingsWriter,
        MerchantPreferenceWriter {
  DriftUserSettingsRepository(
    this._db, {
    PlanningOutboxQueue? outboxQueue,
    @visibleForTesting void Function()? afterConsentFinalGuard,
    @visibleForTesting Future<void> Function()? beforeMerchantUpdate,
    @visibleForTesting Future<void> Function()? afterMerchantUpdate,
  })  : _outboxQueue = outboxQueue,
        _afterConsentFinalGuard = afterConsentFinalGuard,
        _beforeMerchantUpdate = beforeMerchantUpdate,
        _afterMerchantUpdate = afterMerchantUpdate;

  final AppDatabase _db;
  final Future<void> Function()? _beforeMerchantUpdate;
  final Future<void> Function()? _afterMerchantUpdate;

  /// Test-only, null in production: called synchronously right after the final
  /// authorization check of [saveConsentChoice], before the callback returns, so a
  /// test can start a logout exactly between that check and COMMIT.
  final void Function()? _afterConsentFinalGuard;

  /// A retained service may reject work before touching a retired database.
  bool get isDatabaseOpen => _db.lifecycleState == DatabaseLifecycleState.open;
  final PlanningOutboxQueue? _outboxQueue;

  @override
  Future<UserSettingsEntity> getSettings() async {
    final row = await _db
        .customSelect(
          'SELECT * FROM user_settings LIMIT 1;',
        )
        .getSingle();
    return userSettingsFromRow(row);
  }

  @override
  Future<UserSettingsEntity> saveSettings(UserSettingsEntity settings) =>
      _db.transaction(() => _saveWithinTransaction(settings));

  /// A local notification may arrive concurrently with another delivery or
  /// a settings change. Append inside the transaction and only write its field.
  Future<void> appendNotificationHistory(NotificationHistoryEntry entry,
      {required bool Function() isCurrent}) async {
    if (!isCurrent() || !isDatabaseOpen) return;
    await _db.transaction(() async {
      if (!isCurrent()) return;
      final settings = await getSettings();
      if (!isCurrent()) return;
      final json = settings.notificationsJson.isEmpty
          ? <String, dynamic>{}
          : jsonDecode(settings.notificationsJson) as Map<String, dynamic>;
      final inbox = NotificationInboxState.fromJson(
          json['notificationInboxState'] as Map<String, dynamic>?);
      json['notificationInboxState'] = inbox.addHistory(entry).toJson();
      await _db.customUpdate(
        'UPDATE user_settings SET notifications_json = ? WHERE id = ?;',
        variables: [
          Variable.withString(jsonEncode(json)),
          Variable.withString(settings.id),
        ],
      );
      if (!isCurrent()) throw const StaleAdmissionException();
    });
  }

  /// A field-scoped local preference write. No settings snapshot or outbox is
  /// involved, so a concurrent consent decision cannot be carried back here.
  @override
  Future<void> saveMerchantPersonalization(
    AdmissionAuthority authority,
    AppDatabase? database,
    bool enabled,
  ) async {
    void check() {
      authority.requireCurrent();
      if (database == null || !identical(database, _db) || !isDatabaseOpen) {
        throw const StaleAdmissionException();
      }
    }

    check();
    await _db.transaction(() async {
      check();
      final owner = await _db
          .customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;')
          .getSingleOrNull();
      check();
      if (owner == null || owner.read<String>('owner_uid') != authority.uid) {
        throw const StaleAdmissionException();
      }
      final settingsIds =
          await _db.customSelect('SELECT id FROM user_settings LIMIT 2;').get();
      check();
      if (settingsIds.length != 1) {
        throw StateError('merchant_settings_not_singleton');
      }
      final settingsId = settingsIds.single.read<String>('id');
      await _beforeMerchantUpdate?.call();
      check();
      final affected = await _db.customUpdate(
        'UPDATE user_settings SET merchant_personalization_enabled = ? '
        'WHERE id = ?;',
        variables: [
          Variable.withInt(enabled ? 1 : 0),
          Variable.withString(settingsId),
        ],
      );
      check();
      if (affected != 1) {
        throw StateError('merchant_settings_not_updated');
      }
      await _afterMerchantUpdate?.call();
      // Final synchronous guard before the transaction callback returns.
      check();
    });
  }

  /// The consent decision, as ONE typed transaction. Unlike [saveSettings] it
  /// takes no caller-supplied entity: it reads the CURRENT row and merges only
  /// the consent [choices] into it, so a stale entity can neither carry along nor
  /// overwrite any other setting. The capability, the database and the replica
  /// owner are checked INSIDE the transaction, and again after every awaited
  /// step: after the UPDATE, after the atomic local outbox enqueue and, last, in a
  /// final synchronous check immediately before the callback returns. A failed
  /// check throws [StaleAdmissionException] inside the transaction, so the
  /// settings AND the outbox row roll back together. Drift awaits this callback
  /// and only then sends COMMIT: a choice authorized at that final check is a
  /// legitimate local persistence and is never claimed to be rolled back. The
  /// future completes only after the transaction settled.
  @override
  Future<UserSettingsEntity> saveConsentChoice(
    ConsentCapability capability,
    ConsentChoices choices,
  ) async {
    await beforeConsentChoice(capability, choices);
    final saved = await _saveConsentChoice(capability, choices);
    afterConsentChoice(capability, choices);
    _recordConsentCommit(saved);
    return saved;
  }

  /// Test interception shared by ordinary and reserved writes, outside SQL.
  @visibleForTesting
  Future<void> beforeConsentChoice(
      ConsentCapability capability, ConsentChoices choices) async {}

  @visibleForTesting
  void afterConsentChoice(ConsentCapability capability, ConsentChoices choices) {}

  Future<UserSettingsEntity> _saveConsentChoice(
    ConsentCapability capability,
    ConsentChoices choices, {
    _ReservedCommit? token,
  }) async {
    capability.requireCurrent();
    if (!identical(capability.database, _db)) {
      throw const StaleAdmissionException();
    }
    return _db.transaction(() async {
      capability.requireCurrent();
      final owner = await _db
          .customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;')
          .getSingleOrNull();
      capability.requireCurrent();
      if (owner == null || owner.read<String>('owner_uid') != capability.uid) {
        throw const StaleAdmissionException();
      }
      final previous = await getSettings();
      capability.requireCurrent();
      // The explicit enable commits at exactly its reservation: only the matching
      // operation (uid, capability epoch, operation id and exact version) may.
      // Any other consent change allocates above the watermark and
      // invalidates a reservation it does not own (the enable then aborts
      // restrictively instead of committing below a newer version).
      int? exactVersion;
      if (token != null) {
        final marks = await _versionMarks();
        capability.requireCurrent();
        final pending = token.pending;
        final owns = marks.operationId == token.operationId &&
            marks.uid == capability.uid &&
            marks.reserved == token.version &&
            (pending == null ||
                (pending.ownerUid == capability.uid &&
                    pending.localOperationId == token.operationId &&
                    pending.reservedVersion == token.version));
        if (!owns || token.version <= previous.consentVersion ||
            marks.watermark != token.version) {
          throw const StaleAdmissionException();
        }
        if (marks.epoch != capability.epoch) {
          final proof = token.proof;
          if (proof == null) throw const StaleAdmissionException();
          await proof.verifyLocal(capability);
          capability.requireCurrent();
          // The proof rebinds this exact durable reservation, never a version-only
          // fallback. All checks and the rebind roll back with the consent write.
          final rebound = await _db.customUpdate(
            'UPDATE consent_version_watermark SET reserved_epoch = ? '
            'WHERE id = 1 AND reserved_uid = ? AND reserved_op = ? '
            'AND reserved = ? AND watermark = ? AND reserved_epoch = ?;',
            variables: [Variable.withInt(capability.epoch),
              Variable.withString(capability.uid), Variable.withString(token.operationId),
              Variable.withInt(token.version), Variable.withInt(token.version),
              Variable<int>(marks.epoch)],
          );
          capability.requireCurrent();
          if (rebound != 1) throw const StaleAdmissionException();
        } else if (token.proof != null) {
          await token.proof!.verifyLocal(capability);
          capability.requireCurrent();
        }
        exactVersion = token.version;
      }
      final saved = await _saveWithinTransaction(
        choices.applyTo(previous),
        checkpoint: capability.requireCurrent,
        exactVersion: exactVersion,
        explicitConsent: choices.cloud != null || choices.ai != null,
      );
      capability.requireCurrent();
      // The FINAL synchronous authorization point: nothing is awaited between
      // this check and the callback returning (COMMIT is sent after that).
      capability.requireCurrent();
      _afterConsentFinalGuard?.call();
      return saved;
    });
  }

  Future<({int watermark, int reserved, String? uid, int? epoch, String? operationId})>
      _versionMarks() async {
    final row = await _db
        .customSelect('SELECT watermark, reserved, reserved_uid, reserved_epoch, '
            'reserved_op FROM consent_version_watermark WHERE id = 1;')
        .getSingleOrNull();
    return (
      watermark: row?.read<int>('watermark') ?? 0,
      reserved: row?.read<int>('reserved') ?? 0,
      uid: row?.read<String?>('reserved_uid'),
      epoch: row?.read<int?>('reserved_epoch'),
      operationId: row?.read<String?>('reserved_op'),
    );
  }

  /// The explicit consent operation's version RESERVATION (allocation metadata,
  /// not consent): strictly above every version this device has committed,
  /// reserved or watermarked and above [verifiedFrontier], the highest version the
  /// caller VERIFIED in durable egress evidence of this owner (it can only raise
  /// the result). The reservation is bound to the owner uid, the capability epoch
  /// and [operationId]; only that operation's commit
  /// ([saveReservedConsentChoice]) consumes it. Changes no consent state, boolean
  /// or timestamp and enqueues nothing. The capability, the database and the
  /// replica owner are checked inside the transaction.
  Future<int> reserveConsentVersion(
    ConsentCapability capability, {
    required int verifiedFrontier,
    required String operationId,
  }) async {
    capability.requireCurrent();
    if (!identical(capability.database, _db)) {
      throw const StaleAdmissionException();
    }
    return _db.transaction(() async {
      capability.requireCurrent();
      final owner = await _db
          .customSelect('SELECT owner_uid FROM replica_meta WHERE id = 1;')
          .getSingleOrNull();
      capability.requireCurrent();
      if (owner == null || owner.read<String>('owner_uid') != capability.uid) {
        throw const StaleAdmissionException();
      }
      final committed = await _db
          .customSelect('SELECT MAX(cloud_consent_version, ai_consent_version) '
              'AS v FROM user_settings;')
          .getSingleOrNull();
      final marks = await _versionMarks();
      capability.requireCurrent();
      var floor = committed?.read<int?>('v') ?? 0;
      for (final v in [marks.watermark, marks.reserved, verifiedFrontier]) {
        if (v > floor) floor = v;
      }
      final reserved = floor + 1;
      await _db.customStatement(
        'INSERT OR IGNORE INTO consent_version_watermark(id, watermark, reserved) '
        'VALUES (1, 0, 0);',
      );
      await _db.customUpdate(
        'UPDATE consent_version_watermark SET watermark = ?, reserved = ?, '
        'reserved_uid = ?, reserved_epoch = ?, reserved_op = ? WHERE id = 1;',
        variables: [
          Variable.withInt(reserved),
          Variable.withInt(reserved),
          Variable.withString(capability.uid),
          Variable.withInt(capability.epoch),
          Variable.withString(operationId),
        ],
      );
      capability.requireCurrent();
      return reserved;
    });
  }

  /// [saveConsentChoice] for the explicit enable: commits at EXACTLY [version]
  /// when this operation owns the reservation. A resume also supplies its typed
  /// [proof] identity; otherwise nothing is written
  /// and [StaleAdmissionException] is thrown.
  Future<UserSettingsEntity> saveReservedConsentChoice(
    ConsentCapability capability,
    ConsentChoices choices, {
    required int version,
    required String operationId,
    PendingEnableCommitProof? proof,
  }) async {
    await beforeConsentChoice(capability, choices);
    final saved = await _saveConsentChoice(capability, choices,
        token: _ReservedCommit(version, operationId, proof));
    afterConsentChoice(capability, choices);
    _recordConsentCommit(saved);
    return saved;
  }

  void _recordConsentCommit(UserSettingsEntity saved) {
    AppDiagnostics.record(
        AppOperation.cloudConsent,
        saved.cloudProcessingEnabled
            ? AppEventState.enabled
            : AppEventState.disabled,
        revision: saved.consentVersion);
    AppDiagnostics.record(AppOperation.aiConsent,
        saved.aiConsentGranted ? AppEventState.enabled : AppEventState.disabled,
        revision: saved.consentVersion);
  }

  Future<UserSettingsEntity> _saveWithinTransaction(
    UserSettingsEntity settings, {
    void Function()? checkpoint,
    int? exactVersion,
    bool explicitConsent = false,
  }) async {
    {
      // Cloud/AI consent persists exactly as the user chose (MALI-001) — the
      // former forced-true clamp made the privacy toggles meaningless.
      final previousSettings = await getSettings();
      final requiredSettings = settings.copyWith(
        notificationsJson: NotificationInboxState.mergeHistoryJson(
            settings.notificationsJson, previousSettings.notificationsJson),
      );
      final marks = await _versionMarks();
      // The reads above are async boundaries: the lifecycle is revalidated here,
      // BEFORE the first mutation (a failure throws inside the transaction).
      checkpoint?.call();
      final cloudChanged = previousSettings.cloudConsentState !=
          requiredSettings.cloudConsentState;
      final aiChanged =
          previousSettings.aiConsentState != requiredSettings.aiConsentState;
      final consentChanged = cloudChanged || aiChanged;
      // WP-6: versions are assigned HERE from the stored row, never taken from
      // the caller's entity, so a stale entity can neither lower a version nor
      // invent one. Any change of either consent moves the shared version
      // strictly forward; an untouched consent keeps its own version and time.
      // The device watermark governs EVERY consent commit: an unreserved change
      // allocates above the local history, the watermark and any reservation.
      var floor = previousSettings.consentVersion;
      if (marks.watermark > floor) floor = marks.watermark;
      if (marks.reserved > floor) floor = marks.reserved;
      final nextVersion = exactVersion ?? floor + 1;
      final changedAt = dateTimeToSql(DateTime.now().toUtc());
      Variable<String> consentAt(bool changed, DateTime? previous) => changed
          ? Variable.withString(changedAt)
          : previous == null
              ? const Variable<String>(null)
              : Variable.withString(dateTimeToSql(previous.toUtc()));
      await _db.customUpdate(
        '''
        UPDATE user_settings
        SET display_name = ?, phone_number = ?, avatar_path = ?,
            date_of_birth = ?,
            country = ?, currency = ?, language = ?, theme = ?, input_method = ?,
            notifications_json = ?, db_encryption_key_ref = ?,
            privacy_mode_enabled = ?, ai_consent_granted = ?,
            cloud_processing_enabled = ?, ai_consent_state = ?,
            cloud_consent_state = ?,
            cloud_consent_version = ?, cloud_consent_at = ?,
            ai_consent_version = ?, ai_consent_at = ?,
            merchant_personalization_enabled = ?,
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))}
        WHERE id = ?;
      ''',
        variables: [
          requiredSettings.displayName == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.displayName!),
          requiredSettings.phoneNumber == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.phoneNumber!),
          requiredSettings.avatarPath == null
              ? const Variable<String>(null)
              : Variable.withString(requiredSettings.avatarPath!),
          requiredSettings.dateOfBirth == null
              ? const Variable<String>(null)
              : Variable.withString(
                  requiredSettings.dateOfBirth!.toUtc().toIso8601String()),
          Variable.withString(requiredSettings.country),
          Variable.withString(requiredSettings.currency),
          Variable.withString(requiredSettings.language),
          Variable.withString(requiredSettings.theme),
          Variable.withString(requiredSettings.inputMethod),
          Variable.withString(requiredSettings.notificationsJson),
          // MALI-058n — never persist key material: this deprecated column is
          // always written empty, regardless of the entity value.
          const Variable<String>(''),
          Variable.withInt(requiredSettings.privacyModeEnabled ? 1 : 0),
          // MALI-059n: the effective grant is DERIVED from the versioned state,
          // so the boolean and the state can never drift apart on disk.
          Variable.withInt(requiredSettings.aiConsentGranted ? 1 : 0),
          Variable.withInt(requiredSettings.cloudProcessingEnabled ? 1 : 0),
          _consentStateVariable(requiredSettings.aiConsentState),
          _consentStateVariable(requiredSettings.cloudConsentState),
          Variable.withInt(cloudChanged
              ? nextVersion
              : previousSettings.cloudConsentVersion),
          consentAt(cloudChanged, previousSettings.cloudConsentAt),
          Variable.withInt(
              aiChanged ? nextVersion : previousSettings.aiConsentVersion),
          consentAt(aiChanged, previousSettings.aiConsentAt),
          // COUPONS Phase 1 — persisted locally and DELIBERATELY absent from
          // the settings sync payload below. See UserSettingsEntity.
          Variable.withInt(
              requiredSettings.merchantPersonalizationEnabled ? 1 : 0),
          Variable.withString(requiredSettings.id),
        ],
      );
      if (consentChanged) {
        await _db.customStatement(
          'INSERT OR IGNORE INTO consent_version_watermark(id, watermark, reserved) '
          'VALUES (1, 0, 0);',
        );
        // The watermark rises; the reservation is consumed by its own operation's
        // commit and invalidated by any other consent change.
        await _db.customUpdate(
          'UPDATE consent_version_watermark SET watermark = MAX(watermark, ?), '
          'reserved = 0, reserved_uid = NULL, reserved_epoch = NULL, '
          'reserved_op = NULL WHERE id = 1;',
          variables: [Variable.withInt(nextVersion)],
        );
      }
      checkpoint?.call(); // after the SQL, before the outbox
      final changedAtValue = dateTimeFromSql(changedAt);
      final saved = requiredSettings.copyWith(
        cloudConsentVersion:
            cloudChanged ? nextVersion : previousSettings.cloudConsentVersion,
        cloudConsentAt:
            cloudChanged ? changedAtValue : previousSettings.cloudConsentAt,
        aiConsentVersion:
            aiChanged ? nextVersion : previousSettings.aiConsentVersion,
        aiConsentAt: aiChanged ? changedAtValue : previousSettings.aiConsentAt,
      );
      // S2: أدرج التفضيلات السحابية للمزامنة في الخلفية (الأعمدة السحابية فقط).
      final queued = await _outboxQueue?.enqueueSettings(
        PlanningSyncOperation.update,
        saved,
        // Retrying the same explicit choice must resend its consent fields,
        // even when its local value/version were already saved successfully.
        consentChanged: consentChanged || explicitConsent,
        previous: previousSettings,
      );
      AppDiagnostics.record(AppOperation.settingsQueue,
          queued == true ? AppEventState.pending : AppEventState.blocked,
          reason: queued == true ? AppEventReason.none
              : _outboxQueue == null ? AppEventReason.unavailable : AppEventReason.ownerMissing,
          revision: saved.consentVersion);
      checkpoint?.call(); // after the atomic local outbox enqueue
      return saved;
    }
  }
}

class _ReservedCommit {
  const _ReservedCommit(this.version, this.operationId, this.proof);
  final int version;
  final String operationId;
  final PendingEnableCommitProof? proof;
  PendingEnableRecord? get pending => proof?.pending;
}
