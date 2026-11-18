import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/ads/admob_build_config.dart';
import 'package:money_companion/features/ads/ad_placement.dart';
import 'package:money_companion/features/ads/banner_ads_providers.dart';
import 'package:money_companion/features/ads/report_banner_suppression.dart';
import 'package:money_companion/features/report_ads/report_entitlement.dart';

/// THE COOLDOWN HAS TO END FOR A LISTENER THAT IS ALREADY LISTENING.
///
/// Every test in this file uses ONE container and ONE subscription for its
/// whole life. That is the entire point: the earlier expiry test built a fresh
/// container after advancing a fake clock, which only ever proved that a NEW
/// subscription computes the right answer. It could not have caught the actual
/// defect, which is that an EXISTING one never recomputes.
///
/// `bannerEligibilityProvider` read `ReportBannerSuppression.active` as a plain
/// static. A `false` taken during the cooldown was then held for as long as
/// anything kept listening, so the Reports banner stayed gone long past the
/// window — until something unrelated happened to invalidate the provider. A
/// banner that never comes back is the same bug as one that never leaves, just
/// quieter.

ProviderContainer _container() {
  final container = ProviderContainer(overrides: [
    for (final p in AdPlacement.values)
      bannerPlacementEnabledProvider(p).overrideWithValue(true),
    bannerEntitlementProvider
        .overrideWith((ref) async => ReportEntitlementState.verifiedInactive),
    bannerConsentProvider.overrideWith((ref) async => true),
  ]);
  addTearDown(container.dispose);
  return container;
}

/// Keeps a live subscription open and records every value it is handed.
///
/// `listen` with `fireImmediately` is what makes this a real subscriber: the
/// provider stays alive between reads, which is the condition the defect needs.
List<bool?> _watch(ProviderContainer container, AdPlacement placement) {
  final seen = <bool?>[];
  container.listen<AsyncValue<bool>>(
    bannerEligibilityProvider(placement),
    (_, next) => seen.add(next.valueOrNull),
    fireImmediately: true,
  );
  return seen;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  // Decision 3.2: advertising is compiled out of Version 1 builds. These tests
  // exercise the ad pipeline itself, as a build made with
  // --dart-define=QIRSH_ADS_ENABLED=true runs it. The compiled-out behaviour
  // is covered by test/features/ads/v1_ads_compiled_out_test.dart.
  setUp(() => AdMobBuildConfig.debugAdsCompiledInOverride = true);
  tearDown(() => AdMobBuildConfig.debugAdsCompiledInOverride = false);
  setUp(ReportBannerSuppression.resetForTest);
  tearDown(ReportBannerSuppression.resetForTest);

  test('a live subscription sees the cooldown END on its own', () async {
    // A real window, just a short one. The expiry is delivered by a timer, so
    // it has to be crossed for real rather than by moving a fake clock.
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 120);

    final container = _container();
    final seen = _watch(container, AdPlacement.reports);
    await _settle();
    expect(seen.last, isTrue, reason: 'nothing is suppressing anything yet');

    ReportBannerSuppression.markAdShown();
    await _settle();
    expect(seen.last, isFalse, reason: 'the interstitial was just shown');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _settle();

    expect(seen.last, isTrue,
        reason: 'the window closed and the SAME subscription was told');
  });

  test('a live subscription sees a journey begin and end', () async {
    final container = _container();
    final seen = _watch(container, AdPlacement.reports);
    await _settle();
    expect(seen.last, isTrue);

    ReportBannerSuppression.beginJourney();
    await _settle();
    expect(seen.last, isFalse);

    ReportBannerSuppression.endJourney();
    await _settle();
    expect(seen.last, isTrue, reason: 'no ad was shown, so no cooldown follows');
  });

  test('a journey that ends WITH an ad shown hands over to the cooldown',
      () async {
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 120);

    final container = _container();
    final seen = _watch(container, AdPlacement.reports);
    await _settle();

    ReportBannerSuppression.beginJourney();
    ReportBannerSuppression.markAdShown();
    ReportBannerSuppression.endJourney();
    await _settle();
    expect(seen.last, isFalse,
        reason: 'the journey is over but the cooldown is not');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _settle();
    expect(seen.last, isTrue);
  });

  test('a second ad restarts the window rather than extending the first',
      () async {
    // Two exports in a row must not leave a listener waiting on a stale timer.
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 150);

    final container = _container();
    final seen = _watch(container, AdPlacement.reports);
    await _settle();

    ReportBannerSuppression.markAdShown();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    ReportBannerSuppression.markAdShown();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await _settle();
    expect(seen.last, isFalse,
        reason: 'the first timer must not close a window the second reopened');

    await Future<void>.delayed(const Duration(milliseconds: 120));
    await _settle();
    expect(seen.last, isTrue);
  });

  test('a live subscription on ANOTHER placement is never disturbed', () async {
    // Reports is the only surface with two formats. Suppression leaking would
    // cost every other placement its ad for two minutes, silently.
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 120);

    final container = _container();
    final goals = _watch(container, AdPlacement.goals);
    await _settle();
    // `fireImmediately` hands over the loading state first, whose value is
    // null. Only the settled answers are the subject here.
    List<bool?> settled() => goals.where((v) => v != null).toList();
    final before = settled().length;
    expect(before, greaterThan(0));

    ReportBannerSuppression.beginJourney();
    ReportBannerSuppression.markAdShown();
    ReportBannerSuppression.endJourney();
    await _settle();

    expect(settled().every((v) => v == true), isTrue,
        reason: 'goals stayed eligible throughout');
    expect(settled().length, before,
        reason: 'and was not even recomputed — it does not watch suppression');
  });

  test('no timer is left running after the window closes', () async {
    // A leaked periodic timer would be a battery cost for a feature that is off
    // by default. There is one timer, it is one-shot, and it is cancelled and
    // replaced rather than stacked.
    ReportBannerSuppression.cooldown = const Duration(milliseconds: 50);
    ReportBannerSuppression.markAdShown();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(ReportBannerSuppression.inCooldown, isFalse);
    expect(ReportBannerSuppression.active, isFalse);
  });
}
