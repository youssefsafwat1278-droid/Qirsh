import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/backend/supabase_config.dart';
import '../../core/session/account_fence_authority.dart';
import '../../core/session/admission_authority.dart';
import '../../core/session/app_session.dart';
import '../../core/sync/outbox_failure.dart';
import '../../core/sync/sync_health.dart';
import '../../data/db/app_database.dart';
import '../../data/db/sql_value_codec.dart';
import '../../data/sync/sync_cursor.dart';
import 'profile_image_store.dart';

/// The profile photo's Cloud Sync copy: one private object per account at
/// `profile-photos/<uid>/avatar` (migration 20261116210000).
///
/// Why Storage and not the encrypted backup archive: the archive exists only
/// for users who turned on the passphrase backup, while the photo should come
/// back for everyone on Cloud Sync, like the name and phone that already sync
/// with `user_settings`. Storage is reached through the same gated Supabase
/// transport as every other upload, and the deletion worker already sweeps
/// the user's Storage folders.
///
/// One run (inside the planning sync cycle, or right after a new pick):
///  * gates, all read fresh, default DENY: a signed-in owner that matches the
///    account fence, Cloud consent ([EgressClass.profileAndSettings] via the
///    injected `mayEgress`), an HTTPS endpoint, and the server capability
///    `profile_photo_backup`. Revoking consent stops the next run.
///  * the local photo is THIS account's when its file sits directly in the
///    account's own folder (`profile/<owner key>/`) or the pre-account shared
///    folder (`profile/`). A path into another account's folder is never
///    uploaded, so a photo cannot cross accounts on one device.
///  * a photo whose bytes differ from the last upload (SHA-256 kept in the
///    replica's `sync_cursors`, which sign-out wipes and backups exclude) is
///    uploaded, overwriting the previous one. Only recognised image bytes go.
///  * no usable local photo (none set, the file is gone after a reinstall or a
///    restore from another phone, or it belongs to another account): download
///    this account's photo, store it in the account's own folder and point the
///    settings at it. "Nothing in the cloud" is remembered, so an account
///    without a photo costs one request per replica, not one per cycle.
///
/// Erasure is server-side (account deletion sweeps the bucket); this service
/// never deletes the cloud copy.
enum ProfilePhotoSyncOutcome {
  /// A gate refused, another run was in flight, or the run went stale.
  skipped,

  /// The cloud copy already matches (or this account was checked and has none).
  upToDate,
  uploaded,
  restored,

  /// Nothing local and nothing in the cloud.
  absent,
  failed,
}

/// Injectable remote; the real one is Supabase Storage, tests use a fake.
abstract interface class ProfilePhotoRemote {
  Future<void> upload(String objectPath, Uint8List bytes,
      {required String contentType});

  /// The object's bytes, or null when there is no such object. Throws on any
  /// other failure (never reported as "absent").
  Future<Uint8List?> download(String objectPath, {required int maxBytes});
}

class SupabaseProfilePhotoRemote implements ProfilePhotoRemote {
  const SupabaseProfilePhotoRemote();

  @override
  Future<void> upload(String objectPath, Uint8List bytes,
      {required String contentType}) async {
    await Supabase.instance.client.storage
        .from(ProfilePhotoSyncService.bucket)
        .uploadBinary(objectPath, bytes,
            fileOptions: FileOptions(upsert: true, contentType: contentType));
  }

  @override
  Future<Uint8List?> download(String objectPath,
      {required int maxBytes}) async {
    try {
      final bytes = await Supabase.instance.client.storage
          .from(ProfilePhotoSyncService.bucket)
          .download(objectPath);
      if (bytes.length > maxBytes) throw StateError('profile_photo_too_large');
      return bytes;
    } on StorageException catch (e) {
      if (e.statusCode == '404' || e.error == 'not_found') return null;
      rethrow;
    }
  }
}

class ProfilePhotoSyncService {
  ProfilePhotoSyncService({
    required AppDatabase db,
    ProfilePhotoRemote? remote,
    Future<String?> Function()? getAuthUserId,

    /// Cloud consent, asked fresh per run. Defaults to DENY.
    Future<bool> Function()? mayEgress,

    /// The `profile_photo_backup` server capability. Defaults to NOT ready.
    Future<bool> Function()? serverReady,

    /// Whether the configured backend is reached over HTTPS.
    bool Function()? endpointIsHttps,
    Future<Directory> Function()? documents,
    SyncHealth? health,
    DateTime Function() now = DateTime.now,
  })  : _db = db,
        _remote = remote ?? const SupabaseProfilePhotoRemote(),
        _getAuthUserId = getAuthUserId ?? _defaultUid,
        _mayEgress = mayEgress ?? _deny,
        _serverReady = serverReady ?? _deny,
        _endpointIsHttps = endpointIsHttps ?? configuredEndpointIsHttps,
        _documents = documents ?? getApplicationDocumentsDirectory,
        _health = health,
        _now = now;

  static const bucket = 'profile-photos';
  static const maxBytes = 5 * 1024 * 1024; // the bucket's file_size_limit
  static const absentMarker = 'absent';
  static String objectPathFor(String uid) => '$uid/avatar';
  static String markerKey(String uid) => 'profile_photo:$uid';

  static Future<bool> _deny() async => false;
  static Future<String?> _defaultUid() async {
    if (!SupabaseConfig.isConfigured) return null;
    try {
      return Supabase.instance.client.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static bool configuredEndpointIsHttps() =>
      Uri.tryParse(SupabaseConfig.url)?.scheme == 'https';

  final AppDatabase _db;
  final ProfilePhotoRemote _remote;
  final Future<String?> Function() _getAuthUserId;
  final Future<bool> Function() _mayEgress;
  final Future<bool> Function() _serverReady;
  final bool Function() _endpointIsHttps;
  final Future<Directory> Function() _documents;
  final SyncHealth? _health;
  final DateTime Function() _now;
  bool _busy = false;

  Future<ProfilePhotoSyncOutcome> sync() => syncWithPhase(SyncPhaseBinding());

  Future<ProfilePhotoSyncOutcome> syncWithPhase(SyncPhaseBinding phase) async {
    if (_busy) return ProfilePhotoSyncOutcome.skipped;
    _busy = true;
    try {
      final inherited = phase.isBound ? phase : null;
      if (inherited != null &&
          (!inherited.isCurrent || !identical(inherited.database, _db))) {
        return ProfilePhotoSyncOutcome.skipped;
      }
      final authority = AccountFenceAuthority.shared;
      final handle =
          await authority.captureForDatabase(AppSession.instance, _db);
      if (handle == null) return ProfilePhotoSyncOutcome.skipped;
      final run = _PhotoInvocation(authority, handle, _db, inherited);
      if (!phase.isBound) phase.bind(run);
      final uid = await _getAuthUserId();
      if (uid == null ||
          uid.isEmpty ||
          uid != authority.ownerUid(handle) ||
          !run.isCurrent) {
        return ProfilePhotoSyncOutcome.skipped;
      }
      if (!await _mayEgress()) {
        phase.noteConsentBlocked(_health);
        return ProfilePhotoSyncOutcome.skipped;
      }
      if (!_endpointIsHttps()) return ProfilePhotoSyncOutcome.skipped;
      if (!await _serverReady() || !run.isCurrent) {
        return ProfilePhotoSyncOutcome.skipped;
      }
      try {
        return await _reconcile(run, uid);
      } on StaleAdmissionException {
        rethrow;
      } on AccountFenceDeliveryCancellation {
        rethrow;
      } catch (e) {
        phase.noteFailure(_health, e);
        if (kDebugMode) debugPrint('[ProfilePhotoSync] ${e.runtimeType}');
        return ProfilePhotoSyncOutcome.failed;
      }
    } on StaleAdmissionException {
      return ProfilePhotoSyncOutcome.skipped;
    } finally {
      _busy = false;
    }
  }

  Future<ProfilePhotoSyncOutcome> _reconcile(
      _PhotoInvocation run, String uid) async {
    final documents = await _documents();
    final avatarPath = await run.runLocal(_readAvatarPath);
    final marker = await run.runLocal(() => _readMarker(uid));
    final local = ownedPhotoFile(documents, uid, avatarPath);
    if (local != null && await local.exists()) {
      return _upload(run, uid, local, marker);
    }
    if (marker == absentMarker) return ProfilePhotoSyncOutcome.upToDate;
    return _restore(run, uid, documents, avatarPath);
  }

  Future<ProfilePhotoSyncOutcome> _upload(
      _PhotoInvocation run, String uid, File file, String? marker) async {
    final bytes = await file.readAsBytes();
    final type = imageContentType(bytes);
    if (bytes.length > maxBytes || type == null) {
      return ProfilePhotoSyncOutcome.skipped;
    }
    final hash = sha256.convert(bytes).toString();
    if (marker == hash) return ProfilePhotoSyncOutcome.upToDate;
    if (!run.isCurrent) return ProfilePhotoSyncOutcome.skipped;
    await _remote.upload(objectPathFor(uid), bytes, contentType: type);
    if (!run.isCurrent) return ProfilePhotoSyncOutcome.skipped;
    await run.runLocal(() => _writeMarker(uid, hash));
    return ProfilePhotoSyncOutcome.uploaded;
  }

  Future<ProfilePhotoSyncOutcome> _restore(_PhotoInvocation run, String uid,
      Directory documents, String? avatarPathBefore) async {
    final bytes = await _remote.download(objectPathFor(uid), maxBytes: maxBytes);
    if (!run.isCurrent) return ProfilePhotoSyncOutcome.skipped;
    if (bytes == null) {
      await run.runLocal(() => _writeMarker(uid, absentMarker));
      return ProfilePhotoSyncOutcome.absent;
    }
    final extension = imageExtension(bytes);
    if (extension == null || bytes.length > maxBytes) {
      throw const FormatException('profile_photo_not_an_image');
    }
    final dir = profileDirOf(documents, uid);
    if (!await dir.exists()) await dir.create(recursive: true);
    final destination = File(p.join(
        dir.path, 'avatar_${_now().microsecondsSinceEpoch}$extension'));
    await destination.writeAsBytes(bytes, flush: true);
    var applied = false;
    try {
      applied = await run.runLocal(() => _db.transaction(() async {
            // The user may have picked a photo while this was downloading:
            // that newer choice wins and the download is discarded.
            if (await _readAvatarPath() != avatarPathBefore) return false;
            await _db.customStatement(
                'UPDATE user_settings SET avatar_path = ?, updated_at = ?;', [
              destination.path,
              dateTimeToSql(_now().toUtc()),
            ]);
            await _writeMarker(uid, sha256.convert(bytes).toString());
            return true;
          }));
    } finally {
      if (!applied) {
        try {
          await destination.delete();
        } catch (_) {}
      }
    }
    return applied
        ? ProfilePhotoSyncOutcome.restored
        : ProfilePhotoSyncOutcome.skipped;
  }

  // ─────────────────────────────────────────────────────────── helpers

  /// [path] as this account's photo file, or null when it is empty or lies
  /// anywhere but directly in [uid]'s own folder or the shared pre-account
  /// folder (in particular: never another account's folder).
  static File? ownedPhotoFile(Directory documents, String uid, String? path) {
    final trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    final parent = p.normalize(p.dirname(p.normalize(trimmed)));
    final own = p.normalize(profileDirOf(documents, uid).path);
    final shared = p.normalize(profileDirOf(documents, null).path);
    if (parent != own && parent != shared) return null;
    return File(trimmed);
  }

  /// The MIME type of recognised image bytes (what the bucket accepts), or null.
  static String? imageContentType(List<int> b) => switch (imageExtension(b)) {
        '.jpg' => 'image/jpeg',
        '.png' => 'image/png',
        '.webp' => 'image/webp',
        '.heic' => 'image/heic',
        _ => null,
      };

  static String? imageExtension(List<int> b) {
    bool at(int offset, List<int> sig) {
      if (b.length < offset + sig.length) return false;
      for (var i = 0; i < sig.length; i++) {
        if (b[offset + i] != sig[i]) return false;
      }
      return true;
    }

    if (at(0, const [0xFF, 0xD8, 0xFF])) return '.jpg';
    if (at(0, const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) {
      return '.png';
    }
    if (at(0, 'RIFF'.codeUnits) && at(8, 'WEBP'.codeUnits)) return '.webp';
    if (at(4, 'ftyp'.codeUnits) &&
        const ['heic', 'heix', 'heif', 'mif1', 'msf1', 'hevc']
            .any((brand) => at(8, brand.codeUnits))) {
      return '.heic';
    }
    return null;
  }

  Future<String?> _readAvatarPath() async {
    final row = await _db
        .customSelect('SELECT avatar_path FROM user_settings LIMIT 1;')
        .getSingleOrNull();
    return row?.readNullable<String>('avatar_path');
  }

  Future<String?> _readMarker(String uid) async {
    final row = await _db
        .customSelect('SELECT last_id FROM sync_cursors '
            'WHERE entity = ${sqlString(markerKey(uid))} LIMIT 1;')
        .getSingleOrNull();
    return row?.read<String>('last_id');
  }

  Future<void> _writeMarker(String uid, String value) => writeSyncCursor(
      _db, markerKey(uid), SyncCursor(updatedAt: syncCursorEpoch, id: value));
}

class _PhotoInvocation implements SyncPhaseLifecycle {
  _PhotoInvocation(this.authority, this.handle, this.database, this.inherited);
  final AccountFenceAuthority authority;
  final AccountFenceHandle handle;
  @override
  final AppDatabase database;
  final SyncPhaseBinding? inherited;

  @override
  bool get isCurrent =>
      authority.isCurrentForDatabase(handle, database) &&
      (inherited == null || inherited!.isCurrent);

  @override
  Future<T> runLocal<T>(Future<T> Function() action) {
    if (!isCurrent) throw const StaleAdmissionException();
    return authority.runCurrentLocal(handle, database, action);
  }
}
