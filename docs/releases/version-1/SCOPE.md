# Version 1 — proposed scope

Assessed at: the commit recorded in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) (`50957c06` at the time of writing; local branch `release-readiness/v1`, not pushed, built by CI, deployed or submitted). `23499229`, `af675aec`, `c8cef416`, `5583cbea` and `75dab61a` are earlier points on the same line, not alternative candidates.

**Status: PROPOSAL. Nothing in this document has been approved by the owner.** It records what the code at the candidate does and what the specialist audits recommend. Every item under "Open scope decisions" is still the owner's call, and the IN / IN-BUT-OFF / OUT lists change if those decisions go another way.

- Audit baseline: `ab5dc10a` (2026-11-17). 28 commits follow it: 12 round-1 code commits (through `af675aec`), 1 records commit (`d830855e`) and 15 round-2 code commits (through `50957c06`). They fix defects and harden the release workflow; they add no feature, route or flag. Last distributed build: TestFlight 1.0.0 (147) from `b6fc0dad` (internal testing only), which has none of those fixes. No public release exists yet.
- Sources: product-scope audit [`A-product-scope.md`](evidence/audits/A-product-scope.md) (§2.6, §2.7, "Proposed V1 scope"), the other audits in [`evidence/audits/`](evidence/audits/), and the issue register [`ISSUES.md`](ISSUES.md). Owner decisions cited are those in `docs/project/DECISIONS.md` and `docs/v1-release/V1_MASTER_PLAN.md` as quoted by the audits; several of those documents are stale (A §2.8). Decisions found in existing project records are listed in [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md) table A. Production facts are from a read-only comparison ([`evidence/production-comparison.md`](evidence/production-comparison.md)).
- Compiled by: AI agent (release-records compiler), claude-opus-5-5, 2026-11-17; reconciled to `c8cef416` and then to `50957c06` by a release-records editor (same model). No code was run for this document.

## 1. Audience, markets, languages, platforms, devices

| Dimension | What the code / decisions say | Evidence | Unresolved |
|---|---|---|---|
| Audience | Individuals who receive bank SMS in Arabic or English and want automatic expense tracking. Sign-in is mandatory; no guest mode is reachable. | A §2.1, §2.6 | — |
| Markets (store notes) | "Saudi and Egyptian markets" | `docs/v1-release/V1_APP_STORE_SUBMISSION.md:77` via A §2.6 | App Store availability territories not checked (no console access). |
| Markets (app) | Onboarding offers 8 countries: SA, AE, EG, KW, QA, BH, OM, JO. Bundled bank catalog: 12 banks, EG ×8 and SA ×4 only. | `setup_screen.dart:83-92`, `assets/catalog/banks.json` via A §2.6 | **V1-019.** Production `banks` catalog not inspected. |
| Languages | Arabic (template) and English, both complete (2092/2092 keys). Language screen preselects English. | A §2.3, `language_screen.dart:23` | **V1-044** (default language). iOS declares no `CFBundleLocalizations` / `ar.lproj` (H REL-19b), so system dialogs and the store listing may read as English-only. |
| Platform: iOS | In V1 per `V1_MASTER_PLAN.md` and `auth_screen.dart:36` ("V1 is iOS-only by decision"). | A §2.6 | — |
| Platform: Android | **Out of V1, decided by project record, not by this assessment** (`V1_EXTERNAL_BLOCKERS.md` EB-003 and `V1_MASTER_PLAN.md` §1, 2026-09-15; DECISIONS-NEEDED A1). Code-complete for SMS capture, never built as a release, never run on a device, Play declarations not submitted. DECISIONS D-1 still calls Android SMS capture a required core feature. | D §2, AND-01; A §2.6; DECISIONS-NEEDED A1 | V1-004 follows the record; reopens if the owner reopens Android. |
| iOS minimum OS | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` on all targets; `Podfile` says 15.0. No V1 document states the OS floor. | A PROD-17; C §2 "Release config" | OS floor not recorded (PROD-17, S4). |
| iOS device classes | `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone and iPad); iPhone landscape enabled; no orientation lock in Dart. Only iPhone 6.9" screenshots exist. | A PROD-01, C IOS-08, H REL-08 | **V1-014.** |
| Android levels (if in scope) | minSdk 24, targetSdk 36, compileSdk 36 (implicit Flutter defaults). | D §2 | Pinning (AND-12, S4). |
| Sign-in providers | Apple on iOS always; Google and email (one-time code) only if `QIRSH_GOOGLE_AUTH_ENABLED` / `QIRSH_EMAIL_AUTH_ENABLED` are true in Codemagic (default false). `android-release` passes neither, so an Android release has no sign-in method. Email sign-in worked on a simulator against a local stack (J, M); after it the tab bar was missing until `45ea901a` (RT-01, V1-065). | A §2.5, PROD-03/04; H REL-01 | **V1-016** (owner decision B6). Production Codemagic values unknown. |

Assumptions this proposal makes that the owner has not confirmed:
1. V1 is iOS only. This is now settled by project record (DECISIONS-NEEDED A1), not by this assessment.
2. V1 ships to the App Store, not only TestFlight, which needs a pipeline that does not exist yet (V1-009).
3. The target markets are Saudi Arabia and Egypt as the store notes say; the six other onboarding countries are an open question (V1-019).
4. Ads stay off at launch (V1-005). Production currently has every advertising flag ON at 100% (V1-063), contrary to decision D-19; whether ads appear depends on the build carrying AdMob IDs.
5. The production backend has the candidate's migrations: a read-only check found exactly its 134 migrations (V1-002 closed for the ledger; names, not content). Three changed functions still need an owner-authorized deploy: `process-ios-sms`, `parse-sms`, `account-deletion-worker`.

## 2. Feature inventory (release build; inventory taken at `ab5dc10a`, behaviour changes from later commits noted)

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
| Consent: combined Smart Analysis & Cloud Sync grant and combined withdrawal (one control withdraws both; the copy still says separate, V1-017), re-ask, resume banner | reachable | setup step 1; Privacy |
| Capture, iOS: Shortcuts App Intent "Process Bank SMS", Share extension | reachable | C §2 |
| Capture, Android: `RECEIVE_SMS` receiver, share intent | reachable in an Android build; Android is out of V1 by project record | D §2 |
| Manual paste | reachable | `/paste` |
| Cloud sync of ledger and planning entities, conflicts sheet | reachable (compiled on, gated by consent and server capability; the `ledger_*` / `planning_*_sync` flags have no reader) | A §2.4; `app_providers.dart:680-697` |
| Data transfer: CSV / ZIP import and export, PDF | reachable (ZIP is not password-protected) | A §2.7, PROD-06 |
| Learned rules, currency repair, sign-in methods, privacy, delete account | reachable | Settings tiles |
| Legacy encrypted backup restore | reachable only when a legacy backup exists. Since `0f90003f` restore reconciles with cloud sync (V1-020, fixed in code); replace vs merge is owner decision B10, and the confirmation says "replace" under the merge default (V1-070) | `data_transfer_screen.dart:346-352` |
| Encrypted cloud backup enablement (`BackupScreen`) | incomplete (no caller; `/backup` redirects) | A PROD-09 |
| Savings ledger (`/savings`, confirm sheet) | incomplete | A PROD-09 |
| Bank-discovery confirmation sheet | incomplete (stream has no listener) | A PROD-09 |
| Coupons catalog | flagged off by default (`enable_coupons`); **ON in production** | A §2.4; production-comparison §4.3 |
| Merchant offers / personalization | flagged off (`enable_offers_merchants`) | A §2.4 |
| Affiliate click gateway | flagged off (`enable_affiliate_links` + cloud consent) | A §2.4 |
| Referrals | flagged off by default (`enable_referrals`); **ON in production** | A §2.4; production-comparison §4.3 |
| Ads: 6 banner placements + report interstitial (AdMob / UMP SDK linked) | flagged off by default (`enable_banner_ads` + 6 placement flags, `enable_report_ads`); **all ON at 100% in production** (V1-063); AdMob IDs injected only by workflows that attach the `admob` group: `ios-signed-release` and `android-release` attach it, `ios-signed` (which built TestFlight 147) does not | A §2.4; E SEC-01; `codemagic.yaml` |
| UMP privacy-options tile | reachable when UMP requires it | `settings_screen.dart:515-524` |
| Proof-carrying engine | flagged off (shadow mode, records only; `enable_proof_autocommit` cannot be armed server-side) | A §2.7; B DATA-01 |
| Capture pipeline switches: `capture_ai_fallback_enabled`, `capture_import_v3`, `capture_notify_v2`, `local_auto_confirm_v2`, `ai_sender_mapping_auto` | flagged off | A §2.4 |
| `android_capture_ai_enabled` | on by default | A §2.4 |
| Shared category learning | reachable; on by default once Cloud and AI are accepted | E §2.1, SEC-14 |
| Design gallery, sync diagnostics, Developer settings group | dev-only (`kDebugMode`) | A §2.2 |
| `foundation_home_screen.dart` | unreachable (no route, no caller) | A §2.2 |
| Admin panel (Next.js): affiliate, announcements, banks, campaigns, categories, coupons, dashboard, flags, merchants, parser-lab, parsers, push, referrals | reachable for operators; deployment reported loopback-only, not verified. Next.js 14.2.35 with image optimization off (`f6dc5076`); 25 advisories remain (V1-025, owner decision B17) | A §2.7; F BE-07 |
| Backend Edge Functions (33 function directories, plus the `_shared` library) | 28 deployed in production. `process-ios-sms`, `parse-sms` (V1-001, V1-060) and `account-deletion-worker` (V1-062) differ from the candidate and need an owner-authorized deploy. `process-ios-sms` uses its default model `gemini-3.8-flash`. Point-in-time recovery is off and no backups are listed (V1-023) | `supabase/functions/`; production-comparison §1–§4 |

## 3. Proposed lists

Grounded in A "Proposed V1 scope" and the decisions it cites. Each list assumes the assumptions in §1.

### IN (ships enabled) — iOS only
- Onboarding and sign-in: Apple; Google and email only if the owner confirms them (V1-016).
- Arabic and English.
- Consent: combined Smart Analysis & Cloud Sync grant and combined withdrawal (V1-017 copy fix).
- Capture: iOS Shortcuts App Intent and Share extension; manual entry; paste.
- Smart Inbox, categories, learned rules.
- Transactions, accounts, cards; budgets, goals, subscriptions / bills, plans; reports including annual and PDF; achievements.
- Notifications (including the daily reminder).
- Data transfer (CSV / ZIP / PDF).
- Ledger and planning cloud sync behind consent.
- Sign out, delete account, Privacy screen.
- Help and coach marks, What's new, announcements and update banner, force update.
- App lock.
- Shared category learning (default subject to V1-048).

### IN-BUT-OFF (ships dormant, remote-flag gated)
- Coupons, merchant offers and personalization, affiliate tracking (D-14), referrals.
- All 6 banner placements and the report interstitial (D-18/D-19). Shipping the SDK dormant still requires disclosure (V1-005, V1-003).
- Proof gate (shadow, D-13).
- Capture v3, notify v2, auto-confirm v2, AI fallback, sender mapping.

### OUT
- Android / Google Play distribution — out of V1 by project record (DECISIONS-NEEDED A1), not by this assessment.
- Safari extension (D-15).
- Savings ledger UI, encrypted cloud-backup enablement screen, bank-discovery confirmation UI (V1-042; code stays).
- Design gallery and sync diagnostics (debug only); `foundation` screen (dead code).
- iPad and landscape, if V1-014 is decided as iPhone portrait only.

## 4. Open scope decisions for the owner

Each row gives the options the audits set out and the recommendation the audit gave. "No recommendation" means the audit left it to the owner.

| Issue | Decision | Options | Audit recommendation |
|---|---|---|---|
| V1-004 (S1; decided by project record A1, listed for reopening only) | Android in or out of V1 | (a) V1 = iOS only, Android follows after Play approval and device QA; (b) Android in V1, then AND-02..AND-08, REL-01, REL-15 and a device matrix become blockers | D AND-01: no recommendation; record a decision in DECISIONS.md. A proposes OUT, citing V1_MASTER_PLAN. D-1 still says Android SMS capture is a required core feature. |
| V1-014 (S1, re-rated by REV-13) | iPad and iPhone landscape | (a) iPhone only, `TARGETED_DEVICE_FAMILY = 1`, portrait only; (b) keep iPad, add iPad screenshots, run a layout pass | A PROD-01: restricting is the smaller change. All three audits (A, C, H) note that iPad support cannot be dropped after first release, so decide before submission. |
| V1-016 (S2) | Sign-in providers | Apple only; Apple + Google; Apple + Google + email | A PROD-03: record the set in DECISIONS; make the release workflow print the resolved booleans. Apple-only needs no code change. |
| V1-019 (S2) | Supported countries | (a) limit onboarding and App Store territories to SA and EG; (b) keep 8 countries and state limited bank support for six | A PROD-08: no recommendation between (a) and (b); also align App Store territories. |
| V1-005 (S1 for any store build carrying AdMob IDs, FR-05; production ad flags ON, V1-063) | Ads at launch | (a) disclose AdMob/UMP in policy, consent sheet and store labels, keep flags off until disclosures are live; (b) build without the `admob` group or strip the SDK | E SEC-01: either; (b) needs no app change if the workflow is confirmed. H REL-13: add the policy row or remove the SDK. |
| V1-006 (S2) | Account-deletion semantics | Rewrite policy to immediate permanent deletion; or restore a 30-day undo | E SEC-03: rewrite policy §5/§6 to describe immediate deletion. |
| V1-007 (S1, re-rated by REV-12) | Legal pages while Cloud is off | Allowlist exact policy/terms URLs; or bundle the text in-app | E SEC-02: allowlist fixed URLs (smallest). |
| V1-017 (S2) | Consent withdrawal granularity | Change copy to "withdrawn together"; or build AI-only withdrawal | A PROD-05: change copy (smallest). |
| V1-020 (S1, reproduced on a local stack; reconciliation fixed in `0f90003f`) | Restore vs cloud semantics (B10: replace vs merge; V1-070) | Restore replaces cloud too; or restore is local-only and cloud re-enable is blocked or warned | B DATA-02: owner decision; smallest safe step is clearing outboxes in the restore transaction plus an explicit "replace cloud" choice. |
| V1-026 (S2) | Export compliance answer | Keep `ITSAppUsesNonExemptEncryption = false`; or answer the questionnaire for app-level crypto | C IOS-09, H REL-11: owner answers with export-control advice, then align the plist. |
| V1-027 (S2, Android) | Force-stopped Android capture loss | Add OEM battery guidance and document the limitation | D AND-03: guidance + documentation, no manifest change. |
| V1-031 (S3) | Currency-less message | Treat as needs review; or accept account currency | B DATA-05: treat `currencyDefaulted` as review. |
| V1-032 (S3) | Account "current balance" | Hide; label "as of import"; derive from transactions | B DATA-06: no recommendation among the three. |
| V1-036 (S3) | Lock-screen detail | Default hide; or record decision and add policy wording about APNs carrying detail | C IOS-05: privacy-preserving default is hide. |
| V1-037 (S3) | Signed-out Shortcut captures | Keep silent drop; add one-time "sign in to keep recording" notice | C IOS-06: at least a one-time notice and accurate share copy. |
| V1-042 (S3) | Orphaned features | Record OUT; code stays | A PROD-09: record OUT. |
| V1-044 (S3) | Default language | Preselect from device locale; or 'ar' | A PROD-12: device locale, or 'ar' if Arabic-first. |
| V1-045 (S3) | Force-update reach for Cloud-off users; policy wording | Add an anonymous data-free catalog exception; or correct policy §3 | E SEC-05: owner decides. |
| V1-046 (S3) | Backup passphrase minimum | Raise to 10–12 or generate one | E SEC-06: raise. Note: the screen that sets it is orphaned (V1-042), see COVERAGE-MATRIX SEC-04. |
| V1-048 (S3) | Shared category learning default and threshold | Keep; raise threshold; require account age or Apple-only voters; opt-in | E SEC-14, F BE-09: owner confirms; ensure production email confirmation is on. |
| V1-021 / BE-02 | Google sign-up Auth hook | Enable `require_google_enrollment_intent` after `google-enrollment` is deployed; or leave unwired | F BE-02: enable only after functions deploy and only if every client offering Google sign-up calls `google-enrollment`. |
| V1-050 / BE-10 | Engagement webhooks | Leave `engagement_worker_secret` unset for V1; or rework triggers | F BE-10: either; record the decision. |
| V1-056 (S3) | Declined purchases stored before the fix | Leave as a known limitation; or add a one-off review list for matching confirmed rows (changes stored financial data) | REV-05: owner decision. |
| UI/UX owner items (UI-UX-REVIEW.md) | Terms/Privacy links on sign-in (G UX-02); brand green for the "On track" chip (G UX-07 item 1); text-scale cap 1.25x (G UX-09); onboarding step controls (G UX-11); "manual" transaction source (G UX-14); consent-step order and prominence (G UX-15); design consistency (G UX-19, UX-20) | Per finding | G: no single recommendation; UX-09: keep 1.25x as a known limitation unless all primary screens get overflow tests at a higher cap. |
| PROD-14 (S4) | 1.0.0 What's new text | Rewrite as launch highlights | A PROD-14; also G UX-21. |
| PROD-17 (S4) | iOS OS floor | Record iOS 16.0+; align Podfile | A PROD-17. |

## 5. What this proposal does not settle

- Production values of remote flags, Codemagic auth defines and the bank catalog (A §5).
- Whether the production backend matches the repository (V1-002, V1-023).
- UI/UX acceptance: audit G and both fix rounds are recorded in [UI-UX-REVIEW.md](UI-UX-REVIEW.md). The signed-in shell was walked on iOS simulators (J, M); VoiceOver, devices and Android were not exercised.
