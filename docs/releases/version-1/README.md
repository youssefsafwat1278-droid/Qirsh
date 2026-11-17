# Qirsh Version 1 — release readiness records

Results of applying the [release-readiness process](../../release-process/README.md) to Version 1 on 2026-11-17.

**Outcome: NOT READY** on iOS, Android, backend and combined. See [RELEASE-DECISION.md](RELEASE-DECISION.md). This is a recommendation by an AI orchestrator; the owner decides.

Candidate: `af675aec` on the local branch `release-readiness/v1`, which is the audit baseline `ab5dc10a` (tip of `feat/post-beta-features`) plus 12 fix commits. Not pushed, not built by CI, not deployed, not on any device. The last distributed build, iOS 1.0.0 (147), contains none of the fixes.

## Read in this order

| File | What it answers |
|---|---|
| [RELEASE-DECISION.md](RELEASE-DECISION.md) | Is each platform ready, why not, what the owner must decide and do |
| [ISSUES.md](ISSUES.md) | Every finding, deduplicated, with severity, class and status |
| [CHANGELOG.md](CHANGELOG.md) | What was changed locally and why |
| [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md) | What remains wrong or unverified below blocker level (proposals, not accepted) |
| [TEST-EVIDENCE.md](TEST-EVIDENCE.md) | What was actually run, where, and the result |
| [MANUAL-DEVICE-TESTS.md](MANUAL-DEVICE-TESTS.md) | The numbered script for physical devices — all NOT TESTED |
| [RELEASE-PLAN.md](RELEASE-PLAN.md) | Production checks, deploy order, rollout, monitoring, recovery |
| [STORE-READINESS.md](STORE-READINESS.md) | Each mandatory store requirement and its state |
| [SCOPE.md](SCOPE.md) | Proposed Version 1 scope and open scope decisions |
| [SYSTEM-MAP.md](SYSTEM-MAP.md) | Components, data flows, consent model, outbound data |
| [COVERAGE-MATRIX.md](COVERAGE-MATRIX.md) | Every checklist item and critical scenario with method, result and evidence |
| [UI-UX-REVIEW.md](UI-UX-REVIEW.md) | Interface findings, fixes, before/after, what was not exercised |
| [AUDIT-REPORT.md](AUDIT-REPORT.md) | How the audit ran, what held up, disagreements and how they were settled |
| [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) | Exact commit, versions, and what is unknown |
| [PROGRESS.md](PROGRESS.md) | Chronological log; resume point after an interruption |

## Evidence

- [`evidence/audits/`](evidence/audits/) — specialist reports A–H, the independent review I, and the briefs given to the agents.
- [`evidence/ui/before/`](evidence/ui/before/), [`evidence/ui/after/`](evidence/ui/after/) — simulator screenshots with synthetic data.
- [`evidence/logs/`](evidence/logs/) — summaries of the gate runs.

No real bank messages, credentials, tokens or personal data are in these records.

## Status words

`PASS` / `FAIL` / `NOT TESTED` / `NOT APPLICABLE` for checklist items. `NOT TESTED` means exactly that: it was not run, usually because it needs a physical device, production access or a store console that this assessment did not have.
