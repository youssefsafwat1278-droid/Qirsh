# App Review notes — DRAFT

> **NOT SUBMITTED — draft for owner review.** Nothing here has been entered in App Store Connect.
> Written 2026-11-17 from the code at the working tree of `release-readiness/v1` (HEAD `d830855e`), by a documentation agent (Claude Opus 5.5). It replaces §5 of `docs/v1-release/V1_APP_STORE_SUBMISSION.md`, which contradicts the build (PROD-02, REL-12).
> Corrected the same day (round 2) only where later facts made a statement stale: the production ad flags (all ON) and the tab-bar defect (RT-01). Nothing else was re-checked against the final candidate.
> Every statement in Part 1 is backed by a code reference in Part 2. Part 2 is **not** for pasting.
> **Closure round (2026-11-17, ops):** Part 1 updated for the owner decisions D-20 — reviewer path by Sign in with Apple, no advertising, all countries, iPhone only, first-run consent with "Agree and enable" / "Continue locally", final deletion. Labels quoted are from `app_en.arb` in the working tree; walk them on the submitted build (MDT-IOS-25).
> The sample messages were written to match formats used in the project's own parser tests; they have **not** been run through a build. Before submission, paste each one into the build being submitted and confirm it produces a transaction.

Reviewer access (V1-015): the build has no password sign-in and an emailed one-time code cannot reach the reviewer, so Part 1 directs the reviewer to **Sign in with Apple with their own Apple ID**, which Apple's guidance allows without demo credentials. No reviewer backdoor exists or is added (D-20, 3.11).

---

## Part 1 — text to paste (English)

**What Qirsh does**
Qirsh is a personal expense tracker for iPhone. Any country can be chosen; bank-message reading has been tested with some banks in Saudi Arabia and Egypt only, and other messages can be entered manually. It turns bank transaction text messages into a private spending record (amount, merchant, date, card) and adds budgets, goals and reports. It does not connect to banks, move money, sell anything or offer financial advice. The app is available in Arabic and English; the language is chosen on the first screen and can be changed in Settings.

iOS does not let apps read SMS. On iPhone, a bank message reaches Qirsh in one of three ways, all started by the user: pasting it into the app, sharing it to Qirsh from the share sheet, or an optional Shortcuts automation that the user builds in Apple's Shortcuts app.

**Signing in**
Sign-in is required. Please use **Sign in with Apple** with any Apple ID; no demo account is needed and a new, empty account is created. The app has no passwords: the other methods shown (Google, and email with a one-time code sent to the inbox) are for existing users. External authentication services: Sign in with Apple, Google Sign-In; accounts are hosted by Supabase.

**Consent (shown once, at first run)**
"Smart Analysis & Cloud Sync" stays off until the user taps **Agree and enable**. That one choice turns on cloud sync and backup, assisted reading of messages by Google Gemini (sanitized text), merchant lookup by Google Places and shared category learning; the screen names each recipient and says the sanitized text is not anonymous. **Continue locally** keeps everything on the device, and everything below still works. Turning it off later (More → Privacy and data → Turn off → **Turn off both**) stops sync and AI together; requests already sent cannot be recalled. The Privacy Policy and Terms open from the app even with Cloud off.

**How to test capture without receiving a bank SMS**

Sample messages (fictional merchant, amount and card):

- English: `Purchase SAR 45.50 at EXAMPLE TEST CAFE card **1234 2026-11-15 12:30`
- Arabic: `شراء بمبلغ 45.50 ر.س لدى مقهى التجربة بطاقة 1234`

*A. Paste a message (fastest)*
1. Copy one sample message above (for example into Notes, then copy it).
2. In Qirsh, on Home, tap **Paste SMS** (or tap **+** → **Paste a bank message**).
3. Paste the text into the field and tap **Analyse messages**.
4. Review the extracted transaction and confirm it. It appears under Transactions and on Home.

*B. Share extension*
1. In Notes, write or paste a sample message (text only — do not include a link; shared links are treated as offers).
2. Select the text, tap **Share**, and choose **إضافة رسالة بنك** ("Add bank message"). Tap **Post** in the sheet.
3. Open Qirsh. The message is imported and appears for review or as a transaction.
4. If you share while signed out, Qirsh shows an alert and saves nothing.

*C. Shortcuts automation (description; optional to test)*
Qirsh provides a Shortcuts action, **Process Bank SMS**. A user can create a personal automation in the Shortcuts app ("When I get a message from <bank sender> → Process Bank SMS with the message text") so that bank messages are recorded without opening Qirsh. The action can also be run manually from the Shortcuts app with the sample text in the "SMS Text" field. It does nothing while the user is signed out. In-app setup help: + → **Automatic capture**.

**Account deletion**
More → **Delete my account and all my data** → **Delete my account and all my data** → **Delete account** → **Delete permanently**. The user confirms their identity with the method they signed in with (Apple, Google, or an emailed code). Deletion starts as soon as it is confirmed and is final (no undo period); some server steps finish in the background within minutes and the app shows when deletion is complete. Separately, "Sign out and erase data" removes the data from this device only.

**Data practices**
Financial data is stored on the device in an encrypted database. With Smart Analysis & Cloud Sync off (the default), no financial data leaves the device. If the user accepts it, transactions and settings sync to the developer's backend (Supabase), sanitized message text is sent to the backend and may be read by Google's Gemini API, merchant names may be sent to Google Places, and crash reports are sent to Sentry. Qirsh does not sell data. **This version shows no ads.** The Google Mobile Ads SDK is still linked in the binary from earlier development, but it is compiled out of use in this build: it is never initialised, no ad is requested and no advertising consent form is shown; no remote setting can turn it on. Privacy policy: https://qirsh.site/privacy.

**Contact**: `<one monitored support address — see Part 3, item 5>`

---

## Part 1 — Arabic version of the two key paragraphs (optional)

**بدون رسائل بنكية حقيقية:** انسخ هذه الرسالة التجريبية: `شراء بمبلغ 45.50 ر.س لدى مقهى التجربة بطاقة 1234` — ثم في قِرش اضغط **لصق رسالة** في الرئيسية، الصق النص، واضغط **حلّل الرسائل**. أو حدّد النص في تطبيق الملاحظات ← مشاركة ← **إضافة رسالة بنك**، ثم افتح قِرش.

**حذف الحساب:** المزيد ← **حذف حسابي وجميع بياناتي** ← حذف الحساب ← تأكيد. الحذف فوري ونهائي.

*(Owner: check the Arabic button labels against `app_ar.arb` before use; only `homeQuickPaste` and `pasteAnalyse` were checked.)*

---

## Part 2 — evidence (private; do not paste)

| Statement | Evidence (`path:line`, working tree 2026-11-17) |
|---|---|
| Sign in with Apple shown on iOS only | `app/lib/features/onboarding/auth_screen.dart:49` (`appleSignInSupported` = iOS), `:332-357` |
| Google shown when `QIRSH_GOOGLE_AUTH_ENABLED` and configured | `app/lib/core/auth/auth_methods_config.dart:7-9`; `auth_screen.dart:194-198`; `app/lib/core/auth/supabase_auth_service.dart:85-89` (iOS: always configured) |
| Email button when `QIRSH_EMAIL_AUTH_ENABLED` | `auth_screen.dart:394-417` |
| "Create account" toggle only if signup flag and (Google or email) | `auth_screen.dart:419` |
| `ios-signed` sets Google, email and signup to true; no `admob` group (ads fail closed there) | `codemagic.yaml` workflow `ios-signed`, `environment.vars` (`QIRSH_GOOGLE_AUTH_ENABLED: "true"`, `QIRSH_EMAIL_AUTH_ENABLED: "true"`, `QIRSH_ALTERNATE_SIGNUP_ENABLED: "true"`) and `environment.groups: [supabase]` — HEAD lines 737-741; working-tree lines 908-911 (the file is being edited concurrently). Build step passes them as `--dart-define` with `:-false` fallbacks |
| When the flags are off | Defines default false → iOS shows Apple only and no create-account toggle (`auth_methods_config.dart:7-9`, `auth_screen.dart:419`) |
| Email is a one-time code, no password | `supabase_auth_service.dart:391` (`signInWithOtp`), `:402-405` (`verifyOTP`, `OtpType.email`); `app/lib/features/onboarding/widgets/email_code_sheet.dart:153` (digits only) |
| Languages ar, en | `app/lib/l10n/app_localizations.dart:95-98`; language screen preselects English `app/lib/features/onboarding/language_screen.dart:23` |
| Paste entry points and labels | `app/lib/features/dashboard/dashboard_screen.dart:1826-1828` (`homeQuickPaste` = "Paste SMS"); `app/lib/features/capture/capture_entry_sheet.dart:33-42` ("Paste a bank message"); `app/lib/l10n/app_en.arb:3338,2454,1488` |
| Paste can save for later analysis | `app/lib/features/capture/manual_paste_screen.dart:263-283,331-332` |
| Share extension name, accepts text and one URL | `app/ios/ShareBankMessage/Info.plist:11-12,31-41` |
| Shared link may be routed to Offers | `app/ios/ShareBankMessage/ShareViewController.swift:14-16` (`.offerLink`); IOS-07 |
| Share while signed out → alert, nothing saved | `ShareViewController.swift:18-25,47-57` |
| Compose sheet with Post | `ShareViewController.swift:5` (`SLComposeServiceViewController`), `:10` (`didSelectPost`) |
| Shortcuts action "Process Bank SMS", parameter "SMS Text", runs without opening the app | `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift:11-20,31-32,594-610` |
| Shortcut does nothing while signed out | `BankMessageShortcuts.swift:68-73` |
| In-app automation help | `capture_entry_sheet.dart` `captureAutomaticTitle` tile; `app_en.arb:3567` |
| Consent sheet text, names Gemini and Places, off by default | `app_en.arb:3094-3100` (`smartConsent*`); `app/lib/core/privacy/consent_authority.dart` ("Fail closed. `unset` and `declined` both deny") |
| Withdrawal stops both together | `app/lib/features/settings/privacy_screen.dart` single consent card (PROD-05); `consentWithdrawBody` |
| More tab = Settings | `app/lib/features/app/app_shell.dart:2207,2531` |
| Deletion path | `app/lib/features/settings/settings_screen.dart:1023-1025` → `/privacy`; `privacy_screen.dart:171-173` → `/delete-account`; `app/lib/features/settings/delete_account_screen.dart:443-453`; labels `app_en.arb:508,1371,3300,3303` |
| Immediate and permanent; reauthentication | `delete_account_screen.dart:37,78` (`immediateDeletionFlowProvider`); `app_en.arb:3299,3302`; email proof `app_en.arb:3781-3782` |
| Policy URL | `app/lib/core/config/legal_urls.dart:6,36` |
| Ads SDK in binary | `app/pubspec.yaml:68` (`google_mobile_ads: 9.0.0`); `app/lib/features/ads/mobile_ads_initializer.dart:56`; `app/ios/Runner/Info.plist:109-110` |
| Support address in app | `app/lib/features/help/help_screen.dart:84`; `settings_screen.dart:1730` (`support@money-companion.app`) |

---

## Part 3 — what the owner must do or decide before these notes are usable

1. **Reviewer access — resolved in Part 1 (Sign in with Apple).** Historical note: No password sign-in exists, so the App Store Connect "password" field has nothing true to hold, and an emailed code cannot reach the reviewer. Options: (a) tell the reviewer to use Sign in with Apple with their own Apple ID and test with the sample messages (no seeded data; seeding then is unnecessary); (b) add a reviewer-only sign-in path — a code change that needs its own security review and decision; (c) provide an inbox the reviewer can read — not recommended. Deleting the review account also needs an emailed code if it was created by email. Whether Supabase can issue a fixed code for one email address was not checked — **UNCONFIRMED**.
2. **If a seeded account is used**, seed only fictional data: 2 accounts (one SAR, one EGP), about 20 transactions over the last 30 days with fictional merchants (for example "EXAMPLE TEST CAFE", "مقهى التجربة"), one budget, one goal, one subscription, and 2–3 items waiting in Smart Inbox. No real names, card numbers or phone numbers.
3. **Ads sentence — resolved by D-20 (no ads; compiled out).** Turn the production ad flags off anyway (RELEASE-PLAN P4) so no future ad-capable build inherits them. Historical note: decide what to say (V1-005, DECISIONS-NEEDED B1). **All eight ad flags are ON at 100% in production** (`evidence/production-comparison.md` §4.3), contrary to the recorded decision D-19. Whether the submitted build shows ads then depends only on whether it carries the AdMob IDs (`ios-signed-release` attaches the `admob` group; `ios-signed` does not). The notes must not say "no ads" unless the flags are off or the build carries no AdMob IDs, and must not say ads are shown unless the policy, consent text and privacy answers cover them.
3a. **Tab bar (RT-01)**: the navigation in Part 1 ("More → …") needs the tab bar. Build 147 hides it after email-code sign-in; the fix (`45ea901a`) is in the candidate and was confirmed on a simulator only. Submit only a build containing it, and walk Part 1 on that build (MDT-IOS-25, MDT-IOS-30).
4. **Backend that must be live during review** (Guideline 2.1): Supabase Auth (Apple, Google, email OTP providers and SMTP), the database and its RLS, Edge Functions used by consent-on paths (`process-ios-sms`, `parse-sms`, `bank-discovery`, `enrich-merchant`, catalog functions, the account-deletion challenge/request functions), the Gemini and Places keys, APNs push, and https://qirsh.site/privacy and /terms. With consent off the reviewer needs only Auth and deletion.
5. **Support contact**: pick one monitored address; the app shows `support@money-companion.app` and the policy shows `business@qirsh.site` (Guideline 1.5).
6. **iPad**: resolved — the device family is iPhone only (`TARGETED_DEVICE_FAMILY = 1`), portrait.
7. **Before pasting:** publish the updated policy (owner, `tools/deploy_site.sh`) only once the V1 app is live, and make sure the reviewer-facing policy does not describe 30-day deletion; confirm the release build enables the sign-in methods named above (RELEASE-PLAN f).

## Part 4 — places where the privacy policy and the code disagree (not papered over)

**2026-11-17 closure round:** rows 1–4 and 6 are addressed in the rewritten `docs/legal/PRIVACY_POLICY.md` (not yet published). Row 5 (one support address) remains an owner action.

| # | Privacy policy (`docs/legal/PRIVACY_POLICY.md`, last updated 2026-11-16) | Code | Issue |
|---|---|---|---|
| 1 | §1 "There is no advertising profile built from your transactions"; §7 lists no ad provider | Google Mobile Ads + UMP are in the binary and are enabled remotely in builds that carry the AdMob identifiers; every ad flag is currently ON in production (`pubspec.yaml:68`; D-18/D-19; `production-comparison.md` §4.3) | V1-005 |
| 2 | §5 deletion is "scheduled for permanent deletion after 30 days. You can undo it…" | Deletion is immediate and permanent (`delete_account_screen.dart:37`; `app_en.arb:3302`) | V1-006 |
| 3 | §3 "Always allowed": catalog updates "requested anonymously" and not consent-gated | Catalog is gated behind Cloud consent (`consent_authority.dart`, `catalog` class); Cloud-off users get no force-update notice; with Cloud on, catalog calls carry the user's session | V1-045 / SEC-05 |
| 4 | §6 retention table has no row for notification logs | Notification logs kept 30 days (`supabase/migrations/0112_capture_notifications_retention.sql`) | SEC-05 |
| 5 | §9 contact `business@qirsh.site` | App shows `support@money-companion.app` | Guideline 1.5 |
| 6 | Consent sheet: "You can withdraw either permission in Settings → Privacy" (`smartConsentBullet3`) | One control withdraws both together | V1-017 (consent copy rather than policy; the policy §4 itself says "one choice") |
| 7 | §5 path "Settings → Privacy & data → Delete my account and all my data" | App path is More → Delete my account and all my data → (Privacy and data) → Delete my account and all my data → Delete account | Wording only; align when §5 is rewritten |
