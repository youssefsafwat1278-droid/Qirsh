import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';
import '../../data/db/replica_store.dart';
import '../../data/sync/server_capabilities.dart';
import '../../data/sync/sync_cursor.dart' show readRecordedSyncEpoch;
import '../../domain/entities/supporting_entities.dart' show UserSettingsEntity;
import '../../features/capture/services/capture_device_registration_service.dart'
    show CaptureRegistrationStatus;
import '../../features/capture/services/capture_import_service.dart'
    show CaptureImportReport;
import '../../features/capture/services/native_capture_bridge.dart'
    show
        CaptureOwnerRecord,
        CaptureQueueStats,
        CaptureRemovalBarrier,
        SharedCapturedMessage;
import 'sync_health.dart';
import '../observability/app_diagnostics.dart';
import 'sync_pull_proof.dart' show readSeqCursors;

/// WP-8 / CAP-8 — the Sync Health v2 diagnostics, built to be CONTENT-FREE BY
/// CONSTRUCTION: the only value kinds a row can carry are counts, booleans,
/// timestamps, enum names and short code words ([DiagnosticRows.add]). Free text
/// (SMS text, sender, amount, merchant, card digits, payload ids, uids, epochs,
/// error messages) has no way in: an unexpected string becomes `[redacted]`.

/// Manifest §4.5 (owner-approved change, 2026-11-12): the native queue has no
/// count or byte quota any more. A full segment file opens an encrypted
/// overflow segment; these are segment sizes, mirrored from
/// `SharedCaptureStore.segmentMaxItems` / `segmentMaxBytes` (a test pins them).
const int kCaptureSegmentMaxItems = 500;
const int kCaptureSegmentMaxBytes = 2 * 1024 * 1024;

/// The one remaining per-capture ceiling (`SharedCaptureStore.maxItemBytes`):
/// a single capture larger than a whole segment is refused, nothing is evicted.
const int kCaptureMaxItemBytes = kCaptureSegmentMaxBytes;

final RegExp _codeWord = RegExp(r'^[A-Za-z0-9_.:\-]{1,40}$');
final RegExp _opaqueId = RegExp(r'^[0-9a-fA-F-]{16,}$');

/// A closed-vocabulary code (`failure_class`, `epoch_reason`, a state word) or
/// `[redacted]`. Opaque identifiers (hex / uuid shapes) are never a code.
String safeCode(String? v) {
  if (v == null || v.isEmpty) return '—';
  if (!_codeWord.hasMatch(v) || _opaqueId.hasMatch(v)) return '[redacted]';
  return v;
}

String diagnosticTime(DateTime? t) =>
    t == null ? '—' : t.toUtc().toIso8601String();

class DiagnosticSection {
  const DiagnosticSection(this.title, this.rows);
  final String title;
  final Map<String, String> rows;
}

/// Accumulates one section's rows through the content-free value filter.
class DiagnosticRows {
  final Map<String, String> _rows = {};

  Map<String, String> get rows => Map.unmodifiable(_rows);

  /// Rows keyed by a data-derived code (a failure class, a park reason, a state
  /// word). The KEY is filtered like a value; keys that collapse to
  /// `[redacted]` are summed so nothing is dropped.
  void addCodeCounts(Map<String, int> counts, {String prefix = ''}) {
    final merged = <String, int>{};
    counts.forEach((k, v) => merged.update('$prefix${safeCode(k)}', (n) => n + v,
        ifAbsent: () => v));
    merged.forEach(add);
  }

  void add(String label, Object? value) {
    _rows[label] = switch (value) {
      null => '—',
      final bool b => b ? 'yes' : 'no',
      final int n => '$n',
      final DateTime t => diagnosticTime(t),
      final Enum e => safeCode(e.name),
      final String s => safeCode(s),
      _ => '[redacted]',
    };
  }
}

class SyncDiagnosticsReport {
  const SyncDiagnosticsReport(this.sections);

  final List<DiagnosticSection> sections;

  /// The redacted support bundle ("Copy diagnostics"): exactly what the screen
  /// shows, as text.
  String toRedactedText() {
    final b = StringBuffer('Qirsh sync diagnostics (content-free)\n');
    for (final s in sections) {
      if (s.rows.isEmpty) continue;
      b.writeln('\n[${s.title}]');
      for (final e in s.rows.entries) {
        b.writeln('${e.key}: ${e.value}');
      }
    }
    b.write(AppDiagnostics.exportText());
    return b.toString();
  }
}

/// Counts of the active owner's native queue items (CAP-6). Read from the peek
/// and discarded: only these integers survive.
class CaptureQueueCounts {
  const CaptureQueueCounts({
    this.ownerItems = 0,
    this.localOnly = 0,
    this.awaitingUpload = 0,
    this.withFailure = 0,
    this.otherOwners = 0,
  });

  final int ownerItems;

  /// Bound by an explicit claim: parsed on device only.
  final int localOnly;

  /// Durable `pendingSend` items (captured, not yet uploaded).
  final int awaitingUpload;

  /// Items carrying a failure marker from the App Intent.
  final int withFailure;

  /// Items of another owner or no owner in the peek: left in the queue.
  final int otherOwners;
}

CaptureQueueCounts summarizeCaptureQueue(
  List<SharedCapturedMessage> peek,
  String? ownerUid,
) {
  var mine = 0, localOnly = 0, awaiting = 0, failed = 0, other = 0;
  for (final m in peek) {
    if (ownerUid == null || m.ownerUid != ownerUid) {
      other++;
      continue;
    }
    mine++;
    if (m.localOnly == true) localOnly++;
    if (m.status == 'pendingSend') awaiting++;
    if (m.failureReason?.trim().isNotEmpty ?? false) failed++;
  }
  return CaptureQueueCounts(
    ownerItems: mine,
    localOnly: localOnly,
    awaitingUpload: awaiting,
    withFailure: failed,
    otherOwners: other,
  );
}

/// Everything the collector reads, as seams so a test can drive each source
/// package's state without platform channels or a network.
class SyncDiagnosticsSources {
  const SyncDiagnosticsSources({
    required this.db,
    required this.health,
    required this.settings,
    required this.authUid,
    required this.ownerUid,
    required this.cachedCapability,
    required this.otherCapabilities,
    required this.replicaEntry,
    required this.captureOwner,
    required this.peekQueue,
    required this.unboundHinted,
    required this.removalBarrier,
    required this.consentAck,
    this.mirroredConsentVersion,
    this.queueStats,
    this.registration,
    this.lastImport,
    this.captureV3Enabled = false,
    this.now,
  });

  final AppDatabase db;
  final SyncHealth health;
  final UserSettingsEntity settings;
  final String? authUid;
  final String? ownerUid;

  /// Cached answer (no probe) for a capability key.
  final ServerCapabilityState Function(String capKey) cachedCapability;

  /// Label -> state name for the older probes (exact transport, planning FX...).
  final Map<String, String> otherCapabilities;
  final Future<ReplicaEntry?> Function() replicaEntry;
  final Future<CaptureOwnerRecord?> Function() captureOwner;
  final Future<List<SharedCapturedMessage>> Function() peekQueue;
  final Future<int> Function(String uid) unboundHinted;
  final Future<CaptureRemovalBarrier?> Function() removalBarrier;
  final Future<({bool cloud, bool ai, int version})?> Function() consentAck;
  final int? mirroredConsentVersion;

  /// Native `captureQueueStats` (counts, bytes, quota state; content-free).
  /// Absent or null off iOS or when the native call fails: the rows read "—".
  final Future<CaptureQueueStats?> Function()? queueStats;
  final CaptureRegistrationStatus? registration;
  final CaptureImportReport? lastImport;
  final bool captureV3Enabled;
  final DateTime Function()? now;
}

Future<T?> _guarded<T>(Future<T> Function() f) async {
  try {
    return await f();
  } catch (_) {
    return null; // a diagnostic must never throw; the row reads "—"
  }
}

Future<Map<String, int>> _countBy(AppDatabase db, String sql) async {
  final rows = await db.customSelect(sql).get();
  return {for (final r in rows) r.read<String>('k'): r.read<int>('n')};
}

Future<int> _count(AppDatabase db, String sql, [List<Variable> v = const []]) async =>
    (await db.customSelect(sql, variables: v).getSingle()).read<int>('n');

Future<SyncDiagnosticsReport> collectSyncDiagnostics(
    SyncDiagnosticsSources s) async {
  await AppDiagnostics.refreshBackground();
  final now = (s.now ?? DateTime.now)();
  final sections = <DiagnosticSection>[];
  void section(String title, void Function(DiagnosticRows r) fill) {
    final r = DiagnosticRows();
    fill(r);
    sections.add(DiagnosticSection(title, r.rows));
  }

  final uid = s.authUid;
  final counts = await SyncHealth.queueCounts(s.db);

  // ── Identity and replica (WP-3 / WP-7) ────────────────────────────────────
  final entry = await _guarded(s.replicaEntry);
  final recorded = uid == null
      ? null
      : await _guarded(() => readRecordedSyncEpoch(s.db, uid));
  final retired = entry?.retiredAt;
  section('Identity and replica', (r) {
    r.add('session present', uid != null);
    r.add('replica owner matches session', uid != null && uid == s.ownerUid);
    r.add('replica state', entry?.state);
    r.add('replica schema version', entry?.schemaVersion);
    r.add('replica registry epoch', entry?.epoch);
    r.add('server epoch recorded', recorded != null);
    r.add('recorded epoch reason', recorded?.reason);
    r.add('rebootstrap in progress', entry?.rebootstrap != null);
    r.add('rebootstrap phase', entry?.rebootstrap?.phase.wire);
    r.add('rebootstrap reason', entry?.rebootstrap?.reason);
    r.add('rebootstrap started', entry?.rebootstrap?.startedAt);
    r.add('retired replica retained', retired != null);
    r.add(
      'retired replica days left',
      retired == null
          ? null
          : (ReplicaStore.retiredReplicaRetention.inDays -
                  now.difference(retired).inDays)
              .clamp(0, ReplicaStore.retiredReplicaRetention.inDays),
    );
  });

  // ── Consent (WP-6) ────────────────────────────────────────────────────────
  final ack = await _guarded(s.consentAck);
  final cfg = s.settings;
  section('Consent', (r) {
    r.add('cloud consent state', cfg.cloudConsentState);
    r.add('cloud consent', cfg.cloudProcessingEnabled);
    r.add('cloud consent version', cfg.cloudConsentVersion);
    r.add('cloud consent at', cfg.cloudConsentAt);
    r.add('AI consent state', cfg.aiConsentState);
    r.add('AI consent', cfg.aiConsentGranted);
    r.add('AI consent version', cfg.aiConsentVersion);
    r.add('AI consent at', cfg.aiConsentAt);
    r.add('server ack present', ack != null);
    r.add('server ack cloud', ack?.cloud);
    r.add('server ack AI', ack?.ai);
    r.add('server ack version', ack?.version);
    r.add('native mirror version (this run)', s.mirroredConsentVersion);
    r.add('device registration', s.registration?.phase);
    r.add('device registration failure', s.registration?.failureCode);
  });

  // ── Capabilities ──────────────────────────────────────────────────────────
  ServerCapabilityState cap(String k) =>
      uid == null ? ServerCapabilityState.unknown : s.cachedCapability(k);
  section('Capabilities', (r) {
    r.add('sync_seq', cap(kCapSyncSeq));
    r.add('revision_cas', cap(kCapRevisionCas));
    r.add('replica_epoch', cap(kCapReplicaEpoch));
    r.add('capture_contract_v2', cap(kCapCaptureContractV2));
    for (final e in s.otherCapabilities.entries) {
      r.add(e.key, e.value);
    }
  });

  // ── Pull: cursors, head, stop (WP-4) ──────────────────────────────────────
  final obs = s.health.pullObservation;
  final cursors = uid == null
      ? const <int>[]
      : await _guarded(() => readSeqCursors(s.db, uid)) ?? const <int>[];
  final integrity = await _guarded(() => _countBy(
          s.db,
          'SELECT reason AS k, COUNT(*) AS n FROM parked_child_rows '
          'GROUP BY reason')) ??
      const <String, int>{};
  section('Pull', (r) {
    r.add('last pull stop', obs?.stop ?? (obs == null ? null : 'none'));
    r.add('server head seq (last read)', obs?.headSeq);
    r.add('last plan at', obs?.at);
    r.add('seq cursors', cursors.length);
    r.add('seq cursor min', cursors.isEmpty ? null : cursors.reduce((a, b) => a < b ? a : b));
    r.add('seq cursor max', cursors.isEmpty ? null : cursors.reduce((a, b) => a > b ? a : b));
    r.add(
        'cursors behind head',
        obs?.headSeq == null
            ? null
            : cursors.where((c) => c < obs!.headSeq!).length);
    r.addCodeCounts(integrity, prefix: 'parked rows: ');
    r.add('quarantined (integrity)', counts.quarantined);
  });

  // ── Queue and conflicts (WP-5) ────────────────────────────────────────────
  final conflictsByKind = await _guarded(() => _countBy(
          s.db,
          'SELECT kind AS k, COUNT(*) AS n FROM sync_conflicts '
          'WHERE resolved_at IS NULL GROUP BY kind')) ??
      const <String, int>{};
  section('Queue', (r) {
    r.add('pending', counts.pending);
    r.add('parked', counts.parked);
    r.add('dead letter', counts.deadLetter);
    r.add('in flight', counts.inFlight);
    r.add('network stalled', counts.networkStalled);
    r.add('conflicts (flagged rows)', counts.conflicts);
    for (final k in const ['update', 'delete', 'tombstone', 'create']) {
      r.add('open conflicts: $k', conflictsByKind[k] ?? 0);
    }
    r.add('local rows not yet in cloud', counts.unprovenLocalRows);
    r.add('sender mappings pending', counts.senderMappingsPending);
    r.add('sender mappings failed', counts.senderMappingsFailed);
    r.add('smart inbox pending', counts.smartInboxPendingSync);
    r.add('next retry', counts.nextRetryAt);
    r.add('last local mutation', counts.lastLocalMutationAt);
  });
  section('Parked by reason', (r) => r.addCodeCounts(counts.parkedByReason));
  section('Dead letter by reason',
      (r) => r.addCodeCounts(counts.deadLetterByReason));

  // ── History per domain ────────────────────────────────────────────────────
  for (final d in SyncDomain.values) {
    final h = s.health.of(d);
    section('Domain: ${d.name}', (r) {
      r.add('last push', h.lastPushSuccessAt);
      r.add('last pull', h.lastPullSuccessAt);
      r.add('last error class', h.lastErrorClass);
      r.add('last error at', h.lastErrorAt);
      r.add('consecutive failures', h.consecutiveFailures);
    });
  }

  // ── Capture (CAP-5 / CAP-6 / CAP-7) ───────────────────────────────────────
  final owner = await _guarded(s.captureOwner);
  final queue = owner == null
      ? const CaptureQueueCounts()
      : summarizeCaptureQueue(
          await _guarded(s.peekQueue) ?? const <SharedCapturedMessage>[],
          owner.uid);
  final unbound = owner == null
      ? null
      : await _guarded(() => s.unboundHinted(owner.uid));
  final stats = await _guarded(() async => await s.queueStats?.call());
  final barrier = await _guarded(s.removalBarrier);
  final receipts = await _guarded(() => _count(s.db,
          'SELECT COUNT(*) AS n FROM dedup_hashes WHERE hash LIKE ?',
          [Variable.withString('capture_payload:%')])) ??
      0;
  final alerts = await _guarded(() => _countBy(
          s.db,
          'SELECT transaction_id AS k, COUNT(*) AS n FROM dedup_hashes '
          "WHERE hash LIKE 'capture_notified:%' GROUP BY transaction_id")) ??
      const <String, int>{};
  final last = s.lastImport;
  section('Capture', (r) {
    r.add('capture import v3 enabled', s.captureV3Enabled);
    r.add('native owner published', owner != null);
    r.add('native owner matches session', owner != null && owner.uid == uid);
    r.add('queue items (this owner)', queue.ownerItems);
    r.add('queue items bound local-only', queue.localOnly);
    r.add('queue items awaiting upload', queue.awaitingUpload);
    r.add('queue items with failure marker', queue.withFailure);
    r.add('queue items of other owners/unbound (peek)', queue.otherOwners);
    r.add('unbound items hinted to this user', unbound);
    // Native queue statistics: counts, bytes and quota state only (§4.5).
    r.add('queue stats available', stats != null);
    r.add('queue stats: stamped, may upload', stats?.stamped);
    r.add('queue stats: local-only', stats?.localOnly);
    r.add('queue stats: waiting (other owners)', stats?.waiting);
    r.add('queue stats: unbound', stats?.unbound);
    r.add('queue stats: v2 migration pending', stats?.migrationPending);
    r.add('queue stats: quarantined segments', stats?.quarantinedSegments);
    r.add('queue bytes (this owner)', stats?.activeOwnerBytes);
    r.add('queue bytes (unbound)', stats?.unboundBytes);
    r.add('queue bytes (device)', stats?.deviceBytes);
    r.add('queue quota (this owner)', stats?.ownerQuota);
    r.add('queue quota (unbound)', stats?.unboundQuota);
    r.add('queue quota (device)', stats?.deviceQuota);
    r.add('queue segment size items', kCaptureSegmentMaxItems);
    r.add('queue segment size bytes', kCaptureSegmentMaxBytes);
    r.add('queue limit bytes (single capture)', kCaptureMaxItemBytes);
    r.add('removal barrier active', barrier != null);
    r.add('removal barrier started', barrier == null ? null : DateTime.tryParse(barrier.startedAt));
    r.add('receipts in replica', receipts);
  });
  section('Capture import (latest run)', (r) {
    r.add('run recorded', last != null);
    r.add('imported (total)', last?.imported.length);
    for (final path in const ['alreadyImported', 'server', 'local']) {
      r.add('imported: $path',
          last?.imported.where((i) => i.path.name == path).length);
    }
    r.add('left for retry', last?.skippedAwaiting);
    r.add('skipped other owner', last?.skippedForeignOwner);
    r.add('ownership guard failed', last?.guardFailed);
    r.add('rebootstrap barrier held', last?.barrierHeld);
  });
  section('Capture alerts', (r) {
    r.addCodeCounts(alerts, prefix: 'alert state: ');
    r.add('alerts recorded', alerts.values.fold<int>(0, (a, b) => a + b));
  });

  final recent = AppDiagnostics.events.reversed.take(12).toList();
  if (recent.isNotEmpty) {
    sections.add(DiagnosticSection('Recent application events (local)', {
      for (var i = 0; i < recent.length; i++)
        '${i + 1}. ${recent[i].operation.name}':
            '${recent[i].state.name} / ${recent[i].reason.name}',
    }));
  }
  return SyncDiagnosticsReport(sections);
}
