import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/entities/smart_inbox_item_entity.dart';
import '../../domain/repositories/smart_inbox_repository.dart';
import '../db/app_database.dart';
import '../db/sql_value_codec.dart';

class DriftSmartInboxRepository implements SmartInboxRepository {
  const DriftSmartInboxRepository(this._db);
  final AppDatabase _db;

  /// Supported inbox writers share this persisted, strictly increasing token.
  /// Preserve the original stored spelling when comparing an in-flight edit.
  static DateTime parseEditStamp(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$').hasMatch(value)) {
      throw const FormatException('invalid_inbox_edit_stamp');
    }
    final parsed = DateTime.tryParse(value);
    final fraction = value.contains('.')
        ? value.substring(value.indexOf('.') + 1, value.length - 1) : '';
    final expected = '${value.substring(0, 19)}.${fraction.padRight(6, '0')}Z';
    if (parsed == null || parsed.year < 1 || parsed.year > 9999 ||
        _canonicalStamp(parsed) != expected) {
      throw const FormatException('invalid_inbox_edit_stamp');
    }
    return parsed;
  }

  static String _canonicalStamp(DateTime value) {
    final utc = value.toUtc();
    if (utc.year < 1 || utc.year > 9999) {
      throw const FormatException('invalid_inbox_edit_stamp');
    }
    final iso = utc.toIso8601String();
    return '${iso.substring(0, 19)}.${(utc.millisecond * 1000 + utc.microsecond).toString().padLeft(6, '0')}Z';
  }

  static String nextEditStamp(String? previous, {DateTime? now}) {
    var next = (now ?? DateTime.now()).toUtc();
    _canonicalStamp(next);
    if (previous != null) {
      final old = parseEditStamp(previous);
      final incremented = old.add(const Duration(microseconds: 1));
      _canonicalStamp(incremented);
      if (!next.isAfter(old)) next = incremented;
    }
    return _canonicalStamp(next);
  }

  /// Persists a native capture that looked financial but could not be parsed.
  ///
  /// The payload id is the durable business key: a crash/re-delivery executes
  /// the same INSERT OR IGNORE and therefore keeps one review card. This is a
  /// local Smart Inbox item (there is no server-authored row to push), while the
  /// raw SMS remains available in [body] for manual recovery.
  /// [lang] is the reader's language at the moment the message arrived.
  ///
  /// `smart_inbox_items.title` normally holds SERVER-authored text, so a
  /// code-and-render-at-the-UI scheme does not generalize to this column. This
  /// one title is generated locally, so it is written in the language the user
  /// is reading in — the same contract the capture notifications use. A later
  /// language switch leaves existing rows as they were, which is deliberate:
  /// the row records what the user was actually shown.
  Future<String> saveUnprocessableCapture({
    required String payloadId,
    required String rawMessage,
    required String source,
    String? senderId,
    DateTime? receivedAt,
    String lang = 'ar',
    bool awaitingAnalysis = false,
    String? reviewReason,
  }) async {
    final itemId = 'local_capture:$payloadId';
    final now = DateTime.now().toUtc();
    final effectiveReceivedAt = (receivedAt ?? now).toUtc();
    await _db.customInsert(
      '''
        INSERT OR IGNORE INTO smart_inbox_items(
          id, server_id, transaction_id, payload_id,
          type, title, body, status, confidence, metadata_json,
          server_created_at, server_updated_at, synced_at,
          dismissed_locally, pending_sync, created_at, updated_at
        ) VALUES (?, ?, NULL, ?, 'needs_review', ?, ?, 'open', NULL, ?,
                  ?, NULL, ?, 0, 0, ?, ?);
      ''',
      variables: [
        Variable.withString(itemId),
        Variable.withString(itemId),
        Variable.withString(payloadId),
        Variable.withString(awaitingAnalysis ||
                reviewReason == SmartInboxReviewReason.analysisUnavailable
            ? (lang == 'en' ? 'Bank message awaiting analysis'
                : 'رسالة بنكية بانتظار التحليل')
            : (lang == 'en' ? 'An unsupported bank message that needs review'
                : 'رسالة بنكية غير مدعومة تحتاج مراجعة')),
        Variable.withString(rawMessage),
        Variable.withString(jsonEncode({
          'capture_disposition': 'unprocessable',
          'source': source,
          if (senderId != null && senderId.isNotEmpty) 'sender_id': senderId,
          'received_at': effectiveReceivedAt.toIso8601String(),
          'local_only': true,
          if (awaitingAnalysis) 'manual_analysis_draft': true,
          if (reviewReason != null) 'review_reason': reviewReason,
        })),
        Variable.withString(dateTimeToSql(effectiveReceivedAt)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(dateTimeToSql(now)),
        Variable.withString(nextEditStamp(null, now: now)),
      ],
    );
    return itemId;
  }

  Future<void> removeManualAnalysisDraft(String id) async {
    await _db.customUpdate(
      "DELETE FROM smart_inbox_items WHERE id = ? AND server_id = id "
      "AND json_extract(metadata_json, '\$.source') = 'manualPaste' "
      "AND json_extract(metadata_json, '\$.manual_analysis_draft') = 1;",
      variables: [Variable.withString(id)],
    );
  }

  /// Bare legacy `rejected:<payloadId>` dedup markers are not durable capture
  /// results on their own. This lets the native drain require the deterministic
  /// review row before treating such a marker as safe acknowledgement proof.
  Future<bool> hasUnprocessableCapture(String payloadId) async {
    final itemId = 'local_capture:$payloadId';
    final row = await _db.customSelect(
      '''
        SELECT 1 FROM smart_inbox_items
        WHERE id = ? AND payload_id = ?
        LIMIT 1;
      ''',
      variables: [
        Variable.withString(itemId),
        Variable.withString(payloadId),
      ],
    ).getSingleOrNull();
    return row != null;
  }

  @override
  Future<List<SmartInboxItemEntity>> getOpen() async {
    final rows = await _db
        .customSelect(
          "SELECT * FROM smart_inbox_items WHERE status = 'open' "
          'AND dismissed_locally = 0 ORDER BY server_created_at DESC;',
        )
        .get();
    return rows.map(_fromRow).toList(growable: false);
  }

  @override
  Future<void> dismiss(String id) => _setStatus(id, 'dismissed', true);

  @override
  Future<void> resolve(String id) => _setStatus(id, 'resolved', false);

  Future<void> _setStatus(String id, String status, bool dismissed) async {
    // pending_sync = 1: تغيير محلي (offline-first) ينتظر الدفع للخادم. العناصر
    // المحلية فقط (`local_capture:`) ليس لها صف على الخادم فلا شيء ينتظر الدفع
    // (G11) — وإلا بقيت pending_sync=1 للأبد.
    await _db.transaction(() async {
      final rows = await _db.customSelect(
        'SELECT id, updated_at FROM smart_inbox_items WHERE id = ? OR server_id = ?;',
        variables: [Variable.withString(id), Variable.withString(id)],
      ).get();
      for (final row in rows) {
        final stamp = nextEditStamp(row.read<String>('updated_at'));
        await _db.customUpdate(
          'UPDATE smart_inbox_items SET status = ?, dismissed_locally = ?, '
          "pending_sync = CASE WHEN server_id LIKE 'local_capture:%' THEN 0 ELSE 1 END, "
          'push_attempt_count = 0, push_next_retry_at = NULL, updated_at = ? WHERE id = ?;',
          variables: [Variable.withString(status), Variable.withInt(boolToSql(dismissed)),
            Variable.withString(stamp), Variable.withString(row.read<String>('id'))],
        );
      }
    });
  }

  SmartInboxItemEntity _fromRow(QueryRow row) => SmartInboxItemEntity(
        id: row.read<String>('server_id'),
        transactionId: row.readNullable<String>('transaction_id'),
        payloadId: row.readNullable<String>('payload_id'),
        type: row.read<String>('type'),
        title: row.read<String>('title'),
        body: row.readNullable<String>('body'),
        status: row.read<String>('status'),
        confidence: row.readNullable<double>('confidence'),
        createdAt: dateTimeFromSql(row.read<String>('server_created_at')),
      );
}
