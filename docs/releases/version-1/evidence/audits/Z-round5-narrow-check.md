# Review Y follow-up check: `b2060a27` against N-M1, N-M2, N-M3 and N-P1

**Scope.** This checks only whether `b2060a27` fixes my review Y findings. It is not a new audit.

**Where it ran.** Everything ran on a `git archive b2060a27` copy in the scratchpad (`review-r5c/`). `countries.g.dart` was copied in read-only. No worktree was modified or run in.

**Limits.** No real model, network, Docker or iOS build. `heldout/`, `sample_b.jsonl` and `.env*` were not read. All messages are synthetic.

**How it ran.**
- **Server:** the real handler `handleProcessIosSms` on `capture_rpc_fake`, with a Gemini fetch stub. Modes: AI off, correct, forged "completed" and flipped. Both rule parse + model and AI-primary. Model requests were counted per row.
- **Device:** the real import, sync and add-transaction services on in-memory Drift, in 9 paths:
  - AI off;
  - AI-primary row: correct, wrong-completed, flipped;
  - rule-parse row: wrong-completed, flipped;
  - own model (`_tryAiParseFirst`): correct, wrong-completed, flipped.
  
  Own-model calls were counted per row.

## Verdicts

| Area | Verdict | Why |
|---|---|---|
| N-M1 (stated direction) | **ACCEPT WITH FOLLOW-UP** | Both reproductions and 21 new siblings go to review when the model flips. The old controls stay debit. One sibling was already wrong before and stays wrong: `Installment of SAR 250.00 added to your card *4521`. The new pattern now positively reads this debit as a credit (N-M1b). |
| N-M2 (person-to-person transfers kept local) | **ACCEPT WITH FOLLOW-UP** | Every wording in the new pattern makes 0 model requests on both server modes and the device. The salary through the redaction-then-parse order is saved right (credit 4,000 and 9,200). Other received-transfer wordings still reach the model: «وصلك … من», «استلمت … من», "X sent you", "topped up … by <person>" (N-M2b). None of them was saved wrong. |
| N-M3 (label) | **ACCEPT** | `declined/1342` is relabelled credit. It is no longer in the residual on the model paths. |
| Residual file | **ACCEPT** | Every remaining row on the model paths is a card or wallet text with a merchant and an amount and no direction word (15/15/24/16). The 16 forged device rule-parse rows are counted only. |
| N-P1 (privacy) | **ACCEPT WITH FOLLOW-UP** | All 3 reproductions and 14 siblings are masked. TS, Dart and Swift outputs are identical (0 differences on 32 texts). Purchase merchants survive, and amounts and dates are intact. Separately, names in received-transfer texts are still sent; this is pre-existing (N-P2). |
| Regressions vs my `c9dc4ca4` probes | **none** | Server and all 9 device paths: 0 rows newly wrong or silent. 4 server and 4 device row-modes were fixed (p40, p41). |

## N-M1: stated direction

Probe file: 45 texts. 39 are not in `money_cases.jsonl`; the 6 already there are y1-1, y1-2, t08, t09, t10 and b02. The server ran each text raw and also after `redactPii` + `redactThirdPartyNames`.

### Reproductions

| Text | Fixed? | Evidence |
|---|---|---|
| `Your account *5678 was topped up with SAR 1,800.00 by Test Corp` | **yes** | Server, flipped: review (rule + model and AI-primary). Correct model: credit 1,800. Device, flipped (AI-primary row, own model): review; correct: credit 1,800. |
| `قُيّد مبلغ 2,000 ريال لحسابك *5678 من شركة الاختبار` | **yes** | Same results, credit 2,000. |

### New siblings

**Credit wordings, 14 texts: all 14 go to review when flipped, on both server modes and both device model paths:**
- `SAR 2,300.00 has been added to your account *5678 by Test Corp`
- `Your account *5678 has been topped up with SAR 75.00 cashback`
- `SAR 640.00 posted to account *5678 from Test Insurance claim`
- `You got SAR 120.00 back from Test Airline`
- `تم قيد 1,200 ريال لحسابك *5678 مستحقات نهاية الخدمة`
- `أضيف مبلغ 450 ريال لحسابك *5678`
- `قيد لحسابك مبلغ 900 ريال تعويض`
- `تمت إضافة 650 ريال إلى حسابك *5678`
- `Funds of SAR 980.00 have been added to your account *5678`
- `Your balance was topped up by SAR 60.00`
- `SAR 500.00 landed in your account *5678 from Test Corp`
- `Your wallet *9001 was topped up with SAR 330.00 refund from Test Store`
- `أضيفت 275 ريال إلى رصيد حسابك *5678`
- `An amount of SAR 1,500.00 was added to your card *4521`

Two of these behave differently but stay correct:
- `تمت إضافة 650 ريال إلى حسابك *5678` and `Your wallet *9001 was topped up with SAR 330.00 refund from Test Store` are recorded locally as credit (650 and 330) on the server with AI off and under rule parse + model with the flip.

**Debit wordings and traps, 7 texts:**
- 6 are right or review:
  - `Recharge of SAR 30.00 for your mobile line made using your card *4521`
  - `Your prepaid line has been topped up with SAR 50.00 via card *4521`
  - `تم شحن رصيد جوالك بمبلغ 50 ريال من بطاقتك *4521`
  - `Transaction of SAR 45.00 at Test Mart has been added to your card statement *4521`
  - `SAR 99.00 subscription charge added to your card *4521`
  - `تم قيد 250 ريال على حسابك *5678 رسوم سنوية`
- 1 is wrong: see N-M1b below.

**Controls, all unchanged:**

| Text | Result |
|---|---|
| `Fee SAR 10 added to your account *5678` | debit 10, or review. Never income. |
| «تم دفع 500 ريال لحسابك في شركة الكهرباء» | debit 500 |
| «دفع 500 ريال لحسابك لدى Test Mart» | debit 500 |
| `Purchase SAR 85.00 at Topped Up Cafe card *4521` | debit 85 |

### Counts with a flipped stub

| Path | Wrong saved | Silent |
|---|---|---|
| Server, rule + model | 1 text (d05), raw and redacted | 0 |
| Server, AI-primary | 1 text (d05), raw and redacted | 0 |
| Device, AI-primary row | 1 (d05) | 0 |
| Device, own model | 1 (d05) | 0 |
| Device, forged deterministic rule-parse row | 4 | – |

The 4 forged rule-parse rows are counted only, as agreed: `SAR 640.00 posted … from Test Insurance claim`, `تم قيد 1,200 ريال لحسابك …`, `Recharge of SAR 30.00 …`, `Ali Hassan sent you SAR 120.00`.

### N-M1b (S1, pre-existing; the new pattern now asserts it): an installment "added to your card" is read as credit

- **Text:** `Installment of SAR 250.00 added to your card *4521`. Truth: debit 250.
- **Now:**
  - Flipped model: **saved as credit 250** on server rule + model, server AI-primary, the device AI-primary row and the device own model.
  - Correct model: review (`direction_contradiction`), because `statedCreditPattern` "added to your card" sets the local direction to credit.
  - AI off: review.
- **At `c9dc4ca4`:** flipped also saved credit 250, and the correct model was saved as debit 250. So the wrong entry is not new, but the correct answer is now refused.
- **Expected:** "added to your card" alone should not state a credit, so that the model decides; or "installment" should be a debit word.

## N-M2: received person-to-person transfers

### Model requests

The server figures cover both modes; the device figure is the own-model path.

| Text | Server model requests | Device model requests | Result |
|---|---|---|---|
| `You got SAR 200.00 from Omar Khalid via Test Pay` | 0 | 0 | review everywhere (AI off as well) |
| `You have received SAR 150.00 from Lina Saad` | 0 | 0 | server credit 150; device review |
| `تم قيد مبلغ 300 ريال لحسابك *5678 من خالد سعيد` | 0 | 0 | review |
| `You received SAR 75.00 from Ahmed via STC Pay` | 0 | 0 | server credit 75; device review |
| `You got SAR 750.00 from Ali via Test Pay` (Y repro) | 0 | 0 | review |
| `قيد مبلغ 2,000 ريال لحسابك *5678 من علي` (Y repro) | 0 | 0 | review |
| `You received SAR 300.00 from Sara Ahmed via Test Pay` | 0 | 0 | server credit 300; device review |

At `c9dc4ca4` the same table had 1–3 model requests per row, and two rows saved a debit when flipped.

### Business senders

| Text | Result |
|---|---|
| `You got SAR 50.00 from Test Bank cashback` | goes to the model as intended; flipped → review |
| `تم قيد 8,000 ريال لحسابك من شركة الاختبار راتب` | goes to the model as intended; flipped → review |
| `Credit transaction: SAR 4,000.00 from Test Corp Payroll` | goes to the model as intended; flipped → review |
| `You received SAR 4,000.00 from Test Corp Payroll` | raw on the server: credit 4,000 with 0 model requests (local credit reading) |
| `You have received SAR 1,350.00 from Al Noor Hospital` | treated as a person: "hospital" is not a business word. Server: credit 1,350, 0 model requests. Device: review. Not wrong. |
| `تم قيد 600 ريال لحسابك *5678 من مستشفى النور` | treated as a person: review everywhere. Not wrong. |

### Through the handler order (TS redaction, then the real handler)

| Text after redaction | AI off | Correct model | Wrong-completed model | Flipped model | Model requests |
|---|---|---|---|---|---|
| `You received SAR 4,000.00 from [NAME]` | credit 4,000 | credit 4,000 | credit 4,000 | credit 4,000 | 0 |
| `You received your salary SAR 9,200.00 from [NAME]` | credit 9,200 | credit 9,200 | credit 9,200 | credit 9,200 (rule + model); review (AI-primary, 3 requests) | – |

- `Credit transaction: SAR 4,000.00 from Test Corp Payroll` is not redacted. It behaves as raw: review with AI off, credit 4,000 with a correct model, review when flipped.
- **No salary is saved wrong or lost silently.**

### N-M2b (S3 policy; no wrong entry seen): other received-transfer wordings still reach the model

| Text | Server requests | Device own model |
|---|---|---|
| `وصلك 250 ريال من نورة أحمد` | 1 | 1 |
| `استلمت 400 ريال من محمد العتيبي` | 1–3 | 1 |
| `Ali Hassan sent you SAR 120.00` | 1 | 1 |
| `Your wallet was topped up with SAR 95.00 by Ali Hassan` | 1 | 1 |

- **Results:** with a flipped answer, all four go to review. The stated or local credit refuses the flip, so nothing is saved wrong.
- **What the model sees:** the name is masked in the first three. The fourth sends "Ali Hassan" (see N-P2).
- **Expected by the owner decision:** no model request.

## Residual file (`tools/acceptance/flipped_residual.json`)

| Path | Rows | Stated direction? |
|---|---|---|
| server rule + model | 15 | none |
| server AI-primary | 15 | none |
| device AI-primary row | 24 | none |
| device own model | 16 | none |
| device rule-parse row (forged) | 16 | counted only |

- The model-path rows are 15 base texts: card or wallet, merchant and amount, for example `SAR 250.00 Test Cafe 14:02`, `Mada *4521 SAR 89.50 Test Mart 17/11/26`, `Repos Cafe SAR 45.00 card *4521`. The device AI-primary row adds 9 footer variants of them.
- None states a credit or a debit. "Added", "topped up", «قيد لحسابك», "You got … from" and "posted … from" are gone from the model paths.

## N-P1: privacy

Each pair shows the output at `c9dc4ca4` → the output at `b2060a27`.

| Text | `c9dc4ca4` | `b2060a27` (TS = Dart = Swift) | Fixed? |
|---|---|---|---|
| `You have a payment request of SAR 200 from Majid Saeed` | sent whole | `… from [NAME]` | yes |
| `Beneficiary added successfully: Rami Fawzi` | name sent | `Beneficiary added successfully: [NAME]` | yes |
| `A new beneficiary, Sami Odeh, was added to your account` | sent whole | `A new beneficiary, [NAME], was added …` | yes |

**14 new siblings:**
- 6 were already masked at `c9dc4ca4`: `Fund request …`, `Bilal Ahmad sent you a money request …`, `Payee Noor Haddad has been added …`, `Your new payee: …`, «طلب تحويل …», `You received a payment request from …`.
- 8 leaked at `c9dc4ca4` and are masked now:

| Text | Now |
|---|---|
| `New payment request: SAR 75 from Hala Mansour. Tap to view` | `… from [NAME]. Tap to view` |
| `Payment requests pending: SAR 300 from Fahad Nasser` | `… from [NAME]` |
| `Rana Khoury was added as a new beneficiary` | `[NAME] was added …` |
| «تمت إضافة المستفيد بنجاح: هند العلي» | `… [NAME]` |
| «تم إضافة ماجد القحطاني كمستفيد جديد» | `تم إضافة [NAME] كمستفيد جديد` |
| «طلب أموال بقيمة 100 ريال من عبدالله الشمري» | `… من [NAME]` |
| `Request for money: SAR 45 from Dana Yousef on 17/11` | `… from [NAME] on 17/11` |
| `Beneficiary Rami Fawzi activated on 17/11/2026` | `Beneficiary [NAME] on 17/11/2026` (status word dropped; date kept) |

**Merchants in purchase wording survive unchanged:** Jarir Bookstore, Starbucks, «بنده», Careem, «نون», Netflix, Al Baik, Hungerstation, "Ahmed Trading".

**Amounts, dates and times are intact in all 32 outputs.**

Parity: TS against Dart (`SmsSanitizer.sanitize`) gives 0 differences; TS against Swift (`swift_sanitize.sh`, compiled standalone with `swiftc`) gives 0 differences.

### N-P2 (S2, pre-existing: identical at `c9dc4ca4`): names in received-transfer texts are sent

| Text | Output |
|---|---|
| `You got SAR 200.00 from Omar Khalid via Test Pay` | sent whole |
| `تم قيد مبلغ 300 ريال لحسابك *5678 من خالد سعيد` | sent whole |
| `Your wallet was topped up with SAR 95.00 by Ali Hassan` | sent whole |

- These texts are uploaded to the server even though they now stay off the model. The last one is also sent to the model (N-M2b).
- Expected: the name masked.

### Over-masking (pre-existing, S3)

- `Purchase SAR 60.00 at Payee Coffee card *4521 17/11` → `… at Payee [NAME] card [ACCOUNT] 17/11`. The merchant and the own card suffix are lost, so a saved rule for "Payee Coffee" will not match.
- `Your order request from Amazon …` → `[NAME]`, as the implementers disclosed.

## Regressions vs my `c9dc4ca4` probe outputs

I re-ran my 81 probes (`probe/probe_cases.jsonl`) and review X's 290 probes.

- **Server, compared with my saved `server_out.json` / `x290_now.json`:**
  - 0 regressions.
  - 4 row-modes fixed: p40 and p41 under both flipped modes.
  - 2 harmless changes: `You received SAR 400.00 from Test Corp …` and `You received SAR 300.00 from Sara Ahmed via Test Pay` move from review to credit under AI-primary flipped, because they are read locally.
  - The 290 probes are unchanged.
- **Device, all 9 paths, compared with my saved `dev_out.*` / `x290_dev.*`:**
  - 0 regressions.
  - 4 row-modes fixed: p40 and p41 under the AI-primary row and own model.
  - p23 (`You received SAR 300.00 from Sara Ahmed via Test Pay`) moves from saved credit 300 to review in 5 modes. It is now a local-only transfer, and the device's own reading does not record it. This is an unnecessary review, not a loss; the server itself records credit 300.
  - The 290 probes are unchanged.

## Not run

- The full acceptance suites (`round5_money_acceptance_test.ts` / `.dart`) on `b2060a27`, `parser_diff/run.sh` and `server_diff.sh`. I ran only my probes and review X's.
- iOS build and XCTest; Swift was checked only through the standalone `sanitize`.
- Real model and local Supabase stack.
- The device harness substitutes a "review" server row for texts it detects as transfers (the AI-primary row and rule-parse row paths), so device import results for person-to-person transfers reflect that substitution, not a real server row.

## Scratch

- Report: `scratchpad/review-r5c-report.md`.
- Probes and outputs in `scratchpad/probe-c/`:
  - `gen2.py`, `probe2.jsonl`, `probe2_red.jsonl`;
  - `srv2_table.txt`, `dev2_table.txt`;
  - `priv2_*.json`;
  - `srv_old_*.json`, `dev_old_*`.
- Harness copies are inside `review-r5c/` (`zz_*`). Build output was removed in `review-r5c` and `review-r5b`.
