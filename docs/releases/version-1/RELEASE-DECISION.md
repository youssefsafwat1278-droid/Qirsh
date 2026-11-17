# Version 1 — release decision

**Recommendation, 2026-11-17, second round. Not an owner decision.** Prepared by the orchestrating agent (Claude Fable 5.2) under [`docs/release-process/SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md).

The owner has accepted no limitation and approved no proposed scope decision. Nothing in this file records an acceptance.

Candidate: `5dae2e2d` on the local branch `release-readiness/v1` (final application code `50957c06` plus one test-only commit) — see [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) for how it relates to `23499229`, `af675aec` and the records commits.

| Scope | Decision |
|---|---|
| iOS | **NOT READY** |
| Android | **NOT READY** — and, by existing project record, outside Version 1 |
| Backend | **NOT READY** |
| Combined, for the intended launch | **NOT READY** |

The independent reviews reached NOT READY each time they gave a decision. The count of passing checks in [COVERAGE-MATRIX.md](COVERAGE-MATRIX.md) is informational and does not offset a blocker.

## What changed since the first decision

Local engineering closed or narrowed several first-round blockers, and reading production closed one. None of it is released.

| First-round blocker | Now |
|---|---|
| V1-001 declined purchases counted as spending | Fixed in code over ten parser rounds; the final commit is independently reviewed with no S1 regression and nothing worse than the baseline on the device or effective path. **Not closed**: open defects remain, and it needs the server and a new build shipped together plus device verification |
| V1-002 production migration state unknown | **Closed for the ledger** by a read-only check: production has the candidate's 134 migrations. No migration is needed |
| V1-020 restore versus cloud sync (was suspected) | **Confirmed** on a local stack, then the decision-independent part fixed and verified on that stack. Open: the owner's replace-or-merge decision; device run |
| V1-009 no store-capable hardened pipeline | Prepared locally; never run on Codemagic |
| V1-054 data removal untested in a configured build | Covered by tests in the gate |

New blockers found in the second round are listed below.

## iOS — NOT READY

Open S1 items:

| ID | Blocker | Who can clear it |
|---|---|---|
| V1-001 | Bank-message parser. The candidate is measurably safer than build 147 (wrong total-changing outcomes on the final reviewer's 1,758-message set: 509 → 71 on the effective path; declined messages recorded: 174 → 4), but 71 remain, each also wrong at the baseline: notices recorded as money, wrong directions, own-account transfers, foreign-currency figures. Measured on synthetic messages only | Owner decision on shipping with the remaining defects; server deploy with a new build; device run with real messages |
| V1-078 | A limit or balance figure recorded as the amount. Fixed in code; takes effect only with the new build and server | Deploy and build |
| V1-072 | Informational notices recorded as money (34 on the reviewer's set). Two attempts to ignore them caused silent losses and were removed | Owner decision on how notices should be handled |
| V1-003 | Store privacy details and the privacy manifest's collected-data list omit data the app sends | Owner (console) and engineering after the ads decision |
| V1-005 / V1-063 | **All advertising flags are on in production.** A store build from the release workflow carries the AdMob IDs and would show ads, while the privacy policy, consent text and store declarations do not mention ads | Owner decision |
| V1-007 | Privacy Policy and Terms cannot be opened in-app with Cloud off, including before consenting | Owner decision |
| V1-014 | iPad and landscape enabled with no decision, layout evidence or iPad screenshots | Owner decision |
| V1-015 | No working reviewer access: the app has no password sign-in; reviewer notes drafted but not submitted | Owner |
| V1-020 | Restore and cloud sync: fixed in code and verified on a local stack; the replace-or-merge rule is undecided; no device run | Owner decision; device |

Also open and affecting testers today: build 147 hides the tab bar after an email-code sign-in (RT-01). Fixed in the candidate and confirmed on a simulator; testers get it only with a new build.

Gates: G1 (automated gates on the candidate) — see [TEST-EVIDENCE.md](TEST-EVIDENCE.md). Not met: G4 (no signed artifact of the candidate), G5 (no physical-device verification of anything), G6 (store requirements), G9 (owner decision). S2 items remain open with no exception record.

## Android — NOT READY

Project records already place Android outside Version 1 (Play publication deferred by the owner; see [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md), table A). On that basis Android does not enter the combined decision. On its own it is not releasable: no sign-in method in a release build, the Play SMS declaration and Data safety form unsubmitted and stale, no release bundle ever built, no device run, and it could not be built or run in this assessment.

## Backend — NOT READY

| Item | State |
|---|---|
| Migrations | None needed; production ledger equals the candidate |
| Functions to deploy | Three, not all: `account-deletion-worker` (the deployed one predates profile-photo erasure, V1-062), `process-ios-sms` and `parse-sms` (parser). The parser functions and the new app build must ship together — the server alone rejects messages that only the new build recovers into review; a new server with build 147 was not measured |
| Advertising flags | On in production, contrary to the recorded decision |
| Recovery | Point-in-time recovery is off and no backups are listed. No verified way to restore the database |
| Monitoring | None for the backend |
| AI spend | No global ceiling |

Gate G7 is not met. The single action package for the owner's approval is in [RELEASE-PLAN.md](RELEASE-PLAN.md). Nothing in it has been executed.

## Combined — NOT READY

With Android outside the scope, the combined decision is still NOT READY on iOS and backend.

## The five lists the owner asked for

### 1. Local engineering completed and verified

| Work | Verification |
|---|---|
| Parser: declined, failed, pending, reversed and informational messages; limit/balance/code figures never the amount; import-path defences; whole-word ignore rules and currency codes | 1,565 shared cases on device and server; ten rounds; independent review of every commit, the last one (R) with its own harness. Not device, not real traffic |
| Restore keeps server identity; no divergence or duplicates | Unit tests against a fake backend and a live local Supabase stack: fails before, passes after. Independent review K |
| Tab bar after sign-in | Tests; simulator, three fresh installs, with a control build reproducing the defect |
| Data removal through startup in a configured build | Tests in the gate (10/10) |
| Native iOS tests | 194 passed on a simulator — first valid run |
| Touch targets, contrast with existing tokens, small-screen layout, labels | Widget tests; part seen on a simulator |
| Release workflow hardened; version define; skip gate; define-gated suites in the gate | Contract tests; never run on Codemagic |
| Admin dependency patch and image-optimizer hardening | Build and tests |
| Help text, paste wording, force-update range, sync timezone | Tests |
| Production compared read-only; official documentation checked; reviewer notes drafted; decisions tabulated | See `evidence/` |

### 2. Local work still outstanding

- Parser open defects (RR-01): notices recorded as money; wrong directions for deposit and own-account wordings; foreign-currency figure recorded instead of the charged amount. No further round was made after the final review, by agreement with the owner.
- The review-volume cost of the stricter parser has no mitigation yet (AI validator rejects more correct candidates).
- Swift notification preview still matches by substring.
- Layouts above the 1.25× text cap; touch targets in sheets and secondary screens; date digits in Arabic.
- Kotlin tests in no CI; backend behavior in no gate; Next.js major upgrade.
- Disk-space probe still compiled into release builds (privacy manifest declaration kept).
- RT-03 sign-out sentence when Cloud is off.

### 3. Blocked by unavailable access or devices

- Every physical-device check: capture by Shortcuts and share extension, locked and background behavior, push, upgrade from 147, real bank messages, VoiceOver, full accessibility text sizes, the live app switcher.
- A Codemagic build of the candidate and its signed artifact.
- Android build and run.
- Store consoles: privacy answers, screenshots, export compliance, reviewer access.
- Production items not readable: Auth hook, Vault, cron history, Codemagic variables, admin exposure.
- The AI path against a real model.

### 4. Product decisions needed from the owner

The full table (question → options → recommendation → consequences → work blocked) is [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md). The ones that block the most:

1. Ship the candidate parser, given it is safer than build 147 by measurement but leaves open defects and sends more messages to review.
2. Advertising: flags are on in production — confirm ads at launch (then disclose everywhere) or turn them off.
3. Restore: replace or merge for cloud rows absent from the backup.
4. iPad: iPhone-only or supported.
5. Policy and Terms reachable with Cloud off.
6. Account-deletion wording in the policy versus immediate deletion in the app.
7. Reviewer access method.
8. How notices (bills due, expected salary) should be treated.

### 5. Production actions proposed for later authorization

One package, in [RELEASE-PLAN.md](RELEASE-PLAN.md): deploy `account-deletion-worker`; deploy `process-ios-sms` and `parse-sms` together with a new internal build; a read-only count of orphaned profile photos; and, depending on the owner's decisions, the advertising flags and a grants clean-up. No migration. Nothing has been executed, and the package is approved or edited as a whole.

## Not performed

No push, merge, production deploy, production configuration or data change, migration, function deploy, flag change, TestFlight upload, store submission, console change, purchase or account creation on any hosted service. Production was only read.
