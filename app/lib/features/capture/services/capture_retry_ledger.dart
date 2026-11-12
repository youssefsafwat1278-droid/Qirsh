import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'capture_backend_client.dart';

/// Why a capture could not be finished on a drain pass.
enum CaptureFailureKind {
  /// Something outside the message: network, server, rate limit, a result that
  /// is not observable yet. Worth retrying later.
  temporary,

  /// The local processing of this message failed. Retrying is unlikely to help.
  permanent,
}

/// The outcome of recording one failed pass.
class CaptureRetryDecision {
  const CaptureRetryDecision({
    required this.attempts,
    required this.exhausted,
    required this.kind,
    required this.nextDue,
  });

  /// Failed passes recorded for this capture so far (this one included).
  final int attempts;

  /// The automatic retry budget is spent: the caller must move the capture to
  /// its visible, recoverable state (a Smart Inbox row) instead of retrying.
  final bool exhausted;

  /// What the capture ended as when [exhausted]: [CaptureFailureKind.permanent]
  /// only when local processing itself kept failing.
  final CaptureFailureKind kind;

  /// No automatic retry before this instant.
  final DateTime nextDue;
}

/// Where the ledger keeps its (content-free) state.
abstract class CaptureRetryStore {
  Future<String?> read();
  Future<void> write(String value);

  /// Drops any cached copy so the next [read] sees writes made by another
  /// engine of this process (a background-triggered drain, a rebuilt scene).
  Future<void> reload() async {}
}

class MemoryCaptureRetryStore implements CaptureRetryStore {
  String? _value;

  @override
  Future<String?> read() async => _value;

  @override
  Future<void> write(String value) async => _value = value;

  @override
  Future<void> reload() async {}
}

class PrefsCaptureRetryStore implements CaptureRetryStore {
  const PrefsCaptureRetryStore();

  static const _key = 'capture_retry_ledger_v1';

  @override
  Future<String?> read() async =>
      (await SharedPreferences.getInstance()).getString(_key);

  @override
  Future<void> write(String value) async {
    await (await SharedPreferences.getInstance()).setString(_key, value);
  }

  /// The plugin caches every value per engine; the native store is shared by
  /// the whole process, so another engine's writes need an explicit reload.
  @override
  Future<void> reload() async {
    await (await SharedPreferences.getInstance()).reload();
  }
}

/// Bounds the automatic retries of a queued capture.
///
/// Every drain pass that neither commits nor acknowledges a capture records a
/// failure here. Retries back off exponentially (a rate-limited upload waits at
/// least an hour) and stop after [maxAttempts] passes, or after
/// [maxPermanentAttempts] local processing failures; the caller then parks the
/// capture in Smart Inbox, where the user can retry it. The ledger never
/// authorizes anything: consent and the egress gates are re-read by the retry
/// itself. It holds payload ids, counters and timestamps only — never text,
/// senders, amounts or user ids.
class CaptureRetryLedger {
  CaptureRetryLedger({CaptureRetryStore? store, DateTime Function()? now})
      : _store = store ?? MemoryCaptureRetryStore(),
        _now = now ?? DateTime.now;

  static const int maxAttempts = 8;
  static const int maxPermanentAttempts = 3;

  /// Waits after the 1st, 2nd, ... temporary failure. The last value repeats.
  static const List<Duration> temporaryBackoff = [
    Duration(seconds: 30),
    Duration(minutes: 2),
    Duration(minutes: 8),
    Duration(minutes: 30),
    Duration(hours: 2),
    Duration(hours: 6),
  ];
  static const List<Duration> permanentBackoff = [
    Duration(minutes: 1),
    Duration(minutes: 10),
    Duration(hours: 6),
  ];
  static const Duration rateLimitFloor = Duration(hours: 1);

  static const Duration _retention = Duration(days: 30);
  static const int _maxEntries = 1000;

  final CaptureRetryStore _store;
  final DateTime Function() _now;
  Map<String, _Entry>? _entries;

  /// A transport/server/rate-limit failure is temporary; anything raised by
  /// local processing is permanent.
  static CaptureFailureKind classify(Object error) =>
      error is CaptureBackendException ||
              error is TimeoutException ||
              error is SocketException ||
              error is http.ClientException
          ? CaptureFailureKind.temporary
          : CaptureFailureKind.permanent;

  /// HTTP 429 from a capture endpoint.
  static bool isRateLimited(Object error) =>
      error is CaptureBackendException && error.reason.endsWith('_429');

  static Duration backoffFor(
    int attempts, {
    CaptureFailureKind kind = CaptureFailureKind.temporary,
    bool rateLimited = false,
  }) {
    final table = kind == CaptureFailureKind.permanent
        ? permanentBackoff
        : temporaryBackoff;
    final wait = table[(attempts - 1).clamp(0, table.length - 1)];
    return rateLimited && wait < rateLimitFloor ? rateLimitFloor : wait;
  }

  Future<Map<String, _Entry>> _load() async {
    final cached = _entries;
    if (cached != null) return cached;
    final entries = <String, _Entry>{};
    try {
      final raw = await _store.read();
      final decoded = raw == null ? null : jsonDecode(raw);
      if (decoded is Map) {
        decoded.forEach((key, value) {
          final entry = _Entry.tryParse(value);
          if (key is String && entry != null) entries[key] = entry;
        });
      }
    } catch (_) {
      // An unreadable ledger only forgets retry counts; captures are untouched.
    }
    return _entries = entries;
  }

  Future<void> _save(Map<String, _Entry> entries) async {
    final cutoff = _now().subtract(_retention).millisecondsSinceEpoch;
    entries.removeWhere((_, e) => e.updatedMs < cutoff);
    if (entries.length > _maxEntries) {
      final oldest = entries.keys.toList()
        ..sort((a, b) => entries[a]!.updatedMs.compareTo(entries[b]!.updatedMs));
      for (final id in oldest.take(entries.length - _maxEntries)) {
        entries.remove(id);
      }
    }
    try {
      await _store.write(jsonEncode({
        for (final e in entries.entries) e.key: e.value.toJson(),
      }));
    } catch (_) {
      // Best-effort persistence: the in-memory state still bounds this process.
    }
  }

  /// Forgets the in-memory copy and re-reads the durable store on next use.
  /// Called at the start of every leased drain: foreground and
  /// background-triggered drains may run in different engines of one process,
  /// and each engine has its own ledger instance over the same store.
  Future<void> reload() async {
    _entries = null;
    try {
      await _store.reload();
    } catch (_) {
      // A failed reload only means the next read may be stale.
    }
  }

  /// When the next automatic retry of [payloadId] is allowed, or null when no
  /// failure is recorded for it (it may run now).
  Future<DateTime?> dueAt(String payloadId) async {
    final entry = (await _load())[payloadId];
    return entry == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(entry.dueMs, isUtc: true);
  }

  /// Whether an automatic retry of [payloadId] may run now.
  Future<bool> isDue(String payloadId) async {
    final entry = (await _load())[payloadId];
    return entry == null || _now().millisecondsSinceEpoch >= entry.dueMs;
  }

  /// Records one failed pass and schedules the next allowed retry.
  Future<CaptureRetryDecision> recordFailure(
    String payloadId,
    CaptureFailureKind kind, {
    bool rateLimited = false,
  }) async {
    final entries = await _load();
    final now = _now();
    final previous = entries[payloadId];
    final attempts = (previous?.attempts ?? 0) + 1;
    final permanent = (previous?.permanent ?? 0) +
        (kind == CaptureFailureKind.permanent ? 1 : 0);
    final permanentExhausted = permanent >= maxPermanentAttempts;
    final exhausted = permanentExhausted || attempts >= maxAttempts;
    final nextDue = now.add(
        backoffFor(attempts, kind: kind, rateLimited: rateLimited));
    entries[payloadId] = _Entry(
      attempts: attempts,
      permanent: permanent,
      dueMs: nextDue.millisecondsSinceEpoch,
      updatedMs: now.millisecondsSinceEpoch,
    );
    await _save(entries);
    return CaptureRetryDecision(
      attempts: attempts,
      exhausted: exhausted,
      kind: permanentExhausted
          ? CaptureFailureKind.permanent
          : CaptureFailureKind.temporary,
      nextDue: nextDue,
    );
  }

  /// The capture reached a durable result (or was acknowledged): forget it.
  Future<void> clear(String payloadId) async {
    final entries = await _load();
    if (entries.remove(payloadId) != null) await _save(entries);
  }
}

class _Entry {
  const _Entry({
    required this.attempts,
    required this.permanent,
    required this.dueMs,
    required this.updatedMs,
  });

  final int attempts;
  final int permanent;
  final int dueMs;
  final int updatedMs;

  static _Entry? tryParse(Object? value) {
    if (value is! List || value.length != 4) return null;
    if (value.any((v) => v is! int)) return null;
    return _Entry(
      attempts: value[0] as int,
      permanent: value[1] as int,
      dueMs: value[2] as int,
      updatedMs: value[3] as int,
    );
  }

  List<int> toJson() => [attempts, permanent, dueMs, updatedMs];
}

/// Whether an in-app AI failure reason describes a TEMPORARY condition (the
/// analysis could not run or complete), as opposed to a rejected candidate or
/// an intentional skip. Used only to label the Smart Inbox row.
bool isTemporaryAiFailure(String? reason) {
  if (reason == null) return false;
  return reason == 'ai_deferred' ||
      reason == 'unexpected_ai_error' ||
      reason == 'unknown_failure' ||
      reason == 'missing_jwt' ||
      reason.startsWith('http_408') ||
      reason.startsWith('http_429') ||
      reason.startsWith('http_5');
}
