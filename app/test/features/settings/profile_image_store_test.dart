import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/features/settings/profile_image_store.dart';
import 'package:path/path.dart' as p;

// Audit P1 (2026-11-14): every account wrote the same `profile/avatar.<ext>`,
// so account B's photo replaced account A's on one device.
void main() {
  late Directory docs;
  late Directory picks;
  var tick = 0;
  DateTime now() => DateTime.fromMicrosecondsSinceEpoch(++tick);

  setUp(() {
    docs = Directory.systemTemp.createTempSync('profile_docs');
    picks = Directory.systemTemp.createTempSync('profile_picks');
  });
  tearDown(() {
    docs.deleteSync(recursive: true);
    picks.deleteSync(recursive: true);
  });

  File pick(String name, String content) =>
      File(p.join(picks.path, name))..writeAsStringSync(content);

  test('two accounts keep two separate photo files', () async {
    final a = await storeProfileImage(
        pickedPath: pick('a.JPG', 'A').path, documents: docs, now: now);
    final b = await storeProfileImage(
        pickedPath: pick('b.png', 'B').path, documents: docs, now: now);
    expect(a, isNot(b));
    expect(File(a).readAsStringSync(), 'A');
    expect(File(b).readAsStringSync(), 'B');
    expect(p.extension(a), '.jpg');
  });

  test("a new photo replaces only this account's previous file", () async {
    final first = await storeProfileImage(
        pickedPath: pick('1.jpg', 'one').path, documents: docs, now: now);
    final second = await storeProfileImage(
        pickedPath: pick('2.jpg', 'two').path,
        documents: docs,
        previousPath: first,
        now: now);
    expect(File(first).existsSync(), isFalse);
    expect(File(second).readAsStringSync(), 'two');
  });

  test('a previous path outside profile/ is never deleted', () async {
    final outside = pick('keep.jpg', 'keep');
    await storeProfileImage(
        pickedPath: pick('3.jpg', 'x').path,
        documents: docs,
        previousPath: outside.path,
        now: now);
    expect(outside.existsSync(), isTrue);
  });
}
