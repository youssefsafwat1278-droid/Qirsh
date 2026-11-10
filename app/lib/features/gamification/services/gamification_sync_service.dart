import '../../../core/sync/sync_health.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/di/app_providers.dart';
import '../../../core/privacy/consent_authority.dart';
import '../../../data/db/app_database.dart';
import '../../../domain/entities/achievement_catalog.dart';
import '../../../domain/usecases/gamification_rules.dart';
import '../../../data/sync/seq_pull.dart';
import '../../../data/sync/sync_cursor.dart';
import '../../../data/repositories/drift_user_settings_repository.dart';
import '../../../domain/repositories/gamification_repository.dart';
import '../../app/app_boot_loader.dart';
import 'achievement_unlocks.dart';

final gamificationSyncServiceProvider = Provider((ref) {
  return GamificationSyncService(
    db: ref.watch(appDatabaseProvider),
    supabase: Supabase.instance.client,
    gamificationRepo: ref.watch(gamificationRepositoryProvider),
    // C-3 — achievements, streaks and XP are derived from what this person did
    // in the app, so they are user data and must not be fetched with cloud
    // consent off. Read fresh per sync, so a revocation is observed by the next
    // call rather than the next boot.
    mayEgress: () => ConsentAuthority(
      () => DriftUserSettingsRepository(ref.read(appDatabaseProvider))
          .getSettings(),
    ).allows(EgressClass.gamification),
    health: ref.watch(syncHealthProvider),
    seqGate: ref.watch(seqPullGateProvider),
  );
});

class GamificationSyncService {
  GamificationSyncService({
    required this.db,
    required this.supabase,
    required this.gamificationRepo,
    Future<String?> Function()? getAuthUserId,
    Future<bool> Function()? mayEgress,
    SyncHealth? health,

    /// WP-4: sequence pull gate. Null keeps the legacy full pull.
    SeqPullGate? seqGate,
  })  : _seqGate = seqGate,
        _health = health,
        _getAuthUserId =
            getAuthUserId ?? (() async => supabase.auth.currentUser?.id),
        // Defaults CLOSED. A caller that forgets to pass a gate gets no
        // egress rather than silent egress — which is the habit that produced
        // this defect: `EgressClass.gamification` has existed in
        // `ConsentAuthority` the whole time and this service never asked it.
        _mayEgress = mayEgress ?? (() async => false);

  final AppDatabase db;
  final SupabaseClient supabase;
  final GamificationRepository gamificationRepo;
  final Future<String?> Function() _getAuthUserId;
  final Future<bool> Function() _mayEgress;
  final SyncHealth? _health;
  final SeqPullGate? _seqGate;
  static const _pageSize = 200;

  Future<void> performSync() async {
    // Read fresh on every call rather than capturing at provider-construction
    // time — the provider is a long-lived singleton, but the signed-in user
    // can change (sign-out/sign-in) without it being recreated.
    final userId = await _getAuthUserId();
    if (userId == null) return;
    // MALI-024 — the client is PULL-ONLY for gamification aggregates. It never
    // uploads an XP/streak/achievement total (that was the dual-authority tamper
    // vector). The server is authoritative: it awards from engagement events
    // (record_engagement_event RPC, submitted by EngagementEventService) and the
    // server-side evaluation of synced domain records. The client only mirrors
    // the acknowledged server aggregate.
    await _pullFromSupabase(userId);
    if (kDebugMode) debugPrint('[GamificationSync] done');
  }

  Future<void> _pullFromSupabase(String userId) async {
    // Consulted at the moment of egress, not at construction: consent can be
    // revoked between a decision and a retry.
    if (!await _mayEgress()) {
      _health?.noteConsentBlocked(SyncDomain.engagement);
      if (kDebugMode) {
        debugPrint('[GamificationSync] denied: cloud consent off');
      }
      return;
    }
    // WP-4: with the sync_seq capability each table is pulled by its own seq
    // cursor (no more full pull); otherwise the legacy full pull below runs.
    final gate = _seqGate;
    if (gate != null) {
      final plan = await gate.plan(userId);
      if (plan.mode == SeqMode.stopped) return;
      if (plan.mode == SeqMode.seq) {
        await _pullBySeq(gate, plan, userId);
        return;
      }
    }

    // Pull Achievements
    final serverAchievements = await supabase
        .from('user_achievements')
        .select()
        .eq('user_id', userId)
        .isFilter('deleted_at', null);

    final unlockedToNotify = await _applyAchievements(serverAchievements);
    await _notifyUnlocked(unlockedToNotify);

    // Pull Streak
    final serverStreak = await supabase
        .from('user_streaks')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    await _applyStreak(serverStreak);

    // Pull XP
    final serverXp = await supabase
        .from('user_xp_levels')
        .select()
        .eq('user_id', userId)
        .maybeSingle();
    await _applyXp(serverXp);
  }

  Future<List<AchievementDefinition>> _applyAchievements(
      Iterable<Map<String, dynamic>> serverAchievements) async {
    final dates = {
      for (final row in serverAchievements)
        row['achievement_key'] as String:
            DateTime.parse(row['unlocked_at'] as String).toUtc(),
    };
    final unlocked = <AchievementDefinition>[];
    for (final badge in AchievementCatalog.all) {
      final date = dates[badge.key];
      if (date != null && await unlockAchievement(db, badge.key, date)) {
        unlocked.add(badge);
      }
    }
    return unlocked;
  }

  Future<void> _notifyUnlocked(List<AchievementDefinition> unlocked) =>
      notifyAchievementUnlocks(
        db,
        unlocked,
        isCurrent: () => !appDataRestoring.value,
      );

  Future<void> _applyStreak(Map<String, dynamic>? serverStreak) async {
    if (serverStreak != null) {
      final currentStreak = serverStreak['current_streak'] as int;
      final longestStreak = serverStreak['longest_streak'] as int;
      final lastActiveDate = serverStreak['last_active_date'] as String?;

      if (lastActiveDate != null) {
        // xp_levels/streaks are singleton rows seeded with a generated id (the
        // repo reads them via LIMIT 1), so target the single row directly — the
        // old `WHERE id='streak'` matched nothing, so the acknowledged server
        // aggregate never reached the local display.
        await db.customStatement('''
          UPDATE streaks
          SET current_streak = ?, longest_streak = ?, last_active_date = ?;
        ''', [currentStreak, longestStreak, lastActiveDate]);
      }
    }
  }

  Future<void> _applyXp(Map<String, dynamic>? serverXp) async {
    if (serverXp != null) {
      final currentXp = serverXp['xp'] as int;
      final currentLevel = serverXp['level'] as int;

      await db.customStatement('''
        UPDATE xp_levels
        SET total_xp = ?, level = ?, level_key = ?;
      ''', [
        currentXp,
        currentLevel,
        // F-022 — the pull wrote total_xp and level but NEVER level_key, so the
        // displayed title stayed at the seeded 'beginner' however high the level
        // climbed. Derived through the clamping mapping because the server curve
        // is unbounded and these tiers are not.
        XpLevelEngine.levelKeyForLevel(currentLevel),
      ]);
    }
  }

  /// WP-4: one seq cursor per table, each advanced in the same local
  /// transaction as the page it covers. Streak/XP are per-user singletons, so a
  /// page holds at most one live row for them.
  Future<void> _pullBySeq(SeqPullGate gate, SeqPlan plan, String userId) async {
    final unlocked = <AchievementDefinition>[];
    for (final table in const [
      'user_achievements',
      'user_streaks',
      'user_xp_levels',
    ]) {
      final entity = 'gamification_$table';
      var seqCursor = await readSeqCursor(db, userId, entity);
      if (plan.isIdle(seqCursor)) continue;
      while (true) {
        final rows = await gate.fetch(
            table: table,
            userId: userId,
            afterSeq: seqCursor,
            limit: _pageSize);
        if (rows.isEmpty) break;
        final nextSeq = nextSeqOf(rows, seqCursor);
        await db.transaction(() async {
          final live = rows.where((r) => r['deleted_at'] == null).toList();
          switch (table) {
            case 'user_achievements':
              unlocked.addAll(await _applyAchievements(live));
            case 'user_streaks':
              if (live.isNotEmpty) await _applyStreak(live.last);
            default:
              if (live.isNotEmpty) await _applyXp(live.last);
          }
          await writeSeqCursor(db, userId, entity, nextSeq);
        });
        seqCursor = nextSeq;
        if (rows.length < _pageSize) break;
      }
      await gate.markCaughtUp(userId, entity, seqCursor, plan);
    }
    await _notifyUnlocked(unlocked);
  }
}
