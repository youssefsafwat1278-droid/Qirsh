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
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/core/sync/pending_sync_reconciler.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
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
    out.putIfAbsent(r['merchant'] as String, () => []).add(
        Money.parse(r['amount_text'] as String, 'KWD').toDecimalString());
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

    test('R1 backup, then edit/delete/add and sync, restore, Cloud on: the '
        'newer edit, the deletion and the new row all survive',
        () async {
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

    test('R3 a row created after the backup and never synced is kept and '
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

    test('R4 a category chosen by hand after the backup keeps the choice and '
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

    test('R6 a row missing on this device returns from the backup and binds to '
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

    test('R9 new device (full apply): a backup row deleted in the cloud after '
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
      expect(await localLive(d2), {
        'Synthetic shop r9-A': '10.000',
        'Synthetic shop r9-B': '20.000',
      }, reason: 'full apply restores the backup as it was');
      d2.consent = true;
      await syncCycle(d2);
      await syncCycle(d2);
      await report('R9 new device after Cloud on + 2 sync cycles', d2, u.uid);
      await expectMergedAndConverged(
          d2, u.uid, {'Synthetic shop r9-A': '10.000'});
      expect(await remote.count('user_transactions', u.uid), 2,
          reason: 'A and the B tombstone; nothing re-inserted');
    });

    test('R9b as R9, but the first ledger pull after Cloud on is interrupted, '
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
        planningCurrencyFor: (_) async => ExactTransportCapability.verifiedExact,
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

    test('R7 account switch: A\'s queued changes are never sent as B; '
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
      expect(await serverLive(uidA), {'Synthetic shop r7-A': ['10.000']});
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
  });
}
