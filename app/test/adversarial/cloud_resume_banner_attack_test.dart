import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/cloud_resume_reminder.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/cloud_resume_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/consent/consent_test_harness.dart';

// Adversarial attacks on the dashboard auto-resume (owner decision 2026-11-14:
// a Cloud the APP paused is turned back on automatically, the user's own OFF
// never is). UI wiring over the consent test doubles; the real reconcile ->
// reminder -> enable chain is in cloud_attack_test.dart.

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CloudResumeBannerDebug.reset();
    repo = FakeSettingsRepository();
    repo.settings = repo.settings.copyWith(
        cloudConsentState: ConsentState.declined,
        aiConsentState: ConsentState.accepted,
        cloudConsentVersion: 2);
    service = FakeRegistrationService();
  });

  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pumpWidget(consentApp(
        overrides: consentOverrides(repo, service),
        home: const Scaffold(
            body: SingleChildScrollView(child: CloudResumeBanner()))));
    await tester.pumpAndSettle();
  }

  /// What the capture reconcile does on an app-made pause
  /// (`rec.state == off && on`): save declined, remember with aiWasOn.
  Future<void> appPauses() async {
    repo.settings =
        repo.settings.copyWith(cloudConsentState: ConsentState.declined);
    await CloudResumeReminder()
        .rememberPaused('uid-fake', repo.settings, aiWasOn: true);
  }

  testWidgets(
      '15: a SECOND app-made pause in the same process (e.g. a second > 1 h '
      'expiry while the app stayed suspended) is also resumed automatically',
      (tester) async {
    await appPauses();
    await pumpDashboard(tester);
    expect(service.enableCalls, 1);
    expect(repo.settings.cloudProcessingEnabled, isTrue);
    expect(repo.settings.aiConsentGranted, isTrue);

    // Same process, later: the app pauses Cloud again.
    await appPauses();
    await tester.pumpAndSettle();
    // The second pause is resumed at once (the reminder appears, the
    // dashboard banner re-runs the auto-resume): no OFF is left behind.
    expect(service.enableCalls, 2,
        reason:
            'owner decision: every app-made pause is resumed automatically');
    expect(repo.settings.cloudProcessingEnabled, isTrue);
  });

  testWidgets("extra: account B's dashboard never resumes from A's reminder",
      (tester) async {
    // A (uid-a) was paused by the app; the admitted account is uid-fake (B).
    await CloudResumeReminder()
        .rememberPaused('uid-a', repo.settings, aiWasOn: true);
    await pumpDashboard(tester);
    expect(service.enableCalls, 0);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudProcessingEnabled, isFalse);
    expect(find.byKey(const Key('cloudResumeEnable')), findsNothing);
  });

  testWidgets(
      '16: the user turned Cloud OFF (no reminder) and comes back much later: '
      'never auto-enabled, even across rebuilds', (tester) async {
    await pumpDashboard(tester);
    CloudResumeReminder.changes.value++; // any later revision / rebuild
    await tester.pumpAndSettle();
    await pumpDashboard(tester);
    expect(service.enableCalls, 0);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudProcessingEnabled, isFalse);
  });
}
