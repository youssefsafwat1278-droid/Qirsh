# Q — Independent review of the ninth parser commit (`75dab61a`)

- Reviewer model: `claude-opus-5-5` (Opus 5.5). I wrote none of the code under review and none of the earlier reviews (K, L, N, O, P).
- HEAD reviewed: `75dab61af852f77ed596e5906bf61263fcf132d7`, branch `release-readiness/v1`, worktree `.claude/worktrees/v1-readiness`. Date 2026-11-17.
- Scope: commit `75dab61a` only. It answers review P (PR-01 … PR-08).
- Comparison points:
  - the audit baseline `ab5dc10a` ("ab");
  - `0095a239` ("base");
  - the parent `5583cbea` ("par"), used only to attribute changes to this commit.
- Constraints kept:
  - No tracked file was changed; `git status --short app supabase` was empty after every run, including `deno test`.
  - The only file written in the repository is this one.
  - No simulator, no Docker, no production. All messages are synthetic.
  - `ab` and `base` reuse O's `git archive` trees. I checked every non-test file under `app/lib`, `process-ios-sms` and `_shared` against `git show <sha>:<file>`: all identical.
  - `par` and the mutation copy were scratch `git archive` trees, which I deleted afterwards. No `git worktree` was added.

## Harness (my own; not the fixer's, not P's)

Everything is in scratch: `<scratch>/Q/` (`h/` code, `in/` inputs, `out/` results).

**Server: `h/srv.ts`**
- It calls the real `parseSms` on `redactThirdPartyNames(redactPii(text))`, which is what `index.ts:137,266-268` parses.
- First call: `allowAi:false`. *processed* means accepted with an amount and a currency (`index.ts:335`).
- Second call: `allowAi:true` with a `beforeAi` hook that records whether the AI would be reached.
- If the message is not accepted and the hook was never reached, the server is **silent** (`IGNORED`, or a declined cue `REJECT`).

**Device: `h/dev_{ab,base,head}.dart`**
- `isIgnoredMessage`, then `ParserEngine.parse`.
- Run twice: sender `null`, and sender `AlRajhi`.

**Effective iOS import (non-AI-primary, AI off/unavailable): `h/dev_*.dart`, per version**
- **ab**: if the server processed the message and `validateCaptureCandidate` accepts it, the server row is imported. Otherwise the device parses it locally.
- **base**: the same, but the server row also needs `!localParseOpposesDirection` (`capture_import_service.dart` at `0095a239`, ll. 525-529).
- **HEAD**: `validateCaptureCandidate`, then `localParseContradictsServer`.
  - If they contradict, the message goes to the **inbox**.
  - Otherwise the server row is imported (`capture_import_service.dart:526-541`).
- Server rows carry `amount_text`, so they import as **confirmed** (`capture_sync_service.dart:1101-1105`).

**Outcome classes**
- `SILENT`
- `REVIEW`, which covers review, the inbox, `unresolved`, and a device `drop`.
  - A `drop` is a Smart Inbox card for a bank sender **and for no sender**: `BankSenderFilter.isLikelyBank` returns true for a null sender (`bank_sender_filter.dart:21`), and `droppedByParser` is set at `add_transaction_usecase.dart:896`.
  - A `drop` is silent only for a non-bank sender, such as a phone number.
- `OK`
- `WDIR` (wrong direction), `WAMT` (wrong amount), `WCUR` (wrong currency), `WREC` (a non-transaction recorded).

**Inputs**

| Set | n | Notes |
|---|---|---|
| `q` (**new**) | 250 | Aimed at this commit (§1). Hand truth for every row. |
| P's sets | 1,154 | `amt 168`, `bal 22`, `cr 144`, `nc 182`, `otp2 12`, `own 186`, `n122 122`, `kl 195` (K + L), `cue 40`, `otp 39`, `notice 44` |
| `table` | 1,315 | All rows of `declined_cases.json` |
| `corpus`, `gold` | 263 / 462 | No truth; every change was diffed and read |
| `g5` | 11 | Merchant-name and "merchant declined" guarantees |

**Commands run**

| Command | Result |
|---|---|
| `git rev-parse HEAD` | `75dab61af852f77ed596e5906bf61263fcf132d7` |
| `flutter test --no-pub` on `declined_cases_totals_test.dart`, `declined_state_cues_table_test.dart` and `round9_regression_test.dart` | **+2619, All tests passed** |
| `deno test --allow-all process-ios-sms/ _shared/` | **691 passed, 0 failed, 2 ignored** (`deno.lock` unchanged) |

## 1. Verdict on the acceptance rule: something IS worse than both baselines

Here "worse" is measured against `ab5dc10a`, and also against `0095a239`.
- I attributed every entry below to this commit by re-running `par`. At the parent each of them was payment, review or transfer.
- Silent outcomes on the device and on the effective path: **0** on every set.

### QR-01 (S1): debits confirmed as INCOME on the server and the effective path

**Cause.**
- New `creditKeywords` (`parser_rules.json:484-500`): `payroll`, `wages`, `cashback`, `posted to your account`, `into account`, `added to your account`, `topped up`, `you got`, `sent to you`, `أودع`, `لحسابك`, `وصلك`.
- These are matched as substrings by `earliest()`, and **the earliest word wins** (`parse.ts:724-734`).
- The server `debitKeywords` (`parser_rules.json:447-464`) has no `transfer`, `تحويل`, `fee`, `charge(d)`, `deducted` or `sent`.

**Why the device does not stop it.**
- The device's contradiction check uses `DirectionSignal`. The same words were added there (`direction_signal.dart:43-63`).
- So for a transfer, or a no-verb debit, the wording reads *credit*, or *mixed*, which counts as unknown. Nothing contradicts the server.
- The wrong server row is then imported **confirmed**.

Every row below was payment at both baselines on the effective path with a bank sender (or review or drop where marked), and is now **confirmed income**:

| Id | Text | eB / eN at HEAD |
|---|---|---|
| Q003 | `Wages paid to employee SAR 3,000 from your account *5678` | income 3000 / income |
| Q004 | `Payroll Services Co: SAR 2,500.00 debited from account *5678` | income / income |
| Q007 | `Wages transfer of SAR 3,000 to Test Staff debited from account *5678` | income / income |
| Q011 | `SAR 120 sent to your contact Ali from account *5678` (`sent to you` inside `sent to your`) | income / income |
| Q013, Q014 | `You got charged SAR 45.00 at Test Diner…` (baseline: drop) | income / income |
| Q018 | `Posted to your account: SAR 45.00 card purchase at Test Mart` | income / income |
| Q021 | `Charge of SAR 49.99 posted to account *5678 for Test Streaming` | income / income |
| Q024 | `Fee SAR 25.00 added to your account *5678` (baseline: drop) | income / income |
| Q025 | `Annual fee SAR 250.00 posted to your account *5678` | income / income |
| **Q045** | `Instant transfer of SAR 250.00 from your account *5678 into account of Ali` (baseline: device transfer) | **income / income** |
| **Q046** | `SAR 250.00 transferred from your account *5678 into account of Ali` | **income / income** |
| **Q047** | `Outgoing transfer SAR 250.00 into account IBAN SA00 of Ali` | **income / income** |
| Q027 | `Interest SAR 32.40 posted to your account` | income. Ambiguous: a card charge or savings interest. |
| Q052 | `Card *4521 SAR 89.00 at Arrived In Account Cafe` | income. Contrived merchant name. |
| Q029 | `STC Pay wallet topped up with SAR 100 from … card *4521` (own transfer) | income |
| Q037, Q038, Q043, Q044 | Own-account transfers using `لحسابك` / `into account` | income |

On the server alone the class has **24 rows** (23 against `base`), plus 5 own-transfer rows. It also includes:
- `Payroll payment SAR 45,000.00 debited`, `Cashback Store purchase SAR 60.00`, `Transaction posted to your account: Purchase SAR 75.00`, `وصلك: خصم 50 ريال…`, `دفع 120 ريال لحسابك…` and `Recharge … topped up with SAR 50, paid from card`;
- for these the effective path catches the contradiction (**inbox**), but the server row and its push are income.

Proof that the tests would catch this if the rows existed: I appended Q045 and Q003 to a scratch copy of the table as `completed_payment`, and `parse_test.ts` **failed** on each ("Values are not equal"). The table simply has no debit carrying a new credit word.

### QR-02 (S2): device-only regressions with a bank sender (pending pre-fills)

**(a) Payment or transfer → income on the device.**
- `DirectionSignal` credit words in a message with no type: Q011, Q012 `Money sent to Yousef SAR 200`, Q022 `Debit posted to your account *5678: SAR 300.00`, Q023 `SAR 300.00 debit added to your account…`.
- The new ATM-deposit rule (`parser_engine.dart:748-752`) applies to **any** `deposit`/`إيداع` without `withdraw`, before the transfer rule:
  - Q076 `Transfer SAR 1,000 to Ali for rent deposit`
  - Q077 `Transfer of SAR 2,000 to deposit account of Test Developer`
  - Q078 `تحويل 2,000 ريال لإيداع دفعة شقة…`
  - These three are income with no sender too. The server already read them as income at both baselines, so the effective path is unchanged.

**(b) A figure taken as the amount: `movementActsOnFigure` clause (a), "English verb right after the figure"** (`parser_engine.dart:1581`).
- Q157 `Available limit SAR 5,000 debited SAR 50 at Test Mart`: device **50 → 5,000**.
- Notices recorded on the device where both baselines dropped them:
  - Q140 `Purchase approved. Available balance SAR 9,000 debited card ending 1234` → payment 9,000. This is the brief's own probe.
  - Q147 `Your balance SAR 5,000 after salary credited` → income 5,000.
  - Q158 and Q159 (`… credited`) → income 9,000 / 5,000.
  - Q162 `Balance SAR 3,000 deducted? Check your statement` → payment 3,000.
- On the effective path these equal the baseline (the server was already wrong), except Q162 with a bank sender (drop → payment 3,000).

### QR-03 (S2): notices recorded as money where a baseline was review (effective path)

| Id | Text | Baseline | HEAD |
|---|---|---|---|
| Q151 | `Your credit card outstanding SAR 2,000 will be debited on 1 Dec` | review | **confirmed payment 2,000** |
| Q242 | `Earn cashback of SAR 50 when you spend SAR 500 this week` | review | confirmed income 50 |
| Q243 | `Get SAR 100 cashback into your account…` | local payment | confirmed server income |
| Q248 | `أودع 1,000 ريال واحصل على مكافأة` | local payment | confirmed server income |

### Worse-than-baseline counts (completed movements; every offending id listed above)

| Side | Silent | Direction / type | Amount | Currency | Notices newly recorded |
|---|---|---|---|---|---|
| Device, bank sender | 0 | 9 (+1 own transfer) | 1 (Q157) | 0 | 5 |
| Device, no sender | 0 | 3 (Q076-78) (+1) | 0 | 0 | 2 |
| Server | 0 new in this commit\* | **24 vs ab / 23 vs base** (+5) | 0 | 0 | 3 |
| Effective, bank sender | 0 | **18** (+5) | 0 | 0 | 3 |
| Effective, no sender | 0 | **15** (+5) | 0 | 0 | 4 |

The same lists apply to both baselines. P's `amt` A028 was flagged by my comparator, but it is a correct foreign amount (USD 20), so it is not counted.

\*The server is silent on 27 completed rows against `ab` and 16 against `base` (declined-cue false positives: `Bounced cheque fee … debited`, `Your dispute … is under review`, `Previous attempt did not go through`, `تم إلغاء رسوم العملية`, and others). Every one was already silent at `par`, so none comes from this commit. The device recovers each as review, so they are total-neutral but carried.

**Currency.** 59 currency probes: **0 regressions, 14 fixes**.
- Fixed: `Saudi Riyal(s)`, `Mada … SAR`, `Card mada`, `Omran`, `Qarawi`, `Jodhpur`, `Eurostar`, `Usdan`, `Saudia`, and others.
- Still wrong at every version: Q120 `SR1,250.00` → 250, and Q103 `Purchase 30.00 at USD Store` → USD.

**AI off: purchase with a notice word** (Q169-Q182).
- With a bank sender, the effective path records the device's own payment for all 14. With no sender: review.
- Nothing is lost.
- Two server-income errors from `ab` are fixed (Q171, Q176).

**`POS` as a whole word.**
- `mPOS SAR 45.00…`, `ePOS…`, `Repos Cafe…`, `Posh Store…` and `Positano…` went payment → review with no sender and on the server. They are still a payment with a bank sender.

### Correct → review (total-neutral cost)

Attributed to this commit (`par` → HEAD), all on my `q` set:

| Side | Rows |
|---|---|
| Device, bank sender | 13 |
| Device, no sender | 9 |
| Server | 5 |
| Effective, bank sender | 8 |
| Effective, no sender | 15 |

Causes:
1. `isMixed` (`parser_engine.dart:667`). Examples: `…debited… Received by merchant`, `…Points received`, `…Cashback credited next month`, `SAR 150 debited… Credited to Ali`. 9 rows with a bank sender.
2. New credit words that contradict a correct server debit, sending it to the inbox: `Transaction posted to your account: Purchase…`, `Cashback Store purchase`, `وصلك: خصم`, `دفع … لحسابك`. 7 rows on the effective path.
3. `POS` as a whole word (5 with no sender).

Against `ab`, the full probe set's correct → review counts are: device with a bank sender 40, device with no sender 28, server 14, effective with a bank sender 53, effective with no sender 61. Most come from earlier rounds (declined cues).

### Wrong total-changing outcomes, `ab5dc10a` / `0095a239` / HEAD

| Set | Device, bank sender | Device, no sender | Server | Effective, bank sender | Effective, no sender |
|---|---|---|---|---|---|
| P's sets (1,154) | 178 / 149 / **10** | 97 / 69 / **10** | 144 / 126 / **21** | 206 / 181 / **18** | 151 / 127 / **18** |
| `q`, mine (250) | 66 / 63 / **48** | 48 / 46 / **28** | 46 / 45 / **60** | 73 / 81 / **65** | 59 / 68 / **54** |
| Table (1,315)† | 327 / 151 / **0** | 226 / 63 / **0** | 280 / 124 / **0** | 354 / 179 / **0** | 288 / 123 / **0** |

†Built from HEAD's output (see §2).

On `q` the server got **worse** in aggregate (46 → 60).

**`corpus` and `gold`.** Every change against `base` was read by hand. All are fixes:
- ATM deposit (G014 × 12) → income;
- credits (G017, K017, K079, K087) → income;
- G007–G009 limit/balance amounts → the true 8, 14 or 0.1;
- outward transfer → transfer.

## 2. The rebuilt shared table

- **(a) Rows read.** The 803 old rows are unchanged except for `device`/`server` values and **C205's amount, 100 → 80** (PR-07 fixed). 512 rows were added, all `V1-RES9` and all completed. I read 136 of the new rows plus every row quoted above: 51 credits, 40 Arabic, 45 payments.
  - Expect, amount and direction are right in all of them.
  - Currency is **absent** on 941 of 1,315 rows, including non-SAR texts such as `45 جنيه` (T1262/T1264), `45 درهم` (T1270) and `USD45` (T1278). On those rows currency is never asserted.
- **(b) Deviations (502).**

  | Kind | Rows |
  |---|---|
  | Completed rows not recorded on the device | **236 of 1,036**: 116 review, 99 dropped, 16 `not_completed`, 5 credit review or `not_completed` |
  | Completed payment → transfer (spend under-stated) | 20 |
  | `completed_transfer_in` → `completed_income` (same direction) | 12 |
  | Server `unresolved` | 362 |
  | Server reject-with-no-AI (`review` / `not_completed`) | 25 |
  | Completed rows pinned `ai: not_a_transaction` | 107 |

  No deviation records a wrong direction or amount. But that is because the table holds none of the QR-01/QR-02 texts: **it encodes only the classes its author probed**.
- **(c) Do the guards fire?** I mutated a scratch copy of the table or the engine and re-ran the tests:

  | Mutation | Result |
  |---|---|
  | Completed row set to device `ignored` | fail |
  | Income row set to device `completed_payment` | fail (allowed-set / allowlist) |
  | Amount + 1 | fail |
  | Currency SAR → USD | fail |
  | ATM-deposit rule reverted in the engine | 3 fail |
  | Whole-word currency guard reverted | 2 fail |
  | Q045 or Q003 appended as `completed_payment` (`parse_test.ts`) | fail |

  The guards work; the coverage is the gap.
- **(d) The four rows left out of the table.** Their outputs are identical at `ab`, `base` and HEAD:

  | Id | Text | Recorded |
  |---|---|---|
  | A117 | `Purchase SAR 45.00 … Tip SAR 5.00. Total SAR 50.00` | 45 |
  | A146 | `Tip of SAR 10.00 added … Total SAR 110.00` | 10 |
  | A133, A143 | VAT 2.25 on a fee of 15 | 2.25 |

  These amounts are likely understated (the total charged is 50, and fee plus VAT is 17.25). Leaving the rows out hides a pre-existing, not a new, wrong amount (S3).

## 3. Notices still recorded

- **The fixer's list.** Each item is no worse than `ab` on the effective path with a bank sender: bill reminder 300, upcoming payment 1,200, alert settings 500, spending summary 2,000, expected salary 12,000, minimum deposit 1,000, scheduled transfer 500, instalment plan 3,000, card-payment reminder 980.
  - The minimum-due reminder (Q228) is review at both versions.
  - The annual-fee notice (Q232) went drop → review.
- **Notice probes recorded as money, effective path with a bank sender:**

  | Set | `ab` | HEAD |
  |---|---|---|
  | Mine (46) | 39 | **34** |
  | P's `notice` (44) | 37 | **12** |

  Three of mine are new (QR-03).

## 4. Test changes

- **Totals test `composite` (`declined_cases_totals_test.dart:120-125`).**
  - The appended-layout run is now only for `not_completed`/`ignored` rows.
  - This drops 12 notice-review rows that the old rule asserted. I re-ran their composites: 11 record the appended SAR 100 (the layout's own movement) and 1 records nothing. No notice figure is recorded.
  - It is a narrowing, not a hidden defect.
- **"Never `dropped`" → "never `ignored`".**
  - `dropped` is a Smart Inbox card for a bank sender. It is **also a card with no sender**, because a null sender counts as bank-like (`bank_sender_filter.dart:21`, `add_transaction_usecase.dart:892-897`).
  - It is silent only for a non-bank sender, such as a phone number, and that is the same at the baselines.
  - In my sets, no completed message became `drop` at HEAD where a baseline recorded it. The claim holds.
- **Preview** (`declined_state_cues_table_test.dart:203-221`). It now allows `PreviewOutcome.ignored` for completed rows that the sender-less engine does not record. In the app, a preview only chooses the notification text (`BankMessageShortcuts.swift:445,492`). The Dart mirror now differs from the Swift preview, which was not changed (S4).
- **The `defect` rows are removed and the direction is asserted** (`:89-101`). This is a strengthening, but the table has no debit carrying a new credit word.

## 5. Earlier guarantees

| Guarantee | Result |
|---|---|
| "Merchant declined" (G07-G09, C272/C313/C538 class) | review / REJECT |
| Ignore word inside the merchant name (Offer Mart, Click Pharmacy, Promo Burger, Won Kitchen, Promotion Plaza, Winner Sports, مقهى عرض خاص) | recorded on every side. These were **silent at `ab` and `base`**, so this is a fix. |
| Direction conflict → inbox | Holds on the import service (Q006/Q016/Q019/Q030 → inbox). The sync path calls the same `localParseContradictsServer` (`capture_sync_service.dart:953-964`). |
| K, L, N, O and P probe sets | The only worse items are the carried server declined-cue silences (device review). The `cr` set (PR-01): **0 worse**. The `nc` set (PR-02): silent 25 → **0**. |

## Findings

| ID | Sev | Finding | Required action |
|---|---|---|---|
| **QR-01** | **S1** | REGRESSION from this commit. The new server `creditKeywords` plus the "earliest word wins" rule (`parse.ts:724-734`), with no `transfer`/`تحويل`/`fee`/`charge`/`deducted`/`sent` debit words, turn completed debits into income. The matching `DirectionSignal` words (`direction_signal.dart:43-63`) stop the device from contradicting it, so the row imports **confirmed**. Effective: 18 (bank sender) and 15 (no sender) debits that were payment, transfer or review at both baselines. Server: 24. Outgoing transfers `…from your account into account of Ali`, fees `posted to/added to your account`, `Wages paid … from your account`, `Payroll Services Co … debited`. | Credit words must not override an outgoing marker (`from your account`, `debited`, `paid`, `transfer… to/into account of`, `charge`, `fee`). Add `transfer`/`تحويل` direction handling and the debit words. Use whole phrases (not `sent to you` inside `sent to your`). Add Q003/Q004/Q011/Q013/Q018/Q021/Q024/Q025/Q045-Q047 as `completed_payment` rows. |
| QR-02 | S2 | REGRESSION. The device pre-fills a wrong type or amount with a bank sender (pending): transfers containing `deposit`/`إيداع` → income (Q076-78, also with no sender); `Debit posted to your account`, `sent to your contact` → income; `movementActsOnFigure` clause (a) takes `Available limit SAR 5,000 debited` as 5,000 (Q157) and records balance or limit notices (Q140, Q147, Q158, Q159, Q162). | Limit the ATM-deposit rule to an ATM/cash token. Exclude `available`/`balance`/`limit` labels from clause (a). Add the probes as rows. |
| QR-03 | S2 | REGRESSION. Notices newly recorded as confirmed money on the effective path: Q151 `outstanding SAR 2,000 will be debited on 1 Dec` (review → payment), Q242 cashback advert (review → income), Q243 and Q248. | A future-tense or offer clause must not resolve on the server. |
| QR-04 | S3 | Carried. Server reject-with-no-AI on 27 completed rows against `ab` (declined-cue false positives). The device recovers each as review. | Keep tracked. |
| QR-05 | S3 | Table coverage. 941 rows carry no `currency`, including non-SAR texts. The rebuilt table encodes only the probed classes. The four left-out tip/VAT rows hide a pre-existing understatement. | Add `currency` to every row; add the tip/VAT truth. |
| QR-06 | S4 | The Dart preview mirror now differs from the Swift preview. | Sync, or document. |

## Verdict: **REJECT** (for this commit, under its own rule: "nothing may be worse than the baseline")

**Is anything worse than the baseline for a real user? Yes.**
1. QR-01: confirmed income for completed debits and outgoing transfers. 18 / 15 rows on the effective path, 24 on the server.
2. QR-02: wrong pending pre-fills on the device, 9 direction and 1 amount, plus 5 notices.
3. QR-03: 3-4 notices newly confirmed as money.

**Wrong outcomes `ab5dc10a` → HEAD, effective path with a bank sender:**

| Set | `ab5dc10a` | HEAD |
|---|---|---|
| P's sets | 206 | **18** |
| Table | 354 | **0** (self-referential) |
| Mine | 73 | **65** |

On my set the server went from 46 to **60**.

**Review cost of this commit:** 8 to 15 correct rows per side on my set; nothing became silent.

**Open:**
- QR-01 … QR-03;
- the pre-existing notices (34/46 of mine);
- the AI legs, installed builds and the deployed server, which I did not test.

No universal-coverage claim.

**Is `ab5dc10a`..HEAD as a whole safer than the baseline parser?**

On the evidence, yes in aggregate, and by a wide margin, on every set except my targeted one. Specifically:
- wrong amounts from limit and balance figures are fixed;
- declined and not-completed messages are no longer recorded (203–242 at `ab` → 0);
- silent loss is 0 on the device and on the effective path;
- the wrong-direction count on P's sets fell 10×.

It is **not** safe to ship as-is. This commit introduced a new, frequent-shaped class: outgoing transfers and fees confirmed as income, a total-changing error that is not pending.

The conditions to ship are:
1. Fix QR-01: credit words must yield to outgoing markers on the server and in `DirectionSignal`.
2. Fix QR-02 and QR-03, or get owner sign-off on them as pending, review-only defects.
3. Add my `q` probes, with hand truth, to the shared table, and re-run.
4. Show 0 worse-than-baseline on `q` + P + table, on all five sides.
