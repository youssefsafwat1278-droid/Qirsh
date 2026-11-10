import { assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { buildNotification, type CaptureStatus, type ParsedCapture } from './index.ts';

// A physical iPhone received "عملية مشابهة ⚠️" carrying amount, merchant, card
// and time but nothing about whether money LEFT or ENTERED the account — even
// though the parse had `direction` and `type` all along. `typeTitle` exposed it
// only in the `processed` title; the other two templates hardcode theirs. These
// pin the shared line so all three stay consistent.

const RECEIVED = '2026-09-07T19:30:00.000Z';

function parsed(over: Partial<ParsedCapture> = {}): ParsedCapture {
  return {
    amount: 25,
    amount_text: '25.00',
    currency: 'SAR',
    type: 'payment',
    direction: 'debit',
    merchant: 'QIRSH TEST',
    last4: '1234',
    category: 'other',
    confidence: 0.85,
    ...over,
  };
}

function body(status: CaptureStatus, over: Partial<ParsedCapture> = {}): string {
  return buildNotification(status, parsed(over), 'SNB', RECEIVED, 180, 'ar').body;
}

Deno.test('processed notification states the nature', () => {
  assertStringIncludes(body('processed'), 'النوع: مصروف');
});

Deno.test('needs_review notification states the nature', () => {
  assertStringIncludes(body('needs_review'), 'النوع: مصروف');
});

Deno.test('duplicate notification states the nature — the reported defect', () => {
  const n = buildNotification('duplicate', parsed(), 'SNB', RECEIVED, 180, 'ar');
  assertEquals(n.type, 'suspicious_duplicate');
  assertEquals(n.title, 'عملية مشابهة ⚠️'); // title deliberately unchanged
  assertStringIncludes(n.body, 'النوع: مصروف');
  assertStringIncludes(n.body, 'موجودة مسبقاً؟');
});

Deno.test('debit maps to مصروف', () => {
  assertStringIncludes(body('processed', { direction: 'debit', type: 'payment' }), 'النوع: مصروف');
});

Deno.test('credit maps to دخل, on every template', () => {
  for (const status of ['processed', 'needs_review', 'duplicate'] as CaptureStatus[]) {
    assertStringIncludes(body(status, { direction: 'credit', type: 'income' }), 'النوع: دخل');
  }
});

Deno.test('direction credit wins even when type says payment', () => {
  // detectDirection is the grounded signal; type only refines it.
  assertStringIncludes(body('processed', { direction: 'credit', type: 'payment' }), 'النوع: دخل');
});

Deno.test('transfer maps to تحويل', () => {
  assertStringIncludes(body('processed', { type: 'transfer', direction: 'debit' }), 'النوع: تحويل');
});

Deno.test('withdrawal and refund keep their domain labels', () => {
  assertStringIncludes(body('processed', { type: 'withdrawal' }), 'النوع: سحب نقدي');
  assertStringIncludes(body('processed', { type: 'refund' }), 'النوع: استرداد');
});

Deno.test('an unclassified movement stays silent rather than guessing', () => {
  // Asserting "مصروف" on an unknown direction would invent a fact.
  const text = body('processed', { type: 'unknown', direction: 'unknown' });
  assertEquals(text.includes('النوع:'), false);
});

Deno.test('a known category still renders', () => {
  assertStringIncludes(body('processed', { category: 'cafes' }), 'التصنيف: مقاهي ☕');
  assertStringIncludes(body('duplicate', { category: 'groceries' }), 'التصنيف: بقالة 🛒');
});

Deno.test('category "other" remains omitted', () => {
  for (const status of ['processed', 'needs_review', 'duplicate'] as CaptureStatus[]) {
    assertEquals(body(status, { category: 'other' }).includes('التصنيف:'), false);
  }
});

Deno.test('the processed title is unchanged', () => {
  assertEquals(
    buildNotification('processed', parsed(), 'SNB', RECEIVED, 180, 'ar').title,
    'تم رصد عملية شراء 🛒',
  );
});

Deno.test('a needs_review capture with no amount keeps its generic body', () => {
  // The nature line rides on detailLines, so this path must stay untouched.
  const n = buildNotification(
    'needs_review',
    { merchant: 'X', direction: 'debit', type: 'payment' },
    'SNB',
    RECEIVED,
    180,
    'ar',
  );
  assertEquals(n.body, 'افتح قرش لمراجعة الرسالة.');
});

Deno.test('English capture copy covers processed, duplicate, review and rejected messages', () => {
  for (const status of ['processed', 'duplicate', 'needs_review', 'rejected'] as CaptureStatus[]) {
    const n = buildNotification(status, parsed(), 'SNB', RECEIVED, 180, 'en');
    assertEquals(/[\u0600-\u06ff]/.test(n.title + n.body), false, status);
  }
  assertStringIncludes(buildNotification('duplicate', parsed(), 'SNB', RECEIVED, 180, 'en').body,
    'Open Qirsh to review');
});
