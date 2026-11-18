# Round 4 — redaction before transmission (implementer `privacy`)

Working tree on `release-readiness/v1` at `41b39127`; nothing committed. Synthetic data only.
Model: Claude Fable 5.2 (`claude-fable-5-2`), as stated by the session's own system prompt.

Owner's instruction: "Fix redaction before transmission. Cover the confirmed English and Arabic personal-name leaks and third-party account suffixes across the iOS Shortcut, app, and backend. Inspect the actual outbound payloads using synthetic data. Add paired cases where a person's name must be removed and a merchant's name must survive so an enabled saved category rule still matches."

Added during the run by the orchestrator (real-model run at `a157e68e`): one-time codes reached the model; the word "confirm" was masked as a name.

## Status

| Item | Status |
|---|---|
| A. Leak classes 1 and 2 closed in Dart, TypeScript and Swift | DONE (limits in section G) |
| B. Merchants, amounts, dates, status words survive; paired cases | DONE |
| C. Saved category rule still matches after redaction | DONE (tests; no categorisation code changed) |
| D. Outbound payloads inspected | DONE for the app upload, the app's AI request, the server's model request, stored row, response and logs. PARTIAL for the Shortcut: the body is rebuilt field for field in XCTest with source pins, because the gated transport has no capture seam. One OPEN leak found outside my paths (shared learning, below). |
| E. Frozen-copy diff test extended to `5dae2e2d` | DONE |
| F. Device == server == Swift, generated parity set | DONE |
| G. What still survives | Listed below |
| One-time codes (added) | DONE in all three; one compatibility note for the deployed server |
| "confirm" → `[NAME]` (added) | DONE |

## What was wrong in the partial work I took over

The uncommitted edits masked every card suffix without a possessive (so every card purchase lost its own `*4321`), put "payment/paid" into the transfer context (which turned "to be paid", "to get", "to STC did not go through" into `[NAME]` and ate status words), left `MASK-0` unfixed and bloated the labelled fixture with 249 generated rows. I restored my files to `HEAD` and rewrote the change.

## The rules

All three implementations run the same passes in the same order. Person or merchant is decided from the text alone; the Dart `detectedType` hint is accepted but no longer used (it was the cause of the «إلى حساب <name>» leak under `payment`).

**Names (new):**
- Field labels, any message: Attn, Attention, Name (not "Merchant name"), Customer, Cardholder, Account holder, عناية, الاسم, اسم, العميل, حامل البطاقة, صاحب الحساب.
- "account of <Name>", «حساب باسم <name>», any message.
- A name in parentheses after an account or card number, unless the text reads as a purchase.
- "From <Name>:" and «من <name>:» headings, next to the existing "To <Name>:".
- "Payment … to <Name>" (capitalised words only, so "payment to X did not go through" keeps the status).
- No cue: "<Name> sent you …" / "<Name> has transferred … to your …"; «أرسل لك <name>», «قام <name> بتحويل»; a full name (two words or more) right after Transfer / حوالة / تحويل before the amount.

**Merchant, not person (by structure, never by a list of names):**
- The text reads as a purchase, refund or bill (existing word list), or as a card payment: it names the user's own card and has no transfer word (`MASK-1`).
- The name carries a business marker (shop, store, market, company, LLC, trading, مكتبة, شركة, متجر, أسواق …; one list, `COMPANY_MARKERS`).
- The run after «إلى»/"To:" is kept in those cases (`MASK-0`), unless it is an account or card object, starts with a number, or carries a long number or a masked name.

**Account and card suffixes — the exact rule** (`sms_redaction.ts`, "Account and card suffixes"). A number of 1–4 digits after an account, card or wallet label is kept only when the text marks it as the user's own, checked in this order:
1. Third party, always masked: the label carries or follows beneficiary / payee / sender / recipient / المستفيد / المرسل, follows a masked name, or is followed by a name in parentheses.
2. Own, kept: a possessive label (your, my, حسابك, بطاقتك, حسابي …).
3. A destination (to / into / in, إلى / في, لحساب) is masked, unless a credit verb governs it in the same clause ("credited to account", "refund … to card", «إيداع في حساب») and the text has no transfer-out word (transferred, sent, paid, حولت, دفع).
4. A card not caught above is kept, except "from card" in an incoming message with no debit verb.
5. In a purchase, refund or bill, an account, wallet or star-masked number that is not a destination is kept.
6. Otherwise an account is kept only as the source ("from / with / using / via account", «من حساب»; in an incoming message only after a debit verb), or when the text has no other party at all (no transfer or payment word, no masked name).

A labelled number of 5 digits or more is always masked.

**One-time codes.** A 4–8 digit code is masked as `[OTP]` when it follows a cue (OTP, one-time password/passcode/code, verification / security / activation / confirmation / authentication / access / login / secret code, passcode, password, code, كلمة المرور (لمرة واحدة), كلمة السر, رمز/كود التحقق/الدخول/التفعيل/الأمان/التأكيد, الرمز السري, الرقم السري, رمزك, الرمز, رمز, كودك, الكود, كود), when the cue is earlier in the sentence and the code follows "is" / «هو», when the code comes first ("482913 is your … code"), after "Use / Enter / استخدم / أدخل", and before "do not share" / «لا تشارك». A figure next to a currency, a decimal or grouped figure, a date or time and a card or account suffix are never a code. "Approval / auth / authorization / reference / transaction / receipt / pickup / promo code" is not a one-time code and is left.

**"confirm".** The rule was the counterparty cue `to` + name in a transfer text. After the bare prepositions "to" and "by", a single lower-case Latin word is now an ordinary word, not a name. Two or more words are still masked ("to nadir zaki"), and "from" is unchanged. `now`, `here`, `then` and a set of notice words were added to the stop list.

## Files changed

- `supabase/functions/_shared/sms_redaction.ts`
- `app/lib/engine/privacy/sms_sanitizer.dart`, `sanitization_edit_map.dart`
- `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift` (`BackendCaptureClient.sanitize` and its word lists only)
- Fixtures: `_shared/fixtures/sms_leak_labelled_cases.json` (93 → 204 rows), `sms_redaction_cases.json` (2 rows), new `sms_redaction_parity_cases.json` (290 rows), new frozen copy `sms_redaction_5dae2e2d.ts`
- Tests: `_shared/sms_redaction_head_diff_test.ts`, new `_shared/sms_redaction_parity_test.ts`, new `_shared/sms_outbound_payload_test.ts`, `app/test/engine/privacy/sms_name_minimization_test.dart`, new `app/test/engine/privacy/outbound_payload_test.dart`, `app/ios/RunnerTests/RunnerTests.swift` (3 new tests)

## Tests, and how they failed before

Measured with the `HEAD` copy of `sms_redaction.ts` (identical to `a157e68e`) on the new fixture rows:
- 111 new labelled rows: 67 differ from the expected text, 52 leak a tagged name, number or code, 16 lose something that must stay.
- The 93 earlier rows are unchanged.
- 168 of the 290 generated parity rows differ.
The Dart and Swift tests read the same files, and all three implementations were identical at `HEAD`, so they fail the same rows.

New tests:
- Labelled set, 204 rows (Deno, Flutter, XCTest): expected text, no tagged secret, must-keep words, idempotence, edit map.
- Pairs: 38 person/merchant rows (paid to, payment to, To:, إلى, from, من, bill, POS, online, refund, beneficiary, لصالح, transfer to, salary) and 10 code/amount rows.
- Generated parity set: 29 templates × 5 people × merchants × 3 number forms (Western and Arabic-Indic). Deno writes the fixture and refuses a stale one; Flutter and XCTest must reproduce it.
- Frozen-copy diff against `4d54d258` and `5dae2e2d` over 2,800+ texts: no digit run the older version removed is emitted, except amounts, dates and two documented own-suffix cases (possessive with "ending"/«المنتهية»; the card of a purchase). No tagged secret an older version removed is emitted.
- Rule key: for merchant rows the server's `merchantRuleKey` and the device's `AppDatabase.normalizeMerchant` are equal for raw and redacted text, and a saved user rule in an in-memory database still matches. For person rows no name is a merchant or a merchant key.

## Outbound payloads — what is transmitted

| Payload | Fields carrying message text | Result on 204 rows |
|---|---|---|
| App → `process-ios-sms` (`CaptureBackendClient.processIosSms`) | `smsText`, `sanitizedText` (both the redacted text). Others: `sender`, ids, `receivedAt`, `locale`, `tzOffsetMinutes`, `textLength`, flags, owner | No tagged token in any string field |
| App → `parse-sms` (`SupabaseAiParserClient`) | `sanitized_sms` only; `sender_id` is not sent | No tagged token, including under the `payment` hint |
| Shortcut → `process-ios-sms` | `smsText`, `sanitizedText` (redacted); `sender`, `senderName`, `senderId` as given by the Shortcut | No tagged token (body rebuilt in the test; see Status) |
| Server → model | The redacted text inside the prompt | No tagged token, with a client that redacted nothing, in both analysis modes |
| Server stored row, response, push, logs | Redacted text and the parse | No tagged token |
| Shared learning (`merchant_key`, `category_key`) | The merchant key | **OPEN**, see below |

## OPEN: needs a change outside my paths

`sharedContributionFor` (`app/lib/domain/services/shared_category_learning.dart`) can build a contribution whose `merchant_key` is a person's name when the row is typed as a payment and the text has no transfer word: "paid to Sara Ahmed" → `SARA AHMED`, "Payment … to Nadir Zaki via Mada", "Bill payment … to account of Nadir Zaki". It is sent only for an opted-in user who confirmed a category for that row. I added `SmsSanitizer.masksPartOf(message, merchant)`; the fix is one line before the key is built:

```dart
if (SmsSanitizer.masksPartOf(message, raw)) return null;
```

`outbound_payload_test.dart` proves the helper recognises all four rows and reports the leak as a skipped expectation until that line is in.

## Parse outcomes

Another implementer is changing the parser, so I separated the two. Same parser (working tree), `HEAD` redaction against mine, over 4,328 cases:
- No message changed between processed and rejected. No amount, currency, type or direction changed on a processed row.
- 27 distinct texts changed on the server path only (device paths identical):
  - 26 one-time-code messages. All were and are rejected. 16 of them used to go on to the AI and now stop at the server.
  - «دفع 300 ريال إلى الاتصالات بانتظار التأكيد» is now read as not completed: the old redaction removed the status words.
- `last4` changed on 139 rows and `merchant` on 38; neither is part of the harness outcome. They are third-party or unmarked suffixes now masked, and merchants now kept or masked.

Harness results on the working tree:
- `tools/parser_diff/run.sh 5dae2e2d`: exit 1. 0 regressions of the "right → wrong/silent" kind; 9 "base not-completed, now recorded", all `fu6/*` refund and footer cases, on the device paths as well, which do not use redaction. They belong to the parser work. To review: 38 of 38.
- `tools/parser_diff/server_diff.sh` (base `b6fc0dad`): exit 0, 0 regressions.
- `tools/parser_diff/server_diff.sh HEAD`: exit 0, 0 regressions; every listed move is a `fu6/*` case.

## Runs

- Deno, `deno test --allow-all` in `supabase/functions`: 1,623 passed, 0 failed, 6 ignored. `deno lint _shared/`: clean. `deno.lock` unchanged.
- Flutter (`PUB_CACHE=$HOME/.pub-cache flutter test --no-pub -j 2`):
  - `test/engine/privacy test/engine/sms_sanitizer_test.dart`: 354 passed, 1 expectation skipped (the OPEN item).
  - `test/engine/ai`: 176 passed.
  - `test/engine/categorizer_test.dart test/engine/categorization test/engine/merchant_boundary_test.dart test/engine/merchant_intelligence_eval_test.dart test/data/catalog test/data/merchant_rule_deleted_category_test.dart test/engine/proof`: 289 passed.
  - `test/features/capture`: 1,698 passed.
  - `test/engine/parser/follow_up5_money_correctness_test.dart` and the eight architecture source-contract tests that read the Swift file: 275 passed.
- `flutter analyze` (whole app): 1 warning, in `test/features/capture/follow_up6_final_effect_test.dart` (not mine). My files are clean.
- Parity over 2,866 corpus texts plus the three fixtures: Dart `sanitize` and `sanitizeWithMap` equal the server on all; the Swift `sanitize` function, compiled standalone on macOS from the source file, equals the server on all 3,414 rows.
- XCTest: see the last section.

## Existing expectations changed

- `sms_redaction_cases.json` `en_salary`, `ar_salary`: the employer ("ACME TRADING LLC", «شركة الأفق») is now kept. It carries a business marker; it is a company, and salary categorisation uses it.
- `sms_name_minimization_test.dart`, golden corpus: the last-digits check is skipped for a transfer whose text has no possessive. "To: <name>" then "Acc:3583*" does not mark the account as the user's, so it is masked (two fixtures).
- `sms_redaction_head_diff_test.ts`: the allowed own-suffix shapes gained "ending"/«المنتهية» after a possessive and the card of a purchase.

## G. What still survives redaction

Kept on purpose: amounts, currencies, dates, times, tense and status words, cue words, merchant and bank names, and the user's own suffix under the rule above.

A third party's data can still leave the device in these cases:
1. **A name in a message that reads as a purchase, refund, bill or card payment and has no person label**: "Purchase from Nadir Zaki", "Card *4521: SAR 85 paid to Nadir Zaki", «شراء … إلى نادر زكي». The structure is that of a merchant.
2. **A name with a business marker word in it** ("Ahmed Trading", «مؤسسة محمد»): kept as a business.
3. **A name with no cue outside the three shapes covered**; a one-word name right after "Transfer"/«حوالة»; a lower-case Latin name after "payment … to" or before "sent you"; a single lower-case Latin word after "to"/"by".
4. **A third party's suffix of 4 digits or fewer** where the wording is the same as for the user's own: a card with no destination, sender or beneficiary word; "credited to account *9876" with no transfer-out word; "from account *5678" in a text with no incoming word; any account in a purchase, refund or bill that is not a destination.
5. **Unlabelled numbers of up to 9 digits** outside the beneficiary's sentence (for example a field line «من:5678»). A bare short number is far more often an amount.
6. **Codes**: a code with no cue and no "do not share"; a 9-digit code; a code with letters in it; approval, reference, receipt and promo codes (left on purpose).
7. **Phone numbers** that are neither Saudi/Egyptian mobile nor written with "+"; references shorter than 6 characters.
8. **The sender**: the app sends `sender`; the Shortcut sends `sender`, `senderName`, `senderId` as it received them. If a message came from a personal number, that number is uploaded. The sender is not put in the model prompt by `process-ios-sms` or `parse-sms`.

The user's own data that is now masked more often: an account suffix with no possessive and no source wording in a transfer ("Acc:3583*", «حساب:5438*», "to account *5678" without a credit verb). The server then has no `last4` for that capture.

## Compatibility with build 147 (`b6fc0dad`)

- **Build 147 app with the new server**: no contract change. The server re-applies the new redaction to whatever the old app sends, so names, suffixes and codes are masked at intake. One-time-code messages with an amount are rejected before the AI.
- **New app with the deployed `b6fc0dad` server**: no contract change, but one behaviour to know. That server treats the text `[OTP]` as an OTP notice. One-time-code messages it used to record as purchases (11 of the probe texts) are now rejected, which is right. Completed purchases that also carry a masked "code NNNN" (a promo or pickup code after the purchase sentence; 10 probe texts) are rejected by that server too. The `HEAD` and working-tree servers do not have this effect. Deploy the server before the app build ships.

## XCTest

iPhone 17 simulator (iOS 26.5), after `flutter build ios --config-only`, from `app/ios`:
`xcodebuild test -workspace Runner.xcworkspace -scheme Runner -destination "platform=iOS Simulator,id=<sim>" -derivedDataPath <scratch>/dd -parallel-testing-enabled NO -only-testing:RunnerTests/SmsRedactionParityTests -only-testing:RunnerTests/RunnerTests/testShortcutUploadBodySendsTextLengthMeasuredBeforeRedaction`

**7 executed, 0 failures** (`** TEST SUCCEEDED **`):
- `testShortcutSanitizerMatchesSharedRedactionFixture` (54 rows)
- `testShortcutSanitizerRemovesEveryTaggedLeak` (204 rows)
- `testShortcutSanitizerMatchesGeneratedParitySet` (290 rows, new)
- `testShortcutUploadBodyCarriesNoTaggedThirdPartyToken` (new)
- `testShortcutRemovesOneTimeCodesAndKeepsAmountsAndOrdinaryWords` (new)
- `testShortcutKeepsMerchantInPurchaseAndMasksPersonInTransfer`
- `testShortcutUploadBodySendsTextLengthMeasuredBeforeRedaction`

The rest of `RunnerTests` (about 200 tests) was not run. Scratch DerivedData is removed. `app/build/ios` (1.2 MB of fingerprints from the config step) is left in place because other implementers may be building.

## Not verified

- The full `RunnerTests` suite and the full Flutter suite.
- The literal bytes of the Shortcut request (no capture seam in the gated transport).
- Real-model behaviour on the redacted text; sample B was not opened.
- The harness numbers will move again as the parser work continues; the attribution above was taken on the tree as it stood when I ran it.

---

# Closing items (after the first report)

Where this section and the text above disagree, this section is current. In particular: the shared-learning leak is closed, the Shortcut body is now the captured request, the labelled set has 211 rows, and a masked promo or pickup code is written `[REF]`, not `[OTP]`.

## 1. A person's name is never sent as a merchant

Three request bodies carried a merchant text built by the app. All three could carry a person's name when a row was typed as a payment and the message had no transfer word ("paid to Nadir Zaki", "Payment … to Nadir Zaki via Mada", "Bill payment … to account of Nadir Zaki", «سداد … إلى حساب نادر زكي»):

| Request | Field | Before | Now |
|---|---|---|---|
| `merchant-category-contribution` | `merchant_key` | `NADIR ZAKI` sent for an opted-in user | not built |
| `enrich-merchant` (goes on to Google Places) | `merchant_name` | `NADIR ZAKI` sent | no request |
| `merchant-feedback` | `keywords[]` | `NADIR ZAKI` queued, then sent | not queued |

The fix is one guard, `SmsSanitizer.masksPartOf(message, merchant)`: true when redaction removes any word of the merchant from the message.
- `app/lib/domain/services/shared_category_learning.dart`, `sharedContributionFor`: returns null.
- `app/lib/domain/usecases/add_transaction_usecase.dart`: the enrichment and feedback block is skipped. **This file was not in my brief.** Enrichment and feedback are built at one place, in that file, so the check you asked for could only be closed there. It is one condition; revert it if the file belongs to someone else's change.

Tests:
- `app/test/engine/privacy/outbound_payload_test.dart`: the skipped expectation is now a real assertion (0 leaks), plus a direct `masksPartOf` test on every pair row.
- `app/test/domain/merchant_feedback_privacy_test.dart` (new group): for each person/merchant pair of the labelled set, the person row sends nothing to enrichment or feedback and the merchant twin still goes out. Before the guard it failed with `enrich-merchant:NADIR ZAKI, merchant-feedback:NADIR ZAKI` on 6 rows, English and Arabic.

Over-blocking to know about: a merchant that redaction masks ("Payment of SAR 230 to STC", no business word, no purchase word) is also no longer enriched or shared.

Still open, not fixed: `SharedCategoryLearningClient.withdraw(rawMerchant)` sends `merchant_key` when the user deletes a learned rule. It has no message to test against, so a rule the user saved for a person's name would send that name once, on deletion, for an opted-in user. Closing it needs a local record of which keys were actually contributed.

## 2. The actual Shortcut request

Seam: `SharedCaptureStore.uploadProtocolClasses` (`#if DEBUG` variable, a `nil` constant in release), read once in `gatedUpload` to set `protocolClasses` on its own ephemeral session. Both physical copies of `SharedCaptureStore.swift` carry it and are byte-identical. No release behaviour changes.

`testShortcutActualRequestBodyCarriesNoTaggedThirdPartyToken` runs `BackendCaptureClient.process` unchanged, through the real admission and `gatedUpload`, for all 211 labelled rows with a capturing URL protocol. For each request it checks that `smsText` and `sanitizedText` equal the server's expected text, that `textLength` is the raw length, and that no tagged name, number or code is in any string field or in the raw request bytes. The rebuilt-body test and the source pins stay.

## 3. Full `RunnerTests`

`xcodebuild test … -parallel-testing-enabled NO -only-testing:RunnerTests`, iPhone 17 simulator, iOS 26.5, after `flutter build ios --config-only`; 16 GB free before the run.

**204 executed, 0 failures** (`** TEST SUCCEEDED **`): 198 in `RunnerTests`, 6 in `SmsRedactionParityTests`. That is the earlier 200 plus 4 new. Scratch DerivedData and `app/build/ios` are removed.

## 4. One-time codes and the deployed server

Decision: the digits are always masked; the placeholder depends on the wording.
- Verification wording (OTP, one-time …, verification / security / … code, passcode, password, رمز التحقق, كلمة المرور, الرمز السري …) or a following "do not share": `[OTP]`, wherever it sits.
- A bare cue ("code", «رمز», «الرمز», «كود», "Use / Enter N"): `[OTP]`, unless an earlier sentence of the message already states an amount. Then it is a promo, pickup or receipt code after a movement and is written `[REF]`, the existing reference placeholder that every server version already knows.

Masking only verification cues was the alternative. I did not take it, because "Your code is 482913" is a real one-time code under a bare cue.

| Message | Sent text | New app × `b6fc0dad` server | New app × new server |
|---|---|---|---|
| "Your verification code is 482913. Do not share it." | `… is [OTP]. …` | rejected, as before | rejected, as before |
| "Your code is 482913 for purchase SAR 250.00 at SHOPX" | `Your code is [OTP] …` | **now rejected** (it was recorded as a SAR 250 purchase) | rejected, and no longer sent to the AI |
| "You are paying SAR 250.00 at X. Your verification code is 771204" | `… code is [OTP]` | rejected | rejected |
| "Purchase SAR 250.00 at SHOPX. Use code 4829 to pay less on your next order" | `… Use code [REF] …` | recorded SAR 250, as before | recorded SAR 250, as before |
| "Purchase of SAR 100.00 at SHOPX. Order 482913 is your code for pickup" | `… Order [REF] is your code …` | recorded, as before | recorded, as before |
| «شراء 250 ريال لدى SHOPX. الرمز 4829 للاستفسار» | `… الرمز [REF] …` | recorded, as before | recorded, as before |
| "Purchase … at SHOPX. Approval code 482913" | unchanged (not a one-time code) | recorded, as before | recorded, as before |

Measured over the 4,328 harness cases:
- New app text against the `b6fc0dad` server: 11 messages change between processed and rejected. All 11 are one-time-code messages (truth: not a movement) that server used to record as purchases. No completed purchase is lost; the 10 that were lost with the first version of this change are back.
- New app text against the working-tree server (same parser, old redaction against new): no message changes between processed and rejected, 27 texts change reason or stop going to the AI, as listed above.

So the deploy order no longer matters for this change.

Known limit: a real one-time code under a bare cue, in a second sentence after an amount and with no "do not share", is masked as `[REF]`. The code still does not leave the device; the server then treats the message as it always did.

## Runs after the closing items

- Deno `deno test --allow-all`: 1,623 passed, 0 failed, 6 ignored. `deno lint _shared/`: clean. `deno.lock` unchanged.
- `flutter analyze`, whole app: **No issues found.**
- Flutter `test/engine/privacy test/engine/sms_sanitizer_test.dart test/domain/merchant_feedback_privacy_test.dart`: 369 passed, 0 skipped.
- Flutter `test/architecture`: 1 failure, `head_completeness_test` — the committed diff test imports `fixtures/sms_redaction_5dae2e2d.ts`, which is new and not yet tracked. It passes once the file is committed with the rest; I may not `git add`.
- Parity: Dart equals the server on 2,873 corpus texts; standalone Swift equals it on those plus the three fixtures (3,428 rows).
- Flutter `test/features/capture test/domain test/data/catalog test/engine/ai test/engine/ai_cascade_test.dart` (after the change in `add_transaction_usecase.dart`): 2,642 passed, 0 failed.
- The seven rows of the table in item 4 were run one by one against both servers; the outcomes in the table are the measured ones.
