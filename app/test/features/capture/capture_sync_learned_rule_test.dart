// A user-confirmed merchant rule, then a shared-learning mapping for the exact
// merchant, outrank the category a server-analysed (iOS relay) capture arrives
// with; a catalog seed mapping or a non-shared keyword does not. Real
// CaptureSyncService over a real in-memory Drift database; only the network is
// a MockClient. All messages are synthetic.
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/catalog/catalog_daos.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<void> syncBackendState() async {}
  @override
  Future<String?> readDeviceSecret() async => 'device-secret';
  @override
  Future<bool> isLinkedForCloud() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

Map<String, Object?> _serverRow(String id, String merchant,
    {String? display}) {
  final at = DateTime.utc(2026, 4, 8, 9, 45).toIso8601String();
  return {
    'payload_id': id,
    'status': 'processed',
    'parsed': {
      'amount': 45.0,
      'amount_text': '45.00',
      'currency': 'SAR',
      'direction': 'debit',
      'type': 'payment',
      'merchant': merchant,
      if (display != null) 'merchantDisplay': display,
      'category': 'shopping',
      'last4': '4521',
      'occurredAt': at,
      'comparisonTimestamp': at,
      'comparisonTimestampSource': 'received_at',
      'rawMessage': 'شراء $merchant مبلغ SAR 45.00 بطاقة 4521',
      'parserSource': 'ai',
      'confidence': 0.95,
    },
    'notification': <String, Object?>{},
  };
}

void main() {
  late AppDatabase db;
  late DriftMerchantCategoryRepository merchants;
  late List<Map<String, Object?>> rows;
  late CaptureSyncService sync;

  setUp(() async {
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    merchants = DriftMerchantCategoryRepository(db);
    rows = [];
    Future<http.Response> handle(http.Request request) async {
      if (!request.url.path.endsWith('/sync-captures')) {
        return http.Response('{}', 404);
      }
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final acks =
          ((body['ackPayloadIds'] as List?) ?? const []).cast<String>();
      rows.removeWhere((r) => acks.contains(r['payload_id']));
      return http.Response(jsonEncode({'captures': rows}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }

    final settings = DriftUserSettingsRepository(db);
    await settings.saveSettings((await settings.getSettings())
        .copyWith(cloudConsentState: ConsentState.accepted));
    sync = CaptureSyncService(
      settingsRepository: settings,
      transactionRepository: DriftTransactionRepository(db),
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(),
      currentUserId: () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      merchantCategoryRepository: merchants,
      loadRemoteKeywords: () => RemoteMerchantKeywordsDao(db).getAll(),
      client: CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'anon',
        httpClient: MockClient(handle),
      ),
      backendConfigured: true,
      loadInstallId: () async => 'install',
    );
  });

  tearDown(() => db.close());

  Future<String?> categoryOf(String id) async => (await db.customSelect(
        'SELECT c.key AS k FROM transactions t '
        'LEFT JOIN categories c ON c.id = t.category_id WHERE t.id = ?;',
        variables: [Variable.withString(id)],
      ).getSingle())
          .read<String?>('k');

  test('a user-confirmed rule beats the server category', () async {
    await merchants.confirmMerchantCategory(
        rawMerchant: 'ZARYAB DIMASHQI',
        categoryKey: 'restaurants',
        isUserConfirmed: true);
    rows.add(_serverRow('srv-1', 'ZARYAB DIMASHQI 12'));
    await sync.sync();
    expect(await categoryOf('srv-1'), 'restaurants');
  });

  test('a catalog seed mapping does not beat the server category', () async {
    // STARBUCKS is seeded (is_user_confirmed = 0) as cafes.
    expect((await merchants.getLearnedCategoryMap())['STARBUCKS'], 'cafes');
    rows.add(_serverRow('srv-2', 'STARBUCKS'));
    await sync.sync();
    expect(await categoryOf('srv-2'), 'shopping');
  });

  test('with no rule the server category is used', () async {
    rows.add(_serverRow('srv-3', 'ZARYAB DIMASHQI'));
    await sync.sync();
    expect(await categoryOf('srv-3'), 'shopping');
  });

  Future<void> keyword(String keyword, String category, int priority) =>
      RemoteMerchantKeywordsDao(db).upsertAll([
        RemoteMerchantKeyword(
          id: 'kw-$keyword',
          keyword: keyword,
          categoryKey: category,
          language: 'any',
          countryCode: 'ALL',
          priority: priority,
          isActive: true,
          isDeleted: false,
          updatedAt: '2026-11-16T00:00:00Z',
        ),
      ]);

  test('a shared-learning mapping for the exact merchant beats the server',
      () async {
    await keyword('ZARYAB DIMASHQI', 'restaurants', 1000);
    rows.add(_serverRow('srv-4', 'Zaryab Dimashqi 12'));
    await sync.sync();
    expect(await categoryOf('srv-4'), 'restaurants');
  });

  test('a user rule beats a shared mapping and the server', () async {
    await keyword('ZARYAB DIMASHQI', 'restaurants', 1000);
    await merchants.confirmMerchantCategory(
        rawMerchant: 'ZARYAB DIMASHQI',
        categoryKey: 'groceries',
        isUserConfirmed: true);
    rows.add(_serverRow('srv-5', 'ZARYAB DIMASHQI'));
    await sync.sync();
    expect(await categoryOf('srv-5'), 'groceries');
  });

  test('a non-shared keyword (curated / Places) does not beat the server',
      () async {
    await keyword('ZARYAB DIMASHQI', 'restaurants', 0);
    rows.add(_serverRow('srv-6', 'ZARYAB DIMASHQI'));
    await sync.sync();
    expect(await categoryOf('srv-6'), 'shopping');
  });

  test('a shared mapping matching only a substring does not beat the server',
      () async {
    await keyword('ZARYAB', 'restaurants', 1000);
    rows.add(_serverRow('srv-7', 'ZARYAB DIMASHQI'));
    await sync.sync();
    expect(await categoryOf('srv-7'), 'shopping');
  });

  Future<String?> merchantOf(String id) async => (await db.customSelect(
        'SELECT raw_merchant AS m FROM transactions WHERE id = ?;',
        variables: [Variable.withString(id)],
      ).getSingle())
          .read<String?>('m');

  test('phase 4: the server display name of a merchant code is recorded',
      () async {
    rows.add(_serverRow('srv-8', 'PAYMOB RAF SPECIALIT',
        display: 'RAF Specialized Hospital'));
    await sync.sync();
    expect(await merchantOf('srv-8'), 'RAF Specialized Hospital');
    expect(await categoryOf('srv-8'), 'shopping');
  });

  test('phase 4: a user rule on the code keeps the code and the rule',
      () async {
    await merchants.confirmMerchantCategory(
        rawMerchant: 'PAYMOB RAF SPECIALIT',
        categoryKey: 'health',
        isUserConfirmed: true);
    rows.add(_serverRow('srv-9', 'PAYMOB RAF SPECIALIT',
        display: 'RAF Specialized Hospital'));
    await sync.sync();
    expect(await merchantOf('srv-9'), 'PAYMOB RAF SPECIALIT');
    expect(await categoryOf('srv-9'), 'health');
  });

  test('phase 4: an old server reply (no display name) is unchanged',
      () async {
    rows.add(_serverRow('srv-10', 'PAYMOB RAF SPECIALIT'));
    await sync.sync();
    expect(await merchantOf('srv-10'), 'PAYMOB RAF SPECIALIT');
  });
}
