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

  setUp(() {
    restoring = ValueNotifier(false);
    calls = [];
    trigger = ConsentReaskTrigger(
      restoring: restoring,
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
}
