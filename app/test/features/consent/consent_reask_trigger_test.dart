import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/consent/consent_reask_trigger.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

// F1 (2026-11-16): after a reinstall the "Restore your cloud data" sheet is the
// only way Cloud comes back. If it was swiped away (or the app was
// backgrounded before an answer) it was only offered again after a restart.

void main() {
  late ValueNotifier<bool> restoring;
  late List<Completer<ReaskOutcome>> calls;
  late ConsentReaskTrigger trigger;
  late bool foreground;

  void goBackground() {
    foreground = false;
    trigger.onBackground();
  }

  void goForeground() {
    foreground = true;
    trigger.onResume();
  }

  setUp(() {
    restoring = ValueNotifier(false);
    calls = [];
    foreground = true;
    trigger = ConsentReaskTrigger(
      restoring: restoring,
      isForeground: () => foreground,
      ask: () {
        final c = Completer<ReaskOutcome>();
        calls.add(c);
        return c.future;
      },
    );
  });
  tearDown(() => trigger.dispose());

  test(
      'F1 regression: a dismissed sheet is offered again on resume, in the '
      'same process (no restart)', () async {
    trigger.start();
    expect(calls, hasLength(1));
    // Swipe-dismissed: shown, but no answer recorded.
    calls.single.complete(ReaskOutcome.shown);
    await pumpEventQueue();

    trigger.onResume();
    expect(calls, hasLength(2), reason: 'the restore offer must come back');
  });

  test('never a second sheet while one is open', () async {
    trigger.start();
    trigger.onResume();
    trigger.onResume();
    trigger.onAuthenticated();
    expect(calls, hasLength(1));
  });

  test('never asks behind the restore loader; one ask when it closes',
      () async {
    restoring.value = true;
    trigger.start();
    trigger.onResume();
    expect(calls, isEmpty);
    restoring.value = false;
    expect(calls, hasLength(1));
    restoring.value = true;
    restoring.value = false;
    expect(calls, hasLength(1), reason: 'the gate listener is single-use');
  });

  testWidgets(
      'an answered "Not now" is respected: the re-ask itself returns '
      'notNeeded and nothing else is scheduled', (tester) async {
    trigger.start();
    calls.single.complete(ReaskOutcome.notNeeded);
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(calls, hasLength(1), reason: 'no timer-driven re-ask');
  });

  testWidgets(
      "account change: a sheet still open is not stacked; the old "
      "account's late answer schedules nothing; the new account is asked "
      'once it closes', (tester) async {
    trigger.start();
    final old = calls.single;
    trigger.onSignedOut();
    trigger.onAuthenticated();
    expect(calls, hasLength(1), reason: 'never two sheets at once');
    old.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    expect(calls, hasLength(2), reason: 'the new account is asked');
    calls.last.complete(ReaskOutcome.shown);
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));
    expect(calls, hasLength(2),
        reason: "the old account's outcome must not schedule a retry");
  });

  testWidgets('signed out with a sheet open: nothing is asked when it closes',
      (tester) async {
    trigger.start();
    trigger.onSignedOut();
    calls.single.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));
    trigger.onResume();
    expect(calls, hasLength(1));
  });

  test('signed out: a pending gate listener is dropped and nothing asks', () {
    restoring.value = true;
    trigger.start();
    trigger.onSignedOut();
    restoring.value = false;
    expect(calls, isEmpty);
  });

  testWidgets(
      'F2: an unknown server choice is retried while in the foreground, '
      'with a bounded backoff', (tester) async {
    trigger.start();
    calls.last.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    await tester.pump(const Duration(seconds: 15));
    expect(calls, hasLength(2));
    calls.last.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    await tester.pump(const Duration(seconds: 60));
    expect(calls, hasLength(3));
    calls.last.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    await tester.pump(const Duration(minutes: 30));
    expect(calls, hasLength(3), reason: 'then only on resume');
    trigger.onResume();
    expect(calls, hasLength(4));
  });

  testWidgets('F2: a resume during the backoff asks once and cancels the timer',
      (tester) async {
    trigger.start();
    calls.last.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    trigger.onResume();
    expect(calls, hasLength(2));
    calls.last.complete(ReaskOutcome.shown);
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));
    expect(calls, hasLength(2));
  });

  testWidgets('dispose cancels everything', (tester) async {
    trigger.start();
    calls.last.complete(ReaskOutcome.unknownPreference);
    await tester.pump();
    trigger.dispose();
    await tester.pump(const Duration(minutes: 5));
    trigger.onResume();
    expect(calls, hasLength(1));
  });

  group('foreground only', () {
    testWidgets('not started while in the background; asked on resume',
        (tester) async {
      foreground = false;
      trigger.start();
      expect(calls, isEmpty);
      goForeground();
      expect(calls, hasLength(1));
    });

    testWidgets('backgrounded during the F2 backoff: the retry never starts '
        'off-screen, and the resume asks exactly once', (tester) async {
      trigger.start();
      calls.single.complete(ReaskOutcome.unknownPreference);
      await tester.pump();
      goBackground();
      await tester.pump(const Duration(minutes: 5));
      expect(calls, hasLength(1), reason: 'no retry while in the background');
      goForeground();
      expect(calls, hasLength(2));
      goForeground();
      expect(calls, hasLength(2), reason: 'one sheet at a time');
    });

    testWidgets('backgrounded during an in-flight read: the deferred outcome '
        'starts nothing; the resume asks once', (tester) async {
      trigger.start();
      goBackground();
      calls.single.complete(ReaskOutcome.deferred);
      await tester.pump();
      await tester.pump(const Duration(minutes: 5));
      expect(calls, hasLength(1));
      goForeground();
      expect(calls, hasLength(2));
      calls.last.complete(ReaskOutcome.shown);
      await tester.pump();
      expect(calls, hasLength(2));
    });

    testWidgets('resumed again before the in-flight read returns: no second '
        'ask, the running one presents', (tester) async {
      trigger.start();
      goBackground();
      goForeground();
      expect(calls, hasLength(1), reason: 'never a duplicate sheet');
      calls.single.complete(ReaskOutcome.shown);
      await tester.pump();
      await tester.pump(const Duration(minutes: 5));
      expect(calls, hasLength(1));
    });

    testWidgets('the restore loader closes while in the background: nothing '
        'is asked until the resume', (tester) async {
      restoring.value = true;
      trigger.start();
      goBackground();
      restoring.value = false;
      expect(calls, isEmpty);
      goForeground();
      expect(calls, hasLength(1));
    });
  });
}
