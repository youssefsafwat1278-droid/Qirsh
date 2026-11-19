import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;

import '../../data/db/app_database.dart';
import '../../core/utils/id_generator.dart';
import 'data_portability_models.dart';
import 'portable_csv.dart';
import 'qirsh_package_codec.dart';

class DriftFinancialExporter {
  DriftFinancialExporter(this._db, {int? maxPackageBytes})
      : _maxPackageBytes = maxPackageBytes ?? maxExportPackageBytes;

  final AppDatabase _db;
  // MALI-030 — the enforced total-export cap; overridable in tests.
  final int _maxPackageBytes;

  // MALI-030 — transactions are exported in bounded keyset pages so at most this
  // many transaction rows are ever held in memory at once (the accumulated output
  // text is the export's own byte contract, not retained domain objects).
  static const int _exportPageSize = 1000;

  Future<ExportedFile> exportTransactionsCsv() async {
    const columns = '''
        t.id AS record_id, t.occurred_at, t.amount, t.currency,
        COALESCE(t.direction, 'unknown') AS direction, t.type, t.source, t.status,
        t.raw_merchant AS merchant, c.key AS category_key, c.name_ar AS category,
        a.name AS account, t.card_last4, t.balance_after, t.foreign_amount,
        t.foreign_currency, t.note''';
    const fromJoin = '''
      FROM transactions t
      LEFT JOIN accounts a ON a.id = t.account_id
      LEFT JOIN categories c ON c.id = t.category_id''';

    // Keyset page (occurred_at ASC, id ASC): only [_exportPageSize] rows are held
    // per read; each page is CSV-encoded and appended, then released. The growing
    // output text is the CSV file itself (the export's byte contract).
    final buffer = StringBuffer();
    var recordCount = 0;
    var firstChunk = true;
    String? cursorOccurredAt;
    String? cursorId;
    while (true) {
      final keyset = cursorOccurredAt == null
          ? ''
          : ' AND (t.occurred_at > ? OR (t.occurred_at = ? AND t.id > ?))';
      final rows = await _db.customSelect(
        'SELECT $columns $fromJoin '
        "WHERE t.status != 'ignored'$keyset "
        'ORDER BY t.occurred_at ASC, t.id ASC LIMIT ?;',
        variables: [
          if (cursorOccurredAt != null) ...[
            Variable.withString(cursorOccurredAt),
            Variable.withString(cursorOccurredAt),
            Variable.withString(cursorId!),
          ],
          Variable.withInt(_exportPageSize),
        ],
      ).get();
      if (rows.isEmpty) break;
      final headers = rows.first.data.keys.toList(growable: false);
      final chunk = encodePortableCsvChunk(
        headers: headers,
        rows: rows.map((r) => [for (final h in headers) r.data[h]]),
        includeHeader: firstChunk,
      );
      if (!firstChunk) buffer.write('\r\n');
      buffer.write(chunk);
      firstChunk = false;
      recordCount += rows.length;
      cursorOccurredAt = rows.last.data['occurred_at'] as String?;
      cursorId = rows.last.data['record_id'] as String?;
      if (rows.length < _exportPageSize) break;
    }
    if (recordCount == 0) {
      buffer.write(encodePortableCsvChunk(
        headers: _transactionExportHeaders,
        rows: const [],
        includeHeader: true,
      ));
    }
    final bytes = Uint8List.fromList(utf8.encode(buffer.toString()));
    return ExportedFile(
      name: 'qirsh-transactions-${_dateStamp()}.csv',
      mimeType: 'text/csv',
      bytes: bytes,
      recordCount: recordCount,
    );
  }

  Future<ExportedFile> exportFinancialPackage() async {
    final csvFiles = <String, Uint8List>{};
    final rowCounts = <String, int>{};
    var recordCount = 0;
    var totalBytes = 0;
    for (final spec in _tableSpecs) {
      // The transactions table is the only one that scales with usage — page it
      // (bounded row retention). Other tables are small bounded catalogs/config.
      // The remaining export budget is passed down so the paged big table aborts
      // MID-BUILD rather than after materializing an over-cap CSV.
      final (bytes, count) = spec.name == 'transactions'
          ? await _pagedSpecCsv(spec,
              budgetBytes: _maxPackageBytes - totalBytes)
          : await _singleSpecCsv(spec);
      totalBytes += bytes.length;
      if (totalBytes > _maxPackageBytes) {
        // Typed, privacy-safe resource limit — no financial content in the message,
        // no partial file returned (the caller only writes a file on success).
        throw const DataPortabilityException(
          'حجم التصدير تجاوز الحد المسموح (100MB).', code: DataPortabilityError.exportTooLarge,
        );
      }
      csvFiles['${spec.name}.csv'] = bytes;
      rowCounts[spec.name] = count;
      recordCount += count;
    }
    final now = DateTime.now().toUtc();
    final bytes = encodeQirshPackage(
      packageId: IdGenerator.next(),
      exportedAt: now,
      csvFiles: csvFiles,
      rowCounts: rowCounts, // avoids re-decoding every CSV to count rows
    );
    return ExportedFile(
      name: 'qirsh-data-${_dateStamp(now)}.zip',
      mimeType: 'application/zip',
      bytes: bytes,
      recordCount: recordCount,
    );
  }

  Future<(Uint8List, int)> _singleSpecCsv(_ExportTableSpec spec) async {
    final rows = await _db.customSelect(spec.sql).get();
    final headers = rows.isEmpty
        ? spec.headers
        : rows.first.data.keys.toList(growable: false);
    return (_encodeRows(headers, rows.map((row) => row.data)), rows.length);
  }

  /// MALI-030 — pages a spec whose query ends `ORDER BY t.occurred_at, t.id`
  /// (the transactions dump) via keyset, so at most [_exportPageSize] rows are
  /// held per read. Bytes accumulate in a BytesBuilder and are checked against
  /// [budgetBytes] AS they grow — an over-cap dataset aborts mid-build with a
  /// typed [DataPortabilityException] before an unbounded buffer forms.
  Future<(Uint8List, int)> _pagedSpecCsv(
    _ExportTableSpec spec, {
    required int budgetBytes,
  }) async {
    final out = BytesBuilder(copy: false);
    var byteSize = 0;
    var count = 0;
    var firstChunk = true;
    String? cursorOccurredAt;
    String? cursorId;
    void append(String fragment) {
      final bytes = utf8.encode(fragment);
      byteSize += bytes.length;
      if (byteSize > budgetBytes) {
        throw const DataPortabilityException(
          'حجم التصدير تجاوز الحد المسموح (100MB).', code: DataPortabilityError.exportTooLarge,
        );
      }
      out.add(bytes);
    }

    while (true) {
      final keyset = cursorOccurredAt == null
          ? ''
          : ' AND (t.occurred_at > ? OR (t.occurred_at = ? AND t.id > ?))';
      final sql = spec.sql.replaceFirst(
        'ORDER BY t.occurred_at, t.id',
        '$keyset ORDER BY t.occurred_at, t.id LIMIT ?',
      );
      final rows = await _db.customSelect(
        sql,
        variables: [
          if (cursorOccurredAt != null) ...[
            Variable.withString(cursorOccurredAt),
            Variable.withString(cursorOccurredAt),
            Variable.withString(cursorId!),
          ],
          Variable.withInt(_exportPageSize),
        ],
      ).get();
      if (rows.isEmpty) break;
      final chunk = encodePortableCsvChunk(
        headers: spec.headers,
        rows: rows.map((r) => [for (final h in spec.headers) r.data[h]]),
        includeHeader: firstChunk,
      );
      if (!firstChunk) append('\r\n');
      append(chunk);
      firstChunk = false;
      count += rows.length;
      cursorOccurredAt = rows.last.data['occurred_at'] as String?;
      cursorId = rows.last.data['record_id'] as String?;
      if (rows.length < _exportPageSize) break;
    }
    if (count == 0) {
      append(encodePortableCsvChunk(
        headers: spec.headers,
        rows: const [],
        includeHeader: true,
      ));
    }
    return (out.toBytes(), count);
  }

  Uint8List _encodeRows(
    List<String> headers,
    Iterable<Map<String, Object?>> rows,
  ) {
    return encodePortableCsv(
      headers,
      rows.map((row) => [for (final header in headers) row[header]]),
    );
  }

  String _dateStamp([DateTime? value]) {
    final date = (value ?? DateTime.now()).toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${date.year}-${two(date.month)}-${two(date.day)}';
  }
}

const _transactionExportHeaders = [
  'record_id',
  'occurred_at',
  'amount',
  'currency',
  'direction',
  'type',
  'source',
  'status',
  'merchant',
  'category_key',
  'category',
  'account',
  'card_last4',
  'balance_after',
  'foreign_amount',
  'foreign_currency',
  'note',
];

class _ExportTableSpec {
  const _ExportTableSpec(this.name, this.headers, this.sql);

  final String name;
  final List<String> headers;
  final String sql;
}

const _tableSpecs = <_ExportTableSpec>[
  _ExportTableSpec('accounts', [
    'record_id',
    'name',
    'currency',
    'type',
    'initial_balance',
    'initial_balance_minor',
    'current_balance',
    'current_balance_minor',
    'credit_limit',
    'credit_limit_minor',
    'available_credit',
    'available_credit_minor',
    'is_default',
    'sort_order',
    'created_at',
    'updated_at',
  ], '''
    SELECT id AS record_id, name, currency, type,
           initial_balance, initial_balance_minor,
           current_balance, current_balance_minor,
           credit_limit, credit_limit_minor,
           available_credit, available_credit_minor,
           is_default, sort_order, created_at, updated_at
    FROM accounts WHERE deleted_at IS NULL ORDER BY sort_order, id;
  '''),
  _ExportTableSpec('custom_categories', [
    'record_id',
    'key',
    'name_ar',
    'icon',
    'color',
    'is_income',
    'sort_order',
  ], '''
    SELECT id AS record_id, key, name_ar, icon, color, is_income, sort_order
    FROM categories
    WHERE key GLOB 'custom_*' AND deleted_at IS NULL
    ORDER BY sort_order, id;
  '''),
  _ExportTableSpec('transactions', [
    'record_id',
    'account_record_id',
    'amount',
    'amount_minor',
    'currency',
    'merchant',
    'category_record_id',
    'category_key',
    'type',
    'source',
    'card_last4',
    'balance_after',
    'balance_after_minor',
    'note',
    'occurred_at',
    'status',
    'created_at',
    'updated_at',
    'foreign_amount',
    'foreign_amount_minor',
    'foreign_currency',
    'direction',
    'transaction_time_from_sms',
    'sms_received_at',
    'comparison_timestamp',
    'comparison_timestamp_source',
    'duplicate_status',
    'possible_duplicate_record_id',
    'duplicate_reason',
    'transfer_group_id',
  ], '''
    SELECT t.id AS record_id, t.account_id AS account_record_id,
           t.amount, t.amount_minor, t.currency, t.raw_merchant AS merchant,
           t.category_id AS category_record_id, c.key AS category_key,
           t.type, t.source, t.card_last4,
           t.balance_after, t.balance_after_minor, t.note,
           t.occurred_at, t.status, t.created_at, t.updated_at,
           t.foreign_amount, t.foreign_amount_minor, t.foreign_currency, t.direction,
           t.transaction_time_from_sms, t.sms_received_at,
           t.comparison_timestamp, t.comparison_timestamp_source,
           t.duplicate_status,
           t.possible_duplicate_of_transaction_id AS possible_duplicate_record_id,
           t.duplicate_reason, t.transfer_group_id
    FROM transactions t
    LEFT JOIN categories c ON c.id = t.category_id
    WHERE t.status != 'ignored'
    ORDER BY t.occurred_at, t.id;
  '''),
  // Audit C-2: `currency` MUST be exported. Without it the importer had no
  // authority for these base-currency rows and could not reconstruct canonical
  // money, so imported budgets landed with NULL `_minor` columns.
  _ExportTableSpec('budgets', [
    'record_id',
    'account_record_id',
    'category_record_id',
    'category_key',
    'currency',
    'amount',
    'amount_minor',
    'period',
    'start_date',
    'is_active',
    'last_notified_spent_amount',
    'last_notified_spent_amount_minor',
    'last_notified_period_start',
    'show_on_header',
    'alert_threshold_percent',
  ], '''
    SELECT b.id AS record_id, b.account_id AS account_record_id,
           b.category_id AS category_record_id, c.key AS category_key,
           b.currency, b.amount, b.amount_minor, b.period, b.start_date, b.is_active,
           b.last_notified_spent_amount, b.last_notified_spent_amount_minor,
           b.last_notified_period_start, b.show_on_header,
           b.alert_threshold_percent
    FROM budgets b LEFT JOIN categories c ON c.id = b.category_id
    WHERE b.deleted_at IS NULL ORDER BY b.id;
  '''),
  _ExportTableSpec('subscriptions', [
    'record_id',
    'account_record_id',
    'merchant',
    'name',
    'amount',
    'amount_minor',
    'currency',
    'period',
    'frequency',
    'type',
    'next_due_date',
    'is_confirmed',
    'reminder_on',
    'custom_interval_days',
    'note',
    'created_at',
    'status',
    'total_installments',
    'paid_count',
    'manual_paid_amount',
    'manual_paid_amount_minor',
    'total_purchase_amount',
    'total_purchase_amount_minor',
    'lender_name',
    'interest_rate',
  ], '''
    SELECT s.id AS record_id, s.account_id AS account_record_id,
           m.raw_name AS merchant, s.name, s.amount, s.amount_minor,
           s.currency, s.period,
           s.frequency, s.type, s.next_due_date, s.is_confirmed,
           s.reminder_on, s.custom_interval_days, s.note, s.created_at,
           s.status, s.total_installments, s.paid_count,
           s.manual_paid_amount, s.manual_paid_amount_minor,
           s.total_purchase_amount, s.total_purchase_amount_minor, s.lender_name,
           s.interest_rate
    FROM subscriptions s LEFT JOIN merchants m ON m.id = s.merchant_id
    WHERE s.deleted_at IS NULL ORDER BY s.id;
  '''),
  _ExportTableSpec('bill_payments', [
    'record_id',
    'subscription_record_id',
    'amount',
    'amount_minor',
    'currency',
    'period_start',
    'period_end',
    'paid_at',
    'installment_index',
    'transaction_record_id',
    'note',
  ], '''
    SELECT id AS record_id, bill_id AS subscription_record_id,
           amount, amount_minor, currency, period_start, period_end,
           paid_at, installment_index,
           transaction_id AS transaction_record_id, note
    FROM bill_payments WHERE deleted_at IS NULL ORDER BY paid_at, id;
  '''),
  // Audit C-2 — see `budgets`: the currency authority must travel with the row.
  _ExportTableSpec('goals', [
    'record_id',
    'account_record_id',
    'name',
    'currency',
    'target_amount',
    'target_amount_minor',
    'saved_amount',
    'saved_amount_minor',
    'deadline',
    'vault_skin',
    'status',
    'created_at',
    'auto_save_amount',
    'auto_save_amount_minor',
    'auto_save_period',
    'auto_save_last_run',
    'last_notified_saved_amount',
    'last_notified_saved_amount_minor',
  ], '''
    SELECT id AS record_id, account_id AS account_record_id, name,
           currency, target_amount, target_amount_minor,
           saved_amount, saved_amount_minor, deadline, vault_skin, status,
           created_at, auto_save_amount, auto_save_amount_minor,
           auto_save_period, auto_save_last_run,
           last_notified_saved_amount, last_notified_saved_amount_minor
    FROM goals WHERE deleted_at IS NULL ORDER BY id;
  '''),
  _ExportTableSpec('goal_contributions', [
    'record_id',
    'goal_record_id',
    'currency',
    'amount',
    'amount_minor',
    'created_at',
    'note',
  ], '''
    SELECT gc.id AS record_id, gc.goal_id AS goal_record_id,
           g.currency, gc.amount, gc.amount_minor, gc.created_at, gc.note
    FROM goal_contributions gc
    JOIN goals g ON g.id = gc.goal_id
    WHERE gc.deleted_at IS NULL ORDER BY gc.created_at, gc.id;
  '''),
  _ExportTableSpec('plans', [
    'record_id',
    'name',
    'budget_amount',
    'budget_amount_minor',
    'currency',
    'start_date',
    'end_date',
    'account_record_ids',
    'card_last4s',
    'status',
    'icon',
    'created_at',
  ], '''
    SELECT id AS record_id, name, budget_amount, budget_amount_minor,
           currency, start_date,
           end_date, account_ids AS account_record_ids, card_last4s,
           status, icon, created_at
    FROM plans WHERE deleted_at IS NULL ORDER BY id;
  '''),
  _ExportTableSpec('plan_transaction_links', [
    'plan_record_id',
    'transaction_record_id',
    'created_at',
  ], '''
    SELECT plan_id AS plan_record_id, transaction_id AS transaction_record_id,
           created_at
    FROM plan_transaction_links WHERE deleted_at IS NULL
    ORDER BY plan_id, transaction_id;
  '''),
];
