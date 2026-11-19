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
