# Review X follow-up check: `c9dc4ca4` against review X of `e5881120`

**Scope.** This is a narrow check of whether commit `c9dc4ca4` fixes the findings of review X. It is not a new audit.

**Where it ran.** Everything ran on a `git archive c9dc4ca4` copy in the scratchpad (`review-r5b/`). The worktree was not touched. The only files I added were harness copies inside the scratch copy.

**What was not used.** No Docker, network, production service or real model. `tools/message_eval/heldout/` and `real_model/sample_b.jsonl` were not read. All messages are synthetic.

## Verdicts

| Area | Verdict | Why |
|---|---|---|
| Money | **REJECT (narrow)** | **Fixed:** every X-M1..X-M5 reproduction text, on every path and with every stub. Further checks, all clean: (a) 0 wrong and 0 silent on review X's own 290 probes, server and all 9 device paths; (b) the acceptance tests now grade against labels; (c) a stale residual entry fails. **Not fixed:** part of X-M1. Review X explicitly named "added to / topped up … your account". These wordings, plus «قُيّد … لحسابك» and "You got … from", are still recorded in the model's flipped direction. They were moved into `flipped_residual.json` under the claim "the text gives the local parser no direction". That claim is false for them: a reader sees credit. Two new probes in this family are recorded wrong on 4 paths (N-M1). |
| Privacy | **ACCEPT WITH FOLLOW-UP** | X-P1, X-P2, X-P3 and S4 are fixed. TS, Dart and Swift outputs are identical (0 differences on 33 texts). Purchase merchants survive, and no amount or date is removed. Close variants of the X-P2/X-P3 wordings still send the name. These variants are pre-existing and leaked identically at `e5881120` (N-P1). |
| Restore | **ACCEPT** | X-R1 and X-R2 are fixed: pull first, then push, and a losing queued change is dropped. All 4 new tests fail when the fix is reverted in my copy, and pass with it. My own four probes pass on the fix. Two of them (ZZ-1, ZZ-3) also fail on revert. |

## Money

**Paths run.**
- Server: real handler `handleProcessIosSms` on `capture_rpc_fake`, with a Gemini fetch stub. Modes: AI off; correct; forged "completed" (the truth figure, and a debit "completed" answer for the 8 not-completed texts); flipped. Both rule parse + model and AI-primary.
- Device: the real `CaptureImportService` / `CaptureSyncService` / `AddTransactionUseCase` on in-memory Drift (a copy of `round5_money_acceptance_test.dart` pointed at my probe file), in 9 paths:
  - AI off;
  - AI-primary row: correct, wrong-completed, flipped;
  - rule-parse row: wrong-completed, flipped;
  - own model (`_tryAiParseFirst` with a fake `AiParserClient`): correct, wrong-completed, flipped.

### Per finding

Notation: `c`/`d` + amount = saved as credit/debit; REV = visible review.

| ID | Reproduced before? | Fixed now? | Evidence |
|---|---|---|---|
| X-M1 (15 texts) | yes (review X table) | **yes** for all 15 | **Server, flipped:** REV in both modes for all 15. **Server, correct stub:** right direction and amount for all 15. **Server, AI off:** `Your payroll … posted` → c 8500; the other 14 → REV. **Device, flipped:** REV on the AI-primary row, the rule-parse row and own model. **Device, correct and wrong-completed (own model / primary row):** right direction and amount. |
| X-M2 (7 texts; own-model path) | yes | **yes** | **Device own model, flipped:** REV for 6 of 7. `Refund for your purchase at Noon: SAR 150.00 returned to card *4521` is saved c 150, from the local reading: correct. **Server, flipped:** REV for all 7. **Acceptance test:** now runs the own-model path (3 modes, consent on). |
| X-M3 (test integrity) | yes | **yes** | `money_cases.jsonl` has 0 `model_dependent` marks. `mark_model_dependence.ts` and `model_dependence.json` are deleted. `grade()` compares with `expected[mode]`, which `build_money_cases.py` derives from the truth label only. **Mutation:** I added an id that is recorded right (`p01`) to the residual list of `server ai_flipped (rule parse + model)`. The test failed with `p01: listed as residual but no longer wrong`. Two wrong rows not listed (`p40`, `p41`) made the test fail. Listed, they passed. |
| X-M4 (4 texts) | yes | **yes** (safe, unnecessary review) | REV in every server and device mode, both stub directions. |
| X-M5 (2 texts) | yes | **yes** | REV everywhere. Own-model AI calls = 0: the harness asserts this, and the own-model modes passed. |
| X-M3 example `رصيدك بعد الخصم 5,000 ريال` with forged "completed" | yes (server stored a 5,000 debit) | **yes** | REV on both server modes and all device paths. |
| S3 labels (841/842/843/957 → r; pre_round/8, /84 → d; AM-R4M09a → t) | – | done | Read in `build_money_cases.py` `TABLE_RELABEL` / `RELABEL`. |

### Acceptance runs

All numbers are identical to the closure tables.
- **Server** `round5_money_acceptance_test.ts`: **7 passed, 0 failed** (32 min).
  - flipped, rule parse + model: 704 ok / 18 ok_alt / 732 review / **22 wrong** (all pinned residual)
  - flipped, AI-primary: 66 ok / 1388 review / **22 wrong** (pinned)
- **Device** `round5_money_acceptance_test.dart`, flipped modes only: **3 passed**.
  - AI-primary row: 39 wrong (pinned)
  - rule-parse row: 17 wrong (pinned)
  - own model: 23 wrong (pinned)
- 0 silent in all of these runs.

### New probes (44 completed texts plus 8 not-completed; none in `money_cases.jsonl`)

**Families covered:**
- salary, wages, bonus, dividend, deposit, cashback, interest;
- fee, charge, ATM, refund, reversal, fee reversal;
- own-account moves, received P2P, "landed / topped up / added / قُيّد";
- 18 Arabic.

**Results, flipped stub:**

| Path | Wrong saved | Silent | Unnecessary review (all modes, AI off included) |
|---|---|---|---|
| Server, rule + model | 2 (p40, p41) | 0 | – |
| Server, AI-primary | 2 (p40, p41) | 0 | – |
| Device, AI-primary row | 2 (p40, p41) | 0 | – |
| Device, own model | 2 (p40, p41) | 0 | – |
| Device, rule-parse row (forged deterministic flip) | 0 | 0 | – |

**Other modes:** correct, wrong-completed and AI off gave 0 wrong and 0 silent on every path. All 8 not-completed texts went to REV under a forged "completed" on every path.

**Unnecessary reviews (counted, not failures):**
- `Reversal of SAR 45.00 credited to your account *5678 for Test Diner`
- `Fee reversal SAR 25.00 credited …`
- `Late payment charge SAR 100.00 applied …`
- `عكس عملية بمبلغ 75 ريال لصالح بطاقتك *4521`
- the two own-account moves: REV, as intended

### Regressions vs review X's own probes

I re-ran review X's 290 money probes (`review-r5/probe/money_probes.jsonl`).
- **Server:** compared row by row with review X's `server_probe_out.json` at `e5881120`.
  - 0 regressions.
  - 32 row-modes that were wrong are now right.
  - The only "wrong" rows left are F12 (`Your card *4521 was charged USD 15.99 (SAR 60.12) at NETFLIX.COM` → debit USD 15.99), in 4 modes. Review X graded this the original-currency convention (ok_alt), not a wrong entry.
- **Device, all 9 paths:** 0 wrong and 0 silent.
  - The own model with flipped answers was review X's X-M2 case (18 wrong entries then); it is now 0.

### Residual judgement (`tools/acceptance/flipped_residual.json`, 56 distinct texts)

**Text states a direction a reader can see, yet it is pinned as "no direction":**

| Wording (variants with footers) | Reader sees | Paths pinned |
|---|---|---|
| `SAR 500.00 added to your account *5678` (+ ". Card activated", ". Available credit limit …") | credit | server both modes (1 each), device primary row (3), own model (1) |
| `Your account *5678 has been topped up with SAR 500.00` (+ "\nPIN-verified", ". Credit limit …") | credit | server (2 each), device primary (3), own model (2) |
| `قُيّد لحسابك *5678 مبلغ 2,000 ريال` («قُيّد لحسابك» = credited to your account; + statement / card-renewed footers) | credit | server, device primary, own model, rule-parse row |
| `قيد مبلغ 2,000 ريال لحسابك *5678 من علي` (+ 4 footers) | credit, and a person-to-person transfer (see N-M2) | server, device primary, own model, rule-parse row |
| `تم قيد مبلغ 2,000 ريال لحسابك *5678` (+ 4 footers) | credit | device rule-parse row |
| `You got SAR 750.00 from Ali via Test Pay` (+ 2 footers) | credit, and a person-to-person transfer (see N-M2) | server, device primary, own model |
| `SAR 300.00 posted to your account *5678 from Ali` (+ 4 footers); `SAR 3,000 posted to account *5678 from Test Corp` | credit | device rule-parse row |
| `Recharge balance SAR 100 for mobile via card *4521 successful`; `Balance recharge of SAR 100.00 completed using card *4521` | debit ("via / using card") | device rule-parse row |

**Rows per path with a stated direction:**

| Path | Rows with a stated direction |
|---|---|
| server, rule + model | 7 of 22 |
| server, AI-primary | 7 of 22 |
| device, AI-primary row | 15 of 39 |
| device, own model | 7 of 23 |
| device, rule-parse row | 15 of 17 |

**Fair as "no stated direction":** these carry a card plus merchant, or a merchant plus figure, and no direction word. A reader infers a purchase, but nothing states it.
- `SAR 250.00 Test Cafe 14:02`
- `Mada *4521 SAR 89.50 Test Mart …`
- `Apple Pay *4521 SAR 32.75 Test Coffee`
- `Online: USD 12.99 Test Stream card *4521`
- `بطاقة *4521 مبلغ 89.50 ريال Test Mart`
- `Card *4521 SAR 45.00 Test Mart …`
- `Repos Cafe / Posh Store / Positano Restaurant …`
- `مدى *4521 ٨٩٫٥٠ ر.س Test Mart`

**"Posted to your account" is truly ambiguous.**
- `Interest SAR 32.40 posted to your account *5678` (declined/1342) is labelled **d**.
- `Amount SAR 3,000 posted to your account *5678` (declined/1516) is labelled **c**.
- The same wording carries opposite labels. The `d` on interest is doubtful (S3 label note).

### New money findings

**N-M1 (S1): a credit stated by "topped up", "added to your account" or «قُيّد … لحسابك» is recorded as a debit when the model flips.** This is part of X-M1, which review X named explicitly and which remains open.
- Observed, flipped stub:
  - `Your account *5678 was topped up with SAR 1,800.00 by Test Corp` → **debit 1,800**. Saved on server rule + model, server AI-primary, the device AI-primary row and the device own model.
  - `قُيّد مبلغ 2,000 ريال لحسابك *5678 من شركة الاختبار` → **debit 2,000** on the same 4 paths.
- Cause: `localDirection` returns `unknown` for these texts. `zz_calls.ts` shows `local: "unknown"`, `meaning: uncertain/no_completed_form`, so the model's direction is accepted.
- Expected: review (`direction_contradiction`), or local credit.
- The same mechanism covers the 7/7/15/7 pinned residual rows above.

**N-M2 (S1 when combined with a flip; S3 as policy): a received person-to-person transfer reaches the model.**
- `You got SAR 750.00 from Ali via Test Pay`: `isTransfer` = false; model calls = 1 on both server modes. With a flipped answer it is saved as **debit 750**, and this row is pinned in the residual.
- `قيد مبلغ 2,000 ريال لحسابك *5678 من علي`: the same.
- `You received SAR 300.00 from Sara Ahmed via Test Pay`: model called (1 call rule + model, 3 calls AI-primary). It is safe: the local direction (credit) refuses the flip, so the result is review.
- Owner decision: person-to-person transfers are never sent to the model.
- Pre-existing: the same counts at `e5881120` (checked on an `e5881120` extract).

**N-M3 (S3, label):** declined/1342 `Interest SAR 32.40 posted to your account *5678` is labelled `d`. A reader would more likely read credited interest; it is at least ambiguous.

## Privacy

| ID | Reproduced before? | Fixed now? | Evidence (TS = Dart = Swift, same output) |
|---|---|---|---|
| X-P1 (4 texts) | yes (`e5881120` extract: names sent whole) | **yes** | `SAR 75.00 paid to [NAME] using your card *4521`. The Arabic text gives `دفع 85 ريال إلى: [REDACTED] مدى [ACCOUNT]`: over-masked, with «ببطاقة» and the own suffix lost. This over-masking is disclosed by the implementers. |
| X-P2 (4 texts) | yes | **yes** | e.g. `urpay: [NAME] requested SAR 150 from you`; `Request to pay EGP 250 from [NAME]. Accept in app` |
| X-P3 (2 texts) | yes | **yes** | `Beneficiary [NAME]: [NAME], IBAN [IBAN]`; `تمت إضافة مستفيد جديد: [NAME]` |
| X-S4 own suffix | yes | **yes** | `Salary SAR 8,000 credited from [NAME]. to account *5678` |

**Merchants in purchase wording survive.** All 9 of these survive unchanged, so a saved category rule still matches:
- `Jarir Bookstore`, `Starbucks`, «بنده», `Careem`, «نون», `Netflix`, `Al Baik`, `Hungerstation` (purchase or "at" wording);
- `Ahmed Trading` (business word).

`Payment of SAR 85.00 to Careem with card *4521` → `[NAME]`. This is per owner decision 2: payment wording is masked.

**Amounts, dates and times:** none removed in any of the 33 outputs.

**Parity:**
- TS (`redactThirdPartyNames(redactPii())`), Dart (`SmsSanitizer.sanitize`) and Swift (`swift_sanitize.sh`, compiled standalone with `swiftc`): **0 differences on 33 texts**.
- `_shared/privacy_acceptance_test.ts`: 2 passed.

**N-P1 (S2, pre-existing: identical output at `e5881120`): close variants of the X-P2 / X-P3 wordings still send the name.**
- `You have a payment request of SAR 200 from Majid Saeed` → sent whole.
- `Beneficiary added successfully: Rami Fawzi` → `Beneficiary [NAME] successfully: Rami Fawzi`.
- `A new beneficiary, Sami Odeh, was added to your account` → sent whole.
- Expected: the name masked.
- The fix matches the exact reported forms ("money request", "request to pay", "requested", "beneficiary added:") and misses these neighbours.

## Restore

| ID | Reproduced before? | Fixed now? | Evidence |
|---|---|---|---|
| X-R1 | yes | **yes** | `merchant_rule_precedence_test.dart`: 76 pass on the fix. **Implementers' tests, reverted fix in my copy** (`merchant_rule_sync_service.dart` from `e5881120`): all 4 fail — "X-R1 …", "X-R2 …", "no push unless the pull …", "the push-only flush …". **My probe ZZ-1** (Leave out queued; other device saves 1 h later on the device clock; 2 syncs): fix → `device=removed cloud=shopping queued=[] pending=1`; revert → `cloud=removed pending=0`. The fix file was restored and checked by `diff` against `c9dc4ca4`. |
| X-R2 | yes | **yes** | **ZZ-3** (cloud rule at −2 h pulled; offline edit "groceries"; other device "shopping" at +1 h): fix → `device=shopping cloud=shopping`; revert → `groceries/groceries`. |
| No push before a completed pull | – | **yes** | `_run` pulls first and pushes only if `pulled.completed`. The page-2 failure test fails on revert. |
| Older remote vs queued Leave out | – | ok | **ZZ-2** (other device older than the Leave out): `cloud=removed`. The removal wins and is pushed. |
| restore → sync → restore | – | ok | **ZZ-4**: `removed/removed` after both cycles: nothing lost, nothing resurrected. |

**Wider suites:**
- `test/features/planning_sync` + `destructive_path_inventory_test.dart`: 666 passed, 1 skipped.
- Test-harness caveat:
  - My first ZZ-3 version stamped the other device's edit with the device clock. That stamp was earlier than the fake cloud's own 2027 stamp of the previous row (the server clock moving backwards).
  - The older local edit then won. This is the disclosed clock limit (R4R-05), not a defect of the fix.
  - With realistic stamps the test passes.

**Remaining limits** (disclosed by the implementers; agreed):
- A one-run window between pull and push, because there is no server-side guard.
- Cross-device clocks.

## Not run / not checked

- Dart acceptance modes ai_off, ai_correct and ai_wrong_completed over the full 2,221-row set. I ran only the 3 flipped modes (all 9 modes did run on my 81 probes and review X's 290).
- iOS build and XCTest. Swift was checked only by compiling `sanitize` standalone.
- Real model, local Supabase stack, `parser_diff/run.sh` (review budget 336), `server_diff.sh`.
- Device-path regressions vs `e5881120`: not compared row by row, because there was no base Flutter build. The device showed 0 wrong on review X's probes, so nothing can have regressed into a wrong row.

## Scratch

- Report: `scratchpad/review-r5b-report.md`.
- Probes:
  - `scratchpad/probe/gen.py` and `probe_cases.jsonl`;
  - `server_out.json`, `dev_out.*.json`;
  - `priv_*.json`;
  - `x290_now.json`, `x290_dev.*`.
- Harness copies in the scratch copy: `zz_probe_test.ts`, `zz_calls.ts`, `zz_probe_test.dart`, `zz_priv_test.dart`, and the ZZ-1..4 tests appended to the scratch `merchant_rule_precedence_test.dart`.
