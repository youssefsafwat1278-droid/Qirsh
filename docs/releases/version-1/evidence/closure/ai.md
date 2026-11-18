# Closure round 3 — AI pipeline (`ai`)

- Model running this work: `claude-opus-5-5` (Opus 5.5). Source: the session's system context states "You are powered by the model named Opus 5.5. The exact model ID is claude-opus-5-5." That is the harness's statement; I have no other way to inspect it.
- Tree: `.claude/worktrees/v1-readiness`, branch `release-readiness/v1`, HEAD `b125f7af` at start. Nothing committed, staged or stashed by me. Other specialists' uncommitted edits were left alone (`parser_engine.dart`, `language_screen.dart`, … changed under me during the run).
- Evidence language: every model answer in the tests below is SYNTHETIC (hand-written JSON). No model was called. Nothing here is an AI evaluation or real-world accuracy.

## 0. The pipeline as it is (read end to end)

| Step | iOS capture (V1 path) | In-app AI (paste / inbox retry / Android) |
|---|---|---|
| Entry | App Intent → `process-ios-sms` (`analysis_mode=ai_primary_v1` when AI consented, build 147 too) | `AddTransactionUseCase` → `SupabaseAiParserClient` → `parse-sms` (`ai_primary_v1`, build 147 too) |
| Sanitizing | client `SmsSanitizer`, server `redactThirdPartyNames(redactPii())` | same |
| Consent / owner | `capture_claim` (owner + consent snapshot), `capture_ai_dispatch` RPC before **each** provider attempt, `capture_finalize` fence | device `_requireSameAccountIdentity` before the request; server `resolveVerifiedIdentity` + `consentError` per provider attempt (`beforeAttempt`) |
| Model | `GEMINI_SMS_MODEL` default `gemini-3.8-flash`, temperature 0, JSON schema, `store:false` | same |
| Prompt | `process-ios-sms/parse.ts` (parser-owned) | `parse-sms/index.ts` |
| Provider attempts | `runPrimaryAi`: ≤3 calls, validator reason fed back as a repair turn | same; client ≤2 HTTP attempts with one `request_id` (idempotent replay, no second charge) |
| Validators | server `validateAiCandidate` + `checkPrimaryAmount`; device import gate `validateCaptureCandidate` + `localParseContradictsServer` | server same; device `AiCandidateValidator` |
| Combine | AI-primary: the validated AI row is imported; anything else → Smart Inbox (no local substitution) | AI-primary: local parse is not used; AI rejected → Smart Inbox |
| Write | device import transaction (row + receipt) after owner re-check | `_commitCapture` |

## 1. Work items

### 4.2 Structured, evidence-based output — DONE (server and device), PARTIAL for the iOS prompt (parser-owned file)

Files: `supabase/functions/_shared/ai_understanding.ts` (new), `_shared/ai_primary.ts`, `_shared/gemini_request.ts`, `parse-sms/index.ts`, `app/lib/engine/ai/ai_parser_client.dart`, `app/lib/engine/ai/ai_candidate_validator.dart`.

- Response schema (all callers of `runPrimaryAi`, including `process-ios-sms/parse.ts`) gains optional `message_type` (transaction, declined_or_failed, pending_or_scheduled, balance_or_limit_notice, bill_or_reminder, expected_income, marketing, otp_or_security, other_non_transaction, ambiguous), `status` (completed, declined, failed, pending, scheduled, unknown), evidence quotes (`amount_/currency_/status_/direction_/merchant_evidence`), `original_amount_text`/`original_currency`, `currency_source`, `missing_information`, `contradictions`.
- Untrusted message: every primary request now carries a `systemInstruction` (kept apart from the content) saying the SMS is third-party data and instructions inside it are never followed; `parse-sms` puts the message inside `<sms_message>…</sms_message>` after the rules, and any marker look-alike inside the message is neutralized (`[marker removed]`).
- A message type other than `transaction`, or a status other than `completed`, is a **terminal** verdict normalized to `{is_transaction:false, message_type, status}` (enum codes only; model free text is dropped). It is never sent back through the repair loop. Every caller and old client already treats `is_transaction:false` as "kept for review unless the deterministic OTP/advert filter drops it".
- `checkUnderstanding` (when the caller passes the message, i.e. `parse-sms`): each evidence quote must be a literal part of the message (whitespace/case-insensitive); the amount quote must contain `amount_text`; the amount must not be a figure that is only ever written as a reference/approval/auth/trace/OTP/code number; an original foreign amount must be grounded, its currency named in the text and different from the charged currency. Balance/limit figures were already refused (`amount_is_account_figure`, `transaction_amount_not_balance`).
- Evidence quotes, `missing_information` and `contradictions` are **not** returned to the client nor stored in the idempotency row (they are fragments of the message); `evidence_checked:true` is.
- Device: `AiParseResponse` reads `message_type`, `status`, `currency_source`, `prompt_version`; the device validator rejects `status_not_completed` / `message_type_not_transaction` (defence against any server).

### V1-058 model and prompt version — DONE, no migration

- `parse-sms` returns `model_used` (as before) and `prompt_version` (`sms-understanding-v2`) on every primary answer, including not-a-transaction verdicts.
- `process-ios-sms/index.ts` adds `aiModel` and `aiSystemVersion` (`sms-system-v2`) to the stored `parsed` jsonb whenever an AI request was made. `processed_captures.parsed` is jsonb: no migration. The prompt text of `parse.ts` itself is parser-owned and not versioned (see "Changes needed in files I do not own").

### 4.3 Local/AI cooperation — DONE for the in-app path; iOS path unchanged by design

- The device sends the local parse (`local_evidence`: amount_text, currency unless defaulted, direction) as **evidence** the model may overrule, on the same request (no extra request). It is sent only when the local amount is still a figure of the sanitized text, so a digit run the sanitizer removed cannot leave this way.
- AI-primary already prefers the validated AI answer, keeps a rejected/contradictory/incomplete answer in Smart Inbox, and never saves a local result to rewrite it later (the use case waits for the answer; the iOS import is single-shot with receipts). With AI off the local flow is unchanged (valid → saved, invalid → Smart Inbox). AI is never requested without consent (`_tryAiParseFirst` consent check, server `consentError`).
- New: after the answer arrives and **before it is applied**, the device re-checks the account identity (throws, nothing committed) and AI consent (answer discarded, local/review flow instead).
- V1-086 (validator rejecting correct candidates): `not_a_transaction` no longer fires on an account-notice sentence (`credit limit`, `e-statement`, `activated`, …) that does not hold the amount, when the amount's own sentence names a completed movement (a money word, or `authorised/approved/posted/direct debit/standing order/payroll`). Ignore words, non-transaction markers (links, offers, `won`) and OTP codes anywhere still reject; a notice whose own sentence carries the amount still rejects. Same rule on the server (`withoutUnrelatedNotices`), the device validator, and the iOS import gate (`localParseContradictsServer` uses it for `isNoticeMessage` when the server amount is known).
- Measured on the shared table `process-ios-sms/declined_cases.json` (synthetic, validator only, no model; my scratch harness, correct candidate = table amount/currency/direction): completed rows with a grounded amount 1,212; rejected at HEAD 355 (255 `not_a_transaction`) → now 296 (151 `not_a_transaction`); not-completed rows offered as a payment candidate: 234 of 397 accepted by the validator at HEAD and now — **the identical set** (`diff` empty), so nothing it was added to stop is re-admitted on this set. (Those 234 are stopped earlier by `isDeclinedText` / `TransactionStateCues`, not by this validator.) The remaining increase in `currency_not_grounded` is my harness defaulting SAR for rows without a table currency, not a product change.

### 4.4 Currency inference — PARTIAL (no persistent flag)

- When the message names no currency and its account number matches **exactly one** existing account (exact or 4+ digit suffix; two matches = no match), the device sends `account_currency`. The server validator accepts that currency only if the text names no allow-listed currency at all and the answer gives exactly it; it returns `currency_source:"account_context"`. The device validator applies the same rule and the row is bound to the matched account (`currencyFromAccount` on `AddTransactionResult`). An AI currency with no such context is still `currency_not_grounded` → review. With AI off the local flow keeps its existing rule (a defaulted currency is never confirmed).
- Not done: persisting "inferred from account context" on the transaction row. There is no column for it (`transactions` has no metadata field); the schema is not mine. See changes needed.

### 4.5 Categorization precedence — VERIFIED, no change needed in my files

- `learnedRuleCategoryFor` (user-confirmed rule > shared-learning exact mapping > AI) is applied on both the in-app and the iOS import path; provenance `rule`/`auto` is written on save. A rule supplies only the category; amount, currency, status and direction come from the parse.
- New acceptance test: a redelivered/late server AI result for a capture whose row exists with a hand-picked category leaves the category and `CategoryProvenance.user` unchanged (`capture_import_service_test.dart`, "a redelivered AI result leaves a manual category and its provenance"). It passes before and after (it verifies existing behaviour).
- Observed, not changed: `process-ios-sms` `withUserMerchantRule` turns the notification's type into `withdrawal` when the user's rule is `cash` (display only, both debit); the device turns `payment` into `withdrawal` for a `cash` category on an ATM-shaped message without AI. Neither changes direction or totals; noted for the owner of notifications.

### 4.6 Dispositions — PARTIAL (server/device behaviour; UI not mine)

- Declined/failed and pending now become terminal not-a-transaction verdicts on every AI path → Smart Inbox (review) on device unless the deterministic OTP/advert filter drops them; they are never processed money. Clear non-transactions stay out. Ambiguous (`message_type=ambiguous` or `status=unknown`) → review.
- Temporary failure: unchanged — `retryable` server state, `CaptureRetryLedger` bounded attempts then Smart Inbox `analysisUnavailable`.
- Not verified/not mine: the review UI affordances (move a saved row into review, confirm/edit/exclude, the "awaiting review is not in totals" report note) and a disposition reason shown in Smart Inbox. See changes needed.

### 4.7 Retries and identity — DONE where in my files

- Per attempt: `parse-sms` re-resolves identity + consent before each provider attempt (existing); `process-ios-sms` `capture_ai_dispatch` per attempt and `capture_finalize` fence (existing); device: identity before the request (existing) and identity + consent before applying the answer (new). Disabling Cloud/AI: the next attempt is denied (`denied` → no further provider call; tested in `ai_primary_test.ts`).
- Terminal verdicts end after one provider call instead of up to three.
- Unowned captures: unchanged (triple-equality owner guard; items stamped to another uid are left, never attached).

### Request volume per capture

| Path | Before | After |
|---|---|---|
| In-app (`parse-sms`) | 1 billed request (client may replay once with the same `request_id`; replay is not re-billed) → ≤3 Gemini calls | same bound; a not-completed verdict ends after 1 call |
| iOS (`process-ios-sms`) | ≤3 Gemini calls per claim; re-claims bounded by `capture_claim`'s attempt cap | same bound; terminal verdicts end after 1 call |
| Tokens | — | larger: a ~1.6 kB system instruction on every call and evidence quotes in the answer. Not measured. |

No new request type was added; local evidence and account currency ride on the existing request.

## 2. Tests (commands and results)

| Command | Result |
|---|---|
| `deno test --allow-all _shared/ process-ios-sms/ parse-sms/ sync-captures/` (in `supabase/functions`) | 748 passed, 1 failed, 2 ignored. The one failure is the parser-owned `process-ios-sms/parse_test.ts` declined-table row ("approved. Previous attempt declined.", `isDeclinedText` in `parse.ts`), which the parser specialist is changing concurrently; an earlier run before their edits was 718 passed / 0 failed. `ai_understanding_test.ts` 23/23; validator fixtures 53/53. `deno lint` clean on the 7 changed files; `deno.lock` unchanged. |
| `deno lint` on the 8 server files I changed/added | `Checked 7 files` (+ test file), no findings |
| `flutter test --no-pub test/engine/ai/` | 89 passed, 0 failed. |
| `flutter test --no-pub` new/changed files | `ai_structured_understanding_test.dart` 21/21, `ai_account_context_test.dart` 4/4, `notice_footer_import_test.dart` 4/4, `capture_import_service_test.dart` new test passes. |
| broader run | The first broad run, made while the machine load average was 100–600, had timeouts and failures in six files. Every one of them was rerun with `-j 1 --timeout 10x`: `account_number_matching`, `withdrawal_correction`, `outbox_kill_resume`, `astra_g2_contract` and `headless_capture_drain` gave 95 passed, 0 failed. `manual_paste_declined_message_test` gave 8/8; its first failure was a compile error caught mid-edit by another owner (`pasteBatchNotTransactionLabel`), and that helper is present now. Load was 600, so the rest of the suite was not rerun. |
| `flutter analyze --no-pub lib/domain/capture lib/domain/usecases/add_transaction_usecase.dart lib/engine/ai` + test files | No issues found. |

New tests: `_shared/ai_understanding_test.ts` (23), 4 shared fixture cases in `_shared/fixtures/ai_candidate_cases.json` (run by both suites), `app/test/engine/ai/ai_structured_understanding_test.dart` (21), `app/test/domain/usecases/ai_account_context_test.dart` (4), `app/test/domain/capture/notice_footer_import_test.dart` (4), one test in `capture_import_service_test.dart`.

Proof of "before": the V1-086 and account-currency validator tests were run against `git archive HEAD supabase/functions` in a scratch directory: all four FAILED there and pass now. `ai_understanding.ts`, `AiParseContext`, `parseWithContext`, `currencyFromAccount`, `status`/`messageType` do not exist at HEAD, so the tests using them cannot compile/run there. The provenance test passes at HEAD too (verification of existing behaviour, not a fix).

Existing tests whose expectations I changed: none.

## 3. Compatibility

**Build 147 against the new server** (147 sends `analysis_mode=ai_primary_v1` to both functions; verified in `git show ab5dc10a:…/ai_parser_client.dart` and `capture_backend_client.dart`):

| Response | 147 receives now | After |
|---|---|---|
| `parse-sms` transaction | `{…model fields, model_used}` | the same fields 147 reads (`amount, amount_text, currency, merchant_name, type, category_key, direction, occurred_at, model_used`), plus `message_type, status, evidence_checked, prompt_version`, which 147 ignores. `currency_source` only appears when the request carried `account_currency`, which 147 never sends. |
| `parse-sms` not a transaction | `{is_transaction:false}` | `{is_transaction:false, message_type?, status?, model_used, prompt_version}`; 147 reads only `is_transaction` → same handling (review unless deterministic ignore). More messages get this answer (pending/declined/notice answers that the repair loop used to retry and might have accepted). |
| `process-ios-sms` row | `parsed` jsonb | same keys + `aiModel`, `aiSystemVersion` when AI ran; 147 reads named keys only. A pending/declined AI answer now arrives as `parserSource:ai_ignored` (147: Smart Inbox unless deterministic ignore) instead of a possibly processed row. |
| V1-086 | — | rows the new server validator now accepts reach 147's own import gate (old `localParseContradictsServer`, global notice rule) → Smart Inbox as today; 147 sees no new confirmed rows from this change. |

So build 147 is at least as safe: every changed shape is a superset, and every behaviour change moves a result toward review, except V1-086 acceptance, which 147's gate still sends to review.

**New build against the old server**: the extra request fields are ignored by the old `parse-sms` (no strict schema; old idempotency hash ignores them). `message_type/status/prompt_version` absent → device judges as before. `account_currency` has no effect → a no-currency message stays in review. Safe.

**Stored data**: no device schema change, no migration, no rewrite of historical rows (3.15).

## 4. Not verified

- No real model was run: whether `gemini-3.8-flash` fills the new fields, follows the system instruction, resists injection, and what the review volume/latency/cost becomes. Needs the `eval` specialist's runner with the authorized key.
- `deno test` of the deployed function handlers end-to-end (parse-sms `index.ts` runs `Deno.serve` at import, so it is exercised only through its shared modules).
- iOS simulator/device: not run.

## 5. Changes needed in files I do not own

1. `supabase/functions/process-ios-sms/parse.ts` (parser): in `parsePrimarySms`, build the prompt with `buildUnderstandingPrompt({ task: <current rules without the "SMS:" line>, message: input.text })` from `_shared/ai_understanding.ts` and pass `message: input.text` to `runPrimaryAi`, so the iOS path gets the delimited message and the evidence checks too; record `UNDERSTANDING_PROMPT_VERSION` in the returned parse. The system instruction, schema and terminal verdicts already apply to it.
2. Data/sync owner (`app/lib/data/db/app_database.dart`, `transactions`): add `currency_source TEXT NULL CHECK(currency_source IN ('message','account_context'))`, map it in `TransactionEntity`, and I will set it from `AddTransactionResult.currencyFromAccount` (one line in `add_transaction_usecase.dart`). Server side the value already travels in the response.
3. UI owner: Smart Inbox should show the AI disposition (`message_type`/`status`) as the concrete review reason; confirm that a saved row can be moved to review and that reports state that review items are excluded from totals (not checked by me).
4. Consent copy owner (3.8/3.10): the in-app AI request may now also carry the on-device parser's amount/currency/direction and the matched account's currency code.

## 6. Owner actions

- Deploy order when approved: `parse-sms` and `process-ios-sms` together (they share `_shared/ai_*`); no migration.
- Authorize the bounded real-model evaluation (eval specialist) before relying on any accuracy claim for these prompts.

---

## Follow-up: global AI spend guard integrated (V1-022)

Requested by the orchestrator after the main report. It uses the `ops` specialist's `_shared/ai_spend_guard.ts` (`consumeGlobalAiBudget`, unchanged) and migration `20261117120000_ai_global_spend_guard.sql` (unchanged). Model: claude-opus-5-5.

**Status: DONE.** Not deployed; no production call made.

### What happens at each call site

| Function | Where the budget is reserved | When the budget is refused |
|---|---|---|
| `parse-sms`, primary path (`ai_primary_v1`, build 147 and new) | Before **every** Gemini attempt (repairs included), inside `runPrimaryAi`, after the per-attempt identity/consent recheck. The quota and idempotency checks have already passed. | No provider call. Returns the existing retryable `upstream_unavailable` (503), and the idempotency claim is completed as `failed`. The device client already maps this to `ai_deferred`: the message is kept for review and is never auto-saved. |
| `parse-sms`, legacy path | Before the single Gemini request | Same as above. `fallbackParse` is **not** used, so no local result is substituted. |
| `process-ios-sms` (both paths) | Inside the `beforeAi` hook, right after `capture_ai_dispatch` allows the attempt (claim, consent and quota have already passed). It runs per attempt, so repairs count too. `parse.ts` (parser-owned) is untouched. | No provider call. The capture is finalized **`retryable`** with `failure_reason = 'ai_unavailable'` and `status = rejected`. The parse is `ai_pending` with no amount and the notification is the silent `received`. This is the same row and response as today's provider outage. The capture stays a pending item: replays retry it under `capture_claim`'s attempt cap and then go to review. It is never dropped and never saved from the unvalidated reading. |
| `enrich-merchant` | Before the paid Google Places request (`'places'` bucket), after consent, quota and idempotency. It applies only when `MAPS_API_KEY` is set, as Places is not called otherwise. | No Places call and **no write to the global `merchant_keywords` catalogue**. Returns the retryable `upstream_unavailable`. Both app call sites already catch non-2xx and fall back to the feedback queue. |

**Function deployed before the migration — chosen behaviour: run exactly as today.**
- Covers only "function does not exist" (PostgREST `PGRST202`, Postgres `42883`). The call goes ahead unchanged and a content-free `ai_budget_guard_absent` line is logged.
- Every other guard failure **fails closed**, per the ops contract: refusal, other RPC error, thrown or malformed reply. That covers `ceiling`, `disabled`, `unknown_bucket` and `unavailable`.
- The detection lives in the new `_shared/ai_budget_gate.ts` (`reserveAiBudget`). It watches the RPC reply that `consumeGlobalAiBudget` already receives, so the ops module is unchanged.
- **Consequence to know:** once the migration is applied, a schema-cache miss for the function would also go ahead (fail open). Deploy order stays free.
- Logs carry only `bucket` and `reason`, no identity.

**Build 147 compatibility.** No new response shape:
- `parse-sms` and `enrich-merchant` return an error code they already return today (`upstream_unavailable`, retryable).
- `process-ios-sms` returns the exact provider-outage shape that already exists in `handler_outcome_test`.

**Choice to review:**
- On the legacy (non-primary) `process-ios-sms` path, a budget refusal makes the capture **retryable even when the deterministic parse resolved it**.
- A provider outage on that path keeps the local result. The budget case is stricter because "never auto-saved on an unvalidated basis" was required, and `parse.ts`'s `isResolved` is parser-owned.
- Build 147 and the new build use the primary path, so this affects only older clients sending `allowAi` without `analysis_mode`.

### Files
- New: `supabase/functions/_shared/ai_budget_gate.ts` and `_shared/ai_budget_gate_test.ts`, `process-ios-sms/ai_budget_test.ts`, `parse-sms/ai_budget_contract_test.ts`, `enrich-merchant/ai_budget_contract_test.ts`.
- Changed:
  - `_shared/ai_primary.ts`: new optional `reserveAttempt` hook and the `'budget'` result reason.
  - `parse-sms/index.ts`: still contains no "sender".
  - `process-ios-sms/index.ts`.
  - `process-ios-sms/capture_rpc_fake.ts`: models `consume_ai_global_budget` as allow, ceiling-after-N, absent or error; the default is allow.
  - `enrich-merchant/index.ts`: this change only, as authorised.

### Tests (synthetic data)
| Test | Before (integration removed in a scratch copy) | After |
|---|---|---|
| `_shared/ai_budget_gate_test.ts` (4: allowed, refusals, absent → proceeds, other failures fail closed) | module did not exist | 4/4 |
| `_shared/ai_primary_test.ts` — 3 new (reservation order consent→budget→provider per attempt; refused → 0 provider calls; exhausted mid-repair → no further call) | 3 FAILED | 3/3; the 6 existing still pass |
| `process-ios-sms/ai_budget_test.ts` (7: allowed 1 unit/call; 3 units for 3 attempts; exhausted → 0 calls + retryable + outage shape; exhausted between repairs; RPC error fails closed; legacy path not auto-saved; **guard absent → processed exactly as before**) | 6 FAILED; the "absent" test passes (it pins today's behaviour) | 7/7 |
| `parse-sms/ai_budget_contract_test.ts` (3, source pins — the function serves on import) | 2 FAILED (the refusal-shape pin passes on its own helper) | 3/3 |
| `enrich-merchant/ai_budget_contract_test.ts` (2, source pins) | 2 FAILED | 2/2 |

Commands, run in `supabase/functions`:
- `deno test --allow-all _shared/ process-ios-sms/ parse-sms/ sync-captures/ enrich-merchant/` → **767 passed, 1 failed, 2 ignored.** The one failure is the same parser-owned `parse_test.ts` "declined table" row as above.
- `deno check` on the three functions → clean.
- `deno lint` on the 11 touched files → clean.
- `deno.lock` is unchanged.

### Not verified
- The real RPC against a migrated local or staging database. The fake models the migration's documented replies, and PostgREST's `PGRST202` code for a missing function is assumed, not observed here.
- `parse-sms` and `enrich-merchant` are pinned from source, not by a running handler, because they call `Deno.serve` on import.
- No deploy.

### Owner and orchestrator actions
- Deploy order is free. Watch M7 (`ai_global_spend.denied`): when it is above 0, new captures are waiting for budget and show as pending or review.
- Raising the ceiling is a production `update public.ai_global_budget`.
- `bank-discovery` also calls Gemini and is **not** guarded. It is not in my paths.

### Follow-up 2: `bank-discovery` gated as well

- **Change:** `supabase/functions/bank-discovery/index.ts`, +8 lines, edited for this only.
  - `reserveAiBudget(supabase, 'gemini')` runs immediately before the single Gemini request.
  - It runs after consent, the per-identity cap (50/day) and the unconfigured-key check.
- **Refused:** no model call. The function returns the same retryable `upstream_unavailable` an unconfigured key already returns.
  - `app/lib/engine/ai/bank_discovery_client.dart` treats any non-200 response as "no suggestion" (`null`). The sender stays unknown and the next message tries again.
  - No suggestion is invented.
- **Guard absent:** as today (the shared gate's `PGRST202`/`42883` rule). Any other guard failure blocks the call.
- **Test:** `bank-discovery/ai_budget_contract_test.ts`. It has 2 source pins, because the function starts its server on import:
  - reservation after consent, quota and the key check, and before the request;
  - a refusal returns the retryable error.
  - The gate's own behaviour, including guard absent and fail closed, is covered by `_shared/ai_budget_gate_test.ts`.
- **Before/after:** against the `HEAD` source both tests FAILED (0/2); after the change, 2/2 pass. `deno check` and `deno lint` are clean.
- With this, every Gemini and Places call site in `supabase/functions` reserves the global budget first.

---

## Follow-up 3: server push wording follows the outcome (decision 3.12)

Requested by the orchestrator. Files:
- `supabase/functions/_shared/capture_push.ts`
- the push-building code in `supabase/functions/process-ios-sms/index.ts`
- tests in `_shared/capture_push_test.ts`, `process-ios-sms/notification_classification_test.ts` and `process-ios-sms/capture_state_machine_test.ts`.

`notification_policy.ts` needed no change: it governs budget/goal pushes, not capture pushes. Model: claude-opus-5-5. **Status: DONE in code.** Not deployed.

### Rule
The server never records anything in the user's ledger. The device records when it imports the row, and may still send it to review (V1-086 contradictions, the V1-088 class). So **no server push says "recorded"**. Each capture push now ends with one status line; the wording mirrors the native `captureBanner`, as `ios.md` §3 describes it:

| Server outcome | Where it comes from | English | Arabic |
|---|---|---|---|
| `queued` | `processed` | Not recorded yet: Qirsh checks it before adding it. | لم تُسجَّل بعد: يتحقق منها قِرش قبل إضافتها. |
| `duplicate` | `duplicate` | Possible duplicate: needs your review in Qirsh before it is recorded. | قد تكون مكررة: تحتاج مراجعتك في قِرش قبل تسجيلها. |
| `review` | legacy `needs_review` | Needs your review in Qirsh before it is recorded. | تحتاج مراجعتك في قِرش قبل تسجيلها. |
| `declined` | `rejected` and `isDeclinedText` | Not recorded: the message says it was declined or failed. | لم تُسجَّل: تفيد الرسالة بأن العملية مرفوضة أو لم تتم. |
| `excluded` | `rejected` and (AI said "not a transaction", or the message meaning is not-completed, a notice or an OTP) | Not recorded: no completed transaction in this message (for example pending or a notice). | لم تُسجَّل: لا توجد عملية مكتملة في هذه الرسالة (مثل عملية معلّقة أو إشعار). |
| `unread` | any other `rejected` (V1-088 class: the matched device keeps it for review) | Not recorded yet: open Qirsh to check this bank message. | لم تُسجَّل بعد: افتح قِرش للتحقق من رسالة البنك هذه. |

`isDeclinedText` and `messageMeaning` from `parse.ts` are only **called**; `parse.ts` is not edited.

**Details**
- The pushed alert and the in-response notification show what is available:
  - type (title or "Type:" line), amount and currency, merchant or source (capped at 80 characters), local time;
  - for a declined or unread message, the amount the text shows.
- **Category:** shown only when it is the user's **saved merchant rule** (`withUserMerchantRule`, now marked `ruleCategory`). A parser's or model's category is a proposal and is never shown. This applies in both languages and to every outcome.
- **Last four digits:** only exactly four ASCII digits.
  - Shown in the notification text the app receives in the response (`Card/account ending 1234` / `البطاقة: ****1234`).
  - **Not in the APNs alert.** The existing privacy pin `capture details opt-in … without card or SMS` in `capture_state_machine_test.ts` requires this, and I did not loosen it.
  - **Decision for the owner:** 3.12 lists last four among the details, but that pin keeps card digits out of anything that travels through Apple.
- **Never in any push:** OTPs, full card or account numbers, or raw SMS text. The sender appears only when it is an alphanumeric bank brand, as before.
- **Limits:** the title is at most 120 characters and the body at most 600, as before (`capturePushContent` falls back to the generic alert otherwise); this is tested.
- **Generic alerts** are used when details are hidden or the client did not opt in, including on the retry worker. They now follow the outcome:
  - `new_transaction` keeps the manifest wording "New transaction captured" / "تم رصد عملية جديدة" (it does not say "recorded"; the Flutter contract pin still passes);
  - review, duplicate and rejected pushes no longer say "captured".
- Pushes still sent **only where they were sent before**:
  - AI-primary rejections stay silent;
  - transient or retryable captures queue no push.

### Build 147
- **APNs payload keys are unchanged:** `payloadId`, `notificationType`, `smartInboxItemId`, `transactionId`, `notificationLogId`, `source`; tested.
- **Notification types are unchanged:** `new_transaction`, `needs_review`, `suspicious_duplicate`, `received`. The new `captureOutcome` key in the stored notification JSON is additive and ignored by build 147.
- **What build 147 will display:**
  - **APNs pushes** (app path): the new text, including the status line.
  - **Shortcut banner, duplicate or `received`:** it shows the server's `title`/`body`, so the new wording.
  - **Shortcut banner, `new_transaction` or `needs_review`:** build 147 builds **its own** banner from `capture.parsed`. That banner still says "تم رصد عملية شراء" and **still shows the parsed category**. The server cannot change this without altering `capture.parsed`, which also feeds the stored row and import, so I did not change it.

### Changed expectations (decision 3.12)

| Test | Before | Now |
|---|---|---|
| `capture_push_test` "only opted-in…", "transfer preview…", "missing timezone…" | Body without a status line; category taken from the parse | Body ends with the queued line; the category is passed as the saved rule |
| `notification_classification_test` "duplicate … reported defect" | "موجودة مسبقاً؟" | The duplicate status line (title and nature unchanged) |
| `notification_classification_test` "a known category still renders" | Parse category | Saved-rule category |
| `notification_classification_test` "needs_review … no amount" | "افتح قرش لمراجعة الرسالة." | The review status line |
| `notification_classification_test` "English copy…" | "Open Qirsh to review" | "…needs your review in Qirsh before it is recorded" |
| `notification_classification_test` "rejected alert … sender" | "…لم نتمكن من تحليلها. الصقها يدوياً…" | The `unread` line; the brand-or-numeric sender rule is unchanged |

No privacy or consent assertion was removed or loosened.

### New tests and before/after proof
`capture_push.ts` and `process-ios-sms/index.ts` were restored to `HEAD` in a scratch copy:

| Test | At HEAD | Now |
|---|---|---|
| `capture_push_test` (5 new 3.12 tests) | 4 FAILED; the APNs-limit test passes at HEAD too | 13/13 |
| `notification_classification_test` (4 new: outcome mapping, processed "not recorded yet" ×2 languages, declined ×2 languages with details and no category, last-four bound) | Failed to load (`outcomeOf` absent) | 20/20 |
| `capture_state_machine_test` (2 new handler tests through the real APNs path) | 2 FAILED | Pass. They cover the processed push (status line and payload keys) and a declined message × {details, hidden} × {en, ar}: "not recorded", never "captured", no card digits on the wire |

**Commands and results**
- `deno test --allow-all _shared/ process-ios-sms/ parse-sms/ sync-captures/ enrich-merchant/ bank-discovery/ process-notification-retries/` → **799 passed, 0 failed, 2 ignored.** The parser-owned declined-table row now passes after the parser's own change.
- `deno check` on `process-ios-sms` and `process-notification-retries` → clean.
- `deno lint` on the touched files → clean.
- `flutter test --no-pub test/architecture/capture_notify_v2_contract_test.dart` → 19 passed.
- `deno.lock` is unchanged.

### Not verified
- No push was seen on a device.
- Display truncation on the lock screen was not checked.
- Build 147's Shortcut banner was not run; the table above is from its source at `ab5dc10a`.

### Follow-up 4: masked last four in the APNs alert (decision 3.12)

The owner's decision 3.12 approves showing the card or account's last four digits in notifications. It forbids only full card/account numbers, OTPs, secrets and raw SMS text. **This replaces the "Decision for the owner" note under Follow-up 3:** the last four now appear in the detailed APNs alert.

- **Code** (`_shared/capture_push.ts`, `process-ios-sms/index.ts`):
  - When details are shown (`notificationDetails: true`), the APNs alert carries `Card/account ••1234` / `البطاقة/الحساب: ••1234`.
  - The digits come only from the parse's `last4` field (the suffix the parser identified) and only when they are exactly four ASCII digits. Anything else shows no card line.
  - Defence in depth: in the merchant name, any run of five or more digits (Latin or Arabic-Indic) is masked as `•••`. A card number, IBAN or account number that slipped into a merchant name is never shown.
  - Hidden-details and generic pushes are unchanged and carry no digits.
- **Changed test, a decided change under 3.12:** `process-ios-sms/capture_state_machine_test.ts` "capture details opt-in sends amount and merchant without card or SMS; hidden stays generic" is renamed to "…sends amount, merchant and only the masked last four; hidden stays generic".
  - Before: `!alert.body.includes('1234')`.
  - Now: the body contains `••1234`, and `1234` appears exactly once.
  - `assertNoIdentifierDigits` now applies to the whole alert: the only run of four or more digits it allows is `••dddd`, so any longer run fails.
  - Still asserted: no "Purchase of" (no raw text). The hidden-details branch is still exactly the generic alert.
  - In my Follow-up 3 declined-message handler test, the old "no 1234 anywhere" check is replaced by the same bound when details are shown, and by "no digits at all" when they are hidden.
  - `capture_push_test` "last four only on request…" now expects the masked form.
- **New negative tests** (`_shared/capture_push_test.ts`):
  - **Detailed alert:** each of these, in English and Arabic, must leak nothing:
    - an 8-digit or 16-digit `last4`;
    - a PAN, an IBAN, or an Arabic-Indic digit run inside the merchant name;
    - an OTP and raw text in `rawMessage`.
  - **Checked absent:** the PAN, the OTP, the IBAN, "Purchase of" and "OTP".
  - **Self-check:** the checker itself rejects `••12345`, a PAN, an OTP and a bare 5-digit run.
  - **Generic alerts:** every type × outcome × language carries no digit at all.
- **Before/after:** against the Follow-up 3 code (no suffix in APNs, no merchant masking), 4 tests FAILED: the changed privacy test, the declined-details test, the masked-suffix test and the negative test. All pass now.
- **Results:**
  - Deno across `_shared/`, `process-ios-sms/`, `parse-sms/`, `sync-captures/`, `enrich-merchant/`, `bank-discovery/`, `process-notification-retries/`: **801 passed, 0 failed, 2 ignored.**
  - `deno check` and `deno lint` are clean.
- **Build 147:** the payload keys are unchanged. Build 147 displays the alert text as sent, so with details on it shows `••1234`.

---

## Follow-up 5: "move into review" and the bank-reported balance time (owner brief 4.6)

Requested by the orchestrator for the `a11y` specialist (`a11y.md`, "Changes needed outside my paths", items 2 and 3). Model: claude-opus-5-5. **Status: DONE (data layer).** The "Move to review" button is the `a11y` owner's.

### API

```dart
// lib/domain/repositories/transaction_repository.dart
typedef ReportedBalance = ({Money balance, DateTime occurredAt});
abstract class TransactionRepository {
  Future<TransactionEntity> markForReview(String id);
  Future<ReportedBalance?> latestReportedBalance({String? accountId});
  // unchanged: Future<Money?> latestBalanceAfter({String? accountId});
}
// lib/domain/usecases/mark_for_review_usecase.dart
class MarkForReviewUseCase {
  MarkForReviewUseCase(TransactionRepository transactionRepository);
  Future<TransactionEntity> call(String transactionId);
}
```

Restoring a reviewed transaction uses the existing `TransactionRepository.confirm(id)` / `ConfirmTransactionUseCase`.

### What `markForReview` does (`DriftTransactionRepository`)

- **Status:** `confirmed` becomes `pending`.
  - This is the **existing** review state: Smart Inbox's pending filter shows it, and every total, report and latest-balance query counts only `confirmed`.
  - No new state and **no Drift schema change**.
- **Unchanged:** only `status` and `updated_at` are written. Amount, currency, type, account, `category_id` and `category_source` keep their values, so a manual (`user`) category stays manual and `rule` stays `rule`.
- **Sync:**
  - It enqueues `OutboxOperation.update` with the entity, the same path as `confirm()`. The payload carries `status: 'pending'`, and a later confirm coalesces into the same outbox row.
  - **Server:** accepts `pending` (check constraint `chk_user_transactions_status`, migration 0029). The push service forwards `pending`.
  - **Other devices, including build 147:** pull maps server `pending` to local `pending` (`ledger_sync_service.dart`; the same mapping is present at `ab5dc10a`).
- **Correction log:**
  - One `proof_correction_events` row of type **`rejected_or_deleted`**. It is an existing type, because the table's CHECK constraint allows only four types and a new one would need a schema change.
  - In the Proof gate this outranks `confirmed`, so a parse the user doubted is never counted as confirmed-unchanged; that is the strict side.
  - A later re-confirm adds a `confirmed` event, but the row stays in the rejected bucket.
- **Idempotent and bounded:**
  - A row that is already `pending` or `ignored` is returned unchanged: no write, no outbox row, no event. An ignored (deleted) row is not revived.
  - An unknown id throws `StateError`, as `confirm()` does.
  - Everything runs in one database transaction.
- **Confirming again:** `confirm(id)` updates the same row, so there is no duplicate. Amount, category and provenance come back as they were, and totals count it again.

### `latestReportedBalance`

- Same query, rows, ordering and filters as `latestBalanceAfter`: confirmed only, latest `occurred_at`, combined scope skips accounts excluded from totals.
- It additionally returns that row's `occurred_at` (UTC) as `occurredAt`.
- `latestBalanceAfter` and its two callers (`dashboard_providers.dart`, `report_snapshot_builder.dart`) are unchanged.

### Tests

- **New: `app/test/data/mark_for_review_test.dart`**, 6 tests on an in-memory encrypted database with a real `LedgerOutboxQueue`:
  - move to review: status pending, out of totals, amount and manual category and provenance kept, one outbox `update` with `status: pending`, one `rejected_or_deleted` event;
  - idempotent;
  - re-confirm restores in place: one row, provenance `rule` kept, totals back, outbox coalesced to `confirmed`;
  - `pending` and `ignored` untouched, unknown id throws;
  - `latestReportedBalance` gives balance plus time, agrees with `latestBalanceAfter`, and a row in review is excluded from both;
  - null when there is no balance.
- **Before/after:** with the repository and interface restored to `HEAD` and the use case removed, the test file **fails to compile** (`markForReview`, `MarkForReviewUseCase` and `latestReportedBalance` are missing). After the change, 6/6 pass. The files were restored, and the diff was checked.
- **Changed file outside the new ones:** `app/test/domain/budget_progress_usecase_test.dart`. Its fake implements the full interface without `noSuchMethod`, so I added two `UnimplementedError` stubs; no assertion changed. The other 16 fakes use `noSuchMethod`.
- **Commands:**
  - `flutter analyze --no-pub` on the touched files and every `TransactionRepository` fake → **No issues found.**
  - `flutter test --no-pub -j 2` on the new test, `exclude_from_totals_test`, `budget_progress_usecase_test`, `proof_correction_log_test`, `proof_shadow_dao_test` and all files with `TransactionRepository` fakes → **234 passed, 0 failed.**
- The `data` specialist's files (`transactions_backfill_service.dart`, sync e2e harness) were not touched.

### Notes for the UI owner

- `ConfirmTransactionUseCase` records an engagement event on every confirm. Moving to review and confirming again can therefore award the confirmation action more than once. Whether that matters is a product call; the data layer does not block it.
- Not verified: a two-device round trip against a real server (only the code paths and the server constraint were checked).

## Follow-up 6 — parser meaning integrated on the device, cloud-import and AI-primary paths

Requested by the orchestrator after `parser` finished (`parser.md` §8). Model: `claude-opus-5-5`. Synthetic messages only; `tools/message_eval/heldout/**` not read. Nothing committed, staged or stashed.

### (3) Currency codes from the parser table — DONE, both sides, drift-tested
- Server `CURRENCY_CODES` (`_shared/ai_candidate_validator.ts`) = `parser_rules.json → currencyTable.iso` ∩ codes persisted Money can hold. App `AiCandidateValidator.currencyCodes` and `kCaptureCurrencyCodes` = `CurrencyTable.iso` ∩ `kCurrencyScale`. 51 codes (was 12); all 12 old codes kept.
- **Why the intersection:** `kCurrencyScale` (persisted Money) throws for an unknown code. Accepting e.g. `NOK` would hand the device a capture it cannot store.
- Grounding follows the parser rule: a core code (`Normalizer.isoCurrencyAlternation`) matches in any case as a whole word, as before. Any other table code counts only in capitals next to a figure (`NGN 5,000`). Local forms count only next to a figure (`₦5,000`, `SR1,250`).
- The server holds its own `CURRENCY_SCALE` (equal to `kCurrencyScale`) and rejects an `amount_text` beyond the scale. `_shared/money_text.ts` is not mine and was left unchanged.
- `validated_capture.dart` drops its private 12-code scale and alias copies. It now uses `kCurrencyScale` and `AiCandidateValidator.currencyGrounded` (one implementation).
- **Tests:**
  - `_shared/ai_currency_table_drift_test.ts` (5): list = table ∩ scale; `CURRENCY_SCALE` == the Dart `kCurrencyScale`, parsed from the Dart file; NGN accepted; capitals/local-form rule; scale overflow rejected.
  - `app/test/engine/ai/ai_currency_codes_test.dart` (3): both Dart lists == JSON table ∩ scale; grounding rule; NGN import accepted.
  - **Before:** server 3 of 4 failed, Dart 3 of 3 failed, with the old list and grounding swapped back in. **After:** all pass.
- **Changed expectation:** `ai_candidate_validator_test.ts` "currency outside the whitelist is rejected" used `INR`, which is now on the list. It now uses `NOK`: a table code that persisted Money cannot hold, so the assertion still tests the same rule.

### (1) / (6) Meaning gate in `add_transaction_usecase` — DONE
- The use case reads `parseResult.meaning ?? ParserEngine.meaningOf(rawMessage)`. Any disposition other than `record` holds the message: `not_completed`, `no_movement_notice`, `own_account_transfer`, `cash_deposit`, `multiple_events` and `otp`. A held message:
  - makes **no AI request** (skip reason `message_meaning_<reason>`, not a temporary failure);
  - is never booked from the local reading;
  - returns `notTransaction`. Review and no-movement kinds use `droppedByParser: true` (Smart Inbox, never silent). An OTP counts as intentionally ignored.
- New `AddTransactionResult.reviewReason` carries the meaning reason (`cash_deposit`, `own_accounts`, `multiple_amounts`, `bill_due`, `scheduled_or_expected`, `pending`, …). `capture_import_service._importLocally` passes it to the Smart Inbox row (`metadata.review_reason`).
- **Multi-event messages the AI schema cannot hold (6):** these are `multiple_events` → held → review (no AI call, nothing booked).
- **Currency absent:** this was already the account-context inference (V1-031, follow-up 0). `currencyDefaulted` → the AI receives only the confidently matched account's currency; otherwise the local reading is invalid (V2) → Smart Inbox. Not changed.
- **"Direction not established":** a review kind already resolves to an unknown direction. Otherwise an unresolved direction is rejected (`direction_unresolved` / LocalValidity `unknownType`) → Smart Inbox. Not changed.
- **Tests:** `app/test/domain/usecases/ai_meaning_gate_test.dart` (5, real `AddTransactionUseCase` and parser, in-memory Drift):
  - cash deposit, purchase + cashback, bill due and expected salary each give 0 AI calls, nothing stored, `droppedByParser` and the reason;
  - a completed purchase with an OTP footer still calls the AI and is recorded.
  - **Before** (gate disabled): 4 of 5 failed. **After:** 5 of 5 pass.

### (2) and import paths — DONE (`capture_import_service.dart`)
- **Non-AI-primary path:** a processed server result that the validator rejects with `direction_contradiction` now goes to Smart Inbox with `review_reason: direction_contradiction`. It no longer falls back to the local reading. Other rejections still fall back to the local parse, as before.
- **Both paths:** `meaningHoldReason(item.text)` (new, `validated_capture.dart`) is checked before any server result is imported. A server (any build) that processed a cash deposit, a notice or several movements as money is not imported → Smart Inbox + reason.
- **AI-primary path:** a server rejection that carries `parsed.reviewReason` (from (4)) keeps that reason on the row.
- **Tests:** 6 new in `capture_import_service_test.dart`:
  - validator direction contradiction;
  - cash deposit, both paths;
  - bill due, both paths;
  - server reason kept.
  - **Before** (routing reverted): 6 of 6 failed. **After:** 51 of 51 in the file pass.

### (4) AI-primary no-movement gate and false contradictions — DONE
- **Server gate** (`process-ios-sms/index.ts`, both analysis modes):
  - A `processed` result whose `messageMeaning(sanitizedText).disposition` is not `record` becomes `rejected`, with `parsed.reviewReason = meaning.reason`. A model answer cannot make a notice, OTP or review kind into money.
  - `outcomeOf` reports `review` for review kinds (3.12 wording "needs review").
  - Test `process-ios-sms/ai_meaning_gate_test.ts` (10): 4 held kinds × 2 modes, plus 2 controls (OTP-footer purchase still processed). **Before** (gate off): 6 failed. The 2 legacy no-movement rows already passed, because `parse.ts` rejects them before AI. **After:** all pass.
- **parse-sms AI-primary:**
  - Before any provider request, `messageMeaning(reSanitized)` other than `record` returns `{ is_transaction: false, message_type }`. `message_type` is a bounded code mapped from the reason. No call is made and no budget is used.
  - Build 147 treats an AI "not a transaction" as a review item, never a silent drop.
  - The legacy request is unchanged.
  - Test `parse-sms/ai_meaning_gate_contract_test.ts` (2): source pin that the gate comes before `runPrimaryAi`, plus the meaning of the held and control texts. No word "sender" appears in `index.ts`.
- **False contradictions (classes: deposit-worded outgoing transfers, cue-word merchant names, refunds, OTP footers).** Probed on synthetic examples of each class:
  - **Server (`ai_candidate_validator.ts`):**
    - The wording direction now reads the clause structure first (debit/credit flow phrases from `parser_rules.json → messageMeaning`, mirroring `DirectionSignal.flowOf`). It reads the **first sentence that carries the booked amount**, with a grounded merchant name masked. Word families are the fallback.
    - Mirrored rather than imported: `message_meaning.ts` imports the validator, so a back-import would be a module cycle.
    - The rejected-but-correct deposit-worded transfers (English and Arabic) are now accepted.
    - The same change now **catches** previously accepted wrong answers: income for "Transfer … to Deposit Holdings … from your account".
  - **Device:**
    - New `AiCandidateValidator.bookedDirection(text, amount:, merchant:)`: `DirectionSignal.detect` on the first sentence carrying the amount (merchant masked), else on the whole message. It is used by:
      - the device AI validator;
      - the use case's post-reclassification check;
      - `validateCaptureCandidate`;
      - the PR-04 wording check.
    - `localParseOpposesDirection` keeps its type-based opposition, but the booked direction now **vetoes** it when it agrees with the server. It never adds an opposition: a transfer still keeps the server result, which the parser's table test pins.
    - The one device false contradiction I could reproduce: "POS purchase SAR 45.00 at Salary Store. Credited points 45".
  - **Tests:**
    - `_shared/ai_direction_flow_test.ts` (15): 8 correct answers accepted, a points/merchant case, 5 real contradictions plus a split-sentence credit still rejected. **Before** (flow off): 5 failed.
    - `app/test/domain/capture/booked_direction_test.dart` (10): 6 correct, 4 real. **Before:** 2 failed.

### (5) Tip / fee / VAT totals — DONE in the validators (no parser change)
- The parser does not represent tip totals: the local parse returns no transaction (review) for "SAR 100.00 + tip SAR 15.00. Total charged SAR 115.00". It reads the VAT layout's total correctly.
- **New rule on both validators and the import validator** (`chargedTotal`): when the message names a tip/gratuity/service charge/fee/VAT/tax component **and** states a total figure (`total [charged|paid|debited]`, `grand total`, `الإجمالي`, `إجمالي المبلغ`, `المجموع`), the amount must equal that total. Otherwise the candidate is rejected with `amount_not_charged_total` and goes to review, never booked as the base.
- "Total balance/due/spent" never matches, because the figure must follow the label directly.
- A same-currency fee is never a second row: `_maybeSaveFee` already skips it, so the total is counted once.
- **Tests:** 4 shared fixtures in `ai_candidate_cases.json` (English tip, Arabic VAT; base rejected, total accepted), run by both suites. **Before** (rule off, server): the 2 base cases failed. **After:** server 57/57, Dart fixtures pass.

### Build-147 compatibility
- No response shape changed:
  - `parsed.reviewReason` is an extra jsonb key;
  - parse-sms returns the existing `is_transaction:false` shape;
  - statuses are the existing `rejected` / `processed`.
- An old app receiving a held capture keeps it in Smart Inbox (AI-primary) or reads it locally (legacy). It is never processed money from the server.
- New device builds talking to an old server re-check meaning, direction and totals locally on import.

### Commands and results
- `deno test --allow-all _shared/ process-ios-sms/ parse-sms/ sync-captures/ enrich-merchant/ bank-discovery/ process-notification-retries/`: **836 passed, 1 failed, 2 ignored.**
  - The one failure is the parser-owned `parse_test.ts` "declined table" row **Q232** ("Annual fee of SAR 250 will be charged on 1 Dec"). Its open-defect pin says the server "accepts a grounded AI payment **and refund**". The flow-first direction check now rejects the refund ("will be charged" is a debit flow), so the defect is half fixed and the pin is stale.
  - The fix is one word in two parser-owned files (see below). My attempt to edit them was refused by the permission system, so they are untouched.
- `deno lint` on the 7 changed/new server files: clean. `deno.lock` unchanged.
- `flutter analyze --no-pub` on all touched Dart files: **No issues found.**
- `flutter test --no-pub -j 2`:
  - First full run of `test/engine/ai test/engine/parser test/domain/capture test/domain/usecases` (+ local-V2, silent-drop, commit characterization) and `test/features/capture`: 5171 passed, 44 failed. All 44 were the parser table's "opposite import" pin, under my first design, which let the booked direction add oppositions for transfers.
  - Redesigned to veto-only (above). The table test, `test/domain/capture`, `test/engine/ai`, `test/domain/usecases`, `capture_import_service_test` and `capture_sync_service_test` then gave **1940 passed, 0 failed.**
  - Full rerun of the whole set after the redesign: **5174 passed, 1 failed.** The one failure is a load error, not a test: `notification_log_sync_service_test.dart` does not compile because `lib/features/accounts/account_detail_screen.dart`, another owner's in-progress UI file, uses l10n keys `accBankReportedBalance` / `accBankReportedAt` that are not generated yet. It is unrelated to this follow-up.

### Changed expectations
1. `ai_candidate_validator_test.ts`: `INR` → `NOK` in the "outside the whitelist" case (INR is now accepted; reason above).
2. None in parser-owned tests. The Q232 pin needs the parser owner (below).

### Needed in files I do not own
- **`parser`:** in `process-ios-sms/declined_cases.json` and `declined_cases_deviations.json`, row `V1-RES10 Q Q232`: change "server accepts a grounded AI payment and refund;" to "server accepts a grounded AI payment;". The refund is now rejected (`direction_contradiction`). The payment is still accepted by `parseSms` on the legacy path. The `process-ios-sms` handler now rejects it via the meaning gate only if `messageMeaning` reads it as no movement.
- **`parser`:** "Transfer of SAR 2,000.00 from your account *1234 to your account *5678" is read as `completed_movement` (debit), not `own_account_transfer`.
- **`parser`:** "Get 20% cashback up to SAR 50.00 on your next purchase… Offer ends soon" is read as `completed_movement` (`footer_set_aside`), not an offer. The validator rejects the model's credit for it, but only on direction.
- **`parser`:** the merchant for "POS purchase SAR 45.00 at Salary Store. Credited points 45" runs into the next sentence ("Salary Store. Credited points 45").
- **Owner of `legacy_capture_drain.dart`:** pass `result.addTransactionResult.reviewReason` as `reviewReason` to `handoff.complete`, as `capture_import_service` now does. Until then the legacy drain stores held captures without the reason (still Smart Inbox, still not booked).

### Not verified
- No device or simulator run, and no deployed function.
- `process-ios-sms` and `parse-sms` must be deployed together with `parser_rules.json` (the validator now reads `messageMeaning` flow lists from it).

## Follow-up 7 — storage vs detection currency split (decision 3.7)

**Outcome: DONE. The split was contained; no migration is needed.** Every country except Antarctica now gets its own currency as a storable default. Antarctica has no currency, so it still asks.

### What changed
- `app/lib/domain/finance/currency_scale.dart`
  - **`kCurrencyScale` is now the STORAGE table: 155 codes.** It contains every active ISO-4217 code with a 0, 2 or 3 digit minor unit. Funds are excluded (BOV, CHE, CHW, CLF, COU, MXV, USN, UYI, UYW, XAD). So are codes with no minor unit (precious metals, XDR, XSU, XUA, XXX, XTS, ...) and the two 4-decimal units of account (CLF, UYW), which Money cannot hold.
  - Scales: 3 decimals for BHD, IQD, JOD, KWD, LYD, OMR, TND. 0 decimals for BIF, CLP, DJF, GNF, ISK, JPY, KMF, KRW, PYG, RWF, UGX, VND, VUV, XAF, XOF, XPF. All the rest have 2.
  - The table is generated and is idempotent. The generator is `app/tool/generate_currency_scale.py`. It reads ISO 4217 List One (SIX `list-one.xml`, Pblshd="2026-09-17"); the source URL is in the script header. It rewrites only the region between the `BEGIN/END GENERATED` markers.
  - The 50 codes that were in the table before all appear in it with the same scales.
  - **New `kDetectionCurrencyScale`:** the previous 50-entry literal, unchanged.
- Detection consumers moved to `kDetectionCurrencyScale`:
  - `engine/proof/evidence.dart`, minimal edit: `_buildIsoLiteralPattern` and two comments, plus a read-only getter `isoLiteralPatternSource` for the pin test.
  - `engine/ai/ai_candidate_validator.dart` (`currencyCodes`).
  - `domain/capture/validated_capture.dart` (`canonicalCaptureMoneyText`, mirroring the server `canonicalMoneyText`).
- Unchanged on purpose, because their result is the same for detected codes:
  - `evidence.dart:365` (the scale of a detected ISO);
  - `proof_checker.dart:319` (the iso always comes from detection).
- Server side:
  - `_shared/ai_candidate_validator.ts`: `CURRENCY_SCALE` is unchanged; only its comment now says it mirrors the detection registry.
  - `_shared/ai_currency_table_drift_test.ts` now parses `kDetectionCurrencyScale`.
  - `parser_validation.ts` `scaleFor`, `parse-sms/money.ts`, `_shared/money_text.ts` and `sync-captures/money.ts` are detection-side and untouched.

### Server check (read-only; no migration needed)
- Currency columns only have a format check: `CHECK (currency ~ '^[A-Z]{3}$')` in 0022, 0029 (`foreign_currency`), 0031, 0095 and 0097.
- There is no currency enum, and nothing references `currencies(code)` as a foreign key.
- Amounts are unconstrained `numeric`, and the sync RPCs (0107) use `trim_scale`.
- I found no Edge Function that rejects a currency outside a list. The only allowlists are detection-side (above).
- So the server accepts every code the device can now store, and none needed to be kept non-storable.
- Cosmetic only, not changed: `evaluate-budgets` builds its push body with `toFixed(2)`. This was already true for JPY and KWD before this change.

### Consumers of the storage table (all just accept more codes)
These need no logic change:
- `Money`;
- `money_format.currencyDecimalDigits` (BIF, XPF and others now show 0 decimals instead of the default 2);
- `savings_math`;
- planning cutover, invariants, backfill, repair and pull;
- backup preflight and payload repair;
- the settings currency lists;
- `local_read_providers`;
- `country_catalog` (`storableCurrencies` and `defaultCurrencyFor` derive from `kCurrencyScale`; the file is unchanged).

### Tests
- **New:** `app/test/domain/finance/currency_storage_detection_split_test.dart`, 7 tests.
  - The evidence ISO regex source is byte-identical to the pre-split build. It is pinned to the literal `(?<![A-Za-z])(AED|…|ZAR)(?![A-Za-z])`, and the detection keys are pinned to the same 50.
  - Every detection code is storable with the same scale.
  - ALL, TOP, CUP, PEN, CAD and NOK are storable, but are not read as currency evidence in text. SAR still is.
  - The storage table has 155 codes, exactly the seven 3-decimal codes, the 0-decimal spot checks, and excludes funds, metals and test codes.
  - Formatting: BIF and JPY show `1,235`, KWD shows `1,234.500`, CAD shows `1,234.50`.
  - For all 249 countries, the default currency round-trips through the sync wire: `moneyToNumericText`, JSON, then `moneyFromPulledValue`. This includes the server's trailing-zero-trimmed text and the legacy JSON-number shape. Antarctica correctly has no default.
  - 248 accounts and transactions, one per country default, each with the currency's full decimals, are stored. They go through `BackupSnapshotBuilder`, JSON and `RestoreBackupUseCase` into a fresh database, and come back with the exact `Money` and currency.
- **Fail-before proof:** I temporarily set `kCurrencyScale = kDetectionCurrencyScale`. Then:
  - 5 of the new tests failed (storage, format, sync round trip, backup round trip, and the ordinary-words test);
  - the 2 consent count tests failed;
  - the 3 Norway tests failed.
  - The two pin tests passed both before and after, as they should, since they pin an invariant.
  - The file was then restored byte for byte.
- **Changed expectations in other owners' tests:**
  - `test/core/i18n/country_currency_storage_test.dart` (consent):
    - the choice list has 155 entries, not 50;
    - NO, CA, CN and BR now get NOK, CAD, CNY and BRL;
    - the only country without a default is AQ.
  - `test/features/onboarding/country_currency_choice_test.dart` (consent):
    - in onboarding (en and ar) and in Settings, Norway now saves NOK without asking;
    - the "dismiss saves nothing" tests and the Settings "asks" test now use Antarctica.
    - The `currencyChoiceUnsupportedBody` copy is no longer reachable from the bundled 249-country catalog, so no test shows it now. The code path stays as a defensive fallback.
  - `test/features/settings/planning_currency_repair_screen_test.dart`: the currency sheet now lists 155 codes, so the test scrolls to EUR before tapping it. No assertion changed.
  - `test/engine/ai/ai_currency_codes_test.dart` (mine) now compares against `kDetectionCurrencyScale`.

### Runs
- `flutter analyze` on the touched areas: no issues.
- Currency, i18n, onboarding and proof suites: 440/440 passed.
- 38 test files that touch the registry, plus `test/core/backup` and `test/features/coupons`: all passed except one failure that is not mine. `test/architecture/destructive_path_inventory_test.dart` fails on `restore_backup_usecase.dart` (18 > 12 destructive statements); that file is another owner's uncommitted edit, and I did not touch it.
- Deno (`_shared`, `process-ios-sms`, `parse-sms`, `sync-captures`, `-A`): 823 passed, 0 failed, 2 ignored.

## Follow-up 8 — points/miles are not a money flow (mirrors parser follow-up 2)
- `_shared/ai_candidate_validator.ts` now skips a flow phrase followed by points, miles, نقاط or نقطة, but not نقاط البيع. Both `directionOfFlow` and the bare-destination check in `directionOfWording` use this. The regex is identical to `message_meaning.ts`'s; it is copied because `message_meaning.ts` imports the validator and uses it at load time, so importing back would create a cycle. A new parity test (`directionOfFlow === flowOf`, 8 texts) pins the two together. The Dart validator has no copy (`bookedDirection` uses `DirectionSignal.detect`), so it needed no change.
- 4 new shared fixtures (`ai_candidate_cases.json`): 3 correct payments with a "credited points/miles / تمت إضافة نقاط" phrase in the amount's sentence are accepted, and a real money credit is still rejected as `direction_contradiction`. The 3 accept fixtures and the parity test failed before the fix and pass after. Runs: Deno `_shared` + `process-ios-sms` + `parse-sms`: 812 passed, 0 failed. Flutter `test/engine/ai` (it runs the same fixtures): 121 passed. Lint: clean.

## Follow-up 9 — review S (SM-05, SM-07), shared reward rule, `uncertain` kind
- **(1) Shared reward rule.** `_shared/ai_candidate_validator.ts` no longer has its own `POINTS_AFTER` copy. `firstMoneyFlow` now calls the parser's `isRewardFlow` from `_shared/money_text.ts`. The parity test (`directionOfFlow === flowOf`) stays and now covers 10 texts, including "45 points credited" and "إضافة 30 نقطة".
- **(2) SM-05: three-letter words read as currencies in totals.** In `chargedTotal` (Dart `AiCandidateValidator`, which `validated_capture` also uses, and TS), the optional currency before the total figure is now one of the detection currency codes (`currencyCodes` / `CURRENCY_CODES`), not any 3-letter word. «الرصيد الإجمالي» (total balance) is not a charged total. "Total bal", "Total balance SAR" and "Total due" therefore no longer reject a correct amount.
  - 4 new shared fixtures (Total bal, Total due, Total balance SAR, الرصيد الإجمالي) in `ai_candidate_cases.json`, run on both sides. 3 of the 4 failed with the old pattern; Total balance SAR passed there too and is kept as a guard. All 4 pass now. The tip-total fixtures are unchanged and still pass.
  - Not mine: `parse.ts` has the same check (parser-owned).
- **(3) SM-07: redaction merged sentences.** In `_shared/sms_redaction.ts`, a period that ends a sentence (followed by a space or the end of the text) can no longer be part of a name. The «إلى/الى» and "To:" rules now stop at the end of the sentence instead of the end of the line.
  - Initials and titles ("Mr. Ali") keep their period, so the name after them is still masked.
  - Example: "sent to Ali completed. Previous transfer declined." becomes "sent to [NAME]. Previous transfer declined." Before, it was "sent to [NAME] transfer declined.".
  - New test "third-party redaction never merges two sentences" (5 cases): it fails on HEAD's `sms_redaction.ts` and passes now. A guard test for "Mr. Ali" passes before and after.
  - All 61 existing redaction and privacy tests and the shared redaction fixture still pass.
  - Not changed (pre-existing): "To A. Ali" is not masked, because "a" is a stopword; the old pattern did the same.
  - For the privacy owner: the Dart `SmsSanitizer._nameToken` has the same period behaviour. The device parses the raw text, so this does not change device parsing. The shared fixture has no case for it, so the two still agree on every fixture.
- **(4) `uncertain` kind.** Every gate keys on `disposition != record`, and `uncertain` has disposition review on both sides, so no code change was needed. New tests:
  - Server (`process-ios-sms/ai_meaning_gate_test.ts`), AI-primary and legacy: `other_event_status` and `truncated_status` texts with a model "transaction" answer are rejected, never processed.
  - Device (`test/domain/usecases/ai_meaning_gate_test.dart`): the kind is uncertain, `meaningHoldReason` holds it (import paths), no AI request is made, nothing is recorded, and the message is never silent.
  - I could not build a `status_disputed` text by hand; it goes through the same disposition.
  - Changed expectation (caused by the parser's follow-up 3): "Purchase … Cashback SAR 12.00 credited to your card" is now recorded (the cashback is a reward footer). The `multiple_amounts` case now uses two purchases, as the server test does.
- **Runs**
  - Deno, all of `supabase/functions` (`-A`): 1,170 passed, 0 failed, 6 ignored.
  - Parser differential harness (`tools/parser_diff/run.sh 5dae2e2d`): 0 regressions, 0 throws on every path, 0 base not-completed texts now recorded. eB right 1,215 and eN 1,048 (one more each than the parser's pd5); s is unchanged.
  - `flutter analyze` on the touched files: clean.
  - Flutter `test/engine/ai`, `test/domain/capture`, `test/domain/usecases`, `test/features/capture` (`-j 2`): 1,875 passed, 0 failed.
