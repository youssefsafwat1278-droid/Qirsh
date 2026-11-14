import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/backend/auth_client_provider.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../core/session/admission_authority.dart';
import '../../core/session/app_session.dart';
import '../../core/session/consent_capability.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/repositories/user_settings_repository.dart';
import '../capture/services/capture_device_registration_service.dart';
import '../settings/settings_providers.dart';
import '../../core/theme/widgets/glass_sheet.dart';

/// One disclosed initial choice for Cloud Sync and Smart Analysis. Nothing is
/// pre-selected: Accept grants both; local use persists both denials. Dismissal
/// changes nothing. Privacy management retains independent withdrawal.
///
/// [management] opens the same disclosure from the Privacy screen to RE-consent:
/// its secondary action is a plain Cancel that writes nothing (first-use "Continue
/// locally", which persists a denial of both, is not offered there), and the
/// link back to the Privacy page is dropped because the person is already on it.
Future<bool> showSmartAnalysisConsentSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onAnswered,
  ConsentLocalWork? work,
  bool management = false,
  bool restoreCloud = false,
}) async {
  final scope = work ?? ref.read(consentLocalWorkProvider)();
  final granted = await showGlassSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.gutter, AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
        child: SmartAnalysisConsentPanel(
          work: scope,
          management: management,
          restoreCloud: restoreCloud,
          onDone: (granted) {
            onAnswered?.call();
            Navigator.of(sheetContext).pop(granted);
          },
        ),
      ),
    ),
  );
  return granted ?? false;
}

/// §4.6 "a new device re-asks": an onboarded account admitted into a replica whose
/// cloud AND AI consent are both still unset (a new device, or after Remove data)
/// is asked once, through the same sheet, before anything can egress. Unset means
/// denied until answered, so nothing is sent while the question is open. A button
/// press (grant or "Not now") records that it was asked; a swipe-dismiss does not,
/// so the question comes back next launch. [seen]/[markSeen] default to the
/// per-uid marker kept by [AppSession].
Future<void> maybeReaskConsent(
  BuildContext context,
  WidgetRef ref, {
  Future<bool> Function()? seen,
  Future<void> Function()? markSeen,
}) async {
  final work = ref.read(consentLocalWorkProvider)();
  if (work == null) return;
  final repository = ref.read(userSettingsRepositoryProvider);
  try {
    final settings = await work.run(repository.getSettings);
    if (!work.current ||
        settings.cloudConsentState != ConsentState.unset ||
        settings.aiConsentState != ConsentState.unset) {
      return;
    }
    if (await (seen ?? AppSession.instance.consentPromptSeen)()) return;
  } on StaleAdmissionException {
    return;
  }
  if (!context.mounted || !work.current) return;
  bool? previousChoice;
  final client = ref.read(authClientProvider);
  if (client != null) {
    previousChoice = await AppSession.instance.readAccountCloudPreference(
      client,
      AdmissionAuthority(work.capability.uid, () => work.current,
          epoch: work.capability.epoch),
    );
  }
  if (!context.mounted || !work.current || previousChoice == false) return;
  try {
    final latest = await work.run(repository.getSettings);
    if (!context.mounted || !work.current ||
        latest.cloudConsentState != ConsentState.unset ||
        latest.aiConsentState != ConsentState.unset) {
      return;
    }
  } on StaleAdmissionException {
    return;
  }
  await showSmartAnalysisConsentSheet(
    context,
    ref,
    work: work,
    restoreCloud: previousChoice == true,
    onAnswered: () {
      // markConsentPromptSeen binds to the epoch at ITS call: only the scope
      // that was asked may mark it.
      if (work.current) {
        unawaited((markSeen ?? AppSession.instance.markConsentPromptSeen)());
      }
    },
  );
}

/// The consent-only capability of the lifecycle a consent action started in, and
/// the runner of its bounded local work inside the session's local drain. The
/// action captures it once, before its first await. It is the typed
/// [ConsentCapability] the session issued (valid through onboarding), never a
/// flag: the general local-work authority still requires an authenticated session.
class ConsentLocalWork {
  ConsentLocalWork(this.capability, this._run);

  final ConsentCapability capability;
  final Future<T> Function<T>(Future<T> Function() action) _run;

  /// Null when no lifecycle may be asked or saved (nothing admitted, an explicit
  /// admission, logout, removal or account switch in flight).
  static ConsentLocalWork? capture() {
    final capability = AppSession.instance.captureConsentCapability();
    return capability == null
        ? null
        : ConsentLocalWork(
            capability,
            <T>(action) => AppSession.instance
                .runConsentLocalOperation(capability, action));
  }

  bool get current => capability.isCurrent;

  /// Bounded local work only: no network, retry, removal or server revoke.
  Future<T> run<T>(Future<T> Function() action) {
    if (!current) throw const StaleAdmissionException();
    return _run(action);
  }
}

/// Seam for widget tests with fake repositories (no authenticated session).
final consentLocalWorkProvider =
    Provider<ConsentLocalWork? Function()>((ref) => ConsentLocalWork.capture);

/// Persists the explicit choice through the TYPED consent writer and the
/// enable/disable transition authority. A failed save never grants consent.
/// Everything is captured before the first await; a lifecycle that ends meanwhile
/// (logout, removal, another uid, a readmission at a new epoch) ends in
/// [StaleAdmissionException] with nothing granted and no later side effect.
/// There is no caller-supplied save callback: the write is the choices plus the
/// capability, verified inside the repository transaction.
Future<UserSettingsEntity> saveConsentChoice(
  WidgetRef ref, {
  bool cloud = false,
  bool ai = false,
  bool declined = false,
  ConsentLocalWork? work,
  CaptureDeviceRegistrationService? registration,
}) async {
  final scope = work ?? ref.read(consentLocalWorkProvider)();
  if (scope == null) throw const StaleAdmissionException();
  final updated = await applyConsentChoice(
    scope: scope,
    repository: ref.read(userSettingsRepositoryProvider),
    writer: ref.read(consentSettingsWriterProvider),
    service: registration ?? ref.read(captureDeviceRegistrationServiceProvider),
    cloud: cloud,
    ai: ai,
    declined: declined,
  );
  if (ref.context.mounted) ref.invalidate(userSettingsProvider);
  DiagnosticsConsentGate.set(
    ConsentAuthority.decide(EgressClass.diagnostics, updated),
  );
  return updated;
}

/// The widget-free core of [saveConsentChoice]: chooses the protocol for the
/// explicit choice and runs it, bound to [scope].
Future<UserSettingsEntity> applyConsentChoice({
  required ConsentLocalWork scope,
  required UserSettingsRepository repository,
  required ConsentSettingsWriter writer,
  required CaptureDeviceRegistrationService service,
  bool cloud = false,
  bool ai = false,
  bool declined = false,
}) async {
  void requireCurrent() {
    if (!scope.current) throw const StaleAdmissionException();
  }

  final current = await scope.run(repository.getSettings);
  requireCurrent();
  final choices = ConsentChoices(
    cloud: declined
        ? ConsentState.declined
        : cloud
            ? ConsentState.accepted
            : null,
    ai: declined
        ? ConsentState.declined
        : ai
            ? ConsentState.accepted
            : null,
  );
  final updated = choices.applyTo(current);
  Future<void> commit() async {
    await writer.saveConsentChoice(scope.capability, choices);
  }

  // Astra G: widening Cloud is an explicit enable (new generation + version).
  if (service.isDisablingCloud(current, updated)) {
    requireCurrent();
    DiagnosticsConsentGate.set(false);
    await service.disableCloud(commitLocalOff: () => scope.run(commit));
  } else {
    // A3(c)/G2: the protocol follows BOTH the stored choice and the live/pending
    // authority. A stored ON is never completed by a plain save unless the live
    // ON is verified; otherwise the exact pending operation resumes, or the
    // person is told to turn the permission off first (nothing written).
    final route = await service.explicitEnableRoute(current, updated,
        ownerUid: scope.capability.uid);
    requireCurrent();
    switch (route) {
      case ExplicitEnableRoute.enable:
      case ExplicitEnableRoute.resumePending:
        await service.enableCloud(
            write: ConsentWrite(scope.capability, choices));
      case ExplicitEnableRoute.plainSave:
        await scope.run(commit);
      case ExplicitEnableRoute.withdrawFirst:
        throw const CloudEnableWithdrawFirstException();
    }
  }
  requireCurrent();
  // R17: the result is the row that is actually persisted, never the predicted
  // one. An exact resume of an older pending enable skips the save, so the
  // choice asked for may not be stored: that is reported, not claimed.
  final persisted = await scope.run(repository.getSettings);
  requireCurrent();
  if (persisted.cloudProcessingEnabled != updated.cloudProcessingEnabled ||
      persisted.aiConsentGranted != updated.aiConsentGranted) {
    throw ConsentChoiceNotPersistedException(persisted);
  }
  return persisted;
}

/// Disclosure + actions of the sheet.
/// [onDone] fires with true after a grant (once the user continues past the
/// live status) or false for "Not now".
class SmartAnalysisConsentPanel extends ConsumerStatefulWidget {
  const SmartAnalysisConsentPanel({
    super.key,
    required this.onDone,
    this.onDark = false,
    this.privacyRoute = '/privacy',
    this.work,
    this.management = false,
    this.restoreCloud = false,
  });

  final ValueChanged<bool> onDone;
  final bool onDark;
  final String privacyRoute;

  /// The scope the question is shown for (default: captured when the panel is
  /// created). Every action and the final [onDone] are bound to it.
  final ConsentLocalWork? work;

  /// Re-consent from Privacy management: Cancel (no write) instead of the
  /// first-use denial, and no link back to the page it is shown on.
  final bool management;
  final bool restoreCloud;

  @override
  ConsumerState<SmartAnalysisConsentPanel> createState() =>
      _SmartAnalysisConsentPanelState();
}

/// A short, non-sensitive reason code appended to a failed consent toast so a
/// field report can be diagnosed: the incomplete-enable reason (an internal
/// identifier) and, while egress is frozen, the freeze tag; otherwise only the
/// exception type. Never a message, token, email or uid.
@visibleForTesting
String consentFailureCode(Object error) {
  if (error is! CloudEnableIncompleteException) return error.runtimeType.toString();
  final tag = ConsentAuthority.egressFreezeTag;
  return ConsentAuthority.egressFrozen && tag.isNotEmpty
      ? 'CloudEnableIncomplete:${error.reason}/$tag'
      : 'CloudEnableIncomplete:${error.reason}';
}

class _SmartAnalysisConsentPanelState
    extends ConsumerState<SmartAnalysisConsentPanel> {
  bool _granting = false;
  late final ConsentLocalWork? _work;

  @override
  void initState() {
    super.initState();
    _work = widget.work ?? ref.read(consentLocalWorkProvider)();
  }

  /// The only way [SmartAnalysisConsentPanel.onDone] fires: the captured scope
  /// must still be current at this very moment.
  void _complete(ConsentLocalWork work, bool granted) {
    if (mounted && work.current) widget.onDone(granted);
  }

  Future<void> _grant({required bool cloud, required bool ai}) async {
    if (_granting) return;
    final work = _work;
    if (work == null) {
      AppToast.showError(context, context.l10n.setupSaveFailed);
      return;
    }
    if (!work.current) return;
    final service = ref.read(captureDeviceRegistrationServiceProvider);
    setState(() => _granting = true);
    final UserSettingsEntity saved;
    try {
      saved = await saveConsentChoice(ref,
          cloud: cloud, ai: ai, work: work, registration: service);
    } catch (error) {
      // Saving failed: nothing was granted; the user can tap Enable again. A
      // revoked scope reports nothing (no toast into whatever scope is now live).
      if (mounted && work.current && error is! StaleAdmissionException) {
        // An incomplete Cloud enable is not a failed save: say it could not turn
        // on (it stays off) so the user can try again.
        AppToast.showError(
            context,
            error is CloudEnableIncompleteException
                ? '${context.l10n.cloudEnableIncomplete} '
                    '(E: ${consentFailureCode(error)})'
                : error is CloudEnableWithdrawFirstException
                    ? context.l10n.cloudEnableWithdrawFirst
                    : error is ConsentChoiceNotPersistedException
                        ? context.l10n.cloudEnableChoiceNotSaved
                        : '${context.l10n.setupSaveFailed} '
                            '(E: ${consentFailureCode(error)})');
      }
      if (mounted) setState(() => _granting = false);
      return;
    }
    // Consent is locally saved from here on. A registration failure is reported by the
    // live status below (connected / failed + Retry), never as a save failure.
    try {
      if (work.current) {
        if (ai) {
          await service.retry();
        } else {
          await service.syncBackendState();
        }
      }
    } catch (_) {}
    try {
      if (!mounted || !work.current) return;
      if (await service.serverConsentMatches(saved)) {
        _complete(work, true);
      } else if (mounted && work.current) {
        AppToast.showError(context, context.l10n.smartConsentStatusFailed);
      }
    } on StaleAdmissionException {
      // An old sheet cannot update the new account.
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  Future<void> _decline() async {
    if (_granting) return;
    final work = _work;
    if (work == null) {
      AppToast.showError(context, context.l10n.setupSaveFailed);
      return;
    }
    if (!work.current) return;
    final service = ref.read(captureDeviceRegistrationServiceProvider);
    setState(() => _granting = true);
    try {
      await saveConsentChoice(ref,
          declined: true, work: work, registration: service);
      _complete(work, false);
    } catch (error) {
      if (mounted && work.current && error is! StaleAdmissionException) {
        AppToast.showError(context, context.l10n.setupSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _granting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fg = widget.onDark ? Colors.white : context.colors.textPrimary;
    final muted = widget.onDark ? Colors.white70 : context.colors.textSecondary;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.restoreCloud ? l10n.restoreCloudTitle : l10n.smartConsentTitle,
            style: AppTypography.sectionTitle(fg)),
        const SizedBox(height: AppSpacing.s3),
        for (final text in [l10n.smartConsentBullet2, l10n.smartConsentBullet1, l10n.smartConsentBullet3])
          Padding(padding: const EdgeInsets.only(bottom: AppSpacing.s3),
            child: Text(text, style: AppTypography.body(muted))),
        FilledButton(
          key: const Key('initialConsentAccept'),
          onPressed: _granting ? null : () => _grant(cloud: true, ai: true),
          child: Text(_granting ? l10n.consentStatusTurningOn : l10n.initialConsentAccept),
        ),
        if (widget.restoreCloud)
          TextButton(
            key: const Key('restoreCloudOnly'),
            onPressed: _granting ? null : () => _grant(cloud: true, ai: false),
            child: Text(l10n.restoreCloudOnly),
          ),
        if (widget.management)
          TextButton(
            key: const Key('consentManageCancel'),
            // Cancelling re-consent changes nothing: no save, no denial.
            onPressed: _granting ? null : () => widget.onDone(false),
            child: Text(l10n.commonCancel),
          )
        else ...[
          TextButton(
            key: const Key('initialConsentDecline'),
            onPressed: _granting ? null : _decline,
            child: Text(l10n.initialConsentDecline),
          ),
          TextButton(
            onPressed: () => context.push(widget.privacyRoute),
            child: Text(l10n.smartConsentPrivacyLink),
          ),
        ],
      ],
    );
  }
}

/// Live registration status: connecting spinner / connected / failed + Retry.
class SmartAnalysisRegistrationStatus extends ConsumerWidget {
  const SmartAnalysisRegistrationStatus({super.key, this.onDark = false});

  final bool onDark;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final status = ref.watch(captureRegistrationStatusProvider);
    final fg = onDark ? Colors.white : c.textPrimary;
    switch (status.phase) {
      case CaptureRegistrationPhase.connected:
        return Row(children: [
          Icon(Icons.check_circle, size: 18, color: c.success),
          const SizedBox(width: AppSpacing.s2),
          Expanded(
            child: Text(l10n.smartConsentStatusConnected,
                style: AppTypography.body(fg)),
          ),
        ]);
      case CaptureRegistrationPhase.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.smartConsentStatusFailed, style: AppTypography.body(fg)),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                onPressed: () =>
                    ref.read(captureDeviceRegistrationServiceProvider).retry(),
                style: TextButton.styleFrom(foregroundColor: fg),
                child: Text(l10n.smartConsentRetry),
              ),
            ),
          ],
        );
      case CaptureRegistrationPhase.notRequested:
        return const SizedBox.shrink();
      case CaptureRegistrationPhase.connecting:
        return Row(children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2, color: fg),
          ),
          const SizedBox(width: AppSpacing.s2),
          Text(l10n.smartConsentStatusConnecting,
              style: AppTypography.body(fg)),
        ]);
    }
  }
}
