# iOS audit — Qirsh V1
Model: claude-opus-5-5 (Claude Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: iOS specialist (AI agent)

## 1. Scope covered / not covered

Covered, by reading source at `ab5dc10a` (no build, no simulator, no device):
- `app/ios/Runner/{AppDelegate,SceneDelegate,SharedCaptureStore,SessionKeychain,SharedOfferIntentStore}.swift`, `app/ios/ShareBankMessage/*` (the extension's `SharedCaptureStore.swift` and `SharedOfferIntentStore.swift` are byte-identical to Runner's: `diff` returned no output), `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift` (compiled into the Runner target, `project.pbxproj:30,541`).
- Both targets' entitlements, Info.plist and PrivacyInfo.xcprivacy (`plutil -p`), `project.pbxproj` build settings, xcconfigs, Podfile/Podfile.lock, ExportOptions.plist.
- Dart side where it touches native: `lib/features/capture/services/capture_sync_service.dart` (pendingSend replay), `lib/core/startup/bootstrap_runner.dart` (owner release hooks), `lib/core/session/app_session.dart` (expiry, reinstall), `lib/core/security/app_lock_gate.dart`, `lib/core/observability/diagnostics.dart`, `lib/features/ads/*` (init gating only).
- `codemagic.yaml` `ios-signed` workflow (lines 712–960), `tools/verify_ios_release_artifact.sh`, `tools/stamp_ios_provenance.sh` (skimmed), `app/tools/verify_ios_packaging.sh` (grep).
- Server push copy only where it determines lock-screen content (`supabase/functions/process-ios-sms/index.ts:353-360`, `_shared/capture_push.ts:16-25`).

Not covered: the Dart `CloudEgressGate` / consent state machine internals (privacy/backend specialists), the server consent fences, Android, admin. No targeted `flutter test` could be run: `flutter test test/ios/ios_privacy_manifest_test.dart …` failed before running (`Creation failed, path = '/Volumes/shared' (OS Error: Permission denied, errno = 13) / Failed to update packages`, sandbox write restriction during pub resolution). No XCTest run (needs a build).

## 2. What is established (verified behavior, with evidence — code inspection only)

**Capture queue (App Group + shared Keychain).**
- Queue = AES-GCM sealed JSON `[Payload]` in `pending_bank_messages_v3.bin` plus encrypted overflow segments `pending_bank_messages_v3_overflow/seg-*.bin` (`SharedCaptureStore.swift:23-60,1137-1300`). Key `capture_queue_key_v1` in Keychain service `com.youssefsafwat.mali.sharedcapture`, access group `<prefix>com.youssefsafwat.mali.shared`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (`:4917-4960`). Update-then-add, never delete-then-add (`:4949`).
- A key is minted only on `errSecItemNotFound` AND no sealed file exists; otherwise writes are refused (`:4850-4873`). Unreadable/undecryptable main file throws, never "empty" (`:1105-1110,4892-4908`). A segment that fails to decrypt with a readable key is quarantined, not deleted (`:1200-1260`).
- No count/byte quota since 2026-11-12; only a per-item ceiling of 2 MB (`:103-108,1115-1119`). Unbound items expire after 30 days, counted (`:994-1014`); stamped items never expire.
- Durable write: temp file, F_FULLFSYNC, rename, directory fsync, protection `completeUntilFirstUserAuthentication` (`:1320-1370`). So after first unlock, a locked device can enqueue; before first unlock the Keychain read fails → `.deviceLocked` copy and a visible Shortcuts error (`:520-530`, `BankMessageShortcuts.swift:59-63,675-681`).
- One cross-process `flock` on `pending_bank_messages.lock` around every read/write (`:1483-1505`) with a `performExpiringActivity` guard against 0xdead10cc suspension kills (`:1470-1481`, best effort, 200 ms wait).
- Per-item lease: `peekPendingPayloadsJSON` never deletes; Dart acks per payload (`:588-619`, `AppDelegate.swift:421-432`).

**App Intent ("Process Bank SMS").** `BankMessageShortcuts.swift:63-241`: setup probe → if `isSignedOutForCertain()` return silently (no store, no upload, no banner) → persist BEFORE any network (`status: .pendingSend`) → `authorizeUpload` under flock → `.allowed` uploads via `gatedUpload`; `.localOnly` marks `.sent` and posts a local banner; `.waiting` stays queued silently. Backend success keeps the local copy as `.sent` until Flutter imports and acks (`:167-179`). `openAppWhenRun = false`; iOS 26 `supportedModes [.background, .foreground(.dynamic)]`.

**Native egress is single-path and consent-gated.** The only native network transport is `SharedCaptureStore.gatedUpload` (`:4216-4260`): ephemeral session, no cookies/cache/credential store, redirects refused, no background session, 8 s timeout. Immediately before the request it runs `admitUpload` under the flock (`:1990-2012`), which re-reads barrier, stamped `{uid, generation}` vs active owner, egress state in both layers (Keychain + file; unreadable ⇒ deny, `:2159-2191`), the capture-time `localOnly` stamp, and the owner's consent mirror (missing ⇒ `.waiting`, cloud off ⇒ `.localOnly`, `:1958-1982`), then durably registers an in-flight entry. A consent withdrawal (`withdrawCloudEgress`, `:4355-4413`) flips config + mirror OFF, writes DISABLING in both layers, and cancels in-process sessions via an epoch registry that `gatedUpload` re-checks after admission (`:4237-4254,4268-4311`). The idempotent timeout retry re-enters `gatedUpload` and is re-admitted (`BankMessageShortcuts.swift:249-274`). A capture taken while the mirror is off is stamped `localOnly` forever (`SharedCaptureStore.swift:500-509`). SMS text is sanitized natively before upload and throws `sanitizerUnavailable` instead of sending raw text (`BankMessageShortcuts.swift:779-783,814,918+`). The Dart replay path also requires native `authorizeCaptureUpload == allowed` (`capture_sync_service.dart:407-437`). The share extension makes no network call. APNs registration is gated by `egressAdmitsHostRequest` (`AppDelegate.swift:472-482`). I found no native egress path that skips the consent re-check.
- Residual (by design, documented at `SharedCaptureStore.swift:4209-4211`): a request already on the wire in *another process* at withdrawal cannot be recalled; the in-flight registry lets the app wait out its deadline (≤10 s).

**Protected-state writers are host-only.** `CAPTURE_STATE_WRITER` is set for Runner Debug/Release/Profile (`project.pbxproj:664,865,894`) and not for the share extension (`:923`, none at `:949`), so the extension binary cannot write owner, consent mirror, egress state or barrier.

**Ownership.** Owner record `{uid, uidHash(HMAC), generation}` in shared Keychain (`:1634-1649,1742-1789`). Sign-out / account transition clears the owner (`clearActiveOwner`, `:1826-1833`; Dart `bootstrap_runner.dart:1427-1452`) and the previous owner's delivered notifications. Session expiry does NOT clear the owner (`app_session.dart:4576-4596`), so captures keep binding to the same user ("preserve local data on auth loss"). Signed-out App Intent drops silently; signed-out share is refused visibly (`ShareViewController.swift:21-25`).

**Share extension.** URL items go to a separate offer store and never to the capture queue (`ShareViewController.swift:98-117`); text from attachment, item text or composer; empty → error alert, never success (`:35-41`); refused enqueue → alert + `cancelRequest(withError:)` (`:26-33,47-58`).

**Background.** BGTaskScheduler refresh+processing (`Info.plist` `BGTaskSchedulerPermittedIdentifiers`, `UIBackgroundModes [fetch, processing]`); handler starts a headless Flutter engine only when protected data is available (`AppDelegate.swift:1576-1650`); force-quit/BAR-off fall back to foreground drain (documented `:1491-1494`).

**APNs.** `aps-environment = $(APS_ENVIRONMENT)`: Release `production`, Debug/Profile `development` (`project.pbxproj:646,847,877`). Token environment is derived from the embedded profile or store receipt; unresolved ⇒ token withheld (`AppDelegate.swift:26-112,1187-1214`). CI asserts `aps-environment == production` on profile and signed binary (`codemagic.yaml:836-838,924-926`).

**Release config.** Bundle IDs `com.youssefsafwat.mali` / `.ShareBankMessage`; Release/Profile xcconfigs pin empty QA suffixes and never include `QA.xcconfig` (`Flutter/Release.xcconfig`, `Flutter/ShareExtRelease.xcconfig`). `RunnerQA.entitlements` empty, unreachable in Release. Deployment target iOS 16.0 (all targets), Podfile 15.0. `ITSAppUsesNonExemptEncryption = false`. Build number from App Store Connect latest + 1 with floor 146 (`codemagic.yaml:757-789`). DEBUG hooks in `SharedCaptureStore` are `let … = nil` in non-DEBUG (`:167-195`); debug BG probe compiled out (`AppDelegate.swift:186-195,1686-1700`, `SceneDelegate.swift:32-40`).

**Logging.** All native `NSLog`/`os_log` lines are constant strings or enum reasons; none carries SMS text, uid, amount or token (`grep -nE "NSLog|os_log|print\(|debugPrint"` over all three targets; the only `print`/`debugPrint` are inside `#if DEBUG`). Dart routes `debugPrint` through a redacting, 240-char-bounded sink (`lib/core/observability/diagnostics.dart:40-46`); no bare `print(` in `lib/`. The "release diagnostic" from `ea7de7a9` is `os_log("[QirshShortcut] route decision=%{public}@", <constant reason>)` (`BankMessageShortcuts.swift:123-126,227-228`) — content-free. The diagnostics journal (`app_diagnostics.dart`) is a closed enum vocabulary, local only. No "temporary persistence trace" code was found at this commit (`grep -rniE "persistence ?trace|TEMPORARY|REMOVE BEFORE"` over `app/lib`, `app/ios`).

**Store items.** Account deletion route `/delete-account` reachable from Privacy screen (`app_router.dart:224`, `privacy_screen.dart:173`); Apple token revocation implemented server-side (`supabase/functions/_shared/apple_deletion_gateway.ts`). Sign in with Apple entitlement present. Google sign-in via AppAuth with reversed-client-id URL scheme validated at runtime (`AppDelegate.swift:1286-1342`). No associated domains / universal links. No `NSUserTrackingUsageDescription`, `NSPrivacyTracking = false`, consistent with D-6.

## 3. Findings

### IOS-01 — Required-reason API declarations are missing or wrong in both privacy manifests (DiskSpace undeclared)
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: iOS
- User impact: none at runtime; App Store Connect can reject or warn on upload (ITMS-91053 "Missing API declaration"), blocking or risking V1 submission.
- Evidence:
  - `SharedCaptureStore.swift:4771-4777` reads `volumeAvailableCapacityForImportantUsageKey` (DiskSpace category), reachable from `queueStats()` (`:4763`), compiled into Runner AND the share extension (identical file, not under any `#if`). Neither `Runner/PrivacyInfo.xcprivacy` nor `ShareBankMessage/PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategoryDiskSpace` (`plutil -p` output in §2 scope).
  - `SharedCaptureStore.swift:4152` reads `.modificationDate` (FileTimestamp); declared in Runner (C617.1) but NOT in the extension manifest, which compiles the same code.
  - Both targets read the App Group `UserDefaults(suiteName: "group.com.youssefsafwat.mali")` (`:117-119`, `SharedOfferIntentStore`, `SceneDelegate.swift:63`) but declare only reason `CA92.1` (app-only); App Group access needs `1C8F.1`.
  - Introduced by `934a0777` (2026-11-12), an ancestor of `b6fc0dad`, so TestFlight 1.0.0 (147) already contains it (`git merge-base --is-ancestor 934a0777 b6fc0dad` → true).
  - `test/ios/ios_privacy_manifest_test.dart` checks only Info.plist usage keys, not manifest reasons; `verify_ios_packaging.sh:69,105` checks presence only.
- Root cause: manifest not updated when the diagnostic disk-space probe was added; App Group defaults reason never added.
- Proposed fix: add `NSPrivacyAccessedAPICategoryDiskSpace` (reason `E174.1` — check free space before writing) to both manifests; add `NSPrivacyAccessedAPICategoryFileTimestamp` `C617.1` to the extension; add `1C8F.1` alongside `CA92.1` in both. Alternatively drop the diagnostic disk probe. No runtime compatibility impact.
- Verification required after fix: check the App Store Connect processing email for build 147 (did it carry ITMS-91053?); after fix, upload a build and confirm no ITMS-91053; generate Xcode's Privacy Report from the archive.

### IOS-02 — The `ios-signed` workflow cannot produce an App Store–submittable V1 build
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: iOS
- User impact: release pipeline blocks public release; a build from it cannot go to external TestFlight or App Review.
- Evidence: `codemagic.yaml:738` hard-requires `CM_BRANCH = release/ios-beta1-personal-20261013` (the candidate is on `release-readiness/v1`); `:841` exports with `{"testFlightInternalTestingOnly": true}`, and the comment at `:955-958` confirms such builds cannot be submitted for external review; `:723` `xcode: latest` is unpinned (toolchain drift between the audited and the shipped build).
- Root cause: workflow was scoped to the internal personal beta.
- Proposed fix: a V1 release workflow (or parameters) with the release branch/SHA, `testFlightInternalTestingOnly` false, and a pinned Xcode version; keep all existing assertions. No app compatibility impact.
- Verification required after fix: dry run on the release SHA; confirm in App Store Connect that the build is eligible for external testing and submission.

### IOS-03 — App-switcher privacy overlay is dead code under the UIScene lifecycle
- Severity: S3 · Class: CODE-SUPPORTED (needs simulator/device confirmation) · Platforms: iOS
- User impact: the multitasking snapshot can show balances, transactions and merchants, even with App Lock (Face ID) enabled. `docs/MANUAL_IPHONE_QA_CHECKLIST.md` §7.1 expects a blank "قرش" snapshot; remediation item #23 claims it was done.
- Evidence: the overlay is installed only from `AppDelegate.applicationDidEnterBackground` (`AppDelegate.swift:306-309`) and needs `AppDelegate.window` (`:1360`). The app uses scenes (`Info.plist` `UIApplicationSceneManifest`, `SceneDelegate.swift`); UIKit does not call app-delegate background callbacks for scene-based apps, and the window belongs to the scene. `SceneDelegate.sceneDidEnterBackground` (`:73-77`) only writes a defaults flag. Dart `AppLockGate` locks only after 30 s background (`app_lock_gate.dart:22,44-58`) and draws no cover. Scenes have existed since `dc5cca80`; the overlay was added in `976f5f92`.
- Root cause: overlay wired to non-scene callbacks.
- Proposed fix: install and remove the overlay from `SceneDelegate.sceneWillResignActive`/`sceneDidBecomeActive` on the scene's window (or `sceneDidEnterBackground`/`sceneWillEnterForeground`). Small, no compatibility impact.
- Verification required after fix: simulator or device: open dashboard, go to the app switcher, and confirm the thumbnail is blank.

### IOS-04 — Legacy local capture banner is Arabic-only regardless of the user's language
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: iOS
- User impact: English users get Arabic transaction banners ("تم رصد عملية شراء 🛒", "المبلغ: …") when `capture_notify_v2` is off.
- Evidence: `BankMessageShortcuts.swift:490-511` hard-codes Arabic; the v2 path (`:381-420`) and the generic fallback (`:536-580`) are localized. Reached at `:137,221,234` whenever `config.captureNotifyV2 == false`; the flag defaults `false` (`lib/data/catalog/feature_flag_service.dart:113`). The production flag value was not checked.
- Proposed fix: reuse `detailedCaptureNotification` (localized) in the legacy branch, or confirm `capture_notify_v2` is ON in production and accept as a limitation.
- Verification required after fix: device with app language English, flag off, run the Shortcut on a high-confidence sample. Expected: an English banner.

### IOS-05 — Amount, merchant and card last-4 show on the lock screen by default
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: iOS (server push too)
- User impact: financial details visible on a locked phone unless the user turns on "hide lock-screen content".
- Evidence: `hideLockScreenContent = false` default (`lib/domain/entities/engagement_entities.dart:83`), mirrored natively (`SharedCaptureStore.swift:723-730`); local banners include amount/merchant/category/last4 (`BankMessageShortcuts.swift:381-420,490-511`); upload sends `notificationDetails: !hide` (`:829`) and the server then builds a detailed push alert (`process-ios-sms/index.ts:359-360`), so detail also transits APNs. No policy document in `docs/legal`, `docs/privacy` or `docs/project` sets a lock-screen rule (`grep -rniE "lock.?screen"`).
- Proposed fix: owner decides; the privacy-preserving default is `hide = true`, or an explicit decision record plus privacy-policy wording about APNs carrying transaction detail.
- Verification required after fix: device lock-screen check (manual step 8).

### IOS-06 — Signed-out Shortcut captures are dropped silently and permanently
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: iOS
- User impact: after sign-out (not expiry), an automation that keeps firing loses every bank message, with no banner and no Shortcuts error. The user may believe capture is running.
- Evidence: `BankMessageShortcuts.swift:68-73` (owner decision 2026-11-13 cited in `SharedCaptureStore.swift:1627-1632`). Contrast: share is refused visibly (`ShareViewController.swift:18-25`), but with the "couldn't access its secure storage" copy (`SharedCaptureStore.swift:305-308`), which misdescribes the cause.
- Proposed fix: owner to confirm; at least a one-time "Sign in to Qirsh to keep recording bank messages" notification, and accurate share copy (new copy needs approval).
- Verification required after fix: manual step 6.

### IOS-07 — Shared text that also carries a URL item may be routed to Offers and reported as success
- Severity: S3 · Class: SUSPECTED · Platforms: iOS
- User impact: a bank SMS containing a link, shared from Messages, could be stored as an "offer link". The share sheet completes normally and no capture is saved.
- Evidence: the URL branch is checked first and returns `.offerLink` → `completeRequest` (`ShareViewController.swift:98-117,14-16`). Whether Messages attaches a `public.url` provider for a text bubble with a link is host-dependent and not verifiable here. `SharedOfferIntentStore.enqueue` also has no result, so even the offer may be silently dropped (`SharedOfferIntentStore.swift:86-104`); that is low impact by design (`:107-109`).
- Proposed fix: prefer text when a text provider exists and the URL is only part of the text, or only treat URL-only shares as offers.
- Verification required: manual step 4.

### IOS-08 — iPad (and iPhone landscape) are declared supported
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: iOS
- Evidence: `TARGETED_DEVICE_FAMILY = "1,2"` for all targets (`project.pbxproj:637,783,838,926,953,980`); `UISupportedInterfaceOrientations` includes both landscapes on iPhone and all four on iPad, with no `UIRequiresFullScreen`.
- Impact: App Review tests on iPad, iPad screenshots become mandatory, and Split View must work. The SMS Shortcut automation is iPhone-only in practice.
- Proposed fix: owner confirms iPad is in V1 scope; if not, set family `1` (and consider portrait-only on iPhone). Changing device family after release is restricted, so decide before first public release.

### IOS-09 — Export-compliance answer `ITSAppUsesNonExemptEncryption=false` needs owner/legal confirmation
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: iOS
- Evidence: `Runner/Info.plist` `ITSAppUsesNonExemptEncryption => false`; the app ships its own encryption beyond the OS: SQLCipher/`sqlite3mc` (per `app/CLAUDE.md`) and CryptoKit AES-GCM queue encryption (`SharedCaptureStore.swift:4878-4908`).
- Proposed fix: confirm against Apple's export-compliance questions (and the French declaration, if the app is distributed in France) and record the decision.

### IOS-10 — App privacy disclosures must cover the shipped AdMob/UMP SDKs
- Severity: S3 · Class: PRODUCT-DECISION / ENV-LIMITATION · Platforms: iOS
- Evidence: Google-Mobile-Ads-SDK 13.3.0 and UMP 3.1.0 are linked (`Podfile.lock:55-72`); `GADApplicationIdentifier`, `SKAdNetworkItems` in Info.plist; ads are activatable remotely without a new build (DECISIONS D-18/D-19). The app's own manifest declares no advertising-related collection (§2). D-6 (non-personalized, no ATT) is consistent with `NSPrivacyTracking=false`. However, App Store Connect privacy labels are entered manually, and the SDK's bundled manifest was not inspected here (Pods not vendored).
- Proposed fix: make sure the ASC privacy labels include what the GMA SDK collects (device ID, advertising data, diagnostics) for the "Third-party advertising" purpose, even with ads off by default; generate the Xcode privacy report from the archive.

### IOS-11 — Stamped captures for a non-active owner never expire
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: iOS
- Evidence: pruning only removes `unbound` items (`SharedCaptureStore.swift:998-1003`). After an account switch, or a reinstall where the Keychain owner survives and a different user signs in, the old owner's items stay encrypted in the App Group until that user returns or Remove-data runs. Every enqueue/peek decrypts all segments (`loadQueue`, `:969-992`), so a very large backlog raises memory in the share extension.
- Proposed fix: record as a known limitation, or add an age cap for non-active-owner items with a user-visible count.

### IOS-12 — Hygiene
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: iOS
- `AppDelegate.swift:11-16` says `DEBUG` is not defined in any configuration; Runner Debug defines `DEBUG CAPTURE_STATE_WRITER` (`project.pbxproj:865`). The comment is stale and misleading for future `#if DEBUG` reasoning.
- `ShareViewController.swift:153-156` reads a whole shared file into memory (`String(contentsOf:)`, `NSAttributedString(url:)`) on a background provider queue before the 2 MB item limit applies. A large or HTML file could exceed extension memory, and HTML import off the main thread can fail.
- `codemagic.yaml:723` `xcode: latest` (also part of IOS-02).

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Shortcut capture | iOS | Capture persisted before any network; visible error when not persisted | BankMessageShortcuts.perform, SharedCaptureStore.enqueue | Code inspection | PASS | BankMessageShortcuts.swift:100-112,675-681 | — |
| Shortcut capture | iOS | Locked after first unlock: enqueue works | Keychain AfterFirstUnlock, file protection CUFUA | Code inspection | PASS (not device-tested) | SharedCaptureStore.swift:4958,1328,1342 | — |
| Shortcut capture | iOS | Before first unlock: refused with deviceLocked copy | enqueue error mapping | Code inspection | PASS (not device-tested) | SharedCaptureStore.swift:520-525 | — |
| Shortcut capture | iOS | Signed out | perform early return | Code inspection | PASS as designed | BankMessageShortcuts.swift:68-73 | IOS-06 |
| Queue | iOS | Corrupt/unreadable queue not treated as empty; key never re-minted over sealed data | decodeQueueBlob, encryptionKey, quarantine | Code inspection | PASS | :4850-4908,1200-1260 | — |
| Queue | iOS | Overflow beyond segment | saveQueue segments | Code inspection | PASS | :1546-1604 | IOS-11 |
| Queue | iOS | Cross-process lock + suspension | withQueueLock, beginSuspensionGuard | Code inspection | PASS (best effort) | :1470-1505 | — |
| Queue | iOS | Kill between drain and import | peek + per-item ack | Code inspection | PASS | :588-619; AppDelegate.swift:421-432 | — |
| Share ext | iOS | Empty / refused share never reported as saved | ShareViewController | Code inspection | PASS | ShareViewController.swift:21-41 | — |
| Share ext | iOS | Bank SMS containing link | URL-first routing | Code inspection | NOT TESTED | ShareViewController.swift:98-117 | IOS-07 |
| Ownership | iOS | Sign-out / switch clears owner and notifications | clearActiveOwner, release hook | Code inspection | PASS | SharedCaptureStore.swift:1826-1833; bootstrap_runner.dart:1427-1452 | — |
| Ownership | iOS | Session expiry keeps owner | markSessionInvalid | Code inspection | PASS | app_session.dart:4576-4596 | — |
| Ownership | iOS | Reinstall (Keychain survives) | repairActiveOwnerGeneration, resetInstallPresentation | Code inspection | NOT TESTED | SharedCaptureStore.swift:1792-1819; app_session.dart:526-540 | IOS-11 |
| Consent | iOS | Every native upload re-checks consent under lock immediately before the wire | gatedUpload/admitUpload | Code inspection | PASS | :1958-2012,4216-4260 | — |
| Consent | iOS | Withdrawal while queued/retrying/in flight | withdrawCloudEgress, epoch registry, localOnly stamp | Code inspection | PASS (cross-process in-flight not recallable, by design) | :4355-4413,4268-4311,500-509 | — |
| Consent | iOS | Dart replay gated by native authorize | retryPendingSend | Code inspection | PASS | capture_sync_service.dart:407-437 | — |
| Consent | iOS | Share extension has no egress and cannot write protected state | no CAPTURE_STATE_WRITER in extension | Code inspection | PASS | project.pbxproj:923,949 | — |
| Push | iOS | aps-environment production in Release; env from signed profile | entitlements, ApnsEnvironment | Code + CI script inspection | PASS | pbxproj:877; AppDelegate.swift:26-112; codemagic.yaml:836,924 | — |
| Push | iOS | Lock-screen content | banners, server pushAlert | Code inspection | FAIL vs privacy-safe default (decision needed) | see IOS-05 | IOS-05 |
| Notifications | iOS | Banner language | legacy local banner | Code inspection | FAIL | BankMessageShortcuts.swift:490-511 | IOS-04 |
| Notifications | iOS | Permission denied: capture still stored | scheduleNotification failure logged only | Code inspection | PASS | BankMessageShortcuts.swift:330-353 | — |
| Privacy manifest | iOS | Required-reason APIs declared | PrivacyInfo.xcprivacy x2 | plutil + grep | FAIL | IOS-01 | IOS-01 |
| Tracking | iOS | No ATT / NSPrivacyTracking false consistent with D-6 | Info.plist, manifest | plutil | PASS | §2 | IOS-10 |
| Usage strings | iOS | Only Camera, Photos, Face ID; all justified | Info.plist | plutil | PASS | §2 | — |
| App-switcher privacy | iOS | Snapshot hidden | installPrivacySnapshotView | Code inspection | FAIL (suspected; confirm on sim) | AppDelegate.swift:306-309,1359-1379 | IOS-03 |
| Account deletion | iOS | In-app deletion reachable; Apple revoke | /delete-account, apple_deletion_gateway | Code inspection | PASS (flow not executed) | app_router.dart:224; privacy_screen.dart:173 | — |
| Release config | iOS | QA identifiers cannot reach Release | xcconfigs, CI SHA/branch check | Code inspection | PASS | Release.xcconfig; codemagic.yaml:734-750 | — |
| Release pipeline | iOS | Build is App Store submittable | ios-signed export options | Code inspection | FAIL | codemagic.yaml:738,841 | IOS-02 |
| Diagnostics | iOS | Release logs content-free | NSLog/os_log, Diag sink | grep + inspection | PASS | §2 Logging | — |
| Background drain | iOS | BG task with no engine, protected data unavailable | CaptureBackgroundDrain | Code inspection | PASS (not device-tested) | AppDelegate.swift:1576-1684 | — |

## 5. Could not verify here (exact scenarios, what is needed)
- All runtime behavior. A physical iPhone with a distribution (TestFlight) build is needed for: Shortcuts automation on a received SMS; locked / before-first-unlock behavior; BGTask headless drain; real APNs delivery; Keychain survival across reinstall; Messages share-sheet attachment types; memory/time limits of the extension and App Intent. The simulator cannot run Messages SMS automations, BGTasks, or production APNs.
- The App Store Connect upload result/email for build 147 (ITMS-91053), production value of `capture_notify_v2`, App Store Connect privacy labels and export-compliance answers: need ASC access.
- XCTest (`RunnerTests`) and the targeted Flutter tests: need a build and a writable pub cache (failed with `/Volumes/shared` permission error).
- The GMA SDK's own privacy manifest contents: need `pod install` output.

## 6. Manual device test steps you recommend (numbered, with expected outcome)

Use a TestFlight build of the release candidate on a physical iPhone (iOS 16+ and iOS 26), a test account, and synthetic bank-style SMS sent from a second phone. Never use real bank messages in evidence.

1. **Cold, terminated capture.** Sign in, set up the "Process Bank SMS" automation (Message from sender X → run immediately). Force-quit Qirsh. Send a synthetic purchase SMS. Expected: banner appears (generic or localized detail); opening Qirsh shows exactly one transaction; repeat send of the identical text does not create a duplicate.
2. **Locked after first unlock.** Lock the phone (Face ID set), wait 1 min, send an SMS. Expected: capture saved (it appears after unlocking and opening); no Shortcuts error.
3. **Before first unlock.** Reboot, do NOT unlock, send an SMS. Expected: Shortcut fails visibly (or does not run); after unlocking, no phantom success. Note whether the message is lost (document as known limitation if so).
4. **Share sheet, text with link.** In Messages, long-press a synthetic bank SMS that contains `https://example.com/x` → Share → "إضافة رسالة بنك". Expected: the capture appears in Qirsh, not under Offers (IOS-07). Repeat with a plain-text SMS and with a shared Safari URL (expected: offer only, no capture).
5. **Share while signed out.** Sign out, share an SMS. Expected: alert, not success; nothing appears after next sign-in.
6. **Automation while signed out.** Signed out, send an SMS. Expected per owner decision: nothing stored and no banner. Confirm the owner accepts this (IOS-06).
7. **Consent revocation mid-flight.** Cloud + Smart Analysis ON, enable airplane mode, send an SMS (the queued capture stays `pendingSend`). In Qirsh turn Cloud OFF, then disable airplane mode and reopen. Expected: no `process-ios-sms` request for that capture (check server `processed_captures` for its payload id: absent); the transaction is parsed locally.
8. **Lock-screen content.** Default settings, phone locked, send an SMS. Record what the banner shows. Then enable "hide lock-screen content" and repeat. Expected: second banner generic ("New transaction captured"), with no amount or merchant in either the local or the APNs alert (IOS-05).
9. **English UI.** Set the app language to English, with the `capture_notify_v2` flag in its production state; send a high-confidence SMS. Expected: English banner (IOS-04).
10. **Account switch.** Capture under account A while signed out of nothing; sign out, sign in as B. Expected: A's notifications cleared; A's queued items not imported into B; signing back into A imports them.
11. **Reinstall.** With pending captures, delete the app, reinstall, and run the automation BEFORE opening the app; then open and sign in as the same user, then repeat with a different user. Expected: same user recovers captures; different user sees none of A's data.
12. **App switcher.** Open the dashboard and swipe to the app switcher. Expected: branded blank snapshot (IOS-03 predicts the real screen is shown).
13. **Background drain.** Leave captures queued, background the app (not force-quit) overnight on Wi-Fi + power. Expected: captures imported without opening (Console `[CaptureBg] task_completed success=true`).
14. **Push permission denied.** Deny notifications at first prompt; send an SMS. Expected: capture still saved; no crash; Settings shows the denied state honestly.
15. **Account deletion.** Delete the account from Privacy → Delete account (Apple-sign-in account). Expected: completes in-app; Apple ID "Sign in with Apple" list no longer shows Qirsh.
