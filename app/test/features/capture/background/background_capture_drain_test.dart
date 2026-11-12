// Background recovery of queued captures, executed end to end: the REAL
// LegacyCaptureDrain (what AppShell runs, foreground or background-triggered),
// the real leased pass (runLeasedCaptureDrain), the real background runner and
// the real NativeCaptureBridge over a mocked `money_companion/native_capture`
// channel that models the native queue AND the process-wide drain lease; a
// fake HTTP server behind the real AI client; a real in-memory Drift DB; the
// real retry ledger over a shared durable store (fake clock). Every message is
// synthetic. No source inspection.
import 'dart:async';
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
import 'package:money_companion/features/capture/background/background_capture_drain.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_retry_ledger.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/legacy_capture_drain.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../../../domain/local_v2_support.dart';

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

/// The stored admission; [current] changes on sign-out / account switch.
class _Guard extends OwnershipGuard {
  static AdmissionToken current =
      const AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');

  @override
  Future<AdmissionToken> capture() async => current;

  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == current;
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

  /// The PROCESS-WIDE lease (one per process, shared by every engine).
  String? leaseToken;
  int _leases = 0;

  /// `scheduleBackgroundCaptureDrain` requests, in ms.
  final scheduled = <int>[];
  int cancelledSchedules = 0;

  /// Runs right after a capture was acknowledged.
  void Function(String id)? onAck;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call.method);
    switch (call.method) {
      case 'acquireCaptureDrainLease':
        if (leaseToken != null) return {'granted': false};
        leaseToken = 'lease-${++_leases}';
        return {'granted': true, 'token': leaseToken};
      case 'releaseCaptureDrainLease':
        final token = (call.arguments as Map)['token'];
        if (token != leaseToken) return false;
        leaseToken = null;
        return true;
      case 'scheduleBackgroundCaptureDrain':
        scheduled.add((call.arguments as Map)['delayMs'] as int);
        return null;
      case 'cancelBackgroundCaptureDrain':
        cancelledSchedules++;
        return null;
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
        onAck?.call(id);
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

  /// Every HTTP request of any kind (egress count).
  int requests = 0;

  /// Holds each `parse-sms` response until completed (a request in flight).
  Completer<void>? aiGate;

  /// Runs when a `parse-sms` request arrives (before its response).
  void Function()? onAiRequest;

  Future<http.Response> handle(http.Request request) async {
    requests++;
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
      onAiRequest?.call();
      final gate = aiGate;
      if (gate != null) await gate.future;
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
const _unparseable = 'Your transaction could not be completed. Call us.';

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


void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('money_companion/native_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late DriftUserSettingsRepository settings;
  late _NativeQueue native;
  late _FakeServer server;
  late DateTime now;

  /// The durable, process-wide store behind every engine's retry ledger.
  late MemoryCaptureRetryStore ledgerStore;

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
    server = _FakeServer()..aiBody = _aiTransaction;
    now = DateTime.utc(2026, 5, 1, 8);
    ledgerStore = MemoryCaptureRetryStore();
    _Guard.current =
        const AdmissionToken(ownerUid: 'user-A', generation: 'gen-A');
    NativeCaptureBridge.debugTreatHostAsNative = true;
    messenger.setMockMethodCallHandler(channel, native.handle);
  });

  tearDown(() async {
    NativeCaptureBridge.debugTreatHostAsNative = false;
    messenger.setMockMethodCallHandler(channel, null);
    await db.close();
  });

  /// One engine's object graph (Android shape: no native upload pipeline),
  /// exactly the production wiring over the fakes. Each call is a separate
  /// "engine": its own ledger instance (own cache) over the shared store.
  ({LegacyCaptureDrain drain, CaptureRetryLedger ledger}) engine() {
    final httpClient = MockClient(server.handle);
    final txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    final ledger = CaptureRetryLedger(store: ledgerStore, now: () => now);
    final sync = CaptureSyncService(
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
      loadAiConsent: () async => ConsentAuthority.decide(
          EgressClass.aiProcessing, await settings.getSettings()),
      aiPrimarySelected: () async {
        final s = await settings.getSettings();
        return s.cloudProcessingEnabled && s.aiConsentGranted;
      },
      findSameTextCapture: txRepo.findSameTextCapture,
      installId: 'install',
    ));
    final drain = LegacyCaptureDrain(
      captureSync: sync,
      ingest: ingest,
      loadSettings: settings.getSettings,
      retryLedger: ledger,
      flag: (key) => key == 'android_capture_ai_enabled',
      ownershipGuard: _Guard(),
      uploadsNatively: () => false,
      aiAvailable: () => true,
    );
    return (drain: drain, ledger: ledger);
  }

  /// One leased pass, exactly as AppShell runs it (lease, ledger reload, the
  /// real drain, follow-up scheduling over the native channel).
  Future<CaptureDrainPass> pass(
    ({LegacyCaptureDrain drain, CaptureRetryLedger ledger}) e, {
    bool Function()? isActive,
  }) =>
      runLeasedCaptureDrain(
        lease: CaptureDrainLease(),
        holder: 'test',
        ledger: e.ledger,
        now: () => now,
        drain: () async {
          final report = await e.drain.run(isActive: isActive);
          return CaptureDrainPass(
            stopped: report.stopped,
            authRequired: report.authRequired || report.authRequiredBeforeDrain,
            readFailed: report.readFailed,
          );
        },
      );

  /// What the OS-scheduled run does: the precondition, then one leased pass.
  BackgroundCaptureDrainRunner background(
    ({LegacyCaptureDrain drain, CaptureRetryLedger ledger}) e, {
    bool signedIn = true,
  }) {
    late BackgroundCaptureDrainRunner runner;
    runner = BackgroundCaptureDrainRunner(
      mayRun: () async => signedIn,
      pass: (isActive) => pass(e, isActive: isActive),
    );
    return runner;
  }

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

  test(
      'offline-queued capture: the foreground pass leaves it queued and asks '
      'for a background run when it is due; the background run imports it '
      'once the network is back', () async {
    native.add('bg-1', _purchase);
    server.aiOffline = true;
    final fg = engine();

    final first = await pass(fg);
    expect(native.items, hasLength(1), reason: 'not acknowledged');
    expect(await transactions(), isEmpty);
    expect(first.pendingDelay, const Duration(seconds: 30),
        reason: 'the ledger backoff, not an immediate retry');
    expect(native.scheduled, [30000]);
    expect(native.leaseToken, isNull, reason: 'the lease was released');

    // Network back; the OS runs the background drain once the item is due.
    server.aiOffline = false;
    now = now.add(const Duration(seconds: 31));
    final outcome = await background(engine()).run();
    expect(outcome, BackgroundDrainOutcome.done);
    expect(await transactions(), ['bg-1:confirmed']);
    expect(native.acked, ['bg-1']);
    expect(native.scheduled, [30000], reason: 'nothing left to schedule');
  });

  test('a background run before the item is due sends nothing', () async {
    native.add('bg-2', _purchase);
    server.aiOffline = true;
    await pass(engine());
    final sent = server.aiRequests.length;
    server.aiOffline = false;
    now = now.add(const Duration(seconds: 10));
    final outcome = await background(engine()).run();
    expect(outcome, BackgroundDrainOutcome.pending);
    expect(server.aiRequests, hasLength(sent),
        reason: 'the background run respects the backoff (no hammering)');
    expect(native.scheduled.last, 30000,
        reason: 'never shorter than the first backoff step');
  });

  test('consent revoked before the background retry: zero AI requests',
      () async {
    native
      ..add('bg-3', _purchase)
      ..add('bg-4', _unparseable);
    server.aiOffline = true;
    await pass(engine());
    final before = server.aiRequests.length;
    expect(before, greaterThan(0));

    await consent(cloud: true, ai: false);
    server.aiOffline = false;
    now = now.add(const Duration(seconds: 31));
    final outcome = await background(engine()).run();
    expect(outcome, BackgroundDrainOutcome.done);
    expect(server.aiRequests, hasLength(before),
        reason: 'a revoked consent never re-sends, in background too');
    expect(await transactions(), ['bg-3:confirmed'],
        reason: 'on-device policy: parsed locally');
    expect((await reviewRows()).single['id'], 'local_capture:bg-4');
    expect(native.items, isEmpty);
  });

  test(
      'foreground and background race for the lease: one drains, the other '
      'skips; no duplicate transaction', () async {
    native.add('bg-5', _purchase);
    final gate = Completer<void>();
    server.aiGate = gate;
    final foreground = pass(engine());
    // Wait until the foreground pass has its AI request in flight.
    while (server.aiRequests.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(native.leaseToken, isNotNull);

    // A second engine's background-triggered run arrives meanwhile.
    final outcome = await background(engine()).run();
    expect(outcome, BackgroundDrainOutcome.busy);
    expect(server.aiRequests, hasLength(1),
        reason: 'the skipped run sent nothing');
    expect(native.calls.where((c) => c == 'peekPendingSharedMessages'),
        hasLength(1),
        reason: 'the skipped run did not even read the queue');

    gate.complete();
    await foreground;
    expect(await transactions(), ['bg-5:confirmed']);

    // The retried background run finds nothing to do and duplicates nothing.
    server.aiGate = null;
    expect(await background(engine()).run(), BackgroundDrainOutcome.done);
    expect(await transactions(), ['bg-5:confirmed']);
    expect(server.aiRequests, hasLength(1));
  });

  test(
      'two engines, each with its own ledger cache: the second never retries '
      'before the backoff the first recorded', () async {
    native.add('bg-6', _purchase);
    server.aiOffline = true;
    final a = engine();
    final b = engine();
    // Engine A loads its ledger cache while nothing is recorded yet.
    expect(await a.ledger.isDue('bg-6'), isTrue);
    await pass(b); // engine B records the failure in the shared store
    final sent = server.aiRequests.length;
    server.aiOffline = false;
    now = now.add(const Duration(seconds: 5));
    await pass(a);
    expect(server.aiRequests, hasLength(sent),
        reason: 'A re-read the durable ledger under the lease');
    expect(native.items, hasLength(1));
  });

  test(
      'cancelled mid-drain: the item in flight commits and is acked, nothing '
      'else is touched; the restart recovers the rest exactly once', () async {
    // On-device route (distinct amounts parse to distinct transactions).
    await consent(cloud: false, ai: false);
    native
      ..add('bg-7', _purchaseOf(11))
      ..add('bg-8', _purchaseOf(12))
      ..add('bg-9', _purchaseOf(13));
    final runner = background(engine());
    // The OS expires the task while the first item is being finished.
    native.onAck = (_) {
      runner.cancel();
      native.onAck = null;
    };
    expect(await runner.run(), BackgroundDrainOutcome.cancelled);
    expect(await transactions(), ['bg-7:pending']);
    expect(native.acked, ['bg-7'], reason: 'acked only after its commit');
    expect(native.items.map((i) => i['id']), ['bg-8', 'bg-9'],
        reason: 'nothing after the cancel was read into the DB or acked');
    expect(native.scheduled, isNotEmpty, reason: 'the remainder is asked for');

    expect(await background(engine()).run(), BackgroundDrainOutcome.done);
    expect(await transactions(),
        ['bg-7:pending', 'bg-8:pending', 'bg-9:pending']);
    expect(native.acked, ['bg-7', 'bg-8', 'bg-9']);
    expect(server.requests, 0, reason: 'consent off: no egress at all');
  });

  test(
      'killed between commit and acknowledgement: nothing is lost and the '
      'restart does not import it twice', () async {
    native
      ..add('bg-10', _purchase)
      ..ackFailures = 1; // the process died before the native ack landed
    expect(await background(engine()).run(), BackgroundDrainOutcome.pending);
    expect(await transactions(), ['bg-10:confirmed']);
    expect(native.items, hasLength(1), reason: 'still queued natively');

    now = now.add(const Duration(minutes: 1));
    expect(await background(engine()).run(), BackgroundDrainOutcome.done);
    expect(await transactions(), ['bg-10:confirmed'], reason: 'one, not two');
    expect(server.aiRequests, hasLength(1),
        reason: 'the committed receipt is found before any new request');
  });

  test(
      'retry budget spent in background: a retryable "awaiting analysis" '
      'review row, then the capture is acknowledged', () async {
    native.add('bg-11', _purchase);
    server.aiOffline = true;
    var last = BackgroundDrainOutcome.failed;
    var perAttempt = 0;
    for (var i = 0; i < CaptureRetryLedger.maxAttempts; i++) {
      last = await background(engine()).run();
      if (i == 0) perAttempt = server.aiRequests.length;
      if (i < CaptureRetryLedger.maxAttempts - 1) {
        // A run inside the backoff window sends nothing.
        final sent = server.aiRequests.length;
        expect(
            await background(engine()).run(), BackgroundDrainOutcome.pending);
        expect(server.aiRequests, hasLength(sent));
      }
      now = now.add(const Duration(hours: 7));
    }
    expect(last, BackgroundDrainOutcome.done);
    final row = (await reviewRows()).single;
    expect(row['body'], _purchase);
    expect(reasonOf(row), SmartInboxReviewReason.analysisUnavailable);
    expect(native.items, isEmpty);
    expect(await transactions(), isEmpty);
    expect(server.aiRequests,
        hasLength(perAttempt * CaptureRetryLedger.maxAttempts),
        reason: 'requests only on due attempts, never more');
  });

  test('signed out before the background run: no egress, no write, no ack',
      () async {
    native.add('bg-12', _purchase);
    final outcome = await background(engine(), signedIn: false).run();
    expect(outcome, BackgroundDrainOutcome.deferred);
    expect(server.requests, 0);
    expect(await transactions(), isEmpty);
    expect(await reviewRows(), isEmpty);
    expect(native.acked, isEmpty);
    expect(native.calls, isEmpty,
        reason: 'not even the lease or the queue is touched');
  });

  test(
      'account switched while the background run is in flight: no write into '
      'the new account, no acknowledgement', () async {
    native
      ..add('bg-13', _purchaseOf(31))
      ..add('bg-14', _purchaseOf(32));
    server.onAiRequest = () {
      _Guard.current =
          const AdmissionToken(ownerUid: 'user-B', generation: 'gen-B');
      server.onAiRequest = null;
    };
    final outcome = await background(engine()).run();
    expect(outcome, isNot(BackgroundDrainOutcome.done));
    // The pass is bound to the database of the scope it started in (in the
    // app, the previous account's replica, closed by the switch). The item in
    // flight is NOT acknowledged under the new admission, the next one is not
    // read, sent or written.
    expect(native.acked, isEmpty);
    expect(native.items, hasLength(2));
    expect(await transactions(), isNot(contains('bg-14:confirmed')));
    expect(await reviewRows(), isEmpty);
    expect(server.aiRequests, hasLength(1),
        reason: 'nothing more is sent after the owner changed');
  });

  test('the native trigger reaches the handler; cancel reaches the run',
      () async {
    var cancelled = false;
    NativeCaptureBridge.setBackgroundDrainHandler(
      () async => BackgroundDrainOutcome.pending.name,
      cancel: () => cancelled = true,
    );
    addTearDown(() => NativeCaptureBridge.setBackgroundDrainHandler(null));
    Future<Object?> call(String method) async {
      Object? decoded;
      await messenger.handlePlatformMessage(
        'money_companion/native_capture',
        const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
        (data) => decoded = data == null
            ? null
            : const StandardMethodCodec().decodeEnvelope(data),
      );
      return decoded;
    }

    expect(await call('runBackgroundDrain'), 'pending');
    await call('cancelBackgroundDrain');
    expect(cancelled, isTrue);

    NativeCaptureBridge.setBackgroundDrainHandler(null);
    // No drain host left: native is told to stop without retrying.
    NativeCaptureBridge.setPendingMessagesHandler(() async {});
    addTearDown(() => NativeCaptureBridge.setPendingMessagesHandler(null));
    expect(await call('runBackgroundDrain'), 'deferred');
  });
}
