import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture guards for the report-export ads layer (R4 §31). Static source
/// scans — they assert the boundaries the design forbids, and fail loudly if a
/// later change crosses one.

String _read(String path) => File(path).readAsStringSync();

/// BOTH ads directories. `features/ads` holds the shared layer (build config,
/// SDK init, placements, banners); `features/report_ads` holds what is specific
/// to the report-export interstitial. Every invariant below applies to both — a
/// guard that only covered the old directory would have silently stopped
/// guarding the moment the banner work moved the config out of it.
const _adsLayerDirs = ['lib/features/ads', 'lib/features/report_ads'];

List<File> _adsLayerFiles() => [
      for (final d in _adsLayerDirs)
        ...Directory(d)
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart')),
    ];

List<String> _adsLayerSources() =>
    _adsLayerFiles().map((f) => f.readAsStringSync()).toList();

/// The `enum AdPlacement { … }` body, as source text.
String _placementEnumBody() {
  final src = File('lib/features/ads/ad_placement.dart').readAsStringSync();
  return src.substring(src.indexOf('enum AdPlacement {'));
}

/// The declared enum value identifiers. Two-space indent is what distinguishes
/// a value from anything nested deeper in the body.
Set<String> _placementNames() =>
    RegExp(r'^\s{2}([a-z][A-Za-z0-9]*)\(', multiLine: true)
        .allMatches(_placementEnumBody())
        .map((m) => m.group(1)!)
        .toSet();

Iterable<File> _allLibDart() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('no rewarded-ad concepts anywhere in the ads layer', () {
    for (final src in _adsLayerSources()) {
      expect(src.contains('RewardedAd'), isFalse, reason: 'no RewardedAd');
      expect(src.contains('RewardedInterstitialAd'), isFalse,
          reason: 'no RewardedInterstitialAd');
      expect(src.contains('OnUserEarnedReward'), isFalse,
          reason: 'no OnUserEarnedReward');
      expect(src.contains('onUserEarnedReward'), isFalse);
    }
  });

  test('no rewarded-ad concepts anywhere in lib', () {
    for (final f in _allLibDart()) {
      final src = f.readAsStringSync();
      expect(src.contains('RewardedInterstitialAd'), isFalse, reason: f.path);
      expect(src.contains('OnUserEarnedReward'), isFalse, reason: f.path);
    }
  });

  test('no Qirsh-owned adConsentState (UMP is the sole authority)', () {
    for (final f in _allLibDart()) {
      expect(f.readAsStringSync().contains('adConsentState'), isFalse,
          reason: 'adConsentState found in ${f.path}');
    }
  });

  test('no report_ads_config table/symbol in the client', () {
    for (final f in _allLibDart()) {
      expect(f.readAsStringSync().contains('report_ads_config'), isFalse,
          reason: 'report_ads_config found in ${f.path}');
    }
  });

  test('R4 contributes no schema change', () {
    // The guard's intent is that the ADS track introduces no migration — it
    // was originally written as a global pin to v31, which over-reached once
    // another track legitimately bumped the version.
    //
    // v34 is owned by COUPONS Phase 1 (the merchant catalog cache); v32/v33 by
    // PHASE 8/9A; v36/v37 by PHASE 11 (proof shadow store + its attribution key); v39 by WP-3a (replica_meta); v40 by WP-6 (consent versions); v41 by WP-5 (sync_conflicts + outbox CAS columns). Each is an
    // approved and separately gated change. So the version pin now tracks the
    // current approved value, and the R4-specific claim is asserted directly
    // below, where it belongs.
    final db = _read('lib/data/db/app_database.dart');
    expect(RegExp(r'_targetSchemaVersion\s*=\s*43').hasMatch(db), isTrue,
        reason: 'unexpected schema version — a bump must be an approved, '
            'separately gated change');
  });

  test('the ads layer contains no schema or migration code', () {
    // This is what "no v32 for R4" actually meant, and it is stronger than a
    // global version pin: it fails if the ads track ever adds a migration,
    // whatever the version number happens to be.
    for (final src in _adsLayerSources()) {
      for (final forbidden in const [
        'CREATE TABLE',
        'ALTER TABLE',
        '_targetSchemaVersion',
        'MigrationStrategy',
        'customStatement',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'the ads layer must not carry schema work ($forbidden)');
      }
    }
  });

  test('the ads layer never reads entitlement tables directly', () {
    const tables = [
      'user_entitlement_state',
      'entitlement_events',
      'referral_reward_progress',
      'referral_reward_grants',
    ];
    for (final src in _adsLayerSources()) {
      for (final t in tables) {
        expect(src.contains("'$t'"), isFalse, reason: 'direct read of $t');
      }
      expect(src.contains('.from('), isFalse,
          reason: 'the ads layer must not issue a direct table read');
    }
  });

  test('no production ad IDs in source — only Google test publisher units', () {
    final re = RegExp(r'ca-app-pub-[0-9]+');
    for (final f in _allLibDart()) {
      for (final m in re.allMatches(f.readAsStringSync())) {
        expect(m.group(0), contains('3940256099942544'),
            reason: 'non-test ad id ${m.group(0)} in ${f.path}');
      }
    }
  });

  test('the ads layer contains no report-generation logic', () {
    for (final src in _adsLayerSources()) {
      expect(src.contains('runReportGeneration'), isFalse);
      expect(src.contains('ReportGenerationController'), isFalse);
      expect(src.contains('report_config_sheet'), isFalse);
      expect(src.contains('report_generation'), isFalse);
    }
  });

  // ── R7 I3/A3 — AdMob release configuration plumbing ──────────────────────
  //
  // The repository and QA builds are ALLOWED to carry Google's TEST identifiers.
  // What must be impossible is a SHIPPING build resolving them implicitly, so
  // these guards pin the plumbing rather than banning the test publisher.

  test('iOS GADApplicationIdentifier is build-configured, not a literal', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    final idx = plist.indexOf('GADApplicationIdentifier');
    expect(idx, greaterThan(-1), reason: 'the AdMob app id key must exist');
    final after = plist.substring(idx, idx + 200);
    expect(after, contains(r'$(ADMOB_APP_ID)'),
        reason: 'the app id must come from the build setting');
    expect(after, isNot(contains('ca-app-pub-')),
        reason: 'no hardcoded AdMob app id may ship in Info.plist');
  });

  test('iOS ADMOB_APP_ID is test-only on dev configs and injected on Release',
      () {
    final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    // Release must defer to the injected variable...
    expect(pbx, contains(r'ADMOB_APP_ID = "$(ADMOB_APP_ID_IOS)"'),
        reason: 'Release must take the app id from the release pipeline');
    // ...and the only literal present must be Google's TEST app id.
    final literals = RegExp(r'ADMOB_APP_ID = "(ca-app-pub-[^"]+)"')
        .allMatches(pbx)
        .map((m) => m.group(1)!)
        .toSet();
    for (final v in literals) {
      expect(v, startsWith('ca-app-pub-3940256099942544'),
          reason: 'only Google TEST app ids may be committed');
    }
  });

  test('Android APPLICATION_ID is a manifest placeholder, not a literal', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final idx = manifest.indexOf('com.google.android.gms.ads.APPLICATION_ID');
    expect(idx, greaterThan(-1));
    final after = manifest.substring(idx, idx + 200);
    expect(after, contains(r'${admobAppId}'),
        reason: 'the app id must come from the Gradle placeholder');
    expect(after, isNot(contains('ca-app-pub-')),
        reason: 'no hardcoded AdMob app id may ship in the manifest');
  });

  test('Gradle resolves the release app id from env/property', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync();
    expect(gradle, contains('ADMOB_APP_ID_ANDROID'));
    expect(gradle, contains('manifestPlaceholders["admobAppId"]'));
  });

  test('the four canonical config names are the only ones used', () {
    const configPath = 'lib/features/ads/admob_build_config.dart';
    final cfg = File(configPath).readAsStringSync();
    for (final name in const [
      'ADMOB_APP_ID_IOS',
      'ADMOB_APP_ID_ANDROID',
      'ADMOB_INTERSTITIAL_IOS',
      'ADMOB_INTERSTITIAL_ANDROID',
      'ADMOB_BANNER_IOS',
      'ADMOB_BANNER_ANDROID',
    ]) {
      expect(cfg, contains("String.fromEnvironment('$name')"), reason: name);
    }
    // No alias/duplicate configuration system crept in. Six, not four: the
    // banner work added two inputs, and editing THIS NUMBER is the deliberate
    // act the guard exists to force. Adding an AdMob input must never be
    // possible without touching this line.
    final names = RegExp(r"String\.fromEnvironment\('(ADMOB_[A-Z_]+)'\)")
        .allMatches(cfg)
        .map((m) => m.group(1)!)
        .toSet();
    expect(names.length, 6, reason: 'exactly six AdMob inputs: $names');

    // ...and they live in exactly ONE file. A second config file would give
    // each of them a weaker, per-file invariant instead of one strong one.
    for (final f in _allLibDart()) {
      if (f.path.replaceAll(r'\\', '/').endsWith(configPath)) continue;
      expect(f.readAsStringSync().contains("fromEnvironment('ADMOB_"), isFalse,
          reason: 'AdMob build input outside $configPath: ${f.path}');
    }
  });

  // ── BANNER ADS ───────────────────────────────────────────────────────────

  test('Google Mobile Ads types never escape the ads layer', () {
    final adsPaths =
        _adsLayerFiles().map((f) => f.path.replaceAll(r'\\', '/')).toSet();
    for (final f in _allLibDart()) {
      if (adsPaths.contains(f.path.replaceAll(r'\\', '/'))) continue;
      final src = f.readAsStringSync();
      expect(src.contains('package:google_mobile_ads/'), isFalse,
          reason: 'the SDK must stay behind the ads layer: ${f.path}');
      for (final symbol in const [
        'BannerAd(',
        'AdWidget(',
        'AdSize.',
        'InterstitialAd.',
        'MobileAds.instance',
      ]) {
        expect(src.contains(symbol), isFalse,
            reason: '$symbol leaked into ${f.path}');
      }
    }
  });

  test('the ads layer depends on nothing financial', () {
    // Ads may render UI. Ads may not become part of financial state, and they
    // must not be able to READ it either — no targeting can be built out of a
    // user's bank messages if the types are unreachable from here.
    for (final f in _adsLayerFiles()) {
      final src = f.readAsStringSync();
      for (final forbidden in const [
        "import '../../domain/",
        "import '../../engine/",
        "import '../../data/repositories/",
        'package:money_companion/domain/',
        'package:money_companion/engine/',
        'package:money_companion/data/repositories/',
      ]) {
        expect(src.contains(forbidden), isFalse,
            reason: 'financial dependency in ${f.path}: $forbidden');
      }
    }
  });

  test('QirshAdBanner appears ONLY at approved placement call sites', () {
    // A positive allowlist, not a list of forbidden filenames. Enumerating the
    // screens an ad must never reach is unbounded and silently stops covering
    // any screen added later; enumerating the ones it MAY reach is finite and
    // fails closed — a new placement cannot ship without editing this list.
    const approved = {
      'lib/features/transactions/transactions_screen.dart',
      'lib/features/achievements/achievements_screen.dart',
      'lib/features/goals/goals_screen.dart',
      'lib/features/subscriptions/subscriptions_screen.dart',
      'lib/features/reports/reports_screen.dart',
      'lib/features/dashboard/dashboard_screen.dart',
    };
    final found = <String>{};
    for (final f in _allLibDart()) {
      final path = f.path.replaceAll(r'\\', '/');
      if (path.startsWith('lib/features/ads/')) continue;
      if (f.readAsStringSync().contains('QirshAdBanner')) found.add(path);
    }
    expect(found, approved,
        reason: 'banner call sites changed. The ad-surface allowlist is CLOSED '
            '(owner decision 2026-09-19, D-19, superseding D-18): a surface not '
            'approved there is prohibited. Adding one requires an owner '
            'decision recorded in docs/project/DECISIONS.md and section 0 of '
            'docs/plans/MONETIZATION_PLAN.md — not an edit to this list.\n'
            'D-19 approves six surfaces; this list is the narrower record of '
            'which are actually MOUNTED. Dashboard, Goals, Subscriptions, '
            'Reports and Achievements are approved and not yet mounted — the '
            'entry goes in here in the same change that adds the widget, not '
            'ahead of it.');
  });

  test('the AdPlacement enum itself is a closed allowlist', () {
    // The call-site guard above is necessary but not sufficient. A placement
    // could be added to the enum and mounted inside an ALREADY approved file,
    // and the call-site set would not change. The approved surfaces are a
    // product contract (D-19), so the enum that names them is pinned too.
    expect(_placementNames(), {
      'transactionsList',
      'dashboard',
      'goals',
      'subscriptions',
      'reports',
      'achievements',
    },
        reason: 'AdPlacement changed. Approved surfaces are the six banner '
            'placements above (owner decision D-19, 2026-09-19, superseding '
            'D-18) plus the report-export interstitial, and nothing else. '
            'Still excluded by owner decision: Budgets, Smart Inbox, '
            'capture/review/confirmation, transaction detail/edit, '
            'Coupons/Savings/Merchant offers, onboarding/auth, privacy, '
            'backup/restore, destructive flows, and forms and modal financial '
            'actions. That exclusion list is illustrative — the allowlist is '
            'what permits. Record a new surface in docs/project/DECISIONS.md '
            'first.');
  });

  test('every placement flag is seeded, and seeded FALSE', () {
    // `getBool` consults the remote cache first and falls back to `_defaults`.
    // A key in neither is false by ACCIDENT — indistinguishable from "off"
    // right up until someone flips it remotely and nothing happens.
    //
    // And `false` specifically, not merely present: the rollout bucket returns
    // null for a user OUTSIDE the percentage, which falls through to this map.
    // A placement seeded `true` would therefore serve ads to precisely the
    // population a partial rollout was created to withhold them from — the
    // rollout would read as "10% on" and behave as "100% on".
    //
    // Derived from the enum rather than listed, so a new placement cannot ship
    // with an unseeded flag.
    final defaults =
        File('lib/data/catalog/feature_flag_service.dart').readAsStringSync();
    final placementKeys = RegExp(r"^\s{2}[a-z][A-Za-z0-9]*\('([a-z0-9_]+)'\)",
            multiLine: true)
        .allMatches(_placementEnumBody())
        .map((m) => m.group(1)!)
        .toSet();
    expect(placementKeys.length, _placementNames().length,
        reason: 'every enum value declares a literal key');
    for (final key in {
      'enable_banner_ads',
      for (final k in placementKeys) 'enable_banner_$k',
    }) {
      expect(defaults, contains("'$key': false"),
          reason: '$key must be seeded, and seeded OFF, in _defaults');
      expect(defaults, isNot(contains("'$key': true")),
          reason: '$key must never be seeded ON');
    }
  });

  test('the per-placement flag key is spelled in exactly one place', () {
    // Three things must agree on the spelling: the provider that reads it, the
    // `_defaults` seed, and the guard above. `AdPlacement.flagKey` is that one
    // place; an interpolated string rebuilt at the read site can drift from the
    // seed and fail silently to "off".
    final providers =
        File('lib/features/ads/banner_ads_providers.dart').readAsStringSync();
    expect(providers.contains('placement.flagKey'), isTrue);
    expect(providers.contains("'enable_banner_\${placement"), isFalse,
        reason: 'read the key from AdPlacement.flagKey, do not re-interpolate');
  });

  test('no banner placement has a raw ad unit id', () {
    // Placements name an enum; the enum maps to a unit in ONE function. A raw
    // id in a feature file cannot be disabled independently or reported on.
    final placement =
        File('lib/features/ads/ad_placement.dart').readAsStringSync();
    expect(placement.contains('ca-app-pub-'), isFalse);
  });

  test('every AdRequest is non-personalized, and ATT stays absent', () {
    // This guard defends a claim made OUTSIDE Dart. `ios/Runner/
    // PrivacyInfo.xcprivacy` declares `NSPrivacyTracking` false with an empty
    // `NSPrivacyTrackingDomains`, and Info.plist ships no
    // `NSUserTrackingUsageDescription`. That set is only honest while every ad
    // request is non-personalized: flipping one `nonPersonalizedAds` to false
    // would make the shipped privacy manifest untrue, and nothing in the Dart
    // layer would notice.
    //
    // Turning personalized ads on is therefore not a one-line change. It needs
    // an ATT usage string, an ATT request before the ad request, and both
    // manifest keys updated — so this test failing is the intended signal, not
    // an obstacle to route around.
    var requests = 0;
    for (final file in _adsLayerFiles()) {
      final source = file.readAsStringSync();
      for (final match in RegExp(r'AdRequest\(').allMatches(source)) {
        requests++;
        // The constructor call, up to its closing paren at the same nesting.
        final tail = source.substring(match.end, match.end + 200 > source.length
            ? source.length
            : match.end + 200);
        final body = tail.substring(0, tail.indexOf(')'));
        expect(body, contains('nonPersonalizedAds: true'),
            reason: '${file.path}: every AdRequest must be non-personalized — '
                'the shipped privacy manifest says this app does not track');
        expect(body, contains("'npa': '1'"),
            reason: '${file.path}: the legacy npa extra is kept alongside the '
                'typed property because mediation adapters still read it');
      }
    }
    expect(requests, greaterThan(0),
        reason: 'the guard found no AdRequest at all — it has stopped guarding');

    // The other half of the same claim: no ATT anywhere.
    for (final path in const [
      'ios/Runner/Info.plist',
      'ios/Runner/PrivacyInfo.xcprivacy',
    ]) {
      expect(_read(path).contains('NSUserTrackingUsageDescription'), isFalse,
          reason: '$path declares an ATT purpose string while every ad request '
              'is non-personalized — one of the two is wrong');
    }
    expect(_read('ios/Runner/PrivacyInfo.xcprivacy'),
        contains('<key>NSPrivacyTracking</key>\n\t<false/>'),
        reason: 'NSPrivacyTracking must stay false while ads are NPA-only');
  });
}
