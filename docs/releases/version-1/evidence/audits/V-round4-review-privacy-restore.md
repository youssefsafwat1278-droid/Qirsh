# Round 4 review: redaction before transmission, and merge restore of category rules

Reviewer `r4-review-privacy-restore`, model `claude-fable-5-2` (Claude Fable 5.2). Fresh reviewer; wrote none of the code. Scope: `a157e68e..a86298fc` on `release-readiness/v1`. Repository read-only; synthetic data only; no production access, no model or API call.

## Verdicts

| Part | Verdict | Reason |
|---|---|---|
| A. Redaction before transmission | **REJECT** | Every original reproduction is closed, and device == server == Swift. But the change itself makes two common Arabic names leak that were masked at `a157e68e` (R4P-01, S2), and stops masking a person behind a business word in a transfer (R4P-02, S3). The owner accepts no exception. |
| B. Merge restore of category rules | **ACCEPT WITH FOLLOW-UP** | The merge rule, the ambiguity path, repeated restore and restore-then-sync hold in their tests, on my stack and in my own tests. Three follow-ups: a failed pull lets the restore push a rule over another device's removal (R4R-01), "Leave out" is undone by the cloud (R4R-02), "Leave all out" has no confirmation (R4R-03). |

## Part A: redaction

### What I ran

- **Three implementations, two commits.** TypeScript through Deno (`redactThirdPartyNames(redactPii(text)).trim()`), Dart (`SmsSanitizer.sanitize`), and Swift (`BackendCaptureClient.sanitize` compiled standalone with the repository's own `tools/message_eval/real_model/swift_sanitize.sh`). The `a157e68e` sources came from a `git archive` export in scratch.
- **Original reproductions, 31 texts:** PRIV-1r, SP-16, MASK-1, MASK-0, the two one-time codes and "confirm" from the real-model run, and four older PRIV-1 shapes.
- **Fresh corpus, 211 texts** (158 carry a tagged secret), Arabic and English, in 13 classes. Plus 58 + 19 follow-up probes.
- **Implementer's suites:** Deno `sms_redaction_parity_test`, `sms_outbound_payload_test`, `sms_redaction_head_diff_test`: 12 passed. Flutter `test/engine/privacy test/engine/sms_sanitizer_test.dart test/domain/merchant_feedback_privacy_test.dart`: 369 passed.

### Original reproductions

All fixed at `a86298fc`, identically in TypeScript, Dart and Swift. All leaked or over-masked at `a157e68e` as the earlier reviewers reported.

| Original | At `a157e68e` | At `a86298fc` |
|---|---|---|
| "Attn", "Name:", "Customer" before a name (PRIV-1r) | name sent | `[NAME]` |
| «إلى حساب <name>» under the `payment` hint (PRIV-1r, Dart only) | name sent | masked; the hint is no longer used |
| "Payment of SAR 99 to Omar Farooq via Mada" (SP-16) | name sent | `[NAME]` |
| "Bill payment SAR 150 to account of Mohammed Abdullah" (SP-16) | name sent | `[NAME]` |
| "sent to account *9876 (Noura)" (SP-16) | suffix and name sent | `[ACCOUNT] ([NAME])` |
| "transferred to beneficiary account ****9876" (SP-16) | suffix sent | `[ACCOUNT]` |
| "Card *4521: SAR 85.00 paid to Jarir Bookstore" (MASK-1) | merchant masked | merchant kept |
| "Purchase To: Jarir Bookstore SAR 85.00 card *4521", «شراء 85 ريال إلى … بطاقة 4521» (MASK-0) | merchant and own suffix masked | both kept |
| "…code for the transfer is 999999. Do not share it." | code sent | `[OTP]` |
| "Use 999999 to confirm your SAR 500.00 transfer…" | code sent, "confirm" → `[NAME]` | `[OTP]`, "confirm" kept |

### Fresh corpus: what survives

Device == server == Swift on all 319 texts at `a86298fc` (0 mismatches). Redacting twice gives the same text on 300 of 300. Texts where at least one tagged token survives:

| Class | Texts | Leak at `a157e68e` | Leak at `a86298fc` |
|---|---|---|---|
| English name with a cue | 26 | 10 | 5 |
| English name, no cue | 14 | 14 | 9 |
| Name that is also a word | 8 | 3 | 3 |
| Person with a business word | 6 | 0 | **5** |
| Arabic name with a cue | 20 | 7 | 7 (two of them new) |
| Arabic name, no cue | 10 | 10 | 6 |
| Third-party suffix | 18 | 13 | 2 |
| IBAN | 9 | 0 | 0 |
| Phone, e-mail | 12 | 4 | 3 |
| One-time code | 35 | 29 | 11 |
| **Total** | **158** | **90** | **51** |

Over-masking (something that must stay is lost): 11 texts at `a157e68e`, 4 at `a86298fc`. No amount, date, time or status word was lost in any of the 211. Eight texts are worse than at `a157e68e`; they are R4P-01, R4P-02 and R4P-03 below.

### Findings

| ID | Sev | Class | Finding |
|---|---|---|---|
| R4P-01 | **S2** | REPRODUCED, **regression of this round** | **Names containing «العزيز» or «الكريم» are cut after the first word.** The round added both words to the name stop list (`sms_redaction.ts` `NAME_STOPWORDS`, and the Dart and Swift copies), meant for «عميلنا العزيز». «عبد العزيز» and «عبد الكريم» written with a space now end the name. Identical in all three implementations. No fixture row contains «عبد » with a space. |
| R4P-02 | S3 | REPRODUCED, **regression of this round** | **A person behind a business word is no longer masked in a transfer.** Listed by the implementer under "Still survives" (2), but not as a regression: all of these were masked at `a157e68e`. |
| R4P-03 | S3 | REPRODUCED, regression of this round; effect on a saved rule CODE-SUPPORTED | **Merchants masked as `[NAME]` in payment wording that was untouched before.** MASK-1 is fixed only when the text names the user's own card. |
| R4P-04 | S3 | REPRODUCED, regression of this round | **The new «اسم» label rule masks the label's next word**, and the new English stop words cut names. |
| R4P-05 | S3 | REPRODUCED, pre-existing | **A middle initial without a dot ends the name.** Not in the "Still survives" list. |
| R4P-06 | S3 | REPRODUCED, pre-existing, narrowed | **One-time codes still sent under wording the claims do not list.** |
| R4P-07 | S3 | REPRODUCED, pre-existing | **Name cues and phone forms still missed**, beyond the "Still survives" list. |
| R4P-08 | S3 | REPRODUCED (key), CODE-SUPPORTED (withdraw) | **"A person's name is never sent as a merchant" is not true in two cases**, and the consent text says "never". |
| R4P-09 | S4 | CODE-SUPPORTED | **Outbound string fields the payload tests do not assert on.** |
| R4P-10 | S4 | CODE-SUPPORTED | **Wording.** Unchanged this round; two phrases are stronger than the facts. |

**R4P-01 reproduction** (same output from Deno, Dart and Swift):

| Text | `a157e68e` | `a86298fc` |
|---|---|---|
| «حوالة واردة 75 ريال من عبد العزيز القحطاني» | `من [NAME]` | `من [NAME] العزيز القحطاني` |
| «المستفيد: عبد الكريم القحطاني المبلغ 75.50 ريال» | `المستفيد: [NAME] المبلغ…` | `المستفيد: [NAME] الكريم القحطاني المبلغ…` |
| «المرسل: عبد العزيز محمد مبلغ 300 ريال» | `[NAME]` | `[NAME] العزيز محمد` |
| «تم تحويل 75 ريال لصالح عبد الكريم ناصر» | `[NAME]` | `[NAME] الكريم ناصر` |
| «المستفيد: كريم العزيز المبلغ 75 ريال» | `[NAME]` | `[NAME] العزيز` |
| «أرسل لك عبد العزيز محمد 40 ريال» | whole name sent | `[NAME] العزيز محمد` |

Not affected: «عبدالعزيز» written as one word, «عبد الرحمن», «عبد الله», and any name after «إلى» (that rule masks to the end of the run). Fix direction: do not treat «العزيز» / «الكريم» as a stop word after «عبد» or inside a name run; add fixture rows.

**R4P-02 reproduction:** "Transfer of SAR 100.00 to Ahmed Trading completed"; "SAR 900.00 transferred to Faisal Qahtani Est."; «تم تحويل 900 ريال إلى مؤسسة فيصل القحطاني»; «تم تحويل 900 ريال إلى محمد التاجر». Each was `[NAME]` / `[REDACTED]` at `a157e68e` and is sent whole at `a86298fc`. «مؤسسة <full name>» is the usual name of a sole proprietorship.

**R4P-03 reproduction:**

| Text | `a157e68e` | `a86298fc` |
|---|---|---|
| "Payment of SAR 85.00 to Careem" | kept | `to [NAME]` |
| "Payment of SAR 230.00 to STC from your account *3311" | kept | `to [NAME]` |
| "You paid SAR 85.00 to Kudu using mada" | kept | `to [NAME]` |
| "Paid SAR 85.00 to Panda" | kept | `to [NAME]` |
| "SAR 85.00 paid to Kudu"; "Apple Pay: SAR 85.00 paid to Careem" | `[NAME]` | `[NAME]` (MASK-1 not fixed without a card) |
| "SAR 85.00 paid to Al Rajhi Takaful via SADAD from your account *3311" | `[NAME]` | `[NAME]` |

Effect on a saved category rule:
- **Rule-based server key: no change.** 180 texts (12 merchants × 12 English payment shapes, 6 × 6 Arabic): `merchantRuleKey` of the server's rule parse is the same from raw, old-redacted and new-redacted text on all 180. No amount, type or outcome changed.
- **Model path: the merchant is gone.** The server's rule parser reads no merchant from these shapes (114 of 180 have no key from the raw text either), so the merchant can only come from the model, which now sees `[NAME]`. `withUserMerchantRule` then has nothing to match. Not measured: no model call was allowed.
- **Device:** the device parses the raw text, so its own rule lookup is unaffected; enrichment and shared learning are skipped for these merchants (the implementer says so).

**R4P-04 reproduction:** «اسم المستفيد: فيصل القحطاني المبلغ 120 ريال» → `اسم [NAME]: [NAME] …` (harmless); «اسم المستفيد عبد العزيز محمد المبلغ 120 ريال» → `اسم [NAME] [NAME] العزيز محمد` (leak, was fully masked); «اسم الجهة: شركة الكهرباء. سداد 120 ريال» → `اسم [NAME]: شركة الكهرباء` (a biller label lost). English: "SAR 100.00 received from Mark Order" → `[NAME] Order`; "received from Local Hero" → sent whole. Both were `[NAME]` at `a157e68e`.

**R4P-05 reproduction:** "Cardholder: NOURA A ALHARBI. Purchase…" → `[NAME] A ALHARBI`; "Transfer of SAR 45.00 to Noura A Alharbi completed" → `[NAME] A Alharbi`; "received from MOHAMMED A M ALQAHTANI" → `[NAME] A M ALQAHTANI`. The parity set only has an initial with a dot ("LAYLA H. MANSOUR").

**R4P-06 reproduction** (digits sent, all three implementations):
- "Your authorization code is 482913" ("authorization code" is excluded on purpose as an approval code; this wording is a verification code).
- "PIN: 482913 valid for 5 minutes"; "Your PIN is 482913"; "Your TAC is 482913 for transfer of SAR 250.00"; "mToken 482913".
- «كلمة المرور المؤقتة 4829 …»; «الرقم السري لمرة واحدة 482913»; «الرقم السري المؤقت 482913»; «الرمز المؤقت: 482913»; «لإتمام العملية أدخل الرمز التالي 482913». The claims list «الرقم السري» and «كلمة المرور» as cues; one word between the cue and the digits defeats them.
- "Your code is 482913 SAR 250.00 at EXTRA" (a code directly before a currency is read as an amount).
- "482913\nUse this to log in to Example Bank"; "Never share this: 482913."; "Code 482-913 to authorise SAR 250.00"; "Code 4 8 2 9 1 3".

**R4P-07 reproduction** (sent whole): "Recipient - Dana Yousef - SAR 61.00 sent"; "Request from Zainab Kareem: pay SAR 95.00"; "Salary transfer … for employee Majed Sultan credited"; "Cheque … payable to Walid Jaber"; "transferred to acct 7788 of Faisal Qahtani" (suffix masked, name sent); «حوالة صادرة 60 ريال للمستفيد رامي نصار»; «تحويل 60 ريال لـ رامي نصار»; «تم تحويل 60 ريال للسيد حاتم صبري»; «عميلنا العزيز/ سلمى راشد تم إيداع…»; «من: أبو بكر الصديق»; «وصلك 40 ريال من عبدالله»; «طلب دفع 95 ريال من زينب كريم». Phones: "055 123 4567", "055-123-4567", an 8-digit Gulf mobile. Third-party suffix: "debited from your account *3311 and credited to account *7788" (the implementer's item 4).

**R4P-08:**
- **Lower-case name passes the guard.** "Payment of SAR 85.00 to nadir zaki via Mada": redaction keeps the name, so `masksPartOf` is false, and `sharedContributionFor` returns `{merchant_key: NADIR ZAKI VIA MADA, category_key: shopping}`. Run with the production parser and builder. The guard can only catch what redaction catches.
- **`SharedCategoryLearningClient.withdraw`** (`learned_rules_usecase.dart:35` → `shared_category_learning_client.dart:78`) sends `merchant_key` when the user forgets a rule, with no person check. A rule saved for a person's name is sent once on deletion, for a signed-in, opted-in user. The implementer left this open; it is still open.
- **Copy:** `privSharedLearningBody` and `smartConsentShared` say "transfers and names of people are never sent". With the two cases above that is not exact.

**R4P-09:**
- `sender` / `senderName` / `senderId`: every payload test uses the constant "ExampleBank". A message from a personal number or a contact uploads that value (the implementer's item 8). The server uses a letters-only sender as the brand in the push title.
- `bank-discovery` (`bank_discovery_client.dart:50`): `sender_id` and `sanitized_sms`. Same sanitizer, but no payload test.
- Cloud sync of the user's own records: `user_transactions.merchant` and `description`, `user_merchant_rules.merchant_key`. A transfer's counterparty name travels there as the user's own data. Not in the "Still survives" list.
- The Dart upload test calls `CaptureBackendClient.processIosSms` with text it redacted itself and pins the caller's line as a source string; it does not run `capture_sync_service`.
- Not inspected by me: Sentry and telemetry payloads, push registration, the encrypted backup upload.

**R4P-10:**
- `docs/legal/PRIVACY_POLICY.md` §8: "the last digits of your own card or account". Closer to the code than before, but a third party's suffix still stays in the cases of the implementer's item 4.
- `smsDisclosureOnDevice`: "after card, account and phone numbers, IBANs and codes are removed" with no "it recognises". The other strings and §8 say "recognises / can miss some".
- §8's cue examples and "can miss some" remain literally true, including for R4P-01.

### Checked and found sound

- **DEBUG seam.** `SharedCaptureStore.uploadProtocolClasses` is a `var` only under `#if DEBUG` and a `nil` constant otherwise. `DEBUG` is set only in the Debug configurations of `project.pbxproj`; Release and Profile do not define it. The two copies of `SharedCaptureStore.swift` are byte-identical. `testShortcutActualRequestBodyCarriesNoTaggedThirdPartyToken` runs `BackendCaptureClient.process` and reads the captured request bytes (read, not run).
- **`[OTP]` or `[REF]`.** The digits are masked either way, on the device and again by the server (`reSanitize`). The model sees a placeholder that both server versions already name in the prompt. A real verification code written `[REF]` (bare cue after an amount, or "Do not share" on the next line: "Purchase SAR 250.00 at EXTRA.\nCode: 482913\nDo not share" → `Code: [REF]`) is not transmitted; the server then treats the message as it did before the change.
- **Server re-redaction.** The server applies the new rules to whatever arrives; redaction is idempotent on my 300 texts.

## Part B: merge restore of category rules

### What I ran

- `flutter test --no-pub -j 2 test/core/backup test/data/db/merchant_rule_history_v44_migration_test.dart test/data/merchant_rule_deleted_category_test.dart test/core/privacy/data_wipe_service_test.dart test/architecture/destructive_path_inventory_test.dart`: **+365, all passed**.
- Own local stack (project `r4_review_pr`, API 59321, DB 59322), all migrations applied. `test/integration_local/restore_then_sync_local_supabase_test.dart` with the dart-defines and the `LOCAL_SUPABASE_*` variables: **+13, all passed** (R1–R9b, RR1–RR3). Without the environment variables the file skips all 13. Stack stopped with `--no-backup`; no container, volume or network of mine remains; `frasaaaaa` and `qirsh_proof` untouched.
- Nine attack tests of my own over the real restore use case, rule repository, outbox and `MerchantRuleSyncService`, with an in-memory cloud that can fail a fetch.

### My attack tests

| # | Scenario | Result |
|---|---|---|
| A1 | Removal on another device not yet pulled; restore writes the rule; the next sync's pull fails once | **FAIL**: rule pushed back, live in the cloud (R4R-01) |
| A2 | Signed out at restore time; removal in the cloud; sign in, sync twice | Pass: rule removed on device, cloud stays removed |
| A3 | Rule forgotten while signed out, restore, sign in, sync | Rule stays off the device; the cloud is never told; after a pull-cursor reset it returns and the removal record is erased (R4R-02) |
| A4 | Legacy backup, "Leave out", cloud holds the rule and it was not pulled yet | **FAIL**: next sync brings the rule back (R4R-02) |
| A5 | Legacy backup: restore, Add one, Leave out one, restore again, sync, restore again | Pass: no re-prompt, nothing resurrected, cloud holds only the added rule |
| A6 | Removal record pruned by retention (10,000 newer records), then restore | Pass: the rule goes to the user's choice, not added. 10,000 inserts through the bound trigger: 753 ms |
| A7 | Backup rule stamped in the future against a newer device edit | Backup wins (R4R-05) |
| A8 | Rule deleted, re-created, restore; deleted again, restore | Pass |
| A9 | Bulk delete of 5,000 saved rules through the triggers | 25 ms, 5,000 removal records |

### Findings

| ID | Sev | Class | Finding |
|---|---|---|---|
| R4R-01 | S3 | REPRODUCED | **A failed pull lets a restore resurrect a rule everywhere.** `_pull` swallows its error and `_backfill` runs anyway (`merchant_rule_sync_service.dart` `_run`). After a restore re-arms the backfill, one failed fetch followed by a working upsert pushes the restored rule with `deleted_at: null` over a removal another device made. The device never learns of the removal. The mechanism existed for the first-ever backfill; the restore now re-arms it on every restore that writes a rule. This is the case the implementer's design note says it avoids. Fix direction: skip the backfill when the pull did not complete. |
| R4R-02 | S3 | REPRODUCED | **"Leave out" and a signed-out removal are local only, and a pull undoes them.** `_apply` writes a live cloud row without looking at the device's removal record, and saving the rule erases that record. `lrRestoreExplanation` says "Leave out keeps it off this device". The signed-out half is pre-existing and disclosed; the "Leave out" half is new. |
| R4R-03 | S3 | CODE-SUPPORTED | **"Leave all out" acts on one tap, with no confirmation and no undo** (`learned_rules_screen.dart`, key `restore-rules-leave-all`, next to "Add all"). It records a removal for every pending rule, and later restores do not ask again. With a build-147 backup on a device that has finished onboarding, every backup-only rule is pending, so one mis-tap discards them all. |
| R4R-04 | S4 | CODE-SUPPORTED | The post-restore dialog has no widget test (read: count, explanation, "Not now" / "Review rules"; correct). If `reviewCount` throws, the confirmation silently shows no count. After "Not now" nothing outside Settings → Learned rules points to the pending rules. |
| R4R-05 | S4 | REPRODUCED | Clock skew: a backup rule with a later timestamp beats a newer device edit, and a rule stamped before a removal stays removed. Inherent to last-writer-wins; not in the known limitations for rules. |
| R4R-06 | S4 | CODE-SUPPORTED | The v44 postcondition checks the three tables, not the six triggers; `CREATE TRIGGER IF NOT EXISTS` means a later change to a trigger body will not reach existing databases. A new database (new install, replica rebootstrap) counts as having complete history, so removals made on the old database while signed out are unknown to it (the implementer says so). |
| R4R-07 | S4 | SUSPECTED | A full apply re-arms the backfill but does not reset the `merchant_rules` pull cursor (`restore_backup_usecase.dart:558` resets ledger, accounts and planning cursors only). A rule the cloud holds and the backup lacks would stay absent on the device. Not reproduced. |

**R4R-01 reproduction** (A1): remember a rule, sync, back up; remove the rule and its removal record on the device; mark it deleted in the cloud as another device; restore; make the next `fetchRows` throw once; sync. Output: `cloud.live={SYNTHETIC RULE SHOP: restaurants} pushed=[SYNTHETIC RULE SHOP]`, and the same after a second, healthy sync.

**R4R-02 reproduction** (A4): legacy backup with a rule; the cloud holds the same rule live, not yet pulled; restore → pending; `decide(add: false)`; sync. The rule is `restaurants` on the device again and `merchant_rule_tombstones` is empty.

### Checked and found sound

- **Merge rule.** Every row of the rule table is exercised by their suite; A5, A6 and A8 add repeated restore, retention and delete-then-recreate.
- **Upgrade from v43, then a pre-upgrade backup.** Their test passes: older than the upgrade → the user's choice; newer → restored.
- **Triggers.** Only two code paths demote a rule and both are removals. The catalog seed inserts unconfirmed rows only. A pull that changes a rule's category is an update of a confirmed row and records nothing. No caller passes `isUserConfirmed: false`.
- **Wipe and account switch.** The three tables are in `wipedTables` after `merchant_category_map`, and the `user_settings` trigger clears them; `data_wipe_service_test` and the migration test's wipe case pass. `user_settings` is deleted only by the wipe and by a full apply, where the history tables are restored after it.
- **v44 migration.** Additive, `IF NOT EXISTS` throughout, created again unconditionally at open, marker written with `INSERT OR IGNORE`.
- **Build 147** (`git show b6fc0dad:`): `currentSchemaVersion = 4` and `restore_preparation.dart` throws `backupFromNewerApp` ("This backup comes from a newer version of the app. Update Qirsh and try again.") before any change; `_targetSchemaVersion = 43` with `UnsupportedDatabaseVersionException` for a newer database. Both claims hold. What a user sees after a TestFlight downgrade onto a v44 database was not run.
- **SP-17.** `hasCategoryForMerchant` now joins `categories` with `deleted_at IS NULL`; its test passes.
- **Destructive inventory.** The two new entries (3 and 6 statements) match the code; none deletes a rule or a financial row.
- **Changed expectations.** Schema pins 43 → 44, backup format 4 → 5, and the copy pins are decided changes. One loosened check: `sms_name_minimization_test` skips the last-digits check for a transfer with no possessive, so a real-format transfer ("To: … Acc:3583*") reaches the server with no `last4`. Disclosed by the implementer.
- **Copy.** English and Arabic confirmation and review strings match the behaviour, except "keeps it off this device" (R4R-02).

## Not checked

- XCTest was not run: another reviewer's `xcodebuild` was running on the same machine. The Swift sanitizer was compiled standalone instead; the Shortcut request test was read, not executed.
- The `[OTP]` / `[REF]` table against the deployed `b6fc0dad` server was not re-measured; I read both servers' handling only.
- Real-model behaviour; the effect of R4P-03 on a model-read merchant.
- Sentry, telemetry, push registration and backup-upload payloads.
- A device or simulator run; the post-restore dialog in a running app; the build-147 screen for a v44 database.
- R4R-01 and R4R-02 on the stack (in-memory only, with the real services); R4R-07.
- The full Flutter suite. `tools/message_eval/heldout/**` and `sample_b.jsonl` were not opened.

## Housekeeping

- Scratch: `/private/tmp/claude-501/-Users-luciq--claude-spares-spare-yEUVj2/1b6aaa41-9527-44a7-aa2c-8ab180862078/scratchpad/r4-review-pr/` holds the corpus, harness and logs (under 1 MB). The `a157e68e` export, Swift binaries and stack copy are removed.
- An untracked directory `tools/.astra-review-tmp/` appeared in the working tree during my run and was gone by the end. It was not mine; I did not touch it.
- `HEAD` moved from `a86298fc` to `2f9931cb` during my run: one commit by someone else that adds `W-round4-review-astra.md` only. No file under `app/` or `supabase/` changed, so every result here is for the code at `a86298fc`. I did not read that report.
- The only file I added to the repository is this report.
