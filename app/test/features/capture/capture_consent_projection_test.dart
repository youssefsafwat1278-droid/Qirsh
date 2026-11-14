import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/session/admission_authority.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/data/db/database_key_store.dart';
import 'package:money_companion/data/repositories/drift_user_settings_repository.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/capture/services/capture_backend_client.dart';
import 'package:money_companion/features/capture/services/capture_consent_client.dart';
import 'package:money_companion/features/capture/services/capture_device_registration_service.dart';

// WP-6 — the capture-owner gate (manifest §4.2/§4.6): the owner is published
// only after link_capture_device(consent) succeeded, the per-owner mirror
// follows the replica's own versioned consent, and a revocation reaches the
// device first and the server through set_capture_consent.

class _MemoryKeyStore implements DatabaseKeyStore {
  @override
  Future<String> readOrCreateKey() async => 'memory-key';
  @override
  Future<String?> readStoredKey() async => 'memory-key';
}

typedef _Consent = ({bool cloud, bool ai, int version});

class _Backend extends CaptureBackendClient {
  _Backend() : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  int registers = 0;
  @override
  Future<String> registerDevice(
      {required String installId, String platform = 'ios'}) async {
    registers++;
    return 'device-secret';
  }

  final unlinks = <({String installId, String deviceSecret})>[];
  @override
  Future<void> unlinkDevice(
      {required String installId, required String deviceSecret}) async {
    unlinks.add((installId: installId, deviceSecret: deviceSecret));
  }
}

/// Records every call into the shared [events] log so ordering is assertable.
class _ConsentServer extends CaptureConsentClient {
  _ConsentServer(this.events)
      : super(supabaseUrl: 'https://x.invalid', anonKey: 'anon');
  final List<String> events;
  final links = <_Consent>[];
  final sets = <_Consent>[];
  Object? linkError;
  Object? setError;

  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  required int clientGeneration,
  }) async {
    events.add('link');
    if (linkError != null) throw linkError!;
    links.add((cloud: cloud, ai: ai, version: version));
  }

  @override
  Future<void> setConsent({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  required int clientGeneration,
  }) async {
    events.add('set');
    if (setError != null) throw setError!;
    sets.add((cloud: cloud, ai: ai, version: version));
  }

  /// Astra G C.3: the one-shot revoke is its own call, not a `set`.
  final revokes = <_Consent>[];

  @override
  Future<RevokeResult> revoke({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required String ownerUid,
    required int transitionGeneration,
    required int version,
  }) async {
    events.add('revoke');
    if (setError != null) throw setError!;
    revokes.add((cloud: false, ai: false, version: version));
    return const RevokeResult(ok: true, applied: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DriftUserSettingsRepository repo;
  late List<String> events;
  late _ConsentServer server;
  late _Backend backend;
  late List<(String, _Consent)> mirrors;
  late List<String> published;
  CaptureSession? session;
  String? replicaOwner;

  CaptureDeviceRegistrationService service() =>
      CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: server,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        writeNativeBackendConfig: ({
          required cloudProcessingEnabled,
          required installId,
          deviceSecret,
          required backendUrl,
          required anonKey,
          required aiConsentGranted,
          String? ownerUid,
          int? transitionGeneration,
        }) async {},
        loadApnsToken: () async => null,
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        int? transitionGeneration,
        }) async {
          events.add('mirror');
          mirrors.add((uid, (cloud: cloud, ai: ai, version: version)));
        },
        // A-12-min R4: ONE native call writes the mirror first, then the owner.
        readOwnerEpoch: () async => 0,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        int? transitionGeneration,
          }) async {
          events.add('mirror');
          mirrors.add((uid, (cloud: cloud, ai: ai, version: version)));
          events.add('publish');
          published.add(uid);
        },
      );

  Future<UserSettingsEntity> save(
      {ConsentState? cloud, ConsentState? ai}) async {
    final s = await repo.getSettings();
    return repo.saveSettings(
        s.copyWith(cloudConsentState: cloud, aiConsentState: ai));
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    CaptureDeviceRegistrationService.debugResetUnlinkTarget();
    db = await AppDatabase.open(
        executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
    repo = DriftUserSettingsRepository(db);
    events = [];
    server = _ConsentServer(events);
    backend = _Backend();
    mirrors = [];
    published = [];
    session = (uid: 'uid-a', jwt: 'jwt-a');
    replicaOwner = 'uid-a';
  });
  tearDown(() async => db.close());

  group('WP-8 read-only diagnostics accessors', () {
    test('ack snapshot and mirror version follow the projection', () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      expect(await s.consentAckSnapshot(), isNull);
      expect(s.mirroredConsentVersion, isNull);

      await s.linkToCurrentUser();
      expect(await s.consentAckSnapshot(), (cloud: true, ai: true, version: 1));
      expect(s.mirroredConsentVersion, 1);
    });

    test('another user\'s acknowledgement is never reported', () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'jwt-b');
      expect(await s.consentAckSnapshot(), isNull);
      expect(s.mirroredConsentVersion, isNull);
    });
  });

  group('owner publication is gated on link_capture_device(consent)', () {
    test('publishes only AFTER the link succeeded, and writes the mirror first',
        () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);

      await service().linkToCurrentUser();

      expect(events, ['link', 'mirror', 'publish']);
      expect(server.links.single, (cloud: true, ai: true, version: 1));
      expect(mirrors.single, ('uid-a', (cloud: true, ai: true, version: 1)));
      expect(published, ['uid-a']);
    });

    test('the owner is NOT published (and no mirror written) when link fails',
        () async {
      await save(cloud: ConsentState.accepted);
      server.linkError = const CaptureBackendException('link_device_failed_500');

      await service().linkToCurrentUser();

      expect(events, ['link']);
      expect(published, isEmpty);
      expect(mirrors, isEmpty);
    });

    test('offline: a failed link then a later success publishes exactly then',
        () async {
      await save(cloud: ConsentState.accepted); // Cloud ON: the link is required
      final s = service();
      server.linkError = const CaptureBackendException('offline');
      await s.linkToCurrentUser();
      expect(published, isEmpty);

      server.linkError = null;
      await s.linkToCurrentUser();
      expect(published, ['uid-a']);
    });

    test('no session, or a session that is not the admitted replica: no link',
        () async {
      session = null;
      await service().linkToCurrentUser();
      session = (uid: 'uid-b', jwt: 'jwt-b'); // replica belongs to uid-a
      await service().linkToCurrentUser();
      replicaOwner = null;
      session = (uid: 'uid-a', jwt: 'jwt-a');
      await service().linkToCurrentUser();

      expect(events, isEmpty);
      expect(published, isEmpty);
    });

    // A-12-min (updated truthfully): this used to pin an identity-only link for
    // a Cloud-OFF user. Cloud OFF = ZERO EGRESS: the owner is published
    // LOCALLY with an explicit OFF mirror and no server call at all.
    test('cloud OFF and AI OFF publish locally with an OFF mirror, no link',
        () async {
      await service().linkToCurrentUser();
      expect(server.links, isEmpty);
      expect(events, ['mirror', 'publish']);
      expect(mirrors.single.$2, (cloud: false, ai: false, version: 0));
      expect(published, ['uid-a']);
    });

    test('AI is never projected without Cloud (cloud is the master gate)',
        () async {
      await save(cloud: ConsentState.declined, ai: ConsentState.accepted);
      await service().linkToCurrentUser();
      expect(server.links, isEmpty, reason: 'OFF is never linked');
      expect(mirrors.single.$2.cloud, isFalse);
      expect(mirrors.single.$2.ai, isFalse);
    });

    test('a repeat admission with nothing changed does not call the server',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      await s.linkToCurrentUser();
      expect(server.links, hasLength(1));
      expect(published, ['uid-a', 'uid-a'], reason: 'publish is idempotent');
    });

    test('a session lost during the link round trip publishes nothing',
        () async {
      await save(cloud: ConsentState.accepted);
      final slow = _SwitchingServer(events, () => session = null);
      final s = CaptureDeviceRegistrationService(
        settingsRepository: repo,
        client: backend,
        consentClient: slow,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        int? transitionGeneration,
        }) async =>
            events.add('mirror'),
        readOwnerEpoch: () async => 0,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        int? transitionGeneration,
          }) async =>
            events.add('publish'),
      );
      await s.linkToCurrentUser();
      expect(events, ['link']);
    });
  });

  group('a consent change is projected with a version that only grows', () {
    Future<CaptureDeviceRegistrationService> linked() async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      events.clear();
      mirrors.clear();
      return s;
    }

    test('a revoke updates the mirror FIRST and then the server', () async {
      final s = await linked();
      await save(ai: ConsentState.declined);

      await s.syncBackendState();

      expect(events, ['mirror', 'set', 'mirror']);
      expect(mirrors.first.$2, (cloud: true, ai: false, version: 2),
          reason: 'restrictive mirror before the network call');
      expect(server.sets.single, (cloud: true, ai: false, version: 2));
      expect(mirrors.last.$2, (cloud: true, ai: false, version: 2));
    });

    // A-12-min (updated truthfully): the old test pinned a RETRY of the revoke.
    // Cloud OFF = zero egress: the revoke is one-shot and is never retried.
    // E1 (updated truthfully): it is sent by the disableCloud transition, not by
    // the OFF sync. Astra G (updated truthfully): it is the dedicated
    // `revoke_capture_consent` call ('revoke'), no longer a `set_capture_consent`.
    test('a failed revoke still stops the device and is NOT retried', () async {
      final s = await linked();
      server.setError = const CaptureBackendException('offline');

      await s.disableCloud(
          commitLocalOff: () => save(cloud: ConsentState.declined));
      expect(mirrors.single.$2, (cloud: false, ai: false, version: 2));
      expect(server.revokes, isEmpty);
      expect(events.where((e) => e == 'revoke'), hasLength(1));

      server.setError = null;
      events.clear();
      await s.syncBackendState();
      expect(events.where((e) => e == 'revoke' || e == 'set'), isEmpty,
          reason: 'one attempt only; retention covers a call that never lands');
    });

    test('a grant widens the mirror only after the server accepted it',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = service();
      await s.linkToCurrentUser();
      events.clear();
      mirrors.clear();

      await save(ai: ConsentState.accepted);
      server.setError = const CaptureBackendException('offline');
      await s.syncBackendState();
      expect(mirrors.single.$2.ai, isFalse,
          reason: 'an unacknowledged grant is not mirrored');

      server.setError = null;
      await s.syncBackendState();
      expect(mirrors.last.$2, (cloud: true, ai: true, version: 2));
    });

    test('versions sent to the server never decrease', () async {
      final s = await linked(); // link at version 1
      int latest() => [
            ...server.links.map((c) => c.version),
            ...server.sets.map((c) => c.version),
            ...server.revokes.map((c) => c.version),
          ].reduce((a, b) => a > b ? a : b);
      final sent = <int>[latest()];
      for (final step in [
        () => save(ai: ConsentState.declined),
        () => s.disableCloud(
            commitLocalOff: () => save(cloud: ConsentState.declined)),
        // Astra G (updated truthfully): leaving the persistent OFF gate is an
        // explicit enable (a plain save of ON would be reverted to OFF).
        () => s.enableCloudForTest(
            commitLocalOn: () => save(cloud: ConsentState.accepted)),
        () => save(ai: ConsentState.accepted),
      ]) {
        await step();
        await s.syncBackendState();
        // OFF->ON after the one-shot revoke re-links (the ack was cleared), so
        // the version may arrive through link or set.
        sent.add(latest());
      }
      expect(sent, [1, 2, 3, 4, 5]);
      for (var i = 1; i < sent.length; i++) {
        expect(sent[i], greaterThan(sent[i - 1]));
      }
    });

    test('an unchanged state is not re-sent', () async {
      final s = await linked();
      await s.syncBackendState();
      expect(server.sets, isEmpty);
    });

    test('sign-out unlink forgets the acknowledgement: the next admission '
        're-links', () async {
      final s = await linked();
      await s.unlinkCurrentDevice();
      await s.linkToCurrentUser();
      expect(server.links, hasLength(2));
    });
  });

  group('P3: sign-out unlinks the install from the outgoing user', () {
    CaptureDeviceRegistrationService gated(
            bool Function() live, AdmissionAuthority authority) =>
        CaptureDeviceRegistrationService(
          settingsRepository: repo,
          client: backend,
          consentClient: server,
          storage: const FlutterSecureStorage(),
          isIos: () => true,
          isAndroid: () => false,
          isBackendConfigured: () => true,
          loadInstallId: () async => 'install-id',
          readSession: () => session,
          readReplicaOwnerUid: () async => replicaOwner,
          writeConsentMirror: ({
            required uid,
            required cloud,
            required ai,
            required version,
            int? transitionGeneration,
          }) async {},
          readOwnerEpoch: () async => 0,
          publishOwner: ({
            required uid,
            required cloud,
            required ai,
            required version,
            required expectedEpoch,
            int? transitionGeneration,
          }) async =>
              published.add(uid),
          isCurrentScope: live,
          captureWorkAuthority: () => authority,
        );

    test(
        'a Cloud-ON link taken as a ticket before revocation is sent after '
        'the authority went stale and the scope closed', () async {
      await save(cloud: ConsentState.accepted);
      var live = true;
      final authority = AdmissionAuthority('uid-a', () => live);
      final s = gated(() => live, authority);
      await s.linkToCurrentUser();
      expect(server.links, hasLength(1));
      expect(await s.consentAckSnapshot(), isNotNull);

      // signOut: the ticket is taken first, then everything is revoked.
      final ticket = CaptureDeviceRegistrationService.takeUnlinkTicket();
      live = false; // authority stale AND scope no longer current
      session = null;

      // Before the fix: the gated unlink refuses (blocked) and sends nothing.
      await s.unlinkCurrentDevice();
      expect(backend.unlinks, isEmpty);

      expect(ticket, isNotNull);
      expect(ticket!.uid, 'uid-a');
      await ticket.send();
      expect(backend.unlinks,
          [(installId: 'install-id', deviceSecret: 'device-secret')]);
      expect(
          await const FlutterSecureStorage()
              .read(key: 'qirsh_capture_consent_ack'),
          isNull);
      // One-shot: a second take has nothing to send.
      expect(CaptureDeviceRegistrationService.takeUnlinkTicket(), isNull);
    });

    test('the ticket leaves another user\'s ack alone', () async {
      await save(cloud: ConsentState.accepted);
      final s = gated(() => true, const AdmissionAuthority.forTest('uid-a'));
      await s.linkToCurrentUser();
      final ticket = CaptureDeviceRegistrationService.takeUnlinkTicket()!;
      await const FlutterSecureStorage()
          .write(key: 'qirsh_capture_consent_ack', value: 'uid-b|1|0|1');
      await ticket.send();
      expect(backend.unlinks, hasLength(1));
      expect(
          await const FlutterSecureStorage()
              .read(key: 'qirsh_capture_consent_ack'),
          'uid-b|1|0|1');
    });

    test('Cloud OFF: no ticket, no request', () async {
      await save(cloud: ConsentState.declined);
      final s = gated(() => true, const AdmissionAuthority.forTest('uid-a'));
      await s.linkToCurrentUser();
      expect(server.links, isEmpty);
      expect(CaptureDeviceRegistrationService.takeUnlinkTicket(), isNull);
      expect(backend.unlinks, isEmpty);
    });

    test('a cleared ack (Cloud OFF transition / unlink) drops the ticket',
        () async {
      await save(cloud: ConsentState.accepted);
      final s = gated(() => true, const AdmissionAuthority.forTest('uid-a'));
      await s.linkToCurrentUser();
      await s.unlinkCurrentDevice(); // clears the ack (and sends once)
      expect(backend.unlinks, hasLength(1));
      expect(CaptureDeviceRegistrationService.takeUnlinkTicket(), isNull);
    });

    test('an ack confirmed by a later process re-arms the ticket', () async {
      await save(cloud: ConsentState.accepted);
      final s = gated(() => true, const AdmissionAuthority.forTest('uid-a'));
      await s.linkToCurrentUser();
      CaptureDeviceRegistrationService.debugResetUnlinkTarget(); // "restart"
      await gated(() => true, const AdmissionAuthority.forTest('uid-a'))
          .linkToCurrentUser();
      expect(server.links, hasLength(1)); // ack matched: no re-link
      expect(CaptureDeviceRegistrationService.takeUnlinkTicket()?.uid,
          'uid-a');
    });
  });

  group('consent never crosses users', () {
    test("uid A's acknowledged consent is not reused for uid B", () async {
      await save(cloud: ConsentState.accepted, ai: ConsentState.accepted);
      await service().linkToCurrentUser(); // A linked at (true,true,1)

      // B signs in on the same install; B's replica is a different database
      // whose consent is unset.
      final dbB = await AppDatabase.open(
          executor: NativeDatabase.memory(), keyStore: _MemoryKeyStore());
      addTearDown(dbB.close);
      session = (uid: 'uid-b', jwt: 'jwt-b');
      replicaOwner = 'uid-b';
      final b = CaptureDeviceRegistrationService(
        settingsRepository: DriftUserSettingsRepository(dbB),
        client: backend,
        consentClient: server,
        storage: const FlutterSecureStorage(),
        isIos: () => true,
        isAndroid: () => false,
        isBackendConfigured: () => true,
        loadInstallId: () async => 'install-id',
        readSession: () => session,
        readReplicaOwnerUid: () async => replicaOwner,
        writeConsentMirror: ({
          required uid,
          required cloud,
          required ai,
          required version,
        int? transitionGeneration,
        }) async =>
            mirrors.add((uid, (cloud: cloud, ai: ai, version: version))),
        readOwnerEpoch: () async => 0,
        publishOwner: ({
          required uid,
          required cloud,
          required ai,
          required version,
          required expectedEpoch,
        int? transitionGeneration,
          }) async {
          mirrors.add((uid, (cloud: cloud, ai: ai, version: version)));
          published.add(uid);
        },
      );
      mirrors.clear();
      published.clear();

      await b.linkToCurrentUser();

      expect(server.links, hasLength(1),
          reason: "B is OFF: never linked (zero egress); A's ack is not reused");
      expect(mirrors.single, ('uid-b', (cloud: false, ai: false, version: 0)));
      expect(published, ['uid-b']);
    });
  });
}

class _SwitchingServer extends _ConsentServer {
  _SwitchingServer(super.events, this.onLink);
  final void Function() onLink;
  @override
  Future<void> link({
    required String installId,
    required String deviceSecret,
    required String jwt,
    required bool cloud,
    required bool ai,
    required int version,
  required int clientGeneration,
  }) async {
    await super.link(
        installId: installId,
        deviceSecret: deviceSecret,
        jwt: jwt,
        cloud: cloud,
        ai: ai,
        version: version,
        clientGeneration: clientGeneration);
    onLink(); // the user signs out while the request is in flight
  }
}
