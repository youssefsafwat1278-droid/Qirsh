# Round 5 — redaction under the owner's transfer rule (implementer `privacy`)

Working tree on `release-readiness/v1` at `2f9931cb`; nothing committed, pushed or deployed. Synthetic data only; no model call. `tools/message_eval/heldout/` and `sample_b.jsonl` were not opened.
Model: Claude Opus 5.5 (`claude-opus-5-5`).

I took over the interrupted round-5 partial edits (backup: scratchpad `round5-partial-fable.patch`). They were coherent (TypeScript, Dart and Swift agreed) and already carried the compound-name, status-word, date-word, one-time-code and phone fixes. I kept them and changed what conflicted with the owner's decision.

## The rule, in plain words

1. **Transfer or remittance** (the text says transfer, remit, beneficiary, sent, payable to, request from, standing order, instapay/IPN, «حوالة», «تحويل», «حول», «مستفيد», «المرسل», «لصالح», «وصلك», «أرسل», «طلب دفع» …, or a credit word such as "credited from" / «إيداع» with no purchase word): every counterparty after a cue is masked whole, up to the next amount, date, status or date word, account/reference cue or sentence end. No name lists, no business-word exception. A purchase or refund word in the same text does not change this (privacy wins where the reading is mixed). Account, IBAN and card numbers that the text does not mark as the user's own are masked.
2. **Purchase, POS, online payment, refund, bill**, or a card payment (the user's own card, no transfer word): the merchant is kept, so a saved category rule still matches.
3. **Payment wording with neither** ("Payment of SAR 85 to …", "paid to …", «دفع … إلى …», no purchase, POS, online, refund, bill or own-card cue and no transfer word): the type is unclear, so **privacy wins**. The payee is masked unless it carries a **business-form word** (Bookstore, Trading, Takaful, «شركة», «أسواق» …). A one-word brand is masked too in this exact wording: "Payment of SAR 85.00 to Careem" → `to [NAME]`. The same brand survives in purchase, POS, online or card-payment wording ("Payment of SAR 85.00 to Careem with card *4521", "POS purchase SAR 85.00 at Kudu").
4. Person cues (beneficiary, sender, payee, «المستفيد», «للسيد», Name:, Cardholder, account of …) mask in every message.
5. Never removed: amounts, currencies, dates, times, date words ("yesterday", «أمس»), status words («بانتظار التأكيد», pending, declined, could not be completed …).
6. One-time codes of 4–8 digits (also "482-913", "4 8 2 9 1 3") are masked after OTP, PIN, TAC, mToken, token, verification/security/… code, "your authorization code", password/passcode, «كلمة المرور (المؤقتة)», «الرقم السري (المؤقت / لمرة واحدة)», «الرمز (المؤقت / التالي)», «رمز التحقق» …, before or after "do not share" / "never share", after Use/Enter, and alone on a line followed by "Use this …".

The rule is stated once in code: `supabase/functions/_shared/sms_redaction.ts`, "Person or merchant: THE DECISION RULE"; the Dart and Swift copies point to it.

**Owner follow-up decision (item 3).** The first version of this round kept a one-word capitalised Latin payee ("Careem") after payment wording, so "Payment of SAR 50.00 to Ahmed" was sent (a regression against `HEAD`). On the owner's decision that exception is removed in all three implementations: both are masked now. Known survivor: a payee with a business-form word in the same wording ("Paid SAR 50.00 to Ahmed Trading") is still sent.

## What I deleted or changed

- «العزيز» and «الكريم» removed from the not-a-name list in all three implementations (`LOOSE_STOPWORDS`, Dart `_looseStopwords`, Swift `looseStopwords`). «عميلنا العزيز/» is still handled as a salutation.
- The "a purchase word makes it a purchase" exception inside transfers: `PURCHASE_CONTEXT` is now false whenever `STRONG_TRANSFER_WORDS` matches. The cue test's matching exception (`PURCHASE_READING` in `sms_redaction_cue_test.ts`) is deleted, so every cue after a name in a transfer must now mask the name.
- Item 3: no exception other than a business-form word after unclear payment wording. A one-word-brand exception from earlier in this round was removed again on the owner's follow-up decision.
- `looksLikeBusiness` (`shared_category_learning.dart`, used by `withdraw`) now requires a business-form word (`SmsSanitizer.hasBusinessWord`). It no longer probes "paid to X".
- Added: `takaful` as a business-form word; a destination after a debit verb is a third party ("debited from your account *3311 and credited to account *7788" → `*7788` masked); `payable to` and `request from` count as transfer words; the code-on-its-own-line rule.

## Acceptance set

`tools/acceptance/privacy_cases.jsonl`, frozen at **490 cases**: 72 from review V (originals table, R4P-01…08), 14 from review W (AR-01, AR-02, AR-07 and the status-word texts of AR-03…06), 9 from `round4-privacy.md`, 27 owner-decision cases, and 368 from the existing fixtures (`sms_leak_labelled_cases.json` 314, `sms_redaction_cases.json` 54). The owner-decision cases are: 6 person/merchant pairs, with the merchant side in purchase wording; lower case; a transfer with a refund word; IBAN; employer; one-word unclear payees; and the R4P-03 brands in real purchase, POS, online and card wording. In total 840 `must_not` substrings, 1,113 `must_keep` substrings, 51 rows with a merchant that must survive, 12 rows in explicit pairs. The six R4P-03 texts with unclear payment wording ("Payment … to Careem", "… to STC from your account *3311", "paid … to Kudu using mada", "Paid … to Panda", "paid to Kudu", "Apple Pay: … paid to Careem") moved from "must survive" to "must not appear". "Paid SAR 50.00 to Ahmed Trading" is in the set as a known survivor. The server output for each case is in `tools/acceptance/privacy_acceptance_expected.json`; the device and the Shortcut must reproduce it byte for byte.

| Implementation | Cases | Forbidden substrings sent | Required substrings lost | Equal to the server text |
|---|---|---|---|---|
| TypeScript (server, Deno) | 490 | 0 | 0 | (reference) |
| Dart (device, `sanitize` and `sanitizeWithMap`) | 490 | 0 | 0 | 490 / 490 |
| Swift (`BackendCaptureClient.sanitize`, compiled standalone from the source file) | 490 | 0 | 0 | 490 / 490 |

Swift also equals the server on the other fixtures: parity set 400, labelled set 314, redaction cases 54 (1,258 rows in total, 0 differences). The run used the final source.

Outbound payloads with synthetic data, over all 490 cases:
- Server (`sms_outbound_payload_test.ts`): a client that redacted nothing uploads the raw text; no `must_not` substring in the model request, the stored row, the response or any log line, in `ai_primary` and legacy modes. For the 51 merchant rows the server's `merchantRuleKey` is the same from raw and redacted text. No person name becomes a merchant or merchant key.
- App (`outbound_payload_test.dart`): the `process-ios-sms` upload body, the `parse-sms` body, bank-discovery, shared learning, enrichment and feedback; a saved rule still matches for every merchant row the device parser reads; no person name is a merchant of the redacted text.
- Dart `privacy_acceptance_test.dart`: `masksPartOf` is false for all 51 merchants (so shared learning and enrichment still see them) and true for every person row in a pair.

## Findings

| Finding | Status |
|---|---|
| R4P-01 compound names cut | Closed. Particle rule («عبد», «أبو», «بن», «آل» …) plus the two list entries removed. All 6 texts and 40+ fixture variants masked whole. |
| R4P-02 business word in a transfer | Closed. No business-word exception in a transfer (4 texts). |
| R4P-03 merchants masked in payment wording | Resolved by the owner's decision: in unclear payment wording the payee is masked unless it carries a business word ("Al Rajhi Takaful" survives; Careem, STC, Kudu, Panda are masked there). In purchase, POS, online and card-payment wording they survive (4 cases). The device still reads the raw message, so a saved rule matches there; a merchant that comes only from the server or the model is lost for these 6 shapes. |
| R4P-04 «اسم» label, English stop words | Closed (5 texts). «اسم» is a label only before a colon; the loose stop words apply only after a field label or with no cue. |
| R4P-05 middle initial without a dot | Closed (3 texts). |
| R4P-06 one-time codes under other wording | Closed for all 15 listed wordings. |
| R4P-07 more cues, phones, third-party suffix | Closed for all listed texts, including "+965 5123 4567". Not closed: a bare 8-digit Gulf mobile with no "+" (see below). |
| R4P-08 lower-case name; `withdraw`; copy | Lower-case name closed. `withdraw` closed: the key is sent only if this account offered it in this app session, or if it carries a business-form word (a person's one-word name too: test added). Copy ("never sent") not changed: l10n is not mine, and it is still not exact (see below). |
| R4P-09 outbound fields not asserted | Partly. The payload tests now run the whole acceptance set. `sender` / `senderName` / `senderId`, cloud sync of the user's own records, Sentry and telemetry are unchanged and not covered. |
| R4P-10 wording | Open (legal and l10n texts are not mine). |
| AR-01 | Closed (holder name and suffix; lower-case payee). |
| AR-02 | Closed (status words kept; checked against every cue in `parser_rules.json`). |
| AR-07 | Closed ("yesterday", «أمس» and the other date words of the cue test, 18 in all, kept). |

## Still survives (third-party data that can still be sent)

1. **A name with a business-form word after payment wording** with no transfer word ("Paid SAR 50.00 to Ahmed Trading"). If the user confirms a category for such a row, shared learning and enrichment treat it as a merchant.
2. **A name in a purchase, refund or bill text with no person cue** ("Purchase SAR 50.00 at Nadir Zaki", "Refund SAR 50 from Nadir Zaki"): read as a merchant.
3. **The 7th and later words of a counterparty**: a transfer counterparty is masked up to 6 words ("… to [NAME] Khalid" for a 7-word name).
4. **Names with no cue** outside the covered shapes (sentence start before "sent you", after a transfer word, «أرسل لك», «قام … بتحويل»).
5. **A third party's suffix of 4 digits or fewer** where the text words it as the user's own would be (round-4 list item 4), except the debit/credit case fixed here.
6. **Phones**: a bare 8-digit Gulf mobile with no "+" ("Call 66123456"); numbers in other unrecognised forms.
7. **Codes**: no cue at all; 9 or more digits; codes with letters; approval, reference, receipt and promo codes (kept on purpose, or written `[REF]`).
8. **Outside redaction**: `sender` / `senderName` / `senderId` (a personal number is uploaded); counterparty names in the user's own synced records (`user_transactions.merchant`, `description`, `user_merchant_rules.merchant_key`).

Until the routing from item 1 of the decision lands (another agent), transfer messages still reach the model, with the counterparty masked as above.

## Commands and results

- `cd supabase/functions && deno test --allow-all _shared` → **696 passed, 0 failed, 2 ignored** (includes `privacy_acceptance_test.ts`, `sms_outbound_payload_test.ts`, `sms_redaction_cue_test.ts`, `sms_redaction_parity_test.ts`, `sms_redaction_head_diff_test.ts`, `sms_redaction_test.ts`). `deno lint` on the changed files: clean. The server outbound test's floor on model calls was lowered from half to a quarter of the cases: the parser work now keeps more texts away from the model (217 of the first 484 cases reached it). The leak assertion is unchanged.
- `cd app && PUB_CACHE=$HOME/.pub-cache flutter analyze` → **No issues found.**
- `flutter test --no-pub -j 2 test/engine/privacy test/engine/sms_sanitizer_test.dart test/domain/merchant_feedback_privacy_test.dart test/data/catalog test/engine/proof` → **722 passed, 0 failed** (after the follow-up decision). The proof tests are the only other engine and domain tests that use the sanitizer.
- `flutter test --no-pub -j 2 test/engine test/domain` → 4,997 passed, **541 failed**, run during the parser agent's in-flight edits (`parser_engine.dart`, `ai_candidate_validator.dart`, the untracked `completion_certainty.dart`). None of the failing files uses the sanitizer: all the sanitizer-dependent files are in the two green runs above. I checked samples: `ai_candidate_validator_test` "a sanitizer placeholder is never a grounded merchant" fails on `accepted` (the new `CompletionCertainty` gate), not on redaction; `declined_cases_totals_test` is parser. Re-run this suite once the parser work settles.
- Swift: `tools/message_eval/real_model/swift_sanitize.sh` (extracts `BackendCaptureClient.sanitize` verbatim and compiles it with `swiftc`) on 1,252 texts → 0 differences from the server.
- Other related Flutter suites (`test/features/capture/{android_sms_permission,capture_sync_service,capture_import_service}_test.dart`, `test/adversarial/privacy_attack_test.dart`, `test/architecture`, `test/ios`, `test/data/catalog`): 761 passed, 4 failed, none from redaction. `capture_sync_service_test` "internal transfer between own accounts" (the text «تحويل داخلي EGP 42 بين حساباتك» is redacted identically at `HEAD`; the parser work is in flight); `head_completeness_test` (`process-ios-sms/parse.ts` and `meaning_gate.ts` import the untracked `completion_certainty.ts`, parser work); `destructive_path_inventory_test` (restore work); `report_ads_guards_test` (passed on re-run).

## Files changed (mine)

- `supabase/functions/_shared/sms_redaction.ts`
- `app/lib/engine/privacy/sms_sanitizer.dart`, `app/lib/engine/privacy/sanitization_edit_map.dart`
- `app/ios/BankMessageShortcuts/BankMessageShortcuts.swift` (`BackendCaptureClient.sanitize` and its word lists only)
- `app/lib/domain/services/shared_category_learning.dart` (`looksLikeBusiness`), `app/lib/data/catalog/shared_category_learning_client.dart` (`withdraw` guard, from the partial)
- Fixtures: `sms_leak_labelled_cases.json`, `sms_redaction_cases.json`, `sms_redaction_parity_cases.json`
- Tests: `_shared/privacy_acceptance_test.ts` (new), `_shared/sms_outbound_payload_test.ts`, `_shared/sms_redaction_cue_test.ts` (new in the partial), `_shared/sms_redaction_parity_test.ts`, `app/test/engine/privacy/privacy_acceptance_test.dart` (new), `app/test/engine/privacy/outbound_payload_test.dart`, `app/test/data/catalog/shared_category_learning_client_test.dart`
- New: `tools/acceptance/privacy_cases.jsonl`, `tools/acceptance/privacy_acceptance_expected.json`

No patch outside my paths was needed. Suggested for the l10n owner: `privSharedLearningBody` and `smartConsentShared` should not say names of people are "never" sent (still-survives items 1–2).

## Not verified

- XCTest (`RunnerTests`, `SmsRedactionParityTests`) was not run: it needs `flutter build ios --config-only` and a simulator build, and the disk has about 16 GB free. The Swift function was compiled standalone from the source file instead. The RunnerTests read the same three fixtures, and the Swift output equals them. Run it in the gate.
- Real-model behaviour; the routing that keeps transfers away from the model.
- The full Flutter suite.

## Follow-up to review X of e5881120 (X-P1, X-P2, X-P3, S3)

Same three twins, byte-identical. No commit.

- **X-P1 (own card no longer keeps "paid to X").** `isMerchantContext` is now the purchase reading alone; the branch "own card suffix and no transfer word" is removed. In "paid to X", "payment to X" and «دفع … إلى X», X is kept only with a business word or in purchase wording ("purchase at", "POS", «شراء», and «عملية انترنت»: «انترنت|إنترنت» added to the purchase words because STC's online-purchase format has no other purchase word and lost its merchant otherwise). "SAR 75.00 paid to Ahmed Saleh using your card *4521", "Card *4521: SAR 85.00 paid to Omar Farooq", "Apple Pay: … paid to Omar Farooq using card *4521" and «دفع 85 ريال إلى عمر فاروق ببطاقة مدى 4521» are masked.
- **X-P2 (money requests).** "money request", "request to pay" and "requested" join the transfer words and the strong transfer words, so the counterparty after "from" is masked unconditionally. The name-before-verb cue takes "requested … from you" ("Fatima Zahra requested SAR 150 from you" → "[NAME] requested …").
- **X-P3 (beneficiary notices).** The person cue takes "beneficiary added", «مستفيد جديد» and «المستفيد الجديد» (before, «جديد» stopped the name and "added" left the colon unmatched).
- **S3 (own suffix after "to account").** One rule: the credit-verb window now crosses a period followed by "to"/"into" ("credited from ACME Trading Co. to account *5678" keeps `*5678`).

Fixtures: two labelled rows that relied on the own-card rule moved to purchase wording (`r4_pair_card_paid_to_merchant`: "Card *4521: SAR 85.00 purchase at Example Diner"; `r5_decision_payment_card`: "Purchase of SAR 85.00 at Careem with card *4521"). Acceptance set: 490 → **504 rows** (14 `x_*` rows from the review texts; `own_r4p03_careem_card` is now must-not "Careem"); 53 merchant rows. Regenerated once and frozen: `privacy_acceptance_expected.json`, labelled `expected`; `sms_redaction_parity_cases.json` was unchanged by regeneration. Dart test "payment wording masks the payee; purchase wording keeps its rule" now checks the carded payment is masked and the purchase text keeps Careem and its rule.

**Survivors after this follow-up (honest list):**
- "Payment of SAR 85.00 to Careem with card *4521" is now **masked** (Careem is a one-word brand with no business word). "Purchase of SAR 85.00 at Careem with card *4521" survives.
- "Paid SAR 50.00 to Ahmed Trading" and "Card *4521: SAR 85.00 paid to Jarir Bookstore" survive (business word; item 1 above).
- A person in purchase wording survives (item 2 above), now including «عملية انترنت … إلى عمر فاروق».
- Over-masking, not a leak: in «… إلى عمر فاروق ببطاقة مدى 4521» the name span runs over «ببطاقة» and the own suffix becomes `[ACCOUNT]` (same as the transfer twin «تحويل … ببطاقة مدى 4521» at e5881120). In the S3 text "ACME Trading Co." is masked (credit wording is the transfer class); only the suffix was fixed.

Results:
- Deno `_shared` (`--no-check`; type check fails only in `process-ios-sms/parse.ts`, parser agent's in-flight file): **696 passed, 0 failed, 2 ignored**.
- `flutter analyze lib/engine/privacy test/engine/privacy`: no issues. `flutter test test/engine/privacy test/data/catalog/shared_category_learning_client_test.dart`: **483 passed**. `test/engine/sms_sanitizer_test.dart test/engine/proof test/features/capture/{android_sms_permission,capture_sync_service}_test.dart`: **306 passed**.
- Swift standalone (`swift_sanitize.sh`, `BackendCaptureClient.sanitize` compiled alone): **1,272 texts, 0 differences** from the server (504 acceptance, 400 parity, 314 labelled, 54 redaction cases). XCTest not run (disk).

## Follow-up to re-review Y of c9dc4ca4 (N-P1)

Worktree `v1-fix`; the three twins stay byte-identical. No commit.

- **Money requests, the wording family.** The single phrases "money request" / "request to pay" became `(payment|money|pay|transfer|fund)(s) request(s)`, `request(s) to pay`, `request(s) for payment|money` (plus "requested", already in); «طلب دفع» became «طلب (دفع|تحويل|مبلغ|أموال)». They are transfer words and strong transfer words, so the counterparty after "from" / «من» is masked unconditionally; a name before "sent you a payment request" or "requested … from you" was already masked.
- **Beneficiary notices, the wording family.** The two one-off extensions of the person cue ("beneficiary added", «مستفيد جديد») are replaced by one pattern: a beneficiary or payee cue (beneficiary, payee, «المستفيد», «مستفيد», «للمستفيد»), then any run of status words (new, added, successfully, has, been, was, «جديد», «الجديد», «بنجاح»), then a colon, comma, dash or space, then the name. A second pattern takes the name before the role: "X was / has been added as a (new) beneficiary", "added X as a beneficiary", «إضافة X كمستفيد», «إضافة X إلى قائمة المستفيدين». "added" and «كمستفيد» are now name stop words, so "Beneficiary Rami Fawzi added successfully" keeps "added successfully". The status words stay; for example, the X-P3 row now reads "Beneficiary added: [NAME], …" instead of "Beneficiary [NAME]: [NAME], …".
- **Acceptance set.** 504 → **522 rows**. There are 18 `y_np1_*` rows:
  - the 3 review texts;
  - 13 siblings, 6 of them Arabic;
  - 2 keep rows: "Your beneficiary is now active" is unchanged, and the Jarir Bookstore purchase keeps its merchant and date.
  
  Regenerated once: `privacy_acceptance_expected.json` has the 18 new rows, and one existing row changed (`x_p3_beneficiary_added`, which no longer loses "added"). Regenerating the labelled and parity fixtures changed nothing.
- **Over-masking noted:** in «تم إضافة رامي فوزي إلى قائمة المستفيدين» the existing «إلى» rule also masks «قائمة المستفيدين» (`إلى: [REDACTED]`).
- **Pre-existing, unchanged:** "request from X" was already a transfer word, so "Your order request from Amazon" masks Amazon.

Results:
- Deno `_shared` (`--no-check`; the parser agent's `process-ios-sms` files are in flight): **696 passed, 0 failed, 2 ignored**. `deno check` and `deno lint` on `sms_redaction.ts`: clean.
- `flutter analyze lib/engine/privacy test/engine/privacy`: no issues. Whole-app `flutter analyze` shows 9 errors, all in `lib/core/i18n/country_catalog.dart`: the gitignored generated `countries.g.dart` is absent in this fresh worktree (build_runner not run). They are not from this change.
- `flutter test -j 1 test/engine/privacy test/engine/sms_sanitizer_test.dart test/engine/proof test/data/catalog/shared_category_learning_client_test.dart`: **706 passed**. This covers the Dart privacy acceptance test, the edit-map and outbound-payload tests.
- Swift standalone (`swift_sanitize.sh`, `BackendCaptureClient.sanitize` compiled alone): **1,290 texts, 0 differences** from the server (522 acceptance, 400 parity, 314 labelled, 54 redaction cases). XCTest not run (disk).

## Follow-up to narrow check Z of b2060a27 (N-P2)

Worktree `v1-fix`; the three twins stay byte-identical. No commit.

- **Rule.** When a text has no transfer word (those already mask every counterparty), no purchase reading and no merchant mark ("at <Capitalised>", "@", «لدى», «من متجر»), a counterparty after "from", "by" or «من» is masked unless it carries a business word (the existing `maskPayee` / COMPANY_MARKERS). The cue must follow an amount, or an incoming-money verb in the same sentence (within 60 characters):
  - English verbs: got, received, credited, deposited, added, topped up, sent you.
  - Arabic verbs: «قيد», «أودع», «أضيف», «وصلك», «استلمت», «حوّل».
  - This is one pattern (`INCOMING_FROM_PATTERN` / `_incomingFrom` / Swift inline) plus the `MERCHANT_MARK` gate. It is not a pattern per sentence.
- A leading name before "sent you" was already masked. «وصلك» and «استلمت» texts were already masked (transfer words); they are now in the set.
- **"Payee Coffee".** This is a one-line guard in each twin, applied to both the person cue and the beneficiary-notice pattern: a cue word right after "at" is not a cue (`(?<!at[ \t]{1,3})`, bounded for ICU). "Purchase SAR 60.00 at Payee Coffee card *4521" now keeps the merchant and `*4521`.
- **Acceptance set.** 522 → **540 rows**, with 18 `z_np2_*` rows:
  - the 6 review texts;
  - 6 siblings, 2 of them Arabic;
  - 6 rows that must survive: "from Test Corp Payroll", «من شركة الاختبار», "Purchase from AMAZON", "Refund … from Noon", «شراء من كارفور», "at Payee Coffee".
- **Regeneration.** `privacy_acceptance_expected.json` gained the 18 rows; **no existing row's expected output changed**. Regenerating the labelled and parity fixtures changed nothing.
- **Business senders.** In credit or transfer wording ("Salary … credited from Test Corp Payroll"), a business sender was already masked under the transfer rule, and that is unchanged. It survives only in the new non-transfer class.
- **"… from Test Pay".** In "You got SAR 50.00 cashback from Test Pay", "Test" is masked and "Pay" stays because "Pay" is a stop word. "Payment of SAR 85 from Careem" now masks Careem; this follows the unclear-wording rule.

Results:
- Deno `_shared` (`--no-check`; the money agent's `process-ios-sms` files are in flight): **696 passed, 0 failed, 2 ignored**. `deno check` and `deno lint` on `sms_redaction.ts`: clean.
- `flutter analyze` (whole app): **No issues found**.
- `flutter test -j 1 test/engine/privacy test/engine/sms_sanitizer_test.dart test/engine/proof test/data/catalog/shared_category_learning_client_test.dart`: **706 passed**. This covers the Dart privacy acceptance, edit-map and outbound-payload tests.
- Swift standalone (`swift_sanitize.sh`, `BackendCaptureClient.sanitize` compiled alone): **1,308 texts, 0 differences** from the server (540 acceptance, 400 parity, 314 labelled, 54 redaction cases). XCTest not run (disk).
