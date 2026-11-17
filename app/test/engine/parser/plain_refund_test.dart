import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/repositories/drift_transaction_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/usecases/add_transaction_usecase.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/engine/parser/parser_engine.dart';

/// V1-001 residuals, round 4 — a plain English refund ("Refund SAR 99.00 from
/// …") had no amount on device: `ref` inside "refund" made the amount a
/// reference number. A promotional maximum ("a refund of up to SAR 50") must
/// not become a credit. Synthetic data only.
class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';

  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

const _refunds = <String>[
  'Refund SAR 99.00 from SHOP TWO',
  'Refund of SAR 99.00 from SHOP TWO',
  'Refund of SAR 99.00 from SHOP TWO to your card **1234',
  'استرداد مبلغ ٩٩٫٠٠ ريال من SHOP TWO',
];

const _promotions = <String>[
  'Get a refund of up to SAR 50 on your next purchase',
  'احصل على استرداد يصل إلى 50 ريال على مشترياتك',
];

void main() {
  const engine = ParserEngine();

  for (final text in _refunds) {
    test('a plain refund is read as a refund on device: $text', () {
      final r = engine.parse(text, senderId: 'AlRajhi');
      expect(r.isTransaction, isTrue);
      expect(r.transaction!.type, TransactionType.refund);
      expect(r.transaction!.amount, 99.0);
    });
  }

  for (final text in _promotions) {
    test('a promotional maximum is not an amount: $text', () {
      final r = engine.parse(text, senderId: 'AlRajhi');
      expect(r.isTransaction, isFalse);
    });
  }

  test('end to end (on device only): a refund is captured, a promotion is not',
      () async {
    final db = await AppDatabase.open(
      executor: NativeDatabase.memory(),
      keyStore: _MemoryKeyStore(),
    );
    addTearDown(db.close);
    final txRepo = DriftTransactionRepository(db);
    final add = AddTransactionUseCase(
      transactionRepository: txRepo,
      merchantCategoryRepository: DriftMerchantCategoryRepository(db),
    );
    for (final text in _promotions) {
      final r =
          await add(rawMessage: text, senderId: 'AlRajhi', onDeviceOnly: true);
      expect(r.transaction, isNull, reason: text);
    }
    final r = await add(
        rawMessage: _refunds.first, senderId: 'AlRajhi', onDeviceOnly: true);
    expect(r.outcome, AddTransactionOutcome.added);
    // Recorded as a refund (pending the user's confirmation, like any
    // on-device parse below the auto-confirm bar), never income or spend.
    expect(r.transaction!.type, TransactionTypeEntity.refund);
    expect(r.transaction!.amount, 99.0);

    final now = DateTime.now();
    final from = DateTime(now.year - 1);
    final to = DateTime(now.year + 1);
    expect(
        (await txRepo.incomeTotalBetween(from: from, to: to, currency: 'SAR'))
            .isZero,
        isTrue);
    expect(
        (await txRepo.expenseTotalBetween(from: from, to: to, currency: 'SAR'))
            .isZero,
        isTrue);
  });
}
