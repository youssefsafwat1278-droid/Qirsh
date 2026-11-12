// Duplicate handling by stable capture identity, and the account-identity
// re-check before every external AI request — behavioural tests that execute
// the REAL AddTransactionUseCase / IngestCapturedMessageUseCase /
// CaptureSyncService (legacy relay import) / CaptureImportService (v3) /
// LegacyCaptureDrain on a real Drift database (in memory, or a temp FILE shared
// by two connections for the concurrency cases). Only the network (package:http
// MockClient), the native queue and the AI client are fakes. All messages are
// synthetic; nothing leaves the process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
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
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
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

/// Counts every external AI request; answers "no transaction".
class _SpyAi implements AiParserClient {
  final requests = <String>[];

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    requests.add(sanitizedSms);
    return null;
  }
}

/// `sync-captures` in memory. [ackLost] keeps acknowledged rows listed, like a
/// server whose ACK never landed.
class _RelayServer {
  final rows = <Map<String, Object?>>[];
  final acked = <String>[];
  bool ackLost = false;

  Future<http.Response> handle(http.Request request) async {
    if (!request.url.path.endsWith('/sync-captures')) {
      return http.Response('{}', 404);
    }
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final acks = ((body['ackPayloadIds'] as List?) ?? const []).cast<String>();
    acked.addAll(acks);
    if (!ackLost) rows.removeWhere((r) => acks.contains(r['payload_id']));
    return http.Response(jsonEncode({'captures': rows}), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
  }
}

// Synthetic messages. The body carries no time: identity is uncertain.
const _noTime = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nالرصيد:SAR 2,310.50';
// The body carries the bank's own time: an exact comparison instant.
const _withTime = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nفي:2026-04-08 12:45\nالرصيد:SAR 2,310.50';

final _t0 = DateTime.utc(2026, 4, 8, 9, 45);

/// A server (relay) result for one capture.
Map<String, Object?> _serverRow(
  String id, {
  required DateTime at,
  String text = 'شراء NETFLIX مبلغ SAR 45.00 بطاقة 4521',
  String source = 'received_at',
}) =>
    {
      'payload_id': id,
      'status': 'processed',
      'parsed': {
        'amount': 45.0,
        'amount_text': '45.00',
        'currency': 'SAR',
        'direction': 'debit',
        'type': 'payment',
        'merchant': 'NETFLIX',
        'last4': '4521',
        'occurredAt': at.toIso8601String(),
        'comparisonTimestamp': at.toIso8601String(),
        'comparisonTimestampSource': source,
        'rawMessage': text,
        'parserSource': 'ai',
        'confidence': 0.95,
      },
      'notification': <String, Object?>{},
    };

/// One Drift connection plus the production object graph over it.
class _Conn {
  _Conn(this.db, {http.Client? httpClient}) {
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    settings = DriftUserSettingsRepository(db);
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
      client: httpClient == null
          ? null
          : CaptureBackendClient(
              supabaseUrl: 'https://example.supabase.co',
              anonKey: 'anon',
              httpClient: httpClient,
            ),
      backendConfigured: httpClient != null,
      loadInstallId: () async => 'install',
    );
  }

  final AppDatabase db;
  late final DriftTransactionRepository txRepo;
  late final DriftUserSettingsRepository settings;
  late final CaptureSyncService sync;

  AddTransactionUseCase useCase({
    AiParserClient? ai,
    Future<bool> Function()? consent,
    Future<bool> Function()? aiPrimarySelected,
    Future<Object?> Function()? identity,
  }) =>
      AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        findSameTextCapture: txRepo.findSameTextCapture,
        aiClient: ai,
        loadAiConsent: consent,
        aiPrimarySelected: aiPrimarySelected,
        loadAccountIdentity: identity,
        installId: 'install',
      );

  Future<AddTransactionResult> ingest(
    String id,
    String text,
    DateTime receivedAt, {
    AddTransactionUseCase? with_,
  }) =>
      (with_ ?? useCase())(
        rawMessage: text,
        senderId: 'SNB',
        smsReceivedAt: receivedAt,
        onDeviceOnly: true,
        capture: sync.captureCommitFor(id),
      );

  Future<List<String>> txIds() async =>
      (await db.customSelect('SELECT id FROM transactions ORDER BY rowid;').get())
          .map((r) => r.read<String>('id'))
          .toList();

  Future<int> count(String table) async => (await db
          .customSelect('SELECT COUNT(*) c FROM $table;')
          .getSingle())
      .read<int>('c');

  Future<List<String>> suspectedFor() async => (await db
          .customSelect('SELECT id, existing_transaction_id e '
              'FROM suspected_duplicates ORDER BY id;')
          .get())
      .map((r) => '${r.read<String>('id')}->${r.read<String>('e')}')
      .toList();
}

Future<AppDatabase> _memoryDb() => AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );

void _busyTimeout(dynamic database) =>
    database.execute('PRAGMA busy_timeout = 5000;');

/// A real database FILE opened by [n] independent connections, each on its
/// own background isolate — the shape of a foreground engine and a background
/// drain engine with their own AppDatabase on the same SQLite file.
Future<List<AppDatabase>> _fileConnections(Directory dir, int n) async {
  final file = File('${dir.path}/shared.sqlite');
  final dbs = <AppDatabase>[];
  for (var i = 0; i < n; i++) {
    dbs.add(await AppDatabase.open(
      executor: NativeDatabase.createInBackground(file, setup: _busyTimeout),
      keyStore: _MemoryKeyStore(),
      runMigrations: i == 0,
    ));
  }
  return dbs;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Two AppDatabase objects on one FILE is the scenario under test here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  group('local processing (AddTransactionUseCase, stable capture ids)', () {
    late _Conn c;
    setUp(() async => c = _Conn(await _memoryDb()));
    tearDown(() => c.db.close());

    test('proven redelivery (same capture id): one transaction, no review',
        () async {
      final first = await c.ingest('sms-1', _noTime, _t0);
      // The same SMS re-delivered after the ack was lost, much later.
      final again =
          await c.ingest('sms-1', _noTime, _t0.add(const Duration(days: 9)));
      expect(first.outcome, AddTransactionOutcome.added);
      expect(again.outcome, AddTransactionOutcome.duplicate);
      expect(again.transaction!.id, 'sms-1');
      expect(await c.txIds(), ['sms-1']);
      expect(await c.count('suspected_duplicates'), 0,
          reason: 'a proven redelivery is not review noise');
    });

    test(
        'redelivery of a capture that became a suspected duplicate: still '
        'one transaction and ONE review item', () async {
      await c.ingest('via-sms', _noTime, _t0);
      final share = await c.ingest(
          'via-share', _noTime, _t0.add(const Duration(minutes: 2)));
      expect(share.outcome, AddTransactionOutcome.suspiciousDuplicate);
      final redelivered = await c.ingest(
          'via-share', _noTime, _t0.add(const Duration(minutes: 3)));
      expect(redelivered.outcome, AddTransactionOutcome.duplicate);
      expect(await c.txIds(), ['via-sms']);
      expect(await c.suspectedFor(), ['via-share->via-sms']);
    });

    test(
        'two calls for the same capture at once on one connection: one '
        'transaction, both calls succeed', () async {
      final results = await Future.wait([
        c.ingest('sms-2', _noTime, _t0),
        c.ingest('sms-2', _noTime, _t0),
      ]);
      expect(results.map((r) => r.transaction?.id), ['sms-2', 'sms-2']);
      expect(results.map((r) => r.outcome).toSet(),
          {AddTransactionOutcome.added, AddTransactionOutcome.duplicate});
      expect(await c.txIds(), ['sms-2']);
      expect(await c.count('suspected_duplicates'), 0);
    });

    test(
        'identical text, separate purchases INSIDE 72 h: both preserved, the '
        'later one in review (never a second confirmed row)', () async {
      await c.ingest('p-1', _noTime, _t0);
      final later = await c.ingest(
          'p-2', _noTime, _t0.add(const Duration(hours: 71)));
      expect(later.outcome, AddTransactionOutcome.suspiciousDuplicate);
      expect(await c.txIds(), ['p-1']);
      expect(await c.suspectedFor(), ['p-2->p-1'],
          reason: 'the later capture is kept, as a suspected duplicate');
    });

    test(
        'identical text, separate purchases BEYOND 72 h: two transactions, '
        'nothing flagged (the text match is no longer a signal)', () async {
      await c.ingest('p-1', _noTime, _t0);
      final later = await c.ingest(
          'p-2', _noTime, _t0.add(const Duration(hours: 73)));
      expect(later.outcome, AddTransactionOutcome.added);
      expect(await c.txIds(), ['p-1', 'p-2']);
      expect(await c.count('suspected_duplicates'), 0);
    });

    test(
        'stronger identity applies beyond 72 h: the same bank timestamp in '
        'the body is still flagged days later', () async {
      await c.ingest('t-1', _withTime, _t0);
      final later =
          await c.ingest('t-2', _withTime, _t0.add(const Duration(days: 5)));
      expect(later.outcome, AddTransactionOutcome.suspiciousDuplicate);
      expect(await c.txIds(), ['t-1']);
      expect(await c.suspectedFor(), ['t-2->t-1']);
    });
  });

  group('two connections to one SQLite file (foreground + background engine)',
      () {
    late Directory dir;
    late List<AppDatabase> dbs;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('dup_identity_');
      dbs = await _fileConnections(dir, 2);
    });
    tearDown(() async {
      for (final db in dbs) {
        await db.close();
      }
      await dir.delete(recursive: true);
    });

    test('the same capture ingested concurrently: exactly one transaction',
        () async {
      final a = _Conn(dbs[0]);
      final b = _Conn(dbs[1]);
      for (var round = 0; round < 5; round++) {
        final id = 'race-$round';
        final results = await Future.wait([
          a.ingest(id, _noTime, _t0.add(Duration(days: 4 * round))),
          b.ingest(id, _noTime, _t0.add(Duration(days: 4 * round))),
        ]);
        expect(results.every((r) => r.transaction?.id == id), isTrue,
            reason: 'neither call fails; both report the one transaction');
      }
      expect(await a.txIds(), [for (var i = 0; i < 5; i++) 'race-$i']);
      expect(await b.count('suspected_duplicates'), 0);
    });

    test(
        'the same server capture imported concurrently by two relay syncs: '
        'one transaction, neither run reports a failure', () async {
      final server = _RelayServer()..rows.add(_serverRow('srv-1', at: _t0));
      final a = _Conn(dbs[0], httpClient: MockClient(server.handle));
      final b = _Conn(dbs[1], httpClient: MockClient(server.handle));
      await a.settings.saveSettings((await a.settings.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));
      server.ackLost = true; // both runs see the row
      final reports = await Future.wait([a.sync.sync(), b.sync.sync()]);
      expect(await a.txIds(), ['srv-1']);
      for (final r in reports) {
        expect(r.failedPayloadIds, isEmpty);
        expect(r.importedPayloadIds, {'srv-1'});
      }
    });
  });

  group('iOS server-result imports (legacy relay path)', () {
    late _Conn c;
    late _RelayServer server;
    setUp(() async {
      server = _RelayServer();
      c = _Conn(await _memoryDb(), httpClient: MockClient(server.handle));
      await c.settings.saveSettings((await c.settings.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));
    });
    tearDown(() => c.db.close());

    test(
        'the same server capture listed again (ACK lost, later sync): one '
        'transaction, no review noise', () async {
      server
        ..ackLost = true
        ..rows.add(_serverRow('srv-1', at: _t0));
      await c.sync.sync();
      await c.sync.sync();
      await c.sync.sync();
      expect(await c.txIds(), ['srv-1']);
      expect(await c.count('suspected_duplicates'), 0);
      expect(server.acked.where((id) => id == 'srv-1'), hasLength(3),
          reason: 'every listing is acknowledged again, never re-imported');
    });

    test(
        'Shortcut + Share Extension: two payload ids, same text → one '
        'transaction + one suspected duplicate in review', () async {
      server.rows
        ..add(_serverRow('shortcut', at: _t0))
        ..add(_serverRow('share-ext', at: _t0.add(const Duration(minutes: 2))));
      final report = await c.sync.sync();
      expect(await c.txIds(), ['shortcut']);
      expect(await c.suspectedFor(), ['share-ext->shortcut']);
      expect(report.importedPayloadIds, {'shortcut', 'share-ext'});
      expect(await c.sync.transactionIdForPayload('share-ext'), 'shortcut');
      // Listed again: still one transaction, still one review item.
      server.rows.add(
          _serverRow('share-ext', at: _t0.add(const Duration(minutes: 2))));
      await c.sync.sync();
      expect(await c.txIds(), ['shortcut']);
      expect(await c.count('suspected_duplicates'), 1);
    });

    test(
        'identical text, separate purchases: inside 72 h the later is in '
        'review; beyond 72 h both are transactions', () async {
      server.rows
        ..add(_serverRow('p-1', at: _t0))
        ..add(_serverRow('p-2', at: _t0.add(const Duration(hours: 70))))
        ..add(_serverRow('p-3', at: _t0.add(const Duration(hours: 150))));
      await c.sync.sync();
      expect(await c.txIds(), ['p-1', 'p-3']);
      expect(await c.suspectedFor(), ['p-2->p-1']);
    });

    test(
        'stronger identity beyond 72 h: a server result at the SAME bank '
        'timestamp as an existing local capture goes to review', () async {
      await c.ingest('local-1', _withTime, _t0);
      final local = (await c.txRepo.getById('local-1'))!;
      server.rows.add({
        ..._serverRow('srv-late',
            at: local.comparisonTimestamp!, source: 'sms_body'),
        'created_at': _t0.add(const Duration(days: 6)).toIso8601String(),
      });
      await c.sync.sync();
      expect(await c.txIds(), ['local-1']);
      expect(await c.suspectedFor(), ['srv-late->local-1']);
    });

    test('a server result arriving after the local copy (same id): one row',
        () async {
      await c.ingest('same-id', _noTime, _t0);
      server.rows.add(_serverRow('same-id', at: _t0));
      final report = await c.sync.sync();
      expect(await c.txIds(), ['same-id']);
      expect(await c.count('suspected_duplicates'), 0);
      expect(report.importedPayloadIds, {'same-id'});
    });
  });

  group('iOS v3 import (CaptureImportService)', () {
    late _Conn c;
    setUp(() async => c = _Conn(await _memoryDb()));
    tearDown(() => c.db.close());

    CaptureImportService service(
      _Queue queue,
      Map<String, ProcessedCaptureDto> results,
    ) =>
        CaptureImportService(
          queue: queue,
          server: _V3Server(results),
          captureSyncService: c.sync,
          receipts: CaptureReceipts(c.db),
          ingestLocal: CaptureImportService.localIngest(
              IngestCapturedMessageUseCase(c.useCase())),
          sessionUid: () => 'user-A',
          replicaOwnerUid: () async => 'user-A',
          ownershipGuard: _Guard(),
        );

    ProcessedCaptureDto dto(String id, DateTime at) =>
        ProcessedCaptureDto.fromJson(_serverRow(id, at: at, text: _noTime));

    SharedCapturedMessage item(String id, DateTime at,
            CapturedMessageSource source) =>
        SharedCapturedMessage(
          id: id,
          text: _noTime,
          sender: 'SNB',
          source: source,
          receivedAt: at,
          status: 'sent',
          ownerUid: 'user-A',
        );

    test(
        'Shortcut + Share Extension with server results: one transaction + '
        'one suspected duplicate; a repeated run changes nothing', () async {
      final later = _t0.add(const Duration(minutes: 3));
      final queue = _Queue()
        ..items.addAll([
          item('a' * 64, _t0, CapturedMessageSource.iosShortcut),
          item('b' * 64, later, CapturedMessageSource.iosShare),
        ]);
      final results = {
        'a' * 64: dto('a' * 64, _t0),
        'b' * 64: dto('b' * 64, later),
      };
      await service(queue, results).run();
      expect(await c.txIds(), ['a' * 64]);
      expect(await c.suspectedFor(), ['${'b' * 64}->${'a' * 64}']);
      expect(queue.items, isEmpty);

      // Redelivered by the native layer and listed again by the server.
      queue.items.addAll([
        item('a' * 64, _t0, CapturedMessageSource.iosShortcut),
        item('b' * 64, later, CapturedMessageSource.iosShare),
      ]);
      await service(queue, results).run();
      expect(await c.txIds(), ['a' * 64]);
      expect(await c.count('suspected_duplicates'), 1);
    });

    test('the same server capture imported twice at once: one transaction',
        () async {
      final capture = dto('c' * 64, _t0);
      final runs = await Future.wait([
        c.sync.importServerCapture(capture, () async {}),
        c.sync.importServerCapture(capture, () async {}),
      ]);
      expect(runs, [null, null]);
      expect(await c.txIds(), ['c' * 64]);
    });
  });

  group('account identity re-check before every external AI request', () {
    late _Conn c;
    late _SpyAi ai;
    setUp(() async {
      c = _Conn(await _memoryDb());
      ai = _SpyAi();
    });
    tearDown(() => c.db.close());

    Future<AddTransactionResult> aiIngest(
      String id, {
      required Future<Object?> Function() identity,
      bool consent = true,
      bool aiPrimary = false,
    }) =>
        c.useCase(
          ai: ai,
          consent: () async => consent,
          aiPrimarySelected: () async => aiPrimary,
          identity: identity,
        )(
          rawMessage: _noTime,
          senderId: 'SNB',
          smsReceivedAt: _t0,
          capture: c.sync.captureCommitFor(id),
        );

    test('unchanged identity: the request is made (positive control)',
        () async {
      await aiIngest('ok', identity: () async => 'user-A|gen-1');
      expect(ai.requests, hasLength(1));
    });

    test(
        'the account changes between capture start and the request: no '
        'request, nothing committed, the capture can be processed later',
        () async {
      final identities = ['user-A|gen-1', 'user-B|gen-2'];
      var reads = 0;
      await expectLater(
        aiIngest('switch',
            identity: () async => identities[(reads++).clamp(0, 1)]),
        throwsA(isA<StaleOwnershipException>()),
      );
      expect(ai.requests, isEmpty);
      expect(await c.txIds(), isEmpty);
      expect(await c.count('suspected_duplicates'), 0);
      expect(await c.sync.transactionIdForPayload('switch'), isNull,
          reason: 'no receipt: the capture is not consumed');

      // Under a consistent identity the SAME capture is processed once.
      await aiIngest('switch', identity: () async => 'user-B|gen-2');
      expect(ai.requests, hasLength(1));
      expect(await c.txIds(), ['switch']);
    });

    test(
        'the replica owner is not the signed-in user (identity unavailable): '
        'no request', () async {
      await expectLater(
        aiIngest('foreign', identity: () async => null),
        throwsA(isA<StaleOwnershipException>()),
      );
      await expectLater(
        aiIngest('throws', identity: () async => throw StateError('keychain')),
        throwsA(isA<StaleOwnershipException>()),
      );
      expect(ai.requests, isEmpty);
      expect(await c.txIds(), isEmpty);
    });

    test(
        'a selected/remote AI flag never substitutes for consent: no '
        'request, and the identity is not even consulted', () async {
      var reads = 0;
      final result = await aiIngest('no-consent',
          consent: false,
          aiPrimary: true,
          identity: () async => 'user-A|${reads++}');
      expect(ai.requests, isEmpty);
      expect(result.aiFailureReason, 'consent_off');
      expect(reads, 1, reason: 'read once at start; no request to guard');
    });

    test(
        'through the real drain: the capture stays queued (not acked) and is '
        'imported exactly once after the identity is consistent again',
        () async {
      await c.settings.saveSettings((await c.settings.getSettings()).copyWith(
        cloudConsentState: ConsentState.accepted,
        aiConsentState: ConsentState.accepted,
      ));
      final queue = <SharedCapturedMessage>[
        SharedCapturedMessage(
          id: 'drain-1',
          text: _noTime,
          sender: 'SNB',
          source: CapturedMessageSource.unknown,
          receivedAt: _t0,
        ),
      ];
      final acked = <String>[];
      var identity = 'user-A|gen-1';
      var flipOnRead = true;
      LegacyCaptureDrain drain() => LegacyCaptureDrain(
            captureSync: c.sync,
            ingest: IngestCapturedMessageUseCase(c.useCase(
              ai: ai,
              consent: () async => ConsentAuthority.decide(
                  EgressClass.aiProcessing, await c.settings.getSettings()),
              identity: () async {
                final now = identity;
                // A sign-out/account switch lands right after the capture
                // started (first read), before the AI request (second read).
                if (flipOnRead) identity = 'user-B|gen-2';
                return now;
              },
            )),
            loadSettings: c.settings.getSettings,
            retryLedger: CaptureRetryLedger(now: () => _t0),
            flag: (key) => key == 'android_capture_ai_enabled',
            ownershipGuard: _Guard(),
            peek: () async => List.of(queue),
            acknowledge: (id) async {
              acked.add(id);
              queue.removeWhere((m) => m.id == id);
              return true;
            },
            uploadsNatively: () => false,
            aiAvailable: () => true,
          );

      final stopped = await drain().run();
      expect(stopped.stopped, isTrue);
      expect(ai.requests, isEmpty, reason: 'no request under a changed account');
      expect(acked, isEmpty);
      expect(queue, hasLength(1), reason: 'the capture is kept, recoverable');
      expect(await c.txIds(), isEmpty);

      flipOnRead = false;
      await drain().run();
      expect(ai.requests, hasLength(1));
      expect(await c.txIds(), ['drain-1']);
      expect(acked, ['drain-1']);
    });
  });
}

class _Queue implements CaptureImportQueue {
  final items = <SharedCapturedMessage>[];

  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);

  @override
  Future<bool> acknowledge(String payloadId) async {
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _V3Server implements CaptureServerPort {
  _V3Server(this.results);
  final Map<String, ProcessedCaptureDto> results;

  @override
  Future<CaptureServerFetch> fetchResults() async =>
      CaptureServerFetch(CaptureFetchStatus.ok, Map.of(results));

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async =>
      CaptureUploadStatus.unavailable;

  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}
