# Version 1 — known limitations

Limitations that exist at the candidate `af675aec`. **None of these has been accepted by the owner.** Each is a proposal: to ship with one, the owner signs an exception record ([`EXCEPTION-TEMPLATE.md`](../../release-process/EXCEPTION-TEMPLATE.md)). S1 items cannot be accepted as limitations and are listed in [RELEASE-DECISION.md](RELEASE-DECISION.md) as blockers, not here.

## Declined-transaction detection (V1-001 residuals)

The rule is deliberately small and explainable. What it still gets wrong, as reported by its author and not independently re-tested:

| Input class | Result today | Direction of error |
|---|---|---|
| "Refund of SAR 99 failed" (a failed refund) | Stored as a refund | Wrong amount in the user's favor |
| "voided", "not authorised" | Not recognised; stored as a payment | Overstates spending |
| A conditional marker before the status in the same sentence ("If …, retry: purchase declined") | Not recognised | Overstates spending |
| A cue later in a merchant name or after "to" ("at The Failed Co", "to Failed Co") | Sent to Smart Inbox review | Real purchase waits for the user |
| Advisory text without a listed marker ("Declined transactions incur no fee.") | Sent to Smart Inbox review | Real purchase waits for the user |
| Vowel-marked Arabic forms in the notification preview only | Preview shows a detailed notification | Cosmetic |

Also:

- **Transactions stored before the fix are not corrected** (V1-056). A declined purchase already saved stays counted until the user deletes it. There is no list that helps the user find them.
- **Installed builds are not protected.** TestFlight 147 and older parse on the device with the old rules. After the server is redeployed, those builds re-parse a server-rejected message locally and still confirm it.
- **Pre-existing type errors remain**: the app types "تم استرجاع …" as a payment, and the server reads "Reversal of declined purchase" as a debit. Recorded in the shared test cases, not changed.

## Capture and parsing

- A message with no currency is confirmed in the account's currency in the default flow (V1-031). Owner decision.
- The account "current balance" is not derived from transactions (V1-032). Owner decision on what the figure means.
- On-device AI amount check does not treat the Arabic comma as a thousands separator (V1-057).
- iOS: a Shortcut capture while signed out is dropped silently (V1-037); shared text that also carries a link may be filed under Offers (V1-038, suspected).
- Amount, merchant and card last-4 appear on the lock screen by default (V1-036). Owner decision.

## Backup, restore and sync

- Restore followed by re-enabling Cloud is not reconciled (V1-020 — rated S1 SUSPECTED, listed as a blocker until tested).
- No real upgrade fixtures for device schema versions 27–42 (V1-033); upgrade from build 147 is covered only by the manual device script.
- Data removal through startup is not tested in a configured build (V1-054).
- Cloud backup passphrase minimum is 6 characters (V1-046); the screen that sets it is currently unreachable (V1-042).

## Updates and versioning

- Forced update and update notices compare the marketing version only, so two builds of 1.0.0 cannot be told apart, and the app does not expose its build number (V1-040). A force-update row with a malformed version bound fails open on device; the server applies the same rule before sending it.
- Users with Cloud off never receive a force-update notice (V1-045).

## Interface and accessibility

- Text size is capped at 1.25× app-wide (UX-09). Above it, the details pill and "Budget history" break on a 320 pt screen. Recommendation: keep the cap for Version 1 and fix layouts after.
- Still under 44 pt: Subscriptions filter chips, budget-form period chips, Settings "Edit" (UX-05).
- The "On track" chip is 4.02:1 against the shared brand green (UX-07). Changing the brand color is an owner decision.
- The app-switcher cover appears once the app is in the background, so the live screen can still be visible while the app switcher opens (REV-08). Covering earlier changes when the cover shows — owner decision.
- Not exercised on a running app: the signed-in shell and tab bar, sign-out and delete confirmation, restore, the Privacy screen, offline and permission-denied states, VoiceOver focus order.

## Backend and operations

- AI spending has no global ceiling (V1-022); model and prompt versions are not recorded per result (V1-058).
- No backend monitoring or alerting (V1-024).
- Server consent on the user-token path is per account, not per device (V1-047).
- Engagement triggers make two HTTP calls per transaction write; migration 0104's backfill takes strong locks on 17 tables in one transaction (V1-050).
- Several remote flags shown in the admin panel are read by no code (V1-043); there is no server-side switch for the AI or capture endpoints.
- Admin panel: 25 advisories remain on Next.js 14.2.35 (3 critical, 9 high) with no fix on 14.x (V1-025). Mitigated by removing remote image hosts and turning off image optimization. Keep the panel off the public internet until a major upgrade.

## Build and test

- Native tests (194 iOS XCTests, Android Kotlin) run in no CI (V1-012). No gate executes row-level security, RPCs or migrations (V1-013).
- The skip gate can still be bypassed by a platform restriction, an excluded tag, or an early return inside a test.
- Two unconditional skips in `adversarial/session_recovery_attack_test.dart` never run anywhere.
- The CI revision check is self-attested and there are no GitHub Actions runs as independent evidence (V1-051).
- The zone-less timestamp regression test cannot fail on a UTC host; run the sync suites under a non-UTC zone as well.

## Documentation

`docs/project/CURRENT_STATE.md`, `FEATURE_MATRIX.md`, `RELEASE_READINESS.md`, `RELEASE_BLOCKERS.md`, `MIGRATION_LEDGER.md`, decisions D-13, D-14 and D-19, `docs/v1-release/*` and `docs/FINAL_RELEASE_READINESS*.md` describe September–October 2026 and contradict the code in places. They were not rewritten in this assessment; treat them as history.
