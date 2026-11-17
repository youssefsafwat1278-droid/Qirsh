# Fix brief — Qirsh Version 1 local remediation

Shared rules for every fix specialist. Read this, then the findings named in your prompt (full evidence is in the audit reports in this directory).

## Where and what

- Work ONLY in `<worktree>/` (branch `release-readiness/v1`, based on `ab5dc10a`). Never `cd` to another checkout.
- Several fix specialists are working in this same tree at the same time. Edit ONLY the paths your prompt assigns to you. If a fix needs a file outside your paths, do not touch it: describe the needed change in your final message.
- Do NOT commit, stash, reset, checkout, push, merge or deploy. Do not run `git add`. The orchestrator reviews and commits. Do not revert or "clean up" changes you did not make.
- Do not call production services. Do not start or stop any local Supabase stack. Do not spawn further agents.

## How to fix

- Follow the repository's `CLAUDE.md`: smallest change that solves the problem; touch only what the fix requires; match existing style; no refactoring, no new features, no speculative configurability.
- Never weaken a security or consent check, delete or loosen an assertion, skip a test, or lower a threshold to make something pass. If an existing test asserts the defective behavior, change it only to assert the corrected behavior and say so explicitly in your report.
- Do not change product scope, consent flows, privacy defaults, or the financial meaning of anything beyond the defect described. If the right fix needs an owner decision, stop on that item and report the options.
- Every substantive defect gets a regression test that fails before the fix and passes after. Say how you confirmed it failed before (e.g. ran it against the unfixed code).
- Use synthetic data only in tests and fixtures. No real bank messages, names, tokens or keys.

## Running checks

- Prefix every Flutter/Dart command with `PUB_CACHE=$HOME/.pub-cache` (the profile's pub cache path is an unmounted volume). Use `flutter test --no-pub <files>`.
- Run only targeted tests for the code you touched plus obviously related suites; the orchestrator runs the full gate afterwards. The machine is shared: do not run the whole Flutter suite.
- `flutter analyze` on the files you touched must be clean. For Deno: `deno test` on the affected function directory and `deno lint`. For admin: its existing test/build scripts.
- If you change `.arb` files, run `flutter gen-l10n` in `app/` (generated files under `app/lib/l10n/` are committed) and keep Arabic and English in step.
- Some tests are "source contract" tests that read non-Dart files as text (Info.plist, privacy manifests, codemagic.yaml, Kotlin/Swift sources). Search `app/test` and `tools`/node tests for references to any file you change and run those.

## Final message (to the orchestrator)

State the model identifier you are running as. Then, per finding: status (FIXED / PARTIAL / NOT FIXED — why), the files changed, what the change does in one or two sentences, the regression test(s) added and proof they failed before and pass after, the exact commands you ran with their results, anything you could not verify, and any compatibility implication (existing stored data, older installed clients, backend/client ordering). Keep it under 500 words.
