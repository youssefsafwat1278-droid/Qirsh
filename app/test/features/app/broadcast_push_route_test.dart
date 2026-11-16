import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/features/app/capture_notification_actions.dart';

/// Admin push broadcasts (migration 20261116150000, send-push-broadcast).
void main() {
  group('broadcastRouteFor', () {
    for (final route in kBroadcastRoutes) {
      test('$route opens as sent', () {
        expect(broadcastRouteFor(route), route);
      });
    }

    test(
      'no link, or one outside the allowlist, opens the announcements page',
      () {
        expect(broadcastRouteFor(null), '/announcements');
        expect(broadcastRouteFor(''), '/announcements');
        expect(broadcastRouteFor('https://evil.example'), '/announcements');
        expect(broadcastRouteFor('/transaction/tx1'), '/announcements');
        expect(broadcastRouteFor('/delete-account'), '/announcements');
      },
    );
  });

  test('a tapped broadcast is routed before any capture lookup', () {
    final shell = File('lib/features/app/app_shell.dart').readAsStringSync();
    final body = shell.substring(
      shell.indexOf('Future<String> _routeForCaptureNotification('),
    );
    final broadcast = body.indexOf(
      'if (route.source == kBroadcastSource) return broadcastRouteFor(route.route);',
    );
    expect(broadcast, greaterThan(0));
    expect(broadcast, lessThan(body.indexOf('notificationSectionRoute(')));
  });

  test('iOS queues a broadcast tap with its route', () {
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    expect(
      delegate,
      contains('userInfo["source"] as? String == "qirsh_broadcast"'),
    );
    for (final path in [
      'ios/Runner/SharedCaptureStore.swift',
      'ios/ShareBankMessage/SharedCaptureStore.swift',
    ]) {
      final store = File(path).readAsStringSync();
      expect(
        store,
        contains('route: clean(userInfo["route"] as? String)'),
        reason: path,
      );
      expect(
        store,
        contains('payload.source == "qirsh_broadcast"'),
        reason: path,
      );
    }
  });

  test('the server sends the source the app routes on, and no payloadId', () {
    final send = File('../supabase/functions/send-push-broadcast/send.ts')
        .readAsStringSync();
    expect(
      send,
      contains("export const BROADCAST_SOURCE = '$kBroadcastSource';"),
    );
    final data = send.substring(send.indexOf('data: {'));
    expect(
      data.substring(0, data.indexOf('}')).contains('payloadId'),
      isFalse,
      reason: 'any payloadId makes iOS treat the push as a capture',
    );
  });

  test('"Messages from Qirsh" is the preference the server filters on', () {
    // Default ON, synced in notifications_json under this exact key.
    expect(
      const NotificationPreferences().toJson()['marketingMessages'],
      isTrue,
    );
    expect(
      const NotificationPreferences(marketingMessages: false)
          .toJson()['marketingMessages'],
      isFalse,
    );
    final sql = File(
      '../supabase/migrations/20261116150000_admin_push_broadcasts.sql',
    ).readAsStringSync();
    expect(sql, contains("->> 'marketingMessages'"));
    final send = File('../supabase/functions/send-push-broadcast/send.ts')
        .readAsStringSync();
    expect(send, contains('parsed.marketingMessages === false'));
  });
}
