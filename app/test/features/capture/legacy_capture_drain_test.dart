// Behavioural tests of the legacy capture drain: the REAL per-message loop
// (LegacyCaptureDrain, what AppShell._consumeSharedInput runs) is executed
// end to end against
//   - the real NativeCaptureBridge over a mocked `money_companion/native_capture`
//     MethodChannel (TestDefaultBinaryMessenger) that models the native queue;
//   - a fake HTTP server (package:http MockClient) behind the real
//     CaptureBackendClient (`sync-captures`, `process-ios-sms`) and the real
//     SupabaseAiParserClient (`parse-sms`);
//   - a real in-memory Drift DB, real repositories, real AddTransactionUseCase,
//     CaptureSyncService and retry ledger (fake clock).
// Every message is synthetic. No source inspection anywhere in this file.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/core/privacy/consent_authority.dart';
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
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_retry_ledger.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/legacy_capture_drain.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../domain/local_v2_support.dart';

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

/// The native queue as the platform channel exposes it.
class _NativeQueue {
  final List<Map<String, Object?>> items = [];
  final acked = <String>[];
  final calls = <String>[];

  /// Makes `peekPendingSharedMessages` fail like an unreadable native store.
  bool peekFails = false;

  /// Makes the next N acknowledgements report "not removed".
  int ackFailures = 0;

  /// `authorizeCaptureUpload` reply: allowed / waiting / localOnly.
  String uploadDecision = 'allowed';

  void add(
    String id,
    String text, {
    String? status,
    String? failureReason,
    bool? localOnly,
    String sender = 'SNB',
    DateTime? receivedAt,
  }) =>
      items.add({
        'id': id,
        'text': text,
        'sender': sender,
        'source': 'sms',
        'receivedAtEpochMs':
            (receivedAt ?? DateTime.utc(2026, 4, 8, 9, 45)).millisecondsSinceEpoch,
        if (status != null) 'status': status,
        if (failureReason != null) 'failureReason': failureReason,
        if (localOnly != null) 'localOnly': localOnly,
      });

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'peekPendingSharedMessages':
        if (peekFails) {
          throw PlatformException(code: 'queue_unavailable');
        }
        return items.isEmpty ? null : jsonEncode(items);
      case 'acknowledgeSharedMessage':
        final id = (call.arguments as Map)['payloadId'] as String;
        if (ackFailures > 0) {
          ackFailures--;
          return false;
        }
        acked.add(id);
        items.removeWhere((i) => i['id'] == id);
        return true;
      case 'authorizeCaptureUpload':
        return uploadDecision == 'allowed'
            ? {
                'decision': 'allowed',
                'ownerUid': 'user-A',
                'ownerGeneration': 1,
                'allowAi': true,
              }
            : {'decision': uploadDecision};
      default:
        return null;
    }
  }
}

/// The three capture endpoints, in memory.
class _FakeServer {
  /// Rows `sync-captures` lists (unacked).
  final List<Map<String, Object?>> rows = [];
  final acked = <String>[];
  final uploads = <String>[];
  final aiRequests = <String>[];

  /// HTTP status for `sync-captures` (200 = healthy).
  int syncStatus = 200;

  /// What an accepted upload turns into: a row builder, or null for "still
  /// analysing" (202, nothing listed).
  Map<String, Object?>? Function(String payloadId)? analyse;

  /// HTTP status for `process-ios-sms` (2xx accepted).
  int uploadStatus = 200;

  /// `parse-sms`: true = network down (SocketException).
  bool aiOffline = false;
  int aiStatus = 200;
  Map<String, Object?> aiBody = const {'is_transaction': false};

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.url.path.endsWith('/sync-captures')) {
      if (syncStatus != 200) return http.Response('{}', syncStatus);
      final acks = (body['ackPayloadIds'] as List).cast<String>();
      acked.addAll(acks);
      rows.removeWhere((r) => acks.contains(r['payload_id']));
      return http.Response(jsonEncode({'captures': rows}), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    if (request.url.path.endsWith('/process-ios-sms')) {
      final id = body['payloadId'] as String;
      uploads.add(id);
      if (uploadStatus < 200 || uploadStatus >= 300) {
        return http.Response('{}', uploadStatus);
      }
      final row = analyse?.call(id);
      if (row != null && !rows.any((r) => r['payload_id'] == id)) rows.add(row);
      return http.Response('{}', uploadStatus);
    }
    if (request.url.path.endsWith('/parse-sms')) {
      aiRequests.add(body['sanitized_sms'] as String);
      if (aiOffline) throw const SocketException('offline');
      return http.Response(jsonEncode(aiBody), aiStatus,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }
    return http.Response('{}', 404);
  }
}

// Synthetic messages.
const _purchase = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';
const _purchaseNoTime = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nالرصيد:SAR 2,310.50';
const _unparseable = 'Your transaction could not be completed. Call us.';
const _otp = 'Your OTP is 123456. Do not share it. SAR 50.00';

String _purchaseOf(int amount) =>
    'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR $amount.00\n'
    'لدى:SHOP\nفي:2026-04-08 12:45\nالرصيد:SAR 9,000.00';

const _aiTransaction = <String, Object?>{
  'is_transaction': true,
  'amount': 45.0,
  'amount_text': '45.00',
  'currency': 'SAR',
  'merchant_name': 'NETFLIX',
  'type': 'payment',
  'direction': 'debit',
  'category_key': 'subscriptions',
  'model_used': 'test-model',
};

Map<String, Object?> _processedRow(String id) => {
      'payload_id': id,
      'status': 'processed',
      'parsed': {
        'amount': 45.0,
        'amount_text': '45.00',
        'currency': 'SAR',
        'direction': 'debit',
        'type': 'payment',
        'merchant': 'NETFLIX',
        'occurredAt': '2026-04-08T09:45:00.000Z',
        'rawMessage': 'sanitized purchase',
        'parserSource': 'ai',
        'confidence': 0.95,
      },
      'notification': <String, Object?>{},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late DriftUserSettingsRepository settings;
  late _NativeQueue native;
  late _FakeServer server;
  late CaptureSyncService sync;
  late DateTime now;
  late Map<String, bool> flags;
  late List<String> localNotifications;

  Future<void> consent({required bool cloud, required bool ai}) async =>
      settings.saveSettings((await settings.getSettings()).copyWith(
        cloudConsentState: cloud ? ConsentState.accepted : ConsentState.declined,
        aiConsentState: ai ? ConsentState.accepted : ConsentState.declined,
      ));

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    settings = DriftUserSettingsRepository(db);
    await consent(cloud: true, ai: true);
    native = _NativeQueue();
    server = _FakeServer();
    now = DateTime.utc(2026, 5, 1, 8);
    flags = {};
    localNotifications = [];
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() async {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
    await db.close();
  });

  /// Builds the production object graph over the fakes. [android] selects the
  /// platform shape: no native upload pipeline.
  LegacyCaptureDrain build({required bool android}) {
    final httpClient = MockClient(server.handle);
    final txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    final ledger = CaptureRetryLedger(now: () => now);
    sync = CaptureSyncService(
      settingsRepository: settings,
      transactionRepository: txRepo,
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(),
      currentUserId: () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      client: CaptureBackendClient(
        supabaseUrl: 'https://example.supabase.co',
        anonKey: 'anon',
        httpClient: httpClient,
      ),
      backendConfigured: true,
      loadInstallId: () async => 'install-id',
      retryLedger: ledger,
      lookupNativeCapture: (id) async {
        for (final m in await NativeCaptureBridge.peekPendingSharedMessages()) {
          if (m.id == id) return m;
        }
        return null;
      },
    );
    final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      aiClient: SupabaseAiParserClient(
        edgeFunctionUrl: 'https://example.supabase.co/functions/v1/parse-sms',
        getAnonJwt: () async => 'jwt',
        httpClient: httpClient,
      ),
      // Exactly the production wiring: both read fresh at call time.
      loadAiConsent: () async => ConsentAuthority.decide(
          EgressClass.aiProcessing, await settings.getSettings()),
      aiPrimarySelected: () async {
        final s = await settings.getSettings();
        return s.cloudProcessingEnabled && s.aiConsentGranted;
      },
      findSameTextCapture: txRepo.findSameTextCapture,
      installId: 'install',
    ));
    return LegacyCaptureDrain(
      captureSync: sync,
      ingest: ingest,
      loadSettings: settings.getSettings,
      retryLedger: ledger,
      flag: (key) => flags[key] ?? (key == 'android_capture_ai_enabled'),
      ownershipGuard: _Guard(),
      uploadsNatively: () => !android,
      aiAvailable: () => true,
    );
  }

  Future<LegacyDrainReport> run(LegacyCaptureDrain drain) => drain.run(
        showLocalReview: (item) async =>
            localNotifications.add(item.message.id ?? ''),
      );

  Future<List<String>> transactions() async => (await db
          .customSelect('SELECT id, status FROM transactions ORDER BY rowid;')
          .get())
      .map((r) => '${r.read<String>('id')}:${r.read<String>('status')}')
      .toList();

  Future<List<Map<String, Object?>>> reviewRows() async => (await db
          .customSelect(
              'SELECT id, body, metadata_json FROM smart_inbox_items ORDER BY id;')
          .get())
      .map((r) => r.data)
      .toList();

  String? reasonOf(Map<String, Object?> row) =>
      (jsonDecode(row['metadata_json']! as String) as Map)['review_reason']
          as String?;

  Future<int> suspectedDuplicates() async => (await db
          .customSelect('SELECT COUNT(*) c FROM suspected_duplicates;')
          .getSingle())
      .read<int>('c');

  group('Android automatic AI (consent + Cloud/AI settings permit it)', () {
    test('an SMS is analysed by AI: one sanitized request, one transaction',
        () async {
      // A synthetic phone number the sanitizer must redact before egress.
      native.add('and-1', '$_purchase\nللاستفسار 0551234567');
      server.aiBody = _aiTransaction;
      await run(build(android: true));
      expect(server.aiRequests, hasLength(1));
      expect(server.aiRequests.single, isNot(contains('0551234567')),
          reason: 'the outgoing text is sanitized');
      expect(server.aiRequests.single, contains('[PHONE]'));
      expect(server.uploads, isEmpty, reason: 'Android never uses the relay');
      expect(await transactions(), ['and-1:confirmed']);
      expect(native.acked, ['and-1']);
    });

    test(
        'offline recovery: the AI request fails, the item STAYS queued, and a '
        'later drain imports it exactly once', () async {
      native.add('and-2', _purchase);
      server
        ..aiOffline = true
        ..aiBody = _aiTransaction;
      final drain = build(android: true);

      await run(drain);
      expect(native.items, hasLength(1), reason: 'not acknowledged');
      expect(await transactions(), isEmpty);
      expect(await reviewRows(), isEmpty,
          reason: 'a temporary failure is not parked on the first attempt');
      final attempts = server.aiRequests.length;
      expect(attempts, greaterThan(0));

      // Connectivity is back, but the retry is not due yet: nothing is sent.
      server.aiOffline = false;
      await run(drain);
      expect(server.aiRequests, hasLength(attempts),
          reason: 'restored connectivity alone does not trigger a send');
      expect(native.items, hasLength(1));

      now = now.add(const Duration(seconds: 31));
      await run(drain);
      expect(await transactions(), ['and-2:confirmed'],
          reason: 'exactly one transaction, id == payload id');
      expect(server.aiRequests, hasLength(attempts + 1));
      expect(native.items, isEmpty);

      await run(drain);
      expect(await transactions(), hasLength(1));
    });

    test('consent revoked between the failed attempt and the retry: no AI',
        () async {
      native
        ..add('and-3', _purchase)
        ..add('and-4', _unparseable);
      server.aiOffline = true;
      final drain = build(android: true);
      await run(drain);
      expect(native.items, hasLength(2));
      final before = server.aiRequests.length;

      await consent(cloud: true, ai: false);
      server.aiOffline = false;
      now = now.add(const Duration(seconds: 31));
      await run(drain);
      expect(server.aiRequests, hasLength(before),
          reason: 'a revoked consent never re-sends');
      expect(await transactions(), ['and-3:confirmed'],
          reason: 'parsed on device');
      expect((await reviewRows()).single['id'], 'local_capture:and-4');
      expect(native.items, isEmpty);
    });

    test('an unreachable AI is tried once per drain, not once per message',
        () async {
      native
        ..add('and-10', _purchaseOf(21))
        ..add('and-11', _purchaseOf(22))
        ..add('and-12', _purchaseOf(23));
      server.aiOffline = true;
      await run(build(android: true));
      expect(server.aiRequests.toSet(), hasLength(1),
          reason: 'only the first message was sent; the rest wait');
      expect(native.items, hasLength(3));
      expect(await reviewRows(), isEmpty);
    });

    test('a 429 from AI backs the item off for at least an hour', () async {
      native.add('and-13', _purchase);
      server
        ..aiStatus = 429
        ..aiBody = const {'error': 'rate_limit_exceeded'};
      final drain = build(android: true);
      await run(drain);
      final sent = server.aiRequests.length;
      server
        ..aiStatus = 200
        ..aiBody = _aiTransaction;
      now = now.add(const Duration(minutes: 59));
      await run(drain);
      expect(server.aiRequests, hasLength(sent));
      now = now.add(const Duration(minutes: 2));
      await run(drain);
      expect(await transactions(), ['and-13:confirmed']);
    });

    test('an OTP from a non-bank sender is never sent to AI', () async {
      native.add('and-14', _otp, sender: '+966500000000');
      await run(build(android: true));
      expect(server.aiRequests, isEmpty);
      expect(native.acked, ['and-14']);
    });

    test('Cloud processing off: zero requests of any kind, parsed on device',
        () async {
      await consent(cloud: false, ai: true);
      native.add('and-5', _purchase);
      await run(build(android: true));
      expect(server.aiRequests, isEmpty);
      expect(server.uploads, isEmpty);
      expect(await transactions(), hasLength(1));
    });

    test('the operator kill switch keeps Android on device', () async {
      flags['android_capture_ai_enabled'] = false;
      native.add('and-6', _purchase);
      await run(build(android: true));
      expect(server.aiRequests, isEmpty);
      expect(await transactions(), ['and-6:confirmed']);
    });

    test('a spent retry budget ends as a retryable Smart Inbox row', () async {
      native.add('and-7', _purchase);
      server.aiOffline = true;
      final drain = build(android: true);
      for (var i = 0; i < CaptureRetryLedger.maxAttempts; i++) {
        await run(drain);
        now = now.add(const Duration(hours: 7));
      }
      final row = (await reviewRows()).single;
      expect(row['body'], _purchase);
      expect(reasonOf(row), SmartInboxReviewReason.analysisUnavailable);
      expect(native.items, isEmpty);
      expect(await transactions(), isEmpty);
    });

    test('an AI "not a transaction" verdict becomes a review row', () async {
      native.add('and-8', _purchase);
      await run(build(android: true));
      expect((await reviewRows()).single['body'], _purchase);
      expect(native.acked, ['and-8']);
    });

    test('an OTP never reaches AI and is dropped by the deterministic filter',
        () async {
      native.add('and-9', _otp);
      await run(build(android: true));
      expect(server.aiRequests, isEmpty);
      expect(await reviewRows(), isEmpty);
      expect(native.acked, ['and-9']);
    });
  });

  group('iOS captures the server never received', () {
    test('a Share Extension item is uploaded with its own payload id', () async {
      native.add('ios-share', _purchase, status: 'pending');
      server.analyse = _processedRow;
      await run(build(android: false));
      expect(server.uploads, ['ios-share']);
      expect(server.aiRequests, isEmpty, reason: 'no second AI path');
      expect(await transactions(), ['ios-share:confirmed']);
      expect(native.acked, ['ios-share']);
    });

    test('a `.waiting` item (stored as sent, never uploaded) is uploaded',
        () async {
      native.add('ios-waiting', _purchase, status: 'sent');
      server.analyse = _processedRow;
      await run(build(android: false));
      expect(server.uploads, ['ios-waiting']);
      expect(await transactions(), ['ios-waiting:confirmed']);
    });

    test('a localOnly item never leaves the device', () async {
      native.add('ios-local', _purchase, status: 'sent', localOnly: true);
      await run(build(android: false));
      expect(server.uploads, isEmpty);
      expect(server.aiRequests, isEmpty);
      expect(await transactions(), ['ios-local:confirmed']);
    });

    test('the native gate refusing the upload means on-device, not review',
        () async {
      native
        ..uploadDecision = 'localOnly'
        ..add('ios-denied', _purchase, status: 'pending');
      await run(build(android: false));
      expect(server.uploads, isEmpty);
      expect(await transactions(), ['ios-denied:confirmed']);
      expect(await reviewRows(), isEmpty);
    });

    test('an upload still being analysed waits; it is imported once listed',
        () async {
      native.add('ios-202', _purchase, status: 'pendingSend');
      server.uploadStatus = 202;
      final drain = build(android: false);
      await run(drain);
      expect(native.items, hasLength(1));
      expect(await reviewRows(), isEmpty);

      server.rows.add(_processedRow('ios-202'));
      await run(drain); // inside the backoff: the relay result still imports
      expect(await transactions(), ['ios-202:confirmed']);
      expect(native.items, isEmpty);
      expect(server.uploads, hasLength(1));
    });

    test('a terminal 409 is resolved on device and never re-requested',
        () async {
      native.add('ios-409', _purchase, status: 'pendingSend');
      server.uploadStatus = 409;
      final drain = build(android: false);
      await run(drain);
      expect(await transactions(), ['ios-409:confirmed']);
      expect(native.acked, ['ios-409']);
      await run(drain);
      expect(server.uploads, hasLength(1));
    });

    test('relay outage: a sent item waits instead of being parked', () async {
      native.add('ios-sent', _purchase, status: 'sent');
      server.syncStatus = 503;
      final drain = build(android: false);
      await run(drain);
      expect(native.items, hasLength(1));
      expect(await reviewRows(), isEmpty);
      expect(server.uploads, isEmpty);

      server
        ..syncStatus = 200
        ..rows.add(_processedRow('ios-sent'));
      await run(drain);
      expect(await transactions(), ['ios-sent:confirmed']);
    });
  });

  group('AI rejection without returned text', () {
    Map<String, Object?> ignoredNoText(String id) => {
          'payload_id': id,
          'status': 'rejected',
          'parsed': {'parserSource': 'ai_ignored'},
          'notification': <String, Object?>{},
          'sanitized_text': null,
          'failure_reason': 'not_parseable',
        };

    test('the native full text becomes the review row; then the server ACK',
        () async {
      native.add('ios-ign', _purchase, status: 'sent');
      server.rows.add(ignoredNoText('ios-ign'));
      final drain = build(android: false);
      await run(drain);
      final row = (await reviewRows()).single;
      expect(row['id'], 'local_capture:ios-ign');
      expect(row['body'], _purchase, reason: 'never a placeholder');
      expect(native.acked, ['ios-ign']);
      expect(server.acked, isEmpty,
          reason: 'no server ACK before the local row exists');
      expect(server.uploads, isEmpty);

      await run(drain);
      expect(server.acked, ['ios-ign']);
    });

    test('an OTP the server ignored without text is still just ignored',
        () async {
      native.add('ios-otp', _otp, status: 'sent');
      server.rows.add(ignoredNoText('ios-otp'));
      await run(build(android: false));
      expect(await reviewRows(), isEmpty);
      expect(native.acked, ['ios-otp']);
    });

    test('a rejected result without any text never becomes a placeholder row',
        () async {
      native.add('ios-exh', _purchase, status: 'pendingSend');
      server.rows.add({
        'payload_id': 'ios-exh',
        'status': 'rejected',
        'parsed': <String, Object?>{},
        'notification': <String, Object?>{},
        'failure_reason': 'attempts_exhausted',
      });
      await run(build(android: false));
      final row = (await reviewRows()).single;
      expect(row['body'], _purchase);
      expect(reasonOf(row), SmartInboxReviewReason.analysisUnavailable);
      expect(native.acked, ['ios-exh']);
    });
  });

  group('duplicates', () {
    test('the same capture re-delivered (ack lost) yields one transaction',
        () async {
      await consent(cloud: false, ai: false);
      native
        ..add('sms-1', _purchase)
        ..ackFailures = 1;
      final drain = build(android: true);
      await run(drain);
      expect(native.items, hasLength(1), reason: 'the ack did not land');
      await run(drain);
      expect(await transactions(), ['sms-1:confirmed']);
      expect(await suspectedDuplicates(), 0);
      expect(native.items, isEmpty);
    });

    test(
        'the same text through two paths (no time in the body): both kept, '
        'the later one flagged for review', () async {
      await consent(cloud: false, ai: false);
      native
        ..add('via-sms', _purchaseNoTime,
            receivedAt: DateTime.utc(2026, 4, 8, 9, 45))
        ..add('via-share', _purchaseNoTime,
            receivedAt: DateTime.utc(2026, 4, 8, 9, 46, 30));
      await run(build(android: true));
      expect(await transactions(), ['via-sms:confirmed'],
          reason: 'never auto-merged into, never a second confirmed row');
      expect(await suspectedDuplicates(), 1,
          reason: 'the later capture is preserved as a possible duplicate');
      expect(native.acked, ['via-sms', 'via-share']);
      expect(await sync.transactionIdForPayload('via-share'), 'via-sms');
    });

    test('two different purchases are two transactions, nothing flagged',
        () async {
      await consent(cloud: false, ai: false);
      native
        ..add('p-1', _purchaseOf(11))
        ..add('p-2', _purchaseOf(12));
      await run(build(android: true));
      expect(await transactions(), hasLength(2));
      expect(await suspectedDuplicates(), 0);
    });
  });

  group('queue beyond the old bound', () {
    test('every capture past 200 is drained into its own transaction',
        () async {
      await consent(cloud: false, ai: false);
      for (var i = 1; i <= 205; i++) {
        native.add('bulk-$i', _purchaseOf(1000 + i));
      }
      final report = await run(build(android: true));
      expect(report.queued, 205);
      expect(await transactions(), hasLength(205));
      expect(native.items, isEmpty);
    });
  });

  group('read and write failures', () {
    test('a peek error is an error: nothing acked or written, then recovery',
        () async {
      await consent(cloud: false, ai: false);
      native
        ..add('r-1', _purchase)
        ..peekFails = true;
      final drain = build(android: true);
      final failed = await run(drain);
      expect(failed.readFailed, isTrue,
          reason: 'a failed read must not look like an empty queue');
      expect(native.calls, isNot(contains('acknowledgeSharedMessage')));
      expect(await transactions(), isEmpty);
      expect(await reviewRows(), isEmpty);
      expect(native.items, hasLength(1), reason: 'storage untouched');

      native.peekFails = false;
      final ok = await run(drain);
      expect(ok.readFailed, isFalse);
      expect(await transactions(), ['r-1:confirmed']);
    });

    test('a local commit failure is never acknowledged as saved', () async {
      await consent(cloud: false, ai: false);
      native.add('w-1', _purchase);
      await db.customStatement('''
        CREATE TRIGGER fail_capture_receipt BEFORE INSERT ON dedup_hashes
        WHEN NEW.hash = 'capture_payload:w-1'
        BEGIN SELECT RAISE(ABORT, 'disk_full'); END;
      ''');
      final drain = build(android: true);
      await run(drain);
      expect(native.acked, isEmpty);
      expect(native.items, hasLength(1));
      expect(await transactions(), isEmpty,
          reason: 'the transaction rolled back with its receipt');

      await db.customStatement('DROP TRIGGER fail_capture_receipt;');
      now = now.add(const Duration(minutes: 2));
      await run(drain);
      expect(await transactions(), ['w-1:confirmed']);
      expect(native.acked, ['w-1']);
    });
  });
}
