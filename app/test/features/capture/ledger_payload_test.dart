import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/features/capture/services/ledger_payload.dart';

// MALI-056n / MALI-009 / MALI-010 — the canonical ledger payload codec. Proves
// the enum mapping table, the lossless v2 round-trip, and the documented
// compatibility rule for old / future / unknown values.

void main() {
  group('server column mapping (client type → coarse server column)', () {
    test('coarse transaction_type collapses payment/withdrawal to expense', () {
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.payment), 'expense');
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.withdrawal), 'expense');
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.income), 'income');
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.refund), 'refund');
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.transfer), 'transfer');
      expect(LedgerPayloadCodec.serverTransactionType(TransactionTypeEntity.unknown), 'unknown');
    });

    test('direction is derived losslessly only where meaningful', () {
      String dir(TransactionTypeEntity t) =>
          LedgerPayloadCodec.serverDirection(t, TransactionDirectionEntity.unknown);
      expect(dir(TransactionTypeEntity.income), 'credit');
      expect(dir(TransactionTypeEntity.refund), 'credit');
      expect(dir(TransactionTypeEntity.payment), 'debit');
      expect(dir(TransactionTypeEntity.withdrawal), 'debit');
      expect(dir(TransactionTypeEntity.transfer), 'unknown');
      expect(dir(TransactionTypeEntity.unknown), 'unknown');
    });

    test('an explicit direction always wins over derivation', () {
      expect(
        LedgerPayloadCodec.serverDirection(
            TransactionTypeEntity.transfer, TransactionDirectionEntity.debit),
        'debit',
      );
    });
  });

  group('v2 canonical round-trip (lossless for every type)', () {
    for (final type in TransactionTypeEntity.values) {
      test('type $type round-trips exactly via canonical metadata', () {
        final recovered = LedgerPayloadCodec.typeFromPull(
          canonicalType: type.name,
          serverTransactionType:
              LedgerPayloadCodec.serverTransactionType(type),
        );
        expect(recovered, type);
      });
    }

    for (final source in TransactionSourceEntity.values) {
      test('source $source round-trips exactly via canonical metadata', () {
        final recovered = LedgerPayloadCodec.sourceFromPull(
          canonicalSource: source.name,
          serverSource: 'ignored',
        );
        expect(recovered, source);
      });
    }
  });

  group('compatibility rule (old rows without canonical metadata)', () {
    TransactionTypeEntity legacy(String serverType) =>
        LedgerPayloadCodec.typeFromPull(
            canonicalType: null, serverTransactionType: serverType);

    test('income/refund/transfer map directly', () {
      expect(legacy('income'), TransactionTypeEntity.income);
      expect(legacy('refund'), TransactionTypeEntity.refund);
      expect(legacy('transfer'), TransactionTypeEntity.transfer);
    });

    test('legacy expense is interpreted as payment (documented rule)', () {
      expect(legacy('expense'), TransactionTypeEntity.payment);
    });

    test('adjustment / unknown / any future category → unknown, NEVER payment',
        () {
      expect(legacy('adjustment'), TransactionTypeEntity.unknown);
      expect(legacy('unknown'), TransactionTypeEntity.unknown);
      expect(legacy('some_future_category'), TransactionTypeEntity.unknown);
    });
  });

  group('future / unknown value safety', () {
    test('an unrecognised canonical type name falls back to the coarse column, '
        'never silently payment', () {
      // A newer app wrote canonical_type this build does not know. It must not
      // be trusted verbatim; fall back to the coarse column.
      final recovered = LedgerPayloadCodec.typeFromPull(
        canonicalType: 'crypto_swap', // unknown to this build
        serverTransactionType: 'unknown',
      );
      expect(recovered, TransactionTypeEntity.unknown);
    });

    test('an unrecognised canonical source name falls back safely', () {
      expect(
        LedgerPayloadCodec.sourceFromPull(
            canonicalSource: 'nfc_tap', serverSource: 'manual'),
        TransactionSourceEntity.unknown,
      );
    });
  });

  group('direction recovery', () {
    test('canonical direction wins; otherwise derived from the recovered type',
        () {
      expect(
        LedgerPayloadCodec.directionFromPull(
            canonicalDirection: 'credit', type: TransactionTypeEntity.payment),
        TransactionDirectionEntity.credit,
      );
      expect(
        LedgerPayloadCodec.directionFromPull(
            canonicalDirection: null, type: TransactionTypeEntity.withdrawal),
        TransactionDirectionEntity.debit,
      );
      expect(
        LedgerPayloadCodec.directionFromPull(
            canonicalDirection: null, type: TransactionTypeEntity.transfer),
        TransactionDirectionEntity.unknown,
      );
    });

    test('a transfer without canonical direction takes the server direction '
        'column; other types ignore it', () {
      TransactionDirectionEntity pull(
              TransactionTypeEntity type, String? serverDirection,
              [String? canonical]) =>
          LedgerPayloadCodec.directionFromPull(
              canonicalDirection: canonical,
              type: type,
              serverDirection: serverDirection);
      const t = TransactionTypeEntity.transfer;
      expect(pull(t, 'credit'), TransactionDirectionEntity.credit);
      expect(pull(t, 'debit'), TransactionDirectionEntity.debit);
      expect(pull(t, 'unknown'), TransactionDirectionEntity.unknown);
      expect(pull(t, null), TransactionDirectionEntity.unknown);
      expect(pull(t, 'credit', 'debit'), TransactionDirectionEntity.debit,
          reason: 'canonical metadata still wins');
      for (final (type, expected) in [
        (TransactionTypeEntity.payment, TransactionDirectionEntity.debit),
        (TransactionTypeEntity.withdrawal, TransactionDirectionEntity.debit),
        (TransactionTypeEntity.income, TransactionDirectionEntity.credit),
        (TransactionTypeEntity.refund, TransactionDirectionEntity.credit),
        (TransactionTypeEntity.unknown, TransactionDirectionEntity.unknown),
      ]) {
        for (final server in ['credit', 'debit', 'unknown', null]) {
          expect(pull(type, server), expected, reason: '$type / $server');
        }
      }
    });
  });
}
