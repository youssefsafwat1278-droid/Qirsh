# Proposal: reviewing transactions stored before the declined-transaction fix

**Status: NOT PURSUED.** The owner decided on 2026-11-17 (OWNER-BRIEF-ROUND3.md §3.15, D-20) that parser corrections apply only to newly processed messages, that previously recorded transactions are not re-analysed, recategorized or silently marked for review, and that any historical clean-up stays outside this release. Nothing here is implemented, and nothing will be under V1. The text below is kept as written for a possible later decision (D-20 leaves historical clean-up undecided).

Original status: PROPOSAL ONLY. It answered V1-056 / REV-05.

## Problem

Before the V1-001 fixes (`d35fc044`, `668f4d64` and the residual fix that follows them), the app and the server could store messages that moved no money as confirmed transactions:

- a declined, failed, voided, expired or cancelled purchase stored as a payment (spend too high);
- a failed refund ("Refund of SAR 99 failed") stored as a refund on the device (spend too low) or as income by the server parser (income too high);
- a genuine refund or reversal stored with the wrong type: "تم استرجاع …" as a payment on the device, "Reversal of declined purchase" as a payment by the server parser, and every server-parsed refund as income instead of a refund.

The fixes stop new errors. They do not touch rows that are already stored, and they must not: changing a user's financial history without the user is out of policy.

## Proposal in one paragraph

A one-off, opt-in review list. On first launch of the fixed build, the device re-runs the current rule (`TransactionStateCues.isNotCompleted` and the current `ParserEngine` type) over the raw message text of confirmed, SMS-derived transactions that still carry it. Rows whose stored type disagrees with what the current rule says are listed as "may need a fix". Each row shows the original message, what is stored, and what the app would store today. The user acts per row: keep as is, move to review (excluded from totals, like a Smart Inbox item), or change the type. Nothing changes without that action. Every action can be undone.

## How candidates are found

Run once per replica, on device only, in a background pass after the database opens:

1. Select confirmed transactions with a non-empty `raw_message` and an SMS/capture source. Manual entries and file imports are skipped.
2. For each row, evaluate the CURRENT rule over `raw_message`:
   - `isNotCompleted(raw) == true` → candidate "this message reports no completed money movement";
   - otherwise, `ParserEngine.parse(raw)` gives a type different from the stored type in a way that changes totals (payment ↔ refund, refund ↔ income, payment ↔ income) → candidate "stored as X, reads as Y".
   - A row whose type the user has edited (or whose category provenance says the user chose it) is still listed, but marked "you changed this before" and never pre-selected.
3. Store the candidate ids and the verdict in a new local table (`historical_review_candidates`: transaction id, verdict, rule version, created at, resolved at, resolution). No transaction row is written.

Cost: one parse per eligible row; the parser already runs on an isolate with a 2 s timeout. For a few thousand rows this is seconds. Run it in pages so a large ledger does not block the UI.

## Where raw text is and is not retained

| Place | What is kept | For how long | Usable for this review |
|---|---|---|---|
| Device, `transactions.raw_message` | The full raw SMS for transactions captured on this device | No purge found: kept for the life of the row (until the user deletes it or removes data) | Yes |
| Device, Smart Inbox and suspected-duplicate rows | Raw text of items still under review | Until the item is resolved or deleted | Not needed (not counted in totals) |
| Device, rows pulled from the cloud ledger (`ledger_sync_service.dart` sets `rawMessage: ''`) | No raw text | — | No |
| Device, rows from file import / data portability (`rawMessage: ''`) | No raw text | — | No |
| Encrypted backup (`backup_snapshot_builder.dart`, `rawMessageExcluded: true`) | No raw text | — | No: a restored ledger has no raw text |
| Server, `processed_captures.sanitized_text` (iOS cloud capture) | Sanitized (redacted) text, never the raw SMS | Only while unconsumed; content is nulled at 168 hours after creation (migration 0112) and when consumed | No: gone long before a review could run |
| Server ledger (synced transactions) | No raw text column | — | No |

So the review can only work on the device that captured the message, and only for rows that were captured there and not restored from a backup or pulled from the cloud.

## What the user sees

- A single, dismissible card in the Transactions screen (the place the Smart Inbox banner already lives): "We improved how declined and refunded transactions are read. N older transactions may need a look." No card when N is 0.
- A list grouped by verdict, newest first. Each row: the original message, the stored type and amount, and the suggested reading ("this purchase was declined: it moved no money", "this refund failed", "this is a refund, not a payment").
- Per row, three actions: **Keep as is**, **Move to review** (the row leaves totals and appears as a Smart Inbox item, where the existing confirm/delete flow applies), **Change type** (only to the suggested type).
- Optional "Apply the suggestion to all" with a confirmation that states the number of rows and the total effect on this month's spend, refunds and income. It applies per-row actions; it is not a migration.
- The card can be dismissed for good; dismissing changes nothing.

## Nothing changes without the user

- The scan only writes the candidate table. No transaction, budget, goal or report value changes until the user acts on a row.
- No server write happens from the scan. A user action is an ordinary local edit, synced like any other edit.

## Undo

- Every action records the previous type and status in the candidate row (`resolution` and the prior values).
- "Undo" on a resolved row restores those values through the same repository path as a normal edit, so totals, budgets and sync update the usual way.
- Undo stays available from the review list until the user dismisses the list.

## Sync behaviour

- The scan is per replica and keyed by rule version, so it runs once per device per rule change, not on every launch.
- Two devices of the same account: only the device holding raw text can produce candidates. When the user acts on it, the edit syncs to the other devices as a normal edit. The other device never shows the card for rows it cannot read.
- If a row was edited elsewhere after the scan (sync pull with a newer version), the candidate is dropped rather than shown with stale data.
- A conflict between a review action and a concurrent edit follows the existing ledger conflict rules; the review adds no new conflict path.

## Rows without raw text

They cannot be judged and are not listed. The card says so once: "Transactions restored from a backup or synced from another device cannot be checked automatically." The existing manual tools (search, edit, delete) remain the remedy. Nothing is guessed from amount or merchant alone.

## Effort and risks

- Effort: roughly 3–5 engineer-days: one local table and migration (schema version bump), the background scan, one list screen with three actions and undo, l10n in Arabic and English, tests (scan verdicts from the shared `declined_cases.json`, no write without action, undo round trip, sync of an action, rows without raw text skipped).
- Risks:
  - False candidates: the rule still sends some real purchases to review (listed in KNOWN-LIMITATIONS). Because nothing is pre-applied, the cost is a row the user keeps.
  - Missed rows: wording the rule does not know, and every row without raw text.
  - User confusion when totals for past months move after an action; the confirmation states the effect before it is applied.
  - Budgets and achievements computed from past totals will change after an action; that is correct, but should be explained in the confirmation.
  - Performance on very large ledgers: paged scan, no UI blocking.

## What this deliberately does not do

- No automatic migration, deletion or retyping of stored rows, on the device or the server.
- No server-side scan: the server never holds the raw text, and keeps sanitized text only for at most 168 hours.
- No re-parsing of amounts, dates or merchants: only the not-completed verdict and the type that affects totals.
- No change to the backup format to start carrying raw text.
- No promise of completeness: the list helps the user find likely errors; it does not certify the ledger.
