# Unresolved capture retention — proposal (FOR REVIEW, NOT IMPLEMENTED)

Principle requested by the owner (2026-11-12): an unresolved bank message stays recoverable unless the user
deliberately deletes it. No arbitrary age-based deletion is introduced. This document lists what the code does
today and proposes behaviour for review. Nothing here has been changed in code.

## 1. Where an unresolved capture can live, and what deletes it today

| Store | What it holds | Deleted today by | Unattended age-based deletion? |
|---|---|---|---|
| iOS App Group queue (`SharedCaptureStore.swift`), items **stamped** to an owner | encrypted raw message | import + ack after a durable commit; Remove data / account deletion sweep; sign-out purge | **No** ("stamped items never expire by age", `SharedCaptureStore.swift:109`) |
| iOS queue, **unbound** items (captured with no active owner) | encrypted raw message | claim then import; Remove-data sweep of hinted items; **age expiry after 30 days** (`unboundExpiryDays = 30`, `loadQueuePruned`, `SharedCaptureStore.swift:988-1007`) with a content-free counter only | **Yes — conflicts with the principle** |
| iOS quarantined overflow segments | ciphertext that failed to decrypt | Remove data (`finishRemoval`), sign-out purge | No |
| Android queue (`DurableCaptureQueue.kt`) main + overflow, stamped / waiting / unbound | raw message (encryption at rest added in phase 4) | import + ack; Remove-data sweep of that owner's and hinted items; full purge | No |
| Android quarantine (`items_quarantine_*`, `.quarantine` files) | unreadable blob | Remove-data sweep (unattributable, so swept) | No |
| Smart Inbox rows (Drift, encrypted DB) — "awaiting analysis", "processing failed", "not a transaction", unsupported message | full message text for review | user resolves/hides; account replica deletion | No |
| Suspected-duplicate review rows | full message text | user dismisses / keeps both; replica deletion | No |
| Retry ledger (`capture_retry_ledger.dart`) | attempt counts only, no content | entries older than 30 days or beyond 1000 entries are forgotten (`:123-183`) | Counts only. Effect: a long-stuck item starts a fresh retry budget; **no capture is lost** |
| Server `processed_captures` (iOS route) | sanitized text + result | content inaccessible 168 h after creation, row deleted 30 days later (`0112_capture_notifications_retention.sql`) | Yes, server side — but the device keeps its native copy until import, and an expired/absent server result falls back to on-device processing (`capture_import_service.dart:516-521`, `capture_sync_service.dart:376-377`), so the message is not lost |
| Server `ai_request_idempotency` (Android `parse-sms`) | request hash + AI result, no SMS text | ~1 h TTL + daily prune | Not a capture store |

Conclusion: the only path that deletes an unresolved message without a user action is the **iOS unbound 30-day
expiry**.

## 2. Proposed behaviour (for review)

1. **Remove the iOS unbound age expiry**, or make it opt-in: unbound items stay until claimed, explicitly discarded
   by the user, or swept by Remove data / account deletion of the hinted account. Replace the silent counter with a
   visible state: diagnostics + the existing claim prompt showing "N messages captured while no account was
   signed in are waiting — Import / Delete". Trade-off: raw messages (encrypted) can stay on the device indefinitely
   if nobody signs in; data minimization argued for the expiry. Owner to decide.
2. **Never delete quarantined/unreadable data automatically.** Keep the current rule (only Remove data / account
   deletion / sign-out purge remove it) and surface a count with a "Delete unreadable captured data" action in
   diagnostics/privacy settings, so the user can deliberately clear it.
3. **Smart Inbox / review rows**: keep until the user resolves them (current behaviour). Optionally add a manual
   "Delete all unresolved messages" action in privacy settings that deletes Smart Inbox capture rows, suspected
   duplicates and the native queue for the current account in one barrier-protected operation.
4. **Retry ledger**: keep pruning counts (no content) but never let pruning or a reset cause deletion; the item's
   review row / native copy remains authoritative (current behaviour).
5. **Server**: no change to the 168 h content / 30 d row rules; document that the device copy is the recovery
   source and that backups (PITR) are a separate retention domain.
6. **Account deletion / Remove data** remain the deliberate-deletion paths and must keep sweeping every store above
   (both platforms) and report failure if anything remains.

## 3. Decisions needed

- Remove (or keep) the iOS 30-day unbound expiry. Recommended: remove it and show the waiting count with Import /
  Delete.
- Whether to add the "Delete all unresolved messages" action.
- Wording for the prompt and the privacy policy retention section (see the disclosure proposal).
