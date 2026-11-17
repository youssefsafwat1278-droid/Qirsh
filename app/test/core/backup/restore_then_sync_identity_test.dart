// V1-020 — restore a backup, then sync, WITHOUT a live stack. Real backup
// snapshot builder and restore use case, real ledger outbox, pending-intent
// reconciler, transactions backfill, legacy ledger push and pull; the cloud is
// an in-memory `user_transactions` behind the real PostgREST client
// (fake_ledger_cloud.dart). Synthetic data only.
//
// Semantics asserted (see RestoreBackupUseCase._rebindSyncIdentity):
//  * restored rows keep their server identity and their RESTORED values become
//    the cloud copy (no duplicate cloud rows);
//  * PENDING OWNER DECISION (replace vs merge): cloud rows ABSENT from the
//    backup are kept and pulled back to the device (merge, the non-destructive
//    default);
//  * a row the cloud holds as a tombstone is never un-deleted: the restored row
//    is kept locally and surfaced as a sync conflict.
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

  test('R1: restored values win over later synced edits; a cloud row created '
      'after the backup is kept and pulled back (pending decision: merge)',
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
      'Synthetic shop r1-B': '20.00',
      'Synthetic shop r1-C': '30.00',
    });

    await d.sync();
    await d.sync();
    await expectConverged(d, restored);
    // The cloud-only row D (absent from the backup) is merged back.
    expect((await d.live())['Synthetic shop r1-D'], '40.00');
    expect(d.cloud.rows, hasLength(4), reason: 'no new cloud rows at all');
  });

  test('R2: a cloud row created after the backup returns to the device '
      '(pending decision: merge), nothing duplicated', () async {
    await d.add('r2-A', '10');
    await d.sync();
    final backup = await d.backup();
    await d.add('r2-E', '50');
    await d.sync();

    await d.restore(backup);
    final restored = await d.live();
    expect(restored, {'Synthetic shop r2-A': '10.00'});

    await d.sync();
    await d.sync();
    await expectConverged(d, restored);
    expect(await d.live(), {
      'Synthetic shop r2-A': '10.00',
      'Synthetic shop r2-E': '50.00',
    });
    expect(d.cloud.rows, hasLength(2));
  });

  test('a restored row the cloud holds as a tombstone is kept locally and '
      'surfaced as a conflict, never duplicated or silently re-deleted',
      () async {
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

    expect(await d.live(), {
      'Synthetic shop t-A': '10.00',
      'Synthetic shop t-C': '30.00',
    });
    expect(await d.syncStatus('t-C'), 'conflict');
    expect(await d.syncStatus('t-A'), 'synced');
    expect(d.cloud.live().keys, ['Synthetic shop t-A'],
        reason: 'the cloud tombstone is never un-deleted by a restore');
    expect(d.cloud.rows, hasLength(2), reason: 'no duplicate cloud copy');
  });
}
