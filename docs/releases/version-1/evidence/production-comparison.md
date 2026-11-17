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
