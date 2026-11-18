# Version 1 — release plan (deployment, rollout and recovery)

Rewritten 2026-11-17 (closure round) by the backend-privacy-ops specialist (model `claude-opus-5-5`, as stated by the harness) from a second read-only pass over production ([`evidence/production-comparison.md`](evidence/production-comparison.md) §7), the owner decisions D-20 ([`OWNER-BRIEF-ROUND3.md`](OWNER-BRIEF-ROUND3.md) §3, recorded in `docs/project/DECISIONS.md`), and the closure-round work. It replaces the round-2 plan; the round-2 facts that still hold are carried forward. **Regenerated 2026-11-18 from commit `f4dcabd3`** (clean tree) with `tools/deploy_set.sh b6fc0dad f4dcabd3` and the read-only `tools/prod_compare.sh` (production-comparison §8): sections (a), (b), (d), the 147 × new row in (c), the call-site contract in (g) and recovery in (h).

**Candidate.** Commit **`f4dcabd3`**. Every count, version and rollback source below was measured against it on 2026-11-18. If the orchestrator records a later commit in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md), re-run the two commands in (a) there; any difference from the numbers below is a stop condition for P0 until this plan is updated.

**Nothing in this plan has been executed.** No function was deployed, no migration applied, no flag changed, no grant revoked, no backup taken, no build uploaded. Every production step is an owner-approved action.

How production changes are approved: production mutations are collected into **one action package** (section d) plus a **separate grants package** (section e). The owner approves or edits each as a whole. Approval covers the listed steps, in order, within the stated stop conditions; anything listed as excluded is not covered.

---

## (a) Deployed state versus the candidate

Read-only, 2026-11-17 and 2026-11-18 (production-comparison §1, §4, §7, §8). Function versions were re-listed on 2026-11-18 and are unchanged since 2026-11-17.

| Area | Production | Candidate `f4dcabd3` | Consequence |
|---|---|---|---|
| Migrations | 134 applied (`0001`–`0117`, 17 timestamped through `20261117010000`) | 134 + **`20261117120000_ai_global_spend_guard`** | One migration in the package (b, M1). Fresh apply of `f4dcabd3`: 135 migrations, 13 SQL proofs pass (`tools/backend_behaviour.sh`, 2026-11-18) |
| Schema content | Fingerprint equal to a fresh apply of the 134 files except `anon` EXECUTE on `public.set_default_account(uuid)` (§7.2) | Differs from production only by M1's objects | The extra grant goes to the grants package (e) |
| Edge Functions | 28 deployed of 33 | 33 | 5 undeployed by design (D-14, `parser-test`) |
| Identical to `f4dcabd3` | **16** functions | — | Not proposed |
| Differ from `f4dcabd3` | **12** functions: the 7 in the set (b) and 5 not proposed (below) | — | Each is accounted for in (b) |
| `parse-sms` v15, `process-ios-sms` v27 | Identical to `b6fc0dad` (build 147's commit) | New server parser and AI path, redaction, AI budget gate | In the set; parser compatibility condition in (c) |
| `account-deletion-worker` v5 | Erases only `backups`; identical to `4bde299a` | Erases `backups` and `profile-photos` (`9e19c3e4`) | In the set (V1-062) |
| `process-notification-retries` v12 | Identical to `a106bd6f` | `capture_push.ts` words a retried generic push from `captureOutcome` (3.12) | In the set (review T, SP-03) |
| `bank-discovery` v10, `enrich-merchant` v8 | Identical to `b6fc0dad` | Global AI budget gate (Gemini / Places) and the closure-round redaction | In the set (V1-022). `enrich-merchant` makes no Places call today (`GOOGLE_MAPS_API_KEY` unset) |
| `merchant-category-contribution` v3 | Identical to `b6fc0dad` | Only `_shared/sms_redaction.ts` changed; the function accepts a shared-learning key only when `redactPii(key) === key`. Keys can hold no digit or `@`, so the new card/IBAN/account/phone rules cannot apply; the only reachable difference is name masking, which is narrower now (more stop-words), so the new copy can only accept a few keys the old copy refused. Seven synthetic keys gave the same result with both copies | In the set, low risk: the server's rule then equals the device's. It can be dropped from the window without user-visible effect beyond rare refusals |
| `sync-captures` v7 | Identical to `b6fc0dad` | Its closure gains additive `_shared/money_text.ts` exports and the statically imported `parser_rules.json`; the function's own path (`withValidatedExactMoneyText`) is unchanged | Not proposed |
| `send-push-broadcast` v3 | Identical to `b6fc0dad` | Closure includes `_shared/capture_push.ts`, but it imports only `clearDeadApnsToken` / `isDeadApnsToken`, which are unchanged | Not proposed |
| `evaluate-budgets` v11, `evaluate-gamification` v8, `evaluate-goals` v8 | Identical to `a106bd6f` | `_shared/apns.ts` refactor `79a063d8` only | Not proposed (behaviour-preserving refactor; no behaviour need) |
| Secrets (names) | 23 set; `GEMINI_SMS_MODEL`, `GEMINI_MODEL`, `GEMINI_SHADOW_API_KEY`, `GOOGLE_MAPS_API_KEY` unset (defaults apply; Places has no key) | No new secret | Nothing to set |
| Function config | `verify_jwt` per function in the deployed listing equals `supabase/config.toml` (false for the cron/worker functions) | `config.toml` unchanged since `b6fc0dad`; new shared files and `parser_rules.json` are static imports, so the CLI bundles them; no function reads a file at run time | Nothing to change |
| Vault (names) | `project_url`, `account_deletion_worker_secret` and 6 other worker secrets present | — | The deletion worker is really called (288 successful runs in 24 h) |
| Feature flags | All 8 ad flags `value 'true'`, `is_active true`, `rollout_percent 100`, `target_countries []`, `updated_at 2026-10-04 14:29:12.530481+00`; no audit row | V1 build has ads compiled out (D-20) | Turn off (P4) — hygiene for any future ad-capable build; V1 ignores them |
| Backups | Free plan; `pitr_enabled false`; `backups []`; database 28 MB; Storage holds **0 objects** | — | No restorable backup. Owner-run logical dump before M1 (section h) |
| Admin panel | Not reachable on the internet (production-comparison §7.3) | Next.js 15.5.29, 0 production advisories | Not part of this package |

**Commands (read-only) and their 2026-11-18 results.**

```bash
bash tools/deploy_set.sh b6fc0dad f4dcabd3
SUPABASE_PROJECT_REF=<production ref> BACKEND_PG_HOST=127.0.0.1 BACKEND_PG_PORT=<port> \
  bash tools/prod_compare.sh f4dcabd3 b6fc0dad
```

- `deploy_set.sh` prints CHANGED for exactly 8 functions: `bank-discovery`, `enrich-merchant`, `merchant-category-contribution`, `parse-sms`, `process-ios-sms`, `process-notification-retries`, `send-push-broadcast`, `sync-captures`.
- `prod_compare.sh` against `f4dcabd3`: **16 IDENTICAL, 12 DIFFERS**. The 12 are `account-deletion-worker`, `bank-discovery`, `enrich-merchant`, `merchant-category-contribution`, `parse-sms`, `process-ios-sms`, `process-notification-retries`, `send-push-broadcast`, `sync-captures`, `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`.
- **The release set** is the CHANGED list minus `send-push-broadcast` and `sync-captures` (no behaviour difference, shown above), plus `account-deletion-worker` (production predates `9e19c3e4`, which `b6fc0dad` already contains, so `deploy_set` does not list it). The `evaluate-*` functions differ only by the refactor and are excluded. Any other CHANGED or DIFFERS function at a later commit must be added here with a reason or excluded explicitly.
- Schema (fresh apply of `f4dcabd3`, local PostgreSQL 17): `col 1044`, `con 396`, `cron 7`, `fn 244`, `idx 240`, `pol 155`, `tbl 97`, `trg 140` objects (hashes in production-comparison §8). Against production the expected differences are `fn` (new `consume_ai_global_budget`; `set_default_account` anon; scaffold `_dryrun_noop`), `tbl`/`col`/`con`/`idx` (the two guard tables) and `cron` (§7.2). Anything else is a stop condition for P0.

---

## (b) Deployment set

Seven functions and one migration, all from `f4dcabd3`.

**Rollback sources.** For every function in the set, the deployed version and a commit whose source (the function's whole import closure, JSON included) is byte-identical to it, verified with `tools/prod_compare.sh` on 2026-11-18. A rollback is a redeploy from a clean checkout of that commit. P0 also archives the deployed bundles themselves, so a rollback does not depend on this table alone.

| Function | Deployed | Rollback source (identical to deployed) | Why in the set |
|---|---|---|---|
| `account-deletion-worker` | v5 | `4bde299a` (the parent of `9e19c3e4`) | V1-062: the deployed worker leaves `profile-photos/<uid>/` when it completes a deletion |
| `process-notification-retries` | v12 | `a106bd6f` (the parent of `79a063d8`) | SP-03: the deployed copy ignores `captureOutcome`, so after the new `process-ios-sms` a retried generic push would say "New transaction captured" for a declined, excluded or review capture |
| `process-ios-sms` | v27 | `b6fc0dad` | V1-001/V1-078 server parser fixes; AI understanding (message type and status before amount, evidence checks, untrusted-text delimiting); V1-060 grounded amounts; redaction; AI budget gate |
| `parse-sms` | v15 | `b6fc0dad` | Same as `process-ios-sms` (shared parser and AI modules) |
| `bank-discovery` | v10 | `b6fc0dad` (also `d1212986`) | V1-022 budget gate on Gemini; redaction |
| `enrich-merchant` | v8 | `b6fc0dad` (also `d1212986`) | V1-022 budget gate on Places; redaction |
| `merchant-category-contribution` | v3 | `b6fc0dad` (also `d1212986`, `4bde299a`) | The server's key rule (`redactPii(key) === key`) equals the new device's |

No function in the set lacks a matching commit. For completeness, the excluded functions that differ: `sync-captures` v7 and `send-push-broadcast` v3 equal `b6fc0dad`; `evaluate-budgets` v11, `evaluate-gamification` v8, `evaluate-goals` v8 equal `a106bd6f`.

| | M1 migration `20261117120000_ai_global_spend_guard` | `account-deletion-worker` | `process-notification-retries` | `process-ios-sms` + `parse-sms` | `bank-discovery` + `enrich-merchant` | `merchant-category-contribution` |
|---|---|---|---|---|---|---|
| **What it does** | Creates `public.ai_global_budget` (seeded `gemini` 3000/day, `places` 1000/day, `enabled true`) and `public.ai_global_spend` (day, bucket, calls, denied) — RLS on, no client grants; and `public.consume_ai_global_budget(bucket, units)` (SECURITY DEFINER, `search_path` pinned, EXECUTE to `service_role` only) that reserves atomically and returns `{allowed, reason, used, limit}` | Bundles the two-bucket `storage_erasure.ts` | Retried generic pushes are worded from `captureOutcome`; old rows without it get the old wording. Also brings the `79a063d8` sender refactor (behaviour-preserving by design, not proven) | New server parse and AI path | Gate before each paid call | New `redactPii` decides which keys are accepted |
| **Lock and risk** | Additive and idempotent (`create … if not exists`, `on conflict do nothing` seed); new objects only; no lock on an existing table; no data rewrite. Proof: `supabase/tests/ai_global_spend_guard_20261117.sql` (9 checks) and `tools/backend_behaviour.sh` (135 migrations) | No schema change | No schema change | No schema change; build-147 condition (c) | No schema change | No schema change; can only accept a few more keys than the old copy |
| **Depends on** | Nothing | Vault names present; secrets `ACCOUNT_DELETION_WORKER_SECRET`, `ACCOUNT_DELETION_SEALER_KEY`, `APPLE_*`, platform `SUPABASE_*` — all set | Secrets `APNS_*`, `NOTIFICATION_RETRY_WORKER_SECRET`, Vault `notification_retry_worker_secret` — present. Deploy **before** `process-ios-sms` | `GEMINI_API_KEY`, `APNS_*`, `ENGAGEMENT_WORKER_SECRET`, platform `SUPABASE_*` — set. M1 first | M1 first; `GEMINI_API_KEY` set | Nothing |
| **Verification after** | `select count(*) from supabase_migrations.schema_migrations` = 135; `select bucket, daily_limit, enabled from public.ai_global_budget;` = 2 rows; `select has_function_privilege('anon','public.consume_ai_global_budget(text,integer)','EXECUTE')` = false; `fn`/`tbl` fingerprint as in (a) | `cron.job_run_details` for `account-deletion-worker` all `succeeded` for 2 hours; M2 stuck = 0; M3 stays 0 | `cron.job_run_details` for `notification-retry-dispatch-5min` all `succeeded` for 2 hours; M6 backlog 0 | Smoke tests S1–S4 in (d) | Smoke test S5 in (d) | Smoke test S6 in (d) |
| **Undo** | **Rolling M1 back while the new functions are deployed removes the ceiling silently** (the gate treats a missing guard function, PGRST202 / 42883, as absent and calls the provider: no outage, no limit). To limit or stop AI use `update public.ai_global_budget set daily_limit = … / enabled = false`. Full undo: (1) redeploy the AI functions from their rollback sources, (2) `supabase/rollback/20261117120000_ai_global_spend_guard_rollback.sql` (rehearsed locally: apply → rollback → re-apply), (3) `delete from supabase_migrations.schema_migrations where version = '20261117120000';` | Redeploy from `4bde299a`; re-opens the photo gap | Redeploy from `a106bd6f`, **after** `process-ios-sms` has been rolled back | Redeploy both from `b6fc0dad` | Redeploy both from `b6fc0dad` | Redeploy from `b6fc0dad` |
| **Rehearsed** | Locally on PostgreSQL 17: yes. Against production-shaped data: no | No | No | No | No | No |

**Not proposed:** `sync-captures`, `send-push-broadcast`, `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`; the 16 functions identical to `f4dcabd3`; the 5 undeployed functions; any secret, Vault, Auth, cron or `config.toml` change.

---

## (c) Compatibility matrix

Build 147 = commit `b6fc0dad` (iOS, `ios-signed`, internal TestFlight). "Old backend" = production today. "New backend" = section (b) deployed. Cloud on = the user accepted Smart Analysis & Cloud Sync. Evidence: code inspection by the `ai` specialist (closure/ai.md §3) and this specialist; **no pair was run end to end**.

| App × backend | Cloud/AI off | Cloud/AI on |
|---|---|---|
| **147 × old** (today) | Device-only parse; no catalog, flags or force-update notices; ads impossible (no AdMob IDs in 147) | Server parse with declined purchases accepted (V1-001); shared learning ON by default for 147 users (old missing-key = ON) |
| **147 × new** | No change: 147 sends nothing | **Parser outcomes: see "Build-147 parser condition" below; P3 parser deploy depends on it.** Measurement: for every held-out message (`tools/message_eval/heldout`), take `f4dcabd3`'s server result (`deno/server_eval.ts`, the server-only reading) and pass it through build 147's own import (`dart/message_eval_test.dart` and `CaptureImportService` at `b6fc0dad`, which applies `localParseContradictsServer` and the `forceLocalAutoConfirm` re-parse); compare with the same messages through `b6fc0dad`'s server. Report per class: booked as income for a purchase, silent (neither recorded nor in review), wrong amount, declined counted. **Accept only if no total-changing class is worse than 147 with today's server.** The runner's mixed mode does this (`MESSAGE_EVAL_SERVER_REV=<server commit>` in `tools/message_eval/run.sh`; evaluation owner, not ops). Shapes: response shapes are supersets; 147 reads named keys only. More messages come back as not-a-transaction / `ai_ignored` → 147 sends them to Smart Inbox unless its deterministic filter drops them. Server rejections of declined/failed messages make 147 **re-parse locally and confirm** (`forceLocalAutoConfirm`), so a declined purchase can still be counted on 147 (V1-056, known). If the guard ceiling is reached: `parse-sms` returns the existing retryable error → 147 falls back to local parsing (no new failure mode). Deletion worker: no client involvement. 147 keeps contributing shared learning (server unchanged; the transition prompt exists only in the new build) |
| **new × old** | Device-only; catalog not fetched (gated on Cloud consent) | Old `parse-sms` ignores the new request fields (`local_evidence`, `account_currency`); no `message_type/status` → device judges as before; no-currency messages stay in review. Old `process-ios-sms` still returns declined purchases as processed → the new build's import re-check holds contradicting results for review. Ads compiled out whatever the flags. Deletion with profile photo: inline path erases both buckets; worker-completed path leaves the photo until the worker is deployed |
| **new × new** | Device-only | Designed pair (all closure-round behaviour) |

**Build-147 parser condition (gate for `process-ios-sms` and `parse-sms`).** Condition: **no class that changes totals is worse for a build-147 user after the server deploy** than for the same user with today's server (`b6fc0dad`). Classes: purchase booked as income; completed purchase silent (neither recorded nor in review); wrong amount; declined, failed, refunded-pending or scheduled message counted as spending.

> **MEASUREMENT AT `f4dcabd3`** (orchestrator, from the evaluation specialist's run; `evidence/closure/eval.md` §12)
>
> Runner and mode: `tools/message_eval/run.sh b6fc0dad` with `MESSAGE_EVAL_SERVER_REV` (build 147's own import code, server step from the named commit), Cloud on, deterministic path · Message set and count: the 753 synthetic held-out messages · Date: 2026-11-18
>
> | Class (messages) | 147 × `b6fc0dad` server | 147 × `f4dcabd3` server | Worse by |
> |---|---|---|---|
> | Pending refund booked | 12 | 0 | 0 |
> | Pending or scheduled booked | 24 | 20 | 0 |
> | Declined or failed booked | 43 | 40 | 0 |
> | Wrong direction (includes a purchase booked as income) | 32 | 12 | 0 |
> | Wrong currency | 16 | 0 | 0 |
> | Wrong amount | 7 | 0 | 0 |
> | Balance / bill / marketing notice booked | 8 / 12 / 12 | 4 / 4 / 4 | 0 |
> | Expected salary booked | 12 | 12 | 0 |
> | Ambiguous booked | 4 | 4 | 0 |
> | Completed message lost (neither recorded nor in review) | 8 | 0 | 0 |
>
> **Total-changing classes worse: `0`** (must be 0 for the parser functions to go in P3). Completed messages that a 147 user newly finds in review rather than saved: 4 (no money effect).
>
> Limits of this measurement: synthetic messages by one author, not real bank traffic; the set was used earlier in the round to find failing families, which were then fixed with fresh sibling examples, so it is weaker evidence than a first run. The independent reviewer's separate probe sets found, at `6f771108`, 2 of 578 messages where a 147 user is worse because the new server holds a message for review and build 147 falls back to its own old parse ("Credit card payment … received" booked as spend; a purchase with an injected salary sentence booked as income); see `evidence/audits/S-review-money-correctness.md` for the check at `f4dcabd3`. A 147 user keeps every defect of build 147's own parser on the local path until they update.

**If that number is not zero**, the owner chooses one of:
1. **Hold the parser functions** (`process-ios-sms`, `parse-sms`) until the new build from `f4dcabd3` has reached every internal tester and build 147 is no longer used (TestFlight expiry or tester confirmation). `process-notification-retries` is then also not needed yet and can wait with them.
2. **Ship now only the functions that do not change build-147 results:** M1, `account-deletion-worker`, `bank-discovery`, `enrich-merchant`, `merchant-category-contribution` (and `process-notification-retries`, which is backward-compatible with old notification rows, though it only matters once the new `process-ios-sms` writes `captureOutcome`). None of these decides whether a 147 user's message is recorded, its amount or its direction: `bank-discovery` only identifies banks, `enrich-merchant` only adds merchant details, `merchant-category-contribution` only accepts or refuses shared-learning keys, and the deletion worker and the migration have no client involvement. Effect of the gate on 147: when the ceiling is reached, `parse-sms` returns the existing retryable error and 147 falls back to local parsing (no new failure mode).

In both cases P3 is split: the non-parser functions go in the window, the parser functions go in a later window under the same smoke tests (S1–S4).

**Currencies (review T, SP-04).** Storable currencies grew from 50 to 155 (`kCurrencyScale`). Read in build 147's code (`git show b6fc0dad:…`): `Money.parse` → `currencyScale()` throws `UnsupportedCurrencyException` for a code outside its 50. **Ledger:** `ledger_sync_service.dart` `_applyRowOrQuarantine` catches it, stores the raw row in `parked_child_rows` (reason `quarantine`), advances the cursor, retries up to 5 pulls, then marks it `terminal` (kept, counted, not shown). **Planning:** `planning_pull_service.dart` `_quarantineUnresolved` parks budgets/goals as `unresolved_currency`; 147 has a repair flow (`planning_server_currency_repair.dart`, `planning_currency_repair_screen.dart`) in which the user picks one of the 50 currencies — whether that rewrites the server row's currency was **not traced** and would change the row for the other device. No crash path found (review T). Effect: only a user who picks one of the 105 new currencies on a new-build device **and** still runs 147 on another device sees those transactions and plans missing on the 147 device, with no message. Options (owner/data): (1) accept and document as a known limitation, since 147 is an internal TestFlight build that expires 90 days after upload; (2) ask internal testers to update every device before choosing a new currency (release note); (3) hold the new currencies behind a flag until 147 has expired; (4) server-side, reject the 105 new codes until then — not proposed, it would break the new build. Recommendation: (1) + (2).

**Consent transitions to re-check on the final build:** 147 user with Cloud on upgrades → Cloud stays on, shared learning is OFF until they answer the one-time prompt; 147 user with Cloud off upgrades → stays local, no prompt; turning off on the new build → "Turn off both" stops sync, AI, retries and new contributions.

**Sign-in compatibility (3.11).** `ios-signed-release` now sets `QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED` and `QIRSH_ALTERNATE_SIGNUP_ENABLED` to `"true"` in its `vars` (`ios` specialist), matching build 147. Verify the resolved values in the release build log before upload.

**Re-check before P3:** the build-147 measurement above is filled; the Codemagic sign-in variables. (Guard integration and `prod_compare.sh` were re-checked at `f4dcabd3`, section a.)

---

## (d) Action package for approval

**Status: NOT EXECUTED.**

Operator: `______` (owner fills). Window: `______`. Estimated operator time (not measured): 1–2 hours plus the observation window.

**Preconditions (none is a production action)**
1. The release commit is `f4dcabd3` (or a later commit for which (a) has been re-run and this plan updated); the strict gate passed at it, and the opt-in backend stage passed at it (`BACKEND_PG_HOST=… REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`; JSON field `backend_behaviour: passed` — passed at `f4dcabd3` on 2026-11-18: 135 migrations, 13 proofs).
2. The build-147 parser condition in (c) is filled. If it is not zero, the parser functions leave P3 (see (c)).
3. Parser/AI conditions for P3 (DECISIONS-NEEDED B28–B30 and the bounded real-model evaluation), and a new app build from the same commit ready for testers in the same window (V1-087).
4. A clean checkout of the release commit **and** clean checkouts (or `git worktree add`) of the rollback commits `4bde299a`, `a106bd6f`, `b6fc0dad`; Supabase CLI signed in, project ref `<ref>`.
5. The owner-run backup in section (h) exists and its listing check passed (required before P2; recommended before P1).

**P0 — download and archive the deployed source bundle of every function in the set (SP-14), then verify.** Read-only. Run from the repository root:

```bash
REF=<production ref>
ARCHIVE="$HOME/QirshSecure/function-archive/$(date -u +%Y%m%dT%H%MZ)"   # outside the repository
mkdir -p "$ARCHIVE"
supabase functions list --project-ref "$REF" -o json > "$ARCHIVE/functions-list.json"
for fn in account-deletion-worker process-notification-retries process-ios-sms parse-sms \
          bank-discovery enrich-merchant merchant-category-contribution; do
  mkdir -p "$ARCHIVE/$fn" &&
  (cd "$ARCHIVE/$fn" && supabase functions download "$fn" --project-ref "$REF" --use-api --workdir .) ||
  { echo "STOP: download failed for $fn"; break; }
done
tar czf "$ARCHIVE.tar.gz" -C "$(dirname "$ARCHIVE")" "$(basename "$ARCHIVE")"
shasum -a 256 "$ARCHIVE.tar.gz" > "$ARCHIVE.tar.gz.sha256"
SUPABASE_PROJECT_REF="$REF" bash tools/prod_compare.sh f4dcabd3 b6fc0dad 4bde299a a106bd6f
```

Expected: every download succeeds; `functions-list.json` shows `account-deletion-worker` v5, `process-notification-retries` v12, `process-ios-sms` v27, `parse-sms` v15, `bank-discovery` v10, `enrich-merchant` v8, `merchant-category-contribution` v3; `prod_compare.sh` prints IDENTICAL for each function against its rollback source in (b), 16 IDENTICAL / 12 DIFFERS against `f4dcabd3`. The archive holds function source, not user data; keep it with the backup and delete it with the backup when the observation window ends.

**Stop P0 (do not start P1) if:** any download fails; any version differs from the list above (someone deployed since 2026-11-18 — re-run (a) and update this plan); any function in the set is not IDENTICAL to its rollback source; the counts against `f4dcabd3` differ from 16/12; a secret or Vault name in (a) is missing; schema drift beyond the expected kinds in (a).

Other P0 read-only checks: `supabase secrets list --project-ref "$REF"` (names only); `select name from vault.secrets order by name;`; monitoring baseline queries M1–M7 (g). Record results in `evidence/` (counts and names only).

| Step | Action | Exact command | Post-check | Stop if |
|---|---|---|---|---|
| **P0** | Archive and verify (above) | above | Archive and checksum exist; expected output | Stop conditions above |
| **P1** | Deploy `account-deletion-worker` | `supabase functions deploy account-deletion-worker --project-ref <ref>` (`config.toml` keeps `verify_jwt = false`) | (b) verification | Deploy error; a `failed` worker run → redeploy from `4bde299a` |
| **P2** | Apply M1 | `supabase db push --linked --dry-run` must list exactly `20261117120000_ai_global_spend_guard.sql`; then `supabase db push --linked`. (Alternative: paste the file into the SQL editor and record the version with `insert into supabase_migrations.schema_migrations(version, name) values ('20261117120000','ai_global_spend_guard');`) | (b) verification | Dry run lists any other file; any error |
| **P3** | Deploy, in this order, after P2: `process-notification-retries`, `process-ios-sms`, `parse-sms`, `bank-discovery`, `enrich-merchant`, `merchant-category-contribution` | `supabase functions deploy <fn> --project-ref <ref>` for each, one at a time, from the `f4dcabd3` checkout. **If the build-147 condition (c) is not zero, skip `process-ios-sms` and `parse-sms` (and optionally `process-notification-retries`) and deploy them in a later window** | Smoke tests S1–S6 below; MDT-IOS-07b/-07d on the new build | Any condition in the smoke-test table; then roll back that function (and, for `process-notification-retries`, `process-ios-sms` first) |
| **P4** | Advertising flags off (D-20) | SQL below | Read-back query below | Any other flag changed; the function raises (stale `updated_at` → re-read and stop) |
| **P5** | Observe | Section (g) daily | Recorded daily, window `______` (proposed 7 days) | Any stop condition in (g) |

**P3 smoke tests** (synthetic test account and synthetic messages only; no real bank text):

| # | After | Test | Pass | Stop and roll back if |
|---|---|---|---|---|
| S1 | `process-ios-sms` | New build, Shortcut path: synthetic declined samples (S04, S19), a completed purchase (S21) and the "available limit" purchase | Declined → not recorded as spending, item in review; S21 and the "available limit" purchase recorded with the amount in the text | A declined sample counted; a completed purchase neither recorded nor in review; a new error class in the logs |
| S2 | `parse-sms` | New build: paste a synthetic purchase. Build 147 (if still installed on a test device): the same synthetic purchase | Amount in the text recorded on both; 147 behaves as with today's server | Amount differs from the text; 147 books a purchase as income |
| S3 | `process-notification-retries` | Synthetic account with notification content hidden: a declined sample's push or its retry | Reads as declined, not "New transaction captured"; `notification-retry-dispatch-5min` runs `succeeded` | Wrong wording; a `failed` cron run |
| S4 | AI functions | `select day, bucket, calls, denied from public.ai_global_spend where day = current_date;` after S1/S2 | `gemini` calls increased, `denied` 0 (the gate is integrated and the ceiling is not hit) | No row after AI-path captures (gate not reached); `denied > 0` on day one |
| S5 | `bank-discovery`, `enrich-merchant` | New build: a synthetic message from an unknown synthetic sender; a merchant enrichment request | Both return as before; `gemini` calls increment for bank discovery; no `places` row while `GOOGLE_MAPS_API_KEY` is unset | Error responses; a `places` row without a Places key |
| S6 | `merchant-category-contribution` | Synthetic account with shared learning on: recategorise a merchant with a plain synthetic name (e.g. `COFFEE HOUSE` → dining) | Accepted (HTTP 200), exactly as the new device decides to send it | Refused, or the device and server disagree on a key |

**Undo order (P3 and earlier), reverse of deployment:** `merchant-category-contribution`, `enrich-merchant`, `bank-discovery` (each from `b6fc0dad`); `parse-sms`, `process-ios-sms` (from `b6fc0dad`); `process-notification-retries` (from `a106bd6f`, only after `process-ios-sms` is back); M1 per (b) only if needed — prefer `enabled = false`; `account-deletion-worker` (from `4bde299a`). Each redeploy is `supabase functions deploy <fn> --project-ref <ref>` from a clean checkout of the rollback commit; if a checkout is not at hand, the P0 archive holds the exact deployed source.

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

**Excluded from this package:** the grants package (e); `sync-captures`, `send-push-broadcast`, `evaluate-budgets`, `evaluate-gamification`, `evaluate-goals`, the 16 identical and 5 undeployed functions; any secret, Vault, Auth, cron or `config.toml` change; enabling PITR or any plan change; cleanup of any stored data (Storage holds no objects today); admin panel deployment; Codemagic runs, TestFlight or App Store actions (section f); publishing the legal site (owner runs `tools/deploy_site.sh` only after the V1 app is live, see the note in `docs/legal/PRIVACY_POLICY.md`).

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

**Build workflow.** `ios-signed-release` (hardened locally in `4fc2ecd6`; now attaches no `admob` group, so the release build has no AdMob identifier and does not pass `QIRSH_ADS_ENABLED`) has **never run on Codemagic**. Before the first run the owner checks, by name only: group `supabase` (`SUPABASE_URL`, `SUPABASE_ANON_KEY`); `EXPECTED_REVIEWED_CI_SHA`; `SENTRY_DSN`; `LEGAL_BASE_URL` (unset = `https://qirsh.site`); `GOOGLE_SERVER_CLIENT_ID`; `QIRSH_GOOGLE_AUTH_ENABLED` and `QIRSH_EMAIL_AUTH_ENABLED` (set to `true` in the workflow `vars`; confirm in the build log, section c); `QIRSH_ALTERNATE_SIGNUP_ENABLED` (default `true`); `codemagic_asc_api_key`; signing for `com.youssefsafwat.mali` and the share extension; a protected `release/*` branch.

**Stages** (store actions, outside (d)): internal TestFlight → MANUAL-DEVICE-TESTS (G5) → external TestFlight (Beta App Review) → App Store, manual release. Phased release applies to updates only.

**Version identity.** 147 and 1.0.0 both send `X-App-Version: 1.0.0`; a force-update notice cannot target 147, and Cloud-off users receive no notices at all (V1-045, now stated in the policy). Backend changes must therefore stay compatible with 147 (section c).

**Export compliance (V1-026).** See STORE-READINESS A14: the app ships standard encryption not provided by iOS (SQLCipher/`sqlite3mc`, Dart `cryptography`), so `ITSAppUsesNonExemptEncryption` should be `true` and App Store Connect answered "standard encryption algorithms"; either exclude France or upload the French declaration.

**Android.** Out of V1 (D-20, 3.1).

---

## (g) Monitoring, thresholds, actions

All queries are read-only and return counts; run them in the SQL editor (UTC). Baselines measured 2026-11-17 are given where available. There is **no alerting**: a named person must run these daily during the window.

| # | Signal | Query | Baseline (2026-11-17) | Threshold → action |
|---|---|---|---|---|
| M1 | Cron failures | `select j.jobname, d.status, count(*) from cron.job_run_details d join cron.job j using (jobid) where d.start_time > now() - interval '24 hours' group by 1, 2 order by 1, 2;` | All `succeeded` (deletion worker 288, notification retry 288, push retry 144) | Any `failed` for `account-deletion-worker` on 2 consecutive runs → stop P5 widening; check function logs; if caused by P1, redeploy from `4bde299a` |
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
- If `decision.allowed` is false (`ceiling`, `disabled`, `unknown_bucket`, or `unavailable` when the RPC fails for any other reason — those fail closed), **do not call the provider**: in `process-ios-sms` send the capture to review the way a provider outage does today; in `parse-sms` return the existing retryable `upstream_unavailable` response.
- **One exception, fail-open:** when the RPC reports that `consume_ai_global_budget` does not exist (PGRST202 / 42883 — M1 not applied, or rolled back), the gate lets the call proceed as before the guard. This is why deploy order cannot cause an outage, and also why rolling back M1 silently removes the ceiling (b). Any other RPC failure is closed.
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
- Function deploy: redeploy the rollback source in (b) (`4bde299a`, `a106bd6f` or `b6fc0dad`), in the undo order in (d); the P0 archive holds the exact deployed bundles if a commit cannot be checked out. Not rehearsed.
- M1: functions first, then the rollback file (b); rolling M1 back alone removes the ceiling without an outage. Rehearsed locally.
- Flags: P4 rollback SQL. Grants: (e) rollback SQL.
- Bad mobile build: expire in TestFlight; pause phased release (updates only); forward fix with a higher build number.
- Data already sent to a third party: cannot be recalled; contain (kill switches in g) and follow INCIDENT-AND-RECOVERY.

---

## Status

| Item | State |
|---|---|
| Read-only production comparison (functions, schema content, Vault names, cron history, flags, backups, counts) | Done 2026-11-17; functions re-run 2026-11-18 at `f4dcabd3` (16 IDENTICAL / 12 DIFFERS; rollback sources found for all 7 in the set) |
| M1 migration and guard module | Prepared and tested locally; called by `parse-sms`, `process-ios-sms`, `bank-discovery`, `enrich-merchant` at `f4dcabd3`; backend stage passed there 2026-11-18 |
| Build-147 parser condition (c) | **Placeholder — orchestrator to fill** |
| Deployment P0–P5 | Not executed |
| Grants package (e) | Prepared; not executed; not rehearsed |
| Owner-run backup (h) | Proposed; not run |
| Release workflow run, Codemagic sign-in variables | Not run / owner to check |
| Any undo or restore rehearsed against production | No |
