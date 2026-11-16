import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/features/settings/profile_image_store.dart';
import 'package:money_companion/features/settings/profile_photo_sync_service.dart';

import '../capture/ledger_admission_fixture.dart';

/// `profile-photos` as Storage RLS enforces it (migration 20261116210000): a
/// caller reaches ONLY `<its uid>/avatar`; anything else is refused.
class _FakePhotoBucket {
  final objects = <String, Uint8List>{};
  final calls = <String>[];
}

class _FakeRemote implements ProfilePhotoRemote {
  _FakeRemote(this.bucket, this.callerUid);
  final _FakePhotoBucket bucket;
  final String callerUid;
  Future<void> Function()? beforeDownloadReturns;
  Object? failWith;

  void _admit(String path) {
    if (path != '$callerUid/avatar') {
      throw StateError('rls_denied:$path');
    }
  }

  @override
  Future<void> upload(String objectPath, Uint8List bytes,
      {required String contentType}) async {
    bucket.calls.add('upload:$objectPath:$contentType');
    if (failWith != null) throw failWith!;
    _admit(objectPath);
    bucket.objects[objectPath] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> download(String objectPath,
      {required int maxBytes}) async {
    bucket.calls.add('download:$objectPath');
    if (failWith != null) throw failWith!;
    _admit(objectPath);
    final bytes = bucket.objects[objectPath];
    await beforeDownloadReturns?.call();
    return bytes == null ? null : Uint8List.fromList(bytes);
  }
}

final _jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5]);
final _jpeg2 = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE1, 9, 9, 9]);
final _png = Uint8List.fromList(
    [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]);

void main() {
  late LedgerAdmissionFixture fixture;
  late AppDatabase db;
  late Directory documents;
  late _FakePhotoBucket bucket;

  setUp(() async {
    fixture = await LedgerAdmissionFixture.open('user-1');
    db = fixture.database;
    documents = await Directory.systemTemp.createTemp('profile_photo_sync');
    bucket = _FakePhotoBucket();
  });
  tearDown(() async {
    await fixture.finish();
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  ProfilePhotoSyncService service({
    String? authUid = 'user-1',
    bool consent = true,
    bool capability = true,
    bool https = true,
    _FakeRemote? remote,
  }) =>
      ProfilePhotoSyncService(
        db: db,
        remote: remote ?? _FakeRemote(bucket, authUid ?? 'nobody'),
        getAuthUserId: () async => authUid,
        mayEgress: () async => consent,
        serverReady: () async => capability,
        endpointIsHttps: () => https,
        documents: () async => documents,
      );

  Future<String?> avatarPath() async => (await db
          .customSelect('SELECT avatar_path FROM user_settings LIMIT 1;')
          .getSingle())
      .readNullable<String>('avatar_path');

  Future<void> setAvatarPath(String? path) =>
      db.customStatement('UPDATE user_settings SET avatar_path = ?;', [path]);

  /// A photo picked in the app, stored the way settings_screen stores it.
  Future<String> pick(Uint8List bytes, {String? owner = 'user-1'}) async {
    final picked = File(p.join(documents.path, 'picked_${bytes.length}.jpg'));
    await picked.writeAsBytes(bytes);
    final stored = await storeProfileImage(
        pickedPath: picked.path,
        documents: documents,
        previousPath: await avatarPath(),
        ownerUid: owner);
    await setAvatarPath(stored);
    return stored;
  }

  group('upload is gated', () {
    test('Cloud consent off: nothing is sent', () async {
      await pick(_jpeg);
      expect(await service(consent: false).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.calls, isEmpty);
    });

    test('signed out: nothing is sent', () async {
      await pick(_jpeg);
      expect(await service(authUid: null).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.calls, isEmpty);
    });

    test('capability not advertised, or not HTTPS: nothing is sent', () async {
      await pick(_jpeg);
      expect(await service(capability: false).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(await service(https: false).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.calls, isEmpty);
    });

    test('consent on: uploaded once to <uid>/avatar; revoking stops the next',
        () async {
      await pick(_jpeg);
      expect(await service().sync(), ProfilePhotoSyncOutcome.uploaded);
      expect(bucket.objects['user-1/avatar'], _jpeg);
      expect(bucket.calls, ['upload:user-1/avatar:image/jpeg']);

      // Same bytes: no second upload.
      expect(await service().sync(), ProfilePhotoSyncOutcome.upToDate);
      expect(bucket.calls, hasLength(1));

      // A new photo while consent is revoked is not sent...
      await pick(_png);
      expect(await service(consent: false).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.objects['user-1/avatar'], _jpeg);
      expect(bucket.calls, hasLength(1));

      // ...and goes once consent is back.
      expect(await service().sync(), ProfilePhotoSyncOutcome.uploaded);
      expect(bucket.objects['user-1/avatar'], _png);
      expect(bucket.calls.last, 'upload:user-1/avatar:image/png');
    });

    test('a file that is not an image is never uploaded', () async {
      final path = await pick(Uint8List.fromList('%PDF-1.7 secret'.codeUnits));
      expect(File(path).existsSync(), isTrue);
      expect(await service().sync(), isNot(ProfilePhotoSyncOutcome.uploaded));
      expect(bucket.calls.where((c) => c.startsWith('upload')), isEmpty);
    });

    test('a failed upload is reported and retried by the next run', () async {
      await pick(_jpeg);
      final failing = _FakeRemote(bucket, 'user-1')
        ..failWith = const SocketException('offline');
      expect(await service(remote: failing).sync(),
          ProfilePhotoSyncOutcome.failed);
      expect(await service().sync(), ProfilePhotoSyncOutcome.uploaded);
      expect(bucket.objects['user-1/avatar'], _jpeg);
    });
  });

  group('restore', () {
    test('after a reinstall the photo comes back into the account folder',
        () async {
      bucket.objects['user-1/avatar'] = _jpeg;
      expect(await avatarPath(), isNull);

      expect(await service().sync(), ProfilePhotoSyncOutcome.restored);

      final restored = await avatarPath();
      expect(restored, isNotNull);
      expect(p.dirname(restored!), profileDirOf(documents, 'user-1').path);
      expect(p.extension(restored), '.jpg');
      expect(await File(restored).readAsBytes(), _jpeg);
      // It is now the uploaded copy: the next run neither uploads nor downloads.
      final before = bucket.calls.length;
      expect(await service().sync(), ProfilePhotoSyncOutcome.upToDate);
      expect(bucket.calls, hasLength(before));
    });

    test('a path restored from another phone (file missing) is replaced',
        () async {
      bucket.objects['user-1/avatar'] = _png;
      await setAvatarPath('/var/old-phone/Documents/profile/x/avatar_1.jpg');
      expect(await service().sync(), ProfilePhotoSyncOutcome.restored);
      expect(await File((await avatarPath())!).readAsBytes(), _png);
    });

    test('no photo in the cloud: asked once per replica, then remembered',
        () async {
      expect(await service().sync(), ProfilePhotoSyncOutcome.absent);
      expect(await service().sync(), ProfilePhotoSyncOutcome.upToDate);
      expect(bucket.calls, ['download:user-1/avatar']);
      expect(await avatarPath(), isNull);
    });

    test('no download while consent is off', () async {
      bucket.objects['user-1/avatar'] = _jpeg;
      expect(await service(consent: false).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.calls, isEmpty);
      expect(await avatarPath(), isNull);
    });

    test('a photo picked while the download runs wins', () async {
      bucket.objects['user-1/avatar'] = _jpeg;
      late String picked;
      final remote = _FakeRemote(bucket, 'user-1')
        ..beforeDownloadReturns = () async => picked = await pick(_png);
      expect(await service(remote: remote).sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(await avatarPath(), picked);
      // The discarded download left no file behind.
      final files = profileDirOf(documents, 'user-1').listSync();
      expect(files.map((f) => f.path), [picked]);
    });
  });

  group('account isolation', () {
    test('a signed-in identity other than the fenced owner does nothing',
        () async {
      bucket.objects['user-2/avatar'] = _jpeg;
      await pick(_png);
      expect(await service(authUid: 'user-2').sync(),
          ProfilePhotoSyncOutcome.skipped);
      expect(bucket.calls, isEmpty);
      expect(bucket.objects['user-2/avatar'], _jpeg);
    });

    test('a photo in another account\'s folder is never uploaded', () async {
      // The settings point at a file of user-2 (e.g. an old local backup).
      final foreign = await pick(_png, owner: 'user-2');
      bucket.objects['user-1/avatar'] = _jpeg;

      expect(await service().sync(), ProfilePhotoSyncOutcome.restored);

      expect(bucket.calls.where((c) => c.startsWith('upload')), isEmpty);
      // user-1 gets its OWN photo; user-2's file is untouched.
      expect(await File((await avatarPath())!).readAsBytes(), _jpeg);
      expect(await File(foreign).readAsBytes(), _png);
    });

    test('only <own uid>/avatar is ever addressed', () async {
      await pick(_jpeg);
      await service().sync();
      await setAvatarPath(null);
      await db.customStatement('DELETE FROM sync_cursors WHERE entity = ?;',
          [ProfilePhotoSyncService.markerKey('user-1')]);
      await service().sync();
      expect(bucket.calls, hasLength(2));
      expect(bucket.calls, everyElement(contains(':user-1/avatar')));
    });

    test('a photo picked before sign-in (shared folder) is this account\'s',
        () async {
      await pick(_jpeg, owner: null);
      expect(await service().sync(), ProfilePhotoSyncOutcome.uploaded);
      expect(bucket.objects['user-1/avatar'], _jpeg);
    });

    test('ownedPhotoFile accepts only the own and the shared folder', () {
      final own = p.join(profileDirOf(documents, 'user-1').path, 'avatar_1.jpg');
      final shared = p.join(profileDirOf(documents, null).path, 'avatar_1.jpg');
      final other = p.join(profileDirOf(documents, 'user-2').path, 'avatar_1.jpg');
      expect(ProfilePhotoSyncService.ownedPhotoFile(documents, 'user-1', own),
          isNotNull);
      expect(
          ProfilePhotoSyncService.ownedPhotoFile(documents, 'user-1', shared),
          isNotNull);
      expect(ProfilePhotoSyncService.ownedPhotoFile(documents, 'user-1', other),
          isNull);
      expect(
          ProfilePhotoSyncService.ownedPhotoFile(
              documents, 'user-1', p.join(documents.path, 'elsewhere.jpg')),
          isNull);
      expect(
          ProfilePhotoSyncService.ownedPhotoFile(documents, 'user-1',
              p.join(profileDirOf(documents, 'user-1').path, '..', '..', 'x.jpg')),
          isNull);
    });
  });

  test('the remembered upload hash is the exact bytes sent', () async {
    await pick(_jpeg2);
    await service().sync();
    final marker = await db
        .customSelect('SELECT last_id FROM sync_cursors WHERE entity = ?;',
            variables: [
              Variable.withString(ProfilePhotoSyncService.markerKey('user-1'))
            ])
        .getSingle();
    expect(marker.read<String>('last_id'), sha256.convert(_jpeg2).toString());
  });
}
