# Release runbook

The procedure for taking a Qirsh candidate from "frozen" to "observed in production". Steps marked **OWNER** need the owner's explicit authorization each time; a previous authorization does not carry over.

Qirsh ships four separately deployed parts: the Postgres schema (`supabase/migrations`), Edge Functions (`supabase/functions`), the admin panel (`admin/`), and the mobile apps. Installed mobile apps cannot be recalled, and device databases migrate forward only, so order and compatibility matter more than speed.

## Stage 0 — Freeze

1. Pick the candidate commit. Confirm the working tree is clean and the commit is on the remote release branch.
2. Start the release folder `docs/releases/<release>/` and record commit, last released build, and the diff range in `RELEASE-MANIFEST.md`.
3. Write the change-impact table (MASTER-CHECKLIST §0).

Check: gate G0.

## Stage 1 — Automated gates

1. From the repository root, with production credentials absent from the environment:
   `env -u SUPABASE_URL -u SUPABASE_ANON_KEY -u SUPABASE_SERVICE_ROLE_KEY REQUIRE_ALL_GATES=1 bash tools/ci_gates.sh`
2. Save the log. Quote the "truthful summary" block in the test evidence.
3. If Flutter cannot resolve packages on a development machine, check `PUB_CACHE` points at a mounted path before treating it as a code failure.
4. Run the timezone-sensitive suites under both the local zone and `TZ=UTC` when sync or date code changed.

Check: gate G1. A failure here stops the release until fixed; do not skip stages.

## Stage 2 — Audit, triage, fix

1. Walk the 14 categories. Record results with the evidence template.
2. Register findings; deduplicate; assign severity with SEVERITY-AND-GATES.
3. Fix in small batches in priority order (data loss → cross-account → consent → financial → core journeys → reliability → accessibility → polish). Add a regression test for each substantive defect.
4. After each batch: impact assessment, re-run affected checks, update the records.
5. Any change to the candidate moves the frozen commit. Record the new commit and which evidence was invalidated.

Check: gates G2, G3.

## Stage 3 — Backend readiness (read-only)

1. **OWNER / operator**: run the production comparison queries from the release's `RELEASE-PLAN.md` (migration ledger, deployed function list, flag values, cron jobs, presence of required secrets). Record the output with secrets redacted.
2. Update `docs/project/MIGRATION_LEDGER.md`.
3. For every migration not yet applied in production: review locks, destructiveness, idempotency; rehearse on a local stack or a copy. Never against production data.
4. Confirm each backend change is compatible with every installed client build, or name the forced-update mechanism and its evidence.

Check: gate G7.

## Stage 4 — Deploy backend (OWNER, each step)

Order: **database → functions → admin → mobile**. Each step is additive first (expand), with removal of old shapes deferred to a later release (contract).

1. Database: apply pending migrations in ledger order. After each, run its verification query. Stop on the first failure; do not continue past a failed migration.
2. Functions: deploy the changed functions. Smoke-test each with a non-production test account.
3. Flags: leave new features off until the mobile build that needs them is in testers' hands, unless the feature is server-only.
4. Admin: deploy; sign in; confirm authorization on one restricted route.
5. Observe for the release's stated window before shipping mobile.

Between steps, old clients must keep working. If they do not, stop and apply the recovery path in INCIDENT-AND-RECOVERY; do not push forward.

## Stage 5 — Build and verify the artifact

1. iOS: the Codemagic `ios-signed` workflow on the release branch builds, verifies and uploads the IPA. It requires `EXPECTED_REVIEWED_CI_SHA` to equal the frozen commit and resolves the build number from App Store Connect. The upload makes the build available to **internal** TestFlight testers only; external testing and App Store submission are separate, owner-authorized actions.
2. Android: the `android-release` workflow builds the signed App Bundle. Play upload is a separate, owner-authorized action.
3. Record version, build number, commit, CI build URL, IPA/AAB hash and the verification output in the manifest.
4. Inspect the artifact (identifiers, entitlements/permissions, endpoints, flags, absence of debug capability and secrets).

Check: gate G4.

## Stage 6 — Device verification

1. Install the Stage 5 artifact on physical devices for each platform in scope.
2. Run the release's `MANUAL-DEVICE-TESTS.md`, including upgrade from the previous build over real data.
3. Record device, OS, build, tester, date, and result per step. Failures become findings.

Check: gate G5.

## Stage 7 — Store readiness

1. Walk the store items (category 12) in the consoles. Confirm live legal URLs match the repository text.
2. Prepare review notes and reviewer access.

Check: gate G6.

## Stage 8 — Independent review and decision

1. Independent reviewer challenges blockers, fixes, stale evidence, untested journeys, weakened tests, and mismatches between UI, behavior, policy and store declarations.
2. Address supported findings; re-verify.
3. Write `RELEASE-DECISION.md`. **OWNER** decides and signs exceptions.

Check: gates G8, G9.

## Stage 9 — Rollout (OWNER)

1. Internal testers (TestFlight internal / Play internal track). Observe the window.
2. Limited external audience (TestFlight external after Beta App Review / Play closed or open testing).
3. Store release with phased rollout where the store supports it (App Store phased release; Play staged rollout percentages).
4. At each step check the stop conditions before widening.

## Stage 10 — Observe and close

1. Watch the signals and thresholds from the release plan for the stated window.
2. Record what was observed. Open follow-ups for exceptions.
3. Mark the release folder final. Later changes go in a new release folder.

## Stop conditions (defaults; a release may add its own)

Stop widening, and assess, on any of:

- A report of lost, duplicated or wrong financial data.
- A report of one account seeing another's data.
- Evidence of transmission without consent.
- Crash-free sessions below the threshold in SEVERITY-AND-GATES.
- Function error rate or push/AI failure rate clearly above the pre-release baseline.
- A store rejection or policy notice.
