import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/consent/smart_analysis_consent_sheet.dart';

import 'consent_test_harness.dart';

// §4.6 "a new device re-asks": an onboarded account admitted into a fresh replica
// (consent unset) is asked through the sheet before any egress.

class _Host extends ConsumerStatefulWidget {
  const _Host(
      {required this.seen, required this.markSeen, this.readChoice, this.onOutcome});
  final Future<bool> Function() seen;
  final Future<void> Function() markSeen;
  final Future<AccountCloudChoice> Function()? readChoice;
  final void Function(ReaskOutcome)? onOutcome;

  @override
  ConsumerState<_Host> createState() => _HostState();
}

class _HostState extends ConsumerState<_Host> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => maybeReaskConsent(
          context,
          ref,
          seen: widget.seen,
          markSeen: widget.markSeen,
          readChoice: widget.readChoice,
        ).then((o) => widget.onOutcome?.call(o)));
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox());
}

void main() {
  late FakeSettingsRepository repo;
  late FakeRegistrationService service;
  var asked = false;
  var markCalls = 0;

  ReaskOutcome? outcome;

  Future<void> pump(WidgetTester tester,
      {bool seen = false,
      String locale = 'en',
      Future<AccountCloudChoice> Function()? readChoice}) async {
    outcome = null;
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    markCalls = 0;
    asked = seen;
    await tester.pumpWidget(consentApp(
      overrides: consentOverrides(repo, service),
      home: _Host(
        seen: () async => asked,
        markSeen: () async {
          markCalls++;
          asked = true;
        },
        readChoice: readChoice,
        onOutcome: (o) => outcome = o,
      ),
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  setUp(() {
    repo = FakeSettingsRepository();
    service = FakeRegistrationService();
  });

  testWidgets('fresh replica, consent unset, never asked: the sheet opens and '
      'nothing is saved or sent before the answer (EN)', (tester) async {
    await pump(tester);
    expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
    expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
    expect(repo.saveCalls, 0);
    expect(repo.settings.cloudConsentState, ConsentState.unset);
    expect(repo.settings.aiConsentState, ConsentState.unset);
    expect(service.retryCalls, 0);
    expect(service.syncCalls, 0);
    expect(markCalls, 0, reason: 'not answered yet');
  });

  testWidgets('re-ask renders in Arabic', (tester) async {
    await pump(tester, locale: 'ar');
    expect(find.text('التحليل الذكي والمزامنة السحابية'), findsOneWidget);
    expect(find.byKey(const Key('initialConsentAccept')), findsOneWidget);
  });

  testWidgets('"Not now" records the question as asked, writes nothing (stays '
      'denied)', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const Key('initialConsentDecline')));
    await tester.pumpAndSettle();
    expect(markCalls, 1);
    expect(repo.saveCalls, 1);
    expect(repo.settings.cloudConsentState, ConsentState.declined);
    expect(repo.settings.aiConsentState, ConsentState.declined);
    expect(service.syncCalls + service.retryCalls, 0);
  });

  testWidgets('swipe-dismiss does not record it: it is asked again next time',
      (tester) async {
    await pump(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(markCalls, 0);
  });

  testWidgets('already asked on this device: no sheet', (tester) async {
    await pump(tester, seen: true);
    expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
  });

  testWidgets('any explicit answer already on the replica: no sheet',
      (tester) async {
    repo.settings =
        repo.settings.copyWith(cloudConsentState: ConsentState.declined);
    await pump(tester);
    expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
  });

  group('F2: the account\'s server choice', () {
    testWidgets('unknown (offline / timeout): no sheet, nothing recorded, '
        'reported for a retry', (tester) async {
      await pump(tester, readChoice: () async => AccountCloudChoice.unknown);
      expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
      expect(find.text('Restore your cloud data'), findsNothing);
      expect(markCalls, 0, reason: '"Not now" can no longer be recorded '
          'against an unanswered read');
      expect(repo.saveCalls, 0);
      expect(outcome, ReaskOutcome.unknownPreference);
    });

    testWidgets('ON: the restore wording is offered', (tester) async {
      await pump(tester, readChoice: () async => AccountCloudChoice.on);
      expect(find.text('Restore your cloud data'), findsOneWidget);
      expect(outcome, isNull, reason: 'still open');
    });

    testWidgets('OFF: no sheet and no recorded answer', (tester) async {
      await pump(tester, readChoice: () async => AccountCloudChoice.off);
      expect(find.text('Smart Analysis & Cloud Sync'), findsNothing);
      expect(find.text('Restore your cloud data'), findsNothing);
      expect(markCalls, 0);
      expect(outcome, ReaskOutcome.notNeeded);
    });

    testWidgets('never chose: the generic sheet', (tester) async {
      await pump(tester, readChoice: () async => AccountCloudChoice.none);
      expect(find.text('Smart Analysis & Cloud Sync'), findsOneWidget);
      expect(find.text('Restore your cloud data'), findsNothing);
    });

    testWidgets('an explicit choice made while the read was pending wins: no '
        'sheet', (tester) async {
      await pump(tester, readChoice: () async {
        repo.settings =
            repo.settings.copyWith(cloudConsentState: ConsentState.declined);
        return AccountCloudChoice.on;
      });
      expect(find.text('Restore your cloud data'), findsNothing);
      expect(outcome, ReaskOutcome.notNeeded);
      expect(repo.saveCalls, 0, reason: 'the explicit choice is not touched');
    });
  });
}
