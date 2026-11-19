// Gemini-first analysis, phase 1: every server reason code has its own
// Arabic and English sentence; the generic "unsupported" title is used only
// when no reason is known; a person transfer is shown without a name.
import 'dart:ui' show Locale;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_smart_inbox_repository.dart';
import 'package:money_companion/domain/capture/analysis_reason.dart';
import 'package:money_companion/domain/entities/smart_inbox_item_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/capture/analysis_reason_text.dart';
import 'package:money_companion/l10n/app_localizations.dart';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

TransactionEntity _tx({
  String? merchant,
  TransactionDirectionEntity? direction,
  String? transferGroupId,
}) {
  final now = DateTime.utc(2026, 11, 18, 18, 36);
  return TransactionEntity(
    id: 't1',
    amountMoney: Money.parse('754.00', 'EGP'),
    currency: 'EGP',
    type: direction == TransactionDirectionEntity.credit
        ? TransactionTypeEntity.income
        : TransactionTypeEntity.payment,
    source: TransactionSourceEntity.aiParsed,
    occurredAt: now,
    rawMessage: 'IPN transfer sent',
    parseConfidence: 0.9,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    rawMerchant: merchant,
    direction: direction,
    transferGroupId: transferGroupId,
  );
}

void main() {
  final ar = lookupAppL10n(const Locale('ar'));
  final en = lookupAppL10n(const Locale('en'));

  test('every reason code has its own Arabic and English sentence', () {
    for (final l10n in [ar, en]) {
      final texts = {
        for (final code in AnalysisReason.all) analysisReasonText(l10n, code)
      };
      expect(texts.length, AnalysisReason.all.length, reason: l10n.localeName);
      for (final t in texts) {
        expect(t, isNot(contains('غير مدعومة')));
        expect(t.toLowerCase(), isNot(contains('unsupported')));
      }
    }
    expect(analysisReasonText(ar, 'promo'),
        'عرض أو رسالة تسويقية، ولا تحتوي على عملية');
    expect(analysisReasonText(en, 'direction_conflict'),
        'Unclear whether this is spending or income; confirm before recording');
    expect(analysisReasonText(ar, 'amount_mismatch'),
        'المبلغ لا يطابق نص الرسالة، أكّده قبل التسجيل');
  });

  test('reason of an item: the server code, else the stored review reason', () {
    expect(AnalysisReason.of(reasonCode: 'otp'), 'otp');
    expect(AnalysisReason.of(reasonCode: 'free text from a model'), isNull);
    expect(AnalysisReason.of(reviewReason: 'bill_due'), 'payment_reminder');
    expect(AnalysisReason.of(reviewReason: 'direction_contradiction'),
        'direction_conflict');
    expect(AnalysisReason.of(reviewReason: 'cash_deposit'), 'unclear');
    expect(
        AnalysisReason.of(
            reviewReason: SmartInboxReviewReason.analysisUnavailable),
        isNull);
    expect(AnalysisReason.of(), isNull);
  });

  test('re-analyse only where a new analysis can change the outcome', () {
    expect(AnalysisReason.canReanalyse(code: null, aiAnalysed: false), isTrue);
    expect(AnalysisReason.canReanalyse(code: 'unclear', aiAnalysed: false),
        isTrue);
    expect(AnalysisReason.canReanalyse(code: 'unclear', aiAnalysed: true),
        isFalse);
    for (final code in AnalysisReason.all.where((c) => c != 'unclear')) {
      expect(AnalysisReason.canReanalyse(code: code, aiAnalysed: false),
          isFalse, reason: code);
    }
  });

  test('proposal: only a well-formed reading is kept', () {
    final p = CaptureProposal.fromJson({
      'amount': 120,
      'amount_text': '120.00',
      'currency': 'EGP',
      'direction': 'credit',
      'merchant': 'InstaPay',
      'counterpartyKind': 'person',
    })!;
    expect([p.amountText, p.currency, p.isDebit, p.merchant],
        ['120.00', 'EGP', false, 'InstaPay']);
    expect(CaptureProposal.fromJson({'amount_text': '0', 'currency': 'EGP',
        'direction': 'debit'}), isNull);
    expect(CaptureProposal.fromJson({'amount_text': '12', 'currency': 'egp',
        'direction': 'debit'}), isNull);
    expect(CaptureProposal.fromJson({'amount_text': '12', 'currency': 'EGP',
        'direction': 'unknown'}), isNull);
  });

  test('a transfer to or from a person is shown without a name', () {
    final out = _tx(merchant: 'InstaPay',
        direction: TransactionDirectionEntity.debit);
    final inn = _tx(direction: TransactionDirectionEntity.credit);
    expect(personTransferTitle(ar, out, 'transfers'), 'تحويل لصديق');
    expect(personTransferTitle(en, out, 'transfers'), 'Transfer to a friend');
    expect(personTransferTitle(ar, inn, 'transfers'), 'تحويل من صديق');
    expect(personTransferTitle(en, inn, 'transfers'), 'Transfer from a friend');
    // A business, a purchase, or one leg of a move between own accounts.
    expect(personTransferTitle(en, _tx(merchant: 'Test Mart',
        direction: TransactionDirectionEntity.debit), 'transfers'), isNull);
    expect(personTransferTitle(en, out, 'shopping'), isNull);
    expect(personTransferTitle(en, _tx(direction: TransactionDirectionEntity.debit,
        transferGroupId: 'g'), 'transfers'), isNull);
  });

  test('inbox row: reason title, code, proposal and AI flag persist', () async {
    final db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    addTearDown(db.close);
    final repo = DriftSmartInboxRepository(db);
    await repo.saveUnprocessableCapture(
      payloadId: 'p1',
      rawMessage: 'Purchase of EGP 45.00 at Test Mart',
      source: 'backend_rejected',
      lang: 'en',
      reviewReason: 'amount_mismatch',
      server: ServerReviewInfo.fromParsed({
        'parserSource': 'ai',
        'reasonCode': 'amount_mismatch',
        'proposal': {'amount_text': '54.00', 'currency': 'EGP',
          'direction': 'debit', 'merchant': 'Test Mart'},
      }),
      reasonTitle: analysisReasonText(en, 'amount_mismatch'),
    );
    await repo.saveUnprocessableCapture(
        payloadId: 'p2', rawMessage: 'x', source: 'sms', lang: 'ar');
    final items = {for (final i in await repo.getOpen()) i.payloadId: i};
    final held = items['p1']!;
    expect(held.title, analysisReasonText(en, 'amount_mismatch'));
    expect(held.reasonCode, 'amount_mismatch');
    expect(held.aiAnalysed, isTrue);
    expect(held.proposal!.amountText, '54.00');
    expect(inboxCanReanalyse(held), isFalse);
    // No reason known: the generic title, and re-analysis is offered.
    final unknown = items['p2']!;
    expect(unknown.title, 'رسالة بنكية غير مدعومة تحتاج مراجعة');
    expect(inboxItemTitle(ar, unknown), 'رسالة بنكية غير مدعومة تحتاج مراجعة');
    expect(inboxCanReanalyse(unknown), isTrue);
  });
}
