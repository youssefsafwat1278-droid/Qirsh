import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/supporting_entities.dart';

/// Local presentation only: never a consent, credential or egress permission.
/// Removed with the app container; each account has its own opaque key.
class CloudResumeReminder {
  static final changes = ValueNotifier<int>(0);

  String _key(String uid) =>
      'qirsh.cloud_resume.v1.${sha256.convert(utf8.encode(uid))}';

  String _choice(UserSettingsEntity settings) =>
      '${settings.cloudConsentVersion}:${settings.cloudConsentAt?.toUtc().toIso8601String() ?? "-"}';

  /// Records that the app itself paused Cloud (never the user's own OFF).
  /// [aiWasOn]: whether AI was ON before the pause, so the automatic resume
  /// restores the same choice (owner decision 2026-11-14).
  Future<void> rememberPaused(String uid, UserSettingsEntity savedOff,
      {bool aiWasOn = false}) async {
    if (uid.isEmpty || savedOff.cloudConsentState != ConsentState.declined) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _key(uid), '${_choice(savedOff)}${aiWasOn ? _aiSuffix : ''}');
    changes.value++;
  }

  static const _aiSuffix = '#ai';

  /// Whether AI was ON when the app paused Cloud for [uid].
  Future<bool> aiWasOn(String uid) async {
    if (uid.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key(uid))?.endsWith(_aiSuffix) ?? false;
  }

  Future<bool> shouldShow(String uid, UserSettingsEntity current) async {
    if (uid.isEmpty) return false;
    final prefs = await SharedPreferences.getInstance();
    final recorded = prefs.getString(_key(uid));
    if (recorded == null) return false;
    final choice = recorded.endsWith(_aiSuffix)
        ? recorded.substring(0, recorded.length - _aiSuffix.length)
        : recorded;
    if (!current.cloudProcessingEnabled && choice == _choice(current)) {
      return true;
    }
    // Any later consent decision or a fresh replica ends the old reminder.
    await dismiss(uid);
    return false;
  }

  Future<void> dismiss(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_key(uid))) return;
    await prefs.remove(_key(uid));
    changes.value++;
  }
}
