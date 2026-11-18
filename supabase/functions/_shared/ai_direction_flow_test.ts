import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { validateAiCandidate } from './ai_candidate_validator.ts';

// Closure round, follow-up 6 (4): the wording check reads the clause
// structure of the sentence that carries the booked amount (debit/credit flow,
// as DirectionSignal), so a correct answer is no longer contradicted by a
// deposit word on an outgoing transfer, a cue word in a merchant name, a
// refund or a footer; a real contradiction is still rejected. Synthetic only.

const check = (text: string, amount: number, type: string, direction: string, merchant?: string) =>
  validateAiCandidate({
    candidate: { amount, amount_text: amount.toFixed(2), currency: 'SAR', type, direction, merchant },
    sanitizedText: text,
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });

const correct: Array<[string, number, string, string]> = [
  ['Transfer of SAR 500.00 to Deposit Holdings Ltd from your account *1234 completed', 500, 'transfer', 'debit'],
  ['SAR 500.00 deposited to beneficiary Ali from your account *1234', 500, 'transfer', 'debit'],
  ['تم إيداع مبلغ 500.00 ريال في حساب المستفيد علي من حسابك 1234', 500, 'transfer', 'debit'],
  ['Purchase of SAR 80.00 at Refund Mart with card *1234', 80, 'payment', 'debit'],
  ['Purchase of SAR 80.00 at Salary Cafe with card *1234', 80, 'payment', 'debit'],
  ['Refund of SAR 80.00 from SHOP credited to your card *1234', 80, 'refund', 'credit'],
  ['Your purchase of SAR 80.00 at SHOP was refunded to card *1234', 80, 'refund', 'credit'],
  ['Purchase of SAR 80.00 at SHOP with card *1234. Never share your OTP with anyone.', 80, 'payment', 'debit'],
];
Deno.test('a points line equal to the amount and a cue-word merchant do not contradict', () => {
  const out = check('POS purchase SAR 45.00 at Salary Store. Credited points 45', 45, 'payment', 'debit',
    'Salary Store');
  assertEquals(out.accepted ? 'accepted' : out.reason, 'accepted');
});
Deno.test('a split credit (amount in its own sentence) is still a credit', () => {
  assertEquals(check('Your account *1234 was credited. Amount SAR 300.00 from SHOP', 300, 'payment', 'debit'),
    { accepted: false, reason: 'direction_contradiction' });
});
for (const [text, amount, type, direction] of correct) {
  Deno.test(`a correct answer is not contradicted: ${text}`, () => {
    const out = check(text, amount, type, direction);
    assertEquals(out.accepted ? 'accepted' : out.reason, 'accepted');
  });
}

const wrong: Array<[string, number, string, string]> = [
  ['Transfer of SAR 500.00 to Deposit Holdings Ltd from your account *1234 completed', 500, 'income', 'credit'],
  ['SAR 500.00 deposited to beneficiary Ali from your account *1234', 500, 'income', 'credit'],
  ['SAR 750.00 credited to your account *1234 from Ali', 750, 'payment', 'debit'],
  ['Purchase of SAR 80.00 at SHOP debited from card *1234', 80, 'refund', 'credit'],
  ['تم خصم 80.00 ريال من بطاقتك 1234 لدى المتجر', 80, 'income', 'credit'],
];
for (const [text, amount, type, direction] of wrong) {
  Deno.test(`a real contradiction is still rejected: ${type} for ${text}`, () => {
    assertEquals(check(text, amount, type, direction), { accepted: false, reason: 'direction_contradiction' });
  });
}
