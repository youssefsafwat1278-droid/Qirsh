# Version 1 — release plan (deployment, rollout and recovery)

Rewritten 2026-11-17 (round 2) by a documentation agent (Claude Opus 5.5) from [`evidence/ROUND2-FACTS.md`](evidence/ROUND2-FACTS.md), [`evidence/production-comparison.md`](evidence/production-comparison.md), the final independent review [`evidence/audits/K-final-independent-review.md`](evidence/audits/K-final-independent-review.md) (§H, §J, FR-04, FR-05, FR-07, FR-10), reviews L, N, O, P, Q and R (R is the review of the final parser commit, [`evidence/audits/R-review-of-tenth-parser-commit.md`](evidence/audits/R-review-of-tenth-parser-commit.md)), the backend audit F, and a code check of the three functions named below. Updated the same day for the final candidate.

**Candidate.** "The final candidate" in this plan means the final candidate commit recorded in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) (`50957c06` at the time of writing). The final parser commit was reviewed by reviewer R: **accept with follow-up**, no S1, nothing worse than the audit baseline on the device or the effective iOS-Cloud path, with open defects carried from the baseline (RR-01) and more correct messages sent to review (RR-02, RR-03). The parser commit before it was rejected by review Q. A review is by an AI agent and is not an approval. The owner has not chosen a release commit; whether to ship this parser is decision B28.

**Nothing in this plan has been executed.** No function was deployed, no flag changed, no grant revoked, no build uploaded. The owner has accepted no limitation and approved no scope proposal; every recommendation below is a proposal.

How production changes are approved: production mutations are collected into **one action package** (section d). The owner approves or edits that package as a whole when it is ready. Approval covers the listed steps, in order, within the package's stated stop conditions; anything listed as excluded is not covered. Read-only checks already authorized remain valid within their scope.

---

## (a) Deployed state versus the candidate

Source: [`evidence/production-comparison.md`](evidence/production-comparison.md) (read-only, 2026-11-17; functions compared against `af675aec`, then database facts read through the attached connector). Nothing below was re-queried for this rewrite.

| Area | Production | Candidate | Consequence for this release |
|---|---|---|---|
| Migrations | Ledger lists 134: `0001`–`0117` and 17 timestamped through `20261117010000`; deferred `0118` absent | Same 134 files | **No migration is needed.** V1-002 closed for the ledger. The ledger holds names, not content (see unknowns) |
| Edge Functions deployed | 28 of the 33 in the repository | 33 | The 5 not deployed are the 4 affiliate functions and `parser-test` (decision D-14). Not proposed for deployment |
| Identical functions | 22 (list in the comparison §1) | — | Not proposed. **Except `parse-sms`**: identical at `af675aec`, changed since (see next row) |
| Changed after the comparison | — | `parse-sms` (`money.ts` amount grounding, `0de54a2b`) and `process-ios-sms` (`parse.ts`, `parser_rules.json`) changed again after `af675aec`, as did `_shared/ai_candidate_validator.ts` | Code check (import closure of every function under `supabase/functions/`): only `parse-sms` and `process-ios-sms` import `_shared/ai_candidate_validator.ts` or `process-ios-sms/parser_rules.json`. No other function is affected by the later parser commits |
| `process-ios-sms` | v27, deployed 2026-11-16 08:25 UTC; differs in `parse.ts`, `parser_rules.json` | Declined/failed/reversed handling (V1-001) and later parser rounds | In the deployment set |
| `account-deletion-worker` | v5, deployed 2026-11-15 07:55 UTC; its `_shared/storage_erasure.ts` erases only the `backups` bucket | Erases `backups` and `profile-photos` (`9e19c3e4`, 2026-11-16) | In the deployment set (V1-062, FR-04) |
| `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, `process-notification-retries` | Deployed before the push-sender refactor `79a063d8` | `_shared/apns.ts` refactored to `sendApnsAlert` | **Not proposed**: intended as behavior-preserving; no behavior need established (equivalence also not proven) |
| Secrets (names only) | 23 set, including `GEMINI_API_KEY`, `APNS_*`, `APPLE_*`, `ACCOUNT_DELETION_SEALER_KEY`, `ACCOUNT_DELETION_WORKER_SECRET` | — | Every secret the three proposed functions read is set (checked against their import closures, below). `GEMINI_SMS_MODEL`, `GEMINI_MODEL`, `GEMINI_SHADOW_API_KEY`, `GOOGLE_MAPS_API_KEY` are unset; defaults apply. Nothing proposed |
| Feature flags | **All 8 advertising flags ON at 100%**; `local_auto_confirm_v2`, `capture_ai_fallback_enabled` off | Client defaults seed every ad flag off (D-19) | Configuration item, decision-dependent (section c) |
| Scheduled jobs | `account-deletion-worker` every 5 minutes, active; 8 others listed in the comparison §4.2 | Same schedule (`0117`, line 6634) | See note on Vault below |
| Backups | `pitr_enabled: false`, `backups: []` | — | **No verified way to restore the database** (V1-023). Section (c) |
| Storage buckets | `backups` (private), `profile-photos` (private), `coupon-assets` (public) | Same | — |
| Advisor | 2 `SECURITY DEFINER` trigger functions executable by `anon`; 26 functions with mutable `search_path`; leaked-password protection off | — | Section (c) |

Note on the deletion worker. The cron job calls `public.run_account_deletion_worker()`, which posts to the worker **only if Vault holds `project_url` and `account_deletion_worker_secret`**; otherwise it logs "worker secret not configured" and returns (`0117_account_deletion_fence.sql`, the function above line 6630). Vault contents are unknown, and cron run history was not queried. So "the outdated worker runs every 5 minutes" is established for the schedule, not for actual worker runs.

### Still unknown

| Item | Why it matters here | How it can be learned (read-only) |
|---|---|---|
| Vault entries (`project_url`, `account_deletion_worker_secret`, other worker secrets) | Whether the deletion worker and other dispatchers actually run | `select name from vault.secrets order by name;` (names only) |
| Auth hook wiring, email sign-up and confirmation settings | Google sign-up restriction (V1-016), cost of new accounts (BE-03, BE-09) | Dashboard → Auth → Hooks; Providers → Email |
| Cron run history and failures | Whether workers succeed; baseline for monitoring | `cron.job_run_details` for the last 24 hours (query in audit F §5 check E) |
| Whether applied migration content equals the files | The ledger holds names only | A schema-only comparison. Note: the comparison avoided the CLI's database commands because they create a temporary login role in production |
| Codemagic variable values (AdMob IDs, sign-in switches, `SENTRY_DSN`) | Whether a release build would render ads; which providers ship | Codemagic UI, by the owner |
| Admin panel deployment and exposure | V1-025: Next.js 14.2.35 still carries advisories | Owner |
| Provider-side daily backups beyond what the API lists | V1-023 | Dashboard → Database → Backups |
| Which commit each deployed function was built from | Undo of a deploy (section b, "undo") | Repeat the normalized bundle comparison against the proposed undo source (package step P0) |

---

## (b) Smallest justified deployment set

Three Edge Functions. No migration, no secret change, no other function. Each row was checked against the code: import closure, environment variables read, `supabase/config.toml`, and what installed clients call.

| | `account-deletion-worker` | `process-ios-sms` | `parse-sms` |
|---|---|---|---|
| **Why** | V1-062 / FR-04 (S2): the deployed worker does not erase `profile-photos` | V1-001 (S1), server side: the deployed function accepts declined/failed purchases as `processed` payments and takes limit or balance figures as amounts (V1-078); ten parser rounds since (R: server wrong total-changing outcomes 375 → 63 on 1,758 synthetic messages) | V1-060: the AI fallback can return an AI amount not found in the text; the candidate drops an ungrounded amount and falls back to the text amount (`parse-sms/money.ts` `groundedModelAmount`) |
| **Evidence production differs** | Comparison §1: deployed v5 differs in `_shared/storage_erasure.ts` | Comparison §1: v27 differs in `parse.ts`, `parser_rules.json`; candidate changed again after the comparison (FR-07) | Identical at `af675aec`; changed after (`0de54a2b`, and `_shared/ai_candidate_validator.ts` in later commits) — K §H, FR-07 |
| **Depends on — migrations** | None. `profile-photos` bucket (`20261116210000`) and the deletion schema (`0117`, `20261110124809`) are in the production ledger | None | None |
| **Depends on — secrets (names)** | `ACCOUNT_DELETION_WORKER_SECRET`, `ACCOUNT_DELETION_SEALER_KEY`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_P8`, platform `SUPABASE_*` — all listed as set. Vault `project_url`, `account_deletion_worker_secret` — **unknown**; without them the worker is never called | `GEMINI_API_KEY`, `APNS_BUNDLE_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_TEAM_ID`, `ENGAGEMENT_WORKER_SECRET`, platform `SUPABASE_*` — set. `GEMINI_SMS_MODEL` unset (default model applies, unchanged by the deploy) | `GEMINI_API_KEY`, platform `SUPABASE_*` — set. `GEMINI_SMS_MODEL`, `GEMINI_SHADOW_API_KEY` unset (defaults; unchanged) |
| **Depends on — other functions** | None. The same `storage_erasure.ts` already runs in production inside `delete-account-immediate` and `purge-scheduled-deletions` (both identical to the candidate) | None at deploy time. Deploy from the same commit as `parse-sms` so both bundle the same validator and rules (consistency, not a hard dependency) | As left |
| **Depends on — code state** | None: unchanged since `9e19c3e4`, so it does not wait for the parser work | **Review condition met in part:** review R of the final parser commit `50957c06` exists and found no S1 regression. **Still required:** (1) the strict gate at the final candidate (FR-07; still pending in TEST-EVIDENCE.md); (2) the owner's decision on the remaining RR-01 defects and on the review-volume cost (DECISIONS-NEEDED B28–B30); (3) **ship together with the new app build** (V1-087): R measured the server alone rejecting 21 completed messages (V1-088) and reading `Cashback reversal … deducted` as a refund (V1-089); only the new device build recovers those into review | Same commit as `process-ios-sms`, same timing |
| **`verify_jwt`** | `false` in `config.toml` (cron-only, own secret); deploying from the repository applies it | Default (gateway JWT on) | Default (gateway JWT on) |
| **Compatibility — build 147 and older** | Not called by any client (pg_cron only). No effect | Build 147 handles `type: refund` (K §A3). After the deploy, build 147 receives the stricter rejections (declined, failed, informational, and the 21 completed messages the final server rejects with no AI), then **re-parses locally with its old rules and confirms** (`forceLocalAutoConfirm: true`; code inspection). Its outcome for those messages therefore becomes its own old local parse: a declined purchase is still counted as spending (as before the deploy, REV-03), and each of the 21 completed messages gets whatever the baseline device parser gives it. **A new server with build 147 was NOT measured** (R measured only matched pairs); which of the 21 the old parser records correctly, records wrongly or drops is NOT TESTED. A server result build 147 does accept now carries the final server's reading (for example `Cashback reversal … deducted` as `refund`). Refund wording arrives as `refund` instead of `income` for future captures (nets against spend; no stored row rewritten) | Response shape unchanged (K §H). An ungrounded AI amount is replaced by the text amount. Build 147 calls `parse-sms` only with AI consent on |
| **Compatibility — the candidate** | No client interaction | Designed for it. Before the deploy, the candidate re-checks server results on both import paths and does not confirm a server result whose direction contradicts its own parse; refund wording from the old server arrives as `income` (temporary path difference, K §A3, S3) | Compatible; the candidate also validates AI output itself |
| **Verification after** | (1) `supabase functions list`: new version, new update time. (2) Function logs: no errors over the next two cron intervals. (3) Read-only: `cron.job_run_details` for `account-deletion-worker` succeeded since the deploy. (4) Read-only orphan count (below) repeated 24 hours later: does not grow. (5) If the package includes it: delete a disposable synthetic test account that has a synthetic profile photo, then a read-only count of objects under that account's `<uid>/` prefix in both buckets returns 0 (this exercises the inline path; the worker-only path cannot be forced without fault injection) | (1) Version and update time changed. (2) Logs: no new error class for 30 minutes of normal traffic. (3) Synthetic test account on a candidate build, Cloud on: S04 and S19 (MANUAL-DEVICE-TESTS 0.4) → server status `rejected`, item in Smart Inbox, spend unchanged; S21 and a purchase carrying an "available limit" line → `processed` and recorded (MDT-IOS-07b, -07d). Read-only query of that test account's capture statuses only | (1) Version changed. (2) Logs: no new error class. (3) Synthetic test account, AI consent on: paste a synthetic purchase; the recorded amount equals the amount in the text |
| **How to undo; rehearsed?** | Redeploy the previous source: believed to be `9e19c3e4^` (the deployed v5 differs from the candidate only in `storage_erasure.ts`). Confirm in P0 by repeating the normalized comparison of the downloaded v5 bundle against that commit. Undoing re-opens the photo gap. **Not rehearsed** | Redeploy the previous source: believed to be the audit baseline `ab5dc10a` (backend identical to `b6fc0dad`, the source of build 147; v27 was deployed 08:25 UTC on 2026-11-16, a few minutes after commit `d3a6d539`, the last change to its files before `b6fc0dad`). Confirm in P0 by the same comparison. **Not rehearsed** | Redeploy `af675aec`'s `parse-sms` (the comparison found the deployed function identical to it). **Not rehearsed** |
| **If not done** | A deletion whose storage step the worker performs (the inline run in `delete-account-immediate` failed, timed out or scheduled a retry before `storage_sweep` finished) leaves the user's profile photo in `profile-photos/<uid>/avatar` after the account is gone — provided Vault lets the worker run | The server keeps returning declined purchases as payments. Candidate builds hold them in the Smart Inbox through their own import re-check; build 147 is unprotected either way. Server-side parser fixes (FR-01/02/13, LR-04 limit notices) do not reach any client that relies on the server result. V1-001 cannot be closed | The server AI fallback can still return an ungrounded amount; the candidate re-grounds it on the device, so urgency is lower |

### Profile photos possibly already left behind (FR-04)

Code trace (candidate and deployed share the saga; only the bucket list differs):
- `delete-account-immediate` (already deployed with both buckets) accepts the request and runs the job inline (`handler.ts:176-180`), swallowing errors because "the job is durable and will be resumed".
- The job's stages are `apple_revoke → storage_sweep → sql_purge → auth_delete → terminal_storage` (`_shared/account_deletion_coordinator.ts:126-132`). Both storage stages call `eraseBackupObjects`, which iterates `ERASURE_BUCKETS`.
- If the inline run stops before `storage_sweep` completes, the cron-driven worker resumes the job with its old `['backups']` list: both of its storage stages finish without touching `profile-photos`, the job completes, and the photo stays. If the inline run completed `storage_sweep`, the photo was already removed.
- Completed jobs keep no `uid` (`deletion_job_uid_shape`), so an affected account cannot be traced from the job table; a photo whose owner no longer exists in `auth.users` can be counted.

Proposed **read-only** check (counts only; no object names, no download, no cleanup):

```sql
-- objects in profile-photos whose owner folder has no auth user
select count(*) as orphaned_profile_photos
from storage.objects o
where o.bucket_id = 'profile-photos'
  and not exists (select 1 from auth.users u where u.id::text = split_part(o.name, '/', 1));
-- same for backups, for comparison
select count(*) as orphaned_backups
from storage.objects o
where o.bucket_id = 'backups'
  and not exists (select 1 from auth.users u where u.id::text = split_part(o.name, '/', 1));
-- deletion jobs by state; open jobs whose storage sweep is still to run
select state, count(*) from account_fence.deletion_job group by state;
select count(*) from account_fence.deletion_job
where state <> 'completed' and not ('storage_sweep' = any(completed_steps));
```

A non-zero orphan count can also have other causes (for example a user removed outside the deletion flow); the count does not prove the worker caused it. **Removing any orphaned object is not part of this plan and needs a separate approval.**

### Not proposed, and why

| Functions | Reason |
|---|---|
| `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, `process-notification-retries` | Differ only by the push-sender refactor `79a063d8`; no behavior need established. Deploy only if a later finding needs it |
| The other 21 identical functions (22 minus `parse-sms`) | Identical at `af675aec` (code check above), and no commit up to `50957c06` touches their import closures (`af675aec..50957c06` changes only `_shared/ai_candidate_validator.ts` and its fixture, `parse-sms` and `process-ios-sms`) |
| `affiliate-click-status`, `affiliate-postback`, `affiliate-sync`, `prepare-affiliate-click`, `parser-test` | Not deployed in production, consistent with decision D-14 (affiliate gateway unwired until a network exists); `parser-test` is a test tool |
| "Deploy every function from the frozen commit" (earlier plan) | Withdrawn: it would change 4 functions with no established need and 22 with no difference, and every extra deploy is an extra undo path that has never been rehearsed |

---

## (c) Configuration items that are not code deploys

Each is a separate, decision-dependent item. None is a prerequisite of the three function deploys unless stated.

| Item | Fact | Options | Proposal | Production mutation? |
|---|---|---|---|---|
| **Advertising flags** (`enable_banner_ads`, `enable_banner_dashboard`, `enable_banner_transactions_list`, `enable_banner_reports`, `enable_banner_goals`, `enable_banner_subscriptions`, `enable_banner_achievements`, `enable_report_ads`) | All ON at 100% in production. The recorded decision D-19 seeds every ad flag off and calls activation "a separate owner action"; no record of an activation decision was found. A banner renders only when its flag is on, Cloud consent is on, the build carries compiled `ADMOB_*` defines, the entitlement is inactive and UMP allows requests (K §H). `ios-signed` (build 147) attaches no AdMob group, so 147 cannot show ads; `ios-signed-release` and `android-release` attach the `admob` group. Final review FR-05 rates this S1 for any store build carrying AdMob IDs: ads would render while the privacy policy, consent text, privacy manifest and store answers do not mention them | (1) Turn all eight off before any build with AdMob IDs reaches users. (2) Keep them on and first complete the disclosures (policy, consent line, App privacy details, report-an-ad UI). (3) Build store artifacts without the `admob` group values | Owner decides (DECISIONS-NEEDED B1). Turning flags off reaches every user who could see an ad, because ads already require Cloud consent and flags reach Cloud-on clients (after their next catalog fetch). A read-only look at `public.feature_flag_admin_audit` (flag key, field, new value, date — not the actor) would show when the flags were turned on | Yes. Change through the admin Flags page so `feature_flag_admin_audit` records it |
| **Point-in-time recovery / backup before a change** | PITR off; the API lists no backups (V1-023) | (1) Enable PITR or confirm provider daily backups (plan/cost question for the owner; cost not checked). (2) A logical `pg_dump` before a change. (3) Nothing for this package | The three function deploys change no schema and no stored data by themselves, and their undo is a redeploy, so a dump is **not** proposed for this package. Before any future migration, a restorable recovery point is needed. **A `pg_dump` contains production user data**: if one is taken it stays in protected, access-limited storage, is never loaded into a development or test environment, and is deleted when no longer needed. Rehearsals use synthetic data (section e) | Enabling PITR is a plan change; a dump is a read that creates a copy of user data |
| **Revoke `EXECUTE` from `anon`** on `create_profile_on_signup()` and `feature_flag_audit_append_only()` | Both return `trigger`; PostgreSQL refuses to call a trigger function outside a trigger, so they cannot be invoked through `/rpc` (K §H, FR-09, S4) | (1) Revoke now in production. (2) Revoke in a migration in a later release | Hygiene only. If done now: rehearse on the local stack first (revoke, then create a synthetic user and change a flag on the local stack to confirm both triggers still fire), revoke from `public` as well as `anon` (functions are executable by `public` by default), and add a matching migration file afterwards so the ledger and the files stay equal | Yes |
| **Leaked-password protection** | Advisor reports it off | — | **Not applicable**: the app has no password sign-in (email uses a one-time code) | — |

---

## (d) Action package for approval

**Status: NOT EXECUTED. Nothing in this package has been run.** It becomes ready when the preconditions in P0 hold. The owner approves or edits it as a whole. Approval covers steps P0–P7 below, in this order, within the stop conditions; it does not cover anything under "Excluded".

Operator: `______` (owner fills). Window: `______`. Expected duration (estimate, not measured): about 1–2 hours of operator time for P0–P6 and the first post-checks, then the observation window in P7.

**Preconditions (all must hold; none is a production action)**
1. The final candidate commit is recorded in RELEASE-MANIFEST.md, and the strict gate (`REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`) passed at it, recorded in TEST-EVIDENCE.md (FR-07).
2. Parser conditions, required for P3–P4 only (P1–P2 do not depend on them): (a) an independent review of the final parser commit with no S1 regression — **met by review R of `50957c06`** (not an approval); (b) the owner's decision to ship this parser given the remaining RR-01 defects and the review-volume cost (DECISIONS-NEEDED B28, B29, B30) — **open**; (c) a new app build from the same commit is ready to reach testers in the same window (V1-087), because the server alone rejects 21 completed messages that only the new build keeps for review — **open** (no build exists).
3. A clean checkout of the final candidate commit on the operator's machine; the Supabase CLI linked to the production project (`<production ref>`, not published here).
4. The owner has filled in the ads choice for P5 and the include/exclude choice for P6.

| Step | Action | Exact command or dashboard action | Pre-check | Post-check | Stop if |
|---|---|---|---|---|---|
| **P0** | Read-only pre-checks | `supabase functions list --project-ref <ref>` (record versions: `process-ios-sms` v27, `account-deletion-worker` v5, `parse-sms`); `supabase secrets list --project-ref <ref>` (names only); SQL: `select name from vault.secrets order by name;` (names only); the orphan and deletion-job counts in (b); `cron.job_run_details` for `account-deletion-worker`, last 24 hours; download the three deployed bundles to a scratch folder and repeat the normalized comparison against the final candidate **and** against the proposed undo sources (`9e19c3e4^`, `ab5dc10a`, `af675aec`) | — | Results recorded in `evidence/` with no secret values, no user data, counts only | Deployed versions differ from those in the comparison (someone deployed meanwhile); a required secret name is missing; the deployed bundle matches neither the candidate's predecessor nor the proposed undo source (then the undo source is unknown — decide before continuing) |
| **P1** | Deploy `account-deletion-worker` | From the repository root at the final candidate: `supabase functions deploy account-deletion-worker --project-ref <ref>` (`config.toml` sets `verify_jwt = false` for it) | P0 done | Verification row in (b) items 1–3 within 15 minutes | Deploy error; worker errors in logs; a `failed` run in `cron.job_run_details` for this job |
| **P2** | Read-only orphan count, second reading | The (b) queries again, 24 hours after P1 | — | Count recorded; compared with P0 | Count grows (then the gap is not closed; investigate before anything else) |
| **P3** | Deploy `process-ios-sms` | `supabase functions deploy process-ios-sms --project-ref <ref>` | Preconditions 1–2 hold | Verification row in (b); MDT-IOS-07b and -07d on a candidate build signed into a synthetic test account | Deploy error; a new error class in logs; any synthetic completed purchase (S01, S21, the limit-line sample) neither recorded nor in the Smart Inbox; any synthetic declined sample recorded as spending on the candidate build; the new build cannot be made available to testers in the same window (precondition 2c) |
| **P4** | Deploy `parse-sms` | `supabase functions deploy parse-sms --project-ref <ref>` | P3 verified | Verification row in (b) | Deploy error; a new error class; the synthetic paste records an amount not in the text |
| **P5** | Advertising flags — **only the option the owner selects** | Option A: in the admin Flags page set the eight ad flags off (reason recorded in the audit field). Option B: no action; the owner records that ads stay on and that disclosures must be complete before any build with AdMob IDs ships. Option C: no flag action; store builds are made without `admob` values | Owner's ads decision (DECISIONS-NEEDED B1) | Read-only: `select key, value, rollout_percent, is_active from public.feature_flags where key like 'enable_banner%' or key = 'enable_report_ads';` | Any other flag changed |
| **P6** | Revoke `EXECUTE` — **only if the owner includes it** | SQL editor: `revoke execute on function public.create_profile_on_signup() from public, anon;` `revoke execute on function public.feature_flag_audit_append_only() from public, anon;` | Rehearsed on the local stack as described in (c) | Advisor no longer lists them for `anon`; a new sign-up still gets a profile (observed on the next real or synthetic sign-up) | Any error; any sign-up without a profile → undo with `grant execute … to anon` |
| **P7** | Observe | Daily: function logs for the three functions; `cron.job_run_details` for the deletion worker; the orphan count | — | Recorded daily during the window `______` (proposed: 7 days) | Any stop condition in section (g) |

Undo for P1, P3, P4: redeploy the undo source named in (b) with the same command from a checkout of that commit. None of these undos has been rehearsed.

**Excluded from this package (not approved by approving it):**
- Any migration (none is needed).
- The four push-sender functions, the 21 identical functions, the five undeployed functions.
- Any secret or Vault change; Auth hook wiring; email provider settings.
- Enabling PITR or changing the plan; taking a `pg_dump`.
- Cleanup of orphaned profile photos or backups (separate approval after P0/P2 counts).
- Admin panel deployment (exposure unknown; DECISIONS-NEEDED, Next.js row).
- Any Codemagic run, TestFlight upload, external testing, App Store Connect or Play Console action (a separate package when a release build exists; section f).
- Any change to stored user transactions (historical review is a proposal only, `HISTORICAL-REVIEW-PROPOSAL.md`).

---

## (e) Rehearsal

**Rehearsed, with synthetic data only, on the local stack `qirsh_v1_verify`** ([`evidence/local-stack.md`](evidence/local-stack.md); a disposable stack built from a scratch copy of `supabase/`):
- All 134 migrations apply cleanly to a fresh database, including `0117_account_deletion_fence.sql`.
- Restore followed by cloud sync (V1-020): `restore_then_sync_local_supabase_test.dart` failed on both scenarios with the old code and passed with `0f90003f`, with and without a configured build. The test creates and deletes its own throw-away synthetic users.
- Signed-in simulator runs (files J and M) used the synthetic account `qa+v1@example.test` against this stack.
- No Auth hook or Vault entries are configured on the local stack, so anything that depends on them was not exercised.

**Not rehearsed anywhere:** any function deploy or redeploy (including the undo of P1, P3, P4); any migration rollback SQL; the grant revoke (P6); any flag change; any production step; a database restore.

**Rehearsal data rule (owner's instruction):** rehearsals use synthetic data, or data that is properly protected and sanitized. Production user data is not copied into development or test environments. If production shape is needed, use a schema-only description plus synthetic rows. A production dump, if one is ever taken, stays in protected storage and is never loaded into a development environment.

---

## (f) Mobile

**Build workflow.** `ios-signed-release` was hardened locally in `4fc2ecd6` (V1-009, V1-012): it runs only on a `release/*` branch; it requires `EXPECTED_REVIEWED_CI_SHA` to be a full 40-character SHA equal to `CM_COMMIT` and `HEAD` on a clean tree; it runs the strict gate, then the native XCTest step, then signing, build, IPA verification, and **uploads without submitting** (`submit_to_testflight: false`, no `submit_to_app_store`). It exports for `app_store` distribution, so its build can go to internal and external TestFlight and App Store review (unlike `ios-signed`, whose builds are internal-testing-only). **It has never run on Codemagic.** The native XCTests (194, 0 failures) ran once locally on a simulator at `d830855e`; the XCTest step has never run on Codemagic and can fail for environmental reasons (FR-10). `xcode: latest` is not pinned.

**Codemagic settings the owner must check (names only; values are not recorded here):** group `supabase` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`); group `admob` (`ADMOB_APP_ID_IOS`, `ADMOB_BANNER_IOS`, `ADMOB_INTERSTITIAL_IOS`) — whether it carries values decides whether the build can render ads (section c); `EXPECTED_REVIEWED_CI_SHA`; `SENTRY_DSN`; `LEGAL_BASE_URL`; `GOOGLE_SERVER_CLIENT_ID`; `QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED` (both default `false` in this workflow), `QIRSH_ALTERNATE_SIGNUP_ENABLED` (defaults `true`); App Store Connect integration `codemagic_asc_api_key`; signing for `com.youssefsafwat.mali` and the share extension; a protected `release/*` branch.

**Stages** (each a store action, not part of the package in (d)):
1. Internal TestFlight from an `ios-signed-release` build of the final candidate. Run MANUAL-DEVICE-TESTS on it (gate G5).
2. External TestFlight: the first build in an external group goes to Beta App Review. Limited cohort; size `______`.
3. App Store: manual release after approval. Phased release applies to **version updates** (official-doc-checks §c); a first version has no existing users to phase, so it is not a canary for V1. Territories as decided (V1-019).

**RT-01 (tab bar).** Build 147, now in testers' hands, hides the native tab bar after email one-time-code sign-in; `ios-signed` (which built 147) enables email sign-in. Fixed in `45ea901a`; confirmed **on a simulator only** (file M: three fresh installs plus a control build that reproduces the defect). A new internal build from the final candidate replaces 147 for testers. Apple and Google sign-in, the app-lock path and physical devices were not tested (MDT-IOS-30).

**Version identity.** Build 147 and a 1.0.0 release build both send `X-App-Version: 1.0.0`; a force-update notice cannot target 147 alone (V1-040). Cloud-off users never receive notices or flags (V1-045). There is no verified way to move installed clients off a build, so backend changes must stay compatible with every installed build (as the rows in (b) are).

**Android.** Out of V1 per the project records (DECISIONS-NEEDED A1); the owner may reopen it. If reopened: no release AAB has ever been built; `android-release` attaches the `admob` group.

---

## (g) Monitoring, thresholds, stop conditions, ownership

### Signals that exist

| Signal | Where | Limits |
|---|---|---|
| App crash and error reports (Sentry) | Flutter app | Only with Cloud consent on; whether `SENTRY_DSN` is set for the release workflow is unknown |
| TestFlight / App Store Connect crash data and feedback | Apple | Depends on users sharing diagnostics; not checked in this assessment |
| Edge Function logs and invocation counts | Supabase dashboard | No alerting; someone must look |
| Cron run history | `cron.job_run_details` | Manual query; never queried so far |
| Push delivery and retry backlog | `public.push_broadcast_deliveries`, `public.notification_retry_queue` | Manual |
| AI provider spend | Google Cloud billing | Budget alert existence unknown (V1-022) |
| Orphaned storage objects | Read-only count in (b) | Manual |
| User reports | Support path below | Path not confirmed |

**Signals review R asked for, which do not exist today:**

| Signal | Why | State |
|---|---|---|
| Smart Inbox volume (share of captures that wait for review) | R measured up to about 15% of correct completed probe messages going to review (0% on the repository corpus); real traffic is unknown (V1-085) | **No monitoring exists.** Smart Inbox items live on the device; no backend metric or report counts them. A manual read-only count of server capture statuses (`rejected` / unresolved) for consenting Cloud users is the nearest proxy and covers the server side only. Not defined or run |
| AI `not_a_transaction` rejection rate | R measured 353 of 1,306 correct AI candidates rejected on each side (V1-086) | **No monitoring exists.** Rejection reasons are not recorded server-side in a queryable form known to this assessment (V1-058); device rejections are not reported. Not defined or run |

**Not available (V1-024):** alerting of any kind; server-side error tracking; uptime checks; a project-wide AI spend ceiling; build-level client identity; a recorded pre-release baseline of function error rates (so "above baseline" cannot be judged until P0/P7 numbers are recorded).

### Stop conditions
Stop widening, and assess, on any of:
- A report of lost, duplicated or wrong financial data, including a completed movement not recorded (NR-01 class), a declined/failed one counted, or an outgoing payment recorded as income (QR-01, RR-01 class 2).
- Smart Inbox volume or AI rejections that users report as burdensome (no metric exists; user reports only, V1-085, V1-086).
- One account seeing another's data; transmission without consent.
- A `failed` run of the deletion worker, notification retry or push retry jobs lasting more than one day; an orphan count that grows after P1.
- Crash-free sessions below the SEVERITY-AND-GATES threshold (where measurable).
- Function error rate above the recorded baseline by `______` (owner sets); AI spend above `______` per day (owner sets).
- A store rejection or policy notice.

Known before any rollout: declined purchases are still counted on build 147 and older, and rows already stored stay counted (V1-056); at the final candidate 71 wrong total-changing outcomes remain on R's synthetic set (RR-01) — this is why V1-001 stays S1 OPEN until an owner decision, P3 with a new build, and a device run with real bank messages (MDT-IOS-07f).

### Observation windows (owner sets)
- After P1–P4: `______` (proposed 7 days with daily checks).
- Internal TestFlight: `______`. External TestFlight: `______`. After App Store release: `______`.
- Hours actually covered by a person in each window: `______`.

### Incident ownership and support (owner fills; deliberately blank)

| Role | Name | Contact | Hours covered |
|---|---|---|---|
| Incident owner | ______ | ______ | ______ |
| Backup contact | ______ | ______ | ______ |
| Operator with production database access | ______ | ______ | ______ |
| Person with App Store Connect access | ______ | ______ | ______ |

- Public support page `https://qirsh.site/support` (returned 200, audit H). The app shows `support@money-companion.app`; the privacy policy shows `business@qirsh.site` — one monitored address must be chosen (Guideline 1.5).
- Who reads the support inbox and how often: ______.
- Rule (INCIDENT-AND-RECOVERY): record affected accounts by identifier only; never copy user financial data into tickets or chats.

### Levers (none tested in the changed position)
- Remote flags reach only Cloud-on clients after their next catalog fetch (V1-045). Flags read by no code are not levers (V1-043: for example `enable_goals`, `enable_announcements`, the `ledger_*` and `planning_*_sync` flags).
- Unset `GEMINI_API_KEY`: `parse-sms` returns a retryable `upstream_unavailable` before any spend; clients fall back to local parsing (audit F, code inspection; not tested). This is a secret change, i.e. a production mutation.
- Remove a worker's Vault secret: its dispatcher makes no call. Deactivate a cron job (`cron.job.active`). Neither rehearsed.
- There is no server-side kill switch for the capture endpoints other than undeploying a function, which breaks every client that calls it (BE-13).

---

## (h) Recovery

General facts (INCIDENT-AND-RECOVERY): installed apps cannot be recalled; device databases migrate forward only; the fix for a bad build is a new build with a higher build number, tested as an upgrade from the bad build.

- **Failed function deploy:** redeploy the undo source named in (b) from its commit. Feasible because none of the three changes the database shape the old version expects. Not rehearsed. For AI functions, unsetting `GEMINI_API_KEY` is the other containment.
- **Database:** this release applies no migration. Point-in-time recovery is off and no backups are listed (V1-023): **there is no verified way to restore the database.** A whole-database restore would also lose everything written after its point. Rollback files exist for migrations from `0084` on; none has been rehearsed against production-shaped data.
- **Flag change gone wrong:** revert in the admin Flags page; reaches Cloud-on clients only, after their next fetch.
- **Grant revoke gone wrong:** `grant execute on function … to anon` restores the previous state.
- **Bad mobile build:** expire it in TestFlight; pause phased release (updates only); remove from sale if needed (stops new downloads only); ship a forward fix. Remote flags help only for flag-gated features and Cloud-on users.
- **Data already sent to a third party:** cannot be recalled; contain first (for example unset `GEMINI_API_KEY`), then follow INCIDENT-AND-RECOVERY.

---

## Status

| Item | State |
|---|---|
| Read-only production comparison | Done 2026-11-17 for migrations, functions (against `af675aec`), secrets names, flags, cron schedule, buckets, advisor, backups API. Unknowns listed in (a) |
| Function comparison against the final candidate | Not done (P0) |
| Deployment set P1–P4 | Not executed |
| Ads flag choice P5, revoke P6 | Owner decision; not executed |
| Orphaned-photo count | Not run |
| Strict gate at the final candidate | Not recorded (see TEST-EVIDENCE.md) |
| Independent review of the final parser commit | Done: review R of `50957c06`, accept with follow-up, no S1 (an AI review; not an approval). `75dab61a` was rejected by Q and `1be44623` by N |
| Owner decision to ship the candidate parser (B28–B30) | Open |
| New app build to ship with P3–P4 | Not made |
| Release-workflow build, Codemagic XCTest step | Never run |
| Any undo or recovery rehearsed | No |
| Observation windows, thresholds, owners | Owner to fill |
