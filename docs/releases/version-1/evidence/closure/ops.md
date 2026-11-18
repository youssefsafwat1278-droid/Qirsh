# Closure round — backend, privacy, operations (ops)

- Specialist: BACKEND-PRIVACY-OPS. Model: `claude-opus-5-5` (Opus 5.5), as stated by the harness's system context; no other way to inspect it.
- Date: 2026-11-17. Base: HEAD `d1212986`, working tree with the other specialists' uncommitted changes. **Nothing committed** (closure brief).
- Production: read-only only (CLI list/download/secrets-names/backups; connector `SELECT`s returning catalog facts and counts). **Nothing in production was changed.** No user rows exported; no secret value read.

## 1. Status per item

| # | Item | Status | Files |
|---|---|---|---|
| 1 | Owner decisions recorded | DONE | `docs/project/DECISIONS.md` (D-20, supersedes D-19's ads position and the 30-day deletion brief) |
| 2 | Legal text | DONE (not published) | `docs/legal/PRIVACY_POLICY.md`, `docs/legal/TERMS.md` |
| 3 | Store privacy answers (V1-003), export compliance (V1-026) | DONE (answers + precise counsel question); console entry is the owner's | `STORE-READINESS.md` (closure section), `evidence/official-doc-checks.md` §e |
| 4 | Admin advisories (V1-025) | DONE | `admin/package.json`, `admin/package-lock.json`, `admin/tsconfig.json`, `admin/app/api/referral-users/[id]/route.ts` |
| 5 | AI spend containment (V1-022) | PARTIAL — migration, guard and tests done; call sites are the `ai` specialist's | `supabase/migrations/20261117120000_ai_global_spend_guard.sql`, `supabase/functions/_shared/ai_spend_guard.ts` + `_test.ts`, plus rollback and SQL proof (see §5) |
| 6 | Monitoring (V1-024) | DONE (queries, baselines, thresholds, actions; no alerting exists) | `RELEASE-PLAN.md` (g) |
| 7 | Backup/recovery (V1-023) | DONE (assessment + owner-run dump proposal; not run) | `RELEASE-PLAN.md` (h) |
| 8 | Opt-in backend stage (V1-013) | DONE | `tools/ci_gates.sh`, `tools/backend_behaviour.sh` (+ contract test, §5) |
| 9 | Compatibility matrix | DONE (code inspection; no pair run end to end) | `RELEASE-PLAN.md` (c) |
| 10 | RELEASE-PLAN as one package | DONE | `RELEASE-PLAN.md`, `evidence/production-comparison.md` §7, `docs/project/MIGRATION_LEDGER.md`, `tools/prod_compare.sh`, `tools/schema_fingerprint.sql` |
| 11 | Reviewer access (V1-015) | DONE — Sign in with Apple path; no blocker found | `REVIEWER-NOTES-DRAFT.md` |

**This adds a migration to the production package** (`20261117120000`, additive, idempotent, no lock on existing tables). Include it only when the final commit calls the guard.

## 2. Tests — before / after

| Test | Before | After |
|---|---|---|
| `supabase/tests/ai_global_spend_guard_20261117.sql` (9 checks: calls under the ceiling allowed, calls past it refused, counter never exceeds the ceiling and counts refusals, disabled bucket refuses, unknown bucket refuses, an over-size reservation is refused whole, `p_units = 0` rejected, no client EXECUTE/SELECT/UPDATE, seeded buckets exist; idempotent re-apply checked separately) | Fails: relation does not exist | 9/9 pass; migration applies twice; rollback → re-apply round trip works |
| `supabase/functions/_shared/ai_spend_guard_test.ts` (Deno, 4 tests: allowed, refusals, fail-closed on RPC error/throw/malformed, unit validation) | Module did not exist | 4/4 pass; `deno lint` clean |
| `tools/backend_behaviour.sh` on a dedicated local PostgreSQL 17 | Stage did not exist | `BACKEND BEHAVIOUR PASSED (135 migrations, 13 proofs)`, ~27 s; re-run at the end of the round: pass |
| `supabase/tests/backend_behaviour_stage_contract_test.mjs` (opt-in, not-run ≠ pass, refuses non-local host / no host / non-dedicated cluster) | Did not exist | 6/6 pass; `ci_gates_contract_node_test.mjs` 9/9 pass |
| `supabase/tools/check_migrations.sh` | — | pass |
| Admin: `npm audit --omit=dev` | next 14.2.35: critical/high group (image-optimizer RCE, SSRF, DoS…) + postcss high | 0 (next 15.5.29, postcss override ^8.5.33); dev-only advisories remain (brace-expansion, baseline-browser-mapping) |
| Admin: `next build`; `test:auth` | Build ok; 190 pass / 1 skipped | Build ok (52 pages); 190 pass / 0 fail / 1 skipped (same as baseline). Runtime unauthenticated: every page and `/api/*` → 307 `/login`; `/_next/image` → 404. **Signed-in admin path NOT TESTED** |
| Flutter: `legal_urls_test`, `ai_egress_consent_test`, `android_sms_permission_test`, `public_copy_truthfulness_test`, `report_ads_guards_test` | 2 failed on my first policy draft (wording they pin) | All pass after aligning the wording; no test changed |
| `tools/build_site.py` | — | Builds; output deleted |

**Existing tests whose expectations I changed: none.**

Observed, not mine: `supabase/tests/codemagic_ios_store_pipeline_contract_test.mjs` fails 3/13 against the uncommitted `codemagic.yaml` (ios/CI owner's edit removing the `admob` group and related steps).

## 3. Production facts (new)

- Free plan; `pitr_enabled false`; `backups []`; DB 28 MB, PostgreSQL 17.6; Storage 0 objects.
- `parse-sms` v15 and `process-ios-sms` v27 are **identical to `b6fc0dad`** (build 147) → exact rollback source. `account-deletion-worker` v5 matches neither HEAD nor `b6fc0dad`.
- Schema fingerprint equals a fresh apply of the 134 files except: `anon` EXECUTE on `set_default_account(uuid)` (grants package), `affiliate-sync-hourly` inactive by hand.
- Vault names present (deletion worker runs: 288 successes/24 h). All cron runs succeeded.
- Ad flags: `value 'true'`, active, 100 %, `updated_at 2026-10-04 14:29:12.530481+00`, no audit rows.
- Notifications: 540 `local_ios` failures in 7 days (error 2003) from **one** account → `ios` specialist; 2 `processed_captures` stuck in `processing` > 1 h (explain in P0).

## 4. Could not verify

Signed-in admin runtime; any deploy, undo or restore against production; the guard under real traffic (not integrated); whether App Review accepts "not collected" for a linked, never-started GMA SDK; export classification (counsel); Supabase fixed email OTPs; the four compatibility pairs end to end; Codemagic variable values.

## 5. Changes needed in files I do not own

1. **ai**: call `consumeGlobalAiBudget` per the contract in RELEASE-PLAN (g) in `parse-sms`, `process-ios-sms` (`'gemini'`) and `enrich-merchant` (`'places'`).
2. **ios**: `ITSAppUsesNonExemptEncryption` → `true`; Product Interaction purpose → App Functionality (or both); add Other Data Types (date of birth) or stop syncing it; consider removing `google_mobile_ads` from the V1 binary; investigate the error-2003 notification failures.
3. **ios/CI**: `ios-signed-release` must enable Google and email sign-in (`QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED` = true) or 147 users lose sign-in methods; the 3 failing codemagic contract tests.
4. **consent/data**: `deleteAccountAcceptedBody` said the request could be "cancel"led — resolved in the working tree by 2026-11-18 (see §7).
5. **Orchestrator**: my new files outside my listed paths, required by lint or tests: `supabase/rollback/20261117120000_ai_global_spend_guard_rollback.sql`, `supabase/tests/ai_global_spend_guard_20261117.sql`, `supabase/tests/backend_behaviour_stage_contract_test.mjs`.
6. Admin `env-guard` / `dev-local.mjs` list old project refs, not `rjwphwsefnuotpbtuycf` (noted, not fixed).

Statements for final reconciliation (other specialists' code, read as it stood): ads compiled out and SDK never initialised; consent wording, shared-learning transition and combined turn-off; final deletion and the "earlier request will not be carried out" copy; catalog gated on Cloud consent; country coverage note; legal links open with Cloud off; AI requests carry local evidence and account currency.

## 6. Owner actions

1. Approve or edit the action package (RELEASE-PLAN d: P0–P5) and, separately, the grants package (e).
2. Before P1/P2, run the logical backup in (h) and keep it in protected storage.
3. Set the Codemagic sign-in variables for `ios-signed-release`.
4. Export compliance: answer "standard algorithms"; decide France (declaration or exclude); send the counsel question (STORE-READINESS A14).
5. Enter the App privacy answers (STORE-READINESS closure table) after reconciling items in §5.2.
6. After the V1 app is live and P1 is deployed: redeploy the legal site with `tools/deploy_site.sh` (not run by this work).
7. Choose one support address; set a Google Cloud budget alert on the Gemini project; fill in the monitoring owners and windows.

## 7. Follow-up (2026-11-18, orchestrator request): reconciled with `consent` and `ai`

Read `evidence/closure/consent.md`, `evidence/closure/ai.md` and the code as it stands (`ai_parser_client.dart` `AiParseContext`, `gated_url_launcher.dart`, `shared_learning_preference.dart`, `_shared/ai_budget_gate.ts`, `parse-sms`/`process-ios-sms` call sites).

| Point | State in `docs/legal/PRIVACY_POLICY.md` |
|---|---|
| 1 Catalog / force-update with Cloud off (B14: egress kept closed) | §3 "What happens with Smart Analysis & Cloud Sync off": no catalog, flag or update-notice request; no in-app update notice. The old "Always allowed … anonymous" text is gone |
| 2 Shared learning | Included when the user agrees; a missing preference is OFF; users who consented earlier stay off unless they agree when asked once (§3 table, §4) |
| 3 Combined consent and withdrawal | §1, §4: one choice turns Cloud and AI on; "Turn off both" stops both, including retries and new contributions; anything already sent cannot be recalled |
| 4 Legal pages with Cloud off | §3: opening them is an ordinary web page request to qirsh.site in an in-app browser view (IP address, browser details); nothing about finances or messages; enables nothing |
| 5 AI request content | §8: for messages pasted or shared in the app, the amount as written plus currency and direction when found in the message, and the matched account's currency code; the amount only if still in the sanitized text; model and instruction version recorded. **No App privacy data type changes** (STORE-READINESS note) |
| 6 Global AI budget | §7 "Spending limit": a daily count across all users; holds date, service and numbers only |

Flutter policy tests re-run after the edits: `legal_urls_test`, `ai_egress_consent_test`, `android_sms_permission_test`, `public_copy_truthfulness_test`, `report_ads_guards_test`: **89 passed, 0 failed**. No test changed.

RELEASE-PLAN updated for the `ai` integration: M1 is **included**. `bank-discovery` (Gemini) and `enrich-merchant` (Places) join `parse-sms` and `process-ios-sms` in P3, after M1. The gate's deliberate fallback is noted: if the guard function is absent, the call proceeds as before, so deploy order cannot cause an outage. Expected `prod_compare` result: 19 IDENTICAL and 9 DIFFERS.

**Statements that still depend on unfinished or uncommitted work (reconcile at the final commit before publishing):**
- **ios — ads SDK presence:** "Google Mobile Ads and UMP SDKs still linked but not started; no ad requested; no advertising consent form". If `ios` removes the SDK, simplify §7 and STORE-READINESS. The "not collected" store answer also needs a release-build log without `QIRSH_ADS_ENABLED` and a proxy capture.
- **data — deletion lifecycle:**
  - "final, no undo period; some server steps finish in the background within minutes; the app shows when complete"
  - "earlier 30-day requests will not be carried out"
  - profile-photo erasure on the worker path, which needs the `account-deletion-worker` deploy (P1)
  - the deletion copy is now consistent: `deleteAccountAcceptedBody` was rewritten ("deletion has started … final") on 2026-11-18
- **ai — guard and AI payload:** the "Spending limit" paragraph and the §8 local-evidence sentence describe uncommitted code; the ceiling only works after M1 and P3.
- **consent:**
  - legal links open with Cloud off (`launchLegalDocument`)
  - the shared-learning transition prompt
  - the comment in `settings_providers.dart` still says "on by default" (behaviour is correct)
- **Owner:** the Gemini paid tier (§7), and publication only after the V1 app is live (`tools/deploy_site.sh`).

## 8. Follow-up 2 (2026-11-18): review T (platform and records) and review S (SM-03/SM-04), HEAD `98e8e56d`

Nothing committed.

**SP-03, deploy set derived instead of hand-listed.**
- New `tools/deploy_set.sh <base-ref> [<target-ref>]`. For every function it compares the import closure (including JSON) at both refs.
- `bash tools/deploy_set.sh b6fc0dad HEAD` reports these as CHANGED: `bank-discovery`, `enrich-merchant`, `parse-sms`, `process-ios-sms`, `process-notification-retries`, `send-push-broadcast`.
- `send-push-broadcast` is excluded: it imports only the unchanged dead-token helpers from `_shared/capture_push.ts`.
- `process-notification-retries` is added to RELEASE-PLAN. It is deployed **first in P3**, before `process-ios-sms`. The new copy handles old `notification` rows (no `captureOutcome` → the old wording).
  - Smoke test: retry cron succeeds, backlog is 0, and a declined sample's push reads as declined.
  - Its v12 rollback source must be identified in P0.
  - Undo order: `process-ios-sms` first, then this function.
- Expected `prod_compare` result at the final commit: 18 IDENTICAL, 10 DIFFERS.

**SP-05, comments corrected.**
- Corrected: the migration header `20261117120000_ai_global_spend_guard.sql` (not applied anywhere), the rollback file header, and the `ai_spend_guard.ts` comment. They now state the fail-open exception for a missing function (PGRST202/42883).
- RELEASE-PLAN (b) Undo and (h): rolling back M1 while the new functions are deployed removes the ceiling silently. To limit or stop AI, use `ai_global_budget` instead.
- Correct undo order: functions → rollback file → ledger row.
- Checks: migration lint passes; `deno test` for the guard and gate: 8/8.

**SP-04, currencies, read in `b6fc0dad`.**
- `currencyScale()` throws for a code outside build 147's 50.
- Ledger: `_applyRowOrQuarantine` parks the row in `parked_child_rows` (`quarantine`), advances the cursor, retries 5 times, then marks it `terminal`. The row stays hidden and nothing is shown to the user.
- Planning: `_quarantineUnresolved` parks the row as `unresolved_currency`. Build 147 has a repair flow where the user picks one of its 50 currencies. I did not trace whether that repair rewrites the server row.
- Added to RELEASE-PLAN (c) with four options. Recommended: document it, and tell testers to update every device before choosing one of the new currencies.

**SM-03/SM-04.**
- The 147 × new-backend parser cell is now "must be re-measured on the final commit before P3".
- Measurement: run the final server-only reading through build 147's own import, against 147 with today's server.
- Accept only if no total-changing class is worse.
- If `tools/message_eval` has no mixed old-device/new-server mode, the evaluation owner has to add it.

**SP-07.**
- Fixed in RELEASE-PLAN: "Turn off (P5)" → P4.
- Also updated: the sign-in compatibility paragraph. `ios-signed-release` now sets the three sign-in `vars` to `"true"`.
- Code comments that present an open item as decided (not edited):
  - `app/lib/features/settings/sign_out_sheet.dart:53`: "(V1-067, decision B26 (a))"
  - `app/test/features/settings/sign_out_sheet_test.dart:148`: "V1-067 / decision B26 (a)"
  - `app/ios/Runner/SceneDelegate.swift:74`: "// B24: cover as soon as the scene stops being active …"
  - B24 and B26 are open in `DECISIONS-NEEDED.md` and are not in owner brief §3 / D-20.

**Tests:** the legal-text Flutter tests pass, 89/89. The legal text was not changed in this follow-up.
