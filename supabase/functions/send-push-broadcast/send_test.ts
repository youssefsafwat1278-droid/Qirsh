import { assert, assertEquals } from 'jsr:@std/assert@1';
import { sendApnsAlert } from '../_shared/apns.ts';
import {
  broadcastMessagesEnabled,
  handleSendPushBroadcast,
  pickBroadcastLanguage,
  type SendPushBroadcastDependencies,
} from './send.ts';

const BROADCAST_ID = '6f1c1d1e-0000-4000-8000-000000000001';
const ADMIN = '6f1c1d1e-0000-4000-8000-0000000000aa';

type Device = {
  hash: string;
  token: string | null;
  environment: string | null;
  inAudience: boolean;
  language: string | null;
  notificationsJson: string | null;
};
type Delivery = {
  id: string;
  hash: string;
  status: 'pending' | 'sending' | 'sent' | 'failed' | 'skipped';
  attempts: number;
  lastRunId: string | null;
  errorCode: string | null;
  language: string | null;
};

/// In-memory stand-in for the two sender RPCs with the migration's semantics:
/// claim takes pending / failed-with-attempts-left rows not attempted by this
/// run, finish moves only a 'sending' row.
// deno-lint-ignore no-explicit-any -- test double for the loosely typed Edge client.
function fakeStore(devices: Device[]): { client: any; deliveries: Delivery[]; cleared: string[] } {
  const deliveries: Delivery[] = devices.map((d, i) => ({
    id: `delivery-${i}`,
    hash: d.hash,
    status: 'pending',
    attempts: 0,
    lastRunId: null,
    errorCode: null,
    language: null,
  }));
  const cleared: string[] = [];
  const client = {
    rpc(fn: string, args: Record<string, unknown>) {
      if (fn === 'claim_push_broadcast_deliveries') {
        assertEquals(args.p_actor, ADMIN);
        const picked = deliveries
          .filter((x) => ['pending', 'failed'].includes(x.status) && x.attempts < 5 && x.lastRunId !== args.p_run_id)
          .slice(0, args.p_limit as number);
        for (const x of picked) {
          x.status = 'sending';
          x.lastRunId = args.p_run_id as string;
        }
        return Promise.resolve({
          data: picked.map((x) => {
            const d = devices.find((v) => v.hash === x.hash)!;
            return {
              delivery_id: x.id,
              device_hash: x.hash,
              attempts: x.attempts,
              in_audience: d.inAudience,
              token: d.inAudience ? d.token : null,
              environment: d.inAudience ? d.environment : null,
              settings_language: d.language,
              notifications_json: d.notificationsJson,
            };
          }),
          error: null,
        });
      }
      if (fn === 'finish_push_broadcast_delivery') {
        const x = deliveries.find((v) => v.id === args.p_delivery_id && v.status === 'sending');
        if (x) {
          x.status = args.p_status as Delivery['status'];
          x.errorCode = args.p_error_code as string | null;
          x.attempts = args.p_exhaust ? Math.max(x.attempts, 5) : x.attempts + (args.p_count_attempt ? 1 : 0);
          x.language = (args.p_language as string | null) ?? x.language;
        }
        return Promise.resolve({ data: x != null, error: null });
      }
      throw new Error(`unexpected rpc ${fn}`);
    },
    from(table: string) {
      const filters: Record<string, unknown> = {};
      let update: Record<string, unknown> | null = null;
      const builder = {
        select() {
          return builder;
        },
        update(values: Record<string, unknown>) {
          update = values;
          return builder;
        },
        eq(column: string, value: unknown) {
          filters[column] = value;
          return builder;
        },
        maybeSingle() {
          assertEquals(table, 'push_broadcasts');
          return Promise.resolve({
            data: filters.id === BROADCAST_ID
              ? {
                id: BROADCAST_ID,
                title_ar: 'عنوان',
                title_en: 'Title',
                body_ar: 'نص',
                body_en: 'Body',
                deep_link: '/budgets',
              }
              : null,
            error: null,
          });
        },
        then(resolve: (v: unknown) => unknown) {
          if (table === 'capture_devices' && update) cleared.push(filters.install_id_hash as string);
          return Promise.resolve({ data: null, error: null }).then(resolve);
        },
      };
      return builder;
    },
  };
  return { client, deliveries, cleared };
}

type Sent = Parameters<typeof sendApnsAlert>[0];

function deps(
  // deno-lint-ignore no-explicit-any -- test double
  client: any,
  sendAlert: SendPushBroadcastDependencies['sendAlert'],
  admin = true,
): SendPushBroadcastDependencies {
  let run = 0;
  return {
    createServiceClient: () => client,
    authenticateAdmin: () =>
      Promise.resolve(
        admin ? { ok: true as const, userId: ADMIN } : { ok: false as const, status: 403, error: 'not_authorized' },
      ),
    sendAlert,
    newRunId: () => `run-${++run}`,
  };
}

const request = (broadcastId = BROADCAST_ID) =>
  new Request('http://local/send-push-broadcast', {
    method: 'POST',
    headers: { authorization: 'Bearer admin-jwt', 'content-type': 'application/json' },
    body: JSON.stringify({ broadcast_id: broadcastId }),
  });

const device = (hash: string, extra: Partial<Device> = {}): Device => ({
  hash,
  token: `tok-${hash}`,
  environment: 'sandbox',
  inAudience: true,
  language: 'ar',
  notificationsJson: null,
  ...extra,
});

const accept = (sent: Sent[]) => (m: Sent) => {
  sent.push(m);
  return Promise.resolve({ ok: true as const, apnsId: `apns-${sent.length}` });
};

Deno.test('language: English only for an English app language, Arabic otherwise', () => {
  assertEquals(pickBroadcastLanguage('en'), 'en');
  assertEquals(pickBroadcastLanguage('EN-us'), 'en');
  assertEquals(pickBroadcastLanguage('ar'), 'ar');
  assertEquals(pickBroadcastLanguage(null), 'ar');
  assertEquals(pickBroadcastLanguage('fr'), 'ar');
});

Deno.test('preference: Messages from Qirsh defaults ON; only an explicit false is OFF', () => {
  assert(broadcastMessagesEnabled(null));
  assert(broadcastMessagesEnabled('{"budgetWarning":false}'));
  assert(broadcastMessagesEnabled('{not json'));
  assert(!broadcastMessagesEnabled('{"marketingMessages":false}'));
});

Deno.test('each device gets the text in its account language', async () => {
  const store = fakeStore([device('ar1'), device('en1', { language: 'en' })]);
  const sent: Sent[] = [];
  const res = await handleSendPushBroadcast(request(), deps(store.client, accept(sent)));
  assertEquals(res.status, 200);
  const byToken = Object.fromEntries(sent.map((m) => [m.token, m]));
  assertEquals(byToken['tok-ar1'].title, 'عنوان');
  assertEquals(byToken['tok-ar1'].body, 'نص');
  assertEquals(byToken['tok-en1'].title, 'Title');
  assertEquals(byToken['tok-en1'].body, 'Body');
  assertEquals(store.deliveries.map((d) => d.language), ['ar', 'en']);
});

Deno.test('the push carries the broadcast route and no capture payloadId', async () => {
  const store = fakeStore([device('a')]);
  const sent: Sent[] = [];
  await handleSendPushBroadcast(request(), deps(store.client, accept(sent)));
  assertEquals(sent[0].data, {
    notificationType: 'qirsh_broadcast',
    source: 'qirsh_broadcast',
    broadcastId: BROADCAST_ID,
    route: '/budgets',
  });
  assertEquals(sent[0].collapseKey, `broadcast:${BROADCAST_ID}`);
});

Deno.test('preference OFF and out-of-audience devices are skipped, never pushed', async () => {
  const store = fakeStore([
    device('on'),
    device('pref-off', { notificationsJson: '{"marketingMessages":false}' }),
    device('cloud-off', { inAudience: false }),
  ]);
  const sent: Sent[] = [];
  const res = await handleSendPushBroadcast(request(), deps(store.client, accept(sent)));
  assertEquals(sent.map((m) => m.token), ['tok-on']);
  assertEquals(store.deliveries.map((d) => [d.status, d.errorCode]), [
    ['sent', null],
    ['skipped', 'preference_off'],
    ['skipped', 'audience_left'],
  ]);
  const body = await res.json();
  assertEquals([body.sent, body.skipped], [1, 2]);
});

Deno.test('invoking the sender twice pushes each device exactly once', async () => {
  const store = fakeStore([device('a'), device('b'), device('c')]);
  const sent: Sent[] = [];
  const d = deps(store.client, accept(sent));
  await handleSendPushBroadcast(request(), d);
  const second = await (await handleSendPushBroadcast(request(), d)).json();
  assertEquals(sent.map((m) => m.token).sort(), ['tok-a', 'tok-b', 'tok-c']);
  assertEquals(second.claimed, 0);
  assert(store.deliveries.every((x) => x.status === 'sent'));
});

Deno.test('without APNs credentials every row fails closed as apns_not_configured and stays retryable', async () => {
  for (const k of ['APNS_KEY_ID', 'APNS_TEAM_ID', 'APNS_BUNDLE_ID', 'APNS_PRIVATE_KEY']) Deno.env.delete(k);
  const store = fakeStore([device('a'), device('b')]);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = (() => {
    throw new Error('APNs must not be called without credentials');
  }) as typeof fetch;
  try {
    // The real sender, not a stub: the fail-closed path is apns.ts's own.
    const d = deps(store.client, sendApnsAlert);
    const first = await (await handleSendPushBroadcast(request(), d)).json();
    assertEquals([first.failed, first.not_configured, first.sent], [2, 2, 0]);
    assertEquals(store.deliveries.map((x) => [x.status, x.errorCode, x.attempts]), [
      ['failed', 'apns_not_configured', 0],
      ['failed', 'apns_not_configured', 0],
    ]);
    // A later run (credentials still missing) claims both again: still retryable.
    const again = await (await handleSendPushBroadcast(request(), d)).json();
    assertEquals(again.claimed, 2);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

Deno.test('a transient APNs failure is retried by the next run, not the same one', async () => {
  const store = fakeStore([device('a')]);
  let calls = 0;
  const d = deps(store.client, () => {
    calls++;
    return Promise.resolve(
      calls === 1
        ? {
          ok: false as const,
          reason: 'apns_503_ServiceUnavailable',
          httpStatus: 503,
          errorCode: 'ServiceUnavailable',
        }
        : { ok: true as const, apnsId: 'x' },
    );
  });
  await handleSendPushBroadcast(request(), d);
  assertEquals([calls, store.deliveries[0].status, store.deliveries[0].attempts], [1, 'failed', 1]);
  await handleSendPushBroadcast(request(), d);
  assertEquals([calls, store.deliveries[0].status], [2, 'sent']);
});

Deno.test('a dead token is cleared and its row exhausted', async () => {
  const store = fakeStore([device('a')]);
  await handleSendPushBroadcast(
    request(),
    deps(
      store.client,
      () =>
        Promise.resolve({
          ok: false as const,
          reason: 'apns_410_Unregistered',
          httpStatus: 410,
          errorCode: 'Unregistered',
        }),
    ),
  );
  assertEquals(store.cleared, ['a']);
  assertEquals([store.deliveries[0].status, store.deliveries[0].attempts], ['failed', 5]);
});

Deno.test('non-admins and missing tokens are refused before anything is claimed', async () => {
  const store = fakeStore([device('a')]);
  const sent: Sent[] = [];
  const res = await handleSendPushBroadcast(request(), deps(store.client, accept(sent), false));
  assertEquals(res.status, 403);
  const noToken = await handleSendPushBroadcast(
    new Request('http://local/x', { method: 'POST', body: '{}' }),
    deps(store.client, accept(sent)),
  );
  assertEquals(noToken.status, 401);
  assertEquals(sent.length, 0);
  assertEquals(store.deliveries[0].status, 'pending');
});
