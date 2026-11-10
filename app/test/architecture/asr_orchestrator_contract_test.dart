import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ASR v7.2 WP7 (§8–§11): source pins for the orchestrator's wiring. The
/// behaviour is covered by test/core/startup/automatic_session_recovery_test;
/// these keep the invariants from drifting through a later edit.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final asr = read('lib/core/startup/automatic_session_recovery.dart');
  final session = read('lib/core/session/app_session.dart');
  final bootstrap = read('lib/core/startup/bootstrap_runner.dart');
  final registration = read(
      'lib/features/capture/services/capture_device_registration_service.dart');

  Iterable<File> libFiles() => Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  test('only the orchestrator installs, finalizes or completes an ASR adoption',
      () {
    for (final f in libFiles()) {
      final p = f.path.replaceAll('\\', '/');
      if (p == 'lib/core/auth/auth_coordinator.dart' ||
          p == 'lib/core/startup/automatic_session_recovery.dart') {
        continue;
      }
      final s = f.readAsStringSync();
      for (final call in [
        '.installForAsr(',
        '.writeFinalizing(',
        '.completeAdoption(',
      ]) {
        expect(s.contains(call), isFalse, reason: '$p calls $call');
      }
    }
  });

  test('B4: own-cause attribution is explicit, never ambient', () {
    for (final f in libFiles()) {
      final p = f.path.replaceAll('\\', '/');
      final src = f.readAsStringSync();
      expect(src.contains('runAsCauseAuthority'), isFalse, reason: p);
      expect(src.contains('_causeAuthorityKey'), isFalse, reason: p);
    }
    final gate =
        File('lib/core/privacy/cloud_egress_gate.dart').readAsStringSync();
    final note = RegExp(r'void noteCause\([^)]*\) \{([\s\S]*?)\n  \}')
        .firstMatch(gate)!
        .group(1)!;
    expect(note.contains('Zone'), isFalse);
    // The enumerated owned transitions: the ASR admission's scope init, SE1,
    // and the successor chain (SE2–SE5) — each names its authority.
    final boot =
        File('lib/core/startup/bootstrap_runner.dart').readAsStringSync();
    expect(
        boot.contains('EpochCause.scopeInit, '
            '_host?.initializingAuthority?.causeAuthority)'),
        isTrue);
    expect(boot.contains('successorCauseAuthority: successor?.causeAuthority'),
        isTrue);
    expect(asr.contains('causeAuthority: ctx.authority'), isTrue);
    final reg = File(
            'lib/features/capture/services/capture_device_registration_service.dart')
        .readAsStringSync();
    expect(reg.contains('_gate.freezeEnable(owner, authority: causeAuthority)'),
        isTrue);
    expect(RegExp(r'causeAuthority: s\.causeAuthority').allMatches(reg).length,
        4);
  });

  test('the orchestrator refreshes only through an ASR op, never installing',
      () {
    final refresh = RegExp(r'runRefresh\(RefreshOpSpec\(([\s\S]*?)\)\);')
        .allMatches(asr)
        .toList();
    expect(refresh, hasLength(1));
    final spec = refresh.single.group(1)!;
    expect(spec, contains('kind: RefreshOpKind.asr'));
    expect(spec, contains('install: false'));
    expect(spec, contains('preAdmit: () => native.confirm(evidence.counter)'));
    expect(spec, contains('preSend: () => native.confirm(evidence.counter)'));
    expect(asr, isNot(contains('.auth.refreshSession(')));
    expect(asr, isNot(contains('.auth.setSession(')));
  });

  test('the orchestrator logs no identifiers or session material', () {
    for (final sink in ['print(', 'debugPrint(', 'log(', 'Sentry.']) {
      expect(asr.contains(sink), isFalse, reason: sink);
    }
  });

  test('generic capture reconcile is blocked while a transition hold is up',
      () {
    final at = registration.indexOf('Future<_Gate> _reconcile({');
    expect(at, greaterThan(-1));
    final head = registration.substring(at, at + 1000);
    expect(head, contains('if (_gate.holdActive) return _Gate.blocked;'));
    expect(head, contains('if (_gate.successorUnsettled) return _Gate.blocked;'));
  });

  test('only a non-expiry, non-adoption loss invalidates expiry evidence', () {
    final at = session.indexOf('void markSessionInvalid(');
    expect(at, greaterThan(-1));
    final body = session.substring(at, session.indexOf('\n  }\n', at));
    expect(
        body,
        matches(RegExp(
            r'if \(cause == SessionLossCause\.other\)[\s\S]*_invalidateAsrEvidence\(\)')));
    // The expired branch revokes with expiry evidence and keeps it.
    expect(session, contains('_revokeConsentProof(expiry: true)'));
    expect(session,
        contains('markSessionInvalid(cause: SessionLossCause.sessionExpiry)'));
  });

  test('an explicit attempt preempts a running ASR op', () {
    final at = session.indexOf('beginAuthAttempt(');
    expect(at, greaterThan(-1));
    expect(session.substring(at, at + 1200),
        contains('AutomaticSessionRecovery.active?.yieldToExplicitAttempt()'));
  });

  test('ASR starts only resumed; real background states latch loss while inactive may finish adoption',
      () {
    final at = bootstrap.indexOf('class _AsrLifecycleObserver');
    expect(at, greaterThan(-1));
    final body = bootstrap.substring(at);
    expect(body, contains('AppLifecycleState.resumed'));
    expect(body, contains('AppLifecycleState.paused'));
    expect(body, contains('AppLifecycleState.hidden'));
    expect(body, contains('AppLifecycleState.detached'));
    expect(body, contains('AppLifecycleState.inactive'));
    final cases = body.substring(0, body.indexOf('\n}'));
    expect(
        RegExp(r'case AppLifecycleState\.paused:'
                r'\s*case AppLifecycleState\.hidden:\s*case AppLifecycleState\.detached:'
                r'\s*asr\.onBackground\(\);')
            .hasMatch(cases),
        isTrue);
    final inactive = cases.substring(cases.indexOf('case AppLifecycleState.inactive:'),
        cases.indexOf('case AppLifecycleState.paused:'));
    expect(inactive, contains('break;'));
    expect(inactive, isNot(contains('asr.onBackground()')));
    expect(asr, contains('(accepted ? host.foreground : host.resumed)'));
    expect(
        asr,
        contains('authority.mayContinue = false;\n'
            "    coordinator.cancelActive('background');"));
    expect(asr, contains('acceptPredicate: () => authority.mayContinue && host.resumed'));
  });
}
