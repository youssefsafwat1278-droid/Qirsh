import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/app_providers.dart';
import '../../domain/entities/supporting_entities.dart';
import '../../domain/usecases/gamification_rules.dart';
import '../gamification/services/local_achievement_service.dart';

class AchievementsView {
  const AchievementsView({
    required this.achievements,
    required this.xpLevel,
    required this.streak,
  });

  final List<AchievementEntity> achievements;
  final XpLevelEntity xpLevel;
  final StreakEntity streak;

  int? get nextLevelThreshold {
    final currentLevel = xpLevel.level;
    if (currentLevel >= XpLevelEngine.thresholds.length) {
      return null;
    }
    return XpLevelEngine.thresholds[currentLevel];
  }
}

final achievementsViewProvider = FutureProvider<AchievementsView>((ref) async {
  ref.watch(dbRevisionProvider);
  final repo = ref.watch(gamificationRepositoryProvider);
  return AchievementsView(
    achievements: await repo.getAchievements(),
    xpLevel: await repo.getXpLevel(),
    streak: await repo.getStreak(),
  );
});

/// Owner-approved v2 addition: real progress toward each locked badge,
/// computed read-only from the same local data the badge rules use. Kept
/// separate from [achievementsViewProvider] so a failed read only hides the
/// progress lines, never the screen.
final achievementProgressProvider =
    FutureProvider<Map<String, double>>((ref) async {
  ref.watch(dbRevisionProvider);
  return LocalAchievementService(ref.watch(appDatabaseProvider)).progress();
});

void refreshAchievements(WidgetRef ref) {
  ref.invalidate(achievementsViewProvider);
  ref.invalidate(achievementProgressProvider);
}
