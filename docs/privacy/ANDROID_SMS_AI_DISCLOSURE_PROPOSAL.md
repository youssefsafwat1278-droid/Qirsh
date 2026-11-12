# Android SMS + AI — disclosure (FINAL DRAFT, NOT SUBMITTED)

**Status (2026-11-12, phase 4): final draft.** The in-app wording (EN + AR) and
`docs/legal/PRIVACY_POLICY.md` have been updated in the working tree to match
the phase-4 implementation (see §8). **Nothing has been submitted** to the Play
Console, and the website has not been regenerated. Every item marked
**OWNER MUST CONFIRM** (earlier sections: **OWNER TO CONFIRM**) is a fact the
code cannot establish; do not publish or attest any text that depends on it
until it is confirmed.

**Release dependency.** The final wording is accurate only for a release that
ships together with: (1) the phase-4 backend changes **deployed** (`parse-sms`,
`bank-discovery`, `process-ios-sms`, `enrich-merchant`,
`_shared/sms_redaction.ts`, `_shared/gemini_request.ts`, `_shared/ai_primary.ts`
— not deployed at the time of writing); (2) the AES-256-GCM encrypted Android
capture queue; (3) cold-start background processing (WorkManager /
BGTaskScheduler). See §8.0.

Sections 1–6 are the phase-3 analysis, kept for the record. Where phase 4
changed a fact, §8.1 lists the correction; §8 supersedes §3–§5.

**What changed.** Android capture was on-device only. Now, when the user has
accepted *Smart Analysis & Cloud Sync* (Cloud consent AND AI consent), each
eligible captured Android message — automatic bank SMS and messages shared to
Qirsh — is sanitised on the device, sent to the `parse-sms` Edge Function on
Qirsh's Supabase project, and forwarded by that function to **Google Gemini**
(`generativelanguage.googleapis.com`). The same route also enables
`bank-discovery` (Gemini) and `enrich-merchant` (Google Places) for those
captures.

Citations are `path:line` in this worktree (base `0b91574f`). Line numbers in
`add_transaction_usecase.dart` and `legacy_capture_drain.dart` were taken while
other work was editing those files and may drift by a few lines; the function
names are given so they can be re-found.

---

## 1. Data-flow table

### 1a. Route and gates (Android)

| Step | What happens | Evidence |
|---|---|---|
| Receive | Runs only if `RECEIVE_SMS` is granted AND the in-app opt-in is on. Multipart bodies are joined; first sender kept. | `SmsCaptureReceiver.kt:37`, `:39-47`; `CaptureSettings.kt` `isAutoCaptureEnabled` |
| Prefilter | Heuristic, not a parser. OTP-like text without an amount is dropped. Alphanumeric sender: amount OR keyword retains. Numeric sender: amount AND keyword. Dropped messages are never stored. | `SmsCaptureReceiver.kt:49`, `:111-123` |
| Queue | Retained message stored on device (see 1b). | `DurableCaptureQueue.kt:66-75` (receiver), `:189-198` |
| Route | AI route is taken only if Cloud AND AI consent are on (read fresh for each message), item not `localOnly`, the remote kill switch `android_capture_ai_enabled` (compiled default **ON**) is on, and the backend is configured. Every other route sets `onDeviceOnly: true`. | `legacy_capture_drain.dart:320-347`, `:402-407`; `legacy_capture_drain_policy.dart:46-55`; `feature_flag_service.dart:98-105` |
| OTP/promo check | The deterministic ignore filter runs first; ignored messages are never sent to AI. | `legacy_capture_drain.dart:391` |
| Consent re-check | `ConsentAuthority.decide(aiProcessing)` = cloud && AI && not frozen, checked again inside the use case just before the request. | `consent_authority.dart:148-171`; `app_providers.dart:1893-1902`; `add_transaction_usecase.dart` `_tryAiParseFirst` (~:1779-1815) |
| Sanitise | `SmsSanitizer.sanitize(raw, detectedType: _privacyTypeHint(raw))` on device. | `add_transaction_usecase.dart` `_tryAiParseFirst` (~:1789); `_privacyTypeHint` (~:1974) |
| Transport | `GatedHttpClient` → `CloudEgressGate.admit` (durable consent record; freeze/alignment denial). | `ai_parser_client.dart:79`; `cloud_egress_gate.dart:3217-3262` |
| Server | Verified identity, server-side consent check (cloud && AI), daily cap, server re-sanitisation, Gemini call. | `parse-sms/index.ts:256-260`, `:273-279`, `:320`, `:446-466` |

### 1b. Field-by-field

Abbreviations: **Dev** = on device; **QB** = Qirsh backend (Supabase project);
**G** = Google Gemini API; **GP** = Google Places API.

| Field | Collected on device? | Transmitted? To whom | Purpose | Retention | Deletion path |
|---|---|---|---|---|---|
| **Raw SMS body (unsanitised)** | Yes. Stored as JSON in app-private SharedPreferences `mali_capture_queue_v1`, or one file per item under `files/capture_overflow/` (`DurableCaptureQueue.kt:83-84`, `:111-118`, `:298-318`). **Not** SQLCipher-encrypted. Then stored in the SQLCipher DB as `transactions.raw_message` / `suspected_duplicates.raw_message` (`app_database.dart:1886`, `:2225`). | **No.** Only the sanitised copy leaves the device. | Local parsing, dedup, audit | Queue: until the drain acknowledges a committed import (`DurableCaptureQueue.kt:466-471`). Corrupt items are kept **verbatim** in quarantine indefinitely (`:248-251`, `:329`). DB: until the transaction is deleted or local data is wiped. | Queue purge exists natively (`DurableCaptureQueue.kt:483-491`, `MainActivity.kt:187-194`) but **has no production caller** (see Finding F1). Uninstall removes everything. `allowBackup="false"` (`AndroidManifest.xml:67-68`). |
| **Sanitised SMS text** | Built in memory | **QB** (`sanitized_sms`, `ai_parser_client.dart:105`) → re-sanitised (`parse-sms/index.ts:320`) → **G** inside the prompt (`:376-444`; `ai_primary.ts:76-92`). Also **QB → G** via `bank-discovery` for bank-like senders the catalogue does not know (`add_transaction_usecase.dart` `_runBankDiscoveryIfEligible`; `bank-discovery/index.ts:98-117`, `:228-231`). | Extract amount, currency, merchant, type, direction, date, category; identify an unknown bank | **QB:** the text is not written to any table; only `sha256(ownerKey, endpoint, text)` is stored (`parse-sms/index.ts:347`; `ai_endpoint.ts:322-324`). **G:** **OWNER TO CONFIRM**. **Platform logs:** our code logs only safe fields (`ai_endpoint.ts:124-126`); Supabase platform log retention **OWNER TO CONFIRM**. | No QB copy to delete. G: per Google terms (**OWNER TO CONFIRM**). |
| **Sender ID** (e.g. `AlRajhiBank` or a phone number) | Yes (queue + DB) | **QB** (`sender_id`, `ai_parser_client.dart:106`). `parse-sms` does **not** put it in the Gemini prompt (prompt contains only the re-sanitised text and today's date, `parse-sms/index.ts:376-444`). `bank-discovery` **does** put it in the Gemini prompt verbatim (`bank-discovery/index.ts:228`) and logs a short hash of it (`:99-105`). | Bank attribution | QB: not stored by `parse-sms`. G: **OWNER TO CONFIRM**. | — |
| **SMS receipt time** | Yes | Not sent to `parse-sms` as a field (body: `ai_parser_client.dart:104-113`). Dates written inside the message text are sent as part of the text. | — | — | — |
| **Install ID (raw)** | Yes | **QB** (`install_id`), hashed server-side to find the device (`ai_endpoint.ts:219-233`). Not sent to G. | Identity / rate limit | `capture_devices` row (hash), no TTL; `last_seen_at` updated on each call (`ai_endpoint.ts:244-247`). | Account deletion (`0113_purge_user_data_claimed_captures.sql`, `0117_account_deletion_fence.sql`). |
| **Device secret** | Yes | **QB** (`device_secret`) — compared to a stored hash (`ai_endpoint.ts:227-238`). Not sent to G. | Authentication | Hash only, in `capture_devices`. | Account deletion. |
| **User JWT** | Yes | **QB**, `Authorization: Bearer` — user access token, else the anon key (`app_providers.dart:1876-1885`; `ai_parser_client.dart:124-127`). Not sent to G. | Authentication; links the request to the user (`ownerKey = u:<uid>` or `d:<installHash>`, `ai_endpoint.ts:252`, `:277`). | Not stored by our code. | — |
| **request_id, schema_version, analysis_mode** | Generated | **QB** (`ai_parser_client.dart:103-113`) | Idempotency (no double AI charge) | `ai_request_idempotency` row: owner key, request id, payload hash, status, **result JSON**; `expires_at` = +1 h (`ai_endpoint.ts:317`, `0071_ai_endpoint_hardening.sql:27-38`), pruned by a daily job at 03:25 UTC (`0112_capture_notifications_retention.sql:682`) → **up to ~25 h**. | Daily prune; account deletion (`0113_purge_user_data_claimed_captures.sql:95`). |
| **AI result**: `is_transaction`, `amount`, `amount_text`, `currency`, `merchant_name`, `type`, `direction`, `category_key`, `occurred_at`, `model_used` | Response is parsed on device (`ai_parser_client.dart:18-56`, `:132-145`) | Returned **G → QB → Dev**. Copy kept in `ai_request_idempotency.result` (`ai_endpoint.ts:361-376`, `parse-sms/index.ts:363-368`). | Create the transaction | QB: up to ~25 h (above). Dev: as part of the transaction. | As above. |
| **Transaction derived from the SMS** (amount, currency, merchant, note, date, card_last4, balance_after, foreign amount, category, status, type/source/direction) | Yes (SQLCipher DB) | **QB** ledger sync, only with Cloud consent (`EgressClass.financialSync`) (`ledger_outbox_queue.dart:690-727`; `app_providers.dart:749-884`). **The raw and sanitised SMS text are not in the sync payload.** | Multi-device sync, backup | No TTL — until deleted or account deletion (existing policy §6). | In-app delete; account deletion. |
| **Merchant name** (purchase/refund, when rules and AI both fell back to "other") | Yes | **QB** `enrich-merchant` → **GP** Text Search if `GOOGLE_MAPS_API_KEY` is set (`add_transaction_usecase.dart` ~:1182-1184; `enrich-merchant/index.ts:43-44`, `:311-321`). Gated by Cloud consent only (`app_providers.dart` `mayEnrichMerchant`), and on Android reached only on the AI route because other routes are `onDeviceOnly`. | Categorise merchant | Written to the **global** `merchant_keywords` catalogue (keyword, category, country; no user id) (`enrich-merchant/index.ts:358-370`) — no TTL. GP: **OWNER TO CONFIRM**. | Not deleted by account deletion (not linked to a user). |
| **Rate-limit counter** | — | QB only | 500 calls/day per identity (`parse-sms/index.ts:50`, `:273-279`; `capture_auth.ts:193-218`) | `capture_rate_limits` (key = owner key + endpoint, date, count). **No TTL prune found** in migrations. | Account deletion (`0113_purge_user_data_claimed_captures.sql:86`). |
| **Crash reports (Sentry)** | — | Sentry, only while Cloud consent + diagnostics gate + durable egress permit hold; SDK is not even initialised otherwise (`sentry_lifecycle.dart:1-60`, `:77-104`). Dart events: messages, breadcrumbs, request, user, threads dropped; tags/extras allowlisted (`telemetry_sanitizer.dart:38-62`). Native receiver logs outcome names only (`SmsCaptureReceiver.kt:81`). **Limit:** native (Kotlin) crashes bypass the Dart scrubber (`telemetry_sanitizer.dart:21-26`). | Crash triage | Sentry retention **OWNER TO CONFIRM**. | Sentry-side **OWNER TO CONFIRM**. |
| Smart Inbox | Local rows when AI/local parse fails | Android in-app path writes local rows only; Smart Inbox sync pushes a **status** update for server-created items (`smart_inbox_sync_service.dart:62`). | Review | Local | Local wipe |

**Server-side copy of the text — answer:** for the Android `parse-sms` route,
no table stores the SMS text (raw or sanitised). What persists is a hash, the
extracted result for up to ~25 h, a device `last_seen_at` timestamp and a daily
counter. This is different from the iOS route (`process-ios-sms`), which stores
sanitised text in `processed_captures` for 30 days. Platform logs and Google's
retention are **OWNER TO CONFIRM**.

---

## 2. What sanitisation removes — and what it does not

Applied twice: on device (`sms_sanitizer.dart:142-177`) and again on the server
before Gemini (`sms_redaction.ts:77-85`, `:104-109`; `parse-sms/index.ts:74-76`).

**Removed**

| Item | Rule |
|---|---|
| Full 16-digit card numbers (with spaces/dashes) | `[CARD]` — `sms_sanitizer.dart:46-48` |
| Saudi `05xxxxxxxx`, Egyptian `01[0125]xxxxxxxx`, `+` international numbers | `[PHONE]` — `:54-60` |
| IBANs (case-insensitive) | `[IBAN]` — `:72-74` |
| Digits that follow an explicit OTP cue (`OTP`, `verification code`, `رمز التحقق` …) | `[OTP]` — `:82-87` |
| Any remaining run of 10–20 digits | `[ACCOUNT]` — `:93` |
| Text after `إلى:` / `الى:` / `To:` to end of line | Device: for transfer/income/unknown only (`:163-171`). Server: always (`sms_redaction.ts:104-109`). So it never reaches Gemini. |
| Name after `عزيزي` / `عزيزتي` | `[REDACTED]` — `:110-113` |
| Arabic-Indic digits | Handled by every digit rule — `:32-41` |

**Not removed (reaches Gemini)**

- Amounts and currencies; **balances** ("available balance 12,345.67 SAR").
- **Merchant / location names** (purchases keep `To:` on the device; the server
  strips only the `To:`/`إلى:` line form, not "at STARBUCKS RIYADH").
- **Dates and times** written in the message.
- **Masked/partial card or account digits** (`*1234`, `ending 1234`,
  `XXXX1234`) — kept by design (`sms_sanitizer.dart:44-45`).
- **Reference / transaction numbers of up to 9 digits**.
- **Bank and branch names** in the text.
- **Payer or counterparty names introduced by `من` / `from` / `received from`
  / `credited by`, and English greetings (`Dear Ahmed`)** — no rule covers them.
  Incoming-transfer messages can therefore carry a third party's name to Gemini.
- Free text such as location, ATM name, or wallet name.

**Plain statement for reviewers:** the sanitised text is still personal
financial data. It describes a specific purchase or transfer by a specific
person at a specific time, with amount, merchant and balance; the request is
authenticated as that user's account or device. It is **pseudonymised at best,
not anonymous**, and must not be described as anonymous anywhere.

---

## 3. Proposed in-app wording (phase 3 — superseded: final text applied, see §8.2)

Context: the UI no longer has separate Cloud and AI switches. One sheet,
*Smart Analysis & Cloud Sync*, grants both together
(`smart_analysis_consent_sheet.dart:25`), and Privacy shows one consent card
(`privacy_screen.dart:105-112`). Wording below follows that.

Constraints from existing tests (keep or update the test together):
`test/l10n/privacy_copy_test.dart` requires `privCloudProcessingBody`,
`privAiAnalysisBody`, `smartConsentBullet1` to keep the exact sanitisation
phrase, AI keys to say "may be analysed" (EN) / contain `قد ` (AR), and none to
contain "every", "only when", `كل رسالة`, `فقط عندما`.
`test/features/capture/android_sms_permission_test.dart:262-270` requires
`smsDisclosureOnDevice` to exist. The proposals below satisfy both.

### 3a. Strings that are now inaccurate or incomplete

| Key | Current (EN) | Problem |
|---|---|---|
| `smsAutoCaptureSubtitleOn` (`app_en.arb:357`, `app_ar.arb:467`; shown at `settings_screen.dart:2712`) | "On — incoming bank messages are read on your device only" | **False** when Smart Analysis is on. |
| `smsDisclosureOnDevice` (`app_en.arb:275`, `app_ar.arb:370`) | "…If you enable cloud processing, a sanitized copy … is sent to Qirsh's servers." | Omits that Google Gemini processes it; omits what stays in the text. |
| `smsDisclosureCloud` (`app_en.arb:276`, `app_ar.arb:374`) | "Cloud sync is off by default…" | Names only sync; the relevant consent is Smart Analysis & Cloud Sync. |
| `smsDisclosureFilter` (`app_en.arb:274`, `app_ar.arb:366`) | "…are ignored and not stored." | Absolute; the prefilter is heuristic (privacy policy §8 already says so). |
| `privIntro` (`app_en.arb:1363`, `app_ar.arb:1486`; `privacy_screen.dart:75`) | "…bank messages you share through the shortcut…" | iOS-only; Android SMS not mentioned. |
| `privAiAnalysisBody` (`app_en.arb:1335`, `app_ar.arb:1458`) | "…may be analysed by an AI service…" | Does not name the provider or that Android SMS are included. |
| `smartConsentBullet1` (`app_en.arb:3061`, `app_ar.arb:3184`) | Names Gemini; accurate | Should add that details remain and the text is linked to the account. |
| `onbCloudBullet1`, `onbAiBullet1` | — | No longer referenced from `lib/features`; leave or remove. |

### 3b. Proposed replacements

**`smsDisclosureFilter`**
- EN: "Messages that do not look financial — such as personal messages and verification codes — are dropped on your device and not stored. The check is automatic and can occasionally keep a message it should not; you can delete it in Qirsh."
- AR: "تُستبعد على جهازك الرسائل التي لا تبدو مالية — مثل الرسائل الشخصية ورموز التحقق — ولا تُخزَّن. هذا الفحص آلي وقد يحتفظ أحيانًا برسالة لا داعي لحفظها، ويمكنك حذفها من قِرش."

**`smsDisclosureOnDevice`**
- EN: "With Smart Analysis & Cloud Sync off, messages are read only on your device. If you turn it on, captured bank messages are sent to Qirsh's servers and analysed by Google Gemini, after card, account and phone numbers, IBANs and codes are removed. The amount, merchant, date, balance and last card digits stay in the text, so it is still your personal financial information."
- AR: "عند إيقاف «التحليل الذكي والمزامنة السحابية» تُقرأ الرسائل على جهازك فقط. وإذا فعّلته، تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش ويحلّلها Google Gemini، بعد حذف أرقام البطاقات والحسابات والهواتف والآيبان والرموز. يبقى في النص المبلغ والتاجر والتاريخ والرصيد وآخر أرقام البطاقة، لذا يظل معلومات مالية شخصية تخصّك."

**`smsDisclosureCloud`**
- EN: "Smart Analysis & Cloud Sync is a separate choice from this permission. It stays off unless you accept it, and you can withdraw it at any time in Settings → Privacy."
- AR: "«التحليل الذكي والمزامنة السحابية» خيار منفصل عن هذا الإذن، ويبقى متوقفًا ما لم توافق عليه، ويمكنك سحب موافقتك في أي وقت من الإعدادات ← الخصوصية."

**`smsAutoCaptureSubtitleOn`** (make neutral) + **new key `smsAutoCaptureSubtitleOnSmart`**
(code change needed at `settings_screen.dart:2712` to pick the new key when
`cloudProcessingEnabled && aiConsentGranted`):
- `smsAutoCaptureSubtitleOn` EN: "On — incoming bank messages are read on your device" / AR: "يعمل — تُقرأ رسائل البنك الواردة على جهازك"
- `smsAutoCaptureSubtitleOnSmart` EN: "On — bank messages are captured and analysed by Google Gemini after sensitive numbers are removed" / AR: "يعمل — تُلتقط رسائل البنك ويحلّلها Google Gemini بعد حذف الأرقام الحساسة"

**`smartConsentBullet1`** (AI consent sheet)
- EN: "Captured bank messages — including bank SMS read automatically on Android — are sent to Qirsh servers after card, account and phone numbers and codes are removed. Google Gemini may process this text to identify the amount, merchant and bank. Amounts, merchants, dates, balances and last card digits stay in the text, and it is linked to your account, so it is not anonymous."
- AR: "تُرسل الرسائل البنكية الملتقطة — ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد — إلى خوادم قرش بعد إزالة أرقام البطاقات والحسابات والهواتف والرموز. قد تعالج خدمة Google Gemini هذا النص لتحديد المبلغ والتاجر والبنك. يبقى في النص المبلغ والتاجر والتاريخ والرصيد وآخر أرقام البطاقة، ويرتبط بحسابك، لذا فهو ليس مجهول الهوية."

**Optional new key `smartConsentBullet4`** — add ONLY after the owner confirms
Google's retention/training terms (§6 items 1–3):
- EN: "Qirsh's servers do not keep the text of Android messages after reading them. Google processes it under its terms for [OWNER TO CONFIRM: e.g. 'paid API services, without using it to train its models']."
- AR: "لا تحتفظ خوادم قِرش بنص رسائل أندرويد بعد قراءتها. وتعالجه Google وفق شروطها [يؤكده المالك]."

**`privAiAnalysisBody`** (Privacy → Smart Analysis)
- EN: "With Cloud Sync on, captured bank messages — including bank SMS read automatically on Android — with card, account and phone numbers and codes removed, may be analysed by Google Gemini to read the amount, merchant and bank. The text still contains amounts, merchants, dates and balances. Withdrawing consent limits reading to Qirsh's on-device rules."
- AR: "عند تشغيله مع المزامنة السحابية، قد تُحلَّل رسائل البنك الملتقطة — ومنها رسائل SMS البنكية التي تُقرأ تلقائيًا على أندرويد — بعد حذف أرقام البطاقات والحسابات والهواتف والرموز، بواسطة Google Gemini لقراءة المبلغ والتاجر والبنك. يبقى في النص المبالغ والتجار والتواريخ والأرصدة. سحب الموافقة يقصر القراءة على قواعد قِرش داخل جهازك."

**`privCloudProcessingBody`** (Privacy → Cloud)
- EN: "Captured bank messages may be sent to Qirsh servers, with card, account and phone numbers and codes removed, to be read; your transactions and settings are synced and backed up there. Turning it off keeps everything on this device: messages are read by Qirsh's on-device rules and nothing is synced. Manual entry keeps working."
- AR: "قد تُرسَل رسائل البنك الملتقطة إلى خوادم قِرش بعد حذف أرقام البطاقات والحسابات والهواتف والرموز لقراءتها، وتتم مزامنة معاملاتك وإعداداتك ونسخها احتياطيًا هناك. عند الإيقاف يبقى كل شيء على جهازك: تُقرأ الرسائل بقواعد قِرش المحلية ولا تتم أي مزامنة، ويظل الإدخال اليدوي متاحًا."

**`privIntro`**
- EN: "With Smart Analysis & Cloud Sync on, bank messages captured by Qirsh — SMS read automatically on Android, or messages you share or send through the iOS shortcut — may be processed as sanitised text on Qirsh servers and by Google Gemini. With it off, messages are parsed on this device. You can export or import your financial data from Data transfer."
- AR: "عند تفعيل «التحليل الذكي والمزامنة السحابية»، قد تُعالَج رسائل البنك التي يلتقطها قِرش — رسائل SMS التي تُقرأ تلقائيًا على أندرويد، أو الرسائل التي تشاركها أو ترسلها عبر اختصار iOS — كنص مُنقّى على خوادم قِرش وبواسطة Google Gemini. عند إيقافه تُحلَّل الرسائل على هذا الجهاز. ويمكنك تصدير بياناتك المالية أو استيرادها من شاشة نقل البيانات."

After any ARB change: `flutter gen-l10n` from `app/`, then run
`test/l10n/privacy_copy_test.dart` and
`test/features/capture/android_sms_permission_test.dart`.

---

## 4. Proposed privacy-policy text (phase 3 — superseded: applied to `docs/legal/PRIVACY_POLICY.md`)

Sections that are now inaccurate:

- **§1, bullet 3** and **§7 "About the AI row"** describe cloud processing and AI
  as "two choices". The UI grants them together. Replace "two choices, both off
  by default" with "one choice, *Smart Analysis & Cloud Sync*, off unless you
  accept it".
- **§7 table**: "AI provider" should name **Google (Gemini API)**; add
  **Google (Places API)** — receives a merchant name, with Cloud on.
- **§6 retention**: "Sanitized captured message text … deleted after 30 days"
  is true for the iOS route only. Add the Android row below.
- **§8 "Where captured messages are processed"** says the sanitised copy "is
  stored there" and that AI is "a third, separate consent" — both no longer
  match Android.

Proposed replacement for **§8 "Where captured messages are processed"** (keeps
the phrases pinned by `android_sms_permission_test.dart:217-260`):

> ### Where captured messages are processed
>
> **By default, captured message text is read on your device and does not
> leave it.**
>
> If you accept **Smart Analysis & Cloud Sync** — a separate consent from the
> SMS permission, off unless you accept it — captured bank messages are
> **sanitized** on your device and then sent to Qirsh's servers, which pass the
> text to **Google's Gemini API** to read the amount, currency, merchant,
> transaction type and date. On Android this includes bank SMS that Qirsh reads
> automatically and messages you share to Qirsh. Sanitizing removes:
>
> - full card numbers,
> - phone numbers,
> - account numbers and IBANs,
> - one-time codes that follow a code label,
> - the recipient name on a "To:" / «إلى:» line.
>
> What stays in the text: the amount and currency, the balance if the bank
> includes it, the merchant or place, dates and times, short reference numbers,
> masked card endings (`*1234`), and any name written another way (for example
> the sender of an incoming transfer). **This text is still personal financial
> information about you; it is not anonymous.** Requests are linked to your
> account or device so that we can authenticate and rate-limit them.
>
> For an unrecognised bank sender, the sender name and the sanitized text may
> also be sent to Gemini to identify the bank. For a purchase we cannot
> categorise, the merchant name may be sent to Google's Places API.
>
> **What we keep.** For Android messages, Qirsh's database does not store the
> message text. It keeps a one-way fingerprint of the request and the extracted
> result (amount, merchant, date, category) for up to about one day to prevent
> duplicate processing, and then deletes it automatically. Messages captured on
> iOS through the Shortcut are kept as sanitized text for 30 days (see §6). The
> transactions created from your messages are synced like any other transaction
> and kept until you delete them or your account. Google's handling of the text
> it receives: **[OWNER TO CONFIRM — retention period, whether it is used for
> training, abuse-monitoring logging]**.
>
> So: with the default settings, message text stays on your device. If you
> accept Smart Analysis & Cloud Sync, sanitized text does leave your device and
> is processed by Google — we will not tell you otherwise. You can withdraw
> consent at any time in Settings → Privacy; sending stops immediately.

Proposed §6 rows:

| Data | Retained |
|---|---|
| Sanitized message text from Android | Not stored in Qirsh's database |
| Extracted result of an AI request (fingerprint, amount, merchant, date, category) | Up to about one day, then deleted automatically |
| Sanitized captured message text from iOS | Deleted automatically after 30 days |
| Daily request counters | **OWNER TO CONFIRM** (no automatic expiry found; removed on account deletion) |
| Text sent to Google Gemini / Places | **OWNER TO CONFIRM** (per Google's terms) |
| Service logs on our hosting provider | **OWNER TO CONFIRM** |

---

## 5. Google Play — proposed answers (phase 3 — superseded by §8.3–§8.5; NOT submitted)

Assumptions: (a) Play counts data as *collected* when it is transmitted off the
device; (b) a transfer to a **service provider** that processes it only on the
developer's behalf is generally **not "sharing"**. Assumption (b) holds for
Gemini/Places **only if** the owner confirms Google does not use the content for
its own purposes (§6). **OWNER TO CONFIRM both against the current Play Help
Center text before attesting.**

### 5a. Data types (Android build)

| Play data type | Collected | Shared | Optional? | Processed ephemerally? | Purposes | Basis in code |
|---|---|---|---|---|---|---|
| **Messages → SMS or MMS** (sanitised SMS text, sender ID) | **Yes** | **No** (assumption b) | **Yes** — needs RECEIVE_SMS + opt-in + Smart Analysis & Cloud Sync | **Do not claim** until Google's retention is confirmed; our DB holds no text, but the extracted result is kept ≤ ~25 h and Google's retention is unknown | App functionality | §1b |
| **Financial info → Purchase history** (amount, merchant, date of captured purchases) | Yes | No | Yes (Cloud) | No | App functionality | `ledger_outbox_queue.dart:690-727`; AI result |
| **Financial info → Other financial info** (balances, card last 4, accounts, transfers) | Yes | No | Yes (Cloud) | No | App functionality | same |
| **Personal info → User IDs** (account id via JWT) | Yes | No | **OWNER TO CONFIRM** (existing draft says Required because sign-in is mandatory) | No | App functionality, account management | `ai_endpoint.ts:261-287` |
| **Device or other IDs** (install id, device secret) | Yes | No | Yes (only with Cloud) | No | App functionality, fraud prevention/security | `ai_endpoint.ts:219-258` |
| **App activity** | No new collection from this change. Existing telemetry declared per the existing draft. | — | — | — | — | — |
| **App info and performance → Crash logs / Diagnostics** | Yes | No (Sentry as service provider — assumption b) | Yes | No | Analytics / app functionality | `sentry_lifecycle.dart`; `telemetry_sanitizer.dart` |

Security section:
- **Encrypted in transit: Yes** — Gemini/Places URLs are `https://`
  (`parse-sms/index.ts:49`, `ai_primary.ts:77`, `enrich-merchant/index.ts:44`);
  the Supabase URL comes from the build config (`supabase_config.dart:6`) —
  **OWNER TO CONFIRM** it is `https://` in every release config.
- **Users can request deletion: Yes** — in-app account deletion
  (`privacy_screen.dart:163-170`, route `/delete-account`) plus the policy email
  (`<CONTACT_EMAIL>` still a placeholder, `PRIVACY_POLICY.md:256`).
- Do **not** answer "data is anonymised" for SMS.

### 5b. Permissions Declaration (RECEIVE_SMS) — changes to `Qirsh Production/18_Android_SMS_Capture/play_declaration_draft.md`

Inaccurate today:
- §2 "Cloud processing and AI assistance are two separate switches, both off
  by default" → one combined consent.
- §2 "The sanitized copy is retained for 30 days" → for Android the text is not
  stored; the derived result is kept ≤ ~25 h.
- §2 "may be processed by an AI provider" → name Google Gemini; add that the
  sender ID can be sent for bank identification and the merchant name to Google
  Places.
- §3 quotes `smsDisclosure*` verbatim → regenerate from the final ARB text.
- §5 step 12 "cloud processing and AI assistance both off" → "Smart Analysis &
  Cloud Sync not accepted".

Proposed §2 text:

> Incoming messages are screened on the device before anything is stored; only
> messages that look like financial transactions are retained. By default,
> parsing happens on the device and no message content leaves it.
>
> If the user accepts **Smart Analysis & Cloud Sync** — a separate, explicit
> consent, not bundled with the permission — a sanitized copy of each captured
> financial message (full card numbers, account numbers, IBANs, phone numbers,
> labelled one-time codes and "To:" recipient names removed on the device) is
> sent to Qirsh's backend, which forwards it to Google's Gemini API, acting as
> Qirsh's service provider, solely to extract the transaction for the user's own
> record. Qirsh's backend does not store the message text; it keeps the
> extracted result for up to about a day for de-duplication. SMS data is never
> sold, never used for advertising, marketing or profiling, and never shared
> for any other purpose. [OWNER TO CONFIRM: Google's retention and no-training
> terms for the API tier in use.]

Store listing: add one sentence — "Optional Smart Analysis sends a sanitized
copy of bank messages to Google Gemini to read them; it is off unless you
accept it."

Data Safety draft (`data_safety_draft.md`) rows now wrong for Android: "Sanitized
SMS text — gate `cloudProcessingEnabled`, retained in `processed_captures`"
(Android gate is Cloud AND AI; not retained); "Merchant keywords — not wired"
(now wired via `enrich-merchant`, Cloud-gated); line 199-203 "`GEMINI_API_KEY`
is not currently set on production" (**OWNER TO CONFIRM** current state).

### 5c. iOS comparison

`ios/Runner/PrivacyInfo.xcprivacy` declares Other Financial Info, Email, Name,
Phone, Device ID (linked, not tracking) and Crash Data. It has no messages
type; Apple has no SMS category, so sanitised message text falls under Other
Financial Info there. Play has a distinct **SMS or MMS** type, which is the one
to use on Android.

---

## 6. Facts the owner must confirm (not derivable from code)

1. **Gemini API terms in force** for the production key: paid vs unpaid tier,
   whether prompts/responses may be used to improve Google products or train
   models, retention for abuse monitoring, and the terms version + date checked.
2. Whether **`GEMINI_API_KEY` is set in production**, which Google Cloud project
   and billing account it belongs to, and the production value of
   `GEMINI_SMS_MODEL` (code default `gemini-3.8-flash`, `parse-sms/index.ts:33`)
   and `GEMINI_MODEL` for bank-discovery (default `gemini-2.5-flash-lite`,
   `bank-discovery/index.ts:22`).
3. **Data processing agreement** with Google covering the Gemini API (and Places
   API), with Supabase, and with Sentry.
4. **Processing locations / cross-border transfer**: Supabase project region;
   Gemini processing region; any obligations under Saudi PDPL / Egyptian PDPL
   for financial data of users in those markets.
5. **Supabase Edge Function and API log retention** for the plan in use
   (request metadata, IP addresses); confirm nothing logs request bodies.
6. **Google Places**: whether `GOOGLE_MAPS_API_KEY` is set in production and the
   applicable terms.
7. **Sentry**: retention, region, and acceptance of the native-crash scrubbing
   gap (`telemetry_sanitizer.dart:21-26`).
8. Production value of the **`android_capture_ai_enabled`** remote flag (compiled
   ON).
9. Whether **`capture_rate_limits`** should get a TTL (none found).
10. Whether Play's **"processed ephemerally"** answer can be used (depends on 1
    and 5).
11. That off-device AI processing of SMS content is acceptable under the current
    Play **SMS/Call Log permissions policy** money-management exception, and how
    Google expects it described.
12. The policy contact email (still `<CONTACT_EMAIL>`) and that the policy's
    "Delete local data" / "Delete cloud data" paths (§5) still exist in the UI —
    only `/delete-account` was located in `privacy_screen.dart`.
13. That the live site `qirsh.site/privacy` is regenerated from the final text.

---

## 7. Engineering findings — status at phase 4 (2026-11-12)

| # | Finding (phase 3) | Status | Evidence |
|---|---|---|---|
| **F1** | Android capture queue never purged; queued SMS had no owner and could be drained by the next account (incl. the AI route). | **FIXED in phase 3** (commit `8866dd13`): Keystore-HMAC owner stamps; only the active owner's captures are drained; captures taken while signed out are imported only through the explicit claim prompt (on device, no AI); Remove data sweeps that account's captures, resets the SMS opt-in, cancels background work and keeps its barrier until verified. Owner-isolation JVM harness 47 checks pass (`scratchpad/sms_pipeline_phase3.md`). Device check still outstanding (phase-3 real-device list, item 7–9). | `DurableCaptureQueue.kt`, `MainActivity.kt`, `native_capture_bridge.dart` |
| **F2** | `0071_ai_endpoint_hardening.sql:26` says "Raw SMS / merchant text is NEVER written here", but `ai_request_idempotency.result` holds the AI output (merchant, amount, date) for ≤ ~25 h. | **OPEN (documentation only).** Applied migrations must not be edited. Disclosed accurately in the policy §6 ("extracted result … at most about 25 hours"). Recommended: a follow-up migration with `COMMENT ON TABLE ai_request_idempotency IS '…stores the extracted AI result (merchant, amount, date) for ~1 h, pruned daily; never the SMS text'`. Not in this workstream's files. | `0071_ai_endpoint_hardening.sql:22-26`; `ai_endpoint.ts:317` (`AI_IDEMPOTENCY_TTL_SECONDS = 3600`); `0112_capture_notifications_retention.sql:682` (prune 03:25 UTC) |
| **F3** | `bank-discovery` put the raw sender ID (possibly a phone number) into the Gemini prompt; `parse-sms` received `sender_id` it never used. | **ADDRESSED in phase 4 (backend not yet deployed).** Device: discovery runs only for a sender `BankSenderFilter.isLikelyBank` accepts; phone-number and numeric short-code senders are never sent (`bank_discovery_service.dart:55-56`; test `bank_discovery_service_test.dart` "phone-number and numeric short-code senders are never sent"). Server: `redactSenderForAi` replaces any phone-like / letter-less sender with `[NUMERIC_SENDER]` before the prompt (`sms_redaction.ts:433-439`; `bank-discovery/index.ts:230`). Device no longer sends `sender_id` to `parse-sms` (`ai_parser_client.dart:105-109`). An alphanumeric bank sender ID **is** still sent to Gemini by bank-discovery — disclosed. | as cited |
| **F4** | Sanitiser left names after `من` / `from` / `received from` / `credited by` and English greetings. | **ADDRESSED in phase 4 (server side not yet deployed).** Device and server both mask, as `[NAME]` keeping the cue: names after salutations (Dear/Hi/Hello at sentence start, عزيزي/عزيزتي/السيد/السيدة/الأستاذ…) always; names after counterparty cues (from/to/by/beneficiary/sender/remitter/recipient/payer/Mr/Mrs/من/إلى/لصالح/باسم/المستفيد/المرسل…) only when the text reads as a transfer/credit and not a purchase/refund/bill. Also new: e-mails → `[EMAIL]`; 6–9 character references after Ref/RRN/رقم المرجع/رقم العملية… → `[REF]`. Merchants, amounts, dates, balances and masked card digits are kept. Shared fixture `supabase/functions/_shared/fixtures/sms_redaction_cases.json` pins device and server to identical output. **Limit:** a name not introduced by one of these cues (or in a message that also reads as a purchase) still reaches Gemini — wording says "recognised names". `enrich-merchant` refuses a merchant name containing an identifier (`enrich-merchant/index.ts:265-271`); the device never sends one (`add_transaction_usecase.dart` ~:1184, `SmsSanitizer.containsIdentifier`). | `sms_sanitizer.dart:124-256`, `:301-333`; `sms_redaction.ts`; `test/engine/privacy/sms_name_minimization_test.dart` |
| **F5** | Android queue at rest not encrypted. | **IN PROGRESS (another phase-4 workstream; uncommitted at the time of writing).** AES-256-GCM with a non-exportable Android Keystore key (`qirsh_capture_queue_aes_v1`), sealed main segment, overflow and quarantine; backup and device-to-device transfer excluded (`AndroidManifest.xml:72-74`, `res/xml/data_extraction_rules.xml`). Design: `docs/ANDROID_SMS_CAPTURE_DECISION.md` "Storage at rest (encryption)". The wording "stored encrypted on your device" (`smsDisclosureFilter`, policy §1/§2/§8) **depends on this landing in the same release**. | `CaptureQueueCrypto.kt`, `DurableCaptureQueue.kt` |
| F6 (new) | Gemini "Logs and Datasets" stores generateContent requests by default for projects created after 2026-10-26. | **ADDRESSED in phase 4 (not yet deployed):** every Gemini request body is built by `geminiRequestBody`, which forces top-level `store:false` (request-level opt-out, takes precedence over the project setting). All four callers use it: `parse-sms/index.ts:484`, `_shared/ai_primary.ts:82`, `bank-discovery/index.ts:118`, `process-ios-sms/parse.ts:352`. Google's 55-day abuse-monitoring retention still applies and is disclosed. | `_shared/gemini_request.ts`; `_shared/gemini_request_test.ts` |

---

## 8. FINAL DRAFT — wording, policy and Google Play answers (NOT SUBMITTED)

### 8.0 Facts this wording depends on

| Fact | Where it holds | Status at writing |
|---|---|---|
| Server masks names / e-mails / references like the device | `_shared/sms_redaction.ts` | Code in tree, **not deployed** |
| `store:false` on every Gemini request | `_shared/gemini_request.ts` + 4 callers | Code in tree, **not deployed** |
| bank-discovery never puts a numeric/phone sender in the prompt | `sms_redaction.ts:433` (`redactSenderForAi`), device filter | Code in tree, **server not deployed** (device filter already ships) |
| `parse-sms` does not receive `sender_id` | `ai_parser_client.dart:105-109` | In the app release |
| enrich-merchant refuses identifier-bearing names | `enrich-merchant/index.ts:265-271` | Code in tree, **not deployed** |
| Android capture queue encrypted at rest (AES-256-GCM, Keystore) | `CaptureQueueCrypto.kt` | **In progress** (other workstream) |
| Cold-start background processing under the same consent checks | `headless_capture_drain.dart`, `CaptureDrainWorker.kt`, iOS BGTask | **In progress** (other workstream) |
| Android AI result cache ~1 h, pruned daily → ≤ ~25 h | `ai_endpoint.ts:317`, `0112_capture_notifications_retention.sql:682` | Deployed migrations (per repo) |
| iOS server copy: content unavailable at 168 h, nulled on consume, row deleted at 30 d | `0112_capture_notifications_retention.sql:22-48`, `:636-655`; consume `0117_account_deletion_fence.sql:4656-4658` | Deployed migrations (per repo) |
| iOS unbound queue items expire after 30 days on device | `SharedCaptureStore.swift:988-1007` | Current code; `docs/privacy/CAPTURE_RETENTION_PROPOSAL.md` proposes removing it. The policy does not state an on-device expiry, so it stays true either way. |

### 8.1 Corrections to §1–§2 after phase 4

- §1b "Sender ID" row: the device no longer sends `sender_id` to `parse-sms`.
  bank-discovery sends only an alphanumeric (brand) sender to Gemini; numeric
  and phone senders are filtered on the device and replaced on the server.
- §1b "Merchant name" row: identifier-bearing names are never sent to Places
  and are refused by `enrich-merchant`.
- §1b "Raw SMS body" row: the queue is encrypted at rest once F5 lands; F1
  purge/sweep is fixed.
- §2 "Not removed": names after transfer/credit cues and greetings, e-mails,
  and 6–9 character references after a reference cue are now masked (`[NAME]`,
  `[EMAIL]`, `[REF]`). Still not removed: amounts, balances, merchants, dates,
  masked card digits, bank names, unrecognised names.
- Every Gemini request now carries `store:false`.

### 8.2 In-app wording — APPLIED (EN + AR)

Applied in `app/lib/l10n/app_en.arb` / `app_ar.arb`; `flutter gen-l10n` run.
New key `smsAutoCaptureSubtitleOnSmart` is selected in
`settings_screen.dart` (`_SmsAutoCaptureTile`) when the stored settings show
cloud AND AI consent. Final text: see the ARB files (keys
`smsDisclosureFilter`, `smsDisclosureOnDevice`, `smsDisclosureCloud`,
`smsAutoCaptureSubtitleOn`, `smsAutoCaptureSubtitleOnSmart`,
`smartConsentBullet1`, `privAiAnalysisBody`, `privCloudProcessingBody`,
`privIntro`, `smsV2PrivacyLine`, `smsShareBody`).

Not applied: `smartConsentBullet4` (Google retention/training) — it depends on
the billing tier (OWNER MUST CONFIRM, §8.6 items 1–3); the policy §7 carries
the provider detail instead. `onbCloudBullet1` / `onbAiBullet1` are unused in
`lib/features` and were left unchanged.

### 8.3 Google Play — Data safety (final draft answers)

Definitions used (Play Console Help "Provide information for Google Play's Data
safety section", answer 10787469, accessed 2026-11-12; see
`scratchpad/p4_provider_terms.md` Q5): **Collected** = transmitted off the
device (5.1); **Shared** = transferred to a third party, except a service
provider processing on the developer's behalf and instructions (5.2, 5.3);
**Processed ephemerally** = in memory only, no longer than the real-time request
(5.4); **Messages → SMS or MMS** includes sender, recipients and content (5.5);
**Financial info** types per 5.6.

Overall questions:

| Question | Answer | Basis |
|---|---|---|
| Does the app collect or share any of the required user data types? | **Yes** | below |
| Is all user data collected encrypted in transit? | **Yes** — Gemini, Places and Sentry endpoints are `https://` (`parse-sms/index.ts:49`, `ai_primary.ts:77`, `enrich-merchant/index.ts:44`); Supabase URL from build config (`supabase_config.dart`) — **OWNER MUST CONFIRM** it is `https://` in every release config | |
| Do you provide a way for users to request that their data is deleted? | **Yes** — in-app *Delete my account and all my data* (`privacy_screen.dart` → `/delete-account`), plus email to `<CONTACT_EMAIL>` (**OWNER MUST CONFIRM** the address) | |

Data types:

| Play data type | Collected | Shared | Ephemeral | Required / optional | Purposes | Code basis |
|---|---|---|---|---|---|---|
| **Messages → SMS or MMS** (sanitised SMS text; alphanumeric bank sender ID for bank-discovery) | **Yes** — sanitised text leaves the device to Qirsh's backend and Google's Gemini API | **No**, *only if* the Gemini project is on the **paid tier** (Google acts as processor under the DPA, 1.2 / 2.6). **If unpaid tier: Yes** (Google may use the content to improve its products and humans may review it, 1.1) — **OWNER MUST CONFIRM** tier | **No** — Google keeps prompts 55 days for abuse monitoring (1.4); iOS route stores text ≤ 168 h | **Optional** (RECEIVE_SMS + in-app opt-in + Smart Analysis & Cloud Sync) | App functionality | `ai_parser_client.dart:105`; `parse-sms/index.ts:484`; `bank-discovery/index.ts:230` |
| **Financial info → Purchase history** (amount, merchant, date: AI result, synced transactions; merchant name to Places) | **Yes** | **Recommended: Yes** — the merchant name goes to Google Places, which acts as an independent controller that may use and retain search terms (3.1). Legal may conclude a bare merchant name without identity is not "user data shared"; **OWNER/LEGAL MUST DECIDE** (5.7). Gemini: as SMS row | No | Optional | App functionality | `enrich-merchant/index.ts:311-322`; `features/capture/services/ledger_outbox_queue.dart` |
| **Financial info → Other financial info** (balances, masked card digits in the sanitised text; accounts and transfers in sync) | **Yes** | As SMS row (Gemini tier) | No | Optional | App functionality | as above |
| **Personal info → Name** | Only incidentally: names not recognised by the masking rules can remain in sanitised SMS text. Account name/email: per the existing data-safety draft (sign-in) | As SMS row | No | Optional | App functionality | `sms_sanitizer.dart:208-233` limits |
| **Personal info → User IDs** (account id via JWT) | Yes | No | No | **OWNER MUST CONFIRM** (existing draft: required, sign-in mandatory) | App functionality, Account management | `ai_endpoint.ts` identity |
| **Device or other IDs** (install id, device secret hash) | Yes | No | No | Optional (with cloud) | App functionality, Fraud prevention/security | `ai_endpoint.ts` device auth |
| **App info and performance → Crash logs, Diagnostics** | Yes | No (Sentry as service provider; `sendDefaultPii = false`, `sentry_lifecycle.dart:78`) | No | Optional | App functionality, Analytics | `telemetry_sanitizer.dart` |

Do **not** answer "data is anonymised" for SMS. Do **not** claim "processed
ephemerally" for SMS.

### 8.4 Permissions Declaration — RECEIVE_SMS (final draft text)

**Core functionality:** SMS-based money management — Qirsh turns the user's
incoming bank transaction SMS into a personal spending record.

> Qirsh is a personal finance app. Its core feature records the user's
> spending automatically from the bank transaction SMS they receive, so they do
> not have to type each purchase, transfer, withdrawal or deposit. The app
> requests only `RECEIVE_SMS` (no READ_SMS, SEND_SMS or MMS access) and never
> reads the existing inbox. The permission is requested only after an in-app
> prominent disclosure, and automatic capture stays off until the user also
> turns it on in Settings; it can be turned off in the app or revoked in Android
> settings at any time.
>
> Each incoming message is screened on the device; messages that do not look
> like financial transactions are discarded and never stored. Retained
> messages are stored encrypted on the device (AES-256-GCM, Android Keystore
> key) and parsed into a transaction, on the device by default, including in
> background work scheduled by WorkManager.
>
> If the user separately accepts **Smart Analysis & Cloud Sync** — an explicit,
> optional consent that is off unless accepted and is not bundled with the
> permission — a sanitised copy of each retained financial message (full card,
> account and phone numbers, IBANs, labelled one-time codes, e-mail addresses
> and reference numbers removed, and recognisable names of people masked, on
> the device and again on the server) is sent to Qirsh's backend, which
> forwards it to Google's Gemini API solely to extract the transaction for the
> user's own record. Qirsh's backend does not store the message text; it keeps
> the extracted result for at most about a day to prevent duplicate
> processing. SMS data is never sold, never used for advertising, marketing or
> profiling, and never shared for any other purpose. [OWNER MUST CONFIRM: Gemini
> paid tier — "Google processes these requests as our service provider and
> does not use them to improve its products."]

Notes for the owner: §5b's list of inaccurate statements in
`Qirsh Production/18_Android_SMS_Capture/play_declaration_draft.md` still
applies; regenerate its §3 quotes from the final ARB text (`smsDisclosure*`).
Whether off-device AI processing fits the SMS-permission exception as Google
expects it described is **OWNER MUST CONFIRM** (§6 item 11). The video/demo
steps must show: disclosure → system dialog → in-app switch → Smart Analysis
consent sheet declined (on-device) and accepted.

### 8.5 Store listing sentence (final draft)

- EN: "Optional Smart Analysis sends a sanitised copy of your bank messages to
  Qirsh's servers and Google's Gemini API to read them; it is off unless you
  accept it."
- AR: "التحليل الذكي اختياري: يُرسل نسخة مُنقّاة من رسائل البنك إلى خوادم قِرش
  وواجهة Google Gemini لقراءتها، ولا يعمل إلا إذا وافقت عليه."

### 8.6 OWNER MUST CONFIRM (before publishing the policy or attesting in Play)

1. **Gemini billing tier** of the production `GEMINI_API_KEY` project (paid tier
   with active billing = no product-improvement use, DPA applies). Decides the
   Data safety "Shared" answer and the bracketed policy §7 sentence.
2. Same for the **shadow** `GEMINI_SHADOW_API_KEY` project (may be a separate
   project/tier) — or confirm the shadow route is off in production.
3. **Logs and Datasets** setting, project creation date (before/after
   2026-10-26), any datasets shared with Google, any Contributor-tier enrolment.
   (`store:false` overrides the project setting per request once deployed.)
4. **DPA** acceptance on the billing account (Google Cloud Data Processing
   Addendum); Supabase DPA; Sentry DPA.
5. **Regions:** Supabase project region; Sentry data region; Gemini has no
   residency choice. Cross-border transfer obligations (Saudi PDPL, Egypt PDPL,
   EEA users ⇒ paid tier mandatory per Gemini terms 1.7).
6. **Retention settings:** Supabase plan (log retention 1/7/28/90 days), any
   log drains, backup/PITR window; Sentry plan retention (30/90 days).
7. **Contact email** to replace `<CONTACT_EMAIL>` (policy §9) and the Play
   deletion answer.
8. **Google Places:** whether `GOOGLE_MAPS_API_KEY` is set in production; legal
   view on storing the derived `category_key` in `merchant_keywords` (3.6) and
   on the Places "Shared" answer; Maps attribution / ToS pointer duties (3.5).
9. Production values of `GEMINI_SMS_MODEL`, `GEMINI_MODEL` and the
   `android_capture_ai_enabled` flag.
10. That the Supabase URL is `https://` in every release build config.
11. Deployment of the phase-4 backend **before or with** the app release, and
    that F5 (encryption) and cold-start background processing ship in the same
    release (§8.0).
12. `capture_rate_limits` has no TTL (removed only on account deletion) —
    accept or add a prune.
13. That `qirsh.site/privacy` is regenerated from the final policy text.
