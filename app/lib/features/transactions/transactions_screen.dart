import '../common/top_banner.dart';
import '../../core/session/app_session.dart';
import '../../domain/entities/captured_message.dart';
import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/utils/l10n_ext.dart';
import '../../core/utils/async_reload_safe.dart';
import 'package:flutter/services.dart';

import '../../core/di/app_providers.dart';
import '../../core/privacy/consent_authority.dart';
import '../consent/smart_analysis_consent_sheet.dart';
import '../settings/settings_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/app_shadows.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/glass_selector.dart';
import '../../core/theme/widgets/mali_card.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/category_glyph.dart';
import '../../core/utils/currency.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/bill_entity.dart';
import '../../domain/finance/bill_metrics.dart';
import '../../domain/finance/money.dart' show Money;
import '../../domain/finance/money_format.dart';
import '../../domain/entities/transaction_entity.dart';
import '../cards/brand_mark.dart';
import '../common/app_avatar.dart';
import '../common/premium_loading.dart';
import '../common/motion.dart';
import '../common/transaction_direction.dart';
import '../common/app_pill_tab_bar.dart';
import '../common/app_empty_state.dart';
import '../common/app_transaction_row.dart';
import '../common/app_sheet_scaffold.dart';
import '../common/category_catalog.dart';
import '../subscriptions/bill_form_sheet.dart';
import '../dashboard/dashboard_providers.dart';
import '../../domain/entities/suspected_duplicate_entity.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../ads/ad_placement.dart';
import '../ads/qirsh_ad_banner.dart';
import '../capture/capture_entry_sheet.dart';
import 'manual_transaction_sheet.dart';
import 'transaction_details_screen.dart';
import 'transactions_providers.dart';
import 'widgets/change_category_sheet.dart';
import 'widgets/account_scope_sheet.dart';
import 'widgets/activity_chip.dart';
import '../common/qirsh_summary_card.dart';
import '../subscriptions/subscriptions_providers.dart'
    show billsScopeAccountProvider;
import '../subscriptions/widgets/bills_overview.dart';
import 'package:flutter/rendering.dart';
import '../../core/theme/widgets/directional_chevron.dart';
import '../../core/theme/widgets/glass_sheet.dart';
import '../../core/theme/widgets/glass_dialog.dart';
import '../../core/theme/widgets/glass_pickers.dart';
import '../common/app_error_state.dart';

class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  /// v2 header icons: search reveals (and focuses) the existing search field;
  /// the filter chip (end of the chips row) reveals the existing account /
  /// date-range selectors.
  bool _searchOpen = false;
  bool _filtersOpen = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(transactionsListProvider);
    final searchQuery = ref.watch(transactionSearchQueryProvider);
    final billsAsync = ref.watch(billsViewProvider);
    final tab = ref.watch(transactionsPageTabProvider);
    final pendingOnly = ref.watch(transactionsPendingFilterProvider);
    // MALI-047n: canonical period expense over the full dataset (not a fold of
    // loaded pages), single-currency for the active-account scope.
    final periodTotal = ref.watch(transactionsPeriodTotalProvider).valueOrNull;
    final privacyMode =
        ref.watch(userSettingsProvider).valueOrNull?.privacyModeEnabled ??
            false;
    final logos = ref.watch(merchantLogosProvider).valueOrNull ??
        const <String, String>{};

    return Scaffold(
      // مفيش FAB: زرار الإضافة في الهيدر هو المنفذ الوحيد للإضافة.
      body: async.when(
        skipLoadingOnReload: true,
        loading: () => const SkeletonList(rows: 6),
        error: (e, _) => SafeArea(
            child: SingleChildScrollView(
                child: AppErrorState(
          title: context.l10n.txnError,
          description: context.l10n.annTryAgainSoon,
          retryLabel: context.l10n.startRetry,
          onRetry: () => ref.invalidate(transactionsListProvider),
        ))),
        data: (view) {
          // B2-C — date-section grouping is precomputed once in the provider
          // (view.sections), not re-grouped over every row on every build here.
          final sections = view.sections;
          Widget txRow(TransactionEntity tx) {
            final category = view.catalog.byId(tx.categoryId);
            final title = tx.rawMerchant ??
                category?.name ??
                context.l10n.txnTransactionWord;
            final row = AppTransactionRow(
              title: title,
              amount: tx.amount,
              amountMoney: tx.amountMoney,
              currency: Currency.label(context, tx.currency),
              subtitle:
                  '${Formatters.time(tx.occurredAt, context)} · ${category?.name ?? context.l10n.homeUncategorised}',
              categoryIconName: category?.iconName,
              categoryColor:
                  category?.accent(Theme.of(context).brightness),
              brandLogoUrl: BrandMark.logoFor(title, logos),
              isPending: tx.status == TransactionStatus.pending,
              awaitingPrice:
                  tx.pricingState == TransactionPricingState.awaitingFx,
              isAi: tx.source == TransactionSourceEntity.aiParsed,
              isDebit: transactionIsDebit(tx),
              horizontalPadding: 14,
              onTap: () => TransactionDetailsScreen.showSheet(context, tx.id),
            );
            // v2 row swipe (trailing → leading) reveals «تغيير التصنيف» and
            // opens the SAME category sheet the detail screen uses; the row
            // snaps back. Delete is not offered here — its handler (with the
            // bill-payment cleanup) lives inside the detail screen only.
            return Dismissible(
              key: ValueKey('txn-swipe-${tx.id}'),
              direction: DismissDirection.endToStart,
              dismissThresholds: const {DismissDirection.endToStart: 0.3},
              background: ColoredBox(
                color: context.colors.cta,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.s4),
                  child: Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(AppLucideIcons.shapes,
                            size: 18, color: context.colors.onCta),
                        const SizedBox(width: AppSpacing.s2),
                        Text(context.l10n.txnChangeCategory,
                            style: AppTypography.subhead(
                                context.colors.onCta)),
                      ],
                    ),
                  ),
                ),
              ),
              confirmDismiss: (_) async {
                HapticFeedback.lightImpact();
                await showChangeCategorySheet(context, tx, view.catalog);
                return false;
              },
              child: row,
            );
          }

          // v2: search and the account/date filters stay out of the first
          // screenful until asked for. An active query keeps the field open.
          final searchField = AnimatedSize(
            duration: AppMotion.base,
            curve: AppMotion.easeInOut,
            alignment: AlignmentDirectional.topStart,
            child: _searchOpen || searchQuery.isNotEmpty
                ? Padding(
                    padding: const EdgeInsets.only(bottom: AppSpacing.s3),
                    child: TransactionSearchField(autofocus: _searchOpen),
                  )
                : const SizedBox(width: double.infinity),
          );
          // Revealed by the filter chip, directly under the chips row.
          final filterPanel = AnimatedSize(
            duration: AppMotion.base,
            curve: AppMotion.easeInOut,
            alignment: AlignmentDirectional.topStart,
            child: !_filtersOpen
                ? const SizedBox(width: double.infinity)
                : Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s2),
                    child: !pendingOnly
                        ? Row(children: [
                            const Expanded(
                                child: _ActiveAccountPicker(onBlue: false)),
                            const SizedBox(width: AppSpacing.s2),
                            Expanded(
                                child: _DateRangeChips(
                                    range: view.range, onBlue: false)),
                          ])
                        : const _ActiveAccountPicker(onBlue: false),
                  ),
          );

          final bills = billsAsync.valueOrNull;
          final header = _TransactionsHeader(
            subtitle: tab == 0
                ? '${view.range.labelIn(Localizations.localeOf(context).languageCode)} ${context.l10n.txnCountSuffix(view.transactions.length.toString())}${view.hasMore ? "+" : ""}'
                : bills == null
                    ? null
                    : context.l10n.billsV3Counts(
                        bills.subscriptionsCount, bills.installmentsCount),
            // The ONE Transactions | Bills control, on the photo for both tabs.
            tabs: AppPillTabBar(
              onPhoto: true,
              tabs: [
                context.l10n.txnTabTransactions,
                context.l10n.txnTabBills,
              ],
              selectedIndex: tab,
              onSelected: (value) {
                if (tab == value) return;
                ref.read(transactionsPageTabProvider.notifier).state = value;
              },
            ),
            onSearch: () {
              HapticFeedback.selectionClick();
              if (tab != 0) {
                // Search lives on the activity list: go there and open it.
                ref.read(transactionsPageTabProvider.notifier).state = 0;
                setState(() => _searchOpen = true);
                return;
              }
              if (_searchOpen) FocusManager.instance.primaryFocus?.unfocus();
              setState(() => _searchOpen = !_searchOpen);
            },
            onAdd: () {
              if (tab == 0) {
                showCaptureEntrySheet(context);
              } else {
                BillFormSheet.show(context);
              }
            },
          );

          // Immersive top edge: the scroll view fills from y = 0 and the
          // section photo runs under the status bar on BOTH tabs. On the
          // activity list a transparent pinned band of the status-bar height
          // leads the headers so the pinned chips dock right under the clock,
          // while rows pass beneath both (the glass is QirshSectionBackdrop +
          // the chips). The photo hero is pulled up under that band, so at
          // rest the page looks exactly like the Bills tab.
          final statusTop = tab == 0 ? MediaQuery.paddingOf(context).top : 0.0;

          final scrollView = NestedScrollView(
            headerSliverBuilder: (context, innerBoxIsScrolled) {
              return [
                if (statusTop > 0)
                  PinnedHeaderSliver(child: SizedBox(height: statusTop)),
                SliverToBoxAdapter(
                  child: PremiumMotion(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PullUnder(by: statusTop, child: header),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.gutter,
                          ),
                          child: Column(
                            children: [
                                      if (tab == 0) ...[
                                        searchField,
                                        _TransactionsSummary(
                                          total: periodTotal,
                                          privacyMode: privacyMode,
                                          periodLabel: view.range.labelIn(
                                              Localizations.localeOf(context)
                                                  .languageCode),
                                          thisMonth: view.range.preset ==
                                              TransactionsDatePreset.thisMonth,
                                          onPeriodTap: () {
                                            HapticFeedback.selectionClick();
                                            _DateRangeChips.open(
                                                context, ref, view.range);
                                          },
                                        ),
                                        const SizedBox(height: AppSpacing.s3),
                                      ],
                                      if (tab == 0) ...[
                                        const _SuspectedDuplicatesBanner(),
                                        const _SmartInboxBanner(),
                                      ],
                                      if (tab == 0) ...[
                                        if (pendingOnly) ...[
                                          Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        horizontal: 12,
                                                        vertical: 8),
                                                decoration: BoxDecoration(
                                                  color: context.colors.warningBg,
                                                  borderRadius:
                                                      BorderRadius.circular(20),
                                                  border: Border.all(
                                                      color: context
                                                          .colors.warning
                                                          .withValues(
                                                              alpha: 0.30)),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                        AppLucideIcons
                                                            .alertTriangle,
                                                        size: 14,
                                                        color: context
                                                            .colors.warningText),
                                                    const SizedBox(width: 6),
                                                    Text(
                                                        context.l10n
                                                            .txnFilterPending,
                                                        style: AppTypography
                                                                .caption(context
                                                                    .colors
                                                                    .warningText)
                                                            .copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700)),
                                                    const SizedBox(width: 8),
                                                    GestureDetector(
                                                      onTap: () => ref
                                                          .read(
                                                              transactionsPendingFilterProvider
                                                                  .notifier)
                                                          .state = false,
                                                      child: Icon(
                                                          AppLucideIcons.x,
                                                          size: 14,
                                                          color: context
                                                              .colors.warningText),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const Spacer(),
                                              if (view.pendingCount > 0)
                                                TextButton.icon(
                                                  onPressed: () =>
                                                      _confirmAllPending(
                                                          context,
                                                          ref,
                                                          view.transactions),
                                                  icon: Icon(
                                                      AppLucideIcons.checkCheck,
                                                      size: 18,
                                                      color: context
                                                          .colors.success),
                                                  label: Text(
                                                    context.l10n.txnConfirmAll,
                                                    style:
                                                        AppTypography.caption(
                                                                context.colors
                                                                    .success)
                                                            .copyWith(
                                                                fontWeight:
                                                                    FontWeight
                                                                        .w700),
                                                  ),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: AppSpacing.s3),
                                        ],
                                      ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // v2 sticky filter row: pins under the status bar and turns to
                // glass once content scrolls beneath it.
                if (tab == 0)
                  SliverOverlapAbsorber(
                    handle:
                        NestedScrollView.sliverOverlapAbsorberHandleFor(context),
                    sliver: SliverPersistentHeader(
                      pinned: true,
                      delegate: _PinnedFilterBarDelegate(
                        filtersOpen: _filtersOpen,
                        onFilter: () =>
                            setState(() => _filtersOpen = !_filtersOpen),
                      ),
                    ),
                  ),
              ];
            },
            // The header keeps the device inset (the photo pads below the
            // clock); the body lists consume none of it, as before.
            body: MediaQuery.removePadding(
              context: context,
              removeTop: true,
              child: MeltTail(
              startAt: 64,
              child: tab == 0
                  ? NotificationListener<ScrollNotification>(
                      onNotification: (notification) {
                        if (notification.metrics.extentAfter < 900 &&
                            view.hasMore &&
                            !view.isLoadingMore) {
                          ref
                              .read(transactionsListProvider.notifier)
                              .loadMore();
                        }
                        return false;
                      },
                      child: Builder(
                        builder: (context) => CustomScrollView(
                          slivers: [
                            SliverOverlapInjector(
                              handle: NestedScrollView
                                  .sliverOverlapAbsorberHandleFor(context),
                            ),
                            if (statusTop > 0)
                              _StatusBandCatchUp(
                                // This Builder sits inside the OUTER
                                // scrollable, so this is the header's offset.
                                outer: Scrollable.maybeOf(context)?.position,
                                statusTop: statusTop,
                              ),
                            SliverToBoxAdapter(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.gutter),
                                child: filterPanel,
                              ),
                            ),
                            SliverPadding(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.gutter,
                                AppSpacing.s2,
                                AppSpacing.gutter,
                                120,
                              ),
                              sliver: SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  childCount: view.transactions.isEmpty
                                      ? 1
                                      : sections.length + 1,
                                  (context, index) {
                                  final itemIndex = index;
                                  if (view.transactions.isEmpty) {
                                    // EMPTY STATE — the message first, the banner
                                    // after it. A placement may not depend on the
                                    // user having data, but it must still sit below
                                    // the explanation rather than replace it.
                                    return Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        AppEmptyState(
                                          illustration: QirshIllustration(
                                            name: pendingOnly
                                                ? 'reviewDone'
                                                : 'emptyTx',
                                            width: 210,
                                            height: 158,
                                          ),
                                          icon: AppLucideIcons.inbox,
                                          title: pendingOnly
                                              ? context
                                                  .l10n.txnPendingEmptyTitle
                                              : context
                                                  .l10n.txnEmptyPeriodTitle,
                                          subtitle: pendingOnly
                                              ? context.l10n.txnPendingEmptyBody
                                              : context.l10n.txnEmptyPeriodBody,
                                          // v2 QEmptyState: one useful action
                                          // — the same add entry as the «+».
                                          primaryLabel: pendingOnly
                                              ? null
                                              : context.l10n.cesTitle,
                                          onPrimary: pendingOnly
                                              ? null
                                              : () => showCaptureEntrySheet(
                                                  context),
                                        ),
                                        if (!pendingOnly) ...[
                                          const SizedBox(height: AppSpacing.s4),
                                          const QirshAdBanner(
                                            placement:
                                                AdPlacement.transactionsList,
                                          ),
                                        ],
                                      ],
                                    );
                                  }
                                  if (itemIndex == sections.length &&
                                      !view.isLoadingMore) {
                                    // v2 end-of-list marker; while more pages
                                    // exist it would be a lie, so it waits.
                                    // (The loading row below takes this slot
                                    // while a page is in flight.)
                                    return view.hasMore
                                        ? const SizedBox.shrink()
                                        : Padding(
                                            padding: const EdgeInsets.only(
                                                top: AppSpacing.s2),
                                            child: Text(
                                              context.l10n.txnV2EndOfList,
                                              textAlign: TextAlign.center,
                                              style: AppTypography.caption(
                                                  context.colors.textMuted),
                                            ),
                                          );
                                  }
                                  if (itemIndex >= sections.length) {
                                    return const Padding(
                                      padding: EdgeInsets.all(
                                          AppSpacing.cardPadding),
                                      child: Center(
                                          child: CircularProgressIndicator()),
                                    );
                                  }
                                  final section = sections[itemIndex];
                                  return Padding(
                                    padding: const EdgeInsets.only(
                                        bottom: AppSpacing.s4),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        _DateHeader(
                                          label: Formatters.dateGroupLabel(
                                              section.day, context),
                                          transactions: section.transactions,
                                          privacyMode: privacyMode,
                                        ),
                                        // v2: one Group card per day, rows
                                        // inside it (never a card per row).
                                        MaliCard(
                                          style: MaliSurfaceStyle.floating,
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 4),
                                          child: Column(
                                            children: [
                                              for (final tx
                                                  in section.transactions)
                                                txRow(tx),
                                            ],
                                          ),
                                        ),
                                        // The app's ONLY banner placement.
                                        //
                                        // After the FIRST complete day, and only
                                        // when another day follows, so the ad is
                                        // always bracketed by real content and is
                                        // never the last thing on the screen. It
                                        // sits below a finished card rather than
                                        // between two transaction rows: the rows
                                        // are tappable (they open the detail
                                        // sheet), and an ad flush against one is
                                        // the accidental-click layout Google's own
                                        // placement guidance calls out.
                                        //
                                        // Not shown on the pending-review filter.
                                        // That list is a correction workflow — the
                                        // user is fixing how their money was
                                        // classified — and an advertisement does
                                        // not belong in the middle of it. That is a
                                        // workflow rule, not a content rule, so it
                                        // stays.
                                        //
                                        // A SECOND date section used to be
                                        // required as well, so the ad was always
                                        // bracketed by another day. Dropped:
                                        // availability may no longer depend on how
                                        // much data exists.
                                        if (itemIndex == 0 && !pendingOnly)
                                          const QirshAdBanner(
                                            placement:
                                                AdPlacement.transactionsList,
                                          ),
                                      ],
                                    ),
                                  );
                                  },
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView(
                              padding: const EdgeInsets.fromLTRB(
                                AppSpacing.gutter,
                                AppSpacing.s3,
                                AppSpacing.gutter,
                                120,
                              ),
                              children: [
                                billsAsync.when(
                                  skipLoadingOnReload: true,
                                  loading: () => const Padding(
                                    padding: EdgeInsets.all(AppSpacing.s5),
                                    child: Center(
                                        child: CircularProgressIndicator()),
                                  ),
                                  error: (error, _) =>
                                      Text(context.l10n.txnError),
                                  data: (bills) {
                                    // F-027 — the display currency must come
                                    // from the user's base currency, never
                                    // from `bills.first`, which made the total
                                    // depend on list ORDER and silently
                                    // dropped every bill in another currency.
                                    final baseCurrency = ref
                                            .watch(baseCurrencyProvider)
                                            .valueOrNull ??
                                        'SAR';
                                    final scopeAccountName = ref
                                        .watch(billsScopeAccountProvider)
                                        .valueOrNull
                                        ?.name;
                                    // Active instalments only: the metric
                                    // applies no filter of its own.
                                    final instalmentsMonthly =
                                        monthlyEquivalentsTotalMoney(
                                      bills.bills.where((b) =>
                                          b.type == BillType.installment &&
                                          b.status == BillStatus.active),
                                      baseCurrency,
                                    );
                                    return BillsOverview(
                                      bills: bills.bills,
                                      instalmentsMonthly: instalmentsMonthly,
                                      subscriptionsExtraStat: instalmentsMonthly
                                                  .minorUnits >
                                              0
                                          ? QirshSummaryStat(
                                              value: Text(
                                                  '${formatMoney(instalmentsMonthly)} ${Currency.label(context, baseCurrency)}',
                                                  maxLines: 1),
                                              label: context
                                                  .l10n.subsMonthlyInstCommit,
                                            )
                                          : null,
                                      suggestions: bills.suggestions,
                                      baseCurrency: baseCurrency,
                                      subscriptionsMonthly:
                                          subscriptionMonthlyTotalMoney(
                                              bills.bills, baseCurrency),
                                      subscriptionsLabel: scopeAccountName ==
                                              null
                                          ? context.l10n.subsMonthlyTotal
                                          : context.l10n.subsMonthlyScoped(
                                              scopeAccountName),
                                    );
                                  },
                                ),
                              ],
                            ),
            ),
            ),
          );

          // Both tabs share the section photo and its status band, so
          // switching Transactions ↔ Bills never changes the page's look.
          return QirshSectionBackdrop(
            child: SafeArea(
              // Immersive: the photo runs under the status bar.
              top: false,
              bottom: false,
              child: scrollView,
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmAllPending(
    BuildContext context,
    WidgetRef ref,
    List<TransactionEntity> transactions,
  ) async {
    final pending = transactions
        .where((t) => t.status == TransactionStatus.pending)
        .toList();
    if (pending.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text(context.l10n.txnConfirmAllTitle),
        content: Text(context.l10n.txnConfirmAllBody(pending.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(context.l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(context.l10n.txnConfirm),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final repo = ref.read(transactionRepositoryProvider);
    for (final tx in pending) {
      await repo.confirm(tx.id);
    }
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    ref.read(transactionsPendingFilterProvider.notifier).state = false;
  }
}

class _ActiveAccountPicker extends ConsumerWidget {
  const _ActiveAccountPicker({this.onBlue = true});

  /// White-on-photo for the bills section hero; canvas tone on the v2
  /// activity page.
  final bool onBlue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountsProvider);
    final selectedId = ref.watch(activeAccountIdProvider);
    return accountsAsync.dataOrWhen(
      data: (accounts) {
        if (accounts.isEmpty) return const SizedBox.shrink();
        final defaultAccount = accounts.firstWhere(
          (account) => account.isDefault,
          orElse: () => accounts.first,
        );
        final account = accounts.firstWhere(
          (item) => item.id == selectedId,
          orElse: () => defaultAccount,
        );
        return GlassSelector(
          onBlue: onBlue,
          icon: AppLucideIcons.walletCards,
          label:
              '${account.name} · ${Currency.label(context, account.currency)}',
          onTap: () => showAccountScopeSheet(context, ref, account.id),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class TransactionSearchField extends ConsumerStatefulWidget {
  const TransactionSearchField(
      {super.key, this.onPhoto = false, this.autofocus = false});

  final bool onPhoto;

  /// Focus on insert — the header's search icon reveals the field and the
  /// keyboard rises with it.
  final bool autofocus;

  @override
  ConsumerState<TransactionSearchField> createState() =>
      TransactionSearchFieldState();
}

class TransactionSearchFieldState
    extends ConsumerState<TransactionSearchField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  // MALI-029 / rendering — debounce the search so a burst of keystrokes does not
  // re-fetch page 1 + re-filter + re-group the whole list on every character; the
  // field text updates instantly, only the filter query is debounced.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: ref.read(transactionSearchQueryProvider),
    );
    _focusNode = FocusNode()..addListener(_revealPhotoSearch);
  }

  void _revealPhotoSearch() {
    if (!widget.onPhoto || !_focusNode.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_focusNode.hasFocus) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _onQueryChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) {
        ref.read(transactionSearchQueryProvider.notifier).state = value;
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _focusNode
      ..removeListener(_revealPhotoSearch)
      ..dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final query = ref.watch(transactionSearchQueryProvider);
    // v2 field on canvas: dark = Inset well; light = white + 1px stroke.soft
    // + e1 (the old canvas-coloured field was invisible in light, L2).
    final field = TextField(
      controller: _controller,
      focusNode: _focusNode,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      onChanged: _onQueryChanged,
      decoration: InputDecoration(
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        hintText: context.l10n.txnSearchHint,
        hintStyle: TextStyle(fontSize: 14, color: c.textMuted),
        prefixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: 40),
        prefixIcon: const Icon(AppLucideIcons.search, size: 20),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 40, minHeight: 40),
        suffixIcon: query.isEmpty
            ? null
            : IconButton(
                tooltip: context.l10n.txnClearSearch,
                padding: EdgeInsets.zero,
                iconSize: 20,
                onPressed: () {
                  _searchDebounce?.cancel();
                  _controller.clear();
                  ref.read(transactionSearchQueryProvider.notifier).state = '';
                },
                icon: const Icon(AppLucideIcons.x),
              ),
        filled: true,
        fillColor: widget.onPhoto
            ? c.surface
            : isDark
                ? c.surfaceMuted
                : c.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          borderSide: BorderSide(
              color: widget.onPhoto
                  ? c.border.withValues(alpha: 0.4)
                  : c.strokeSoft),
        ),
      ),
    );
    if (widget.onPhoto || isDark) return field;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.pill),
        boxShadow: AppShadows.e1,
      ),
      child: field,
    );
  }
}

class _DateRangeChips extends ConsumerWidget {
  const _DateRangeChips({required this.range, this.onBlue = true});

  final TransactionsDateRange range;
  final bool onBlue;

  /// Opens the same period picker (the summary card's scope chip uses it).
  static Future<void> open(BuildContext context, WidgetRef ref,
          TransactionsDateRange range) =>
      _DateRangeChips(range: range)._showRangeSheet(context, ref, range);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GlassSelector(
      onBlue: onBlue,
      icon: AppLucideIcons.calendarDays,
      label: range.labelIn(Localizations.localeOf(context).languageCode),
      onTap: () {
        HapticFeedback.selectionClick();
        _showRangeSheet(context, ref, range);
      },
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

  TransactionsDateRange _rangeForPreset(TransactionsDatePreset preset) {
    return transactionsRangeForPreset(preset, customFallback: range);
  }

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
                                .state = _rangeForPreset(preset);
                            Navigator.of(context).pop();
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.s4),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.s3),
                    decoration: BoxDecoration(
                      color: c.surfaceCard,
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
                              if (picked != null) setState(() => from = picked);
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
                  const SizedBox(height: AppSpacing.s4),
                  FilledButton(
                    onPressed: to.isBefore(from)
                        ? null
                        : () {
                            ref
                                .read(transactionsDateRangeProvider.notifier)
                                .state = TransactionsDateRange(
                              preset: TransactionsDatePreset.custom,
                              from: from,
                              to: DateTime(
                                to.year,
                                to.month,
                                to.day,
                                23,
                                59,
                                59,
                              ),
                            );
                            Navigator.of(context).pop();
                          },
                    child: Text(context.l10n.txnApplyCustomRange),
                  ),
                  const SizedBox(height: AppSpacing.s4),
                ],
              ),
            ),
          );
        },
      )),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filtersOpen, required this.onFilter});

  final bool filtersOpen;
  final VoidCallback onFilter;

  @override
  Widget build(BuildContext context) {
    // v2: horizontally scrollable with a 24pt fade on the trailing edge
    // instead of a hard clip of the last chip.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final fade = rect.width <= 0 ? 0.0 : (24 / rect.width).clamp(0.0, 1.0);
        return LinearGradient(
          begin: rtl ? Alignment.centerLeft : Alignment.centerRight,
          end: rtl ? Alignment.centerRight : Alignment.centerLeft,
          colors: const [Color(0x00000000), Color(0xFF000000)],
          stops: [0, fade],
        ).createShader(rect);
      },
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Row(
          children: [
            const _KindFilterChips(),
            const _PendingFilterChip(),
            const SizedBox(width: 8),
            const _CategoryFilterButton(),
            const SizedBox(width: 8),
            // The account / date filters (was the header's filter icon).
            ActivityChip(
              label: '',
              semanticLabel: context.l10n.txnV2Filters,
              selected: filtersOpen,
              onTap: onFilter,
              leading: Icon(AppLucideIcons.filter,
                  size: 16,
                  color: filtersOpen
                      ? context.colors.actionText
                      : context.colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _KindFilterChips extends ConsumerWidget {
  const _KindFilterChips();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(transactionKindFilterProvider);
    final items = {
      TransactionKindFilter.all: context.l10n.txnKindAll,
      TransactionKindFilter.expenses: context.l10n.txnKindExpense,
      TransactionKindFilter.income: context.l10n.txnKindIncome,
      TransactionKindFilter.transfers: context.l10n.txnKindTransfer,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in items.entries)
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: ActivityChip(
              label: entry.value,
              selected: filter == entry.key,
              onTap: () => ref
                  .read(transactionKindFilterProvider.notifier)
                  .state = entry.key,
            ),
          ),
      ],
    );
  }
}

/// UX-016 — the missing «قيد المراجعة» filter.
///
/// The pending-only filter already existed and was reachable from exactly two
/// places, both OUTSIDE this screen: the Home banner and a notification tap.
/// On Transactions itself the app showed «1 قيد المراجعة» in the header, told
/// the user to review those items — «راجعها عشان أرصدتك تفضل مظبوطة» — and then
/// offered only الكل / مصروفات / دخل / تحويلات / التصنيف. It asked for a review
/// it gave no way to start. Fine at the QA's 34 rows; impossible at 500.
///
/// A separate toggle rather than a fifth kind chip, because pending is a
/// STATUS and the others are kinds: «مصروفات» and «قيد المراجعة» are a
/// meaningful combination, and making it a fifth kind would have made them
/// mutually exclusive. That also matches the existing provider, which ANDs
/// `pendingOnly` with the kind filter rather than replacing it.
class _PendingFilterChip extends ConsumerWidget {
  const _PendingFilterChip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(transactionsPendingFilterProvider);
    // v2: the review count rides on the chip (it used to sit in the header
    // subtitle).
    final pending =
        ref.watch(transactionsListProvider).valueOrNull?.pendingCount ?? 0;
    return ActivityChip(
      label: context.l10n.txnPendingReview,
      selected: active,
      badge: pending,
      onTap: () =>
          ref.read(transactionsPendingFilterProvider.notifier).state = !active,
    );
  }
}

/// Opens a category picker; shows the selected category (icon + name) or a
/// neutral "التصنيف" placeholder when no category filter is active.
class _CategoryFilterButton extends ConsumerWidget {
  const _CategoryFilterButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final selectedId = ref.watch(transactionCategoryFilterProvider);
    final catalog = ref.watch(categoryCatalogProvider).valueOrNull;
    final selected = catalog?.byId(selectedId);
    final active = selectedId != null;

    final fg = active ? c.actionText : c.textSecondary;
    return ActivityChip(
      label: selected?.name ?? context.l10n.txnCategory,
      selected: active,
      onTap: () => _showCategoryFilterSheet(context, ref),
      leading: CategoryGlyph(
          name: selected?.iconName ?? 'shapes', size: 15, color: fg),
      trailing: active
          ? GestureDetector(
              onTap: () => ref
                  .read(transactionCategoryFilterProvider.notifier)
                  .state = null,
              child: Icon(AppLucideIcons.x, size: 14, color: fg),
            )
          : null,
    );
  }

  Future<void> _showCategoryFilterSheet(
      BuildContext context, WidgetRef ref) async {
    final catalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => navySheetTheme(_CategoryFilterSheet(catalog: catalog)),
    );
  }
}

class _CategoryFilterSheet extends ConsumerWidget {
  const _CategoryFilterSheet({required this.catalog});

  final CategoryCatalog catalog;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final selectedId = ref.watch(transactionCategoryFilterProvider);
    // قايمة رأسية بدل شبكة حبوب مبعثرة: كل تصنيف في سطر بعرض واحد —
    // التايل، الاسم، وعلامة صح على المختار.
    return AppSheetScaffold(
      title: context.l10n.txnFilterByCategory,
      scrollable: true,
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
        child: Container(
          decoration: BoxDecoration(
            color: c.surfaceElevated,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: c.divider),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _CategoryFilterRow(
                label: context.l10n.txnAllCategories,
                selected: selectedId == null,
                leading: AppAvatar.icon(
                  icon: AppLucideIcons.shapes,
                  color: c.primary,
                  size: AppSpacing.avatarSm,
                ),
                onTap: () {
                  ref.read(transactionCategoryFilterProvider.notifier).state =
                      null;
                  Navigator.of(context).pop();
                },
              ),
              for (final cat in catalog.all) ...[
                Divider(height: 1, thickness: 1, color: c.divider),
                _CategoryFilterRow(
                  label: cat.name,
                  selected: selectedId == cat.id,
                  leading: AppAvatar.category(
                    category: cat,
                    size: AppSpacing.avatarSm,
                  ),
                  onTap: () {
                    ref.read(transactionCategoryFilterProvider.notifier).state =
                        cat.id;
                    Navigator.of(context).pop();
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryFilterRow extends StatelessWidget {
  const _CategoryFilterRow({
    required this.label,
    required this.selected,
    required this.leading,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Widget leading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: selected ? c.primary.withValues(alpha: 0.12) : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
          child: Row(
            children: [
              leading,
              const SizedBox(width: AppSpacing.s3),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: selected
                      ? AppTypography.subhead(c.textMain)
                      : AppTypography.callout(c.textMain),
                ),
              ),
              if (selected)
                Icon(AppLucideIcons.check, size: 18, color: c.primary),
            ],
          ),
        ),
      ),
    );
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader({
    required this.label,
    this.transactions = const <TransactionEntity>[],
    this.privacyMode = false,
  });

  final String label;

  /// The day's SHOWN rows; their net sits at the trailing end.
  final List<TransactionEntity> transactions;
  final bool privacyMode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Net of the SHOWN rows: debits subtract, credits add. Money refuses to
    // mix currencies, so a day is folded per currency and only the first
    // row's currency is stated (same rule as the Home transactions panel).
    String? net;
    if (transactions.isNotEmpty) {
      final currency = transactions.first.amountMoney.currency;
      var sum = Money.zero(currency);
      for (final tx in transactions) {
        if (tx.amountMoney.currency != currency) continue;
        sum = transactionIsDebit(tx) ? sum - tx.amountMoney : sum + tx.amountMoney;
      }
      net = privacyMode
          ? '••••'
          // v2: a true minus (U+2212) leads the digits.
          : sum.isNegative
              ? '−${formatMoney(-sum)}'
              : '+${formatMoney(sum)}';
    }
    // v2 day header: `subhead` text.secondary, aligned with the card.
    return Padding(
      padding: const EdgeInsetsDirectional.only(
          top: AppSpacing.s3, bottom: AppSpacing.s2, start: 4, end: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.start,
              style: AppTypography.subhead(c.textSecondary),
            ),
          ),
          if (net != null)
            Text(
              net,
              textDirection: TextDirection.ltr,
              style: AppTypography.custom(
                size: 13,
                weight: FontWeight.w600,
                height: 1.3,
                tabular: true,
                color: c.textSecondary,
              ),
            ),
        ],
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return CalmHeaderAction(
      icon: AppLucideIcons.plus,
      primary: true,
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
    );
  }
}

/// Activity summary (v3 `QirshSummaryCard`): the period's net, with Out / In
/// beneath. Complete, canonical, currency-isolated totals; a not-yet-loaded or
/// failed aggregate is unknown (—), never an invented zero; privacy masks all.
class _TransactionsSummary extends StatelessWidget {
  const _TransactionsSummary({
    required this.total,
    required this.privacyMode,
    required this.periodLabel,
    required this.thisMonth,
    required this.onPeriodTap,
  });
  final TransactionsPeriodTotal? total;
  final bool privacyMode;
  final String periodLabel;
  final bool thisMonth;
  final VoidCallback onPeriodTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final value = total;
    final expense = privacyMode
        ? '••••'
        : value == null
            ? '—'
            : '${formatMoney(-value.netExpense).replaceFirst('-', '−')} ${value.currency}';
    final income = privacyMode
        ? '••••'
        : value == null
            ? '—'
            : '${value.income.minorUnits > 0 ? "+" : ""}${formatMoney(value.income)} ${value.currency}';
    // Net = in − out, exact Money in the period's single currency.
    final net = value == null ? null : value.income - value.netExpense;
    final netText = privacyMode
        ? '••••'
        : net == null
            ? '—'
            : '${net.isNegative ? '−${formatMoney(-net)}' : '${net.minorUnits > 0 ? "+" : ""}${formatMoney(net)}'} ${value!.currency}';
    final netColor = privacyMode || net == null || net.isZero
        ? c.textPrimary
        : net.isNegative
            ? c.expense
            : c.income;
    return QirshSummaryCard(
      label: thisMonth
          ? context.l10n.txnV3NetThisMonth
          : context.l10n.txnV3NetThisPeriod,
      scopeLabel: periodLabel,
      onScopeTap: onPeriodTap,
      amount: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: AlignmentDirectional.centerStart,
        child: Text(
          netText,
          key: const ValueKey('activity-period-net'),
          maxLines: 1,
          textDirection: TextDirection.ltr,
          style: TextStyle(color: netColor),
        ),
      ),
      stats: [
        QirshSummaryStat(
          value: Text(expense,
              key: const ValueKey('activity-period-out'),
              textDirection: TextDirection.ltr,
              style: TextStyle(color: privacyMode ? null : c.expense)),
          label: context.l10n.cardOut,
        ),
        QirshSummaryStat(
          value: Text(income,
              key: const ValueKey('activity-period-in'),
              textDirection: TextDirection.ltr,
              style: TextStyle(color: privacyMode ? null : c.income)),
          label: context.l10n.cardIn,
        ),
      ],
    );
  }
}

/// The activity / bills section header: the SAME photo hero on both tabs —
/// large title, subtitle, small round search + add, and the one
/// Transactions | Bills control underneath.
class _TransactionsHeader extends StatelessWidget {
  const _TransactionsHeader({
    required this.subtitle,
    required this.tabs,
    required this.onSearch,
    required this.onAdd,
  });

  final String? subtitle;
  final Widget tabs;
  final VoidCallback onSearch;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    // Shared design-system header — edit CalmPageHeader once, every screen
    // that uses it updates.
    return CalmPageHeader(
      // شرائح متعددة: الأزرق ميمتدّش تحت (هيغطّي المحتوى) — الذوبان جوّه.
      meltOverflow: 0,
      sectionPhoto: QirshSectionPhoto.transactions,
      coverBottom: tabs,
      title: context.l10n.txnTabTransactions,
      subtitle: subtitle,
      leading: Navigator.of(context).canPop() ? const BackButton() : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HeroGlassAction(
            icon: AppLucideIcons.search,
            semanticLabel: context.l10n.txnSearchHint,
            onTap: onSearch,
          ),
          const SizedBox(width: AppSpacing.s2),
          _AddButton(onTap: onAdd),
        ],
      ),
      sectionHeight: 150,
    );
  }
}

/// Small round glass button for the photo hero (white glyph on a frosted
/// white tint), the secondary sibling of the primary «+».
class _HeroGlassAction extends StatelessWidget {
  const _HeroGlassAction({
    required this.icon,
    required this.onTap,
    required this.semanticLabel,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ClipOval(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Material(
            color: Colors.white.withValues(alpha: .14),
            shape: CircleBorder(
                side: BorderSide(color: Colors.white.withValues(alpha: .22))),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(
                width: 42,
                height: 42,
                child: Icon(icon, size: 20, color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Lays its child out at full height but reports [by] px less and paints it
/// [by] px higher — so a photo hero that follows the activity list's pinned
/// status band still starts at y = 0, under the clock.
class _PullUnder extends SingleChildRenderObjectWidget {
  const _PullUnder({required this.by, required Widget super.child});

  final double by;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPullUnder(by);

  @override
  void updateRenderObject(BuildContext context, _RenderPullUnder renderObject) {
    renderObject.by = by;
  }
}

class _RenderPullUnder extends RenderProxyBox {
  _RenderPullUnder(this._by);

  double _by;
  set by(double value) {
    if (value == _by) return;
    _by = value;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final child = this.child!;
    child.layout(constraints, parentUsesSize: true);
    size = constraints.constrain(Size(child.size.width,
        (child.size.height - _by).clamp(0.0, double.infinity)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    context.paintChild(child!, offset.translate(0, -_by));
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return result.addWithPaintOffset(
      offset: Offset(0, -_by),
      position: position,
      hitTest: (result, transformed) =>
          child!.hitTest(result, position: transformed),
    );
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    transform.translate(0.0, -_by);
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      (super.computeMinIntrinsicHeight(width) - _by).clamp(0.0, double.infinity);

  @override
  double computeMaxIntrinsicHeight(double width) =>
      (super.computeMaxIntrinsicHeight(width) - _by).clamp(0.0, double.infinity);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final size = child!.getDryLayout(constraints);
    return constraints.constrain(
        Size(size.width, (size.height - _by).clamp(0.0, double.infinity)));
  }
}

/// v2 sticky filter row: the chips pin under the status bar; while content
/// scrolls beneath them they sit on glass with a bottom hairline.
class _PinnedFilterBarDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedFilterBarDelegate(
      {required this.filtersOpen, required this.onFilter});

  /// The filter chip (end of the row) toggles the account / date panel.
  final bool filtersOpen;
  final VoidCallback onFilter;

  static const double _extent = 56;

  @override
  double get minExtent => _extent;

  @override
  double get maxExtent => _extent;

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    final c = context.colors;
    final pinned = overlapsContent || shrinkOffset > 0;
    final bar = Center(
        child: _FilterBar(filtersOpen: filtersOpen, onFilter: onFilter));
    if (!pinned) return ColoredBox(color: Colors.transparent, child: bar);
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: c.bg.withValues(alpha: .62),
            border: Border(
              bottom: BorderSide(color: c.border, width: .5),
            ),
          ),
          child: bar,
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant _PinnedFilterBarDelegate oldDelegate) =>
      oldDelegate.filtersOpen != filtersOpen ||
      oldDelegate.onFilter != onFilter;
}

/// Top inset of the immersive activity list that catches up with the status
/// band. The list's overlap injector covers only the chips; while the header
/// scrolls its last [statusTop] px the chips are already docked under the
/// status bar but the list keeps rising, so this grows 0 → [statusTop] in
/// step and the first row stays glued under the chips (no gap at rest, and
/// nothing hidden behind the glass once docked).
class _StatusBandCatchUp extends StatelessWidget {
  const _StatusBandCatchUp({required this.outer, required this.statusTop});

  final ScrollPosition? outer;
  final double statusTop;

  @override
  Widget build(BuildContext context) {
    final outer = this.outer;
    if (outer == null) return const SliverToBoxAdapter(child: SizedBox());
    return ListenableBuilder(
      listenable: outer,
      builder: (context, _) {
        final height = outer.hasContentDimensions && outer.hasPixels
            ? (statusTop - (outer.maxScrollExtent - outer.pixels))
                .clamp(0.0, statusTop)
            : 0.0;
        return SliverToBoxAdapter(child: SizedBox(height: height));
      },
    );
  }
}

// ─── Smart Inbox ─────────────────────────────────────────────────────────────

class _SmartInboxBanner extends ConsumerWidget {
  const _SmartInboxBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(smartInboxItemsProvider).valueOrNull ?? const [];
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _SmartInboxSheet.show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: c.cta.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.cta.withValues(alpha: 0.22)),
          ),
          child: Row(
            children: [
              Icon(AppLucideIcons.sparkles, size: 17, color: c.cta),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.txnSmartInboxCount(items.length),
                  style: AppTypography.caption(c.textMain)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              DirectionalChevron(size: 18, color: c.cta),
            ],
          ),
        ),
      ),
    );
  }
}

class _SmartInboxSheet extends ConsumerWidget {
  const _SmartInboxSheet();

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        backgroundColor: context.colors.surface,
        builder: (_) => navySheetTheme(Directionality(
          textDirection: Directionality.of(context),
          child: const _SmartInboxSheet(),
        )),
      );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final items = ref.watch(smartInboxItemsProvider).valueOrNull ?? const [];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.58,
      maxChildSize: 0.9,
      builder: (_, controller) => ListView.separated(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        itemCount: items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                context.l10n.txnSmartInbox,
                style: AppTypography.sectionTitle(context.colors.textMain),
              ),
            );
          }
          return SmartInboxCard(item: items[index - 1]);
        },
      ),
    );
  }
}

class _RetryInboxAnalysis extends ConsumerStatefulWidget {
  const _RetryInboxAnalysis({required this.item});
  final SmartInboxItemEntity item;

  @override
  ConsumerState<_RetryInboxAnalysis> createState() => _RetryInboxAnalysisState();
}

class _RetryInboxAnalysisState extends ConsumerState<_RetryInboxAnalysis> {
  bool _running = false;

  Future<void> _retry() async {
    final item = widget.item;
    final authority = AppSession.instance.captureLocalWorkAuthority();
    if (_running || authority == null || item.body == null) return;
    setState(() => _running = true);
    try {
      final result = await ref.read(ingestCapturedMessageUseCaseProvider)
          .fromCapturedMessage(CapturedMessage(
            text: item.body!,
            source: CapturedMessageSource.manualPaste,
            receivedAt: item.createdAt,
          ));
      if (!mounted || !authority.isCurrent) return;
      if (result.transactionId != null) {
        await ref.read(smartInboxRepositoryProvider).resolve(item.id);
        if (!mounted) return;
        ref.invalidate(smartInboxItemsProvider);
      } else {
        showTopInfo(context, context.l10n.pasteSavedForAnalysis);
      }
    } catch (_) {
      if (mounted && authority.isCurrent) {
        showTopInfo(context, context.l10n.pasteSavedForAnalysis);
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: _running ? null : _retry,
    child: Text(_running ? context.l10n.pasteAnalyse : context.l10n.retryBankAnalysis),
  );
}

class SmartInboxCard extends ConsumerWidget {
  const SmartInboxCard({super.key, required this.item});
  final SmartInboxItemEntity item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    // Unprocessable captures are saved by DriftSmartInboxRepository
    // .saveUnprocessableCapture with the deterministic `local_capture:` id and
    // no transaction.
    final isUnprocessable =
        item.id.startsWith('local_capture:') && item.transactionId == null;
    final settings = ref.watch(userSettingsProvider).valueOrNull;
    final smartAnalysisOn = settings != null &&
        ConsentAuthority.decide(EgressClass.aiProcessing, settings);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, style: AppTypography.bodyStrong(c.textMain)),
          if (item.body?.isNotEmpty == true) ...[
            const SizedBox(height: 5),
            Text(item.body!, style: AppTypography.caption(c.textMuted)),
          ],
          if (isUnprocessable) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: () async {
                    final saved = await ManualTransactionSheet.show(context);
                    if (!saved) return;
                    await ref
                        .read(smartInboxRepositoryProvider)
                        .resolve(item.id);
                    ref.invalidate(smartInboxItemsProvider);
                  },
                  child: Text(context.l10n.cesManualEntry),
                ),
                if (smartAnalysisOn && item.body?.isNotEmpty == true)
                  _RetryInboxAnalysis(item: item),
                if (settings != null && !smartAnalysisOn)
                  TextButton(
                    onPressed: () =>
                        showSmartAnalysisConsentSheet(context, ref),
                    child: Text(context.l10n.smartConsentEnable),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (item.transactionId != null)
                TextButton(
                  onPressed: () => TransactionDetailsScreen.showSheet(
                    context,
                    item.transactionId!,
                  ),
                  child: Text(context.l10n.txnReviewTx),
                ),
              const Spacer(),
              IconButton(
                tooltip: context.l10n.txnHide,
                icon: const Icon(AppLucideIcons.x),
                onPressed: () async {
                  await ref.read(smartInboxRepositoryProvider).dismiss(item.id);
                  ref.invalidate(smartInboxItemsProvider);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Suspected Duplicates ────────────────────────────────────────────────────

class _SuspectedDuplicatesBanner extends ConsumerWidget {
  const _SuspectedDuplicatesBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dupes = ref.watch(suspectedDuplicatesProvider).valueOrNull ?? [];
    if (dupes.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s3),
      child: GestureDetector(
        onTap: () => _SuspectedDuplicatesSheet.show(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: c.accent.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: c.accent.withValues(alpha: 0.28)),
          ),
          child: Row(
            children: [
              Icon(AppLucideIcons.copy, size: 16, color: c.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  context.l10n.txnDupBannerReview(dupes.length),
                  style: AppTypography.caption(c.accent)
                      .copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              DirectionalChevron(size: 16, color: c.accent),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showSuspectedDuplicateReviewSheet(
    BuildContext context, SuspectedDuplicateEntity dupe) {
  return showGlassSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => navySheetTheme(Directionality(
      textDirection: Directionality.of(context),
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
          child: _SuspectedDuplicateCard(dupe: dupe),
        ),
      ),
    )),
  );
}

class _SuspectedDuplicatesSheet extends ConsumerWidget {
  const _SuspectedDuplicatesSheet();

  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: context.colors.surface,
      builder: (_) => navySheetTheme(Directionality(
        textDirection: Directionality.of(context),
        child: const _SuspectedDuplicatesSheet(),
      )),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final dupes = ref.watch(suspectedDuplicatesProvider).valueOrNull ?? [];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.92,
      builder: (_, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(context.l10n.txnSuspectTxPlural,
                      style: AppTypography.sectionTitle(c.textMain)),
                ),
                // NEW (Phase J §13) — «تجاهل الكل» dismissed the ENTIRE review
                // queue on one tap: no count, no confirmation, no undo. It is
                // the same shape as UX-027 and F-017 — the most destructive
                // action being the easiest to reach — and it is worse here
                // because it is a bulk action whose size the user cannot see
                // from the button.
                //
                // It discards duplicate FLAGS rather than transactions, so no
                // money is lost; what is lost is the queue that would have
                // caught a genuine double charge. The confirmation states the
                // count and what dismissing actually means.
                TextButton(
                  onPressed: () async {
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => GlassAlertDialog(
                        title: Text(ctx.l10n.txnDismissNAlerts(dupes.length)),
                        content: Text(ctx.l10n.txnDismissAllDupesBody),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(false),
                            child: Text(context.l10n.commonCancel),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(ctx).pop(true),
                            child: Text(context.l10n.txnDismissAll,
                                style: TextStyle(color: ctx.colors.danger)),
                          ),
                        ],
                      ),
                    );
                    if (proceed != true) return;
                    final repo = ref.read(suspectedDuplicateRepositoryProvider);
                    for (final d in dupes) {
                      await repo.delete(d.id);
                    }
                    ref.invalidate(suspectedDuplicatesProvider);
                    if (context.mounted) Navigator.of(context).pop();
                  },
                  child: Text(context.l10n.txnDismissAllCount(dupes.length),
                      style: AppTypography.caption(c.textMuted)),
                ),
              ],
            ),
          ),
          Expanded(
            child: dupes.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const QirshIllustration(
                            name: 'emptyTx', width: 150, height: 112.5),
                        const SizedBox(height: AppSpacing.s3),
                        Text(context.l10n.txnNoSuspectTx,
                            textAlign: TextAlign.center,
                            style: AppTypography.body(c.textMuted)),
                      ],
                    ),
                  )
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                    itemCount: dupes.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.s3),
                    itemBuilder: (_, i) =>
                        _SuspectedDuplicateCard(dupe: dupes[i]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _SuspectedDuplicateCard extends ConsumerWidget {
  const _SuspectedDuplicateCard({required this.dupe});

  final SuspectedDuplicateEntity dupe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final existingAsync = ref.watch(transactionByIdProvider(
      dupe.existingTransactionId,
    ));
    final existing = existingAsync.valueOrNull;
    final timestamp = dupe.comparisonTimestamp ?? dupe.occurredAt;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.s4),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (MediaQuery.textScalerOf(context).scale(16) > 20) ...[
            Row(
              children: [
                Icon(AppLucideIcons.copy, size: 18, color: c.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.txnSimilarExists,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Text(
                '${Formatters.amount(dupe.amount)} ${dupe.currency}',
                style: AppTypography.bodyStrong(c.textMain),
              ),
            ),
          ] else
            Row(
              children: [
                Icon(AppLucideIcons.copy, size: 18, color: c.warning),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    context.l10n.txnSimilarExists,
                    style: AppTypography.bodyStrong(c.textMain),
                  ),
                ),
                Text(
                  '${Formatters.amount(dupe.amount)} ${dupe.currency}',
                  style: AppTypography.bodyStrong(c.textMain),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Text(
            context.l10n.txnSimilarBody,
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s3),
          _DuplicateInfoRow(
            label: context.l10n.txnTheNew,
            merchant: dupe.rawMerchant ?? context.l10n.txnNoClearMerchant,
            amount: '${Formatters.amount(dupe.amount)} ${dupe.currency}',
            time:
                '${Formatters.dateWithWeekday(timestamp, context)} · ${Formatters.time(timestamp, context)}',
          ),
          if (existing != null) ...[
            const SizedBox(height: AppSpacing.s2),
            _DuplicateInfoRow(
              label: context.l10n.txnTheExisting,
              merchant: existing.rawMerchant ?? context.l10n.txnNoClearMerchant,
              amount:
                  '${Formatters.amount(existing.amount)} ${existing.currency}',
              time:
                  '${Formatters.dateWithWeekday(existing.comparisonTimestamp ?? existing.occurredAt, context)} · ${Formatters.time(existing.comparisonTimestamp ?? existing.occurredAt, context)}',
            ),
          ],
          const SizedBox(height: AppSpacing.s2),
          Text(
            context.l10n.txnTimeSource(
                _timestampSourceLabel(context, dupe.comparisonTimestampSource)),
            style: AppTypography.caption(c.textMuted),
          ),
          const SizedBox(height: AppSpacing.s3),
          if (MediaQuery.textScalerOf(context).scale(16) > 20) ...[
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: () => _dismiss(ref),
                style: OutlinedButton.styleFrom(
                  foregroundColor: c.textMuted,
                  side: BorderSide(color: c.border.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(context.l10n.txnDismissDuplicate),
              ),
            ),
            const SizedBox(height: AppSpacing.s3),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => _confirmAsReal(context, ref),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
                child: Text(context.l10n.txnSaveAsNew),
              ),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _dismiss(ref),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textMuted,
                      side: BorderSide(color: c.border.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(context.l10n.txnDismissDuplicate),
                  ),
                ),
                const SizedBox(width: AppSpacing.s3),
                Expanded(
                  child: FilledButton(
                    onPressed: () => _confirmAsReal(context, ref),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: Text(context.l10n.txnSaveAsNew),
                  ),
                ),
              ],
            ),
          const SizedBox(height: AppSpacing.s2),
          if (MediaQuery.textScalerOf(context).scale(16) > 20) ...[
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: existing == null
                    ? null
                    : () => _editExisting(context, ref, existing),
                icon: const Icon(AppLucideIcons.pencil, size: 16),
                label: Text(context.l10n.txnEditTx),
              ),
            ),
            const SizedBox(height: AppSpacing.s2),
            SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: existing == null
                    ? null
                    : () => _changeCategory(context, ref, existing),
                icon: const Icon(AppLucideIcons.shapes, size: 16),
                label: Text(context.l10n.txnChangeCategory),
              ),
            ),
          ] else
            Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: existing == null
                        ? null
                        : () => _editExisting(context, ref, existing),
                    icon: const Icon(AppLucideIcons.pencil, size: 16),
                    label: Text(context.l10n.txnEditTx),
                  ),
                ),
                const SizedBox(width: AppSpacing.s2),
                Expanded(
                  child: TextButton.icon(
                    onPressed: existing == null
                        ? null
                        : () => _changeCategory(context, ref, existing),
                    icon: const Icon(AppLucideIcons.shapes, size: 16),
                    label: Text(context.l10n.txnChangeCategory),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _timestampSourceLabel(
      BuildContext context, ComparisonTimestampSource? source) {
    return source == ComparisonTimestampSource.smsBody
        ? context.l10n.txnTimeInSms
        : context.l10n.txnTimeReceived;
  }

  Future<void> _dismiss(WidgetRef ref) async {
    await ref.read(suspectedDuplicateRepositoryProvider).delete(dupe.id);
    ref.invalidate(suspectedDuplicatesProvider);
  }

  Future<void> _confirmAsReal(BuildContext context, WidgetRef ref) async {
    final addUseCase = ref.read(addTransactionUseCaseProvider);
    final result = await addUseCase(
      rawMessage: dupe.rawMessage,
      senderId: dupe.senderId,
      skipDedup: true,
      smsReceivedAt:
          dupe.comparisonTimestampSource == ComparisonTimestampSource.receivedAt
              ? dupe.comparisonTimestamp ?? dupe.occurredAt
              : null,
    );
    await ref.read(suspectedDuplicateRepositoryProvider).delete(dupe.id);
    ref.invalidate(suspectedDuplicatesProvider);
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
    if (context.mounted && result.transaction != null) {
      await TransactionDetailsScreen.showSheet(context, result.transaction!.id);
    }
  }

  Future<void> _editExisting(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity existing,
  ) async {
    await ManualTransactionSheet.show(context, transaction: existing);
    ref.invalidate(transactionByIdProvider(existing.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }

  Future<void> _changeCategory(
    BuildContext context,
    WidgetRef ref,
    TransactionEntity existing,
  ) async {
    final catalog = await ref.read(categoryCatalogProvider.future);
    if (!context.mounted) return;
    await showChangeCategorySheet(context, existing, catalog);
    ref.invalidate(transactionByIdProvider(existing.id));
    refreshTransactions(ref);
    ref.invalidate(dashboardDataProvider);
  }
}

class _DuplicateInfoRow extends StatelessWidget {
  const _DuplicateInfoRow({
    required this.label,
    required this.merchant,
    required this.amount,
    required this.time,
  });

  final String label;
  final String merchant;
  final String amount;
  final String time;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.s3),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: c.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppTypography.caption(c.textMuted)),
          const SizedBox(height: 2),
          Row(
            children: [
              Expanded(
                child: Text(
                  merchant,
                  style: AppTypography.bodyStrong(c.textMain),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: AppSpacing.s2),
              Text(amount, style: AppTypography.bodyStrong(c.textMain)),
            ],
          ),
          const SizedBox(height: 2),
          Text(time, style: AppTypography.caption(c.textMuted)),
        ],
      ),
    );
  }
}
