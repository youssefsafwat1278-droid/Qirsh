import '../../../domain/entities/transaction_entity.dart';

/// MALI-056n / MALI-009 / MALI-010 — the explicit, versioned canonical ledger
/// sync payload contract.
///
/// The server's `transaction_type` column is a COARSE category
/// (income/expense/transfer/refund/adjustment/unknown) that cannot distinguish
/// the client's finer types — `payment` and `withdrawal` both map to `expense`,
/// and there is no server slot for a genuinely `unknown` client type. Before
/// this, the round-trip collapsed withdrawal→expense→payment and, worse,
/// unknown→expense→payment, silently rewriting a transaction's financial
/// meaning across devices.
///
/// The canonical payload (version 2) preserves the EXACT client type, source and
/// direction by round-tripping them through the server `metadata` JSONB, while
/// still writing the coarse columns for server-side reporting. On pull the
/// canonical metadata is authoritative; older rows without it fall back to a
/// DOCUMENTED compatibility rule that never invents a `payment`/`expense`
/// meaning for an unmapped or future category.
///
/// ── Enum mapping table ───────────────────────────────────────────────────────
///  client type  server transaction_type  server direction (when unset)
///  payment      expense                   debit
///  withdrawal   expense                   debit
///  income       income                    credit
///  refund       refund                    credit
///  transfer     transfer                  unknown (no lossless direction)
///  unknown      unknown                   unknown
///
///  pull recovery (v2): metadata.canonical_type/source/direction → exact enum.
///  pull recovery (v1/old server row, no canonical metadata):
///    income→income, refund→refund, transfer→transfer,
///    expense→payment (documented legacy rule; withdrawal was indistinguishable),
///    adjustment/unknown/any-future→unknown  (NEVER payment/expense).
const int kLedgerPayloadVersion = 2;

/// Canonical mapping between the client transaction enums and the server ledger
/// representation. Pure + total; unknown/future inputs map to safe values.
class LedgerPayloadCodec {
  const LedgerPayloadCodec._();

  /// Client type → server `transaction_type` (coarse category).
  static String serverTransactionType(TransactionTypeEntity type) =>
      switch (type) {
        TransactionTypeEntity.income => 'income',
        TransactionTypeEntity.refund => 'refund',
        TransactionTypeEntity.transfer => 'transfer',
        TransactionTypeEntity.payment => 'expense',
        TransactionTypeEntity.withdrawal => 'expense',
        TransactionTypeEntity.unknown => 'unknown',
      };

  /// Client type + explicit direction → server `direction`. An explicit
  /// direction wins; otherwise it is derived from the type only where lossless
  /// (income/refund→credit, payment/withdrawal→debit; transfer/unknown→unknown).
  static String serverDirection(
    TransactionTypeEntity type,
    TransactionDirectionEntity direction,
  ) {
    if (direction != TransactionDirectionEntity.unknown) return direction.name;
    return switch (type) {
      TransactionTypeEntity.income => 'credit',
      TransactionTypeEntity.refund => 'credit',
      TransactionTypeEntity.payment => 'debit',
      TransactionTypeEntity.withdrawal => 'debit',
      TransactionTypeEntity.transfer => 'unknown',
      TransactionTypeEntity.unknown => 'unknown',
    };
  }

  /// Server `transaction_type` for a canonical type NAME (as carried in the
  /// payload). An unrecognised/future name maps to `unknown`, never `expense`.
  static String serverTransactionTypeFor(String canonicalType) =>
      serverTransactionType(
          _parseType(canonicalType) ?? TransactionTypeEntity.unknown);

  /// Server `direction` for a canonical type + direction NAME (as carried in the
  /// payload).
  static String serverDirectionFor(
    String canonicalType,
    String? canonicalDirection,
  ) =>
      serverDirection(
        _parseType(canonicalType) ?? TransactionTypeEntity.unknown,
        _parseDirection(canonicalDirection) ??
            TransactionDirectionEntity.unknown,
      );

  /// Recover the EXACT client type on pull. Prefers the canonical metadata
  /// value (lossless); falls back to the documented coarse-column rule. A
  /// canonical value the current build does not recognise (future enum) is
  /// treated as absent → coarse fallback → `unknown`, never `payment`.
  static TransactionTypeEntity typeFromPull({
    String? canonicalType,
    required String serverTransactionType,
  }) {
    final canon = _parseType(canonicalType);
    if (canon != null) return canon;
    return switch (serverTransactionType) {
      'income' => TransactionTypeEntity.income,
      'refund' => TransactionTypeEntity.refund,
      'transfer' => TransactionTypeEntity.transfer,
      'expense' => TransactionTypeEntity.payment,
      _ => TransactionTypeEntity.unknown,
    };
  }

  /// Recover the client source on pull (canonical first, else the legacy rule).
  static TransactionSourceEntity sourceFromPull({
    String? canonicalSource,
    required String serverSource,
  }) {
    final canon = _parseSource(canonicalSource);
    if (canon != null) return canon;
    return switch (serverSource) {
      'ios_shortcut' ||
      'android_sms' ||
      'share_extension' =>
        TransactionSourceEntity.bank,
      'import' => TransactionSourceEntity.imported,
      _ => TransactionSourceEntity.unknown,
    };
  }

  /// Recover the client direction on pull (canonical first, else derived). A
  /// transfer has no direction implied by its type, so without canonical
  /// metadata it takes the server `direction` column (debit/credit) — the
  /// backfill and older pushes wrote the explicit direction there.
  static TransactionDirectionEntity directionFromPull({
    String? canonicalDirection,
    required TransactionTypeEntity type,
    String? serverDirection,
  }) {
    final canon = _parseDirection(canonicalDirection);
    if (canon != null) return canon;
    return switch (type) {
      TransactionTypeEntity.income => TransactionDirectionEntity.credit,
      TransactionTypeEntity.refund => TransactionDirectionEntity.credit,
      TransactionTypeEntity.payment => TransactionDirectionEntity.debit,
      TransactionTypeEntity.withdrawal => TransactionDirectionEntity.debit,
      TransactionTypeEntity.transfer => switch (serverDirection) {
          'debit' => TransactionDirectionEntity.debit,
          'credit' => TransactionDirectionEntity.credit,
          _ => TransactionDirectionEntity.unknown,
        },
      _ => TransactionDirectionEntity.unknown,
    };
  }

  static TransactionTypeEntity? _parseType(String? name) {
    if (name == null) return null;
    for (final v in TransactionTypeEntity.values) {
      if (v.name == name) return v;
    }
    return null; // future/unknown canonical → treat as absent
  }

  static TransactionSourceEntity? _parseSource(String? name) {
    if (name == null) return null;
    for (final v in TransactionSourceEntity.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  static TransactionDirectionEntity? _parseDirection(String? name) {
    if (name == null) return null;
    for (final v in TransactionDirectionEntity.values) {
      if (v.name == name) return v;
    }
    return null;
  }
}
