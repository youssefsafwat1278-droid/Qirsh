# Version 1 — manual device test script

Candidate: the final candidate commit recorded in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) (local branch `release-readiness/v1`; not pushed, built by CI, deployed or submitted). First written at `23499229`; round-2 tests added 2026-11-17 (MDT-IOS-06a, -07d, -07e, -07f, -18a, -30, -31, and simulator notes on -21 and -22). The final candidate is `50957c06` at the time of writing. "Fixed in code at 23499229" below still refers to that commit; later fixes name their own commit.

Status of every test in this file: **NOT TESTED**. No physical device, no Android toolchain (no Java, no `adb`) and no production access were available during the assessment, so none of these steps has been run. Gate G5 (device verification) is unmet until a human runs this script on the release artifact and fills in the result lines.

Sources merged and deduplicated into this script: the "manual device test steps" and "could not verify here" sections of the seven audits in [`evidence/audits/`](evidence/audits/) (A product scope, B data integrity, C iOS, D Android, E security/privacy, F backend/ops, H tests/artifact/store), plus the UI/UX audit G and [UI-UX-REVIEW.md](UI-UX-REVIEW.md), and the independent review I (REV-nn) for the fixes made after the baseline. Checklist IDs refer to [`docs/release-process/MASTER-CHECKLIST.md`](../../release-process/MASTER-CHECKLIST.md); issue IDs refer to [`ISSUES.md`](ISSUES.md); thresholds come from [`SEVERITY-AND-GATES.md`](../../release-process/SEVERITY-AND-GATES.md).

How to read an "Expected" line: it states the behaviour the release requires. Where an audit found that the baseline does something else, the line also says "Known at ab5dc10a:" with the issue ID. Where a later commit on `release-readiness/v1` changed that code, the line says "Fixed in code at 23499229" with the commit: that means unit or widget tests pass, not that the behaviour was seen on a device. Build 147 contains none of these fixes. A test whose expected behaviour is not met is a **FAIL** even if the failure was already known; record it and link the issue.

Runtime checks of the fixed code so far, all on **simulators with debug builds** against a local stack and synthetic accounts — none counts toward G5:
- `f6dc5076`: launched, backgrounded and returned with its UI intact; the UI fix round rendered four screens on an iPhone SE simulator (UI-UX-REVIEW.md).
- `8e953d14` (file J, `evidence/audits/J-signed-in-runtime.md`): signed-in shell on iPhone 17 and SE, iOS 26.5, real email-code sign-in UI; 44 items seen. Found RT-01 (tab bar missing after email-code sign-in).
- `0095a239` (file M): RT-01 fix confirmed on three fresh installs, with a control build reproducing the defect.

Where a test below was partly seen on a simulator, it says **"simulator only — device still NOT TESTED"**.

---

## Part 0 — Prerequisites (both platforms)

### 0.1 The build under test

| Item | Value to record before starting |
|---|---|
| Release commit (frozen) | `________` (the final candidate commit recorded in RELEASE-MANIFEST.md) |
| `process-ios-sms` deployed from the final candidate? (RELEASE-PLAN action package P3) | yes / no · date `________` — needed to tell "before" from "after" in MDT-IOS-07b, -07d, -07e |
| `account-deletion-worker` deployed from the final candidate? (P1) | yes / no · date `________` — needed for MDT-IOS-19 step 5 |
| Production ad flags state at test time (RELEASE-PLAN P5) | on / off · date `________` |
| iOS build | 1.0.0 (`____`) — must be the artifact that passed gate G4, produced by the release workflow from the frozen commit. Build number must be greater than 147. |
| Android build | versionCode `____` — only if Android is in V1 scope (V1-004). |
| CI run URL / IPA or AAB SHA-256 | `________` |
| Previous build for upgrade tests | iOS TestFlight 1.0.0 (147), built from `b6fc0dad` (internal testing only). Also one build at or below 146 (local schema v42 or older) if TestFlight still offers it (V1-033). |

Notes:
- **No store-eligible build of the candidate exists today.** Build 147 is not the candidate (it is one commit behind and lacks every fix made since), and the `ios-signed` workflow exports internal-testing-only builds from a hard-coded personal branch (V1-009). Results recorded against 147 are reconnaissance only and do not satisfy G5.
- Internal TestFlight builds can be installed only by App Store Connect users added as internal testers.
- Producing and uploading the build is an **OWNER-AUTHORIZED ACTION**.

### 0.2 Devices

| Platform | Device | OS | Purpose |
|---|---|---|---|
| iOS | Oldest iPhone available that runs iOS 16 | iOS 16.x (deployment target is 16.0, all targets) | minimum OS (COMP-01), cold start and populated-database thresholds (PERF-01/02) |
| iOS | Recent iPhone | latest iOS 26.x | latest OS, most tests |
| iOS | iPad | latest iPadOS | only if the owner keeps iPad support (V1-014); otherwise confirm the app is not offered on iPad |
| Any | Second phone with a SIM | any | sends the synthetic messages in 0.4 by SMS |
| Android (only if in scope) | Google Pixel | Android 16 (API 36) | reference device |
| Android (only if in scope) | Xiaomi or Huawei with default battery settings | current | OEM battery-manager behaviour (V1-027) |
| Android (only if in scope) | Any device on Android 7.0 (API 24) or an emulator image | minSdk 24 | minimum OS |
| Mac | with a recording proxy (Proxyman, Charles or mitmproxy) | — | network capture for consent tests |

On iOS, also enable **Settings → Privacy & Security → App Privacy Report** on each test iPhone before the consent tests. It lists the domains each app contacted without installing a proxy certificate and is a useful second record.

### 0.3 Accounts and data

- Account **A** and account **B**: two test identities used only for testing, holding no real financial data. On iOS these are Apple IDs for Sign in with Apple, plus a Google account or email address for each if the build enables those providers (which providers ship is not known from the repository, V1-016).
- A **reviewer-style account** prepared the way App Review will receive it (V1-015).
- Never record credentials, tokens, real names, real phone numbers or real bank messages in evidence. Screenshots must show only synthetic data. Crop or blur the status bar carrier name and any notification from a real contact.
- Backend: the tests that need server-side confirmation say "operator confirms". Those confirmations are read-only queries run by the operator against the project the build talks to. Running them against production is an **OWNER-AUTHORIZED ACTION**.

### 0.4 Synthetic message set

All messages below are invented for testing. Merchants, card and account numbers are fictional ("TEST SHOP", card ending `0000`, account ending `9999`). Send them from the second phone, or paste/share them, exactly as written. Replace the dates with the test date where a date is shown, except for S10.

| ID | Language | Case | Text |
|---|---|---|---|
| S01 | Arabic | Purchase (SAR) | `شراء بطاقة مدى ****0000 بمبلغ 45.50 ريال لدى متجر الاختبار أ في 2026-11-20 14:05` |
| S02 | English | Purchase with balance figure | `Purchase of SAR 120.00 at TEST SHOP B with card ending 0000 on 20/11/2026 15:10. Available balance SAR 5,120.00` |
| S03 | Arabic | **Declined** purchase | `تم رفض عملية شراء بمبلغ 250.00 ريال لدى متجر الاختبار أ بطاقة مدى ****0000 بسبب عدم كفاية الرصيد` |
| S04 | English | **Declined** purchase | `Purchase declined: SAR 250.00 at TEST SHOP A, card ending 0000. Reason: insufficient balance.` |
| S05 | English | **Failed** purchase | `Transaction failed. Purchase of SAR 99.00 at TEST SHOP C card ending 0000.` |
| S06 | Arabic | Refund | `تم استرداد مبلغ 45.50 ريال من متجر الاختبار أ إلى بطاقة مدى ****0000` |
| S07 | English | Refund | `Refund of SAR 120.00 from TEST SHOP B credited to card ending 0000.` |
| S08 | Arabic | Outgoing transfer | `حوالة صادرة بمبلغ 300.00 ريال إلى حساب ****9999 بتاريخ 2026-11-20` |
| S09 | Arabic | Arabic-Indic digits and separators | `شراء بمبلغ ١٬٢٣٤٫٥٠ ريال لدى متجر الاختبار د بطاقة ****٠٠٠٠` |
| S10 | English | Year-less date (send in January, or after moving the device date to 2 January) | `Purchase of SAR 80.00 at TEST SHOP E card ending 0000 on 31/12 23:50` |
| S11 | English | Similar purchase 1 | `Purchase of SAR 15.00 at TEST CAFE card ending 0000 on 20/11/2026 08:01` |
| S12 | English | Similar purchase 2 (same merchant and amount, later time) | `Purchase of SAR 15.00 at TEST CAFE card ending 0000 on 20/11/2026 08:47` |
| S13 | Arabic | OTP that mentions an amount | `رمز التحقق 482913 لعملية شراء بمبلغ 45.50 ريال لدى متجر الاختبار أ. لا تشارك الرمز مع أحد` |
| S14 | English | OTP that mentions an amount | `Your OTP is 482913 for a purchase of SAR 45.50 at TEST SHOP A. Do not share it.` |
| S15 | Arabic | No currency token | `شراء بمبلغ 40.00 لدى متجر الاختبار و` |
| S16 | English | Purchase containing a link | `Purchase of SAR 30.00 at TEST SHOP F card ending 0000. Details: https://example.com/x` |
| S17 | Arabic | Purchase (EGP) | `تم خصم 350.00 جنيه من بطاقتك ****0000 لدى متجر الاختبار ز` |
| S18 | English | Non-financial personal message | `Don't forget to bring your card tomorrow` |
| S19 | English | **Declined** purchase with refund wording | `Your purchase of SAR 250.00 at TEST SHOP A was declined. If the amount was deducted it will be refunded.` |
| S20 | Arabic | **Declined** purchase with refund wording | `عملية شراء مرفوضة بمبلغ 100.00 ريال لدى متجر الاختبار أ بطاقة مدى ****0000. لاسترداد المبلغ اتصل بنا` |
| S21 | English | Completed purchase; merchant name contains a cue word | `Purchase of SAR 100.00 at TEST FAILED VENTURES card ending 0000 on 20/11/2026 12:00` |
| S22 | Arabic | Completed purchase; merchant name contains a cue word | `شراء بطاقة مدى ****0000 بمبلغ 100.00 ريال لدى مرفوض للتجارة الاختبارية في 2026-11-20 12:10` |
| S23 | English | Completed purchase with an advisory footer that mentions declining | `Purchase of SAR 60.00 at TEST SHOP G card ending 0000. Transactions exceeding limit will be declined.` |

Round-2 additions. In S24 and S25, `⏎` means a line break: type each part on its own line (the multi-line layout is what matters, review N §2c).

| ID | Language | Case | Text |
|---|---|---|---|
| S24 | English | Completed purchase, multi-line, with an available-limit line | `Purchase ⏎ Card: **0000 ⏎ Amount: SAR 75.00 ⏎ At: TEST SHOP H ⏎ Date: 20/11/2026 13:00 ⏎ Available Credit Limit: SAR 9,000.00` |
| S25 | Arabic | Completed purchase, multi-line, with an available-limit line | `شراء ⏎ بطاقة مدى ****0000 ⏎ المبلغ: 75.00 ريال ⏎ لدى: متجر الاختبار ح ⏎ الحد الائتماني المتاح: 9,000.00 ريال` |
| S26 | English | Fee that is a real debit | `Card renewal fee SAR 150.00 debited from card ending 0000.` |
| S27 | English | Completed purchase mentioning activation | `Purchase of SAR 40.00 at TEST SHOP I on your newly activated card ending 0000.` |
| S28 | English | Salary credit with a limit sentence | `Salary of SAR 8,000.00 credited to account ending 9999. Your credit limit is unchanged.` |
| S29 | English | Informational: limit change (not money) | `Your credit card ending 0000 limit has been increased to SAR 15,000.00.` |
| S30 | English | Informational: activation with limit (not money) | `Your card ending 0000 has been activated. Available limit SAR 10,000.00.` |
| S31 | Arabic | Informational: balance (not money) | `رصيدك المتاح في الحساب ****9999 هو 5,000.00 ريال` |
| S32 | English | Informational: PIN change (not money) | `The PIN of your card ending 0000 was changed successfully.` |
| S33 | English | **Pending** purchase | `Purchase of SAR 70.00 at TEST SHOP J is pending authorisation. Card ending 0000.` |
| S34 | English | **Reversed** purchase | `Purchase of SAR 90.00 at TEST SHOP K has been reversed. Card ending 0000.` |
| S35 | English | Reversal of a **declined** purchase | `Reversal of declined purchase SAR 100.00 at TEST SHOP A credited to card ending 0000.` |
| S36 | English | Bare reversal (no purchase noun) | `Reversal of SAR 99.00 at TEST SHOP L card ending 0000.` |
| S37 | English | **Pending** refund | `Refund of SAR 50.00 from TEST SHOP M initiated. Card ending 0000.` |
| S38 | English | **Failed** refund | `Refund of SAR 50.00 from TEST SHOP M failed. Card ending 0000.` |
| S39 | English | Completed purchase after an earlier decline | `Purchase of SAR 80.00 at TEST SHOP N approved. Previous attempt declined.` |

Open point to resolve before running (not established by any audit): the second phone appears to the device as a numeric sender, not a bank's alphanumeric sender ID. Whether sender-based bank recognition accepts these messages from a numeric sender is not known. Run MDT-IOS-07 / MDT-AND-06 by paste first to separate parser behaviour from sender recognition, and record what the automatic path does with a numeric sender.

### 0.5 Result line

Every test ends with:

`Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______`

Allowed results: `PASS`, `FAIL`, `NOT TESTED`, `NOT APPLICABLE` (with a reason). A FAIL must name the issue ID it matches or open a new one.

---

## Part 1 — iOS

### MDT-IOS-01 — Fresh install, language and sign-in
- Purpose: first run completes without dead ends; the offered sign-in methods are the decided set.
- Checklist: CORE-02, SCOPE-05, UX-01 · Issues: V1-016, V1-044, V1-019
- Steps:
  1. Set the iPhone language to Arabic. Install the build under test on a device that never had Qirsh.
  2. Launch. Note the language preselected on the language screen.
  3. Continue through the welcome story to the sign-in screen. Note every sign-in button shown.
  4. Sign in with Sign in with Apple as account A.
  5. In setup, note the countries offered. Pick Saudi Arabia. Choose "Continue locally" at the consent step. Allow notifications. Follow the Shortcut setup step. Finish.
  6. Repeat steps 1–3 with the device language set to English.
- Expected: no crash, no blank screen, lands on Home with coach marks. The sign-in buttons match the owner's recorded provider set; if Google is shown, Sign in with Apple is also shown. Language preselection follows the owner decision (Known at ab5dc10a: English is preselected regardless of device language, V1-044). Countries offered match the owner decision (Known at ab5dc10a: 8 countries offered, seed catalog covers Saudi Arabia and Egypt only, V1-019).
- Evidence: screenshots of the language screen (Arabic device), the sign-in screen, the country list and Home after setup.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-02 — Upgrade from TestFlight 147 over existing data
- Purpose: upgrade keeps all data, settings and consent state.
- Checklist: COMP-04, DATA-07, PRIV-03 · Issues: V1-033, V1-040
- Steps:
  1. On a device with no Qirsh, install TestFlight 1.0.0 (147). Sign in as A. Accept Cloud Sync and Smart Analysis.
  2. Create data across every money area: at least 20 transactions (paste S01, S02, S06, S07, S08, S17 and add manual ones), two accounts in different currencies, a budget, a goal, a subscription, a plan, a custom category, a learned rule, and change one transaction's category by hand.
  3. Queue one capture: enable airplane mode, run the Shortcut automation with S11 (or share S11 into Qirsh). Do not open the app.
  4. Write down: transaction count, this month's spend per currency, budget remaining, goal progress, consent state in Privacy, app lock setting, language, notification settings.
  5. Install the build under test over 147 from TestFlight. Turn airplane mode off. Open the app.
  6. Compare every value from step 4. Confirm the queued S11 is imported exactly once.
  7. Open More → Settings and note the version shown.
  8. If a build at or below 146 is still installable, repeat steps 1–6 starting from that build.
- Expected: every value in step 4 is unchanged; the manual category choice is kept; consent state unchanged; the queued capture appears once. The version shown is non-empty. (Known at ab5dc10a: the app reports only the marketing version 1.0.0, so 147 and the release build are indistinguishable at runtime, V1-040; the What's new sheet does not appear between builds of the same marketing version.)
- Evidence: screenshots of Home totals, the transaction list count, Budgets and Privacy before and after; a note of the version line.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-03 — Shortcut automation capture: foreground, background, terminated, locked
- Purpose: each message is captured exactly once in every app and device state.
- Checklist: CORE-01, COMP-03, DATA-10 · Issues: — (behaviour established only by code reading in audit C)
- Steps:
  1. Signed in as A, Cloud and Smart Analysis accepted. Create the personal automation "When I get a message from <second phone> → Process Bank SMS", set to run without asking where iOS offers that option. Record whether iOS 16 offers it.
  2. App in foreground: send S01. 
  3. App in background (home screen, app not killed): send S02.
  4. App terminated (swiped away in the app switcher): send S17.
  5. Device locked with Face ID/passcode, at least 1 minute after the last unlock: send S11.
  6. Open Qirsh after each step and count the new transactions.
  7. Leave one capture queued (send S12 while in airplane mode, app in background), then leave the phone on Wi-Fi and power overnight without opening Qirsh. Next morning, before opening Qirsh, check whether the transaction count changed (open the app only after noting the time).
- Expected: one banner per message; each message produces exactly one transaction with the right amount, currency and merchant; no Shortcuts error in steps 2–5. Step 7: the background task may import without the app being opened; if it does not, the capture must still import exactly once on open.
- Evidence: screenshot of each banner (synthetic content only) and of the transaction list after step 6; the Shortcuts automation configuration screen.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-04 — Capture before first unlock
- Purpose: a capture that cannot be stored is reported, never shown as success.
- Checklist: COMP-03, DATA-10, CORE-07 · Issues: —
- Steps:
  1. With the automation from MDT-IOS-03 enabled, restart the iPhone. Do not unlock it.
  2. Send S02 from the second phone.
  3. Unlock. Open Shortcuts and Qirsh.
- Expected: the Shortcut fails visibly or does not run; no success banner; after unlock no phantom transaction. If the message is lost, record it: the owner must list it as a known limitation.
- Evidence: screenshot of any Shortcuts error or notification; transaction list after unlock.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-05 — Share extension
- Purpose: the share path captures text, refuses what it cannot store, and does not misroute bank messages that contain a link.
- Checklist: CORE-01, CORE-07, SEC-07 · Issues: V1-038
- Steps:
  1. In Messages, long-press S07 → Share → the Qirsh share action ("إضافة رسالة بنك") with Qirsh in the background. Repeat with S06 after terminating Qirsh, and with S08 after opening and leaving Qirsh.
  2. Share S16 (contains a link) the same way.
  3. In Safari, share a page URL to Qirsh.
  4. Share an empty selection or an image (no text).
- Expected: step 1 creates exactly one transaction per shared message in every app state (repeats of the same message are covered by MDT-IOS-08); step 2 creates a transaction, not an offer (Known at ab5dc10a: suspected misrouting to Offers with a success result, V1-038); step 3 stores an offer link only, no transaction; step 4 shows an error, never success.
- Evidence: screenshots of each share-sheet result and of the transaction list and Offers area.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-06 — Manual paste and manual entry
- Purpose: the in-app paths produce correct, reviewable transactions; copy matches behaviour.
- Checklist: CORE-01, CORE-03, CORE-07 · Issues: V1-041
- Steps:
  1. Open the paste screen and paste S01. Note whether it is saved directly or held in the Smart Inbox.
  2. Open the manual add sheet. Before touching anything, note what the Category field shows. Enter an amount and tap Save without choosing a category.
  3. Choose a category and save. Then edit the amount, change the category, delete it. Watch the month total after each step.
  4. Open Reports → spending by category.
  5. Open Help → adding transactions and Smart Inbox entries; read what they promise.
- Expected: step 2: no category is pre-selected and Save shows "Pick a category"; «كل المصروفات / All expenses» is not offered (Known at ab5dc10a: it was pre-selected and saved, G UX-01; fixed in code at 23499229). Step 3: totals follow every add, edit and delete exactly. Step 4: no "All expenses" slice from new entries. Step 5: Help text matches behaviour (Known at ab5dc10a: Help said the user always confirms first, V1-041; fixed in code at 23499229, `2f2c4707`).
- Evidence: screenshots of the empty Category field and the validation message; the month total after each step in 3; Reports; Help text.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-06a — Paste wording for messages that are not recorded
- Purpose: what the paste screen says is true and does not push the user to record money that never moved, or to drop money that did.
- Checklist: CORE-01, UX-04 · Issues: RT-02, LR-08, NR-07
- Simulator status: with Cloud off, pasting declined, declined-with-refund-boilerplate and failed-refund samples saved nothing and left spend unchanged (file J, at `8e953d14`, before the wording fix). **Simulator only — device still NOT TESTED.** The new wording (`0095a239`) has not been seen on any screen.
- Steps (Cloud off, then repeat with Cloud and Smart Analysis on):
  1. Paste S04. Read the message shown.
  2. Paste S33 (pending). Read the message.
  3. Paste S39 (a completed purchase that mentions an earlier decline). Read the message; check the transaction list and the Smart Inbox.
  4. Paste S04 and S01 together as one batch. Read the per-message status.
- Expected: step 1: the message says the payment was not completed and nothing was recorded; it does not invite a manual add (RT-02, fixed in code at `0095a239`). Step 2: the message does not call a pending payment "declined" (Known at `1be44623`: still says declined, LR-08 / NR-07). Step 3: the purchase is recorded, or, if held for review, the screen says so and points to the Smart Inbox; it never says "nothing was recorded" for a completed purchase (Known: a cue false positive is told "nothing was recorded", LR-08 (a)). With Cloud and AI on, a saved-for-analysis item shows the "saved for analysis" text instead. Step 4: each message gets a truthful status (Known: batch shows "Not understood", NR-07).
- Evidence: screenshot of each message; transaction list and Smart Inbox after step 3.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07 — Parser cases on device
- Purpose: financial correctness for the hard cases.
- Checklist: DATA-02, DATA-03, DATA-04 · Issues: V1-001, V1-029, V1-031, V1-030
- Steps:
  1. Note this month's spend in SAR and EGP.
  2. Paste, one at a time: S03, S04, S05 (declined/failed). Note what is saved and the month spend.
  3. Paste S06 and S07 (refunds), S08 (transfer), S09 (Arabic-Indic), S17 (EGP), S13, S14 (OTP), S15 (no currency), S18 (non-financial).
  4. Set the device date to 2 January of next year, paste S10, then restore automatic date and time.
  5. Repeat steps 2 and 3 with Cloud and Smart Analysis accepted and with them declined (local-only parse).
- Expected:
  - S03–S05: no confirmed transaction; each is held in the Smart Inbox; month spend unchanged (Known at ab5dc10a: saved as confirmed payments and counted as spending, V1-001, S1; fixed in code at 23499229, `d35fc044`, `668f4d64`).
  - S06/S07: recorded as refunds that reduce net expense; S08: transfer, excluded from spend.
  - S09: 1,234.50 SAR exactly. (The parser changed after the baseline probe; this is the first check of this case on the changed parser.)
  - S17: in EGP, never added into the SAR total.
  - S13/S14/S18: nothing saved.
  - S15: held for review, not confirmed in the account currency (Known at ab5dc10a: auto-confirmed in the account currency, V1-031).
  - S10: dated 31 December of the previous year (Known at ab5dc10a: dated in the future, V1-029; fixed in code at 23499229, `d35fc044`).
- Evidence: screenshot of each saved or held item and of the month totals before and after; the list of message IDs and outcomes in a table.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07a — Declined purchases through each ingestion path, Cloud off
- Purpose: V1-001 on the device. A declined or failed purchase never becomes spending through any path; a real purchase whose text contains a cue word is still recorded.
- Checklist: CORE-01, DATA-02 · Issues: V1-001, V1-056
- Preconditions: a build containing `668f4d64`. Cloud Sync and Smart Analysis declined ("Continue locally"). Note this month's spend in SAR.
- Steps (for each message: S04, S19, S20, S21, S22, S23):
  1. Shortcut automation: send it from the second phone.
  2. Share extension: share the same text from Messages or Notes.
  3. Paste screen: paste it.
  4. After each message and path, check the banner text, the transaction list, the Smart Inbox and the month spend. (Each path creates its own item; duplicates across paths are covered by MDT-IOS-08, so delete or dismiss between paths if needed and note it.)
- Expected:
  - S04, S19, S20: no confirmed transaction and no refund; the item is held in the Smart Inbox; month spend unchanged on every path. S19 must not appear as a refund (Known at ab5dc10a / first fix `d35fc044`: S19-style wording became a 250.00 refund, REV-01; fixed in code at 23499229).
  - S21, S22, S23: a normal confirmed purchase of 100.00 / 100.00 / 60.00 SAR (REV-02 false positives; fixed in code at 23499229).
  - Banner: for S04, S19, S20 the banner does not present a purchase with an amount. For S21 and S22 the banner may be the generic one: the preview rules match cue words anywhere in the text (code inspection), unlike the full parser. Record exactly what each banner shows.
- Evidence: a table of message × path × outcome (confirmed / Smart Inbox / nothing) × banner text; month spend before and after.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07b — Declined purchases with Cloud on, before and after the `process-ios-sms` deploy
- Purpose: V1-001 on the server path. Shows what the new build does against the old function, what it does after the `process-ios-sms` deploy (RELEASE-PLAN action package P3), and what build 147 does.
- Checklist: CORE-01, DATA-02, DEPLOY-03 · Issues: V1-001
- Preconditions: Cloud Sync and Smart Analysis accepted. Operator can run read-only queries on the server capture records of the synthetic test account on the project the build talks to (on production, as part of the approved action package). Record in 0.1 whether P3 has been done.
- Steps:
  1. **Before the deploy**, on a build containing `668f4d64`: send S04, S19 and S21 through the Shortcut automation, then share S20 through the share extension. Operator records the server status of each capture (`processed` / `rejected`). Check the app, the Smart Inbox and month spend.
  2. **After the deploy** (P3 done): repeat step 1 on the same build with new copies (change the time in the text so the server does not fingerprint them as duplicates).
  3. Optional, to document the known gap: on a device with build 147 and Cloud on, send S04 after the deploy.
  4. For each capture, record whether a push notification arrived and what it showed.
- Expected:
  - Step 1: the server may return S04/S19/S20 as `processed` payments (old function). The app still holds them in the Smart Inbox, no confirmed row, spend unchanged (client import re-check, fixed in code at 23499229, `668f4d64`). S21: confirmed purchase.
  - Step 2: the server status for S04/S19/S20 is `rejected`; the app holds them in the Smart Inbox; spend unchanged. S21: `processed`, confirmed purchase.
  - Step 3: per REV-03, build 147 re-parses the rejected capture with its old parser and confirms it, so S04 counts as spending. This is a known, documented gap, not a pass condition; record it.
  - Step 4: no push presents a declined purchase as a completed purchase. (What the server sends for a rejected capture was not established; record it.)
- Evidence: operator's redacted status list per capture; app screenshots; month spend; push screenshots with synthetic content.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07c — Declined purchases stored before the fix
- Purpose: record what an upgraded user sees for declined purchases saved by an older build.
- Checklist: DATA-02, COMP-04 · Issues: V1-056
- Steps:
  1. On build 147, Cloud off, paste S03 and S04. Note month spend (expected on 147: both confirmed and counted).
  2. Upgrade to the build under test over 147 (as MDT-IOS-02). Open the app.
- Expected: per the owner decision on V1-056. Current code has no repair: the two rows stay confirmed and counted. Record whether anything tells the user.
- Evidence: transaction list and month spend before and after the upgrade.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07d — Informational bank messages and limit or balance lines (NR-01 class)
- Purpose: a completed movement whose text also carries a limit, activation, renewal, balance or PIN phrase is recorded; a message that only informs is never recorded as money. Review N found that `1be44623` silently dropped the first kind on device and server (NR-01, S1) and sent others to review (NR-02).
- Checklist: DATA-02, DATA-03, CORE-01 · Issues: V1-001, NR-01, NR-02, LR-04
- Preconditions: note this month's spend and income. Record in 0.1 whether P3 (`process-ios-sms` deploy) has been done.
- Steps:
  1. Cloud off: paste each of S24–S32, one at a time. Check the transaction list, the Smart Inbox, month spend and income after each.
  2. Cloud and Smart Analysis on: send S24–S32 through the Shortcut automation (second phone, or run the Shortcut manually with the text). Operator records the server status per capture for the synthetic test account (read-only).
  3. Optional, after P3: on build 147 with Cloud on, send S24, S26 and S29. Record the outcome (build 147 re-parses a server rejection with its own old rules).
- Expected:
  - S24, S25: a confirmed purchase of 75.00 SAR. S26: a confirmed 150.00 SAR fee (payment). S27: a confirmed 40.00 SAR purchase. S28: confirmed income of 8,000.00 SAR. A Smart Inbox item instead of a confirmed row is a FAIL (NR-02); **nothing at all (no row, no Smart Inbox item) is a FAIL of S1 severity (NR-01, silent loss)**. Known at `1be44623`: S24–S27 silent, S28 review. At the final candidate (`50957c06`), review R found no completed message silent on the device or effective path, but completed movements carrying a limit, activation or other notice line often go to review instead of being recorded (RR-02, V1-085) — record each such result as a FAIL against this line and note it as review volume, not silent loss.
  - S29–S32: no transaction; spend and income unchanged. (Known on the server before `1be44623`: a limit change or activation could be recorded as income 10,000–15,000, LR-04.)
  - Steps 1 and 2 give the same money outcome for every message.
- Evidence: a table of message × path × outcome × server status; month totals before and after.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07e — Pending, reversed, refunded-declined and failed-refund samples
- Purpose: messages about money that did not (or did not yet) move never change totals; ambiguous ones go to review, per the policy recorded in ROUND2-FACTS §3.
- Checklist: DATA-02, CORE-01 · Issues: V1-001, V1-057, FR-01, LR-02, NR-03; owner decisions DECISIONS-NEEDED B2, B3
- Steps: as MDT-IOS-07d steps 1–2, with S33–S39 and S19.
- Expected:
  - S33 (pending purchase): no confirmed transaction; spend unchanged.
  - S34 (purchase reversed): held for review; no total change.
  - S35 (reversal of a declined purchase): held for review, not a credit (current policy; owner decision B2 open).
  - S36 (bare reversal): held for review (policy: ambiguous). Known: recorded as a refund (ROUND2-FACTS §3, honest limits; review N C103) — record a FAIL against that limitation.
  - S37 (pending refund): no refund recorded. Known: recorded as a refund (ROUND2-FACTS §3) — FAIL against that limitation.
  - S38 (failed refund): no refund recorded (fixed in code, `0de54a2b`).
  - S39 (approved after an earlier decline): a confirmed 80.00 SAR purchase. Known: held for review (review N C114/C198, a disputed expectation, B3).
  - S19: as MDT-IOS-07a.
- Evidence: a table of message × path × outcome; month totals.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-07f — A period of real use with the owner's own bank messages (before wide release)
- Purpose: review R's measurements are on synthetic messages only; no parser version has ever met real bank traffic in this assessment. R asks for verification on a device with real bank messages before wide release. This test measures what the final parser does with real messages, in the classes where R found open defects or review cost.
- Checklist: CORE-01, DATA-02, DATA-03 · Issues: V1-001, V1-072, V1-078, V1-082, V1-083, V1-084, V1-085, V1-086, V1-087; DECISIONS-NEEDED B28–B30
- Preconditions: a physical iPhone with the release-candidate build (greater than 147) installed by the owner, signed in to the owner's own account; the Shortcuts automation set up for the owner's bank senders; record in 0.1 whether P3/P4 (server deploy) have been done — the server and the new build are meant to ship together (V1-087). Decide beforehand with Cloud and AI on or off, and keep that setting for the whole period.
- **Privacy rule for this test:** real bank messages and real amounts stay on the device. Nothing from them — text, amounts, merchants, account or card digits, screenshots — is copied into these records, chats, tickets or any repository file. The evidence is counts only, kept by the owner.
- Steps:
  1. Use the app normally for a period of `______` days (proposed: at least two weeks, or until at least 50 bank messages have arrived).
  2. For each bank message that arrives, the owner compares the app's outcome with what really happened and puts it in exactly one class: **recorded correctly** (right amount, currency and direction, or correctly not recorded for a non-transaction); **sent to review** (Smart Inbox item for a real completed movement); **wrong** (wrong amount, wrong currency, wrong direction, a non-transaction recorded as money, or a real movement with no record and no Smart Inbox item).
  3. Keep separate counts, with the same three classes, for these kinds of message when they occur:
     - a transaction message that also carries a limit, available-balance or similar line (V1-078; RR-02);
     - incoming credits: salary, incoming transfers, refunds, cashback (V1-082);
     - transfers between the owner's own accounts (V1-083);
     - purchases in a foreign currency (V1-084);
     - notices with an amount and no movement: due or scheduled bills, expected salary, offers (V1-072).
  4. If AI consent is on, also count Smart Inbox items whose message the owner recognises as a real completed movement (AI rejections, V1-086).
  5. At the end, record the totals per class and per kind, the period, the number of bank senders, and whether the server deploy was in place.
- Expected:
  - **Wrong: 0.** Any wrong outcome is a FAIL; record its kind (count only) and link the issue. A real movement with no record and no Smart Inbox item is a FAIL of S1 severity (silent loss).
  - Sent to review: no fixed threshold is set; the owner judges the burden (DECISIONS-NEEDED B29). R measured 0% on the repository corpus and up to about 15% on synthetic probes.
  - Known at `50957c06` (review R, synthetic): notices recorded as money, outgoing money with `deposit` or salary-transfer wording booked as income, own-account transfers counted, foreign figures recorded instead of the charged amount — each class may appear as a FAIL.
- Evidence: the count table only (no message content).
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______ · Period: ______ · Counts: correct ____ / review ____ / wrong ____

### MDT-IOS-08 — Duplicates across paths and similar purchases
- Purpose: the same message through any path counts once; distinct similar messages stay distinct.
- Checklist: DATA-05, FAIL-05 · Issues: —
- Steps:
  1. Send S11 by SMS so the automation captures it.
  2. Share the same S11 bubble through the share extension.
  3. Paste the same S11 text.
  4. Send S11 again from the second phone (repeated delivery).
  5. Send S12.
  6. Check the transaction list, the Smart Inbox and the day total.
- Expected: S11 counts once in totals; any repeat is either not created or held as a suspected duplicate for review, never a second confirmed transaction. S12 is a separate transaction. The day total is 30.00 SAR from S11 and S12.
- Evidence: screenshot of the transaction list, the Smart Inbox and the day total.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-09 — Consent off: nothing leaves the device (network capture)
- Purpose: zero transmission of message content or financial data without consent.
- Checklist: PRIV-02, PRIV-01, PRIV-09 · Issues: V1-003, V1-005, V1-007
- Steps:
  1. Fresh install. Configure the iPhone to use the Mac's recording proxy and trust its certificate (test device only). Start recording. Keep App Privacy Report on.
  2. Go through onboarding and choose "Continue locally" (never accept Cloud/AI). Sign in as A (sign-in traffic is expected and user-initiated).
  3. For 5 minutes: run the Shortcut automation with S01, share S02, paste S17, open Reports, Budgets, Settings, background and reopen the app.
  4. From the consent sheet, tap the Privacy policy link, then the Privacy policy and Terms rows.
  5. Stop recording. List every host contacted after sign-in completed.
- Expected: after sign-in, no request to `*.supabase.co` (REST, functions, storage), `sentry.io`, Google ads hosts (`googleads`, `doubleclick`, `app-measurement`) or Google APIs. The privacy policy and terms open. (Known at ab5dc10a: the legal links show "That link could not be opened right now" while Cloud is off, V1-007.)
- Evidence: proxy host list export (hosts only, no bodies); App Privacy Report screenshot for Qirsh; screenshot of step 4 result.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-10 — Consent on: egress matches the disclosures
- Purpose: with consent, only the declared data goes to the declared services; the recorded host list feeds the store disclosures.
- Checklist: PRIV-02, PRIV-06, PRIV-10 · Issues: V1-003, V1-005, V1-017, V1-048
- Steps:
  1. With the proxy recording, open Privacy and accept Cloud Sync and Smart Analysis. Read the consent sheet bullets and note what they say about withdrawing.
  2. Repeat the 5-minute activity of MDT-IOS-09 step 3, plus set a profile photo.
  3. Stop recording. List hosts and endpoint paths (no bodies in evidence).
- Expected: traffic only to the services listed in the privacy policy and the store disclosures. Record each data category observed (SMS text to capture/parse functions, profile photo upload, telemetry) for comparison with App Store privacy details (V1-003). No ad SDK traffic unless an ads flag is on (it should be off; V1-005). Consent copy about withdrawal matches the controls (Known at ab5dc10a: copy says either permission can be withdrawn separately; the UI withdraws both together, V1-017).
- Evidence: host and path list; screenshot of the consent sheet bullets.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-11 — Withdrawal while captures are queued, and while a request is in flight
- Purpose: revocation stops queued and retrying work; a late response is not applied.
- Checklist: PRIV-03, PRIV-04, FAIL-05 · Issues: V1-047
- Steps:
  1. Cloud and Smart Analysis on. Enable airplane mode. Send S02 so the automation queues it (status pending send).
  2. Open Qirsh, Privacy → turn off Cloud Sync and Smart Analysis. Confirm.
  3. Start the proxy recording. Disable airplane mode. Reopen Qirsh and wait 2 minutes.
  4. Operator confirms that no server capture record exists for that capture (`processed_captures` or equivalent, by payload id; read-only).
  5. Turn consent back on. Share S07, and while the upload indicator shows, turn consent off.
- Expected: step 3: no request to the capture or parse functions for S02; S02 is parsed locally. Step 5: no new request starts after the toggle; a response that arrives after the toggle does not create a transaction from server data. (By design a request already on the wire in another process cannot be recalled; the app waits it out, at most about 10 seconds.)
- Evidence: proxy host and path list with timestamps relative to the toggle; operator's redacted query result.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-12 — Remaining consent combinations
- Purpose: every reachable consent state behaves as documented.
- Checklist: PRIV-01, PRIV-02 · Issues: V1-017, V1-045
- Steps:
  1. State "declined, then accepted later": from MDT-IOS-09 end state, accept in Privacy. Confirm captures made while declined are not uploaded retroactively (they were stamped local-only).
  2. State "Cloud on, AI off": try to reach it from the UI. Record whether it is reachable.
  3. If reachable (or present after upgrading from 147 with that state): share S01 with the proxy recording. Expected: request to the capture function without AI mode; no `parse-sms` call.
  4. With Cloud off, wait for a catalog refresh window and note whether any catalog or flag request is made.
- Expected: step 1: no retroactive upload of local-only captures. Step 2: record the finding. The code withdraws both permissions together (audit A, `privacy_screen.dart`; audit E's "separately" is superseded); the consent-sheet copy promising separate withdrawal is V1-017, and the owner decides between changing the copy and building AI-only withdrawal. Step 4: no catalog request with Cloud off (consequence: Cloud-off users never receive flag changes or force-update notices, V1-045).
- Evidence: proxy host list per state; screenshot of the Privacy screen in each state.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-13 — Sign-out, Remove data and re-sign-in
- Purpose: sign-out keeps data; Remove data erases it; nothing leaks.
- Checklist: CORE-05, SEC-03 · Issues: V1-015
- Steps:
  1. As A with data, sign out (do not choose Remove data). Sign in again as A.
  2. Sign out choosing Remove data. Sign in again as A.
- Expected: step 1: all of A's data is present, matching the sign-out sheet's text. (The prepared App Store reviewer notes say the database is wiped on sign-out; that is wrong, V1-015.) Step 2: local data gone; with Cloud on it returns from the cloud; the pending capture queue is empty.
- Evidence: screenshots of the sign-out sheet text, Home totals after each re-sign-in.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-14 — Session expiry
- Purpose: an expired session does not lose data or rebind captures.
- Checklist: CORE-05, SEC-01 · Issues: —
- Steps:
  1. As A, operator invalidates A's refresh tokens on the backend the build uses (method chosen by the operator; on production this is an **OWNER-AUTHORIZED ACTION**).
  2. Background and reopen the app; send S01 while the session is invalid.
  3. Sign in again as A.
- Expected: the app shows a session-expired state without losing local data; the S01 capture stays bound to A and imports once after re-sign-in.
- Evidence: screenshot of the expired state; transaction list after re-sign-in.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-15 — Account switch and ownership of queued captures
- Purpose: account B never sees or uploads A's data or captures.
- Checklist: SEC-03, CORE-05, DATA-10 · Issues: V1-037
- Steps:
  1. As A, Cloud on. Airplane mode on. Send S11 (queued for A). Note A's lock-screen notifications.
  2. Sign out (keep data). Sign in as B. Airplane mode off. Use the app for 5 minutes with the proxy recording.
  3. Sign out of B. With nobody signed in, send S12 by SMS, then share S12.
  4. Sign in as A.
- Expected: step 2: A's notifications cleared; B sees none of A's transactions; S11 is neither imported into B nor uploaded under B. Step 3: share is refused with a visible alert; the automation drops the message silently (owner decision recorded as V1-037; record what happens). Step 4: S11 imports exactly once into A; S12 is absent.
- Evidence: screenshots of B's transaction list, the share refusal alert, A's list after step 4; proxy host list from step 2.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-16 — Offline use and reconnect
- Purpose: core local features work offline; reconnect causes no duplicates or loss.
- Checklist: CORE-08, FAIL-01, DATA-09 · Issues: —
- Steps:
  1. As A with Cloud on, enable airplane mode.
  2. Add two manual transactions, edit one existing transaction, delete one, edit a budget, capture S01 by automation.
  3. Disable airplane mode; wait for sync.
  4. On a second device (or after Remove data and re-sign-in on the same device) check the cloud copy.
- Expected: everything works offline with truthful offline indicators; after reconnect each change appears once in the cloud copy, the deleted row stays deleted, no conflict is shown for unchanged fields.
- Evidence: screenshots of the offline state and of both devices' lists after sync.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-17 — Backup export, import and corrupted file
- Purpose: round trip is lossless; bad files are rejected before anything changes.
- Checklist: DATA-08, FAIL-03, CORE-07 · Issues: V1-018
- Steps:
  1. As A, More → Data transfer → export the ZIP. Save it to Files. Note what the screen and Help → Backup say about protection.
  2. Make a copy and corrupt it: truncate it, or change bytes in the middle with a file editor on the Mac.
  3. On a clean install signed in as B (Cloud off), import the corrupted copy.
  4. Import the intact export.
  5. Kill the app (swipe away) during an import of the intact file, then reopen.
- Expected: step 1: Help and the export screen agree (Known at ab5dc10a: Help called it "an encrypted copy"; the ZIP is not password-protected, V1-018; fixed in code at 23499229, `2f2c4707`). Step 3: a clear error and no change to existing data. Step 4: all transactions, budgets, goals, categories and manual category choices match the source. Step 5: either the full import or no change, never a partial state.
- Evidence: screenshots of the Help text, the export notice, the import error, the totals before and after.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-18 — Restore, then re-enable Cloud
- Purpose: establish what restore does to cloud data, for the owner's decision.
- Checklist: DATA-08, DATA-09 · Issues: V1-020
- Steps:
  1. As A with Cloud on, create transactions T-A and T-B and let them sync. Export a backup.
  2. Delete T-A, edit T-B's amount, add T-C. Let them sync.
  3. Restore the backup from step 1 (restore turns consent off).
  4. Re-enable Cloud. Wait for sync to finish.
  5. Record which of T-A, T-B (and its amount), T-C exist locally and, via a second device or operator read-only query, in the cloud.
- Expected: the final state matches the restore semantics the owner chooses. (Known at ab5dc10a: restore does not reconcile with sync; restored rows can be overwritten or removed rows can return, V1-020. Fixed in code at `0f90003f` with merge as the default; see MDT-IOS-18a.)
- Evidence: a table of T-A/T-B/T-C local and cloud state; screenshots.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-18a — Restore then Cloud on two real devices (merge default and FR-06 cases)
- Purpose: V1-020 on devices. Restore keeps server identity, creates no cloud duplicates and loses no cloud row; record the cases final review FR-06 named.
- Checklist: DATA-08, DATA-09, DATA-05 · Issues: V1-020, FR-06; owner decision DECISIONS-NEEDED B10 (replace vs merge — open)
- Status elsewhere: reproduced and fixed against the local stack by `restore_then_sync_local_supabase_test.dart` (fails with the old code, passes with `0f90003f`). **Local-stack test only — no simulator or device run; device NOT TESTED.**
- Preconditions: two iPhones, D1 and D2, both signed in as account A with Cloud on, synced. Synthetic data only.
- Steps:
  1. On D1, create T-A and T-B; let both sync and appear on D2. On D1, export a backup.
  2. **Merge default:** on D2, create T-D and let it sync. On D1, restore the backup, re-enable Cloud, wait for two sync cycles. Count rows on D1, on D2 and (operator, read-only, synthetic account only) in the cloud.
  3. **Unsynced post-backup row (FR-06):** on D1, airplane mode on, create T-E. Restore the backup on D1 (read the confirmation text first). Airplane mode off, re-enable Cloud, sync.
  4. **Row deleted elsewhere:** on D2, delete T-A and let it sync. On D1, restore the backup (which contains T-A), re-enable Cloud, sync.
  5. **Fresh install with a different amount:** on D2, change T-B's amount and sync. On D1, delete the app, reinstall, sign in as A, restore the backup, re-enable Cloud, sync.
- Expected:
  - No step creates a duplicate of a restored row on either device or in the cloud.
  - Step 2: T-D is present on D1 and D2 (merge default: a cloud row absent from the backup is kept and pulled back; nothing is deleted).
  - Step 3: under merge, T-E comes back after restore (FR-06). The confirmation text says the backup "will replace your current data on this device"; for a Cloud user that is not what happens — record the text and the outcome. Pass/fail follows the owner's decision B10.
  - Step 4: T-A is not silently un-deleted; it is shown as a sync conflict.
  - Step 5: T-B is shown as a conflict for the user to resolve, not silently overwritten either way.
- Evidence: a table of T-A, T-B (amount), T-D, T-E per step on D1, D2 and the cloud; screenshots of the confirmation text and of each conflict.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-19 — Account deletion
- Purpose: in-app deletion completes and matches the policy text.
- Checklist: CORE-06, PRIV-07 · Issues: V1-002, V1-006
- Steps:
  1. Sign in with a disposable Sign in with Apple test account; enable Cloud; set a profile photo; capture S01.
  2. Follow More → Security & privacy → Delete account → Delete account and all data. Complete the challenge.
  3. Check Apple ID settings → Sign in with Apple: is Qirsh still listed?
  4. Try to sign in again with the same Apple ID.
  5. Operator confirms (read-only) that the auth user, `user_*` rows, `capture_devices`, contributions, and `profile-photos/<uid>/` and `backups/<uid>/` objects are gone, and that `account-deletion-worker` runs succeed in `cron.job_run_details`.
- Expected: deletion completes in-app and states its timing; Qirsh is no longer listed under Sign in with Apple; signing in again starts a new empty account; operator finds no remaining data. In-app text, the live privacy policy and the store disclosure say the same thing (Known at ab5dc10a: the policy promises 30-day undoable deletion, the app deletes immediately, V1-006). This test depends on production having the deletion migrations and functions (V1-002).
- Evidence: screenshots of each deletion screen and the success message; Apple ID list; operator's redacted query output.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-20 — Notifications: lock screen, language, permission denied
- Purpose: notification content follows the privacy decision; capture does not depend on notification permission.
- Checklist: PRIV-08, UX-01, UX-04 · Issues: V1-036, V1-035
- Steps:
  1. Default settings, phone locked: send S01. Record what the banner shows.
  2. Enable "hide lock-screen content" in Qirsh. Lock and send S02.
  3. Set the app language to English; send S07 (with the production state of the `capture_notify_v2` flag).
  4. Fresh install: deny notifications at the first prompt. Send S11.
- Expected: step 1 follows the owner's decision (Known at ab5dc10a: amount, merchant and card last 4 show by default, V1-036). Step 2: a generic banner with no amount or merchant, both for the local and the push notification. Step 3: an English banner (Known at ab5dc10a: the legacy banner is Arabic-only when `capture_notify_v2` is off, V1-035). Step 4: capture still saved, no crash, Settings shows notifications as denied.
- Evidence: lock-screen photos or screenshots with synthetic content only.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-21 — App-switcher privacy cover
- Purpose: balances are not visible in the multitasking snapshot; record the states the cover does not reach.
- Checklist: PRIV-08, SEC-04, COMP-03 · Issues: V1-034
- Background: at ab5dc10a the cover was wired to callbacks a scene-based app never receives (V1-034). Fixed in code at 23499229 (`d70ba396`): the cover is installed on `sceneDidEnterBackground` and removed on `sceneWillEnterForeground` / `sceneDidBecomeActive`. A debug simulator build compiled at `f6dc5076` launched, went to the background and came back with its UI intact; the cover itself was never observed in the app switcher. Per REV-08 the cover is not installed while the scene is only inactive.
- Simulator status: the snapshot iOS stored for the app switcher showed only the Qirsh cover (dark and light) on iPhone 17 and SE simulators (file J, screenshots 40–41). The **live** app switcher was never opened. **Simulator only — device still NOT TESTED**; steps 1–5 below, which use the live switcher, have not been run anywhere.
- Steps:
  1. Open Home showing balances. Press the Home button / swipe up to go to the home screen. Then open the app switcher and look at Qirsh's card.
  2. Open Home again. Swipe up from the bottom and pause, so the app switcher opens directly from Qirsh without first going to the home screen. Look at Qirsh's card while it is showing.
  3. Return to Qirsh from the switcher. Check that the cover is gone and the screen responds to taps.
  4. Enable App Lock (Face ID) and repeat steps 1–3. Note whether the cover appears during the Face ID prompt.
  5. Terminate Qirsh. Run the Shortcut automation with S01 so the system may launch Qirsh in the background. Without opening Qirsh, open the app switcher (if Qirsh appears) and look at its card.
- Expected: step 1: a blank branded snapshot. Step 2: per REV-08 the live screen is expected to show while the scene is only inactive; record what is visible. Whether to cover earlier is an owner decision (V1-034). Step 3: the cover never stays on screen after returning. Step 4: as steps 1–3; the cover does not hide the Face ID prompt. Step 5: record what the card shows (REV-08: a scene launched straight into the background never receives the callback).
- Evidence: screenshots of the app switcher in steps 1, 2, 4 and 5 (synthetic data only).
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-22 — Large text, RTL and device classes
- Purpose: primary screens are usable in Arabic and English at the largest text size and on each supported device class.
- Checklist: UX-01, UX-02, UX-05, UX-06, UX-10, COMP-02 · Issues: V1-014; G UX-05, UX-06, UX-08, UX-09, UX-10 (UI-UX-REVIEW.md)
- Steps:
  1. On the smallest supported iPhone (iPhone SE size), Arabic, Settings → Accessibility → Display & Text Size → Larger Text at the maximum: open Home, Transactions, a transaction detail, Budgets (including the "Budget history" tab), Reports, Goals, Bills, Settings, the manual add sheet with the keyboard up, and the goal and budget forms with the keyboard up.
  2. Repeat in English, in light and dark mode.
  3. Rotate the iPhone to landscape on Home, Reports and the add sheet.
  4. If iPad is supported: open the same screens on iPad in both orientations and in Split View. If not supported: confirm the build is iPhone-only.
- Expected: page titles on one line ("Transactions", not "Transaction / s"); budget chips ("On track", "Close to limit", "Over limit", "Budgets") and the "Budget history" tab fully readable; «تغيير التصنيف» / "Change category" not clipped; no overflow stripe or cut-off content on transaction details; no clipped, overlapping or truncated primary content elsewhere; amounts and dates render correctly inside Arabic text; fields not hidden by the keyboard. (Known at ab5dc10a: G UX-06, UX-08, UX-10; fixed in code at 23499229 and seen on a simulator for four screens only.) Text above the app's 1.25x cap looks the same as 1.25x; that is the current cap pending an owner decision (G UX-09), so record it, not as a failure. Landscape and iPad behaviour as the owner decides (V1-014).
- Evidence: screenshots of each screen in each mode.
- Simulator status: at the largest accessibility size the app's effective text scale was 1.25× and the captured screens wrapped without clipping (file J, screenshots 38–39). **Simulator only — device still NOT TESTED.** Behaviour above the cap is MDT-IOS-31.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-23 — Performance with a populated database
- Purpose: meet the SEVERITY-AND-GATES thresholds.
- Checklist: PERF-01, PERF-02, PERF-06 · Issues: —
- Steps:
  1. Prepare a synthetic file of 10,000 transactions: export a small set from the app, replicate rows in a spreadsheet with synthetic merchants and dates across 24 months, and import it with Data transfer on the oldest iPhone (iOS 16).
  2. Force-quit. Cold start with a stopwatch from tap to a usable Home (can scroll and tap).
  3. Scroll the full Transactions list quickly top to bottom. Note any freeze.
  4. Open Reports for the current month, for the year, and the annual report. Time each.
- Expected: cold start usable within 5 s; no freeze longer than 1 s while scrolling; each report opens within 3 s.
- Evidence: screen recording of steps 2–4 (synthetic data only); timings table.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-24 — Reinstall and keychain survival
- Purpose: reinstall behaves predictably; another user never sees the earlier user's data.
- Checklist: SEC-03, COMP-04, DATA-10 · Issues: —
- Steps:
  1. As A, queue two captures in airplane mode (S11, S12). Delete the app. Reinstall it.
  2. Before opening it, run the automation with S01.
  3. Open and sign in as A. Note which of S11, S12, S01 appear.
  4. Repeat steps 1–2, then sign in as B.
- Expected: step 3: A recovers the queued captures exactly once (the keychain-held queue key and owner survive reinstall); step 4: B sees none of A's captures or data.
- Evidence: transaction lists after steps 3 and 4.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-25 — Reviewer walkthrough
- Purpose: an App Review reviewer can sign in and see capture work from the review notes alone.
- Checklist: STORE-04, STORE-02 · Issues: V1-015
- Steps:
  1. On a clean iPhone and (if supported) iPad, follow the review notes exactly as written, using the reviewer account.
  2. Share the sample message the notes provide through the share extension; paste it on the paste screen.
- Expected: sign-in works; the sample becomes one transaction with the right amount and category; every statement in the notes matches the build (sign-in methods, languages, sign-out behaviour, deletion path, version).
- Evidence: screenshots of each step; a list of note statements checked.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-26 — Push notification delivery
- Purpose: real APNs delivery with the production environment; no duplicate banner on retry.
- Checklist: OPS-01, FAIL-05 · Issues: V1-021
- Steps:
  1. Admin (OWNER-AUTHORIZED on production): send a push test to account A only.
  2. Put the test device in airplane mode; send a broadcast limited to the test account (typed confirmation of the dry-run count); disable airplane mode after 5 minutes.
- Expected: the test push arrives once; the broadcast arrives once after reconnect or the next scheduled retry; admin history shows the retry then `sent`; no duplicate banner.
- Evidence: notification screenshot; admin history screenshot with personal data hidden.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-27 — Force-update notice after updating
- Purpose: a cached force-update notice blocks only the versions it targets, so it does not keep blocking an updated app.
- Checklist: DEPLOY-03, BUILD-09 · Issues: V1-039, V1-040, V1-045
- Preconditions: a non-production backend the operator controls (on production, creating a force-update notice is an **OWNER-AUTHORIZED ACTION**). Two builds with different marketing versions, older build X.Y.Z and newer build above it, the newer one containing `7597bb42`. Builds of the same marketing version cannot be told apart (V1-040), so two builds of 1.0.0 cannot be used.
- Steps:
  1. Install the older build. Sign in, Cloud on (Cloud-off users never receive notices, V1-045). Operator creates a `force_update` notice whose version range includes the older build's version and excludes the newer one.
  2. Wait for the catalog refresh; confirm the block screen appears.
  3. Enable airplane mode (so the cached notice is not refreshed). Install the newer build over it. Open it.
  4. Operator changes the notice's maximum version to a malformed value such as `v1.0.1`, on a device still running the older build; refresh.
- Expected: step 2: blocked. Step 3: the newer build opens normally, not blocked by the cached notice (Known at ab5dc10a: the cached row kept blocking, V1-039; fixed in code at 23499229, `7597bb42`). Step 4: per REV-10 the malformed bound now fails open (no block); record it. The owner decides whether the admin form must validate the format.
- Evidence: screenshots of steps 2–4; the notice's version range as entered (no personal data).
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-28 — VoiceOver names on add and close buttons
- Purpose: icon-only controls have spoken names.
- Checklist: UX-07 · Issues: G UX-03, G UX-04 (UI-UX-REVIEW.md)
- Steps:
  1. Turn on VoiceOver. In Arabic and in English, on Transactions swipe to the "+" header button; on Bills (Subscriptions) do the same.
  2. Open the manual add sheet, the goal form, the budget form, the paste screen and (when signed out or adding a method) the sign-in methods and email-code sheets. Swipe to each X button.
  3. Swipe through Home, Transactions and the add sheet from top to bottom; note whether the reading order follows the screen.
- Expected: step 1: "Add transaction, button" / the Bills add label, in the app language, not just "button". Step 2: "Close, button" / «إغلاق». Step 3: a sensible order; record anything skipped or unnamed. (Known at ab5dc10a: unnamed, G UX-03, UX-04; fixed in code at 23499229, checked by widget tests only. VoiceOver itself was never used.)
- Evidence: screen recording with VoiceOver captions, or notes of what was spoken per control.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-29 — UI states, contrast and motion from the UI review
- Purpose: check on a device the UI fixes that were verified only by widget tests, and the owner-decision items.
- Checklist: UX-03, UX-04, UX-06, UX-09 · Issues: G UX-05, UX-07, UX-12, UX-16, UX-17 (UI-UX-REVIEW.md)
- Steps:
  1. New account, no transactions: open Reports → Overview.
  2. Settings → Transaction capture before any capture has happened.
  3. Light mode, one budget on track: look at the "On track" chip. Then Accounts and Transactions: look at the header subtitle over the photo.
  4. Settings → Accessibility → Motion → Reduce Motion on. Reach the restore prompt (fresh install with a backup available, or as onboarding offers it).
  5. Tap Subscriptions filter chips, budget-form period chips, Settings "Edit" and Settings → Account name with a thumb; note mis-taps.
- Expected: step 1: a tip card, not a blank page (G UX-12, fixed in code). Step 2: neutral info styling, not a green success shield (G UX-16, fixed in code). Step 3: subtitle clearly readable over the photo (G UX-07 part fixed in code); the "On track" chip is 4.02:1 by calculation and its fix needs an owner decision on the brand green; record whether it reads clearly. Step 4: no scale or bounce animation (G UX-17, fixed in code). Step 5: these controls are still 36 pt or less (G UX-05, open); record mis-taps.
- Evidence: screenshots of steps 1–3; a note for steps 4 and 5.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-30 — Tab bar visible after every sign-in method (RT-01)
- Purpose: the native tab bar appears after sign-in with nothing open, and hides only while a sheet or dialog is open. Build 147 hides it for good after email-code sign-in (RT-01).
- Checklist: CORE-02, UX-01 · Issues: RT-01, V1-016
- Simulator status: email one-time-code sign-in on `0095a239` — bar visible on three fresh installs and after a re-sign-in; hidden while the add sheet or sign-out sheet is open; a control build with the old observer reproduced the defect (file M). **Simulator only — device still NOT TESTED.** Apple and Google sign-in, the app-lock path, cold relaunch and tapping the native tab items were not tested anywhere.
- Steps (fresh install each time; Arabic and English):
  1. Email code (if the build enables it): sign in; complete setup; dismiss the first-use coach mark. Look for the tab bar. Tap each of the five tabs.
  2. Open the "+" sheet, then close it with its X. Open Settings → Sign out, cancel. Look for the bar after each.
  3. Sign out and sign in again with the same method.
  4. Repeat steps 1–3 with Sign in with Apple, and with Google if the build offers it.
  5. App lock: enable App Lock. Open the "+" sheet, send the app to the background for more than 30 seconds, return, unlock with Face ID, close the sheet.
  6. Force-quit and relaunch while signed in.
  7. Optional control: on build 147, sign in by email code and record whether the bar appears.
- Expected: steps 1–6: with nothing open, the bar is visible and every tab responds; while a sheet or dialog is open, the bar is hidden; it returns when the sheet closes. Step 7: per RT-01, the bar is missing on 147 (record; not a pass condition).
- Evidence: screenshots after each step.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-IOS-31 — Full device accessibility text sizes above the app's 1.25× cap
- Purpose: record what users who need text larger than 1.25× actually get. **Not covered by any testing so far**: the only check (file J, simulator) saw the capped rendering on a few screens.
- Checklist: UX-02, UX-05 · Issues: G UX-09 (owner decision on the cap)
- Steps:
  1. Settings → Accessibility → Display & Text Size → Larger Text: turn on Larger Accessibility Sizes and set the maximum. Turn on Bold Text.
  2. In Arabic and English, open Home, Transactions, a transaction detail, Budgets, Reports, Goals, Bills, Settings, the add sheet, the paste screen, the email-code sheet, Smart Inbox, the consent sheet and the delete-account screens.
  3. Look at the native tab bar labels, the share extension's compose sheet, the Shortcuts action, system alerts and the notification banner at this size.
  4. Repeat step 2 at the largest non-accessibility size (no "Larger Accessibility Sizes").
- Expected: app content renders at no more than 1.25× and is not clipped, overlapped or truncated at that scale; native and system parts follow the system size without breaking the layout around them. Record, as a fact for the owner's decision G UX-09, that app text does not grow beyond 1.25× at the largest sizes — not as a pass.
- Evidence: screenshots of each screen at the maximum size; a note of which parts follow the system size.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

---

## Part 2 — Android

> **Android's inclusion in Version 1 is an open owner decision (V1-004).** Run this part only if the owner puts Android in V1 scope. If Android is out of scope, mark every test below NOT APPLICABLE with the reason "Android out of V1 scope (V1-004 decision dated ______)". At ab5dc10a a release AAB has never been built, the release build offers no sign-in method, and the Play SMS declaration is not submitted, so most tests below cannot start until those are resolved. The device steps assume `adb` access from a computer with the Android platform tools.

### MDT-AND-01 — Fresh install and sign-in
- Purpose: the release build can be signed into.
- Checklist: CORE-02, COMP-01 · Issues: V1-004, V1-010
- Steps:
  1. Install the release AAB from the Play internal track on the Pixel and on the API 24 device.
  2. Launch; go to the sign-in screen; note the buttons. Sign in as A.
  3. Open Settings; note the version line.
- Expected: at least one sign-in button; sign-in reaches setup. (Known at ab5dc10a: the `android-release` workflow passes no sign-in defines, so no button is shown, V1-004.) The version line is non-empty (Known at ab5dc10a: `APP_VERSION` was empty in `android-release`, V1-010; fixed in CI configuration at 23499229, `64e571e5`; no CI build has run with it).
- Evidence: screenshots of the sign-in screen and the Settings version line.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-02 — SMS disclosure and permission
- Purpose: the prominent disclosure precedes the system dialog; every answer is handled.
- Checklist: PRIV-01, STORE-03, UX-04 · Issues: V1-004
- Steps:
  1. Fresh install. Settings → «رصد العمليات». Note the switch state and whether any system dialog has appeared.
  2. Turn the switch on; decline the disclosure.
  3. Turn it on; accept the disclosure; deny in the system dialog. Repeat to a permanent denial.
  4. Grant via the App Settings route.
  5. With the switch on, revoke SMS permission in system settings; return to the app; send S01.
- Expected: step 1: switch off, no system dialog. Step 2: no system dialog, switch off. Step 3: switch off; after permanent denial the app offers App Settings. Step 5: switch reads off; nothing captured.
- Evidence: screenshots of the disclosure and each dialog.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-03 — SMS capture in foreground, background and swiped away
- Purpose: each message is captured exactly once.
- Checklist: CORE-01, COMP-03, DATA-10 · Issues: —
- Steps:
  1. Switch on, permission granted. Send S01 with the app in the foreground, S02 with it in the background, S17 after swiping it away.
  2. Open the app after each and count transactions.
- Expected: one transaction per message; the swiped-away case arrives within a few minutes of network availability via background work.
- Evidence: transaction list screenshot.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-04 — Locked device, Doze, reboot before unlock
- Purpose: capture survives device power states.
- Checklist: COMP-03, DATA-10 · Issues: —
- Steps:
  1. Lock the phone for more than 1 hour; send S11.
  2. `adb shell dumpsys deviceidle force-idle`; send S12; `adb shell dumpsys deviceidle unforce`.
  3. Reboot; before the first unlock send S07; then unlock.
- Expected: steps 1 and 2 captured once each (step 2 after Doze ends). Step 3 captured after unlock, or a documented loss for the owner to list as a known limitation.
- Evidence: transaction list after each step.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-05 — Force-stop and OEM battery manager
- Purpose: establish and document loss when the app is stopped.
- Checklist: COMP-03, CORE-07 · Issues: V1-027
- Steps:
  1. App info → Force stop. Send S01. Open the app.
  2. On the Xiaomi or Huawei device with default battery settings, leave the app idle and the phone locked for several hours, then send S02.
  3. Check whether the app tells the user anything about either case.
- Expected: per the owner decision on V1-027. (Known at ab5dc10a: messages received while force-stopped are not captured and the user is not told.)
- Evidence: transaction list; screenshot of any guidance shown.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-06 — Message filtering and parser cases
- Purpose: same financial-correctness cases as iOS; non-financial and OTP messages are not read.
- Checklist: DATA-02, DATA-03, DATA-04, PRIV-02 · Issues: V1-001, V1-029, V1-031, V1-030
- Steps:
  1. Send S18 from a numeric sender and S13/S14 by SMS. Check the app and the capture queue count.
  2. Run the parser steps of MDT-IOS-07 by SMS and by sharing text into Qirsh.
  3. Declined messages, Cloud off: send S04, S19, S20, S21, S22 and S23 by SMS, then share and paste each (as MDT-IOS-07a, with the SMS receiver in place of the Shortcut automation).
  4. Declined messages, Cloud and Smart Analysis on, with the network recorded: repeat step 3 by SMS.
- Expected: S18, S13, S14 neither imported nor queued. Other expectations as in MDT-IOS-07, including the known failure V1-031. Steps 3–4: as MDT-IOS-07a (S04, S19, S20 held in the Smart Inbox, never confirmed or counted as refunds; S21–S23 normal purchases). Step 4: no `parse-sms` request for S04, S19 or S20 (declined messages are not sent to AI; fixed in code at 23499229). The `process-ios-sms` deploy does not affect Android.
- Evidence: outcomes table; screenshots.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-07 — Duplicates across paths
- Purpose: one transaction per message across SMS receiver, share and paste.
- Checklist: DATA-05 · Issues: —
- Steps: as MDT-IOS-08, using the SMS receiver in place of the Shortcut automation and Android share in place of the share extension.
- Expected: as MDT-IOS-08.
- Evidence: transaction list, Smart Inbox, day total.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-08 — Share intent from another app
- Purpose: another app cannot silently inject "bank messages".
- Checklist: SEC-07 · Issues: V1-053
- Steps:
  1. `adb shell am start -n com.youssefsafwat.mali/.MainActivity -a android.intent.action.SEND -t text/plain --es android.intent.extra.TEXT "Purchase of SAR 99.00 at TEST SHOP X" --es android.intent.extra.SUBJECT TESTBANK`
- Expected: no silent import as a bank transaction (Known at ab5dc10a: imported, V1-053).
- Evidence: transaction list after the command.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-09 — Sign-out, session expiry, account switch and queued captures
- Purpose: B never sees A's captures; capture pauses visibly while signed out.
- Checklist: SEC-03, CORE-05, DATA-10 · Issues: V1-053
- Steps:
  1. As A, switch on. Airplane mode on; send S11 (queued). Sign out; sign in as B; airplane mode off. Use the app.
  2. Sign out of B. Send S12 while signed out.
  3. Sign in as A.
  4. Session expiry: operator invalidates A's refresh tokens (OWNER-AUTHORIZED on production); send S01; sign in again.
- Expected: B imports nothing and B's switch reads off. A's switch is restored with the one-time notice; S11 imports exactly once into A. S12 is not captured (current code; the decision document says otherwise, V1-053). After session expiry capture pauses until re-sign-in; record whether the user is told.
- Evidence: transaction lists for A and B; switch states.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-10 — Remove data and account deletion with a queued item
- Purpose: deletion leaves no capture data or background work behind.
- Checklist: CORE-06, PRIV-07, SEC-03 · Issues: V1-002, V1-006
- Steps:
  1. As A with an item queued offline, run Remove data. Check `adb shell dumpsys jobscheduler | grep -i qirsh`.
  2. Repeat with Delete account. Operator confirms server data is gone (as MDT-IOS-19 step 5).
  3. Open the public web deletion URL entered in Play Console and follow it.
- Expected: queue holds none of A's items, switch off, no remaining scheduled job; account deleted; the web URL works and describes the same process.
- Evidence: command output (no personal data); screenshots.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-11 — Consent off: network capture from cold start
- Purpose: nothing leaves the device without consent, including the ads SDK.
- Checklist: PRIV-02, PRIV-09 · Issues: V1-053, V1-005
- Steps:
  1. Fresh install; switch on; Cloud never accepted. Record traffic with PCAPdroid (or a proxy) from cold start for at least 2 minutes, then through capture of S01 and sharing of S02.
- Expected: no requests to `*.supabase.co`, `sentry.io`, `googleads`, `doubleclick`, `app-measurement` or Google APIs except user-initiated sign-in. (Suspected at ab5dc10a: the ads SDK may start at process launch on Android, V1-053.)
- Evidence: host list export.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-12 — Consent on, combinations and revocation while queued
- Purpose: same as MDT-IOS-10 to MDT-IOS-12.
- Checklist: PRIV-02, PRIV-03, PRIV-06 · Issues: V1-003, V1-017
- Steps: run MDT-IOS-10, MDT-IOS-11 (steps 1–4) and MDT-IOS-12 on Android, using SMS capture in place of the Shortcut automation.
- Expected: as the iOS tests.
- Evidence: host lists per state.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-13 — Offline, backup, corrupted file, restore then Cloud
- Purpose: same as MDT-IOS-16 to MDT-IOS-18.
- Checklist: CORE-08, DATA-08, DATA-09 · Issues: V1-018, V1-020
- Steps: run MDT-IOS-16, MDT-IOS-17 and MDT-IOS-18 on Android.
- Expected: as the iOS tests.
- Evidence: as the iOS tests.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-14 — Notifications
- Purpose: permission handling and lock-screen privacy.
- Checklist: PRIV-08, UX-04 · Issues: V1-036
- Steps:
  1. Android 13+, fresh install: deny notifications. Capture S01.
  2. Grant notifications. Enable the system "hide sensitive content" setting. Lock, capture S02.
  3. With default system settings, lock and capture S07.
- Expected: step 1 capture works, no crash. Step 2 amount and merchant hidden. Step 3 per the owner's lock-screen decision.
- Evidence: lock-screen photos with synthetic content.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-15 — Device backup and transfer
- Purpose: financial data, session and capture queue are not restored to another device.
- Checklist: SEC-04 · Issues: —
- Steps:
  1. Run a device backup (Google One) or device-to-device transfer to a second Android device.
- Expected: no capture queue, session or opt-in restored; the app asks for sign-in.
- Evidence: screenshot of the second device's first launch.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-16 — Version header and upgrade between builds
- Purpose: the build identifies itself; a second upload is accepted and upgrades cleanly.
- Checklist: BUILD-09, COMP-04 · Issues: V1-010, V1-004
- Steps:
  1. With the proxy recording and Cloud on, check the `X-App-Version` header on a catalog request.
  2. Install two consecutive internal-track builds over each other with data present (as MDT-IOS-02 steps 2–6).
- Expected: header non-empty (fixed in CI configuration at 23499229, `64e571e5`); versionCode increases between uploads (Known at ab5dc10a: fixed at 44 by `pubspec.yaml`, part of V1-004); all data kept.
- Evidence: header value; before/after totals.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

### MDT-AND-17 — Large text, RTL, performance, reinstall
- Purpose: same as MDT-IOS-22 to MDT-IOS-24.
- Checklist: UX-01, UX-02, UX-05, PERF-01, PERF-02, COMP-04 · Issues: —
- Steps: run MDT-IOS-22 (steps 1–2), MDT-IOS-23 on the slowest in-scope Android device, and a reinstall: uninstall with captures queued, reinstall, sign in as A.
- Expected: as the iOS tests for layout and thresholds. Reinstall: Android removes app data and Keystore keys on uninstall, so queued captures and local data are gone unless restored from Cloud or a backup; the app must not crash on the missing key.
- Evidence: as the iOS tests.
- Result: NOT TESTED · Tester: ______ · Device: ______ · OS: ______ · Build: ______ · Date: ______

---

## Coverage summary

| Requested scenario | iOS test | Android test |
|---|---|---|
| Fresh install | MDT-IOS-01 | MDT-AND-01 |
| Upgrade from build 147 over existing data | MDT-IOS-02 | MDT-AND-16 (between internal builds; no prior Android release exists) |
| Capture per ingestion path, locked / background / terminated | MDT-IOS-03, -04, -05, -06 | MDT-AND-03, -04, -05 |
| Duplicates across paths | MDT-IOS-08 | MDT-AND-07 |
| Sign-out, session expiry, account switch, queued-capture ownership | MDT-IOS-13, -14, -15 | MDT-AND-09 |
| Consent combinations, revocation while queued, network capture | MDT-IOS-09, -10, -11, -12 | MDT-AND-11, -12 |
| Offline then reconnect | MDT-IOS-16 | MDT-AND-13 |
| Backup export / restore, corrupted file | MDT-IOS-17 | MDT-AND-13 |
| Restore then re-enable Cloud (V1-020) | MDT-IOS-18 | MDT-AND-13 |
| Account deletion | MDT-IOS-19 | MDT-AND-10 |
| Lock-screen notification content | MDT-IOS-20 | MDT-AND-14 |
| App-switcher cover (V1-034), including the inactive state (REV-08) | MDT-IOS-21 | n/a (Android sets `FLAG_SECURE`; check during MDT-AND-17) |
| Large text, small screen and RTL | MDT-IOS-22 | MDT-AND-17 |
| Declined purchase via each ingestion path, Cloud off (V1-001) | MDT-IOS-07a | MDT-AND-06 step 3 |
| Declined purchase, Cloud on, before and after the `process-ios-sms` deploy; build 147 behaviour | MDT-IOS-07b | MDT-AND-06 step 4 (no server parser on Android) |
| Declined rows stored before the fix (V1-056) | MDT-IOS-07c | — |
| "Declined … will be refunded" wording; merchant name with a cue word | MDT-IOS-07a (S19, S20, S21, S22, S23) | MDT-AND-06 |
| Year-less date (V1-029) | MDT-IOS-07 (S10) | MDT-AND-06 |
| Force-update notice after updating (V1-039) | MDT-IOS-27 | — |
| Manual add with no pre-selected category (G UX-01) | MDT-IOS-06 | — |
| VoiceOver names on add and close buttons (G UX-03, UX-04) | MDT-IOS-28 | — |
| UI states, contrast, Reduce Motion, small targets (UI-UX-REVIEW) | MDT-IOS-29 | — |
| Performance with populated database | MDT-IOS-23 | MDT-AND-17 |
| Reinstall (keychain survival) | MDT-IOS-24 | MDT-AND-17 |
| Parser cases (declined, refund, transfer, digits, year-less, OTP) | MDT-IOS-07 | MDT-AND-06 |
| Reviewer path | MDT-IOS-25 | — |
| Push delivery | MDT-IOS-26 | — |
| Tab bar after email-code, Apple, Google sign-in and app lock (RT-01) | MDT-IOS-30 (email code: simulator only) | — |
| Restore then Cloud on two devices, merge default and FR-06 cases (V1-020) | MDT-IOS-18a (local-stack test only) | MDT-AND-13 (if Android in scope) |
| Informational messages; completed messages with limit, activation, renewal or balance lines (NR-01 class) | MDT-IOS-07d | MDT-AND-06 (if Android in scope) |
| Pending, reversed, refunded-declined, bare-reversal, pending- and failed-refund samples | MDT-IOS-07e | MDT-AND-06 (if Android in scope) |
| Paste wording for messages not recorded (RT-02, LR-08) | MDT-IOS-06a | — |
| Real use with the owner's own bank messages: correct / review / wrong counts; limit or balance lines, incoming credits, own-account transfers, foreign-currency purchases, notices (review R) | MDT-IOS-07f (never tested) | — |
| Privacy cover in the live app switcher | MDT-IOS-21 (stored snapshot seen on simulator only) | — |
| Full device accessibility text sizes above the 1.25× cap | MDT-IOS-31 (never tested) | — |
