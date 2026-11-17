# Version 1 — release plan (rollout and recovery)

Assessed at: `23499229` (HEAD of local branch `release-readiness/v1`; not pushed, built by CI, deployed or submitted). The candidate is `af675aec`; its only difference from `23499229` is one updated test expectation.

This plan follows the stages of [`docs/release-process/RELEASE-RUNBOOK.md`](../../release-process/RELEASE-RUNBOOK.md) and the capabilities table in [`INCIDENT-AND-RECOVERY.md`](../../release-process/INCIDENT-AND-RECOVERY.md). It is written for this release only.

Ground rules for reading it:
- **Every step marked OWNER-AUTHORIZED ACTION touches production or a store. None of them has been performed.** Each needs the owner's explicit authorization at the time; an earlier authorization does not carry over.
- Nothing here has been rehearsed unless the text says so. "Rollback" always names the method and whether it was rehearsed.
- The production state is unknown until section (a) is done (V1-002, V1-023). Several later steps cannot be finalised before then; they say so.
- Facts: audit baseline `ab5dc10a`; final local commit `23499229` (11 fix commits after the baseline, listed in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)); last TestFlight build 1.0.0 (147) from `b6fc0dad` (internal testing only), which contains none of the fixes. Backend and admin code at `ab5dc10a` were byte-identical to `b6fc0dad` (audit F §1). Since then, two backend/admin areas changed: `supabase/functions/process-ios-sms/` (`parse.ts`, `parser_rules.json`, new `declined_cases.json`; commits `d35fc044`, `668f4d64`) and `admin/` (Next.js 14.2.35, remote image hosts removed, image optimization off; `f9c5be75`, `f6dc5076`). No migration was added. The frozen release commit is not chosen yet; re-check this plan against it.
- Gate: `tools/ci_gates.sh` gained a mandatory stage (4d) that runs the six define-gated Flutter suites with synthetic defines (`29cb1819`). The release workflows run `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` before signing, so a release build now also needs that stage to pass. The strict run on `23499229`: see TEST-EVIDENCE.md.

---

## (a) Read-only production comparison — run first

Purpose: close or confirm **V1-002** (migration state unknown for about 32 migrations, including those account deletion depends on) and **V1-023** (backup / point-in-time-recovery status not recorded). Gate G7 and MASTER-CHECKLIST DEPLOY-01 / OPS-06 depend on it.

**OWNER-AUTHORIZED ACTION** (read-only, but it uses production credentials). Run with a read-only role where possible.

Recording rules:
- Save every output to `docs/releases/version-1/evidence/production/` with the date and the operator's initials.
- **Redact secrets**: never paste secret values, keys, tokens, connection strings or the database password. Secret checks are presence-only.
- Do not copy user data. Row counts and object names only.
- Then update `docs/project/MIGRATION_LEDGER.md` with the production max version, the exact unapplied list and the date.

The checks below are copied from audit F §5 ([`evidence/audits/F-backend-ops.md`](evidence/audits/F-backend-ops.md)) without change.

> No production access was used. Run these against the production project (SQL editor or `psql` with a read-only role) and record results in `docs/project/MIGRATION_LEDGER.md`.
>
> **A. Migration ledger**
> ```sql
> select version, name from supabase_migrations.schema_migrations order by version;
> -- expected repo set: 0001..0117 and 17 versions 20261105122315..20261117010000; 0118 must be ABSENT
> select version from supabase_migrations.schema_migrations where version = '0118';  -- 0 rows
> ```
> A2. Lock-size inputs: `select relname, n_live_tup from pg_stat_user_tables where relname in ('user_transactions','user_accounts','user_categories','coupons','push_broadcast_deliveries') order by 2 desc;`
>
> A3. 0117 preconditions (only if 0117 is unapplied): row count of the legacy purge queue table named in `0117…sql:94` = 0; `select jobname, schedule, command from cron.job where jobname = 'purge-scheduled-deletions-job';`
>
> A4. Then, from a workstation with the DB password: `supabase db push --linked --dry-run` — the proposed list must equal A's gap.
>
> **B. Functions**: `supabase functions list --project-ref <ref>` — compare names/updated times with the 34 directories; confirm `verify_jwt` false only for the 10 listed in `config.toml:415-502` (Dashboard → Edge Functions → each function's "Enforce JWT").
>
> **C. Secrets / Vault (presence only, never values)**: `supabase secrets list --project-ref <ref>` (names in BE-02); `select name from vault.secrets order by name;`.
>
> **D. Auth config**: Dashboard → Auth → Hooks (is `before_user_created` set, and to which `qirsh_auth_hooks` function?); Providers → Email: sign-ups allowed? confirmations required?; anonymous sign-ins off.
>
> **E. Cron and worker health**
> ```sql
> select jobid, jobname, schedule, active, command from cron.job order by jobname;
> select j.jobname, d.status, count(*), max(d.start_time) from cron.job_run_details d join cron.job j using (jobid)
>  where d.start_time > now() - interval '24 hours' group by 1,2 order by 1,2;
> select status, count(*) from public.push_broadcast_deliveries group by 1;   -- if table exists
> select count(*) from public.notification_retry_queue where next_attempt_at < now() - interval '1 hour';
> ```
>
> **F. Flags and backups**: `select key, is_active, rollout_percent, value from public.feature_flags order by key;` (compare with intended V1 activation matrix); Dashboard → Database → Backups: plan tier, PITR enabled, retention, last successful backup.
>
> Also not verifiable here: deployed function revisions vs repository; whether the admin panel is loopback-only; Google Cloud budget alerts; real APNs behaviour of auto-retry.

Notes on these checks:
- Check B: the repository has 33 function directories under `supabase/functions/` (34 including `_shared`, which is not a function). Compare against 33.
- Check B, `process-ios-sms`: record its deployed update time. The repository version changed in `d35fc044` and `668f4d64`; the deployed revision is unknown, so whether the deployed function contains any declined-message handling is unknown.
- A4 (`db push --dry-run`) applies nothing, but it needs the database password; treat the password as a secret.
- `cron.job.command` (checks A3, E) may contain function URLs; check that no secret is embedded before saving the output.
- The `--project-ref` value is not a secret but should not be published.

Additional read-only checks from audit E §5 (security state; same recording rules):
- Tables without row-level security in `public` and `account_fence` (expect 0 rows); SECURITY DEFINER functions executable by `anon`/`authenticated` (review each); SECURITY DEFINER functions without a pinned `search_path` (expect 0); `storage.buckets` (`backups` and `profile-photos` must be `public=false`). The exact SQL is in audit E §5 item 1.
- Owner: Google Cloud billing tier for the project that holds `GEMINI_API_KEY` (policy claims a paid tier), and whether a budget alert exists (V1-022).
- Owner: Codemagic — whether the `admob` group or `ADMOB_*` values are attached to the workflow that will build the store artifact (in `codemagic.yaml`, `ios-signed` attaches only `supabase`; `ios-signed-release` and `android-release` also attach `admob`); the resolved `QIRSH_GOOGLE_AUTH_ENABLED` / `QIRSH_EMAIL_AUTH_ENABLED` values (V1-016); whether `SENTRY_DSN` is set.
- Owner: App Store Connect processing email for build 147 (ITMS-91053, V1-008). The missing declarations were added locally in `d70ba396`; build 147 does not contain them.

Outcome to record:

| Question | Answer (fill in) | Closes |
|---|---|---|
| Production max migration version; exact list of unapplied migrations | | V1-002 |
| Is `0118` absent? | | V1-002 |
| Are `0117_account_deletion_fence` and `20261110124809_deletion_provider_proofs` applied? | | V1-002 |
| Deployed function list vs the 33 function directories; `verify_jwt` settings | | V1-002, V1-021 |
| Deployed `process-ios-sms` update time (before the step 3a deploy) | | V1-001 |
| Secrets and Vault names present / missing | | V1-021 |
| Auth hook state; email sign-up and confirmation settings | | V1-021, V1-022 |
| Cron jobs and 24-hour run status | | V1-024 baseline |
| Production flag values | | ARCH-04 |
| Plan tier, PITR on/off, retention, last successful backup | | V1-023 |

---

## (b) Backend deploy order — database → secrets/Vault → functions → Auth hook → admin → mobile

Source: audit F BE-02, which proposed this order. No CI or Codemagic step deploys migrations or functions; every step is manual. **Every step below is an OWNER-AUTHORIZED ACTION.** Stop at the first failed verification and go to section (h); do not continue past a failed step.

### Step 0 — Before anything changes
1. Section (a) complete and recorded.
2. Take a logical dump of production (`pg_dump`) and test-restore it into a scratch project. This is the only recovery point this plan can count on until PITR status is known (V1-023). Record dump time, size and restore result. Not yet done; never rehearsed.
3. Rehearse the full migration set from the production max version onward on a local stack or a restored copy — never on production data. Not yet done.
4. Choose a quiet window (migration 0104 locks 17 tables, see step 1).

### Step 1 — Database migrations
- What is involved, as far as the audit established: the repository holds `0001`–`0117` plus 17 timestamped migrations `20261105122315` … `20261117010000`. The ledger records production as applied through `0092` (verified 2026-09-02); `supabase/deferred/README.md:56` says `0100`–`0102` were applied on 2026-10-02, which contradicts the ledger. No document records `0103`–`0117` or any 2026-11 migration as applied. **The exact list is unknown until (a)-A and A4.**
- Order: filename order (`supabase db push --linked`, after the dry run matches the gap). Do **not** move `supabase/deferred/0118`.
- Known hazards (audit F):
  - `0117_account_deletion_fence` aborts unless the legacy purge queue is empty (QD096) and deployed function bodies equal the migration text (QD097); its header says applying it to production requires the owner's explicit approval. Check A3 first.
  - `0104_sync_seq_columns` adds columns, builds non-concurrent indexes and backfills 17 tables inside one transaction with strong locks; sync and writes block for its duration. Use A2 row counts to estimate (V1-050).
  - `0115` revokes DELETE on synced tables; older clients that hard-delete would get permission errors (not verified which builds do; see (c)).
  - No destructive DDL in `0100`–`0117` or the 2026-11 set (audit F §2).
- Verification after each migration: `select version from supabase_migrations.schema_migrations order by version desc limit 5;` shows it; the migration's own checks passed (several raise errors on precondition failure); for capability-adding migrations, `select qirsh_server_capabilities();` shows the new key. After the set: `bash supabase/tools/check_migrations.sh` locally is unaffected; re-run (a)-E for cron jobs created by `0117` (`account-deletion-worker` every 5 min, `account-deletion-purge-expired`).

### Step 2 — Secrets and Vault entries
- Function secrets required and not created by any migration (audit F BE-02): `ACCOUNT_DELETION_SEALER_KEY`, `ACCOUNT_DELETION_WORKER_SECRET`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_P8`, `APNS_*`, `GEMINI_API_KEY`, `GOOGLE_MAPS_API_KEY`, `PUSH_BROADCAST_WORKER_SECRET`, `NOTIFICATION_RETRY_WORKER_SECRET`, `ENGAGEMENT_WORKER_SECRET`, `REMINDERS_WORKER_SECRET`, `PURGE_WORKER_SECRET`, `AFFILIATE_WORKER_SECRET`.
- Vault names: `project_url`, `account_deletion_worker_secret`, `push_broadcast_worker_secret`, `engagement_worker_secret`, `notification_retry_worker_secret`, `reminders_worker_secret`, `purge_worker_secret`, `affiliate_worker_secret`.
- Set only those for workers that should run in V1. An absent worker secret leaves that worker inert, which is safe (audit F). Owner decisions: leave `engagement_worker_secret` unset unless engagement webhooks are wanted (V1-050: two HTTP calls per transaction write); affiliate secrets only if affiliate links are enabled (they are flagged off).
- Verification: presence-only listing ((a)-C); `select name from vault.secrets order by name;`.
- Which of these already exist: **unknown until (a)-C.**

### Step 3 — Edge Functions
- Deploy all functions from the frozen commit so `supabase/config.toml` `verify_jwt` settings apply. Ordering constraints (audit F BE-02):
  - `delete-account-immediate` and `account-deletion-worker` only after `0117` and `20261110124809`.
  - `send-push-broadcast` after `20261117010000`.
  - `merchant-category-contribution` after `20261116150000` / `20261116220000`.
  - `google-enrollment` before any Auth hook (step 4).
- Before deploying: record the currently deployed list and updated times ((a)-B). Which repository commit each deployed function came from is **unknown**; without it, redeploying "the previous version" is not possible (see (h)).
- Verification per function: smoke test with a non-production test account (runbook Stage 4.2); for workers, `cron.job_run_details` shows success within one schedule interval; `verify_jwt` false only for the ten worker functions listed in `config.toml`.

### Step 3a — Deploy `process-ios-sms` for V1-001 (declined purchases) — OWNER-AUTHORIZED ACTION
- Reason: V1-001 (S1). The server parser in the repository rejects a declined, failed, rejected or cancelled purchase (`d35fc044`, `668f4d64`); the deployed function does not have this code unless it was deployed from these commits, which it was not (nothing on this branch has been deployed). Until this step, the server keeps returning such a message as a `processed` payment. V1-001 cannot be closed without this step, a new app build and device verification.
- Position: after step 1 (the function at the frozen commit may rely on migrations) and as part of, or right after, step 3. It does not depend on the app build and does not need to wait for it. It must be done before the release candidate is offered beyond internal TestFlight. If the owner wants the candidate's behaviour against the old server recorded (MDT-IOS-07b, "before the deploy"), install the candidate on internal TestFlight and run that test before this step.
- What it deploys: the whole `process-ios-sms` directory at the frozen commit, not only the declined change. The deployed revision is unknown ((a)-B), so other differences between it and the frozen commit are unknown too.
- What each client gets:
  - Builds containing `668f4d64`: protected before and after this step, because both client import paths re-check a server `processed` result and send a declined capture to Smart Inbox. After this step the server also rejects it.
  - **TestFlight 147 and every older build: no protection from this step.** Before the deploy they import the server's `processed` payment. After it, they receive a rejection, re-parse the capture locally with the old parser (`forceLocalAutoConfirm: true` in `capture_import_service.dart`) and confirm it. Either way the declined purchase is saved as a confirmed payment and counted as spending (REV-03). Only installing a build that contains the fix changes this.
  - Cloud-off users of any build: the server is not involved; only a build containing the fix protects them (local parser).
  - Rows already stored from declined messages stay counted on every build (V1-056).
- Verification (test account; on production only with the owner's authorization for this step):
  1. Run `deno test --allow-all process-ios-sms/` at the frozen commit (125 passed at `668f4d64`, Mac-T).
  2. Deploy; confirm the function's update time changed ((a)-B) and its logs show no errors for 15 minutes of normal traffic.
  3. On an iPhone with a build containing the fix, Cloud on, run MDT-IOS-07b: S04 and S19 through the Shortcut automation → operator confirms (read-only) the server capture record is rejected, not processed; the app shows the item in Smart Inbox; month spend unchanged. S01 and S21 still become confirmed purchases.
  4. Record which notification, if any, the server sends for the rejected capture.
  5. Optional, to document the known gap: repeat S04 on build 147; expected per REV-03: it is still confirmed.
- Rollback: redeploy the previous version from its commit. That commit is unknown today ((h) "Failed function deploy"), so the practical fallback is a forward fix. Not rehearsed.

### Step 4 — Auth hook (owner decision)
- `20261110070552_restrict_new_google_accounts` and `20261110124811_explicit_google_enrollment` create hook functions, but nothing wires them; `config.toml` has `[auth.hook.before_user_created]` commented out, and no document says which hook production should use.
- Enable `require_google_enrollment_intent` only after step 3, and only if every installed client that offers Google sign-up calls `google-enrollment`. Whether build 147 or older builds offer Google sign-up is unknown (V1-016). Enabling it too early blocks every Google sign-up; never enabling it leaves the restriction inert.
- Verification: audit F device step 2 — Google "Create an account" succeeds; "Sign in" with an unknown Google account is refused with the hook message.

### Step 5 — Admin panel
- Build from the frozen commit (push, shared-learning and flag pages call RPCs from `20261116150000`–`20261117010000` and `0101`). The branch moves the admin to Next.js 14.2.35, removes the remote image hosts and turns image optimization off (`f9c5be75`, `f6dc5076`); admin tests 191 pass and `next build` succeeds (Mac-T). At 14.2.35, `npm audit --omit=dev` still lists 25 advisories on `next` (3 critical, 9 high) with no fix on 14.x (REV-07, V1-025). A major upgrade is an owner decision. Keep the admin on loopback only (workspace notes say it runs bound to 127.0.0.1; not verified).
- Verification: sign in; a non-admin is refused; open one restricted route; `/_next/image` does not decode images (optimization off); `npm audit --omit=dev` result recorded.

### Step 6 — Mobile
- Before building: freeze a candidate commit and run `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` on it, including stage 4d (define-gated suites). Then build it through the release workflow (V1-009) and run MANUAL-DEVICE-TESTS on that artifact (V1-055).
- Submit only after steps 1–5 (including 3a) are verified and the observation window in (e) for the backend has passed.

---

## (c) Compatibility window

What installed builds need from the backend:

| Client | Needs | Evidence | Unknown |
|---|---|---|---|
| TestFlight 147 and older TestFlight builds (44…146) | Whatever production has today; they work against it now (no reports in the repository either way). New migrations are additive (capabilities re-declared with all prior keys; new columns nullable; `transaction_category_source` records `unknown` for writers without a token). | Audit F §2 (code inspection). | Whether older builds hard-delete synced rows and break under `0115` (audit F device step 7, not run). Which older builds testers still have (TestFlight builds expire after 90 days). |
| Any build, `process-ios-sms` after step 3a | The server rejects declined purchases. Builds containing `668f4d64` send them to Smart Inbox before and after the deploy. Build 147 and older re-parse a rejected capture locally with the old parser and still confirm it, so they get no protection (see step 3a). | `capture_import_service.dart` (`forceLocalAutoConfirm: true`); REV-03 (code inspection). | Not run on any device. |
| Release candidate | `0117` + `20261110124809` + deletion functions + `APPLE_*` / `ACCOUNT_DELETION_*` secrets for in-app account deletion (an App Store requirement, SRC-APPLE-5.1.1v). Capabilities `merchant_rules_sync`, `profile_photo_backup`, `transaction_category_source` for those features; when absent the client does not use the feature (by design, `server_capabilities.dart`). `GEMINI_API_KEY` for AI parsing (absent → retryable error, local parse fallback). APNs secrets for push. | Audit F BE-01/BE-02, §2. | Everything production actually has: (a). |

Forced update — what exists and its limits:
- A `force_update` announcement severity with version targeting exists (`catalog-announcements`).
- It compares only `major.minor.patch`. TestFlight 147 and a release 1.0.0 build both send `X-App-Version: 1.0.0`, so 147 cannot be targeted separately from the release build (V1-040). Owner option from audit F: ship the store build as 1.0.1, or add a build-number header.
- Catalog and announcements are fetched only by clients with Cloud consent on (`consent_authority.dart`, `EgressClass.catalog` → cloud). **Users with Cloud off never receive a force-update notice or any flag change** (V1-045).
- A cached force-update row is now re-checked against its version range on device (`7597bb42`, V1-039 fixed locally; not in any distributed build). A malformed bound such as `v1.0.1` now fails open: it stops blocking (REV-10). Validate the version format when entering a force-update notice.
- No server-enforced minimum client exists (`min_client_build` capability hard-coded false).
- Conclusion: there is no verified way to move all installed clients off a build. Backend changes must stay compatible with every installed build.

---

## (d) Rollout stages

Each stage is an **OWNER-AUTHORIZED ACTION**. Stop conditions in (e) are checked before widening.

### iOS
1. **Internal TestFlight.** The current `ios-signed` workflow produces internal-testing-only builds (`testFlightInternalTestingOnly: true`) and only runs on the branch `release/ios-beta1-personal-20261013`; it would refuse the release branch (V1-009). Engineering must change the workflow (or the owner must build from that branch) before a candidate build exists at all. Run `MANUAL-DEVICE-TESTS.md` on this build (gate G5). Observation window: see (e).
2. **External TestFlight.** Requires a build that is **not** exported internal-only, plus Beta App Review for the first external build (SRC-APPLE-TESTFLIGHT). `ios-signed-release` can produce such a build but lacks the `ios-signed` checks (V1-009). Its empty `APP_VERSION` was fixed locally in `64e571e5` (V1-010); no CI build has run with the fix. Limited cohort; owner chooses size.
3. **App Store.** Options to limit the first audience, each **unconfirmed** against SOURCES.md (not covered there; check in App Store Connect):
   - Manual release after approval, so the owner chooses the day.
   - Phased release: as generally understood it throttles automatic updates for existing users; for a first release with no existing App Store users it may give no throttling.
   - Availability territories limited to the decided markets (V1-019).
   - Pausing a phased release stops new automatic updates only; users who have the build keep it.

### Android (only if the owner puts Android in V1, V1-004)
1. Play internal track (exempt from Data safety). Requires a release AAB, which has never been built, a sign-in method in the build (V1-004), and an increasing versionCode (fixed at 44 today).
2. Closed testing; if the developer account is personal and created after 2023-11-13, 12 testers for 14 continuous days before production can be requested (SRC-PLAY-TESTING-TRACK; account type unknown).
3. Production. Staged rollout percentages apply to updates only, not the first publish (SRC-PLAY-STAGED-ROLLOUT). Halting stops new users receiving it; installed users keep it.

---

## (e) Monitoring, thresholds, stop conditions, observation windows

### Signals that exist today

| Signal | Where | Limits |
|---|---|---|
| App crash and error reports (Sentry) | Flutter app only | Sent only while Cloud consent is on and the gate permits; scrubbed. Whether `SENTRY_DSN` is set for the release workflow is unknown. Cloud-off users are invisible. |
| TestFlight crash reports and tester feedback; App Store Connect crash data | Apple | Platform feature; depends on users sharing diagnostics. Not checked in this assessment. |
| Edge Function logs and invocation counts | Supabase dashboard | No alerting configured; someone must look. |
| Cron job run history | `cron.job_run_details` (query (a)-E) | Manual query. |
| Push delivery state | `public.push_broadcast_deliveries`, admin Push history | Manual. |
| Notification retry backlog | `public.notification_retry_queue` (query (a)-E) | Manual. |
| AI provider spend | Google Cloud billing console | Budget alert existence unknown (V1-022). |
| User reports | The contact path in (f) | Not yet named. |

### Signals that do not exist (V1-024)
- Any alerting (function 5xx rate, cron failures, queue backlog, AI error rate). Dispatchers fail with `raise log` / `console.log` only.
- Server-side error tracking (no Sentry in `supabase/functions` or `admin/`).
- Uptime or health checks.
- A project-wide AI spend ceiling (V1-022).
- Build-level version identity from clients (V1-040).
- A pre-release baseline for function error rates: there is none, so "clearly above baseline" cannot be judged until one is recorded.

### What to do about it for this release
1. During internal TestFlight, the operator runs the (a)-E query pack and reviews function logs **daily** and records the numbers. These become the baseline.
2. Owner sets a Google Cloud budget alert before external testing (OWNER-AUTHORIZED ACTION).

### Thresholds and stop conditions
From SEVERITY-AND-GATES and the runbook; this release does not loosen them. Stop widening and assess on any of:
- A report of lost, duplicated or wrong financial data (zero tolerance). Note V1-001: declined purchases are counted as spending on every installed build, including 147, and stay counted where already stored (V1-056). The fix exists only in code on this branch; it needs step 3a, a new build and device verification. That alone is an S1.
- A report of one account seeing another's data.
- Evidence of transmission without consent.
- Crash-free sessions below 99% in the observation window (where measurable; Sentry sees only Cloud-on users).
- Any cron job in `failed` status for account deletion, notification retries or push retry for more than one day.
- Function error rate or AI/push failure rate above the recorded baseline by a margin the owner sets before rollout: `______`.
- AI spend above `______` per day (owner sets).
- A store rejection or policy notice.

### Observation windows (proposed; owner confirms or changes before rollout)
- Backend deploy (steps 1–5) before any mobile step: `______` (proposed: 48 hours with the daily query pack).
- Internal TestFlight: `______` (proposed: at least 7 days, daily checks).
- External TestFlight: `______` (proposed: at least 7 days).
- After store release: `______` (proposed: 14 days, daily checks).
- Hours actually covered by a person during each window: `______`.

---

## (f) Incident ownership and user support

To be filled by the owner. These were deliberately left blank; do not invent names.

| Role | Name | Contact | Hours covered |
|---|---|---|---|
| Incident owner | ______ | ______ | ______ |
| Backup contact | ______ | ______ | ______ |
| Operator with production database access | ______ | ______ | ______ |
| Person with App Store Connect access | ______ | ______ | ______ |
| Person with Play Console access (if Android) | ______ | ______ | ______ |

User support path:
- Public support page: `https://qirsh.site/support` (returned 200 on 2026-11-17, audit H).
- The privacy policy §9 lists a contact address for questions and data requests (`docs/legal/PRIVACY_POLICY.md:348-350`).
- In-app support or contact link: not located by any audit; to be confirmed: ______.
- Who reads the support inbox and how often: ______.
- Rule (INCIDENT-AND-RECOVERY): record affected accounts by identifier only; never copy user financial data into tickets or chats.

Incident severity and first steps: INCIDENT-AND-RECOVERY.md (SEV-1 immediate; SEV-2 same day; SEV-3 next working day — targets, not commitments).

---

## (g) Safe feature disablement

Only levers the audits showed are actually read by code. **None has been tested in the off (or changed) position on a device or against production.** A lever that was never tested is not a verified recovery mechanism (INCIDENT-AND-RECOVERY).

### Remote flags (admin Flags page; changes are audited in `feature_flag_admin_audit`) — OWNER-AUTHORIZED ACTION to change
Read by code (audit A §2.4):

| Flag | Default | Effect of turning it off | Tested off? |
|---|---|---|---|
| `enable_banner_ads` + 6 placement flags | false | Banner ads hidden | No |
| `enable_report_ads` | false | Report-export interstitial off | No |
| `enable_coupons` | false | Savings corner and coupon catalog hidden | No |
| `enable_offers_merchants` | false | Merchant pages and personalization toggle hidden | No |
| `enable_affiliate_links` | false | Tracked affiliate click-through off | No |
| `enable_referrals` | false | "Invite friends" hidden | No |
| `capture_ai_fallback_enabled`, `android_capture_ai_enabled` (default **true**), `capture_import_v3`, `capture_notify_v2`, `local_auto_confirm_v2`, `ai_sender_mapping_auto` | mostly false | Capture pipeline switches; changing them changes how messages are parsed, confirmed and notified | No — changing these during an incident is itself a risk |

Limits that apply to every flag:
- Flags reach only clients with **Cloud consent on**; Cloud-off users keep their bundled or cached values (V1-045).
- They take effect after the client's next catalog fetch and cache expiry (interval not established by the audits).
- `enable_proof_autocommit` is blocked from being armed server-side (`0101`); it is not a lever.

**Not levers — read by no code (V1-043):** `enable_goals`, `enable_announcements`, `enable_savings_claims`, `enable_offers_personalization`, `ledger_dual_write`, `ledger_pull_sync`, `ledger_push_sync`, `smart_inbox_pull_sync`, the five `planning_*_sync` flags, `capture_direct_ledger_write`, `capture_notify_shared_ids`. Turning them off does nothing; sync is compiled on and gated by consent and capability.

### Server-side levers — OWNER-AUTHORIZED ACTION
- **Unset `GEMINI_API_KEY`**: `parse-sms` returns `upstream_unavailable` (retryable) before any spend; clients fall back to local parsing (audit F, code inspection `parse-sms/index.ts:337-340`). Not tested (audit F device step 5 proposes testing on staging). Effect on `bank-discovery` and the `process-ios-sms` AI path was not established.
- **Unset `GOOGLE_MAPS_API_KEY`**: intended to stop Places enrichment; behaviour not established by the audits.
- **Remove a worker's Vault secret**: the dispatcher makes no call and fails closed (audit F, push broadcast and engagement dispatchers). Tested only by Deno unit tests for push broadcast (weak/missing secret never authenticates).
- **Deactivate a cron job** (`cron.job.active`): available in Postgres; not rehearsed.
- **Disable the Auth hook**: reverts Google sign-up restriction; not rehearsed.
- There is no server-side kill switch for the capture endpoints (BE-13); the remaining option is undeploying a function, which breaks every client that calls it.

---

## (h) Recovery

General facts (INCIDENT-AND-RECOVERY): installed apps cannot be recalled; device databases migrate forward only (local schema is v43 since build 147); the fix for a bad build is a new build with a higher build number, tested as an upgrade from the bad build.

### Failed migration
- During apply: stop at the first failure. Precondition aborts in `0117` (QD096/QD097) leave nothing applied. Whether a failed migration leaves partial state depends on whether it ran in one transaction; `0104` uses an explicit `BEGIN … COMMIT`. Check `schema_migrations` and the object the migration creates before doing anything else.
- After apply, if it is wrong:
  - **Rollback files exist** for every migration from `0084` on, including all 2026-11 migrations (`supabase/rollback/`; lint: 0 missing, 1 deferred). Method: run the matching `*_rollback.sql` in reverse order, **OWNER-AUTHORIZED ACTION**.
  - **None has been rehearsed** against production-shaped data. The only recorded local verification is for the push auto-retry rollback (2026-11-16). Its runbook contradicted the rollback SQL; `f9c5be75` corrected the runbook on this branch to match the SQL (V1-049, document only). The rollback itself is still unrehearsed.
  - Some are not reversible in practice: the `0102` rollback refuses while awaiting-FX rows exist; the `0104` backfill cannot be meaningfully undone. Any data written in the new shape since apply may block or be lost by a rollback.
  - Preferred path: a **forward-fix migration**, rehearsed on a local stack first.
- Whole-database restore: from the step-0 `pg_dump` (if taken and test-restored) or from platform backups/PITR. **PITR availability is UNKNOWN until (a)-F is checked.** Workspace notes outside the repository say platform backups/PITR were off on 2026-10-02; not verified. Any whole-database restore loses everything written after the restore point; last resort, OWNER-AUTHORIZED ACTION.

### Failed function deploy
- Method: redeploy the previous version from its commit (`supabase functions deploy <name>` from that checkout), OWNER-AUTHORIZED ACTION.
- Feasible only if (1) the previous source commit is known — today it is not; (a)-B records names and update times only — and (2) the database shape the old version expects still exists.
- Not rehearsed.
- Alternative: deploy a forward fix; or, for AI functions, unset `GEMINI_API_KEY` (section g).

### Failed Auth hook
- Method: remove the hook in Dashboard → Auth → Hooks, OWNER-AUTHORIZED ACTION. Sign-ups blocked in the meantime are not recovered automatically; affected users retry. Not rehearsed.

### Failed admin deploy
- Method: redeploy the previous build from its commit. The admin runs as a local build (not verified); recovery is rebuilding the previous commit on that machine. Not rehearsed.

### Bad mobile build
- **Internal or external TestFlight:** expire the build in App Store Connect (stops new installs and eventually stops it launching for testers; does not repair data), then ship a forward-fix build. OWNER-AUTHORIZED ACTION.
- **App Store:** pause phased release if one is running (affects automatic updates only); remove the version from sale if needed (stops new downloads, does not affect installed copies; App Store Connect feature, not covered by SOURCES.md — unconfirmed); ship a forward-fix build through review. OWNER-AUTHORIZED ACTION.
- **Play (if Android):** halt the staged rollout; ship a higher versionCode (requires fixing the fixed versionCode first). OWNER-AUTHORIZED ACTION.
- Remote flags help only for flag-gated features, only for Cloud-on users, and were never tested off (section g).
- A device-database problem can only be fixed by a new build with a further migration; never ship a build that lowers the schema version or build number.
- Forward fix time: build, TestFlight processing, and for App Store users, App Review. No measured duration exists.

### Data already sent to a third party
- Cannot be recalled. Contain (stop the egress path first, e.g. unset `GEMINI_API_KEY`), then follow INCIDENT-AND-RECOVERY response steps. Legal and store notification duties are for the owner to decide with advice.

---

## Status

| Item | State |
|---|---|
| (a) production comparison | Not run |
| Step 0 dump and rehearsal | Not done |
| Steps 1–6 deploy | Not done |
| Step 3a `process-ios-sms` deploy (V1-001) | Not done |
| Strict gate on a frozen candidate, release-workflow build | Not done (strict run on `23499229`: see TEST-EVIDENCE.md; no CI or signed build) |
| Observation windows and thresholds marked `______` | Owner to set |
| (f) owners and contacts | Owner to fill |
| Any lever in (g) tested | No |
| Any recovery in (h) rehearsed | No |
