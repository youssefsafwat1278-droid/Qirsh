# Closure round 3 — onboarding and consent (`consent`)

Model: Claude Opus 5.5, identifier `claude-opus-5-5`, as stated in this agent's system prompt by the harness that launched it. Not otherwise verified.

Working tree: `release-readiness/v1`, HEAD `b125f7af`, uncommitted. Other specialists' uncommitted edits are in the same tree.

Evidence language: the tests below are local `flutter test` runs (widget/unit). Nothing here ran on a simulator, a device, CI or a signed build.

## Summary

| Item | Status |
|---|---|
| 1 Language (3.6, V1-044) | DONE |
| 2 Countries (3.7, V1-019, UX-11 step 1) | DONE |
| 3 First-run Cloud/AI consent (3.8, 3.10, V1-017, V1-048, UX-15) | DONE — with a shared-learning consent transition (re-ask) |
| 4 Disabling (3.9, V1-017) | DONE (copy + verified gates); no new gate needed |
| 5 Privacy Policy and Terms with Cloud off (3.5, V1-007, UX-02); B14 | DONE in code; B14 is a policy change for `ops` |
| 6 Sign-in (3.11, V1-016) | NOT DONE in my files — needs a `codemagic.yaml` change owned by `ios` (below). Assessment done |

## 1. Language

- `app/lib/features/onboarding/language_screen.dart`: `_selected` is now `String?` (was `'en'`). Nothing is checked on first launch; Continue is disabled (`onPressed: null`, readable disabled colours on the brand blue) until a language is tapped. The choice is saved through `SaveLanguageUseCase` (or the `LockPromptLanguage` mirror when the signed-out scope is read-only) exactly as before. Settings → Language is unchanged and still works.
- Existing users: `InstallPresentationStore` already treats an install with data, or a marker with `requiresSetup:false`, as "language chosen", so they never see the screen and `localeProvider` keeps reading their stored language. An install still in setup from before `languageChosen` existed sees the screen with nothing preselected, **rendered in the language it was already showing** (the locale still comes from their settings) until they choose. These are pinned as characterization of preserved behaviour.
- Tests: `app/test/features/onboarding/first_language_choice_test.dart` (8). Before: with the HEAD `language_screen.dart` restored, 2 of 5 widget tests failed (English preselected, check mark shown); the 3 upgrade tests passed (preservation, not new behaviour). After: all pass.

## 2. Countries

- Generated list: `app/tool/generate_countries.swift` reads the IANA tz `iso3166.tab` (ISO 3166-1 alpha-2, public domain; `/usr/share/zoneinfo/iso3166.tab` on macOS) and takes English and Arabic names and the default currency from Unicode CLDR through Foundation. Output: `app/lib/core/i18n/countries.g.dart` (249 countries; Antarctica has no currency → `null`, falls back to USD). Regenerate with the command in the file header.
- `app/lib/core/i18n/country_catalog.dart`: `IsoCountry`, `countryByCode`, `defaultCurrencyFor`, `searchCountries` (English/Arabic names and code; ignores Arabic diacritics and hamza/taa-marbuta/alef-maqsura variants), flag from the code, and — separately — `verifiedBankCoverageCountries = {EG, SA}`, which a test keeps equal to the countries in the bundled tested bank catalog `assets/catalog/banks.json`.
- Default currency is configuration only (account default / Shortcut currency); nothing treats it as the currency of a message.
- `app/lib/features/onboarding/country_picker_sheet.dart`: searchable full list; rows show the default currency and "Tested with some banks" for EG/SA; an honest note on top.
- `setup_screen.dart` step 1: the 8 hard-coded pills (with SA preselected, UX-11) are replaced by one field "Choose your country" (nothing preselected) that opens the sheet, plus the coverage note. The base currency comes from the chosen country.
- `settings_screen.dart` (country part only): the country row names any ISO country, is tappable without the synced catalog, opens the same sheet; on change the currency follows the catalog rule as before, else the ISO default; the currency picker also offers the country's ISO default currency. Removed the now-unused `_countryValues`.
- Existing users keep their stored country and currency (nothing rewrites settings; `SaveCountryCurrencyUseCase` only runs on an explicit choice, unchanged).
- Coverage note (exact):
  - EN: "Qirsh has been tested with messages from some banks in Saudi Arabia and Egypt only, and not with every message format. In other countries, bank messages may not be recognized correctly. You can always add transactions manually."
  - AR: «اختُبر قِرش على رسائل بعض البنوك في السعودية ومصر فقط، وليس على كل صيغ الرسائل. في الدول الأخرى قد لا تُفهم رسائل البنوك بشكل صحيح. يمكنك دائمًا إضافة معاملاتك يدويًا.»
- Tests: `app/test/core/i18n/country_catalog_test.dart` (new, 6, including a diff against the maintained `iso3166.tab` when present). Updated (decided change, 3.7): `country_pill_contrast_test.dart` (now the single field: no preselection, coverage note, AA contrast, AR/EN × light/dark × 320/390 px) and `country_save_failure_test.dart` (same failure/retry/no-write assertions, choosing Egypt through the search sheet). Before: all 8 contrast tests failed against the HEAD setup screen.

## 3. First-run Cloud/AI consent

`app/lib/features/consent/smart_analysis_consent_sheet.dart` (panel used by onboarding step 2, the re-ask sheet and Privacy re-consent):
- Sections: intro, What is sent (your data; bank messages), Who receives it, Why, How sync works, Shared category learning, Turning it off, Continue locally; Privacy Policy and Terms links; then **"Agree and enable"** (filled) and **"Continue locally"** (outlined) at the **same full width and height** (UX-15 item 2). Copy order is fixed (UX-15 item 1); the Android sentence is gone on this iPhone release (UX-15 item 4); labels are centred (item 3).
- Only "Agree and enable" grants (unchanged path: `saveConsentChoice` → typed enable). After a persisted grant with AI, it records shared learning ON for that account (3.10); the keychain write does not hold up the consent completion or the registration retry, and a failed write leaves it OFF (fail closed).
- The sheet is capped at 90% of the screen height and scrolls, so the scrim stays visible and tapping it dismisses (a dismissal grants nothing). "Continue locally" persists both denials and records nothing for shared learning. Dismissal changes nothing.
- No transmission before consent: unchanged gates (`ConsentAuthority.decide` false for every class while unset/declined; `CloudEgressGate.permits()` false with no durable ON record). New tests assert it from the panel: before the tap, after opening both legal links, and after "Continue locally".

### Facts behind the text (from code, read on this tree)
- Sync classes and payloads: `core/privacy/consent_authority.dart` (`financialSync`, `profileAndSettings` incl. name/phone/date of birth, `senderBankMappings`, `smartInbox`, `gamification`, `telemetry` = notification delivery events, `diagnostics` = Sentry, `backup` = user-created encrypted backup).
- Message text: client `SmsSanitizer` (cards, accounts, phones, codes, IBAN; names after salutations/counterparty cues masked; masked last-4 kept), server `reSanitize` again before Gemini (`parse-sms`, `process-ios-sms`); Places receives the merchant name (`enrich-merchant`); unknown bank senders: sender name + sanitized text (`bank-discovery`). iOS path keeps sanitized text at most 168 h (`0111`/`0117` migrations, policy §6); Android path stores none.
- New in this round (owned by `ai`, `evidence/closure/ai.md` §4.3/4.4): the in-app request also carries the on-device reading (amount text, currency, direction) and, when one account matches, that account's currency. The text names both: "with what the app already read from it on your device and the currency of the account it matches".
- Shared learning: `domain/services/shared_category_learning.dart` sends `{merchant_key, category_key}` only; server stores an HMAC of the user id (`20261116150000_shared_merchant_category_learning.sql`); auto-approve ≥6 users and ≥75% (`20261116170000…`).

### Exact consent text — English
- Title: "Smart Analysis & Cloud Sync"
- Intro: "Qirsh works fully on this device without the cloud. If you agree, all of the following is turned on together."
- What is sent — "Your data: your transactions, accounts, cards, budgets, goals, plans, subscriptions, learned category rules, which bank each message sender belongs to, Smart Inbox items and achievements, and your profile (name, phone number, date of birth and photo) and settings are synced to your Qirsh cloud account, together with crash reports and notification delivery events. If you create an encrypted backup, it is stored there too."
- "Bank messages: bank messages you capture are sent to Qirsh servers after card, account and phone numbers and codes are removed, and with people’s names masked where the app detects them. Google Gemini may process this text, with what the app already read from it on your device and the currency of the account it matches, to identify the amount, merchant, date and type. Google Places may receive merchant names. For a bank sender Qirsh does not recognise, the sender’s name may be sent to identify the bank. Qirsh servers keep the message text only until processing finishes, at most 7 days. Amounts, merchants, balances and the last digits of cards remain, so it is not anonymous."
- Who receives it — "Qirsh servers, hosted by Supabase; Google (the Gemini API and the Places API); and Sentry, for crash reports. Supabase, Gemini and Sentry process data on Qirsh’s behalf."
- Why — "To read your bank messages more accurately, to keep your data in sync across your devices and restorable after you reinstall, and to fix crashes."
- How sync works — "After you agree, sync and message analysis run automatically, including retries and background processing when your phone allows it. Agreeing on this device does not turn them on for your other devices."
- Shared category learning — "Shared category learning is included. When you choose “Remember for this merchant”, Qirsh sends that merchant’s name and the category you chose, linked to a one-way code instead of your account ID. Amounts, dates, messages, transfers and names of people are never sent. A choice is added to the categories everyone receives when at least 6 users agree on it and they are a clear majority (75%), or after an admin reviews it. You can turn shared learning off on its own in Settings → Privacy."
- Turning it off — "You can turn Cloud Sync and Smart Analysis off together at any time in Settings → Privacy. Sending then stops, including retries and new shared-learning contributions. Anything already sent cannot be recalled, and data already in your Qirsh account stays there until you delete your account."
- "Continue locally: everything stays on this device. Nothing above is sent, messages are read on the device only, and there is no cloud sync or cloud backup."
- Links: "Privacy policy", "Terms & conditions". Buttons: "Agree and enable", "Continue locally".

### Exact consent text — Arabic
- العنوان: «التحليل الذكي والمزامنة السحابية»
- «يعمل قِرش بالكامل على هذا الجهاز دون السحابة. إذا وافقت، يُفعَّل كل ما يلي معًا.»
- ما الذي يُرسَل — «بياناتك: تتم مزامنة معاملاتك وحساباتك وبطاقاتك وميزانياتك وأهدافك وخططك واشتراكاتك وقواعد التصنيف التي تعلّمها التطبيق، والبنك الذي ينتمي إليه كل مرسِل رسائل، وعناصر صندوق الوارد الذكي وإنجازاتك، وملفك الشخصي (الاسم ورقم الهاتف وتاريخ الميلاد والصورة) وإعداداتك، مع حسابك السحابي على قِرش، إضافةً إلى تقارير الأعطال وأحداث توصيل الإشعارات. وإذا أنشأت نسخة احتياطية مشفّرة فإنها تُحفظ هناك أيضًا.»
- «رسائل البنوك: تُرسل رسائل البنوك التي تلتقطها إلى خوادم قرش بعد إزالة أرقام البطاقات والحسابات والهواتف والرموز، مع إخفاء أسماء الأشخاص حين يتعرّف عليها التطبيق. قد تعالج خدمة Google Gemini هذا النص، مع ما قرأه التطبيق منه على جهازك وعملة الحساب المطابق لها، لتحديد المبلغ والتاجر والتاريخ ونوع العملية، وقد تتلقى Google Places أسماء التجار. وإذا لم يتعرّف قِرش على البنك المرسِل فقد يُرسَل اسم المرسِل لتحديد البنك. تحتفظ خوادم قرش بنص الرسالة حتى تنتهي معالجتها، و7 أيام كحد أقصى. تبقى فيه المبالغ والتجار والأرصدة وآخر أرقام البطاقات، لذا فهو ليس مجهول الهوية.»
- من يتلقاها — «خوادم قِرش المستضافة لدى Supabase، وGoogle (خدمتا Gemini API وPlaces API)، وSentry لتقارير الأعطال. تعالج Supabase وGemini وSentry البيانات نيابةً عن قِرش.»
- لماذا — «لقراءة رسائل البنوك بدقة أكبر، ولإبقاء بياناتك متزامنة بين أجهزتك وقابلة للاستعادة بعد إعادة التثبيت، ولإصلاح الأعطال.»
- كيف تعمل المزامنة — «بعد الموافقة، تعمل المزامنة وتحليل الرسائل تلقائيًا، بما في ذلك إعادة المحاولة والمعالجة في الخلفية عندما يسمح هاتفك بذلك. الموافقة على هذا الجهاز لا تفعّلهما على أجهزتك الأخرى.»
- التعلّم المشترك للتصنيفات — «التعلّم المشترك للتصنيفات مشمول. عندما تختار «تذكّر التصنيف لهذا المتجر» يرسل قِرش اسم المتجر والتصنيف الذي اخترته، مربوطين برمز أحادي الاتجاه بدلًا من معرّف حسابك. لا تُرسَل أبدًا المبالغ أو التواريخ أو الرسائل أو التحويلات أو أسماء الأشخاص. ويُضاف الاختيار إلى التصنيفات التي يتلقاها الجميع عندما يتفق عليه 6 مستخدمين على الأقل ويكونون أغلبية واضحة (75%)، أو بعد مراجعة مشرف. يمكنك إيقاف التعلّم المشترك وحده من الإعدادات ← الخصوصية.»
- الإيقاف — «يمكنك إيقاف المزامنة السحابية والتحليل الذكي معًا في أي وقت من الإعدادات ← الخصوصية. يتوقف الإرسال عندها، بما في ذلك إعادة المحاولة ومساهمات التعلّم المشترك الجديدة. لا يمكن استرجاع ما أُرسل بالفعل، وتبقى البيانات الموجودة في حسابك على قِرش حتى تحذف حسابك.»
- «المتابعة محليًا: يبقى كل شيء على هذا الجهاز. لا يُرسَل شيء مما سبق، وتُقرأ الرسائل على الجهاز فقط، ولا توجد مزامنة سحابية أو نسخ احتياطي سحابي.»
- الروابط: «سياسة الخصوصية»، «الشروط والأحكام». الأزرار: «أوافق وفعّل»، «المتابعة محليًا».

### Consent transition for shared learning (finding)
- There is **no consent version** anywhere (no field, key or table). The in-app consent existing users accepted (build 147 copy, `smartConsentBullet1-3` at HEAD) **never mentioned shared learning**; the only disclosures were policy §3/§4 (added 2026-11-12/16) and a just-in-time hint in the category sheets. Yet `SharedLearningPreference.isOn` treated a missing key as ON, so every consenting user contributed by default. Apple 5.1.2(ii) (fetched 2026-11-17 from developer.apple.com/app-store/review/guidelines): "Data collected for one purpose may not be repurposed without further consent unless otherwise explicitly permitted by law."
- Change (`core/privacy/shared_learning_preference.dart`): a missing key is now OFF and unanswered (`isAnswered`). ON is written only by "Agree and enable", by the one-time question, or by the Privacy switch.
- Re-ask (`maybeReaskConsent` → `_maybeAskSharedLearning`, run by the existing shell trigger on start/resume): an account with Cloud AND AI accepted and no recorded shared-learning choice sees "Shared category learning" with "Agree and include" / "Keep it off" (equal size). Answers are recorded per account on this device; a dismissal records nothing (asked again). Cloud/AI choices are not touched.
  - EN: title "Shared category learning"; body "Smart Analysis & Cloud Sync now includes shared category learning. You turned it on before this was part of the choice, so shared learning stays off unless you agree now. Your other settings do not change." followed by the shared-learning and turning-off paragraphs above.
  - AR: «التعلّم المشترك للتصنيفات»؛ «أصبح التحليل الذكي والمزامنة السحابية يشمل التعلّم المشترك للتصنيفات. لقد فعّلته قبل أن يصبح جزءًا من هذا الاختيار، لذا يبقى التعلّم المشترك متوقفًا ما لم توافق الآن. لن تتغير إعداداتك الأخرى.» ثم فقرتا التعلّم المشترك والإيقاف أعلاه. الأزرار: «أوافق وأدرِجه»، «أبقِه متوقفًا».
- Effect on upgraders: a build-147 user who never touched the switch stops contributing after the update until they agree. Contributions already made stay on the server (withdrawn per rule or on account deletion, as before).
- Privacy switch text changed from "On by default; …" to "Included when you agree to Cloud Sync and Smart Analysis; you can turn it off at any time. …" (AR: «يُفعَّل عند موافقتك على المزامنة السحابية والتحليل الذكي، ويمكنك إيقافه في أي وقت. …»).

### Platform/legal check (3.8/3.10)
Fetched current App Review Guidelines. 5.1.2(i) requires clearly disclosing sharing "including with third-party AI" and "explicit permission" — met by naming Google Gemini and the affirmative button. 5.1.1(iv) forbids forcing consent to unnecessary access and asks for alternatives — "Continue locally" keeps the app usable and shared learning has its own off switch. I found no concrete guideline text forbidding one combined consent for Cloud, AI and shared learning, so I did not change the mechanism. Not assessed: GDPR "granular consent" for EU users (no legal source was checked; this is for counsel if the app is offered in the EU — all countries are now selectable).

Tests: `app/test/features/consent/first_run_consent_screen_test.dart` (6), `app/test/features/consent/shared_learning_transition_test.dart` (8), `app/test/l10n/consent_disclosure_copy_test.dart` (4). Before (HEAD sheet + HEAD preference restored): 11 of the 14 widget tests failed; the 3 that passed are "not asked when consent is off/partial" and "explicit earlier choice kept" — preservation checks.

## 4. Disabling

- Code path unchanged (it already turned both off together: `privacy_screen.dart _withdrawConsent` with `ConsentChoices(cloud: declined, ai: declined)` and the restrictive disable protocol). Gates verified by reading and by existing tests: every egress class reads consent fresh (`ConsentAuthority.allows`), AI needs both, the durable `CloudEgressGate` freezes during OFF; the shared-learning client re-checks opt-in AND `aiProcessing` before each send and drops its queue on refusal (`shared_category_learning_client_test.dart`, run green). Dispatch-time re-checks in the capture pipeline are `ai`'s (their report §4.7).
- Copy (V1-017): withdrawal dialog body and button changed.
  - EN: "Cloud Sync and Smart Analysis turn off together. Qirsh stops sending from this device, including sync, message analysis, retries and new shared-learning contributions. Anything already sent cannot be recalled, and data already in your Qirsh account stays there until you delete your account. Your data stays on this device, and you can turn both on again here at any time." Button "Turn off both".
  - AR: «تتوقف المزامنة السحابية والتحليل الذكي معًا. يتوقف قِرش عن الإرسال من هذا الجهاز، بما في ذلك المزامنة وتحليل الرسائل وإعادة المحاولة ومساهمات التعلّم المشترك الجديدة. لا يمكن استرجاع ما أُرسل بالفعل، وتبقى البيانات الموجودة في حسابك على قِرش حتى تحذف حسابك. تبقى بياناتك على هذا الجهاز، ويمكنك تفعيلهما مجددًا من هنا في أي وقت.» الزر «إيقافهما معًا».
- The old "withdraw either permission" sentence is gone (copy test pins its absence). No automatic activation was added anywhere; the only writers of ON remain the explicit disclosure actions.

## 5. Privacy Policy and Terms with Cloud off; B14

- `core/privacy/gated_url_launcher.dart`: `isLegalDocumentUrl` (exactly `kPrivacyPolicyUrl` or `kTermsUrl`, https, whole-URL equality: no other path/query/fragment/port/userinfo/host) and `launchLegalDocument` (in-app Safari view, `LaunchMode.inAppBrowserView`), without the Cloud gate. `launchExternalUrl` and `CloudEgressGate.mayLaunchExternal` are unchanged.
- Reachable from: the consent panel (onboarding and sheets), the sign-in screen under the terms notice (UX-02; `auth_screen.dart`, new `features/consent/legal_links.dart`), and Settings → Privacy (now via `launchLegalDocument`).
- Opening sends no message or account data (constant URLs) and enables nothing. The legal site receives an ordinary browser page request (IP address, user agent) — `ops`: the policy should say so.
- Tests: `app/test/core/privacy/legal_document_access_test.dart` (3): exact allowlist and 12 near-miss URLs refused; with a never-consented/unresolved gate the two documents open and nothing else does; `launchExternalUrl` still refuses the same URLs; the gate still denies and every egress class stays denied afterwards. Before: compile failure (no API) and, at HEAD, `launchExternalUrl` returned false with Cloud off (the defect, SEC-02).
- B14 (catalog/force-update with Cloud off): decided minimally — **no catalog egress widening**. Truthful state: with Smart Analysis & Cloud Sync off (or never answered) no catalog, flag, announcement or force-update request is made; the app uses its bundled catalog; Cloud-off users get no remote force-update notice or flag change. `ops` must correct privacy policy §3 "Always allowed, and why" item 1, which says catalog updates and the force-update notice are ungated and anonymous.

## 6. Sign-in (assessment; change needed in `codemagic.yaml`, owned by `ios`)

- Build 147 came from `ios-signed`, whose `vars` set `QIRSH_GOOGLE_AUTH_ENABLED`, `QIRSH_EMAIL_AUTH_ENABLED`, `QIRSH_ALTERNATE_SIGNUP_ENABLED` to `"true"`. The store workflow `ios-signed-release` (and the unsigned sideload) have **no** such `vars` and pass `${QIRSH_GOOGLE_AUTH_ENABLED:-false}` / `${QIRSH_EMAIL_AUTH_ENABLED:-false}`; `AuthMethodsConfig` reads them with `bool.fromEnvironment`. Unless the Codemagic UI group sets them (not visible from the repository), a store build shows **Apple only**. A Google-only user or an email-code user whose address is not their Apple ID email could then not sign back in after sign-out, reinstall or session expiry. Existing sessions on an upgraded device are not affected (refresh does not need the button).
- Required change (for `ios`), in `ios-signed-release` → `environment`:
  ```yaml
      vars:
        QIRSH_GOOGLE_AUTH_ENABLED: "true"
        QIRSH_EMAIL_AUTH_ENABLED: "true"
        QIRSH_ALTERNATE_SIGNUP_ENABLED: "true"
  ```
  (keep any existing vars), and a contract test in `supabase/tests/codemagic_ios_store_pipeline_contract_test.mjs` pinning these three equal between `ios-signed` and `ios-signed-release`. `GOOGLE_SERVER_CLIENT_ID` already comes from the `supabase` group in both.
- Apple sign-in is always shown on iOS (`appleSignInSupported`), so Guideline 4.8 holds with Google on.
- No reviewer backdoor was added. Reviewer access: feasible with Sign in with Apple using the reviewer's own Apple ID (a new, empty account). Guideline 2.1 asks to "include demo account info ... if your app includes a login"; there is no password sign-in and email sign-in needs a code sent to the inbox, so no static demo credential exists. Reviewer notes must say: sign in with Apple (any Apple ID) creates an account; the account starts empty; how to add sample transactions (paste the sample bank messages in the notes); Smart Analysis & Cloud Sync is optional and both choices work; Privacy Policy and Terms are on the sign-in screen. This is a review-risk, not a code blocker; I found no concrete blocker.

## Existing tests whose expectations changed (decided behaviour)
- `test/features/onboarding/country_pill_contrast_test.dart` — 8 fixed pills → one field over the full ISO list (3.7); contrast assertion kept (AA ≥ 4.5).
- `test/features/onboarding/country_save_failure_test.dart` — Egypt is chosen through the search sheet; every failure/retry/no-write assertion kept.
- `test/data/catalog/shared_category_learning_client_test.dart` — "ON by default" → unset is OFF (3.10 transition); "still needs Cloud and AI" now uses a recorded ON; per-account test records uid-b ON explicitly.
- `test/features/settings/privacy_consent_management_test.dart` — the switch shows OFF when unanswered (new test); the toggle test starts from a recorded ON.
- `test/l10n/privacy_copy_test.dart` — the shared-learning body's first sentence ("On by default") changed to the decided wording.
- `test/features/settings/privacy_consent_management_test.dart` "explained, and ON by default" → "explained, and ON once chosen" (records ON first; 3.10).
- `test/features/onboarding/setup_consent_step_test.dart` — the country is chosen through the field → search → `country-EG` (3.7); all consent/account assertions kept.
- Mechanical, no assertion changed: `ensureVisible` + `pump` before tapping the consent/transition buttons (the disclosure is longer and the sheet scrolls) in enable_cloud_outcome_ui, privacy_consent_management, consent_recovery_real_service, smart_analysis_consent_sheet, cloud_resume_banner, consent_lifetime, consent_reask, no_combined_grant, setup_consent_step, shared_learning_transition and tool/visual_parity/extended_surfaces tests.

## Commands and results
All from `app/`, prefixed `PUB_CACHE=$HOME/.pub-cache`.
- `flutter gen-l10n` — ok (after every ARB change).
- `flutter analyze --no-pub` on every touched lib and test file/dir (onboarding, consent, settings tests, core/i18n, core/privacy launcher+preference, l10n tests, shared-learning client test, visual-parity test) — **No issues found**.
- Final batch `flutter test --no-pub -j 2 test/features/consent test/features/onboarding test/core/i18n test/core/privacy test/l10n test/data/catalog/shared_category_learning_client_test.dart test/architecture test/features/ads/astra_h2_sdk_gating_test.dart` + 8 settings files (privacy_consent_management, language_selector, settings_screen, consent_status, privacy_controls_contrast, privacy_registration_status, privacy_stale_switch, consent_pending_provenance) — **1429 passed, 1 skipped, 2 failed**; both failures are outside this work:
  - `architecture/destructive_path_inventory_test.dart`: `lib/core/backup/restore_backup_usecase.dart` gained destructive statements (18 > 12) — `data`'s file.
  - `architecture/head_completeness_test.dart`: committed code imports untracked `supabase/functions/_shared/ai_understanding.ts` and `process-ios-sms/message_meaning.ts` — `ai`/`parser` new files; resolves when the orchestrator commits them.
- Separately green: enable_cloud_outcome_ui, consent_recovery_real_service, tool/visual_parity/extended_surfaces, setup_consent_step, shared_learning_transition, first_run_consent_screen, consent copy tests (124 passed in that run).
- Known unrelated: `settings/privacy_screen_deletion_test.dart` 3 failures (see item 4 under files I do not own).
- Before-proofs: language 2 of 5 widget tests fail on HEAD; consent/legal/country 19 fail on HEAD files, 5 preservation tests pass on HEAD (details in sections 1–5).

## Compatibility
- Stored data: language, country, currency and Cloud/AI consent are read as before; nothing is rewritten. Shared-learning keys `on`/`off` keep their meaning; only a missing key changes (ON → OFF, asked once).
- Build 147 against a new backend: nothing in this work changes a server contract.
- New build against the old backend: no new endpoint; the legal links go to the static legal site, not Supabase.
- Cloud modes: unset/declined → no egress, legal documents open; accepted both → shared learning asked once if unanswered; partial (cloud only) → not asked, no contribution (AI required).

## Not verified
- No simulator/device run of the new screens (RTL layout and large text checked only in widget tests at 320/390/800 px widths); VoiceOver reading of the links/headings not checked on a device. Would verify: MDT walk on an iPhone in AR and EN with largest text.
- `inAppBrowserView` on iOS (SFSafariViewController) not exercised outside the platform mock.
- Codemagic UI variable values for `ios-signed-release` (not visible to me).

## Changes needed in files I do not own
1. `codemagic.yaml` (`ios`): the `vars` above for `ios-signed-release`, plus the contract test.
2. `docs/legal/PRIVACY_POLICY.md` (`ops`): §3 "Always allowed" item 1 (catalog/force-update are NOT fetched with Cloud off); §3/§4 shared learning is "included when you agree", not "on by default", and existing consenting users are asked; §4 consent is combined and withdrawal is combined; the legal-site page request with Cloud off; §3 the AI request may include the on-device reading and the matched account's currency; §5 still says 30-day deletion (decision 3.4, not mine).
3. `app/lib/features/settings/settings_providers.dart` (comment only, `sharedLearningActiveProvider`): "(on by default)" is now wrong; behaviour is correct.
4. `privacy_screen_deletion_test.dart` (3 tests) fails on this tree because another specialist removed the `privCancelDeletion` ARB key / pending-deletion card (decision 3.4); not caused by this work, not touched.

## Open
- None in my scope beyond "Not verified" and the changes listed for other owners.

## Owner actions
- Confirm the Codemagic UI values (or approve the `ios` change) so the store build keeps Apple, Google and email-code sign-in.
- Approve the privacy-policy changes listed for `ops` before the store build ships with this consent text.

## Follow-up: country default currency vs storable money (orchestrator request)

**Finding.** Stored money supports only the codes in `kCurrencyScale` (`app/lib/domain/finance/currency_scale.dart`): **50 currencies** (I count 50 keys, not 51; a test now pins 50). With the 249-country catalog, choosing any of **128 countries** saved an ISO currency that `Money` rejects (`UnsupportedCurrencyException`), e.g. NO→NOK, CA→CAD, CN→CNY. I proved this before the fix with a throwaway test (`Money.parse('1', defaultCurrencyFor(code))` failed for 128 countries). Antarctica (no currency) fell back to USD without asking.

**Decision: do not extend `kCurrencyScale`; ask the user to choose explicitly.** Extending is unsafe in this round:
- `engine/proof/evidence.dart` builds its **case-insensitive** ISO-literal currency regex from `kCurrencyScale`. Codes such as `ALL`, `TOP`, `CUP`, `MOP`, `PEN`, `BOB` and `CAD` would then match ordinary words in bank messages and anchor amounts to false currencies.
- That regex is hashed into the Phase-4 seal.
- `parser_validation.ts`, `ai_candidate_validator.ts` and `ai_currency_table_drift_test.ts` are all drift-tested against the table.

Adding about 100 codes would be a parser change, not a consent change. **Validators: none need to change, because `kCurrencyScale` is unchanged.**

**Change.**
- `core/i18n/country_catalog.dart`: `defaultCurrencyFor(code)` now returns the ISO currency only when it is storable (`isSupportedCurrency`), otherwise null. New `storableCurrencies` (sorted `kCurrencyScale` keys). `fallbackCurrency` removed.
- `features/onboarding/country_picker_sheet.dart`:
  - New `currencyForCountry(context, country)` returns the storable default when there is one. Otherwise it shows `CurrencyChoiceSheet`, which lists only the 50 storable currencies. Dismissing it returns null, and nothing is saved.
  - In the picker, a country without a storable currency shows "You choose the currency next" instead of an unstorable code.
- `setup_screen.dart` (onboarding) and `settings_screen.dart` (country tile): both go through `currencyForCountry`.
- Settings now only offers catalog currencies that can be stored, in both the country default and the currency picker. If none can, it falls back to the storable set.
- Text (EN / AR):
  - Title: "Choose your currency" / «اختر عملتك»
  - Unsupported currency: "Qirsh can’t record amounts in {currency} yet. Choose the currency you want to track your money in. You can change it later in Settings." / «لا يستطيع قِرش تسجيل المبالغ بعملة {currency} حتى الآن. اختر العملة التي تريد متابعة أموالك بها، ويمكنك تغييرها لاحقًا من الإعدادات.»
  - No currency: "This place has no currency of its own. …" / «ليس لهذه المنطقة عملة خاصة بها. …»
  - Picker subtitle: "You choose the currency next" / «تختار العملة في الخطوة التالية»

**Result.**
- 120 countries save their own currency directly.
- **129 countries require an explicit choice** from the 50: the 128 below plus AQ, which has no currency.
- The 128: AF AG AI AL AM AO AR AU AW AZ BA BB BI BM BN BO BR BS BT BV BW BY BZ CA CC CD CH CK CN CO CR CU CV CW CX CZ DK DM DO ER FJ FK FO GD GE GI GL GM GT GY HK HM HN HT HU IR JM KG KH KI KN KP KY KZ LA LC LI LK LR MD MG MK MM MN MO MS MU MV MW MX MZ NA NC NF NI NO NP NR NU NZ PA PE PF PG PL PN RO RS RU SB SC SE SH SJ SL SR SS ST SX SZ TH TJ TK TM TO TT TV TW UA UY UZ VC VE VU WF WS ZM ZW.
- Exact pairs are in the test's source of truth (`countries.g.dart` against `kCurrencyScale`).

**Tests.**
- `app/test/core/i18n/country_currency_storage_test.dart` (4 tests):
  - Every country's default is storable or null.
  - The choice list is exactly the 50 storable codes.
  - A country has no default exactly when its ISO currency is not storable.
  - End to end on an in-memory encrypted Drift DB: for **all 249 countries** (default, or the first offered choice) and for **each of the 50 choices**, it creates an account and saves a manual transaction (`SaveManualTransactionUseCase`) without throwing.
- `app/test/features/onboarding/country_currency_choice_test.dart` (8 tests):
  - Onboarding, EN and AR: Norway shows the honest text, does not offer NOK, and saves (NO, EUR).
  - Onboarding: dismissing saves nothing; Antarctica asks; Egypt saves EGP without asking.
  - Settings: Norway asks and saves the choice; dismissing saves nothing; Kuwait saves KWD.
- Changed expectation (decided): `country_catalog_test` now expects `defaultCurrencyFor('AQ')` to be null (it was USD).
- Run: `test/core/i18n test/features/onboarding settings_screen_test language_selector_test test/l10n` gave 223 passed. `flutter analyze --no-pub` on the touched files gave no issues. `gen-l10n` ran.

## Follow-up: strict-gate failures on `7cab5e8b`

1. **`app/test/features/transactions/smart_inbox_card_test.dart`** ("Enable opens disclosed choices without granting consent, and dismissal changes nothing").
   - Cause: my consent change. The test looked for the old affirmative label "Accept cloud sync and smart analysis". Owner decision **3.8** renamed it to "Agree and enable".
   - Not a regression: the sheet opens, nothing is granted, and dismissal changes nothing. The 90% height cap and the shared-learning prompt played no part.
   - Change: the label in its two `find.text` checks (present while open, absent after dismissal) is now "Agree and enable". Every other assertion is unchanged.
2. **`app/test/features/app/smart_inbox_status_cycle_test.dart`** (the 11 "actual mounted status/engagement …" cases, synthetic-define stage).
   - Cause: `ios`'s ads gating (decision **3.2**, Version 1 has no advertising), not my work and not `a11y`'s.
   - In `640562f6`, `UmpAdConsentService.canRequestAds()` returns false and makes no UMP call unless the build sets `QIRSH_ADS_ENABLED` (`AdMobBuildConfig.adsCompiledIn`). The test still expected `UserMessagingPlatform#loadAndShowConsentFormIfRequired` in the non-notification scenarios.
   - Not a regression: no UMP call is the decided Version 1 behaviour.
   - Change: one line. The expectation is now `expect(umpMethods, isEmpty)` in every scenario, with a comment citing 3.2. The `unknownUmpMethods` check and all sync assertions are unchanged.
   - Pipeline coverage with ads enabled stays in `ios`'s ad tests, which use `debugAdsCompiledInOverride`.

No product code was changed for either failure.

**Runs** (from `app/`, `PUB_CACHE=$HOME/.pub-cache`):
- `flutter test --no-pub -j 2 test/features/app test/features/transactions test/features/consent test/features/onboarding`: **559 passed, 1 skipped, 0 failed**.
- Synthetic-define stage, run exactly as in `tools/ci_gates.sh`: the 5 files with the three defines and `--concurrency=1` gave **91 passed, 12 skipped, 0 failed**. The group command (`bootstrap_remove_data_integration_test.dart --plain-name 'configured real sender bootstrap receivers'`) gave **0 failed, 10 skipped**, the same as the existing gate; I did not touch it.
- `flutter analyze --no-pub` on both test files: no issues.
