// A user-confirmed merchant rule outranks the category a server-analysed
// (iOS relay) capture arrives with; a catalog seed mapping does not. Real
// CaptureSyncService over a real in-memory Drift database; only the network is
// a MockClient. All messages are synthetic.
import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

Map<String, Object?> _serverRow(String id, String merchant) {
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
}
