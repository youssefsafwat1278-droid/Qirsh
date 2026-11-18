# Message-understanding acceptance criteria (held-out evaluation)

Written 2026-11-17 by the evaluation specialist (`eval`) **before any parser,
validator or model was run on the held-out set** (no baseline, candidate or
final run existed when this file was written).

**These are engineering criteria, not owner-approved risk tolerances.** The
owner has approved no error rate. A PASS here means "meets the bar an engineer
would set before release on this synthetic set"; it is not real-world
accuracy, it is not an owner acceptance of the residual errors, and it does not
replace device verification with real, permissioned bank messages.

## What is measured

- **Set:** `tools/message_eval/heldout/messages.jsonl` (built by
  `build_heldout.py`), synthetic, one author, labelled from the text alone.
  Rows marked `policy_dependent` are reported but excluded from every
  criterion below.
- **Unit:** one message, one fresh in-memory database, real application code
  (`CaptureImportService` → `AddTransactionUseCase` / `CaptureSyncService` on
  Drift; the version's own `process-ios-sms/parse.ts` under Deno). What counts
  is the **booked outcome**: confirmed rows (the only rows any total reads),
  pending rows / Smart Inbox items (review), or nothing.
- **Paths** (all iOS, the V1 platform):
  - `local_only` — Cloud/AI off: the device's deterministic flow.
  - `cloud_det` — Cloud on, AI off: server deterministic parse, device import
    with its own defences (the "effective" path).
  - `cloud_ai_oracle` / `cloud_primary_oracle` — Cloud + AI on (hybrid and
    AI-primary server modes), with a scripted model that returns the ground
    truth. This is an **upper bound with a perfect model**: it measures what
    the validators and the import do to correct AI answers. It is not a model
    evaluation.
  - `cloud_*_real` — the same with the configured Gemini model, only when an
    authorized key is supplied (see `README.md`).
  - Amendment before the first full run (paths only, no criterion changed):
    the hybrid mode (`cloud_ai_oracle`, `cloud_ai_real`) is not run through
    the device import, because no iOS client sends it — whenever AI is
    allowed both the App Intent (`BankMessageShortcuts.swift`, `analysis_mode
    = ai_primary_v1`) and the Dart client (`capture_backend_client.dart:189`)
    request AI-primary, at `ab5dc10a` and at `5dae2e2d`. Its server reading is
    still reported.

## Criteria (each applies per path; counts exclude `policy_dependent` rows)

| ID | Criterion | Bar | Why this bar |
|---|---|---|---|
| A1 | Non-transactions (balance/limit notices, bill due/reminders, expected salary, marketing, OTP, other non-financial text) booked as confirmed money | **0** | Money that never moved changes totals by the full figure (often a balance or limit, i.e. large). Owner 4.6: "do not create financial movement". A review card is not counted here. |
| A2 | Declined / failed / pending / scheduled / pending-refund messages booked as confirmed money | **0** | Owner 4.6: failed and pending are excluded from totals. This was V1-001's core defect. |
| A3 | Ambiguous messages booked as confirmed money | **0** | Owner 4.3/4.6: ambiguous → review. |
| A4 | Completed messages booked with the wrong amount, currency or direction (net effect on totals differs from the label and from every listed alternative) | **≤ 1 %** of completed (save) messages on the path, and **0** on instruction-bearing messages | Each such row is a silent wrong total. 1 % is the largest rate at which a user with ~100 bank messages a month meets about one silent error a month; above that the totals are not trustworthy. Injection must never steer money. |
| A5 | Duplicate financial effect: a completed message booked twice (in one pass, or when the same capture is delivered again) | **0** | Double counting is a wrong total; redelivery is routine on iOS (App Intent retry + import). |
| A6 | Completed or ambiguous messages lost silently (no row, no review card) | **0** on every path | Owner 4.6: never silently drop financial messages. |
| A7 | Completed messages sent to review instead of saved | **≤ 15 %** on `local_only` and `cloud_det`; **≤ 5 %** on the oracle AI paths; **≤ 10 %** on a real-model path | Review is safe but leaves totals understated until the user acts. 15 % is about R's measured probe-set cost at `50957c06`, i.e. "no worse than the reviewed candidate"; a perfect model should rarely be overruled. |
| A8 | Correct AI answers rejected: (a) server `validateAiCandidate` and device `AiCandidateValidator` on the ground-truth candidate of every completed message; (b) completed messages not saved on `cloud_primary_oracle` | **≤ 5 %** each | NR-02/RR-03: a validator that rejects correct answers turns AI into review volume. Validators may still be stricter than the label on genuinely unusual text (OOD, malformed). |

Reported without a bar (information): non-transactions sent to review (noise),
declined/pending kept as review vs. dropped, wrong type within the right
direction (refund vs income), server-only reading, policy-dependent rows,
per-class and per-tag breakdowns, real-model latency / requests / estimated
cost.

## How a verdict is formed

- A path PASSES when every criterion with a bar holds on it.
- The release-relevant paths are `local_only`, `cloud_det` and, when a key is
  authorized, `cloud_primary_real` / `cloud_ai_real`. The oracle paths gate the
  validators and import (A8) only.
- A criterion is never relaxed after a run. If a label is found wrong after a
  run, the fix is recorded in the report with the message id, and both the
  before and after numbers are re-run on the corrected label.
