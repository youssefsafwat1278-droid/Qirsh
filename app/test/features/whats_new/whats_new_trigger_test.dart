import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/whats_new/whats_new_trigger.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Harness {
  _Harness(String running) {
    trigger = WhatsNewTrigger(
      runningVersion: running,
      blockers: [restoring, consent, modal],
      isForeground: () => foreground,
      show: () async {
        shown++;
        return true;
      },
    );
  }

  final restoring = ValueNotifier<bool>(false);
  final consent = ValueNotifier<bool>(false);
  final modal = ValueNotifier<bool>(false);
  bool foreground = true;
  int shown = 0;
  late final WhatsNewTrigger trigger;
}

Future<String?> _stored() async =>
    (await SharedPreferences.getInstance()).getString(kWhatsNewLastSeenKey);

void main() {
  testWidgets('fresh install: no sheet, the running version is stored',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final h = _Harness('1.0.0');
    await h.trigger.start();
    await tester.pump(const Duration(seconds: 5));
    expect(h.shown, 0);
    expect(await _stored(), '1.0.0');
  });

  testWidgets('same version or a downgrade: no sheet', (tester) async {
    for (final seen in ['1.0.0', '1.2.0']) {
      SharedPreferences.setMockInitialValues({kWhatsNewLastSeenKey: seen});
      final h = _Harness('1.0.0');
      await h.trigger.start();
      await tester.pump(const Duration(seconds: 5));
      expect(h.shown, 0, reason: seen);
    }
  });

  testWidgets('after an update: shown once when idle, then never again',
      (tester) async {
    SharedPreferences.setMockInitialValues({kWhatsNewLastSeenKey: '0.9.0'});
    final h = _Harness('1.0.0');
    await h.trigger.start();
    await tester.pump(const Duration(seconds: 5));
    expect(h.shown, 1);
    h.trigger.onResume();
    await tester.pump(const Duration(seconds: 5));
    expect(h.shown, 1);
    expect(await _stored(), '1.0.0');

    // Next launch: the stored version is now current.
    final next = _Harness('1.0.0');
    await next.trigger.start();
    await tester.pump(const Duration(seconds: 5));
    expect(next.shown, 0);
  });

  testWidgets(
      'waits for the restore loader, the consent re-ask and any open sheet',
      (tester) async {
    SharedPreferences.setMockInitialValues({kWhatsNewLastSeenKey: '0.9.0'});
    final h = _Harness('1.0.0');
    h.restoring.value = true;
    h.consent.value = true;
    await h.trigger.start();
    await tester.pump(const Duration(minutes: 1));
    expect(h.shown, 0, reason: 'restore loader and consent are up');

    h.restoring.value = false;
    await tester.pump(const Duration(minutes: 1));
    expect(h.shown, 0, reason: 'the consent sheet is still up');

    h.consent.value = false;
    h.modal.value = true; // e.g. a confirm sheet opened meanwhile
    await tester.pump(const Duration(minutes: 1));
    expect(h.shown, 0, reason: 'another sheet is open');

    h.modal.value = false;
    await tester.pump(const Duration(milliseconds: 500));
    h.consent.value = true; // an ask starts within the settle window
    await tester.pump(const Duration(minutes: 1));
    expect(h.shown, 0, reason: 'never races a sheet about to open');

    h.consent.value = false;
    await tester.pump(const Duration(seconds: 2));
    expect(h.shown, 1);
  });

  testWidgets('never shows in the background; shows on the next resume',
      (tester) async {
    SharedPreferences.setMockInitialValues({kWhatsNewLastSeenKey: '0.9.0'});
    final h = _Harness('1.0.0');
    h.foreground = false;
    await h.trigger.start();
    await tester.pump(const Duration(minutes: 1));
    expect(h.shown, 0);
    h.foreground = true;
    h.trigger.onResume();
    await tester.pump(const Duration(seconds: 2));
    expect(h.shown, 1);
  });

  testWidgets('an unshown sheet stays owed: the version is recorded on show',
      (tester) async {
    SharedPreferences.setMockInitialValues({kWhatsNewLastSeenKey: '0.9.0'});
    final h = _Harness('1.0.0');
    h.restoring.value = true;
    await h.trigger.start();
    await tester.pump(const Duration(seconds: 5));
    h.trigger.dispose(); // app killed behind the loader
    expect(await _stored(), '0.9.0');
  });
}
