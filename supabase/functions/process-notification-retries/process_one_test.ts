import { assert, assertEquals } from 'jsr:@std/assert@1';
import { processOne } from './process_one.ts';
import { captureContentLive, CAPTURE_RETENTION_MS } from '../process-ios-sms/capture_rpc_fake.ts';

const row = {
  id: 'retry-1',
  notification_log_id: 'log-1',
  install_id_hash: 'install-hash',
  payload_id: 'payload-1',
  attempt_number: 1,
  max_attempts: 5,
};

type RecordedUpdate = {
  table: string;
  values: Record<string, unknown>;
  filters: Array<[string, unknown]>;
};

type Fence = Record<string, unknown>;
const allowed: Fence = {
  allowed: true,
  apns_token: 'current-token',
  apns_environment: 'production',
  notification_type: 'needs_review',
};

// deno-lint-ignore no-explicit-any
function fakeSupabase(fence: Fence | null, rpcError = false, notification: unknown = null): { client: any; updates: RecordedUpdate[]; rpcs: unknown[] } {
  const updates: RecordedUpdate[] = [];
  const rpcs: unknown[] = [];
  const client = {
    rpc(fn: string, args: unknown) {
      rpcs.push({ fn, args });
      return Promise.resolve(rpcError ? { data: null, error: { message: 'boom' } } : { data: fence, error: null });
    },
    from(table: string) {
      let updateValues: Record<string, unknown> | null = null;
      const filters: Array<[string, unknown]> = [];
      let recorded = false;
      const builder = {
        select(_columns: string) { return builder; },
        maybeSingle() { return Promise.resolve({ data: { notification }, error: null }); },
        update(values: Record<string, unknown>) {
          updateValues = values;
          return builder;
        },
        eq(column: string, value: unknown) {
          filters.push([column, value]);
          return builder;
        },
        then(resolve: (value: unknown) => unknown, reject: (reason: unknown) => unknown) {
          if (updateValues != null && !recorded) {
            updates.push({ table, values: updateValues, filters: [...filters] });
            recorded = true;
          }
          return Promise.resolve({ data: null, error: null }).then(resolve, reject);
        },
      };
      return builder;
    },
  };
  return { client, updates, rpcs };
}

const resolved = (u: RecordedUpdate[]) =>
  u.some((x) => x.table === 'notification_retry_queue' && typeof x.values.resolved_at === 'string');
const noSend = () => {
  throw new Error('APNs must not be called');
};

Deno.test('retry runs the fence RPC for this capture', async () => {
  const fake = fakeSupabase(allowed);
  await processOne(fake.client, row, () => Promise.resolve({ ok: true, apnsId: 'a' } as const));
  assertEquals(fake.rpcs, [{
    fn: 'capture_retry_fence',
    args: { p_install_id_hash: 'install-hash', p_payload_id: 'payload-1' },
  }]);
});

Deno.test('fenced-out retries are dropped without APNs and map to a log error code', async () => {
  const cases: Array<[string, string]> = [
    ['credential_revoked', 'credential_revoked'],
    ['consent_revoked', 'consent_revoked'],
    ['owner_changed', 'owner_changed'],
    ['not_pending', 'capture_not_pending'], // consumed / expired / retryable
    ['expired', 'capture_expired'], // F1: past the 7-day logical expiry fence
    ['no_token', 'retry_unsendable'],
    ['no_content', 'retry_unsendable'],
    ['gone', 'retry_unsendable'],
  ];
  for (const [reason, code] of cases) {
    const fake = fakeSupabase({ allowed: false, reason });
    const outcome = await processOne(fake.client, row, noSend);
    assertEquals(outcome, 'exhausted', reason);
    assert(resolved(fake.updates), reason);
    assertEquals(
      fake.updates.some((u) => u.table === 'notification_logs' && u.values.error_code === code),
      true,
      reason,
    );
  }
});

Deno.test('a push already sent by another path is resolved quietly, no APNs, no failure logged', async () => {
  const fake = fakeSupabase({ allowed: false, reason: 'already_sent' });
  assertEquals(await processOne(fake.client, row, noSend), 'skipped');
  assert(resolved(fake.updates));
  assertEquals(fake.updates.some((u) => u.table === 'notification_logs'), false);
});

Deno.test('fence infrastructure failure leaves the claimed row alone (no APNs, nothing resolved)', async () => {
  for (const fake of [fakeSupabase(null, true), fakeSupabase(null)]) {
    assertEquals(await processOne(fake.client, row, noSend), 'retrying');
    assertEquals(fake.updates.length, 0);
  }
});

Deno.test('allowed retry sends a GENERIC alert to the fence-returned (current) token', async () => {
  const fake = fakeSupabase(allowed);
  const sent: Array<Record<string, unknown>> = [];
  const outcome = await processOne(fake.client, row, (message) => {
    sent.push({ ...message });
    return Promise.resolve({ ok: true, apnsId: 'apns-1' } as const);
  });
  assertEquals(outcome, 'sent');
  assertEquals(sent.length, 1);
  assertEquals(sent[0].token, 'current-token');
  assertEquals(sent[0].environment, 'production');
  assertEquals(sent[0].title, '');
  assertEquals(sent[0].body, 'New transaction captured');
  assertEquals(sent[0].notificationType, 'needs_review');
  assert(fake.updates.some((u) => u.table === 'processed_captures' && typeof u.values.apns_push_sent_at === 'string'));
  assert(resolved(fake.updates));
});

Deno.test('retry preserves the opted-in summary instead of replacing it with generic text', async () => {
  const alert = { title: 'New purchase 🛒', body: '250.00 EGP · CARREFOUR' };
  const fake = fakeSupabase(allowed, false, { pushAlert: alert });
  const sent: Array<Record<string, unknown>> = [];
  assertEquals(await processOne(fake.client, row, (message) => {
    sent.push({ ...message });
    return Promise.resolve({ ok: true, apnsId: 'a' } as const);
  }), 'sent');
  assertEquals(sent[0].body, alert.body);
  assertEquals(sent[0].title, alert.title);
});

Deno.test('a hidden Arabic notification keeps its language on retry', async () => {
  const fake = fakeSupabase(allowed, false, { pushLanguage: 'ar' });
  const sent: Array<Record<string, unknown>> = [];
  assertEquals(await processOne(fake.client, row, (message) => {
    sent.push({ ...message });
    return Promise.resolve({ ok: true, apnsId: 'a' } as const);
  }), 'sent');
  assertEquals(sent[0].title, '');
  assertEquals(sent[0].body, 'تم رصد عملية جديدة');
});

Deno.test('dead token (410 Unregistered) is cleared by compare-and-swap and the retry ends', async () => {
  const fake = fakeSupabase(allowed);
  const outcome = await processOne(fake.client, row, () =>
    Promise.resolve({ ok: false, reason: 'apns_410_Unregistered', httpStatus: 410, errorCode: 'Unregistered' } as const));
  assertEquals(outcome, 'exhausted');
  const clear = fake.updates.find((u) => u.table === 'capture_devices');
  assert(clear, 'token cleared');
  assertEquals(clear.values.apns_token, null);
  assertEquals(clear.filters, [['install_id_hash', 'install-hash'], ['apns_token', 'current-token']]);
  assert(resolved(fake.updates));
});

Deno.test('transient failure reschedules the same row (no second queue row), token kept', async () => {
  const fake = fakeSupabase(allowed);
  const outcome = await processOne(fake.client, row, () =>
    Promise.resolve({ ok: false, reason: 'apns_503_ServiceUnavailable', httpStatus: 503, errorCode: 'ServiceUnavailable' } as const));
  assertEquals(outcome, 'retrying');
  assertEquals(fake.updates.some((u) => u.table === 'capture_devices'), false);
  const q = fake.updates.find((u) => u.table === 'notification_retry_queue');
  assert(q && typeof q.values.next_attempt_at === 'string' && q.values.resolved_at === undefined);
  assertEquals(q.values.attempt_number, 2);
});

Deno.test('exhausted attempts stop retrying', async () => {
  const fake = fakeSupabase(allowed);
  const outcome = await processOne(fake.client, { ...row, attempt_number: 4 }, () =>
    Promise.resolve({ ok: false, reason: 'apns_503_x', httpStatus: 503, errorCode: 'ServiceUnavailable' } as const));
  assertEquals(outcome, 'exhausted');
  assert(resolved(fake.updates));
});

// F1: capture_retry_fence refuses a notification whose capture is past the 7-day logical
// expiry fence (database clock, judged inside the RPC). This models the SQL authority
// (supabase/tests/capture_expiry_fence.sql); the worker must fail closed on it.
Deno.test('F1 boundaries: retry fence modelled on the DB clock; expired -> dropped, no APNs, no content; 7d-1ms still sends', async () => {
  const created = Date.parse('2026-10-01T00:00:00Z');
  for (
    const [name, delta, live] of [['7d-1ms', -1, true], ['exactly 7d', 0, false], ['7d+1ms', 1, false]] as const
  ) {
    const dbNow = created + CAPTURE_RETENTION_MS + delta;
    const fence = captureContentLive(created, dbNow) ? allowed : { allowed: false, reason: 'expired' };
    const fake = fakeSupabase(fence);
    const sent: unknown[] = [];
    const outcome = await processOne(fake.client, row, (m) => {
      sent.push(m);
      return Promise.resolve({ ok: true, apnsId: 'a' } as const);
    });
    if (live) {
      assertEquals([outcome, sent.length], ['sent', 1], name);
    } else {
      assertEquals([outcome, sent.length], ['exhausted', 0], name);
      assert(resolved(fake.updates), name);
      // the worker only drops: it neither writes capture content nor marks the capture sent
      assertEquals(fake.updates.some((u) => u.table === 'processed_captures'), false, name);
      assertEquals(
        fake.updates.some((u) => u.table === 'notification_logs' && u.values.error_code === 'capture_expired'),
        true,
        name,
      );
    }
  }
});
