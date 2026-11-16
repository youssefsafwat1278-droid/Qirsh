import 'ledger_admission_fixture.dart';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/money_v30_backfill.dart';
import 'package:money_companion/data/db/sql_value_codec.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/ledger_push_service.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../harness/seed_test_account.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'test-key';
  @override
  Future<String?> readStoredKey() async => 'test-key';
}

class _Remote implements LedgerRemoteSource {
  List<Map<String, dynamic>> rows = [];

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final sorted = [...rows]..sort((a, b) {
        final t = normalizeCursorTimestamp(a['updated_at'])
            .compareTo(normalizeCursorTimestamp(b['updated_at']));
        return t != 0 ? t : (a['id'] as String).compareTo(b['id'] as String);
      });
    return sorted
        .where((row) {
          if (after.id.isEmpty) return true;
          final t =
              normalizeCursorTimestamp(row['updated_at']).compareTo(after.updatedAt);
          return t > 0 || (t == 0 && (row['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .toList();
  }
}

Map<String, dynamic> _serverRow({
  required String id,
  required String updatedAt,
  String? merchant,
  String? categoryKey,
  String? categorySource,
  bool sendSourceKey = true,
  String transactionType = 'expense',
  bool? importedFromFile,
}) =>
    {
      'id': id,
      'source_payload_id': null,
      'amount': 100.0,
      'amount_text': '100.0',
      'balance_after_text': null,
      'foreign_amount_text': null,
      'foreign_currency': null,
      'currency': 'SAR',
      'direction': transactionType == 'income' ? 'credit' : 'debit',
      'transaction_type': transactionType,
      'source': 'ios_shortcut',
      'merchant': merchant,
      'occurred_at': '2026-01-01T10:00:00.000Z',
      'updated_at': updatedAt,
      'confidence': 0.9,
      'category_id': categoryKey,
      if (sendSourceKey) 'category_source': categorySource,
      if (importedFromFile != null) 'imported_from_file': importedFromFile,
    };

void main() {
  group('pull', () {
    late AppDatabase db;
    late _Remote remote;

    setUp(() async {
      db = await seededDb(AppDatabase.open(
        executor: NativeDatabase.memory(),
        keyStore: _MemoryKeyStore(),
      ));
      remote = _Remote();
    });
    tearDown(() => db.close());

    Future<void> pull() => LedgerSyncService(
          db: db,
          transactionRepository: DriftTransactionRepository(db),
          dedupStore: DriftDedupStore(db),
          isPullEnabled: () => true,
          remoteSource: remote,
          getAuthUserId: () async => 'test-user-id',
          mayEgress: () async => true,
        ).pull();

    Future<Map<String, Object?>> local(String serverId) async => (await db
            .customSelect(
                'SELECT t.category_source, t.merchant_id, t.raw_merchant, '
                't.imported_from_file, '
                'c.key AS category_key, m.normalized_name AS mn '
                'FROM transactions t '
                'LEFT JOIN categories c ON c.id = t.category_id '
                'LEFT JOIN merchants m ON m.id = t.merchant_id '
                "WHERE t.server_id = ${sqlString(serverId)};")
            .getSingle())
        .data;

    test('a new pulled row takes the server provenance (or unknown)', () async {
      remote.rows = [
        _serverRow(
            id: 'a',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'user'),
        _serverRow(
            id: 'b',
            updatedAt: '2026-01-01T10:00:01.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'rule'),
        _serverRow(
            id: 'c',
            updatedAt: '2026-01-01T10:00:02.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            sendSourceKey: false),
        _serverRow(
            id: 'd',
            updatedAt: '2026-01-01T10:00:03.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'bogus'),
      ];
      await pull();

      expect((await local('a'))['category_source'], 'user');
      expect((await local('b'))['category_source'], 'rule');
      expect((await local('c'))['category_source'], 'unknown',
          reason: 'an older server sends no key: origin is unknown');
      expect((await local('d'))['category_source'], 'unknown',
          reason: 'an unrecognised value is never trusted');
      expect((await local('a'))['mn'], AppDatabase.normalizeMerchant('ZARYAB'));
    });

    test('the file-import marker arrives on new rows and is never cleared',
        () async {
      remote.rows = [
        _serverRow(
            id: 'imp',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'unknown',
            importedFromFile: true),
        _serverRow(
            id: 'plain',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
      ];
      await pull();
      expect((await local('imp'))['imported_from_file'], 1);
      expect((await local('plain'))['imported_from_file'], 0);

      // An older server (no key) or a stale false never clears it.
      remote.rows = [
        _serverRow(
            id: 'imp',
            updatedAt: '2026-01-02T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'groceries',
            categorySource: 'unknown'),
      ];
      await pull();
      expect((await local('imp'))['imported_from_file'], 1);
      remote.rows = [
        _serverRow(
            id: 'imp',
            updatedAt: '2026-01-03T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'groceries',
            categorySource: 'unknown',
            importedFromFile: false),
      ];
      await pull();
      expect((await local('imp'))['imported_from_file'], 1);

      // A row marked imported on another device gets the mark here too.
      remote.rows = [
        _serverRow(
            id: 'plain',
            updatedAt: '2026-01-04T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'auto',
            importedFromFile: true),
      ];
      await pull();
      expect((await local('plain'))['imported_from_file'], 1);
    });

    test('an update applies the pulled provenance', () async {
      remote.rows = [
        _serverRow(
            id: 'a',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
      ];
      await pull();
      remote.rows = [
        _serverRow(
            id: 'a',
            updatedAt: '2026-01-02T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'groceries',
            categorySource: 'user'),
      ];
      await pull();
      final r = await local('a');
      expect(r['category_key'], 'groceries');
      expect(r['category_source'], 'user');
    });

    test('an older server: a changed category becomes unknown, an unchanged '
        'one keeps the local provenance', () async {
      remote.rows = [
        _serverRow(
            id: 'same',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'user'),
        _serverRow(
            id: 'moved',
            updatedAt: '2026-01-01T10:00:01.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'user'),
      ];
      await pull();
      remote.rows = [
        // A note edit made by an older app: same category, no key.
        _serverRow(
            id: 'same',
            updatedAt: '2026-01-02T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            sendSourceKey: false),
        // A category change made by an older app: no key.
        _serverRow(
            id: 'moved',
            updatedAt: '2026-01-02T10:00:01.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'groceries',
            sendSourceKey: false),
      ];
      await pull();

      expect((await local('same'))['category_source'], 'user');
      final moved = await local('moved');
      expect(moved['category_key'], 'groceries');
      expect(moved['category_source'], 'unknown');
    });

    test('a renamed merchant is relinked; transfers and income are unlinked',
        () async {
      remote.rows = [
        _serverRow(
            id: 'rename',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'OLD SHOP',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
        _serverRow(
            id: 'to-transfer',
            updatedAt: '2026-01-01T10:00:01.000Z',
            merchant: 'Ahmed Ali',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
      ];
      await pull();
      final oldLink = (await local('rename'))['merchant_id'];
      expect(oldLink, isNotNull);
      expect((await local('to-transfer'))['merchant_id'], isNotNull,
          reason: 'precondition: an expense is linked');

      remote.rows = [
        _serverRow(
            id: 'rename',
            updatedAt: '2026-01-02T10:00:00.000Z',
            merchant: 'NEW SHOP 12',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
        _serverRow(
            id: 'to-transfer',
            updatedAt: '2026-01-02T10:00:01.000Z',
            merchant: 'Ahmed Ali',
            categoryKey: 'restaurants',
            categorySource: 'auto',
            transactionType: 'income'),
      ];
      await pull();

      final renamed = await local('rename');
      expect(renamed['mn'], AppDatabase.normalizeMerchant('NEW SHOP 12'));
      expect(renamed['merchant_id'], isNot(oldLink));
      expect((await local('to-transfer'))['merchant_id'], isNull,
          reason: 'income carries an employer, never a merchant link');
    });

    test('an unchanged merchant keeps its existing link', () async {
      remote.rows = [
        _serverRow(
            id: 'keep',
            updatedAt: '2026-01-01T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'restaurants',
            categorySource: 'auto'),
      ];
      await pull();
      final before = (await local('keep'))['merchant_id'];
      remote.rows = [
        _serverRow(
            id: 'keep',
            updatedAt: '2026-01-02T10:00:00.000Z',
            merchant: 'ZARYAB',
            categoryKey: 'groceries',
            categorySource: 'user'),
      ];
      await pull();
      expect((await local('keep'))['merchant_id'], before);
    });
  });

  group('push', () {
    late AppDatabase db;
    late LedgerAdmissionFixture admission;
    late LedgerOutboxQueue q;
    late List<Map<String, dynamic>> sent;
    late SyncHealth health;
    Map<String, Object?> rpcBody = const {};
    var rpcMissing = false;

    setUp(() async {
      admission = await LedgerAdmissionFixture.open('u1');
      db = admission.database;
      q = LedgerOutboxQueue(
          db: db, isPushEnabled: () => true, getAuthUserId: () async => 'u1');
      sent = [];
      health = SyncHealth();
      rpcBody = const {};
      rpcMissing = false;
    });
    tearDown(() async => admission.finish());

    SupabaseClient client() {
      final now = dateTimeToSql(DateTime.now().toUtc());
      return LedgerAdmissionFixture.trackClient(SupabaseClient(
        'https://example.supabase.co',
        'anon',
        accessToken: () async => 'tok',
        httpClient: MockClient((request) async {
          http.Response json(int code, Object body) => http.Response(
              jsonEncode(body), code,
              headers: const {'content-type': 'application/json'},
              request: request);
          if (request.url.path.endsWith('/rpc/qirsh_server_capabilities')) {
            return rpcMissing
                ? json(404, {'code': 'PGRST202', 'message': 'missing'})
                : json(200, rpcBody);
          }
          if (request.url.path.contains('user_transactions') &&
              request.body.isNotEmpty) {
            final decoded = jsonDecode(request.body);
            sent.add(Map<String, dynamic>.from(
                decoded is List ? decoded.single as Map : decoded as Map));
          }
          return json(200, {'id': 'srv-${sent.length}', 'updated_at': now});
        }),
      ));
    }

    LedgerPushService push() => LedgerPushService(
          db: db,
          queue: q,
          isPushEnabled: () => true,
          getAuthUserId: () async => 'u1',
          getClient: client,
          mayEgress: () async => true,
          health: health,
          capabilities: ServerCapabilitiesService(
            getAuthUserId: () async => 'u1',
            getClient: client,
            mayEgress: () async => true,
            health: health,
            getServerUrl: () => 'https://example.supabase.co',
          ),
        );

    Future<void> insertAndEnqueue(String id, String provenance,
        {bool imported = false}) async {
      final now = dateTimeToSql(DateTime.now().toUtc());
      final cat = (await db
              .customSelect(
                  "SELECT id FROM categories WHERE key = 'restaurants';")
              .getSingle())
          .read<String>('id');
      await db.customStatement('''
        INSERT INTO transactions(
          id, amount, currency, type, source, occurred_at, raw_message,
          parse_confidence, status, created_at, updated_at, raw_merchant,
          category_id, category_source, imported_from_file
        ) VALUES (
          '$id', 25.0, 'SAR', 'payment', 'bank', '$now', '', 0.9, 'confirmed',
          '$now', '$now', 'ZARYAB', '$cat', '$provenance', ${imported ? 1 : 0}
        );
      ''');
      await backfillNonPlanningMoneyV30(db);
      await q.enqueue(OutboxOperation.create,
          (await DriftTransactionRepository(db).getById(id))!);
    }

    test('a verified server receives the column and a bound fresh token',
        () async {
      rpcBody = {'transaction_category_source': true};
      await insertAndEnqueue('a', 'user');
      await insertAndEnqueue('b', 'rule');
      await push().push();

      expect(sent, hasLength(2));
      final byValue = {for (final r in sent) r['category_source']: r};
      expect(byValue.keys.toSet(), {'user', 'rule'});
      for (final entry in byValue.entries) {
        final token = (entry.value['metadata'] as Map)['cs_op'] as Map;
        expect(token['s'], entry.key, reason: 'the token names its value');
        expect(token['c'], entry.value['category_id'],
            reason: 'the token is bound to the category it vouches for');
        expect(token['c'], 'restaurants');
        expect((token['n'] as String).isNotEmpty, isTrue);
      }
      final nonces = sent
          .map((r) => ((r['metadata'] as Map)['cs_op'] as Map)['n'])
          .toSet();
      expect(nonces, hasLength(2), reason: 'every write mints a fresh nonce');
    });

    test('the import marker is sent only as true, only to a verified server',
        () async {
      rpcBody = {'transaction_category_source': true};
      await insertAndEnqueue('imp', 'unknown', imported: true);
      await insertAndEnqueue('own', 'auto');
      await push().push();
      final byCat = {for (final r in sent) r['category_source']: r};
      expect(byCat['unknown']!['imported_from_file'], isTrue);
      expect((byCat['unknown']!['metadata'] as Map)['canonical_source'], 'bank',
          reason: 'the exact original source travels unchanged');
      expect(byCat['auto']!.containsKey('imported_from_file'), isFalse);
    });

    test('an unverified server never sees the import marker', () async {
      rpcBody = const {'something_else': true};
      await insertAndEnqueue('imp', 'unknown', imported: true);
      await push().push();
      expect(sent.single.containsKey('imported_from_file'), isFalse);
    });

    for (final (label, body, missing) in [
      ('absent key', <String, Object?>{'something_else': true}, false),
      ('false key', <String, Object?>{'transaction_category_source': false},
          false),
      ('missing RPC', <String, Object?>{}, true),
    ]) {
      test('an unverified server ($label) never sees the column or token',
          () async {
        rpcBody = body;
        rpcMissing = missing;
        await insertAndEnqueue('a', 'user');
        await push().push();

        expect(sent, hasLength(1));
        expect(sent.single.containsKey('category_source'), isFalse);
        final metadata = sent.single['metadata'] as Map? ?? const {};
        expect(metadata.containsKey('cs_op'), isFalse);
      });
    }
  });
}
