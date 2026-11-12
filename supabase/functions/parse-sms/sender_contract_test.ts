import { assertEquals } from 'jsr:@std/assert@1';

// The client no longer sends `sender_id` to parse-sms. That is only safe while
// the server neither requires nor reads it; no committed version ever has.
// Pin it: a future read of the sender here must come with a client change.
Deno.test('parse-sms never reads a sender field (client omits sender_id)', () => {
  const src = Deno.readTextFileSync(new URL('./index.ts', import.meta.url));
  assertEquals(src.match(/sender/gi), null);
});
