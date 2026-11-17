# Qirsh release-readiness process

This directory is the reusable process. It says how any Qirsh release is assessed and decided. It holds no results.

Results for a specific release live under `docs/releases/<release>/` (for example [`docs/releases/version-1/`](../releases/version-1/README.md)). Keep the two apart: never record a test result here, and never redefine a gate inside a release folder.

## Files

| File | Purpose |
|---|---|
| [RELEASE-POLICY.md](RELEASE-POLICY.md) | Rules that apply to every release: who decides, what may never be traded away, how evidence ages. |
| [SEVERITY-AND-GATES.md](SEVERITY-AND-GATES.md) | Severity scale, finding classes, the gates, and the decision rule. Fixed before results are seen. |
| [MASTER-CHECKLIST.md](MASTER-CHECKLIST.md) | The 14 categories and their checklist items, each with a stable ID and acceptance criteria. |
| [EVIDENCE-TEMPLATE.md](EVIDENCE-TEMPLATE.md) | How a checklist result and its evidence are recorded. |
| [EXCEPTION-TEMPLATE.md](EXCEPTION-TEMPLATE.md) | How an accepted limitation is proposed and approved. |
| [RELEASE-RUNBOOK.md](RELEASE-RUNBOOK.md) | Step-by-step procedure from freezing a candidate to post-release observation. |
| [INCIDENT-AND-RECOVERY.md](INCIDENT-AND-RECOVERY.md) | What can and cannot be undone after release, and how to respond. |
| [SOURCES.md](SOURCES.md) | External sources (Apple, Google Play, OWASP, Google SRE, AWS, stack docs) with access dates and applicability. |

## How a release uses this process

1. Freeze a candidate commit and record it in the release manifest.
2. Describe the change since the last release and rate its impact per category (MASTER-CHECKLIST §0).
3. Walk all 14 categories. Depth scales with risk and change impact; a category is never skipped, but evidence from an earlier release may be reused when the reuse is justified in writing.
4. Record each item with the evidence template. Unverified is `NOT TESTED`, never `PASS`.
5. Triage findings with SEVERITY-AND-GATES, fix what is in scope, re-verify what the fix touched.
6. Have someone who did not write the fixes review the result.
7. Write the release decision per platform and combined. The owner decides; the process only recommends.
8. Follow RELEASE-RUNBOOK for the rollout, and INCIDENT-AND-RECOVERY if something goes wrong.

## Relationship to existing repository material

This process does not replace the mechanical gates; it points at them.

| Existing authority | Role here |
|---|---|
| `tools/ci_gates.sh` | The canonical automated gate (category 11). Its "truthful summary" is the evidence format for automated checks. |
| `codemagic.yaml` (`ios-signed`, `android-release`) | The only supported way to produce a store-bound artifact. |
| `tools/verify_ios_release_artifact.sh`, `tools/stamp_ios_provenance.sh` | Artifact inspection and provenance for iOS. |
| `docs/project/DECISIONS.md` | Product and privacy decisions. A release may not contradict a decision without a new decision. |
| `docs/project/MIGRATION_LEDGER.md` | What is applied in production. Must be current before a release decision. |
| `docs/legal/PRIVACY_POLICY.md`, `docs/legal/TERMS.md` | Public commitments the build must match. |
| `docs/CLIENT_RELEASE_CHECKLIST.md`, `docs/MANUAL_IPHONE_QA_CHECKLIST.md` | Older checklists. Superseded by MASTER-CHECKLIST and the per-release manual device tests; kept for history. |
| `docs/project/CURRENT_STATE.md`, `RELEASE_READINESS.md`, `RELEASE_BLOCKERS.md`, `docs/v1-release/*`, `docs/FINAL_RELEASE_READINESS*.md` | Dated snapshots (September–October 2026). Read for intent only; they are not evidence for a later commit. |

## What this process is not

It is not a certification and does not claim compliance with any standard. OWASP MASVS, Google SRE and AWS operational-readiness material are used as sources of questions sized for a small team. Review by AI agents is an extra control, not an approval.
