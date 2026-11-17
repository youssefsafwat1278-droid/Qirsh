// V1-020 — an in-memory `user_transactions` table behind the real PostgREST
// client (HTTP boundary) for restore-then-sync tests without a live stack.
//
// It models just what the legacy (non-CAS) ledger push, the transactions
// backfill and the legacy ledger pull send: GET with `eq`/`is` filters, POST
// insert/upsert on (user_id, client_request_id), guarded PATCH. Every write
// moves `updated_at` forward, so `(updated_at, id)` keyset pulls behave like
// the server's. Synthetic data only.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/capture/services/ledger_sync_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class FakeLedgerCloud implements LedgerRemoteSource {
  final List<Map<String, dynamic>> rows = [];
  int _clock = 0;
  int _ids = 0;

  String _tick() => DateTime.utc(2026, 9, 1)
      .add(Duration(seconds: ++_clock))
      .toIso8601String();

  /// Live (not tombstoned, not ignored) rows: merchant -> amounts (a list, so
  /// a duplicate cloud copy is visible).
  Map<String, List<String>> live() {
    final out = <String, List<String>>{};
    for (final r in rows) {
      if (r['deleted_at'] != null || r['status'] == 'ignored') continue;
      out.putIfAbsent(r['merchant'] as String, () => []).add(r['amount_text'] as String);
    }
    for (final v in out.values) {
      v.sort();
    }
    return out;
  }

  SupabaseClient client() => SupabaseClient(
        'https://fake.supabase.test',
        'anon',
        accessToken: () async => 'token',
        httpClient: MockClient(_handle),
      );

  static String _amountText(Object? v) =>
      v == null ? '' : num.parse('$v').toStringAsFixed(2);

  Map<String, dynamic> _stored(Map<String, dynamic> body) {
    final r = Map<String, dynamic>.from(body);
    r['amount_text'] = _amountText(body['amount']);
    r['balance_after_text'] =
        body['balance_after'] == null ? null : _amountText(body['balance_after']);
    r['foreign_amount_text'] = body['foreign_amount'] == null
        ? null
        : _amountText(body['foreign_amount']);
    return r;
  }

  bool _matches(Map<String, dynamic> r, Map<String, String> q) {
    for (final e in q.entries) {
      if (const {'select', 'on_conflict', 'limit', 'order', 'or'}
          .contains(e.key)) {
        continue;
      }
      final v = e.value;
      if (v == 'is.null') {
        if (r[e.key] != null) return false;
      } else if (v.startsWith('eq.')) {
        final want = v.substring(3);
        final have = r[e.key];
        if (e.key == 'updated_at') {
          if (canonicalServerTimestamp(have as String?) !=
              canonicalServerTimestamp(want)) {
            return false;
          }
        } else if ('$have' != want) {
          return false;
        }
      } else {
        throw UnsupportedError('filter ${e.key}=$v');
      }
    }
    return true;
  }

  Future<http.Response> _handle(http.Request req) async {
    if (!req.url.path.endsWith('/user_transactions')) {
      return http.Response('not found', 404, request: req);
    }
    final q = req.url.queryParameters;
    final wantsObject =
        (req.headers['Accept'] ?? req.headers['accept'] ?? '')
            .contains('vnd.pgrst.object');
    List<Map<String, dynamic>> result;
    switch (req.method) {
      case 'GET':
        result = rows.where((r) => _matches(r, q)).toList();
      case 'POST':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        final existing = q['on_conflict'] == null
            ? null
            : rows
                .where((r) =>
                    r['user_id'] == body['user_id'] &&
                    r['client_request_id'] == body['client_request_id'])
                .firstOrNull;
        if (existing != null) {
          existing.addAll(_stored(body));
          existing['updated_at'] = _tick();
          result = [existing];
        } else {
          final r = _stored(body)
            ..['id'] = 'srv-${++_ids}'
            ..putIfAbsent('deleted_at', () => null)
            ..['updated_at'] = _tick();
          rows.add(r);
          result = [r];
        }
      case 'PATCH':
        final body = jsonDecode(req.body) as Map<String, dynamic>;
        result = rows.where((r) => _matches(r, q)).toList();
        for (final r in result) {
          r.addAll(body.containsKey('amount') ? _stored(body) : body);
          r['updated_at'] = _tick();
        }
      default:
        return http.Response('unsupported', 405, request: req);
    }
    if (wantsObject) {
      if (result.length != 1) {
        return http.Response(
            jsonEncode({'code': 'PGRST116', 'message': 'not one row'}), 406,
            headers: const {'content-type': 'application/json'},
            request: req);
      }
      return http.Response(jsonEncode(result.single), 200,
          headers: const {'content-type': 'application/json'}, request: req);
    }
    return http.Response(jsonEncode(result), 200,
        headers: const {'content-type': 'application/json'}, request: req);
  }

  /// The pull seam: the same rows, in `(updated_at, id)` keyset order.
  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    final sorted = [...rows]..sort((a, b) {
        final c = (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
      });
    bool isAfter(Map<String, dynamic> r) {
      if (after.id.isEmpty) return true;
      final u = canonicalServerTimestamp(r['updated_at'] as String)!;
      final c = u.compareTo(after.updatedAt);
      return c > 0 || (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
    }

    return [
      for (final r in sorted.where(isAfter).take(limit))
        Map<String, dynamic>.from(r),
    ];
  }
}
