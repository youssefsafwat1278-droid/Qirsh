import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:money_companion/core/theme/app_theme.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';
import 'package:money_companion/l10n/app_localizations.dart';

import 'consent_test_harness.dart';

// Explicit-choice contract (behavioural). The one disclosed first-use choice may
// grant cloud + AI together, but ONLY through its explicit Accept action.
// Rendering, opening, navigating to the terms/privacy pages, dismissing, a lost
// scope and cancelling never grant. First-use "Continue locally" persists a
// denial of both. Management cancel/withdraw is covered with the Privacy screen
// in privacy_consent_management_test.dart.

class _Opener extends ConsumerWidget {
  const _Opener(this.onResult, {this.management = false});
  final ValueChanged<bool> onResult;
  final bool management;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async => onResult(await showSmartAnalysisConsentSheet(
                context, ref,
                management: management)),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  var current = true;
  bool? result;

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
    current = true;
    result = null;
  });

  Future<void> open(WidgetTester tester, {bool management = false}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: consentOverrides(repo, service,
          workSource: () => fakeConsentWork(isCurrent: () => current)),
      child: MaterialApp.router(
        theme: AppTheme.light,
        locale: const Locale('en'),
        supportedLocales: AppL10n.supportedLocales,
        localizationsDelegates: const [
          ...AppL10n.localizationsDelegates,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: GoRouter(routes: [
          GoRoute(
              path: '/',
              builder: (_, __) => _Opener((v) => result = v, management: management)),
          GoRoute(
              path: '/privacy',
              builder: (_, __) => const Scaffold(body: Text('privacy-page'))),
        ]),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void expectNothingGranted() {
    expect(repo.saveCalls, 0);
    expect(service.enableCalls, 0);
    expect(service.syncCalls, 0);
    expect(service.retryCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
  }

  testWidgets('rendering the disclosure grants nothing and pre-selects nothing',
      (tester) async {
    await open(tester);
    expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
    expect(find.byKey(const Key('initialConsentDecline')), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Checkbox), findsNothing);
    expectNothingGranted();
  });

  testWidgets('opening the privacy page from the disclosure grants nothing',
      (tester) async {
    await open(tester);
    await tester.ensureVisible(find.text(lookupAppL10n(const Locale('en')).smartConsentPrivacyLink));
    await tester.tap(find.text(lookupAppL10n(const Locale('en')).smartConsentPrivacyLink));
    await tester.pumpAndSettle();
    expect(find.text('privacy-page'), findsOneWidget);
    expectNothingGranted();
  });

  testWidgets('dismissing the disclosure grants nothing', (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(400, 20));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('initialConsentAccept')), findsNothing);
    expect(result, isFalse);
    expectNothingGranted();
  });

  testWidgets('first-use "Continue locally" persists a denial of BOTH and '
      'enables nothing', (tester) async {
    await open(tester);
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentDecline')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expect(repo.saveCalls, 1);
    expect(repo.lastChoices!.cloud, ConsentState.declined);
    expect(repo.lastChoices!.ai, ConsentState.declined);
    expect(repo.settings.cloudConsentState, ConsentState.declined);
    expect(repo.settings.aiConsentState, ConsentState.declined);
    expect(service.enableCalls, 0);
    expect(service.syncCalls, 0);
  });

  testWidgets('only the explicit Accept grants cloud and AI together',
      (tester) async {
    await open(tester);
    expectNothingGranted();
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(result, isTrue);
    expect(service.enableCalls, 1);
    expect(repo.lastChoices!.cloud, ConsentState.accepted);
    expect(repo.lastChoices!.ai, ConsentState.accepted);
  });

  testWidgets('a management disclosure has no denial action; its cancel '
      'writes nothing', (tester) async {
    await open(tester, management: true);
    expect(find.byKey(const Key('initialConsentDecline')), findsNothing);
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('consentManageCancel')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('consentManageCancel')));
    await tester.pumpAndSettle();
    expect(result, isFalse);
    expectNothingGranted();
  });

  testWidgets('accept after the account changed grants nothing in the new '
      'scope', (tester) async {
    await open(tester);
    current = false;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(result, isNot(isTrue));
    expectNothingGranted();
  });

  testWidgets('decline after the account changed writes nothing',
      (tester) async {
    await open(tester);
    current = false;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentDecline')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await tester.pumpAndSettle(const Duration(seconds: 6));
    expect(result, isNot(isTrue));
    expectNothingGranted();
  });

  test('the combined-grant label is not rendered by any consent surface', () {
    for (final path in [
      'lib/features/onboarding/onboarding_consent_steps.dart',
      'lib/features/consent/smart_analysis_consent_sheet.dart',
    ]) {
      final src = File(path).readAsStringSync();
      expect(src.contains('onbAiEnableBoth'), isFalse, reason: path);
      expect(src.contains('onbAiNeedsCloud'), isFalse, reason: path);
      expect(src.contains('smartConsentEnable'), isFalse, reason: path);
    }
  });

  test('the Privacy screen renders no daily cloud/AI switch and grants only '
      'through the disclosure', () {
    final src =
        File('lib/features/settings/privacy_screen.dart').readAsStringSync();
    expect(src, contains('showSmartAnalysisConsentSheet('));
    expect(RegExp(r'ConsentState\.accepted').hasMatch(src), isFalse,
        reason: 'the screen never writes an accept itself');
  });
}
