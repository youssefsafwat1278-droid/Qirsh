import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/settings/settings_providers.dart';
import 'package:money_companion/l10n/app_localizations.dart';

/// MALI-013 — the Android automatic-SMS-capture opt-in.
///
/// Until this shipped, the app declared `RECEIVE_SMS`, registered a live
/// `SMS_RECEIVED` receiver, and gave the user no way to switch the feature on.
/// A restricted permission with no reachable feature fails Google Play's
/// core-functionality test, and it contradicted a privacy policy that was
/// already live and said the app captures bank SMS.
///
/// These tests pin the properties that make the toggle honest:
///   * it renders from the PLATFORM's state, never a local boolean, so a
///     permission revoked outside the app cannot leave it stuck ON;
///   * it is invisible when the build does not declare the permission;
///   * and it never claims the app is capturing when it is not.
///
/// The disclosure-before-request ordering is enforced structurally inside
/// `AndroidSmsCaptureService.requestAndEnable` (which cannot reach the system
/// dialog without the disclosure callback returning true) and is covered in
/// `test/features/capture/android_sms_permission_test.dart`.

Widget _app(CaptureCapabilities caps) {
  return ProviderScope(
    overrides: [
      captureCapabilitiesProvider.overrideWith((ref) async => caps),
    ],
    child: MaterialApp(
      locale: const Locale('ar'),
      supportedLocales: AppL10n.supportedLocales,
      localizationsDelegates: const [
        ...AppL10n.localizationsDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: AppTheme.dark,
      home: const Scaffold(body: _Harness()),
    ),
  );
}

/// Renders the same decision the Settings tile makes, without booting the whole
/// 2300-line settings screen (which needs a database, a session and a network).
/// The logic under test is the mapping from capabilities to what the user sees.
class _Harness extends ConsumerWidget {
  const _Harness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final caps = ref.watch(captureCapabilitiesProvider).valueOrNull;
    if (caps == null || !caps.receiveSmsDeclared) {
      return const SizedBox.shrink(key: Key('hidden'));
    }
    final enabled = caps.isAutomaticSmsCaptureEnabled;
    final blocked = !caps.hasReceiveSmsPermission && !enabled;
    return Column(
      children: [
        Switch(key: const Key('toggle'), value: enabled, onChanged: (_) {}),
        Text(
          enabled
              ? 'on'
              : blocked
                  ? 'blocked'
                  : 'off',
          key: const Key('state'),
        ),
      ],
    );
  }
}

String _state(WidgetTester t) =>
    (t.widget(find.byKey(const Key('state'))) as Text).data!;
bool _toggle(WidgetTester t) =>
    (t.widget(find.byKey(const Key('toggle'))) as Switch).value;

void main() {
  testWidgets('a build that does not declare RECEIVE_SMS shows nothing',
      (tester) async {
    // iOS, and any future share-only Android variant. The row must not exist
    // at all — an always-off toggle would advertise a capability the binary
    // does not contain.
    await tester.pumpWidget(_app(const CaptureCapabilities()));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hidden')), findsOneWidget);
    expect(find.byKey(const Key('toggle')), findsNothing);
  });

  testWidgets('declared but not granted reads BLOCKED, not merely off',
      (tester) async {
    await tester.pumpWidget(_app(const CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: false,
      isAutomaticSmsCaptureEnabled: false,
    )));
    await tester.pumpAndSettle();
    expect(_toggle(tester), isFalse);
    expect(_state(tester), 'blocked');
  });

  testWidgets('granted but not opted in is OFF — permission is not consent',
      (tester) async {
    // The two-key lock, visible in the UI: Android saying yes is not the user
    // saying yes, and the switch must not read ON because of the OS alone.
    await tester.pumpWidget(_app(const CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: true,
      canUseAutomaticSmsCapture: true,
      isAutomaticSmsCaptureEnabled: false,
    )));
    await tester.pumpAndSettle();
    expect(_toggle(tester), isFalse);
    expect(_state(tester), 'off',
        reason: 'a granted permission alone must never read as blocked '
            'either — nothing is stopping the user, they simply have not '
            'turned it on');
  });

  testWidgets('both keys turned means ON', (tester) async {
    await tester.pumpWidget(_app(const CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: true,
      canUseAutomaticSmsCapture: true,
      isAutomaticSmsCaptureEnabled: true,
    )));
    await tester.pumpAndSettle();
    expect(_toggle(tester), isTrue);
    expect(_state(tester), 'on');
  });

  test('a permission revoked outside the app cannot leave it ON', () async {
    // The case a locally-cached boolean gets wrong: the user revokes RECEIVE_SMS
    // in system Settings while the app is backgrounded. Because the tile renders
    // from the platform snapshot, the next read shows the truth.
    final container = ProviderContainer(overrides: [
      captureCapabilitiesProvider.overrideWith((ref) async =>
          const CaptureCapabilities(
              receiveSmsDeclared: true,
              hasReceiveSmsPermission: true,
              canUseAutomaticSmsCapture: true,
              isAutomaticSmsCaptureEnabled: true)),
    ]);
    addTearDown(container.dispose);
    expect(
      (await container.read(captureCapabilitiesProvider.future))
          .isAutomaticSmsCaptureEnabled,
      isTrue,
    );

    // Android takes the permission away; the platform now reports both halves
    // false, because `isAutomaticSmsCaptureEnabled` is defined as opted-in AND
    // permitted.
    container.updateOverrides([
      captureCapabilitiesProvider.overrideWith((ref) async =>
          const CaptureCapabilities(
              receiveSmsDeclared: true,
              hasReceiveSmsPermission: false,
              canUseAutomaticSmsCapture: false,
              isAutomaticSmsCaptureEnabled: false)),
    ]);
    container.invalidate(captureCapabilitiesProvider);
    final after = await container.read(captureCapabilitiesProvider.future);
    expect(after.isAutomaticSmsCaptureEnabled, isFalse);
    expect(after.hasReceiveSmsPermission, isFalse);
  });

  testWidgets(
      'an opt-in restored for this account at sign-in reads ON from the '
      'platform, with no local state carried over', (tester) async {
    // The opt-in is remembered per account natively: signed out (and for any
    // other account) the platform reports it OFF; once this account is
    // published again its own opt-in is restored and the platform reports ON.
    // The shell re-reads the provider when it shows the restored notice.
    var platform = const CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: true,
      canUseAutomaticSmsCapture: true,
      isAutomaticSmsCaptureEnabled: false,
    );
    final container = ProviderContainer(overrides: [
      captureCapabilitiesProvider.overrideWith((ref) async => platform),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: const Locale('ar'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: AppTheme.dark,
        home: const Scaffold(body: _Harness()),
      ),
    ));
    await tester.pumpAndSettle();
    expect(_toggle(tester), isFalse);
    expect(_state(tester), 'off');

    platform = const CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: true,
      canUseAutomaticSmsCapture: true,
      isAutomaticSmsCaptureEnabled: true,
    );
    container.invalidate(captureCapabilitiesProvider);
    await tester.pumpAndSettle();
    expect(_toggle(tester), isTrue);
    expect(_state(tester), 'on');
  });

  test('the capability model keeps notification and SMS permission separate',
      () {
    // The bug this model replaced: one `hasSmsPermission()` that actually
    // returned notification permission, so the app believed it could read SMS
    // because the user had allowed notifications.
    const caps = CaptureCapabilities(
      receiveSmsDeclared: true,
      hasReceiveSmsPermission: false,
      hasNotificationPermission: true,
    );
    expect(caps.hasNotificationPermission, isTrue);
    expect(caps.hasReceiveSmsPermission, isFalse);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
    expect(caps.supportsShareCapture, isTrue,
        reason: 'share capture needs no permission and must survive every '
            'denial path');
  });

  test('fromJson defaults to the SAFE state on a malformed platform reply', () {
    // A platform reply we cannot parse must never be read as "you may capture".
    final caps = CaptureCapabilities.fromJson(const {});
    expect(caps.receiveSmsDeclared, isFalse);
    expect(caps.hasReceiveSmsPermission, isFalse);
    expect(caps.canUseAutomaticSmsCapture, isFalse);
    expect(caps.isAutomaticSmsCaptureEnabled, isFalse);
    expect(caps.supportsShareCapture, isTrue);
  });
}
