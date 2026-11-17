# Version 1 — changes made during release readiness

Changes on the local branch `release-readiness/v1` after the audit baseline `ab5dc10a`. None is pushed, built by CI, deployed, or on a device. Issue IDs refer to [ISSUES.md](ISSUES.md); UX IDs to [UI-UX-REVIEW.md](UI-UX-REVIEW.md).

## Money correctness

- **Declined purchases are no longer recorded as money movements** (V1-001; `d35fc044`, `668f4d64`). A bank message reporting a declined, failed, rejected, cancelled or unsuccessful transaction used to be saved as a confirmed payment and counted in monthly spending, budgets and reports. Now, on the device, such a message goes to Smart Inbox for review; consented AI is not asked about it and the AI validator rejects it; the server parser rejects it; the notification preview does not announce it as a purchase; and both client paths that import server results refuse to import it as a confirmed row. A refund or reversal of a failed purchase is still a credit. The first version of this fix was rejected by the independent review (a refund word anywhere switched detection off and one case was stored as a refund; common wordings were missed; merchant names and footers caused false alarms); the second version addresses those with 69 synthetic cases shared by the device and server tests.
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

## Not changed, deliberately

Consent flows and their text, privacy defaults, the privacy policy, store disclosure drafts, sign-in screens, navigation, feature flags, any production system, and any stored data. These need owner decisions listed in [RELEASE-DECISION.md](RELEASE-DECISION.md).
