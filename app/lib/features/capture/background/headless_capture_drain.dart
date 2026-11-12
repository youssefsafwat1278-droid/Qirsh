import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/observability/diagnostics.dart';
import '../../../core/session/app_session.dart';
import '../../../core/session/rebootstrap_service.dart';
import '../../../core/startup/account_scope_overrides.dart';
import '../../../core/startup/bootstrap_runner.dart';
import '../../../core/startup/install_presentation_store.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/entities/transaction_entity.dart';
import '../../../domain/errors/repo_exceptions.dart';
import '../services/capture_identity_metrics.dart';
import '../services/capture_import_service.dart';
import '../services/capture_notification_authority.dart';
import '../services/captured_message_processor.dart';
import '../services/local_notification_service.dart';
import 'background_capture_drain.dart';
import 'capture_alerts.dart';

/// The cold-start background capture drain: what a HEADLESS engine runs when
/// the OS scheduler (Android WorkManager worker, iOS BGTask) fires and no live
/// engine exists (process killed, after reboot, iOS background launch).
///
///  1. [BootstrapRunner.runHeadless]: the launch steps minus UI/interaction;
///     it creates the database coordinator only when none is registered and
///     yields to a foreground bootstrap (the foreground always wins);
///  2. a provider container over the admitted writable scope, built from the
///     SAME providers and overrides as the foreground graph;
///  3. ONE leased pass of the SAME drain the foreground runs
///     ([runLeasedCaptureDrain] -> `LegacyCaptureDrain.run`, or the v3 import
///     on iOS): process-wide lease, retry ledger reloaded under it, per-item
///     owner check, consent re-read before every AI request, tx.id = payloadId
///     with the receipt in the same transaction, ack only after commit;
///  4. teardown: container disposed, database closed, coordinator released.
///
/// Content-free diagnostics only (outcome / reason codes, counts).
class HeadlessCaptureDrain {
  HeadlessCaptureDrain({
    BootstrapRunner? runner,
    CaptureDrainLease? lease,
    Future<bool> Function()? prepareInstallPresentation,
    @visibleForTesting this.overrides = const [],
  })  : runner = runner ?? BootstrapRunner(),
        _lease = lease ?? CaptureDrainLease(),
        _prepareInstall =
            prepareInstallPresentation ?? _readInstallPresentation;

  final Future<bool> Function() _prepareInstall;

  /// The install presentation is READ, never prepared or reset here: a fresh
  /// install (or one with a reset outstanding) does nothing in background.
  static Future<bool> _readInstallPresentation() async {
    final support = await getApplicationSupportDirectory();
    final store = InstallPresentationStore(
        File('${support.path}/qirsh_install_presentation_v1.json'));
    if (!await store.loadCompletedReadOnly()) return false;
    AppSession.instance.configureInstallPresentation(store);
    return true;
  }

  final BootstrapRunner runner;
  final CaptureDrainLease _lease;

  /// Test seam: extra overrides layered over the account-scope ones.
  final List<Override> overrides;

  BackgroundCaptureDrainRunner? _drain;
  bool _cancelled = false;
  bool _started = false;

  /// Whether the coordinator was released at the end of [run] (false while it
  /// runs, or when a holder could not be confirmed closed).
  bool released = false;

  /// The OS withdrew the run: stop before the next step / item.
  void cancel() {
    _cancelled = true;
    runner.requestHeadlessStop();
    _drain?.cancel();
  }

  bool get _stopRequested => _cancelled || runner.headlessStopRequested;

  Future<BackgroundDrainOutcome> run() async {
    if (_started) return BackgroundDrainOutcome.busy;
    _started = true;
    var outcome = BackgroundDrainOutcome.failed;
    try {
      outcome = await _run();
    } catch (error) {
      Diag.log('[CaptureBg]', 'headless_error type=${error.runtimeType}');
      outcome = BackgroundDrainOutcome.failed;
    } finally {
      released = await runner.releaseHeadless();
      Diag.log('[CaptureBg]',
          'headless_end outcome=${outcome.name} released=$released');
    }
    return outcome;
  }

  Future<BackgroundDrainOutcome> _run() async {
    Diag.log('[CaptureBg]', 'headless_start');
    if (!await _prepareInstall()) {
      Diag.log('[CaptureBg]', 'headless_no_work reason=install_setup');
      return BackgroundDrainOutcome.deferred;
    }
    final boot = await runner.runHeadless();
    if (!boot.ready) {
      Diag.log('[CaptureBg]', 'headless_no_work reason=${boot.noWork}');
      // Held coordinator, or keys unreadable (before first unlock): retry.
      if (boot.busy || boot.noWork == 'protected_data') {
        return BackgroundDrainOutcome.busy;
      }
      if (boot.noWork == 'stopped') return BackgroundDrainOutcome.cancelled;
      return BackgroundDrainOutcome.deferred;
    }
    final scope = boot.scope!;
    final host = runner.accountScope;
    final authority = AppSession.instance.captureLocalWorkAuthority();
    bool admitted() =>
        authority != null &&
        authority.isCurrent &&
        identical(host.current, scope) &&
        AppSession.instance.status == SessionStatus.authenticated &&
        !ReplicaFreeze.instance.frozen;
    final container = ProviderContainer(overrides: [
      ...accountScopeProviderOverrides(scope, host),
      ...overrides,
    ]);
    try {
      final drain = _drain = BackgroundCaptureDrainRunner(
        mayRun: () async => admitted() && !_stopRequested,
        pass: (isActive) => runLeasedCaptureDrain(
          lease: _lease,
          holder: 'headless',
          ledger: container.read(captureRetryLedgerProvider),
          drain: () => runHeadlessCapturePass(
            container,
            isActive: () => isActive() && !_stopRequested && admitted(),
          ),
        ),
      );
      if (_cancelled) drain.cancel();
      final outcome = await drain.run();
      // A foreground yield is a cancellation too: the foreground drains next.
      return outcome == BackgroundDrainOutcome.done ||
              outcome == BackgroundDrainOutcome.pending
          ? (_stopRequested ? BackgroundDrainOutcome.cancelled : outcome)
          : outcome;
    } finally {
      _drain = null;
      container.dispose();
    }
  }
}

/// One drain pass over [container]: the foreground shell's leased body
/// (`AppShell._consumeSharedInputLeased`) without its UI. An auth failure is
/// REPORTED (deferred), never acted on: no session transition in background.
Future<CaptureDrainPass> runHeadlessCapturePass(
  ProviderContainer container, {
  required bool Function() isActive,
}) async {
  // §4.7: queue hygiene after adoption; independent of the import flag.
  try {
    await container.read(legacyCaptureResolverProvider).resolve();
  } catch (_) {}
  final database = container.read(appDatabaseProvider);
  final preferences =
      await container.read(loadNotificationPreferencesUseCaseProvider).call();
  if (_flagOn('capture_import_v3') && Platform.isIOS) {
    final CaptureImportReport report;
    try {
      report = await container.read(captureImportServiceProvider).run();
    } on AuthRepoException {
      return const CaptureDrainPass(authRequired: true);
    }
    final notifyV2 = _flagOn('capture_notify_v2');
    for (final item in report.imported) {
      if (item.path == CaptureImportPath.alreadyImported) continue;
      await CaptureIdentityMetrics.record(
          database, item.message?.receivedAtInferred);
      final local = item.local;
      if (local != null &&
          !notifyV2 &&
          CaptureNotificationAuthority.shouldShowLocalReview(
            status: item.message?.status,
            alreadyImported: false,
            ownerValid: true,
          )) {
        await showCapturedMessageNotification(local, preferences);
      }
    }
    if (notifyV2 && report.imported.isNotEmpty) {
      await alertImportedV2(database, report.imported, preferences);
    }
    await _budgetAlerts(
        container,
        preferences,
        report.imported
            .where((item) => item.path == CaptureImportPath.local)
            .expand((item) => item.committedTransactions));
    return CaptureDrainPass(readFailed: report.readFailed);
  }
  final report = await container.read(legacyCaptureDrainProvider).run(
        isActive: isActive,
        onAcknowledged: (message) =>
            CaptureIdentityMetrics.record(database, message.receivedAtInferred),
        showLocalReview: (item) =>
            showCapturedMessageNotification(item.result, preferences),
      );
  Diag.log(
      '[CaptureBg]',
      'pass queued=${report.queued} ingested=${report.ingested.length} '
          'stopped=${report.stopped} readFailed=${report.readFailed}');
  await _budgetAlerts(container, preferences, report.budgetCommits);
  return CaptureDrainPass(
    stopped: report.stopped,
    authRequired: report.authRequired || report.authRequiredBeforeDrain,
    readFailed: report.readFailed,
  );
}

Future<void> _budgetAlerts(ProviderContainer container,
    NotificationPreferences preferences,
    Iterable<TransactionEntity> commits) async {
  final committed = commits.toList();
  if (committed.isEmpty) return;
  try {
    await CapturedMessageProcessor.checkBudgetAlert(
      container.read(appDatabaseProvider),
      preferences,
      committedTransactions: committed,
      lang: LocalNotificationService.instance.notificationLanguage,
    );
  } catch (_) {}
}

bool _flagOn(String key) {
  try {
    return featureFlags.getBool(key);
  } catch (_) {
    return false;
  }
}
