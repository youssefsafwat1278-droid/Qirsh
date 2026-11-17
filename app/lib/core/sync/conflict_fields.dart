/// WP-5 / SYNC-Q5 — the meaningful field differences of a conflict.
///
/// A conflict stores two snapshots in different vocabularies: [mine] is the
/// LOCAL row (local column names), [theirs] is the CLOUD row (server column
/// names). Each entity lists the fields a person can recognise; a field whose
/// two values normalise equal is not a difference.
library;

import 'conflict_policy.dart';

/// What a field's value is, which decides how it is compared and shown.
enum ConflictFieldKind { text, amount, date, flag }

/// Stable keys; the screen maps each to its label string.
enum ConflictFieldKey {
  amount,
  currency,
  merchant,
  note,
  date,
  status,
  category,
  name,
  type,
  balance,
  initialBalance,
  creditLimit,
  period,
  startDate,
  endDate,
  frequency,
  nextDue,
  targetAmount,
  deadline,
  nickname,
  last4,
  active,
}

class ConflictFieldSpec {
  const ConflictFieldSpec(this.key, this.localCol, this.serverCol,
      [this.kind = ConflictFieldKind.text]);
  final ConflictFieldKey key;
  final String localCol;
  final String serverCol;
  final ConflictFieldKind kind;
}

/// One displayed difference; a null side means "not set".
class ConflictFieldDiff {
  const ConflictFieldDiff(this.key, this.mine, this.cloud);
  final ConflictFieldKey key;
  final String? mine;
  final String? cloud;
}

const _amount = ConflictFieldKind.amount;
const _date = ConflictFieldKind.date;
const _flag = ConflictFieldKind.flag;

const Map<String, List<ConflictFieldSpec>> kConflictFields = {
  ConflictEntities.transaction: [
    ConflictFieldSpec(ConflictFieldKey.amount, 'amount', 'amount', _amount),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(ConflictFieldKey.merchant, 'raw_merchant', 'merchant'),
    ConflictFieldSpec(ConflictFieldKey.note, 'note', 'description'),
    ConflictFieldSpec(ConflictFieldKey.date, 'occurred_at', 'occurred_at', _date),
    ConflictFieldSpec(ConflictFieldKey.status, 'status', 'status'),
    ConflictFieldSpec(ConflictFieldKey.category, 'category_key', 'category_id'),
  ],
  ConflictEntities.account: [
    ConflictFieldSpec(ConflictFieldKey.name, 'name', 'name'),
    ConflictFieldSpec(ConflictFieldKey.type, 'type', 'type'),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(
        ConflictFieldKey.initialBalance, 'initial_balance', 'initial_balance', _amount),
    ConflictFieldSpec(
        ConflictFieldKey.balance, 'current_balance', 'current_balance', _amount),
    ConflictFieldSpec(
        ConflictFieldKey.creditLimit, 'credit_limit', 'credit_limit', _amount),
  ],
  ConflictEntities.budget: [
    ConflictFieldSpec(ConflictFieldKey.amount, 'amount', 'amount', _amount),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(ConflictFieldKey.period, 'period', 'period'),
    ConflictFieldSpec(ConflictFieldKey.startDate, 'start_date', 'start_date', _date),
    ConflictFieldSpec(ConflictFieldKey.active, 'is_active', 'is_active', _flag),
  ],
  ConflictEntities.subscription: [
    ConflictFieldSpec(ConflictFieldKey.name, 'name', 'name'),
    ConflictFieldSpec(ConflictFieldKey.amount, 'amount', 'amount', _amount),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(ConflictFieldKey.frequency, 'frequency', 'frequency'),
    ConflictFieldSpec(ConflictFieldKey.nextDue, 'next_due_date', 'next_due_date', _date),
    ConflictFieldSpec(ConflictFieldKey.status, 'status', 'status'),
    ConflictFieldSpec(ConflictFieldKey.note, 'note', 'note'),
  ],
  ConflictEntities.goal: [
    ConflictFieldSpec(ConflictFieldKey.name, 'name', 'name'),
    ConflictFieldSpec(
        ConflictFieldKey.targetAmount, 'target_amount', 'target_amount', _amount),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(ConflictFieldKey.deadline, 'deadline', 'deadline', _date),
    ConflictFieldSpec(ConflictFieldKey.status, 'status', 'status'),
  ],
  ConflictEntities.plan: [
    ConflictFieldSpec(ConflictFieldKey.name, 'name', 'name'),
    ConflictFieldSpec(ConflictFieldKey.amount, 'budget_amount', 'budget_amount', _amount),
    ConflictFieldSpec(ConflictFieldKey.currency, 'currency', 'currency'),
    ConflictFieldSpec(ConflictFieldKey.startDate, 'start_date', 'start_date', _date),
    ConflictFieldSpec(ConflictFieldKey.endDate, 'end_date', 'end_date', _date),
    ConflictFieldSpec(ConflictFieldKey.status, 'status', 'status'),
  ],
  ConflictEntities.card: [
    ConflictFieldSpec(ConflictFieldKey.nickname, 'nickname', 'nickname'),
    ConflictFieldSpec(ConflictFieldKey.last4, 'last4', 'last4'),
  ],
  ConflictEntities.category: [
    ConflictFieldSpec(ConflictFieldKey.name, 'name_ar', 'name_ar'),
  ],
};

/// The fields whose two normalised values differ. Empty for an entity with no
/// field list, or when either snapshot is missing (a tombstone has no cloud
/// fields to compare).
List<ConflictFieldDiff> diffConflictFields(
  String entityType,
  Map<String, dynamic>? mine,
  Map<String, dynamic>? theirs,
) {
  final specs = kConflictFields[entityType];
  if (specs == null || mine == null || theirs == null) return const [];
  final out = <ConflictFieldDiff>[];
  for (final f in specs) {
    final a = _norm(mine[f.localCol], f.kind);
    final b = _norm(theirs[f.serverCol], f.kind);
    if (a != b) out.add(ConflictFieldDiff(f.key, a, b));
  }
  return out;
}

String? _norm(Object? v, ConflictFieldKind kind) {
  if (v == null) return null;
  switch (kind) {
    case ConflictFieldKind.text:
      final t = v.toString().trim();
      return t.isEmpty ? null : t;
    case ConflictFieldKind.amount:
      final n = v is num ? v : num.tryParse(v.toString());
      if (n == null) return v.toString();
      final fixed = n.toStringAsFixed(6);
      return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
    case ConflictFieldKind.date:
      final d = DateTime.tryParse(v.toString());
      if (d == null) return v.toString();
      // Every writer stores UTC (`dateTimeToSql`, `Z` suffix), so a zone-less
      // value means UTC, not device-local time. Explicit offsets are kept.
      final u = d.isUtc
          ? d
          : DateTime.utc(d.year, d.month, d.day, d.hour, d.minute, d.second,
              d.millisecond, d.microsecond);
      String two(int x) => x.toString().padLeft(2, '0');
      return '${u.year}-${two(u.month)}-${two(u.day)}'
          '${u.hour == 0 && u.minute == 0 && u.second == 0 ? '' : ' ${two(u.hour)}:${two(u.minute)}'}';
    case ConflictFieldKind.flag:
      return (v == true || v == 1 || v == '1' || v == 'true') ? '1' : '0';
  }
}
