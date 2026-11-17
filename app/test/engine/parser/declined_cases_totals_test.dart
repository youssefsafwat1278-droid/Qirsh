import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/ai/ai_parser_client.dart';
import 'package:money_companion/engine/ai/grounding_check.dart';

/// V1-001 residuals — end to end on an in-memory database: every
/// `not_completed` case of the shared table (`declined_cases.json`, also run by
/// the server tests) leaves spend, refund and income totals unchanged, on
/// device only and with consented AI answering a grounded payment or refund.
/// Each case also runs inside a known bank layout that the device would
/// otherwise auto-confirm. Synthetic data only.
const _casesPath = '../supabase/functions/process-ios-sms/declined_cases.json';

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

/// A consented AI that always claims a completed transaction, grounded on the
/// first amount of the message.
class _EagerAi implements AiParserClient {
  _EagerAi(this.type);
  final String type;

  @override
  Future<AiParseResponse?> parse({
    required String sanitizedSms,
    required String senderId,
    required String installId,
  }) async {
    final amounts = GroundingCheck.amountTokens(sanitizedSms);
    final amount = amounts.isEmpty ? 100.0 : amounts.first;
    return AiParseResponse(
      amount: amount,
      amountText: amount.toStringAsFixed(2),
      currency: 'SAR',
      type: type,
      direction: type == 'refund' ? 'credit' : 'debit',
    );
  }
}

/// SNB layout a known bank auto-confirms (see declined_transaction_test).
String _snb(String header) {
  final d = DateTime.now();
  final date = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
  return '$header\nمبلغ:SAR 100.00\nلدى:NETFLIX\nفي:$date 00:01';
}

void main() {
  final table = jsonDecode(File(_casesPath).readAsStringSync())
      as Map<String, dynamic>;
  final cases = (table['cases'] as List).cast<Map<String, dynamic>>();

  late AppDatabase db;
  late DriftTransactionRepository txRepo;

  setUp(() async {
    db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    txRepo = DriftTransactionRepository(db);
  });
  tearDown(() async => db.close());

  Future<void> expectTotalsUnchanged(String reason) async {
    final now = DateTime.now();
    final from = DateTime(now.year - 1);
    final to = DateTime(now.year + 1);
    for (final total in [
      await txRepo.expenseTotalBetween(from: from, to: to, currency: 'SAR'),
      await txRepo.refundTotalBetween(from: from, to: to, currency: 'SAR'),
      await txRepo.incomeTotalBetween(from: from, to: to, currency: 'SAR'),
    ]) {
      expect(total.isZero, isTrue, reason: reason);
    }
    final recent = await txRepo.getRecent(limit: 50, accountId: null);
    expect(recent.where((t) => t.status == TransactionStatus.confirmed),
        isEmpty,
        reason: reason);
  }

  // FR-13: the ignore-rule outcomes change no total on device either: a real
  // OTP/promotion is dropped, a purchase with a security footer is a review
  // row (with consented AI it is AI-read like any review-shaped message, so
  // only the on-device path is asserted for `review`).
  // V1-RES5 (NR-05): `device` is the on-device outcome where it knowingly
  // differs from the true outcome `expect` (no total change on device).
  String onDevice(Map<String, dynamic> c) =>
      (c['device'] ?? c['expect']) as String;
  for (final c in cases.where((c) => const [
        'not_completed',
        'review',
        'ignored',
        'dropped',
      ].contains(onDevice(c)))) {
    final text = c['text'] as String;
    // A real movement kept in review on device is AI-read like any review
    // row: only the on-device path is asserted for it.
    final completed = (c['expect'] as String).startsWith('completed_');
    final withAi = onDevice(c) != 'review' && !completed;
    // A review row that is not an account notice (its own words read as a
    // movement: "Transfer limit SAR 5,000", a purchase code) is, with a bank
    // layout appended, a second movement as for a completed row: only the
    // message itself is asserted (V1-RES4 X19 was pinned `dropped` for this).
    // Round 9 (PR-02): a notice word no longer silences the message it is
    // in, so a notice row (now `review`) with a movement appended records
    // that movement — the composite is asserted only for a cue
    // (not_completed) or a genuine OTP/promotion (ignored).
    final composite = !completed &&
        const ['not_completed', 'ignored'].contains(onDevice(c));
    test('[${c['src']}] ${onDevice(c)}: totals unchanged: $text', () async {
      // The bank layout appended to a real movement, or to a notice whose
      // own words name a transfer, is a second movement (NR-01).
      for (final sms in [
        text,
        if (composite) _snb(text),
      ]) {
        for (final sender in ['SNB', 'AlRajhi']) {
          await AddTransactionUseCase(
            transactionRepository: txRepo,
            merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          )(rawMessage: sms, senderId: sender, onDeviceOnly: true);
          for (final type in [
            if (withAi) ...['payment', 'refund']
          ]) {
            await AddTransactionUseCase(
              transactionRepository: txRepo,
              merchantCategoryRepository: DriftMerchantCategoryRepository(db),
              aiClient: _EagerAi(type),
              loadAiConsent: () async => true,
            )(rawMessage: sms, senderId: sender);
          }
        }
        await expectTotalsUnchanged(sms);
      }
    });
  }

  // V1-RES4 (LR-04): a genuine salary/deposit, cash withdrawal or incoming
  // transfer is still recorded on device, with the type that moves the right
  // total.
  const otherCompleted = {
    'completed_income': TransactionTypeEntity.income,
    'completed_withdrawal': TransactionTypeEntity.withdrawal,
    // The parser reads a transfer; the use case records the incoming one as
    // income (it moves the income total).
    'completed_transfer_in': TransactionTypeEntity.income,
  };
  // (Round 10: an open defect row — Q's probes — is pinned at its outcome by
  // the table test; it is not asserted to move the right total here.)
  for (final c in cases.where((c) =>
      otherCompleted.containsKey(onDevice(c)) && c['defect'] == null)) {
    final text = c['text'] as String;
    test('[${c['src']}] ${c['expect']} is recorded: $text', () async {
      final r = await AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
      )(rawMessage: text, senderId: 'AlRajhi', onDeviceOnly: true);
      // Round 9 (PR-08): an ATM cash deposit is income (OR-07 fixed).
      expect(r.transaction?.type, otherCompleted[onDevice(c)],
          reason: '${r.outcome}');
      expect(r.transaction?.amount, closeTo(c['amount'] as num, 0.005));
    });
  }

  // A completed purchase or refund is still recorded, with the type that moves
  // the right total (never diverted to Smart Inbox by the rule).
  for (final c in cases.where((c) =>
      const ['completed_payment', 'completed_credit'].contains(onDevice(c)) &&
      c['defect'] == null)) {
    final text = c['text'] as String;
    // An open wrong-direction defect is pinned at the outcome it has.
    final payment = onDevice(c) == 'completed_payment';
    test('[${c['src']}] ${c['expect']} is recorded: $text', () async {
      final r = await AddTransactionUseCase(
        transactionRepository: txRepo,
        merchantCategoryRepository: DriftMerchantCategoryRepository(db),
        aiClient: _EagerAi(payment ? 'payment' : 'refund'),
        loadAiConsent: () async => true,
      )(rawMessage: text, senderId: 'AlRajhi');
      expect(r.transaction?.type,
          payment ? TransactionTypeEntity.payment : TransactionTypeEntity.refund,
          reason: '${r.outcome}');
      // (or, for a foreign purchase, the foreign amount in its currency).
      final foreign = c['foreign'] as Map<String, dynamic>?;
      expect(
          r.transaction?.amount,
          closeTo(
              (foreign != null && r.transaction?.currency == foreign['currency']
                  ? foreign['amount']
                  : c['amount']) as num,
              0.005));
    });
  }
}
