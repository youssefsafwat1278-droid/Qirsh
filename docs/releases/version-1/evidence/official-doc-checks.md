# Version 1 — official-documentation checks

- Access date for every source: **2026-11-17**.
- Prepared by a documentation agent (Claude Opus 5.5) for the release owner. Nothing was submitted, uploaded or changed in any console; the privacy manifests were **not** edited.
- Quotes are short (one per source, under 15 words). Everything else is paraphrase.
- Verdict and status words: `CORRECT-FOR-THIS-USE` / `WRONG` / `COULD-NOT-CONFIRM` for reason codes; `CONFIRMED` (primary source read today) / `UNCONFIRMED` (no primary source read today) for other facts.
- **Not legal advice.** The export-compliance, data-protection and policy statements below report what the vendors' documentation says; they are not a legal determination.
- Source register IDs refer to [`docs/release-process/SOURCES.md`](../../../release-process/SOURCES.md), corrected in place today.

## How the Apple pages were read this time

Apple's documentation site is rendered by JavaScript, which is why the earlier research only saw page titles. The same pages are served as JSON at `https://developer.apple.com/tutorials/data/documentation/<path>.json`. Fetched and read today (all HTTP 200):

| Page | JSON URL |
|---|---|
| Describing use of required reason API | `.../tutorials/data/documentation/bundleresources/describing-use-of-required-reason-api.json` |
| `NSPrivacyAccessedAPIType` (holds the reason codes for each category) | `.../bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype.json` |
| `NSPrivacyAccessedAPITypeReasons` | `.../bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons.json` |
| Describing data use in privacy manifests | `.../bundleresources/describing-data-use-in-privacy-manifests.json` |
| `NSPrivacyCollectedDataType`, `...Purposes`, `NSPrivacyTracking`, `NSPrivacyTrackingDomains` | `.../bundleresources/app-privacy-configuration/...json` |
| Complying with encryption export regulations | `.../tutorials/data/documentation/security/complying-with-encryption-export-regulations.json` |
| `ITSAppUsesNonExemptEncryption` | `.../bundleresources/information-property-list/itsappusesnonexemptencryption.json` |

The human-readable equivalents are the same paths under `https://developer.apple.com/documentation/`. App Store Connect Help, the App Review Guidelines ("Last Updated: October 16, 2026"), App privacy details, and the account-deletion page are static HTML and were fetched directly.

---

## a. Required-reason API reason codes

Primary source for every code below: `NSPrivacyAccessedAPIType` (JSON URL above), section "Possible values". Apple also states (describing-use-of-required-reason-api): declared reasons must "accurately reflect your use of each of these APIs" and the data may be used for the declared reasons only. Each **executable bundle** that calls a required-reason API needs its own manifest entry, so the share extension needs its own.

What the candidate's manifests declare (read today):

| Target | Category | Reasons declared |
|---|---|---|
| Runner (`app/ios/Runner/PrivacyInfo.xcprivacy`) | FileTimestamp | `C617.1` |
| Runner | UserDefaults | `CA92.1`, `1C8F.1` |
| Runner | DiskSpace | `85F4.1` |
| ShareBankMessage (`app/ios/ShareBankMessage/PrivacyInfo.xcprivacy`) | UserDefaults | `1C8F.1` |
| ShareBankMessage | FileTimestamp | `C617.1` |
| ShareBankMessage | DiskSpace | `85F4.1` |

Both targets: `NSPrivacyTracking` false, `NSPrivacyTrackingDomains` empty. The App Intent (`BankMessageShortcuts.swift`) is compiled into the Runner target (project.pbxproj build file `A00100000000000000000011`), so there is no third bundle that needs a manifest. `ShareBankMessage/SharedCaptureStore.swift` is byte-identical to `Runner/SharedCaptureStore.swift` (checked with `cmp`).

Call sites read (Swift):

- `UserDefaults.standard` (app only): `AppDelegate.swift:501,1202,1209,1227,1547,1553,1559,1671` — values written and read by the app itself (APNs registration failure, BG-drain earliest time).
- App Group `UserDefaults(suiteName: appGroupIdentifier)`: `SharedCaptureStore.swift:118` (both targets), `SharedOfferIntentStore.swift:47` (both targets), `SceneDelegate.swift:63,78` (app).
- File timestamp: `SharedCaptureStore.swift:4150-4154` `inflightFileIsStale` reads `.modificationDate` of `inflightFileURL()`, which is `appGroupContainerURL()` + file name (`:4121-4122`).
- Disk space: `SharedCaptureStore.swift:4771-4777` `deviceCapacityState()` reads `.volumeAvailableCapacityForImportantUsageKey` and maps it to a coarse `ok/near/full`; its comment says "Diagnostics only: a capture is refused only by an actual failed write". Only caller: `queueStats()` (`:4763`), reached only through the method-channel case `captureQueueStats` (`AppDelegate.swift:715-730`). Only Dart caller: `NativeCaptureBridge.captureQueueStats` from `SyncDiagnosticsScreen` (`sync_diagnostics_screen.dart:74`). That screen exists only when `syncDiagnosticsAvailable()` is true, which is `kDebugMode` (`sync_diagnostics_screen.dart:31`), and its route is registered only then (`app_router.dart`, "debug builds only; no route exists in release"). The screen's copy button puts `d.toRedactedText()` on the clipboard (`sync_diagnostics_screen.dart:121-122`), which includes the row `queue quota (device)` (`sync_diagnostics_report.dart:412`). The share extension never calls `queueStats()`.
- No other required-reason API call was found in the Runner, ShareBankMessage or BankMessageShortcuts Swift sources (system boot time, active keyboards: none). Pods (e.g. Sentry's `systemUptime`) are covered by the pods' own manifests — not verified here.

| Code | Official definition (primary; short quote or paraphrase) | How Qirsh uses it | Verdict |
|---|---|---|---|
| `CA92.1` (UserDefaults) | "read and write information that is only accessible to the app itself." Does not permit reading other apps' or system data. | App-only `UserDefaults.standard` in the main app (APNs failure record, BG-drain timing) | **CORRECT-FOR-THIS-USE** (Runner) |
| `1C8F.1` (UserDefaults) | Paraphrase: read/write information accessible only to apps, extensions and App Clips in the same App Group. | App Group suite `group.com.youssefsafwat.mali` shared by app and share extension | **CORRECT-FOR-THIS-USE** (Runner and ShareBankMessage). The earlier audit was right that `CA92.1` alone was wrong for this |
| `C617.1` (FileTimestamp) | Paraphrase: access timestamps, size or other metadata of files inside the app container, app group container or the app's CloudKit container. | Modification date of the in-flight upload registry file inside the App Group container | **CORRECT-FOR-THIS-USE** (both targets) |
| `85F4.1` (DiskSpace) | Paraphrase: display disk-space information to the person using the device; units of information or of time are allowed; the information and anything derived **may not be sent off-device** (narrow exception: local network to the same person's other device, with permission, never over the Internet). | Coarse ok/near/full state shown only on a debug-build diagnostics screen; copied to the clipboard only when the person taps Copy; never transmitted by the app; never displayed in release builds; never displayed by the extension | **CORRECT-FOR-THIS-USE, narrowly — see note** |
| `E174.1` (DiskSpace, *not declared*; the C-ios audit had proposed it) | Paraphrase: check whether there is enough space to write files, or delete files when low; "The app must behave differently based on disk space" observably. | The app never changes behaviour on free space (comment at `SharedCaptureStore.swift:4768-4770`) | **WRONG for Qirsh** — do not switch to it |
| `7D9E.1` (DiskSpace, not declared) | Paraphrase: include disk space in an optional bug report the person chooses to submit, prominently displayed. | Qirsh has no bug-report submission that carries this value | **WRONG for Qirsh** |

Note on `85F4.1`. The definition is about *displaying* the value; the only display is in debug builds, and the extension declares it only because the same source file is compiled in. Two points remain open:

1. **Clipboard.** Apple's text forbids sending the value or derived information off-device; it does not address a user-initiated copy to the clipboard (which Universal Clipboard can carry to another device). Whether App Review treats that as "sent off-device" is **COULD-NOT-CONFIRM** from Apple's documentation. The risk exists only in debug builds, which are never submitted.
2. **Release builds call nothing but still contain the API.** Apple's automated check works on API presence in the binary, so a declaration is still required as long as `deviceCapacityState()` is compiled into release builds.

Cleanest engineering action (proposal, not done): compile the probe out of release builds — for example make `deviceCapacityState()` return `.ok` under `#if !DEBUG` (or delete it, since its own comment says it is diagnostics only), keep the debug diagnostics row, and then **remove the DiskSpace entry from both manifests**. Until then, `85F4.1` is the only listed reason that matches what the code does; `E174.1` and `7D9E.1` do not. Verification after either path: generate the Xcode Privacy Report from the release archive and check the App Store Connect processing email for ITMS-91053.

Also noted: the build-147 processing email (did it carry ITMS-91053 for the then-undeclared DiskSpace use?) has not been seen by anyone in this assessment — **UNCONFIRMED**.

---

## b. Privacy manifest collected-data types, tracking, and App Store privacy details

### What Apple says (primary)

- `describing-data-use-in-privacy-manifests` (JSON): third-party SDKs provide their own manifests; "Your app’s privacy manifest file doesn’t need to cover data collected by third-party SDKs". Xcode's **Privacy Report** (Product > Archive > Generate Privacy Report) aggregates app and SDK manifests and is the intended input for the App Store Connect answers.
- `NSPrivacyTracking` (JSON): set true only if the app or SDK uses data for tracking as defined under App Tracking Transparency; true requires `NSPrivacyTrackingDomains`.
- **App privacy details** (https://developer.apple.com/app-store/app-privacy-details/, HTML, `CONFIRMED`): the App Store Connect answers must cover data collected by "you and/or your third-party partners"; third-party partners include advertising networks and third-party SDKs. "Collect" means transmitted off the device and kept longer than needed to service the request in real time. Data processed only on device is not collected. Optional disclosure requires **all** listed criteria (infrequent, not core, user-initiated each time, etc.).

### Official category names relevant to Qirsh

Official App Store Connect names (App privacy details page) with the matching manifest key (`NSPrivacyCollectedDataType` possible values, JSON):

| Qirsh data | App Store category > data type | Manifest key | Note |
|---|---|---|---|
| Sanitized SMS text sent to Qirsh servers (iOS: kept up to 7 days per policy §6) and to Google Gemini, with consent | User Content > **Emails or Text Messages** ("Including subject line, sender, recipients, and contents") | `NSPrivacyCollectedDataTypeEmailsOrTextMessages` | Apple's page says text messages include SMS. Retained beyond the request, so "collected". **Missing** from the Runner manifest today |
| Extracted transactions, balances, budgets | Financial Info > **Other Financial Info** | `NSPrivacyCollectedDataTypeOtherFinancialInfo` | Declared |
| Profile photo backed up to the cloud | User Content > **Photos or Videos** | `NSPrivacyCollectedDataTypePhotosorVideos` | **Missing** |
| Account ID (Supabase user ID) | Identifiers > **User ID** | `NSPrivacyCollectedDataTypeUserID` | **Missing** |
| Email address | Contact Info > **Email Address** | `NSPrivacyCollectedDataTypeEmailAddress` | Declared |
| Name, phone number (user settings) | Contact Info > **Name**, **Phone Number** | `...Name`, `...PhoneNumber` | Declared |
| Capture device identifier | Identifiers > **Device ID** | `...DeviceID` | Declared |
| Notification delivery/open events, engagement events | Usage Data > **Product Interaction** | `NSPrivacyCollectedDataTypeProductInteraction` | **Missing** |
| Crash reports (Sentry, consent-gated) | Diagnostics > **Crash Data** (also **Performance Data**, **Other Diagnostic Data** if Sentry sends them) | `...CrashData` etc. | Crash Data declared; Sentry's own manifest covers its collection; App Store Connect answers must still include it |
| Ad SDK data | Usage Data > **Advertising Data**; Identifiers > **Device ID**; Location > **Coarse Location**; Diagnostics > **Performance Data**, **Crash Data**; Usage Data > **Product Interaction** | — (declared in the GMA SDK's own manifest) | See below |
| Date of birth in user settings | **Other Data Types** (no specific type for date of birth in Apple's list — **UNCONFIRMED** mapping) | `...OtherDataTypes` | SEC-04 listed it |

Official purpose names: Third-Party Advertising; Developer’s Advertising or Marketing; Analytics; Product Personalization; App Functionality; Other Purposes. Every Qirsh-own type above is "App Functionality"; the shared-category-learning contribution is arguably "Product Personalization" or "App Functionality" — owner to choose.

### Google Mobile Ads / UMP linked but ads not shown

- Google (https://developers.google.com/admob/ios/privacy/data-disclosure, `CONFIRMED`) lists what the SDK collects: Device ID (advertising identifier or app/developer-scoped IDs), Advertising Data, Coarse Location (incl. from IP), Performance Data, non-user crash logs, product interactions; purposes include third-party advertising and analytics. Google says SDK 11.2.0+ ships a privacy manifest and that the app developer remains responsible for checking it and keeping disclosures up to date.
- Neither Google's page nor Apple's says what to declare when the SDK is linked but never initialized. **UNCONFIRMED.** Reasoning from Apple's definition: "collect" means data actually transmitted. If the shipped build can never start the SDK, nothing is collected; but the SDK's own manifest is still aggregated into the Privacy Report, and Qirsh's ads can be switched on remotely (`enable_*` flags, D-19) in any build that carries the `admob` variable group (`ios-signed-release` and `android-release` do; `ios-signed` does not — SEC-01). App privacy details can be edited without a new build, but must be correct **before** any flag is turned on. Safe course: declare the GMA data types (Third-Party Advertising / Analytics, linked as Google describes) for any build in which the flags can serve ads.
- Tracking: D-6 records non-personalized requests and no ATT prompt; `NSPrivacyTracking` false is consistent with that. Whether Google's use of the device identifier in non-personalized serving counts as "tracking" in Apple's sense is not stated by either vendor — **UNCONFIRMED**. The GMA SDK version actually linked (needed to confirm it ships a manifest, 11.2.0+) was not checked — **UNCONFIRMED** (read `app/ios/Podfile.lock`).

---

## c. App Review items

Source: App Review Guidelines, https://developer.apple.com/app-store/review/guidelines/ ("Last Updated: October 16, 2026"), unless another URL is given.

| Item | What the source says (paraphrase unless quoted) | Qirsh finding | Status |
|---|---|---|---|
| **1.5 Developer information** | App **and** Support URL must include an easy way to contact you; accurate, up-to-date contact information. | **Conflict found:** the in-app contact address is `support@money-companion.app` (`help_screen.dart:84`, `settings_screen.dart:1730`) — an old project name — while the privacy policy §9 gives `business@qirsh.site`. Confirm one monitored address and use it in the app, the Support URL and the policy | CONFIRMED rule; defect to fix |
| **2.1 App completeness** | Include demo account info "(and turn on your back-end service!)"; a built-in demo mode needs Apple's prior approval. | The build has **no password sign-in** — email is a one-time code (`supabase_auth_service.dart:391-405`). See the reviewer-notes draft for the consequence | CONFIRMED |
| **2.5.1** | Public APIs only; use frameworks for their intended purpose. | App Intents for Shortcuts: intended use | CONFIRMED |
| **2.5.2** | No downloading code that changes features. | Remote catalog carries parser **patterns** (content), not code (app/CLAUDE.md rule 2) — keep it that way | CONFIRMED |
| **2.5.4** | Background services only for intended purposes. | BGTask drain of captured messages is task completion — keep it scoped | CONFIRMED |
| **2.5.11 SiriKit and Shortcuts** | (i) register only intents you can handle; (ii) phrases must relate to the app; (iii) no ads/marketing between request and fulfillment. | `PostBankStatusIntent` "Process Bank SMS" and its phrases (`BankMessageShortcuts.swift:11-20,594-610`) relate to the app; no ads in the intent | CONFIRMED |
| **2.5.14** | Explicit consent and a clear indication when recording or logging user activity. | Capture runs only through a user-built automation or a user share; not an activity log in Apple's sense — low risk | CONFIRMED rule |
| **2.5.16** | Extensions must relate to the app's content. | Share extension captures bank text; it also routes shared URLs to Offers (IOS-07) — still app-related | CONFIRMED |
| **2.5.18** | Ads only in the main binary; ads must let users report inappropriate ads and see targeting information. | Ads code is not in the extension target. If ads are ever enabled, the report-an-ad and "why this ad" requirements apply | CONFIRMED |
| **2.5.19** | No hidden, dormant or undocumented features. | Remote ad flags, dormant features (D-13, PROD-09) — describe them truthfully in review notes | CONFIRMED |
| **3.1.1 In-App Purchase** | IAP is required to **unlock features or functionality** within the app. | No purchase or paid unlock found in the iOS build; coupons open merchant URLs (D-14). The ad-free entitlement (D-7) must not be sold outside IAP if it is ever sold | N/A today — CONFIRMED rule, owner to confirm no paid unlock ships |
| **4.8 Login Services** | A third-party/social login (Google Sign-In is named) used for the primary account requires an equivalent option that limits data to name + email, allows email hiding, and does not collect interactions for ads without consent. Not required if the app **exclusively** uses its own account system. | `ios-signed` builds show Apple + Google + email code. Sign in with Apple is shown on iOS whenever Google is (`auth_screen.dart:49,332`), which satisfies 4.8. If Apple sign-in were ever off while Google is on, 4.8 would fail | CONFIRMED |
| **5.1.1(v) Account deletion** | If the app supports account creation it must offer deletion within the app. Support page (https://developer.apple.com/support/offering-account-deletion-in-your-app/): easy to find; tell people if it takes time; Sign in with Apple apps should revoke tokens via the REST API; reauthentication and confirmation steps are allowed but must not make deletion unnecessarily difficult. | In-app deletion exists (More → Delete my account and all my data → … → Delete permanently). Reauthentication is Apple, Google or an emailed code. Policy text (30 days, undoable) contradicts the app (immediate) — V1-006 | CONFIRMED |
| **5.1.2(i) Data use and sharing** | "including with third-party AI" — disclose where personal data is shared and get explicit permission first. | Consent sheet names Google Gemini and Google Places (`app_en.arb` `smartConsentBullet1`) and is off by default; policy §7 matches for Gemini/Places but omits AdMob (V1-005) | CONFIRMED |
| **Export compliance** | `ITSAppUsesNonExemptEncryption` (JSON page): set **NO** only if the app, including linked libraries, uses no encryption or only encryption **exempt** from export-compliance documentation; otherwise **YES**, and then normally also `ITSEncryptionExportComplianceCode` from Apple after documentation review. "Complying with encryption export regulations": OS-provided encryption such as HTTPS via URLSession is "typically" exempt; proprietary encryption is not; exempt use may still require a year-end **self-classification report** to the US government. App Store Connect Help "Overview of export compliance": standard algorithms, OS crypto and non-standard crypto all need a determination; the developer is responsible for the EAR determination; France has its own import controls. | Qirsh implements standard algorithms itself, beyond OS HTTPS: Argon2id + symmetric backup encryption via the Dart `cryptography` package, SQLCipher / `sqlite3mc` database encryption, CryptoKit AES-GCM for the capture queue. Whether these are "exempt" (for example under US mass-market or data-protection provisions) is a legal determination Apple's pages do not make. The plist currently says `false` (`Info.plist:103-104`) | Key name and semantics CONFIRMED. The correct value for Qirsh is **UNCONFIRMED — needs an export-control determination; this is not legal advice**. The App Store Connect questionnaire wording itself could not be read without an account |
| **iPad screenshots** | App Store Connect Help "Screenshot specifications": required sizes are iPhone with Dynamic Island (medium display) and, "iPad (if your app supports iPadOS)", at least one **iPad 13-inch** screenshot. | `TARGETED_DEVICE_FAMILY = "1,2"` — iPad screenshots are mandatory unless the device family is reduced to iPhone (V1-014) | CONFIRMED |
| **Phased release** | App Store Connect Help "Release a version update in phases": an **update** can be released over 7 days to users with automatic updates (1%, 2%, 5%, 10%, 20%, 50%, 100%); pausable for up to 30 days in total; anyone can still download manually. | The page describes the option only for version updates. A **first version** has no existing users to phase; the page does not say so in words — **UNCONFIRMED** that the option is hidden for 1.0, but it cannot work as a canary for V1 either way | CONFIRMED for updates |
| **TestFlight** | App Store Connect Help "TestFlight overview": internal testers up to 100 App Store Connect users; external up to 10,000; the first build added to an external group goes to App Review; builds are testable for 90 days. | — | CONFIRMED |
| **`testFlightInternalTestingOnly`** | `xcodebuild -help` (Xcode 27.2, local, read today): when enabled, the build "cannot be distributed via external TestFlight or the App Store". | `ios-signed` exports with it set to true (IOS-02 / V1-009), so its builds can never be submitted | CONFIRMED |
| **Upload floor** | https://developer.apple.com/news/upcoming-requirements/: since 2026-04-28 Xcode 26 / iOS 26 SDK; since 2026-09-09 minimum deployment target iOS 13; age-rating answers since 2026-01-31. No newer item listed today. | — | CONFIRMED |

---

## d. Google Play (facts only — Android's V1 scope is the owner's call)

| Item | Source (fetched today) | Fact | Status |
|---|---|---|---|
| SMS/Call Log exception | https://support.google.com/googleplay/android-developer/answer/10208820 | Exception "SMS-based money management" (apps that track and manage budget) covers READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH; such apps may not exfiltrate or share non-financial or personal SMS history. Apps that believe they qualify must declare the permissions in Play Console. Upcoming: from 2027-01-27 phone-call account verification is no longer a permitted READ_CALL_LOG use (not relevant to Qirsh) | CONFIRMED |
| Permissions Declaration Form | https://support.google.com/googleplay/android-developer/answer/9214102 | Play Console → App content → Permissions Declaration Form; select core use case; reviewer instructions; **video demonstration required**; test credentials if sign-in is needed; publishing changes is blocked until handled; review can take several weeks | CONFIRMED |
| Target API | https://developer.android.com/google/play/requirements/target-sdk | From **2026-08-31** new apps and updates must target **Android 16 (API 36)**; existing apps must target API 35+ to stay available to new users on newer devices; extension could be requested to **2026-11-01** (passed). No API 37 date announced on the page | CONFIRMED |
| Account deletion web URL | https://support.google.com/googleplay/android-developer/answer/13327111 | In-app path **and** a web link where users can request deletion without the app; page must load, name the app/developer as on the listing, make the deletion path prominent; entered in the Data safety form's data-deletion questions; enforcement possible after 2024-05-31 | CONFIRMED |
| Advertising ID | https://support.google.com/googleplay/android-developer/answer/6048248 | Apps targeting Android 13+ must declare `com.google.android.gms.permission.AD_ID` to read the ID; the Google Mobile Ads SDK declares it in its library manifest and it merges into the app manifest by default. The **Play Console "Advertising ID" declaration** (where it sits, whether non-ad apps must answer) was found only in secondary sources | AD_ID permission CONFIRMED; console declaration details **UNCONFIRMED** |
| 16 KB page size | https://developer.android.com/guide/practices/page-sizes | Apps targeting Android 15+ must support 16 KB page sizes on 64-bit devices; the page states that from **2027-02-01** app **updates** that don't support 16 KB cannot be released. NDK r28+ and AGP 8.5.1+ align by default; Flutter apps ship native libraries, so the release AAB must be checked (`zipalign -c -P 16`, APK Analyzer). The page did not state a separate date for new apps — **UNCONFIRMED** whether new apps are already enforced | CONFIRMED as quoted dates |
| Closed testing for new personal accounts | https://support.google.com/googleplay/android-developer/answer/14151465 | Personal accounts created after 2023-11-13: closed test with at least **12** testers opted in for **14** consecutive days before applying for production. The page speaks of personal accounts; it does not say in words that organization accounts are exempt | CONFIRMED (organization exemption UNCONFIRMED) |

---

## Changes made to `SOURCES.md` today

- `SRC-APPLE-PRIVACY-MANIFEST`: now `FETCHED` (via the JSON endpoints); reason-code definitions confirmed; `E174.1` flagged as not matching Qirsh's use.
- `SRC-APPLE-EXPORT`: `ITSAppUsesNonExemptEncryption` key and its YES/NO semantics confirmed; developer doc now `FETCHED`.
- `SRC-APPLE-1.5`, `SRC-APPLE-4.8`, `SRC-APPLE-TESTFLIGHT`, `SRC-APPLE-PRIVACY-LABELS`: corrected or extended (contact conflict, email-code sign-in, internal-only export option, missing data types, SDK disclosure).
- New: `SRC-APPLE-SCREENSHOTS`, `SRC-APPLE-PHASED`, `SRC-GMA-DISCLOSURE`, `SRC-PLAY-PERMDECL`, `SRC-PLAY-ADID`, `SRC-PLAY-16KB`.
- Tier 3 items 1, 2 and 15 updated.

---

## e. Closure round re-checks (ops specialist, 2026-11-17)

Fetched again on **2026-11-17** by the backend-privacy-ops specialist (model `claude-opus-5-5`, as stated by the harness). Paraphrase only.

| Source (URL, access date 2026-11-17) | What it says | Used for |
|---|---|---|
| App privacy details — https://developer.apple.com/app-store/app-privacy-details/ (no "last updated" date shown) | "Collect" = transmitted off device and kept longer than needed to service the request in real time; on-device-only processing is not collection; answers cover third-party partners and SDKs; definitions of linked, tracking and the purposes | STORE-READINESS closure table (V1-003). A linked SDK that never runs transmits nothing; Apple does not address that case in words — **UNCONFIRMED** that App Review accepts "not collected" for a linked, never-started ad SDK |
| Complying with encryption export regulations — `https://developer.apple.com/tutorials/data/documentation/security/complying-with-encryption-export-regulations.json` | `NO` only if the app, including linked libraries, uses no encryption or only exempt encryption; OS-provided encryption is typically exempt; exempt use may still need a year-end self-classification report | A14 (V1-026) |
| App Store Connect Help, "Overview of export compliance" (same page as section c; URL not re-recorded here) | The developer is responsible for the EAR determination; France has its own import rules | A14 |
| App Store Connect Help, "Export compliance documentation for encryption" — https://developer.apple.com/help/app-store-connect/reference/export-compliance-documentation-for-encryption/ | Categories: only Apple OS encryption (no documents); standard algorithms instead of or in addition to OS encryption (French declaration if distributed in France); proprietary/non-standard algorithms (CCATS and the French declaration) | A14: Qirsh is in the **standard algorithms** category (SQLCipher/`sqlite3mc`, Dart `cryptography`) |
| App Review — https://developer.apple.com/distribute/app-review/ and App Review Help "Complete review" — https://developer.apple.com/help/app-review/before-submitting-for-review/complete-review | Provide active demo credentials; if sign-in requires an authentication code, include the code or how to obtain it in the notes; list external authentication services; apps with sensitive data may offer a demo mode (needs prior approval per Guideline 2.1) | REVIEWER-NOTES-DRAFT (V1-015): Sign in with Apple path |

Supabase test OTPs for **email** sign-in (a fixed code for one address) were not found in this check — **UNCONFIRMED**; not relied on.
