import Flutter
import UIKit
import XCTest
import Security
import CryptoKit

@testable import Runner

class RunnerTests: XCTestCase {

  func testShortcutSetupProbeRecordsFreshReceipt() {
    let started = Date().timeIntervalSince1970 * 1000
    SharedCaptureStore.recordShortcutSetupProbe()
    XCTAssertGreaterThanOrEqual(SharedCaptureStore.shortcutSetupProbeMilliseconds, started)
  }

  func testConnectingNonKeySceneControllerHasCaptureAndTimezoneBeforeActivation() throws {
    let delegate = AppDelegate()
    defer {
      CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        UnsafeRawPointer(Unmanaged.passUnretained(delegate).toOpaque()))
    }
    let first = ChannelTestController(name: "connecting-scene-channel-test")
    let window = UIWindow(frame: .zero)
    window.rootViewController = first
    XCTAssertFalse(window.isKeyWindow)
    delegate.configureNativeCaptureChannelIfNeeded(controller: first)
    delegate.configureDeviceTimezoneChannelIfNeeded(controller: first)
    let capture = "money_companion/native_capture"
    let timezone = "mali/device_timezone"
    XCTAssertEqual(try first.messages.invoke(capture, method: "hasSmsPermission") as? Bool, false)
    XCTAssertFalse((try first.messages.invoke(timezone, method: "getLocalTimezone") as? String ?? "").isEmpty)
    let registrations = first.messages.registrations
    delegate.configureNativeCaptureChannelIfNeeded(controller: first)
    delegate.configureDeviceTimezoneChannelIfNeeded(controller: first)
    XCTAssertEqual(first.messages.registrations, registrations)

    let next = ChannelTestController(name: "reconnecting-scene-channel-test")
    delegate.configureNativeCaptureChannelIfNeeded(controller: next)
    delegate.configureDeviceTimezoneChannelIfNeeded(controller: next)
    XCTAssertNil(first.messages.handlers[capture])
    XCTAssertNil(first.messages.handlers[timezone])
    XCTAssertEqual(try next.messages.invoke(capture, method: "hasSmsPermission") as? Bool, false)
    XCTAssertFalse((try next.messages.invoke(timezone, method: "getLocalTimezone") as? String ?? "").isEmpty)
  }

  // MARK: - Native Liquid Glass

  func testNativeGlassIsTheUnmodifiedSystemRegularMaterial() throws {
    guard #available(iOS 26.0, *) else { throw XCTSkip("UIGlassEffect needs iOS 26") }
    XCTAssertTrue(NativeGlass.isSupported)
    let platformView = NativeGlassPlatformView(
      frame: CGRect(x: 0, y: 0, width: 240, height: 56),
      args: ["radius": 16, "dark": true])
    let view = try XCTUnwrap(platformView.view() as? UIVisualEffectView)
    let effect = try XCTUnwrap(view.effect as? UIGlassEffect)
    XCTAssertNil(effect.tintColor, "no custom tint unless the caller asks for one")
    XCTAssertFalse(effect.isInteractive)
    XCTAssertEqual(view.overrideUserInterfaceStyle, .dark)
    // Nothing that would fight the system material's own adaptation.
    XCTAssertEqual(view.alpha, 1)
    XCTAssertNil(view.backgroundColor)
    XCTAssertTrue(view.contentView.subviews.isEmpty)
    XCTAssertFalse(view.isUserInteractionEnabled)

    let light = NativeGlassPlatformView(frame: .zero, args: ["radius": 16, "dark": false])
    XCTAssertEqual(light.view().overrideUserInterfaceStyle, .light)
  }

  func testNativeGlassTintIsTheSystemTintColor() throws {
    guard #available(iOS 26.0, *) else { throw XCTSkip("UIGlassEffect needs iOS 26") }
    let platformView = NativeGlassPlatformView(
      frame: .zero, args: ["radius": 22, "dark": false, "tint": NSNumber(value: UInt32(0x24FF_0000))])
    let view = try XCTUnwrap(platformView.view() as? UIVisualEffectView)
    let tint = try XCTUnwrap((view.effect as? UIGlassEffect)?.tintColor)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    XCTAssertTrue(tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    XCTAssertEqual(red, 1, accuracy: 0.01)
    XCTAssertEqual(green, 0, accuracy: 0.01)
    XCTAssertEqual(blue, 0, accuracy: 0.01)
    XCTAssertEqual(alpha, CGFloat(0x24) / 255, accuracy: 0.01)
  }

  func testNativeGlassChannelReportsSupportAndReduceTransparency() throws {
    let delegate = AppDelegate()
    let controller = ChannelTestController(name: "native-glass-channel-test")
    delegate.configureNativeGlassChannelIfNeeded(controller: controller)
    let channel = "mali/native_glass"
    XCTAssertEqual(try controller.messages.invoke(channel, method: "isSupported") as? Bool,
                   NativeGlass.isSupported)
    XCTAssertEqual(try controller.messages.invoke(channel, method: "reduceTransparency") as? Bool,
                   UIAccessibility.isReduceTransparencyEnabled)
    // A Reduce Transparency change is pushed to Dart live.
    NotificationCenter.default.post(
      name: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil)
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let pushed = controller.messages.sent
      .filter { $0.channel == channel }
      .compactMap { $0.message.map { codec.decodeMethodCall($0) } }
    XCTAssertEqual(pushed.map(\.method), ["reduceTransparencyChanged"])
    XCTAssertEqual(pushed.first?.arguments as? Bool, UIAccessibility.isReduceTransparencyEnabled)
  }

  func testNativeTabBarReportsItsSystemHeight() throws {
    let messenger = ChannelTestMessenger()
    let platformView = NativeTabBarPlatformView(
      frame: CGRect(x: 0, y: 0, width: 390, height: 120),
      viewId: 7,
      args: ["items": [["symbol": "house", "title": "Home"], ["symbol": "gearshape", "title": "Settings"]],
             "selected": 0, "dark": false, "rtl": false],
      messenger: messenger)
    let container = platformView.view()
    container.setNeedsLayout()
    container.layoutIfNeeded()
    let codec = FlutterStandardMethodCodec.sharedInstance()
    let heights = messenger.sent
      .filter { $0.channel == "mali/native_tab_bar_7" }
      .compactMap { $0.message.map { codec.decodeMethodCall($0) } }
      .filter { $0.method == "height" }
      .compactMap { $0.arguments as? Double }
    let height = try XCTUnwrap(heights.first, "the bar must report its own height")
    print("NativeTabBar system height: \(height)")
    XCTAssertGreaterThan(height, 0)
    // Re-layout with the same width does not re-send (no resize loop).
    container.setNeedsLayout()
    container.layoutIfNeeded()
    XCTAssertEqual(messenger.sent.filter { $0.channel == "mali/native_tab_bar_7" }.count, 1)
  }

  func testNotificationLogConsumePreservesForeignLegacyAndUnboundOrigins() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    try publish(ownerA, cloud: true)
    let owner = try XCTUnwrap(SharedCaptureStore.activeOwner())
    let matching = SharedCaptureStore.NotificationLogEventPayload(
      notificationLogId: "matching", eventType: "created", channel: "ios_shortcut_local",
      notificationType: "test", relatedEntityType: nil, relatedEntityId: nil,
      errorCode: nil, errorReason: nil, occurredAt: "2026-10-11T00:00:00Z",
      eventId: "00000000-0000-4000-8000-000000000001",
      originKind: "native", ownerUid: ownerA, ownerGeneration: owner.generation)
    let foreign = SharedCaptureStore.NotificationLogEventPayload(
      notificationLogId: "foreign", eventType: "created", channel: "ios_shortcut_local",
      notificationType: "test", relatedEntityType: nil, relatedEntityId: nil,
      errorCode: nil, errorReason: nil, occurredAt: matching.occurredAt,
      originKind: "native", ownerUid: ownerB, ownerGeneration: owner.generation)
    let legacy = SharedCaptureStore.NotificationLogEventPayload(
      notificationLogId: "legacy", eventType: "created", channel: "ios_shortcut_local",
      notificationType: "test", relatedEntityType: nil, relatedEntityId: nil,
      errorCode: nil, errorReason: nil, occurredAt: matching.occurredAt)
    var oldGeneration = matching
    oldGeneration.ownerGeneration = owner.generation - 1
    appGroupDefaults.set(try JSONEncoder().encode([matching, foreign, legacy, oldGeneration]),
                         forKey: "pending_notification_log_events_v1")
    XCTAssertNil(SharedCaptureStore.consumePendingNotificationLogEventsJSON())
    XCTAssertNil(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
      ownerUid: ownerA, ownerGeneration: owner.generation + 1))
    let json = try XCTUnwrap(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
      ownerUid: ownerA, ownerGeneration: owner.generation))
    let consumed = try JSONDecoder().decode([SharedCaptureStore.NotificationLogEventPayload].self,
                                            from: Data(json.utf8))
    XCTAssertEqual(consumed.map { $0.notificationLogId }, ["matching"])
    let repeated = try XCTUnwrap(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
      ownerUid: ownerA, ownerGeneration: owner.generation))
    let repeatedEvents = try JSONDecoder().decode([SharedCaptureStore.NotificationLogEventPayload].self,
      from: Data(repeated.utf8))
    XCTAssertEqual(repeatedEvents.map { $0.eventId }, consumed.map { $0.eventId })
    XCTAssertFalse(SharedCaptureStore.acknowledgeNotificationLogEvent(
      eventId: matching.eventId!, ownerUid: ownerB, ownerGeneration: owner.generation))
    XCTAssertFalse(SharedCaptureStore.acknowledgeNotificationLogEvent(
      eventId: "malformed", ownerUid: ownerA, ownerGeneration: owner.generation))
    XCTAssertTrue(SharedCaptureStore.acknowledgeNotificationLogEvent(
      eventId: matching.eventId!, ownerUid: ownerA, ownerGeneration: owner.generation))
    let retainedData = try XCTUnwrap(appGroupDefaults.data(forKey: "pending_notification_log_events_v1"))
    let retained = try JSONDecoder().decode([SharedCaptureStore.NotificationLogEventPayload].self,
                                            from: retainedData)
    XCTAssertEqual(retained.map { $0.notificationLogId }, ["foreign", "legacy", "matching"])
    XCTAssertEqual(retained.last?.ownerGeneration, owner.generation - 1)
    XCTAssertNil(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
      ownerUid: ownerA, ownerGeneration: owner.generation))
  }

  func testNotificationLifecycleRetainsCaptureOriginAcrossOwnerSwitch() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    try publish(ownerA)
    let firstOwner = try XCTUnwrap(SharedCaptureStore.activeOwner())
    guard case .enqueued(let capture) = SharedCaptureStore.enqueue(
      text: "purchase 5.00 SAR", sender: "ACME") else {
      return XCTFail("capture setup failed")
    }
    let captureQueueBeforeSwitch = try XCTUnwrap(queueFileData())
    SharedCaptureStore.enqueueNotificationLogEvent(notificationLogId: "attempt",
      eventType: "created", channel: "ios_shortcut_local", notificationType: "test",
      relatedEntityType: "payload", relatedEntityId: capture.id)
    try publish(ownerB)
    SharedCaptureStore.enqueueNotificationLogEvent(notificationLogId: "attempt",
      eventType: "sent", channel: "ios_shortcut_local", notificationType: "test",
      relatedEntityType: "payload", relatedEntityId: capture.id)
    let owner = try XCTUnwrap(SharedCaptureStore.activeOwner())
    XCTAssertNil(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
      ownerUid: ownerB, ownerGeneration: owner.generation))
    let data = try XCTUnwrap(appGroupDefaults.data(forKey: "pending_notification_log_events_v1"))
    let events = try JSONDecoder().decode([SharedCaptureStore.NotificationLogEventPayload].self, from: data)
    XCTAssertEqual(events.count, 2)
    XCTAssertTrue(events.allSatisfy { $0.ownerUid == ownerA &&
      $0.ownerGeneration == firstOwner.generation && $0.originKind == "native" })
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(),
                 "owner B cannot import owner A's capture")
    XCTAssertEqual(queueFileData(), captureQueueBeforeSwitch,
                   "owner switch and notification events preserve encrypted capture bytes")
  }

  // F2 ownerless snapshot contract: inspection must never manufacture keys or authority.
  private func resetSnapshotState() {
    SharedCaptureStore.purgeUserOwnedState()
    for key in ["active_capture_owner_v1", "last_admitted_uid_hash_v1",
                "capture_uid_hmac_key_v1", "cloud_egress_state_v1",
                "cloud_egress_pending_v1"] {
      SnapshotTestKeychain.remove(forKey: key)
    }
    for key in ["capture_owner_epoch_v1", "capture_owner_generation_v1",
                "capture_consent_mirror_v1"] { appGroupDefaults.removeObject(forKey: key) }
    for file in ["cloud_egress_state_v1.json", "capture_destructive_barrier_v1.json",
                 "native_inflight_uploads_v1.json", "cloud_egress_pending_v1.json"] {
      try? FileManager.default.removeItem(at: container.appendingPathComponent(file))
    }
    SharedCaptureStore.ownerRecordReadOverride = nil
    SharedCaptureStore.egressKeychainReadOverride = nil
  }

  func testOwnerlessSnapshotFreshIsReadOnly() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""),
                   .ownerless(epoch: 0, generation: 0))
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA), .unset)
    for key in ["active_capture_owner_v1", "last_admitted_uid_hash_v1",
                "capture_uid_hmac_key_v1", "capture_queue_key_v1"] {
      XCTAssertEqual(SnapshotTestKeychain.read(forKey: key).status, errSecItemNotFound)
    }
    XCTAssertNil(appGroupDefaults.object(forKey: "capture_owner_generation_v1"))
  }

  func testOwnerlessSnapshotAfterRemovalKeepsRevocationAndKeysUnchanged() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    try publish(ownerA, cloud: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 2)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    _ = try SharedCaptureStore.finishRemoval(uid: ownerA)
    let key = SnapshotTestKeychain.read(forKey: "capture_uid_hmac_key_v1").data
    let epoch = try SharedCaptureStore.ownerEpoch()
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""),
                   .ownerless(epoch: epoch, generation: 1))
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: "capture_uid_hmac_key_v1").data, key)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: "capture_queue_key_v1").status, errSecItemNotFound)
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerA, mirror: .init(cloud: true, ai: true, version: 2),
      expectedEpoch: epoch - 1, transitionGeneration: 1))
    XCTAssertNil(try SharedCaptureStore.activeOwner())
  }

  func testOwnerlessSnapshotBlocksKnownAndUnknownRemovalBarrier() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    // The UID is not recoverable from this barrier, but it must still block.
    let barrier = #"{"nonce":"n","uidHash":"unknown","startedAt":"2026-01-01T00:00:00Z"}"#
    try Data(barrier.utf8).write(to: container.appendingPathComponent("capture_destructive_barrier_v1.json"))
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
  }

  func testOwnerlessSnapshotFailsClosedOnCorruptOrUnreadableEvidence() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    appGroupDefaults.set("invalid", forKey: "capture_owner_epoch_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    appGroupDefaults.removeObject(forKey: "capture_owner_epoch_v1")
    appGroupDefaults.set(-1, forKey: "capture_owner_generation_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    appGroupDefaults.removeObject(forKey: "capture_owner_generation_v1")
    SharedCaptureStore.ownerRecordReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertThrowsError(try SharedCaptureStore.cloudEgressState(forUid: ""))
    SharedCaptureStore.ownerRecordReadOverride = nil
    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    SharedCaptureStore.egressKeychainReadOverride = nil
    _ = SnapshotTestKeychain.writeData(Data([0xff]), forKey: "last_admitted_uid_hash_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
  }

  func testOwnerlessSnapshotRejectsUnverifiableOwnedAndTransitionState() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    try publish(ownerA, cloud: false)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 2)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 2)
    SnapshotTestKeychain.remove(forKey: "capture_uid_hmac_key_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA), .uncertain)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: "capture_uid_hmac_key_v1").status, errSecItemNotFound)
  }

  func testOwnerlessSnapshotHistoricalOnHintIsNotAuthority() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    try publish(ownerA)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 1)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    let epoch = try SharedCaptureStore.ownerEpoch()
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""),
                   .ownerless(epoch: epoch, generation: 1))
    XCTAssertNil(try SharedCaptureStore.activeOwner())
  }

  func testOwnerlessSnapshotRejectsEgressMismatchMissingCopyAndInflight() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    let owner = try publish(ownerA, cloud: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 1)
    try SharedCaptureStore.clearActiveOwner(clearHint: true)
    let egressFile = container.appendingPathComponent("cloud_egress_state_v1.json")
    let saved = try Data(contentsOf: egressFile)
    try Data(#"{"owners":{}}"#.utf8).write(to: egressFile)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    try FileManager.default.removeItem(at: egressFile)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    try saved.write(to: egressFile)
    let inflightFile = container.appendingPathComponent("native_inflight_uploads_v1.json")
    let live = "[{\"payloadId\":\"p\",\"ownerHash\":\"\(owner.uidHash)\",\"deadline\":\(Date().timeIntervalSince1970 + 60)}]"
    try Data(live.utf8).write(to: inflightFile)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    try Data("corrupt".utf8).write(to: inflightFile)
    XCTAssertThrowsError(try SharedCaptureStore.cloudEgressState(forUid: ""))
  }

  func testSnapshotStrictMetadataAndOwnedGenerationPreserveRestrictiveRevoke() throws {
    resetSnapshotState()
    defer { resetSnapshotState() }
    let owner = try publish(ownerA)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 1)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA),
                   .record(.init(state: "ON", transitionGeneration: 1, reservedVersion: 1)))
    appGroupDefaults.set(2, forKey: "capture_owner_generation_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA), .uncertain)
    appGroupDefaults.set(1, forKey: "capture_owner_generation_v1")
    appGroupDefaults.set(true, forKey: "capture_owner_epoch_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA), .uncertain)
    appGroupDefaults.set(0, forKey: "capture_owner_epoch_v1")
    let corruptOwner = SharedCaptureStore.OwnerRecord(uid: ownerA, uidHash: String(repeating: "0", count: 64), generation: 1)
    SharedCaptureStore.ownerRecordReadOverride = { (errSecSuccess, try? JSONEncoder().encode(corruptOwner)) }
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA), .uncertain)
    SharedCaptureStore.ownerRecordReadOverride = nil
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    for malformed in [true as Any, 1.5 as Any] {
      appGroupDefaults.set([owner.uidHash: ["cloud": false, "ai": false, "version": malformed]],
                           forKey: "capture_consent_mirror_v1")
      XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    }
    appGroupDefaults.set([owner.uidHash: ["cloud": 0, "ai": false, "version": 1]],
                         forKey: "capture_consent_mirror_v1")
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
    appGroupDefaults.removeObject(forKey: "capture_consent_mirror_v1")
    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 2)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ownerA),
                   .record(.init(state: "DISABLING", transitionGeneration: 2, reservedVersion: 2)))
  }

  // MARK: - Build-52 (81c59422) in-place upgrade state: native egress snapshot

  /// Seeds exactly what build 52 persisted for a signed-in user: active owner
  /// record + last-admitted hint (Keychain), HMAC key (Keychain), owner
  /// generation / epoch counters and the consent mirror (App Group defaults),
  /// and, when [egressOn], the LEGACY egress map (no lifecycle fields, no
  /// retirement) identically in the Keychain item and the App Group file. No
  /// pending-enable barrier, no lifetime fields. Returns the owner's hash.
  @discardableResult
  private func seedBuild52(
    egressOn: Bool, epoch: Int = 0, signedOut: Bool = false, mirrorCloud: Bool = true
  ) throws -> SharedCaptureStore.OwnerRecord {
    resetSnapshotState()
    let owner = try publish(ownerA, cloud: mirrorCloud)
    if egressOn {
      let data = try egressJSON([(ownerA, "ON", 1)])
      try data.write(to: egressFileURL, options: .atomic)
      XCTAssertEqual(SnapshotTestKeychain.writeData(data, forKey: "cloud_egress_state_v1"), errSecSuccess)
    }
    if signedOut {
      try SharedCaptureStore.clearActiveOwner(clearHint: false)
    }
    if epoch > 0 {
      appGroupDefaults.set(epoch, forKey: "capture_owner_epoch_v1")
    }
    return owner
  }

  private func describe52(_ label: String, _ uid: String) -> String {
    let state: String
    do { state = "\(try SharedCaptureStore.cloudEgressState(forUid: uid))" }
    catch { state = "THROWS \(error)" }
    let pending: String
    if uid.isEmpty { pending = "n/a (Dart passes non-empty only)" }
    else if let p = try? SharedCaptureStore.cloudEgressPending(forUid: uid) {
      pending = "status=\(p.status.rawValue) opId=\(p.operationId ?? "nil") barrier=\(p.barrier.map { $0.outcome }) egress=\(p.egress.map { $0.outcome })"
    } else { pending = "THROWS" }
    let line = "BUILD52 \(label) uid=\(uid.isEmpty ? "<empty>" : "owner") state=\(state) | pending: \(pending)"
    print(line)
    return state
  }

  func testBuild52UpgradeSignedInCloudOnLegacyOnRecord() throws {
    defer { resetSnapshotState() }
    for epoch in [0, 3] {
      try seedBuild52(egressOn: true, epoch: epoch)
      let own = describe52("signedIn+ON-legacy epoch=\(epoch)", ownerA)
      let none = describe52("signedIn+ON-legacy epoch=\(epoch)", "")
      XCTAssertEqual(try egressState(ownerA),
                     .record(.init(state: "ON", transitionGeneration: 1, reservedVersion: 2)), own)
      // An active owner makes the ownerless snapshot uncertain (by design).
      XCTAssertEqual(try egressState(""), .uncertain, none)
    }
  }

  func testBuild52UpgradeVariantA_OwnerPresentNoEgressMapsAtAll() throws {
    defer { resetSnapshotState() }
    try seedBuild52(egressOn: false)
    let own = describe52("A owner,no egress maps", ownerA)
    _ = describe52("A owner,no egress maps", "")
    XCTAssertEqual(try egressState(ownerA), .unset, own)
  }

  func testBuild52UpgradeVariantB_NoActiveOwnerKeychainHintPresent() throws {
    defer { resetSnapshotState() }
    for withOn in [false, true] {
      try seedBuild52(egressOn: withOn, signedOut: true)
      XCTAssertEqual(SnapshotTestKeychain.read(forKey: "last_admitted_uid_hash_v1").status, errSecSuccess)
      XCTAssertEqual(SnapshotTestKeychain.read(forKey: "active_capture_owner_v1").status, errSecItemNotFound)
      let own = describe52("B signedOut,hint,ON=\(withOn)", ownerA)
      let none = describe52("B signedOut,hint,ON=\(withOn)", "")
      XCTAssertNotEqual(try egressState(ownerA), .uncertain, own)
      XCTAssertNotEqual(try egressState(""), .uncertain, none)
    }
  }

  func testBuild52UpgradeVariantC_ConsentMirrorWithoutLifecycleFields() throws {
    defer { resetSnapshotState() }
    // Mirror entries are {cloud, ai, version} only; the ON egress record has no
    // lifetimeOwnerGeneration / lifetimeOwnerEpoch / retirement.
    let owner = try seedBuild52(egressOn: true)
    let raw = try Data(contentsOf: egressFileURL)
    let json = try XCTUnwrap(String(data: raw, encoding: .utf8))
    XCTAssertFalse(json.contains("lifetime"))
    XCTAssertFalse(json.contains("retirement"))
    let mirrors = try XCTUnwrap(appGroupDefaults.dictionary(forKey: "capture_consent_mirror_v1"))
    XCTAssertEqual(Set((mirrors[owner.uidHash] as? [String: Any] ?? [:]).keys), ["cloud", "ai", "version"])
    let own = describe52("C mirror-only+legacy ON", ownerA)
    XCTAssertEqual(try egressState(ownerA),
                   .record(.init(state: "ON", transitionGeneration: 1, reservedVersion: 2)), own)
    // Signed-out after 52 sign-out (owner cleared, hint kept, ON kept).
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    _ = describe52("C after sign-out", ownerA)
    _ = describe52("C after sign-out", "")
    XCTAssertNotEqual(try egressState(ownerA), .uncertain)
    XCTAssertEqual(try egressState(""), .ownerless(epoch: 1, generation: 1))
  }

  /// Diagnostic only: the reason constant names the branch that produced
  /// `.uncertain`, and the answer itself is unchanged.
  func testEgressUncertainReasonNamesTheBranch() throws {
    defer { resetSnapshotState() }
    func diagnosed(_ uid: String) throws -> (SharedCaptureStore.EgressSnapshot, String) {
      let snap = try egressState(uid)
      return (snap, snap == .uncertain ? SharedCaptureStore.lastEgressUncertainReason : "")
    }
    // Clean build-52 state: no reason.
    try seedBuild52(egressOn: true)
    var r = try diagnosed(ownerA)
    XCTAssertEqual(r.1, "")
    // Ownerless read with an active owner present.
    r = try diagnosed("")
    XCTAssertEqual(r.0, .uncertain)
    XCTAssertEqual(r.1, "ownerless_active_owner")
    // Generation counter removed: reads as 0, which disagrees with the owner.
    try seedBuild52(egressOn: true)
    appGroupDefaults.removeObject(forKey: "capture_owner_generation_v1")
    r = try diagnosed(ownerA)
    XCTAssertEqual(r.0, .uncertain)
    XCTAssertEqual(r.1, "owner_generation_mismatch")
    // Generation counter disagrees with the active owner record.
    try seedBuild52(egressOn: true)
    let generation = appGroupDefaults.integer(forKey: "capture_owner_generation_v1")
    appGroupDefaults.set(generation + 5, forKey: "capture_owner_generation_v1")
    r = try diagnosed(ownerA)
    XCTAssertEqual(r.1, "owner_generation_mismatch")
    // Copies of the owner's record differ.
    try seedBuild52(egressOn: true)
    try egressJSON([(ownerA, "ON", 2)]).write(to: egressFileURL, options: .atomic)
    r = try diagnosed(ownerA)
    XCTAssertEqual(r.0, .uncertain)
    XCTAssertFalse(r.1.isEmpty)
    // A reason is never a uid, hash or value.
    XCTAssertNotNil(r.1.range(of: "^[a-z_/]+$", options: .regularExpression))
  }

  /// Keychain outlives an app deletion, the app-group counter does not: the
  /// owner record names generation N while the counter is missing / lower. The
  /// repair re-claims the SAME owner with a fresh generation and nothing else.
  func testRepairActiveOwnerGenerationOnlyFixesTheCounterOfTheSameOwner() throws {
    defer { resetSnapshotState() }
    let counterKey = "capture_owner_generation_v1"
    for scenario in ["missing", "lower", "higher"] {
      let owner = try seedBuild52(egressOn: true)
      let epochBefore = try SharedCaptureStore.ownerEpoch()
      switch scenario {
      case "missing": appGroupDefaults.removeObject(forKey: counterKey)
      case "lower": appGroupDefaults.set(owner.generation - 1, forKey: counterKey)
      default: appGroupDefaults.set(owner.generation + 7, forKey: counterKey)
      }
      XCTAssertEqual(try egressState(ownerA), .uncertain, scenario)
      XCTAssertEqual(SharedCaptureStore.lastEgressUncertainReason, "owner_generation_mismatch", scenario)

      // A different uid is never repairable, and nothing changes.
      XCTAssertThrowsError(try SharedCaptureStore.repairActiveOwnerGeneration(uid: ownerB), scenario)
      XCTAssertEqual(try egressState(ownerA), .uncertain, scenario)

      let mirrorBefore = appGroupDefaults.dictionary(forKey: "capture_consent_mirror_v1") as NSDictionary?
      let repaired = try SharedCaptureStore.repairActiveOwnerGeneration(uid: ownerA)
      XCTAssertEqual(appGroupDefaults.dictionary(forKey: "capture_consent_mirror_v1") as NSDictionary?,
                     mirrorBefore, "consent mirror unchanged")
      XCTAssertEqual(repaired.uid, owner.uid)
      XCTAssertEqual(repaired.uidHash, owner.uidHash)
      XCTAssertGreaterThan(repaired.generation, max(owner.generation, appGroupDefaults.integer(forKey: counterKey) - 1),
                           scenario)
      XCTAssertEqual(try SharedCaptureStore.activeOwner()?.generation, repaired.generation)
      XCTAssertEqual(appGroupDefaults.integer(forKey: counterKey), repaired.generation)
      XCTAssertEqual(try SharedCaptureStore.ownerEpoch(), epochBefore, "epoch untouched")
      // Clean named-owner answer, the ON record is untouched.
      XCTAssertEqual(try egressState(ownerA),
                     .record(.init(state: "ON", transitionGeneration: 1, reservedVersion: 2)), scenario)
      // Idempotent once consistent.
      XCTAssertEqual(try SharedCaptureStore.repairActiveOwnerGeneration(uid: ownerA), repaired)
    }
    // No active owner: refused.
    try seedBuild52(egressOn: true, signedOut: true)
    XCTAssertThrowsError(try SharedCaptureStore.repairActiveOwnerGeneration(uid: ownerA))
  }

  func testShortcutPersistsBeforeNetworkAndUsesStablePayloadID() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    let persist = try XCTUnwrap(source.range(of: "status: .pendingSend"))
    let network = try XCTUnwrap(source.range(of: "let attempt = await processBackend"))
    XCTAssertLessThan(persist.lowerBound, network.lowerBound)
  }

  /// H-19 durability contract: on a SUCCESSFUL backend capture the App Intent
  /// must RETAIN the durable local copy (mark it `.sent`) rather than delete it.
  /// Deleting it made processed_captures (swept unconditionally at 30 days) the
  /// only copy, so an unopened app lost a capture the user was told succeeded.
  /// This fails against the pre-fix source, which called
  /// `SharedCaptureStore.remove(payloadID: payloadID)` on success.
  func testShortcutRetainsDurableCopyOnBackendSuccess() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    // The success branch begins at `if let response = attempt.response`.
    let successBranch = try XCTUnwrap(source.range(of: "if let response = attempt.response"))
    let branchTail = String(source[successBranch.lowerBound...])
    XCTAssertTrue(
      branchTail.contains("SharedCaptureStore.updateStatus(payloadID: payloadID, status: .sent)"),
      "backend success must keep a durable local copy as .sent for the host drain to import"
    )
    XCTAssertFalse(
      source.contains("SharedCaptureStore.remove(payloadID: payloadID)"),
      "the App Intent must NOT delete the only durable local copy on backend success (H-19)"
    )
  }

  /// The two physical copies of SharedCaptureStore.swift (Runner + the Share
  /// Extension; the App Intent target compiles one of them via membership) must
  /// stay byte-identical.
  func testSharedCaptureStoresRemainByteIdentical() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let paths = [
      "Runner/SharedCaptureStore.swift",
      "ShareBankMessage/SharedCaptureStore.swift",
    ]
    let values = try paths.map {
      try Data(contentsOf: root.appendingPathComponent($0))
    }
    XCTAssertEqual(values[0], values[1])
  }

  /// A-12-min R4: publishing writes the owner's consent mirror with the owner, in
  /// one flock, compare-and-swap on the owner epoch. The default is Cloud ON, so
  /// the stamped items are upload-eligible exactly as before A-12-min.
  @discardableResult
  private func publish(
    _ uid: String, cloud: Bool = true, ai: Bool = false, version: Int = 1
  ) throws -> SharedCaptureStore.OwnerRecord {
    try SharedCaptureStore.publishActiveOwner(
      uid: uid,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: cloud, ai: ai, version: version),
      expectedEpoch: try SharedCaptureStore.ownerEpoch())
  }

  private var appGroupDefaults: UserDefaults {
    UserDefaults(suiteName: SharedCaptureStore.appGroupIdentifier)!
  }

  private var container: URL {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: SharedCaptureStore.appGroupIdentifier)!
  }

  /// CAP-6: queue v3 is an encrypted file in the App Group container.
  private var queueFileURL: URL {
    container.appendingPathComponent("pending_bank_messages_v3.bin")
  }

  private func queueFileData() -> Data? { try? Data(contentsOf: queueFileURL) }

  private let ownerA = "11111111-1111-4111-8111-111111111111"
  private let ownerB = "22222222-2222-4222-8222-222222222222"

  // MALI-031 — the capture queue is encrypted at rest; the raw SMS never appears
  // as plaintext in App Group UserDefaults, but round-trips out via the store.
  func testCaptureQueueEncryptedAtRestAndRoundTrips() throws {
    SharedCaptureStore.purgeUserOwnedState()
    try publish(ownerA)
    let secret = "ACME: purchase 512.34 SAR on card 4417"
    let result = SharedCaptureStore.enqueue(text: secret, sender: "ACME")
    if case .failed(let reason, _) = result { XCTFail("enqueue failed: \(reason)") }

    let json = try XCTUnwrap(SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains(secret), "the store must decrypt back to plaintext")

    let blob = try XCTUnwrap(queueFileData())
    let asText = String(data: blob, encoding: .utf8) ?? ""
    XCTAssertFalse(asText.contains(secret), "raw SMS must NOT be stored in plaintext")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // A legacy plaintext-JSON v2 blob is still readable, and (§4.7) migrates to v3
  // as UNBOUND with no hint: never importable by the active owner.
  func testLegacyPlaintextQueueStillReads() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let legacy = "[{\"id\":\"abc\",\"text\":\"legacy 10.00\",\"status\":\"pending\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: "pending_bank_messages_v2")
    try publish(ownerA)
    let items = try SharedCaptureStore.queueSnapshot()
    XCTAssertEqual(items.map { $0.text }, ["legacy 10.00"])
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(),
                 "a migrated item is quarantined, never imported by the active owner")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // A corrupt/undecryptable blob fails closed (empty) and is NOT deleted.
  func testCorruptQueueFailsClosedWithoutDeleting() throws {
    SharedCaptureStore.purgeUserOwnedState()
    let corrupt = Data([0x01, 0x02, 0x03, 0xFF, 0x00, 0x99])
    appGroupDefaults.set(corrupt, forKey: "pending_bank_messages_v2")
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages(), "fail closed → looks empty")
    XCTAssertNotNil(appGroupDefaults.data(forKey: "pending_bank_messages_v2"),
                    "the blob must NOT be deleted on a decrypt failure")
    SharedCaptureStore.purgeUserOwnedState()
  }

  // MALI-031 — the device secret lives in the Keychain, never UserDefaults, and
  // is invalidated by purge.
  func testDeviceSecretNotInUserDefaults() throws {
    SharedCaptureStore.purgeUserOwnedState()
    SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true,
      installID: "install-1",
      deviceSecret: "top-secret-device-key",
      backendURL: "https://example.test",
      anonKey: "anon",
      aiConsentGranted: true
    )
    XCTAssertNil(appGroupDefaults.string(forKey: "device_secret"),
                 "the device secret must not be in App Group UserDefaults")
    XCTAssertEqual(SharedCaptureStore.backendConfig().deviceSecret,
                   "top-secret-device-key",
                   "the secret must round-trip via the Keychain")
    SharedCaptureStore.purgeUserOwnedState()
    XCTAssertNil(SharedCaptureStore.backendConfig().deviceSecret,
                 "purge/wipe invalidates the device secret")
  }

  // ── CAP-0: queue key / lock failures never destroy the queue ───────────────
  //
  // These drive the two internal seams on SharedCaptureStore
  // (queueKeyReadOverride, lockUnavailableOverride). They need a device or
  // simulator with the App Group + Keychain entitlements; they cannot run in
  // the Linux/Dart CI (the Dart source-contract tests pin the same properties).

  private let queueDefaultsKey = "pending_bank_messages_v2"  // legacy v2 blob (migration source)

  private func resetCapSeams() {
    SharedCaptureStore.queueKeyReadOverride = nil
    SharedCaptureStore.lockUnavailableOverride = false
    SharedCaptureStore.ownerRecordReadOverride = nil
    SharedCaptureStore.stampingHook = nil
    SharedCaptureStore.beforeLifetimeFinishLock = nil
    SharedCaptureStore.clockOverride = nil
    SharedCaptureStore.egressKeychainReadOverride = nil
    SharedCaptureStore.durableWriteFault = nil
    SharedCaptureStore.debugResetCloudEgressState()
    try? FileManager.default.removeItem(
      at: container.appendingPathComponent("capture_destructive_barrier_v1.json"))
    SharedCaptureStore.purgeUserOwnedState()
  }

  // T-Q1: a Keychain read error (errSecInteractionNotAllowed = before first
  // unlock) must not generate a new key or touch the blob. If it had replaced
  // the key, the original blob could no longer be decrypted afterwards.
  func testKeyReadErrorFailsWithoutNewKeyAndKeepsBlob() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    try publish(ownerA)
    let first = "ACME: purchase 77.10 SAR"
    if case .failed(let reason, _) = SharedCaptureStore.enqueue(text: first, sender: "ACME") {
      return XCTFail("setup enqueue failed: \(reason)")
    }
    let before = try XCTUnwrap(queueFileData())

    SharedCaptureStore.queueKeyReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    guard case .failed(_, let kind) = SharedCaptureStore.enqueue(text: "second 5.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail while the key is unreadable")
    }
    XCTAssertEqual(kind, .deviceLocked, "errSecInteractionNotAllowed is the locked-device case")
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertFalse(SharedCaptureStore.remove(payloadID: "anything"))
    XCTAssertEqual(queueFileData(), before, "the encrypted blob must be untouched")

    SharedCaptureStore.queueKeyReadOverride = nil
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains(first), "the original key must still decrypt the blob")
    XCTAssertFalse(json.contains("second 5.00"))
  }

  // T-Q2: no lock, no write. The body never runs unlocked.
  func testLockUnavailableThrowsAndWritesNothing() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    _ = SharedCaptureStore.enqueue(text: "ACME: purchase 9.00 SAR", sender: "ACME")
    let before = try XCTUnwrap(queueFileData())

    SharedCaptureStore.lockUnavailableOverride = true
    guard case .failed = SharedCaptureStore.enqueue(text: "other 1.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail without the lock")
    }
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON()) { error in
      guard case SharedCaptureStore.QueueError.lockUnavailable = error else {
        return XCTFail("unexpected error \(error)")
      }
    }
    XCTAssertFalse(SharedCaptureStore.purgeUserOwnedState(), "an unlocked purge must not run")
    XCTAssertEqual(queueFileData(), before)
  }

  // T-Q3: a blob that cannot be decrypted is not an empty queue; the next
  // enqueue must not overwrite it.
  func testUnreadableBlobIsNeverOverwritten() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    let corrupt = Data([0x01, 0x02, 0x03, 0xFF, 0x00, 0x99])
    try corrupt.write(to: queueFileURL)
    guard case .failed = SharedCaptureStore.enqueue(text: "new 3.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail on an unreadable blob")
    }
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertEqual(queueFileData(), corrupt)
    // The same holds for an unreadable v2 blob that has not migrated yet.
    SharedCaptureStore.purgeUserOwnedState()
    appGroupDefaults.set(corrupt, forKey: queueDefaultsKey)
    guard case .failed = SharedCaptureStore.enqueue(text: "new 4.00 SAR", sender: "ACME") else {
      return XCTFail("enqueue must fail on an unreadable v2 blob")
    }
    XCTAssertEqual(appGroupDefaults.data(forKey: queueDefaultsKey), corrupt)
    XCTAssertNil(queueFileData(), "no v3 file may be created over an unreadable v2 queue")
  }

  // T-Q4: the App Intent surfaces a persistence failure as a thrown, localized
  // error instead of silently returning a result.
  @available(iOS 16.0, *)
  func testIntentThrowsVisibleErrorWhenQueueUnavailable() async throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    SharedCaptureStore.queueKeyReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    let intent = PostBankStatusIntent()
    intent.smsText = "ACME: purchase 12.00 SAR"
    intent.dateReceived = Date()
    do {
      _ = try await intent.perform()
      XCTFail("perform must throw when the capture cannot be persisted")
    } catch let error as ProcessBankSMSError {
      // R9 copy rule: the approved locked-device text, never technical detail.
      let message = try XCTUnwrap(error.errorDescription)
      XCTAssertEqual(message, SharedCaptureStore.FailureKind.deviceLocked.userMessage)
      for leak in ["errSec", "-25308", "keyUnavailable", "OSStatus", "process_bank_sms_error", "%@"] {
        XCTAssertFalse(message.contains(leak), "user-facing error leaked \(leak)")
      }
    } catch {
      XCTFail("unexpected error \(error)")
    }

    intent.smsText = "   "
    do {
      _ = try await intent.perform()
      XCTFail("perform must throw on empty text")
    } catch {
      XCTAssertTrue(error is ProcessBankSMSError)
    }
  }

  // R9: the inferred-date marker round-trips through the queue.
  func testReceivedAtInferredRoundTrips() throws {
    SharedCaptureStore.purgeUserOwnedState()
    defer { resetCapSeams() }
    try publish(ownerA)
    _ = SharedCaptureStore.enqueue(
      text: "ACME: purchase 4.00 SAR", sender: "ACME", receivedAtInferred: true)
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("\"receivedAtInferred\":true"))
  }


  // ── CAP-6: queue v3 (owner record, stamping, quotas, claim CAS, barrier) ───
  //
  // Device/simulator only (App Group + Keychain). The Dart source-contract test
  // test/architecture/capture_queue_cap6_contract_test.dart pins the same
  // properties on Linux CI.

  @discardableResult
  private func put(_ text: String, sender: String = "ACME") -> SharedCaptureStore.EnqueueResult {
    SharedCaptureStore.enqueue(text: text, sender: sender, source: "ios_shortcut")
  }

  private func items() throws -> [SharedCaptureStore.Payload] {
    try SharedCaptureStore.queueSnapshot()
  }

  // Stamping: owner present -> stamped; none -> unbound + hint; transition -> no hint.
  func testStampingOwnerUnboundHintAndTransition() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    put("stamped 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)   // sign-out
    put("signed out 2.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: true)    // transition
    put("transition 3.00 SAR")

    let queue = try items()
    let stamped = try XCTUnwrap(queue.first { $0.text.hasPrefix("stamped") })
    XCTAssertEqual(stamped.ownerState, "stamped")
    XCTAssertEqual(stamped.ownerUid, ownerA)
    XCTAssertEqual(stamped.ownerGeneration, a.generation)
    XCTAssertNil(stamped.ownerHint)

    let signedOut = try XCTUnwrap(queue.first { $0.text.hasPrefix("signed out") })
    XCTAssertEqual(signedOut.ownerState, "unbound")
    XCTAssertNil(signedOut.ownerUid)
    XCTAssertEqual(signedOut.ownerHint, a.uidHash, "the hint is only the last admitted uidHash")

    let transition = try XCTUnwrap(queue.first { $0.text.hasPrefix("transition") })
    XCTAssertEqual(transition.ownerState, "unbound")
    XCTAssertNil(transition.ownerHint, "a transition capture carries no hint")
  }

  // Non-active owner: A's item waits (not visible to B, not purged) and resumes for A.
  func testNonActiveOwnerItemWaitsAndResumes() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("A item 5.00 SAR")
    try publish(ownerB)
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(), "B must not see A's capture")
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages())
    XCTAssertEqual(try items().count, 1, "A's item is not purged")
    try publish(ownerA)
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("A item 5.00 SAR"))
  }

  // Owner mismatch: an upload is allowed only under the stamped {uid, generation}.
  func testUploadAuthorizationOwnerMismatchAndConsentMirror() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    guard case .enqueued(let item) = put("upload 6.00 SAR") else { return XCTFail("enqueue") }
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false),
                   "published with a Cloud-ON mirror (ai false)")

    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: false, version: 3)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false))
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: false, ai: false, version: 4)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "cloud OFF in the owner's mirror means zero egress")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 5)

    try publish(ownerB)      // owner changed mid-flight
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .waiting)
    try publish(ownerA)      // same uid, NEW generation
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .waiting,
                   "a changed generation is not 'unchanged'")
    XCTAssertGreaterThan(try XCTUnwrap(SharedCaptureStore.activeOwner()).generation, a.generation)

    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    guard case .enqueued(let unbound) = put("unbound 7.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(unbound.id)),
                   .localOnly, "unbound: zero egress, zero AI")
  }

  // Keychain unavailable while reading the owner record: nothing is persisted.
  func testOwnerRecordUnavailablePersistsNothing() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("before 1.00 SAR")
    let before = try XCTUnwrap(queueFileData())
    SharedCaptureStore.ownerRecordReadOverride = { (status: errSecInteractionNotAllowed, data: nil) }
    guard case .failed(_, let kind) = put("during 2.00 SAR") else {
      return XCTFail("enqueue must fail while the owner record is unreadable")
    }
    XCTAssertEqual(kind, .deviceLocked)
    XCTAssertEqual(queueFileData(), before)
  }

  // The owner read, the stamp and the write happen while the flock is held.
  func testFlockHeldDuringStamping() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    var probed = false
    SharedCaptureStore.stampingHook = {
      let fd = open(self.container.appendingPathComponent("pending_bank_messages.lock").path,
                    O_RDWR)
      defer { if fd >= 0 { close(fd) } }
      XCTAssertGreaterThanOrEqual(fd, 0)
      XCTAssertNotEqual(flock(fd, LOCK_EX | LOCK_NB), 0, "the flock must be held while stamping")
      XCTAssertEqual(errno, EWOULDBLOCK)
      probed = true
    }
    put("locked 8.00 SAR")
    XCTAssertTrue(probed)
  }

  private func big(_ tag: String, _ chars: Int) -> String {
    tag + String(repeating: "x", count: chars)
  }

  // §4.5 capacity (owner-approved change, 2026-11-12): the old quotas (500 /
  // 2 MB per owner, 200 / 512 KB unbound, 8 MB device) no longer refuse a
  // capture. A full main file opens an encrypted overflow segment; nothing is
  // evicted and no older message is overwritten.
  func testCapacityValuesAreSegmentSizesNotQuotas() {
    XCTAssertEqual(SharedCaptureStore.segmentMaxItems, 500)
    XCTAssertEqual(SharedCaptureStore.segmentMaxBytes, 2 * 1024 * 1024)
    XCTAssertEqual(SharedCaptureStore.maxItemBytes, SharedCaptureStore.segmentMaxBytes)
    XCTAssertEqual(SharedCaptureStore.unboundExpiryDays, 30)
  }

  private var overflowDir: URL {
    container.appendingPathComponent("pending_bank_messages_v3_overflow", isDirectory: true)
  }

  private var quarantineDir: URL {
    container.appendingPathComponent("pending_bank_messages_v3_quarantine", isDirectory: true)
  }

  private func segmentURL(_ seq: Int) -> URL {
    overflowDir.appendingPathComponent("seg-" + String(format: "%016d", seq) + ".bin")
  }

  private func segmentNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: overflowDir.path)) ?? []).sorted()
  }

  private func quarantineNames() -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: quarantineDir.path)) ?? []).sorted()
  }

  /// The texts Dart would receive from `peekPendingSharedMessages`, in order.
  private func peekTexts() throws -> [String] {
    guard let json = try SharedCaptureStore.peekPendingPayloadsJSON() else { return [] }
    let array = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    return array.compactMap { $0["text"] as? String }
  }

  private func peekIDs() throws -> [String] {
    guard let json = try SharedCaptureStore.peekPendingPayloadsJSON() else { return [] }
    let array = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
    return array.compactMap { $0["id"] as? String }
  }

  @discardableResult
  private func fill(_ count: Int, _ tag: String, from start: Int = 0) -> [String] {
    var texts: [String] = []
    for i in start..<(start + count) {
      let text = "\(tag) \(i) 1.00 SAR"
      guard case .enqueued = put(text) else {
        XCTFail("capture \(i) was not saved")
        return texts
      }
      texts.append(text)
    }
    return texts
  }

  // Boundary: exactly at the old 500-item / 200-unbound limits, and past them.
  func testOldItemLimitsBoundaryAndPastThemGoToOverflow() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    let first500 = fill(500, "owner")
    XCTAssertEqual(try items().count, 500, "exactly at the old per-owner limit")
    XCTAssertNotNil(queueFileData())
    XCTAssertEqual(segmentNames(), [], "500 items still fit the main file")
    let mainBefore = try XCTUnwrap(queueFileData())

    guard case .enqueued(let item501) = put("owner 500 1.00 SAR") else {
      return XCTFail("the 501st stamped capture must be SAVED now (it was refused before)")
    }
    XCTAssertEqual(item501.ownerUid, ownerA)
    XCTAssertEqual(segmentNames(), ["seg-0000000000000001.bin"], "it went to an overflow segment")
    XCTAssertEqual(queueFileData(), mainBefore, "the main file was not rewritten")
    XCTAssertEqual(try peekTexts(), first500 + ["owner 500 1.00 SAR"])
    let overflowBlob = try Data(contentsOf: segmentURL(1))
    XCTAssertFalse(String(decoding: overflowBlob, as: UTF8.self).contains("owner 500"),
                   "an overflow segment is encrypted at rest")

    // Unbound: 200 (old limit) then 201+.
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    fill(201, "unbound")
    let unbound = try items().filter { $0.ownerState == "unbound" }
    XCTAssertEqual(unbound.count, 201, "the 201st unbound capture is saved too")
    XCTAssertEqual(try items().count, 702, "nothing was evicted")
  }

  // Boundary: exactly at the old byte limits (2 MB owner, 512 KB unbound, 8 MB
  // device) and past them.
  func testOldByteLimitsNoLongerRefuse() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    for i in 0..<6 { XCTAssertNotNil(enqueuedItem(put(big("u\(i)", 100_000))), "unbound \(i)") }
    XCTAssertEqual(try items().count, 6, "past the old 512 KB unbound limit")

    let owners = [ownerA, ownerB,
                  "33333333-3333-4333-8333-333333333333",
                  "44444444-4444-4444-8444-444444444444",
                  "55555555-5555-4555-8555-555555555555"]
    for (n, uid) in owners.enumerated() {
      try publish(uid)
      for i in 0..<6 {                                       // ~2.4 MB per owner
        XCTAssertNotNil(enqueuedItem(put(big("d\(n)-\(i)", 400_000))), "owner \(n) item \(i)")
      }
    }
    let all = try items()
    XCTAssertEqual(all.count, 36, "~12.6 MB total: past the old 8 MB device limit")
    XCTAssertGreaterThan(segmentNames().count, 2, "segments stay within 2 MB each")
    for name in segmentNames() {
      let size = try XCTUnwrap(
        try FileManager.default.attributesOfItem(atPath: overflowDir.appendingPathComponent(name).path)[.size] as? Int)
      XCTAssertLessThanOrEqual(size, SharedCaptureStore.segmentMaxBytes + 1024)
    }
    try publish(owners[0])
    XCTAssertEqual(try peekTexts().count, 6, "owner 0 sees exactly its own six items")
  }

  // The one ceiling left: a single item larger than a whole segment. Refused
  // visibly; nothing else changes.
  func testSingleOversizedItemIsRefusedWithoutTouchingTheQueue() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("small 1.00 SAR")
    let before = try XCTUnwrap(queueFileData())
    guard case .failed(_, let kind) = put(big("huge", SharedCaptureStore.maxItemBytes)) else {
      return XCTFail("an item larger than a segment must be refused")
    }
    XCTAssertEqual(kind, .quotaFull)
    XCTAssertEqual(queueFileData(), before)
  }

  private func enqueuedItem(_ result: SharedCaptureStore.EnqueueResult) -> SharedCaptureStore.Payload? {
    if case .enqueued(let item) = result { return item }
    return nil
  }

  // Drain order is the capture order across main + overflow, also after acks
  // empty the main file and new captures arrive.
  func testDrainOrderIsPreservedAcrossMainAndOverflow() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    var expected = fill(1001, "order")
    XCTAssertEqual(segmentNames().count, 2, "main 500 + seg1 500 + seg2 1")
    XCTAssertEqual(try peekTexts(), expected)

    // Ack ten from the main file, one from the middle of seg1: per-item lease.
    let ids = try peekIDs()
    for id in ids[0..<10] + [ids[700]] {
      XCTAssertTrue(SharedCaptureStore.remove(payloadID: id))
    }
    expected.remove(at: 700)
    expected.removeFirst(10)
    expected += fill(3, "later")
    XCTAssertEqual(try peekTexts(), expected, "new captures drain after every older one")

    // Ack everything that is still in the main file: it is removed, and a new
    // capture still lands AFTER the overflow items, never before them.
    for id in try peekIDs().prefix(490) {
      XCTAssertTrue(SharedCaptureStore.remove(payloadID: id))
    }
    XCTAssertNil(queueFileData(), "the emptied main file is removed")
    expected.removeFirst(490)
    expected += fill(1, "after-main-emptied")
    XCTAssertNil(queueFileData(), "the new item went to the tail segment")
    XCTAssertEqual(try peekTexts(), expected)
    XCTAssertTrue(SharedCaptureStore.hasPendingMessages())

    // consume (destructive drain) returns the same order and empties the queue.
    let consumed = try XCTUnwrap(try SharedCaptureStore.consumePendingPayloadsJSON())
    let texts = (try JSONSerialization.jsonObject(with: Data(consumed.utf8)) as? [[String: Any]])?
      .compactMap { $0["text"] as? String }
    XCTAssertEqual(texts, expected)
    XCTAssertEqual(try items().count, 0)
    XCTAssertEqual(segmentNames(), [], "emptied overflow segments are deleted")
  }

  // Duplicate payload ids are detected across main AND overflow.
  func testDuplicateIdIsDetectedInMainAndOverflow() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    fill(501, "dup")
    let ids = try peekIDs()
    let inMain = ids[3]
    let inOverflow = ids[500]
    for id in [inMain, inOverflow] {
      let result = SharedCaptureStore.enqueue(
        text: "different text 9.99", sender: "ACME", payloadID: id)
      guard case .duplicate(let existing) = result else {
        return XCTFail("a re-sent payload id must be a duplicate wherever it is stored")
      }
      XCTAssertEqual(existing.id, id)
    }
    XCTAssertEqual(try items().count, 501, "a duplicate is never stored twice")
  }

  // A corrupt overflow segment is quarantined (kept byte-for-byte, counted),
  // every other segment stays readable and captures keep working.
  func testCorruptOverflowSegmentIsQuarantinedOthersStayReadable() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    let texts = fill(1001, "q")
    var corrupt = try Data(contentsOf: segmentURL(1))
    corrupt[corrupt.count / 2] ^= 0xFF                      // flip one ciphertext byte
    try corrupt.write(to: segmentURL(1))

    // A read-only stats call skips and counts it, but moves nothing.
    let stats = try SharedCaptureStore.queueStats()
    XCTAssertEqual(stats.quarantinedSegments, 1, "the user-visible count")
    XCTAssertEqual(stats.stamped, 501)
    XCTAssertTrue(segmentNames().contains("seg-0000000000000001.bin"), "stats never move files")

    // A writer quarantines it; the rest is intact and in order.
    XCTAssertEqual(try peekTexts(), Array(texts[0..<500]) + [texts[1000]])
    XCTAssertFalse(segmentNames().contains("seg-0000000000000001.bin"))
    XCTAssertEqual(quarantineNames().count, 1)
    let kept = try Data(contentsOf: quarantineDir.appendingPathComponent(quarantineNames()[0]))
    XCTAssertEqual(kept, corrupt, "quarantine keeps the bytes; nothing is deleted")
    XCTAssertEqual(try SharedCaptureStore.queueStats().quarantinedSegments, 1)

    guard case .enqueued = put("after quarantine 1.00 SAR") else {
      return XCTFail("captures keep working next to a quarantined segment")
    }
    XCTAssertEqual(try peekTexts().last, "after quarantine 1.00 SAR")
    XCTAssertFalse(segmentNames().contains("seg-0000000000000001.bin"),
                   "a quarantined segment's number is never reused for new data")
  }

  // A failed write reports failure, saves nothing and loses nothing: injected
  // failure, out of space, and a real read-only directory.
  func testFailedWriteIsReportedAndNothingIsLost() throws {
    resetCapSeams()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overflowDir.path)
      resetCapSeams()
    }
    try publish(ownerA)
    let texts = fill(500, "w")
    let mainBefore = try XCTUnwrap(queueFileData())

    SharedCaptureStore.durableWriteFault = { $0 == "seg-0000000000000001.bin" ? .fail : .none }
    guard case .failed(_, let failKind) = put("w new 1.00 SAR") else {
      return XCTFail("a failed overflow write must be reported")
    }
    XCTAssertEqual(failKind, .storageUnavailable)
    SharedCaptureStore.durableWriteFault = { _ in .outOfSpace }
    guard case .failed(_, let fullKind) = put("w new 1.00 SAR") else {
      return XCTFail("a full disk must be reported")
    }
    XCTAssertEqual(fullKind, .quotaFull, "out of space selects the 'no room' kind")
    XCTAssertEqual(fullKind.userMessage, SharedCaptureStore.FailureKind.storageUnavailable.userMessage,
                   "approved copy only")
    SharedCaptureStore.durableWriteFault = nil
    XCTAssertEqual(queueFileData(), mainBefore)
    XCTAssertEqual(try peekTexts(), texts, "nothing lost, nothing half-saved")

    // A real file-system refusal: the overflow directory is read-only.
    try FileManager.default.createDirectory(at: overflowDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: overflowDir.path)
    guard case .failed(_, let roKind) = put("w new 1.00 SAR") else {
      return XCTFail("a read-only directory must make the capture fail visibly")
    }
    XCTAssertEqual(roKind, .storageUnavailable)
    XCTAssertEqual(segmentNames(), [], "no temp or partial file is left behind")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overflowDir.path)
    XCTAssertEqual(try peekTexts(), texts)
    guard case .enqueued = put("w new 1.00 SAR") else { return XCTFail("works again") }

    // The main file's write fails the same way, and its old bytes stay.
    SharedCaptureStore.purgeUserOwnedState()
    try publish(ownerA)
    put("m1 1.00 SAR")
    put("m1b 1.00 SAR")
    let two = try XCTUnwrap(queueFileData())
    SharedCaptureStore.durableWriteFault = { $0 == "pending_bank_messages_v3.bin" ? .fail : .none }
    guard case .failed = put("m2 1.00 SAR") else { return XCTFail("main write failure") }
    XCTAssertFalse(SharedCaptureStore.remove(payloadID: try XCTUnwrap(try peekIDs().first)),
                   "an ack whose write fails is not reported as done")
    SharedCaptureStore.durableWriteFault = nil
    XCTAssertEqual(queueFileData(), two)
    XCTAssertEqual(try peekTexts(), ["m1 1.00 SAR", "m1b 1.00 SAR"])
  }

  // The App Intent turns a failed durable write into a thrown error with the
  // approved copy (it never reports "saved").
  @available(iOS 16.0, *)
  func testIntentReportsFailedDurableWrite() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    SharedCaptureStore.durableWriteFault = { _ in .outOfSpace }
    let request = BankSMSCaptureRequest(
      smsText: "ACME: purchase 3.00 SAR", senderName: "ACME", senderID: nil,
      receivedAt: Date(), receivedAtInferred: false, localeIdentifier: nil)
    XCTAssertThrowsError(try BankSMSCaptureService().capture(request)) { error in
      guard case ProcessBankSMSError.captureFailed(let kind)? = error as? ProcessBankSMSError else {
        return XCTFail("unexpected \(error)")
      }
      XCTAssertEqual(kind, .quotaFull)
    }
    SharedCaptureStore.durableWriteFault = nil
    XCTAssertEqual(try items().count, 0)
  }

  // An interrupted write leaves only a temp file: never read, removed by the
  // next writer, and every existing item stays intact. Main file and overflow.
  func testInterruptedWriteLeavesTempFileThatIsIgnoredAndCleaned() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    var texts = fill(3, "t")
    let mainBefore = try XCTUnwrap(queueFileData())
    func mainTemps() -> [String] {
      ((try? FileManager.default.contentsOfDirectory(atPath: container.path)) ?? [])
        .filter { $0.hasPrefix(".pending_bank_messages_v3.bin.tmp-") }
    }

    SharedCaptureStore.durableWriteFault = { _ in .tornTemp }
    guard case .failed = put("t torn-main 1.00 SAR") else { return XCTFail("torn main write") }
    SharedCaptureStore.durableWriteFault = nil
    XCTAssertEqual(mainTemps().count, 1, "a half-written temp file is on disk")
    XCTAssertEqual(queueFileData(), mainBefore, "the main file never saw the torn write")
    XCTAssertEqual(try peekTexts(), texts, "the torn temp is ignored; nothing lost or added")
    XCTAssertEqual(mainTemps(), [], "the next writer removed it")

    texts += fill(497, "t", from: 3)
    SharedCaptureStore.durableWriteFault = { _ in .tornTemp }
    guard case .failed = put("t torn-overflow 1.00 SAR") else { return XCTFail("torn overflow write") }
    SharedCaptureStore.durableWriteFault = nil
    XCTAssertEqual(segmentNames().filter { $0.contains(".tmp-") }.count, 1)
    XCTAssertFalse(segmentNames().contains("seg-0000000000000001.bin"),
                   "no half-written segment exists under a real name")
    XCTAssertEqual(try peekTexts(), texts)
    XCTAssertEqual(segmentNames(), [], "the torn overflow temp was removed")
    guard case .enqueued = put("t after 1.00 SAR") else { return XCTFail("captures work again") }
    XCTAssertEqual(try peekTexts(), texts + ["t after 1.00 SAR"])
  }

  // Upgrade: a main file written by the previous build (same AES-GCM format,
  // more than 500 items, several owners) is read unchanged and is never
  // rewritten just to append.
  func testUpgradeFromPreviousFormatReadsTheOldBlobUnchanged() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    SharedCaptureStore.queueKeyReadOverride = { (status: errSecSuccess, data: keyData) }
    var legacy: [[String: Any]] = []
    for i in 0..<700 {
      let owner = i % 7 == 0 ? ownerB : ownerA
      legacy.append([
        "id": "old-\(i)", "text": "old \(i) 2.00 SAR", "sender": "ACME", "status": "pending",
        "createdAt": "2026-11-01T10:00:00Z", "receivedAt": "2026-11-01T10:00:00Z",
        "ownerState": "stamped", "ownerUid": owner, "ownerGeneration": a.generation,
      ])
    }
    let json = try JSONSerialization.data(withJSONObject: legacy)
    let sealed = try XCTUnwrap(try AES.GCM.seal(json, using: SymmetricKey(data: keyData)).combined)
    try sealed.write(to: queueFileURL)

    let snapshot = try items()
    XCTAssertEqual(snapshot.map { $0.id }, (0..<700).map { "old-\($0)" }, "read in order")
    let mine = (0..<700).filter { $0 % 7 != 0 }.map { "old \($0) 2.00 SAR" }
    XCTAssertEqual(try peekTexts(), mine, "owner A's items, B's stay invisible")
    XCTAssertEqual(queueFileData(), sealed, "reading never rewrites the old blob")

    guard case .enqueued = put("new after upgrade 1.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(queueFileData(), sealed, "a full old main file is not rewritten to append")
    XCTAssertEqual(segmentNames(), ["seg-0000000000000001.bin"])
    XCTAssertEqual(try peekTexts(), mine + ["new after upgrade 1.00 SAR"])

    XCTAssertTrue(SharedCaptureStore.remove(payloadID: "old-1"))
    XCTAssertNotEqual(queueFileData(), sealed, "an ack rewrites only the segment it touches")
    XCTAssertEqual(try items().count, 700)
  }

  // The one-time v2 migration appends to whatever is already queued: an
  // overflow segment that exists while the main file does not is never dropped.
  func testV2MigrationNeverDropsExistingOverflowItems() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    fill(501, "keep")
    for id in try peekIDs().prefix(500) { XCTAssertTrue(SharedCaptureStore.remove(payloadID: id)) }
    XCTAssertNil(queueFileData())
    appGroupDefaults.set(
      Data("[{\"id\":\"v2-1\",\"text\":\"legacy 1.00\",\"status\":\"pending\"}]".utf8),
      forKey: queueDefaultsKey)
    appGroupDefaults.removeObject(forKey: "pending_bank_messages_v3_migrated")

    let all = try items()
    XCTAssertEqual(all.map { $0.text }, ["keep 500 1.00 SAR", "legacy 1.00"])
    XCTAssertEqual(all.last?.origin, "legacy_v2")
    XCTAssertEqual(try peekTexts(), ["keep 500 1.00 SAR"])
  }

  // Sign-out / account-switch purge deletes overflow and quarantine files; a
  // purge that cannot delete them reports failure and keeps the key.
  func testPurgeDeletesOverflowAndQuarantineAndReportsLeftovers() throws {
    resetCapSeams()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overflowDir.path)
      resetCapSeams()
    }
    try publish(ownerA)
    fill(1001, "p")
    var corrupt = try Data(contentsOf: segmentURL(2))
    corrupt[corrupt.count - 1] ^= 0xFF
    try corrupt.write(to: segmentURL(2))
    _ = try items()                                          // quarantines seg2
    XCTAssertEqual(quarantineNames().count, 1)

    // A purge that cannot remove an overflow file fails and keeps the key.
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: overflowDir.path)
    XCTAssertFalse(SharedCaptureStore.purgeUserOwnedState(), "leftover overflow => purge reports failure")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: overflowDir.path)
    XCTAssertEqual(try items().count, 500, "seg1 is still decryptable: the key was not removed")

    XCTAssertTrue(SharedCaptureStore.purgeUserOwnedState())
    XCTAssertFalse(FileManager.default.fileExists(atPath: overflowDir.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: quarantineDir.path))
    XCTAssertNil(queueFileData())
    XCTAssertEqual(try items().count, 0)
  }

  // Owner isolation and Remove-data extend to overflow items.
  func testOverflowItemsKeepOwnerIsolationAndRemoveDataSweepsThem() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    let aTexts = fill(501, "A")                              // one A item in seg1
    try publish(ownerB)
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(), "B never sees A's overflow item")
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages())
    let bTexts = fill(2, "B")                                // seg1: A, B, B
    XCTAssertEqual(try peekTexts(), bTexts)
    try publish(ownerA)
    XCTAssertEqual(try peekTexts(), aTexts, "A never sees B's overflow items")

    // An undecryptable segment in quarantine cannot be shown NOT to hold A's data.
    try Data(repeating: 0xAB, count: 64).write(to: segmentURL(9))
    _ = try items()
    XCTAssertEqual(quarantineNames().count, 1)

    // Remove data for A: A's main AND overflow items go; B's stay.
    try publish(ownerB)
    Thread.sleep(forTimeInterval: 1.1)    // created_at has 1 s resolution (sweep by barrier time)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertEqual(try SharedCaptureStore.finishRemoval(uid: ownerA), 501)
    XCTAssertEqual(try items().map { $0.text }, bTexts)
    XCTAssertEqual(quarantineNames(), [], "quarantined segments are swept by Remove data")
    XCTAssertEqual(try peekTexts(), bTexts)
  }

  // The no-new-key rule itself: even when the key read flips to "not found"
  // between the load and the write, no key is minted while a sealed file exists.
  func testNoKeyIsMintedWhileASealedQueueFileExists() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    let keyData = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
    SharedCaptureStore.queueKeyReadOverride = { (status: errSecSuccess, data: keyData) }
    put("sealed 1.00 SAR")
    let sealed = try XCTUnwrap(queueFileData())
    var reads = 0
    SharedCaptureStore.queueKeyReadOverride = {
      reads += 1
      return reads == 1 ? (status: errSecSuccess, data: keyData) : (status: errSecItemNotFound, data: nil)
    }
    guard case .failed(_, let kind) = put("new 2.00 SAR") else {
      return XCTFail("no key may be minted over existing sealed data")
    }
    XCTAssertEqual(kind, .storageUnavailable)
    XCTAssertGreaterThanOrEqual(reads, 2, "the write path did look for the key")
    XCTAssertEqual(queueFileData(), sealed, "the sealed file is untouched")
    SharedCaptureStore.queueKeyReadOverride = { (status: errSecSuccess, data: keyData) }
    XCTAssertEqual(try peekTexts(), ["sealed 1.00 SAR"])
  }

  // The Keychain key is gone while sealed overflow data survives (e.g. a
  // restored backup: the key is ThisDeviceOnly). Nothing is overwritten,
  // nothing deleted, no new key is minted, the failure is visible.
  func testKeyLostWhileOverflowSurvivesFailsClosedWithoutMintingAKey() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    fill(501, "k")
    for id in try peekIDs().prefix(500) { XCTAssertTrue(SharedCaptureStore.remove(payloadID: id)) }
    XCTAssertNil(queueFileData(), "only the overflow segment is left")
    let segment = try Data(contentsOf: segmentURL(1))

    SharedCaptureStore.queueKeyReadOverride = { (status: errSecItemNotFound, data: nil) }
    guard case .failed(_, let kind) = put("k new 1.00 SAR") else {
      return XCTFail("a capture must fail while the key for existing data is missing")
    }
    XCTAssertEqual(kind, .storageUnavailable)
    XCTAssertThrowsError(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertThrowsError(try SharedCaptureStore.queueStats())
    XCTAssertFalse(SharedCaptureStore.hasPendingMessages())
    XCTAssertEqual(try Data(contentsOf: segmentURL(1)), segment, "the sealed segment is untouched")
    XCTAssertNil(queueFileData(), "no main file was written under a new key")
    XCTAssertEqual(segmentNames(), ["seg-0000000000000001.bin"])

    SharedCaptureStore.queueKeyReadOverride = nil
    XCTAssertEqual(try peekTexts(), ["k 500 1.00 SAR"],
                   "the real key was never replaced: the data still decrypts")
  }

  // §4.5 expiry: only UNBOUND items expire by age; stamped items never do.
  func testUnboundExpiresAfter30DaysStampedDoesNot() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("stamped keeps 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("unbound expires 2.00 SAR")
    SharedCaptureStore.clockOverride = { Date().addingTimeInterval(31 * 86_400) }
    _ = try SharedCaptureStore.peekPendingPayloadsJSON()
    let texts = try items().map { $0.text }
    XCTAssertEqual(texts, ["stamped keeps 1.00 SAR"])
  }

  // §4.7 migration: every v2 item becomes unbound with NO hint; nothing is
  // dropped (quotas do not apply); only Dart's receipt/tx verdict removes items.
  func testV2MigrationQuarantinesEverythingWithoutHint() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = (0..<250).map {
      "{\"id\":\"l\($0)\",\"text\":\"legacy \($0) 9.00\",\"status\":\"pendingSend\",\"owner\":\"\(ownerA)\"}"
    }.joined(separator: ",")
    appGroupDefaults.set(Data("[\(legacy)]".utf8), forKey: queueDefaultsKey)
    let a = try publish(ownerA)

    let queue = try items()
    XCTAssertEqual(queue.count, 250, "no legacy item is dropped")
    for item in queue {
      XCTAssertEqual(item.ownerState, "unbound")
      XCTAssertNil(item.ownerUid)
      XCTAssertNil(item.ownerHint, "no hint is derived from the legacy owner marker")
      XCTAssertEqual(item.origin, "legacy_v2")
    }
    XCTAssertNil(try SharedCaptureStore.peekPendingPayloadsJSON(), "never imported automatically")
    XCTAssertEqual(try SharedCaptureStore.unboundSummary(forUid: ownerA).count, 0,
                   "no hint, so no recovery prompt for anyone")
    XCTAssertNotNil(appGroupDefaults.data(forKey: queueDefaultsKey),
                    "the v2 blob is kept for the 7-day rollback grace")
    XCTAssertGreaterThan(a.generation, 0)

    // Dart's adopted-replica verdict: one consumed (removed), one suspected (annotated).
    let removed = try SharedCaptureStore.resolveLegacyItems(
      consumedIds: ["l0"], suspectedIds: ["l1", "no-such-id"])
    XCTAssertEqual(removed, 1)
    let after = try items()
    XCTAssertEqual(after.count, 249)
    XCTAssertFalse(after.contains { $0.id == "l0" })
    XCTAssertEqual(after.first { $0.id == "l1" }?.reviewState, "suspected_already_imported")
    XCTAssertNil(after.first { $0.id == "l2" }?.reviewState)
    // The migration ran once: a removed item does not come back.
    XCTAssertFalse(try items().contains { $0.id == "l0" })
  }

  // A6 (CAP-7): the read-only listing returns only unbound legacy_v2 items, with
  // id, raw text and the receive time, and changes nothing.
  func testPeekLegacyCaptureItemsListsOnlyUnboundLegacyAndChangesNothing() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = "[{\"id\":\"l0\",\"text\":\"legacy 9.00\",\"status\":\"pendingSend\",\"receivedAt\":\"2026-01-02T03:04:05.000Z\"},"
      + "{\"id\":\"l1\",\"text\":\"legacy 8.00\",\"status\":\"pendingSend\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: queueDefaultsKey)
    try publish(ownerA)
    // A stamped, non-legacy item is never listed.
    _ = SharedCaptureStore.enqueue(text: "stamped 7.00", sender: "ACME")

    let before = try items()
    let peeked = try SharedCaptureStore.peekLegacyCaptureItems()
    XCTAssertEqual(Set(peeked.map { $0.id }), ["l0", "l1"])
    XCTAssertEqual(peeked.first { $0.id == "l0" }?.text, "legacy 9.00")
    XCTAssertEqual(peeked.first { $0.id == "l0" }?.receivedAt, "2026-01-02T03:04:05.000Z")
    XCTAssertEqual(try items().count, before.count, "listing mutates nothing")
    XCTAssertEqual(try items().map { $0.reviewState }, before.map { $0.reviewState })
  }

  // CAP-7: the App Intent banner wiring and the generic fallback text, pinned in the
  // source (the intent target is not importable from RunnerTests).
  func testNotifyV2OwnerRuleAndGenericTextAreWiredInTheIntent() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift")
    )
    XCTAssertTrue(source.contains("response.pushAttempted ?? response.pushSent"))
    XCTAssertTrue(source.contains("json[\"push_attempted\"] as? Bool"))
    XCTAssertTrue(source.contains("\"New transaction captured\""))
    let banner = try XCTUnwrap(source.range(of: "private func scheduleGenericCaptureNotification"))
    let body = String(source[banner.lowerBound...].prefix(400))
    XCTAssertTrue(body.contains("detailedCaptureNotification(aiDetail: aiDetail)"))
    XCTAssertTrue(source.contains("aiDetail: response.aiDetail"))
    for forbidden in ["sender", "response.notification"] {
      XCTAssertFalse(body.contains(forbidden), "banner must not touch \(forbidden)")
    }
    XCTAssertTrue(source.contains("await Self.removeDeliveredPushes(payloadID: payloadID)"))
  }

  func testCaptureDetailsPreferenceDefaultsOffAndMirrorsExplicitHide() {
    SharedCaptureStore.setHideCaptureDetails(false)
    defer { SharedCaptureStore.setHideCaptureDetails(false) }
    XCTAssertFalse(SharedCaptureStore.hidesCaptureDetails)
    SharedCaptureStore.setHideCaptureDetails(true)
    XCTAssertTrue(SharedCaptureStore.hidesCaptureDetails)
  }

  func testNativeCaptureDetailsAreIndependentOfRolloutAndCarryCategory() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift"))
    let start = try XCTUnwrap(source.range(of: "if let response = attempt.response"))
    let end = try XCTUnwrap(source.range(of: "// Backend unreachable", range: start.upperBound..<source.endIndex))
    let success = String(source[start.lowerBound..<end.lowerBound])
    XCTAssertFalse(success.contains("if config.captureNotifyV2"))
    XCTAssertFalse(success.contains("else if !response.pushSent"))
    XCTAssertTrue(success.contains("aiDetail: response.aiDetail"))
    XCTAssertTrue(source.contains("\"localNotification\": true"))
    XCTAssertTrue(source.contains("category: text(\"category\")"))
    XCTAssertTrue(source.contains("!SharedCaptureStore.hidesCaptureDetails"))
  }

  // A1/A2 unbound recovery: hint, claim CAS preconditions, no mutation on failure.
  func testUnboundHintAndClaimCAS() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)       // signed out
    put("while signed out 1.00 SAR", sender: "BANK1")
    put("while signed out 2.00 SAR", sender: "BANK2")
    let before = try XCTUnwrap(queueFileData())

    // Another uid authenticates: it sees nothing and cannot claim (A2).
    let b = try publish(ownerB)
    XCTAssertEqual(try SharedCaptureStore.unboundSummary(forUid: ownerB).count, 0)
    let stolen = try SharedCaptureStore.claimUnbound(
      uid: ownerB, generation: b.generation, replicaOwnerUid: ownerB, sessionUid: ownerB,
      ids: try SharedCaptureStore.unboundSummary(forUid: ownerA).ids)
    XCTAssertEqual(stolen, .stale)
    XCTAssertEqual(queueFileData(), before, "a failed claim mutates nothing")

    // The hinted uid returns.
    let a = try publish(ownerA)
    let summary = try SharedCaptureStore.unboundSummary(forUid: ownerA)
    XCTAssertEqual(summary.count, 2)
    XCTAssertEqual(summary.senders, ["BANK1", "BANK2"])

    let uid = ownerA
    func claim(gen: Int, replica: String? = nil, session: String? = nil,
               ids: [String]) throws -> SharedCaptureStore.ClaimOutcome {
      try SharedCaptureStore.claimUnbound(
        uid: uid, generation: gen, replicaOwnerUid: replica ?? uid, sessionUid: session ?? uid, ids: ids)
    }
    XCTAssertEqual(try claim(gen: a.generation + 1, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, replica: ownerB, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, session: ownerB, ids: summary.ids), .ownerMismatch)
    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids + ["unknown"]), .stale)
    XCTAssertEqual(try items().filter { $0.ownerState == "unbound" }.count, 2,
                   "every failed claim left the items unbound")

    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids), .applied(2))
    let bound = try items()
    for item in bound {
      XCTAssertEqual(item.ownerState, "stamped")
      XCTAssertEqual(item.ownerUid, ownerA)
      XCTAssertEqual(item.localOnly, true, "bound items never upload and never use AI")
      XCTAssertNil(item.ownerHint)
      XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                     .localOnly)
    }
    let json = try XCTUnwrap(try SharedCaptureStore.peekPendingPayloadsJSON())
    XCTAssertTrue(json.contains("\"localOnly\":true"))
    XCTAssertEqual(try claim(gen: a.generation, ids: summary.ids), .stale, "claims are one-shot")
  }

  func testDiscardUsesTheSameCAS() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("discard me 1.00 SAR")
    let a = try publish(ownerA)
    let ids = try SharedCaptureStore.unboundSummary(forUid: ownerA).ids
    XCTAssertEqual(try SharedCaptureStore.discardUnbound(
      uid: ownerA, generation: a.generation, replicaOwnerUid: ownerB, sessionUid: ownerA, ids: ids),
      .ownerMismatch)
    XCTAssertEqual(try items().count, 1)
    XCTAssertEqual(try SharedCaptureStore.discardUnbound(
      uid: ownerA, generation: a.generation, replicaOwnerUid: ownerA, sessionUid: ownerA, ids: ids),
      .applied(1))
    XCTAssertEqual(try items().count, 0)
  }

  // Two claimers race: the flock serializes them; exactly one wins.
  func testClaimRaceTwoClaimersExactlyOneWins() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("race 1.00 SAR")
    put("race 2.00 SAR")
    let a = try publish(ownerA)
    let ids = try SharedCaptureStore.unboundSummary(forUid: ownerA).ids
    let lock = NSLock()
    var outcomes: [SharedCaptureStore.ClaimOutcome] = []
    DispatchQueue.concurrentPerform(iterations: 2) { _ in
      let outcome = try? SharedCaptureStore.claimUnbound(
        uid: ownerA, generation: a.generation, replicaOwnerUid: ownerA, sessionUid: ownerA, ids: ids)
      lock.lock(); outcomes.append(outcome ?? .stale); lock.unlock()
    }
    XCTAssertEqual(outcomes.filter { $0 == .applied(2) }.count, 1)
    XCTAssertEqual(outcomes.filter { $0 == .stale }.count, 1)
  }

  // §4.4 Remove-data barrier (A3): the intent fails visibly; the sweep removes
  // everything owned by, hinted to, or created after the barrier for A.
  func testRemovalBarrierBlocksIntentAndSweepsEverythingOfA() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    put("A stamped 1.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    put("A hinted 2.00 SAR")                                         // hint == uidHash(A)
    let b = try publish(ownerB)
    put("B stamped 3.00 SAR")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 1)
    Thread.sleep(forTimeInterval: 1.1)    // created_at has 1 s resolution

    let barrier = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertEqual(barrier.uidHash, a.uidHash)
    XCTAssertEqual(try SharedCaptureStore.beginRemoval(uid: ownerA), barrier, "resumable / idempotent")
    XCTAssertThrowsError(try SharedCaptureStore.beginRemoval(uid: ownerB))
    XCTAssertEqual(try SharedCaptureStore.removalBarrier(), barrier)

    guard case .failed(_, let kind) = put("during removal 4.00 SAR") else {
      return XCTFail("the intent must fail visibly while the barrier is up")
    }
    XCTAssertEqual(kind, .removalInProgress)
    XCTAssertThrowsError(try publish(ownerA))
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: "anything"), .waiting)
    XCTAssertEqual(try items().count, 3, "the refused capture was not persisted")

    XCTAssertEqual(try SharedCaptureStore.finishRemoval(uid: ownerA), 2)
    let left = try items()
    XCTAssertEqual(left.map { $0.text }, ["B stamped 3.00 SAR"], "nothing of A remains")
    XCTAssertNil(try SharedCaptureStore.removalBarrier(), "the barrier is cleared last")
    XCTAssertEqual(try SharedCaptureStore.finishRemoval(uid: ownerA), 0, "idempotent after completion")
    // B stays admitted and keeps working.
    guard case .enqueued = put("after 5.00 SAR") else { return XCTFail("B must capture again") }
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), b)
  }

  // Removing A also forgets A as the last admitted uid: later unbound captures
  // carry no hint, so nothing can ever be recovered "for A".
  func testRemovalClearsLastAdmittedHintWhenItIsA() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)      // sign-out keeps the hint
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    try SharedCaptureStore.finishRemoval(uid: ownerA)
    put("after removal 5.00 SAR")
    let item = try XCTUnwrap(try items().first)
    XCTAssertEqual(item.ownerState, "unbound")
    XCTAssertNil(item.ownerHint)
  }

  // Quota refusal reaches the Share Extension / Shortcut with approved copy only.
  func testNewRefusalKindsReuseApprovedCopyOnly() {
    for kind in [SharedCaptureStore.FailureKind.quotaFull, .removalInProgress, .ownerChanged] {
      XCTAssertEqual(kind.userMessage,
                     SharedCaptureStore.FailureKind.storageUnavailable.userMessage)
    }
    XCTAssertEqual(SharedCaptureStore.FailureKind.quotaFull.bridgeCode, "quota_exceeded")
    XCTAssertEqual(SharedCaptureStore.FailureKind.removalInProgress.bridgeCode, "removal_in_progress")
    XCTAssertEqual(SharedCaptureStore.FailureKind.ownerChanged.bridgeCode, "owner_changed")
  }

  // A re-enqueue goes back under its original owner or not at all.
  func testReEnqueueRequiresOriginalOwner() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerB)
    guard case .failed(_, let kind) = SharedCaptureStore.enqueue(
      text: "back 1.00 SAR", sender: "ACME", requireOwnerUid: ownerA) else {
      return XCTFail("re-enqueue under another owner must be refused")
    }
    XCTAssertEqual(kind, .ownerChanged)
    XCTAssertEqual(try items().count, 0)
  }


  // ── A-12-min: Cloud OFF = zero egress, local owner publication ────────────

  private func mirrorKeyRemoved() {
    appGroupDefaults.removeObject(forKey: "capture_consent_mirror_v1")
  }

  // R3: Cloud OFF at capture time -> the item is local-only for good and a
  // replay-able pendingSend becomes sent, so no drain ever replays it.
  func testCloudOffStampsLocalOnlyAndSentEvenIfCloudIsLaterTurnedOn() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA, cloud: false)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "off 1.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(item.status, "sent", "a localOnly item is never left pendingSend")
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "consent is judged at capture time: ON later does not make it uploadable")
  }

  func testCloudOnStampsUploadableAndKeepsPendingSend() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: true, ai: true)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "on 1.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertNil(item.localOnly)
    XCTAssertEqual(item.status, "pendingSend")
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
  }

  // R2/R3: a missing mirror never uploads: new captures are stamped local-only,
  // and an item stamped earlier waits (there is no `.allowed(nil)` any more).
  func testMissingMirrorNeverUploads() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    guard case .enqueued(let early) = put("early 1.00 SAR") else { return XCTFail("enqueue") }
    mirrorKeyRemoved()
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(early.id)), .waiting)
    guard case .enqueued(let late) = SharedCaptureStore.enqueue(
      text: "late 2.00 SAR", sender: "ACME", status: .pendingSend) else { return XCTFail("enqueue") }
    XCTAssertEqual(late.localOnly, true)
    XCTAssertEqual(late.status, "sent")
  }

  // R4: the mirror and the owner are one publish; the owner is never visible
  // without its mirror, and republishing the owner keeps the generation.
  func testPublishWritesMirrorWithOwnerAndKeepsGeneration() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: false)
    let again = try publish(ownerA, cloud: true, ai: true, version: 7)
    XCTAssertEqual(again, a)
    guard case .enqueued(let item) = put("mirror 3.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
  }

  // R4: compare-and-swap. A publish that read its epoch before a transition
  // clear is refused afterwards, so B's capture is never stamped as A's.
  func testLatePublishAfterTransitionClearIsRefused() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let epoch = try SharedCaptureStore.ownerEpoch()          // A's publish starts here
    try SharedCaptureStore.clearActiveOwner(clearHint: true)  // transition clear
    XCTAssertGreaterThan(try SharedCaptureStore.ownerEpoch(), epoch)
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: true, ai: false, version: 1),
      expectedEpoch: epoch)) { error in
      guard case SharedCaptureStore.QueueError.ownerChanged = error else {
        return XCTFail("expected ownerChanged, got \(error)")
      }
    }
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    guard case .enqueued(let item) = put("B capture 4.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(item.ownerState, "unbound")
    XCTAssertNil(item.ownerUid, "a late A publish must never own B's capture")
  }

  // R4: setConsentMirror is refused while a Remove-data barrier is in force.
  func testSetConsentMirrorRefusedUnderBarrier() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA)
    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: true, ai: true, version: 9))
  }

  // The claim path binds items local-only and forces pendingSend -> sent.
  func testClaimForcesSentAndLocalOnly() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    SharedCaptureStore.enqueue(text: "pending 1.00 SAR", sender: "ACME", status: .pendingSend)
    let a2 = try publish(ownerA)
    let hinted = try SharedCaptureStore.unboundSummary(forUid: ownerA)
    XCTAssertEqual(hinted.count, 1)
    _ = a
    XCTAssertEqual(
      try SharedCaptureStore.claimUnbound(
        uid: ownerA, generation: a2.generation, replicaOwnerUid: ownerA,
        sessionUid: ownerA, ids: hinted.ids),
      .applied(1))
    let claimed = try XCTUnwrap(try items().first)
    XCTAssertEqual(claimed.localOnly, true)
    XCTAssertEqual(claimed.status, "sent")
  }

  // ── captureQueueStats (content-free) ──────────────────────────────────────

  func testQueueStatsBucketsBytesAndQuotaState() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerB)
    put("B waits 1.00 SAR")
    try publish(ownerA, cloud: false)
    put("A local only 2.00 SAR")                  // stamped localOnly (Cloud OFF)
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: false, version: 2)
    put("A stamped 3.00 SAR")
    try SharedCaptureStore.clearActiveOwner(clearHint: true)
    put("unbound 4.00 SAR")

    let stats = try SharedCaptureStore.queueStats()
    XCTAssertEqual(stats.stamped, 0, "no active owner now: A's items wait")
    XCTAssertEqual(stats.waiting, 3)
    XCTAssertEqual(stats.unbound, 1)
    XCTAssertGreaterThan(stats.deviceBytes, 0)
    XCTAssertEqual(stats.unboundQuota, .ok)
    XCTAssertEqual(stats.deviceQuota, .ok)

    try publish(ownerA)
    let active = try SharedCaptureStore.queueStats()
    XCTAssertEqual(active.stamped, 1)
    XCTAssertEqual(active.localOnly, 1)
    XCTAssertEqual(active.waiting, 1)
    XCTAssertEqual(active.unbound, 1)
    XCTAssertEqual(active.stamped + active.localOnly + active.waiting + active.unbound,
                   try items().count, "every item is in exactly one bucket")
    XCTAssertGreaterThan(active.activeOwnerBytes, 0)
    XCTAssertLessThanOrEqual(active.activeOwnerBytes + active.unboundBytes, active.deviceBytes)
  }

  // Stats never write: an unmigrated v2 queue is counted, not migrated.
  func testQueueStatsNeverMigratesTheV2Queue() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let legacy = "[{\"id\":\"abc\",\"text\":\"legacy 10.00\",\"status\":\"pending\"}]"
    appGroupDefaults.set(Data(legacy.utf8), forKey: "pending_bank_messages_v2")
    let stats = try SharedCaptureStore.queueStats()
    XCTAssertTrue(stats.migrationPending)
    XCTAssertEqual(stats.unbound, 1)
    XCTAssertNil(queueFileData(), "no v3 file was written by a stats read")
    XCTAssertNil(appGroupDefaults.object(forKey: "pending_bank_messages_v3_migrated"),
                 "the migration flag was not set by a stats read")
  }

  // A localOnly item that is still `.pending` (not pendingSend) can never be
  // authorized for upload either, whatever the mirror says later.
  func testLocalOnlyPendingItemIsNeverAuthorized() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA, cloud: false)
    guard case .enqueued(let item) = SharedCaptureStore.enqueue(
      text: "pending 1.00 SAR", sender: "ACME", status: .pending) else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(item.status, "pending")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: true, ai: true, version: 3)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)
  }

  func testQueueStatsReadOnlyAndContentFree() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA)
    put("SECRET-TEXT 5.00 SAR", sender: "SECRET-SENDER")
    let before = try XCTUnwrap(queueFileData())
    let stats = try SharedCaptureStore.queueStats()
    XCTAssertEqual(queueFileData(), before, "stats never write the queue")
    let described = String(describing: stats)
    for fragment in ["SECRET", ownerA, "5.00"] {
      XCTAssertFalse(described.contains(fragment), "stats must be content-free")
    }
  }


  // ── APNs environment pairing ───────────────────────────────────────────────
  //
  // A real iPhone registered a SANDBOX token as `production` because the old
  // derivation was `#if DEBUG`, and DEBUG is not defined in this project's
  // Swift build conditions. These pin the replacement: the value comes from the
  // signed entitlement, and anything unresolved withholds the token.

  private func profileBlob(withEntitlements body: String) -> Data {
    // A provisioning profile is a plist wrapped in a CMS/DER envelope; the
    // parser slices the plist out of the surrounding bytes.
    let plist = """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"       "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict><key>Name</key><string>t</string>      <key>Entitlements</key><dict>\(body)</dict></dict></plist>
      """
    var data = Data([0x30, 0x82, 0x0A, 0xBC, 0x06, 0x09])
    data.append(plist.data(using: .isoLatin1)!)
    data.append(Data([0x00, 0x01, 0x02]))
    return data
  }

  func testApnsDevelopmentEntitlementMapsToSandbox() {
    XCTAssertEqual(ApnsEnvironment.map(entitlement: "development"), "sandbox")
  }

  func testApnsProductionEntitlementMapsToProduction() {
    XCTAssertEqual(ApnsEnvironment.map(entitlement: "production"), "production")
  }

  func testApnsMissingEntitlementIsUnresolved() {
    XCTAssertNil(ApnsEnvironment.map(entitlement: nil))
  }

  func testApnsUnexpectedEntitlementIsUnresolved() {
    // Including case variants: the entitlement vocabulary is exact.
    for value in ["", "staging", "sandbox", "Development", "PRODUCTION", "dev"] {
      XCTAssertNil(
        ApnsEnvironment.map(entitlement: value),
        "\(value) must not resolve to an APNs host")
    }
  }

  func testApnsEntitlementReadFromProvisioningProfile() {
    let dev = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>development</string>")
    XCTAssertEqual(ApnsEnvironment.entitlement(inProfile: dev), "development")
    XCTAssertEqual(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: dev)),
      "sandbox")

    let prod = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>production</string>")
    XCTAssertEqual(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: prod)),
      "production")
  }

  func testApnsProfileWithoutEntitlementIsUnresolved() {
    // Push capability absent from the profile: no token may be registered.
    let none = profileBlob(
      withEntitlements: "<key>application-identifier</key><string>X.y</string>")
    XCTAssertNil(ApnsEnvironment.entitlement(inProfile: none))
    XCTAssertNil(
      ApnsEnvironment.map(entitlement: ApnsEnvironment.entitlement(inProfile: none)))
  }

  func testApnsGarbageProfileIsUnresolved() {
    XCTAssertNil(ApnsEnvironment.entitlement(inProfile: Data([0x00, 0xFF, 0x10])))
  }

  func testApnsMissingProfileWithStoreReceiptIsProduction() {
    // App Store / TestFlight: Apple strips the profile and re-signs for the
    // production APNs host. The RECEIPT is the evidence; failing closed here
    // would stop every shipping build from registering for push.
    XCTAssertEqual(
      ApnsEnvironment.resolve(profileData: nil, isStoreDistributed: true),
      "production")
  }

  func testApnsMissingProfileWithoutStoreReceiptFailsClosed() {
    // No profile AND no receipt: nothing establishes the environment, so the
    // token must be withheld rather than guessed as production.
    XCTAssertNil(
      ApnsEnvironment.resolve(profileData: nil, isStoreDistributed: false))
  }

  func testApnsStoreEvidenceCannotOverrideAPresentProfile() {
    // A development profile stays sandbox even if a receipt is somehow present:
    // the signed profile is the stronger, more specific evidence.
    let dev = profileBlob(
      withEntitlements: "<key>aps-environment</key><string>development</string>")
    XCTAssertEqual(
      ApnsEnvironment.resolve(profileData: dev, isStoreDistributed: true),
      "sandbox")
  }

  func testApnsDevelopmentBundleIsNotTreatedAsStoreDistributed() {
    // The test bundle has no App Store receipt, so the real accessor must say
    // so — this is what makes the missing-profile branch safe.
    XCTAssertFalse(
      ApnsEnvironment.isStoreDistributed(bundle: Bundle(for: RunnerTests.self)))
    XCTAssertNil(
      ApnsEnvironment.current(bundle: Bundle(for: RunnerTests.self)),
      "a bundle with neither a profile nor a receipt must fail closed")
  }

  func testApnsRoutingDoesNotDependOnDebugCompileFlag() throws {
    // The dead `#if DEBUG` branch is what shipped the defect. Assert the
    // registration handler derives the environment from the entitlement.
    let source = try String(
      contentsOf: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Runner/AppDelegate.swift"))
    let start = try XCTUnwrap(
      source.range(of: "didRegisterForRemoteNotificationsWithDeviceToken"))
    let end = try XCTUnwrap(
      source.range(of: "didFailToRegisterForRemoteNotificationsWithError"))
    let handler = String(source[start.upperBound..<end.lowerBound])
    XCTAssertFalse(
      handler.contains("#if DEBUG"),
      "APNs environment must never come from a compile flag")
    XCTAssertTrue(handler.contains("ApnsEnvironment.current()"))
    XCTAssertTrue(
      handler.contains("guard let environment"),
      "an unresolved environment must withhold the token")
  }

  // MARK: - G3 cloud-egress denial state (C.4 / C.5), C.1 owner binding, P4 / P6

  private var egressFileURL: URL { container.appendingPathComponent("cloud_egress_state_v1.json") }
  private var inflightFileURL: URL { container.appendingPathComponent("native_inflight_uploads_v1.json") }

  private typealias Rec = SharedCaptureStore.CloudEgressRecord

  private func rec(_ state: String, _ generation: Int) -> Rec {
    Rec(state: state, transitionGeneration: generation, reservedVersion: generation + 1)
  }

  /// The stored map JSON: one entry per owner, keyed by uidHash.
  private func egressJSON(_ entries: [(String, String, Int)]) throws -> Data {
    var owners: [String: Rec] = [:]
    for (uid, state, generation) in entries {
      owners[try SharedCaptureStore.debugOwnerHash(uid)] = rec(state, generation)
    }
    return try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: owners))
  }

  private func egressState(_ uid: String) throws -> SharedCaptureStore.EgressSnapshot {
    try SharedCaptureStore.cloudEgressState(forUid: uid)
  }

  /// An item stamped to A under a Cloud-ON mirror, upload-eligible until a denial.
  private func stampedAllowedItem() throws -> (id: String, record: SharedCaptureStore.OwnerRecord) {
    let a = try publish(ownerA, cloud: true, ai: true)
    guard case .enqueued(let item) = put("egress 5.00 SAR") else { XCTFail("enqueue"); throw QueueTestError.enqueue }
    let id = try XCTUnwrap(item.id)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    return (id, a)
  }

  private enum QueueTestError: Error { case enqueue }

  // D5 (native): a corrupt egress FILE denies; the item stays local-only.
  func testCorruptEgressFileDeniesEgress() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertNotEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    try Data([0x00, 0xFF, 0x7B]).write(to: egressFileURL)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    XCTAssertEqual(try egressState(ownerB), .uncertain, "an unreadable store denies every owner")
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    // Unknown version frontier: even restriction refuses repair and preserves
    // both stores byte-for-byte. Admission remains fail-closed.
    let before = try rawState()
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3))
    XCTAssertEqual(try rawState(), before)
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
  }

  // D5 (native): an UNREADABLE Keychain copy denies (never "treated as absent").
  func testUnreadableEgressKeychainDeniesEgress() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, Data([0x01, 0x02])) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "undecodable Keychain bytes are corrupt, not absent")
    // With no readable store at all, an ON write cannot widen over the corruption.
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 9, reservedVersion: 10))
  }

  // D4 (native part): mixed-store records. A valid DISABLING/OFF in EITHER store
  // wins over ON or absence in the other.
  func testMixedStoreDisablingRecordWinsInEitherStore() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 3, reservedVersion: 4)
    XCTAssertNotEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // File says DISABLING, Keychain still says ON.
    try egressJSON([(ownerA, "DISABLING", 4)]).write(to: egressFileURL)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 4)))

    // Keychain says OFF, file says ON (crash between the two writes).
    try egressJSON([(ownerA, "ON", 3)]).write(to: egressFileURL)
    let off = try egressJSON([(ownerA, "OFF", 4)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, off) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // File absent, Keychain DISABLING: the single marker still denies.
    try? FileManager.default.removeItem(at: egressFileURL)
    let disabling = try egressJSON([(ownerA, "DISABLING", 4)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, disabling) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)

    // Two ON entries that disagree (generation) for the owner: conflicting => denied.
    try egressJSON([(ownerA, "ON", 5)]).write(to: egressFileURL)
    let staleOn = try egressJSON([(ownerA, "ON", 3)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, staleOn) }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
  }

  // C.5: per-owner records. B's restrictive write leaves A's DISABLING intact,
  // A's relaunch (a fresh read of both stores) still sees it, and A's entry
  // neither denies nor allows B.
  func testOtherOwnersWriteNeverDiscardsDisablingMarker() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 7, reservedVersion: 8)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerB, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)),
                   "B's writes never touch A's entry")
    XCTAssertEqual(try egressState(ownerB), .record(rec("ON", 2)))

    // A's relaunch: each store alone still carries A's marker.
    let fileData = try Data(contentsOf: egressFileURL)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecItemNotFound, nil) }
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)), "file alone")
    try FileManager.default.removeItem(at: egressFileURL)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, fileData) }
    XCTAssertEqual(try egressState(ownerA), .record(rec("DISABLING", 7)), "Keychain alone")

    // The stored keys are uidHash, never the raw uid.
    let text = String(data: fileData, encoding: .utf8) ?? ""
    XCTAssertFalse(text.contains(ownerA))
    XCTAssertTrue(text.contains(try SharedCaptureStore.debugOwnerHash(ownerA)))
  }

  // C.5: A's OFF entry does not deny B, B's own entry does.
  func testOtherOwnersOffRecordDoesNotDenyActiveOwner() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 5)
    let b = try publish(ownerB, cloud: true, ai: false)
    guard case .enqueued(let item) = put("B 2.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerB, ownerGeneration: b.generation, allowAi: false))
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)
    XCTAssertEqual(try egressState(ownerA), .record(rec("OFF", 4)))
  }

  // D7: an extension / background intent attempt during DISABLING and after OFF
  // makes no request: the admission gate the client runs immediately before
  // the network transport returns .localOnly and registers nothing in flight.
  func testDisablingAndOffAdmitNoNativeUpload() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))

    try SharedCaptureStore.setCloudEgressState(
      state: "DISABLING", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly, "DISABLING")
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "no APNs registration")

    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly, "OFF")
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    // The persistent gate survives a sign-out wipe of the queue and owner.
    SharedCaptureStore.purgeUserOwnedState()
    XCTAssertEqual(try egressState(ownerA), .record(rec("OFF", 2)))

    // A widening write is refused while denied, a restrictive one is not.
    XCTAssertFalse(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true, installID: "i", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 2))
    XCTAssertTrue(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: false, installID: "i", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 2))
    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: true, ai: true, version: 9, transitionGeneration: 2)) { error in
      guard case SharedCaptureStore.QueueError.egressDenied = error else {
        return XCTFail("expected egressDenied, got \(error)")
      }
    }
    try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: false, ai: false, version: 9, transitionGeneration: 2)

    // Explicit enable: strictly greater generation, then egress is admitted again.
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 4))
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 3, reservedVersion: 4)
    XCTAssertEqual(try egressState(ownerA), .record(rec("ON", 3)))
  }

  // MARK: - Pending enable barrier (consent-security amendment, native subunit)
  //
  // The real SharedCaptureStore over its real App Group container and Keychain.
  // A layer is the Keychain item or the App Group file; the DEBUG seams
  // (pendingKeychainReadOverride, egressKeychainReadOverride, stateLayerWriteFault)
  // inject unreadable layers and failed / silently dropped writes per layer.

  private typealias Phase = SharedCaptureStore.EnableTransitionResult
  private typealias Outcome = SharedCaptureStore.LayerOutcome
  private let foreignOperationId = String(repeating: "ab", count: 16)
  private let egressKC = "cloud_egress_state_v1"
  private let pendingKC = "cloud_egress_pending_v1"

  private var pendingFileURL: URL { container.appendingPathComponent("cloud_egress_pending_v1.json") }

  private func layerOutcomes(_ reports: [SharedCaptureStore.LayerReport]) -> [String: Outcome] {
    Dictionary(uniqueKeysWithValues: reports.map { ($0.layer, $0.outcome) })
  }

  /// Makes [uid] the COMMITTED native active owner (the existing F2 publication,
  /// restrictive mirror so it also works while egress is unreadable). The barrier
  /// APIs under test never do this themselves.
  private func ensureOwner(_ uid: String) throws {
    if try SharedCaptureStore.activeOwner()?.uid != uid { try publish(uid, cloud: false, ai: false) }
  }

  /// A FRESH begin for the committed owner (never adopts), or an explicit resume.
  private func begin(
    _ uid: String, _ generation: Int = 3, _ version: Int = 4, resume: Phase? = nil
  ) throws -> Phase {
    try ensureOwner(uid)
    return try SharedCaptureStore.beginCloudEgressEnable(
      ownerUid: uid, transitionGeneration: generation, reservedVersion: version,
      resumeOperationId: resume?.operationId, resumeOwnerEpoch: resume?.ownerEpoch)
  }

  private typealias Binding = (id: String, generation: Int, version: Int, ownerGeneration: Int, ownerEpoch: Int)

  private func bound(_ op: Phase) throws -> Binding {
    (try XCTUnwrap(op.operationId), try XCTUnwrap(op.transitionGeneration),
     try XCTUnwrap(op.reservedVersion), try XCTUnwrap(op.ownerGeneration),
     try XCTUnwrap(op.ownerEpoch))
  }

  private func writeOn(_ uid: String, _ op: Phase) throws -> Phase {
    let b = try bound(op)
    return try SharedCaptureStore.writeCloudEgressEnableOn(
      ownerUid: uid, operationId: b.id, transitionGeneration: b.generation,
      reservedVersion: b.version, ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch)
  }

  private func restrict(_ uid: String, _ op: Phase) throws -> Phase {
    let b = try bound(op)
    return try SharedCaptureStore.restrictCloudEgressEnable(
      ownerUid: uid, operationId: b.id, transitionGeneration: b.generation,
      reservedVersion: b.version, ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch)
  }

  private func finish(_ uid: String, _ op: Phase, abandon: Bool = false) throws -> Phase {
    let b = try bound(op)
    return try SharedCaptureStore.finishCloudEgressEnable(
      ownerUid: uid, operationId: b.id, transitionGeneration: b.generation,
      reservedVersion: b.version, ownerGeneration: b.ownerGeneration,
      ownerEpoch: b.ownerEpoch, abandon: abandon)
  }

  private func revokeLifetime(_ uid: String, _ op: Phase) throws -> Phase {
    let b = try bound(op)
    return try SharedCaptureStore.revokeCaptureAuthorizationLifetime(
      ownerUid: uid, operationId: b.id, transitionGeneration: b.generation,
      reservedVersion: b.version, ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch)
  }

  func testLifetimeFenceAfterCompletionAndBeforeCompletion() throws {
    for completeFirst in [true, false] {
      resetCapSeams()
      let (id, _) = try stampedAllowedItem()
      let op = try begin(ownerA, 3, 4)
      XCTAssertEqual(try writeOn(ownerA, op).status, .done)
      if completeFirst { XCTAssertEqual(try finish(ownerA, op).status, .done) }
      let revoked = try revokeLifetime(ownerA, op)
      XCTAssertEqual(revoked.status, .done)
      XCTAssertEqual(layerOutcomes(revoked.egress), ["file": .verified, "keychain": .verified])
      XCTAssertEqual(try egressRecord(file: ownerA)?.retirement?.operationId, op.operationId)
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.retirement?.ownerEpoch, op.ownerEpoch)
      XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
      XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
      if !completeFirst {
        XCTAssertEqual(try finish(ownerA, op).status, .ownerMismatch)
        XCTAssertEqual(try inspect(ownerA).status, .pending)
      }
      XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done, "exact retry")
    }
    resetCapSeams()
  }

  func testLifetimeFenceRevokesWhileFinishWaitsBeforeSharedLock() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = expectation(description: "queued finish settles")
    SharedCaptureStore.beforeLifetimeFinishLock = {
      entered.signal()
      _ = release.wait(timeout: .now() + 5)
    }
    DispatchQueue.global().async {
      defer { finished.fulfill() }
      do {
        XCTAssertEqual(try self.finish(self.ownerA, op).status, .ownerMismatch)
      } catch { XCTFail("queued finish failed: \(error)") }
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    release.signal()
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
  }

  func testLifetimeFenceKeepsAlreadyAdmittedRequestButRefusesNext() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    guard case .allowed = SharedCaptureStore.admitUpload(payloadID: id) else {
      return XCTFail("pre-fence admission")
    }
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 1)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 1)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
  }

  func testLifetimeFencePartialWriteAndUnreadableNeverConfirmOrRepair() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    fault("egress", "keychain", .silentDrop)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .incomplete)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
    SharedCaptureStore.stateLayerWriteFault = nil
    let bytes = Data([0xff, 0x00])
    try bytes.write(to: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .uncertain)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), bytes)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
  }

  func testLifetimeFenceCannotTouchNewOwnerOrBeDiscardedByLegacyWriter() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 99, reservedVersion: 99))
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 4)
    XCTAssertEqual(try egressRecord(file: ownerA)?.retirement?.operationId, op.operationId)
    XCTAssertThrowsError(try publish(ownerA, cloud: true, ai: false))
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    let newer = try publish(ownerB, cloud: false, ai: false)
    let fileBefore = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), newer)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileBefore)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
  }

  func testLifetimeFenceFreshRestrictivePublicationHasNewGeneration() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    let published = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(published.status, .done)
    let owner = try XCTUnwrap(published.owner)
    XCTAssertGreaterThan(owner.generation, try XCTUnwrap(op.ownerGeneration))
    XCTAssertEqual(published.egress.count, 2)
    XCTAssertTrue(published.egress.allSatisfy { $0.outcome == .verified && $0.state == "OFF" })
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try finish(ownerA, op).status, .noBarrier)
  }

  func testFreshRestrictivePublicationAfterCounterResetIsStrictlyNewer() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    let retiredGeneration = try XCTUnwrap(op.ownerGeneration)
    // The app-group counter was reset (reinstall) while the Keychain survived.
    appGroupDefaults.set(0, forKey: "capture_owner_generation_v1")
    let published = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(published.status, .done)
    let owner = try XCTUnwrap(published.owner)
    XCTAssertGreaterThan(owner.generation, retiredGeneration)
    XCTAssertEqual(appGroupDefaults.integer(forKey: "capture_owner_generation_v1"), owner.generation)
    XCTAssertEqual(published.egress.count, 2)
    XCTAssertTrue(published.egress.allSatisfy { $0.outcome == .verified && $0.state == "OFF" })
    // Neither the old retirement nor the old enable completion touches the new lifetime.
    let fileBefore = try Data(contentsOf: egressFileURL)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try finish(ownerA, op).status, .noBarrier)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileBefore)
  }

  func testRetiredSnapshotPublicationRequiresExactRetiredOffAboveFrontier() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    let epoch = try SharedCaptureStore.ownerEpoch()
    let inspected = try SharedCaptureStore.cloudEgressPending(forUid: ownerA)
    XCTAssertEqual(inspected.status, .noBarrier)
    XCTAssertEqual(inspected.egress.count, 2)
    XCTAssertTrue(inspected.egress.allSatisfy {
      $0.outcome == .verified && $0.state == "OFF" && $0.operationId != nil })
    let frontier = try XCTUnwrap(inspected.egressVersionFrontier)
    XCTAssertGreaterThanOrEqual(frontier, 4)
    let before = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    // The version must be strictly above every stored and retired version.
    let low = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: frontier, expectedEpoch: epoch,
      expectedRetiredCopies: inspected.egress)
    XCTAssertEqual(low.status, .conflict)
    XCTAssertNil(low.owner)
    // A snapshot naming another retirement is not the stored one.
    var other = inspected.egress
    other[0] = SharedCaptureStore.LayerReport(
      layer: other[0].layer, outcome: other[0].outcome, state: other[0].state,
      transitionGeneration: other[0].transitionGeneration,
      reservedVersion: other[0].reservedVersion,
      operationId: String(repeating: "f", count: 32),
      ownerGeneration: other[0].ownerGeneration, ownerEpoch: other[0].ownerEpoch)
    let changed = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: frontier + 1, expectedEpoch: epoch, expectedRetiredCopies: other)
    XCTAssertEqual(changed.status, .conflict)
    XCTAssertNil(changed.owner)
    // Never combined with another expectation mode.
    XCTAssertThrowsError(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: frontier + 1, expectedEpoch: epoch,
      expectedOffCopies: inspected.egress, expectedRetiredCopies: inspected.egress))
    XCTAssertEqual(try Data(contentsOf: egressFileURL), before)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
    // The exact snapshot publishes a fresh restrictive lifetime, never ON.
    let published = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: frontier + 1, expectedEpoch: epoch,
      expectedRetiredCopies: inspected.egress)
    XCTAssertEqual(published.status, .done)
    let owner = try XCTUnwrap(published.owner)
    XCTAssertGreaterThan(owner.generation, try XCTUnwrap(op.ownerGeneration))
    XCTAssertEqual(published.egress.count, 2)
    XCTAssertTrue(published.egress.allSatisfy {
      $0.outcome == .verified && $0.state == "OFF" && $0.operationId == nil
        && $0.reservedVersion == frontier + 1 })
    XCTAssertNil(try egressRecord(file: ownerA)?.retirement)
    XCTAssertNil(try egressRecord(keychain: ownerA)?.retirement)
    // The retired snapshot no longer holds: a replay changes nothing.
    let after = try Data(contentsOf: egressFileURL)
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: frontier + 2, expectedEpoch: epoch,
      expectedRetiredCopies: inspected.egress).status, .conflict)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), after)
    // The old retirement and the old enable completion do not touch the new lifetime.
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try finish(ownerA, op).status, .noBarrier)
  }

  func testRestrictivePublicationForAbsentRecordIsCompleteOffAndPendingConflicts() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let absent = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 1, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(absent.status, .done)
    XCTAssertEqual(absent.egress.count, 2)
    XCTAssertTrue(absent.egress.allSatisfy { $0.outcome == .verified && $0.state == "OFF" })
    // A pending enable of the same owner is never acknowledged or cleared.
    let op = try begin(ownerA, 3, 4)
    let pending = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(pending.status, .conflict)
    XCTAssertNil(pending.owner)
    XCTAssertNotEqual(try finish(ownerA, op).status, .ownerMismatch)
  }

  func testRecoveryPublicationRequiresInspectedOffEvidenceAndNeverLowers() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    let first = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 2, expectedEpoch: epoch)
    XCTAssertEqual(first.status, .done)
    let lifetimeGeneration = try XCTUnwrap(first.owner?.generation)
    let before = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    // A supplied version below the stored frontier is still refused (stale).
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 1, expectedEpoch: epoch).status, .stale)
    // The inspected evidence must match exactly and the version must be above it.
    for (tg, rv, v, lg, le) in [
      (0, 1, 3, lifetimeGeneration, epoch), (5, 2, 3, lifetimeGeneration, epoch),
      (0, 2, 2, lifetimeGeneration, epoch),
      (0, 2, 3, lifetimeGeneration + 1, epoch), (0, 2, 3, lifetimeGeneration, epoch + 1),
    ] {
      let refused = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: v, expectedEpoch: epoch,
        recover: (tg, rv, lg, le))
      XCTAssertEqual(refused.status, .conflict, "\(tg) \(rv) \(v) \(lg) \(le)")
      XCTAssertNil(refused.owner)
    }
    // An unbound expectation does not match a lifetime-bound record.
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 3, expectedEpoch: epoch, recover: (0, 2, nil, nil)).status,
      .conflict)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), before)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
    let recovered = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 3, expectedEpoch: epoch,
      recover: (0, 2, lifetimeGeneration, epoch))
    XCTAssertEqual(recovered.status, .done)
    XCTAssertEqual(recovered.egress.count, 2)
    XCTAssertTrue(recovered.egress.allSatisfy {
      $0.outcome == .verified && $0.state == "OFF" && $0.reservedVersion == 3 })
    XCTAssertEqual(try egressRecord(file: ownerA)?.reservedVersion, 3)
    XCTAssertEqual(try egressRecord(keychain: ownerA)?.reservedVersion, 3)
    // The old inspected frontier no longer holds: a replay changes nothing.
    let after = try Data(contentsOf: egressFileURL)
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: epoch,
      recover: (0, 2, lifetimeGeneration, epoch)).status, .conflict)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), after)
  }

  func testRecoveryPublicationAcceptsAnAgreedUnboundLegacyRecord() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 20, reservedVersion: 2)
    // A lifetime-bound expectation does not match the unbound record.
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 3, expectedEpoch: epoch, recover: (20, 2, 1, epoch)).status,
      .conflict)
    let recovered = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 3, expectedEpoch: epoch, recover: (20, 2, nil, nil))
    XCTAssertEqual(recovered.status, .done)
    XCTAssertTrue(recovered.egress.allSatisfy {
      $0.outcome == .verified && $0.state == "OFF" && $0.reservedVersion == 3
        && $0.transitionGeneration == 20 }, "the transition generation is kept")
  }

  func testRestrictiveOffRepairRestoresMissingCopyWithSameLifetime() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    let first = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 2, expectedEpoch: epoch)
    let generation = try XCTUnwrap(first.owner?.generation)
    // Both orientations: loss of the App Group file during reinstall, and a
    // missing Keychain copy. The surviving OFF is verified before repairing.
    for missingFile in [true, false] {
      if missingFile {
        try FileManager.default.removeItem(at: egressFileURL)
      } else {
        XCTAssertEqual(SnapshotTestKeychain.remove(forKey: egressKC), errSecSuccess)
      }
      try SharedCaptureStore.setCloudEgressState(
        state: "OFF", ownerUid: ownerA, transitionGeneration: 21, reservedVersion: 2)
      let file = try XCTUnwrap(egressRecord(file: ownerA))
      let keychain = try XCTUnwrap(egressRecord(keychain: ownerA))
      XCTAssertEqual(file, keychain)
      XCTAssertEqual(file.state, "OFF")
      XCTAssertEqual(file.lifetimeOwnerGeneration, generation)
      XCTAssertEqual(file.lifetimeOwnerEpoch, epoch)
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    }
    let recovered = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 3, expectedEpoch: epoch,
      recover: (21, 2, generation, epoch))
    XCTAssertEqual(recovered.status, .done)
    XCTAssertTrue(recovered.egress.allSatisfy { $0.state == "OFF" })
  }

  func testRecoveryPublicationRefusesLayersNamingDifferentLifetimes() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    let first = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 2, expectedEpoch: epoch)
    let lifetimeGeneration = try XCTUnwrap(first.owner?.generation)
    // The file layer names another lifetime than the keychain layer.
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    var map = try JSONDecoder().decode(SharedCaptureStore.CloudEgressMap.self,
      from: try Data(contentsOf: egressFileURL))
    let held = try XCTUnwrap(map.owners[hash])
    map.owners[hash] = SharedCaptureStore.CloudEgressRecord(
      state: held.state, transitionGeneration: held.transitionGeneration,
      reservedVersion: held.reservedVersion,
      lifetimeOwnerGeneration: lifetimeGeneration + 7,
      lifetimeOwnerEpoch: held.lifetimeOwnerEpoch)
    try JSONEncoder().encode(map).write(to: egressFileURL)
    let before = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    for lg in [lifetimeGeneration, lifetimeGeneration + 7] {
      let refused = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: 3, expectedEpoch: epoch, recover: (0, 2, lg, epoch))
      XCTAssertEqual(refused.status, .conflict)
    }
    XCTAssertEqual(try Data(contentsOf: egressFileURL), before)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
  }

  func testExplicitOffCopiesReconcileDifferentLifetimesUnderLock() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    let first = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 2, expectedEpoch: epoch)
    let generation = try XCTUnwrap(first.owner?.generation)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    var map = try JSONDecoder().decode(SharedCaptureStore.CloudEgressMap.self,
      from: try Data(contentsOf: egressFileURL))
    map.owners[hash] = SharedCaptureStore.CloudEgressRecord(
      state: "OFF", transitionGeneration: 20, reservedVersion: 9,
      lifetimeOwnerGeneration: generation + 7, lifetimeOwnerEpoch: epoch)
    try JSONEncoder().encode(map).write(to: egressFileURL)
    let expected = try SharedCaptureStore.cloudEgressPending(forUid: ownerA).egress
    let repaired = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 10, expectedEpoch: epoch, expectedOffCopies: expected)
    XCTAssertEqual(repaired.status, .done)
    XCTAssertGreaterThan(try XCTUnwrap(repaired.owner?.generation), generation + 7)
    XCTAssertTrue(repaired.egress.allSatisfy {
      $0.outcome == .verified && $0.state == "OFF" &&
        $0.transitionGeneration == 20 && $0.reservedVersion == 10 &&
        $0.ownerGeneration == repaired.owner?.generation && $0.ownerEpoch == epoch
    })
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    // A delayed publication that inspected the old copies cannot touch the new lifetime.
    let before = try Data(contentsOf: egressFileURL)
    let keychain = SnapshotTestKeychain.read(forKey: egressKC).data
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 11, expectedEpoch: epoch, expectedOffCopies: expected).status,
      .conflict)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), before)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, keychain)
  }

  func testExplicitOffCopiesRefuseOnPendingRetirementAndUnreadable() throws {
    for hazard in ["ON", "pending", "retirement", "unreadable"] {
      resetCapSeams()
      _ = try stampedAllowedItem()
      let epoch = try SharedCaptureStore.ownerEpoch()
      _ = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: 2, expectedEpoch: epoch)
      let op = try begin(ownerA, 3, 4)
      if hazard == "ON" || hazard == "retirement" {
        XCTAssertEqual(try writeOn(ownerA, op).status, .done)
        XCTAssertEqual(try finish(ownerA, op).status, .done)
        if hazard == "retirement" {
          XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
        }
      } else if hazard == "unreadable" {
        try Data([0xff]).write(to: egressFileURL)
      }
      let expected = try SharedCaptureStore.cloudEgressPending(forUid: ownerA).egress
      let before = try Data(contentsOf: egressFileURL)
      let keychain = SnapshotTestKeychain.read(forKey: egressKC).data
      let refused = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: 10, expectedEpoch: epoch, expectedOffCopies: expected)
      XCTAssertNotEqual(refused.status, .done, hazard)
      XCTAssertNil(refused.owner, hazard)
      XCTAssertEqual(try Data(contentsOf: egressFileURL), before, hazard)
      XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, keychain, hazard)
      resetCapSeams()
    }
  }

  func testRecoveryPublicationRefusesAPendingOperation() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let epoch = try SharedCaptureStore.ownerEpoch()
    let first = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 2, expectedEpoch: epoch)
    let lifetimeGeneration = try XCTUnwrap(first.owner?.generation)
    _ = try begin(ownerA, 3, 4)
    let before = try Data(contentsOf: egressFileURL)
    XCTAssertEqual(try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 5, expectedEpoch: epoch,
      recover: (0, 2, lifetimeGeneration, epoch)).status, .conflict)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), before)
  }

  // MARK: - Lifetime retirement covers every enable transition (Astra A1, section 2b)
  // Written for the approved isolated native harness; NOT executed by the authoring team.

  func testLifetimeRetirementCoversNewerEnableGenerationOfSameLifecycle() throws {
    for finishFirst in [true, false] {
      resetCapSeams()
      let (id, _) = try stampedAllowedItem()
      let published = try begin(ownerA, 3, 4)          // publication binding gen g
      XCTAssertEqual(try writeOn(ownerA, published).status, .done)
      XCTAssertEqual(try finish(ownerA, published).status, .done)
      let enable = try begin(ownerA, 4, 5)             // enable gen g+1, same lifecycle
      XCTAssertEqual(try writeOn(ownerA, enable).status, .done)
      if finishFirst { XCTAssertEqual(try finish(ownerA, enable).status, .done) }
      let revoked = try revokeLifetime(ownerA, published)
      XCTAssertEqual(revoked.status, .done)
      XCTAssertEqual(layerOutcomes(revoked.egress), ["file": .verified, "keychain": .verified])
      XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.retirement?.operationId, published.operationId)
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(egressRecord(file: ownerA)?.transitionGeneration), 4)
      XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
      if !finishFirst {
        XCTAssertNotEqual(try finish(ownerA, enable).status, .done, "retirement-first prevents completion")
      }
    }
    resetCapSeams()
  }

  func testLifetimeRetirementWithPendingAlreadyAbsentAndAdmissionOrdering() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    guard case .allowed = SharedCaptureStore.admitUpload(payloadID: id) else {
      return XCTFail("admission immediately before retirement")
    }
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly, "immediately after")
  }

  func testStaleRetirementPreservesNewerLifecycleAndDifferentOwner() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    let republished = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(republished.status, .done)
    let next = try begin(ownerA, 5, 6)
    XCTAssertEqual(try writeOn(ownerA, next).status, .done)
    XCTAssertEqual(try finish(ownerA, next).status, .done)
    let fileBefore = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileBefore)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    _ = try publish(ownerB, cloud: false, ai: false)
    let fileB = try Data(contentsOf: egressFileURL)
    XCTAssertEqual(try revokeLifetime(ownerA, next).status, .ownerMismatch)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileB)
  }

  func testBoundRecordAdmissionRequiresSameUidHashAndGenerationThroughEveryEntrance() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    guard case .allowed = SharedCaptureStore.admitUpload(payloadID: id) else {
      return XCTFail("bound ON of the active owner admits")
    }
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest())
    // Another account becomes active while A's bound ON (same numeric generation
    // and epoch) is still stored: A's evidence must not admit through any entrance.
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    _ = try publish(ownerB, cloud: false, ai: false)
    // A's item is stamped under A; with B active it is "not this owner's to process
    // now": `.waiting` = no egress, no banner (authorizeUploadLocked; the App Intent
    // and AppDelegate both treat it as durable-queue-and-wait). Stricter than
    // `.localOnly`, which would show A's local-parse banner under B.
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .waiting, "upload")
    // A host request has no capture/subject; it is judged by the ACTIVE owner B's own
    // entry (egressDenied: "another owner's entry is never applied to this owner").
    // B is unset, so B's own request is admitted; A's bound ON admits nothing here.
    XCTAssertEqual(try egressState(ownerB), .unset, "B is judged by its own entry")
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest(), "host request is B's own")
    XCTAssertThrowsError(try publish(ownerA, cloud: true, ai: false), "mirror/config widening")
  }

  // N-RT / N-R8 (Astra R7 Q14): the owner UID and the owner HASH broken
  // INDEPENDENTLY, with every other binding value unchanged. Unlike the
  // clear-and-republish `activeUidReplaced` pattern, the stored bound ON (both
  // layers), the egress map key, the owner generation counter and the epoch
  // counter are all left exactly as the completed enable wrote them; only the
  // active-owner record read by admission differs. Written for the approved
  // isolated native harness; NOT executed by the authoring team.
  private func assertBoundOnRefusedThroughEveryEntrance(
    _ label: String,
    breaking: (SharedCaptureStore.OwnerRecord) throws -> SharedCaptureStore.OwnerRecord,
    hostRequestUsesBrokenSubject: Bool
  ) throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, active) = try stampedAllowedItem()
    let broken = try breaking(active)
    let op = try completedBoundOn(ownerA)
    let good = try boundOn(op)
    func widen() -> Bool {
      SharedCaptureStore.setBackendConfig(
        cloudProcessingEnabled: true, installID: "i", deviceSecret: "s",
        backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
        ownerUid: ownerA, transitionGeneration: good.transitionGeneration)
    }
    // Control: the unbroken binding admits every entrance.
    XCTAssertTrue(widen(), "control config \(label)")
    guard case .allowed = SharedCaptureStore.admitUpload(payloadID: id) else {
      return XCTFail("control upload \(label)")
    }
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest(), "control host \(label)")

    let fileBefore = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    let generationCounter = appGroupDefaults.object(forKey: "capture_owner_generation_v1") as? Int
    let epochCounter = appGroupDefaults.object(forKey: "capture_owner_epoch_v1") as? Int
    // Only the active-owner record differs; its generation is the stored counter.
    XCTAssertEqual(broken.generation, active.generation, "generation unchanged \(label)")
    XCTAssertEqual(generationCounter, active.generation, "counter unchanged \(label)")
    SharedCaptureStore.ownerRecordReadOverride = {
      (errSecSuccess, try? JSONEncoder().encode(broken))
    }

    XCTAssertFalse(widen(), "backend-config widening must refuse: \(label)")
    if case .allowed = SharedCaptureStore.admitUpload(payloadID: id) {
      XCTFail("upload must not be allowed: \(label)")
    }
    if hostRequestUsesBrokenSubject {
      // The subject of a host request is the active owner's uid: here A's bound
      // ON is judged against a mismatched active hash.
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "host request: \(label)")
    }
    XCTAssertThrowsError(try publish(ownerA, cloud: true, ai: false), "mirror widening: \(label)")
    // A restrictive config write is never refused for denial.
    XCTAssertTrue(
      SharedCaptureStore.setBackendConfig(
        cloudProcessingEnabled: false, installID: "i", deviceSecret: "s",
        backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
        ownerUid: ownerA, transitionGeneration: good.transitionGeneration),
      "restrictive config: \(label)")

    // The refusals changed none of the stored binding evidence.
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileBefore, "egress file: \(label)")
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore, "egress keychain: \(label)")
    XCTAssertEqual(appGroupDefaults.object(forKey: "capture_owner_generation_v1") as? Int, generationCounter)
    XCTAssertEqual(appGroupDefaults.object(forKey: "capture_owner_epoch_v1") as? Int, epochCounter)
  }

  func testBoundOnRefusedWhenOnlyTheActiveUidIsWrongAndHashGenerationEpochAreValid() throws {
    try assertBoundOnRefusedThroughEveryEntrance("wrong uid only", breaking: { a in
      // Wrong UID, valid hash of the ORIGINAL owner, same generation, same epoch.
      SharedCaptureStore.OwnerRecord(uid: self.ownerB, uidHash: a.uidHash, generation: a.generation)
    }, hostRequestUsesBrokenSubject: false)
  }

  func testBoundOnRefusedWhenOnlyTheActiveHashIsWrongAndUidGenerationEpochAreValid() throws {
    try assertBoundOnRefusedThroughEveryEntrance("wrong hash only", breaking: { a in
      // Wrong hash (a well-formed hash of ANOTHER uid), same uid, generation, epoch.
      SharedCaptureStore.OwnerRecord(
        uid: a.uid, uidHash: try SharedCaptureStore.debugOwnerHash(self.ownerB), generation: a.generation)
    }, hostRequestUsesBrokenSubject: true)
  }

  // N-RT (Astra R6 unit 6 / R45 R3): the backend-config ENTRANCE itself, with each
  // binding component broken independently. Written for the approved isolated
  // native harness; NOT executed by the authoring team.
  func testBackendConfigEntranceRejectsEachIndependentBindingMismatch() throws {
    enum Break: String, CaseIterable {
      case lifetimeGenerationBothLayers, lifetimeEpochBothLayers, onlyOneLayerGeneration,
           onlyOneLayerEpoch, storedGenerationCounter, liveEpochCounter, activeUidReplaced
    }
    func widen(_ generation: Int) -> Bool {
      SharedCaptureStore.setBackendConfig(
        cloudProcessingEnabled: true, installID: "i", deviceSecret: "s",
        backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
        ownerUid: ownerA, transitionGeneration: generation)
    }
    func restrict(_ generation: Int) -> Bool {
      SharedCaptureStore.setBackendConfig(
        cloudProcessingEnabled: false, installID: "i", deviceSecret: "s",
        backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
        ownerUid: ownerA, transitionGeneration: generation)
    }
    for kind in Break.allCases {
      resetCapSeams()
      let (id, _) = try stampedAllowedItem()
      let op = try completedBoundOn(ownerA)
      let good = try boundOn(op)
      // Control: the unbroken bound ON admits the direct config entrance.
      XCTAssertTrue(widen(good.transitionGeneration), "control before \(kind)")
      let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
      func broken(generation: Int? = nil, epoch: Int? = nil) -> Rec {
        Rec(state: "ON", transitionGeneration: good.transitionGeneration,
            reservedVersion: good.reservedVersion,
            lifetimeOwnerGeneration: generation ?? good.lifetimeOwnerGeneration,
            lifetimeOwnerEpoch: epoch ?? good.lifetimeOwnerEpoch)
      }
      let genOff = (good.lifetimeOwnerGeneration ?? 0) + 1
      let epochOff = (good.lifetimeOwnerEpoch ?? 0) + 1
      switch kind {
      case .lifetimeGenerationBothLayers:
        try putEgress(file: [hash: broken(generation: genOff)], keychain: [hash: broken(generation: genOff)])
      case .lifetimeEpochBothLayers:
        try putEgress(file: [hash: broken(epoch: epochOff)], keychain: [hash: broken(epoch: epochOff)])
      case .onlyOneLayerGeneration:
        try putEgress(file: [hash: good], keychain: [hash: broken(generation: genOff)])
      case .onlyOneLayerEpoch:
        try putEgress(file: [hash: broken(epoch: epochOff)], keychain: [hash: good])
      case .storedGenerationCounter:
        appGroupDefaults.set(genOff, forKey: "capture_owner_generation_v1")
      case .liveEpochCounter:
        appGroupDefaults.set(epochOff, forKey: "capture_owner_epoch_v1")
      case .activeUidReplaced:
        try SharedCaptureStore.clearActiveOwner(clearHint: false)
        _ = try publish(ownerB, cloud: false, ai: false)
      }
      XCTAssertFalse(widen(good.transitionGeneration), "config entrance must refuse: \(kind)")
      // Replaced active owner: the stamped item waits (no egress, no banner); every
      // other break keeps the stamped owner and is denied as `.localOnly`.
      XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id),
                     kind == .activeUidReplaced ? .waiting : .localOnly, "upload: \(kind)")
      // With the owner replaced, the host request's subject is B, judged by B's own
      // (unset) entry; A's bound ON never applies to B.
      XCTAssertEqual(SharedCaptureStore.egressAdmitsHostRequest(),
                     kind == .activeUidReplaced, "host request: \(kind)")
      // A restrictive config write is never refused for denial.
      XCTAssertTrue(restrict(good.transitionGeneration), "restrictive config: \(kind)")
    }
    resetCapSeams()
  }

  func testRestrictPublishedLifetimePreservesMetadataAndOwnLayerProof() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let publication = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(publication.status, .done)
    let op = try begin(ownerA, 4, 5)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let before = try XCTUnwrap(egressRecord(file: ownerA))
    // A barrier in the other layer cannot authorize compensation here.
    let pendingBytes = try XCTUnwrap(rawPending(file: true))
    try FileManager.default.removeItem(at: pendingFileURL)
    let refused = try restrict(ownerA, op)
    XCTAssertEqual(refused.status, .incomplete)
    XCTAssertEqual(layerOutcomes(refused.egress)["file"], .notOurs)
    XCTAssertEqual(try egressRecord(file: ownerA), before)
    try pendingBytes.write(to: pendingFileURL)
    let restricted = try restrict(ownerA, op)
    XCTAssertEqual(restricted.status, .done)
    for entry in [try egressRecord(file: ownerA), try egressRecord(keychain: ownerA)] {
      XCTAssertEqual(entry?.state, "OFF")
      XCTAssertEqual(entry?.lifetimeOwnerGeneration, op.ownerGeneration)
      XCTAssertEqual(entry?.lifetimeOwnerEpoch, op.ownerEpoch)
      XCTAssertNil(entry?.retirement)
    }
    XCTAssertEqual(try inspect(ownerA).status, .pending)
  }

  func testAbandonExactRetiredLifetimeClearsOnlyPendingAndKeepsDenial() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(try revokeLifetime(ownerA, op).status, .done)
    let fileBefore = try Data(contentsOf: egressFileURL)
    let kcBefore = SnapshotTestKeychain.read(forKey: egressKC).data
    let abandoned = try finish(ownerA, op, abandon: true)
    XCTAssertEqual(abandoned.operation, "abandon")
    XCTAssertEqual(abandoned.status, .done)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), fileBefore)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, kcBefore)
    XCTAssertNil(rawPending(file: true))
    XCTAssertNil(rawPending(file: false))
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
  }

  func testRestrictAndAbandonLeaveDifferentLifetimeEvidenceUntouched() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let b = try bound(op)
    let foreign = SharedCaptureStore.PendingEnable(operationId: foreignOperationId,
      transitionGeneration: b.generation, reservedVersion: b.version,
      ownerGeneration: b.ownerGeneration + 1, ownerEpoch: b.ownerEpoch)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let record = SharedCaptureStore.CloudEgressRecord(state: "OFF",
      transitionGeneration: b.generation, reservedVersion: b.version,
      lifetimeOwnerGeneration: foreign.ownerGeneration, lifetimeOwnerEpoch: foreign.ownerEpoch,
      retirement: foreign)
    let data = try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: [hash: record]))
    try data.write(to: egressFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(data, forKey: egressKC), errSecSuccess)
    let pendingBefore = rawPending(file: true)
    XCTAssertEqual(try restrict(ownerA, op).status, .incomplete)
    let abandoned = try finish(ownerA, op, abandon: true)
    XCTAssertEqual(abandoned.operation, "abandon")
    XCTAssertEqual(abandoned.status, .ownerMismatch)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), data)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, data)
    XCTAssertEqual(rawPending(file: true), pendingBefore)
  }

  // MARK: - N-R1 / N-R2 explicit bound ON (written test-first; NOT EXECUTED here:
  // the harness uses the shipping App Group and Keychain service, so it must only
  // run against an isolated storage namespace)

  /// The exact bound ON a phase-authorized writeOn must produce for [op].
  private func boundOn(_ op: Phase) throws -> Rec {
    let b = try bound(op)
    return Rec(state: "ON", transitionGeneration: b.generation, reservedVersion: b.version,
               lifetimeOwnerGeneration: b.ownerGeneration, lifetimeOwnerEpoch: b.ownerEpoch)
  }

  /// A record in either orientation of the lifecycle: legacy (no fields) or bound.
  private func offRec(_ generation: Int, _ version: Int, ownerGeneration: Int? = nil,
                      ownerEpoch: Int? = nil) -> Rec {
    Rec(state: "OFF", transitionGeneration: generation, reservedVersion: version,
        lifetimeOwnerGeneration: ownerGeneration, lifetimeOwnerEpoch: ownerEpoch)
  }

  /// Writes a raw per-layer egress map (nil removes that layer entirely).
  private func putEgress(file: [String: Rec]?, keychain: [String: Rec]?) throws {
    if let file {
      try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: file)).write(to: egressFileURL)
    } else {
      try? FileManager.default.removeItem(at: egressFileURL)
    }
    if let keychain {
      XCTAssertEqual(SnapshotTestKeychain.writeData(
        try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: keychain)),
        forKey: egressKC), errSecSuccess)
    } else {
      SnapshotTestKeychain.remove(forKey: egressKC)
    }
  }

  /// Every raw byte the snapshot/admission reads must leave untouched.
  private struct RawState: Equatable {
    let egressFile: Data?
    let egressKeychain: Data?
    let pendingFile: Data?
    let pendingKeychain: Data?
    let owner: SharedCaptureStore.OwnerRecord?
    let epoch: Int
    let generationCounter: Int
  }

  private func rawState() throws -> RawState {
    RawState(
      egressFile: try? Data(contentsOf: egressFileURL),
      egressKeychain: SnapshotTestKeychain.read(forKey: egressKC).data,
      pendingFile: rawPending(file: true), pendingKeychain: rawPending(file: false),
      owner: try SharedCaptureStore.activeOwner(), epoch: try SharedCaptureStore.ownerEpoch(),
      generationCounter: appGroupDefaults.integer(forKey: "capture_owner_generation_v1"))
  }

  func testSnapshotFailureVocabularyAndReadOnlyStages() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let mappings: [(Error, String)] = [
      (SharedCaptureStore.QueueError.keyUnavailable(errSecInteractionNotAllowed), "interaction_not_allowed"),
      (SharedCaptureStore.QueueError.keyUnavailable(errSecMissingEntitlement), "missing_entitlement"),
      (SharedCaptureStore.QueueError.keyUnavailable(errSecDecode), "decode"),
      (SharedCaptureStore.QueueError.keyUnavailable(-99999), "key_other"),
      (SharedCaptureStore.QueueError.unreadable, "unreadable"),
      (SharedCaptureStore.QueueError.lockUnavailable, "lock_unavailable"),
      (NSError(domain: "private", code: 123), "unexpected")
    ]
    for (error, category) in mappings {
      for stage in [SharedCaptureStore.SnapshotStage.lock, .barrier, .activeowner,
                    .hmac, .ownerlesshint, .inflight] {
        XCTAssertEqual(SharedCaptureStore.SnapshotFailure(underlying: error, stage: stage).details,
                       ["contract": "snapshot_v1", "stage": stage.rawValue, "category": category])
      }
    }
    let before = try rawState()
    SharedCaptureStore.lockUnavailableOverride = true
    XCTAssertThrowsError(try SharedCaptureStore.diagnosticCloudEgressState(forUid: "")) {
      XCTAssertEqual(($0 as? SharedCaptureStore.SnapshotFailure)?.details,
                     ["contract": "snapshot_v1", "stage": "lock", "category": "lock_unavailable"])
    }
    XCTAssertThrowsError(try SharedCaptureStore.cloudEgressState(forUid: "")) {
      guard case SharedCaptureStore.QueueError.lockUnavailable = $0 else {
        return XCTFail("original throwing API changed")
      }
    }
    SharedCaptureStore.lockUnavailableOverride = false
    XCTAssertEqual(try rawState(), before)
    SharedCaptureStore.ownerRecordReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertThrowsError(try SharedCaptureStore.diagnosticCloudEgressState(forUid: "")) {
      XCTAssertEqual(($0 as? SharedCaptureStore.SnapshotFailure)?.details,
                     ["contract": "snapshot_v1", "stage": "activeowner", "category": "interaction_not_allowed"])
    }
    SharedCaptureStore.ownerRecordReadOverride = nil
    XCTAssertEqual(try rawState(), before)
  }

  /// Snapshot uncertain + native admission denied, with every raw store unchanged.
  private func assertSnapshotDenied(_ uid: String, _ message: String = "",
                                    hostRequestAdmitted: Bool = false,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
    let before = try rawState()
    XCTAssertEqual(try egressState(uid), .uncertain, message, file: file, line: line)
    XCTAssertEqual(SharedCaptureStore.egressAdmitsHostRequest(), hostRequestAdmitted, message,
                   file: file, line: line)
    XCTAssertEqual(try rawState(), before, "reads never mutate: \(message)", file: file, line: line)
  }

  /// begin -> writeOn -> complete under the committed owner, bound ON in both layers.
  private func completedBoundOn(_ uid: String, _ generation: Int = 3, _ version: Int = 4) throws -> Phase {
    let op = try begin(uid, generation, version)
    XCTAssertEqual(try writeOn(uid, op).status, .done)
    XCTAssertEqual(try finish(uid, op).status, .done)
    return op
  }

  // N-R tests 1: matching restrictive publication -> begin -> NEW explicit bound
  // ON -> complete. Exact lifecycle in both layers; snapshot ON; admission allowed.
  func testBoundOnAfterRestrictivePublicationIsExactAndSnapshotOn() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let publication = try SharedCaptureStore.publishRestrictiveCaptureOwner(
      uid: ownerA, version: 4, expectedEpoch: try SharedCaptureStore.ownerEpoch())
    XCTAssertEqual(publication.status, .done)
    let op = try begin(ownerA, 4, 5)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let expected = try boundOn(op)
    XCTAssertEqual(try egressRecord(file: ownerA), expected)
    XCTAssertEqual(try egressRecord(keychain: ownerA), expected)
    XCTAssertEqual(expected.lifetimeOwnerGeneration, publication.owner?.generation)
    XCTAssertEqual(expected.lifetimeOwnerEpoch, try SharedCaptureStore.ownerEpoch())
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "pending barrier denies")
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try egressState(ownerA), .record(expected))
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest())
    XCTAssertEqual(try egressRecord(file: ownerA), expected, "complete rewrites nothing")
    XCTAssertEqual(try egressRecord(keychain: ownerA), expected)
  }

  // N-R tests 2: completed bound ON, then clearActiveOwner: snapshot uncertain and
  // admission denied; the epoch advanced; reads leave every byte alone.
  func testBoundOnSnapshotIsUncertainAfterOwnerClear() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try completedBoundOn(ownerA)
    XCTAssertEqual(try egressState(ownerA), .record(try boundOn(op)))
    guard case .allowed = SharedCaptureStore.authorizeUpload(payloadID: id) else {
      return XCTFail("valid bound ON admits")
    }
    let epoch = try SharedCaptureStore.ownerEpoch()
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    XCTAssertGreaterThan(try SharedCaptureStore.ownerEpoch(), epoch)
    try assertSnapshotDenied(ownerA, "owner cleared")
    // No active owner: the stamped item is "not this owner's to process now".
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .waiting)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .waiting)
  }

  // N-R tests 3: same UID new generation, and another current UID, separately.
  func testBoundOnSnapshotIsUncertainForNewGenerationAndOtherCurrentOwner() throws {
    for other in [false, true] {
      resetCapSeams()
      defer { resetCapSeams() }
      let (id, _) = try stampedAllowedItem()
      let op = try completedBoundOn(ownerA)
      try SharedCaptureStore.clearActiveOwner(clearHint: false)
      let successor = try publish(other ? ownerB : ownerA, cloud: false, ai: false)
      XCTAssertNotEqual(successor.generation, op.ownerGeneration)
      let bytes = try rawState()
      // Another current owner B is judged by its own (unset) entry for a host request.
      try assertSnapshotDenied(ownerA, other ? "other current owner" : "same uid, new generation",
                               hostRequestAdmitted: other)
      XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .waiting)
      if other {
        XCTAssertEqual(try egressState(ownerB), .unset, "the requested uid is judged by its own entry")
      }
      XCTAssertEqual(try rawState().egressFile, bytes.egressFile)
      XCTAssertEqual(try rawState().egressKeychain, bytes.egressKeychain)
    }
  }

  // N-R tests 4: one bound layer missing (each orientation): uncertain/denied, and
  // the absent layer stays absent (reads never repair).
  func testBoundOnSnapshotNeedsBothLayers() throws {
    for removeFile in [true, false] {
      resetCapSeams()
      defer { resetCapSeams() }
      _ = try stampedAllowedItem()
      _ = try completedBoundOn(ownerA)
      if removeFile {
        try FileManager.default.removeItem(at: egressFileURL)
      } else {
        SnapshotTestKeychain.remove(forKey: egressKC)
      }
      try assertSnapshotDenied(ownerA, removeFile ? "file layer missing" : "keychain layer missing")
      if removeFile {
        XCTAssertFalse(FileManager.default.fileExists(atPath: egressFileURL.path))
      } else {
        XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).status, errSecItemNotFound)
      }
    }
  }

  // N-R tests 5: mismatched epoch / generation, corrupt owner evidence and corrupt
  // egress layers (both orientations) are uncertain/denied with raw bytes
  // unchanged; a valid OFF stays visible after clear / unreadable ownership.
  func testBoundOnSnapshotRejectsMismatchedOrCorruptEvidence() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try completedBoundOn(ownerA)
    let b = try bound(op)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let valid = try boundOn(op)
    XCTAssertEqual(try egressState(ownerA), .record(valid))
    // Mismatched lifetime fields in BOTH layers (generation, then epoch).
    for (generation, epoch) in [(b.ownerGeneration + 1, b.ownerEpoch), (b.ownerGeneration, b.ownerEpoch + 1)] {
      let moved = Rec(state: "ON", transitionGeneration: b.generation, reservedVersion: b.version,
                      lifetimeOwnerGeneration: generation, lifetimeOwnerEpoch: epoch)
      try putEgress(file: [hash: moved], keychain: [hash: moved])
      try assertSnapshotDenied(ownerA, "stored lifetime \(generation)/\(epoch)")
    }
    // One layer carries the wrong lifetime, the other the right one.
    let wrong = Rec(state: "ON", transitionGeneration: b.generation, reservedVersion: b.version,
                    lifetimeOwnerGeneration: b.ownerGeneration, lifetimeOwnerEpoch: b.ownerEpoch + 1)
    try putEgress(file: [hash: wrong], keychain: [hash: valid])
    try assertSnapshotDenied(ownerA, "layers disagree")
    // A half-bound record (epoch only) is never a bound ON.
    let half = Rec(state: "ON", transitionGeneration: b.generation, reservedVersion: b.version,
                   lifetimeOwnerGeneration: nil, lifetimeOwnerEpoch: b.ownerEpoch)
    try putEgress(file: [hash: half], keychain: [hash: half])
    try assertSnapshotDenied(ownerA, "half-bound")
    try putEgress(file: [hash: valid], keychain: [hash: valid])
    XCTAssertEqual(try egressState(ownerA), .record(valid))
    // Actual counters: owner generation counter and epoch counter move.
    appGroupDefaults.set(b.ownerGeneration + 1, forKey: "capture_owner_generation_v1")
    try assertSnapshotDenied(ownerA, "generation counter")
    appGroupDefaults.set(b.ownerGeneration, forKey: "capture_owner_generation_v1")
    appGroupDefaults.set(b.ownerEpoch + 1, forKey: "capture_owner_epoch_v1")
    try assertSnapshotDenied(ownerA, "epoch counter")
    appGroupDefaults.set(b.ownerEpoch, forKey: "capture_owner_epoch_v1")
    XCTAssertEqual(try egressState(ownerA), .record(valid))
    // Corrupt owner evidence.
    let corruptOwner = SharedCaptureStore.OwnerRecord(
      uid: ownerA, uidHash: String(repeating: "0", count: 64), generation: b.ownerGeneration)
    SharedCaptureStore.ownerRecordReadOverride = { (errSecSuccess, try? JSONEncoder().encode(corruptOwner)) }
    XCTAssertEqual(try egressState(ownerA), .uncertain, "corrupt owner evidence")
    SharedCaptureStore.ownerRecordReadOverride = nil
    XCTAssertEqual(try egressState(ownerA), .record(valid))
    // Corrupt/unreadable egress layers, both orientations; raw bytes unchanged.
    let garbage = Data([0x00, 0xFF, 0x7B])
    try garbage.write(to: egressFileURL)
    try assertSnapshotDenied(ownerA, "corrupt file layer")
    XCTAssertEqual(try Data(contentsOf: egressFileURL), garbage)
    try putEgress(file: [hash: valid], keychain: [hash: valid])
    XCTAssertEqual(SnapshotTestKeychain.writeData(garbage, forKey: egressKC), errSecSuccess)
    try assertSnapshotDenied(ownerA, "corrupt keychain layer")
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, garbage)
    try putEgress(file: [hash: valid], keychain: [hash: valid])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertEqual(try egressState(ownerA), .uncertain, "unreadable keychain layer")
    SharedCaptureStore.egressKeychainReadOverride = nil
    guard case .allowed = SharedCaptureStore.authorizeUpload(payloadID: id) else {
      return XCTFail("valid bound ON in both readable layers admits")
    }
    // A valid OFF is still reported after the owner is cleared or unreadable.
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 9, reservedVersion: 9)
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    for _ in 0..<2 {
      guard case let .record(restrictive) = try egressState(ownerA) else {
        return XCTFail("restrictive OFF must stay visible")
      }
      XCTAssertEqual(restrictive.state, "OFF")
      SharedCaptureStore.ownerRecordReadOverride = { (errSecSuccess, try? JSONEncoder().encode(corruptOwner)) }
    }
    SharedCaptureStore.ownerRecordReadOverride = nil
    try garbage.write(to: egressFileURL)
    guard case let .record(offWithBadLayer) = try egressState(ownerA) else {
      return XCTFail("restrictive OFF in the readable layer stays visible")
    }
    XCTAssertEqual(offWithBadLayer.state, "OFF")
  }

  /// Runs begin -> mixed-input writeOn -> complete and checks the bound result.
  /// [file] / [keychain] build that layer's record for the requested owner from the
  /// lifecycle `begin` captured (nil = the layer holds NO entry for the owner).
  /// Unrelated owner B keeps a DIFFERENT complete record in each layer.
  private func assertPromotesToBoundOn(
    file: (Int, Int) -> Rec?, keychain: (Int, Int) -> Rec?,
    _ message: String, fileID: StaticString = #filePath, line: UInt = #line
  ) throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    let b = try bound(op)
    let hashA = try SharedCaptureStore.debugOwnerHash(ownerA)
    let hashB = try SharedCaptureStore.debugOwnerHash(ownerB)
    let bFile = Rec(state: "ON", transitionGeneration: 1, reservedVersion: 2)
    let bKeychain = Rec(state: "OFF", transitionGeneration: 6, reservedVersion: 7,
                        lifetimeOwnerGeneration: 99, lifetimeOwnerEpoch: 98)
    var fileMap: [String: Rec] = [hashB: bFile]
    var keychainMap: [String: Rec] = [hashB: bKeychain]
    fileMap[hashA] = file(b.ownerGeneration, b.ownerEpoch)
    keychainMap[hashA] = keychain(b.ownerGeneration, b.ownerEpoch)
    try putEgress(file: fileMap, keychain: keychainMap)
    let on = try writeOn(ownerA, op)
    XCTAssertEqual(on.status, .done, message, file: fileID, line: line)
    let expected = try boundOn(op)
    XCTAssertEqual(try egressRecord(file: ownerA), expected, message, file: fileID, line: line)
    XCTAssertEqual(try egressRecord(keychain: ownerA), expected, message, file: fileID, line: line)
    XCTAssertEqual(try egressRecord(file: ownerB), bFile, "B preserved in file: \(message)", file: fileID, line: line)
    XCTAssertEqual(try egressRecord(keychain: ownerB), bKeychain, "B preserved in keychain: \(message)", file: fileID, line: line)
    XCTAssertEqual(try finish(ownerA, op).status, .done, message, file: fileID, line: line)
    XCTAssertEqual(try egressState(ownerA), .record(expected), message, file: fileID, line: line)
    guard case .allowed = SharedCaptureStore.authorizeUpload(payloadID: id) else {
      return XCTFail("admitted: \(message)", file: fileID, line: line)
    }
    // N-R tests 10: afterwards, epoch/generation loss => uncertain/denied.
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    try assertSnapshotDenied(ownerA, "after owner loss: \(message)", file: fileID, line: line)
  }

  // N-R tests 6: legacy OFF + current-bound OFF, both orientations, with a higher
  // transition and exact pending/live proof => BOTH layers hold the explicit bound
  // ON (uniformly promoted, never stripped); unrelated owner B is preserved per layer.
  func testMixedLegacyAndBoundOffAreUniformlyPromotedToExplicitBoundOn() throws {
    let legacy: (Int, Int) -> Rec? = { [self] _, _ in offRec(2, 3) }
    let boundOff: (Int, Int) -> Rec? = { [self] generation, epoch in
      offRec(2, 3, ownerGeneration: generation, ownerEpoch: epoch)
    }
    try assertPromotesToBoundOn(file: legacy, keychain: boundOff, "legacy file / bound keychain")
    try assertPromotesToBoundOn(file: boundOff, keychain: legacy, "bound file / legacy keychain")
  }

  // N-R tests 7: absent owner entry vs current-bound OFF (both orientations) and an
  // all-legacy pair: exact proof establishes an explicitly bound ON, never a legacy grant.
  func testAbsentAndAllLegacyInputsBecomeExplicitBoundOnNeverLegacy() throws {
    let absent: (Int, Int) -> Rec? = { _, _ in nil }
    let legacy: (Int, Int) -> Rec? = { [self] _, _ in offRec(2, 3) }
    let boundOff: (Int, Int) -> Rec? = { [self] generation, epoch in
      offRec(2, 3, ownerGeneration: generation, ownerEpoch: epoch)
    }
    try assertPromotesToBoundOn(file: absent, keychain: boundOff, "absent file entry / bound keychain")
    try assertPromotesToBoundOn(file: boundOff, keychain: absent, "bound file / absent keychain entry")
    try assertPromotesToBoundOn(file: legacy, keychain: legacy, "all-legacy pair")
    try assertPromotesToBoundOn(file: absent, keychain: absent, "no entries")
  }

  // N-R tests 8: wrong/stale lifecycle, retirement, same-generation conflicting target
  // and newer transition input are refused BEFORE any write.
  func testWriteOnRefusesBadLifecycleInputBeforeAnyWrite() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    let b = try bound(op)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let hashB = try SharedCaptureStore.debugOwnerHash(ownerB)
    let retired = SharedCaptureStore.PendingEnable(operationId: op.operationId!,
      transitionGeneration: b.generation, reservedVersion: b.version,
      ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch)
    let foreignB = Rec(state: "ON", transitionGeneration: 8, reservedVersion: 8)
    let cases: [(String, Rec, SharedCaptureStore.TransitionStatus)] = [
      ("other generation", offRec(2, 3, ownerGeneration: b.ownerGeneration + 1, ownerEpoch: b.ownerEpoch), .ownerMismatch),
      ("other epoch", offRec(2, 3, ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch + 1), .ownerMismatch),
      // A half-bound record fails egress decoding (decodeEgressMap), so the layer is
      // unreadable/corrupt: `.uncertain` ("nothing was judged or written"). Dart treats
      // every non-`done` reply identically (confirmsOnWritten false -> abort).
      ("half bound generation", offRec(2, 3, ownerGeneration: b.ownerGeneration, ownerEpoch: nil), .uncertain),
      ("half bound epoch", offRec(2, 3, ownerGeneration: nil, ownerEpoch: b.ownerEpoch), .uncertain),
      ("retired lifetime", Rec(state: "OFF", transitionGeneration: 2, reservedVersion: 3,
         lifetimeOwnerGeneration: b.ownerGeneration, lifetimeOwnerEpoch: b.ownerEpoch,
         retirement: retired), .ownerMismatch),
      ("same generation conflicting target", offRec(b.generation, b.version), .stale),
      ("same generation stripped ON", Rec(state: "ON", transitionGeneration: b.generation,
         reservedVersion: b.version), .stale),
      ("newer transition", offRec(b.generation + 1, b.version + 1), .stale),
    ]
    for (name, record, status) in cases {
      for orientation in [true, false] {
        try putEgress(file: [hash: orientation ? record : offRec(1, 2), hashB: foreignB],
                      keychain: [hash: orientation ? offRec(1, 2) : record, hashB: foreignB])
        let before = try rawState()
        XCTAssertEqual(try writeOn(ownerA, op).status, status, "\(name) \(orientation)")
        XCTAssertEqual(try rawState(), before, "refused before any write: \(name) \(orientation)")
        XCTAssertEqual(try inspect(ownerA).status, .pending, "pending retained: \(name)")
      }
    }
  }

  // N-R tests 9: an exactly matching bound ON re-write is idempotent and completes;
  // a forged STRIPPED ON is refused by writeOn and by complete, with pending retained.
  func testIdempotentBoundOnCompletesAndForgedStrippedOnIsRefused() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let bytes = try rawState()
    XCTAssertEqual(try writeOn(ownerA, op).status, .done, "idempotent exact bound ON")
    // Semantically identical: JSONEncoder key order is not stable across encodes, so
    // the egress layers are compared decoded; every other raw field is compared as is.
    let again = try rawState()
    XCTAssertEqual(try egressRecord(file: ownerA), try boundOn(op))
    XCTAssertEqual(try egressRecord(keychain: ownerA), try boundOn(op))
    XCTAssertEqual(again.egressFile?.count, bytes.egressFile?.count)
    XCTAssertEqual(again.egressKeychain?.count, bytes.egressKeychain?.count)
    XCTAssertEqual(again.pendingFile, bytes.pendingFile)
    XCTAssertEqual(again.pendingKeychain, bytes.pendingKeychain)
    XCTAssertEqual(again.owner, bytes.owner)
    XCTAssertEqual(again.epoch, bytes.epoch)
    XCTAssertEqual(again.generationCounter, bytes.generationCounter)
    // Stripped ON forged in both layers before complete.
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let stripped = Rec(state: "ON", transitionGeneration: 3, reservedVersion: 4)
    try putEgress(file: [hash: stripped], keychain: [hash: stripped])
    let forged = try rawState()
    XCTAssertEqual(try writeOn(ownerA, op).status, .stale, "stripped target is not the bound target")
    XCTAssertEqual(try finish(ownerA, op).status, .incomplete)
    XCTAssertEqual(try rawState(), forged, "nothing was written or cleared")
    XCTAssertEqual(try inspect(ownerA).status, .pending, "pending retained")
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    // The intended bound target still succeeds once restored.
    let expected = try boundOn(op)
    try putEgress(file: [hash: expected], keychain: [hash: expected])
    XCTAssertEqual(try finish(ownerA, op).status, .done)
    XCTAssertEqual(try egressState(ownerA), .record(expected))
  }

  private func rawPending(file: Bool) -> Data? {
    if file { return try? Data(contentsOf: pendingFileURL) }
    return SnapshotTestKeychain.read(forKey: pendingKC).data
  }

  private func pendingMap(file: Bool) throws -> SharedCaptureStore.PendingEnableMap? {
    try rawPending(file: file).map {
      try JSONDecoder().decode(SharedCaptureStore.PendingEnableMap.self, from: $0)
    }
  }

  private func inspect(_ uid: String) throws -> Phase {
    try SharedCaptureStore.cloudEgressPending(forUid: uid)
  }

  private func egressRecord(file uid: String) throws -> Rec? {
    guard let data = try? Data(contentsOf: egressFileURL) else { return nil }
    return try JSONDecoder().decode(SharedCaptureStore.CloudEgressMap.self, from: data)
      .owners[try SharedCaptureStore.debugOwnerHash(uid)]
  }

  private func egressRecord(keychain uid: String) throws -> Rec? {
    guard let data = SnapshotTestKeychain.read(forKey: egressKC).data else { return nil }
    return try JSONDecoder().decode(SharedCaptureStore.CloudEgressMap.self, from: data)
      .owners[try SharedCaptureStore.debugOwnerHash(uid)]
  }

  private func setEgress(file entries: [(String, String, Int)]) throws {
    try egressJSON(entries).write(to: egressFileURL)
  }

  private func setEgress(keychain entries: [(String, String, Int)]) throws {
    XCTAssertEqual(SnapshotTestKeychain.writeData(try egressJSON(entries), forKey: egressKC), errSecSuccess)
  }

  /// (uid, operationId, generation, version, ownerGeneration, ownerEpoch)
  private func pendingJSON(_ entries: [(String, String, Int, Int, Int, Int)]) throws -> Data {
    var owners: [String: SharedCaptureStore.PendingEnable] = [:]
    for (uid, id, generation, version, ownerGeneration, ownerEpoch) in entries {
      owners[try SharedCaptureStore.debugOwnerHash(uid)] = SharedCaptureStore.PendingEnable(
        operationId: id, transitionGeneration: generation, reservedVersion: version,
        ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
    }
    return try JSONEncoder().encode(SharedCaptureStore.PendingEnableMap(owners: owners))
  }

  private func fault(_ store: String, _ layer: String, _ kind: SharedCaptureStore.LayerWriteFault) {
    SharedCaptureStore.stateLayerWriteFault = { s, l in s == store && l == layer ? kind : .none }
  }

  private func assertEgressDenied(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
    guard case SharedCaptureStore.QueueError.egressDenied = error else {
      return XCTFail("expected egressDenied, got \(error)", file: file, line: line)
    }
  }

  // 1: begin persists the denial in BOTH layers, read back, before any ON.
  func testBeginPersistsDenialInBothLayersBeforeAnyOn() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path),
                   "a healthy install has no barrier store")
    let epoch = try SharedCaptureStore.ownerEpoch()
    let op = try begin(ownerA, 1, 2)
    XCTAssertEqual(op.status, .done)
    XCTAssertEqual(layerOutcomes(op.barrier), ["file": .verified, "keychain": .verified])
    XCTAssertEqual(op.operationId?.count, 32)
    XCTAssertEqual(op.ownerGeneration, a.generation, "bound to the committed owner record")
    XCTAssertEqual(op.ownerEpoch, epoch, "bound to the committed owner epoch")
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), a, "begin never changes the owner")
    XCTAssertEqual(try SharedCaptureStore.ownerEpoch(), epoch, "begin never bumps the epoch")
    XCTAssertNil(try egressRecord(file: ownerA), "no ON was written by begin")
    XCTAssertNil(try egressRecord(keychain: ownerA))
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "no APNs registration")
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    let text = String(data: try Data(contentsOf: pendingFileURL), encoding: .utf8) ?? ""
    XCTAssertFalse(text.contains(ownerA), "keyed by the HMAC uidHash, never a raw uid")
    XCTAssertTrue(text.contains(try SharedCaptureStore.debugOwnerHash(ownerA)))
    XCTAssertNoThrow(try SharedCaptureStore.setConsentMirror(
      uid: ownerB, cloud: true, ai: false, version: 1), "another owner is unaffected")
  }

  // 2: no legacy writer, mirror, publish or backend config can bypass the barrier.
  func testLegacyAndMirrorWritesCannotBypassPending() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    _ = try begin(ownerA, 1, 2)
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)) { assertEgressDenied($0) }
    XCTAssertNil(try egressRecord(file: ownerA))
    XCTAssertNil(try egressRecord(keychain: ownerA))
    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: true, ai: true, version: 9)) { assertEgressDenied($0) }
    XCTAssertThrowsError(try publish(ownerA, cloud: true, ai: false)) { assertEgressDenied($0) }
    XCTAssertFalse(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true, installID: "i", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 1))
    // Restrictive writes still pass and never lift the barrier.
    XCTAssertNoThrow(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: false, ai: false, version: 9))
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
  }

  // 3: a fresh begin NEVER adopts an existing operation, even with identical
  // parameters; only an explicit resume of the exact operation touches it.
  func testFreshBeginNeverAdoptsAndOnlyExplicitResumeRepairs() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let first = try begin(ownerA, 1, 2)
    XCTAssertEqual(first.status, .done)
    let before = (rawPending(file: true), rawPending(file: false))
    for (generation, version) in [(1, 2), (1, 3), (2, 3)] {
      let other = try begin(ownerA, generation, version)
      XCTAssertEqual(other.status, .conflict, "fresh begin \(generation)/\(version)")
      XCTAssertEqual(other.operationId, first.operationId, "the pending operation is reported, not adopted")
    }
    XCTAssertEqual(rawPending(file: true), before.0)
    XCTAssertEqual(rawPending(file: false), before.1, "a conflicting begin writes nothing")
    let epoch = try XCTUnwrap(first.ownerEpoch)
    // Wrong id, wrong epoch, wrong binding: still conflicts and writes nothing.
    for (id, resumeEpoch, generation) in [
      (foreignOperationId, epoch, 1), (try XCTUnwrap(first.operationId), epoch + 1, 1),
      (try XCTUnwrap(first.operationId), epoch, 2),
    ] {
      XCTAssertEqual(try SharedCaptureStore.beginCloudEgressEnable(
        ownerUid: ownerA, transitionGeneration: generation, reservedVersion: 2,
        resumeOperationId: id, resumeOwnerEpoch: resumeEpoch).status, .conflict)
    }
    XCTAssertEqual(rawPending(file: true), before.0)
    let resumed = try begin(ownerA, 1, 2, resume: first)
    XCTAssertEqual(resumed.status, .done)
    XCTAssertEqual(resumed.operationId, first.operationId)
    // B is independent and does not disturb A's barrier.
    let b = try begin(ownerB, 1, 2)
    XCTAssertEqual(b.status, .done)
    XCTAssertNotEqual(b.operationId, first.operationId)
    XCTAssertEqual(try inspect(ownerA).operationId, first.operationId)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
    // Resuming something that does not exist creates nothing.
    XCTAssertEqual(try finish(ownerA, first, abandon: true).status, .done)
    XCTAssertEqual(try inspect(ownerA).status, .noBarrier)
    try ensureOwner(ownerA)
    XCTAssertEqual(try begin(ownerA, 1, 2, resume: first).status, .noBarrier)
    XCTAssertEqual(try inspect(ownerA).status, .noBarrier)
  }

  // 4: a generation that is not strictly newer is stale; an unreadable egress
  // state judges nothing and writes nothing.
  func testBeginRefusesStaleGenerationAndUncertainEgress() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 5, reservedVersion: 6)
    XCTAssertEqual(try begin(ownerA, 5, 6).status, .stale)
    XCTAssertEqual(try begin(ownerA, 4, 5).status, .stale)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))
    XCTAssertEqual(try begin(ownerA, 6, 7).status, .done)
    let garbage = Data([0x00, 0xFF, 0x7B])
    try garbage.write(to: egressFileURL)
    let uncertain = try begin(ownerB, 1, 2)
    XCTAssertEqual(uncertain.status, .uncertain)
    XCTAssertEqual(layerOutcomes(uncertain.egress)["file"], .unreadable)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), garbage, "an unreadable layer is never overwritten")
    XCTAssertEqual(try inspect(ownerB).status, .noBarrier)
  }

  // 5: every pending layer failing independently (fail or silent drop) leaves a
  // partial barrier that still denies; a retry repairs it under the same operation.
  func testBeginPartialWriteFailsClosedAndRetryRepairs() throws {
    for layer in ["file", "keychain"] {
      for kind in [SharedCaptureStore.LayerWriteFault.fail, .silentDrop] {
        resetCapSeams()
        defer { resetCapSeams() }
        let (id, _) = try stampedAllowedItem()
        fault("pending", layer, kind)
        let partial = try begin(ownerA, 1, 2)
        XCTAssertEqual(partial.status, .incomplete, "\(layer) \(kind)")
        let outcomes = layerOutcomes(partial.barrier)
        XCTAssertEqual(outcomes[layer], kind == .fail ? .writeFailed : .mismatch)
        XCTAssertEqual(outcomes[layer == "file" ? "keychain" : "file"], .verified)
        XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                       "the layer that did persist still denies")
        XCTAssertEqual(try writeOn(ownerA, partial).status, .incomplete,
                       "no ON is written under a partial barrier")
        XCTAssertNil(try egressRecord(file: ownerA))
        XCTAssertNil(try egressRecord(keychain: ownerA))
        SharedCaptureStore.stateLayerWriteFault = nil
        XCTAssertEqual(try begin(ownerA, 1, 2).status, .conflict,
                       "a fresh begin does not adopt the partial operation")
        let repaired = try begin(ownerA, 1, 2, resume: partial)
        XCTAssertEqual(repaired.status, .done)
        XCTAssertEqual(repaired.operationId, partial.operationId)
        XCTAssertEqual(layerOutcomes(repaired.barrier), ["file": .verified, "keychain": .verified])
      }
    }
  }

  // 6: unreadable / corrupt barrier layers fail closed for every owner.
  func testUnreadableOrCorruptBarrierLayerFailsClosed() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    try Data([0x00, 0xFF, 0x7B]).write(to: pendingFileURL)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    XCTAssertEqual(try egressState(ownerB), .uncertain, "an unreadable store denies every owner")
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)) { assertEgressDenied($0) }
    // ANY unreadable layer: nothing is judged, reconstructed or written, whether
    // the other layer is healthy-absent or unreadable too.
    let garbage = Data([0x00, 0xFF, 0x7B])
    let none = try begin(ownerA, 1, 2)
    XCTAssertEqual(none.status, .uncertain)
    XCTAssertEqual(try Data(contentsOf: pendingFileURL), garbage, "the unreadable layer is not overwritten")
    XCTAssertNil(rawPending(file: false), "the healthy layer is not written either")
    SharedCaptureStore.pendingKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertEqual(try begin(ownerA, 1, 2).status, .uncertain)
    XCTAssertEqual(try Data(contentsOf: pendingFileURL), garbage)
    SharedCaptureStore.pendingKeychainReadOverride = nil
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly, "still denied")
  }

  // 7: writeOn needs the exact barrier in both layers and reads each layer back.
  func testWriteOnNeedsBothBarrierLayersAndVerifiesBothEgressLayers() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 1, 2)
    let on = try writeOn(ownerA, op)
    XCTAssertEqual(on.status, .done)
    XCTAssertEqual(layerOutcomes(on.egress), ["file": .verified, "keychain": .verified])
    // N-R2: the new ON is explicitly bound to the verified operation's lifecycle.
    let exactOn = try boundOn(op)
    XCTAssertEqual(try egressRecord(file: ownerA), exactOn)
    XCTAssertEqual(try egressRecord(keychain: ownerA), exactOn)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                   "ON in the egress state does not open anything while the barrier stands")
    // A wrong operation id, wrong generation or wrong version is not this operation.
    let b = try bound(op)
    let wrong = try SharedCaptureStore.writeCloudEgressEnableOn(
      ownerUid: ownerA, operationId: foreignOperationId, transitionGeneration: 1, reservedVersion: 2,
      ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch)
    XCTAssertEqual(wrong.status, .conflict)
    XCTAssertEqual(try SharedCaptureStore.writeCloudEgressEnableOn(
      ownerUid: ownerA, operationId: b.id, transitionGeneration: 9, reservedVersion: 2,
      ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch).status, .conflict)
    XCTAssertEqual(try SharedCaptureStore.writeCloudEgressEnableOn(
      ownerUid: ownerA, operationId: b.id, transitionGeneration: 1, reservedVersion: 2,
      ownerGeneration: b.ownerGeneration + 1, ownerEpoch: b.ownerEpoch).status, .conflict,
      "the owner binding is part of the operation's identity")
    // Barrier gone from one layer: no ON is written (partial), gone from both: none.
    try? FileManager.default.removeItem(at: pendingFileURL)
    XCTAssertEqual(try writeOn(ownerA, op).status, .incomplete)
    SnapshotTestKeychain.remove(forKey: pendingKC)
    XCTAssertEqual(try writeOn(ownerA, op).status, .noBarrier)
  }

  // 8: each egress layer failing independently during writeOn is reported.
  func testWriteOnLayerFailuresAreReportedPerLayer() throws {
    for layer in ["file", "keychain"] {
      for kind in [SharedCaptureStore.LayerWriteFault.fail, .silentDrop] {
        resetCapSeams()
        defer { resetCapSeams() }
        let (id, _) = try stampedAllowedItem()
        let op = try begin(ownerA, 1, 2)
        fault("egress", layer, kind)
        let on = try writeOn(ownerA, op)
        XCTAssertEqual(on.status, .incomplete, "\(layer) \(kind)")
        let outcomes = layerOutcomes(on.egress)
        XCTAssertEqual(outcomes[layer], kind == .fail ? .writeFailed : .mismatch)
        XCTAssertEqual(outcomes[layer == "file" ? "keychain" : "file"], .verified)
        XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
      }
    }
  }

  // 9: writeOn refuses a newer generation or a same-generation OFF, and an
  // unreadable layer is never overwritten.
  func testWriteOnRefusesNewerGenerationAndNeverOverwritesUnreadable() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try begin(ownerA, 2, 3)
    try setEgress(file: [(ownerA, "OFF", 2)])
    XCTAssertEqual(try writeOn(ownerA, op).status, .stale, "same generation OFF")
    XCTAssertNil(try egressRecord(keychain: ownerA), "nothing was written to the other layer")
    try setEgress(file: [(ownerA, "ON", 7)])
    XCTAssertEqual(try writeOn(ownerA, op).status, .stale, "newer generation")
    let garbage = Data([0x00, 0xFF, 0x7B])
    try garbage.write(to: egressFileURL)
    let unreadable = try writeOn(ownerA, op)
    XCTAssertEqual(unreadable.status, .uncertain)
    XCTAssertEqual(try Data(contentsOf: egressFileURL), garbage)
    XCTAssertNil(try egressRecord(keychain: ownerA))
  }

  func testGenericRestrictionPreservesHigherVersionInBothLegacyAndBoundLayers() throws {
    for bound in [false, true] {
      resetCapSeams()
      defer { resetCapSeams() }
      try ensureOwner(ownerA)
      let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
      let owner = try XCTUnwrap(SharedCaptureStore.activeOwner())
      let epoch = try SharedCaptureStore.ownerEpoch()
      func entry(_ generation: Int, _ version: Int) -> SharedCaptureStore.CloudEgressRecord {
        SharedCaptureStore.CloudEgressRecord(state: "ON", transitionGeneration: generation,
          reservedVersion: version, lifetimeOwnerGeneration: bound ? owner.generation : nil,
          lifetimeOwnerEpoch: bound ? epoch : nil)
      }
      try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: [hash: entry(30, 3)]))
        .write(to: egressFileURL)
      let keychain = try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: [hash: entry(20, 9)]))
      XCTAssertEqual(SnapshotTestKeychain.writeData(keychain, forKey: egressKC), errSecSuccess)
      try SharedCaptureStore.setCloudEgressState(state: "DISABLING", ownerUid: ownerA,
        transitionGeneration: 31, reservedVersion: 1)
      XCTAssertEqual(try egressRecord(file: ownerA)?.reservedVersion, 9)
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.reservedVersion, 9)
      try SharedCaptureStore.setCloudEgressState(state: "OFF", ownerUid: ownerA,
        transitionGeneration: 31, reservedVersion: 1)
      XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.state, "OFF")
      XCTAssertEqual(try egressRecord(file: ownerA)?.reservedVersion, 9)
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.reservedVersion, 9)
      let retired = try SharedCaptureStore.revokeCaptureAuthorizationLifetime(
        ownerUid: ownerA, operationId: foreignOperationId, transitionGeneration: 31,
        reservedVersion: 1, ownerGeneration: owner.generation, ownerEpoch: epoch)
      XCTAssertEqual(retired.status, .done)
      XCTAssertEqual(try egressRecord(file: ownerA)?.reservedVersion, 9)
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.reservedVersion, 9)
    }
  }

  func testGenericBoundWriterChecksBothGenerationsBeforeAnyWrite() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try ensureOwner(ownerA)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let owner = try XCTUnwrap(SharedCaptureStore.activeOwner())
    let epoch = try SharedCaptureStore.ownerEpoch()
    func entry(_ generation: Int) -> SharedCaptureStore.CloudEgressRecord {
      SharedCaptureStore.CloudEgressRecord(state: "ON", transitionGeneration: generation,
        reservedVersion: 9, lifetimeOwnerGeneration: owner.generation, lifetimeOwnerEpoch: epoch)
    }
    try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: [hash: entry(20)]))
      .write(to: egressFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(
      try JSONEncoder().encode(SharedCaptureStore.CloudEgressMap(owners: [hash: entry(40)])),
      forKey: egressKC), errSecSuccess)
    let before = try rawState()
    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(state: "OFF", ownerUid: ownerA,
      transitionGeneration: 31, reservedVersion: 1))
    XCTAssertEqual(try rawState(), before)
  }

  func testWriteOnRefusesOlderGenerationHigherVersionWithoutChangingBytes() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try begin(ownerA, 30, 3)
    let hash = try SharedCaptureStore.debugOwnerHash(ownerA)
    var map = SharedCaptureStore.CloudEgressMap()
    map.owners[hash] = SharedCaptureStore.CloudEgressRecord(
      state: "OFF", transitionGeneration: 20, reservedVersion: 9)
    let bytes = try JSONEncoder().encode(map)
    try bytes.write(to: egressFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(bytes, forKey: egressKC), errSecSuccess)
    let before = try rawState()
    XCTAssertEqual(try writeOn(ownerA, op).status, .stale)
    let after = try rawState()
    XCTAssertEqual(after.egressFile, before.egressFile)
    XCTAssertEqual(after.egressKeychain, before.egressKeychain)
  }

  // 10: mixed old OFF in one layer + the operation's ON in the other: only the
  // layer that holds the operation's ON is rewritten.
  func testRestrictOnlyRewritesTheOperationsOnPerLayer() throws {
    for onInFile in [true, false] {
      resetCapSeams()
      defer { resetCapSeams() }
      let op = try begin(ownerA, 3, 4)
      if onInFile {
        try setEgress(file: [(ownerA, "ON", 3)])
        try setEgress(keychain: [(ownerA, "OFF", 2)])
      } else {
        try setEgress(file: [(ownerA, "OFF", 2)])
        try setEgress(keychain: [(ownerA, "ON", 3)])
      }
      let oldOffBefore = onInFile
        ? SnapshotTestKeychain.read(forKey: egressKC).data : try? Data(contentsOf: egressFileURL)
      let result = try restrict(ownerA, op)
      XCTAssertEqual(result.status, .done)
      let outcomes = layerOutcomes(result.egress)
      XCTAssertEqual(outcomes[onInFile ? "file" : "keychain"], .restricted)
      XCTAssertEqual(outcomes[onInFile ? "keychain" : "file"], .alreadyRestrictive)
      XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
      XCTAssertEqual(try egressRecord(file: ownerA)?.transitionGeneration, onInFile ? 3 : 2)
      XCTAssertEqual(try egressRecord(keychain: ownerA)?.transitionGeneration, onInFile ? 2 : 3)
      let oldOffAfter = onInFile
        ? SnapshotTestKeychain.read(forKey: egressKC).data : try? Data(contentsOf: egressFileURL)
      XCTAssertEqual(oldOffAfter, oldOffBefore, "the already-restrictive layer was not rewritten")
      XCTAssertEqual(try inspect(ownerA).status, .pending, "compensation never lifts the barrier")
    }
  }

  // 11: a newer generation and an unreadable layer are never touched; a foreign
  // ON is reported, never claimed.
  func testRestrictNeverDowngradesNewerOrTouchesUnreadableOrForeign() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try begin(ownerA, 3, 4)
    // Newer generation in the file layer, the operation's ON in the keychain.
    try setEgress(file: [(ownerA, "ON", 5)])
    try setEgress(keychain: [(ownerA, "ON", 3)])
    let newerBytes = try Data(contentsOf: egressFileURL)
    var result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .superseded, "keychain": .restricted])
    XCTAssertEqual(try Data(contentsOf: egressFileURL), newerBytes)

    // Unreadable file layer beside the operation's ON: reported, never overwritten.
    try setEgress(keychain: [(ownerA, "ON", 3)])
    let garbage = Data([0x00, 0xFF, 0x7B])
    try garbage.write(to: egressFileURL)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .incomplete)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .unreadable, "keychain": .restricted])
    XCTAssertEqual(try Data(contentsOf: egressFileURL), garbage)
    XCTAssertEqual(try inspect(ownerA).barrier.count, 2)

    // Unreadable Keychain layer: the ON in the file is restricted, the Keychain is not written.
    try setEgress(file: [(ownerA, "ON", 3)])
    let keychainBefore = try XCTUnwrap(SnapshotTestKeychain.read(forKey: egressKC).data)
    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    result = try restrict(ownerA, op)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .restricted, "keychain": .unreadable])
    XCTAssertEqual(result.status, .incomplete)
    SharedCaptureStore.egressKeychainReadOverride = nil
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, keychainBefore)

    // A same-generation ON with another version is not this operation's.
    let foreign = SharedCaptureStore.CloudEgressRecord(state: "ON", transitionGeneration: 3, reservedVersion: 9)
    let foreignMap = SharedCaptureStore.CloudEgressMap(
      owners: [try SharedCaptureStore.debugOwnerHash(ownerA): foreign])
    try JSONEncoder().encode(foreignMap).write(to: egressFileURL)
    result = try restrict(ownerA, op)
    XCTAssertEqual(layerOutcomes(result.egress)["file"], .notOurs)
    XCTAssertEqual(result.status, .incomplete)
  }

  // 12: failed / silently dropped compensation writes are reported per layer.
  func testRestrictWriteFailureIsReportedAndBarrierRetained() throws {
    for kind in [SharedCaptureStore.LayerWriteFault.fail, .silentDrop] {
      resetCapSeams()
      defer { resetCapSeams() }
      let (id, _) = try stampedAllowedItem()
      let op = try begin(ownerA, 1, 2)
      XCTAssertEqual(try writeOn(ownerA, op).status, .done)
      fault("egress", "keychain", kind)
      let result = try restrict(ownerA, op)
      XCTAssertEqual(result.status, .incomplete)
      XCTAssertEqual(layerOutcomes(result.egress),
                     ["file": .restricted, "keychain": kind == .fail ? .writeFailed : .mismatch])
      XCTAssertEqual(try inspect(ownerA).status, .pending)
      XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    }
  }

  // 13: an old operation can neither compensate, write nor complete a newer one.
  func testOldOperationCannotTouchNewerOperation() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let old = try begin(ownerA, 1, 2)
    XCTAssertEqual(try finish(ownerA, old, abandon: true).status, .done)
    let newer = try begin(ownerA, 2, 3)
    XCTAssertEqual(newer.status, .done)
    XCTAssertNotEqual(newer.operationId, old.operationId)
    XCTAssertEqual(try restrict(ownerA, old).status, .conflict)
    XCTAssertEqual(try writeOn(ownerA, old).status, .conflict)
    XCTAssertEqual(try finish(ownerA, old).status, .conflict)
    XCTAssertEqual(try finish(ownerA, old, abandon: true).status, .conflict)
    let b = try bound(newer)
    XCTAssertEqual(try SharedCaptureStore.finishCloudEgressEnable(
      ownerUid: ownerA, operationId: b.id, transitionGeneration: 9, reservedVersion: 3,
      ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch,
      abandon: true).status, .conflict, "right id, wrong binding")
    XCTAssertEqual(try inspect(ownerA).operationId, newer.operationId)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
  }

  // 14: complete needs verified ON in BOTH layers and lifts only that barrier.
  func testCompleteNeedsVerifiedOnAndLiftsOnlyItsOwnBarrier() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    // B's barrier first (B must be the committed owner to begin), then A, the
    // committed owner that stays live for the rest of the test.
    let b = try begin(ownerB, 1, 2)
    let (id, _) = try stampedAllowedItem()
    let a = try begin(ownerA, 1, 2)
    XCTAssertEqual(try finish(ownerA, a).status, .incomplete, "no ON written yet")
    XCTAssertEqual(try writeOn(ownerA, a).status, .done)
    try setEgress(keychain: []) // ON in one layer only
    XCTAssertEqual(try finish(ownerA, a).status, .incomplete)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    // A forged STRIPPED (legacy, unbound) ON in both layers is not the operation's
    // exact bound ON (N-R2): completion refuses and the barrier stays.
    try setEgress(file: [(ownerA, "ON", 1)])
    try setEgress(keychain: [(ownerA, "ON", 1)])
    XCTAssertEqual(try finish(ownerA, a).status, .incomplete)
    XCTAssertEqual(try inspect(ownerA).status, .pending)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
    // Restore the exact bound ON in both layers, then complete.
    try putEgress(file: [try SharedCaptureStore.debugOwnerHash(ownerA): try boundOn(a)],
                  keychain: [try SharedCaptureStore.debugOwnerHash(ownerA): try boundOn(a)])
    let done = try finish(ownerA, a)
    XCTAssertEqual(done.status, .done)
    XCTAssertEqual(layerOutcomes(done.barrier), ["file": .cleared, "keychain": .cleared])
    XCTAssertEqual(try inspect(ownerA).status, .noBarrier)
    XCTAssertEqual(try inspect(ownerB).status, .pending, "B's barrier is untouched")
    XCTAssertEqual(try inspect(ownerB).operationId, b.operationId)
    if case .allowed = SharedCaptureStore.authorizeUpload(payloadID: id) {} else {
      XCTFail("A is admitted once its own operation completed; B's pending denies only B")
    }
    XCTAssertEqual(try finish(ownerB, b, abandon: true).status, .done)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: pendingKC).status, errSecItemNotFound)
    // A second complete is not success: the barrier is gone.
    XCTAssertEqual(try finish(ownerA, a).status, .noBarrier)
  }

  // 15: a partial clear is reported, keeps denying, and a retry finishes it.
  func testPartialClearIsReportedKeepsDenialAndRetryFinishes() throws {
    for kind in [SharedCaptureStore.LayerWriteFault.fail, .silentDrop] {
      resetCapSeams()
      defer { resetCapSeams() }
      let (id, _) = try stampedAllowedItem()
      let op = try begin(ownerA, 1, 2)
      XCTAssertEqual(try writeOn(ownerA, op).status, .done)
      fault("pending", "file", kind)
      let partial = try finish(ownerA, op)
      XCTAssertEqual(partial.status, .incomplete)
      XCTAssertEqual(layerOutcomes(partial.barrier),
                     ["file": kind == .fail ? .writeFailed : .mismatch, "keychain": .cleared])
      XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly,
                     "the layer that could not be cleared keeps denying")
      XCTAssertEqual(try inspect(ownerA).status, .incomplete)
      SharedCaptureStore.stateLayerWriteFault = nil
      let retry = try finish(ownerA, op)
      XCTAssertEqual(retry.status, .done)
      XCTAssertEqual(layerOutcomes(retry.barrier), ["file": .cleared, "keychain": .absent])
      if case .allowed = SharedCaptureStore.authorizeUpload(payloadID: id) {} else {
        XCTFail("admitted after the retry cleared the last layer")
      }
    }
  }

  // 16: a crash after any phase keeps denying on restart (all state is durable).
  func testCrashAtEveryPhaseKeepsDenyingAfterRestart() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 1, 2)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly, "after begin")
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly, "after writeOn")
    fault("egress", "keychain", .fail)
    XCTAssertEqual(try restrict(ownerA, op).status, .incomplete)
    SharedCaptureStore.stateLayerWriteFault = nil
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly, "after compensation")
    // "Restart": nothing is held in memory, the durable state alone is read.
    let found = try inspect(ownerA)
    XCTAssertEqual(found.status, .pending)
    XCTAssertEqual(found.operationId, op.operationId)
    XCTAssertEqual(layerOutcomes(found.barrier), ["file": .verified, "keychain": .verified])
  }

  // 17: a Remove-data barrier refuses begin / writeOn / complete but never
  // compensation or abandon (they only restrict).
  func testRemovalBarrierRefusesWideningPhasesOnly() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try begin(ownerA, 1, 2)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    _ = try SharedCaptureStore.beginRemoval(uid: ownerB)
    func assertBarrierActive(_ body: () throws -> Phase, _ what: String) {
      XCTAssertThrowsError(try body(), what) { error in
        guard case SharedCaptureStore.QueueError.barrierActive = error else {
          return XCTFail("\(what): expected barrierActive, got \(error)")
        }
      }
    }
    assertBarrierActive({ try self.begin(self.ownerA, 2, 3) }, "begin")
    assertBarrierActive({ try self.writeOn(self.ownerA, op) }, "writeOn")
    assertBarrierActive({ try self.finish(self.ownerA, op) }, "complete")
    XCTAssertEqual(try inspect(ownerA).status, .pending, "inspection stays available")
    XCTAssertEqual(try restrict(ownerA, op).status, .done)
    XCTAssertEqual(try finish(ownerA, op, abandon: true).status, .done)
  }

  // 18: a healthy legacy install is unaffected and inspection creates nothing.
  func testHealthyLegacyInstallIsUnaffectedAndInspectionIsReadOnly() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(try egressState(ownerA), .record(rec("ON", 1)))
    let inspected = try inspect(ownerA)
    XCTAssertEqual(inspected.status, .noBarrier)
    XCTAssertEqual(layerOutcomes(inspected.barrier), ["file": .absent, "keychain": .absent])
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: pendingKC).status, errSecItemNotFound)
  }

  // 19: layers that disagree about the owner's operation deny and conflict.
  func testDisagreeingLayersConflictAndDeny() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, _) = try stampedAllowedItem()
    let op = try begin(ownerA, 1, 2)
    let b = try bound(op)
    let other = try pendingJSON([(ownerA, foreignOperationId, 1, 2, b.ownerGeneration, b.ownerEpoch)])
    XCTAssertEqual(SnapshotTestKeychain.writeData(other, forKey: pendingKC), errSecSuccess)
    XCTAssertEqual(try inspect(ownerA).status, .conflict)
    XCTAssertEqual(try begin(ownerA, 1, 2).status, .conflict)
    XCTAssertEqual(try begin(ownerA, 1, 2, resume: op).status, .conflict)
    XCTAssertEqual(try writeOn(ownerA, op).status, .conflict)
    XCTAssertEqual(try finish(ownerA, op).status, .conflict)
    XCTAssertEqual(try restrict(ownerA, op).status, .conflict)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: id), .localOnly)
  }

  // 20: each layer keeps ITS OWN other-owner entries exactly. They are never
  // merged or copied across layers, and conflicting maps stay conflicting.
  func testOtherOwnersEntriesArePreservedExactlyPerLayer() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let bHash = try SharedCaptureStore.debugOwnerHash(ownerB)
    let aHash = try SharedCaptureStore.debugOwnerHash(ownerA)
    let idB1 = String(repeating: "b1", count: 16)
    let idB2 = String(repeating: "b2", count: 16)
    try ensureOwner(ownerA)
    let a = try XCTUnwrap(try SharedCaptureStore.activeOwner())
    let epoch = try SharedCaptureStore.ownerEpoch()

    // B only in the file layer; the keychain layer has no entry at all.
    try pendingJSON([(ownerB, idB1, 1, 2, 7, 0)]).write(to: pendingFileURL)
    let first = try begin(ownerA, 1, 2)
    XCTAssertEqual(first.status, .done)
    XCTAssertEqual(try pendingMap(file: true)?.owners.keys.sorted(), [aHash, bHash].sorted())
    XCTAssertEqual(try pendingMap(file: false)?.owners.keys.sorted(), [aHash],
                   "B's file-only entry was NOT copied into the keychain layer")
    XCTAssertEqual(try pendingMap(file: true)?.owners[bHash]?.operationId, idB1)
    XCTAssertEqual(first.ownerGeneration, a.generation)
    XCTAssertEqual(first.ownerEpoch, epoch)
    XCTAssertEqual(try finish(ownerA, first, abandon: true).status, .done)

    // Conflicting B entries in the two layers: each stays exactly as it was.
    try pendingJSON([(ownerB, idB1, 1, 2, 7, 0)]).write(to: pendingFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(
      try pendingJSON([(ownerB, idB2, 5, 6, 9, 3)]), forKey: pendingKC), errSecSuccess)
    let second = try begin(ownerA, 1, 2)
    XCTAssertEqual(second.status, .done)
    XCTAssertEqual(try pendingMap(file: true)?.owners[bHash]?.operationId, idB1)
    XCTAssertEqual(try pendingMap(file: false)?.owners[bHash]?.operationId, idB2)
    XCTAssertEqual(try pendingMap(file: true)?.owners[bHash]?.transitionGeneration, 1)
    XCTAssertEqual(try pendingMap(file: false)?.owners[bHash]?.transitionGeneration, 5)
    // Clearing A removes only A from each layer and leaves B exactly as found.
    XCTAssertEqual(try finish(ownerA, second, abandon: true).status, .done)
    XCTAssertEqual(try pendingMap(file: true)?.owners.keys.sorted(), [bHash])
    XCTAssertEqual(try pendingMap(file: false)?.owners.keys.sorted(), [bHash])
    XCTAssertEqual(try pendingMap(file: true)?.owners[bHash]?.operationId, idB1)
    XCTAssertEqual(try pendingMap(file: false)?.owners[bHash]?.operationId, idB2)
  }

  // 21: ONE unreadable pending layer can hide another owner's barrier or a newer
  // operation, so nothing is written to EITHER layer (no reconstruction).
  func testSingleUnreadablePendingLayerHidesOwnerAndBlocksEveryWrite() throws {
    for unreadableFile in [true, false] {
      resetCapSeams()
      defer { resetCapSeams() }
      // B's barrier lives in both layers; A then tries to begin.
      let b = try begin(ownerB, 1, 2)
      XCTAssertEqual(b.status, .done)
      try ensureOwner(ownerA)
      let garbage = Data([0x00, 0xFF, 0x7B])
      let hiddenFile = rawPending(file: true)
      let hiddenKeychain = rawPending(file: false)
      if unreadableFile {
        try garbage.write(to: pendingFileURL)
      } else {
        SharedCaptureStore.pendingKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
      }
      let blocked = try begin(ownerA, 1, 2)
      XCTAssertEqual(blocked.status, .uncertain, "unreadableFile=\(unreadableFile)")
      XCTAssertNil(blocked.operationId, "no operation was created")
      if unreadableFile {
        XCTAssertEqual(rawPending(file: true), garbage)
        XCTAssertEqual(rawPending(file: false), hiddenKeychain)
      } else {
        XCTAssertEqual(rawPending(file: true), hiddenFile)
        SharedCaptureStore.pendingKeychainReadOverride = nil
        XCTAssertEqual(rawPending(file: false), hiddenKeychain)
      }
      // An explicit resume of a real operation cannot repair through an unreadable layer.
      let epoch = try XCTUnwrap(b.ownerEpoch)
      if unreadableFile { try garbage.write(to: pendingFileURL) }
      else { SharedCaptureStore.pendingKeychainReadOverride = { (errSecInteractionNotAllowed, nil) } }
      try ensureOwner(ownerB)
      let resumed = try SharedCaptureStore.beginCloudEgressEnable(
        ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2,
        resumeOperationId: b.operationId, resumeOwnerEpoch: epoch)
      XCTAssertEqual(resumed.status, .uncertain)
      SharedCaptureStore.pendingKeychainReadOverride = nil
      XCTAssertEqual(rawPending(file: false), hiddenKeychain)
      XCTAssertEqual(rawPending(file: true), unreadableFile ? garbage : hiddenFile)
    }
  }

  // 22: compensation modifies egress only for an operation the barrier PROVES.
  func testRestrictWritesNothingWithoutAProvenOperation() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try ensureOwner(ownerA)
    let a = try XCTUnwrap(try SharedCaptureStore.activeOwner())
    let epoch = try SharedCaptureStore.ownerEpoch()
    let op = Phase(
      operation: "begin", status: .done, operationId: foreignOperationId,
      transitionGeneration: 3, reservedVersion: 4, ownerGeneration: a.generation,
      ownerEpoch: epoch, barrier: [], egress: [])
    func putOn() throws {
      try setEgress(file: [(ownerA, "ON", 3)])
      try setEgress(keychain: [(ownerA, "ON", 3)])
    }
    func egressBytes() -> (Data?, Data?) {
      (try? Data(contentsOf: egressFileURL), SnapshotTestKeychain.read(forKey: egressKC).data)
    }
    try putOn()
    let on = egressBytes()
    // 1) No barrier at all: ON with the matching generation/version is NOT permission.
    var result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .noBarrier)
    XCTAssertEqual(egressBytes().0, on.0)
    XCTAssertEqual(egressBytes().1, on.1)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .verified, "keychain": .verified],
                   "reported, not restricted")
    // 2) An unreadable barrier layer beside a layer that holds the operation.
    let entry = try pendingJSON([(ownerA, foreignOperationId, 3, 4, a.generation, epoch)])
    XCTAssertEqual(SnapshotTestKeychain.writeData(entry, forKey: pendingKC), errSecSuccess)
    try Data([0x00, 0xFF, 0x7B]).write(to: pendingFileURL)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .uncertain)
    XCTAssertEqual(egressBytes().0, on.0)
    XCTAssertEqual(egressBytes().1, on.1)
    // 3) A different operation for the owner.
    try entry.write(to: pendingFileURL)
    let other = try pendingJSON([(ownerA, String(repeating: "cd", count: 16), 3, 4, a.generation, epoch)])
    XCTAssertEqual(SnapshotTestKeychain.writeData(other, forKey: pendingKC), errSecSuccess)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .conflict)
    XCTAssertEqual(egressBytes().0, on.0)
    XCTAssertEqual(egressBytes().1, on.1)
    // 4) Same id but another owner binding is not this operation either.
    let rebound = try pendingJSON([(ownerA, foreignOperationId, 3, 4, a.generation + 1, epoch)])
    try rebound.write(to: pendingFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(rebound, forKey: pendingKC), errSecSuccess)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .conflict)
    XCTAssertEqual(egressBytes().0, on.0)
    XCTAssertEqual(egressBytes().1, on.1)
    // 5) PER-LAYER proof, file only: the operation is exactly in the FILE barrier
    // layer and healthy-absent from the Keychain one. Only the egress FILE layer
    // may be restricted; the Keychain egress ON has no proof of its own, so it is
    // left byte-for-byte untouched, reported unresolved, and the status is
    // incomplete (the denial stays).
    try putOn()
    let onAgain = egressBytes()
    try entry.write(to: pendingFileURL)
    SnapshotTestKeychain.remove(forKey: pendingKC)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .incomplete)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .restricted, "keychain": .notOurs])
    XCTAssertNotEqual(egressBytes().0, onAgain.0, "the proven file layer was restricted")
    XCTAssertEqual(try egressRecord(file: ownerA), SharedCaptureStore.CloudEgressRecord(
      state: "OFF", transitionGeneration: 3, reservedVersion: 4))
    XCTAssertEqual(egressBytes().1, onAgain.1, "the unproven Keychain layer is byte-identical")
    XCTAssertEqual(try egressRecord(keychain: ownerA), rec("ON", 3))
    XCTAssertEqual(rawPending(file: true), entry, "the barrier is never removed or changed")
    XCTAssertNil(rawPending(file: false), "no barrier was written to the other layer")
    // 5b) The mirror: the operation only in the KEYCHAIN barrier layer.
    try putOn()
    let onMirror = egressBytes()
    try? FileManager.default.removeItem(at: pendingFileURL)
    XCTAssertEqual(SnapshotTestKeychain.writeData(entry, forKey: pendingKC), errSecSuccess)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .incomplete)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .notOurs, "keychain": .restricted])
    XCTAssertEqual(egressBytes().0, onMirror.0, "the unproven file layer is byte-identical")
    XCTAssertEqual(try egressRecord(file: ownerA), rec("ON", 3))
    XCTAssertNotEqual(egressBytes().1, onMirror.1, "the proven Keychain layer was restricted")
    XCTAssertEqual(try egressRecord(keychain: ownerA), SharedCaptureStore.CloudEgressRecord(
      state: "OFF", transitionGeneration: 3, reservedVersion: 4))
    XCTAssertEqual(rawPending(file: false), entry)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))
    // 5c) Proven in BOTH barrier layers: both egress layers restrict, and a repeat
    // is a no-write alreadyRestrictive on both.
    try putOn()
    try entry.write(to: pendingFileURL)
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(layerOutcomes(result.egress), ["file": .restricted, "keychain": .restricted])
    let restrictedBytes = egressBytes()
    result = try restrict(ownerA, op)
    XCTAssertEqual(result.status, .done)
    XCTAssertEqual(layerOutcomes(result.egress),
                   ["file": .alreadyRestrictive, "keychain": .alreadyRestrictive])
    XCTAssertEqual(egressBytes().0, restrictedBytes.0)
    XCTAssertEqual(egressBytes().1, restrictedBytes.1)
    XCTAssertEqual(rawPending(file: true), entry, "the barrier is never removed by compensation")
    XCTAssertEqual(rawPending(file: false), entry)
  }

  // 23: a queued complete (or writeOn / resume) from an older owner lifecycle can
  // neither widen nor clear after a same-UID logout and readmission.
  func testQueuedCompleteAfterSameUidReadmissionClearsNothing() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    let old = try begin(ownerA, 1, 2)
    XCTAssertEqual(try writeOn(ownerA, old).status, .done)
    let oldEpoch = try XCTUnwrap(old.ownerEpoch)
    // Logout, then the same uid is admitted again: a new epoch and generation.
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    try publish(ownerA, cloud: false, ai: false)
    let live = try XCTUnwrap(try SharedCaptureStore.activeOwner())
    XCTAssertGreaterThan(try SharedCaptureStore.ownerEpoch(), oldEpoch)
    XCTAssertNotEqual(live.generation, old.ownerGeneration)
    let barrierBefore = (rawPending(file: true), rawPending(file: false))
    let egressBefore = (try? Data(contentsOf: egressFileURL), SnapshotTestKeychain.read(forKey: egressKC).data)

    XCTAssertEqual(try finish(ownerA, old).status, .ownerMismatch, "queued complete")
    XCTAssertEqual(try writeOn(ownerA, old).status, .ownerMismatch, "queued writeOn")
    let resumed = try begin(ownerA, 1, 2, resume: old)
    XCTAssertEqual(resumed.status, .ownerMismatch, "resume of an older lifecycle")
    let fresh = try begin(ownerA, 2, 3)
    XCTAssertEqual(fresh.status, .conflict, "a fresh begin does not adopt the old operation")
    XCTAssertEqual(fresh.operationId, old.operationId)
    XCTAssertEqual(rawPending(file: true), barrierBefore.0)
    XCTAssertEqual(rawPending(file: false), barrierBefore.1, "no barrier was touched")
    XCTAssertEqual(try? Data(contentsOf: egressFileURL), egressBefore.0)
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: egressKC).data, egressBefore.1)
    XCTAssertEqual(try egressState(ownerA), .uncertain, "the owner stays denied")
    XCTAssertEqual(try inspect(ownerA).status, .pending)

    // The old operation may only be restricted and abandoned, then a new lifecycle begins.
    XCTAssertEqual(try restrict(ownerA, old).status, .done)
    XCTAssertEqual(try finish(ownerA, old, abandon: true).status, .done)
    let newer = try begin(ownerA, 2, 3)
    XCTAssertEqual(newer.status, .done)
    XCTAssertNotEqual(newer.operationId, old.operationId, "operation ids never collide or carry over")
    XCTAssertEqual(newer.ownerGeneration, live.generation)
    let newBarrier = (rawPending(file: true), rawPending(file: false))
    XCTAssertEqual(try finish(ownerA, old).status, .conflict, "old complete vs the new barrier")
    XCTAssertEqual(try finish(ownerA, old, abandon: true).status, .conflict)
    XCTAssertEqual(try restrict(ownerA, old).status, .conflict)
    XCTAssertEqual(try writeOn(ownerA, old).status, .conflict)
    XCTAssertEqual(rawPending(file: true), newBarrier.0)
    XCTAssertEqual(rawPending(file: false), newBarrier.1, "the new lifecycle's barrier is intact")
  }

  // 24: ownerless, deferred (another owner), refused (removal) and a changed
  // owner generation. The APIs never mint an owner, generation or epoch.
  func testBeginNeedsTheCommittedOwnerAndNeverMintsOne() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let epoch = try SharedCaptureStore.ownerEpoch()
    // Ownerless: no committed owner at all.
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    let ownerless = try SharedCaptureStore.beginCloudEgressEnable(
      ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    XCTAssertEqual(ownerless.status, .ownerMismatch)
    XCTAssertNil(ownerless.operationId)
    XCTAssertNil(try SharedCaptureStore.activeOwner(), "no owner was minted")
    XCTAssertEqual(try SharedCaptureStore.ownerEpoch(), epoch, "no epoch was bumped")
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))
    XCTAssertEqual(SnapshotTestKeychain.read(forKey: pendingKC).status, errSecItemNotFound)

    // Deferred: another owner is the committed one.
    try publish(ownerB, cloud: false, ai: false)
    XCTAssertEqual(try SharedCaptureStore.beginCloudEgressEnable(
      ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2).status, .ownerMismatch)
    XCTAssertEqual(try SharedCaptureStore.activeOwner()?.uid, ownerB)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingFileURL.path))

    // A changed owner generation (A -> B -> A, no epoch change) invalidates a
    // bound operation for widening phases.
    let op = try begin(ownerA, 1, 2)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    try publish(ownerB, cloud: false, ai: false)
    try publish(ownerA, cloud: false, ai: false)
    XCTAssertEqual(try SharedCaptureStore.ownerEpoch(), op.ownerEpoch)
    XCTAssertNotEqual(try SharedCaptureStore.activeOwner()?.generation, op.ownerGeneration)
    XCTAssertEqual(try finish(ownerA, op).status, .ownerMismatch, "stale owner generation")
    XCTAssertEqual(try writeOn(ownerA, op).status, .ownerMismatch)
    XCTAssertEqual(try inspect(ownerA).status, .pending)

    // Refused: a Remove-data barrier throws before anything else.
    _ = try SharedCaptureStore.beginRemoval(uid: ownerB)
    XCTAssertThrowsError(try SharedCaptureStore.beginCloudEgressEnable(
      ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)) { error in
      guard case SharedCaptureStore.QueueError.barrierActive = error else {
        return XCTFail("expected barrierActive, got \(error)")
      }
    }
  }

  // 25: a prior ON does not justify abandoning after a revoked / failed enable.
  func testAbandonWithAnOlderOnAfterRevocationKeepsTheDenial() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    // A prior legitimate ON (generation 1) in both layers.
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    let op = try begin(ownerA, 2, 3)
    XCTAssertEqual(op.status, .done)
    // The new ON lands in only one layer (the file write fails), then the
    // lifecycle is revoked and the same uid is admitted again.
    fault("egress", "file", .fail)
    XCTAssertEqual(try writeOn(ownerA, op).status, .incomplete)
    SharedCaptureStore.stateLayerWriteFault = nil
    try SharedCaptureStore.clearActiveOwner(clearHint: false)
    try publish(ownerA, cloud: false, ai: false)
    XCTAssertEqual(try finish(ownerA, op).status, .ownerMismatch, "no false completion")

    // Abandon is refused while ANY ON survives, the older one included.
    var abandoned = try finish(ownerA, op, abandon: true)
    XCTAssertEqual(abandoned.status, .incomplete)
    XCTAssertEqual(try inspect(ownerA).status, .pending, "the barrier keeps denying")
    XCTAssertEqual(try egressState(ownerA), .uncertain)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())

    // Compensation restricts only the operation's own ON; the older ON is not its.
    let restricted = try restrict(ownerA, op)
    XCTAssertEqual(restricted.status, .incomplete)
    XCTAssertEqual(layerOutcomes(restricted.egress), ["file": .notOurs, "keychain": .restricted])
    abandoned = try finish(ownerA, op, abandon: true)
    XCTAssertEqual(abandoned.status, .incomplete, "the older ON still stands in the file layer")
    XCTAssertEqual(try inspect(ownerA).status, .pending)

    // Only once the older grant is itself restricted can the barrier be lifted.
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    abandoned = try finish(ownerA, op, abandon: true)
    XCTAssertEqual(abandoned.status, .done)
    XCTAssertEqual(try inspect(ownerA).status, .noBarrier)
  }

  // The ownerless snapshot is not provably clean while a barrier stands.
  func testOwnerlessSnapshotIsUncertainWhileAnyBarrierStands() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try begin(ownerA, 1, 2)
    XCTAssertEqual(try SharedCaptureStore.cloudEgressState(forUid: ""), .uncertain)
  }

  // C.4: the durable in-flight registry. Admission registers
  // {payloadId, ownerHash, deadline = admitted_at + 8 s + 2 s}; removal clears it;
  // an entry past its deadline counts as finished.
  func testInflightRegistryRegistrationRemovalAndDeadline() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    var now = base
    SharedCaptureStore.clockOverride = { now }
    let (id, a) = try stampedAllowedItem()
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    var live = try SharedCaptureStore.inflightUploads(forUid: ownerA)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.latestDeadline, base.addingTimeInterval(10))
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerB).count, 0,
                   "scoped to the owner")
    // The registry never holds the raw uid.
    let raw = String(data: try Data(contentsOf: inflightFileURL), encoding: .utf8) ?? ""
    XCTAssertFalse(raw.contains(ownerA))
    XCTAssertTrue(raw.contains(id))

    // A retry of the same payload replaces its entry (one entry, new deadline).
    now = base.addingTimeInterval(3)
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: true))
    live = try SharedCaptureStore.inflightUploads(forUid: ownerA)
    XCTAssertEqual(live.count, 1)
    XCTAssertEqual(live.latestDeadline, base.addingTimeInterval(13))

    // Completion (success or error) removes it.
    SharedCaptureStore.removeInflightUpload(payloadID: id)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    // An entry whose process died is finished once its deadline passes.
    XCTAssertNotEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
    now = base.addingTimeInterval(3 + 9.9)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 1)
    now = base.addingTimeInterval(3 + 10.1)
    XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)

    // An unreadable registry is "unavailable" to the reader and denies admission.
    now = Date()  // real time: the corrupt file is fresh, so it is not yet replaceable
    try Data([0x00, 0xFF]).write(to: inflightFileURL)
    XCTAssertThrowsError(try SharedCaptureStore.inflightUploads(forUid: ownerA))
    XCTAssertEqual(SharedCaptureStore.admitUpload(payloadID: id), .localOnly)
  }

  // D3 (native writes): a stale-generation mirror / config / publish / egress
  // write is refused and changes nothing.
  func testStaleGenerationNativeWritesAreRefused() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let a = try publish(ownerA, cloud: true, ai: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 5, reservedVersion: 6)

    XCTAssertThrowsError(try SharedCaptureStore.setConsentMirror(
      uid: ownerA, cloud: false, ai: false, version: 9, transitionGeneration: 4)) { error in
      guard case SharedCaptureStore.QueueError.staleGeneration = error else {
        return XCTFail("expected staleGeneration, got \(error)")
      }
    }
    guard case .enqueued(let item) = put("stale 1.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)),
                   .allowed(ownerUid: ownerA, ownerGeneration: a.generation, allowAi: false),
                   "the refused stale mirror write changed nothing")

    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 9),
      expectedEpoch: try SharedCaptureStore.ownerEpoch(),
      transitionGeneration: 4))

    SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: true, installID: "keep", deviceSecret: "s",
      backendURL: "https://example.test", anonKey: "k", aiConsentGranted: false)
    XCTAssertFalse(SharedCaptureStore.setBackendConfig(
      cloudProcessingEnabled: false, installID: "stale", deviceSecret: nil,
      backendURL: nil, anonKey: nil, aiConsentGranted: false,
      ownerUid: ownerA, transitionGeneration: 4))
    XCTAssertEqual(SharedCaptureStore.backendConfig().installID, "keep")
    XCTAssertTrue(SharedCaptureStore.backendConfig().cloudProcessingEnabled)

    XCTAssertThrowsError(try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 5)) { error in
      guard case SharedCaptureStore.QueueError.staleGeneration = error else {
        return XCTFail("expected staleGeneration, got \(error)")
      }
    }
    // A new owner starts fresh: B at generation 1 is not stale against A's 5.
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerB, transitionGeneration: 1, reservedVersion: 2)
  }

  // P6: a restrictive mirror (cloud=false, ai=false) is published atomically with
  // the owner under the flock; the capture is local-only, never uploaded. A
  // publish with no authority (stale epoch / barrier) writes nothing.
  func testRestrictivePublishIsAtomicAndRefusedWithoutAuthority() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let epoch = try SharedCaptureStore.ownerEpoch()
    let a = try SharedCaptureStore.publishActiveOwner(
      uid: ownerA,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: epoch)
    XCTAssertEqual(try SharedCaptureStore.activeOwner(), a)
    guard case .enqueued(let item) = put("restrictive 1.00 SAR") else { return XCTFail("enqueue") }
    XCTAssertEqual(item.localOnly, true)
    XCTAssertEqual(SharedCaptureStore.authorizeUpload(payloadID: try XCTUnwrap(item.id)), .localOnly)

    try SharedCaptureStore.clearActiveOwner(clearHint: true)
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerB,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: epoch))
    XCTAssertNil(try SharedCaptureStore.activeOwner())
    let currentEpoch = try SharedCaptureStore.ownerEpoch()
    SharedCaptureStore.lockUnavailableOverride = true
    XCTAssertThrowsError(try SharedCaptureStore.publishActiveOwner(
      uid: ownerB,
      mirror: SharedCaptureStore.ConsentMirrorValue(cloud: false, ai: false, version: 1),
      expectedEpoch: currentEpoch), "uncertain authority (no flock) must refuse")
  }

  // C.1 + C.4 source pins for the one native network client: ownerless is
  // impossible, owner_uid/owner_generation go on EVERY schema version, and the
  // admission re-check sits between building the body and URLSession.
  func testBackendClientOwnerBindingAndAdmissionOrder() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let source = try String(
      contentsOf: root.appendingPathComponent("BankMessageShortcuts/BankMessageShortcuts.swift"))
    XCTAssertFalse(source.contains("ownerUid: String? = nil"), "an ownerless upload must not compile")
    let ownerBody = try XCTUnwrap(source.range(of: "body[\"owner_uid\"] = ownerUid"))
    let schema = try XCTUnwrap(source.range(of: "body[\"schema_version\"] = 2"))
    XCTAssertLessThan(ownerBody.lowerBound, schema.lowerBound,
                      "owner_uid is not inside the schema_version 2 branch")
    XCTAssertTrue(source.contains("body[\"owner_generation\"] = ownerGeneration"))
    // H3.1: the client holds NO admission or URLSession of its own; it calls the one
    // gated transport, which admits under the flock immediately before the request.
    XCTAssertFalse(source.contains("URLSession"), "the client must not touch URLSession")
    XCTAssertFalse(source.contains("admitUpload"), "admission lives inside the transport")
    XCTAssertEqual(source.components(separatedBy: "SharedCaptureStore.gatedUpload(").count - 1, 1,
                   "exactly one native network call site")
    XCTAssertTrue(source.contains("catch SharedCaptureStore.QueueError.egressDenied"))
    XCTAssertTrue(source.contains("throw BackendCaptureError.egressDenied"))
    let body = try XCTUnwrap(source.range(of: "urlRequest.httpBody = try JSONSerialization"))
    let call = try XCTUnwrap(source.range(of: "SharedCaptureStore.gatedUpload("))
    XCTAssertLessThan(body.lowerBound, call.lowerBound)
  }

  // MARK: H3 native transport (UNCOMPILED here: needs Xcode / a Mac)

  private func iosSource(_ relative: String) throws -> String {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    return try String(contentsOf: root.appendingPathComponent(relative))
  }

  private func gatedRequest() -> URLRequest {
    // Never sent: every test below is refused before the transport reaches the network.
    URLRequest(url: URL(string: "https://invalid.invalid/functions/v1/process-ios-sms")!)
  }

  // H3.3: the App Intent / background path is denied in DISABLING and OFF, and nothing
  // is left in the in-flight registry.
  func testGatedUploadDeniedInDisablingAndOff() async throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    for state in ["DISABLING", "OFF"] {
      try SharedCaptureStore.setCloudEgressState(
        state: state, ownerUid: ownerA,
        transitionGeneration: state == "OFF" ? 3 : 2, reservedVersion: 3)
      do {
        _ = try await SharedCaptureStore.gatedUpload(
          gatedRequest(), payloadID: id, ownerUid: ownerA, ownerGeneration: a.generation)
        XCTFail("\(state): the transport must not make a request")
      } catch SharedCaptureStore.QueueError.egressDenied {
        // expected
      }
      XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0, state)
    }
  }

  // H3.3: a stale generation / a different owner is refused and its in-flight entry is
  // removed on that exit; an unreadable egress store is refused too.
  func testGatedUploadStaleGenerationAndOwnerDenied() async throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let (id, a) = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 1, reservedVersion: 2)
    for (uid, generation) in [(ownerA, a.generation + 1), (ownerB, a.generation)] {
      do {
        _ = try await SharedCaptureStore.gatedUpload(
          gatedRequest(), payloadID: id, ownerUid: uid, ownerGeneration: generation)
        XCTFail("a stale (owner, generation) must not reach the network")
      } catch SharedCaptureStore.QueueError.egressDenied {
        // expected
      }
      XCTAssertEqual(try SharedCaptureStore.inflightUploads(forUid: ownerA).count, 0)
    }
    SharedCaptureStore.lockUnavailableOverride = true
    do {
      _ = try await SharedCaptureStore.gatedUpload(
        gatedRequest(), payloadID: id, ownerUid: ownerA, ownerGeneration: a.generation)
      XCTFail("no flock means no request")
    } catch SharedCaptureStore.QueueError.egressDenied {
      // expected
    }
  }

  // H3.1/H3.3: push registration with a stale transition generation is refused; the
  // current generation (and the generation-less legacy call) is admitted while ON.
  func testPushRegistrationStaleGenerationDenied() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try stampedAllowedItem()
    try SharedCaptureStore.setCloudEgressState(
      state: "ON", ownerUid: ownerA, transitionGeneration: 5, reservedVersion: 6)
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest())
    XCTAssertTrue(SharedCaptureStore.egressAdmitsHostRequest(transitionGeneration: 5))
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(transitionGeneration: 4), "stale")
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 6, reservedVersion: 7)
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(transitionGeneration: 6), "OFF")
  }

  // H3.1 source pin: no network use outside the transport in ANY iOS target; the
  // transport refuses redirects, is ephemeral and never waits or goes background.
  func testNoNetworkUseOutsideTheGatedTransport() throws {
    let forbidden = ["URLSession", "dataTask", "uploadTask", "downloadTask", "NWConnection",
                     "NWPathMonitor", "CFNetwork", "CFReadStream", "NSURLConnection", "WKWebView"]
    for file in ["Runner/AppDelegate.swift", "Runner/SceneDelegate.swift",
                 "Runner/NativeGlassView.swift", "Runner/SharedOfferIntentStore.swift",
                 "ShareBankMessage/ShareViewController.swift",
                 "ShareBankMessage/SharedOfferIntentStore.swift",
                 "BankMessageShortcuts/BankMessageShortcuts.swift"] {
      let source = try iosSource(file)
      for token in forbidden {
        XCTAssertFalse(source.contains(token), "\(file) uses \(token)")
      }
    }
    let store = try iosSource("Runner/SharedCaptureStore.swift")
    XCTAssertEqual(store, try iosSource("ShareBankMessage/SharedCaptureStore.swift"))
    XCTAssertEqual(store.components(separatedBy: "URLSession(configuration:").count - 1, 1)
    XCTAssertFalse(store.contains("URLSession.shared"))
    XCTAssertTrue(store.contains("URLSessionConfiguration.ephemeral"))
    XCTAssertFalse(store.contains("URLSessionConfiguration.background"))
    XCTAssertTrue(store.contains("willPerformHTTPRedirection"))
    XCTAssertTrue(store.contains("completionHandler(nil)"))
    XCTAssertTrue(store.contains("configuration.waitsForConnectivity = false"))
    let transport = try XCTUnwrap(store.range(of: "static func gatedUpload("))
    let admit = try XCTUnwrap(store.range(of: "admitUpload(payloadID: payloadID)",
                                          range: transport.upperBound..<store.endIndex))
    let send = try XCTUnwrap(store.range(of: "try await session.data(for: admitted)"))
    XCTAssertLessThan(admit.lowerBound, send.lowerBound, "admission precedes the request")
  }

  // H3.3: the extension has no network code and never references the transport; push
  // registration is reached only through the gated channel; no allowance reaches native.
  func testExtensionHasNoNetworkPushIsGatedAndAllowanceStaysInDart() throws {
    let share = try iosSource("ShareBankMessage/ShareViewController.swift")
    XCTAssertFalse(share.contains("gatedUpload"))
    XCTAssertFalse(share.contains("URLSession"))
    XCTAssertTrue(share.contains("SharedCaptureStore.enqueue("))
    let delegate = try iosSource("Runner/AppDelegate.swift")
    XCTAssertEqual(delegate.components(separatedBy: "registerForRemoteNotifications()").count - 1, 1)
    let gate = try XCTUnwrap(delegate.range(of: "egressAdmitsHostRequest("))
    let register = try XCTUnwrap(delegate.range(of: "UIApplication.shared.registerForRemoteNotifications()"))
    XCTAssertLessThan(gate.lowerBound, register.lowerBound)
    for source in [try iosSource("Runner/SharedCaptureStore.swift"), delegate] {
      XCTAssertFalse(source.lowercased().contains("allowance"), "no Dart allowance in native")
    }
    // Phase 3 background recovery: only the app (never the extension) declares
    // background modes, and only the two capture-drain tasks, each registered AND
    // submitted. The BGTask code asks the live Dart engine to drain or, with no
    // engine at all, starts ONE headless engine running ONLY the Dart
    // `captureBackgroundMain` entrypoint, torn down after Dart answered; it does
    // no networking itself and completes each task exactly once.
    for key in ["UIBackgroundModes", "BGTaskSchedulerPermittedIdentifiers"] {
      XCTAssertFalse(try iosSource("ShareBankMessage/Info.plist").contains(key))
    }
    let plistURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Runner/Info.plist")
    let plist = try XCTUnwrap(
      NSDictionary(contentsOf: plistURL) as? [String: Any])
    XCTAssertEqual(plist["UIBackgroundModes"] as? [String], ["fetch", "processing"])
    XCTAssertEqual(
      plist["BGTaskSchedulerPermittedIdentifiers"] as? [String],
      ["com.youssefsafwat.mali.capture-drain.refresh",
       "com.youssefsafwat.mali.capture-drain.processing"])
    let drain = try XCTUnwrap(delegate.range(of: "final class CaptureBackgroundDrain"))
    let drainSource = String(delegate[drain.lowerBound...])
    XCTAssertFalse(drainSource.contains("URLSession"), "no networking in the BGTask path")
    XCTAssertTrue(drainSource.contains(
      "for identifier in [Self.refreshIdentifier, Self.processingIdentifier] {"),
      "every permitted identifier has a registered handler")
    XCTAssertTrue(drainSource.contains("BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)"),
                  "fetch <=> a submitted BGAppRefreshTask")
    XCTAssertTrue(drainSource.contains("BGProcessingTaskRequest(identifier: Self.processingIdentifier)"),
                  "processing <=> a submitted BGProcessingTask")
    // The only engine: headless, one entrypoint, destroyed.
    let engine = try XCTUnwrap(delegate.range(of: "final class HeadlessCaptureEngine"))
    let engineSource = String(delegate[engine.lowerBound..<drain.lowerBound])
    XCTAssertEqual(delegate.components(separatedBy: "FlutterEngine(").count - 1, 1,
                   "exactly one engine construction in the app delegate")
    XCTAssertTrue(engineSource.contains("FlutterEngine("))
    XCTAssertTrue(engineSource.contains("static let entrypoint = \"captureBackgroundMain\""))
    XCTAssertTrue(engineSource.contains("run(withEntrypoint: Self.entrypoint)"))
    XCTAssertTrue(engineSource.contains("destroyContext()"))
    XCTAssertFalse(engineSource.contains("URLSession"))
    XCTAssertFalse(drainSource.contains("FlutterEngine("), "the task handler builds no engine itself")
    XCTAssertEqual(drainSource.components(separatedBy: "task.setTaskCompleted(").count - 1, 1,
                   "one completion site, guarded")
    XCTAssertTrue(drainSource.contains("guard !completed else { return }"))
    XCTAssertTrue(drainSource.contains("isProtectedDataAvailable"),
                  "no headless start before first unlock / while protected data is unavailable")
    // The probe that drives the handler on a simulator is DEBUG-only.
    let probe = try XCTUnwrap(drainSource.range(of: "-QirshDebugHeadlessDrain"))
    let lastIf = try XCTUnwrap(drainSource.range(of: "#if DEBUG", options: .backwards,
                                                 range: drainSource.startIndex..<probe.lowerBound))
    XCTAssertNil(drainSource.range(of: "#endif", range: lastIf.upperBound..<probe.lowerBound))
    XCTAssertFalse(delegate.contains("performFetchWithCompletionHandler"))
  }
}

/// Test-only access to the same isolated service/group as the native store.
/// Production's file-private Keychain implementation remains private.
private enum SnapshotTestKeychain {
  private static func query(_ key: String) -> [String: Any] {
    var result: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "com.youssefsafwat.mali.sharedcapture",
      kSecAttrAccount as String: key,
    ]
    if let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
       !prefix.isEmpty {
      result[kSecAttrAccessGroup as String] = "\(prefix)com.youssefsafwat.mali.shared"
    }
    return result
  }

  static func read(forKey key: String) -> (status: OSStatus, data: Data?) {
    var request = query(key)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &result)
    return (status, status == errSecSuccess ? result as? Data : nil)
  }

  @discardableResult
  static func remove(forKey key: String) -> OSStatus {
    SecItemDelete(query(key) as CFDictionary)
  }

  static func writeData(_ data: Data, forKey key: String) -> OSStatus {
    let base = query(key)
    let status = SecItemUpdate(base as CFDictionary,
      [kSecValueData as String: data] as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil)
  }
}

private final class ChannelTestMessenger: NSObject, FlutterBinaryMessenger {
  var handlers: [String: FlutterBinaryMessageHandler] = [:]
  var registrations = 0
  var sent: [(channel: String, message: Data?)] = []
  private var channels: [Int64: String] = [:]
  func send(onChannel channel: String, message: Data?) {
    sent.append((channel, message))
  }
  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    sent.append((channel, message))
    callback?(nil)
  }
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    registrations += 1
    let connection = Int64(registrations)
    channels[connection] = channel
    handlers[channel] = handler
    return connection
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    if let channel = channels.removeValue(forKey: connection) { handlers[channel] = nil }
  }
  func invoke(_ channel: String, method: String) throws -> Any? {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    var reply: Data?
    handlers[channel]?(codec.encode(FlutterMethodCall(methodName: method, arguments: nil))) {
      reply = $0
    }
    return try codec.decodeEnvelope(XCTUnwrap(reply))
  }
}

private final class ChannelTestController: FlutterViewController {
  let messages = ChannelTestMessenger()
  override var binaryMessenger: FlutterBinaryMessenger { messages }
  init(name: String) {
    super.init(project: nil, nibName: nil, bundle: nil)
  }
  required init(coder: NSCoder) { fatalError("Test controller has no storyboard") }
}

// MARK: - ASR v7.2 WP6: native expiry evidence, mutation counter, successor enable

extension RunnerTests {
  private var mutationCounter: Int {
    appGroupDefaults.integer(forKey: "capture_egress_mutation_counter_v1")
  }

  private func revokeExpiry(_ uid: String, _ op: Phase, lifecycle: Int?) throws -> Phase {
    let b = try bound(op)
    return try SharedCaptureStore.revokeCaptureAuthorizationLifetime(
      ownerUid: uid, operationId: b.id, transitionGeneration: b.generation,
      reservedVersion: b.version, ownerGeneration: b.ownerGeneration, ownerEpoch: b.ownerEpoch,
      expirySessionLifecycle: lifecycle)
  }

  /// A completed explicit enable: both layers ON, bound to the live owner.
  private func liveOn(_ uid: String) throws -> Phase {
    let op = try begin(uid, 3, 4)
    XCTAssertEqual(try writeOn(uid, op).status, .done)
    XCTAssertEqual(try finish(uid, op).status, .done)
    return op
  }

  // §7.1/§7.4: every protected write advances the counter; reads never do.
  func testAsrMutationCounterAdvancesOnProtectedWritesOnly() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    var last = mutationCounter
    func advanced(_ what: String, line: UInt = #line) {
      XCTAssertGreaterThan(mutationCounter, last, what, line: line)
      last = mutationCounter
    }
    try publish(ownerA, cloud: false); advanced("publishActiveOwner")
    try SharedCaptureStore.setConsentMirror(uid: ownerA, cloud: false, ai: false, version: 1)
    advanced("setConsentMirror")
    let op = try begin(ownerA, 3, 4); advanced("begin")
    _ = try writeOn(ownerA, op); advanced("writeOn")
    _ = try finish(ownerA, op); advanced("finish")
    _ = try SharedCaptureStore.activeOwner()
    _ = try inspect(ownerA)
    _ = try? SharedCaptureStore.cloudEgressState(forUid: ownerA)
    _ = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA)
    XCTAssertEqual(mutationCounter, last, "reads do not advance the counter")
    XCTAssertTrue(try SharedCaptureStore.confirmRecoveryEvidence(expectedCounter: last))
    _ = try revokeLifetime(ownerA, op); advanced("revoke")
    XCTAssertFalse(try SharedCaptureStore.confirmRecoveryEvidence(expectedCounter: last - 1))
    try SharedCaptureStore.clearActiveOwner(clearHint: false); advanced("clearActiveOwner")
    _ = try SharedCaptureStore.beginRemoval(uid: ownerA); advanced("beginRemoval")
    _ = try SharedCaptureStore.finishRemoval(uid: ownerA); advanced("finishRemoval")
    XCTAssertTrue(SharedCaptureStore.purgeUserOwnedState()); advanced("purgeUserOwnedState")
  }

  // §7.2/§7.3: evidence only from an agreed live ON; identical repeat is a no-op;
  // a non-expiry revoke drops it; an OFF is never upgraded.
  func testAsrExpiryRevokeMintsEvidenceOnlyFromAgreedLiveOn() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try liveOn(ownerA)
    let revoked = try revokeExpiry(ownerA, op, lifecycle: 7)
    XCTAssertEqual(revoked.status, .done)
    let evidence = try XCTUnwrap(revoked.expiryEvidence)
    XCTAssertEqual(evidence.sessionLifecycle, 7)
    XCTAssertEqual(evidence.ownerGeneration, op.ownerGeneration)
    XCTAssertEqual(evidence.ownerEpoch, op.ownerEpoch)
    XCTAssertEqual(try egressRecord(file: ownerA)?.expiryEvidence, evidence)
    XCTAssertEqual(try egressRecord(keychain: ownerA)?.expiryEvidence, evidence)
    XCTAssertEqual(revoked.mutationCounter, mutationCounter)
    let snap = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA)
    XCTAssertEqual(snap.kind, "expiryEvidence")
    XCTAssertEqual(snap.record?.expiryEvidence, evidence)
    XCTAssertEqual(snap.mutationCounter, mutationCounter)
    XCTAssertEqual(try revokeExpiry(ownerA, op, lifecycle: 7).expiryEvidence, evidence, "identical repeat")
    XCTAssertEqual(try egressRecord(file: ownerA)?.expiryEvidence, evidence)
    XCTAssertNil(try revokeExpiry(ownerA, op, lifecycle: 8).expiryEvidence,
                 "another lifecycle is not the identical repeat")
    XCTAssertNil(try egressRecord(file: ownerA)?.expiryEvidence)
    XCTAssertNil(try egressRecord(keychain: ownerA)?.expiryEvidence)
    XCTAssertEqual(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).kind, "none")
    let again = try revokeExpiry(ownerA, op, lifecycle: 7)
    XCTAssertEqual(again.status, .done)
    XCTAssertNil(again.expiryEvidence, "an OFF is never upgraded")
  }

  func testAsrExpiryRevokeWithPendingEnableOrBarrierWritesNoEvidence() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try begin(ownerA, 3, 4)
    XCTAssertEqual(try writeOn(ownerA, op).status, .done)
    let behindBarrier = try revokeExpiry(ownerA, op, lifecycle: 7)
    XCTAssertEqual(behindBarrier.status, .done)
    XCTAssertNil(behindBarrier.expiryEvidence)
    XCTAssertNil(try egressRecord(file: ownerA)?.expiryEvidence)
    resetCapSeams()
    let live = try liveOn(ownerA)
    XCTAssertNil(try revokeExpiry(ownerA, live, lifecycle: nil).expiryEvidence, "non-expiry cause")
  }

  func testAsrInvalidateExpiryEvidenceRemovesExactlyThatEvidence() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try liveOn(ownerA)
    let evidence = try XCTUnwrap(try revokeExpiry(ownerA, op, lifecycle: 2).expiryEvidence)
    let before = mutationCounter
    let other = try SharedCaptureStore.invalidateExpiryEvidence(
      ownerUid: ownerA, evidenceId: String(repeating: "a", count: 32))
    XCTAssertEqual(other.status, .done)
    XCTAssertGreaterThan(mutationCounter, before, "the counter changes in every case")
    XCTAssertEqual(try egressRecord(file: ownerA)?.expiryEvidence, evidence)
    XCTAssertEqual(try SharedCaptureStore.invalidateExpiryEvidence(
      ownerUid: ownerA, evidenceId: evidence.evidenceId).status, .done)
    XCTAssertNil(try egressRecord(file: ownerA)?.expiryEvidence)
    XCTAssertNil(try egressRecord(keychain: ownerA)?.expiryEvidence)
    XCTAssertEqual(try egressRecord(file: ownerA)?.retirement?.operationId, op.operationId,
                   "the retirement itself stays")
    XCTAssertEqual(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).kind, "none")
  }

  // Session-only refresh (Cloud OFF): the inspection carries a record only for
  // readable, agreeing layers with no pending; the restrictive getter is not
  // that proof (Astra, Cloud OFF delta).
  func testRecoveryInspectionReportsOffOnlyForReadableAgreedLayersWithoutPending() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    try publish(ownerA, cloud: false)
    try SharedCaptureStore.setCloudEgressState(
      state: "OFF", ownerUid: ownerA, transitionGeneration: 2, reservedVersion: 3)
    let agreed = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA)
    XCTAssertEqual(agreed.kind, "none")
    XCTAssertEqual(agreed.record?.state, "OFF")
    XCTAssertNotNil(agreed.ownerGeneration)

    SharedCaptureStore.egressKeychainReadOverride = { (errSecInteractionNotAllowed, nil) }
    XCTAssertNil(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).record,
                 "OFF file plus an unreadable Keychain copy")
    let on = try egressJSON([(ownerA, "ON", 2)])
    SharedCaptureStore.egressKeychainReadOverride = { (errSecSuccess, on) }
    XCTAssertNil(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).record,
                 "OFF/ON disagreement")
    SharedCaptureStore.egressKeychainReadOverride = nil
    XCTAssertEqual(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).record?.state, "OFF")

    _ = try begin(ownerA, 3, 4)
    XCTAssertNil(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).record,
                 "a native-only pending enable")
  }

  // §7.6 E2-b: the cold-start mint is bound to the inspected counter.
  func testAsrLiveOnMintRequiresTheInspectedCounter() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    _ = try liveOn(ownerA)
    let snap = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA)
    XCTAssertEqual(snap.kind, "liveOn")
    let rec = try XCTUnwrap(snap.record)
    let generation = try XCTUnwrap(snap.ownerGeneration)
    let epoch = try XCTUnwrap(snap.ownerEpoch)
    func mint(_ counter: Int) throws -> Phase {
      try SharedCaptureStore.mintExpiryEvidenceForLiveOn(
        ownerUid: ownerA, ownerGeneration: generation, ownerEpoch: epoch,
        transitionGeneration: rec.transitionGeneration, reservedVersion: rec.reservedVersion,
        sessionLifecycle: 5, expectedCounter: counter)
    }
    XCTAssertEqual(try mint(try XCTUnwrap(snap.mutationCounter) - 1).status, .conflict)
    XCTAssertEqual(try egressRecord(file: ownerA)?.state, "ON", "nothing written")
    // The refused attempt itself advanced the counter: the old inspection is spent.
    XCTAssertEqual(try mint(try XCTUnwrap(snap.mutationCounter)).status, .conflict)
    let fresh = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA)
    let minted = try mint(try XCTUnwrap(fresh.mutationCounter))
    XCTAssertEqual(minted.status, .done)
    let evidence = try XCTUnwrap(minted.expiryEvidence)
    XCTAssertEqual(evidence.sessionLifecycle, 5)
    XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
    XCTAssertEqual(try egressRecord(keychain: ownerA)?.expiryEvidence, evidence)
    XCTAssertEqual(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).kind, "expiryEvidence")
    XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
  }

  // §7.5: SE1–SE4 with receipts; a stale counter at SE4 leaves only compensation.
  func testAsrSuccessorChainBehindBarrierFinishOrRetire() throws {
    for staleFinish in [false, true] {
      resetCapSeams()
      let op = try liveOn(ownerA)
      let evidence = try XCTUnwrap(try revokeExpiry(ownerA, op, lifecycle: 9).expiryEvidence)
      let epoch = try SharedCaptureStore.ownerEpoch()
      let c0 = try XCTUnwrap(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).mutationCounter)
      let refused = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: 4, expectedEpoch: epoch, successorOf: (evidence.evidenceId, c0 - 1))
      XCTAssertEqual(refused.status, .conflict)
      XCTAssertEqual(try egressRecord(file: ownerA)?.expiryEvidence, evidence, "nothing written")
      let c0b = try XCTUnwrap(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).mutationCounter)
      let se1 = try SharedCaptureStore.publishRestrictiveCaptureOwner(
        uid: ownerA, version: 4, expectedEpoch: epoch, successorOf: (evidence.evidenceId, c0b))
      XCTAssertEqual(se1.status, .done)
      let successor = try XCTUnwrap(se1.owner)
      XCTAssertGreaterThan(successor.generation, try XCTUnwrap(op.ownerGeneration))
      XCTAssertEqual(try egressRecord(file: ownerA)?.successorOfExpiry, evidence.evidenceId)
      XCTAssertNil(try egressRecord(keychain: ownerA)?.expiryEvidence, "evidence consumed")
      XCTAssertEqual(try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerA).kind, "none")
      let se2 = try SharedCaptureStore.beginCloudEgressEnable(
        ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 4,
        successor: (evidence.evidenceId, try XCTUnwrap(se1.mutationCounter)))
      XCTAssertEqual(se2.status, .done)
      let opId = try XCTUnwrap(se2.operationId)
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
      let se3 = try SharedCaptureStore.writeCloudEgressEnableOn(
        ownerUid: ownerA, operationId: opId, transitionGeneration: 4, reservedVersion: 4,
        ownerGeneration: successor.generation, ownerEpoch: epoch,
        expectedCounter: try XCTUnwrap(se2.mutationCounter))
      XCTAssertEqual(se3.status, .done)
      XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest(), "ON stays behind the barrier")
      XCTAssertEqual(try SharedCaptureStore.inspectSuccessor(
        ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
        operationId: opId), "behindBarrier")
      let c3 = try XCTUnwrap(se3.mutationCounter)
      func complete(_ counter: Int) throws -> Phase {
        try SharedCaptureStore.finishCloudEgressEnable(
          ownerUid: ownerA, operationId: opId, transitionGeneration: 4, reservedVersion: 4,
          ownerGeneration: successor.generation, ownerEpoch: epoch, abandon: false,
          expectedCounter: counter)
      }
      if staleFinish {
        XCTAssertEqual(try complete(c3 - 1).status, .conflict)
        XCTAssertEqual(try complete(c3).status, .conflict, "the refused attempt spent c3")
        XCTAssertEqual(try SharedCaptureStore.inspectSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId), "behindBarrier")
        XCTAssertEqual(try SharedCaptureStore.retireSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation + 1, ownerEpoch: epoch,
          operationId: opId).status, .stale, "another lifetime is never touched")
        // Phase 4 B3: OFF not verified in either layer → the pending barrier stays.
        SharedCaptureStore.stateLayerWriteFault = { s, _ in s == "egress" ? .fail : .none }
        XCTAssertEqual(try SharedCaptureStore.retireSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId).status, .incomplete)
        SharedCaptureStore.stateLayerWriteFault = nil
        XCTAssertEqual(try SharedCaptureStore.inspectSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId), "behindBarrier", "G' must not be ON without its barrier")
        XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
        let retired = try SharedCaptureStore.retireSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId)
        XCTAssertEqual(retired.status, .done)
        XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
        XCTAssertEqual(try egressRecord(keychain: ownerA)?.retirement?.operationId, opId)
        XCTAssertEqual(try inspect(ownerA).barrier.map(\.outcome), [.absent, .absent])
        XCTAssertEqual(try SharedCaptureStore.inspectSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId), "other")
        XCTAssertFalse(SharedCaptureStore.egressAdmitsHostRequest())
      } else {
        XCTAssertEqual(try complete(c3).status, .done)
        XCTAssertEqual(try SharedCaptureStore.inspectSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId), "finished")
        let retired = try SharedCaptureStore.retireSuccessor(
          ownerUid: ownerA, successorGeneration: successor.generation, ownerEpoch: epoch,
          operationId: opId)
        XCTAssertEqual(retired.status, .done, "a confirmed finish followed by a loss retires G'")
        XCTAssertEqual(try egressRecord(file: ownerA)?.state, "OFF")
      }
    }
    resetCapSeams()
  }

  // SE2 refuses anything but exactly SE1's lifetime.
  func testAsrSuccessorBeginRefusesWithoutSE1Marker() throws {
    resetCapSeams()
    defer { resetCapSeams() }
    let op = try liveOn(ownerA)
    let evidence = try XCTUnwrap(try revokeExpiry(ownerA, op, lifecycle: 1).expiryEvidence)
    let counter = mutationCounter
    let refused = try SharedCaptureStore.beginCloudEgressEnable(
      ownerUid: ownerA, transitionGeneration: 4, reservedVersion: 4,
      successor: (evidence.evidenceId, counter))
    XCTAssertNotEqual(refused.status, .done, "no SE1 publication yet")
    XCTAssertEqual(try inspect(ownerA).barrier.map(\.outcome), [.absent, .absent])
  }

  // §7.4 enforcement: compile flag only on Runner, identical copies, writers only
  // reachable from the Runner channel, every writer under the counted lock.
  func testAsrCaptureStateWriterFlagAndCallSiteAudit() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let runner = try Data(contentsOf: root.appendingPathComponent("Runner/SharedCaptureStore.swift"))
    let share = try Data(contentsOf: root.appendingPathComponent("ShareBankMessage/SharedCaptureStore.swift"))
    XCTAssertEqual(runner, share, "the two physical copies must be byte-identical")
    let project = try String(contentsOf: root.appendingPathComponent("Runner.xcodeproj/project.pbxproj"))
    var runnerConfigs = 0
    var shareConfigs = 0
    for block in project.components(separatedBy: "isa = XCBuildConfiguration;").dropFirst() {
      let settings = block.components(separatedBy: "name = ").first ?? block
      if settings.contains("INFOPLIST_FILE = Runner/Info.plist;") {
        runnerConfigs += 1
        XCTAssertTrue(settings.contains("CAPTURE_STATE_WRITER"))
      } else {
        if settings.contains("INFOPLIST_FILE = ShareBankMessage/Info.plist;") { shareConfigs += 1 }
        XCTAssertFalse(settings.contains("CAPTURE_STATE_WRITER"))
      }
    }
    XCTAssertEqual(runnerConfigs, 3)
    XCTAssertEqual(shareConfigs, 3)
    // The writer set is DERIVED from the `#if CAPTURE_STATE_WRITER` regions
    // (never a hand-kept list), and every counted-lock use sits inside one.
    let store = String(decoding: runner, as: UTF8.self)
    var writers: [String] = []
    var stack: [Bool] = []
    for (index, line) in store.components(separatedBy: "\n").enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#if") { stack.append(trimmed.contains("CAPTURE_STATE_WRITER")); continue }
      if trimmed.hasPrefix("#endif") { _ = stack.popLast(); continue }
      let inWriter = stack.contains(true)
      if inWriter, let r = line.range(of: "static func ") {
        let name = line[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        writers.append(String(name))
      }
      if line.contains("withProtectedWriteLock") && !line.contains("func ") {
        XCTAssertTrue(inWriter, "counted lock outside a writer region at line \(index + 1)")
      }
    }
    XCTAssertTrue(writers.contains("retireSuccessor"))
    XCTAssertTrue(writers.contains("publishActiveOwner"))
    // No Swift source other than the store copies and the Runner channel
    // handler reaches a writer (any target, any helper file).
    let iosRoot = root
    let files = FileManager.default.enumerator(at: iosRoot, includingPropertiesForKeys: nil)!
      .compactMap { $0 as? URL }
      .filter { $0.pathExtension == "swift" }
      .filter { url in
        let p = url.path
        return !p.contains("/Pods/") && !p.contains("/Flutter/") && !p.contains("/RunnerTests/")
          && !p.contains("/build/") && url.lastPathComponent != "SharedCaptureStore.swift"
          && !p.hasSuffix("/Runner/AppDelegate.swift")
      }
    XCTAssertTrue(files.contains { $0.lastPathComponent == "ShareViewController.swift" })
    XCTAssertTrue(files.contains { $0.lastPathComponent == "BankMessageShortcuts.swift" })
    for url in files {
      let source = try String(contentsOf: url)
      for writer in writers {
        XCTAssertFalse(source.contains("SharedCaptureStore.\(writer)("), "\(url.lastPathComponent) calls \(writer)")
      }
    }
    // Every public entry point takes the counted lock (or delegates to one).
    let entryPoints = writers.filter { name in
      store.contains("  static func \(name)(") && !store.contains("private static func \(name)(")
    }
    XCTAssertFalse(entryPoints.isEmpty)
    for writer in entryPoints {
      let def = try XCTUnwrap(store.range(of: "static func \(writer)("), writer)
      let rest = store[def.upperBound...]
      let end = try XCTUnwrap(rest.range(of: "\n  }\n"), writer)
      let body = rest[..<end.lowerBound]
      XCTAssertTrue(body.contains("withProtectedWriteLock") || body.contains("publishActiveOwner("),
                    "\(writer) does not advance the mutation counter")
    }
  }
}
