import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/privacy/smart_analysis_consent.dart';
import 'package:money_companion/data/repositories/analysis_log_repository.dart';
import 'package:money_companion/domain/capture/analysis_outcome.dart';
import 'package:money_companion/features/capture/analysis_log_screen.dart';
import 'package:money_companion/domain/capture/analysis_reason.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/repositories/account_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/smart_inbox_repository.dart';
import 'package:money_companion/features/transactions/manual_transaction_sheet.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

import '../consent/consent_test_harness.dart';

class _NoAccounts implements AccountRepository {
  @override
  Future<AccountEntity?> getDefault() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _FakeInbox implements SmartInboxRepository {
  @override
  Future<List<SmartInboxItemEntity>> getOpen() async => const [];
  @override
  Future<void> dismiss(String id) async {}
  @override
  Future<void> resolve(String id) async {}
}

SmartInboxItemEntity _item({
  String id = 'local_capture:p1',
  String? transactionId,
  String? body,
  String? reviewReason,
  String? reasonCode,
  bool aiAnalysed = false,
  CaptureProposal? proposal,
}) =>
    SmartInboxItemEntity(
      id: id,
      type: 'needs_review',
      title: 'Unsupported',
      status: 'open',
      createdAt: DateTime(2026, 1, 1),
      transactionId: transactionId,
      payloadId: 'p1',
      body: body,
      reviewReason: reviewReason,
      reasonCode: reasonCode,
      aiAnalysed: aiAnalysed,
      proposal: proposal,
    );

const _sms = 'Purchase EGP 45.00 at Test Mart';

Future<void> _pump(
  WidgetTester tester,
  SmartInboxItemEntity item, {
  required bool consentOn,
  FakeSettingsRepository? settingsRepository,
  FakeRegistrationService? registrationService,
  bool? ownLane,
}) async {
  final repo = settingsRepository ?? FakeSettingsRepository();
  if (consentOn) {
    repo.settings = repo.settings.copyWith(
      cloudConsentState: ConsentState.accepted,
      aiConsentState: ConsentState.accepted,
    );
  }
  await tester.pumpWidget(consentApp(
    overrides: [
      ...consentOverrides(
          repo, registrationService ?? FakeRegistrationService()),
      smartInboxRepositoryProvider.overrideWithValue(_FakeInbox()),
      accountRepositoryProvider.overrideWithValue(_NoAccounts()),
      if (ownLane != null)
        smartAnalysisOwnLaneProvider.overrideWithValue(ownLane),
    ],
    home: Scaffold(body: SmartInboxCard(item: item)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unprocessable + consent off: Add manually and Enable',
      (tester) async {
    await _pump(tester, _item(), consentOn: false);
    expect(find.text('Add manually'), findsOneWidget);
    expect(find.text('Enable Smart Analysis & Cloud Sync'), findsOneWidget);
  });

  testWidgets('unprocessable + consent on: only Add manually', (tester) async {
    await _pump(tester, _item(), consentOn: true);
    expect(find.text('Add manually'), findsOneWidget);
    expect(find.text('Enable Smart Analysis & Cloud Sync'), findsNothing);
  });

  testWidgets('other items are unchanged', (tester) async {
    await _pump(tester, _item(id: 'server-1', transactionId: 'tx1'),
        consentOn: false);
    expect(find.text('Add manually'), findsNothing);
    expect(find.text('Enable Smart Analysis & Cloud Sync'), findsNothing);
    expect(find.text('Review transaction'), findsOneWidget);
  });

  testWidgets(
      'Enable opens disclosed choices without granting consent, '
      'and dismissal changes nothing', (tester) async {
    final repo = FakeSettingsRepository();
    final service = FakeRegistrationService();
    final before = repo.settings;
    void expectNoGrant() {
      expect(repo.saveCalls, 0);
      expect(repo.lastChoices, isNull);
      expect(repo.settings, same(before));
      expect(repo.settings.cloudConsentState, ConsentState.unset);
      expect(repo.settings.aiConsentState, ConsentState.unset);
      expect(repo.settings.cloudProcessingEnabled, isFalse);
      expect(repo.settings.aiConsentGranted, isFalse);
      expect(service.enableCalls, 0);
      expect(service.disableCalls, 0);
      expect(service.syncCalls, 0);
      expect(service.retryCalls, 0);
    }

    await _pump(tester, _item(),
        consentOn: false,
        settingsRepository: repo,
        registrationService: service);
    expectNoGrant();
    await tester.tap(find.text('Enable Smart Analysis & Cloud Sync'));
    await tester.pumpAndSettle();
    // Decided change (owner decision 3.8): the affirmative action is now
    // "Agree and enable" (was "Accept cloud sync and smart analysis").
    expect(find.text('Agree and enable'), findsOneWidget);
    expect(find.text('Continue locally'), findsOneWidget);
    expect(
        // Decision 3.8 (ai.md Follow-up 12): only what redaction recognises.
        find.textContaining('Qirsh automatically removes the card numbers, '
            'long or labelled account numbers'),
        findsOneWidget);
    expect(find.textContaining('Google Gemini may process this text'),
        findsOneWidget);
    expectNoGrant();

    // Dismiss the modal without choosing either disclosed action.
    final context = tester.element(find.text('Continue locally'));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    expect(find.text('Continue locally'), findsNothing);
    expect(find.text('Agree and enable'), findsNothing);
    expect(find.text('Enable Smart Analysis & Cloud Sync'), findsOneWidget);
    expectNoGrant();
  });

  group('Gemini-first phase 1: reason title and re-analyse visibility', () {
    testWidgets('no reason known: generic title, re-analyse offered',
        (tester) async {
      await _pump(tester, _item(body: _sms), consentOn: true);
      expect(find.text('Unsupported'), findsOneWidget);
      expect(find.text('Retry smart analysis'), findsOneWidget);
    });

    testWidgets('analysis did not run: re-analyse offered', (tester) async {
      await _pump(
          tester,
          _item(
              body: _sms,
              reviewReason: SmartInboxReviewReason.analysisUnavailable),
          consentOn: true);
      expect(find.text('Retry smart analysis'), findsOneWidget);
    });

    testWidgets('model verdict: reason as title, no re-analyse',
        (tester) async {
      await _pump(
          tester,
          _item(body: _sms, reasonCode: 'promo', aiAnalysed: true),
          consentOn: true);
      expect(find.text('An offer or marketing message, with no transaction'),
          findsOneWidget);
      expect(find.text('Unsupported'), findsNothing);
      expect(find.text('Retry smart analysis'), findsNothing);
    });

    testWidgets('a device hold that settles the message: no re-analyse',
        (tester) async {
      await _pump(tester, _item(body: _sms, reviewReason: 'bill_due'),
          consentOn: true);
      expect(find.text('A payment reminder; nothing has been paid yet'),
          findsOneWidget);
      expect(find.text('Retry smart analysis'), findsNothing);
    });

    testWidgets('unclear without AI: re-analyse offered', (tester) async {
      await _pump(
          tester, _item(body: _sms, reviewReason: 'no_completed_form'),
          consentOn: true);
      expect(find.text('The operation is not clear; please review it'),
          findsOneWidget);
      expect(find.text('Retry smart analysis'), findsOneWidget);
    });

    testWidgets('direction conflict: one-tap confirmation in both directions',
        (tester) async {
      await _pump(
          tester,
          _item(
            body: _sms,
            reasonCode: 'direction_conflict',
            aiAnalysed: true,
            proposal: const CaptureProposal(
                amountText: '120.00', currency: 'EGP', isDebit: false),
          ),
          consentOn: true);
      expect(
          find.text(
              'Unclear whether this is spending or income; confirm before recording'),
          findsOneWidget);
      expect(find.textContaining('Record as income 120.00'), findsOneWidget);
      expect(find.textContaining('Record as expense 120.00'), findsOneWidget);
      expect(find.text('Retry smart analysis'), findsNothing);
    });

    // Gemini-first phase 2 (owner decision): the model's amount does not
    // match the text, so it is never saved by one tap.
    testWidgets(
        'amount mismatch: opens the pre-filled editor with the message, '
        'saves nothing', (tester) async {
      await _pump(
          tester,
          _item(
            body: _sms,
            reasonCode: 'amount_mismatch',
            aiAnalysed: true,
            proposal: const CaptureProposal(
                amountText: '54.00', currency: 'EGP', isDebit: true),
          ),
          consentOn: true);
      expect(find.textContaining('Record as expense'), findsNothing);
      expect(find.textContaining('Record as income'), findsNothing);
      await tester.tap(find.text('Check the amount and record it'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final sheet = tester
          .widget<ManualTransactionSheet>(find.byType(ManualTransactionSheet));
      expect(sheet.transaction, isNull, reason: 'a new entry, not an edit');
      expect(sheet.prefill!.amountText, '54.00');
      expect(sheet.prefill!.currency, 'EGP');
      expect(sheet.prefill!.messageText, _sms);
    });

    testWidgets('not added for a settled reason: "Record it anyway"',
        (tester) async {
      await _pump(tester, _item(body: _sms, reasonCode: 'declined'),
          consentOn: true);
      expect(find.text('Record it anyway'), findsOneWidget);
      expect(find.text('Add manually'), findsNothing);
    });
  });

  // Gemini-first phase 3: a capture kept because Smart Analysis is off reads
  // "awaiting analysis — turn on Smart Analysis to record it automatically",
  // with a one-tap path to the Smart Analysis consent and manual entry.
  group('phase 3: kept because Smart Analysis is off (iOS)', () {
    final off = _item(
        body: _sms, reviewReason: SmartInboxReviewReason.smartAnalysisOff);

    test('its outcome is awaiting, with the turn-on sentence', () {
      expect(AnalysisOutcome.forInboxItem(off), AnalysisOutcomeState.awaiting);
      final entry = AnalysisLogEntry(
        payloadId: 'p1',
        at: DateTime.utc(2026, 1, 1),
        state: AnalysisOutcome.forInboxItem(off),
        inboxItem: off,
      );
      final en = AnalysisLogTile.textOf(entry, 'en', '');
      expect(en.title, 'Awaiting analysis');
      expect(en.body, 'Turn on Smart Analysis to record it automatically');
      final ar = AnalysisLogTile.textOf(entry, 'ar', '');
      expect(ar.title, 'بانتظار التحليل');
      expect(ar.body, 'فعّل التحليل الذكي لتسجيلها تلقائيًا');
    });

    testWidgets('Turn on Smart Analysis and Add manually; the turn-on opens '
        'the Smart Analysis consent only and grants nothing by itself',
        (tester) async {
      final repo = FakeSettingsRepository();
      final service = FakeRegistrationService();
      await tester.binding.setSurfaceSize(const Size(800, 2400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pump(tester, off,
          consentOn: false,
          ownLane: true,
          settingsRepository: repo,
          registrationService: service);
      expect(find.text('Add manually'), findsOneWidget);
      expect(find.text('Turn on Smart Analysis'), findsOneWidget);
      await tester.tap(find.byKey(const Key('inboxTurnOnSmartAnalysis')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('smartOnlyAllow')), findsOneWidget);
      expect(find.text('Agree and enable'), findsNothing,
          reason: 'not the combined Cloud disclosure');
      expect(repo.saveCalls, 0);
      expect(service.retryCalls, 0);
    });

    testWidgets('with Smart Analysis on (Cloud off): no turn-on, a retry',
        (tester) async {
      final repo = FakeSettingsRepository()
        ..settings = FakeSettingsRepository().settings.copyWith(
            cloudConsentState: ConsentState.declined,
            aiConsentState: ConsentState.accepted);
      await _pump(tester, off,
          consentOn: false, ownLane: true, settingsRepository: repo);
      expect(find.text('Turn on Smart Analysis'), findsNothing);
      expect(find.text('Add manually'), findsOneWidget);
      expect(find.text('Retry smart analysis'), findsOneWidget);
    });
  });
}
