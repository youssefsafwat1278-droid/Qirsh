// Dev siblings c/d/e on the server gate. App twin:
// app/test/engine/ai/movement_amounts_test.dart (meaningHoldReason).
import { assert, assertEquals, assertNotEquals } from 'jsr:@std/assert@1';
import { gatedMeaning, meaningRejectionOf } from './meaning_gate.ts';
import declinedTable from './declined_cases.json' with { type: 'json' };
import { nonTransactionVerdict } from '../_shared/ai_understanding.ts';

Deno.test('several purchases in one message are held as multiple_amounts', () => {
  for (
    const text of [
      'Card *1111 used: SAR 64.00 at Oak Bakery; SAR 210.50 at Pine Books.',
      'عمليتا شراء ببطاقتك 4444: 130.00 ريال لدى متجر النخيل و 45.00 ريال لدى مقهى السدر',
      'تم خصم ١٨٠ جنيه لدى مكتبة النور و ٤٢٠ جنيه لدى متجر الورد',
    ]
  ) {
    const m = gatedMeaning(text, undefined, 64);
    assertEquals([m.kind, m.disposition, m.reason], ['multiple_events', 'review', 'multiple_amounts'], text);
  }
});

Deno.test('one purchase with a balance or a footer is not held', () => {
  for (
    const text of [
      'Purchase SAR 120.00 at Oak Bakery card *1111. Available balance SAR 3,400.00',
      'Salary SAR 12,000.00 credited to account *4521. Previous salary SAR 11,500.00',
      'Purchase USD 20.00 at WEBSHOP, charged SAR 75.40',
    ]
  ) {
    assertEquals(gatedMeaning(text).disposition, 'record', text);
  }
});

Deno.test('a tip form records only at the total it states', () => {
  const text = 'You paid SAR 115.00 at Lark Cafe (SAR 100.00 + SAR 15.00 tip) with card *5555.';
  assertEquals(gatedMeaning(text).disposition, 'review');
  assertEquals(gatedMeaning(text, undefined, 100).disposition, 'review');
  assertEquals(gatedMeaning(text, undefined, 115).disposition, 'record');
});

Deno.test('the model can say own-account transfer or several movements; both are never a transaction', () => {
  for (const type of ['own_account_transfer', 'multiple_transactions']) {
    assertEquals(nonTransactionVerdict({ is_transaction: true, message_type: type, amount: 5000 }), {
      is_transaction: false,
      message_type: type,
    });
  }
});

// Follow-up 13: the server twin of AiCandidateValidator.meaningRejectionOf.
// Same texts and reasons as app/test/engine/ai/movement_amounts_test.dart.
Deno.test('a non-record meaning rejects, the not-completed reason first', () => {
  const filler = Array(260).fill('Thank you for banking with us.').join(' ');
  const cases: Array<[string, string | null]> = [
    ['Purchase of SAR 100.00 at SHOPX declined', 'transaction_not_completed'],
    [`Purchase of SAR 100.00 at SHOPX declined. ${filler}`, 'transaction_not_completed'],
    ['Purchase of SAR 100.00 at SHOPX approved. Previous attempt declined.', 'transaction_not_completed'],
  ];
  for (const [text, expected] of cases) {
    assertEquals(meaningRejectionOf(text, 100), expected, text);
    assertNotEquals(gatedMeaning(text, undefined, 100).disposition, 'record', text);
  }
});

// Follow-up 13 — server/device parity on the whole declined case table. The
// device table (app/test/engine/parser/declined_state_cues_table_test.dart)
// requires both device validators to reject every row whose device outcome is
// not_completed with `transaction_not_completed`, and never that reason
// otherwise; the server rule must give the same verdict on the same column,
// and the server gate must hold every such row before any model answer.
Deno.test('declined table: server meaning rejection matches the device rule on every row', () => {
  type Row = { text: string; expect: string; device?: string; server?: string };
  let review = 0;
  for (const c of declinedTable.cases as Row[]) {
    const device = (c.device ?? c.expect) === 'not_completed';
    assertEquals((c.server ?? c.expect) === 'not_completed', device, `sides differ: ${c.text}`);
    const reason = meaningRejectionOf(c.text, 100);
    if (device) {
      review++;
      assertEquals(reason, 'transaction_not_completed', c.text);
      assertNotEquals(gatedMeaning(c.text, undefined, 100).disposition, 'record', c.text);
    } else {
      assertNotEquals(reason, 'transaction_not_completed', c.text);
    }
  }
  assert(review > 0);
});
