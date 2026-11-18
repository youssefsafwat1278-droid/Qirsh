// Decision 3.3 (V1-020, V1-070) — restore MERGES into a device that already
// holds financial data. Per row, keyed by its local id:
//  * only in the backup        -> brought back;
//  * only on the device        -> kept (created after the backup, synced or not);
//  * on both                   -> the copy with the newer `updated_at` wins and
//                                 the device wins a tie; a table whose backup
//                                 carries no timestamp keeps the device row;
//  * deleted on the device     -> stays deleted (the device's deletion is newer);
//  * category changed by hand  -> the device's choice and provenance are kept.
// Then Cloud sync converges with one cloud copy per row. Real restore use case,
// snapshot builder, outbox, reconciler, backfill, push and pull over the
// in-memory cloud (fake_ledger_cloud.dart). Synthetic data only.
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

import '../../features/capture/ledger_admission_fixture.dart';
import 'fake_ledger_cloud.dart';
import 'restore_sync_device.dart';

void main() {
  late LedgerAdmissionFixture admission;
  late Device d;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    admission = await LedgerAdmissionFixture.open(uid);
    d = Device(admission.database, FakeLedgerCloud());
    await d.seedAccount();
  });
  tearDown(() => admission.finish());

  Future<Map<String, Object?>> row(String id) async => (await d.db
          .customSelect('SELECT t.status, t.amount_minor, t.category_source, '
              't.sync_status, c.key AS category_key FROM transactions t '
              'LEFT JOIN categories c ON c.id = t.category_id '
              "WHERE t.id = '$id';")
          .getSingle())
      .data;

  test('a row deleted after the backup stays deleted on device and cloud',
      () async {
    await d.add('m1-A', '10');
    await d.add('m1-C', '30');
    await d.sync();
    final backup = await d.backup();
    await d.repo.deleteTransaction('m1-C');
    await d.sync();

    await d.restore(backup);
    expect((await row('m1-C'))['status'], 'ignored',
        reason: 'the restore must not resurrect a deleted transaction');
    await d.sync();
    await d.sync();
    expect(await d.live(), {'Synthetic shop m1-A': '10.00'});
    expect(d.cloud.live().keys, ['Synthetic shop m1-A']);
    expect(await d.syncStatus('m1-C'), isNot('conflict'));
    expect(d.cloud.rows, hasLength(2), reason: 'no duplicate cloud copy');
  });

  test('a row deleted after the backup and not yet synced stays deleted',
      () async {
    await d.add('m1b-C', '30');
    await d.sync();
    final backup = await d.backup();
    await d.repo.deleteTransaction('m1b-C'); // delete intent still queued

    await d.restore(backup);
    expect((await row('m1b-C'))['status'], 'ignored');
    await d.sync();
    await d.sync();
    expect(await d.live(), isEmpty);
    expect(d.cloud.live(), isEmpty,
        reason: 'the queued deletion still reaches the cloud');
  });

  test('a row edited after the backup keeps the newer edit', () async {
    await d.add('m2-B', '20');
    await d.sync();
    final backup = await d.backup();
    await d.repo
        .updateAmount(transactionId: 'm2-B', amount: Money.parse('25', 'SAR'));

    await d.restore(backup);
    expect(await d.live(), {'Synthetic shop m2-B': '25.00'});
    await d.sync();
    await d.sync();
    expect(await d.live(), {'Synthetic shop m2-B': '25.00'});
    expect(d.cloud.live(), {
      'Synthetic shop m2-B': ['25.00']
    });
  });

  test('a row created after the backup and not yet synced is kept and pushed '
      'once', () async {
    await d.add('m3-A', '10');
    await d.sync();
    final backup = await d.backup();
    await d.add('m3-D', '40'); // create intent queued, never pushed

    await d.restore(backup);
    expect(await d.live(), {
      'Synthetic shop m3-A': '10.00',
      'Synthetic shop m3-D': '40.00',
    });
    await d.sync();
    await d.sync();
    expect(d.cloud.live(), {
      'Synthetic shop m3-A': ['10.00'],
      'Synthetic shop m3-D': ['40.00'],
    });
    expect(d.cloud.rows, hasLength(2));
  });

  test('a row missing on this device is brought back from the backup and '
      'bound to its cloud copy, not duplicated', () async {
    await d.add('m4-A', '10');
    await d.add('m4-B', '20');
    await d.sync();
    final backup = await d.backup();
    // This device no longer has B (e.g. a backup made on another phone).
    await d.db.customStatement("DELETE FROM transactions WHERE id = 'm4-B';");

    await d.restore(backup);
    expect(await d.live(), {
      'Synthetic shop m4-A': '10.00',
      'Synthetic shop m4-B': '20.00',
    });
    await d.sync();
    await d.sync();
    expect(d.cloud.live(), {
      'Synthetic shop m4-A': ['10.00'],
      'Synthetic shop m4-B': ['20.00'],
    });
    expect(d.cloud.rows, hasLength(2));
    expect(await d.syncStatus('m4-B'), 'synced');
  });

  test('a row present only in the cloud arrives through sync, once', () async {
    await d.add('m5-A', '10');
    await d.sync();
    final backup = await d.backup();
    // E reaches the cloud after the backup; this device has not pulled it
    // (modelled as: the local copy is gone and the pull cursor is unset).
    await d.add('m5-E', '50');
    await d.sync();
    await d.db.customStatement("DELETE FROM transactions WHERE id = 'm5-E';");
    await d.db.customStatement('DELETE FROM sync_cursors;');

    await d.restore(backup);
    await d.sync();
    await d.sync();
    expect(await d.live(), {
      'Synthetic shop m5-A': '10.00',
      'Synthetic shop m5-E': '50.00',
    });
    expect(d.cloud.rows, hasLength(2));
  });

  test('a category changed by hand after the backup keeps the choice and its '
      'provenance', () async {
    await d.add('m6-A', '10');
    await d.repo.updateCategory(transactionId: 'm6-A', categoryKey: 'shopping');
    await d.sync();
    final backup = await d.backup();
    await d.repo
        .updateCategory(transactionId: 'm6-A', categoryKey: 'restaurants');

    await d.restore(backup);
    final r = await row('m6-A');
    expect(r['category_key'], 'restaurants');
    expect(r['category_source'], 'user');
  });

  test('a backup copy newer than the device copy wins and is pushed as an '
      'update of the same cloud row', () async {
    await d.add('m7-B', '20');
    await d.sync();
    final backup = await d.backup();
    final txns = ((backup['tables'] as Map)['transactions'] as List)
        .cast<Map<String, dynamic>>();
    final b = txns.singleWhere((r) => r['id'] == 'm7-B');
    b['amount_minor'] = '3000';
    b['amount'] = 30.0;
    b['updated_at'] = '2099-01-01T00:00:00.000Z';

    await d.restore(backup);
    expect(await d.live(), {'Synthetic shop m7-B': '30.00'});
    await d.sync();
    await d.sync();
    expect(d.cloud.live(), {
      'Synthetic shop m7-B': ['30.00']
    });
    expect(d.cloud.rows, hasLength(1));
  });
}
