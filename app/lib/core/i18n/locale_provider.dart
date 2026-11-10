import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/capture/services/local_notification_service.dart';
import '../../features/capture/services/native_capture_bridge.dart';
import '../../features/settings/settings_providers.dart';
import '../security/lock_prompt_language.dart';

/// The app's language, held across a settings reload.
///
/// This used to be `maybeWhen(data: ..., orElse: () => const Locale('ar'))`.
/// `orElse` fires on every `AsyncLoading` frame as well as on error — and
/// `userSettingsProvider` watches `dbRevisionProvider`, so it reloads after
/// **every database write**. An English reader's app therefore dropped to
/// Arabic for a frame each time anything was saved, and stayed there for as
/// long as the reload took.
///
/// That is not a theoretical flicker. The restore overlay covers the whole
/// screen immediately after sign-in, over exactly that window: captured on an
/// English device, `AppBootLoader` read «جارٍ تجهيز التطبيق...». The ARB was
/// correct and so was the widget; the locale underneath them was not.
///
/// `valueOrNull` keeps the previous answer while the future is in flight, so a
/// reload no longer changes the language. English is the fallback for the
/// first read when there is no saved preference; an explicit Arabic choice
/// remains Arabic.
final localeProvider = Provider<Locale>((ref) {
  final chosen = ref.watch(preSignInLanguageProvider);
  if (chosen != null) return Locale(chosen);
  final settings = ref.watch(userSettingsProvider).valueOrNull;
  final language = settings?.language ?? LockPromptLanguage.initialSettingsLanguage;
  return language == 'ar' ? const Locale('ar') : const Locale('en');
});

/// A language picked on the sign-in screen when the settings row cannot be
/// written there (a signed-out, read-only scope). It lives in this provider
/// graph only, so the next account scope reads its own settings again; the
/// choice also goes to the `LockPromptLanguage` mirror, which seeds a fresh
/// account's settings.
final preSignInLanguageProvider = StateProvider<String?>((ref) => null);

/// Pushes the active language into the notification service.
///
/// Notifications are raised from background isolates and plugin callbacks with
/// no element tree, so the service cannot read the locale the way a widget
/// does — it is told. Keeping the push next to the provider that owns the
/// answer means there is exactly one place where the two can disagree, and it
/// covers both first read and later changes, because `localeProvider` is
/// reactive.
final notificationLanguageSyncProvider = Provider<String>((ref) {
  final code = ref.watch(localeProvider).languageCode;
  LocalNotificationService.instance.notificationLanguage = code;
  // Keep the saved choice available to Shortcuts when Flutter is closed. Do
  // not replace it with the temporary first-frame default while settings load.
  if (ref.watch(preSignInLanguageProvider) != null ||
      ref.watch(userSettingsProvider).valueOrNull != null) {
    unawaited(NativeCaptureBridge.setNotificationLanguage(code));
  }
  return code;
});
