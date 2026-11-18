# Version 1 — scope

Assessed at: the candidate **`a157e68e`** ([RELEASE-MANIFEST.md](RELEASE-MANIFEST.md); local branch `release-readiness/v1`, not pushed, built by CI, deployed or submitted).

**Status: the scope questions are decided by the owner** in [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3 (approved 2026-11-17; D-20). This file records what those decisions are and what the code at the candidate does. The owner decided the scope; the owner has not accepted any open defect. Questions still open are in §4 and in [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md) table C.

- In short: **iPhone only; no advertising; all countries; Arabic and English with no preselected language; restore merges; deletion is final; legal pages open with Cloud off; first-run consent; no historical rewrite.**
- Audit baseline: `ab5dc10a` (2026-11-17). Last distributed build: TestFlight 1.0.0 (147) from `b6fc0dad` (internal testing only), which has none of the changes. No public release exists yet.
- Sources: product-scope audit [`A-product-scope.md`](evidence/audits/A-product-scope.md), the closure reports in [`evidence/closure/`](evidence/closure/), the issue register [`ISSUES.md`](ISSUES.md), and production facts from read-only checks ([`evidence/production-comparison.md`](evidence/production-comparison.md)).
- Compiled 2026-11-17 by an AI agent (claude-opus-5-5); brought to round 3 on 2026-11-18 by a records editor (same model). No code was run for this document.

## 1. Audience, markets, languages, platforms, devices

| Dimension | What the code / decisions say | Evidence | Unresolved |
|---|---|---|---|
| Audience | Individuals who receive bank SMS in Arabic or English and want automatic expense tracking. Sign-in is mandatory; no guest mode is reachable. | A §2.1, §2.6 | — |
| Markets | **All countries** (decision 3.7). App Store territories are set in the console (owner); France needs the encryption declaration or exclusion (DECISIONS-NEEDED C1) | brief §3.7; STORE-READINESS | Territories not checked (no console access) |
| Markets (app) | Onboarding offers 249 countries (maintained ISO list). Verified bank coverage: SA and EG only, stated separately from the country choice. 155 storable currencies; 50 recognized in message text | consent closure report; `640562f6` | Build 147 knows 50 currencies (V1-100). Production `banks` catalog not inspected |
| Languages | Arabic and English. First launch asks for a language with none preselected; existing users keep theirs (decision 3.6) | brief §3.6; `640562f6` | iOS declares no `CFBundleLocalizations` / `ar.lproj` (H REL-19b) |
| Platform: iOS | **iPhone** (decision 3.1) | brief §3.1 | — |
| Platform: Android | **Out of V1 by owner decision 3.1.** Android code is kept and must not regress | brief §3.1 | V1-004, V1-027, V1-053 move to the Android release |
| iOS minimum OS | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` on all targets; `Podfile` says 15.0. No V1 document states the OS floor. | A PROD-17; C §2 "Release config" | OS floor not recorded (PROD-17, S4). |
| iOS device classes | **iPhone only, portrait** (decision 3.1): `TARGETED_DEVICE_FAMILY = 1` in all six configurations (`640562f6`). On an iPad the app runs in iPhone compatibility mode | brief §3.1; iOS closure report | Compatibility mode NOT TESTED |
| Android levels (if in scope) | minSdk 24, targetSdk 36, compileSdk 36 (implicit Flutter defaults). | D §2 | Pinning (AND-12, S4). |
| Sign-in providers | **Apple, Google and email one-time code**, as available to existing users (decision 3.11). The store workflow fails unless all three variables are set (`640562f6`). Reviewer uses Sign in with Apple; no backdoor | brief §3.11 | Codemagic values not visible (owner) |

Settled by the owner on 2026-11-17 (formerly assumptions of this file): iOS only (3.1); no ads (3.2); all countries (3.7); sign-in methods kept (3.11). Still assumed: V1 ships to the App Store, which needs the never-run `ios-signed-release` workflow (V1-009, DECISIONS-NEEDED C2). Production has 134 of the candidate's 135 migrations; the package in RELEASE-PLAN deploys one migration and seven functions.

## 2. Feature inventory (release build; inventory taken at `ab5dc10a`, behaviour changes up to `a157e68e` noted)

Status: **reachable** · **flagged off** (remote flag, default off) · **incomplete** (code ships, no entry point) · **dev-only** (debug builds only) · **unreachable** (dead code). Taken from A §2.7 (code inspection, not run); defaults from `app/lib/data/catalog/feature_flag_service.dart` via A §2.4. Production flag values are unknown.

| Feature | Status | Evidence |
|---|---|---|
| Onboarding: language, welcome story, brand, auth, account check, 6-step setup, restore prompt, force update, iOS Shortcut guide | reachable | A §2.7; `app_router.dart:139-199` |
| Home dashboard | reachable | shell page 0 |
| Transactions, Smart Inbox (pending filter), manual entry sheet, details | reachable. Since `23499229` the manual sheet pre-selects no category (G UX-01). Since the ten parser rounds (`d35fc044` … `50957c06`) a captured message that reports a declined, failed, rejected, cancelled or pending purchase goes to the Smart Inbox instead of being confirmed; a server result the device reads in the other direction or with another amount goes to review; a limit, balance or code figure is never the amount; more correct messages wait in the Smart Inbox than before (V1-085) (V1-001; fixed in code, not closed — remaining wrong outcomes V1-072, V1-073, V1-082, V1-083, V1-084; SYSTEM-MAP §2.1) | shell page 1; `/transaction/:id` |
| Budgets | reachable | shell page 2 |
| Reports (incl. annual and PDF) | reachable | shell page 4 |
| Settings hub, account, appearance, capture, alerts, security, app lock | reachable | shell page 3 |
| Accounts, cards | reachable | Settings → `/accounts`, `/cards` |
| Subscriptions / bills, plans | reachable | Settings, Home tiles |
| Goals | reachable (`enable_goals` has no reader) | A §2.4, §2.7 |
| Achievements / gamification | reachable | `/achievements` |
| Help and coach marks | reachable | `/help` |
| What's new, announcements, update banner | reachable (`enable_announcements` has no reader) | A §2.7 |
| Consent: first-run screen with "Agree and enable" and "Continue locally"; one control turns Cloud and AI off together; shared learning only after the activation, existing users asked once (decisions 3.8–3.10) | reachable | `640562f6` |
| Capture, iOS: Shortcuts App Intent "Process Bank SMS", Share extension | reachable | C §2 |
| Capture, Android: `RECEIVE_SMS` receiver, share intent | reachable in an Android build; Android is out of V1 by project record | D §2 |
| Manual paste | reachable | `/paste` |
| Cloud sync of ledger and planning entities, conflicts sheet | reachable (compiled on, gated by consent and server capability; the `ledger_*` / `planning_*_sync` flags have no reader) | A §2.4; `app_providers.dart:680-697` |
| Data transfer: CSV / ZIP import and export, PDF | reachable (ZIP is not password-protected) | A §2.7, PROD-06 |
| Learned rules, currency repair, sign-in methods, privacy, delete account | reachable | Settings tiles |
| Legacy encrypted backup restore | reachable only when a legacy backup exists. **Merges** (decision 3.3); a device with no user data gets a full apply; the confirmation names the case (V1-020, V1-070; limits V1-102) | `640562f6`, `6f771108` |
| Encrypted cloud backup enablement (`BackupScreen`) | incomplete (no caller; `/backup` redirects) | A PROD-09 |
| Savings ledger (`/savings`, confirm sheet) | incomplete | A PROD-09 |
| Bank-discovery confirmation sheet | incomplete (stream has no listener) | A PROD-09 |
| Coupons catalog | flagged off by default (`enable_coupons`); **ON in production** | A §2.4; production-comparison §4.3 |
| Merchant offers / personalization | flagged off (`enable_offers_merchants`) | A §2.4 |
| Affiliate click gateway | flagged off (`enable_affiliate_links` + cloud consent) | A §2.4 |
| Referrals | flagged off by default (`enable_referrals`); **ON in production** | A §2.4; production-comparison §4.3 |
| Ads: 6 banner placements + report interstitial | **compiled out of the V1 build** (decision 3.2; `QIRSH_ADS_ENABLED` off; no remote flag can turn them on). GMA and UMP still linked, never started; network silence NOT TESTED. Production flags still ON until RELEASE-PLAN P4 (V1-063) | `640562f6`; iOS closure report |
| UMP privacy-options tile | not reachable in the V1 build (UMP never started) | `640562f6` |
| Proof-carrying engine | flagged off (shadow mode, records only; `enable_proof_autocommit` cannot be armed server-side) | A §2.7; B DATA-01 |
| Capture pipeline switches: `capture_ai_fallback_enabled`, `capture_import_v3`, `capture_notify_v2`, `local_auto_confirm_v2`, `ai_sender_mapping_auto` | flagged off | A §2.4 |
| `android_capture_ai_enabled` | on by default | A §2.4 |
| Shared category learning | on only with the explicit Cloud/AI activation; a missing preference reads OFF (decision 3.10, orchestrator's reading) | `640562f6` |
| Design gallery, sync diagnostics, Developer settings group | dev-only (`kDebugMode`) | A §2.2 |
| `foundation_home_screen.dart` | unreachable (no route, no caller) | A §2.2 |
| Admin panel (Next.js): affiliate, announcements, banks, campaigns, categories, coupons, dashboard, flags, merchants, parser-lab, parsers, push, referrals | reachable for operators; deployment reported loopback-only, not verified. Next.js 15.5.29; production `npm audit` 0 (V1-025) | A §2.7; F BE-07 |
| Backend Edge Functions (33 function directories, plus the `_shared` library) | 28 deployed in production. Seven functions and one migration are in the owner-approved-only package (RELEASE-PLAN). `process-ios-sms` uses its default model `gemini-3.8-flash`. Point-in-time recovery is off and no backups are listed (V1-023) | `supabase/functions/`; production-comparison §1–§4 |

## 3. Lists (as decided)

### IN (ships enabled) — iPhone only
- Onboarding with language choice (none preselected), all countries, Apple / Google / email sign-in.
- Arabic and English.
- First-run consent ("Agree and enable" / "Continue locally"); combined withdrawal; shared learning with the activation.
- Capture: iOS Shortcuts App Intent and Share extension; manual entry; paste. Signed-out capture fails visibly and keeps nothing.
- Smart Inbox (including "Move to review"), categories, learned rules.
- Transactions, accounts (balances labelled by source and time), cards; budgets, goals, subscriptions / bills, plans; reports including annual and PDF; achievements.
- Notifications with details within the OS preview setting.
- Data transfer (CSV / ZIP / PDF); legacy backup restore by merge.
- Ledger and planning cloud sync behind consent.
- Sign out; delete account (final); Privacy screen; Privacy Policy and Terms reachable with Cloud off.
- Help, What's new, announcements and update banner, force update (Cloud users only).
- App lock.

### IN-BUT-OFF (ships dormant, remote-flag gated)
- Coupons, merchant offers and personalization, affiliate tracking (D-14), referrals. Coupons and referrals are **ON in production** (production-comparison §4.3).
- Proof gate (shadow, D-13).
- Capture v3, notify v2, auto-confirm v2, AI fallback, sender mapping.

### OUT
- Advertising in any form in the V1 build (decision 3.2); the SDKs stay linked but are never started.
- Android / Google Play (decision 3.1); iPad and landscape (decision 3.1).
- Historical re-analysis of stored transactions (decision 3.15).
- Safari extension (D-15).
- Savings ledger UI, encrypted cloud-backup enablement screen, bank-discovery confirmation UI (V1-042; code stays; DECISIONS-NEEDED C3).
- Design gallery and sync diagnostics (debug only); `foundation` screen (dead code).

## 4. Scope questions still open

| Issue | Question | Where |
|---|---|---|
| V1-026 | Export compliance and France | DECISIONS-NEEDED C1 |
| V1-042 | Orphaned features recorded as out | C3 |
| V1-046 | Backup passphrase minimum | C4 |
| V1-085, V1-103 | How much review volume is acceptable | C6 |
| V1-100 | Build 147 and the new currencies | C8 |
| PROD-14, PROD-17, UX-14, UX-19…21 | What's new text, OS floor (16.0 in the project), small UI choices | UI-UX-REVIEW |

## 5. What this file does not settle

- Production values of remote flags beyond the read-only checks, Codemagic variables and the production bank catalog.
- Whether the build behaves as described on a device: nothing in this file was observed on a device.
