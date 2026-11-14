import '../observability/app_diagnostics.dart';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:cryptography/cryptography.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/app_database.dart';
import '../../data/db/database_lease.dart';
import '../../data/db/ownership_guard.dart';
import '../../data/db/replica_store.dart';
import '../session/app_session.dart';
import '../utils/id_generator.dart';
import 'backup_crypto.dart';
import 'backup_service.dart';
import 'backup_snapshot_builder.dart';
import 'remote_backup_store.dart';
import 'restore_controller.dart';
import 'restore_plan.dart';
import 'restore_preparation.dart';
import 'restore_result.dart';
import 'restore_service.dart';
import 'supabase_remote_backup_store.dart';
import '../security/secure_storage_options.dart';

/// Audit **H-23** — how locally cached backup crypto relates to the signed-in
/// account.
enum BackupStateOwnership {
  /// The cache belongs to this account and may be used.
  owned,

  /// It belongs to a DIFFERENT account (or ownership cannot be established).
  /// It must be treated as absent: never read, never used to encrypt, never
  /// surfaced as "backup is on". Deliberately not deleted — the other account
  /// may sign back in, and destroying it would cost recoverability we do not
  /// need to spend.
  foreign,

  /// Pre-owner-binding state with no marker, belonging to the identity that
  /// owns the local database. Adopt it for this account and record the owner.
  adoptable,
}

/// Pure ownership decision (audit H-23). Fail-closed by construction: every
/// ambiguous combination resolves to [BackupStateOwnership.foreign].
BackupStateOwnership classifyBackupStateOwnership({
  required String currentUserId,
  required String? storedOwnerUid,
  required String? localDataOwnerUid,
}) {
  if (currentUserId.isEmpty) return BackupStateOwnership.foreign;
  if (storedOwnerUid != null && storedOwnerUid.isNotEmpty) {
    return storedOwnerUid == currentUserId
        ? BackupStateOwnership.owned
        : BackupStateOwnership.foreign;
  }
  // Legacy state: adopt ONLY for the identity that owns the local database —
  // the same ownership authority the sync backfills use.
  if (localDataOwnerUid != null &&
      localDataOwnerUid.isNotEmpty &&
      localDataOwnerUid == currentUserId) {
    return BackupStateOwnership.adoptable;
  }
  return BackupStateOwnership.foreign;
}

class EncryptedBackupService implements BackupService {
  EncryptedBackupService({
    required AppDatabase database,
    supabase.SupabaseClient? client,
    FlutterSecureStorage? storage,
    BackupCrypto? crypto,
    RemoteBackupStore? remoteStore,
    Future<void> Function()? afterRestore,
    // The admission authority is injected only to make restore-boundary races
    // deterministic in tests. Production uses the shared secure-storage guard.
    OwnershipGuard? ownershipGuard,
    // Audit H-23: the local-database ownership authority, used to adopt
    // pre-owner-binding backup state deterministically. Injected for tests.
    Future<String?> Function()? readLocalDataOwnerUid,
    // O-BX-1: the restore's participation in the session admission drain.
    Future<void> Function(Future<void> Function() run)? maintenanceParticipant,
  })  : _database = database,
        _client = client ?? supabase.Supabase.instance.client,
        _storage = storage ?? SecureStorageOptions.storage,
        _crypto = crypto ?? BackupCrypto(),
        _injectedRemoteStore = remoteStore,
        _afterRestore = afterRestore,
        _ownershipGuard = ownershipGuard ?? OwnershipGuard(),
        _readLocalDataOwnerUid =
            readLocalDataOwnerUid ?? AppSession.instance.readLocalDataOwnerUid,
        _maintenanceParticipant = maintenanceParticipant ??
            AppSession.instance.runMaintenanceParticipant;

  static const _bucket = 'backups';
  static const _enabledKey = 'backup_enabled';
  static const _saltKey = 'backup_salt';
  static const _recoveryKey = 'backup_recovery_code';
  static const _lastKey = 'backup_last_at';
  static const _localKeyKey = 'backup_local_key';
  static const _keySlotsKey = 'backup_key_slots';
  // MALI-076n — marks a slot set + local content key as the v3 authenticated
  // envelope format. Absent ⇒ a legacy (pre-v3) install that keeps its format.
  static const _envelopeVersionKey = 'backup_envelope_version';

  /// Audit **H-23** — the account that owns the locally cached backup crypto.
  ///
  /// Every key above is device-global and none carried an owner. `signOut()`
  /// clears session keys but NOT backup state, so after A signed out and B
  /// signed in, `backupNow()` still saw `backup_enabled == '1'` and encrypted
  /// **B's data with A's content key** — whose slots are wrapped by A's
  /// passphrase and recovery code — then uploaded it to B's path. A could
  /// decrypt B's backup, and B was "protected" by a secret they never chose.
  ///
  /// The state stays DEVICE-scoped (it is a cache for *creating* backups), but
  /// it is now BOUND to one account and is inert for any other. This costs no
  /// recoverability: key slots are serialized into the blob itself
  /// (`BackupBlob.toJson`/`fromJson`), so a restore needs only the blob plus the
  /// passphrase or recovery code — never this cache.
  static const _ownerKey = 'backup_owner_uid';

  final AppDatabase _database;
  final supabase.SupabaseClient _client;
  final FlutterSecureStorage _storage;

  // MALI-076n §5 — safe generation-based publication + verified download.
  final RemoteBackupStore? _injectedRemoteStore;
  late final RemoteBackupStore _remoteStore =
      _injectedRemoteStore ?? SupabaseRemoteBackupStore(_client);
  late final RemoteBackupPublisher _publisher =
      RemoteBackupPublisher(_remoteStore);
  final BackupCrypto _crypto;
  final Future<void> Function()? _afterRestore;
  final OwnershipGuard _ownershipGuard;
  final Future<String?> Function() _readLocalDataOwnerUid;
  final Future<void> Function(Future<void> Function() run)
      _maintenanceParticipant;

  // MALI-014/076n §2/§9 — one restore orchestrator per process so its durable
  // replay journal is consulted across restore attempts.
  late final RestoreService _restoreService = RestoreService(_database);

  // Transient, in-memory prepared-restore state (decrypt outputs) between
  // prepareRestore and the user-confirmed commitRestore. Never exposed to the UI.
  final Map<String, _PreparedRestore> _prepared = {};

  @override
  Future<BackupStatus> status() async {
    // Audit H-23: another account's cached state must not appear as "backup is
    // on" for this one. Signed-out reads report disabled rather than leaking
    // the previous account's status.
    final userId = _client.auth.currentUser?.id;
    final owned = userId != null &&
        userId.isNotEmpty &&
        await _ownedByCurrentAccount(userId);
    final enabled = owned && await _storage.read(key: _enabledKey) == '1';
    final lastRaw = owned ? await _storage.read(key: _lastKey) : null;
    return BackupStatus(
      enabled: enabled,
      lastBackupAt: lastRaw == null ? null : DateTime.tryParse(lastRaw),
    );
  }

  /// Whether this account has a restorable cloud backup.
  ///
  /// This used to look ONLY for the fixed legacy object `<owner>/backup.enc`.
  /// `backupNow()` has not written that path since MALI-076n §5: it publishes
  /// each generation to a unique `<owner>/g/<generationId>.enc` and commits a
  /// pointer. So this returned false for every backup the current code writes
  /// — and it is what the Data Transfer screen and the post-reinstall restore
  /// prompt ask before offering to restore. A user who reinstalled was told
  /// they had no backup while `prepareRestore` would have opened it.
  ///
  /// It now asks in the same order `prepareRestore` does: the committed
  /// generation pointer first, the legacy object only as a fallback. Those two
  /// must agree, or the app offers a restore it cannot perform, or hides one
  /// it could.
  @override
  Future<bool> hasRemoteBackup() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null || userId.isEmpty) return false;
    try {
      final generation = await _remoteStore.readCurrentGeneration();
      if (generation != null) return true;
    } catch (_) {
      // Fall through to the legacy check rather than reporting "no backup"
      // on a transient pointer-read failure.
    }
    try {
      final files = await _client.storage.from(_bucket).list(path: userId);
      return files.any((file) => file.name == 'backup.enc');
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String> enable({required String passphrase}) async {
    final userId = _userId();
    // MALI-076n §6 — v3 uses the passphrase EXACTLY as entered (UTF-8, no trim,
    // no Unicode normalization); whitespace and case are significant.
    final recovery = _generateRecoveryCode();
    final keyBytes = _crypto.randomBytes(32);
    final keySlots = await _crypto.createV3KeySlots(
      contentKey: keyBytes,
      passphrase: passphrase,
      recoveryCode: recovery,
    );

    // Audit H-23: secure-storage calls are independent commits, so disable the
    // old publication before overwriting any in-place material. Until the final
    // `_enabledKey` write, `backupNow()` cannot consume a mixed generation.
    await _storage.delete(key: _enabledKey);
    final successor = <String, String>{
      _envelopeVersionKey: '3',
      _recoveryKey: recovery,
      _keySlotsKey: _encodeKeySlots(keySlots),
      _localKeyKey: base64Encode(keyBytes),
    };
    await _writeAndVerifyKeyState(successor);
    // Retire the legacy representation while the successor is still unpublished.
    await _storage.delete(key: _saltKey);
    // Publish the trust markers LAST. Verify owner before enabling; a failed or
    // torn owner write therefore leaves the state disabled.
    await _writeAndVerifyKeyState({_ownerKey: userId});
    await _storage.write(key: _enabledKey, value: '1');
    try {
      await backupNow();
      await _client.from('profiles').upsert({
        'id': userId,
        'email': _client.auth.currentUser?.email,
        'auth_method':
            _client.auth.currentSession?.user.appMetadata['provider'],
      });
    } catch (_) {
      await _clearLocalBackupState();
      rethrow;
    }
    return recovery;
  }

  /// MALI-058n — the remote-backup metadata row upserted alongside the upload.
  /// It is built ONLY from the user id, the object path, and blob size/version/
  /// time — never from user_settings or any key material — so it can carry no key
  /// canary. Exposed so a test can assert the actual object, not just the source.
  @visibleForTesting
  static Map<String, dynamic> uploadMetadata({
    required String userId,
    required String path,
    required int blobVersion,
    required int sizeBytes,
    required String updatedAtIso,
  }) =>
      {
        'user_id': userId,
        'blob_path': path,
        'blob_version': blobVersion,
        'size_bytes': sizeBytes,
        'updated_at': updatedAtIso,
      };

  @override
  Future<void> backupNow() async {
    return AppDiagnostics.run(AppOperation.backup, () async {
      final userId = _userId();
      // Audit H-23: THE critical gate. Without it a background backup for the
      // newly signed-in account encrypted that account's data with the previous
      // account's content key and uploaded it under the new account's path.
      if (!await _ownedByCurrentAccount(userId)) return;
      final enabled = await _storage.read(key: _enabledKey) == '1';
      if (!enabled) return;

      final saltRaw = await _storage.read(key: _saltKey);
      final keyRaw = await _storage.read(key: _localKeyKey);
      final slotsRaw = await _storage.read(key: _keySlotsKey);
      final recoveryRaw = await _storage.read(key: _recoveryKey);
      if (keyRaw == null ||
          ((slotsRaw == null || slotsRaw.isEmpty) && saltRaw == null)) {
        throw const BackupException('النسخ الاحتياطي يحتاج تفعيل جديد.',
            code: BackupError.needsReenable);
      }

      final keyBytes = base64Decode(keyRaw);

      // MALI-076n — current installs write the v3 authenticated envelope, reusing
      // the stored content key + slots (no passphrase needed for a background
      // backup). Pre-v3 installs keep their existing format until re-enable.
      final isV3 = await _storage.read(key: _envelopeVersionKey) == '3';
      if (isV3 && slotsRaw != null && slotsRaw.isNotEmpty) {
        // MALI-030 (B2-B closure) — stream the snapshot straight to capped plaintext
        // bytes (no full object graph / whole JSON String), then AEAD-seal them.
        final plaintext =
            await BackupSnapshotBuilder(_database).buildEncryptedPlaintext(
          maxBytes: BackupEnvelopeLimits.maxPlaintextBytes,
        );
        final v3Blob =
            await _crypto.encryptEnvelopeV3WithContentKeyFromPlaintext(
          plaintext: plaintext,
          schemaVersion: BackupSnapshotBuilder.currentSchemaVersion,
          contentKey: keyBytes,
          keySlots: _decodeKeySlots(slotsRaw),
        );
        final v3Bytes = v3Blob.toBytes();
        // MALI-076n §5 — publish as a NEW generation: a unique per-generation
        // object path, size-verified upload, compare-and-set pointer commit, then
        // retire the previous object ONLY after the new pointer commits. An
        // interrupted upload can only orphan a new object; the last valid backup is
        // never replaced.
        await _publisher.publish(
          blob: v3Bytes,
          envelopeVersion: v3Blob.version,
          generationId: IdGenerator.uuidV4(),
          operationId: IdGenerator.uuidV4(),
        );
        await _storage.write(
            key: _lastKey, value: DateTime.now().toUtc().toIso8601String());
        return;
      }

      // Legacy (pre-v3) installs only: build the object snapshot lazily here — the
      // common v3 path above never constructs it (it streams straight to plaintext).
      final snapshot = await BackupSnapshotBuilder(_database).build();
      final shouldUpgradeLegacyBackup =
          (slotsRaw == null || slotsRaw.isEmpty) && recoveryRaw != null;
      final blob = shouldUpgradeLegacyBackup
          ? await _crypto.encryptJsonWithRawKey(
              json: snapshot,
              keyBytes: keyBytes,
              keySlots: [
                await _crypto.createKeySlot(
                  type: 'recovery',
                  secret: recoveryRaw,
                  keyBytes: keyBytes,
                ),
              ],
              salt: base64Decode(saltRaw!),
            )
          : slotsRaw == null || slotsRaw.isEmpty
              ? await _crypto.encryptJsonWithKey(
                  json: snapshot,
                  key: SecretKey(keyBytes),
                  salt: base64Decode(saltRaw!),
                )
              : await _crypto.encryptJsonWithRawKey(
                  json: snapshot,
                  keyBytes: keyBytes,
                  keySlots: _decodeKeySlots(slotsRaw),
                );
      if (shouldUpgradeLegacyBackup) {
        await _storage.write(
          key: _keySlotsKey,
          value: _encodeKeySlots(blob.keySlots),
        );
      }
      final bytes = blob.toBytes();
      final path = '$userId/backup.enc';
      try {
        await _client.storage.from(_bucket).uploadBinary(
              path,
              bytes,
              fileOptions: const supabase.FileOptions(
                upsert: true,
                contentType: 'application/octet-stream',
              ),
            );
        final now = DateTime.now().toUtc();
        await _client.from('backups').upsert(uploadMetadata(
              userId: userId,
              path: path,
              blobVersion: blob.version,
              sizeBytes: bytes.length,
              updatedAtIso: now.toIso8601String(),
            ));
        await _storage.write(key: _lastKey, value: now.toIso8601String());
      } on supabase.StorageException catch (error) {
        throw backupStorageException(error);
      }
    });
  }

  /// MALI-076n §3 — DISABLE stops future uploads ONLY. It clears local backup
  /// scheduling + keys but deliberately does NOT delete the remote backup, so the
  /// existing backup stays restorable (with its passphrase) and re-enabling makes
  /// a fresh one. Deleting remote data is a SEPARATE, explicit destructive action
  /// ([deleteRemoteBackups]); the two are never silently combined. The local
  /// database is unaffected either way.
  @override
  Future<void> disable() async {
    await _clearLocalBackupState();
  }

  /// MALI-076n §3 — the explicit destructive action: delete the committed remote
  /// backup object + its pointer (and any legacy fixed object). A failed remote
  /// deletion surfaces a typed [RemoteBackupException]; the local database and
  /// local files are never touched.
  @override
  Future<void> deleteRemoteBackups() async {
    final generation = await _remoteStore.readCurrentGeneration();
    if (generation != null) {
      await _remoteStore.deleteObject(generation.objectPath);
    }
    final owner = _remoteStore.ownerId;
    if (owner != null) {
      try {
        await _client.storage.from(_bucket).remove(['$owner/backup.enc']);
      } on supabase.StorageException {
        // Legacy object may be absent — that is idempotent success.
      }
    }
    await _remoteStore.clearGeneration();
  }

  // MALI-014 §Blocker-1 — there is NO combined prepare+commit production path. A
  // destructive mutation can ONLY be reached through prepareRestore → an explicit
  // user confirmation (which mints the unforgeable RestoreConfirmation capability) →
  // commitRestore(confirmation). Retains the admission that authorised the last
  // committed restore, so the post-commit usability check can detect an ownership
  // change.
  AdmissionToken? _lastRestoreAdmission;
  String? _lastRestoreUserId;

  @override
  Future<RestorePlan> prepareRestore({required String passphrase}) async {
    return AppDiagnostics.run(AppOperation.restore, () async {
      // Bind the entire prepare/commit lifecycle to both authorities at its start:
      // the authenticated user and the admission generation. Capturing only after
      // download/decryption would allow an A operation to be relabelled as B.
      final userId = _userId();
      final admissionToken = await _ownershipGuard.capture();
      if (!await _restoreAdmissionIsCurrent(
        preparedUserId: userId,
        admissionToken: admissionToken,
      )) {
        throw const BackupException(
          'تغيّر الحساب أثناء تجهيز الاستعادة. أعد المحاولة.',
          code: BackupError.accountChangedDuringRestore,
        );
      }
      // MALI-076n §7 — prefer the committed generation, integrity-verified (size +
      // encrypted-blob hash) BEFORE any decryption. A legacy backup with no
      // generation pointer falls back to the fixed object path (integrity still
      // enforced by the v3/legacy envelope authentication below).
      // Discovery (`hasRemoteBackup`) reports a backup when EITHER the pointer
      // or the legacy object exists. Restore used to accept only the pointer
      // once one existed, so an install with both — a pre-generation backup plus
      // a pointer whose object is gone — was offered a restore that could never
      // run, with no way back. The two must agree on what "restorable" means, so
      // a failed generation download falls through to the legacy object rather
      // than ending the attempt.
      final generation = await _remoteStore.readCurrentGeneration();
      Uint8List? bytes;
      if (generation != null) {
        try {
          bytes = await _publisher.downloadVerified(generation);
        } catch (error) {
          // Deliberately broad: a missing object, a size mismatch and a hash
          // mismatch are all "this generation is not usable", and the legacy
          // object is authenticated by its own envelope below either way.
          if (kDebugMode) {
            debugPrint('[Backup] generation unusable (${error.runtimeType}); '
                'trying the legacy object');
          }
        }
      }
      bytes ??=
          await _client.storage.from(_bucket).download('$userId/backup.enc');
      try {
        // MALI-076n §9 — structurally validate + limit BEFORE any KDF, then
        // decrypt/authenticate. NOTHING is mutated in preparation.
        final blob = EncryptedBackupBlob.fromBytesChecked(bytes);
        List<int>? keyBytes;
        Map<String, dynamic> snapshot;
        if (blob.version >= 3) {
          keyBytes =
              await _crypto.unwrapContentKeyV3(blob: blob, secret: passphrase);
          snapshot =
              await _crypto.decryptPayloadV3(blob: blob, contentKey: keyBytes);
        } else if (blob.keySlots.isEmpty) {
          snapshot = await _crypto.decryptJson(
              blob: blob, passphrase: passphrase.trim());
        } else {
          try {
            keyBytes = await _crypto.unwrapKeyFromSlots(
                keySlots: blob.keySlots, secret: passphrase);
            snapshot = await _crypto.decryptJsonWithRawKey(
                blob: blob, keyBytes: keyBytes);
          } on SecretBoxAuthenticationError {
            final legacyKey = await _crypto.deriveKey(
                passphrase: passphrase.trim(), salt: blob.salt);
            keyBytes = await legacyKey.extractBytes();
            snapshot = await _crypto.decryptJsonWithRawKey(
                blob: blob, keyBytes: keyBytes);
          }
        }
        final plan = RestorePreparation.build(
          snapshot: snapshot,
          envelopeVersion: blob.version,
          sourceBytes: bytes,
          operationId:
              generation?.operationId ?? RestorePreparation.fingerprint(bytes),
        );
        // Revalidate the start-of-prepare binding after the asynchronous download,
        // KDF and decryption, before retaining any commit capability.
        if (!await _restoreAdmissionIsCurrent(
          preparedUserId: userId,
          admissionToken: admissionToken,
        )) {
          throw const BackupException(
            'تغيّر الحساب أثناء تجهيز الاستعادة. أعد المحاولة.',
            code: BackupError.accountChangedDuringRestore,
          );
        }
        // Stash sensitive decrypt outputs in memory only. The authoritative user id
        // is retained alongside the admission token and never resolved dynamically
        // during commit or key-state publication.
        _prepared[plan.operationId] = _PreparedRestore(
          plan,
          keyBytes,
          blob,
          passphrase,
          admissionToken,
          userId,
        );
        return plan;
      } on BackupEnvelopeException catch (e) {
        throw _envelopeException(e.kind);
      } on SecretBoxAuthenticationError {
        throw const BackupException('كلمة مرور النسخة الاحتياطية غير صحيحة.',
            code: BackupError.wrongPassphrase);
      } on FormatException {
        throw const BackupException('ملف النسخة الاحتياطية غير صالح.',
            code: BackupError.invalidBackupFile);
      }
    });
  }

  @override
  Future<RestoreResult> commitRestore(
      {required RestoreConfirmation confirmation}) async {
    final plan = confirmation.plan;
    final prepared = _prepared[plan.operationId];
    // The confirmation must be tied to a real prepared operation with a matching
    // source fingerprint, and consumed exactly once (a reused/stale confirmation, a
    // changed source, or an unprepared plan is a typed rejection — no mutation).
    if (prepared == null ||
        prepared.plan.sourceFingerprint != plan.sourceFingerprint) {
      return const RestoreResult(RestoreOutcome.validationFailed);
    }
    if (!confirmation.consume()) {
      return const RestoreResult(RestoreOutcome.validationFailed);
    }
    DatabaseLeaseManager? leaseManager;
    try {
      final location = await ReplicaStore().activeLocation();
      leaseManager = location == null
          ? null
          : await AppDatabase.appSupportLeaseManager(location: location);
    } catch (_) {
      leaseManager = null; // headless/test → logical maintenance
    }
    // Validate the admission captured at PREPARATION — a re-login / ownership change
    // since then rotates the generation and aborts before mutation.
    final result = await _restoreService.execute(
      plan: plan,
      leaseManager: leaseManager,
      ownershipGuard: _ownershipGuard,
      admissionToken: prepared.admissionToken,
      preparedUserId: prepared.userId,
      currentUserId: _currentUserId,
      afterRestore: _afterRestore,
      maintenanceParticipant: _maintenanceParticipant,
    );
    // A committed replay belonging to another admission must not proceed to key
    // publication. RestoreService has already preserved the truthful committed
    // result and attached the ownership-conflict warning.
    if (result.outcome == RestoreOutcome.committedPendingBackupState) {
      _prepared.remove(plan.operationId);
      return result;
    }
    if (result.isCommitted) {
      _lastRestoreAdmission = prepared.admissionToken;
      _lastRestoreUserId = prepared.userId;
      try {
        await _persistKeyStateAfterRestore(prepared);
      } on StaleOwnershipException {
        _prepared.remove(plan.operationId);
        return RestoreResult(
          RestoreOutcome.committedPendingBackupState,
          operationId: result.operationId ?? plan.operationId,
          warnings: [
            ...result.warnings,
            RestoreService.backupStateOwnershipConflictWarning,
          ],
        );
      } catch (_) {
        // Audit H-20: the database commit is already durable. Key-state
        // publication is idempotent, so leave the journal unacknowledged and let
        // a fresh prepare/commit (including after restart) retry only this step.
        _prepared.remove(plan.operationId);
        return RestoreResult(
          RestoreOutcome.committedPendingBackupState,
          operationId: result.operationId ?? plan.operationId,
          warnings: [...result.warnings, 'backup_key_state_pending'],
        );
      }
    }
    _prepared.remove(plan.operationId);
    // NOT acknowledged here — acknowledgement happens only AFTER the controller has
    // proven the database usable (verifyRestoredDatabaseUsable).
    return result;
  }

  /// Post-commit usability proof (MALI-014 §Blocker-2): the restored database must be
  /// readable through a real query AND still owned by the admission that ran the
  /// restore. Returns false → the controller routes to recoveryRequired (never
  /// completed) and does NOT acknowledge; startup recovery re-establishes.
  @override
  Future<bool> verifyRestoredDatabaseUsable() async {
    final admission = _lastRestoreAdmission;
    final userId = _lastRestoreUserId;
    if (admission != null &&
        (userId == null ||
            !await _restoreAdmissionIsCurrent(
              preparedUserId: userId,
              admissionToken: admission,
            ))) {
      return false; // ownership changed after commit
    }
    try {
      await _database
          .customSelect('SELECT COUNT(*) AS c FROM user_settings;')
          .getSingle();
      return true;
    } catch (_) {
      return false; // the connection is not usable
    }
  }

  @override
  Future<void> acknowledgeRestore({required String operationId}) =>
      _restoreService.acknowledge(operationId);

  /// Audit **S-1 / H-23** — DISABLE → WRITE-NEW → VERIFY → RETIRE-OLD →
  /// PUBLISH-OWNER → ENABLE.
  ///
  /// The v2 and legacy-v3 branches used to `delete(_envelopeVersionKey)` FIRST.
  /// A crash or a storage failure in that window left the version marker gone
  /// while the successor key material was not yet written — an ambiguous state
  /// that changes how the NEXT restore interprets the stored material. Every
  /// branch now first invalidates the enable marker, establishes all successor
  /// values, verifies their exact values, and only then retires superseded
  /// values and republishes owner/enabled. No interruption can expose a
  /// half-migrated state to `backupNow()`:
  ///
  ///   * before invalidation fails  → old state remains internally consistent
  ///   * after invalidation         → disabled, regardless of partial writes
  ///   * before publication         → successor is complete and verified
  ///   * after owner publication    → still disabled
  ///   * after enable publication   → complete successor is usable
  ///
  /// An envelope is therefore never "upgraded" until the migration is committed.
  Future<void> _persistKeyStateAfterRestore(_PreparedRestore prepared) async {
    final blob = prepared.blob;
    final keyBytes = prepared.keyBytes;

    /// Retire a superseded marker only after its successor is durable.
    Future<void> retire(Iterable<String> keys) async {
      for (final key in keys) {
        await _storage.delete(key: key);
      }
    }

    // Reject a stale prepared restore before touching even unpublished material.
    await _requirePreparedRestoreAdmission(prepared);

    // Invalidate publication before replacing any in-place key generation.
    await _storage.delete(key: _enabledKey);
    await _requirePreparedRestoreAdmission(prepared);

    if (blob.version >= 3) {
      await _writeAndVerifyKeyState({
        _envelopeVersionKey: '3',
        _localKeyKey: base64Encode(keyBytes!),
        _keySlotsKey: _encodeKeySlots(blob.keySlots),
      });
      await retire([_saltKey, _recoveryKey]);
    } else if (keyBytes == null) {
      // v2: derive and persist the successor material FIRST…
      final key = await _crypto.deriveKey(
          passphrase: prepared.passphrase.trim(), salt: blob.salt);
      await _writeAndVerifyKeyState({
        _saltKey: base64Encode(blob.salt),
        _localKeyKey: base64Encode(await key.extractBytes()),
      });
      // …and only then retire the v3-era markers this envelope supersedes.
      await retire([_envelopeVersionKey, _keySlotsKey]);
    } else {
      await _writeAndVerifyKeyState({
        _localKeyKey: base64Encode(keyBytes),
        _keySlotsKey: _encodeKeySlots(blob.keySlots),
      });
      await retire([_envelopeVersionKey, _saltKey, _recoveryKey]);
    }
    await _storage.write(
        key: _lastKey, value: DateTime.now().toUtc().toIso8601String());
    // Audit H-23/RB4: publish only for the account captured at PREPARE. Re-check
    // both the admission generation and live auth identity immediately before
    // each trust marker. A change after material was written leaves it disabled.
    await _requirePreparedRestoreAdmission(prepared);
    await _writeAndVerifyKeyState({_ownerKey: prepared.userId});
    await _requirePreparedRestoreAdmission(prepared);
    await _storage.write(key: _enabledKey, value: '1');
    // Close the final async-write boundary. An A→B race here is already safe
    // because owner remains A, but removing enabled makes the stale admission's
    // state explicitly retryable and fail-closed as well.
    if (!await _restoreAdmissionIsCurrent(
      preparedUserId: prepared.userId,
      admissionToken: prepared.admissionToken,
    )) {
      await _storage.delete(key: _enabledKey);
      throw const StaleOwnershipException();
    }
  }

  Future<void> _requirePreparedRestoreAdmission(
      _PreparedRestore prepared) async {
    if (!await _restoreAdmissionIsCurrent(
      preparedUserId: prepared.userId,
      admissionToken: prepared.admissionToken,
    )) {
      throw const StaleOwnershipException();
    }
  }

  Future<bool> _restoreAdmissionIsCurrent({
    required String preparedUserId,
    required AdmissionToken admissionToken,
  }) async {
    if (preparedUserId.isEmpty ||
        admissionToken.ownerUid != preparedUserId ||
        admissionToken.generation == null ||
        admissionToken.generation!.isEmpty ||
        _currentUserId() != preparedUserId) {
      return false;
    }
    return _ownershipGuard.isCurrent(admissionToken);
  }

  /// Write every value, then read back and compare the exact successor bytes.
  /// A non-empty-but-stale value is not sufficient proof of durability.
  Future<void> _writeAndVerifyKeyState(Map<String, String> expected) async {
    for (final entry in expected.entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
    for (final entry in expected.entries) {
      if (await _storage.read(key: entry.key) != entry.value) {
        throw const BackupException(
          'تعذّر حفظ حالة النسخ الاحتياطي. أعد المحاولة.',
          code: BackupError.stateSaveFailed,
        );
      }
    }
  }

  // Safe, non-leaking user messages for typed envelope failures (MALI-076n §8).
  // A wrong passphrase, tampering, and corruption are cryptographically
  // indistinguishable, so they share one message.
  static BackupException _envelopeException(BackupEnvelopeErrorKind kind) {
    switch (kind) {
      case BackupEnvelopeErrorKind.authenticationFailed:
        return const BackupException(
          'تعذّر فك النسخة الاحتياطية: كلمة المرور غير صحيحة أو الملف تالف.',
          code: BackupError.decryptFailed,
        );
      case BackupEnvelopeErrorKind.unsupportedVersion:
      case BackupEnvelopeErrorKind.incompatibleSchema:
        return const BackupException(
          'هذه النسخة الاحتياطية من إصدار غير مدعوم. حدّث التطبيق ثم أعد المحاولة.',
          code: BackupError.unsupportedEnvelopeVersion,
        );
      case BackupEnvelopeErrorKind.payloadTooLarge:
      case BackupEnvelopeErrorKind.unsafeKdfParams:
      case BackupEnvelopeErrorKind.unsupportedAlgorithm:
      case BackupEnvelopeErrorKind.malformed:
      case BackupEnvelopeErrorKind.decodeFailed:
        return const BackupException(
          'ملف النسخة الاحتياطية غير صالح.',
          code: BackupError.invalidBackupFile,
        );
    }
  }

  String? _currentUserId() {
    final id = _client.auth.currentUser?.id;
    return id == null || id.isEmpty ? null : id;
  }

  String _userId() {
    final id = _currentUserId();
    if (id == null) {
      throw const BackupException('سجّل الدخول أولاً لتفعيل النسخ الاحتياطي.',
          code: BackupError.signInRequired);
    }
    return id;
  }

  /// Audit **H-23** — whether the cached backup crypto belongs to the signed-in
  /// account. Fail-closed: anything ambiguous means "not enabled here", which
  /// costs a re-enable (passphrase re-entry) and never a backup.
  ///
  /// Legacy migration is DETERMINISTIC: state written before owner binding
  /// carries no marker, so it is adopted only by the identity that owns the
  /// LOCAL DATABASE (`AppSession.readLocalDataOwnerUid`) — the same ownership
  /// authority the sync backfills use. If that marker is absent or names a
  /// different account, the state is treated as foreign and left untouched;
  /// the user re-enables and nothing is destroyed.
  Future<bool> _ownedByCurrentAccount(String userId) async {
    final decision = classifyBackupStateOwnership(
      currentUserId: userId,
      storedOwnerUid: await _storage.read(key: _ownerKey),
      localDataOwnerUid: await _readLocalDataOwnerUid(),
    );
    switch (decision) {
      case BackupStateOwnership.owned:
        return true;
      case BackupStateOwnership.adoptable:
        await _storage.write(key: _ownerKey, value: userId);
        return true;
      case BackupStateOwnership.foreign:
        return false;
    }
  }

  String _generateRecoveryCode() {
    const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final rng = Random.secure();
    String block() =>
        List.generate(4, (_) => chars[rng.nextInt(chars.length)]).join();
    return '${block()}-${block()}-${block()}';
  }

  Future<void> _clearLocalBackupState() async {
    await _storage.delete(key: _enabledKey);
    await _storage.delete(key: _ownerKey);
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _recoveryKey);
    await _storage.delete(key: _lastKey);
    await _storage.delete(key: _localKeyKey);
    await _storage.delete(key: _keySlotsKey);
    await _storage.delete(key: _envelopeVersionKey);
  }

  String _encodeKeySlots(List<BackupKeySlot> slots) {
    return jsonEncode(slots.map((slot) => slot.toJson()).toList());
  }

  List<BackupKeySlot> _decodeKeySlots(String raw) {
    return BackupKeySlot.listFromJson(jsonDecode(raw));
  }
}

BackupException backupStorageException(supabase.StorageException error) {
  if (error.statusCode == '404' ||
      error.message.toLowerCase().contains('bucket not found')) {
    // «جرّب تاني» was Egyptian colloquial; MSA is «أعد المحاولة».
    return const BackupException(
      'إعداد النسخ الاحتياطي غير مكتمل: أنشئ Storage bucket باسم backups '
      'في Supabase ثم أعد المحاولة.',
      code: BackupError.bucketMissing,
    );
  }
  return BackupException(
    'فشل رفع النسخة الاحتياطية: ${error.message}',
    code: BackupError.uploadFailed,
    args: [error.message],
  );
}

/// Kept for log lines and for callers that genuinely want only the words.
String backupStorageExceptionMessage(supabase.StorageException error) =>
    backupStorageException(error).message;

// Transient decrypt state held between prepareRestore and commitRestore. Lives in
// memory only and is discarded after commit — the key never reaches the UI or disk
// except as the existing backup key-state (unchanged behavior).
class _PreparedRestore {
  _PreparedRestore(this.plan, this.keyBytes, this.blob, this.passphrase,
      this.admissionToken, this.userId);
  final RestorePlan plan;
  final List<int>? keyBytes;
  final EncryptedBackupBlob blob;
  final String passphrase;
  final AdmissionToken admissionToken;
  final String userId;
}
