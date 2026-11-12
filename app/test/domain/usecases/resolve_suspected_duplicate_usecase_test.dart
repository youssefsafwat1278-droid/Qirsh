// Review actions for a suspected duplicate (the later of two captures that
// may be one purchase) and the Smart Inbox actions: NONE may delete or change
// the ORIGINAL transaction. Behavioural: real AddTransactionUseCase,
// ResolveSuspectedDuplicateUseCase, Drift repositories on an in-memory DB.
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/db/ownership_guard.dart';
import 'package:money_companion/data/repositories/drift_account_repository.dart';
import 'package:money_companion/data/repositories/drift_dedup_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/data/repositories/drift_suspected_duplicate_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/suspected_duplicate_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/resolve_suspected_duplicate_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';

import '../local_v2_support.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

class _SpyAi implements AiParserClient {
  int calls = 0;
  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    calls++;
    return null;
  }
}

const _noTime = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 45.00\n'
    'لدى:NETFLIX\nالرصيد:SAR 2,310.50';
const _otherNoTime = 'عملية شراء\nبطاقة:مدى;****4521\nمبلغ:SAR 19.00\n'
    'لدى:CAREEM\nالرصيد:SAR 2,291.50';
final _t0 = DateTime.utc(2026, 4, 8, 9, 45);

void main() {
  late AppDatabase db;
  late DriftTransactionRepository txRepo;
  late DriftSuspectedDuplicateRepository dupRepo;

  AddTransactionUseCase useCase({
    AiParserClient? ai,
    Future<Object?> Function()? identity,
  }) =>
      AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        suspectedDuplicateRepository: dupRepo,
        accountRepository: DriftAccountRepository(db),
        dedupStore: DriftDedupStore(db),
        parserIsolate: const FakeParserIsolate(),
        findSameTextCapture: txRepo.findSameTextCapture,
        aiClient: ai,
        loadAiConsent: ai == null ? null : () async => true,
        loadAccountIdentity: identity,
        installId: 'install',
      );

  ResolveSuspectedDuplicateUseCase resolver([AddTransactionUseCase? add]) =>
      ResolveSuspectedDuplicateUseCase(
        addTransaction: add ?? useCase(),
        repository: dupRepo,
        runAtomically: (action) => db.transaction(action),
      );

  CaptureCommit commitFor(String id) => CaptureCommit(
        captureId: id,
        runAtomically: (action) => db.transaction(action),
        writeReceipt: (txId) => DriftDedupStore(db).mark(
          'capture_payload:$id',
          transactionId: txId,
          occurredAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        ),
      );

  /// Captures [text] twice (two ids, minutes apart): returns the original
  /// transaction and the suspected duplicate of the later capture.
  Future<(TransactionEntity, SuspectedDuplicateEntity)> pair(
    String a,
    String b, {
    String text = _noTime,
  }) async {
    final first = await useCase()(
      rawMessage: text,
      senderId: 'SNB',
      smsReceivedAt: _t0,
      onDeviceOnly: true,
      capture: commitFor(a),
    );
    final second = await useCase()(
      rawMessage: text,
      senderId: 'SNB',
      smsReceivedAt: _t0.add(const Duration(minutes: 2)),
      onDeviceOnly: true,
      capture: commitFor(b),
    );
    expect(second.outcome, AddTransactionOutcome.suspiciousDuplicate);
    final dupe = (await dupRepo.getAll()).firstWhere((d) => d.id == b);
    return (first.transaction!, dupe);
  }

  /// The original row exactly as committed: id, status, amount, text.
  Future<String> snapshot(String id) async {
    final row = await db.customSelect(
      'SELECT id, status, amount_minor, currency, raw_message, updated_at '
      'FROM transactions WHERE id = ?;',
      variables: [Variable.withString(id)],
    ).getSingle();
    return row.data.toString();
  }

  Future<List<String>> liveTxIds() async => (await db
          .customSelect("SELECT id FROM transactions WHERE status != 'ignored' "
              'ORDER BY rowid;')
          .get())
      .map((r) => r.read<String>('id'))
      .toList();

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(
      db,
      outboxQueue: LedgerOutboxQueue(
        db: db,
        isPushEnabled: () => true,
        getAuthUserId: () async => 'user-A',
      ),
    );
    dupRepo = DriftSuspectedDuplicateRepository(db);
  });

  tearDown(() => db.close());

  test('"dismiss duplicate": the flag goes, the original is untouched',
      () async {
    final (original, dupe) = await pair('orig', 'later');
    final before = await snapshot(original.id);

    await resolver().dismiss(dupe);

    expect(await snapshot(original.id), before);
    expect(await liveTxIds(), ['orig']);
    expect(await dupRepo.getAll(), isEmpty);
  });

  test('"dismiss all": every flag goes, every original is untouched',
      () async {
    final (o1, d1) = await pair('o1', 'l1');
    final (o2, d2) = await pair('o2', 'l2', text: _otherNoTime);
    final before = [await snapshot(o1.id), await snapshot(o2.id)];

    await resolver().dismissAll([d1, d2]);

    expect([await snapshot(o1.id), await snapshot(o2.id)], before);
    expect(await liveTxIds(), ['o1', 'o2']);
    expect(await dupRepo.getAll(), isEmpty);
  });

  test(
      '"save as new" (keep both): a second transaction next to the untouched '
      'original; a repeated tap never adds a third', () async {
    final (original, dupe) = await pair('orig', 'later');
    final before = await snapshot(original.id);

    final kept = await resolver().keepBoth(dupe);
    expect(kept.outcome, AddTransactionOutcome.added);
    expect(kept.transaction!.id, 'later');
    // A double tap / retry with the same (stale) flag in hand.
    final again = await resolver().keepBoth(dupe);
    expect(again.transaction!.id, 'later');

    expect(await snapshot(original.id), before);
    expect(await liveTxIds(), ['orig', 'later']);
    expect(await dupRepo.getAll(), isEmpty);
  });

  test(
      '"save as new" that cannot produce a transaction keeps the flag (the '
      'capture is not lost) and the original', () async {
    final (original, dupe) = await pair('orig', 'later');
    final before = await snapshot(original.id);
    final unreadable = SuspectedDuplicateEntity(
      id: dupe.id,
      rawMessage: 'Your request could not be completed. Call us.',
      existingTransactionId: dupe.existingTransactionId,
      amountMoney: dupe.amountMoney,
      currency: dupe.currency,
      occurredAt: dupe.occurredAt,
      createdAt: dupe.createdAt,
    );

    final result = await resolver().keepBoth(unreadable);

    expect(result.transaction, isNull);
    expect(await snapshot(original.id), before);
    expect(await liveTxIds(), ['orig']);
    expect((await dupRepo.getAll()).map((d) => d.id), ['later']);
  });

  test(
      '"save as new" when the account changed before its AI request: no '
      'request, flag and original kept', () async {
    final (original, dupe) = await pair('orig', 'later');
    final before = await snapshot(original.id);
    final ai = _SpyAi();
    var reads = 0;

    await expectLater(
      resolver(useCase(ai: ai, identity: () async => 'uid-${reads++}'))
          .keepBoth(dupe),
      throwsA(isA<StaleOwnershipException>()),
    );

    expect(ai.calls, 0);
    expect(await snapshot(original.id), before);
    expect(await liveTxIds(), ['orig']);
    expect((await dupRepo.getAll()).map((d) => d.id), ['later']);
  });

  test('Smart Inbox hide / resolve never delete the linked transaction',
      () async {
    final (original, _) = await pair('orig', 'later');
    final before = await snapshot(original.id);
    final inbox = DriftSmartInboxRepository(db);
    for (final id in ['srv-dup-1', 'srv-dup-2']) {
      await db.customStatement('''
        INSERT INTO smart_inbox_items(
          id, server_id, transaction_id, payload_id, type, title, body, status,
          confidence, metadata_json, server_created_at, server_updated_at,
          synced_at, dismissed_locally, pending_sync, created_at, updated_at
        ) VALUES ('$id', '$id', 'orig', NULL, 'suspicious_duplicate', 't',
          NULL, 'open', NULL, '{}', '2026-04-08T09:45:00.000Z', NULL,
          '2026-04-08T09:45:00.000Z', 0, 0, '2026-04-08T09:45:00.000Z',
          '2026-04-08T09:45:00.000000Z');
      ''');
    }

    await inbox.dismiss('srv-dup-1');
    await inbox.resolve('srv-dup-2');

    expect(await inbox.getOpen(), isEmpty);
    expect(await snapshot(original.id), before);
    expect(await liveTxIds(), ['orig']);
  });
}
