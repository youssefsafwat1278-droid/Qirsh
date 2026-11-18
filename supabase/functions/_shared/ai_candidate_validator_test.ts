import { assertEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import {
  type AiCandidate,
  type LocalCandidate,
  validateAiCandidate,
} from './ai_candidate_validator.ts';
import cases from './fixtures/ai_candidate_cases.json' with { type: 'json' };

// The SAME file is run through the app's AiCandidateValidator by
// app/test/engine/ai/ai_candidate_shared_fixtures_test.dart. Do not weaken a
// case here to make one side pass; a real disagreement must be reported.
//
// Deliberate server-only strictness NOT in the shared file (spec-mandated):
// currency whitelist, AI `direction` field contradiction, amount/amount_text
// agreement, ASCII-only canonical amount_text.

for (const c of cases as Array<{
  name: string;
  sanitized_text: string;
  received_at: string;
  local: LocalCandidate | null;
  ai: AiCandidate;
  expected: {
    accepted: boolean;
    reason?: string;
    currency?: string;
    merchant?: string | null;
    occurred_at_kept?: boolean;
  };
}>) {
  Deno.test(`shared AI candidate fixture: ${c.name}`, () => {
    const out = validateAiCandidate({
      candidate: c.ai,
      sanitizedText: c.sanitized_text,
      receivedAt: c.received_at,
      local: c.local,
    });
    assertEquals(out.accepted, c.expected.accepted);
    if (!out.accepted) {
      assertEquals(out.reason, c.expected.reason);
    } else {
      assertEquals(out.currency, c.expected.currency);
      assertEquals(out.merchant, c.expected.merchant ?? null);
      assertEquals(out.occurredAt != null, c.expected.occurred_at_kept ?? false);
    }
  });
}

// Closure round (parser currency table): INR is now on the list, so this
// case uses NOK — a table ISO code persisted Money cannot hold.
Deno.test('server-only: currency outside the whitelist is rejected even when grounded', () => {
  const out = validateAiCandidate({
    candidate: { amount: 75, amount_text: '75.00', currency: 'NOK' },
    sanitizedText: 'Paid 75.00 NOK at SHOP',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'currency_not_whitelisted' });
});

Deno.test('server-only: AI direction field contradicting wording is rejected', () => {
  const out = validateAiCandidate({
    candidate: { amount: 500, amount_text: '500.00', currency: 'EGP', type: 'unknown', direction: 'debit' },
    sanitizedText: 'تم إيداع 500.00 EGP في حسابك',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'direction_contradiction' });
});

Deno.test('server-only: amount and amount_text must agree', () => {
  const out = validateAiCandidate({
    candidate: { amount: 75, amount_text: '750.00', currency: 'SAR' },
    sanitizedText: 'Paid 75.00 SAR / 750.00 SAR',
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });
  assertEquals(out, { accepted: false, reason: 'amount_text_mismatch' });
});

Deno.test('AI confidence is not part of the candidate contract', () => {
  const base = { amount: 75, amount_text: '75.00', currency: 'SAR', direction: 'debit' };
  const text = 'Paid 75.00 SAR at SHOP';
  const run = (confidence: number) =>
    validateAiCandidate({
      candidate: { ...base, confidence } as AiCandidate,
      sanitizedText: text,
      receivedAt: '2026-06-16T12:00:00Z',
      local: null,
    });
  assertEquals(run(0.01), run(0.99));
});

// T-S13: amount_text must be a whole numeric token of the source text; digits
// of a date, time, last4, account number or a larger number never ground it.
const lookalike = (text: string, amount: number, amountText: string) =>
  validateAiCandidate({
    candidate: { amount, amount_text: amountText, currency: 'SAR', direction: 'debit' },
    sanitizedText: text,
    receivedAt: '2026-06-16T12:00:00Z',
    local: null,
  });

Deno.test('T-S13: a date component cannot ground an amount', () => {
  assertEquals(lookalike('Purchase 250.00 SAR on 2026-06-16', 16, '16'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
});

Deno.test('T-S13: a time component cannot ground an amount', () => {
  assertEquals(lookalike('Purchase 250.00 SAR at 14:30', 30, '30'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
});

Deno.test('T-S13: last4 digits cannot ground an amount', () => {
  assertEquals(lookalike('Purchase 99.00 SAR card *1234', 1234, '1234'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
  assertEquals(lookalike('Purchase 99.00 SAR card ending 1234', 1234, '1234'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
});

Deno.test('T-S13: a fragment of a larger number cannot ground an amount', () => {
  assertEquals(lookalike('Purchase 1250.50 SAR', 250.5, '250.50'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
  assertEquals(lookalike('Purchase 99.00 SAR account 9876543210', 98765, '98765'), {
    accepted: false,
    reason: 'amount_not_grounded',
  });
});

Deno.test('T-S13: amount_text must itself occur as a token', () => {
  assertEquals(lookalike('Purchase 75.00 SAR', 75, '75'), { accepted: false, reason: 'amount_text_not_grounded' });
});

Deno.test('T-S13: grouped and Arabic-Indic renderings still ground', () => {
  assertEquals(lookalike('Purchase 1,250.50 SAR', 1250.5, '1250.50').accepted, true);
  assertEquals(lookalike('خصم ١٬٢٥٠٫٥٠ SAR', 1250.5, '1250.50').accepted, true);
  assertEquals(lookalike('Purchase 75.00 SAR on 2026-06-16 at 14:30', 75, '75.00').accepted, true);
});

Deno.test('direction is required: missing, unknown or transfer-only is unresolved', () => {
  const run = (extra: Partial<AiCandidate>, local: LocalCandidate | null = null) =>
    validateAiCandidate({
      candidate: { amount: 75, amount_text: '75.00', currency: 'SAR', ...extra },
      sanitizedText: 'Transaction of 75.00 SAR at SHOP ONE',
      receivedAt: '2026-06-16T12:00:00Z',
      local,
    });
  const unresolved = { accepted: false as const, reason: 'direction_unresolved' };
  assertEquals(run({}), unresolved);
  assertEquals(run({ type: 'unknown', direction: 'sideways' }), unresolved);
  assertEquals(run({ type: 'transfer' }), unresolved);
  assertEquals(run({ type: 'payment' }).accepted, true);
  assertEquals(run({ direction: 'credit' }).accepted, true);
  // A known deterministic direction resolves it, as parse.ts does.
  const local = { amount: 75, currency: 'SAR', direction: 'debit' };
  assertEquals(run({}, local).accepted, true);
});
