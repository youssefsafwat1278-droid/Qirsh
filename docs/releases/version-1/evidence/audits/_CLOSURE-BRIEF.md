# Closure brief — Qirsh Version 1, round 3

Shared rules for every specialist in the closure round. Read, in this order:

1. This file.
2. `docs/releases/version-1/OWNER-BRIEF-ROUND3.md` — the owner's instruction, verbatim. **Section 3 is the list of approved product decisions; sections 4 and 5 are the message-understanding requirements.** They are decided. Do not re-ask them and do not substitute your own preference.
3. The rows of `docs/releases/version-1/ISSUES.md` and `DECISIONS-NEEDED.md` named in your prompt, and the audit or review reports they cite in this directory.
4. The repository `CLAUDE.md` (smallest change, surgical edits, match existing style, verifiable goals).

This is an implementation task, not an audit. Do not restart audits. Deliver working, tested code.

## Where and what

- Work ONLY in `/Users/luciq/Documents/Money/.claude/worktrees/v1-readiness` (branch `release-readiness/v1`, HEAD `b125f7af` at the start of the round; candidate code so far `5dae2e2d`). Never `cd` to another checkout. The main checkout holds unrelated user work.
- Several specialists work in this same tree at the same time. Edit ONLY the paths your prompt assigns. If the work needs a file outside your paths, do not touch it: describe the exact change needed in your report, and continue.
- Do NOT commit, stash, reset, checkout, push, merge or deploy. Do not run `git add`. The orchestrator commits. Do not revert or tidy changes you did not make — other people's uncommitted edits are in the tree.
- Production is read-only and only for the specialist whose prompt says so. Nobody mutates production: no deploy, flag change, migration, grant, data change, account creation.
- Only the specialist whose prompt says so may start or stop a local Supabase stack. Do not touch the Docker stacks named `frasaaaaa` or `qirsh_proof` — they belong to the owner.
- Do not spawn further agents.
- No real bank messages, names, credentials, tokens or personal data in code, tests, fixtures or reports. Synthetic data only. Never print secret values.
- Do not spend money or create accounts or paid services.

## Shared files — the localisation rule

`app/lib/l10n/*.arb` and the generated `app/lib/l10n/*.dart` are shared by everyone.

- Add or change only the keys your own work needs. Never reorder, reformat or delete other keys.
- Use the Edit tool with a small, unique anchor; re-read the surrounding lines immediately before each edit (another specialist may have just changed the file). Never rewrite the whole file.
- Keep Arabic and English in step. Arabic copy is Modern Standard Arabic matching the existing strings; Western digits.
- After editing, run `PUB_CACHE=$HOME/.pub-cache flutter gen-l10n` in `app/`. Generated files may contain other specialists' keys — that is expected.

## How to work

- Never weaken a security or consent check, delete or loosen an assertion, skip a test, cap accessibility, or lower a threshold to make something pass. If an existing test asserts behaviour the owner has now changed, update it to the decided behaviour and list it in your report. A test that pins a known defect must be labelled as characterization, not acceptance.
- Every substantive change gets a test that fails before and passes after. Say how you confirmed the "before".
- Preserve existing users: stored data, consent choices, language, sign-in. Migrations of device data must keep financial meaning and user choices. No bulk rewrite of historical transactions (decision 3.15).
- Android code stays compiling in shared Dart; do not delete it; do not spend effort on Android-only behaviour.
- No new features beyond the decisions, no redesign, no broad refactor.
- If a decision cannot be implemented as written because of a concrete, verified platform or legal constraint, implement the closest compliant behaviour, and state the specific conflict with its source in your report.
- Routine implementation choices are yours. Do not stop to ask.

## Running checks

- Prefix every Flutter/Dart command with `PUB_CACHE=$HOME/.pub-cache`. Use `flutter test --no-pub -j 2 <files>` — the machine is shared with seven other specialists; never run the whole Flutter suite (the orchestrator runs the full gate at the end). A timeout under load is not a result: re-run that file alone.
- `flutter analyze` on the files you touched must be clean. Deno: `deno test` on the affected directory and `deno lint`; if `supabase/functions/deno.lock` changes, leave it and say so. Admin: its own scripts.
- Source-contract tests read non-Dart files as text (Info.plist, privacy manifests, `codemagic.yaml`, Swift/Kotlin, `.arb`). Search `app/test`, `tools` and `supabase/functions` for references to every file you change and run those tests.
- Disk is small (about 30 GB free). Remove build output you create (`app/build`, DerivedData you made, scratch worktrees). Check `df -h /` before any build or simulator run and stop if under 12 GB.
- Temporary files go in `/private/tmp/claude-501/-Users-luciq--claude-spares-spare-yEUVj2/1b6aaa41-9527-44a7-aa2c-8ab180862078/scratchpad/<your-name>/`.

## Evidence language

A simulator is not a device. A local gate is not CI. A contract test is not a signed build. A validator run without a model is not an AI evaluation. Synthetic messages are not real-world accuracy. Code reading is `NOT TESTED` for any runtime claim.

## Report

Write your report to `docs/releases/version-1/evidence/closure/<your-name>.md` (create the directory if needed; this file is yours) and return a summary of it (under 500 words) as your final message. The report states:

- The model identifier you are running as, and how you know it.
- Per work item: status (DONE / PARTIAL / NOT DONE — why), files changed, what the change does, tests added with proof they failed before and pass after, exact commands and results.
- Existing tests whose expectations you changed, and why each is a decided behaviour change rather than a weakened check.
- What you could not verify and what would verify it.
- Compatibility: existing stored data, build 147 still installed against a new backend, new build against the old backend.
- Changes needed in files you do not own.
- Anything the owner must do (access, console, device) — concrete, not generic.
