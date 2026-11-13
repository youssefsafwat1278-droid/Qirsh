import '../help/coach_marks.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui' show FontFeature, ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/backend/auth_client_provider.dart';
import '../../core/session/app_session.dart';
import '../../core/theme/app_assets.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/mali_tokens.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/mali_screen.dart';
import '../../core/theme/widgets/app_toast.dart';
import '../../core/theme/widgets/ring_progress.dart';
import '../../core/theme/widgets/section_header.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../../domain/finance/daily_allowance.dart';
import '../../domain/finance/money.dart';
import '../../domain/finance/hero_amount_size.dart';
import '../../domain/finance/money_format.dart';
import '../../core/security/app_lock_service.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../app/app_shell.dart';
import '../cards/brand_mark.dart';
import '../consent/cloud_resume_banner.dart';
import '../coupons/coupon_widgets.dart';
import '../coupons/coupons_providers.dart';
import '../goals/goals_providers.dart';
import '../plans/plan_form_sheet.dart';
import '../plans/plans_screen.dart';
import '../common/premium_loading.dart';
// hide SectionHeader — we use the Calm Capital archetype of the same name.
import '../common/widgets.dart' hide SectionHeader;
import '../settings/settings_providers.dart';
import '../capture/capture_entry_sheet.dart';
import '../capture/manual_paste_screen.dart';
import '../capture/sms_permission_screen.dart';
import '../common/transaction_direction.dart';
import '../common/app_status_pill.dart';
import '../common/motion.dart';
import '../onboarding/ios_shortcut_guide.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';
import 'home_sections_providers.dart';
import 'widgets/budgets_card.dart';
import 'widgets/coupons_corner.dart';
import 'widgets/daily_spend_card.dart';
import 'widgets/home_overview_cards.dart';
import 'widgets/home_v2_style.dart';
import 'widgets/transactions_panel.dart';
import '../../core/theme/widgets/glass_pickers.dart';

/// Home — the Calm Capital flagship dashboard (docs/MALI_DESIGN_SYSTEM.md).
///
/// Rebuilt from scratch: the whole screen is composed from the archetype
/// primitives over a single read-only source, [dashboardDataProvider]. No sync,
/// DB, or parser behavior lives here — this is presentation only.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(dashboardDataProvider);
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    // valueOrNull (not maybeWhen) so privacyMode holds through a reload instead
    // of flashing hidden→shown on every account switch / sync.
    final privacyMode = settings?.privacyModeEnabled ?? false;

    return MaliScreen(
      padding: EdgeInsets.zero,
      safeArea: false,
      // v2: الهيرو كارت مستقل هو مصدر الأزرق الوحيد — من غير هالة زرقا في
      // الخلفية ورا المحتوى.
      ambient: false,
      child: FirstUseGuide(
          id: CoachMarkIds.dashboard,
          marks: dashboardCoachMarks,
          child: _HomeChrome(
            data: async.valueOrNull,
            privacyMode: privacyMode,
            child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(dashboardDataProvider),
            child: async.when(
              skipLoadingOnReload: true,
              loading: () => const _HomeLoading(),
              error: (error, stack) {
                // الرسالة العامة بتخفي السبب — نطبعه في الديباج عشان يتشاف في
                // الكونسول بدل ما نخمّن.
                assert(() {
                  debugPrint('[dashboard] load failed: $error\n$stack');
                  return true;
                }());
                if (error is AuthRepoException) {
                  final authFailure = AppSession.instance
                      .captureAuthRequiredFailure(ref.read(authClientProvider));
                  Future<void> recover() async {
                    if (!context.mounted ||
                        !identical(ref.read(dashboardDataProvider), async)) {
                      return;
                    }
                    await authFailure();
                  }

                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => recover());
                  return _errorList(
                    title: context.l10n.homeSessionExpiredTitle,
                    description: context.l10n.homeSessionExpiredBody,
                    retryLabel: context.l10n.homeSignIn,
                    onRetry: recover,
                  );
                }
                return _errorList(
                  title: context.l10n.homeLoadFailed,
                  description: context.l10n.homeLoadFailedBody,
                  retryLabel: context.l10n.annRetry,
                  onRetry: () => ref.invalidate(dashboardDataProvider),
                );
              },
              data: (data) => _HomeBody(
                data: data,
                displayName: settings?.displayName,
                avatarPath: settings?.avatarPath,
                privacyMode: privacyMode,
              ),
            ),
          ))),
    );
  }

  Widget _errorList({
    required String title,
    required String description,
    required String retryLabel,
    required VoidCallback onRetry,
  }) =>
      ListView(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        children: [
          const SizedBox(height: AppSpacing.s7),
          AppErrorState(
            title: title,
            description: description,
            retryLabel: retryLabel,
            onRetry: onRetry,
          ),
        ],
      );
}

// ─── Insight strip ────────────────────────────────────────────────────────────

/// Spec «05» item 7: the three promo-style blocks (savings growth, the
/// matched-period category comparison, finishing setup) merged into one
/// horizontal pager of tinted cards — one visible with a 24pt peek, page
/// dots underneath. Every card is built up front (a `Row`, not a lazy
/// `PageView`) so each one sizes to its own copy at any text scale.
class _InsightPager extends ConsumerStatefulWidget {
  const _InsightPager({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  ConsumerState<_InsightPager> createState() => _InsightPagerState();
}

class _InsightPagerState extends ConsumerState<_InsightPager> {
  final ScrollController _controller = ScrollController();
  final ValueNotifier<int> _page = ValueNotifier<int>(0);

  static const double _gap = 10;
  static const double _peek = 24;

  @override
  void dispose() {
    _controller.dispose();
    _page.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final nudge = _setupNudgeState(ref);
    final cards = <Widget>[
      _SavingsInsight(data: data, privacyMode: widget.privacyMode),
      if (data.topCategories.any((slice) =>
          slice.changeRatio != null &&
          (slice.changeRatio! * 100).round() != 0))
        _CategoryInsight(data: data),
      if (nudge != null)
        _SetupNudgeCard(lockEnabled: nudge.lockEnabled, hasGoals: nudge.hasGoals),
    ];
    return LayoutBuilder(builder: (context, box) {
      final paged = cards.length > 1;
      final width = paged ? box.maxWidth - _peek : box.maxWidth;
      final extent = width + _gap;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NotificationListener<ScrollNotification>(
            onNotification: (n) {
              if (n.depth == 0 && n.metrics.axis == Axis.horizontal) {
                final page = (n.metrics.pixels / extent)
                    .round()
                    .clamp(0, cards.length - 1);
                if (page != _page.value) _page.value = page;
              }
              return false;
            },
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              physics: paged
                  ? _SnapPhysics(extent: extent)
                  : const NeverScrollableScrollPhysics(),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      if (i > 0) const SizedBox(width: _gap),
                      SizedBox(width: width, child: cards[i]),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (paged) ...[
            const SizedBox(height: 10),
            ExcludeSemantics(
              child: ValueListenableBuilder<int>(
                valueListenable: _page,
                builder: (context, page, _) => Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < cards.length; i++)
                      AnimatedContainer(
                        duration: AppMotion.base,
                        curve: AppMotion.easeOut,
                        margin: const EdgeInsets.symmetric(horizontal: 3),
                        width: i == page ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: i == page
                              ? context.colors.cta
                              : context.colors.strokeSoft,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      );
    });
  }
}

/// Snaps the insight pager to whole cards (a card is narrower than the
/// viewport, so `PageScrollPhysics` would snap to the wrong positions).
class _SnapPhysics extends ScrollPhysics {
  const _SnapPhysics({required this.extent, super.parent});

  final double extent;

  @override
  _SnapPhysics applyTo(ScrollPhysics? ancestor) =>
      _SnapPhysics(extent: extent, parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
      ScrollMetrics position, double velocity) {
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    var page = position.pixels / extent;
    if (velocity < -tolerance.velocity) {
      page -= 0.5;
    } else if (velocity > tolerance.velocity) {
      page += 0.5;
    }
    final target = (page.roundToDouble() * extent)
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < tolerance.distance) return null;
    return ScrollSpringSimulation(spring, position.pixels, target, velocity,
        tolerance: tolerance);
  }
}

/// One tinted insight card (v2 Tinted role): `infoBg`, radius 20; dark adds a
/// 1px info hairline @24%. Title `title.card`, body `callout`, one plain
/// action.
class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.leading,
    required this.title,
    required this.body,
    this.action,
    this.onDismiss,
  });

  final Widget leading;
  final String title;
  final List<Widget> body;
  final Widget? action;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = HomeV2.isDark(context);
    final stacked = MediaQuery.textScalerOf(context).scale(16) > 21;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(title, style: AppTypography.cardTitle(c.textPrimary)),
            ),
            if (onDismiss != null)
              Semantics(
                button: true,
                label: MaterialLocalizations.of(context).closeButtonTooltip,
                excludeSemantics: true,
                child: InkResponse(
                  onTap: onDismiss,
                  radius: 22,
                  child: SizedBox(
                    width: 32,
                    height: 32,
                    child: Icon(AppLucideIcons.x, size: 18, color: c.textMuted),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        ...body,
        if (action != null) ...[
          const Spacer(),
          const SizedBox(height: 4),
          action!,
        ],
      ],
    );
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.infoBg,
        borderRadius: BorderRadius.circular(20),
        border: isDark
            ? Border.all(color: c.info.withValues(alpha: 0.24))
            : null,
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(height: AppSpacing.s3),
                Expanded(child: content),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                leading,
                const SizedBox(width: AppSpacing.s3),
                Expanded(child: content),
              ],
            ),
    );
  }
}

/// A plain (text-only) insight action in `action.text`.
Widget _insightAction(BuildContext context, String label, VoidCallback onTap) =>
    TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: context.colors.actionText,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        minimumSize: const Size(44, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        alignment: AlignmentDirectional.centerStart,
        textStyle: AppTypography.subhead(context.colors.actionText)
            .copyWith(fontWeight: FontWeight.w600),
      ),
      child: Text(label),
    );

/// «نمو مدخراتك» — the coin-stack photo is a 96pt rounded thumbnail now, not
/// a full-bleed dark block (removes the dark island, L10).
class _SavingsInsight extends StatelessWidget {
  const _SavingsInsight({required this.data, required this.privacyMode});
  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final surplus = data.incomeThisMonth - data.spentThisMonth;
    final amount = privacyMode
        ? '••••'
        : '${Formatters.amount(surplus.toDouble().abs())} ${Currency.label(context, data.currency)}';
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return _InsightCard(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Image.asset(
          QirshPhoto.growth.assetPath,
          width: 96,
          height: 96,
          cacheWidth: (96 * dpr).round(),
          fit: BoxFit.cover,
          alignment: QirshPhoto.growth.focalOffset,
          excludeFromSemantics: true,
        ),
      ),
      title: context.l10n.homeSavingsGrowing,
      body: [
        Text(
            surplus.isNegative
                ? context.l10n.homeSpendingAhead(amount)
                : context.l10n.homeSavingsSurplus(amount),
            style: AppTypography.callout(c.textSecondary)),
        Text(context.l10n.homeSavingsMotivation,
            style: AppTypography.caption(c.textMuted)),
      ],
      action: _insightAction(
          context, context.l10n.homeAddToGoal, () => context.push('/goals')),
    );
  }
}

/// The matched-period category change, with the same comparison as the
/// category card below it.
class _CategoryInsight extends ConsumerWidget {
  const _CategoryInsight({required this.data});
  final DashboardData data;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final comparisons = data.topCategories.where((slice) =>
        slice.changeRatio != null && (slice.changeRatio! * 100).round() != 0);
    final slice = comparisons.isEmpty ? null : comparisons.first;
    final change = slice?.changeRatio;
    final percent =
        change == null ? null : (change.abs() * 100).round().clamp(0, 999);
    final accent = slice == null
        ? c.actionText
        : slice.category.accent(Theme.of(context).brightness);
    return _InsightCard(
      leading: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: HomeV2.isDark(context) ? 0.16 : 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(slice?.category.icon ?? AppLucideIcons.pieChart,
            size: 22, color: accent),
      ),
      title: context.l10n.rptVsPrevPeriod,
      body: [
        if (slice != null)
          Text(slice.category.name,
              style: AppTypography.bodyStrong(c.textPrimary)),
        Text(
            percent == null
                ? context.l10n.rptNeedPrevPeriod
                : change! < 0
                    ? context.l10n.rptSpendLower(percent)
                    : context.l10n.rptSpendHigher(percent),
            style: AppTypography.callout(c.textSecondary)),
      ],
      action: _insightAction(context, context.l10n.rptTabDetails,
          () => ref.read(shellIndexProvider.notifier).state = 4),
    );
  }
}

class _HomeBody extends ConsumerWidget {
  const _HomeBody({
    required this.data,
    required this.displayName,
    required this.avatarPath,
    required this.privacyMode,
  });

  final DashboardData data;
  final String? displayName;
  final String? avatarPath;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // An account that has never had a transaction gets the first-run Home
    // (welcome + three start steps) instead of a hero full of zeros. A period
    // that is merely empty is NOT that: it keeps the normal layout, and the
    // sections a user owns keep rendering with their own empty notes.
    final firstRun = !data.hasAnyTransactions;
    final reviewFirst = !firstRun && data.pendingReviewCount > 0;
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _BlueZone(
          data: data,
          displayName: displayName,
          avatarPath: avatarPath,
          privacyMode: privacyMode,
          firstRun: firstRun,
        ),
        _Sheet(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CloudResumeBanner(),
              if (firstRun) ...[
                _WelcomeBody(data: data),
                // Anything the user created before their first transaction
                // still shows; empty ones stay out of the welcome screen.
                _BudgetsSection(data: data, privacyMode: privacyMode),
                _UpcomingSection(privacyMode: privacyMode),
                _GoalsPlansSection(privacyMode: privacyMode),
              ] else ...[
                const AnnouncementBanner(),
                // «للمراجعة» first: the only block that asks for an action.
                if (reviewFirst) ...[
                  _ReviewSection(data: data, privacyMode: privacyMode),
                  const SizedBox(height: AppSpacing.sectionGap),
                ],
                if (!data.isEmpty) ...[
                  _recentSection(context, ref),
                  const SizedBox(height: AppSpacing.sectionGap),
                ],
                if (data.todayTransactions.isNotEmpty ||
                    data.lastSevenDays.any((day) => !day.total.isZero)) ...[
                  _todaySection(context, ref, onBlue: false),
                  const SizedBox(height: AppSpacing.sectionGap),
                ],
                _InsightPager(data: data, privacyMode: privacyMode),
                if (data.topCategories.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.sectionGap),
                  _categoriesSection(context, ref),
                ],
                _BudgetsSection(data: data, privacyMode: privacyMode),
                _UpcomingSection(privacyMode: privacyMode),
                _GoalsPlansSection(privacyMode: privacyMode),
              ],
              // THE BANNER — after everything the user owns, so the first
              // things on Home are always their own money.
              //
              // NO horizontal padding here. `_Sheet` already insets its child by
              // `AppSpacing.gutter` on both sides, so wrapping the banner in
              // another gutter made the slot 310pt on a 390pt screen — under the
              // 320 minimum `BannerAdController.request()` enforces, which
              // refused the request before `resolveHeight` and left the slot at
              // zero height. The banner inherits the sheet's inset instead.
              const SizedBox(height: AppSpacing.s6),
              const QirshAdBanner(placement: AdPlacement.dashboard),
              const SizedBox(height: AppSpacing.s6),
              if (!firstRun) ...[
                const _DashboardCouponsRail(),
                const SizedBox(height: AppSpacing.s6),
              ],
            ],
          ),
        ),
        // Clearance for the floating tab bar.
        const SizedBox(height: 112),
      ],
    );
  }

  // ── «اليوم» ────────────────────────────────────────────────────────────────

  Widget _todaySection(BuildContext context, WidgetRef ref,
      {required bool onBlue}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeSectionTitle(title: context.l10n.txnRangeToday, onBlue: onBlue),
        const SizedBox(height: AppSpacing.s3),
        // The previous Home's «المصروفات اليومية» card: today's spend, what is
        // left for today, the week's bars and today's largest transactions.
        DailySpendCard(
          todaySpend: data.todaySpend,
          lastSevenDays: data.lastSevenDays,
          averageSevenDays:
              averageDailySpend(data.lastSevenDays, data.currency),
          availableToday: data.availableToday,
          dailyBudgetLimit: data.dailyBudgetLimit,
          todayVsYesterday: data.todayVsYesterday,
          todayTransactions: data.todayTransactions,
          todayIsTruncated: data.todayIsTruncated,
          catalog: data.catalog,
          currencyLabel: Currency.label(context, data.currency.toUpperCase()),
          privacyMode: privacyMode,
          merchantLogos: ref.watch(merchantLogosProvider).valueOrNull ??
              const <String, String>{},
          onTransactionTap: (tx) =>
              TransactionDetailsScreen.showSheet(context, tx.id),
        ),
      ],
    );
  }

  // ── «أين ذهبت أموالك» ──────────────────────────────────────────────────────

  Widget _categoriesSection(BuildContext context, WidgetRef ref) {
    final t = MaliTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeSectionTitle(
          title: context.l10n.homeWhereMoneyWent,
          trailing: context.l10n.homeDetails,
          onTrailingTap: () => ref.read(shellIndexProvider.notifier).state = 4,
        ),
        const SizedBox(height: AppSpacing.s2),
        // The range these categories (and «آخر العمليات») cover. It is the
        // same range the Transactions tab uses, so it says so and stays
        // changeable from here.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: InkWell(
            borderRadius: BorderRadius.circular(AppRadius.pill),
            onTap: () => _showRangeSheet(context, ref, data.range),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(AppLucideIcons.calendarDays,
                      size: 14, color: t.textOnCanvasMuted),
                  const SizedBox(width: 6),
                  Text(
                    data.range
                        .labelIn(Localizations.localeOf(context).languageCode),
                    style: AppTypography.caption(t.textOnCanvasSecondary),
                  ),
                  Icon(AppLucideIcons.chevronDown,
                      size: 14, color: t.textOnCanvasMuted),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.s2),
        CategorySpendCard(
          categories: data.topCategories,
          privacyMode: privacyMode,
        ),
      ],
    );
  }

  // ── «آخر العمليات» ─────────────────────────────────────────────────────────

  Widget _recentSection(BuildContext context, WidgetRef ref) {
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeSectionTitle(
          title: context.l10n.homeRecentTx,
          trailing: context.l10n.homeSeeAll,
          onTrailingTap: () => ref.read(shellIndexProvider.notifier).state = 1,
        ),
        const SizedBox(height: AppSpacing.s3),
        TransactionsPanel(
          days: groupByDay(data.recent.take(3).toList()),
          compact: true,
          catalog: data.catalog,
          merchantLogos: logos,
          privacyMode: privacyMode,
          onTap: (tx) => TransactionDetailsScreen.showSheet(context, tx.id),
        ),
      ],
    );
  }

  // ── Range sheet (preserved from the previous screen) ───────────────────────

  Future<void> _showRangeSheet(
    BuildContext context,
    WidgetRef ref,
    TransactionsDateRange current,
  ) async {
    var from = current.from;
    var to = current.to;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => navySheetTheme(StatefulBuilder(
        builder: (context, setState) {
          final c = context.colors;
          return AppSheetScaffold(
            title: context.l10n.txnPickRange,
            scrollable: true,
            body: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final preset in TransactionsDatePreset.values)
                        ChoiceChip(
                          label: Text(_presetLabel(context, preset)),
                          selected: current.preset == preset,
                          onSelected: (_) {
                            if (preset == TransactionsDatePreset.custom) {
                              setState(() {});
                              return;
                            }
                            ref
                                .read(transactionsDateRangeProvider.notifier)
                                .state = transactionsRangeForPreset(
                              preset,
                              customFallback: defaultTransactionsRange(),
                            );
                            Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surface,
                      borderRadius: BorderRadius.circular(AppRadius.card),
                      border: Border.all(color: c.border),
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: Column(
                        children: [
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(context.l10n.txnFrom),
                            subtitle: Text(Formatters.fullDate(from, context)),
                            trailing: const Icon(AppLucideIcons.calendarDays),
                            onTap: () async {
                              final picked = await showGlassDatePicker(
                                context: context,
                                initialDate: from,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now()
                                    .add(const Duration(days: 365)),
                              );
                              if (picked != null) {
                                setState(() => from = picked);
                              }
                            },
                          ),
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(context.l10n.txnTo),
                            subtitle: Text(Formatters.fullDate(to, context)),
                            trailing: const Icon(AppLucideIcons.calendarDays),
                            onTap: () async {
                              final picked = await showGlassDatePicker(
                                context: context,
                                initialDate: to,
                                firstDate: DateTime(2020),
                                lastDate: DateTime.now()
                                    .add(const Duration(days: 365)),
                              );
                              if (picked != null) setState(() => to = picked);
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            bottomAction: FilledButton(
              onPressed: to.isBefore(from)
                  ? null
                  : () {
                      ref.read(transactionsDateRangeProvider.notifier).state =
                          TransactionsDateRange(
                        preset: TransactionsDatePreset.custom,
                        from: from,
                        to: DateTime(to.year, to.month, to.day, 23, 59, 59),
                      );
                      Navigator.of(context).pop();
                    },
              child: Text(context.l10n.txnApplyCustomRange),
            ),
          );
        },
      )),
    );
  }

  String _presetLabel(BuildContext context, TransactionsDatePreset preset) =>
      switch (preset) {
        TransactionsDatePreset.today => context.l10n.txnRangeToday,
        TransactionsDatePreset.thisWeek => context.l10n.txnRangeThisWeek,
        TransactionsDatePreset.thisMonth => context.l10n.txnRangeThisMonth,
        TransactionsDatePreset.previousMonth => context.l10n.txnRangeLastMonth,
        TransactionsDatePreset.last7Days => context.l10n.txnRange7,
        TransactionsDatePreset.last30Days => context.l10n.txnRange30,
        TransactionsDatePreset.last90Days => context.l10n.txnRange90,
        TransactionsDatePreset.thisYear => context.l10n.txnRangeThisYear,
        TransactionsDatePreset.previousYear => context.l10n.txnRangeLastYear,
        TransactionsDatePreset.custom => context.l10n.txnRangeCustom,
      };
}

// ─── Header + hero ────────────────────────────────────────────────────────────

/// The top of Home (spec «05» items 1–3): the greeting row on the plain
/// canvas, the hero card, and the quick actions.
///
/// v2: the hero is a self-contained card with a hard edge in both themes — it
/// never fades into the page (fixes L4). Dark keeps a quiet aurora on black
/// behind the header zone; light has none, so the hero carries all the blue.
// Retained Flutter-only trend feature, below the approved Home sections.
// The summary hero keeps the prototype's pace bar and three totals.
class _BlueZone extends ConsumerWidget {
  const _BlueZone({
    required this.data,
    required this.privacyMode,
    required this.firstRun,
    this.displayName,
    this.avatarPath,
  });

  final DashboardData data;
  final bool privacyMode;
  final bool firstRun;
  final String? displayName;
  final String? avatarPath;

  // The hero's semantic tint (white-on-blue legible), same as before.
  static const _income = Color(0xFF4ADE80);

  String _name(BuildContext context) {
    final n = displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final email = AppSession.instance.email;
    if (email == null || email.trim().isEmpty) {
      return context.l10n.homeMoneyFriend;
    }
    final local = email.split('@').first.trim();
    if (local.isEmpty || local.toLowerCase() == 'user') {
      return context.l10n.homeMoneyFriend;
    }
    return local.replaceAll(RegExp(r'[._]'), ' ');
  }

  String _initials(String name) {
    final parts =
        name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return 'م';
    if (parts.length == 1) return parts.first.characters.first;
    return '${parts.first.characters.first}${parts[1].characters.first}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = HomeV2.isDark(context);
    final topPad = MediaQuery.paddingOf(context).top;
    final t = MaliTokens.of(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Dark only: the aurora on black behind the header zone, fading to
        // full transparency so the page's grain shows through gradually (an
        // opaque fade hid that texture until its edge, leaving a seam).
        if (isDark)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: -_heroMeltOverflow,
            child: IgnorePointer(
              child: ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, 0.5, 1.0],
                  colors: [Colors.white, Colors.white, Colors.transparent],
                ).createShader(bounds),
                child: Container(
                  key: const ValueKey('home-blue-backdrop'),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const AlignmentDirectional(0.7, -1.0)
                          .resolve(Directionality.of(context)),
                      radius: 1.1,
                      colors: [t.auroraTop, t.auroraTop.withValues(alpha: 0)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter, topPad + 8, AppSpacing.gutter, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HomeEnter(index: 0, child: _topRow(context, ref)),
              const SizedBox(height: AppSpacing.s4),
              _HomeEnter(
                index: 1,
                child: RepaintBoundary(
                  child: _HeroCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: firstRun
                          ? _welcome(context)
                          : _figures(context, ref),
                    ),
                  ),
                ),
              ),
              if (!firstRun) ...[
                const SizedBox(height: AppSpacing.s4),
                const _QuickActions(),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _topRow(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final name = _name(context);
    final path = avatarPath?.trim();
    final file = (path == null || path.isEmpty) ? null : File(path);
    final hasImage = file != null && file.existsSync();
    final greeting = firstRun
        ? context.l10n.homeWelcomeTo
        : (DateTime.now().hour < 12
            ? context.l10n.homeGoodMorning
            : context.l10n.homeGoodEvening);
    return Row(
      children: [
        // The brand moment lives in the avatar's gold ring (1.5pt, with a
        // canvas gap) — one mark instead of a separate coin icon.
        Container(
          width: 42,
          height: 42,
          padding: const EdgeInsets.all(3.5),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: c.bg,
            border: Border.all(color: c.accent, width: 1.5),
          ),
          child: Container(
            alignment: Alignment.center,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: c.ctaSoft, shape: BoxShape.circle),
            child: hasImage
                ? Image.file(file, fit: BoxFit.cover, width: 35, height: 35)
                : Text(_initials(name),
                    style: AppTypography.label(c.actionText)
                        .copyWith(fontWeight: FontWeight.w700)),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(greeting, style: AppTypography.caption(c.textSecondary)),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.cardTitle(c.textPrimary)),
            ],
          ),
        ),
        Semantics(
          button: true,
          label: context.l10n.annTitle,
          excludeSemantics: true,
          child: HomePressScale(
            scale: AppMotion.pressScaleIcon,
            onTap: () => context.push('/announcements'),
            child: Container(
              width: 44,
              height: 44,
              decoration: HomeV2.group(context, radius: 22),
              child: Icon(AppLucideIcons.bell, color: c.textPrimary, size: 22),
            ),
          ),
        ),
        const SizedBox(width: 6),
        const CoachAnchor(target: 'add', child: _AddButton()),
      ],
    );
  }

  List<Widget> _welcome(BuildContext context) => [
        Image.asset(
          AppAssets.qirshCoinGold,
          width: 64,
          height: 64,
          excludeFromSemantics: true,
        ),
        const SizedBox(height: 14),
        Text(context.l10n.homeWelcomeTitle,
            style: AppTypography.title1(Colors.white).copyWith(height: 1.3)),
        const SizedBox(height: 8),
        Text(context.l10n.homeWelcomeBody,
            style: AppTypography.callout(Colors.white.withValues(alpha: 0.8))),
      ];

  List<Widget> _figures(BuildContext context, WidgetRef ref) {
    final period = ref.watch(heroPeriodProvider);
    final currencyLabel = Currency.label(context, data.currency.toUpperCase());
    String money(Money m) => privacyMode ? '••••' : formatMoney(m);

    final heroValue = _heroValue(data, period);
    final heroLabel = _heroLabel(context, period);

    final hasBudget =
        !data.monthlyBudgetLimit.isZero && !data.monthlyBudgetLimit.isNegative;
    final limit = data.monthlyBudgetLimit.toDouble();
    final spentMonth = data.spentThisMonth.toDouble();

    // The line under the figure.
    final String sub;
    switch (period) {
      case HeroPeriod.month:
        if (!hasBudget) {
          sub = context.l10n.homeProjectedMonthEnd(privacyMode
              ? '••••'
              : Formatters.amount(data.projectedMonthSpend));
        } else if (spentMonth > limit) {
          sub = context.l10n.homeBudgetOverBy(money(data.monthlyBudgetLimit),
              privacyMode ? '••••' : Formatters.amount(spentMonth - limit));
        } else {
          sub = context.l10n.homeBudgetLeft(money(data.monthlyBudgetLimit),
              privacyMode ? '••••' : Formatters.amount(limit - spentMonth));
        }
      case HeroPeriod.week:
        sub = context.l10n.homeLastWeekWas(money(data.previousWeekSpend));
      case HeroPeriod.day:
        final count =
            context.l10n.homeTodayTxCount(data.todayTransactions.length);
        final available = data.availableToday;
        sub = available == null
            ? count
            : '$count · ${context.l10n.homeLeftTodayShort(money(available))}';
    }

    // The chip under the pace bar: how this period sits against its
    // yardstick.
    String? pace;
    var good = true;
    VoidCallback? paceTap;
    switch (period) {
      case HeroPeriod.month:
        final expected = limit * data.monthElapsedRatio;
        if (!hasBudget || expected <= 0) {
          pace = context.l10n.homePaceSetBudget;
          paceTap = () => context.push('/budgets');
        } else {
          final pct = ((spentMonth / expected - 1) * 100).round();
          good = pct <= 0;
          pace = pct == 0
              ? context.l10n.homePaceOnTrack
              : pct < 0
                  ? context.l10n.homePaceUnder(pct.abs().clamp(0, 999))
                  : context.l10n.homePaceOver(pct.clamp(0, 999));
        }
      case HeroPeriod.week:
        final pct = (data.weekChangeRatio * 100).round();
        if (pct != 0) {
          good = pct < 0;
          pace = pct > 0
              ? context.l10n.homeWeekMoreThan(pct.clamp(0, 999))
              : context.l10n.homeWeekLessThan(pct.abs().clamp(0, 999));
        }
      case HeroPeriod.day:
        final ratio = data.todayVsYesterday;
        final pct = ratio == null ? 0 : (ratio * 100).round();
        if (pct != 0) {
          good = pct < 0;
          pace = pct > 0
              ? context.l10n.homeDayMoreThan(pct.clamp(0, 999))
              : context.l10n.homeDayLessThan(pct.abs().clamp(0, 999));
        }
    }

    final heroText = privacyMode ? '••••••' : formatMoney(heroValue);
    final showPaceBar = hasBudget && period != HeroPeriod.week;
    return [
      // Row A — account (quiet text button) + period segmented.
      LayoutBuilder(builder: (context, constraints) {
        final account = _accountSelector(context, ref);
        final periods = CoachAnchor(
            target: 'period',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _PeriodSegments(
                selected: period,
                onSelect: (value) async {
                  try {
                    await ref.read(heroPeriodProvider.notifier).select(value);
                  } catch (_) {
                    if (context.mounted) {
                      AppToast.showError(context, context.l10n.setupSaveFailed);
                    }
                  }
                },
              ),
            ));
        if (MediaQuery.textScalerOf(context).scale(16) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              account,
              const SizedBox(height: 8),
              Align(alignment: AlignmentDirectional.centerStart, child: periods)
            ],
          );
        }
        return Row(children: [
          Expanded(child: account),
          const SizedBox(width: AppSpacing.s2),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * .58),
            child: periods,
          ),
        ]);
      }),
      const SizedBox(height: AppSpacing.s4),
      // Row B — label · currency, with the eye toggle.
      Row(
        children: [
          Flexible(
            child: Text(heroLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(
                    Colors.white.withValues(alpha: 0.72))),
          ),
          Text(' · $currencyLabel',
              style:
                  AppTypography.caption(Colors.white.withValues(alpha: 0.72))),
          const SizedBox(width: 2),
          _eye(context, ref),
        ],
      ),
      // Row C — the amount: amount.hero, count-up, decimals at 62%.
      // A financial figure is never truncated: it scales down from a size
      // already chosen for its length (UX-035).
      FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: AnimatedSwitcher(
          duration: shouldReduceMotion(context)
              ? AppMotion.fast
              : AppMotion.base,
          child: privacyMode
              ? Text(
                  heroText,
                  key: const ValueKey('hero-hidden'),
                  maxLines: 1,
                  style: AppTypography.amountHero(Colors.white).copyWith(
                      fontSize: heroAmountFontSize(heroText.length, base: 48)),
                )
              : _HeroAmount(
                  key: const ValueKey('hero-amount'), value: heroValue),
        ),
      ),
      const SizedBox(height: 4),
      // Row D — one sentence.
      Text(sub,
          style: AppTypography.callout(Colors.white.withValues(alpha: 0.8))),
      if (showPaceBar) ...[
        const SizedBox(height: AppSpacing.s4),
        _budgetPace(context, period),
      ],
      if (pace != null) ...[
        const SizedBox(height: 10),
        _pacePill(context, pace, good, paceTap),
      ],
      const SizedBox(height: AppSpacing.s4),
      _heroTotals(context, period),
    ];
  }

  /// The hero's pace chip (v2 QStatusChip on the hero): warning-tinted when
  /// over pace, a quiet white tint otherwise. Pops in on `spring.lively`.
  Widget _pacePill(
      BuildContext context, String text, bool good, VoidCallback? onTap) {
    final isDark = HomeV2.isDark(context);
    final over = HomeV2.heroOverPace(isDark);
    final pill = Container(
      constraints: const BoxConstraints(minHeight: 24),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: good
            ? Colors.white.withValues(alpha: 0.14)
            : over.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(good ? AppLucideIcons.trendingDown : AppLucideIcons.trendingUp,
              size: 14, color: good ? _income : const Color(0xFFFFD9A8)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.overline(
                    good ? Colors.white : const Color(0xFFFFD9A8))),
          ),
        ],
      ),
    );
    final popped = TweenAnimationBuilder<double>(
      tween: Tween(begin: shouldReduceMotion(context) ? 1 : 0.85, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: AppMotion.springLivelyCurve,
      builder: (context, s, child) => Transform.scale(
          scale: s, alignment: AlignmentDirectional.centerStart.resolve(
              Directionality.of(context)), child: child),
      child: pill,
    );
    if (onTap == null) return popped;
    return GestureDetector(onTap: onTap, child: popped);
  }

  /// Row A's account selector — a quiet text button on the hero.
  Widget _accountSelector(BuildContext context, WidgetRef ref) {
    final accounts = ref.watch(accountsProvider).valueOrNull;
    final selectedId = ref.watch(dashboardAccountProvider);
    final String accountLabel;
    if (accounts == null || accounts.isEmpty) {
      accountLabel = context.l10n.homeAllAccounts;
    } else {
      final selected = accounts.firstWhere(
        (a) => a.id == selectedId,
        orElse: () => accounts.firstWhere((a) => a.isDefault,
            orElse: () => accounts.first),
      );
      // UX-007 — name the account, do not describe its currency. Home totals
      // are per-currency, so the currency stays as secondary context.
      accountLabel = '${selected.name} · '
          '${Currency.label(context, selected.currency.toUpperCase())}';
    }
    return CoachAnchor(
        target: 'account',
        child: Semantics(
          button: true,
          label: accountLabel,
          excludeSemantics: true,
          child: HomePressScale(
            onTap: () {
              HapticFeedback.selectionClick();
              context.push('/accounts');
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(AppLucideIcons.wallet,
                      size: 18, color: Colors.white),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(accountLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTypography.subhead(Colors.white)
                            .copyWith(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 4),
                  Icon(AppLucideIcons.chevronDown,
                      size: 16, color: Colors.white.withValues(alpha: 0.8)),
                ],
              ),
            ),
          ),
        ));
  }

  /// Row G — three QStats under a hairline, separated by vertical hairlines.
  Widget _heroTotals(BuildContext context, HeroPeriod period) {
    final income = switch (period) {
      HeroPeriod.day => data.todayIncome,
      HeroPeriod.week => data.weekIncome,
      HeroPeriod.month => data.incomeThisMonth,
    };
    final spent = switch (period) {
      HeroPeriod.day => data.todaySpend,
      HeroPeriod.week => data.weekSpend,
      HeroPeriod.month => data.spentThisMonth,
    };
    final net = income - spent;
    String netText() {
      final abs = formatMoney(net.isNegative ? -net : net);
      return net.isNegative ? '−$abs' : abs;
    }

    final rule = Colors.white.withValues(alpha: 0.12);
    final items = [
      (context.l10n.homeHeroIncome, formatMoney(income), AppColors.dark.income),
      (context.l10n.homeHeroSpent, formatMoney(spent), const Color(0xFFFF8A78)),
      (context.l10n.homeHeroNet, netText(), AppBrandBlue.pale),
    ];
    return Container(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      decoration:
          BoxDecoration(border: Border(top: BorderSide(color: rule))),
      child: IntrinsicHeight(
        child: Row(children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0)
              Container(
                  width: 1,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: rule),
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Row(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            color: items[i].$3, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(items[i].$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption(
                              Colors.white.withValues(alpha: .72))),
                    ),
                  ]),
                  const SizedBox(height: 2),
                  FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(privacyMode ? '••••' : items[i].$2,
                          textDirection: TextDirection.ltr,
                          style: AppTypography.amountSmall(Colors.white))),
                ])),
          ],
        ]),
      ),
    );
  }

  /// Row E — the pace bar: spent in white, the span past the expected-to-date
  /// mark tinted amber, a 2×16pt tick at the expected mark. Fills over 600ms.
  Widget _budgetPace(BuildContext context, HeroPeriod period) {
    final isDark = HomeV2.isDark(context);
    final amount =
        period == HeroPeriod.day ? data.todaySpend : data.spentThisMonth;
    final limit = period == HeroPeriod.day
        ? data.dailyBudgetLimit
        : data.monthlyBudgetLimit;
    if (limit.isZero || limit.isNegative) return const SizedBox.shrink();
    final used = (amount.toDouble() / limit.toDouble()).clamp(0.0, 1.0);
    final expected = (period == HeroPeriod.day
            ? (DateTime.now().hour * 60 + DateTime.now().minute) / 1440
            : data.monthElapsedRatio)
        .clamp(0.0, 1.0);
    final reduce = shouldReduceMotion(context);
    final labelStyle =
        AppTypography.caption(Colors.white.withValues(alpha: .72));
    return Column(children: [
      TweenAnimationBuilder<double>(
        tween: Tween(begin: reduce ? used : 0, end: used),
        duration:
            reduce ? Duration.zero : const Duration(milliseconds: 600),
        curve: AppMotion.easeOut,
        builder: (context, v, _) => LayoutBuilder(builder: (context, box) {
          final w = box.maxWidth;
          final fill = privacyMode ? 0.0 : v;
          final overFrom = fill > expected ? expected : fill;
          return SizedBox(
            height: 16,
            child: Stack(clipBehavior: Clip.none, children: [
              PositionedDirectional(
                start: 0,
                end: 0,
                top: 3,
                height: 10,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  child: ColoredBox(
                    color: HomeV2.heroTrack(isDark),
                    child: Stack(children: [
                      PositionedDirectional(
                        start: 0,
                        top: 0,
                        bottom: 0,
                        width: w * fill,
                        child: const ColoredBox(color: Colors.white),
                      ),
                      if (fill > expected)
                        PositionedDirectional(
                          start: w * overFrom,
                          top: 0,
                          bottom: 0,
                          width: w * (fill - overFrom),
                          child: ColoredBox(
                              color: HomeV2.heroOverPace(isDark)),
                        ),
                    ]),
                  ),
                ),
              ),
              PositionedDirectional(
                // A background launch lays this out at zero width; an
                // upper bound below 0 makes clamp throw.
                start: w <= 2 ? 0.0 : ((w - 2) * expected).clamp(0.0, w - 2),
                top: 0,
                child: Opacity(
                  opacity: used == 0 ? 1 : (v / used).clamp(0.0, 1.0),
                  child: Container(
                    width: 2,
                    height: 16,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(1),
                      boxShadow: [
                        BoxShadow(
                            color: AppBrandBlue.brand.withValues(alpha: .5),
                            spreadRadius: 2),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
          );
        }),
      ),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Flexible(
          child: Text(context.l10n.homePaceUsed((used * 100).round()),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(context.l10n.homePaceExpected((expected * 100).round()),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: labelStyle),
        ),
      ]),
    ]);
  }

  /// Privacy toggle beside the figure's label — the small inline eye Home
  /// has always had, with a padded touch target.
  Widget _eye(BuildContext context, WidgetRef ref) => Semantics(
        button: true,
        label: context.l10n.homePrivacyToggle,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: () async {
            HapticFeedback.selectionClick();
            final settings = ref.read(userSettingsProvider).valueOrNull;
            if (settings == null) return;
            await ref.read(userSettingsRepositoryProvider).saveSettings(
                settings.copyWith(privacyModeEnabled: !privacyMode));
          },
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(
              privacyMode ? AppLucideIcons.eyeOff : AppLucideIcons.eye,
              size: 16,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ),
      );
}

/// The headline figure for a period (shared by the hero and the collapsed
/// bar).
Money _heroValue(DashboardData data, HeroPeriod period) => switch (period) {
      HeroPeriod.day => data.todaySpend,
      HeroPeriod.week => data.weekSpend,
      HeroPeriod.month => data.spentThisMonth,
    };

String _heroLabel(BuildContext context, HeroPeriod period) => switch (period) {
      HeroPeriod.day => context.l10n.homeTodaySpend,
      HeroPeriod.week => context.l10n.homeWeekSpend,
      HeroPeriod.month => context.l10n.homeMonthSpend,
    };

/// v2 Hero role (spec §2.2): radius 28, per-theme gradient top-leading →
/// bottom-trailing, a 1px inner top sheen, a static aurora and the per-theme
/// lift. A self-contained card with a hard edge.
class _HeroCard extends StatelessWidget {
  const _HeroCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final isDark = HomeV2.isDark(context);
    final t = MaliTokens.of(context);
    const radius = BorderRadius.all(Radius.circular(28));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          stops: const [0.0, 0.52, 1.0],
          colors: HomeV2.heroStops(isDark),
        ),
        boxShadow: HomeV2.heroShadow(isDark),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const AlignmentDirectional(-0.6, -0.9)
                          .resolve(Directionality.of(context)),
                      radius: 0.9,
                      colors: [
                        Colors.white.withValues(alpha: isDark ? 0.08 : 0.12),
                        t.auroraTop.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: 1,
              child: ColoredBox(color: HomeV2.heroSheen(isDark)),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.s5),
              child: child,
            ),
          ],
        ),
      ),
    );
  }
}

/// The hero amount: `amount.hero` in white, decimals at 62%. The first paint
/// shows the final value (Home appears complete, no count-up); `m.count`
/// tweens from the previously shown value when the period or account changes;
/// tabular figures so the width does not jitter. Reduce Motion renders the
/// final value.
class _HeroAmount extends ConsumerWidget {
  const _HeroAmount({super.key, required this.value});

  final Money value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = ref.read(_heroShownProvider);
    final target = value.minorUnits.toDouble();
    final reduce = shouldReduceMotion(context);
    return Semantics(
      label: formatMoney(value),
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: reduce ? target : (shown ?? target), end: target),
        duration: reduce
            ? Duration.zero
            : AppMotion.countFor(value.toDouble().abs()),
        curve: AppMotion.easeOut,
        onEnd: () => ref.read(_heroShownProvider.notifier).state = target,
        builder: (context, v, _) {
          final done = (v - target).abs() < 0.5;
          final m = done ? value : Money(v.round(), value.currency);
          final parts = splitMoneyForDisplay(m);
          final full = formatMoney(value);
          final base = AppTypography.amountHero(Colors.white)
              .copyWith(fontSize: heroAmountFontSize(full.length, base: 48));
          return Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: '${parts.negative ? '−' : ''}${parts.integerPart}',
                  style: base),
              if (parts.fraction.isNotEmpty)
                TextSpan(
                    text: '.${parts.fraction}',
                    style: base.copyWith(
                        fontSize: base.fontSize! * 0.62,
                        color: Colors.white.withValues(alpha: 0.72))),
            ]),
            maxLines: 1,
            textDirection: TextDirection.ltr,
          );
        },
      ),
    );
  }
}

/// Home's loading state. The first load after launch runs under the boot
/// loader's exit, so a grey skeleton there is a one-frame flash: this paints
/// only the canvas, and reveals the skeleton if a load takes over ~600ms.
class _HomeLoading extends StatefulWidget {
  const _HomeLoading();

  @override
  State<_HomeLoading> createState() => _HomeLoadingState();
}

class _HomeLoadingState extends State<_HomeLoading> {
  late final Timer _reveal;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _reveal = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _slow = true);
    });
  }

  @override
  void dispose() {
    _reveal.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _slow
      ? const SkeletonList(rows: 5, withHero: true)
      : const SizedBox.expand();
}

/// The last hero figure painted, so a remount (scroll-back, tab return)
/// does not count up from zero again.
final _heroShownProvider = StateProvider<double?>((_) => null);

/// Whether Home's entrance choreography already ran this session.
final _homeEnteredProvider = StateProvider<bool>((_) => false);

/// v2 `m.enter` with `m.stagger`: opacity over `dur.base` + a 12pt rise over
/// `dur.moderate` (expo-out), 40ms between siblings. Runs once — a remount
/// after scrolling back renders in place. The widget tree is the same before,
/// during and after, so children keep their state.
class _HomeEnter extends ConsumerStatefulWidget {
  const _HomeEnter({required this.index, required this.child});

  final int index;
  final Widget child;

  @override
  ConsumerState<_HomeEnter> createState() => _HomeEnterState();
}

class _HomeEnterState extends ConsumerState<_HomeEnter>
    with SingleTickerProviderStateMixin {
  // The stagger delay is part of the controller's timeline (no timers).
  late final Duration _delay = AppMotion.stagger * widget.index;
  late final AnimationController _c = AnimationController(
      vsync: this, duration: _delay + AppMotion.moderate);
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (ref.read(_homeEnteredProvider)) _c.value = 1;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (shouldReduceMotion(context)) {
      _c.value = 1;
    } else if (_c.value < 1) {
      _c.forward().whenComplete(() {
        if (mounted) ref.read(_homeEnteredProvider.notifier).state = true;
      });
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _c.duration!.inMicroseconds;
    final delay = _delay.inMicroseconds;
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (context, child) {
        // Same widgets before, during and after: children keep their state.
        final elapsed = _c.value * total - delay;
        final fade = AppMotion.easeOut.transform(
            (elapsed / AppMotion.base.inMicroseconds).clamp(0.0, 1.0));
        final rise = AppMotion.enterRise *
            (1 -
                AppMotion.easeOut.transform(
                    (elapsed / AppMotion.moderate.inMicroseconds)
                        .clamp(0.0, 1.0)));
        return Opacity(
          opacity: fade,
          child: Transform.translate(offset: Offset(0, rise), child: child),
        );
      },
    );
  }
}

/// Three wide tinted shortcuts under the hero — paste a bank SMS, budgets,
/// goals. Adding a transaction is the header's «+» only (no duplicate).
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget action(IconData icon, String label, VoidCallback onTap) {
      final button = Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: HomePressScale(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: HomeV2.group(context, radius: 14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: c.actionText, size: 20),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTypography.subhead(c.textPrimary)
                          .copyWith(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
          ),
        ),
      );
      // The three shortcuts enter together (one index), not one by one.
      return Expanded(
          child: _HomeEnter(
              index: 2,
              child: icon == AppLucideIcons.clipboardPaste
                  ? CoachAnchor(target: 'paste', child: button)
                  : button));
    }

    return Row(
      children: [
        action(AppLucideIcons.clipboardPaste, context.l10n.homeQuickPaste,
            () => ManualPasteScreen.showSheet(context)),
        const SizedBox(width: AppSpacing.s2),
        action(AppLucideIcons.pieChart, context.l10n.homeQuickBudget,
            () => context.push('/budgets')),
        const SizedBox(width: AppSpacing.s2),
        action(AppLucideIcons.target, context.l10n.homeQuickGoals,
            () => context.push('/goals')),
      ],
    );
  }
}

/// The header's «+» — a 44pt action-filled circle that opens the
/// add-transaction flow.
class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      label: context.l10n.homeQuickAdd,
      excludeSemantics: true,
      child: HomePressScale(
        scale: AppMotion.pressScaleIcon,
        onTap: () {
          HapticFeedback.lightImpact();
          showCaptureEntrySheet(context);
        },
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: c.cta,
            shape: BoxShape.circle,
            boxShadow: HomeV2.isDark(context) ? null : AppShadows.actionLift,
          ),
          child: const Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// The hero's اليوم / الأسبوع / الشهر switch — v2 `QSegmented` in its
/// on-hero style: track white@12%, a white thumb that slides between the
/// options on `spring.smooth` (`m.select`), selected label brand blue.
///
/// Its own widget rather than the shared `SegmentedControl`: it lives on the
/// hero, and each option here is a real [Semantics] button announcing its
/// selected state.
class _PeriodSegments extends StatelessWidget {
  const _PeriodSegments({required this.selected, required this.onSelect});

  final HeroPeriod selected;
  final ValueChanged<HeroPeriod> onSelect;

  // Was a `static const` map. Localized copy cannot be const, and a table
  // built once at class-load would freeze whichever language was active then.
  static String _label(BuildContext context, HeroPeriod p) => switch (p) {
        HeroPeriod.day => context.l10n.txnRangeToday,
        HeroPeriod.week => context.l10n.homeWeek,
        HeroPeriod.month => context.l10n.homeMonth,
      };

  static TextStyle _style(Color c) =>
      AppTypography.caption(c).copyWith(fontWeight: FontWeight.w700);

  @override
  Widget build(BuildContext context) {
    // Equal segments sized to the widest label, so one thumb can slide.
    var segment = 58.0;
    for (final p in HeroPeriod.values) {
      final painter = TextPainter(
        text: TextSpan(text: _label(context, p), style: _style(Colors.white)),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      if (painter.width + 24 > segment) segment = painter.width + 24;
      painter.dispose();
    }
    final reduce = shouldReduceMotion(context);
    final index = HeroPeriod.values.indexOf(selected);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: SizedBox(
        width: segment * HeroPeriod.values.length,
        child: Stack(
          children: [
            AnimatedPositionedDirectional(
              duration: reduce ? AppMotion.micro : AppMotion.moderate,
              curve: reduce ? Curves.linear : AppMotion.springSmoothCurve,
              start: segment * index,
              top: 0,
              bottom: 0,
              width: segment,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                ),
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final period in HeroPeriod.values)
                  _segment(period, _label(context, period),
                      period == selected, segment),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _segment(
      HeroPeriod period, String label, bool isSelected, double width) {
    return Semantics(
      button: true,
      selected: isSelected,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          onSelect(period);
        },
        child: Container(
          width: width,
          constraints: const BoxConstraints(minHeight: 34),
          alignment: Alignment.center,
          child: AnimatedDefaultTextStyle(
            duration: AppMotion.micro,
            style: _style(isSelected
                ? AppBrandBlue.brand
                : Colors.white.withValues(alpha: 0.8)),
            child: Text(label, maxLines: 1),
          ),
        ),
      ),
    );
  }
}

/// How far the dark aurora runs past the header zone before it has fully
/// faded — the colour reaches under the first cards and dissolves behind
/// them, not in empty space.
const double _heroMeltOverflow = 220;

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.sectionGap, AppSpacing.gutter, 0),
      child: child,
    );
  }
}

/// Status-bar protection and the collapsed bar (spec §2.2 Status bar, §2.6
/// QNavBar, «05» Motion). The status-bar region always belongs to this layer:
/// transparent at rest, glass once content scrolls beneath the clock
/// (8→40pt), and after 120pt a glass bar fades in naming the hero figure.
/// Status icons follow the canvas (dark icons in light, light in dark).
class _HomeChrome extends ConsumerStatefulWidget {
  const _HomeChrome(
      {required this.data, required this.privacyMode, required this.child});

  final DashboardData? data;
  final bool privacyMode;
  final Widget child;

  @override
  ConsumerState<_HomeChrome> createState() => _HomeChromeState();
}

class _HomeChromeState extends ConsumerState<_HomeChrome> {
  final ValueNotifier<double> _offset = ValueNotifier<double>(0);

  @override
  void dispose() {
    _offset.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    // The page scrollable only; the horizontal rails and pagers are deeper.
    if (n.depth == 0 && n.metrics.axis == Axis.vertical) {
      _offset.value = n.metrics.pixels;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.paddingOf(context).top;
    final isDark = HomeV2.isDark(context);
    final c = context.colors;
    final data = widget.data;
    final period = ref.watch(heroPeriodProvider);
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: ValueListenableBuilder<double>(
              valueListenable: _offset,
              builder: (context, px, _) {
                final band = ((px - 8) / 32).clamp(0.0, 1.0);
                final bar = data == null || !data.hasAnyTransactions
                    ? 0.0
                    : ((px - 120) / 40).clamp(0.0, 1.0);
                final fill = band > bar ? band : bar;
                final hair = HomeV2.hairline(context);
                return AnnotatedRegion<SystemUiOverlayStyle>(
                  value: isDark
                      ? SystemUiOverlayStyle.light
                      : SystemUiOverlayStyle.dark,
                  child: SizedBox(
                    height: top + (bar > 0 ? 44 : 0),
                    child: ClipRect(
                      child: BackdropFilter(
                        enabled: fill > 0,
                        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: c.bg.withValues(alpha: 0.62 * fill),
                            border: Border(
                              bottom: BorderSide(
                                  color: hair.withValues(alpha: hair.a * bar),
                                  width: 0.5),
                            ),
                          ),
                          child: bar > 0
                              ? Padding(
                                  padding: EdgeInsets.only(top: top),
                                  child: Opacity(
                                    opacity: bar,
                                    child: Center(
                                      child: Text(
                                        '${_heroLabel(context, period)}  ${widget.privacyMode ? '••••' : formatMoney(_heroValue(data!, period))}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: AppTypography.titleNav(
                                                c.textPrimary)
                                            .copyWith(fontFeatures: const [
                                          FontFeature.tabularFigures()
                                        ]),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// A Home section title — the shared [SectionHeader], inset 4 like every
/// other Home section. [onBlue] is for a section that sits on the hero, where
/// the canvas ink would not read; [badge] is folded into the title as a
/// count.
class _HomeSectionTitle extends StatelessWidget {
  const _HomeSectionTitle({
    required this.title,
    this.trailing,
    this.onTrailingTap,
    this.onBlue = false,
    this.badge,
  });

  final String title;
  final String? trailing;
  final VoidCallback? onTrailingTap;
  final bool onBlue;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.textScalerOf(context).scale(16) > 24) {
      final t = MaliTokens.of(context);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
                child: Text(badge == null ? title : '$title ($badge)',
                    style: AppTypography.sectionTitle(
                        onBlue ? Colors.white : t.textOnCanvasPrimary))),
            if (trailing != null)
              GestureDetector(
                onTap: onTrailingTap,
                child: Text(trailing!,
                    style: AppTypography.subhead(onBlue
                        ? Colors.white.withValues(alpha: 0.8)
                        : context.colors.actionText)),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: SectionHeader(
        title: badge == null ? title : '$title ($badge)',
        trailing: trailing,
        onTrailingTap: onTrailingTap,
        titleColor: onBlue ? Colors.white : null,
        // v2: section links are `action.text` (never `cta` for text).
        trailingColor: onBlue
            ? Colors.white.withValues(alpha: 0.8)
            : context.colors.actionText,
      ),
    );
  }
}

// ─── «للمراجعة» ───────────────────────────────────────────────────────────────

/// Transactions waiting for review — promoted above recent transactions
/// because it is the only block asking for action. One Group card with a 3pt
/// warning leading edge; a stacked edge (6pt offsets) hints at the next ones.
/// Reviewing happens in the transaction sheet, where the category can be
/// confirmed or changed.
class _ReviewSection extends ConsumerWidget {
  const _ReviewSection({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final isDark = HomeV2.isDark(context);
    final tx = data.pendingReview.first;
    final category = data.catalog.byId(tx.categoryId);
    final title =
        tx.rawMerchant ?? category?.name ?? context.l10n.txnTransactionWord;
    final logo = BrandMark.logoFor(
        title,
        ref.watch(merchantLogosProvider).valueOrNull ??
            const <String, String>{});
    final debit = transactionIsDebit(tx);
    final count = data.pendingReviewCount;
    final categoryTile = AppAvatar.category(
        iconName: category?.iconName, color: category?.color, size: 40);
    void openAll() {
      HapticFeedback.selectionClick();
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
    }

    final top = DecoratedBox(
      decoration: HomeV2.group(context),
      child: Stack(
        children: [
          // The 3pt warning edge on the leading side, inside the radius.
          PositionedDirectional(
            start: 0,
            top: 14,
            bottom: 14,
            width: 3,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: c.warning,
                borderRadius: const BorderRadiusDirectional.horizontal(
                        end: Radius.circular(3))
                    .resolve(Directionality.of(context)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    // Same tile rule as the transaction rows: the merchant's
                    // logo when it is a known brand, otherwise its category.
                    (logo != null || BrandMark.hasBrand(title))
                        ? AppAvatar.brand(
                            name: title,
                            logoUrl: logo,
                            size: 40,
                            fallback: categoryTile)
                        : categoryTile,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTypography.bodyStrong(
                                  t.textOnCanvasPrimary)),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                  '${Formatters.dateGroupLabel(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt, context)}',
                                  style: AppTypography.caption(
                                      t.textOnCanvasMuted)),
                              if (category != null)
                                IntrinsicWidth(
                                  child: AppStatusPill(
                                      label: category.name, compact: true),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      privacyMode
                          ? '••••'
                          : '${tx.amountMoney.isZero ? '' : debit ? '−' : '+'}${formatMoney(tx.amountMoney.isNegative ? -tx.amountMoney : tx.amountMoney)}',
                      // Keeps the sign before the number under RTL («−64.00»).
                      textDirection: TextDirection.ltr,
                      style: AppTypography.amountSmall(
                          debit ? t.textOnCanvasPrimary : c.income),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(context.l10n.homeReviewToStayAccurate,
                    style: AppTypography.caption(t.textOnCanvasMuted)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () {
                        HapticFeedback.mediumImpact();
                        TransactionDetailsScreen.showSheet(context, tx.id);
                      },
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 40),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      icon: const Icon(AppLucideIcons.check, size: 16),
                      label: Text(context.l10n.homeReviewNow),
                    ),
                    TextButton(
                      onPressed: openAll,
                      style: TextButton.styleFrom(
                        foregroundColor: c.actionText,
                        minimumSize: const Size(0, 40),
                      ),
                      child: Text(context.l10n.homeSeeAll),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );

    // The stacked edge only peeks out under the card's bottom edge, 6pt per
    // layer. Opaque in both themes, so nothing shows through the card.
    Widget layer(double inset, double alpha) => Positioned(
          left: inset,
          right: inset,
          bottom: -(inset / 11) * 6,
          height: 24,
          child: Container(
            key: ValueKey('home-review-layer-$inset'),
            decoration: BoxDecoration(
              color: Color.alphaBlend(
                  c.surface.withValues(alpha: alpha), c.bg),
              borderRadius: BorderRadius.circular(18),
              border: isDark ? Border.all(color: t.cardBorder) : null,
              boxShadow: isDark ? null : AppShadows.e1,
            ),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HomeSectionTitle(
          title: context.l10n.homeToReview,
          badge: count,
          trailing: context.l10n.bdgFilterAll,
          onTrailingTap: openAll,
          onBlue: false,
        ),
        const SizedBox(height: AppSpacing.s3),
        Padding(
          padding: EdgeInsets.only(bottom: count > 2 ? 12 : count > 1 ? 6 : 0),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (count > 2) layer(22, 0.5),
              if (count > 1) layer(11, 0.8),
              top,
            ],
          ),
        ),
      ],
    );
  }
}

// ─── الميزانيات ───────────────────────────────────────────────────────────────

class _BudgetsSection extends StatelessWidget {
  const _BudgetsSection({
    required this.data,
    required this.privacyMode,
  });

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    if (data.budgetProgress.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sectionGap),
        _HomeSectionTitle(
          title: context.l10n.helpBudgetsTitle,
          trailing: context.l10n.homeManage,
          onTrailingTap: () => context.push('/budgets'),
        ),
        const SizedBox(height: AppSpacing.s3),
        BudgetsCard(
          entries: data.budgetProgress,
          privacyMode: privacyMode,
          onTap: () => context.push('/budgets'),
        ),
      ],
    );
  }
}

// ─── «مدفوعات قادمة» ──────────────────────────────────────────────────────────

class _UpcomingSection extends ConsumerWidget {
  const _UpcomingSection({required this.privacyMode});
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subs = ref.watch(homeSubscriptionsProvider).valueOrNull;
    final insts = ref.watch(homeInstallmentsProvider).valueOrNull;
    // valueOrNull, not `when`: a reload must not collapse the section to
    // nothing and back — the previous render holds while the next one loads.
    if (subs == null && insts == null) return const SizedBox.shrink();
    final bills = <BillEntity>[...?subs, ...?insts];
    if (bills.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sectionGap),
        _HomeSectionTitle(
          title: context.l10n.homeUpcoming,
          trailing: context.l10n.bdgFilterAll,
          onTrailingTap: () => context.push('/subscriptions'),
        ),
        const SizedBox(height: AppSpacing.s3),
        UpcomingPaymentsCard(
          bills: bills,
          privacyMode: privacyMode,
          now: DateTime.now(),
          onTap: () => context.push('/subscriptions'),
        ),
      ],
    );
  }
}

// ─── «أهدافي وخططي» ───────────────────────────────────────────────────────────

class _GoalsPlansSection extends ConsumerWidget {
  const _GoalsPlansSection({required this.privacyMode});
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final goals = ref.watch(goalsListProvider).valueOrNull ?? const [];
    final plans = ref.watch(homePlansProvider).valueOrNull ?? const [];
    if (goals.isEmpty && plans.isEmpty) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: AppSpacing.sectionGap),
        _HomeSectionTitle(
          title: context.l10n.homeGoalsAndPlans,
          trailing: context.l10n.bdgFilterAll,
          onTrailingTap: () => context.push('/goals'),
        ),
        const SizedBox(height: AppSpacing.s3),
        GoalsPlansRail(
          goals: goals,
          plans: plans.take(3).toList(growable: false),
          privacyMode: privacyMode,
          onGoalTap: () => context.push('/goals'),
          onPlanTap: () => PlansScreen.open(context),
          onNewGoal: () => context.push('/goals/new'),
        ),
      ],
    );
  }
}

class _WelcomeBody extends StatelessWidget {
  const _WelcomeBody({required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final t = MaliTokens.of(context);
    final hasBudget =
        !data.monthlyBudgetLimit.isZero && !data.monthlyBudgetLimit.isNegative;
    // Step 1 is what ends first-run, so on this screen it is never done.
    final done = <bool>[false, hasBudget, false];
    final doneCount = done.where((d) => d).length;
    final current = done.indexOf(false);

    Widget step(
        int i, String title, String body, String cta, VoidCallback onTap) {
      final isDone = done[i];
      final isCurrent = i == current;
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          border: i == 0 ? null : Border(top: BorderSide(color: t.cardBorder)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone ? c.income : Colors.transparent,
                border: Border.all(
                  width: 2,
                  color: isDone ? c.income : (isCurrent ? c.cta : t.cardBorder),
                ),
              ),
              child: isDone
                  ? const Icon(AppLucideIcons.check,
                      size: 16, color: Colors.white)
                  : Text('${i + 1}',
                      style: AppTypography.subhead(
                          isCurrent ? c.cta : t.textOnCanvasMuted)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: AppTypography.bodyStrong(isDone
                              ? t.textOnCanvasMuted
                              : t.textOnCanvasPrimary)
                          .copyWith(
                              decoration:
                                  isDone ? TextDecoration.lineThrough : null)),
                  const SizedBox(height: 2),
                  Text(body, style: AppTypography.caption(t.textOnCanvasMuted)),
                  if (!isDone) ...[
                    const SizedBox(height: 10),
                    isCurrent
                        ? FilledButton(onPressed: onTap, child: Text(cta))
                        : OutlinedButton(onPressed: onTap, child: Text(cta)),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    Widget tile(IconData icon, Color tone, String title, String sub,
        VoidCallback onTap) {
      return MaliCard(
        onTap: onTap,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(icon, size: 18, color: tone),
            ),
            const SizedBox(height: 8),
            Text(title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
            Text(sub,
                maxLines: 2, style: AppTypography.micro(t.textOnCanvasMuted)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
            child:
                QirshIllustration(name: 'welcome', width: 230, height: 172.5)),
        MaliCard(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  RingProgress(
                    value: doneCount / 3,
                    size: 52,
                    strokeWidth: 6,
                    color: c.income,
                    child: Text('$doneCount/3',
                        style: AppTypography.label(t.textOnCanvasPrimary)),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(context.l10n.homeStartSteps,
                            style:
                                AppTypography.cardTitle(t.textOnCanvasPrimary)),
                        Text(context.l10n.homeStartStepsHint,
                            style: AppTypography.caption(t.textOnCanvasMuted)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              step(
                0,
                context.l10n.homeStepAddTitle,
                context.l10n.homeStepAddBody,
                context.l10n.homeStepAddCta,
                () => showCaptureEntrySheet(context),
              ),
              step(
                1,
                context.l10n.homeStepBudgetTitle,
                context.l10n.homeStepBudgetBody,
                context.l10n.homeStepBudgetCta,
                () => context.push('/budgets/new'),
              ),
              step(
                2,
                context.l10n.homeStepCaptureTitle,
                context.l10n.homeStepCaptureBody,
                context.l10n.homeStepCaptureCta,
                () => Platform.isIOS
                    ? showIosShortcutSheet(context)
                    : SmsPermissionScreen.showSheet(context),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.income.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadius.xl),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: c.income,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Icon(AppLucideIcons.shieldCheck,
                    size: 18, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.homeOnDeviceTitle,
                        style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    Text(context.l10n.homeOnDeviceBody,
                        style: AppTypography.caption(t.textOnCanvasSecondary)),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.s6),
        _HomeSectionTitle(title: context.l10n.homeCreateYourself),
        const SizedBox(height: AppSpacing.s3),
        GridView(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            // Fixed height, not an aspect ratio: Arabic copy at large text
            // sizes must not overflow a tile that shrinks with the width.
            mainAxisExtent: 138,
          ),
          children: [
            tile(
                AppLucideIcons.pieChart,
                c.cta,
                context.l10n.homeQuickBudget,
                context.l10n.homeTileBudgetSub,
                () => context.push('/budgets/new')),
            tile(AppLucideIcons.target, c.income, context.l10n.homeTileGoal,
                context.l10n.homeTileGoalSub, () => context.push('/goals/new')),
            tile(
                AppLucideIcons.repeat,
                c.warning,
                context.l10n.homeTileBill,
                context.l10n.homeTileBillSub,
                () => context.push('/subscriptions')),
            tile(
                AppLucideIcons.plane,
                c.danger,
                context.l10n.homeTilePlan,
                context.l10n.homeTilePlanSub,
                () => PlanFormSheet.show(context)),
          ],
        ),
      ],
    );
  }
}

// ─── Setup nudge ──────────────────────────────────────────────────────────────

const Duration _setupNudgeSnooze = Duration(days: 30);
const String _setupNudgeSnoozedUntilKey = 'setup_nudge_snoozed_until';
final _setupNudgeDismissedProvider = StateProvider<bool>((_) => false);
final _setupNudgeSnoozedProvider = FutureProvider<bool>((_) async {
  const storage = FlutterSecureStorage();
  final raw = await storage.read(key: _setupNudgeSnoozedUntilKey);
  final until = raw == null ? null : DateTime.tryParse(raw);
  return until != null && DateTime.now().toUtc().isBefore(until);
});
Future<void> _snoozeSetupNudge(WidgetRef ref) async {
  const storage = FlutterSecureStorage();
  final until = DateTime.now().toUtc().add(_setupNudgeSnooze);
  await storage.write(
      key: _setupNudgeSnoozedUntilKey, value: until.toIso8601String());
  ref.read(_setupNudgeDismissedProvider.notifier).state = true;
  ref.invalidate(_setupNudgeSnoozedProvider);
}

final _appLockEnabledProvider =
    FutureProvider<bool>((_) => AppLockService.instance.isEnabled());

/// Whether the setup nudge shows, and what it still offers. Null when it is
/// dismissed, snoozed (or the snooze is still loading), or nothing is left.
({bool lockEnabled, bool hasGoals})? _setupNudgeState(WidgetRef ref) {
  if (ref.watch(_setupNudgeDismissedProvider)) return null;
  if (ref.watch(_setupNudgeSnoozedProvider).valueOrNull ?? true) return null;
  final hasGoals = ref.watch(goalsListProvider).valueOrNull?.isNotEmpty ?? true;
  final lockEnabled = ref.watch(_appLockEnabledProvider).valueOrNull ?? true;
  if (hasGoals && lockEnabled) return null;
  return (lockEnabled: lockEnabled, hasGoals: hasGoals);
}

class _SetupNudgeCard extends ConsumerWidget {
  const _SetupNudgeCard({required this.lockEnabled, required this.hasGoals});

  final bool lockEnabled;
  final bool hasGoals;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return _InsightCard(
      leading: Container(
        width: 48,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.cta,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Icon(
            lockEnabled ? AppLucideIcons.piggyBank : AppLucideIcons.fingerprint,
            size: 22,
            color: Colors.white),
      ),
      title: context.l10n.homeFinishSetup,
      onDismiss: () => _snoozeSetupNudge(ref),
      body: [
        const SizedBox(height: AppSpacing.s1),
        Wrap(
          spacing: AppSpacing.s2,
          runSpacing: AppSpacing.s2,
          children: [
            if (!lockEnabled)
              _SetupNudgeChip(
                icon: AppLucideIcons.fingerprint,
                label: context.l10n.homeEnableBiometrics,
                onTap: () => ref.read(shellIndexProvider.notifier).state = 3,
              ),
            if (!hasGoals)
              _SetupNudgeChip(
                icon: AppLucideIcons.piggyBank,
                label: context.l10n.homeAddSavingsGoal,
                onTap: () => ref.read(shellIndexProvider.notifier).state = 2,
              ),
          ],
        ),
      ],
    );
  }
}

/// v2 tinted button, compact: `action.soft` fill + `action.text` label.
class _SetupNudgeChip extends StatelessWidget {
  const _SetupNudgeChip(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      button: true,
      child: HomePressScale(
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.ctaSoft,
          borderRadius: BorderRadius.circular(AppRadius.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.actionText),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  style: AppTypography.subhead(c.actionText)
                      .copyWith(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      ),
    ));
  }
}

// ─── Coupons ──────────────────────────────────────────────────────────────────

class _DashboardCouponsRail extends ConsumerWidget {
  const _DashboardCouponsRail();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offers = ref.watch(dashboardCouponsProvider).valueOrNull;
    // valueOrNull, not `when`: a reload must not blink the section away.
    // Empty (or the feature flag off) renders nothing at all — an empty
    // «ركن التوفير» header would advertise a section that has no content.
    if (offers == null || offers.isEmpty) return const SizedBox.shrink();
    final english = Localizations.localeOf(context).languageCode == 'en';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: SectionHeader(
            title: context.l10n.homeSavingsCorner,
            trailing: context.l10n.bdgFilterAll,
            onTrailingTap: () => context.push('/coupons'),
          ),
        ),
        const SizedBox(height: AppSpacing.s3),
        CouponsCorner(
          offers: offers,
          preferEnglish: english,
          onOpen: (offer) => showCouponDetailsSheet(context, ref, offer),
          onSeeAll: () => context.push('/coupons'),
        ),
      ],
    );
  }
}
