# Version 1 — release manifest

What exactly was assessed, to the extent it can be verified. Unknown means unknown. Counts are from `git log`. Brought to round 3 on 2026-11-18 by a records editor (AI agent, model `claude-opus-5-5`); this editor ran `git` and `tools/deploy_set.sh` only.

## One candidate

**The candidate is commit `a157e68e`** (`a157e68e0e…`, the last commit that changes application, backend, test or tool code) on the local branch `release-readiness/v1`. Every other name below is an ancestor of it and is history, not a candidate. The previous candidate `5dae2e2d` (round 2) and the intermediate round-3 commits are superseded.

| Name | Commit | What it is |
|---|---|---|
| Audit baseline | `ab5dc10a` | Tip of `origin/feat/post-beta-features` (2026-11-17). What audits A–H read |
| Last distributed build | `b6fc0dad` → iOS 1.0.0 (147) | One commit before the baseline. TestFlight internal testing, Codemagic `ios-signed`, 2026-11-16 |
| Round-1 code, final | `af675aec` | Strict gate 15/15 (history) |
| Round-2 application code, final | `50957c06` | Reviewed by R (history) |
| Round-2 candidate | `5dae2e2d` | `50957c06` + one test-only commit. **Superseded** |
| Round-3 intermediate states | `7577f347`, `7dd6efa8`, `6f771108`, `f4dcabd3` | Each was reviewed and then changed. `7577f347`: rejected by review S (money) and, for restore, by review T. `7dd6efa8`: rejected by S on one narrow class; accepted with follow-up by T. `6f771108`: accepted with follow-up by S. `f4dcabd3`: accepted with follow-up by S with one open S2 (VAL-1); the production plan was measured there. **None is a candidate** |
| **Candidate** | **`a157e68e`** | `f4dcabd3` + one tool-hygiene commit + one code commit closing VAL-1 and narrowing PRIV-1 |
| Round-3 records | `ea218565` and the records commit that will contain this file | Documentation only, on top of `a157e68e`. Nothing under `app/`, `supabase/`, `admin/`, `tools/` or `codemagic.yaml` changes |

`git log --oneline ab5dc10a..a157e68e` lists 46 commits. `git log --oneline 5dae2e2d..a157e68e` lists 17.

The candidate is **not pushed, not merged, not built by CI, not signed, not deployed and not on any physical device.** Build 147 contains none of it. The local branch name is refused by the hardened release workflow, which requires a `release/*` branch.

## Commits after the round-2 candidate `5dae2e2d`

"Code" means the commit changes `app/`, `supabase/`, `admin/`, `codemagic.yaml` or `tools/`. Several records commits also changed the evaluation tool `tools/message_eval/`, which is not shipped; they are marked "records + eval tool".

| Commit | Kind | Subject (shortened) |
|---|---|---|
| `c82f9a89` | records | Record the second round of the assessment |
| `b125f7af` | records | Record the strict gate result on the round-2 candidate |
| `d1212986` | records | Record the owner's round-3 brief and the closure brief |
| `bae159e2` | code (backend) | Evidence-based AI output, meaning-first parsing, outcome-true pushes, global AI budget guard, deletion worker proof, admin on Next 15 |
| `640562f6` | code (app) | Merge restore, final deletion, first-run consent and language, all countries and ISO currencies, no ads in the V1 build, iPhone only, honest notifications, large text, review flow |
| `7cab5e8b` | eval tool + records | Held-out message evaluation, legal text, decision record D-20, specialist closure reports |
| `b6f102b4` | code | Fixes for what strict gate run 1 found (reward-points and advert misreadings; tests aligned to the approved decisions; skip-manifest entries for the local-stack deletion tests) |
| `7577f347` | code (test) | Make a review golden fixture `const` (analyzer). Reviewed by S (REJECT) and T (REJECT for restore) |
| `98e8e56d` | records + eval tool | Held-out run of `7577f347`; reviews S and T |
| `7dd6efa8` | code | Fixes for S and T: status sentences never footers, reward points not income, no parser throws, bounded linear parsing, merge keeps deleted rules deleted, large text wraps, derived deploy set |
| `4d54d258` | records + eval tool | Re-reviews at `7dd6efa8`; build-147 mixed mode in the evaluation |
| `6f771108` | code | Second review fixes: primary-clause direction and amount, completed purchases never dropped, over-length text to review, redaction changes, restore confirmation names its case, stacked selector test |
| `5a5a1587` | records | Re-review at `6f771108`; server deploy condition for build 147 not met then |
| `f4dcabd3` | code | Third review fixes: pending refunds and scheduled orders are not movements, own-account and multi-purchase messages held, validator rejects any non-record meaning, redaction leak classes closed (device, server, Shortcut), consent text states what redaction does, `textLength` sent |
| `4c428719` | records + eval tool + legal text | Final held-out run and narrow review at `f4dcabd3`; production plan regenerated there; build-147 measurement filled in |
| `0eafa897` | tool hygiene | Stop tracking Python bytecode in `tools/parser_diff` |
| **`a157e68e`** | **code** | **A total can never release a not-completed message; one source of "processed" on the server; remaining name and account-number redaction cues on device, server and Swift.** 15 files |
| `ea218565` | records | Final held-out run, review S confirmation, strict gate summaries |

The round-1 and round-2 commit lists are in git history (`git log ab5dc10a..5dae2e2d`) and in this file's earlier versions.

## Components and versions

| Component | At the candidate `a157e68e` | In production (read-only checks, 2026-11-17 and 2026-11-18) |
|---|---|---|
| Marketing version | 1.0.0 (`app/pubspec.yaml`) | — |
| Build number | Not assigned. Codemagic takes the latest App Store Connect number and adds one. `pubspec.yaml` says `+44`, which is not the real number | Last build 147 |
| Device families | iPhone only (`TARGETED_DEVICE_FAMILY = 1` in all six build configurations), portrait (owner decision 3.1) | Build 147 allowed iPad and landscape |
| Advertising | Compiled out of the V1 build (`QIRSH_ADS_ENABLED` compile-time define, off in store workflows). Google Mobile Ads 13.3.0 and UMP 3.1.0 are still linked but never started; network silence NOT TESTED | **All eight ad flags ON** (unchanged; the change is in the plan, not executed) |
| Device database schema | Drift v43, forward-only (`_targetSchemaVersion = 43`); unchanged since the baseline | — |
| Backup file format | Unchanged | — |
| Storable currencies | 155 ISO codes (`kCurrencyScale`); detection in message text still uses 50 (`kDetectionCurrencyScale`). Build 147 knows 50 (SP-04) | — |
| Countries | 249 selectable; verified bank coverage SA and EG only | — |
| Supabase migrations | **135 files**; the new one, `20261117120000_ai_global_spend_guard.sql`, is additive and **not in production**. No migration changed between `f4dcabd3` and `a157e68e` | Ledger lists 134 (all except the new one). Names only |
| Edge Functions | 33 in the repository | 28 deployed. Against `f4dcabd3`: 16 identical, 12 differ (ops, 2026-11-18). Not re-compared at `a157e68e` |
| Functions changed since build 147 (`tools/deploy_set.sh b6fc0dad a157e68e`, run by this editor) | 8: `bank-discovery`, `enrich-merchant`, `merchant-category-contribution`, `parse-sms`, `process-ios-sms`, `process-notification-retries`, `send-push-broadcast`, `sync-captures` — the same 8 as at `f4dcabd3`. `account-deletion-worker` is in the plan because the deployed v5 matches no commit | — |
| Production package | Seven functions and one migration ([RELEASE-PLAN.md](RELEASE-PLAN.md)); `sync-captures` and `send-push-broadcast` not proposed | Nothing executed |
| AI model | `gemini-3.8-flash` (SMS) and `gemini-2.5-flash-lite` (bank discovery) unless overridden; prompt versions now recorded with each result (`sms-understanding-v3`, `sms-system-v3`) | Override variables not set → defaults |
| Admin panel | Next.js **15.5.29**; `npm audit --omit=dev` 0 advisories (ops) | Deployment and exposure unknown |
| CI toolchain | Flutter 3.47.3; `xcode: latest` (unpinned). Store workflows now require the Apple, Google and email sign-in variables and fail otherwise | Variable values in Codemagic not visible |
| Backups | — | Point-in-time recovery **off**; the API lists no backups; free plan |

## Environment of this assessment

One Apple-silicon Mac, macOS (Darwin 27.0.0), Flutter 3.47.3 / Dart 3.13.3, Xcode 27.2, Node 26.8.2, Deno 2.9.6, Supabase CLI 2.117.0, Docker Desktop. iOS 26.5 simulators (iPhone 17 Pro for the XCTest run). Local Supabase stacks with synthetic data for restore, sync, deletion and the backend stage.

Not available or not used: any physical device; a Java runtime or `adb`; a CI or signed build of the candidate; store consoles; Codemagic variables; a real AI model (a key exists in a git-ignored local file and was deliberately not used).

Production was read, never written.

## Reviewers

Orchestration, integration, verification runs and the release decision: Claude Fable 5.2 (AI). Specialists (parser, AI, data, consent, iOS, accessibility, ops, evaluation), records and the independent reviews S (money correctness) and T (platform and records): AI agents that each reported the model identifier `claude-opus-5-5`; that identity cannot be verified beyond the agent's own statement. No human has reviewed anything. AI review is an additional control, not a certification and not an approval. The owner approved the product decisions in [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3 and nothing else.
