import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthException, PostgrestException;

import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/sync/seq_pull.dart' show SyncPullStop;
import '../session/unsynced_inventory.dart'
    show countUnprovenFinancialRows, countUnresolvedConflicts;
import '../di/app_providers.dart' show appDatabaseProvider;
import 'outbox_failure.dart';
import '../observability/app_diagnostics.dart';

/// Every independently-synced data domain.
enum SyncDomain {
  ledger,
  planning,
  accounts,
  children,
  senderMappings,
  smartInbox,
  engagement,
}

enum SyncDirection { push, pull }

/// Coarse failure class. Deliberately a closed enum with NO message payload:
/// raw error text can carry user data (amounts, merchant names, emails), so it
/// must never be stored or surfaced.
enum SyncErrorClass {
  offline,
  auth,

  /// Cloud consent is off — a STATE, not a failure.
  consentBlocked,

  /// Held durably until an exact-transport capability is verified — a STATE.
  capabilityParked,
  serverRejected,
  conflict,
  unknown;

  /// States that resolve on their own (consent granted / capability verified)
  /// and therefore do not count as failures.
  bool get isBlockedState =>
      this == consentBlocked || this == capabilityParked;

  /// Coarse classification that NEVER reads or retains the error message.
  static SyncErrorClass classify(Object error) {
    if (error is SocketException ||
        error is HttpException ||
        error is TimeoutException) {
      return offline;
    }
    if (error is AuthException) return auth;
    if (error is PostgrestException) {
      switch (classifyOutboxError(error)) {
        case OutboxFailureClass.auth:
          return auth;
        case OutboxFailureClass.conflict:
          return conflict;
        case OutboxFailureClass.transientNetwork:
          return offline;
        case OutboxFailureClass.accountFenceContention:
        case OutboxFailureClass.accountDeletionPending:
        case OutboxFailureClass.rateLimit:
        case OutboxFailureClass.serverError:
        case OutboxFailureClass.permanentValidation:
        case OutboxFailureClass.unsupportedSchema:
        case OutboxFailureClass.corruptedPayload:
        case OutboxFailureClass.duplicateBusinessKey:
        case OutboxFailureClass.serverSchemaMismatch:
        case OutboxFailureClass.serverCheckViolation:
        case OutboxFailureClass.permissionDenied:
          return serverRejected;
        case OutboxFailureClass.missingDependency:
          return unknown;
      }
    }
    return unknown;
  }
}

/// WP-8: what the sequence-pull gate last decided. Enum code, a count and a
/// timestamp only.
class SyncPullObservation {
  const SyncPullObservation({this.stop, this.headSeq, required this.at});

  /// Why the last plan stopped, null when it did not.
  final SyncPullStop? stop;

  /// The server `last_seq` read for that plan (null: none read).
  final int? headSeq;
  final DateTime at;
}

/// Immutable per-domain snapshot.
class SyncDomainHealth {
  const SyncDomainHealth({
    this.lastPushSuccessAt,
    this.lastPullSuccessAt,
    this.lastErrorAt,
    this.lastErrorClass,
    this.consecutiveFailures = 0,
  });

  final DateTime? lastPushSuccessAt;
  final DateTime? lastPullSuccessAt;
  final DateTime? lastErrorAt;
  final SyncErrorClass? lastErrorClass;
  final int consecutiveFailures;

  Map<String, dynamic> toJson() => {
        if (lastPushSuccessAt != null)
          'push': lastPushSuccessAt!.toUtc().toIso8601String(),
        if (lastPullSuccessAt != null)
          'pull': lastPullSuccessAt!.toUtc().toIso8601String(),
        if (lastErrorAt != null)
          'errAt': lastErrorAt!.toUtc().toIso8601String(),
        if (lastErrorClass != null) 'errClass': lastErrorClass!.name,
        'fails': consecutiveFailures,
      };

  static SyncDomainHealth fromJson(Map<String, dynamic> j) {
    DateTime? t(Object? v) => v is String ? DateTime.tryParse(v) : null;
    SyncErrorClass? c;
    final name = j['errClass'];
    for (final v in SyncErrorClass.values) {
      if (v.name == name) c = v;
    }
    return SyncDomainHealth(
      lastPushSuccessAt: t(j['push']),
      lastPullSuccessAt: t(j['pull']),
      lastErrorAt: t(j['errAt']),
      lastErrorClass: c,
      consecutiveFailures: (j['fails'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Outbox/queue depth, for the health surface. Counts only — no payloads.
class SyncQueueCounts {
  const SyncQueueCounts({
    this.pending = 0,
    this.parked = 0,
    this.deadLetter = 0,
    this.parkedByReason = const {},
    this.senderMappingsPending = 0,
    this.senderMappingsFailed = 0,
    this.smartInboxPendingSync = 0,
    this.deadLetterByReason = const {},
    this.inFlight = 0,
    this.senderMappingsPermanentFailed = 0,
    this.lastLocalMutationAt,
    this.nextRetryAt,
    this.conflicts = 0,
    this.unprovenLocalRows = 0,
    this.networkStalled = 0,
    this.quarantined = 0,
  });

  /// WP-4 §4.11: pulled rows parked for an identity-integrity error
  /// (`parked_child_rows.reason = 'integrity'`). Needs the user's attention.
  final int quarantined;

  /// D-5: entities in `sync_status = 'conflict'` — a two-device collision the
  /// user must resolve. Counted as needing attention, never "all synced".
  final int conflicts;

  /// D-5: server-less local rows (no `server_id`, not on an outbox, not
  /// deleted/ignored) still awaiting backfill — local-only until uploaded.
  final int unprovenLocalRows;

  /// Pending outbox rows whose last push failed with a transient NETWORK error
  /// (`failure_class = transientNetwork`): the app is effectively offline for
  /// them, whatever the run state says.
  final int networkStalled;

  /// Ledger + planning outbox rows awaiting push.
  final int pending;

  /// Ledger + planning rows held durably: an unverified transport, a foreign /
  /// unverified owner (`owner_mismatch`, `owner_unverified`) or a missing
  /// dependency (`dependency_wait`). Always the SUM of [parkedByReason].
  final int parked;

  /// A-2: [parked] broken down by park reason (the row's `failure_class`).
  final Map<String, int> parkedByReason;

  /// Ledger + planning rows that exhausted retries / failed permanently.
  final int deadLetter;
  final int senderMappingsPending;
  final int senderMappingsFailed;
  final int smartInboxPendingSync;

  /// A-5: [deadLetter] broken down by reason (`failure_class`; an
  /// `unsupported_operation` row is keyed by that name). Always sums to
  /// [deadLetter].
  final Map<String, int> deadLetterByReason;

  /// A-5: outbox rows carrying the durable "possibly sent" marker
  /// (`in_flight_seq`) — a push of them has started and is not yet ACKed.
  final int inFlight;

  /// A-5: sender mappings that failed terminally (`sync_permanent = 1`) and need
  /// attention; a subset of [senderMappingsFailed].
  final int senderMappingsPermanentFailed;

  /// A-5: the newest `created_at` / `updated_at` across both outboxes — the
  /// cheap "last local mutation enqueued" signal. Null when no outbox row exists.
  final DateTime? lastLocalMutationAt;

  /// A-5: the earliest scheduled retry of a pending outbox row, if any.
  final DateTime? nextRetryAt;
}

/// The real ledger supplies only its original verified lifetime implementation.
abstract interface class SyncPhaseLifecycle {
  bool get isCurrent;
  AppDatabase get database;
  Future<T> runLocal<T>(Future<T> Function() action);
}

/// One invocation, once-bound. An unbound real phase never uses legacy saves.
class SyncPhaseBinding {
  SyncPhaseLifecycle? _lifecycle;
  bool _bound = false;
  _PhaseNotes? _notes;
  SyncDomain? _domain;
  AppDatabase? _database;

  bool get isBound => _bound;
  bool get isCurrent => _lifecycle?.isCurrent == true;
  AppDatabase? get database => _lifecycle?.database;

  Future<T> runLocal<T>(Future<T> Function() action) {
    final lifecycle = _lifecycle;
    if (lifecycle == null) {
      throw const LedgerDeliveryStopped(LedgerDeliveryStopReason.unbound);
    }
    return lifecycle.runLocal(action);
  }

  SyncPhaseBinding forNextPhase() {
    final next = SyncPhaseBinding();
    final lifecycle = _lifecycle;
    if (lifecycle != null) next.bind(lifecycle);
    return next;
  }

  void bind(SyncPhaseLifecycle lifecycle) {
    if (_bound) throw StateError('sync_phase_already_bound');
    _bound = true;
    _lifecycle = lifecycle;
  }

  void noteConsentBlocked(SyncHealth? health) => health?._boundNote(this,
      (notes) => notes.consentBlocked = true);
  void noteCapabilityParked(SyncHealth? health) => health?._boundNote(this,
      (notes) => notes.capabilityParked = true);
  void noteFailure(SyncHealth? health, Object error) => health?._boundNote(this,
      (notes) => notes.failure ??= SyncErrorClass.classify(error));
}

/// Durable, lightweight per-domain sync health.
///
/// Persistence pattern: one `sync_cursors` row per domain, keyed
/// `sync_health:<domain>`, with the JSON snapshot in `last_id`. That table is
/// the app's existing device-local key-value store for sync state: it is
/// wiped on sign-out, excluded from backups and from the financial-revision
/// signal, and needs no schema change.
///
/// Orchestrators wrap each phase in [runPhase]; services that swallow errors or
/// refuse on consent report through [noteConsentBlocked] / [noteFailure] /
/// [noteCapabilityParked] so the enclosing phase records ONE accurate state.
class SyncHealth {
  SyncHealth({DateTime Function()? clock, AppDatabase? db})
      : _clock = clock ?? DateTime.now,
        _db = db;

  /// Process-wide instance used by providers and by non-Riverpod construction
  /// sites (the bootstrap sender-mapping sync). Persists once [attach]ed.
  static final SyncHealth shared = SyncHealth();

  static const _keyPrefix = 'sync_health:';

  final DateTime Function() _clock;
  AppDatabase? _db;
  final Map<SyncDomain, SyncDomainHealth> _state = {};
  final Map<SyncDomain, _PhaseNotes> _notes = {};

  final Map<String, String> _capabilityStates = {};
  SyncPullObservation? _pullObservation;

  /// Latest observed capability states (label -> state name), in memory only.
  /// Written by capability probes; read by the diagnostics screen.
  Map<String, String> get capabilityStates =>
      Map.unmodifiable(_capabilityStates);

  void recordCapability(String label, String state) =>
      _capabilityStates[label] = state;

  /// WP-8: the latest sequence-pull plan the gate made (in memory only).
  SyncPullObservation? get pullObservation => _pullObservation;

  void recordPullPlan({SyncPullStop? stop, int? headSeq}) =>
      _pullObservation = SyncPullObservation(
        stop: stop,
        headSeq: headSeq,
        at: _clock(),
      );

  SyncDomainHealth of(SyncDomain d) => _state[d] ?? const SyncDomainHealth();

  Map<SyncDomain, SyncDomainHealth> get all => {
        for (final d in SyncDomain.values) d: of(d),
      };

  /// Binds the persistence target and loads persisted state. Domains already
  /// touched in this process win over the persisted copy.
  Future<void> attach(AppDatabase db) async {
    if (identical(_db, db)) return;
    // WP-3b: another account's database means another account's health. Nothing
    // observed under the previous one carries over (an in-memory state would
    // otherwise be persisted into, and shown for, the next account).
    if (_db != null) {
      _state.clear();
      _notes.clear();
      _capabilityStates.clear();
      _pullObservation = null;
    }
    _db = db;
    try {
      final rows = await db
          .customSelect('SELECT entity, last_id FROM sync_cursors '
              "WHERE entity LIKE 'sync_health:%';")
          .get();
      if (!identical(_db, db)) return;
      for (final row in rows) {
        final name = row.read<String>('entity').substring(_keyPrefix.length);
        for (final d in SyncDomain.values) {
          if (d.name != name || _state.containsKey(d)) continue;
          final json = jsonDecode(row.read<String>('last_id')) as Map;
          _state[d] = SyncDomainHealth.fromJson(json.cast<String, dynamic>());
        }
      }
    } catch (_) {
      // Health is diagnostic — a corrupt/unavailable store must never break sync.
    }
  }

  // --- services report into the enclosing phase -----------------------------

  void noteConsentBlocked(SyncDomain d) => _note(d).consentBlocked = true;

  /// Records a consent-blocked STATE for an egress that runs outside any sync
  /// phase (e.g. a user-triggered repair). Same one-state semantics as a phase
  /// that ended consent-blocked: re-entering it does not bump failures.
  void recordConsentBlocked(SyncDomain d) =>
      _recordBlocked(d, SyncErrorClass.consentBlocked);

  /// Records a capability-parked STATE for work held outside any sync phase
  /// (e.g. a startup backfill skipped until a server capability is verified).
  void recordCapabilityParked(SyncDomain d) =>
      _recordBlocked(d, SyncErrorClass.capabilityParked);

  void noteCapabilityParked(SyncDomain d) => _note(d).capabilityParked = true;

  /// Records that a swallowed error happened inside the phase. Only the coarse
  /// class is kept — never the error or its message.
  void noteFailure(SyncDomain d, Object error) =>
      _note(d).failure ??= SyncErrorClass.classify(error);

  _PhaseNotes _note(SyncDomain d) => _notes.putIfAbsent(d, _PhaseNotes.new);

  void _boundNote(SyncPhaseBinding binding, void Function(_PhaseNotes) note) {
    final notes = binding._notes;
    final lifecycle = binding._lifecycle;
    if (notes != null && lifecycle != null && lifecycle.isCurrent &&
        identical(_db, binding._database) &&
        identical(_notes[binding._domain], notes)) {
      note(notes);
    }
  }

  Future<void> _recordBound(SyncPhaseBinding binding, SyncDomain domain,
      void Function() record) async {
    final lifecycle = binding._lifecycle;
    if (lifecycle == null || !lifecycle.isCurrent ||
        !identical(_db, binding._database) ||
        !identical(lifecycle.database, binding._database) ||
        !identical(_notes[domain], binding._notes)) {
      return;
    }
    await lifecycle.runLocal(() async {
      if (!identical(_db, binding._database) ||
          !identical(_notes[domain], binding._notes)) {
        return;
      }
      record();
      final snapshot = jsonEncode(of(domain).toJson());
      await _saveSnapshot(binding._database!, domain, snapshot);
    });
  }

  // --- orchestrators --------------------------------------------------------

  /// Runs [body] as one sync phase and records its outcome:
  /// thrown error -> failure (rethrown only when [rethrowErrors]);
  /// consent denied -> consentBlocked; a swallowed failure noted by the service
  /// -> failure; parked -> capabilityParked; otherwise success.
  Future<T?> runPhase<T>(
    SyncDomain domain,
    SyncDirection direction,
    Future<T> Function() body, {
    bool rethrowErrors = false,
    SyncPhaseBinding? binding,
  }) async {
    final ownNotes = _PhaseNotes();
    _notes[domain] = ownNotes;
    if (binding != null) {
      binding._notes = ownNotes;
      binding._domain = domain;
      binding._database = _db;
    }
    try {
      final result = await body();
      void record({required bool save}) {
        if (ownNotes.consentBlocked) {
          _recordBlocked(domain, SyncErrorClass.consentBlocked, save: save);
        } else if (ownNotes.failure != null) {
          _recordFailure(domain, ownNotes.failure!, save: save);
        } else if (ownNotes.capabilityParked) {
          _recordBlocked(domain, SyncErrorClass.capabilityParked, save: save);
        } else {
          _recordSuccess(domain, direction, save: save);
        }
      }

      if (binding != null) {
        await _recordBound(binding, domain, () => record(save: false));
      } else if (identical(_notes[domain], ownNotes)) {
        record(save: true);
      }
      return result;
    } catch (e) {
      if (e is! AccountFenceDeliveryCancellation) {
        if (binding != null) {
          await _recordBound(binding, domain, () =>
              _recordFailure(domain, SyncErrorClass.classify(e), save: false));
        } else if (identical(_notes[domain], ownNotes)) {
          recordFailure(domain, e);
        }
      }
      if (rethrowErrors) rethrow;
      return null;
    } finally {
      if (identical(_notes[domain], ownNotes)) _notes.remove(domain);
    }
  }

  void recordFailure(SyncDomain d, Object error) =>
      _recordFailure(d, SyncErrorClass.classify(error));

  static AppOperation _diagnosticDomain(SyncDomain domain) => switch (domain) {
        SyncDomain.ledger => AppOperation.syncLedger,
        SyncDomain.planning => AppOperation.syncPlanning,
        SyncDomain.accounts => AppOperation.syncAccounts,
        SyncDomain.children => AppOperation.syncChildren,
        SyncDomain.senderMappings => AppOperation.syncMappings,
        SyncDomain.smartInbox => AppOperation.syncInbox,
        SyncDomain.engagement => AppOperation.syncEngagement,
      };

  void _recordSuccess(SyncDomain d, SyncDirection dir, {bool save = true}) {
    AppDiagnostics.record(_diagnosticDomain(d), AppEventState.succeeded);
    final s = of(d);
    final now = _clock();
    final clearState = s.lastErrorClass?.isBlockedState ?? false;
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: dir == SyncDirection.push ? now : s.lastPushSuccessAt,
      lastPullSuccessAt: dir == SyncDirection.pull ? now : s.lastPullSuccessAt,
      lastErrorAt: clearState ? null : s.lastErrorAt,
      lastErrorClass: clearState ? null : s.lastErrorClass,
      consecutiveFailures: 0,
    );
    if (save) _save(d);
  }

  void _recordFailure(SyncDomain d, SyncErrorClass c, {bool save = true}) {
    AppDiagnostics.record(_diagnosticDomain(d), AppEventState.failed,
        reason: c == SyncErrorClass.offline
            ? AppEventReason.offline
            : c == SyncErrorClass.conflict
                ? AppEventReason.conflict
                : c == SyncErrorClass.auth
                    ? AppEventReason.authMissing
                    : AppEventReason.server);
    final s = of(d);
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: s.lastPushSuccessAt,
      lastPullSuccessAt: s.lastPullSuccessAt,
      lastErrorAt: _clock(),
      lastErrorClass: c,
      consecutiveFailures: s.consecutiveFailures + 1,
    );
    if (save) _save(d);
  }

  /// A blocked state is ONE state: re-entering it repeatedly neither bumps the
  /// failure counter nor rewrites the timestamp.
  void _recordBlocked(SyncDomain d, SyncErrorClass c, {bool save = true}) {
    final s = of(d);
    if (s.lastErrorClass == c) return;
    AppDiagnostics.record(_diagnosticDomain(d), AppEventState.blocked,
        reason: c == SyncErrorClass.consentBlocked
            ? AppEventReason.consentOff
            : AppEventReason.capability);
    _state[d] = SyncDomainHealth(
      lastPushSuccessAt: s.lastPushSuccessAt,
      lastPullSuccessAt: s.lastPullSuccessAt,
      lastErrorAt: _clock(),
      lastErrorClass: c,
      consecutiveFailures: s.consecutiveFailures,
    );
    if (save) _save(d);
  }

  void _save(SyncDomain d) {
    final db = _db;
    if (db == null) return;
    unawaited(_saveSnapshot(db, d, jsonEncode(of(d).toJson())));
  }

  Future<void> _saveSnapshot(AppDatabase db, SyncDomain d, String snapshot) async {
    try {
      await db.customStatement(
        'INSERT INTO sync_cursors(entity, last_updated_at, last_id) VALUES ('
        '${sqlString('$_keyPrefix${d.name}')}, '
        '${sqlString(_clock().toUtc().toIso8601String())}, '
        '${sqlString(snapshot)}) '
        'ON CONFLICT(entity) DO UPDATE SET '
        'last_updated_at = excluded.last_updated_at, '
        'last_id = excluded.last_id;',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('[SyncHealth] persist failed: ${e.runtimeType}');
    }
  }

  /// Outbox depth for the health surface. Raw counts only.
  static Future<SyncQueueCounts> queueCounts(AppDatabase db) async {
    Future<int> n(String sql) async =>
        (await db.customSelect(sql).getSingle()).read<int>('n');
    Future<int> outbox(String status) async =>
        await n("SELECT COUNT(*) AS n FROM ledger_sync_outbox "
            "WHERE status = '$status'") +
        await n("SELECT COUNT(*) AS n FROM planning_sync_outbox "
            "WHERE status = '$status'");
    final parkedByReason = <String, int>{};
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      final rows = await db.customSelect(
        "SELECT COALESCE(failure_class, 'unknown') AS reason, COUNT(*) AS n "
        "FROM $table WHERE status = 'parked' GROUP BY reason",
      ).get();
      for (final r in rows) {
        parkedByReason.update(
          r.read<String>('reason'),
          (v) => v + r.read<int>('n'),
          ifAbsent: () => r.read<int>('n'),
        );
      }
    }
    final deadLetterByReason = <String, int>{};
    var inFlight = 0;
    String? lastMutation;
    String? nextRetry;
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      final rows = await db.customSelect(
        "SELECT CASE WHEN last_error LIKE '$kFailUnsupportedOperation%' "
        "THEN '$kFailUnsupportedOperation' "
        "ELSE COALESCE(failure_class, 'unknown') END AS reason, "
        "COUNT(*) AS n FROM $table WHERE status = 'dead_letter' "
        'GROUP BY reason',
      ).get();
      for (final r in rows) {
        deadLetterByReason.update(
          r.read<String>('reason'),
          (v) => v + r.read<int>('n'),
          ifAbsent: () => r.read<int>('n'),
        );
      }
      final agg = await db.customSelect(
        'SELECT MAX(MAX(created_at, updated_at)) AS m, '
        "MIN(CASE WHEN status = 'pending' THEN next_retry_at END) AS r, "
        'SUM(CASE WHEN in_flight_seq IS NOT NULL THEN 1 ELSE 0 END) AS f '
        'FROM $table',
      ).getSingle();
      final m = agg.readNullable<String>('m');
      if (m != null && (lastMutation == null || m.compareTo(lastMutation) > 0)) {
        lastMutation = m;
      }
      final r = agg.readNullable<String>('r');
      if (r != null && (nextRetry == null || r.compareTo(nextRetry) < 0)) {
        nextRetry = r;
      }
      inFlight += agg.readNullable<int>('f') ?? 0;
    }
    var networkStalled = 0;
    for (final table in const ['ledger_sync_outbox', 'planning_sync_outbox']) {
      networkStalled += await n("SELECT COUNT(*) AS n FROM $table "
          "WHERE status = 'pending' AND failure_class = 'transientNetwork'");
    }
    return SyncQueueCounts(
      quarantined: await n('SELECT COUNT(*) AS n FROM parked_child_rows '
          "WHERE reason = 'integrity'"),
      networkStalled: networkStalled,
      conflicts: await countUnresolvedConflicts(db),
      unprovenLocalRows:
          await countUnprovenFinancialRows(db, excludeIgnored: true),
      deadLetterByReason: deadLetterByReason,
      inFlight: inFlight,
      lastLocalMutationAt:
          lastMutation == null ? null : DateTime.tryParse(lastMutation),
      nextRetryAt: nextRetry == null ? null : DateTime.tryParse(nextRetry),
      senderMappingsPermanentFailed: await n('SELECT COUNT(*) AS n FROM '
          "sender_bank_mappings WHERE sync_status = 'failed' "
          'AND sync_permanent = 1'),
      pending: await outbox('pending'),
      parked: parkedByReason.values.fold<int>(0, (a, b) => a + b),
      parkedByReason: parkedByReason,
      deadLetter: await outbox('dead_letter'),
      senderMappingsPending: await n("SELECT COUNT(*) AS n FROM "
          "sender_bank_mappings WHERE sync_status = 'pending'"),
      senderMappingsFailed: await n("SELECT COUNT(*) AS n FROM "
          "sender_bank_mappings WHERE sync_status = 'failed'"),
      smartInboxPendingSync: await n(
          'SELECT COUNT(*) AS n FROM smart_inbox_items WHERE pending_sync = 1'),
    );
  }
}

class _PhaseNotes {
  bool consentBlocked = false;
  bool capabilityParked = false;
  SyncErrorClass? failure;
}

final syncHealthProvider = Provider<SyncHealth>((ref) {
  final health = SyncHealth.shared;
  unawaited(health.attach(ref.watch(appDatabaseProvider)));
  return health;
});
