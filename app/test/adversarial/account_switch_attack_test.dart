import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/settings/profile_image_store.dart';
import 'package:path/path.dart' as p;

import '../core/session/f2_fixture.dart';

/// Adversarial: account switching on one device (scenarios 9, 11, 12, 14).
///
/// Drives the REAL AppSession over the real per-uid replica host (F2Fixture):
/// sign-in, sign-out (lock), and a different uid's sign-in, as the UI does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late F2Fixture f;
  late Directory docs;
  late Directory picks;
  final session = AppSession.instance;
  var tick = 0;
  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(++tick);

  setUp(() async {
    f = await F2Fixture.create();
    docs = Directory.systemTemp.createTempSync('adv_docs');
    picks = Directory.systemTemp.createTempSync('adv_picks');
  });
  tearDown(() async {
    session.configureCaptureOwnerClear(() async => true);
    await f.dispose();
    docs.deleteSync(recursive: true);
    picks.deleteSync(recursive: true);
  });

  AppDatabase db() => f.host.current!.database;
  Future<int> count(String table) async =>
      (await db().customSelect('SELECT COUNT(*) AS n FROM $table;').getSingle())
          .read<int>('n');
  Future<Map<String, Object?>> settingsRow() async => (await db()
          .customSelect(
              'SELECT display_name, avatar_path FROM user_settings LIMIT 1;')
          .getSingle())
      .data;

  Future<String> setAvatar(String tag) async {
    final picked = File(p.join(picks.path, '$tag.jpg'))..writeAsStringSync(tag);
    final previous = (await settingsRow())['avatar_path'] as String?;
    final path = await storeProfileImage(
        pickedPath: picked.path,
        documents: docs,
        previousPath: previous,
        now: now);
    await db().customStatement(
        'UPDATE user_settings SET avatar_path = ?, display_name = ?;',
        [path, 'User $tag']);
    return path;
  }

  Future<void> seed(String tag) async {
    final ts = DateTime.now().toUtc().toIso8601String();
    await db().customStatement(
      "INSERT INTO transactions(id, amount, currency, type, source, "
      "occurred_at, raw_message, parse_confidence, status, created_at, "
      "updated_at) VALUES ('tx-$tag', 77, 'SAR', 'expense', 'manual', '$ts', "
      "'secret $tag', 1.0, 'active', '$ts', '$ts');",
    );
    await db().customStatement(
      "INSERT INTO notification_log_events(id, notification_log_id, "
      "event_type, channel, notification_type, payload_json, occurred_at, "
      "created_at) VALUES ('n-$tag', 'log-$tag', 'sent', 'push', "
      "'budget_alert', '{}', '$ts', '$ts');",
    );
  }

  test(
      "9/11/14: A -> sign out -> B -> sign out -> A: B never sees A's "
      'transactions, notifications, settings or photo; each keeps its own '
      'photo; A finds everything again', () async {
    var purges = 0;
    session.configureCaptureOwnerClear(() async {
      purges++; // production: clears A's OS notifications + native residue
      return true;
    });

    await f.signIn('uid-a');
    await seed('a');
    final photoA = await setAvatar('A');
    await session.signOut();
    expect(purges, greaterThanOrEqualTo(1),
        reason: "sign-out purges A's OS notifications / residue");
    expect(f.host.current?.uid, isNull, reason: 'signed-out scope only');
    expect((await f.registryEntry('uid-a'))!.state.name, 'locked');

    await f.signIn('uid-b');
    expect(f.host.current!.uid, 'uid-b');
    expect(await count('transactions'), 0);
    expect(await count('notification_log_events'), 0);
    final bSettings = await settingsRow();
    expect(bSettings['display_name'], isNot('User A'));
    expect(bSettings['avatar_path'], isNot(photoA));
    final photoB = await setAvatar('B');
    expect(photoB, isNot(photoA));
    expect(File(photoA).readAsStringSync(), 'A',
        reason: "B's photo never overwrites A's file");
    await session.signOut();

    await f.signIn('uid-a');
    expect(f.host.current!.uid, 'uid-a');
    expect(await count('transactions'), 1);
    expect(await count('notification_log_events'), 1);
    final aSettings = await settingsRow();
    expect(aSettings['avatar_path'], photoA);
    expect(aSettings['display_name'], 'User A');
    expect(File(photoA).readAsStringSync(), 'A');
    expect(File(photoB).readAsStringSync(), 'B');
    final rows = await db().customSelect('SELECT id FROM transactions;').get();
    expect(rows.map((r) => r.read<String>('id')), ['tx-a'],
        reason: "B's own rows never leak into A either");
  });

  test(
      "12: A's cleanup failed -> B refused with LocalDataOwnershipException, "
      'A stays locked and intact; a retry after the cleanup succeeds admits B',
      () async {
    var purgeOk = true;
    session.configureCaptureOwnerClear(() async => purgeOk);

    await f.signIn('uid-a');
    await seed('a');
    purgeOk = false;
    await session.signOut(); // residue purge fails: marker stays A
    expect(await session.readLocalDataOwnerUid(), 'uid-a');

    Object? error;
    try {
      await f.signIn('uid-b');
    } catch (e) {
      error = e;
    }
    expect(error, isA<LocalDataOwnershipException>());
    expect(error.toString(), contains('previous account'));
    expect(session.status, isNot(SessionStatus.authenticated));
    expect(f.host.current?.uid, isNot('uid-b'));
    expect(await f.artifactsOf('uid-b'), isEmpty,
        reason: 'no replica is created for a refused identity');
    expect(await f.artifactsOf('uid-a'), ['dir', 'key', 'registry']);
    expect(await session.readLocalDataOwnerUid(), 'uid-a');

    // A second attempt while the cleanup still fails is refused too.
    await expectLater(
        f.signIn('uid-b'), throwsA(isA<LocalDataOwnershipException>()));

    // The cleanup now succeeds: the retry admits B on B's own empty replica.
    purgeOk = true;
    await f.signIn('uid-b');
    expect(session.status, SessionStatus.authenticated);
    expect(f.host.current!.uid, 'uid-b');
    expect(await session.readLocalDataOwnerUid(), 'uid-b');
    expect(await count('transactions'), 0);
    expect(await f.artifactsOf('uid-a'), ['dir', 'key', 'registry'],
        reason: "A's data is locked, not wiped");

    await session.signOut();
    await f.signIn('uid-a');
    expect(await count('transactions'), 1);
  });
}
