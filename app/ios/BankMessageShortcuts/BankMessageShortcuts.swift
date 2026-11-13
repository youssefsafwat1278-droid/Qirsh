import AppIntents
import Foundation
import UserNotifications
import os

/// App Intent exposed to Shortcuts as "Process Bank SMS".
///
/// The Swift type name is kept for backward compatibility with existing
/// automations; the user-facing title is the localized Shortcuts action name.
@available(iOS 16.0, *)
struct PostBankStatusIntent: AppIntent {
  static var title: LocalizedStringResource = "Process Bank SMS"

  static var description = IntentDescription(
    "Processes a bank SMS and imports the transaction into Mali."
  )

  /// Keeps the app from opening by default on pre-iOS 26 systems while still
  /// letting Shortcuts expose its normal "Show When Run" control.
  static var openAppWhenRun: Bool = false

  @available(iOS 26.0, *)
  static var supportedModes: IntentModes {
    [.background, .foreground(.dynamic)]
  }

  static var parameterSummary: some ParameterSummary {
    Summary("Process \(\.$smsText) from \(\.$senderName)")
  }

  @Parameter(
    title: "SMS Text",
    description: "The bank SMS text to process.",
    inputOptions: String.IntentInputOptions(multiline: true)
  )
  var smsText: String

  @Parameter(title: "Sender", description: "The sender shown by Messages.")
  var senderName: String?

  @Parameter(
    title: "Sender ID",
    description: "The bank sender identifier or short code."
  )
  var senderID: String?

  @Parameter(
    title: "Date Received",
    description: "When the SMS was received."
  )
  var dateReceived: Date?

  @Parameter(
    title: "Device Locale",
    description: "The device locale identifier, such as en_US or ar_SA."
  )
  var deviceLocale: String?

  /// CAP-0: throws (a visible Shortcuts error) whenever the capture could not be
  /// persisted — empty text, Keychain unavailable before first unlock, lock or
  /// App Group failure. Returning a quiet result there told the user a capture
  /// succeeded that was never saved.
  func perform() async throws -> some IntentResult {
    if smsText.trimmingCharacters(in: .whitespacesAndNewlines) == SharedCaptureStore.shortcutSetupProbe {
      SharedCaptureStore.recordShortcutSetupProbe()
      return .result()
    }
    // Signed out: nothing is captured. No queue entry, no upload and no
    // notification (silent by the owner's decision): a bank message is only
    // recorded for an account that is signed in.
    if SharedCaptureStore.isSignedOutForCertain() {
      return .result()
    }
    let receivedAt = dateReceived ?? Date()
    let request = BankSMSCaptureRequest(
      smsText: smsText,
      senderName: senderName,
      senderID: senderID,
      receivedAt: receivedAt,
      // R9: the recipe is meant to always pass Date Received; record when it
      // did not, since the inferred time makes the payload id unstable.
      receivedAtInferred: dateReceived == nil,
      localeIdentifier: SharedCaptureStore.notificationLanguage
    )
    let service = BankSMSCaptureService()
    let config = SharedCaptureStore.backendConfig()

    // One payload ID for both the backend call and the shared queue entry.
    // Two independently computed IDs diverge on edge inputs (e.g. empty-string
    // sender ID), which breaks Flutter's already-imported check and double-imports.
    let payloadID = SharedCaptureStore.makePayloadID(
      text: smsText.trimmingCharacters(in: .whitespacesAndNewlines),
      sender: firstNonEmpty(senderID, senderName),
      senderName: senderName,
      senderID: senderID,
      source: "ios_shortcut",
      receivedAt: SharedCaptureStore.isoString(from: receivedAt)
    )

    if config.canUseBackend {
      // Durability boundary: the complete payload exists in the App Group
      // before the first suspension point/network request. A hard extension
      // kill from here onward leaves a retryable entry with the same payloadId.
      let persisted = try service.capture(
        request,
        status: .pendingSend,
        payloadID: payloadID
      )
      if case let .duplicate(existing) = persisted,
         existing.status != SharedCaptureStore.CaptureStatus.pendingSend.rawValue {
        return .result()
      }

      // CAP-6 (§4.2): re-read the owner under the queue flock. Only a capture
      // still stamped to the ACTIVE owner may leave the device; an unbound
      // capture (no admitted user), a locally-bound one, or an owner whose cloud
      // consent mirror is missing or off stays on the device with zero egress and
      // zero AI (A-12-min R2/R3; a missing mirror is stamped local-only at capture).
      let ownerUid: String
      let ownerGeneration: Int
      let mirrorAllowsAi: Bool
      let decision = SharedCaptureStore.authorizeUpload(payloadID: payloadID)
      // Release diagnostic (constants only): which route and why.
      // os_log with a public format: NSLog arguments are redacted on device.
      os_log("[QirshShortcut] route decision=%{public}@",
             SharedCaptureStore.uploadDecisionReason(payloadID: payloadID))
      switch decision {
      case let .allowed(uid, generation, allowAi):
        ownerUid = uid
        ownerGeneration = generation
        mirrorAllowsAi = allowAi
      case .localOnly:
        _ = SharedCaptureStore.updateStatus(payloadID: payloadID, status: .sent)
        if config.captureNotifyV2 {
          await scheduleGenericCaptureNotification(payloadID: payloadID)
        } else {
          await scheduleLocalParsedOrGenericNotification(
            payloadID: payloadID,
            offersSmartAnalysis: true
          )
        }
        return .result()
      case .waiting:
        // Not this owner's to process now (the owner changed, or a removal is in
        // progress). Durably queued; it waits and no banner is shown.
        _ = SharedCaptureStore.updateStatus(payloadID: payloadID, status: .sent)
        return .result()
      }

      let attempt = await processBackend(
        request,
        payloadID: payloadID,
        config: config,
        ownerUid: ownerUid,
        ownerGeneration: ownerGeneration,
        allowAi: mirrorAllowsAi
      )
      if let response = attempt.response {
        if response.analysisPending {
          // A 202 is a durable receipt, not a failed parse. Keep the native copy
          // until an admitted app import acknowledges the final server result.
          _ = SharedCaptureStore.updateStatus(payloadID: payloadID,
            status: .pendingSend, failureReason: "ai_primary_pending")
          SharedCaptureStore.notifyPendingCaptureUpdateAvailable()
          return .result()
        }
        // H-19: do NOT remove the durable local copy on backend success. The
        // relay row in processed_captures is swept unconditionally at 30 days
        // (run_prune_processed_captures), so deleting the only local copy here
        // loses a capture the user was told succeeded whenever Flutter is not
        // opened before that TTL. Instead mark it `.sent` — the same durable
        // state the cloud-OFF and backend-unreachable paths already use — so the
        // host's per-item lease drain imports it into Drift (locally, on-device,
        // if the relay is already gone) and only THEN acknowledges/removes it.
        // The shared payloadId dedups the relay pull and this local copy to one
        // transaction; `.sent` also tells the drain this path already owns the
        // notification, so no duplicate banner is shown.
        _ = SharedCaptureStore.updateStatus(payloadID: payloadID, status: .sent)
        SharedCaptureStore.notifyPendingCaptureUpdateAvailable()
        // The intent has the parsed result now; Flutter may never be launched.
        // Only a saved capture gets the transaction banner; a duplicate or an
        // unread message keeps the server's own wording.
        let savedCapture = response.notification.type == "new_transaction"
          || response.notification.type == "needs_review"
        let posted = response.notification.title.isEmpty ||
          response.pushAttempted == true || response.pushSent ? false : savedCapture
          ? await scheduleGenericCaptureNotification(
            payloadID: payloadID,
            aiDetail: response.aiDetail
          )
          : await scheduleNotification(
            response.notification,
            payloadID: payloadID,
            identifierPrefix: "capture_backend"
          )
        if posted, response.pushAttempted ?? response.pushSent {
          await Self.removeDeliveredPushes(payloadID: payloadID)
        }
        return .result()
      }
      if mirrorAllowsAi {
        _ = SharedCaptureStore.updateStatus(payloadID: payloadID,
          status: .pendingSend, failureReason: "ai_primary_pending")
        SharedCaptureStore.notifyPendingCaptureUpdateAvailable()
        return .result()
      }
      // Backend unreachable after the idempotent retry. Notify ONLY when the
      // payload is durably queued: a `.duplicate` was queued+notified by an
      // earlier run, and after a `.failed` App Group write there is nothing
      // durable anywhere — a banner would promise a capture that never
      // happened.
      let durableFallback = SharedCaptureStore.updateStatus(
        payloadID: payloadID,
        status: .sent,
        failureReason: attempt.failureReason
      )
      if durableFallback {
        if config.captureNotifyV2 {
          await scheduleGenericCaptureNotification(payloadID: payloadID)
        } else {
          await scheduleLocalParsedOrGenericNotification(payloadID: payloadID)
        }
      }
      return .result()
    }

    os_log("[QirshShortcut] route decision=local_%{public}@",
           SharedCaptureStore.backendConfigGap(config) ?? "config_ok")
    let outcome = try service.capture(request, status: .sent, payloadID: payloadID)
    if case .enqueued = outcome {
      if config.captureNotifyV2 {
        await scheduleGenericCaptureNotification(payloadID: payloadID)
      } else {
        await scheduleLocalParsedOrGenericNotification(
          payloadID: payloadID,
          offersSmartAnalysis: true
        )
      }
    }
    return .result()
  }

  /// One idempotent retry on timeout-shaped failures: the first call may have
  /// committed server-side after the 8s client budget expired. The endpoint is
  /// idempotent per payloadId (a replay returns the stored capture and re-sends
  /// APNs only if it was never delivered), so retrying both recovers the real
  /// outcome and prevents posting a local fallback banner on top of a push
  /// that was actually sent.
  private func processBackend(
    _ request: BankSMSCaptureRequest,
    payloadID: String,
    config: SharedCaptureStore.BackendConfig,
    ownerUid: String,
    ownerGeneration: Int,
    allowAi: Bool
  ) async -> (response: BackendCaptureResponse?, failureReason: String?) {
    let client = BackendCaptureClient(config: config)
    do {
      return (try await client.process(
        request, payloadID: payloadID, ownerUid: ownerUid,
        ownerGeneration: ownerGeneration, allowAi: allowAi
      ), nil)
    } catch {
      guard Self.isTimeoutShaped(error) else { return (nil, "\(error)") }
      do {
        return (try await client.process(
          request, payloadID: payloadID, ownerUid: ownerUid,
        ownerGeneration: ownerGeneration, allowAi: allowAi
        ), nil)
      } catch {
        return (nil, "retry_after_timeout: \(error)")
      }
    }
  }

  private static func isTimeoutShaped(_ error: Error) -> Bool {
    let code = (error as? URLError)?.code
    return code == .timedOut || code == .networkConnectionLost
  }

  /// Deterministic identifier per payloadId: replaying the same payload
  /// replaces the earlier banner instead of stacking a duplicate. userInfo
  /// carries the same routing keys as the APNs payload so AppDelegate's
  /// didReceive handler routes taps on local banners too.
  ///
  /// notificationLogId is this attempt's stable id for the Phase 1
  /// notification tracking pipeline (docs/NOTIFICATION_PIPELINE_AUDIT.md) —
  /// it travels via userInfo into the tap-routing queue so an open can be
  /// correlated back to this exact send. Previously this scheduling call
  /// used `try?` and silently swallowed any failure — a dropped notification
  /// with no log, no retry, and no way to detect it. Now every outcome is
  /// recorded via SharedCaptureStore for Flutter to sync.
  /// True when iOS accepted the notification.
  @discardableResult
  private func scheduleNotification(
    _ notification: BackendNotification,
    payloadID: String,
    identifierPrefix: String,
    categoryIdentifier: String? = nil
  ) async -> Bool {
    let notificationLogId = UUID().uuidString.lowercased()
    SharedCaptureStore.enqueueNotificationLogEvent(
      notificationLogId: notificationLogId,
      eventType: "created",
      channel: "ios_shortcut_local",
      notificationType: notification.type,
      relatedEntityType: "payload",
      relatedEntityId: payloadID
    )

    let content = UNMutableNotificationContent()
    content.title = notification.title
    content.body = notification.body
    content.sound = .default
    if let categoryIdentifier {
      content.categoryIdentifier = categoryIdentifier
    }
    content.userInfo = [
      "payloadId": payloadID,
      "source": "ios_shortcut",
      "notificationType": notification.type,
      "notificationLogId": notificationLogId,
    ]

    let notifRequest = UNNotificationRequest(
      identifier: "\(identifierPrefix)_\(payloadID)",
      content: content,
      trigger: nil
    )
    do {
      try await UNUserNotificationCenter.current().add(notifRequest)
      SharedCaptureStore.enqueueNotificationLogEvent(
        notificationLogId: notificationLogId,
        eventType: "sent",
        channel: "ios_shortcut_local",
        notificationType: notification.type,
        relatedEntityType: "payload",
        relatedEntityId: payloadID
      )
      return true
    } catch {
      SharedCaptureStore.enqueueNotificationLogEvent(
        notificationLogId: notificationLogId,
        eventType: "failed",
        channel: "ios_shortcut_local",
        notificationType: notification.type,
        relatedEntityType: "payload",
        relatedEntityId: payloadID,
        errorCode: "\(type(of: error))",
        errorReason: "\(error)"
      )
      return false
    }
  }

  /// CAP-7 (`capture_notify_v2`, X9): the one local banner of the notification
  /// journey. Built on the device from the local parser (amount, merchant, card,
  /// time), so nothing financial leaves the phone; generic when the parser is
  /// not confident. The identifier is deterministic per payloadId, so a replay
  /// replaces it.
  @discardableResult
  private func scheduleGenericCaptureNotification(
    payloadID: String,
    aiDetail: CaptureDetail? = nil
  ) async -> Bool {
    await scheduleNotification(
      detailedCaptureNotification(aiDetail: aiDetail)
        ?? BackendNotification(
          title: "",
          body: Self.genericCaptureBody(),
          type: "new_transaction"
        ),
      payloadID: payloadID,
      identifierPrefix: "capture_generic"
    )
  }

  /// The detailed banner in Qirsh's selected language: from the server's AI reading
  /// when there is one, else from the local parser; nil when neither read the
  /// message with confidence.
  private func detailedCaptureNotification(
    aiDetail: CaptureDetail? = nil,
    preferredLanguage: String? = SharedCaptureStore.notificationLanguage
  ) -> BackendNotification? {
    // The user's "hide lock-screen content" preference keeps it generic.
    guard !SharedCaptureStore.hidesCaptureDetails,
          let detail = aiDetail ?? localDetail() else { return nil }
    let ar = (preferredLanguage ?? "").hasPrefix("ar")
    let isCredit = detail.isCredit
    let title: String
    switch (isCredit, detail.kind) {
    case (true, _): title = ar ? "تم رصد إيداع 💰" : "Deposit received 💰"
    case (_, "withdrawal"): title = ar ? "تم رصد سحب نقدي 🏧" : "Cash withdrawal 🏧"
    case (_, "transfer"): title = ar ? "تم رصد تحويل 🔁" : "Transfer sent 🔁"
    case (_, "refund"): title = ar ? "تم رصد استرداد ↩️" : "Refund received ↩️"
    default: title = ar ? "تم رصد عملية شراء 🛒" : "New purchase 🛒"
    }
    var lines = [ar
      ? "المبلغ: \(detail.amount) \(detail.currency)"
      : "Amount: \(detail.amount) \(detail.currency)"]
    if let merchant = detail.merchant {
      lines.append(ar
        ? (isCredit ? "المصدر: \(merchant)" : "التاجر: \(merchant)")
        : (isCredit ? "From: \(merchant)" : "Merchant: \(merchant)"))
    }
    if let category = detail.category {
      lines.append(ar ? "التصنيف: \(Self.categoryLabel(category, arabic: true))"
        : "Category: \(Self.categoryLabel(category, arabic: false))")
    }
    if let last4 = detail.last4 {
      lines.append(ar ? "البطاقة: ****\(last4)" : "Card: ****\(last4)")
    }
    let time = Self.timeLabel(for: dateReceived ?? Date(), arabic: ar)
    lines.append(ar ? "الوقت: \(time)" : "Time: \(time)")
    return BackendNotification(
      title: title,
      body: lines.joined(separator: "\n"),
      type: "new_transaction"
    )
  }

  static func categoryLabel(_ key: String, arabic: Bool) -> String {
    let labels: [String: (String, String)] = [
      "restaurants": ("Restaurants", "مطاعم"), "cafes": ("Cafés", "مقاهي"),
      "groceries": ("Groceries", "بقالة"), "transport": ("Transport", "مواصلات"),
      "fuel": ("Fuel", "وقود"), "bills": ("Bills", "فواتير"),
      "shopping": ("Shopping", "تسوق"), "health": ("Health", "صحة"),
      "education": ("Education", "تعليم"), "entertainment": ("Entertainment", "ترفيه"),
      "subscriptions": ("Subscriptions", "اشتراكات"), "transfers": ("Transfers", "تحويل"),
      "cash": ("Cash", "كاش"), "travel": ("Travel", "سفر"),
      "gifts": ("Gifts", "هدايا"), "kids": ("Kids", "أطفال"),
      "home": ("Home", "منزل"), "maintenance": ("Maintenance", "صيانة"),
      "fitness": ("Fitness", "رياضة"), "beauty": ("Beauty", "جمال"),
      "charity": ("Charity", "خيرية"), "pets": ("Pets", "حيوانات"),
      "insurance": ("Insurance", "تأمين"), "income": ("Income", "دخل"),
      "other": ("Other", "أخرى"),
    ]
    guard let label = labels[key] else { return key }
    return arabic ? label.1 : label.0
  }

  private func localDetail() -> CaptureDetail? {
    guard let parser = PreviewParser.shared else { return nil }
    let result = parser.parse(smsText)
    guard result.isHighConfidence, let amount = result.amount, let currency = result.currency else {
      return nil
    }
    let isCredit = result.outcome == .credit
    return CaptureDetail(
      amount: PreviewParser.format(amount),
      currency: currency,
      merchant: result.merchant,
      last4: result.last4,
      kind: isCredit ? "income" : "payment",
      isCredit: isCredit
    )
  }

  /// Removes the generic APNs alert already delivered for [payloadID] (its
  /// userInfo carries the same payloadId), leaving the detailed local banner.
  private static func removeDeliveredPushes(payloadID: String) async {
    let center = UNUserNotificationCenter.current()
    let ids = await center.deliveredNotifications()
      .filter {
        $0.request.trigger is UNPushNotificationTrigger
          && ($0.request.content.userInfo["payloadId"] as? String) == payloadID
      }
      .map(\.request.identifier)
    if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
  }

  /// PROPOSED COPY, pending user approval. English mirrors the server push
  /// (GENERIC_CAPTURE_PUSH); the Arabic is a proposal.
  static func genericCaptureBody(preferredLanguage: String? = SharedCaptureStore.notificationLanguage) -> String {
    (preferredLanguage ?? "").hasPrefix("ar") ? "تم رصد عملية جديدة" : "New transaction captured"
  }

  /// [offersSmartAnalysis] is true only when the backend is not usable
  /// (consent off OR device not registered — indistinguishable here); the
  /// generic fallback then invites enabling Smart Analysis. The
  /// backend-failure path uses [backendFailureBody] instead.
  private func scheduleLocalParsedOrGenericNotification(
    payloadID: String,
    offersSmartAnalysis: Bool = false
  ) async {
    if SharedCaptureStore.hidesCaptureDetails {
      await scheduleGenericCaptureNotification(payloadID: payloadID)
      return
    }
    if let parser = PreviewParser.shared {
      let result = parser.parse(smsText)
      if result.isHighConfidence, let amount = result.amount, let currency = result.currency {
        let isCredit = result.outcome == .credit
        let title = isCredit ? "تم رصد إيداع 💰" : "تم رصد عملية شراء 🛒"
        var lines = ["المبلغ: \(PreviewParser.format(amount)) \(currency)"]
        if let merchant = result.merchant {
          lines.append(isCredit ? "المصدر: \(merchant)" : "التاجر: \(merchant)")
        }
        if let last4 = result.last4 {
          lines.append("البطاقة: ****\(last4)")
        }
        lines.append("الوقت: \(Self.timeLabel(for: dateReceived ?? Date()))")
        await scheduleNotification(
          BackendNotification(
            title: title,
            body: lines.joined(separator: "\n"),
            type: "new_transaction"
          ),
          payloadID: payloadID,
          identifierPrefix: "capture_fallback"
        )
        return
      }
    }
    await scheduleGenericFallbackNotification(
      payloadID: payloadID,
      offersSmartAnalysis: offersSmartAnalysis
    )
  }

  /// "اليوم ٩:٤١ م" بأسلوب صريح: اليوم/أمس/د‏/‏ش — بتوقيت الجهاز.
  private static func timeLabel(for date: Date, arabic: Bool = true) -> String {
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.hour, .minute], from: date)
    let hour24 = comps.hour ?? 0
    let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
    let minute = String(format: "%02d", comps.minute ?? 0)
    let suffix = arabic ? (hour24 < 12 ? "ص" : "م") : (hour24 < 12 ? "AM" : "PM")
    let time = "\(hour12):\(minute) \(suffix)"
    if calendar.isDateInToday(date) { return arabic ? "اليوم \(time)" : "Today \(time)" }
    if calendar.isDateInYesterday(date) { return arabic ? "أمس \(time)" : "Yesterday \(time)" }
    let dayComps = calendar.dateComponents([.day, .month], from: date)
    return "\(dayComps.day ?? 0)/\(dayComps.month ?? 0) \(time)"
  }

  private func scheduleGenericFallbackNotification(
    payloadID: String,
    offersSmartAnalysis: Bool
  ) async {
    let sender = firstNonEmpty(senderName, senderID)
    await QirshNotificationCategories.registerUnrecognizedCapture()
    await scheduleNotification(
      BackendNotification(
        title: SharedCaptureStore.notificationLanguage == "ar" ? "قِرش رصد رسالة بنك" : "Bank message captured",
        body: offersSmartAnalysis
          ? Self.smartAnalysisInviteBody(sender: sender)
          : Self.backendFailureBody(sender: sender),
        type: "received"
      ),
      payloadID: payloadID,
      identifierPrefix: "capture_fallback",
      categoryIdentifier: QirshNotificationCategories.unrecognizedCaptureId
    )
  }

  /// Copy for the backend-unavailable (consent off / not registered) generic
  /// fallback. One text serves both causes: the extension cannot tell them apart.
  static func smartAnalysisInviteBody(sender: String?, preferredLanguage: String = SharedCaptureStore.notificationLanguage) -> String {
    if preferredLanguage != "ar" {
      return "Couldn't recognize \(sender ?? "the bank") message automatically. Enable Smart Analysis to read new bank messages, or add it manually."
    }
    guard let sender, !sender.isEmpty else {
      return "لم نتعرّف على رسالة البنك تلقائيًا. فعّل التحليل الذكي ليحاول قِرش فهم رسائل البنوك الجديدة، أو أضفها يدويًا."
    }
    return "لم نتعرّف على رسالة \(sender) تلقائيًا. فعّل التحليل الذكي ليحاول قِرش فهم رسائل البنوك الجديدة، أو أضفها يدويًا."
  }

  /// Backend-failure generic fallback (the backend was usable but did not
  /// answer, and the on-device PreviewParser has no confident result). Says the
  /// analysis failed for now and points to review / manual entry; the capture is
  /// already stored durably (`.sent` + failureReason) for the app to import.
  static func backendFailureBody(sender: String?, preferredLanguage: String = SharedCaptureStore.notificationLanguage) -> String {
    if preferredLanguage != "ar" {
      return "Couldn't analyze \(sender ?? "the bank") message right now. Open Qirsh to review it or add it manually."
    }
    guard let sender, !sender.isEmpty else {
      return "تعذّر تحليل رسالة البنك الآن. افتح قِرش لمراجعتها أو إضافتها يدويًا."
    }
    return "تعذّر تحليل رسالة \(sender) الآن. افتح قِرش لمراجعتها أو إضافتها يدويًا."
  }

  private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
      if let clean = value?.trimmingCharacters(in: .whitespacesAndNewlines),
         !clean.isEmpty {
        return clean
      }
    }
    return nil
  }
}

/// Registers Mali shortcuts with the Shortcuts app and Siri.
struct BankMessageShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: PostBankStatusIntent(),
      phrases: [
        "Process Bank SMS in \(.applicationName)",
        "Process Bank SMS with \(.applicationName)",
        "Import bank SMS in \(.applicationName)",
        "Add transaction from SMS in \(.applicationName)",
        "Log bank expense in \(.applicationName)",
        "Track bank transaction in \(.applicationName)",
        "Send bank SMS to \(.applicationName)"
      ],
      shortTitle: "Process Bank SMS",
      systemImageName: "creditcard"
    )
  }
}

/// Immutable input model used by App Intents before writing to shared storage.
///
/// Keeping this separate from the intent makes future intents such as Add
/// Transaction or Quick Expense able to reuse the same capture pipeline.
@available(iOS 16.0, *)
struct BankSMSCaptureRequest {
  let smsText: String
  let senderName: String?
  let senderID: String?
  let receivedAt: Date?
  let receivedAtInferred: Bool?
  let localeIdentifier: String?
}

/// Intent-facing capture service.
///
/// The service intentionally avoids Flutter APIs. App extensions should stay
/// small, deterministic, and independent from the host app UI process.
@available(iOS 16.0, *)
struct BankSMSCaptureService {
  private let queue: CaptureQueueWriting

  init(queue: CaptureQueueWriting = SharedCaptureStoreWriter()) {
    self.queue = queue
  }

  @discardableResult
  func capture(
    _ request: BankSMSCaptureRequest,
    status: SharedCaptureStore.CaptureStatus = .pending,
    sentAt: Date? = nil,
    failureReason: String? = nil,
    payloadID: String? = nil
  ) throws -> SharedCaptureStore.EnqueueResult {
    let trimmedText = request.smsText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedText.isEmpty else {
      throw ProcessBankSMSError.emptySMSText
    }

    let result = queue.enqueue(
      text: trimmedText,
      senderName: request.senderName,
      senderID: request.senderID,
      source: "ios_shortcut",
      receivedAt: request.receivedAt ?? Date(),
      localeIdentifier: SharedCaptureStore.notificationLanguage,
      status: status,
      sentAt: sentAt,
      failureReason: failureReason,
      payloadID: payloadID,
      receivedAtInferred: request.receivedAtInferred
    )

    #if DEBUG
      debugPrint(
        "[MaliShortcut] received smsLength=\(trimmedText.count) " +
        "senderNameSet=\(!(request.senderName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) " +
        "senderIDSet=\(!(request.senderID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)) " +
        "receivedAt=\((request.receivedAt ?? Date()).ISO8601Format()) source=ios_shortcut"
      )
    #endif

    if case let .failed(reason, kind) = result {
      // Internal diagnostic only (no SMS text); the user sees the kind's copy.
      NSLog("[QirshShortcut] capture not persisted: %@", reason)
      throw kind == .emptyText
        ? ProcessBankSMSError.emptySMSText
        : ProcessBankSMSError.captureFailed(kind)
    }
    return result
  }
}

/// Queue abstraction for dependency injection and future App Intent tests.
@available(iOS 16.0, *)
protocol CaptureQueueWriting {
  func enqueue(
    text: String,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: Date,
    localeIdentifier: String?,
    status: SharedCaptureStore.CaptureStatus,
    sentAt: Date?,
    failureReason: String?,
    payloadID: String?,
    receivedAtInferred: Bool?
  ) -> SharedCaptureStore.EnqueueResult
}

/// App Group backed queue writer used by production App Intents.
@available(iOS 16.0, *)
struct SharedCaptureStoreWriter: CaptureQueueWriting {
  func enqueue(
    text: String,
    senderName: String?,
    senderID: String?,
    source: String?,
    receivedAt: Date,
    localeIdentifier: String?,
    status: SharedCaptureStore.CaptureStatus,
    sentAt: Date?,
    failureReason: String?,
    payloadID: String?,
    receivedAtInferred: Bool?
  ) -> SharedCaptureStore.EnqueueResult {
    SharedCaptureStore.enqueue(
      text: text,
      sender: senderID ?? senderName,
      senderName: senderName,
      senderID: senderID,
      source: source,
      receivedAt: receivedAt,
      localeIdentifier: localeIdentifier,
      status: status,
      sentAt: sentAt,
      failureReason: failureReason,
      payloadID: payloadID,
      receivedAtInferred: receivedAtInferred
    )
  }
}

// MARK: - Backend capture client

@available(iOS 16.0, *)
struct BackendNotification {
  let title: String
  let body: String
  let type: String
}

@available(iOS 16.0, *)
struct BackendCaptureResponse {
  let notification: BackendNotification
  let pushSent: Bool
  /// The v2 response's `push_attempted` (CAP-3); nil on the legacy response.
  let pushAttempted: Bool?
  /// What the server's AI read from this message (`capture.parsed`), returned
  /// to this phone over the same HTTPS reply; nil when it read no amount.
  var aiDetail: CaptureDetail? = nil
  var analysisPending: Bool = false
}

/// The fields a capture banner shows, from the server's AI or the local parser.
struct CaptureDetail {
  let amount: String
  let currency: String
  let merchant: String?
  let last4: String?
  /// payment | withdrawal | transfer | income | refund | unknown
  let kind: String
  let isCredit: Bool
  var category: String? = nil
}

@available(iOS 16.0, *)
enum BackendCaptureError: Error {
  case invalidConfig
  case invalidURL
  /// C.4 admission: the egress state, the owner or the consent mirror no longer
  /// permits this upload. NO request was made.
  case egressDenied
  case http(Int)
  case malformedResponse
  /// A redaction rule failed to compile, so the sanitizer cannot promise the
  /// text is clean. Raised rather than swallowed: this client posts to a
  /// backend that forwards the text to an AI service, and a rule that quietly
  /// did nothing used to mean the raw SMS went out in full.
  case sanitizerUnavailable
}

@available(iOS 16.0, *)
struct BackendCaptureClient {
  let config: SharedCaptureStore.BackendConfig

  func process(
    _ request: BankSMSCaptureRequest,
    payloadID: String,
    ownerUid: String,
    ownerGeneration: Int,
    allowAi: Bool
  ) async throws -> BackendCaptureResponse {
    guard config.canUseBackend,
          let backendURL = config.backendURL,
          let installID = config.installID,
          let deviceSecret = config.deviceSecret,
          let anonKey = config.anonKey else {
      throw BackendCaptureError.invalidConfig
    }
    guard let url = URL(string: "\(backendURL)/functions/v1/process-ios-sms") else {
      throw BackendCaptureError.invalidURL
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.timeoutInterval = SharedCaptureStore.nativeUploadTimeout
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    urlRequest.setValue(anonKey, forHTTPHeaderField: "apikey")
    urlRequest.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
    let sanitized = try Self.sanitize(request.smsText)
    var body: [String: Any] = [
      "payloadId": payloadID,
      "installId": installID,
      "deviceSecret": deviceSecret,
      "smsText": sanitized,
      "sanitizedText": sanitized,
      "sender": request.senderID ?? request.senderName ?? "",
      "senderName": request.senderName ?? "",
      "senderId": request.senderID ?? "",
      "receivedAt": SharedCaptureStore.isoString(from: request.receivedAt ?? Date()),
      "tzOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
      "locale": SharedCaptureStore.notificationLanguage,
      "source": "ios_shortcut",
      "localNotification": true,
      "notificationDetails": !SharedCaptureStore.hidesCaptureDetails,
      // The owner's consent mirror is the only source (A-12-min R2): there is no
      // install-level fallback, so an upload never carries a wider AI grant.
      "allowAi": allowAi
    ]
    // C.1: EVERY upload, on BOTH schema versions, carries the stamped owner_uid
    // and the owner_generation it was stamped under. An ownerless upload is
    // impossible: `ownerUid` is not optional, and an unstamped item is never
    // `.allowed` by authorizeUpload. `schema_version` 2 stays capability-gated.
    body["owner_uid"] = ownerUid
    body["owner_generation"] = ownerGeneration
    if config.captureContractV2 {
      body["schema_version"] = 2
    }
    if allowAi {
      body["analysis_mode"] = "ai_primary_v1"
      body["backgroundAnalysis"] = true
      body["localNotification"] = false
    }
    urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

    // C.4 / H3.1: the request goes ONLY through the one gated native transport
    // (SharedCaptureStore.gatedUpload). Immediately before the request it admits
    // under the queue flock (egress state, the exact (owner, generation) and the
    // durable in-flight registration, deadline = now + timeout + 2 s, so the
    // app's disable drain can wait for it), removes the registry entry on EVERY
    // exit, refuses redirects and uses an ephemeral session. This also covers the
    // idempotent timeout retry. DISABLING / OFF / unreadable => no request.
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await SharedCaptureStore.gatedUpload(
        urlRequest, payloadID: payloadID, ownerUid: ownerUid, ownerGeneration: ownerGeneration)
    } catch SharedCaptureStore.QueueError.egressDenied {
      throw BackendCaptureError.egressDenied
    }
    let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
    if statusCode == 202,
       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
       let state = json["state"] as? String,
       state == "in_progress" || state == "retryable" {
      return BackendCaptureResponse(
        notification: BackendNotification(title: "", body: "", type: "received"),
        pushSent: false, pushAttempted: nil, analysisPending: true)
    }
    guard statusCode == 200 else {
      throw BackendCaptureError.http(statusCode)
    }
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let capture = json["capture"] as? [String: Any],
      let notification = capture["notification"] as? [String: Any],
      let title = notification["title"] as? String,
      let body = notification["body"] as? String
    else {
      throw BackendCaptureError.malformedResponse
    }
    return BackendCaptureResponse(notification: BackendNotification(
      title: title,
      body: body,
      type: notification["type"] as? String ?? "received"
    ), pushSent: json["pushSent"] as? Bool ?? false,
       pushAttempted: json["push_attempted"] as? Bool,
       aiDetail: Self.aiDetail(capture["parsed"] as? [String: Any]))
  }

  static func aiDetail(_ parsed: [String: Any]?) -> CaptureDetail? {
    guard let parsed,
          let amount = parsed["amount"] as? Double, amount > 0,
          let currency = parsed["currency"] as? String, !currency.isEmpty
    else { return nil }
    func text(_ key: String) -> String? {
      guard let value = parsed[key] as? String, !value.isEmpty else { return nil }
      return value
    }
    let last4 = text("last4").flatMap { $0.count == 4 && $0.allSatisfy(\.isNumber) ? $0 : nil }
    return CaptureDetail(
      amount: text("amount_text") ?? PreviewParser.format(amount),
      currency: currency,
      merchant: text("merchant"),
      last4: last4,
      kind: text("type") ?? "unknown",
      isCredit: text("direction") == "credit" || text("type") == "income",
      category: text("category")
    )
  }

  /// Internal (not private) so RunnerTests can run the shared redaction
  /// fixture against it; still only called by [process].
  static func sanitize(_ text: String) throws -> String {
    var value = text
    // ORDER MATTERS and mirrors `lib/engine/privacy/sms_sanitizer.dart`:
    // card -> phone -> IBAN -> OTP -> account. The generic account rule is last
    // because it would otherwise eat the digit run inside a more specific match.
    //
    // IBAN and OTP were missing here while this copy carried a comment claiming
    // parity with the Dart sanitizer. They are not optional: this is the path
    // that reaches an off-device AI service, so it was the WEAKEST of the three
    // sanitizers guarding the most sensitive egress. The account rule cannot
    // stand in for the IBAN rule — `\b\d{10,20}\b` never matches a Saudi IBAN,
    // because there is no word boundary between "SA" and the digits that follow.
    // Every digit shape this market sends: Latin, Arabic-Indic (U+0660-0669)
    // and extended Arabic-Indic (U+06F0-06F9). ASCII `\d` alone meant a card
    // or account number written in the digits half the market uses was
    // forwarded to the model untouched. They are matched in place rather than
    // normalised away, because the proof layer compares model output against
    // spans of the very string that was sent.
    // ICU escapes (\uFFFF), not Swift's \u{...}: these live inside raw
    // strings, so the regex engine is what reads them.
    let d = #"[0-9\u0660-\u0669\u06F0-\u06F9]"#
    // `\b` is defined over [A-Za-z0-9_] alone, so it does not treat U+0660 as
    // a word character and would place a "boundary" inside an Arabic-Indic
    // run. These are that assertion widened; on ASCII input they are exactly
    // equivalent to `\b`.
    let nb = #"(?<![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])"#
    let nbEnd = #"(?![0-9\u0660-\u0669\u06F0-\u06F9A-Za-z_])"#

    let specificRules: [(String, String)] = [
      // E-mail first: a local part such as `ahmed0551234567` would otherwise be
      // half-eaten by the phone rule.
      (#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[EMAIL]"),
      (#"\#(nb)\#(d){4}[\s-]?\#(d){4}[\s-]?\#(d){4}[\s-]?\#(d){4}\#(nbEnd)"#, "[CARD]"),
      // The leading 0 and 5 may themselves be Arabic-Indic, so they are classes.
      (#"\#(nb)[0\u0660\u06F0][5\u0665\u06F5]\#(d){8}\#(nbEnd)"#, "[PHONE]"),
      (#"\#(nb)[0\u0660\u06F0][1\u0661\u06F1][0125\u0660\u0661\u0662\u0665\u06F0\u06F1\u06F2\u06F5]\#(d){8}\#(nbEnd)"#, "[PHONE]"),
      (#"\+\#(d){7,15}\#(nbEnd)"#, "[PHONE]"),
      // The country code is matched case-insensitively: `sa0380...` is the same
      // identifier as `SA0380...` and used to pass straight through.
      (#"\#(nb)[A-Za-z]{2}\#(d){2}[A-Za-z0-9\u0660-\u0669\u06F0-\u06F9]{11,30}\#(nbEnd)"#, "[IBAN]")
    ]
    let genericRules: [(String, String)] = [
      (#"\#(nb)\#(d){10,20}\#(nbEnd)"#, "[ACCOUNT]")
    ]

    // A rule that will not compile is thrown, never skipped. `try?` + `continue`
    // here meant a broken pattern silently redacted nothing and the raw SMS
    // was posted in full to a backend that forwards it to an AI service.
    func apply(_ rules: [(String, String)]) throws {
      for (pattern, replacement) in rules {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
          throw BackendCaptureError.sanitizerUnavailable
        }
        value = regex.stringByReplacingMatches(
          in: value,
          range: NSRange(location: 0, length: (value as NSString).length),
          withTemplate: replacement
        )
      }
    }

    try apply(specificRules)
    // Cue-anchored OTP, applied before the generic account rule. Redacting any
    // 4-8 digit run by shape would destroy amounts and card suffixes, so only
    // digits FOLLOWING an explicit cue are removed — and the cue is kept, so the
    // message stays classifiable as an OTP. Mirrors the Dart `_otp` rule.
    let otpPattern =
      #"((?:otp|one[- ]?time(?:\s+password)?|verification\s+code|"# +
      #"رمز\s+التحقق|كود\s+التحقق|رمز\s+الدخول)"# +
      #"(?:\s+(?:is|هو))?\s*:?\s*)\#(d){4,8}"#
    guard let otpRegex = try? NSRegularExpression(
      pattern: otpPattern,
      options: [.caseInsensitive]
    ) else {
      throw BackendCaptureError.sanitizerUnavailable
    }
    value = otpRegex.stringByReplacingMatches(
      in: value,
      options: [],
      range: NSRange(value.startIndex..., in: value),
      withTemplate: "$1[OTP]"
    )

    try apply(genericRules)

    // Rules below mirror `lib/engine/privacy/sms_sanitizer.dart` and
    // `supabase/functions/_shared/sms_redaction.ts` exactly; the fixture
    // `supabase/functions/_shared/fixtures/sms_redaction_cases.json` holds all
    // three to the same output (RunnerTests).
    func replace(_ pattern: String, _ template: String) throws {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        throw BackendCaptureError.sanitizerUnavailable
      }
      value = regex.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: template
      )
    }
    func matches(_ pattern: String) throws -> Bool {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
        throw BackendCaptureError.sanitizerUnavailable
      }
      return regex.firstMatch(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length)
      ) != nil
    }

    // Reference numbers, cue-anchored, AFTER the account rule (10+ digits are
    // already [ACCOUNT]). A run that continues into a decimal is an amount.
    let refChar = #"[A-Za-z0-9٠-٩۰-۹\-]"#
    try replace(
      #"((?<![\p{L}\p{M}])(?:reference|ref|rrn|رقم[ \t]+المرجع|الرقم[ \t]+المرجعي|المرجع|مرجع|"# +
        #"رقم[ \t]+العملية|رقم[ \t]+الحوالة|رقم[ \t]+المعاملة)(?![\p{L}\p{M}])"# +
        #"(?:[ \t]*(?:no|number|num|id)(?![\p{L}\p{M}]))?[ \t]*[.:#]*[ \t]*)"# +
        #"(?=\#(refChar)*\#(d))\#(refChar){6,}(?!\#(refChar)|[.,٫٬]\#(d))"#,
      "$1[REF]"
    )

    // Personal names → "[NAME]", cue kept. A name is 1-6 letter tokens and
    // stops at a digit, punctuation, a line break, a placeholder or a stopword.
    let stopwords = [
      "your", "yours", "you", "our", "us", "the", "a", "an", "account", "accounts", "acct", "ac", "card",
      "cards", "wallet", "mobile", "phone", "number", "no", "on", "at", "in", "into", "via", "using", "with",
      "for", "of", "to", "from", "by", "ref", "reference", "rrn", "amount", "amt", "is", "was", "has",
      "have", "been", "and", "or", "date", "time", "balance", "bal", "avl", "available", "avail", "customer",
      "customers", "client", "cardholder", "holder", "valued", "sir", "madam", "member", "there", "team",
      "atm", "branch", "bank", "app", "online", "internet", "instapay", "ipn", "sarie", "mada", "swift",
      "transfer", "transaction", "trx", "txn", "successful", "successfully", "credit", "debit", "credited",
      "debited", "cash", "deposit", "salary", "sar", "egp", "aed", "usd", "eur", "gbp", "kwd", "qar", "bhd",
      "omr", "jod", "le", "sr", "riyal", "riyals", "pound", "pounds", "dirham", "dirhams", "dinar", "dinars",
      "dollar", "dollars", "transferred", "sent", "received", "paid", "made", "requested", "deposited",
      "withdrew", "initiated", "will", "would", "name", "حسابك", "حسابكم", "حساب", "الحساب", "حسابات",
      "لحسابك", "لحساب", "للحساب", "بطاقتك", "بطاقتكم", "بطاقة", "البطاقة", "بطاقه", "رصيدك", "رصيد",
      "الرصيد", "خلال", "قبل", "في", "على", "عن", "إلى", "الى", "الي", "من", "بمبلغ", "مبلغ", "المبلغ",
      "بقيمة", "قيمة", "بتاريخ", "تاريخ", "يوم", "اليوم", "الساعة", "الساعه", "ساعة", "وقت", "رقم", "عبر",
      "بواسطة", "محفظة", "محفظتك", "المحفظة", "ريال", "جنيه", "جم", "درهم", "دينار", "دولار", "يورو",
      "العميل", "عميلنا", "عملائنا", "عزيزي", "تطبيق", "الصراف", "صراف", "جهاز", "مدى", "سريع", "انستاباي",
      "حوالة", "حواله", "تحويل", "التحويل", "الحوالة", "واردة", "وارده", "صادرة", "صادره", "البنك", "بنك",
      "فرع", "عند", "لدى", "و", "تم", "المتاح", "متاح", "المرجع", "مرجع", "رسوم", "عمولة", "قام", "حول",
      "حوّل", "أرسل", "ارسل", "إرسال", "ارسال", "بتحويل", "بإرسال", "استلم", "أودع", "اودع", "سحب", "دفع"
    ].joined(separator: "|")
    let nameToken = #"(?!(?:\#(stopwords))(?![\p{L}\p{M}*'’\-]|\.[\p{L}\p{M}]))[\p{L}\p{M}*][\p{L}\p{M}*.'’\-]*"#
    let name = #"\#(nameToken)(?:[ \t]+\#(nameToken)){0,5}"#
    let cueSep = #"(?:[ \t]*:[ \t]*|[ \t]+)"#
    // Salutations: Arabic anywhere; English only at a text or sentence start.
    try replace(
      #"((?:(?<![\p{L}\p{M}])(?:عزيزي|عزيزتي|السيدة|السيد|الأستاذة|الاستاذة|الأستاذ|الاستاذ)"# +
        #"|(?:^|(?<=[\n.!?؟؛;:،,]))[ \t]*(?:dear|hi|hello))(?![\p{L}\p{M}])\#(cueSep))(\#(name))"#,
      "$1[NAME]"
    )
    // Counterparty cues only when the text reads as a transfer/credit and NOT
    // as a purchase/refund/bill — so "Purchase from AMAZON" keeps its merchant.
    // (ASCII lookarounds instead of `\b`: ICU's `\b` is Unicode-aware, the
    // Dart/JS one is not.)
    let w = "(?<![A-Za-z0-9_])"
    let wEnd = "(?![A-Za-z0-9_])"
    let transferContext = try matches(
      #"transfer|remit|received|credited|deposit|\#(w)ipn\#(wEnd)|instapay|beneficiary|"# +
        #"\#(w)sent\#(wEnd)|حوال|تحويل|حول|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|مستفيد|المرسل|انستا|لصالح"#
    )
    let purchaseContext = try matches(
      #"purchase|\#(w)pos\#(wEnd)|point of sale|paid at|spent|refund|revers|e-?commerce|\#(w)bill|merchant|"# +
        #"شراء|مشتريات|نقاط البيع|نقطة بيع|نقاط بيع|استرداد|مسترد|مرتجع|إرجاع|ارجاع|فاتور|سداد|تاجر"#
    )
    if transferContext && !purchaseContext {
      try replace(
        #"((?<![\p{L}\p{M}])(?:from|to|by|beneficiary(?:[ \t]+name)?|sender(?:[ \t]+name)?|"# +
          #"remitter(?:[ \t]+name)?|recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|"# +
          #"on[ \t]+behalf[ \t]+of|in[ \t]+favou?r[ \t]+of|mrs|mr|ms|dr|من[ \t]+قبل|اسم[ \t]+المستفيد|"# +
          #"اسم[ \t]+المرسل|المستفيد|المرسل|المحول|لصالح|باسم|بواسطة|من|إلى|الى|الي)"# +
          #"\.?(?![\p{L}\p{M}])\#(cueSep))(\#(name))"#,
        "$1[NAME]"
      )
    }
    // Third-party PII: beneficiary/sender names after إلى:/الى:/To: and
    // Arabic greetings with a personal name — mirrors
    // lib/engine/privacy/sms_sanitizer.dart so both capture paths (this
    // direct Shortcut→backend call and the Dart retry-fallback in
    // capture_sync_service.dart) redact the same way. No transaction-type
    // detection happens client-side here, so this always strips — safer to
    // over-redact an unknown message than leak a third party's identity.
    if let arBeneficiary = try? NSRegularExpression(
      pattern: #"(إلى|الى)\s*:?\s*.+"#,
      options: .caseInsensitive
    ) {
      value = arBeneficiary.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: "$1: [REDACTED]"
      )
    }
    if let enBeneficiary = try? NSRegularExpression(
      pattern: #"\bTo\s*:\s*.+"#,
      options: .caseInsensitive
    ) {
      value = enBeneficiary.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: "To: [REDACTED]"
      )
    }
    if let greeting = try? NSRegularExpression(
      pattern: #"(عزيزي|عزيزتي)\s+\S+"#,
      options: .caseInsensitive
    ) {
      value = greeting.stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: "[REDACTED]"
      )
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

/// Localized user-facing errors surfaced by Shortcuts.
@available(iOS 16.0, *)
enum ProcessBankSMSError: Error, LocalizedError {
  case emptySMSText
  case captureFailed(SharedCaptureStore.FailureKind)

  /// R9 copy rule: fixed, approved text only. Never an OSStatus, errSec*,
  /// QueueError description or raw localization key.
  var errorDescription: String? {
    switch self {
    case .emptySMSText:
      return SharedCaptureStore.FailureKind.emptyText.userMessage
    case let .captureFailed(kind):
      return kind.userMessage
    }
  }
}

// MARK: - Shared rule-based preview parser

/// Mirrors `lib/engine/parser/shared_preview_parser.dart` and reads the SAME
/// `assets/catalog/parser_rules.json` that Flutter bundles — one rules file,
/// two runtimes, identical semantics. Any change to the algorithm here must
/// be applied to the Dart mirror too; the Dart tests over the embedded
/// examples are the contract for both.
@available(iOS 16.0, *)
enum PreviewOutcome {
  case debit
  case credit
  case unknown
  case ignored
}

@available(iOS 16.0, *)
struct PreviewResult {
  let outcome: PreviewOutcome
  let amount: Double?
  let currency: String?
  let merchant: String?
  let last4: String?

  /// Detailed notification only when type + amount + currency are all clear.
  var isHighConfidence: Bool {
    (outcome == .debit || outcome == .credit) && amount != nil && currency != nil
  }
}

@available(iOS 16.0, *)
final class PreviewParser {
  /// nil when the rules file can't be found/parsed — callers fall back to the
  /// generic notification text.
  static let shared: PreviewParser? = loadBundledRules()

  private let currencyReplacements: [(NSRegularExpression, String)]
  private let decimalMarks: [String]
  private let thousandsMarks: [String]
  private let currencyPattern: NSRegularExpression
  private let ignoreKeywords: [String]
  private let debitKeywords: [String]
  private let creditKeywords: [String]
  private let amountPatterns: [NSRegularExpression]
  private let merchantPatterns: [NSRegularExpression]
  private let merchantStopPattern: NSRegularExpression
  private let last4Patterns: [NSRegularExpression]
  private let thousandsBetweenDigits: NSRegularExpression

  private init?(json: [String: Any]) {
    func regex(_ pattern: String) -> NSRegularExpression? {
      try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
    func regexes(_ value: Any?) -> [NSRegularExpression]? {
      guard let patterns = value as? [String] else { return nil }
      let compiled = patterns.compactMap(regex)
      return compiled.count == patterns.count ? compiled : nil
    }

    guard
      let normalization = json["normalization"] as? [String: Any],
      let replacementItems = normalization["currencyReplacements"] as? [[String: String]],
      let decimalMarks = normalization["decimalMarks"] as? [String],
      let thousandsMarks = normalization["thousandsMarks"] as? [String],
      let currencyPatternString = json["currencyPattern"] as? String,
      let currencyPattern = regex(currencyPatternString),
      let ignoreKeywords = json["ignoreKeywords"] as? [String],
      let debitKeywords = json["debitKeywords"] as? [String],
      let creditKeywords = json["creditKeywords"] as? [String],
      let amountPatterns = regexes(json["amountPatterns"]),
      let merchantPatterns = regexes(json["merchantPatterns"]),
      let merchantStopString = json["merchantStopPattern"] as? String,
      let merchantStopPattern = regex(merchantStopString),
      let last4Patterns = regexes(json["last4Patterns"]),
      let thousandsBetweenDigits = regex("(\\d),(\\d)")
    else { return nil }

    var replacements: [(NSRegularExpression, String)] = []
    for item in replacementItems {
      guard let pattern = item["pattern"], let replacement = item["replacement"],
            let compiled = regex(pattern) else { return nil }
      replacements.append((compiled, replacement))
    }

    self.currencyReplacements = replacements
    self.decimalMarks = decimalMarks
    self.thousandsMarks = thousandsMarks
    self.currencyPattern = currencyPattern
    self.ignoreKeywords = ignoreKeywords
    self.debitKeywords = debitKeywords
    self.creditKeywords = creditKeywords
    self.amountPatterns = amountPatterns
    self.merchantPatterns = merchantPatterns
    self.merchantStopPattern = merchantStopPattern
    self.last4Patterns = last4Patterns
    self.thousandsBetweenDigits = thousandsBetweenDigits
  }

  /// Locates the Flutter-bundled rules file. Works both when the intent runs
  /// inside the main app (Bundle.main = Runner.app) and inside the extension
  /// (Bundle.main = Runner.app/PlugIns|Extensions/BankMessageShortcuts.appex).
  private static func loadBundledRules() -> PreviewParser? {
    let assetPath =
      "Frameworks/App.framework/flutter_assets/assets/catalog/parser_rules.json"
    let bundleURL = Bundle.main.bundleURL
    let candidates = [
      bundleURL,
      bundleURL.deletingLastPathComponent().deletingLastPathComponent(),
    ]
    for base in candidates {
      let url = base.appendingPathComponent(assetPath)
      guard let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data)
              as? [String: Any]
      else { continue }
      return PreviewParser(json: json)
    }
    return nil
  }

  func parse(_ text: String) -> PreviewResult {
    let normalized = normalize(text)
    let lower = normalized.lowercased()

    if ignoreKeywords.contains(where: { lower.contains($0) }) {
      return PreviewResult(
        outcome: .ignored, amount: nil, currency: nil, merchant: nil, last4: nil
      )
    }

    return PreviewResult(
      outcome: detectOutcome(in: lower),
      amount: firstGroup(amountPatterns, in: normalized).flatMap(Double.init),
      currency: extractCurrency(from: normalized),
      merchant: extractMerchant(from: normalized),
      last4: firstGroup(last4Patterns, in: normalized)
    )
  }

  static func format(_ amount: Double) -> String {
    amount == amount.rounded(.towardZero)
      ? String(Int(amount))
      : String(format: "%.2f", amount)
  }

  private func normalize(_ input: String) -> String {
    var text = Self.normalizeDigits(input)
    for mark in decimalMarks {
      text = text.replacingOccurrences(of: mark, with: ".")
    }
    for mark in thousandsMarks {
      text = text.replacingOccurrences(of: mark, with: "")
    }
    for (pattern, replacement) in currencyReplacements {
      text = pattern.stringByReplacingMatches(
        in: text,
        range: NSRange(location: 0, length: (text as NSString).length),
        withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
      )
    }
    // فواصل الآلاف بين رقمين: 12,500.00 → 12500.00 (حلقة لأن التطابقات تتداخل).
    while thousandsBetweenDigits.firstMatch(
      in: text, range: NSRange(location: 0, length: (text as NSString).length)
    ) != nil {
      text = thousandsBetweenDigits.stringByReplacingMatches(
        in: text,
        range: NSRange(location: 0, length: (text as NSString).length),
        withTemplate: "$1$2"
      )
    }
    return text
  }

  private static func normalizeDigits(_ input: String) -> String {
    let arabicIndicZero: UInt32 = 0x0660
    let extendedArabicIndicZero: UInt32 = 0x06F0
    var output = String.UnicodeScalarView()
    for scalar in input.unicodeScalars {
      if scalar.value >= arabicIndicZero, scalar.value <= arabicIndicZero + 9 {
        output.append(Unicode.Scalar(0x30 + (scalar.value - arabicIndicZero))!)
      } else if scalar.value >= extendedArabicIndicZero,
                scalar.value <= extendedArabicIndicZero + 9 {
        output.append(
          Unicode.Scalar(0x30 + (scalar.value - extendedArabicIndicZero))!)
      } else {
        output.append(scalar)
      }
    }
    return String(output)
  }

  private func detectOutcome(in lower: String) -> PreviewOutcome {
    let debitIndex = Self.earliestIndex(of: debitKeywords, in: lower)
    let creditIndex = Self.earliestIndex(of: creditKeywords, in: lower)
    switch (debitIndex, creditIndex) {
    case (nil, nil): return .unknown
    case (_, nil): return .debit
    case (nil, _): return .credit
    case let (debit?, credit?):
      // الاثنان موجودان — الأسبق في النص يحسم (وعند التساوي: خصم).
      return debit <= credit ? .debit : .credit
    }
  }

  private static func earliestIndex(
    of keywords: [String], in lower: String
  ) -> String.Index? {
    var earliest: String.Index?
    for keyword in keywords {
      guard let range = lower.range(of: keyword) else { continue }
      if earliest == nil || range.lowerBound < earliest! {
        earliest = range.lowerBound
      }
    }
    return earliest
  }

  private func extractCurrency(from normalized: String) -> String? {
    firstGroupMatch(currencyPattern, in: normalized)?.uppercased()
  }

  private func extractMerchant(from normalized: String) -> String? {
    guard let raw = firstGroup(merchantPatterns, in: normalized) else {
      return nil
    }
    var merchant = merchantStopPattern.stringByReplacingMatches(
      in: raw,
      range: NSRange(location: 0, length: (raw as NSString).length),
      withTemplate: ""
    )
    let edgeTrim = CharacterSet(charactersIn: " \t\n\r.,:;؛*-")
    merchant = merchant.trimmingCharacters(in: edgeTrim)
    return merchant.isEmpty ? nil : merchant
  }

  private func firstGroup(
    _ patterns: [NSRegularExpression], in text: String
  ) -> String? {
    for pattern in patterns {
      if let value = firstGroupMatch(pattern, in: text) {
        return value
      }
    }
    return nil
  }

  private func firstGroupMatch(
    _ pattern: NSRegularExpression, in text: String
  ) -> String? {
    let nsText = text as NSString
    let range = NSRange(location: 0, length: nsText.length)
    guard let match = pattern.firstMatch(in: text, range: range),
          match.numberOfRanges > 1,
          match.range(at: 1).location != NSNotFound
    else { return nil }
    let value = nsText.substring(with: match.range(at: 1))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? nil : value
  }
}

/// Notification category for an unrecognized bank message, with the two
/// foreground actions. Single copy: this file is compiled into the Runner
/// target. Categories are registered via flutter_local_notifications
/// initialisation (local_notification_service.dart) and merged by the Shortcut
/// before scheduling (the app may not have launched since an update).
enum QirshNotificationCategories {
  static let unrecognizedCaptureId = "QIRSH_UNRECOGNIZED_CAPTURE"
  static let enableSmartAnalysisActionId = "qirsh.enable_smart_analysis"
  static let addManuallyActionId = "qirsh.add_manually"
  static let actionIds: Set<String> = [enableSmartAnalysisActionId, addManuallyActionId]

  static func registerUnrecognizedCapture() async {
    let category = UNNotificationCategory(
      identifier: unrecognizedCaptureId,
      actions: [
        UNNotificationAction(
          identifier: enableSmartAnalysisActionId,
          title: SharedCaptureStore.notificationLanguage == "ar" ? "تفعيل التحليل الذكي" : "Enable Smart Analysis",
          options: [.foreground]
        ),
        UNNotificationAction(
          identifier: addManuallyActionId,
          title: SharedCaptureStore.notificationLanguage == "ar" ? "إضافة يدويًا" : "Add manually",
          options: [.foreground]
        ),
      ],
      intentIdentifiers: [],
      options: []
    )
    let center = UNUserNotificationCenter.current()
    // Merge: other components (e.g. flutter_local_notifications) may have
    // registered their own categories; replace only ours.
    var categories = await center.notificationCategories()
    categories = categories.filter { $0.identifier != unrecognizedCaptureId }
    categories.insert(category)
    center.setNotificationCategories(categories)
  }
}
