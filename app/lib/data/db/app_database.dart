import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../core/utils/id_generator.dart';
import '../../core/observability/database_diagnostics.dart';
import 'creation_policy.dart';
import 'database_key_store.dart';
import 'existing_only_sqlite3.dart';
import 'database_lease.dart';
import 'database_process_liveness.dart';
import 'database_seed.dart';
import 'money_v30_backfill.dart';
import 'ownership_guard.dart';
import 'replica_location.dart';
import 'sql_value_codec.dart';

// v28 (MALI-014 Batch-5 closure): adds the durable `restore_operations` journal
// (created idempotently by _createSchema on both fresh install and upgrade).
const int _targetSchemaVersion = 42;

/// The notification preferences of the seeded default settings row. Shared so a
/// recovery can tell the pristine seed from a row the user has edited.
const String kDefaultSettingsNotificationsJson =
    '{"captureReview":true,"captureLight":true,"budgetWarning":true,"budgetOver":true,"achievements":true,"weeklyReport":true,"subscriptionReminder":true,"goalMilestone":true,"quietHoursEnabled":false,"quietHoursStartHour":23,"quietHoursEndHour":8,"notifiedGoalMilestones":{}}';

/// MALI-027 — the on-disk database was created by a NEWER build than this one
/// (its `user_version` exceeds [_targetSchemaVersion]). Initialization fails
/// closed BEFORE any read/write so a stale binary never operates on a schema it
/// does not understand. Deliberately distinct from [MigrationIntegrityException]
/// and generic errors so the caller can prompt the user to update the app
/// (a recoverable, non-destructive condition) rather than treat it as corruption.
class UnsupportedDatabaseVersionException implements Exception {
  const UnsupportedDatabaseVersionException({
    required this.databaseVersion,
    required this.supportedVersion,
  });

  /// The `PRAGMA user_version` found on disk.
  final int databaseVersion;

  /// The newest version this build knows how to run ([_targetSchemaVersion]).
  final int supportedVersion;

  @override
  String toString() =>
      'UnsupportedDatabaseVersionException: database schema v$databaseVersion '
      'is newer than this build supports (v$supportedVersion) — update the app.';
}

/// MALI-027 — a post-migration integrity check failed: a required table is
/// missing, foreign-key enforcement could not be enabled, or `foreign_key_check`
/// reported dangling references. Carries ONLY non-sensitive structural
/// diagnostics (table / constraint identity) — never financial row contents.
/// Distinct from [UnsupportedDatabaseVersionException] so the caller can tell
/// "this build cannot run this schema" apart from "the migration produced an
/// inconsistent schema".
class MigrationIntegrityException implements Exception {
  const MigrationIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'MigrationIntegrityException: $message';
}

/// MALI-027 — a discrete, version-keyed schema migration (the forward contract
/// for new schema changes). Applied inside the atomic migration transaction:
/// [apply] performs the change; [postcondition] (optional) returns false to
/// abort (and roll back) if the change didn't take.
class _SchemaMigration {
  const _SchemaMigration({
    required this.from,
    required this.to,
    required this.apply,
    // Forward-contract API: no registered migration supplies it YET (the
    // registry is empty until the first versioned schema change lands).
    // ignore: unused_element_parameter
    this.postcondition,
  });

  final int from;
  final int to;
  final Future<void> Function(AppDatabase db) apply;
  final Future<bool> Function(AppDatabase db)? postcondition;
}

/// Stable local id reserved for the default account ("الحساب الرئيسي").
/// No account is auto-seeded (A-7: there is no silent default account); an
/// existing install's account keeps this id. The id is deliberately NOT random,
/// so any path that (re)creates it stays idempotent and the sync
/// backfill/pull matches the existing server row instead of duplicating it.
/// (User-created accounts keep using random IdGenerator ids.)
const String kDefaultAccountLocalId = 'default_account';

/// MALI-069n §2 — the database connection lifecycle. A failed open never leaves a
/// live connection/isolate; close is idempotent and waits for init to settle.
enum DatabaseLifecycleState {
  opening,
  open,
  maintenanceRequested,
  closing,
  closed,
  failed,

  /// An exclusive maintenance operation could not restore a usable database.
  /// No partially-initialized database is published; the owner must reset/reopen.
  recoveryRequired,
}

/// MALI-069n — typed, privacy-safe database-lifecycle failures. Carry no SQL,
/// key, path, bound value, user id, or financial row.
enum DatabaseLifecycleFailure {
  closed,
  recoveryRequired,
  maintenanceTimeout,

  /// A read-only (offline local-read) owner can never authorize a writable
  /// secondary connection.
  readOnlyOwner,
}

class DatabaseLifecycleException implements Exception {
  const DatabaseLifecycleException(this.reason);
  final DatabaseLifecycleFailure reason;
  @override
  String toString() => 'DatabaseLifecycleException(${reason.name})';
}

/// MALI-069n §Blocker-2 — maintenance modes.
enum MaintenanceMode {
  /// Logical maintenance over the existing open connection (no file-level lock).
  logical,

  /// File-exclusive maintenance: every isolate/process must be quiesced; acquires
  /// the cross-isolate exclusive lease before running (Batch-5 destructive
  /// restore/reset uses this).
  fileExclusive,
}

/// MALI-069n §Blocker-3 — a transient, retryable busy/locked condition after the
/// bounded busy_timeout wait expires. Never carries the raw SQLite message.
class DatabaseBusyException implements Exception {
  const DatabaseBusyException();
  bool get isRetryable => true;
  @override
  String toString() => 'DatabaseBusyException';
}

/// Map a caught database error to a typed [DatabaseBusyException] when it is a
/// SQLITE_BUSY (5) / SQLITE_LOCKED (6) result (including the 261/262 extended
/// codes); otherwise return null so a non-busy error is never misclassified. Uses
/// only the numeric result code — never the raw exception text.
DatabaseBusyException? mapDatabaseBusy(Object error) {
  if (error is SqliteException) {
    final code = error.extendedResultCode;
    final primary = code & 0xFF; // low byte = primary result code
    if (primary == 5 || primary == 6) return const DatabaseBusyException();
  }
  return null;
}

/// Verification failed and the real read-only handle could not be closed.
/// The receiver must retain [database] until its actual close succeeds.
class ReadOnlyCleanupIncompleteException implements Exception {
  const ReadOnlyCleanupIncompleteException(this.database);

  final AppDatabase database;

  @override
  String toString() => 'ReadOnlyCleanupIncompleteException: cleanup incomplete.';
}

/// Offline local read — the existing database's schema is not exactly the one
/// this build runs (`user_version` older or newer). A read-only connection never
/// migrates, so the replica is unavailable for reading until a normal open
/// upgrades it. Carries only version numbers.
class ReadOnlySchemaUnsupportedException implements Exception {
  const ReadOnlySchemaUnsupportedException({
    required this.databaseVersion,
    required this.supportedVersion,
  });

  final int databaseVersion;
  final int supportedVersion;

  @override
  String toString() =>
      'ReadOnlySchemaUnsupportedException: database schema v$databaseVersion '
      'cannot be read by this build (v$supportedVersion).';
}

/// Offline local read — the key source of a read-only open. It can only READ the
/// stored key; minting is structurally impossible.
class _ReadOnlyKeyStore implements DatabaseKeyStore {
  const _ReadOnlyKeyStore(this._read);
  final Future<String?> Function() _read;

  @override
  Future<String> readOrCreateKey() =>
      Future.error(const DatabaseCreationNotAuthorizedException());

  @override
  Future<String?> readStoredKey() => _read();
}

class AppDatabase extends GeneratedDatabase {
  AppDatabase._(
    DatabaseConnection connection, {
    required this.keyStore,
    required this.isEncrypted,
    this.isReadOnly = false,
    this.initialLanguage = 'en',
  }) : super.connect(connection.interceptWith(DatabaseDiagnostics()));

  final DatabaseKeyStore keyStore;
  final bool isEncrypted;

  /// Used only when creating the settings row. Existing choices are untouched.
  final String initialLanguage;

  /// True for the offline local-read connection ([openReadOnlyExisting]): SQLite
  /// itself opened the file read-only, and [initialize] refuses to run.
  final bool isReadOnly;
  final _manualRevisionController = StreamController<int>.broadcast();
  // MALI-029 — table-scoped write signal: emits the TARGET table of every data
  // write (raw-SQL and Drift-API alike) so providers can subscribe to only the
  // domains they read, instead of the global manualRevisionStream that rebuilds
  // every watcher on every write. The target table of single-table DML is
  // unambiguous (the identifier right after INTO / UPDATE / FROM).
  final _tableWriteController = StreamController<String>.broadcast();

  DatabaseLifecycleState _lifecycle = DatabaseLifecycleState.opening;

  /// The current typed lifecycle state (MALI-069n §2).
  DatabaseLifecycleState get lifecycleState => _lifecycle;
  var _manualRevision = 0;

  @override
  int get schemaVersion => _targetSchemaVersion;

  // Migrations are handled manually in initialize() → _runCompatibilityMigrations(),
  // which uses IF NOT EXISTS / ADD COLUMN IF NOT EXISTS and is fully idempotent.
  // This no-op strategy prevents Drift from throwing when it detects a version bump
  // on an existing database before initialize() has had a chance to run.
  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {},
        onUpgrade: (m, from, to) async {},
      );

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  static Future<AppDatabase> open({
    DatabaseKeyStore? keyStore,
    QueryExecutor? executor,
    // MALI-069n §6 — a secondary (background/second-connection) open passes
    // false: it uses the same key + PRAGMA contract but does NOT run the
    // migration pipeline, so the file's migrations are never run concurrently
    // from two connections. The MAIN application open (the sole migration owner)
    // uses the default true. See [openSecondary].
    bool runMigrations = true,
    String initialLanguage = 'en',
    // WP-3a — which database file/key to open. Null = the legacy shared
    // `money_companion.sqlite` in the app-support directory (today's behaviour).
    ReplicaLocation? location,
    // F2 — what this open may CREATE (the database file, its directory, its key).
    // [CreationPolicy.denied] opens the existing file only: a missing database is
    // refused with [DatabaseCreationNotAuthorizedException] BEFORE any key is read
    // or minted and without creating any directory. Secondary and launch opens
    // pass it; only an admission that holds creation authority for the uid
    // creates, and every layer below re-verifies that authority first.
    CreationPolicy creation = const CreationPolicy.unrestricted(),
    @visibleForTesting Future<bool> Function()? databaseFileExists,
    @visibleForTesting Future<void> Function(String phase)? debugFailInit,
  }) async {
    // The existence probe goes INTO the store: the no-mint-over-an-existing-DB
    // invariant then holds wherever the store is used, not only on the path
    // that remembers to check first.
    final replicaLocation = executor == null
        ? (location ?? await ReplicaLocation.legacy())
        : location;
    final fileExists =
        databaseFileExists ?? (() => File(replicaLocation!.dbPath).exists());
    // A file that is not there can only be CREATED: refuse BEFORE any key read,
    // key mint or directory creation unless creation is authorized right now.
    creation.requireCurrent();
    final createsFile = executor == null && !await fileExists();
    creation.requireCurrent();
    if (createsFile) creation.requireMayCreate();
    final resolvedKeyStore = keyStore ??
        SecureDatabaseKeyStore(
          databaseExists: fileExists,
          storageKey: replicaLocation?.keyName ??
              SecureDatabaseKeyStore.defaultStorageKey,
          creation: creation,
        );
    if (executor != null) {
      // In-memory/test path. Only exercise the key-state gate when a test opts
      // in by injecting databaseFileExists (avoids touching path_provider, which
      // is unmocked in most in-memory tests).
      if (databaseFileExists != null) {
        await _resolveKeyStateOrThrow(resolvedKeyStore, databaseFileExists);
      }
      final connection = executor is DatabaseConnection
          ? executor
          : DatabaseConnection(executor);
      final db = AppDatabase._(
        connection,
        keyStore: resolvedKeyStore,
        isEncrypted: false,
        initialLanguage: initialLanguage == 'ar' ? 'ar' : 'en',
      )..debugFailAtPhase = debugFailInit;
      return _finishOpen(db, runMigrations);
    }

    // MALI-058n — before creating or using any key, decide the key state. If an
    // encrypted DB already exists but its key is gone, fail with a typed state
    // instead of minting a new key (which would leave the DB unopenable and mask
    // the loss). Never reads a key from Drift/backup, never deletes.
    await _resolveKeyStateOrThrow(resolvedKeyStore, fileExists);
    creation.requireCurrent();
    final encryptionKey = await resolvedKeyStore.readOrCreateKey();
    creation.requireCurrent();
    // Re-verified after the awaits above and before the directory/file is made.
    if (createsFile) creation.requireMayCreate();
    final encryptedConnection = await _openEncryptedConnection(
      encryptionKey,
      replicaLocation!,
      createFile: createsFile,
    );
    final db = AppDatabase._(
      encryptedConnection,
      keyStore: resolvedKeyStore,
      isEncrypted: true,
      initialLanguage: initialLanguage == 'ar' ? 'ar' : 'en',
    );
    return _finishOpen(db, runMigrations);
  }

  /// MALI-069n §6/§Blocker-2 — open a bounded SECONDARY connection to the same
  /// encrypted file (e.g. the background capture-import or notification-action
  /// isolate). It uses the authoritative key + the centralized PRAGMA contract
  /// but never runs application migrations (the main connection owns them), so it
  /// can never observe a partially-upgraded schema — callers MUST close it in a
  /// `try/finally`.
  ///
  /// When an in-memory [owner] is available (same isolate), the secondary is
  /// ADMITTED only while the owner is in a usable state — refused (typed) while
  /// the owner is opening/migrating/closing/closed/failed or under exclusive
  /// maintenance. The two production paths run where no owner is accessible (a
  /// background isolate / no main connection), so their admission is file-level:
  /// the Batch-1 key-state gate + the shared PRAGMA/busy_timeout contract + the
  /// no-concurrent-migration rule. Batch-5 main-isolate maintenance uses [owner].
  static Future<AppDatabase> openSecondary({
    DatabaseKeyStore? keyStore,
    ReplicaLocation? location,
    AppDatabase? owner,
    DatabaseLeaseManager? leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
  }) async {
    if (owner != null && owner.isReadOnly) {
      throw const DatabaseLifecycleException(
          DatabaseLifecycleFailure.readOnlyOwner);
    }
    if (owner != null && !owner.admitsSecondary) {
      throw const DatabaseLifecycleException(DatabaseLifecycleFailure.closed);
    }
    // MALI-069n §Blocker-1 point 1 — validate the admission generation BEFORE
    // acquiring the lease: a job from a previous session (sign-out / wipe /
    // ownership change / same-UID re-login) is refused before it touches anything.
    if (ownershipGuard != null &&
        admissionToken != null &&
        !await ownershipGuard.isCurrent(admissionToken)) {
      throw const StaleOwnershipException();
    }
    // Cross-isolate admission: acquire a SHARED lease first, so the secondary is
    // refused while file-exclusive maintenance intent is active and, once open,
    // maintenance in any isolate waits for it to close. Held for the lifetime;
    // released on close.
    final lease =
        leaseManager != null ? await leaseManager.acquireShared() : null;
    try {
      // MALI-069n §Blocker-1 point 2 — re-validate immediately before opening the
      // connection (ownership can change between the lease and the open).
      if (ownershipGuard != null &&
          admissionToken != null &&
          !await ownershipGuard.isCurrent(admissionToken)) {
        throw const StaleOwnershipException();
      }
      // F2: a secondary open attaches to a database that EXISTS; it never
      // creates one (nor a key, nor a directory), whatever the file system or
      // Keychain says.
      final db = await open(
        keyStore: keyStore,
        location: location,
        runMigrations: false,
        creation: const CreationPolicy.denied(),
      );
      db._lease = lease;
      return db;
    } catch (_) {
      if (lease != null) await lease.release();
      rethrow;
    }
  }

  /// Offline local read — open the EXISTING encrypted database of [location]
  /// through a genuine SQLite read-only connection (`SQLITE_OPEN_READONLY`, plus
  /// `PRAGMA query_only` as defence in depth).
  ///
  /// It can create nothing: a missing file fails, a missing/empty key fails with
  /// [LocalDatabaseKeyUnavailableException] (the key is only READ via [readKey],
  /// never minted), and no directory is made. The migration pipeline never runs:
  /// `user_version` must equal this build's schema exactly, else the handle is
  /// closed and [ReadOnlySchemaUnsupportedException] is thrown. The encrypted
  /// cipher activation, key install and key proof are the same as every other
  /// production connection; there is no plaintext fallback. A verification
  /// failure awaits closure. If closure fails, [ReadOnlyCleanupIncompleteException]
  /// retains the uncertain handle for lifecycle draining; it is never exposed
  /// as a usable read replica. This path performs no initialization or repair.
  static Future<AppDatabase> openReadOnlyExisting({
    required ReplicaLocation location,
    required Future<String?> Function() readKey,
    @visibleForTesting Future<void> Function(AppDatabase db)? debugBeforeClose,
  }) async {
    if (!await File(location.dbPath).exists()) {
      throw const FileSystemException('database does not exist');
    }
    final key = await readKey();
    if (key == null || key.isEmpty) {
      throw const LocalDatabaseKeyUnavailableException();
    }
    final connection = await _openEncryptedConnection(
      key,
      location,
      createFile: false,
      readOnly: true,
    );
    final db = AppDatabase._(
      connection,
      keyStore: _ReadOnlyKeyStore(readKey),
      isEncrypted: true,
      isReadOnly: true,
    ).._debugBeforeReadOnlyClose = debugBeforeClose;
    try {
      final version = await db
          .customSelect('PRAGMA user_version;')
          .getSingle()
          .then((r) => r.read<int>('user_version'));
      if (version != _targetSchemaVersion) {
        throw ReadOnlySchemaUnsupportedException(
          databaseVersion: version,
          supportedVersion: _targetSchemaVersion,
        );
      }
    } catch (_) {
      db._lifecycle = DatabaseLifecycleState.failed;
      try {
        await db.close();
      } catch (_) {
        // Failed teardown is unknown, not proof of closure. Transfer the exact
        // handle to the receiver so lifecycle draining cannot lose it.
        throw ReadOnlyCleanupIncompleteException(db);
      }
      rethrow;
    }
    db._lifecycle = DatabaseLifecycleState.open;
    return db;
  }

  /// MALI-069n §Blocker-1 — the production cross-isolate lease manager, using
  /// files beside the database in the app-support directory. Records are tagged
  /// with the current pid + (when known) the process-instance token established by
  /// [initProcessLiveness].
  ///
  /// WP-3a — every sidecar (lease dir, maintenance intent, liveness lock and
  /// instance file) lives in the replica's own directory; [location] null = the
  /// legacy shared layout.
  static Future<DatabaseLeaseManager> appSupportLeaseManager(
      {ReplicaLocation? location}) async {
    final loc = location ?? await ReplicaLocation.legacy();
    return DatabaseLeaseManager(
      leaseDir: loc.leaseDir,
      intentPath: loc.maintPath,
      instanceToken: _processLiveness[loc.dbPath]?.instanceToken,
    );
  }

  /// The retained process-liveness handles (Contract B), one per database file.
  /// Held for the process lifetime so each OS advisory lock stays taken until
  /// this process dies.
  static final Map<String, ProcessLivenessHandle> _processLiveness = {};

  /// F2 — forget (and release) the process-liveness handle of a replica that is
  /// being deleted. Idempotent.
  static void dropProcessLiveness(ReplicaLocation location) {
    _processLiveness.remove(location.dbPath)?.release();
  }

  /// MALI-069n §Batch-4-closure-4 — establish PROCESS liveness once at startup
  /// (bootstrap). Takes the process-lifetime OS advisory lock; if this process is
  /// the sole opener (acquired the exclusive lock — Contract B guarantees no
  /// concurrent opener), it clears leftover lease/intent records from ENDED
  /// instances (identified by a different owner pid — never a live same-process
  /// isolate's lease). This startup pass, gated by the OS lock, is the ONLY reaping
  /// authority; nothing time-based ever deletes a record. Idempotent per process.
  static Future<ProcessLivenessHandle> initProcessLiveness(
      {ReplicaLocation? location}) async {
    final loc = location ?? await ReplicaLocation.legacy();
    final existing = _processLiveness[loc.dbPath];
    if (existing != null) {
      // F2: a cached handle whose lock file was deleted with its replica is for
      // deleted filesystem objects; re-acquire instead of reusing it. A failed
      // acquisition is not retained proof and must also be retried.
      if (existing.acquiredExclusive && File(loc.plockPath).existsSync()) {
        return existing;
      }
      existing.release();
      _processLiveness.remove(loc.dbPath);
    }
    final liveness = DatabaseProcessLiveness(
      lockPath: loc.plockPath,
      instancePath: loc.instancePath,
    );
    final handle = liveness.acquire();
    if (handle.acquiredExclusive) {
      _processLiveness[loc.dbPath] = handle;
      final manager = DatabaseLeaseManager(
        leaseDir: loc.leaseDir,
        intentPath: loc.maintPath,
        ownerPid: handle.ownerPid,
        instanceToken: handle.instanceToken,
      );
      manager.recoverEndedInstances();
    }
    return handle;
  }

  /// MALI-069n §3 — finish opening: run the migration pipeline for a MAIN open,
  /// and on ANY failure close the just-created native connection + its background
  /// isolate (best-effort, never masking the original error), mark [failed], and
  /// rethrow the typed cause. No key rotation, no file deletion. A SECONDARY open
  /// (runMigrations=false) skips the pipeline entirely.
  static Future<AppDatabase> _finishOpen(
      AppDatabase db, bool runMigrations) async {
    db._lifecycle = DatabaseLifecycleState.opening;
    if (!runMigrations) {
      db._lifecycle = DatabaseLifecycleState.open;
      return db;
    }
    try {
      await db.initialize();
    } catch (_) {
      db._lifecycle = DatabaseLifecycleState.failed;
      await db._closeQuietly();
      rethrow;
    }
    db._lifecycle = DatabaseLifecycleState.open;
    return db;
  }

  /// TEST-ONLY: build an UN-initialized instance so a test can drive the real
  /// [initialize] pipeline itself (memoization, retry, first-run concurrency).
  /// Production always goes through [open], which initializes before returning.
  @visibleForTesting
  static AppDatabase createForTesting({
    required QueryExecutor executor,
    required DatabaseKeyStore keyStore,
  }) {
    final connection = executor is DatabaseConnection
        ? executor
        : DatabaseConnection(executor);
    return AppDatabase._(connection, keyStore: keyStore, isEncrypted: false);
  }

  /// Deletes the on-disk encrypted database (and its WAL/SHM sidecars). Used by
  /// the recovery screen when the file can't be decrypted/opened — the data is
  /// unrecoverable without the key, so a clean recreate is the only way forward.
  static Future<void> deleteDatabaseFile({ReplicaLocation? location}) async {
    final loc = location ?? await ReplicaLocation.legacy();
    for (final suffix in const ['', '-wal', '-shm']) {
      final file = File('${loc.dbPath}$suffix');
      if (await file.exists()) {
        await file.delete();
      }
    }
  }

  /// MALI-058n — resolve the open-time key state and fail CLOSED with the typed
  /// [LocalDatabaseKeyUnavailableException] when an encrypted DB exists but its
  /// key is gone. Never mints a new key here, never reads a key from Drift or a
  /// backup, and never deletes anything.
  static Future<void> _resolveKeyStateOrThrow(
    DatabaseKeyStore keyStore,
    Future<bool> Function() databaseExists,
  ) async {
    final storedKey = await keyStore.readStoredKey();
    final exists = await databaseExists();
    if (classifyDatabaseKeyState(
            databaseExists: exists, storedKey: storedKey) ==
        DatabaseKeyState.keyUnavailable) {
      throw const LocalDatabaseKeyUnavailableException();
    }
  }

  // MALI-027: memoize the in-flight init so concurrent/repeated initialize()
  // calls on the same instance never run migrations twice (guarantee: idempotent
  // + no double-migration). A fresh AppDatabase (a reopen) gets a fresh future.
  Future<void>? _initFuture;

  /// TEST-ONLY deterministic failure injection (MALI-027). When set, it is
  /// awaited at each named migration phase so a test can throw exactly there and
  /// assert the whole migration rolls back. Null (unset) in production; in-memory
  /// only (never persisted or runtime-configurable).
  @visibleForTesting
  Future<void> Function(String phase)? debugFailAtPhase;

  Future<void> _phase(String phase) async => debugFailAtPhase?.call(phase);

  /// Runs the initialization pipeline at most once per instance. Concurrent and
  /// repeated callers share the single in-flight (or completed-successful)
  /// future. A FAILED init is NOT retained: [_runGuardedInitialize] clears the
  /// memo on error so an explicit later [initialize] in the same process can
  /// retry (e.g. after a transient failure clears). There is no automatic retry
  /// loop — one attempt per call.
  Future<void> initialize() => isReadOnly
      ? Future.error(StateError('a read-only database is never initialized'))
      : _initFuture ??= _runGuardedInitialize();

  Future<void> _runGuardedInitialize() async {
    try {
      await _runInitialize();
    } catch (_) {
      // Clear the memo so the failure is not cached. Only this instance runs
      // init and nothing re-enters it mid-run, so _initFuture is still THIS
      // future here; dropping it lets the next explicit initialize() re-attempt.
      _initFuture = null;
      rethrow;
    }
  }

  /// TEST-ONLY: re-run the pipeline bypassing the once-guard, to exercise
  /// upgrade/rollback paths on an already-open DB. NOT a production recovery
  /// mechanism — production recovers via [deleteDatabaseFile] + reopen.
  @visibleForTesting
  Future<void> debugReinitialize() => _runInitialize();

  /// Failure-atomic, version-aware initialization pipeline (MALI-027).
  ///
  /// Rollback guarantee (accurate wording): on any failure inside the migration
  /// transaction, SQLite rolls the transaction back — schema and user data are
  /// left logically/value-equivalent to before the attempt, no migration change
  /// is visible, `user_version` is unchanged, and no partial schema objects
  /// remain. (This is a transactional/logical guarantee; it does NOT assert the
  /// on-disk file/WAL/journal bytes are identical.) `PRAGMA user_version` is the
  /// LAST write inside the transaction, so schema changes, backfills, seed and
  /// the version bump commit or roll back together; reopening after a failed
  /// migration re-runs cleanly; re-running on an up-to-date DB is idempotent.
  ///
  /// SQLite / Drift atomicity notes (verified for this codebase):
  ///  • CREATE/ALTER TABLE, CREATE INDEX, INSERT/UPDATE and `PRAGMA user_version`
  ///    are all transactional in SQLite and roll back together.
  ///  • `PRAGMA foreign_keys` is NOT transactional (a no-op inside a txn), so it
  ///    is set ONCE before the transaction; no in-scope migration toggles it.
  ///  • No init step uses a non-transactional statement (no VACUUM/ATTACH).
  ///  • The one legacy table rebuild (_relaxCardsAccountNullable) runs as a
  ///    nested savepoint and is FK-safe only because nothing references `cards`.
  ///    Rebuilding a *referenced* table (as MALI-026 may need) would require
  ///    foreign_keys=OFF outside the txn — a documented limitation, out of scope.
  Future<void> _runInitialize() async {
    // Phase 1 — connection-level FK enforcement (non-transactional; set first).
    // Then VERIFY it actually took: if enforcement is not active we cannot make
    // the integrity guarantees below, so fail closed (unconditional, runs in
    // release too — not an assert).
    await customStatement('PRAGMA foreign_keys = ON;');
    final fkEnabled = (await customSelect('PRAGMA foreign_keys;').getSingle())
        .read<int>('foreign_keys');
    if (fkEnabled != 1) {
      throw MigrationIntegrityException(
        'foreign key enforcement is not active (PRAGMA foreign_keys=$fkEnabled)',
      );
    }

    // Phase 2 — current-version discovery.
    final fromVersion = await _currentUserVersion();

    // Phase 3 — downgrade guard, FAIL CLOSED. A newer-than-app schema is left
    // untouched (no reads, no writes, user_version unchanged), but we do NOT let
    // the app continue on a schema this build may not understand: throw a
    // dedicated, distinguishable exception so the caller can surface an
    // update/recovery message instead of risking corruption.
    if (fromVersion > _targetSchemaVersion) {
      throw UnsupportedDatabaseVersionException(
        databaseVersion: fromVersion,
        supportedVersion: _targetSchemaVersion,
      );
    }

    // Phases 4-8 — schema, versioned migrations, compatibility repairs, seed,
    // backfills, postflight integrity, and the user_version bump ALL run inside
    // one transaction, so any failure rolls the whole upgrade back atomically.
    await transaction(() async {
      await _phase('preSchema'); // before the first migration write
      await _createSchema(); // CREATE ... IF NOT EXISTS (fresh + idempotent)
      await _applyVersionedMigrations(fromVersion); // forward contract
      await _runCompatibilityMigrations(); // idempotent historical repairs
      await _phase('postAlter'); // after schema/ALTER work
      await _seedIfNeeded();
      // Cloud/AI processing consent is the USER's choice (MALI-001): consent
      // defaults OFF (NULL state = off, MALI-059n), and a persisted "disabled"
      // is never coerced back on — the capture/sync/backup gates honor the
      // stored value.
      await _phase('postSeed'); // during/after seed work
      await _dedupeCategoryRows();
      await _backfillSystemTransactionCategories();
      await _backfillTransactionDirections();
      await _repairBankCaptureTimestampDrift();
      await _migrateMoneyV30(); // fixed-precision backfill (throws → rolls back)
      await _phase('postBackfill'); // after backfills
      await _verifyMigrationIntegrity(); // postflight (throws → rolls back)
      await _phase('preVersion'); // immediately before the version bump
      // user_version LAST, inside the txn — commits only if all the above did.
      await customStatement('PRAGMA user_version = $_targetSchemaVersion;');
    });
  }

  /// Discrete, version-keyed migrations — the forward contract for NEW schema
  /// changes (from → to, apply, optional postcondition), applied in order inside
  /// the migration transaction. Empty today: the historical manual schema
  /// predates versioned snapshots, so past upgrades stay covered by the
  /// idempotent [_runCompatibilityMigrations] repairs (retrofitting 27 discrete
  /// snapshots would be riskier than the proven idempotent repairs). New schema
  /// work must register a step here instead of extending the flat repair list.
  // v28 → v29 (MALI-073n, Phase-7 B2) adds the additive account/category hot-path
  // indexes. Because `account_id` is ensured by _runCompatibilityMigrations (which
  // runs AFTER this versioned-registry phase), the indexes are created there,
  // idempotently, and their presence is asserted by the postflight
  // _verifyMigrationIntegrity BEFORE the user_version bump commits. The registry
  // itself stays empty (no forward step can precede its own column dependency).
  static const List<_SchemaMigration> _versionedMigrations = [
    // v31 -> v32 (PHASE 8) — the durable capture work item.
    //
    // ADDITIVE ONLY: one new table plus its indexes. No existing table is
    // read, altered, backfilled or converted, which is what makes this step
    // safe to apply inside the shared migration transaction.
    //
    // NOTE ON ROLLBACK: after v32 a v31 binary cannot open the database
    // (user_version exceeds what it knows). Rollback is therefore flags,
    // kill switch, forward hotfix or forward migration — NEVER a binary
    // downgrade. See docs/proof/PHASE8_DURABILITY.md.
    _SchemaMigration(
      from: 31,
      to: 32,
      apply: _applyV32CaptureWorkItems,
      postcondition: _verifyV32CaptureWorkItems,
    ),
    // v32 -> v33 (PHASE 9A) — real user labels. ADDITIVE: one table plus
    // indexes, no existing table read or converted. Same rollback rule as
    // v32: forward-only, never a binary downgrade.
    _SchemaMigration(
      from: 32,
      to: 33,
      apply: _applyV33ReviewLabels,
      postcondition: _verifyV33ReviewLabels,
    ),
    // v33 -> v34 (COUPONS PHASE 1) — the merchant catalog cache and the
    // structured offer economics. ADDITIVE: two new catalog cache tables plus
    // nullable columns on the existing coupon cache. No business table is read
    // or converted.
    //
    // Same rollback rule as v32/v33: forward-only. A v33 binary cannot open a
    // v34 database, so recovery is a flag, the kill switch, a hotfix or a
    // forward migration — never shipping an older build.
    _SchemaMigration(
      from: 33,
      to: 34,
      apply: _applyV34MerchantCatalog,
      postcondition: _verifyV34MerchantCatalog,
    ),
    // v34 -> v35 (COUPONS PHASE 3 + 4) — affiliate click receipts and the local
    // savings ledger. ADDITIVE: two new tables, nothing existing read or
    // converted.
    //
    // Both steps land in ONE version deliberately. Each schema bump forces a
    // sweep of every version pin in the repository (fourteen files at v34), and
    // doing that twice in a row for two tables that ship together is how the
    // v32/v33 pin fallout happened. Same forward-only rollback rule.
    _SchemaMigration(
      from: 34,
      to: 35,
      apply: _applyV35AffiliateAndSavings,
      postcondition: _verifyV35AffiliateAndSavings,
    ),
    // PHASE 11 — the durable Proof shadow store. Registered here rather than
    // buried in the flat repair list: the DAO swallows its own insert errors by
    // design, so a missing table would be permanently INVISIBLE. The
    // postcondition is what turns that into a loud migration failure.
    _SchemaMigration(
      from: 35,
      to: 36,
      apply: _applyV36ProofShadow,
      postcondition: _verifyV36ProofShadow,
    ),
    // PHASE 11 Tier 2 — the attribution join key. Without it a shadow
    // observation cannot be tied to the transaction it influenced, and the
    // "would have committed AND was later corrected" numerator is
    // unanswerable.
    _SchemaMigration(
      from: 36,
      to: 37,
      apply: _applyV37ProofShadowAttribution,
      postcondition: _verifyV37ProofShadowAttribution,
    ),
    // PHASE 11 Tier 2 — correctness provenance. Without it, confirmation and
    // correction are indistinguishable, because confirm() bumps updated_at just
    // as an edit does.
    _SchemaMigration(
      from: 37,
      to: 38,
      apply: _applyV38ProofCorrectionEvents,
      postcondition: _verifyV38ProofCorrectionEvents,
    ),
    // WP-3a — per-UID replica ownership. ADDITIVE: one single-row table that
    // records which uid this database file belongs to. Rows are written by the
    // replica layer (replica_store.dart), never by the migration: the migration
    // cannot know the uid, and a pre-existing database must NOT be silently
    // assigned one.
    _SchemaMigration(
      from: 38,
      to: 39,
      apply: _applyV39ReplicaMeta,
      postcondition: _verifyV39ReplicaMeta,
    ),
    // WP-6 — versioned, per-replica consent. ADDITIVE: four columns on the
    // existing single-row user_settings (version + time for each of the Cloud
    // and AI consents). No existing consent VALUE is changed. A consent that is
    // already an explicit choice (state not NULL) starts at version 1 with an
    // unknown time; an unset one stays at version 0. Forward-only like v32..v39.
    _SchemaMigration(
      from: 39,
      to: 40,
      apply: _applyV40ConsentVersions,
      postcondition: _verifyV40ConsentVersions,
    ),
    // WP-5 — revision CAS and durable conflicts. ADDITIVE: two nullable columns
    // on each outbox (the operation receipt id and the explicit CAS base
    // revision) and one new table, `sync_conflicts`. No existing row is changed:
    // a queued mutation without an operation id is assigned one at push time.
    // Forward-only like v32..v40.
    _SchemaMigration(
      from: 40,
      to: 41,
      apply: _applyV41SyncConflicts,
      postcondition: _verifyV41SyncConflicts,
    ),
    // Device-local consent VERSION allocation watermark. ADDITIVE: one
    // single-row table. It is allocation metadata only (the highest version this
    // device has reserved or committed), never a consent state, boolean or
    // timestamp, and it is never synced. The recovery seed fingerprint is local
    // provenance only; wipe clears it while retaining the version frontier.
    // Rows are written by explicit operations, never by the migration.
    _SchemaMigration(
      from: 41,
      to: 42,
      apply: _applyV42ConsentVersionWatermark,
      postcondition: _verifyV42ConsentVersionWatermark,
    ),
  ];

  static Future<void> _applyV42ConsentVersionWatermark(AppDatabase db) =>
      db._createConsentVersionWatermarkTable();

  static Future<bool> _verifyV42ConsentVersionWatermark(AppDatabase db) async {
    final cols = (await db
            .customSelect(
                "SELECT name FROM pragma_table_info('consent_version_watermark');")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    final sql = (await db
            .customSelect("SELECT sql FROM sqlite_master WHERE type='table' "
                "AND name='consent_version_watermark';")
            .getSingleOrNull())
        ?.read<String?>('sql');
    // The columns the allocation needs and the singleton constraint.
    return cols.containsAll(const {
          'id',
          'watermark',
          'reserved',
          'reserved_uid',
          'reserved_epoch',
          'reserved_op',
          'seed_source_fingerprint',
        }) &&
        (sql?.contains('CHECK (id = 1)') ?? false);
  }

  Future<void> _createConsentVersionWatermarkTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS consent_version_watermark (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        watermark INTEGER NOT NULL DEFAULT 0,
        reserved INTEGER NOT NULL DEFAULT 0,
        reserved_uid TEXT NULL,
        reserved_epoch INTEGER NULL,
        reserved_op TEXT NULL,
        seed_source_fingerprint TEXT NULL
      );
    ''');
  }

  static Future<void> _applyV41SyncConflicts(AppDatabase db) async {
    await db._ensureOutboxCasColumns();
    await db._createSyncConflictsTable();
  }

  static Future<bool> _verifyV41SyncConflicts(AppDatabase db) async {
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      final names = (await db
              .customSelect("SELECT name FROM pragma_table_info('$table');")
              .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      if (names.isEmpty) continue; // table not created yet (older database)
      if (!names.containsAll(const {'operation_id', 'base_revision'})) {
        return false;
      }
    }
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='sync_conflicts';")
        .get();
    return rows.isNotEmpty;
  }

  /// v41 — the operation receipt id (`last_op_id` on the server) and the
  /// explicit CAS base revision of a queued mutation. Both NULL for rows queued
  /// before v41; the push assigns the operation id lazily.
  Future<void> _ensureOutboxCasColumns() async {
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      // A database older than the outbox has no such table yet at this point
      // (the compatibility pass creates it later, WITH these columns).
      final exists = (await customSelect(
                  "SELECT name FROM sqlite_master WHERE type='table' "
                  "AND name='$table';")
              .get())
          .isNotEmpty;
      if (!exists) continue;
      await _ensureColumn(table, 'operation_id', 'TEXT NULL');
      await _ensureColumn(table, 'base_revision', 'INTEGER NULL');
    }
  }

  /// v41 — the durable record of a sync conflict: the base (when known), the
  /// local proposal and the cloud version, stored BEFORE the outbox op is
  /// consumed so a conflict survives a restart. At most one OPEN record per
  /// entity (partial unique index); a resolved record is kept as history.
  Future<void> _createSyncConflictsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sync_conflicts (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        local_id TEXT NOT NULL,
        server_id TEXT NULL,
        kind TEXT NOT NULL CHECK(kind IN ('update','delete','tombstone','create')),
        base_json TEXT NULL,
        mine_json TEXT NULL,
        theirs_json TEXT NULL,
        theirs_revision INTEGER NULL,
        operation_id TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        resolved_at TEXT NULL,
        resolution TEXT NULL
      );
    ''');
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sync_conflicts_open '
      'ON sync_conflicts(entity_type, local_id) WHERE resolved_at IS NULL;',
    );
  }

  static Future<void> _applyV40ConsentVersions(AppDatabase db) async {
    // A database older than MALI-059n has no *_state columns yet (the
    // compatibility repairs add them AFTER the versioned steps); the backfill
    // below reads them, so ensure them first. Same definition as that repair.
    await db._ensureColumn('user_settings', 'ai_consent_state', 'TEXT NULL');
    await db._ensureColumn('user_settings', 'cloud_consent_state', 'TEXT NULL');
    await db._ensureColumn(
        'user_settings', 'cloud_consent_version', 'INTEGER NOT NULL DEFAULT 0');
    await db._ensureColumn('user_settings', 'cloud_consent_at', 'TEXT NULL');
    await db._ensureColumn(
        'user_settings', 'ai_consent_version', 'INTEGER NOT NULL DEFAULT 0');
    await db._ensureColumn('user_settings', 'ai_consent_at', 'TEXT NULL');
    await db.customStatement(
      'UPDATE user_settings SET cloud_consent_version = 1 '
      'WHERE cloud_consent_state IS NOT NULL AND cloud_consent_version = 0;',
    );
    await db.customStatement(
      'UPDATE user_settings SET ai_consent_version = 1 '
      'WHERE ai_consent_state IS NOT NULL AND ai_consent_version = 0;',
    );
  }

  static Future<bool> _verifyV40ConsentVersions(AppDatabase db) async {
    final names = (await db
            .customSelect(
                "SELECT name FROM pragma_table_info('user_settings');")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    return names.containsAll(const {
      'cloud_consent_version',
      'cloud_consent_at',
      'ai_consent_version',
      'ai_consent_at',
    });
  }

  static Future<void> _applyV39ReplicaMeta(AppDatabase db) =>
      db._createReplicaMetaTable();

  static Future<bool> _verifyV39ReplicaMeta(AppDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='replica_meta';")
        .get();
    return rows.isNotEmpty;
  }

  /// v39 — `replica_meta`, at most ONE row (CHECK id = 1). `owner_uid` is the
  /// authoritative owner of this file; the directory name and the registry are
  /// only hints and are verified against it on open.
  Future<void> _createReplicaMetaTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS replica_meta (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        owner_uid TEXT NOT NULL,
        replica_id TEXT NOT NULL,
        server_epoch INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
    ''');
  }

  static Future<void> _applyV38ProofCorrectionEvents(AppDatabase db) =>
      db._createProofCorrectionEventsTable();

  static Future<bool> _verifyV38ProofCorrectionEvents(AppDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='proof_correction_events';")
        .get();
    return rows.isNotEmpty;
  }

  static Future<void> _applyV37ProofShadowAttribution(AppDatabase db) =>
      db._addProofShadowAttribution();

  static Future<bool> _verifyV37ProofShadowAttribution(AppDatabase db) async {
    final cols = await db
        .customSelect(
            "SELECT name FROM pragma_table_info('proof_shadow_evaluations');")
        .get();
    if (!cols.any((r) => r.read<String>('name') == 'transaction_id')) {
      return false;
    }
    // The column existing is not enough: a NULL row is an unclassifiable row.
    final nulls = await db
        .customSelect('SELECT COUNT(*) AS n FROM proof_shadow_evaluations '
            'WHERE transaction_id IS NULL;')
        .get();
    return (nulls.first.read<int?>('n') ?? 0) == 0;
  }

  static Future<void> _applyV36ProofShadow(AppDatabase db) =>
      db._createProofShadowTable();

  static Future<bool> _verifyV36ProofShadow(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='proof_shadow_evaluations';",
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<void> _createProofShadowTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS proof_shadow_evaluations (
        evaluation_key TEXT PRIMARY KEY,
        evaluated_at TEXT NOT NULL,
        engine_version TEXT NOT NULL,
        gate_mode TEXT NOT NULL,
        outcome TEXT NOT NULL,
        would_have_committed INTEGER NOT NULL DEFAULT 0,
        parse_confidence_permille INTEGER NOT NULL,
        confidence_min_permille INTEGER NOT NULL,
        proof_verdict TEXT NOT NULL DEFAULT '',
        amount_match TEXT NOT NULL,
        direction_match TEXT NOT NULL,
        currency_match TEXT NOT NULL,
        refusal_reason TEXT NOT NULL DEFAULT '',
        transaction_id TEXT NULL
      );
    ''');
    // Attribution join: shadow observation -> the transaction it influenced.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_proof_shadow_txn '
      'ON proof_shadow_evaluations(transaction_id);',
    );
  }

  /// v38 — the correctness-provenance log.
  ///
  /// Append-only, and written ONLY from the explicit user-intent repository
  /// methods. That placement is the whole design: every non-user writer — sync
  /// pull-apply, the import soft-hide, the migration timestamp repair — mutates
  /// `transactions` with RAW SQL and never touches the repository, so it cannot
  /// manufacture a correction event. `updated_at` could not distinguish those;
  /// an explicit event can.
  ///
  /// Stores WHICH CLASS of Proof-relevant field changed, never the values: the
  /// question is "did the amount change", not "what was it".
  Future<void> _createProofCorrectionEventsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS proof_correction_events (
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        event_type TEXT NOT NULL
          CHECK(event_type IN ('confirmed','corrected_financial',
                               'rejected_or_deleted','non_financial_edit')),
        changed_fields TEXT NOT NULL DEFAULT '',
        occurred_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_proof_correction_txn '
      'ON proof_correction_events(transaction_id);',
    );
  }

  /// v37 adds the attribution column to an existing v36 table. Separate from
  /// the CREATE above because a v36 database already has the table without it.
  Future<void> _addProofShadowAttribution() async {
    final cols = await customSelect(
            "SELECT name FROM pragma_table_info('proof_shadow_evaluations');")
        .get();
    final has = cols.any((r) => r.read<String>('name') == 'transaction_id');
    if (!has) {
      await customStatement(
        'ALTER TABLE proof_shadow_evaluations ADD COLUMN transaction_id TEXT NULL;',
      );
    }
    // BACKFILL — load-bearing. Rows written by a v36 build have NULL here, and
    // in SQL both `= ''` and `!= ''` evaluate to NULL for them, so they would
    // match NONE of the attribution predicates and be silently dropped from the
    // Tier 2 population — violating this module's own "classified, not dropped"
    // contract. They could never have been attributed anyway (the v36 writer had
    // no transaction id), so '' is the correct classification: unattributed.
    await customStatement(
      "UPDATE proof_shadow_evaluations SET transaction_id = '' "
      'WHERE transaction_id IS NULL;',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_proof_shadow_txn '
      'ON proof_shadow_evaluations(transaction_id);',
    );
  }

  static Future<void> _applyV33ReviewLabels(AppDatabase db) =>
      db._createCaptureReviewLabelsTable();

  static Future<bool> _verifyV33ReviewLabels(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='capture_review_labels';",
        )
        .get();
    return rows.isNotEmpty;
  }

  static Future<void> _applyV35AffiliateAndSavings(AppDatabase db) async {
    await db._createAffiliateClickReceiptsTable();
    await db._createLocalOfferSavingsTable();
  }

  static Future<bool> _verifyV35AffiliateAndSavings(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name IN ('affiliate_click_receipts','local_offer_savings');",
        )
        .get();
    return rows.length == 2;
  }

  static Future<void> _applyV34MerchantCatalog(AppDatabase db) async {
    await db._createRemoteCatalogMerchantsTable();
    await db._createRemoteMerchantAliasesTable();
    await db._ensureRemoteCouponEconomicsColumns();
    await db._ensureMerchantPersonalizationColumn();
  }

  /// A partial v34 is worse than no v34: the resolver would find an alias table
  /// with no merchants, or coupons whose benefit columns are missing, and fail
  /// at read time on a user's device instead of here.
  static Future<bool> _verifyV34MerchantCatalog(AppDatabase db) async {
    final tables = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name IN ('remote_catalog_merchants','remote_merchant_aliases');",
        )
        .get();
    if (tables.length != 2) return false;
    final cols =
        await db.customSelect('PRAGMA table_info(remote_coupons);').get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    if (!names.containsAll(const {
      'merchant_id',
      'benefit_type',
      'discount_bps',
      'benefit_currency',
      'verification_state',
    })) {
      return false;
    }
    final settings =
        await db.customSelect('PRAGMA table_info(user_settings);').get();
    return settings
        .map((r) => r.read<String>('name'))
        .contains('merchant_personalization_enabled');
  }

  static Future<void> _applyV32CaptureWorkItems(AppDatabase db) =>
      db._createCaptureWorkItemsTable();

  /// The step must not be able to report success without the table existing.
  static Future<bool> _verifyV32CaptureWorkItems(AppDatabase db) async {
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name='capture_work_items';",
        )
        .get();
    return rows.isNotEmpty;
  }

  Future<void> _applyVersionedMigrations(int fromVersion) async {
    for (final migration in _versionedMigrations) {
      if (migration.from < fromVersion) continue; // already applied
      if (migration.to > _targetSchemaVersion) continue; // beyond this build
      await migration.apply(this);
      final ok = await migration.postcondition?.call(this) ?? true;
      if (!ok) {
        throw StateError(
          'migration ${migration.from}->${migration.to} postcondition failed',
        );
      }
    }
  }

  /// Postflight integrity check (runs inside the migration txn, before the
  /// user_version bump). UNCONDITIONAL runtime validation — active in release,
  /// profile and debug (NOT an assert), because this is part of a financial
  /// database's integrity contract. Any failure throws
  /// [MigrationIntegrityException], which rolls the whole migration back.
  Future<void> _verifyMigrationIntegrity() async {
    const requiredTables = [
      'accounts',
      'transactions',
      'categories',
      'user_settings',
    ];
    for (final table in requiredTables) {
      final present = (await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?;",
        variables: [Variable.withString(table)],
      ).get())
          .isNotEmpty;
      if (!present) {
        throw MigrationIntegrityException(
          'post-migration schema check failed: missing table "$table"',
        );
      }
    }
    // MALI-073n (v29) — the hot-path indexes are part of the schema contract from
    // v29 on; assert both exist before the version bump commits (a failure rolls
    // the whole migration back rather than stamping a half-applied v29).
    const requiredIndexes = [
      'idx_transactions_account_occurred',
      'idx_transactions_category_id',
    ];
    for (final index in requiredIndexes) {
      final present = (await customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?;",
        variables: [Variable.withString(index)],
      ).get())
          .isNotEmpty;
      if (!present) {
        throw MigrationIntegrityException(
          'post-migration schema check failed: missing index "$index"',
        );
      }
    }
    final violations = await customSelect('PRAGMA foreign_key_check;').get();
    if (violations.isNotEmpty) {
      // `foreign_key_check` columns: table, rowid, parent, fkid. We surface ONLY
      // structural identity (child table → parent table, constraint index) and
      // deliberately omit rowid and every data column — no financial row
      // contents are read or logged.
      final diagnostics = violations
          .take(20)
          .map((row) => '${row.data['table']}→${row.data['parent']}'
              '#${row.data['fkid']}')
          .join(', ');
      throw MigrationIntegrityException(
        'post-migration foreign_key_check found ${violations.length} '
        'violation(s): $diagnostics',
      );
    }
    // MALI-026 (v30 §37): every documented minor column + planning authority
    // column must exist before the version bump commits — a half-applied v30
    // schema rolls the whole upgrade back rather than stamping user_version=30.
    Future<void> requireColumn(String table, String column) async {
      final info = await customSelect('PRAGMA table_info($table);').get();
      if (!info.any((r) => r.read<String>('name') == column)) {
        throw MigrationIntegrityException(
          'post-migration schema check failed: missing column "$table.$column"',
        );
      }
    }

    for (final f in kV30MinorColumns) {
      await requireColumn(f.table, f.minorColumn);
    }
    await requireColumn('budgets', 'currency');
    // The per-budget alert threshold. A database that reached this point
    // without it would silently warn everyone at the default, so the
    // postflight fails closed rather than letting that ship.
    await requireColumn('budgets', 'alert_threshold_percent');
    await requireColumn('goals', 'currency');
    await requireColumn('user_settings', 'planning_cutover_state');
  }

  Future<void>? _closeFuture;

  /// MALI-069n §2 — idempotent close. Concurrent/repeated close calls share one
  /// teardown; it first waits for any in-flight initialization to SETTLE (so we
  /// never tear down mid-migration), then closes the stream + the executor
  /// (which stops the background isolate). Safe to call after a failed open.
  @override
  Future<void> close() {
    if (_debugBeforeReadOnlyClose != null) return _closeReadOnlyWithHook();
    return _closeFuture ??= _close();
  }

  Future<void> Function(AppDatabase db)? _debugBeforeReadOnlyClose;

  Future<void> _closeReadOnlyWithHook() async {
    // Test-only fault before actual teardown; does not cache a simulated failure
    // as the database's real close result.
    await _debugBeforeReadOnlyClose!(this);
    await (_closeFuture ??= _close());
  }

  /// A cross-isolate SHARED lease held for a secondary connection's lifetime
  /// (MALI-069n §Blocker-1); released on close.
  DatabaseFileLease? _lease;

  /// O-BX-1 — set synchronously by the first [close]. From then on no maintenance
  /// caller may start, leave the queue, finish its drain or begin its action: the
  /// exclusive-maintenance entrances are DRAINED (the one already past its intent
  /// is awaited to completion, never interrupted) or DENIED (one still queued or
  /// draining is refused before it creates an intent).
  bool _closeRequested = false;

  Future<void> _close() async {
    _closeRequested = true;
    // A maintenance caller still in its drain step has published nothing: refuse
    // it now instead of waiting for borrows that may never end.
    final draining = _drain;
    if (draining != null && !draining.isCompleted) {
      draining.completeError(
          const DatabaseLifecycleException(DatabaseLifecycleFailure.closed));
    }
    // A running maintenance (it holds the gate and may hold an intent) is awaited
    // to completion; queued callers wake, see the request and are refused. Only
    // when none remains does teardown proceed, so no intent can be created after
    // a caller observed this database closed.
    while (_maintenanceLock != null && !_maintenanceLock!.isCompleted) {
      await _maintenanceLock!.future;
    }
    if (_lifecycle != DatabaseLifecycleState.failed) {
      _lifecycle = DatabaseLifecycleState.closing;
    }
    // Let a running init finish or fail before teardown — never abort it midway.
    try {
      await _initFuture;
    } catch (_) {}
    await _manualRevisionController.close();
    await _tableWriteController.close();
    // MALI-040 — complete Drift's own teardown for THIS instance: super.close()
    // disposes the drift stream-query manager (active `.watch` streams), closes
    // this instance's executor EXACTLY once, decrements drift's open-database
    // counter and notifies devtools. The previous bare `executor.close()` skipped
    // all of that, leaking streamQueries on every close (sign-out/restore reopen)
    // and never decrementing the counter (the source of the spurious
    // "created the database class AppDatabase multiple times" warnings). Each
    // AppDatabase owns its own executor (main/secondary/test open independent
    // connections), so this closes only this instance's executor — no double
    // close, and the file-level lease below is released exactly as before.
    await super.close();
    // Release the cross-isolate shared lease so file-exclusive maintenance can
    // proceed once every secondary has closed.
    final lease = _lease;
    _lease = null;
    if (lease != null) await lease.release();
    _lifecycle = DatabaseLifecycleState.closed;
  }

  /// Best-effort close used by failed-open cleanup — never throws, so it can
  /// never mask the original initialization failure (MALI-069n §3).
  Future<void> _closeQuietly() async {
    try {
      await close();
    } catch (_) {}
  }

  Completer<void>? _maintenanceLock;
  int _activeBorrows = 0;
  bool _maintenanceRequested = false;
  final _borrowQueue = <Completer<void>>[];
  Completer<void>? _drain;

  /// True while an exclusive maintenance operation holds (or is acquiring) the gate.
  bool get isUnderMaintenance => _maintenanceRequested;

  /// The number of in-flight borrows (for tests/diagnostics).
  int get activeBorrows => _activeBorrows;

  /// Whether a NEW secondary connection may be admitted right now (§Blocker-2):
  /// only when the owner is writable, fully open and not quiescing for maintenance.
  /// A read-only owner cannot authorize a writable secondary connection.
  bool get admitsSecondary =>
      !isReadOnly &&
      _lifecycle == DatabaseLifecycleState.open &&
      !_closeRequested &&
      !_maintenanceRequested;

  void _requireNotClosing() {
    if (_closeRequested) {
      throw const DatabaseLifecycleException(DatabaseLifecycleFailure.closed);
    }
  }

  void _throwIfUnusable() {
    _requireNotClosing();
    switch (_lifecycle) {
      case DatabaseLifecycleState.closing:
      case DatabaseLifecycleState.closed:
        throw const DatabaseLifecycleException(DatabaseLifecycleFailure.closed);
      case DatabaseLifecycleState.failed:
      case DatabaseLifecycleState.recoveryRequired:
        throw const DatabaseLifecycleException(
            DatabaseLifecycleFailure.recoveryRequired);
      case DatabaseLifecycleState.opening:
      case DatabaseLifecycleState.open:
      case DatabaseLifecycleState.maintenanceRequested:
        return;
    }
  }

  /// MALI-069n §Blocker-1 — borrow the database for ONE operation through the
  /// lifecycle gate. A borrow is REJECTED (typed) after close/failed/recovery,
  /// and QUEUED while exclusive maintenance holds the gate, so maintenance can
  /// safely quiesce the database and file-level maintenance never races an active
  /// operation. Operations that must not run during maintenance route here.
  Future<T> borrow<T>(Future<T> Function() op) async {
    _throwIfUnusable();
    while (_maintenanceRequested) {
      final waiter = Completer<void>();
      _borrowQueue.add(waiter);
      await waiter.future;
      _throwIfUnusable();
    }
    _activeBorrows++;
    try {
      return await op();
    } finally {
      _activeBorrows--;
      if (_activeBorrows == 0 && _drain != null && !_drain!.isCompleted) {
        _drain!.complete();
      }
    }
  }

  /// MALI-069n §10/§Blocker-1 — ENFORCEABLE exclusive maintenance. It serialises
  /// against other maintenance, transitions to [maintenanceRequested] so NEW
  /// borrows/secondaries are refused or QUEUED, waits (bounded by [drainTimeout])
  /// for active borrows to drain, then runs [action]. On success it returns to
  /// [open]; on a recoverable failure it restores the prior usable state; if the
  /// action signals it left the database unusable (by throwing
  /// [DatabaseLifecycleException] with [recoveryRequired]) it exposes the typed
  /// [recoveryRequired] state and never publishes a partial database. Cleanup is
  /// idempotent and never hides the original failure. This is the primitive the
  /// Batch-5 restore/reset matrix builds on; it does not itself rewrite restore.
  Future<T> runExclusiveMaintenance<T>(
    Future<T> Function() action, {
    Duration drainTimeout = const Duration(seconds: 10),
    MaintenanceMode mode = MaintenanceMode.logical,
    DatabaseLeaseManager? leaseManager,
    Duration exclusiveTimeout = const Duration(seconds: 10),
  }) async {
    if (mode == MaintenanceMode.fileExclusive && leaseManager == null) {
      throw ArgumentError('fileExclusive maintenance requires a leaseManager');
    }
    _requireNotClosing();
    while (_maintenanceLock != null && !_maintenanceLock!.isCompleted) {
      await _maintenanceLock!.future;
      // O-BX-1: a caller queued behind earlier maintenance never starts once
      // close was requested (it has created no intent).
      _requireNotClosing();
    }
    final lock = Completer<void>();
    _maintenanceLock = lock;
    final priorState = _lifecycle;
    _maintenanceRequested = true;
    _lifecycle = DatabaseLifecycleState.maintenanceRequested;
    DatabaseFileLease? exclusive;
    try {
      // 1. Drain in-memory (main-isolate) borrows.
      await _drainBorrows(drainTimeout);
      _requireNotClosing(); // refused BEFORE any intent is published
      // 2. For file-level exclusivity, acquire the CROSS-ISOLATE exclusive lease
      //    — this publishes maintenance intent (refusing new secondaries) and
      //    waits (bounded) for every secondary lease to close.
      if (mode == MaintenanceMode.fileExclusive) {
        exclusive =
            await leaseManager!.acquireExclusive(timeout: exclusiveTimeout);
      }
      _requireNotClosing(); // the finally releases an acquired lease
      final result = await action();
      _lifecycle = DatabaseLifecycleState.open;
      return result;
    } catch (error) {
      if (error is DatabaseLifecycleException &&
          error.reason == DatabaseLifecycleFailure.recoveryRequired) {
        _lifecycle = DatabaseLifecycleState.recoveryRequired;
      } else if (_lifecycle == DatabaseLifecycleState.maintenanceRequested) {
        // Recoverable: the DB was not torn down — restore the prior usable state.
        _lifecycle = priorState;
      }
      rethrow; // preserve the original typed cause
    } finally {
      // Release the cross-isolate exclusive lease (clears the intent marker) so
      // secondaries may resume.
      if (exclusive != null) await exclusive.release();
      _maintenanceRequested = false;
      _maintenanceLock = null;
      lock.complete();
      final queued = [..._borrowQueue];
      _borrowQueue.clear();
      for (final waiter in queued) {
        if (!waiter.isCompleted) waiter.complete();
      }
    }
  }

  /// MALI-069n §Batch-5 primitive — the single explicit file-exclusive maintenance
  /// entry point the Batch-5 restore/reset will build on. It does NOT itself rewrite
  /// restore; it guarantees the boundary around [action]:
  ///   * the captured admission generation is validated first (a job from a
  ///     superseded session aborts with [StaleOwnershipException] before any lock);
  ///   * in-memory main borrows are drained (bounded);
  ///   * a fenced cross-isolate maintenance intent is published, refusing NEW
  ///     secondaries, and every pre-existing live shared lease is drained with a
  ///     stable-zero settle so no lease can enter during [action];
  ///   * quiescing/closing the main executor and the safe reopen happen INSIDE
  ///     [action] (that is restore's job); a recoverable failure restores the prior
  ///     usable lifecycle, and an unrecoverable reopen failure surfaces as
  ///     [DatabaseLifecycleFailure.recoveryRequired].
  /// No file deletion/replacement may begin inside [action] while any shared lease
  /// exists — the drain above is what guarantees that.
  Future<T> runFileExclusiveMaintenance<T>(
    Future<T> Function() action, {
    required DatabaseLeaseManager leaseManager,
    OwnershipGuard? ownershipGuard,
    AdmissionToken? admissionToken,
    Duration drainTimeout = const Duration(seconds: 10),
    Duration exclusiveTimeout = const Duration(seconds: 10),
  }) async {
    if (ownershipGuard != null &&
        admissionToken != null &&
        !await ownershipGuard.isCurrent(admissionToken)) {
      throw const StaleOwnershipException();
    }
    return runExclusiveMaintenance(
      action,
      mode: MaintenanceMode.fileExclusive,
      leaseManager: leaseManager,
      drainTimeout: drainTimeout,
      exclusiveTimeout: exclusiveTimeout,
    );
  }

  Future<void> _drainBorrows(Duration timeout) async {
    if (_activeBorrows == 0) return;
    _drain = Completer<void>();
    try {
      await _drain!.future.timeout(timeout);
    } on TimeoutException {
      throw const DatabaseLifecycleException(
          DatabaseLifecycleFailure.maintenanceTimeout);
    } finally {
      _drain = null;
    }
  }

  /// MALI-069n §Blocker-3 — run [op] with a BOUNDED retry when the connection's
  /// busy_timeout wait still ends in a transient SQLITE_BUSY/LOCKED. A non-busy
  /// error is rethrown unchanged (never misclassified); an exhausted busy retry
  /// throws the typed, privacy-safe [DatabaseBusyException] (never the raw SQLite
  /// text). Does NOT retry, reset, delete, or rotate anything else. The caller
  /// must not pass an active-transaction body (retry-in-transaction is unsafe).
  Future<T> runWithBusyRetry<T>(
    Future<T> Function() op, {
    int maxAttempts = 3,
  }) async {
    var attempt = 0;
    while (true) {
      attempt++;
      try {
        return await op();
      } catch (error) {
        final busy = mapDatabaseBusy(error);
        if (busy == null) rethrow; // a non-busy error is never misclassified
        if (attempt >= maxAttempts) throw busy; // typed + bounded
      }
    }
  }

  Stream<int> get manualRevisionStream => _manualRevisionController.stream;

  /// MALI-029 — the target table of each data write. Domain-scoped revision
  /// providers filter this so an unrelated-table write never rebuilds an
  /// unrelated screen. Table-less/global watchers keep using [manualRevisionStream].
  Stream<String> get tableWriteStream => _tableWriteController.stream;

  /// Extracts the TARGET table of a single-table DML statement (the table being
  /// written), or null if it cannot be identified. Subqueries/joins in a WHERE or
  /// VALUES clause never change the target, so this is reliable for the app's DML.
  static final RegExp _dmlTargetTable = RegExp(
    r'^\s*(?:INSERT(?:\s+OR\s+\w+)?\s+INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM)'
    r'''\s+["'`]?([A-Za-z_][A-Za-z0-9_]*)''',
    caseSensitive: false,
  );

  static String? targetTableOf(String sql) =>
      _dmlTargetTable.firstMatch(sql)?.group(1);

  /// Lifecycle race seam: the real transaction remains open while this awaits.
  @visibleForTesting
  Future<void> Function(String query)? debugBeforeCustomInsert;

  @override
  Future<int> customInsert(
    String query, {
    List<Variable> variables = const [],
    Set<ResultSetImplementation<dynamic, dynamic>>? updates,
  }) async {
    await debugBeforeCustomInsert?.call(query);
    final result = await super.customInsert(
      query,
      variables: variables,
      updates: updates,
    );
    _notifyManualRevision(targetTableOf(query));
    return result;
  }

  @override
  Future<int> customUpdate(
    String query, {
    List<Variable> variables = const [],
    Set<ResultSetImplementation<dynamic, dynamic>>? updates,
    UpdateKind? updateKind,
  }) async {
    final result = await super.customUpdate(
      query,
      variables: variables,
      updates: updates,
      updateKind: updateKind,
    );
    _notifyManualRevision(targetTableOf(query));
    return result;
  }

  @override
  Future<void> customStatement(String statement, [List<dynamic>? args]) async {
    await super.customStatement(statement, args);
    if (_looksLikeDataWrite(statement)) {
      _notifyManualRevision(targetTableOf(statement));
    }
  }

  void _notifyManualRevision([String? table]) {
    if (!_manualRevisionController.isClosed) {
      _manualRevisionController.add(++_manualRevision);
    }
    if (table != null && !_tableWriteController.isClosed) {
      _tableWriteController.add(table);
    }
  }

  bool _looksLikeDataWrite(String sql) {
    final trimmed = sql.trimLeft().toUpperCase();
    return trimmed.startsWith('INSERT ') ||
        trimmed.startsWith('UPDATE ') ||
        trimmed.startsWith('DELETE ') ||
        trimmed.startsWith('REPLACE ');
  }

  Future<int> count(String table) async {
    final rows =
        await customSelect('SELECT COUNT(*) AS total FROM $table;').get();
    return rows.first.read<int>('total');
  }

  /// MALI-058n — idempotent local repair that clears any legacy raw SQLCipher
  /// key stored in the deprecated `db_encryption_key_ref` column. Touches ONLY
  /// that column (never another setting), never reads the value into memory/logs,
  /// and is a no-op once the value is already empty. Returns the number of rows
  /// repaired (0 on a clean device) so callers can assert idempotency in tests.
  Future<int> clearDeprecatedDbKeyRef() async {
    return customUpdate(
      "UPDATE user_settings SET db_encryption_key_ref = '' "
      "WHERE db_encryption_key_ref != '';",
      updateKind: UpdateKind.update,
    );
  }

  static Future<DatabaseConnection> _openEncryptedConnection(
    String key,
    ReplicaLocation location, {
    required bool createFile,
    bool readOnly = false,
  }) async {
    final file = File(location.dbPath);
    // F2: only a creating open makes the directory. An existing-only open uses a
    // sqlite3 that cannot create the file, and drift only makes the parent
    // directory when it is missing. ReplicaStore tracks primary opens through
    // connection initialization; secondary callers hold their shared lease, so
    // removal cannot delete the parent during the resolver/open interval.
    if (createFile) await file.parent.create(recursive: true);
    return NativeDatabase.createBackgroundConnection(
      file,
      sqlite3: databaseResolver(
        file.absolute.path,
        createFile: createFile,
        readOnly: readOnly,
      ),
      // MALI-046n: the migration pipeline (_runInitialize) is the SOLE owner of
      // `PRAGMA user_version`. With Drift migrations enabled, Drift's version
      // delegate stamps `user_version = schemaVersion` at open — BEFORE the
      // pipeline's discovery phase reads it — which makes the downgrade guard,
      // the versioned-migration registry and the version-gated compatibility
      // repairs inert. Disabling migrations installs a NoVersionDelegate: Drift
      // runs no migrator and never writes `user_version`, so the pipeline
      // observes the real on-disk version and remains the only writer.
      enableMigrations: false,
      // MALI-069n §7 — the single centralized connection-configuration contract.
      // EVERY production connection (main and approved secondary) runs THIS setup,
      // so they can never silently differ. Order is SQLCipher-correct: activate
      // the cipher, verify the extension is present (fail-closed — never continue
      // unencrypted), install the key, prove the key by touching sqlite_master,
      // then set the integrity/contention PRAGMAs.
      setup: (database) {
        database.execute("PRAGMA cipher = 'sqlcipher';");
        final cipher = database.select('PRAGMA cipher;');
        if (cipher.isEmpty) {
          throw StateError(
            'SQLite encryption extension is not available. The database would not be encrypted.',
          );
        }
        database.execute("PRAGMA key = '${escapeSqlString(key)}';");
        database.select('SELECT count(*) FROM sqlite_master;');
        database.execute('PRAGMA foreign_keys = ON;');
        // MALI-069n §8 — bounded wait on transient write contention (e.g. the
        // background capture/notification second connection racing the main
        // one), instead of failing immediately with SQLITE_BUSY. Bounded so it
        // can never hang; a genuinely stuck lock surfaces as a typed busy error.
        database.execute('PRAGMA busy_timeout = $_busyTimeoutMs;');
        // Offline local read: defence in depth behind OpenMode.readOnly.
        if (readOnly) database.execute('PRAGMA query_only = ON;');
      },
    );
  }

  /// MALI-069n §8 — bounded busy wait (ms) applied to every production connection.
  static const int _busyTimeoutMs = 5000;

  Future<void> _createSchema() async {
    // MALI-014/076n §Batch-5-closure §Blocker-1 — the DURABLE restore-operation
    // journal. Privacy-safe columns ONLY (no passphrase/key/payload/total/path).
    // Excluded from backup/restore/sync/export (see BackupSnapshotBuilder). The
    // `committed` transition is written INSIDE the restore transaction so it is
    // atomic with the restored data; a crash after commit is discovered here at
    // startup so a destructive restore is never replayed.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS restore_operations(
        operation_id TEXT PRIMARY KEY,
        source_fingerprint TEXT NOT NULL,
        envelope_version INTEGER NOT NULL,
        snapshot_schema_version INTEGER NOT NULL,
        owner_generation_hash TEXT NULL,
        state TEXT NOT NULL,
        prepared_at TEXT NOT NULL,
        committed_at TEXT NULL,
        acknowledged_at TEXT NULL,
        terminal_error_class TEXT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS categories(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        icon TEXT NOT NULL,
        color TEXT NOT NULL,
        is_income INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS merchants(
        id TEXT PRIMARY KEY,
        raw_name TEXT NOT NULL,
        normalized_name TEXT NOT NULL UNIQUE,
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS merchant_category_map(
        id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL UNIQUE,
        category_id TEXT NOT NULL,
        is_user_confirmed INTEGER NOT NULL,
        confidence REAL NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS transactions(
        id TEXT PRIMARY KEY,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        merchant_id TEXT NULL,
        raw_merchant TEXT NULL,
        category_id TEXT NULL,
        type TEXT NOT NULL,
        source TEXT NOT NULL,
        card_last4 TEXT NULL,
        balance_after REAL NULL,
        note TEXT NULL,
        occurred_at TEXT NOT NULL,
        raw_message TEXT NOT NULL,
        parse_confidence REAL NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        foreign_amount REAL NULL,
        foreign_currency TEXT NULL,
        direction TEXT NULL CHECK(direction IN ('credit', 'debit', 'unknown')),
        transaction_time_from_sms TEXT NULL,
        sms_received_at TEXT NULL,
        comparison_timestamp TEXT NULL,
        comparison_timestamp_source TEXT NOT NULL DEFAULT 'received_at'
          CHECK(comparison_timestamp_source IN ('sms_body', 'received_at')),
        duplicate_status TEXT NOT NULL DEFAULT 'normal'
          CHECK(duplicate_status IN ('normal', 'suspicious_duplicate')),
        possible_duplicate_of_transaction_id TEXT NULL,
        duplicate_reason TEXT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE SET NULL,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE SET NULL
      );
    ''');

    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_occurred_at ON transactions(occurred_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_merchant_amount ON transactions(merchant_id, amount);',
    );
    // NOTE: the account_id/category_id hot-path indexes (MALI-073n) are created in
    // _runCompatibilityMigrations, AFTER the `account_id` column is ensured there —
    // account_id is not part of this original CREATE TABLE, so its index cannot be
    // built at this point.
    // MALI-027: idx_transactions_duplicate_exact indexes `comparison_timestamp`,
    // which a legacy `transactions` table does NOT have yet (it is added later by
    // _runCompatibilityMigrations via ADD COLUMN). Creating it here would fail on
    // a real historical upgrade because `CREATE TABLE IF NOT EXISTS` is a no-op
    // for the existing legacy table, so the column is still absent at this point.
    // The index is (re)created in _runCompatibilityMigrations AFTER the column is
    // ensured, so all paths — fresh and legacy — still end up with it.

    await customStatement('''
      CREATE TABLE IF NOT EXISTS budgets(
        id TEXT PRIMARY KEY,
        category_id TEXT NOT NULL,
        amount REAL NOT NULL,
        period TEXT NOT NULL,
        start_date TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        last_notified_spent_amount REAL NOT NULL DEFAULT 0,
        last_notified_period_start TEXT NOT NULL DEFAULT '2000-01-01T00:00:00Z',
        show_on_header INTEGER NOT NULL DEFAULT 0,
        account_id TEXT NULL,
        alert_threshold_percent INTEGER NOT NULL DEFAULT 80,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL,
        FOREIGN KEY (category_id) REFERENCES categories(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS goals(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        account_id TEXT NULL,
        target_amount REAL NOT NULL,
        saved_amount REAL NOT NULL,
        deadline TEXT NULL,
        vault_skin TEXT NOT NULL,
        status TEXT NOT NULL,
        last_notified_saved_amount REAL NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        auto_save_amount REAL NULL,
        auto_save_period TEXT NULL,
        auto_save_last_run TEXT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS goal_contributions(
        id TEXT PRIMARY KEY,
        goal_id TEXT NOT NULL,
        amount REAL NOT NULL,
        created_at TEXT NOT NULL,
        note TEXT NULL,
        deleted_at TEXT NULL,
        FOREIGN KEY (goal_id) REFERENCES goals(id) ON DELETE CASCADE
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS achievements(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        unlocked_at TEXT NULL,
        progress REAL NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS streaks(
        id TEXT PRIMARY KEY,
        current_streak INTEGER NOT NULL,
        longest_streak INTEGER NOT NULL,
        last_active_date TEXT NOT NULL,
        freezes_available INTEGER NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS xp_levels(
        id TEXT PRIMARY KEY,
        total_xp INTEGER NOT NULL,
        level INTEGER NOT NULL,
        level_key TEXT NOT NULL
      );
    ''');

    await customStatement('''
      CREATE TABLE IF NOT EXISTS subscriptions(
        id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL,
        amount REAL NOT NULL,
        period TEXT NOT NULL,
        next_due_date TEXT NULL,
        is_confirmed INTEGER NOT NULL,
        reminder_on INTEGER NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        type TEXT NOT NULL DEFAULT 'subscription',
        currency TEXT NOT NULL DEFAULT 'SAR',
        frequency TEXT NOT NULL DEFAULT 'monthly',
        custom_interval_days INTEGER NULL,
        note TEXT NULL,
        created_at TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z',
        status TEXT NOT NULL DEFAULT 'active',
        account_id TEXT NULL,
        total_installments INTEGER NULL,
        paid_count INTEGER NULL,
        manual_paid_amount REAL NULL,
        total_purchase_amount REAL NULL,
        lender_name TEXT NULL,
        interest_rate REAL NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL,
        FOREIGN KEY (merchant_id) REFERENCES merchants(id) ON DELETE CASCADE
      );
    ''');

    await _createBillPaymentsTable();

    await customStatement('''
      CREATE TABLE IF NOT EXISTS parsing_rules(
        id TEXT PRIMARY KEY,
        bank_key TEXT NOT NULL,
        locale TEXT NOT NULL,
        pattern TEXT NOT NULL,
        field TEXT NOT NULL,
        priority INTEGER NOT NULL,
        version INTEGER NOT NULL,
        is_active INTEGER NOT NULL
      );
    ''');

    await _createCatalogMetadataTable();
    await _createRemoteBanksTable();
    await _createRemoteParsersTable();
    await _createRemoteCurrenciesTable();
    await _createRemoteCountriesTable();
    await _createRemoteCategoriesTable();
    await _createRemoteFeatureFlagsTable();
    await _createRemoteAnnouncementsTable();
    await _createRemoteGrowthCampaignsTable();
    await _createRemoteCouponsTable();

    await customStatement('''
      CREATE TABLE IF NOT EXISTS user_settings(
        id TEXT PRIMARY KEY,
        display_name TEXT NULL,
        phone_number TEXT NULL,
        avatar_path TEXT NULL,
        date_of_birth TEXT NULL,
        country TEXT NOT NULL,
        currency TEXT NOT NULL,
        language TEXT NOT NULL,
        theme TEXT NOT NULL,
        input_method TEXT NOT NULL,
        notifications_json TEXT NOT NULL,
        -- DEPRECATED (MALI-058n): kept for schema stability (no table rebuild
        -- before MALI-026) but NON-AUTHORITATIVE. Every production writer writes
        -- '' here; the SQLCipher key lives ONLY in platform secure storage and is
        -- never stored in the DB, backed up, synced, or exported. A local repair
        -- clears any legacy non-empty value.
        db_encryption_key_ref TEXT NOT NULL,
        privacy_mode_enabled INTEGER NOT NULL DEFAULT 0,
        -- MALI-059n: cloud/AI processing default OFF. The boolean columns are the
        -- effective grant (derived from the versioned state below); the *_state
        -- columns record the explicit tri-state choice (NULL=unset / accepted /
        -- declined) so consent is never inferred and can be migrated precisely.
        ai_consent_granted INTEGER NOT NULL DEFAULT 0,
        cloud_processing_enabled INTEGER NOT NULL DEFAULT 0,
        ai_consent_state TEXT NULL,
        cloud_consent_state TEXT NULL,
        -- WP-6 (v40): the version and time of the last explicit change of each
        -- consent. Versions only ever increase; 0 = never changed.
        cloud_consent_version INTEGER NOT NULL DEFAULT 0,
        cloud_consent_at TEXT NULL,
        ai_consent_version INTEGER NOT NULL DEFAULT 0,
        ai_consent_at TEXT NULL,
        updated_at TEXT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))
      );
    ''');

    // الحسابات/المحافظ — كل حساب بعملته الخاصة (multi-currency).
    await customStatement('''
      CREATE TABLE IF NOT EXISTS accounts(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        currency TEXT NOT NULL,
        type TEXT NOT NULL,
        initial_balance REAL NULL,
        current_balance REAL NULL,
        bank_account_number TEXT NULL,
        credit_limit REAL NULL,
        available_credit REAL NULL,
        payment_due_day INTEGER NULL,
        wallet_provider TEXT NULL,
        exclude_from_totals INTEGER NOT NULL DEFAULT 0,
        metadata TEXT NULL,
        is_default INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');

    // البطاقات الحقيقية — مصدر الحقيقة لهوية البطاقة وبياناتها، تنتمي لحساب.
    // العمليات تحتفظ بـ card_last4 مستقلًّا؛ الربط عبر (account_id, last4).
    await customStatement('''
      CREATE TABLE IF NOT EXISTS cards(
        id TEXT PRIMARY KEY,
        account_id TEXT NULL,
        nickname TEXT NULL,
        last4 TEXT NOT NULL,
        network TEXT NOT NULL,
        source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual', 'auto')),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL,
        color_theme TEXT NULL,
        accent_hex TEXT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cards_account ON cards(account_id);',
    );
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS uidx_cards_account_last4_active '
      'ON cards(account_id, last4) WHERE deleted_at IS NULL;',
    );

    // Phase 2: تتبّع صحة الكاش المحلي (Drift) أثناء فترة الطرح التدريجي
    // للقراءة/الكتابة المباشرة على Supabase. يُستخدم فقط لمعرفة متى فشلت
    // مرآة الكتابة بعد نجاح Supabase، حتى لا يُعتبر التراجع (rollback) آمنًا
    // بشكل أعمى قبل إصلاح الكاش.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS financial_cache_health(
        entity_type TEXT PRIMARY KEY,
        dirty INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        marked_at TEXT NULL,
        repaired_at TEXT NULL
      );
    ''');

    // مؤشر دائم لكل تدفق pull. يُنشأ في كل initialize() بنفس نمط الجداول
    // الإضافية اليدوية، لذلك لا يحتاج bump منفصلًا لـ user_version.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sync_cursors(
        entity TEXT PRIMARY KEY,
        last_updated_at TEXT NOT NULL,
        last_id TEXT NOT NULL
      );
    ''');

    // MALI-051n: durable parking for child pull-rows whose parent hasn't synced
    // yet. Storing the raw server row lets the pull cursor advance safely (the
    // row is never lost) while the child is retried after its parent arrives.
    // `reason='terminal'` marks a bounded, permanently-unresolvable row so it
    // stops looping but stays visible for diagnostics. Additive/idempotent —
    // created for fresh + existing DBs; wiped on sign-out; never backed up.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS parked_child_rows(
        table_name TEXT NOT NULL,
        server_id TEXT NOT NULL,
        row_json TEXT NOT NULL,
        reason TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        first_seen_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (table_name, server_id)
      );
    ''');

    await _createDedupHashesTable();
    await _createRemoteMerchantKeywordsTable();
    await _createPendingMerchantFeedbackTable();
    await _createSenderBankMappingsTable();
    await _createPlansTable();
    await _createSuspectedDuplicatesTable();
  }

  Future<void> _createSuspectedDuplicatesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS suspected_duplicates(
        id TEXT PRIMARY KEY,
        raw_message TEXT NOT NULL,
        sender_id TEXT NULL,
        existing_transaction_id TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        raw_merchant TEXT NULL,
        occurred_at TEXT NOT NULL,
        card_last4 TEXT NULL,
        comparison_timestamp TEXT NULL,
        comparison_timestamp_source TEXT NULL,
        duplicate_reason TEXT NULL,
        created_at TEXT NOT NULL
      );
    ''');
  }

  /// خطط/مظاريف مؤقتة (سفر، عُرس، رمضان...) — ميزانية لفترة محددة بتتبّع تلقائياً
  /// أي صرف في الفترة من الحسابات/الكروت المختارة. عضوية العمليات محسوبة ديناميكياً
  /// (مفيش عمود على transactions)، فالجدول بيتعمل بـ IF NOT EXISTS لكل النسخ.
  Future<void> _createPlansTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS plans(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        budget_amount REAL NOT NULL,
        currency TEXT NOT NULL,
        start_date TEXT NOT NULL,
        end_date TEXT NOT NULL,
        account_ids TEXT NOT NULL DEFAULT '',
        card_last4s TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'active',
        icon TEXT NULL,
        created_at TEXT NOT NULL,
        server_id TEXT NULL,
        synced_at TEXT NULL,
        server_updated_at TEXT NULL,
        sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
        deleted_at TEXT NULL
      );
    ''');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS plan_transaction_links(
        plan_id TEXT NOT NULL,
        transaction_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        deleted_at TEXT NULL,
        PRIMARY KEY (plan_id, transaction_id),
        FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE CASCADE,
        FOREIGN KEY (transaction_id) REFERENCES transactions(id) ON DELETE CASCADE
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_plan_transaction_links_transaction '
      'ON plan_transaction_links(transaction_id);',
    );
  }

  Future<void> _runCompatibilityMigrations() async {
    final version = await _currentUserVersion();
    // v2 consolidates the manual columns added during MVP hardening. The
    // checks stay idempotent because older builds could write user_version
    // before all compatibility columns existed.
    if (version > _targetSchemaVersion) {
      throw StateError('Unsupported database schema version: $version');
    }
    await _ensureColumn('transactions', 'note', 'TEXT NULL');
    await _ensureColumn('remote_merchant_keywords', 'logo_url', 'TEXT');
    await _ensureColumn(
      'budgets',
      'last_notified_spent_amount',
      'REAL NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'budgets',
      'last_notified_period_start',
      "TEXT NOT NULL DEFAULT '2000-01-01T00:00:00Z'",
    );
    await _ensureColumn(
      'goals',
      'last_notified_saved_amount',
      'REAL NOT NULL DEFAULT 0',
    );
    await _ensureColumn('subscriptions', 'name', "TEXT NOT NULL DEFAULT ''");
    await _ensureColumn(
      'subscriptions',
      'type',
      "TEXT NOT NULL DEFAULT 'subscription'",
    );
    await _ensureColumn(
      'subscriptions',
      'currency',
      "TEXT NOT NULL DEFAULT 'SAR'",
    );
    await _ensureColumn(
      'subscriptions',
      'frequency',
      "TEXT NOT NULL DEFAULT 'monthly'",
    );
    await _ensureColumn(
      'subscriptions',
      'custom_interval_days',
      'INTEGER NULL',
    );
    await _ensureColumn('subscriptions', 'note', 'TEXT NULL');
    await _ensureColumn(
      'subscriptions',
      'created_at',
      "TEXT NOT NULL DEFAULT '1970-01-01T00:00:00.000Z'",
    );
    await _ensureColumn(
      'user_settings',
      'privacy_mode_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    // MALI-059n: cloud/AI processing default OFF. (A DB predating these columns
    // gets them as 0; the versioned *_state columns start NULL = unset.)
    await _ensureColumn(
      'user_settings',
      'ai_consent_granted',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn(
      'user_settings',
      'cloud_processing_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await _ensureColumn('user_settings', 'ai_consent_state', 'TEXT NULL');
    await _ensureColumn('user_settings', 'cloud_consent_state', 'TEXT NULL');
    // MALI-059n migrate-to-OFF: an existing install that never recorded an
    // explicit choice (state IS NULL) must NOT inherit the old default-ON
    // boolean — force the effective grant OFF. Idempotent: once the user makes
    // an explicit choice the state is non-NULL and these rows are skipped.
    await customStatement(
      'UPDATE user_settings SET ai_consent_granted = 0 '
      'WHERE ai_consent_state IS NULL;',
    );
    await customStatement(
      'UPDATE user_settings SET cloud_processing_enabled = 0 '
      'WHERE cloud_consent_state IS NULL;',
    );
    await _ensureColumn('user_settings', 'display_name', 'TEXT NULL');
    await _ensureColumn('user_settings', 'phone_number', 'TEXT NULL');
    await _ensureColumn('user_settings', 'avatar_path', 'TEXT NULL');
    await _ensureColumn('user_settings', 'date_of_birth', 'TEXT NULL');
    // S2: مزامنة تفضيلات المستخدم (offline-first، نفس محرك الحسابات/البطاقات).
    await _ensureColumn('user_settings', 'updated_at', 'TEXT NULL');
    await _ensureColumn('user_settings', 'server_id', 'TEXT NULL');
    await _ensureColumn('user_settings', 'synced_at', 'TEXT NULL');
    await _ensureColumn('user_settings', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn('user_settings', 'sync_status', 'TEXT NULL');
    // v2: ربط المعاملات/الاشتراكات بالحساب (multi-currency accounts).
    await _ensureColumn('transactions', 'account_id', 'TEXT NULL');
    // MALI-073n (schema v29) — account/category hot-path indexes, evidence-backed
    // by EXPLAIN QUERY PLAN (test/performance/query_plan_test.dart). Created here
    // (not in _createSchema) because account_id is ensured just above. The account
    // index is COMPOSITE (account_id, occurred_at): it subsumes a single-column
    // account_id index AND serves `WHERE account_id = ? ORDER BY occurred_at DESC`
    // (account detail / latest-balance / recent list) without a temp-B-tree sort.
    // category_id is single-column for `WHERE category_id = ?` + `GROUP BY
    // category_id`. Additive read accelerators only — no financial semantics,
    // precision or types change. Presence asserted by _verifyMigrationIntegrity.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_account_occurred '
      'ON transactions(account_id, occurred_at);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_category_id '
      'ON transactions(category_id);',
    );
    await _ensureColumn('subscriptions', 'account_id', 'TEXT NULL');
    await _ensureColumn(
        'budgets', 'show_on_header', 'INTEGER NOT NULL DEFAULT 0');
    await _ensureColumn('budgets', 'account_id', 'TEXT NULL');
    // The DEFAULT is what migrates existing budgets: every row that predates
    // this column gets 80, which is the threshold the Settings copy has always
    // promised. Nobody's alerts change the day they update.
    await _ensureColumn(
        'budgets', 'alert_threshold_percent', 'INTEGER NOT NULL DEFAULT 80');
    await _ensureColumn('goals', 'account_id', 'TEXT NULL');
    // recurring auto-save per goal (fixed amount every week/month).
    await _ensureColumn('goals', 'auto_save_amount', 'REAL NULL');
    await _ensureColumn('goals', 'auto_save_period', 'TEXT NULL');
    await _ensureColumn('goals', 'auto_save_last_run', 'TEXT NULL');
    // subscription/installment extra fields
    await _ensureColumn(
        'subscriptions', 'status', "TEXT NOT NULL DEFAULT 'active'");
    await _ensureColumn('subscriptions', 'total_installments', 'INTEGER NULL');
    await _ensureColumn('subscriptions', 'paid_count', 'INTEGER NULL');
    await _ensureColumn('subscriptions', 'manual_paid_amount', 'REAL NULL');
    await _ensureColumn('subscriptions', 'total_purchase_amount', 'REAL NULL');
    await _ensureColumn('subscriptions', 'lender_name', 'TEXT NULL');
    await _ensureColumn('subscriptions', 'interest_rate', 'REAL NULL');
    await _createBillPaymentsTable();
    await _createSuspectedDuplicatesTable();

    // v27: تخصيص تصميم البطاقة + ربط الحساب اختياري.
    await _ensureColumn('cards', 'color_theme', 'TEXT NULL');
    await _ensureColumn('cards', 'accent_hex', 'TEXT NULL');
    await _relaxCardsAccountNullable();

    if (version < 3) {
      await _createCatalogMetadataTable();
      await _createRemoteBanksTable();
      await _createRemoteParsersTable();
      await _createRemoteCurrenciesTable();
      await _createRemoteCountriesTable();
      await _createRemoteCategoriesTable();
    }
    if (version < 4) {
      await _createRemoteFeatureFlagsTable();
      await _createRemoteAnnouncementsTable();
    }
    // v31 (MALI-COUPONS C4): additive catalog cache only. No business table is
    // touched, no Money/Planning/CAS/backup/capture data is converted.
    if (version < 31) {
      await _createRemoteCouponsTable();
    }
    // v32 (PHASE 8): the durable capture work item. ADDITIVE — no existing
    // business table is read, written or converted.
    //
    // Created UNCONDITIONALLY, like `ledger_sync_outbox` above: the statement
    // is CREATE ... IF NOT EXISTS, so correctness comes from idempotence rather
    // than from a version gate. A gate here would skip the table on any
    // database already reporting >= 32 — including a freshly created one —
    // and leave the wipe/delete paths referencing a table that does not exist.
    // The v31 -> v32 forward contract for EXISTING databases is carried by the
    // versioned migration registry.
    await _createCaptureWorkItemsTable();

    // v33 (PHASE 9A): real user labels for the Phase-11 precision gate.
    // ADDITIVE, and created unconditionally for the same reason as above.
    await _createCaptureReviewLabelsTable();
    await _createProofShadowTable();
    await _addProofShadowAttribution();
    await _createProofCorrectionEventsTable();
    await _createReplicaMetaTable();
    await _createSyncConflictsTable();
    await _createConsentVersionWatermarkTable();

    // v34 (COUPONS PHASE 1): the merchant catalog cache. Unconditional for the
    // same reason as the two above — a version gate would skip these on a
    // freshly created database, and the resolver would then query a table that
    // does not exist. The coupon economics columns are added by the same
    // idempotent helper the compatibility pass uses.
    await _createRemoteCatalogMerchantsTable();
    await _createRemoteMerchantAliasesTable();
    await _ensureRemoteCouponEconomicsColumns();
    await _ensureMerchantPersonalizationColumn();

    // v35 (COUPONS PHASE 3 + 4): click receipts and the savings ledger.
    // Unconditional for the same reason as every table above — a version gate
    // skips them on a freshly created database and leaves the wipe and backup
    // paths referencing tables that do not exist.
    await _createAffiliateClickReceiptsTable();
    await _createLocalOfferSavingsTable();
    if (version < 5) {
      await _createDedupHashesTable();
    }
    if (version < 6) {
      await _createRemoteMerchantKeywordsTable();
      await _createPendingMerchantFeedbackTable();
    }
    if (version < 7) {
      await _createSenderBankMappingsTable();
    }
    if (version < 13) {
      await _createRemoteGrowthCampaignsTable();
    }
    if (version < 8) {
      await _ensureColumn('sender_bank_mappings', 'reason', 'TEXT NULL');
    }
    if (version < 9) {
      await _ensureColumn('transactions', 'foreign_amount', 'REAL NULL');
      await _ensureColumn('transactions', 'foreign_currency', 'TEXT NULL');
    }
    await _ensureColumn(
      'transactions',
      'direction',
      "TEXT NULL CHECK(direction IN ('credit', 'debit', 'unknown'))",
    );
    await _ensureColumn(
        'transactions', 'transaction_time_from_sms', 'TEXT NULL');
    await _ensureColumn('transactions', 'sms_received_at', 'TEXT NULL');
    await _ensureColumn('transactions', 'comparison_timestamp', 'TEXT NULL');
    await _ensureColumn(
      'transactions',
      'comparison_timestamp_source',
      "TEXT NOT NULL DEFAULT 'received_at' "
          "CHECK(comparison_timestamp_source IN ('sms_body', 'received_at'))",
    );
    await _ensureColumn(
      'transactions',
      'duplicate_status',
      "TEXT NOT NULL DEFAULT 'normal' "
          "CHECK(duplicate_status IN ('normal', 'suspicious_duplicate'))",
    );
    await _ensureColumn(
      'transactions',
      'possible_duplicate_of_transaction_id',
      'TEXT NULL',
    );
    await _ensureColumn('transactions', 'duplicate_reason', 'TEXT NULL');
    await _ensureColumn('suspected_duplicates', 'card_last4', 'TEXT NULL');

    // F-032 / OD-02 — canonical card identity on transactions.
    //
    // The card↔transaction join was the soft composite `(account_id, last4)`.
    // Four digits are not identity: `getByCard(last4)` matched across every
    // account, merging two physically different cards into one history; and
    // moving a card to another account left its history behind, where a later
    // card with the same last4 silently inherited it. Both are silent financial
    // mis-attribution — no error, just money shown under the wrong card.
    //
    // Additive and nullable: `last4` remains as display metadata and as the
    // matching EVIDENCE the backfill uses, never as identity. NULL means
    // "not attributable", which is a truthful state — see backfillCardIdentity.
    await _ensureColumn('transactions', 'card_id', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_card_id '
      'ON transactions(card_id) WHERE card_id IS NOT NULL;',
    );
    await _ensureColumn(
      'suspected_duplicates',
      'comparison_timestamp',
      'TEXT NULL',
    );
    await _ensureColumn(
      'suspected_duplicates',
      'comparison_timestamp_source',
      'TEXT NULL',
    );
    await _ensureColumn(
        'suspected_duplicates', 'duplicate_reason', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_duplicate_exact '
      'ON transactions(amount, currency, comparison_timestamp);',
    );
    // G6: the v10 goal→default-account backfill moved out of the schema layer
    // into DriftGoalRepository.repointOrphanGoalsToDefaultAccount (run at
    // bootstrap), which records sync intent for every re-pointed goal. A raw
    // migration write cannot: it has no session/owner context.
    // v15: Phase C — server sync metadata for Supabase ledger pull.
    await _ensureColumn('transactions', 'server_id', 'TEXT NULL');
    await _ensureColumn('transactions', 'synced_at', 'TEXT NULL');
    await _ensureColumn('transactions', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn(
      'transactions',
      'sync_status',
      "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_server_id ON transactions(server_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_transactions_sync_status ON transactions(sync_status);',
    );
    // MALI-022 / 0068 — the locally-cached server `revision` (the CAS base
    // token). Additive + nullable: NULL means "revision unknown for this row"
    // (never synced, or synced before the server had 0068), which the push
    // treats as fail-safe — it uses the guarded server_updated_at compare rather
    // than a blind overwrite. Populated by pull + push acknowledgements once the
    // server reports a revision. Used only when the server advertises `revision_cas` (WP-5).
    for (final table in const [
      'transactions',
      'accounts',
      'budgets',
      'subscriptions',
      'goals',
      'plans',
      'cards',
      'categories',
      'user_settings',
    ]) {
      await _ensureColumn(table, 'server_revision', 'INTEGER NULL');
    }
    // MALI-072n / 0069 — sender-mapping sync durability: a local tombstone
    // (deleted_at) that propagates deletions, and the server base token
    // (server_updated_at) for conflict-safe pulls. Additive + nullable.
    await _ensureColumn('sender_bank_mappings', 'deleted_at', 'TEXT NULL');
    await _ensureColumn(
        'sender_bank_mappings', 'server_updated_at', 'TEXT NULL');
    // Provenance of an accepted mapping: 'user' | 'ai_validated' (enforced in
    // code). NULL = legacy row, treated as user-accepted. Additive + nullable.
    await _ensureColumn('sender_bank_mappings', 'accepted_by', 'TEXT NULL');
    // G10: bounded push retry state. `sync_permanent` is the terminal
    // "failed_permanent" marker — the sync_status CHECK constraint cannot take a
    // new value without a table rebuild, so a permanently failed mapping stays
    // sync_status='failed' with sync_permanent=1 (never retried, never
    // overwritten by pull, still visible to the unsynced inventory).
    await _ensureColumn('sender_bank_mappings', 'sync_attempt_count',
        'INTEGER NOT NULL DEFAULT 0');
    await _ensureColumn(
        'sender_bank_mappings', 'sync_next_retry_at', 'TEXT NULL');
    await _ensureColumn(
        'sender_bank_mappings', 'sync_failure_class', 'TEXT NULL');
    await _ensureColumn(
        'sender_bank_mappings', 'sync_permanent', 'INTEGER NOT NULL DEFAULT 0');
    // v16: Phase D — local outbox for push sync.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS ledger_sync_outbox (
        id TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN ('create','update','delete')),
        payload_json TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        next_retry_at TEXT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        failure_class TEXT NULL,
        op_seq INTEGER NOT NULL DEFAULT 0,
        owner_uid TEXT NULL,
        in_flight_seq INTEGER NULL,
        operation_id TEXT NULL,
        base_revision INTEGER NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_transaction_id '
      'ON ledger_sync_outbox(transaction_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_outbox_next_retry '
      'ON ledger_sync_outbox(next_retry_at);',
    );
    // v17: Phase F — Smart Inbox pull-sync cache.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS smart_inbox_items (
        id TEXT PRIMARY KEY,
        server_id TEXT NOT NULL UNIQUE,
        transaction_id TEXT NULL,
        payload_id TEXT NULL,
        type TEXT NOT NULL,
        title TEXT NOT NULL,
        body TEXT NULL,
        status TEXT NOT NULL DEFAULT 'open',
        confidence REAL NULL,
        metadata_json TEXT NOT NULL DEFAULT '{}',
        server_created_at TEXT NOT NULL,
        server_updated_at TEXT NULL,
        synced_at TEXT NOT NULL,
        dismissed_locally INTEGER NOT NULL DEFAULT 0,
        pending_sync INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_smart_inbox_type '
      'ON smart_inbox_items(type);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_smart_inbox_status '
      'ON smart_inbox_items(status);',
    );
    // S3 gap#1: علم دفع محلي لتغييرات صندوق الوارد (رفض/معالجة) offline-first.
    await _ensureColumn(
        'smart_inbox_items', 'pending_sync', 'INTEGER NOT NULL DEFAULT 0');
    // G11: bounded push backoff (additive).
    await _ensureColumn('smart_inbox_items', 'push_attempt_count',
        'INTEGER NOT NULL DEFAULT 0');
    await _ensureColumn('smart_inbox_items', 'push_next_retry_at', 'TEXT NULL');
    // v18-v19: Phase G — planning sync foundation.
    await _ensureAccountsSyncSchema();
    await _ensurePlanningEntitySyncSchema();
    await _ensurePlanningChildSyncSchema();
    await _createPlanningSyncOutboxTable();
    // MALI-023: dead-letter/retry columns for existing installs (additive).
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      await _ensureColumn(table, 'status', "TEXT NOT NULL DEFAULT 'pending'");
      await _ensureColumn(table, 'failure_class', 'TEXT NULL');
      // A-2 (G3): monotonic per-row edit counter. Every insert/coalesce bumps it,
      // so an ACK can tell "the row I pushed" from "the row edited while in
      // flight". A-2 (G18): the local-data owner uid the row was recorded for;
      // NULL = legacy row, stamped lazily at push time only when ownership is
      // verified.
      await _ensureColumn(table, 'op_seq', 'INTEGER NOT NULL DEFAULT 0');
      await _ensureColumn(table, 'owner_uid', 'TEXT NULL');
      // A-3: durable "possibly sent" marker — the op_seq this row had when it was
      // handed to a push. Survives process death, so a create+delete coalesce can
      // never drop a create that may already have reached the server.
      await _ensureColumn(table, 'in_flight_seq', 'INTEGER NULL');
      // v41 (WP-5): operation receipt id + explicit CAS base revision.
      await _ensureColumn(table, 'operation_id', 'TEXT NULL');
      await _ensureColumn(table, 'base_revision', 'INTEGER NULL');
    }
    // MALI-024 / 0070 — durable local engagement-event outbox. The client
    // records typed events; the server (record_engagement_event RPC) decides the
    // award. The client NEVER stores or uploads an authoritative XP total. The
    // event_id is the owner-bound idempotency key (exactly-once server award).
    await customStatement('''
      CREATE TABLE IF NOT EXISTS engagement_events (
        event_id TEXT PRIMARY KEY,
        event_type TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        business_key TEXT NULL,
        event_version INTEGER NOT NULL DEFAULT 1,
        status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending', 'synced', 'failed', 'dead')),
        attempt_count INTEGER NOT NULL DEFAULT 0,
        failure_class TEXT NULL,
        created_at TEXT NOT NULL,
        synced_at TEXT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_engagement_events_status '
      'ON engagement_events(status);',
    );
    // v22: portable custom categories. Built-in catalog rows keep these null;
    // only user-created rows participate in server mirroring/import.
    await _ensureColumn('categories', 'server_id', 'TEXT NULL');
    await _ensureColumn('categories', 'synced_at', 'TEXT NULL');
    await _ensureColumn('categories', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn(
      'categories',
      'sync_status',
      "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
    );
    await _ensureColumn('categories', 'deleted_at', 'TEXT NULL');
    await _ensureColumn('goal_contributions', 'deleted_at', 'TEXT NULL');
    await _ensureColumn('bill_payments', 'deleted_at', 'TEXT NULL');
    await _ensureColumn('plan_transaction_links', 'deleted_at', 'TEXT NULL');
    await customStatement('''
      CREATE TABLE IF NOT EXISTS financial_import_runs(
        package_id TEXT PRIMARY KEY,
        format TEXT NOT NULL,
        mode TEXT NOT NULL,
        result_json TEXT NOT NULL,
        completed_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_categories_server_id ON categories(server_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_categories_deleted_at ON categories(deleted_at);',
    );
    await _ensureV30MoneyColumns();
  }

  /// MALI-026 (Phase-8 B8-3 §2/§3) — the ADDITIVE v30 fixed-precision schema.
  /// Every money REAL column `X` gains an int64 `X_minor` (retained REAL is the
  /// compatibility shadow — NOT dropped/rebuilt). Planning gains its per-row
  /// currency authority; user_settings gains the durable cutover marker. All
  /// idempotent (`_ensureColumn`); the backfill/postflight run later in the
  /// upgrade transaction (see [_migrateMoneyV30]).
  Future<void> _ensureV30MoneyColumns() async {
    for (final f in kV30MinorColumns) {
      await _ensureColumn(f.table, f.minorColumn, 'INTEGER NULL');
    }
    // Per-row planning currency authority (repair-confirmed at cutover).
    await _ensureColumn('budgets', 'currency', 'TEXT NULL');
    await _ensureColumn('goals', 'currency', 'TEXT NULL');
    // Durable planning cutover marker: 0 = unresolved (P1), 1 = canonical (P3).
    await _ensureColumn('user_settings', 'planning_cutover_state',
        'INTEGER NOT NULL DEFAULT 0');
  }

  /// MALI-026 (Phase-8 B8-3 §5/§6/§7/§8/§11) — the v30 money DATA migration,
  /// inside the upgrade transaction. Non-planning domains are canonicalized
  /// (REAL -> checked int64 minor) with preflight + exact postflight; any invalid
  /// row throws and rolls the WHOLE upgrade back. Planning is STRUCTURAL ONLY:
  /// historical budgets/goals keep currency/minor NULL and land in P1
  /// (marker = unresolved) for the app-level cutover executor — EXCEPT a dataset
  /// with no planning rows at all, which is trivially canonical (§11: a fresh /
  /// empty DB must never show a historical-currency repair prompt).
  Future<void> _migrateMoneyV30() async {
    await backfillNonPlanningMoneyV30(this);
    await verifyNonPlanningMoneyV30(this);
    final hasBudgets =
        (await customSelect('SELECT 1 FROM budgets LIMIT 1;').get()).isNotEmpty;
    final hasGoals =
        (await customSelect('SELECT 1 FROM goals LIMIT 1;').get()).isNotEmpty;
    if (!hasBudgets && !hasGoals) {
      await customStatement(
          'UPDATE user_settings SET planning_cutover_state = 1;');
    }
  }

  Future<void> _ensureAccountsSyncSchema() async {
    await _ensureColumn('accounts', 'server_id', 'TEXT NULL');
    await _ensureColumn('accounts', 'synced_at', 'TEXT NULL');
    await _ensureColumn('accounts', 'server_updated_at', 'TEXT NULL');
    await _ensureColumn(
      'accounts',
      'sync_status',
      "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
    );
    await _ensureColumn('accounts', 'deleted_at', 'TEXT NULL');
    await _ensureColumn('accounts', 'bank_account_number', 'TEXT NULL');
    await _ensureColumn('accounts', 'credit_limit', 'REAL NULL');
    await _ensureColumn('accounts', 'available_credit', 'REAL NULL');
    await _ensureColumn('accounts', 'payment_due_day', 'INTEGER NULL');
    await _ensureColumn('accounts', 'wallet_provider', 'TEXT NULL');
    await _ensureColumn(
        'accounts', 'exclude_from_totals', 'INTEGER NOT NULL DEFAULT 0');
    await _ensureColumn('accounts', 'metadata', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_server_id ON accounts(server_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_sync_status ON accounts(sync_status);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_accounts_deleted_at ON accounts(deleted_at);',
    );
  }

  Future<void> _createPlanningSyncOutboxTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS planning_sync_outbox (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        operation TEXT NOT NULL CHECK(operation IN ('create','update','delete')),
        payload_json TEXT NOT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        next_retry_at TEXT NULL,
        status TEXT NOT NULL DEFAULT 'pending',
        failure_class TEXT NULL,
        op_seq INTEGER NOT NULL DEFAULT 0,
        owner_uid TEXT NULL,
        in_flight_seq INTEGER NULL,
        operation_id TEXT NULL,
        base_revision INTEGER NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_planning_outbox_entity '
      'ON planning_sync_outbox(entity_type, entity_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_planning_outbox_next_retry '
      'ON planning_sync_outbox(next_retry_at);',
    );
  }

  Future<void> _ensurePlanningEntitySyncSchema() async {
    for (final table in const [
      'budgets',
      'subscriptions',
      'goals',
      'plans',
    ]) {
      await _ensureColumn(table, 'server_id', 'TEXT NULL');
      await _ensureColumn(table, 'synced_at', 'TEXT NULL');
      await _ensureColumn(table, 'server_updated_at', 'TEXT NULL');
      await _ensureColumn(
        table,
        'sync_status',
        "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
      );
      await _ensureColumn(table, 'deleted_at', 'TEXT NULL');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_server_id ON $table(server_id);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_sync_status ON $table(sync_status);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_deleted_at ON $table(deleted_at);',
      );
    }
  }

  Future<void> _ensurePlanningChildSyncSchema() async {
    for (final table in const [
      'goal_contributions',
      'bill_payments',
      'plan_transaction_links',
    ]) {
      await _ensureColumn(table, 'server_id', 'TEXT NULL');
      await _ensureColumn(table, 'synced_at', 'TEXT NULL');
      await _ensureColumn(table, 'server_updated_at', 'TEXT NULL');
      await _ensureColumn(
        table,
        'sync_status',
        "TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict'))",
      );
      await _ensureColumn(table, 'deleted_at', 'TEXT NULL');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_server_id ON $table(server_id);',
      );
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_${table}_deleted_at ON $table(deleted_at);',
      );
    }
  }

  /// Removes dedup hashes older than [daysOld] days to prevent unbounded growth.
  ///
  /// صفوف `capture_payload:` مستثناة دائمًا: هي سجل "تم الاستيراد" الدائم
  /// لالتقاطات iOS/الدفتر وتُخزَّن بـ occurred_at ثابت عند epoch-0 (توقيع
  /// مساحة الأسماء وليس وقتًا حقيقيًا)، فحذفها بعمر occurred_at يمحو السجل
  /// كله ويسمح بإعادة استيراد Capture لم يُؤكَّد (ack) بعد — أي تكرار عملية.
  Future<void> pruneOldDedupHashes({int daysOld = 30}) async {
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: daysOld));
    await customStatement(
      "DELETE FROM dedup_hashes "
      "WHERE occurred_at < '${cutoff.toIso8601String()}' "
      "AND hash NOT LIKE 'capture_payload:%';",
    );
  }

  Future<void> _createSenderBankMappingsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sender_bank_mappings(
        id TEXT PRIMARY KEY,
        sender_id TEXT NOT NULL,
        normalized_sender_id TEXT NOT NULL UNIQUE,
        bank_key TEXT NULL,
        suggested_bank_name TEXT NOT NULL,
        suggested_country TEXT NOT NULL,
        confidence REAL NOT NULL CHECK(confidence >= 0 AND confidence <= 1),
        reason TEXT NULL,
        status TEXT NOT NULL CHECK(status IN ('pending', 'confirmed', 'rejected')),
        source TEXT NOT NULL CHECK(source IN ('gemini', 'user_manual', 'remote')),
        first_seen_at TEXT NOT NULL,
        last_seen_at TEXT NOT NULL,
        confirmed_at TEXT NULL,
        rejected_at TEXT NULL,
        rejection_expires_at TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        synced_at TEXT NULL,
        sync_status TEXT NOT NULL DEFAULT 'pending'
          CHECK(sync_status IN ('pending', 'synced', 'failed')),
        accepted_by TEXT NULL,
        CHECK(status != 'confirmed' OR confirmed_at IS NOT NULL),
        CHECK(status != 'rejected' OR rejected_at IS NOT NULL)
      );
    ''');
    await customStatement(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_sender_bank_mappings_normalized_sender '
      'ON sender_bank_mappings(normalized_sender_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_status '
      'ON sender_bank_mappings(status);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_sender_bank_mappings_sync_status '
      'ON sender_bank_mappings(sync_status);',
    );
  }

  Future<void> _createDedupHashesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS dedup_hashes(
        hash TEXT PRIMARY KEY,
        transaction_id TEXT NOT NULL,
        occurred_at TEXT NOT NULL,
        saved_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_dedup_hashes_occurred_at ON dedup_hashes(occurred_at);',
    );
  }

  Future<void> _createBillPaymentsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS bill_payments(
        id TEXT PRIMARY KEY,
        bill_id TEXT NOT NULL,
        amount REAL NOT NULL,
        currency TEXT NOT NULL,
        period_start TEXT NOT NULL,
        period_end TEXT NOT NULL,
        paid_at TEXT NOT NULL,
        installment_index INTEGER NULL,
        transaction_id TEXT NULL,
        note TEXT NULL,
        deleted_at TEXT NULL,
        FOREIGN KEY (bill_id) REFERENCES subscriptions(id) ON DELETE CASCADE
      );
    ''');
    await _ensureColumn('bill_payments', 'transaction_id', 'TEXT NULL');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_bill_payments_bill_id ON bill_payments(bill_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_bill_payments_transaction_id ON bill_payments(transaction_id);',
    );
  }

  Future<void> _createCatalogMetadataTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS catalog_metadata(
        category TEXT PRIMARY KEY,
        server_version INTEGER NOT NULL,
        local_version INTEGER NOT NULL,
        last_synced_at TEXT NULL,
        etag TEXT NULL
      );
    ''');
  }

  Future<void> _createRemoteBanksTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_banks(
        id TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        short_code TEXT NOT NULL UNIQUE,
        logo_url TEXT NULL,
        country_code TEXT NOT NULL,
        sms_senders TEXT NOT NULL,
        supported_currencies TEXT NOT NULL,
        color_hex TEXT NULL,
        is_active INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteParsersTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_parsers(
        id TEXT PRIMARY KEY,
        bank_id TEXT NOT NULL,
        sender_pattern TEXT NOT NULL,
        message_pattern TEXT NOT NULL,
        transaction_type TEXT NOT NULL,
        language TEXT NOT NULL,
        priority INTEGER NOT NULL,
        extracted_fields TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (bank_id) REFERENCES remote_banks(id) ON DELETE CASCADE
      );
    ''');
  }

  Future<void> _createRemoteCurrenciesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_currencies(
        code TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        symbol TEXT NOT NULL,
        decimal_places INTEGER NOT NULL,
        country_codes TEXT NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteCountriesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_countries(
        code TEXT PRIMARY KEY,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        flag_emoji TEXT NOT NULL,
        phone_prefix TEXT NOT NULL,
        is_supported INTEGER NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteCategoriesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_categories(
        id TEXT PRIMARY KEY,
        key TEXT NOT NULL UNIQUE,
        name_ar TEXT NOT NULL,
        name_en TEXT NOT NULL,
        icon TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        parent_key TEXT NULL,
        type TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        is_system INTEGER NOT NULL,
        is_active INTEGER NOT NULL,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteFeatureFlagsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_feature_flags(
        key TEXT PRIMARY KEY,
        value_type TEXT NOT NULL,
        value TEXT NOT NULL,
        rollout_percent INTEGER NOT NULL DEFAULT 100,
        target_countries TEXT NOT NULL DEFAULT '[]',
        is_active INTEGER NOT NULL DEFAULT 1,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteAnnouncementsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_announcements(
        id TEXT PRIMARY KEY,
        title_ar TEXT NOT NULL,
        title_en TEXT NOT NULL,
        body_ar TEXT NULL,
        body_en TEXT NULL,
        severity TEXT NOT NULL,
        min_app_version TEXT NULL,
        max_app_version TEXT NULL,
        action_label_ar TEXT NULL,
        action_label_en TEXT NULL,
        action_url TEXT NULL,
        valid_from TEXT NOT NULL,
        valid_until TEXT NULL,
        is_dismissible INTEGER NOT NULL DEFAULT 1,
        priority INTEGER NOT NULL DEFAULT 0,
        is_dismissed INTEGER NOT NULL DEFAULT 0,
        dismissed_at TEXT NULL,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  Future<void> _createRemoteGrowthCampaignsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_growth_campaigns(
        id TEXT PRIMARY KEY,
        title_ar TEXT NOT NULL,
        title_en TEXT NOT NULL,
        body_ar TEXT NULL,
        body_en TEXT NULL,
        type TEXT NOT NULL,
        target_segment TEXT NOT NULL,
        action_label_ar TEXT NULL,
        action_label_en TEXT NULL,
        action_route TEXT NULL,
        action_url TEXT NULL,
        valid_from TEXT NOT NULL,
        valid_until TEXT NULL,
        max_impressions INTEGER NULL,
        cooldown_hours INTEGER NOT NULL DEFAULT 24,
        is_dismissible INTEGER NOT NULL DEFAULT 1,
        once_per_user INTEGER NOT NULL DEFAULT 0,
        priority INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  /// MALI-COUPONS (Phase C4, schema v31) — the Offers/Coupons catalog cache.
  ///
  /// Pure REFETCHABLE server catalog: it is replaced wholesale by every
  /// successful `catalog-coupons` snapshot and is deliberately EXCLUDED from the
  /// business backup (see BackupSnapshotBuilder.intentionallyExcluded) and from
  /// the sign-out wipe, exactly like every other `remote_*` table. It holds no
  /// user-authored data and no per-user state: V1 has no favourites, dismissals
  /// or persisted impression state.
  ///
  /// Embedded collections arrive as deterministic JSON text (tags keep the
  /// server's order); ALL decoding happens at the repository boundary so no
  /// widget ever parses JSON.
  /// PHASE 8 — the durable capture work item.
  ///
  /// ## Two identity layers, deliberately not one
  ///
  /// `capture_uuid` is the WORK-ITEM IDENTITY: it is minted once by the native
  /// capture layer and is what a lease, a retry and an ACK all refer to. It is
  /// the primary key, so re-presenting the same native item resolves the
  /// existing row instead of creating a second one.
  ///
  /// `content_fingerprint` is a DUPLICATE SIGNAL ONLY. Two byte-identical bank
  /// messages are genuinely ambiguous: a user really can buy the same coffee
  /// for the same amount at the same shop twice in one minute. So the
  /// fingerprint may raise a review, and it may never be treated as proof that
  /// two messages are one transaction. It is therefore NOT unique, and nothing
  /// keys off it.
  ///
  /// ## Ordering contract
  ///
  ///   1. the native item stays leased/unacked
  ///   2. this row is created or resolved by `capture_uuid`
  ///   3. Drift COMMITs
  ///   4. only then is the native item ACKed
  ///
  /// A crash between 3 and 4 re-presents the item; step 2 finds the existing
  /// row and no duplicate work or transaction is created. A crash before 3
  /// loses the row but not the native item, which is re-presented. The
  /// dangerous ordering — ACK before commit — is the one this exists to
  /// prevent.
  /// PHASE 9A — genuine user labels.
  ///
  /// Phase 11 needs an auto-commit PRECISION estimate, and shadow telemetry
  /// cannot provide one: without labels, disagreement is not ground truth. This
  /// table is where real accept/correct actions are recorded so that gate has
  /// something to measure.
  ///
  /// ## What is deliberately absent
  ///
  /// There is NO column for the message. A label says "the user corrected the
  /// direction on capture X at revision N" — which is the entire evidentiary
  /// value — and storing the SMS alongside it would create a second, permanent
  /// copy of bank text for a purpose that does not need it.
  ///
  /// ## Why (capture_uuid, work_item_revision) is UNIQUE
  ///
  /// It makes replay idempotent. A double-tap, a retried write or a duplicated
  /// event records ONE label, and a label for a superseded revision cannot be
  /// added after the fact — which is what stops stale UI actions from
  /// manufacturing evidence about state that no longer exists.
  Future<void> _createCaptureReviewLabelsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS capture_review_labels (
        id TEXT PRIMARY KEY,
        capture_uuid TEXT NOT NULL,
        transaction_id TEXT NULL,
        review_state TEXT NOT NULL,
        action TEXT NOT NULL
          CHECK(action IN ('accepted','corrected','dismissed')),
        corrected_fields TEXT NOT NULL DEFAULT '',
        corrected_direction INTEGER NOT NULL DEFAULT 0,
        work_item_revision INTEGER NOT NULL,
        created_at TEXT NOT NULL,
        UNIQUE(capture_uuid, work_item_revision)
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_crl_capture '
      'ON capture_review_labels(capture_uuid);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_crl_action '
      'ON capture_review_labels(action);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_crl_direction '
      'ON capture_review_labels(corrected_direction);',
    );
  }

  Future<void> _createCaptureWorkItemsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS capture_work_items (
        capture_uuid TEXT PRIMARY KEY,
        content_fingerprint TEXT NULL,
        state TEXT NOT NULL DEFAULT 'received'
          CHECK(state IN ('received','model_in_flight','model_result_persisted',
                          'applied','review','rejected','dead_letter')),
        lease_owner TEXT NULL,
        claimed_at TEXT NULL,
        lease_expires_at TEXT NULL,
        attempt_count INTEGER NOT NULL DEFAULT 0,
        model_result_json TEXT NULL,
        model_executions INTEGER NOT NULL DEFAULT 0,
        transaction_id TEXT NULL,
        revision INTEGER NOT NULL DEFAULT 0,
        last_error TEXT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cwi_state ON capture_work_items(state);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cwi_lease_expiry '
      'ON capture_work_items(lease_expires_at);',
    );
    // NOT UNIQUE, on purpose — see the identity note above.
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cwi_fingerprint '
      'ON capture_work_items(content_fingerprint);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_cwi_transaction '
      'ON capture_work_items(transaction_id);',
    );
  }

  Future<void> _createRemoteCouponsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_coupons(
        id TEXT PRIMARY KEY,
        slug TEXT NOT NULL,
        partner_name TEXT NOT NULL,
        title_ar TEXT NOT NULL,
        title_en TEXT NULL,
        description_ar TEXT NOT NULL,
        description_en TEXT NULL,
        redemption_type TEXT NOT NULL,
        code TEXT NULL,
        partner_url TEXT NULL,
        display_category_key TEXT NOT NULL,
        display_category_label_ar TEXT NOT NULL,
        display_category_label_en TEXT NULL,
        tags_json TEXT NOT NULL DEFAULT '[]',
        spend_hints_json TEXT NOT NULL DEFAULT '[]',
        country_codes_json TEXT NOT NULL DEFAULT '[]',
        accent_hex TEXT NULL,
        image_url TEXT NULL,
        featured INTEGER NOT NULL DEFAULT 0,
        priority INTEGER NOT NULL DEFAULT 0,
        valid_from TEXT NOT NULL,
        valid_until TEXT NULL,
        terms_ar TEXT NULL,
        synced_at TEXT NOT NULL
      );
    ''');
  }

  /// COUPONS Phase 1 — the canonical merchant catalog cache.
  ///
  /// A catalog cache, not user data: it is populated only by catalog-delta,
  /// excluded from backup (it is reproducible from the server) and survives a
  /// sign-out wipe (it contains nothing about the user).
  Future<void> _createRemoteCatalogMerchantsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_catalog_merchants(
        id TEXT PRIMARY KEY,
        slug TEXT NOT NULL,
        name_ar TEXT NOT NULL,
        name_en TEXT NULL,
        primary_domain TEXT NULL,
        logo_url TEXT NULL,
        default_display_category_key TEXT NULL,
        country_codes_json TEXT NOT NULL DEFAULT '[]',
        is_active INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_version INTEGER NOT NULL DEFAULT 0,
        synced_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_rcm_active '
      'ON remote_catalog_merchants(is_active, is_deleted);',
    );
  }

  /// Reviewed aliases only — catalog-delta never serves an unreviewed row, and
  /// nothing on the device may add one.
  ///
  /// `alias_normalized` is the lookup key produced by `merchant_alias_key_v1`;
  /// the index on it is what makes resolution a single indexed equality rather
  /// than a scan over the whole alias set on every transaction.
  Future<void> _createRemoteMerchantAliasesTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_merchant_aliases(
        id TEXT PRIMARY KEY,
        merchant_id TEXT NOT NULL,
        alias_normalized TEXT NOT NULL,
        alias_kind TEXT NOT NULL,
        country_code TEXT NULL,
        priority INTEGER NOT NULL DEFAULT 0,
        key_version INTEGER NOT NULL DEFAULT 1,
        is_active INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_version INTEGER NOT NULL DEFAULT 0,
        synced_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_rma_lookup '
      'ON remote_merchant_aliases(alias_normalized, alias_kind);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_rma_merchant '
      'ON remote_merchant_aliases(merchant_id);',
    );
  }

  /// The structured half of an offer's value (server 0095), cached alongside the
  /// prose the user actually sees.
  ///
  /// Every column is NULLABLE and added with `_ensureColumn`, so a cached
  /// snapshot written by an older build stays readable and simply has no
  /// structured value. The savings layer must abstain on a null rather than
  /// infer one — an invented number is worse than no number in a finance app.
  Future<void> _ensureRemoteCouponEconomicsColumns() async {
    const columns = <String, String>{
      'merchant_id': 'TEXT NULL',
      'merchant_slug': 'TEXT NULL',
      'merchant_name_ar': 'TEXT NULL',
      'merchant_name_en': 'TEXT NULL',
      'benefit_type': 'TEXT NULL',
      'discount_bps': 'INTEGER NULL',
      'fixed_amount_minor': 'INTEGER NULL',
      'min_spend_minor': 'INTEGER NULL',
      'max_saving_minor': 'INTEGER NULL',
      'benefit_currency': 'TEXT NULL',
      'source': "TEXT NOT NULL DEFAULT 'manual'",
      'verification_state': "TEXT NOT NULL DEFAULT 'unverified'",
    };
    for (final entry in columns.entries) {
      await _ensureColumn('remote_coupons', entry.key, entry.value);
    }
  }

  /// The merchant-personalization toggle — LOCAL ONLY, and off by default.
  ///
  /// It lives on `user_settings` because that is where user preferences live,
  /// but it must never leave the device: the fact that someone enabled
  /// spending-derived personalization is itself information about them, and the
  /// server has no use for it because the server does no personalizing.
  ///
  /// `user_settings` IS synced — but through an EXPLICIT column map in
  /// `planning_push_service.dart`, not `SELECT *`. Omitting this column from
  /// that map is what keeps it local, and
  /// `test/architecture/coupons_isolation_test.dart` asserts the omission so it
  /// stays a contract rather than a habit.
  ///
  /// Default 0. A personalization feature that defaults on is not a choice.
  Future<void> _ensureMerchantPersonalizationColumn() async {
    await _ensureColumn(
      'user_settings',
      'merchant_personalization_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
  }

  /// COUPONS Phase 3 — the device's half of an affiliate click.
  ///
  /// Holds the plaintext `claim_token`. The SERVER holds only its SHA-256, so
  /// this row is the only thing in existence that can prove a click was ours —
  /// which is exactly why attribution can work without the server knowing whose
  /// clicks are whose.
  ///
  /// USER-SCOPED, therefore WIPED on sign-out and EXCLUDED from backup. Excluded
  /// because a restored token would claim a click made on a different install
  /// while the original device might still be polling it, and because an
  /// attribution window is days — a token in a year-old backup is expired
  /// credentials.
  Future<void> _createAffiliateClickReceiptsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS affiliate_click_receipts(
        click_id TEXT PRIMARY KEY,
        claim_token TEXT NOT NULL,
        coupon_id TEXT NOT NULL,
        merchant_id TEXT NULL,
        launched_at TEXT NOT NULL,
        last_status TEXT NOT NULL DEFAULT 'pending',
        last_checked_at TEXT NULL,
        expires_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_acr_pending '
      'ON affiliate_click_receipts(last_status, expires_at);',
    );
  }

  /// COUPONS Phase 4 — the savings ledger. LOCAL ONLY.
  ///
  /// What a user saved is computed here, from the offer's own discount and the
  /// user's own confirmation. It is never uploaded: a server-side savings total
  /// would be a spending profile, and there is no product reason for one to
  /// exist off the device.
  ///
  /// INCLUDED in backup, unlike the click receipts. A savings history is
  /// something a user would be upset to lose when they change phone, and unlike
  /// a claim token it carries no credential and does not expire.
  ///
  /// `evidence_kind` is the honesty column. `user_confirmed` means the user said
  /// they used the offer; `conversion_estimated` means a provider reported a
  /// sale and we applied the offer's own discount; `conversion_verified` means
  /// the provider told us the actual discount. They are NEVER summed into one
  /// figure without saying which is which.
  Future<void> _createLocalOfferSavingsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS local_offer_savings(
        id TEXT PRIMARY KEY,
        coupon_id TEXT NOT NULL,
        merchant_id TEXT NULL,
        click_id TEXT NULL,
        evidence_kind TEXT NOT NULL,
        amount_minor INTEGER NOT NULL,
        currency TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'active',
        occurred_at TEXT NOT NULL,
        created_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_los_active '
      'ON local_offer_savings(state, currency, occurred_at);',
    );
  }

  Future<void> _createRemoteMerchantKeywordsTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS remote_merchant_keywords(
        id TEXT PRIMARY KEY,
        keyword TEXT NOT NULL,
        category_key TEXT NOT NULL,
        language TEXT NOT NULL DEFAULT 'any',
        country_code TEXT NOT NULL DEFAULT 'ALL',
        priority INTEGER NOT NULL DEFAULT 0,
        is_active INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        updated_at TEXT NOT NULL,
        logo_url TEXT
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_rmk_country_active '
      'ON remote_merchant_keywords(country_code, is_active);',
    );
  }

  Future<void> _createPendingMerchantFeedbackTable() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS pending_merchant_feedback(
        normalized_keyword TEXT PRIMARY KEY,
        seen_count INTEGER NOT NULL DEFAULT 1,
        last_seen_at TEXT NOT NULL
      );
    ''');
    // v23: Phase 1 notification tracking (docs/NOTIFICATION_PIPELINE_AUDIT.md).
    // Durable local outbox of notification lifecycle events, synced
    // opportunistically to notification_logs (supabase/migrations/
    // 0052_notification_logs.sql). Not a source of truth on its own — it is
    // the offline-safe relay so logging never depends on immediate network
    // availability, and never blocks showing/scheduling the notification.
    await customStatement('''
      CREATE TABLE IF NOT EXISTS notification_log_events(
        id TEXT PRIMARY KEY,
        notification_log_id TEXT NOT NULL,
        event_type TEXT NOT NULL CHECK(
          event_type IN ('created', 'queued', 'sent', 'failed', 'opened')
        ),
        channel TEXT NOT NULL,
        notification_type TEXT NOT NULL,
        related_entity_type TEXT NULL,
        related_entity_id TEXT NULL,
        payload_json TEXT NOT NULL DEFAULT '{}',
        error_code TEXT NULL,
        error_reason TEXT NULL,
        occurred_at TEXT NOT NULL,
        synced_at TEXT NULL,
        sync_attempt_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      );
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notification_log_events_log_id '
      'ON notification_log_events(notification_log_id);',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS idx_notification_log_events_unsynced '
      'ON notification_log_events(synced_at) WHERE synced_at IS NULL;',
    );
  }

  Future<int> _currentUserVersion() async {
    final row = await customSelect('PRAGMA user_version;').getSingle();
    return row.read<int>('user_version');
  }

  /// F-032 / OD-02 — attribute historical transactions to a canonical card.
  ///
  /// Matches ONLY where the evidence is unambiguous: exactly one live card whose
  /// `(account_id, last4)` equals the transaction's. Anything else — no match,
  /// or more than one candidate — is left NULL.
  ///
  /// **Never guesses.** An unattributed transaction is a visible, correctable
  /// state; a wrongly attributed one is money silently displayed under someone
  /// else's card, which is precisely the defect this replaces.
  ///
  /// Idempotent: only rows with `card_id IS NULL` are considered, so a repeat
  /// run performs no write. Returns the number of rows attributed.
  /// F-023 — re-run the per-key achievement seed.
  ///
  /// Exposed so the backfill contract (missing keys added, existing progress
  /// untouched) is testable without driving a whole bootstrap.
  @visibleForTesting
  Future<void> reseedAchievementsForTest() async {
    for (final achievement in DatabaseSeed.achievements) {
      await customInsert(
        '''
          INSERT OR IGNORE INTO achievements(id, key, name_ar, unlocked_at, progress)
          VALUES (?, ?, ?, NULL, ?);
        ''',
        variables: [
          Variable.withString(achievement.id),
          Variable.withString(achievement.key),
          Variable.withString(achievement.nameAr),
          Variable.withReal(achievement.progress),
        ],
      );
    }
  }

  Future<int> backfillCardIdentity() async {
    return customUpdate(
      '''
      UPDATE transactions
         SET card_id = (
           SELECT c.id FROM cards c
            WHERE c.deleted_at IS NULL
              AND c.account_id = transactions.account_id
              AND c.last4 = transactions.card_last4
         )
       WHERE card_id IS NULL
         AND card_last4 IS NOT NULL
         AND account_id IS NOT NULL
         AND (
           SELECT COUNT(*) FROM cards c
            WHERE c.deleted_at IS NULL
              AND c.account_id = transactions.account_id
              AND c.last4 = transactions.card_last4
         ) = 1;
      ''',
      updates: {},
    );
  }

  Future<void> _ensureColumn(
    String table,
    String column,
    String definition,
  ) async {
    final rows = await customSelect('PRAGMA table_info($table);').get();
    final exists = rows.any((row) => row.read<String>('name') == column);
    if (!exists) {
      await customStatement(
          'ALTER TABLE $table ADD COLUMN $column $definition;');
    }
  }

  /// v27: يجعل `account_id` في جدول `cards` قابلًا لأن يكون NULL (بطاقة بلا
  /// حساب مرتبط). SQLite لا يدعم إسقاط NOT NULL بـ ALTER — نعيد بناء الجدول مرة
  /// واحدة. idempotent: لا يفعل شيئًا إن كان العمود بالفعل NULLable. يفترض أن
  /// عمودَي color_theme/accent_hex أُضيفا مسبقًا عبر _ensureColumn.
  Future<void> _relaxCardsAccountNullable() async {
    final info = await customSelect('PRAGMA table_info(cards);').get();
    final accountCol =
        info.where((row) => row.read<String>('name') == 'account_id').toList();
    if (accountCol.isEmpty) return; // حماية دفاعية — لا يُفترض حدوثه.
    final notNull = accountCol.first.read<int>('notnull') == 1;
    if (!notNull) return; // بالفعل NULLable — لا حاجة لإعادة البناء.

    // إعادة البناء ذرّية (transaction) حتى لا تُترك cards_new يتيمة لو انقطع
    // التطبيق في المنتصف.
    await transaction(() async {
      await customStatement('DROP TABLE IF EXISTS cards_new;');
      await customStatement('''
        CREATE TABLE cards_new(
          id TEXT PRIMARY KEY,
          account_id TEXT NULL,
          nickname TEXT NULL,
          last4 TEXT NOT NULL,
          network TEXT NOT NULL,
          source TEXT NOT NULL DEFAULT 'manual' CHECK(source IN ('manual', 'auto')),
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL,
          server_id TEXT NULL,
          synced_at TEXT NULL,
          server_updated_at TEXT NULL,
          sync_status TEXT NULL CHECK(sync_status IN ('local_only', 'synced', 'pending', 'conflict')),
          deleted_at TEXT NULL,
          color_theme TEXT NULL,
          accent_hex TEXT NULL
        );
      ''');
      await customStatement('''
        INSERT INTO cards_new(
          id, account_id, nickname, last4, network, source,
          created_at, updated_at, server_id, synced_at, server_updated_at,
          sync_status, deleted_at, color_theme, accent_hex
        )
        SELECT id, account_id, nickname, last4, network, source,
          created_at, updated_at, server_id, synced_at, server_updated_at,
          sync_status, deleted_at, color_theme, accent_hex
        FROM cards;
      ''');
      await customStatement('DROP TABLE cards;');
      await customStatement('ALTER TABLE cards_new RENAME TO cards;');
      await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_cards_account ON cards(account_id);',
      );
      await customStatement(
        'CREATE UNIQUE INDEX IF NOT EXISTS uidx_cards_account_last4_active '
        'ON cards(account_id, last4) WHERE deleted_at IS NULL;',
      );
    });
  }

  Future<void> _seedIfNeeded() async {
    if (await count('categories') == 0) {
      for (final category in DatabaseSeed.categories) {
        await customInsert(
          '''
            INSERT INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
            VALUES (?, ?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(category.id),
            Variable.withString(category.key),
            Variable.withString(category.nameAr),
            Variable.withString(category.icon),
            Variable.withString(category.color),
            Variable.withInt(boolToSql(category.isIncome)),
            Variable.withInt(category.sort),
          ],
        );
      }
    }
    await _ensureInternalCategories();

    if (await count('merchants') == 0 &&
        await count('merchant_category_map') == 0 &&
        await count('remote_merchant_keywords') == 0) {
      for (final mapping in DatabaseSeed.merchantMappings) {
        final merchantId = IdGenerator.next();
        final now = DateTime.now().toUtc();
        final categoryId = await _categoryIdByKey(mapping.categoryKey);
        if (categoryId == null) {
          continue;
        }

        await customInsert(
          '''
            INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at)
            VALUES (?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(merchantId),
            Variable.withString(mapping.rawName),
            Variable.withString(_normalizeMerchant(mapping.rawName)),
            Variable.withString(dateTimeToSql(now)),
            Variable.withString(dateTimeToSql(now)),
          ],
        );

        await customInsert(
          '''
            INSERT INTO merchant_category_map(
              id, merchant_id, category_id, is_user_confirmed, confidence, updated_at
            )
            VALUES (?, ?, ?, ?, ?, ?);
          ''',
          variables: [
            Variable.withString(IdGenerator.next()),
            Variable.withString(merchantId),
            Variable.withString(categoryId),
            Variable.withInt(0),
            Variable.withReal(mapping.confidence),
            Variable.withString(dateTimeToSql(now)),
          ],
        );
      }
    }

    // F-023 / OD-03 — seed per KEY, not "only when the table is empty".
    //
    // The old guard meant an install that had already seeded the original six
    // achievements never received a new one. That is precisely how the three
    // server-awarded keys (first/tenth/century_transaction) had no local row to
    // land on, so every server unlock was dropped in silence.
    //
    // `INSERT OR IGNORE` on the UNIQUE key makes this idempotent and
    // non-destructive: existing rows keep their unlocked_at and progress, and
    // only genuinely missing keys are added.
    {
      for (final achievement in DatabaseSeed.achievements) {
        await customInsert(
          '''
            INSERT OR IGNORE INTO achievements(id, key, name_ar, unlocked_at, progress)
            VALUES (?, ?, ?, NULL, ?);
          ''',
          variables: [
            Variable.withString(achievement.id),
            Variable.withString(achievement.key),
            Variable.withString(achievement.nameAr),
            Variable.withReal(achievement.progress),
          ],
        );
      }
    }

    if (await count('streaks') == 0) {
      await customInsert(
        '''
          INSERT INTO streaks(id, current_streak, longest_streak, last_active_date, freezes_available)
          VALUES (?, 0, 0, ?, 1);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
        ],
      );
    }

    if (await count('xp_levels') == 0) {
      await customInsert(
        '''
          INSERT INTO xp_levels(id, total_xp, level, level_key)
          VALUES (?, 0, 1, 'beginner');
        ''',
        variables: [Variable.withString(IdGenerator.next())],
      );
    }

    if (await count('user_settings') == 0) {
      // MALI-058n — the SQLCipher key lives ONLY in platform secure storage and
      // is NEVER copied into the database. db_encryption_key_ref is a deprecated,
      // non-authoritative column that must stay EMPTY so it can never enter a
      // backup snapshot; it is seeded to '' (not the raw key).
      await customInsert(
        '''
          INSERT INTO user_settings(
            id, country, currency, language, theme, input_method, notifications_json, db_encryption_key_ref, privacy_mode_enabled
          )
          VALUES (?, 'SA', 'SAR', ?, 'system', 'auto', ?, '', 0);
        ''',
        variables: [
          Variable.withString(IdGenerator.next()),
          Variable.withString(initialLanguage),
          Variable.withString(kDefaultSettingsNotificationsJson),
        ],
      );
    }

    await _ensureDefaultAccount();
  }

  /// يُستدعى بعد استعادة نسخة احتياطية لضمان وجود حساب افتراضي وربط
  /// أي سجلات يتيمة (account_id = NULL) به.
  Future<void> runPostRestoreSetup() async {
    // MALI-059n: a restore must NOT import consent as authorization on a new
    // device — reset both to unset/OFF so the restored device re-asks. (The
    // backup no longer carries consent, but reset unconditionally so legacy
    // backups that do carry it can never auto-authorize.)
    //
    // WP-6: the reset is a consent change, so a prior choice moves the version
    // forward (never back) and the next link/consent push projects the OFF state.
    await customStatement(
      'UPDATE user_settings SET '
      'cloud_consent_version = MAX(cloud_consent_version, ai_consent_version) + 1, '
      'ai_consent_version = MAX(cloud_consent_version, ai_consent_version) + 1 '
      'WHERE ai_consent_state IS NOT NULL OR cloud_consent_state IS NOT NULL;',
    );
    await customStatement(
      'UPDATE user_settings SET ai_consent_granted = 0, '
      'cloud_processing_enabled = 0, ai_consent_state = NULL, '
      'cloud_consent_state = NULL, cloud_consent_at = NULL, '
      'ai_consent_at = NULL;',
    );
    await _ensureDefaultAccount();
  }

  /// يُعيد تشغيل بذر البيانات الأولية لأي جدول أفرغه مسح بيانات (تسجيل خروج،
  /// حذف حساب) — نفس المنطق الذي يعمل عند فتح قاعدة البيانات، فقط بلا انتظار
  /// إعادة تشغيل التطبيق. يضمن وجود صف user_settings/حساب افتراضي فوراً.
  Future<void> reseedDefaultsAfterWipe() async {
    await _seedIfNeeded();
  }

  /// A-7: لا يُنشئ أي حساب أبداً. الحسابات تُنشأ فقط بفعل صريح من المستخدم
  /// (شاشة إعداد الحساب) عبر المستودع. هنا إصلاحات غير منشئة فقط: ترقية أول
  /// حساب قائم إلى افتراضي إن لم يكن هناك افتراضي. (ربط الأهداف اليتيمة بالحساب
  /// الافتراضي انتقل إلى DriftGoalRepository ليُسجَّل في الـ outbox.) مع صفر حسابات لا يُمَسّ شيء.
  Future<void> _ensureDefaultAccount() async {
    if (await count('accounts') > 0) {
      // اضمن وجود حساب افتراضي واحد على الأقل.
      final defaults = await customSelect(
        'SELECT id FROM accounts WHERE is_default = 1 AND deleted_at IS NULL LIMIT 1;',
      ).get();
      if (defaults.isEmpty) {
        await customStatement(
          'UPDATE accounts SET is_default = 1, '
          '$kMarkPendingIfServerBacked WHERE id = '
          '(SELECT id FROM accounts WHERE deleted_at IS NULL ORDER BY sort_order ASC LIMIT 1);',
        );
      }
    }
  }

  // Idempotently ensures every seed category (internal + new ones added in
  // later app versions) exists. INSERT OR IGNORE keys off the UNIQUE `key`, so
  // existing rows are untouched and only genuinely new categories are inserted.
  Future<void> _ensureInternalCategories() async {
    for (final category in DatabaseSeed.categories) {
      await customInsert(
        '''
          INSERT OR IGNORE INTO categories(id, key, name_ar, icon, color, is_income, sort_order)
          VALUES (?, ?, ?, ?, ?, ?, ?);
        ''',
        variables: [
          Variable.withString(category.id),
          Variable.withString(category.key),
          Variable.withString(category.nameAr),
          Variable.withString(category.icon),
          Variable.withString(category.color),
          Variable.withInt(boolToSql(category.isIncome)),
          Variable.withInt(category.sort),
        ],
      );
    }
  }

  // Repairs DBs that ended up with duplicate category rows (same `key`, which
  // crashed category dropdowns). Repoints every FK reference to the canonical
  // (lowest-rowid) row per key, then deletes the duplicates.
  Future<void> _dedupeCategoryRows() async {
    final dup = await customSelect(
      'SELECT COUNT(*) - COUNT(DISTINCT key) AS d FROM categories;',
    ).getSingle();
    if (dup.read<int>('d') == 0) return;

    for (final table in const [
      'transactions',
      'budgets',
      'merchant_category_map'
    ]) {
      await customStatement('''
        UPDATE $table SET category_id = (
          SELECT c.id FROM categories c
          WHERE c.key = (SELECT k.key FROM categories k WHERE k.id = $table.category_id)
          ORDER BY c.rowid LIMIT 1
        )
        WHERE category_id IS NOT NULL
          AND category_id NOT IN (
            SELECT id FROM categories
            WHERE rowid IN (SELECT MIN(rowid) FROM categories GROUP BY key)
          );
      ''');
    }
    await customStatement(
      'DELETE FROM categories WHERE rowid NOT IN '
      '(SELECT MIN(rowid) FROM categories GROUP BY key);',
    );
  }

  Future<void> _backfillSystemTransactionCategories() async {
    // A-4b: a changed server-backed row is marked pending (+ updated_at) so the
    // PendingSyncReconciler records sync intent for it.
    final nowSql = dateTimeToSql(DateTime.now().toUtc());
    for (final entry in const {
      'transfer': 'transfers',
      'withdrawal': 'cash',
      'income': 'income',
    }.entries) {
      await customUpdate(
        '''
          UPDATE transactions
          SET category_id = (
            SELECT id FROM categories WHERE key = ? LIMIT 1
          ),
          updated_at = ?,
          $kMarkPendingIfServerBacked
          WHERE type = ?
            AND (
              category_id IS NULL OR
              category_id != (SELECT id FROM categories WHERE key = ? LIMIT 1)
            );
        ''',
        variables: [
          Variable.withString(entry.value),
          Variable.withString(nowSql),
          Variable.withString(entry.key),
          Variable.withString(entry.value),
        ],
      );
    }
    await customUpdate(
      '''
        UPDATE transactions
        SET merchant_id = NULL, raw_merchant = NULL,
            updated_at = ${sqlString(nowSql)},
            $kMarkPendingIfServerBacked
        WHERE type IN ('transfer', 'income')
          AND (merchant_id IS NOT NULL OR raw_merchant IS NOT NULL);
      ''',
    );
  }

  Future<void> _backfillTransactionDirections() async {
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'credit',
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
            $kMarkPendingIfServerBacked
        WHERE direction IS NULL
          AND (
            raw_message LIKE '%credited%' OR
            raw_message LIKE '%received%' OR
            raw_message LIKE '%incoming%' OR
            raw_message LIKE '%إيداع%' OR
            raw_message LIKE '%ايداع%' OR
            raw_message LIKE '%إضافة%' OR
            raw_message LIKE '%اضافة%' OR
            raw_message LIKE '%تم إضافة%' OR
            raw_message LIKE '%تم اضافة%' OR
            raw_message LIKE '%حوالة واردة%' OR
            raw_message LIKE '%مبلغ وارد%'
          );
      ''',
    );
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'debit',
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
            $kMarkPendingIfServerBacked
        WHERE direction IS NULL
          AND (
            type IN ('payment', 'withdrawal') OR
            raw_message LIKE '%debited%' OR
            raw_message LIKE '%deducted%' OR
            raw_message LIKE '%withdrawn%' OR
            raw_message LIKE '%purchase%' OR
            raw_message LIKE '%خصم%' OR
            raw_message LIKE '%شراء%' OR
            raw_message LIKE '%سحب%' OR
            raw_message LIKE '%مبلغ صادر%'
          );
      ''',
    );
    await customUpdate(
      '''
        UPDATE transactions
        SET direction = 'unknown',
            updated_at = ${sqlString(dateTimeToSql(DateTime.now().toUtc()))},
            $kMarkPendingIfServerBacked
        WHERE direction IS NULL;
      ''',
    );
  }

  Future<void> _repairBankCaptureTimestampDrift() async {
    // Older backend builds interpreted SMS body times as UTC instead of the
    // device timezone, and briefly trusted stale AI years such as 2024. A bank
    // capture cannot happen far in the future, and SMS dates older than the
    // import time by a month are safer as received-at timestamps than as
    // misleading ledger dates.
    await customUpdate(
      '''
        UPDATE transactions
        SET occurred_at = COALESCE(sms_received_at, created_at),
            comparison_timestamp = COALESCE(sms_received_at, created_at),
            comparison_timestamp_source = 'received_at',
            transaction_time_from_sms = NULL,
            sms_received_at = COALESCE(sms_received_at, created_at),
            updated_at = ?,
            $kMarkPendingIfServerBacked
        WHERE source = 'bank'
          AND status IN ('confirmed', 'pending')
          AND comparison_timestamp_source = 'sms_body'
          AND (
            julianday(occurred_at) - julianday(created_at) > (10.0 / 1440.0)
            OR julianday(created_at) - julianday(occurred_at) > 31.0
          );
      ''',
      variables: [
        Variable.withString(dateTimeToSql(DateTime.now().toUtc())),
      ],
    );
  }

  Future<String?> _categoryIdByKey(String key) async {
    final row = await customSelect(
      'SELECT id FROM categories WHERE key = ? LIMIT 1;',
      variables: [Variable.withString(key)],
    ).getSingleOrNull();
    return row?.read<String>('id');
  }

  static String normalizeMerchant(String rawMerchant) =>
      _normalizeMerchant(rawMerchant);

  static String _normalizeMerchant(String rawMerchant) {
    return rawMerchant
        .toUpperCase()
        .replaceAll(RegExp(r'[0-9]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}
