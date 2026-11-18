# Closure round 3: held-out message-understanding evaluation (`eval`)

- **Model:** `claude-opus-5-5` (Opus 5.5). Source: the identity my runtime states ("You are powered by the model named Opus 5.5. The exact model ID is claude-opus-5-5"). That is the runtime's own statement; I did not check it any other way.
- **Date:** 2026-11-17. Worktree `.claude/worktrees/v1-readiness`. I wrote only `tools/message_eval/**` and this file. I did not commit, stage or edit any parser or AI file.
- **Measured commits:** baseline `ab5dc10a` and candidate `5dae2e2d`. Each ran from its own scratch `git worktree add --detach`. Every scratch worktree was removed afterwards (`git worktree list` shows none of them).

## 1. What was built (status: DONE, except the real-model run: BLOCKED, see §5)

| Item | File(s) | Status |
|---|---|---|
| Ground-truth schema | header of `tools/message_eval/heldout/build_heldout.py` | DONE |
| Held-out synthetic set: 753 messages, 194 templates | `tools/message_eval/heldout/messages.jsonl` (+ generator, seed fixed) | DONE |
| Acceptance criteria, written before any run | `tools/message_eval/ACCEPTANCE.md` | DONE |
| Runner (one command per commit) | `tools/message_eval/run.sh`, `expand.py`, `deno/server_eval.ts`, `dart/message_eval_test.dart`, `score.py`, `README.md` | DONE |
| Real-model runner (hard request cap, token and latency accounting) | `deno/server_eval.ts` (env-gated) | DONE; not run (no authorized key) |
| Before numbers (`ab5dc10a`, `5dae2e2d`) | §4 | DONE |

**Ground-truth fields.** Each message carries:
- `cls`: message type, one of completed, declined, pending, refund_completed, refund_pending, balance_notice, bill_due, expected_salary, marketing, otp, ambiguous, multi_event, other_nontxn.
- `disposition`: save / exclude / review / ignore, plus an `acceptable` list for texts where another disposition is also correct.
- `events`: kind, amount, currency, and the original foreign amount where the message gives one. Kinds are payment, fee, withdrawal, transfer_out, income, transfer_in, refund and own_transfer (neutral).
- `alt_events`: other correct readings, e.g. a fee that is not split out.
- `sender` and `sender_context`.
- `policy_dependent`.
- `tags`: the coverage classes.

I labelled each message from its text alone before running any code. No text comes from `declined_cases.json`, the corpus or the golden fixtures.

**How the runner works.**
- **Server side:** the commit's own `parseSms`, applied to `redactThirdPartyNames(redactPii(text))`, exactly as `index.ts` calls it. The stored-capture mapping (status and state) copies `index.ts:335-378`.
- **Device side:** the commit's own `CaptureImportService.run()` on a Drift database built from a migrated template, using the real `CaptureSyncService`, `IngestCapturedMessageUseCase` and `AddTransactionUseCase`, with the bundled bank profiles through `RulesClient`.
- Each message is delivered twice, to count duplicate effects.
- **Grading** looks only at what reaches totals. Confirmed rows are the only rows any total reads. Pending rows, Smart Inbox items and suspected duplicates count as review.

**Paths measured:**
- `local_only`: Cloud and AI off.
- `cloud_det`: Cloud on, AI off. This is the effective iOS path.
- `cloud_primary_oracle`: AI-primary, with a model stub that returns the ground truth. It shows what the validators and the import do to a perfect answer. **It is not a model evaluation.**
- Hybrid mode is reported on the server side only, because no iOS client sends it. I amended `ACCEPTANCE.md` for this before the first full run; no criterion changed.

## 2. Set composition and limitations

- 753 messages: 542 English, 211 Arabic (some with Arabic-Indic digits).
- Regions: Saudi Arabia 459, Egypt 210, UAE 40, Qatar 8, Kuwait 4, Bahrain 4, Oman 4, international (USD/GBP/EUR/French/Turkish) 24.
- Dispositions: save 453, exclude 103, ignore 139, review 44. A further 14 rows are policy-dependent: ATM cash deposit, card repayment, wallet top-up, crypto purchase.
- 149 messages have no sender context.
- Coverage tags (count):

| Tag | Count | Tag | Count |
|---|---|---|---|
| direction | 87 | injection | 25 |
| multi_amount | 56 | fx | 24 |
| merchant_token | 52 | malformed | 20 |
| balance_trap | 40 | truncated | 20 |
| mixed | 36 | own_transfer | 16 |
| ref_trap | 32 | vat | 12 |
| fee | 28 | no_currency | 12 |
| ood (out of distribution) | 28 | tip | 4 |

**Limitations:**
- Synthetic messages from a single author, not real traffic. The rates are not real-world accuracy.
- Each template is expanded about four times, so one template-level defect moves the counts in steps of about 4.
- The device runs with a fresh install's bundled bank profiles, not the synced production catalog.
- The native Swift sanitizer is not applied (the server's own redaction is).
- The oracle answers one event per message, matching the single-transaction schema.

## 3. Acceptance criteria (summary of `ACCEPTANCE.md`)

These are engineering criteria. **They are not owner-approved risk tolerances.**

| ID | What it measures | Bar |
|---|---|---|
| A1 | Non-transactions saved as money | 0 |
| A2 | Declined or pending messages saved as money | 0 |
| A3 | Ambiguous messages saved as money | 0 |
| A4 | Wrong amount, currency or direction | ≤ 1 % of completed messages; 0 on injection-bearing messages |
| A5 | Duplicate effects | 0 |
| A6 | Messages lost silently | 0 |
| A7 | Completed messages sent to review | ≤ 15 % without AI; ≤ 5 % on the oracle path; ≤ 10 % with a real model |
| A8 | Correct AI answers rejected | ≤ 5 % |

## 4. Results: the "before" numbers

Counts exclude the 14 policy-dependent rows. Denominators: 453 completed, 103 declined/pending, 139 non-transactions, 44 ambiguous.

| Path | Commit | A1 non-txn saved | A2 declined/pending saved | A3 ambiguous saved | A4 amt / cur / dir (rate) | A4 injection | A5 dup | A6 lost | A7 to review (rate) | Non-txn → review (info) | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| local_only | ab5dc10a | 24 | 60 | 4 | 1 / 4 / 31 (8.0 %) | 4 | 0 | 12 | 155 (34.2 %) | 117 | FAIL A1–A4, A6, A7 |
| local_only | 5dae2e2d | 20 | 20 | 4 | 0 / 4 / 28 (7.1 %) | 0 | 0 | 0 | 143 (31.6 %) | 161 | FAIL A1–A4, A7 |
| cloud_det | ab5dc10a | 44 | 79 | 4 | 8 / 16 / 39 (13.9 %) | 4 | 0 | 8 | 33 (7.3 %) | 81 | FAIL A1–A4, A6 |
| cloud_det | 5dae2e2d | 32 | 27 | 4 | 8 / 16 / 33 (12.6 %) | 0 | 0 | 0 | 50 (11.0 %) | 145 | FAIL A1–A4 |
| cloud_primary_oracle | ab5dc10a | 0 | 0 | 0 | 5 / 0 / 15 (4.4 %) | 0 | 0 | 8 | 8 (1.8 %) | 201 | FAIL A4, A6 |
| cloud_primary_oracle | 5dae2e2d | 0 | 0 | 0 | 5 / 0 / 13 (4.0 %) | 0 | 0 | 0 | 35 (7.7 %) | 201 | FAIL A4, A7, A8b |

**Validators on the correct candidate** (453 per side):
- Server `validateAiCandidate` + `checkPrimaryAmount`:
  - `ab5dc10a`: rejects 14 (3.1 %): direction_contradiction 8, amount_not_grounded 6.
  - `5dae2e2d`: rejects 14 (3.1 %): same reasons.
- Device `AiCandidateValidator`:
  - `ab5dc10a`: rejects 4 (0.9 %).
  - `5dae2e2d`: rejects 10 (2.2 %): transaction_not_completed 4, amount_not_grounded 6.
- Both sides pass A8a.

**Server reading alone** (what a push notification would claim), `cloud_det` mode:
- Processed although not a completed movement: `ab5dc10a` 55 declined/pending + 36 non-transactions; `5dae2e2d` 20 + 19.
- Completed messages rejected: 118 at both commits. The device recovers them.

**Wrong type within the right direction** (refund vs income, information only), `cloud_det`: 20 at `ab5dc10a`, 4 at `5dae2e2d`.

**Policy-dependent rows** (both commits):
- ATM cash deposit: booked as income.
- Card repayment: booked as spending.
- Wallet top-up: review, or spending on the AI path.
- Not graded.

### Failure classes at `5dae2e2d` (aggregate, by message family)

I share only aggregate classes. Per-message results stay with the evaluator.

- **Pending or scheduled saved as money (A2):**
  - "under processing", "scheduled for", future-tense "will be debited" installments, "standing order … will be executed tomorrow".
  - Refund-request notices booked as refunds.
  - On `cloud_det` only: a returned or unpaid cheque, and about 3 declined messages.
- **Non-transactions saved as money (A1):**
  - Expected salary ("will be credited", "سيتم إيداع راتبك"), booked as income.
  - Adverts with money terms (cashback up to X, "transfer X or more"), booked as payment.
  - On `cloud_det` also: Arabic bill-due and minimum-due reminders.
- **Ambiguous saved (A3):** a message truncated mid-status ("… was decl") booked as a purchase.
- **Wrong direction (A4):**
  - Outgoing money worded with deposit, salary or credited ("security deposit … paid", "salary transfer to employee", "rent deposit", "credited to {payee}'s account from your account"), booked as income.
  - "Cashback reversal … deducted" booked as income.
  - An Arabic incoming transfer ("تم تحويل … إليك") booked as spending.
  - Merchant names containing cue words ("Refund …", "Salary …") booked as refund or income on the device.
  - Own-account transfers booked as spending.
- **Wrong currency (A4):** a foreign purchase with a charged local amount ("USD x … charged as SAR y") recorded in the foreign currency, on all forms on `cloud_det` and one form on the device.
- **Wrong amount (A4):**
  - "Amount + tip = total" and "bill + fee = total debited", where the base figure is recorded instead of the total charged.
  - Multi-event messages: only one event is booked.
- **Review cost (A7):**
  - Device without AI: about 32 % of completed messages, concentrated in fee lines, FX, VAT, refunds, Arabic bill payments, mixed footers, Gulf 3-decimal formats, "$" and "£" formats, injection-bearing purchases and truncated tails.
  - AI-primary with a perfect answer (35 messages): validators or the device contradiction check overrule the correct answer on deposit/salary-worded outgoing transfers, cue-word merchant names, refunds and OTP-footer purchases.
- **Fixed relative to the baseline:**
  - Silent loss is 0 on every path (was 12 / 8 / 8). The baseline dropped purchases carrying an "OTP" footer and the "OTP Mobiles" merchant.
  - Injection-bearing errors are 0 (was 4).
  - Declined/pending saved: 60 → 20 on the device, 79 → 27 on `cloud_det`.
  - Non-transactions saved: 24 → 20 on the device, 44 → 32 on `cloud_det`.
- **Worse than the baseline on this set:**
  - Review volume on `cloud_det`: 33 → 50.
  - Review volume on AI-primary with a perfect answer: 8 → 35.

**Verdict:** neither commit meets the engineering criteria on any path. The candidate is better than the baseline on every wrong-money criterion and on silent loss. It is worse on review volume.

## 5. Real model: BLOCKED (no authorized test access)

- **Code defaults:**
  - Model: `GEMINI_SMS_MODEL` unset → `gemini-3.8-flash` (`process-ios-sms/parse.ts:45`, `parse-sms/index.ts:34`).
  - AI-primary: up to 3 requests per message (`_shared/ai_primary.ts` `MAX_AI_ATTEMPTS`); hybrid: 1.
  - Timeouts: 12 s (primary), 3.5 s (hybrid).
- **Search for local access** (names only, no values printed):
  - Nothing under the worktree (`supabase/functions/.env*`, `supabase/.env*`, `.env*`, `app/.env*`, `admin/.env*`).
  - Nothing in the shell environment.
  - `supabase/config.toml` sets no Gemini secret.
  - One file defines `GEMINI_API_KEY`: `/Users/luciq/Documents/Money/demo-docker/supabase/functions/.env.demo` (git-ignored demo stack).
- **Why I did not use that key:**
  1. Nothing establishes that it is authorized test access rather than a live key billed to the owner.
  2. The closure brief forbids spending money.
- **Exact command once the owner authorizes a test key:**
  ```
  MESSAGE_EVAL_GEMINI_KEY=<key> MESSAGE_EVAL_MAX_REQUESTS=300 MESSAGE_EVAL_REAL_SAMPLE=100 \
    MESSAGE_EVAL_SCRATCH=<dir> tools/message_eval/run.sh <sha>
  ```
  - The output adds a `cloud_primary_real` path, plus request count, tokens (prompt / output / thinking), latency and errors.
  - Cost = tokens × the provider's published price on the day; the price is not hard-coded.
  - A full-set run is at most about 2,250 requests (753 × 3).

## 6. Commands and results

| Command | Result |
|---|---|
| `python3 tools/message_eval/heldout/build_heldout.py > …/messages.jsonl` | 753 rows, deterministic |
| `MESSAGE_EVAL_SCRATCH=<scratch>/eval tools/message_eval/run.sh ab5dc10a 5dae2e2d` | exit 0. Device shards: ab5dc10a 875 s ×2; 5dae2e2d 391 s ×2. Deno about 45 s per commit. 0 runner errors. |
| `deno lint tools/message_eval/deno/` | clean (after the run I replaced an `async () => true` with `Promise.resolve(true)`; behaviour is identical) |
| `deno check --no-lock tools/message_eval/deno/server_eval.ts` | ok |

- The Dart runner is not covered by `flutter analyze` in `app/`, because it lives under `tools/`. It compiled and ran inside both scratch checkouts.
- Each run takes about 15–30 minutes per commit on this shared machine.

## 7. What is not verified

- **Real-model accuracy, latency and cost:** not measured (§5).
- **Real traffic:** synthetic only.
- **Production catalog parser rules:** not loaded.
- **Build 147 against the new server, and the reverse:** not measured.
- **Server-side duplicate detection:** not exercised (no database).
- **Notifications:** not graded.

## 8. Compatibility, other files, owner actions

- **Compatibility:** read-only tooling. No app, server or stored-data change.
- **Changes needed in files I do not own:** none required for the runner.
- **Owner action:**
  1. Authorize, or provide, a Gemini key and budget for testing. Name the env file or secret and confirm it is not the production key and that its spend is acceptable.
  2. Then run the §5 command.
