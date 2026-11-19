// Round 4 review fixes (R4R-01, R4R-02, R4R-07, AR-08, AR-09, AR-10) — ONE
// precedence rule for a merchant's saved category rule, used by restore, the
// cloud pull and the backfill (`ruleVersionSupersedes`):
//
//   Each side (device, backup, cloud) holds, per merchant, a RULE or a
//   REMOVAL, with a time. An incoming version (backup or cloud) replaces the
//   device's only when it is STRICTLY newer, in whole milliseconds; otherwise
//   the device's stands, and where it differs from the cloud it is pushed.
//
// The tables below run every pair through the real restore use case, rule
// repository, outbox and MerchantRuleSyncService over an in-memory cloud whose
// clock runs ahead of the device's. Synthetic data only.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/backup/merchant_rule_restore.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/merchant_rule_history.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';

import '../../features/capture/ledger_admission_fixture.dart';
import 'fake_ledger_cloud.dart';
import 'fake_rule_cloud.dart';
import 'restore_sync_device.dart';

enum Kind { rule, removal }

enum When { older, same, newer }

const _a = 'restaurants'; // what the device holds
const _b = 'shopping'; // what the backup / cloud brings
final _t0 = DateTime.utc(2026, 7, 10, 12);

/// [when] relative to the device's version at [_t0]. "same" differs only below
/// the millisecond, the resolution of the rule.
DateTime _at(When when) => switch (when) {
      When.older => _t0.subtract(const Duration(hours: 1)),
      When.same => _t0.add(const Duration(microseconds: 900)),
      When.newer => _t0.add(const Duration(hours: 1)),
    };

void main() {
  late LedgerAdmissionFixture admission;
  late Device d;
  late AppDatabase db;
  late DriftMerchantCategoryRepository rules;
  late FakeRuleCloud cloud;
  String? signedIn = uid;

  const shop = 'Synthetic Rule Shop';
  final key = AppDatabase.normalizeMerchant(shop);

  PlanningOutboxQueue queue() => PlanningOutboxQueue(
      db: db, isSyncEnabled: (_) => true, getAuthUserId: () async => signedIn);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    signedIn = uid;
    admission = await LedgerAdmissionFixture.open(uid);
    db = admission.database;
    d = Device(db, FakeLedgerCloud());
    await d.seedAccount(); // the device holds records: every restore merges
    rules = DriftMerchantCategoryRepository(db, outboxQueue: queue());
    cloud = FakeRuleCloud();
  });
  tearDown(() => admission.finish());

  MerchantRuleSyncService service({int pageSize = 200}) =>
      MerchantRuleSyncService(
        db: db,
        queue: queue(),
        remote: cloud,
        getAuthUserId: () async => signedIn,
        mayEgress: () async => true,
        serverReady: () async => true,
        pageSize: pageSize,
      );
  Future<void> sync({int pageSize = 200}) => service(pageSize: pageSize).sync();
  Future<List<String>> queued() async => [
        for (final r in await db
            .customSelect('SELECT entity_id FROM planning_sync_outbox '
                "WHERE entity_type = 'merchant_rule';")
            .get())
          r.read<String>('entity_id'),
      ];

  Future<void> clearOutbox() => db.customStatement(
      "DELETE FROM planning_sync_outbox WHERE entity_type = 'merchant_rule';");

  /// Puts the device in a state with an exact time and nothing queued.
  Future<void> deviceHolds(Kind? kind,
      {DateTime? at, String category = _a}) async {
    await db.customStatement('DELETE FROM merchant_category_map '
        'WHERE is_user_confirmed = 1;');
    await db.customStatement('DELETE FROM merchant_rule_tombstones;');
    if (kind == Kind.rule) {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: category, isUserConfirmed: true);
      await setMerchantRuleTime(db, key, at ?? _t0);
    } else if (kind == Kind.removal) {
      await setMerchantRuleTombstone(db, key, category, at ?? _t0);
    }
    await clearOutbox();
  }

  /// The device's state: the category of its rule, 'removed', or 'nothing'.
  Future<String> device() async {
    final v = await deviceRuleVersion(db, key);
    return v == null ? 'nothing' : v.categoryKey ?? 'removed';
  }

  /// The cloud's state in the same words.
  String cloudState() {
    final row = cloud.rows[key];
    return row == null
        ? 'nothing'
        : row['deleted_at'] != null
            ? 'removed'
            : row['category_key'] as String;
  }

  /// A backup (current format) holding exactly this version of the merchant.
  Future<Map<String, dynamic>> backupWith(Kind kind, DateTime at) async {
    // Any saved rule gives the backup the merchant and category rows.
    await rules.confirmMerchantCategory(
        rawMerchant: shop, categoryKey: _b, isUserConfirmed: true);
    final backup = await d.backup();
    final tables = backup['tables'] as Map;
    final rows =
        (tables['merchant_category_map'] as List).cast<Map<String, dynamic>>();
    if (kind == Kind.rule) {
      rows.firstWhere((r) => r['is_user_confirmed'] == 1)['updated_at'] =
          at.toIso8601String();
      tables['merchant_rule_tombstones'] = <Map<String, dynamic>>[];
    } else {
      rows.removeWhere((r) => r['is_user_confirmed'] == 1);
      tables['merchant_rule_tombstones'] = [
        {
          'merchant_key': key,
          'category_key': _b,
          'deleted_at': at.toIso8601String(),
        }
      ];
    }
    return backup;
  }

  void cloudHolds(Kind kind, DateTime at, {String category = _b}) =>
      cloud.otherDevice(key, category,
          removed: kind == Kind.removal, at: at.toIso8601String());

  /// What the incoming version leaves on the device when it wins.
  String taken(Kind incoming) => incoming == Kind.rule ? _b : 'removed';
  String heldState(Kind? held) => switch (held) {
        Kind.rule => _a,
        Kind.removal => 'removed',
        null => 'nothing',
      };

  group('the rule itself', () {
    final rule = RuleVersion.rule(_b, _t0);
    final removal = RuleVersion.removal(_t0);
    test('nothing held: the incoming version is taken', () {
      expect(ruleVersionSupersedes(rule, null), isTrue);
      expect(ruleVersionSupersedes(removal, null), isTrue);
    });
    for (final incoming in Kind.values) {
      for (final held in Kind.values) {
        for (final when in When.values) {
          test('incoming ${incoming.name} ${when.name} than held ${held.name}',
              () {
            final i = incoming == Kind.rule
                ? RuleVersion.rule(_b, _at(when))
                : RuleVersion.removal(_at(when));
            final h = held == Kind.rule
                ? RuleVersion.rule(_a, _t0)
                : RuleVersion.removal(_t0);
            expect(ruleVersionSupersedes(i, h), when == When.newer);
          });
        }
      }
    }
    test(
        'times that cannot be read: an unreadable incoming version never '
        'wins; a held removal stands; a held rule gives way', () {
      expect(ruleVersionSupersedes(const RuleVersion.rule(_b, null), rule),
          isFalse);
      expect(ruleVersionSupersedes(const RuleVersion.removal(null), rule),
          isFalse);
      expect(ruleVersionSupersedes(rule, const RuleVersion.removal(null)),
          isFalse);
      expect(ruleVersionSupersedes(rule, const RuleVersion.rule(_a, null)),
          isTrue);
    });
  });

  group('backup against device (restore), then sync: device and cloud agree',
      () {
    for (final incoming in Kind.values) {
      for (final held in <Kind?>[Kind.rule, Kind.removal, null]) {
        for (final when in held == null ? [When.newer] : When.values) {
          final wins = held == null || when == When.newer;
          final expected = wins ? taken(incoming) : heldState(held);
          test(
              'backup ${incoming.name}${held == null ? '' : ' ${when.name} than'} '
              'device ${held?.name ?? 'nothing'} -> $expected', () async {
            final backup = await backupWith(incoming, _at(when));
            await deviceHolds(held);
            // The cloud already has what the device holds (synced earlier).
            if (held != null) cloudHolds(held, _t0, category: _a);
            await sync();
            cloud.pushedKeys.clear();

            await d.restore(backup);
            expect(await device(), expected);
            await d.restore(backup);
            expect(await device(), expected, reason: 'repeated restore');

            await sync();
            await sync();
            expect(await device(), expected, reason: 'after sync');
            final inCloud = cloudState();
            expect(
                inCloud == expected ||
                    (expected == 'removed' && inCloud == 'nothing') ||
                    (expected == 'nothing' && inCloud == 'removed'),
                isTrue,
                reason: 'cloud holds $inCloud, device $expected');
          });
        }
      }
    }
  });

  group('cloud against device (pull): device and cloud agree', () {
    for (final incoming in Kind.values) {
      for (final held in <Kind?>[Kind.rule, Kind.removal, null]) {
        for (final when in held == null ? [When.newer] : When.values) {
          final wins = held == null || when == When.newer;
          final expected = wins ? taken(incoming) : heldState(held);
          test(
              'cloud ${incoming.name}${held == null ? '' : ' ${when.name} than'} '
              'device ${held?.name ?? 'nothing'} -> $expected', () async {
            await deviceHolds(held);
            cloudHolds(incoming, _at(when));

            await sync();
            expect(await device(), expected);
            if (wins && incoming == Kind.removal && when != When.same) {
              expect(
                  (await deviceRuleVersion(db, key))!.at,
                  _at(when)
                      .subtract(Duration(microseconds: _at(when).microsecond)),
                  reason: 'the removal carries the cloud\'s time, not "now"');
            }
            await sync();
            expect(await device(), expected, reason: 'second sync');
            final inCloud = cloudState();
            expect(
                inCloud == expected ||
                    (expected == 'removed' && inCloud == 'nothing'),
                isTrue,
                reason: 'cloud holds $inCloud, device $expected');
          });
        }
      }
    }
  });

  group(
      'backup against cloud (restore onto a device that holds neither, '
      'then sync): the newer one wins on both', () {
    for (final backupKind in Kind.values) {
      for (final cloudKind in Kind.values) {
        for (final when in When.values) {
          // The backup's version is on the device first; the cloud's replaces
          // it only when strictly newer.
          final cloudWins = when == When.newer;
          final expected = cloudWins
              ? (cloudKind == Kind.rule ? _a : 'removed')
              : taken(backupKind);
          test(
              'cloud ${cloudKind.name} ${when.name} than backup '
              '${backupKind.name} -> $expected', () async {
            final backup = await backupWith(backupKind, _t0);
            await deviceHolds(null);
            cloudHolds(cloudKind, _at(when), category: _a);

            await d.restore(backup);
            expect(await device(), taken(backupKind));
            await sync();
            await sync();
            expect(await device(), expected);
            expect(cloudState(), expected);
          });
        }
      }
    }
  });

  group('within one side', () {
    test(
        'device: a rule and a removal never coexist; a change made now is '
        'always later than the version it replaces, even one stamped by a '
        'clock that runs ahead', () async {
      final ahead = DateTime.utc(2099);
      await deviceHolds(Kind.rule, at: ahead);
      await rules.forgetUserConfirmedRule(shop);
      var held = (await deviceRuleVersion(db, key))!;
      expect(held.isRemoval, isTrue);
      expect(held.at!.isAfter(ahead), isTrue,
          reason: 'the removal is newer than the rule it removed');

      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _b, isUserConfirmed: true);
      final removedAt = held.at!;
      held = (await deviceRuleVersion(db, key))!;
      expect(held.categoryKey, _b);
      expect(held.at!.isAfter(removedAt), isTrue,
          reason: 'the rule saved again is newer than its removal');
      expect(
          await db
              .customSelect('SELECT 1 FROM merchant_rule_tombstones;')
              .get(),
          isEmpty);

      final savedAt = held.at!;
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      held = (await deviceRuleVersion(db, key))!;
      expect(held.at!.isAfter(savedAt), isTrue,
          reason: 'an edit is newer than the rule it changed');
    });

    for (final when in When.values) {
      test('backup: its rule ${when.name} than its own recorded removal',
          () async {
        final backup = await backupWith(Kind.rule, _at(when));
        ((backup['tables'] as Map)['merchant_rule_tombstones'] as List).add({
          'merchant_key': key,
          'category_key': _b,
          'deleted_at': _t0.toIso8601String(),
        });
        await deviceHolds(null);
        await d.restore(backup);
        expect(await device(), when == When.newer ? _b : 'removed');
      });
    }
  });

  group('reviewers\' reproductions', () {
    test(
        'R4R-01 the pull fails once after a restore: the restored rule is '
        'NOT pushed over a removal this device has not read; the retry reads '
        'it and removes the rule', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await sync();
      final backup = await d.backup();
      await deviceHolds(null);
      cloud.otherDevice(key, _a, removed: true);
      cloud.pushedKeys.clear();

      await d.restore(backup);
      expect(await device(), _a, reason: 'this device cannot know yet');
      cloud.failFetches = 1;
      await sync();
      expect(cloud.pushedKeys, isEmpty,
          reason: 'nothing restored is pushed before a pull has completed');
      expect(cloudState(), 'removed');

      // The app restarts; the precondition is stored, not in memory.
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
      expect(cloud.pushedKeys, isEmpty);
      await sync();
      expect(cloudState(), 'removed');
    });

    test('R4R-01 the very first backfill also waits for a completed pull',
        () async {
      await deviceHolds(Kind.rule);
      cloud.otherDevice(key, _a, removed: true);
      cloud.pushedKeys.clear();
      cloud.failFetches = 2;
      await sync();
      await sync();
      expect(cloud.pushedKeys, isEmpty);
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
    });

    test(
        'R4R-02 / A4 "Leave out" while the cloud still holds the rule and '
        'this device has not read it: the rule stays off the device and is '
        'removed in the cloud', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      final backup = await d.backup();
      backup['version'] = 4;
      backup['schemaVersion'] = 4;
      (backup['tables'] as Map)
          .removeWhere((t, _) => MerchantRuleRestore.historyTables.contains(t));
      await deviceHolds(null);
      // Live in the cloud since before the "Leave out", not pulled yet. (With
      // a cloud clock running ahead it would read as newer and go back on
      // the list instead: see the signed-out test below.)
      cloud.otherDevice(key, _a, at: '2026-01-01T00:00:00.000Z');

      await d.restore(backup);
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
      await MerchantRuleRestore(db).decide(key, add: false, queue: queue());
      await sync();
      await sync();

      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
      await d.restore(backup);
      await sync();
      expect(await device(), 'removed');
      expect(await MerchantRuleRestore(db).pending(), isEmpty);
      expect(cloudState(), 'removed');
    });

    /// A legacy backup holding the rule, restored onto a device that holds
    /// nothing for it, and the user's "Leave out".
    Future<Map<String, dynamic>> leaveOut({required bool signedInNow}) async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      final backup = await d.backup();
      backup['version'] = 4;
      backup['schemaVersion'] = 4;
      (backup['tables'] as Map)
          .removeWhere((t, _) => MerchantRuleRestore.historyTables.contains(t));
      await deviceHolds(null);
      await d.restore(backup);
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
      if (!signedInNow) signedIn = null;
      await MerchantRuleRestore(db).decide(key, add: false, queue: queue());
      signedIn = uid;
      return backup;
    }

    Future<List<String>> tombstones() async => [
          for (final r in await db
              .customSelect(
                  'SELECT merchant_key FROM merchant_rule_tombstones;')
              .get())
            r.read<String>('merchant_key'),
        ];

    test(
        'R4R-02 a cloud rule genuinely newer than "Leave out" (saved on '
        'another device afterwards) is not applied silently: it goes back on '
        'the list to choose, and the record of the choice stays', () async {
      await leaveOut(signedInNow: true);
      await sync();
      expect(cloudState(), 'removed');
      cloud.otherDevice(key, _b); // later, on another device

      await sync();
      expect(await device(), 'removed');
      expect(await tombstones(), [key]);
      final back = await MerchantRuleRestore(db).pending();
      expect(back.map((c) => (c.merchantKey, c.categoryKey)), [(key, _b)]);
      await sync();
      expect(await device(), 'removed', reason: 'still not applied');
      expect(cloudState(), _b, reason: 'nothing was pushed over it');

      // Choosing again: Add takes the rule; it is then an ordinary rule.
      await MerchantRuleRestore(db).decide(key, add: true);
      expect(await device(), _b);
    });

    test(
        'R4R-02 "Leave out" while signed out, the cloud\'s copy stamped by a '
        'clock that runs ahead: the rule is not brought back; it waits on '
        'the list', () async {
      cloud.otherDevice(key, _a); // live, 2027 server clock, not pulled
      await leaveOut(signedInNow: false);
      expect(
          await db
              .customSelect("SELECT 1 FROM planning_sync_outbox "
                  "WHERE entity_type = 'merchant_rule';")
              .get(),
          isEmpty);
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(await tombstones(), [key]);
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
      // "Leave out" again, signed in: now it is newer than the cloud's copy.
      await MerchantRuleRestore(db).decide(key, add: false, queue: queue());
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
      expect(await MerchantRuleRestore(db).pending(), isEmpty);
    });

    test(
        'R4R-02 the record of "Leave out" travels in a backup: restored onto '
        'a device holding the removal without it, a newer cloud rule still '
        'goes back on the list', () async {
      await leaveOut(signedInNow: true);
      await sync();
      final withChoice = await d.backup();
      await db.customStatement('DELETE FROM merchant_rule_restore_choices;');
      await d.restore(withChoice);
      expect(await MerchantRuleRestore(db).pending(), isEmpty,
          reason: 'the record is not a rule to choose');
      cloud.otherDevice(key, _b);
      await sync();
      expect(await device(), 'removed');
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
    });

    test(
        'R4R-02 a backup rule newer than "Leave out" also goes back on the '
        'list instead of being restored', () async {
      final newer = await backupWith(
          Kind.rule, DateTime.now().toUtc().add(const Duration(days: 1)));
      await leaveOut(signedInNow: true);
      await d.restore(newer);
      expect(await device(), 'removed');
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
    });

    test(
        'X-R1 a queued "Leave out" is not pushed over a newer rule another '
        'device saved before this sync: the cloud keeps it and the merchant '
        'goes back on the list', () async {
      await leaveOut(signedInNow: true);
      expect(await queued(), [key], reason: 'the removal is queued');
      cloud.otherDevice(key, _b); // later, on another device, not pulled

      await sync();
      await sync();
      expect(cloudState(), _b, reason: 'the newer rule is not overwritten');
      expect(await device(), 'removed', reason: 'not applied silently');
      expect(
          (await MerchantRuleRestore(db).pending())
              .map((c) => (c.merchantKey, c.categoryKey)),
          [(key, _b)]);
      expect(await queued(), isEmpty, reason: 'the losing removal is dropped');
    });

    test(
        'X-R2 an older queued edit does not overwrite another device\'s '
        'later edit; a newer queued edit still wins', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await sync();
      // Offline edit here, then a later edit on another device.
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'groceries', isUserConfirmed: true);
      cloud.otherDevice(key, _b);
      await sync();
      await sync();
      expect(await device(), _b);
      expect(cloudState(), _b);
      expect(await queued(), isEmpty);

      // The other way round: the other device first, then a newer edit here.
      cloud.otherDevice(key, _a, at: '2026-01-01T00:00:00.000Z');
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: 'groceries', isUserConfirmed: true);
      await sync();
      expect(await device(), 'groceries');
      expect(cloudState(), 'groceries');
    });

    test(
        'no push unless the pull of the same run completed: a pull failing '
        'on page 2 pushes nothing; the next run reconciles and pushes',
        () async {
      for (final other in ['SYNTHETIC OTHER A', 'SYNTHETIC OTHER B']) {
        cloud.otherDevice(other, _a);
      }
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      cloud.pushedKeys.clear();
      cloud.failFetchNumber = 2;
      await sync(pageSize: 2);
      expect(cloud.pushedKeys, isEmpty);
      expect(await queued(), [key], reason: 'kept for the next run');
      await sync(pageSize: 2);
      // (The one-time backfill also re-sends the two rules the first run
      // read before its pull broke off: same values, nothing overwritten.)
      expect(cloud.pushedKeys, contains(key));
      expect(cloudState(), _a);
      expect(cloud.live().values.toSet(), {_a});
      expect(await queued(), isEmpty);
    });

    test(
        'the push-only flush (sign-out) also pulls first: a queued '
        '"Leave out" is not pushed over a newer rule', () async {
      await leaveOut(signedInNow: true);
      cloud.otherDevice(key, _b);
      await service().push();
      expect(cloudState(), _b);
      expect(await MerchantRuleRestore(db).pending(), hasLength(1));
    });

    test(
        'R4R-02 / A3 a rule forgotten while signed out: after sign-in the '
        'older cloud copy does not bring it back, and the cloud is told',
        () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await sync();
      final backup = await d.backup();
      signedIn = null; // signed out: nothing can be queued
      await DriftMerchantCategoryRepository(db, outboxQueue: queue())
          .forgetUserConfirmedRule(shop);
      expect(
          await db
              .customSelect("SELECT 1 FROM planning_sync_outbox "
                  "WHERE entity_type = 'merchant_rule';")
              .get(),
          isEmpty);
      await d.restore(backup);
      expect(await device(), 'removed');

      signedIn = uid;
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
    });

    test(
        'A2 signed out at restore time, a removal waiting in the cloud: '
        'after sign-in the rule is removed and the cloud stays removed',
        () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await sync();
      final backup = await d.backup();
      await deviceHolds(null);
      cloud.otherDevice(key, _a, removed: true);
      signedIn = null;
      await d.restore(backup);
      await sync(); // signed out: does nothing
      expect(await device(), _a);

      signedIn = uid;
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
    });

    test(
        'AR-09 a restored newer edit is kept against an older cloud change '
        'the device had not read, and is pushed', () async {
      final nov15 = DateTime.utc(2026, 11, 15);
      final nov16 = DateTime.utc(2026, 11, 16);
      final nov17 = DateTime.utc(2026, 11, 17);
      final backup = await backupWith(Kind.rule, nov17); // shopping, Nov 17
      await deviceHolds(Kind.rule, at: nov15); // restaurants, Nov 15
      cloudHolds(Kind.rule, nov16, category: _a); // restaurants, Nov 16

      await d.restore(backup);
      expect(await device(), _b);
      await sync();
      await sync();
      expect(await device(), _b);
      expect(cloudState(), _b);
    });

    test(
        'AR-10 a pull of the same category still takes the cloud\'s later '
        'time, so an older backup with another category cannot win afterwards',
        () async {
      final backup = await backupWith(Kind.rule, _at(When.newer)); // B, +1h
      await deviceHolds(Kind.rule); // A at t0
      cloudHolds(Kind.rule, _t0.add(const Duration(hours: 2)), category: _a);
      await sync();
      expect((await deviceRuleVersion(db, key))!.at,
          _t0.add(const Duration(hours: 2)));

      await d.restore(backup);
      expect(await device(), _a, reason: 'A was confirmed later than B');
    });

    test(
        'AR-10 a pulled removal is not re-stamped "now": a backup edit made '
        'after that removal is restored', () async {
      final backup = await backupWith(Kind.rule, _at(When.newer)); // +1h
      await deviceHolds(Kind.rule, at: _at(When.older));
      cloudHolds(Kind.removal, _t0);
      await sync();
      final held = (await deviceRuleVersion(db, key))!;
      expect(held.isRemoval, isTrue);
      expect(held.at, _t0);

      await d.restore(backup);
      expect(await device(), _b);
      await sync();
      await sync();
      expect(cloudState(), _b);
    });

    test(
        'R4R-07 a full apply makes the next sync read every cloud rule '
        'again: a cloud removal the device read before it kept such records '
        'still removes the restored rule', () async {
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await rules.confirmMerchantCategory(
          rawMerchant: 'Synthetic Other Shop',
          categoryKey: _b,
          isUserConfirmed: true);
      await clearOutbox();
      final backup = await d.backup();
      // The cloud removed the first rule; this device read that row (its
      // cursor is past it) without recording it, as build 147 did.
      cloud.otherDevice(key, _a, removed: true);
      await db.customStatement('DELETE FROM merchant_category_map '
          'WHERE is_user_confirmed = 1;');
      await db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await sync();
      await db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await db.customStatement('DELETE FROM accounts;');
      expect(await RestoreBackupUseCase.restoreWillMerge(db), isFalse);
      cloud.pushedKeys.clear();

      await d.restore(backup); // full apply
      expect(await device(), _a);
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
      expect(
          cloud.live(),
          {
            AppDatabase.normalizeMerchant('Synthetic Other Shop'): _b,
          },
          reason: 'the rule the cloud never had is pushed after the pull');
    });

    test(
        'restore, sync, then a second device that still holds the removed '
        'rule and syncs: the rule does not come back anywhere', () async {
      // This device removed the rule; the removal is in the cloud.
      await rules.confirmMerchantCategory(
          rawMerchant: shop, categoryKey: _a, isUserConfirmed: true);
      await sync();
      final backup = await d.backup();
      await rules.forgetUserConfirmedRule(shop);
      await sync();
      await d.restore(backup);
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
      final removal = Map<String, dynamic>.of(cloud.rows[key]!);

      // The second device: the same service on the same schema, holding the
      // rule as it synced it before the removal, now reading the cloud.
      await deviceHolds(Kind.rule, at: DateTime.utc(2027, 1, 1, 0, 0, 1));
      await db.customStatement("DELETE FROM sync_cursors "
          "WHERE entity = 'merchant_rules';");
      await sync();
      await sync();
      expect(await device(), 'removed');
      expect(cloud.rows[key], removal, reason: 'nothing was pushed back');
      // Restoring the old backup on that second device changes nothing.
      await d.restore(backup);
      await sync();
      expect(await device(), 'removed');
      expect(cloudState(), 'removed');
    });
  });
}
