// Follow-up 6 (round 4): the FINAL EFFECT of each money-correctness class —
// what row is saved, what the dashboard totals become, what the review list
// shows — through the real CaptureImportService, CaptureSyncService and
// AddTransactionUseCase on an in-memory database. Each class runs on three
// paths: the device alone (Cloud off), a processed server row, and a processed
// AI-primary row; for a message that must not be recorded the server row is
// forged as "completed payment" (what an older server or a model would say).
// Synthetic messages only. The fakes are those of
// capture_import_service_test.dart.
import 'dart:async';

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
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/domain/usecases/ingest_captured_message_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';
import 'package:money_companion/features/capture/services/capture_import_ports.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_receipts.dart';
import 'package:money_companion/features/capture/services/capture_sync_service.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
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
  Future<bool> isLinkedForCloud() async => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// The admission of user-A, revocable by the test.
class _Guard extends OwnershipGuard {
  _Guard(this.isLive);
  final bool Function() isLive;
  static const _token = AdmissionToken(ownerUid: 'user-A', generation: 'gen');
  @override
  Future<AdmissionToken> capture() async => _token;
  @override
  Future<bool> isCurrent(AdmissionToken token) async =>
      isLive() && token == _token;
}

/// Counts every AI request; the iOS import path must make none.
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

class _FakeQueue implements CaptureImportQueue {
  final List<SharedCapturedMessage> items = [];
  final acked = <String>[];
  Future<void> Function(String id)? onAck;
  bool ackThrows = false;

  @override
  Future<List<SharedCapturedMessage>> peek() async => List.of(items);

  @override
  Future<bool> acknowledge(String payloadId) async {
    await onAck?.call(payloadId);
    if (ackThrows) throw StateError('killed before native ack');
    acked.add(payloadId);
    items.removeWhere((m) => m.id == payloadId);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected queue call: ${invocation.memberName}');
}

class _FakeServer implements CaptureServerPort {
  CaptureServerFetch fetch = const CaptureServerFetch(CaptureFetchStatus.ok);
  CaptureServerFetch? refetch;
  CaptureUploadStatus upload = CaptureUploadStatus.unavailable;
  final acks = <List<String>>[];
  var fetches = 0;
  var uploads = 0;
  Future<void> Function(List<String> ids)? onAck;

  @override
  Future<CaptureServerFetch> fetchResults() async =>
      (fetches++ > 0 ? refetch : null) ?? fetch;

  @override
  Future<CaptureUploadStatus> retryUpload(SharedCapturedMessage m) async {
    uploads++;
    return upload;
  }

  @override
  Future<void> acknowledge(List<String> payloadIds) async {
    await onAck?.call(payloadIds);
    acks.add(payloadIds);
  }
}


final _received = DateTime.utc(2026, 11, 17, 9, 45);
String _id(int n) => n.toRadixString(16).padLeft(64, '0');

/// What must end up on the device.
sealed class _Effect {
  const _Effect();
}

/// One confirmed row: it counts in the totals.
class _Saved extends _Effect {
  const _Saved(this.type, this.amount, this.currency,
      {this.expense = 0, this.local = true});
  final String type;
  final double amount;
  final String currency;

  /// The dashboard's net expense in minor units after the import (a refund
  /// subtracts); income stays 0 for every class here.
  final int expense;

  /// False when the device alone (Cloud off) keeps the message for review.
  final bool local;
}

/// No row, totals untouched, the message visible in review with [reason].
class _Review extends _Effect {
  const _Review(this.reason);
  final String reason;
}

typedef _Case = ({String name, String text, _Effect effect});

const _cases = <_Case>[
  // 1. pending merchant confirmation / attempts (CUE-1)
  (
    name: 'awaiting merchant confirmation',
    text: 'Purchase SAR 45.00 at Jarir card *4521. Awaiting merchant confirmation',
    effect: _Review('pending')
  ),
  (
    name: 'awaiting merchant confirmation (ar)',
    text: 'شراء 45 ريال لدى جرير بطاقة *4521. بانتظار تأكيد التاجر',
    effect: _Review('declined_or_failed')
  ),
  (
    name: 'attempted purchase',
    text: 'Attempted purchase SAR 45.00 at Jarir card *4521',
    effect: _Review('declined_or_failed')
  ),
  (
    name: 'attempted purchase (ar)',
    text: 'محاولة شراء 45 ريال لدى جرير بطاقة *4521',
    effect: _Review('declined_or_failed')
  ),
  // 2. future charges and credits (CUE-1)
  (
    name: 'a total that will be charged tomorrow',
    text: 'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 will be charged tomorrow',
    effect: _Review('scheduled_or_expected')
  ),
  (
    name: 'a total that will be charged tomorrow (ar)',
    text: 'فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال سيتم خصمه غدا',
    effect: _Review('scheduled_or_expected')
  ),
  (
    name: 'a future cashback',
    text: 'You will receive SAR 45.00 cashback on 01/12',
    effect: _Review('scheduled_or_expected')
  ),
  (
    name: 'a future cashback (ar)',
    text: 'سوف تستلم 45 ريال استرداد نقدي بتاريخ 01/12',
    effect: _Review('scheduled_or_expected')
  ),
  // 3. completed purchases with a footer (FT-1, NEW-2r, HOLD-1)
  (
    name: 'a purchase with a standing-order footer',
    text: 'Purchase SAR 45.00 at Jarir card *4521. Standing orders will be executed on the due date',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  (
    name: 'a purchase with a standing-order footer (ar)',
    text: 'شراء 45 ريال لدى جرير بطاقة *4521. سيتم تنفيذ الأوامر المستديمة في تاريخ الاستحقاق',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  (
    name: 'a purchase with a refund-request footer',
    text: 'Purchase SAR 45.00 at Jarir card *4521. Refund requests will be processed within 7 days',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  (
    name: 'a purchase with a refund-request footer (ar)',
    text: 'شراء 45 ريال لدى جرير بطاقة *4521. طلبات الاسترداد تعالج خلال 7 أيام',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  (
    name: 'a bill payment with a reminder tail (ar)',
    text: 'دفع فاتورة 45 ريال من حسابك *4521، تذكير: موعد السداد القادم 1/12',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  (
    name: 'a purchase with a month-to-date total tail',
    text: 'Purchase SAR 45.00 at Jarir card *4521, total spent this month SAR 3,200.00',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  // 4. refunds and reversals (HOLD-1, PRE-RF009, VAL-1 leftover)
  (
    name: 'an expected refund that has been credited',
    text: 'Your expected refund of SAR 45.00 from Noon has been credited to your card *4521',
    effect: _Saved('refund', 45, 'SAR', expense: -4500)
  ),
  (
    name: 'a pending refund that has been credited (ar)',
    text: 'تم إيداع مبلغ الاسترداد المعلق 45 ريال في حسابك *4521',
    effect: _Saved('refund', 45, 'SAR', expense: -4500)
  ),
  (
    name: 'an Arabic refund that names the purchase',
    text: 'استرجاع عملية شراء بمبلغ 45 ريال من نون بطاقة *4521',
    effect: _Saved('refund', 45, 'SAR', expense: -4500)
  ),
  (
    name: 'a refund request that is pending',
    text: 'Your refund request of SAR 45.00 from Noon is pending',
    effect: _Review('pending')
  ),
  (
    name: 'a reversed bill with a VAT total (ar)',
    text: 'فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال. تم عكس العملية',
    effect: _Review('total_with_parts')
  ),
  // 5. own accounts and third parties (PRE-AT008, HOLD-1)
  (
    name: 'a move between the user\'s own named accounts',
    text: 'SAR 45.00 transferred from your current account to your savings account',
    effect: _Review('own_accounts')
  ),
  (
    name: 'a move between the user\'s own named accounts (ar)',
    text: 'تم تحويل 45 ريال من حسابك الجاري إلى حسابك الادخاري',
    effect: _Review('own_accounts')
  ),
  (
    name: 'a transfer to a third party that names two account types',
    text: 'SAR 45.00 transferred from your current account to savings account of Ali',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  // 6. bill + VAT = total paid (HOLD-1)
  (
    name: 'a bill, its VAT and the total paid',
    text: 'Bill SAR 200.00, VAT SAR 30.00, total SAR 230.00 paid from account *4521',
    effect: _Saved('payment', 230, 'SAR', expense: 23000)
  ),
  (
    name: 'a bill, its VAT and the total paid (ar)',
    text: 'فاتورة 200 ريال، ضريبة 30 ريال، الإجمالي 230 ريال تم دفعه من حسابك *4521',
    effect: _Saved('payment', 230, 'SAR', expense: 23000)
  ),
  // 7. genuinely ambiguous
  (
    name: 'a completed purchase next to another declined one',
    text: 'Purchase SAR 45.00 at Jarir card *4521 completed. Previous transaction declined.',
    effect: _Review('other_event_status')
  ),
  (
    name: 'a bare operation on the card (ar)',
    text: 'عملية بمبلغ 45 ريال على بطاقتك *4521',
    effect: _Review('unspecified_operation')
  ),
  (
    name: 'a bare transaction on the card',
    text: 'A transaction of SAR 45.00 on your card *4521',
    effect: _Review('unspecified_operation')
  ),
  // real-model run: a late-payment fee is a debit, not a card repayment
  (
    name: 'a late-payment fee charged to the credit card',
    text: 'Late payment fee of SAR 45.00 charged to your credit card *4521',
    effect: _Saved('payment', 45, 'SAR', expense: 4500, local: false)
  ),
  (
    name: 'a late-payment fee charged to the credit card (ar)',
    text: 'تم خصم رسوم تأخير سداد بطاقتك الائتمانية *4521 بمبلغ 45 ريال',
    effect: _Saved('payment', 45, 'SAR', expense: 4500)
  ),
  // real-model run: a completed refund of a cancelled operation
  (
    name: 'a refund of a cancelled transaction that has been credited',
    text: 'Refund of SAR 45.00 for the cancelled transaction has been credited to your card *4521',
    effect: _Saved('refund', 45, 'SAR', expense: -4500)
  ),
  (
    name: 'a refund of a cancelled transaction that has been credited (ar)',
    text: 'تم إيداع مبلغ الاسترداد 45 ريال للعملية الملغاة في بطاقتك *4521',
    effect: _Saved('refund', 45, 'SAR', expense: -4500)
  ),
];

void main() {
  late AppDatabase db;
  late CaptureSyncService sync;
  late _FakeQueue queue;
  late _FakeServer server;
  late _SpyAi ai;
  late DriftTransactionRepository txRepo;
  late DriftMerchantCategoryRepository rules;

  SharedCapturedMessage item(String id, String text) => SharedCapturedMessage(
        id: id,
        text: text,
        sender: 'SNB',
        source: CapturedMessageSource.iosShortcut,
        receivedAt: _received,
        status: 'sent',
        ownerUid: 'user-A',
      );

  CaptureImportService buildService({bool aiPrimary = false}) {
    final ingest = IngestCapturedMessageUseCase(AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: rules,
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      accountRepository: DriftAccountRepository(db),
      dedupStore: DriftDedupStore(db),
      parserIsolate: const FakeParserIsolate(),
      aiClient: ai,
      loadAiConsent: () async => true,
      installId: 'install',
    ));
    return CaptureImportService(
      queue: queue,
      server: server,
      captureSyncService: sync,
      receipts: CaptureReceipts(db),
      ingestLocal: CaptureImportService.localIngest(ingest),
      sessionUid: () => 'user-A',
      replicaOwnerUid: () async => 'user-A',
      ownershipGuard: _Guard(() => true),
      aiPrimarySelected: aiPrimary ? () async => true : null,
    );
  }

  /// A processed server row: what a server (or its model) answered.
  ProcessedCaptureDto row(String id, String text, String type, double amount,
          {String currency = 'SAR',
          bool ai = false,
          String? merchant,
          String? category}) =>
      ProcessedCaptureDto(
        payloadId: id,
        status: 'processed',
        state: 'processed',
        parsed: {
          'amount': amount,
          // The amount as the message writes it ("45.00", or «45»).
          'amount_text': text.contains(amount.toStringAsFixed(2))
              ? amount.toStringAsFixed(2)
              : amount.toStringAsFixed(0),
          'currency': currency,
          'direction': type == 'refund' || type == 'income' ? 'credit' : 'debit',
          'type': type,
          if (merchant != null) 'merchant': merchant,
          if (category != null) 'category': category,
          'rawMessage': text,
          'parserSource': ai ? 'ai' : 'deterministic',
          'confidence': 0.95,
        },
        notification: const {},
      );

  /// The dashboard's confirmed-only totals (minor units) for [currency].
  Future<(int expense, int income)> totals([String currency = 'SAR']) async {
    final all = await txRepo.currencyTotalsBetween(
        from: DateTime.utc(2026), to: DateTime.utc(2027));
    for (final t in all) {
      if (t.currency == currency) {
        return (t.expense.minorUnits, t.income.minorUnits);
      }
    }
    return (0, 0);
  }

  /// The review list (Smart Inbox): the open item for [id] and its reason.
  Future<String?> reviewReason(String id) async {
    final open = await DriftSmartInboxRepository(db).getOpen();
    if (!open.any((i) => i.payloadId == id)) return 'not in the review list';
    final meta = (await db.customSelect(
                'SELECT metadata_json FROM smart_inbox_items WHERE payload_id = ?;',
                variables: [Variable.withString(id)]).getSingle())
        .read<String?>('metadata_json');
    return RegExp(r'"review_reason":"([a-z_]+)"').firstMatch(meta ?? '')?.group(1);
  }

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
    rules = DriftMerchantCategoryRepository(db);
    sync = CaptureSyncService(
      settingsRepository: DriftUserSettingsRepository(db),
      transactionRepository: txRepo,
      dedupStore: DriftDedupStore(db),
      smartInboxRepository: DriftSmartInboxRepository(db),
      suspectedDuplicateRepository: DriftSuspectedDuplicateRepository(db),
      registrationService: _Registration(),
      ownershipGuard: _Guard(() => true),
      currentUserId: () => 'user-A',
      accountRepository: DriftAccountRepository(db),
      merchantCategoryRepository: rules,
      backendConfigured: true,
      loadInstallId: () async => 'install',
    );
    queue = _FakeQueue();
    server = _FakeServer();
    ai = _SpyAi();
  });

  tearDown(() async => db.close());

  for (final c in _cases) {
    for (final path in const ['device alone', 'server row', 'AI-primary row']) {
      test('${c.name} — $path', () async {
        final effect = c.effect;
        queue.items.add(item(_id(1), c.text));
        if (path == 'device alone') {
          server.fetch =
              const CaptureServerFetch(CaptureFetchStatus.notConfigured);
        } else {
          // For a message that must not be recorded: the answer of an older
          // server or a model ("a completed payment of the figure").
          final answer = effect is _Saved
              ? row(_id(1), c.text, effect.type, effect.amount,
                  currency: effect.currency, ai: path != 'server row')
              : row(_id(1), c.text, 'payment',
                  c.text.contains('230') ? 230 : 45,
                  ai: path != 'server row');
          server.fetch =
              CaptureServerFetch(CaptureFetchStatus.ok, {_id(1): answer});
        }

        await buildService(aiPrimary: path == 'AI-primary row').run();

        final saved = await txRepo.getAll();
        expect(ai.calls, 0, reason: 'the import path makes no AI request');
        if (effect is _Review ||
            (path == 'device alone' && !(effect as _Saved).local)) {
          // (a) nothing saved, (b) totals untouched, (c) visible in review.
          expect(saved, isEmpty);
          expect(await totals(), (0, 0));
          final reason = await reviewReason(_id(1));
          if (effect is _Review) {
            expect(reason, effect.reason);
            expect(ParserEngine.meaningOf(c.text).reason, effect.reason);
          } else {
            expect(reason, isNot('not in the review list'));
          }
          return;
        }
        effect as _Saved;
        // (a) one confirmed row with the right money.
        final tx = saved.single;
        expect(tx.status, TransactionStatus.confirmed);
        expect(tx.type.name, effect.type);
        expect(tx.amount, closeTo(effect.amount, 0.005));
        expect(tx.currency, effect.currency);
        // Never the opposite direction (the device alone stores no direction
        // for a transfer it books as spending from its type).
        expect(
            tx.direction,
            isNot(effect.type == 'refund'
                ? TransactionDirectionEntity.debit
                : TransactionDirectionEntity.credit));
        if (path != 'device alone') {
          expect(
              tx.direction,
              effect.type == 'refund'
                  ? TransactionDirectionEntity.credit
                  : TransactionDirectionEntity.debit);
        }
        // Dated in the capture's own month, not by a reminder's date.
        expect(tx.occurredAt.isAfter(DateTime.utc(2026, 11)), isTrue);
        expect(tx.occurredAt.isBefore(DateTime.utc(2026, 12)), isTrue);
        // (b) its effect on the dashboard totals, counted once.
        expect(await totals(effect.currency), (effect.expense, 0));
        // (c) nothing left in the review list.
        expect(await reviewReason(_id(1)), 'not in the review list');
      });
    }
  }

  // An explicitly named move between the user's own accounts is neutral on
  // every path, whatever type a server or a model gave it (PRE-AT008).
  for (final text in const [
    'Transfer of SAR 45.00 from your account *4521 to your own account *7788 completed',
    'تم تحويل 45 ريال من حسابك إلى حسابك الآخر',
  ]) {
    for (final path in const ['device alone', 'server row', 'AI-primary row']) {
      test('an own-account transfer is neither spending nor income — $path: $text',
          () async {
        queue.items.add(item(_id(1), text));
        server.fetch = path == 'device alone'
            ? const CaptureServerFetch(CaptureFetchStatus.notConfigured)
            : CaptureServerFetch(CaptureFetchStatus.ok, {
                _id(1):
                    row(_id(1), text, 'payment', 45, ai: path != 'server row')
              });

        await buildService(aiPrimary: path == 'AI-primary row').run();

        final saved = await txRepo.getAll();
        expect(await totals(), (0, 0));
        if (saved.isEmpty) {
          // Kept for review: visible, never silent.
          expect(await reviewReason(_id(1)), isNot('not in the review list'));
        } else {
          expect(saved.single.type, TransactionTypeEntity.transfer);
          expect(saved.single.amount, 45);
        }
      });
    }
  }

  // (d) Category precedence: a manual choice, then an enabled matching saved
  // rule, then the server's or model's category.
  group('category precedence', () {
    String text(double amount) =>
        'Purchase SAR ${amount.toStringAsFixed(2)} at Jarir card *4521';
    Future<String> categoryOf(String id) async => (await db.customSelect(
                'SELECT c.key FROM transactions t JOIN categories c '
                'ON c.id = t.category_id WHERE t.id = ?;',
                variables: [Variable.withString(id)]).getSingle())
        .read<String>('key');

    Future<TransactionEntity> import(String id, String category,
        {bool aiPrimary = true, double amount = 45}) async {
      queue.items.add(item(id, text(amount)));
      server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
        id: row(id, text(amount), 'payment', amount,
            ai: true, merchant: 'Jarir', category: category)
      });
      await buildService(aiPrimary: aiPrimary).run();
      return (await txRepo.getById(id))!;
    }

    test('no rule: the model category is used', () async {
      final tx = await import(_id(1), 'shopping');
      expect(await categoryOf(_id(1)), 'shopping');
      expect(tx.categoryProvenance, CategoryProvenance.auto);
      expect(await totals(), (4500, 0));
    });

    test(
        'an enabled matching saved rule outranks the model category and '
        'changes nothing else', () async {
      final plain = await import(_id(1), 'shopping');
      await rules.confirmMerchantCategory(
          rawMerchant: 'Jarir', categoryKey: 'education', isUserConfirmed: true);
      final ruled = await import(_id(2), 'shopping', amount: 60);

      expect(await categoryOf(_id(2)), 'education');
      expect(ruled.categoryProvenance, CategoryProvenance.rule);
      // The rule never changes amount, currency, status, direction or type.
      expect(ruled.amount, 60);
      expect(ruled.currency, plain.currency);
      expect(ruled.status, plain.status);
      expect(ruled.direction, plain.direction);
      expect(ruled.type, plain.type);
      expect(await totals(), (10500, 0));
    });

    test('a rule that was removed no longer applies: the model category',
        () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'Jarir', categoryKey: 'education', isUserConfirmed: true);
      await rules.forgetUserConfirmedRule('Jarir');
      await import(_id(1), 'shopping');
      expect(await categoryOf(_id(1)), isNot('education'));
    });

    test('a rule never turns a held message into money', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'Jarir', categoryKey: 'education', isUserConfirmed: true);
      const held =
          'Purchase SAR 45.00 at Jarir card *4521. Awaiting merchant confirmation';
      queue.items.add(item(_id(1), held));
      server.fetch = CaptureServerFetch(CaptureFetchStatus.ok, {
        _id(1): row(_id(1), held, 'payment', 45,
            ai: true, merchant: 'Jarir', category: 'shopping')
      });
      await buildService(aiPrimary: true).run();
      expect(await txRepo.getAll(), isEmpty);
      expect(await totals(), (0, 0));
      expect(await reviewReason(_id(1)), 'pending');
    });

    test(
        'a manual category outranks the saved rule and a late model result',
        () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'Jarir', categoryKey: 'education', isUserConfirmed: true);
      await import(_id(1), 'shopping');
      await txRepo.updateCategory(transactionId: _id(1), categoryKey: 'travel');

      // The same capture is delivered again with another model category.
      final again = await import(_id(1), 'groceries');

      expect(await categoryOf(_id(1)), 'travel');
      expect(again.categoryProvenance, CategoryProvenance.user);
      expect(again.amount, 45);
      expect(again.status, TransactionStatus.confirmed);
      expect(await txRepo.getAll(), hasLength(1));
      expect(await totals(), (4500, 0), reason: 'counted once');
    });
  });
}
