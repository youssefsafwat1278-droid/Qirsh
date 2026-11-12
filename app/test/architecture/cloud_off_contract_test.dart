import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A-12-min — Cloud OFF = ZERO EGRESS, owner publication decoupled from the
/// network link, plus native `captureQueueStats` (D3).
///
/// Swift cannot run here. The behavioural proof is `ios/RunnerTests/
/// RunnerTests.swift` (the A-12-min section; needs Xcode and a device/simulator
/// with the App Group + Keychain entitlements: MAC PROOF REQUIRED); these static
/// checks pin the source properties that make it true so a regression fails in
/// Linux CI. The style follows capture_queue_cap6_contract_test.dart.
void main() {
  final store = File('ios/Runner/SharedCaptureStore.swift').readAsStringSync();
  final storeCopy =
      File('ios/ShareBankMessage/SharedCaptureStore.swift').readAsStringSync();
  final intent = File('ios/BankMessageShortcuts/BankMessageShortcuts.swift')
      .readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
  final registration = File(
          'lib/features/capture/services/capture_device_registration_service.dart')
      .readAsStringSync();
  final sync = File('lib/features/capture/services/capture_sync_service.dart')
      .readAsStringSync();
  final port = File('lib/features/capture/services/capture_server_port.dart')
      .readAsStringSync();
  final bootstrap =
      File('lib/core/startup/bootstrap_runner.dart').readAsStringSync();
  final diagnostics =
      File('lib/core/sync/sync_diagnostics_report.dart').readAsStringSync();
  final xctest = File('ios/RunnerTests/RunnerTests.swift').readAsStringSync();

  /// The text from the `{` after [signature] to its matching `}`.
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

  void inOrder(String text, List<String> tokens) {
    var last = -1;
    for (final token in tokens) {
      final at = text.indexOf(token, last + 1);
      expect(at, greaterThan(last), reason: '$token out of order or missing');
      last = at;
    }
  }

  group('Swift: owner publication (R4)', () {
    test('the two store copies are byte-identical', () {
      expect(storeCopy, store);
    });

    test('mirror + owner are ONE flock; the mirror is written first', () {
      final publish = body(store, 'static func publishActiveOwner(');
      expect(publish.trimLeft().substring(1).trimLeft(),
          matches(RegExp(r'^try with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      inOrder(publish, [
        'readBarrier() == nil',
        'ownerEpochKey',
        'expectedEpoch',
        'writeConsentMirrorEntry(',
        'writeKeychain(data, forKey: activeOwnerKC)',
      ]);
      expect(publish, contains('QueueError.barrierActive'));
      expect(publish, contains('QueueError.ownerChanged'),
          reason: 'a stale epoch is refused (compare-and-swap)');
      // The signature takes the mirror: publication has no mirror-less form.
      expect(store, contains('mirror: ConsentMirrorValue'));
      expect(store, isNot(contains('publishActiveOwner(uid: String) ')));
    });

    test('every owner clear bumps the epoch', () {
      expect(body(store, 'static func clearActiveOwner('),
          contains('bumpOwnerEpoch()'));
      expect(body(store, 'static func beginRemoval('),
          contains('bumpOwnerEpoch()'));
      expect(body(store, 'static func finishRemoval('),
          contains('bumpOwnerEpoch()'));
      expect(body(store, 'static func purgeUserOwnedState()'),
          contains('bumpOwnerEpoch()'));
      expect(
          body(store, 'static func ownerEpoch()'), matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
    });

    test('setConsentMirror is refused under a Remove-data barrier', () {
      final fn = body(store, 'static func setConsentMirror(');
      expect(fn, contains('readBarrier() == nil'));
      expect(fn, contains('QueueError.barrierActive'));
    });

    test(
        'the consent mirror is written in exactly four places, all under the '
        'flock', () {
      expect(RegExp(r'writeConsentMirrorEntry\(').allMatches(store).length, 4,
          reason: 'the definition, publishActiveOwner, setConsentMirror and '
              'publishRestrictiveCaptureOwner');
      final restrictive =
          body(store, 'static func publishRestrictiveCaptureOwner(');
      expect(restrictive, matches(RegExp(r'with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      expect(
          RegExp(r'writeConsentMirrorEntry\(').allMatches(restrictive).length,
          1);
      expect(restrictive,
          contains('mirror: ConsentMirrorValue(cloud: false, ai: false'));
    });
  });

  group('Swift: stamping and the one upload gate (R2, R3)', () {
    test('stamping: no mirror or cloud OFF => localOnly + pendingSend->sent',
        () {
      final enqueue = body(store, 'static func enqueue(');
      inOrder(enqueue, [
        'try readActiveOwner()',
        'consentMirror(forHash: owner.uidHash)?.cloud != true',
        'stamped.localOnly = true',
        'CaptureStatus.pendingSend.rawValue',
        'CaptureStatus.sent.rawValue',
        'try checkQuotas(',
        'try saveQueue(',
      ]);
    });

    test(
        'authorizeUpload is fail-closed: no mirror => waiting, no allowed(nil)',
        () {
      final fn = body(store, 'private static func authorizeUploadLocked(');
      expect(fn, contains('item.localOnly == true'));
      expect(
          fn,
          contains(
              'guard let mirror = consentMirror(forHash: owner.uidHash) else { return .waiting }'));
      expect(fn, isNot(contains('allowAi: nil')));
      expect(
          store,
          contains(
              'case allowed(ownerUid: String, ownerGeneration: Int, allowAi: Bool)'));
      expect(store, isNot(contains('allowAi: Bool?')));
      inOrder(fn, ['.localOnly', 'consentMirror(forHash', '.allowed(']);
    });

    test('the claim path still binds localOnly and forces pendingSend -> sent',
        () {
      final claim = body(store, 'static func claimUnbound(');
      expect(claim, contains('localOnly = true'));
      expect(claim, contains('CaptureStatus.sent.rawValue'));
    });

    test('the App Intent has no install-level AI fallback and sends v2 owner',
        () {
      expect(intent, isNot(contains('ai_consent_granted')));
      expect(intent, isNot(contains('allowAi ?? ')));
      expect(
          intent,
          contains(
              'allowAi: Bool\n  ) async throws -> BackendCaptureResponse'));
      expect(intent, contains('body["schema_version"] = 2'));
      expect(intent, contains('body["owner_uid"] = ownerUid'));
      // authorizeUpload runs before any network call.
      final perform = body(intent, 'func perform() async throws');
      inOrder(perform, [
        'SharedCaptureStore.authorizeUpload(payloadID: payloadID)',
        'let attempt = await processBackend',
      ]);
    });

    test('the Dart replay has the same gate, before any secret or request', () {
      final retry = body(sync, 'Future<bool> retryPendingSend(');
      inOrder(retry, [
        'await gate(message.id!)',
        'CaptureUploadDecision.waiting',
        '!auth.allowed',
        'isLinkedForCloud()',
        'readDeviceSecret()',
        'processIosSms(',
      ]);
      expect(retry, contains('allowAi: auth.allowAi'));
      // Only a platform WITHOUT the native v3 queue (no pendingSend there) falls
      // back to the settings flag; the iOS path always uses the owner mirror.
      expect(retry, contains('NativeCaptureBridge.hasNativeQueue'));
    });
  });

  group('Swift: captureQueueStats (user decision 9)', () {
    test('read-only, under the flock, no per-capture list', () {
      final fn = body(store, 'static func queueStats()');
      expect(fn.trimLeft().substring(1).trimLeft(),
          matches(RegExp(r'^try with(?:QueueLock|ProtectedWriteLock(?:Counted)?)')));
      for (final write in const [
        'saveQueue(',
        'writeKeychain(',
        'removeKeychain(',
        'defaults?.set(',
        'loadQueuePruned',
        'loadQueue()',
        'migrateLegacyQueue',
      ]) {
        expect(fn, isNot(contains(write)), reason: 'stats must not write');
      }
      // The loader it uses is read-only too: it never migrates the v2 queue.
      final loader = body(store, 'private static func loadQueueReadOnly()');
      for (final write in const [
        'saveQueue(',
        'defaults?.set(',
        'migrateLegacyQueue',
        'removeQueueFile',
      ]) {
        expect(loader, isNot(contains(write)), reason: 'stats loader: $write');
      }
      final model = body(store, 'struct QueueStats: Equatable');
      for (final field in RegExp(r'var (\w+) = ').allMatches(model)) {
        expect(
          RegExp('var ${field[1]} = (0|false|QuotaState\\.ok)').hasMatch(model),
          isTrue,
          reason: '${field[1]} must be a count or a quota state',
        );
      }
      expect(model, isNot(contains('[')), reason: 'no lists in the stats');
      expect(model, isNot(contains('String')));
    });

    test('the channel returns counts, bytes and quota words only', () {
      final at = appDelegate.indexOf('case "captureQueueStats":');
      expect(at, greaterThan(-1));
      final end = appDelegate.indexOf('case "', at + 10);
      final handler = appDelegate.substring(at, end);
      final keys = RegExp(r'"(\w+)": stats\.')
          .allMatches(handler)
          .map((m) => m[1])
          .toSet();
      expect(keys, {
        'stamped',
        'localOnly',
        'waiting',
        'unbound',
        'activeOwnerBytes',
        'unboundBytes',
        'deviceBytes',
        'ownerQuota',
        'unboundQuota',
        'deviceQuota',
        'migrationPending',
        // 2026-11-12: content-free count of undecryptable overflow segments.
        'quarantinedSegments',
      });
      for (final leak in const ['text', 'sender', 'id', 'uid', 'ownerUid']) {
        expect(keys.contains(leak), isFalse);
      }
    });

    test('capacity values: segment sizes and the single-item ceiling', () {
      // Owner-approved change (2026-11-12): the refusing per-owner / unbound /
      // device quotas were replaced by encrypted overflow segments.
      for (final (name, value) in const [
        ('segmentMaxItems', '500'),
        ('segmentMaxBytes', '2 * 1024 * 1024'),
        ('maxItemBytes', 'segmentMaxBytes'),
      ]) {
        expect(store, contains('static let $name = $value'));
      }
      for (final gone in const [
        'ownerMaxItems',
        'unboundMaxItems',
        'deviceMaxBytes',
      ]) {
        expect(store, isNot(contains('static let $gone')));
      }
    });

    test('the AppDelegate channel cases exist', () {
      for (final c in const [
        'captureQueueStats',
        'captureOwnerEpoch',
        'authorizeCaptureUpload',
        'publishCaptureOwner',
      ]) {
        expect(appDelegate, contains('case "$c":'));
      }
      expect(appDelegate, contains('expectedEpoch'));
    });

    test('the XCTests exist for every A-12-min store change', () {
      for (final t in const [
        'testCloudOffStampsLocalOnlyAndSentEvenIfCloudIsLaterTurnedOn',
        'testMissingMirrorNeverUploads',
        'testPublishWritesMirrorWithOwnerAndKeepsGeneration',
        'testLatePublishAfterTransitionClearIsRefused',
        'testSetConsentMirrorRefusedUnderBarrier',
        'testClaimForcesSentAndLocalOnly',
        'testQueueStatsBucketsBytesAndQuotaState',
        'testQueueStatsReadOnlyAndContentFree',
        'testQueueStatsNeverMigratesTheV2Queue',
        'testLocalOnlyPendingItemIsNeverAuthorized',
      ]) {
        expect(xctest, contains('func $t('));
      }
    });
  });

  group('Dart: zero egress while Cloud is OFF (R5, R6)', () {
    test('the OFF branch of _syncNativeState sends nothing', () {
      final fn = body(registration, 'Future<void> _syncNativeState(');
      final off = fn
          .substring(0, fn.indexOf('if (!settings.aiConsentGranted ||'))
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      for (final egress in const [
        '_projectConsent',
        'registerDevice',
        'setConsent',
        '_consent.',
        '_backendClient',
        '_loadApnsToken',
        'syncApnsToken',
        '_withSecretRecovery',
        '_recoverRejectedSecret',
      ]) {
        expect(off, isNot(contains(egress)), reason: egress);
      }
      // E1: the OFF sync branch never revokes; the revoke lives in disableCloud.
      expect(off, contains('_linkOnce()'));
      expect(off, isNot(contains('revoke')));
      expect(registration, isNot(contains('_cloudOnSeenUid')));
      expect(registration, isNot(contains('_revokeOnSwitchOff')));
      expect(registration, isNot(contains('_revokeAndroidOnSwitchOff')));
    });

    test('_linkAndPublish: OFF never needs the backend, ON links first', () {
      final fn = body(registration, 'Future<bool> _linkAndPublish(bool Function() current)');
      final beforeCloudBranch =
          fn.substring(0, fn.indexOf('if (snapshot.cloud &&'));
      expect(beforeCloudBranch, isNot(contains('_isBackendConfigured')));
      expect(beforeCloudBranch, isNot(contains('_linkWithConsent')));
      inOrder(fn, [
        '_readOwnerEpoch()',
        'if (snapshot.cloud &&',
        '_linkWithConsent(',
        '_publishOwner(',
      ]);
      expect(fn, contains('expectedEpoch: epoch'));
    });

    test('a 401 never re-registers while Cloud is OFF', () {
      final start =
          registration.indexOf('Future<String> _recoverRejectedSecret(');
      final fn = registration.substring(start, start + 1500);
      inOrder(fn, [
        'cloudProcessingEnabled',
        'recovery_skipped_cloud_off',
        'registerDevice(',
      ]);
    });

    test('sign-out unlink needs a Cloud-ON ack and clears it before sending',
        () {
      final fn = body(registration, 'Future<void> unlinkCurrentDevice()');
      inOrder(fn, [
        '_mirrorVersions.clear()',
        '_readAckAny()',
        '!ack.snapshot.cloud',
        '_clearAck()',
        'unlinkDevice(',
      ]);
    });

    test('legacy device-credential calls need the uid-bound ack', () {
      final fn = body(registration, 'Future<bool> isLinkedForCloud()');
      expect(fn, contains('_readAck(uid)'));
      expect(fn, contains('ack.cloud'));
      expect(body(sync, 'Future<CaptureSyncResult> _syncOnce()'),
          contains('isLinkedForCloud()'));
      expect(
          body(port,
              'Future<({String installId, String secret})?> _credentials()'),
          contains('isLinkedForCloud()'));
    });

    test('the publish hook and the epoch reach the registration service', () {
      expect(bootstrap,
          contains('readOwnerEpoch: captureQueue.captureOwnerEpoch'));
      expect(bootstrap,
          contains('publishOwner: captureQueue.publishCaptureOwner'));
    });
  });

  group(
      'Dart: the one-shot revoke inside the OFF transition (A-12.4, E1, '
      'Astra G C.3/C.4)', () {
    test('one named constant, referenced by exactly one gate', () {
      expect(
          RegExp(r'const bool kRevokeAtCloudSwitchOff = true;')
              .hasMatch(registration),
          isTrue);
      final fn =
          body(registration, 'Future<_RevokeInputs?> _captureRevokeInputs(');
      expect(fn, contains('!_revokeAtSwitchOff'));
      expect(
          RegExp(r'revokeAtSwitchOff = kRevokeAtCloudSwitchOff')
              .hasMatch(registration),
          isTrue);
    });

    test(
        'inputs need the frozen owner JWT and the uid-bound ack, never just '
        'a stored secret', () {
      final fn =
          body(registration, 'Future<_RevokeInputs?> _captureRevokeInputs(');
      inOrder(fn, [
        'session.uid != freeze.owner',
        '_readAck(freeze.owner)',
        '_secretKey',
      ]);
    });

    test(
        'attempt durable and consumed first, ack cleared, no 401 recovery, no '
        'relink', () {
      final fn = body(registration,
          'Future<void> _revokeOnce(DisableFreeze freeze, _RevokeInputs? inputs)');
      inOrder(fn, [
        '_attemptRecorded(freeze)',
        '_revokeAttemptSlots.write(',
        '_clearAck()',
        '_gate.runRevoke(',
        '_consent.revoke(',
      ]);
      expect(fn, contains("'consumed': true"));
      for (final forbidden in const [
        '_withSecretRecovery',
        '_recoverRejectedSecret',
        'registerDevice',
        'link(',
        'setConsent(',
      ]) {
        expect(fn, isNot(contains(forbidden)), reason: forbidden);
      }
    });

    test(
        'disableCloud: freeze and epoch first, DISABLING durable before any '
        'native/revoke work, commit after, durable OFF before unfreezing', () {
      final fn = body(registration,
          'Future<void> _disableCloud(Future<void> Function() commitLocalOff)');
      inOrder(fn, [
        "ConsentAuthority.freeze('disable');",
        '_gate.advanceEpoch(EpochCause.cloudDisable);',
        '_gate.beginDisabling(',
        '_restrictNativeSide(',
        '_captureRevokeInputs(',
        '_gate.drain()',
        '_gate.drainNative(',
        '_revokeOnce(',
        'finally',
        '_finishDisable(',
      ]);
      final fin = body(registration, 'Future<void> _finishDisable(');
      inOrder(fin, [
        'owner_changed',
        'await commitLocalOff();',
        '_gate.rewriteDisabling(freeze)',
        'rethrow;',
        'disabling_not_durable',
        '_gate.commitOff(freeze)',
        'ConsentAuthority.egressFrozen = false;',
      ]);
      // The reconcile path never sends a revoke.
      final pending =
          body(registration, 'Future<bool> _completePendingDisable(');
      expect(pending, isNot(contains('_consent.')));
      expect(pending, isNot(contains('_revokeOnce')));
    });

    test('the revoke has exactly one trigger; the UI routes OFF through it',
        () {
      // N-CR-3: exactly two triggers, each in its own transition body: the
      // ordinary ON->OFF disable and the verified withdrawal of an effective
      // permission (same one-shot, ack-bound helper; never anywhere else).
      expect(
          RegExp(r'_revokeOnce\(freeze, inputs\)')
              .allMatches(registration)
              .length,
          2,
          reason: '_disableCloud and _withdrawPendingEnable only');
      expect(
          RegExp(r'_revokeOnce\(freeze, inputs\)')
              .allMatches(body(registration, 'Future<void> _disableCloud('))
              .length,
          1);
      expect(
          RegExp(r'_revokeOnce\(freeze, inputs\)')
              .allMatches(
                  body(registration, 'Future<void> _withdrawPendingEnable('))
              .length,
          1);
      final screen =
          File('lib/features/settings/privacy_screen.dart').readAsStringSync();
      expect(
          screen, contains('registration.isDisablingCloud(before, updated)'));
      expect(screen, contains('registration.disableCloud('));
      // Enabling is not on this screen: the disclosure's typed service route.
      expect(screen, isNot(contains('enableCloud(')));
      final sheet = File('lib/features/consent/smart_analysis_consent_sheet.dart')
          .readAsStringSync();
      expect(sheet, contains('service.enableCloud('));
    });
  });

  group('Dart: one admission gate (Astra G P1)', () {
    test('every default transport is the gated client', () {
      for (final f in const [
        'lib/features/capture/services/capture_backend_client.dart',
        'lib/features/capture/services/capture_consent_client.dart',
        'lib/features/capture/services/capture_server_port.dart',
        'lib/engine/ai/ai_parser_client.dart',
        'lib/engine/ai/bank_discovery_client.dart',
        'lib/engine/ai/proof_shadow_client.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src, contains('GatedHttpClient()'), reason: f);
        expect(src, isNot(contains('?? http.Client()')), reason: f);
      }
    });

    test(
        'Supabase is initialised with the gated transport and no automatic '
        'exception', () {
      inOrder(bootstrap,
          ['await Supabase.initialize(', 'httpClient: GatedHttpClient(),']);
      expect(bootstrap, contains('stopAutoRefresh()'));
      final consent =
          File('lib/core/privacy/consent_authority.dart').readAsStringSync();
      final decide = body(consent, 'static bool decide(');
      expect(decide, contains('case EgressClass.auth:\n        return false;'));
    });

    test('catalog sync asks the gate first', () {
      final catalog =
          File('lib/data/catalog/catalog_sync_service.dart').readAsStringSync();
      final syncAll = body(catalog,
          'Future<void> syncAll(\n      {String? countryCode, CatalogLocalWork? localWork}) async');
      inOrder(syncAll, [
        'CloudEgressGate.instance.permits()',
        '_fetchVersions(localWork)',
      ]);
    });

    test('network images go through the gated provider', () {
      for (final f in const [
        'lib/features/cards/brand_mark.dart',
        'lib/features/coupons/coupon_widgets.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src, isNot(contains('Image.network(')), reason: f);
        expect(src, contains('GatedNetworkImage('), reason: f);
      }
    });

    test('the Dart replay always sends owner_uid and owner_generation', () {
      final fn = body(sync, 'Future<bool> retryPendingSend(');
      expect(fn, contains('ownerGeneration: ownerGeneration'));
      expect(fn, contains('ownerUid: ownerUid'));
      expect(fn, isNot(contains('auth.contractV2 ? auth.ownerUid : null')));
    });
  });

  group('Dart: diagnostics use the native stats', () {
    test('the count-only quota rows are gone; the stats rows exist', () {
      expect(diagnostics, isNot(contains("'queue count quota'")));
      expect(diagnostics, isNot(contains("'unbound count quota'")));
      expect(diagnostics, contains("'queue quota (this owner)'"));
      expect(diagnostics, contains('s.queueStats'));
    });
  });
}
