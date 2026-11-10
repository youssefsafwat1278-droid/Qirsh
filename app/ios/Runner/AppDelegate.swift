import AppAuth
import AppIntents
import Flutter
import UIKit
import UserNotifications

/// The APNs host a device token belongs to, derived from the entitlement this
/// binary was ACTUALLY SIGNED WITH.
///
/// WHY NOT `#if DEBUG`.
/// It used to be `#if DEBUG ? "sandbox" : "production"`. `DEBUG` is not defined
/// in this project's Swift build conditions — `SWIFT_ACTIVE_COMPILATION_CONDITIONS`
/// is unset on Debug, Profile AND Release — so the branch was dead and every
/// build reported "production". A real iPhone proved it: a Debug build signed
/// `aps-environment: development` registered a SANDBOX token as `production`,
/// which routes `sendCapturePush` to api.push.apple.com and earns BadDeviceToken
/// on every send. Configuration names, Flutter build mode and compile flags all
/// describe INTENT; only the signed entitlement describes what Apple actually
/// issued the token for.
///
/// `SecTaskCopyValueForEntitlement` is the natural API but `SecTask` is not in
/// the public iOS SDK (no `SecTask.h` under the iPhoneOS SDK's Security
/// framework), so the App-Store-safe equivalent is the embedded provisioning
/// profile, which is the artefact that GRANTED the entitlement.
enum ApnsEnvironment {
  static let entitlementKey = "aps-environment"

  /// Pure mapping seam — the only place the vocabulary is translated.
  /// `nil` means UNRESOLVED, and callers must withhold the token.
  static func map(entitlement: String?) -> String? {
    switch entitlement {
    case "development": return "sandbox"
    case "production": return "production"
    default: return nil
    }
  }

  /// Pull `aps-environment` out of a provisioning profile's CMS blob.
  /// The payload is a plist embedded in DER, so the plist range is sliced out
  /// rather than the whole blob being parsed.
  static func entitlement(inProfile data: Data) -> String? {
    guard let raw = String(data: data, encoding: .isoLatin1),
          let start = raw.range(of: "<plist"),
          let end = raw.range(of: "</plist>"),
          let plistData = String(raw[start.lowerBound..<end.upperBound])
            .data(using: .isoLatin1),
          let plist = try? PropertyListSerialization.propertyList(
            from: plistData, options: [], format: nil) as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any]
    else { return nil }
    return entitlements[entitlementKey] as? String
  }

  /// Positive evidence that this binary came from the App Store or TestFlight.
  ///
  /// Those are the only distribution channels that legitimately ship WITHOUT an
  /// embedded provisioning profile — Apple strips it and re-signs for the
  /// production APNs environment. The receipt is the artefact that proves it:
  /// `receipt` for the App Store, `sandboxReceipt` for TestFlight (which is a
  /// StoreKit sandbox, unrelated to the APNs sandbox — a TestFlight build's
  /// pushes go to the PRODUCTION host). A development build has no receipt, so
  /// "no profile" alone can never be mistaken for "shipped by Apple".
  static func isStoreDistributed(bundle: Bundle = .main) -> Bool {
    guard let url = bundle.appStoreReceiptURL else { return false }
    let name = url.lastPathComponent
    guard name == "receipt" || name == "sandboxReceipt" else { return false }
    return FileManager.default.fileExists(atPath: url.path)
  }

  /// Pure resolution seam — both missing-profile branches are testable.
  ///
  /// `nil` means UNRESOLVED and the caller must withhold the token.
  static func resolve(profileData: Data?, isStoreDistributed: Bool) -> String? {
    guard let data = profileData else {
      // No profile. Only a real store receipt justifies "production"; anything
      // else (a stripped, corrupted or hand-assembled bundle) fails closed.
      return isStoreDistributed ? "production" : nil
    }
    return map(entitlement: entitlement(inProfile: data))
  }

  /// The environment this PROCESS was signed for, or `nil` when it cannot be
  /// established — in which case no token may be registered.
  ///
  /// Nothing here reads a configuration NAME or a compile flag. The inputs are
  /// the signed provisioning profile and the store receipt, both of which are
  /// artefacts of how the binary was actually distributed.
  static func current(bundle: Bundle = .main) -> String? {
    if let url = bundle.url(
      forResource: "embedded", withExtension: "mobileprovision") {
      // A profile that exists but cannot be READ is unresolved — never treated
      // as "absent", which would fall through to the store-receipt branch.
      guard let data = try? Data(contentsOf: url) else { return nil }
      return resolve(profileData: data, isStoreDistributed: false)
    }
    return resolve(
      profileData: nil, isStoreDistributed: isStoreDistributed(bundle: bundle))
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var captureChannel: FlutterMethodChannel?

  /// ASR §6.1: status-preserving Keychain access for the session store. Bound to
  /// a plugin registrar (not a view controller) so it exists before Dart's
  /// bootstrap reads the session, whatever the scene lifecycle is doing.
  private let sessionKeychain = SessionKeychain()

  /// The controller whose binaryMessenger [captureChannel] is bound to.
  ///
  /// WEAK on purpose, and identity-compared rather than counted. `captureChannel
  /// != nil` is not idempotency: iOS can disconnect and reconnect the scene,
  /// which builds a NEW FlutterViewController and a new messenger while this
  /// AppDelegate survives. The old channel object is still non-nil, so a
  /// nil-check would no-op and leave every native call wired to a dead
  /// messenger — silently, because sending to it neither throws nor returns.
  ///
  /// Weak also means a deallocated controller reads back as nil, which compares
  /// unequal to the current one and forces a rebind rather than pinning a dead
  /// view controller in memory.
  private weak var captureChannelController: FlutterViewController?
  private var exportProtectionChannel: FlutterMethodChannel?
  private weak var exportProtectionChannelController: FlutterViewController?
  private var nativeGlassChannel: FlutterMethodChannel?
  private weak var nativeGlassChannelController: FlutterViewController?
  private var reduceTransparencyObserver: NSObjectProtocol?
  private var deviceTimezoneChannel: FlutterMethodChannel?
  private var googleAuthorizationFlow: OIDExternalUserAgentSession?

  /// The controller [deviceTimezoneChannel] is bound to — weak, and identity
  /// compared, for the same reason as [captureChannelController]. See Audit 3A.
  private weak var deviceTimezoneChannelController: FlutterViewController?
  private var didRegisterPendingMessagesObserver = false
  private var privacySnapshotView: UIView?
  private static let apnsRegistrationFailureKey = "apns_registration_failure"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    if #available(iOS 10.0, *) {
      UNUserNotificationCenter.current().delegate = self
    }
    GeneratedPluginRegistrant.register(with: self)
    if let registrar = self.registrar(forPlugin: "QirshSessionKeychain") {
      sessionKeychain.attach(messenger: registrar.messenger())
    }
    if let registrar = self.registrar(forPlugin: "QirshGoogleAuthorization") {
      configureGoogleAuthorization(messenger: registrar.messenger())
    }
    if let registrar = self.registrar(forPlugin: "NativeGlass") {
      registrar.register(
        NativeGlassViewFactory(),
        withId: "mali_glass_native"
      )
      registrar.register(
        NativeTabBarViewFactory(messenger: registrar.messenger()),
        withId: "mali_native_tab_bar"
      )
    }
    let didFinish = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    configureNativeCaptureChannelIfNeeded()
    configureExportProtectionChannelIfNeeded()
    configureNativeGlassChannelIfNeeded()
    configureDeviceTimezoneChannelIfNeeded()
    if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
      SharedCaptureStore.enqueueNotificationRoute(userInfo: remote)
    }
    BankMessageShortcuts.updateAppShortcutParameters()
    return didFinish
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    removePrivacySnapshotView()
    configureNativeCaptureChannelIfNeeded()
    configureExportProtectionChannelIfNeeded()
    configureNativeGlassChannelIfNeeded()
    configureDeviceTimezoneChannelIfNeeded()
  }

  /// Answers the one question Dart needs before building glass surfaces:
  /// does this device have the real iOS 26 Liquid Glass material?
  ///
  /// Under the UIScene lifecycle there is no root controller during
  /// `didFinishLaunching` and `applicationDidBecomeActive` never fires, so
  /// SceneDelegate binds this from `scene(_:willConnectTo:)` with the exact
  /// controller (same pattern as the timezone channel). Without that the probe
  /// got MissingPluginException and every device fell back to Flutter glass.
  func configureNativeGlassChannelIfNeeded(controller: FlutterViewController? = nil) {
    guard let controller = controller ?? rootFlutterViewController() else {
      return
    }
    if nativeGlassChannel != nil, nativeGlassChannelController === controller {
      return
    }
    nativeGlassChannel?.setMethodCallHandler(nil)

    let channel = FlutterMethodChannel(
      name: "mali/native_glass",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(NativeGlass.isSupported)
      case "reduceTransparency":
        // Public accessibility state Flutter's MediaQuery does not carry; the
        // Dart-drawn glass tiers turn opaque with it. Native UIGlassEffect
        // views adapt to it on their own.
        result(UIAccessibility.isReduceTransparencyEnabled)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    nativeGlassChannel = channel
    nativeGlassChannelController = controller

    if reduceTransparencyObserver == nil {
      reduceTransparencyObserver = NotificationCenter.default.addObserver(
        forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        self?.nativeGlassChannel?.invokeMethod(
          "reduceTransparencyChanged",
          arguments: UIAccessibility.isReduceTransparencyEnabled
        )
      }
    }
  }

  /// The device's IANA timezone identifier, for scheduling local notifications
  /// in the user's own zone.
  ///
  /// This replaces the `flutter_timezone` package, whose public ObjC header
  /// carries a stray `#import <CoreLocation/CoreLocation.h>`. That header is
  /// pulled into Runner through GeneratedPluginRegistrant.m, which put a
  /// location-framework reference in an app that has no location feature and
  /// triggered Apple's ITMS-90683. The import is unused by the plugin (its
  /// implementation is Swift and reads the zone from Foundation), and it is
  /// still present upstream as of 5.1.0, so removing the dependency is the only
  /// way to remove the reference.
  ///
  /// `TimeZone.current` is Foundation. It reads the system zone setting and
  /// needs no CoreLocation and no authorization of any kind.
  ///
  /// LIFECYCLE: this deliberately mirrors `configureNativeCaptureChannelIfNeeded`
  /// rather than the simpler `nativeGlassChannel` shape. Dart reaches this
  /// channel from `LocalNotificationService.initialize()`, which bootstrap runs
  /// at `notifications_init` — the same pre-first-frame window in which the
  /// capture purge once got MissingPluginException. So it registers from
  /// `scene(_:willConnectTo:)` too, and it is idempotent against the CURRENT
  /// controller instead of against "a channel object exists", so a scene
  /// reconnect rebinds rather than stranding the channel on a dead messenger.
  /// A separate channel from the capture drain, but not a weaker one.
  func configureDeviceTimezoneChannelIfNeeded(controller: FlutterViewController? = nil) {
    guard let controller = controller ?? rootFlutterViewController() else {
      return
    }
    // Idempotent against the CURRENT controller, not against "a channel exists".
    if deviceTimezoneChannel != nil,
       deviceTimezoneChannelController === controller {
      return
    }
    // A different (or newly created) controller: drop the old handler before
    // rebinding, so exactly one handler is installed and the previous closure is
    // released along with the messenger it answered on.
    deviceTimezoneChannel?.setMethodCallHandler(nil)

    let channel = FlutterMethodChannel(
      name: "mali/device_timezone",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "getLocalTimezone":
        result(TimeZone.current.identifier)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    deviceTimezoneChannel = channel
    deviceTimezoneChannelController = controller
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    installPrivacySnapshotView()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    removePrivacySnapshotView()
  }

  func configureNativeCaptureChannelIfNeeded(controller: FlutterViewController? = nil) {
    guard let controller = controller ?? rootFlutterViewController() else {
      return
    }
    // Idempotent against the CURRENT controller, not against "a channel exists".
    if captureChannel != nil, captureChannelController === controller {
      return
    }
    // A different (or newly created) controller: drop the old handler before
    // rebinding, so exactly one handler is installed and the previous closure
    // is released along with the messenger it answered on.
    captureChannel?.setMethodCallHandler(nil)

    let channel = FlutterMethodChannel(
      name: "money_companion/native_capture",
      binaryMessenger: controller.binaryMessenger
    )
    // CAP-0: a queue failure (key unreadable, lock unavailable, corrupt blob)
    // reaches Dart as a FlutterError — never a crash, never an "empty queue".
    // CAP-6: a refused write carries its own code (quota_exceeded,
    // removal_in_progress, owner_changed) so Dart can tell it from a failure.
    func queueResult(_ result: FlutterResult, snapshotDiagnostic: Bool = false, _ body: () throws -> Any?) {
      do {
        result(try body())
      } catch {
        let snapshot = snapshotDiagnostic ? error as? SharedCaptureStore.SnapshotFailure : nil
        let error = snapshot?.underlying ?? error
        var code = "queue_unavailable"
        switch error as? SharedCaptureStore.QueueError {
        case .quotaExceeded?: code = "quota_exceeded"
        case .barrierActive?: code = "removal_in_progress"
        case .ownerChanged?: code = "owner_changed"
        case .staleGeneration?: code = "stale_generation"
        case .egressDenied?: code = "egress_denied"
        default: break
        }
        result(FlutterError(code: code, message: snapshot == nil ? "\(error)" : "snapshot_unavailable", details: snapshot?.details))
      }
    }
    func ownerMap(_ record: SharedCaptureStore.OwnerRecord?) -> [String: Any]? {
      record.map { ["uid": $0.uid, "uidHash": $0.uidHash, "generation": $0.generation] }
    }
    // Consent-security amendment: the structured per-layer reply of every pending-
    // enable phase. Only `status == "done"` is success; no uid/key/content in it.
    // ASR §7.2: the evidence identity only (no uid, key or content).
    func evidenceMap(_ e: SharedCaptureStore.ExpiryEvidence) -> [String: Any] {
      ["evidenceId": e.evidenceId, "ownerGeneration": e.ownerGeneration,
       "ownerEpoch": e.ownerEpoch, "sessionLifecycle": e.sessionLifecycle]
    }
    func transitionMap(_ r: SharedCaptureStore.EnableTransitionResult) -> [String: Any] {
      func layers(_ reports: [SharedCaptureStore.LayerReport]) -> [[String: Any]] {
        reports.map { report in
          var map: [String: Any] = ["layer": report.layer, "outcome": report.outcome.rawValue]
          if let state = report.state { map["state"] = state }
          if let generation = report.transitionGeneration { map["transitionGeneration"] = generation }
          if let version = report.reservedVersion { map["reservedVersion"] = version }
          if let id = report.operationId { map["operationId"] = id }
          if let generation = report.ownerGeneration { map["ownerGeneration"] = generation }
          if let epoch = report.ownerEpoch { map["ownerEpoch"] = epoch }
          return map
        }
      }
      var map: [String: Any] = [
        "contractVersion": 1, "operation": r.operation, "status": r.status.rawValue,
        "barrier": layers(r.barrier), "egress": layers(r.egress),
      ]
      if let id = r.operationId { map["operationId"] = id }
      if let generation = r.transitionGeneration { map["transitionGeneration"] = generation }
      if let version = r.reservedVersion { map["reservedVersion"] = version }
      if let generation = r.ownerGeneration { map["ownerGeneration"] = generation }
      if let epoch = r.ownerEpoch { map["ownerEpoch"] = epoch }
      if let evidence = r.expiryEvidence { map["expiryEvidence"] = evidenceMap(evidence) }
      if let counter = r.mutationCounter { map["mutationCounter"] = counter }
      return map
    }
    func barrierMap(_ barrier: SharedCaptureStore.RemovalBarrier?) -> [String: Any]? {
      barrier.map { ["nonce": $0.nonce, "uidHash": $0.uidHash, "startedAt": $0.startedAt] }
    }
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "consumePendingSharedInput":
        queueResult(result) { try SharedCaptureStore.consumePendingText() }
      case "consumePendingSharedMessages":
        queueResult(result) { try SharedCaptureStore.consumePendingPayloadsJSON() }
      case "peekPendingSharedMessages":
        // Per-item lease (MALI-012): returns the queue without deleting it;
        // Dart acks each payload after its import commits.
        queueResult(result) { try SharedCaptureStore.peekPendingPayloadsJSON() }
      case "acknowledgeSharedMessage":
        let payloadId =
          (call.arguments as? [String: Any])?["payloadId"] as? String
        if let payloadId = payloadId {
          result(SharedCaptureStore.remove(payloadID: payloadId))
        } else {
          result(false)
        }
      case "hasPendingSharedMessages":
        result(SharedCaptureStore.hasPendingMessages())
      // COUPONS Phase 5 — shared merchant links.
      //
      // A SEPARATE method reading a SEPARATE store. One method returning a
      // mixed list would put a shopping URL one missed branch away from the SMS
      // parser, which is precisely what the two-store split exists to prevent.
      case "drainOfferIntents":
        result(SharedOfferIntentStore.drain())
      case "setCaptureBackendConfig":
        guard let args = call.arguments as? [String: Any] else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected backend config arguments.",
            details: nil
          ))
          return
        }
        // P4: false means the native config write was refused (stale transition
        // generation, or it would widen while egress is denied/uncertain).
        guard SharedCaptureStore.setBackendConfig(
          cloudProcessingEnabled: args["cloudProcessingEnabled"] as? Bool ?? false,
          installID: args["installId"] as? String,
          deviceSecret: args["deviceSecret"] as? String,
          backendURL: args["backendUrl"] as? String,
          anonKey: args["anonKey"] as? String,
          aiConsentGranted: args["aiConsentGranted"] as? Bool ?? false,
          captureContractV2: args["captureContractV2"] as? Bool ?? false,
          ownerUid: args["ownerUid"] as? String,
          transitionGeneration: args["transitionGeneration"] as? Int
        ) else {
          result(FlutterError(
            code: "stale_generation",
            message: "Backend config write refused.",
            details: nil
          ))
          return
        }
        result(nil)
      case "registerForRemoteNotifications":
        // C.4 admission: no APNs registration request while egress is DISABLING,
        // OFF or uncertain. Answers "no token" exactly like an unregistered host.
        let requestedGeneration =
          (call.arguments as? [String: Any])?["transitionGeneration"] as? Int
        guard SharedCaptureStore.egressAdmitsHostRequest(
          transitionGeneration: requestedGeneration) else {
          result(nil)
          return
        }
        UIApplication.shared.registerForRemoteNotifications()
        if let info = SharedCaptureStore.apnsTokenInfo() {
          result([
            "token": info.token,
            "environment": info.environment,
          ])
        } else {
          result(nil)
        }
      case "getApnsToken":
        if let info = SharedCaptureStore.apnsTokenInfo() {
          result([
            "token": info.token,
            "environment": info.environment,
          ])
        } else {
          result(nil)
        }
      case "getApnsRegistrationFailure":
        result(UserDefaults.standard.dictionary(
          forKey: AppDelegate.apnsRegistrationFailureKey
        ))
      case "consumePendingNotificationRoutes":
        result(SharedCaptureStore.consumePendingNotificationRoutesJSON())
      case "consumePendingNotificationLogEvents":
        let arguments = call.arguments as? [String: Any]
        result(SharedCaptureStore.consumePendingNotificationLogEventsJSON(
          ownerUid: arguments?["ownerUid"] as? String,
          ownerGeneration: arguments?["ownerGeneration"] as? Int))
      case "acknowledgeNotificationLogEvent":
        guard let arguments = call.arguments as? [String: Any],
              let eventId = arguments["eventId"] as? String,
              let ownerUid = arguments["ownerUid"] as? String,
              let generation = arguments["ownerGeneration"] as? Int else {
          result(false)
          return
        }
        result(SharedCaptureStore.acknowledgeNotificationLogEvent(
          eventId: eventId, ownerUid: ownerUid, ownerGeneration: generation))
      case "reEnqueueSharedMessage":
        // Puts a drained message back after Flutter failed to process it —
        // the queue drain is destructive, so without this a single failing
        // message would silently lose the capture. notifyHost=false: waking
        // the host again immediately would loop drain → fail → re-enqueue.
        guard let args = call.arguments as? [String: Any],
              let text = args["text"] as? String, !text.isEmpty else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected the original shared message fields.",
            details: nil
          ))
          return
        }
        let receivedAt = (args["receivedAt"] as? String)
          .flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date()
        let status = SharedCaptureStore.CaptureStatus(
          rawValue: args["status"] as? String ?? ""
        ) ?? .pending
        let outcome = SharedCaptureStore.enqueue(
          text: text,
          sender: args["sender"] as? String,
          senderName: args["senderName"] as? String,
          senderID: args["senderId"] as? String,
          source: args["source"] as? String,
          receivedAt: receivedAt,
          localeIdentifier: args["locale"] as? String,
          status: status,
          failureReason: args["failureReason"] as? String,
          payloadID: args["payloadId"] as? String,
          receivedAtInferred: args["receivedAtInferred"] as? Bool,
          notifyHost: false,
          // CAP-6: the item goes back under its ORIGINAL owner or not at all.
          requireOwnerUid: args["ownerUid"] as? String,
          localOnly: args["localOnly"] as? Bool
        )
        if case let .failed(reason, kind) = outcome {
          result(FlutterError(code: kind.bridgeCode, message: reason, details: nil))
        } else {
          result(nil)
        }
      case "hasSmsPermission":
        result(false)
      case "openAppSettings":
        if let url = URL(string: UIApplication.openSettingsURLString) {
          UIApplication.shared.open(url)
        }
        result(nil)
      // ── CAP-6 owner record / unbound claim / Remove-data barrier ──────────
      // Every call runs under the queue flock inside SharedCaptureStore.
      case "publishCaptureOwner":
        // A-12-min R4: mirror + owner in one flock, compare-and-swap on the epoch.
        guard let args = call.arguments as? [String: Any],
              let uid = args["uid"] as? String, !uid.isEmpty,
              let cloud = args["cloud"] as? Bool,
              let ai = args["ai"] as? Bool,
              let version = args["version"] as? Int,
              let expectedEpoch = args["expectedEpoch"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected uid, mirror and epoch.", details: nil))
          return
        }
        queueResult(result) {
          ownerMap(try SharedCaptureStore.publishActiveOwner(
            uid: uid,
            mirror: SharedCaptureStore.ConsentMirrorValue(cloud: cloud, ai: ai, version: version),
            expectedEpoch: expectedEpoch,
            transitionGeneration: args["transitionGeneration"] as? Int))
        }
      case "repairActiveOwnerGeneration":
        // Only the generation counter is repaired, for the SAME verified owner.
        guard let args = call.arguments as? [String: Any],
              let uid = args["uid"] as? String, !uid.isEmpty else {
          result(FlutterError(code: "bad_args", message: "Expected uid.", details: nil))
          return
        }
        queueResult(result) {
          ownerMap(try SharedCaptureStore.repairActiveOwnerGeneration(uid: uid))
        }
      case "publishRestrictiveCaptureOwner":
        guard let args = call.arguments as? [String: Any],
              let uid = args["uid"] as? String, !uid.isEmpty,
              let version = args["version"] as? Int,
              let expectedEpoch = args["expectedEpoch"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected restrictive owner fields.", details: nil))
          return
        }
        queueResult(result) {
          var recover: (transitionGeneration: Int, reservedVersion: Int,
                        lifetimeOwnerGeneration: Int?, lifetimeOwnerEpoch: Int?)? = nil
          if let tg = args["expectedTransitionGeneration"] as? Int,
             let rv = args["expectedReservedVersion"] as? Int {
            recover = (tg, rv, args["expectedLifetimeOwnerGeneration"] as? Int,
                       args["expectedLifetimeOwnerEpoch"] as? Int)
          }
          var successorOf: (evidenceId: String, expectedCounter: Int)? = nil
          if let id = args["successorEvidenceId"] as? String,
             let counter = args["successorExpectedCounter"] as? Int {
            successorOf = (id, counter)
          }
          var expectedOffCopies: [SharedCaptureStore.LayerReport]? = nil
          if let raw = args["expectedOffCopies"] {
            guard let copies = raw as? [[String: Any]], copies.count == 2 else {
              throw SharedCaptureStore.QueueError.encodingFailed
            }
            expectedOffCopies = try copies.map { copy in
              guard let layer = copy["layer"] as? String,
                    let generation = copy["transitionGeneration"] as? Int, generation >= 0,
                    let reserved = copy["reservedVersion"] as? Int, reserved >= 0,
                    (copy["ownerGeneration"] == nil) == (copy["ownerEpoch"] == nil),
                    copy.keys.allSatisfy({
                      ["layer", "transitionGeneration", "reservedVersion",
                       "ownerGeneration", "ownerEpoch"].contains($0)
                    }),
                    copy["ownerGeneration"] == nil ||
                      (copy["ownerGeneration"] is Int && copy["ownerEpoch"] is Int) else {
                throw SharedCaptureStore.QueueError.encodingFailed
              }
              return SharedCaptureStore.LayerReport(layer: layer, outcome: .verified,
                state: "OFF", transitionGeneration: generation, reservedVersion: reserved,
                operationId: nil, ownerGeneration: copy["ownerGeneration"] as? Int,
                ownerEpoch: copy["ownerEpoch"] as? Int)
            }
          }
          let receipt = try SharedCaptureStore.publishRestrictiveCaptureOwner(
            uid: uid, version: version, expectedEpoch: expectedEpoch, recover: recover,
            successorOf: successorOf, expectedOffCopies: expectedOffCopies)
          var reply = SharedCaptureStore.EnableTransitionResult(
            operation: "publishRestrictive", status: receipt.status, operationId: nil,
            transitionGeneration: nil, reservedVersion: nil,
            ownerGeneration: receipt.owner?.generation, ownerEpoch: receipt.ownerEpoch,
            barrier: [
              SharedCaptureStore.LayerReport(layer: "file", outcome: .absent, state: nil,
                transitionGeneration: nil, reservedVersion: nil, operationId: nil, ownerGeneration: nil, ownerEpoch: nil),
              SharedCaptureStore.LayerReport(layer: "keychain", outcome: .absent, state: nil,
                transitionGeneration: nil, reservedVersion: nil, operationId: nil, ownerGeneration: nil, ownerEpoch: nil)
            ], egress: receipt.egress)
          reply.mutationCounter = receipt.mutationCounter
          var map = transitionMap(reply)
          if let owner = ownerMap(receipt.owner) { map["owner"] = owner }
          return map
        }
      case "captureOwnerEpoch":
        queueResult(result) { try SharedCaptureStore.ownerEpoch() }
      case "authorizeCaptureUpload":
        // A-12-min R2: the one upload gate for the app's pendingSend replay.
        // Read-only, under the flock; carries no content.
        guard let payloadId = (call.arguments as? [String: Any])?["payloadId"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected payloadId.", details: nil))
          return
        }
        queueResult(result) {
          let contractV2 = SharedCaptureStore.backendConfig().captureContractV2
          switch SharedCaptureStore.authorizeUpload(payloadID: payloadId) {
          case let .allowed(uid, generation, allowAi):
            return [
              "decision": "allowed", "ownerUid": uid, "ownerGeneration": generation,
              "allowAi": allowAi, "contractV2": contractV2,
            ]
          case .localOnly:
            return ["decision": "localOnly"]
          case .waiting:
            return ["decision": "waiting"]
          }
        }
      case "captureQueueStats":
        // WP-8 diagnostics: counts, bytes and quota state only. Content-free;
        // no per-capture list.
        queueResult(result) {
          let stats = try SharedCaptureStore.queueStats()
          return [
            "stamped": stats.stamped,
            "localOnly": stats.localOnly,
            "waiting": stats.waiting,
            "unbound": stats.unbound,
            "activeOwnerBytes": stats.activeOwnerBytes,
            "unboundBytes": stats.unboundBytes,
            "deviceBytes": stats.deviceBytes,
            "ownerQuota": stats.ownerQuota.rawValue,
            "unboundQuota": stats.unboundQuota.rawValue,
            "deviceQuota": stats.deviceQuota.rawValue,
            "migrationPending": stats.migrationPending,
          ]
        }
      case "clearCaptureOwner":
        let clearHint = (call.arguments as? [String: Any])?["clearHint"] as? Bool ?? false
        queueResult(result) {
          try SharedCaptureStore.clearActiveOwner(clearHint: clearHint)
          return true
        }
      case "getCaptureOwner":
        queueResult(result) { ownerMap(try SharedCaptureStore.activeOwner()) }
      case "setCaptureConsentMirror":
        guard let args = call.arguments as? [String: Any],
              let uid = args["uid"] as? String,
              let cloud = args["cloud"] as? Bool,
              let ai = args["ai"] as? Bool,
              let version = args["version"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected consent mirror fields.", details: nil))
          return
        }
        queueResult(result) {
          try SharedCaptureStore.setConsentMirror(
            uid: uid, cloud: cloud, ai: ai, version: version,
            transitionGeneration: args["transitionGeneration"] as? Int)
          return true
        }
      // ── C.4 / C.5 durable cloud-egress denial state (Keychain + App Group file)
      case "setCloudEgressState":
        guard let args = call.arguments as? [String: Any],
              let state = args["state"] as? String,
              let ownerUid = args["ownerUid"] as? String,
              let generation = args["transitionGeneration"] as? Int,
              let reservedVersion = args["reservedVersion"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected egress state fields.", details: nil))
          return
        }
        queueResult(result) {
          try SharedCaptureStore.setCloudEgressState(
            state: state, ownerUid: ownerUid,
            transitionGeneration: generation, reservedVersion: reservedVersion)
          return true
        }
      case "nativeInflightUploads":
        // C.4: live (before their deadline) native uploads admitted for the owner.
        guard let ownerUid = (call.arguments as? [String: Any])?["ownerUid"] as? String,
              !ownerUid.isEmpty else {
          result(FlutterError(code: "bad_args", message: "Expected ownerUid.", details: nil))
          return
        }
        queueResult(result) {
          let live = try SharedCaptureStore.inflightUploads(forUid: ownerUid)
          var map: [String: Any] = ["count": live.count]
          if let deadline = live.latestDeadline {
            map["latestDeadlineMs"] = Int((deadline.timeIntervalSince1970 * 1000).rounded(.up))
          }
          return map
        }
      case "getCloudEgressState":
        guard let ownerUid = (call.arguments as? [String: Any])?["ownerUid"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected ownerUid.", details: nil))
          return
        }
        queueResult(result, snapshotDiagnostic: true) {
          switch try SharedCaptureStore.diagnosticCloudEgressState(forUid: ownerUid) {
          case .unset:
            return ["status": "unset"]
          case let .ownerless(epoch, generation):
            return ["status": "ownerless", "contractVersion": 1,
                    "ownerEpoch": epoch, "ownerGeneration": generation]
          case .uncertain:
            // `reason` is a diagnostic constant (no uid, hash or value).
            return ["status": "uncertain", "reason": SharedCaptureStore.lastEgressUncertainReason]
          case let .record(record):
            return [
              "status": "record", "state": record.state, "ownerUid": ownerUid,
              "transitionGeneration": record.transitionGeneration,
              "reservedVersion": record.reservedVersion,
            ]
          }
        }
      // ── Pending explicit-enable barrier (phases: begin, writeOn, restrict, finish)
      case "beginCloudEgressEnable":
        guard let args = call.arguments as? [String: Any],
              let ownerUid = args["ownerUid"] as? String,
              let generation = args["transitionGeneration"] as? Int,
              let reservedVersion = args["reservedVersion"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected enable begin fields.", details: nil))
          return
        }
        // A fresh begin never adopts an existing operation. A resume names BOTH the
        // original operation id and the original owner epoch, or neither.
        let resumeId = args["resumeOperationId"] as? String
        let resumeEpoch = args["resumeOwnerEpoch"] as? Int
        guard (resumeId == nil) == (resumeEpoch == nil) else {
          result(FlutterError(code: "bad_args", message: "Expected both resume fields or none.", details: nil))
          return
        }
        // ASR §7.5 SE2: a successor begin names the consumed evidence and the
        // SE1 receipt counter, both or neither.
        let successorId = args["successorEvidenceId"] as? String
        let successorCounter = args["successorExpectedCounter"] as? Int
        guard (successorId == nil) == (successorCounter == nil) else {
          result(FlutterError(code: "bad_args", message: "Expected both successor fields or none.", details: nil))
          return
        }
        queueResult(result) {
          transitionMap(try SharedCaptureStore.beginCloudEgressEnable(
            ownerUid: ownerUid, transitionGeneration: generation, reservedVersion: reservedVersion,
            resumeOperationId: resumeId, resumeOwnerEpoch: resumeEpoch,
            successor: successorId.map { ($0, successorCounter!) }))
        }
      case "writeCloudEgressEnableOn", "restrictCloudEgressEnable", "finishCloudEgressEnable", "revokeCaptureAuthorizationLifetime":
        guard let args = call.arguments as? [String: Any],
              let ownerUid = args["ownerUid"] as? String,
              let operationId = args["operationId"] as? String,
              let generation = args["transitionGeneration"] as? Int,
              let reservedVersion = args["reservedVersion"] as? Int,
              let ownerGeneration = args["ownerGeneration"] as? Int,
              let ownerEpoch = args["ownerEpoch"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected enable phase fields.", details: nil))
          return
        }
        let phase = call.method
        let abandon = args["abandon"] as? Bool ?? false
        let expectedCounter = args["expectedCounter"] as? Int
        let expiryLifecycle = args["expirySessionLifecycle"] as? Int
        queueResult(result) {
          switch phase {
          case "writeCloudEgressEnableOn":
            return transitionMap(try SharedCaptureStore.writeCloudEgressEnableOn(
              ownerUid: ownerUid, operationId: operationId,
              transitionGeneration: generation, reservedVersion: reservedVersion,
              ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch,
              expectedCounter: expectedCounter))
          case "revokeCaptureAuthorizationLifetime":
            return transitionMap(try SharedCaptureStore.revokeCaptureAuthorizationLifetime(
              ownerUid: ownerUid, operationId: operationId,
              transitionGeneration: generation, reservedVersion: reservedVersion,
              ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch,
              expirySessionLifecycle: expiryLifecycle))
          case "restrictCloudEgressEnable":
            return transitionMap(try SharedCaptureStore.restrictCloudEgressEnable(
              ownerUid: ownerUid, operationId: operationId,
              transitionGeneration: generation, reservedVersion: reservedVersion,
              ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch))
          default:
            return transitionMap(try SharedCaptureStore.finishCloudEgressEnable(
              ownerUid: ownerUid, operationId: operationId,
              transitionGeneration: generation, reservedVersion: reservedVersion,
              ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch,
              abandon: abandon, expectedCounter: expectedCounter))
          }
        }
      case "inspectRecoveryEvidence":
        // ASR §7.4: read-only locked snapshot.
        guard let ownerUid = (call.arguments as? [String: Any])?["ownerUid"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected ownerUid.", details: nil))
          return
        }
        queueResult(result) {
          let snap = try SharedCaptureStore.inspectRecoveryEvidence(ownerUid: ownerUid)
          var map: [String: Any] = ["kind": snap.kind]
          if let g = snap.ownerGeneration { map["ownerGeneration"] = g }
          if let e = snap.ownerEpoch { map["ownerEpoch"] = e }
          if let c = snap.mutationCounter { map["mutationCounter"] = c }
          if let r = snap.record {
            var rec: [String: Any] = ["state": r.state, "transitionGeneration": r.transitionGeneration,
                                      "reservedVersion": r.reservedVersion]
            if let g = r.lifetimeOwnerGeneration { rec["lifetimeOwnerGeneration"] = g }
            if let e = r.lifetimeOwnerEpoch { rec["lifetimeOwnerEpoch"] = e }
            if let ev = r.expiryEvidence { rec["expiryEvidence"] = evidenceMap(ev) }
            map["record"] = rec
          }
          return map
        }
      case "confirmRecoveryEvidence":
        guard let counter = (call.arguments as? [String: Any])?["expectedCounter"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected expectedCounter.", details: nil))
          return
        }
        queueResult(result) { try SharedCaptureStore.confirmRecoveryEvidence(expectedCounter: counter) }
      case "mintExpiryEvidenceForLiveOn":
        guard let args = call.arguments as? [String: Any],
              let ownerUid = args["ownerUid"] as? String,
              let ownerGeneration = args["ownerGeneration"] as? Int,
              let ownerEpoch = args["ownerEpoch"] as? Int,
              let generation = args["transitionGeneration"] as? Int,
              let reservedVersion = args["reservedVersion"] as? Int,
              let lifecycle = args["sessionLifecycle"] as? Int,
              let counter = args["expectedCounter"] as? Int else {
          result(FlutterError(code: "bad_args", message: "Expected mint fields.", details: nil))
          return
        }
        queueResult(result) {
          transitionMap(try SharedCaptureStore.mintExpiryEvidenceForLiveOn(
            ownerUid: ownerUid, ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch,
            transitionGeneration: generation, reservedVersion: reservedVersion,
            sessionLifecycle: lifecycle, expectedCounter: counter))
        }
      case "invalidateExpiryEvidence":
        guard let args = call.arguments as? [String: Any],
              let ownerUid = args["ownerUid"] as? String,
              let evidenceId = args["evidenceId"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected evidence fields.", details: nil))
          return
        }
        queueResult(result) {
          transitionMap(try SharedCaptureStore.invalidateExpiryEvidence(ownerUid: ownerUid, evidenceId: evidenceId))
        }
      case "retireSuccessor", "inspectSuccessor":
        guard let args = call.arguments as? [String: Any],
              let ownerUid = args["ownerUid"] as? String,
              let generation = args["successorGeneration"] as? Int,
              let ownerEpoch = args["ownerEpoch"] as? Int,
              let operationId = args["operationId"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected successor fields.", details: nil))
          return
        }
        let retire = call.method == "retireSuccessor"
        queueResult(result) {
          retire
            ? transitionMap(try SharedCaptureStore.retireSuccessor(
                ownerUid: ownerUid, successorGeneration: generation, ownerEpoch: ownerEpoch,
                operationId: operationId)) as Any
            : try SharedCaptureStore.inspectSuccessor(
                ownerUid: ownerUid, successorGeneration: generation, ownerEpoch: ownerEpoch,
                operationId: operationId) as Any
        }
      case "getCloudEgressPending":
        guard let ownerUid = (call.arguments as? [String: Any])?["ownerUid"] as? String,
              !ownerUid.isEmpty else {
          result(FlutterError(code: "bad_args", message: "Expected ownerUid.", details: nil))
          return
        }
        queueResult(result) {
          transitionMap(try SharedCaptureStore.cloudEgressPending(forUid: ownerUid))
        }
      case "unboundCaptureSummary":
        guard let uid = (call.arguments as? [String: Any])?["uid"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected uid.", details: nil))
          return
        }
        queueResult(result) {
          let summary = try SharedCaptureStore.unboundSummary(forUid: uid)
          return ["ids": summary.ids, "senders": summary.senders, "count": summary.count]
        }
      case "claimUnboundCaptures", "discardUnboundCaptures":
        guard let args = call.arguments as? [String: Any],
              let uid = args["uid"] as? String,
              let generation = args["generation"] as? Int,
              let replicaOwnerUid = args["replicaOwnerUid"] as? String,
              let sessionUid = args["sessionUid"] as? String,
              let ids = args["ids"] as? [String] else {
          result(FlutterError(code: "bad_args", message: "Expected claim fields.", details: nil))
          return
        }
        let discard = call.method == "discardUnboundCaptures"
        queueResult(result) {
          let outcome: SharedCaptureStore.ClaimOutcome
          if discard {
            outcome = try SharedCaptureStore.discardUnbound(
              uid: uid, generation: generation, replicaOwnerUid: replicaOwnerUid,
              sessionUid: sessionUid, ids: ids)
          } else {
            outcome = try SharedCaptureStore.claimUnbound(
              uid: uid, generation: generation, replicaOwnerUid: replicaOwnerUid,
              sessionUid: sessionUid, ids: ids)
          }
          switch outcome {
          case let .applied(count): return ["status": "applied", "count": count]
          case .stale: return ["status": "stale", "count": 0]
          case .ownerMismatch: return ["status": "owner_mismatch", "count": 0]
          }
        }
      case "peekLegacyCaptureItems":
        // A6 (CAP-7): read-only listing of the unbound legacy_v2 items for the
        // fingerprint check. Content-bearing: never logged.
        queueResult(result) {
          try SharedCaptureStore.peekLegacyCaptureItems().map { item -> [String: Any] in
            var map: [String: Any] = ["id": item.id, "text": item.text]
            if let receivedAt = item.receivedAt { map["receivedAt"] = receivedAt }
            if let createdAt = item.createdAt { map["createdAt"] = createdAt }
            return map
          }
        }
      case "shortcutSetupProbeStatus":
        result(SharedCaptureStore.shortcutSetupProbeMilliseconds)
      case "setNotificationLanguage":
        SharedCaptureStore.setNotificationLanguage(
          (call.arguments as? [String: Any])?["language"] as? String ?? "en"
        )
        result(nil)
      case "setCaptureNotifyV2":
        // CAP-7: mirrors the `capture_notify_v2` flag for the App Intent.
        SharedCaptureStore.setCaptureNotifyV2(
          (call.arguments as? [String: Any])?["enabled"] as? Bool ?? false
        )
        result(nil)
      case "setHideCaptureDetails":
        SharedCaptureStore.setHideCaptureDetails(
          (call.arguments as? [String: Any])?["hide"] as? Bool ?? false
        )
        result(nil)
      case "withdrawDeliveredCaptureAlert":
        // CAP-7 correction: removes this capture's still-delivered App Intent
        // banner so a correction replaces it instead of stacking. True when one
        // was delivered. Identifiers are the App Intent's own.
        guard let payloadId = (call.arguments as? [String: Any])?["payloadId"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected payloadId.", details: nil))
          return
        }
        let center = UNUserNotificationCenter.current()
        let wanted = Set(["capture_generic_", "capture_fallback_", "capture_backend_"].map { $0 + payloadId })
        center.getDeliveredNotifications { delivered in
          let hits = delivered.map { $0.request.identifier }.filter { wanted.contains($0) }
          if !hits.isEmpty { center.removeDeliveredNotifications(withIdentifiers: hits) }
          DispatchQueue.main.async { result(!hits.isEmpty) }
        }
      case "resolveLegacyCaptureItems":
        let args = call.arguments as? [String: Any]
        queueResult(result) {
          try SharedCaptureStore.resolveLegacyItems(
            consumedIds: args?["consumedIds"] as? [String] ?? [],
            suspectedIds: args?["suspectedIds"] as? [String] ?? []
          )
        }
      case "beginCaptureRemoval":
        guard let uid = (call.arguments as? [String: Any])?["uid"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected uid.", details: nil))
          return
        }
        queueResult(result) { barrierMap(try SharedCaptureStore.beginRemoval(uid: uid)) }
      case "getCaptureRemovalBarrier":
        queueResult(result) { barrierMap(try SharedCaptureStore.removalBarrier()) }
      case "finishCaptureRemoval":
        guard let uid = (call.arguments as? [String: Any])?["uid"] as? String else {
          result(FlutterError(code: "bad_args", message: "Expected uid.", details: nil))
          return
        }
        queueResult(result) { try SharedCaptureStore.finishRemoval(uid: uid) }
      case "purgeAllCaptureState":
        // MALI-054n: wipe this identity's capture residue from the App Group.
        result(SharedCaptureStore.purgeUserOwnedState())
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    captureChannel = channel
    captureChannelController = controller
    registerPendingMessagesObserverIfNeeded()
  }

  /// MALI-065n — applies at-rest protection to a managed export temp file:
  /// NSFileProtectionComplete (unreadable while the device is locked) and
  /// exclusion from iCloud/iTunes backup. Best-effort from Dart's side.
  ///
  /// Bound by SceneDelegate with the connecting controller: under the UIScene
  /// lifecycle the AppDelegate call sites never find one, and Dart swallows
  /// the MissingPluginException, so exports silently went unprotected.
  func configureExportProtectionChannelIfNeeded(controller: FlutterViewController? = nil) {
    guard let controller = controller ?? rootFlutterViewController() else {
      return
    }
    if exportProtectionChannel != nil,
       exportProtectionChannelController === controller {
      return
    }
    exportProtectionChannel?.setMethodCallHandler(nil)

    let channel = FlutterMethodChannel(
      name: "mali/export_protection",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "protect":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(
            code: "bad_args",
            message: "Expected a file path.",
            details: nil
          ))
          return
        }
        do {
          try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: path
          )
          var url = URL(fileURLWithPath: path)
          var values = URLResourceValues()
          values.isExcludedFromBackup = true
          try url.setResourceValues(values)
          result(nil)
        } catch {
          result(FlutterError(
            code: "protect_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    exportProtectionChannel = channel
    exportProtectionChannelController = controller
  }

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    // Fail closed. A token registered against the wrong host is worse than no
    // token: the backend reports a healthy send and nothing is ever delivered.
    guard let environment = ApnsEnvironment.current() else {
      let failure: [String: Any] = [
        "message":
          "aps-environment entitlement missing or unrecognised; push token withheld",
        "domain": "qirsh.apns.environment",
        "code": -1,
        "occurredAt": ISO8601DateFormatter().string(from: Date()),
      ]
      UserDefaults.standard.set(failure, forKey: AppDelegate.apnsRegistrationFailureKey)
      captureChannel?.invokeMethod("apnsRegistrationFailed", arguments: failure)
      // Diagnostic only: no token, no entitlement value, no identifiers.
      NSLog("[Capture] APNs environment unresolved - token not registered")
      return
    }
    SharedCaptureStore.setApnsToken(token, environment: environment)
    UserDefaults.standard.removeObject(forKey: AppDelegate.apnsRegistrationFailureKey)
    captureChannel?.invokeMethod("apnsTokenUpdated", arguments: [
      "token": token,
      "environment": environment,
    ])
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    let nsError = error as NSError
    let failure: [String: Any] = [
      "message": error.localizedDescription,
      "domain": nsError.domain,
      "code": nsError.code,
      "occurredAt": ISO8601DateFormatter().string(from: Date()),
    ]
    UserDefaults.standard.set(failure, forKey: AppDelegate.apnsRegistrationFailureKey)
    captureChannel?.invokeMethod("apnsRegistrationFailed", arguments: failure)
    #if DEBUG
    print("[Capture] APNs registration failed: \(error)")
    #endif
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let userInfo = response.notification.request.content.userInfo
    if userInfo["source"] as? String == "ios_shortcut" ||
      userInfo["payloadId"] as? String != nil {
      let actionId = response.actionIdentifier
      SharedCaptureStore.enqueueNotificationRoute(
        userInfo: userInfo,
        action: QirshNotificationCategories.actionIds.contains(actionId) ? actionId : nil
      )
      captureChannel?.invokeMethod("pendingNotificationRouteAvailable", arguments: nil)
      completionHandler()
      return
    }
    super.userNotificationCenter(
      center,
      didReceive: response,
      withCompletionHandler: completionHandler
    )
  }

  private func registerPendingMessagesObserverIfNeeded() {
    guard !didRegisterPendingMessagesObserver else { return }
    didRegisterPendingMessagesObserver = true
    let observer = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(),
      observer,
      { _, observer, _, _, _ in
        guard let observer else { return }
        let appDelegate = Unmanaged<AppDelegate>
          .fromOpaque(observer)
          .takeUnretainedValue()
        DispatchQueue.main.async {
          appDelegate.captureChannel?.invokeMethod(
            "pendingSharedMessagesAvailable",
            arguments: nil
          )
        }
      },
      SharedCaptureStore.pendingMessagesNotificationName as CFString,
      nil,
      .deliverImmediately
    )
  }

  private func configureGoogleAuthorization(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "mali/google_authorization", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "authorize" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self, self.googleAuthorizationFlow == nil,
        let controller = self.rootFlutterViewController(),
        let arguments = call.arguments as? [String: String],
        let clientID = arguments["clientId"],
        clientID.hasSuffix(".apps.googleusercontent.com"),
        let nonce = arguments["nonce"], nonce.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
        let state = OIDAuthorizationRequest.generateState(),
        let verifier = OIDAuthorizationRequest.generateCodeVerifier(),
        let challenge = OIDAuthorizationRequest.codeChallengeS256(forVerifier: verifier)
      else {
        result(FlutterError(code: "google_unavailable", message: nil, details: nil))
        return
      }
      let scheme = clientID.split(separator: ".").reversed().joined(separator: ".")
      let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
      guard urlTypes?.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(scheme) == true }) == true,
        let redirect = URL(string: "\(scheme):/oauth2callback")
      else {
        result(FlutterError(code: "google_configuration", message: nil, details: nil))
        return
      }
      let config = OIDServiceConfiguration(
        authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
        tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!
      )
      // The SDK convenience initializer generates a nonce we cannot supply to
      // Supabase. Use our own challenge alongside AppAuth's PKCE and state.
      let request = OIDAuthorizationRequest(
        configuration: config, clientId: clientID, clientSecret: nil,
        scope: "openid email profile", redirectURL: redirect, responseType: OIDResponseTypeCode,
        state: state, nonce: nonce, codeVerifier: verifier, codeChallenge: challenge,
        codeChallengeMethod: OIDOAuthorizationRequestCodeChallengeMethodS256,
        additionalParameters: ["prompt": "select_account"]
      )
      self.googleAuthorizationFlow = OIDAuthState.authState(byPresenting: request, presenting: controller) { [weak self] auth, error in
        self?.googleAuthorizationFlow = nil
        guard let tokens = auth?.lastTokenResponse, let idToken = tokens.idToken,
          let accessToken = tokens.accessToken else {
          let error = error as NSError?
          if error?.domain == OIDGeneralErrorDomain && error?.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue {
            result(nil)
          } else {
            result(FlutterError(code: "google_authorization_failed", message: nil, details: nil))
          }
          return
        }
        result(["idToken": idToken, "accessToken": accessToken])
      }
    }
  }

  private func rootFlutterViewController() -> FlutterViewController? {
    if let controller = window?.rootViewController as? FlutterViewController {
      return controller
    }

    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    for scene in scenes {
      if let controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController as? FlutterViewController {
        return controller
      }
    }

    return nil
  }

  private func installPrivacySnapshotView() {
    guard privacySnapshotView == nil, let targetWindow = window else { return }
    let overlay = UIView(frame: targetWindow.bounds)
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.backgroundColor = UIColor.systemBackground

    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.text = "قرش"
    label.font = UIFont.systemFont(ofSize: 28, weight: .bold)
    label.textColor = UIColor.label
    overlay.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
    ])

    targetWindow.addSubview(overlay)
    targetWindow.bringSubviewToFront(overlay)
    privacySnapshotView = overlay
  }

  private func removePrivacySnapshotView() {
    privacySnapshotView?.removeFromSuperview()
    privacySnapshotView = nil
  }
}
