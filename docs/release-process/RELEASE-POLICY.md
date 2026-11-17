# Release policy

Project-specific rules. Where a rule comes from a store or a standard, [SOURCES.md](SOURCES.md) has the reference; everything else here is Qirsh's own policy.

## 1. Roles

| Role | Who | Authority |
|---|---|---|
| Owner | The product owner | The only person who accepts limitations, changes scope, privacy commitments or consent rules, and authorizes pushes, production deploys, production configuration changes, and store submissions. |
| Release lead | Whoever runs the release (a person or an orchestrating agent) | Runs this process, integrates fixes, writes the decision *recommendation*. |
| Specialist reviewers | People or agents per area | Produce evidence and findings. Agreement between reviewers is not proof. |
| Independent reviewer | Someone who did not write the fixes | Challenges the result before the decision. |

Nobody may record an approval on the owner's behalf.

## 2. Non-negotiables

A release is not READY while any of these is open, regardless of how many other checks pass:

1. Unresolved material data loss or corruption.
2. Unauthorized or cross-account data access.
3. A material consent or privacy violation, including any transmission the privacy policy or the user's consent state does not allow.
4. Incorrect core financial behavior (amounts, totals, balances, fabricated values).
5. A broken critical journey.
6. A critical requirement that could not be verified.
7. An unmet store requirement that applies to the intended distribution.

## 3. What may not be done to make a release pass

- Disabling, skipping, or weakening a required test, lowering a threshold, or deleting an assertion to turn a gate green. `tools/ci_gates.sh` counts caller-skipped mandatory tests as fatal in strict mode; keep it that way.
- Weakening a security control or a consent check.
- Changing scope, privacy commitments, consent flows, or financial meaning without an owner decision recorded in `docs/project/DECISIONS.md`.
- Recording a result that was not observed. A device test that did not happen is `NOT TESTED`.

## 4. Evidence rules

- Every result names the commit and, for artifacts, the build number it was observed on.
- Evidence expires when affected code or configuration changes. After any change, write an impact assessment (which categories and items are affected) and re-verify those.
- Evidence from an earlier release may be reused only with a written reason that the relevant code and configuration did not change.
- Simulator and emulator runs are runtime evidence, not device evidence. Say which it was.
- Evidence must not contain real bank messages, credentials, tokens, or personal data. Use synthetic data. Sensitive screenshots stay out of the repository.
- Thresholds are written down before measuring.

## 5. Scope discipline

- A release fixes confirmed, in-scope defects. It does not add features or refactor broadly.
- UI changes during release hardening are limited to defects (clipping, overflow, RTL errors, missing labels, missing states, missing feedback) and modest consistency fixes within the existing design. Rebranding, new navigation, re-architected screens, removed features, and anything touching consent or financial meaning need an owner decision first.
- A pre-existing defect can still block a release. "It was already there" is not a severity.

## 6. Production and stores

- Database, functions, admin, and mobile are separately deployed and separately versioned. The release plan states the order and the compatibility window; see [RELEASE-RUNBOOK.md](RELEASE-RUNBOOK.md).
- Backend changes must work with every client version still installed (expand, then migrate, then contract). A migration that breaks an installed client is a blocker unless a forced update exists and has been verified.
- Migrations are forward-only on the device (Drift) and treated as forward-only in production unless a specific rollback file has been rehearsed. Do not write "roll back" in a plan without saying how and whether it was tested.
- Mobile releases go to internal testers first, then a limited audience, then wider, where the store supports it.

## 7. Decisions

Allowed outcomes per platform and combined: `READY`, `READY WITH DOCUMENTED ACCEPTED LIMITATIONS`, `NOT READY`. A truthful NOT READY with precise blockers is a successful outcome of this process. "Accepted" means the owner signed the exception record ([EXCEPTION-TEMPLATE.md](EXCEPTION-TEMPLATE.md)); a proposal is not an acceptance.
