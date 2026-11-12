import 'package:flutter/material.dart';

import '../../../core/theme/widgets/glass_dialog.dart';
import '../../../core/utils/l10n_ext.dart';
import '../services/android_sms_capture_service.dart';
import '../services/native_capture_bridge.dart';
import 'sms_capture_disclosure.dart';

/// MALI-013 — the one "turn automatic SMS capture on" flow, shared by the
/// Settings switch and the Android setup step so both follow the same order:
/// prominent disclosure → system permission dialog → opt-in.
///
/// The disclosure ordering is structural (`requestAndEnable` cannot reach the
/// system dialog unless the disclosure returns true). [onRequested] runs as
/// soon as the platform has answered, before any follow-up dialog, so callers
/// can refresh what they show from the platform's real state.
///
/// After "don't ask again" the only way forward is system Settings: asking
/// again returns instantly without showing anything, so this offers to open
/// them instead of a retry that would silently do nothing.
Future<SmsPermissionStatus> enableAutomaticSmsCapture(
  BuildContext context, {
  required Future<void> Function() onRequested,
}) async {
  final service = AndroidSmsCaptureService.instance;
  final result = await service.requestAndEnable(
    showDisclosure: () => showSmsCaptureDisclosure(context),
  );
  await onRequested();
  if (!context.mounted) return result.status;

  if (result.status == SmsPermissionStatus.permanentlyDenied) {
    final l10n = context.l10n;
    final go = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => GlassAlertDialog(
        title: Text(l10n.smsAutoCaptureDeniedTitle),
        content: Text(l10n.smsAutoCaptureDeniedBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.smsAutoCaptureOpenSettings),
          ),
        ],
      ),
    );
    if (go ?? false) await service.openSystemSettings();
  }
  // Declined, dismissed, denied-but-askable, unsupported or a platform error:
  // capture stays off and share/manual capture keep working; nothing to say.
  return result.status;
}
