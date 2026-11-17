# Version 1 — release decision

**Recommendation, 2026-11-17. Not an owner decision.** Prepared by the orchestrating agent (Claude Fable 5.2) under [`docs/release-process/SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md). The owner decides; no approval or accepted limitation is recorded here because none was given.

Candidate: `af675aec` on local branch `release-readiness/v1` (audit baseline `ab5dc10a` plus 12 fix commits). See [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md).

| Scope | Decision |
|---|---|
| iOS | **NOT READY** |
| Android | **NOT READY** |
| Backend | **NOT READY** |
| Combined, for the intended launch | **NOT READY** |

The independent reviewer reached the same four decisions ([`evidence/audits/I-independent-review.md`](evidence/audits/I-independent-review.md)).

A count of passing checks does not change this: see [COVERAGE-MATRIX.md](COVERAGE-MATRIX.md) for the tally, which is informational.

## iOS — NOT READY

Open S1 blockers:

| ID | Blocker | What closes it |
|---|---|---|
| V1-001 | Declined purchases counted as spending. Fixed in code on this branch only | Deploy `process-ios-sms` (owner), build the candidate through CI, verify on a device with the manual script. The second fix has not been independently reviewed |
| V1-003 | Store privacy details and the privacy manifest's collected-data list omit data the app sends | Owner corrects App Store Connect privacy answers; engineering updates the manifest's collected-data types once the ads decision (V1-005) is made |
| V1-007 | Privacy Policy and Terms cannot be opened in-app with Cloud off, including before consenting | Owner decision: allow these two links to open with Cloud off, or show the texts in-app |
| V1-014 | iPad and landscape enabled with no decision, layout evidence or iPad screenshots | Owner decision: iPhone-only (remove the iPad device family, lock orientation) or support and test iPad |
| V1-015 | Reviewer notes describe a different app; no reviewer account or way to exercise capture | Owner: reviewer account with seeded fictional data, notes rewritten from the code |
| V1-020 | Restore then re-enabling Cloud may overwrite restored data or bring back removed rows (suspected; rated by impact) | Run the manual test; fix if confirmed |

Gates not met: G4 (no signed artifact of the candidate), G5 (no device verification at all), G6 (store requirements), G9 (owner decision). G1 is met locally: the strict gate passed 15 of 15 on `af675aec` ([TEST-EVIDENCE.md](TEST-EVIDENCE.md)); it has not run in CI.

S2 items open with no exception: V1-005 (ads undisclosed), V1-006 (deletion wording), V1-009 (no hardened store-capable pipeline — the present workflow produces internal-testing builds only), V1-012, V1-016, V1-017, V1-019, V1-026, V1-054, V1-055.

What is in reasonable shape, by code reading and tests only: consent gating of native uploads, account isolation logic, exact money arithmetic, duplicate handling, localization completeness.

## Android — NOT READY

V1-004: Android's place in Version 1 is undecided and every publishing gate is open. A release build would have no sign-in method; the Play SMS permission declaration and Data safety form are unsubmitted and stale; no release bundle has ever been built; R8 has never run on the app; Kotlin tests run in no CI; nothing has run on a device; SMS received while the app is force-stopped are lost (V1-027). Android could not be built or run in this assessment (no Java, no `adb`).

**Recommendation to the owner: record Android as OUT of Version 1** and plan it as its own release. That turns V1-004 from a blocker into a recorded scope decision and removes Android from the combined decision. This is a proposal; it is not decided.

## Backend — NOT READY

| ID | Blocker | What closes it |
|---|---|---|
| V1-002 | Production migration state unknown for about 32 migrations, including those account deletion depends on | Operator runs the read-only checks in [RELEASE-PLAN.md](RELEASE-PLAN.md) and records the result |
| V1-001 (server part) | Server still accepts declined purchases until `process-ios-sms` is redeployed | Owner-authorized deploy |

Gate G7 not met: production state unknown; backup and point-in-time-recovery status unrecorded (V1-023); no written, rehearsed deploy order (V1-021 — a proposed order is now in the release plan, unrehearsed); no backend monitoring (V1-024); no ceiling on AI spending (V1-022).

The backend code at the candidate differs from what build 147 was built against only in `process-ios-sms`.

## Combined — NOT READY

The combined decision is the worst of the platforms in scope and the backend they depend on. With Android out of scope it is still NOT READY on iOS and backend.

## Proposed limitations (not accepted)

If the owner wishes to ship with any S2 or S3 item open, each needs a signed exception. Candidates the orchestrator would propose once the S1 blockers are closed: V1-025 (admin advisories, with the panel kept off the public internet), V1-031, V1-032, V1-033, V1-040, V1-043, V1-047, V1-050, V1-051, V1-056, V1-057, and the interface items in [KNOWN-LIMITATIONS.md](KNOWN-LIMITATIONS.md). No exception record has been written, because nobody has agreed to anything.

## Decisions required from the owner

1. **Android**: in or out of Version 1 (V1-004). Recommendation: out.
2. **iPad**: iPhone-only or supported (V1-014). Recommendation: iPhone-only for Version 1.
3. **Ads at launch**: ship with AdMob able to be enabled, and disclose it in the privacy policy, consent text and store declarations; or ship with ads unconfigured and say so (V1-005). Recommendation: no ads at launch, with the store declarations still covering the SDK that is in the binary.
4. **Account deletion wording**: change the policy to match immediate permanent deletion, or change the app to the 30-day scheme (V1-006). Recommendation: change the policy.
5. **Policy and Terms with Cloud off** (V1-007). Recommendation: let those two fixed URLs open, or bundle the texts.
6. **Consent withdrawal**: change the sentence to say both are withdrawn together, or add separate controls (V1-017). Recommendation: change the sentence.
7. **Countries offered in onboarding** versus the two the bank catalog covers (V1-019).
8. **Sign-in providers** for the store build and their production variable values (V1-016).
9. **Export compliance** answer given the app's own backup encryption (V1-026) — may need legal advice.
10. **Lock-screen detail** in capture notifications (V1-036); **signed-out Shortcut captures** (V1-037); **language preselection** (V1-044); **shared category learning default** (V1-048); **unreachable features** shipped in the binary (V1-042).
11. **Admin panel**: major Next.js upgrade, or a written constraint that the panel is never internet-exposed (V1-025).
12. **A store-capable build pipeline**: harden `ios-signed-release`, or re-point `ios-signed` at a release branch with App Store export (V1-009).
13. **A review list for declined purchases already stored** (V1-056).

## Actions required from the owner or operator

In order:

1. Run the read-only production checks (migration ledger, deployed functions, flags, cron, secrets presence, backup/PITR tier) and record the results. Closes or confirms V1-002 and V1-023.
2. Make decisions 1–6 above; they unblock the store and policy work.
3. Review and, if acceptable, push `release-readiness/v1` and merge it into the release branch. Nothing has been pushed.
4. Authorize the backend steps in the release plan, including the `process-ios-sms` deploy.
5. Produce a CI build of the merged commit and install it on physical iPhones; run [MANUAL-DEVICE-TESTS.md](MANUAL-DEVICE-TESTS.md), starting with the declined-purchase, consent-revocation, upgrade-from-147 and restore-then-Cloud tests.
6. Confirm the privacy-manifest reason codes against Apple's required-reason API list.
7. Correct App Store Connect: privacy details, review notes, reviewer account, screenshots, export compliance.
8. Fill the blanks in the release plan: incident owner, contact path, observation windows, thresholds.
9. Re-run this decision when the above is done. Evidence gathered now expires for any code that changes.

## Actions not performed in this assessment

No push, merge, production deploy, production configuration or data change, migration, function deploy, TestFlight upload, App Store or Play submission, console change, purchase, or account creation. Nothing was written to any external system. External reads were `git fetch`, GitHub check-run and event queries, package downloads, public web pages for the standards research, and one Codemagic build log opened with the owner's sign-in.
