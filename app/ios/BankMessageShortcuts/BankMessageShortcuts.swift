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
    // Signed out: nothing is captured or kept — no queue entry and no upload,
    // so the message can never attach to whichever account signs in next.
    // Owner decision 3.13: never report success. The run fails with the
    // signed-out copy (Shortcuts shows it), and one content-free banner with
    // the same copy is posted (replaced, not stacked, on repeat runs).
    if SharedCaptureStore.isSignedOutForCertain() {
      await Self.postSignedOutNotification()
      throw ProcessBankSMSError.captureFailed(.signedOut)
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
            aiDetail: response.aiDetail,
            status: response.notification.type == "needs_review" ? .needsReview : .queued
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
    aiDetail: CaptureDetail? = nil,
    status: CaptureBannerStatus = .queued
  ) async -> Bool {
    await scheduleNotification(
      detailedCaptureNotification(aiDetail: aiDetail, status: status)
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
    status: CaptureBannerStatus = .queued,
    preferredLanguage: String? = SharedCaptureStore.notificationLanguage
  ) -> BackendNotification? {
    // The user's "hide lock-screen content" preference keeps it generic.
    guard !SharedCaptureStore.hidesCaptureDetails,
          let detail = aiDetail ?? localDetail() else { return nil }
    return Self.captureBanner(
      detail: detail,
      fromServerAnalysis: aiDetail != nil,
      status: status,
      receivedAt: dateReceived ?? Date(),
      arabic: (preferredLanguage ?? "").hasPrefix("ar")
    )
  }

  /// Owner decision 3.12: what a native capture banner may say. Built here, at
  /// capture time, BEFORE the app has imported the message — so it never says
  /// the transaction was recorded, never names a category (the final category
  /// is chosen on import: manual > saved rule > AI) and states the real status:
  /// queued for Qirsh to check, or waiting for the user's review. A type is
  /// shown only from the server's validated analysis; the on-device preview
  /// only matches keywords, so it claims no outcome (V1-061). The amount is in
  /// the title (visible collapsed); the details are in the multi-line body
  /// (visible expanded). Nothing else from the message is copied: no sender,
  /// no raw text, a bounded merchant name, and a card/account hint only when
  /// it is exactly four digits. iOS hides title and body when the user turned
  /// notification previews off (no category here opts into showing them).
  static func captureBanner(
    detail: CaptureDetail,
    fromServerAnalysis: Bool,
    status: CaptureBannerStatus,
    receivedAt: Date,
    arabic ar: Bool
  ) -> BackendNotification {
    var lines: [String] = []
    if fromServerAnalysis, let type = typeLabel(detail, arabic: ar) {
      lines.append(ar ? "النوع: \(type)" : "Type: \(type)")
    }
    if let merchant = boundedMerchant(detail.merchant) {
      let label: String
      if fromServerAnalysis {
        label = detail.isCredit ? (ar ? "المصدر" : "From") : (ar ? "التاجر" : "Merchant")
      } else {
        label = ar ? "الجهة" : "Merchant/source"
      }
      lines.append("\(label): \(merchant)")
    }
    if let last4 = detail.last4, last4.count == 4,
       last4.allSatisfy({ ("0"..."9").contains($0) }) {
      lines.append(ar ? "البطاقة/الحساب: ••••\(last4)" : "Card/account ending \(last4)")
    }
    let time = timeLabel(for: receivedAt, arabic: ar)
    lines.append(ar ? "الوقت: \(time)" : "Time: \(time)")
    switch status {
    case .queued:
      lines.append(ar
        ? "لم تُسجَّل بعد: يتحقق منها قِرش قبل إضافتها."
        : "Not recorded yet: Qirsh checks it before adding it.")
    case .needsReview:
      lines.append(ar
        ? "تحتاج مراجعتك في قِرش قبل تسجيلها."
        : "Needs your review in Qirsh before it is recorded.")
    }
    return BackendNotification(
      title: ar
        ? "رسالة بنك: \(detail.amount) \(detail.currency)"
        : "Bank message: \(detail.amount) \(detail.currency)",
      body: lines.joined(separator: "\n"),
      type: status == .needsReview ? "needs_review" : "new_transaction"
    )
  }

  private static func typeLabel(_ detail: CaptureDetail, arabic ar: Bool) -> String? {
    if detail.isCredit && detail.kind != "refund" { return ar ? "إيداع" : "Deposit" }
    switch detail.kind {
    case "payment": return ar ? "شراء" : "Purchase"
    case "withdrawal": return ar ? "سحب نقدي" : "Cash withdrawal"
    case "transfer": return ar ? "تحويل" : "Transfer"
    case "refund": return ar ? "استرداد" : "Refund"
    case "income": return ar ? "إيداع" : "Deposit"
    default: return nil
    }
  }

  /// A merchant name is short; anything longer is more of the message than a
  /// name, so it is cut rather than shown whole.
  private static func boundedMerchant(_ raw: String?) -> String? {
    guard let clean = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
          !clean.isEmpty else { return nil }
    return clean.count > 40 ? String(clean.prefix(40)) + "…" : clean
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
    // V1-035: the same localized banner as the v2 path (it was Arabic-only).
    if let banner = detailedCaptureNotification() {
      await scheduleNotification(
        banner,
        payloadID: payloadID,
        identifierPrefix: "capture_fallback"
      )
      return
    }
    await scheduleGenericFallbackNotification(
      payloadID: payloadID,
      offersSmartAnalysis: offersSmartAnalysis
    )
  }

  /// "اليوم ٩:٤١ م" بأسلوب صريح: اليوم/أمس/د‏/‏ش — بتوقيت الجهاز.
  static func timeLabel(for date: Date, arabic: Bool = true) -> String {
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

  /// Owner decision 3.13: the signed-out banner. Content-free (no amount, no
  /// sender, no message text); one stable identifier, so a repeat run replaces
  /// it instead of stacking banners.
  static let signedOutNotificationId = "capture_signed_out"

  private static func postSignedOutNotification() async {
    let content = UNMutableNotificationContent()
    content.title = SharedCaptureStore.notificationLanguage == "ar" ? "قِرش" : "Qirsh"
    content.body = SharedCaptureStore.FailureKind.signedOut.userMessage
    content.sound = .default
    let request = UNNotificationRequest(
      identifier: signedOutNotificationId, content: content, trigger: nil)
    // Best effort: the thrown error carries the same copy if banners are off.
    try? await UNUserNotificationCenter.current().add(request)
  }
}

/// Owner decision 3.12: the status a native capture banner states.
enum CaptureBannerStatus {
  /// Stored on the device; Qirsh still checks it before recording it.
  case queued
  /// The analysis asked for the user's review before anything is recorded.
  case needsReview
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
      // LEN-1: the message's length as received (trimmed, as queued), in
      // UTF-16 units like Dart/JS `String.length`, measured BEFORE redaction
      // shortens it. The server sends anything over 2,000 to review.
      "textLength": Self.textLength(request.smsText),
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

  /// LEN-1 measure shared by the upload body and the queued payload.
  static func textLength(_ text: String) -> Int {
    text.trimmingCharacters(in: .whitespacesAndNewlines).utf16.count
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
  /// fixtures against it; still only called by [process].
  ///
  /// PRIV-0 (closure FU10–12): a rule-for-rule port of the server's
  /// `redactPii` + `redactThirdPartyNames` in
  /// `supabase/functions/_shared/sms_redaction.ts`, which the Dart
  /// `SmsSanitizer` also mirrors. The fixtures
  /// `_shared/fixtures/sms_redaction_cases.json` and
  /// `sms_leak_labelled_cases.json` hold all three to the same output
  /// (RunnerTests). Translation notes, so a future edit stays faithful:
  /// - JS `\b` is ASCII-only; ICU's is Unicode-aware, so it is written as
  ///   `(?<![A-Za-z0-9_])` / `(?![A-Za-z0-9_])`.
  /// - ICU needs a bounded look-behind. Unbounded runs inside a look-behind are
  ///   bounded here; every bound errs toward masking MORE, except the sentence
  ///   span of the beneficiary-number pass, bounded at 4,000 characters (twice
  ///   the server's length limit).
  static func sanitize(_ text: String) throws -> String {
    var value = text
    // A rule that will not compile is thrown, never skipped: a broken pattern
    // that silently redacted nothing once meant the raw SMS was posted in full
    // to a backend that forwards it to an AI service.
    func regex(_ pattern: String, _ caseInsensitive: Bool) throws -> NSRegularExpression {
      guard let regex = try? NSRegularExpression(
        pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []
      ) else {
        throw BackendCaptureError.sanitizerUnavailable
      }
      return regex
    }
    func replace(_ pattern: String, _ template: String, ci: Bool = true) throws {
      value = try regex(pattern, ci).stringByReplacingMatches(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length),
        withTemplate: template
      )
    }
    func matches(_ pattern: String) throws -> Bool {
      try regex(pattern, true).firstMatch(
        in: value,
        range: NSRange(location: 0, length: (value as NSString).length)
      ) != nil
    }
    func alternation(_ words: [String]) -> String { words.joined(separator: "|") }

    // Every digit shape this market sends: Latin, Arabic-Indic (U+0660-0669)
    // and extended Arabic-Indic (U+06F0-06F9), matched in place (the proof
    // layer compares model output against spans of the string that was sent).
    // ICU escapes (￿) inside raw strings: the regex engine reads them.
    let d = #"[0-9٠-٩۰-۹]"#
    let alnum = #"[A-Za-z0-9٠-٩۰-۹]"#
    // `\b` widened to Arabic-Indic digits; on ASCII exactly `\b`.
    let nb = #"(?<![0-9٠-٩۰-۹A-Za-z_])"#
    let nbEnd = #"(?![0-9٠-٩۰-۹A-Za-z_])"#
    let w = "(?<![A-Za-z0-9_])"
    let wEnd = "(?![A-Za-z0-9_])"
    let notLetter = #"(?![\p{L}\p{M}])"#
    let noLetterBefore = #"(?<![\p{L}\p{M}])"#
    let currency = alternation(Self.currencyAfter)

    // ── redactPii ── ORDER MATTERS: specific shapes first, the generic
    // account rule after them (it would eat the digits inside a specific match).
    try replace(#"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#, "[EMAIL]", ci: false)
    // Spaced IBAN, before the card rule (which ate its middle 16 digits).
    try replace(
      #"\#(nb)[A-Za-z]{2}\#(d){2}(?:[ \-](?=\#(alnum){0,3}\#(d))\#(alnum){4}){3,7}"# +
        #"(?:[ \-](?=\#(alnum){0,3}\#(d))\#(alnum){1,3})?\#(nbEnd)"#,
      "[IBAN]", ci: false)
    try replace(#"\#(nb)\#(d){4}[\s-]?\#(d){4}[\s-]?\#(d){4}[\s-]?\#(d){4}\#(nbEnd)"#, "[CARD]", ci: false)
    // R4P-07: phone numbers written in groups, before the unspaced rules.
    try replace(#"\#(nb)[0٠۰][5٥۵]\#(d)[ \-]\#(d){3}[ \-]\#(d){4}\#(nbEnd)"#, "[PHONE]", ci: false)
    try replace(
      #"\#(nb)[0٠۰][1١۱][0125٠١٢٥۰۱۲۵][ \-]\#(d){4}[ \-]\#(d){4}\#(nbEnd)"#, "[PHONE]", ci: false)
    try replace(#"\+\#(d){1,3}(?:[ \-]\#(d){1,4}){2,4}\#(nbEnd)"#, "[PHONE]", ci: false)
    // The leading 0 and 5 may themselves be Arabic-Indic, so they are classes.
    try replace(#"\#(nb)[0٠۰][5٥۵]\#(d){8}\#(nbEnd)"#, "[PHONE]", ci: false)
    try replace(
      #"\#(nb)[0٠۰][1١۱][0125٠١٢٥۰۱۲۵]\#(d){8}\#(nbEnd)"#,
      "[PHONE]", ci: false)
    try replace(#"\+\#(d){7,15}\#(nbEnd)"#, "[PHONE]", ci: false)
    try replace(#"\#(nb)[A-Za-z]{2}\#(d){2}\#(alnum){11,30}\#(nbEnd)"#, "[IBAN]", ci: false)
    // Cue-anchored OTP: the cue is kept so the message stays classifiable.
    try replace(
      #"((?:otp|one[- ]?time(?:\s+password)?|verification\s+code|"# +
        #"رمز\s+التحقق|كود\s+التحقق|رمز\s+الدخول)(?:\s+(?:is|هو))?\s*:?\s*)\#(d){4,8}"#,
      "$1[OTP]")
    // Round 4 (real-model run): a one-time code never leaves the device,
    // whatever the cue wording and on whichever side of the code the cue sits.
    // Still cue-anchored: a figure next to a currency, a decimal or grouped
    // figure, a date or time and a card or account suffix are never a code.
    // Server twin: OTP_PATTERNS, in the same order.
    let otpCurrency =
      #"sar|egp|aed|usd|eur|gbp|kwd|qar|bhd|omr|jod|le|sr|riyals?|pounds?|dirhams?|dinars?|dollars?|ريال|جنيه|جم|درهم|دينار|دولار|يورو|ر\.س"#
    let otpCue =
      #"(?:otp|one[- ]?time[ \t]+(?:password|passcode|pin|code)|pin|tac|mtoken|token|secure[ \t]+code"# +
      // "Your authorization code is …" is a verification code.
      #"|(?<=your[ \t])(?:authorization|authorisation|auth|approval)[ \t]+code"# +
      #"|(?:verification|security|activation|confirmation|authentication|access|login|secret)[ \t]+code"# +
      // A purchase's approval, reference or promo code is not a one-time code.
      #"|passcode|password|(?<!(?:approval|auth|authorization|authorisation|reference|transaction|receipt|pickup|promo|discount|coupon|voucher|order|branch|swift|bank|area|postal)[ \t])code|كلمة[ \t]+المرور(?:[ \t]+لمرة[ \t]+واحدة)?|كلمة[ \t]+السر"# +
      #"|(?:رمز|كود)[ \t]+(?:التحقق|الدخول|التفعيل|الأمان|الامان|التأكيد|التاكيد)|الرمز[ \t]+السري|رمز[ \t]+سري|الرقم[ \t]+السري"# +
      #"|رمزك|الرمز|رمز|كودك|الكود|كود)"#
    let otpNumber =
      #"(?<![0-9٠-٩۰-۹*•#]|\#(d)[.,٫٬/:\-]|\#(noLetterBefore)(?:\#(otpCurrency))[ \t]{0,3}"# +
      #"|\#(noLetterBefore)(?:card|account|acct|ending|بطاقة|البطاقة|حساب|الحساب)[ \t]{1,3})"# +
      // Also "482-913" and "4 8 2 9 1 3"; a currency after it makes it an
      // amount unless another figure follows the currency.
      #"(?:\#(d){4,8}|\#(d){3}[\- ]\#(d){3}|\#(d)(?:[ ]\#(d)){3,7})"# +
      #"(?!\#(d)|[.,٫٬/:\-]\#(d)|[ \t]*(?:\#(otpCurrency))\#(notLetter)(?![ \t]*\#(d)))"#
    // Words that may sit between the cue and the code.
    let otpQualifier =
      #"(?:[ \t]+(?:المؤقتة|المؤقت|مؤقتة|مؤقت|لمرة[ \t]+واحدة|التالي|التالية|الخاص[ \t]+بك|الخاصة[ \t]+بك|الجديد|الجديدة|below|following)\#(notLetter))*"#
    // The placeholder: `[OTP]` under verification wording. Under a bare cue
    // ("code 4829", "Use 4829 …") it is `[OTP]` too, unless an earlier
    // sentence already states an amount — a promo, pickup or receipt code
    // after a movement, written `[REF]` so no server reads the movement as an
    // OTP notice. Server twin: codePlaceholder.
    let otpBareCue = try regex(#"^(?:code|رمزك|الرمز|رمز|كودك|الكود|كود)\z"#, true)
    let otpSentenceEnd = try regex(#"[\n!?؟]|\.(?!\#(d))"#, false)
    let otpMoney = try regex(#"\#(noLetterBefore)(?:\#(otpCurrency))\#(notLetter)"#, true)
    let otpDigit = try regex(d, false)
    func maskCodes(_ pattern: String, _ mode: String) throws {
      let re = try regex(pattern, true)
      let source = value as NSString
      let result = NSMutableString(string: value)
      for m in re.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
        let prefix = source.substring(with: m.range(at: 1))
        var placeholder = "[OTP]"
        let cue = mode == "cue" && m.range(at: 2).location != NSNotFound
          ? source.substring(with: m.range(at: 2)) : ""
        let verification = mode == "strong" || (mode == "cue" &&
          otpBareCue.firstMatch(in: cue, range: NSRange(location: 0, length: (cue as NSString).length)) == nil)
        if !verification {
          let before = source.substring(to: m.range.location)
          let beforeRange = NSRange(location: 0, length: (before as NSString).length)
          var end = 0
          for s in otpSentenceEnd.matches(in: before, range: beforeRange) {
            end = s.range.location + s.range.length
          }
          let earlier = (before as NSString).substring(to: end)
          let earlierRange = NSRange(location: 0, length: (earlier as NSString).length)
          if otpDigit.firstMatch(in: earlier, range: earlierRange) != nil,
             otpMoney.firstMatch(in: earlier, range: earlierRange) != nil {
            placeholder = "[REF]"
          }
        }
        result.replaceCharacters(in: m.range, with: prefix + placeholder)
      }
      value = result as String
    }
    // First, so the wording decides: a code is what a message says not to share.
    try maskCodes(
      #"()\#(otpNumber)(?=[ \t]*[.,،;]?\s*(?:(?:please|الرجاء|يرجى)[ \t]+)?(?:do[ \t]+not[ \t]+share|don['’]?t[ \t]+share|never[ \t]+share|لا[ \t]+تشارك|عدم[ \t]+مشارك|لا[ \t]+تفصح))"#,
      "strong")
    // A code alone on its line, the next line saying what to use it for.
    try maskCodes(
      #"((?:^|(?<=\n))[ \t]*)\#(otpNumber)(?=[ \t]*[.:]?[ \t]*\n[ \t]*(?:use|enter|استخدم|أدخل|ادخل)\#(notLetter))"#,
      "strong")
    // "Never share this: 482913", «لا تشارك هذا الرمز: 482913».
    try maskCodes(
      #"(\#(noLetterBefore)(?:never[ \t]+share|do[ \t]+not[ \t]+share|don['’]?t[ \t]+share|لا[ \t]+تشارك[\p{L}\p{M}]*)(?:[ \t]+(?:this|it|the[ \t]+code|هذا[ \t]+الرمز|الرمز))?[ \t]*[:\-]?[ \t]*)\#(otpNumber)"#,
      "strong")
    try maskCodes(
      #"(\#(noLetterBefore)(\#(otpCue))\#(notLetter)\#(otpQualifier)(?:[ \t]*(?:is|are|was|no\.?|number|هو|هي|رقم)\#(notLetter))?[ \t]*[:#=\-]?[ \t]*)\#(otpNumber)"#,
      "cue")
    try maskCodes(
      #"(\#(noLetterBefore)(\#(otpCue))\#(notLetter)(?:[^\n.!?؟]|\.(?=\#(d))){0,80}?\#(noLetterBefore)(?:is|are|هو|هي)\#(notLetter)[ \t]*:?[ \t]*)\#(otpNumber)"#,
      "cue")
    try maskCodes(
      #"()\#(otpNumber)(?=[ \t]+(?:is|هو|هي)[ \t]+(?:(?:your|the)[ \t]+)?(?:[\p{L}\p{M}]+[ \t]+){0,3}?(\#(otpCue))\#(notLetter))"#,
      "cue")
    try maskCodes(
      #"(\#(noLetterBefore)(?:use|enter|type|استخدم|أدخل|ادخل)\#(notLetter)[ \t]+(?:(?:the|this)[ \t]+)?)\#(otpNumber)"#,
      "weak")
    try replace(#"\#(nb)\#(d){10,20}\#(nbEnd)"#, "[ACCOUNT]", ci: false)
    // Labelled account numbers of 5-9 digits; a ≤4-digit suffix and an amount
    // (a currency or a decimal part after it) stay.
    try replace(
      #"(\#(noLetterBefore)(?:account|acct|acc|a\/c|ac|حساب|الحساب|لحساب|للحساب|بحساب|حسابك|لحسابك|حسابكم|حسابي)"# +
        #"\#(notLetter)\.?(?:[ \t]+(?:no|number|num|رقم)\#(notLetter)\.?)?[ \t]*[:#]?[ \t]*)"# +
        #"[*xX•#]*\#(d){5,9}(?!\#(d)|[.,٫٬]\#(d)|[ \t]*(?:\#(currency))\#(notLetter)(?![ \t]*\#(d)))"#,
      "$1[ACCOUNT]")
    // Reference numbers, cue-anchored; a run that continues into a decimal is an amount.
    let refChar = #"[A-Za-z0-9٠-٩۰-۹\-]"#
    try replace(
      #"(\#(noLetterBefore)(?:reference|ref|rrn|رقم[ \t]+المرجع|الرقم[ \t]+المرجعي|المرجع|مرجع|"# +
        #"رقم[ \t]+العملية|رقم[ \t]+الحوالة|رقم[ \t]+المعاملة)\#(notLetter)"# +
        #"(?:[ \t]*(?:no|number|num|id)\#(notLetter))?[ \t]*[.:#]*[ \t]*)"# +
        #"(?=\#(refChar)*\#(d))\#(refChar){6,}(?!\#(refChar)|[.,٫٬]\#(d))"#,
      "$1[REF]")

    // ── redactThirdPartyNames ──
    // A period that ends a sentence is never part of a name (SM-07); an
    // initial or title keeps its period.
    let sentenceEnd =
      #"(?:(?<!(?<![\p{L}\p{M}])(?:\p{L}|mrs|mr|ms|dr))\.(?=\s|$)|[\n!?؟;؛])"#
    // R4P-01: after an Arabic name particle the next word is part of the name
    // whatever it is («عبد العزيز», «أبو بكر», «بن سعود», «آل سعود»).
    let afterParticle =
      #"(?<=(?<![\p{L}\p{M}])(?:عبد|أبو|ابو|أبي|ابي|بن|ابن|بنت|آل|أم|ام)[ \t]{1,3})"#
    let arabicPrefix = #"(?:[وف](?=[ء-ي]{2}))?"#
    // The veto of a name token (server twin: stopAt): a stop word as a whole
    // token; not after a name particle; a one-letter stop word before
    // ". Name" or before another name word is an initial (R4P-05).
    func nameTokenOf(_ words: [String]) -> String {
      let stop = alternation(words)
      return #"(?!(?!\#(afterParticle))\#(arabicPrefix)(?:\#(stop))(?![\p{L}\p{M}*'’\-]|\.[\p{L}\p{M}]"# +
        #"|(?<=(?<![\p{L}\p{M}])\p{L})\.[ \t]+\p{L}"# +
        #"|(?<=(?<![\p{L}\p{M}])\p{L})[ \t]+(?!(?:\#(stop))(?![\p{L}\p{M}]))\p{L}))"# +
        #"(?!\*+\#(d))[\p{L}\p{M}*](?:[\p{L}\p{M}*'’\-]|(?!\#(sentenceEnd))\.)*(?![\p{L}\p{M}*'’\-]|\#(d))"#
    }
    let nameToken = nameTokenOf(Self.nameStopwords)
    let looseNameToken = nameTokenOf(Self.nameStopwords + Self.looseStopwords)
    let looseName = #"\#(looseNameToken)(?:[ \t]+\#(looseNameToken)){0,5}"#
    let labelSep = #"(?:[ \t]*[:\-][ \t]*|[ \t]+)"#
    let name = #"\#(nameToken)(?:[ \t]+\#(nameToken)){0,5}"#
    let cueSep = #"(?:[ \t]*:[ \t]*|[ \t]+)"#
    // Salutations: Arabic anywhere; English only at a text or sentence start.
    try replace(
      #"((?:\#(noLetterBefore)(?:عزيزي|عزيزتي|السيدة|السيد|الأستاذة|الاستاذة|الأستاذ|الاستاذ|(?:عميلنا|عميلتنا)[ \t]+(?:العزيز|العزيزة|الكريم|الكريمة)[ \t]*[\/:\-])"# +
        #"|(?:^|(?<=[\n.!?؟؛;:،,]))[ \t]*(?:dear|hi|hello))\#(notLetter)\#(cueSep))(\#(name))"#,
      "$1[NAME]")
    // Text-decided helpers shared by the passes below (server twins: maskName,
    // maskCapitalisedName, scanSuffixes, isMerchantContext, keepsBeneficiary).
    func has(_ re: NSRegularExpression, _ s: String) -> Bool {
      re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
    // Replaces each match of `pattern` with what `transform` returns; a nil
    // leaves the match as it is.
    func replaceEach(
      _ pattern: String, ci: Bool = true,
      _ transform: (NSTextCheckingResult, NSString) -> String?
    ) throws {
      let re = try regex(pattern, ci)
      let source = value as NSString
      let result = NSMutableString(string: value)
      for m in re.matches(in: value, range: NSRange(location: 0, length: source.length)).reversed() {
        if let replacement = transform(m, source) {
          result.replaceCharacters(in: m.range, with: replacement)
        }
      }
      value = result as String
    }
    // A business, by the words a business name carries; such a counterparty is
    // a merchant and is kept, whatever the cue.
    let companyMarker = try regex(
      #"\#(noLetterBefore)(?:\#(alternation(Self.companyMarkers)))\#(notLetter)"#, true)
    // The leading capitalised (or Arabic, or star-masked) words of a match.
    let capitalisedRun = try regex(#"^[\p{Lu}\p{Lo}*][^ \t]*(?:[ \t]+[\p{Lu}\p{Lo}*][^ \t]*)*"#, false)
    // THE DECISION RULE for person or merchant is stated once, in
    // `sms_redaction.ts`. After the bare prepositions "to" and "by", a single
    // lower-case Latin word followed by a determiner is a verb, not a name.
    let barePreposition = try regex(#"\#(noLetterBefore)(?:to|by)[ \t]+\z"#, true)
    let lowerCaseWord = try regex(#"^\p{Ll}[^ \t]*\z"#, false)
    let determinerAfter = try regex(
      #"^[ \t]+(?:your|the|this|that|these|those|a|an|it|my|our|all|any)\#(notLetter)"#, true)
    // A person, whatever words the name carries (server twin: maskPerson); with
    // `payee`, a name carrying a business-form word is kept (maskPayee).
    func maskPerson(_ pattern: String, payee: Bool = false) throws {
      try replaceEach(pattern) { m, s in
        let cue = s.substring(with: m.range(at: 1))
        let name = s.substring(with: m.range(at: 2))
        if payee && has(companyMarker, name) { return nil }
        let after = s.substring(from: m.range.location + m.range.length)
        return has(barePreposition, cue) && has(lowerCaseWord, name) && has(determinerAfter, after)
          ? nil : cue + "[NAME]"
      }
    }
    func maskPayee(_ pattern: String) throws { try maskPerson(pattern, payee: true) }
    func maskCapitalisedName(_ pattern: String) throws {
      try replaceEach(pattern) { m, s in
        let name = s.substring(with: m.range(at: 2)) as NSString
        guard let run = capitalisedRun.firstMatch(
          in: name as String, range: NSRange(location: 0, length: name.length)
        ) else { return nil }
        return s.substring(with: m.range(at: 1)) + "[NAME]" + name.substring(from: run.range.length)
      }
    }

    // ── Account and card suffixes: THE RULE in `sms_redaction.ts` ──
    let thirdParty = alternation(Self.thirdPartyWords)
    let thirdPartyEnglish = alternation(Array(Self.thirdPartyWords.prefix(8)))
    let suffixNumberEnd = #"(?!\#(d)|[.,٫٬/:]\#(d)|[ \t]*(?:\#(currency))\#(notLetter)(?![ \t]*\#(d)))"#
    let labelledSuffix = try regex(
      #"(\#(noLetterBefore)(?:(?:your|my)[ \t]+)?(?:(?:debit|credit|prepaid|mada|visa|mastercard|current|savings|bank|corporate|business|personal|joint|main|primary|\#(thirdPartyEnglish))[ \t]+)*"# +
        #"(?:\#(alternation(Self.suffixLabels)))\#(notLetter)"# +
        #"(?:[ \t]+(?:ending|ends|in|with|no\.?|number|num|رقم|برقم|المنتهية|منتهية|تنتهي|بـ|ب|مدى|mada|visa|mastercard|الائتمانية|ائتمانية|الجديدة|الجديد|\#(thirdParty))\#(notLetter))*[ \t]*[:#]?[ \t]*)"# +
        #"([*xX•#]*\#(d){1,9}[*•]*)\#(suffixNumberEnd)"#, true)
    let maskedSuffix = try regex(
      #"(?<![A-Za-z0-9٠-٩۰-۹*•.,٫٬/:\-])()((?:[*•]+|[xX]{2,})[*xX•]*\#(d){1,9}[*•]*|\#(d){1,9}[*•]+)\#(suffixNumberEnd)"#,
      false)
    // `\z`, not `$`: ICU's `$` also matches before a final line break.
    let open = #"[ \t]*:?[ \t]*(?:(?:the|a|an)[ \t]+)?\z"#
    let thirdPartyWord = try regex(#"\#(noLetterBefore)(?:\#(thirdParty))\#(notLetter)"#, true)
    let thirdPartyBefore = try regex(
      #"(?:\[NAME\]|\[REDACTED\]|\#(noLetterBefore)(?:\#(thirdParty))\#(notLetter))(?:['’]s)?\#(open)"#, true)
    let possessive = try regex(
      #"\#(noLetterBefore)(?:your|my|حسابك|لحسابك|بحسابك|حسابكم|لحسابكم|حسابي|بطاقتك|ببطاقتك|لبطاقتك|بطاقتكم|بطاقتي|محفظتك|لمحفظتك)\#(notLetter)"#,
      true)
    let possessiveBefore = try regex(#"\#(noLetterBefore)(?:your|my)[ \t]+\z"#, true)
    let destinationBefore = try regex(
      #"\#(noLetterBefore)(?:to|into|in|إلى|الى|الي|في)\#(notLetter)\#(open)"#, true)
    let destinationLabel = try regex(#"^(?:لحساب|للحساب|لبطاقة|للبطاقة)\#(notLetter)"#, false)
    let creditVerbBefore = try regex(
      #"\#(noLetterBefore)(?:credited|deposited|refunded|refund|reversal|added|received|returned|arrived|posted|applied|charged|billed|[وف]?(?:إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضاف|اضاف)[\p{L}\p{M}]*|استرداد|استرجاع|واردة|وارده|وارد)\#(notLetter)(?:[^.\n;؛!?؟]|\.(?=\#(d))|\.(?=[ \t]+(?:to|into)\#(notLetter))){0,60}\z"#,
      true)
    let outgoingWords = try regex(
      #"\#(noLetterBefore)(?:transferred|sent|paid|دفع|صادرة|صادره|صادر|حولت|أرسلت|ارسلت)\#(notLetter)"#,
      true)
    let incomingWords = try regex(
      #"received|credited|deposit|incoming|refund|وارد|استلام|استلمت|إيداع|ايداع|أودع|اودع|أضيف|اضيف|إضافة|اضافة"#, true)
    let fromBefore = try regex(#"\#(noLetterBefore)(?:from|من)\#(notLetter)\#(open)"#, true)
    // A debit verb before "from" makes it the user's side even when the text
    // also credits something ("debited from account … and credited to …").
    let debitVerbBefore = try regex(
      #"\#(noLetterBefore)(?:debited|deducted|withdrawn|[وف]?(?:خصم|سحب)[\p{L}\p{M}]*)\#(notLetter)(?:[^.\n;؛!?؟]|\.(?=\#(d))){0,60}\z"#,
      true)
    let instrumentBefore = try regex(
      #"\#(noLetterBefore)(?:with|using|via|by|through|عبر|باستخدام|بواسطة)\#(notLetter)\#(open)"#, true)
    let instrumentLabel = try regex(#"^(?:بحساب|بالحساب)\#(notLetter)"#, false)
    let cardLabel = try regex(
      #"\#(noLetterBefore)(?:card|mada|visa|mastercard|apple[ \t]+pay|بطاقة|البطاقة|ببطاقة|بالبطاقة|لبطاقة|للبطاقة|بطاقه|مدى)\#(notLetter)"#,
      true)
    let transferWords = try regex(
      #"transfer|remit|received|credited|deposit|\#(w)ipn\#(wEnd)|instapay|beneficiary|payable\s+to|request(?:ed)?\s+from|(?:payment|money|pay|transfer|fund)s?\s+requests?|requests?\s+(?:to\s+pay|for\s+(?:payment|money))|\#(w)requested\#(wEnd)|"# +
        #"\#(w)sent\#(wEnd)|standing\s+order|حوال|تحويل|حول|وارد|وصلك|طلب\s+(?:دفع|تحويل|مبلغ|أموال|اموال)|استلام|استلمت|إيداع|ايداع|أودع|اودع|"# +
        #"مستفيد|المرسل|انستا|لصالح|أمر\s+(?:مستديم|دائم)|امر\s+(?:مستديم|دائم)"#, true)
    // "merchant" / «تاجر» alone reads as a purchase only where nothing says
    // transfer («إلى محمد التاجر» is a surname in a transfer).
    let purchaseWords = try regex(
      #"purchase|\#(w)pos\#(wEnd)|point of sale|paid at|spent|refund|revers|e-?commerce|\#(w)bill|"# +
        #"شراء|انترنت|إنترنت|مشتريات|نقاط البيع|نقطة بيع|نقاط بيع|استرداد|مسترد|مرتجع|إرجاع|ارجاع|فاتور|سداد"#, true)
    let weakPurchaseWords = try regex(#"merchant|تاجر"#, true)
    // A transfer or remittance by its own wording: its counterparty is masked
    // whole and a purchase or refund word does not make it a purchase (server
    // twin: STRONG_TRANSFER_WORDS).
    let strongTransferWords = try regex(
      #"transfer|remit|beneficiary|\#(w)ipn\#(wEnd)|instapay|\#(w)sent\#(wEnd)|payable\s+to|request(?:ed)?\s+from|(?:payment|money|pay|transfer|fund)s?\s+requests?|requests?\s+(?:to\s+pay|for\s+(?:payment|money))|\#(w)requested\#(wEnd)|"# +
        #"standing\s+order|حوال|تحويل|حول|مستفيد|المرسل|لصالح|وصلك|أرسل|ارسل|طلب\s+(?:دفع|تحويل|مبلغ|أموال|اموال)|انستا|أمر\s+(?:مستديم|دائم)|امر\s+(?:مستديم|دائم)"#, true)
    func readsAsPurchase(_ s: String) -> Bool {
      !has(strongTransferWords, s) &&
        (has(purchaseWords, s) || (has(weakPurchaseWords, s) && !has(transferWords, s)))
    }
    let paymentWords = try regex(#"payment|\#(w)paid\#(wEnd)|\#(w)pay\#(wEnd)|دفع"#, true)
    let maskedPerson = try regex(#"\[NAME\]|\[REDACTED\]"#, false)
    let nameInParensAfter = try regex(#"^[ \t]*\([ \t]*\[NAME\]"#, false)
    let digit = try regex(d, false)

    // Every labelled or star-masked short number with the rule's verdict, in
    // text order; `range` bounds the number (stars included).
    func scanSuffixes(_ text: String, purchase: Bool) -> [(range: NSRange, card: Bool, own: Bool)] {
      let source = text as NSString
      var found: [(range: NSRange, card: Bool, own: Bool)] = []
      let incoming = has(incomingWords, text)
      let outgoing = has(outgoingWords, text)
      let alone = !has(transferWords, text) && !has(paymentWords, text) && !has(maskedPerson, text)
      func scan(_ re: NSRegularExpression, labelled: Bool) {
        for m in re.matches(in: text, range: NSRange(location: 0, length: source.length)) {
          let phrase = source.substring(with: m.range(at: 1))
          let number = m.range(at: 2)
          if found.contains(where: { $0.range.location == number.location }) { continue }
          let windowStart = max(0, m.range.location - 80)
          let before = source.substring(
            with: NSRange(location: windowStart, length: m.range.location - windowStart))
          let after = source.substring(from: number.location + number.length)
          let numberText = source.substring(with: number)
          let digits = digit.numberOfMatches(
            in: numberText, range: NSRange(location: 0, length: (numberText as NSString).length))
          let card = has(cardLabel, phrase)
          let from = has(fromBefore, before)
          // "from" in an incoming message is the sender's side, unless a
          // debit verb governs it.
          let sender = incoming && from && !has(debitVerbBefore, before)
          let own: Bool
          if digits > 4 {
            own = false
          } else if has(thirdPartyWord, phrase) || has(thirdPartyBefore, before) || has(nameInParensAfter, after) {
            own = false
          } else if has(possessive, phrase) || has(possessiveBefore, before) {
            own = true
          } else if has(destinationBefore, before) || has(destinationLabel, phrase) {
            // The other side of a debit is a third party (R4P-07).
            own = has(creditVerbBefore, before) && !outgoing && !has(debitVerbBefore, before)
          } else if card || purchase {
            own = !sender
          } else {
            let instrument = labelled && !incoming &&
              (has(instrumentBefore, before) || has(instrumentLabel, phrase))
            own = (labelled && alone) || (from ? !sender : instrument)
          }
          found.append((range: number, card: card, own: own))
        }
      }
      scan(labelledSuffix, labelled: true)
      scan(maskedSuffix, labelled: false)
      return found.sorted { $0.range.location < $1.range.location }
    }
    // A purchase, refund or bill: the counterparty is a merchant (MASK-1). An
    // own card alone does not make "paid to X" a purchase (X-P1).
    func isMerchantContext() -> Bool {
      readsAsPurchase(value)
    }

    // PRIV-1: cues that only ever introduce a person (payee, beneficiary,
    // sender …) apply in any message, transfer word or not.
    try maskPerson(
      #"(\#(noLetterBefore)(?:beneficiary(?:[ \t]+name)?|benef|payee(?:[ \t]+name)?|sender(?:[ \t]+name)?"# +
        #"|remitter(?:[ \t]+name)?|recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|on[ \t]+behalf[ \t]+of|in[ \t]+favou?r[ \t]+of"# +
        #"|payable[ \t]+to|(?:for[ \t]+)?employee|اسم[ \t]+المستفيد|اسم[ \t]+المرسل|المستفيد|مستفيد|للمستفيد|المرسل|المستلم|للمستلم|المحول"# +
        #"|لصالح|باسم|للسيدة|للسيد)\.?\#(notLetter)\#(labelSep))(\#(name))"#)
    // N-P1: a beneficiary notice names a person wherever the name sits: after
    // the cue and its status words, between commas, and before the role.
    try maskPerson(
      #"(\#(noLetterBefore)(?:beneficiary|beneficiaries|payee|المستفيد|مستفيد|للمستفيد)\#(notLetter)"# +
        #"(?:[ \t]+(?:new|added|successfully|has|have|been|was|الجديد|جديد|بنجاح)\#(notLetter))*"# +
        #"(?:[ \t]*[:,،\-][ \t]*|[ \t]+))(\#(name))"#)
    try maskPerson(
      #"((?:(?:^|(?<=[\n.!?؟;؛:,،]))[ \t]*|\#(noLetterBefore)(?:added|إضافة|اضافة|أضفت|اضفت)[ \t]+))(\#(looseName))"# +
        #"(?=[ \t]+(?:(?:was|has[ \t]+been|have[ \t]+been)[ \t]+(?:successfully[ \t]+)?added[ \t]+)?"# +
        #"(?:as[ \t]+(?:an?[ \t]+)?(?:new[ \t]+)?(?:beneficiary|payee)|كمستفيد|إلى[ \t]+(?:قائمة[ \t]+)?المستفيدين)\#(notLetter))"#)
    // PRIV-1r: field labels that only ever introduce a person; "Merchant
    // name: …" names a business.
    try maskPerson(
      #"(\#(noLetterBefore)(?:attn|attention|(?<!merchant[ \t]|store[ \t]|shop[ \t]|bank[ \t]|company[ \t])name|customer(?:[ \t]+name)?"# +
        #"|card[ \t]?holder(?:[ \t]+name)?|account[ \t]+holder(?:[ \t]+name)?|عناية|الاسم|اسم(?=[ \t]*:)|العميل|العميلة|حامل[ \t]+البطاقة|صاحب[ \t]+الحساب)"# +
        #"\.?\#(notLetter)\#(labelSep))(\#(looseName))"#)
    // SP-16: the holder of an account ("to account of …", «حساب باسم …»); a
    // number may sit between ("acct 7788 of …").
    try maskPerson(
      #"(\#(noLetterBefore)(?:(?:account|acct|acc|a\/c|ac|card|wallet)(?:[ \t]+(?:no\.?[ \t]*)?(?:[*xX•#]*\#(d){1,9}|\[ACCOUNT\]))?[ \t]+of|(?:حساب|الحساب|لحساب|بطاقة|محفظة)[ \t]+باسم)\#(notLetter)\#(cueSep))(\#(name))"#)
    // AR-01: «من حساب هاني عادل 7788» — the holder right after the account word.
    try maskPerson(#"(\#(noLetterBefore)(?:من|في)[ \t]+(?:حساب|الحساب)[ \t]+)(\#(name))"#)
    if !isMerchantContext() {
      if has(transferWords, value) {
        // Counterparty cues only when the text reads as a transfer/credit and
        // NOT as a purchase/refund/bill, so "Purchase from AMAZON" keeps its
        // merchant.
        try maskPerson(
          #"(\#(noLetterBefore)(?:from|to(?:[ \t]+name)?|by|beneficiary(?:[ \t]+name)?|sender(?:[ \t]+name)?|"# +
            #"remitter(?:[ \t]+name)?|recipient(?:[ \t]+name)?|payer(?:[ \t]+name)?|on[ \t]+behalf[ \t]+of|"# +
            #"in[ \t]+favou?r[ \t]+of|mrs|mr|ms|dr|من[ \t]+قبل|اسم[ \t]+المستفيد|اسم[ \t]+المرسل|المستفيد|"# +
            #"مستفيد|المرسل|المحول|لصالح|باسم|بواسطة|من|إلى|الى|الي|لـ)\.?\#(notLetter)\#(cueSep))(\#(name))"#)
      } else {
        // PRIV-1: with no purchase, refund, bill or card-payment reading, a
        // "From:" label, "paid to", a "To/From <Name>:" heading and the payee
        // of a payment name a person too (a business-form word keeps it).
        try maskPayee(
          #"(\#(noLetterBefore)(?:from[ \t]*:|من[ \t]*:|request(?:ed)?[ \t]+from\#(notLetter)|paid[ \t]+to\#(notLetter))[ \t]*)(\#(name))"#)
        try maskPayee(
          #"((?:^|(?<=[\n.!?؟;؛]))[ \t]*(?:to|from|من)[ \t]+)(\#(name))(?=[ \t]*:)"#)
        try maskPayee(
          #"(\#(noLetterBefore)(?:payment|payments|paid|pay)\#(notLetter)(?:[^.\n;؛!?؟]|\.(?=\#(d))){0,40}?\#(noLetterBefore)to[ \t]+)(\#(name))"#)
      }
      // SP-16: a name in parentheses right after an account or card number.
      try maskPerson(
        #"((?:\[(?:ACCOUNT|CARD|IBAN|PHONE)\]|[*xX•#]\#(d){1,9}|\#(noLetterBefore)(?:account|acct|acc|a\/c|ac|card|wallet|حساب|الحساب|لحساب|للحساب|بطاقة|البطاقة|محفظة)[ \t]*[:#]?[ \t]*\#(d){1,9})[ \t]*\([ \t]*)(\#(name))(?=[ \t]*\))"#)
      // Names with no cue: before a transfer verb aimed at the user, after the
      // Arabic verb, and a full name right after the transfer word.
      try maskPerson(
        #"((?:^|(?<=[\n.!?؟;؛:]))[ \t]*)(\#(looseName))(?=[ \t]+(?:has[ \t]+|have[ \t]+)?(?:sent|transferred|paid|remitted|requested)[ \t]+"# +
          #"(?:you\#(notLetter)|(?:[^.\n]|\.(?=\#(d))){0,30}?\#(noLetterBefore)(?:to|into|from)[ \t]+you))"#)
      try maskPerson(
        #"(\#(noLetterBefore)(?:(?:أرسل|ارسل|حول|حوّل|أودع|اودع)ت?[ \t]+(?:لك|إليك|اليك)|قام|قامت)[ \t]+)(\#(name))"#)
      try maskCapitalisedName(
        #"(\#(noLetterBefore)(?:transfer|transferred|remittance|حوالة|حواله|تحويل)\#(notLetter)(?:[ \t]*[:\-][ \t]*|[ \t]+))"# +
          #"(\#(looseNameToken)(?:[ \t]+\#(looseNameToken)){1,5})"# +
          #"(?=[ \t]*(?:[\-,،]|\#(d)|\z|\n|(?:\#(currency))\#(notLetter)))"#)
    }
    // The beneficiary after «إلى»/«الى»/"To:": the name's letter tokens, the
    // account or card object before it and the third party's number — never
    // a tense, status, amount, currency or date word, an amount, a date or the
    // next sentence (Vso4). The user's own «حسابك»/"your card" is not consumed.
    let beneficiaryStop = alternation(Self.nameStopwords.filter { !Self.beneficiaryObjectWords.contains($0) })
    let beneficiaryToken =
      #"(?!(?!\#(afterParticle))\#(arabicPrefix)(?:\#(beneficiaryStop))(?![\p{L}\p{M}*'’\-]|\.[\p{L}\p{M}]))"# +
      #"[\p{L}\p{M}][\p{L}\p{M}*'’\-]*(?:\.[\p{L}\p{M}][\p{L}\p{M}*'’\-]*)*"# +
      #"(?:(?<=(?<![\p{L}\p{M}])(?:\p{L}|mrs|mr|ms|dr))\.)?"#
    let beneficiaryID =
      #"(?:\[(?:ACCOUNT|IBAN|CARD|PHONE|REF)\]|[A-Z]{2}\#(d){2}(?:[ ]?[0-9A-Z]{4})*(?:[ ]?[0-9A-Z]{1,3})?|"# +
      #"[*xX•#]*\#(d)+(?:-\#(d)+)*)"# +
      #"(?![0-9A-Za-z]|[.,٫٬/:]\#(d)|\#(d)|[ \t]*(?:\#(currency))\#(notLetter)(?![ \t]*\#(d)))"#
    let beneficiaryPart = #"(?:\[NAME\]|\#(beneficiaryID)|\#(beneficiaryToken))"#
    let beneficiaryRun = #"\#(beneficiaryPart)(?:[ \t]+\#(beneficiaryPart))*"#
    // MASK-0: the run is a merchant, and stays, when the text reads as a
    // purchase or the run carries a business marker — unless it is an account
    // or card object, or carries a number or a masked name.
    let merchantContext = isMerchantContext()
    let transfer = has(transferWords, value)
    let beneficiaryCue = try regex(#"^(?:إلى|الى|to(?:[ \t]+name)?)\s*:?\s*"#, true)
    let beneficiaryAccountObject = try regex(
      #"\#(noLetterBefore)(?:account|accounts|acct|acc|ac|wallet|mobile|phone|number|no|name|حساب|الحساب|حسابات|لحساب|للحساب|محفظة|المحفظة|رقم)\#(notLetter)"# +
        #"|^(?:(?:the|a|an)[ \t]+)?(?:card|cards|بطاقة|البطاقة|بطاقه)\#(notLetter)"# +
        #"|\[(?:NAME|ACCOUNT|IBAN|CARD|PHONE|REF)\]|^[*xX•#]*\#(d)|\#(d){5}|[A-Z]{2}\#(d){2}"#, true)
    func keepsBeneficiary(_ match: String) -> Bool {
      let run = beneficiaryCue.stringByReplacingMatches(
        in: match, range: NSRange(location: 0, length: (match as NSString).length), withTemplate: "")
      return !has(beneficiaryAccountObject, run) &&
        (merchantContext || (!transfer && has(companyMarker, run)))
    }
    try replaceEach(#"(إلى|الى)\s*:?\s*\#(beneficiaryRun)"#) { m, s in
      keepsBeneficiary(s.substring(with: m.range)) ? nil : s.substring(with: m.range(at: 1)) + ": [REDACTED]"
    }
    try replaceEach(#"\#(w)To(?:[ \t]+name)?\s*:\s*\#(beneficiaryRun)"#) { m, s in
      keepsBeneficiary(s.substring(with: m.range)) ? nil : "To: [REDACTED]"
    }
    // The user's own account after the cue stays only as a partial suffix: an
    // unmasked number of 5+ digits after it becomes [ACCOUNT].
    let ownWord = #"(?:your|حسابك|حسابكم|لحسابك|بطاقتك|بطاقتكم|محفظتك)"#
    try replace(
      #"((?:إلى|الى|\#(w)to)\s*:?\s*\#(ownWord)(?:[ \t]+(?:account|card|wallet|رقم|no\.?|number))?[ \t]+)"# +
        #"[*xX•#]*\#(d){5,}(?![.,٫٬/:]?\#(d)|[ \t]*(?:\#(currency))\#(notLetter)(?![ \t]*\#(d)))"#,
      "$1[ACCOUNT]")
    // AR-01: a number right after a masked name is that person's account or
    // card number, unless it is an amount, a date or a time.
    try replace(
      #"((?:\[NAME\]|\[REDACTED\])[ \t]+(?:(?:رقم|no\.?|number|account|acct|حساب)[ \t]*[:#]?[ \t]*)?)[*xX•#]*\#(d){1,9}[*•]*"# +
        #"(?!\#(d)|[.,٫٬/:\-]\#(d)|[ \t]*(?:\#(currency))\#(notLetter))"#,
      "$1[ACCOUNT]")
    // Account and card suffixes the text does not mark as the user's own.
    let purchase = readsAsPurchase(value)
    let suffixed = NSMutableString(string: value)
    for s in scanSuffixes(value, purchase: purchase).reversed() where !s.own {
      suffixed.replaceCharacters(in: s.range, with: "[ACCOUNT]")
    }
    value = suffixed as String
    let own = Set(scanSuffixes(value, purchase: purchase).filter { $0.own }.map { $0.range.location })
    // Any other number left in the beneficiary's sentence becomes [ACCOUNT],
    // unless it is an amount, a date or time, a day before a month name, or the
    // user's own ≤4-digit suffix.
    let ownWordBounded = #"\#(ownWord)(?:[ \t]{1,10}(?:account|card|wallet|رقم|no\.?|number))?"#
    let currencyWord = #"(?:\#(currency))\#(notLetter)"#
    let months = alternation(Self.monthNames)
    try replaceEach(
      #"(?<![A-Za-z0-9٠-٩۰-۹*•#]|\#(d)[.,٫٬/:\-])"# +
        #"(?![*xX•#]*\#(d){1,4}(?!\#(d)|-\#(d))(?<=\#(ownWordBounded)[ \t]{1,10}[*xX•#]{0,10}\#(d){1,4}))"# +
        #"(?!\#(d){1,2}[ \t]+(?:\#(months))\#(notLetter))"# +
        #"(?<!\#(noLetterBefore)\#(currencyWord)[ \t]{0,10})"# +
        #"(?:[A-Z]{2}(?=\#(d)))?[*xX•#]*\#(d)+(?:-\#(d)+)*"# +
        #"(?![0-9A-Za-z٠-٩۰-۹]|[.,٫٬/:\-]\#(d)|[ \t]*\#(currencyWord)(?![ \t]*\#(d)))"# +
        #"(?<=(?:إلى|الى|\#(w)To(?:[ \t]{1,10}name)?\s{0,10}:)(?:(?!\#(sentenceEnd)).){0,4000})"#
    ) { m, _ in own.contains(m.range.location) ? nil : "[ACCOUNT]" }
    try replace(#"(عزيزي|عزيزتي)\s+\S+"#, "[REDACTED]")
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  // Word lists copied verbatim from `_shared/sms_redaction.ts` (NAME_STOPWORDS,
  // BENEFICIARY_OBJECT_WORDS, CURRENCY_AFTER, MONTH).
  private static let nameStopwords: [String] = [
    "your", "yours", "you", "our", "us", "the", "a", "an", "account", "accounts", "acct", "acc",
    "ac", "card", "cards", "wallet", "mobile", "phone", "number", "no", "on", "at", "in", "into",
    "via", "using", "with", "for", "of", "to", "from", "by", "beneficiary", "benef", "payee",
    "sender", "remitter", "recipient", "payer", "ref", "reference", "rrn", "amount", "amt", "is",
    "was", "has", "have", "been", "and", "or", "date", "time", "balance", "bal", "avl",
    "available", "avail", "customer", "customers", "client", "cardholder", "holder", "valued",
    "sir", "madam", "member", "there", "team", "atm", "branch", "bank", "app", "online",
    "internet", "instapay", "ipn", "sarie", "mada", "swift", "transfer", "transaction", "trx",
    "txn", "successful", "successfully", "added", "credit", "debit", "credited", "debited", "cash",
    "deposit", "salary", "sar", "egp", "aed", "usd", "eur", "gbp", "kwd", "qar", "bhd", "omr",
    "jod", "le", "sr", "riyal", "riyals", "pound", "pounds", "dirham", "dirhams", "dinar",
    "dinars", "dollar", "dollars", "transferred", "sent", "received", "paid", "made", "requested",
    "deposited", "withdrew", "initiated", "will", "would", "name", "حسابك", "حسابكم", "حساب",
    "الحساب", "حسابات", "لحسابك", "لحساب", "للحساب", "بطاقتك", "بطاقتكم", "بطاقة", "البطاقة",
    "بطاقه", "رصيدك", "رصيد", "الرصيد", "خلال", "قبل", "في", "على", "عن", "إلى", "الى", "الي",
    "من", "بمبلغ", "مبلغ", "المبلغ", "بقيمة", "قيمة", "بتاريخ", "تاريخ", "يوم", "اليوم", "الساعة",
    "الساعه", "ساعة", "وقت", "رقم", "عبر", "بواسطة", "محفظة", "محفظتك", "المحفظة", "ريال", "جنيه",
    "جم", "درهم", "دينار", "دولار", "يورو", "العميل", "عميلنا", "عملائنا", "عزيزي", "تطبيق",
    "الصراف", "صراف", "جهاز", "مدى", "سريع", "انستاباي", "حوالة", "حواله", "تحويل", "التحويل",
    "الحوالة", "واردة", "وارده", "صادرة", "صادره", "البنك", "بنك", "فرع", "عند", "لدى", "و", "تم",
    "المتاح", "متاح", "المرجع", "مرجع", "رسوم", "عمولة", "قام", "حول", "حوّل", "أرسل", "ارسل",
    "إرسال", "ارسال", "بتحويل", "بإرسال", "استلم", "أودع", "اودع", "سحب", "دفع", "shall",
    "tomorrow", "today", "scheduled", "executes", "executed", "execution", "pending", "declined",
    "rejected", "failed", "unsuccessful", "completed", "approved", "processed", "awaiting",
    "expected", "upcoming", "reversed", "cancelled", "canceled", "not", "please", "if", "once",
    "when", "every", "under", "due", "سينفذ", "ستنفذ", "سيتم", "ستتم", "سوف", "غدا", "غداً",
    "مجدول", "مجدولة", "سيخصم", "سيُخصم", "سيضاف", "سيودع", "جاري", "جارٍ", "قيد", "معلق", "معلقة",
    "مرفوضة", "مرفوض", "رفض", "فشلت", "فشل", "لم", "تمت", "بنجاح", "كمستفيد", "يرجى", "الرجاء", "إذا", "اذا",
    "مستحق", "مستحقة", "savings", "saving", "current", "checking", "chequing", "iban", "due to",
    "insufficient", "funds", "limit", "reason", "technical", "error", "request", "lack", "الآيبان",
    "الايبان", "آيبان", "ايبان", "التوفير", "توفير", "الادخار", "ادخار", "الجاري", "payment",
    "payments", "purchase", "refund", "bill", "pos", "attn", "attention", "cardholder", "merchant",
    "we", "it", "he", "she", "they", "this", "that", "now", "here", "then", "الاسم", "اسم",
    "عناية", "شراء", "سداد", "عملية", "العملية", "الجهة", "المفوتر", "المستفيد", "مستفيد",
    "المرسل", "المستلم", "المحول", "ناجح", "ناجحة", "داخلي", "داخلية", "دولي", "دولية", "محلي",
    "محلية", "فوري", "فورية", "سريعة", "بنكي", "بنكية", "مالية", "جديد", "جديدة", "صادر", "وارد",
    "إشعار", "اشعار", "تنبيه", "تأكيد", "تفاصيل", "لك", "إليك", "اليك", "حامل", "صاحب", "بين",
    "are", "attempted", "authorization", "being", "blocked", "bounced", "call", "can", "cannot",
    "contact", "could", "denied", "did", "didn", "exceeded", "exceeds", "expired", "going", "hold",
    "may", "might", "minimum", "pre", "preauthorisation", "preauthorization", "refused", "remind",
    "reminder", "report", "should", "stopped", "timed", "unable", "unauthorised", "unauthorized",
    "unless", "void", "voided", "withdrawal", "إبلاغ", "اتصل", "اعتراض", "المتوقع", "انتهت",
    "بانتظار", "تجاوز", "تجاوزت", "تخطي", "تذكير", "تستحق", "تعذر", "تعذرت", "تواصل", "رفضت",
    "ستتلقى", "ستحصل", "ستستلم", "سيصلك", "طلب", "عدم", "غير", "فاشلة", "قد", "لا", "لعدم", "لن",
    "لو", "متوقع", "محاولة", "ملغاة", "ملغية", "موعد", "موقوفة", "يستحق", "يمكن", "يمكنك",
    "انتظار", "التأكيد", "الموافقة", "المعالجة", "التنفيذ", "الانتظار", "approval", "attempt",
    "authorised", "authorized", "confirmation", "didn't", "didn’t", "couldn't", "couldn’t",
    "wasn't", "wasn’t", "can't", "can’t", "won't", "won’t", "hasn't", "hasn’t", "isn't", "isn’t",
    "doesn't", "doesn’t", "dispensed", "out", "pre-auth", "pre-authorisation", "pre-authorization",
    "process", "processing", "review", "reviewed", "run", "أن", "إتمام", "إلغاء", "إيقاف",
    "استرداد", "الإلغاء", "الاسترداد", "الحد", "الخصم", "الدفع", "الرفض", "السحب", "السداد", "بنا",
    "تتم", "تعليق", "تكتمل", "تنجح", "تنفذ", "تنفيذ", "حال", "حجز", "حد", "خصم", "صرف", "صلاحية",
    "كاف", "كافي", "كفاية", "محجوز", "مصرح", "معالجة", "معنا", "مقبول", "مقبولة", "يتم", "ينجح",
    "to", "by", "were", "be", "does", "do", "done", "must", "went", "go", "goes", "gone",
    "through", "got", "get", "gets", "confirm", "confirmed", "verify", "verified", "complete",
    "proceed", "activate", "avoid", "view", "check", "receive", "pay", "use", "visit", "click",
    "reply", "send", "make", "see", "authorise", "authorize", "approve", "cancel", "stop", "try",
    "tried", "arrive", "arrived", "reach", "reached", "remain", "remains", "returned", "refunded",
    "posted", "booked", "placed", "issued", "released", "held", "settle", "settled", "yesterday",
    "tonight", "morning", "evening", "afternoon", "noon", "midnight", "earlier", "later", "ago",
    "recently", "currently", "already", "just", "still", "again", "soon", "immediately",
    "instantly", "last", "next", "week", "month", "year", "monday", "tuesday", "wednesday",
    "thursday", "friday", "saturday", "sunday", "أمس", "امس", "البارحة", "الآن", "الان", "صباحا",
    "صباحاً", "مساء", "مساءً", "ظهرا", "ظهراً", "ليلا", "ليلاً", "الماضي", "الماضية", "القادم",
    "القادمة", "المقبل", "المقبلة", "هذا", "هذه", "الشهر", "الأسبوع", "الاسبوع", "السنة", "العام",
    "لاحقا", "لاحقاً", "سابقا", "سابقاً", "حاليا", "حالياً", "مؤخرا", "مؤخراً", "الأحد", "الاحد",
    "الاثنين", "الإثنين", "الثلاثاء", "الأربعاء", "الاربعاء", "الخميس", "الجمعة", "السبت"
  ]
  // LOOSE_STOPWORDS, verbatim: not a name only where there is no cue at all or
  // after a field label.
  private static let looseStopwords: [String] = [
    "service", "care", "support", "money", "sum", "total", "fee", "fees", "charge", "charges",
    "loan", "installment", "instalment", "invoice", "tax", "vat", "cashback", "order", "standing",
    "incoming", "outgoing", "local", "international", "domestic", "instant", "internal",
    "external", "own", "between", "alert", "notification", "notice", "details", "update", "status",
    "advice", "id", "خدمة"
  ]
  private static let beneficiaryObjectWords: Set<String> = [
    "you", "us", "the", "a", "an", "account", "accounts", "acct", "acc", "ac",
    "card", "cards", "wallet", "mobile", "phone", "number", "no", "name", "حساب", "الحساب",
    "حسابات", "لحساب", "للحساب", "بطاقة", "البطاقة", "بطاقه", "محفظة", "المحفظة", "رقم"
  ]
  // COMPANY_MARKERS, SUFFIX_LABELS, THIRD_PARTY_WORDS, verbatim.
  private static let companyMarkers: [String] = [
    "shop", "shops", "store", "stores", "bookstore", "market", "markets", "supermarket",
    "hypermarket", "mart", "mall", "cafe", "café", "coffee", "restaurant", "restaurants",
    "kitchen", "bakery", "pharmacy", "pharmacies", "clinic", "clinics", "hospital", "company",
    "co", "corp", "corporation", "ltd", "llc", "inc", "est", "establishment", "trading", "group",
    "holding", "services", "solutions", "hotel", "hotels", "station", "petrol", "fuel", "telecom",
    "electricity", "water", "insurance", "takaful", "school", "university", "academy", "airlines", "airways",
    "pay", "com", "net", "شركة", "شركه", "مؤسسة", "مؤسسه", "مكتبة", "مكتبه", "متجر", "متاجر",
    "محل", "محلات", "مطعم", "مطاعم", "مقهى", "كافيه", "كوفي", "صيدلية", "صيدليات", "مستشفى",
    "عيادة", "عيادات", "فندق", "سوبرماركت", "هايبر", "هايبرماركت", "أسواق", "اسواق", "سوق", "مركز",
    "محطة", "مخبز", "مخابز", "بقالة", "تموينات", "للتجارة", "التجارية", "للخدمات", "مدرسة",
    "جامعة", "الكهرباء", "المياه", "الاتصالات", "للاتصالات", "للتأمين"
  ]
  private static let suffixLabels: [String] = [
    "account", "acct", "acc", "a\\/c", "ac", "card", "wallet", "mada", "visa", "mastercard",
    "apple[ \\t]+pay", "حساب", "الحساب", "لحساب", "للحساب", "بحساب", "بالحساب", "حسابك", "لحسابك",
    "بحسابك", "حسابكم", "لحسابكم", "حسابي", "بطاقة", "البطاقة", "ببطاقة", "بالبطاقة", "لبطاقة",
    "للبطاقة", "بطاقه", "بطاقتك", "ببطاقتك", "لبطاقتك", "بطاقتكم", "بطاقتي", "محفظة", "المحفظة",
    "محفظتك", "لمحفظتك", "مدى"
  ]
  private static let thirdPartyWords: [String] = [
    "beneficiary", "benef", "payee", "sender", "recipient", "receiver", "remitter", "payer",
    "المستفيد", "مستفيد", "المرسل", "المستلم", "المحول"
  ]
  private static let currencyAfter: [String] = [
    "sar", "egp", "aed", "usd", "eur", "gbp", "kwd", "qar", "bhd", "omr",
    "jod", "le", "sr", "riyals?", "pounds?", "dirhams?", "dinars?", "dollars?", "ريال", "جنيه",
    "جم", "درهم", "دينار", "دولار", "يورو", "ر\\.س"
  ]
  private static let monthNames: [String] = [
    "يناير", "فبراير", "مارس", "أبريل", "ابريل", "مايو", "يونيو", "يوليو", "أغسطس", "اغسطس",
    "سبتمبر", "أكتوبر", "اكتوبر", "نوفمبر", "ديسمبر", "jan(?:uary)?", "feb(?:ruary)?", "mar(?:ch)?", "apr(?:il)?", "may",
    "june?", "july?", "aug(?:ust)?", "sep(?:t|tember)?", "oct(?:ober)?", "nov(?:ember)?", "dec(?:ember)?"
  ]
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
