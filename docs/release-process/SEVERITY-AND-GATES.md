# Severity, finding classes, gates and the decision rule

These definitions are fixed before a release is assessed. Do not adjust them after seeing results.

## Severity

| Level | Definition | Release effect |
|---|---|---|
| **S1 Blocker** | Material data loss or corruption; unauthorized or cross-account access; material consent or privacy violation; incorrect core financial result; broken critical journey; unmet applicable store requirement; a critical requirement that cannot be verified. | Release is NOT READY while open. Cannot be accepted as a limitation, except an unverifiable-requirement S1 that the owner explicitly accepts after reading the exact untested scenarios. |
| **S2 High** | Significant defect with limited scope or a workable workaround; a serious risk that is not yet shown to occur. | Must be fixed, or accepted by the owner in an exception record, before READY. |
| **S3 Medium** | Real defect with low likelihood or low impact. | Fix if cheap and safe; otherwise list in known limitations. |
| **S4 Low** | Polish, documentation drift, hygiene. | Backlog. |

Severity is about user impact, not about who introduced the defect or when.

When likelihood is unknown, rate by impact and class the finding `SUSPECTED`; resolve the uncertainty rather than discounting the severity.

## Finding classes

| Class | Meaning |
|---|---|
| `REPRODUCED` | Observed by running something. |
| `CODE-SUPPORTED` | Established by reading code; not executed. |
| `SUSPECTED` | Plausible; needs verification before it is acted on. |
| `PRODUCT-DECISION` | Needs the owner. |
| `ENV-LIMITATION` | Cannot be checked in the available environment; the record says what is needed. |

## Checklist statuses

`PASS` · `FAIL` · `NOT TESTED` · `NOT APPLICABLE`. Nothing else. `NOT APPLICABLE` needs a reason. `PASS` needs evidence at the assessed commit.

## Gates

A gate is a condition that must hold before the next stage.

| Gate | Condition | Evidence |
|---|---|---|
| **G0 Candidate frozen** | One commit named; working tree clean; manifest started. | Release manifest. |
| **G1 Automated gates** | `REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh` exits 0 on the candidate: zero failed, zero unavailable tools, zero caller-skipped. Skips and ignores match the manifest. | Log with the "truthful summary" block. |
| **G2 Audit complete** | All 14 categories walked; every item has a status; no item is blank. | Coverage matrix and checklist results. |
| **G3 Triage clean** | Zero open S1. Every S2 fixed or carrying an owner-signed exception. | Issues register. |
| **G4 Artifact verified** | The store-bound artifact was built by the release workflow from the frozen commit and inspected (identifiers, version/build, entitlements/permissions, endpoints, no debug capability, no secrets). | Artifact verification output, provenance stamp. |
| **G5 Device verification** | The release's critical device scenarios were run on physical devices for each platform in scope, on the artifact from G4 (or a build of the same commit). | Manual device test record. |
| **G6 Store and policy** | Every mandatory store requirement for the intended distribution is met; public legal text matches behavior. | Store readiness record. |
| **G7 Backend ready** | Production state known (migration ledger, functions, flags, secrets presence, cron); deploy order and compatibility window written; recovery path stated honestly. | Release plan, production comparison record. |
| **G8 Independent review** | A reviewer who did not write the fixes has challenged the result; supported findings are addressed and re-verified. | Review record. |
| **G9 Owner decision** | The owner has read the decision and the exceptions and authorized the release action. | Signed decision. |

## Acceptance thresholds (defaults)

A release may tighten these in its own records before measuring; it may not loosen them without an owner decision.

| Area | Threshold |
|---|---|
| Automated tests | 100% of mandatory suites pass. No retries counted as passes. |
| Static analysis | `flutter analyze`, `deno lint`: zero errors. Warnings do not increase from the previous release's baseline. |
| Financial correctness | Totals are exact in integer minor units. Zero tolerance for a wrong or invented amount in tested scenarios. |
| Consent | Zero transmissions of message content or financial data in any tested state where consent is absent or revoked. |
| Account isolation | Zero cross-account reads in tested scenarios, local and server. |
| Capture reliability (device) | Every message in the manual device script is captured exactly once, or is visibly reported as not saved. Zero silent losses. |
| Duplicates | Zero duplicate transactions from repeated delivery of the same message; zero merges of distinct messages in the test set. |
| Cold start (device) | App is usable within 5 seconds on the oldest supported device class with a populated database. |
| Populated database | Lists and reports remain usable with 10,000 transactions (no frame freezes longer than 1 second on scroll, report opens within 3 seconds). |
| Upgrade | Upgrade from each supported prior build keeps all data and settings. |
| Accessibility | Body text contrast at least 4.5:1; interactive targets at least 44×44 pt (iOS) / 48×48 dp (Android); every interactive control has an accessible name; no clipped text at the largest supported text size on primary screens. |
| Crash-free sessions after release | Stop the rollout below 99% crash-free sessions in the observation window, or on any data-loss report. |

## Decision rule

- Any open S1 on a platform → that platform is **NOT READY**.
- G1–G8 not all satisfied for a platform → **NOT READY**, with the unmet gates named.
- No open S1, all gates satisfied, one or more S2/S3 covered by owner-signed exceptions → **READY WITH DOCUMENTED ACCEPTED LIMITATIONS**.
- No open S1 or S2, all gates satisfied → **READY**.
- The combined decision is the worst decision among the platforms in the intended launch scope and the backend they depend on.

Pass percentages are reported for information only. They never offset a blocker.
