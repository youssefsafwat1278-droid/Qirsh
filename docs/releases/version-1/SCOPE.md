# Version 1 — proposed scope

Assessed at: `23499229` (HEAD of local branch `release-readiness/v1`; not pushed, built by CI, deployed or submitted). The candidate is `af675aec`; its only difference from `23499229` is one updated test expectation.

**Status: PROPOSAL. Nothing in this document has been approved by the owner.** It records what the code at the candidate does and what the specialist audits recommend. Every item under "Open scope decisions" is still the owner's call, and the IN / IN-BUT-OFF / OUT lists change if those decisions go another way.

- Audit baseline: `ab5dc10a` (2026-11-17). Final local commit: `23499229`; the 11 commits in between fix defects and add no feature, route or flag. Last distributed build: TestFlight 1.0.0 (147) from `b6fc0dad` (internal testing only), which has none of those fixes. No public release exists yet.
- Sources: product-scope audit [`A-product-scope.md`](evidence/audits/A-product-scope.md) (§2.6, §2.7, "Proposed V1 scope"), the other audits in [`evidence/audits/`](evidence/audits/), and the issue register [`ISSUES.md`](ISSUES.md). Owner decisions cited are those in `docs/project/DECISIONS.md` and `docs/v1-release/V1_MASTER_PLAN.md` as quoted by the audits; several of those documents are stale (A §2.8).
- Compiled by: AI agent (release-records compiler), claude-opus-5-5, 2026-11-17. No code was run for this document.

## 1. Audience, markets, languages, platforms, devices

| Dimension | What the code / decisions say | Evidence | Unresolved |
|---|---|---|---|
| Audience | Individuals who receive bank SMS in Arabic or English and want automatic expense tracking. Sign-in is mandatory; no guest mode is reachable. | A §2.1, §2.6 | — |
| Markets (store notes) | "Saudi and Egyptian markets" | `docs/v1-release/V1_APP_STORE_SUBMISSION.md:77` via A §2.6 | App Store availability territories not checked (no console access). |
| Markets (app) | Onboarding offers 8 countries: SA, AE, EG, KW, QA, BH, OM, JO. Bundled bank catalog: 12 banks, EG ×8 and SA ×4 only. | `setup_screen.dart:83-92`, `assets/catalog/banks.json` via A §2.6 | **V1-019.** Production `banks` catalog not inspected. |
| Languages | Arabic (template) and English, both complete (2092/2092 keys). Language screen preselects English. | A §2.3, `language_screen.dart:23` | **V1-044** (default language). iOS declares no `CFBundleLocalizations` / `ar.lproj` (H REL-19b), so system dialogs and the store listing may read as English-only. |
| Platform: iOS | In V1 per `V1_MASTER_PLAN.md` and `auth_screen.dart:36` ("V1 is iOS-only by decision"). | A §2.6 | — |
| Platform: Android | Code-complete for SMS capture, never built as a release, never run on a device, Play declarations not submitted. DECISIONS D-1 calls Android SMS capture a required core feature; V1_MASTER_PLAN puts Play submission out of scope. No document says Android was dropped from V1. | D §2, AND-01; A §2.6 | **V1-004.** |
| iOS minimum OS | `IPHONEOS_DEPLOYMENT_TARGET = 16.0` on all targets; `Podfile` says 15.0. No V1 document states the OS floor. | A PROD-17; C §2 "Release config" | OS floor not recorded (PROD-17, S4). |
| iOS device classes | `TARGETED_DEVICE_FAMILY = "1,2"` (iPhone and iPad); iPhone landscape enabled; no orientation lock in Dart. Only iPhone 6.9" screenshots exist. | A PROD-01, C IOS-08, H REL-08 | **V1-014.** |
| Android levels (if in scope) | minSdk 24, targetSdk 36, compileSdk 36 (implicit Flutter defaults). | D §2 | Pinning (AND-12, S4). |
| Sign-in providers | Apple on iOS always; Google and email (one-time code) only if `QIRSH_GOOGLE_AUTH_ENABLED` / `QIRSH_EMAIL_AUTH_ENABLED` are true in Codemagic (default false). `android-release` passes neither, so an Android release has no sign-in method. | A §2.5, PROD-03/04; H REL-01 | **V1-016**, V1-004. Production Codemagic values unknown. |

Assumptions this proposal makes that the owner has not confirmed:
1. V1 is iOS only (V1-004 option a).
2. V1 ships to the App Store, not only TestFlight, which needs a pipeline that does not exist yet (V1-009).
3. The target markets are Saudi Arabia and Egypt as the store notes say; the six other onboarding countries are an open question (V1-019).
4. Ads stay off at launch (V1-005).
5. The production backend will have all repository migrations applied before release (V1-002 says this is currently unknown).

## 2. Feature inventory (release build; inventory taken at `ab5dc10a`, behaviour changes from later commits noted)

Status: **reachable** · **flagged off** (remote flag, default off) · **incomplete** (code ships, no entry point) · **dev-only** (debug builds only) · **unreachable** (dead code). Taken from A §2.7 (code inspection, not run); defaults from `app/lib/data/catalog/feature_flag_service.dart` via A §2.4. Production flag values are unknown.

| Feature | Status | Evidence |
|---|---|---|
| Onboarding: language, welcome story, brand, auth, account check, 6-step setup, restore prompt, force update, iOS Shortcut guide | reachable | A §2.7; `app_router.dart:139-199` |
| Home dashboard | reachable | shell page 0 |
| Transactions, Smart Inbox (pending filter), manual entry sheet, details | reachable. Since `23499229` the manual sheet pre-selects no category (G UX-01). Since `d35fc044`/`668f4d64` a captured message that reports a declined, failed, rejected or cancelled purchase goes to the Smart Inbox instead of being confirmed (V1-001; fixed in code, not closed) | shell page 1; `/transaction/:id` |
| Budgets | reachable | shell page 2 |
| Reports (incl. annual and PDF) | reachable | shell page 4 |
| Settings hub, account, appearance, capture, alerts, security, app lock | reachable | shell page 3 |
| Accounts, cards | reachable | Settings → `/accounts`, `/cards` |
| Subscriptions / bills, plans | reachable | Settings, Home tiles |
| Goals | reachable (`enable_goals` has no reader) | A §2.4, §2.7 |
| Achievements / gamification | reachable | `/achievements` |
| Help and coach marks | reachable | `/help` |
| What's new, announcements, update banner | reachable (`enable_announcements` has no reader) | A §2.7 |
| Consent: combined Smart Analysis & Cloud Sync, re-ask, resume banner | reachable | setup step 1; Privacy |
| Capture, iOS: Shortcuts App Intent "Process Bank SMS", Share extension | reachable | C §2 |
| Capture, Android: `RECEIVE_SMS` receiver, share intent | reachable in an Android build (Android scope undecided) | D §2 |
| Manual paste | reachable | `/paste` |
| Cloud sync of ledger and planning entities, conflicts sheet | reachable (compiled on, gated by consent and server capability; the `ledger_*` / `planning_*_sync` flags have no reader) | A §2.4; `app_providers.dart:680-697` |
| Data transfer: CSV / ZIP import and export, PDF | reachable (ZIP is not password-protected) | A §2.7, PROD-06 |
| Learned rules, currency repair, sign-in methods, privacy, delete account | reachable | Settings tiles |
| Legacy encrypted backup restore | reachable only when a legacy backup exists | `data_transfer_screen.dart:346-352` |
| Encrypted cloud backup enablement (`BackupScreen`) | incomplete (no caller; `/backup` redirects) | A PROD-09 |
| Savings ledger (`/savings`, confirm sheet) | incomplete | A PROD-09 |
| Bank-discovery confirmation sheet | incomplete (stream has no listener) | A PROD-09 |
| Coupons catalog | flagged off (`enable_coupons`) | A §2.4 |
| Merchant offers / personalization | flagged off (`enable_offers_merchants`) | A §2.4 |
| Affiliate click gateway | flagged off (`enable_affiliate_links` + cloud consent) | A §2.4 |
| Referrals | flagged off (`enable_referrals`) | A §2.4 |
| Ads: 6 banner placements + report interstitial (AdMob / UMP SDK linked) | flagged off (`enable_banner_ads` + 6 placement flags, `enable_report_ads`); AdMob IDs injected only by workflows that attach the `admob` group: `ios-signed-release` and `android-release` attach it, `ios-signed` (which built TestFlight 147) does not | A §2.4; E SEC-01; `codemagic.yaml` |
| UMP privacy-options tile | reachable when UMP requires it | `settings_screen.dart:515-524` |
| Proof-carrying engine | flagged off (shadow mode, records only; `enable_proof_autocommit` cannot be armed server-side) | A §2.7; B DATA-01 |
| Capture pipeline switches: `capture_ai_fallback_enabled`, `capture_import_v3`, `capture_notify_v2`, `local_auto_confirm_v2`, `ai_sender_mapping_auto` | flagged off | A §2.4 |
| `android_capture_ai_enabled` | on by default | A §2.4 |
| Shared category learning | reachable; on by default once Cloud and AI are accepted | E §2.1, SEC-14 |
| Design gallery, sync diagnostics, Developer settings group | dev-only (`kDebugMode`) | A §2.2 |
| `foundation_home_screen.dart` | unreachable (no route, no caller) | A §2.2 |
| Admin panel (Next.js): affiliate, announcements, banks, campaigns, categories, coupons, dashboard, flags, merchants, parser-lab, parsers, push, referrals | reachable for operators; deployment reported loopback-only, not verified | A §2.7; F BE-07 |
| Backend Edge Functions (33 function directories, plus the `_shared` library) | present in source; deployed state unknown (V1-002). `process-ios-sms` changed after the baseline and needs a deploy for V1-001 (RELEASE-PLAN step 3a) | `supabase/functions/`; F BE-01 |

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
- Android / Google Play distribution (if V1-004 is decided as option a).
- Safari extension (D-15).
- Savings ledger UI, encrypted cloud-backup enablement screen, bank-discovery confirmation UI (V1-042; code stays).
- Design gallery and sync diagnostics (debug only); `foundation` screen (dead code).
- iPad and landscape, if V1-014 is decided as iPhone portrait only.

## 4. Open scope decisions for the owner

Each row gives the options the audits set out and the recommendation the audit gave. "No recommendation" means the audit left it to the owner.

| Issue | Decision | Options | Audit recommendation |
|---|---|---|---|
| V1-004 (S1) | Android in or out of V1 | (a) V1 = iOS only, Android follows after Play approval and device QA; (b) Android in V1, then AND-02..AND-08, REL-01, REL-15 and a device matrix become blockers | D AND-01: no recommendation; record a decision in DECISIONS.md. A proposes OUT, citing V1_MASTER_PLAN. D-1 still says Android SMS capture is a required core feature. |
| V1-014 (S1, re-rated by REV-13) | iPad and iPhone landscape | (a) iPhone only, `TARGETED_DEVICE_FAMILY = 1`, portrait only; (b) keep iPad, add iPad screenshots, run a layout pass | A PROD-01: restricting is the smaller change. All three audits (A, C, H) note that iPad support cannot be dropped after first release, so decide before submission. |
| V1-016 (S2) | Sign-in providers | Apple only; Apple + Google; Apple + Google + email | A PROD-03: record the set in DECISIONS; make the release workflow print the resolved booleans. Apple-only needs no code change. |
| V1-019 (S2) | Supported countries | (a) limit onboarding and App Store territories to SA and EG; (b) keep 8 countries and state limited bank support for six | A PROD-08: no recommendation between (a) and (b); also align App Store territories. |
| V1-005 (S2; S1 if ads on at launch) | Ads at launch | (a) disclose AdMob/UMP in policy, consent sheet and store labels, keep flags off until disclosures are live; (b) build without the `admob` group or strip the SDK | E SEC-01: either; (b) needs no app change if the workflow is confirmed. H REL-13: add the policy row or remove the SDK. |
| V1-006 (S2) | Account-deletion semantics | Rewrite policy to immediate permanent deletion; or restore a 30-day undo | E SEC-03: rewrite policy §5/§6 to describe immediate deletion. |
| V1-007 (S1, re-rated by REV-12) | Legal pages while Cloud is off | Allowlist exact policy/terms URLs; or bundle the text in-app | E SEC-02: allowlist fixed URLs (smallest). |
| V1-017 (S2) | Consent withdrawal granularity | Change copy to "withdrawn together"; or build AI-only withdrawal | A PROD-05: change copy (smallest). |
| V1-020 (S1 SUSPECTED, re-rated by REV-14) | Restore vs cloud semantics | Restore replaces cloud too; or restore is local-only and cloud re-enable is blocked or warned | B DATA-02: owner decision; smallest safe step is clearing outboxes in the restore transaction plus an explicit "replace cloud" choice. |
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
- UI/UX acceptance: audit G and the fix round are recorded in [UI-UX-REVIEW.md](UI-UX-REVIEW.md). The signed-in shell, VoiceOver, devices and Android were not exercised there.
