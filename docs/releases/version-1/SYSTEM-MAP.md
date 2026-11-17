# Version 1 — system map

Assessed at: the commit recorded in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) (`50957c06` at the time of writing; local branch `release-readiness/v1`, not pushed, built by CI, deployed or submitted). `23499229`, `af675aec`, `c8cef416`, `5583cbea` and `75dab61a` are earlier points on the same line, not alternative candidates.

What is present in the repository, how data moves, where the trust boundaries are, and what leaves the device under which consent. Compiled from the specialist audits in [`evidence/audits/`](evidence/audits/) (cited as A, B, C, D, E, F, H with section or finding ID; I = independent review, REV-nn) at the baseline `ab5dc10a`, then corrected for the 28 commits up to `50957c06` (12 round-1 code, 1 records, 15 round-2 code) and for what the independent reviews (I, K, L, N, O, P, Q, R) contradicted. `path:line` references are from the audits at `ab5dc10a` unless a commit is named, and some lines have moved since. Evidence is code inspection or targeted local runs. Runtime observations are debug builds on iOS 26.5 simulators: without a backend (audit G; `f6dc5076`), and signed in against a local Supabase stack with Cloud and AI off and functions not served (J at `8e953d14`, M at `0095a239`). Production facts are from a read-only comparison against `af675aec` ([`evidence/production-comparison.md`](evidence/production-comparison.md)); `process-ios-sms`, `parse-sms` and `_shared/ai_candidate_validator.ts` changed after it. **No device or store-console observation backs anything here.** Anything not established is marked **unknown**.

Compiled by: AI agent (release-records compiler), claude-opus-5-5, 2026-11-17. Updated by: AI agent (release-records editor), claude-opus-5-5, 2026-11-17.

## 1. Components

| Component | What is there | Evidence |
|---|---|---|
| Flutter app | `app/lib`: features (see [SCOPE.md](SCOPE.md) §2), Drift database encrypted with SQLCipher/sqlite3mc, one replica directory and key per user (`qirsh.db_key.<salted uid hash>`), exact money in `amount_minor` (int64) plus a REAL shadow column. All HTTP goes through `GatedHttpClient`; the Supabase client is built with it. | E §2.1, §2.3; B §2; `replica_store.dart:27,106-125`; `bootstrap_runner.dart:673` |
| iOS Runner | `AppDelegate`, `SceneDelegate`, `SharedCaptureStore` (encrypted capture queue), `SessionKeychain`, BGTaskScheduler refresh + processing drain, APNs registration. The Shortcuts App Intent (`BankMessageShortcuts.swift`) is compiled into Runner. Bundle `com.youssefsafwat.mali`. App-switcher privacy cover: installed on `sceneDidEnterBackground`, removed on `sceneWillEnterForeground` / `sceneDidBecomeActive` (`d70ba396`); it is not installed while the scene is only inactive, nor for a scene launched straight into the background (REV-08). The snapshot iOS stores for the switcher shows only the cover (simulator, J); the live switcher was not opened. XCTests: 194 passed on a simulator at `d830855e`; no `app/ios` change since. Required-reason API declarations added to both privacy manifests (`d70ba396`; reason codes unconfirmed). | C §1–§2; `project.pbxproj:30,541`; I REV-08, REV-09 |
| iOS ShareBankMessage extension | Share sheet target `.ShareBankMessage`; same `SharedCaptureStore` source; no network; cannot write owner, consent mirror, egress state or barrier (`CAPTURE_STATE_WRITER` not defined). URL items go to a separate offer store. | C §2; `project.pbxproj:923,949`; `ShareViewController.swift:98-117` |
| iOS shared state | App Group `group.com.youssefsafwat.mali` (queue file + overflow segments, offer store, defaults); shared Keychain group `<prefix>com.youssefsafwat.mali.shared` (queue key, owner record, device secret, egress state). | C §2; `SharedCaptureStore.swift:23-60,4917-4960,736-741` |
| Android native | 11 Kotlin sources: `SmsCaptureReceiver` (`RECEIVE_SMS` only, guarded by `BROADCAST_SMS`), `CaptureSettings` (opt-in, default off), `DurableCaptureQueue` (AES-256-GCM, Keystore key, owner stamp), `CaptureDrainWorker` (WorkManager), `MainActivity` (share intent, `FLAG_SECURE`, owner hooks), `SessionKeychain`, `SharedContentRouter`, `OfferIntentStore`. Backups and device transfer disabled. Never built as a release; never run on a device. | D §2 |
| Supabase database | Migrations `0001`–`0117` plus 17 timestamped 2026-11 files; RLS enabled on every created table (static check); 155–159 SECURITY DEFINER functions, all pin `search_path` (static check); `qirsh_server_capabilities()` advertises features to clients. **Production (read-only): exactly the candidate's 134 migrations are applied** (names, not content; V1-002 closed for the ledger). No migration changed after `af675aec`. The production advisor shows two trigger functions executable by `anon` (V1-064). | E §2.3; F §1, §2, BE-01; production-comparison §4.1, §4.5 |
| Supabase Edge Functions | 33 function directories under `supabase/functions/`, plus the `_shared` library (the 34th directory, not a function). Production has 28 deployed. `process-ios-sms` and `parse-sms` (parser and grounding changes) and `account-deletion-worker` (v5, erases only `backups`, V1-062) differ from the candidate and are not deployed; `process-ios-sms` uses its default model `gemini-3.8-flash`. Ten run with `verify_jwt = false` and authenticate with worker secrets or signed tokens; the rest keep gateway JWT verification plus a verified identity (device secret or user JWT). | F §2, §5 B; `supabase/config.toml:415-502`; production-comparison §1–§3 |
| Supabase Storage | Buckets `backups` (encrypted archive) and `profile-photos` (owner-folder RLS). Production: `backups` private, `profile-photos` private, `coupon-assets` public. Point-in-time recovery off and no backups listed (V1-023). | E §2.2, §5; production-comparison §3, §4.4 |
| Scheduled jobs (pg_cron / pg_net) | `account-deletion-worker` (every 5 min) and `account-deletion-purge-expired` (0117); capture-content, fingerprint and notification-log retention (0112); push-broadcast auto-retry dispatcher (20261117010000); notification retries; daily reminders; engagement webhooks (row triggers → `evaluate-budgets` / `evaluate-gamification`, inert without the Vault secret). Workers fail closed when their secret is absent. Production (read-only): deletion worker, deletion purge, notification and push retries, daily reminders and three prune jobs active; `affiliate-sync-hourly` inactive. Run history not queried. | E §2.3; F §2, BE-10, §5 E; production-comparison §4.2 |
| Admin panel | Next.js 14.2.35 (`admin/`; was 14.2.29 at the baseline, `f9c5be75`; owner decision B17 on exposure); no remote image hosts and image optimization off (`f6dc5076`), though `/_next/image` is still outside the auth middleware; 25 advisories on `next` remain at 14.2.35 (REV-07, V1-025). Middleware + `requireAdmin()` on every page and API route; service-role key used server-side only; audit tables for flags, announcements, referrals, push. Reported to run as a local build on 127.0.0.1 (not verified). | F §2, BE-07; I REV-07 |
| CI/CD | Codemagic: `backend-and-quality-gates` (gates + Android debug APK compile), `ios-signed` (produced TestFlight 147; internal-testing-only export; variable group `supabase` only), `ios-signed-release` (App Store–capable; since `4fc2ecd6` it has the checks of `ios-signed` plus native XCTests and uploads without submitting; groups `supabase` and `admob`; never run), `ios-unsigned-sideload` (runs native XCTests since `4fc2ecd6`), `android-release` (never run per D; groups include `admob`). `APP_VERSION` is now resolved in every workflow, and an unresolved version fails the build (`64e571e5`; contract test; not yet exercised by a CI build). Release workflows run `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` before signing; the gate now matches Flutter skip sites against `tools/test_skip_manifest.json` (`64e571e5`) and has a mandatory stage 4d that runs the six define-gated Flutter suites with synthetic defines (`29cb1819`). No CI build of any commit on this branch exists. GitHub Actions `ci.yml` exists with no recorded runs. No step deploys migrations or functions. | H §2, REL-03, REL-17; F BE-02; `codemagic.yaml`, `tools/ci_gates.sh` |
| Third-party services | Google Gemini (AI parsing), Google Places (merchant enrichment), Sentry (app crash reports), Google Mobile Ads + UMP (SDK linked; flags off by default but **all ad flags ON at 100% in production**, V1-063), Sign in with Apple (+ token revocation on deletion), Google sign-in (AppAuth), Supabase Auth, APNs, public legal and support pages on `qirsh.site`. Android push transport (FCM or none): **unknown**, not covered by any audit. | E §2.2; C §2; H §2 |

## 2. Data flows

### 2.1 Capture → transaction → report

```
 iOS: SMS ─► user's Shortcuts automation ─► App Intent ─┐        Android: SMS ─► SmsCaptureReceiver
      shared text ─► Share extension ───────────────────┤                 (opt-in + permission + owner)
                                                        ▼                          │
                         SharedCaptureStore (AES-GCM, App Group)        DurableCaptureQueue (AES-GCM)
                         persisted BEFORE any network                              │
                            │                    │                                 │
     consent mirror cloud=on, owner stamped      │ Flutter import (peek + per-item ack)
     ─► native sanitize ─► gatedUpload ─► process-ios-sms ──┐                      │
        (server: capture_claim consent, declined check*,    │  client re-checks    ▼
         deterministic parse, Gemini if allowAi,            └──► declined*,  ──► AddTransactionUseCase (Dart)
                                                                 direction†
         fingerprint dedupe, push alert)                                         on-device parser + declined
                                                                  check* ─► (optional AI: parse-sms ─► Gemini,
                                                                  cloud+AI consent; skipped for declined*) ─►
   manual entry / paste ────────────────────────────────────────► validity / auto-confirm ≥0.92 ─► duplicate
                                                                  check ─► Drift DB (amount_minor) ─► lists,
                                                                  budgets, reports via financial_semantics

 * declined / failed / rejected / cancelled message → Smart Inbox review, never a confirmed row
   (ten parser rounds d35fc044 … 50957c06; server part not deployed)
 † server result the device reads in the opposite direction (1be44623) or with another
   amount (5583cbea) → Smart Inbox review
```

| Step | Behavior established | Evidence |
|---|---|---|
| Persist first (iOS) | App Intent writes the capture `pendingSend` before any network; unreadable queue throws, never "empty"; signed-out App Intent drops silently. | C §2; `BankMessageShortcuts.swift:63-241,68-73` |
| Sanitization | iOS native sanitizer runs before upload and throws `sanitizerUnavailable` rather than send raw text; server re-sanitizes before the Gemini prompt. Sanitization on the Android → `parse-sms` path is implied by the consent copy and the server re-sanitize; the Dart sanitizer itself was not traced by any audit (**unknown in detail**). | C §2; E SEC-10 (`parse-sms/index.ts:382-412`) |
| Local parse | `parser_engine.dart`: Arabic-Indic digits, Arabic separators, currency before/after parsed correctly in a probe at `ab5dc10a` (not re-checked with those strings after the parser changed). Since `5583cbea` a figure introduced by a limit, balance, remaining, due or code label is a labelled figure, never the amount, on device and server (V1-078, V1-079; reviewers P and R). Known wrong at `50957c06` (review R, synthetic): a foreign-currency figure recorded instead of the charged amount, and `SR1,250.00` read as 250 (V1-084). Currency codes match whole words since `75dab61a`. A year-less date no longer lands in the future (`d35fc044`, V1-029). Missing currency falls back to account currency (V1-031). | B §2, DATA-01/04/05; I REV-15 |
| Declined / failed messages | Fixed in code on this branch, not closed (V1-001). `TransactionStateCues` (ten parser rounds, `d35fc044` … `50957c06`) treats a message whose own transaction is declined, failed, rejected, cancelled, pending, held or blocked as not completed; a credit word exempts it only when the credit is the message's completed action; a cue inside a merchant name, after a negation or in an advisory footer does not count. **Outcomes at `50957c06`:** a not-completed message → Smart Inbox review (device) or rejected (server), never confirmed; a refund or reversal of a declined original → review; an incoming-money phrase with no other direction evidence → review; a figure in a due-or-scheduled clause → review; informational words (limit, activation, renewal, statement, PIN) can never silence a message — only the original ignore set can (`75dab61a`); a figure introduced by a limit, balance, remaining, due or code label is never the amount, and an AI amount equal to such a figure is rejected (`5583cbea`). **Import-path defences:** both client import paths (`capture_import_service.dart`, `capture_sync_service.dart`) re-check a server-`processed` capture with `validateCaptureCandidate`, send a declined one to review, and send a result whose direction (`1be44623`) or amount (`5583cbea`) contradicts the device's own reading to review (`localParseContradictsServer`); the device does not confirm a server result it would ignore. Not routed on import: type-only differences and a device `transfer` against a server direction (V1-076, RR-06). Also applied in: the AI path (declined not sent to AI; AI candidate rejected — and correct candidates over-rejected again, 353 of 1,306, V1-086); `process-ios-sms` (same cue lists, mirrored by hand, V1-081); the Dart notification preview (contextual rule, `84f2fe41`; the Swift preview still matches substrings, V1-061). 1,565 shared synthetic cases run against device and server code; 75 carry an open-defect pin. **Review outcome:** N rejected `1be44623`, Q rejected `75dab61a`; R accepted the final commit `50957c06` with follow-up: no S1, nothing worse than the baseline on the device or effective path, wrong total-changing outcomes 509 → 71 on 1,758 synthetic messages (effective, bank sender). Still wrong: notices recorded as money (V1-072), wrong directions (V1-082), own-account transfers (V1-083), foreign figures (V1-084). More correct messages wait in review (V1-085). The server alone rejects 21 completed messages that only the matching device build keeps for review (V1-088), so server and build must ship together (V1-087). Not in effect for: the deployed server until the owner-authorized deploy; any installed build, including 147 (after the deploy, build 147 re-parses a rejected capture with its old parser and confirms it, REV-03; that pairing was not measured); rows stored before the fix (V1-056). | `d35fc044` … `50957c06`; I REV-01..05; K, L, N, O, P, Q, R; REVIEW-CLOSURE.md |
| AI parse | Device: `parse-sms` (cloud+AI). On-device AI grounding requires a whole number in the message (`d35fc044`, V1-030), with the Arabic comma as a thousands separator (`0de54a2b`, V1-057). Server: whole-token grounding, currency allowlist, placeholder rejection in AI-primary mode; 12 s Gemini timeout; typed retryable errors; idempotency; per-capture budget of 3 attempts; `store:false`. The server's non-primary AI path (`parse-sms/money.ts`) grounds the AI amount since `0de54a2b` (V1-060; production runs the older function). Model and prompt version are not persisted server-side (V1-058). | B DATA-03; E §2.3; F §2, BE-03 |
| Commit | Auto-confirm at confidence ≥ 0.92; rejected exact-money tokens go to review as LEGACY_LOSSY; suspected duplicates go to review, never silently dropped. Help now says confident captures are saved directly (`2f2c4707`). Manual entry has no pre-selected category (`23499229`). | A PROD-07; B §2 |
| Reports | One spend contract: payment + withdrawal − refund; transfers and unknown excluded; only `confirmed` counts; no cross-currency sums; local month boundaries converted to UTC. Account "current balance" is not derived from transactions (V1-032). | B §2, DATA-06 |
| Categorization | Category provenance (`category_source`) kept through pull, import and backup; server trigger records `unknown` without a fresh token. | B §2 |

### 2.2 Other flows

| Flow | What happens | Evidence |
|---|---|---|
| Sync | Outbox push via CAS RPCs (`0107`), `client_request_id = local id`; pull never overwrites a pending local edit, records a durable conflict instead; keep-cloud resolution is atomic for all 8 interactive entities; planning sync compiled on, gated by consent and server capability. Conflict field diff reads zone-less timestamps as UTC (`ff1fc292`, V1-028; it parsed them as device-local time at the baseline). | B §2, DATA-07; A §2.4 |
| Backup / restore | Data-transfer ZIP export is not password-protected (Help says so since `2f2c4707`). Legacy encrypted restore: Argon2id (64 MiB, t=3, p=2) + AES-256-GCM. Restore validates before mutating, runs in one transaction and resets consent OFF. Since `0f90003f` it reconciles with cloud sync (V1-020): the account identity is kept, restored rows are queued as pending push, intents recorded before the restore are dropped, pull cursors are reset, and the backfill binds to an existing cloud row before inserting, so device and cloud converge (local stack, orchestrator and reviewer K). Under the merge default, cloud rows absent from the backup come back and an unsynced post-backup row returns while the confirmation says "replace" (V1-070); replace vs merge is owner decision B10. The screen that turns on encrypted cloud backup is orphaned (V1-042). | B §2, DATA-02; E §2.3; A PROD-06, PROD-09 |
| Account deletion | Privacy → `/delete-account` → `delete-account-immediate` (raw HTTP client, explicit user action) → `account_deletion_*` RPCs defined only in `0117` and `20261110124809` → storage sweep of `backups` and `profile-photos` → Apple token revocation; cron worker recovers stuck jobs. Immediate and permanent in-app; policy says 30-day undo (V1-006). Production (read-only): the RPCs are present; the deployed `account-deletion-worker` (v5) erases only `backups`, so a deletion it resumes leaves the profile photo (V1-062). Entry screen seen on a simulator (J); the confirmation dialog was not reached. | E §2.3, SEC-03; F BE-01; C §2 |
| Sign-out / switch / expiry | iOS: sign-out or switch clears the capture owner and that owner's notifications; session expiry keeps the owner; local data stays on device. Android: sign-out and session expiry clear the owner and stop capture. | C §2; D AND-06 |
| Push | APNs registration only when egress is admitted; `aps-environment` production in Release. Capture push from `process-ios-sms` carries amount/merchant unless the user hides lock-screen content (default not hidden, V1-036); what it sends for a capture the server rejects as declined is **unknown**. Admin broadcast: typed confirmation, `FOR UPDATE SKIP LOCKED` claim, 15-min lease, per-broadcast collapse id, 2.5 s APNs timeout. | C §2, IOS-05; F §2 |
| Catalog | Parser rules, flags, announcements, banks fetched only with Cloud consent, through the signed-in client (policy says anonymous and ungated, V1-045). Force update is an announcement severity. A cached notice is now re-checked against its version range on device (`7597bb42`, V1-039); a malformed bound fails open (REV-10); it cannot target build numbers (V1-040). | E SEC-05; A PROD-11; F BE-06; I REV-10 |

## 3. Trust boundaries

```
 ┌────────────── device ───────────────┐      TLS       ┌──────── Supabase project ────────┐
 │ untrusted input: SMS, share payload,│  JWT / device  │ Edge Functions ─► Postgres (RLS) │
 │ URL scheme, AI output, catalog rows │  secret        │      │            ▲              │
 │ App ◄─► App Group / shared Keychain │ ─────────────► │      ▼            │ service role │
 │   (extension: no protected writes)  │                │  Gemini, Places   Admin (Next.js)│
 └─────────────────────────────────────┘                │  APNs             loopback? (unk)│
                                                        └──────────────────────────────────┘
```

| Boundary | Control established | Gap / unknown |
|---|---|---|
| SMS / share text → app | Treated as data; Android receiver only from the OS; iOS share empty → error | Android share activity accepts forged messages from any foreground app (AND-07, V1-053); iOS shared text with a URL may go to Offers (V1-038) |
| App ↔ Share extension | Extension cannot write protected state; one `flock` across processes | — |
| Device ↔ backend | `GatedHttpClient` with durable per-owner ON record; native `admitUpload` under lock; server `resolveVerifiedIdentity` never accepts a bare install id | Server consent on the JWT path is per account, not per device (V1-047); anonymous device identities are free (V1-022) |
| Backend ↔ AI provider | Re-sanitized text, `store:false`, grounded output validation | No data delimiter in prompt (SEC-10, S4); Gemini billing tier unknown |
| Admin ↔ database | `admin_users` membership, `requireAdmin()` everywhere, service key server-only | Password-only login, no MFA; Next.js advisories (V1-025); exposure unknown |
| CI ↔ store | Gates before signing; `ios-signed` and, since `4fc2ecd6`, `ios-signed-release` verify production URL, profiles, entitlements, provenance | `ios-signed-release` never run (V1-009); reviewed-SHA check is self-attested (V1-051) |
| Operator ↔ production | — | Migrations, functions, secrets, Vault, Auth hook all manual and undocumented (V1-021). Read-only comparison: migrations match; three functions differ; Vault, Auth hook and Codemagic values unknown |

## 4. Consent model as implemented

Per user, per device, stored locally; mirrored natively on iOS; read server-side from `capture_devices` (device path) or `user_settings` (JWT path, account-level). Source: E §2.1 unless noted.

| Flag | Default | What it permits |
|---|---|---|
| `cloudConsentState` | `unset` (= denied) | Master gate for every user-data egress class: financial sync, profile and settings (incl. photo), backup, sender-bank mappings, Smart Inbox, gamification, telemetry, Sentry diagnostics, catalog; also AdMob/UMP initialization, every external URL launch (including the privacy policy, V1-007) and network images; Google Places enrichment (via financial sync); iOS upload to `process-ios-sms` (native mirror `cloud`). |
| `aiConsentState` | `unset` | AI egress (`parse-sms`, `bank-discovery`, Gemini on the iOS server path) only when cloud **and** AI are accepted. With AI off and cloud on, iOS still uploads message text to `process-ios-sms` with `allowAi=false`, and Places still runs (E SEC-09). |
| Shared category learning | ON, effective only with cloud + AI | Contributing merchant → category pairs (HMAC-pseudonymised contributor id); server re-checks `'ai'`. Publishes fleet-wide at ≥ 6 accounts (V1-048). |
| `merchantPersonalizationEnabled` | false | Local only, never synced. |
| `hideLockScreenContent` | false | When false, local banners and server push show amount, merchant, card last-4 (V1-036; C IOS-05). |
| Android `autoCaptureEnabled` | false | Receiver reads nothing unless on; requires the OS permission and an active owner who opted in. (D §2) |
| UMP (Google) | n/a | Sole ad-consent authority; all ad requests non-personalized. (DECISIONS D-5, D-6) |

Grant and withdrawal (combined): the UI grants both permissions with one action and withdraws both together (`privacy_screen.dart:421`, "Both permissions, together"; A PROD-05). There is no separate AI-only withdrawal; E §2.1's statement that each can be withdrawn separately is superseded. The consent sheet copy still says either can be withdrawn separately (V1-017, owner decision). Revocation: Dart writes DISABLING under the admission lock and discards late responses; iOS cancels in-process uploads and stamps later captures `localOnly`; a request already on the wire in another process cannot be recalled (waits out ≤ 10 s). Server retries re-check consent. (C §2; E §2.1)

## 5. Outbound data inventory

Source: E §2.2, extended with C §2 and F §2. "Gate" is the client gate; server gate in brackets.

| Destination | Data | Gate |
|---|---|---|
| Supabase PostgREST (sync) | accounts, transactions, budgets, goals, settings (name, phone, date of birth), merchant rules | cloud [RLS per owner] |
| Supabase Storage `backups` | encrypted archive | cloud (backup) [storage RLS] |
| Supabase Storage `profile-photos` | avatar image | cloud (profile) + server capability [owner-folder RLS] |
| `process-ios-sms` (native iOS) | sanitized SMS text, sender, time, timezone, locale, `allowAi`, `notificationDetails` | native mirror cloud [`capture_claim`] |
| `parse-sms`, `bank-discovery` → Gemini | sanitized SMS text, alphabetic sender | cloud + AI [verified identity + `'ai'`] |
| `enrich-merchant` → Google Places | merchant name, country | cloud [identity + `'cloud'`] |
| `merchant-category-contribution` | merchant name + category | cloud + AI + shared-learning switch [`'ai'`] |
| `record_metric`, engagement, notification telemetry; `profiles.last_seen_at` | event keys, placement keys, activity timestamps | cloud [owner-bound RPC] |
| Catalog functions | app version (`X-App-Version`), country, user JWT | cloud (catalog) |
| `register-device`, `register-push-token`, `link-capture-device`, `set-device-consent` | install id, device secret, APNs token, consent state | APNs registration gated by egress admission (C); gating of the others **unknown** (no audit traced them client-side) |
| Sentry | sanitized crash events (no PII, no screenshots) | cloud (diagnostics) |
| Google Mobile Ads + UMP | Google-defined device / ad signals | cloud + remote flags + build-injected IDs; Android may initialise at process start (SEC-07, unverified) |
| APNs (via server) | push alert, with transaction detail unless hidden | server-side; lock-screen setting |
| Supabase Auth, Apple, Google sign-in | credentials exchange, tokens | explicit user action; refresh exception |
| `delete-account-immediate` | deletion request | explicit user action (raw client, not gated) |
| `qirsh.site` / external URLs | none (navigation) | cloud — blocks legal pages when off (V1-007) |

E reports no path that carries SMS text, amounts or merchant names without cloud consent (and AI consent for Gemini). This is a code-inspection result; no network capture was made on any platform.

## 6. External dependencies and failure behavior

| Dependency | When down, slow or returning garbage | Evidence |
|---|---|---|
| Gemini | 12 s timeout → typed retryable `upstream_unavailable`; idempotent retry does not re-pay; malformed/ungrounded output rejected on the server AI-primary path; unset `GEMINI_API_KEY` returns `upstream_unavailable` before spend; client falls back to local parsing (as F states). Device-side grounding is weaker (V1-030). | F §2, BE-03, BE-13; B DATA-03 |
| Supabase backend (unreachable / timeout) | iOS capture stays queued `pendingSend`; 8 s upload timeout; idempotent timeout retry re-admitted under consent. Behavior of sync and UI states when offline: **unknown** (CORE-08 not tested). | C §2 |
| APNs | 2.5 s timeout; at-least-once resend with collapse id; auto-retry dispatcher with 15-min lease. Token withheld if environment unresolved. | F §2; C §2 |
| Google Places | **unknown** | — |
| Sentry | Initialised only while permitted; failure behavior **unknown** | E §2.1 |
| AdMob / UMP | Flags off by default but ON in production (V1-063); `ios-signed` does not attach the `admob` group so ads fail closed there; `ios-signed-release` and `android-release` do attach it, so builds from them carry the AdMob IDs. Behavior on SDK failure: **unknown** | E SEC-01; `codemagic.yaml` |
| Apple token revocation (deletion) | Gateway exists; failure handling **unknown** (0117 read at header level only) | C §2; F §1 |
| `qirsh.site` legal pages | Live (HTTP 200) on 2026-11-17; unreachable in-app while Cloud is off (V1-007) | H §2; E SEC-02 |
| Codemagic / App Store Connect | Build number resolution: since `4fc2ecd6` `ios-signed-release` resolves a build number for a version with no builds yet, and uploads without submitting; never run on Codemagic (V1-009) | H REL-18; `4fc2ecd6` |
