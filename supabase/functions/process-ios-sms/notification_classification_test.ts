import { assert, assertEquals, assertStringIncludes } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { buildNotification, type CaptureStatus, outcomeOf, type ParsedCapture } from './index.ts';

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
  // 3.12: the status line says it needs review before it is recorded.
  assertStringIncludes(n.body, 'قد تكون مكررة: تحتاج مراجعتك في قِرش قبل تسجيلها.');
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

Deno.test('a known category still renders when it is the user\'s saved rule (3.12)', () => {
  assertStringIncludes(body('processed', { category: 'cafes', ruleCategory: 'cafes' } as Partial<ParsedCapture>),
    'التصنيف: مقاهي ☕');
  assertStringIncludes(body('duplicate', { category: 'groceries', ruleCategory: 'groceries' } as Partial<ParsedCapture>),
    'التصنيف: بقالة 🛒');
});

Deno.test('3.12: a parser/model category is a proposal and is never shown as final', () => {
  for (const status of ['processed', 'needs_review', 'duplicate'] as CaptureStatus[]) {
    assertEquals(body(status, { category: 'cafes' }).includes('التصنيف:'), false, status);
    const en = buildNotification(status, parsed({ category: 'cafes' }), 'SNB', RECEIVED, 180, 'en');
    assertEquals(/Caf/.test(en.title + en.body), false, status);
  }
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
  assertEquals(n.body, 'تحتاج مراجعتك في قِرش قبل تسجيلها.');
});

Deno.test('English capture copy covers processed, duplicate, review and rejected messages', () => {
  for (const status of ['processed', 'duplicate', 'needs_review', 'rejected'] as CaptureStatus[]) {
    const n = buildNotification(status, parsed(), 'SNB', RECEIVED, 180, 'en');
    assertEquals(/[\u0600-\u06ff]/.test(n.title + n.body), false, status);
  }
  assertStringIncludes(buildNotification('duplicate', parsed(), 'SNB', RECEIVED, 180, 'en').body,
    'needs your review in Qirsh before it is recorded');
});

// The rejected alert names the sender. It travels through APNs to the lock
// screen, so only an alphanumeric bank brand may appear there — never a phone
// number or a numeric short code.
Deno.test('rejected alert shows a bank brand sender but never a numeric/phone sender', () => {
  const rejected = (sender: string) => buildNotification('rejected', {}, sender, RECEIVED, 180, 'ar').body;
  assertStringIncludes(rejected('SNB'), 'رسالة من SNB');
  // 3.12: a message the server did not understand is kept for the user to
  // check (the device reviews it, V1-088): "not recorded yet", not "paste it".
  const unread = 'لم تُسجَّل بعد: افتح قِرش للتحقق من رسالة البنك هذه.';
  for (const s of ['+966551234567', '0551234567', '01012345678', '19623', '٠٥٥١٢٣٤٥٦٧', 'AB 0551234567']) {
    const out = rejected(s);
    assertEquals(out, unread, s);
  }
  assertEquals(rejected(''), unread);
});

// ── Decision 3.12: the wording follows what happened to the capture ─────────

const NO_MOVEMENT = { parsed: {} as ParsedCapture };

Deno.test('3.12: outcome per status; declined and not-completed messages are "not recorded"', () => {
  assertEquals(outcomeOf('processed', 'x', NO_MOVEMENT), 'queued');
  assertEquals(outcomeOf('duplicate', 'x', NO_MOVEMENT), 'duplicate');
  assertEquals(outcomeOf('needs_review', 'x', NO_MOVEMENT), 'review');
  assertEquals(outcomeOf('rejected', 'Purchase of SAR 45.00 at Test Diner was declined', NO_MOVEMENT), 'declined');
  assertEquals(outcomeOf('rejected', 'Hello', { parsed: { parserSource: 'ai_ignored' } as ParsedCapture }), 'excluded');
  assertEquals(outcomeOf('rejected', 'Hello', NO_MOVEMENT), 'unread');
});

Deno.test('3.12: a processed capture is "not recorded yet" — the device records it, and may still review it', () => {
  for (const [locale, line] of [['en', 'Not recorded yet: Qirsh checks it before adding it.'],
    ['ar', 'لم تُسجَّل بعد: يتحقق منها قِرش قبل إضافتها.']]) {
    const n = buildNotification('processed', parsed(), 'SNB', RECEIVED, 180, locale);
    assertEquals(n.type, 'new_transaction'); // build 147 keys on this
    assertEquals(n.captureOutcome, 'queued');
    assertEquals(n.body.split('\n').at(-1), line, locale);
  }
});

Deno.test('3.12: a declined message says not recorded, with its details, in both languages', () => {
  const declined = { ...parsed(), category: 'restaurants' };
  const en = buildNotification('rejected', declined, 'SNB', RECEIVED, 180, 'en', 'declined');
  assertEquals(en.type, 'received');
  assertEquals(en.title, 'Bank message not recorded');
  assertStringIncludes(en.body, 'Purchase · 25.00 SAR');
  assertStringIncludes(en.body, 'Card/account ••1234');
  assert(en.body.endsWith('Not recorded: the message says it was declined or failed.'));
  const ar = buildNotification('rejected', declined, 'SNB', RECEIVED, 180, 'ar', 'declined');
  assertEquals(ar.title, 'رسالة بنك لم تُسجَّل');
  assertStringIncludes(ar.body, 'المبلغ: 25 SAR');
  assertStringIncludes(ar.body, 'البطاقة: ****1234');
  assert(ar.body.endsWith('لم تُسجَّل: تفيد الرسالة بأن العملية مرفوضة أو لم تتم.'));
  for (const n of [en, ar]) assertEquals(/Restaurants|مطاعم/.test(n.body), false);
});

Deno.test('3.12: never more than the last four digits of a card or account', () => {
  for (const last4 of ['12345678', '123', 'ab12']) {
    for (const locale of ['en', 'ar']) {
      const n = buildNotification('processed', parsed({ last4 }), 'SNB', RECEIVED, 180, locale);
      assertEquals(n.body.includes(last4), false, `${locale}/${last4}`);
    }
  }
});
