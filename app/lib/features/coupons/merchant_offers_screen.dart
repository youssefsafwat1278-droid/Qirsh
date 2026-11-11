import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/calm_page_header.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/app_lucide_icons.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/widgets.dart';
import 'coupon_models.dart';
import 'coupon_widgets.dart';
import 'coupons_providers.dart';

/// COUPONS Phase 1 — every live offer for one canonical merchant.
///
/// Reads only from the local cache, like the Offers screen. The merchant id in
/// the route is a CATALOG id, not the device-local `merchants.id`: local ids are
/// normalization-derived and differ between users, so one could never be shared
/// in a link or a notification.
///
/// A direct open is always safe. If the flag is off, the merchant is unknown, or
/// it has no live offers, the screen resolves to a calm empty state — it never
/// invents content and never errors at the user.
class MerchantOffersScreen extends ConsumerWidget {
  const MerchantOffersScreen({super.key, required this.merchantId});

  final String merchantId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final c = context.colors;
    final english = Localizations.localeOf(context).languageCode == 'en';

    final merchants = ref.watch(catalogMerchantsProvider).valueOrNull;
    final grouped = ref.watch(couponsByMerchantProvider);
    final merchant = merchants?[merchantId];

    // The merchant's own name when the catalog knows it. Falling back to the
    // offer's partner_name rather than showing an id keeps the page readable
    // even if the merchant row is mid-sync.
    final title = merchant == null
        ? null
        : (english && (merchant.nameEn?.trim().isNotEmpty ?? false)
            ? merchant.nameEn!
            : merchant.nameAr);

    // Immersive: the header scrolls with the content, which fills from y = 0
    // under the status bar (kept legible by the scrim).
    final topInset = MediaQuery.paddingOf(context).top;
    final headerRow = Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title == null
                        ? l10n.couponsStoresSection
                        : l10n.couponsMerchantOffers(title),
                    style: AppTypography.calmTitle(c.textPrimary)
                        .copyWith(fontSize: 22, letterSpacing: -0.5),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => Navigator.of(context).maybePop(),
              icon: const Icon(AppLucideIcons.x),
            ),
          ],
        );
    // Non-list states: the header leads, the state fills the rest.
    Widget withHeader(Widget state) => CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.only(top: topInset),
              sliver: SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.gutter,
                    AppSpacing.s3,
                    AppSpacing.gutter,
                    AppSpacing.s2,
                  ),
                  child: headerRow,
                ),
              ),
            ),
            SliverFillRemaining(hasScrollBody: false, child: state),
          ],
        );

    return AppScreenScaffold(
      safeArea: false,
      body: StatusBarScrim(
        child: grouped.when(
        skipLoadingOnReload: true,
        loading: () =>
            withHeader(AppLoadingState(label: l10n.couponsLoading)),
        error: (_, __) => withHeader(AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(cachedCouponsProvider),
        )),
        data: (byMerchant) {
          final offers = byMerchant[merchantId] ?? const <CouponOffer>[];
          if (offers.isEmpty) {
            return withHeader(AppEmptyState(
              icon: AppLucideIcons.tag,
              illustration: const QirshIllustration(
                  name: 'offers', width: 220, height: 165),
              title: l10n.couponsMerchantEmptyTitle,
              subtitle: l10n.couponsMerchantEmptyBody,
            ));
          }
          return ListView.separated(
            padding: EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              topInset,
              AppSpacing.gutter,
              AppSpacing.s6,
            ),
            // Item 0 is the header; it scrolls away with the offers.
            itemCount: offers.length + 1,
            separatorBuilder: (_, i) => i == 0
                ? const SizedBox.shrink()
                : const SizedBox(height: AppSpacing.s3),
            itemBuilder: (context, i) => i == 0
                ? Padding(
                    padding: const EdgeInsets.only(
                      top: AppSpacing.s3,
                      bottom: AppSpacing.s2 + AppSpacing.s2,
                    ),
                    child: headerRow,
                  )
                : CouponCard(offer: offers[i - 1]),
          );
        },
        ),
      ),
    );
  }
}
