import CoreFoundation
import CryptoKit
import Darwin
import Foundation
import Security

/// Shared store between the Flutter host app, the Share Extension, and the
/// "Process Bank SMS" App Intent.
///
/// The store is intentionally App Group based so App Intents can run without
/// opening Flutter. Flutter drains the FIFO queue when the host app is active.
///
/// IMPORTANT: keep this file identical in Runner, ShareBankMessage, and
/// BankMessageShortcuts. Swift targets do not share source automatically.
enum SharedCaptureStore {
  static let appGroupIdentifier = "group.com.youssefsafwat.mali"
  static let pendingMessagesNotificationName =
    "com.youssefsafwat.mali.pendingBankMessages"

  // Queue v3 (CAP-6) is an encrypted file in the App Group container. The v2
  // UserDefaults blob is read ONLY to migrate it (§4.7) and is deliberately kept
  // afterwards: the 7-day P2 rollback grace needs it (manifest §13).
  private static let queueKey = "pending_bank_messages_v2"
  private static let queueFileName = "pending_bank_messages_v3.bin"
  private static let barrierFileName = "capture_destructive_barrier_v1.json"
  private static let migratedKey = "pending_bank_messages_v3_migrated"
  private static let ownerGenerationKey = "capture_owner_generation_v1"
  // A-12-min R4: bumped by every owner clear (sign-out, transition, removal), so
  // a publish that started before the clear can never land after it.
  private static let ownerEpochKey = "capture_owner_epoch_v1"
  /// ASR §7.1: changes on every protected native write (never `max`-merged).
  private static let egressMutationCounterKey = "capture_egress_mutation_counter_v1"
  private static let consentMirrorKey = "capture_consent_mirror_v1"
  private static let contractV2Key = "capture_contract_v2"
  private static let notifyV2Key = "capture_notify_v2"
  private static let hideCaptureDetailsKey = "capture_hide_details"
  private static let notificationLanguageKey = "capture_notification_language"
  private static let expiredUnboundCountKey = "capture_unbound_expired_count_v1"
  private static let expiredUnboundLastKey = "capture_unbound_expired_last_v1"
  private static let legacyKey = "pending_bank_message_text"
  private static let pendingCountKey = "pending_bank_messages_count"
  private static let latestPayloadIDKey = "pending_bank_messages_latest_id"
  private static let cloudProcessingEnabledKey = "cloud_processing_enabled"
  private static let deviceSecretKey = "device_secret"
  private static let backendURLKey = "backend_url"
  private static let anonKeyKey = "backend_anon_key"
  private static let installIDKey = "install_id"
  private static let aiConsentGrantedKey = "ai_consent_granted"
  private static let apnsTokenKey = "apns_token"
  private static let apnsEnvironmentKey = "apns_environment"
  private static let pendingNotificationRoutesKey = "pending_notification_routes_v1"
  private static let notificationLogEventsKey = "pending_notification_log_events_v1"
  private static let queueLockFileName = "pending_bank_messages.lock"
  // Overflow segments (2026-11-12): `seg-<16-digit seq>.bin` in this directory,
  // same AES-GCM blob format and key as the main file. Undecryptable segments
  // are moved (never deleted) to the quarantine directory.
  private static let overflowDirName = "pending_bank_messages_v3_overflow"
  private static let quarantineDirName = "pending_bank_messages_v3_quarantine"
  private static let segmentFilePrefix = "seg-"
  private static let segmentFileSuffix = ".bin"
  /// Every durable write goes to `.<final name>.tmp-<uuid>` first. A name with
  /// this marker is never a segment: a leftover one is a torn write.
  private static let tempFileMarker = ".tmp-"
  // C.4: the durable cloud-egress denial record lives in BOTH the shared
  // Keychain and an App Group file (no UserDefaults copy: it must survive a
  // purge and is only ever written under the queue flock).
  private static let egressStateKC = "cloud_egress_state_v1"
  private static let egressStateFileName = "cloud_egress_state_v1.json"
  // Consent-security amendment: the durable pending-enable barrier (see "Pending
  // enable barrier" below). Same two native layers and the same isolation rules
  // as the egress state: Keychain item + App Group file, only ever written under
  // the queue flock, deliberately NOT cleared by a sign-out purge.
  private static let pendingStateKC = "cloud_egress_pending_v1"
  private static let pendingStateFileName = "cloud_egress_pending_v1.json"
  private static let inflightFileName = "native_inflight_uploads_v1.json"

  // MALI-031 — secret material lives in the shared Keychain, never UserDefaults.
  // `deviceSecretKC` is the device auth secret; `queueEncryptionKeyKC` is the
  // AES-256 key that encrypts the raw-SMS capture queue at rest.
  private static let deviceSecretKC = "device_secret"
  private static let queueEncryptionKeyKC = "capture_queue_key_v1"
  // CAP-6 (§4.2): the active owner record and the last-admitted hint live in the
  // shared Keychain; `uidHmacKeyKC` keys the uidHash (HMAC-SHA256) so a hash is
  // meaningless off this device.
  private static let activeOwnerKC = "active_capture_owner_v1"
  private static let lastAdmittedHashKC = "last_admitted_uid_hash_v1"
  private static let uidHmacKeyKC = "capture_uid_hmac_key_v1"

  // §4.5 queue capacity. Changed with the owner's explicit approval
  // (manifest §14.10, approved 2026-11-12): the per-owner (500 items / 2 MB),
  // unbound (200 / 512 KB) and device-wide (8 MB) quotas that REFUSED a new
  // capture are gone. The queue is now the main file plus encrypted overflow
  // segments (see "Overflow segments" below), so a capture is refused only when
  // the device itself cannot take the write (ENOSPC), the key/lock/container is
  // unavailable, or one single item is larger than a whole segment. Nothing is
  // ever evicted and no older message is ever overwritten.
  //
  // One segment file (the main file included) takes at most this many items /
  // plaintext bytes before the next capture opens a new overflow segment. They
  // bound the size of every rewrite and of every decrypted blob in memory (the
  // App Intent and Share Extension run under a small memory limit); they never
  // limit how much the queue holds.
  static let segmentMaxItems = 500
  static let segmentMaxBytes = 2 * 1024 * 1024
  /// The only remaining per-capture ceiling: one item must fit in one segment.
  /// An SMS is a few hundred bytes; this rejects only pathological input (a
  /// Shortcut passing a whole document), visibly, and never evicts anything.
  static let maxItemBytes = segmentMaxBytes
  /// Unbound items expire after this long (§4.5). Stamped items never expire by age.
  static let unboundExpiryDays = 30

  static let ownerStateStamped = "stamped"
  static let ownerStateUnbound = "unbound"
  static let originLegacyV2 = "legacy_v2"
  static let reviewSuspectedAlreadyImported = "suspected_already_imported"

  private static var defaults: UserDefaults? {
    UserDefaults(suiteName: appGroupIdentifier)
  }

  private static let isoFormatter = ISO8601DateFormatter()

  enum CaptureStatus: String, Codable {
    case pending
    case pendingSend
    case sent
    case failed
  }

  /// Why a queue operation was refused. Every case means NOTHING was written:
  /// a failed operation never touches the stored queue blob (CAP-0).
  enum QueueError: Error {
    /// The App Group container or the cross-process lock inside it is unusable.
    case lockUnavailable
    /// The queue key could not be read or written (e.g.
    /// `errSecInteractionNotAllowed` before the first unlock).
    case keyUnavailable(OSStatus)
    /// A queue blob exists but cannot be decrypted/decoded (corrupt, or its key
    /// is gone). It is left in place and every write is refused until it is
    /// purged (sign-out); overwriting it would silently destroy recoverable
    /// captures.
    case unreadable
    case encodingFailed
    /// The queue file could not be written or removed.
    case storageWriteFailed
    /// The device cannot take the write (ENOSPC, "out of space"), or one single
    /// item is larger than `maxItemBytes`. There is no count/byte quota on the
    /// queue any more (2026-11-12); nothing is ever evicted.
    case quotaExceeded
    /// §4.4: a Remove-data barrier is in force; the capture is refused visibly.
    case barrierActive
    /// The owner record is not the owner the caller required (stamp race).
    case ownerChanged
    /// P4: the write carries a transition generation older than the stored one.
    case staleGeneration
    /// C.4/C.5: the cloud-egress state denies (or is uncertain for) the owner, so
    /// a write that would widen consent or egress is refused.
    case egressDenied
  }

  /// Test seams (CAP-0, CAP-6, C.5): the Keychain read of the queue key, a forced
  /// lock failure, the owner-record Keychain read, a hook invoked while the queue
  /// flock is held during stamping, the clock (30-day unbound expiry, in-flight
  /// deadlines) and the egress-state Keychain read. They exist ONLY in DEBUG
  /// builds: in a release build they are inert constants, so production code can
  /// never be steered by them.
  #if DEBUG
  static var queueKeyReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var lockUnavailableOverride = false
  static var ownerRecordReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var stampingHook: (() -> Void)?
  static var clockOverride: (() -> Date)?
  static var egressKeychainReadOverride: (() -> (status: OSStatus, data: Data?))?
  /// The Keychain read of the pending-enable barrier, and a per-layer write fault
  /// for the egress and pending stores (`store` is "egress" or "pending", `layer`
  /// is "file" or "keychain"). `.silentDrop` reports success without persisting,
  /// which only a read-back can catch.
  static var pendingKeychainReadOverride: (() -> (status: OSStatus, data: Data?))?
  static var stateLayerWriteFault: ((_ store: String, _ layer: String) -> LayerWriteFault)?
  static var beforeLifetimeFinishLock: (() -> Void)?
  /// A fault injected into the durable write of one queue file (main or
  /// overflow segment), keyed by its final file name.
  static var durableWriteFault: ((_ fileName: String) -> DurableWriteFault)?
  #else
  static let queueKeyReadOverride: (() -> (status: OSStatus, data: Data?))? = nil
  static let lockUnavailableOverride = false
  static let ownerRecordReadOverride: (() -> (status: OSStatus, data: Data?))? = nil
  static let stampingHook: (() -> Void)? = nil
  static let clockOverride: (() -> Date)? = nil
  static let egressKeychainReadOverride: (() -> (status: OSStatus, data: Data?))? = nil
  static let pendingKeychainReadOverride: (() -> (status: OSStatus, data: Data?))? = nil
  static let stateLayerWriteFault: ((_ store: String, _ layer: String) -> LayerWriteFault)? = nil
  static let beforeLifetimeFinishLock: (() -> Void)? = nil
  static let durableWriteFault: ((_ fileName: String) -> DurableWriteFault)? = nil
  #endif

  /// What a DEBUG test seam makes one layer write do. Always `.none` in release.
  enum LayerWriteFault { case none, fail, silentDrop }

  /// What a DEBUG test seam makes one durable queue-file write do (never set in
  /// release). `.fail` / `.outOfSpace` fail before anything is written;
  /// `.tornTemp` leaves a half-written temp file behind and fails, which is what
  /// a crash or power loss mid-write leaves on disk.
  enum DurableWriteFault { case none, fail, outOfSpace, tornTemp }

  struct BackendConfig {
    let cloudProcessingEnabled: Bool
    let installID: String?
    let deviceSecret: String?
    let backendURL: String?
    let anonKey: String?
    /// Mirror of the server capability `capture_contract_v2`, set by Dart.
    /// Default false: uploads stay on the legacy contract.
    var captureContractV2: Bool = false
    /// Mirror of the client flag `capture_notify_v2` (CAP-7), set by Dart.
    /// Default false: the App Intent banners behave exactly as before.
    var captureNotifyV2: Bool = false

    var canUseBackend: Bool {
      cloudProcessingEnabled &&
        !(installID?.isEmpty ?? true) &&
        !(deviceSecret?.isEmpty ?? true) &&
        !(backendURL?.isEmpty ?? true) &&
        !(anonKey?.isEmpty ?? true)
    }
  }

  struct NotificationRoutePayload: Codable {
    let payloadId: String?
    let transactionId: String?
    let smartInboxItemId: String?
    let notificationType: String?
    let source: String?
    let receivedAt: String?
    let notificationLogId: String?
    /// Banner action button tapped (nil for a plain banner tap).
    let action: String?
  }

  /// One notification lifecycle event, queued here until the host Flutter
  /// app can sync it to `notification_logs`
  /// (docs/NOTIFICATION_PIPELINE_AUDIT.md Phase 1). `notificationLogId` is
  /// the SAME id used for the whole notification's lifecycle — never
  /// regenerated between created/sent/failed/opened.
  struct NotificationLogEventPayload: Codable {
    let notificationLogId: String
    let eventType: String
    let channel: String
    let notificationType: String
    let relatedEntityType: String?
    let relatedEntityId: String?
    let errorCode: String?
    let errorReason: String?
    let occurredAt: String
    var eventId: String? = nil
    var originKind: String? = nil
    var ownerUid: String? = nil
    var ownerGeneration: Int? = nil
  }

  enum EnqueueResult {
    case enqueued(Payload)
    case duplicate(Payload)
    /// The String is an INTERNAL diagnostic (never shown to the user, never
    /// contains SMS text); the kind selects the user-facing copy.
    case failed(String, kind: FailureKind)
  }

  /// Why a capture could not be saved, as far as the user needs to know.
  /// The technical reason is logged internally only; this picks the copy.
  enum FailureKind {
    case emptyText
    case storageUnavailable
    /// The Keychain refused access because the iPhone has not been unlocked
    /// since it restarted (errSecInteractionNotAllowed).
    case deviceLocked
    /// CAP-6 refusals. They reuse the approved storage copy below: NEW
    /// user-visible copy needs approval (see the CAP-6a report for proposals).
    /// Since 2026-11-12 `quotaFull` means the DEVICE is out of space (or one
    /// item exceeds `maxItemBytes`); the queue itself has no count/byte quota.
    case quotaFull
    case removalInProgress
    case ownerChanged

    /// Method-channel error code for a refused re-enqueue.
    var bridgeCode: String {
      switch self {
      case .quotaFull: return "quota_exceeded"
      case .removalInProgress: return "removal_in_progress"
      case .ownerChanged: return "owner_changed"
      default: return "reenqueue_failed"
      }
    }

    /// User-facing copy (approved, R9). Arabic when the app's selected
    /// language is Arabic, English otherwise. Never carries technical text.
    var userMessage: String {
      let arabic = notificationLanguage == "ar"
      switch self {
      case .emptyText:
        return arabic
          ? "لم يصل نص رسالة البنك إلى قِرش. تأكد أن الاختصار يمرّر نص الرسالة، ثم حاول مرة أخرى."
          : "Qirsh didn't receive the bank message text. Make sure the Shortcut passes the message text, then try again."
      case .storageUnavailable, .quotaFull, .removalInProgress, .ownerChanged:
        return arabic
          ? "تعذر الوصول إلى بيانات قِرش الآمنة. افتح قِرش ثم حاول مرة أخرى."
          : "Qirsh couldn't access its secure storage. Open Qirsh, then try again."
      case .deviceLocked:
        return arabic
          ? "تعذر حفظ الرسالة بأمان. افتح قفل الآيفون، ثم افتح قِرش وحاول مرة أخرى."
          : "Couldn't save the message securely. Unlock your iPhone, then open Qirsh and try again."
      }
    }
  }

  /// Codable payload consumed by Flutter through the native capture channel.
  struct Payload: Codable, Equatable {
    let id: String?
    let text: String
    let sender: String?
    let senderName: String?
    let senderId: String?
    let source: String?
    let receivedAt: String?
    let locale: String?
    var status: String?
    var failureReason: String?
    var sentAt: String?
    let createdAt: String?
    /// True when the App Intent's Date Received parameter was missing and the
    /// receive time was inferred (R9). Optional so older builds still decode.
    let receivedAtInferred: Bool?

    // Queue v3 ownership fields (§4.2). All optional so a v2-shaped record
    // still decodes; Flutter ignores keys it does not know.
    /// `stamped` (bound to `ownerUid`) or `unbound`.
    var ownerState: String? = nil
    var ownerUid: String? = nil
    /// The owner-record generation this item was stamped under.
    var ownerGeneration: Int? = nil
    /// Unbound only: the last admitted uidHash (HMAC). A hint is never authority.
    var ownerHint: String? = nil
    /// When the item became unbound (the 30-day expiry runs from here).
    var unboundAt: String? = nil
    /// Non-financial annotation (`suspected_already_imported`), review only.
    var reviewState: String? = nil
    /// `legacy_v2` for items migrated from the v2 queue.
    var origin: String? = nil
    /// Bound by an explicit claim: never uploaded, never AI (§4.3).
    var localOnly: Bool? = nil
    /// Remove-data barrier tag (§4.4); swept with its barrier.
    var barrierNonce: String? = nil
  }

  /// §4.2 active owner record, held in the shared Keychain.
  struct OwnerRecord: Codable, Equatable {
    let uid: String
    let uidHash: String
    let generation: Int
  }

  /// §4.4 destructive barrier, persisted so a crashed removal resumes.
  struct RemovalBarrier: Codable, Equatable {
    let nonce: String
    let uidHash: String
    let startedAt: String
  }

  /// What the App Intent may do with a persisted capture (§4.2 pre-upload re-check).
  enum UploadDecision: Equatable {
    /// Upload as `ownerUid` under `ownerGeneration` (C.1: both are ALWAYS sent).
    /// `allowAi` is the owner's consent mirror. A missing mirror is never
    /// `allowed` (A-12-min R2): there is no install-level fallback. Egress state
    /// DISABLING / OFF / uncertain for the owner is never `allowed` (C.4).
    case allowed(ownerUid: String, ownerGeneration: Int, allowAi: Bool)
    /// Zero egress, zero AI; the capture stays on the device for a local parse.
    case localOnly
    /// Not this owner's to process now: no egress and no banner.
    case waiting
  }

  enum ClaimOutcome: Equatable {
    /// Number of items bound (claim) or deleted (discard).
    case applied(Int)
    /// Items changed since the prompt snapshot; NOTHING was mutated.
    case stale
    /// uid / owner record / generation / replica / session do not all agree;
    /// NOTHING was mutated.
    case ownerMismatch
  }

  struct UnboundSummary: Equatable {
    let ids: [String]
    let senders: [String]
    var count: Int { ids.count }
  }

  /// Adds a captured bank message to the shared queue.
  ///
  /// Duplicate prevention is scoped to pending native payloads only. Transaction
  /// duplicate detection remains in Flutter where the domain model lives.
  ///
  /// [notifyHost] is false only for Flutter's own re-enqueue of a message whose
  /// processing failed: posting the Darwin notification there would wake the
  /// host again immediately and loop drain → fail → re-enqueue → drain forever.
  ///
  /// CAP-6 (§4.2): the owner record is read, the item stamped, its size checked
  /// and the item persisted in ONE critical section under the queue flock. With
  /// no admitted owner the item is `unbound` (with the last-admitted hint unless
  /// cleared); with a Remove-data barrier in force nothing is persisted.
  /// [requireOwnerUid] (a re-enqueue) refuses when the active owner is not that uid.
  ///
  /// `.enqueued` is returned only after the item's segment file was durably
  /// written (temp file, F_FULLFSYNC, rename, directory sync). A full main file
  /// never refuses: the item goes to an encrypted overflow segment.
  @discardableResult
  static func enqueue(
    text: String,
    sender: String? = nil,
    senderName: String? = nil,
    senderID: String? = nil,
    source: String? = nil,
    receivedAt: Date = Date(),
    localeIdentifier: String? = nil,
    status: CaptureStatus = .pending,
    sentAt: Date? = nil,
    failureReason: String? = nil,
    payloadID: String? = nil,
    receivedAtInferred: Bool? = nil,
    notifyHost: Bool = true,
    requireOwnerUid: String? = nil,
    localOnly: Bool? = nil
  ) -> EnqueueResult {
    guard defaults != nil else {
      return .failed("App Group storage is unavailable.", kind: .storageUnavailable)
    }

    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return .failed("SMS text is empty.", kind: .emptyText)
    }

    let cleanSender = clean(sender)
    let cleanSenderName = clean(senderName)
    let cleanSenderID = clean(senderID)
    let cleanSource = clean(source)
    let receivedAtString = isoFormatter.string(from: receivedAt)
    let createdAtString = isoFormatter.string(from: Date())
    let locale = clean(localeIdentifier) ?? notificationLanguage
    // A caller-supplied ID (the App Intent's backend payload ID) wins so the
    // queue entry and the processed_captures row always share one identity.
    let payloadID = payloadID ?? makePayloadID(
      text: trimmed,
      sender: cleanSender,
      senderName: cleanSenderName,
      senderID: cleanSenderID,
      source: cleanSource,
      receivedAt: receivedAtString
    )
    let payload = Payload(
      id: payloadID,
      text: trimmed,
      sender: cleanSender ?? cleanSenderID ?? cleanSenderName,
      senderName: cleanSenderName,
      senderId: cleanSenderID,
      source: cleanSource,
      receivedAt: receivedAtString,
      locale: locale,
      status: status.rawValue,
      failureReason: clean(failureReason),
      sentAt: sentAt.map { isoFormatter.string(from: $0) },
      createdAt: createdAtString,
      receivedAtInferred: receivedAtInferred
    )

    do {
      return try withQueueLock {
        stampingHook?()
        guard try readBarrier() == nil else { throw QueueError.barrierActive }
        var queue = try loadQueuePruned()
        if let existing = queue.first(where: { $0.id == payloadID }) {
          if notifyHost {
            notifyPendingMessagesAvailable()
          }
          return .duplicate(existing)
        }

        var stamped = payload
        let owner = try readActiveOwner()
        if let required = requireOwnerUid, normalizedUID(required) != owner?.uid {
          throw QueueError.ownerChanged
        }
        stamped.localOnly = localOnly
        if let owner = owner {
          stamped.ownerState = ownerStateStamped
          stamped.ownerUid = owner.uid
          stamped.ownerGeneration = owner.generation
          // A-12-min R3: consent is judged at capture time. A missing mirror or
          // `cloud == false` makes the item local-only for good: it never uploads
          // and never reaches AI, even if Cloud is turned ON later. A replay-able
          // `pendingSend` becomes `sent`, so no drain replays it.
          if consentMirror(forHash: owner.uidHash)?.cloud != true {
            stamped.localOnly = true
            if stamped.status == CaptureStatus.pendingSend.rawValue {
              stamped.status = CaptureStatus.sent.rawValue
            }
          }
        } else {
          stamped.ownerState = ownerStateUnbound
          stamped.ownerHint = try readLastAdmittedHash()
          stamped.unboundAt = createdAtString
        }
        try checkQuotas(adding: stamped)
        queue.append(stamped)
        try saveQueue(queue, notifyHost: notifyHost)
        return .enqueued(stamped)
      }
    } catch {
      var kind = FailureKind.storageUnavailable
      if case let QueueError.keyUnavailable(status) = error,
         status == errSecInteractionNotAllowed {
        kind = .deviceLocked
      }
      if case QueueError.quotaExceeded = error { kind = .quotaFull }
      if case QueueError.barrierActive = error { kind = .removalInProgress }
      if case QueueError.ownerChanged = error { kind = .ownerChanged }
      return .failed("Could not save the SMS payload (\(error)).", kind: kind)
    }
  }

  /// Backward-compatible single store used by older call sites.
  @discardableResult
  static func store(text: String) -> EnqueueResult {
    enqueue(text: text, sender: nil)
  }

  /// Updates one durable queue entry without changing its stable payload ID.
  @discardableResult
  static func updateStatus(
    payloadID: String,
    status: CaptureStatus,
    failureReason: String? = nil
  ) -> Bool {
    (try? withQueueLock { () throws -> Bool in
      var queue = try loadQueue()
      guard let index = queue.firstIndex(where: { $0.id == payloadID }) else {
        return false
      }
      var item = queue[index]
      item.status = status.rawValue
      item.failureReason = clean(failureReason)
      if status == .sent { item.sentAt = isoFormatter.string(from: Date()) }
      queue[index] = item
      try saveQueue(queue, notifyHost: false)
      return true
    }) ?? false
  }

  /// Removes only a positively acknowledged payload; other queue entries stay.
  @discardableResult
  static func remove(payloadID: String) -> Bool {
    (try? withQueueLock { () throws -> Bool in
      var queue = try loadQueue()
      let before = queue.count
      queue.removeAll(where: { $0.id == payloadID })
      guard queue.count != before else { return false }
      try saveQueue(queue, notifyHost: false)
      return true
    }) ?? false
  }

  /// Returns true when the App Group queue currently has pending messages.
  /// Only the ACTIVE owner's stamped items count: unbound items and items that
  /// wait for another owner are not importable now (§4.2). Runs under the lock
  /// because loading may migrate the v2 queue.
  static func hasPendingMessages() -> Bool {
    (try? withQueueLock { () throws -> Bool in
      let queue = try loadQueue()
      if !importableItems(queue, owner: try readActiveOwner()).isEmpty { return true }
      return defaults?.string(forKey: legacyKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .isEmpty == false
    }) ?? false
  }

  /// Returns the queue as JSON WITHOUT deleting anything (per-item lease,
  /// MALI-012). Dart acknowledges each payload individually via
  /// `remove(payloadID:)` only after its import committed — a kill between
  /// drain and import re-delivers exactly the unacknowledged remainder
  /// instead of losing the whole batch.
  ///
  /// Any legacy single-text value is first folded into the durable queue (so
  /// it gains a stable payload id and the same per-item lifecycle) before the
  /// legacy key is cleared.
  static func peekPendingPayloadsJSON() throws -> String? {
    try withQueueLock {
      var queue = try loadQueuePruned()
      if foldLegacyText(into: &queue) {
        // Persist the fold first; only then clear the legacy key so the text
        // is never in neither place.
        try saveQueue(queue, notifyHost: false)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.synchronize()
      }
      guard !queue.isEmpty else {
        updatePendingMetadata([])
        return nil
      }
      let mine = importableItems(queue, owner: try readActiveOwner())
      guard !mine.isEmpty,
            let data = try? JSONEncoder().encode(mine),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      return json
    }
  }

  /// Drains the ACTIVE owner's items (a legacy value is folded in as unbound and
  /// so not returned) and returns a JSON array. Items stamped to another owner
  /// and unbound items stay queued.
  ///
  /// The items are removed only after JSON encoding succeeds so messages are not
  /// lost if encoding fails.
  static func consumePendingPayloadsJSON() throws -> String? {
    try withQueueLock {
      var queue = try loadQueuePruned()
      let folded = foldLegacyText(into: &queue)
      let owner = try readActiveOwner()
      let mine = importableItems(queue, owner: owner)
      guard !mine.isEmpty,
            let data = try? JSONEncoder().encode(mine),
            let json = String(data: data, encoding: .utf8) else {
        if folded {
          try saveQueue(queue, notifyHost: false)
          defaults?.removeObject(forKey: legacyKey)
          defaults?.synchronize()
        }
        updatePendingMetadata(queue)
        return nil
      }
      let mineIDs = Set(mine.compactMap { $0.id })
      queue.removeAll(where: { mineIDs.contains($0.id ?? "") })
      try saveQueue(queue, notifyHost: false)
      defaults?.removeObject(forKey: legacyKey)
      defaults?.synchronize()
      return json
    }
  }

  /// Backward-compatible single consume that returns the oldest text only.
  static func consumePendingText() throws -> String? {
    try withQueueLock {
      var queue = try loadQueuePruned()
      let owner = try readActiveOwner()
      guard let first = importableItems(queue, owner: owner).first else {
        if let legacy = defaults?.string(forKey: legacyKey),
           !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          defaults?.removeObject(forKey: legacyKey)
          updatePendingMetadata(queue)
          defaults?.synchronize()
          return legacy
        }
        updatePendingMetadata(queue)
        return nil
      }
      queue.removeAll(where: { $0.id == first.id })
      try saveQueue(queue)
      return first.text
    }
  }

  static func backendConfig() -> BackendConfig {
    BackendConfig(
      cloudProcessingEnabled: defaults?.bool(forKey: cloudProcessingEnabledKey) ?? false,
      installID: clean(defaults?.string(forKey: installIDKey)),
      deviceSecret: migratedDeviceSecret(),
      backendURL: clean(defaults?.string(forKey: backendURLKey)),
      anonKey: clean(defaults?.string(forKey: anonKeyKey)),
      captureContractV2: defaults?.bool(forKey: contractV2Key) ?? false,
      captureNotifyV2: defaults?.bool(forKey: notifyV2Key) ?? false
    )
  }

  /// Presentation only: does not grant capture ownership or cloud consent.
  static let shortcutSetupProbe = "QIRSH_SETUP_CHECK_V1"

  static func recordShortcutSetupProbe() {
    defaults?.set(Date().timeIntervalSince1970 * 1000, forKey: "shortcut_setup_probe_ms")
    defaults?.synchronize()
  }

  static var shortcutSetupProbeMilliseconds: Double {
    defaults?.synchronize()
    return defaults?.double(forKey: "shortcut_setup_probe_ms") ?? 0
  }

  static func setNotificationLanguage(_ code: String) {
    let language = code.lowercased().components(separatedBy: CharacterSet(charactersIn: "-_")).first == "ar" ? "ar" : "en"
    defaults?.set(language, forKey: notificationLanguageKey)
    defaults?.synchronize()
  }

  static var notificationLanguage: String {
    if let stored = defaults?.string(forKey: notificationLanguageKey) {
      return stored == "ar" ? "ar" : "en"
    }
    // Until Qirsh first mirrors its in-app language (e.g. a Shortcut that runs
    // before the app was ever opened), follow the device language.
    return Locale.preferredLanguages.first?.lowercased().hasPrefix("ar") == true ? "ar" : "en"
  }

  /// CAP-7: mirrors the `capture_notify_v2` flag for the App Intent.
  static func setCaptureNotifyV2(_ enabled: Bool) {
    defaults?.set(enabled, forKey: notifyV2Key)
    defaults?.synchronize()
  }

  /// Mirrors the user's "hide lock-screen content" preference for the App
  /// Intent's capture banners (default false, as in Flutter).
  static func setHideCaptureDetails(_ hide: Bool) {
    defaults?.set(hide, forKey: hideCaptureDetailsKey)
    defaults?.synchronize()
  }

  static var hidesCaptureDetails: Bool {
    defaults?.bool(forKey: hideCaptureDetailsKey) ?? false
  }

  /// The device secret from the shared Keychain. A legacy UserDefaults value is
  /// migrated into the Keychain once and then removed, so the secret is never
  /// left as a plaintext UserDefaults duplicate (MALI-031).
  private static func migratedDeviceSecret() -> String? {
    if let fromKeychain = clean(SharedKeychain.string(forKey: deviceSecretKC)) {
      return fromKeychain
    }
    if let legacy = clean(defaults?.string(forKey: deviceSecretKey)) {
      SharedKeychain.setString(legacy, forKey: deviceSecretKC)
      defaults?.removeObject(forKey: deviceSecretKey)
      defaults?.synchronize()
      return legacy
    }
    return nil
  }

  /// P4/C.4: runs under the queue flock. Returns false (nothing written) when
  /// [transitionGeneration] is older than the stored egress generation for
  /// [ownerUid], or when the write would WIDEN (cloud ON) while the egress state
  /// denies the owner (the explicit [ownerUid], else the active owner) or is
  /// uncertain. Restrictive writes (cloud OFF) are never refused for denial.
  @discardableResult
  static func setBackendConfig(
    cloudProcessingEnabled: Bool,
    installID: String?,
    deviceSecret: String?,
    backendURL: String?,
    anonKey: String?,
    aiConsentGranted: Bool,
    captureContractV2: Bool = false,
    ownerUid: String? = nil,
    transitionGeneration: Int? = nil
  ) -> Bool {
    let written = try? withQueueLock { () throws -> Bool in
      if let ownerUid, let transitionGeneration,
         egressGenerationIsStale(transitionGeneration, owner: ownerUid) {
        return false
      }
      if cloudProcessingEnabled || aiConsentGranted {
        let subject = try ownerUid.map(normalizedUID) ?? readActiveOwner()?.uid
        if egressDenied(forOwner: subject) { return false }
      }
      defaults?.set(cloudProcessingEnabled, forKey: cloudProcessingEnabledKey)
      defaults?.set(captureContractV2, forKey: contractV2Key)
      defaults?.set(aiConsentGranted, forKey: aiConsentGrantedKey)
      setOrRemove(installID, forKey: installIDKey)
      // MALI-031: device secret → shared Keychain only; never a UserDefaults
      // duplicate. Any legacy plaintext value is removed.
      if let secret = clean(deviceSecret) {
        SharedKeychain.setString(secret, forKey: deviceSecretKC)
      } else {
        SharedKeychain.remove(forKey: deviceSecretKC)
      }
      defaults?.removeObject(forKey: deviceSecretKey)
      setOrRemove(backendURL, forKey: backendURLKey)
      setOrRemove(anonKey, forKey: anonKeyKey)
      defaults?.synchronize()
      return true
    }
    return written ?? false
  }

  static func setApnsToken(_ token: String?, environment: String?) {
    setOrRemove(token, forKey: apnsTokenKey)
    setOrRemove(environment, forKey: apnsEnvironmentKey)
    defaults?.synchronize()
  }

  static func apnsTokenInfo() -> (token: String, environment: String)? {
    guard let token = clean(defaults?.string(forKey: apnsTokenKey)),
          let environment = clean(defaults?.string(forKey: apnsEnvironmentKey)) else {
      return nil
    }
    return (token, environment)
  }

  static func enqueueNotificationRoute(
    userInfo: [AnyHashable: Any],
    action: String? = nil
  ) {
    let payload = NotificationRoutePayload(
      payloadId: clean(userInfo["payloadId"] as? String),
      transactionId: clean(userInfo["transactionId"] as? String),
      smartInboxItemId: clean(userInfo["smartInboxItemId"] as? String),
      notificationType: clean(userInfo["notificationType"] as? String),
      source: clean(userInfo["source"] as? String),
      receivedAt: isoFormatter.string(from: Date()),
      notificationLogId: clean(userInfo["notificationLogId"] as? String),
      action: clean(action)
    )
    guard payload.payloadId != nil ||
      payload.transactionId != nil ||
      payload.smartInboxItemId != nil else {
      return
    }
    // MALI-068n: read-modify-write under the shared cross-process lock so a
    // concurrent host/extension write cannot lose a route.
    _ = try? withQueueLock {
      var queue = loadNotificationRoutes()
      queue.append(payload)
      if queue.count > 10 {
        queue.removeFirst(queue.count - 10)
      }
      if let data = try? JSONEncoder().encode(queue) {
        defaults?.set(data, forKey: pendingNotificationRoutesKey)
        defaults?.synchronize()
      }
    }
  }

  static func consumePendingNotificationRoutesJSON() -> String? {
    try? withQueueLock { () throws -> String? in
      let queue = loadNotificationRoutes()
      guard !queue.isEmpty,
            let data = try? JSONEncoder().encode(queue),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      defaults?.removeObject(forKey: pendingNotificationRoutesKey)
      defaults?.synchronize()
      return json
    }
  }

  static func isoString(from date: Date) -> String {
    isoFormatter.string(from: date)
  }

  /// Appends within the diagnostic quota; never evicts unacknowledged events.
  @discardableResult
  static func enqueueNotificationLogEvent(
    notificationLogId: String,
    eventType: String,
    channel: String,
    notificationType: String,
    relatedEntityType: String? = nil,
    relatedEntityId: String? = nil,
    errorCode: String? = nil,
    errorReason: String? = nil
  ) -> Bool {
    var payload = NotificationLogEventPayload(
      notificationLogId: notificationLogId,
      eventType: eventType,
      channel: channel,
      notificationType: notificationType,
      relatedEntityType: clean(relatedEntityType),
      relatedEntityId: clean(relatedEntityId),
      errorCode: clean(errorCode),
      errorReason: clean(errorReason).map { String($0.prefix(300)) },
      occurredAt: isoFormatter.string(from: Date())
    )
    // MALI-068n: RMW under the shared cross-process lock.
    return (try? withQueueLock {
      var queue = try loadNotificationLogEvents()
      guard queue.count < 200 else { return false }
      // Later outcomes retain the first event's origin, even after an account switch.
      if let origin = queue.first(where: { $0.notificationLogId == notificationLogId }) {
        payload.originKind = origin.originKind
        payload.ownerUid = origin.ownerUid
        payload.ownerGeneration = origin.ownerGeneration
      } else if eventType == "created", relatedEntityType == "payload",
                let capture = try loadQueueReadOnly().queue.first(where: { $0.id == relatedEntityId }),
                capture.ownerState == ownerStateStamped {
        payload.originKind = "native"
        payload.ownerUid = capture.ownerUid
        payload.ownerGeneration = capture.ownerGeneration
      }
      payload.eventId = UUID().uuidString.lowercased()
      queue.append(payload)
      guard let data = try? JSONEncoder().encode(queue) else { return false }
      defaults?.set(data, forKey: notificationLogEventsKey)
      defaults?.synchronize()
      return true
    }) ?? false
  }

  static func consumePendingNotificationLogEventsJSON(ownerUid: String? = nil, ownerGeneration: Int? = nil) -> String? {
    try? withQueueLock { () throws -> String? in
      guard let ownerUid, let ownerGeneration,
            let owner = try readActiveOwner(),
            owner.uid == ownerUid, owner.generation == ownerGeneration,
            try readBarrier() == nil else { return nil }
      let queue = try loadNotificationLogEvents()
      let matches = queue.filter {
        $0.originKind == "native" && $0.ownerUid == ownerUid &&
        $0.ownerGeneration == ownerGeneration
      }
      guard !matches.isEmpty,
            let data = try? JSONEncoder().encode(matches),
            let json = String(data: data, encoding: .utf8) else {
        return nil
      }
      return json
    }
  }

  /// Removes only a persisted event of the same still-current origin.
  static func acknowledgeNotificationLogEvent(eventId: String, ownerUid: String,
                                             ownerGeneration: Int) -> Bool {
    guard UUID(uuidString: eventId) != nil else { return false }
    return (try? withQueueLock {
      guard let owner = try readActiveOwner(), owner.uid == ownerUid,
            owner.generation == ownerGeneration, try readBarrier() == nil else { return false }
      let queue = try loadNotificationLogEvents()
      let retained = queue.filter {
        !($0.eventId == eventId && $0.originKind == "native" &&
          $0.ownerUid == ownerUid && $0.ownerGeneration == ownerGeneration)
      }
      guard retained.count != queue.count,
            let data = try? JSONEncoder().encode(retained) else { return false }
      defaults?.set(data, forKey: notificationLogEventsKey)
      defaults?.synchronize()
      return true
    }) ?? false
  }

  private static func loadNotificationLogEvents() throws -> [NotificationLogEventPayload] {
    guard let defaults else { throw QueueError.lockUnavailable }
    guard let data = defaults.data(forKey: notificationLogEventsKey) else {
      if defaults.object(forKey: notificationLogEventsKey) != nil { throw QueueError.unreadable }
      return []
    }
    return try JSONDecoder().decode([NotificationLogEventPayload].self, from: data)
  }

  /// Signals the host Flutter app that backend relay state may have changed.
  ///
  /// Backend-first captures do not need to store the raw SMS in App Group on
  /// success; the relay row is already in `processed_captures`. This notification
  /// wakes the host app, when running, so Flutter can call `sync-captures` and
  /// refresh Drift/UI without waiting for a notification tap.
  static func notifyPendingCaptureUpdateAvailable() {
    notifyPendingMessagesAvailable()
  }

  private static func loadQueue() throws -> [Payload] {
    // MALI-031: the file holds an AES-GCM encrypted blob. CAP-0: a blob that
    // cannot be read THROWS — it is never reported as an empty queue, because
    // the next enqueue would then overwrite recoverable records. It is
    // deliberately NOT deleted here. Callers hold the queue lock.
    //
    // 2026-11-12: the queue is the main file followed by the overflow segments
    // in sequence order; that is the drain order. The layout is remembered for
    // this lock session so `saveQueue` rewrites only the segments whose items
    // changed and appends new items to the tail segment.
    let mainData = try readQueueFile()
    var mainItems: [Payload] = []
    if let data = mainData { mainItems = try decodeQueueBlob(data) }
    let overflow = try readOverflowSegments(cleanUp: true)
    queueLayout = QueueLayout(
      segments: [QueueSegment(seq: 0, items: mainItems)] + overflow.segments,
      nextSeq: overflow.nextSeq)
    if mainData == nil { _ = try migrateLegacyQueue() }
    guard let layout = queueLayout else { throw QueueError.unreadable }
    return layout.items
  }

  /// `loadQueue` plus the §4.5 expiry: unbound items older than
  /// `unboundExpiryDays` are removed (stamped items never expire by age) and a
  /// content-free diagnostics counter is bumped. Callers hold the queue lock.
  private static func loadQueuePruned(now: Date = clockOverride?() ?? Date()) throws -> [Payload] {
    var queue = try loadQueue()
    let cutoff = now.addingTimeInterval(-Double(unboundExpiryDays) * 86_400)
    let before = queue.count
    queue.removeAll(where: { item in
      guard item.ownerState == ownerStateUnbound,
            let since = (item.unboundAt ?? item.createdAt).flatMap(isoFormatter.date(from:))
      else { return false }
      return since < cutoff
    })
    let expired = before - queue.count
    if expired > 0 {
      try saveQueue(queue, notifyHost: false)
      defaults?.set(
        (defaults?.integer(forKey: expiredUnboundCountKey) ?? 0) + expired,
        forKey: expiredUnboundCountKey
      )
      defaults?.set(isoFormatter.string(from: now), forKey: expiredUnboundLastKey)
    }
    return queue
  }

  /// §4.7: the v2 queue becomes v3 ONCE. Nothing is imported or dropped here.
  /// Native cannot see the adopted replica, so every v2 item is quarantined as
  /// `unbound` with NO hint (the legacy owner marker is never trusted); Dart
  /// removes the ones its adopted replica proves consumed (receipt or
  /// tx.id == capture_id) through `resolveLegacyItems`. Quotas do not apply: a
  /// legacy item is never evicted. The v2 blob stays for the rollback grace.
  private static func migrateLegacyQueue() throws -> [Payload] {
    guard defaults?.bool(forKey: migratedKey) != true else { return [] }
    guard let blob = defaults?.data(forKey: queueKey) else {
      defaults?.set(true, forKey: migratedKey)
      return []
    }
    let now = isoFormatter.string(from: Date())
    let items = try decodeQueueBlob(blob).map { quarantinedLegacy($0, at: now) }
    if !items.isEmpty {
      // `saveQueue` takes the WHOLE queue: an overflow segment already on disk
      // is kept, the migrated items are appended after it.
      guard let layout = queueLayout else { throw QueueError.storageWriteFailed }
      try saveQueue(layout.items + items, notifyHost: false)
    }
    defaults?.set(true, forKey: migratedKey)
    return items
  }

  private static func quarantinedLegacy(_ item: Payload, at now: String) -> Payload {
    var item = item
    item.ownerState = ownerStateUnbound
    item.ownerUid = nil
    item.ownerGeneration = nil
    item.ownerHint = nil
    item.unboundAt = now
    item.origin = originLegacyV2
    return item
  }

  /// A pre-queue single-text value becomes a quarantined queue item.
  private static func foldLegacyText(into queue: inout [Payload]) -> Bool {
    guard let legacy = defaults?.string(forKey: legacyKey),
          !legacy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return false
    }
    let receivedAt = isoFormatter.string(from: Date())
    queue.append(quarantinedLegacy(Payload(
      id: makePayloadID(
        text: legacy,
        sender: nil,
        senderName: nil,
        senderID: nil,
        source: "legacy",
        receivedAt: receivedAt
      ),
      text: legacy,
      sender: nil,
      senderName: nil,
      senderId: nil,
      source: "legacy",
      receivedAt: receivedAt,
      locale: notificationLanguage,
      status: CaptureStatus.pending.rawValue,
      failureReason: nil,
      sentAt: nil,
      createdAt: receivedAt,
      receivedAtInferred: nil
    ), at: receivedAt))
    return true
  }

  /// §4.2 consumption rule: only items stamped to the ACTIVE owner are importable.
  /// Unbound items and items stamped to another owner wait, invisible.
  private static func importableItems(_ queue: [Payload], owner: OwnerRecord?) -> [Payload] {
    guard let owner = owner else { return [] }
    return queue.filter { $0.ownerState == ownerStateStamped && $0.ownerUid == owner.uid }
  }

  private static func queueFileURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(queueFileName)
  }

  private static func appGroupContainerURL() throws -> URL {
    guard let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    ) else {
      throw QueueError.lockUnavailable
    }
    return url
  }

  /// nil only when the file does not exist; an existing file that cannot be read
  /// throws (never "empty").
  private static func readQueueFile() throws -> Data? {
    let url = try queueFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    guard let data = try? Data(contentsOf: url) else { throw QueueError.unreadable }
    return data
  }

  /// §4.5 since 2026-11-12: the queue has NO count or byte quota (a full
  /// segment opens an overflow segment). The one ceiling left is per item: it
  /// must fit in one segment. Throws before anything is written; never evicts.
  private static func checkQuotas(adding item: Payload) throws {
    guard let data = try? JSONEncoder().encode(item) else { throw QueueError.encodingFailed }
    if data.count > maxItemBytes { throw QueueError.quotaExceeded }
  }

  // MARK: Overflow segments (2026-11-12, owner-approved)
  //
  // Segment 0 is the main file (`pending_bank_messages_v3.bin`, the unchanged
  // pre-overflow format, still read and written as before). Segments 1... live
  // in `overflowDirName` as `seg-<16-digit seq>.bin`: the same AES-GCM blob of
  // a JSON `[Payload]` under the same Keychain key, with the same owner stamps.
  // Every file is written durably (temp file, F_FULLFSYNC, rename, directory
  // sync) under the queue flock, so the App, the App Intent and the Share
  // Extension are serialized exactly as for the main file. An item never moves
  // between segments; new items go to the highest-numbered segment, and a new
  // segment is opened when that one is full (`segmentMaxItems` /
  // `segmentMaxBytes`). A torn temp file is never read. A segment that cannot
  // be decrypted although the key is readable is moved to `quarantineDirName`
  // (kept, counted in `queueStats`, never decrypted again, deleted only by a
  // purge or a Remove-data sweep); a missing or unreadable key fails the whole
  // store closed instead, like an unreadable main file.

  private struct QueueSegment {
    /// 0 is the main file; overflow segments are 1, 2, ...
    let seq: Int
    var items: [Payload]
  }

  private struct QueueLayout {
    /// `segments[0]` is always the main file (possibly absent / empty), then
    /// the readable overflow segments in ascending order.
    var segments: [QueueSegment]
    /// Above every overflow segment name on disk (quarantine candidates too).
    var nextSeq: Int
    var items: [Payload] { segments.flatMap { $0.items } }
  }

  /// The layout read by the last `loadQueue` of THIS lock session. Reset by
  /// `withQueueLock`, so it never outlives the flock it was read under.
  private static var queueLayout: QueueLayout?

  private static func overflowDirURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(overflowDirName, isDirectory: true)
  }

  private static func quarantineDirURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(quarantineDirName, isDirectory: true)
  }

  private static func segmentURL(_ seq: Int) throws -> URL {
    guard seq > 0 else { return try queueFileURL() }
    return try overflowDirURL().appendingPathComponent(
      segmentFilePrefix + String(format: "%016d", seq) + segmentFileSuffix)
  }

  private static func segmentSeq(_ name: String) -> Int? {
    guard name.hasPrefix(segmentFilePrefix), name.hasSuffix(segmentFileSuffix),
          !name.contains(tempFileMarker) else { return nil }
    let digits = name.dropFirst(segmentFilePrefix.count).dropLast(segmentFileSuffix.count)
    guard digits.count == 16, digits.allSatisfy({ $0.isASCII && $0.isNumber }),
          let seq = Int(digits), seq > 0 else { return nil }
    return seq
  }

  /// Overflow segments are always sealed (no plaintext form), so they need the
  /// key itself. CAP-0: a key that cannot be read throws `keyUnavailable`; a
  /// key that is GONE while sealed segments exist throws `unreadable` (the same
  /// as an undecryptable main file). Neither case quarantines or skips a file.
  private static func segmentKey() throws -> SymmetricKey {
    let read = readQueueKey()
    switch read.status {
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else { throw QueueError.unreadable }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      throw QueueError.unreadable
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  /// The readable overflow segments in order. [cleanUp] (writers, under the
  /// flock) removes torn temp files and moves undecryptable segments to the
  /// quarantine directory; without it (read-only stats) nothing on disk
  /// changes and an undecryptable segment is only skipped and counted.
  private static func readOverflowSegments(cleanUp: Bool) throws
    -> (segments: [QueueSegment], nextSeq: Int, corrupt: Int) {
    let fm = FileManager.default
    if cleanUp { removeTornMainTempFiles() }
    let dir = try overflowDirURL()
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: dir.path, isDirectory: &isDirectory) else { return ([], 1, 0) }
    guard isDirectory.boolValue, let names = try? fm.contentsOfDirectory(atPath: dir.path) else {
      throw QueueError.unreadable
    }
    var found: [(seq: Int, name: String)] = []
    for name in names {
      if name.contains(tempFileMarker) {
        // A torn write: never a segment. We hold the flock, so no write is in
        // progress; a writer removes it, a reader just ignores it.
        if cleanUp { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        continue
      }
      if let seq = segmentSeq(name) { found.append((seq, name)) }
    }
    found.sort { $0.seq < $1.seq }
    let nextSeq = (found.last?.seq ?? 0) + 1
    guard !found.isEmpty else { return ([], nextSeq, 0) }
    let key = try segmentKey()
    var segments: [QueueSegment] = []
    var corrupt = 0
    for entry in found {
      let url = dir.appendingPathComponent(entry.name)
      // A file that cannot be READ (e.g. data protection before first unlock)
      // is not corrupt: fail closed, keep it.
      guard let data = try? Data(contentsOf: url) else { throw QueueError.unreadable }
      if let box = try? AES.GCM.SealedBox(combined: data),
         let plain = try? AES.GCM.open(box, using: key),
         let items = try? JSONDecoder().decode([Payload].self, from: plain) {
        if !items.isEmpty { segments.append(QueueSegment(seq: entry.seq, items: items)) }
        continue
      }
      corrupt += 1
      if cleanUp { quarantineSegment(url) }
    }
    return (segments, nextSeq, corrupt)
  }

  /// Moves an undecryptable overflow segment aside, byte-for-byte. Best effort:
  /// if the move fails it stays in place, is skipped on every load, and is
  /// never rewritten (new segments are numbered above it).
  private static func quarantineSegment(_ url: URL) {
    let fm = FileManager.default
    guard let dir = try? quarantineDirURL() else { return }
    try? fm.createDirectory(
      at: dir, withIntermediateDirectories: true,
      attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    let target = dir.appendingPathComponent(
      url.lastPathComponent + "." + UUID().uuidString.lowercased())
    try? fm.moveItem(at: url, to: target)
  }

  /// Content-free count of the segments set aside as undecryptable.
  private static func quarantinedSegmentCount() -> Int {
    guard let dir = try? quarantineDirURL(),
          let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
      return 0
    }
    return names.count
  }

  /// Leftover `.pending_bank_messages_v3.bin.tmp-*` files of a torn main write.
  private static func removeTornMainTempFiles() {
    let fm = FileManager.default
    guard let container = try? appGroupContainerURL(),
          let names = try? fm.contentsOfDirectory(atPath: container.path) else { return }
    let prefix = "." + queueFileName + tempFileMarker
    for name in names where name.hasPrefix(prefix) {
      try? fm.removeItem(at: container.appendingPathComponent(name))
    }
  }

  /// True when a sealed queue file (main or overflow segment) exists, so a
  /// missing key must NOT be replaced by a new one.
  private static func sealedQueueFilesExist() throws -> Bool {
    let fm = FileManager.default
    if fm.fileExists(atPath: try queueFileURL().path) { return true }
    let names = (try? fm.contentsOfDirectory(atPath: try overflowDirURL().path)) ?? []
    return names.contains { segmentSeq($0) != nil }
  }

  /// Which segment an item was loaded from is found by its id (ids are unique
  /// in the queue: `enqueue` deduplicates); an id-less legacy record falls back
  /// to its content, and duplicates are matched one stored copy at a time.
  private static func slotKey(_ item: Payload) -> String {
    if let id = item.id { return "id:" + id }
    return "noid:" + [item.createdAt ?? "", item.receivedAt ?? "", item.text].joined(separator: "|")
  }

  private static func plaintextSize(_ items: [Payload]) throws -> Int {
    guard let data = try? JSONEncoder().encode(items) else { throw QueueError.encodingFailed }
    return data.count
  }

  /// The QueueError for a failed file-system write: ENOSPC ("out of space")
  /// is `quotaExceeded`, anything else `storageWriteFailed`.
  private static func writeFailure(_ error: Error) -> QueueError {
    if let queueError = error as? QueueError { return queueError }
    let ns = error as NSError
    let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
    if (ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError)
      || (ns.domain == NSPOSIXErrorDomain && ns.code == Int(ENOSPC))
      || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ENOSPC)) {
      return .quotaExceeded
    }
    return .storageWriteFailed
  }

  /// The durable write of one queue file: the bytes go to a fresh
  /// `.<name>.tmp-<uuid>` beside it (file protection
  /// completeUntilFirstUserAuthentication), are flushed with F_FULLFSYNC
  /// (fsync as fallback), and only then renamed over the final name; the
  /// directory is synced so the rename survives a power loss. Until the rename
  /// the previous file is untouched; a crash leaves at most a temp file, which
  /// is never read and is removed by the next writer.
  private static func writeDurably(_ data: Data, to url: URL) throws {
    let fm = FileManager.default
    let dir = url.deletingLastPathComponent()
    let temp = dir.appendingPathComponent(
      "." + url.lastPathComponent + tempFileMarker + UUID().uuidString.lowercased())
    do {
      try fm.createDirectory(
        at: dir, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    } catch {
      throw writeFailure(error)
    }
    switch durableWriteFault?(url.lastPathComponent) ?? .none {
    case .none: break
    case .fail: throw QueueError.storageWriteFailed
    case .outOfSpace: throw QueueError.quotaExceeded
    case .tornTemp:
      try? data.prefix(data.count / 2).write(to: temp, options: [.withoutOverwriting])
      throw QueueError.storageWriteFailed
    }
    do {
      try data.write(
        to: temp, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
    } catch {
      try? fm.removeItem(at: temp)
      throw writeFailure(error)
    }
    let fd = open(temp.path, O_RDWR)
    var synced = false
    if fd >= 0 {
      synced = fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0
      close(fd)
    }
    guard synced else {
      try? fm.removeItem(at: temp)
      throw QueueError.storageWriteFailed
    }
    guard rename(temp.path, url.path) == 0 else {
      let code = errno
      try? fm.removeItem(at: temp)
      throw code == ENOSPC ? QueueError.quotaExceeded : QueueError.storageWriteFailed
    }
    // The rename is visible now. If it cannot be made durable the write is
    // reported as failed (at worst a later retry is a deduplicated repeat).
    let dirFD = open(dir.path, O_RDONLY)
    guard dirFD >= 0 else { throw QueueError.storageWriteFailed }
    defer { close(dirFD) }
    guard fcntl(dirFD, F_FULLFSYNC) == 0 || fsync(dirFD) == 0 else {
      throw QueueError.storageWriteFailed
    }
  }

  private static func removeSegmentFile(_ seq: Int) throws {
    guard seq > 0 else { return try removeQueueFile() }
    let url = try segmentURL(seq)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw QueueError.storageWriteFailed
    }
  }

  #if CAPTURE_STATE_WRITER
  /// Purge: every overflow segment, every quarantined segment and every torn
  /// temp file. Throws (so the purge reports failure) if ANY of them remains.
  private static func removeOverflowFiles() throws {
    let fm = FileManager.default
    removeTornMainTempFiles()
    let targets = [try overflowDirURL(), try quarantineDirURL()]
    for url in targets where fm.fileExists(atPath: url.path) {
      try? fm.removeItem(at: url)
    }
    let prefix = "." + queueFileName + tempFileMarker
    let container = try appGroupContainerURL()
    let leftovers = ((try? fm.contentsOfDirectory(atPath: container.path)) ?? [])
      .filter { $0.hasPrefix(prefix) }
    guard targets.allSatisfy({ !fm.fileExists(atPath: $0.path) }), leftovers.isEmpty else {
      throw QueueError.storageWriteFailed
    }
  }

  /// Remove-data sweep: a quarantined segment cannot be read, so it cannot be
  /// shown NOT to hold the removed user's captures; it is deleted.
  private static func removeQuarantinedSegments() throws {
    let url = try quarantineDirURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw QueueError.storageWriteFailed
    }
  }
  #endif

  private static func loadNotificationRoutes() -> [NotificationRoutePayload] {
    guard let data = defaults?.data(forKey: pendingNotificationRoutesKey),
          let queue = try? JSONDecoder().decode([NotificationRoutePayload].self, from: data) else {
      return []
    }
    return queue
  }

  #if CAPTURE_STATE_WRITER
  /// MALI-054n / MALI-031: removes ALL user-owned capture residue from the App
  /// Group AND invalidates the device secret + queue-encryption key, so a
  /// previous account's bank messages can never surface under a new identity and
  /// user B never inherits user A's device auth or a key that could decrypt
  /// residual data. Runs under the queue lock (same discipline as the queue
  /// writers). Install-level NON-secret config (backend URL/keys, install id,
  /// APNs token) is preserved and re-managed by setBackendConfig; the device
  /// secret is re-provisioned on the next login. Returns true on completion,
  /// false (nothing purged) when the queue lock could not be taken.
  @discardableResult
  static func purgeUserOwnedState() -> Bool {
    do {
      try withProtectedWriteLock {
        try removeQueueFile()
        // 2026-11-12: overflow, quarantine and torn temp files go too, BEFORE
        // the key; if any remains the purge fails and the key is kept.
        try removeOverflowFiles()
        defaults?.removeObject(forKey: queueKey)
        defaults?.removeObject(forKey: migratedKey)
        defaults?.removeObject(forKey: legacyKey)
        defaults?.removeObject(forKey: pendingCountKey)
        defaults?.removeObject(forKey: latestPayloadIDKey)
        defaults?.removeObject(forKey: pendingNotificationRoutesKey)
        defaults?.removeObject(forKey: notificationLogEventsKey)
        defaults?.removeObject(forKey: deviceSecretKey) // legacy plaintext, if any
        SharedKeychain.remove(forKey: deviceSecretKC)
        SharedKeychain.remove(forKey: queueEncryptionKeyKC)
        // A full wipe also forgets the owner and the hint. The Remove-data
        // barrier is deliberately NOT cleared here; only its final sweep does.
        SharedKeychain.remove(forKey: activeOwnerKC)
        SharedKeychain.remove(forKey: lastAdmittedHashKC)
        bumpOwnerEpoch()
        defaults?.removeObject(forKey: consentMirrorKey)
        defaults?.synchronize()
      }
    } catch {
      return false
    }
    return true
  }
  #endif

  /// CAP-0: the body NEVER runs without the exclusive lock. If the container,
  /// the lock file or the flock itself is unavailable this throws instead.
  private static func withQueueLock<T>(_ body: () throws -> T) throws -> T {
    guard !lockUnavailableOverride,
          let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
          ) else {
      throw QueueError.lockUnavailable
    }
    let lockURL = containerURL.appendingPathComponent(queueLockFileName)
    let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fd >= 0 else {
      throw QueueError.lockUnavailable
    }
    defer { close(fd) }
    while flock(fd, LOCK_EX) != 0 {
      guard errno == EINTR else { throw QueueError.lockUnavailable }
    }
    defer { flock(fd, LOCK_UN) }
    queueLayout = nil
    defer { queueLayout = nil }
    return try body()
  }

  #if CAPTURE_STATE_WRITER
  /// ASR §7.1/§7.4: every write to protected native state (egress state,
  /// pending enable, removal barrier, active owner, consent mirror) runs under
  /// this lock, which advances `egressMutationCounter` BEFORE the body runs —
  /// also when the body then refuses, so the counter can only over-report a
  /// change (an ASR evidence confirmation then fails closed).
  private static func withProtectedWriteLock<T>(_ body: () throws -> T) throws -> T {
    try withQueueLock {
      bumpEgressMutationCounter()
      return try body()
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// [withProtectedWriteLock] that hands the body the counter as it was BEFORE
  /// this write's own bump, for ASR transitions bound to an earlier receipt.
  private static func withProtectedWriteLockCounted<T>(_ body: (Int?) throws -> T) throws -> T {
    try withQueueLock {
      let prior = egressMutationCounter()
      bumpEgressMutationCounter()
      return try body(prior)
    }
  }
  #endif

  /// The counter as read under a lock already held (nil only without defaults).
  private static func egressMutationCounter() -> Int? {
    guard let store = defaults else { return nil }
    return store.integer(forKey: egressMutationCounterKey)
  }

  #if CAPTURE_STATE_WRITER
  private static func bumpEgressMutationCounter() {
    let next = (defaults?.integer(forKey: egressMutationCounterKey) ?? 0) &+ 1
    defaults?.set(next, forKey: egressMutationCounterKey)
  }
  #endif

  private static func saveQueue(_ queue: [Payload], notifyHost: Bool = true) throws {
    // 2026-11-12: [queue] is the whole logical queue (main + overflow). Every
    // item stays in the segment it was loaded from; only segments whose items
    // changed are rewritten (each one with `writeDurably`), emptied overflow
    // segments are deleted, and NEW items are appended to the tail segment,
    // opening a new overflow segment when the tail is full. Nothing is moved,
    // dropped or overwritten to make room.
    guard let layout = queueLayout else { throw QueueError.storageWriteFailed }
    queueLayout = nil   // restored below only if every write succeeds
    var assigned = layout.segments.map { QueueSegment(seq: $0.seq, items: []) }
    var slots: [String: [Int]] = [:]
    for (index, segment) in layout.segments.enumerated() {
      for item in segment.items { slots[slotKey(item), default: []].append(index) }
    }
    var fresh: [Payload] = []
    for item in queue {
      let key = slotKey(item)
      if var indexes = slots[key], !indexes.isEmpty {
        assigned[indexes.removeFirst()].items.append(item)
        slots[key] = indexes
      } else {
        fresh.append(item)
      }
    }
    var nextSeq = layout.nextSeq
    if !fresh.isEmpty {
      var tail = assigned.count - 1
      var tailBytes = try plaintextSize(assigned[tail].items)
      for item in fresh {
        let itemBytes = try plaintextSize([item])
        let tailItems = assigned[tail].items
        if !tailItems.isEmpty,
           tailItems.count + 1 > segmentMaxItems || tailBytes + itemBytes > segmentMaxBytes {
          assigned.append(QueueSegment(seq: nextSeq, items: []))
          nextSeq += 1
          tail = assigned.count - 1
          tailBytes = 0
        }
        assigned[tail].items.append(item)
        tailBytes += itemBytes
      }
    }
    for (index, segment) in assigned.enumerated() {
      let before = index < layout.segments.count ? layout.segments[index].items : []
      if segment.items.isEmpty {
        if segment.seq == 0 || !before.isEmpty { try removeSegmentFile(segment.seq) }
      } else if segment.items != before {
        try writeDurably(try encodeQueueBlob(segment.items), to: try segmentURL(segment.seq))
      }
    }
    queueLayout = QueueLayout(
      segments: assigned.filter { $0.seq == 0 || !$0.items.isEmpty }, nextSeq: nextSeq)
    updatePendingMetadata(queue)
    defaults?.synchronize()
    if notifyHost && !queue.isEmpty {
      notifyPendingMessagesAvailable()
    }
  }

  private static func removeQueueFile() throws {
    let url = try queueFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw QueueError.storageWriteFailed
    }
  }

  // MARK: - Owner record, hint, barrier (CAP-6, §4.2 / §4.4)
  //
  // Every function below that writes takes the queue flock, so the owner record
  // can never change underneath an intent that is stamping or authorizing an
  // upload. Reads that must agree with the queue also run under it.

  static func normalizedUID(_ uid: String) -> String {
    uid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  private static func readActiveOwner() throws -> OwnerRecord? {
    let read = ownerRecordReadOverride?() ?? SharedKeychain.read(forKey: activeOwnerKC)
    switch read.status {
    case errSecSuccess:
      guard let data = read.data,
            let record = try? JSONDecoder().decode(OwnerRecord.self, from: data) else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return record
    case errSecItemNotFound:
      return nil
    default:
      // Before first unlock / Keychain unavailable: the capture is NOT persisted.
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func readLastAdmittedHash() throws -> String? {
    let read = SharedKeychain.read(forKey: lastAdmittedHashKC)
    switch read.status {
    case errSecSuccess:
      return read.data.flatMap { String(data: $0, encoding: .utf8) }
    case errSecItemNotFound:
      return nil
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func writeKeychain(_ data: Data, forKey key: String) throws {
    let status = SharedKeychain.writeData(data, forKey: key)
    guard status == errSecSuccess else { throw QueueError.keyUnavailable(status) }
  }

  private static func removeKeychain(forKey key: String) throws {
    let status = SharedKeychain.remove(forKey: key)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw QueueError.keyUnavailable(status)
    }
  }

  /// HMAC-SHA256 key for uidHash, created ONLY on errSecItemNotFound (the same
  /// discipline as the queue key) and always under the queue flock.
  private static func uidHmacKey() throws -> SymmetricKey {
    let read = SharedKeychain.read(forKey: uidHmacKeyKC)
    switch read.status {
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      var bytes = [UInt8](repeating: 0, count: 32)
      guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
        throw QueueError.keyUnavailable(errSecAllocate)
      }
      let raw = Data(bytes)
      try writeKeychain(raw, forKey: uidHmacKeyKC)
      return SymmetricKey(data: raw)
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func uidHash(_ uid: String) throws -> String {
    let mac = HMAC<SHA256>.authenticationCode(
      for: Data(normalizedUID(uid).utf8),
      using: try uidHmacKey()
    )
    return Data(mac).map { String(format: "%02x", $0) }.joined()
  }

  /// The active owner record, or nil when no user is admitted.
  static func activeOwner() throws -> OwnerRecord? {
    try withQueueLock { try readActiveOwner() }
  }

  /// The owner epoch: bumped by every owner clear (A-12-min R4). Dart reads it
  /// BEFORE a publish and passes it back, so a publish that began before a
  /// sign-out / transition / removal clear cannot land after it.
  static func ownerEpoch() throws -> Int {
    try withQueueLock { defaults?.integer(forKey: ownerEpochKey) ?? 0 }
  }

  #if CAPTURE_STATE_WRITER
  private static func bumpOwnerEpoch() {
    defaults?.set((defaults?.integer(forKey: ownerEpochKey) ?? 0) + 1, forKey: ownerEpochKey)
  }
  #endif

  /// The consent a publish writes together with the owner (A-12-min R4).
  struct ConsentMirrorValue: Equatable {
    let cloud: Bool
    let ai: Bool
    let version: Int
  }

  #if CAPTURE_STATE_WRITER
  /// Publishes `{uid, uidHash, generation}` as the active owner, writing the
  /// owner's consent mirror FIRST and the owner record second, in ONE flock
  /// (A-12-min R4): an owner is never visible without its mirror. It compares
  /// and swaps on [expectedEpoch] (`ownerChanged` when a clear happened since
  /// Dart read it) and is refused while a Remove-data barrier is in force. The
  /// caller decides whether a network link was required first: Cloud OFF
  /// publishes locally; Cloud ON only after `link_capture_device(consent)`
  /// succeeded (§4.2). Re-publishing the current owner rewrites the mirror and
  /// keeps the generation.
  @discardableResult
  static func publishActiveOwner(
    uid: String,
    mirror: ConsentMirrorValue,
    expectedEpoch: Int,
    transitionGeneration: Int? = nil,
    repairGeneration: Bool = false
  ) throws -> OwnerRecord {
    try withProtectedWriteLock {
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      guard (defaults?.integer(forKey: ownerEpochKey) ?? 0) == expectedEpoch else {
        throw QueueError.ownerChanged
      }
      let normalized = normalizedUID(uid)
      guard !normalized.isEmpty else { throw QueueError.ownerChanged }
      // P4/P6: refuse before ANY write a stale generation, or a widening mirror
      // while the egress state denies (or is uncertain for) this owner. A
      // restrictive mirror (cloud=false, ai=false) is always publishable.
      try guardMirrorWrite(owner: normalized, mirror: mirror, transitionGeneration: transitionGeneration)
      // Repair mode never manufactures a key: without one no owner can verify.
      if repairGeneration, try existingUidHmacKey() == nil { throw QueueError.ownerChanged }
      let hash = try uidHash(normalized)
      let current = try readActiveOwner()
      let lifecycleView = egressView()
      if lifecycleView.maps.contains(where: { $0.owners[hash]?.retirement != nil }) {
        throw QueueError.egressDenied
      }
      var baseGeneration = defaults?.integer(forKey: ownerGenerationKey) ?? 0
      if repairGeneration {
        // Only the SAME verified owner whose counter disagrees is repairable.
        guard let current, current.uid == normalized, current.uidHash == hash,
              let store = defaults, let counter = snapshotCounter(ownerGenerationKey, in: store) else {
          throw QueueError.ownerChanged
        }
        if current.generation > 0 && current.generation == counter { return current }
        baseGeneration = max(counter, max(current.generation, 0))
      }
      writeConsentMirrorEntry(hash: hash, mirror: mirror)
      if !repairGeneration, let current, current.uid == normalized { return current }
      let generation = baseGeneration + 1
      let record = OwnerRecord(uid: normalized, uidHash: hash, generation: generation)
      guard let data = try? JSONEncoder().encode(record) else { throw QueueError.encodingFailed }
      try writeKeychain(data, forKey: activeOwnerKC)
      try writeKeychain(Data(hash.utf8), forKey: lastAdmittedHashKC)
      defaults?.set(generation, forKey: ownerGenerationKey)
      defaults?.synchronize()
      return record
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Re-claims the CURRENT active owner with a fresh, monotonic generation when
  /// the ONLY inconsistency is the app-group generation counter (missing, reset
  /// or different from the Keychain record: Keychain items survive an app
  /// deletion, the app-group defaults do not). It goes through the existing
  /// owner-claim path ([publishActiveOwner]) with the owner's CURRENT consent
  /// mirror, so nothing widens. Refuses everything else: no active owner, a
  /// different uid, an owner whose hash does not verify, a Remove-data barrier, a
  /// retirement, an unreadable counter. The epoch, egress records, queue and
  /// captures are untouched; work bound to the old generation fails closed
  /// (is ineligible) instead of being deleted. Already consistent: no-op.
  @discardableResult
  static func repairActiveOwnerGeneration(uid: String) throws -> OwnerRecord {
    let normalized = normalizedUID(uid)
    let state: (mirror: ConsentMirrorValue, epoch: Int) = try withQueueLock {
      guard !normalized.isEmpty, let key = try existingUidHmacKey() else { throw QueueError.ownerChanged }
      let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
      let hash = Data(mac).map { String(format: "%02x", $0) }.joined()
      let entry = defaults?.dictionary(forKey: consentMirrorKey)?[hash] as? [String: Any]
      let mirror = ConsentMirrorValue(
        cloud: (entry?["cloud"] as? Bool) ?? false,
        ai: (entry?["ai"] as? Bool) ?? false,
        version: (entry?["version"] as? Int) ?? 0)
      return (mirror, defaults?.integer(forKey: ownerEpochKey) ?? 0)
    }
    return try publishActiveOwner(
      uid: normalized, mirror: state.mirror, expectedEpoch: state.epoch, repairGeneration: true)
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Clears the owner record (sign-out, or the start of an account transition).
  /// [clearHint] true at a transition: captures during it are `unbound` with NO
  /// hint. At a plain sign-out the hint stays so the same uid can recover them.
  static func clearActiveOwner(clearHint: Bool) throws {
    try withProtectedWriteLock {
      try removeKeychain(forKey: activeOwnerKC)
      if clearHint { try removeKeychain(forKey: lastAdmittedHashKC) }
      bumpOwnerEpoch()
      defaults?.synchronize()
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Per-owner consent mirror (advisory; read by the intent for the stamped
  /// owner only). Keyed by uidHash; deleted by the Remove-data sweep.
  static func setConsentMirror(
    uid: String, cloud: Bool, ai: Bool, version: Int, transitionGeneration: Int? = nil
  ) throws {
    try withProtectedWriteLock {
      // A-12-min R4: refused while a Remove-data barrier is in force.
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      let mirror = ConsentMirrorValue(cloud: cloud, ai: ai, version: version)
      try guardMirrorWrite(
        owner: normalizedUID(uid), mirror: mirror, transitionGeneration: transitionGeneration)
      writeConsentMirrorEntry(hash: try uidHash(uid), mirror: mirror)
    }
  }
  #endif

  /// P4: callers hold the flock. Stale generation or a widening mirror under a
  /// denial throws before anything is written.
  private static func guardMirrorWrite(
    owner: String, mirror: ConsentMirrorValue, transitionGeneration: Int?
  ) throws {
    if let transitionGeneration, egressGenerationIsStale(transitionGeneration, owner: owner) {
      throw QueueError.staleGeneration
    }
    if (mirror.cloud || mirror.ai) && egressDenied(forOwner: owner) {
      throw QueueError.egressDenied
    }
  }

  #if CAPTURE_STATE_WRITER
  /// Writes one mirror entry. Callers hold the queue flock.
  private static func writeConsentMirrorEntry(hash: String, mirror: ConsentMirrorValue) {
    var entries = defaults?.dictionary(forKey: consentMirrorKey) ?? [:]
    entries[hash] = ["cloud": mirror.cloud, "ai": mirror.ai, "version": mirror.version]
    defaults?.set(entries, forKey: consentMirrorKey)
    defaults?.synchronize()
  }
  #endif

  private static func consentMirror(forHash hash: String) -> (cloud: Bool, ai: Bool)? {
    guard let entry = defaults?.dictionary(forKey: consentMirrorKey)?[hash] as? [String: Any],
          let cloud = entry["cloud"] as? Bool,
          let ai = entry["ai"] as? Bool else {
      return nil
    }
    return (cloud, ai)
  }

  /// §4.2 "before any upload": re-reads `{uid, generation}` under the flock and
  /// allows the upload only if it is still the one the item was stamped under,
  /// the item is not local-only, and the stamped owner's consent mirror EXISTS
  /// and says cloud ON. Fails closed. EVERY upload path (the App Intent and the
  /// app's pendingSend replay) must call this first (A-12-min R2).
  static func authorizeUpload(payloadID: String) -> UploadDecision {
    (try? withQueueLock { try authorizeUploadLocked(payloadID) }) ?? .waiting
  }

  /// The authorizeUpload decision; the caller holds the queue flock.
  private static func authorizeUploadLocked(_ payloadID: String) throws -> UploadDecision {
      guard try readBarrier() == nil else { return .waiting }
      guard let item = try loadQueue().first(where: { $0.id == payloadID }) else {
        return .waiting
      }
      if item.ownerState == ownerStateUnbound { return .localOnly }
      guard item.ownerState == ownerStateStamped,
            let uid = item.ownerUid,
            let generation = item.ownerGeneration,
            let owner = try readActiveOwner(),
            owner.uid == uid, owner.generation == generation else {
        return .waiting
      }
      // C.4 admission: the denial state is read under THIS flock, with the owner
      // check. DISABLING / OFF / unreadable / conflicting for the stamped owner
      // means no request; the item stays on the device (local parse only).
      if egressDenied(forOwner: uid) { return .localOnly }
      if item.localOnly == true { return .localOnly }
      // A-12-min R2: fail closed. No mirror means nothing is known about this
      // owner's consent, so the item waits; it is never `allowed` by default.
      guard let mirror = consentMirror(forHash: owner.uidHash) else { return .waiting }
      return mirror.cloud
        ? .allowed(ownerUid: uid, ownerGeneration: generation, allowAi: mirror.ai)
        : .localOnly
  }

  /// C.4 native admission + in-flight registration, ONE flock: the same decision
  /// as [authorizeUpload], and when it is `.allowed` the upload is durably
  /// registered in the in-flight registry (`{payloadId, ownerHash, deadline}`)
  /// BEFORE the caller touches the network. A registry that cannot be read or
  /// written denies (`.localOnly`): no request. The caller MUST call
  /// [removeInflightUpload] when the request finishes, success or error.
  static func admitUpload(payloadID: String) -> UploadDecision {
    (try? withQueueLock { () throws -> UploadDecision in
      let decision = try authorizeUploadLocked(payloadID)
      guard case let .allowed(uid, _, _) = decision else { return decision }
      let now = egressNow()
      var entries: [InflightUpload]
      do {
        entries = try readInflightRaw()
      } catch {
        // A corrupt registry cannot say what is in flight. It is replaced only
        // once it is older than every deadline it could hold.
        guard inflightFileIsStale(now: now) else { return .localOnly }
        entries = []
      }
      entries.removeAll { $0.payloadId == payloadID || $0.deadline <= now.timeIntervalSince1970 }
      entries.append(InflightUpload(
        payloadId: payloadID,
        ownerHash: try uidHash(uid),
        deadline: now.addingTimeInterval(nativeUploadTimeout + inflightGrace).timeIntervalSince1970))
      do { try writeInflight(entries) } catch { return .localOnly }
      return decision
    }) ?? .waiting
  }

  // MARK: Cloud egress state (C.4 / C.5)

  /// One owner's entry. The owner is the KEY of [CloudEgressMap] (uidHash, HMAC),
  /// never a raw uid. [state] is ON, DISABLING or OFF.
  struct CloudEgressRecord: Codable, Equatable {
    let state: String
    let transitionGeneration: Int
    let reservedVersion: Int
    // N: durable lifecycle evidence in the existing two stores, never a new path.
    let lifetimeOwnerGeneration: Int?
    let lifetimeOwnerEpoch: Int?
    let retirement: PendingEnable?
    /// ASR §7.2: present only on an OFF written by the conditional expiry mint.
    /// Every other writer constructs records without it, which invalidates it
    /// (§7.3). Absent from the encoding when nil, so older records round-trip.
    let expiryEvidence: ExpiryEvidence?
    /// ASR §7.5 SE1: the evidence id a successor OFF lifetime consumed. Like
    /// [expiryEvidence], dropped by every other writer.
    let successorOfExpiry: String?

    init(state: String, transitionGeneration: Int, reservedVersion: Int,
         lifetimeOwnerGeneration: Int? = nil, lifetimeOwnerEpoch: Int? = nil,
         retirement: PendingEnable? = nil, expiryEvidence: ExpiryEvidence? = nil,
         successorOfExpiry: String? = nil) {
      self.state = state
      self.transitionGeneration = transitionGeneration
      self.reservedVersion = reservedVersion
      self.lifetimeOwnerGeneration = lifetimeOwnerGeneration
      self.lifetimeOwnerEpoch = lifetimeOwnerEpoch
      self.retirement = retirement
      self.expiryEvidence = expiryEvidence
      self.successorOfExpiry = successorOfExpiry
    }
  }

  /// ASR §7.2: the expired session lifetime an OFF record retired, bound to the
  /// native owner lifetime and to the session store lifecycle that expired.
  struct ExpiryEvidence: Codable, Equatable {
    let evidenceId: String
    let ownerGeneration: Int
    let ownerEpoch: Int
    let sessionLifecycle: Int
  }

  /// `cloud_egress_state` as stored (identically) in the Keychain item and the
  /// App Group file: one entry per owner, so a write for B never touches A's.
  struct CloudEgressMap: Codable, Equatable {
    var owners: [String: CloudEgressRecord] = [:]
  }

  /// The reconciled view of ONE owner for Dart (C.5).
  enum EgressSnapshot: Equatable {
    /// Neither store holds an entry for the owner (never disabled).
    case unset
    /// Complete read-only inspection: no active owner or unresolved native transition.
    case ownerless(epoch: Int, generation: Int)
    case record(CloudEgressRecord)
    /// Unreadable / corrupt / conflicting with no restrictive entry: DENIED.
    case uncertain
  }

  /// Seconds an intent upload may run (its request timeout) and the grace
  /// added to its in-flight deadline.
  static let nativeUploadTimeout: TimeInterval = 8
  private static let inflightGrace: TimeInterval = 2

  /// One admitted native upload (C.4 in-flight set). [deadline] is epoch seconds.
  struct InflightUpload: Codable, Equatable {
    let payloadId: String
    let ownerHash: String
    let deadline: Double
  }

  private static func egressNow() -> Date { clockOverride?() ?? Date() }

  private static func egressRank(_ state: String) -> Int? {
    switch state {
    case "ON": return 0
    case "DISABLING": return 1
    case "OFF": return 2
    default: return nil
    }
  }

  private static func decodeEgressMap(_ data: Data) -> CloudEgressMap? {
    guard let map = try? JSONDecoder().decode(CloudEgressMap.self, from: data) else { return nil }
    for (hash, record) in map.owners {
      guard !hash.isEmpty, egressRank(record.state) != nil,
            record.transitionGeneration >= 0, record.reservedVersion >= 0,
            (record.lifetimeOwnerGeneration == nil) == (record.lifetimeOwnerEpoch == nil),
            record.lifetimeOwnerGeneration.map({ $0 > 0 }) ?? true,
            record.lifetimeOwnerEpoch.map({ $0 >= 0 }) ?? true else {
        return nil
      }
      if let retired = record.retirement {
        guard validOperationId(retired.operationId), retired.ownerGeneration > 0,
              retired.ownerEpoch >= 0, retired.transitionGeneration >= 0,
              retired.reservedVersion >= 0, record.state != "ON" else { return nil }
      }
    }
    return map
  }

  private static func egressFileURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(egressStateFileName)
  }

  /// Both stores, read. A valid map is collected per store; any store that exists
  /// but cannot be read or decoded marks the view `uncertain`.
  private static func egressView() -> (maps: [CloudEgressMap], uncertain: Bool) {
    var maps: [CloudEgressMap] = []
    var uncertain = false
    let kc = egressKeychainReadOverride?() ?? SharedKeychain.read(forKey: egressStateKC)
    switch kc.status {
    case errSecSuccess:
      if let data = kc.data, let map = decodeEgressMap(data) {
        maps.append(map)
      } else {
        uncertain = true
      }
    case errSecItemNotFound:
      break
    default:
      uncertain = true
    }
    if let url = try? egressFileURL() {
      if FileManager.default.fileExists(atPath: url.path) {
        if let data = try? Data(contentsOf: url), let map = decodeEgressMap(data) {
          maps.append(map)
        } else {
          uncertain = true
        }
      }
    } else {
      uncertain = true
    }
    return (maps, uncertain)
  }

  /// C.5 owner-scoped evaluation; callers hold the queue flock. DENIED when:
  /// either store is unreadable/corrupt (the owner cannot be known, so EVERY owner
  /// is denied); the owner's own entry is DISABLING or OFF in either store; the
  /// two stores' entries for the owner disagree; or the owner cannot be hashed.
  /// Another owner's entry is never applied to this owner and never discarded.
  /// A nil [owner] is denied only when a store is uncertain.
  private static func egressDenied(forOwner owner: String?) -> Bool {
    let view = egressView()
    if view.uncertain { return true }
    // A pending-enable barrier store that cannot be read denies every owner, like
    // an unreadable egress store (fail closed, never "treated as absent").
    let pending = pendingView()
    if pending.anyUnreadable { return true }
    guard let owner else { return false }
    guard let hash = try? uidHash(owner) else { return true }
    // A pending explicit enable denies its owner in EVERY path that asks here
    // (upload admission, widening mirror/config writes, host requests) until
    // that exact operation completes with verified ON in both native layers.
    if pending.holds(hash) { return true }
    let mine = view.maps.compactMap { $0.owners[hash] }
    if mine.contains(where: { $0.state != "ON" || $0.retirement != nil }) { return true }
    if mine.contains(where: { $0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil }) {
      // §2b: the SAME evidence the snapshot requires. The requested owner must be
      // the actual active owner (normalized uid and independently computed hash),
      // with a positive generation that matches the stored counter, and both layers
      // must carry exactly that generation and the live epoch. No caller is trusted
      // to have validated the owner already.
      guard let active = try? readActiveOwner(), let defaults,
            active.uid == normalizedUID(owner), active.uidHash == hash,
            active.generation > 0,
            snapshotCounter(ownerGenerationKey, in: defaults) == active.generation,
            let epoch = snapshotCounter(ownerEpochKey, in: defaults),
            mine.count == 2, mine.allSatisfy({
              ($0.lifetimeOwnerGeneration ?? 0) > 0
                && $0.lifetimeOwnerGeneration == active.generation && $0.lifetimeOwnerEpoch == epoch
            }) else { return true }
    }
    return mine.count == 2 && mine[0] != mine[1]
  }

  /// P4: [generation] is older than a stored entry of the SAME owner (a new owner
  /// starts fresh). Callers hold the flock.
  private static func egressGenerationIsStale(_ generation: Int, owner: String) -> Bool {
    guard let hash = try? uidHash(owner) else { return true }
    return egressView().maps.contains {
      ($0.owners[hash]?.transitionGeneration ?? -1) > generation
    }
  }

  /// C.4 admission for a host-app native request that is not tied to a capture
  /// item (APNs registration). Under the flock; false (deny) when either store is
  /// uncertain, the lock is unavailable, the active owner's entry denies, or (no
  /// owner admitted) any owner has a DISABLING/OFF entry.
  /// H3.1: a caller that passes the transition [generation] it acts under is also
  /// refused when that generation is older than the active owner's stored one
  /// (P4); nil keeps the generation-less check.
  static func egressAdmitsHostRequest(transitionGeneration generation: Int? = nil) -> Bool {
    (try? withQueueLock { () throws -> Bool in
      let owner = try readActiveOwner()
      if egressDenied(forOwner: owner?.uid) { return false }
      if let generation, let uid = owner?.uid,
         egressGenerationIsStale(generation, owner: uid) { return false }
      if owner != nil { return true }
      // No active owner: a stored lifecycle-bound ON (or retirement) belongs to an
      // owner lifetime that can no longer be proven live (cleared owner), so it can
      // never admit a request. Fail closed until an owner is published again.
      let view = egressView()
      return !view.maps.contains {
          $0.owners.values.contains {
            $0.state != "ON" || $0.retirement != nil
              || $0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil
          }
        }
        && !pendingView().holdsAny
    }) ?? false
  }

  /// Snapshot reads may never create the HMAC key (unlike explicit owner publication).
  private static func existingUidHmacKey() throws -> SymmetricKey? {
    let read = SharedKeychain.read(forKey: uidHmacKeyKC)
    switch read.status {
    case errSecItemNotFound: return nil
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else { throw QueueError.unreadable }
      return SymmetricKey(data: data)
    default: throw QueueError.keyUnavailable(read.status)
    }
  }

  private static func validSnapshotHash(_ hash: String) -> Bool {
    hash.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func snapshotInteger(_ raw: Any) -> Int? {
    guard let number = raw as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          let value = raw as? Int, value >= 0 else { return nil }
    return value
  }

  private static func snapshotCounter(_ key: String, in store: UserDefaults) -> Int? {
    guard let raw = store.object(forKey: key) else { return 0 }
    return snapshotInteger(raw)
  }

  private static func snapshotBoolean(_ raw: Any?) -> Bool {
    guard let number = raw as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// Called only under the flock. No owner, key, mirror, epoch or record is written.
  private static func ownerlessEgressSnapshot(stage: (SnapshotStage) -> Void) throws -> EgressSnapshot {
    stage(.barrier)
    guard try readBarrier() == nil else { return unc("ownerless_barrier") }
    stage(.activeowner)
    guard try readActiveOwner() == nil else { return unc("ownerless_active_owner") }
    guard let store = defaults else { return unc("defaults_nil") }
    guard let epoch = snapshotCounter(ownerEpochKey, in: store) else { return unc("epoch_missing") }
    guard let generation = snapshotCounter(ownerGenerationKey, in: store) else { return unc("generation_missing") }
    stage(.hmac)
    let key = try existingUidHmacKey()
    let view = egressView()
    guard !view.uncertain else { return unc("egress_view_uncertain") }
    // An unresolved or unreadable pending-enable barrier is an unresolved native
    // transition: the ownerless installation is not provably clean.
    let pendingBarrier = pendingView()
    guard !pendingBarrier.anyUnreadable else { return unc("pending_unreadable") }
    guard !pendingBarrier.holdsAny else { return unc("pending_held") }
    var records: [String: CloudEgressRecord] = [:]
    for map in view.maps {
      for (hash, record) in map.owners {
        guard validSnapshotHash(hash), record.state != "DISABLING" else { return unc("record_invalid") }
        guard records[hash] == nil || records[hash] == record else { return unc("record_conflict") }
        records[hash] = record
      }
    }
    // A missing copy of a nonempty map is incomplete evidence, too.
    if !records.isEmpty {
      guard view.maps.count == 2, view.maps[0] == view.maps[1] else { return unc("record_copies_differ") }
    }
    stage(.ownerlesshint)
    let hintRead = SharedKeychain.read(forKey: lastAdmittedHashKC)
    let hint: String?
    switch hintRead.status {
    case errSecItemNotFound: hint = nil
    case errSecSuccess:
      guard let data = hintRead.data, let hash = String(data: data, encoding: .utf8),
            validSnapshotHash(hash), generation > 0 else { return unc("hint_invalid") }
      hint = hash
    default: throw QueueError.keyUnavailable(hintRead.status)
    }
    let mirrorRaw = store.object(forKey: consentMirrorKey)
    if let mirrorRaw {
      guard let mirrors = mirrorRaw as? [String: Any] else { return unc("mirror_not_dict") }
      for (hash, value) in mirrors {
        guard validSnapshotHash(hash), let entry = value as? [String: Any],
              snapshotBoolean(entry["cloud"]), snapshotBoolean(entry["ai"]),
              let rawVersion = entry["version"], snapshotInteger(rawVersion) != nil else { return unc("mirror_entry_invalid") }
      }
    }
    let mirrors = store.dictionary(forKey: consentMirrorKey) ?? [:]
    stage(.inflight)
    let inflight = try readInflightRaw()
    guard inflight.allSatisfy({ validSnapshotHash($0.ownerHash) && !$0.payloadId.isEmpty
      && $0.deadline.isFinite && $0.deadline <= egressNow().timeIntervalSince1970 }) else { return unc("inflight_invalid") }
    if key == nil && (generation > 0 || hint != nil || !records.isEmpty || !mirrors.isEmpty || !inflight.isEmpty) {
      return unc("hmac_key_missing_with_state")
    }
    return .ownerless(epoch: epoch, generation: generation)
  }

  /// Diagnostic only: a short constant naming the branch that produced the last
  /// `.uncertain` answer of [cloudEgressState(forUid:)] (never a uid, hash or
  /// value). Written under the queue lock; read right after the call.
  private static var egressUncertainReason = ""
  static var lastEgressUncertainReason: String { egressUncertainReason }
  private static func unc(_ reason: String) -> EgressSnapshot {
    egressUncertainReason = reason
    return .uncertain
  }

  /// Closed vocabulary for getter-only thrown failures.
  enum SnapshotStage: String {
    case lock, barrier, activeowner, hmac, ownerlesshint, inflight
  }

  struct SnapshotFailure: Error {
    let underlying: Error
    let stage: SnapshotStage
    var details: [String: String] {
      ["contract": "snapshot_v1", "stage": stage.rawValue, "category": Self.category(underlying)]
    }
    static func category(_ error: Error) -> String {
      switch error as? QueueError {
      case .lockUnavailable?: return "lock_unavailable"
      case .unreadable?: return "unreadable"
      case .keyUnavailable(let status)?:
        switch status {
        case errSecInteractionNotAllowed: return "interaction_not_allowed"
        case errSecMissingEntitlement: return "missing_entitlement"
        case errSecDecode: return "decode"
        default: return "key_other"
        }
      default: return "unexpected"
      }
    }
  }

  /// Getter-only failure evidence. No mutable global failure state or raw values.
  static func diagnosticCloudEgressState(forUid uid: String) throws -> EgressSnapshot {
    var stage = SnapshotStage.lock
    do { return try cloudEgressState(forUid: uid, stage: { stage = $0 }) }
    catch { throw SnapshotFailure(underlying: error, stage: stage) }
  }

  static func cloudEgressState(forUid uid: String) throws -> EgressSnapshot {
    try cloudEgressState(forUid: uid, stage: { _ in })
  }

  private static func cloudEgressState(forUid uid: String,
      stage: (SnapshotStage) -> Void) throws -> EgressSnapshot {
    try withQueueLock {
      egressUncertainReason = ""
      if uid.isEmpty { return try ownerlessEgressSnapshot(stage: stage) }
      let normalized = normalizedUID(uid)
      guard !normalized.isEmpty else { return unc("uid_empty_after_normalize") }
      let view = egressView()
      stage(.hmac)
      guard let key = try existingUidHmacKey() else {
        // An untouched installation has no hash key yet. Inspect before treating
        // an absent per-owner record as unset; never manufacture the missing key.
        let ownerless = try ownerlessEgressSnapshot(stage: stage)
        if case .ownerless = ownerless { return .unset }
        return unc("hmac_key_missing/" + egressUncertainReason)
      }
      let mac = HMAC<SHA256>.authenticationCode(for: Data(normalized.utf8), using: key)
      let hash = Data(mac).map { String(format: "%02x", $0) }.joined()
      let mine = view.maps.compactMap { $0.owners[hash] }
      if let top = mine.filter({ $0.state != "ON" }).max(by: {
        (egressRank($0.state) ?? 0, $0.transitionGeneration)
          < (egressRank($1.state) ?? 0, $1.transitionGeneration)
      }) {
        return .record(top)
      }
      if view.uncertain { return unc("egress_view_uncertain") }
      // A pending explicit enable is not a usable ON/unset: Dart sees the same
      // restrictive `uncertain` it already fails closed on. (A restrictive record
      // above is still reported as such.) Inspect the barrier with
      // [cloudEgressPending(forUid:)].
      let pendingBarrier = pendingView()
      if pendingBarrier.anyUnreadable { return unc("pending_unreadable") }
      if pendingBarrier.holds(hash) { return unc("pending_held") }
      // Restrictive records above remain usable for the existing removal revoke.
      // ON/unset is trustworthy only with readable ownership and generation.
      stage(.barrier)
      guard try readBarrier() == nil else { return unc("barrier_present") }
      guard let store = defaults else { return unc("defaults_nil") }
      guard let epoch = snapshotCounter(ownerEpochKey, in: store) else { return unc("epoch_missing") }
      guard let generation = snapshotCounter(ownerGenerationKey, in: store) else { return unc("generation_missing") }
      stage(.activeowner)
      let activeOwner = try readActiveOwner()
      if let owner = activeOwner {
        let ownerUid = normalizedUID(owner.uid)
        let ownerMac = HMAC<SHA256>.authenticationCode(for: Data(ownerUid.utf8), using: key)
        let ownerHash = Data(ownerMac).map { String(format: "%02x", $0) }.joined()
        guard !ownerUid.isEmpty, owner.uid == ownerUid else { return unc("owner_uid_not_normalized") }
        guard validSnapshotHash(owner.uidHash) else { return unc("owner_hash_invalid") }
        guard owner.uidHash == ownerHash else { return unc("owner_hash_mismatch") }
        guard owner.generation > 0 else { return unc("owner_generation_zero") }
        guard owner.generation == generation else { return unc("owner_generation_mismatch") }
      }
      if mine.isEmpty { return .unset }
      if mine.count == 2 && mine[0] != mine[1] { return unc("record_copies_differ") }
      // N-R1 bound-ON eligibility (read-only; mirrors the lifetime check of
      // [egressDenied]). A record carrying ANY lifecycle field is reported as ON
      // only when the REQUESTED uid is the actual active owner (its normalized uid
      // and independently computed hash match the requested ones) and BOTH
      // independently read layers hold the exact ON for the active generation and
      // the live owner epoch. Anything else (cleared owner, new generation or
      // epoch, another owner, a missing/half-bound layer) is uncertain. Records
      // with no lifecycle field at all are the explicit legacy boundary: they keep
      // the pre-N reporting and can never be produced by a new phase-authorized ON.
      if mine.contains(where: {
        $0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil || $0.retirement != nil
      }) {
        guard let owner = activeOwner, owner.uid == normalized, owner.uidHash == hash,
              mine.count == 2, mine.allSatisfy({
                $0.state == "ON" && $0.retirement == nil
                  && ($0.lifetimeOwnerGeneration ?? 0) > 0
                  && $0.lifetimeOwnerGeneration == owner.generation
                  && $0.lifetimeOwnerEpoch == epoch
              }) else { egressUncertainReason = "lifetime_fields_unbound"; return .uncertain }
      }
      return .record(mine[0])
    }
  }

  #if CAPTURE_STATE_WRITER
  /// Writes the OWNER's entry to BOTH stores under the queue flock. Both
  /// physical layers must be readable before any write: corruption has an
  /// unknown version frontier and is never repaired by this generic writer.
  /// Refuses older generations (or equal with a less restrictive state).
  /// Restriction preserves the maximum stored version; ON refuses a lower
  /// version. A restrictive legacy write succeeds if at least ONE store took it
  /// (C.5); an ON write needs BOTH. Bound entries retain their lifetime metadata.
  static func setCloudEgressState(
    state: String, ownerUid: String, transitionGeneration: Int, reservedVersion: Int
  ) throws {
    let owner = normalizedUID(ownerUid)
    guard let rank = egressRank(state), !owner.isEmpty,
          transitionGeneration >= 0, reservedVersion >= 0 else {
      throw QueueError.encodingFailed
    }
    let restrictive = rank > 0
    try withProtectedWriteLock {
      let hash = try uidHash(owner)
      // The legacy writer can never open a pending explicit enable: only
      // [writeCloudEgressEnableOn] under the exact operation writes that ON, and
      // only [finishCloudEgressEnable] lifts the barrier. Restrictive writes pass.
      if !restrictive {
        let pending = pendingView()
        if pending.anyUnreadable || pending.holds(hash) { throw QueueError.egressDenied }
      }
      let view = egressView()
      // Validate BOTH layers before any write, including the bound branch.
      // Restriction carries the highest owner version; ON cannot adopt it.
      guard !view.uncertain else { throw QueueError.egressDenied }
      var version = reservedVersion
      for map in view.maps {
        if let stored = map.owners[hash] {
          if transitionGeneration < stored.transitionGeneration
            || (transitionGeneration == stored.transitionGeneration && rank < (egressRank(stored.state) ?? 0)) {
            throw QueueError.staleGeneration
          }
          version = max(version, max(stored.reservedVersion, stored.retirement?.reservedVersion ?? 0))
        }
      }
      if !restrictive && version > reservedVersion { throw QueueError.staleGeneration }
      if view.maps.contains(where: { $0.owners.values.contains(where: { $0.retirement != nil || $0.lifetimeOwnerGeneration != nil }) }) {
        guard !view.uncertain else { throw QueueError.egressDenied }
        if !restrictive && view.maps.contains(where: {
          $0.owners[hash]?.retirement != nil || $0.owners[hash]?.lifetimeOwnerGeneration != nil
        }) {
          throw QueueError.egressDenied
        }
        // A reinstall can leave one readable OFF in Keychain and no file
        // entry. Filling that absent copy must keep the SAME restrictive
        // lifetime, otherwise the next explicit preflight sees two lifetimes
        // and can never finish. Existing entries and retirement evidence are
        // never rebound; ON/DISABLING and disagreeing lifetimes are excluded.
        let ownerCopies = view.maps.compactMap { $0.owners[hash] }
        let offSource = ownerCopies.first.flatMap { first in
          state == "OFF" && ownerCopies.allSatisfy {
            $0.state == "OFF" && $0.retirement == nil
              && $0.lifetimeOwnerGeneration == first.lifetimeOwnerGeneration
              && $0.lifetimeOwnerEpoch == first.lifetimeOwnerEpoch
          } ? first : nil
        }
        for layer in StateLayer.allCases {
          let read = egressLayerRead(layer)
          guard !read.isUnreadable else { throw QueueError.egressDenied }
          var map = CloudEgressMap()
          if case let .value(value) = read { map = value }
          let old = map.owners[hash]
          if let old, transitionGeneration < old.transitionGeneration
              || (transitionGeneration == old.transitionGeneration && rank < (egressRank(old.state) ?? 0)) {
            throw QueueError.staleGeneration
          }
          map.owners[hash] = CloudEgressRecord(state: state,
            transitionGeneration: transitionGeneration, reservedVersion: version,
            lifetimeOwnerGeneration: old?.lifetimeOwnerGeneration
              ?? (old == nil ? offSource?.lifetimeOwnerGeneration : nil),
            lifetimeOwnerEpoch: old?.lifetimeOwnerEpoch
              ?? (old == nil ? offSource?.lifetimeOwnerEpoch : nil), retirement: old?.retirement)
          guard let data = try? JSONEncoder().encode(map), writeStateLayer(.egress, layer, data),
                case let .value(back) = egressLayerRead(layer), back == map else {
            throw QueueError.storageWriteFailed
          }
        }
        return
      }
      for map in view.maps {
        if let stored = map.owners[hash] {
          let storedRank = egressRank(stored.state) ?? 0
          if transitionGeneration < stored.transitionGeneration
            || (transitionGeneration == stored.transitionGeneration && rank < storedRank) {
            throw QueueError.staleGeneration
          }
        }
      }
      if !restrictive && view.maps.isEmpty && view.uncertain {
        throw QueueError.egressDenied
      }
      var merged: [String: CloudEgressRecord] = [:]
      for map in view.maps {
        for (other, record) in map.owners {
          if let kept = merged[other],
             (egressRank(kept.state) ?? 0, kept.transitionGeneration)
               >= (egressRank(record.state) ?? 0, record.transitionGeneration) {
            continue
          }
          merged[other] = record
        }
      }
      merged[hash] = CloudEgressRecord(
        state: state, transitionGeneration: transitionGeneration,
        reservedVersion: version)
      guard let data = try? JSONEncoder().encode(CloudEgressMap(owners: merged)) else {
        throw QueueError.encodingFailed
      }
      var fileOK = false
      if let url = try? egressFileURL() {
        fileOK = (try? data.write(
          to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        ) != nil
      }
      let keychainOK = SharedKeychain.writeData(data, forKey: egressStateKC) == errSecSuccess
      guard restrictive ? (fileOK || keychainOK) : (fileOK && keychainOK) else {
        throw QueueError.storageWriteFailed
      }
    }
  }
  #endif

  // MARK: Pending enable barrier (consent-security amendment)
  //
  // WHY. `setCloudEgressState` reports one bool for "at least one / both layers
  // took it" and `getCloudEgressState` is a MERGED restrictive snapshot, so Dart
  // can neither attest what each native layer holds nor compensate a late ON
  // safely. An explicit Cloud enable is therefore a four-phase native
  // transaction, every phase under the queue flock, every reply a structured
  // per-layer report. The two native layers are the Keychain item and the App
  // Group file ("keychain", "file"); each is read back and judged INDEPENDENTLY
  // (an attempted-write count or a merged winner proves nothing).
  //
  // STATE. `cloud_egress_pending_v1` (Keychain item + App Group file):
  // `{"owners": {<uidHash>: {operationId, transitionGeneration, reservedVersion,
  // ownerGeneration, ownerEpoch}}}`. The key is the HMAC uidHash, never a raw
  // uid. The operationId is a nonsecret 128-bit random hex string created HERE
  // (never supplied by a caller). ownerGeneration and ownerEpoch are the EXISTING
  // F2 evidence of the active owner (the owner record's generation and the owner
  // epoch) read under the flock when the operation began: they bind the
  // operation to one admission lifecycle. These APIs only READ that evidence;
  // they never mint or change an owner, a generation or an epoch.
  // An entry means "a pending explicit enable exists for this owner": every
  // native admission path denies that owner (see [egressDenied]). Absent in both
  // layers is the healthy legacy state and denies nothing. An entry in only one
  // layer, an entry that differs between layers, and an unreadable or corrupt
  // layer all deny (unreadable denies every owner, like an unreadable egress
  // store). The store survives sign-out and is not swept by Remove data (egress
  // state does not either).
  //
  // EACH LAYER IS ITS OWN STORE. A write rebuilds a layer only from THAT layer's
  // readable content: another owner's entries are preserved per layer exactly and
  // are never merged or copied across layers. An unreadable layer is never
  // reconstructed or overwritten, and it can hide another owner's barrier or a
  // newer operation, so ANY unreadable layer makes a phase `uncertain` without a
  // write.
  //
  // PHASES (state = owner's pending barrier B and egress record E):
  //  1. begin     needs a committed native active owner equal to the requested
  //               owner (otherwise `ownerMismatch`: nothing is written, nothing
  //               is minted). A fresh begin NEVER adopts an existing operation,
  //               even with identical parameters: it is a `conflict`. Only an
  //               explicit resume (the original operationId AND the original
  //               ownerEpoch, still matching the live owner) repairs a layer that
  //               is healthy-absent. B := op in BOTH layers, verified by
  //               read-back, BEFORE any ON is written; a generation not strictly
  //               greater than E is stale. Refused (barrierActive) during a
  //               Remove-data barrier. Never touches E.
  //  2. writeOn   needs the live owner/epoch to still equal the operation's
  //               binding, B == op in BOTH layers and E readable in both; refuses
  //               a layer holding a newer generation or a same-generation OFF/
  //               DISABLING; writes ON(generation, version) into each layer's
  //               own map and reads each back. The barrier stays.
  //  3. restrict  compensation. Needs the operation PROVEN by the barrier (exact
  //               entry in at least one readable layer, none unreadable, none
  //               different); no barrier, an unreadable barrier or another
  //               operation writes nothing. Per egress layer: unreadable is left
  //               alone; a newer generation is `superseded`; an already
  //               restrictive entry is reported without a write; only exactly the
  //               operation's ON(generation, version) becomes OFF, read back, and
  //               only in a layer whose OWN barrier entry is that exact operation
  //               (a layer without its own proof is `notOurs`: untouched,
  //               reported, status `incomplete`).
  //               Never removes the barrier. Needs no live owner (it only
  //               restricts).
  //  4. finish    the ONLY way the barrier is lifted, and only by the exact
  //               operation (its full binding). `complete` re-reads the
  //               Remove-data barrier and the live owner/epoch under the flock
  //               (an old queued complete after a logout/readmission is an
  //               `ownerMismatch` and clears nothing) and requires
  //               E == ON(generation, version) in BOTH layers. `abandon`
  //               requires E readable in both layers with NO ON for the owner at
  //               all (a prior ON is not exempt: without proof it is still
  //               authorized for this lifecycle the denial stays). The entry is
  //               then removed from each layer and each is read back: a layer
  //               that could not be cleared keeps denying (`incomplete`).
  //
  // A crash anywhere keeps the barrier (it is written first and removed last), so
  // a restart denies the owner until the exact operation is finished. A status of
  // `done` is the ONLY success; everything else is a refusal or an uncertain
  // outcome the caller must fail closed on.

  /// One owner's pending explicit-enable operation (see above).
  struct PendingEnable: Codable, Equatable {
    let operationId: String
    let transitionGeneration: Int
    let reservedVersion: Int
    /// The active owner record's generation when the operation began (F2).
    let ownerGeneration: Int
    /// The owner epoch when the operation began (F2).
    let ownerEpoch: Int
  }

  /// `cloud_egress_pending` as stored (identically) in the Keychain item and the
  /// App Group file: one entry per owner.
  struct PendingEnableMap: Codable, Equatable {
    var owners: [String: PendingEnable] = [:]
  }

  /// The outcome of a phase. Only [done] is success.
  enum TransitionStatus: String, Equatable {
    /// The phase is fully achieved and verified in BOTH layers.
    case done
    /// Some layer did not reach the target; the barrier is retained.
    case incomplete
    /// Another operation is pending for the owner, or the layers disagree.
    case conflict
    /// A newer generation (or a same-generation restrictive record) exists.
    case stale
    /// The expected barrier is missing from every layer.
    case noBarrier
    /// A layer is unreadable or corrupt: nothing was judged or written.
    case uncertain
    /// Inspection only: a consistent pending operation exists in both layers.
    case pending
    /// The native active owner is absent, is another owner, or is no longer the
    /// owner lifecycle (generation / epoch) the operation was bound to. Nothing
    /// was written; the barrier, if any, is untouched and keeps denying.
    case ownerMismatch
  }

  /// What one layer holds / what a phase did to it.
  enum LayerOutcome: String, Equatable {
    /// Read back and holds exactly the expected entry (or, for inspection, an entry).
    case verified
    /// Compensation replaced the operation's ON with OFF, read back.
    case restricted
    /// Already OFF/DISABLING; nothing to restrict.
    case alreadyRestrictive
    /// Holds a newer generation than the operation; left untouched.
    case superseded
    /// No entry for the owner in this layer.
    case absent
    /// The barrier entry was removed, read back.
    case cleared
    /// Holds an ON that is not this operation's; left untouched.
    case notOurs
    /// Exists but cannot be read or decoded; left untouched.
    case unreadable
    /// The write failed and the read-back does not show the target.
    case writeFailed
    /// The write reported success but the read-back differs from the target.
    case mismatch
  }

  struct LayerReport: Equatable {
    let layer: String
    let outcome: LayerOutcome
    let state: String?
    let transitionGeneration: Int?
    let reservedVersion: Int?
    let operationId: String?
    let ownerGeneration: Int?
    let ownerEpoch: Int?
  }

  /// The structured reply of every phase. [barrier] and [egress] always list the
  /// layers in the order "file", "keychain" (egress may be empty for `begin`
  /// conflicts that never read it). No uid, key or content ever appears here.
  struct EnableTransitionResult: Equatable {
    let operation: String
    let status: TransitionStatus
    let operationId: String?
    let transitionGeneration: Int?
    let reservedVersion: Int?
    let ownerGeneration: Int?
    let ownerEpoch: Int?
    let barrier: [LayerReport]
    let egress: [LayerReport]
    /// ASR §7.2: the evidence both layers hold after an expiry revoke, if any.
    var expiryEvidence: ExpiryEvidence? = nil
    /// ASR §7.4: `egressMutationCounter` read under the same lock (receipts).
    var mutationCounter: Int? = nil
    /// Inspection only: the highest reserved version the owner's stored egress
    /// entries carry, a retirement's own version included (a layer report shows
    /// only one of the two). nil when no layer holds an entry of the owner.
    var egressVersionFrontier: Int? = nil
  }

  private enum StateStore: String { case egress, pending }
  private enum StateLayer: String, CaseIterable { case file, keychain }

  private enum LayerRead<Map> {
    case absent
    case value(Map)
    case unreadable

    var isUnreadable: Bool {
      if case .unreadable = self { return true }
      return false
    }
  }

  private static func validOperationId(_ id: String) -> Bool {
    id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private static func decodePendingMap(_ data: Data) -> PendingEnableMap? {
    guard let map = try? JSONDecoder().decode(PendingEnableMap.self, from: data) else { return nil }
    for (hash, entry) in map.owners {
      guard validSnapshotHash(hash), validOperationId(entry.operationId),
            entry.transitionGeneration >= 0, entry.reservedVersion >= 0,
            entry.ownerGeneration > 0, entry.ownerEpoch >= 0 else { return nil }
    }
    return map
  }

  private static func pendingFileURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(pendingStateFileName)
  }

  private static func stateFileURL(_ store: StateStore) throws -> URL {
    store == .egress ? try egressFileURL() : try pendingFileURL()
  }

  private static func readStateLayer<Map>(
    _ store: StateStore, _ layer: StateLayer, decode: (Data) -> Map?
  ) -> LayerRead<Map> {
    switch layer {
    case .keychain:
      let read: (status: OSStatus, data: Data?)
      if store == .egress {
        read = egressKeychainReadOverride?() ?? SharedKeychain.read(forKey: egressStateKC)
      } else {
        read = pendingKeychainReadOverride?() ?? SharedKeychain.read(forKey: pendingStateKC)
      }
      switch read.status {
      case errSecSuccess:
        if let data = read.data, let map = decode(data) { return .value(map) }
        return .unreadable
      case errSecItemNotFound:
        return .absent
      default:
        return .unreadable
      }
    case .file:
      guard let url = try? stateFileURL(store) else { return .unreadable }
      guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
      guard let data = try? Data(contentsOf: url), let map = decode(data) else { return .unreadable }
      return .value(map)
    }
  }

  private static func layerWriteFault(_ store: StateStore, _ layer: StateLayer) -> LayerWriteFault {
    stateLayerWriteFault?(store.rawValue, layer.rawValue) ?? .none
  }

  #if CAPTURE_STATE_WRITER
  /// True when the write CALL reported success. Never proof: read the layer back.
  private static func writeStateLayer(_ store: StateStore, _ layer: StateLayer, _ data: Data) -> Bool {
    switch layerWriteFault(store, layer) {
    case .fail: return false
    case .silentDrop: return true
    case .none: break
    }
    switch layer {
    case .file:
      guard let url = try? stateFileURL(store) else { return false }
      return (try? data.write(
        to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil
    case .keychain:
      return SharedKeychain.writeData(
        data, forKey: store == .egress ? egressStateKC : pendingStateKC) == errSecSuccess
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  private static func removeStateLayer(_ store: StateStore, _ layer: StateLayer) -> Bool {
    switch layerWriteFault(store, layer) {
    case .fail: return false
    case .silentDrop: return true
    case .none: break
    }
    switch layer {
    case .file:
      guard let url = try? stateFileURL(store) else { return false }
      guard FileManager.default.fileExists(atPath: url.path) else { return true }
      return (try? FileManager.default.removeItem(at: url)) != nil
    case .keychain:
      let status = SharedKeychain.remove(forKey: store == .egress ? egressStateKC : pendingStateKC)
      return status == errSecSuccess || status == errSecItemNotFound
    }
  }
  #endif

  private static func egressLayerRead(_ layer: StateLayer) -> LayerRead<CloudEgressMap> {
    readStateLayer(.egress, layer, decode: decodeEgressMap)
  }

  private static func pendingLayerRead(_ layer: StateLayer) -> LayerRead<PendingEnableMap> {
    readStateLayer(.pending, layer, decode: decodePendingMap)
  }

  /// Both pending layers, read. Callers hold the flock.
  private struct PendingView {
    let file: LayerRead<PendingEnableMap>
    let keychain: LayerRead<PendingEnableMap>

    func layer(_ layer: StateLayer) -> LayerRead<PendingEnableMap> {
      layer == .file ? file : keychain
    }

    var anyUnreadable: Bool {
      StateLayer.allCases.contains { layer($0).isUnreadable }
    }

    func entry(_ hash: String, in layer: StateLayer) -> PendingEnable? {
      if case let .value(map) = self.layer(layer) { return map.owners[hash] }
      return nil
    }

    /// Any layer holds an entry for [hash] (one is enough to deny).
    func holds(_ hash: String) -> Bool {
      StateLayer.allCases.contains { entry(hash, in: $0) != nil }
    }

    var holdsAny: Bool {
      StateLayer.allCases.contains {
        if case let .value(map) = layer($0) { return !map.owners.isEmpty }
        return false
      }
    }
  }

  private static func pendingView() -> PendingView {
    PendingView(file: pendingLayerRead(.file), keychain: pendingLayerRead(.keychain))
  }

  private static func newOperationId() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw QueueError.keyUnavailable(errSecAllocate)
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Validates the full binding every phase after `begin` carries: owner,
  /// operation, generation, version, and the F2 owner generation / epoch the
  /// operation was created under. A malformed binding is a caller bug, not a state.
  private static func boundOperation(
    ownerUid: String, operationId: String, generation: Int, version: Int,
    ownerGeneration: Int, ownerEpoch: Int
  ) throws -> (owner: String, operation: PendingEnable) {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, validOperationId(operationId), generation > 0, version >= 0,
          ownerGeneration > 0, ownerEpoch >= 0 else {
      throw QueueError.encodingFailed
    }
    return (owner, PendingEnable(
      operationId: operationId, transitionGeneration: generation, reservedVersion: version,
      ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch))
  }

  /// The owner's uidHash WITHOUT creating the HMAC key (these phases never mint
  /// anything): nil when no key exists, i.e. nothing can be bound to a hash yet.
  private static func keyedOwnerHash(_ owner: String) throws -> String? {
    guard let key = try existingUidHmacKey() else { return nil }
    let mac = HMAC<SHA256>.authenticationCode(for: Data(normalizedUID(owner).utf8), using: key)
    return Data(mac).map { String(format: "%02x", $0) }.joined()
  }

  /// The EXISTING F2 evidence, read under the flock: the committed active owner's
  /// generation and the owner epoch, when that owner is [owner]. nil when no owner
  /// is committed or it is another one. Throws (fail closed) when the epoch or the
  /// owner record cannot be read. Never writes.
  private static func liveOwner(matching owner: String) throws -> (generation: Int, epoch: Int)? {
    guard let store = defaults, let epoch = snapshotCounter(ownerEpochKey, in: store) else {
      throw QueueError.unreadable
    }
    guard let record = try readActiveOwner(), record.uid == normalizedUID(owner) else { return nil }
    let view = egressView()
    guard let hash = try keyedOwnerHash(owner),
          !view.maps.contains(where: { $0.owners[hash]?.retirement != nil }) else { return nil }
    return (record.generation, epoch)
  }

  private static func pendingReport(
    _ layer: StateLayer, _ outcome: LayerOutcome, _ entry: PendingEnable?
  ) -> LayerReport {
    LayerReport(
      layer: layer.rawValue, outcome: outcome, state: nil,
      transitionGeneration: entry?.transitionGeneration,
      reservedVersion: entry?.reservedVersion, operationId: entry?.operationId,
      ownerGeneration: entry?.ownerGeneration, ownerEpoch: entry?.ownerEpoch)
  }

  private static func egressReport(
    _ layer: StateLayer, _ outcome: LayerOutcome, _ entry: CloudEgressRecord?
  ) -> LayerReport {
    LayerReport(
      layer: layer.rawValue, outcome: outcome, state: entry?.state,
      transitionGeneration: entry?.retirement?.transitionGeneration ?? entry?.transitionGeneration,
      reservedVersion: entry?.retirement?.reservedVersion ?? entry?.reservedVersion, operationId: entry?.retirement?.operationId,
      ownerGeneration: entry?.retirement?.ownerGeneration ?? entry?.lifetimeOwnerGeneration,
      ownerEpoch: entry?.retirement?.ownerEpoch ?? entry?.lifetimeOwnerEpoch)
  }

  /// What each pending layer holds for [hash], for inspection replies.
  private static func inspectBarrier(_ view: PendingView, _ hash: String) -> [LayerReport] {
    StateLayer.allCases.map { layer in
      switch view.layer(layer) {
      case .unreadable: return pendingReport(layer, .unreadable, nil)
      case .absent: return pendingReport(layer, .absent, nil)
      case let .value(map):
        guard let entry = map.owners[hash] else { return pendingReport(layer, .absent, nil) }
        return pendingReport(layer, .verified, entry)
      }
    }
  }

  /// What each egress layer holds for [hash], for inspection replies.
  private static func inspectEgress(_ hash: String) -> [LayerReport] {
    StateLayer.allCases.map { layer in
      switch egressLayerRead(layer) {
      case .unreadable: return egressReport(layer, .unreadable, nil)
      case .absent: return egressReport(layer, .absent, nil)
      case let .value(map):
        guard let entry = map.owners[hash] else { return egressReport(layer, .absent, nil) }
        return egressReport(layer, .verified, entry)
      }
    }
  }

  private static func transition(
    _ operation: String, _ status: TransitionStatus, op: PendingEnable?,
    barrier: [LayerReport], egress: [LayerReport] = []
  ) -> EnableTransitionResult {
    EnableTransitionResult(
      operation: operation, status: status, operationId: op?.operationId,
      transitionGeneration: op?.transitionGeneration, reservedVersion: op?.reservedVersion,
      ownerGeneration: op?.ownerGeneration, ownerEpoch: op?.ownerEpoch,
      barrier: barrier, egress: egress)
  }

  /// The two empty barrier reports for a phase that could not even compute an
  /// owner hash (no HMAC key exists, so nothing can be bound to an owner yet).
  private static func absentBarrier() -> [LayerReport] {
    StateLayer.allCases.map { pendingReport($0, .absent, nil) }
  }

  private enum BarrierCheck { case bothMatch, partial, noBarrier, conflict, uncertain }

  /// Judges the owner's barrier against the operation a caller claims.
  private static func checkBarrier(_ view: PendingView, _ hash: String, _ expected: PendingEnable) -> BarrierCheck {
    let entries = StateLayer.allCases.map { view.entry(hash, in: $0) }
    if entries.contains(where: { $0 != nil && $0 != expected }) { return .conflict }
    if view.anyUnreadable { return .uncertain }
    switch entries.filter({ $0 == expected }).count {
    case 2: return .bothMatch
    case 0: return .noBarrier
    default: return .partial
    }
  }

  #if CAPTURE_STATE_WRITER
  /// Phase 1. See "PHASES" above. Writes ONLY the pending barrier, each layer from
  /// its own content. A fresh begin never adopts an existing operation; [resume…]
  /// names the original operation (its id AND its original owner epoch) to repair.
  ///
  /// ASR §7.5 SE2 `successor`: a fresh begin only, when the counter is unchanged
  /// since the SE1 receipt and both egress layers hold exactly SE1's OFF lifetime
  /// (marker [successor.evidenceId], bound to the live owner) with no reserved
  /// version above [reservedVersion]. No consent version is reserved here.
  static func beginCloudEgressEnable(
    ownerUid: String, transitionGeneration: Int, reservedVersion: Int,
    resumeOperationId: String? = nil, resumeOwnerEpoch: Int? = nil,
    successor: (evidenceId: String, expectedCounter: Int)? = nil
  ) throws -> EnableTransitionResult {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, transitionGeneration > 0, reservedVersion >= 0,
          (resumeOperationId == nil) == (resumeOwnerEpoch == nil),
          resumeOperationId.map(validOperationId) ?? true,
          (resumeOwnerEpoch ?? 0) >= 0,
          successor == nil || resumeOperationId == nil,
          successor.map({ validOperationId($0.evidenceId) }) ?? true else {
      throw QueueError.encodingFailed
    }
    return try withProtectedWriteLockCounted { prior in
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("begin", .ownerMismatch, op: nil, barrier: absentBarrier())
      }
      let view = pendingView()
      let barrier = inspectBarrier(view, hash)
      // The operation is bound to the COMMITTED native owner. Not committed (an
      // ownerless or deferred publication), or another owner: refuse honestly,
      // never mint the owner here.
      guard let live = try liveOwner(matching: owner) else {
        return transition("begin", .ownerMismatch, op: nil, barrier: barrier)
      }
      if let successor {
        let entries = StateLayer.allCases.map { layer -> CloudEgressRecord? in
          if case let .value(map) = egressLayerRead(layer) { return map.owners[hash] }
          return nil
        }
        guard prior == successor.expectedCounter, !view.holdsAny, !view.anyUnreadable,
              let first = entries[0], entries.allSatisfy({ $0 == first }), first.state == "OFF",
              first.successorOfExpiry == successor.evidenceId, first.retirement == nil,
              first.lifetimeOwnerGeneration == live.generation, first.lifetimeOwnerEpoch == live.epoch,
              first.reservedVersion <= reservedVersion else {
          return transition("begin", .conflict, op: nil, barrier: barrier, egress: inspectEgress(hash))
        }
      }
      // An unreadable layer can hide another owner's barrier or a newer
      // operation, and is never reconstructed: nothing is judged or written.
      if view.anyUnreadable {
        return transition("begin", .uncertain, op: nil, barrier: barrier, egress: inspectEgress(hash))
      }
      let egress = inspectEgress(hash)
      let existing = StateLayer.allCases.compactMap { view.entry(hash, in: $0) }
      let op: PendingEnable
      if let first = existing.first {
        // Only an explicit resume of exactly this operation may touch it.
        guard let resumeId = resumeOperationId, let resumeEpoch = resumeOwnerEpoch,
              existing.allSatisfy({ $0 == first }), first.operationId == resumeId,
              first.transitionGeneration == transitionGeneration,
              first.reservedVersion == reservedVersion, first.ownerEpoch == resumeEpoch else {
          return transition("begin", .conflict, op: first, barrier: barrier, egress: egress)
        }
        guard first.ownerGeneration == live.generation, first.ownerEpoch == live.epoch else {
          return transition("begin", .ownerMismatch, op: first, barrier: barrier, egress: egress)
        }
        op = first
      } else {
        // Resuming something that is not there creates nothing.
        guard resumeOperationId == nil else {
          return transition("begin", .noBarrier, op: nil, barrier: barrier, egress: egress)
        }
        // A new operation needs a readable egress state strictly older than it.
        let stored = StateLayer.allCases.map { egressLayerRead($0) }
        if stored.contains(where: { $0.isUnreadable }) {
          return transition("begin", .uncertain, op: nil, barrier: barrier, egress: egress)
        }
        let newest = stored.compactMap { read -> Int? in
          if case let .value(map) = read { return map.owners[hash]?.transitionGeneration }
          return nil
        }.max()
        if let newest, newest >= transitionGeneration {
          return transition("begin", .stale, op: nil, barrier: barrier, egress: egress)
        }
        op = PendingEnable(
          operationId: try newOperationId(), transitionGeneration: transitionGeneration,
          reservedVersion: reservedVersion, ownerGeneration: live.generation,
          ownerEpoch: live.epoch)
      }
      // Each layer is rebuilt from ITS OWN readable content only (other owners'
      // entries stay exactly as that layer holds them); a layer that already holds
      // exactly the operation is not rewritten.
      var targets: [StateLayer: PendingEnableMap] = [:]
      var wrote: [StateLayer: Bool] = [:]
      for layer in StateLayer.allCases {
        var target = PendingEnableMap()
        if case let .value(map) = view.layer(layer) { target = map }
        let unchanged = target.owners[hash] == op
        target.owners[hash] = op
        targets[layer] = target
        if unchanged {
          wrote[layer] = true
          continue
        }
        guard let data = try? JSONEncoder().encode(target) else { throw QueueError.encodingFailed }
        wrote[layer] = writeStateLayer(.pending, layer, data)
      }
      let after = pendingView()
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        switch after.layer(layer) {
        case let .value(map) where map == targets[layer]: return pendingReport(layer, .verified, op)
        case let .value(map): return pendingReport(layer, wrote[layer] == true ? .mismatch : .writeFailed, map.owners[hash])
        case .absent: return pendingReport(layer, wrote[layer] == true ? .mismatch : .writeFailed, nil)
        case .unreadable: return pendingReport(layer, wrote[layer] == true ? .unreadable : .writeFailed, nil)
        }
      }
      let verified = reports.allSatisfy { $0.outcome == .verified }
      var reply = transition("begin", verified ? .done : .incomplete, op: op, barrier: reports, egress: inspectEgress(hash))
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Phase 2. Writes ON(generation, version) into each egress layer under the
  /// exact pending operation while its owner lifecycle is still the live one,
  /// then reads each layer back. The barrier stays.
  ///
  /// ASR §7.5 SE3/SE4: with [expectedCounter] (writeOn and complete) the phase
  /// also requires the counter unchanged since the caller's previous receipt.
  static func writeCloudEgressEnableOn(
    ownerUid: String, operationId: String, transitionGeneration: Int, reservedVersion: Int,
    ownerGeneration: Int, ownerEpoch: Int, expectedCounter: Int? = nil
  ) throws -> EnableTransitionResult {
    let (owner, expected) = try boundOperation(
      ownerUid: ownerUid, operationId: operationId,
      generation: transitionGeneration, version: reservedVersion,
      ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
    return try withProtectedWriteLockCounted { prior in
      guard expectedCounter == nil || prior == expectedCounter else {
        return transition("writeOn", .conflict, op: expected, barrier: absentBarrier())
      }
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("writeOn", .noBarrier, op: expected, barrier: absentBarrier())
      }
      let view = pendingView()
      let barrier = inspectBarrier(view, hash)
      switch checkBarrier(view, hash, expected) {
      case .bothMatch: break
      case .partial: return transition("writeOn", .incomplete, op: expected, barrier: barrier)
      case .noBarrier: return transition("writeOn", .noBarrier, op: expected, barrier: barrier)
      case .conflict: return transition("writeOn", .conflict, op: expected, barrier: barrier)
      case .uncertain: return transition("writeOn", .uncertain, op: expected, barrier: barrier)
      }
      guard let live = try liveOwner(matching: owner),
            live.generation == expected.ownerGeneration, live.epoch == expected.ownerEpoch else {
        return transition("writeOn", .ownerMismatch, op: expected, barrier: barrier)
      }
      let stored = StateLayer.allCases.map { egressLayerRead($0) }
      let before = inspectEgress(hash)
      if stored.contains(where: { $0.isUnreadable }) {
        return transition("writeOn", .uncertain, op: expected, barrier: barrier, egress: before)
      }
      let lifecycleEntries = stored.compactMap { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      // N-R2: a retired, half-bound or differently bound entry in EITHER layer
      // refuses before any write. Entries with no lifecycle field (legacy/absent)
      // are never a source of metadata: they are promoted below.
      if lifecycleEntries.contains(where: {
        $0.retirement != nil ||
        (($0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil) &&
          ($0.lifetimeOwnerGeneration != ownerGeneration || $0.lifetimeOwnerEpoch != ownerEpoch))
      }) {
        return transition("writeOn", .ownerMismatch, op: expected, barrier: barrier, egress: before)
      }
      // Every new ON is explicitly bound to the verified operation's owner
      // generation/epoch (proven live above), regardless of layer order or of
      // whether the old entries were legacy, bound, or absent. Mixed legacy/bound
      // OFF inputs are uniformly PROMOTED to this exact bound ON in both layers
      // (never stripped, same result in both orientations).
      let target = CloudEgressRecord(
        state: "ON", transitionGeneration: transitionGeneration, reservedVersion: reservedVersion,
        lifetimeOwnerGeneration: expected.ownerGeneration,
        lifetimeOwnerEpoch: expected.ownerEpoch)
      for read in stored {
        guard case let .value(map) = read, let entry = map.owners[hash] else { continue }
        // Older entries are replaced; a newer generation or a same-generation
        // record other than this exact ON blocks the write.
        if entry.transitionGeneration > transitionGeneration
          || entry.reservedVersion > reservedVersion
          || (entry.transitionGeneration == transitionGeneration && entry != target) {
          return transition("writeOn", .stale, op: expected, barrier: barrier, egress: before)
        }
      }
      // Each layer keeps its own other owners' entries exactly; none is copied
      // from one layer into the other.
      var targets: [StateLayer: CloudEgressMap] = [:]
      var wrote: [StateLayer: Bool] = [:]
      for (layer, read) in zip(StateLayer.allCases, stored) {
        var next = CloudEgressMap()
        if case let .value(map) = read { next = map }
        next.owners[hash] = target
        targets[layer] = next
        guard let data = try? JSONEncoder().encode(next) else { throw QueueError.encodingFailed }
        wrote[layer] = writeStateLayer(.egress, layer, data)
      }
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        switch egressLayerRead(layer) {
        case let .value(map) where map == targets[layer]: return egressReport(layer, .verified, target)
        case let .value(map): return egressReport(layer, wrote[layer] == true ? .mismatch : .writeFailed, map.owners[hash])
        case .absent: return egressReport(layer, wrote[layer] == true ? .mismatch : .writeFailed, nil)
        case .unreadable: return egressReport(layer, wrote[layer] == true ? .unreadable : .writeFailed, nil)
        }
      }
      let verified = reports.allSatisfy { $0.outcome == .verified }
      var reply = transition("writeOn", verified ? .done : .incomplete, op: expected, barrier: barrier, egress: reports)
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// N: retires an outgoing lifetime even AFTER pending completion cleared.
  /// Ordered against finish/admission by the same flock; no transport is awaited.
  ///
  /// ASR §7.2: with [expirySessionLifecycle] (cause `sessionExpiry`) the OFF also
  /// carries expiry evidence, but ONLY when, before writing, both layers agree on
  /// an ON with no retirement bound to exactly this owner generation/epoch, with
  /// no pending enable and no removal barrier. An identical repeat is a no-op.
  /// Any other prior state revokes exactly as without the argument.
  static func revokeCaptureAuthorizationLifetime(
    ownerUid: String, operationId: String, transitionGeneration: Int, reservedVersion: Int,
    ownerGeneration: Int, ownerEpoch: Int, expirySessionLifecycle: Int? = nil
  ) throws -> EnableTransitionResult {
    let (owner, expected) = try boundOperation(ownerUid: ownerUid, operationId: operationId,
      generation: transitionGeneration, version: reservedVersion,
      ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
    return try withProtectedWriteLock {
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("revoke", .ownerMismatch, op: expected, barrier: absentBarrier())
      }
      let pending = pendingView()
      let barrier = inspectBarrier(pending, hash)
      let before = inspectEgress(hash)
      // No stale retry may mutate a newly published account/lifetime.
      guard let active = try readActiveOwner(), active.uid == owner,
            active.generation == ownerGeneration,
            let defaults, snapshotCounter(ownerEpochKey, in: defaults) == ownerEpoch else {
        return transition("revoke", .ownerMismatch, op: expected, barrier: barrier, egress: before)
      }
      let reads = StateLayer.allCases.map { egressLayerRead($0) }
      if pending.anyUnreadable || reads.contains(where: { $0.isUnreadable }) {
        return transition("revoke", .uncertain, op: expected, barrier: barrier, egress: before)
      }
      for read in reads {
        if case let .value(map) = read, let entry = map.owners[hash] {
          if let retirement = entry.retirement, retirement != expected {
            return transition("revoke", .conflict, op: expected, barrier: barrier, egress: before)
          }
          // A1: retirement covers EVERY enable transition (any transition generation,
          // including a completed ON with no pending barrier) of the lifecycle named
          // by the captured uid/hash + owner generation + owner epoch, which the
          // guard above proved is still the live one. Only an entry bound to a
          // DIFFERENT owner generation/epoch is a newer lifecycle and is never
          // modified by this stale retirement.
          if entry.retirement == nil
              && (entry.lifetimeOwnerGeneration.map({ $0 != ownerGeneration }) == true
              || entry.lifetimeOwnerEpoch.map({ $0 != ownerEpoch }) == true) {
            return transition("revoke", .stale, op: expected, barrier: barrier, egress: before)
          }
        }
      }
      var evidence: ExpiryEvidence?
      if let lifecycle = expirySessionLifecycle {
        let entries = reads.map { read -> CloudEgressRecord? in
          if case let .value(map) = read { return map.owners[hash] }
          return nil
        }
        if let first = entries[0], entries.allSatisfy({ $0 == first }),
           first.retirement == expected, let held = first.expiryEvidence,
           held.ownerGeneration == ownerGeneration, held.ownerEpoch == ownerEpoch,
           held.sessionLifecycle == lifecycle {
          var reply = transition("revoke", .done, op: expected, barrier: barrier, egress: before)
          reply.expiryEvidence = held
          reply.mutationCounter = egressMutationCounter()
          return reply
        }
        if let first = entries[0], entries.allSatisfy({ $0 == first }),
           first.state == "ON", first.retirement == nil,
           first.lifetimeOwnerGeneration == ownerGeneration, first.lifetimeOwnerEpoch == ownerEpoch,
           !pending.holds(hash), try readBarrier() == nil {
          evidence = ExpiryEvidence(evidenceId: try newOperationId(), ownerGeneration: ownerGeneration,
            ownerEpoch: ownerEpoch, sessionLifecycle: lifecycle)
        }
      }
      var targets: [StateLayer: CloudEgressMap] = [:]
      var writes: [StateLayer: Bool] = [:]
      for (layer, read) in zip(StateLayer.allCases, reads) {
        var map = CloudEgressMap()
        if case let .value(existing) = read { map = existing }
        let old = map.owners[hash]
        map.owners[hash] = CloudEgressRecord(state: "OFF",
          transitionGeneration: max(old?.transitionGeneration ?? 0, transitionGeneration),
          reservedVersion: max(old?.reservedVersion ?? 0, reservedVersion),
          lifetimeOwnerGeneration: ownerGeneration, lifetimeOwnerEpoch: ownerEpoch,
          retirement: expected, expiryEvidence: evidence)
        targets[layer] = map
        guard let data = try? JSONEncoder().encode(map) else { throw QueueError.encodingFailed }
        writes[layer] = writeStateLayer(.egress, layer, data)
      }
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        switch egressLayerRead(layer) {
        case let .value(map) where map == targets[layer]:
          return egressReport(layer, .verified, map.owners[hash])
        case let .value(map):
          return egressReport(layer, writes[layer] == true ? .mismatch : .writeFailed, map.owners[hash])
        case .absent: return egressReport(layer, .writeFailed, nil)
        case .unreadable: return egressReport(layer, .unreadable, nil)
        }
      }
      var reply = transition("revoke", reports.allSatisfy { $0.outcome == .verified } ? .done : .incomplete,
        op: expected, barrier: barrier, egress: reports)
      if reply.status == .done { reply.expiryEvidence = evidence }
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  struct RestrictiveOwnerPublication {
    let status: TransitionStatus
    let owner: OwnerRecord?
    let ownerEpoch: Int
    let egress: [LayerReport]
    /// ASR §7.4: the counter after this write (SE1 receipts).
    var mutationCounter: Int? = nil
  }

  #if CAPTURE_STATE_WRITER
  /// Explicit fresh restrictive publication; never clears a pending operation.
  /// A retired active same-UID owner obtains a NEW generation only after both
  /// existing egress layers verify restrictive lifetime evidence.
  ///
  /// `recover` (explicit Cloud enable over a version frontier ahead of the local
  /// consent history): only when BOTH layers still hold exactly the inspected OFF
  /// record (same transition generation, reserved version and lifetime
  /// generation/epoch, or all unbound), no lifetime retirement, and `version` is strictly above that reserved version. Any other
  /// state (ON, DISABLING, unbound ahead, a disagreeing or absent layer, a
  /// changed frontier) is refused with nothing written. It never lowers a version
  /// or a transition generation.
  ///
  /// `expectedOffCopies` (explicit consent only): independently read OFF
  /// snapshots must still match both physical layers exactly under this lock.
  /// A fresh generation above every stored lifetime is published restrictive.
  ///
  /// `expectedRetiredCopies` (explicit consent only): the independently read
  /// snapshot of a RETIRED OFF (a lifetime fence's record, or a verified absence
  /// beside one) must still match both physical layers exactly under this lock,
  /// every stored entry must be OFF under one and the same retirement, and
  /// `version` must be strictly above every stored and retired version. A fresh
  /// generation above every stored and retired lifetime is published
  /// restrictive. Like every writer other than the expiry mint, it drops expiry
  /// evidence (§7.3); the mutation counter moves, so a successor chain sees it.
  ///
  /// ASR §7.5 SE1 `successorOf`: only when the counter is unchanged since the
  /// caller's evidence read, the same uid is the active owner, and both layers
  /// hold exactly that expiry evidence bound to the active owner generation and
  /// [expectedEpoch]. The new OFF lifetime records the consumed evidence id.
  static func publishRestrictiveCaptureOwner(
    uid: String, version: Int, expectedEpoch: Int,
    recover: (transitionGeneration: Int, reservedVersion: Int,
              lifetimeOwnerGeneration: Int?, lifetimeOwnerEpoch: Int?)? = nil,
    successorOf: (evidenceId: String, expectedCounter: Int)? = nil,
    expectedOffCopies: [LayerReport]? = nil,
    expectedRetiredCopies: [LayerReport]? = nil
  ) throws -> RestrictiveOwnerPublication {
    let owner = normalizedUID(uid)
    guard !owner.isEmpty, version >= 0, expectedEpoch >= 0,
          recover == nil || successorOf == nil,
          expectedOffCopies == nil || (recover == nil && successorOf == nil),
          expectedRetiredCopies == nil
            || (recover == nil && successorOf == nil && expectedOffCopies == nil),
          successorOf.map({ validOperationId($0.evidenceId) }) ?? true else {
      throw QueueError.encodingFailed
    }
    return try withProtectedWriteLockCounted { prior in
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      guard let defaults, snapshotCounter(ownerEpochKey, in: defaults) == expectedEpoch,
            let lastGeneration = snapshotCounter(ownerGenerationKey, in: defaults) else {
        throw QueueError.ownerChanged
      }
      let active = try readActiveOwner()
      // A different current owner is not an explicit readmission invitation.
      guard active == nil || active?.uid == owner else { throw QueueError.ownerChanged }
      let hash = try uidHash(owner)
      let pending = pendingView()
      let reads = StateLayer.allCases.map { egressLayerRead($0) }
      if pending.anyUnreadable || reads.contains(where: { $0.isUnreadable }) {
        return RestrictiveOwnerPublication(status: .uncertain, owner: nil,
          ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
      }
      if pending.holds(hash) {
        return RestrictiveOwnerPublication(status: .conflict, owner: nil,
          ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
      }
      let entries = reads.map { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      if entries.contains(where: { ($0?.reservedVersion ?? 0) > version }) {
        return RestrictiveOwnerPublication(status: .stale, owner: nil,
          ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
      }
      if let expectedOffCopies {
        // Explicit consent only. Compare both physical snapshots again while
        // holding the write lock. No retirement, pending operation, unreadable
        // copy or intervening state change is normalized by this repair.
        guard expectedOffCopies.count == 2,
              expectedOffCopies.map({ $0.layer }) == ["file", "keychain"],
              inspectEgress(hash) == expectedOffCopies,
              entries.contains(where: { $0 != nil }),
              entries.allSatisfy({
                $0 == nil || ($0!.state == "OFF" && $0!.retirement == nil
                  && $0!.reservedVersion < version)
              }) else {
          return RestrictiveOwnerPublication(status: .conflict, owner: nil,
            ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
        }
      }
      if let expectedRetiredCopies {
        // Explicit consent only. The retired snapshot is compared again while
        // holding the write lock; anything else (an ON, a DISABLING, an OFF
        // without retirement, two retirements, a changed or lower-versioned
        // copy) is refused with nothing written.
        let stored = entries.compactMap { $0 }
        guard expectedRetiredCopies.count == 2,
              expectedRetiredCopies.map({ $0.layer }) == ["file", "keychain"],
              inspectEgress(hash) == expectedRetiredCopies,
              let fence = stored.first?.retirement,
              stored.allSatisfy({
                $0.state == "OFF" && $0.retirement == fence
                  && max($0.reservedVersion, fence.reservedVersion) < version
              }) else {
          return RestrictiveOwnerPublication(status: .conflict, owner: nil,
            ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
        }
      }
      if let successorOf {
        guard prior == successorOf.expectedCounter, let active, active.uid == owner,
              let first = entries[0], entries.allSatisfy({ $0 == first }), first.state == "OFF",
              let evidence = first.expiryEvidence, evidence.evidenceId == successorOf.evidenceId,
              evidence.ownerGeneration == active.generation, evidence.ownerEpoch == expectedEpoch else {
          return RestrictiveOwnerPublication(status: .conflict, owner: nil,
            ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
        }
      }
      if let recover {
        let agreed = entries.count == StateLayer.allCases.count && entries.allSatisfy {
          $0 != nil && $0!.state == "OFF" && $0!.retirement == nil
            && $0!.transitionGeneration == recover.transitionGeneration
            && $0!.reservedVersion == recover.reservedVersion
            // The lifetime evidence must agree across the layers AND with the
            // inspected record; both absent (the agreed unbound legacy record)
            // is explicit, any disagreement is refused.
            && $0!.lifetimeOwnerGeneration == recover.lifetimeOwnerGeneration
            && $0!.lifetimeOwnerEpoch == recover.lifetimeOwnerEpoch
        }
        guard agreed, version > recover.reservedVersion else {
          return RestrictiveOwnerPublication(status: .conflict, owner: nil,
            ownerEpoch: expectedEpoch, egress: inspectEgress(hash))
        }
      }
      let retired = entries.contains { $0?.retirement != nil }
      // Current live publication retries preserve generation. Retirement requires
      // a new lifetime; old pending completion is never acknowledged here.
      let retiredGenerations = entries.compactMap { $0?.retirement?.ownerGeneration }
      let unfinishedGeneration = (entries.compactMap { $0?.lifetimeOwnerGeneration } + retiredGenerations).max() ?? 0
      // A genuinely NEW lifetime is allocated strictly above every generation the
      // counter, the active owner and the durable lifetime/retirement evidence
      // know (a reset counter must not hand out a retired generation again).
      let generation = (expectedOffCopies == nil && active != nil && !retired && unfinishedGeneration <= active!.generation)
        ? active!.generation
        : max(lastGeneration, active?.generation ?? 0, unfinishedGeneration) + 1
      let transitionGeneration = entries.compactMap { $0?.transitionGeneration }.max() ?? 0
      let target = CloudEgressRecord(state: "OFF", transitionGeneration: transitionGeneration,
        reservedVersion: version, lifetimeOwnerGeneration: generation, lifetimeOwnerEpoch: expectedEpoch,
        successorOfExpiry: successorOf?.evidenceId)
      var targets: [StateLayer: CloudEgressMap] = [:]
      var writes: [StateLayer: Bool] = [:]
      for (layer, read) in zip(StateLayer.allCases, reads) {
        var map = CloudEgressMap()
        if case let .value(existing) = read { map = existing }
        map.owners[hash] = target
        targets[layer] = map
        guard let data = try? JSONEncoder().encode(map) else { throw QueueError.encodingFailed }
        writes[layer] = writeStateLayer(.egress, layer, data)
      }
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        switch egressLayerRead(layer) {
        case let .value(map) where map == targets[layer]: return egressReport(layer, .verified, target)
        case let .value(map): return egressReport(layer, writes[layer] == true ? .mismatch : .writeFailed, map.owners[hash])
        case .absent: return egressReport(layer, .writeFailed, nil)
        case .unreadable: return egressReport(layer, .unreadable, nil)
        }
      }
      guard reports.allSatisfy({ $0.outcome == .verified }) else {
        return RestrictiveOwnerPublication(status: .incomplete, owner: nil,
          ownerEpoch: expectedEpoch, egress: reports)
      }
      writeConsentMirrorEntry(hash: hash, mirror: ConsentMirrorValue(cloud: false, ai: false, version: version))
      guard let mirror = consentMirror(forHash: hash), !mirror.cloud, !mirror.ai else {
        return RestrictiveOwnerPublication(status: .incomplete, owner: nil,
          ownerEpoch: expectedEpoch, egress: reports)
      }
      let record = OwnerRecord(uid: owner, uidHash: hash, generation: generation)
      guard let data = try? JSONEncoder().encode(record) else { throw QueueError.encodingFailed }
      try writeKeychain(data, forKey: activeOwnerKC)
      try writeKeychain(Data(hash.utf8), forKey: lastAdmittedHashKC)
      defaults.set(generation, forKey: ownerGenerationKey)
      defaults.synchronize()
      guard try readActiveOwner() == record,
            snapshotCounter(ownerEpochKey, in: defaults) == expectedEpoch,
            snapshotCounter(ownerGenerationKey, in: defaults) == generation else {
        return RestrictiveOwnerPublication(status: .incomplete, owner: nil,
          ownerEpoch: expectedEpoch, egress: reports)
      }
      return RestrictiveOwnerPublication(status: .done, owner: record,
        ownerEpoch: expectedEpoch, egress: reports, mutationCounter: egressMutationCounter())
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Phase 3. Conditional, per-layer compensation of an operation the barrier
  /// PROVES. Missing, unreadable or conflicting barrier evidence is never
  /// permission to write, and the proof is per layer: an egress layer is rewritten
  /// only if the same layer's barrier entry is exactly the expected operation.
  /// Without its own proof a layer holding the operation's ON is reported
  /// `notOurs` (unresolved, status `incomplete`, denial kept). Allowed during a
  /// Remove-data barrier and needs no live owner (it only restricts). Never
  /// removes the pending barrier.
  static func restrictCloudEgressEnable(
    ownerUid: String, operationId: String, transitionGeneration: Int, reservedVersion: Int,
    ownerGeneration: Int, ownerEpoch: Int
  ) throws -> EnableTransitionResult {
    let (owner, expected) = try boundOperation(
      ownerUid: ownerUid, operationId: operationId,
      generation: transitionGeneration, version: reservedVersion,
      ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
    return try withProtectedWriteLock {
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("restrict", .noBarrier, op: expected, barrier: absentBarrier())
      }
      let view = pendingView()
      let barrier = inspectBarrier(view, hash)
      switch checkBarrier(view, hash, expected) {
      case .bothMatch, .partial: break
      case .noBarrier:
        return transition("restrict", .noBarrier, op: expected, barrier: barrier, egress: inspectEgress(hash))
      case .conflict:
        return transition("restrict", .conflict, op: expected, barrier: barrier, egress: inspectEgress(hash))
      case .uncertain:
        return transition("restrict", .uncertain, op: expected, barrier: barrier, egress: inspectEgress(hash))
      }
      var clean = true
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        switch egressLayerRead(layer) {
        case .unreadable:
          clean = false
          return egressReport(layer, .unreadable, nil)
        case .absent:
          return egressReport(layer, .absent, nil)
        case let .value(map):
          guard let entry = map.owners[hash] else { return egressReport(layer, .absent, nil) }
          if entry.lifetimeOwnerGeneration.map({ $0 != ownerGeneration }) == true
              || entry.lifetimeOwnerEpoch.map({ $0 != ownerEpoch }) == true
              || entry.retirement.map({ $0 != expected }) == true {
            clean = false
            return egressReport(layer, .notOurs, entry)
          }
          if entry.transitionGeneration > transitionGeneration {
            return egressReport(layer, .superseded, entry)
          }
          if entry.state == "ON", entry.transitionGeneration == transitionGeneration,
             entry.reservedVersion == reservedVersion, entry.retirement == nil {
            // PER-LAYER PROOF: this egress layer may be rewritten only when the
            // SAME layer's pending barrier holds exactly the expected operation
            // (owner, operation, generation, version, owner generation, epoch).
            // Evidence in the other layer authorizes nothing here: the ON is left
            // byte-for-byte untouched and reported unresolved.
            guard view.entry(hash, in: layer) == expected else {
              clean = false
              return egressReport(layer, .notOurs, entry)
            }
            let off = CloudEgressRecord(state: "OFF", transitionGeneration: transitionGeneration,
              reservedVersion: reservedVersion,
              lifetimeOwnerGeneration: entry.lifetimeOwnerGeneration,
              lifetimeOwnerEpoch: entry.lifetimeOwnerEpoch, retirement: entry.retirement)
            var restricted = map
            restricted.owners[hash] = off
            guard let data = try? JSONEncoder().encode(restricted) else {
              clean = false
              return egressReport(layer, .writeFailed, entry)
            }
            let wrote = writeStateLayer(.egress, layer, data)
            switch egressLayerRead(layer) {
            case let .value(readBack) where readBack == restricted:
              return egressReport(layer, .restricted, off)
            case let .value(readBack):
              clean = false
              return egressReport(layer, wrote ? .mismatch : .writeFailed, readBack.owners[hash])
            case .absent:
              clean = false
              return egressReport(layer, wrote ? .mismatch : .writeFailed, nil)
            case .unreadable:
              clean = false
              return egressReport(layer, wrote ? .unreadable : .writeFailed, nil)
            }
          }
          if entry.state != "ON" { return egressReport(layer, .alreadyRestrictive, entry) }
          clean = false
          return egressReport(layer, .notOurs, entry)
        }
      }
      return transition("restrict", clean ? .done : .incomplete, op: expected, barrier: barrier, egress: reports)
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// Phase 4. `complete` (needs verified ON in both layers and the operation's
  /// owner lifecycle still live) or `abandon` (needs NO ON for the owner in
  /// either layer): the only ways the barrier is lifted, and only by the
  /// operation's full binding.
  static func finishCloudEgressEnable(
    ownerUid: String, operationId: String, transitionGeneration: Int, reservedVersion: Int,
    ownerGeneration: Int, ownerEpoch: Int, abandon: Bool, expectedCounter: Int? = nil
  ) throws -> EnableTransitionResult {
    let (owner, expected) = try boundOperation(
      ownerUid: ownerUid, operationId: operationId,
      generation: transitionGeneration, version: reservedVersion,
      ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
    let name = abandon ? "abandon" : "complete"
    guard expectedCounter == nil || !abandon else { throw QueueError.encodingFailed }
    beforeLifetimeFinishLock?()
    return try withProtectedWriteLockCounted { prior in
      guard expectedCounter == nil || prior == expectedCounter else {
        return transition(name, .conflict, op: expected, barrier: absentBarrier())
      }
      // Re-read under the flock: a Remove-data barrier and the live owner.
      if !abandon { guard try readBarrier() == nil else { throw QueueError.barrierActive } }
      guard let hash = try keyedOwnerHash(owner) else {
        return transition(name, .noBarrier, op: expected, barrier: absentBarrier())
      }
      let view = pendingView()
      let barrier = inspectBarrier(view, hash)
      let stored = StateLayer.allCases.map { egressLayerRead($0) }
      let egress = inspectEgress(hash)
      switch checkBarrier(view, hash, expected) {
      case .bothMatch, .partial: break
      case .noBarrier: return transition(name, .noBarrier, op: expected, barrier: barrier, egress: egress)
      case .conflict: return transition(name, .conflict, op: expected, barrier: barrier, egress: egress)
      case .uncertain: return transition(name, .uncertain, op: expected, barrier: barrier, egress: egress)
      }
      if !abandon {
        // A queued complete from an older lifecycle (logout, readmission, another
        // owner in between) is refused and clears nothing.
        guard let live = try liveOwner(matching: owner),
              live.generation == expected.ownerGeneration, live.epoch == expected.ownerEpoch else {
          return transition(name, .ownerMismatch, op: expected, barrier: barrier, egress: egress)
        }
      }
      if stored.contains(where: { $0.isUnreadable }) {
        return transition(name, .uncertain, op: expected, barrier: barrier, egress: egress)
      }
      let entries = stored.map { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      let lifecycleEntries = stored.compactMap { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      if lifecycleEntries.contains(where: {
        ($0.retirement != nil && (!abandon || $0.retirement != expected)) ||
        (($0.lifetimeOwnerGeneration != nil || $0.lifetimeOwnerEpoch != nil) &&
          ($0.lifetimeOwnerGeneration != ownerGeneration || $0.lifetimeOwnerEpoch != ownerEpoch))
      }) {
        return transition(name, .ownerMismatch, op: expected, barrier: barrier, egress: egress)
      }
      // N-R2: the only ON that completes is the exact bound one writeOn produced,
      // built from the verified operation, never inferred from old entry order.
      let target = CloudEgressRecord(
        state: "ON", transitionGeneration: transitionGeneration, reservedVersion: reservedVersion,
        lifetimeOwnerGeneration: expected.ownerGeneration,
        lifetimeOwnerEpoch: expected.ownerEpoch)
      if abandon {
        // No ON of ANY generation may remain: a prior grant is not proven still
        // authorized for this lifecycle, so the denial stays until it is restricted.
        if entries.contains(where: { $0?.state == "ON" }) {
          return transition(name, .incomplete, op: expected, barrier: barrier, egress: egress)
        }
      } else {
        if entries.contains(where: { ($0?.transitionGeneration ?? 0) > transitionGeneration }) {
          return transition(name, .stale, op: expected, barrier: barrier, egress: egress)
        }
        guard entries.allSatisfy({ $0 == target }) else {
          return transition(name, .incomplete, op: expected, barrier: barrier, egress: egress)
        }
      }
      var cleared = true
      let reports = StateLayer.allCases.map { layer -> LayerReport in
        guard case let .value(map) = view.layer(layer), map.owners[hash] != nil else {
          return pendingReport(layer, .absent, nil)
        }
        var remaining = map
        remaining.owners.removeValue(forKey: hash)
        let wrote: Bool
        if remaining.owners.isEmpty {
          wrote = removeStateLayer(.pending, layer)
        } else if let data = try? JSONEncoder().encode(remaining) {
          wrote = writeStateLayer(.pending, layer, data)
        } else {
          wrote = false
        }
        switch pendingLayerRead(layer) {
        case .absent where remaining.owners.isEmpty:
          return pendingReport(layer, .cleared, nil)
        case let .value(readBack) where readBack == remaining && !remaining.owners.isEmpty:
          return pendingReport(layer, .cleared, nil)
        case let .value(readBack):
          cleared = false
          return pendingReport(layer, wrote ? .mismatch : .writeFailed, readBack.owners[hash])
        case .absent:
          cleared = false
          return pendingReport(layer, wrote ? .mismatch : .writeFailed, nil)
        case .unreadable:
          cleared = false
          return pendingReport(layer, wrote ? .unreadable : .writeFailed, nil)
        }
      }
      var reply = transition(name, cleared ? .done : .incomplete, op: expected, barrier: reports, egress: egress)
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  // MARK: Automatic session recovery evidence (ASR §7.2–§7.5)

  /// One locked, read-only snapshot of everything ASR's native predicate needs.
  /// [kind] is `expiryEvidence` (E2-a), `liveOn` (E2-b) or `none`; the session
  /// lifecycle comparison is Dart's. No uid, key or content appears here.
  struct RecoveryEvidenceSnapshot: Equatable {
    let kind: String
    let ownerGeneration: Int?
    let ownerEpoch: Int?
    let record: CloudEgressRecord?
    let mutationCounter: Int?
  }

  static func inspectRecoveryEvidence(ownerUid: String) throws -> RecoveryEvidenceSnapshot {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty else { throw QueueError.encodingFailed }
    return try withQueueLock {
      let counter = egressMutationCounter()
      func none(_ generation: Int? = nil, _ epoch: Int? = nil, _ record: CloudEgressRecord? = nil)
        -> RecoveryEvidenceSnapshot {
        RecoveryEvidenceSnapshot(kind: "none", ownerGeneration: generation, ownerEpoch: epoch,
          record: record, mutationCounter: counter)
      }
      guard let hash = try keyedOwnerHash(owner), let store = defaults,
            let epoch = snapshotCounter(ownerEpochKey, in: store),
            let active = try readActiveOwner(), active.uid == owner,
            barrierProvenAbsent() else { return none() }
      let pending = pendingView()
      let entries = StateLayer.allCases.map { layer -> CloudEgressRecord?? in
        switch egressLayerRead(layer) {
        case let .value(map): return .some(map.owners[hash])
        case .absent: return .some(nil)
        case .unreadable: return nil
        }
      }
      guard !pending.anyUnreadable, !pending.holdsAny,
            let file = entries[0], let record = file, entries.allSatisfy({ $0 == .some(record) }) else {
        return none(active.generation, epoch)
      }
      if record.state == "OFF", record.retirement != nil, let evidence = record.expiryEvidence,
         evidence.ownerGeneration == active.generation, evidence.ownerEpoch == epoch {
        return RecoveryEvidenceSnapshot(kind: "expiryEvidence", ownerGeneration: active.generation,
          ownerEpoch: epoch, record: record, mutationCounter: counter)
      }
      if record.state == "ON", record.retirement == nil,
         record.lifetimeOwnerGeneration == active.generation, record.lifetimeOwnerEpoch == epoch {
        return RecoveryEvidenceSnapshot(kind: "liveOn", ownerGeneration: active.generation,
          ownerEpoch: epoch, record: record, mutationCounter: counter)
      }
      return none(active.generation, epoch, record)
    }
  }

  /// A removal barrier that cannot be read is NOT absent.
  private static func barrierProvenAbsent() -> Bool {
    do { return try readBarrier() == nil } catch { return false }
  }

  /// §7.4: true only when no protected native write happened since [expectedCounter].
  static func confirmRecoveryEvidence(expectedCounter: Int) throws -> Bool {
    try withQueueLock { egressMutationCounter() == expectedCounter }
  }

  #if CAPTURE_STATE_WRITER
  /// Writes [target] for [hash] into each layer (other owners untouched) and
  /// reports the read-back. Used only by the ASR transitions below.
  private static func writeEgressRecord(
    _ hash: String, _ reads: [LayerRead<CloudEgressMap>], _ target: CloudEgressRecord
  ) throws -> [LayerReport] {
    var targets: [StateLayer: CloudEgressMap] = [:]
    var writes: [StateLayer: Bool] = [:]
    for (layer, read) in zip(StateLayer.allCases, reads) {
      var map = CloudEgressMap()
      if case let .value(existing) = read { map = existing }
      map.owners[hash] = target
      targets[layer] = map
      guard let data = try? JSONEncoder().encode(map) else { throw QueueError.encodingFailed }
      writes[layer] = writeStateLayer(.egress, layer, data)
    }
    return StateLayer.allCases.map { layer -> LayerReport in
      switch egressLayerRead(layer) {
      case let .value(map) where map == targets[layer]: return egressReport(layer, .verified, target)
      case let .value(map): return egressReport(layer, writes[layer] == true ? .mismatch : .writeFailed, map.owners[hash])
      case .absent: return egressReport(layer, .writeFailed, nil)
      case .unreadable: return egressReport(layer, .unreadable, nil)
      }
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// §7.6 E2-b: the conditional expiry retirement of a still-ON lifetime left by
  /// a previous process. Only when the counter is unchanged since the caller's
  /// inspection and both layers hold exactly that ON bound to the live owner,
  /// with no pending enable and no removal barrier. Writes OFF + retirement +
  /// expiry evidence; any other state writes nothing.
  static func mintExpiryEvidenceForLiveOn(
    ownerUid: String, ownerGeneration: Int, ownerEpoch: Int, transitionGeneration: Int,
    reservedVersion: Int, sessionLifecycle: Int, expectedCounter: Int
  ) throws -> EnableTransitionResult {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, ownerGeneration > 0, ownerEpoch >= 0, transitionGeneration >= 0,
          reservedVersion >= 0, sessionLifecycle >= 0 else { throw QueueError.encodingFailed }
    return try withProtectedWriteLockCounted { prior in
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("mintExpiry", .ownerMismatch, op: nil, barrier: absentBarrier())
      }
      let pending = pendingView()
      let barrier = inspectBarrier(pending, hash)
      let before = inspectEgress(hash)
      guard prior == expectedCounter else {
        return transition("mintExpiry", .conflict, op: nil, barrier: barrier, egress: before)
      }
      guard let active = try readActiveOwner(), active.uid == owner, active.generation == ownerGeneration,
            let store = defaults, snapshotCounter(ownerEpochKey, in: store) == ownerEpoch else {
        return transition("mintExpiry", .ownerMismatch, op: nil, barrier: barrier, egress: before)
      }
      let reads = StateLayer.allCases.map { egressLayerRead($0) }
      if pending.anyUnreadable || reads.contains(where: { $0.isUnreadable }) {
        return transition("mintExpiry", .uncertain, op: nil, barrier: barrier, egress: before)
      }
      let expected = CloudEgressRecord(state: "ON", transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion, lifetimeOwnerGeneration: ownerGeneration,
        lifetimeOwnerEpoch: ownerEpoch)
      let entries = reads.map { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      guard try readBarrier() == nil, !pending.holds(hash),
            entries.allSatisfy({ $0 == expected }) else {
        return transition("mintExpiry", .conflict, op: nil, barrier: barrier, egress: before)
      }
      let op = PendingEnable(operationId: try newOperationId(), transitionGeneration: transitionGeneration,
        reservedVersion: reservedVersion, ownerGeneration: ownerGeneration, ownerEpoch: ownerEpoch)
      let evidence = ExpiryEvidence(evidenceId: try newOperationId(), ownerGeneration: ownerGeneration,
        ownerEpoch: ownerEpoch, sessionLifecycle: sessionLifecycle)
      let reports = try writeEgressRecord(hash, reads, CloudEgressRecord(state: "OFF",
        transitionGeneration: transitionGeneration, reservedVersion: reservedVersion,
        lifetimeOwnerGeneration: ownerGeneration, lifetimeOwnerEpoch: ownerEpoch,
        retirement: op, expiryEvidence: evidence))
      let done = reports.allSatisfy { $0.outcome == .verified }
      var reply = transition("mintExpiry", done ? .done : .incomplete, op: op, barrier: barrier, egress: reports)
      if done { reply.expiryEvidence = evidence }
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// §7.7: removes exactly [evidenceId] from every layer that holds it (the
  /// record is otherwise unchanged). The counter changes in every case, so an
  /// earlier inspection can no longer be confirmed.
  static func invalidateExpiryEvidence(ownerUid: String, evidenceId: String) throws -> EnableTransitionResult {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, validOperationId(evidenceId) else { throw QueueError.encodingFailed }
    return try withProtectedWriteLock {
      guard let hash = try keyedOwnerHash(owner) else {
        var reply = transition("invalidateExpiry", .done, op: nil, barrier: absentBarrier())
        reply.mutationCounter = egressMutationCounter()
        return reply
      }
      let reads = StateLayer.allCases.map { egressLayerRead($0) }
      var clean = true
      for (layer, read) in zip(StateLayer.allCases, reads) {
        switch read {
        case .unreadable: clean = false
        case .absent: continue
        case let .value(map):
          guard let entry = map.owners[hash], entry.expiryEvidence?.evidenceId == evidenceId else { continue }
          var next = map
          next.owners[hash] = CloudEgressRecord(state: entry.state,
            transitionGeneration: entry.transitionGeneration, reservedVersion: entry.reservedVersion,
            lifetimeOwnerGeneration: entry.lifetimeOwnerGeneration,
            lifetimeOwnerEpoch: entry.lifetimeOwnerEpoch, retirement: entry.retirement)
          guard let data = try? JSONEncoder().encode(next) else { throw QueueError.encodingFailed }
          _ = writeStateLayer(.egress, layer, data)
          if case let .value(back) = egressLayerRead(layer), back == next { continue }
          clean = false
        }
      }
      var reply = transition("invalidateExpiry", clean ? .done : .incomplete, op: nil,
        barrier: absentBarrier(), egress: inspectEgress(hash))
      reply.mutationCounter = egressMutationCounter()
      return reply
    }
  }
  #endif

  #if CAPTURE_STATE_WRITER
  /// §7.5 exact successor retirement, bound to lifetime G' (not to pending state):
  /// if G' is the active lifetime, writes OFF + retirement for G' in both layers
  /// and removes [operationId]'s pending entry if present. A superseded G' (the
  /// active owner or a layer is bound elsewhere) is `stale` with nothing written.
  static func retireSuccessor(
    ownerUid: String, successorGeneration: Int, ownerEpoch: Int, operationId: String
  ) throws -> EnableTransitionResult {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, successorGeneration > 0, ownerEpoch >= 0,
          validOperationId(operationId) else { throw QueueError.encodingFailed }
    return try withProtectedWriteLock {
      guard let hash = try keyedOwnerHash(owner) else {
        return transition("retireSuccessor", .stale, op: nil, barrier: absentBarrier())
      }
      let pending = pendingView()
      let barrier = inspectBarrier(pending, hash)
      let before = inspectEgress(hash)
      guard let active = try readActiveOwner(), active.uid == owner,
            active.generation == successorGeneration,
            let store = defaults, snapshotCounter(ownerEpochKey, in: store) == ownerEpoch else {
        return transition("retireSuccessor", .stale, op: nil, barrier: barrier, egress: before)
      }
      let reads = StateLayer.allCases.map { egressLayerRead($0) }
      if pending.anyUnreadable || reads.contains(where: { $0.isUnreadable }) {
        return transition("retireSuccessor", .uncertain, op: nil, barrier: barrier, egress: before)
      }
      let entries = reads.compactMap { read -> CloudEgressRecord? in
        if case let .value(map) = read { return map.owners[hash] }
        return nil
      }
      if entries.contains(where: {
        $0.lifetimeOwnerGeneration != successorGeneration || $0.lifetimeOwnerEpoch != ownerEpoch
      }) {
        return transition("retireSuccessor", .stale, op: nil, barrier: barrier, egress: before)
      }
      let own = StateLayer.allCases.compactMap { pending.entry(hash, in: $0) }
        .first { $0.operationId == operationId }
      let op = own ?? PendingEnable(operationId: operationId,
        transitionGeneration: entries.map(\.transitionGeneration).max() ?? 0,
        reservedVersion: entries.map(\.reservedVersion).max() ?? 0,
        ownerGeneration: successorGeneration, ownerEpoch: ownerEpoch)
      let reports = try writeEgressRecord(hash, reads, CloudEgressRecord(state: "OFF",
        transitionGeneration: op.transitionGeneration, reservedVersion: op.reservedVersion,
        lifetimeOwnerGeneration: successorGeneration, lifetimeOwnerEpoch: ownerEpoch, retirement: op))
      var clean = reports.allSatisfy { $0.outcome == .verified }
      // The pending barrier is the remaining protection while OFF is not
      // verified in both layers: it is removed only after that verification.
      for layer in StateLayer.allCases where clean {
        guard case let .value(map) = pending.layer(layer), map.owners[hash]?.operationId == operationId else {
          continue
        }
        var remaining = map
        remaining.owners.removeValue(forKey: hash)
        if remaining.owners.isEmpty {
          _ = removeStateLayer(.pending, layer)
        } else if let data = try? JSONEncoder().encode(remaining) {
          _ = writeStateLayer(.pending, layer, data)
        }
        switch pendingLayerRead(layer) {
        case .absent where remaining.owners.isEmpty: break
        case let .value(back) where back == remaining: break
        default: clean = false
        }
      }
      return transition("retireSuccessor", clean ? .done : .incomplete, op: op,
        barrier: inspectBarrier(pendingView(), hash), egress: reports)
    }
  }
  #endif

  /// §7.5.1 read-only reconciliation of a dispatched successor finish: `finished`
  /// (G' ON in both layers, no pending for the owner), `behindBarrier` (G' ON in
  /// both layers behind exactly [operationId]'s pending) or `other`.
  static func inspectSuccessor(
    ownerUid: String, successorGeneration: Int, ownerEpoch: Int, operationId: String
  ) throws -> String {
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty, validOperationId(operationId) else { throw QueueError.encodingFailed }
    return try withQueueLock {
      guard let hash = try keyedOwnerHash(owner),
            let active = try readActiveOwner(), active.uid == owner,
            active.generation == successorGeneration,
            let store = defaults, snapshotCounter(ownerEpochKey, in: store) == ownerEpoch else { return "other" }
      let pending = pendingView()
      let entries = StateLayer.allCases.map { layer -> CloudEgressRecord? in
        if case let .value(map) = egressLayerRead(layer) { return map.owners[hash] }
        return nil
      }
      guard !pending.anyUnreadable, entries.allSatisfy({
        $0 != nil && $0!.state == "ON" && $0!.retirement == nil
          && $0!.lifetimeOwnerGeneration == successorGeneration && $0!.lifetimeOwnerEpoch == ownerEpoch
      }) else { return "other" }
      let own = StateLayer.allCases.map { pending.entry(hash, in: $0) }
      if own.allSatisfy({ $0 == nil }) { return "finished" }
      if own.allSatisfy({ $0?.operationId == operationId }) { return "behindBarrier" }
      return "other"
    }
  }

  /// Read-only: the owner's pending barrier and egress entry per layer, so a
  /// restart can find the operation it must resume, restrict or abandon. Allowed
  /// during a Remove-data barrier. Writes nothing and never creates the HMAC key.
  static func cloudEgressPending(forUid uid: String) throws -> EnableTransitionResult {
    let owner = normalizedUID(uid)
    guard !owner.isEmpty else { throw QueueError.encodingFailed }
    return try withQueueLock {
      guard let hash = try keyedOwnerHash(owner) else {
        // No hash key yet: nothing can have been written under an owner hash.
        let view = pendingView()
        let status: TransitionStatus = view.anyUnreadable ? .uncertain : (view.holdsAny ? .conflict : .noBarrier)
        return transition("inspect", status, op: nil, barrier: StateLayer.allCases.map {
          pendingReport($0, view.layer($0).isUnreadable ? .unreadable : .absent, nil)
        }, egress: StateLayer.allCases.map { layer in
          switch egressLayerRead(layer) {
          case .absent: return egressReport(layer, .absent, nil)
          case .unreadable: return egressReport(layer, .unreadable, nil)
          case let .value(map):
            return egressReport(layer, map.owners.isEmpty ? .absent : .mismatch, nil)
          }
        })
      }
      let view = pendingView()
      let barrier = inspectBarrier(view, hash)
      let egress = inspectEgress(hash)
      let entries = StateLayer.allCases.compactMap { view.entry(hash, in: $0) }
      let status: TransitionStatus
      if view.anyUnreadable {
        status = .uncertain
      } else if entries.isEmpty {
        status = .noBarrier
      } else if let first = entries.first, entries.allSatisfy({ $0 == first }) {
        status = entries.count == 2 ? .pending : .incomplete
      } else {
        status = .conflict
      }
      var reply = transition("inspect", status, op: entries.first, barrier: barrier, egress: egress)
      reply.egressVersionFrontier = StateLayer.allCases.compactMap { layer -> Int? in
        guard case let .value(map) = egressLayerRead(layer), let stored = map.owners[hash] else { return nil }
        return max(stored.reservedVersion, stored.retirement?.reservedVersion ?? 0)
      }.max()
      return reply
    }
  }

  // MARK: Native in-flight registry (C.4)

  private static func inflightFileURL() throws -> URL {
    try appGroupContainerURL().appendingPathComponent(inflightFileName)
  }

  /// All entries (expired ones included); callers hold the flock. Absent file is
  /// empty; an unreadable/undecodable file throws.
  private static func readInflightRaw() throws -> [InflightUpload] {
    let url = try inflightFileURL()
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([InflightUpload].self, from: data) else {
      throw QueueError.unreadable
    }
    return entries
  }

  private static func writeInflight(_ entries: [InflightUpload]) throws {
    let url = try inflightFileURL()
    if entries.isEmpty {
      if FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
      return
    }
    try JSONEncoder().encode(entries).write(
      to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  /// A corrupt registry older than the longest possible deadline holds nothing live.
  private static func inflightFileIsStale(now: Date) -> Bool {
    guard let url = try? inflightFileURL(),
          let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    else { return false }
    return now.timeIntervalSince(modified) > nativeUploadTimeout + inflightGrace
  }

  /// Removes the upload's entry (success or error). Best effort: an entry that is
  /// not removed simply expires at its deadline.
  static func removeInflightUpload(payloadID: String) {
    _ = try? withQueueLock {
      let entries = try readInflightRaw()
      try writeInflight(entries.filter { $0.payloadId != payloadID })
    }
  }

  /// The live (not past its deadline) admitted uploads of [uid]. Throws when the
  /// registry or the lock is unavailable: the caller must then wait the longest
  /// possible deadline.
  static func inflightUploads(forUid uid: String) throws -> (count: Int, latestDeadline: Date?) {
    try withQueueLock {
      let hash = try uidHash(uid)
      let now = egressNow().timeIntervalSince1970
      let live = try readInflightRaw().filter { $0.ownerHash == hash && $0.deadline > now }
      return (live.count, live.map { $0.deadline }.max().map { Date(timeIntervalSince1970: $0) })
    }
  }

  // MARK: The ONE native network transport (H3.1)

  /// Answers every redirect with "no new request", so a 3xx is delivered as the
  /// final response (the caller then sees a non-200 status). An upload carries
  /// the device secret and the sanitized SMS; it is never replayed to a
  /// `Location` the server did not admit.
  private final class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
      _ session: URLSession,
      task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse,
      newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      completionHandler(nil)
    }
  }

  /// H3.1: the single place any native process (host app, App Intent, share
  /// extension) opens a network connection. An architecture test pins that no
  /// other URL-loading, socket or Network-framework use exists in any iOS target.
  ///
  /// - Admission (egress state + owner/generation + in-flight registration, the
  ///   [admitUpload] decision) runs under the queue flock IMMEDIATELY before the
  ///   request. DISABLING / OFF / unreadable / a different owner or generation
  ///   throws [QueueError.egressDenied] and NO request is made.
  /// - The session is ephemeral (no shared cookie jar, URL cache or credential
  ///   store), refuses redirects, does not wait for connectivity and has no
  ///   background identifier, so nothing is retried or resumed by the OS after
  ///   the process ends.
  /// - The in-flight registry entry is removed on every exit.
  /// - Admission before a lifecycle fence is already in flight, even if transport
  ///   starts later. Revocation cannot recall that request; network waits never
  ///   run under the queue flock. Native denial is confirmed at the fence receipt.
  /// - It reads ONLY the durable egress state through [admitUpload]. The Dart
  ///   account-control grant is in-process Dart state; it is never written to
  ///   the Keychain, the App Group file or any channel, so it cannot admit
  ///   native traffic.
  static func gatedUpload(
    _ request: URLRequest,
    payloadID: String,
    ownerUid: String,
    ownerGeneration: Int
  ) async throws -> (Data, URLResponse) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = nativeUploadTimeout
    configuration.timeoutIntervalForResource = nativeUploadTimeout
    let session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    // Read BEFORE admission: a consent withdrawal of this owner that lands
    // between admission and the transport start advances it, and the request
    // is then refused instead of being sent on a decision that is already stale.
    let owner = normalizedUID(ownerUid)
    let withdrawalEpoch = inflightSessions.epoch(owner)
    guard case let .allowed(admittedUid, admittedGeneration, _) = admitUpload(payloadID: payloadID) else {
      throw QueueError.egressDenied
    }
    // Registered at admission: removed on EVERY exit, including a stale
    // (owner, generation) refusal right below.
    defer { removeInflightUpload(payloadID: payloadID) }
    guard admittedUid == ownerUid, admittedGeneration == ownerGeneration else {
      throw QueueError.egressDenied
    }
    // Last check before the wire: a withdrawal since [withdrawalEpoch] refuses;
    // a later one finds the session here and cancels it.
    guard let registration = inflightSessions.register(
      session, owner: owner, epoch: withdrawalEpoch) else {
      throw QueueError.egressDenied
    }
    defer { inflightSessions.unregister(registration) }

    var admitted = request
    admitted.timeoutInterval = nativeUploadTimeout
    admitted.httpShouldHandleCookies = false
    return try await session.data(for: admitted)
  }

  // MARK: Consent withdrawal (fail-closed native gate)

  /// In-process registry of the gated native uploads that are about to start
  /// or on the wire, per normalized owner. Memory only (never persisted, never
  /// logged). A consent withdrawal advances the owner's epoch and cancels its
  /// registered sessions; [gatedUpload] registers only under an unchanged epoch.
  final class InflightSessionRegistry {
    private let lock = NSLock()
    private var epochs: [String: Int] = [:]
    private var sessions: [UUID: (owner: String, session: URLSession)] = [:]

    func epoch(_ owner: String) -> Int {
      lock.lock(); defer { lock.unlock() }
      return epochs[owner] ?? 0
    }

    /// nil (refused) when [owner] was withdrawn since [epoch] was read.
    func register(_ session: URLSession, owner: String, epoch: Int) -> UUID? {
      lock.lock(); defer { lock.unlock() }
      guard (epochs[owner] ?? 0) == epoch else { return nil }
      let id = UUID()
      sessions[id] = (owner, session)
      return id
    }

    func unregister(_ id: UUID) {
      lock.lock(); defer { lock.unlock() }
      sessions[id] = nil
    }

    /// Advances [owner]'s epoch and cancels its registered sessions. Returns
    /// how many were cancelled (requests already dispatched before the
    /// withdrawal that this process could still reach).
    func withdraw(_ owner: String) -> Int {
      lock.lock()
      epochs[owner] = (epochs[owner] ?? 0) + 1
      let mine = sessions.filter { $0.value.owner == owner }
      for id in mine.keys { sessions[id] = nil }
      lock.unlock()
      for entry in mine.values { entry.session.invalidateAndCancel() }
      return mine.count
    }

    var registeredCount: Int {
      lock.lock(); defer { lock.unlock() }
      return sessions.count
    }
  }

  static let inflightSessions = InflightSessionRegistry()

  #if CAPTURE_STATE_WRITER
  /// What [withdrawCloudEgress] did. Constant strings and counts only.
  struct WithdrawReport: Equatable {
    /// restricted | barrier (Remove-data barrier: admission already waits) | failed
    var mirror = "failed"
    /// restricted | failed
    var config = "failed"
    /// restricted (DISABLING written) | already_denied (uncertain or not ON) |
    /// absent (no record: the mirror alone governs) | failed
    var egress = "failed"
    /// Admitted uploads of the owner still inside their deadline at the
    /// withdrawal: dispatched BEFORE it (-1 = registry unreadable).
    var inflightBefore = -1
    /// In-process sessions of the owner cancelled by the withdrawal.
    var cancelled = 0

    var dictionary: [String: Any] {
      ["mirror": mirror, "config": config, "egress": egress,
       "inflightBefore": inflightBefore, "cancelled": cancelled]
    }

    /// True when the native admission is guaranteed to refuse this owner.
    var denies: Bool {
      mirror == "restricted" || mirror == "barrier" || config == "restricted"
        || egress == "restricted" || egress == "already_denied"
    }
  }

  /// The user confirmed Cloud / Smart Analysis OFF for [ownerUid]: from this
  /// call on no native content upload of that owner may START. Every step is
  /// restrictive, owner-scoped and independent of the Dart transition (which
  /// can fail on its own, e.g. on another account's unverifiable records):
  ///  1. under one flock, the backend config goes cloud/AI OFF (the App Intent
  ///     then never asks to upload) and the owner's consent mirror goes OFF at
  ///     its stored version ([authorizeUpload] then answers `.localOnly`);
  ///  2. the owner's ON egress record becomes DISABLING in both layers at its
  ///     CURRENT generation (rank up, generation unchanged), so a stale ON can
  ///     never be written over it and a later explicit enable (a strictly
  ///     higher generation) is not blocked by it;
  ///  3. in-process requests admitted before the withdrawal are cancelled;
  ///     any admitted but not yet started are refused by [gatedUpload].
  /// Captures stay in the queue for local parsing and review.
  static func withdrawCloudEgress(ownerUid: String) -> WithdrawReport {
    var report = WithdrawReport()
    let owner = normalizedUID(ownerUid)
    guard !owner.isEmpty else { return report }
    _ = try? withProtectedWriteLock { () throws -> Void in
      defaults?.set(false, forKey: cloudProcessingEnabledKey)
      defaults?.set(false, forKey: aiConsentGrantedKey)
      defaults?.synchronize()
      if let store = defaults,
         store.object(forKey: cloudProcessingEnabledKey) as? Bool == false,
         store.object(forKey: aiConsentGrantedKey) as? Bool == false {
        report.config = "restricted"
      }
      if try readBarrier() != nil {
        report.mirror = "barrier"
        return
      }
      let hash = try uidHash(owner)
      let entry = defaults?.dictionary(forKey: consentMirrorKey)?[hash] as? [String: Any]
      let version = entry?["version"] as? Int ?? 0
      writeConsentMirrorEntry(
        hash: hash, mirror: ConsentMirrorValue(cloud: false, ai: false, version: version))
      if let mirror = consentMirror(forHash: hash), !mirror.cloud, !mirror.ai {
        report.mirror = "restricted"
      }
    }
    let target = try? withQueueLock { () throws -> (generation: Int, version: Int)? in
      let view = egressView()
      if view.uncertain {
        report.egress = "already_denied"
        return nil
      }
      let hash = try uidHash(owner)
      let mine = view.maps.compactMap { $0.owners[hash] }
      if mine.isEmpty {
        report.egress = "absent"
        return nil
      }
      if !mine.contains(where: { $0.state == "ON" }) {
        report.egress = "already_denied"
        return nil
      }
      return (mine.map(\.transitionGeneration).max() ?? 0,
              mine.map(\.reservedVersion).max() ?? 0)
    }
    if let target {
      do {
        try setCloudEgressState(
          state: "DISABLING", ownerUid: owner,
          transitionGeneration: target.generation, reservedVersion: target.version)
        report.egress = "restricted"
      } catch {
        report.egress = "failed"
      }
    }
    report.inflightBefore = (try? inflightUploads(forUid: owner).count) ?? -1
    report.cancelled = inflightSessions.withdraw(owner)
    return report
  }
  #endif

  #if DEBUG
  /// Test-only reset (XCTest): the egress state is deliberately NOT cleared by
  /// `purgeUserOwnedState`, because the persistent OFF gate outlives sign-out.
  static func debugResetCloudEgressState() {
    SharedKeychain.remove(forKey: egressStateKC)
    SharedKeychain.remove(forKey: pendingStateKC)
    pendingKeychainReadOverride = nil
    stateLayerWriteFault = nil
    if let url = try? egressFileURL() { try? FileManager.default.removeItem(at: url) }
    if let url = try? pendingFileURL() { try? FileManager.default.removeItem(at: url) }
    if let url = try? inflightFileURL() { try? FileManager.default.removeItem(at: url) }
  }

  /// Test-only: the uidHash used as the egress-map key.
  static func debugOwnerHash(_ uid: String) throws -> String {
    try withQueueLock { try uidHash(uid) }
  }
  #endif

  // MARK: Unbound recovery (§4.3)

  /// Count/senders of the unbound items whose hint is HMAC([uid]). Items without
  /// a hint, or hinted to another uid, are never reported.
  static func unboundSummary(forUid uid: String) throws -> UnboundSummary {
    try withQueueLock {
      let hash = try uidHash(uid)
      let mine = try loadQueuePruned().filter {
        $0.ownerState == ownerStateUnbound && $0.ownerHint == hash
      }
      let senders = Array(Set(mine.compactMap { $0.sender })).sorted()
      return UnboundSummary(ids: mine.compactMap { $0.id }, senders: senders)
    }
  }

  /// "Add them to my account": binds the [ids] snapshot under the flock iff every
  /// item is still unbound AND hinted to [uid], the active owner record is
  /// exactly `{uid, generation}`, and replica owner and session uid both equal
  /// [uid]. Otherwise nothing is mutated. Bound items are `localOnly`: they never
  /// upload and never use AI.
  static func claimUnbound(
    uid: String,
    generation: Int,
    replicaOwnerUid: String,
    sessionUid: String,
    ids: [String]
  ) throws -> ClaimOutcome {
    try casUnbound(uid, generation, replicaOwnerUid, sessionUid, ids) { queue, indexes, owner in
      for index in indexes {
        queue[index].ownerState = ownerStateStamped
        queue[index].ownerUid = owner.uid
        queue[index].ownerGeneration = owner.generation
        queue[index].ownerHint = nil
        queue[index].unboundAt = nil
        queue[index].localOnly = true
        if queue[index].status == CaptureStatus.pendingSend.rawValue {
          queue[index].status = CaptureStatus.sent.rawValue
        }
      }
    }
  }

  /// "Discard them": the same CAS, then deletes the items.
  static func discardUnbound(
    uid: String,
    generation: Int,
    replicaOwnerUid: String,
    sessionUid: String,
    ids: [String]
  ) throws -> ClaimOutcome {
    try casUnbound(uid, generation, replicaOwnerUid, sessionUid, ids) { queue, indexes, _ in
      for index in indexes.sorted(by: >) { queue.remove(at: index) }
    }
  }

  private static func casUnbound(
    _ uid: String,
    _ generation: Int,
    _ replicaOwnerUid: String,
    _ sessionUid: String,
    _ ids: [String],
    apply: (inout [Payload], [Int], OwnerRecord) -> Void
  ) throws -> ClaimOutcome {
    try withQueueLock {
      guard try readBarrier() == nil else { throw QueueError.barrierActive }
      let target = normalizedUID(uid)
      guard normalizedUID(replicaOwnerUid) == target,
            normalizedUID(sessionUid) == target,
            let owner = try readActiveOwner(),
            owner.uid == target, owner.generation == generation else {
        return .ownerMismatch
      }
      let hash = try uidHash(target)
      var queue = try loadQueuePruned()
      let wanted = Set(ids)
      let indexes = queue.indices.filter { wanted.contains(queue[$0].id ?? "") }
      guard !wanted.isEmpty, indexes.count == wanted.count,
            indexes.allSatisfy({
              queue[$0].ownerState == ownerStateUnbound && queue[$0].ownerHint == hash
            }) else {
        return .stale
      }
      apply(&queue, indexes, owner)
      try saveQueue(queue, notifyHost: false)
      return .applied(indexes.count)
    }
  }

  // MARK: Legacy v2 provenance (§4.7)

  #if CAPTURE_STATE_WRITER
  /// Dart's adopted-replica verdict on migrated items: [consumedIds] (receipt
  /// `capture_payload:<id>` or tx.id == capture_id) are removed; [suspectedIds]
  /// (fingerprint match) get the non-financial `suspected_already_imported`
  /// annotation. Only `legacy_v2` unbound items are touched; nothing is bound.
  @discardableResult
  static func resolveLegacyItems(consumedIds: [String], suspectedIds: [String]) throws -> Int {
    try withProtectedWriteLock {
      var queue = try loadQueue()
      let consumed = Set(consumedIds)
      let suspected = Set(suspectedIds)
      let before = queue.count
      func isLegacy(_ item: Payload) -> Bool {
        item.origin == originLegacyV2 && item.ownerState == ownerStateUnbound
      }
      queue.removeAll(where: { isLegacy($0) && consumed.contains($0.id ?? "") })
      for index in queue.indices
      where isLegacy(queue[index]) && suspected.contains(queue[index].id ?? "") {
        queue[index].reviewState = reviewSuspectedAlreadyImported
      }
      try saveQueue(queue, notifyHost: false)
      return before - queue.count
    }
  }
  #endif

  /// One migrated v2 item as the legacy resolver needs it for the A6
  /// fingerprint check. Content-bearing: never log it.
  struct LegacyPeekItem {
    let id: String
    let text: String
    let receivedAt: String?
    let createdAt: String?
  }

  /// A6 (CAP-7): read-only listing of the `legacy_v2` items that are still
  /// unbound. Under the flock; changes nothing and notifies nobody.
  static func peekLegacyCaptureItems() throws -> [LegacyPeekItem] {
    try withQueueLock {
      try loadQueue().compactMap { item in
        guard item.origin == originLegacyV2,
              item.ownerState == ownerStateUnbound,
              let id = item.id else { return nil }
        return LegacyPeekItem(
          id: id, text: item.text, receivedAt: item.receivedAt, createdAt: item.createdAt
        )
      }
    }
  }

  // MARK: Remove-data barrier (§4.4)

  private static func readBarrier() throws -> RemovalBarrier? {
    let url = try appGroupContainerURL().appendingPathComponent(barrierFileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    // An unreadable barrier fails closed: the capture is refused, not persisted.
    guard let data = try? Data(contentsOf: url),
          let barrier = try? JSONDecoder().decode(RemovalBarrier.self, from: data) else {
      throw QueueError.unreadable
    }
    return barrier
  }

  #if CAPTURE_STATE_WRITER
  /// Step 1 of Remove data for [uid]: under the flock, persist the barrier and
  /// clear the owner record if it is [uid]'s. From now on the intent fails
  /// visibly instead of persisting. Idempotent for the same uid (a resumed removal).
  static func beginRemoval(uid: String) throws -> RemovalBarrier {
    try withProtectedWriteLock {
      let target = normalizedUID(uid)
      let hash = try uidHash(target)
      let barrier: RemovalBarrier
      if let existing = try readBarrier() {
        guard existing.uidHash == hash else { throw QueueError.barrierActive }
        barrier = existing
      } else {
        barrier = RemovalBarrier(
          nonce: UUID().uuidString.lowercased(),
          uidHash: hash,
          startedAt: isoFormatter.string(from: Date())
        )
        guard let data = try? JSONEncoder().encode(barrier) else { throw QueueError.encodingFailed }
        do {
          try data.write(
            to: try appGroupContainerURL().appendingPathComponent(barrierFileName),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
          )
        } catch let error as QueueError {
          throw error
        } catch {
          throw QueueError.storageWriteFailed
        }
      }
      if let owner = try readActiveOwner(), owner.uid == target {
        try removeKeychain(forKey: activeOwnerKC)
        bumpOwnerEpoch()
      }
      return barrier
    }
  }
  #endif

  /// The barrier in force, if any. A launch that finds one resumes the removal
  /// from step 2 (replica teardown), then calls `finishRemoval`.
  static func removalBarrier() throws -> RemovalBarrier? {
    try withQueueLock { try readBarrier() }
  }

  #if CAPTURE_STATE_WRITER
  /// Step 5 of Remove data: the final sweep under the flock. Deletes every item
  /// owned by, hinted to, or created at/after the barrier start of [uid]'s
  /// removal (or tagged with its nonce), drops the uid's consent mirror and
  /// last-admitted hint, and clears the barrier LAST so a crash re-runs this
  /// idempotently. Returns the number of items deleted.
  @discardableResult
  static func finishRemoval(uid: String) throws -> Int {
    try withProtectedWriteLock {
      guard let barrier = try readBarrier() else { return 0 }
      let target = normalizedUID(uid)
      let hash = try uidHash(target)
      guard barrier.uidHash == hash else { throw QueueError.barrierActive }
      var queue = try loadQueue()
      let started = isoFormatter.date(from: barrier.startedAt)
      let before = queue.count
      queue.removeAll(where: { item in
        if item.ownerUid == target || item.ownerHint == hash { return true }
        if item.barrierNonce == barrier.nonce { return true }
        if let started = started,
           let created = item.createdAt.flatMap(isoFormatter.date(from:)),
           created >= started {
          return true
        }
        return false
      })
      try saveQueue(queue, notifyHost: false)
      try removeQuarantinedSegments()
      if try readLastAdmittedHash() == hash { try removeKeychain(forKey: lastAdmittedHashKC) }
      if let owner = try readActiveOwner(), owner.uid == target {
        try removeKeychain(forKey: activeOwnerKC)
        bumpOwnerEpoch()
      }
      var mirror = defaults?.dictionary(forKey: consentMirrorKey) ?? [:]
      mirror.removeValue(forKey: hash)
      defaults?.set(mirror, forKey: consentMirrorKey)
      defaults?.synchronize()
      let url = try appGroupContainerURL().appendingPathComponent(barrierFileName)
      do {
        try FileManager.default.removeItem(at: url)
      } catch {
        throw QueueError.storageWriteFailed
      }
      return before - queue.count
    }
  }
  #endif

  // MARK: Queue stats (diagnostics, content-free)

  enum QuotaState: String, Equatable {
    case ok
    /// At least 80% of a count or byte limit.
    case near
    /// The next capture in this scope would be refused (§4.5).
    case full
  }

  /// WP-8 diagnostics: counts, byte sizes and quota state ONLY. No text, sender,
  /// amount, merchant, account, id or uid ever appears here, and there is no
  /// per-capture list. Each item falls in exactly one bucket: `unbound`;
  /// stamped to the active owner (`localOnly` when it never uploads, else
  /// `stamped`); anything else (another owner's, or no owner is active) is
  /// `waiting`.
  struct QueueStats: Equatable {
    var stamped = 0
    var localOnly = 0
    var waiting = 0
    var unbound = 0
    var activeOwnerBytes = 0
    var unboundBytes = 0
    var deviceBytes = 0
    var ownerQuota = QuotaState.ok
    var unboundQuota = QuotaState.ok
    var deviceQuota = QuotaState.ok
    /// The v2 queue has not been migrated to v3 yet. Its items are counted as
    /// unbound (what the migration will make them) WITHOUT migrating.
    var migrationPending = false
    /// Overflow segments that could not be decrypted although the key was
    /// readable (quarantined or skipped). Their items are not in any count
    /// above; the files are kept until a purge / Remove-data sweep.
    var quarantinedSegments = 0
  }

  /// The queue for stats: STRICTLY read-only. Unlike `loadQueue` it never runs
  /// the one-time v2 -> v3 migration (a write); a not-yet-migrated v2 blob is
  /// counted as the unbound items the migration will make of it. Overflow
  /// segments are read without cleanup: nothing is moved, removed or written.
  private static func loadQueueReadOnly() throws
    -> (queue: [Payload], migrationPending: Bool, quarantined: Int) {
    let mainData = try readQueueFile()
    var mainItems: [Payload] = []
    if let data = mainData { mainItems = try decodeQueueBlob(data) }
    let overflow = try readOverflowSegments(cleanUp: false)
    let rest = overflow.segments.flatMap { $0.items }
    let quarantined = overflow.corrupt + quarantinedSegmentCount()
    if mainData != nil { return (mainItems + rest, false, quarantined) }
    guard defaults?.bool(forKey: migratedKey) != true,
          let blob = defaults?.data(forKey: queueKey) else { return (rest, false, quarantined) }
    return (try decodeQueueBlob(blob).map { quarantinedLegacy($0, at: "") } + rest, true, quarantined)
  }

  /// Read-only, under the flock (writes nothing, migrates nothing). Since
  /// 2026-11-12 there is no per-owner / unbound quota, so `ownerQuota` and
  /// `unboundQuota` are always `ok`; `deviceQuota` reports the free space of
  /// the volume (the only thing that can refuse a capture now).
  static func queueStats() throws -> QueueStats {
    try withQueueLock {
      let (queue, migrationPending, quarantined) = try loadQueueReadOnly()
      let owner = try readActiveOwner()
      var stats = QueueStats()
      stats.migrationPending = migrationPending
      stats.quarantinedSegments = quarantined
      func size(_ value: Payload) throws -> Int {
        guard let data = try? JSONEncoder().encode(value) else { throw QueueError.encodingFailed }
        return data.count
      }
      for item in queue {
        let bytes = try size(item)
        stats.deviceBytes += bytes
        if item.ownerState == ownerStateUnbound {
          stats.unbound += 1
          stats.unboundBytes += bytes
        } else if let owner = owner, item.ownerUid == owner.uid {
          stats.activeOwnerBytes += bytes
          if item.localOnly == true { stats.localOnly += 1 } else { stats.stamped += 1 }
        } else {
          stats.waiting += 1
        }
      }
      stats.deviceQuota = deviceCapacityState()
      return stats
    }
  }

  /// `full` when the volume has less free space than two whole segments (a
  /// tail rewrite needs a temp copy), `near` below 64 MB. Diagnostics only:
  /// a capture is refused only by an actual failed write.
  private static func deviceCapacityState() -> QuotaState {
    guard let url = try? appGroupContainerURL(),
          let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let free = values.volumeAvailableCapacityForImportantUsage else { return .ok }
    if free < Int64(2 * segmentMaxBytes) { return .full }
    if free < Int64(64 * 1024 * 1024) { return .near }
    return .ok
  }

  /// Every queued item, for diagnostics and tests. Content-bearing: never log it.
  static func queueSnapshot() throws -> [Payload] {
    try withQueueLock { try loadQueue() }
  }

  private static func updatePendingMetadata(_ queue: [Payload]) {
    if queue.isEmpty {
      defaults?.removeObject(forKey: pendingCountKey)
      defaults?.removeObject(forKey: latestPayloadIDKey)
    } else {
      defaults?.set(queue.count, forKey: pendingCountKey)
      defaults?.set(queue.last?.id, forKey: latestPayloadIDKey)
    }
  }

  private static func notifyPendingMessagesAvailable() {
    CFNotificationCenterPostNotification(
      CFNotificationCenterGetDarwinNotifyCenter(),
      CFNotificationName(pendingMessagesNotificationName as CFString),
      nil,
      nil,
      true
    )
  }

  private static func clean(_ value: String?) -> String? {
    let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (trimmed?.isEmpty ?? true) ? nil : trimmed
  }

  private static func setOrRemove(_ value: String?, forKey key: String) {
    if let cleanValue = clean(value) {
      defaults?.set(cleanValue, forKey: key)
    } else {
      defaults?.removeObject(forKey: key)
    }
  }

  static func makePayloadID(
    text: String,
    sender: String?,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: String
  ) -> String {
    let raw = [
      text,
      sender ?? "",
      senderName ?? "",
      senderID ?? "",
      source ?? "",
      receivedAt
    ].joined(separator: "|")
    let digest = SHA256.hash(data: Data(raw.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Capture-queue encryption (MALI-031)

  private static func readQueueKey() -> (status: OSStatus, data: Data?) {
    queueKeyReadOverride?() ?? SharedKeychain.read(forKey: queueEncryptionKeyKC)
  }

  /// The AES-256 key that encrypts the capture queue at rest, held in the shared
  /// Keychain (accessible to the host app and the extension). Generated once,
  /// and ONLY when the Keychain positively reports `errSecItemNotFound`: any
  /// other status (e.g. `errSecInteractionNotAllowed` before first unlock) throws,
  /// because replacing a key that merely could not be read would make the
  /// existing encrypted queue permanently undecryptable (CAP-0).
  private static func encryptionKey() throws -> SymmetricKey {
    let read = readQueueKey()
    switch read.status {
    case errSecSuccess:
      guard let data = read.data, data.count == 32 else {
        throw QueueError.keyUnavailable(errSecDecode)
      }
      return SymmetricKey(data: data)
    case errSecItemNotFound:
      // 2026-11-12: a key is minted only when NO sealed queue file exists. A
      // main file or overflow segment whose key is gone (e.g. a backup restored
      // without the ThisDeviceOnly Keychain item) is kept byte-for-byte and
      // every write is refused: a new key would orphan it for good, even if
      // the old key came back.
      guard try !sealedQueueFilesExist() else { throw QueueError.unreadable }
      let key = SymmetricKey(size: .bits256)
      let raw = key.withUnsafeBytes { Data(Array($0)) }
      let status = SharedKeychain.writeData(raw, forKey: queueEncryptionKeyKC)
      guard status == errSecSuccess else { throw QueueError.keyUnavailable(status) }
      return key
    default:
      throw QueueError.keyUnavailable(read.status)
    }
  }

  /// Encrypts the queue as an AES-GCM combined blob. Throws if the shared
  /// Keychain (hence the key) is unavailable, so the caller does NOT overwrite a
  /// good blob with an unencrypted one.
  private static func encodeQueueBlob(_ queue: [Payload]) throws -> Data {
    let key = try encryptionKey()
    guard let json = try? JSONEncoder().encode(queue),
          let sealed = try? AES.GCM.seal(json, using: key).combined else {
      throw QueueError.encodingFailed
    }
    return sealed
  }

  /// Decrypts a stored blob. New blobs are AES-GCM sealed; a legacy plaintext
  /// JSON blob is decoded transparently (one-time migration on next save). This
  /// path only READS the key and never creates one: an unreadable key throws
  /// `keyUnavailable`, and a blob that decrypts under no key (corrupt, or the
  /// key is gone) throws `unreadable` — callers must not treat either as empty.
  private static func decodeQueueBlob(_ data: Data) throws -> [Payload] {
    let read = readQueueKey()
    guard read.status == errSecSuccess || read.status == errSecItemNotFound else {
      throw QueueError.keyUnavailable(read.status)
    }
    if let keyData = read.data, keyData.count == 32,
       let box = try? AES.GCM.SealedBox(combined: data),
       let plain = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)),
       let queue = try? JSONDecoder().decode([Payload].self, from: plain) {
      return queue
    }
    // Legacy plaintext migration path.
    if let queue = try? JSONDecoder().decode([Payload].self, from: data) {
      return queue
    }
    throw QueueError.unreadable
  }
}

/// MALI-031 — secret material (device secret, capture-queue key) lives here, in
/// a shared Keychain access group readable by the host app and the Share
/// Extension, never in App Group UserDefaults. The access group's team prefix is
/// resolved at build time from the `AppIdentifierPrefix` Info.plist value; the
/// `.shared` group is declared in each target's `keychain-access-groups`
/// entitlement. Items are `ThisDeviceOnly` and never sync to iCloud.
private enum SharedKeychain {
  private static let service = "com.youssefsafwat.mali.sharedcapture"

  /// The shared access group, or nil when the team prefix can't be resolved
  /// (e.g. an unsigned simulator/dev build). When nil, the item is stored in the
  /// app's DEFAULT keychain instead — still Keychain (ThisDeviceOnly), never
  /// UserDefaults — so the app stays functional; cross-process app↔extension
  /// sharing then requires the entitled group and is a device-verified path.
  static var accessGroup: String? {
    guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
          !prefix.isEmpty else {
      return nil
    }
    return "\(prefix)com.youssefsafwat.mali.shared"
  }

  private static func baseQuery(_ key: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    if let group = accessGroup {
      q[kSecAttrAccessGroup as String] = group
    }
    return q
  }

  /// Updates the item in place and adds it only when it does not exist yet.
  /// Never delete-then-add: a failure between the two calls would destroy the
  /// only copy of the key (CAP-0).
  @discardableResult
  static func writeData(_ data: Data, forKey key: String) -> OSStatus {
    let base = baseQuery(key)
    let status = SecItemUpdate(
      base as CFDictionary,
      [kSecValueData as String: data] as CFDictionary
    )
    guard status == errSecItemNotFound else { return status }
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    return SecItemAdd(add as CFDictionary, nil)
  }

  @discardableResult
  static func setData(_ data: Data, forKey key: String) -> Bool {
    writeData(data, forKey: key) == errSecSuccess
  }

  /// The raw Keychain status is kept so callers can tell "not there"
  /// (`errSecItemNotFound`) from "could not be read right now".
  static func read(forKey key: String) -> (status: OSStatus, data: Data?) {
    var query = baseQuery(key)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    return (status, status == errSecSuccess ? result as? Data : nil)
  }

  static func data(forKey key: String) -> Data? {
    read(forKey: key).data
  }

  @discardableResult
  static func setString(_ value: String, forKey key: String) -> Bool {
    setData(Data(value.utf8), forKey: key)
  }

  static func string(forKey key: String) -> String? {
    guard let data = data(forKey: key) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  static func remove(forKey key: String) -> OSStatus {
    SecItemDelete(baseQuery(key) as CFDictionary)
  }
}
