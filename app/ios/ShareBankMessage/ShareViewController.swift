import Social
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: SLComposeServiceViewController {
  override func isContentValid() -> Bool {
    true
  }

  override func didSelectPost() {
    extractSharedText { outcome in
      DispatchQueue.main.async {
        switch outcome {
        case .offerLink:
          // A merchant link went to its own store; nothing to capture.
          self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        case .text(let text):
          // Signed out: nothing is captured. Unlike the automation, a share is
          // the user's own action, so it is refused visibly (approved copy:
          // "open Qirsh, then try again"), never reported as saved.
          if SharedCaptureStore.isSignedOutForCertain() {
            NSLog("[QirshShare] share not persisted: signed_out")
            self.fail(.storageUnavailable)
            return
          }
          if case let .failed(reason, kind) = SharedCaptureStore.enqueue(text: text, sender: nil, source: "share") {
            // CAP-0: the queue refused the write (e.g. before first unlock). Cancel
            // with an error rather than reporting a successful share that was lost.
            // R9: the user sees only the approved copy; the reason is logged.
            NSLog("[QirshShare] share not persisted: %@", reason)
            self.fail(kind)
            return
          }
          self.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        case .none(let types):
          // No readable text arrived (seen with a Messages bubble share). Never
          // report success for a share that saved nothing. Only the type
          // identifiers are logged, never content.
          NSLog("[QirshShare] share not persisted: no_text types=%@", types)
          self.fail(.emptyText)
        }
      }
    }
  }

  /// Shows the approved copy, then cancels the request with it.
  private func fail(_ kind: SharedCaptureStore.FailureKind) {
    let error = NSError(
      domain: "ShareBankMessage",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: kind.userMessage]
    )
    let alert = UIAlertController(title: nil, message: kind.userMessage, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
      self.extensionContext?.cancelRequest(withError: error)
    })
    present(alert, animated: true)
  }

  override func configurationItems() -> [Any]! {
    []
  }

  private enum SharedOutcome {
    case text(String)
    case offerLink
    /// Nothing usable; carries the offered type identifiers for the log.
    case none(String)
  }

  private func extractSharedText(completion: @escaping (SharedOutcome) -> Void) {
    let typed = (contentText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
    let attachments = items.flatMap { $0.attachments ?? [] }
    let offered = attachments.flatMap { $0.registeredTypeIdentifiers }.joined(separator: ",")
    // Text the host put on the item itself (not an attachment).
    let itemText = items
      .compactMap { $0.attributedContentText?.string }
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .first { !$0.isEmpty }
    let fallback: SharedOutcome = !typed.isEmpty
      ? .text(typed)
      : (itemText.map { .text($0) } ?? .none(offered))

    // COUPONS Phase 5 — route by ITEM TYPE, URLs first.
    //
    // A shared merchant link must never reach the capture queue: the SMS parser
    // would read a product page as a transaction, and the URL would be
    // persisted in the store built for bank messages. URL items therefore go to
    // a SEPARATE App Group store and this method reports nothing to capture.
    //
    // URLs are checked BEFORE text because Safari offers a page as both — it
    // attaches the title as plain text alongside the public.url item — and
    // taking the text branch would put the page title into the parser.
    //
    // A FILE url is not a merchant link: some hosts hand shared text over as a
    // file. It is excluded here and read as text below.
    let urlType = UTType.url.identifier
    let fileURLType = UTType.fileURL.identifier
    for provider in attachments
    where provider.hasItemConformingToTypeIdentifier(urlType)
      && !provider.hasItemConformingToTypeIdentifier(fileURLType) {
      provider.loadItem(forTypeIdentifier: urlType, options: nil) { item, _ in
        if let url = item as? URL, !url.isFileURL {
          // Sanitized inside the store: scheme, host and path only. A shared
          // shopping URL routinely carries a session id, a cart id and the
          // sharer's own referral code, none of which is needed to know which
          // merchant this is.
          SharedOfferIntentStore.enqueue(url: url)
          // Nothing goes to the capture path for a URL share.
          completion(.offerLink)
        } else {
          completion(fallback)
        }
      }
      return
    }

    // Any text flavour, most specific first. `public.text` is what activates
    // the extension, so an attachment may conform to it without being
    // `public.plain-text` (rich text, a text file).
    let textTypes = [UTType.plainText.identifier, UTType.utf8PlainText.identifier,
                     UTType.text.identifier, fileURLType]
    for type in textTypes {
      for provider in attachments where provider.hasItemConformingToTypeIdentifier(type) {
        provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
          let text = Self.string(from: item)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
          if let text, !text.isEmpty {
            completion(.text(text))
          } else {
            completion(fallback)
          }
        }
        return
      }
    }

    completion(fallback)
  }

  /// The text a provider handed over, in whichever form the host chose.
  private static func string(from item: NSSecureCoding?) -> String? {
    switch item {
    case let text as String:
      return text
    case let attributed as NSAttributedString:
      return attributed.string
    case let data as Data:
      if let plain = String(data: data, encoding: .utf8) { return plain }
      return (try? NSAttributedString(
        data: data, options: [:], documentAttributes: nil))?.string
    case let url as URL where url.isFileURL:
      if let plain = try? String(contentsOf: url, encoding: .utf8) { return plain }
      return (try? NSAttributedString(
        url: url, options: [:], documentAttributes: nil))?.string
    default:
      return nil
    }
  }
}
