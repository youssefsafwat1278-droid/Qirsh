import { assertEquals } from 'jsr:@std/assert@1';
import {
  analysisGenericAlert, analysisOutcomeAlert, analysisStateOf, clearDeadApnsToken, enqueueNotificationRetry,
  GENERIC_CAPTURE_PUSH, isDeadApnsToken, capturePushContent, REASON_LINES, transactionPushAlert, withPushDelivery,
} from './capture_push.ts';

// 3.12: every detailed alert ends with what the server knows; nothing is "recorded".
const QUEUED_EN = 'Not recorded yet: Qirsh checks it before adding it.';

Deno.test('only opted-in valid summaries expose transaction details', () => {
  const parsed = { amount: 250, currency: 'EGP', merchant: 'CARREFOUR', type: 'payment' };
  const alert = transactionPushAlert(parsed, 'en_EG');
  assertEquals(alert, { title: 'Purchase · 250.00 EGP', body: `CARREFOUR\n${QUEUED_EN}` });
  assertEquals(capturePushContent({ pushAlert: alert }), alert);
  assertEquals(capturePushContent({ title: 'detail', body: '250 EGP' }), GENERIC_CAPTURE_PUSH);
  assertEquals(capturePushContent(null), GENERIC_CAPTURE_PUSH);
  assertEquals(transactionPushAlert({ ...parsed, amount: NaN }, 'en'), undefined);
  assertEquals(transactionPushAlert({ ...parsed, currency: null }, 'en'), undefined);
  assertEquals(transactionPushAlert({ ...parsed, direction: 'credit' }, 'ar_EG')?.title, 'إيداع وارد · 250.00 EGP');
});

Deno.test('transfer preview includes the grounded payment network, category and local time', () => {
  const parsed = { amount: 1, currency: 'EGP', type: 'transfer', direction: 'debit',
    category: 'transfers', occurredAt: '2026-11-09T16:45:00Z',
    rawMessage: 'IPN transfer sent from 1938. Ref# abc123. Balance EGP 9000.', last4: '1938' };
  // The category shown is the user's saved rule (3.12), passed as finalCategory.
  const alert = transactionPushAlert(parsed, 'en_EG', { tzOffsetMinutes: 120, finalCategory: 'transfers' });
  assertEquals(alert?.title, 'Transfer sent · 1.00 EGP');
  assertEquals(alert?.body, `Via InstaPay\nTransfers · 9 Nov, 6:45 PM\n${QUEUED_EN}`);
  const arabic = transactionPushAlert(parsed, 'ar_EG', { tzOffsetMinutes: 120, finalCategory: 'transfers' });
  assertEquals(arabic?.title, 'تحويل صادر · 1.00 EGP');
  assertEquals(arabic?.body.startsWith('عبر InstaPay\nتحويلات · '), true);
  assertEquals(arabic?.body.includes('6:45'), true);
  for (const privateValue of ['1938', 'abc123', '9000', 'IPN transfer']) {
    assertEquals(JSON.stringify(alert).includes(privateValue), false);
  }
});

Deno.test('incoming transfers and refunds keep their own transaction names', () => {
  const incoming = { amount: 10, currency: 'EGP', direction: 'credit' };
  assertEquals(transactionPushAlert({ ...incoming, type: 'transfer' }, 'en')?.title,
    'Transfer received · 10.00 EGP');
  assertEquals(transactionPushAlert({ ...incoming, type: 'refund' }, 'ar')?.title,
    'استرداد · 10.00 EGP');
});

Deno.test('missing timezone or malformed clocks are omitted; receipt time is a valid fallback', () => {
  const parsed = { amount: 10, currency: 'EGP', type: 'payment',
    occurredAt: '2026-11-09T16:45:00Z' };
  const rule = { finalCategory: 'groceries' };
  assertEquals(transactionPushAlert(parsed, 'en', rule)?.body, `Groceries\n${QUEUED_EN}`);
  assertEquals(transactionPushAlert({ ...parsed, occurredAt: 'invalid' }, 'en',
    { ...rule, tzOffsetMinutes: 120 })?.body, `Groceries\n${QUEUED_EN}`);
  assertEquals(transactionPushAlert({ ...parsed, occurredAt: undefined }, 'en',
    { ...rule, tzOffsetMinutes: 120, receivedAt: '2026-11-09T22:05:00Z' })?.body,
    `Groceries · 10 Nov, 12:05 AM\n${QUEUED_EN}`);
});

Deno.test('generic capture push text is the manifest Q3 wording and carries no data', () => {
  assertEquals(GENERIC_CAPTURE_PUSH, { title: '', body: 'New transaction captured' });
  assertEquals(capturePushContent({ pushLanguage: 'ar', body: 'private details' }),
    { title: '', body: 'تم رصد عملية جديدة' });
  assertEquals(capturePushContent({ pushLanguage: 'en', body: 'private details' }), GENERIC_CAPTURE_PUSH);
});

Deno.test('dead-token detection: 410 and the permanent token errors only', () => {
  assertEquals(isDeadApnsToken({ httpStatus: 410, errorCode: 'Unregistered' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 400, errorCode: 'BadDeviceToken' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 410, errorCode: 'ExpiredToken' }), true);
  assertEquals(isDeadApnsToken({ httpStatus: 503, errorCode: 'ServiceUnavailable' }), false);
  assertEquals(isDeadApnsToken({ httpStatus: null, errorCode: 'timeout' }), false);
  assertEquals(isDeadApnsToken({ httpStatus: 403, errorCode: 'InvalidProviderToken' }), false);
});

Deno.test('token clear is a compare-and-swap on the failing token', async () => {
  const calls: unknown[] = [];
  const builder = {
    update: (v: unknown) => (calls.push(['update', v]), builder),
    eq: (c: string, v: unknown) => (calls.push(['eq', c, v]), builder),
  };
  await clearDeadApnsToken({ from: () => builder } as never, 'h', 'dead');
  const eqs = calls.filter((c) => (c as unknown[])[0] === 'eq');
  assertEquals(eqs, [['eq', 'install_id_hash', 'h'], ['eq', 'apns_token', 'dead']]);
  assertEquals(((calls[0] as unknown[])[1] as Record<string, unknown>).apns_token, null);
});

Deno.test('retry enqueue is an ignore-duplicates upsert keyed on notification_log_id', async () => {
  let args: unknown[] = [];
  await enqueueNotificationRetry({
    from: () => ({ upsert: (...a: unknown[]) => ((args = a), Promise.resolve({})) }),
  } as never, {
    notificationLogId: 'log',
    installIdHash: 'h',
    payloadId: 'p',
    maxAttempts: 5,
    nextAttemptAt: 't',
    lastErrorCode: 'timeout',
  });
  assertEquals(args[1], { onConflict: 'notification_log_id', ignoreDuplicates: true });
  assertEquals((args[0] as Record<string, unknown>).notification_log_id, 'log');
});

// ── Decision 3.12: the push says what the server knows, never "recorded" ──

Deno.test('3.12: a parser or model category is a proposal and never appears; a saved rule does', () => {
  const parsed = { amount: 45, currency: 'SAR', merchant: 'Test Diner', type: 'payment', category: 'restaurants' };
  for (const locale of ['en', 'ar']) {
    const proposed = transactionPushAlert(parsed, locale)!;
    assertEquals(/Restaurants|مطاعم/.test(proposed.body), false, locale);
  }
  assertEquals(transactionPushAlert(parsed, 'en', { finalCategory: 'restaurants' })!.body.includes('Restaurants'), true);
  assertEquals(transactionPushAlert(parsed, 'ar', { finalCategory: 'restaurants' })!.body.includes('مطاعم'), true);
});

Deno.test('3.12: each outcome has its own status line in both languages; none says recorded', () => {
  const parsed = { amount: 45, currency: 'SAR', merchant: 'Test Diner', type: 'payment' };
  const lines = new Set<string>();
  for (const outcome of ['queued', 'review', 'duplicate', 'declined', 'excluded', 'unread'] as const) {
    for (const locale of ['en', 'ar']) {
      const body = transactionPushAlert(parsed, locale, { outcome })!.body;
      const status = body.split('\n').at(-1)!;
      lines.add(status);
      assertEquals(/[؀-ۿ]/.test(status), locale === 'ar', `${outcome}/${locale}`);
      // "Not recorded" / "before it is recorded" only; never a claim that it was.
      assertEquals(/(?<!not |before it is )recorded(?!\s*yet)/i.test(status.replace(/Not recorded/g, '')), false, status);
      assertEquals(/تم تسجيل|سُجِّلت|سجلت/.test(status), false, status);
    }
  }
  assertEquals(lines.size, 12);
  assertEquals(transactionPushAlert(parsed, 'en', { outcome: 'declined' })!.body.endsWith(
    'Not recorded: the message says it was declined or failed.'), true);
  assertEquals(transactionPushAlert(parsed, 'ar', { outcome: 'review' })!.body.endsWith(
    'تحتاج مراجعتك في قِرش قبل تسجيلها.'), true);
});

Deno.test('3.12: the masked last four appears only when requested and only as exactly four digits', () => {
  const parsed = { amount: 45, currency: 'SAR', type: 'payment', last4: '4521' };
  assertEquals(transactionPushAlert(parsed, 'en')!.body.includes('4521'), false);
  assertEquals(transactionPushAlert(parsed, 'en', { includeLast4: true })!.body.includes('Card/account ••4521'), true);
  assertEquals(transactionPushAlert(parsed, 'ar', { includeLast4: true })!.body.includes('البطاقة/الحساب: ••4521'), true);
  for (const last4 of ['45210', '452', '4521 ', '٤٥٢١', '1234567812345678']) {
    const body = transactionPushAlert({ ...parsed, last4 }, 'en', { includeLast4: true })!.body;
    assertEquals(/Card\/account|\d{3,}/.test(body), false, last4);
  }
});

Deno.test('3.12: the generic (no-detail) alert follows the outcome, never "captured" for a review or exclusion', () => {
  assertEquals(capturePushContent({ type: 'new_transaction' }), GENERIC_CAPTURE_PUSH);
  assertEquals(capturePushContent({ type: 'suspicious_duplicate' }).body,
    'Possible duplicate: needs your review in Qirsh before it is recorded.');
  assertEquals(capturePushContent({ type: 'needs_review', pushLanguage: 'ar' }).body,
    'تحتاج مراجعتك في قِرش قبل تسجيلها.');
  assertEquals(capturePushContent({ type: 'received' }).body,
    'Not recorded yet: open Qirsh to check this bank message.');
  assertEquals(capturePushContent({ type: 'received', captureOutcome: 'declined' }).body,
    'Not recorded: the message says it was declined or failed.');
  assertEquals(capturePushContent({ type: 'received', captureOutcome: 'excluded', pushLanguage: 'ar' }).body,
    'لم تُسجَّل: لا توجد عملية مكتملة في هذه الرسالة (مثل عملية معلّقة أو إشعار).');
  for (const n of [{ type: 'received' }, { type: 'needs_review' }, { type: 'suspicious_duplicate' }]) {
    assertEquals(capturePushContent(n).body.includes('captured'), false);
  }
});

Deno.test('3.12: the detailed alert stays within the APNs limits it is checked against', () => {
  const alert = transactionPushAlert({ amount: 1234567.89, currency: 'SAR', type: 'transfer', direction: 'credit',
    merchant: 'M'.repeat(500), occurredAt: '2026-11-09T16:45:00Z', last4: '4521' }, 'ar',
  { tzOffsetMinutes: 180, outcome: 'excluded', finalCategory: 'transfers' })!;
  assertEquals(alert.title.length <= 120 && alert.body.length <= 600, true);
  assertEquals(capturePushContent({ pushAlert: alert }), alert);
});

// Decision 3.12 privacy bound for a detailed alert: the only digit run of four
// or more allowed is the masked suffix "••dddd"; amounts are grouped by commas.
function assertNoIdentifierDigits(text: string): void {
  const rest = text.replace(/••[0-9]{4}(?![0-9])/g, '');
  assertEquals(/[0-9٠-٩۰-۹]{4,}/.test(rest), false, text);
}

Deno.test('3.12 negative: no longer digit run, PAN, IBAN, OTP or raw text in a detailed alert', () => {
  const raw = 'Purchase of SAR 45.00 at SHOP card 4111111111111111 OTP 482913 IBAN SA0380000000608010167519';
  const cases = [
    { last4: '41111111' },
    { last4: '4111111111111111' },
    { merchant: 'SHOP 4111111111111111' },
    { merchant: 'SA0380000000608010167519' },
    { merchant: 'Pay ٤١١١١١١١١١١١١١١١' },
    { merchant: 'SHOP', last4: '4521' },
  ];
  for (const extra of cases) {
    for (const locale of ['en', 'ar']) {
      const alert = transactionPushAlert({ amount: 45, currency: 'SAR', type: 'payment', rawMessage: raw, ...extra },
        locale, { includeLast4: true, outcome: 'queued' })!;
      const wire = JSON.stringify(alert);
      assertNoIdentifierDigits(wire);
      for (const secret of ['4111111111111111', '482913', 'SA0380000000608010167519', 'Purchase of', 'OTP']) {
        assertEquals(wire.includes(secret), false, `${JSON.stringify(extra)}/${locale}: ${secret}`);
      }
    }
  }
  // The checker itself rejects what it must reject.
  for (const bad of ['Card ••12345', 'card 4111111111111111', 'OTP 482913', '12345']) {
    let failed = false;
    try { assertNoIdentifierDigits(bad); } catch { failed = true; }
    assertEquals(failed, true, bad);
  }
});

Deno.test('3.12: hidden-details / generic pushes carry no digits at all', () => {
  for (const type of ['new_transaction', 'needs_review', 'suspicious_duplicate', 'received']) {
    for (const captureOutcome of [undefined, 'queued', 'review', 'duplicate', 'declined', 'excluded', 'unread']) {
      for (const pushLanguage of ['en', 'ar']) {
        const alert = capturePushContent({ type, captureOutcome, pushLanguage, title: 'x 4521', body: '45.00 SAR' });
        assertEquals(/[0-9٠-٩]/.test(alert.title + alert.body), false, `${type}/${captureOutcome}`);
      }
    }
  }
});

// ── Gemini-first phase 2: one push per financial outcome ─────────────────────

Deno.test('phase 2: the outcome of each status and reason code; non-financial codes are silent', () => {
  assertEquals(analysisStateOf('processed', null), 'saved');
  assertEquals(analysisStateOf('duplicate', 'duplicate'), 'not_added');
  for (const code of ['declined', 'pending', 'payment_reminder', 'own_account']) {
    assertEquals(analysisStateOf('rejected', code), 'not_added', code);
  }
  for (const code of ['amount_mismatch', 'direction_conflict', 'unclear', null]) {
    assertEquals(analysisStateOf('rejected', code), 'needs_confirmation', String(code));
  }
  for (const code of ['otp', 'promo', 'not_financial', 'balance_only']) {
    assertEquals(analysisStateOf('rejected', code), null, code);
  }
});

Deno.test('phase 2: reason sentences and headings are the app ARB strings, in both languages', () => {
  const arb = (lang: string) => JSON.parse(Deno.readTextFileSync(
    new URL(`../../../app/lib/l10n/app_${lang}.arb`, import.meta.url))) as Record<string, string>;
  const en = arb('en'), ar = arb('ar');
  const key = (code: string) => 'inboxReason' + code.split('_').map((w) => w[0].toUpperCase() + w.slice(1)).join('');
  for (const [code, [enLine, arLine]] of Object.entries(REASON_LINES)) {
    assertEquals(enLine, en[key(code)], code);
    assertEquals(arLine, ar[key(code)], code);
  }
  for (const [state, arbKey] of [['saved', 'outcomeSavedTitle'], ['not_added', 'outcomeNotAddedTitle'],
    ['needs_confirmation', 'outcomeNeedsConfirmationTitle']] as const) {
    assertEquals(analysisGenericAlert(state, 'declined', false).title, en[arbKey]);
    assertEquals(analysisGenericAlert(state, 'declined', true).title, ar[arbKey]);
  }
});

Deno.test('phase 2: a saved purchase reads "Saved: expense 250.00 EGP" with merchant and the user category only', () => {
  const parsed = { amount: 250, currency: 'EGP', merchant: 'CARREFOUR', type: 'payment', direction: 'debit' };
  assertEquals(analysisOutcomeAlert(parsed, 'ar', { state: 'saved', finalCategory: 'groceries' }),
    { title: 'سُجّل مصروف 250.00 EGP', body: 'CARREFOUR · بقالة' });
  assertEquals(analysisOutcomeAlert(parsed, 'en', { state: 'saved' }),
    { title: 'Saved: expense 250.00 EGP', body: 'CARREFOUR' });
});

Deno.test('phase 2: a transfer to a person is "transfer to a friend" and never names them', () => {
  const alert = analysisOutcomeAlert({ amount: 500, currency: 'EGP', merchant: 'Ahmed Ali', type: 'transfer',
    direction: 'debit', counterpartyKind: 'person' }, 'ar', { state: 'saved' });
  assertEquals(alert.title, 'سُجّل تحويل لصديق 500.00 EGP');
  assertEquals(JSON.stringify(alert).includes('Ahmed'), false);
});

Deno.test('phase 2: not added / needs confirmation carry the reason sentence; hidden details carry no digits', () => {
  const parsed = { amount: 250, currency: 'EGP', type: 'payment', direction: 'debit' };
  assertEquals(analysisOutcomeAlert(parsed, 'ar', { state: 'not_added', reasonCode: 'declined' }),
    { title: 'لم تُضَف · 250.00 EGP', body: 'عملية مرفوضة أو لم تكتمل، ولم يتحرك أي مبلغ' });
  assertEquals(analysisOutcomeAlert({}, 'en', { state: 'needs_confirmation', reasonCode: 'amount_mismatch' }),
    { title: 'Needs your confirmation',
      body: 'The amount does not match the message; confirm it before recording' });
  for (const analysisState of ['saved', 'not_added', 'needs_confirmation']) {
    for (const pushLanguage of ['en', 'ar']) {
      const alert = capturePushContent({ type: 'received', analysisState, reasonCode: 'declined', pushLanguage,
        title: 'x 4521', body: '45.00 SAR' });
      assertEquals(/[0-9٠-٩]/.test(alert.title + alert.body), false, `${analysisState}/${pushLanguage}`);
    }
  }
});

Deno.test('phase 2: the delivery mark touches only a notification that states an outcome', () => {
  assertEquals(withPushDelivery({ title: 't', analysisState: 'saved' }, true),
    { notification: { title: 't', analysisState: 'saved', pushed: true } });
  assertEquals(withPushDelivery({ title: 't', type: 'new_transaction' }, false), {});
  assertEquals(withPushDelivery(null, false), {});
});
