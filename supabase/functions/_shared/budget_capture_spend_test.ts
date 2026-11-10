import { assertEquals } from 'jsr:@std/assert@1';
import { budgetWindow, pendingCaptureSpend } from './budget_capture_spend.ts';
const from = Date.parse('2026-11-01T00:00:00Z'), to = Date.parse('2026-12-01T00:00:00Z');
const accounts = [
  { id: 'mina', local_id: 'mina-local', currency: 'EGP' },
  { id: 'sofa', local_id: 'sofa-local', currency: 'EGP' },
];
const budget = { currency: 'EGP', category_id: 'all_expenses', server_account_id: 'mina' };
const capture = { payload_id: 'a', parsed: { amount_text: '80.00', currency: 'EGP',
  direction: 'debit', type: 'payment', category: 'groceries', occurredAt: '2026-11-09T10:00:00Z' } };
Deno.test('closed-app capture contributes before ledger import', () => {
  assertEquals(pendingCaptureSpend([capture], accounts, new Set(), budget, from, to), 80);
});
Deno.test('imported capture never counts twice', () => {
  assertEquals(pendingCaptureSpend([capture], accounts, new Set(['a']), budget, from, to), 0);
});
Deno.test('same currency does not leak spend into another account budget', () => {
  assertEquals(pendingCaptureSpend([capture], accounts, new Set(),
    { ...budget, server_account_id: 'sofa' }, from, to), 0);
});
Deno.test('category, period and direction remain scoped', () => {
  assertEquals(pendingCaptureSpend([capture], accounts, new Set(),
    { ...budget, category_id: 'fuel' }, from, to), 0);
  assertEquals(pendingCaptureSpend([capture], accounts, new Set(), budget, to, to + 86400000), 0);
  assertEquals(pendingCaptureSpend([{ ...capture, parsed: { ...capture.parsed, direction: 'credit' } }],
    accounts, new Set(), budget, from, to), 0);
});
Deno.test('budget period uses local midnight and Saturday week', () => {
  assertEquals(budgetWindow('monthly', Date.parse('2026-11-09T10:00:00Z'), 120),
    [Date.parse('2026-10-31T22:00:00Z'), Date.parse('2026-11-30T22:00:00Z')]);
  assertEquals(budgetWindow('weekly', Date.parse('2026-11-09T10:00:00Z'), 120)[0],
    Date.parse('2026-11-06T22:00:00Z'));
});
