// Real-model evaluation, device side. Copied by real_model/run_real.sh into
// <checkout>/app/test/zz_message_eval/ of a scratch worktree and run there with
// `flutter test`; it never runs inside the working tree.
//
// Same harness as ../dart/message_eval_test.dart (fresh database per message
// and path, the checkout's REAL iOS import: CaptureImportService on Drift),
// with two paths and more detail per message:
//   local_only          Cloud/AI off: the device parser decides.
//   cloud_primary_real  the row process-ios-sms stored for the REAL model's
//                       answer (real_eval.ts), imported with AI-primary on.
// Per path: every transactions row (status, type, amount, currency,
// direction), the Smart Inbox items with their review reason, and for the
// real path the device gate's own inputs (meaning hold, ValidatedCapture
// reason, local contradiction, deterministic ignore filter).
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backend/rules_client.dart';
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
import 'package:money_companion/domain/capture/validated_capture.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';

import '../domain/local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _Registration implements CaptureDeviceRegistrationService {
  @override
  Future<bool> isLinkedForCloud() async => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Guard extends OwnershipGuard {
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async => token == _token;
}

class _Queue implements CaptureImportQueue {
  final List<SharedCapturedMessage> items = [];
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

class _Server implements CaptureServerPort {
  _Server(this.fetch);
  final CaptureServerFetch fetch;
  @override
  Future<CaptureServerFetch> fetchResults() async => fetch;
  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async =>
      CaptureUploadStatus.unavailable;
  @override
  Future<void> acknowledge(List<String> payloadIds) async {}
}

const _shard = 0;
const _shards = 1;

void main() {
  const dir = 'test/zz_message_eval';
  // A migrated, encrypted template database is created once and copied for
  // every run: opening a fresh database costs seconds (all migrations), a
  // copy well under one. Same schema, same key, same code path afterwards.
  final dbDir = Directory('$dir/db_$_shard')..createSync(recursive: true);
  final template = File('${dbDir.path}/template.db');
  final runFile = File('${dbDir.path}/run.db');
  final input = jsonDecode(File('$dir/in.json').readAsStringSync())
      as Map<String, dynamic>;
  final server = (jsonDecode(File('$dir/server.json').readAsStringSync())
      as Map<String, dynamic>)['server'] as Map<String, dynamic>;
  final all = (input['messages'] as List).cast<Map<String, dynamic>>();
  final messages = [
    for (var i = 0; i < all.length; i++)
      if (i % _shards == _shard) all[i],
  ];

  Future<Map<String, dynamic>> runPath(
    Map<String, dynamic> m, {
    Map<String, dynamic>? stored,
    bool aiPrimary = false,
    bool localOnly = false,
  }) async {
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final f = File('${runFile.path}$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    template.copySync(runFile.path);
    final db = await AppDatabase.open(
      executor: NativeDatabase(runFile),
      keyStore: _MemoryKeyStore(),
    );
    try {
      final txRepo = DriftTransactionRepository(
        db,
        outboxQueue: LedgerOutboxQueue(
          db: db,
          isPushEnabled: () => true,
          getAuthUserId: () async => 'user-A',
        ),
      );
      final sync = CaptureSyncService(
        settingsRepository: DriftUserSettingsRepository(db),
        transactionRepository: txRepo,
        dedupStore: DriftDedupStore(db),
        smartInboxRepository: DriftSmartInboxRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        registrationService: _Registration(),
        ownershipGuard: _Guard(),
        currentUserId: () => 'user-A',
        accountRepository: DriftAccountRepository(db),
        backendConfigured: true,
        loadInstallId: () async => 'install',
      );
      final rules = RulesClient(database: db);
      final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        loadBankProfiles: rules.localBankProfiles,
        loadCatalogRules: rules.catalogRulesForSender,
        installId: 'install',
      ));
      final id = (m['id'] as String).codeUnits.fold<int>(7, (h, c) => h * 31 + c)
          .toUnsigned(60)
          .toRadixString(16)
          .padLeft(64, '0');
      final results = <String, ProcessedCaptureDto>{};
      if (stored != null) {
        results[id] = ProcessedCaptureDto.fromJson({
          'payload_id': id,
          'status': stored['status'],
          'state': stored['state'],
          'parsed': stored['parsed'],
          'notification': const <String, dynamic>{},
          'failure_reason': stored['failure_reason'],
          if (stored['status'] == 'rejected') 'sanitized_text': 'redacted',
        });
      }
      final queue = _Queue();
      SharedCapturedMessage item() => SharedCapturedMessage(
            id: id,
            text: m['text'] as String,
            sender: m['sender'] as String?,
            source: CapturedMessageSource.iosShortcut,
            receivedAt: DateTime.parse(m['received_at'] as String),
            status: 'sent',
            ownerUid: 'user-A',
            localOnly: localOnly ? true : null,
          );
      CaptureImportService service() => CaptureImportService(
            queue: queue,
            server: _Server(
                CaptureServerFetch(CaptureFetchStatus.ok, results)),
            captureSyncService: sync,
            receipts: CaptureReceipts(db),
            ingestLocal: CaptureImportService.localIngest(ingest),
            sessionUid: () => 'user-A',
            replicaOwnerUid: () async => 'user-A',
            ownershipGuard: _Guard(),
            aiPrimarySelected: aiPrimary ? () async => true : null,
          );
      queue.items.add(item());
      await service().run();
      final first = await _snapshot(db);
      // Redelivery: the same capture arrives again (App Intent retry, a
      // second import pass). It must not add a second financial effect.
      queue.items.add(item());
      await service().run();
      final again = await _snapshot(db);
      return {...first, 'redelivered_confirmed': again['confirmed']};
    } catch (e) {
      return {'error': e.toString().split('\n').first};
    } finally {
      await db.close();
    }
  }

  test('real-model message evaluation (shard $_shard of $_shards)', () async {
    if (template.existsSync()) template.deleteSync();
    final seed = await AppDatabase.open(
      executor: NativeDatabase(template),
      keyStore: _MemoryKeyStore(),
    );
    await seed.customSelect('SELECT 1;').get();
    await seed.close();
    final out = <String, dynamic>{};
    final sw = Stopwatch()..start();
    for (final m in messages) {
      final entry = server[m['id']] as Map<String, dynamic>?;
      if (entry == null) continue; // not part of this run (smoke subset, cap)
      final stored = entry['stored'] as Map<String, dynamic>;
      final text = m['text'] as String;
      final sender = m['sender'] as String?;
      final parsed = (stored['parsed'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
      final amount = parsed['amount'];
      final meaning = ParserEngine.meaningOf(text);
      final r = <String, dynamic>{
        'local_only': await runPath(m, localOnly: true),
        'cloud_primary_real': await runPath(m, stored: stored, aiPrimary: true),
        'local_meaning': {
          'kind': meaning.kind.name,
          'disposition': meaning.disposition.name,
          'reason': meaning.reason,
        },
        'local_ignored': ParserEngine.isIgnoredMessage(text, senderId: sender),
      };
      // The device gate's inputs for the server row, by the gate's own
      // functions (capture_import_service.dart, AI-primary branch).
      String? str(Object? v) => v is String ? v : null;
      final validation = validateCaptureCandidate(
        candidate: CaptureCandidate(
          amount: amount is num ? amount.toDouble() : null,
          amountText: str(parsed['amount_text']),
          currency: str(parsed['currency']),
          direction: str(parsed['direction']),
          type: str(parsed['type']),
          merchant: str(parsed['merchant']),
          last4: str(parsed['last4']),
          occurredAt: str(parsed['occurredAt']),
        ),
        text: text,
        receivedAt: DateTime.parse(m['received_at'] as String),
      );
      r['device_gate'] = {
        'server_processed': stored['status'] != 'rejected' &&
            stored['status'] != 'needs_review' &&
            (stored['state'] ?? 'processed') == 'processed',
        'hold_reason': meaningHoldReason(text, amount: amount is num ? amount : null),
        'validation_reason': validation.reason,
        'local_contradicts': localParseContradictsServer(
          text: text,
          direction: str(parsed['direction']),
          type: str(parsed['type']),
          senderId: sender,
          merchant: str(parsed['merchant']),
          amount: amount is num ? amount : null,
        ),
      };
      out[m['id'] as String] = r;
    }
    File('$dir/out_$_shard.json').writeAsStringSync(jsonEncode(
        {'device': out, 'elapsed_ms': sw.elapsedMilliseconds}));
    dbDir.deleteSync(recursive: true);
  }, timeout: Timeout.none);
}

Future<Map<String, dynamic>> _snapshot(AppDatabase db) async {
  final rows = await db.customSelect('SELECT * FROM transactions;').get();
  final confirmed = <Map<String, dynamic>>[];
  final allRows = <Map<String, dynamic>>[];
  var pending = 0;
  var ignored = 0;
  for (final r in rows) {
    final d = r.data;
    final row = {
      'status': d['status'],
      'type': d['type'],
      'amount': d['amount'],
      'currency': d['currency'],
      'foreign_amount': d['foreign_amount'],
      'foreign_currency': d['foreign_currency'],
      'direction': d['direction'],
    };
    allRows.add(row);
    switch (d['status']) {
      case 'confirmed':
        confirmed.add(row);
      case 'pending':
        pending++;
      default:
        ignored++;
    }
  }
  final inboxRows = <Map<String, dynamic>>[];
  for (final r
      in await db.customSelect('SELECT * FROM smart_inbox_items;').get()) {
    Object? reason;
    try {
      final meta = jsonDecode(r.data['metadata_json'] as String? ?? '{}');
      if (meta is Map) {
        for (final e in meta.entries) {
          if ('${e.key}'.toLowerCase().contains('reason')) reason ??= e.value;
        }
      }
    } catch (_) {}
    inboxRows.add({
      'type': r.data['type'],
      'status': r.data['status'],
      'reason': reason,
      'has_transaction': r.data['transaction_id'] != null,
    });
  }
  Future<int> count(String table) async {
    try {
      return (await db
              .customSelect('SELECT COUNT(*) c FROM $table;')
              .getSingle())
          .read<int>('c');
    } catch (_) {
      return 0;
    }
  }

  return {
    'confirmed': confirmed,
    'rows': allRows,
    'inbox_rows': inboxRows,
    'pending': pending,
    'ignored_rows': ignored,
    'inbox': await count('smart_inbox_items'),
    'suspected': await count('suspected_duplicates'),
  };
}
