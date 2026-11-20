# Qirsh — Privacy Policy

**Last updated: 2026-11-21**

Qirsh (قِرش) is a personal finance app that reads bank SMS on your device and
turns them into a private record of your spending.

Qirsh is currently available for iPhone. The Android app has not been released
yet; the parts of this policy marked Android describe how it behaves once it is.

You can choose any country in the app. Choosing a country does not mean Qirsh
can read every bank's messages there: it has been tested with messages from some
banks in Saudi Arabia and Egypt only, and not with every message format.

This policy describes what the app actually does. It was written after the
privacy behaviour was audited and corrected, not before — several statements
that used to be aspirational are now enforced in code and covered by tests.

---

## 1. The short version

- **Your financial data lives on your device**, in a database encrypted with a
  key held in the device keychain. Bank messages waiting to be processed are
  also stored encrypted on your device.
- **Cloud sync and AI are off by default, and nothing is sent until you
  agree.** On first use Qirsh asks you to choose **"Agree and enable"** (turns
  on **Smart Analysis & Cloud Sync**) or **"Continue locally"**. Until you
  agree, no financial data leaves your device, and no bank message either —
  this is enforced at every network call, not only in the settings screen.
- **The model that categorises your spending runs entirely on your device**, with
  no network access at all. Separately, if you accept **Smart Analysis & Cloud
  Sync** — one choice, which turns on both cloud processing and AI assistance
  together, with shared category learning included — a sanitized copy of a bank message may be sent to
  our servers and to Google's Gemini API to help read it. The sanitized text is
  still personal financial information; **it is not anonymous**.
- **Turning it off turns both off.** One action stops cloud sync and AI message
  reading together. Anything already sent cannot be recalled.
- **On iPhone, Smart Analysis can also be on by itself**, without Cloud Sync
  (section 4). Then only the sanitized text of the bank messages you capture is
  sent for reading — no transactions, accounts or other data.
- **No advertising.** This version of Qirsh shows no ads (section 7).
- **We do not sell your data.** There is no advertising profile built from your
  transactions.

---

## 2. What is processed on your device only

The following never leave your device unless you accept Smart Analysis & Cloud
Sync:

| Data | Why |
|---|---|
| Bank SMS text, and messages you share or paste | To extract the amount, merchant, date and account |
| Transactions, accounts, cards, balances | The core function of the app |
| Budgets, goals, subscriptions, plans | Planning features |
| Merchant→category learning | So your corrections apply to future transactions |

The local database is encrypted (SQLCipher). The encryption key is stored in the
iOS Keychain / Android Keystore and is not transmitted. Bank messages that are
waiting to be processed are kept in a separate on-device queue that is also
encrypted (AES-256-GCM, with a key held in the iOS Keychain / Android Keystore).
On Android, this storage is excluded from device backups and device-to-device
transfer.

### Background processing

Qirsh may process captured messages in the background — including after the app
was closed or the phone restarted — using the operating system's scheduler
(WorkManager on Android, background tasks on iOS). Background processing applies
exactly the same checks as the app in the foreground: your consent is read again
before anything is sent, a message is only processed for the account it was
captured under, and with Smart Analysis & Cloud Sync off it is read on your
device only.

### On-device AI

Qirsh includes a merchant-understanding and category-prediction model. It runs
**entirely on your device** as part of the app, with **no network access at all**:

- it is not a cloud service, and there is no API key or provider behind it;
- no message text, merchant name or transaction is sent anywhere for it to work;
- it learns from **your corrections**, on your device, and that learning is never
  uploaded.

Because there is no network path, this holds regardless of your consent settings.
We disclose it here because it is a real model making real suggestions — not
because it transmits anything. It is different from the optional message
reading by Google's Gemini API described in section 8.

---

## 3. What is sent to the cloud, and only with your consent

Cloud features are **off until you choose "Agree and enable"**. The gate is
checked at the moment of sending — turning consent off stops transmission
immediately, not at the next app start.

| Category | Sent when enabled | Purpose |
|---|---|---|
| Financial sync | Accounts, transactions, budgets, goals, plans | Multi-device sync |
| Learned merchant rules | Each "Remember for this merchant" rule: the merchant name and the category you chose | Restore your rules on a new device or after reinstalling |
| Profile photo | The profile picture you chose in Qirsh, stored privately so only your account can read it | Restore your photo on a new device or after reinstalling |
| Encrypted backup | An encrypted archive of your data | Restore after device loss |
| Message reading (Smart Analysis) | Sanitized bank-message text (see section 8) | Read the amount, merchant, date and type |
| Bank identification | For a bank sender we do not recognise: the sender's name (letters, such as a bank's name; never a phone number) and the sanitized text | Identify which bank sent it |
| Merchant lookup | A merchant name we cannot categorise | Find the merchant's category |
| Bank mappings | Which bank a sender ID belongs to | Improve parsing for everyone |
| Shared category learning (**included** in Smart Analysis & Cloud Sync; you can turn it off on its own) | When you choose "Remember for this merchant": the merchant name and the category only, with a one-way code in place of your account ID. The one-way code is derived from your account, so it is a pseudonym, not anonymity. Never amounts, dates, messages, transfers, wallet movements, or anything that looks like a person's name or contains numbers | Improve categories for everyone (see section 4) |
| Smart Inbox | Messages awaiting your confirmation | Review across devices |
| Gamification | Achievement progress | Cross-device streaks |
| Telemetry | Notification delivery/open events, linked to your account | Reliability of capture |
| App updates (catalog) | Your app version and country, sent with your sign-in session | Parser-rule updates, feature switches, and notices that an update is required |
| Messages from us | Nothing extra: a notification we send reaches devices with Cloud Sync on whose "Qirsh messages and tips" notifications are on; we record whether it was delivered, against a one-way code of the install | Product news and announcements |
| Diagnostics | Crash reports | Fixing crashes |

**Diagnostics fail closed:** when cloud/privacy consent is off, crash reporting
does not transmit — the report is dropped before it is assembled, not merely
scrubbed.

### What happens with Smart Analysis & Cloud Sync off

- **No catalog updates.** Qirsh does not contact our servers for parser-rule
  updates, feature switches or update notices. It keeps using the rules built
  into the installed app, and **you will not see an in-app notice that an update
  is required** — keep the app updated from the App Store.
- **Sign-in** happens only when you choose to sign in (and your session is kept
  fresh while you stay signed in). It sends nothing about your finances.
- **Opening the Privacy Policy or Terms** opens our website (qirsh.site) in an
  in-app browser view, also before you have made a choice. That is an ordinary
  web page request, so our web host receives what any website receives (your
  IP address and browser details). It sends nothing about your finances or
  messages and does not turn Smart Analysis & Cloud Sync on.

---

## 4. Consent, and how it behaves

- Consent is **off until you agree**. Nothing about your finances is uploaded
  until you choose "Agree and enable". "Continue locally" keeps everything on
  your device; you can turn it on later in Settings → Privacy.
- **Smart Analysis & Cloud Sync is one choice.** Accepting it turns on cloud
  sync, AI message reading and shared category learning together.
- **Turning it off turns both off.** Settings → Privacy → Turn off → "Turn off
  both" stops cloud sync and AI message reading together, including retries,
  background work and new shared-learning contributions. The check is performed
  at each transmission. **A request that was already sent cannot be recalled.**
- **Smart Analysis on its own (iPhone).** You can turn on Smart Analysis without
  Cloud Sync — from its own consent screen ("Allow" / "Not now") or Settings →
  Privacy → Smart Analysis. Then the sanitized text of each bank message you
  capture is sent to our servers and to Google's Gemini API to read it (section
  8). No merchant is looked up with Google Places in this mode (section 7).
  Nothing else is uploaded: no transactions, accounts, budgets, backups or
  shared-learning contributions. With "Not now" nothing is sent, and your
  messages wait on your device in the analysis log, where you can record them
  yourself. Turning Smart Analysis off stops sending at once; nothing already
  recorded is deleted, and a message already sent cannot be recalled.
- **Shared category learning is part of that consent.** When you agree, it is
  included; you can still turn shared learning off on its own in Privacy, and
  the choice is kept for your account on that device. If you agreed to Smart
  Analysis & Cloud Sync in an earlier version, before shared learning was part
  of it, shared learning stays off unless you agree when the app asks. Choices
  are pooled: a merchant→category pair is added to the categories everyone
  receives only when at least 6 users agree and they are a clear majority
  (75%), or after an admin reviews it, and an admin can remove it at any time.
  Turning it off stops future contributions; deleting a learned rule while it is
  on withdraws that rule's contribution; deleting your account deletes all the
  contributions you made.
- **Across devices, the more restrictive setting wins.** Turning consent OFF on
  one device propagates as a revocation. Turning it ON does **not** silently
  grant consent on your other devices — you grant it on each device yourself.

---

## 5. Deleting your data

These are separate actions, deliberately:

### Stop uploading (revoke consent)
Settings → Privacy & data → turn off Smart Analysis & Cloud Sync. Transmission
stops immediately. **Data already in the cloud is not deleted** —
revoking consent is not a deletion request, and treating it as one would destroy
your backup the moment you paused syncing.

### Delete data from your device
Settings → Sign out → Remove data. This permanently deletes the account's data
on this device, including bank messages still waiting to be processed, and turns
automatic SMS capture off. Data already saved to the cloud is not affected and
can be downloaded again by signing in.

### Delete your account entirely
Settings → Privacy & data → Delete my account and all my data. After you confirm
your identity (with Apple, or with a one-time code sent to your account's
email), deletion starts at once and **is final — there is no undo period**. Your
account and your cloud data (transactions, goals, budgets, backups, your profile
photo, your shared-learning contributions, and the capture and AI records
described in section 6) are deleted. Some server steps run in the background and
can take a few minutes to finish; the app shows when deletion is complete.

A deletion request made in an earlier version of Qirsh, which scheduled deletion
after 30 days, will not be carried out; the app tells you so and you can delete
your account with the action above.

If you cannot access the app, email the address in §9 from the address on the
account and we will action the deletion.

---

## 6. Retention

| Data | Retained |
|---|---|
| Local data | Until you delete it or uninstall the app |
| Bank messages waiting on your device | Encrypted, until processed or until you remove data / delete your account |
| Cloud financial data (transactions, accounts, budgets) | **No fixed expiry** — kept until you delete it or delete your account |
| Android: message text sent for reading | **Not stored** in our database. We keep a one-way fingerprint of the request and the extracted result (amount, merchant, date, category) for about 1 hour, removed by a daily clean-up — **at most about 25 hours** — to prevent duplicate processing |
| iOS (Shortcut / share): sanitized message text and its sender and time on our servers | **Unavailable after 168 hours (7 days)** at most, and removed as soon as your device collects the result; the record without its content is **deleted after 30 days** |
| Duplicate-detection fingerprints | **Deleted automatically after 7 days** |
| Notification delivery records | **Deleted automatically after 30 days**, and when you delete your account |
| App activity events (achievements and streaks) | **No fixed expiry** — removed when you delete your account |
| Daily request counters | **No fixed expiry** — removed when you delete your account |
| Device identifiers used for capture | **No fixed expiry** — removed when you delete your account |
| Merchant names added to the shared merchant catalogue | **No fixed expiry** — a business name and category, not linked to you or your account |
| Shared message-format memory (section 8) | **No fixed expiry** — the shape of a bank's message with every amount, merchant and number replaced by a placeholder, the bank sender name and how the message reads; never a person's name, an amount or anything linked to you or your account |
| Shared merchant-code memory (section 8) | **No fixed expiry** — a merchant code as banks print it, its category and the display name Google Places returned; not linked to you or your account |
| Daily analysis counters | **No fixed expiry** — the date and counts only (for example how many messages were read), no user, device or message data |
| Your shared-learning contributions (merchant name, category, one-way code) | **No fixed expiry** — withdrawn when you delete that learned rule, and all deleted when you delete your account. A pair already added to the shared catalogue stays there as a business name and category, not linked to you |
| Learned merchant rules in the cloud | **No fixed expiry** — a rule you delete is kept as a deletion marker so your other devices drop it too; all of it is removed when you delete your account |
| Profile photo in the cloud | **No fixed expiry** — one copy, replaced when you choose a new photo; deleted when you delete your account |
| Encrypted backups | Until replaced or deleted by you |
| Text sent to Google's Gemini API | Per Google's terms — see section 7 |
| Crash reports (if enabled) | Per the diagnostics provider's retention |
| Service logs at our hosting provider | Per the hosting provider's log retention for our plan. Our code logs only content-free events (no message text, amounts, merchants or senders) |

The automatic deletions run on scheduled jobs. The rows with no fixed expiry are
exactly that — they do not expire on their own, and are removed when you delete
your account (except the merchant catalogue, which holds no personal data).
Database backups kept by our hosting provider are a separate retention domain:
data written before a deletion can remain in those backups until they expire.

---

## 7. Third parties

| Provider | Receives | When |
|---|---|---|
| Supabase (hosting, database, auth) | Whatever you have consented to sync, and sanitized message text for reading | Only with consent |
| Google — Gemini API (message reading) | Sanitized bank-message text; for an unrecognised bank, the sender's name | Only with Smart Analysis on — together with Cloud Sync, or on its own on iPhone |
| Google — Places API (merchant lookup) | A merchant name, without your identity | Only with Smart Analysis & Cloud Sync on |
| Sentry (crash reporting) | Crash diagnostics | Only with consent |
| Apple Push Notification service | The notification content Qirsh shows you | Only for notifications you allow |
| Google / Apple sign-in | Authentication only | Only if you sign in |

**No advertising.** This version of Qirsh shows no ads and does not request
ads. The app still contains Google's Mobile Ads SDK and its consent (UMP) SDK
from earlier development; in this version they are not started, so no ad is
requested and no advertising consent form is shown. We do not use your data for
advertising or share it with advertisers.

Supabase, Sentry and the Gemini API process data **on our behalf**, under our
instructions, to run the service. We do not sell or share your data for
advertising.

**Spending limit.** Our servers keep a daily count of paid AI requests across
all users, so that AI use stops at a fixed daily ceiling. The count holds only
the date, the service name and numbers — no user, device or message data.

**Google's Gemini API.** We send each request with Google's request-level
setting that turns off storage of the request in Google AI Studio logs. Google
states that it keeps prompts and responses for 55 days to detect abuse, and that
only authorised staff can see data flagged for review.
We use Google's paid Gemini API service, under which Google does not use our
requests to improve its products. Google does not offer a choice of processing location for this
service.

**Google Places API.** Google receives the merchant name as a search term and,
under the Google Maps Platform terms, may use and retain it to provide and
improve its services, as an independent controller. See the Google Privacy
Policy (https://policies.google.com/privacy). A name that contains an identifier
(card, phone, account, IBAN, reference number or e-mail) is never sent.

**About the AI row.** The model that categorises your spending is on your device
and sends nothing (section 2). That is separate from *reading* a bank message: if
you turn on Smart Analysis (with Cloud Sync, or on its own on iPhone), a
sanitized copy of the message may be sent to Google's Gemini API to help parse
it. It is off unless you accept it, and withdrawing consent stops it.

---

## 8. Permissions

### Android — SMS access

Qirsh can read **incoming SMS** on Android to detect financial transactions
automatically. This is the app's core function: turning bank messages into your
spending record without you typing them in.

- The permission is **requested only after a disclosure screen** explaining what
  is accessed and why, and only when you explicitly agree.
- Granting the permission is **not** enough on its own. Automatic capture stays
  **off** until you separately turn it on in Settings.
- Incoming messages are **screened on your device before anything is stored**.
  A message that does not look like a financial transaction is discarded at that
  point and is never saved. The screening is designed to leave ordinary personal
  messages and verification codes behind, but it is a judgement based on the
  message's content and sender rather than a guarantee — occasionally a message
  may be kept that you would not have chosen to keep. Anything kept in error can
  be deleted in the app.
- Messages that are kept are stored **encrypted on your device** and may be
  processed in the background (section 2).
- Qirsh requests `RECEIVE_SMS` only. It does **not** request permission to read
  your existing inbox, send messages, or read MMS.
- You can turn automatic capture off in Qirsh, or revoke the permission in
  Android settings, at any time. Either stops it immediately.
- SMS content is never used for advertising, marketing, or profiling, and is
  never sold.

**Manual capture always works without this permission.** You can share a message
to Qirsh instead, and nothing about that path requires SMS access.

### iOS

**iOS gives no app permission to read your Messages, and Qirsh does not have
one.** It cannot open, search or browse your Messages history. It only ever sees
a message that you hand to it, in one of two ways:

- **Share to Qirsh** — you select a message and share its text to Qirsh.
- **A Shortcuts automation you set up yourself** — Qirsh provides a Shortcuts
  action ("Process Bank SMS"). If you build an automation that runs it, the
  Shortcut passes that message's text, sender and time to Qirsh. Qirsh receives
  only what your automation passes in, and the automation only runs on the
  messages you configured it for.

In both cases, Qirsh receives content only because you either shared it or
configured a Shortcut to pass it. Qirsh cannot independently open, search, or
browse your Messages history.

### Other permissions

- **Notifications** — to show you alerts Qirsh generates, such as budget
  warnings and reminders.
- **Biometrics** — to lock the app, if you enable it.

- **Photos and camera** — only if you choose a profile picture. Qirsh opens the
  picker when you tap to set one; it cannot browse your library otherwise.
  The picture you choose is kept on your device and, with Smart Analysis &
  Cloud Sync on, backed up to your account (section 3).
- **Files** — only when you pick a backup file to restore.

Qirsh does not request location, contacts, or the microphone.

### Where captured messages are processed

**By default, captured message text is read on your device and does not leave
it.**

If you accept **Smart Analysis & Cloud Sync**, or turn on **Smart Analysis**
on its own on iPhone — a separate consent from the SMS permission, off unless
you accept it — captured bank messages are **sanitized**
on your device and then sent to Qirsh's servers, which sanitize them again and
pass the text to **Google's Gemini API** to read the amount, currency, merchant,
transaction type and date. When you paste or share a message in the app, the
request may also include what the app already read from that message on your
device — the amount as written in the message, and the currency and direction
when the app found them in it — and the currency code of your account the
message matched, so that the two readings can be checked against each other.
The amount is only sent if it still appears in the sanitized text. We record
which AI model and instruction version produced each result, to investigate
errors. On Android this includes bank
SMS that Qirsh reads automatically and messages you share to Qirsh; on iOS,
messages you share or pass through the Shortcut.

**Sanitizing is automatic, and it can miss some things.** Before a message
leaves your device — in the app and in the Shortcuts action, which apply the
same rules — and again on our servers before anything is stored or sent to
Gemini, Qirsh removes what it recognises as:

- full card numbers,
- long account numbers, and account numbers that follow an account label,
- IBANs,
- mobile phone numbers,
- verification and one-time codes,
- e-mail addresses and reference numbers that follow a reference label,

and masks the names of people it detects (for example after a greeting such as
"Dear …" or «عزيزي …», or after words such as "from", "to", "beneficiary",
«من», «إلى» or «لصالح» in transfers and credits). Because this is automatic, it
can miss some of these — for example a name or number written in a way the
rules do not recognise — and the rest of the message is sent as written.

What stays in the text: the amount and currency, the balance if the bank
includes it, the merchant or place, dates and times, the last digits of your own
card or account when the bank shows at most four of them (for example
`***1234`), bank names, and anything the rules did not recognise. **This text is
still personal financial information about you; it is not anonymous.** Requests
are linked to your account or device so that we can authenticate and rate-limit
them.

For a bank sender we do not recognise, the sender's name may also be sent to
Gemini to identify the bank — only a name made of letters (such as a bank's
registered sender name); a phone number or numeric sender is never sent. For a
purchase we cannot categorise, with Smart Analysis & Cloud Sync on, the merchant
name may be sent to Google's Places API.

**Shared, non-personal memory.** So that the same bank message format is not
sent to Gemini again and again, our servers remember the *shape* of a bank's
message once Gemini has read that shape the same way at least three times from
at least two devices: the message with every amount, merchant and number
replaced by a placeholder, together with how it reads (for example "a card
purchase"). A message in which a person's name was masked is never remembered.
A later message of the same shape may then be read from that memory instead of
being sent to Gemini (a sample is still checked with Gemini, and a shape Gemini
disagrees with is dropped for good). Separately, for a merchant code as banks
print it (for example "CARREFOUR MAADI"), we remember its category and the
display name Google Places returned, so it is looked up only once. This memory
holds no amounts, no people's names and nothing that identifies you, your
device or your account; to count distinct devices it keeps a short one-way code
per shape that cannot be linked across shapes or back to you.

**The analysis log.** On your device, Qirsh keeps a log of each captured bank
message and what became of it — recorded, not added (with the reason), waiting
for your confirmation, or waiting for analysis — with the masked message text.
It stays on your device and is removed with your data.

What we keep, and for how long, is in section 6: for Android messages our
database does not store the message text; for iOS the sanitized text is kept for
at most 168 hours. The transactions created from your messages are synced like
any other transaction and kept until you delete them or your account.

So: with the default settings, message text stays on your device. If you turn
on Smart Analysis (with or without Cloud Sync), sanitized text does leave your
device and is
processed by Google — we will not tell you otherwise. You can withdraw consent at
any time in Settings → Privacy & data; sending stops immediately.

---

## 9. Contact

Questions, or a data request: **business@qirsh.site**

---

## 10. Changes

Material changes will be announced in the app before taking effect. The "last
updated" date above always reflects the current version.

---

<!--
  DEPLOYMENT NOTE — not part of the published text.

  Publication: the live site is NOT updated by editing this file. The owner
  redeploys it with `tools/deploy_site.sh` (not run by the release work).

  Before publishing:
    1. Do NOT publish before BOTH (a) the app release built from the V1
       candidate (first-run consent, combined turn-off, final deletion, ads
       compiled out, catalog gated on Cloud consent, all-country picker) is
       live on the App Store, and (b) the V1 backend package in
       docs/releases/version-1/RELEASE-PLAN.md is deployed — in particular
       account-deletion-worker (the deployed v5 still erases only the
       `backups` bucket, not `profile-photos`; section 5 says the profile
       photo is deleted).
    2. Until (a), build 147 users still see the earlier behaviour (separate
       shared-learning switch on by default, 30-day deletion text in the app).
       Publishing earlier would describe a build they do not have.
    3. Gemini billing tier: confirm the production Gemini project is on the
       paid tier (section 7 says so). If not, section 7 must change.
    4. Set "Last updated" to the publication date.
    5. Host at the URL configured in `app/lib/core/config/legal_urls.dart`
       (https://qirsh.site by default).

  Statements that depend on another specialist's code and must be reconciled
  against the final commit before publishing:
    - ads SDK presence and "not started" (admob_build_config.dart
      `adsCompiledIn`, mobile_ads_initializer.dart, ad_consent_service.dart);
    - consent and shared-learning wording (smart_analysis_consent_sheet.dart,
      shared_learning_preference.dart, app_en.arb smartConsent* keys);
    - deletion lifecycle (deleteAccount* and privScheduledForDeletion keys);
    - catalog gated on Cloud consent (consent_authority.dart,
      catalog_sync_service.dart);
    - country coverage note (countryCoverageNote);
    - section 8 redaction list (device SmsSanitizer, native Shortcut
      sanitizer, server _shared/sms_redaction.ts redactPii; own account
      suffix of at most four digits kept) — checked at f4dcabd3.

  Retention statements in section 6 were checked against migrations 0112
  (7-day capture text, 30-day capture rows, 7-day fingerprints, 30-day
  notification logs) and 0117 (account-deletion purge). If behaviour changes,
  this text must change with it.
-->
