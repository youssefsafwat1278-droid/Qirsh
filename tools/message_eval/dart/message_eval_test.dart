// Held-out evaluation, device side. Copied by tools/message_eval/run.sh into
// <checkout>/app/test/zz_message_eval/ of a scratch worktree and run there with
// `flutter test`; it never runs inside the working tree.
//
// Each message, each path, gets a fresh in-memory database and goes through the
// checkout's REAL iOS import: CaptureImportService → (server result validated by
// ValidatedCapture + localParseContradictsServer → CaptureSyncService import) or
// (IngestCapturedMessageUseCase → AddTransactionUseCase, onDeviceOnly). Only the
// native queue, the server transport and the session are fakes (as in
// capture_import_service_test.dart). The server results are the checkout's own
// parse.ts outputs produced by deno/server_eval.ts.
//
// Inputs (relative to app/): test/zz_message_eval/in.json, server.json.
// Output: test/zz_message_eval/out_<shard>.json. run.sh makes one copy of this
// file per shard (`_shard` replaced) so two shards run in parallel.
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
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_candidate_validator.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
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

const _kinds = {
  'payment': 'payment',
  'fee': 'payment',
  'withdrawal': 'withdrawal',
  'transfer_out': 'transfer',
  'transfer_in': 'transfer',
  'own_transfer': 'transfer',
  'income': 'income',
  'refund': 'refund',
};
const _dirs = {
  'payment': 'debit',
  'fee': 'debit',
  'withdrawal': 'debit',
  'transfer_out': 'debit',
  'transfer_in': 'credit',
  'income': 'credit',
  'refund': 'credit',
  'own_transfer': 'debit',
};

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

  test('held-out message evaluation (shard $_shard of $_shards)', () async {
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
      final s = server[m['id']] as Map<String, dynamic>;
      final r = <String, dynamic>{
        'local_only': await runPath(m, localOnly: true),
        'cloud_det': await runPath(m, stored: s['det'] as Map<String, dynamic>),
        'cloud_primary_oracle': await runPath(m,
            stored: s['primary_oracle'] as Map<String, dynamic>,
            aiPrimary: true),
        if (s['primary_real'] != null)
          'cloud_primary_real': await runPath(m,
              stored: s['primary_real'] as Map<String, dynamic>,
              aiPrimary: true),
      };
      // Device AI candidate validator on the ground-truth candidate.
      final events = (m['events'] as List).cast<Map<String, dynamic>>();
      if (m['disposition'] == 'save' && events.isNotEmpty) {
        final e = events.first;
        final kind = e['kind'] as String;
        final v = const AiCandidateValidator().validate(
          response: AiParseResponse(
            amount: (e['amount'] as num).toDouble(),
            amountText: e['amount_text'] as String,
            currency: e['currency'] as String,
            type: _kinds[kind],
            direction: _dirs[kind],
          ),
          sanitizedText: s['sanitized'] as String,
          localParsed: null,
          referenceTime: DateTime.parse(m['received_at'] as String),
          messageText: m['text'] as String,
          normalizedType: switch (_kinds[kind]) {
            'payment' => TransactionType.payment,
            'withdrawal' => TransactionType.withdrawal,
            'transfer' => TransactionType.transfer,
            'income' => TransactionType.income,
            'refund' => TransactionType.refund,
            _ => null,
          },
        );
        r['device_validator'] = {
          'accepted': v.accepted,
          'reason': v.rejectionReason,
        };
      }
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
  var pending = 0;
  var ignored = 0;
  for (final r in rows) {
    final d = r.data;
    switch (d['status']) {
      case 'confirmed':
        confirmed.add({
          'type': d['type'],
          'amount': d['amount'],
          'currency': d['currency'],
          'foreign_amount': d['foreign_amount'],
          'foreign_currency': d['foreign_currency'],
          'direction': d['direction'],
        });
      case 'pending':
        pending++;
      default:
        ignored++;
    }
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
    'pending': pending,
    'ignored_rows': ignored,
    'inbox': await count('smart_inbox_items'),
    'suspected': await count('suspected_duplicates'),
  };
}
