# P — Independent review of the eighth parser commit (`5583cbea`)

- Reviewer model: `claude-opus-5-5` (Opus 5.5). I wrote none of the code under review and none of the earlier reviews (K, L, N, O).
- HEAD reviewed: `5583cbead0cb9b930fd30b794c09014b0b02da24`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: commit `5583cbea` only. It answers review O (OR-01 … OR-05). The comparison points are:
  - `c8cef416` ("par", the parent);
  - `0095a239` ("base");
  - the audit baseline `ab5dc10a` ("ab").
- Constraints kept:
  - No tracked file changed. `git status --short app supabase` was empty after every run, including the `deno test` run.
  - Older code came from three places:
    - `par` was a scratch `git worktree add --detach`, and I removed it afterwards (`git worktree list` no longer shows it);
    - `base` and `ab` reused O's `git archive` trees;
    - I checked those trees against `git show <sha>:<file>` for `parser_engine.dart` and `parse.ts`, and both were identical.
  - No simulator, no Docker, no production. All messages are synthetic.

## Harness (my own)

Everything is in scratch: `<scratch>/P/`.

The harness has these parts:
- `p/dev.dart`: `ParserEngine.parse` and `isIgnoredMessage`, run with no sender (`devN`) and with sender `AlRajhi` (`devB`). It reports the amount, currency and foreign amount.
- `p/srv.ts`: `deterministicParse`, `isDeclinedText` and `isResolved`. It runs on the raw text and on the text after `redactThirdPartyNames(redactPii(…))`. The text that has been redacted this way is what the server parses. Every server number below uses that text.
- `p/eff_{head,par,base,ab}.dart`: the effective iOS import on the non-AI-primary path with the server reachable.
  - If the server accepts the message and `localParseContradictsServer` holds, the message goes to `inbox`. At HEAD that check includes the new `amount:` argument, as in `capture_import_service.dart:584-590`.
  - Otherwise the server row is imported.
  - If the server does not accept the message, the device's local result is used.
  - Which contradiction check applies depends on the version:
    - `base` uses `localParseOpposesDirection`;
    - `ab` has no contradiction check (`capture_import_service.dart:495,525` at `ab5dc10a`).
- `p/uc_test.dart`: the real `AddTransactionUseCase` on an in-memory database, run with `flutter test` at HEAD. It reports type, amount and **status**.
- `p/lib.py`, `p/amt2.py`, `p/cases.py`, `p/diff.py`, `p/mm.py` and `p/v1.py` are the comparators.

Each outcome is put into one class:
- `OK`: recorded with the true amount and direction. A foreign amount with its own non-SAR currency counts as correct.
- `WAMT`: wrong amount.
- `WDIR`: wrong direction.
- `REVIEW`: review, Smart Inbox, unresolved or REJECT.
- `DROP`: no amount on the device, so no row. With a bank sender this becomes a Smart Inbox card.
- `SILENT`: device `ignored` or server `IGNORED`.

Limits of the harness:
- The AI legs were not run against a model.
- An `unresolved` server result is modelled as falling back to the local parse.
- Catalog rules were not loaded.

Input sets (all in `P/in/`):

| Set | n | Content |
|---|---|---|
| `amt` | 168 | **New.** Completed movements that stress amount selection: several amounts in one message; labels before and after the amount; Arabic and English labels; separators and Arabic-Indic digits; amount equal to the balance; label-led amounts (`Amount due paid…`); references, auth codes, last-four digits, dates, percentages; fees, VAT, tips, cashback, points, instalments. Each has a hand truth. |
| `cr` | 144 | **New.** 24 cores (incoming credits worded with the new money words, plus debits) × 6 tails (none, `Credit limit`, `Card activated`, e-statement, `تم تفعيل البطاقة`, `حد البطاقة`) |
| `nc` | 182 | **New.** OR-01: 26 cores with no currency or unusual currency (`SAR45`, `45SR`, `٤٥ ر.س`, `SR 45`, `رس`, `riyals`, `﷼`, none) × 7 notice tails |
| `bal` | 22 | **New.** Label-word payments (`رصيد`, `المستحق`, `minimum payment`, `due amount`, `balance transfer`, recharge) |
| `otp2` | 12 | **New.** Genuine completed purchases that mention a code |
| `cases` | 803 | `declined_cases.json` at HEAD |
| `corpus`, `gold`, `n122`, `own`, `notice`, `otp`, `cue` | 263 / 462 / 122 / 186 / 44 / 39 / 40 | O's sets, which contain K's, N's and O's probes |
| `kl` | 195 | K's 94 probes plus L's 87 + 14 |

## Commands run

| Command | Result |
|---|---|
| `git rev-parse HEAD` | `5583cbead0cb9b930fd30b794c09014b0b02da24` |
| `flutter test --no-pub` on the 6 Dart test files the commit touched | **+1710, All tests passed** |
| `deno test --allow-all process-ios-sms/ _shared/` | **690 passed, 0 failed, 2 ignored** (`deno.lock` unchanged) |

## 1. Amount regressions (`amt`, 168 new completed messages)

Counts are baseline → HEAD. I made the comparison against `ab5dc10a` and against `0095a239`. Where the two results differ, the `0095a239` figure is given in brackets.

| Side | correct → WRONG amount | correct → review | recorded → silent | wrong → correct | wrong at HEAD |
|---|---|---|---|---|---|
| Device, bank sender | **0** | 11 | **0** | 7 | 0 (+3 ambiguous) |
| Device, no sender | **0** | 3 | **0** | 0 (1 → review) | 0 (+1 ambiguous) |
| Server | **0** | 11 | **0** | 7 | 0 (+4 ambiguous) |
| Effective, bank sender | **0** | **13** | **0** | 8 (6) | 0 (+4 ambiguous) |
| Effective, no sender | **0** | 12 | **0** | 7 (5) | 0 |

How to read the table:
- The "ambiguous" rows are tip and total (A117, A146) and VAT plus fee (A133, A143). Their values are unchanged across all four commits.
- Foreign purchases record the foreign amount in its own currency. Examples: A006 USD 49.99, A007 AED 120, A060 USD 50. That is consistent across versions and not a wrong amount.

**What became correct.** Every wrong figure in my set came from a limit, minimum-due or outstanding label:
- `Annual card fee SAR 250… Credit limit SAR 10,000`: device payment 10,000 → review (A132).
- `Late payment fee SAR 100… Minimum due SAR 215`: device 215 → review. The effective path keeps the server's correct 100 (A140).
- `Interest SAR 32.40… Outstanding SAR 2,032.40`: 2,032.40 → review (A148).
- On the server, the "wrong → correct" rows are the wrong incomes (A031, A039, A159) and the bank layouts A161–A165.

**What became review: completed payments whose own amount follows a label word.** These are the 13 effective-path cases. Each was correct at every baseline:
- `Minimum payment of SAR 115.00 received`
- `Remaining installment SAR 400.00 debited`
- `Payment due SAR 300 paid successfully`
- `Total due SAR 1,045.00 paid via Test Bank app`
- `Amount due of SAR 340.00 has been debited`
- `Card *4521 outstanding of SAR 980.00 paid in full`
- `Remaining amount SAR 600.00 transferred`
- `تم سداد المبلغ المستحق 500 ريال`
- `سداد المستحق 1,200 ريال`
- **`خصم من رصيدك 250 ريال لدى متجر تجريبي`**
- `Outstanding amount settled SAR 1,200`
- A008, a EUR purchase whose server foreign amount the device does not read. See §2.

The targeted `bal` set (22) shows the same mechanism. Correct effective records fell from **15 at `ab5dc10a` to 4 at HEAD**: 11 completed payments went to review. Examples:
- `Minimum payment SAR 115.00 has been paid`
- `Due amount SAR 230… paid`
- `سداد المبلغ المستحق 230 ريال`
- `تم سداد الحد الأدنى 115 ريال`
- `تم خصم مبلغ من رصيدك 250 ريال`
- `Debited from your balance SAR 75.00`
- `شراء رصيد سوا 50 ريال`

The cause is that the label is matched with no regard to what the sentence says moved:
- Server: `LABELLED_FIGURE` (`_shared/ai_candidate_validator.ts:338`) masks the amount after `رصيد`, `المستحق`, `minimum payment`, `remaining`, `outstanding` and similar labels, before `extractCaptureAmount` runs (`parse.ts:452-455`). With no amount left the server goes to AI, and the new AI check (`ai_candidate_validator.ts:395-397`) rejects that same amount as `amount_is_account_figure`.
- Device: `_limitWords` (`parser_engine.dart:434`) is classed as a balance label (`:923`).

This is total-neutral (Smart Inbox). Nothing is silent and no amount is wrong. → **PR-03**.

`Balance transfer of SAR 3,000 completed` was never recorded at any version, and is review at HEAD.

### Item 1 on the other sets

| Set | Change from the parent to HEAD |
|---|---|
| `corpus` (263) | **No change** on any side |
| `n122` (122) | No change, except 9 on the device with no sender, review → correct record (Z032, Z034, Z042, Z063, Z093, Z094, Y001, Y002, Y007) |
| `gold` (462) | The server **amount changed** on 9. All are fixes: G007 `limit 9,000` → **8**; G007 balance `1,234.56` → **8**; G008 → **14**; G009 → **0.1 KWD**. On the device, 11 (bank sender) and 27 (no sender) went review → recorded, and I checked every amount by hand as correct (e.g. G005 700, G021 USD 248.95, G037 income 9,500). Nothing went correct → wrong. |
| Shared table (803), completed truth, against `ab5dc10a` | correct → WRONG = 0 on every side except C724 (see below). Recorded → silent: **0**. |

On the shared table, against `ab5dc10a`:
- Wrong → correct:
  - server 8 amount or direction plus 10 silent;
  - effective (bank) 14.
- Correct → review: device (bank) 35, server 21, effective (bank) 39. Most of these rows were added in this round with a pinned review deviation.

**The one exception is C724** (= my P52_7 and `cr` R00/R07/R08/R11). The effective path with a bank sender went from **income 12,000 (correct at `ab5dc10a` and `0095a239`) to payment 12,000**. See PR-01.

## 2. Import-path amount mismatch (`validated_capture.dart:273-284`)

How often the device and server disagree on the amount, among messages that the deterministic server accepts and the device also records:

| Set | Disagree |
|---|---|
| corpus | **0 / 131** |
| gold | **0 / 350** |
| n122 | **0 / 93** |
| table | **0 / 312** |
| `own` | **0 / 44** |
| `kl` | **0 / 65** |
| `amt` | **1 / 124** (A008) |

**Rate on ordinary messages: about 0%** (1 in 1,119). There is no flood into review. The AI leg was not run, so mismatches against AI amounts are unmeasured.

Formatting probes (`p/fmt.dart`, the result of `localParseContradictsServer`; `true` means Smart Inbox):

| Input | Result |
|---|---|
| Text `1,250.00`, server `1250` / `1250.0` / `1250.004` | false |
| Server `1250.01` | true |
| Server `125000` (minor units) | **true** (safe: review) |
| Arabic-Indic `١٬٢٥٠٫٠٠` vs `1250` | false |
| `USD 49.99 (SAR 187.46)`, server 49.99 or 187.46 | false |
| `KWD 12.500` vs `12.5` | false |
| `Purchase USD 20.00… Charged SAR 75.00`, server **75** | **true**. The device reads USD 20 with no foreign amount, so a correct SAR answer goes to review. |
| A008 `EUR 35.00… Amount in SAR 143.20… Foreign fee SAR 3.58`, server EUR 35 | **true** (`inbox`; recorded as EUR 35 at every baseline) |
| Device reads no amount (`Card *4521 authorised at Test Diner`, 45) | false: the server amount is accepted unchecked |
| Server amount as the **string** `"1,250.00"` | `num.tryParse` and `double.tryParse` return `null`, so **the check is skipped** (fail-open). This is harmless today, because `process-ios-sms` sends a number (`index.ts:535`). |

**Duplicates and loss.** The new term only widens the boolean on two existing branches:
- `capture_import_service.dart:526-541` (Smart Inbox, acknowledged);
- `capture_sync_service.dart:953-964` (`_persistBackendUnprocessableCapture`).

These are the same branches the direction-conflict rule already used. I found no new path to a duplicate or a loss.

Two caveats:
- The sync path re-parses the server's **sanitized** `rawMessage` (`:956`).
- When the device reads no amount, the check is off.

## 3. OR-01 ("silent only when there is no amount with a currency")

- **O's three silent probes are fixed.** P20_3, P40_6 and P43_5 are device `review` and server `unresolved` at HEAD.
- **O's 186:**
  - silent on device and server: 3 at the parent → **0** at HEAD;
  - server `IGNORED`: 53 → 0.
- **My `nc` set (182).** Silent on **every** path (device with a bank sender, device with no sender, and server):

| `ab5dc10a` | `0095a239` | `c8cef416` | **HEAD** |
|---|---|---|---|
| 0 | 0 | 80 | **25** |

The 25 come from 5 cores × 5 notice tails:
- `Card *4521 used for 45 رس at Test Diner`
- `… 45 riyals …`
- `Monthly maintenance fee 15.00 for account *5678` (no currency)
- `Monthly maintenance fee SR15 …` (glued `SR`)
- `SMS service fee: 5.75, account *5678`

At both baselines each was a device `drop` (a Smart Inbox card with a bank sender) and server `unresolved` (AI). At HEAD they are `ignored` / `IGNORED`. The cause is the gate on `_amountWithCurrency` (`parser_engine.dart:170`) and `AMOUNT_WITH_CURRENCY` (`parse.ts:131,683`). It needs a currency token from a fixed list, which does not include `SR` glued to the digits, `رس`, `riyals`, or a bare amount. → **PR-02**.

Also checked:
- `SR 45.00` (with a space), `ر.س`, `﷼`, `ريال سعودي`, `Saudi Riyals`, `SAR45`, `45SR`, `EGP45`, `جنيه` and `درهم` are all visible.
- `Click & Collect`, `Winner Sports` and `مقهى عرض خاص` are recorded with a bank sender.
- `مقهى عرض خاص` (C366) is still `ignored` with no sender, as at every version.

## 4. OR-05 (codes)

- O's 15 purchase-code texts (O00–O07, O11–O14, O16–O19) went from recorded at the parent to **review** on device, server and the effective path. Real OTPs (O08–O10, O15, C296, C302) are still `ignored`.
- **`482913 هو رمز…` is no longer the amount 482,913.**
- Genuine purchases that carry ref, auth, approval or receipt codes (Z083–Z098; my A098–A127) are still recorded with the right amount.
- **Over-reach.** 11 of my 12 `otp2` completed purchases went from recorded to review. Examples:
  - `Purchase SAR 250.00 at SHOPX. Pickup code 4829. Valid until 18:00`
  - `Receipt code 482913 valid for returns`
  - `Auth code: 482913 for the transaction`
  - `شراء 250 ريال… الرمز 4829 للاستفسار`

  The cause is the new `_otpCode` branches (`parser_engine.dart:416-427`), which `parse` now applies with no ignore word (`:489`). This is total-neutral. → **PR-05**.

## 5. Earlier guarantees

**Merchant declined.** C272, C313 and C538 are review and REJECT at HEAD.

**Ignore word inside the merchant name.** `Offer Mart`, `Click Pharmacy`, `Promo Burger`, `Won Kitchen`, `Promotion Plaza` and `Winner Sports` are recorded on every side.

**Direction conflict → review.** Unchanged. Contradiction-only inbox at HEAD on corpus, gold, n122 and the table: none new except G014_limTot (an ATM deposit) and C598 (a notice).

**The 566 earlier table rows.** Comparing the parent and HEAD on device, server and the effective path, the only changes are intended:
- 16 completed rows went from `dropped` to `review`;
- C482, C483, C486 and C487 now have the correct amount (8, 8, 0.1 KWD, 0.1 KWD) instead of 9,000;
- 10 notices went from server `IGNORED` to `unresolved`;
- 4 notices went from device `ignored` to `review`;
- C306 went from `review` to `ignored`, which is correct for a notice.

**Pure notices (`notice`, 44).** Number recorded as money:

| Path | `ab` | `base` | `par` | **HEAD** |
|---|---|---|---|---|
| Effective, bank sender | 38 | 34 | 31 | **11** |
| Server | 35 | 33 | 30 | 15 |

The remaining 11 include `Payment reminder: SAR 115 minimum due` (payment 115), `Your salary of SAR 12,000 is expected` and `Open a savings account with a minimum deposit of SAR 1,000`.

**K and L (`kl`).** From the parent to HEAD, only L82 changes, and correctly: `you are the winning customer of SAR 1,000` goes from review to ignored.

**Not completed → recorded on the table.** 0 on every side at HEAD. At `ab5dc10a` it was 203–242.

### What is worse than the baseline

All three findings below come from my `cr` set, where every message is a completed incoming credit.

- **PR-01 (this commit).** On the device with a bank sender, 12 messages went from review to **payment**: `Payroll…`, `تم قيد مبلغ 2,000 ريال لحسابك`, `قيد مبلغ … لحسابك من علي` and `Cashback SAR 25.00 approved`, each followed by a credit-limit or `حد البطاقة` line.
  - On the effective path with a bank sender, 10 of them were income or review at both baselines and are payment at HEAD.
  - The cause is that `payroll`, `قيد مبلغ`, `تم قيد` and `approved` were added to `moneyWords`/`moneyKeywords` (`parser_engine.dart:378-384`, `parser_rules.json:162-175`), but not to any credit-direction list. The notice gate no longer holds the message, and the device defaults to payment.
  - `AddTransactionUseCase` (my `uc_test.dart`) stores each one as `payment … pending` for `AlRajhi`. **Pending rows are outside the totals** (`drift_transaction_repository.dart:752`, `status = 'confirmed'`), so a total changes only when the user confirms the pre-filled wrong type.
- **PR-04 (carried from `1be44623`, which added `standing order` to `debitKeywords`).** The server reads `Standing order SAR 1,000.00 received from Ali into account *5678` (6/6 variants) as **payment 1,000**. At `ab5dc10a` and `0095a239` it read income.
  - With no sender the device reads no transaction, so it does not oppose. The effective import is a **confirmed** payment (`capture_sync_service.dart:1098-1102`).

## 6. Shared table and the allowlist

**Expected amounts.**
- All 524 completed rows have an `amount`.
- Every amount occurs as a number in its text (machine check).
- I read every one of the 221 rows that contain more than one number. All are right except one: **C205 (N40), `Purchase of SAR 100.00 … was declined. Purchase of SAR 80.00 … approved.`, carries `amount: 100`**. The movement that completed is **80**, and 100 is exactly the wrong figure that `ab5dc10a` recorded. It is not asserted today, because the row deviates to `not_completed` on both sides.
- `amount` carries no currency. Currency is never asserted, except for the `foreign` rows. For example, C502 and C508 are `USD 19.99` / `USD 248.95` stored under `amount`.

**The 263 deviations, by kind:**

| Kind | Rows | Notes |
|---|---|---|
| Completed, device `review` | 98 | 40 also pinned `ai: not_a_transaction`, so AI may never confirm them; 9 are server `review` = server rejects with no AI (`IGNORED` in my harness) |
| Completed, device `not_completed` | 16 | |
| Completed, server-only `unresolved` | 68 | |
| Completed, device `transfer` | 13 | Excluded from spend (`financial_semantics.dart:10`); a product decision |
| Completed, wrong direction pinned as `defect` | **20** | 17 credits read as `completed_payment`, 3 ATM deposits read as `completed_withdrawal` |
| `ignored` → review or unresolved | 48 | |

- In total, **114 completed rows are not recorded on the device by design, and 20 are recorded with the wrong direction.**
- None of the deviations hides a wrong **amount** at HEAD: 0 on any side.
- The only silent outcomes at HEAD are server `IGNORED` on 9 rows (C170, C171, C241, C352, C391, C439, C451, C465, C471). The device recovers each as review. All 9 were also silent at `ab5dc10a`.

**Defects, measured with the real use case** (`p/uc_test.dart`, sender `AlRajhi`):
- **The 17 credit→payment rows are stored as `payment <amount> pending`.** Examples:
  - C722–C725 `Payroll … 12,000`
  - C749 `وصلك مبلغ 750 ريال`
  - C653 `أودع مبلغ 2,000 ريال`
  - C659 `topped up with SAR 500.00`
  - With an unknown sender they are not a transaction.
- So on the device they change no total until the user confirms. If the user confirms, **spend rises and income falls by the full amount**.
- 16 of the 17 were the same at `ab5dc10a`. C724 is new (PR-01).
- On the iOS effective path the server is `unresolved`. With AI available, an AI credit is opposed by the device and goes to Smart Inbox. Without AI, the local pending payment is used.
- Rating: **S1, pre-existing**. It is a wrong-direction pre-fill on a frequent class (salary and incoming transfers).

**ATM deposits.**
- C752–C754 are stored as `transfer … confirmed` with a bank sender. That is neutral, but **income is under-stated** by 1,500–4,000.
- On the effective path the server's correct income is opposed by the device's withdrawal reading and goes to `inbox`.
- At `ab5dc10a` the effective path recorded income correctly; at `0095a239` it was `inbox`.
- Rating: S2, total-neutral but income missing.

**Is the table now pinned?**
- Yes. Both table tests compare the deviating set with `declined_cases_deviations.json` (`declined_state_cues_table_test.dart:56-76`, `parse_test.ts:521-526`), and the device amount is asserted (`:128-133`). This closes OR-07.
- The allowed values still permit `review` and `unresolved` on any completed row. A regression that moves a completed row to review passes, provided someone also edits the allowlist.

## 7. Test changes

- **`capture_sync_service_test.dart` (42 → 1.00).**
  - The fixture text is `IPN transfer sent with amount of EGP 1.00`, and the test asserts merchant naming only.
  - Changing `amountText`/`numericAmount` to `1.00`/`1` makes the fixture consistent with its own text.
  - **Not a weakening.**
- **`declined_cases_totals_test.dart:121-124` (the `composite` rule).** The `_snb` bank-layout variant is now skipped for review rows that are not notices.
  - I listed them with `p/snb.dart`: **36 rows, all new in this commit** (`wasRunAtParent=false` for every one). Nothing that was asserted before has been dropped.
  - Of the 36, 18 are purchase codes; their composite is review.
  - The other 18 are limit or activation notices. Their composite records the appended layout's own 100 SAR (or a transfer or withdrawal). That is the layout's movement, not the notice's.
- **`declined_cases_totals_test.dart:175`, `:187`.** These now assert `otherCompleted[onDevice(c)]` and `onDevice(c) == 'completed_payment'`. The 17 credit rows are now **asserted as payments**, which pins the defect as expected behaviour. It is labelled `defect`, but the test will fail when someone fixes it, and that change must also update the table.
- **`declined_state_cues_table_test.dart:114-124`.** The preview assertion is relaxed for completed fee rows that the device holds in review. This is consistent with the stated intent.
- **`transaction_state_cues_drift_test.dart`.** This is an improvement: `noticeKeywords` is now an exact-list comparison.

## Findings (severity per `docs/release-process/SEVERITY-AND-GATES.md`)

| ID | Sev | Class | Finding | Required action |
|---|---|---|---|---|
| **PR-01** | **S1** | REPRODUCED; REGRESSION introduced by `5583cbea` | New money words (`payroll`, `قيد مبلغ`, `تم قيد`, `approved`, `posted`) are not credit signals. An incoming credit that carries a notice line, and that the device used to hold for review, is now read as **payment**. 12 of 144 `cr` probes on the device with a bank sender; 10 on the effective path, where both baselines had income or review. One is a table row (C724, pinned as a "defect"). Examples: `تم قيد مبلغ 2,000 ريال لحسابك *5678. حد البطاقة 20,000 ريال` → payment 2,000; `Payroll SAR 12,000.00 … Credit limit: SAR 20,000` → payment 12,000. These are stored **pending**: no total change until the user confirms the wrong pre-filled type. | Add `payroll`, `قيد … لحساب`, `تم قيد … لحسابك`, `cashback … approved` and `posted to your account` to `creditKeywords` / `DirectionSignal`. Or keep a notice message with a credit preposition (`لحسابك`, `to your account`, `into account`) in review. |
| **PR-02** | **S1** | REPRODUCED; REGRESSION against `ab5dc10a` and `0095a239` (OR-01 narrowed from 80 to 25 of 182, not closed) | A completed movement with a notice line and an amount whose currency token is not in the fixed list is **silent on every path**: `45 رس`, `45 riyals`, `SR15`, or no currency (`Monthly maintenance fee 15.00 for account *5678`, `SMS service fee: 5.75`). At both baselines it was a Smart Inbox card (bank sender) and server AI. | Gate on "has any amount token" (`GroundingCheck.amountTokens` / `amountTokens`), not on a currency token. Add `SR`, `رس` and `riyal(s)` to the currency pattern. |
| PR-03 | S2 | REPRODUCED; REGRESSION, total-neutral | The label-masking rule sends completed payments whose own amount follows a label word to review. Effective path: 13 of 168 `amt`, and 11 of 22 `bal` (correct at both baselines). Examples: `Minimum payment of SAR 115.00 received/paid`, `Due amount SAR 230 … paid`, `سداد المبلغ المستحق 230 ريال`, `تم خصم مبلغ من رصيدك 250 ريال`, `Debited from your balance SAR 75.00`, `شراء رصيد سوا 50 ريال`. The AI cannot recover them: `amount_is_account_figure` rejects the right answer. | Do not mask a labelled figure when the same clause names the movement (`paid`, `received`, `settled`, `debited`, `سداد`, `خصم`, `شراء`, `شحن`); `LABELLED_FIGURE` already does this for `paid`/`debited` only when they come between the label and the number. Add these as table rows. |
| PR-04 | S1 | REPRODUCED; carried from `1be44623`; worse than both baselines | Server: `Standing order SAR 1,000.00 received from Ali into account *5678` → **payment 1,000**, a **confirmed** import on the effective path with no sender (6/6 variants). At `ab5dc10a` and `0095a239` it was income. `standing order` is in `debitKeywords` with no "received" guard. | Credit wording must win over `standing order`. Add a received-standing-order row. |
| PR-05 | S3 | REPRODUCED; total-neutral | The new `_otpCode` branches catch genuine completed purchases that mention a code (11/12 `otp2`): `Pickup code 4829. Valid until 18:00`, `Receipt code … valid for returns`, `Auth code: 482913 for the transaction`, `الرمز 4829 للاستفسار`. | Apply the purpose branches only when no completed-verb or amount clause precedes them; add counter-cases to the table. |
| PR-06 | S3 | REPRODUCED; total-neutral | The import amount check sends a correct server foreign or local amount to review when the device misses the pairing. A008 is `EUR 35.00 … Amount in SAR 143.20` (recorded as EUR 35 at every baseline). An AI SAR answer for `USD 20.00 … Charged SAR 75.00` is the same case. A string amount (`"1,250.00"`) skips the check (fail-open; not sent today). | Compare against every amount token with its currency, not only `amount`/`foreignAmount`; treat an unparseable amount as a mismatch. |
| PR-07 | S3 | REPRODUCED | C205 expects `amount: 100` for a message whose completed purchase is **80** (100 is the declined one). The table never asserts currency. | Fix C205 to 80; add a currency field. |
| PR-08 | S2 | REPRODUCED; pre-existing | 17 incoming-credit wordings are pre-filled as **payment** on the device. If confirmed, spend rises and income falls by the full amount. The ATM deposit is stored as a transfer, so income is missing. The totals test now asserts the wrong type (`declined_cases_totals_test.dart:175,187`). | Owner decision before release. Fix the direction lists; do not pin a wrong type as passing. |

## Verdict for `5583cbea`

**ACCEPT WITH FOLLOW-UP.**

It is a large net improvement:
- Limit and balance figures are no longer recorded as amounts. On every set, 0 messages went from a correct amount to a wrong amount.
- Notices recorded as money on the effective path fell from 31 to 11.
- Purchase codes are no longer recorded.
- O's 3 silent probes and the parent's 80 silent `nc` probes are reduced.
- The table is now amount-checked and pinned.

It must not be described as closing OR-01 or OR-03:
- PR-02 (silent loss) remains.
- PR-01 introduces a new wrong-direction pre-fill.
- PR-03 sends correct label-led payments to review, and the AI path cannot recover them.

## V1-001 at `5583cbea`, against `ab5dc10a`

**Wrong total-changing outcomes on my probe sets.** A wrong total-changing outcome is a wrong amount, a wrong direction, or a non-transaction recorded. The sets are `amt`, `cr`, `nc`, `bal`, `otp2`, the 803-row table, `notice` and the OTP texts: 1,397 messages.

| Path | `ab5dc10a` | `0095a239` | `c8cef416` | **HEAD** |
|---|---|---|---|---|
| Device, bank sender | 364 | 188 | 103 | **77** |
| Server | 325 | 168 | 93 | **39** |
| Effective iOS, bank sender | 416 | 228 | 125 | **70** |
| …of which a server row (confirmed) | 325 | 156 | 79 | **22** |
| …of which a local row (mostly pending) | 91 | 72 | 46 | **48** |
| Effective iOS, no sender | 344 | 166 | 98 | **29** |

The same comparison per set (the effective path with a bank sender, `ab5dc10a` → HEAD), excluding the table I did not write:

| Set | `ab5dc10a` | HEAD |
|---|---|---|
| `amt` | 11 | **0** |
| `notice` | 38 | **11** |
| `otp` | 12 | **0** |
| `nc` | 12 | **0** |
| `cr` | 46 | **42** |

**Worse than the baseline for a real user:** yes, in three places.
1. **PR-02.** 25 of 182 `nc` completed movements are silent on every path; at both baselines they were visible.
2. **PR-01.** 10 `cr` credits that were income or review on the effective path at both baselines are pre-filled as payments (pending).
3. **PR-04** (carried). 6 `standing order … received` variants are a confirmed payment with no sender; at both baselines they were income.

Also: 11–13 correct label-led payments per set now need manual review (PR-03, total-neutral).

**Open.**
- PR-01, PR-02 and PR-04: S1.
- The 17 pre-existing credit→payment pre-fills, and ATM deposits stored without income (PR-08).
- The remaining 11 of 44 notices recorded as money.
- AI legs against a model, installed builds and the deployed server were not tested.
- No claim of universal coverage of bank wording.

**V1-001 stays S1 OPEN.**
