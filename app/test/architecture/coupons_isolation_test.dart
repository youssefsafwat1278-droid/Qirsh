// MALI-COUPONS (Phase C4) — architecture guards.
//
// The Coupons feature is an isolated catalog domain. It must never take over,
// mutate or reshape a closed contract (Money, Planning currency, CAS, financial
// outboxes, the business backup format, capture, APNs/notification scheduling),
// its remote requests must never carry financial data, and its ranking must not
// scan transactions inside a widget build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

/// Source with `//` comments stripped, so a scan tests CODE, not prose.
String _code(String path) => _read(path)
    .split('\n')
    .map((l) {
      final i = l.indexOf('//');
      return i >= 0 ? l.substring(0, i) : l;
    })
    .join('\n');

const _couponSources = <String>[
  'lib/features/coupons/coupon_models.dart',
  'lib/features/coupons/coupon_ranking.dart',
  'lib/features/coupons/coupon_analytics.dart',
  'lib/features/coupons/coupons_providers.dart',
  'lib/features/coupons/coupon_widgets.dart',
  'lib/features/coupons/coupons_screen.dart',
  // COUPONS Phase 1 — merchant awareness. Added to the SAME list rather than a
  // new one, so every existing isolation rule automatically applies to them.
  'lib/features/coupons/merchant_alias_key.dart',
  'lib/features/coupons/merchant_lookup_pipeline.dart',
  'lib/features/coupons/merchant_interest.dart',
];

void main() {
  test('Coupons never write to a financial, planning, sync or capture table', () {
    // The ONLY table the feature may write is its own catalog cache, and only
    // through the DAO.
    for (final path in _couponSources) {
      final code = _code(path);
      for (final forbidden in [
        'transactions',
        'accounts',
        'budgets',
        'goals',
        'subscriptions',
        'plans',
        'ledger_sync_outbox',
        'planning_sync_outbox',
        'parked_child_rows',
        'capture_devices',
        'amount_minor',
        'server_revision',
      ]) {
        expect(
          RegExp('''(INSERT INTO|UPDATE|DELETE FROM)\\s+$forbidden''', caseSensitive: false)
              .hasMatch(code),
          isFalse,
          reason: '$path must not mutate $forbidden',
        );
      }
    }
  });

  test('Coupons add no Money/CAS/backup/APNs coupling', () {
    for (final path in _couponSources) {
      final code = _code(path);
      for (final forbidden in [
        'Money(',
        'moneyToNumericText',
        'RevisionCasGate',
        'BackupSnapshotBuilder',
        'apns',
        'flutter_local_notifications',
        'OutboxOperation',
        'PlanningSyncOperation',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: '$path must not reference $forbidden');
      }
    }
  });

  test('the coupon cache is EXCLUDED from the business backup (v4 unchanged)', () {
    final builder = _read('lib/core/backup/backup_snapshot_builder.dart');
    // Present in the deliberate-exclusion set…
    expect(builder.contains("'remote_coupons'"), isTrue);
    // …and NOT in the backed-up table map. `_tables` maps table -> columns, so a
    // backed-up table appears as a `'name': [` key.
    expect(builder.contains("'remote_coupons': ["), isFalse,
        reason: 'the refetchable catalog cache must never enter the snapshot');
    // The business snapshot version is untouched by the COUPONS Drift bump. It
    // is 5 since round 4 (saved-rule deletion history, unrelated to coupons).
    expect(_read('lib/core/backup/backup_snapshot_builder.dart')
        .contains('currentSchemaVersion = 5'), isTrue);
  });

  test('§17 privacy: coupon remote calls carry no financial context', () {
    final analytics = _code('lib/features/coupons/coupon_analytics.dart');
    // The only outbound payload in the whole feature.
    expect(analytics.contains("'p_coupon_id': couponId, 'p_event': event.wireName"),
        isTrue);
    for (final forbidden in [
      'categoryBreakdown',
      'spendHint',
      'topSpend',
      'country',
      'installId',
      'deviceId',
      'balance',
      'amount',
    ]) {
      expect(analytics.contains(forbidden), isFalse,
          reason: 'the analytics payload must not touch $forbidden');
    }
    // The catalog fetch sends no user context either (no country parameter).
    final sync = _code('lib/data/catalog/catalog_sync_service.dart');
    final syncCoupons = sync.substring(sync.indexOf('Future<void> syncCoupons('));
    final body = syncCoupons.substring(0, syncCoupons.indexOf('Future<void> syncCategory('));
    expect(body.contains('queryParameters'), isFalse,
        reason: 'catalog-coupons is fetched without any user-derived parameter');
  });

  test('§16 ranking runs on device from prepared aggregates, never in build()', () {
    final ranking = _code('lib/features/coupons/coupon_ranking.dart');
    // Pure: no I/O, no repository, no network in the ranking module.
    for (final forbidden in ['await', 'Supabase', 'Repository', 'customSelect']) {
      expect(ranking.contains(forbidden), isFalse,
          reason: 'ranking must stay a pure function ($forbidden found)');
    }
    // Spend aggregates come from a memoized provider that watches a scoped
    // revision — not from a per-frame query.
    final providers = _code('lib/features/coupons/coupons_providers.dart');
    expect(providers.contains('scopedRevisionProvider(kReportsRevisionTables)'), isTrue);
    expect(providers.contains('categoryBreakdown'), isTrue);
    // Widgets never call the repository directly.
    for (final path in [
      'lib/features/coupons/coupons_screen.dart',
      'lib/features/coupons/coupon_widgets.dart',
    ]) {
      expect(_code(path).contains('categoryBreakdown'), isFalse);
      expect(_code(path).contains('transactionRepositoryProvider'), isFalse);
    }
  });

  test('§36 coupon analytics cannot trigger gamification or engagement awards', () {
    for (final path in _couponSources) {
      final code = _code(path);
      for (final forbidden in [
        'RecordEngagementUseCase',
        'recordEngagement',
        'engagementEventService',
        'gamification',
        'kEngagementAward',
      ]) {
        expect(code.contains(forbidden), isFalse,
            reason: '$path must not reach the gamification path');
      }
    }
  });

  test('§37 V1 ships no coupon push/notification surface', () {
    for (final path in _couponSources) {
      final code = _code(path);
      for (final forbidden in [
        'LocalNotificationService',
        'showNotification',
        'scheduleNotification',
        'NotificationPlanner',
        'register-push-token',
      ]) {
        expect(code.contains(forbidden), isFalse, reason: '$path must not notify');
      }
    }
  });

  test('§38 favourites/dismissals stay deferred: no per-coupon persistence', () {
    final schema = _read('lib/data/db/app_database.dart');
    expect(schema.contains('coupon_local_state'), isFalse,
        reason: 'V1 has exactly ONE coupon table');
    // The cache table carries no user-state columns.
    final start = schema.indexOf('CREATE TABLE IF NOT EXISTS remote_coupons(');
    final ddl = schema.substring(start, schema.indexOf("''')", start));
    for (final forbidden in ['saved_at', 'dismissed_at', 'is_favorite', 'first_seen_at']) {
      expect(ddl.contains(forbidden), isFalse, reason: 'no $forbidden column in V1');
    }
    for (final path in _couponSources) {
      final code = _code(path);
      expect(code.contains('favorite') || code.contains('dismiss'), isFalse,
          reason: '$path must not implement V1.1 features');
    }
  });

  test('§2 no hardcoded catalog remains: production content is server-only', () {
    final providers = _code('lib/features/coupons/coupons_providers.dart');
    expect(providers.contains('_sampleCoupons'), isFalse);
    // The read path goes through the Drift cache DAO, never a literal list.
    expect(providers.contains('RemoteCouponsDao'), isTrue);
    for (final path in _couponSources) {
      expect(_code(path).contains('talabat') || _code(path).contains('Talabat'), isFalse,
          reason: '$path must not embed demo partner data');
    }
  });

  test('C4.1: the catalog snapshot is ALL-OR-NOTHING — no row-dropping decode', () {
    final sync = _code('lib/data/catalog/catalog_sync_service.dart');
    final syncCoupons = sync.substring(sync.indexOf('Future<void> syncCoupons('));
    final body = syncCoupons.substring(0, syncCoupons.indexOf('Future<void> syncCategory('));

    // The whole snapshot is parsed by ONE all-or-nothing entry point…
    expect(body.contains('CouponOffer.parseSnapshot('), isTrue);
    // …and never by a per-row decode that silently discards failures. These are
    // the exact shapes that let a partially-valid snapshot replace a good cache.
    for (final forbidden in [
      'whereType<CouponOffer>()',
      'tryParseSnapshot',
      '.map(CouponOffer.',
    ]) {
      expect(body.contains(forbidden), isFalse,
          reason: 'syncCoupons must not drop malformed rows ($forbidden)');
    }
    // The row-level fail-safe decoder must not exist at all — keeping it would
    // leave the footgun one call site away.
    expect(_code('lib/features/coupons/coupon_models.dart').contains('tryParseSnapshot'),
        isFalse);

    // Validation must COMPLETE before the destructive replace begins: the DAO
    // is only reachable after parseSnapshot has returned a typed list.
    expect(body.indexOf('CouponOffer.parseSnapshot(') <
        body.indexOf('RemoteCouponsDao(_database).replaceAll('), isTrue);
    // replaceAll takes typed offers, never raw JSON.
    final dao = _code('lib/data/catalog/catalog_daos.dart');
    expect(dao.contains('Future<void> replaceAll(List<CouponOffer> offers)'), isTrue);
  });

  test('C4.1: snapshot rejection telemetry carries no user or server content', () {
    final sync = _code('lib/data/catalog/catalog_sync_service.dart');
    // A stable, allowlisted code — not a free-form message — identifies the
    // failure at the Sentry boundary.
    expect(sync.contains('TelemetryCodes.syncDecodeFailed'), isTrue);
    expect(sync.contains("operation: 'catalog_coupons'"), isTrue);
    // Logging goes through the redacting sink, never a raw print of the payload.
    final syncCoupons = sync.substring(sync.indexOf('Future<void> syncCoupons('));
    final body = syncCoupons.substring(0, syncCoupons.indexOf('Future<void> syncCategory('));
    expect(body.contains('Diag.error'), isTrue);
    expect(body.contains('debugPrint'), isFalse,
        reason: 'use the redacting sink, not a raw print');
    // No LOG call may pass the payload itself — only the typed exception (whose
    // toString is a fixed reason + row index + static id) or a literal.
    final logCalls = RegExp(r'Diag\.(error|log)\([^;]*;')
        .allMatches(body)
        .map((m) => m.group(0)!);
    expect(logCalls, isNotEmpty);
    for (final call in logCalls) {
      for (final forbidden in ['data', 'items', 'response', 'json', 'stackTrace']) {
        expect(call.contains(forbidden), isFalse,
            reason: 'log call must not carry $forbidden: $call');
      }
    }
  });

  test('§P1 merchant interest can never be serialised', () {
    // A merchant-interest score is a direct statement about someone's spending:
    // this person shops at X, often, recently. It is the most sensitive thing
    // this feature derives, and the entire on-device-personalization decision
    // exists to keep it here. No codec means it cannot be dropped into a
    // request body by a future refactor that "just adds toJson everywhere".
    final interest = _code('lib/features/coupons/merchant_interest.dart');
    for (final forbidden in [
      'toJson', 'toMap', 'jsonEncode', 'encode(', 'Codec', 'Serializer',
    ]) {
      expect(interest.contains(forbidden), isFalse,
          reason: 'merchant_interest.dart must carry no serialisation '
              '($forbidden found)');
    }
  });

  test('§P1 no merchant signal reaches the network', () {
    // The feature's ONLY outbound call remains record_coupon_event(id, event).
    // A merchant id or an interest score appearing next to a network call would
    // mean the server had started to learn where the user shops.
    for (final path in _couponSources) {
      final code = _code(path);
      final networkCalls = RegExp(r'\.(rpc|invoke)[<(][^;]*;')
          .allMatches(code)
          .map((m) => m.group(0)!);
      for (final call in networkCalls) {
        for (final forbidden in [
          'merchantId', 'merchant_id', 'topMerchantIds', 'MerchantInterest',
          'interest', 'aliasNormalized', 'merchantBreakdown',
        ]) {
          expect(call.contains(forbidden), isFalse,
              reason: '$path sends $forbidden to the server: $call');
        }
      }
    }
  });

  test('§P1 the personalization toggle is never synced', () {
    // It lives on user_settings, which IS synced — but through an explicit
    // column map, not SELECT *. That omission is the whole mechanism, so it has
    // to be a contract rather than a habit: the fact that someone enabled
    // spending-derived personalization is itself information about them.
    final push = _code(
        'lib/features/planning_sync/services/planning_push_service.dart');
    expect(push.contains('merchant_personalization_enabled'), isFalse,
        reason: 'the settings sync payload must not carry the local '
            'personalization toggle');
    expect(push.contains('merchantPersonalizationEnabled'), isFalse);
  });

  test('§P1 merchant resolution never runs on the server', () {
    // Catalog matching is on-device only. A server-side resolver would need the
    // user's merchant strings, which is exactly what never leaves.
    for (final path in _couponSources) {
      final code = _code(path);
      for (final forbidden in ['resolve-merchant', 'match-merchant', 'merchant-resolve']) {
        expect(code.contains(forbidden), isFalse,
            reason: '$path references a server-side merchant resolver');
      }
    }
  });

  test('the retired ALL country literal is gone from the client', () {
    for (final path in _couponSources) {
      expect(_code(path).contains("'ALL'"), isFalse,
          reason: "$path must use an empty list for global availability");
    }
  });
}
