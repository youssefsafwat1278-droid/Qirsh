# Version 1 — release manifest

What exactly was assessed, to the extent it can be verified. Unknown means unknown. Counts are from `git log`.

## One candidate

**The candidate is commit `5dae2e2d`** on the local branch `release-readiness/v1`: the final code commit `50957c06c2a1bf037eabdb73b3e224452caa32a1` plus one test-only commit. Every other name below is an ancestor of it and is history, not a candidate.

| Name | Commit | What it is |
|---|---|---|
| Audit baseline | `ab5dc10a` | Tip of `origin/feat/post-beta-features` (2026-11-17). What audits A–H read |
| Last distributed build | `b6fc0dad` → iOS 1.0.0 (147) | One commit before the baseline. TestFlight internal testing, Codemagic `ios-signed`, 2026-11-16 |
| Round-1 code, first form | `23499229` | Baseline + 11 fix commits. The strict gate found one stale test expectation in it |
| Round-1 code, final | `af675aec` | `23499229` + that one corrected test expectation. Strict gate 15/15. No application code differs between the two |
| Round-1 records | `d830855e` | Documentation only, committed on top of `af675aec` |
| Round-2 application code, final | `50957c06` | `d830855e` + 15 round-2 code commits. The commit the final independent review (R) assessed |
| **Candidate** | **`5dae2e2d`** | `50957c06` + one corrected test expectation that the strict gate's define-gated stage caught (no application, backend or CI code differs between the two) |
| Round-2 records | the commit that contains this file, and one after it recording the gate result | Documentation only, on top of `5dae2e2d`. It changes nothing under `app/`, `supabase/`, `admin/`, `tools/` or `codemagic.yaml` |

`git log --oneline ab5dc10a..5dae2e2d` lists 29 commits: 12 round-1 code commits, 1 round-1 records commit, 15 round-2 code commits, 1 round-2 test-only commit.

The candidate is **not pushed, not merged, not built by CI, not deployed and not on any physical device.** Build 147 contains none of it. The local branch name is refused by the hardened release workflow, which requires a `release/*` branch.

## Commits after the baseline

Round 1:

| Commit | Subject |
|---|---|
| `64e571e5` | Pass a real app version in every CI build and count Flutter skips in the skip gate |
| `f9c5be75` | Move the admin panel to the last Next.js 14.2 patch and correct the push rollback runbook |
| `d70ba396` | Declare the required-reason APIs both iOS targets use and run the app-switcher cover under scenes |
| `2f2c4707` | Make the Help text match what export and capture actually do |
| `ff1fc292` | Read zone-less timestamps as UTC when comparing sync conflict dates |
| `7597bb42` | Stop a cached force-update notice from blocking a build it no longer targets |
| `d35fc044` | Never record a declined purchase as spending; fix year-less dates and AI amount grounding (parser round 1) |
| `f6dc5076` | Serve admin images unoptimized so the unauthenticated image optimizer does no decoding |
| `29cb1819` | Run the define-gated Flutter suites in the gate instead of only counting their skips |
| `668f4d64` | Close the gaps in declined-transaction detection found by independent review (parser round 2) |
| `23499229` | Fix small UI and accessibility defects found on the running app |
| `af675aec` | Update the onboarding page-label test to the Western digits the Arabic strings now use |
| `d830855e` | Add the release-readiness process and the Version 1 assessment records (documentation) |

Round 2:

| Commit | Subject |
|---|---|
| `0de54a2b` | Treat failed refunds and more failed-payment wordings as not completed; type reversals as refunds (parser round 3) |
| `4fc2ecd6` | Give the App Store iOS workflow the same checks as the internal-testing one |
| `34ccc9e9` | Enlarge the remaining small touch targets and fix low-contrast text with existing tokens |
| `837d0881` | Cover data removal through startup in a configured build |
| `8e953d14` | Add an executable reproduction of restore followed by cloud sync |
| `84f2fe41` | Send reversed purchases to review, read plain refund messages, and stop promotions becoming credits (parser round 4) |
| `0f90003f` | Keep server identity across restore so restored data syncs without diverging or duplicating |
| `45ea901a` | Show the tab bar again after signing in with a sheet open |
| `42a0fd0c` | Cover more non-completed wordings, stop ignore rules dropping real purchases, distrust a server result the device reads the other way (parser round 5) |
| `0095a239` | Tell the user a pasted declined payment was not recorded instead of asking them to add it |
| `1be44623` | Parser round 6 — rejected by independent review (silent loss of completed transactions) |
| `c8cef416` | Stop informational words dropping real transactions (parser round 7) |
| `5583cbea` | Never take a limit, balance or code figure as the amount, and never hide a message that carries an amount (parser round 8) |
| `75dab61a` | Parser round 9 — rejected by independent review (outgoing debits imported as confirmed income) |
| `50957c06` | Take back the direction words and amount rule that turned debits into income (parser round 10, subtractive) |
| `5dae2e2d` | Update the default-RPC reconcile test to the backfill's first lookup (test only) |

Two commits in this history were rejected by independent review and corrected by the commits after them. They remain in the history; the candidate is the tip.

## Components and versions

| Component | At the candidate | In production (read-only check, 2026-11-17) |
|---|---|---|
| Marketing version | 1.0.0 (`app/pubspec.yaml`) | — |
| Build number | Not assigned. Codemagic takes the latest App Store Connect number and adds one. `pubspec.yaml` says `+44`, which is not the real number | Last build 147 |
| Device database schema | Drift v43, forward-only; unchanged by any commit after the baseline | — |
| Backup file format | Unchanged | — |
| Supabase migrations | 134 files, `0001_init` … `20261117010000_push_broadcast_auto_retry`; none added or changed after the baseline; `0118` deferred | **Ledger lists the same 134.** Names only — content not compared |
| Edge Functions | 33 in the repository | 28 deployed (the four affiliate functions and `parser-test` are not, per decision D-14). Compared at `af675aec`: 22 identical, 6 different. Since then only `process-ios-sms`, `parse-sms` and the shared AI validator they bundle changed |
| Server parser rules | `process-ios-sms/parser_rules.json` and the shared cases changed by the parser rounds | Deployed `process-ios-sms` v27 (2026-11-16) has none of it |
| AI model, SMS parsing | `gemini-3.8-flash` unless `GEMINI_SMS_MODEL` is set | Variable not set → default in effect |
| AI model, bank discovery | `gemini-2.5-flash-lite` unless `GEMINI_MODEL` is set | Variable not set → default in effect |
| AI prompt version | Not versioned, not recorded per result | — |
| Feature flags | Seed values in migrations | All advertising flags **on** at 100%; `local_auto_confirm_v2` off; `capture_ai_fallback_enabled` off (see `evidence/production-comparison.md`) |
| Backups | — | Point-in-time recovery **off**; the API lists no backups |
| Admin panel | Next.js 14.2.35, image optimization off | Deployment and exposure unknown |
| CI toolchain | Flutter 3.47.3; `xcode: latest` (unpinned) | Variable values in Codemagic unknown |
| Sign-in in a build | Apple always; Google and email one-time code when the build variables enable them — `ios-signed` sets both true; `ios-signed-release` defaults them off | — |

## Environment of this assessment

One Apple-silicon Mac, macOS (Darwin 27.0.0), Flutter 3.47.3 / Dart 3.13.3, Xcode 27.2, Node 26.8.2, Deno 2.9.6, Supabase CLI 2.117.0, Docker Desktop 29.7.2. iOS 26.5 simulators. A local Supabase stack with synthetic data for the restore and signed-in checks.

Not available: any physical device; a Java runtime or `adb` (Android was neither built nor run); a CI or signed build of the candidate; store consoles.

Production was read, never written: the Supabase CLI already signed in on the owner's machine, and a Supabase connector the owner attached (migration list, security advisor, one `SELECT`). One Codemagic build log was read with the owner's sign-in.

The disk filled during round 2; one test run made then was discarded as evidence and repeated (see [TEST-EVIDENCE.md](TEST-EVIDENCE.md)). With the owner's agreement, Xcode test-device clones, device-support files, the npm and Homebrew caches and four simulators from finished earlier test rounds were deleted to free space. Docker Desktop was restarted at the owner's request.

## Reviewers

Orchestration, integration, verification runs and these records: Claude Fable 5.2 (AI). Specialist audits, fixes, records compilation and every independent review: AI agents that each reported the model identifier `claude-opus-5-5`; that identity cannot be verified beyond the agent's own statement and the tool's `opus` selection. No human has reviewed anything. AI review is an additional control, not a certification and not an approval.
