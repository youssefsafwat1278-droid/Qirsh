// V1-020 — restore a backup, then turn Cloud back on, against a REAL local
// Supabase. Skipped unless LOCAL_SUPABASE_URL is set (see local-stack.md in
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
import 'package:money_companion/core/backup/backup_snapshot_builder.dart';
import 'package:money_companion/core/backup/restore_backup_usecase.dart';
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

/// The V1-020 semantics once Cloud is back on and sync has settled:
///  * every RESTORED value is kept on the device and becomes the cloud copy
///    (restored rows win over edits synced after the backup);
///  * no duplicate cloud copies;
///  * PENDING OWNER DECISION (replace vs merge) — cloud rows ABSENT from the
///    backup are kept in the cloud and pulled back to the device (merge, the
///    non-destructive default until the owner decides);
///  * a restored row whose cloud copy is a tombstone ([cloudTombstoned]
///    merchants) is never un-deleted in the cloud: it stays on the device and is
///    surfaced as a sync conflict for the user (keep-mine re-creates it as new).
Future<void> expectRestoredWinAndCloudOnlyRowsMergedBack(
    Device d, String uid, Map<String, String> restored,
    {Set<String> cloudTombstoned = const {}}) async {
  final local = await localLive(d);
  final server = await serverLive(uid);
  for (final e in restored.entries) {
    expect(local[e.key], e.value,
        reason: 'restored ${e.key} must not be overwritten or removed');
  }
  for (final e in server.entries) {
    expect(e.value, hasLength(1), reason: 'duplicate cloud copies of ${e.key}');
  }
  for (final m in cloudTombstoned) {
    expect(server.containsKey(m), isFalse,
        reason: 'a cloud tombstone is never un-deleted by a restore');
    final status = await d.sql('SELECT sync_status s FROM transactions '
        "WHERE raw_merchant = '$m'");
    expect(status.single['s'], 'conflict',
        reason: '$m must be surfaced as a conflict, not silently diverge');
  }
  expect({for (final e in server.entries) e.key: e.value.first},
      {...local}..removeWhere((k, _) => cloudTombstoned.contains(k)),
      reason: 'device and cloud must agree, and cloud rows absent from the '
          'backup must be merged back (pending decision: merge)');
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

    test('R1 backup, then edit/delete/add and sync, restore, Cloud on',
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
      final restored = await localLive(d);
      expect(restored, {
        'Synthetic shop r1-A': '10.000',
        'Synthetic shop r1-B': '20.000',
        'Synthetic shop r1-C': '30.000',
      });
      await report('R1 after restore, Cloud off', d, uid);

      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await report('R1 after Cloud on + 2 sync cycles', d, uid);
      await expectRestoredWinAndCloudOnlyRowsMergedBack(d, uid, restored,
          cloudTombstoned: {'Synthetic shop r1-C'});
      expect((await localLive(d))['Synthetic shop r1-D'], '40.000',
          reason: 'D is absent from the backup: kept and merged back');
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
      final restored = await localLive(d);
      expect(restored, {'Synthetic shop r2-A': '10.000'});
      await report('R2 after restore, Cloud off', d, uid);

      d.consent = true;
      await syncCycle(d);
      await syncCycle(d);
      await report('R2 after Cloud on + 2 sync cycles', d, uid);
      await expectRestoredWinAndCloudOnlyRowsMergedBack(d, uid, restored);
      expect((await localLive(d))['Synthetic shop r2-E'], '50.000',
          reason: 'E is absent from the backup: kept and merged back');
    });
  });
}
