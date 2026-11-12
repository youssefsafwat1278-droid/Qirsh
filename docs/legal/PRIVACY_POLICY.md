# Qirsh — Privacy Policy

**Last updated: 2026-11-12**

Qirsh (قِرش) is a personal finance app that reads bank SMS on your device and
turns them into a private record of your spending.

This policy describes what the app actually does. It was written after the
privacy behaviour was audited and corrected, not before — several statements
that used to be aspirational are now enforced in code and covered by tests.

---

## 1. The short version

- **Your financial data lives on your device**, in a database encrypted with a
  key held in the device keychain. Bank messages waiting to be processed are
  also stored encrypted on your device.
- **Cloud sync is OFF by default.** With it off, no financial data leaves your
  device — this is enforced at every network call, not only in the settings UI.
- **The model that categorises your spending runs entirely on your device**, with
  no network access at all. Separately, if you accept **Smart Analysis & Cloud
  Sync** — one choice, off unless you accept it, which turns on both cloud
  processing and AI assistance together — a sanitized copy of a bank message may
  be sent to our servers and to Google's Gemini API to help read it. The
  sanitized text is still personal financial information; it is not anonymous.
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

Cloud features are **off by default**. The gate is checked at the moment of
sending — turning consent off stops transmission immediately, not at the next
app start.

| Category | Sent when enabled | Purpose |
|---|---|---|
| Financial sync | Accounts, transactions, budgets, goals, plans | Multi-device sync |
| Encrypted backup | An encrypted archive of your data | Restore after device loss |
| Message reading (Smart Analysis) | Sanitized bank-message text (see section 8) | Read the amount, merchant, date and type |
| Bank identification | For a bank sender we do not recognise: the sender's name (letters, such as a bank's name; never a phone number) and the sanitized text | Identify which bank sent it |
| Merchant lookup | A merchant name we cannot categorise | Find the merchant's category |
| Bank mappings | Which bank a sender ID belongs to | Improve parsing for everyone |
| Smart Inbox | Messages awaiting your confirmation | Review across devices |
| Gamification | Achievement progress | Cross-device streaks |
| Telemetry | Notification delivery/open events | Reliability of capture |
| Diagnostics | Crash reports | Fixing crashes |

**Diagnostics fail closed:** when cloud/privacy consent is off, crash reporting
does not transmit — the report is dropped before it is assembled, not merely
scrubbed.

### Always allowed, and why

Two things are not consent-gated:

1. **Catalog updates** — parser rules, feature flags, and the force-update
   notice. These carry **no data about you** and are requested anonymously. They
   also deliver safety controls, so gating them would leave the most
   privacy-conscious users unable to receive a critical fix notice.
2. **Authentication**, when you choose to sign in.

---

## 4. Consent, and how it behaves

- Consent is **off by default**. Nothing about your finances is uploaded until
  you turn it on.
- **Smart Analysis & Cloud Sync is one choice.** Accepting it turns on cloud
  processing and AI assistance together; message reading by Google's Gemini API
  requires both, and withdrawing stops it.
- **Revocation is immediate.** The check is performed at each transmission, so
  turning cloud off stops the next sync — including retries, background work,
  and startup reconciliation.
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
Settings → Privacy & data → Delete my account and all my data. Your account and
your cloud data (transactions, goals, budgets, backups, and the capture and AI
records described in section 6) are scheduled for permanent deletion after 30
days. You can undo it before then by signing in again.

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
| Daily request counters | **No fixed expiry** — removed when you delete your account |
| Device identifiers used for capture | **No fixed expiry** — removed when you delete your account |
| Merchant names added to the shared merchant catalogue | **No fixed expiry** — a business name and category, not linked to you or your account |
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
| Google — Gemini API (message reading) | Sanitized bank-message text; for an unrecognised bank, the sender's name | Only with Smart Analysis & Cloud Sync on, which turns on **both** cloud processing and AI assistance |
| Google — Places API (merchant lookup) | A merchant name, without your identity | Only with Smart Analysis & Cloud Sync on |
| Sentry (crash reporting) | Crash diagnostics | Only with consent |
| Google / Apple sign-in | Authentication only | Only if you sign in |

Supabase, Sentry and the Gemini API process data **on our behalf**, under our
instructions, to run the service. We do not sell or share your data for
advertising.

**Google's Gemini API.** We send each request with Google's request-level
setting that turns off storage of the request in Google AI Studio logs. Google
states that it keeps prompts and responses for 55 days to detect abuse, and that
only authorised staff can see data flagged for review.
[OWNER MUST CONFIRM before publishing: "We use Google's paid Gemini API service,
under which Google does not use our requests to improve its products." — true
only if the production project is on the paid tier with an active billing
account.] Google does not offer a choice of processing location for this
service.

**Google Places API.** Google receives the merchant name as a search term and,
under the Google Maps Platform terms, may use and retain it to provide and
improve its services, as an independent controller. See the Google Privacy
Policy (https://policies.google.com/privacy). A name that contains an identifier
(card, phone, account, IBAN, reference number or e-mail) is never sent.

**About the AI row.** The model that categorises your spending is on your device
and sends nothing (section 2). That is separate from *reading* a bank message: if
you accept Smart Analysis & Cloud Sync, a sanitized copy of the message may be
sent to Google's Gemini API to help parse it. It is off unless you accept it,
and withdrawing consent stops it.

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
- **Files** — only when you pick a backup file to restore.

Qirsh does not request location, contacts, or the microphone.

### Where captured messages are processed

**By default, captured message text is read on your device and does not leave
it.**

If you accept **Smart Analysis & Cloud Sync** — a separate consent from the SMS
permission, off unless you accept it — captured bank messages are **sanitized**
on your device and then sent to Qirsh's servers, which sanitize them again and
pass the text to **Google's Gemini API** to read the amount, currency, merchant,
transaction type and date. On Android this includes bank SMS that Qirsh reads
automatically and messages you share to Qirsh; on iOS, messages you share or
pass through the Shortcut. Sanitizing removes:

- full card numbers,
- phone numbers,
- account numbers and IBANs,
- e-mail addresses,
- one-time codes that follow a code label,
- reference numbers that follow a reference label,
- people's names where they are recognisable from the wording: after a greeting
  ("Dear …", «عزيزي …») and, in transfers and credits, after words such as
  "from", "to", "beneficiary", «من», «إلى» or «لصالح».

What stays in the text: the amount and currency, the balance if the bank
includes it, the merchant or place, dates and times, masked card endings
(`*1234`), bank names, and any name written in a way these rules do not
recognise. **This text is still personal financial information about you; it is
not anonymous.** Requests are linked to your account or device so that we can
authenticate and rate-limit them.

For a bank sender we do not recognise, the sender's name may also be sent to
Gemini to identify the bank — only a name made of letters (such as a bank's
registered sender name); a phone number or numeric sender is never sent. For a
purchase we cannot categorise, the merchant name may be sent to Google's Places
API.

What we keep, and for how long, is in section 6: for Android messages our
database does not store the message text; for iOS the sanitized text is kept for
at most 168 hours. The transactions created from your messages are synced like
any other transaction and kept until you delete them or your account.

So: with the default settings, message text stays on your device. If you accept
Smart Analysis & Cloud Sync, sanitized text does leave your device and is
processed by Google — we will not tell you otherwise. You can withdraw consent at
any time in Settings → Privacy & data; sending stops immediately.

---

## 9. Contact

Questions, or a data request: **<CONTACT_EMAIL>**

---

## 10. Changes

Material changes will be announced in the app before taking effect. The "last
updated" date above always reflects the current version.

---

<!--
  DEPLOYMENT NOTE — not part of the published text.

  Before publishing:
    1. Replace <CONTACT_EMAIL> with a monitored address.
    2. Resolve the bracketed "[OWNER MUST CONFIRM ...]" sentence in section 7
       (Gemini billing tier). If the production Gemini project is NOT on the
       paid tier, the sentence must instead say that Google may use the
       requests to improve its products and that human reviewers may read
       them — and sending bank-message text there should be reconsidered.
    3. Do NOT publish this version until the 2026-11 backend changes are
       DEPLOYED (parse-sms, bank-discovery, process-ios-sms, enrich-merchant,
       _shared/sms_redaction.ts, _shared/gemini_request.ts, _shared/ai_primary.ts):
       server-side name / e-mail / reference masking, `store:false` on every
       Gemini request, numeric senders never sent to bank-discovery, and the
       enrich-merchant identifier refusal. Sections 3, 7 and 8 describe them.
    4. Do NOT publish before the app release that contains (a) the AES-256-GCM
       encrypted Android capture queue and (b) cold-start background processing
       (WorkManager / BGTaskScheduler). Sections 1, 2, 6 and 8 describe them.
    5. Set "Last updated" to the publication date.
    6. Host at the URL configured in `app/lib/core/config/legal_urls.dart`.
       That host must resolve — the in-app Privacy screen links to it, and both
       app stores require a reachable privacy URL.

  This document describes behaviour verified in the 2026-08 audit:
  C-3 (consent enforced at every egress point, fail-closed),
  OD-13 (on-device model, no network path),
  OD-10 (revocation and cloud deletion are separate actions),
  and the 2026-11 Android SMS + AI review
  (docs/privacy/ANDROID_SMS_AI_DISCLOSURE_PROPOSAL.md).
  If that behaviour changes, this text must change with it — a privacy policy
  that describes the software inaccurately is worse than none.
-->
