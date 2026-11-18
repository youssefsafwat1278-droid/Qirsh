# Held-out message-understanding evaluation

Independent measurement of how Qirsh understands bank messages, owned by the
evaluation specialist. **Tuners (parser / AI work) must not read `heldout/`
or per-message results**; they get aggregate numbers and failure classes only.

- `heldout/messages.jsonl` — the labelled set (built by `heldout/build_heldout.py`).
- `ACCEPTANCE.md` — criteria, written before any run.
- `run.sh <commit>...` — one command per commit (scratch worktree, server, device, score).
- `expand.py` — fills date placeholders relative to the run time.
- `deno/server_eval.ts` — the commit's own `process-ios-sms/parse.ts` + `ai_candidate_validator.ts`.
- `dart/message_eval_test.dart` — the commit's own iOS import (`CaptureImportService` on Drift).
- `score.py` — grades booked outcomes; `score.py compare a.json b.json` for side-by-side.

## Run

```bash
# from anywhere in the repo; needs deno, flutter, python3, git
MESSAGE_EVAL_SCRATCH=/path/to/scratch tools/message_eval/run.sh ab5dc10a 5dae2e2d <final-sha>
```

Each commit takes about 10–20 minutes on this machine (one `flutter test`
compile plus ~750 messages × 4 paths × 2 deliveries on in-memory databases).
Results land in `$MESSAGE_EVAL_SCRATCH/<sha8>/metrics.{md,json}`;
`metrics.private.json` holds per-message grades and stays with the evaluator.

## Real model (bounded, opt-in)

The configured AI path is `process-ios-sms` → Gemini. Model defaults read from
the code: `GEMINI_SMS_MODEL` unset → `gemini-3.8-flash`
(`process-ios-sms/parse.ts`, `parse-sms/index.ts`); AI-primary makes up to
`MAX_AI_ATTEMPTS = 3` requests per message (`_shared/ai_primary.ts`), hybrid 1.

```bash
MESSAGE_EVAL_GEMINI_KEY=<authorized TEST key>   # never a production secret
MESSAGE_EVAL_MAX_REQUESTS=300                   # hard cap; default 0 = no real call
MESSAGE_EVAL_REAL_MODES=primary_real            # or primary_real,hybrid_real
MESSAGE_EVAL_REAL_SAMPLE=0                      # 0 = as many messages as the cap allows;
                                                # N = class-stratified sample of N
GEMINI_SMS_MODEL=gemini-3.8-flash               # optional, to compare models
tools/message_eval/run.sh <commit>
```

The cap is enforced in the fetch wrapper: a message is started only if its
worst case (3 requests for AI-primary) still fits under the cap, and any
request beyond it is refused locally. Only `generativelanguage.googleapis.com`
is reachable (`--allow-net`), and the text sent is exactly what `parseSms`
sends (the server's own redaction). The key is read from the environment and
never written or printed. Output: request count, prompt/output/thinking tokens,
latency per request, errors.

Cost estimate = prompt_tokens × input price + (output + thinking tokens) ×
output price, using the provider's current published price for the model
(not hard-coded here: check it on the day). Rough size: the AI-primary prompt
is ~450 tokens + the message; 750 messages × ≤3 attempts ≈ 2,250 requests
worst case, typically ~800.

## What it is not

Synthetic, single-author messages; not real traffic and not real-world
accuracy. The `*_oracle` paths use a scripted model that returns the label:
they measure validators and import, not a model. The device runs with the
bundled bank profiles of a fresh install (no synced remote catalog), and the
native Swift sanitizer is not applied before the server (the server re-applies
its own redaction floor).
