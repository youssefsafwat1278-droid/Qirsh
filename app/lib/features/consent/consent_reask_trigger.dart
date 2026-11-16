import 'dart:async';

import 'package:flutter/foundation.dart';

import 'smart_analysis_consent_sheet.dart';

/// Decides WHEN the main shell runs [maybeReaskConsent]: never behind the root
/// restore loader ([restoring]), never two at once, and never for an account
/// that is no longer the admitted one.
///
/// F1 (2026-11-16): a sheet that was swiped away, or left by backgrounding
/// before an answer, records nothing, so [maybeReaskConsent] offers it again.
/// That used to happen only on the next launch; it now also happens on resume
/// and when an account is admitted while the shell is mounted. An answer
/// ("Restore" or "Not now") is recorded by [maybeReaskConsent] itself, which
/// then returns [ReaskOutcome.notNeeded]: nothing here overrides it.
///
/// F2: when the account's server choice could not be read
/// ([ReaskOutcome.unknownPreference]) it is retried after [retryDelays] while
/// the app stays in the foreground, then on each resume.
///
/// Foreground only: nothing starts while [isForeground] is false, leaving the
/// foreground ([onBackground]) cancels a waiting retry and the loader gate, and
/// the next [onResume] asks again. An ask that was already running when the
/// app left is not duplicated: [maybeReaskConsent] rechecks the foreground
/// before it presents and reports [ReaskOutcome.deferred] instead.
class ConsentReaskTrigger {
  ConsentReaskTrigger({
    required this.restoring,
    required this.ask,
    required this.isForeground,
    this.retryDelays = const [Duration(seconds: 15), Duration(seconds: 60)],
  });

  /// True while the root restore loader is up.
  final ValueListenable<bool> restoring;

  /// One re-ask attempt (the shell binds it to its context and ref).
  final Future<ReaskOutcome> Function() ask;

  /// True while the app is resumed (visible and interactive).
  final bool Function() isForeground;

  /// Backoff for an unknown server choice before falling back to resume.
  final List<Duration> retryDelays;

  VoidCallback? _gate;
  Timer? _retry;
  bool _inFlight = false;
  bool _disposed = false;
  bool _authenticated = false;
  int _unknownRetries = 0;

  /// Bumped on every account transition: an attempt started under an older
  /// generation never schedules anything.
  int _generation = 0;

  /// The shell is mounted with an authenticated session.
  void start() {
    _authenticated = true;
    _schedule();
  }

  /// The app came back to the foreground.
  void onResume() {
    _unknownRetries = 0;
    _schedule();
  }

  /// The app left the foreground (inactive, hidden or paused).
  void onBackground() {
    _retry?.cancel();
    _retry = null;
    _dropGate();
  }

  /// A (possibly different) account was admitted while the shell is mounted.
  /// A sheet still open for the previous lifecycle is never stacked: the new
  /// account is asked once it closes, and its outcome is ignored.
  void onAuthenticated() {
    _reset();
    _authenticated = true;
    _schedule();
  }

  /// The session left the authenticated state.
  void onSignedOut() {
    _reset();
    _authenticated = false;
  }

  void dispose() {
    _disposed = true;
    _reset();
  }

  void _reset() {
    _generation++;
    _unknownRetries = 0;
    _retry?.cancel();
    _retry = null;
    _dropGate();
  }

  void _schedule() {
    if (_disposed || !_authenticated || _inFlight || _gate != null) return;
    if (!isForeground()) return;
    _retry?.cancel();
    _retry = null;
    if (!restoring.value) {
      _run();
      return;
    }
    void onChange() {
      if (restoring.value) return;
      _dropGate();
      _run();
    }

    _gate = onChange;
    restoring.addListener(onChange);
  }

  void _run() {
    if (_disposed || _inFlight || !isForeground()) return;
    final generation = _generation;
    _inFlight = true;
    void settled() {
      _inFlight = false;
      // An attempt of an older lifecycle: ignore its outcome, then ask for
      // the account admitted meanwhile.
      if (generation != _generation) _schedule();
    }

    ask().then((outcome) {
      settled();
      if (_disposed || generation != _generation) return;
      if (outcome != ReaskOutcome.unknownPreference) return;
      if (_unknownRetries >= retryDelays.length) return;
      _retry = Timer(retryDelays[_unknownRetries++], () {
        _retry = null;
        if (!_disposed && generation == _generation) _schedule();
      });
    }, onError: (Object _) => settled());
  }

  void _dropGate() {
    final gate = _gate;
    if (gate != null) restoring.removeListener(gate);
    _gate = null;
  }
}
