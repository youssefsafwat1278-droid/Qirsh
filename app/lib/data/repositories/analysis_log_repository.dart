import 'package:drift/drift.dart';

import '../../domain/capture/analysis_outcome.dart';
import '../../domain/capture/analysis_reason.dart';
import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/entities/transaction_entity.dart';
import '../db/app_database.dart';
import 'drift_repository_support.dart' show transactionFromRow;
import 'drift_smart_inbox_repository.dart';

/// One captured bank message in the analysis log (Gemini-first phase 2).
class AnalysisLogEntry {
  const AnalysisLogEntry({
    required this.payloadId,
    required this.at,
    required this.state,
    this.reasonCode,
    this.unanalysed = false,
    this.transaction,
    this.inboxItem,
    this.text,
  });

  final String payloadId;
  final DateTime at;
  final AnalysisOutcomeState state;
  final String? reasonCode;

  /// Its analysis never ran (24-hour rule): the user is asked to record it.
  final bool unanalysed;

  /// The recorded transaction (saved / awaiting confirmation).
  final TransactionEntity? transaction;

  /// The Smart Inbox item that holds it (not added / needs confirmation).
  final SmartInboxItemEntity? inboxItem;

  /// The message as the device holds it (raw), when it keeps one. The log
  /// shows it masked only.
  final String? text;
}

/// The analysis log, built from what the device already keeps: each capture's
/// receipt (`dedup_hashes` `capture_payload:<id>`, written with its result),
/// the transaction or Smart Inbox row it points at, and the captures still
/// queued natively ("awaiting analysis", passed in by the caller). No schema
/// change and nothing new stored except a content-free `ignored` receipt.
class AnalysisLogRepository {
  const AnalysisLogRepository(this._db);

  final AppDatabase _db;

  static const _receiptPrefix = 'capture_payload:';
  static const int limit = 300;

  Future<List<AnalysisLogEntry>> recent() async {
    final receipts = await _db.customSelect(
      'SELECT substr(hash, ${_receiptPrefix.length + 1}) AS payload_id, '
      'transaction_id AS target, saved_at FROM dedup_hashes '
      'WHERE hash LIKE ? ORDER BY saved_at DESC LIMIT ?;',
      variables: [
        Variable.withString('$_receiptPrefix%'),
        Variable.withInt(limit),
      ],
    ).get();
    if (receipts.isEmpty) return const [];
    final targets = {for (final r in receipts) r.read<String>('target')};
    final payloadIds = [for (final r in receipts) r.read<String>('payload_id')];
    final transactions = <String, TransactionEntity>{
      for (final row in await _byIds('transactions', 'id', targets))
        row.read<String>('id'): transactionFromRow(row),
    };
    final inbox = <String, SmartInboxItemEntity>{
      for (final item in await DriftSmartInboxRepository(_db)
          .captureItems(payloadIds))
        if (item.payloadId != null) item.payloadId!: item,
    };
    final entries = <AnalysisLogEntry>[];
    for (final r in receipts) {
      final payloadId = r.read<String>('payload_id');
      final target = r.read<String>('target');
      final savedAt =
          DateTime.tryParse(r.read<String>('saved_at'))?.toUtc() ??
              DateTime.now().toUtc();
      final tx = transactions[target];
      final item = inbox[payloadId];
      if (tx != null) {
        // Another transaction than its own: kept as a duplicate of it.
        final duplicate = tx.id != payloadId;
        entries.add(AnalysisLogEntry(
          payloadId: payloadId,
          at: duplicate ? savedAt : tx.occurredAt.toUtc(),
          state: duplicate
              ? AnalysisOutcomeState.notAdded
              : tx.status == TransactionStatus.pending
                  ? AnalysisOutcomeState.needsConfirmation
                  : AnalysisOutcomeState.saved,
          reasonCode: duplicate ? AnalysisReason.duplicate : null,
          transaction: tx,
          text: tx.rawMessage.isEmpty ? null : tx.rawMessage,
        ));
      } else if (item != null) {
        entries.add(AnalysisLogEntry(
          payloadId: payloadId,
          at: item.createdAt.toUtc(),
          state: AnalysisOutcome.forInboxItem(item),
          reasonCode: AnalysisOutcome.unanalysed(item)
              ? null
              : AnalysisReason.of(
                  reasonCode: item.reasonCode, reviewReason: item.reviewReason),
          unanalysed: AnalysisOutcome.unanalysed(item),
          inboxItem: item,
          text: item.body,
        ));
      } else if (target == 'ignored') {
        // Dropped by the device's OTP/advert filter: no text was kept.
        entries.add(AnalysisLogEntry(
          payloadId: payloadId,
          at: savedAt,
          state: AnalysisOutcomeState.notAdded,
          reasonCode: AnalysisReason.notFinancial,
        ));
      }
      // A transaction the user deleted since: nothing left to show.
    }
    return entries;
  }

  Future<List<QueryRow>> _byIds(
      String table, String column, Iterable<String> ids) async {
    final list = ids.toList();
    final rows = <QueryRow>[];
    for (var i = 0; i < list.length; i += 200) {
      final chunk = list.sublist(i, i + 200 > list.length ? list.length : i + 200);
      rows.addAll(await _db.customSelect(
        'SELECT * FROM $table WHERE $column IN '
        '(${List.filled(chunk.length, '?').join(', ')});',
        variables: [for (final id in chunk) Variable.withString(id)],
      ).get());
    }
    return rows;
  }
}
