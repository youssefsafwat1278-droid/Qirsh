import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';

import '../../../core/session/app_session.dart';
import '../../../data/db/app_database.dart';
import '../../../data/db/sql_value_codec.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/entities/achievement_catalog.dart';
import '../../../domain/entities/engagement_entities.dart';
import '../../../domain/usecases/user_settings_usecases.dart';
import '../../app/app_boot_loader.dart';
import '../../capture/services/local_notification_service.dart';

// A local evaluation and a Cloud pull can discover the same badge. Only the
// writer that changes the locked row may announce it.
Future<bool> unlockAchievement(
  AppDatabase db,
  String key,
  DateTime at,
) async =>
    await db.customUpdate(
      'UPDATE achievements SET unlocked_at = ?, progress = 1.0 '
      'WHERE key = ? AND unlocked_at IS NULL;',
      variables: [
        Variable.withString(dateTimeToSql(at)),
        Variable.withString(key)
      ],
    ) ==
    1;

typedef AchievementNotification = Future<void> Function({
  required String achievementKey,
  required String title,
  required String body,
  required NotificationPreferences preferences,
});

/// The monthly budget's previous start date is about to be replaced by a
/// rollover. Claim the badge while the full closed period is still known.
Future<void> recordMonthUnderBudget(
  AppDatabase db,
  DateTime completedAt,
) async {
  final session = AppSession.instance;
  final host = session.captureDatabaseHostAdmission();
  final authority = session.captureLocalWorkAuthority();
  if (host == null || authority == null || !identical(host.database, db)) {
    return;
  }
  const badge = AchievementCatalog.monthWithoutOverrun;
  try {
    await session.runAdmittedLocalOperation(authority, () async {
      if (await unlockAchievement(db, badge.key, completedAt)) {
        await notifyAchievementUnlocks(db, [badge],
            isCurrent: () => authority.isCurrent && !appDataRestoring.value);
      }
    });
  } catch (error) {
    if (kDebugMode) debugPrint('[Achievements] rollover award skipped: $error');
  }
}

Future<void> notifyAchievementUnlocks(
  AppDatabase db,
  Iterable<AchievementDefinition> badges, {
  required bool Function() isCurrent,
  AchievementNotification? notify,
}) async {
  if (badges.isEmpty || !isCurrent()) return;
  try {
    final settings = DriftUserSettingsRepository(db);
    final preferences = await LoadNotificationPreferencesUseCase(settings)();
    final language = (await settings.getSettings()).language;
    final en = language == 'en';
    final send =
        notify ?? LocalNotificationService.instance.showAchievementNotification;
    for (final badge in badges) {
      if (!isCurrent()) return;
      final name = badge.name(language);
      await send(
        achievementKey: badge.key,
        title: en ? '🏆 New achievement: $name' : '🏆 إنجاز جديد: $name',
        body: en
            ? 'You unlocked a new achievement. Open Qirsh to see it.'
            : 'فتحت إنجازًا جديدًا. افتح قرش لتراه.',
        preferences: preferences,
      );
    }
  } catch (error) {
    if (kDebugMode) debugPrint('[Achievements] notification skipped: $error');
  }
}
