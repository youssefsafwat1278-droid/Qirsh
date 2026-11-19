// In-memory `user_merchant_rules` for one user, for the rule restore and
// precedence tests: one row per merchant key, a server-owned `updated_at`,
// tombstones instead of deletes. Its clock starts in 2027, AHEAD of the test
// device's clock, so every test also runs with the server ahead of the device.
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';

class FakeRuleCloud implements MerchantRuleRemote {
  final rows = <String, Map<String, dynamic>>{};
  final pushedKeys = <String>[];

  /// The next N fetches throw (a dropped connection during the pull).
  int failFetches = 0;

  /// Fetch number N (1-based, counted from now on) throws: e.g. 2 fails the
  /// second page of a pull.
  int? failFetchNumber;
  var _fetches = 0;
  var _clock = 0;

  String _tick() => DateTime.utc(2027, 1, 1)
      .add(Duration(seconds: ++_clock))
      .toIso8601String();

  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) async {
    final key = row['merchant_key'] as String;
    pushedKeys.add(key);
    rows[key] = {
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': row['category_key'],
      'deleted_at': row['deleted_at'],
      'updated_at': _tick(),
    };
    return [Map.of(rows[key]!)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) async {
    if (failFetchNumber != null && ++_fetches == failFetchNumber) {
      failFetchNumber = null;
      _fetches = 0;
      throw StateError('synthetic network failure on a later page');
    }
    if (failFetches > 0) {
      failFetches--;
      throw StateError('synthetic network failure');
    }
    final sorted = rows.values.toList()
      ..sort((a, b) {
        final c = normalizeCursorTimestamp(a['updated_at'])
            .compareTo(normalizeCursorTimestamp(b['updated_at']));
        return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
      });
    return sorted
        .where((r) {
          if (after.id.isEmpty) return true;
          final c = normalizeCursorTimestamp(r['updated_at'])
              .compareTo(after.updatedAt);
          return c > 0 ||
              (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  /// A write made by another device of the same user: a rule, or with
  /// [removed] its removal. [at] is the server time of that write (default:
  /// the next tick of this cloud's clock).
  void otherDevice(String key, String category,
      {bool removed = false, String? at}) {
    final time = at ?? _tick();
    rows[key] = {
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': category,
      'deleted_at': removed ? time : null,
      'updated_at': time,
    };
  }

  /// Live rules: merchant key -> category key.
  Map<String, Object?> live() => {
        for (final r in rows.values)
          if (r['deleted_at'] == null)
            r['merchant_key'] as String: r['category_key'],
      };
}
