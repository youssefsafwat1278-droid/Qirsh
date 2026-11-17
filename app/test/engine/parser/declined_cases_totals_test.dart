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

  for (final c in cases.where((c) => c['expect'] == 'not_completed')) {
    final text = c['text'] as String;
    test('[${c['src']}] totals unchanged: $text', () async {
      for (final sms in [text, _snb(text)]) {
        for (final sender in ['SNB', 'AlRajhi']) {
          await AddTransactionUseCase(
            transactionRepository: txRepo,
            merchantCategoryRepository: DriftMerchantCategoryRepository(db),
          )(rawMessage: sms, senderId: sender, onDeviceOnly: true);
          for (final type in ['payment', 'refund']) {
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

  // A completed purchase or refund is still recorded, with the type that moves
  // the right total (never diverted to Smart Inbox by the rule).
  for (final c in cases.where((c) => c['expect'] != 'not_completed')) {
    final text = c['text'] as String;
    final payment = c['expect'] == 'completed_payment';
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
    });
  }
}
