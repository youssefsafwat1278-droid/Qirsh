# Real-model samples: label record

**EVALUATION ONLY.** Do not give these files to the parser, redaction or AI implementers. Do not use them as examples, fixtures or tests for fixes.

Both samples were written and labelled from the text alone by the evaluation specialist on 2026-11-18. That was before any run of them on any commit, and before any real-model request. They are fresh texts: they are not copies or edits of `heldout/messages.jsonl` or `dev_siblings.jsonl`.

Similarity was checked with `difflib.SequenceMatcher` against every held-out and development text:
- sample A: at most 0.80;
- sample B: at most 0.75;
- A against B: at most 0.79.

| File | Rows | SHA-256 | Labels fixed (UTC) | Repo HEAD then |
|---|---|---|---|---|
| `sample_a.jsonl` | 100 | `dbc78bbcd1eca64612c293c3b79b2e31803ab6cc763599448e6d0a1b83c11451` | 2026-11-18T09:34:36Z | `7bba5ffa` |
| `sample_b.jsonl` | 100 | `80e556e5290ae5c786cfa9803910790c5e7452bb40ab29fa234652c6df3768e9` | 2026-11-18T09:34:36Z | `7bba5ffa` |

Check with `shasum -a 256 tools/message_eval/real_model/sample_*.jsonl`. A label change after this point must be listed below with its reason and the new hash. A changed hash with no entry means the labels can no longer be trusted.

## How the samples are used

- **Sample A** is run first: real model, normal AI-enabled path, compared with local-only.
- **Sample B** is the confirmation sample. It stays unrun until a fix made after the A run needs confirming, and then it is run once at the fixed commit.
- Failures on A are reported to the implementers only as aggregate classes, never as message texts.

## Schema

Same schema as the held-out set (see `../heldout/build_heldout.py`):
- `cls`, `disposition`, `acceptable`, `events` (`kind`, `amount`, `currency`, `amount_text`, optional `original`), `policy_dependent`.
- `privacy_tokens`: third-party names, phone numbers, IBANs, account numbers, e-mail addresses and OTP codes in the text. None of them may appear in any request body sent to the model.

The rows are synthetic: bank sender IDs with invented merchants, people, numbers and IBANs.

## Composition

| | Sample A | Sample B |
|---|---|---|
| Languages | en 52 / ar 48 | en 49 / ar 51 |
| Dispositions (each sample) | save 60, ignore 19, exclude 18, review 3 | same |

The classes in each sample:
- completed purchases, including mixed footers and balance traps;
- foreign-currency purchases;
- totals with tip / VAT / service parts;
- withdrawals and fees;
- transfers out and in, salary and other income;
- refunds;
- declined, pending and scheduled operations, and pending refunds;
- reminders (amount due);
- balance and limit notices;
- several movements in one message;
- OTPs, adverts and other notices;
- ambiguous messages;
- own-account moves.

Each sample has 3 policy-dependent rows (cash deposit, card repayment, wallet top-up), excluded from pass/fail.

Regions:
- Sample A: SA 49, EG 37, Gulf 14.
- Sample B: a similar split.

## Label changes after the record

None.
