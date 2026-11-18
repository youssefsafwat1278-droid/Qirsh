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

Use `real_model/run_real.sh` (see `real_model/README.md`). It runs sample A
through local-only processing and through the normal AI-enabled path with the
configured Gemini model, and records three layers per message: the model's
answer, the validator's/gate's decision, and what was saved.

```bash
MESSAGE_EVAL_SCRATCH=<scratch> MESSAGE_EVAL_MODEL_MODE=stub \
  tools/message_eval/real_model/run_real.sh <commit>          # dry run, no provider call
MESSAGE_EVAL_SCRATCH=<scratch> MESSAGE_EVAL_MODEL_MODE=real \
  MESSAGE_EVAL_KEY_FILE=<env file with GEMINI_API_KEY> \
  tools/message_eval/real_model/run_real.sh <commit>          # hard cap: 300 requests, persistent
```

The older opt-in mode of `deno/server_eval.ts` (`MESSAGE_EVAL_GEMINI_KEY`,
`MESSAGE_EVAL_MAX_REQUESTS`, `MESSAGE_EVAL_REAL_SAMPLE`) still exists and was
never run with a real key. Checked on 2026-11-18, it is weaker than
`run_real.sh` and should not be used for a real-model report:
- it calls `parseSms` and re-creates the handler's status rule in the harness
  (`stored()`), instead of running `handleProcessIosSms`;
- the key comes from the environment of the command, and the request count
  lives in memory only (a second invocation starts again from zero);
- it keeps totals only: no request body, no raw answer, no per-answer verdict.

## Development siblings (not held-out)

`dev_siblings.jsonl` is DEVELOPMENT data for the parser and AI tuners: fresh
hand-written texts in the same schema (`"set": "dev"`, ids `DEV…`, a `family`
per failing class), written separately from the held-out set. Tuners may read
and test against it; its numbers are never reported as held-out numbers.

```bash
MESSAGE_EVAL_SET=$PWD/tools/message_eval/dev_siblings.jsonl \
  MESSAGE_EVAL_OUT=<scratch>/dev-<sha> tools/message_eval/run.sh <sha>
```

## What it is not

Synthetic, single-author messages; not real traffic and not real-world
accuracy. The `*_oracle` paths use a scripted model that returns the label:
they measure validators and import, not a model. The device runs with the
bundled bank profiles of a fresh install (no synced remote catalog), and the
native Swift sanitizer is not applied before the server (the server re-applies
its own redaction floor).
