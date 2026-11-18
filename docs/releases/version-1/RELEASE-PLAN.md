# Version 1 — release plan (deployment, rollout and recovery)

Rewritten 2026-11-17 (closure round) by the backend-privacy-ops specialist (model `claude-opus-5-5`, as stated by the harness) from a second read-only pass over production ([`evidence/production-comparison.md`](evidence/production-comparison.md) §7), the owner decisions D-20 ([`OWNER-BRIEF-ROUND3.md`](OWNER-BRIEF-ROUND3.md) §3, recorded in `docs/project/DECISIONS.md`), and the closure-round work in the working tree. It replaces the round-2 plan; the round-2 facts that still hold are carried forward.

**Candidate.** The closure-round changes are **uncommitted** at the time of writing (HEAD `d1212986`). "The final commit" below means the commit the orchestrator records in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) after integration. Every comparison marked *re-run at the final commit* must be repeated there; the commands are given.

**Nothing in this plan has been executed.** No function was deployed, no migration applied, no flag changed, no grant revoked, no backup taken, no build uploaded. Every production step is an owner-approved action.

How production changes are approved: production mutations are collected into **one action package** (section d) plus a **separate grants package** (section e). The owner approves or edits each as a whole. Approval covers the listed steps, in order, within the stated stop conditions; anything listed as excluded is not covered.

---

## (a) Deployed state versus the candidate

Read-only, 2026-11-17 (production-comparison §1, §4, §7).

| Area | Production | Candidate | Consequence |
|---|---|---|---|
| Migrations | 134 applied (`0001`–`0117`, 17 timestamped through `20261117010000`) | 134 + **`20261117120000_ai_global_spend_guard`** (new, closure round) | **One migration is now in the package** (section b, M1) |
| Schema content | Fingerprint equal to a fresh apply of the 134 files for columns, constraints, indexes, policies, table grants/RLS, triggers; functions equal except `anon` EXECUTE on `public.set_default_account(uuid)` | — | The ledger is now proven by content, not only names. The extra grant goes to the grants package (e) |
| Edge Functions | 28 deployed of 33 | 33 | 5 undeployed by design (D-14, `parser-test`) |
| Identical to HEAD | 21 functions (production-comparison §7.1) | — | Not proposed |
| `parse-sms` v15, `process-ios-sms` v27 | **Identical to `b6fc0dad` (build 147's commit)** | Changed at HEAD and again by the uncommitted AI/parser work | In the set. Rollback source is exactly `b6fc0dad` |
| `account-deletion-worker` v5 | Erases only `backups`; matches neither HEAD nor `b6fc0dad` | Erases `backups` and `profile-photos` (`9e19c3e4`) | In the set (V1-062). Rollback source to be identified in P0 |
| `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, `process-notification-retries` | Older `_shared/apns.ts` | Refactor `79a063d8` | Not proposed (no behaviour need) |
| `bank-discovery`, `enrich-merchant` | Identical to HEAD | Now call the global AI budget gate (`_shared/ai_budget_gate.ts`, `ai` specialist): Gemini in `bank-discovery`, Places in `enrich-merchant` | **In the set**, so the ceiling covers every paid call (V1-022). `enrich-merchant` makes no Places call today (`GOOGLE_MAPS_API_KEY` unset) |
| Secrets (names) | 23 set; `GEMINI_SMS_MODEL`, `GEMINI_MODEL`, `GEMINI_SHADOW_API_KEY`, `GOOGLE_MAPS_API_KEY` unset (defaults apply; Places has no key) | No new secret | Nothing to set |
| Vault (names) | `project_url`, `account_deletion_worker_secret` and 6 other worker secrets present | — | The deletion worker is really called (288 successful runs in 24 h) |
| Feature flags | All 8 ad flags `value 'true'`, `is_active true`, `rollout_percent 100`, `target_countries []`, `updated_at 2026-10-04 14:29:12.530481+00`; no audit row | V1 build has ads compiled out (D-20) | Turn off (P5) — hygiene for any future ad-capable build; V1 ignores them |
| Backups | Free plan; `pitr_enabled false`; `backups []`; database 28 MB; Storage holds **0 objects** | — | No restorable backup. Owner-run logical dump before M1 (section h) |
| Admin panel | Not reachable on the internet (production-comparison §7.3) | Next.js 15.5.29, 0 production advisories | Not part of this package |

**Re-run at the final commit** (one command, read-only):

```bash
SUPABASE_PROJECT_REF=<production ref> BACKEND_PG_HOST=127.0.0.1 BACKEND_PG_PORT=<port> \
  bash tools/prod_compare.sh <final-commit> b6fc0dad
```

It lists the deployed functions with versions, compares every function's source with its import closure at each ref (IDENTICAL / DIFFERS with file names), and — with a local dedicated Postgres — prints per-kind schema hashes of a fresh apply plus the read-only query that gives the same hashes on production. Expected at the final commit: the other 19 IDENTICAL; DIFFERS for exactly `parse-sms`, `process-ios-sms`, `bank-discovery`, `enrich-merchant`, `account-deletion-worker` and the four push-sender functions. Schema: all kinds equal except `fn` (new `consume_ai_global_budget`, `set_default_account` anon, scaffold `_dryrun_noop`), `tbl`/`col`/`con`/`idx` (the two new guard tables) and `cron` (explained in production-comparison §7.2). Anything else is a stop condition for P0.

---

## (b) Deployment set

| | M1 migration `20261117120000_ai_global_spend_guard` | `account-deletion-worker` | `process-ios-sms` + `parse-sms` (together) |
|---|---|---|---|
| **Why** | V1-022: a project-wide daily ceiling for paid AI calls (Gemini, Places) that per-device or per-key caps cannot provide | V1-062: the deployed worker leaves `profile-photos/<uid>/` when it completes a deletion | V1-001/V1-078 server parser fixes; the closure-round AI understanding (message type and status before amount, evidence checks, untrusted-text delimiting); V1-060 grounded amounts |
| **What it does** | Creates `public.ai_global_budget` (seeded `gemini` 3000/day, `places` 1000/day, `enabled true`) and `public.ai_global_spend` (day, bucket, calls, denied) — RLS on, no client grants; and `public.consume_ai_global_budget(bucket, units)` (SECURITY DEFINER, `search_path` pinned, EXECUTE to `service_role` only) that reserves atomically and returns `{allowed, reason, used, limit}` | Bundles the two-bucket `storage_erasure.ts` | New server parse and AI path |
| **Lock and risk** | Additive and idempotent (`create … if not exists`, `on conflict do nothing` seed). Creates new objects only; takes no lock on any existing table; no data rewrite. Proof: `supabase/tests/ai_global_spend_guard_20261117.sql` (9 checks) and `tools/backend_behaviour.sh` (135 migrations apply) | No schema change | No schema change |
| **Depends on** | Nothing | Vault names present; secrets `ACCOUNT_DELETION_WORKER_SECRET`, `ACCOUNT_DELETION_SEALER_KEY`, `APPLE_TEAM_ID`, `APPLE_KEY_ID`, `APPLE_CLIENT_ID`, `APPLE_PRIVATE_KEY_P8`, platform `SUPABASE_*` — all set | `GEMINI_API_KEY`, `APNS_BUNDLE_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_TEAM_ID`, `ENGAGEMENT_WORKER_SECRET`, platform `SUPABASE_*` — set. **If** the final commit calls `consumeGlobalAiBudget`, M1 must be applied first |
| **Include when** | **Included.** The working tree now calls the guard through `_shared/ai_budget_gate.ts` in `parse-sms`, `process-ios-sms`, `bank-discovery` (Gemini) and `enrich-merchant` (Places). The gate lets the provider call proceed only when the guard function does not exist yet (PGRST202 / 42883), so applying the migration first is required for the ceiling to work, but a different deploy order does not cause an outage | Always | When the parser/AI conditions in (d) preconditions hold. `bank-discovery` and `enrich-merchant` go in the same step, after M1 |
| **Verification after** | `select count(*) from supabase_migrations.schema_migrations` = 135; `select bucket, daily_limit, enabled from public.ai_global_budget;` = 2 rows; `select has_function_privilege('anon','public.consume_ai_global_budget(text,integer)','EXECUTE')` = false; schema fingerprint as in (a) | `functions list` shows a new version; `cron.job_run_details` for `account-deletion-worker` all `succeeded` for the next 2 hours; orphan count (M3) stays 0 | New versions; no new error class in function logs for 30 minutes; synthetic test account on the new build: S04/S19 declined samples → not recorded as spending, item in review; S21 and the "available limit" purchase → recorded; a pasted synthetic purchase records the amount in the text (MANUAL-DEVICE-TESTS) |
| **Undo** | `supabase/rollback/20261117120000_ai_global_spend_guard_rollback.sql` (drops the function and both tables; rehearsed locally: apply → rollback → re-apply) **after** redeploying functions that do not call it; then `delete from supabase_migrations.schema_migrations where version = '20261117120000';` | Redeploy the source identified in P0 (v5 matches neither HEAD nor `b6fc0dad`; candidates: commits that last touched `_shared/storage_erasure.ts` before `9e19c3e4`). Undo re-opens the photo gap | Redeploy both from `b6fc0dad` (proven identical to v27 and v15) |
| **Rehearsed** | Locally on PostgreSQL 17 with the scaffold: yes. Against production-shaped data: no | No | No |

**Not proposed:** the four push-sender functions; the 19 functions identical to HEAD; the 5 undeployed functions; any secret, Vault, Auth or cron change.

---

## (c) Compatibility matrix

Build 147 = commit `b6fc0dad` (iOS, `ios-signed`, internal TestFlight). "Old backend" = production today. "New backend" = section (b) deployed. Cloud on = the user accepted Smart Analysis & Cloud Sync. Evidence: code inspection by the `ai` specialist (closure/ai.md §3) and this specialist; **no pair was run end to end**.

| App × backend | Cloud/AI off | Cloud/AI on |
|---|---|---|
| **147 × old** (today) | Device-only parse; no catalog, flags or force-update notices; ads impossible (no AdMob IDs in 147) | Server parse with declined purchases accepted (V1-001); shared learning ON by default for 147 users (old missing-key = ON) |
| **147 × new** | No change: 147 sends nothing | Response shapes are supersets; 147 reads named keys only. More messages come back as not-a-transaction / `ai_ignored` → 147 sends them to Smart Inbox unless its deterministic filter drops them. Server rejections of declined/failed messages make 147 **re-parse locally and confirm** (`forceLocalAutoConfirm`), so a declined purchase can still be counted on 147 (V1-056, known). If the guard ceiling is reached: `parse-sms` returns the existing retryable error → 147 falls back to local parsing (no new failure mode). Deletion worker: no client involvement. 147 keeps contributing shared learning (server unchanged; the transition prompt exists only in the new build) |
| **new × old** | Device-only; catalog not fetched (gated on Cloud consent) | Old `parse-sms` ignores the new request fields (`local_evidence`, `account_currency`); no `message_type/status` → device judges as before; no-currency messages stay in review. Old `process-ios-sms` still returns declined purchases as processed → the new build's import re-check holds contradicting results for review. Ads compiled out whatever the flags. Deletion with profile photo: inline path erases both buckets; worker-completed path leaves the photo until the worker is deployed |
| **new × new** | Device-only | Designed pair (all closure-round behaviour) |

**Consent transitions to re-check on the final build:** 147 user with Cloud on upgrades → Cloud stays on, shared learning is OFF until they answer the one-time prompt; 147 user with Cloud off upgrades → stays local, no prompt; turning off on the new build → "Turn off both" stops sync, AI, retries and new contributions.

**Sign-in compatibility (3.11) — owner action.** `ios-signed-release` passes `QIRSH_GOOGLE_AUTH_ENABLED` and `QIRSH_EMAIL_AUTH_ENABLED` with default **false**, and the workflow's `vars` do not set them. Build 147 (`ios-signed`) enables both. Unless the owner sets both to `true` for the release workflow in Codemagic, users who signed up with Google or an email code on 147 cannot sign in again on the release build. Verify in the release build log before upload.

**Re-check on the final commit:** `tools/prod_compare.sh` output (a); the four rows above against the final `parse-sms`/`process-ios-sms` response shapes; whether the guard is integrated (b, M1); the Codemagic sign-in variables.

---

## (d) Action package for approval

**Status: NOT EXECUTED.**

Operator: `______` (owner fills). Window: `______`. Estimated operator time (not measured): 1–2 hours plus the observation window.

**Preconditions (none is a production action)**
1. The final commit is recorded in RELEASE-MANIFEST.md, the strict gate passed at it, and the opt-in backend stage passed at it (`BACKEND_PG_HOST=… REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`; JSON field `backend_behaviour: passed`).
2. Parser/AI conditions for P3 (DECISIONS-NEEDED B28–B30 and the bounded real-model evaluation), and a new app build from the same commit ready for testers in the same window (V1-087).
3. A clean checkout of the final commit; Supabase CLI linked to production.
4. The owner-run backup in section (h) exists and its listing check passed (required before P2; recommended before P1).

| Step | Action | Exact command | Post-check | Stop if |
|---|---|---|---|---|
| **P0** | Read-only pre-checks | `supabase functions list --project-ref <ref>` (expect `account-deletion-worker` v5, `process-ios-sms` v27, `parse-sms` v15); `supabase secrets list --project-ref <ref>` (names only); `select name from vault.secrets order by name;`; `tools/prod_compare.sh <final-commit> b6fc0dad` (a); monitoring baseline queries M1–M7 (g); identify the `account-deletion-worker` v5 source: `for c in $(git log --format=%h -- supabase/functions/_shared/storage_erasure.ts); do echo $c; done` then `tools/prod_compare.sh <c>` until IDENTICAL | Results recorded in `evidence/` (counts and names only) | Versions changed since 2026-11-17; a secret name missing; unexplained DIFFERS or schema drift; no source found for v5 (then decide whether an un-rollbackable deploy is acceptable) |
| **P1** | Deploy `account-deletion-worker` | `supabase functions deploy account-deletion-worker --project-ref <ref>` (`config.toml` keeps `verify_jwt = false`) | (b) verification | Deploy error; a `failed` worker run |
| **P2** | Apply M1 | `supabase db push --linked --dry-run` must list exactly `20261117120000_ai_global_spend_guard.sql`; then `supabase db push --linked`. (The CLI creates a temporary login role; alternative: paste the file into the SQL editor and record the version with `insert into supabase_migrations.schema_migrations(version, name) values ('20261117120000','ai_global_spend_guard');`) | (b) verification | Dry run lists any other file; any error |
| **P3** | Deploy `process-ios-sms`, `parse-sms`, `bank-discovery`, `enrich-merchant` (same commit, same window, after P2) | `supabase functions deploy process-ios-sms --project-ref <ref>` ; `supabase functions deploy parse-sms --project-ref <ref>` ; `supabase functions deploy bank-discovery --project-ref <ref>` ; `supabase functions deploy enrich-merchant --project-ref <ref>` (undo for the last two: redeploy from `d1212986`, identical to production today) | (b) verification; MDT-IOS-07b/-07d on the new build | New error class; a synthetic completed purchase neither recorded nor in review; a synthetic declined sample counted on the new build; `ai_global_spend.denied > 0` on day one (ceiling too low) |
| **P4** | Advertising flags off (D-20) | SQL below | Read-back query below | Any other flag changed; the function raises (stale `updated_at` → re-read and stop) |
| **P5** | Observe | Section (g) daily | Recorded daily, window `______` (proposed 7 days) | Any stop condition in (g) |

**P4 — ad flags off, through the audited RPC** (the admin panel is not deployed; the RPC is what its Flags page calls). `<owner admin uuid>` is the owner's auth user id (recorded as the actor; `admin_can_change_flag` accepts any non-null actor, migration `0101`); the `expected_updated_at` guard makes it fail if anyone changed a flag since 2026-11-17:

```sql
select public.admin_apply_feature_flag_changes(
  '<owner admin uuid>'::uuid,
  'V1 ships without advertising (owner decision D-20, 2026-11-17)',
  gen_random_uuid(),
  (select jsonb_agg(jsonb_build_object(
            'key', key,
            'expected_updated_at', '2026-10-04 14:29:12.530481+00',
            'set', jsonb_build_object('value', 'false')))
     from unnest(array['enable_banner_ads','enable_banner_dashboard','enable_banner_transactions_list',
                       'enable_banner_reports','enable_banner_goals','enable_banner_subscriptions',
                       'enable_banner_achievements','enable_report_ads']) as key));
-- read back
select key, value, is_active, rollout_percent, target_countries
from public.feature_flags
where key like 'enable_banner%' or key = 'enable_report_ads' order by key;
```

Only `value` changes; `is_active true`, `rollout_percent 100`, `target_countries []` stay as they are. **Rollback (restores the exact previous values):** the same call with `'value', 'true'` and `expected_updated_at` set to the `updated_at` that P4 produced (read it back first). `updated_at` itself cannot be restored to its 2026-10-04 value; the audit table records both changes.

**Excluded from this package:** the grants package (e); the four push-sender functions, the 19 identical and 5 undeployed functions; any secret, Vault, Auth or cron change; enabling PITR or any plan change; cleanup of any stored data (Storage holds no objects today); admin panel deployment; Codemagic runs, TestFlight or App Store actions (section f); publishing the legal site (owner runs `tools/deploy_site.sh` only after the V1 app is live, see the note in `docs/legal/PRIVACY_POLICY.md`).

---

## (e) Grants package V1-064 — separate approval, separate window

Not combined with (d). Previous state read on production 2026-11-17 (`pg_proc.proacl`):

| Function | Kind | Current ACL | Change |
|---|---|---|---|
| `public.create_profile_on_signup()` | SECURITY DEFINER, `returns trigger` | `=X` (PUBLIC), `postgres`, `anon`, `authenticated`, `service_role` | `revoke execute … from public, anon, authenticated;` |
| `public.feature_flag_audit_append_only()` | SECURITY DEFINER, `returns trigger` | same | same |
| `public.set_default_account(uuid)` | SECURITY INVOKER | `postgres`, `anon`, `authenticated`, `service_role` (no PUBLIC) | `revoke execute … from anon;` (migration `0025` intended `authenticated` only) |

Trigger functions run as triggers whatever the caller's EXECUTE grant, so the first two revokes do not affect sign-up or flag auditing; `set_default_account` keeps working for signed-in users.

Steps: G0 rehearse on a local dedicated Postgres after `tools/backend_behaviour.sh` (revoke, then run `supabase/tests/admin_push_broadcasts_20261116.sql` and a synthetic `auth.users` insert to confirm the profile trigger fires); G1 apply the revokes in the SQL editor; G2 add a migration file with the same statements (and its rollback) so the files and the fingerprint agree; G3 verify with the `fn` fingerprint and `has_function_privilege('anon', …, 'EXECUTE')` = false for all three.

**Rollback (restores the exact previous ACLs):**
```sql
grant execute on function public.create_profile_on_signup() to public, anon, authenticated;
grant execute on function public.feature_flag_audit_append_only() to public, anon, authenticated;
grant execute on function public.set_default_account(uuid) to anon;
```

---

## (f) Mobile

**Build workflow.** `ios-signed-release` (hardened locally in `4fc2ecd6`; now attaches no `admob` group, so the release build has no AdMob identifier and does not pass `QIRSH_ADS_ENABLED`) has **never run on Codemagic**. Before the first run the owner checks, by name only: group `supabase` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`); `EXPECTED_REVIEWED_CI_SHA`; `SENTRY_DSN`; `LEGAL_BASE_URL` (unset = `https://qirsh.site`); `GOOGLE_SERVER_CLIENT_ID`; `QIRSH_GOOGLE_AUTH_ENABLED` and `QIRSH_EMAIL_AUTH_ENABLED` (**must be `true` to keep 147's sign-in methods**, section c); `QIRSH_ALTERNATE_SIGNUP_ENABLED` (default `true`); `codemagic_asc_api_key`; signing for `com.youssefsafwat.mali` and the share extension; a protected `release/*` branch.

**Stages** (store actions, outside (d)): internal TestFlight → MANUAL-DEVICE-TESTS (G5) → external TestFlight (Beta App Review) → App Store, manual release. Phased release applies to updates only.

**Version identity.** 147 and 1.0.0 both send `X-App-Version: 1.0.0`; a force-update notice cannot target 147, and Cloud-off users receive no notices at all (V1-045, now stated in the policy). Backend changes must therefore stay compatible with 147 (section c).

**Export compliance (V1-026).** See STORE-READINESS A14: the app ships standard encryption not provided by iOS (SQLCipher/`sqlite3mc`, Dart `cryptography`), so `ITSAppUsesNonExemptEncryption` should be `true` and App Store Connect answered "standard encryption algorithms"; either exclude France or upload the French declaration.

**Android.** Out of V1 (D-20, 3.1).

---

## (g) Monitoring, thresholds, actions

All queries are read-only and return counts; run them in the SQL editor (UTC). Baselines measured 2026-11-17 are given where available. There is **no alerting**: a named person must run these daily during the window.

| # | Signal | Query | Baseline (2026-11-17) | Threshold → action |
|---|---|---|---|---|
| M1 | Cron failures | `select j.jobname, d.status, count(*) from cron.job_run_details d join cron.job j using (jobid) where d.start_time > now() - interval '24 hours' group by 1, 2 order by 1, 2;` | All `succeeded` (deletion worker 288, notification retry 288, push retry 144) | Any `failed` for `account-deletion-worker` on 2 consecutive runs → stop P5 widening; check function logs; if caused by P1, redeploy the P0-identified source |
| M2 | Deletion jobs not completing | `select count(*) filter (where state <> 'completed') open, count(*) filter (where state <> 'completed' and accepted_at < now() - interval '1 hour') stuck from account_fence.deletion_job;` | 0 / 0 (12 completed in total) | `stuck > 0` → incident: a user's deletion is unfinished; check `last_code`, `attempts`, `next_attempt_at` for that job (no uid is printed) |
| M3 | Orphaned Storage objects | the two orphan counts in the round-2 plan (`profile-photos`, `backups` objects whose owner folder has no `auth.users` row) | 0 / 0 (Storage holds 0 objects) | Any growth after P1 → the worker gap is not closed; stop and investigate. Cleanup needs a separate approval |
| M4 | Server capture backlog | `select status, count(*) from public.processed_captures where created_at > now() - interval '24 hours' group by 1;` and `select count(*) from public.processed_captures where state = 'processing' and created_at < now() - interval '1 hour';` | 24 h: 3 processed; **2 rows stuck in `processing` for over an hour** (pre-existing; to be explained in P0) | Stuck count grows day on day, or `rejected` share above 30% of a day's captures with ≥ 20 captures → inspect function logs; hold P3 widening |
| M5 | Notification delivery failures | `select channel, error_code, count(*) , count(distinct coalesce(install_id_hash, user_id::text)) sources from public.notification_logs where status = 'failed' and created_at > now() - interval '24 hours' group by 1, 2;` | 18 failed in 24 h, all `local_ios` error 2003 from **one** account since 2026-11-07 (540 in 7 days) — passed to the iOS specialist | A failure class from more than one source, or any `apns` failure class above 5% of sent → investigate APNs credentials / payload; stop P3 widening if it started after P3 |
| M6 | Retry backlogs | `select count(*) from public.notification_retry_queue where resolved_at is null and next_attempt_at < now() - interval '30 minutes';` and `select status, count(*) from public.push_broadcast_deliveries where created_at > now() - interval '7 days' group by 1;` | 0; 0 failed | Backlog > 0 for two consecutive checks → check the retry job (M1) and Vault names |
| M7 | AI spend (requires M1 migration) | `select day, bucket, calls, denied from public.ai_global_spend where day > current_date - 7 order by day, bucket;` plus `select bucket, daily_limit, enabled from public.ai_global_budget;` | Per-key counters today show 3–25 AI calls a day in total | `calls > 50%` of `daily_limit` → review volume and cost; `denied > 0` → users are being sent to review/local parsing; the owner decides whether to raise the limit (`update public.ai_global_budget set daily_limit = … where bucket = …;`, a production change). Google Cloud budget alert on the Gemini project: owner sets one in Google Cloud billing (not checked) |
| M8 | Function errors | Dashboard → Edge Functions → logs for the deployed functions | Not recorded | A new error class after a deploy → stop and roll back that function |
| M9 | Review volume / AI rejection rate (V1-085/086) | **No server metric exists**; Smart Inbox lives on the device | — | User reports only |

**Stop conditions** (stop widening, assess): any report of lost, duplicated or wrong financial data; one account seeing another's data; transmission without consent; M1/M2/M3 conditions above; a store rejection or policy notice.

**Kill switches (none rehearsed):** `update public.ai_global_budget set enabled = false where bucket = 'gemini';` (after M1 and integration: every guarded AI call is refused before spending; clients fall back to review/local); unset `GEMINI_API_KEY` (`parse-sms` returns retryable `upstream_unavailable`); remove a worker's Vault secret or set `cron.job.active = false`. Each is a production change.

**AI-spend call-site contract** (module `supabase/functions/_shared/ai_spend_guard.ts`; the `ai` specialist implemented it as `_shared/ai_budget_gate.ts`, with one deliberate deviation: when the guard function does not exist yet, the call proceeds as before the guard, so deploy order cannot cause an outage):
- Call `await consumeGlobalAiBudget(serviceClient, 'gemini')` (or `'places'` in `enrich-merchant`) **immediately before each paid provider request** — every Gemini attempt including repair retries counts one unit — and **after** consent, ownership and the per-identity cap have passed, so refused requests never consume budget.
- `serviceClient` is the service-role Supabase client already used by the function (the RPC is executable by `service_role` only).
- If `decision.allowed` is false (`ceiling`, `disabled`, `unknown_bucket`, or `unavailable` when the RPC fails — it fails closed), **do not call the provider**: in `process-ios-sms` send the capture to review the way a provider outage does today; in `parse-sms` return the existing retryable `upstream_unavailable` response. Never fall through to the provider.
- Do not log the decision with user identifiers; a content-free log line with `reason` is enough.

### Observation windows and ownership (owner fills)
- After P1–P4: `______` (proposed 7 days). Internal TestFlight `______`. External `______`. After release `______`.
- Incident owner `______`; backup contact `______`; operator with database access `______`; App Store Connect `______`; hours covered `______`.
- One monitored support address (the app shows `support@money-companion.app`, the policy `business@qirsh.site`, Guideline 1.5).

---

## (h) Backup and recovery

**What exists (read-only, 2026-11-17):** organisation plan **free**; `pitr_enabled false`; the backups API lists **no backups** (`backups []`); WAL-G is enabled on the platform side but no restore point is exposed. Database size 28 MB; Storage holds 0 objects. **There is no verified way to restore the database.** Rollback files exist for migrations `0084` onwards; only M1's has been rehearsed (locally).

**Proposed owner-run logical backup before P1/P2 (not run by this work; no paid service).** Run by the owner on their own machine with PostgreSQL 17 client tools (`pg_dump` ≥ the server's 17.6), using the database connection string from Dashboard → Connect (session pooler), entered at the prompt, never in a file or shell history:

```bash
umask 077
mkdir -p "$HOME/QirshSecure/backups"        # on an encrypted volume (FileVault or an encrypted disk image)
read -rs PGURL                               # paste the connection string; not echoed
pg_dump "$PGURL" --format=custom --no-owner --no-privileges \
  --file "$HOME/QirshSecure/backups/qirsh-prod-$(date -u +%Y%m%dT%H%MZ).dump"
pg_restore --list "$HOME/QirshSecure/backups/"qirsh-prod-*.dump | grep -c 'TABLE DATA'   # listing check only
unset PGURL
```

- **The file contains all production user data** (financial records, auth users, encrypted Vault entries). Keep it only in that protected location, never in the repository, a shared drive, chat or a ticket; never load it into a development or test environment; delete it when the observation window ends.
- It covers the database only; Storage objects are not included (there are none today).
- Restoring it has **not** been rehearsed; a restore would overwrite everything written after it. It is a last resort, not a rollback for (b), whose undo is a function redeploy or the M1 rollback file.

**Recovery by failure type**
- Function deploy: redeploy the undo source in (b). Not rehearsed.
- M1: functions first, then the rollback file (b). Rehearsed locally.
- Flags: P4 rollback SQL. Grants: (e) rollback SQL.
- Bad mobile build: expire in TestFlight; pause phased release (updates only); forward fix with a higher build number.
- Data already sent to a third party: cannot be recalled; contain (kill switches in g) and follow INCIDENT-AND-RECOVERY.

---

## Status

| Item | State |
|---|---|
| Read-only production comparison (functions, schema content, Vault names, cron history, flags, backups, counts) | Done 2026-11-17 against HEAD and `b6fc0dad`; **re-run at the final commit** |
| M1 migration and guard module | Prepared and tested locally; called by `parse-sms`, `process-ios-sms`, `bank-discovery`, `enrich-merchant` (working tree, `ai` specialist) |
| Deployment P0–P5 | Not executed |
| Grants package (e) | Prepared; not executed; not rehearsed |
| Owner-run backup (h) | Proposed; not run |
| Release workflow run, Codemagic sign-in variables | Not run / owner to check |
| Any undo or restore rehearsed against production | No |
