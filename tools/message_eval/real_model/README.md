# Real-model evaluation (sample A)

**EVALUATION ONLY.** The samples and per-message results are not for the
parser, redaction or AI implementers (see `LABELS.md`).

`run_real.sh <commit>` evaluates a committed commit in a scratch worktree,
never the working tree. Per message it runs:

| Step | Code that runs | What is not the product's |
|---|---|---|
| Device redaction | `BackendCaptureClient.sanitize`, extracted verbatim from the commit's `BankMessageShortcuts.swift` and compiled with `swiftc` (`swift_sanitize.sh`) | the command-line wrapper |
| Server | the commit's `handleProcessIosSms` (`process-ios-sms/index.ts`) with the App Intent's request body for consented AI (`analysis_mode=ai_primary_v1`, `backgroundAnalysis`): server redaction, pre-filter, prompt, system instruction, `geminiRequestBody`, `runPrimaryAi` (≤ 3 attempts, repair turns, 429/5xx policy), structured-output parsing, `validateAiCandidate`, `checkPrimaryAmount`, meaning gate, `capture_finalize` | the database: the commit's own in-memory model of the `capture_*` RPCs (`capture_rpc_fake.ts`); `fetch` is wrapped (host check, cap, recording) |
| Model | `MESSAGE_EVAL_MODEL_MODE=real`: the model the code configures (no `GEMINI_SMS_MODEL` override), at the code's URL. `stub`: a scripted answer, no network | — |
| Device | the commit's `CaptureImportService` on an encrypted Drift database (`real_model_eval_test.dart`), once with Cloud/AI off (`local_only`) and once importing the row the server stored (`cloud_primary_real`) | the native queue, the server transport and the session are fakes |
| Report | `report.py`: three layers per message, graded against the labels; the saved outcome is graded by `../score.py` | — |

## Request cap and key

- One HTTP request = one count, including retries, 429s and failures.
- The count is a file: `$MESSAGE_EVAL_SCRATCH/gemini_request_counter.json`
  for real runs. It is read and written before every request. It is never
  reset by the scripts. A request that would pass the cap is refused locally,
  and a message is started only if its worst case (3 requests) still fits.
- The cap is `min(MESSAGE_EVAL_MAX_REQUESTS, 300)`.
- The key is read by the Deno process from `MESSAGE_EVAL_KEY_FILE` (an env
  file with `GEMINI_API_KEY=`). It is never on a command line, never printed,
  and replaced by `[KEY]` in anything written. Request bodies are saved
  without headers (the key travels in a header).
- Only `https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`
  is reachable (`--allow-net` plus a URL check). `MESSAGE_EVAL_MODEL_MODE=list_models`
  makes one counted `models.list` call, for the case where the API rejects the
  configured model. The run stops on a rejected model or key; it never
  substitutes another model.

## Output (`$MESSAGE_EVAL_SCRATCH/<name>/`, scratch only)

- `server_real.json`: per message, every request (status, latency, tokens,
  raw answer, the code's verdict on it) and the stored row.
- `requests/<id>_p<pass>_a<attempt>.json`: the exact request bodies.
- `device.json`: saved rows and Smart Inbox items per path.
- `report.md`, `report.json`, `per_message.json`.

## Limits

- Synthetic, single-author messages: not real traffic, not real-world accuracy.
- The database is the commit's in-memory fake: consent, lease and budget RPCs
  answer "allowed"; duplicate detection across messages is not exercised.
- A fresh install: bundled bank profiles, no accounts, no learned rules.
- One run at temperature 0: no measure of run-to-run variation.
