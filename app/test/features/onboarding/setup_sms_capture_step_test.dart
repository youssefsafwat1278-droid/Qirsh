import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/onboarding/setup_screen.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

import '../consent/consent_test_harness.dart';
import 'setup_consent_step_test.dart' show SpyAccountRepo;

/// The last setup step is platform-specific: iOS installs the Qirsh Shortcut;
/// Android has no Shortcuts app and instead offers the automatic bank-SMS
/// capture opt-in (the same flow as the Settings switch). It is optional:
/// "Not now" completes setup with capture off.
void main() {
  const declared = CaptureCapabilities(receiveSmsDeclared: true);
  const enabled = CaptureCapabilities(
    receiveSmsDeclared: true,
    hasReceiveSmsPermission: true,
    canUseAutomaticSmsCapture: true,
    isAutomaticSmsCaptureEnabled: true,
  );

  Future<void> pumpLastStep(
    WidgetTester tester, {
    CaptureCapabilities caps = declared,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 2200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final repo = FakeSettingsRepository();
    final accounts = SpyAccountRepo();
    final now = DateTime.utc(2026, 11, 12);
    accounts.accounts.add(AccountEntity(
      id: 'a1',
      name: 'Main',
      currency: 'SAR',
      type: AccountType.bank,
      isDefault: true,
      sortOrder: 0,
      createdAt: now,
      updatedAt: now,
    ));
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, FakeRegistrationService()),
        accountRepositoryProvider.overrideWithValue(accounts),
        captureCapabilitiesProvider.overrideWith((ref) async => caps),
      ],
      home: const OnboardingSetupScreen(
          entry: OnboardingSetupEntry.captureGuide),
    ));
    await tester.pumpAndSettle();
  }

  FilledButton finishButton(WidgetTester tester) => tester.widget<FilledButton>(
      find.ancestor(of: find.text('Start'), matching: find.byType(FilledButton)));

  testWidgets('Android: the last step is SMS capture, not the Shortcut',
      (tester) async {
    await pumpLastStep(tester);
    expect(find.text('Step 6 of 6'), findsOneWidget);
    expect(find.text('Automatic bank-SMS capture'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsOneWidget);
    expect(find.text('Not Now'), findsOneWidget);
    expect(find.text('Install the Qirsh Shortcut'), findsNothing);
    expect(find.text('Installed'), findsNothing);
    expect(finishButton(tester).onPressed, isNull);
  });

  testWidgets('Android: "Not now" completes setup with capture left off',
      (tester) async {
    await pumpLastStep(tester);
    await tester.tap(find.byKey(const ValueKey('setup-sms-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsNothing);
    expect(finishButton(tester).onPressed, isNotNull);
  });

  testWidgets('Android: a declined or unavailable request does not complete '
      'the step', (tester) async {
    // On the test host the platform request is unsupported, like a decline.
    await pumpLastStep(tester);
    await tester.tap(find.byKey(const ValueKey('setup-sms-enable')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsOneWidget);
    expect(finishButton(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Android: already on (e.g. restored for this account) shows it '
      'as on and offers Continue', (tester) async {
    await pumpLastStep(tester, caps: enabled);
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsNothing);
    expect(find.text('On — incoming bank messages are read on your device'),
        findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(finishButton(tester).onPressed, isNotNull);
  });

  testWidgets('Android: a build without the SMS permission offers no enable '
      'button but can still finish', (tester) async {
    await pumpLastStep(tester,
        caps: const CaptureCapabilities(receiveSmsDeclared: false));
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsNothing);
    expect(find.text('Install the Qirsh Shortcut'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('setup-sms-skip')));
    await tester.pumpAndSettle();
    expect(finishButton(tester).onPressed, isNotNull);
  });

  testWidgets('iOS keeps the Shortcut step and never shows SMS capture',
      (tester) async {
    await pumpLastStep(tester);
    expect(find.text('Install the Qirsh Shortcut'), findsOneWidget);
    expect(find.text('Automatic bank-SMS capture'), findsNothing);
    expect(find.byKey(const ValueKey('setup-sms-enable')), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
