import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../common/app_header.dart';
import '../common/app_avatar.dart';
import '../../core/theme/widgets/qirsh_visuals.dart';
import '../../core/utils/l10n_ext.dart';
import '../common/widgets.dart';
import 'coupon_models.dart';
import 'coupon_widgets.dart';
import 'coupons_providers.dart';
import '../../core/utils/app_lucide_icons.dart';

/// MALI-COUPONS (Phase C4) — the Offers screen, backed by the real catalog.
///
/// Reads ONLY from the local cache (architecture rule 1); the network is the
/// catalog sync's job. When the feature flag is off it resolves to a calm empty
/// state instead of promotional UI, so a direct route open is always safe.
class CouponsScreen extends ConsumerStatefulWidget {
  const CouponsScreen({super.key, this.highlightSlug});

  /// `/coupons?highlight={slug}` — focuses one offer if it is ELIGIBLE.
  /// An unknown, expired or country-ineligible slug simply shows the normal
  /// screen: the deep route can never bypass eligibility.
  final String? highlightSlug;

  @override
  ConsumerState<CouponsScreen> createState() => _CouponsScreenState();
}

class _CouponsScreenState extends ConsumerState<CouponsScreen> {
  String? _categoryKey;
  String? _tagKey;
  bool _highlightHandled = false;

  void _maybeOpenHighlight(List<CouponOffer> offers) {
    final slug = widget.highlightSlug;
    if (_highlightHandled || slug == null || slug.isEmpty) return;
    _highlightHandled = true;
    // Only an ELIGIBLE offer can be highlighted — `offers` is already filtered.
    final match = offers.where((o) => o.slug == slug).firstOrNull;
    if (match == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) showCouponDetailsSheet(context, ref, match);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final c = context.colors;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final coupons = ref.watch(couponsProvider);
    final categories =
        ref.watch(couponCategoriesProvider).valueOrNull ?? const [];
    final tags = ref.watch(couponTagsProvider).valueOrNull ?? const [];

    return AppScreenScaffold(
      header: AppHeader(title: l10n.couponsTitle),
      body: coupons.when(
        skipLoadingOnReload: true,
        loading: () => AppLoadingState(label: l10n.couponsLoading),
        error: (_, __) => AppErrorState(
          title: l10n.couponsErrorTitle,
          description: l10n.couponsErrorBody,
          retryLabel: l10n.couponsRetry,
          onRetry: () => ref.invalidate(cachedCouponsProvider),
        ),
        data: (offers) {
          _maybeOpenHighlight(offers);
          if (offers.isEmpty) {
            return AppEmptyState(
              icon: AppLucideIcons.tag,
              illustration: const QirshIllustration(
                  name: 'offers', width: 220, height: 165),
              title: l10n.couponsEmptyTitle,
              subtitle: l10n.couponsEmptyBody,
            );
          }

          final filtered = offers.where((o) {
            if (_categoryKey != null && o.category.key != _categoryKey) {
              return false;
            }
            if (_tagKey != null && !o.tags.any((t) => t.key == _tagKey)) {
              return false;
            }
            return true;
          }).toList(growable: false);

          final featured =
              filtered.where((o) => o.featured).toList(growable: false);
          final rest =
              filtered.where((o) => !o.featured).toList(growable: false);

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.gutter,
              AppSpacing.s2,
              AppSpacing.gutter,
              120,
            ),
            children: [
              Container(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 6, 6),
                decoration: BoxDecoration(color: c.ctaSoft, borderRadius: BorderRadius.circular(24)),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l10n.couponsAvailableLabel,
                      style: AppTypography.caption(c.textMuted)),
                    const SizedBox(height: 4),
                    Text('${offers.length}', textDirection: TextDirection.ltr,
                      style: AppTypography.custom(size: 28, weight: FontWeight.w700, height: 1.3, color: c.textPrimary)),
                  ])),
                  const QirshIllustration(name: 'offers', width: 128, height: 96),
                ]),
              ),
              const SizedBox(height: 10),
              Text(l10n.couponsSubtitle,
                  style: AppTypography.caption(c.textMuted)),
              const SizedBox(height: AppSpacing.s3),
              // COUPONS Phase 1 — merchant surfaces, ABOVE the filters.
              //
              // Both render nothing unless there is something real to show:
              // For You is empty when personalization is off or no merchant
              // clears the threshold, and Stores is empty when no live offer is
              // linked to a merchant. So a user who never opts in sees exactly
              // the screen they saw before.
              //
              // They also sit outside the category/tag filter deliberately —
              // filtering "places you shop" by a tag would produce a section
              // that is personal AND arbitrary, which reads as a bug.
              const _ForYouSection(),
              const _StoresSection(),
              _FilterRow(
                label: l10n.couponsFilterAll,
                selectedCategory: _categoryKey,
                selectedTag: _tagKey,
                categories: categories,
                tags: tags,
                english: english,
                onCategory: (key) => setState(() => _categoryKey = key),
                onTag: (key) => setState(() => _tagKey = key),
              ),
              const SizedBox(height: AppSpacing.s3),
              if (filtered.isEmpty)
                AppEmptyState(
                  icon: AppLucideIcons.filterX,
                  illustration: const QirshIllustration(
                      name: 'offers', width: 160, height: 120),
                  title: l10n.couponsFilterEmptyTitle,
                  subtitle: l10n.couponsFilterEmptyBody,
                )
              else ...[
                if (featured.isNotEmpty) ...[
                  Text(
                    l10n.couponsFeaturedSection,
                    style: AppTypography.caption(c.textMuted)
                        .copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: AppSpacing.s2),
                  for (final offer in featured) ...[
                    CouponCard(
                      offer: offer,
                      highlighted: offer.slug == widget.highlightSlug,
                    ),
                    const SizedBox(height: AppSpacing.s3),
                  ],
                ],
                for (final offer in rest) ...[
                  CouponCard(
                    offer: offer,
                    highlighted: offer.slug == widget.highlightSlug,
                  ),
                  const SizedBox(height: AppSpacing.s3),
                ],
              ],
            ],
          );
        },
      ),
    );
  }
}

/// Offers at merchants the user actually shops at.
///
/// The subtitle states WHERE the matching happened, because the honest answer
/// is the reassuring one: a user seeing their own shops listed should be told
/// immediately that this was worked out on their phone and sent nowhere.
class _ForYouSection extends ConsumerWidget {
  const _ForYouSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    final offers = ref.watch(forYouCouponsProvider).valueOrNull ?? const [];
    if (offers.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.couponsForYouSection,
          style: AppTypography.caption(c.textMuted)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.couponsForYouSubtitle,
          style: AppTypography.caption(c.textMuted).copyWith(fontSize: 11),
        ),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: offers.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.s3),
            itemBuilder: (context, i) =>
                CouponCard(offer: offers[i], compact: true),
          ),
        ),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }
}

/// Merchants that have at least one LIVE offer.
///
/// Derived from the offers themselves rather than from the merchant catalog, so
/// the list can never advertise a shop with nothing to show — tapping through
/// to an empty page is a worse experience than not offering the tap.
class _StoresSection extends ConsumerWidget {
  const _StoresSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final l10n = context.l10n;
    final english = Localizations.localeOf(context).languageCode == 'en';
    final grouped = ref.watch(couponsByMerchantProvider).valueOrNull ?? const {};
    final merchants = ref.watch(catalogMerchantsProvider).valueOrNull ?? const {};
    if (grouped.isEmpty) return const SizedBox.shrink();

    // Deterministic order, and only merchants the catalog can actually name —
    // a chip labelled with a UUID would be worse than no chip.
    final entries = grouped.keys
        .where(merchants.containsKey)
        .map((id) => MapEntry(id, merchants[id]!))
        .toList()
      ..sort((a, b) => a.value.slug.compareTo(b.value.slug));
    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.couponsStoresSection,
          style: AppTypography.caption(c.textMuted)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.s2),
        SizedBox(height: 112,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: entries.length,
            separatorBuilder: (_, index) => const SizedBox(width: 10),
            itemBuilder: (context, index) {
              final entry = entries[index];
              final merchant = entry.value;
              final label = english && (merchant.nameEn?.trim().isNotEmpty ?? false)
                  ? merchant.nameEn! : merchant.nameAr;
              return SizedBox(width: 118,
                child: Material(color: c.surface, borderRadius: BorderRadius.circular(18),
                  child: InkWell(borderRadius: BorderRadius.circular(18),
                    onTap: () => context.push('/coupons/merchant/${entry.key}'),
                    child: Padding(padding: const EdgeInsets.all(10),
                      child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        AppAvatar.brand(name: merchant.nameEn ?? merchant.slug, size: 36),
                        const SizedBox(height: 8),
                        Text(label, textAlign: TextAlign.center, maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption(c.textPrimary)),
                      ])),
                  ),
                ));
            },
          )),
        const SizedBox(height: AppSpacing.s4),
      ],
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.label,
    required this.selectedCategory,
    required this.selectedTag,
    required this.categories,
    required this.tags,
    required this.english,
    required this.onCategory,
    required this.onTag,
  });

  final String label;
  final String? selectedCategory;
  final String? selectedTag;
  final List<CouponCategory> categories;
  final List<CouponTag> tags;
  final bool english;
  final ValueChanged<String?> onCategory;
  final ValueChanged<String?> onTag;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 36,
      child: ListView(
        scrollDirection: Axis.horizontal,
        children: [
          _Chip(
            label: label,
            selected: selectedCategory == null && selectedTag == null,
            onTap: () {
              onCategory(null);
              onTag(null);
            },
          ),
          for (final category in categories)
            _Chip(
              label: category.label(preferEnglish: english),
              selected: selectedCategory == category.key,
              onTap: () {
                onTag(null);
                onCategory(
                    selectedCategory == category.key ? null : category.key);
              },
            ),
          for (final tag in tags.take(8))
            _Chip(
              label: '#${tag.label(preferEnglish: english)}',
              selected: selectedTag == tag.key,
              onTap: () {
                onCategory(null);
                onTag(selectedTag == tag.key ? null : tag.key);
              },
            ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip(
      {required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: selected ? c.cta : c.surfaceCard,
              borderRadius: BorderRadius.circular(AppRadius.pill),
              border: Border.all(color: selected ? c.cta : c.border),
            ),
            child: Text(
              label,
              style: AppTypography.caption(selected ? c.onCta : c.textSecondary)
                  .copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}
