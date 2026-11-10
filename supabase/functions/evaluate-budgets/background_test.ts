import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { budgetWindow } from '../_shared/budget_capture_spend.ts';
import { handleEvaluateBudgets } from './index.ts';

Deno.env.set('ENGAGEMENT_WORKER_SECRET', 'test-worker');
Deno.env.set('SUPABASE_URL', 'https://example.supabase.co');
Deno.env.set('SUPABASE_SERVICE_ROLE_KEY', 'test-service');

async function run(options: { delivered?: boolean; hidden?: boolean; valid?: boolean; legacyLocalLink?: boolean; threshold?: number; spend?: number; lastSpent?: number; locale?: string } = {}) {
  const pushes: Record<string, unknown>[] = [], updates: unknown[] = [];
  const now = new Date().toISOString();
  const client = { from(table: string) {
    let selected = '', update: unknown, accountFilter = '';
    const result = () => {
      let data: unknown = [];
      if (table === 'user_budgets') data = [{ id: 'b', user_id: 'u', currency: 'EGP',
        category_id: 'all_expenses', amount: 100, period: 'monthly', server_account_id: 'a',
        alert_threshold_percent: options.threshold,
        last_notified_spent_amount: options.lastSpent ?? 0,
        last_notified_period_start: new Date(budgetWindow('monthly', Date.now(), 120)[0]).toISOString() }];
      if (table === 'capture_devices') data = [{ apns_token: 'test', apns_environment: 'sandbox', last_seen_at: now }];
      if (table === 'user_settings') data = { country: 'EG', notifications_json: { hideLockScreenContent: options.hidden } };
      if (table === 'user_accounts') data = [{ id: 'a', local_id: 'local', currency: 'EGP' }];
      if (table === 'user_transactions' && selected === 'amount,transaction_type' && options.legacyLocalLink) {
        // The historical row has no server ID. It is returned only through
        // the fallback scoped to this owner's resolved local account.
        if (accountFilter.includes('server_account_id.is.null') && accountFilter.includes('local_account_id.eq."local"')) {
          data = [{ amount: '15.00', transaction_type: 'expense' }];
        }
      }
      if (table === 'processed_captures') data = selected === 'payload_id'
        ? (options.valid === false ? null : { payload_id: 'c' })
        : [{ payload_id: 'c', parsed: { amount_text: String(options.spend ?? 80), currency: 'EGP', direction: 'debit', type: 'payment', occurredAt: now } }];
      if (update) { updates.push(update); data = []; }
      return { data, error: null };
    };
    const query = {
      select(s: string) { selected = s; return query; },
      eq() { return query; }, is() { return query; }, not() { return query; },
      in() { return query; }, gte() { return query; }, lt() { return query; },
      order() { return query; }, limit() { return query; },
      or(value: string) { accountFilter = value; return query; },
      update(value: unknown) { update = value; return query; },
      maybeSingle() { return Promise.resolve(result()); },
      then(resolve: (value: unknown) => unknown) { return Promise.resolve(result()).then(resolve); },
    };
    return query;
  } };
  const response = await handleEvaluateBudgets(new Request('https://example.test', {
    method: 'POST', headers: { authorization: 'Bearer test-worker', 'content-type': 'application/json' },
    body: JSON.stringify({ record: { user_id: 'u' }, capturePayloadId: 'c', locale: options.locale ?? 'en', tzOffsetMinutes: 120 }),
  }), {
    createClient: (() => client) as unknown as NonNullable<Parameters<typeof handleEvaluateBudgets>[1]>['createClient'],
    sendCapturePush: (async (message) => {
      pushes.push(message);
      return options.delivered === false
        ? { ok: false, reason: 'offline', httpStatus: 503, errorCode: 'ServiceUnavailable' }
        : { ok: true, apnsId: 'test' };
    }),
  });
  return { response, pushes, updates };
}

Deno.test('recent Shortcut activity does not suppress a closed-app budget push', async () => {
  const r = await run();
  assertEquals(r.response.status, 200);
  assertEquals(r.pushes.length, 1);
  assertStringIncludes(String(r.pushes[0].body), '80.00');
  assertEquals(r.updates.length, 1);
});
Deno.test('failed APNs send never marks the budget tier delivered', async () => {
  const r = await run({ delivered: false });
  assertEquals(r.pushes.length, 1);
  assertEquals(r.updates.length, 0);
});
Deno.test('hidden budget push omits financial details', async () => {
  const r = await run({ hidden: true });
  assertEquals(r.pushes[0].body, 'Open Qirsh to review your budget.');
});
Deno.test('a nonexistent or foreign capture cannot produce a budget push', async () => {
  const r = await run({ valid: false });
  assertEquals(r.response.status, 409);
  assertEquals(r.pushes.length, 0);
});

Deno.test('background totals include pre-mapping ledger rows from the same account', async () => {
  const r = await run({ legacyLocalLink: true });
  assertEquals(r.pushes.length, 1);
  assertStringIncludes(String(r.pushes[0].body), '95.00');
  assertEquals(r.pushes[0].title, 'Budget almost used up');
});

for (const threshold of [70, 80, 90, 95, 100]) {
  Deno.test(`custom ${threshold}% warns on crossing, never before`, async () => {
    const before = await run({threshold, spend: threshold - 1});
    assertEquals(before.pushes.length, 0);
    const crossed = await run({threshold, spend: threshold});
    assertEquals(crossed.pushes.length, 1);
    assertEquals(crossed.pushes[0].title, threshold === 100 ? 'Budget exceeded' : `Budget reached ${threshold}%`);
  });
}
Deno.test('custom threshold repeats are suppressed but escalation still fires', async () => {
  assertEquals((await run({threshold:70, spend:80, lastSpent:70})).pushes.length, 0);
  const escalation = await run({threshold:70, spend:90, lastSpent:80});
  assertEquals(escalation.pushes[0].title, 'Budget almost used up');
  assertEquals((await run({threshold:70, spend:105, lastSpent:100})).pushes.length, 0);
  assertEquals((await run({threshold:70, spend:110, lastSpent:100})).pushes.length, 1);
});
Deno.test('Arabic warning uses the selected percentage', async () => {
  const r = await run({threshold:70, spend:70, locale:'ar'});
  assertStringIncludes(String(r.pushes[0].title), '٧٠');
});
