# Version 1 — audit report

Summary of the specialist audits, the remediation, and the independent review. Detail, file-and-line evidence and reproduction steps are in the reports under [`evidence/audits/`](evidence/audits/). The consolidated register is [ISSUES.md](ISSUES.md).

## How the audit was run

| Step | Who | Output |
|---|---|---|
| Discovery and baseline | Orchestrator (Claude Fable 5.2) | [PROGRESS.md](PROGRESS.md), [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md), baseline gate log |
| Standards research | AI agent, `claude-opus-5-5` | [`docs/release-process/SOURCES.md`](../../release-process/SOURCES.md) |
| A Product scope and functional coverage | AI agent, `claude-opus-5-5` | `evidence/audits/A-product-scope.md` — 18 findings |
| B Data integrity and financial correctness | AI agent, `claude-opus-5-5` | `B-data-integrity.md` — 8 findings |
| C iOS | AI agent, `claude-opus-5-5` | `C-ios.md` — 12 findings |
| D Android | AI agent, `claude-opus-5-5` | `D-android.md` — 12 findings |
| E Security and privacy | AI agent, `claude-opus-5-5` | `E-security-privacy.md` — 14 findings |
| F Backend, admin and operations | AI agent, `claude-opus-5-5` | `F-backend-ops.md` — 13 findings |
| G UI/UX and accessibility (on simulators) | AI agent, `claude-opus-5-5` | `G-ui-ux.md` — 23 findings, 40 screenshots |
| H Test quality, artifact and store readiness | AI agent, `claude-opus-5-5` | `H-tests-artifact-store.md` — 21 findings |
| Fixes | AI agents `claude-opus-5-5` with disjoint file ownership; orchestrator reviewed every diff, added three fixes itself, and made all commits | [CHANGELOG.md](CHANGELOG.md) |
| I Independent review | AI agent `claude-opus-5-5` that wrote no fix and no audit | `I-independent-review.md` — 18 findings |

Every agent stated the model identifier it observed; all reported `claude-opus-5-5`. The orchestrator cannot verify a model identity beyond the agent's own statement and the tool's `opus` selection. No human reviewed anything.

Audits A–F and H read code at `ab5dc10a` and ran only narrow checks. Audit G drove the app on two iOS 26.5 simulators. Nothing ran on a physical device, on Android, against production, or in a store console.

## What the audits established as sound

Stated by the audits from code reading and targeted tests; not device evidence.

- Money is held in integer minor units; totals are exact and separated by currency; refunds and transfers are handled; Arabic-Indic digits and separators parse (B).
- Duplicates go to review instead of being dropped; a pending local edit is never overwritten by a pull; manual category choices survive pull, import and restore (B).
- No native iOS path sends message content off the device without re-checking owner, consent and in-flight registration immediately before the request; withdrawing consent cancels uploads; the share extension cannot make network calls (C).
- Android declares only `RECEIVE_SMS`; a granted permission alone never starts capture; the disclosure precedes the permission dialog; backups and device transfer are disabled; no signing secrets are committed (D).
- No path was found that sends message text, amounts or merchant names without the required consent; every table has row-level security; all `SECURITY DEFINER` functions pin `search_path`; the profile-photo bucket is owner-only; no committed secrets (E).
- November migrations are additive behind capability keys with no destructive statements; worker endpoints refuse without their secret; every admin route checks authorization; push auto-retry cannot double-send (F).
- Debug-only screens are unreachable in a release build; Arabic and English each have 2092 keys with none missing (A).

## What the audits found

Counts as reported by each audit before consolidation: S1 6, S2 32, S3 54, S4 29 (121 findings, including 23 UI). After deduplication, re-rating by the independent review and new findings: see [ISSUES.md](ISSUES.md) — 8 S1, 21 S2, the rest S3/S4.

The findings that matter most:

1. **Wrong money**: declined purchases counted as spending (V1-001, reproduced end to end).
2. **Unknown production state**: nobody can say which of about 32 migrations are applied, including ones account deletion depends on (V1-002); backup and recovery posture unrecorded (V1-023); no deploy order (V1-021).
3. **Store and policy mismatches**: privacy disclosures omit data the app sends (V1-003); ads are in the binary but not in the privacy policy (V1-005); the policy describes 30-day undoable deletion while the app deletes at once (V1-006); the policy and terms cannot be opened in-app with Cloud off (V1-007); reviewer notes describe a different app and there is no reviewer path for capture (V1-015); iPad is enabled without screenshots (V1-014); export compliance answer unconfirmed (V1-026).
4. **No store-capable hardened build pipeline** for iOS (V1-009), and Android has never produced a release build or run on a device (V1-004).
5. **Test coverage that looked better than it was**: six suites never ran in any CI (V1-011); native tests and backend behavior run in no gate (V1-012, V1-013).

## Disagreements between reviewers and how they were resolved

| Topic | Positions | Resolution | Basis |
|---|---|---|---|
| Sync conflict timezone | H: S2. B: S4 latent | S3, fixed | B showed no current writer emits a zone-less timestamp and the diff is display-only; H reproduced the function only |
| Consent withdrawal | E: each consent withdraws separately. A: only together | Together | `privacy_screen.dart` withdraws both in one call |
| Disk-space reason code | Audit suggested "check space before writing"; fixer used "display to user" | Fixer's choice kept, flagged for confirmation | The app never changes behavior on disk space; the value appears only on a debug-only screen |
| Edge Function count | 33 vs 34 | 33 | Directory count |
| AdMob in `ios-signed` | A: values passed. E: group not attached | Both true: the workflow has the define lines but does not attach the `admob` group, so the values are empty there | `codemagic.yaml` |
| First declined-transaction fix | Fixer: fixed. Reviewer: not closed | Not closed; second fix made | Reviewer's probe produced a stored refund from a declined message |
| Failing removal suite | Reviewer: real failure on a critical journey | Harness limit, not a removal defect; coverage gap remains (V1-054) | The same seven tests pass unconfigured; the file never passed under the synthetic defines at three earlier commits |
| Admin advisories | Fixer: "2 vulnerabilities". Reviewer: understated | 25 advisories on `next` (3 critical, 9 high); 2 is the affected-package count | `npm audit --json` |

Agreement between agents was not treated as proof. Where no evidence settled a point it is recorded as SUSPECTED or UNKNOWN.

## Remediation

Twelve local commits; see [CHANGELOG.md](CHANGELOG.md). Fixed in code: V1-001 (not closed — needs deploy, build and device), V1-008, V1-010, V1-011, V1-018, V1-028, V1-029, V1-030, V1-034, V1-039, V1-041, V1-049, and thirteen UI findings. Partly: V1-025.

Not attempted, because they need an owner decision, production access, a store console, a device, or are larger than release hardening: everything else in the register.

## Independent review

The reviewer accepted one commit outright and the rest "with follow-up", rejected the claim that V1-001 was closed, re-rated four findings to S1, found six suites that never ran, corrected the admin advisory count, and found the records stale. Addressed: second declined-transaction fix (`668f4d64`) plus the relay-import check; gate stage for the define-gated suites (`29cb1819`); image optimization off in the admin (`f6dc5076`); re-ratings applied; records refreshed; an iOS simulator build and launch at `f6dc5076`. Not addressed: everything that needs a device, a deploy, a console or a decision.

The second declined-transaction fix has **not** been independently reviewed. Its residual errors are those its own author reported ([KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md)).

## Limits of this audit

- No physical device, no Android build or run, no signed build, no CI build of the candidate.
- No production access: deployed schema, functions, flags, secrets, cron, backups are unknown.
- No store console access: actual privacy answers, declarations, screenshots and reviewer notes are unknown.
- Apple's required-reason API pages could not be fetched; reason codes are from model knowledge.
- Journeys past onboarding were not exercised on a running app, because a build without backend configuration cannot complete onboarding.
- All review was done by AI agents. This is not a certification and makes no compliance claim.
