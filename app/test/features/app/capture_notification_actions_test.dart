import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/app/capture_notification_actions.dart';

void main() {
  group('captureRouteFor', () {
    for (final entry in {
      'budget_alert': '/budgets', 'budgetWarning': '/budgets', 'budgetOver': '/budgets',
      'goal_milestone': '/goals', 'goalMilestone': '/goals',
      'gamification_alert': '/achievements', 'achievements': '/achievements',
      'subscriptionReminder': '/subscriptions', 'bill_reminder': '/subscriptions',
      'weeklyReport': '/reports', 'dailyReminder': '/transactions',
    }.entries) {
      test('${entry.key} opens its own section even with an APNs payload id', () {
        expect(captureRouteFor(type: entry.key, transactionId: 'opaque-event'), entry.value);
      });
    }
    test('successful capture awaiting import opens all transactions, not Pending', () {
      expect(captureRouteFor(type: 'new_transaction'), '/transactions');
      expect(captureRouteFor(type: 'new_transaction', confirmedTransactionId: 'tx1'),
          '/transaction/tx1');
    });
    test('smart_inbox: marker never becomes a transaction route', () {
      expect(captureRouteFor(transactionId: 'smart_inbox:local_capture:p1'),
          '/smart-inbox');
      expect(
          captureRouteFor(payloadTransactionId: 'smart_inbox:local_capture:p1'),
          '/smart-inbox');
    });

    test('rejected: goes to the Smart Inbox', () {
      expect(captureRouteFor(transactionId: 'rejected:p1'), '/smart-inbox');
      expect(
          captureRouteFor(payloadTransactionId: 'rejected:p1'), '/smart-inbox');
    });

    test('real ids route to the transaction', () {
      expect(captureRouteFor(transactionId: 'tx1'), '/transaction/tx1');
      expect(captureRouteFor(payloadTransactionId: 'tx2'), '/transaction/tx2');
      expect(
          captureRouteFor(
              transactionId: 'rejected:p1', payloadTransactionId: 'tx3'),
          '/transaction/tx3');
    });

    test('needs_review type wins over a transaction id', () {
      expect(captureRouteFor(type: 'needs_review', transactionId: 'tx1'),
          '/smart-inbox');
      expect(
          captureRouteFor(type: 'suspicious_duplicate', transactionId: 'tx1'),
          '/smart-inbox');
    });

    test('confirmed ledger row overrides an old needs-review notification', () {
      expect(
          captureRouteFor(
              type: 'needs_review',
              transactionId: 'smart_inbox:old',
              confirmedTransactionId: 'saved-tx'),
          '/transaction/saved-tx');
      expect(
          captureRouteFor(
              type: 'suspicious_duplicate', confirmedTransactionId: 'saved-tx'),
          '/transaction/saved-tx');
      expect(
          captureRouteFor(
              type: 'needs_review', confirmedTransactionId: 'smart_inbox:old'),
          '/smart-inbox');
    });

    test('nothing known falls back to the Smart Inbox', () {
      expect(captureRouteFor(), '/smart-inbox');
    });
  });

  test('smartInboxItemIdFromMarker', () {
    expect(smartInboxItemIdFromMarker('smart_inbox:local_capture:p1'),
        'local_capture:p1');
    expect(smartInboxItemIdFromMarker('tx1'), isNull);
    expect(smartInboxItemIdFromMarker('smart_inbox:'), isNull);
    expect(smartInboxItemIdFromMarker(null), isNull);
  });

  group('handleCaptureNotificationAction', () {
    late List<String> log;
    late bool saved;
    late bool granted;

    Future<void> run(String action, {String? marker}) =>
        handleCaptureNotificationAction(
          action: action,
          smartInboxMarker: marker,
          showSmartInbox: () => log.add('inbox'),
          openManualSheet: () async {
            log.add('manual');
            return saved;
          },
          resolveItem: (id) async => log.add('resolve:$id'),
          isSmartAnalysisGranted: () async => granted,
          openConsentSheet: () async {
            log.add('consent');
            return true;
          },
          openPrivacy: () => log.add('privacy'),
        );

    setUp(() {
      log = [];
      saved = false;
      granted = false;
    });

    test('add manually opens the sheet and resolves only when saved', () async {
      saved = true;
      await run(kActionAddManually, marker: 'smart_inbox:local_capture:p1');
      expect(log, ['inbox', 'manual', 'resolve:local_capture:p1']);
    });

    test('add manually without a save resolves nothing', () async {
      await run(kActionAddManually, marker: 'smart_inbox:local_capture:p1');
      expect(log, ['inbox', 'manual']);
    });

    test('add manually with no smart inbox marker resolves nothing', () async {
      saved = true;
      await run(kActionAddManually, marker: 'rejected:p1');
      expect(log, ['inbox', 'manual']);
    });

    test('enable with consent off opens the consent sheet', () async {
      await run(kActionEnableSmartAnalysis);
      expect(log, ['consent']);
    });

    test('enable with consent on routes to privacy', () async {
      granted = true;
      await run(kActionEnableSmartAnalysis);
      expect(log, ['privacy']);
    });
  });
}
