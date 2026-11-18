// END-TO-END sync proof against a REAL local Supabase (A-P).
//
// Skipped unless LOCAL_SUPABASE_URL is set, so CI and the plain `flutter test`
// run are unaffected. See dart_test.yaml (`local-supabase` tag) and the runner
// command in the A-P report. Never run against a remote project: the support
// layer refuses any non-loopback URL and keys come only from the environment.
@Tags(['local-supabase'])
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:money_companion/core/sync/conflict_policy.dart';
import 'package:money_companion/core/sync/conflict_resolver.dart';
import 'package:money_companion/core/sync/outbox_failure.dart';
import 'package:money_companion/features/capture/services/ledger_outbox_queue.dart';
import 'package:money_companion/core/di/app_providers.dart'
    show
        appDatabaseProvider,
        planningCurrencyCapabilityProbeProvider,
        userSettingsRepositoryProvider;
import 'package:money_companion/core/sync/sync_health.dart';
import 'package:money_companion/data/db/planning_cutover.dart';
import 'package:money_companion/data/sync/exact_transport_capability.dart';
import 'package:money_companion/data/sync/planning_currency_capability_probe.dart';
import 'package:money_companion/data/sync/server_capabilities.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart'
    show ConsentState;
import 'package:money_companion/features/planning_sync/services/planning_push_service.dart';
import 'package:money_companion/domain/entities/account_entity.dart';
import 'package:money_companion/domain/entities/budget_entity.dart';
import 'package:money_companion/domain/entities/goal_entity.dart';
import 'package:money_companion/domain/entities/plan_entity.dart';
import 'package:money_companion/domain/entities/bill_entity.dart';
import 'package:money_companion/domain/repositories/sender_bank_mapping_repository.dart';
import 'package:money_companion/domain/entities/transaction_entity.dart';
import 'package:money_companion/domain/finance/money.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'local_device.dart';
import 'local_supabase_support.dart';

late LocalEnv env;
late RemoteTruth remote;
late ProbeClient probe;

/// Numeric text equality ignoring trailing fractional zeros ('12.3450' == '12.345').
String dec(Object? v) {
  var s = '$v';
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
  }
  return s;
}

typedef TestUser = ({String uid, String email, String password});

Future<TestUser> newUser(String label) => remote.createUser(label);

/// [Device.open] admits the database through the real session sign-in, which
/// records onboarding completion (`mark_onboarding_completed`). That request is
/// device admission, not sync traffic, so it is removed from the probe's count;
/// every other request stays counted.
Future<Device> openDevice() async {
  final before = probe.log.length;
  final d = await Device.open();
  final added = probe.log.sublist(before);
  probe.log.removeRange(before, probe.log.length);
  probe.log.addAll(
      added.where((e) => e != 'POST /rest/v1/rpc/mark_onboarding_completed'));
  return d;
}

Future<void> signIn(TestUser u) async {
  final auth = Supabase.instance.client.auth;
  if (auth.currentSession != null) await auth.signOut();
  await auth.signInWithPassword(email: u.email, password: u.password);
  probe
    ..offline = false
    ..bearerOverride = null
    ..failWhen = null
    ..lostResponseWhen = null
    ..resetCount();
}

AccountEntity acct(
  String id, {
  String name = 'Proof account',
  String currency = 'KWD',
  String initial = '1000.125',
  bool isDefault = false,
}) {
  final now = DateTime.utc(2026, 7, 4, 12);
  final m = Money.parse(initial, currency);
  return AccountEntity(
    id: id,
    name: name,
    currency: currency,
    type: AccountType.bank,
    isDefault: isDefault,
    sortOrder: 1,
    createdAt: now,
    updatedAt: now,
    initialBalanceMoney: m,
    currentBalanceMoney: m,
  );
}

TransactionEntity txn(
  String id,
  String amount,
  String currency, {
  String? accountId,
  String? merchant,
  Money? foreign,
  String? foreignCurrency,
  TransactionTypeEntity type = TransactionTypeEntity.payment,
}) {
  final now = DateTime.utc(2026, 7, 5, 9);
  return TransactionEntity(
    id: id,
    amountMoney: Money.parse(amount, currency),
    currency: currency,
    type: type,
    source: TransactionSourceEntity.unknown,
    occurredAt: now,
    rawMessage: 'manual',
    parseConfidence: 1,
    status: TransactionStatus.confirmed,
    createdAt: now,
    updatedAt: now,
    accountId: accountId,
    rawMerchant: merchant,
    foreignMoney: foreign,
    foreignCurrency: foreignCurrency,
  );
}


/// A pulled row gets a NEW local id on the other device; find it through the
/// server id of the row identified by its original client_request_id.
Future<String> lid(Device d, String uid, String crid) async {
  final sid = (await remote.rows('user_transactions', uid,
          select: 'id', filter: 'client_request_id=eq.$crid'))
      .single['id'];
  return (await d.sql("SELECT id FROM transactions WHERE server_id='$sid'"))
      .single['id'] as String;
}

/// The same wiring app_providers.dart uses for keep-remote.
Map<String, ConflictRemoteSync> remoteSyncFor(Device d) => {
      ConflictEntities.transaction: ConflictRemoteSync(
          fetch: d.ledgerPull.fetchServerRow, apply: d.ledgerPull.applyServerRow),
      ConflictEntities.account: ConflictRemoteSync(
          fetch: d.accountsPull.fetchServerRow,
          apply: d.accountsPull.applyServerRow),
      for (final e in const {
        ConflictEntities.budget,
        ConflictEntities.goal,
        ConflictEntities.subscription,
        ConflictEntities.plan,
      })
        e: ConflictRemoteSync(
            fetch: (id) => d.planningPull.fetchServerRow(e, id),
            apply: (row) => d.planningPull.applyServerRow(e, row)),
    };

Future<List<Map<String, Object?>>> snapshot(Device d, String table) =>
    d.sql('SELECT * FROM $table');

/// Puts [rows] back exactly as they were (used to model a LOST RESPONSE: the
/// server committed, the device never saw the ack, so its outbox row survives).
Future<void> restore(
    Device d, String table, List<Map<String, Object?>> rows) async {
  for (final r in rows) {
    final cols = r.keys.toList();
    await d.db.customStatement(
      'INSERT OR REPLACE INTO $table(${cols.join(',')}) '
      'VALUES (${cols.map((_) => '?').join(',')})',
      cols.map((c) => r[c]).toList(),
    );
  }
}

Future<void> forgetAck(Device d, String table, String id) => d.db.customStatement(
    "UPDATE $table SET server_id = NULL, server_updated_at = NULL, "
    "synced_at = NULL, sync_status = 'pending' WHERE id = '$id'");

/// Every outbound call the app made that was a write to [table] (excludes the
/// service-role ground-truth reads, which bypass the probe).
int writesTo(String table) => probe.countWhere((e) =>
    (e.startsWith('POST ') || e.startsWith('PATCH ')) &&
    e.contains('/rest/v1/$table'));

BudgetEntity budget(String id, String amount, {String currency = 'KWD'}) =>
    BudgetEntity(
      id: id,
      categoryId: BudgetEntity.allExpensesCategoryId,
      currency: currency,
      amountMoney: Money.parse(amount, currency),
      lastNotifiedSpentMoney: Money.parse('0', currency),
      period: BudgetPeriod.monthly,
      startDate: DateTime.utc(2026, 7, 1),
      isActive: true,
      lastNotifiedPeriodStart: DateTime.utc(2026, 7, 1),
    );

GoalEntity goal(String id, String target, {String currency = 'KWD'}) =>
    GoalEntity(
      id: id,
      name: 'Goal $id',
      currency: currency,
      targetMoney: Money.parse(target, currency),
      savedMoney: Money.parse('0', currency),
      lastNotifiedSavedMoney: Money.parse('0', currency),
      vaultSkin: 'default',
      status: 'active',
      createdAt: DateTime.utc(2026, 7, 1),
    );

PlanEntity plan(String id, String budget, {String currency = 'KWD'}) =>
    PlanEntity(
      id: id,
      name: 'Plan $id',
      budgetAmountMoney: Money.parse(budget, currency),
      currency: currency,
      startDate: DateTime.utc(2026, 7, 1),
      endDate: DateTime.utc(2026, 7, 31),
      accountIds: const [],
      cardLast4s: const [],
      status: PlanStatus.active,
      createdAt: DateTime.utc(2026, 7, 1),
    );

BillEntity bill(String id, String amount, {String currency = 'KWD'}) =>
    BillEntity(
      id: id,
      name: 'Bill $id',
      amountMoney: Money.parse(amount, currency),
      currency: currency,
      type: BillType.subscription,
      frequency: BillFrequency.monthly,
      nextDueDate: DateTime.utc(2026, 8, 1),
      reminderOn: true,
      isConfirmed: true,
      createdAt: DateTime.utc(2026, 7, 1),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A-P local-Supabase end-to-end sync proof',
      skip: LocalEnv.enabled ? false : 'LOCAL_SUPABASE_URL not set', () {
    setUpAll(() async {
      // The test binding replaces dart:io HTTP with a stub that answers 400.
      // This suite deliberately talks to the loopback stack, so undo that.
      HttpOverrides.global = null;
      env = LocalEnv.load();
      remote = RemoteTruth(env);
      probe = ProbeClient(http.Client());
      SharedPreferences.setMockInitialValues({});
      final msg =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      msg.setMockMethodCallHandler(
          const MethodChannel('com.llfbandit.app_links/messages'),
          (c) async => null);
      msg.setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (c) async => null);
      await Supabase.initialize(
        url: env.url,
        anonKey: env.anonKey,
        authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
        httpClient: probe,
      );
    });

    tearDownAll(() async {
      final left = await remote.cleanup();
      // ignore: avoid_print
      print('CLEANUP: ${remote.createdUserIds.length} test users removed, '
          '$left user-owned rows left behind');
      remote.close();
      expect(left, 0);
    });

    test('S1 account create -> outbox -> push -> remote exact -> ACK', () async {
      final u = await newUser('s1');
      await signIn(u);
      final dev = await openDevice();
      addTearDown(dev.close);

      await dev.accounts
          .create(acct('acc-s1', initial: '1000.125', isDefault: true));

      // Local intent is durable BEFORE any network.
      expect(await dev.planningOutboxCount("entity_type = 'account'"), 1);
      expect(await dev.planningOutboxCount("entity_type = 'account_default_command'"), 1);
      expect((await dev.sql("SELECT sync_status s FROM accounts WHERE id='acc-s1'")).single['s'], 'pending');
      expect(probe.requests, 0, reason: 'no network before push');

      final res = await dev.accountsPush.push();
      expect(res.pushed, 2);
      expect(res.failed, 0);

      final rows = await remote.rows('user_accounts', u.uid,
          select: 'id,local_id,name,currency,is_default,'
              'initial_balance_text:initial_balance::text,'
              'current_balance_text:current_balance::text');
      expect(rows, hasLength(1));
      expect(rows.single['local_id'], 'acc-s1');
      expect(rows.single['currency'], 'KWD');
      expect(dec(rows.single['initial_balance_text']), '1000.125');
      expect(dec(rows.single['current_balance_text']), '1000.125');
      expect(rows.single['is_default'], true);

      // ACK truth: outbox empty, local synced, server id attached.
      expect(await dev.planningOutboxCount(), 0);
      final local = (await dev.sql(
              "SELECT sync_status s, server_id sid FROM accounts WHERE id='acc-s1'"))
          .single;
      expect(local['s'], 'synced');
      expect(local['sid'], rows.single['id']);
    });

    test('S2 transactions: exact money to server, exact on a SECOND device',
        () async {
      final u = await newUser('s2');
      await signIn(u);
      final d1 = await openDevice();
      addTearDown(d1.close);

      await d1.accounts.create(acct('acc-s2', isDefault: true));
      await d1.accountsPush.push();

      final money = {
        't-kwd-1': ('12.345', 'KWD'),
        't-kwd-2': ('0.001', 'KWD'),
        't-kwd-3': ('99999.999', 'KWD'),
        't-sar-1': ('1234.56', 'SAR'),
      };
      for (final e in money.entries) {
        await d1.transactions.saveTransaction(
          transaction: txn(e.key, e.value.$1, e.value.$2,
              accountId: 'acc-s2', merchant: 'Shop ${e.key}'),
          categoryKey: null,
        );
      }
      expect(await d1.ledgerOutboxCount(), 4);

      final push = await d1.ledgerPush.push();
      expect(push.pushed, 4);
      expect(push.failed, 0);
      expect(push.parked, 0);

      final remoteRows = await remote.rows('user_transactions', u.uid,
          select: 'client_request_id,currency,amount_text:amount::text,'
              'server_account_id,local_account_id');
      expect(remoteRows, hasLength(4));
      for (final r in remoteRows) {
        final want = money[r['client_request_id']]!;
        expect(dec(r['amount_text']), want.$1, reason: '${r['client_request_id']}');
        expect(r['currency'], want.$2);
      }
      final acc = await remote.rows('user_accounts', u.uid, select: 'id');
      expect(remoteRows.every((r) => r['server_account_id'] == acc.single['id']),
          true, reason: 'transactions are bound to the synced server account');
      expect(await d1.ledgerOutboxCount(), 0);
      expect(
          (await d1.sql("SELECT COUNT(*) n FROM transactions WHERE sync_status='synced'"))
              .single['n'],
          4);

      // ---- ANOTHER DEVICE: same user, fresh empty local DB ----
      final d2 = await openDevice();
      addTearDown(d2.close);
      final ap = await d2.accountsPull.pull();
      expect(ap.status.name, 'completed');
      final lp = await d2.ledgerPull.pull();
      expect(lp.status.name, 'completed');
      expect(lp.imported, 4);

      for (final e in money.entries) {
        final t = await d2.transactions.getById(await lid(d2, u.uid, e.key));
        expect(t, isNotNull, reason: 'device 2 has ${e.key}');
        expect(t!.amountMoney, Money.parse(e.value.$1, e.value.$2),
            reason: 'exact minor units for ${e.key}');
        expect(t.currency, e.value.$2);
      }
      expect(
          (await d2.sql("SELECT amount_minor m FROM transactions WHERE id='${await lid(d2, u.uid, 't-kwd-1')}'"))
              .single['m'],
          12345);
      expect(
          (await d2.sql("SELECT amount_minor m FROM transactions WHERE id='${await lid(d2, u.uid, 't-kwd-2')}'"))
              .single['m'],
          1);
      expect(
          (await d2.sql("SELECT amount_minor m FROM transactions WHERE id='${await lid(d2, u.uid, 't-kwd-3')}'"))
              .single['m'],
          99999999);
    });

    test('S3 budgets/goals/plans/subscriptions: insert path + replay once',
        () async {
      final u = await newUser('s3');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);

      await d.budgets.save(budget('bud-s3', '250.500'));
      await d.goals.save(goal('goal-s3', '1500.125'));
      await d.plans.save(plan('plan-s3', '77.777'));
      await d.bills.save(bill('bill-s3', '9.999'));
      expect(await d.planningOutboxCount(), 4);

      // Snapshot the outbox as it is BEFORE the push: a lost response leaves it so.
      final before = await snapshot(d, 'planning_sync_outbox');
      final r1 = await d.planningPush.push();
      expect(r1.pushed, 4);
      expect(r1.failed, 0);
      expect(r1.parked, 0);

      Future<void> expectOneEach() async {
        expect(await remote.count('user_budgets', u.uid), 1);
        expect(await remote.count('user_goals', u.uid), 1);
        expect(await remote.count('user_plans', u.uid), 1);
        expect(await remote.count('user_subscriptions', u.uid), 1);
      }

      await expectOneEach();
      final b = (await remote.rows('user_budgets', u.uid,
              select: 'local_id,currency,amount_text:amount::text'))
          .single;
      expect(b['local_id'], 'bud-s3');
      expect(b['currency'], 'KWD');
      expect(dec(b['amount_text']), '250.5');
      expect(
          dec((await remote.rows('user_goals', u.uid,
                  select: 't:target_amount::text'))
              .single['t']),
          '1500.125');
      expect(
          dec((await remote.rows('user_plans', u.uid,
                  select: 'b:budget_amount::text'))
              .single['b']),
          '77.777');
      expect(
          dec((await remote.rows('user_subscriptions', u.uid,
                  select: 'a:amount::text'))
              .single['a']),
          '9.999');
      expect(await d.planningOutboxCount(), 0);

      // ---- lost response: server has it, device never saw the ack ----
      for (final x in [
        ('budgets', 'bud-s3'),
        ('goals', 'goal-s3'),
        ('plans', 'plan-s3'),
        ('subscriptions', 'bill-s3'),
      ]) {
        await forgetAck(d, x.$1, x.$2);
      }
      await restore(d, 'planning_sync_outbox', before);
      expect(await d.planningOutboxCount(), 4);
      probe.resetCount();
      final r2 = await d.planningPush.push();
      expect(r2.pushed, 4, reason: 'replay resolves to an update of the same row');
      expect(r2.failed, 0);
      expect(writesTo('user_budgets') + writesTo('user_goals') + writesTo('user_plans') + writesTo('user_subscriptions'),
          greaterThanOrEqualTo(4),
          reason: 'the replay really went back to the server');
      await expectOneEach();
      expect(await d.planningOutboxCount(), 0);
    });

    test('S3b goal contribution via the child RPC is exactly-once', () async {
      final u = await newUser('s3b');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.goals.save(goal('goal-s3b', '500'));
      await d.planningPush.push();
      await d.goals.addContribution(GoalContributionEntity(
        id: 'gc-s3b',
        goalId: 'goal-s3b',
        amountMoney: Money.parse('10.125', 'KWD'),
        createdAt: DateTime.utc(2026, 7, 6),
      ));
      final before = await snapshot(d, 'planning_sync_outbox');
      await d.childSync.sync();
      expect(await remote.count('user_goal_contributions', u.uid), 1);
      expect(
          dec((await remote.rows('user_goal_contributions', u.uid,
                  select: 'a:amount::text'))
              .single['a']),
          '10.125');
      // lost ack -> replay
      await d.db.customStatement(
          "UPDATE goal_contributions SET server_id=NULL WHERE id='gc-s3b'");
      await restore(d, 'planning_sync_outbox', before);
      await d.childSync.sync();
      expect(await remote.count('user_goal_contributions', u.uid), 1,
          reason: 'replay is idempotent on (user_id, local_id)');
      expect(
          dec((await remote.rows('user_goals', u.uid, select: 's:saved_amount::text'))
              .single['s']),
          '10.125',
          reason: 'saved total is not double-counted by the replay');
    });

    test('S4 duplicate retry (lost ack) for ledger and accounts -> one row',
        () async {
      final u = await newUser('s4');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);

      await d.accounts.create(acct('acc-s4', isDefault: true));
      await d.transactions.saveTransaction(
        transaction: txn('tx-s4', '5.250', 'KWD', accountId: 'acc-s4'),
        categoryKey: null,
      );
      final accOutbox = await snapshot(d, 'planning_sync_outbox');
      final txOutbox = await snapshot(d, 'ledger_sync_outbox');

      expect((await d.accountsPush.push()).pushed, 2);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect(await remote.count('user_accounts', u.uid), 1);
      expect(await remote.count('user_transactions', u.uid), 1);

      // Same pushes again, exactly as a retry after a lost response would.
      await forgetAck(d, 'accounts', 'acc-s4');
      await forgetAck(d, 'transactions', 'tx-s4');
      await restore(d, 'planning_sync_outbox', accOutbox);
      await restore(d, 'ledger_sync_outbox', txOutbox);
      final a2 = await d.accountsPush.push();
      final l2 = await d.ledgerPush.push();
      expect(a2.failed, 0);
      expect(l2.failed, 0);
      expect(await remote.count('user_accounts', u.uid), 1);
      expect(await remote.count('user_transactions', u.uid), 1);
      final tx = (await remote.rows('user_transactions', u.uid,
              select: 'a:amount::text'))
          .single;
      expect(dec(tx['a']), '5.25');
      expect(await d.ledgerOutboxCount(), 0);
      expect(await d.planningOutboxCount(), 0);
    });

    test('S5 offline: transient failure keeps rows pending with back-off, '
        'then online -> synced', () async {
      final u = await newUser('s5');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.accounts.create(acct('acc-s5', isDefault: true));
      await d.transactions.saveTransaction(
        transaction: txn('tx-s5', '3.500', 'KWD', accountId: 'acc-s5'),
        categoryKey: null,
      );

      probe.offline = true; // real connection-refused on a dead port
      probe.resetCount();
      final a = await d.accountsPush.push();
      final l = await d.ledgerPush.push();
      expect(a.pushed, 0);
      expect(a.failed, greaterThan(0));
      expect(l.pushed, 0);
      expect(l.failed, 1);

      final lo = await d.ledgerOutboxRow('tx-s5');
      expect(lo['status'], 'pending');
      expect(lo['attempt_count'], 1);
      expect(lo['failure_class'], 'transientNetwork');
      expect(lo['next_retry_at'], isNotNull, reason: 'back-off scheduled');
      final po = await d.sql(
          "SELECT status, attempt_count, failure_class, next_retry_at "
          "FROM planning_sync_outbox WHERE entity_type='account'");
      expect(po.single['status'], 'pending');
      expect(po.single['attempt_count'], 1);
      expect(po.single['failure_class'], 'transientNetwork');
      expect(await remote.count('user_accounts', u.uid), 0);
      expect(await remote.count('user_transactions', u.uid), 0);

      // Back-off is honoured: an immediate retry sends nothing.
      final reqs = probe.requests;
      await d.accountsPush.push();
      await d.ledgerPush.push();
      expect(probe.requests, reqs, reason: 'no request inside the back-off window');
      expect((await d.ledgerOutboxRow('tx-s5'))['attempt_count'], 1);

      // Back online (and the back-off window has elapsed).
      probe.offline = false;
      await d.elapseBackoff();
      expect((await d.accountsPush.push()).pushed, 2);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect(await remote.count('user_accounts', u.uid), 1);
      expect(await remote.count('user_transactions', u.uid), 1);
      expect(await d.ledgerOutboxCount(), 0);
      expect(await d.planningOutboxCount(), 0);
      expect(
          (await d.sql("SELECT sync_status s FROM transactions WHERE id='tx-s5'"))
              .single['s'],
          'synced');
    });

    test('S6 consent OFF: zero HTTP, rows untouched; ON -> processed',
        () async {
      final u = await newUser('s6');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.accounts.create(acct('acc-s6', isDefault: true));
      await d.transactions.saveTransaction(
        transaction: txn('tx-s6', '8.125', 'KWD', accountId: 'acc-s6'),
        categoryKey: null,
      );
      await d.budgets.save(budget('bud-s6', '40'));
      await d.senderMappings.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'PROOFBANK',
        suggestedBankName: 'Proof Bank',
        suggestedCountry: 'KW',
        confidence: 0.9,
        bankKey: 'proof_bank',
      ));
      final m = await d.senderMappings.getBySender('PROOFBANK');
      await d.senderMappings.confirm(mappingId: m!.id, bankKey: 'proof_bank');

      Future<String> state() async {
        final l = await d.sql('SELECT status, attempt_count a, next_retry_at n FROM ledger_sync_outbox');
        final p = await d.sql('SELECT status, attempt_count a, next_retry_at n FROM planning_sync_outbox');
        final s = await d.sql('SELECT sync_status, sync_attempt_count FROM sender_bank_mappings');
        return '$l|$p|$s';
      }

      final before = await state();
      d.consent = false;
      probe.resetCount();
      await d.accountsPush.push();
      await d.ledgerPush.push();
      await d.planningPush.push();
      await d.childSync.sync();
      await d.senderSync.sync();
      await d.accountsPull.pull();
      await d.ledgerPull.pull();
      await d.planningPull.pull();
      await d.capabilities.awaitingFxTransactions(force: true);
      expect(probe.requests, 0,
          reason: 'consent off => no HTTP at all. log=${probe.log}');
      expect(await state(), before,
          reason: 'rows and attempt_count are untouched');
      expect(await remote.count('user_accounts', u.uid), 0);
      expect(await remote.count('user_transactions', u.uid), 0);
      expect(await remote.count('user_budgets', u.uid), 0);
      expect(await remote.count('sender_bank_mappings', u.uid), 0);

      d.consent = true;
      expect((await d.accountsPush.push()).pushed, 2);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect((await d.planningPush.push()).pushed, 1);
      expect((await d.senderSync.sync()).pushed, 1);
      expect(probe.requests, greaterThan(0));
      expect(await remote.count('user_accounts', u.uid), 1);
      expect(await remote.count('user_transactions', u.uid), 1);
      expect(await remote.count('user_budgets', u.uid), 1);
      expect(await remote.count('sender_bank_mappings', u.uid), 1);
    });

    test('S7 delete: tombstone reaches server; failure keeps row pending '
        'until ACK; lost ack converges', () async {
      final u = await newUser('s7');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.accounts.create(acct('acc-s7', isDefault: true));
      await d.accounts.create(acct('acc-s7-del', name: 'To delete'));
      for (final id in ['tx-del-1', 'tx-del-2', 'tx-del-3', 'tx-keep']) {
        await d.transactions.saveTransaction(
          transaction: txn(id, '4.321', 'KWD', accountId: 'acc-s7'),
          categoryKey: null,
        );
      }
      await d.accountsPush.push();
      await d.ledgerPush.push();
      expect(await remote.count('user_transactions', u.uid), 4);

      Future<dynamic> deletedAt(String crid) async => (await remote.rows(
              'user_transactions', u.uid,
              select: 'deleted_at', filter: 'client_request_id=eq.$crid'))
          .single['deleted_at'];

      // 1) plain delete -> tombstone
      await d.transactions.deleteTransaction('tx-del-1');
      expect(await d.ledgerOutboxCount("operation='delete'"), 1);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect(await deletedAt('tx-del-1'), isNotNull);
      expect(await deletedAt('tx-keep'), isNull);
      expect(await remote.count('user_transactions', u.uid), 4,
          reason: 'soft delete: the row stays, deleted_at is set');
      expect(await d.ledgerOutboxCount(), 0);
      expect(
          (await d.sql("SELECT sync_status s FROM transactions WHERE id='tx-del-1'"))
              .single['s'],
          'synced');

      // 2) failure DURING the delete push (request never leaves)
      await d.transactions.deleteTransaction('tx-del-2');
      probe.failWhen = (r) =>
          r.method == 'PATCH' && r.url.path.contains('user_transactions');
      final f = await d.ledgerPush.push();
      expect(f.failed, 1);
      expect(f.pushed, 0);
      var row = await d.ledgerOutboxRow('tx-del-2');
      expect(row['status'], 'pending');
      expect(row['attempt_count'], 1);
      expect(await deletedAt('tx-del-2'), isNull, reason: 'server not touched');
      expect(
          (await d.sql("SELECT sync_status s FROM transactions WHERE id='tx-del-2'"))
              .single['s'],
          'pending',
          reason: 'local is NOT marked synced before the ACK');
      probe.failWhen = null;
      await d.elapseBackoff();
      expect((await d.ledgerPush.push()).pushed, 1);
      expect(await deletedAt('tx-del-2'), isNotNull);
      expect(await d.ledgerOutboxCount(), 0);

      // 3) LOST ACK: the server applied the tombstone, the device saw an error.
      await d.transactions.deleteTransaction('tx-del-3');
      probe.lostResponseWhen = (r) =>
          r.method == 'PATCH' && r.url.path.contains('user_transactions');
      final lost = await d.ledgerPush.push();
      expect(lost.failed, 1);
      expect(await deletedAt('tx-del-3'), isNotNull, reason: 'server committed');
      row = await d.ledgerOutboxRow('tx-del-3');
      expect(row['status'], 'pending', reason: 'no ACK seen -> still pending');
      probe.lostResponseWhen = null;
      await d.elapseBackoff();
      final conv = await d.ledgerPush.push();
      expect(conv.failed, 0);
      expect(await d.ledgerOutboxCount(), 0, reason: 'retry converged and ACKed');
      expect(await remote.count('user_transactions', u.uid), 4);

      // 4) account delete -> tombstone
      await d.accounts.delete('acc-s7-del');
      expect(await d.planningOutboxCount("operation='delete'"), 1);
      expect((await d.accountsPush.push()).pushed, 1);
      final accRows = await remote.rows('user_accounts', u.uid,
          select: 'local_id,deleted_at');
      expect(accRows.firstWhere((r) => r['local_id'] == 'acc-s7-del')['deleted_at'],
          isNotNull);
      expect(accRows.firstWhere((r) => r['local_id'] == 'acc-s7')['deleted_at'],
          isNull);
      expect(await d.planningOutboxCount(), 0);
    });

    test('S8 stale owner: foreign-owner rows are parked, never sent',
        () async {
      final a = await newUser('s8a');
      final b = await newUser('s8b');
      await signIn(a);
      final d = await openDevice();
      addTearDown(d.close);

      await d.accounts.create(acct('acc-a1', isDefault: true));
      await d.accountsPush.push();
      expect(await remote.count('user_accounts', a.uid), 1);

      // More A-owned work, NOT yet pushed.
      await d.accounts.create(acct('acc-a2', name: 'A second'));
      await d.transactions.saveTransaction(
        transaction: txn('tx-a1', '2.002', 'KWD', accountId: 'acc-a1'),
        categoryKey: null,
      );
      await d.budgets.save(budget('bud-a1', '10'));
      expect(
          (await d.sql("SELECT DISTINCT owner_uid o FROM ledger_sync_outbox"))
              .single['o'],
          a.uid);

      // Account switch: B signs in on the same local DB (owner accessor = uid).
      await signIn(b);
      final r1 = await d.accountsPush.push();
      final r2 = await d.ledgerPush.push();
      final r3 = await d.planningPush.push();
      expect(r1.pushed + r2.pushed + r3.pushed, 0);
      expect(
          writesTo('user_accounts') +
              writesTo('user_transactions') +
              writesTo('user_budgets'),
          0,
          reason: 'nothing was sent as B');
      for (final t in [
        'user_accounts',
        'user_transactions',
        'user_budgets',
        'user_goals'
      ]) {
        expect(await remote.count(t, b.uid), 0, reason: 'B has no $t');
      }
      expect(await remote.count('user_accounts', a.uid), 1,
          reason: "A's remote is unchanged");
      expect(await remote.count('user_transactions', a.uid), 0);
      expect(await remote.count('user_budgets', a.uid), 0);

      final parked = await d.sql(
          "SELECT status, failure_class, owner_uid FROM ledger_sync_outbox");
      expect(parked.single['status'], 'parked');
      expect(parked.single['failure_class'], 'owner_mismatch');
      expect(parked.single['owner_uid'], a.uid);
      final pp = await d.sql(
          "SELECT status, failure_class FROM planning_sync_outbox");
      expect(pp.every((r) => r['status'] == 'parked' && r['failure_class'] == 'owner_mismatch'),
          true,
          reason: 'accounts + budget rows parked: $pp');
      // Data is not lost: parked rows are retained.
      expect(await d.planningOutboxCount(), greaterThanOrEqualTo(2));

      // The rightful owner signs back in: the same durable rows drain.
      await signIn(a);
      expect((await d.accountsPush.push()).failed, 0);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect((await d.planningPush.push()).pushed, 1);
      expect(await remote.count('user_accounts', a.uid), 2);
      expect(await remote.count('user_transactions', a.uid), 1);
      expect(await remote.count('user_budgets', a.uid), 1);
      expect(await remote.count('user_accounts', b.uid), 0);
    });

    test('S9 pull conflict: pending local edit is never overwritten; '
        'documented interactive resolution is deterministic', () async {
      final u = await newUser('s9');
      await signIn(u);
      final d1 = await openDevice();
      final d2 = await openDevice();
      addTearDown(d1.close);
      addTearDown(d2.close);

      await d1.accounts.create(acct('acc-s9', isDefault: true));
      await d1.accountsPush.push();
      for (final id in ['tx-a', 'tx-b', 'tx-c']) {
        await d1.transactions.saveTransaction(
          transaction: txn(id, '10.000', 'KWD', accountId: 'acc-s9'),
          categoryKey: null,
        );
      }
      await d1.ledgerPush.push();
      await d2.accountsPull.pull();
      await d2.ledgerPull.pull();
      expect((await d2.transactions.getById(await lid(d2, u.uid, 'tx-a')))?.amountMoney,
          Money.parse('10.000', 'KWD'));

      Future<void> edit(Device d, String id, String amount) =>
          d.transactions.updateTransaction(
            transactionId: id,
            amount: Money.parse(amount, 'KWD'),
            currency: 'KWD',
            type: TransactionTypeEntity.payment,
            occurredAt: DateTime.utc(2026, 7, 5, 9),
            rawMerchant: null,
            categoryId: null,
            note: null,
          );
      Future<String> remoteAmt(String id) async => dec((await remote.rows(
              'user_transactions', u.uid,
              select: 'a:amount::text', filter: 'client_request_id=eq.$id'))
          .single['a']);
      Future<Money> localAmt(Device d, String id) async =>
          (await d.transactions.getById(id))!.amountMoney;
      Future<String?> localSync(Device d, String id) async => (await d.sql(
              "SELECT sync_status s FROM transactions WHERE id='$id'"))
          .single['s'] as String?;

      // Device 2 edits a and c and pushes.
      await edit(d2, await lid(d2, u.uid, 'tx-a'), '20.000');
      await edit(d2, await lid(d2, u.uid, 'tx-c'), '22.000');
      expect((await d2.ledgerPush.push()).pushed, 2);
      expect(await remoteAmt('tx-a'), '20');
      expect(await remoteAmt('tx-c'), '22');

      // Device 1 has pending local edits of a, b, c (b was NOT edited remotely).
      await edit(d1, 'tx-a', '30.500');
      await edit(d1, 'tx-b', '31.500');
      await edit(d1, 'tx-c', '32.500');

      // (i) pull-first for a: no overwrite, conflict surfaced, edit kept.
      final pull1 = await d1.ledgerPull.pull();
      expect(pull1.conflicts, greaterThanOrEqualTo(1));
      expect(await localAmt(d1, 'tx-a'), Money.parse('30.500', 'KWD'),
          reason: 'pending local edit NOT overwritten by pull');
      expect(await localAmt(d1, 'tx-c'), Money.parse('32.500', 'KWD'));
      expect(await localSync(d1, 'tx-a'), 'conflict');
      expect(await localSync(d1, 'tx-b'), 'pending',
          reason: 'untouched server row => plain pending, push will win');

      // (ii) push: b wins (server unchanged since base); a and c are already in
      // conflict (flagged by the pull) so Phase D holds them for the user's
      // resolution instead of re-pushing them: never sent, rows kept pending,
      // server keeps device 2's value.
      final push1 = await d1.ledgerPush.push();
      expect(push1.pushed, 1);
      expect(push1.conflicts, 0);
      expect(await remoteAmt('tx-b'), '31.5');
      expect(await remoteAmt('tx-a'), '20', reason: 'server not clobbered');
      expect(await remoteAmt('tx-c'), '22', reason: 'server not clobbered');
      expect(await localSync(d1, 'tx-a'), 'conflict');
      expect(await localSync(d1, 'tx-c'), 'conflict');
      expect(await d1.ledgerOutboxCount(), 2,
          reason: 'the held edits stay queued for the user (D-1)');

      // (iii) documented resolution: transactions are INTERACTIVE.
      expect(conflictPolicyFor(ConflictEntities.transaction).isInteractive, true);
      final resolver = UniversalConflictResolver(
        db: d1.db,
        reEnqueue: {
          ConflictEntities.transaction: (id) async {
            final e = await d1.transactions.getById(id);
            if (e != null) await d1.ledgerQueue.enqueue(OutboxOperation.update, e);
          },
        },
        remoteSync: remoteSyncFor(d1),
        baseFetcher: (table, serverId) async {
          final r = await Supabase.instance.client
              .from(table)
              .select('updated_at')
              .eq('id', serverId)
              .single();
          return ConflictBase(updatedAt: r['updated_at'] as String?);
        },
      );
      final listed = (await resolver.listConflicts())
          .where((c) => c.entityType == ConflictEntities.transaction)
          .map((c) => c.localId)
          .toSet();
      expect(listed, {'tx-a', 'tx-c'});

      // keep REMOTE for a: must converge IMMEDIATELY (no pull, no epoch pull).
      // First prove a failed refetch changes nothing (offline) ...
      probe.offline = true;
      final failed = await UniversalConflictResolver(
        db: d1.db,
        reEnqueue: const {},
        remoteSync: remoteSyncFor(d1),
      ).resolveKeepRemote(ConflictEntities.transaction, 'tx-a');
      probe.offline = false;
      expect(failed, false);
      expect(await localSync(d1, 'tx-a'), 'conflict',
          reason: 'fetch failed -> stays in conflict, not marked synced');
      expect(await localAmt(d1, 'tx-a'), Money.parse('30.500', 'KWD'));
      // ... then the real resolution.
      expect(
          await UniversalConflictResolver(
            db: d1.db,
            reEnqueue: const {},
            remoteSync: remoteSyncFor(d1),
          ).resolveKeepRemote(ConflictEntities.transaction, 'tx-a'),
          true);
      expect(await localAmt(d1, 'tx-a'), Money.parse('20.000', 'KWD'),
          reason: 'local equals the server value immediately (exact money)');
      expect(await localSync(d1, 'tx-a'), 'synced');
      expect(await remoteAmt('tx-a'), '20');
      expect(await d1.ledgerOutboxCount("transaction_id='tx-a'"), 0);
      // and a later normal pull / push leaves it alone
      await d1.ledgerPull.pull();
      expect(await localAmt(d1, 'tx-a'), Money.parse('20.000', 'KWD'));

      // keep LOCAL for c: rebase + re-enqueue; the next push wins.
      await resolver.resolveKeepLocal(ConflictEntities.transaction, 'tx-c');
      expect(await d1.ledgerOutboxCount(), 1);
      final push2 = await d1.ledgerPush.push();
      expect(push2.pushed, 1);
      expect(push2.conflicts, 0);
      expect(await remoteAmt('tx-c'), '32.5');
      expect(await localAmt(d1, 'tx-c'), Money.parse('32.500', 'KWD'));
      expect(await localSync(d1, 'tx-c'), 'synced');

      // device 2 then converges to the winner via pull.
      await d2.ledgerPull.pull();
      expect(await localAmt(d2, await lid(d2, u.uid, 'tx-c')), Money.parse('32.500', 'KWD'));
      expect(await localAmt(d2, await lid(d2, u.uid, 'tx-b')), Money.parse('31.500', 'KWD'));
    });

    test('S10 auth/RLS failure: classified auth, parked-retryable, no loss',
        () async {
      final u = await newUser('s10');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.accounts.create(acct('acc-s10', isDefault: true));
      await d.transactions.saveTransaction(
        transaction: txn('tx-s10', '1.111', 'KWD', accountId: 'acc-s10'),
        categoryKey: null,
      );
      await d.budgets.save(budget('bud-s10', '5'));

      final variants = <String, String>{
        'expired': expiredLocalJwt(env, u.uid),
        'invalid': 'not.a.jwt',
        'anon-role (RLS)': env.anonKey,
      };
      final observed = <String, String>{};
      for (final v in variants.entries) {
        // Each variant starts from a re-armed (pending) queue so every variant
        // really reaches the server instead of finding parked rows.
        await d.ledgerQueue.reArmAuthParked();
        await d.planningQueue.reArmAuthParked();
        probe.bearerOverride = v.value;
        await d.elapseBackoff();
        final a = await d.accountsPush.push();
        final l = await d.ledgerPush.push();
        final p = await d.planningPush.push();
        expect(a.pushed + l.pushed + p.pushed, 0, reason: v.key);
        final rows = [
          ...await d.sql('SELECT status, failure_class, attempt_count FROM ledger_sync_outbox'),
          ...await d.sql('SELECT status, failure_class, attempt_count FROM planning_sync_outbox'),
        ];
        // D-4: an RLS denial (42501) while the session is VALID is not an auth
        // problem: it is a permanent, observable permission_denied dead letter
        // (re-armable by Retry), no longer hidden forever as auth_required.
        bool rlsDenied(Map<String, Object?> r) =>
            v.key == 'anon-role (RLS)' &&
            r['status'] == 'dead_letter' &&
            r['failure_class'] == kFailPermissionDenied;
        for (final r in rows) {
          if (rlsDenied(r)) continue;
          expect(r['status'], isNot('dead_letter'),
              reason: '${v.key}: auth failure must never dead-letter');
        }
        // A-5 (verified here): an auth rejection — INCLUDING an expired or
        // invalid JWT, which PostgREST reports as PGRST303 / PGRST301 — is
        // classified `auth`, parked `auth_required`, and consumes NO attempt
        // (attempt_count stays 0). Before A-5 an expired/invalid JWT was
        // mis-classed `serverError`. A child that never reached the server
        // because its parent was not pushed is a missing-dependency wait, not
        // an auth rejection: it stays pending (never dead-lettered).
        for (final r in rows) {
          if (rlsDenied(r)) continue;
          if (r['status'] == 'parked') {
            expect(r['failure_class'], kParkAuthRequired, reason: v.key);
            expect(r['attempt_count'], 0,
                reason: '${v.key}: an auth rejection must not consume an attempt');
          } else {
            expect(r['status'], 'pending', reason: v.key);
            expect(r['failure_class'],
                OutboxFailureClass.missingDependency.reason,
                reason: v.key);
          }
        }
        observed[v.key] = rows
            .map((r) => '${r['status']}/${r['failure_class']}')
            .toSet()
            .join(',');
        expect(
            rows.where((r) => r['status'] == 'parked' || rlsDenied(r)),
            isNotEmpty,
            reason: '${v.key}: the rejected rows are parked / dead-lettered');
        // Local data intact.
        expect(
            (await d.sql('SELECT COUNT(*) n FROM transactions')).single['n'], 1);
        expect((await d.sql('SELECT COUNT(*) n FROM accounts')).single['n'],
            greaterThanOrEqualTo(1));
        expect(await remote.count('user_transactions', u.uid), 0);
        expect(await remote.count('user_accounts', u.uid), 0);
        expect(await remote.count('user_budgets', u.uid), 0);
      }
      // ignore: avoid_print
      print('S10 observed status/failure_class per variant: $observed');

      // Valid session again -> the very same rows drain, nothing lost.
      probe.bearerOverride = null;
      await d.ledgerQueue.reArmAuthParked();
      await d.planningQueue.reArmAuthParked();
      // D-4: the RLS-denied dead letters are re-armed by an explicit Retry.
      await d.ledgerQueue.reArmRetryableDeadLetters();
      await d.planningQueue.reArmRetryableDeadLetters();
      await d.elapseBackoff();
      expect((await d.accountsPush.push()).failed, 0);
      expect((await d.ledgerPush.push()).pushed, 1);
      expect((await d.planningPush.push()).pushed, 1);
      expect(await remote.count('user_transactions', u.uid), 1);
      expect(await remote.count('user_accounts', u.uid), 1);
      expect(await remote.count('user_budgets', u.uid), 1);
    });

    test('S11 awaiting-FX: parked while server lacks 0102; pushed after; '
        'DB restored to 0001-0099', () async {
      final u = await newUser('s11');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      final repo = Directory.current.parent.path;
      final f103 = '$repo/supabase/migrations/0102_awaiting_fx_transactions.sql';
      final f103rb =
          '$repo/supabase/rollback/0102_awaiting_fx_transactions_rollback.sql';

      Future<String> fingerprint() => remote.psql(
          sql: "select coalesce((select md5(pg_get_functiondef(p.oid)) from pg_proc p "
              "join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' "
              "and p.proname='category_spending_summary'),'none') || '|' || "
              "coalesce((select string_agg(conname, ',' order by conname) from pg_constraint "
              "where conrelid='public.user_transactions'::regclass and conname like 'chk_user_transactions_amount%'),'') || '|' || "
              "(select count(*) from pg_proc where proname='qirsh_server_capabilities')");
      final baseline = await fingerprint();
      expect(baseline, contains('chk_user_transactions_amount_positive'));
      expect(baseline, endsWith('|0'));

      addTearDown(() async {
        // Always leave the DB at 0001-0099, even if an assertion failed.
        final now = await fingerprint();
        if (now != baseline) {
          await remote.psql(
              sql: "delete from public.user_transactions where amount = 0");
          await remote.psql(file: f103rb);
        }
      });

      await d.accounts.create(acct('acc-s11', isDefault: true));
      await d.accountsPush.push();
      await d.transactions.saveTransaction(
        transaction: txn('tx-fx', '0', 'KWD',
            accountId: 'acc-s11',
            foreign: Money.parse('50.00', 'USD'),
            foreignCurrency: 'USD'),
        categoryKey: null,
      );
      await d.transactions.saveTransaction(
        transaction: txn('tx-plain', '2.500', 'KWD', accountId: 'acc-s11'),
        categoryKey: null,
      );

      // --- server WITHOUT 0102 ---
      probe.resetCount();
      final r1 = await d.ledgerPush.push();
      expect(r1.pushed, 1, reason: 'the priced row still goes');
      expect(r1.parked, 1);
      expect(d.capabilities.cachedAwaitingFx(u.uid), ServerCapabilityState.unsupported);
      final fx = await d.ledgerOutboxRow('tx-fx');
      expect(fx['status'], 'parked');
      expect(fx['failure_class'], 'awaiting_server_fx_support');
      expect(fx['attempt_count'], 0);
      expect(
          probe.countWhere((e) =>
              e.startsWith('POST ') && e.endsWith('/rest/v1/user_transactions')),
          1,
          reason: 'exactly one insert (the priced row); ZERO for the FX row');
      expect(await remote.count('user_transactions', u.uid), 1);

      // --- apply 0102 on the local DB ---
      await remote.psql(file: f103);
      await remote.psql(sql: "NOTIFY pgrst, 'reload schema'");
      await Future<void>.delayed(const Duration(seconds: 2));
      // Same session: positive/negative answers are cached for the session
      // (design: one probe per session) so the parked row keeps waiting...
      expect(await d.capabilities.awaitingFxTransactions(uid: u.uid),
          ServerCapabilityState.unsupported);
      // ...until a re-probe (app restart == new service; here force).
      expect(await d.capabilities.awaitingFxTransactions(uid: u.uid, force: true),
          ServerCapabilityState.verified);
      final r2 = await d.ledgerPush.push();
      expect(r2.pushed, 1);
      expect(r2.failed, 0);
      final rows = await remote.rows('user_transactions', u.uid,
          select: 'client_request_id,amount_text:amount::text,'
              'fa:foreign_amount::text,foreign_currency',
          filter: 'client_request_id=eq.tx-fx');
      expect(rows, hasLength(1));
      expect(dec(rows.single['amount_text']), '0');
      expect(dec(rows.single['fa']), '50');
      expect(rows.single['foreign_currency'], 'USD');
      expect(await d.ledgerOutboxCount(), 0);

      // --- cleanup: delete the awaiting-FX rows, run the rollback ---
      await remote.psql(
          sql: "delete from public.user_transactions where amount = 0");
      await remote.psql(file: f103rb);
      await remote.psql(sql: "NOTIFY pgrst, 'reload schema'");
      expect(await fingerprint(), baseline,
          reason: 'local DB is back to the 0001-0099 state');
    });

    test('S12 sender mapping pushes WITHOUT accepted_by (server lacks 0100)',
        () async {
      final u = await newUser('s12');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);
      await d.senderMappings.saveSuggestion(const SenderBankMappingDraft(
        senderId: 'PROOF-BANK',
        suggestedBankName: 'Proof Bank',
        suggestedCountry: 'KW',
        confidence: 0.9,
        bankKey: 'proof_bank',
      ));
      final m = await d.senderMappings.getBySender('PROOF-BANK');
      await d.senderMappings.confirm(mappingId: m!.id, bankKey: 'proof_bank');

      final cols = (await remote.psql(
              sql: "select column_name from information_schema.columns where "
                  "table_name='sender_bank_mappings' and column_name='accepted_by'"))
          .trim();
      expect(cols, isEmpty, reason: 'server has no accepted_by (0100 deferred)');

      final res = await d.senderSync.sync();
      expect(res.pushed, 1);
      expect(res.failed, 0);
      final rows = await remote.rows('sender_bank_mappings', u.uid);
      expect(rows, hasLength(1));
      expect(rows.single['normalized_sender_id'], 'PROOFBANK');
      expect(rows.single['bank_key'], 'proof_bank');
      expect(rows.single['status'], 'confirmed');
      expect(rows.single.containsKey('accepted_by'), false);
      expect(
          (await d.sql('SELECT sync_status s FROM sender_bank_mappings')).single['s'],
          'synced');
    });

    test('S13 onboarding account created OFFLINE syncs exactly once later',
        () async {
      final u = await newUser('s13');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);

      probe.offline = true;
      // AccountFormPanel path == DriftAccountRepository.create
      await d.accounts.create(acct('acc-s13', name: 'Onboarding', initial: '250.750'));
      expect(await d.planningOutboxCount("entity_type='account'"), 1);
      final off = await d.accountsPush.push();
      expect(off.pushed, 0);
      expect(await remote.count('user_accounts', u.uid), 0);
      expect(
          (await d.sql("SELECT sync_status s FROM accounts WHERE id='acc-s13'"))
              .single['s'],
          'pending');

      probe.offline = false;
      await d.elapseBackoff();
      expect((await d.accountsPush.push()).pushed, 2);
      expect(await remote.count('user_accounts', u.uid), 1);
      // later cycles / app restarts must not create a second one
      probe.resetCount();
      await d.accountsPush.push();
      await d.accountsPush.push();
      expect(writesTo('user_accounts'), 0);
      expect(await remote.count('user_accounts', u.uid), 1);
      final r = (await remote.rows('user_accounts', u.uid,
              select: 'local_id,b:initial_balance::text'))
          .single;
      expect(r['local_id'], 'acc-s13');
      expect(dec(r['b']), '250.75');
      expect(await d.planningOutboxCount(), 0);
    });

    test('S9b planning keep-remote converges immediately (budget)', () async {
      final u = await newUser('s9b');
      await signIn(u);
      final d1 = await openDevice();
      final d2 = await openDevice();
      addTearDown(d1.close);
      addTearDown(d2.close);
      await d1.budgets.save(budget('bud-s9b', '100.000'));
      await d1.planningPush.push();
      await d2.planningPull.pull();
      // device 2 edits and pushes
      await d2.budgets.save(budget('bud-s9b', '200.250'));
      expect((await d2.planningPush.push()).pushed, 1);
      // device 1 edits the same budget from the stale base and pushes -> conflict
      await d1.budgets.save(budget('bud-s9b', '300.500'));
      final p = await d1.planningPush.push();
      expect(p.conflicts, 1);
      expect(
          (await d1.sql("SELECT sync_status s FROM budgets WHERE id='bud-s9b'"))
              .single['s'],
          'conflict');
      final r = UniversalConflictResolver(
          db: d1.db, reEnqueue: const {}, remoteSync: remoteSyncFor(d1));
      expect(await r.resolveKeepRemote(ConflictEntities.budget, 'bud-s9b'), true);
      final row = (await d1.sql(
              "SELECT amount_minor m, sync_status s FROM budgets WHERE id='bud-s9b'"))
          .single;
      expect(row['m'], 200250, reason: 'exact server value, no pull needed');
      expect(row['s'], 'synced');
      expect(
          dec((await remote.rows('user_budgets', u.uid,
                  select: 'a:amount::text'))
              .single['a']),
          '200.25');
    });

    test('S14 capabilities via the REAL production providers + probe: planning '
        'currency verified against the local stack, budget push succeeds; a '
        'missing column/table maps to unsupported', () async {
      final u = await newUser('s14');
      await signIn(u);
      final d = await openDevice();
      addTearDown(d.close);

      // The real production provider graph (nothing injected but the database
      // and, via the DB, the consent state the production consent gate reads).
      final container = ProviderContainer(overrides: [
        appDatabaseProvider.overrideWithValue(d.db),
      ]);
      addTearDown(container.dispose);
      final settings = container.read(userSettingsRepositoryProvider);
      await settings.saveSettings((await settings.getSettings())
          .copyWith(cloudConsentState: ConsentState.accepted));

      // Exact transport is a build constant in production.
      expect(container.read(exactPushTransportCapabilityProvider),
          ExactTransportCapability.verifiedExact);
      expect(container.read(exactPullTransportCapabilityProvider),
          ExactTransportCapability.verifiedExact);
      // Planning currency is NOT known until the real probe has run.
      expect(container.read(planningServerCurrencyCapabilityProvider),
          ExactTransportCapability.unknown);

      // A push service wired exactly like planningPushServiceProvider, reading
      // the capabilities through the real providers at call time.
      Future<bool> consent() async => true;
      final push = PlanningPushService(
        db: d.db,
        queue: d.planningQueue,
        isEnabled: (_) => true,
        getAuthUserId: signedInUid,
        coordinator: const FixedPlanningCutoverCoordinator(
            PlanningCutoverState.canonical),
        pushCapability: () =>
            container.read(exactPushTransportCapabilityProvider),
        planningCurrencyCapability: () =>
            container.read(planningServerCurrencyCapabilityProvider),
        mayEgress: consent,
        mayEgressProfile: consent,
      );

      await d.budgets.save(budget('bud-s14', '12.345'));
      probe.resetCount();
      final before = await push.push();
      expect(before.pushed, 0);
      expect(before.parked, 1,
          reason: 'planning currency unknown => canonical budget stays parked');
      expect(probe.countWhere((e) => e.contains('user_budgets')), 0,
          reason: 'a parked row sends nothing');
      expect(await remote.count('user_budgets', u.uid), 0);

      // The real probe (production provider) against the local stack, where
      // 0077 is applied.
      final capability =
          await container.read(planningCurrencyCapabilityProbeProvider).ensure();
      expect(capability, ExactTransportCapability.verifiedExact);
      expect(container.read(planningServerCurrencyCapabilityProvider),
          ExactTransportCapability.verifiedExact);
      expect(probe.countWhere((e) => e.contains('/rest/v1/user_budgets')),
          greaterThanOrEqualTo(1));
      expect(probe.countWhere((e) => e.contains('/rest/v1/user_goals')),
          greaterThanOrEqualTo(1));
      expect(SyncHealth.shared.capabilityStates['planning currency'],
          'verifiedExact');

      // Same row, now unparked by the verified capability, pushes exactly.
      // push() re-arms rows parked on the transport capability before draining.
      final after = await push.push();
      expect(after.pushed, 1);
      expect(await remote.count('user_budgets', u.uid), 1);
      final row = (await remote.rows('user_budgets', u.uid,
              select: 'local_id,currency,amount_text:amount::text'))
          .single;
      expect(row['local_id'], 'bud-s14');
      expect(row['currency'], 'KWD');
      expect(dec(row['amount_text']), '12.345');

      // Missing column / table => unsupported, via the real client and the real
      // PostgREST error codes.
      for (final bad in const ['no_such_column', 'currency']) {
        final p = PlanningCurrencyCapabilityProbe(
          getAuthUserId: signedInUid,
          probeCurrencyColumn: (table) async {
            await Supabase.instance.client
                .from(bad == 'currency' ? 'user_no_such_table' : table)
                .select(bad)
                .limit(0);
          },
          onChanged: (_) {},
          mayEgress: () async => true,
        );
        expect(await p.ensure(), ExactTransportCapability.unsupported,
            reason: bad);
      }
    });
  });
}
