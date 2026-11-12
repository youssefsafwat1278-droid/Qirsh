# Android SMS Capture Decision

**Status: ENABLED and reachable. Publication gated on Google Play approval.**

This document previously said the opposite — "intentionally disabled for MVP",
"`AndroidManifest.xml` does not declare `READ_SMS`, `RECEIVE_SMS`, or an SMS
broadcast receiver". All three claims became false when automatic capture was
implemented, and the document was never revised. It is superseded by the owner
decision of 2026-08-31 recorded in
`Qirsh Production/18_Android_SMS_Capture/README.md`: automatic financial-SMS
capture is a **required core feature of Android V1**, and the earlier
"Play-safe, share-only" position is **revoked**.

## What the build actually contains

| | |
|---|---|
| `RECEIVE_SMS` | **declared**, unconditionally (`AndroidManifest.xml`) |
| `READ_SMS` / `SEND_SMS` / `WRITE_SMS` / `RECEIVE_MMS` / `RECEIVE_WAP_PUSH` | **absent** — the receiver reads broadcast intents and never touches `content://sms` |
| `SmsCaptureReceiver` | **registered**, `android:permission="android.permission.BROADCAST_SMS"` so only the OS can deliver to it |
| Prominent disclosure | **implemented** and shown immediately before the system dialog |
| User opt-in | **implemented** — Settings → «رصد العمليات» → automatic bank-SMS capture |
| Privacy policy §8 | **LIVE** at `qirsh.site/privacy` and `/en/privacy` |
| Play permissions declaration | **draft ready, NOT submitted** |
| Google Play approval | **PENDING — do not publish without it** |
| Physical-device SMS QA | **PENDING** |

## The two-key lock

A granted permission is not consent:

```
RECEIVE_SMS granted   AND   CaptureSettings.autoCaptureEnabled == true
```

`SmsCaptureReceiver.onReceive` returns before touching the intent unless the
opt-in is true. The opt-in defaults to false, is set only by an explicit user
action after the disclosure, and belongs to the account that turned it on (the
capture owner's HMAC is stored with it). Revoking the OS permission fails capture
closed on the next check.

When the opt-in is reset (native, `MainActivity` capture channel):

| Event | Opt-in |
|---|---|
| Another account is published as capture owner (account change) | **reset** before that account is stamped on anything |
| The same account signs in again (after a sign-out, an app restart) | kept |
| Sign-out | kept (the account's SMS keep arriving as *unbound*, offered back only to it) |
| Remove data / account deletion (`beginCaptureRemoval`, `finishCaptureRemoval`) | **reset** |
| An opt-in recorded before this model (no owner) | adopted by the account published at the first launch after the update; reset at the first account change instead |

Until 2026-11-12 this paragraph promised a reset "on identity change" that did
not happen: the Android owner, removal and purge calls were Dart no-ops
(`NativeCaptureBridge._hasNativeQueue` was iOS-only) and `purgeAllCaptureState`
had no production caller, so the opt-in, and every queued SMS, survived sign-out,
account switch, Remove data and account deletion.

## Account isolation of the capture queue

`DurableCaptureQueue` (SharedPreferences main segment + `files/capture_overflow/`)
is owner-scoped, the Android counterpart of the iOS queue's owner model:

- Every admission (`AppSession._admitReplica`) publishes the account as the
  **active owner** (`publishCaptureOwner`, compare-and-swap on the owner epoch).
  Native keeps only `HMAC(Keystore key, uid)`; no uid is written anywhere.
- Each capture (SMS receiver and share sheet) is **stamped** at enqueue with the
  active owner, or is **unbound** when there is none, hinted to the account that
  owns the SMS opt-in / was last signed in (also an HMAC).
- The drain (`peekPendingSharedMessages`, `acknowledgeSharedMessage`,
  `consumePendingSharedMessages`) sees **only the active owner's** stamped
  captures. Sign-out (`clearCaptureOwner`) keeps them, invisible, until that
  account signs in again; another account never sees, imports, acknowledges or
  sends them to AI.
- Unbound captures are imported only after the explicit claim prompt ("Add them
  to my account" / "Discard them", `unboundCaptureSummary` /
  `claimUnboundCaptures`), and only by the hinted account. Claimed captures are
  `localOnly`: parsed on the device, never sent to AI.
- Captures queued by a build before this model carry no stamp: they are treated
  as unbound **without a hint**, never auto-imported, never deleted, and offered
  through the same claim to the account that signs in.
- Remove data / account deletion runs the persisted barrier
  (`beginCaptureRemoval` → replica teardown → `finishCaptureRemoval`): nothing is
  captured, published or claimed while it is set; the sweep deletes every capture
  stamped or hinted to that account (main + overflow), every quarantined
  (unreadable, so unattributable) blob/file and unfinished temp file, resets the
  opt-in, cancels the scheduled background drain, verifies nothing of the
  account remains and only then clears the barrier. Anything left is reported
  (`removal_incomplete`) and the removal resumes at the next launch. Other
  accounts' captures and unhinted pre-update captures are kept.
- `NativeCaptureBridge.hasNativeQueue` (the iOS upload gate, egress state,
  consent mirror) stays iOS-only; Android uses `hasOwnerScopedQueue` for the
  owner, claim and barrier calls only.

## Storage at rest (encryption)

Until 2026-11-12 the Android queue kept raw bank SMS in **plaintext** in
app-private storage (the `items` JSON in SharedPreferences
`mali_capture_queue_v1`, one `.json` file per overflow capture, plaintext
quarantine copies and temp files). It is now sealed, matching the iOS queue
(`SharedCaptureStore`, AES-GCM with a Keychain key):

| | |
|---|---|
| Cipher | AES-256-GCM, 128-bit tag, random 96-bit nonce per seal (generated by the Keystore: the key requires randomized encryption) |
| Key | Android Keystore `qirsh_capture_queue_aes_v1`, non-exportable, GCM only, separate from the owner-HMAC key `qirsh_capture_owner_hmac_v1`. No user-auth / unlocked-device requirement: SMS must be stored while the phone is locked |
| Format | `qcs1.` + base64(nonce ‖ ciphertext ‖ tag). AAD `qirsh.capture.queue.v2/<slot>` binds each record to its slot (`main`, `overflow/<sequence>_<sha256(id)>`, `quarantine/<name>`) and format version: a record moved to another slot fails authentication |
| Main segment | prefs `items_sealed` (whole segment sealed) |
| Overflow | `files/capture_overflow/<20-digit seq>_<sha256(id)>.qcs`, written seal → temp → fsync → rename; a temp file only ever holds sealed bytes |
| Quarantine | a record that fails authentication or does not parse is kept as the **sealed bytes it was** (`sealed_quarantine_<ms>_<rand>` / `<name>.quarantine`), counted, never imported, never deleted except by Remove data / purge |
| Key check | prefs `key_check` = a known plaintext sealed with the key, written before anything else is sealed with a new key. It separates a damaged record (quarantined) from a wrong/lost key (never quarantined) |

Not encrypted: counters, the owner/hint HMACs, the owner epoch/generation and
the Remove-data barrier (hashes and numbers, no message content).

**Migration** (first read after the update): the plaintext main blob and
plaintext quarantined blobs are read unchanged, merged after any sealed items
(duplicates resolved by id: the sealed copy wins) and replaced by their sealed
form in ONE SharedPreferences commit, so an interruption leaves them plaintext
or sealed, never neither. Each plaintext overflow file is sealed (temp → fsync →
rename → directory fsync) BEFORE its plaintext is deleted; a crash between the
two leaves both, and the next run deletes the plaintext once the sealed copy
opens (same name = same id). Plaintext quarantined and unfinished temp files are
kept only in sealed form (`<name>.qcs.quarantine`): plaintext is never kept
after a successful migration, and the bytes are preserved inside the seal. Until
every plaintext is gone the queue reads as unreadable (fail closed), so an item
acknowledged from its sealed copy can never be resurrected from a stale
plaintext one.

**Key unavailable** (Keystore not answering, key deleted by a Keystore reset,
key permanently invalidated — e.g. by a lock-screen change on some OEMs — or a
different key under the alias): fail closed and visible.

- Nothing is quarantined, deleted, overwritten or migrated; the sealed data
  stays on disk untouched.
- Reads are an error (`queue_unreadable` → the `captureQueueReadFailed`
  notice: "Couldn't read the bank messages saved on this device. Nothing was
  deleted…"), never an empty queue; `captureQueueHealth` reports
  `size: -1`, `keyUnavailable: true` and `unreadable: <sealed records>`.
- **New captures are refused** (`NOT_PERSISTED`, counted, the
  `captureQueueNotSaved` notice). Decision: refuse rather than seal under a new key in a
  second generation. It is the iOS behaviour; a Keystore that merely did not
  answer would otherwise get a second key that orphans the first set of data
  for good; and one queue with one key keeps ordering, dedupe, the Remove-data
  sweep and the claim flow single-generation. The cost is that capture stays
  off until the key is back or the unreadable data is removed.
- A key is minted ONLY when no sealed capture data (live or quarantined)
  exists — iOS `encryptionKey()` parity.
- Recovery: when the key is DEFINITIVELY gone (absent from a Keystore that
  answered, permanently invalidated, or failing the key check), Remove data /
  account deletion sweeps the unreadable sealed data as unattributable residue
  (like quarantined data: it may hold that account's messages and can never be
  imported by anyone — this includes other accounts' unreadable captures),
  verifies it is gone, deletes the dead key, and capture works again under a
  new key. If the Keystore merely did not answer, the removal stays
  `removal_incomplete` (barrier kept) and is retried. An identity purge always
  deletes everything.

**Backup / device transfer**: `allowBackup="false"` + `fullBackupContent="false"`
(Android ≤ 11) and `dataExtractionRules` excluding every domain from cloud
backup AND device-to-device transfer (Android 12+, where `allowBackup="false"`
does not stop D2D). Nothing of the queue leaves the device that way. Even if
sealed files did reach another device (e.g. a manual/rooted copy), Keystore keys
are never exported, so they arrive under no key: treated as key unavailable —
counted, not deleted, never imported, never imported under another owner (the
owner stamps are inside the seal), and no new key is minted over them.

**Remove data / purge**: Remove data sweeps sealed records exactly as it swept
plaintext ones (owner semantics unchanged), plus sealed quarantine. Purge
deletes every overflow file first, then the prefs, verifies no sealed byte is
left, and only then deletes the queue key (crypto-shredding whatever the
filesystem may still hold). If anything is left the key is kept and the purge
reports failure; a key that cannot be deleted after the data is gone does not
fail the purge (it seals nothing and is replaced by the next capture).

Device-only checks (not provable in the JVM harness): Keystore AES-GCM
behaviour and cost on real hardware (TEE/StrongBox, a 200-item main segment is
re-sealed on every write), key survival across reboot / lock-screen changes on
the OEMs in the QA matrix, and that an update of a device with a plaintext queue
migrates it.

## What was missing until 2026-09-02

The native receiver, the permission state machine, the Dart facade and the
disclosure widget were all complete and tested — and **nothing called them**.
There was no UI through which a user could turn the feature on, while the app
shipped the restricted permission and a live receiver anyway.

That is the failure mode Play's core-functionality test exists to catch, and it
also meant the Settings screen told users «لا يقرأ … رسائل SMS من النظام» ("does
not read system SMS") while the binary declared the opposite intent. Both are
fixed: the toggle exists, the copy is accurate, and
`test/features/capture/android_sms_permission_test.dart` now contains a
reachability group that fails if either the service or the disclosure ever loses
its last production caller.

## Still required before publishing

1. Physical-device QA — the matrix in
   `Qirsh Production/18_Android_SMS_Capture/device_qa_plan.md`, plus the account
   isolation steps: SMS while A is signed in → sign out → sign in as B (B imports
   nothing, opt-in off) → back to A (imports it); SMS while signed out → the claim
   prompt; Remove data with queued SMS (queue empty of A afterwards, opt-in off);
   an update of a signed-in device with queued SMS (offered through the claim);
   the same update with a plaintext queue (migrated, nothing lost, no plaintext
   left in `shared_prefs/mali_capture_queue_v1.xml` or `files/capture_overflow/`).
   No Android device has ever been attached to this machine.
2. Submit the Play permissions declaration and the Data Safety form (both
   drafted, neither submitted).
3. Reconcile the declaration draft's "no SMS text reaches an AI provider" claim
   with the Data Safety draft's optional sanitized-text path and the live
   privacy policy's optional cloud/AI section, so all three say the same thing.
4. Google Play approval.
