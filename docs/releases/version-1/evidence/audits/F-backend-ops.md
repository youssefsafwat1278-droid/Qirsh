# Backend, Admin and Operations audit — Qirsh V1
Model: claude-opus-5-5 (Opus 5.5)
Date: 2026-11-17 · Commit: ab5dc10a · Reviewer: Backend/Admin/Operations specialist (AI agent)

## 1. Scope covered / not covered

Covered, at commit `ab5dc10a` (backend and admin are byte-identical to TestFlight 1.0.0 (147)'s source `b6fc0dad`; `git diff --stat b6fc0dad ab5dc10a` touches only 5 app files):

- `supabase/migrations` (117 numbered + 17 timestamped files), `supabase/deferred`, `supabase/rollback`, `docs/project/MIGRATION_LEDGER.md`, `supabase/deferred/README.md`.
- `supabase/config.toml` function JWT settings; all 34 Edge Functions surveyed for auth model, rate limits, timeouts, AI cost controls; `send-push-broadcast`, `parse-sms`, `register-device`, `google-enrollment`, `catalog-flags`, `catalog-announcements`, `account-deletion-worker`, `_shared/ai_endpoint.ts` read in detail.
- pg_cron jobs and the new push-broadcast auto-retry (migration, rollback SQL, runbook).
- Admin panel (`admin/`): middleware, every API route, server pages, service-role use, `npm audit --omit=dev`.
- Operations material: monitoring, backups, incident response, capacity.

Not covered: the 6,600-line `0117_account_deletion_fence.sql` was read at header/preflight level only (deep review belongs to the privacy/deletion specialist); `process-ios-sms` (4k lines) only surveyed for rate limit/timeout; affiliate functions only surveyed (features are flag-OFF). No production access was used or attempted.

Commands run (all read-only / local):
- `bash supabase/tools/check_migrations.sh` → `PASS` (numbering 0001..0117 + 17 timestamped, 159 SECURITY DEFINER functions checked, rollback coverage from 84: 0 missing, 1 deferred).
- `deno test --allow-env --no-check=remote send-push-broadcast/send_test.ts` → `ok | 23 passed | 0 failed` (without `--allow-env` 1 test fails with `NotCapable` only — permission, not a defect; CI uses `--allow-all`).
- `deno test account-deletion-worker/handler_test.ts` → `ok | 7 passed | 0 failed`.
- `deno check send-push-broadcast/index.ts google-enrollment/index.ts catalog-announcements/index.ts parse-sms/index.ts` → all pass.
- `npm audit --omit=dev` (in `admin/`) → `4 vulnerabilities (3 high, 1 critical)`: `next` (critical, range `0.9.9 - 16.3.0-preview.10`, installed 14.2.29), `postcss`, `nanoid`, `source-map-js`.

## 2. What is established (verified behavior, with evidence)

- **Migration chain is lint-clean and gapless**; every migration from 0084 on has a rollback file (lint output above). The lexical order `0117_…` < `2026…` is preserved by the CLI's filename sort.
- **Capability discipline (expand/contract) is followed for the 2026-11 features.** Every migration that adds a client-visible feature re-declares `qirsh_server_capabilities()` with all prior keys plus its own: `merchant_rules_sync` (`20261116180000`), `profile_photo_backup` (`20261116210000`), `transaction_category_source` (`20261117000000`); client reads it at `app/lib/data/sync/server_capabilities.dart:147`. A client talking to a database without these migrations sees the capability absent and does not use the feature.
- **No destructive DDL** (DROP TABLE/COLUMN, RENAME, SET NOT NULL, type change) in 0100–0117 or the 2026-11 set (grep over those files; only DELETE statements inside erasure/retention functions). New columns are nullable (`push_broadcast_deliveries.next_attempt_at`, `push_broadcasts.test_user_id`, budget alert threshold).
- **`20261117000000_transaction_category_source`** is designed for older writers: any write without a fresh `metadata.cs_op` token that changes the category records `'unknown'` (header lines 1–20). Older clients keep working.
- **Push-broadcast double-send protection**: manual and scheduled runs share `push_broadcast_claim_rows` (`FOR UPDATE SKIP LOCKED`, row moved to `sending` in the same statement; `20261117010000_push_broadcast_auto_retry.sql:82-130`); abandoned leases reclaimable after 15 min (`:71`), longer than the 120 s claim budget (`send-push-broadcast/send.ts:36`) and the 400 s function wall clock. APNs requests carry a per-broadcast collapse id (`send.ts:340`, `_shared/apns.ts:56-57`) so an at-least-once resend replaces rather than duplicates the banner. APNs fetch has a 2.5 s timeout (`_shared/apns.ts:86`). The dispatcher makes no HTTP call when nothing is due and fails closed without a strong Vault secret (`20261117010000…sql:297-320`). Deno tests confirm weak/missing secret never authenticates (23/23 pass).
- **Worker endpoints** with `verify_jwt = false` (`supabase/config.toml:415-502`) each check a dedicated secret with constant-time comparison and fail closed when the secret is empty (`account-deletion-worker/handler.ts:26-30`; `bearerSecretAuthorized` in affiliate-sync / purge / send-push-broadcast; `timingSafeEqual` in evaluate-*, cron-daily-reminders, process-notification-retries).
- **Other functions keep gateway JWT verification** (default `true`; not listed in config.toml) and add verified identity: device secret or real user JWT, never a caller-supplied install id (`_shared/ai_endpoint.ts:213-285`), consent read server-side and failing closed (`:280-283`, `consentError` `:383-390`).
- **AI endpoints**: per-identity daily caps (`parse-sms/index.ts:51` 500/day; `bank-discovery/index.ts:33` 50; `enrich-merchant/index.ts:42` 200; `process-ios-sms/index.ts:37` 300), 12 s Gemini timeout (`parse-sms/index.ts:26`), typed retryable errors on timeout/unavailable (`:339`, `:375-379`, `:503`), request idempotency so a client retry does not re-pay (`:342-359`), per-capture AI attempt budget of 3 (`20261106104441_capture_ai_attempt_budget.sql:4-6`). Unsetting `GEMINI_API_KEY` makes `parse-sms` return `upstream_unavailable` (retryable) before any spend (`parse-sms/index.ts:337-340`) — a usable server-side AI kill switch.
- **Admin authorization**: middleware covers every page and `/api` route except static assets (`admin/middleware.ts:31-66`); every API route handler calls `requireAdmin()` (counted per file; the three `entitlements/*` routes do it inside `runEntitlementMutation`, `admin/lib/referral-rpc.ts:27-32`); the `(admin)` layout and each server page also call `requireAdmin()` (`admin/app/(admin)/layout.tsx`); authorization is `admin_users` membership only, fail-closed to 503 (`admin/lib/auth-guard.ts:14-54`). The service-role key is read only in `admin/lib/supabase-server.ts:33` (server module); no client component imports it. Push broadcast send requires typed confirmation of the dry-run device count (`admin/app/api/push-broadcasts/route.ts:52-70`). Feature flags, announcements, referrals and push carry audit trails (`feature_flag_admin_audit`, `announcement_admin_audit`, `referral_admin_audit`, `push_broadcasts.created_by`).
- **Forced update exists** as the `force_update` announcement severity with an arming trigger (0089) and version targeting in `catalog-announcements/index.ts:51-57`; the app sends `X-App-Version` from `--dart-define=APP_VERSION` (`codemagic.yaml:106,321,509`; `app/lib/core/backend/app_version.dart:30-46`).

## 3. Findings

### BE-01 — Production migration state is undocumented for ~32 migrations, including those account deletion depends on
- Severity: S1 (unverifiable critical requirement, until the operator runs §5 check A) · Class: ENV-LIMITATION · Platforms: Backend/All
- User impact: if production lacks `0117_account_deletion_fence` or `20261110124809_deletion_provider_proofs` while `delete-account-immediate` is deployed from the repository, in-app account deletion (an App Store requirement) fails. More generally nobody can say what schema TestFlight 147 is talking to today.
- Evidence:
  - `docs/project/MIGRATION_LEDGER.md:3,13-17` — "single source of truth": applied through **0092**, verified 2026-09-02; "0093–0097 source-only".
  - `supabase/deferred/README.md:56` — "0100, 0101 and 0102 were applied to production … (2026-10-02)", which contradicts the ledger (0093–0099 would have had to be applied too, and the ledger was never updated); same file `:60,85` still says "The active chain ends at 0099".
  - No document records 0103–0117 or any of the 17 timestamped 2026-11 migrations as applied.
  - `delete-account-immediate` / `_shared/account_deletion_adapter.ts` call `account_deletion_accept`, `…_claim_lease`, `…_purge`, `…_bind_email_code`, `…_verify_email_code`, `…_read_challenge` — defined only in `0117_account_deletion_fence.sql` and `20261110124809_deletion_provider_proofs.sql` (grep).
- Root cause: the ledger rule ("deployment state lives here, in one file", ledger `:71-79`) was not followed after September.
- Proposed fix: operator runs §5 check A, updates the ledger table with result and date, lists the gap explicitly. No compatibility impact.
- Verification required after fix: ledger shows the production max version and exact unapplied list; the list matches `supabase db push --dry-run --linked` output.

### BE-02 — No written deploy order / runbook for the 2026-11 backend set; several steps live outside migrations
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: Backend/Admin
- User impact: deploying in the wrong order breaks account deletion, Google sign-up, push retries or admin pages; some required steps (Auth hook, secrets, Vault) are not encoded anywhere a tool would enforce.
- Evidence:
  - Google enrollment: `20261110070552_restrict_new_google_accounts.sql` and `20261110124811_explicit_google_enrollment.sql` create `qirsh_auth_hooks.*` hook functions, but nothing wires them: `supabase/config.toml:278-281` has `[auth.hook.before_user_created]` commented out and no doc names which of the two hooks production should use (grep for `require_google_enrollment_intent` outside migrations finds only SQL tests). Enabling the hook before `google-enrollment` is deployed blocks every Google sign-up; never enabling it leaves the restriction inert.
  - 0117 has hard preconditions that abort the migration: legacy purge queue must be empty (QD096) and deployed function bodies must equal migration text (`0117_account_deletion_fence.sql:27,36-37,94,102`); header line 6-7: "Applying it to production requires the owner's explicit approval."
  - Secrets required by functions and not created by any migration: `ACCOUNT_DELETION_SEALER_KEY`, `ACCOUNT_DELETION_WORKER_SECRET`, `APPLE_TEAM_ID/KEY_ID/CLIENT_ID/PRIVATE_KEY_P8` (`_shared/apple_deletion_gateway.ts:38-47`), `APNS_*`, `GEMINI_API_KEY`, `GOOGLE_MAPS_API_KEY`, `PUSH_BROADCAST_WORKER_SECRET`, `NOTIFICATION_RETRY_WORKER_SECRET`, `ENGAGEMENT_WORKER_SECRET`, `REMINDERS_WORKER_SECRET`, `PURGE_WORKER_SECRET`, `AFFILIATE_WORKER_SECRET`; Vault names `project_url`, `account_deletion_worker_secret`, `push_broadcast_worker_secret`, `engagement_worker_secret`, `notification_retry_worker_secret`, `reminders_worker_secret`, `purge_worker_secret`, `affiliate_worker_secret` (grep of migrations).
  - No CI or Codemagic step deploys functions or migrations (`grep 'functions deploy\|db push'` in `codemagic.yaml`, `.github/workflows`, `tools/` → none), so order is entirely manual.
- Proposed fix: write the order below into a runbook with a check between each step.
  1. Pre: logical backup (see BE-04); §5 checks A–F recorded.
  2. Database: apply every missing migration in filename order (`supabase db push --linked --dry-run` first; for 0117 verify QD096/QD097 preconditions first). Do NOT move `deferred/0118`.
  3. Secrets + Vault entries for every worker that should run (absent secrets leave the worker inert, which is safe).
  4. Functions: deploy all from the repository so `config.toml` `verify_jwt` settings apply; specifically `delete-account-immediate`/`account-deletion-worker` only after 0117 + 20261110124809; `send-push-broadcast` after 20261117010000; `merchant-category-contribution` after 20261116150000/220000; `google-enrollment` before any Auth hook.
  5. Auth hook (owner decision): enable `require_google_enrollment_intent` only after step 4 and only if every installed client that offers Google sign-up calls `google-enrollment`.
  6. Admin panel build (push, shared-learning and flag pages call RPCs from 20261116150000–20261117010000 and 0101).
  7. Mobile: submit only after steps 1–6 are verified.
- Verification required after fix: dry-run on a restored copy of production; post-step checks from §5.

### BE-03 — AI spend has no global ceiling; per-identity caps are bypassable with free anonymous device identities
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: Backend
- User impact: none directly; financial exposure and provider-quota exhaustion (which would then degrade AI parsing for every real user).
- Evidence: `register-device/index.ts:20-24` ("reachable with the public anon key … authenticates nothing: whoever presents an installId gets a fresh secret"), rate limit keyed on the caller-chosen install id (`:62`), so new identities are unlimited. A never-linked device may set its own consent (`set-device-consent/index.ts:9-11`, "a never-linked guest row … keeps working"), and `resolveVerifiedIdentity` accepts unlinked devices (`_shared/ai_endpoint.ts:231-255`, `userId … ?? null`). Each such identity then gets 500 `parse-sms`/day, 50 `bank-discovery`, 200 `enrich-merchant` (Google Places). No global/project-wide counter exists (`grep GLOBAL|global_cap` → none). Model and prompt version are not persisted server-side (no `model_used`/`prompt_version` column in any migration; `model_used` is only returned to the client, `parse-sms/index.ts:473`). Local `config.toml:221-226` also has email sign-up on without confirmations (production setting unknown), which would make per-user caps equally cheap to multiply.
- Proposed fix (smallest): a project-wide daily counter per AI endpoint checked in the same RPC as the per-identity cap, with a configured ceiling; set a provider-side budget/quota alert at Google Cloud. Optionally require a linked user for AI on Android. Compatible with old clients (they already handle `rate_limited`/`upstream_unavailable` as retryable and fall back to local parsing).
- Verification required after fix: Deno test that the global ceiling returns `rate_limited`; operator confirms provider budget alert exists.

### BE-04 — Backup / point-in-time recovery posture is unstated in the repository and the rollback story assumes PITR
- Severity: S2 · Class: ENV-LIMITATION · Platforms: Backend
- User impact: an erroneous migration or operator action on production financial data may be unrecoverable.
- Evidence: `docs/FINAL_RELEASE_READINESS_AUDIT.md:196` — "a rollback would mean restoring from a Supabase point-in-time backup". `docs/PRODUCTION_ROLLOUT_OPERATOR_PACKAGE.md:652` asks to "verify backup/recovery posture (PITR window, snapshot)" but no result is recorded anywhere. Workspace notes outside the repository (owner's session notes, 2026-10-02) record that production had platform backups/PITR **off** and that a manual `pg_dump` was taken before 0100–0102; this is not in the repository and is not verified here. Several migrations are irreversible in practice even with rollback SQL (0102 rollback refuses while awaiting-FX rows exist, `supabase/deferred/README.md:136-137`; 0104 backfill).
- Proposed fix: owner confirms plan tier / PITR / daily backup status (§5 check F), records it in the ledger, and takes and test-restores a logical dump immediately before step 2 of BE-02.
- Verification required after fix: restore of the dump into a scratch project succeeds; retention window written down.

### BE-05 — No backend monitoring or alerting; worker failures are only `RAISE LOG` / `console.log`
- Severity: S2 · Class: CODE-SUPPORTED · Platforms: Backend/Admin
- User impact: a broken cron worker (account deletion recovery, notification retries, push retry) or AI outage goes unnoticed until users report it.
- Evidence: Sentry exists only in the Flutter app (`app/lib/core/backend/sentry_config.dart`, consent-gated); none in `supabase/functions` or `admin/` (grep `sentry` → app only). No health-check, uptime or alert integration anywhere (grep `pagerduty|opsgenie|uptime|healthcheck|/health` → none). Dispatchers fail with `raise log` only (`20261117010000…sql:310-318`; `0098_engagement_worker_secret_auth.sql:57`). `docs/release-process/MASTER-CHECKLIST.md` OPS-01/OPS-02 require these signals and thresholds; the referenced `INCIDENT-AND-RECOVERY.md` / `RELEASE-RUNBOOK` do not exist in `docs/release-process/` (directory is untracked, in progress).
- Proposed fix (smallest): a daily operator query pack (§5 check E) plus Supabase log-based alerts on function 5xx rate and `cron.job_run_details` failures; Google Cloud budget alert (BE-03).
- Verification required after fix: an induced failure (e.g. unset a worker secret on a scratch project) produces an alert.

### BE-06 — Forced-update and "update available" targeting cannot distinguish builds of the same marketing version
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: iOS/Android/Backend
- User impact: if V1 ships as 1.0.0, a `force_update` or `update_available` row aimed at TestFlight 1.0.0 (147) also hits the release build, and vice versa; there is no way to force testers off 147. There is no server-enforced minimum client either.
- Evidence: `catalog-announcements/index.ts:52-57,87-90` compares only `major.minor.patch`; the header is `kAppVersion` = pubspec version before `+` (`app/lib/core/backend/app_version.dart:30-39`; `codemagic.yaml:106` strips the build number). `min_client_build` capability is hard-coded `false` (`20261117000000_transaction_category_source.sql`, capability list).
- Proposed fix: bump the App Store marketing version above 1.0.0 (e.g. 1.0.1) if testers must be separable, or send build number in a second header and compare it. No backend change needed for the first option.
- Verification required after fix: a test announcement with `max_app_version=1.0.0` reaches 147 only.

### BE-07 — Admin panel dependencies: `next@14.2.29` has a critical advisory set; `_next/image` is outside the auth middleware
- Severity: S3 (S2 if the admin panel is ever exposed beyond loopback) · Class: SUSPECTED · Platforms: Admin
- User impact: none while the panel runs only on the owner's machine; if hosted, unauthenticated advisories (image optimizer, server actions, cache poisoning) apply.
- Evidence: `npm audit --omit=dev` → critical `next` (installed 14.2.29), high `postcss`, `nanoid`, `source-map-js`; advisories include unauthenticated Image Optimization issues. `admin/middleware.ts:63-65` excludes `_next/image` from the guard, and `admin/next.config.mjs:3-7` allows remote images from `*.supabase.co` (any Supabase project). Admin login is password-only, no MFA/AAL2 requirement (`admin/app/(auth)/login/page.tsx:38`; no `aal2` check in `admin/lib`, `middleware.ts`). Workspace notes say the production admin runs as a local build bound to 127.0.0.1 (not verifiable here).
- Proposed fix: upgrade `next` to a patched 14.2.x line (or the advised major) and re-run admin tests; narrow `remotePatterns` to the project host; require MFA for `admin_users` (check `aal` in `requireAdmin`). Document "admin is loopback-only" as a release constraint.
- Verification required after fix: `npm audit --omit=dev` clean of critical; admin auth tests (`npm run test:auth`) pass.

### BE-08 — Push auto-retry rollback runbook step 0/6 contradicts the rollback SQL and can break the admin Push page
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Backend/Admin
- User impact: an operator following the runbook during an incident may restore a history function that reads a dropped column, breaking the admin Push history.
- Evidence: runbook `docs/PUSH_BROADCAST_AUTO_RETRY_ROLLBACK_RUNBOOK.md:16-20` says the SQL rollback restores the 160000 body "which has no is_test" and that step 6 is mandatory when 230000 is applied (230000 always precedes 010000 in the chain, so it is always applied). But the rollback file was later changed (merge `b6fc0dad`) and now restores a body **with** `is_test` (`supabase/rollback/20261117010000_push_broadcast_auto_retry_rollback.sql:42`). Step 6 tells the operator to re-apply `history_before_rollback.sql`, which was saved *after* 010000 and references `next_attempt_at` that step 5 drops (`:117-119` admits this and says to use the repository body "instead"). The "Local verification" table (`:126-140`) used a snapshot taken before 010000, which is not what the production procedure produces. It also refers to the migration as "200000" (`:133,135`), an earlier name.
- Proposed fix: remove step 6 (the rollback SQL already restores the correct body) and the step-0 save, or make step 6 "verify `is_test` present"; fix the "200000" naming.
- Verification required after fix: local stack: apply 010000, run steps 1–5 only, then `push_broadcast_test_send_20261116.sql` passes.

### BE-09 — Shared category learning auto-publishes fleet-wide on 6 accounts; accounts may be cheap
- Severity: S3 · Class: PRODUCT-DECISION · Platforms: Backend/All
- User impact: six coordinated accounts can publish a wrong merchant→category mapping to every device, and it outranks the AI category (`20261116190000_shared_mapping_marker.sql:3-7`).
- Evidence: `20261116170000_shared_learning_auto_approve.sql:4-9` (≥6 distinct users, ≥75%); contribution requires a signed-in user (`merchant-category-contribution/index.ts:85-86`) with 100/day each (`:28`). Cost of an account depends on production Auth settings (local `config.toml:221-226`: email sign-up without confirmation). Mitigations present: no auto-approve over an existing approved/curated mapping; admin can revoke.
- Proposed fix: owner decision — keep, raise threshold, or require account age / Apple-only for votes; ensure production email confirmation is on.
- Verification required after fix: n/a (decision) / §5 check D for auth settings.

### BE-10 — Engagement triggers fire two HTTP calls per transaction row write
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Backend
- User impact: a large import or sync burst (thousands of rows) produces thousands of `evaluate-budgets`/`evaluate-gamification` invocations and full-row payloads queued in `pg_net`; cost and latency, possible worker backlog.
- Evidence: `0057_engagement_webhooks.sql:47-51,95-97` (`AFTER INSERT OR UPDATE … FOR EACH ROW`), body is `row_to_json(NEW)` + `OLD` (`0098_engagement_worker_secret_auth.sql:61-75`). Inert while `engagement_worker_secret` is absent from Vault (`:56-58`).
- Proposed fix: statement-level trigger with transition tables or a debounced queue; or leave the Vault secret unset for V1 (record the decision).
- Verification required after fix: import of 1,000 synthetic rows on a local stack produces a bounded number of calls.

### BE-11 — 0104 backfill holds strong locks on all 17 synced tables in one transaction
- Severity: S3 · Class: CODE-SUPPORTED · Platforms: Backend
- User impact: if 0104 is still unapplied in production, sync/writes block for the duration of the backfill.
- Evidence: `0104_sync_seq_columns.sql` — `ADD COLUMN` + non-concurrent `CREATE INDEX` on 17 tables, then per table `DISABLE TRIGGER USER` / full `UPDATE` / `ENABLE TRIGGER USER` inside one `BEGIN … COMMIT`.
- Proposed fix: measure row counts first (§5 check A2); apply in a quiet window. Small today if the user base is small.
- Verification required after fix: recorded row counts and apply duration.

### BE-12 — Documentation and header drift around deployment state
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: Backend
- Evidence: `supabase/deferred/README.md:60,85` "active chain ends at 0099"; `MIGRATION_LEDGER.md:17,30` calls the telemetry migration 0099 (now `deferred/0118`); `supabase/config.toml:448-453` says `process-notification-retries` is gated by `SUPABASE_SERVICE_ROLE_KEY`, code uses `NOTIFICATION_RETRY_WORKER_SECRET` (`process-notification-retries/index.ts:20-28`); `account-deletion-worker/handler.ts:1` "DRAFT - NOT DEPLOYED" while 0117 schedules it every 5 min (`0117…sql:6634`) — the ledger rule forbids per-file deployment claims. `catalog-flags/index.ts:40` and `catalog-announcements/index.ts:42` return raw `error.message` to anonymous callers. Edge imports `esm.sh/@supabase/supabase-js@2` unpinned in 11 files (locked to 2.110.2 only if the deploy honours `deno.lock`).
- Proposed fix: update those texts; return a generic error; pin the import.

### BE-13 — No server-side feature kill switch for AI or capture endpoints; only client-honoured flags
- Severity: S4 · Class: CODE-SUPPORTED · Platforms: Backend
- Evidence: `_shared/feature_flags.ts:3` `resolveUserBooleanFlag` has no caller (grep). Safe disablement today = unset the provider secret (AI) or undeploy the function; client flags (`catalog-flags`) only affect clients that honour them. Not documented as the incident procedure.
- Proposed fix: document "unset `GEMINI_API_KEY` / `GOOGLE_MAPS_API_KEY`" as the AI kill switch in the incident runbook.

## 4. Coverage rows

| Feature | Platform | Critical scenario | Code/component | Verification method | Result | Evidence | Issue |
|---|---|---|---|---|---|---|---|
| Migration chain integrity | Backend | gapless, rollback coverage, DEFINER lockdown | supabase/migrations | `check_migrations.sh` | PASS | §1 | — |
| Production migration state | Backend | repo vs prod ledger | MIGRATION_LEDGER.md | document review | FAIL | ledger :13-17 vs deferred README :56 | BE-01 |
| Expand/contract for 2026-11 | Backend | old client against new DB, new client against old DB | qirsh_server_capabilities | code inspection | PASS | §2 | — |
| Destructive DDL in recent set | Backend | data loss on apply | 0100–0117, 2026* | grep | PASS | §2 | — |
| Lock risk | Backend | long locks on apply | 0104, 0095 | code inspection | NOT TESTED (no prod sizes) | 0104 | BE-11 |
| Deploy order documented | All | db → functions → admin → mobile | docs | document review | FAIL | none exists | BE-02 |
| Google sign-up hook | Backend | hook wired as intended | config.toml, 20261110* | code inspection | FAIL (unwired/undocumented) | config.toml:278-281 | BE-02 |
| Worker auth | Backend | raw-secret endpoints fail closed | 10 functions | code inspection + deno test | PASS | send_test 23/23; handler_test 7/7 | — |
| User-facing function auth | Backend | verified identity, consent server-side | _shared/ai_endpoint.ts | code inspection | PASS | :213-285 | — |
| AI cost control | Backend | spend bounded | parse-sms, register-device | code inspection | FAIL | register-device :20-24,62 | BE-03 |
| AI dependency failure | Backend | timeout/5xx/malformed | parse-sms | code inspection | PASS | :26,:339,:375-379,:503-516 | — |
| Push auto-retry overlap | Backend | no double send, lease safety | 20261117010000, send.ts | code inspection + deno test | PASS | §2 | — |
| Push auto-retry rollback | Backend/Admin | runbook realism | runbook | document vs SQL review | FAIL | runbook :16-20,:109-119 | BE-08 |
| Notification retry overlap | Backend | SKIP LOCKED claim | 0052, process-notification-retries | code inspection | PASS | 0052:237-249 | — |
| Account deletion worker | Backend | scheduled recovery runs | 0117, account-deletion-worker | code inspection + deno test | NOT TESTED (deploy state unknown) | handler_test 7/7 | BE-01, BE-12 |
| Forced update | All | target old builds | catalog-announcements | code inspection | FAIL (version-only) | :52-57 | BE-06 |
| Admin route authz | Admin | every route/page guarded | middleware, auth-guard | code inspection | PASS | §2 | — |
| Admin service key server-only | Admin | no client exposure | supabase-server.ts | grep | PASS | :33 | — |
| Admin dangerous action confirm | Admin | push broadcast | push-broadcasts/route.ts | code inspection | PASS | :52-70 | — |
| Admin dependency security | Admin | known CVEs | package-lock | `npm audit --omit=dev` | FAIL | 1 critical, 3 high | BE-07 |
| Monitoring/alerting | Backend | failures observable | all | grep | FAIL | none | BE-05 |
| Backups/PITR | Backend | recovery possible | — | document review | NOT TESTED | — | BE-04 |
| Safe disablement | Backend | turn off AI remotely | parse-sms | code inspection | PASS (secret removal; undocumented) | :337-340 | BE-13 |

## 5. Could not verify here (exact read-only operator checks)

No production access was used. Run these against the production project (SQL editor or `psql` with a read-only role) and record results in `docs/project/MIGRATION_LEDGER.md`.

**A. Migration ledger**
```sql
select version, name from supabase_migrations.schema_migrations order by version;
-- expected repo set: 0001..0117 and 17 versions 20261105122315..20261117010000; 0118 must be ABSENT
select version from supabase_migrations.schema_migrations where version = '0118';  -- 0 rows
```
A2. Lock-size inputs: `select relname, n_live_tup from pg_stat_user_tables where relname in ('user_transactions','user_accounts','user_categories','coupons','push_broadcast_deliveries') order by 2 desc;`
A3. 0117 preconditions (only if 0117 is unapplied): row count of the legacy purge queue table named in `0117…sql:94` = 0; `select jobname, schedule, command from cron.job where jobname = 'purge-scheduled-deletions-job';`
A4. Then, from a workstation with the DB password: `supabase db push --linked --dry-run` — the proposed list must equal A's gap.

**B. Functions**: `supabase functions list --project-ref <ref>` — compare names/updated times with the 34 directories; confirm `verify_jwt` false only for the 10 listed in `config.toml:415-502` (Dashboard → Edge Functions → each function's "Enforce JWT").

**C. Secrets / Vault (presence only, never values)**: `supabase secrets list --project-ref <ref>` (names in BE-02); `select name from vault.secrets order by name;`.

**D. Auth config**: Dashboard → Auth → Hooks (is `before_user_created` set, and to which `qirsh_auth_hooks` function?); Providers → Email: sign-ups allowed? confirmations required?; anonymous sign-ins off.

**E. Cron and worker health**
```sql
select jobid, jobname, schedule, active, command from cron.job order by jobname;
select j.jobname, d.status, count(*), max(d.start_time) from cron.job_run_details d join cron.job j using (jobid)
 where d.start_time > now() - interval '24 hours' group by 1,2 order by 1,2;
select status, count(*) from public.push_broadcast_deliveries group by 1;   -- if table exists
select count(*) from public.notification_retry_queue where next_attempt_at < now() - interval '1 hour';
```

**F. Flags and backups**: `select key, is_active, rollout_percent, value from public.feature_flags order by key;` (compare with intended V1 activation matrix); Dashboard → Database → Backups: plan tier, PITR enabled, retention, last successful backup.

Also not verifiable here: deployed function revisions vs repository; whether the admin panel is loopback-only; Google Cloud budget alerts; real APNs behaviour of auto-retry.

## 6. Manual device test steps you recommend (numbered, with expected outcome)

Run after the BE-02 deploy, on a scratch/staging project first, then production with owner approval.

1. On TestFlight 147 with a synthetic test account, open Settings → Delete account, complete the challenge. Expected: deletion completes; `select count(*) from auth.users where id = '<test uid>'` = 0 within the documented window; `cron.job_run_details` shows `account-deletion-worker` succeeding.
2. On a fresh install, attempt Google sign-up via "Create an account". Expected: succeeds only when the configured hook and `google-enrollment` agree; "Sign in" with an unknown Google account is refused with the hook message if the hook is enabled.
3. Admin: send a push test to the test account, then a real broadcast with typed confirmation; switch the test device to airplane mode during send. Expected: delivered once on reconnect / next scheduled retry; history shows `next_auto_retry_at`, then `sent`; no duplicate banner.
4. Turn Cloud consent off on the test device, then call parse via a bank message. Expected: server returns `consent_required`; app parses locally.
5. Unset `GEMINI_API_KEY` on staging, send a synthetic bank message. Expected: `upstream_unavailable`, local parse fallback, no crash; restore the secret.
6. Create a `force_update` announcement with `max_app_version` set below the installed version. Expected: not shown. Set it equal (1.0.0). Expected: shown on 147 — and on any other 1.0.0 build (BE-06).
7. Old-client check: install the oldest still-distributed TestFlight build against the migrated staging DB; create, edit, delete a transaction and a category. Expected: all succeed (soft delete), no permission errors from 0115.
