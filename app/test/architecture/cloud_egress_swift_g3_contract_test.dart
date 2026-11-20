import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// G3 (Astra required changes C.1, C.4, C.5, P4, P6): the native cloud-egress
/// denial state (per owner), admission and the in-flight registry in the native
/// processes, owner binding of the intent upload, and generation-guarded native
/// writes.
///
/// Swift cannot run here. The behavioural proof is ios/RunnerTests/
/// RunnerTests.swift (the "G3" section; needs Xcode); these static checks pin
/// the source properties that make it true so a regression fails in Linux CI.
/// Style follows capture_queue_cap6_contract_test.dart.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final storeCopy =
      File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync();
  final intent = File('ios/BankMessageShortcuts/BankMessageShortcuts.swift')
      .readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final share =
      File('ios/ShareBankMessage/ShareViewController.swift').readAsStringSync();
  final xctest = File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();
  final bridge =
      File('lib/features/capture/services/native_capture_bridge.dart')
          .readAsStringSync();

  String body(String source, String signature) {
    final at = source.indexOf(signature);
    expect(at, greaterThan(-1), reason: '$signature not found');
    final open = source.indexOf('{', at + signature.length);
    var depth = 0;
    for (var i = open; i < source.length; i++) {
      if (source[i] == '{') depth++;
      if (source[i] == '}' && --depth == 0) {
        return source.substring(open, i + 1);
      }
    }
    fail('unbalanced braces after $signature');
  }

  group('C.4 durable denial state: both stores, under the flock', () {
    test('the two SharedCaptureStore copies stay byte-identical', () {
      expect(storeCopy, store);
    });

    test('the state is in the shared Keychain AND an App Group file', () {
      expect(store, contains('"cloud_egress_state_v1"'));
      expect(store, contains('"cloud_egress_state_v1.json"'));
      final write = body(store, 'static func setCloudEgressState(');
      expect(write,
          contains('SharedKeychain.writeData(data, forKey: egressStateKC)'));
      expect(write, contains('.atomic'));
      expect(write, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      for (final field in const [
        'state',
        'transitionGeneration',
        'reservedVersion',
      ]) {
        expect(store, contains('let $field:'));
      }
    });

    test('a restrictive write needs one store, an ON write needs both', () {
      final write = body(store, 'static func setCloudEgressState(');
      expect(
          write,
          contains(
              'restrictive ? (fileOK || keychainOK) : (fileOK && keychainOK)'));
    });

    test('the persistent OFF gate is NOT cleared by the sign-out wipe', () {
      final purge = body(store, 'static func purgeUserOwnedState()');
      expect(purge, isNot(contains('egressStateKC')));
      expect(purge, isNot(contains('egressStateFileName')));
      expect(purge, isNot(contains('inflightFileName')));
    });
  });

  group('C.5 per-owner records keyed by uidHash', () {
    test('the stored value is a map keyed by uidHash, never a raw uid', () {
      expect(store, contains('struct CloudEgressMap: Codable, Equatable'));
      expect(store, contains('var owners: [String: CloudEgressRecord]'));
      final record = body(store, 'struct CloudEgressRecord: Codable');
      expect(record, isNot(contains('ownerUid')));
      final write = body(store, 'static func setCloudEgressState(');
      expect(write, contains('let hash = try uidHash(owner)'));
      expect(write, contains('merged[hash] = CloudEgressRecord('));
    });

    test("a write touches only its own owner's entry and keeps the others", () {
      final write = body(store, 'static func setCloudEgressState(');
      // every other owner's entry is merged forward from whichever stores read
      expect(write, contains('for (other, record) in map.owners'));
      expect(write, contains('merged[other] = record'));
      // there is no "another owner's marker blocks / is replaced" shortcut left
      expect(write, isNot(contains('QueueError.ownerChanged')));
      expect(write, isNot(contains('stored.ownerUid')));
    });

    test('reads are per owner: an entry for another owner never applies', () {
      final denied = body(store, 'private static func egressDenied(');
      expect(denied, contains(r'$0.owners[hash]'));
      expect(denied, contains('if view.uncertain { return true }'));
      expect(denied, contains(r'$0.state != "ON"'));
      expect(denied, contains('mine[0] != mine[1]'));
      final read = body(store, 'private static func cloudEgressState(forUid uid: String,');
      expect(read, contains(r'$0.owners[hash]'));
    });

    test('an unreadable or undecodable store marks the view uncertain', () {
      final view = body(store, 'private static func egressView()');
      expect(view, contains('uncertain = true'));
      expect(view, contains('case errSecItemNotFound:'));
      expect(view, contains('default:\n      uncertain = true'));
      expect(view, contains('egressKeychainReadOverride'));
    });

    test('a valid DISABLING/OFF in either store wins for the reconciled read',
        () {
      final read = body(store, 'private static func cloudEgressState(forUid uid: String,');
      expect(read.indexOf(r'$0.state != "ON"'),
          lessThan(read.indexOf('view.uncertain')),
          reason: 'a restrictive entry wins before the uncertain verdict');
    });

    test('a decoded map must carry valid states and non-empty keys', () {
      final decode = body(store, 'private static func decodeEgressMap(');
      expect(decode, contains('egressRank(record.state) != nil'));
      expect(decode, contains('!hash.isEmpty'));
    });

    test('an ON write over a wholly unreadable state is refused', () {
      final write = body(store, 'static func setCloudEgressState(');
      expect(write, contains('view.maps.isEmpty && view.uncertain'));
      expect(write, contains('QueueError.egressDenied'));
    });

    test('the channel and bridge read per owner', () {
      final plain = body(store, 'static func cloudEgressState(forUid uid: String)');
      final diagnostic = body(store, 'static func diagnosticCloudEgressState(');
      expect(plain, contains('try cloudEgressState(forUid: uid, stage:'));
      expect(diagnostic, contains('try cloudEgressState(forUid: uid, stage:'));
      expect(diagnostic, contains('SnapshotFailure(underlying: error, stage: stage)'));
      expect(appDelegate,
          contains('SharedCaptureStore.diagnosticCloudEgressState(forUid: ownerUid)'));
      expect(
          bridge,
          contains(
              'static Future<CloudEgressSnapshot?> getCloudEgressState({'));
      expect(bridge, contains("'getCloudEgressState', {'ownerUid': ownerUid}"));
    });
  });

  group('C.4 admission in the native processes', () {
    test('authorizeUpload reads the denial state under the SAME flock', () {
      final auth = body(store, 'private static func authorizeUploadLocked(');
      expect(body(store, 'static func authorizeUpload(payloadID: String)'),
          matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(auth, contains('egressDenied(forOwner: uid)'));
      expect(auth.indexOf('egressDenied(forOwner: uid)'),
          greaterThan(auth.indexOf('owner.uid == uid')));
      // Phase 3: the one .allowed before the Cloud denial check is the
      // smart-analysis lane (the owner's own AI-only mirror); the Cloud
      // .allowed comes after it.
      final lane = auth.indexOf('if let mirror, !mirror.cloud, mirror.ai {');
      expect(lane, greaterThan(auth.indexOf('owner.uid == uid')));
      expect(auth.indexOf('.allowed('), greaterThan(lane));
      expect(auth.indexOf('egressDenied(forOwner: uid)'),
          lessThan(auth.indexOf('allowAi: mirror.ai)')),
          reason: 'the denial check precedes the Cloud .allowed verdict');
      expect(auth,
          contains('if egressDenied(forOwner: uid) { return .localOnly }'));
    });

    test('the one native network call is gated immediately before it', () {
      // H3.1: the URLSession moved into SharedCaptureStore.gatedUpload; the
      // client only calls it (full pins: cloud_egress_native_h3_contract_test).
      expect(intent, isNot(contains('URLSession')));
      expect(RegExp(r'SharedCaptureStore\.gatedUpload\(').allMatches(intent).length,
          1);
      final transport = body(store, 'static func gatedUpload(');
      final gate = transport.indexOf('admitUpload(payloadID: payloadID)');
      final net = transport.indexOf('try await session.data(for: admitted)');
      expect(gate, greaterThan(-1));
      expect(gate, lessThan(net));
      expect(transport, contains('throw QueueError.egressDenied'));
      expect(intent, contains('throw BackendCaptureError.egressDenied'));
      // The gate covers the idempotent timeout retry too: both attempts go
      // through BackendCaptureClient.process.
      final process = body(intent, 'func processBackend(');
      expect(RegExp(r'client\.process\(').allMatches(process).length, 2);
    });

    test('no other native process opens a network connection', () {
      for (final source in [appDelegate, share]) {
        expect(source, isNot(contains('URLSession')));
        expect(source, isNot(contains('URLRequest')));
        expect(source, isNot(contains('NWConnection')));
      }
      expect(share, contains('SharedCaptureStore.enqueue('));
    });

    test('APNs registration (the only other native request) is gated', () {
      final at = appDelegate.indexOf('case "registerForRemoteNotifications":');
      final gate = appDelegate.indexOf('egressAdmitsHostRequest(', at);
      final call = appDelegate.indexOf(
          'UIApplication.shared.registerForRemoteNotifications()', at);
      expect(gate, greaterThan(at));
      expect(gate, lessThan(call));
      final host = body(store, 'static func egressAdmitsHostRequest(');
      expect(host, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(host, contains('?? false'));
    });
  });

  group('C.4 native in-flight registry', () {
    test('admission = authorize + register, in ONE flock, before the request',
        () {
      final admit = body(store, 'static func admitUpload(payloadID: String)');
      expect(admit, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(admit, contains('authorizeUploadLocked(payloadID)'));
      expect(admit.indexOf('authorizeUploadLocked('),
          lessThan(admit.indexOf('InflightUpload(')));
      expect(admit, contains('payloadId: payloadID'));
      expect(admit, contains('ownerHash: try uidHash(uid)'));
      expect(admit, contains('nativeUploadTimeout + inflightGrace'));
      // a registry that cannot be written or trusted denies: no request
      expect(
          admit,
          contains(
              'do { try writeInflight(entries) } catch { return .localOnly }'));
      expect(
          admit,
          contains(
              'guard inflightFileIsStale(now: now) else { return .localOnly }'));
      expect(
          store, contains('static let nativeUploadTimeout: TimeInterval = 8'));
      expect(store,
          contains('private static let inflightGrace: TimeInterval = 2'));
      expect(
          intent,
          contains(
              'urlRequest.timeoutInterval = SharedCaptureStore.nativeUploadTimeout'));
    });

    test('the transport registers at admission and removes on every exit', () {
      final transport = body(store, 'static func gatedUpload(');
      final admit = transport.indexOf('admitUpload(payloadID: payloadID)');
      final cleanup =
          transport.indexOf('defer { removeInflightUpload(payloadID: payloadID) }');
      final net = transport.indexOf('try await session.data(for: admitted)');
      expect(admit, greaterThan(-1));
      expect(cleanup, greaterThan(admit));
      expect(cleanup, lessThan(net),
          reason:
              'defer is armed before the request: success AND error remove');
    });

    test('entries past their deadline count as finished; reader is under flock',
        () {
      final read = body(store, 'static func inflightUploads(forUid');
      expect(read, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(read, contains(r'$0.deadline > now'));
      expect(read, contains(r'$0.ownerHash == hash'));
      expect(read, contains('readInflightRaw()'), reason: 'unreadable throws');
      final remove = body(store, 'static func removeInflightUpload(');
      expect(remove, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(remove, contains(r'$0.payloadId != payloadID'));
    });

    test('the registry lives in the App Group and survives sign-out', () {
      expect(store, contains('"native_inflight_uploads_v1.json"'));
      expect(store,
          contains('.completeFileProtectionUntilFirstUserAuthentication'));
    });

    test('channel and bridge expose it per owner', () {
      expect(appDelegate, contains('case "nativeInflightUploads":'));
      expect(appDelegate, contains('latestDeadlineMs'));
      expect(bridge, contains('nativeInflightUploads({'));
      expect(
          bridge, contains('Future<({int count, DateTime? latestDeadline})?>'));
    });
  });

  group('test-only seams exist only in DEBUG builds', () {
    test('every seam is declared inside #if DEBUG, inert constants otherwise',
        () {
      final start =
          store.indexOf('#if DEBUG\n  static var queueKeyReadOverride');
      expect(start, greaterThan(-1));
      final elseAt = store.indexOf('#else', start);
      final endAt = store.indexOf('#endif', elseAt);
      final debug = store.substring(start, elseAt);
      final release = store.substring(elseAt, endAt);
      for (final seam in const [
        'queueKeyReadOverride',
        'lockUnavailableOverride',
        'ownerRecordReadOverride',
        'stampingHook',
        'clockOverride',
        'egressKeychainReadOverride',
      ]) {
        expect(debug, contains('static var $seam'), reason: seam);
        expect(release, contains('static let $seam'), reason: seam);
        expect(release, isNot(contains('static var $seam')), reason: seam);
        // never declared anywhere else
        expect(RegExp('static (var|let) $seam').allMatches(store).length, 2,
            reason: seam);
      }
    });

    test('debug-only helpers are wrapped in #if DEBUG', () {
      for (final fn in const [
        'static func debugResetCloudEgressState()',
        'static func debugOwnerHash(',
      ]) {
        final at = store.indexOf(fn);
        expect(at, greaterThan(-1), reason: fn);
        final open = store.lastIndexOf('#if DEBUG', at);
        final close = store.lastIndexOf('#endif', at);
        expect(open, greaterThan(close),
            reason: '$fn must sit inside an open #if DEBUG');
      }
      expect(RegExp(r'static func debug\w+').allMatches(store).length, 2);
    });
  });

  group('C.1 the intent upload is ALWAYS owner-bound', () {
    test('owner_uid and owner_generation are sent on every schema version', () {
      final client = body(intent, 'func process(');
      final ownerAt = client.indexOf('body["owner_uid"] = ownerUid');
      final genAt =
          client.indexOf('body["owner_generation"] = ownerGeneration');
      final schemaAt = client.indexOf('body["schema_version"] = 2');
      expect(ownerAt, greaterThan(-1));
      expect(genAt, greaterThan(-1));
      expect(schemaAt, greaterThan(ownerAt));
      expect(schemaAt, greaterThan(genAt));
      expect(client, contains('if config.captureContractV2 {'));
    });

    test('an ownerless upload cannot be expressed', () {
      expect(intent, isNot(contains('ownerUid: String? = nil')));
      expect(intent, isNot(contains('let ownerUid {')));
      expect(
          intent,
          contains('ownerUid: String,\n    ownerGeneration: Int,\n'
              '    allowAi: Bool\n  ) async throws -> BackendCaptureResponse'));
    });

    test(
        'authorizeUpload only allows a stamped item and returns its generation',
        () {
      expect(
          store,
          contains(
              'case allowed(ownerUid: String, ownerGeneration: Int, allowAi: Bool)'));
      final auth = body(store, 'private static func authorizeUploadLocked(');
      expect(auth, contains('item.ownerState == ownerStateStamped'));
      expect(auth, contains('ownerGeneration: generation'));
      expect(
          auth,
          contains(
              'if item.ownerState == ownerStateUnbound { return .localOnly }'));
    });
  });

  group('P4 native writes are generation / epoch guarded', () {
    test('every native mutating write validates the generation', () {
      for (final sig in const [
        'static func publishActiveOwner(',
        'static func setConsentMirror(',
      ]) {
        expect(body(store, sig), contains('guardMirrorWrite('), reason: sig);
      }
      final guard = body(store, 'private static func guardMirrorWrite(');
      expect(guard, contains('egressGenerationIsStale('));
      expect(guard, contains('QueueError.staleGeneration'));
      expect(guard, contains('QueueError.egressDenied'));
      final config = body(store, 'static func setBackendConfig(');
      expect(config, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(config, contains('egressGenerationIsStale('));
      expect(config, contains('egressDenied(forOwner: subject)'));
      final egress = body(store, 'static func setCloudEgressState(');
      expect(egress, contains('QueueError.staleGeneration'));
      expect(egress,
          contains('transitionGeneration < stored.transitionGeneration'));
    });

    test(
        'the publish still compare-and-swaps on the owner epoch and refuses '
        'under a barrier', () {
      final publish = body(store, 'static func publishActiveOwner(');
      expect(publish, contains('readBarrier() == nil'));
      expect(publish, contains('== expectedEpoch'));
      expect(publish.indexOf('guardMirrorWrite('),
          lessThan(publish.indexOf('writeConsentMirrorEntry(')),
          reason: 'refusals happen before ANY write');
    });

    test('channel methods forward transitionGeneration and map the codes', () {
      expect(appDelegate, contains('args["transitionGeneration"] as? Int'));
      expect(appDelegate, contains('case "setCloudEgressState":'));
      expect(appDelegate, contains('case "getCloudEgressState":'));
      expect(appDelegate, contains('code = "stale_generation"'));
      expect(appDelegate, contains('code = "egress_denied"'));
      expect(appDelegate, contains('ownerUid: args["ownerUid"] as? String'));
    });

    test('the Dart bridge statics keep legacy call sites compiling', () {
      expect(bridge, contains('static Future<void> setCloudEgressState({'));
      expect(bridge, contains('int? transitionGeneration,'));
      expect(bridge, contains('String? ownerUid,'));
      expect(bridge, contains('if (transitionGeneration != null)'));
    });
  });

  group('P6 restrictive publish is atomic; missing authority refuses', () {
    test('mirror and owner are written in ONE flock, mirror first', () {
      final publish = body(store, 'static func publishActiveOwner(');
      expect(
          publish.indexOf('writeConsentMirrorEntry('),
          lessThan(
              publish.indexOf('writeKeychain(data, forKey: activeOwnerKC)')));
      expect(publish, isNot(contains('URLSession')));
    });

    test('no mirror, no barrier-free flock or a stale epoch means refuse', () {
      final publish = body(store, 'static func publishActiveOwner(');
      expect(publish, contains('throw QueueError.barrierActive'));
      expect(publish, contains('throw QueueError.ownerChanged'));
      final auth = body(store, 'private static func authorizeUploadLocked(');
      expect(auth, contains('let mirror = consentMirror(forHash: owner.uidHash)'));
      expect(auth, contains('guard let mirror else { return .waiting }'));
      expect(body(store, 'static func authorizeUpload(payloadID: String)'),
          contains(') ?? .waiting'));
    });
  });

  group('XCTests exist for the required scenarios (Mac proof pending)', () {
    test('the G3 XCTests are present', () {
      for (final name in const [
        'testCorruptEgressFileDeniesEgress',
        'testUnreadableEgressKeychainDeniesEgress',
        'testMixedStoreDisablingRecordWinsInEitherStore',
        'testOtherOwnersWriteNeverDiscardsDisablingMarker',
        'testOtherOwnersOffRecordDoesNotDenyActiveOwner',
        'testDisablingAndOffAdmitNoNativeUpload',
        'testInflightRegistryRegistrationRemovalAndDeadline',
        'testStaleGenerationNativeWritesAreRefused',
        'testRestrictivePublishIsAtomicAndRefusedWithoutAuthority',
        'testBackendClientOwnerBindingAndAdmissionOrder',
        'testGatedUploadDeniedInDisablingAndOff',
        'testGatedUploadStaleGenerationAndOwnerDenied',
        'testPushRegistrationStaleGenerationDenied',
        'testNoNetworkUseOutsideTheGatedTransport',
        'testExtensionHasNoNetworkPushIsGatedAndAllowanceStaysInDart',
      ]) {
        expect(xctest, contains('func $name()'), reason: name);
      }
    });
  });
}
