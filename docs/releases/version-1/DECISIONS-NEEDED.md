# Version 1 — owner decisions: approved, still open, and engineering choices the owner may reverse

First prepared 2026-11-17 (rounds 1 and 2). **Brought to round 3 on 2026-11-18** by a records editor (AI agent, `claude-opus-5-5`) from [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3, `docs/project/DECISIONS.md` D-20, the closure reports in [`evidence/closure/`](evidence/closure/) and reviews S and T. Candidate `a157e68e`.

**What the owner decided:** only the fifteen product decisions in brief §3 (approved 2026-11-17, recorded as D-20). D-20 itself says what it does **not** decide: risk tolerances for AI accuracy, any historical clean-up, and the ad position after V1. **The owner has accepted no open defect and signed no exception.** Nothing in this file records an acceptance.

Rule applied, unchanged: a record decides a question only if it states the decision explicitly, is the latest statement on that question, and is not contradicted by code or production state. Code comments that claim an owner decision do not count (V1-104).

## A. Approved by the owner on 2026-11-17 (brief §3)

"Status" says what is implemented and verified, not whether the decision is good.

| # | Decision (brief §3) | Where implemented (commit) | Status at `a157e68e` |
|---|---|---|---|
| 3.1 | V1 targets iPhone; iPad and Android release readiness out of scope; Android code kept | `640562f6`: `TARGETED_DEVICE_FAMILY = 1` in six configurations, portrait | Implemented; contract-tested; reviewer T read it. iPad compatibility mode NOT TESTED (needs a signed build and an iPad) |
| 3.2 | No advertising in V1; a remote flag must not reactivate it; prepare, do not execute, the production flag change | `640562f6`: compile-time define off in store workflows; GMA 13.3.0 and UMP 3.1.0 linked but never started; RELEASE-PLAN P4 turns the eight flags off | Implemented in code; tests; T read every SDK entry. Network silence NOT TESTED. **Production flags still ON** (P4 not executed) |
| 3.3 | Restore merges; keep newer data, server identity, deletions and manual edits; explain in the UI; verify with sync | `640562f6`, `7dd6efa8`, `6f771108` | Implemented; verified on local stacks (data specialist; T `+24 ~2`). Limits: device rules win, backup-only rules are not added, a mistaken deletion is not recoverable by merge (SP-12, V1-102); two-device cases S9/S9b not run (V1-101). Not on a device |
| 3.4 | Deletion is final; copy and policy aligned; worker and retries verified; no production clean-up authorized | `640562f6`, `bae159e2`; policy text `7cab5e8b`, `4c428719` | Implemented; D1–D4 pass on local stacks (data specialist; T). The deployed worker still lacks photo erasure until plan P1 is executed; the live legal site still has the old text |
| 3.5 | Privacy Policy and Terms open with Cloud off, before consent, without enabling anything | `640562f6`: exact-URL allowlist | Implemented; unit tests; T found no bypass. Not on a device |
| 3.6 | Language chosen on first launch without preselection; existing choices kept | `640562f6` | Implemented; tests |
| 3.7 | All countries; country separate from verified bank coverage; currency not assumed from country; honest disposition | `640562f6`, `bae159e2`: 249 countries, coverage note, 155 storable currencies (50 detected in text) | Implemented; tests. **Limit:** build 147 knows 50 currencies (SP-04, V1-100). Antarctica has no default currency; the user chooses |
| 3.8 | First-run consent with "Agree and enable" and "Continue locally"; nothing sent before consent; honest text; no silent opt-in | `640562f6`, text reworded `f4dcabd3` to say what redaction really does | Implemented; tests; T. GDPR granular-consent question not assessed (counsel). Redaction still lets some names through (V1-091) |
| 3.9 | One action turns Cloud and AI off together; dispatch and retries stop; consent re-checked | `640562f6` | Implemented; tests; T |
| 3.10 | Shared learning enabled with the explicit activation; contribution explained and minimized | `640562f6` | Implemented. **Reading by the orchestrator, not by the owner:** a missing preference reads OFF, and existing users are asked once. The owner may reverse this reading |
| 3.11 | Keep the current sign-in methods; no reviewer backdoor; check reviewer access | `640562f6`: store workflow keeps Apple, Google and email code and fails if the variables are missing | Implemented in the workflow; Codemagic values not visible (owner). Reviewer access via Sign in with Apple: no blocker found (ops) |
| 3.12 | Notifications show available details; respect preview settings; never claim a save that did not happen | `640562f6`, `bae159e2`: native banners, masked last four in APNs, server push never says "recorded" | Implemented; XCTest and Deno tests. Not on a device. **Build 147's Shortcut banner** still says a purchase was captured with the parsed category until users update |
| 3.13 | Signed-out capture: no silent success; nothing attached to the next account; no retention promise | `640562f6` | Implemented; nothing retained while signed out; XCTest. Not on a device |
| 3.14 | Balance labelled by its source with its time | `640562f6` | Implemented; tests; contrast measured |
| 3.15 | Parser changes apply to new messages only; no historical re-analysis or silent review marking | No historical code path added | Respected. The historical review-list proposal is not pursued (HISTORICAL-REVIEW-PROPOSAL.md) |

## B. Earlier questions: where each stands now

| # | Question (issue) | Now |
|---|---|---|
| A1 | Android in V1 (V1-004) | Decided again by the owner: 3.1 |
| A2 | Non-personalized ads only (D-6) | Moot for V1: no ads (3.2) |
| A3 | Shared learning on by default (V1-048) | Superseded by 3.10 |
| A′1 | D-19 vs production ad flags | Intent settled by 3.2 (D-20 supersedes D-19's ad position); **production still ON** until P4 |
| B1 | Ads at launch; production flags | Decided: 3.2. Flag change prepared (P4), not executed |
| B2 | Refund or reversal of a declined original | Engineering choice: a completed reversal "… credited" goes to review (table D) |
| B3 | Disputed shared-case labels | Engineering choice: truth labels left unchanged; outcomes graded as review where acceptable (table D) |
| B4 | iPhone-only (V1-014) | Decided: 3.1 |
| B5 | Reviewer access (V1-015) | Decided: 3.11 (Sign in with Apple) |
| B6 | Sign-in providers (V1-016) | Decided: 3.11 |
| B7 | Export compliance (V1-026) | **Still open** (C1) |
| B8 | Legal pages with Cloud off (V1-007) | Decided: 3.5 |
| B9 | Deletion wording (V1-006) | Decided: 3.4 |
| B10 | Restore replace or merge (V1-020) | Decided: 3.3 |
| B11 | Historical declined rows (V1-056) | Decided: 3.15 — not pursued |
| B12 | Countries (V1-019) | Decided: 3.7 |
| B13 | Withdrawal sentence (V1-017) | Decided: 3.9 |
| B14 | Catalog and force-update with Cloud off (V1-045) | Engineering choice (table D) |
| B15 | Store-capable pipeline (V1-009) | **Still open** (C2) |
| B16 | Disk-space probe in release builds | Engineering choice: compiled out (table D) |
| B17 | Admin panel (V1-025) | Overtaken by engineering: upgraded to Next 15.5.29 (`bae159e2`). Whether the admin is internet-exposed is still unknown |
| B18 | Unreachable features in the binary (V1-042) | **Still open** (C3) |
| B19 | Lock-screen detail (V1-036) | Decided: 3.12 |
| B20 | Signed-out Shortcut captures (V1-037) | Decided: 3.13 |
| B21 | Language preselection (V1-044) | Decided: 3.6 |
| B22 | No-currency message in the account currency (V1-031) | Implemented under 3.7 as an engineering rule: only a confidently matched account's currency is used, otherwise review |
| B23 | "Current balance" (V1-032) | Decided: 3.14 |
| B24 | App-switcher cover timing | Engineering choice: resign-active (table D) |
| B25 | Backup passphrase minimum (V1-046) | **Still open** (C4) |
| B26 | Sign-out sentence with Cloud off (RT-03) | Engineering choice: option (a) (table D) |
| B27 | Auto-confirm only on a catalog match | **Still open** (C5); no change made |
| B28 | Ship the round-2 parser | Overtaken: brief §4 directed the round-3 parser work. Shipping it is now part of approving the production package (C7) |
| B29 | Review volume vs wrong totals (V1-085, V1-086) | **Still open** (C6): D-20 leaves AI-accuracy risk tolerances undecided |
| B30 | Notices with an amount (V1-072) | Brief §4.1 requires notices to be distinguished; implemented as "not a movement" (server) and review (device). The residual wordings are V1-094 |

## C. Still open (owner)

Ordered by how much each blocks.

| # | Question (issue) | Options | Recommendation (proposal) | Blocks |
|---|---|---|---|---|
| C1 | Export compliance (V1-026) | (a) `ITSAppUsesNonExemptEncryption = true`, answer "standard algorithms", French declaration or exclude France; (b) keep `false` after a written exemption determination | (a), after counsel answers the prepared question (STORE-READINESS A14). Ops: `false` as written is not supportable | Every upload; App Store Connect answers |
| C2 | Store pipeline (V1-009, B15) | (a) Use the hardened `ios-signed-release`; (b) another workflow | (a); it has never run on Codemagic | Any submittable build (G4) |
| C3 | Unreachable features shipped in the binary (V1-042, B18) | (a) Record as out of V1, leave code; (b) wire them up | (a) | Reviewer notes, Help copy |
| C4 | Backup passphrase minimum of 6 (V1-046, B25) | (a) Raise; (b) keep | (a) | Exception or fix |
| C5 | Auto-confirm only on a catalog match (B27) | (a) Require; (b) keep | (b) for V1 | None today |
| C6 | Risk tolerance for review volume and AI accuracy (V1-085, V1-086, V1-103; D-20 "not decided") | (a) Keep current strictness (27.2 % of completed messages to review without Cloud; 8.8 % deterministic cloud); (b) relax named cases; (c) stricter | (a) for V1, with monitoring once it exists | Whether V1-103 is a defect or within tolerance; the engineering criteria A1–A8 are not owner-approved |
| C7 | Approve the production package as a whole (RELEASE-PLAN), separately the grants clean-up | Approve / edit / reject | Approve after the pre-flight items in RELEASE-PLAN (pg_dump, Codemagic sign-in variables, backend stage at `a157e68e`) | Every deploy step P0–P5 |
| C8 | Build 147 and the 105 new currencies (SP-04, V1-100) | Options in RELEASE-PLAN (c) | As the plan proposes | Mixed-build users |
| C9 | Whether evaluation criterion A8a should exclude rows labelled review-acceptable (eval §12) | (a) Exclude; (b) keep the letter | No recommendation; the criterion was not changed | V1-103 grading |
| C10 | Optional: merchant-rule tombstone so a merge can bring back backup-only rules safely (schema v44) | (a) Later version; (b) now | (a) | V1-102 |
| C11 | Remove the dormant `cancel_account_deletion` and `purge-scheduled-deletions` pieces | (a) Remove in a later migration; (b) keep | (a) | None for V1 |
| C12 | One production account: 540 failed iOS notifications (error 2003) and 2 captures stuck in `processing` (V1-106) | (a) Investigate read-only in P0; (b) leave | (a) | None for the package; no production write is authorized |
| C13 | Legal site redeploy and GDPR granular-consent question (counsel) | — | Redeploy after release; ask counsel | G6 (public text must match the build) |

## D. Engineering choices made in round 3 that the owner may reverse

Not owner decisions. Each was chosen by an engineer because no owner decision covered it, and each errs toward review rather than recording money.

| Choice | Where | Effect |
|---|---|---|
| ATM cash deposit → review (V1-090, RR-05) | parser, device and server | No income booked; the user confirms. Truth labels in the shared table still say income |
| Credit-card repayment "… received" → review | parser | No direction guess |
| Completed English reversal "… credited" → review (old B2) | parser, device validator | 4 held-out messages to review that build 147 recorded |
| Sanitizer keeps the user's own ≤4-digit card suffix and «حسابك» | device, server, Swift | Needed for account matching; the suffix still reaches the server |
| Shared learning: missing preference = OFF, existing users asked once | consent | Reading of 3.8/3.10 |
| Device rules win on merge; backup-only rules not added | restore | SP-12 limit |
| Text over 2,000 characters → review | device and server | No parse of very long text |
| Disk-space probe compiled out of release builds (B16) | iOS | Manifest entry removed |
| App-switcher cover on resign-active (B24) | iOS | Device check owed |
| Cloud-off sign-out sentence, option (a) (B26) | app | Code comments wrongly call it a decision (V1-104) |
| No catalog, flag or update request with Cloud off (B14) | app, policy | Cloud-off users get no force-update notice |
| Evaluation criterion A8a reported failing by its letter, not changed | eval | See C9 |

**Count:** 15 approved by the owner (table A, 3.1–3.15). Of the 34 earlier questions (A1–A3, A′1, B1–B30): 21 settled by the approved decisions or overtaken (A1–A3, A′1, B1, B4–B6, B8–B13, B17, B19–B21, B23, B28, B30); 7 handled by engineering choices the owner may reverse (B2, B3, B14, B16, B22, B24, B26); 6 still open and carried as C1–C6 (B7, B15, B18, B25, B27, B29). **Open now: 13 (C1–C13)**, of which 7 are new in round 3 (C7–C13). Engineering choices the owner may reverse: 12 (table D).
