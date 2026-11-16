import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/repositories/drift_category_repository.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/domain/repositories/merchant_category_repository.dart';
import 'package:money_companion/domain/services/learned_rule_precedence.dart';
import 'package:money_companion/domain/usecases/learned_rules_usecase.dart';
import 'package:money_companion/engine/categorization/categorizer.dart';
import 'package:money_companion/engine/categorization/merchant_category_map.dart';
import 'package:money_companion/engine/models/parsed_transaction.dart';
import 'package:money_companion/engine/models/transaction_source.dart';
import 'package:money_companion/engine/models/transaction_type.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../capture/ledger_admission_fixture.dart';

/// In-memory `user_merchant_rules` for ONE user: unique per merchant_key,
/// server-owned updated_at, tombstones instead of deletes.
class _FakeRuleRemote implements MerchantRuleRemote {
  final rows = <String, Map<String, dynamic>>{};
  int upserts = 0;
  int fetches = 0;
  var _clock = 0;

  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) async {
    upserts++;
    final key = row['merchant_key'] as String;
    final saved = <String, dynamic>{
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': row['category_key'],
      'deleted_at': row['deleted_at'],
      'updated_at': DateTime.utc(2026, 11, 16)
          .add(Duration(seconds: ++_clock))
          .toIso8601String(),
    };
    rows[key] = saved;
    return [Map.of(saved)];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchRows({
    required SyncCursor after,
    int limit = 200,
  }) async {
    fetches++;
    final sorted = rows.values.toList()
      ..sort((a, b) {
        final c =
            (a['updated_at'] as String).compareTo(b['updated_at'] as String);
        return c != 0 ? c : (a['id'] as String).compareTo(b['id'] as String);
      });
    return sorted
        .where((r) {
          if (after.id.isEmpty) return true;
          final at = normalizeCursorTimestamp(r['updated_at']);
          final c = at.compareTo(after.updatedAt);
          return c > 0 ||
              (c == 0 && (r['id'] as String).compareTo(after.id) > 0);
        })
        .take(limit)
        .map(Map<String, dynamic>.from)
        .toList();
  }

  /// A rule written by another device of the same user.
  void serverWrite(String key, String category, {bool deleted = false}) {
    rows[key] = {
      'id': rows[key]?['id'] ?? 'srv-${rows.length + 1}',
      'merchant_key': key,
      'category_key': category,
      'deleted_at': deleted ? '2026-11-16T12:00:00.000Z' : null,
      'updated_at': DateTime.utc(2026, 11, 16)
          .add(Duration(seconds: ++_clock))
          .toIso8601String(),
    };
  }
}

PlanningOutboxQueue _queue(AppDatabase db, {String? uid = 'user-1'}) =>
    PlanningOutboxQueue(
        db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => uid);

MerchantRuleSyncService _service(
  AppDatabase db,
  MerchantRuleRemote remote, {
  bool consent = true,
  bool capability = true,
  List<String>? applied,
}) =>
    MerchantRuleSyncService(
      db: db,
      queue: _queue(db),
      remote: remote,
      getAuthUserId: () async => 'user-1',
      mayEgress: () async => consent,
      serverReady: () async => capability,
      onRuleApplied: applied == null ? null : (k, c) => applied.add('$k=$c'),
    );

Future<List<Map<String, Object?>>> _outbox(AppDatabase db) async => [
      for (final r in await db.customSelect(
        'SELECT entity_id, operation, payload_json, status '
        'FROM planning_sync_outbox WHERE entity_type = ? ORDER BY entity_id;',
        variables: [Variable.withString(MerchantRuleSyncService.entityType)],
      ).get())
        {
          'id': r.read<String>('entity_id'),
          'op': r.read<String>('operation'),
          'category': (jsonDecode(r.read<String>('payload_json'))
              as Map)['category_key'],
          'status': r.read<String>('status'),
        }
    ];

Future<int> _parked(AppDatabase db) async => (await db
        .customSelect("SELECT COUNT(*) AS n FROM parked_child_rows "
            "WHERE table_name = 'user_merchant_rules';")
        .getSingle())
    .read<int>('n');

ParsedTransaction _capture(String merchant) => ParsedTransaction(
      amountText: '45',
      amount: 45,
      currency: 'SAR',
      type: TransactionType.payment,
      source: TransactionSource.card,
      rawMerchant: merchant,
    );

void main() {
  late LedgerAdmissionFixture fixture;
  late AppDatabase db;
  late DriftMerchantCategoryRepository rules;
  late _FakeRuleRemote remote;

  setUp(() async {
    fixture = await LedgerAdmissionFixture.open('user-1');
    db = fixture.database;
    rules = DriftMerchantCategoryRepository(db, outboxQueue: _queue(db));
    remote = _FakeRuleRemote();
  });
  tearDown(() => fixture.finish());

  group('intent', () {
    test('confirm, forget and delete+Undo record one coalesced op per merchant',
        () async {
      final useCase = LearnedRulesUseCase(merchantCategoryRepository: rules);
      await rules.confirmMerchantCategory(
          rawMerchant: 'Zaryab Dimashqi 12',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      expect(await _outbox(db), [
        {
          'id': 'ZARYAB DIMASHQI',
          'op': 'update',
          'category': 'restaurants',
          'status': 'pending'
        }
      ]);

      // Update.
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB DIMASHQI',
          categoryKey: 'groceries',
          isUserConfirmed: true);
      expect((await _outbox(db)).single['category'], 'groceries');

      // Delete from the Learned rules page.
      const rule = LearnedMerchantRule(
          rawMerchant: 'ZARYAB DIMASHQI', categoryKey: 'groceries');
      await useCase.delete(rule);
      expect((await _outbox(db)).single['op'], 'delete');

      // Undo.
      await useCase.restore(rule);
      final undone = (await _outbox(db)).single;
      expect(undone['op'], 'update');
      expect(undone['category'], 'groceries');
    });

    test('seed / catalog rows are never recorded', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'CARREFOUR',
          categoryKey: 'groceries',
          isUserConfirmed: false);
      // Forgetting a merchant that only has a seed mapping is not a rule delete.
      await rules.forgetUserConfirmedRule('CARREFOUR');
      expect(await _outbox(db), isEmpty);

      // The one-time backfill skips them too.
      await _service(db, remote).sync();
      expect(remote.rows, isEmpty);
    });

    test('no account owner (guest, Cloud never set up): nothing is recorded',
        () async {
      final guest = DriftMerchantCategoryRepository(db,
          outboxQueue: _queue(db, uid: null));
      await guest.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      expect(await _outbox(db), isEmpty);
      expect(await guest.userConfirmedCategoryFor('ZARYAB'), 'restaurants');
    });

    test('deleting a category tombstones the user rules that pointed at it',
        () async {
      final categories = DriftCategoryRepository(db, outboxQueue: _queue(db));
      final custom = await categories.createCategory(
          nameAr: 'تبرعات', icon: 'heart', color: '#ff0000', isIncome: false);
      await rules.confirmMerchantCategory(
          rawMerchant: 'CHARITY',
          categoryKey: custom.key,
          isUserConfirmed: true);
      await categories.deleteCategory(custom.id);
      final row = (await _outbox(db)).single;
      expect(row['id'], 'CHARITY');
      expect(row['op'], 'delete');
    });
  });

  group('push', () {
    test('Cloud OFF (no consent): nothing is sent, intent waits', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      final res = await _service(db, remote, consent: false).sync();
      expect(res.pushed, 0);
      expect(remote.upserts, 0);
      expect(remote.fetches, 0);
      expect((await _outbox(db)).single['status'], 'pending');
    });

    test('server without the capability: nothing is sent', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      await _service(db, remote, capability: false).sync();
      expect(remote.upserts + remote.fetches, 0);
    });

    test('Cloud ON: create, update and delete reach the server', () async {
      final sync = _service(db, remote);
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      expect((await sync.sync()).pushed, 1);
      expect(remote.rows['ZARYAB']!['category_key'], 'restaurants');
      expect(remote.rows['ZARYAB']!['deleted_at'], isNull);
      expect(await _outbox(db), isEmpty);

      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'groceries',
          isUserConfirmed: true);
      await sync.sync();
      expect(remote.rows['ZARYAB']!['category_key'], 'groceries');

      await rules.forgetUserConfirmedRule('ZARYAB');
      await sync.sync();
      expect(remote.rows['ZARYAB']!['deleted_at'], isNotNull);
      expect(await _outbox(db), isEmpty);
      // The pull of our own tombstone leaves the rule gone.
      expect(await rules.userConfirmedCategoryFor('ZARYAB'), isNull);
    });

    test('rules confirmed before sign-in are backfilled once', () async {
      final guest = DriftMerchantCategoryRepository(db,
          outboxQueue: _queue(db, uid: null));
      await guest.confirmMerchantCategory(
          rawMerchant: 'OLD RULE', categoryKey: 'fuel', isUserConfirmed: true);
      final res = await _service(db, remote).sync();
      expect(res.pushed, 1);
      expect(remote.rows['OLD RULE']!['category_key'], 'fuel');

      // Not again: a server-side delete from another device must stick.
      remote.serverWrite('OLD RULE', 'fuel', deleted: true);
      await _service(db, remote).sync();
      expect(await rules.userConfirmedCategoryFor('OLD RULE'), isNull);
      expect(await _outbox(db), isEmpty);
    });
  });

  group('pull / restore', () {
    test('restored rules are user-confirmed, listed and used by categorization',
        () async {
      remote.serverWrite('ZARYAB DIMASHQI', 'restaurants');
      remote.serverWrite('CARREFOUR', 'shopping');
      final applied = <String>[];
      final res = await _service(db, remote, applied: applied).sync();
      expect(res.applied, 2);
      expect(applied,
          containsAll(['ZARYAB DIMASHQI=restaurants', 'CARREFOUR=shopping']));

      // Learned rules page.
      final listed =
          await LearnedRulesUseCase(merchantCategoryRepository: rules).list();
      expect({for (final r in listed) r.rawMerchant: r.categoryKey},
          containsPair('ZARYAB DIMASHQI', 'restaurants'));
      // A restored rule overrides a seed mapping and is user-confirmed.
      expect(
          await rules.userConfirmedCategoryFor('Carrefour 0042'), 'shopping');

      // Next capture: both categorization paths pick the restored rule.
      expect(await learnedRuleCategoryFor(rules, 'Zaryab Dimashqi 991'),
          (categoryKey: 'restaurants', userConfirmed: true));
      final categorizer = Categorizer(
          map: MerchantCategoryMap(await rules.getLearnedCategoryMap()));
      final result = categorizer.categorize(_capture('Zaryab Dimashqi 991'));
      expect(result.categoryKey, 'restaurants');
      expect(result.source, CategorySource.userMap);

      // A pulled rule records no new intent (no echo).
      expect(await _outbox(db), isEmpty);
    });

    test('a tombstone from another device removes the local rule', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      await _service(db, remote).sync();
      remote.serverWrite('ZARYAB', 'restaurants', deleted: true);
      final res = await _service(db, remote).sync();
      expect(res.removed, 1);
      expect(await rules.userConfirmedCategoryFor('ZARYAB'), isNull);
      expect(await _outbox(db), isEmpty);
    });

    test('a pending local edit is not overwritten by the pull', () async {
      remote.serverWrite('ZARYAB', 'groceries');
      await rules.confirmMerchantCategory(
          rawMerchant: 'ZARYAB',
          categoryKey: 'restaurants',
          isUserConfirmed: true);
      // Push fails once: the local edit stays pending through the pull.
      final failing = _FailingRemote(remote);
      await _service(db, failing).sync();
      expect(await rules.userConfirmedCategoryFor('ZARYAB'), 'restaurants');
      // The retry backoff elapses; the local edit then wins on the server.
      await db.customStatement(
          'UPDATE planning_sync_outbox SET next_retry_at = NULL;');
      await _service(db, remote).sync();
      expect(remote.rows['ZARYAB']!['category_key'], 'restaurants');
    });

    test('rule for a category not restored yet is parked, then applied',
        () async {
      remote.serverWrite('CHARITY', 'custom_تبرعات');
      final first = await _service(db, remote).sync();
      expect(first.applied, 0);
      expect(first.parked, 1);
      expect(await _parked(db), 1);
      expect(await rules.userConfirmedCategoryFor('CHARITY'), isNull);

      // The category arrives (planning pull) — no new server row needed.
      await db.customStatement(
          "INSERT INTO categories(id, key, name_ar, icon, color, is_income, "
          "sort_order) VALUES ('c-charity', 'custom_تبرعات', 'تبرعات', 'heart', "
          "'#ff0000', 0, 99);");
      final second = await _service(db, remote).sync();
      expect(second.applied, 1);
      expect(second.parked, 0);
      expect(await rules.userConfirmedCategoryFor('CHARITY'), 'custom_تبرعات');
    });
  });

  test('reinstall: rules come back on a fresh replica after sign-in', () async {
    await rules.confirmMerchantCategory(
        rawMerchant: 'Zaryab Dimashqi',
        categoryKey: 'restaurants',
        isUserConfirmed: true);
    await _service(db, remote).sync();
    await fixture.finish();

    // New install, same account, empty local DB.
    fixture = await LedgerAdmissionFixture.open('user-1');
    db = fixture.database;
    final fresh = DriftMerchantCategoryRepository(db);
    expect(await fresh.userConfirmedCategoryFor('ZARYAB DIMASHQI'), isNull);
    await _service(db, remote).sync();
    final listed =
        await LearnedRulesUseCase(merchantCategoryRepository: fresh).list();
    expect(listed.map((r) => r.categoryKey), ['restaurants']);
    expect(await learnedRuleCategoryFor(fresh, 'ZARYAB DIMASHQI 7'),
        (categoryKey: 'restaurants', userConfirmed: true));
  });
}

class _FailingRemote implements MerchantRuleRemote {
  _FailingRemote(this._inner);
  final _FakeRuleRemote _inner;
  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) =>
      Future.error(StateError('offline'));
  @override
  Future<List<Map<String, dynamic>>> fetchRows(
          {required SyncCursor after, int limit = 200}) =>
      _inner.fetchRows(after: after, limit: limit);
}
