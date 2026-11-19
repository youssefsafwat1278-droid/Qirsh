// MALI-COUPONS (Phase C4) — Drift v31 migration (§39) and the atomic catalog
// cache replace (§40 A–F) against a REAL database.
//
// C4.1 adds the SNAPSHOT ATOMICITY regressions: the catalog-coupons response is
// one authoritative unit, so a single malformed row must reject the entire
// snapshot and leave the last-known-good cache byte-for-byte intact.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/catalog/announcement_service.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/catalog/catalog_sync_service.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/features/coupons/coupon_models.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

Future<int> _userVersion(AppDatabase db) async =>
    (await db.customSelect('PRAGMA user_version;').getSingle()).read<int>('user_version');

Future<bool> _hasTable(AppDatabase db, String name) async =>
    (await db
            .customSelect(
              "SELECT COUNT(*) AS n FROM sqlite_master "
              "WHERE type = 'table' AND name = '$name';",
            )
            .getSingle())
        .read<int>('n') ==
    1;

CouponOffer _offer(String id, {String slug = 's', List<CouponTag> tags = const []}) =>
    CouponOffer(
      id: id,
      slug: slug,
      partnerName: 'Partner',
      titleAr: 'عنوان',
      descriptionAr: 'وصف',
      redemptionType: CouponRedemptionType.code,
      code: 'CODE$id',
      category: const CouponCategory(key: 'food', labelAr: 'مطاعم', labelEn: 'Food'),
      validFrom: DateTime.utc(2026, 8, 1),
      validUntil: DateTime.utc(2027, 1, 1),
      tags: tags,
      countryCodes: const ['SA'],
      spendHintCategoryKeys: const ['restaurants'],
      accentHex: '#2563EB',
      featured: true,
      priority: 5,
      termsAr: 'شروط',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Drift v31 migration (§39)', () {
    test('A/D: a fresh database is at v31 with an EMPTY coupon cache', () async {
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      expect(await _userVersion(db), 45);
      expect(await _hasTable(db, 'remote_coupons'), isTrue);
      expect(await RemoteCouponsDao(db).count(), 0);
    });

    test('B/C: a real v30 file upgrades to v31, creating ONLY the new table and '
        'preserving existing business data', () async {
      final dir = Directory.systemTemp.createTempSync('coupons_v31');
      final path = '${dir.path}/app.db';
      addTearDown(() => dir.deleteSync(recursive: true));

      // Build a v30-shaped database: drop the v31 addition and stamp 30.
      final v30 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      await v30.customStatement(
        "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
        "VALUES ('acc-keep', 'Bank', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
      );
      await v30.customStatement('DROP TABLE remote_coupons;');
      await v30.customStatement('PRAGMA user_version = 30;');
      expect(await _hasTable(v30, 'remote_coupons'), isFalse);
      await v30.close();

      // Reopening runs the additive migration.
      final v31 = await AppDatabase.open(
          executor: NativeDatabase(File(path)), keyStore: _MemoryKeyStore());
      addTearDown(v31.close);
      expect(await _userVersion(v31), 45);
      expect(await _hasTable(v31, 'remote_coupons'), isTrue);
      expect(await RemoteCouponsDao(v31).count(), 0, reason: 'starts empty');
      // C: pre-existing financial data survived untouched.
      final kept = await v31
          .customSelect("SELECT name FROM accounts WHERE id = 'acc-keep';")
          .getSingleOrNull();
      expect(kept?.read<String>('name'), 'Bank');
    });

    test('E: the newer-than-app guard still fails closed at v31', () async {
      // Same single-instance pattern the migration pipeline suite uses: stamp a
      // version newer than the app, then drive initialize().
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      await db.customStatement('PRAGMA user_version = 999;');

      Object? caught;
      try {
        await db.debugReinitialize();
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<UnsupportedDatabaseVersionException>());
      expect((caught! as UnsupportedDatabaseVersionException).supportedVersion, 45);
      // Fail-closed: nothing was migrated or rewritten.
      expect(await _userVersion(db), 999);
    });
  });

  group('atomic cache replace (§40 A–F)', () {
    late AppDatabase db;
    late RemoteCouponsDao dao;

    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      dao = RemoteCouponsDao(db);
    });
    tearDown(() => db.close());

    test('A: a successful snapshot lands whole and round-trips typed', () async {
      await dao.replaceAll([
        _offer('c1', slug: 'first', tags: const [
          CouponTag(key: 'food', labelAr: 'مطاعم', labelEn: 'Food'),
          CouponTag(key: 'delivery', labelAr: 'توصيل'),
        ]),
      ]);

      final cached = await dao.getAll();
      expect(cached, hasLength(1));
      final offer = cached.single;
      expect(offer.id, 'c1');
      expect(offer.slug, 'first');
      expect(offer.redemptionType, CouponRedemptionType.code);
      expect(offer.code, 'CODEc1');
      expect(offer.category.labelAr, 'مطاعم');
      expect(offer.category.labelEn, 'Food');
      // Embedded collections survive the JSON round-trip IN ORDER.
      expect(offer.tags.map((t) => t.key).toList(), ['food', 'delivery']);
      expect(offer.tags.first.labelEn, 'Food');
      expect(offer.spendHintCategoryKeys, ['restaurants']);
      expect(offer.countryCodes, ['SA']);
      expect(offer.accentColor, isNotNull);
      expect(offer.featured, isTrue);
      expect(offer.priority, 5);
      expect(offer.termsAr, 'شروط');
      expect(offer.validUntil, DateTime.utc(2027, 1, 1));
    });

    test('B: a later snapshot REPLACES the catalog (removed offers disappear)',
        () async {
      await dao.replaceAll([_offer('old1'), _offer('old2')]);
      expect(await dao.count(), 2);

      await dao.replaceAll([_offer('new1')]);
      final cached = await dao.getAll();
      expect(cached.map((o) => o.id).toList(), ['new1']);
    });

    test('C: an EMPTY successful snapshot clears the cache', () async {
      await dao.replaceAll([_offer('c1')]);
      await dao.replaceAll(const <CouponOffer>[]);
      expect(await dao.count(), 0);
      expect(await dao.getAll(), isEmpty);
    });

    test('D: a failing insert ROLLS BACK — the previous snapshot survives', () async {
      await dao.replaceAll([_offer('keep-me')]);

      // Force a mid-transaction failure: a duplicate primary key inside the new
      // batch. The delete + inserts share one transaction, so nothing commits.
      await expectLater(
        dao.replaceAll([_offer('dup'), _offer('dup')]),
        throwsA(anything),
      );

      final cached = await dao.getAll();
      expect(cached.map((o) => o.id).toList(), ['keep-me'],
          reason: 'the catalog is never left half-old/half-new');
    });

    test('E: a sync failure never calls replaceAll, so the cache is preserved',
        () async {
      await dao.replaceAll([_offer('cached')]);
      // (The service returns early on a non-2xx/unparseable body — see
      // CatalogSyncService.syncCoupons; nothing touches the DAO.)
      expect((await dao.getAll()).single.id, 'cached');
    });

    test('F: duplicate identities within one snapshot are rejected deterministically',
        () async {
      await expectLater(
        dao.replaceAll([_offer('same'), _offer('same')]),
        throwsA(anything),
      );
      expect(await dao.count(), 0, reason: 'rolled back, not partially applied');
    });
  });

  // ---------------------------------------------------------------------
  // C4.1 — snapshot validation atomicity, driven through the REAL sync path
  // ---------------------------------------------------------------------
  group('snapshot atomicity (C4.1 §5–§9)', () {
    late AppDatabase db;
    late RemoteCouponsDao dao;

    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      dao = RemoteCouponsDao(db);
    });
    tearDown(() => db.close());

    /// A snapshot row as `catalog-coupons` serialises it.
    Map<String, Object?> row(String id, {bool malformed = false}) => {
          'id': id,
          'slug': id,
          'partner_name': 'Partner',
          'title_ar': 'عنوان',
          'description_ar': 'وصف',
          // A `code` offer with no code is the canonical contract violation.
          'redemption_type': 'code',
          'code': malformed ? null : 'CODE-$id',
          'display_category': const {'key': 'food', 'label_ar': 'مطاعم'},
          'tags': const <Object?>[],
          'spend_hint_category_keys': const <Object?>[],
          'country_codes': const <Object?>[],
          'valid_from': '2026-08-01T00:00:00.000Z',
          'valid_until': null,
        };

    /// Builds the real service over a canned Edge response.
    CatalogSyncService serviceReturning(Object body, {int status = 200}) {
      final client = supabase.SupabaseClient(
        'https://example.supabase.co',
        'anon',
        httpClient: MockClient((request) async => http.Response(
              jsonEncode(body),
              status,
              headers: const {'content-type': 'application/json'},
              request: request,
            )),
      );
      addTearDown(client.dispose);
      return CatalogSyncService(
        database: db,
        client: client,
        metadataDao: CatalogMetadataDao(db),
        announcementService:
            AnnouncementService(dao: RemoteAnnouncementsDao(db)),
      );
    }

    Future<List<String>> cachedIds() async =>
        (await dao.getAll()).map((c) => c.id).toList()..sort();

    test('§5: D valid / E malformed / F valid leaves the previous cache EXACTLY '
        'as it was — no partial replacement', () async {
      await dao.replaceAll([_offer('A'), _offer('B'), _offer('C')]);
      expect(await cachedIds(), ['A', 'B', 'C']);

      await serviceReturning({
        'items': [row('D'), row('E', malformed: true), row('F')],
      }).syncCoupons();

      // The whole snapshot was rejected: no D, no F, and A/B/C untouched.
      expect(await cachedIds(), ['A', 'B', 'C']);
    });

    test('§6: a structurally valid empty snapshot SUCCEEDS and clears the cache',
        () async {
      await dao.replaceAll([_offer('A'), _offer('B')]);
      await serviceReturning(const {'items': <Object?>[]}).syncCoupons();
      // Proves malformed and empty stay distinct outcomes.
      expect(await dao.count(), 0);
    });

    test('§7: a malformed row on the FIRST ever sync fails safely — cache stays '
        'empty, nothing throws', () async {
      expect(await dao.count(), 0);
      await expectLater(
        serviceReturning({'items': [row('only', malformed: true)]}).syncCoupons(),
        completes,
      );
      expect(await dao.count(), 0);
    });

    test('§5: a malformed ENVELOPE also preserves the cache', () async {
      await dao.replaceAll([_offer('A')]);
      for (final envelope in <Object>[
        const {'coupons': <Object?>[]}, // unrecognised key
        const {'items': 'nope'}, // wrong type
        const {}, // empty object
      ]) {
        await serviceReturning(envelope).syncCoupons();
        expect(await cachedIds(), ['A'], reason: '$envelope');
      }
    });

    test('§8: every validation-failure mode rejects the snapshot at the SYNC '
        'boundary, not just in the parser', () async {
      await dao.replaceAll([_offer('A')]);
      final broken = <String, Map<String, Object?>>{
        'redemption shape': row('x')..['redemption_type'] = 'voucher',
        'non-https link': row('x')
          ..['redemption_type'] = 'link'
          ..['code'] = null
          ..['partner_url'] = 'http://insecure.example',
        'invalid timestamp': row('x')..['valid_from'] = 'not-a-date',
        'invalid country': row('x')..['country_codes'] = <Object?>['ALL'],
        'malformed tag': row('x')
          ..['tags'] = <Object?>[
            const {'key': '', 'label_ar': 'broken'}
          ],
        'malformed category': row('x')..['display_category'] = 'food',
      };
      for (final entry in broken.entries) {
        await serviceReturning({
          'items': [row('good'), entry.value],
        }).syncCoupons();
        expect(await cachedIds(), ['A'],
            reason: '${entry.key} must reject the whole snapshot');
      }
    });

    test('§9: a rejected snapshot stays Coupon-domain-only — financial rows and '
        'the schema version are untouched', () async {
      await db.customStatement(
        "INSERT INTO accounts(id, name, currency, type, created_at, updated_at) "
        "VALUES ('acc-1', 'Bank', 'SAR', 'bank', '2026-01-01', '2026-01-01');",
      );
      await dao.replaceAll([_offer('A')]);

      await serviceReturning({
        'items': [row('bad', malformed: true)],
      }).syncCoupons();

      // Coupon cache preserved…
      expect(await cachedIds(), ['A']);
      // …and nothing outside the Coupon domain moved.
      final account = await db
          .customSelect("SELECT name FROM accounts WHERE id = 'acc-1';")
          .getSingleOrNull();
      expect(account?.read<String>('name'), 'Bank');
      expect(await _userVersion(db), 45);
    });
  });
}
