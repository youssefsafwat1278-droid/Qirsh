// The duplicate fingerprint of an owner-bound capture is scoped to its account.
// Reported on device: account B received "possible duplicate" for a bank
// message account A had captured on the same phone.
import { assertEquals, assertNotEquals } from 'https://deno.land/std@0.224.0/assert/mod.ts';
import { duplicateFingerprintBase } from './index.ts';

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';
const parsed = { amount: 57.25, currency: 'egp', merchant: 'Coffee Corner', last4: '4521' };

Deno.test('the same message on two accounts of one device is not one fingerprint', () => {
  assertNotEquals(duplicateFingerprintBase(parsed, A), duplicateFingerprintBase(parsed, B));
});

Deno.test('the same message on the same account still collides', () => {
  assertEquals(duplicateFingerprintBase(parsed, A), duplicateFingerprintBase({ ...parsed }, A));
  // The uid is compared as an identity, not as typed.
  assertEquals(duplicateFingerprintBase(parsed, A), duplicateFingerprintBase(parsed, ` ${A.toUpperCase()} `));
});

Deno.test('an ownerless (legacy) capture keeps the device-wide fingerprint', () => {
  const legacy = duplicateFingerprintBase(parsed);
  assertEquals(legacy, duplicateFingerprintBase(parsed, ''));
  assertEquals(legacy.startsWith('57.25|EGP|'), true);
  assertNotEquals(legacy, duplicateFingerprintBase(parsed, A));
});

Deno.test('a different amount, currency, merchant or card is a different fingerprint', () => {
  const base = duplicateFingerprintBase(parsed, A);
  assertNotEquals(base, duplicateFingerprintBase({ ...parsed, amount: 57.26 }, A));
  assertNotEquals(base, duplicateFingerprintBase({ ...parsed, currency: 'SAR' }, A));
  assertNotEquals(base, duplicateFingerprintBase({ ...parsed, merchant: 'Bakery' }, A));
  assertNotEquals(base, duplicateFingerprintBase({ ...parsed, last4: '9999' }, A));
});
