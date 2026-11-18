# Version 1 — changes made during release readiness

Changes on the local branch `release-readiness/v1` after the audit baseline `ab5dc10a`, up to the candidate **`a157e68e`** ([RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)): 46 commits in `git log ab5dc10a..a157e68e` across three rounds. None is pushed, built by CI, signed, deployed, or on a device. Build 147 contains none of them. Issue IDs refer to [ISSUES.md](ISSUES.md); UX IDs to [UI-UX-REVIEW.md](UI-UX-REVIEW.md); finding IDs to [REVIEW-CLOSURE.md](REVIEW-CLOSURE.md). Rounds 1 and 2 are kept as written; round 3 is at the end.

# Round 1 (`64e571e5` … `af675aec`)

## Money correctness

- **Declined purchases are no longer recorded as money movements** (V1-001; `d35fc044`, `668f4d64`). A bank message reporting a declined, failed, rejected, cancelled or unsuccessful transaction used to be saved as a confirmed payment and counted in monthly spending, budgets and reports. Now, on the device, such a message goes to Smart Inbox for review; consented AI is not asked about it and the AI validator rejects it; the server parser rejects it; the notification preview does not announce it as a purchase; and both client paths that import server results refuse to import it as a confirmed row. A refund or reversal of a failed purchase is still a credit (changed in round 2: it now goes to review). The first version of this fix was rejected by the independent review (a refund word anywhere switched detection off and one case was stored as a refund; common wordings were missed; merchant names and footers caused false alarms); the second version addresses those with 69 synthetic cases shared by the device and server tests.
  *Takes effect only with a new app build and an owner-authorized deploy of `process-ios-sms`. Does not change transactions already stored.*
- **A bank-message date without a year no longer lands in the future** (V1-029; `d35fc044`). "31/12" processed in November used to become 31 December of the current year.
- **An AI-proposed amount must match a whole number in the message** (V1-030; `d35fc044`). Previously a fragment of a card number or balance counted as a match.

## Privacy and platform requirements

- **iOS privacy manifests declare the required-reason APIs actually used** (V1-008; `d70ba396`): disk space in the app and the share extension, file timestamp in the extension, App Group defaults. Reason codes come from model knowledge and must be checked against Apple's list before upload.
- **The app-switcher privacy cover runs under the scene lifecycle** (V1-034; `d70ba396`). It was attached to callbacks a scene-based app never receives. Compiled and launched on a simulator; the cover itself was not observed in the app switcher.

## Truthful text and state

- **Help matches behavior** (V1-018, V1-041; `2f2c4707`): the ZIP export is described as not password-protected, and Help no longer says every capture waits for confirmation.
- **A cached force-update notice no longer blocks a build it does not target** (V1-039; `7597bb42`).
- **Sync conflict dates do not depend on the device timezone** (V1-028; `ff1fc292`).

## User interface and accessibility (`23499229`, `af675aec`)

- Manual add no longer pre-selects the budget-only "All expenses" category; the user picks a category and the existing validation applies (UX-01).
- Screen-reader labels on the add buttons of Transactions and Bills and on ten sheet close buttons (UX-03, UX-04).
- 44 pt targets for header search and add, planning tabs and the details pill (UX-05, partly).
- Page titles and budget chips no longer break mid-word or truncate on a small screen at large text (UX-06, UX-08); the change-category pill wraps instead of overflowing (UX-10).
- Photo-header subtitle and two hint texts raised above 4.5:1 contrast (UX-07, partly).
- Reports overview shows the existing tip card instead of an empty area (UX-12); Arabic strings use Western digits consistently (UX-13); capture status uses neutral styling before any capture (UX-16); the restore illustration respects Reduce Motion (UX-17); brand tagline centred (UX-18).

## Build, tests and tooling

- **Every CI build passes a real app version** (V1-010; `64e571e5`). Three workflows passed an empty version; an unresolved version now fails the build.
- **Skipped Flutter tests are counted and the define-gated suites run** (V1-011; `64e571e5`, `29cb1819`). 38 skip sites are matched against the skip manifest; a new mandatory gate stage runs six suites (143 tests) that no CI had ever run.
- **Admin panel** (V1-025; `f9c5be75`, `f6dc5076`): Next.js 14.2.29 → 14.2.35, unused remote image hosts removed, image optimization turned off. Advisories that have no fix on 14.x remain.
- **Push auto-retry rollback runbook corrected** (V1-049; `f9c5be75`); it now says the rollback is unrehearsed.

## Tests that were changed, and why

| Test | Change | Reason |
|---|---|---|
| `engine/parser/meridiem_time_test.dart`, `engine/parser_engine_test.dart` | Pass a fixed processing time | They asserted the old year-less date behavior and would fail depending on the calendar date |
| `ios/ios_privacy_manifest_test.dart` | Asserts the new, larger set of declarations derived from the Swift sources | The old expected set was the defect |
| `features/dashboard/home_redesign_render_test.dart` | Expects a Western digit | It asserted the Arabic-Indic digit that UX-13 corrects |
| `features/onboarding/story_screen_test.dart` | Expects Western digits in the page label (`af675aec`) | Same reason; the full gate caught it after the UI commit |
| `features/transactions/txdetail_money_validation_test.dart` | Scrolls the button into view before tapping | The pill above it grew 8 pt |
| `features/reports/reports_details_render_test.dart` | Scopes one check to the details list | The summary card now stays built |
| `core/startup/bootstrap_remove_data_integration_test.dart` | Comment only | Records that its first group targets an unconfigured build |

No assertion was removed to make a test pass, no test was skipped, and no threshold was lowered.

# Round 2 (`0de54a2b` … `50957c06`)

The final parser commit `50957c06` was reviewed by reviewer R: **ACCEPT WITH FOLLOW-UP** — no S1, and nothing worse than the audit baseline on the device or the effective iOS-Cloud path; open defects carried from the baseline remain (RR-01) and more correct messages wait for review. The parser commit before it, `75dab61a`, was **rejected** by reviewer Q. V1-001 stays S1 OPEN (REVIEW-CLOSURE.md, ISSUES.md).

## Money correctness

- **More not-completed messages change no total** (V1-001; `0de54a2b`, `84f2fe41`, `42a0fd0c`, `1be44623`, `c8cef416`). Added, on device and server alike: failed and declined refunds; voided, not authorised, timed out, expired; pending, held and blocked amounts; failed cash withdrawals, transfers and bill payments; future statuses that name an amount; a status after a report header or before a question clause; five more failed-payment wordings in `c8cef416`. The shared synthetic case table grew from 69 to 104, 127, 177, 353, 566, 803, 1,315 and **1,565** cases; from `5583cbea` on it includes the reviewers' probes with hand truth, and from `75dab61a` on it checks amount, currency (where given) and direction. Reviewer R measured, on the effective path with a bank sender, declined or not-completed messages recorded as money falling from 174 at the baseline to 4. This is not complete coverage of bank wording, and each independent review found more (REVIEW-CLOSURE.md).
- **Two regressions were introduced and then removed.** The fifth parser commit `42a0fd0c` (a) read "Merchant declined …" as a merchant name, so such a message was recorded as a payment (LR-01), and (b) on one iOS import path confirmed the device's opposite reading when the server's direction disagreed (LR-03). Both were removed in `1be44623`, and review N confirmed the removal at that commit.
- **A third regression was introduced and then answered.** The sixth parser commit `1be44623` treated credit-limit, activation, renewal, statement and PIN wording as "not a transaction", which silently dropped completed purchases, fees, salaries and refunds that merely carried such a line (NR-01, S1), and made the AI validators reject correct candidates (NR-02). Review N rejected that commit. `c8cef416` changes the rule so these words count only when the message has no money word, and then the message goes to review on the device instead of disappearing. Reviewer O confirmed the bulk fix (silent drops on the golden layouts 320 → 0) but found 3 completed movements still silent on every path (OR-01, S1, V1-077), and the server now ignores 17 completed movements the device recovers (OR-02, V1-071). The notice rule returns notices with a money word to their `0095a239` state: 31 of 44 are still recorded as money (OR-04, V1-072, re-rated S1).
- **Round 8 (`5583cbea`): a limit, balance or code figure is never the amount.** This fixed a defect that existed at the baseline and that no audit had found: a credit-limit or balance figure was taken as the transaction amount, so an 8 SAR purchase could be recorded as 9,000 (OR-03). A figure introduced by a limit, balance, remaining, due or code label is no longer an amount on device or server, and an AI amount equal to such a figure is rejected. On both iOS import paths a server amount that differs from the device's own reading is no longer confirmed. A notice became silent only when it had no amount with a currency. Every completed shared case gained an expected amount, and deviating rows were pinned. Reviewer P accepted it with follow-up but found three outcomes worse than the baseline: incoming credits with a limit line pre-filled as payments (PR-01, introduced here), 25 of 182 completed messages with an unlisted currency form silent on every path (PR-02), and a received standing order confirmed as a payment (PR-04, carried from `1be44623`).
- **Round 9 (`75dab61a`) — rejected by independent review.** It made informational words unable to silence any message (only the original ignore set can), matched currency codes as whole words, added credit wordings and a cash-deposit rule, distrusted a server direction the wording contradicts, and let a labelled figure be the amount when a completed-movement verb acted on it. Reviewer Q **rejected** it: under the server's earliest-word rule the new credit words turned outgoing transfers, fees and wages paid out into **confirmed income** (QR-01, S1); the deposit rule and the verb-after-figure rule produced wrong directions and amounts on the device (QR-02); some notices became confirmed money (QR-03).
- **Round 10 (`50957c06`) — removes round 9's additions.** The credit words, the broad deposit rule and the verb-after-figure rule were taken out, together with round 8's added money-word list; direction and type went back to round 8. An inflow phrase with no other direction evidence now sends the message to review instead of recording income, and a figure in a due-or-scheduled clause goes to review. Round 9's sound parts stay: informational words never silence a message, and currency codes match whole words. Reviewer R: no S1; no regression from this commit on the device or effective path; nothing worse than the baseline there. On R's 1,758 synthetic messages, wrong total-changing outcomes on the effective path with a bank sender fell from 509 at the baseline to 71. The cost is review volume (below).

User-visible behavior at the round-2 code (`50957c06`), once a new build and the server deploy are in place (none of it is on build 147 or the deployed server):
- A limit, balance or code figure is never recorded as the amount.
- More messages wait in the Smart Inbox for the user to confirm: up to about 15% of correct completed messages on R's probe set (0% on the repository corpus), mostly ones with a notice footer, a label-led amount, a code or a less common verb; with AI consent, 353 of 1,306 correct AI candidates are rejected and kept for review. No total changes because of this, but spending and income stay understated until the user acts (V1-085, V1-086; owner decision B29).
- Currency codes are matched as whole words, which fixed misreadings such as "Mada" and "Saudi Riyals" taken as currency codes (Q: 14 currency fixes, 0 regressions on 59 probes).
- Informational words (limit, activation, statement, PIN …) never make a message disappear.
- Still wrong, as at the baseline: 34 notices recorded as money, 18 wrong directions, 8 own-account transfers counted, 6 foreign-currency figures recorded instead of the amount charged (RR-01; KNOWN-LIMITATIONS.md §1.1).
- **Promotions are not credits; plain refunds are read** (`84f2fe41`). An amount after "up to" is no longer taken as a credit; "Refund SAR 99 from SHOP" is read on the device.
- **Ignore words match whole words** (FR-13; `42a0fd0c`, `1be44623`). A purchase at "Hotpot" was dropped because it contains "otp"; an ignore word inside a merchant name ("Offer Mart") no longer drops the purchase; a security footer on a readable transaction sends it to review. Still open: V1-071.
- **One-time-code messages are kept away from AI** (LR-06; `1be44623`), and the code pattern was tightened in `c8cef416` after it matched real purchases (NR-06; confirmed by O). Codes without an `OTP` word were still recorded as payments at `c8cef416` (OR-05, pre-existing); since `5583cbea` they go to review and a code is never the amount (V1-079; reviewer P), at the cost of some genuine purchases that mention a code also going to review (PR-05).
- **The server AI fallback grounds its amount** (V1-060; `0de54a2b`). `parse-sms` drops a model amount that is not a whole number in the message. **Arabic comma** accepted as a thousands separator on device and server (V1-057; `0de54a2b`).

Behavior changes a user or the owner would notice:

| Change | Before | After | Commit |
|---|---|---|---|
| Refund or reversal of an original that was declined (never counted) | Recorded as a refund, reducing spend | Goes to review; no total changes. DECISIONS-NEEDED B2 lists this as an open owner question | `42a0fd0c` |
| "Purchase … reversed" | Recorded as a payment | Goes to review | `84f2fe41` |
| Server type for refund wording | `income` | `refund` (nets against spend). Build 147 already understands `refund` (K §A3); applies to future captures only after a `process-ios-sms` deploy | `0de54a2b` |
| Server and device read a message in opposite money directions | The server's result was imported (one path briefly took the device's reading, LR-03) | Goes to review on both iOS import paths | `42a0fd0c`, `1be44623` |
| A server result the device ignores | Imported | Not confirmed | `1be44623` |
| A limit, balance, remaining, due or code figure in the message | Could be recorded as the amount (e.g. 9,000 for an 8 SAR purchase) | Never the amount; the message is read from its own amount or goes to review | `5583cbea` |
| A server amount that differs from the device's own reading | Imported | Goes to review on both iOS import paths | `5583cbea` |
| A message with an informational word (limit, activation, statement, PIN) | Could be dropped with no Smart Inbox card (rounds 6–8 only; never in a distributed build) | Never silenced by such a word | `75dab61a`, kept in `50957c06` |
| An incoming-money phrase with no other direction evidence | Recorded by the device's default (often payment) | Goes to review | `50957c06` |
| A figure in a due or scheduled clause | Could be recorded as money | Goes to review | `50957c06` |
| Correct messages carrying a notice footer, a label-led amount, a code or a less common verb | Recorded | Often wait in review (R: up to about 15% of baseline-correct probe messages; 0% on the corpus) | `5583cbea`, `50957c06` |
| Pasting a declined payment (single message) | "Could not be read — add it manually" | "Declined or not completed — nothing was recorded". Batch paste still says "Not understood" | `0095a239`, `1be44623` |
| Restore with Cloud on | Restored rows lost their server identity; device and cloud stayed different, and a configured build duplicated rows | Identity kept; restored rows pushed; pull cursors reset. Cloud rows absent from the backup are kept and pulled back (merge default; replace-vs-merge is owner decision B10). The confirmation text still says "replace" (V1-070) | `0f90003f` |

Not protected: rows already stored; installed builds (147 and older); the deployed server until `process-ios-sms` and `parse-sms` are redeployed. The server at the round-2 code must ship together with the new build: alone it rejects 21 completed messages that only the new device build keeps for review (V1-087, V1-088).

## Sign-in and navigation

- **The tab bar comes back after signing in with a sheet open** (RT-01, V1-065; `45ea901a`). Confirmed on a simulator for email sign-in with a control build reproducing the defect (file M). Build 147 has the defect.
- **Arabic code-screen sentence** in Modern Standard Arabic (RT-05; `0095a239`).

## Restore and sync

- **Executable reproduction of restore then cloud sync** (V1-020; `8e953d14`), against a local Supabase stack; skipped unless `LOCAL_SUPABASE_URL` is set.
- **Restore keeps server identity** (V1-020; `0f90003f`) for 12 entity types; no schema or backup-format change; guest restore unchanged. The local-stack test failed before and passes after.

## User interface and accessibility (`34ccc9e9`)

- 44 pt hit areas for chips, section links, the range control and Settings controls on the ten primary screens, at the same visual size (UX-05).
- "On track" chip, success pill, referral entitlement line and the default text-field label and hint use existing darker tokens and pass 4.5:1; no brand colour changed (UX-07).
- Settings tiles no longer overflow at 2.0×; a harness checks the ten primary screens at the 1.25× cap. Sizes above the cap remain unsupported (UX-09).

## Build, tests and tooling

- **App Store workflow checks** (V1-009, V1-012; `4fc2ecd6`): `ios-signed-release` verifies the reviewed revision on a `release/*` branch, runs the strict gate and the native XCTests before signing, asserts the production backend, stamps the signed IPA, resolves a first build number and uploads without submitting. The XCTest step was also added to `ios-unsigned-sideload`. None of this has run on Codemagic. `ios-signed` is unchanged.
- **Data removal through startup covered in a configured build** (V1-054; `837d0881`), with every privacy assertion of the original group kept (K checked parity).

## Pre-existing tests changed in round 2, and why

Tests that existed at `d830855e` and were modified by a round-2 commit (`git diff --diff-filter=M d830855e 50957c06`, and `git show --stat` for `5583cbea`, `75dab61a`, `50957c06`). Test files created in round 2 and changed later are listed after the table.

| Test | Commit(s) | Change | Reason |
|---|---|---|---|
| `app/test/architecture/ci_release_gate_authority_test.dart` | `4fc2ecd6` | Asserted that `ios-signed-release` submits to TestFlight; now asserts it uploads and never submits (`submit_to_testflight: false`, no `submit_to_app_store`) | The workflow was deliberately changed not to submit (V1-009) |
| `app/test/architecture/destructive_path_inventory_test.dart` | `0f90003f` | Allowed destructive statements in `restore_backup_usecase.dart`: 7 → 12 | Five new statements inside the restore transaction: two drops of a temporary identity table, two outbox deletes for pre-restore intents, the pull-cursor reset |
| `app/test/core/startup/bootstrap_remove_data_integration_test.dart` | `837d0881` | Lines added only | Removal journeys ported to the configured harness; originals unchanged |
| `app/test/engine/ai/ai_candidate_validator_test.dart` | `0de54a2b` | Cases added only | Arabic comma and declined-refund cases |
| `app/test/engine/parser/declined_state_cues_table_test.dart` | `0de54a2b`, `84f2fe41`, `42a0fd0c`, `1be44623`, `c8cef416` | Three outcomes (review/payment/credit) became outcome classes; the `engineType` escape was removed and the exact type is asserted; known per-side deviations are read from the table | Reviewer K: the assertions were tightened, none weakened |
| same file | `5583cbea` | Deviating set compared with the pinned `declined_cases_deviations.json`; device amount asserted; preview assertion relaxed for completed fee rows the device holds in review | OR-03, OR-07. Reviewer P: pinning closes OR-07; the preview relaxation is consistent with the stated intent |
| same file | `75dab61a` | `defect` rows removed and direction asserted; preview allows `ignored` for completed rows the sender-less engine does not record | Reviewer Q: a strengthening for direction, but the table held none of the QR-01 texts; the Dart preview now differs from the Swift one (QR-06) |
| same file | `50957c06` | Direction no longer asserted for a row carrying a `defect` text; only round-10 rows may carry one; an own-account transfer outcome added; a defect row's amount is not asserted | Q's probes entered the table with hand truth, and the outcomes still wrong (as at the baseline) are pinned as open defects (RR-01). Reviewer R: guards fire under mutation; a weakening limited to the 75 pinned rows |
| `app/test/engine/parser/declined_transaction_test.dart` | `0de54a2b`, `42a0fd0c` | "Refund/reversal of a failed purchase still parses as a refund" became "goes to review"; the AI candidate for it is now rejected | The policy the fixer applied (refund of a never-counted original → review); DECISIONS-NEEDED B2 lists it as an open owner question |
| `app/test/engine/parser/transaction_state_cues_drift_test.dart` | five parser commits | Lines added only | New cue lists checked for equality on device and server |
| same file | `5583cbea` | `noticeKeywords` removed from a combined list and compared as an exact list | OR-08. Reviewer P: an improvement |
| `app/test/features/capture/capture_import_service_test.dart` | `42a0fd0c`, `1be44623` | Tests added; within round 2 the FR-02 assertion first expected the device's refund, then Smart Inbox | LR-03: a direction conflict goes to review. Review N notes this is a stricter policy, not a corrected wrong expectation, and that the new IPN test no longer exercises a conflict in which the device is wrong |
| same file | `5583cbea` | Tests added only | Import amount mismatch → review (OR-03) |
| `app/test/features/capture/capture_sync_service_test.dart` | `0de54a2b`, `42a0fd0c`, `1be44623` | Lines added only | Import-path cases |
| same file | `5583cbea` | One fixture's amount changed from 42 to 1.00; an OR-03 test added | The fixture text says `EGP 1.00` and the test asserts merchant naming only. Reviewer P: not a weakening |
| same file | `50957c06` | The not-completed sync loop skips the one row whose `defect` names the sync import | Q's open sync-path defect is pinned in the table (RR-01). Not separately assessed by R; it removes one input from that loop |
| `app/test/integration_local/local_device.dart` | `8e953d14` | Helper lines added | Supports the local-stack restore test |
| `supabase/functions/_shared/fixtures/ai_candidate_cases.json` | `42a0fd0c`, `1be44623` | One fixture text `Purchase 500.00 EGP refund pending` → `refund noted`; OTP and notice cases added | Keeps that case about direction. Review L: the original expected +500 to be accepted for a refund that had not happened; no test now asserts that "refund pending" is rejected (LR-10, open) |
| `supabase/functions/parse-sms/money_test.ts` | `0de54a2b` | Import changed; tests added | Grounding of the AI amount (V1-060) |
| `supabase/functions/process-ios-sms/declined_cases.json` | five parser commits | 69 → 566 cases. Six `completed_credit` cases flipped to `not_completed` (`42a0fd0c`, refund of a declined original); C334 and C351 relabelled `completed_payment` (`c8cef416`, NR-02); `review` removed as an expected outcome and per-side deviations recorded (`c8cef416`, NR-05) | Policy flips are the B2 question; relabels make `expect` the true outcome |
| same file | `5583cbea`, `75dab61a`, `50957c06` | 566 → 803 → 1,315 → 1,565 cases; expected amounts added (`5583cbea`), currency on some rows and C205 corrected 100 → 80 (`75dab61a`); 256 rows' per-side outcomes moved toward review and 75 open-defect pins added (`50957c06`) | Reviewers' probes with hand truth; R graded all 256 changed rows at `50957c06`: 0 wrong, 0 newly silent |
| `supabase/functions/process-ios-sms/parse_test.ts` | five parser commits | "Refund of a failed purchase stays a resolved credit" removed (`42a0fd0c`); the `serverDirection` escape removed (`0de54a2b`); table loop reads the new classes | Same policy; K: the server assertions were tightened |
| same file | `5583cbea` | The assertion that no completed row is `isNonTransactionText` removed; deviations compared with the pinned list; amounts asserted | AI rejections are pinned per row instead (`ai: not_a_transaction`); P: amounts and pinning close OR-07 |
| same file | `75dab61a` | Currency asserted where a row gives one; device never `ignored`; device direction asserted; "no open defect" asserted; round-9 tests added (credits are credits, standing order received is a credit, `Due amount SAR 230 … paid` → 230) | PR-01…PR-05 |
| same file | `50957c06` | "No open defect" replaced by: a wrong outcome must carry a `defect` text, only round-10 rows may; amount not asserted on defect rows; grounded AI answers a defect names may be accepted; the round-9 income assertions for `Payroll…`, `posted to your account`, `وصلك` loosened to "not a debit"; `Due amount SAR 230 … paid` loosened to "unresolved or 230"; a card posting loosened from "debit" to "not credit"; round-10 tests added (QR-01 debits never credits; future or offer clauses never resolve) | Round 10 removed the round-9 rules those assertions tested (QR-01, QR-02). Reviewer R: the relaxation is guarded (six mutations fail) and limited to round-10 rows; the loosened single assertions are not discussed by R |
| `tools/test_skip_manifest.json` | `8e953d14` | One skip entry added | The local-stack test is skipped unless `LOCAL_SUPABASE_URL` is set |

Test files created in round 2 and changed by a later round-2 commit:

| Test | Created | Changed | Change | Reason |
|---|---|---|---|---|
| `app/test/engine/parser/declined_cases_totals_test.dart` | `0de54a2b` | `5583cbea` | The bank-layout `composite` variant skipped for non-notice review rows (36 rows, all new in that commit); the 17 credit rows asserted as payments, pinning a defect | P: nothing previously asserted was dropped; the payment assertion pins a defect as expected behaviour (PR-08) |
| | | `75dab61a` | `composite` run only for not-completed and ignored rows (12 notice-review rows dropped); "never `dropped`" became "never `ignored`" | Q: a narrowing, not a hidden defect; `dropped` is a Smart Inbox card |
| | | `50957c06` | Rows carrying a `defect` text excluded from the "recorded with the right total" loops | Open defects are pinned in the table test instead (RR-01) |
| `app/test/domain/capture/local_direction_contradiction_test.dart` | `42a0fd0c` | `5583cbea` | Tests added only | Import amount check |
| `app/test/engine/parser/round9_regression_test.dart` | `75dab61a` | `50957c06` | The PR-01 test "incoming money is a credit" became "never a pre-filled payment": recorded **or** review is accepted, and type and amount are checked only when recorded; the cash-deposit case moved to its own ATM test; QR-01/QR-02 tests added | Round 10 sends an inflow phrase with no other evidence to review. A loosening of a round-9 assertion; not discussed by R |
| `supabase/functions/process-ios-sms/declined_cases_deviations.json` | `5583cbea` | `75dab61a`, `50957c06` | Pinned deviations rewritten with each table change | R graded every row changed in round 10 as a move toward review |

Reviewers K, L and N read the removed lines of these files for the commits they covered and reported no weakened assertion other than the points noted above. Reviewer O read `c8cef416`'s test changes and found them weaker (OR-07, OR-08); `5583cbea` restored exact-list comparison for notice words and pinned the deviating rows (reviewer P). In round 10 several single assertions were loosened because the rules they tested were removed; reviewer R checked that the table relaxation is guarded, and did not discuss the loosened single assertions listed above.

## Not changed, deliberately

Consent flows and their text, privacy defaults, the privacy policy, store disclosure drafts, sign-in screens other than the code-sheet sentence, feature flags, any production system, and any stored data. These need owner decisions listed in [DECISIONS-NEEDED.md](DECISIONS-NEEDED.md).

# Round 3 (`bae159e2` … `a157e68e`, 2026-11-17 to 2026-11-18)

The owner approved fifteen product decisions on 2026-11-17 ([OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3; `docs/project/DECISIONS.md` D-20) and asked for them to be implemented and for message understanding to be rebuilt. Specialists (AI agents) implemented; reviews S and T (AI agents) challenged the result four and two times. Every item below is **implemented locally**; "verified" means on this Mac, a simulator or a local stack. Nothing is deployed or on a device.

## Approved decisions implemented

- **iPhone only, portrait** (3.1; V1-014; `640562f6`). Android code untouched.
- **No ads in the V1 build** (3.2; V1-005; `640562f6`). Compile-time switch, off in store workflows; a remote flag cannot turn ads on. The ad SDKs remain linked but are never started. The production flag change is prepared (RELEASE-PLAN P4), not made.
- **Restore merges** (3.3; V1-020, V1-070; `640562f6`, `7dd6efa8`, `6f771108`). Newer data, server identity, deletions and manual edits are kept; the confirmation names whether this restore merges or fully applies. Verified on local stacks (data specialist, reviewer T).
- **Deletion is final** (3.4; V1-006; `640562f6`, `bae159e2`). Copy and policy say so; the worker's retry and resume paths are tested on a local stack (D1–D4).
- **Legal pages open with Cloud off** (3.5; V1-007; `640562f6`). Exact-URL allowlist.
- **Language chosen on first launch** (3.6; V1-044).
- **All 249 countries; 155 storable currencies; verified bank coverage stated separately** (3.7; V1-019; `640562f6`, `bae159e2`).
- **First-run consent with "Agree and enable" / "Continue locally"; combined disabling; shared learning tied to the activation** (3.8–3.10; V1-017, V1-048; `640562f6`; text reworded in `f4dcabd3` to say what redaction really does).
- **Sign-in methods kept** (3.11; V1-016): store workflows require the Apple, Google and email variables.
- **Honest notifications** (3.12; V1-035, V1-036): details shown within the OS preview setting, masked last four in APNs, the server push never says "recorded".
- **Signed-out capture fails visibly and keeps nothing** (3.13; V1-037).
- **Balances labelled by source and time** (3.14; V1-032).
- **No historical rewrite** (3.15; V1-056).

## Message understanding

- **Meaning before amount, on device and server** (V1-001, V1-072, V1-073, V1-082 … V1-084; `bae159e2`, `640562f6`, then `b6f102b4`, `7dd6efa8`, `6f771108`, `f4dcabd3`, `a157e68e`): completed, declined, pending or scheduled, pending refund, notice, bill due, expected salary, marketing, own-account, several movements and over-length text each get their own disposition; only a completed movement is recorded.
- **AI answers are structured and evidence-based** (`bae159e2`): the model must quote evidence; the server and device validators reject any answer whose meaning is not a completed movement; the prompt version is recorded (V1-058).
- **One source of "processed" on the server** (`a157e68e`): a stated total can never release a declined, pending, failed or reversed message (VAL-1).
- **Redaction** (`6f771108`, `f4dcabd3`, `a157e68e`): more person names, beneficiary forms, spaced IBANs and third-party account numbers are masked on device, server and the native Shortcut path. Some names still pass (V1-091, S2).
- **Global AI budget guard** (V1-022; `bae159e2`): one migration, four call sites; fails open by design if the database function is missing.
- Measured on synthetic data only: TEST-EVIDENCE.md §7.5–7.6.

## Accessibility and UI

- Text-size cap removed; a gate over 32 screens at up to 3.1× fails on cut-off text (UX-09; SP-09, SP-10). "Move to review" on a transaction. Batch-paste and hold wording, Cloud-off sign-out sentence, Western digits in Arabic dates (V1-066 … V1-068). Stacked selectors keep their semantics (SP-13).

## Backend, privacy, operations

- Admin on Next.js 15.5.29; production `npm audit` 0 (V1-025).
- Legal text rewritten in the repository for the approved decisions (`7cab5e8b`, `4c428719`); not published.
- Opt-in backend behaviour stage (V1-013); derived deploy set (`tools/deploy_set.sh`); read-only production comparison script (`tools/prod_compare.sh`).
- RELEASE-PLAN regenerated at `f4dcabd3` as one package (seven functions, one migration). **Records correction (this round):** the plan named `f4dcabd3` as the candidate; it now names `a157e68e`. `deploy_set.sh b6fc0dad a157e68e` gives the same set; `prod_compare.sh` was not re-run.

## Tooling (not shipped)

- Held-out message evaluation `tools/message_eval` (753 synthetic messages, criteria fixed before the first run) and differential harnesses `tools/parser_diff`.

## Rejected or superseded on the way

`7577f347` (S: REJECT — declined messages recorded, reward points as income, parser exceptions, slow parsing; T: restore REJECT — removed rules returned, accounts wiped), `7dd6efa8` (S: REJECT on reward-clause income), `6f771108` and `f4dcabd3` (S: accepted with follow-up; VAL-1 at `f4dcabd3`). Each was answered by the next commit; the findings and their closure are in REVIEW-CLOSURE.md.

## Tests changed because the approved behaviour changed

Listed and accepted by reviewer T for `7577f347`: backup (replace → merge), restore identity and backfill tests, privacy and delete-account screens, Smart Inbox label and status cycle (no UMP), the iOS store-pipeline and Android compile contracts (no iOS AdMob), the capture queue and notification contracts. Later changes are listed in the closure reports (`evidence/closure/*.md`, sections "Changed expectations"). Reviewer T found one weakening (SP-08), fixed in `7dd6efa8`.

## Not changed, deliberately

Production (nothing deployed, no flag changed, no data touched); transactions already stored (3.15); Android release work (3.1); the device database schema (v43).

