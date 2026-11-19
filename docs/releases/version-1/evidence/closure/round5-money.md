# Round 5 — money correctness (owner decision: completion certainty)

Worktree `release-readiness/v1`, base `2f9931cb`. Nothing committed, pushed or
deployed. No real model was called (every model answer in tests is a stub);
`tools/message_eval/heldout/` and `real_model/sample_b.jsonl` were not read.
This record replaces the first round-5 version: the routing now follows the
owner's choice "uncertain → the model decides (AI on); review only when AI is
off, the model is unclear, or the call fails".

## The rule (one rule, device and server)

A message is **recorded on its own reading only when it is clearly completed**:
a completed-event form (a done verb, a movement lead, a known completed
wording, or a clause flow) and **no doubt anywhere outside a security-advice
clause**. Patterns: `parser_rules.json → completionCertainty`, Dart twin
`app/lib/engine/parser/completion_certainty.dart`, TS twin
`supabase/functions/process-ios-sms/completion_certainty.ts`, drift test
`completion_certainty_test.dart`.

| doubt family | examples |
|---|---|
| negated | has not been credited, لم يتم رد |
| hedged | may, will, can be, due, expected, tomorrow, within, سيتم, المستحق |
| pending | pending, awaiting, requires, request, reminder, بانتظار, جاري (not «الحساب الجاري») |
| question | a money clause ending in ?, reply/press/tap/click + object, to confirm |
| cancelled | cancelled, reversed, declined, failed, attempted, ملغاة, معكوسة |
| late | late, overdue, penalty, متأخر, غرامة |
| reference | previous/last purchase, آخر عملية, العملية السابقة |

Security advice ("If you did not make this transaction…", "Not you?",
"Failure to report…", «إذا لم تقم…», «لا تشارك…») is set aside clause by clause.

`meaningOf` / `messageMeaning` turn a record reading into one of two classes:

- **(a) `uncertain:no_completed_form`**: no doubt anywhere, only a wording the
  rules do not know as completed («عملية انترنت … USD», "Trx. of AED…»,
  «تأكيد السداد», «إضافة أموال»…).
- **(b) `uncertain:not_clearly_completed`**: a doubt is present.

Category precedence is unchanged.

## Routing (coordinator items 1–5)

| path | clearly completed | (a) no completed form | (b) doubt present | transfer |
|---|---|---|---|---|
| device alone, AI off | recorded | review (reason `no_completed_form`) | review (reason `not_clearly_completed`) | its own reading: recorded when the flow states the direction, else review |
| server, rule parse + model (`parse.ts` hybrid) | recorded | model asked. **completed**, figure and currency grounded in the text, direction not against a direction the text names → **recorded** (meaning becomes `completed_movement:model_completed`). **pending/declined/future/cancelled** → not counted. **unclear or failed call** → review | model asked. pending/declined/future/cancelled → not counted. **completed → review, never recorded** (`textDoubts`) | never sent to the model (`localTransferOutcome`) |
| server, AI-primary (`parsePrimarySms`) | as the model reads it (validated) | same as the row above | same as the row above | never sent to the model |
| device import of a server row (`CaptureImportService`, `CaptureSyncService`) | imported if `validateCaptureCandidate` passes | a row whose `parserSource` is `ai`/`ai_hybrid` and whose type is not `transfer` is model-decided and imported; a rule-parse row is held | held → Smart Inbox with the reason | held, or imported as its own reading |
| device with its own model (`AddTransactionUseCase._tryAiParseFirst`) | local reading | model asked; the validator accepts a "completed" answer (as the server does) | model asked; a "completed" answer is rejected → review | never asked (`transfer_local_only`) |

**What the user sees when the model says pending/declined/future/cancelled:**
no money row. The server stores a rejected capture (`is_transaction: false`).
The device shows it as a review item in Smart Inbox with the reason; it is
not counted in totals. A model "unclear" answer or a failed call is the same
review item, with `model_unclear` or the failure reason.

**The direction hazard (item 2).** When the text names a direction (the
clause flow, else the earliest money keyword: debit/purchase/POS/مدى/خصم vs
credit/deposit/salary/refund/إيداع), a model answer in the other direction is
not accepted. The row becomes review (`direction_contradiction`).
- Server: `modelFlipsDirection` with `namedDirection` (`parse.ts`), on both
  model paths.
- Device import: `namedDirection` in `validated_capture.dart`, the same lists
  (drift-tested against `parser_rules.json`). It only ever rejects, never
  records.

**The model never decides a transfer.**
- Server: `decidedByModel` needs a non-`transfer` model type.
- Device validator and import: `modelDecided` is false for a `transfer` type
  or text.

The acceptance set found the case that needs this: a wallet top-up from the
user's own card, recorded as an expense from a "completed" model row.

**Transfers (item 3).** Transfers stay local-only. A plain transfer notice with
no doubt is recorded when its own flow states the direction («حوالة واردة 500
ريال من …», "SAR 500 transferred to Ali from your account", «حوالة صادرة»,
"sent to").

Not done as asked: a bare "Transfer SAR 1,000 to Ali for rent deposit" /
«تحويل 2,000 ريال لإيداع دفعة شقة» is **review**. The first implementation
recorded those plain transfers, and the acceptance set caught **2 wrong
entries**: the only direction available was a purpose word ("deposit",
«إيداع»), read as a credit. The direction of such a notice is not grounded
in the text on either runtime, so it stays review on both:
- server `localTransferOutcome`: no direction from a purpose word alone;
- `uncertaintyOf`: a transfer is no longer a completed form by itself.

32 such labelled completed transfers in the set remain unnecessary reviews.
Recovering them needs a transfer-direction reader ("to <name>" vs "from
<name>", own-account discrimination), which is not built.

**AI off (item 4).** Known completed wordings come only from the golden
real-world fixtures: «عملية انترنت», «إضافة أموال», «الشراء عبر الانترنت»,
«تأكيد السداد», "Trx. of". Seven of the nine fixtures moved to review in the
first version are back to their original status.
The two BSF fixtures stay review on purpose: they carry «المبلغ الإجمالي
المستحق», a hedged (due) doubt.
- `ambiguous_bsf_three_amounts`
- `sa_bsf_pos_three_amounts`

**Entry points (item 5).**

| entry point | does it ask a model? | what it does with an uncertain text |
|---|---|---|
| device, `AddTransactionUseCase` (manual paste, iOS Shortcut local path, Android notification) | yes, its own client (`_tryAiParseFirst`) when AI is allowed | (a) and (b) are asked (transfers never); the validator records (a) on "completed", reviews (b) |
| server `process-ios-sms` rule parse + model (`parse.ts` hybrid) | yes | as in the routing table |
| server `process-ios-sms` AI-primary | yes | as in the routing table |
| server `parse-sms` | shares `parse.ts` | same |
| device `CaptureImportService` / `CaptureSyncService` (server row import) | no (reads the server's answer) | `modelDecided` from `parserSource` + type; named-direction check |

## Other money fixes this round (unchanged from the first version)

- Device import: a limit, balance or minimum-due figure is never the amount
  (`amount_is_account_figure`), routed to Smart Inbox.
- Device type (Q072): "Payment of SAR 1,500 for security deposit to …" is a
  payment.
- `local_validity.dart`: an amount ≤ 0 is never valid money.
- Every kept-for-review row carries a reason (R4M-08).

## Acceptance set (`tools/acceptance/money_cases.jsonl`, 2,204 rows, frozen)

The builder now reproduces the frozen file byte for byte (item 8). It was run
three times on the final code and `cmp` showed no difference; the earlier 2-row
drift is gone.

Model-dependent marks come from `tools/acceptance/mark_model_dependence.ts` →
`model_dependence.json`, read by the server meaning of the final code:
- `wrong_completed` (17 rows): truth n/r/i/t, class (a), not a transfer.
- `flipped` (398 rows): truth d/c, the text names no direction.

A forged answer on such a row is, by construction, indistinguishable from a
right one. It is graded `model_dependent` and counted separately, not hidden.

Modes, both runtimes:
- `ai_off`
- `ai_correct`: the right answer.
- `ai_wrong_completed`: the forged "completed" with a figure of the text.
- `ai_flipped` (new): the forged answer with the direction swapped,
  1,462 rows with a figure.

Server: Deno `process-ios-sms/round5_money_acceptance_test.ts` (real handler,
stubbed model). Device: Dart `app/test/features/capture/round5_money_acceptance_test.dart`
(real AddTransactionUseCase / CaptureImportService / CaptureSyncService on an
in-memory database). Both fail on any wrong or silent row.

### Server (Deno, final code)

| mode | ok | ok_alt | unnecessary review | **wrong** | **silent** | **model-dependent** | model requests |
|---|---|---|---|---|---|---|---|
| ai_off | 1368 | 19 | 741 | 0 | 0 | 0 | 0 |
| ai_correct, rule parse + model | 1594 | 19 | 515 | 0 | 0 | 0 | 1585 |
| ai_correct, AI-primary | 1573 | 5 | 550 | 0 | 0 | 0 | 2117 |
| ai_wrong_completed, rule parse + model | 1579 (+1 own-account) | 20 | 514 | 0 | 0 | 1 | 1581 |
| ai_wrong_completed, AI-primary | 1558 (+1 own-account) | 6 | 549 | 0 | 0 | 1 | 2237 |
| ai_flipped, rule parse + model | 653 | 18 | 606 | 0 | 0 | 185 | 1325 |
| ai_flipped, AI-primary | 63 | 0 | 1213 | 0 | 0 | 186 | 3349 |

Notes:
- 76 / 75 ignored truths are not recorded (`ok_ignored`).
- No transfer reached the model (asserted per row).
- "+1 own-account": declined/1344, a wallet top-up from the user's own card.
  The server has no neutral type, so it stores the forged debit with the
  model's type; the device books it (see the device table).

### Device (Dart, final code)

| mode | ok | ok_alt | unnecessary review | extra review | **wrong** | **silent** | **model-dependent** |
|---|---|---|---|---|---|---|---|
| ai_off (device alone) | 1273 | 8 | 890 | 33 | 0 | 0 | 0 |
| ai_correct (AI-primary row) | 1606 | 5 | 543 | 50 | 0 | 0 | 0 |
| ai_wrong_completed (AI-primary row) | 1566 | 6 | 542 | 75 | 0 | 0 | 1 |
| ai_wrong_completed (rule-parse row) | 1524 | 7 | 585 | 74 | 0 | 0 | 0 |
| ai_flipped (AI-primary row) | 0 | 0 | 1274 | 0 | 0 | 0 | 188 |
| ai_flipped (rule-parse row) | 78 | 1 | 1293 | 0 | 0 | 0 | 90 |

`extra review` means a not-completed or ignored truth kept visible in Smart
Inbox. ai_off also has one recorded purchase with its stated fee as a second
row (`with_stated_fee_row`, both right).

The device model-dependent row in ai_wrong_completed is declined/1344, the
wallet top-up from the user's own card. A forged "completed payment" answer
books it as an expense. A right model answer of type `transfer` is never
model-decided: it stays review.

Before the device named-direction check, ai_flipped (AI-primary row) had
**17 wrong** entries and (rule-parse row) 4: "Direct debit SAR 89", "Payroll
credit SAR 8,500", "POS … 89.50", «مدى … ٨٩٫٥٠», "Debit posted …". The
server already reviewed them; the device import did not. They are now 0.

### Where the AI-on unnecessary reviews are (server, ai_correct)

Unnecessary reviews fell from 741 (AI off) to 515 (rule parse + model) and
550 (AI-primary). The first version had 616 / 652.

The rest, by reason (rule parse + model):

| reason | rows | why it stays review |
|---|---|---|
| (b) doubt present | 178 | 99 hedged, 37 cancelled, 20 pending, 13 negated, 9 late. Owner rule: a "completed" answer against a textual doubt is never recorded |
| `undetermined:no_event_amount` | 104 | pre-existing (the rule parse finds no movement amount; not a round-5 hold) |
| transfer, local only | 57 | owner rule: never sent to the model; no stated flow |
| (a) no completed form | 58 | the model was asked; its answer failed another gate (grounding, several amounts, account figure) |
| footer set aside / single event | 46 | pre-existing gates (hybrid reading vs footer) |

## Review findings → rule / route

Outcomes below are AI off. With AI on, a class-(b) text stays review on any
model answer, and a class-(a) text is decided by the model.

| id | outcome now | rule / route |
|---|---|---|
| R4M-01 (unpaid bill at its total) | review | hedged (can be / must / should), question, late; meaning gate rejects stated totals that are not clearly completed |
| R4M-02 (late/overdue repayment, reminder) | review | late family; hedged "by 25/11" |
| R4M-03 (refund not received / cancelled) | a–b, d–e review; c ("Cancelled orders are refunded…" footer) unnecessary review | cancelled / hedged / negated |
| R4M-04 (advice removed a future reading) | review | advice set aside clause by clause only |
| R4M-05 (completed movements newly held) | still review (unnecessary) | awaiting/انتظار footers are pending; transfer without stated flow; «حركة مدينة/دائنة» and "International transaction" have no completed form (model decides with AI on); standing-order footer hedged |
| R4M-06 (pending merchant confirmation) | review | pending + question families |
| R4M-07 (harness hides a recorded declined message by label) | fixed | `VERIFIED_COMPLETED` id list in `diff.py`, printed every run; planted check 1 / 1 / 1 / 0 (control) |
| R4M-08 (review rows without reason) | fixed | `reviewReason` on device use case and import |
| R4M-09 (parity) | 09a fixed (reverse named-accounts form on both sides) | `_namedAccounts` / NAMED_ACCOUNTS |
| R4M-10 (build 147 + new server) | the listed texts are review on the new server | hedged / cancelled / transfer rules; not re-run with build 147 |
| AR-02 (redacted pending transfer) | review | redaction keeps «بانتظار التأكيد»; transfer never to model; pending family |
| AR-03 | review | hedged |
| AR-04 a–d | review | pending, negated, hedged |
| AR-05 a–b | review | negated |
| AR-06 a–b (completed purchase + other-order refund footer) | unnecessary review | the footer's request/pending words; a doubt is not scoped to another order |

## Declined-state table

`declined_cases.json` was re-pinned on the final code: completed rows that
are not clearly completed are `device: review` / `server: unresolved` (safe
deviations). The allowlist count and both ceilings
(`declined_state_cues_table_test.dart` `_maxDeviations`, `parse_test.ts`
`MAX_DEVIATIONS`) are **794** (703 at HEAD; 798 in the first version).

## Harnesses

`bash tools/parser_diff/run.sh 5dae2e2d` (AI off on every path; the server
side counts "would reach the model" as review):
- Regressions 0; base not-completed now recorded 0; wrong → other wrong 0.
- Moves: right → review 228 messages; unlabelled record → review 103; fixed
  222; wrong/silent → review 50; review → right 203.

Labelled, base → work:

| path | wrong | silent | review | right |
|---|---|---|---|---|
| dB (device, bank sender) | 204 → 3 | 1 → 0 | 511 → 640 | 1148 → 1221 |
| dN (device, unknown sender) | 128 → 3 | 4 → 2 | 774 → 857 | 958 → 1002 |
| s (server rule parse) | 156 → 8 | 38 → 11 | 602 → 695 | 1068 → 1150 |
| eB (device import, bank) | 212 → 6 | 0 → 0 | 478 → 604 | 1174 → 1254 |
| eN (device import, unknown) | 182 → 6 | 0 → 0 | 586 → 688 | 1096 → 1170 |

**Right → review (item 7):**
- **AI off: 331 messages** (384 in the first version).
- **AI on, right model: 256**, estimated: the 331 minus the 75 whose meaning
  is class (a) and that are not transfers, which the model decides.
  Computed by `scratchpad/round5/ai_on_review.ts` over the run's move list.

The 331 split by meaning:

| meaning | messages |
|---|---|
| doubt present | 197 (14 of them transfers) |
| no completed form | 89 (14 of them transfers) |
| cash deposit | 28 |
| other holds | 17 |

**Budget: proposed and applied 331.** `tools/parser_diff/diff.py`
`REVIEW_BUDGET` default and the `run.sh` header now say 331. Commented in the
code as a consequence of the owner's completion-certainty rule, with this
split. It was 38.

Justification:
- Every one of the 331 is a review the owner's rule requires when AI is off.
  A doubt is never recorded on any reading. A text without a known completed
  form is decided only by the model. A cash deposit and a transfer with no
  stated flow are kept for review.
- None is a wrong or silent entry, and regressions stay 0.
- The harness cannot see AI-on outcomes. A smaller AI-off budget would force
  rules the owner rejected (recording no-form texts without the model).

The diff step re-run with the new default exits 0; `run.sh` returns the diff
step's status.

`bash tools/parser_diff/server_diff.sh`: exit 0.
- Regressions 0.
- rejected → processed 184; processed → rejected 757; processed, booking
  changed 65; recorded → rejected (pre-round not-completed invariant) 7.

`bash tools/parser_diff/server_diff.sh a157e68e`: exit 0.
- Regressions 0.
- rejected → processed 11; processed → rejected 226; booking changed 3.

## Item 6 — `dart format` damage in the privacy owner's files

Both files were fully short-style formatted in the working tree; HEAD was not.
Comparing each against a formatted copy (`dart format --language-version=3.5`)
gave the result below:
- `sms_sanitizer.dart`: 286 differing lines; 8 of its 55 diff hunks are
  whitespace-only.
- `sanitization_edit_map.dart`: 18 differing lines; 3 of its 11 diff hunks
  are whitespace-only.

Those 11 hunks were separable and are reverted (`git apply -R --unidiff-zero`
of exactly those hunks). Verified:
- each file's non-whitespace content is identical before and after;
- `dart analyze lib/engine/privacy` reports no issues.

Two re-indented lines in `sms_sanitizer.dart` (an SM-07 comment and a
`replaceAllMapped(` line) sit inside the owner's own restructured hunks. They
were left untouched.

## Commands and results (final code)

- `flutter analyze`: no issues found.
- Flutter tests, the 233-file list plus `completion_certainty_test.dart`: 7,263
  passed, 1 failed. The failure is the privacy/rules owner's
  `outbound_payload_test.dart` "payment wording masks the payee; purchase
  wording keeps its rule". It exercises the rule repository, not parser code.
- `deno test --allow-all --no-check process-ios-sms parse-sms _shared`: 1,382
  passed, 0 failed, 2 ignored (includes the server acceptance set, all 7
  modes).
- `deno lint process-ios-sms parse-sms _shared`: clean (118 files).
- Dart acceptance: `flutter test test/features/capture/round5_money_acceptance_test.dart`: 6/6 modes pass (31m48s), table above.

## Open / not verified

- Model-dependent rows (above): their correctness rests on model accuracy by
  construction. The real-model evaluation is the measure; it was not run here.
- Bare transfers without a stated flow stay review (see Transfers).
- The device's named-direction check reads the whole text, footers included.
  It adds about 12 review rows on correct model rows (device ai_correct 531 →
  543), never a recorded row.
- Not run: iOS build/Shortcut, build 147, real model, local Supabase stack.

## Follow-up: payment-instrument tail in the merchant

`Payment of SAR 85.00 to Careem with card *4521` gave the device merchant
"Careem with card *4521", so a saved rule for "Careem" did not match
(`outbound_payload_test.dart`). It was the same at a157e68e: the device read
"Careem with card *4521" / "using card ending 4521" / "via Apple Pay" there
too. The server already cut the English tails at "with/using/via" but kept
«ببطاقة مدى *4521» / «عبر Apple Pay» in the Arabic merchant (at a157e68e as
well).

Fix:
- Device `ParserEngine._cleanMerchant`: a trailing "with/using/via [your]
  [credit/debit/prepaid] card / Apple Pay / Google Pay / Samsung Pay / mada /
  STC Pay", «ببطاق…», «عبر/باستخدام/بواسطة» + card or wallet ends the
  merchant.
- Server `parser_rules.json merchantStopPattern`: «ببطاق…» and «عبر/باستخدام»
  before a card or wallet word.
- The preview asset `app/assets/catalog/parser_rules.json` (Swift/closed-app
  preview) was not changed.

Shared table: `process-ios-sms/merchant_instrument_cases.json` (9 cases,
including two controls: "Card Factory" and «متجر بطاقات الهدايا»), read by
`process-ios-sms/merchant_instrument_test.ts` and
`app/test/engine/parser/merchant_instrument_test.dart`.

Results:
- `outbound_payload_test.dart` passes.
- Flutter tests: 7,273 passed, 0 failed.
- Deno: 1,391 passed, 0 failed.
- Both acceptance runs and all three harnesses: every number is identical
  to the tables above. The declined-table pins and the 794 ceiling are
  unchanged. `run.sh` exits 0 (331 against a budget of 331).

## Follow-up: independent review X (money REJECT at e5881120)

Source: `docs/releases/version-1/evidence/audits/X-round5-review.md`, X-M1..X-M5.
The design is kept; the fixes are rules, not word lists where a rule does it.
Nothing committed.

### X-M1 / X-M2 (S1): a flipped model direction was recorded — fixed

Rule, on every path that accepts a model answer (server rule parse + model,
server AI-primary, device import/sync of model rows via
`validateCaptureCandidate(fromModel:)` / `modelRowDirectionRefused`, and the
device's own-model path `AddTransactionUseCase._tryAiParseFirst`, through
`AiCandidateValidator.validate`, which now refuses a model direction that
contradicts the local reading; own-account moves there stay local):

- the model's direction is accepted only when it equals the direction the
  local parser itself derives for the text (`localDirection` in `parse.ts`,
  `DirectionSignal.localOf` on the device — the same reading that records the
  row when AI is off);
- local direction known and the model disagrees → review
  (`direction_contradiction`; the server keeps a more specific held reason
  through `refusalReason`);
- local direction unknown → the model's direction is accepted only for class
  (a), no completed-event form. Those are the only model-dependent rows.

Local reading extended where it was missing: whole-word `payroll`, `wages`,
`bonus`, `dividend`, `cashback`, `charge(d)`, `billed`, `renewed`,
`authorised/authorized`, `mpos/epos` (whole-word, so "deposited" no longer
reads as "epos"); debit flow "transferred from your"; «لحسابك» removed as a
credit word (it names the destination of a payment as often as a credit);
named nouns ("X store/mart/shop/market", "cashback card", "security
deposit", «متجر/محل/مطعم …») and a marked merchant ("at"/"@"/«لدى») no longer
cast a direction.

Reviewer texts, server (rule parse + model / AI-primary), stub model:

| Text (abridged) | AI off | flipped model | correct model |
|---|---|---|---|
| payroll SAR 8,500 posted to account | credit 8500 | review (direction_contradiction) | credit 8500 |
| Payroll / Bonus SAR … to account from Test Corp | review (no form) | review (direction_contradiction) | credit |
| «أودع مبلغ 2,000 ريال في حسابك» / «مكافأة 2,000 ريال لحسابك» | review | review (direction_contradiction) | credit 2000 |
| Dividend / Rent … arrived in account / Cashback … added to your card | review | review (direction_contradiction) | credit |
| Fee … added to your account / Annual card fee applied / billed by Test Telecom | review | review (direction_contradiction) | debit |
| «المبلغ المخصوم 75.00» / «سُدد مبلغ 300» | review | review (direction_contradiction) | debit |
| ATM cash SAR 500 / Gym membership renewed on card / Debit SAR 45 card | review | review (direction_contradiction) | debit |
| Refund … returned to card / Standing order executed / «سداد فاتورة 300» | recorded right | review (direction_contradiction) | recorded right |

Device: the same texts are in `completion_certainty_test.dart` and the X rows
of the acceptance set; 0 wrong on every device path (tables below).

### X-M3 (S1, test integrity): exemptions computed by the code under test — fixed

`mark_model_dependence.ts` is gone. Every acceptance row carries a hand or
source-derived truth direction; in the ai_flipped modes any recorded row
whose direction differs from truth is counted wrong. The only allowed ones
are pinned, per path, by id and text in `tools/acceptance/flipped_residual.json`
("recorded with the model's flipped direction because the text gives the
local parser no direction"); a wrong row not listed, or a listed row that is
no longer wrong, fails the test. The device acceptance test also runs the
own-model path (AI consent on, fake client).

Residual (this file must be tracked for `head_completeness_test` to pass):

| Path | Residual rows | Why |
|---|---|---|
| server, rule parse + model | 22 | class (a): no completed-event form, e.g. "SAR 250.00 Test Cafe 14:02", «بطاقة *4521 مبلغ 89.50 ريال Test Mart», "SAR 500.00 added to your account" |
| server, AI-primary | 22 | class (a), same texts |
| device, AI-primary row | 39 | class (a) |
| device, own model | 23 | class (a) |
| device, rule-parse row (forged) | 17 | a deterministic server row forged with a flipped direction; the device checks direction only on model rows, so it trusts it (e.g. "SAR 300.00 posted to your account *5678 from Ali", «تم قيد مبلغ 2,000 ريال لحسابك») |

The 17 are not a model answer: they need a server that sends a wrong
deterministic row. Extending the device check to all server rows closes them
but breaks capture fixtures that use placeholder `rawMessage`s; left as a
decision.

### X-M4 (S1, pre-existing, AI off): local direction errors — fixed (review)

Rule (`conflictingCues`, both sides): a text with direction cues of both
families for the event, or more than one movement figure with both families,
is not "clearly completed" → uncertain (review / model class), unless the
clause flow settles it (a source of funds named and no own destination, or a
side credit / reward clause separate from the amount sentence). Own-account
moves exit first.

| Text | before | now (server and device, every mode) |
|---|---|---|
| Purchase SAR 150.00 at Noon card *4521 completed. Merchant confirmation received | credit | review (conflicting_cues) |
| POS Refund SAR 64.50 HYPERPANDA card *4521 | debit (server) | review (conflicting_cues) — safe, an unnecessary review |
| Arabic cashback 50 vs purchase 500 | credit 500 | review (conflicting_cues) |
| Purchase SAR 20 …, cashback SAR 50 credited | credit 20 | review (conflicting_cues) |

These, the U §1 cashback texts and R4M-10 are in the frozen set
(`money_cases.jsonl`, regenerated once by `build_money_cases.py`, byte for
byte reproducible: 2,221 rows — d 1,187, n 586, c 289, i 76, r 64, t 19).

### X-M5 (S2): own-account moves — fixed

"Your STC Pay wallet was topped up with SAR 100 from Al Rajhi card *45…" and
«تم تحويل 300 ريال من بطاقتك الائتمانية إلى حسابك الجاري» → review
(own_accounts) on every path, no model request; never spending or income.
In all acceptance modes no transfer or own-account row reached the model.

### S3 labels — corrected

declined/841, 842, 843, 957 → r; pre_round/8 → d; pre_round/84 → d;
AM-R4M09a → t. `pre_round_not_completed.json` still lists the pre_round/8 and
pre_round/84 texts (not changed here; owner's call).

### Case pins changed

- H03 (follow_up3): defect fixed; pin removed.
- S05 (follow_up3), N1a / N1g / N1i (follow_up4): now review on both sides
  (X-M4 rule).
- DEV060 (follow_up5), AT004a / AT004b (follow_up6): server review pin removed
  (now recorded right).
- Declined table re-pinned: 137 server-unresolved pins and 14 device-review
  pins removed, 1 device → review, 1 server → unresolved; deviations 771.

### Acceptance (final code, stub model; wrong includes residual)

Server, 7/7 passed, 0 silent:

| Mode | ok | ok_alt | ok_ignored | unnecessary review | wrong | of which residual | model requests |
|---|---|---|---|---|---|---|---|
| ai_off | 1,505 | 19 | 76 | 621 | 0 | 0 | 0 |
| ai_correct, rule parse + model | 1,612 | 19 | 76 | 514 | 0 | 0 | 1,576 |
| ai_correct, AI-primary | 1,556 | 5 | 76 | 584 | 0 | 0 | 2,106 |
| ai_wrong_completed, rule parse + model | 1,598 | 20 | 75 | 514 | 0 | 0 | 1,573 |
| ai_wrong_completed, AI-primary | 1,542 | 6 | 75 | 584 | 0 | 0 | 2,229 |
| ai_flipped, rule parse + model | 704 | 18 | — | 732 | 22 | 22 | 1,336 |
| ai_flipped, AI-primary | 66 | — | — | 1,388 | 22 | 22 | 3,360 |

(Round 5 at e5881120: ai_off 1,368 ok / 741 unnecessary review; flipped
"0 wrong" only after 185–186 rows were exempted by production code.)

Device, 9/9 passed, 0 silent:

| Mode | ok | ok_alt | unnecessary review | extra review | wrong | of which residual |
|---|---|---|---|---|---|---|
| ai_off | 1,273 | 8 | 907 | 33 | 0 | 0 |
| ai_correct, AI-primary row | 1,587 | 5 | 579 | 50 | 0 | 0 |
| ai_wrong_completed, AI-primary row | 1,547 | 6 | 579 | 75 | 0 | 0 |
| ai_wrong_completed, rule-parse row | 1,533 | 7 | 593 | 74 | 0 | 0 |
| ai_flipped, AI-primary row | — | — | 1,437 | — | 39 | 39 |
| ai_flipped, rule-parse row | 78 | 1 | 1,380 | — | 17 | 17 |
| ai_correct, own model | 1,631 | 8 | 549 | 33 | 0 | 0 |
| ai_wrong_completed, own model | 1,618 | 8 | 549 | 32 | 0 | 0 |
| ai_flipped, own model | 577 | 8 | 868 | — | 23 | 23 |

ai_off also records one purchase with its stated fee as a second row
(`with_stated_fee_row`), as before.

### Review budget

`run.sh 5dae2e2d` with the budget lifted measures **336** messages to review
(was 331), 0 regressions. `REVIEW_BUDGET` default in `tools/parser_diff/diff.py`
(and the `run.sh` comment) is now 336, so there is again zero headroom by
design: any further move to review fails until justified.

### Other harnesses and suites

- `flutter analyze`: no issues. Dart engine/domain/architecture/core/data/
  adversarial: 10,065 passed, 23 skipped, 1 failed (`head_completeness`:
  the acceptance test reads the untracked `tools/acceptance/flipped_residual.json`;
  clears once it is tracked). Capture files: 1,673 passed.
- Deno process-ios-sms / parse-sms / _shared (acceptance excluded): 1,412
  passed, 0 failed, 2 ignored.
- `server_diff.sh` (base b6fc0dad): 0 regressions; 300 rejected → processed,
  734 processed → rejected, 88 booking changed. Against a157e68e: 0
  regressions; 157 / 233 / 3 booking changed (all wrong direction → right).
  MA39 «Cashback card annual fee SAR 150 deducted …» is review → debit 150 on
  both (it was recorded as income before "cashback card" became a named noun).

### Not verified

- POS Refund HYPERPANDA is now an unnecessary review (safe).
- The 17 forged deterministic rows on the device rule-parse path (see X-M3).
- `pre_round_not_completed.json` still lists pre_round/8 and pre_round/84.
- No iOS build / Shortcut, no real model, no local Supabase stack.

## Follow-up: independent re-review Y (money REJECT, narrow, at c9dc4ca4)

Source: `docs/releases/version-1/evidence/audits/Y-round5-rereview.md`
(N-M1..N-M3). No new mechanism. Two patterns join the existing
`completionCertainty` patterns (`parser_rules.json`, mirrored in
`CompletionCertainty`, drift-tested in `completion_certainty_test.dart`), and
the transfer pattern grows. Nothing committed.

### N-M1: a direction the wording states — fixed

`statedCreditPattern` / `statedDebitPattern` (folded text, read by
`statedDirection` in `completion_certainty.ts` and
`CompletionCertainty.statedCredit` on the device):

- credit: "added to your account/card/wallet", "topped up with", "has
  been / was topped up", "you got <amount>", "posted to (your) account …
  from", and «قيد / أضيف … لحسابك» (verb-bound only; bare «لحسابك» still
  names no direction);
- debit: "recharge … via / using / with / by card".

Both are read only as the last step of the local direction a model answer
must agree with (`localDirection`, `DirectionSignal.localOf`), so nothing
newly records with the AI off. Controls unchanged: «تم دفع 500 ريال لحسابك في
شركة الكهرباء» and «دفع 500 ريال لحسابك لدى Test Mart» stay debit, "Purchase
… at Topped Up Cafe" stays debit, "Fee … added to your account" stays debit.

| Reproduction | AI off | flipped model (both server paths) | right model |
|---|---|---|---|
| Your account *5678 was topped up with SAR 1,800.00 by Test Corp | review | review (direction_contradiction) | credit 1,800 |
| «قُيّد مبلغ 2,000 ريال لحسابك *5678 من شركة الاختبار» | review | review (direction_contradiction) | credit 2,000 |
| SAR 500.00 added to your account / has been topped up with SAR 500.00 / «قُيّد لحسابك … 2,000» / «تم قيد … لحسابك» | review | review (direction_contradiction) | credit |
| SAR 300.00 posted to your account from Ali; Recharge … via/using card | review | review (direction_contradiction) | credit / debit |

Device: the same texts are in `completion_certainty_test.dart` (local
direction, model refused when flipped, accepted when right); the server twin
is `review_x_direction_test.ts`.

### N-M2: received person-to-person transfers — fixed (local only)

`transferPattern` adds "you (have) got/received <amount> from <person>" and
«… لحسابك … من <شخص>», where the sender is not "your/account/card" and has no
business word (corp, company, ltd, llc, inc, est, trading, group, bank,
holding, ministry, university, payroll, salary, store, mart, shop, market;
«شركة، مؤسسة، مجموعة، بنك، مصرف، متجر، مطعم، محل، وزارة، هيئة، جامعة، راتب»).

| Text | model requests (both server modes) | result |
|---|---|---|
| You got SAR 750.00 from Ali via Test Pay | 0 | review (no completed form), as with the AI off |
| «قيد مبلغ 2,000 ريال لحسابك *5678 من علي» | 0 | review, as with the AI off |
| You received SAR 300.00 from Sara Ahmed via Test Pay | 0 | credit 300, as with the AI off |
| «قُيّد … من شركة الاختبار», "You received … from Test Corp Payroll" | not a transfer (business word) | as before |

The server parses redacted text: a name the redaction already judged a
person arrives as `[NAME]` (or «[REDACTED]»), and the pattern accepts that
placeholder as the person. The redaction also turns "from Test Corp Payroll"
into "[NAME]", so on the server that credit is read locally too (never the
model; its own reading has the "received" credit flow). Not probed through
the handler. The device reads the raw text and keeps the
business-word check.

### N-M3: label — corrected

declined/1342 `Interest SAR 32.40 posted to your account *5678` was
`completed_payment`; credited interest is the plain reading, as declined/1516
(`Amount SAR 3,000 posted to your account`, credit). Now `completed_income` in
`declined_cases.json`. Both sides keep it as review/unresolved (the pin is
unchanged).

### Frozen set and residual

`build_money_cases.py` adds Y-NM1-topped-up, Y-NM1-quyyid and Y-NM2-received
(the "You got … Ali" and «… من علي» texts were already declined/737 and
declined/1014 and keep those ids). Regenerated once: 2,224 rows.

`tools/acceptance/flipped_residual.json` after removing every row that is no
longer wrong:

| Path | before | now | what remains |
|---|---|---|---|
| server, rule parse + model | 22 | 15 | no stated direction: card/wallet + merchant + amount ("SAR 250.00 Test Cafe 14:02", "Mada *4521 SAR 89.50 Test Mart", "Apple Pay … Test Coffee", "Online: USD 12.99 Test Stream card", «بطاقة *4521 مبلغ 89.50 ريال Test Mart», "Repos Cafe / Posh Store / Positano Restaurant …") |
| server, AI-primary | 22 | 15 | same |
| device, AI-primary row | 39 | 24 | same family, with footers |
| device, own model | 23 | 16 | same family |
| device, rule-parse row (forged deterministic row) | 17 | 16 | untouched: the device checks direction on model rows only. declined/1018 («قيد … لحسابك من علي. تم تفعيل البطاقة») left because it is now a person-to-person transfer. |

Every residual row on the model paths is now a text with no stated direction.

### Acceptance (final code, stub model; wrong = residual)

Server, 7/7 passed, 0 silent, no transfer or own-account row reached the model:

| Mode | ok | ok_alt | ok_ignored | unnecessary review | wrong (= residual) | model requests |
|---|---|---|---|---|---|---|
| ai_off | 1,506 | 19 | 76 | 623 | 0 | 0 |
| ai_correct, rule parse + model | 1,620 | 19 | 76 | 509 | 0 | 1,568 |
| ai_correct, AI-primary | 1,564 | 5 | 76 | 579 | 0 | 2,088 |
| ai_wrong_completed, rule parse + model | 1,606 | 20 | 75 | 509 | 0 | 1,565 |
| ai_wrong_completed, AI-primary | 1,550 | 6 | 75 | 579 | 0 | 2,211 |
| ai_flipped, rule parse + model | 705 | 18 | — | 741 | 15 | 1,328 |
| ai_flipped, AI-primary | 68 | — | — | 1,396 | 15 | 3,340 |

Device, 9/9 passed, 0 silent:

| Mode | ok | ok_alt | unnecessary review | extra review | wrong (= residual) |
|---|---|---|---|---|---|
| ai_off | 1,273 | 8 | 910 | 33 | 0 |
| ai_correct, AI-primary row | 1,595 | 5 | 574 | 50 | 0 |
| ai_wrong_completed, AI-primary row | 1,555 | 6 | 574 | 75 | 0 |
| ai_wrong_completed, rule-parse row | 1,531 | 7 | 598 | 74 | 0 |
| ai_flipped, AI-primary row | — | — | 1,455 | — | 24 |
| ai_flipped, rule-parse row | 78 | 1 | 1,384 | — | 16 (forged) |
| ai_correct, own model | 1,638 | 8 | 545 | 33 | 0 |
| ai_wrong_completed, own model | 1,625 | 8 | 545 | 32 | 0 |
| ai_flipped, own model | 577 | 8 | 878 | — | 16 |

ai_off and the own-model modes also record one purchase with its stated fee
as a second row (`with_stated_fee_row`), as before.

### Harnesses and suites

- `run.sh 5dae2e2d`: 0 regressions; 336 messages to review, so the budget
  stays 336.
- `server_diff.sh` (b6fc0dad): 0 regressions (300 / 734 / 88, as before);
  against a157e68e: 0 regressions (157 / 233 / 3).
- Deno process-ios-sms / parse-sms / _shared (acceptance excluded): 1,424
  passed, 0 failed, 2 ignored. `review_x_direction_test.ts`: 40 passed.
- Dart test/engine + test/domain + test/architecture: 6,152 passed; capture
  files: 1,673 passed; `completion_certainty_test` + drift: 97 passed.
  `flutter analyze`: no issues.

### Not verified

- The 16 forged deterministic rows on the device rule-parse path (they need a
  server that sends a wrong deterministic row; the device does not check
  rule-parse rows).
- On the server, a redacted business sender ("[NAME]") is read as a person
  and stays local; with a credit flow it records as before with the AI off.
- No iOS build / Shortcut, no real model, no local Supabase stack.
