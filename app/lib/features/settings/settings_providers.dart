import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/shared_learning_preference.dart';
import '../../domain/entities/engagement_entities.dart';
import '../../domain/entities/supporting_entities.dart';
import '../capture/services/android_sms_capture_service.dart';
import '../capture/services/native_capture_bridge.dart';

const captureHealthNudgeThreshold = Duration(days: 7);

class CaptureHealthStatus {
  const CaptureHealthStatus({
    required this.lastCaptureAt,
    required this.now,
    this.apnsRegistrationFailure,
  });

  final DateTime? lastCaptureAt;
  final DateTime now;
  final ApnsRegistrationFailure? apnsRegistrationFailure;

  bool get hasCaptureHistory => lastCaptureAt != null;

  Duration? get gap {
    final last = lastCaptureAt;
    if (last == null) return null;
    final difference = now.difference(last);
    return difference.isNegative ? Duration.zero : difference;
  }

  bool get shouldNudge {
    final currentGap = gap;
    return apnsRegistrationFailure != null ||
        (currentGap != null && currentGap >= captureHealthNudgeThreshold);
  }
}

final userSettingsProvider = FutureProvider<UserSettingsEntity>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(loadUserSettingsUseCaseProvider).call();
});

/// Whether "Remember for this merchant" also shares the merchant and category
/// right now: the account's shared-learning switch (off until the user agrees) AND Cloud
/// AND AI consent — the same three the client checks before sending. Drives
/// the just-in-time notice in the category sheets.
final sharedLearningActiveProvider = FutureProvider.autoDispose<bool>((ref) async {
  final settings = await ref.watch(userSettingsProvider.future);
  if (!settings.cloudProcessingEnabled || !settings.aiConsentGranted) {
    return false;
  }
  return ref.watch(sharedLearningOptInProvider.future);
});

final notificationPreferencesProvider =
    FutureProvider<NotificationPreferences>((ref) async {
  ref.watch(dbRevisionProvider);
  return ref.watch(loadNotificationPreferencesUseCaseProvider).call();
});

final captureHealthStatusProvider =
    FutureProvider<CaptureHealthStatus>((ref) async {
  ref.watch(dbRevisionProvider);
  // B2-C — bounded aggregate (MAX over bank captures) instead of loading the
  // whole ledger to compute one timestamp.
  final latestCaptureAt =
      await ref.watch(transactionRepositoryProvider).latestBankCaptureAt();
  return CaptureHealthStatus(
    lastCaptureAt: latestCaptureAt,
    now: DateTime.now().toUtc(),
    apnsRegistrationFailure:
        await NativeCaptureBridge.getApnsRegistrationFailure(),
  );
});

void refreshNotificationPreferences(WidgetRef ref) {
  ref.invalidate(notificationPreferencesProvider);
}

void refreshUserSettings(WidgetRef ref) {
  ref.invalidate(userSettingsProvider);
}

/// MALI-013 — the Android automatic-SMS-capture capability snapshot.
///
/// Read from the platform on every watch rather than cached in Dart, because
/// every field can change outside the app: the user can revoke RECEIVE_SMS in
/// system Settings, and the stored opt-in is reset on identity change. A cached
/// Dart bool would show a toggle ON for a permission the OS has already taken
/// away — which is exactly the "we are capturing your SMS" lie this feature
/// cannot afford to tell.
///
/// Non-Android returns the default (`receiveSmsDeclared: false`), which hides
/// the toggle entirely.
final captureCapabilitiesProvider = FutureProvider<CaptureCapabilities>(
  (ref) => AndroidSmsCaptureService.instance.capabilities(),
);
