import 'package:drift/drift.dart';

import '../../core/utils/id_generator.dart';
import 'app_database.dart';
import 'sql_value_codec.dart';

/// Stable merchant identity for transactions.
///
/// A transaction's merchant is the `merchants` row whose `normalized_name`
/// equals [AppDatabase.normalizeMerchant] of its trimmed `raw_merchant`
/// (upper-case, ASCII digits removed, whitespace collapsed). That is the same
/// deterministic key every capture path and every merchant rule uses; nothing
/// here guesses, scores or fuzzy-matches.
///
/// Transfers and income carry a person or employer where a merchant would be,
/// so — exactly like `saveTransaction` — they never get a merchant link.
const kMerchantlessTransactionTypes = {'transfer', 'income'};

/// The `merchants` id for [rawMerchant], created when absent. Null when the
/// text normalises to nothing.
Future<String?> resolveOrCreateMerchantId(
  DatabaseConnectionUser db,
  String rawMerchant,
) async {
  final trimmed = rawMerchant.trim();
  final normalized = AppDatabase.normalizeMerchant(trimmed);
  if (normalized.isEmpty) return null;
  final existing = await db.customSelect(
    'SELECT id FROM merchants WHERE normalized_name = ? LIMIT 1;',
    variables: [Variable.withString(normalized)],
  ).getSingleOrNull();
  if (existing != null) return existing.read<String>('id');
  final id = IdGenerator.next();
  final now = dateTimeToSql(DateTime.now().toUtc());
  await db.customInsert(
    'INSERT INTO merchants(id, raw_name, normalized_name, first_seen_at, last_seen_at) '
    'VALUES (?, ?, ?, ?, ?);',
    variables: [
      Variable.withString(id),
      Variable.withString(trimmed),
      Variable.withString(normalized),
      Variable.withString(now),
      Variable.withString(now),
    ],
  );
  return id;
}

/// Links every transaction that has merchant text but no (or a dangling)
/// merchant link, by the deterministic key above. Returns how many rows were
/// linked. Idempotent; touches nothing else (no category, no provenance, no
/// sync state — the link is device-local and never synced).
Future<int> repairMissingMerchantLinks(DatabaseConnectionUser db) async {
  final rows = await db.customSelect(
    'SELECT t.id, t.raw_merchant FROM transactions t '
    'WHERE t.raw_merchant IS NOT NULL AND trim(t.raw_merchant) <> \'\' '
    "AND t.type NOT IN ('transfer', 'income') "
    'AND (t.merchant_id IS NULL '
    '     OR NOT EXISTS (SELECT 1 FROM merchants m WHERE m.id = t.merchant_id));',
  ).get();
  var linked = 0;
  for (final row in rows) {
    final merchantId =
        await resolveOrCreateMerchantId(db, row.read<String>('raw_merchant'));
    if (merchantId == null) continue;
    await db.customUpdate(
      'UPDATE transactions SET merchant_id = ? WHERE id = ?;',
      variables: [
        Variable.withString(merchantId),
        Variable.withString(row.read<String>('id')),
      ],
    );
    linked++;
  }
  return linked;
}

/// The merchant ids that are the SAME merchant as [merchantId]: itself, the
/// merchant it is an active verified alias of, and every merchant that is an
/// active verified alias of that one. Aliases come only from an explicit user
/// confirmation or the verified catalog (`merchant_aliases.origin`), and a
/// revoked alias (`revoked_at`) is ignored, so removing one restores the
/// previous matching exactly.
Future<Set<String>> sameMerchantIds(
  DatabaseConnectionUser db,
  String merchantId,
) async {
  // The canonical merchant: the target of an active alias of this one's name.
  final canonicalRow = await db.customSelect(
    'SELECT a.merchant_id AS id FROM merchant_aliases a '
    'JOIN merchants m ON m.normalized_name = a.alias_normalized '
    'WHERE m.id = ? AND a.revoked_at IS NULL LIMIT 1;',
    variables: [Variable.withString(merchantId)],
  ).getSingleOrNull();
  final canonical = canonicalRow?.read<String>('id') ?? merchantId;
  final aliased = await db.customSelect(
    'SELECT m.id FROM merchant_aliases a '
    'JOIN merchants m ON m.normalized_name = a.alias_normalized '
    'WHERE a.merchant_id = ? AND a.revoked_at IS NULL;',
    variables: [Variable.withString(canonical)],
  ).get();
  return {merchantId, canonical, ...aliased.map((r) => r.read<String>('id'))};
}
