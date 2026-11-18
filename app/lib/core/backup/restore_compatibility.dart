import 'backup_service.dart';
import 'backup_snapshot_builder.dart';

// MALI-014 / MALI-076n (Batch-5 closure) §Blocker-2 — PREPARATION-TIME compatibility
// adapters. Every supported snapshot schema version has an EXPLICIT adapter that
// normalizes the decoded source into the CURRENT plan shape BEFORE the exclusive
// maintenance/mutation phase. The mutation consumes only the normalized plan, so no
// migration logic ever discovers a missing source field after deletion begins, and
// no arbitrary source field reaches SQL.
//
// Mali's local schema is manual and UNIFORM across snapshot versions (the same
// reason AppDatabase._versionedMigrations is empty): the restorable column set is
// identical for v1/v2/v3, so the per-version transform is table-presence
// normalization + defaulted columns + safe warnings, not field renames. Each
// adapter still declares its contract explicitly so a future divergent version adds
// a real transform here (never a post-mutation repair).

class SnapshotSchemaAdapter {
  const SnapshotSchemaAdapter({
    required this.version,
    required this.requiredTables,
    required this.optionalTables,
    this.columnDefaults = const {},
    this.warning,
  });

  final int version;

  /// Tables a healthy snapshot of this version must carry (non-empty).
  final Set<String> requiredTables;

  /// Tables that may be present but empty/absent (defaulted on restore).
  final Set<String> optionalTables;

  /// Per-table column → default applied when a legacy row omits a column the
  /// current schema needs (empty today — the schema is uniform).
  final Map<String, Map<String, Object?>> columnDefaults;

  /// A privacy-safe warning code recorded on the plan for this version.
  final String? warning;
}

class RestoreCompatibility {
  const RestoreCompatibility._();

  static const int currentVersion = 5;

  // The full restorable table set (current schema).
  static Set<String> get _allTables =>
      BackupSnapshotBuilder.restorableColumns.keys.toSet();

  /// The explicit adapter registry, by snapshot schema version.
  static final Map<int, SnapshotSchemaAdapter> _adapters = {
    // MALI-026 (B8-3 §2): v4 adds exact `_minor` (+ budgets/goals currency) to the
    // uniform restorable column set — same required tables as v3, no warning (it
    // IS the current shape); the restore's version dispatch consumes the exact
    // minors directly.
    // v5 adds the deletion history of saved category rules (three tables, any
    // of which may be empty): same required tables as v4.
    5: SnapshotSchemaAdapter(
      version: 5,
      requiredTables: const {'categories', 'accounts', 'user_settings'},
      optionalTables: _allTables.difference(
          const {'categories', 'accounts', 'user_settings'}),
    ),
    4: SnapshotSchemaAdapter(
      version: 4,
      requiredTables: const {'categories', 'accounts', 'user_settings'},
      optionalTables: _allTables.difference(
          const {'categories', 'accounts', 'user_settings'}),
    ),
    3: SnapshotSchemaAdapter(
      version: 3,
      requiredTables: const {'categories', 'accounts', 'user_settings'},
      optionalTables: _allTables.difference(
          const {'categories', 'accounts', 'user_settings'}),
    ),
    2: SnapshotSchemaAdapter(
      version: 2,
      // v2 predates the cards/sender-mapping split — those tables may be absent
      // and are defaulted (the conditional restore never wipes the seeded catalog).
      requiredTables: const {'accounts', 'user_settings'},
      optionalTables: _allTables.difference(const {'accounts', 'user_settings'}),
      warning: 'legacy_schema_v2',
    ),
    1: SnapshotSchemaAdapter(
      version: 1,
      // v1 predates multi-account; a default account is ensured post-restore.
      requiredTables: const {'user_settings'},
      optionalTables: _allTables.difference(const {'user_settings'}),
      warning: 'legacy_schema_v1',
    ),
  };

  static bool isSupported(int version) =>
      version >= 1 && version <= currentVersion;

  static SnapshotSchemaAdapter adapterFor(int version) {
    final adapter = _adapters[version];
    if (adapter == null) {
      throw BackupException(
        'هذه النسخة الاحتياطية من إصدار غير مدعوم ($version). حدّث التطبيق.',
        code: BackupError.unsupportedBackupVersion,
        args: ['$version'],
      );
    }
    return adapter;
  }

  /// Normalize [rawTables] (already whitelisted) into the current plan shape for
  /// [schemaVersion]: verify the version's required tables are present + non-empty,
  /// apply any column defaults, and return the version's warnings. Throws
  /// [BackupException] on an unsupported version or a missing required table.
  static ({Map<String, List<Map<String, Object?>>> tables, List<String> warnings})
      normalize(
    Map<String, List<Map<String, Object?>>> rawTables,
    int schemaVersion,
  ) {
    if (!isSupported(schemaVersion)) {
      throw BackupException(
        'هذه النسخة الاحتياطية من إصدار غير مدعوم ($schemaVersion). حدّث التطبيق.',
        code: BackupError.unsupportedBackupVersion,
        args: ['$schemaVersion'],
      );
    }
    final adapter = adapterFor(schemaVersion);
    for (final table in adapter.requiredTables) {
      final rows = rawTables[table];
      if (rows == null || rows.isEmpty) {
        throw BackupException(
          'النسخة الاحتياطية تالفة أو غير مكتملة (جدول "$table" مفقود). '
          'تعذّرت الاستعادة.',
          code: BackupError.requiredTableMissing,
          args: [table],
        );
      }
    }
    final normalized = <String, List<Map<String, Object?>>>{};
    for (final entry in rawTables.entries) {
      final defaults = adapter.columnDefaults[entry.key];
      if (defaults == null || defaults.isEmpty) {
        normalized[entry.key] = entry.value;
        continue;
      }
      normalized[entry.key] = [
        for (final row in entry.value)
          {
            for (final d in defaults.entries)
              if (!row.containsKey(d.key)) d.key: d.value,
            ...row,
          },
      ];
    }
    return (
      tables: normalized,
      warnings: [if (adapter.warning != null) adapter.warning!],
    );
  }
}
