import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

class _Opener extends ConsumerWidget {
  const _Opener(this.onResult);
  final ValueChanged<bool> onResult;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async =>
                onResult(await showSmartAnalysisConsentSheet(context, ref)),
            child: const Text('open'),
          ),
        ),
      );
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  bool? result;

  Future<void> open(WidgetTester tester,
      {String locale = 'en', bool cloudOn = false}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo = FakeSettingsRepository();
    if (cloudOn) {
      repo.settings =
          repo.settings.copyWith(cloudConsentState: ConsentState.accepted);
    }
    service = FakeRegistrationService();
    result = null;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Opener((v) => result = v),
      locale: locale,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  void expectUntouched() {
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
  }

  for (final locale in ['en', 'ar']) {
    testWidgets('one disclosed choice remains ungranted until accepted ($locale)', (tester) async {
      await open(tester, locale: locale);
      expectUntouched();
      expect(find.byType(Switch), findsNothing);
      expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
      expect(find.byKey(const Key('initialConsentDecline')), findsOneWidget);
      expect(find.textContaining('Google Gemini'), findsOneWidget);
      // The full disclosure is long: scroll to the action first.
      await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('initialConsentAccept')));
      await tester.pumpAndSettle();
      expect(repo.settings.cloudConsentState, ConsentState.accepted);
      expect(repo.settings.aiConsentState, ConsentState.accepted);
      expect(service.retryCalls, 1);
      expect(result, isTrue);
    });
  }

  testWidgets('decline persists both denials and returns local use', (tester) async {
    await open(tester);
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentDecline')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.declined);
    expect(repo.settings.aiConsentState, ConsentState.declined);
    expect(service.retryCalls, 0);
    expect(result, isFalse);
  });

  testWidgets('save failure grants nothing and does not complete', (tester) async {
    await open(tester);
    repo.failSave = true;
    // The full disclosure is long: scroll to the action first.
    await tester.ensureVisible(find.byKey(const Key('initialConsentAccept')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('initialConsentAccept')));
    await tester.pumpAndSettle();
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
    expect(result, isNull);
    await tester.pumpAndSettle(const Duration(seconds: 6));
  });

  testWidgets('dismissing the sheet changes nothing and returns false',
      (tester) async {
    await open(tester);
    await tester.tapAt(const Offset(10, 10)); // barrier
    await tester.pumpAndSettle();
    expectUntouched();
    expect(result, isFalse);
  });
}
