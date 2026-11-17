# Version 1 — coverage matrix

Assessed at: `23499229` (HEAD of local branch `release-readiness/v1`; not pushed, built by CI, deployed or submitted). The candidate is `af675aec`; its only difference from `23499229` is one updated test expectation.

Checklist results (Part A) for every item in [`MASTER-CHECKLIST.md`](../../release-process/MASTER-CHECKLIST.md), and feature traceability (Part B) for the Qirsh-specific scenarios. Statuses and rules follow [`SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md) and [`EVIDENCE-TEMPLATE.md`](../../release-process/EVIDENCE-TEMPLATE.md).

- Audit baseline: `ab5dc10a`. Final local commit: `23499229` (11 commits after the baseline: `64e571e5`, `f9c5be75`, `d70ba396`, `2f2c4707`, `ff1fc292`, `7597bb42`, `d35fc044`, `f6dc5076`, `29cb1819`, `668f4d64`, `23499229`). Comparison build: TestFlight 1.0.0 (147) from `b6fc0dad`, which contains none of these commits.
- Change impact: first public release, so every category is rated **High** (MASTER-CHECKLIST §0): every item needs fresh evidence.
- Evidence sources: specialist audits in [`evidence/audits/`](evidence/audits/), cited by letter and section or finding ID: **A** product scope, **B** data integrity, **C** iOS, **D** Android, **E** security & privacy, **F** backend & ops, **G** UI/UX ([UI-UX-REVIEW.md](UI-UX-REVIEW.md) for the fix round), **H** tests, artifact & store, **I** independent review (REV-nn). Issue IDs are from [`ISSUES.md`](ISSUES.md). Gate run results are in TEST-EVIDENCE.md.
- Compiled by: AI agent, release-records compiler, claude-opus-5-5, 2026-11-17, against `ab5dc10a`. Updated by: AI agent, release-records editor, claude-opus-5-5, 2026-11-17, against `23499229`, from the commits, the independent review and the fix-round results stated below. Neither pass ran code.

## Rules applied

1. **PASS** only where the item's acceptance criteria were verified by the method shown, at the final code (`23499229`, or an earlier commit when the relevant files did not change afterwards). Code inspection (I) supports PASS only for criteria that are about code or configuration. Runtime, device, production or store-console criteria checked only by inspection are **NOT TESTED**. A code or CI-configuration defect that was fixed and is covered by a passing regression test may be PASS with method A.
2. A partially verified item is NOT TESTED or FAIL, never PASS. When in doubt, the more conservative status was chosen and the reason is in the evidence cell.
3. An item linked to an open behavior defect or unmet requirement is **FAIL**. Where the linked issue is only a verification gap (a missing test or fixture), the item is NOT TESTED and the cell says `gap:`. An issue marked FIXED on this branch is not open, but its fix still needs the verification the criteria name.
4. NOT TESTED cells name what is missing (device, production access, console access, a deploy, a signed build, a log).
5. Anything whose criteria need a device, production, a store console, a deploy or a signed artifact cannot be PASS here: none of those exists for `23499229`.

Legends used in the table:

- **Method used**: A automated test, script or probe run · I code inspection · R simulator · D physical device · P production read-only (here only public HTTP GETs) · S store console · `—` nothing performed.
- **Environment**: `Mac-I` = local Mac, inspection only · `Mac-T` = local Mac (Flutter 3.47.3 / Dart 3.13.3, Deno 2.9.6, Node 26), targeted test or probe run, no device · `Sim` = local Mac, iOS 26.5 simulator, debug build without backend keys (audit G at `ab5dc10a`; UI fix round on uncommitted changes later committed as `23499229`, per UI-UX-REVIEW.md; launch check at `f6dc5076`) · `Mac-W` = local Mac, HTTP GET to public `qirsh.site` · `—` none. No physical device, Android build, production database, store console, CI build or signed build was used.
- **Reviewer**: `AI:A` … `AI:H` = "AI agent: <specialist role>, claude-opus-5-5" as stated in each report header (A product scope, B data integrity, C iOS, D Android, E security & privacy, F backend & ops, G UI/UX, H tests/artifact/store) · `AI:I` = independent reviewer, claude-opus-5-5 · `AI:FIX` = verification runs made during the fix round, as recorded in the commit messages, UI-UX-REVIEW.md and TEST-EVIDENCE.md · `AI:RC` = AI agent: release-records compiler/editor, claude-opus-5-5 · `AI:ORCH` = orchestrator gate runs.
- **Linked issue**: `V1-nnn` from ISSUES.md. `G UX-nn` is finding nn in UI-UX-REVIEW.md / audit G, not the checklist row with the same number.
- Fix-round runs cited below (all Mac-T, no device): Flutter engine/domain/capture suites 3061 pass; UI-related suites 1102 pass; announcements/onboarding 159 pass; `deno test process-ios-sms` 125 pass; admin tests 191 pass and `next build`; Node contract tests 297 pass / 89 skipped for missing credentials; the six define-gated suites 143 pass with synthetic defines. A full strict gate run on `23499229` is recorded in TEST-EVIDENCE.md and is not restated here.
- Evidence date is 2026-11-17 for every row. Commit is `ab5dc10a` unless the row names another.

## Part A — checklist results

### 1. Scope and change impact

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| SCOPE-01 | APPLICABLE | H | I | NOT TESTED | Baseline, final local commit and comparison build are recorded (above; [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)). Not met yet: no frozen candidate (the release records are still uncommitted), no CI build, and nothing pushed. Re-check at G0. | 2026-11-17 | 23499229 | Mac-I | AI:RC | — |
| SCOPE-02 | APPLICABLE | H | I | PASS | A §2.7 classes every `app/lib/features/` directory, route, flag and admin page from code; A §2.8 lists where FEATURE_MATRIX is stale. The later commits add no feature, route or flag (`git diff --stat ab5dc10a..23499229`). Content problems the inventory surfaced are tracked under SCOPE-03 and ARCH-04. | 2026-11-17 | ab5dc10a | Mac-I | AI:A | — |
| SCOPE-03 | APPLICABLE | H | I | FAIL | [SCOPE.md](SCOPE.md) gives proposed IN / IN-BUT-OFF / OUT lists and the open questions, but no owner decision exists for Android, iPad, providers, countries or ads. | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:RC | V1-004, V1-014, V1-016, V1-019, V1-005 |
| SCOPE-04 | APPLICABLE | H | I | NOT TESTED | A §2.2 and H §2: design gallery, sync diagnostics, Developer group, QA identity and UMP/ads debug overrides are gated by `kDebugMode` / `kReleaseMode`. A release build was not run (R). PROD-16 (S4): an English-only diagnostic string is reachable in Privacy. | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:H | — (PROD-16, S4) |
| SCOPE-05 | APPLICABLE | M | I | FAIL | SCOPE.md §1 writes down countries, languages, OS and devices and lists the unresolved assumptions, but the device classes (iPad) and countries are undecided and the OS floor is not recorded (PROD-17). | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:RC | V1-014, V1-019 |
| SCOPE-06 | APPLICABLE | M | I, A | FAIL | Help no longer calls the ZIP export encrypted or says every capture waits for confirmation (`2f2c4707`; `help_copy_truthfulness_test.dart`). Still contradicting source: reviewer notes (A PROD-02, H REL-21), privacy policy (E SEC-03, SEC-05), Android decision documents (D AND-06), F BE-12. | 2026-11-17 | 23499229 | Mac-I, Mac-T | AI:A, AI:D, AI:E, AI:F, AI:H, AI:FIX | V1-006, V1-015, V1-045 |

### 2. Architecture and dependencies

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| ARCH-01 | APPLICABLE | H | I | NOT TESTED | [SYSTEM-MAP.md](SYSTEM-MAP.md) was compiled from the audits and updated for the later commits and the independent review. It has not been reviewed as a whole by a second reviewer, and it marks unknowns: deployed backend state, Android push transport, and some dependency failure behavior. | 2026-11-17 | 23499229 | Mac-I | AI:RC | — |
| ARCH-02 | APPLICABLE | H | I | NOT TESTED | SYSTEM-MAP §6. Established by I for Gemini (F §2), APNs (F §2) and the iOS upload timeout (C §2). Unknown for Google Places, Sentry, AdMob, Apple revocation and the UI under a Supabase outage. No automated failure tests are cited. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:F, AI:RC | — |
| ARCH-03 | APPLICABLE | M | A | PASS | Strict gate `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` on `af675aec`: arch guard PASS, exit 0 (`evidence/logs/final_ci_gates_run2.summary.txt`) | 2026-11-17 | `af675aec` | Mac-T | AI:ORCH | — |
| ARCH-04 | APPLICABLE | H | I | FAIL | A §2.4 gives the default and the reader for each flag. 13+ remote flags have no reader. Production values (P) are unknown. What switching each flag off does was not tested. | 2026-11-17 | ab5dc10a | Mac-I | AI:A | V1-043 |

### 3. Core functionality

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| CORE-01 | APPLICABLE | C | A, I | FAIL | At `ab5dc10a` a probe through `AddTransactionUseCase` saved two declined purchases as confirmed payments (B DATA-01). Fixed in code on this branch (`d35fc044`, then `668f4d64` after REV-01..04): device parser, AI validator, AI skip, server parser, notification preview rules and both client import paths for server-processed captures treat a declined/failed message as not completed; 69 shared synthetic cases run against device and server code; engine/domain/capture 3061 pass, `process-ios-sms` 125 pass. Not closed: `process-ios-sms` is not deployed, no app build contains the fix, no ingestion path was run on a simulator or device, TestFlight 147 and older stay unprotected (REV-03), and rows stored before the fix stay counted (V1-056). | 2026-11-17 | 668f4d64 | Mac-T | AI:B, AI:I, AI:FIX | V1-001, V1-056 |
| CORE-02 | APPLICABLE | C | I, R | FAIL | A §2.1: routing is coherent (I). Audit G walked language, story, brand, sign-in and setup to the consent step on a simulator (stub auth); onboarding cannot finish without a backend (G UX-22). The iOS provider set depends on Codemagic values nobody could see. An Android release has no sign-in method (A PROD-04, H REL-01). English is preselected. | 2026-11-17 | ab5dc10a | Mac-I, Sim | AI:A, AI:G, AI:H | V1-004, V1-016, V1-044 |
| CORE-03 | APPLICABLE | C | R | NOT TESTED | Audit G added one manual transaction through the real sheet on a simulator (in-memory DB). The sheet changed in `23499229` (no category pre-selected, G UX-01, widget test). Edit, delete and recategorize were not exercised; no device. | 2026-11-17 | 23499229 | Sim | AI:G, AI:RC | — |
| CORE-04 | APPLICABLE | M | — | NOT TESTED | B §1 explicitly skipped goals math and bill/subscription schedule math; A checked reachability only. | 2026-11-17 | ab5dc10a | — | AI:RC | — |
| CORE-05 | APPLICABLE | C | I | NOT TESTED | iOS: sign-out clears the capture owner; expiry keeps it (C §2, I). Android: sign-out and expiry stop capture (D AND-06, I). E: account isolation on device not tested. No A or D run. Related owner decision V1-037. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D, AI:E | — |
| CORE-06 | APPLICABLE | C | I, A | FAIL | Deletion is reachable in-app (A PROD-13, C). The policy says 30-day undo; the app deletes immediately (E SEC-03). Deletion RPCs exist only in `0117` / `20261110124809`; production presence unknown (F BE-01). Tests run: `account-deletion-worker/handler_test.ts` 7/7 (F), `_shared/storage_erasure_test.ts` 12/12 (E). No P or R run. | 2026-11-17 | ab5dc10a | Mac-T | AI:A, AI:E, AI:F | V1-006, V1-002 |
| CORE-07 | APPLICABLE | H | I, A | FAIL | Fixed: Help copy (`2f2c4707`, test); capture-status tile no longer shows success styling before any capture (`23499229`, G UX-16, widget test). Still untrue: consent copy promises separate withdrawal; shared text with a URL may report success. PROD-13 (S4): the "Delete account" row opens Privacy. | 2026-11-17 | 23499229 | Mac-I, Mac-T | AI:A, AI:C, AI:G, AI:FIX | V1-017, V1-038 |
| CORE-08 | APPLICABLE | H | — | NOT TESTED | No audit tested offline use or reconnection. iOS capture queues offline (C, I only). Needs a simulator or device. | 2026-11-17 | ab5dc10a | — | AI:RC | — |

### 4. Data integrity

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| DATA-01 | APPLICABLE | C | I | NOT TESTED | B §2: totals use `amount_minor`, `Money.sum` rejects mixed currencies, capture rejects inexact money (I). Not shown end to end: use of the REAL shadow column and rounding rules. No automated run is cited for this item. | 2026-11-17 | ab5dc10a | Mac-I | AI:B | — |
| DATA-02 | APPLICABLE | C | A, I | FAIL | The spend contract is correct by I (B §2). Declined messages: fixed in code, not closed (see CORE-01); rows stored before the fix stay counted. The account "current balance" is not derived from transactions. | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:I | V1-001, V1-032, V1-056 |
| DATA-03 | APPLICABLE | C | A | FAIL | Device AI grounding now requires a whole number in the message (`d35fc044`; `ai_candidate_validator_test.dart`). Still open: a currency-less message is auto-confirmed in the account currency (B DATA-05); `1،250.00` (Arabic comma) grounds 250, a fragment (I REV-17 probe). | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:I | V1-031, V1-057 |
| DATA-04 | APPLICABLE | C | A | NOT TESTED | Year-less dates no longer land in the future (`d35fc044`; `yearless_date_test.dart`, also run under `TZ=Asia/Riyadh` by AI:I). Digits, separators and currency position were verified by a B probe at `ab5dc10a`; the parser changed in `d35fc044` and `668f4d64`, so that evidence expired (REV-15), and no parser test with those exact strings was found. Needs the B §2 probe re-run or the strings added to the parser suite. | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:I | — (V1-029 FIXED) |
| DATA-05 | APPLICABLE | C | I | NOT TESTED | B §2 (I only): a device duplicate becomes a suspected duplicate for review; the server fingerprints on the exact timestamp; two genuine identical purchases stay distinct. The same message through several paths was not run; no device. Android forged shares (V1-053) apply if Android ships. | 2026-11-17 | ab5dc10a | Mac-I | AI:B | — |
| DATA-06 | APPLICABLE | H | A, I | FAIL | `category_provenance_restore_test.dart` +5 passed; pull and import provenance by I (B §2). A restore followed by cloud sync can overwrite restored rows (suspected; re-rated S1 by REV-14). Re-parse is not covered. | 2026-11-17 | ab5dc10a | Mac-T | AI:B | V1-020 |
| DATA-07 | APPLICABLE | C | A, I | NOT TESTED | `category_provenance_v43_migration_test.dart` +2 passed (v42→v43, crash replay); the whole upgrade runs in one transaction (I). There are no real-shape fixtures for v27–v42 and no device upgrade from a build ≤ 146. | 2026-11-17 | ab5dc10a | Mac-T | AI:B | gap: V1-033 |
| DATA-08 | APPLICABLE | C | I, A | FAIL | Restore validates before mutating, runs in one transaction and rejects newer formats (I); the provenance restore test passed. Restore vs cloud reconciliation is undefined (V1-020, S1 SUSPECTED). Help copy about the ZIP was corrected (`2f2c4707`). No round trip was executed; `backup_restore_roundtrip` is not run by CI (H REL-06). | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:A | V1-020 |
| DATA-09 | APPLICABLE | H | A, I | NOT TESTED | Zone-less timestamps are now read as UTC (`ff1fc292`); `sync_conflict_store_test.dart` passed under `TZ=Asia/Riyadh` (AI:I). That test cannot fail on a UTC host (REV-11), and server date-typed columns were not checked. "Pending edit never overwritten" and "keep-cloud atomic" are by I only (B §4); the criterion asks for A. | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:H, AI:I | — (V1-028 FIXED) |
| DATA-10 | APPLICABLE | C | I | NOT TESTED | iOS: durable writes, quarantine of corrupted segments, 30-day expiry of unbound items (C §2, I); stamped items never expire (IOS-11, S4). Android retention is unbounded (AND-08, inside V1-053). Native tests never run; no device. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D | gap: V1-012 |

### 5. Security

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| SEC-01 | APPLICABLE | C | I | NOT TESTED | E §2.3: Keychain `first_unlock_this_device`, Android encrypted preferences, refresh only through the coordinator (I). D: `SessionKeychain` reviewed, its JVM tests never run (AND-05). Expiry and refresh were not exercised. | 2026-11-17 | ab5dc10a | Mac-I | AI:E, AI:D | — |
| SEC-02 | APPLICABLE | C | I, A (script) | NOT TESTED | E §2.3: every created table has RLS (script + manual); every SECURITY DEFINER function pins `search_path` (script; F lint checked 159). Worker functions authenticate (F §2). EXECUTE grants cannot be fully proven statically (SEC-12, S4). Production ACLs (P) not checked; no runtime RLS gate. | 2026-11-17 | ab5dc10a | Mac-T | AI:E, AI:F | gap: V1-013 |
| SEC-03 | APPLICABLE | C | I | NOT TESTED | Per-uid replica and key (E); owner stamping in both native queues (C, D) — I only. D's 50 Dart tests use a fake native side; H REL-06 calls the Android isolation test a model of the code under test. No device. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D, AI:E | gap: V1-012 |
| SEC-04 | APPLICABLE | H | I, R | NOT TESTED | E §2.3 (I): SQLCipher DB with Keychain key, AES-GCM queues, Argon2id backups, Android backup exclusion. The app-switcher cover is now installed from the scene callbacks (`d70ba396`). An iOS debug simulator build compiled at `f6dc5076`; the app launched, went to the background and returned with its UI intact (iOS 26.5 simulator). The cover inside the app switcher was not observed. It is installed only on entering the background, so the live UI can show while the switcher opens (REV-08). The 6-character passphrase minimum (V1-046) is set in `backup_screen.dart`, which A reports as orphaned (V1-042). | 2026-11-17 | 23499229 | Mac-I, Sim | AI:E, AI:C, AI:I, AI:FIX | — (V1-034 FIXED locally; earlier cover is an owner decision) |
| SEC-05 | APPLICABLE | C | I | NOT TESTED | E §2.3: `git grep` of the tracked tree found no service-role keys, API keys, keystores or real private keys (test PEMs only). The built artifact was not inspected (no store build) and git history was not scanned. | 2026-11-17 | ab5dc10a | Mac-I | AI:E | — (SEC-11, S4) |
| SEC-06 | APPLICABLE | H | I | NOT TESTED | iOS native logs are content-free (C §2, grep); Dart `debugPrint` goes through a redacting sink; Sentry is gated with an allowlist sanitizer and `sendDefaultPii=false` (E). Android Kotlin logging was inspected by no audit; no automated check. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:E | — |
| SEC-07 | APPLICABLE | H | I | FAIL | The server validates AI output (E §2.3). Shared text with a URL may be filed under Offers (C IOS-07). The Android share activity accepts forged bank messages (D AND-07). No data delimiter in the prompt (SEC-10, S4); URL scheme into the router untested (SEC-13, S4). | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D, AI:E | V1-038, V1-053 |
| SEC-08 | APPLICABLE | H | I | FAIL | Android: no cleartext, target 36 (D §2). iOS ATS settings were reported by no audit. Only `ios-signed` asserts the production Supabase URL; `ios-signed-release` checks only that it is non-empty (H REL-03). | 2026-11-17 | ab5dc10a | Mac-I | AI:D, AI:H | V1-009 |
| SEC-09 | APPLICABLE | C | I | PASS | E §2.3 and F §2, independently: middleware covers every page and `/api` route except static assets; every route calls `requireAdmin()`; `admin_users` membership, fail-closed; `send-push-broadcast` verifies JWT + `admin_users` itself. `admin/middleware.ts` is unchanged by the later commits. The dependency advisories are under BUILD-04 (V1-025). | 2026-11-17 | ab5dc10a | Mac-I | AI:E, AI:F | — |
| SEC-10 | APPLICABLE | C | I, A | NOT TESTED | `profile-photos` owner-folder RLS and `storage_erasure_test.ts` 12/12 (E); `backups` storage RLS (I). Production bucket `public` flags (P) not checked. | 2026-11-17 | ab5dc10a | Mac-T | AI:E | — |

### 6. Privacy and consent

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| PRIV-01 | APPLICABLE | C | I | PASS | SYSTEM-MAP §4 lists each consent flag, its default and what it permits, from code (E §2.1). The earlier disagreement on withdrawal is resolved by the code: Privacy withdraws both permissions together (`privacy_screen.dart:421`, unchanged since `ab5dc10a`; A PROD-05); E §2.1's "separately" is superseded. The consent-sheet copy that says otherwise is V1-017, tracked under CORE-07. | 2026-11-17 | ab5dc10a | Mac-I | AI:E, AI:A, AI:RC | — |
| PRIV-02 | APPLICABLE | C | I, A | NOT TESTED | E §2.2 inventory; no path found that sends SMS text, amounts or merchants without cloud consent (I); `ai_endpoint_test.ts` 26/26 (server). No network capture on any platform; `cloud_off_egress_test.dart` not run by CI (H REL-06); Android AdMob may initialise outside the gate (SEC-07, inside V1-053); client gating of `register-device` / `set-device-consent` was not traced. | 2026-11-17 | ab5dc10a | Mac-T | AI:E, AI:H | — |
| PRIV-03 | APPLICABLE | C | I | NOT TESTED | iOS: withdrawal under the queue lock, epoch cancel, `localOnly` stamp (C); Dart: DISABLING record and late-response discard (E); server retries re-check consent (E). A request on the wire in another process is not recallable (≤ 10 s, by design). No A or D run. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:E | — |
| PRIV-04 | APPLICABLE | H | I, A | FAIL | `resolveVerifiedIdentity` and fail-closed consent, `ai_endpoint_test.ts` 26/26 (E). The JWT path reads account-level `user_settings`, so a device whose local consent is off is protected only by its own client. | 2026-11-17 | ab5dc10a | Mac-T | AI:E | V1-047 |
| PRIV-05 | APPLICABLE | C | I, P | FAIL | The policy omits AdMob/UMP, describes 30-day undoable deletion, calls catalog requests anonymous and ungated, and omits notification-log retention (E SEC-01/03/05; H REL-12/13, live page via HTTP GET). | 2026-11-17 | ab5dc10a | Mac-I, Mac-W | AI:E, AI:H | V1-005, V1-006, V1-045 |
| PRIV-06 | APPLICABLE | C | I, A | FAIL | Required-reason API declarations were added to both manifests (`d70ba396`); `ios_privacy_manifest_test.dart` checks that they are present, not that the reason codes are right, and the codes are unconfirmed against Apple's list (REV-09: 85F4.1 is thin). The collected-data list and the Play draft still omit SMS text, profile photo, user ID, product interaction and ads. Console entries were not visible (S not done). | 2026-11-17 | 23499229 | Mac-I, Mac-T | AI:C, AI:D, AI:E, AI:H, AI:I | V1-003 (V1-008 FIXED locally) |
| PRIV-07 | APPLICABLE | C | I, A | FAIL | Retention jobs match the policy for capture content (E §2.3, I); `storage_erasure_test.ts` 12/12. Deletion semantics differ from the policy; production deletion RPCs and cron state unknown. | 2026-11-17 | ab5dc10a | Mac-T | AI:E, AI:F | V1-006, V1-002 |
| PRIV-08 | APPLICABLE | H | I | FAIL | iOS shows amount, merchant and card last-4 on the lock screen by default and in the APNs payload (C IOS-05); the legacy banner is Arabic-only (V1-035). Android capture notifications use private visibility (D, I). No written lock-screen policy; no device check. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D | V1-036 |
| PRIV-09 | APPLICABLE | H | I | FAIL | UMP is the only ad-consent authority and requests are non-personalized (E §2.1, H §2). Ads are not disclosed in the policy, consent sheet or labels. The UMP flow was not run (R). | 2026-11-17 | ab5dc10a | Mac-I | AI:E, AI:H | V1-005 |
| PRIV-10 | APPLICABLE | C | I, A | FAIL | AI requires cloud + AI on client and server (E; test 26/26); Gemini requests carry `store:false`. The Gemini billing tier is unknown, and model and prompt versions are not recorded server-side (F BE-03). | 2026-11-17 | ab5dc10a | Mac-T | AI:E, AI:F | V1-022, V1-058 |

### 7. Failure handling and recovery

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| FAIL-01 | APPLICABLE | H | I | NOT TESTED | iOS upload 8 s timeout and idempotent retry (C); Gemini 12 s timeout with typed retryable errors (F). The user-visible state was not checked; no A or R run. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:F | — |
| FAIL-02 | APPLICABLE | C | I, A | FAIL | The server validator rejects ungrounded amount/merchant, non-allowlisted currency and placeholders (E §2.3); timeout and unavailable are typed retryable; unset key → `upstream_unavailable` (F). Device grounding now requires a whole number (`d35fc044`), and the device validator rejects declined messages (`d35fc044`, `668f4d64`). Still open: Arabic comma as thousands separator (V1-057); the server's non-primary AI path in `parse-sms/money.ts` is not grounded (B DATA-03) and was not changed. No end-to-end automated run for malformed output. | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:E, AI:F, AI:I | V1-057 |
| FAIL-03 | APPLICABLE | C | A, I | NOT TESTED | Migration crash-replay test passed (B); restore is one transaction (I); iOS durable write and per-item ack (C, I). A kill during sync or backup was not tested; no device. | 2026-11-17 | ab5dc10a | Mac-T | AI:B, AI:C | — |
| FAIL-04 | APPLICABLE | H | — | NOT TESTED | No audit covered overlapping capture, sync and user edits, beyond the push-broadcast lease (F) and the cross-process queue lock (C). | 2026-11-17 | ab5dc10a | — | AI:RC | — |
| FAIL-05 | APPLICABLE | H | I, A | NOT TESTED | `parse-sms` request idempotency and per-capture AI budget (F); push claim with `SKIP LOCKED` and collapse id, `send_test.ts` 23/23 (F); `process-ios-sms` fingerprint (B); sync push keyed by `client_request_id` (B). Not exhaustive across endpoints; no client retry test cited. | 2026-11-17 | ab5dc10a | Mac-T | AI:B, AI:F | — |
| FAIL-06 | APPLICABLE | H | I | NOT TESTED | iOS: an undecryptable segment is quarantined and the key is never re-minted over sealed data (C). Android corruption and key loss not tested (D). Corrupted settings not covered. No automated run. | 2026-11-17 | ab5dc10a | Mac-I | AI:C, AI:D | — |

### 8. Performance, capacity and cost

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| PERF-01 | APPLICABLE | M | — | NOT TESTED | Needs a physical device with a populated database; none was available. | 2026-11-17 | ab5dc10a | — | AI:RC | — |
| PERF-02 | APPLICABLE | M | — | NOT TESTED | No audit measured lists or reports at 10,000 transactions. | 2026-11-17 | ab5dc10a | — | AI:RC | — |
| PERF-03 | APPLICABLE | M | I | FAIL | Engagement triggers fire two HTTP calls per transaction row write (inert without the Vault secret); the `0104` backfill takes strong locks on 17 tables (F BE-10/11). Index coverage of client-reachable queries was not audited. | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-050 |
| PERF-04 | APPLICABLE | H | I | FAIL | Per-identity daily caps exist (F §2), but `register-device` issues unlimited anonymous identities, so the caps can be multiplied. | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-022 |
| PERF-05 | APPLICABLE | H | I | FAIL | No global AI ceiling, no provider budget alert, no backend alerting. | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-022, V1-024 |
| PERF-06 | APPLICABLE | M | — | NOT TESTED | Needs a device. iOS background work is bounded by BGTaskScheduler (C, I) but was not measured. | 2026-11-17 | ab5dc10a | — | AI:RC | — |

### 9. UI/UX and accessibility

Source: [UI-UX-REVIEW.md](UI-UX-REVIEW.md) and audit G. Simulator runs used a debug build without a backend, so the signed-in `AppShell` was never reached; nothing was run with VoiceOver, on a device or on Android.

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| UX-01 | APPLICABLE | H | R, A | NOT TESTED | At `ab5dc10a`: 20 screens on iPhone 17 at 1.0x in AR and EN with no overflow; on iPhone SE at 1.25x a title broke mid-word (G UX-06), chips truncated (G UX-08) and transaction details overflowed by 4 px (G UX-10). After the fix: Transactions, Budgets, Reports and Transaction details rendered on an iPhone SE simulator at 1.25x with 0 FlutterErrors; other screens by widget tests at 320×568 and 375×667 only. The 4 px overflow was not reproduced, and its cause was never isolated. Not exercised: `AppShell`, signed-in screens, a device (criterion asks R and D). | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | — (G UX-06, UX-08, UX-10 FIXED) |
| UX-02 | APPLICABLE | H | R, A | NOT TESTED | At `ab5dc10a` RTL mirroring was correct and amounts rendered LTR inside RTL text on every walked surface (G §2). Arabic strings now use Western digits like formatted numbers (`23499229`, G UX-13, widget test). SAR vs «ريال» differs between screens (G UX-20, S4, owner decision). Not re-walked at the final code beyond the four screens above; signed-in screens not reached. | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | — (G UX-20, S4) |
| UX-03 | APPLICABLE | M | R, A | FAIL | Light and dark render coherently on the walked screens (G §2; after images 45, 46, 48 dark, 47 light). Light-theme photo-header subtitle and two faint texts now pass 4.5:1 (computed, widget tests). Still below 4.5:1 in light theme: the budget "On track" chip, 4.02:1 (the passing fix changes the brand green, owner decision), and `textMuted` on `surfaceMuted`, 4.09:1 (no usage identified). Real photo pixels behind header text were not sampled. | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | G UX-07 |
| UX-04 | APPLICABLE | H | R, A | NOT TESTED | Empty states with a call to action on Dashboard, Transactions, Budgets, Goals, Subscriptions and Cards (G §2, simulator). Reports now shows a tip card when empty (G UX-12, after image 48 and widget test); the capture-status tile no longer shows success before any capture (G UX-16, widget test). Loading, error, offline and permission-denied states were not exercised (need a backend or device). | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | — |
| UX-05 | APPLICABLE | M | R, A | FAIL | Text scale is capped at 1.25x app-wide (`app.dart`); iOS accessibility sizes go to about 3x. Temporary probes at 1.6x and 2.0x truncate transaction details and the "Budget history" tab (UI-UX-REVIEW §5); other screens not probed above 1.25x. At 1.25x the four re-run screens rendered without errors on iPhone SE. The cap is kept pending an owner decision. | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | G UX-09 |
| UX-06 | APPLICABLE | M | R, A, I | FAIL | Header actions, planning tabs and the "Change category" pill now reach 44 pt (widget tests). Still below 44 pt: Subscriptions filter chips 93×36, budget-form period chips 88×36, Settings "Edit" 71×36, Settings → Account name 90×26. Contrast: see UX-03. | 2026-11-17 | 23499229 | Sim, Mac-T | AI:G | G UX-05, G UX-07 |
| UX-07 | APPLICABLE | M | A, I | NOT TESTED | The "+" buttons on Transactions and Bills got labels (G UX-03) and 10 close buttons got tooltips (G UX-04), with widget tests (`labeledTapTargetGuideline` on the shared sheet); some close buttons were checked by code only. VoiceOver and Switch Control navigation and focus order were never exercised. | 2026-11-17 | 23499229 | Mac-T, Mac-I | AI:G | — (G UX-03, UX-04 FIXED) |
| UX-08 | APPLICABLE | H | R, I | NOT TESTED | At `ab5dc10a` on a simulator: two Save taps on the add sheet created 1 row; an empty amount showed an error and kept the typed fields (G §2). The add sheet changed in `23499229` (no default category, G UX-01) and the double tap was not re-run. Guards on goal, budget, bill and account forms by code only. | 2026-11-17 | 23499229 | Sim, Mac-I | AI:G | — (G UX-01 FIXED) |
| UX-09 | APPLICABLE | M | I, A | NOT TESTED | Reduce Motion is checked in 16 files (I); the restore illustration now respects it (G UX-17, widget test). Reduce Motion was never turned on in a simulator or device run. | 2026-11-17 | 23499229 | Mac-I, Mac-T | AI:G | — (G UX-17 FIXED) |
| UX-10 | APPLICABLE | M | R (partial) | NOT TESTED | The add-transaction sheet scrolls and Save stays reachable with the keyboard up (G §5, partial). Goal and budget forms with the keyboard on iPhone SE were not checked; safe areas were not assessed separately. | 2026-11-17 | ab5dc10a | Sim | AI:G | — |

### 10. Device and platform compatibility

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| COMP-01 | APPLICABLE | H | — | NOT TESTED | No run on iOS 16 or on a device. The only runs are debug simulator builds on iOS 26.5. The OS floor is not recorded (PROD-17). Android: no build possible here. | 2026-11-17 | 23499229 | — | AI:RC | — |
| COMP-02 | APPLICABLE | M | I | FAIL | iPad and iPhone landscape are enabled without a decision or layout evidence; only iPhone 6.9" screenshots exist (A PROD-01, C IOS-08, H REL-08). Re-rated S1 (REV-13). | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:C, AI:H, AI:I | V1-014 |
| COMP-03 | APPLICABLE | C | I, R | FAIL | iOS: locked-after-first-unlock, before-first-unlock and background drain are designed correctly by I only (C). The app-switcher cover now runs under scenes (`d70ba396`); a simulator launch, background and return worked at `f6dc5076`, but the cover itself was not observed (see SEC-04). Android: SMS arriving while force-stopped are lost silently (D AND-03). If Android is OUT, the iOS part remains NOT TESTED. | 2026-11-17 | 23499229 | Mac-I, Sim | AI:C, AI:D, AI:FIX | V1-027 |
| COMP-04 | APPLICABLE | C | — | NOT TESTED | No device install or upgrade from a prior build; no real v27–v42 fixtures. | 2026-11-17 | ab5dc10a | — | AI:RC | gap: V1-033 |
| COMP-05 | APPLICABLE | H | A | NOT TESTED | Month windows are built from local boundaries (B, I). Zone-less conflict dates read as UTC (`ff1fc292`) and year-less dates no longer roll forward (`d35fc044`); both test files passed under `TZ=Asia/Riyadh` (AI:I). No R run in another zone; plan/goal date-typed columns were not checked (REV-11). | 2026-11-17 | 23499229 | Mac-T | AI:B, AI:H, AI:I | — (V1-028, V1-029 FIXED) |

### 11. Build and supply-chain integrity

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| BUILD-01 | APPLICABLE | C | A | PASS | Strict gate on `af675aec`, machine otherwise idle: 15 mandatory gates passed, 0 failed, 0 tools missing, 0 caller-skipped, exit 0; includes the define-gated stage (`evidence/logs/final_ci_gates_run2.summary.txt`, TEST-EVIDENCE §1). Local run, not CI | 2026-11-17 | `af675aec` | Mac-T | AI:ORCH | — |
| BUILD-02 | APPLICABLE | H | I, A | FAIL | Flutter skip sites are now matched against the manifest (`64e571e5`), and the six define-gated suites run in a mandatory gate stage with synthetic defines (`29cb1819`; 143 pass). Declined-message tests now exist (`d35fc044`, `668f4d64`). Still: the skip check can be bypassed by `testOn`, an excluded tag or an early return (REV-06, residual S3); native tests run in no CI; no backend behavior gate; data removal through startup is not tested in a configured build. | 2026-11-17 | 23499229 | Mac-T | AI:H, AI:B, AI:I, AI:FIX | V1-012, V1-013, V1-054 |
| BUILD-03 | APPLICABLE | H | I, A | FAIL | Lockfiles committed, no git deps, vendored `file_picker` documented (H §2); PROGRESS records the deps-policy gate as PASS. A dev pre-release dependency ships (`liquid_glass_renderer 0.2.0-dev.4`, H REL-19c), and Edge Functions import `esm.sh/@supabase/supabase-js@2` unpinned in 11 files (F BE-12, S4). | 2026-11-17 | ab5dc10a | Mac-T | AI:H, AI:F | V1-052 |
| BUILD-04 | APPLICABLE | H | A | FAIL | Admin moved to `next@14.2.35` (`f9c5be75`), remote image hosts removed, image optimization off (`f6dc5076`); admin tests 191 pass and the build succeeds. `npm audit --omit=dev` at 14.2.35 still lists 25 advisories on `next` (3 critical, 9 high), none fixed on 14.x, plus a high on `postcss` (REV-07). No advisory scan exists for pub packages (H REL-19c). | 2026-11-17 | f6dc5076 | Mac-T | AI:F, AI:H, AI:I, AI:FIX | V1-025 |
| BUILD-05 | APPLICABLE | M | A (script), I | FAIL | No GPL/AGPL code in the mobile artifact (H license scan of 236 packages). There is no in-app licences page, so notice obligations are unmet (H REL-19a). | 2026-11-17 | ab5dc10a | Mac-T | AI:H | V1-052 |
| BUILD-06 | APPLICABLE | C | I | FAIL | No store-bound artifact was built from any commit on this branch. `ios-signed` verifies identity, entitlements and version, but only for internal TestFlight; the App Store path lacks those checks. Android `versionCode` is fixed at 44 (inside V1-004). The export-compliance key is questioned. | 2026-11-17 | 23499229 | Mac-I | AI:C, AI:H | V1-009, V1-026 |
| BUILD-07 | APPLICABLE | C | I, A | FAIL | Debug hooks are release-inert (A, H; I). `APP_VERSION` is now resolved in every workflow and an unresolved version fails the build (`64e571e5`; `codemagic_app_version_contract_test.mjs`). Still: `android-release` passes no auth defines; `xcode: latest` is unpinned; the App Store–capable workflow lacks the `ios-signed` checks. | 2026-11-17 | 23499229 | Mac-T | AI:A, AI:D, AI:H, AI:I | V1-009, V1-004 |
| BUILD-08 | APPLICABLE | H | I | FAIL | `ios-signed` stamps the IPA SHA-256 against the commit (H §2). `ios-signed-release` has no such step; the reviewed-SHA check is self-attested; GitHub Actions has no runs. | 2026-11-17 | ab5dc10a | Mac-I | AI:H | V1-051, V1-009 |
| BUILD-09 | APPLICABLE | M | I, A | FAIL | `APP_VERSION` fixed in CI config (`64e571e5`, contract test); no CI build has run with it. The build number is still not exposed at runtime. | 2026-11-17 | 64e571e5 | Mac-T | AI:H, AI:D, AI:F, AI:I | V1-040 |

### 12. Store submission

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| STORE-01 | APPLICABLE | C | I | FAIL | 5.1.1: the policy cannot be opened in-app while Cloud is off (E SEC-02); iPad is enabled without evidence; the reviewer notes contradict the build. V1-007, V1-014 and V1-015 are now S1 (REV-12, REV-13). Required-reason declarations were added locally (`d70ba396`; codes unconfirmed). App Store Connect was not inspected (S). | 2026-11-17 | 23499229 | Mac-I | AI:A, AI:C, AI:E, AI:H, AI:I | V1-007, V1-014, V1-015 |
| STORE-02 | APPLICABLE | C | I (repo drafts only) | FAIL | Repository drafts: incomplete privacy details, iPhone-only screenshots, export-compliance answer in question, contradicting reviewer notes, no reviewer account. The console state was not inspected (no access). | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:C, AI:H | V1-003, V1-014, V1-015, V1-026 |
| STORE-03 | APPLICABLE only if Android is in V1 (V1-004) | C | I (repo drafts), P | FAIL | Data safety draft is stale, the SMS declaration is not submitted, `AD_ID` is undeclared, and there is no web deletion URL (`/delete-account` returns 404) (D AND-02/10/11, H REL-20). `targetSdk` 36 meets the current rule. Becomes NOT APPLICABLE if the owner records Android as OUT. | 2026-11-17 | ab5dc10a | Mac-I, Mac-W | AI:D, AI:H | V1-004, V1-003 |
| STORE-04 | APPLICABLE | C | I | FAIL | The reviewer account is `NEEDS_USER_ACTION` and the app has no demo or sample-message path (H REL-12). | 2026-11-17 | ab5dc10a | Mac-I | AI:H | V1-015 |
| STORE-05 | APPLICABLE | H | P (HTTP GET) | FAIL | `/privacy`, `/terms`, `/support` return 200 (H §2). The live policy describes 30-day undoable deletion, lags the repository text and has no AdMob row (H REL-12/13/21). | 2026-11-17 | ab5dc10a | Mac-W | AI:H | V1-006, V1-005 |
| STORE-06 | APPLICABLE | M | — | NOT TESTED | Build 147 went to internal TestFlight (PROGRESS). The intended V1 beta testers are not recorded; external TestFlight is impossible from the `ios-signed` export (V1-009). Console not inspected. | 2026-11-17 | ab5dc10a | — | AI:RC | — |

### 13. Deployment and backward compatibility

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| DEPLOY-01 | APPLICABLE | C | I (documents) | FAIL | The migration ledger says applied through 0092; another document says 0100–0102 were applied; nothing records 0103–0117 or the 17 timestamped files. Functions, flags, cron and secret presence are unknown; F §5 checks A–F were not run (no production access). | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-002, V1-023 |
| DEPLOY-02 | APPLICABLE | C | A (script), I | FAIL | `check_migrations.sh` PASS; no destructive DDL in 0100–0117 or the 2026-11 set (F §2). Not rehearsed on a copy or a local stack; `0104` takes strong locks; `0117` has hard preconditions; the unapplied list is unknown. The later commits add no migration. | 2026-11-17 | ab5dc10a | Mac-T | AI:F | V1-050, V1-002 |
| DEPLOY-03 | APPLICABLE | C | I, A | FAIL | Capability discipline and the old-writer design of `category_source` (F §2, I) support compatibility, but no old client was run. Forced update: a cached row is now re-checked against its version range (`7597bb42`, test), but a malformed bound now fails open (REV-10) and builds of the same marketing version cannot be told apart. Declined fix: after the `process-ios-sms` deploy, build 147 and older re-parse a server-rejected capture locally with the old parser and still confirm it (REV-03), so installed builds get no protection from the deploy. | 2026-11-17 | 23499229 | Mac-I, Mac-T | AI:F, AI:A, AI:I | V1-040, V1-001 |
| DEPLOY-04 | APPLICABLE | H | I | FAIL | RELEASE-PLAN (b) now gives an order, including the `process-ios-sms` deploy that V1-001 depends on. Auth hook, ~15 function secrets and 8 Vault entries remain manual and unverified. | 2026-11-17 | 23499229 | Mac-I | AI:F, AI:I, AI:RC | V1-021 |
| DEPLOY-05 | APPLICABLE | H | — | NOT TESTED | RELEASE-PLAN (d) proposes stages; the owner has not confirmed them and no stage has run. | 2026-11-17 | 23499229 | — | AI:RC | — |
| DEPLOY-06 | APPLICABLE | C | I | FAIL | PITR / backup status is unrecorded. The push auto-retry rollback runbook now matches its SQL (`f9c5be75`, document only). Rollback files exist from 0084 on (F lint). Nothing was rehearsed. | 2026-11-17 | 23499229 | Mac-I | AI:F, AI:I | V1-023 |

### 14. Monitoring, support and incident response

| ID | Applicability | Risk | Method used | Status | Evidence | Evidence date | Commit | Environment | Reviewer | Linked issue |
|---|---|---|---|---|---|---|---|---|---|---|
| OPS-01 | APPLICABLE | H | I | FAIL | Sentry exists only in the app and is consent-gated; no backend monitoring or alerting; workers fail with `RAISE LOG` only (F BE-05). | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-024 |
| OPS-02 | APPLICABLE | H | I | NOT TESTED | Generic default thresholds exist in SEVERITY-AND-GATES.md (for example 99% crash-free sessions). No V1 rollout record with thresholds exists yet, and most signals to measure them are absent (OPS-01). | 2026-11-17 | ab5dc10a | Mac-I | AI:RC | — |
| OPS-03 | APPLICABLE | H | — | NOT TESTED | No audit covered it; no named incident owner or contact path is in the V1 records (RELEASE-PLAN (f) blanks). | 2026-11-17 | ab5dc10a | — | AI:RC | — |
| OPS-04 | APPLICABLE | M | P (HTTP GET), I | NOT TESTED | `/support` returns 200 (H §2); the diagnostics journal is a local closed vocabulary (C §2). The in-app report path was not run (R). | 2026-11-17 | ab5dc10a | Mac-I, Mac-W | AI:H, AI:C | — |
| OPS-05 | APPLICABLE | H | I | FAIL | Several remote flags have no reader. The only server-side AI stop is unsetting the provider secret, and that is undocumented (F BE-13, S4). Nothing was tested. | 2026-11-17 | ab5dc10a | Mac-I | AI:A, AI:F | V1-043 |
| OPS-06 | APPLICABLE | C | I (documents) | FAIL | Backup / PITR posture is not recorded in the repository; workspace notes outside the repository say PITR was off in October (F BE-04, not verified). | 2026-11-17 | ab5dc10a | Mac-I | AI:F | V1-023 |

## Part B — feature traceability

Built from the audits' section 4 coverage rows, deduplicated and grouped, and extended for the fix round. Same status rules as Part A. Where a scenario is runtime or device behavior and was checked only by reading code, the method reads **PASS (code inspection only)** or **I consistent** and the result is **NOT TESTED** (REV-16, V1-059). Rows marked "no audit" were covered by no specialist. Evidence is at `ab5dc10a` unless a commit is named.

### B1. Capture → sanitization → parsing → categorization → persistence → reports

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| SMS receipt (Shortcut) | iOS | Capture persisted before any network; visible error when not persisted | `BankMessageShortcuts.perform`, `SharedCaptureStore.enqueue` | I consistent | NOT TESTED | C §4; needs device with Messages automation | — |
| SMS receipt (locked) | iOS | After first unlock: enqueue works; before first unlock: refused visibly | Keychain AfterFirstUnlock, file protection | I consistent | NOT TESTED | C §4 | — |
| SMS receipt (receiver) | Android | Two-key rule: permission granted but opt-in off → nothing read; only OS can deliver | `SmsCaptureReceiver.kt:39`, manifest `BROADCAST_SMS` | I consistent + Dart tests (fake native, +50) | NOT TESTED | D §4; no device | V1-004 |
| Share capture | iOS | Empty or refused share never reported as saved | `ShareViewController` | I consistent | NOT TESTED | C §4 | — |
| Sanitization guard | iOS | Raw text never uploaded; missing sanitizer throws | `BankMessageShortcuts.swift:779-783` | PASS (code inspection only) | NOT TESTED | C §2: the guard is present in code; not run | — |
| Sanitization quality | All | Card, account, phone numbers and codes removed before any upload | Dart and native sanitizers | — | NOT TESTED | no audit verified sanitizer output; `sms_sanitizer_test` exists (H inventory) | — |
| Local parsing: digits | All | `١٬٢٣٤٫٥٠ ريال`, `SAR 1,234.50`, `1,234.50 SAR` → 1234.50 SAR | `parser_engine.dart` | A (parser probe at `ab5dc10a`) | NOT TESTED | B §2, §4 passed at `ab5dc10a`; evidence expired when the parser changed in `d35fc044`/`668f4d64` (REV-15); no current test with these strings found | — |
| Local parsing: European decimal | All | `EUR 1.234,50` not mis-confirmed | parser + `local_validity` | A (probe at `ab5dc10a`) | NOT TESTED | B §4 (routed to review at `ab5dc10a`); expired as above | — |
| Local parsing: year-less date | All | `31/12` processed in a later year lands in the past year | `parser_engine.dart` | A | PASS | `d35fc044`: `yearless_date_test.dart`; passed under `TZ=Asia/Riyadh` (AI:I); engine suite 3061 pass after the fixes | V1-029 (FIXED) |
| Date boundaries | All | Month and day windows built from local boundaries, half-open | dashboard / repositories | PASS (code inspection only) | NOT TESTED | B §2 (code) | — |
| Declined: end to end | All | A declined or failed purchase never counts as spend, through every ingestion path, on installed builds | parser, AI path, `process-ios-sms`, import paths | A (unit tests), I | FAIL | Fixed in code (`d35fc044`, `668f4d64`) but: function not deployed, no app build with the fix, no simulator or device run, TestFlight 147 and older unprotected (REV-03) | V1-001 |
| Declined: device parse | All | Declined/failed/rejected/cancelled message → not completed → Smart Inbox, never confirmed; credit only when it is the message's own completed action; cue in merchant name or advisory footer does not divert a real purchase | `transaction_state_cues.dart`, `parser_engine.dart` | A | PASS | `declined_transaction_test.dart`, `declined_state_cues_table_test.dart` (69 shared synthetic cases: review / payment / credit); engine suite 3061 pass. Synthetic wordings only: not checked against real bank templates | V1-001 (code part) |
| Declined: AI skip and AI validator | All | A declined message is not sent to AI; an AI candidate for it is rejected | `add_transaction_usecase.dart`, `ai_candidate_validator.dart` | A | PASS | `ai_candidate_validator_test.dart`, `declined_transaction_test.dart` (`d35fc044`, `668f4d64`) | V1-001 (code part) |
| Declined: server parser (repository code) | Backend | `process-ios-sms` rejects a declined message; same cue lists and rule as the device | `process-ios-sms/parse.ts`, `parser_rules.json`, `declined_cases.json` | A | PASS | `deno test process-ios-sms` 125 pass; the same 69 cases; `transaction_state_cues_drift_test.dart` checks the lists match | V1-001 (code part) |
| Declined: server parser (deployed) | Backend | Production function rejects a declined message | deployed `process-ios-sms` | — | NOT TESTED | Not deployed; deploy is an owner-authorized step in RELEASE-PLAN (b) step 3 | V1-001 |
| Declined: client import of server results | iOS | A capture the server marked `processed` is still checked; a declined one goes to Smart Inbox (both import paths) | `validated_capture.dart` (`validateCaptureCandidate`), `capture_sync_service.dart` | A | PASS | `capture_import_service_test.dart`, `capture_sync_service_test.dart` (`668f4d64`). Applies only to builds containing `668f4d64` | V1-001 (code part) |
| Declined: notification preview | iOS | The capture banner does not present a declined purchase as a purchase | `app/assets/catalog/parser_rules.json` `ignoreKeywords`; Swift `PreviewParser`; Dart `shared_preview_parser.dart` | A (drift test on the lists), I | NOT TESTED | Cues added to the preview ignore list (`668f4d64`); the Swift preview code was not changed or run (substring match, so a merchant name containing a cue also gets the generic banner, I). Needs a device | V1-001 |
| Declined: rows stored before the fix | All | Existing confirmed rows from declined messages | — | I | FAIL | No migration or review list (REV-05) | V1-056 |
| Refunds, transfers | All | Refund nets expense; transfer and unknown excluded; only confirmed counts | `financial_semantics.dart` | PASS (code inspection only) | NOT TESTED | B §4 | — |
| Reversals, refund SMS detection | All | Parser classifies reversal / refund messages correctly | parser | A (partial) | NOT TESTED | The 69 shared cases include genuine refund/reversal messages that must stay credits; general reversal/refund coverage was audited by no one | — |
| No fabricated amount: inexact | All | Rejected exact-money token goes to review, never a rounded confirmed row | `add_transaction_usecase.dart:222-239` | PASS (code inspection only) | NOT TESTED | B §2 (code) | — |
| No fabricated amount: missing currency | All | Message without currency token | legacy auto-confirm gate | A (probe), I | FAIL | B DATA-05 | V1-031 |
| Auto-confirm vs copy | All | Help text matches what is saved without review | `app_en.arb`, `app_ar.arb` | A | PASS | `2f2c4707`: `help_copy_truthfulness_test.dart` | V1-041 (FIXED) |
| Manual entry category | All | A new manual entry is never saved under the budget-only «All expenses» | `manual_transaction_sheet.dart` | A, R | PASS | `23499229`: `manual_category_default_test.dart`; simulator after image 47 (G UX-01). Rows already stored under it are unchanged | — (G UX-01 FIXED) |
| Categorization provenance | All | Manual category survives pull, import, restore | migration `20261117000000`, `ledger_sync_service` | A (+5 restore test), I | PASS | B §4 | — |
| Categorization after restore + sync | All | Restored categories not overwritten by cloud | restore + ledger sync | I | NOT TESTED | B §4 (suspected FAIL) | V1-020 |
| Categorization after re-parse | All | Manual category survives re-parse | — | — | NOT TESTED | no audit | — |
| Persistence: exact money | All | Totals in minor units, no cross-currency sum | `money.dart`, `dashboard_providers` | PASS (code inspection only) | NOT TESTED | B §4 | — |
| Reports: account balance | All | Displayed balance tracks transactions | `accounts_screen.dart` | I | FAIL | B DATA-06 | V1-032 |
| Bank coverage | All | Banks for each offered country | `assets/catalog/banks.json` | I | FAIL | A PROD-08 (SA, EG only) | V1-019 |

### B2. Local vs AI parsing, consent prerequisites and combinations

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Consent defaults | All | Fresh install transmits nothing | `ConsentAuthority`, `CloudEgressGate` | I consistent | NOT TESTED | E §4; no network capture; `cloud_off_egress_test` not run by CI (H REL-06) | — |
| Cloud OFF, AI OFF | All | No SMS or financial egress; local parsing only | gate + native mirror | I consistent | NOT TESTED | E §2.2 | — |
| Cloud ON, AI OFF | iOS, All | iOS uploads to `process-ios-sms` with `allowAi=false`; Places runs; no `parse-sms` | `SharedCaptureStore.swift:1976-1980` | I consistent | NOT TESTED | E SEC-09, §6 step 5; policy wording S4 | — |
| Cloud OFF, AI ON | All | AI egress refused without cloud | `consent_authority.dart:180-182`, `ai_endpoint.ts:383-391` | I, A (deno 26/26) | PASS | E §4 | — |
| Cloud ON, AI ON | All | Gemini parsing through `parse-sms` / `process-ios-sms`; shared learning on by default | consent gate, `merchant-category-contribution` | I consistent | NOT TESTED | E §2.1 | V1-048 |
| Server consent | Backend | Server refuses AI work the device's consent does not allow | `_shared/ai_endpoint.ts:261-286` | I, A | FAIL | E SEC-08: account-level on JWT path | V1-047 |
| Consent copy | All | Copy matches grant / withdraw controls | consent sheet, `privacy_screen.dart:421` | I | FAIL | A PROD-05: withdrawal is combined; the copy says separate | V1-017 |
| Ads gate | iOS / Android | No ad traffic with Cloud OFF | `mobile_ads_initializer.dart`, `GADDelayInitialization` | I consistent | NOT TESTED | E §4: iOS I consistent; Android suspected | V1-053 |
| AI version record | Backend | Model, prompt and config version recorded | `parse-sms` | I | FAIL | F BE-03: not persisted | V1-058 |

### B3. Revocation

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Revocation while queued | iOS | Capture queued before withdrawal is not uploaded afterwards | `admitUpload`, `localOnly` stamp | I consistent | NOT TESTED | C §4; C §6 step 7 | — |
| Revocation while retrying | iOS, Backend | Timeout retry re-admitted under consent; server retry re-checks | `BankMessageShortcuts.swift:249-274`; `process-ios-sms/index.ts:294-314,440` | I consistent | NOT TESTED | C §2, E §4 | — |
| Revocation in flight | All | Late response after OFF discarded; in-process upload cancelled | `cloud_egress_gate.dart:63-70`; epoch registry | I consistent | NOT TESTED | E §4, C §4; cross-process request not recallable (≤ 10 s, by design) | — |
| Offline revocation | Backend | Server row stays ON until revoke retry lands | `user_settings` | I | FAIL | E SEC-08 | V1-047 |
| Android permission revoked | Android | Switch reads OFF; nothing captured | `CaptureSettings.kt:65-74` | I consistent | NOT TESTED | D §6 step 14 | V1-004 |

### B4. Account switch, sign-out, session expiry, reconnect; owner of queued records

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Sign-out / switch | iOS | Owner and notifications cleared; A's queue not imported into B | `clearActiveOwner`, `bootstrap_runner.dart:1427-1452` | I consistent | NOT TESTED | C §4; native tests never run | gap: V1-012 |
| Session expiry | iOS | Owner kept; captures stay with the same user | `app_session.dart:4576-4596` | I consistent | NOT TESTED | C §4 | — |
| Sign-out / expiry | Android | Capture behavior matches documents | `MainActivity.kt:492-502` | I | FAIL | D AND-06 (document drift) | V1-053 |
| Account isolation (local) | iOS / Android | B cannot read A's local data | per-uid replica | I consistent | NOT TESTED | E §4 (device) | — |
| Queued owner (upload) | iOS | Upload only for stamped active owner | `authorizeUpload` | I consistent | NOT TESTED | E §4, C §4 | gap: V1-012 |
| Queued owner (drain) | Android | Drain sees only the active owner's items | `DurableCaptureQueue.kt:213-214` | I + Dart model test | NOT TESTED | D §4; H REL-06 calls the test a model of the code | gap: V1-012 |
| Reinstall | iOS | Keychain survives reinstall; different user sees none of A's data | `repairActiveOwnerGeneration` | I consistent | NOT TESTED | C §4 | — |
| Signed-out capture | iOS | Shortcut captures while signed out | `BankMessageShortcuts.swift:68-73` | I | FAIL | C IOS-06: silent drop, against the zero-silent-loss threshold; owner decision | V1-037 |
| Data removal through startup (configured build) | All | Remove data completes in a configured build with the real SDK and native session keychain | `bootstrap_runner.dart` | A (unconfigured harness only) | NOT TESTED | The define-gated stage runs only the configured group the harness supports (`29cb1819`); the original group fails under synthetic defines for a harness reason (V1-054) | V1-054 |
| Reconnect | All | Reconnect resumes without duplicates or loss | sync, capture replay | — | NOT TESTED | no audit | — |

### B5. Duplicates and distinct messages

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Same message twice (device) | All | Becomes a suspected duplicate for review, never silently dropped | `add_transaction_usecase.dart:991-1060` | PASS (code inspection only) | NOT TESTED | B §4; not executed | — |
| Same message, server path | iOS, Backend | Fingerprint on exact timestamp marks `suspicious_duplicate` | `capture_fingerprint.ts`, `process-ios-sms` | I consistent | NOT TESTED | B §2 | — |
| Across ingestion paths | iOS | Same SMS via Shortcut, share and paste → one transaction | all paths | — | NOT TESTED | no audit ran it; C §6 step 1 | — |
| Forged duplicates | Android | Another app injects messages through the share activity | `MainActivity.kt:225-277` | I | FAIL | D AND-07 (suspected) | V1-053 |
| Similar legitimate messages | All | Two genuine identical purchases at different times stay distinct | fingerprint on exact timestamp | I consistent | NOT TESTED | B §2 | — |

### B6. Queue overflow, corruption, age limits; offline

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Overflow | iOS | Items beyond the main segment go to encrypted overflow segments | `saveQueue` | I consistent | NOT TESTED | C §4 | — |
| Corruption | iOS | Unreadable queue not treated as empty; key never re-minted; segment quarantined | `decodeQueueBlob`, quarantine | I consistent | NOT TESTED | C §4 | — |
| Kill between drain and import | iOS | Per-item ack, nothing lost | `peekPendingPayloadsJSON` | I consistent | NOT TESTED | C §4 | — |
| Age limits | iOS | Stamped items of a non-active owner never expire | pruning | I | FAIL | C IOS-11 (S4 backlog) | IOS-11 |
| Corruption / key loss | Android | Quarantine, no silent loss | `DurableCaptureQueue.kt` | — | NOT TESTED | D §4 | — |
| Age / overflow | Android | Retention bounded | `DurableCaptureQueue.kt:31-37` | I | FAIL | D AND-08 (unbounded) | V1-053 |
| Force-stop / OEM killer | Android | SMS arriving while stopped | design | I | FAIL | D AND-03 (silent loss) | V1-027 |
| Doze / reboot | Android | Work runs after Doze and reboot | WorkManager | — | NOT TESTED | D §4 | — |
| Offline capture | iOS | Capture stays `pendingSend` and uploads after reconnect | `gatedUpload` | I consistent | NOT TESTED | C §2 | — |
| Offline core use | All | Local features work offline | app | — | NOT TESTED | no audit (CORE-08) | — |

### B7. Sync, backup, restore, migration

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Sync pull vs local edit | All | Pending edit never overwritten | `ledger_sync_service.dart:485-532` | PASS (code inspection only) | NOT TESTED | B §4 (code logic); not executed (REV-16) | — |
| Conflict keep-cloud | All | All 8 interactive entities fetch and apply atomically | `conflict_resolver.dart`, `app_providers.dart:1205-1222` | PASS (code inspection only) | NOT TESTED | B §4; not executed (REV-16) | — |
| Conflict diff timezone | All | No false date conflict outside UTC for a zone-less value | `conflict_fields.dart` | A | PASS | `ff1fc292`; `sync_conflict_store_test.dart` passed under `TZ=Asia/Riyadh` (AI:I). The test cannot fail on a UTC host (REV-11); server date-typed columns not checked | V1-028 (FIXED) |
| Restore validation | All | Malformed or newer backup rejected before mutation | `restore_backup_usecase.dart` | PASS (code inspection only) | NOT TESTED | B §4; not executed (REV-16) | — |
| Restore + cloud | All | Restored data vs cloud after re-enable | restore + sync | I | NOT TESTED | B §4 (suspected FAIL); V1-020 re-rated S1 SUSPECTED | V1-020 |
| Export protection | All | Copy matches protection | Help, data transfer | A | PASS | `2f2c4707`: `help_copy_truthfulness_test.dart` (Help no longer says encrypted) | V1-018 (FIXED) |
| Migration v42→v43 | All | Upgrade and crash replay | `app_database.dart` | A (+2) | PASS | B §4 | — |
| Migration v27–v42 | All | Real historical shapes | — | — | NOT TESTED | B §4 | gap: V1-033 |

### B8. AI failure modes and message content as data

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Malformed output / missing fields | Backend | Rejected, no invalid persistence | `_shared/ai_candidate_validator.ts:238-308` | PASS (code inspection only) | NOT TESTED | E §2.3 (AI-primary path) | — |
| Invalid amount (server) | Backend | `amount_text` must be a whole token agreeing with `amount` | same | PASS (code inspection only) | NOT TESTED | B §4 | — |
| Invalid amount (device) | iOS / Android | Substring of card or balance digits rejected | `grounding_check.dart` | A | FAIL | Whole-number grounding fixed (`d35fc044`, test). Arabic comma as thousands separator still grounds a fragment (REV-17 probe) | V1-057 |
| Invalid currency | Backend | Currency allowlisted | validator | PASS (code inspection only) | NOT TESTED | E §2.3 | — |
| Non-primary AI response | Backend | Normalized but not grounded on server | `parse-sms/money.ts:51-60` | I | FAIL | B DATA-03; not changed by `d35fc044` (device-side fix only) | V1-030 (registered as device only; see note under the tally) |
| Timeout | Backend | 12 s timeout → typed retryable | `parse-sms/index.ts:26,339` | PASS (code inspection only) | NOT TESTED | F §4 (server code) | — |
| Timeout / unavailable (client) | All | App falls back to local parsing with truthful state | client handling | — | NOT TESTED | F BE-03 states it; not traced or run by any audit | — |
| Rate limit | Backend / client | Per-identity cap returns `rate_limited`; client retries / falls back | `bump_capture_rate_limit`, client | I | NOT TESTED | F §2 (caps exist); client behavior not run | V1-022 |
| Model unavailable | Backend | Unset key → `upstream_unavailable` before spend | `parse-sms/index.ts:337-340` | PASS (code inspection only) | NOT TESTED | F §2 (code) | — |
| Prompt injection | Backend | SMS cannot steer persisted output | `parse-sms` + validator | PASS (code inspection only) | NOT TESTED | E §4 (with note); no data delimiter in the prompt (SEC-10, S4) | SEC-10 (S4) |
| Shared text with URL | iOS | Bank SMS with a link is captured, not filed as an offer | `ShareViewController.swift:98-117` | I | NOT TESTED | C §4 (suspected) | V1-038 |
| Deep links | iOS | External URL cannot trigger an action | Info.plist, router | I | NOT TESTED | E §4 | SEC-13 (S4) |
| Admin-authored content | All | Announcements and catalog rows treated as data | catalog, announcements | — | NOT TESTED | no audit | — |

### B9. Privacy-preserving notifications and diagnostics

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Lock-screen content | iOS | Amount, merchant, last-4 hidden by default | banners, server push alert | I | FAIL | C IOS-05 | V1-036 |
| Banner language | iOS | Legacy banner follows app language | `BankMessageShortcuts.swift:490-511` | I | FAIL | C IOS-04 | V1-035 |
| Notification visibility | Android | Capture and review notifications private | `local_notification_service.dart:416` | PASS (code inspection only) | NOT TESTED | D §4 (config set; device not tested; REV-16) | — |
| Permission denied | iOS | Capture still stored when notifications are denied | `scheduleNotification` | I consistent | NOT TESTED | C §4 | — |
| App-switcher snapshot | iOS | Snapshot hidden | `SceneDelegate.swift`, `installPrivacySnapshotView` | A (source-text test), R (partial) | NOT TESTED | `d70ba396` moves the cover to scene callbacks; `ios_privacy_snapshot_scene_test.dart` matches source text only. Simulator debug build at `f6dc5076`: launched, backgrounded and returned with UI intact; the cover in the app switcher was not observed. Inactive-state gap (REV-08) | V1-034 (FIXED locally) |
| Release logs | iOS | Native logs content-free | NSLog / os_log | I (grep) | PASS | C §4 (static property of the source) | — |
| Crash reports | All | No event while OFF; scrubbed while ON | `sentry_lifecycle.dart` | PASS (code inspection only) | NOT TESTED | E §4 (code; REV-16) | — |
| Release logs | Android | Kotlin logs content-free | — | — | NOT TESTED | no audit | — |
| Diagnostic string | All | No raw debug text in release UI | `privacy_screen.dart:545-550` | I | FAIL | A PROD-16 (S4) | PROD-16 |

### B10. Sign-in, deletion, release path

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Onboarding routing | All | language → story → auth → setup → shell, no loop | `app_router.dart`, `app_session.dart` | PASS (code inspection only); R to the consent step | NOT TESTED | A §4 (code logic; REV-16). Audit G reached the consent step on a simulator; the shell cannot be reached without a backend (G UX-22) | — |
| Sign-in providers | iOS | At least one working method; set intended | `auth_screen.dart`, `codemagic.yaml` | I | NOT TESTED | A §4 (env values unknown) | V1-016 |
| Sign-in providers | Android | At least one method in a release build | same | I | FAIL | A PROD-04, H REL-01 | V1-004 |
| Account deletion | iOS | Reachable in-app; Apple revoke; policy matches | `/delete-account`, `apple_deletion_gateway` | I, A (deno) | FAIL | C §4, E SEC-03, F BE-01 | V1-006, V1-002 |
| Force-update targeting | All | A cached notice blocks only the versions it targets | `app_providers.dart`, `force_update_screen.dart` | A | FAIL | `7597bb42`: `force_update_version_range_test.dart` passes; a malformed bound now fails open (REV-10, no test); builds of the same marketing version cannot be targeted | V1-040 |
| Release pipeline | iOS | Build is App Store submittable | `ios-signed` export options | I | FAIL | C IOS-02, H REL-03 | V1-009 |
| Version reporting | iOS / Android | `X-App-Version` non-empty in every release workflow | `codemagic.yaml` | A (contract test) | PASS | `64e571e5`: `codemagic_app_version_contract_test.mjs`. CI configuration only; no CI build has run with it | V1-010 (FIXED) |

## Tally (Part A)

| Status | Count |
|---|---|
| PASS | 5 (SCOPE-02, SEC-09, PRIV-01, ARCH-03, BUILD-01 — the last two from the strict gate run on `af675aec`) |
| FAIL | 51 |
| NOT TESTED | 46 |
| NOT APPLICABLE | 0 (STORE-03 becomes NOT APPLICABLE only if the owner records Android as OUT) |
| **Total** | **102** |

Changes since the `ab5dc10a` compilation: PRIV-01 NOT TESTED → PASS (withdrawal semantics resolved from code); DATA-04, DATA-09, COMP-05 and SEC-04 FAIL → NOT TESTED (linked defects fixed in code; the criteria are not yet verified by the required method); UX-03, UX-05, UX-06 PENDING → FAIL; the other seven UX rows PENDING → NOT TESTED.

This tally is for information only. It does not offset any blocker. Open S1 issues: V1-001 (fixed in code on this branch, not closed: needs the `process-ios-sms` deploy, a new build and device verification), V1-002, V1-003, V1-004, V1-007, V1-014, V1-015 and V1-020. The decision rule in SEVERITY-AND-GATES.md applies regardless of these counts.

Note: the server's non-primary AI path (`parse-sms/money.ts`, B DATA-03) is ungrounded and unchanged. ISSUES.md files V1-030 as on-device grounding and marks it FIXED, so this server gap has no open issue of its own; the register should give it one.
