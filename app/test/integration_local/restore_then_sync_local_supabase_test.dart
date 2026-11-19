// V1-020 / V1-070, decision 3.3 (restore = merge) — restore a backup, then
// turn Cloud back on, against a REAL local Supabase. Skipped unless LOCAL_SUPABASE_URL is set (see local-stack.md in
// docs/releases/version-1/evidence for the stack and the env file).
//
// Real code end to end: the real backup snapshot builder and restore use case,
// the real outbox queues, push/pull services and startup reconcile backfill,
// over a database admitted by the real account-fence host. Synthetic data only.
@Tags(['local-supabase'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:money_companion/core/backend/supabase_config.dart';
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/merchant_rule_restore.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/repositories/drift_merchant_category_repository.dart';
import 'package:money_companion/data/sync/sync_cursor.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
import 'package:money_companion/features/planning_sync/services/merchant_rule_sync_service.dart';
import 'package:money_companion/features/planning_sync/services/startup_sync_reconcile_service.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../features/capture/ledger_admission_fixture.dart';
import 'local_device.dart';
import 'local_supabase_support.dart';

late LocalEnv env;
late RemoteTruth remote;

const _canonical =
    FixedPlanningCutoverCoordinator(PlanningCutoverState.canonical);

AccountEntity _account(String id) {
  final now = DateTime.utc(2026, 7, 4, 12);
  final m = Money.parse('1000.000', 'KWD');
  return AccountEntity(
    id: id,
    name: 'Restore proof account',
    currency: 'KWD',
    type: AccountType.bank,
    isDefault: true,
    sortOrder: 1,
    createdAt: now,
    updatedAt: now,
    initialBalanceMoney: m,
    currentBalanceMoney: m,
  );
}

TransactionEntity _txn(String id, String amount, String accountId) {
  final now = DateTime.utc(2026, 7, 5, 9);
  return TransactionEntity(
    id: id,
    amountMoney: Money.parse(amount, 'KWD'),
    currency: 'KWD',
    type: TransactionTypeEntity.payment,
    source: TransactionSourceEntity.unknown,
    occurredAt: now,
    rawMessage: 'manual',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    accountId: accountId,
    rawMerchant: 'Synthetic shop $id',
  );
}

/// One sync cycle in the order the app shell runs it (`_runSync`): startup
/// reconcile backfill, pending-intent reconcile, accounts push+pull, ledger
/// push+pull.
Future<ReconcileOutcome> syncCycle(Device d) async {
  final outcome = await StartupSyncReconcileService(
    db: d.db,
    getAuthUserId: signedInUid,
    coordinator: _canonical,
    pushCapability: () => ExactTransportCapability.verifiedExact,
    planningCurrencyFor: (_) async => ExactTransportCapability.verifiedExact,
    mayEgress: () async => d.consent,
  ).run();
  await PendingSyncReconciler(
    db: d.db,
    ledgerQueue: d.ledgerQueue,
    planningQueue: d.planningQueue,
    getOwnerUid: signedInUid,
    getAuthUserId: signedInUid,
    mayEgress: () async => d.consent,
  ).run();
  await d.accountsPush.push();
  await d.accountsPull.pull();
  await d.ledgerPush.push();
  await d.ledgerPull.pull();
  return outcome;
}

/// Live (not soft-deleted) local transactions: merchant -> amount text.
Future<Map<String, String>> localLive(Device d) async {
  final rows = await d.sql("SELECT raw_merchant m, amount_minor a FROM "
      "transactions WHERE status != 'ignored' ORDER BY raw_merchant");
  return {
    for (final r in rows)
      r['m'] as String: Money(r['a'] as int, 'KWD').toDecimalString(),
  };
}

/// Live server transactions: merchant -> list of amounts (a list, so a
/// duplicate server copy is visible).
Future<Map<String, List<String>>> serverLive(String uid) async {
  final rows = await remote.rows('user_transactions', uid,
      select: 'merchant,amount_text:amount::text,deleted_at,status');
  final out = <String, List<String>>{};
  for (final r in rows) {
    if (r['deleted_at'] != null || r['status'] == 'ignored') continue;
    out
        .putIfAbsent(r['merchant'] as String, () => [])
        .add(Money.parse(r['amount_text'] as String, 'KWD').toDecimalString());
  }
  for (final v in out.values) {
    v.sort();
  }
  return Map.fromEntries(
      out.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
}

Future<void> report(String label, Device d, String uid) async {
  // ignore: avoid_print
  print('$label\n  local=${await localLive(d)}\n'
      '  local sync=${await d.sql('SELECT id, status, server_id IS NOT NULL bound, sync_status FROM transactions ORDER BY id')}\n'
      '  ledger outbox=${await d.ledgerOutboxCount()}\n'
      '  server=${await serverLive(uid)}\n'
      '  server all=${await remote.rows('user_transactions', uid, select: 'client_request_id,amount_text:amount::text,status,deleted_at')}');
}

/// Decision 3.3 once Cloud is back on and sync has settled: the device holds
/// [expected] (merchant -> amount) and the cloud holds exactly the same live
/// rows, one copy each, with no sync conflict left on the device.
Future<void> expectMergedAndConverged(
    Device d, String uid, Map<String, String> expected) async {
  expect(await localLive(d), expected, reason: 'device after merge + sync');
  final server = await serverLive(uid);
  for (final e in server.entries) {
    expect(e.value, hasLength(1), reason: 'duplicate cloud copies of ${e.key}');
  }
  expect({for (final e in server.entries) e.key: e.value.single}, expected,
      reason: 'device and cloud must agree');
  expect(
      await d.sql("SELECT id FROM transactions WHERE sync_status = 'conflict'"),
      isEmpty,
      reason: 'a merge leaves nothing for the user to resolve');
}

Future<Map<String, dynamic>> takeBackup(Device d) async =>
    jsonDecode(jsonEncode(await BackupSnapshotBuilder(d.db).build()))
        as Map<String, dynamic>;

Future<void> restoreBackup(Device d, Map<String, dynamic> snapshot) async {
  await RestoreBackupUseCase(d.db, coordinator: _canonical)(snapshot);
  // Restore resets cloud consent (runPostRestoreSetup); the user turns it on.
  d.consent = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('V1-020 restore then Cloud against a local Supabase',
      skip: LocalEnv.enabled ? false : 'LOCAL_SUPABASE_URL not set', () {
    setUpAll(() async {
      // The startup reconcile backfill is a no-op without the build-time
      // config; run with --dart-define=SUPABASE_URL/SUPABASE_ANON_KEY.
      expect(SupabaseConfig.isConfigured, isTrue,
          reason: 'pass --dart-define=SUPABASE_URL=... SUPABASE_ANON_KEY=...');
      HttpOverrides.global = null;
      env = LocalEnv.load();
      remote = RemoteTruth(env);
      SharedPreferences.setMockInitialValues({});
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
              const MethodChannel('com.llfbandit.app_links/messages'),
              (c) async => null);
      await Supabase.initialize(
        url: env.url,
        anonKey: env.anonKey,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: http.Client(),
      );
    });

    tearDownAll(() async {
      await remote.cleanup();
      remote.close();
    });

    Future<(Device, String)> openSignedIn(String label) async {
      final u = await remote.createUser(label);
      await Supabase.instance.client.auth
          .signInWithPassword(email: u.email, password: u.password);
      final fixture = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(fixture.finish);
      final d = Device.wrap(fixture.database);
      return (d, u.uid);
    }

    test(
        'R1 backup, then edit/delete/add and sync, restore, Cloud on: the '
        'newer edit, the deletion and the new row all survive', () async {
      final (d, uid) = await openSignedIn('r1');
      await d.accounts.create(_account('acc-r1'));
      for (final (id, amt) in [('A', '10'), ('B', '20'), ('C', '30')]) {
        await d.transactions.saveTransaction(
            transaction: _txn('r1-$id', amt, 'acc-r1'), categoryKey: null);
      }
      await syncCycle(d);
      expect(await serverLive(uid), {
        'Synthetic shop r1-A': ['10.000'],
        'Synthetic shop r1-B': ['20.000'],
        'Synthetic shop r1-C': ['30.000'],
      });

      final backup = await takeBackup(d);

      await d.transactions.updateAmount(
          transactionId: 'r1-B', amount: Money.parse('25', 'KWD'));
      await d.transactions.deleteTransaction('r1-C');
      await d.transactions.saveTransaction(
          transaction: _txn('r1-D', '40', 'acc-r1'), categoryKey: null);
      await syncCycle(d);
      expect(await serverLive(uid), {
        'Synthetic shop r1-A': ['10.000'],
        'Synthetic shop r1-B': ['25.000'],
        'Synthetic shop r1-D': ['40.000'],
      });

      await restoreBackup(d, backup);
      const merged = {
        'Synthetic shop r1-A': '10.000',
        'Synthetic shop r1-B': '25.000',
        'Synthetic shop r1-D': '40.000',
      };
      expect(await localLive(d), merged,
          reason: 'C stays deleted, B keeps the newer edit, D is kept');
      await report('R1 after restore, Cloud off', d, uid);

      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await report('R1 after Cloud on + 2 sync cycles', d, uid);
      await expectMergedAndConverged(d, uid, merged);
    });

    test('R2 backup predates rows that exist on the server', () async {
      final (d, uid) = await openSignedIn('r2');
      await d.accounts.create(_account('acc-r2'));
      await d.transactions.saveTransaction(
          transaction: _txn('r2-A', '10', 'acc-r2'), categoryKey: null);
      await syncCycle(d);
      final backup = await takeBackup(d);
      await d.transactions.saveTransaction(
          transaction: _txn('r2-E', '50', 'acc-r2'), categoryKey: null);
      await syncCycle(d);
      expect(await serverLive(uid), {
        'Synthetic shop r2-A': ['10.000'],
        'Synthetic shop r2-E': ['50.000'],
      });

      await restoreBackup(d, backup);
      const merged = {
        'Synthetic shop r2-A': '10.000',
        'Synthetic shop r2-E': '50.000',
      };
      expect(await localLive(d), merged);
      await report('R2 after restore, Cloud off', d, uid);

      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await report('R2 after Cloud on + 2 sync cycles', d, uid);
      await expectMergedAndConverged(d, uid, merged);
    });

    test(
        'R3 a row created after the backup and never synced is kept and '
        'pushed once', () async {
      final (d, uid) = await openSignedIn('r3');
      await d.accounts.create(_account('acc-r3'));
      await d.transactions.saveTransaction(
          transaction: _txn('r3-A', '10', 'acc-r3'), categoryKey: null);
      await syncCycle(d);
      final backup = await takeBackup(d);
      await d.transactions.saveTransaction(
          transaction: _txn('r3-D', '40', 'acc-r3'), categoryKey: null);
      expect(await d.ledgerOutboxCount(), 1, reason: 'D queued, not pushed');

      await restoreBackup(d, backup);
      const merged = {
        'Synthetic shop r3-A': '10.000',
        'Synthetic shop r3-D': '40.000',
      };
      expect(await localLive(d), merged);
      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await report('R3 after Cloud on + 2 sync cycles', d, uid);
      await expectMergedAndConverged(d, uid, merged);
    });

    test(
        'R4 a category chosen by hand after the backup keeps the choice and '
        'its provenance on device and cloud', () async {
      final (d, uid) = await openSignedIn('r4');
      await d.accounts.create(_account('acc-r4'));
      await d.transactions.saveTransaction(
          transaction: _txn('r4-A', '10', 'acc-r4'), categoryKey: 'shopping');
      await syncCycle(d);
      final backup = await takeBackup(d);
      await d.transactions
          .updateCategory(transactionId: 'r4-A', categoryKey: 'restaurants');
      await syncCycle(d);

      await restoreBackup(d, backup);
      Future<Map<String, Object?>> local() async => (await d.sql(
              'SELECT c.key k, t.category_source s FROM transactions t '
              "JOIN categories c ON c.id = t.category_id WHERE t.id = 'r4-A'"))
          .single;
      expect(await local(), {'k': 'restaurants', 's': 'user'});
      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      expect(await local(), {'k': 'restaurants', 's': 'user'});
      final cloud = (await remote.rows('user_transactions', uid,
              select: 'category_id,category_source'))
          .single;
      // ignore: avoid_print
      print('R4 cloud=$cloud');
      expect(cloud['category_id'], 'restaurants');
      expect(cloud['category_source'], 'user');
    });

    test('R5 a row present only in the cloud arrives through sync, once',
        () async {
      final (d, uid) = await openSignedIn('r5');
      await d.accounts.create(_account('acc-r5'));
      await d.transactions.saveTransaction(
          transaction: _txn('r5-A', '10', 'acc-r5'), categoryKey: null);
      await syncCycle(d);
      final backup = await takeBackup(d);
      await d.transactions.saveTransaction(
          transaction: _txn('r5-E', '50', 'acc-r5'), categoryKey: null);
      await syncCycle(d);
      // This device has not pulled E (local copy gone, pull cursors unset).
      await d.db.customStatement("DELETE FROM transactions WHERE id = 'r5-E'");
      await d.db.customStatement('DELETE FROM sync_cursors');

      await restoreBackup(d, backup);
      expect(await localLive(d), {'Synthetic shop r5-A': '10.000'});
      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await expectMergedAndConverged(d, uid, {
        'Synthetic shop r5-A': '10.000',
        'Synthetic shop r5-E': '50.000',
      });
    });

    test(
        'R6 a row missing on this device returns from the backup and binds to '
        'its cloud copy without a duplicate', () async {
      final (d, uid) = await openSignedIn('r6');
      await d.accounts.create(_account('acc-r6'));
      for (final (id, amt) in [('A', '10'), ('B', '20')]) {
        await d.transactions.saveTransaction(
            transaction: _txn('r6-$id', amt, 'acc-r6'), categoryKey: null);
      }
      await syncCycle(d);
      final backup = await takeBackup(d);
      await d.db.customStatement("DELETE FROM transactions WHERE id = 'r6-B'");

      await restoreBackup(d, backup);
      const merged = {
        'Synthetic shop r6-A': '10.000',
        'Synthetic shop r6-B': '20.000',
      };
      expect(await localLive(d), merged);
      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await expectMergedAndConverged(d, uid, merged);
      expect(await remote.count('user_transactions', uid), 2);
    });

    test(
        'R9 new device (full apply): a backup row deleted in the cloud after '
        'the backup stays deleted, with no conflict and no duplicate',
        () async {
      final u = await remote.createUser('r9');
      await Supabase.instance.client.auth
          .signInWithPassword(email: u.email, password: u.password);
      final first = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(first.finish);
      final d1 = Device.wrap(first.database);
      await d1.accounts.create(_account('acc-r9'));
      for (final (id, amt) in [('A', '10'), ('B', '20')]) {
        await d1.transactions.saveTransaction(
            transaction: _txn('r9-$id', amt, 'acc-r9'), categoryKey: null);
      }
      await syncCycle(d1);
      final backup = await takeBackup(d1);
      await d1.transactions.deleteTransaction('r9-B');
      await syncCycle(d1);
      expect(await serverLive(u.uid), {
        'Synthetic shop r9-A': ['10.000'],
      });
      await first.finish(); // the first phone is gone

      final second = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(second.finish);
      final d2 = Device.wrap(second.database);
      await restoreBackup(d2, backup);
      expect(
          await localLive(d2),
          {
            'Synthetic shop r9-A': '10.000',
            'Synthetic shop r9-B': '20.000',
          },
          reason: 'full apply restores the backup as it was');
      d2.consent = true;
      await syncCycle(d2);
      await syncCycle(d2);
      await report('R9 new device after Cloud on + 2 sync cycles', d2, u.uid);
      await expectMergedAndConverged(
          d2, u.uid, {'Synthetic shop r9-A': '10.000'});
      expect(await remote.count('user_transactions', u.uid), 2,
          reason: 'A and the B tombstone; nothing re-inserted');
    });

    test(
        'R9b as R9, but the first ledger pull after Cloud on is interrupted, '
        'so the startup backfill meets the cloud tombstone first', () async {
      final u = await remote.createUser('r9b');
      await Supabase.instance.client.auth
          .signInWithPassword(email: u.email, password: u.password);
      final first = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(first.finish);
      final d1 = Device.wrap(first.database);
      await d1.accounts.create(_account('acc-r9b'));
      for (final (id, amt) in [('A', '10'), ('B', '20')]) {
        await d1.transactions.saveTransaction(
            transaction: _txn('r9b-$id', amt, 'acc-r9b'), categoryKey: null);
      }
      await syncCycle(d1);
      final backup = await takeBackup(d1);
      await d1.transactions.deleteTransaction('r9b-B');
      await syncCycle(d1);
      await first.finish();

      final second = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(second.finish);
      final d2 = Device.wrap(second.database);
      await restoreBackup(d2, backup);
      d2.consent = true;
      // Cycle 1 without its final ledger pull (connection dropped): the
      // account gets bound, the transactions do not.
      await StartupSyncReconcileService(
        db: d2.db,
        getAuthUserId: signedInUid,
        coordinator: _canonical,
        pushCapability: () => ExactTransportCapability.verifiedExact,
        planningCurrencyFor: (_) async =>
            ExactTransportCapability.verifiedExact,
        mayEgress: () async => d2.consent,
      ).run();
      await d2.accountsPush.push();
      await d2.accountsPull.pull();
      await syncCycle(d2);
      await syncCycle(d2);
      await report('R9b after interrupted pull + 2 sync cycles', d2, u.uid);
      await expectMergedAndConverged(
          d2, u.uid, {'Synthetic shop r9b-A': '10.000'});
      expect(await remote.count('user_transactions', u.uid), 2,
          reason: 'A and the B tombstone; nothing re-inserted');
    });

    // Item 3 (account switch / signed out): changes queued for account A on
    // this device are never sent as, or shown under, account B.
    Future<void> pushAll(Device d) async {
      for (final push in [
        d.accountsPush.push,
        d.ledgerPush.push,
        d.planningPush.push,
      ]) {
        try {
          await push();
        } on AccountFenceDeliveryCancellation {
          // The fence stopped delivery: also "nothing sent".
        }
      }
    }

    Future<void> expectNothingUnder(String uid) async {
      for (final t in ['user_accounts', 'user_transactions', 'user_budgets']) {
        expect(await remote.count(t, uid), 0, reason: '$t under $uid');
      }
    }

    test(
        'R7 account switch: A\'s queued changes are never sent as B; '
        'they deliver to A when A is back', () async {
      final a = await remote.createUser('r7a');
      await Supabase.instance.client.auth
          .signInWithPassword(email: a.email, password: a.password);
      final fixture = await LedgerAdmissionFixture.open(a.uid);
      addTearDown(fixture.finish);
      final d = Device.wrap(fixture.database);
      final uidA = a.uid;
      d.ownerUid = () async => uidA; // the local data owner stays A
      await d.accounts.create(_account('acc-r7'));
      await d.transactions.saveTransaction(
          transaction: _txn('r7-A', '10', 'acc-r7'), categoryKey: null);
      expect(await d.ledgerOutboxCount(), 1);

      final b = await remote.createUser('r7b');
      await Supabase.instance.client.auth
          .signInWithPassword(email: b.email, password: b.password);
      await pushAll(d);
      await expectNothingUnder(b.uid);
      await expectNothingUnder(uidA);
      expect(await d.ledgerOutboxCount(), 1, reason: 'A\'s intent is kept');

      await Supabase.instance.client.auth
          .signInWithPassword(email: a.email, password: a.password);
      await syncCycle(d);
      await expectNothingUnder(b.uid);
      expect(await serverLive(uidA), {
        'Synthetic shop r7-A': ['10.000']
      });
    });

    test('R8 signed out: queued changes are not sent', () async {
      final (d, uidA) = await openSignedIn('r8');
      d.ownerUid = () async => uidA;
      await d.accounts.create(_account('acc-r8'));
      await d.transactions.saveTransaction(
          transaction: _txn('r8-A', '10', 'acc-r8'), categoryKey: null);
      await Supabase.instance.client.auth.signOut();
      await pushAll(d);
      await expectNothingUnder(uidA);
      expect(await d.ledgerOutboxCount(), 1, reason: 'the intent is kept');
    });

    // ── Round 4: saved category rules ("Remember for this merchant") ───────
    // The real rule repository, restore use case and MerchantRuleSyncService
    // against the real `user_merchant_rules` table (PostgREST, RLS).
    DriftMerchantCategoryRepository rulesOf(Device d) =>
        DriftMerchantCategoryRepository(d.db, outboxQueue: d.planningQueue);

    Future<void> ruleSync(Device d, {MerchantRuleRemote? remote}) =>
        MerchantRuleSyncService(
          db: d.db,
          queue: d.planningQueue,
          remote: remote,
          getAuthUserId: signedInUid,
          mayEgress: () async => d.consent,
          serverReady: () async => true,
        ).sync();

    Future<Map<String, String>> localRules(Device d) async => {
          for (final r in await rulesOf(d).getUserConfirmedRules())
            AppDatabase.normalizeMerchant(r.rawMerchant): r.categoryKey,
        };

    Future<Map<String, String>> serverRules(String uid,
            {bool deleted = false}) async =>
        {
          for (final r in await remote.rows('user_merchant_rules', uid,
              select: 'merchant_key,category_key,deleted_at'))
            if ((r['deleted_at'] != null) == deleted)
              r['merchant_key'] as String: r['category_key'] as String,
        };

    Future<void> remember(Device d, String merchant, String category) =>
        rulesOf(d).confirmMerchantCategory(
            rawMerchant: merchant,
            categoryKey: category,
            isUserConfirmed: true);

    String k(String merchant) => AppDatabase.normalizeMerchant(merchant);

    test(
        'RR1 rules: backup, then forget one, change one, add one and sync; '
        'restore; Cloud on: device and cloud agree, the removed rule stays '
        'removed, and a second phone gets the same rules', () async {
      final u = await remote.createUser('rr1');
      final uid = u.uid;
      await Supabase.instance.client.auth
          .signInWithPassword(email: u.email, password: u.password);
      final first = await LedgerAdmissionFixture.open(uid);
      addTearDown(first.finish);
      final d = Device.wrap(first.database);
      await d.accounts.create(_account('acc-rr1'));
      await remember(d, 'Synthetic Kept Shop', 'restaurants');
      await remember(d, 'Synthetic Removed Shop', 'restaurants');
      await remember(d, 'Synthetic Edited Shop', 'restaurants');
      await remember(d, 'متجر اصطناعي', 'shopping');
      await ruleSync(d);
      expect(await serverRules(uid), hasLength(4));
      final backup = await takeBackup(d);

      await rulesOf(d).forgetUserConfirmedRule('Synthetic Removed Shop');
      await remember(d, 'Synthetic Edited Shop', 'shopping');
      await remember(d, 'Synthetic Later Shop', 'shopping');
      await ruleSync(d);

      await restoreBackup(d, backup);
      final merged = {
        k('Synthetic Kept Shop'): 'restaurants',
        k('Synthetic Edited Shop'): 'shopping',
        k('Synthetic Later Shop'): 'shopping',
        k('متجر اصطناعي'): 'shopping',
      };
      expect(await localRules(d), merged);
      expect(await MerchantRuleRestore(d.db).pending(), isEmpty);
      d.consent = true;
      await ruleSync(d);
      await ruleSync(d);
      expect(await localRules(d), merged);
      expect(await serverRules(uid), merged);
      expect(await serverRules(uid, deleted: true),
          {k('Synthetic Removed Shop'): 'restaurants'});

      // A second phone of the same user: the removed rule does not come back.
      await first.finish();
      final second = await LedgerAdmissionFixture.open(uid);
      addTearDown(second.finish);
      final d2 = Device.wrap(second.database);
      await ruleSync(d2);
      expect(await localRules(d2), merged);
      await restoreBackup(d2, backup);
      d2.consent = true;
      await ruleSync(d2);
      await ruleSync(d2);
      expect(await localRules(d2), merged,
          reason: 'the pulled removal is on record on the second phone');
      expect(await serverRules(uid), merged);
    });

    test(
        'RR2 rules, new phone (full apply) that has not synced yet: a rule '
        'removed in the cloud after the backup is not pushed back', () async {
      final u = await remote.createUser('rr2');
      await Supabase.instance.client.auth
          .signInWithPassword(email: u.email, password: u.password);
      final first = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(first.finish);
      final d1 = Device.wrap(first.database);
      await d1.accounts.create(_account('acc-rr2'));
      await remember(d1, 'Synthetic Kept Shop', 'restaurants');
      await remember(d1, 'Synthetic Removed Shop', 'shopping');
      await syncCycle(d1);
      await ruleSync(d1);
      final backup = await takeBackup(d1);
      await rulesOf(d1).forgetUserConfirmedRule('Synthetic Removed Shop');
      await ruleSync(d1);
      await first.finish(); // the first phone is gone

      final second = await LedgerAdmissionFixture.open(u.uid);
      addTearDown(second.finish);
      final d2 = Device.wrap(second.database);
      await restoreBackup(d2, backup);
      expect(await localRules(d2), hasLength(2),
          reason: 'full apply restores the backup as it was');
      d2.consent = true;
      await ruleSync(d2);
      await ruleSync(d2);
      final merged = {k('Synthetic Kept Shop'): 'restaurants'};
      expect(await localRules(d2), merged);
      expect(await serverRules(u.uid), merged);
      expect(await serverRules(u.uid, deleted: true),
          {k('Synthetic Removed Shop'): 'shopping'});
      // The same backup again (now a merge): still removed.
      await restoreBackup(d2, backup);
      d2.consent = true;
      await ruleSync(d2);
      expect(await localRules(d2), merged);
      expect(await serverRules(u.uid), merged);
    });

    test(
        'RR3 rules, a backup without deletion history: nothing is added or '
        'dropped silently; "add" reaches the cloud, "leave out" does not',
        () async {
      final (d, uid) = await openSignedIn('rr3');
      await d.accounts.create(_account('acc-rr3'));
      await remember(d, 'Synthetic Wanted Shop', 'restaurants');
      await remember(d, 'Synthetic Unwanted Shop', 'shopping');
      final backup = await takeBackup(d);
      // The backup as a build without deletion history wrote it (format 4).
      backup['version'] = 4;
      backup['schemaVersion'] = 4;
      (backup['tables'] as Map)
          .removeWhere((t, _) => MerchantRuleRestore.historyTables.contains(t));
      // This phone does not hold the rules and has no record of removing them.
      await d.db.customStatement(
          'DELETE FROM merchant_category_map WHERE is_user_confirmed = 1;');
      await d.db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await d.db.customStatement("DELETE FROM planning_sync_outbox "
          "WHERE entity_type = 'merchant_rule';");

      await restoreBackup(d, backup);
      expect(await localRules(d), isEmpty);
      expect(await MerchantRuleRestore(d.db).pending(), hasLength(2));
      d.consent = true;
      await ruleSync(d);
      expect(await serverRules(uid), isEmpty);

      final review = MerchantRuleRestore(d.db);
      await review.decide(k('Synthetic Wanted Shop'),
          add: true, save: (m, c) => remember(d, m, c));
      await review.decide(k('Synthetic Unwanted Shop'),
          add: false, queue: d.planningQueue);
      await ruleSync(d);
      final chosen = {k('Synthetic Wanted Shop'): 'restaurants'};
      expect(await localRules(d), chosen);
      expect(await serverRules(uid), chosen);

      await restoreBackup(d, backup);
      expect(await review.pending(), isEmpty,
          reason: 'decided rules are not asked about again');
      d.consent = true;
      await ruleSync(d);
      expect(await localRules(d), chosen);
      expect(await serverRules(uid), chosen);
    });

    // ── Review fixes (R4R-01, R4R-02, AR-09) on the real table ─────────────
    Future<Map<String, dynamic>> serverRow(String uid, String merchant) async =>
        (await remote.rows('user_merchant_rules', uid,
                filter:
                    'merchant_key=eq.${Uri.encodeQueryComponent(k(merchant))}'))
            .single;

    /// The rule is not on this phone and it has no record of a removal.
    Future<void> absentHere(Device d) async {
      await d.db.customStatement(
          'DELETE FROM merchant_category_map WHERE is_user_confirmed = 1;');
      await d.db.customStatement('DELETE FROM merchant_rule_tombstones;');
      await d.db.customStatement("DELETE FROM planning_sync_outbox "
          "WHERE entity_type = 'merchant_rule';");
    }

    test(
        'RR4 (R4R-01) the pull fails once after a restore: the restored rule '
        'is not pushed over a removal made elsewhere; the retry removes it',
        () async {
      final (d, uid) = await openSignedIn('rr4');
      await d.accounts.create(_account('acc-rr4'));
      await remember(d, 'Synthetic Rule Shop', 'restaurants');
      await ruleSync(d);
      final backup = await takeBackup(d);
      await absentHere(d);
      // Another device removes the rule; this one has not read it.
      final row = await serverRow(uid, 'Synthetic Rule Shop');
      await remote.patch('user_merchant_rules', row['id'] as String,
          {'deleted_at': DateTime.now().toUtc().toIso8601String()});
      final removed = await serverRow(uid, 'Synthetic Rule Shop');

      await restoreBackup(d, backup);
      expect(await localRules(d), hasLength(1));
      d.consent = true;
      await ruleSync(d, remote: _FailingOnce());
      expect(await serverRow(uid, 'Synthetic Rule Shop'), removed,
          reason: 'nothing was pushed while the pull had not completed');

      await ruleSync(d);
      await ruleSync(d);
      expect(await localRules(d), isEmpty);
      expect(await serverRules(uid), isEmpty);
      expect((await serverRow(uid, 'Synthetic Rule Shop'))['deleted_at'],
          isNotNull);
    });

    test(
        'RR5 (R4R-02) "Leave out" while the cloud holds the rule live and '
        'this phone has not read it: removed here and in the cloud, and a '
        'later pull does not bring it back', () async {
      final (d, uid) = await openSignedIn('rr5');
      await d.accounts.create(_account('acc-rr5'));
      await remember(d, 'Synthetic Rule Shop', 'restaurants');
      await ruleSync(d);
      final backup = await takeBackup(d);
      backup['version'] = 4;
      backup['schemaVersion'] = 4;
      (backup['tables'] as Map)
          .removeWhere((t, _) => MerchantRuleRestore.historyTables.contains(t));
      await absentHere(d);
      await d.db.customStatement(
          "DELETE FROM sync_cursors WHERE entity = 'merchant_rules';");

      await restoreBackup(d, backup);
      expect(await MerchantRuleRestore(d.db).pending(), hasLength(1));
      await MerchantRuleRestore(d.db)
          .decide(k('Synthetic Rule Shop'), add: false, queue: d.planningQueue);
      d.consent = true;
      await ruleSync(d);
      await ruleSync(d);
      expect(await localRules(d), isEmpty);
      expect(await serverRules(uid), isEmpty);
      expect(await serverRules(uid, deleted: true), hasLength(1));

      await restoreBackup(d, backup);
      d.consent = true;
      await ruleSync(d);
      expect(await localRules(d), isEmpty);
      expect(await MerchantRuleRestore(d.db).pending(), isEmpty);
      expect(await serverRules(uid), isEmpty);
    });

    test(
        'RR6 (AR-09) a restored newer edit is kept against an older cloud '
        'change this phone had not read, and reaches the cloud', () async {
      final (d, uid) = await openSignedIn('rr6');
      await d.accounts.create(_account('acc-rr6'));
      await remember(d, 'Synthetic Rule Shop', 'restaurants');
      await ruleSync(d);
      final synced = await d.sql('SELECT updated_at FROM merchant_category_map '
          'WHERE is_user_confirmed = 1');
      // Another device changes the category; this phone does not read it.
      final row = await serverRow(uid, 'Synthetic Rule Shop');
      await remote.patch('user_merchant_rules', row['id'] as String,
          {'category_key': 'transport'});
      final changed = DateTime.parse(
          (await serverRow(uid, 'Synthetic Rule Shop'))['updated_at']
              as String);
      // A later edit, made on the phone the backup comes from (one minute
      // after the cloud change, whatever the two clocks say).
      await remember(d, 'Synthetic Rule Shop', 'shopping');
      final backup = await takeBackup(d);
      ((backup['tables'] as Map)['merchant_category_map'] as List)
              .cast<Map<String, dynamic>>()
              .singleWhere((r) => r['is_user_confirmed'] == 1)['updated_at'] =
          changed.add(const Duration(minutes: 1)).toUtc().toIso8601String();
      // This phone is back to what it had synced, with nothing queued.
      await remember(d, 'Synthetic Rule Shop', 'restaurants');
      await d.db.customStatement(
          'UPDATE merchant_category_map SET updated_at = ? '
          'WHERE is_user_confirmed = 1;',
          [synced.single['updated_at']]);
      await d.db.customStatement("DELETE FROM planning_sync_outbox "
          "WHERE entity_type = 'merchant_rule';");

      await restoreBackup(d, backup);
      expect(await localRules(d), {k('Synthetic Rule Shop'): 'shopping'});
      d.consent = true;
      await ruleSync(d);
      await ruleSync(d);
      expect(await localRules(d), {k('Synthetic Rule Shop'): 'shopping'});
      expect(await serverRules(uid), {k('Synthetic Rule Shop'): 'shopping'});
    });
  });
}

/// The real remote, whose first fetch fails (a dropped connection).
class _FailingOnce implements MerchantRuleRemote {
  static const _real = SupabaseMerchantRuleRemote();
  var _failed = false;

  @override
  Future<List<Map<String, dynamic>>> upsert(Map<String, dynamic> row) =>
      _real.upsert(row);

  @override
  Future<List<Map<String, dynamic>>> fetchRows(
      {required SyncCursor after, int limit = 200}) {
    if (!_failed) {
      _failed = true;
      throw StateError('synthetic network failure');
    }
    return _real.fetchRows(after: after, limit: limit);
  }
}
