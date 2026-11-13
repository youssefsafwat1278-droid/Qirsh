import 'dart:io';

import 'package:path/path.dart' as p;

/// Copies a picked profile photo into `<documents>/profile/` under a name of
/// its own and returns the new path.
///
/// Every pick gets a fresh file name: the path is stored in the signed-in
/// account's own settings, so two accounts on one device never share (and
/// never overwrite) one photo file, and a new photo is never served from the
/// image cache of the old path. The account's previous photo is deleted, but
/// only when it is a file inside the same `profile/` directory.
Future<String> storeProfileImage({
  required String pickedPath,
  required Directory documents,
  String? previousPath,
  DateTime Function() now = DateTime.now,
}) async {
  final extension = p.extension(pickedPath).isEmpty
      ? '.jpg'
      : p.extension(pickedPath).toLowerCase();
  final dir = Directory(p.join(documents.path, 'profile'));
  if (!await dir.exists()) await dir.create(recursive: true);
  final destination =
      p.join(dir.path, 'avatar_${now().microsecondsSinceEpoch}$extension');
  await File(pickedPath).copy(destination);
  final previous = previousPath?.trim();
  if (previous != null &&
      previous.isNotEmpty &&
      previous != destination &&
      p.isWithin(dir.path, previous)) {
    try {
      await File(previous).delete();
    } catch (_) {
      // Already gone, or not deletable: the new photo is saved either way.
    }
  }
  return destination;
}
