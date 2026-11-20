import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/entities/supporting_entities.dart';
import '../security/secure_storage_options.dart';
import 'consent_authority.dart';

/// Gemini-first phase 3 (owner decision 2026-11-20): "Gemini is always
/// available in the app, separated from Cloud."
///
/// The wording version of the smart-analysis consent text
/// (`smartConsent*` in the ARB files). Raise it when that text changes in a way
/// the person must read again: anyone who accepted an older version is then
/// treated as not consented and is asked again (see
/// [SmartAnalysisConsentRecord.needsReconsent]).
///
/// Version 1 is the text in force when phase 3 shipped. A consent given
/// before it (the combined "Smart Analysis & Cloud Sync" sheet) disclosed the
/// same AI processing (the message, sanitised, read by Google Gemini through
/// Qirsh's servers, to find the amount, merchant and type): where it is in
/// effect (Cloud ON too) it counts as version 1 and is not asked again. An AI
/// choice an earlier build kept while Cloud was OFF was dormant (the app said
/// nothing is analysed) and is withdrawn instead of being switched on silently
/// (`CaptureDeviceRegistrationService._settleLegacySmartAnalysis`).
const int kSmartAnalysisConsentVersion = 1;

/// Whether smart analysis is the person's choice on this platform. iOS: the
/// smart-analysis (AI) consent alone, since its lane needs no Cloud. Android
/// (no smart-analysis lane yet): AI under Cloud, as before phase 3.
bool smartAnalysisSelected(UserSettingsEntity settings, {bool? ios}) =>
    (ios ?? Platform.isIOS)
        ? settings.aiConsentGranted
        : settings.cloudProcessingEnabled && settings.aiConsentGranted;

/// Whether an analysis request may leave the device right now (read at the
/// moment of egress): [EgressClass.smartAnalysis] on iOS,
/// [EgressClass.aiProcessing] on Android.
bool smartAnalysisAllowed(UserSettingsEntity settings, {bool? ios}) =>
    ConsentAuthority.decide(
        (ios ?? Platform.isIOS)
            ? EgressClass.smartAnalysis
            : EgressClass.aiProcessing,
        settings);

/// The wording version each account accepted, on this device. Kept in the
/// device keychain / EncryptedSharedPreferences ([SecureStorageOptions]: this
/// device only, never synced, not in the Drift database or a backup), one key
/// per account: `qirsh.smart_analysis_consent.v1.<sha256 of the uid>`.
///
/// It records WHICH text was accepted; whether consent is given is the
/// stored AI consent ([UserSettingsEntity.aiConsentState]). A missing key on an
/// accepted consent is a consent from before phase 3 (settled once, see
/// [kSmartAnalysisConsentVersion]) and reads as version 1. An unreadable store
/// never re-asks (it reads as the version in force), so a broken keychain does
/// not prompt forever.
class SmartAnalysisConsentRecord {
  SmartAnalysisConsentRecord({
    Future<String?> Function(String key)? read,
    Future<void> Function(String key, String value)? write,
  })  : _read = read ?? ((k) => SecureStorageOptions.storage.read(key: k)),
        _write = write ??
            ((k, v) => SecureStorageOptions.storage.write(key: k, value: v));

  /// An in-memory store, for tests.
  factory SmartAnalysisConsentRecord.memory([Map<String, String>? backing]) {
    final m = backing ?? <String, String>{};
    return SmartAnalysisConsentRecord(
      read: (k) async => m[k],
      write: (k, v) async => m[k] = v,
    );
  }

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  static String keyFor(String uid) =>
      'qirsh.smart_analysis_consent.v1.${sha256.convert(utf8.encode(uid))}';

  /// The accepted wording version of [uid]; 1 when none was recorded.
  Future<int> acceptedVersion(String uid) async {
    try {
      final raw = await _read(keyFor(uid));
      return raw == null ? 1 : int.tryParse(raw) ?? 1;
    } catch (_) {
      return kSmartAnalysisConsentVersion;
    }
  }

  /// Whether [uid] has a recorded wording version (phase 3 or later). Throws
  /// when the store cannot be read.
  Future<bool> hasRecord(String uid) async => await _read(keyFor(uid)) != null;

  /// Records that [uid] accepted [version] (the text just shown).
  Future<void> recordAccepted(String uid,
      {int version = kSmartAnalysisConsentVersion}) async {
    if (uid.isEmpty) return;
    await _write(keyFor(uid), '$version');
  }

  /// Whether [uid]'s accepted consent predates the text in force ([current]),
  /// so it no longer counts and the person is asked again.
  Future<bool> needsReconsent(String uid, UserSettingsEntity settings,
      {int current = kSmartAnalysisConsentVersion}) async {
    if (uid.isEmpty || !settings.aiConsentGranted) return false;
    final String? raw;
    try {
      raw = await _read(keyFor(uid));
    } catch (_) {
      return false; // unreadable: never re-ask
    }
    return (raw == null ? 1 : int.tryParse(raw) ?? 1) < current;
  }
}

/// Whether this platform has the smart-analysis lane (iOS), so Smart Analysis
/// works with Cloud OFF. A provider so a widget test can pick the platform.
final smartAnalysisOwnLaneProvider = Provider<bool>((_) => Platform.isIOS);

final smartAnalysisConsentRecordProvider =
    Provider<SmartAnalysisConsentRecord>((_) => SmartAnalysisConsentRecord());
