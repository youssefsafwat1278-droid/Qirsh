# Version 1 — open defects and known limitations

Assessed at: the commit recorded in [RELEASE-MANIFEST.md](RELEASE-MANIFEST.md) (`50957c06` at the time of writing).

**Nothing in this file has been accepted by the owner.** The owner has accepted no limitation and approved no scope proposal. To ship with any item below, the owner would have to sign an exception record ([`EXCEPTION-TEMPLATE.md`](../../release-process/EXCEPTION-TEMPLATE.md)); S1 items cannot be excepted. Issue IDs refer to [ISSUES.md](ISSUES.md); finding closure is in [REVIEW-CLOSURE.md](REVIEW-CLOSURE.md).

This file has two parts. Part 1 lists behavior that records or shows money wrongly: these are **defects, not limitations**, and stay open until fixed. Part 2 lists genuine constraints of the release or of this assessment.

## Part 1 — Open defects (not accepted)

### 1.1 Money recorded wrongly

The parser for bank messages went through ten fix rounds for V1-001. Round 9 (`75dab61a`) was rejected by review Q and round 10 (`50957c06`) removed its additions. Reviewer R accepted the final commit with follow-up: no S1, and nothing worse than the audit baseline on the device or the effective iOS-Cloud path. On R's 1,758 synthetic messages, wrong total-changing outcomes fell from 509 to 71 on the effective path with a bank sender. **The 71 that remain are open defects, not accepted limitations.** Every review found inputs the previous one had not tried, so the list below is the known part only.

**Remaining at the final candidate (review R, RR-01; effective path with a bank sender; each equally wrong at the baseline):**

| Class (synthetic examples) | Count (baseline → final) | Result | Direction of error | Issue |
|---|---|---|---|---|
| Notices recorded as money: due or scheduled bills (`Your bill of SAR 300 is due…`, `Payment of SAR 1,200 is scheduled…`), expected salary (`Your expected salary of SAR 12,000 will be credited…`), deposit adverts (`Deposit SAR 1,000 or more to get a free card`) | 145 → **34** of 194 notice probes | Recorded as a payment or as income although no money moved | Spending or income overstated by the stated figure | V1-072 (S1) |
| Wrong direction, mostly outgoing money booked as income (`Security deposit SAR 1,000 paid to Test Landlord…`, `Transfer SAR 1,000 to Ali for rent deposit`, `Deposit handling charge SAR 15.00 debited`, `Salary transfer … debited`, `Cashback reversal … deducted`) | 137 → **18** | Income instead of spending (15); spending instead of income (3) | Income overstated and spending understated by the full amount, or the reverse | V1-082 (S2, impact S1) |
| Transfers between the user's own accounts | 12 → **8** | Counted as spending or income | Spending or income overstated by the amount moved | V1-083 (S2, impact S1) |
| Foreign-currency purchases (`Purchase of USD 20.00 … Charged SAR 75.00`) | 27 → **6** wrong amounts | The foreign figure is recorded instead of the amount charged | Spending recorded in the wrong currency and amount | V1-084 (S2, impact S1) |
| Wrong currency (`…at USD Store`) and `SR1,250.00` read as 250 | 14 → **1** wrong currency; the `SR1,250.00` case wrong at every version | Wrong currency or a fragment of the amount | Spending misstated | V1-084 |
| Not-completed messages still recorded | 174 → **4** | Recorded as money | Spending overstated | V1-073 (S2), V1-001 (S1) |

R counts 18 wrong directions as "mostly outgoing booked as income, and 3 incomes booked as spend"; the split 15/3 above follows from that statement.

**Server alone (not on the device or effective path):** the server at `50957c06` rejects 21 completed messages with no AI where the baseline handled them, and reads `Cashback reversal … deducted` as a refund (V1-088, V1-089). The matching device build keeps each for review, so the server and the new build must ship together (V1-087); a new server with build 147 was not measured.

**Other known wrong outcomes (not re-measured by R unless stated):**

| Input (synthetic examples) | Result | Direction of error | Issue | Source |
|---|---|---|---|---|
| `Payment SAR 100 to STC has been returned` | Recorded as a payment | Spending overstated | V1-073 (S2) | O (OR-09) |
| Person-to-person payments that the parser types as `transfer` | Excluded from spend | Spending understated; treatment is an owner decision | V1-080 (S3) | O (OR-07) |
| `بانتظار الموافقة` on a transfer; pending or under-review transfers | Recorded as a transfer on the device | Account cash flow wrong | V1-073 | L, N |
| A pending refund ("Refund … initiated") | Recorded as a refund | Spending understated | V1-073 | fixer report |
| A bare reversal with no purchase noun ("Reversal of SAR 99.00 at SHOP TWO") | Recorded as a credit | Spending understated if the original was never recorded. Whether this should be review is owner decision B2/B3 | V1-073 | N (NR-05) |
| An ATM cash deposit | Booked as income (R, golden G014 ×13); the use case's own comment calls it a neutral transfer | Income overstated if a cash deposit is not income — owner policy | V1-090 (S3) | R (RR-05) |
| A tip or VAT line (`Purchase SAR 45.00 … Tip SAR 5.00. Total SAR 50.00`) | The purchase or VAT figure is recorded, not the total charged | Spending likely understated (pre-existing) | V1-080 | Q (QR-05), R |
| A server income on an outgoing transfer that the device types `transfer` | Imported confirmed (3 probes; 78 at the baseline) | Income overstated | V1-076 (S2) | R (RR-06) |
| Incoming transfers | Device: transfer; server: income | Income differs by path | V1-076 (S2) | K (FR-02), L, N |
| With AI consent: a promotion's amount, or a message with a security footer | The AI path may accept it | Spending overstated | V1-074 (S2, rated by analogy) | fixer report; no model was run |
| Declined purchases stored before the fix | Stay counted | Spending overstated | V1-056 (S3) | REV-05; owner decision B11 |
| Any message on build 147 or older, or on the deployed server until `process-ios-sms` and `parse-sms` are redeployed | Old rules apply (all baseline wrong outcomes above, 509 on R's set); after a server deploy, build 147 re-parses a rejected capture locally and confirms it; a new server with build 147 was not measured | Spending overstated, and the other directions above | V1-001, V1-055, V1-087 | REV-03, K §A3, R |
| A message with no currency token | Confirmed in the account currency | Wrong currency possible | V1-031 (S3) | B DATA-05; owner decision B22 |
| Account "current balance" | Not derived from transactions | Displayed balance may not match | V1-032 (S3) | B DATA-06; owner decision B23 |

**Fixed in code at the final candidate, not yet deployed or built (still wrong on build 147 and the deployed server):** a limit, balance or code figure taken as the amount (V1-078; e.g. an 8 SAR purchase recorded as 9,000); purchase codes recorded as payments or as the amount 482,913 (V1-079).

### 1.2 Real money movements not recorded automatically

No total changes wrongly, but spending or income is understated until the user acts.

| Input | Result | Issue | Source |
|---|---|---|---|
| A purchase whose merchant name or footer contains an ignore word or security footer | Merchant names (`Offer Mart`, `Winner Sports` …) recorded on every side at the final code (R); `مقهى عرض خاص` still silent on the device with no sender (review on the effective path) | V1-071 (S2) | K (FR-13), L (LR-05), N, R |
| 21 completed messages the server alone rejects with no AI (`Bounced cheque fee SAR 100.00 debited…`, `Salary SAR 12,000.00 credited… Bonus not posted yet.`) | Kept for review by the matching device build and on the effective path; nothing on any path that reads only the server row | V1-088 (S3), V1-087 (S2) | R (RR-04) |
| "approved. Previous attempt declined", partial reversal credited, merchant names such as `FAILED VENTURES LLC`, `Café Cancelled`, bounced-cheque fee, `did not go through` footers | Sent to review | V1-075 (S3) | K (FR-03), L (LR-07, LR-11), N (NR-04) |
| Fee debits whose amount the device cannot read (`Card renewal fee SAR 150.00 deducted …`) | Smart Inbox card for a bank sender; recorded only if the user acts | V1-075 | shared cases (`dropped` deviation) |
| Shortcut capture while signed out | Dropped silently | V1-037 (S3) | C IOS-06; owner decision B20 |
| A row created after a backup and not yet synced, under restore | Comes back after restore although the confirmation says "replace" | V1-070 (S3) | K (FR-06); owner decision B10 |

The silent-loss regression of rounds 6–8 (V1-077) is fixed in code: reviewers Q and R found no completed message silent on the device or the effective path.

**Review-volume cost — a consequence the owner must weigh, not an accepted limitation (V1-085, V1-086; DECISIONS-NEEDED B29).** The final parser sends more correct messages to the Smart Inbox than the baseline did. No total is wrong because of it, but spending and income stay understated until the user confirms each item. R measured, among completed messages the baseline recorded correctly: **0%** now in review on the repository corpus and golden fixtures; on the synthetic probe set **14.7%** (device, bank sender), **8.6%** (device, no sender), **6.8%** (server), **14.3%** (effective, bank sender) and **11.3%** (effective, no sender). Completed messages waiting in review on the effective path rose from 192 to 443 of 1,389. The cost sits in messages with a notice footer (`Card activated`, `Credit limit…`, `e-statement…`), label-led payments (`Minimum payment SAR 115.00 has been paid`), purchases that mention a code, and less common verbs (`authorised`, `approved`, `posted`, `direct debit`, `standing order`, `payroll`, `قيد`). With AI consent, the validator rejects 353 of 1,306 correct candidates on each side (203 server / 170 device at the baseline); those captures go to Smart Inbox. How this compares with real traffic is unknown: the corpus has no transaction carrying a notice or limit footer, and no monitoring of Smart Inbox volume or the AI rejection rate exists.

### 1.3 Other open defects users would notice

- Tab bar after sign-in (RT-01, V1-065): fixed in code and confirmed on a simulator for email sign-in; build 147 has the defect. Apple/Google sign-in, app lock and a device are NOT TESTED.
- Paste wording (V1-066): batch paste still says "Not understood"; the single-message text says "declined" for holds.
- Sign-out sheet with Cloud off says changes sync on sign-in (V1-067).
- Arabic dates use Arabic-Indic digits beside Western amounts (V1-068).
- Swift notification preview matches cues anywhere in the text, so a real purchase at a merchant whose name contains a cue word gets the generic notification (V1-061; notification wording only).
- Restore confirmation text and merge behavior (V1-070); replace-vs-merge is open (B10).
- Advertising flags are ON in production while the policy, consent text and manifest do not mention ads (V1-063, V1-005: S1 for any store build carrying AdMob IDs).
- The deployed deletion worker leaves profile photos when it resumes a deletion (V1-062).

## Part 2 — Limitations (constraints, not accepted)

### Coverage of the parser

- **1,565** synthetic shared cases run against the device code (Dart) and the server code (Deno), with expected outcome, amount and direction; currency is asserted on a minority of rows (V1-080). Deviating rows are pinned in a checked-in list; 75 rows carry an explicit open-defect pin (74 no worse than the baseline; one, T1330, worse on the server alone).
- The final measurements (review R) are on **synthetic probe sets**, 1,758 de-duplicated messages with hand truth, deliberately aimed at known weak spots; part of the set (the shared table) was tuned against the final code. They are **not real bank traffic** and are not rates a user will see. On 163 messages the fixers never saw, wrong outcomes fell from 39 to 20 (effective path, bank sender).
- **No device run** of any parser version exists, and no real bank message was used anywhere. Installed builds, the deployed server, and the AI legs against a real model were not tested by any review.
- This is **not universal coverage**: bank wording is open-ended, and each of the eight reviews of the parser found inputs outside the table.
- The drift test compares the device and server word lists (notice words as an exact list again since `5583cbea`); it never checked the matching logic, which is mirrored by hand (V1-081).

### Text size

- Text is capped at 1.25× app-wide (UX-09, owner decision). On an iPhone 17 and SE simulator at the largest system size, the app rendered at 1.25× without clipping on the screens captured (J). **That shows the capped rendering only; it does not verify the device's full accessibility text sizes, which the cap deliberately does not honour.** Above the cap, widget-test measurements show overflows on Transactions rows, Settings → Account, Budget form, Bills, Reports and Home (UI-UX-REVIEW §5a).

### Evidence limits of this assessment

- **Simulator only, no device.** All runtime evidence is from iOS 26.5 simulators, debug builds: the signed-in shell (J, at `8e953d14`), the RT-01 fix (M, at `0095a239`), the app-switcher snapshot, the native XCTests (194 passed at `d830855e`). Not exercised anywhere: a physical device, a CI or signed build, VoiceOver focus order, push, Shortcuts, the share extension, the live app switcher, error/offline and permission-denied states, the delete-account confirmation dialog, Apple and Google sign-in, full accessibility text sizes.
- **Runtime evidence predates the last parser commits.** J ran before the last six parser commits (`42a0fd0c` … `50957c06`); its paste results describe the parser at `8e953d14`. Reviews O, P, Q and R ran the parser code in their own harnesses, not the app.
- **Strict gate.** The last full strict gate passed at `af675aec`. A gate on the final candidate is recorded in TEST-EVIDENCE.md when run (GATE-PENDING at the time of writing).
- **Production** was read, never changed. The function comparison was made against `af675aec`; `process-ios-sms`, `parse-sms` and `_shared/ai_candidate_validator.ts` changed since. The migration ledger holds names, not content. Vault, Auth hook, Codemagic values, admin exposure and cron history are unknown.
- **Backups.** Point-in-time recovery is off and the API lists no backups (V1-023): no verified way to restore the production database.

### Platform and pipeline

- Android is out of V1 by project record (DECISIONS-NEEDED A1), not by this assessment. Android-only items (V1-027, V1-053) follow that record. Kotlin tests have never run.
- The hardened App Store workflow (`ios-signed-release`, `4fc2ecd6`) and its XCTest step have never run on Codemagic (V1-009, V1-012). The CI revision check is self-attested (V1-051).
- The skip gate can still be bypassed by `testOn`, an excluded tag, an early return or an unconditional skip (FR-11). Two unconditional skips in `adversarial/session_recovery_attack_test.dart` never run.
- The zone-less timestamp test cannot fail on a UTC host (REV-11).
- Admin panel: 25 advisories remain on Next.js 14.2.35 (V1-025); keep it off the public internet unless the owner decides otherwise (B17).

### Backend and operations

- No global AI spending ceiling (V1-022); model and prompt versions not recorded per result (V1-058).
- No backend monitoring or alerting (V1-024). In particular, nothing measures Smart Inbox volume or the AI `not_a_transaction` rejection rate, the two signals review R asked to watch after release.
- Server consent on the user-token path is per account (V1-047).
- Engagement triggers make two HTTP calls per transaction write (V1-050).
- Several admin flags have no reader (V1-043).

### Documentation

`docs/project/CURRENT_STATE.md`, `FEATURE_MATRIX.md`, `RELEASE_READINESS.md`, `RELEASE_BLOCKERS.md`, `MIGRATION_LEDGER.md` ("through 0092", superseded by the production ledger read), decisions D-13, D-14 and D-19 (D-19 contradicted by production flags), `docs/v1-release/*` and `docs/FINAL_RELEASE_READINESS*.md` describe September–October 2026. They were not rewritten here.
