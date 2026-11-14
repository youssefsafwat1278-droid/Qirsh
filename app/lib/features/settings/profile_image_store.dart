import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The per-account folder name under `<documents>/profile/` (opaque: no uid).
String profileOwnerKey(String uid) => sha256
    .convert(utf8.encode('qirsh.profile:$uid'))
    .toString()
    .substring(0, 32);

/// `<documents>/profile/<owner key>/` for [ownerUid]; the legacy shared
/// `<documents>/profile/` when no account is known.
Directory profileDirOf(Directory documents, String? ownerUid) {
  final root = p.join(documents.path, 'profile');
  return ownerUid == null || ownerUid.isEmpty
      ? Directory(root)
      : Directory(p.join(root, profileOwnerKey(ownerUid)));
}

/// Copies a picked profile photo into the account's own folder
/// (`<documents>/profile/<owner key>/`) under a name of its own and returns
/// the new path.
///
/// Every pick gets a fresh file name: the path is stored in the signed-in
/// account's own settings, so two accounts on one device never share (and
/// never overwrite) one photo file, and a new photo is never served from the
/// image cache of the old path. The account's previous photo is deleted, but
/// only when it is a file inside `profile/`. The per-account folder is what
/// removing the account's data deletes ([deleteProfileImagesOf]).
Future<String> storeProfileImage({
  required String pickedPath,
  required Directory documents,
  String? previousPath,
  String? ownerUid,
  DateTime Function() now = DateTime.now,
}) async {
  final extension = p.extension(pickedPath).isEmpty
      ? '.jpg'
      : p.extension(pickedPath).toLowerCase();
  final dir = profileDirOf(documents, ownerUid);
  if (!await dir.exists()) await dir.create(recursive: true);
  final destination =
      p.join(dir.path, 'avatar_${now().microsecondsSinceEpoch}$extension');
  await File(pickedPath).copy(destination);
  final previous = previousPath?.trim();
  if (previous != null &&
      previous.isNotEmpty &&
      previous != destination &&
      p.isWithin(p.join(documents.path, 'profile'), previous)) {
    try {
      await File(previous).delete();
    } catch (_) {
      // Already gone, or not deletable: the new photo is saved either way.
    }
  }
  return destination;
}

/// Deletes [uid]'s profile photo folder (removal of the account's data).
Future<void> deleteProfileImagesOf(
    {required Directory documents, required String uid}) async {
  if (uid.isEmpty) return;
  final dir = profileDirOf(documents, uid);
  if (await dir.exists()) await dir.delete(recursive: true);
}
