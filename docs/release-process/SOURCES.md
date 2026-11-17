# Release-readiness standards: source register

Purpose: the primary sources behind Qirsh's reusable release-readiness process, with what each one
requires and how it applies to Qirsh (Flutter app; native iOS App Intents/Shortcuts + share extension;
native Android SMS capture; Supabase Postgres + Deno Edge Functions; Next.js admin; AdMob + UMP;
consent-gated AI-assisted SMS parsing; TestFlight/App Store + Google Play).

- Access date for every source below: **2026-11-17** (fetched live that day unless marked otherwise).
- Summaries are paraphrases. At most one short quoted phrase per source.
- This register is a reading aid for the team. It is **not** a certification, audit, or statement of
  formal compliance with any standard listed here. Store policies change; re-check each source at the
  start of every release cycle (see Tier 3).

Status markers used below:
- `FETCHED` the page was retrieved and read on the access date.
- `PARTIAL` retrieved, but the relevant part was truncated, JS-rendered, or not present.
- `NOT FETCHED` could not be retrieved; content is from prior knowledge and must be re-verified.

---

## Tier 1: MANDATORY platform and store requirements

These are the items Apple or Google will reject a build for, block updates over, or remove the app for.
Every release checklist item that cites a `SRC-APPLE-*` or `SRC-PLAY-*` ID is a release blocker.

### Apple

**SRC-APPLE-ARG** App Review Guidelines (umbrella source)
- URL: https://developer.apple.com/app-store/review/guidelines/ — `FETCHED` (page shows "Last Updated: October 16, 2026")
- Used by all `SRC-APPLE-<section>` IDs below.

**SRC-APPLE-1.5 / 1.6** Developer information; data security
- 1.5: accurate, easy-to-find contact info both in the app and at the Support URL.
- 1.6: appropriate security measures for user information; prevent unauthorized use/disclosure/access.
- Qirsh: support link in Settings must work; 1.6 is the store-level anchor for the OWASP work in Tier 2
  (RLS, token storage, no PII in logs).

**SRC-APPLE-2.1** App completeness
- Final, fully functional build; no placeholder text; tested on device.
- Provide demo account credentials **and keep backend services live** during review; a built-in demo
  mode needs Apple's prior approval.
- IAP (if any) must be complete and visible to the reviewer.
- Qirsh: a reusable review account on the production Supabase project with seeded, fictional data;
  Edge Functions, AI parsing, and push must work during the review window. Note in review notes that
  automatic SMS reading exists only on Android; on iOS, capture runs through a Shortcuts automation
  and the share extension, and the notes must say how a reviewer exercises those two paths.

**SRC-APPLE-2.3** Accurate metadata
- 2.3.1(a): describe new features specifically in review notes.
- 2.3.3: screenshots show the app in use (not just splash/login).
- 2.3.6: answer age-rating questions honestly. 2.3.7: name ≤30 chars; no keyword stuffing.
- 2.3.9: use fictional account data in screenshots. 2.3.10: no other platforms' names/imagery
  (do not show Android/Google Play in iOS screenshots). 2.3.12: "What's New" must describe real changes.
- Qirsh: screenshot set must use a seeded demo ledger, not a real user's transactions.

**SRC-APPLE-2.5** Software requirements (selected)
- 2.5.1 public APIs only; 2.5.2 no downloading/executing code that changes features.
- 2.5.11: SiriKit/Shortcuts intents must match the app's functionality.
- 2.5.16: widgets, extensions, notifications must relate to the app's content.
- 2.5.18: display ads only in the main binary, not in extensions/widgets; ads age-appropriate; users
  must be able to report inappropriate ads.
- 2.5.19: no hidden, dormant, or undocumented features.
- Qirsh: confirm no AdMob code is linked into the share extension or App Intents extension; server-side
  feature flags that unlock unreviewed features risk 2.5.19 — document them in review notes.

**SRC-APPLE-3.1 / 3.2** Business
- 3.1.1: unlocking digital features/content requires IAP. 3.2.1(viii) and 5.1.1(ix): regulated
  financial services (trading, banking, investing) must be submitted by the licensed entity.
  3.2.2(ix): personal-loan rules (max 36% APR, no ≤60-day full repayment).
- Qirsh: personal-loan and licensed-institution rules are **not applicable** to a budgeting/expense
  tracker that moves no money. Coupons/referral rewards must not unlock paid digital features outside
  IAP. Re-assess if Qirsh ever adds payments, lending, or investment advice.

**SRC-APPLE-4.2** Minimum functionality — app must do more than wrap a website. Low risk for Qirsh.

**SRC-APPLE-4.8** Login services
- If a third-party/social login sets up the primary account, also offer an equivalent option that limits
  collection to name + email, allows email hiding, and does not collect interactions for advertising
  without consent (Sign in with Apple satisfies this). Exempt if only the app's own account system is used.
- Qirsh: if Google sign-in is offered on iOS, Sign in with Apple (or equivalent) is required.

**SRC-APPLE-5.1.1** Data collection and storage
- (i) privacy policy linked in App Store Connect **and** in the app; covers what/how/uses, third-party
  protections, retention/deletion, consent revocation.
- (ii) consent for collection; easy withdrawal; clear purpose strings; paid features can't depend on
  granting data access.
- (iii) data minimization. (iv) no coercion; offer alternatives when users decline.
- (ix) regulated financial services must be submitted by the legal entity (see 3.2 note).

**SRC-APPLE-5.1.1v** Account sign-in and account deletion
- Guideline: if the app supports account creation, it must offer account **deletion inside the app**;
  revoke social-login credentials; don't store social tokens off-device.
- Support page: https://developer.apple.com/support/offering-account-deletion-in-your-app/ — `FETCHED`
  - Deletion must remove the account record and associated personal data (deactivation alone fails).
  - No phone/email/support-ticket flow unless the app is in a highly regulated industry.
  - Need not be instant, but tell users how long it takes and confirm completion.
  - Sign in with Apple apps should revoke tokens via the REST API.
  - Tell users with Apple subscriptions that billing continues until they cancel.
- Qirsh: verify the in-app delete path end-to-end (auth user, ledger rows, storage objects, push tokens,
  AI-parse logs, Sentry user context) against production; state retained data (e.g. fraud/legal) in the
  privacy policy.

**SRC-APPLE-5.1.2** Data use and sharing
- Clearly disclose sharing with third parties, **explicitly including third-party AI**, and get explicit
  permission before sharing. Tracking requires ATT. Can't require enabling push/location/tracking to
  use the app.
- (ii) no repurposing data without further consent.
- Qirsh: the AI-assisted SMS/text parsing path must name the AI provider category, what text is sent, and
  obtain explicit opt-in before the first send; declining must leave manual entry working.

**SRC-APPLE-5.6** Developer code of conduct — accurate developer info; review prompts only via the
system API (no custom review prompts); no manipulative monetization.

**SRC-APPLE-SDK** Minimum Xcode/SDK and deployment target for uploads
- URL: https://developer.apple.com/news/upcoming-requirements/ — `FETCHED`
- Since **2026-04-28**: uploads must be built with **Xcode 26+** and the **iOS 26 SDK** (or later).
- Since **2026-09-09**: iOS/iPadOS uploads must have a **minimum deployment target of iOS 13** or later.
- Since 2026-01-31: the updated age-rating questionnaire had to be answered in App Store Connect.
- Since 2025-02 (sandbox 2025-01-20, production 2025-02-24): APNs server trust store must include the
  USERTrust RSA (SHA-2) root — relevant only if a server talks to APNs directly (e.g. an Edge Function).
- EU: DSA trader status required for EU distribution (since 2024-10-16 for updates, 2025-02-17 removal).
- Qirsh: CI must pin Xcode ≥26; Flutter's own iOS floor is iOS 13 (Flutter iOS deployment doc).

**SRC-APPLE-PRIVACY-MANIFEST** Privacy manifests and required-reason APIs
- URLs: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files and
  https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api —
  `PARTIAL` (JS-rendered; only titles retrieved). The upcoming-requirements page (`FETCHED`) confirms
  that since **2024-05-01** uploads must declare approved reasons for required-reason APIs, including
  those used by third-party SDKs.
- From prior knowledge (re-verify): `PrivacyInfo.xcprivacy` keys `NSPrivacyTracking`,
  `NSPrivacyTrackingDomains`, `NSPrivacyCollectedDataTypes`, `NSPrivacyAccessedAPITypes`; categories
  include UserDefaults, file timestamp, system boot time, disk space, active keyboards; reason `CA92.1`
  (app-only UserDefaults) and `1C8F.1` (app-group UserDefaults); listed "commonly used" SDKs must ship
  signed manifests.
- Qirsh: the app **and each extension** (share extension, App Intents) that touch app-group
  UserDefaults need correct manifests; Flutter plugins and AdMob/Sentry SDK manifests must be present
  in the archive. Check the App Store Connect upload email for missing-reason warnings.

**SRC-APPLE-PRIVACY-LABELS** App privacy details ("nutrition labels")
- URL: https://developer.apple.com/app-store/app-privacy-details/ — `FETCHED`
- Required for new apps and updates; must cover data collected by third-party SDKs (ads, analytics,
  crash reporting). "Collect" means off-device and retained longer than needed for the real-time
  request. Tracking = linking with third-party data for ads/measurement, or sharing with data brokers.
  Optional-disclosure exemption requires all criteria (infrequent, optional, user-initiated each time).
  Financial Info types: Payment Info, Credit Info, Other Financial Info. Privacy Policy URL required.
- Qirsh: transactions/budgets → "Other Financial Info" (linked, app functionality); SMS text sent for AI
  parsing → declare; AdMob → Identifiers/Usage/Advertising data; Sentry → Diagnostics. Labels can be
  edited without a new build but must be updated whenever practices change.

**SRC-APPLE-ATT** App Tracking Transparency
- URL: https://developer.apple.com/app-store/user-privacy-and-data-use/ — `FETCHED`
- ATT permission is required before tracking or reading IDFA; SDK behavior counts as the app's;
  fingerprinting is prohibited even with ATT permission; functionality can't be gated on allowing tracking.
- The page does not explicitly address non-personalized ads. Inference: if AdMob is configured so that
  no cross-app tracking or IDFA access occurs, ATT is not triggered — but the privacy manifest,
  privacy labels, and `NSPrivacyTracking` must then truthfully say "no tracking". If IDFA is read
  anywhere (including by the AdMob SDK), ATT + `NSUserTrackingUsageDescription` are required.
- Qirsh: decide explicitly (personalized with ATT vs. non-personalized without) and make SDK config,
  manifest, labels, and UMP messaging consistent.

**SRC-APPLE-TESTFLIGHT** TestFlight
- URL: https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview — `FETCHED`
- Internal testers ≤100 (App Store Connect users); external ≤10,000; the first build for external
  testers needs Beta App Review; builds expire after **90 days**; test info (description, what to test,
  feedback email) needed. Guideline 2.2: testers can't be compensated.

**SRC-APPLE-EXPORT** Export compliance
- URL: https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance — `FETCHED`
  (https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations — `PARTIAL`, title only)
- Any use of encryption (including standard/OS crypto) requires an export-compliance determination per
  version; the developer is responsible for the EAR determination; setting the Info.plist key avoids
  re-answering each upload. France has separate import rules (banking apps listed as exempt).
- Qirsh: if only HTTPS/OS crypto is used, record the determination once and set
  `ITSAppUsesNonExemptEncryption` accordingly (key name from prior knowledge; verify).

### Google Play

**SRC-PLAY-TARGETSDK** Target API level
- URL: https://developer.android.com/google/play/requirements/target-sdk — `FETCHED`
- From **2026-08-31**: new apps and updates must target **Android 16 (API 36)**; existing apps must
  target API 35+ to stay visible to new users on newer devices. Extension available to **2026-11-01**
  (that extension window has now passed).
- Qirsh: `targetSdk` ≥36 in the release AAB is a hard gate; review Android 16 behavior changes
  (and SMS receiver / foreground-service rules) when raising it.

**SRC-PLAY-SMS** SMS and Call Log permissions policy
- URL: https://support.google.com/googleplay/android-developer/answer/10208820 — `FETCHED`
- Default rule: only the registered default SMS/Phone/Assistant handler may use these permissions.
- Exceptions (temporary, reviewed, core functionality only, no alternative) include **"SMS-based money
  management"** (budget tracking) for READ_SMS, RECEIVE_SMS, RECEIVE_MMS, RECEIVE_WAP_PUSH, and
  SMS-based financial transactions. Budgeting apps may not exfiltrate or share non-financial/personal
  SMS history.
- A **Permissions Declaration Form** in Play Console is required; changes in use require resubmission;
  undeclared or non-compliant use can lead to removal. Must also comply with Spyware, Permissions, User
  Data policies. Upcoming (2027-01-27): call-based account verification removed as a READ_CALL_LOG use.
- Qirsh: highest-risk Android item. Request only the minimal SMS permissions actually used; filter to
  financial senders on-device; never upload non-financial SMS; make the AI-parse upload explicitly
  consented; record a demo video for the declaration; keep app usable when the permission is denied.

**SRC-PLAY-USERDATA** User Data policy (incl. prominent disclosure)
- URL: https://support.google.com/googleplay/android-developer/answer/10144311 — `FETCHED`
- Privacy policy in Play Console **and** in-app; public, non-PDF, labeled as privacy policy.
- **Prominent disclosure** in-app, during normal use, before the runtime permission prompt, describing
  data and use; consent needs an affirmative action; collection must not start before consent.
- Encrypted transmission; limited use; no sale of personal/sensitive data (financial, SMS, auth data
  are listed as personal and sensitive). Requirements extend to third-party SDKs **and third-party AI**.
- Qirsh: the SMS capture and AI-parse onboarding screens are the prominent disclosure; they must
  precede the OS permission dialog.

**SRC-PLAY-DATASAFETY** Data safety form
- URL: https://support.google.com/googleplay/android-developer/answer/10787469 — `FETCHED`
- Required for every app on closed/open/production tracks (internal-only exempt). Includes SDK data;
  "encrypted in transit" may only be claimed if all off-device data is; deletion-request mechanism
  must be declared; ephemeral processing is still declared (not shown publicly). Inaccuracy can block
  updates or remove the app; must be updated when practices change. Must match the privacy policy.
- Qirsh: keep one data inventory that drives Apple labels, Play Data safety, and the privacy policy.

**SRC-PLAY-ACCOUNT-DELETION** Account deletion
- URL: https://support.google.com/googleplay/android-developer/answer/13327111 — `FETCHED`
- Apps that allow account creation need an **in-app** deletion path **and** a **web URL** where users can
  request deletion without the app (references app/developer name as on the listing). Deletion covers
  associated data; disclosed exceptions for security/fraud/regulatory retention. Enforcement since
  after 2024-05-31.
- Qirsh: publish and test a web deletion page (e.g. on the admin/marketing domain) and enter it in
  Data safety.

**SRC-PLAY-FINANCIAL** Financial Services policy + Financial features declaration
- Policy: https://support.google.com/googleplay/android-developer/answer/9876821 — `FETCHED`
- Declaration: https://support.google.com/googleplay/android-developer/answer/13849271 — `FETCHED`
- Personal-loan, EWA, binary-options rules are **not applicable** to Qirsh (no lending, no money
  movement). However, **every** app must complete the financial features declaration (including the
  option "doesn't provide any financial features"). No explicit "budgeting" option is listed; the
  correct choice for a budgeting tracker (no features vs. "Other") is **unverified** — decide and record
  rationale.

**SRC-PLAY-ADS** Ads policy (and Families)
- URL: https://support.google.com/googleplay/android-developer/answer/9857753 — `FETCHED`
- No ads mimicking app UI or system notifications; no ads in tap targets for app functions; no
  unexpected interstitials; Advertising ID only for ads/analytics, respect opt-out, no linking to
  persistent IDs, disclose in privacy policy. Families ad rules apply only if the app targets children —
  Qirsh is not child-directed, so Families requirements are deliberately out of scope (ensure target
  audience in Play Console excludes under-13s).

**SRC-PLAY-TESTING-TRACK** Testing requirement for new personal developer accounts
- URL: https://support.google.com/googleplay/android-developer/answer/14151465 — `FETCHED`
- Personal accounts created after 2023-11-13: closed test with **12 testers** opted in for **14
  continuous days** before production access can be requested. (Does not apply to organization
  accounts; confirm which type Qirsh uses.)

**SRC-PLAY-REVIEW-LOGIN** Sign-in details for review
- URL: https://support.google.com/googleplay/android-developer/answer/15748846 — `FETCHED`
- Credentials must always work, be reusable, location-independent, in English; OTP/2-step must be
  bypassable for the review account; expired credentials can cause rejection.
- Qirsh: same seeded review account as SRC-APPLE-2.1, exempt from OTP/email confirmation.

**SRC-PLAY-STAGED-ROLLOUT** Staged rollouts (process capability; not a policy rule)
- URL: https://support.google.com/googleplay/android-developer/answer/6346149 — `FETCHED`
- Updates only (not first publish); percentage set manually; **halt** stops new users receiving it but
  does not roll back installed users — the fix is a new, higher-versionCode release. Countries can't be
  removed once rollout starts.

**SRC-PLAY-PRELAUNCH** Pre-launch report (process capability)
- URLs: https://support.google.com/googleplay/android-developer/answer/9842757 and
  https://support.google.com/googleplay/android-developer/answer/9844487 — summarized via search
  results (`PARTIAL`; full pages not fetched).
- Automated device-lab crawl of test-track builds reporting crashes/ANRs, slow startup, memory, and
  accessibility issues; test credentials can be supplied (standard widgets only — Flutter-rendered
  login fields may not be fillable by the crawler).

**SRC-PLAY-QUALITY** Core app quality guidelines (Google's minimum quality bar; partly enforced via
vitals/policy)
- URL: https://developer.android.com/docs/quality-guidelines/core-app-quality — `FETCHED`
- Relevant IDs: `Stability_ANR`, `App_Startup_Time` (feedback if >2 s), `State_Preservation`,
  `Sensitive_Permissions`, `Minimize_Permissions`, `Permission_Rationale`, `Sensitive_Data_Logging`
  (no PII in system log), `Sensitive_Data_Storage`, `Network_Security_Traffic` (TLS only),
  `Network_Security_Configuration`, `Component_Export` (explicit `android:exported`; only export what
  other apps must call), `Production_Build_Quality` (no debug libraries), `Cryptographic_Algorithms`,
  `App_Data_Backup`, `Back_Gesture_Nav`, `Target_SDK_Version`.
- Qirsh: SMS BroadcastReceiver must be protected (`BROADCAST_SMS` sender permission / not exported to
  arbitrary apps); `dataExtractionRules` should exclude tokens/secure storage from cloud backup.

---

## Tier 2: RECOMMENDED engineering practices

Not store-enforced. Adopted in proportion to a small team; deliberately skipped items are listed.

**SRC-SRE-LAUNCH** Google SRE Book, ch. 27 "Reliable Product Launches at Scale"
- URL: https://sre.google/sre-book/reliable-product-launches/ — `FETCHED`
- Launch Coordination Checklist areas: architecture/dependencies, integration, capacity, failure modes,
  client behavior, processes/automation, development process, external dependencies, rollout planning.
- Practices: staged/canary rollouts; feature flags; client retries with exponential backoff and jitter
  to avoid thundering herds; server-side config to disable features without a new app release;
  version-controlled config; release branches; named owner per launch step; keep the checklist lean
  (each question justified by a past failure); fast path for low-risk launches; mobile
  clients can't be patched quickly, so build checklists from first principles.
- Adopt: one lean checklist derived from Qirsh's own incidents (sync conflicts, consent re-ask, push
  broadcast); kill-switch flags for AI parsing, SMS capture, ads, push broadcast; backoff+jitter on
  sync/retry loops; a written rollout plan with owners; low-risk fast path for copy/l10n-only releases.
- Not adopted: dedicated Launch Coordination Engineer role, multi-region capacity provisioning, formal
  load-test programs per launch — disproportionate at current scale; one person may own launch
  coordination per release.

**SRC-SRE-CANARY** SRE Workbook, "Canarying Releases"
- URL: https://sre.google/workbook/canarying-releases/ — `FETCHED`
- Small, representative canary; compare against control, not before/after; few user-facing metrics
  (SLIs); one canary at a time; include peak load; have a rollback path.
- Adopt: Play staged rollout (e.g. small % first) and App Store phased release as the client canary;
  Edge Function deploys watched against error rate/latency for a fixed window; one rollout at a time.
- Not adopted: automated statistical canary analysis tooling.

**SRC-AWS-OPS** AWS Well-Architected, Operational Excellence pillar
- URL: https://docs.aws.amazon.com/wellarchitected/latest/operational-excellence-pillar/welcome.html — `FETCHED`
- Activities: organize, prepare, operate, evolve; operations as code; capabilities include change flow
  with quality gates, mitigating deployment risk, supportability, observability, event response,
  learning from events. Make an informed, explicit decision to enter production.
- Adopt: migrations and Edge Function config in git; CI quality gates; written go/no-go decision;
  runbooks for each risky capability (several already exist in `docs/`); post-incident notes.

**SRC-AWS-ORR** AWS Operational Readiness Reviews
- URL: https://docs.aws.amazon.com/wellarchitected/latest/operational-readiness-reviews/wa-operational-readiness-reviews.html — `FETCHED` (whitepaper dated 2022-06-30)
- ORR = curated questions distilled from your own post-incident analyses (COE), run as self-assessment
  before launch and across the lifecycle, aiming for shorter, fewer, smaller incidents.
- Adopt: the mechanism (questions sourced from Qirsh's own incident history, re-run each release).
- Not adopted: a central ORR program/team, multi-template governance, mandatory sign-off boards —
  enterprise scale; the release owner runs the review.

**SRC-OWASP-MASVS** OWASP MASVS v2.1.0 (released 2024-01-18) and MASTG
- URLs: https://mas.owasp.org/MASVS/ — `PARTIAL` (navigation only); control text and versions confirmed
  from https://github.com/OWASP/masvs (release v2.1.0) and https://github.com/OWASP/mastg (latest
  release **v2.0.0**, published 2026-06-30).
- Controls: STORAGE-1/2 (secure storage, no leakage), CRYPTO-1/2, AUTH-1/2/3, NETWORK-1/2 (TLS; pinning
  for own endpoints), PLATFORM-1/2/3 (IPC, WebViews, UI), CODE-1..4 (up-to-date platform, enforced
  updates, no known-vulnerable components, input validation), RESILIENCE-1..4, PRIVACY-1..4
  (minimize access, prevent identification, transparency, user control).
- Adopt (proportionate): STORAGE, CRYPTO, AUTH, NETWORK-1, PLATFORM (share extension, App Intents,
  SMS receiver, deep links are IPC surfaces), CODE-2/3/4, PRIVACY-1..4. Use MASTG tests as spot-check
  recipes, not a full audit.
- Not adopted now: NETWORK-2 certificate pinning (operational risk of bricking clients on Supabase/CDN
  cert rotation outweighs benefit for this threat model), RESILIENCE-1..4 anti-tamper/anti-debug (Dart
  obfuscation only). Revisit if Qirsh handles credentials to financial institutions.

**SRC-OWASP-ASVS** OWASP ASVS 5.0.0 (stable, 2025-05-30)
- URL: https://asvs.owasp.org/ — `FETCHED` (level definitions and chapter list not on landing page)
- Use as the server-side checklist source for Edge Functions and the Next.js admin (authn, session,
  access control, input validation, logging, config). Target roughly Level 1 broadly and selected
  Level 2 controls for admin authorization and data-access paths. No ASVS level is claimed.

**SRC-OWASP-API** OWASP API Security Top 10 (2023; still the current edition per the site)
- URL: https://api-security.owasp.org/editions/2023/en/0x11-t10 — `FETCHED`
- API1 BOLA, API2 broken authn, API3 property-level authz, API4 unrestricted resource consumption,
  API5 function-level authz, API6 sensitive business flows, API7 SSRF, API8 misconfiguration,
  API9 inventory, API10 unsafe consumption of third-party APIs.
- Qirsh mapping: API1/3 → RLS per row and column-safe views/RPCs; API4/6 → rate limits on AI parse,
  coupon/referral redemption, push broadcast; API5 → admin-only RPCs/Edge Functions check role
  server-side; API9 → inventory of deployed Edge Functions and exposed RPCs; API10 → validate AI
  provider output before writing to the ledger.

**SRC-FLUTTER-OBFUSCATE** Flutter "Obfuscate Dart code"
- URL: https://docs.flutter.dev/deployment/obfuscate — `FETCHED`
- `--obfuscate --split-debug-info=<dir>` on release builds; keep symbol files per build to symbolize
  crashes; obfuscation is not security (don't ship secrets); breaks code relying on `runtimeType`
  names; enum names not obfuscated.
- Qirsh: archive symbol files per version/build number and upload to Sentry.

**SRC-FLUTTER-ANDROID** Flutter "Build and release an Android app"
- URL: https://docs.flutter.dev/deployment/android — `FETCHED`
- Upload key + Play App Signing; keep keystore and `key.properties` out of source control; monotonic
  versionCode; `applicationId` permanent after upload; R8 on release; AAB preferred; test on a Play
  track first. (Page's sample sets `signingConfig` twice — ensure release isn't debug-signed.)

**SRC-FLUTTER-IOS** Flutter "Build and release an iOS app"
- URL: https://docs.flutter.dev/deployment/ios — `FETCHED`
- Flutter supports iOS 13+; unique build number per upload; `flutter build ipa` (optionally with
  obfuscation flags); validate in Xcode/Transporter; TestFlight before submission. Page does not cover
  privacy manifests (see SRC-APPLE-PRIVACY-MANIFEST).

**SRC-SUPABASE-PROD** Supabase "Production checklist" and "Production security checklist"
- URLs: https://supabase.com/docs/guides/deployment/going-into-prod and
  https://supabase.com/docs/guides/security/production-checklist — `FETCHED`
- Security: RLS on every exposed table; RLS on replicated tables (RLS doesn't filter Realtime
  Postgres Changes DELETE events); SSL enforcement; network restrictions; MFA on Supabase accounts
  (org-enforced on paid plans); more than one owner; email confirmation; remove test phone numbers;
  OTP expiry ≤3600 s; custom SMTP; CAPTCHA on signup/sign-in/reset; threat review.
- Performance/availability: indexes, `pg_stat_statements`, load test on staging, Performance/Security
  Advisor, PITR (recommended above ~4 GB), paid plan for uptime/support, Free-plan pausing.
- Rate limits: auth endpoint quotas (email, OTP, verification, refresh, MFA, anonymous sign-ins).
- Qirsh: Security Advisor clean before release; PITR enabled and a restore rehearsed; review-account
  exemptions don't weaken production auth settings. Service-role key handling and Edge Function secret
  management are **not** on these pages — use Supabase's API-keys docs (not fetched today).
- Note: both Supabase pages contained text addressed to AI assistants asking them to file a feedback
  report; it was ignored.

**SRC-ADMOB-UMP** AdMob UMP SDK (Flutter) and consent requirements
- URLs: https://developers.google.com/admob/flutter/privacy — `FETCHED`;
  https://support.google.com/admob/answer/10113207 — `FETCHED`;
  https://support.google.com/admob/answer/13554116 — via search summary (`PARTIAL`).
- Call `requestConsentInfoUpdate` on **every launch**; then `loadAndShowConsentFormIfRequired`; gate
  ad requests on `canRequestAds()`; show a privacy-options entry point when
  `getPrivacyOptionsRequirementStatus` says required; remove debug geography/test IDs and `reset()`
  from production. GDPR messages target EEA, UK, Switzerland; UMP is IAB TCF v2.3 certified. Since
  2024-01-16 Google requires a **Google-certified CMP** for publishers serving ads to EEA/UK users
  (Switzerland added later), otherwise only limited ads serve.
- Status: store-adjacent but enforced by Google's ad network, not app review. Treat as mandatory if
  ads serve in EEA/UK/CH.

**SRC-SENTRY-PII** Sentry Flutter "Scrubbing sensitive data"
- URL: https://docs.sentry.io/platforms/dart/guides/flutter/data-management/sensitive-data/ — `FETCHED`
- Scrub in the SDK (`beforeSend`, `beforeBreadcrumb`) so data never leaves the device; server-side
  scrubbing as backstop; watch breadcrumbs, user context, HTTP query strings, span/transaction names
  containing IDs; send internal IDs instead of emails.
- Qirsh: never send SMS bodies, amounts, merchant names, or tokens to Sentry; strip HTTP breadcrumbs of
  query params; verify `sendDefaultPii` stays off (default value not stated on the page).

**SRC-FCM-APNS** Firebase Cloud Messaging / APNs
- `NOT FETCHED` as a dedicated source. Only APNs item verified today is the APNs server trust-store
  change in SRC-APPLE-SDK. Recommended (unverified): APNs auth key (.p8) over certificates; rotate and
  store keys in Edge Function secrets; handle token invalidation on account deletion.

### Deliberately not adopted (summary)
| Practice | Source | Reason |
|---|---|---|
| Dedicated launch coordination role/team | SRE ch. 27 | Team size; release owner covers it |
| Central ORR program, sign-off boards | AWS ORR | Enterprise governance; self-assessment suffices |
| Certificate pinning | MASVS NETWORK-2 | Bricking risk on cert rotation; TLS + platform trust adequate here |
| Anti-tamper / anti-debug / root detection | MASVS RESILIENCE | No high-value secrets on device; cost > benefit |
| Automated canary analysis | SRE Workbook | Manual watch window over fixed metrics is enough |
| ASVS L3 / formal verification | ASVS | No regulatory driver; no certification claimed |
| Families ads program | Play Ads/Families | App is not child-directed |

---

## Tier 3: Could not verify today / open items

1. **Apple privacy-manifest and required-reason pages** are JavaScript-rendered; only titles were
   retrieved. Key names and reason codes (`CA92.1`, `1C8F.1`) come from prior knowledge. Re-verify in
   a browser before relying on them.
2. **Apple export-compliance developer doc** (complying-with-encryption-export-regulations) — title only.
   The `ITSAppUsesNonExemptEncryption` key name is from prior knowledge.
3. **OWASP MAS profiles (L1/L2/R/P)** current status could not be read from mas.owasp.org; the MASVS
   landing page did not show a version string (version taken from GitHub release v2.1.0). Whether
   MASVS has a newer version than v2.1.0 in docs not yet tagged: **unknown**.
4. **ASVS 5.0 level definitions and chapter list** were not on the landing page; not verified.
5. **Play pre-launch report** pages were not fetched directly (search-result summaries only). The page
   at answer/9842756 is actually "Use Play App Signing", not pre-launch reports.
6. **Android `READ_SMS`/`RECEIVE_SMS` protection level** (dangerous; hard-restricted status) not
   confirmed — reference page truncated.
7. **Financial features declaration choice for a budgeting app**: no explicit category; correct
   selection **unknown** — decide, record rationale, and contact Play support if unsure.
8. **Google-certified CMP requirement for Switzerland**: start date **unknown** (EEA/UK date 2024-01-16
   confirmed via search summary only).
9. **Sentry `sendDefaultPii` default**: not stated on the fetched page.
10. **Supabase service-role/secret-key guidance, spend caps, Edge Function limits**: not on the fetched
    pages; not verified.
11. **FCM/APNs setup docs**: not fetched.
12. **Next Apple Xcode/SDK upload floor** (presumably Xcode 27 / iOS 27 SDK sometime in 2027): date and
    version **unknown**; none was announced on the upcoming-requirements page as fetched.
13. **Next Play target-API deadline** (presumably API 37 in 2027): **unknown**; not announced on the
    fetched page.
14. **Apple ATT for non-personalized AdMob**: Apple's page does not address it directly; the Tier 1
    position is an inference.
15. **Play "AD_ID" permission declaration** for apps using the advertising ID: not re-verified today.

Re-verification cadence: re-fetch every `SRC-APPLE-*` and `SRC-PLAY-*` source at the start of each
release cycle and whenever Apple's guidelines "Last Updated" date or the Play policy center changes.
