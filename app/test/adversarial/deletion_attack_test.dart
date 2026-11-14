import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/auth/immediate_deletion_receipt_store.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/core/session/remove_data_flow.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/settings/profile_image_store.dart';
import 'package:path/path.dart' as p;

import '../core/session/f2_fixture.dart';

/// Adversarial: account deletion followed by a sign-in with the same identity
/// (scenario 32), via the P4 path: the server completed the deletion, the
/// process died before the local removal, and the next launch has no session.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const owner = 'uid-del';
  const secret = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ0123';
  late F2Fixture f;
  late Directory docs;
  late Directory picks;
  final session = AppSession.instance;

  setUp(() async {
    f = await F2Fixture.create();
    docs = Directory.systemTemp.createTempSync('adv_del_docs');
    picks = Directory.systemTemp.createTempSync('adv_del_picks');
    final defaultDocs = RemoveDataFlow.documentsDirectory;
    RemoveDataFlow.documentsDirectory = () async => docs;
    addTearDown(() => RemoveDataFlow.documentsDirectory = defaultDocs);
  });
  tearDown(() async {
    await f.dispose();
    docs.deleteSync(recursive: true);
    picks.deleteSync(recursive: true);
  });

  AppDatabase db() => f.host.current!.database;
  Future<int> count(String table) async =>
      (await db().customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');

  /// Signs [owner] in, seeds money + profile + photo, the server completes the
  /// deletion, and the process dies before anything local was removed.
  Future<String> deletedAndKilled() async {
    await f.signIn(owner);
    final ts = DateTime.now().toUtc().toIso8601String();
    await db().customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at) VALUES ('tx-old', 99, 'SAR', 'expense', 'manual', '$ts', "
      "'old secret', 1.0, 'active', '$ts', '$ts');",
    );
    final picked = File(p.join(picks.path, 'me.jpg'))..writeAsStringSync('ME');
    final photo = await storeProfileImage(
        pickedPath: picked.path, documents: docs, ownerUid: owner);
    await db().customStatement(
        'UPDATE user_settings SET avatar_path = ?, display_name = ?;',
        [photo, 'Old Me']);
    await ImmediateDeletionReceiptStore().writeVerified(
        const ImmediateDeletionReceipt(
            owner: owner,
            operationId: 'op-adv',
            receiptSecret: secret,
            phase: ImmediateDeletionPhase.completed));
    await f.restart();
    return photo;
  }

  test(
      '32: delete account, killed before local removal, relaunch, sign in '
      'again with the same identity: no old data comes back', () async {
    await deletedAndKilled();
    final launch = await session.prepareLaunchAdmission();
    expect(launch.blocked, isFalse);
    expect(launch.uid, isNull);
    expect(await f.artifactsOf(owner), isEmpty);
    expect(f.storage.data[RemoveDataFlow.barrierKey], isNull);

    await f.signIn(owner);
    expect(f.host.current!.uid, owner);
    expect(await count('transactions'), 0);
    final row = (await db()
            .customSelect(
                'SELECT display_name, avatar_path FROM user_settings LIMIT 1;')
            .getSingle())
        .data;
    expect(row['display_name'], isNot('Old Me'));
    expect(row['avatar_path'], isNull);
  });

  test(
      "32b: the deleted account's profile photo does not survive the "
      'deletion on disk', () async {
    final photo = await deletedAndKilled();
    await session.prepareLaunchAdmission();
    expect(await f.artifactsOf(owner), isEmpty,
        reason: 'the replica, key and registry are gone (P4)');
    expect(File(photo).existsSync(), isFalse,
        reason: "the deleted account's photo is personal data left in "
            '<Documents>/profile/ (backed up by iOS) after its deletion');
  });
}
