# Closure round 3 — iOS specialist (`ios`)

- Model: `claude-opus-5-5` (Claude Opus 5.5). Source: the model identifier stated in this agent's own system context; no other evidence is available to the agent.
- Date: 2026-11-17/18. Tree: `release-readiness/v1`, uncommitted on top of `d1212986` (other specialists' uncommitted edits are in the same tree).
- Nothing committed, staged, pushed, deployed or changed in any console. Production not touched. No certificates or profiles created.

## Summary

| # | Work item | Status |
|---|---|---|
| 1 | iPhone only (3.1, V1-014) | DONE in code, contract-tested; App Store / compatibility-mode behaviour NOT TESTED |
| 2 | No advertising in the V1 build (3.2, V1-005, V1-063) | DONE in code (Dart compile-time gate + CI), tested; production flags unchanged (not authorised) |
| 3 | Notifications (3.12, V1-035, V1-036, V1-061) | PARTIAL — native banners and Dart review copy done; server push copy and an "excluded" disposition belong to other owners |
| 4 | Signed-out capture (3.13, V1-037) | DONE in code, XCTest; on-device Shortcuts error presentation NOT TESTED |
| 5 | Privacy manifests / required-reason APIs (V1-003, V1-008, B16) | DONE in code; App Store Connect answers and the archive Privacy Report NEED OWNER |
| 6 | App-switcher cover on resign-active (B24) | DONE in code; device check needed |
| 7 | Verify | see "Verification" |
| — | Orchestrator note (ops findings 1–5) | 1, 2, 3 DONE; 4 reported only (owner attestation); 5 decision stated |

## 1. iPhone only (decision 3.1, V1-014)

Changes:
- `app/ios/Runner.xcodeproj/project.pbxproj`: all six `TARGETED_DEVICE_FAMILY = "1,2"` → `1` (project Debug/Release/Profile, ShareBankMessage ×3).
- `app/ios/Runner/Info.plist`: `UISupportedInterfaceOrientations` = portrait only; `UISupportedInterfaceOrientations~ipad` removed. `LSRequiresIPhoneOS` stays.

Compatibility behaviour (Apple, App Review Help "Test compatible devices", https://developer.apple.com/help/app-review/before-submitting-for-review/test-compatible-devices, read 2026-11-17, no page date): an iPhone-only app can still be installed on iPad and runs there in compatibility mode unless it depends on iPhone-only capabilities; removing iPad support in Xcode does not by itself stop iPad downloads. iPhone apps can also be offered on Apple-silicon Macs and Apple Vision Pro. Apple asks developers to test behaviour in those modes before submission. So: the V1 build ships iPhone UI only; iPad users see the iPhone layout scaled; Mac/Vision availability is a separate App Store Connect setting (owner action).

Tests: `app/test/ios/ios_privacy_manifest_test.dart` group "iPhone-only target configuration" (device family = 1 in all six configs; portrait only; no `~ipad` key). Fails on HEAD files, passes now.

## 2. No advertising in V1 at build level (3.2)

Decision: **the Google Mobile Ads plugin stays linked; ads are compiled out of the Dart side of the iOS build.**

Why keep the SDK (also answers ops finding 5, "consider removing the SDK"):
- `pubspec.yaml` is shared with Android, which keeps ads (`android-release` now passes `--dart-define=QIRSH_ADS_ENABLED=true`). Flutter has no per-platform dependency switch; removing the package removes it from Android too, and `lib/features/ads/**`, `report_ads/**`, the app shell and settings import it.
- Removing only the iOS pod would break `GeneratedPluginRegistrant` (it registers the plugin unconditionally). Doing it properly means a federated/stub package — too large and risky for this round.
- With the gate, no code path can start the SDK (tested below), and `GADDelayInitialization` is true, so it does not self-start.
- Cost of keeping it: binary size, and the SDKs' own privacy manifests appear in Xcode's Privacy Report. If the owner wants the binary free of Google SDKs, that is a follow-up change (stub package for iOS) — not done.

Mechanism (`app/lib/features/ads/admob_build_config.dart`): `adsCompiledIn = bool.fromEnvironment('QIRSH_ADS_ENABLED') || (!kReleaseMode && debugAdsCompiledInOverride)`. Used by `isConfiguredFor` / `isBannerConfiguredFor`, the first line of `MobileAdsInitializer.mayServe()` (covers initialise, UMP gather, privacy-options form, banner load, interstitial gateway), and `AdConsentService.canRequestAds()` (returns false before touching UMP). The test override is ignored in release mode. No call-site edits in other owners' files were needed: `app_shell.dart` consent orchestration and the settings privacy-options tile go through `mayServe` / `isPrivacyOptionsRequired`.

CI (`codemagic.yaml`):
- `ios-signed-release`: `admob` group removed.
- `ios-signed-release` and `ios-signed`: "Materialise AdMob release config (native)" replaced by "Keep AdMob out of the iOS build (V1 has no ads)" (`rm -f ios/Flutter/AdMob.xcconfig`); `--dart-define=ADMOB_*_IOS` removed. No `QIRSH_ADS_ENABLED` on any iOS workflow.
- `android-release`: `--dart-define=QIRSH_ADS_ENABLED=true` added (keeps Android as it was).

What remains in the iOS binary: GMA SDK 13.3.0 and UMP 3.1.0 frameworks with their own `PrivacyInfo.xcprivacy` (GMA declares required-reason APIs SystemBootTime 35F9.1, UserDefaults CA92.1, DiskSpace E174.1, and collected types incl. Advertising Data, Coarse Location, Product Interaction, Performance/Crash/Other Diagnostic Data, purposes incl. Third-Party Advertising, tracking false); `GADApplicationIdentifier = $(ADMOB_APP_ID)` which is **empty in Release** (no AdMob.xcconfig) and Google's test ID in Debug/Profile; `GADDelayInitialization = true`; one `SKAdNetworkItems` entry. The Dart ad code is present but unreachable.

Privacy answers: answer by actual collection; the app's own manifest declares no advertising data. Apple defines "collect" as transmitted off device (App privacy details, https://developer.apple.com/app-store/app-privacy-details/, read 2026-11-17) and says nothing about a linked SDK that never starts — **UNCONFIRMED** that a linked-but-never-started SDK transmits nothing; needs the network-capture device check (MDT item 8). Build 147 shipped with an empty app ID and did not crash at launch (evidence the uninitialised SDK is inert at launch, not proof of no traffic). If the capture is not done, declare Google's listed types.

Tests:
- New `app/test/features/ads/v1_ads_compiled_out_test.dart` (6 tests): with all 8 production flags overridden ON (`enable_banner_ads`, `enable_banner_{dashboard,transactions_list,reports,goals,subscriptions,achievements}`, `enable_report_ads`), egress permitted and an eligible user: zero calls on the GMA and UMP method channels, zero entitlement lookups, the report still generates with no ad notice, every placement ineligible. Control: with the override on, `MobileAds#initialize` and `ConsentInformation#canRequestAds` are reached. Before-proof: run with `--dart-define=QIRSH_ADS_ENABLED=true` (pre-change behaviour) → 4 fail; now 6 pass.
- `app/test/architecture/android_ci_compile_gate_test.dart`: new test (iOS workflows carry no ads defines and remove AdMob.xcconfig; android-release has `QIRSH_ADS_ENABLED=true`).
- `supabase/tests/codemagic_ios_store_pipeline_contract_test.mjs`: new test "3.2: neither signed iOS workflow configures AdMob".

Production flags: the 8 `enable_*` ad flags are still ON in production. Prepared, **not executed**: set them OFF (owner approval). With this build they are inert on iOS, but Android and build 147 still read them.

## 3. Notifications (3.12)

Native (`app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`):
- New `captureBanner(detail:fromServerAnalysis:status:receivedAt:arabic:)` used by every native capture banner. Shows: title "Bank message: {amount} {currency}" / "رسالة بنك: …"; a "Type:" line only from the server's analysis; merchant/source capped at 40 characters; a card/account hint only when it is exactly 4 ASCII digits ("ending 1234"); time; and a status line — queued: "Not recorded yet: Qirsh checks it before adding it." / "لم تُسجَّل بعد: يتحقق منها قِرش قبل إضافتها."; needs review: "Needs your review in Qirsh before it is recorded." / "تحتاج مراجعتك في قِرش قبل تسجيلها."
- **Never shows a category** (removed `categoryLabel`), never the raw SMS, never an OTP or full number (only bounded fields are copied).
- V1-035: the legacy capture-notify-v2-off branch was Arabic-only; it now uses the same bilingual builder (English for English users via `capture_notification_language`).
- V1-061: Swift `PreviewParser` is unchanged but no longer drives any outcome claim — a local high-confidence result only fills amount/currency/merchant; the status line is always "not recorded yet". So it can no longer disagree with the Dart outcome.
- System preview setting: respected by default. No category uses `hiddenPreviewsShowTitle` or a custom placeholder, so with "Show Previews: When Unlocked/Never" iOS hides title and body (Apple UNNotificationCategory docs, read 2026-11-17).

Dart (`app/lib/features/capture/services/capture_notification_content.dart`): the category on an entry awaiting review is labelled "Suggested category" / "التصنيف المقترح". Test "category of an entry awaiting review is labelled a suggestion" in `capture_notification_content_test.dart`: fails on HEAD file, passes now.

Not done (other owners — see "Changes needed elsewhere"): server APNs copy; a distinct "excluded" (declined/pending) disposition.

## 4. Signed-out capture (3.13)

- `SharedCaptureStore.swift` (Runner and ShareBankMessage, byte-identical, `cmp` checked): `FailureKind.signedOut` with message EN "This bank message wasn't saved because you're signed out. Open Qirsh and sign in to record new bank messages. This message wasn't kept." / AR "لم تُحفظ رسالة البنك لأنك غير مسجّل الدخول. افتح قِرش وسجّل الدخول لتسجيل رسائل البنك الجديدة. لم نحتفظ بهذه الرسالة."
- Shortcut intent: when signed out it posts a local banner with that text and throws `captureFailed(.signedOut)` **before** hashing or storing anything — no success report, nothing retained, so nothing can attach to the next account.
- Share extension: signed out now fails with `.signedOut` (was `.storageUnavailable`).
- XCTest: `testIntentRefusesVisiblyAndStoresNothingWhileSignedOut` (renamed from `…StaysSilentWhileSignedOut`; decided change) and `testSignedOutCopyIsActionableInBothLanguages`.

## 5. Privacy manifests and required-reason APIs

Apple pages read 2026-11-17: `NSPrivacyAccessedAPIType` reference (C617.1, CA92.1, 1C8F.1, 85F4.1, E174.1 confirmed current) and `NSPrivacyCollectedDataType` key list (https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype).

- B16: `deviceCapacityState()` (the only disk-space API use) is compiled only under `#if DEBUG`; release returns `.ok`. DiskSpace (85F4.1) removed from both the Runner and ShareBankMessage manifests.
- Runner collected types added (linked, not tracking, App Functionality): Emails or Text Messages (sanitized SMS, cloud consent), Photos or Videos (profile photo backup), User ID, Product Interaction, **Other Data Types (date of birth, synced via `user_settings`, migration 0063)**.
- Ops finding 3 applied: Product Interaction purpose changed from Analytics to **App Functionality** — the code uses notification logs for delivery retries (`process-notification-retries`) and engagement events for streaks/coupons; no admin or analysis use found. Every Qirsh-declared purpose is now App Functionality.
- No AdvertisingData, no Third-Party Advertising purpose, `NSPrivacyTracking` false.
- ShareBankMessage still declares Other Financial Info (left as is).
- Tests (`app/test/ios/ios_privacy_manifest_test.dart`, now 15): Swift sources scanned with `#if DEBUG` branches stripped; DiskSpace not expected; probe exists only in DEBUG; the 11 types present; purposes = {App Functionality}; no ad data. Before-proofs: the earlier set of 6 new tests failed against HEAD files; the purpose/date-of-birth tests failed (2) with Analytics restored and Other Data Types removed, pass now.

## 6. App-switcher cover (B24)

`app/ios/Runner/SceneDelegate.swift`: `sceneWillResignActive` installs the privacy cover (removed in `sceneDidBecomeActive` / `sceneWillEnterForeground`). Test in `ios_privacy_snapshot_scene_test.dart`. Side effect to check on device: the cover also appears under Control Center, Face ID, Sign in with Apple and permission prompts (MDT item 5).

## Orchestrator note (ops findings)

1. **Sign-in methods in the store build (3.11)**: `ios-signed-release` now sets `QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED`, `QIRSH_ALTERNATE_SIGNUP_ENABLED` to `"true"` like `ios-signed`, and the "Assert production Supabase config" step of **both** signed iOS workflows fails the build unless Google and email-code sign-in are `true` (kept identical, as the contract requires). Test "3.11: both signed iOS workflows keep Apple, Google and email-code sign-in" executes the assert step with full, unset and `false` values. Before-proof: fails with my change removed; passes now.
2. **`codemagic_ios_store_pipeline_contract_test.mjs`**: was 3/13 failing; now 15/15. The `ADMOB` step-name constant was updated to "Keep AdMob out of the iOS build (V1 has no ads)" (decided behaviour 3.2 — the three failures were order/identity/step-list checks on the old step name; none weakened). Two tests added (3.2 and 3.11).
3. **Privacy manifest**: applied (section 5).
4. **Export compliance**: not changed (`ITSAppUsesNonExemptEncryption` stays `false` in `app/ios/Runner/Info.plist`). If the owner attests `true`: App Store Connect will ask the export-compliance questions for each uploaded build (status "Missing Compliance" until answered, blocking TestFlight distribution) unless an `ITSEncryptionExportComplianceCode` is added after Apple issues one; the answers place Qirsh in "standard algorithms" (SQLCipher, Dart `cryptography`), which may need the annual self-classification report and a French declaration if distributed in France. No code, entitlement or test depends on the value.
5. **Remove GMA from the V1 binary**: decided **keep** for V1 (section 2, reasons).

## Verification

Native XCTest (iPhone 17 Pro simulator, iOS 26.5, Xcode 27.2): **197 passed, 0 failed** (`** TEST EXECUTE SUCCEEDED **`; 194 before + 3 new). Command, from `app/ios`: `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -only-testing:RunnerTests -destination "platform=iOS Simulator,id=<sim>" -derivedDataPath <scratch>/dd`. The first attempt failed in the build phase because another process's `flutter test` run had left `ios/Flutter/Generated.xcconfig` with `FLUTTER_TARGET` pointing at a deleted temporary `listener.dart`; fixed with `flutter build ios --config-only --simulator --debug`. A second attempt built but stalled before launch, with the machine at a load average of about 600 and the simulator shut down; after booting the simulator, `xcodebuild test-without-building` on the same build products ran all 197. Swift sources were not changed after that build.

Release-like build (2026-11-18, 21 GB free before): `flutter build ios --release --no-codesign` with `SUPABASE_URL=http://127.0.0.1:54321`, a placeholder anon key, `SUPABASE_ENV=production`, Google/email/alternate sign-up `true`, `APP_VERSION=1.0.0`, no ads defines → **succeeded** (`Runner.app`, 69.5 MB, Xcode build 308 s). Inspected bundle:
- `UIDeviceFamily` = [1] (app and share extension); orientations = portrait only; `ITSAppUsesNonExemptEncryption` = false.
- `GADApplicationIdentifier` empty.
- Runner `PrivacyInfo.xcprivacy`: required-reason APIs FileTimestamp C617.1, UserDefaults CA92.1/1C8F.1 (no DiskSpace); 11 collected types, all App Functionality.
- `volumeAvailableCapacityForImportantUsage` absent from the release `Runner` binary (B16 probe compiled out).
- GMA SDK 13.3.0 (`afma-sdk-i-v13.3.0`) statically linked into `Runner`; `GoogleMobileAdsResources.bundle/PrivacyInfo.xcprivacy` and `UserMessagingPlatformResources.bundle` ship in the app (these feed Xcode's Privacy Report).
- Launch was not attempted (no local backend run; the release bootstrap would also need a real production config).
Build output (`app/build/ios`, scratch DerivedData) removed afterwards; `Generated.xcconfig` reset to `lib/main.dart` debug config.

Dart tests run (all `flutter test --no-pub -j 2`, chosen files only):
- Ads/report_ads/guards/astra/screen render set: 419 passed, 1 skipped.
- `v1_ads_compiled_out_test`: 6 passed.
- `test/ios/*`: privacy manifest 15 passed; snapshot scene passed.
- Architecture pins (build50, capture_notify_v2, capture_queue_cap6) + v1_ads: 59 passed.
- `android_ci_compile_gate_test` + `ci_release_gate_authority_test`: 60 passed (after the 3.11 change).
- `capture_notification_content_test`: passed.
- `sync_diagnostics_report_test` (26) and `apns_open_telemetry_test` (7) failed only under a parallel run (timeout / shared state), pass alone; not related to these changes.
- `node --test supabase/tests/codemagic_ios_store_pipeline_contract_test.mjs`: 15 passed.
- `flutter analyze` on all touched Dart files: no issues. `plutil -lint` on the manifest: OK.

Signing (no secrets printed, nothing created): 1 valid code-signing identity, type "Apple Development". 3 development provisioning profiles for team 5TWARK8A23 (expire Sep 2027, 1 registered device): `com.youssefsafwat.mali`, `com.youssefsafwat.mali.ShareBankMessage` (both with app group `group.com.youssefsafwat.mali`), and a wildcard. No distribution identity or profile. The Release configuration uses `APS_ENVIRONMENT=production`, so a development profile cannot sign Release; an installable device build must use the Profile configuration (aps development).

Exact commands for the orchestrator (from `app/`, after `df -h /` ≥ 12 GB):

```
# Release-like compile check (no signing):
rm -f ios/Flutter/AdMob.xcconfig
PUB_CACHE=$HOME/.pub-cache flutter build ios --release --no-codesign \
  --dart-define=SUPABASE_URL=<backend url> --dart-define=SUPABASE_ANON_KEY=<anon key> \
  --dart-define=SUPABASE_ENV=production \
  --dart-define=QIRSH_GOOGLE_AUTH_ENABLED=true --dart-define=QIRSH_EMAIL_AUTH_ENABLED=true \
  --dart-define=QIRSH_ALTERNATE_SIGNUP_ENABLED=true --dart-define=APP_VERSION=1.0.0

# Installable on the one registered iPhone (development signing, Profile config):
rm -f ios/Flutter/AdMob.xcconfig
PUB_CACHE=$HOME/.pub-cache flutter build ios --profile <same dart-defines>
PUB_CACHE=$HOME/.pub-cache flutter install --profile -d <device id>
```
Do not pass `QIRSH_ADS_ENABLED` or any `ADMOB_*` define for iOS. A store/TestFlight build needs a distribution certificate and App Store profiles (Codemagic `ios-signed-release`).

## Changed tests and why (decided behaviour changes)

- `RunnerTests.swift`: `testIntentCapturesNothingAndStaysSilentWhileSignedOut` → `testIntentRefusesVisiblyAndStoresNothingWhileSignedOut` (3.13: visible refusal instead of silence). Source pin updated to `detailedCaptureNotification(aiDetail: aiDetail, status: status)`. Three tests added (197 total).
- Ten existing ad test files (`test/features/ads/{astra_h2_sdk_gating,banner_build_config,entitlement_consent_gate,report_cooldown_reactivity,report_export_banner_suppression,screen_banner_placement}_test.dart`, `test/features/report_ads/{report_ads_build_config,report_entitlement,ump_runtime_wiring,ump_transition}_test.dart`): file-level `setUp` sets `debugAdsCompiledInOverride = true` so they keep testing the ad logic as Android uses it (3.2); assertions unchanged.
- `android_ci_compile_gate_test.dart`: "admob attached to exactly the two signed workflows" → only `android-release` (3.2); ios-signed-release groups now `supabase` only.
- `build50_ownerless_fallback_pin_test.dart`, `capture_notify_v2_contract_test.dart`: pins updated to the bilingual builder (V1-035/061).
- `capture_queue_cap6_contract_test.dart`: `'return arabic'` count 3 → 4 (new signed-out message, 3.13).
- `ios_privacy_manifest_test.dart`: DiskSpace no longer expected (B16).
- `codemagic_ios_store_pipeline_contract_test.mjs`: AdMob step name (3.2).

## Not verified

- Everything in the manual list below; GMA/UMP network silence; the iPad/Mac/Vision compatibility behaviour; the archive's Privacy Report; App Store Connect answers.
- `ios/BankMessageShortcuts/verify_notification_strings.sh` already failed at HEAD (stale strings; not in CI). Not changed.
- V1-038 (URL-first share routing) not changed; needs a device check.

## Compatibility

- Stored data: no schema, key or file-format change. A new App Group defaults key is not introduced (`capture_notification_language` already existed). Pending captures queued by build 147 are processed as before.
- Build 147 against the new backend: unaffected by these changes (all client-side/CI).
- New build against the old backend: works; the server push copy is unchanged (still the old wording — see below), and the `needs_review` type it already sends is used for the review status line.
- `tools/ios_input_sha.sh` input hash changes (expected, iOS sources changed).

## Changes needed elsewhere

- **backend**: `supabase/functions/process-ios-sms/index.ts` and `_shared/capture_push.ts` APNs copy must use the same saved / queued / needs-review wording and must not present a category as final.
- **parser / data**: declined/pending messages ("excluded") currently map to unprocessable/ignored, whose notification says "Message not recognised… add manually" — wrong for a recognised but excluded message. A distinct disposition is needed; then `ios`/Dart copy can be added.
- **owner/privacy**: whether shared category learning is also Product Personalization.
- **orchestrator**: an earlier run's `flutter test` integration target left `ios/Flutter/Generated.xcconfig` pointing at a temporary `listener.dart`, which breaks Xcode builds; regenerate with `flutter build ios --config-only` before any native build.

## Owner actions

1. Approve turning the 8 production ad flags OFF.
2. App Store Connect privacy answers: the 11 Runner types above, App Functionality, not tracking; ad types only if the network check (MDT 8) is not done.
3. Inspect the archive's Xcode Privacy Report; watch for ITMS-91053 emails after upload.
4. Decide Mac / Vision Pro availability in App Store Connect.
5. Export compliance attestation (`ITSAppUsesNonExemptEncryption`).
6. Run the manual device checks.

## Manual device checks (for MANUAL-DEVICE-TESTS.md)

1. Signed out, run the "post bank status" Shortcut: Shortcuts shows the sign-in error, a Qirsh banner says it was not saved; sign in to another account — nothing is imported.
2. Signed out, share a bank message to Qirsh: the alert says to open Qirsh and sign in; nothing appears after signing in.
3. Signed in, English UI: capture banner title, merchant, card ending, time and "Not recorded yet" line are in English; repeat in Arabic.
4. Message that the server marks needs-review: banner says "Needs your review…", no category shown.
5. Settings › Notifications › Show Previews = When Unlocked, then Never: locked banner shows no amount or merchant.
6. App-switcher cover: swipe to the app switcher, pull Control Center, trigger Face ID, Sign in with Apple and a permission prompt — the cover appears and is removed on return; no stuck cover.
7. Rotate the phone on every main screen: stays portrait.
8. With all production ad flags ON, proxy the release-like build (e.g. on a test network): no requests to Google ad or UMP endpoints from launch through report export; no consent form, banner or interstitial.
9. Install on an iPad (compatibility mode): app launches, sign-in and capture work, layout usable.
10. Share a message that contains a URL (V1-038): routed as a bank message, not a link.
11. Legacy path (capture_notify_v2 off): English banner for English users.
12. Low-storage device: release build shows no disk-space warning (probe is debug only) and capture still works.

---

## Follow-up (2026-11-18): native redaction parity (PRIV-0) and LEN-1

### What the native path sends, and where

- **Endpoint:** `POST {backendURL}/functions/v1/process-ios-sms`, built in `BackendCaptureClient.process` (`app/ios/BankMessageShortcuts/BankMessageShortcuts.swift`). It goes only through `SharedCaptureStore.gatedUpload`: ephemeral session, redirects refused, admitted under the queue lock. Callers are the Shortcut App Intent (`ProcessBankSMSIntent`). The Share extension does not upload; it only queues on the device.
- **Message text:** `smsText` and `sanitizedText`, both set to `BackendCaptureClient.sanitize(request.smsText)`.
- **Sender fields, sent unredacted:** `sender` / `senderName` / `senderId`. These are the bank's sender ID; the server keeps or masks them with `redactSenderForAi`.
- **Other fields:** `payloadId`, `installId`, `deviceSecret`, `receivedAt`, `tzOffsetMinutes`, `locale`, `source`, `localNotification`, `notificationDetails`, `allowAi`, `owner_uid`, `owner_generation`, optional `schema_version`/`analysis_mode`/`backgroundAnalysis`, and now `textLength`.
- **Queue:** the trimmed, **unredacted** text is kept in the App Group queue on the device (`SharedCaptureStore.Payload.text`) for the Flutter import and replay. That replay is Dart (`CaptureBackendClient.processIosSms`), owned by `ai`.

### (1) Swift sanitizer brought to parity

`BackendCaptureClient.sanitize` is now a rule-for-rule port of the server's `redactPii` + `redactThirdPartyNames` (`supabase/functions/_shared/sms_redaction.ts`), followed by `trim`. The fixtures use the server's output as the expected result. The word lists (stopwords, beneficiary object words, currencies, months) are copied verbatim from the TS file. Rules added that Swift lacked:
- spaced IBAN;
- labelled 5–9 digit account numbers;
- the beneficiary rule that stops at the name and includes the third party's number;
- the own-destination number;
- numbers in the beneficiary's sentence;
- standing-order transfer context;
- "To Name:" / «مستفيد» cues;
- the initial rule;
- the new tense, status, account-type and failure-reason stopwords;
- SM-07 sentence ends.

Translation notes are in the code comment:
- JS's ASCII `\b` is written explicitly, because ICU's `\b` is Unicode-aware.
- ICU needs a bounded look-behind. Each bound errs toward masking more, except the beneficiary-sentence span, which is bounded at 4,000 characters (twice the server's limit).

Results (standalone `swiftc` harness on macOS, same Foundation regex engine as iOS; then XCTest on the simulator):
| Set | Old Swift | New Swift |
|---|---|---|
| `sms_redaction_cases.json` (54) | 19 differ from server | **0 differ** |
| `sms_leak_labelled_cases.json` (72) | 62 differ; **33 leak a tagged secret** (e.g. "Standing order to Sara Ali …") | **0 differ, 0 leaks**, all mustKeep kept, idempotent |
| Every text in `tools/parser_diff/cases/*.json`, `process-ios-sms/*_cases.json` and both fixtures (2,607 texts; server output produced with Deno from the working-tree `sms_redaction.ts`) | 200 differ | **0 differ** |

**Full parity reached; no fixture rows still differ.** The existing XCTest `testShortcutSanitizerMatchesSharedRedactionFixture` was already failing against the current fixture (19 rows) before this change.

**Decided behaviour change (does not weaken digit masking).** The old Swift beneficiary rule deleted everything from «إلى»/"To:" to the end of the line. The new one, like the server since FU10/FU11, keeps the words after the name. Over the 2,607 texts, 200 outputs change. In 49 of them the new output contains a digit run the old one removed. Every one of those 49 is the user's own suffix of at most 4 digits, an amount, or a date or time. I checked this with the same allowed-context rules as the server's `sms_redaction_head_diff_test.ts`: 0 runs outside those classes. No third-party number, IBAN group or tagged name survives (the labelled set proves names and numbers). What the new rule keeps that the old one removed: the user's own account word and suffix («إلى حسابك *5678»), tense and status words, amounts, dates, and following sentences.

Performance: about 30 ms per message on the Mac (patterns compiled per call). That is well inside the Shortcut's 8-second budget.

Tests:
- New XCTest `testShortcutSanitizerRemovesEveryTaggedLeak` reads `../../supabase/functions/_shared/fixtures/sms_leak_labelled_cases.json` from the repo path, as the existing fixture test does. It asserts output equals the server, no secret survives, mustKeep is kept, and output is idempotent.
- Existing `testShortcutSanitizerMatchesSharedRedactionFixture` now passes.
- Before-proof: the old function fails both, as in the table above.

### (2) LEN-1 `textLength`

- **Field name: `textLength`** (JSON, camelCase), in both the upload body and the queued payload.
- Upload body: `"textLength": BackendCaptureClient.textLength(request.smsText)`, which is `trimmed.utf16.count` of the raw text, measured before redaction. Same unit as Dart/JS `String.length`.
- Queue: `SharedCaptureStore.Payload.textLength: Int?` is set in `enqueue` to `trimmed.utf16.count`, the same text as the stored `text`. The field is optional, so older records decode with it missing. Both `SharedCaptureStore.swift` copies are identical (`cmp`).
- For `ai`: the Dart replay should send the queued `textLength` when present, or `text.length` of the queued text otherwise (identical value).
- Tests:
  - `testQueuedPayloadCarriesUtf16TextLength` uses Arabic text plus an emoji, so `count` ≠ `utf16.count`.
  - `testShortcutUploadBodySendsTextLengthMeasuredBeforeRedaction` is a source pin.

### Runs

- Dart source-contract tests that read the Swift or iOS files:
  - privacy attack, CAP-0/CAP-6, H3/G3 egress, native bridge, entry points, notify v2, build50, ios_source_integrity, `test/ios/*` and others: **365 passed**;
  - `sync_diagnostics_report`, `broadcast_push_route`, `apns_open_telemetry` run alone: **46 passed**.
- XCTest (iPhone 17 Pro simulator, `xcodebuild test`, after `flutter build ios --config-only`): **200 passed, 0 failed** (197 + 3 new); `testShortcutSanitizerMatchesSharedRedactionFixture` and `testShortcutSanitizerRemovesEveryTaggedLeak` pass. Scratch DerivedData removed; no `app/build/ios` left.

### Compatibility

- Queued records from build 147 have no `textLength`. They decode, and the replay can compute it from `text`.
- An old server ignores the extra key.
- Build 147 against the new server: no `textLength` is sent, and the server falls back to its own measure.
