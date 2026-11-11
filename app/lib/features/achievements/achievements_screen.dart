import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/l10n_ext.dart';
import '../../domain/entities/achievement_catalog.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../common/motion.dart';
import '../common/premium_loading.dart';
import '../common/app_error_state.dart';
import '../common/app_header.dart';
import 'achievements_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

class AchievementsScreen extends ConsumerWidget {
  const AchievementsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(achievementsViewProvider);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppHeader(title: context.l10n.achTitle),
      // Immersive: the body fills from y = 0 behind the glass bar; the bar's
      // height arrives as the body's top inset (read inside the Scaffold).
      body: Builder(builder: (context) => async.when(
        skipLoadingOnReload: true,
        loading: () => Padding(
          padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
          child: const Column(children: [
            _AchievementsHeader(),
            Expanded(child: SkeletonList(rows: 5)),
          ]),
        ),
        error: (error, _) => ListView(
            padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
            children: [
          const _AchievementsHeader(),
          AppErrorState(
            title: context.l10n.txnError,
            description: context.l10n.annTryAgainSoon,
            retryLabel: context.l10n.startRetry,
            onRetry: () => ref.invalidate(achievementsViewProvider),
          ),
        ]),
        data: (data) {
          final c = context.colors;
          final nextThreshold = data.nextLevelThreshold;
          final progress = nextThreshold == null
              ? 1.0
              : (data.xpLevel.totalXp / nextThreshold).clamp(0, 1).toDouble();
          // Real per-badge progress, read beside the view (owner-approved).
          // Absent or failed reads simply show no progress line.
          final badgeProgress =
              ref.watch(achievementProgressProvider).valueOrNull ??
                  const <String, double>{};
          final reduceMotion = shouldReduceMotion(context);
          final topInset = MediaQuery.paddingOf(context).top;
          return RefreshIndicator(
            edgeOffset: topInset,
            onRefresh: () async => refreshAchievements(ref),
            child: ListView(
              padding: EdgeInsets.only(top: topInset),
              children: [
                const _AchievementsHeader(),
                Padding(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                      AppSpacing.s2, AppSpacing.gutter, AppSpacing.gutter),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // v2 level hero: the photo banner and the level card
                      // merged into ONE Hero (per-theme brand gradient, coin
                      // art, gold XP bar). On-hero text is white in both
                      // themes, so the old melt-zone contrast issue cannot
                      // recur.
                      PremiumMotion(
                        child: _LevelHero(
                          level: data.xpLevel.level,
                          levelName: _levelName(context, data.xpLevel.levelKey),
                          totalXp: data.xpLevel.totalXp,
                          nextThreshold: nextThreshold,
                          progress: progress,
                          streakDays: data.streak.currentStreak,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sectionGap),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Expanded(
                            child: Text(context.l10n.achBadges,
                                style: AppTypography.sectionTitle(
                                    c.textPrimary)),
                          ),
                          Text(
                              context.l10n.achEarnedCount(
                                  data.achievements
                                      .where((a) => a.unlockedAt != null)
                                      .length,
                                  data.achievements.length),
                              style: AppTypography.subhead(c.textMuted)),
                        ],
                      ),
                      const SizedBox(height: 12),
                      GridView.builder(
                        // Explicit, or the grid inherits the status-bar inset
                        // as top padding and opens a ~60pt gap above itself.
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: MediaQuery.sizeOf(context).width < 360 ? 2 : 3,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                          mainAxisExtent: 168 * MediaQuery.textScalerOf(context).scale(1),
                        ),
                        itemCount: data.achievements.length,
                        itemBuilder: (context, index) {
                          final item = data.achievements[index];
                          final unlocked = item.unlockedAt != null;
                          final tile = _BadgeTile(
                            glyph: _badgeGlyph(item.key),
                            title: AchievementCatalog.displayName(
                                item.key,
                                item.nameAr,
                                Localizations.localeOf(context).languageCode),
                            unlocked: unlocked,
                            // Unlocked badges are complete; only a locked
                            // badge with a measurable source shows a line.
                            progress:
                                unlocked ? null : badgeProgress[item.key],
                          );
                          if (reduceMotion || index >= 9) return tile;
                          // m.stagger, row by row (30ms), plays once.
                          return tile
                              .animate(delay: (30 * (index ~/ 3)).ms)
                              .fadeIn(
                                  duration: AppMotion.base,
                                  curve: AppMotion.easeOut)
                              .moveY(
                                  begin: AppMotion.enterRise,
                                  end: 0,
                                  duration: AppMotion.moderate,
                                  curve: AppMotion.easeOut);
                        },
                      ),
                    ],
                  ),
                ),
                // A DIRECT child of the ListView, deliberately.
                //
                // `SliverList` materialises its direct children lazily, so a
                // banner here buys nothing until the user has scrolled past the
                // badge grid. Move it inside the `Padding` above and it becomes
                // part of that child, which is built as one unit — and the ad
                // would be requested on arrival for a slot far below the fold.
                // Verified both ways in banner_placement_mechanics_test.dart.
                //
                // After the grid, never inside it: a cell-sized ad among badge
                // cells reads as a badge.
                if (data.achievements.isNotEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.gutter),
                    child: QirshAdBanner(placement: AdPlacement.achievements),
                  ),
                // Clearance for the floating nav bar. An ad the bar sits on top
                // of is an obscured ad, which is a placement-policy problem and
                // not a cosmetic one.
                const SizedBox(
                  height: AppSpacing.navBarHeight + AppSpacing.navBarInset * 2,
                ),
              ],
            ),
          );
        },
      )),
    );
  }

  String _levelName(BuildContext context, String levelKey) {
    switch (levelKey) {
      case 'organized':
        return context.l10n.achLevelOrganised;
      case 'smart_saver':
        return context.l10n.achLevelSmartSaver;
      case 'financial_expert':
        return context.l10n.achLevelExpert;
      case 'saving_legend':
        return context.l10n.achLevelLegend;
      case 'beginner':
      default:
        return context.l10n.achLevelBeginner;
    }
  }
}

/// Each badge keeps its own glyph (dimmed when locked) instead of a padlock.
IconData _badgeGlyph(String key) => switch (key) {
      'first_transaction' => AppLucideIcons.sparkles,
      'tenth_transaction' => AppLucideIcons.receipt,
      'century_transaction' => AppLucideIcons.layers,
      'first_budget' => AppLucideIcons.wallet,
      'streak_7_days' => AppLucideIcons.flame,
      'month_without_overrun' => AppLucideIcons.shieldCheck,
      'saved_500' => AppLucideIcons.piggyBank,
      'first_goal' => AppLucideIcons.target,
      'restaurants_minus_20' => AppLucideIcons.utensilsCrossed,
      _ => AppLucideIcons.medal,
    };

/// v2 level hero (spec 20): Hero role — per-theme brand gradient, coin art on
/// the trailing side, gold level overline, gold XP bar, streak chip.
class _LevelHero extends StatelessWidget {
  const _LevelHero({
    required this.level,
    required this.levelName,
    required this.totalXp,
    required this.nextThreshold,
    required this.progress,
    required this.streakDays,
  });

  final int level;
  final String levelName;
  final int totalXp;
  final int? nextThreshold;
  final double progress;
  final int streakDays;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final reduceMotion = shouldReduceMotion(context);
    // Spec §2.2 Hero + §3.0 row 20 (hero values, both themes).
    final gradient = dark
        ? const [AppBrandBlue.deep, AppBrandBlue.brand, AppBrandBlue.strong]
        : const [AppBrandBlue.brand, AppBrandBlue.strong, AppBrandBlue.mid];
    final track = Colors.white.withValues(alpha: dark ? .16 : .24);
    final chipFill = Colors.white.withValues(alpha: dark ? .14 : .18);
    final chipText =
        dark ? context.colors.goldText : AppBrandAccent.goldLit;
    return RepaintBoundary(
      child: Container(
        // Full width: the parent Column aligns start, which would otherwise
        // shrink the hero to its text and push the coin over the title.
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: 196),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.screenSheet),
          gradient: LinearGradient(
            colors: gradient,
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
          ),
          border: Border.all(
              color: Colors.white.withValues(alpha: dark ? .14 : .28),
              width: .5),
          boxShadow: dark
              ? AppShadows.heroGlow
              : const [
                  BoxShadow(
                      color: Color(0x47155DFC),
                      blurRadius: 32,
                      offset: Offset(0, 12)),
                ],
        ),
        child: Stack(
          children: [
            PositionedDirectional(
              end: 14,
              top: 52,
              child: ExcludeSemantics(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                          color: Color(0x66000000),
                          blurRadius: 24,
                          offset: Offset(0, 10)),
                    ],
                  ),
                  child: Image.asset(AppAssets.qirshCoinGold,
                      width: 120, height: 120, cacheWidth: 360),
                ),
              ),
            ),
            PositionedDirectional(
              end: 16,
              top: 16,
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: chipFill,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(AppLucideIcons.flame, size: 14, color: chipText),
                  const SizedBox(width: 4),
                  Text(context.l10n.achStreakDays(streakDays),
                      style: AppTypography.overline(chipText)),
                ]),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(20),
              child: FractionallySizedBox(
                alignment: AlignmentDirectional.centerStart,
                widthFactor: .58,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${context.l10n.achLevel} $level',
                        style: AppTypography.overline(AppBrandAccent.goldLit)),
                    Text(levelName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.titleLarge(Colors.white)),
                    const SizedBox(height: 40),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.pill),
                      child: SizedBox(
                        height: 10,
                        child: ColoredBox(
                          color: track,
                          child: TweenAnimationBuilder<double>(
                            tween: Tween(end: progress),
                            duration: reduceMotion
                                ? Duration.zero
                                : const Duration(milliseconds: 600),
                            curve: AppMotion.easeOut,
                            builder: (context, value, _) =>
                                FractionallySizedBox(
                              alignment: AlignmentDirectional.centerStart,
                              widthFactor: value,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: AlignmentDirectional.centerStart,
                                    end: AlignmentDirectional.centerEnd,
                                    colors: [
                                      AppBrandAccent.goldLit,
                                      Color(0xFFFBC926),
                                      AppBrandAccent.goldDeep,
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      nextThreshold == null
                          ? '$totalXp XP'
                          : '$totalXp/$nextThreshold XP',
                      textDirection: TextDirection.ltr,
                      style: AppTypography.mono(
                        size: 13,
                        color: Colors.white.withValues(alpha: .8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One badge: medallion (own glyph; locked = muted disc, unlocked = gold),
/// title (always text.primary — locked is not disabled), an optional 3pt
/// progress line, and a state caption.
class _BadgeTile extends StatelessWidget {
  const _BadgeTile({
    required this.glyph,
    required this.title,
    required this.unlocked,
    required this.progress,
  });

  final IconData glyph;
  final String title;
  final bool unlocked;

  /// 0..1 toward this badge, or null when it has no measurable source.
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final value = progress;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(AppRadius.card),
        border: dark ? Border.all(color: c.border) : null,
        boxShadow: AppShadows.group(brightness),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: unlocked ? null : c.surfaceElevated,
              border: unlocked ? null : Border.all(color: c.strokeSoft),
              gradient: unlocked
                  ? const RadialGradient(
                      center: Alignment(-.3, -.4),
                      colors: [
                        AppBrandAccent.goldLit,
                        Color(0xFFFBC926),
                        AppBrandAccent.goldDeep,
                      ],
                      stops: [0, .55, 1],
                    )
                  : null,
              boxShadow: unlocked
                  ? const [
                      BoxShadow(
                          color: Color(0x59FBC926),
                          blurRadius: 16,
                          offset: Offset(0, 6)),
                    ]
                  : null,
            ),
            child: Icon(
              glyph,
              size: 26,
              color: unlocked
                  ? const Color(0xFF3A2A00)
                  : dark
                      ? Colors.white.withValues(alpha: .35)
                      : c.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 36,
            child: Center(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(c.textPrimary)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ),
          ),
          if (value != null) ...[
            const SizedBox(height: 8),
            Semantics(
              value: '${(value * 100).round()}%',
              child: FractionallySizedBox(
                widthFactor: .7,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: SizedBox(
                    height: 3,
                    child: ColoredBox(
                      color: dark
                          ? Colors.white.withValues(alpha: .12)
                          : c.surfaceMuted,
                      child: FractionallySizedBox(
                        alignment: AlignmentDirectional.centerStart,
                        widthFactor: value.clamp(0, 1).toDouble(),
                        child: ColoredBox(color: c.cta),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            unlocked ? context.l10n.achUnlocked : context.l10n.achInProgress,
            style: AppTypography.caption(unlocked ? c.goldText : c.textMuted),
          ),
        ],
      ),
    );
  }
}

class _AchievementsHeader extends StatelessWidget {
  const _AchievementsHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.gutter, 8, AppSpacing.gutter, 12),
      child: Text(context.l10n.achSubtitle,
          style: AppTypography.callout(context.colors.textSecondary)),
    );
  }
}
