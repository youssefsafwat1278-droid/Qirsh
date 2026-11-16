import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/catalog/catalog_daos.dart' show compareAppVersions;

/// Device preference: the last app version whose What's new was handled.
const kWhatsNewLastSeenKey = 'qirsh.whats_new.last_seen_version';

/// Shows the What's new sheet once after an update, never on a fresh install,
/// and only while the shell is idle: no [blockers] up (restore loader, consent
/// re-ask, any open sheet or dialog) and the app in the foreground.
class WhatsNewTrigger {
  WhatsNewTrigger({
    required this.runningVersion,
    required this.blockers,
    required this.isForeground,
    required this.show,
    this.settle = const Duration(seconds: 1),
  });

  final String runningVersion;
  final List<ValueListenable<bool>> blockers;
  final bool Function() isForeground;

  /// Presents the sheet; returns false if there was nothing to show.
  final Future<bool> Function() show;

  /// Idle time required before showing, so a sheet that is about to open
  /// (e.g. consent after its own async checks) is not raced.
  final Duration settle;

  bool _started = false;
  bool _pending = false;
  bool _disposed = false;
  Timer? _timer;

  /// Reads the stored version. A fresh install (nothing stored) just records
  /// the running version; an update arms the sheet.
  Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seen = prefs.getString(kWhatsNewLastSeenKey);
      if (seen == null || compareAppVersions(runningVersion, seen) <= 0) {
        if (seen != runningVersion) {
          await prefs.setString(kWhatsNewLastSeenKey, runningVersion);
        }
        return;
      }
    } catch (_) {
      return; // preferences unavailable: never block anything for this
    }
    if (_disposed) return;
    _pending = true;
    for (final b in blockers) {
      b.addListener(_check);
    }
    _check();
  }

  void onResume() => _check();

  void dispose() {
    _disposed = true;
    _stop();
  }

  bool get _idle => isForeground() && !blockers.any((b) => b.value);

  void _check() {
    _timer?.cancel();
    _timer = null;
    if (!_pending || _disposed || !_idle) return;
    _timer = Timer(settle, () {
      _timer = null;
      if (!_pending || _disposed || !_idle) return;
      _stop();
      unawaited(_present());
    });
  }

  Future<void> _present() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kWhatsNewLastSeenKey, runningVersion);
      await show();
    } catch (_) {}
  }

  void _stop() {
    _pending = false;
    _timer?.cancel();
    _timer = null;
    for (final b in blockers) {
      b.removeListener(_check);
    }
  }
}
