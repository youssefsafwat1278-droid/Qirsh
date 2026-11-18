# Round 4 — independent verification by a Codex reviewer (Astra)

Reviewer: OpenAI Codex CLI codex-cli 0.155.1, model requested `gpt-6-astra` (the requested `gpt-6.2-astra` is not offered to this account), reasoning effort high, read-only brief, commit `a86298fc`, 2026-11-18T17:11:44.877Z. The reviewer's sandbox could run Deno (server code) but not Flutter or Xcode: device, Swift and restore conclusions marked R come from reading. Report reproduced verbatim below; it is an AI review, not an approval.

---

Model: **GPT-6-based Codex**, identified by developer context; the exact runtime model identifier is not exposed.

Verdicts: **Instruction 1 REJECT; instruction 2 REJECT; instruction 3 REJECT.**

Executed offline: baseline/HEAD comparisons, **100 fresh English/Arabic probes**, and captured stubbed-model requests. Selected HEAD tests: **211 passed**. Of 130 new money-table tests, **60 fail against baseline**. No network calls.

E = Deno execution; R = Dart/Swift reading.

| Original reproduction | Status | Evidence |
|---|---|---|
| PRIV-1/PRIV-1r, SP-16 | Exact cases fixed; broader leaks remain | E/R |
| MASK-1, MASK-0 | Fixed | E/R |
| CUE-1 | Exact cases fixed; variants fail | E/R |
| HOLD-1 | Partly: FX-fee total still unresolved | E/R |
| FT-1, NEW-2r | Footer gates fixed; some deterministic transfers remain unresolved | E/R |
| PRE-AT008 | Server holds; device neutral-transfer correction present | E/R |
| PRE-RF009 | Original direction cases fixed | E/R |
| VAL-1 | Fixed, including Arabic reversed totals | E/R |
| SM-01, SM-03, NEW-1 | Remain closed on original texts | E/R |
| Gemini OTP/“confirm”, ambiguous operation, fee, cancelled-operation refund | Fixed | E/R |
| SP-01, SP-12, SP-17, SP-19 | Local recovery/UI fixed; deletion/sync incomplete | R |

New findings below are executed unless marked R:

- **AR-01 — S1, remaining privacy gaps.** “حوالة واردة 123 ريال من حساب هاني عادل 7788” sends both name and suffix to the model. “Payment of SAR 109 to fadi nasser via Mada” sends the name. Both should redact.
- **AR-02 — S1.** “حوالة 152 ريال إلى هاني عادل بانتظار التأكيد” becomes “حوالة 152 ريال إلى: [REDACTED]”: pending status disappears; both handler modes accept a completed-model answer and store payment 152. Expected review.
- **AR-03 — S1, regression.** “Your expected refund of SAR 73.00 may have been credited to your account *4521”: baseline review → HEAD processed refund/credit 73. Uncertainty requires review.
- **AR-04 — S1, remaining completion gaps.** “Purchase SAR 63.00 at Kudu card *4521. Merchant confirmation outstanding”; “شراء 68 ريال لدى نون بطاقة 4521 لم يتم تأكيد العملية”; “تم تعليق شراء 70 ريال لدى جرير لحين تأكيد التاجر”; “Purchase SAR 82.00 at Jarir card *4521 is scheduled for tomorrow”. All become processed debits; none confirms completed movement.
- **AR-05 — S1, remaining negation gap.** “Refund of SAR 71.00 has not been credited to your card *4521” and “لم يتم رد مبلغ 77 ريال عن عملية شراء لدى نون” become processed credits; expected review.
- **AR-06 — S3, remaining over-hold.** “Purchase SAR 91.00 at Jarir card *4521. Your refund request for a previous order is pending” is rejected as pending. “Purchase SAR 90.00 at Panda card *4521. Refunds are pending for other purchases” is also held. Expected completed purchases.
- **AR-07 — S3.** “Transfer SAR 148 to Fadi Nasser yesterday” loses “yesterday”; “تم تحويل 151 ريال إلى هاني عادل أمس” loses “أمس”. Date words must survive.
- **AR-08 — S2, R.** A backup deletion for JARIR is ignored when the destination holds its old rule. Imported tombstones/“Leave out” enqueue no deletion; sync accepts stale live rules without checking tombstones, resurrecting them.
- **AR-09 — S2, R.** Restore shopping@Nov17 over restaurants@Nov15; pull unconsumed restaurants@Nov16: sync overwrites shopping, ignoring timestamps, and backfill skips that merchant. Expected newer restored edit retained.
- **AR-10 — S2, R.** Same-category pulls skip timestamp updates; an older, different-category backup can subsequently win. Pulled deletions also get re-stamped “now” by deletion triggers, falsely blocking newer backup edits.

Tests: **FT1b, HOLD1b4, HOLD1a2, HOLD1a4, RF4b, CAN10a, CAN10b, CAN10c, CAN10d each describe completed movements.** But the blanket label-based exemption can hide mislabeled regressions. Three fu5 review pins were removed; transfer-suffix assertions and permitted-digit exceptions widened. Shared redaction lists match, but parity fixtures omit these failing variants.

Not executed: Flutter, Swift/Xcode, device records/totals, restore/sync, migration, account switching. Reading supports category precedence, legacy choices, repeated restore, and wipe ordering; runtime verification remains outstanding. **Scratch removed; final git status clean.**
