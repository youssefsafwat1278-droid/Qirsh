import { assertEquals } from 'jsr:@std/assert@1';
import { clearDeadApnsToken, enqueueNotificationRetry, GENERIC_CAPTURE_PUSH, isDeadApnsToken, capturePushContent, transactionPushAlert } from './capture_push.ts';

Deno.test('only opted-in valid summaries expose transaction details', () => {
  const parsed = { amount: 250, currency: 'EGP', merchant: 'CARREFOUR', type: 'payment' };
  const alert = transactionPushAlert(parsed, 'en_EG');
  assertEquals(alert, { title: 'Purchase · 250.00 EGP', body: 'CARREFOUR' });
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
  const alert = transactionPushAlert(parsed, 'en_EG', { tzOffsetMinutes: 120 });
  assertEquals(alert?.title, 'Transfer sent · 1.00 EGP');
  assertEquals(alert?.body, 'Via InstaPay\nTransfers · 9 Nov, 6:45 PM');
  const arabic = transactionPushAlert(parsed, 'ar_EG', { tzOffsetMinutes: 120 });
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
  const parsed = { amount: 10, currency: 'EGP', type: 'payment', category: 'groceries',
    occurredAt: '2026-11-09T16:45:00Z' };
  assertEquals(transactionPushAlert(parsed, 'en')?.body, 'Groceries');
  assertEquals(transactionPushAlert({ ...parsed, occurredAt: 'invalid' }, 'en',
    { tzOffsetMinutes: 120 })?.body, 'Groceries');
  assertEquals(transactionPushAlert({ ...parsed, occurredAt: undefined }, 'en',
    { tzOffsetMinutes: 120, receivedAt: '2026-11-09T22:05:00Z' })?.body,
    'Groceries · 10 Nov, 12:05 AM');
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
