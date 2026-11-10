import '../help/coach_marks.dart';
import 'dart:io';

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
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/mali_tokens.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/theme/widgets/glass_selector.dart';
import '../../core/theme/widgets/mali_glass.dart';
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
import '../onboarding/ios_shortcut_guide.dart';
import '../transactions/transaction_details_screen.dart';
import '../transactions/manual_transaction_sheet.dart';
import '../transactions/transactions_providers.dart';
import 'dashboard_providers.dart';
import 'home_sections_providers.dart';
import 'widgets/budgets_card.dart';
import 'widgets/coupons_corner.dart';
import 'widgets/daily_spend_card.dart';
import 'widgets/home_overview_cards.dart';
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
      // الهيرو الأزرق هو مصدر اللون في الصفحة دي — من غير هالة زرقا كمان
      // في الخلفية ورا المحتوى.
      ambient: false,
      child: FirstUseGuide(
          id: CoachMarkIds.dashboard,
          marks: dashboardCoachMarks,
          child: RefreshIndicator(
            onRefresh: () async => ref.invalidate(dashboardDataProvider),
            child: async.when(
              skipLoadingOnReload: true,
              loading: () => const SkeletonList(rows: 5, withHero: true),
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
          )),
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

class _SavingsPhoto extends StatelessWidget {
  const _SavingsPhoto({required this.data, required this.privacyMode});
  final DashboardData data;
  final bool privacyMode;
  @override
  Widget build(BuildContext context) {
    final surplus = data.incomeThisMonth - data.spentThisMonth;
    final amount = privacyMode
        ? '••••'
        : '${Formatters.amount(surplus.toDouble().abs())} ${Currency.label(context, data.currency)}';
    return QirshPhotoCard(
      photo: QirshPhoto.growth,
      margin: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(context.l10n.homeSavingsGrowing,
              textAlign: TextAlign.right,
              style: AppTypography.custom(
                  size: 11,
                  weight: FontWeight.w500,
                  height: 1.4,
                  color: Colors.white.withValues(alpha: .72))),
          const SizedBox(height: 6),
          Text(
              surplus.isNegative
                  ? context.l10n.homeSpendingAhead(amount)
                  : context.l10n.homeSavingsSurplus(amount),
              textAlign: TextAlign.right,
              style: AppTypography.custom(
                  size: 17,
                  weight: FontWeight.w700,
                  height: 1.4,
                  color: Colors.white)),
          const SizedBox(height: 6),
          Text(context.l10n.homeSavingsMotivation,
              textAlign: TextAlign.right,
              style: AppTypography.custom(
                  size: 12,
                  weight: FontWeight.w400,
                  height: 1.5,
                  color: Colors.white.withValues(alpha: .78))),
          const SizedBox(height: 12),
          FilledButton(
              onPressed: () => context.push('/goals'),
              style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF0C1330),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  minimumSize: const Size(44, 36)),
              child: Text(context.l10n.homeAddToGoal)),
        ],
      ),
    );
  }
}

/// The reference's illustrated note uses the already measured category change,
/// with the same matched-period comparison as the category card below it.
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
    return MaliCard(
      padding: const EdgeInsets.all(16),
      child: Row(children: [
        Expanded(
            child:
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(context.l10n.rptVsPrevPeriod,
              style: AppTypography.caption(c.textMuted)),
          const SizedBox(height: 6),
          if (slice != null)
            Text(slice.category.name,
                style: AppTypography.bodyStrong(c.textPrimary)),
          const SizedBox(height: 4),
          Text(
              percent == null
                  ? context.l10n.rptNeedPrevPeriod
                  : change! < 0
                      ? context.l10n.rptSpendLower(percent)
                      : context.l10n.rptSpendHigher(percent),
              style: AppTypography.callout(c.textPrimary)),
          TextButton(
              onPressed: () => ref.read(shellIndexProvider.notifier).state = 4,
              child: Text(context.l10n.rptTabDetails)),
        ])),
        const SizedBox(width: 8),
        const QirshIllustration(name: 'insight', width: 100, height: 90),
      ]),
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
                if (!data.isEmpty) ...[
                  _recentSection(context, ref),
                  const SizedBox(height: AppSpacing.s4),
                ],
                const AnnouncementBanner(),
                if (reviewFirst) ...[
                  _ReviewSection(data: data, privacyMode: privacyMode),
                  const SizedBox(height: AppSpacing.s6),
                ],
                _SavingsPhoto(data: data, privacyMode: privacyMode),
                const SizedBox(height: AppSpacing.s4),
                if (data.todayTransactions.isNotEmpty ||
                    data.lastSevenDays.any((day) => !day.total.isZero)) ...[
                  _todaySection(context, ref, onBlue: false),
                  const SizedBox(height: AppSpacing.s4),
                ],
                if (data.topCategories.any((slice) =>
                    slice.changeRatio != null &&
                    (slice.changeRatio! * 100).round() != 0))
                  _CategoryInsight(data: data),
                const _SetupNudgeCard(),
                if (data.topCategories.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s6),
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

// ─── Blue summary zone ────────────────────────────────────────────────────────

/// The blue hero at the top of Home: greeting, the active account, the period
/// figure with its trend drawing, and the quick actions. White content on the
/// brand blue in both themes; the blue melts into the page below it.
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

  // The hero's semantic tints (white-on-blue legible), same as before.
  static const _income = Color(0xFF4ADE80);
  static const _expenseNet = Color(0xFFFCA5A5);

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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final topPad = MediaQuery.paddingOf(context).top;
    // Light status-bar icons only while the blue sits under the status bar;
    // once it scrolls away the region no longer covers it and the theme's
    // default comes back.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Pull-to-refresh overscroll reveals the space above the hero: keep it
          // blue instead of a canvas-coloured strip.
          Positioned(
            top: -600,
            left: 0,
            right: 0,
            height: 601,
            child: ColoredBox(color: AppBrandBlue.headerStops(isDark).first),
          ),
          // The blue runs [_heroMeltOverflow] past the hero's content and melts
          // into the page canvas behind the first cards — no sheet edge.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            bottom: -_heroMeltOverflow,
            child: LayoutBuilder(builder: (context, box) {
              // The fade starts where the hero's content ends, so every white
              // label in the hero sits on full blue.
              final heroShare = box.maxHeight <= _heroMeltOverflow
                  ? 0.6
                  : ((box.maxHeight - _heroMeltOverflow) / box.maxHeight)
                      .clamp(0.4, 0.9);
              // Fade the whole backdrop to transparency so the page's grain
              // shows through gradually. An opaque canvas-colour overlay hid
              // that texture until this box ended, leaving a horizontal seam.
              return ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.0, heroShare, 1.0],
                  colors: const [
                    Colors.white,
                    Colors.white,
                    Colors.transparent
                  ],
                ).createShader(bounds),
                child: Container(
                  key: const ValueKey('home-blue-backdrop'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topRight,
                      end: Alignment.bottomLeft,
                      stops: const [0.0, 0.55, 1.0],
                      colors: AppBrandBlue.headerStops(isDark),
                    ),
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.95, -1.1),
                        radius: 1.35,
                        colors: [
                          Colors.white.withValues(alpha: isDark ? 0.09 : 0.16),
                          Colors.white.withValues(alpha: 0),
                          const Color(0xFF06122E)
                              .withValues(alpha: isDark ? 0.30 : 0.12),
                        ],
                        stops: const [0.0, 0.55, 1.0],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(20, topPad + 12, 20, AppSpacing.s3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _topRow(context, ref),
                if (firstRun)
                  ..._welcome(context)
                else
                  ..._figures(context, ref),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _topRow(BuildContext context, WidgetRef ref) {
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
        Container(
          width: AppSpacing.avatar,
          height: AppSpacing.avatar,
          alignment: Alignment.center,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.16),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
          ),
          child: hasImage
              ? Image.file(file, fit: BoxFit.cover)
              : Text(_initials(name),
                  style: AppTypography.subhead(Colors.white)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(greeting,
                  style: AppTypography.footnote(
                      Colors.white.withValues(alpha: 0.75))),
              const SizedBox(height: 2),
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTypography.cardTitle(Colors.white)),
            ],
          ),
        ),
        // UX-008 — the product's mark on its first screen. Gold on the navy
        // hero in both themes; decorative, so excluded from semantics.
        Padding(
          padding: const EdgeInsetsDirectional.only(end: 10),
          child: Image.asset(
            AppAssets.qirshCoinGold,
            width: 26,
            height: 26,
            excludeFromSemantics: true,
          ),
        ),
        Semantics(
            button: true,
            label: context.l10n.annTitle,
            child: IconButton(
                onPressed: () => context.push('/announcements'),
                icon: const Icon(AppLucideIcons.bell,
                    color: Colors.white, size: 20))),
        const CoachAnchor(target: 'add', child: _AddButton()),
      ],
    );
  }

  List<Widget> _welcome(BuildContext context) => [
        const SizedBox(height: 22),
        Image.asset(
          AppAssets.qirshCoinGold,
          width: 72,
          height: 72,
          excludeFromSemantics: true,
        ),
        const SizedBox(height: 16),
        Text(context.l10n.homeWelcomeTitle,
            style: AppTypography.title1(Colors.white).copyWith(height: 1.3)),
        const SizedBox(height: 8),
        Text(context.l10n.homeWelcomeBody,
            style: AppTypography.footnote(Colors.white.withValues(alpha: 0.8))
                .copyWith(height: 1.55)),
        const SizedBox(height: AppSpacing.s4),
      ];

  List<Widget> _figures(BuildContext context, WidgetRef ref) {
    final period = ref.watch(heroPeriodProvider);
    final currencyLabel = Currency.label(context, data.currency.toUpperCase());
    String money(Money m) => privacyMode ? '••••' : formatMoney(m);

    final heroValue = switch (period) {
      HeroPeriod.day => data.todaySpend,
      HeroPeriod.week => data.weekSpend,
      HeroPeriod.month => data.spentThisMonth,
    };
    final heroLabel = switch (period) {
      HeroPeriod.day => context.l10n.homeTodaySpend,
      HeroPeriod.week => context.l10n.homeWeekSpend,
      HeroPeriod.month => context.l10n.homeMonthSpend,
    };

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

    // The pill under the drawing: how this period sits against its yardstick.
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
    return [
      const SizedBox(height: 12),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(AppSpacing.s3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0x709BBDFF)),
          gradient: const LinearGradient(
            begin: AlignmentDirectional.topStart,
            end: AlignmentDirectional.bottomEnd,
            colors: [Color(0xA82464F6), Color(0xE608267B)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                          await ref
                              .read(heroPeriodProvider.notifier)
                              .select(value);
                        } catch (_) {
                          if (context.mounted) {
                            AppToast.showError(
                                context, context.l10n.setupSaveFailed);
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
                    Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: periods)
                  ],
                );
              }
              return Row(children: [
                Expanded(child: account),
                const SizedBox(width: AppSpacing.s2),
                ConstrainedBox(
                  constraints:
                      BoxConstraints(maxWidth: constraints.maxWidth * .55),
                  child: periods,
                ),
              ]);
            }),
            const SizedBox(height: 14),
            Row(
              children: [
                Text(heroLabel,
                    style: AppTypography.caption(
                        Colors.white.withValues(alpha: 0.75))),
                const SizedBox(width: 2),
                _eye(context, ref),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  // A financial figure is never truncated: it scales down from a
                  // size already chosen for its length (UX-035).
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      heroText,
                      maxLines: 1,
                      style: AppTypography.amountHero(Colors.white).copyWith(
                        fontSize: heroAmountFontSize(heroText.length),
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(currencyLabel,
                      style: AppTypography.footnote(
                          Colors.white.withValues(alpha: 0.72))),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(sub,
                style: AppTypography.footnote(
                    Colors.white.withValues(alpha: 0.8))),
            if (pace != null) ...[
              const SizedBox(height: 8),
              _pacePill(pace, good, paceTap),
            ],
            if (hasBudget && period != HeroPeriod.week) ...[
              const SizedBox(height: 12),
              _budgetPace(context, period),
            ],
            const SizedBox(height: 12),
            _heroTotals(context, period),
          ],
        ),
      ),
      const SizedBox(height: 16),
      const _QuickActions(),
    ];
  }

  /// The hero's trend chip: translucent white pill, the meaning carried by
  /// the icon's income / expense tint.
  Widget _pacePill(String text, bool good, VoidCallback? onTap) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(good ? AppLucideIcons.arrowDown : AppLucideIcons.arrowUp,
              size: 12, color: good ? _income : _expenseNet),
          const SizedBox(width: 4),
          Flexible(
            child: Text(text,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    AppTypography.micro(Colors.white.withValues(alpha: 0.85))),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }

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
    // The shared selector chip every other screen uses for the account.
    return CoachAnchor(
        target: 'account',
        child: GlassSelector(
          onBlue: true,
          icon: AppLucideIcons.wallet,
          label: accountLabel,
          onTap: () {
            HapticFeedback.selectionClick();
            context.push('/accounts');
          },
        ));
  }

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
    return Container(
      padding: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
          border: Border(
              top: BorderSide(color: Colors.white.withValues(alpha: .14)))),
      child: Row(children: [
        for (final item in [
          (context.l10n.homeHeroIncome, income, const Color(0xFF31D0AA)),
          (context.l10n.homeHeroSpent, spent, const Color(0xFFFF8A78)),
          (context.l10n.homeHeroNet, net, const Color(0xFF9CC0FF)),
        ])
          Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                          color: item.$3, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text(item.$1,
                      style: AppTypography.custom(
                          size: 11,
                          weight: FontWeight.w400,
                          height: 1.4,
                          color: Colors.white.withValues(alpha: .72))),
                ]),
                const SizedBox(height: 4),
                FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(privacyMode ? '••••' : formatMoney(item.$2),
                        textDirection: TextDirection.ltr,
                        style: AppTypography.custom(
                            size: 15,
                            weight: FontWeight.w600,
                            height: 1.2,
                            color: Colors.white,
                            tabular: true))),
              ])),
      ]),
    );
  }

  Widget _budgetPace(BuildContext context, HeroPeriod period) {
    final amount =
        period == HeroPeriod.day ? data.todaySpend : data.spentThisMonth;
    final limit = period == HeroPeriod.day
        ? data.dailyBudgetLimit
        : data.monthlyBudgetLimit;
    if (limit.isZero || limit.isNegative) return const SizedBox.shrink();
    final used = (amount.toDouble() / limit.toDouble()).clamp(0.0, 1.0);
    final expected = period == HeroPeriod.day
        ? (DateTime.now().hour * 60 + DateTime.now().minute) / 1440
        : data.monthElapsedRatio;
    return Column(children: [
      LayoutBuilder(
          builder: (context, box) => SizedBox(
              height: 10,
              child: Stack(children: [
                Positioned.fill(
                    child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                            value: used,
                            minHeight: 8,
                            color: used > expected
                                ? const Color(0xFFFFBC71)
                                : const Color(0xFF9CC0FF),
                            backgroundColor:
                                Colors.white.withValues(alpha: .16)))),
                PositionedDirectional(
                    start: (box.maxWidth - 2) * expected.clamp(0.0, 1.0),
                    child:
                        Container(width: 2, height: 10, color: Colors.white)),
              ]))),
      const SizedBox(height: 5),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(context.l10n.homePaceUsed((used * 100).round()),
            style: AppTypography.custom(
                size: 10,
                weight: FontWeight.w400,
                height: 1.3,
                color: Colors.white.withValues(alpha: .7))),
        Text(context.l10n.homePaceExpected((expected * 100).round()),
            style: AppTypography.custom(
                size: 10,
                weight: FontWeight.w400,
                height: 1.3,
                color: Colors.white.withValues(alpha: .7))),
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

/// Shortcuts under the hero figure — paste a bank SMS, budgets, goals — as
/// the same white-on-blue glass buttons the header uses ([_AddButton]). Adding
/// a transaction stays the header's «+», as on every other screen.
class _QuickActions extends StatelessWidget {
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    Widget action(IconData icon, String label, VoidCallback onTap) {
      final button = Semantics(
        button: true,
        label: label,
        excludeSemantics: true,
        child: Column(
          children: [
            MaliGlass(
              variant: MaliGlassVariant.headerAction,
              onTap: () {
                HapticFeedback.selectionClick();
                onTap();
              },
              child: SizedBox(
                width: 48,
                height: 48,
                child: Center(child: Icon(icon, color: Colors.white, size: 22)),
              ),
            ),
            const SizedBox(height: 6),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.caption(
                    Colors.white.withValues(alpha: 0.85))),
          ],
        ),
      );
      return Expanded(
          child: icon == AppLucideIcons.clipboardPaste
              ? CoachAnchor(target: 'paste', child: button)
              : button);
    }

    return Row(
      children: [
        action(AppLucideIcons.plus, context.l10n.homeQuickAdd,
            () => ManualTransactionSheet.show(context)),
        action(AppLucideIcons.clipboardPaste, context.l10n.homeQuickPaste,
            () => ManualPasteScreen.showSheet(context)),
        action(AppLucideIcons.pieChart, context.l10n.homeQuickBudget,
            () => context.push('/budgets')),
        action(AppLucideIcons.target, context.l10n.homeQuickGoals,
            () => context.push('/goals')),
      ],
    );
  }
}

/// White add button in the blue zone — opens the add-transaction flow.
class _AddButton extends StatelessWidget {
  const _AddButton();

  @override
  Widget build(BuildContext context) {
    return MaliGlass(
      variant: MaliGlassVariant.headerAction,
      onTap: () {
        HapticFeedback.selectionClick();
        showCaptureEntrySheet(context);
      },
      child: const SizedBox(
        width: 44,
        height: 44,
        child: Center(
          child: Icon(AppLucideIcons.plus, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

/// The hero's اليوم / الأسبوع / الشهر switch.
///
/// Its own widget rather than the shared `SegmentedControl` for two reasons:
/// it lives on the blue hero (white-on-blue, not the canvas palette), and the
/// shared control is a bare `GestureDetector` with no button/selected
/// semantics — which a primary control on the app's first screen cannot be.
/// Each option here is a real [Semantics] button announcing its selected
/// state, with a 44px touch target.
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

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final period in HeroPeriod.values)
              _segment(period, _label(context, period), period == selected),
          ],
        ),
      ),
    );
  }

  Widget _segment(HeroPeriod period, String label, bool isSelected) {
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
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          constraints: const BoxConstraints(minHeight: 38, minWidth: 62),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.pill),
          ),
          child: Text(
            label,
            style: AppTypography.caption(
              isSelected
                  ? AppBrandBlue.brand
                  : Colors.white.withValues(alpha: 0.72),
            ).copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ),
    );
  }
}

/// كام بكسل الأزرق يكمّل تحت نهاية محتوى الهيرو — نفس منطق
/// `CalmPageHeader._meltOverflow`: اللون يوصل تحت أول الكروت والذوبان يحصل
/// خلفها مش في فراغ.
const double _heroMeltOverflow = 220;

class _Sheet extends StatelessWidget {
  const _Sheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Keep the blue fade visible behind the first cards, with no solid edge.
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppSpacing.gutter, AppSpacing.s4, AppSpacing.gutter, 0),
      child: child,
    );
  }
}

/// A Home section title — the shared [SectionHeader], inset 4 like every
/// other Home section. [onBlue] is for a section that sits on the melting
/// hero, where the canvas ink would not read; [badge] is folded into the
/// title as a count.
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
                        : t.textOnCanvasSecondary)),
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
        trailingColor: onBlue ? Colors.white.withValues(alpha: 0.8) : null,
      ),
    );
  }
}

// ─── «للمراجعة» ───────────────────────────────────────────────────────────────

/// Transactions waiting for review, as a card stack: the newest on top, the
/// rest peeking behind it. Reviewing happens in the transaction sheet, where
/// the category can be confirmed or changed.
class _ReviewSection extends ConsumerWidget {
  const _ReviewSection({required this.data, required this.privacyMode});

  final DashboardData data;
  final bool privacyMode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final t = MaliTokens.of(context);
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
        iconName: category?.iconName, color: category?.color, size: 44);
    void openAll() {
      HapticFeedback.selectionClick();
      ref.read(shellIndexProvider.notifier).state = 1;
      ref.read(transactionsPendingFilterProvider.notifier).state = true;
    }

    final top = MaliCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Same tile rule as the transaction rows: the merchant's logo
              // when it is a known brand, otherwise its category.
              (logo != null || BrandMark.hasBrand(title))
                  ? AppAvatar.brand(
                      name: title,
                      logoUrl: logo,
                      size: 44,
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
                        style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                    Text(
                        '${Formatters.dateGroupLabel(tx.occurredAt, context)} · ${Formatters.time(tx.occurredAt, context)}',
                        style: AppTypography.caption(t.textOnCanvasMuted)),
                  ],
                ),
              ),
              Text(
                privacyMode
                    ? '••••'
                    : '${tx.amountMoney.isZero ? '' : debit ? '−' : '+'}${formatMoney(tx.amountMoney.isNegative ? -tx.amountMoney : tx.amountMoney)}',
                // Keeps the sign before the number under RTL («−64.00»).
                textDirection: TextDirection.ltr,
                style: AppTypography.subhead(
                    debit ? t.textOnCanvasPrimary : c.income),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const QirshIllustration(name: 'capture', width: 96, height: 72),
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.homeReviewToStayAccurate,
                      style: AppTypography.caption(t.textOnCanvasSecondary)),
                  if (category != null) ...[
                    const SizedBox(height: 6),
                    Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                            color: category.color.withValues(alpha: 0.14),
                            borderRadius:
                                BorderRadius.circular(AppRadius.pill)),
                        child: Text(category.name,
                            style: AppTypography.micro(t.textOnCanvasPrimary)
                                .copyWith(fontWeight: FontWeight.w700))),
                  ],
                ],
              )),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: () =>
                      TransactionDetailsScreen.showSheet(context, tx.id),
                  icon: const Icon(AppLucideIcons.check, size: 16),
                  label: Text(context.l10n.homeReviewNow),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: openAll,
                  child: Text(context.l10n.homeSeeAll),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    // The layers only peek out under the card's bottom edge: in dark mode
    // the card is translucent, so anything taller would show through it.
    Widget layer(double inset, double alpha) => Positioned(
          left: inset,
          right: inset,
          bottom: -inset * 0.9,
          height: inset * 0.9 + 14,
          child: Container(
            key: ValueKey('home-review-layer-$inset'),
            decoration: BoxDecoration(
              // Scales the token's own opacity (7% white in dark, opaque
              // white in light) — never replaces it.
              color: Color.alphaBlend(
                  t.surfaceFloating
                      .withValues(alpha: t.surfaceFloating.a * alpha),
                  c.bg),
              borderRadius: BorderRadius.circular(AppRadius.xxl),
              border: Border.all(color: t.cardBorder),
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
          padding: EdgeInsets.only(bottom: count > 1 ? 16 : 0),
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
        const SizedBox(height: AppSpacing.s6),
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
        const SizedBox(height: AppSpacing.s6),
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
        const SizedBox(height: AppSpacing.s6),
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

class _SetupNudgeCard extends ConsumerWidget {
  const _SetupNudgeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(_setupNudgeDismissedProvider)) {
      return const SizedBox.shrink();
    }
    if (ref.watch(_setupNudgeSnoozedProvider).valueOrNull ?? true) {
      return const SizedBox.shrink();
    }
    final hasGoals =
        ref.watch(goalsListProvider).valueOrNull?.isNotEmpty ?? true;
    final lockEnabled = ref.watch(_appLockEnabledProvider).valueOrNull ?? true;
    if (hasGoals && lockEnabled) return const SizedBox.shrink();
    final t = MaliTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: MaliCard(
        style: MaliSurfaceStyle.floating,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(context.l10n.homeFinishSetup,
                      style: AppTypography.bodyStrong(t.textOnCanvasPrimary)),
                ),
                InkWell(
                  onTap: () => _snoozeSetupNudge(ref),
                  borderRadius: BorderRadius.circular(12),
                  child: Icon(AppLucideIcons.x,
                      size: 18, color: t.textOnCanvasMuted),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.s3),
            Wrap(
              spacing: AppSpacing.s2,
              runSpacing: AppSpacing.s2,
              children: [
                if (!lockEnabled)
                  _SetupNudgeChip(
                    icon: AppLucideIcons.fingerprint,
                    label: context.l10n.homeEnableBiometrics,
                    onTap: () =>
                        ref.read(shellIndexProvider.notifier).state = 3,
                  ),
                if (!hasGoals)
                  _SetupNudgeChip(
                    icon: AppLucideIcons.piggyBank,
                    label: context.l10n.homeAddSavingsGoal,
                    onTap: () =>
                        ref.read(shellIndexProvider.notifier).state = 2,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SetupNudgeChip extends StatelessWidget {
  const _SetupNudgeChip(
      {required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: c.cta.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: c.cta.withValues(alpha: 0.30)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: c.cta),
            const SizedBox(width: 6),
            Text(label, style: AppTypography.footnote(c.cta)),
          ],
        ),
      ),
    );
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
