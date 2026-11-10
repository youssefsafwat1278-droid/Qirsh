import { assertEquals } from 'jsr:@std/assert@1';
import { fingerprintTimeKeys } from './capture_fingerprint.ts';

Deno.test('sms_body timestamps stay exact — no tolerance window', () => {
  const keys = fingerprintTimeKeys('2026-07-13T10:00:00.000Z', 'sms_body');
  assertEquals(keys, ['2026-07-13T10:00:00.000Z']);
});

Deno.test('received_at retains the exact receipt time', () => {
  const iso = '2026-07-13T10:00:00.000Z';
  assertEquals(fingerprintTimeKeys(iso, 'received_at'), [iso]);
});

Deno.test('distinct identical purchases seconds apart do not collide', () => {
  const first = fingerprintTimeKeys('2026-07-13T10:04:30.000Z', 'received_at');
  const rerun = fingerprintTimeKeys('2026-07-13T10:05:10.000Z', 'received_at');
  // Equal money/merchant with a distinct receipt time is a separate event.
  assertEquals(rerun.includes(first[0]), false);
});

Deno.test('distinct receipts across an old bucket boundary do not collide', () => {
  const first = fingerprintTimeKeys('2026-07-13T10:09:59.000Z', 'received_at');
  const rerun = fingerprintTimeKeys('2026-07-13T10:10:05.000Z', 'received_at');
  assertEquals(rerun.includes(first[0]), false);
});

Deno.test('same instant expressed with another offset still matches', () => {
  assertEquals(fingerprintTimeKeys('2026-07-13T12:00:00+02:00', 'sms_body'),
    fingerprintTimeKeys('2026-07-13T10:00:00Z', 'sms_body'));
});

Deno.test('distinct receipts well apart never share a candidate key', () => {
  const a = fingerprintTimeKeys('2026-07-13T10:00:00.000Z', 'received_at');
  const b = fingerprintTimeKeys('2026-07-13T11:00:00.000Z', 'received_at');
  assertEquals(a.some((key) => b.includes(key)), false);
});

Deno.test('unparseable received_at falls back to the exact string', () => {
  assertEquals(fingerprintTimeKeys('not-a-date', 'received_at'), ['not-a-date']);
});
