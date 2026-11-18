import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/repositories/smart_inbox_repository.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

import '../consent/consent_test_harness.dart';

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
}) =>
    SmartInboxItemEntity(
      id: id,
      type: 'needs_review',
      title: 'Unsupported',
      status: 'open',
      createdAt: DateTime(2026, 1, 1),
      transactionId: transactionId,
      payloadId: 'p1',
    );

Future<void> _pump(
  WidgetTester tester,
  SmartInboxItemEntity item, {
  required bool consentOn,
  FakeSettingsRepository? settingsRepository,
  FakeRegistrationService? registrationService,
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
}
