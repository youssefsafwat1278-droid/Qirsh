# Production comparison — read-only, 2026-11-17

Deployed state of the production Supabase project (`rjwphwsefnuotpbtuycf`, region eu-central-1) compared with the candidate source at `af675aec`. Taken by the orchestrator (Claude Fable 5.2) with the Supabase CLI already signed in on the owner's machine.

**Only read operations were used:** `supabase projects list`, `supabase functions list`, `supabase functions download` (into a scratch folder outside the repository), `supabase secrets list` (names only — values are never returned by this command and none are recorded here), `supabase backups list`. Nothing was deployed, changed, linked, or written to the project. The CLI's database commands were not run, because they would create a temporary login role in production. Database facts in §4 were read later through the connector the owner attached.

## 1. Edge Functions

28 functions are deployed; the repository has 33.

**In the repository, not deployed (5):** `affiliate-click-status`, `affiliate-postback`, `affiliate-sync`, `prepare-affiliate-click`, `parser-test`. The four affiliate functions match decision D-14 (the affiliate gateway stays unwired until a network exists). No deployed function is absent from the repository.

**Source comparison.** The deployed bundle of each function was downloaded and compared with the candidate. Deployed code is transpiled, so both sides were normalized identically (types and comments stripped, whitespace, trailing commas, quote style and parentheses removed) before comparing. A difference in parenthesization alone would therefore not be detected; nothing else is masked.

| Result | Functions |
|---|---|
| **Identical to the candidate (22)** | `bank-discovery`, `catalog-announcements`, `catalog-campaigns`, `catalog-coupons`, `catalog-delta`, `catalog-flags`, `catalog-versions`, `cron-daily-reminders`, `delete-account-immediate`, `enrich-merchant`, `google-enrollment`, `link-capture-device`, `merchant-category-contribution`, `merchant-feedback`, `parse-sms`, `purge-scheduled-deletions`, `register-device`, `register-push-token`, `send-push-broadcast`, `set-device-consent`, `sync-captures`, `unlink-capture-device` |
| **Different (6)** | see below |

| Function | Deployed (UTC) | What differs | Meaning |
|---|---|---|---|
| `process-ios-sms` (v27) | 2026-11-16 08:25 | `parse.ts`, `parser_rules.json` | Expected: the declined-transaction rule added on this branch (V1-001). Production still accepts declined purchases |
| `account-deletion-worker` (v5) | 2026-11-15 07:55 | `_shared/storage_erasure.ts` | **The deployed worker erases only the `backups` bucket.** The candidate (and the already-redeployed `delete-account-immediate` and `purge-scheduled-deletions`) also erase `profile-photos`, added 2026-11-16 in `9e19c3e4`. A deletion completed by this worker would leave the profile photo in storage. Not found by any audit |
| `evaluate-budgets` (v11), `evaluate-gamification` (v8), `evaluate-goals` (v8), `process-notification-retries` (v12) | 2026-10-24 … 2026-11-15 | `_shared/apns.ts` | Deployed before `79a063d8` (2026-11-16) refactored the push sender to a shared `sendApnsAlert`. Intended as behavior-preserving; equivalence was not proven here |

`verify_jwt` settings of deployed functions match `supabase/config.toml` where the file declares them.

## 2. Secrets (names only)

23 names are set: `ACCOUNT_DELETION_SEALER_KEY`, `ACCOUNT_DELETION_WORKER_SECRET`, `APNS_BUNDLE_ID`, `APNS_KEY_ID`, `APNS_PRIVATE_KEY`, `APNS_TEAM_ID`, `APPLE_CLIENT_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY_P8`, `APPLE_TEAM_ID`, `ENGAGEMENT_WORKER_SECRET`, `GEMINI_API_KEY`, `NOTIFICATION_RETRY_WORKER_SECRET`, `PURGE_WORKER_SECRET`, `PUSH_BROADCAST_WORKER_SECRET`, `REMINDERS_WORKER_SECRET`, and the platform-provided `SUPABASE_*` entries.

Referenced by function code but **not set**:

| Name | Effect of being unset (from code) |
|---|---|
| `GEMINI_SMS_MODEL` | `process-ios-sms` uses its default model `gemini-3.8-flash` |
| `GEMINI_MODEL` | `bank-discovery` uses its default `gemini-2.5-flash-lite` |
| `GEMINI_SHADOW_API_KEY` | Shadow AI route has no key |
| `GOOGLE_MAPS_API_KEY` | Merchant enrichment through Google Places has no key. The privacy policy and Data safety draft describe Places as a recipient — whether the feature is live should be confirmed before describing it |
| `AFFILIATE_WORKER_SECRET`, `AFFILIATE_FIXTURE_POSTBACK_SECRET` | Affiliate functions are not deployed |

This answers the manifest's "AI model in production: UNKNOWN": the defaults are in effect.

## 3. Backups

`supabase backups list` returned: `walg_enabled: true`, **`pitr_enabled: false`**, **`backups: []`**.

Point-in-time recovery is off, and the API lists no restorable backups. Whether the plan keeps provider-side daily backups that this endpoint does not list was not determined. Until the owner confirms otherwise, treat production as having **no verified way to restore the database** (V1-023). Any plan step that says "restore" or assumes PITR is not available.

## 4. Database state (read through the Supabase connector the owner attached)

After the first pass the owner connected a Supabase connector to the session. Only its read operations were used: `list_migrations`, `get_advisors` (security), and one `execute_sql` call containing a single `SELECT` over `cron.job`, `public.feature_flags` and `storage.buckets`. No write, DDL, deploy or branch operation was called.

### 4.1 Migrations — V1-002 closed for the ledger

The production ledger lists **134 migrations: `0001`–`0117` and the 17 timestamped ones through `20261117010000_push_broadcast_auto_retry`**. That is exactly the set in `supabase/migrations/` at the candidate — nothing missing, nothing extra. The deferred `0118_record_metric_ad_keys` is not applied, as intended.

Limit of this check: the ledger records versions and names, not content. A migration applied by hand with different SQL than the file would not show. `docs/project/MIGRATION_LEDGER.md` ("through 0092") is stale and should be replaced by this result.

### 4.2 Scheduled jobs

| Job | Schedule | Active |
|---|---|---|
| `account-deletion-worker` | every 5 minutes | yes |
| `account-deletion-purge-expired` | 03:17 daily | yes |
| `notification-retry-dispatch-5min` | every 5 minutes | yes |
| `push-broadcast-retry` | every 10 minutes | yes |
| `cron-daily-reminders-job` | 00:00 daily | yes |
| `prune-processed-captures-hourly` | hourly | yes |
| `prune-ai-request-idempotency-daily` | 03:25 daily | yes |
| `prune-affiliate-clicks-daily` | 03:40 daily | yes |
| `affiliate-sync-hourly` | hourly | **no** |

The deletion worker is live and runs the outdated function described in §1.

### 4.3 Feature flags

**On (100%):** `enable_announcements`, `enable_coupons`, `enable_goals`, `enable_referrals`, `parser_engine_version`, and **every advertising flag: `enable_banner_ads`, `enable_banner_dashboard`, `enable_banner_transactions_list`, `enable_banner_reports`, `enable_banner_goals`, `enable_banner_subscriptions`, `enable_banner_achievements`, `enable_report_ads`.**

**Off:** `local_auto_confirm_v2`, `capture_ai_fallback_enabled`, `ai_sender_mapping_auto`, `capture_direct_ledger_write`, `capture_direct_supabase_write`, all `ledger_*`, `planning_*_sync`, `*_supabase_primary`, `smart_inbox_pull_sync`, `dashboard_supabase_summary`, `budget_progress_supabase_rpc`.

The advertising flags being on contradicts the records that say every ad flag ships off (decision D-19 and the audits that relied on the seed values). Whether ads actually appear then depends only on the build: `ios-signed` (the workflow that built 147) does not attach the AdMob variable group, so that build has no ad unit IDs; `ios-signed-release` and `android-release` do attach it. A store build from `ios-signed-release` with the AdMob IDs set would show ads while the privacy policy, consent text and store declarations do not mention them (V1-005 becomes a blocker for that build).

### 4.4 Storage buckets

`backups` (private), `profile-photos` (private), `coupon-assets` (public).

### 4.5 Security advisor (provider's linter)

| Finding | Count | Note |
|---|---|---|
| `SECURITY DEFINER` function executable by the anonymous role | 2 | `create_profile_on_signup()`, `feature_flag_audit_append_only()`. Both look like trigger functions (no arguments); whether calling them through the API does anything was not tested. Grants should be revoked regardless |
| `SECURITY DEFINER` function executable by signed-in users | 15 | Expected for owner-scoped RPCs; each should be confirmed to scope by `auth.uid()` (the security audit read these in code) |
| Function with a mutable `search_path` | 26 | Mostly trigger and helper functions. The security audit's statement that all `SECURITY DEFINER` functions pin `search_path` is about a different set; this list was not cross-checked function by function |
| Row-level security enabled with no policy | 22 tables | Deny-all to API roles, which is the safe direction for service-only tables |
| Leaked-password protection off | 1 | The app has no password sign-in |

Remediation references: [SECURITY DEFINER executable by anon](https://supabase.com/docs/guides/database/database-linter?lint=0028_anon_security_definer_function_executable), [mutable search_path](https://supabase.com/docs/guides/database/database-linter?lint=0011_function_search_path_mutable).

## 5. Still unknown

| Item | Why |
|---|---|
| Vault entries, Auth hook wiring, email-confirmation setting | Dashboard only |
| Cron run history and failures | Not queried |
| Whether applied migration content equals the files | Ledger holds names only |
| Admin panel deployment and exposure | Not in Supabase |
| Codemagic variable values (AdMob IDs, sign-in switches) | Codemagic UI |
| Whether provider-side daily backups exist beyond what the API lists | Plan/dashboard |

## 6. What this changes

- **V1-002 is closed for the migration ledger**: production has all 134 candidate migrations. No migration needs to be applied for this release.
- V1-023 is confirmed in part: point-in-time recovery is off and no backups are listed.
- New: the deployed `account-deletion-worker` predates profile-photo erasure and its job is active (V1-062).
- New: all advertising flags are on in production (V1-063), contrary to the records.
- New: two `SECURITY DEFINER` functions are executable by the anonymous role (V1-064).
- The smallest justified deployment set is functions only — see [RELEASE-PLAN.md](../RELEASE-PLAN.md).

## 7. Closure round — second read-only pass (ops specialist, 2026-11-17)

Taken by the backend-privacy-ops specialist (model `claude-opus-5-5`, as stated by the harness) with the same signed-in CLI and the attached connector. **Read operations only:** `functions list`, `functions download --use-api` (source, into the scratchpad), `secrets list` (names), `backups list`, and connector `execute_sql` calls that are single `SELECT`s over catalogs, `cron.*`, `vault.secrets` (names only), `public.feature_flags`, and **counts** of user tables. No row of user data was exported; no secret value was read.

### 7.1 Function sources against HEAD (`d1212986`) and build 147's commit (`b6fc0dad`)

One command, now in the repository: `SUPABASE_PROJECT_REF=<ref> bash tools/prod_compare.sh HEAD b6fc0dad` (downloads the original **source** with `--use-api`, so no normalisation is needed; compares each function's import closure file by file).

| Result | Functions |
|---|---|
| Identical to both HEAD and `b6fc0dad` (21) | `bank-discovery`, the six `catalog-*`, `cron-daily-reminders`, `delete-account-immediate` (12 files, including the two-bucket `storage_erasure.ts`), `enrich-merchant`, `google-enrollment`, `link-capture-device`, `merchant-category-contribution`, `merchant-feedback`, `purge-scheduled-deletions`, `register-device`, `register-push-token`, `send-push-broadcast`, `set-device-consent`, `sync-captures`, `unlink-capture-device` |
| Identical to `b6fc0dad`, differs from HEAD | `parse-sms` (`_shared/ai_candidate_validator.ts`, `parse-sms/index.ts`, `parse-sms/money.ts`, and HEAD's closure adds `process-ios-sms/parser_rules.json`), `process-ios-sms` (`_shared/ai_candidate_validator.ts`, `parse.ts`, `parser_rules.json`) |
| Differs from both | `account-deletion-worker` (`_shared/storage_erasure.ts`: deployed erases only `backups`), `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, `process-notification-retries` (`_shared/apns.ts`: deployed predates the `sendApnsAlert` refactor `79a063d8`) |

So **`process-ios-sms` v27 and `parse-sms` v15 are build 147's backend** (`b6fc0dad`): that is their exact rollback source. `account-deletion-worker` v5 matches neither; its rollback source must be found (RELEASE-PLAN P0). The uncommitted closure-round work changes the closures of `parse-sms` and `process-ios-sms` again (`_shared/ai_primary.ts`, `ai_understanding.ts`, `ai_candidate_validator.ts`, `gemini_request.ts`, `process-ios-sms/index.ts`, `message_meaning.ts`) and, through a type-only change to `gemini_request.ts`, `bank-discovery`. Re-run the command at the final commit.

### 7.2 Schema equivalence beyond migration names

`tools/schema_fingerprint.sql` (one read-only `SELECT` over the catalogs) was run on production and on a fresh local apply of HEAD's 134 migrations (`tools/backend_behaviour.sh` scaffold, session time zone UTC). Per-kind hashes:

| Kind | Rows (local) | Production = local? |
|---|---|---|
| columns (`col`) | 1036 | **identical** (`6db5192868f3`) |
| constraints (`con`) | 390 | **identical** (`2bf574c0156f`) |
| indexes (`idx`) | 238 | **identical** (`4df90eed4925`) |
| policies (`pol`, incl. `storage.objects`) | 155 | **identical** (`3a19be695b5e`) |
| tables, RLS and anon/authenticated grants (`tbl`) | 95 | **identical** (`f405b704a8ee`) |
| triggers (`trg`) | 140 | **identical** (`bf9f45747c1c`) |
| functions (`fn`: body hash, definer, config, return, anon/authenticated EXECUTE) | 243 | **one real drift**: production grants `anon` EXECUTE on `public.set_default_account(uuid)` (SECURITY INVOKER; migration `0025` revokes only from `public`). Plus the scaffold-only `public._dryrun_noop`. Bodies, definer flags and `search_path` settings are otherwise identical |
| cron (`cron`) | 7 | Commands of the shared jobs identical. Differences explained: `affiliate-sync-hourly` is **inactive** in production (changed by hand, not by a migration); `account-deletion-worker`, `account-deletion-purge-expired`, `push-broadcast-retry` are absent locally only because the scaffold has no pg_cron |

Result: the applied schema equals the migration files except one `anon` grant, which goes to the separate grants package (V1-064).

### 7.3 Facts that were unknown in §5

| Item | Finding |
|---|---|
| Plan | Organisation plan **free** |
| Backups | `pitr_enabled false`, `backups []`, `walg_enabled true` (unchanged). No restorable backup is listed |
| Vault (names only) | `account_deletion_worker_secret`, `affiliate_worker_secret`, `engagement_worker_secret`, `notification_retry_worker_secret`, `project_url`, `purge_worker_secret`, `push_broadcast_worker_secret`, `reminders_worker_secret`. **The deletion worker is really called**; engagement triggers make HTTP calls |
| Cron run history (last 24 h) | Every run succeeded: `account-deletion-worker` 288, `notification-retry-dispatch-5min` 288, `push-broadcast-retry` 144, the daily/hourly jobs 1 or 24 |
| Ad flags | All 8: `value 'true'`, `is_active true`, `rollout_percent 100`, `target_countries []`, `updated_at 2026-10-04 14:29:12.530481+00`. `feature_flag_admin_audit` has **no row** for them (set before or outside the audited path) |
| Counts | 11 auth users; `processed_captures` 208 (last 7 days: 96 processed, 8 duplicate, 3 rejected); `deletion_job` 12 completed; orphaned objects: `profile-photos` 0, `backups` 0 |
| AI volume | Per-key daily counters 3–25 calls a day |
| Notifications (7 days) | 1,428 sent, 540 failed, 3 opened, 4 pending. **All 540 failures are `local_ios` with `PlatformException(Error 2003 …)` from one install since 2026-11-07** (passed to the iOS specialist; monitoring signal M5 in RELEASE-PLAN). `notification_retry_queue` empty |
| Admin panel | `admin.qirsh.site` does not resolve; `qirsh.site` (static legal site) returns 404 for `/admin`, `/dashboard`, `/flags`, `/api/feature-flags`; no Vercel/Netlify configuration in the repository. No internet exposure found |

## 8. Final ops pass at `f4dcabd3` (ops specialist, 2026-11-18)

Read-only again: `functions list`, `functions download --use-api` (into the scratchpad); nothing in production was changed. Commands: `bash tools/deploy_set.sh b6fc0dad f4dcabd3`; `SUPABASE_PROJECT_REF=<ref> BACKEND_PG_HOST=127.0.0.1 BACKEND_PG_PORT=<port> bash tools/prod_compare.sh f4dcabd3 b6fc0dad d1212986`; `SUPABASE_PROJECT_REF=<ref> bash tools/prod_compare.sh 4bde299a a106bd6f`.

**Versions** (unchanged since 2026-11-17): 28 deployed; in or near the set: `account-deletion-worker` v5, `process-notification-retries` v12, `process-ios-sms` v27, `parse-sms` v15, `bank-discovery` v10, `enrich-merchant` v8, `merchant-category-contribution` v3, `sync-captures` v7, `send-push-broadcast` v3, `evaluate-budgets` v11, `evaluate-gamification` v8, `evaluate-goals` v8. `verify_jwt` per function equals `supabase/config.toml` (unchanged since `b6fc0dad`).

**Against `f4dcabd3`: 16 IDENTICAL, 12 DIFFERS.**

| Function | Differs from `f4dcabd3` in | Deployed source equals |
|---|---|---|
| `account-deletion-worker` | `_shared/storage_erasure.ts` | `4bde299a` (13 files) |
| `process-notification-retries` | `_shared/capture_push.ts`, `_shared/apns.ts` | `a106bd6f` |
| `process-ios-sms` | parser, AI, redaction, budget-gate modules, `parser_rules.json` | `b6fc0dad` |
| `parse-sms` | same family | `b6fc0dad` |
| `bank-discovery` | `ai_budget_gate.ts`, `ai_spend_guard.ts`, `gemini_request.ts`, `sms_redaction.ts`, `index.ts` | `b6fc0dad`, `d1212986` |
| `enrich-merchant` | `ai_budget_gate.ts`, `ai_spend_guard.ts`, `sms_redaction.ts`, `index.ts` | `b6fc0dad`, `d1212986` |
| `merchant-category-contribution` | `_shared/sms_redaction.ts` | `b6fc0dad`, `d1212986`, `4bde299a` |
| `sync-captures` (not proposed) | `_shared/money_text.ts` (additive exports), `parser_rules.json` | `b6fc0dad` |
| `send-push-broadcast` (not proposed) | `_shared/capture_push.ts` (unused exports) | `b6fc0dad` |
| `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals` (not proposed) | `_shared/apns.ts` (refactor `79a063d8`) | `a106bd6f` |

Every function in the release set therefore has an exact rollback commit; none is without one. `deploy_set.sh b6fc0dad f4dcabd3` prints CHANGED for 8 functions (`bank-discovery`, `enrich-merchant`, `merchant-category-contribution`, `parse-sms`, `process-ios-sms`, `process-notification-retries`, `send-push-broadcast`, `sync-captures`); `account-deletion-worker` is absent from it because `b6fc0dad` already contains `9e19c3e4`.

**Schema of a fresh apply of `f4dcabd3`** (local PostgreSQL 17, `tools/backend_behaviour.sh`: 135 migrations, 13 SQL proofs passed). Per kind, rows and hash: `col` 1044 `a21a417b3719`; `con` 396 `676e94d78dfb`; `cron` 7 `84fc00e184fb`; `fn` 244 `eb753ec02f0d`; `idx` 240 `bc7701444b43`; `pol` 155 `3a19be695b5e`; `tbl` 97 `38b6d3dbfc7b`; `trg` 140 `bf9f45747c1c`. `pol` and `trg` equal production (§7.2); `col`/`con`/`idx`/`tbl`/`fn` differ from §7.2 by exactly M1's two tables and one function (expected until P2); production's schema was not re-read in this pass.
