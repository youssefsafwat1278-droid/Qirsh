# Version 1 — open defects and known limitations

Assessed at: the candidate **`a157e68e`** ([RELEASE-MANIFEST.md](RELEASE-MANIFEST.md)). Rewritten for round 3 on 2026-11-18 by a records editor (AI agent, `claude-opus-5-5`) from the issues register, reviews S and T, and the closure reports. This editor ran no test.

**Nothing in this file has been accepted by the owner.** The owner approved the product decisions in [OWNER-BRIEF-ROUND3.md](OWNER-BRIEF-ROUND3.md) §3 on 2026-11-17; some items below are consequences of those decisions, and they are listed so the owner sees them, not because the owner accepted them. To ship with any open S2 item, the owner would have to sign an exception record ([`EXCEPTION-TEMPLATE.md`](../../release-process/EXCEPTION-TEMPLATE.md)); S3 items are listed here under the severity rules.

Part 1 lists behaviour that records or shows money wrongly, or leaks data: **defects, not limitations.** Part 2 lists consequences of approved decisions. Part 3 lists constraints of the release and of this assessment.

## Part 1 — Open defects

### 1.1 Money recorded wrongly or not at all (synthetic evidence only)

The bank-message parser was rebuilt in round 3 to decide what a message means before reading an amount (brief §4.1). On synthetic messages it is much safer than build 147, but it has not met a real bank message, a real AI model or a device.

| Measurement (all synthetic) | Build 147 parser (`ab5dc10a`) or round-2 candidate (`5dae2e2d`) | Candidate `a157e68e` |
|---|---|---|
| Held-out set, 753 messages, one author, deterministic cloud path: non-transactions / declined-or-pending / ambiguous saved as money | 44 / 79 / 4 (`ab5dc10a`) | 0 / 0 / 0 |
| Same set: wrong amount, currency or direction | 13.9 % (`ab5dc10a`) | 0.0 % |
| Same set: messages lost silently | 8 (`ab5dc10a`) | 0 |
| Review S's 708 probe messages aimed at weak spots, iOS import: wrong / silent / review | 75 / 3 / 62 (`5dae2e2d`) | 11 / 3 / 62 |
| Same, server alone | 52 / 21 / 107 (`5dae2e2d`) | 9 / 26 / 77 |

Caveat on the held-out set: failing families found in it were fixed using fresh sibling examples given to the tuners, so it is weaker evidence than a first run.

Still wrong at the candidate (review S, `a157e68e`):
- **Recorded although no money moved** (V1-094, S3): "Awaiting merchant confirmation", "Attempted purchase", "You will receive … cashback on 01/12", "… will be charged tomorrow", "awaiting authorization", Arabic «عملية معكوسة:» before a total.
- **Wrong direction or wrong kind** (V1-098, S3): an own-account transfer booked as spending (AT008); an Arabic refund booked in the wrong direction (RF009). Two older items (B147-1, PAR-1) were not re-measured.
- **Silent on the server, held for review on the device** (V1-096, V1-097, S3): a purchase with a "Standing orders will be executed…" footer; six completed shapes with a bill-reminder, month-total or "as scheduled" tail. With the new build the user sees them in review; anything that reads only the server row sees nothing.

Build 147 and older keep the old parser on the device. If the server is deployed while testers still use build 147, the evaluation shows 0 messages worse in classes that change totals (synthetic), but build 147's own wrong outcomes remain (for example 24 non-transactions and 60 declined or pending messages saved on its cloud path, down from 44 and 79).

Transactions already stored stay as they are (decision 3.15): declined purchases that build 147 counted are still counted unless the user edits them.

### 1.2 Completed money movements that wait for the user (no wrong total, but totals understated until confirmed)

- Without Cloud, 27.2 % of completed held-out messages go to review (bar 15 %, fails A7; 119 of the 123 already went to review in build 147). With the deterministic cloud path 8.8 %, oracle path 3.1 % (V1-075, V1-103).
- HOLD-1 (V1-095): "expected/pending refund … credited", purchases with a refund footer, third-party transfers naming two account types, "Bill + VAT = total paid", an FX-fee total.
- The device validator rejects 7.5 % of correct AI answers by the letter of criterion A8a (1.8 % on rows that must be saved) (V1-103).
- Engineering choices that send messages to review (owner may reverse; DECISIONS-NEEDED table D): ATM cash deposits, credit-card repayments "received", completed English reversals "credited", text over 2,000 characters.
- No monitoring of review volume exists (V1-024).

### 1.3 Privacy defects

- **PRIV-1r (V1-091, S2, open; V1-107):** some person names still reach the server and the AI model after redaction. **Labelled names ("Name:", "Attn", "Customer") are not masked at all.** Also unmasked: "From <Name>:", «إلى حساب <name>» on the `payment` path, "Payment … to <Name> via Mada", "to account of <Name>", and "(<Name>)" after an account suffix (review S; review T at `a157e68e`; device, server and Swift behave identically). The consent text says sanitized text is not guaranteed anonymous; that does not make the leak acceptable. Needs a fix or an owner-signed exception.
- MASK-1 / MASK-0 (V1-092, V1-093, S3): some merchants are masked as if they were people, and the card suffix is masked in "Purchase To:" forms, so the AI loses the merchant and category.
- Account digits: the code keeps a suffix of at most four digits after an own-account word (and «حسابك») for account matching, so it reaches the server. **The code does not check that the number is the user's**: a third party's short suffix (for example "beneficiary account ****9876") is kept too (V1-107).

### 1.4 Other open defects users could notice

- Build 147's Shortcut banner still says a purchase was captured, with the parsed category, until users update (decision 3.12 is met only in the new build).
- Shared text containing a URL may be filed as an offer (V1-038, not changed, device check owed).
- Tab bar after email sign-in: fixed for email on a simulator; Apple/Google sign-in and app lock not tested (V1-065).
- One production account had 540 failed iOS notifications in 7 days (error 2003) and 2 captures stuck in `processing` (V1-106); not investigated.

## Part 2 — Consequences of the approved decisions (listed, not accepted)

- **Restore merges (3.3):** device rules win; rules that exist only in the backup are not added; a transaction deleted by mistake cannot be brought back by a merge, only by removing the device's data and doing a full restore, which loses anything newer (V1-102). The confirmation says which case applies. **Not adding backup-only rules departs from decision 3.3 ("restore missing records") and needs the owner's acceptance or rejection** (V1-110, DECISIONS-NEEDED C10). Two-device conflict cases S9/S9b were never run end to end (V1-101).
- **Deletion is final (3.4):** no undo. Until plan step P1 runs, the deployed deletion worker leaves profile photos of deletions it resumes (V1-062).
- **All countries (3.7):** bank formats are verified only for Saudi Arabia and Egypt; other countries get the generic parser and review. 155 currencies can be stored; only 50 are recognized in message text. A phone still on build 147 cannot show rows in the 105 new currencies (V1-100). Antarctica has no default currency; the user chooses.
- **Shared learning (3.10):** on only after "Agree and enable"; existing users are asked once (orchestrator's reading; owner may reverse).
- **Signed-out capture (3.13):** the message is not kept; the user is told it was not saved and to open Qirsh and sign in to record new messages.
- **No ads (3.2):** the ad SDKs are still linked in the binary but never started; whether they make any network request was not tested. Production ad flags stay ON until plan step P4.
- **Historical rows (3.15):** never re-analysed.

## Part 3 — Constraints

### Evidence limits

- **Synthetic only.** Every parser and AI number comes from synthetic messages written by AI agents. No real bank message was processed.
- **No real AI model.** The AI path was tested against an oracle and against forged answers; the real model was never called (no authorized key; the key in a git-ignored local file was deliberately not used) (V1-074).
- **No device.** Every runtime observation is on an iOS simulator or a local Supabase stack. VoiceOver, the largest accessibility sizes on a device, the live app switcher, notifications on a lock screen, Shortcuts and the share extension on a phone, upgrade from build 147: NOT TESTED.
- **No CI, no signed build.** The strict gate passed 15/15 on this Mac at `a157e68e`; XCTest 200/200 on a simulator (implementer only). Nothing ran on Codemagic; no signed archive exists; the archive Privacy Report was not produced.
- **AI review only.** Reviews S and T are AI agents; T's check at `a157e68e` was narrow (no stack, no simulator).
- **Large text:** the gate catches text cut with an ellipsis on 32 screens; text clipped without an ellipsis is not detected; three collapsed navigation titles are allowlisted (V1-105).
- Parse time was measured on a Mac by review S (worst 392 ms at 2,000 characters, at `6f771108`), not on an iPhone and not re-measured at `a157e68e`.

### Platform and pipeline

- iPhone only, portrait. On an iPad the app would run in iPhone compatibility mode; not tested.
- Android is out of V1 (3.1); its defects (V1-004, V1-027, V1-053) move to the Android release.
- The store workflow `ios-signed-release` has never run (V1-009); it fails if the Apple, Google or email sign-in variables are missing, and their values in Codemagic are not visible.
- Export compliance is unanswered (V1-026).

### Backend and operations

- Point-in-time recovery is off and no backups are listed (V1-023). The plan proposes an owner-run `pg_dump` before any change; nothing has been run.
- No backend alerting (V1-024); the monitoring queries in RELEASE-PLAN (g) must be run by hand.
- The global AI budget guard fails open if its database function is missing (by design; SP-05).
- Nothing is deployed. The package is seven functions and one migration (RELEASE-PLAN).
- Auth hook, Vault values and admin exposure are unknown.

### Documentation

- The live legal site shows the old policy until it is redeployed after release.
- Code comments call two engineering choices "decisions" (V1-104).
