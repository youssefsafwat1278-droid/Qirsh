import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/backend/auth_client_provider.dart';
import '../../core/backend/supabase_config.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/consent_authority.dart';
import '../../core/privacy/diagnostics_consent_gate.dart';
import '../../core/privacy/shared_learning_preference.dart';
import '../../core/privacy/smart_analysis_consent.dart';
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
import 'legal_links.dart';
import '../../core/theme/widgets/glass_sheet.dart';

/// One disclosed initial choice for Cloud Sync and Smart Analysis (decision
/// 3.8). Nothing is pre-selected: "Agree and enable" grants both and includes
/// shared category learning (3.10); "Continue locally" persists both denials.
/// Dismissal changes nothing. Withdrawal in Privacy turns both off together.
///
/// [management] opens the same disclosure from the Privacy screen to RE-consent:
/// its secondary action is a plain Cancel that writes nothing (first-use "Continue
/// locally", which persists a denial of both, is not offered there), and the
/// link back to the Privacy page is dropped because the person is already on it.
///
/// [smartAnalysisOnly] (Gemini-first phase 3) shows the Smart Analysis consent
/// on its own: what is sent, to whom, why, that it is optional and how to turn
/// it off, with Allow / Not now. Allow turns on Smart Analysis only (Cloud is
/// untouched); Not now writes nothing.
Future<bool> showSmartAnalysisConsentSheet(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onAnswered,
  ConsentLocalWork? work,
  bool management = false,
  bool restoreCloud = false,
  bool smartAnalysisOnly = false,
}) async {
  final scope = work ?? ref.read(consentLocalWorkProvider)();
  final granted = await showGlassSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // The disclosure is long: cap the sheet so the scrim above it stays
    // visible and tapping it still dismisses (a dismissal grants nothing).
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.s2,
              AppSpacing.gutter, AppSpacing.s6),
          child: SmartAnalysisConsentPanel(
            work: scope,
            management: management,
            restoreCloud: restoreCloud,
            smartAnalysisOnly: smartAnalysisOnly,
            onDone: (granted) {
              onAnswered?.call();
              Navigator.of(sheetContext).pop(granted);
            },
          ),
        ),
      ),
    ),
  );
  return granted ?? false;
}

/// What one [maybeReaskConsent] call did.
enum ReaskOutcome {
  /// Nothing to ask: consent already chosen, already asked on this install, or
  /// the account chose Cloud OFF.
  notNeeded,

  /// The sheet was shown (answered or dismissed).
  shown,

  /// F2: the account's server choice could not be read; nothing was shown or
  /// recorded, so the caller may ask again later.
  unknownPreference,

  /// The app was not in the foreground when the sheet would have been shown;
  /// nothing was shown or recorded, so the caller asks again on resume.
  deferred,

  /// The lifecycle that started the call ended (logout, account switch,
  /// unmounted); nothing was shown.
  stale,
}

/// §4.6 "a new device re-asks": an onboarded account admitted into a replica whose
/// cloud AND AI consent are both still unset (a new device, or after Remove data)
/// is asked once, through the same sheet, before anything can egress. Unset means
/// denied until answered, so nothing is sent while the question is open. A button
/// press (grant or "Not now") records that it was asked; a swipe-dismiss does not,
/// so the question comes back (F1: on the next resume, not only the next
/// launch). [seen]/[markSeen] default to the per-uid marker kept by
/// [AppSession]; [readChoice] defaults to the account's server choice.
/// [isForeground] is rechecked after the server read, right before the sheet
/// is presented: a sheet is never opened while the app is in the background.
/// [beforePresent] runs once the sheet is certain to open, just before it does
/// (the shell lifts its startup loader there); every check is repeated after it.
Future<ReaskOutcome> maybeReaskConsent(
  BuildContext context,
  WidgetRef ref, {
  Future<bool> Function()? seen,
  Future<void> Function()? markSeen,
  Future<AccountCloudChoice> Function()? readChoice,
  bool Function()? isForeground,
  Future<void> Function()? beforePresent,
  int smartAnalysisVersion = kSmartAnalysisConsentVersion,
}) async {
  final work = ref.read(consentLocalWorkProvider)();
  if (work == null) return ReaskOutcome.stale;
  final repository = ref.read(userSettingsRepositoryProvider);
  var askSharedLearning = false;
  try {
    final settings = await work.run(repository.getSettings);
    if (!work.current) return ReaskOutcome.stale;
    // Phase 3: a Smart Analysis consent given to an older wording no longer
    // counts. It is turned off first (sending stops), then asked once.
    if (await ref.read(smartAnalysisConsentRecordProvider).needsReconsent(
        work.capability.uid, settings,
        current: smartAnalysisVersion)) {
      if (!context.mounted || !work.current) return ReaskOutcome.stale;
      return await _reaskSmartAnalysisWording(context, ref, work,
          isForeground: isForeground, beforePresent: beforePresent);
    }
    if (settings.cloudConsentState != ConsentState.unset ||
        settings.aiConsentState != ConsentState.unset) {
      // Decision 3.10 transition: an account that accepted before shared
      // learning was part of this choice is asked about it once.
      if (settings.cloudProcessingEnabled && settings.aiConsentGranted) {
        askSharedLearning = true;
      } else {
        return ReaskOutcome.notNeeded;
      }
    }
    if (!askSharedLearning &&
        await (seen ?? AppSession.instance.consentPromptSeen)()) {
      return ReaskOutcome.notNeeded;
    }
  } on StaleAdmissionException {
    return ReaskOutcome.stale;
  }
  if (!context.mounted || !work.current) return ReaskOutcome.stale;
  if (askSharedLearning) {
    return _maybeAskSharedLearning(context, ref, work,
        isForeground: isForeground, beforePresent: beforePresent);
  }
  var choice = AccountCloudChoice.none;
  if (readChoice != null) {
    choice = await readChoice();
  } else {
    final client = ref.read(authClientProvider);
    if (client != null) {
      choice = await AppSession.instance.readAccountCloudChoice(
        client,
        AdmissionAuthority(work.capability.uid, () => work.current,
            epoch: work.capability.epoch),
      );
    }
  }
  if (!context.mounted || !work.current) return ReaskOutcome.stale;
  if (choice == AccountCloudChoice.off) return ReaskOutcome.notNeeded;
  // F2: an unanswered read is not "never chose": showing the generic sheet
  // would let its "Not now" hide the restore offer for good on this install.
  if (choice == AccountCloudChoice.unknown) {
    return ReaskOutcome.unknownPreference;
  }
  try {
    final latest = await work.run(repository.getSettings);
    if (!context.mounted || !work.current) return ReaskOutcome.stale;
    if (latest.cloudConsentState != ConsentState.unset ||
        latest.aiConsentState != ConsentState.unset) {
      return ReaskOutcome.notNeeded;
    }
  } on StaleAdmissionException {
    return ReaskOutcome.stale;
  }
  if (isForeground != null && !isForeground()) return ReaskOutcome.deferred;
  if (beforePresent != null) {
    await beforePresent();
    if (!context.mounted || !work.current) return ReaskOutcome.stale;
    if (isForeground != null && !isForeground()) return ReaskOutcome.deferred;
  }
  await showSmartAnalysisConsentSheet(
    context,
    ref,
    work: work,
    restoreCloud: choice == AccountCloudChoice.on,
    onAnswered: () {
      // markConsentPromptSeen binds to the epoch at ITS call: only the scope
      // that was asked may mark it.
      if (work.current) {
        unawaited((markSeen ?? AppSession.instance.markConsentPromptSeen)());
      }
    },
  );
  return ReaskOutcome.shown;
}

/// Phase 3: the Smart Analysis wording changed since this account accepted it.
/// The old consent is withdrawn (Smart Analysis turned off, sending stops),
/// then the Smart Analysis consent is shown once; Not now leaves it off.
Future<ReaskOutcome> _reaskSmartAnalysisWording(
  BuildContext context,
  WidgetRef ref,
  ConsentLocalWork work, {
  bool Function()? isForeground,
  Future<void> Function()? beforePresent,
}) async {
  try {
    await saveSmartAnalysisChoice(ref, on: false, work: work);
  } on StaleAdmissionException {
    return ReaskOutcome.stale;
  } catch (_) {
    // Not withdrawn: asked again on the next resume.
    return ReaskOutcome.deferred;
  }
  if (!context.mounted || !work.current) return ReaskOutcome.stale;
  if (isForeground != null && !isForeground()) return ReaskOutcome.deferred;
  if (beforePresent != null) {
    await beforePresent();
    if (!context.mounted || !work.current) return ReaskOutcome.stale;
  }
  if (!context.mounted) return ReaskOutcome.stale;
  await showSmartAnalysisConsentSheet(context, ref,
      work: work, smartAnalysisOnly: true);
  return ReaskOutcome.shown;
}

/// Asks an account that accepted Cloud and AI before shared category learning
/// was part of that consent (decision 3.10) whether to include it. Nothing is
/// assumed: until answered it stays OFF. A button records the answer for this
/// account on this device; a dismissal records nothing, so it is asked again.
Future<ReaskOutcome> _maybeAskSharedLearning(
  BuildContext context,
  WidgetRef ref,
  ConsentLocalWork work, {
  bool Function()? isForeground,
  Future<void> Function()? beforePresent,
}) async {
  final preference = ref.read(sharedLearningPreferenceProvider);
  final uid = work.capability.uid;
  if (await preference.isAnswered(uid)) return ReaskOutcome.notNeeded;
  if (!context.mounted || !work.current) return ReaskOutcome.stale;
  if (isForeground != null && !isForeground()) return ReaskOutcome.deferred;
  if (beforePresent != null) {
    await beforePresent();
    if (!context.mounted || !work.current) return ReaskOutcome.stale;
    if (isForeground != null && !isForeground()) return ReaskOutcome.deferred;
  }
  final agreed = await showGlassSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    // The disclosure is long: cap the sheet so the scrim above it stays
    // visible and tapping it still dismisses (a dismissal grants nothing).
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, AppSpacing.s2,
              AppSpacing.gutter, AppSpacing.s6),
          child: SharedLearningUpdatePanel(
              onDone: (value) => Navigator.of(sheetContext).pop(value)),
        ),
      ),
    ),
  );
  if (agreed == null || !work.current) return ReaskOutcome.shown;
  try {
    await preference.set(uid, agreed);
  } catch (_) {
    // Unwritten: still OFF and still unanswered, so it is asked again.
  }
  if (context.mounted) ref.invalidate(sharedLearningOptInProvider);
  return ReaskOutcome.shown;
}

/// The one-time shared-learning question for accounts that consented earlier.
class SharedLearningUpdatePanel extends StatelessWidget {
  const SharedLearningUpdatePanel({super.key, required this.onDone});

  final ValueChanged<bool> onDone;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final fg = context.colors.textPrimary;
    final muted = context.colors.textSecondary;
    const buttonSize = Size.fromHeight(AppSpacing.buttonHeight);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.sharedLearningUpdateTitle,
            style: AppTypography.sectionTitle(fg)),
        const SizedBox(height: AppSpacing.s3),
        Text(l10n.sharedLearningUpdateBody, style: AppTypography.body(muted)),
        const SizedBox(height: AppSpacing.s3),
        Text(l10n.smartConsentShared, style: AppTypography.body(muted)),
        const SizedBox(height: AppSpacing.s3),
        Text(l10n.smartConsentOff, style: AppTypography.body(muted)),
        LegalLinks(color: fg),
        const SizedBox(height: AppSpacing.s3),
        FilledButton(
          key: const Key('sharedLearningUpdateAgree'),
          style: FilledButton.styleFrom(minimumSize: buttonSize),
          onPressed: () => onDone(true),
          child: Text(l10n.sharedLearningUpdateAgree,
              textAlign: TextAlign.center),
        ),
        const SizedBox(height: AppSpacing.s2),
        OutlinedButton(
          key: const Key('sharedLearningUpdateKeepOff'),
          style: OutlinedButton.styleFrom(
              minimumSize: buttonSize,
              foregroundColor: fg,
              side: BorderSide(color: fg)),
          onPressed: () => onDone(false),
          child: Text(l10n.sharedLearningUpdateKeepOff,
              textAlign: TextAlign.center),
        ),
      ],
    );
  }
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

/// The shell's re-ask entry point (a seam for the AppShell lifecycle test).
typedef ReaskConsent = Future<ReaskOutcome> Function(
    BuildContext context, WidgetRef ref,
    {bool Function()? isForeground, Future<void> Function()? beforePresent});

final reaskConsentProvider = Provider<ReaskConsent>(
  (ref) => (context, ref, {isForeground, beforePresent}) => maybeReaskConsent(
      context, ref,
      isForeground: isForeground, beforePresent: beforePresent),
);

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

/// Gemini-first phase 3: turns Smart Analysis on or off by itself; Cloud is
/// left as it is. Off stops native sending FIRST (the restrictive mirror the
/// App Intent reads), then commits the choice, then narrows the server's copy
/// through the ordinary sync. Turning it off deletes nothing. On records the
/// accepted wording version for this account.
Future<UserSettingsEntity> saveSmartAnalysisChoice(
  WidgetRef ref, {
  required bool on,
  ConsentLocalWork? work,
  CaptureDeviceRegistrationService? registration,
}) async {
  final scope = work ?? ref.read(consentLocalWorkProvider)();
  if (scope == null) throw const StaleAdmissionException();
  final CaptureDeviceRegistrationService service =
      registration ?? ref.read(captureDeviceRegistrationServiceProvider);
  final record = ref.read(smartAnalysisConsentRecordProvider);
  if (!on) {
    try {
      await service.restrictSmartAnalysisNow();
    } catch (_) {
      // Best effort: the committed choice below is what every Dart send
      // checks, and the sync that follows republishes the mirror.
    }
  }
  if (on) {
    // Recorded BEFORE the consent is committed, so no reconciliation can ever
    // see this new consent without its wording (and take it for a dormant one
    // from an earlier build). A record without consent means nothing.
    await record.recordAccepted(scope.capability.uid);
  }
  final updated = await applyConsentChoice(
    scope: scope,
    repository: ref.read(userSettingsRepositoryProvider),
    writer: ref.read(consentSettingsWriterProvider),
    service: service,
    choices: ConsentChoices(
        ai: on ? ConsentState.accepted : ConsentState.declined),
  );
  if (ref.context.mounted) ref.invalidate(userSettingsProvider);
  if (scope.current) unawaited(service.syncBackendState().catchError((_) {}));
  return updated;
}

/// The widget-free core of [saveConsentChoice]: chooses the protocol for the
/// explicit choice and runs it, bound to [scope]. [choices] (phase 3) replaces
/// the flags with an exact choice (Smart Analysis on its own).
Future<UserSettingsEntity> applyConsentChoice({
  required ConsentLocalWork scope,
  required UserSettingsRepository repository,
  required ConsentSettingsWriter writer,
  required CaptureDeviceRegistrationService service,
  bool cloud = false,
  bool ai = false,
  bool declined = false,
  ConsentChoices? choices,
}) async {
  void requireCurrent() {
    if (!scope.current) throw const StaleAdmissionException();
  }

  final current = await scope.run(repository.getSettings);
  requireCurrent();
  choices ??= ConsentChoices(
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
    await writer.saveConsentChoice(scope.capability, choices!);
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

/// Flush the durable choice even if the shell is paused or unmounted while a
/// settings route is open. The push retains all normal owner/consent fences.
Future<bool> confirmSavedConsent(
    WidgetRef ref, ConsentLocalWork work,
    CaptureDeviceRegistrationService service, UserSettingsEntity saved) async {
  if (!work.current) return false;
  // Setup can advance with a pending choice before authenticated workers exist;
  // the live status still waits for the independent account confirmation.
  if (AppSession.instance.status == SessionStatus.needsOnboarding) {
    return service.deviceConsentMatches(saved);
  }
  if (SupabaseConfig.isConfigured) {
    try {
      await ref.read(planningPushServiceProvider).pushSettings()
          .timeout(const Duration(seconds: 8));
    } catch (_) {
      // A busy/offline worker keeps the durable row. Never turn a failed push
      // into confirmation; the subsequent account read decides the UI result.
    }
  }
  return work.current &&
      await service.serverConsentMatches(saved, waitForAccount: true);
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
    this.smartAnalysisOnly = false,
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

  /// Phase 3: the Smart Analysis consent on its own (Allow / Not now).
  final bool smartAnalysisOnly;

  @override
  ConsumerState<SmartAnalysisConsentPanel> createState() =>
      _SmartAnalysisConsentPanelState();
}

/// A short, non-sensitive reason code for a failed consent, for the debug log
/// (never shown to the user): the incomplete-enable reason (an internal
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
    final container = ProviderScope.containerOf(context, listen: false);
    setState(() => _granting = true);
    final UserSettingsEntity saved;
    try {
      saved = await saveConsentChoice(ref,
          cloud: cloud, ai: ai, work: work, registration: service);
    } catch (error) {
      // Saving failed: nothing was granted; the user can tap Enable again. A
      // revoked scope reports nothing (no toast into whatever scope is now live).
      if (mounted && work.current && error is! StaleAdmissionException) {
        if (kDebugMode) {
          debugPrint('[Consent] save failed: ${consentFailureCode(error)}');
        }
        // An incomplete Cloud enable is not a failed save: say it could not turn
        // on (it stays off) so the user can try again.
        AppToast.showError(
            context,
            error is CloudEnableIncompleteException
                ? context.l10n.cloudEnableIncomplete
                : error is CloudEnableWithdrawFirstException
                    ? context.l10n.cloudEnableWithdrawFirst
                    : error is ConsentChoiceNotPersistedException
                        ? context.l10n.cloudEnableChoiceNotSaved
                        : context.l10n.setupSaveFailed);
      }
      if (mounted) setState(() => _granting = false);
      return;
    }
    // Decision 3.10: shared category learning is part of this affirmative
    // choice, so it is recorded ON here, explicitly, for this account. Never
    // on any other path: an update or a dismissal opts nobody in. A failed
    // write leaves it OFF (fail closed); the sending gates still require
    // Cloud AND AI consent at every send. The keychain write does not hold up
    // completing the consent itself.
    // Phase 3: the Smart Analysis wording this account accepted.
    if (ai && saved.aiConsentGranted && work.current) {
      unawaited(container
          .read(smartAnalysisConsentRecordProvider)
          .recordAccepted(work.capability.uid)
          .catchError((Object _) {}));
    }
    if (ai && saved.cloudProcessingEnabled && saved.aiConsentGranted &&
        work.current) {
      unawaited(container
          .read(sharedLearningPreferenceProvider)
          .set(work.capability.uid, true)
          .then((_) {
        try {
          container.invalidate(sharedLearningOptInProvider);
        } catch (_) {} // The scope may be gone by then.
      }, onError: (Object _) {}));
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
      final confirmed = await confirmSavedConsent(ref, work, service, saved);
      if (confirmed) {
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

  /// Phase 3: Allow on the Smart Analysis consent. Turns Smart Analysis on by
  /// itself, then connects this device for it (in the smart-analysis lane when
  /// Cloud is off). A failed save grants nothing.
  Future<void> _grantSmartAnalysis() async {
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
      final saved = await saveSmartAnalysisChoice(ref,
          on: true, work: work, registration: service);
      if (!mounted || !work.current) return;
      try {
        await service.retry();
      } catch (_) {}
      if (!mounted || !work.current) return;
      final confirmed = saved.cloudProcessingEnabled
          ? await confirmSavedConsent(ref, work, service, saved)
          : await service.deviceConsentMatches(saved);
      if (!mounted || !work.current) return;
      if (!confirmed) {
        // Saved: the next sync connects it; until then nothing is analysed.
        AppToast.showError(context, context.l10n.smartConsentStatusFailed);
      }
      _complete(work, true);
    } on StaleAdmissionException {
      // An old sheet cannot update the new account.
    } catch (_) {
      if (mounted && work.current) {
        AppToast.showError(context, context.l10n.setupSaveFailed);
      }
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
    Widget heading(String text) => Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s2, bottom: AppSpacing.s1),
        child: Semantics(
            header: true,
            child: Text(text, style: AppTypography.bodyStrong(fg))));
    Widget para(String text) => Padding(
        padding: const EdgeInsets.only(bottom: AppSpacing.s3),
        child: Text(text, style: AppTypography.body(muted)));
    // Decision 3.8: both choices have the same size and weight; only the
    // affirmative "Agree and enable" turns anything on.
    const buttonSize = Size.fromHeight(AppSpacing.buttonHeight);
    if (widget.smartAnalysisOnly) {
      // Phase 3: Smart Analysis alone. Allow / Not now, the same size and
      // weight; Not now writes nothing (it stays off, offered again only from
      // the analysis log or Settings).
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.smartOnlyTitle, style: AppTypography.sectionTitle(fg)),
          const SizedBox(height: AppSpacing.s3),
          para(l10n.smartOnlyIntro),
          heading(l10n.smartConsentHeadSent),
          para(l10n.smartOnlySent),
          heading(l10n.smartConsentHeadWho),
          para(l10n.smartOnlyWho),
          heading(l10n.smartConsentHeadWhy),
          para(l10n.smartOnlyWhy),
          heading(l10n.smartOnlyHeadOptional),
          para(l10n.smartOnlyOptional),
          heading(l10n.smartConsentHeadOff),
          para(l10n.smartOnlyOff),
          LegalLinks(color: fg),
          const SizedBox(height: AppSpacing.s3),
          FilledButton(
            key: const Key('smartOnlyAllow'),
            style: FilledButton.styleFrom(minimumSize: buttonSize),
            onPressed: _granting ? null : _grantSmartAnalysis,
            child: Text(
                _granting ? l10n.consentStatusTurningOn : l10n.smartOnlyAllow,
                textAlign: TextAlign.center),
          ),
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton(
            key: const Key('smartOnlyNotNow'),
            style: OutlinedButton.styleFrom(
                minimumSize: buttonSize,
                foregroundColor: fg,
                side: BorderSide(color: fg)),
            onPressed: _granting ? null : () => widget.onDone(false),
            child: Text(l10n.smartConsentNotNow, textAlign: TextAlign.center),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.restoreCloud ? l10n.restoreCloudTitle : l10n.smartConsentTitle,
            style: AppTypography.sectionTitle(fg)),
        const SizedBox(height: AppSpacing.s3),
        para(l10n.smartConsentIntro),
        heading(l10n.smartConsentHeadSent),
        para(l10n.smartConsentBullet2),
        para(l10n.smartConsentBullet1),
        heading(l10n.smartConsentHeadWho),
        para(l10n.smartConsentWho),
        heading(l10n.smartConsentHeadWhy),
        para(l10n.smartConsentWhy),
        heading(l10n.smartConsentHeadSync),
        para(l10n.smartConsentBullet3),
        heading(l10n.smartConsentHeadShared),
        para(l10n.smartConsentShared),
        heading(l10n.smartConsentHeadOff),
        para(l10n.smartConsentOff),
        if (!widget.management) para(l10n.smartConsentLocal),
        LegalLinks(color: fg),
        const SizedBox(height: AppSpacing.s3),
        FilledButton(
          key: const Key('initialConsentAccept'),
          style: FilledButton.styleFrom(minimumSize: buttonSize),
          onPressed: _granting ? null : () => _grant(cloud: true, ai: true),
          child: Text(
              _granting ? l10n.consentStatusTurningOn : l10n.initialConsentAccept,
              textAlign: TextAlign.center),
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
          const SizedBox(height: AppSpacing.s2),
          OutlinedButton(
            key: const Key('initialConsentDecline'),
            style: OutlinedButton.styleFrom(
                minimumSize: buttonSize,
                foregroundColor: fg,
                side: BorderSide(color: fg)),
            onPressed: _granting ? null : _decline,
            child: Text(l10n.initialConsentDecline, textAlign: TextAlign.center),
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
