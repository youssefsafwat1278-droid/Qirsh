import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/services/notification_planner.dart';
import 'package:money_companion/features/capture/services/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final shown = <Map<Object?, Object?>>[];
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    IOSFlutterLocalNotificationsPlugin.registerWith();
    shown.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getNotificationAppLaunchDetails') {
        return {'notificationLaunchedApp': false};
      }
      if (call.method == 'show') {
        shown.add(Map<Object?, Object?>.from(call.arguments as Map));
        return null;
      }
      return true;
    });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('iOS budget and achievement banners carry their section even without a log service', () async {
    final service = LocalNotificationService.instance;
    service.logService = null;
    await service.showBudgetAlert(title: 'Budget', body: 'Body',
      type: NotificationType.budgetWarning, preferences: const NotificationPreferences(), notifId: 1);
    await service.showAchievementNotification(achievementKey: 'first', title: 'Badge',
      body: 'Body', preferences: const NotificationPreferences());
    expect(shown, hasLength(2));
    expect(CaptureNotificationPayload.tryDecode(shown[0]['payload'] as String)?.route, '/budgets');
    expect(CaptureNotificationPayload.tryDecode(shown[1]['payload'] as String)?.route, '/achievements');
  });

  test('iOS goal banner opens the goal it describes', () async {
    await LocalNotificationService.instance.showGoalMilestoneNotification(
      notification: const GoalMilestoneNotification(goalId: 'goal-1', goalName: 'Trip',
        milestone: 50, title: 'Goal', body: 'Body'), preferences: const NotificationPreferences());
    expect(shown, hasLength(1));
    expect(CaptureNotificationPayload.tryDecode(shown.single['payload'] as String)?.route, '/goals/goal-1');
  });
}
