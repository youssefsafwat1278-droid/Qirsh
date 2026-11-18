// V1-020 — restore a backup, then sync, WITHOUT a live stack. Real backup
// snapshot builder and restore use case, real ledger outbox, pending-intent
// reconciler, transactions backfill, legacy ledger push and pull; the cloud is
// an in-memory `user_transactions` behind the real PostgREST client
// (fake_ledger_cloud.dart). Synthetic data only.
//
// Semantics asserted (decision 3.3, restore = merge; see
// RestoreBackupUseCase._mergeSnapshot):
//  * rows keep their server identity; no duplicate cloud rows;
//  * an edit or deletion made after the backup is newer and is kept;
//  * rows created after the backup are kept, on the device and in the cloud.
// The per-scenario merge rule is covered in restore_merge_rule_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/domain/finance/money.dart';

import '../../features/capture/ledger_admission_fixture.dart';
import 'fake_ledger_cloud.dart';
import 'restore_sync_device.dart';

void main() {
  late LedgerAdmissionFixture admission;
  late Device d;

  setUp(() async {
    admission = await LedgerAdmissionFixture.open(uid);
    d = Device(admission.database, FakeLedgerCloud());
    await d.seedAccount();
  });
  tearDown(() => admission.finish());

  test('R1: a later synced edit is newer and is kept; a row created after the '
      'backup is kept; nothing is duplicated',
      () async {
    await d.add('r1-A', '10');
    await d.add('r1-B', '20');
    await d.add('r1-C', '30');
    await d.sync();
    final backup = await d.backup();

    await d.repo.updateAmount(
        transactionId: 'r1-B', amount: Money.parse('25', 'SAR'));
    await d.add('r1-D', '40');
    await d.sync();
    expect(d.cloud.live()['Synthetic shop r1-B'], ['25.00']);

    await d.restore(backup);
    final restored = await d.live();
    expect(restored, {
      'Synthetic shop r1-A': '10.00',
      'Synthetic shop r1-B': '25.00',
      'Synthetic shop r1-C': '30.00',
      'Synthetic shop r1-D': '40.00',
    });

    await d.sync();
    await d.sync();
    await expectConverged(d, restored);
    expect(d.cloud.rows, hasLength(4), reason: 'no new cloud rows at all');
  });

  test('R2: a row created after the backup stays on the device and in the '
      'cloud, nothing duplicated', () async {
    await d.add('r2-A', '10');
    await d.sync();
    final backup = await d.backup();
    await d.add('r2-E', '50');
    await d.sync();

    await d.restore(backup);
    final restored = await d.live();
    expect(restored, {
      'Synthetic shop r2-A': '10.00',
      'Synthetic shop r2-E': '50.00',
    });

    await d.sync();
    await d.sync();
    await expectConverged(d, restored);
    expect(await d.live(), {
      'Synthetic shop r2-A': '10.00',
      'Synthetic shop r2-E': '50.00',
    });
    expect(d.cloud.rows, hasLength(2));
  });

  test('a row deleted (and synced) after the backup stays deleted: no '
      'resurrection, no conflict, no duplicate', () async {
    await d.add('t-A', '10');
    await d.add('t-C', '30');
    await d.sync();
    final backup = await d.backup();
    await d.repo.deleteTransaction('t-C');
    await d.sync();
    expect(d.cloud.live().keys, ['Synthetic shop t-A']);

    await d.restore(backup);
    await d.sync();
    await d.sync();

    expect(await d.live(), {'Synthetic shop t-A': '10.00'});
    expect(await d.syncStatus('t-C'), isNot('conflict'));
    expect(await d.syncStatus('t-A'), 'synced');
    expect(d.cloud.live().keys, ['Synthetic shop t-A'],
        reason: 'the cloud tombstone is never un-deleted by a restore');
    expect(d.cloud.rows, hasLength(2), reason: 'no duplicate cloud copy');
  });
}
