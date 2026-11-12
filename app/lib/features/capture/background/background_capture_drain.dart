import 'dart:async';

import '../services/capture_retry_ledger.dart';
import '../services/native_capture_bridge.dart';

/// What a background-triggered drain ended as. The [name] goes over the
/// capture channel to the native scheduler (Android worker / iOS BGTask).
enum BackgroundDrainOutcome {
  /// The native queue is empty: nothing left to schedule.
  done,

  /// Captures remain; the next background run was requested for when the
  /// earliest of them is due (never before its retry backoff).
  pending,

  /// Another engine of this process holds the drain lease. Nothing ran here.
  busy,

  /// Not allowed to run now (no signed-in, admitted account; replica frozen;
  /// re-authentication needed). Nothing was read, sent, written or
  /// acknowledged; the next foreground drain schedules again.
  deferred,

  /// The OS cancelled the run; it stopped at an item boundary. What committed
  /// was acknowledged, nothing else was.
  cancelled,

  /// The native queue could not be read. Nothing was written or acknowledged.
  failed,
}

/// What one drain pass reported to its caller (counts and flags only).
class CaptureDrainPass {
  const CaptureDrainPass({
    this.busy = false,
    this.stopped = false,
    this.authRequired = false,
    this.readFailed = false,
    this.pendingDelay,
  });

  /// The lease was held by another engine: the drain body did not run.
  final bool busy;

  /// The drain stopped early (cancelled, owner changed, host went away).
  final bool stopped;
  final bool authRequired;
  final bool readFailed;

  /// Captures remain; the next run was requested after this delay. Null when
  /// the queue is empty (or the pass did not run).
  final Duration? pendingDelay;

  CaptureDrainPass withPending(Duration? delay) => CaptureDrainPass(
        busy: busy,
        stopped: stopped,
        authRequired: authRequired,
        readFailed: readFailed,
        pendingDelay: delay,
      );
}

/// The single process-wide drain lease, held natively (Kotlin object / Swift
/// static under a lock) so foreground and background-triggered drains of every
/// engine in the process never run concurrently: the second one skips. The
/// lease expires after [ttl], so a holder whose engine died cannot block the
/// queue forever. Idempotency (`tx.id = payloadId`, receipt in the same
/// transaction) remains the backstop if a pass ever outlives its lease.
class CaptureDrainLease {
  CaptureDrainLease({
    Future<CaptureDrainLeaseGrant> Function(String holder, Duration ttl)?
        acquire,
    Future<void> Function(String token)? release,
    this.ttl = const Duration(minutes: 10),
  })  : _acquire = acquire ??
            ((holder, ttl) => NativeCaptureBridge.acquireCaptureDrainLease(
                holder: holder, ttl: ttl)),
        _release = release ?? NativeCaptureBridge.releaseCaptureDrainLease;

  final Future<CaptureDrainLeaseGrant> Function(String holder, Duration ttl)
      _acquire;
  final Future<void> Function(String token) _release;
  final Duration ttl;

  /// Runs [body] while holding the lease; returns null (body not run) when
  /// another holder has it.
  Future<T?> runExclusive<T>(String holder, Future<T> Function() body) async {
    final grant = await _acquire(holder, ttl);
    if (grant.busy) return null;
    try {
      return await body();
    } finally {
      final token = grant.token;
      if (token != null) await _release(token);
    }
  }
}

/// The earliest moment the next drain could do anything for [queued], as a
/// delay from [now]: null when nothing is queued. Never shorter than
/// [minimumDelay] (the ledger's first backoff step), so a background run can
/// never re-trigger itself in a tight loop.
Future<Duration?> pendingCaptureDelay({
  required List<SharedCapturedMessage> queued,
  required CaptureRetryLedger ledger,
  required DateTime now,
  Duration minimumDelay = const Duration(seconds: 30),
}) async {
  if (queued.isEmpty) return null;
  DateTime? earliest;
  for (final message in queued) {
    final id = message.id?.trim();
    final due = id == null || id.isEmpty ? null : await ledger.dueAt(id);
    final at = due == null || due.isBefore(now) ? now : due;
    if (earliest == null || at.isBefore(earliest)) earliest = at;
  }
  final delay = earliest!.difference(now);
  return delay < minimumDelay ? minimumDelay : delay;
}

/// One leased drain pass, shared by the foreground triggers (cold start,
/// resume, poll, native wake-up) and the background-triggered run:
///  1. the process-wide lease (busy => nothing runs);
///  2. the retry ledger is re-read from its durable store (another engine may
///     have recorded attempts since this engine last looked);
///  3. the drain itself ([drain]);
///  4. if captures remain, the next background run is requested for when the
///     earliest is due ([schedule]); the native schedulers keep a network
///     constraint and their own backoff on top.
Future<CaptureDrainPass> runLeasedCaptureDrain({
  required CaptureDrainLease lease,
  required String holder,
  required CaptureRetryLedger ledger,
  required Future<CaptureDrainPass> Function() drain,
  Future<List<SharedCapturedMessage>> Function()? peek,
  Future<void> Function(Duration delay)? schedule,
  DateTime Function()? now,
}) async {
  final pass = await lease.runExclusive<CaptureDrainPass>(holder, () async {
    await ledger.reload();
    return drain();
  });
  if (pass == null) return const CaptureDrainPass(busy: true);
  // Re-auth needed: nothing more can happen without the user.
  if (pass.authRequired) return pass;
  Duration? delay;
  try {
    delay = await pendingCaptureDelay(
      queued: await (peek ?? NativeCaptureBridge.peekPendingSharedMessages)(),
      ledger: ledger,
      now: (now ?? DateTime.now)().toUtc(),
    );
  } catch (_) {
    // The queue could not be read: retry the read later, never sooner than
    // the first backoff step.
    delay = const Duration(seconds: 30);
  }
  if (delay != null) {
    await (schedule ?? NativeCaptureBridge.scheduleBackgroundCaptureDrain)(
        delay);
  }
  return pass.withPending(delay);
}

/// A background-triggered run: precondition, then one leased pass.
///
/// [mayRun] must apply the SAME admission checks as the foreground drain
/// (a signed-in user whose replica is the admitted active account, no replica
/// swap / removal in flight). When it says no, nothing is read, sent, written
/// or acknowledged. Consent, the egress gates and the account binding are
/// re-checked inside the drain for every message exactly as in the
/// foreground: this runner authorizes nothing by itself.
class BackgroundCaptureDrainRunner {
  BackgroundCaptureDrainRunner({
    required Future<bool> Function() mayRun,
    required Future<CaptureDrainPass> Function(bool Function() isActive) pass,
  })  : _mayRun = mayRun,
        _pass = pass;

  final Future<bool> Function() _mayRun;
  final Future<CaptureDrainPass> Function(bool Function() isActive) _pass;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// The OS withdrew the run (WorkManager stop, BGTask expiration). The drain
  /// stops before its next item; the item in flight finishes or rolls back
  /// as a unit and is acknowledged only after its commit.
  void cancel() => _cancelled = true;

  Future<BackgroundDrainOutcome> run() async {
    if (_cancelled) return BackgroundDrainOutcome.cancelled;
    if (!await _mayRun()) return BackgroundDrainOutcome.deferred;
    final pass = await _pass(() => !_cancelled);
    if (pass.busy) return BackgroundDrainOutcome.busy;
    if (pass.authRequired) return BackgroundDrainOutcome.deferred;
    if (_cancelled) return BackgroundDrainOutcome.cancelled;
    if (pass.readFailed) return BackgroundDrainOutcome.failed;
    return pass.pendingDelay == null
        ? BackgroundDrainOutcome.done
        : BackgroundDrainOutcome.pending;
  }
}
