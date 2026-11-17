# Product scope and functional coverage audit — Qirsh V1
Model: claude-opus-5-5 (Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: Product scope / functional coverage specialist (AI agent)

## 1. Scope covered / not covered

Covered, by reading code at `ab5dc10a` (no app was run):
- Every directory under `app/lib/features/`, the router (`app/lib/core/router/app_router.dart`), the shell tabs (`features/app/app_shell.dart`), the Settings hub (`features/settings/settings_screen.dart`), remote flag defaults (`app/lib/data/catalog/feature_flag_service.dart`), the bundled seed catalog (`app/assets/catalog/*.json`), compile-time `--dart-define`s (`codemagic.yaml`) and every `fromEnvironment` in `app/lib`.
- Journeys traced in code: language → story → brand → auth → account check → 6-step setup → shell; consent grant and withdraw; capture setup (iOS Shortcut step, Android SMS step); manual paste; delete account; sign out; What's new; force update and update banner; coupons, referrals and ads gating; backup and restore entry points; Help and coach-mark copy.
- Platform and audience facts: iOS deployment target, device family, orientations, Android SDK settings, onboarding country list, seed banks, currencies, store-submission and decision documents.
- Localization: a key diff, placeholder comparison and unused-key scan of `app_ar.arb` / `app_en.arb` (scripts below).

Not covered: runtime behaviour on a simulator or device; production values of Codemagic environment variables; production `feature_flags`, `announcements` and catalog rows; admin-panel runtime; the content of the legal pages served from `LEGAL_BASE_URL`; deep checks of sync, backup crypto, notifications and capture internals (other specialists own those).

## 2. What is established (verified behaviour, with evidence)

### 2.1 Navigation skeleton
- Five shell pages: Home, Transactions (holds the Smart Inbox as a pending filter), Budgets, More (Settings hub) and Analytics (Reports). `features/app/app_shell.dart:2203-2209`, labels at `:2524-2533`.
- Router gates, in order: recovery/restoring → `/`; local-read restriction; language not chosen → `/onboarding/language`; welcome story not seen → `/welcome` (plus `/onboarding/brand`); `needsOnboarding`/`sessionExpired` → `/onboarding/auth`; authenticated users are kept out of `/onboarding/*`. `core/router/app_router.dart:77-137`. `authenticated` is only published once onboarding is complete for that account (`core/session/app_session.dart:3359-3361, 3441-3443, 3014-3015`), so `/onboarding/check` and `/onboarding/setup` are reachable after sign-in. The flow is coherent; there is no redirect loop.
- Sign-in is mandatory. No guest mode is reachable: `continueWithoutAccount*` strings are unused (§2.6).

### 2.2 Dev-only surfaces in a release build
- `/design` (Design Gallery) is registered only `if (kDebugMode)`, `app_router.dart:410-415`.
- `/settings/sync-diagnostics` is registered only if `syncDiagnosticsAvailable()`, which returns `kDebugMode`. `app_router.dart:402-407`, `features/settings/sync_diagnostics_screen.dart:31`.
- The Developer group in Settings and its long-press gesture are both `kDebugMode`-gated. `settings_screen.dart:557-592`.
- `QIRSH_QA_LOCAL_UID` is inert when `kReleaseMode` is set or Supabase is configured. `core/startup/qa_local_identity.dart:9-18`.
- `UMP_DEBUG_FORCE_EEA`, `UMP_DEBUG_TEST_DEVICE` and `REPORT_ADS_TEST_OVERRIDE` resolve to false in a release build. `features/report_ads/report_ads_debug_config.dart:16-30`. None of them is passed by any `codemagic.yaml` workflow.
- `features/foundation/foundation_home_screen.dart` has no route and no caller, so it is dead code and unreachable.
- Result (code inspection): no dev-only surface is reachable in release. One debug-style string is reachable; see PROD-16.

### 2.3 Localization (REPRODUCED by script)
- Command: `python3 -I` script loading both ARB files and diffing non-`@` keys. Result: **ar 2092 / en 2092 keys; nothing missing in either direction; no empty values; no Arabic in en values.**
- Placeholder comparison by ICU argument name: 16 raw mismatches. All 16 are plural or select case bodies picked up by the regex (for example `{عمليتان}`). The argument names (`count`, `days`, `amount`, `currency`, `colour`, `icon`) match in every key. Select keys checked by hand for `cfAccentColourName` and `setCategoryIconName`: they are identical. **No real placeholder mismatch.**
- `recoveryCodeHint` is `XXXX-XXXX-XXXX` in both languages. This is intentional: it is a format mask.
- Unused keys: 268 of 2092 (about 13%) are referenced nowhere in `lib/` outside `l10n/`. This was a token-set scan. Several unused strings contradict current behaviour, for example `privDeleteAccountBody` ("scheduled … after 30 days") and `setUnsyncedSignOutBody` ("signing out will delete it"). They are not reachable today but are a regression trap. See PROD-18.
- The worktree's generated `app_localizations*.dart` files are clean in git. The freshness check is left to CI, so `gen-l10n` was not run here.

### 2.4 Remote flag defaults vs. readers (`feature_flag_service.dart:11-132`)
| Flag | Default | Read by code? | Effect |
|---|---|---|---|
| enable_coupons | false | yes, `coupons_providers.dart:71` | Dashboard "Savings corner" rail and coupon catalog |
| enable_offers_merchants | false | yes, `:129`; `privacy_screen.dart:136` | merchant pages, personalization toggle |
| enable_affiliate_links | false | yes, `:33` (also needs cloud consent) | tracked CTA through `prepare-affiliate-click` |
| enable_referrals | false | yes, `referrals_providers.dart:32` | Settings "Invite friends" tile |
| enable_report_ads | false | yes, `report_ads_providers.dart:32` | report-export interstitial |
| enable_banner_ads + 6 placements | false | yes, `banner_ads_providers.dart:21,50` | 6 mounted `QirshAdBanner` sites |
| enable_proof_autocommit | false | yes, `app_providers.dart:1890` | Proof gate in SHADOW mode (wired, records) |
| capture_ai_fallback_enabled / android_capture_ai_enabled / capture_import_v3 / capture_notify_v2 / local_auto_confirm_v2 / ai_sender_mapping_auto | false / **true** / false… | yes | capture pipeline switches |
| **enable_goals, enable_announcements** | true | **no reader** | dead switch: Goals and Announcements are always on |
| **enable_savings_claims, enable_offers_personalization** | false | **no reader** | dead switch |
| **ledger_dual_write, ledger_pull_sync, ledger_push_sync, smart_inbox_pull_sync, planning_*_sync (5), capture_direct_ledger_write, capture_notify_shared_ids** | false | **no reader** | dead switch: planning sync is compiled ON (`app_providers.dart:680-697`) and gated by consent and capability, not by these flags |

### 2.5 Compile-time defines
- iOS workflows (`codemagic.yaml:97-106, 312-324, 867-879`) pass `QIRSH_GOOGLE_AUTH_ENABLED` (default `false`), `QIRSH_EMAIL_AUTH_ENABLED` (default `false`) and `QIRSH_ALTERNATE_SIGNUP_ENABLED` (default `true`), plus Supabase, Sentry, legal URL and AdMob values.
- `android-release` (`codemagic.yaml:503-512`) passes **none of the three `QIRSH_*_AUTH*` defines**.
- Apple sign-in is shown only on iOS (`features/onboarding/auth_screen.dart:49`). Google and email are gated by the defines (`auth_screen.dart:194-197, 266`).

### 2.6 Audience, platforms, devices (from code and documents)
- **Platform:** V1 is iOS. `docs/v1-release/V1_MASTER_PLAN.md` puts "Google Play submission (owner-deferred)" explicitly out of scope, and `auth_screen.dart:36` says "V1 is iOS-only by decision". DECISIONS D-1 still calls Android SMS capture "a required core feature" for the product, with publication gated on Play approval.
- **iOS:** `IPHONEOS_DEPLOYMENT_TARGET = 16.0` on all 6 build configurations. `ios/Podfile:1` says `platform :ios, '15.0'`. `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone **and iPad**). iPhone landscape is enabled (`Info.plist:88-100`), and no `setPreferredOrientations` call exists in `lib/`. `knownRegions` = en, ar, Base.
- **Android** (not in V1): `minSdk`/`targetSdk` = Flutter defaults (`android/app/build.gradle.kts:112-113`); `RECEIVE_SMS` receiver plus a share intent.
- **Market:** the store reviewer notes say "Saudi and Egyptian markets" (`V1_APP_STORE_SUBMISSION.md:77`). Onboarding offers 8 countries: SA, AE, EG, KW, QA, BH, OM, JO (`setup_screen.dart:83-92`). The bundled seed has 12 banks, **EG ×8 and SA ×4 only** (`assets/catalog/banks.json`), 10 countries including US/GB, and 11 currencies.
- **Languages:** Arabic is the template and English is complete. The language screen preselects **English** (`language_screen.dart:23`).

### 2.7 Feature inventory (status at ab5dc10a, release build)
Status key: R = IMPLEMENTED-AND-REACHABLE, F = IMPLEMENTED-BUT-FLAGGED-OFF, I = INCOMPLETE/orphaned, D = EXPERIMENTAL-OR-DEV-ONLY, P = PLANNED-ONLY.

| Feature dir / surface | Status | Evidence of reachability |
|---|---|---|
| onboarding (language, story, brand, auth, account check, setup ×6, restore prompt, force update, iOS shortcut guide) | R | router `:139-199`; `auth_screen.dart:131-145`; `setup_screen.dart:347-381` |
| dashboard (Home) | R | shell page 0 |
| transactions + Smart Inbox + manual sheet + details | R | shell page 1; `/transaction/:id` |
| budgets | R | shell page 2; `/budgets*` |
| reports / reporting (incl. PDF, annual) | R | shell page 4; `/reports`; data-transfer "PDF report" |
| settings (hub, account, appearance, capture, alerts, security) | R | shell page 3 |
| accounts | R | Settings "Accounts & wallets" → `/accounts` |
| cards | R | Settings "All cards" → `MyCardsScreen.open` → `/cards` |
| subscriptions / bills | R | Settings, Home tiles → `/subscriptions` |
| plans | R | Settings → `PlansScreen.open` |
| goals | R (flag `enable_goals` is dead) | Home tiles → `/goals*` |
| achievements / gamification | R | Settings → `/achievements` |
| help + coach marks | R | Settings → `/help` |
| whats_new | R | Settings → `/whats-new`; post-update sheet |
| announcements + update banner | R (flag `enable_announcements` is dead) | Home/Settings → `/announcements`; `announcement_banner.dart` |
| consent (Smart Analysis & Cloud Sync, re-ask, resume banner) | R | setup step 1; Privacy |
| capture: iOS Shortcut + Share extension; Android SMS; manual paste | R (Android not V1) | setup step 5; Settings capture page; `/paste` |
| planning_sync (cloud sync of planning entities, conflicts sheet) | R (consent-gated, compiled on) | `app_providers.dart:680-697`; `settings_screen.dart:358-370` |
| settings/data_transfer (CSV/ZIP import/export, PDF) | R | Settings → `/data-transfer` |
| settings/learned_rules, currency repair, sign-in methods, delete account, privacy | R | Settings tiles; `/privacy` → `/delete-account` |
| backup: legacy encrypted restore | R only if a legacy backup exists | `data_transfer_screen.dart:346-352` → `/backup/restore` |
| backup: `BackupScreen` (turn on encrypted cloud backup) | I (orphan) | no caller; `/backup` redirects to `/data-transfer` (`app_router.dart:207-211`) |
| coupons catalog | F | `enable_coupons` |
| coupons merchant offers / personalization | F | `enable_offers_merchants` |
| affiliate click gateway | F (now wired; D-14 says unwired) | `coupons_providers.dart:49-68`, `coupon_widgets.dart:472` |
| savings ledger (`/savings`, `SavingsConfirmSheet`) | I (orphan) | no in-app link to `/savings`; `showSavingsConfirmSheet` has no caller; `enable_savings_claims` unread |
| referrals | F | `enable_referrals` |
| ads: banners (6 mounted) + report interstitial | F | flags off; AdMob ids injected only in signed workflows |
| report_ads UMP privacy-options tile | R when UMP requires it | `settings_screen.dart:515-524` |
| bank_discovery confirmation sheet | I (orphan) | `showBankDiscoveryConfirmationSheet` has no caller; `CaptureRuntime.bankDiscoveryRequests` has no listener (`capture_runtime.dart:46-77`) |
| Proof-carrying engine | F (shadow; wired) | `app_providers.dart:1885-1910` |
| design_gallery, sync diagnostics | D (debug only) | §2.2 |
| foundation | dead | no route, no caller |
| Admin (Next.js): affiliate, announcements, banks, campaigns, categories, coupons, dashboard, flags, merchants, parser-lab, parsers, push, referrals | R for operators | `admin/app/(admin)/*` |
| Backend functions (33) | present; deployment not verified here | `supabase/functions/*` |

### 2.8 Where `docs/project/FEATURE_MATRIX.md` (2026-09-02) is now wrong
- "Proof-Carrying engine … ❌ zero callers": it is now wired in shadow mode with a durable recorder (`app_providers.dart:1885-1900`). DECISIONS D-13 says the same stale thing.
- "Affiliate click gateway … ❌ zero callers": it is wired behind `enable_affiliate_links` (`coupons_providers.dart:49`). D-14 is stale.
- "Cloud ledger sync … all OFF" and per-row "planning_*_sync OFF": the sync flags have no readers, and sync is compiled on and consent-gated (`app_providers.dart:680`).
- "Encrypted backup … always on": the enable-backup screen is orphaned. Only legacy restore remains.
- "Authentication (Google/Apple) always on": Google and email are build-define gated (default off). Apple is iOS-only.
- "Banner (transactions) … one placement": 6 placements are mounted (D-19 says five are "not yet mounted").
- "iOS Runtime ❌ every row": TestFlight build 147 exists. Runtime status needs re-measurement, not inheritance.
- Missing rows: What's new, Learned rules, Help/coach marks, Plans, Achievements, Data transfer (CSV/ZIP), Savings (orphan), Bank discovery (orphan), force-update/update banner, consent re-ask.

## 3. Findings

### PROD-01 — iPad and iPhone-landscape are enabled with no product decision, no layout evidence and no iPad screenshots
- Severity: S2 · Class: PRODUCT-DECISION · Platforms: iOS
- User impact: The app installs natively on iPad and rotates to landscape on iPhone. Financial layouts are verified only in portrait phone sizes (`app.dart` text-scale note). App Store Connect requires iPad screenshots for an app that supports iPad. The submission package lists only a 6.9" iPhone set (`V1_APP_STORE_SUBMISSION.md` §7). An iPad review device is also a common review path.
- Evidence: `app/ios/Runner.xcodeproj/project.pbxproj:637,783,838,926,953,980` `TARGETED_DEVICE_FAMILY = "1,2"`; `app/ios/Runner/Info.plist:88-100` (landscape on iPhone, all four on iPad); `grep -rn setPreferredOrientations app/lib` → no result; no iPad decision in `docs/project/DECISIONS.md` or the V1 docs.
- Proposed fix: The owner decides between iPhone-only V1 (`TARGETED_DEVICE_FAMILY = 1` in all targets, portrait-only `UISupportedInterfaceOrientations`) and iPad support (add iPad screenshots and run a layout pass). Restricting is the smaller change. Changing the device family after release is allowed in one direction only: an app cannot later drop iPad for existing iPad users without a new app.
- Verification required after fix: an archive inspection of `UIDeviceFamily`, and a simulator run in landscape plus one iPad run (or confirmation that iPad is absent).

### PROD-02 — Store reviewer notes contradict the shipping app (sign-in methods, language, sign-out wipe, delete path, version)
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: iOS
- User impact: App Review tests what the notes promise. If they find something different, the result is a rejection (Guideline 2.1/2.3) or a misleading listing.
- Evidence (`docs/v1-release/V1_APP_STORE_SUBMISSION.md`):
  - `:80` "Email/password, Sign in with Apple, and Google are all supported". In code, email is a one-time code, not a password (`auth_screen.dart:446-460`). Google and email appear only if `QIRSH_GOOGLE_AUTH_ENABLED` / `QIRSH_EMAIL_AUTH_ENABLED` are true in Codemagic, and both default to `false` (`codemagic.yaml:873-874`). Production values were not visible here.
  - `:78` "the listing declares Arabic only". English is complete (2092/2092 keys), selectable on the first screen and **preselected** (`language_screen.dart:23`). `knownRegions` includes en.
  - `:105` "the local financial database is wiped on sign-out". The code says the opposite: `signOutDataStays` "Your data stays on this device and comes back when you sign in again" (`sign_out_sheet.dart`). The guide's path to erase is a separate "Remove data".
  - `:104` "Settings → account → delete". The actual path is More → Security & privacy → "Delete account" (`settings_screen.dart:1021-1025`, which opens `/privacy`, not the delete screen) → "Delete account and all data" (`privacy_screen.dart:170-175`) → `/delete-account`.
  - `:7` "Version 1.0.0 (40)". The last TestFlight build is 147.
  - `:44` names only two banner flags. Seven banner flags plus the interstitial exist.
- Proposed fix: Rewrite §5 against the build actually submitted, after the owner confirms the Codemagic auth defines (see PROD-03). Documentation only, no code impact.
- Verification required after fix: compare the notes line by line with a TestFlight build.

### PROD-03 — The sign-in provider set for V1 is undecided in the repository and decided by unaudited CI variables
- Severity: S2 · Class: PRODUCT-DECISION / ENV-LIMITATION · Platforms: iOS (Android: see PROD-04)
- User impact: Sign-in is mandatory, and the set of buttons users see depends on two Codemagic variables nobody can read in the repository. If both are unset, iOS shows Apple only. The "Create account" toggle needs Google or email (`auth_screen.dart:419`), so it is also hidden.
- Evidence: `core/auth/auth_methods_config.dart:7-9`; `codemagic.yaml:873-875`; the CODEMAGIC_ENVIRONMENT_VARIABLES doc has no mention (`grep -rn QIRSH_GOOGLE_AUTH_ENABLED docs` → no result).
- Proposed fix: Record the V1 provider set in DECISIONS and make the signed-release workflow print the resolved booleans in its log. No code change is needed if Apple-only is intended.
- Verification required after fix: the Codemagic log of the release build, plus the auth screen on TestFlight.

### PROD-04 — An Android release build would have no sign-in method at all
- Severity: S3 (S1 if Android ships) · Class: CODE-SUPPORTED · Platforms: Android
- User impact: On Android, Apple is hidden (`auth_screen.dart:49`), and `android-release` passes no `QIRSH_*_AUTH*` defines, so Google and email are false. The mandatory auth screen would show no sign-in control, which is a dead end at first run.
- Evidence: `codemagic.yaml:503-512` compared with `:873-875`; `auth_screen.dart:194-197, 332, 395`.
- Proposed fix: Add the three defines to `android-release` before any Play build, or keep the workflow disabled for V1.
- Verification required after fix: an Android build log and an emulator run of the auth screen.

### PROD-05 — The consent copy promises separate withdrawal, but the UI only offers withdrawing both together
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: All
- User impact: Before granting, users are told "You can withdraw either permission in Settings → Privacy". In fact there is one combined "Turn off cloud sync and Smart Analysis?" action that stops both. A user who wants cloud backup and sync without AI analysis cannot have it. This is a material accuracy problem in a consent disclosure.
- Evidence: `app_en.arb` `smartConsentBullet3` (shown by `features/consent/smart_analysis_consent_sheet.dart`); `privacy_screen.dart:105-113` (single `_ConsentManagementCard`); `consentWithdrawBody` "Sync and analysis stop right away, both together". The grant is also bundled: `initialConsentAccept` "Accept cloud sync and smart analysis".
- Proposed fix (smallest): change `smartConsentBullet3` in ar and en to say both are withdrawn together. Alternatively the owner decides to offer AI-only withdrawal. Privacy specialist to confirm against the policy text.
- Verification required after fix: an ARB check plus reading the consent sheet on device.

### PROD-06 — The Help screen says the backup export is encrypted, but the export ZIP is not password-protected
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: All
- User impact: A user who trusts "Export an encrypted copy of your data … your passphrase never leaves it" may store or share the ZIP as if it were protected. The data-transfer screen itself says "The ZIP is not password-protected". The encrypted backup flow is orphaned (PROD-09).
- Evidence: `app_en.arb` `helpBackupBody`, used at `features/help/help_screen.dart:61-62`; `dtxExportNotice` in `data_transfer_screen.dart`.
- Proposed fix: Rewrite `helpBackupBody` (ar and en) to describe the Data transfer export and its lack of encryption.
- Verification required after fix: the Help screen in both languages.

### PROD-07 — Help says the user always confirms before saving and that captures arrive in the Smart Inbox first, but high-confidence parses are auto-confirmed
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: All
- User impact: Expectation mismatch. Transactions appear in history without review, which contradicts the guide.
- Evidence: `helpAddTransactionBody` ("you always confirm before anything is saved") and `helpSmartInboxBody` ("arrive here first"); `domain/usecases/add_transaction_usecase.dart:620` `autoConfirmThreshold = 0.92` and `:1252`; `manual_paste_screen.dart:305` ("If it is already confirmed, open its details").
- Proposed fix: Copy change: "high-confidence messages are recorded directly; others wait in the Smart Inbox for review".
- Verification required after fix: copy review.

### PROD-08 — Supported countries: onboarding offers 8 markets, but the seed bank catalog covers only Saudi Arabia and Egypt
- Severity: S2 · Class: PRODUCT-DECISION · Platforms: All
- User impact: A UAE, Kuwait, Qatar, Bahrain, Oman or Jordan user picks their country and goes through the capture setup, but no bank profile exists in the bundled seed. Recognition would rely on the generic rules and AI (consent-gated), or on banks that may exist only in the production catalog. The store notes target SA and EG only.
- Evidence: `features/onboarding/setup_screen.dart:83-92`; `app/assets/catalog/banks.json` (12 banks: EG ×8, SA ×4); `V1_APP_STORE_SUBMISSION.md:77`. The production catalog was not inspected (ENV-LIMITATION).
- Recommendation: The owner decides between (a) limiting the V1 country choice and App Store availability to SA and EG, or (b) keeping 8 countries and stating "manual entry / limited bank support" for the other six. Also confirm App Store availability territories match.
- Verification required after fix: the onboarding screen plus a production `banks` query (read-only).

### PROD-09 — Orphaned, user-facing features that ship in the binary but cannot be reached
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: All
- User impact: There is no direct user harm, but scope is unclear and copy that refers to these features misleads (PROD-06). Their flags look operable in the admin panel but do nothing.
- Evidence:
  - `features/backup/backup_screen.dart`: no caller; `/backup` → `/data-transfer` (`app_router.dart:207-211`).
  - `/savings` route (`app_router.dart:270-274`): no in-app link; `showSavingsConfirmSheet` (`savings_confirm_sheet.dart:31`) has no caller; `enable_savings_claims` is unread.
  - `features/bank_discovery/bank_discovery_confirmation_sheet.dart:17`: no caller; the `CaptureRuntime.bankDiscoveryRequests` stream has no listener (`capture_runtime.dart:46-77`). Whether an unknown-sender mapping then stays pending forever was not verified (SUSPECTED).
  - `features/foundation/foundation_home_screen.dart`: no route.
- Proposed fix: Record each as OUT for V1. Leave the code (removal is a separate change). Confirm with the capture owner what happens to discovery requests.
- Verification required after fix: n/a (decision); for bank discovery, a test that an unmatched sender reaches a defined state.

### PROD-10 — Dead remote flags shown in the admin panel: flipping them does nothing
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Backend/Admin
- User impact: Operator error. Turning off `enable_goals` or `enable_announcements` in `/flags` as a kill switch does nothing. `planning_*_sync` / `ledger_*` flags look like sync controls but sync is compiled on. In an incident, an operator relying on them gets no effect.
- Evidence: §2.4 table; `feature_flag_service.dart:12, 61, 62, 87-97, 102`; no reader found by `grep -rn "<key>" app/lib`. The seeded rows are in `app/assets/catalog/feature_flags.json`.
- Proposed fix: Mark these keys "no effect / retired" in the admin flags page or remove the rows from the catalog. Update the runbooks so no incident plan depends on them.
- Verification required after fix: admin flags page review.

### PROD-11 — The force-update block ignores the version range on the device, so a cached row can keep blocking an app that was already updated
- Severity: S3 · Class: CODE-SUPPORTED (behaviour SUSPECTED, not run) · Platforms: iOS
- User impact: The user updates as instructed, opens the app and is still blocked. This lasts until the next catalog sync replaces the cached row, and indefinitely if they are offline. The optional update banner already re-checks `targetsVersion` for exactly this reason. The force path does not.
- Evidence: `core/di/app_providers.dart:376-379` (`any(isForceUpdate)`); `data/catalog/catalog_daos.dart:1832-1845` (no version filter) and `:1714-1728` (`targetsVersion` comment explaining the cached-row risk); `features/common/widgets/announcement_banner.dart:32-35` (banner does re-check); `features/app/app_shell.dart` (force-update check runs before the shell renders).
- Proposed fix: `announcements.any((a) => a.isForceUpdate && a.targetsVersion(kAppVersion))` in `hasForceUpdateProvider` and in `ForceUpdateScreen`. This is fully compatible.
- Verification required after fix: a unit test with a cached force row whose `max_app_version` is below the running version.

### PROD-12 — The language screen preselects English for an Arabic-first product
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: All
- User impact: A Saudi or Egyptian user who taps Continue gets English. The listing (PROD-02) says Arabic.
- Evidence: `features/onboarding/language_screen.dart:23` `String _selected = 'en';`.
- Recommendation: Preselect from the device locale (ar → 'ar', else 'en'), or 'ar' if V1 is Arabic-first.
- Verification required after fix: first run on simulators set to Arabic and to English.

### PROD-13 — The "Delete account" row in Settings opens the Privacy screen, not deletion
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: All
- User impact: An extra hop and a mislabelled destination. Deletion is still reachable in-app, which meets App Store 5.1.1(v).
- Evidence: `settings_screen.dart:1021-1025` (`title: l10n.setDeleteAccount`, `onTap: context.push('/privacy')`); `privacy_screen.dart:170-175`.
- Proposed fix: push `/delete-account` directly.
- Verification required after fix: tap-through.

### PROD-14 — What's new for 1.0.0 reads as a beta changelog
- Severity: S4 · Class: PRODUCT-DECISION · Platforms: All
- User impact: First-time public users who open What's new from Settings see "Clearer screens when …", "This What's new page", which describe changes against a beta they never had. Fresh installs do not get the automatic sheet (`whats_new_trigger.dart:46-48`).
- Evidence: `app/assets/whats_new/release_notes.json`.
- Recommendation: Write 1.0.0 notes as launch highlights.

### PROD-15 — Decision and plan documents contradict code (D-13, D-14, D-19 "five not mounted", FEATURE_MATRIX)
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: All
- Evidence: §2.8. Per D-17, a document that contradicts source is a defect.
- Proposed fix: Add dated amendments to D-13, D-14 and D-19, and regenerate FEATURE_MATRIX from §2.7.

### PROD-16 — An English-only diagnostic string is reachable in the release Privacy screen
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: All
- Evidence: `features/settings/privacy_screen.dart:545-550` `Text('freeze: ${ConsentAuthority.egressFreezeTag}')`, shown when egress is frozen. It is not localized and not debug-gated.
- Proposed fix: Gate with `kDebugMode`, or move it into the existing diagnostics/support code.

### PROD-17 — Podfile platform 15.0 vs. deployment target 16.0
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: iOS
- Evidence: `app/ios/Podfile:1` compared with `project.pbxproj` (16.0 ×6). The effective minimum is iOS 16.0, but no V1 document states the supported OS floor.
- Proposed fix: Align the Podfile to 16.0 and record "iOS 16.0+" as the V1 OS floor.

### PROD-18 — 268 unused localization keys, some contradicting current behaviour
- Severity: S4 · Class: REPRODUCED · Platforms: All
- Evidence: token-set scan (§2.3). Examples: `privDeleteAccountBody` (30-day scheduled deletion), `setUnsyncedSignOutBody` (sign-out deletes data), `continueWithoutAccount`, `authBackupFound*`.
- Proposed fix: Prune them after V1, or add an unused-key gate. They are not user-reachable today.

## 4. Coverage rows
| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Onboarding routing | All | language → story → auth → setup → shell, no loop | app_router.dart, app_session.dart | code inspection | PASS | §2.1 | — |
| Language choice | All | default language matches market | language_screen.dart | code inspection | FAIL | :23 | PROD-12 |
| Sign-in providers | iOS | at least one working method; set intended | auth_screen.dart, codemagic.yaml | code inspection | NOT TESTED (env values unknown) | §2.5 | PROD-03 |
| Sign-in providers | Android | at least one method | same | code inspection | FAIL | §2.5 | PROD-04 |
| Consent grant/withdraw copy | All | copy matches controls | consent sheet, privacy_screen | code inspection | FAIL | | PROD-05 |
| Setup steps 0–5 | iOS/Android | each step completable; capture optional | setup_screen.dart | code inspection | PASS | :187-216, 529-711 | — |
| Manual add / paste | All | entry reachable; copy accurate | manual sheet, paste | code inspection | PASS (reach) / FAIL (copy) | | PROD-07 |
| Reports, budgets, goals, bills, plans | All | reachable from nav | shell, settings | code inspection | PASS | §2.7 | — |
| Backup / export | All | copy matches protection | help, data_transfer | code inspection | FAIL | | PROD-06, PROD-09 |
| Cloud sync on/off | All | governed by consent, not dead flags | app_providers.dart:680 | code inspection | PASS (behaviour) / FAIL (operator flags) | | PROD-10 |
| Coupons, referrals, ads | All | off by default, entry points hidden | flag providers | code inspection | PASS | §2.4 | — |
| What's new / update banner / force update | iOS | not blocking after update | announcements | code inspection | FAIL (suspected) | | PROD-11, PROD-14 |
| Account deletion | iOS | reachable in-app | privacy, delete screen | code inspection | PASS (with extra hop) | | PROD-13 |
| Sign out / re-sign-in | All | data retained; copy consistent | sign_out_sheet | code inspection | PASS (code) / FAIL (store notes) | | PROD-02 |
| Dev-only surfaces in release | All | unreachable | router, settings | code inspection | PASS | §2.2 | PROD-16 |
| ARB parity | All | no missing keys/placeholders | app_ar/en.arb | script | PASS | §2.3 | PROD-18 |
| Device family / orientation | iOS | intended & evidenced | pbxproj, Info.plist | code inspection | FAIL | | PROD-01 |

## 5. Could not verify here
- Production Codemagic values of `QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED` and `QIRSH_ALTERNATE_SIGNUP_ENABLED`. Needed: the Codemagic environment group, or the build-147 log.
- Production `feature_flags`, `announcements` and `banks` rows, including whether any banks beyond SA/EG exist remotely. Needed: a read-only production query.
- The runtime behaviour of every journey. No simulator run was made by this specialist (the simulator is owned by audit G).
- The fate of unknown-sender bank-discovery requests (PROD-09).
- App Store Connect state: availability territories, declared languages, iPad screenshot slots.

## 6. Manual device test steps (TestFlight build on iPhone; plus one iPad if PROD-01 keeps iPad)
1. Fresh install with the device in Arabic. Expected: the language screen preselects Arabic (currently English, PROD-12).
2. Continue to auth. Expected: the buttons match the decided provider set (PROD-03); Apple sign-in completes.
3. Setup: pick SA, choose "Continue locally", create an account, enable notifications, follow the Shortcut step, then Finish. Expected: lands on Home and the coach marks appear.
4. Paste a synthetic high-confidence bank message. Expected: note whether it is auto-confirmed (PROD-07 copy).
5. More → Security & privacy → Privacy: grant consent, then withdraw. Expected: one combined withdrawal; compare with the consent sheet text (PROD-05).
6. More → Data transfer → Export ZIP. Expected: the file is not encrypted; compare with Help → Backup (PROD-06).
7. Rotate the iPhone to landscape on Home, Reports and a form. Expected: decide per PROD-01. On an iPad: the app opens natively.
8. Sign out, then sign in again with the same Apple ID. Expected: data still present (contradicts the store notes, PROD-02).
9. Delete the account from More → Security & privacy → Delete account. Expected: lands on Privacy first (PROD-13); deletion completes and returns to the language or auth screen.
10. With a test announcement (staging only) of severity `force_update`, `max_app_version` below the installed version, cached offline. Expected after fix: not blocked (PROD-11).

## Proposed V1 scope (grounded in DECISIONS and the V1 plan)
- **IN (ships enabled), iOS only:** onboarding and auth (Apple, plus Google/email only if the owner confirms PROD-03); Arabic and English; consent (combined Cloud Sync + Smart Analysis); iOS Shortcut and Share-extension capture; manual entry and paste; Smart Inbox; categories and learned rules; transactions, accounts, cards; budgets, goals, subscriptions/bills, plans; reports including annual and PDF; achievements; notifications (daily 22:00 reminder etc.); Data transfer (CSV/ZIP/PDF); planning/ledger cloud sync behind consent; delete account; sign out; Help and coach marks; What's new; announcements and update banner; app lock.
- **IN-BUT-OFF (dormant, remote-flag gated):** coupons, merchant offers and personalization, affiliate tracking (D-14), referrals, all 6 banner placements and the report interstitial (D-18/D-19), Proof gate (shadow, D-13), capture v3 / notify v2 / auto-confirm v2 / AI fallback / sender mapping.
- **OUT:** Android/Play distribution (V1_MASTER_PLAN); Safari extension (D-15); savings ledger UI, encrypted cloud-backup enablement screen and bank-discovery confirmation UI (orphaned, PROD-09); design gallery and sync diagnostics (debug); foundation screen (dead).
- **Needs an owner decision:** PROD-01 (iPad/landscape), PROD-03 (providers), PROD-08 (countries/territories), PROD-12 (default language), PROD-14 (launch notes), plus the iOS OS floor (PROD-17).
