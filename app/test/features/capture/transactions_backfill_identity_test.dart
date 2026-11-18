// V1-020 — the transactions backfill must not insert a second cloud row for a
// local row the cloud already holds under the outbox identity
// (`client_request_id = <local id>`). Such rows lose `server_id` locally when a
// backup is restored onto a device that never held that identity (a fresh
// install), which is modelled here by clearing the sync columns. Real backfill,
// pending reconciler, legacy ledger push and pull over the in-memory cloud.
// Synthetic data only.
import 'package:flutter_test/flutter_test.dart';

import '../../core/backup/fake_ledger_cloud.dart';
import '../../core/backup/restore_sync_device.dart';
import 'ledger_admission_fixture.dart';

void main() {
  late LedgerAdmissionFixture admission;
  late Device d;

  setUp(() async {
    admission = await LedgerAdmissionFixture.open(uid);
    d = Device(admission.database, FakeLedgerCloud());
    await d.seedAccount();
  });
  tearDown(() => admission.finish());

  Future<void> forgetIdentity() => d.db.customStatement(
      'UPDATE transactions SET server_id = NULL, server_updated_at = NULL, '
      'server_revision = NULL, synced_at = NULL, sync_status = NULL;');

  test('binds to the existing cloud row instead of inserting a backfill copy; '
      'an equal row is synced, a differing amount is a conflict for the user',
      () async {
    await d.add('b-A', '10');
    await d.add('b-B', '20');
    await d.sync();
    expect(d.cloud.rows, hasLength(2));

    // The cloud moved on; the device holds the older (restored) value with no
    // server identity.
    d.cloud.rows
        .firstWhere((r) => r['client_request_id'] == 'b-B')
          ..['amount'] = 25
          ..['amount_text'] = '25.00';
    await forgetIdentity();

    await d.sync();
    await d.sync();

    expect(d.cloud.rows, hasLength(2), reason: 'no backfill duplicate');
    expect(
        d.cloud.rows.where(
            (r) => '${r['client_request_id']}'.startsWith('backfill_')),
        isEmpty);
    expect(d.cloud.live(), {
      'Synthetic shop b-A': ['10.00'],
      'Synthetic shop b-B': ['25.00'],
    });
    expect(await d.live(), {
      'Synthetic shop b-A': '10.00',
      'Synthetic shop b-B': '20.00',
    });
    expect(await d.syncStatus('b-A'), 'synced');
    expect(await d.syncStatus('b-B'), 'conflict',
        reason: 'existing H-2 backfill semantics: a money difference is never '
            'silently resolved either way');
  });

  test('a row with no stored direction is compared the way the outbox push '
      'wrote it: an unchanged row is synced, not a false conflict', () async {
    await d.add('n-A', '10');
    await d.db.customStatement(
        "UPDATE transactions SET direction = NULL WHERE id = 'n-A';");
    await d.sync();
    expect(d.cloud.rows.single['direction'], 'debit',
        reason: 'the push derives debit from the payment type');
    await forgetIdentity();

    await d.sync();

    expect(d.cloud.rows, hasLength(1), reason: 'no backfill copy');
    expect(await d.syncStatus('n-A'), 'synced');
  });

  test('a restored row whose cloud copy is a tombstone takes the cloud '
      'deletion: not re-inserted, not resurrected, no conflict', () async {
    await d.add('t-A', '10');
    await d.sync();
    d.cloud.rows.single['deleted_at'] = '2026-09-01T00:00:00.000Z';
    await forgetIdentity();

    await d.sync();
    await d.sync();

    expect(d.cloud.rows, hasLength(1), reason: 'no backfill copy');
    expect(d.cloud.live(), isEmpty, reason: 'the tombstone is not undone');
    expect(await d.live(), isEmpty,
        reason: 'the deletion made in the cloud after the backup is kept');
    expect(await d.syncStatus('t-A'), 'synced');
    expect(
        (await d.db
                .customSelect("SELECT server_id FROM transactions WHERE id = 't-A'")
                .getSingle())
            .readNullable<String>('server_id'),
        d.cloud.rows.single['id'],
        reason: 'bound to the cloud row, so it is never backfilled again');
  });

  test('...but a row with a local change still waiting to be sent is a '
      'conflict for the user, never silently deleted', () async {
    await d.add('t-P', '10');
    await d.sync();
    d.cloud.rows.single['deleted_at'] = '2026-09-01T00:00:00.000Z';
    await forgetIdentity();
    await d.db.customStatement(
        "UPDATE transactions SET sync_status = 'pending' WHERE id = 't-P';");

    await d.sync();

    expect(d.cloud.live(), isEmpty, reason: 'the tombstone is not undone');
    expect(await d.live(), {'Synthetic shop t-P': '10.00'});
    expect(await d.syncStatus('t-P'), 'conflict');
  });
}
