# Round 4 — real Gemini evaluation on sample A (`gemini-eval`)

- Evaluator: `gemini-eval`, model `claude-fable-5-2` (as stated by the session's system context).
- Date: 2026-11-18. Commit under test: `a157e68e` (the reviewed release candidate), in a detached scratch worktree. The working tree was never evaluated. The fixes in progress are not in this commit.
- Sample: `tools/message_eval/real_model/sample_a.jsonl`, 100 synthetic messages (en 52 / ar 48). Labels were committed in `41b39127` before any run. The SHA-256 is unchanged (`dbc78bbc…1451`). Sample B was not opened or run; its hash is unchanged.
- Nothing was tuned. No label was edited.
- This is one run on synthetic, single-author messages. It is not real-world accuracy.

## Headline

| On the same 97 counted messages (3 policy-dependent rows excluded) | Local only | Real Gemini path |
|---|---|---|
| Wrong financial entries (in totals) | **0** | **1** |
| Silent losses | **0** | **0** |
| Unnecessary reviews (of 50 completed messages that must be saved) | **25** (50 %) | **2** (4 %) |
| Completed messages saved correctly (of 50) | 25 | 48 |
| Declined, pending and pending-refund messages in totals (of 18) | 0 | 0 |
| Reminders, balance notices, adverts, OTPs, other notices in totals (of 19) | 0 | 0 |
| Messages with several movements or own-account moves (7; save or review both accepted) | 7 in review | 7 in review |
| Ambiguous messages in totals (of 3) | 0 | 1 |
| Non-transactions kept as review cards (information) | 35 | 35 |

- Model called: **`gemini-3.8-flash`** (the code default in `process-ios-sms/parse.ts`; `GEMINI_SMS_MODEL` unset). The API accepted it and returned `modelVersion: gemini-3.8-flash`. No substitution, no `models.list` call.
- Requests: **88 in total** against the cap of 300 (5 smoke + 83 full run). 85 returned HTTP 200. 3 timed out at the code's 12 s limit and were retried by the code's own policy. No 429, no other HTTP error.
- Cost: **$0.133** for all 88 requests ($0.126 for the 100-message run, about $0.0013 per message) at the price published today.

## What was run

| Layer | Code |
|---|---|
| Device redaction | `BackendCaptureClient.sanitize`, extracted verbatim from the commit's `BankMessageShortcuts.swift` and compiled with `swiftc` |
| Server | the commit's `handleProcessIosSms` with the App Intent's body for consented AI (`analysis_mode=ai_primary_v1`, `backgroundAnalysis`): redaction, pre-filter, prompt, system instruction, request builder, `runPrimaryAi` (≤ 3 attempts), output parsing, validators, meaning gate, `capture_finalize` |
| Model | the real `generateContent` call at the code's URL — the only external part |
| Device | the commit's `CaptureImportService` on an encrypted Drift database: once with Cloud/AI off, once importing the row the server stored |

Not the product's: the database behind the handler is the commit's own in-memory model of the `capture_*` RPCs (`capture_rpc_fake.ts`), and `fetch` is wrapped for the host check, the cap and recording. The device starts as a fresh install (no accounts, no learned rules).

Order followed: stub dry run, 5-message smoke run, full run.
- Dry run (no provider call): a cap of 40 stopped at 38 requests with 69 messages not started; a second invocation on the same counter sent 0; with the worst-case check off, the wrapper refused 9 requests at 40/40; a cap of 5000 was clamped to 300. The full stub run produced the three layers for 100 messages, and the harness's reading of each validator verdict matched the reason the code put in its repair prompt.
- Smoke run: A001, A015, A022, A037, A075 — 5 requests, all HTTP 200, all correct.

## Gemini's interpretation (layer 1)

77 messages reached the model. 23 did not: the server's own pre-filter held them (10 declined, 6 pending, 4 reminders, 1 OTP, 1 advert, 1 completed refund).

| Gemini's first answer, counted messages | Count |
|---|---|
| Right | 72 |
| Wrong: answered a completed transaction for an ambiguous message | 2 (A094, A095) |
| Not asked | 23 |

- Every completed message it saw (49 strict, 7 flexible) was read correctly: amount, currency and direction. This includes the 3 foreign-currency purchases, 5 totals with tip/VAT/service parts, 6 mixed messages and the Gulf 3-decimal amounts.
- All 5 several-movement messages were answered `multiple_transactions`, both own-account moves `own_account_transfer`, both pending refunds `pending_or_scheduled`, all 6 balance notices `balance_or_limit_notice`.
- One first answer had no `type` (A032, a withdrawal); the validator asked again and the second answer was accepted.

## Validator and gate decisions (layer 2)

| Server decision (100 messages) | Count |
|---|---|
| Processed (validators and meaning gate accepted) | 49 |
| Model said "not a completed transaction": kept for review | 25 |
| Never sent to the model (pre-filter) | 23 |
| Validator accepted, meaning gate refused | 2 (A036; A096 policy-dependent) |
| Validator rejected all 3 answers | 1 (A095) |

The device imported all 49 processed rows. Its own gate held none of them.

| Gemini vs the code vs the outcome (97 counted) | Count |
|---|---|
| Gemini right, outcome right | 71 |
| Gemini right, **overruled** into an unnecessary review | 1 (A036) |
| Gemini wrong, **caught** (no entry in totals) | 1 (A095) |
| Gemini wrong, **let through** into totals | 1 (A094) |
| Not asked, outcome right | 22 |
| Not asked, unnecessary review | 1 (A050) |

## What Qirsh saved (layer 3): the failures

**Wrong financial entry, real path (1)**
- **A094** (ambiguous, ar; label: review) — «عملية بمبلغ 500 جنيه على بطاقتك 6612 - للاستفسار اتصل بنا»
  - Gemini: `transaction / completed`, 500 EGP, debit, payment — wrong: the text does not say what happened.
  - Server: validator and meaning gate accepted. Device: imported.
  - Saved: confirmed payment 500 EGP, in totals. Local only: review.

**Unnecessary reviews, real path (2)**
- **A036** (fee, en) — "AED 26.25 late payment fee charged to your credit card ending 3391."
  - Gemini: completed payment 26.25 AED, debit — right.
  - Server: validator accepted; the meaning gate refused it as `card_repayment`. Saved: review. Local only: review, same reason.
- **A050** (refund, ar) — «تم استرداد مبلغ 1,050 جنيه لعملية ملغاة لدى متجر الأفق للإلكترونيات إلى حسابكم»
  - Gemini: never asked. The server pre-filter read "cancelled operation" as not completed (`declined_or_failed`). Saved: review. Local only: review, same reason.

**Gemini wrong, caught (1)**
- **A095** (ambiguous, en) — "SAR 1,250.00 transaction on account **6630. If this was not you, call 8001241222."
  - Gemini: `transaction / completed`, direction and type `unknown`.
  - Validator: `direction_unresolved`, then `type_required` twice (3 requests). Saved: review — correct.

**Unnecessary reviews, local only (25)** — the real path saved 23 of these correctly; the other two are A036 and A050 above.

| Class | Messages | Device reading |
|---|---|---|
| Purchases (7) | A002, A005, A007, A008, A009, A022, A024 | completed movement, not resolved (A009: no event amount) |
| Mixed with footer (2) | A012, A013 | completed, not resolved |
| Foreign currency (2) | A015, A028 | completed, not resolved |
| Totals with parts (4) | A016, A029 (`tip_component`); A017, A018 | held |
| Fees (2) | A034; A036 (`card_repayment`) | held |
| Transfers (4) | A039, A040, A041, A044 | completed, not resolved |
| Income (2) | A045, A047 | not resolved |
| Refunds (2) | A049; A050 (`declined_or_failed`) | held |

The full per-message record, with the three layers and the message text of each of these, is in the scratch `report.md` and `per_message.json`.

## By class (counted messages)

| Class | n | Local: ok / wrong / lost / unnecessary review | Real: ok / wrong / lost / unnecessary review | Gemini: right / wrong / not asked |
|---|---|---|---|---|
| purchase | 16 | 9 / 0 / 0 / 7 | 16 / 0 / 0 / 0 | 16 / 0 / 0 |
| mixed | 6 | 4 / 0 / 0 / 2 | 6 / 0 / 0 / 0 | 6 / 0 / 0 |
| fx | 3 | 1 / 0 / 0 / 2 | 3 / 0 / 0 / 0 | 3 / 0 / 0 |
| total_parts (multiple amounts, one event) | 5 | 1 / 0 / 0 / 4 | 5 / 0 / 0 / 0 | 5 / 0 / 0 |
| withdrawal | 3 | 3 / 0 / 0 / 0 | 3 / 0 / 0 / 0 | 3 / 0 / 0 |
| fee | 3 | 1 / 0 / 0 / 2 | 2 / 0 / 0 / 1 | 3 / 0 / 0 |
| transfer | 8 | 4 / 0 / 0 / 4 | 8 / 0 / 0 / 0 | 8 / 0 / 0 |
| income | 3 | 1 / 0 / 0 / 2 | 3 / 0 / 0 / 0 | 3 / 0 / 0 |
| refund | 3 | 1 / 0 / 0 / 2 | 2 / 0 / 0 / 1 | 2 / 0 / 1 |
| declined | 10 | 10 / 0 / 0 / 0 | 10 / 0 / 0 / 0 | 0 / 0 / 10 |
| pending | 6 | 6 / 0 / 0 / 0 | 6 / 0 / 0 / 0 | 0 / 0 / 6 |
| refund_pending | 2 | 2 / 0 / 0 / 0 | 2 / 0 / 0 / 0 | 2 / 0 / 0 |
| reminder | 6 | 6 / 0 / 0 / 0 | 6 / 0 / 0 / 0 | 2 / 0 / 4 |
| balance | 6 | 6 / 0 / 0 / 0 | 6 / 0 / 0 / 0 | 6 / 0 / 0 |
| multi (several movements) | 5 | 5 / 0 / 0 / 0 | 5 / 0 / 0 / 0 | 5 / 0 / 0 |
| own_account | 2 | 2 / 0 / 0 / 0 | 2 / 0 / 0 / 0 | 2 / 0 / 0 |
| otp | 3 | 3 / 0 / 0 / 0 | 3 / 0 / 0 / 0 | 2 / 0 / 1 |
| marketing | 3 | 3 / 0 / 0 / 0 | 3 / 0 / 0 / 0 | 2 / 0 / 1 |
| other | 1 | 1 / 0 / 0 / 0 | 1 / 0 / 0 / 0 | 1 / 0 / 0 |
| ambiguous | 3 | 3 / 0 / 0 / 0 | 2 / 1 / 0 / 0 | 1 / 2 / 0 |

- Declined and pending operations were never judged by Gemini on this commit: the server pre-filter holds them first. This run therefore says nothing about how the model reads them.
- Policy-dependent rows (A096 cash deposit, A097 card repayment, A098 wallet top-up): review on both paths; Gemini answered each as a completed transaction.
- Transfers to and from people are saved as `payment` / `income` rows, so they enter the spending and income totals with the right amount and direction.

## Measurements

| | Smoke (5 messages) | Full run (100 messages) | Total |
|---|---|---|---|
| Requests, retries included | 5 | 83 | **88** of 300 |
| HTTP 200 | 5 | 80 | 85 |
| Timeouts at 12 s (no HTTP status) | 0 | 3 (A010, A041, A043) | 3 |
| HTTP 4xx / 5xx | 0 | 0 | 0 |
| Messages sent to the model | 5 | 77 | — |
| Messages needing more than one request | 0 | 5 | — |
| Input tokens | 4,452 | 71,009 | 75,461 |
| Output tokens | 1,012 | 13,085 | 14,097 |
| Thinking tokens | 0 | 6,320 | 6,320 |

- Latency per request, full run: **p50 3.7 s, p95 11.4 s, max 12.0 s** (the timeout). Per message, retries included: p50 3.7 s, p95 11.8 s, max 22.4 s.
- Price: `gemini-3.8-flash`, paid tier, standard: **$0.75 per 1M input tokens, $3.75 per 1M output tokens including thinking**, "through December 31, 2026"; $1.50 / $7.50 from 2027-01-01. Source: https://ai.google.dev/gemini-api/docs/pricing (redirects to https://aistudio.google.com/docs/pricing), read 2026-11-18.
- Cost: input 75,461 × $0.75/1M = $0.057; output + thinking 20,417 × $3.75/1M = $0.077; **total $0.133**. The full run alone is $0.126, or $0.0013 per message. At the 2027 price the same run costs about $0.27.
- The 3 timed-out requests returned no token counts. If the provider bills them, they are not in these figures.
- I could not tell from the responses whether the key is on the free or the paid tier. The pricing page says free-tier content is used to improve the provider's products.

## Privacy check

- 83 request bodies of the full run were captured (scratch only). Every one carries `store: false`.
- 23 labelled third-party tokens in 11 messages: names, phone numbers, IBANs, an account number, an e-mail address, OTP codes.
- **No person name, phone number, IBAN, account number or e-mail address reached the model.** They were replaced by `[NAME]`, `[REDACTED]`, `[PHONE]`, `[IBAN]`, `[ACCOUNT]`, `[EMAIL]` on the device, before upload. A generic scan of every request (digit runs of 9 or more, IBAN shapes, e-mail shapes) found nothing.
- **Two 6-digit one-time codes reached the model** (A086, A088), in `contents[0].parts[0].text`, inside the SMS text after `SMS:`. Shapes: "…is 999999. Do not share it." and "Use 999999 to [NAME] your … transfer…". The Swift redaction left them in the upload, the server redaction left them too, and the server pre-filter did not hold these two messages. Gemini answered `otp_or_security` and both ended as review cards.
- A third code (A087, Arabic) also left the device in the upload but was held by the server pre-filter and never sent to the model.
- In A088 the word "confirm" was replaced by `[NAME]`: a redaction false positive, harmless here.

## Labels

No label was changed. One label is arguable; both scorings are given.
- **A094** is labelled ambiguous (review). The text says only "an operation of 500 EGP on your card". If a reader accepts that as a completed purchase, the real path has **0** wrong entries and local-only has 26 unnecessary reviews of 51. I keep the recorded label: the message names no merchant and no verb, and the device's own local path also declined to save it.

## Limits

- 100 synthetic messages, one author, one run at temperature 0. A zero here is "none seen in 100", not a rate.
- Consent, lease, budget and duplicate checks ran against the in-memory fake, which answers "allowed".
- The run used the device's Swift redaction compiled on macOS, not on a phone.
- Sample A is now seen and must not be reused as a fresh sample. Sample B remains unopened for confirming a fix.

## Reproduce

```bash
MESSAGE_EVAL_SCRATCH=<scratch dir> MESSAGE_EVAL_MODEL_MODE=real \
MESSAGE_EVAL_KEY_FILE=<env file with GEMINI_API_KEY> \
  tools/message_eval/real_model/run_real.sh a157e68e
# dry run without a provider call: MESSAGE_EVAL_MODEL_MODE=stub
# priced report: python3 tools/message_eval/real_model/report.py <scratch>/real-a157e68e \
#   --label a157e68e --price-in 0.75 --price-out 3.75
```

A new real run needs its own authorization: the counter in the scratch directory stands at 88 of 300.
