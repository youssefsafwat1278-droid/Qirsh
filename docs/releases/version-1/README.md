# Qirsh Version 1 — release readiness records

Results of applying the [release-readiness process](../../release-process/README.md) to Version 1 on 2026-11-17 and 2026-11-18 (three rounds).

**Outcome: NOT READY** for the store on iOS, backend and combined, after three rounds. Android and iPad are outside V1 by owner decision 3.1. See [RELEASE-DECISION.md](RELEASE-DECISION.md). This is a recommendation by the AI orchestrator (Claude Fable 5.2); the owner approved the product decisions in [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3 and has accepted no defect or limitation.

Candidate: **`a157e68e`** on the local branch `release-readiness/v1` — the last code commit of round 3 (46 commits after the audit baseline `ab5dc10a`); records commits sit on top. Not pushed, not built by CI, not signed, not deployed, not on a device. See [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md).

## Read in this order

| File | What it answers |
|---|---|
| [RELEASE-DECISION.md](RELEASE-DECISION.md) | Is each platform ready, why not, what the owner must decide and do |
| [REVIEW-CLOSURE.md](REVIEW-CLOSURE.md) | Every independent-review finding: action, commit, verification, what remains |
| [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md) | The owner's approved decisions (brief §3) and where each is implemented; the questions still open; engineering choices the owner may reverse |
| [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) | The owner's round-3 instruction, verbatim |
| [REVIEWER-NOTES-DRAFT.md](REVIEWER-NOTES-DRAFT.md) | Draft App Review notes matching the code — not submitted |
| [HISTORICAL-REVIEW-PROPOSAL.md](HISTORICAL-REVIEW-PROPOSAL.md) | Proposal for reviewing transactions stored before the parser fixes — not pursued (decision 3.15) |
| [ISSUES.md](ISSUES.md) | Every finding, deduplicated, with severity, class and status |
| [CHANGELOG.md](CHANGELOG.md) | What was changed locally and why |
| [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) | Open defects, consequences of the approved decisions, and evidence limits (none accepted) |
| [TEST-EVIDENCE.md](TEST-EVIDENCE.md) | What was actually run, where, and the result |
| [MANUAL-DEVICE-TESTS.md](MANUAL-DEVICE-TESTS.md) | The numbered script for physical devices — all NOT TESTED |
| [RELEASE-PLAN.md](RELEASE-PLAN.md) | Production checks, deploy order, rollout, monitoring, recovery |
| [STORE-READINESS.md](STORE-READINESS.md) | Each mandatory store requirement and its state |
| [SCOPE.md](SCOPE.md) | Version 1 scope as decided by the owner |
| [SYSTEM-MAP.md](SYSTEM-MAP.md) | Components, data flows, consent model, outbound data |
| [COVERAGE-MATRIX.md](COVERAGE-MATRIX.md) | Every checklist item and critical scenario with method, result and evidence |
| [UI-UX-REVIEW.md](UI-UX-REVIEW.md) | Interface findings, fixes, before/after, what was not exercised |
| [AUDIT-REPORT.md](AUDIT-REPORT.md) | How the audit ran, what held up, disagreements and how they were settled |
| [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) | Exact commit, versions, and what is unknown |
| [PROGRESS.md](PROGRESS.md) | Chronological log; resume point after an interruption |

## Evidence

- [`evidence/audits/`](evidence/audits/) — specialist reports A–H; independent reviews I, K, L, N, O, P, Q, R and, in round 3, S (money correctness) and T (platform and records); runtime reports J and M; the briefs given to the agents.
- [`evidence/closure/`](evidence/closure/) — round-3 specialist closure reports (parser, AI, data, consent, iOS, accessibility, ops, held-out evaluation).
- [`evidence/ROUND2-FACTS.md`](evidence/ROUND2-FACTS.md) — the facts the second-round records were reconciled against.
- [`evidence/production-comparison.md`](evidence/production-comparison.md) — read-only comparison of production with the candidate.
- [`evidence/official-doc-checks.md`](evidence/official-doc-checks.md), [`evidence/local-stack.md`](evidence/local-stack.md).
- [`evidence/ui/before/`](evidence/ui/before/), [`evidence/ui/after/`](evidence/ui/after/), [`evidence/ui/signed-in/`](evidence/ui/signed-in/) — simulator screenshots with synthetic data.
- [`evidence/logs/`](evidence/logs/) — summaries of the gate runs.

No real bank messages, credentials, tokens or personal data are in these records.

## Status words

`PASS` / `FAIL` / `NOT TESTED` / `NOT APPLICABLE` for checklist items. `NOT TESTED` means exactly that: it was not run, usually because it needs a physical device, production access or a store console that this assessment did not have.
