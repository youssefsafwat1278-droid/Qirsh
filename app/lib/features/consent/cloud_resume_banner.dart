import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/cloud_resume_reminder.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../settings/settings_providers.dart';
import 'smart_analysis_consent_sheet.dart';

final _sessionStatusProvider = Provider<SessionStatus>((ref) {
  final session = AppSession.instance;
  void changed() => ref.invalidateSelf();
  session.addListener(changed);
  ref.onDispose(() => session.removeListener(changed));
  return session.status;
});

final _reminderRevisionProvider = Provider<int>((ref) {
  void changed() => ref.invalidateSelf();
  CloudResumeReminder.changes.addListener(changed);
  ref.onDispose(() => CloudResumeReminder.changes.removeListener(changed));
  return CloudResumeReminder.changes.value;
});

/// The admitted account only. Errors hide a nonessential presentation hint.
final cloudResumeReminderProvider = FutureProvider<String?>((ref) async {
  ref.watch(_reminderRevisionProvider);
  ref.watch(_sessionStatusProvider);
  ref.watch(userSettingsProvider);
  final work = ref.read(consentLocalWorkProvider)();
  if (work == null) return null;
  try {
    final repository = ref.watch(userSettingsRepositoryProvider);
    // The marker may arrive before the debounced settings provider reloads.
    // Read the committed row, so an old ON snapshot cannot discard the hint.
    final settings = await work.run(repository.getSettings);
    if (!work.current) return null;
    final show = await CloudResumeReminder().shouldShow(work.capability.uid, settings);
    return work.current && show ? work.capability.uid : null;
  } catch (_) {
    return null;
  }
});

class CloudResumeBanner extends ConsumerStatefulWidget {
  const CloudResumeBanner({super.key, this.autoResume = true});

  /// Whether an app-made pause is resumed automatically (owner decision
  /// 2026-11-14). False keeps only the one-tap banner.
  final bool autoResume;

  @override
  ConsumerState<CloudResumeBanner> createState() => _CloudResumeBannerState();
}

class _CloudResumeBannerState extends ConsumerState<CloudResumeBanner> {
  bool _busy = false;
  String? _dismissedUid;

  /// Owner decision (2026-11-14): a Cloud the APP paused (session expiry, a
  /// native lifetime change) is turned back on automatically with the choice
  /// the user already made, through the same explicit enable route as the
  /// banner's button (nothing leaves the device until native ON is
  /// confirmed). The reminder exists only for app-made pauses, never for the
  /// user's own OFF. One attempt per pause; on failure the
  /// banner stays so the user can resume with one tap.
  static final Set<String> _autoAttempted = {};

  Future<void> _autoResume(String uid) async {
    if (_busy || !_autoAttempted.add(uid)) return;
    final work = ref.read(consentLocalWorkProvider)();
    if (work == null || work.capability.uid != uid || !work.current) return;
    setState(() => _busy = true);
    try {
      final ai = await CloudResumeReminder().aiWasOn(uid);
      if (!work.current) return;
      final saved =
          await saveConsentChoice(ref, cloud: true, ai: ai, work: work);
      if (saved.cloudProcessingEnabled && work.current) {
        await CloudResumeReminder().dismiss(uid);
      }
    } catch (_) {
      // The banner below stays: the user can resume with one tap.
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(cloudResumeReminderProvider);
      }
    }
  }


  Future<void> _turnOn(String uid) async {
    if (_busy) return;
    final work = ref.read(consentLocalWorkProvider)();
    if (work == null || work.capability.uid != uid || !work.current) return;
    setState(() => _busy = true);
    try {
      final enabled = await showSmartAnalysisConsentSheet(context, ref,
          management: true, work: work);
      if (enabled && work.current) {
        try {
          await CloudResumeReminder().dismiss(uid);
        } catch (_) {
          // Consent succeeded; a presentation preference cannot undo it.
        }
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        ref.invalidate(cloudResumeReminderProvider);
      }
    }
  }

  Future<void> _dismiss(String uid) async {
    setState(() => _dismissedUid = uid);
    try {
      await CloudResumeReminder().dismiss(uid);
    } catch (_) {
      // The hint stays closed in this view even if local preferences fail.
    }
  }

  @override
  Widget build(BuildContext context) {
    final reminder = ref.watch(cloudResumeReminderProvider);
    final uid = reminder.valueOrNull;
    // Settled with no reminder: the last pause is over, so a LATER app-made
    // pause in this process may auto-resume again. While a reminder is shown
    // its attempt stays recorded, so a failed resume is never retried in a
    // loop.
    if (reminder.hasValue && !reminder.isLoading && uid == null) {
      _autoAttempted.clear();
    }
    if (uid == null || uid == _dismissedUid) return const SizedBox.shrink();
    if (widget.autoResume && !_autoAttempted.contains(uid)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _autoResume(uid);
      });
    }
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
      child: MaliCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Icon(AppLucideIcons.cloud, color: c.cta, size: 24),
              const SizedBox(width: AppSpacing.s2),
              Expanded(child: Text(context.l10n.cloudResumeTitle,
                  style: AppTypography.bodyStrong(c.textPrimary))),
              IconButton(
                key: const Key('cloudResumeDismiss'),
                tooltip: context.l10n.commonClose,
                onPressed: _busy ? null : () => _dismiss(uid),
                icon: Icon(AppLucideIcons.x, size: 18, color: c.textSecondary),
              ),
            ]),
            Text(context.l10n.cloudResumeBody,
                style: AppTypography.footnote(c.textSecondary)),
            const SizedBox(height: AppSpacing.s2),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton(
                key: const Key('cloudResumeEnable'),
                onPressed: _busy ? null : () => _turnOn(uid),
                child: Text(context.l10n.consentTurnOn),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Test seam: forgets the once-per-process automatic resume attempts.
@visibleForTesting
class CloudResumeBannerDebug {
  static void reset() => _CloudResumeBannerState._autoAttempted.clear();
}
