// Gemini-first phase 2: every captured bank message ends in one visible
// outcome — saved, not added (with the reason), needs your confirmation, or
// awaiting analysis — with exactly one notification for a financial outcome
// and none for an OTP or an advert.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/analysis_log_repository.dart';
import 'package:money_companion/domain/capture/analysis_outcome.dart';
import 'package:money_companion/domain/capture/analysis_reason.dart';
import 'package:money_companion/domain/entities/captured_message.dart';
import 'package:money_companion/domain/entities/engagement_entities.dart';
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/analysis_log_screen.dart';
import 'package:money_companion/features/capture/background/capture_alerts.dart';
import 'package:money_companion/features/capture/services/capture_import_service.dart';
import 'package:money_companion/features/capture/services/capture_notification_content.dart';
import 'package:money_companion/features/capture/services/native_capture_bridge.dart';
import 'package:money_companion/features/capture/services/outcome_notification_content.dart';
import 'package:money_companion/features/transactions/transactions_screen.dart';

import '../consent/consent_test_harness.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

TransactionEntity _tx({
  String id = 'p1',
  TransactionTypeEntity type = TransactionTypeEntity.payment,
  TransactionDirectionEntity direction = TransactionDirectionEntity.debit,
  String? merchant = 'CARREFOUR',
  String? category = 'groceries',
}) =>
    TransactionEntity(
      id: id,
      amountMoney: Money.parse('250', 'EGP'),
      currency: 'EGP',
      rawMerchant: merchant,
      categoryId: category,
      type: type,
      source: TransactionSourceEntity.bank,
      occurredAt: DateTime.utc(2026, 11, 20, 9, 41),
      rawMessage: 'Purchase EGP 250.00 at CARREFOUR card 4111111111111111',
      parseConfidence: 1,
      status: TransactionStatus.confirmed,
      createdAt: DateTime.utc(2026, 11, 20, 9, 41),
      updatedAt: DateTime.utc(2026, 11, 20, 9, 41),
      direction: direction,
    );

SmartInboxItemEntity _inbox({
  String? reasonCode,
  String? reviewReason,
  CaptureProposal? proposal,
  String body = 'Purchase EGP 250.00 at CARREFOUR card 4111111111111111',
}) =>
    SmartInboxItemEntity(
      id: 'local_capture:p2',
      type: 'needs_review',
      title: 'stored',
      status: 'open',
      createdAt: DateTime.utc(2026, 11, 20, 8),
      payloadId: 'p2',
      body: body,
      reasonCode: reasonCode,
      reviewReason: reviewReason,
      proposal: proposal,
    );

class _Sink {
  final shown = <String, CaptureNotificationContent>{};
  final order = <String>[];
  final cancelled = <String>[];
  final withdrawn = <String>[];

  Future<void> show(String stableId, CaptureNotificationContent content,
      {String? transactionId, bool generic = false}) async {
    shown[stableId] = content;
    order.add(stableId);
  }

  Future<void> cancel(String stableId) async => cancelled.add(stableId);

  Future<bool> withdraw(String payloadId, {bool includePush = false}) async {
    withdrawn.add(includePush ? '$payloadId+push' : payloadId);
    return true;
  }
}

CaptureImportItem _imported(String id, DeviceCaptureOutcome outcome,
        {List<TransactionEntity> committed = const []}) =>
    CaptureImportItem(
        id: id,
        path: CaptureImportPath.server,
        outcome: outcome,
        committedTransactions: committed);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the four outcomes, in both languages', () {
    test('saved: kind, amount, merchant and category', () {
      final ar = buildOutcomeNotice(
          state: AnalysisOutcomeState.saved, tx: _tx(), lang: 'ar');
      expect(ar.title, 'سُجّل مصروف 250 EGP');
      expect(ar.body, 'CARREFOUR · بقالة 🛒');
      final en = buildOutcomeNotice(
          state: AnalysisOutcomeState.saved, tx: _tx(), lang: 'en');
      expect(en.title, 'Saved: expense 250 EGP');
      expect(en.body, 'CARREFOUR · Groceries 🛒');
    });

    test('saved transfer to a person: «تحويل لصديق», never a name', () {
      final n = buildOutcomeNotice(
          state: AnalysisOutcomeState.saved,
          tx: _tx(
              type: TransactionTypeEntity.transfer,
              merchant: 'InstaPay',
              category: 'transfers'),
          lang: 'ar');
      expect(n.title, 'سُجّل تحويل لصديق 250 EGP');
      expect(n.body.contains('InstaPay'), isFalse);
    });

    test('not added: the reason sentence', () {
      final ar = buildOutcomeNotice(
          state: AnalysisOutcomeState.notAdded,
          reasonCode: AnalysisReason.declined,
          lang: 'ar');
      expect(ar.title, 'لم تُضَف');
      expect(ar.body, 'عملية مرفوضة أو لم تكتمل، ولم يتحرك أي مبلغ');
      final en = buildOutcomeNotice(
          state: AnalysisOutcomeState.notAdded,
          reasonCode: AnalysisReason.declined,
          lang: 'en');
      expect(en.title, 'Not added');
      expect(en.body, 'A declined or failed operation; no money moved');
    });

    test('needs confirmation: reason, amount from the proposal', () {
      final n = buildOutcomeNotice(
          state: AnalysisOutcomeState.needsConfirmation,
          reasonCode: AnalysisReason.amountMismatch,
          proposal: const CaptureProposal(
              amountText: '54.00', currency: 'EGP', isDebit: true),
          lang: 'en');
      expect(n.title, 'Needs your confirmation · 54.00 EGP');
      expect(n.body,
          'The amount does not match the message; confirm it before recording');
      final unanalysed = buildOutcomeNotice(
          state: AnalysisOutcomeState.needsConfirmation,
          unanalysed: true,
          lang: 'ar');
      expect(unanalysed.title, 'تحتاج تأكيدك');
      expect(unanalysed.body, 'لم نتمكن من تحليل الرسالة، افتحها وسجّلها');
    });

    test('awaiting analysis', () {
      expect(
          buildOutcomeNotice(state: AnalysisOutcomeState.awaiting, lang: 'ar')
              .title,
          'بانتظار التحليل');
      expect(
          buildOutcomeNotice(state: AnalysisOutcomeState.awaiting, lang: 'en')
              .body,
          'It will be analysed automatically when the connection is back');
    });

    test('codes: OTP / advert / balance / non-financial are silent', () {
      for (final code in [
        AnalysisReason.otp,
        AnalysisReason.promo,
        AnalysisReason.balanceOnly,
        AnalysisReason.notFinancial,
      ]) {
        expect(AnalysisOutcome.isSilent(code), isTrue, reason: code);
        expect(
            DeviceCaptureOutcome(
                    state: AnalysisOutcomeState.notAdded,
                    reasonCode: code,
                    serverState: AnalysisOutcomeState.notAdded,
                    serverPushed: false)
                .deviceNotifies,
            isFalse,
            reason: code);
      }
      for (final code in [
        AnalysisReason.declined,
        AnalysisReason.pending,
        AnalysisReason.duplicate,
        AnalysisReason.paymentReminder,
        AnalysisReason.ownAccount,
      ]) {
        expect(AnalysisOutcome.forCode(code), AnalysisOutcomeState.notAdded,
            reason: code);
      }
      expect(AnalysisOutcome.forCode(AnalysisReason.amountMismatch),
          AnalysisOutcomeState.needsConfirmation);
      expect(AnalysisOutcome.forCode(null),
          AnalysisOutcomeState.needsConfirmation);
    });
  });

  group('exactly one notification per financial outcome', () {
    late AppDatabase db;
    late _Sink sink;
    const prefs = NotificationPreferences();

    setUp(() async {
      db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      sink = _Sink();
    });
    tearDown(() => db.close());

    Future<void> alert(List<CaptureImportItem> items) => alertServerOutcomes(
        db, items, prefs,
        show: sink.show,
        cancel: sink.cancel,
        withdraw: sink.withdraw,
        lang: 'ar');

    test('the server push went out with the same outcome: the device is silent',
        () async {
      await alert([
        _imported(
            'a',
            const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.saved,
                serverState: AnalysisOutcomeState.saved,
                serverPushed: true),
            committed: [_tx(id: 'a')]),
        // Pushed but not yet marked (the mark lands right after the push).
        _imported(
            'b',
            const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.notAdded,
                reasonCode: AnalysisReason.declined,
                serverState: AnalysisOutcomeState.notAdded)),
      ]);
      expect(sink.shown, isEmpty);
      // Its awaiting notice (device or App Intent) does not stay beside it.
      expect(sink.cancelled, ['outcome:a', 'outcome:b']);
      expect(sink.withdrawn, ['a', 'b']);
    });

    test('no push went out: one device notice, never a second', () async {
      final item = _imported(
          'c',
          const DeviceCaptureOutcome(
              state: AnalysisOutcomeState.saved,
              transactionId: 'c',
              serverState: AnalysisOutcomeState.saved,
              serverPushed: false),
          committed: [_tx(id: 'c')]);
      await alert([item]);
      await alert([item]);
      expect(sink.order, ['outcome:c']);
      expect(sink.shown['outcome:c']!.title, 'سُجّل مصروف 250 EGP');
    });

    test('the push said saved but the device held it: the push is replaced',
        () async {
      await alert([
        _imported(
            'd',
            const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.needsConfirmation,
                reasonCode: AnalysisReason.directionConflict,
                serverState: AnalysisOutcomeState.saved,
                serverPushed: true)),
      ]);
      expect(sink.withdrawn, ['d+push']);
      expect(sink.order, ['outcome:d']);
      expect(sink.shown['outcome:d']!.title, 'تحتاج تأكيدك');
    });

    test('OTP and advert: no notification at all', () async {
      await alert([
        _imported(
            'e',
            const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.notAdded,
                reasonCode: AnalysisReason.otp,
                serverPushed: false,
                serverState: AnalysisOutcomeState.notAdded)),
        _imported(
            'f',
            const DeviceCaptureOutcome(
                state: AnalysisOutcomeState.notAdded,
                reasonCode: AnalysisReason.promo)),
      ]);
      expect(sink.shown, isEmpty);
    });

    test('an older server build (no outcome stated) keeps its own push',
        () async {
      await alert([
        _imported('g',
            const DeviceCaptureOutcome(state: AnalysisOutcomeState.saved)),
      ]);
      expect(sink.shown, isEmpty);
      expect(sink.withdrawn, isEmpty);
    });

    test('24 hours unresolved: one "record it" notice, once', () async {
      final parked = _imported(
          'h',
          const DeviceCaptureOutcome(
              state: AnalysisOutcomeState.needsConfirmation,
              unanalysed: true));
      await alert([parked]);
      await alert([parked]);
      expect(sink.order, ['outcome:h']);
      expect(sink.shown['outcome:h']!.body,
          'لم نتمكن من تحليل الرسالة، افتحها وسجّلها');
    });

    SharedCapturedMessage queued(String id, String text,
            {String? failureReason}) =>
        SharedCapturedMessage(
          id: id,
          text: text,
          sender: 'CIB',
          source: CapturedMessageSource.iosShortcut,
          receivedAt: DateTime.utc(2026, 11, 20),
          status: 'pendingSend',
          failureReason: failureReason,
        );

    test('awaiting analysis: once per message, never for an OTP', () async {
      final waiting = [
        queued('w1', 'Purchase of EGP 250.00 at CARREFOUR'),
        queued('w2', 'Your OTP is 482913. Do not share it with anyone.'),
        queued('w3', 'Purchase of EGP 99.00 at SHOP',
            failureReason: awaitingNotifiedByIntent),
      ];
      await alertAwaitingAnalysis(db, waiting, prefs,
          show: sink.show, lang: 'en');
      await alertAwaitingAnalysis(db, waiting, prefs,
          show: sink.show, lang: 'en');
      expect(sink.order, ['outcome:w1'],
          reason: 'w2 is an OTP; the App Intent already announced w3');
      expect(sink.shown['outcome:w1']!.title, 'Awaiting analysis');
    });
  });

  test('an InstaPay debit filed under transfers reads as a transfer to a friend',
      () {
    final notice = buildOutcomeNotice(
      state: AnalysisOutcomeState.saved,
      tx: _tx(merchant: 'InstaPay', category: 'transfers'),
    );
    expect(notice.title, 'سُجّل تحويل لصديق 250 EGP');
  });

  group('the analysis log', () {
    final entries = [
      AnalysisLogEntry(
          payloadId: 'p1',
          at: DateTime.utc(2026, 11, 20, 9),
          state: AnalysisOutcomeState.saved,
          transaction: _tx(),
          text: _tx().rawMessage),
      AnalysisLogEntry(
          payloadId: 'p2',
          at: DateTime.utc(2026, 11, 20, 8),
          state: AnalysisOutcomeState.notAdded,
          reasonCode: AnalysisReason.declined,
          inboxItem: _inbox(reasonCode: AnalysisReason.declined)),
      AnalysisLogEntry(
          payloadId: 'p3',
          at: DateTime.utc(2026, 11, 20, 7),
          state: AnalysisOutcomeState.needsConfirmation,
          reasonCode: AnalysisReason.directionConflict,
          inboxItem: _inbox(reasonCode: AnalysisReason.directionConflict)),
      AnalysisLogEntry(
          payloadId: 'p4',
          at: DateTime.utc(2026, 11, 20, 6),
          state: AnalysisOutcomeState.awaiting,
          text: 'Purchase EGP 10.00 card 4111111111111111'),
    ];

    Future<void> pump(WidgetTester tester, String locale) async {
      await tester.pumpWidget(consentApp(
        overrides: consentOverrides(
            FakeSettingsRepository(), FakeRegistrationService()),
        locale: locale,
        home: Scaffold(
            body: SingleChildScrollView(
                child: AnalysisLogList(entries: entries))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('each state with its sentence (ar)', (tester) async {
      await pump(tester, 'ar');
      expect(find.text('سُجّل مصروف 250 EGP'), findsOneWidget);
      expect(find.text('لم تُضَف'), findsOneWidget);
      expect(find.text('عملية مرفوضة أو لم تكتمل، ولم يتحرك أي مبلغ'),
          findsOneWidget);
      expect(find.text('تحتاج تأكيدك'), findsOneWidget);
      expect(find.text('لم يتضح إن كانت مصروفًا أم دخلًا، أكّد قبل التسجيل'),
          findsOneWidget);
      expect(find.text('بانتظار التحليل'), findsOneWidget);
      expect(find.text('ستُحلَّل تلقائيًا عند عودة الاتصال'), findsOneWidget);
    });

    testWidgets('each state with its sentence (en), masked text only',
        (tester) async {
      await pump(tester, 'en');
      expect(find.text('Saved: expense 250 EGP'), findsOneWidget);
      expect(find.text('Not added'), findsOneWidget);
      expect(find.text('A declined or failed operation; no money moved'),
          findsOneWidget);
      expect(find.text('Needs your confirmation'), findsOneWidget);
      expect(find.text('Awaiting analysis'), findsOneWidget);
      expect(find.textContaining('4111111111111111'), findsNothing,
          reason: 'the log never shows a full card number');
    });

    test('built from receipts: saved, held, duplicate and ignored captures',
        () async {
      final db = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(db.close);
      Future<void> receipt(String id, String target) => db.customStatement(
          "INSERT INTO dedup_hashes(hash, transaction_id, occurred_at, saved_at) "
          "VALUES ('capture_payload:$id', '$target', '2026-11-20T00:00:00Z', "
          "'2026-11-20T10:00:00.000Z');");
      await db.customStatement(
          "INSERT INTO transactions(id, amount, amount_minor, currency, type, "
          "source, occurred_at, raw_message, parse_confidence, status, "
          "created_at, updated_at) VALUES ('t1', 250, 25000, 'EGP', 'payment', "
          "'bank', "
          "'2026-11-20T09:00:00.000Z', 'Purchase', 1, 'confirmed', "
          "'2026-11-20T09:00:00.000Z', '2026-11-20T09:00:00.000Z');");
      await receipt('t1', 't1');
      await receipt('dup', 't1');
      await receipt('otp', 'ignored');
      final entries = await AnalysisLogRepository(db).recent();
      final byId = {for (final e in entries) e.payloadId: e};
      expect(byId['t1']!.state, AnalysisOutcomeState.saved);
      expect(byId['dup']!.state, AnalysisOutcomeState.notAdded);
      expect(byId['dup']!.reasonCode, AnalysisReason.duplicate);
      expect(byId['otp']!.state, AnalysisOutcomeState.notAdded);
      expect(byId['otp']!.text, isNull, reason: 'no OTP text is kept');
    });
  });

  group('record it anyway', () {
    test('pre-fills the proposal and the masked message', () {
      final prefill = inboxManualPrefill(_inbox(
          reasonCode: AnalysisReason.declined,
          proposal: const CaptureProposal(
              amountText: '250.00',
              currency: 'EGP',
              isDebit: true,
              merchant: 'CARREFOUR')));
      expect(prefill.amountText, '250.00');
      expect(prefill.currency, 'EGP');
      expect(prefill.merchant, 'CARREFOUR');
      expect(prefill.isDebit, isTrue);
      expect(prefill.messageText, contains('CARREFOUR'));
      expect(prefill.messageText, isNot(contains('4111111111111111')));
    });
  });
}
