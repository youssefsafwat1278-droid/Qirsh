import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/privacy/shared_learning_preference.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

/// Decision 3.10 transition: shared learning was not in the in-app consent
/// that existing users accepted (no consent version existed; the disclosure
/// never mentioned it). An update therefore leaves it OFF and asks once.
class _Host extends ConsumerStatefulWidget {
  const _Host(this.onOutcome);
  final void Function(ReaskOutcome) onOutcome;
  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeReaskConsent(
            context, ref,
            seen: () async => true,
            markSeen: () async {},
            readChoice: () async => AccountCloudChoice.on)
        .then(widget.onOutcome));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

void main() {
  late FakeSettingsRepository repo;
  late Map<String, String> prefs;
  ReaskOutcome? outcome;
  final key = SharedLearningPreference.keyFor('uid-fake');

  Future<void> pump(WidgetTester tester, ConsentState cloud, ConsentState ai,
      {String locale = 'en'}) async {
    await tester.binding.setSurfaceSize(const Size(800, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    repo.settings =
        repo.settings.copyWith(cloudConsentState: cloud, aiConsentState: ai);
    outcome = null;
    await tester.pumpWidget(const SizedBox()); // a fresh host every time
    await tester.pumpWidget(consentApp(
      overrides: [
        ...consentOverrides(repo, FakeRegistrationService()),
        sharedLearningPreferenceProvider
            .overrideWithValue(SharedLearningPreference.memory(prefs)),
      ],
      home: _Host((o) => outcome = o),
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    repo = FakeSettingsRepository();
    prefs = {};
  });

  for (final locale in ['en', 'ar']) {
    testWidgets('$locale: an earlier consent is asked once; agreeing records ON',
        (tester) async {
      await pump(tester, ConsentState.accepted, ConsentState.accepted,
          locale: locale);
      expect(find.byKey(const Key('sharedLearningUpdateAgree')), findsOneWidget);
      expect(prefs, isEmpty, reason: 'nothing assumed while the question is open');
      await tester.ensureVisible(find.byKey(const Key('sharedLearningUpdateAgree')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('sharedLearningUpdateAgree')));
      await tester.pumpAndSettle();
      expect(prefs, {key: 'on'});
      expect(outcome, ReaskOutcome.shown);
      expect(repo.saveCalls, 0, reason: 'Cloud and AI choices are untouched');
    });
  }

  testWidgets('Keep it off records OFF and is not asked again', (tester) async {
    await pump(tester, ConsentState.accepted, ConsentState.accepted);
    await tester.ensureVisible(find.byKey(const Key('sharedLearningUpdateKeepOff')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('sharedLearningUpdateKeepOff')));
    await tester.pumpAndSettle();
    expect(prefs, {key: 'off'});
    await pump(tester, ConsentState.accepted, ConsentState.accepted);
    expect(find.byKey(const Key('sharedLearningUpdateAgree')), findsNothing);
    expect(outcome, ReaskOutcome.notNeeded);
  });

  testWidgets('dismissing records nothing, so it stays OFF and is asked again',
      (tester) async {
    await pump(tester, ConsentState.accepted, ConsentState.accepted);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(prefs, isEmpty);
    expect(await SharedLearningPreference.memory(prefs).isOn('uid-fake'), isFalse);
    await pump(tester, ConsentState.accepted, ConsentState.accepted);
    expect(find.byKey(const Key('sharedLearningUpdateAgree')), findsOneWidget);
  });

  testWidgets('an explicit earlier choice is kept and never re-asked',
      (tester) async {
    for (final value in ['on', 'off']) {
      prefs = {key: value};
      await pump(tester, ConsentState.accepted, ConsentState.accepted);
      expect(find.byKey(const Key('sharedLearningUpdateAgree')), findsNothing);
      expect(prefs, {key: value});
      expect(outcome, ReaskOutcome.notNeeded);
    }
  });

  for (final (cloud, ai) in [
    (ConsentState.declined, ConsentState.declined),
    (ConsentState.accepted, ConsentState.declined),
    (ConsentState.declined, ConsentState.accepted),
  ]) {
    testWidgets('Cloud=$cloud AI=$ai: not asked, nothing written',
        (tester) async {
      await pump(tester, cloud, ai);
      expect(find.byKey(const Key('sharedLearningUpdateAgree')), findsNothing);
      expect(prefs, isEmpty);
      expect(outcome, ReaskOutcome.notNeeded);
    });
  }
}
