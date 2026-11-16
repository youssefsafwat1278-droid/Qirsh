import { assert, assertEquals } from 'jsr:@std/assert@1';
import { sendApnsAlert } from '../_shared/apns.ts';
import {
  broadcastMessagesEnabled,
  handleSendPushBroadcast,
  looksLikeJwt,
  pickBroadcastLanguage,
  type SendPushBroadcastDependencies,
  usableWorkerSecret,
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
  /// Mirrors next_attempt_at (ms on the fake clock); null = due now.
  nextAttemptAt: number | null;
};

/// Fake clock shared by the store (backoff) and the handler (claim budget).
const clock = { now: 0 };
const MIN = 60_000;

/// In-memory stand-in for the sender RPCs with the migrations' semantics:
/// both claims take pending / failed-with-attempts-left rows not attempted by
/// this run and move them to 'sending' (the shared lease); the scheduled claim
/// also waits out next_attempt_at; finish moves only a 'sending' row.
function fakeStore(
  devices: Device[],
  // deno-lint-ignore no-explicit-any -- test double for the loosely typed Edge client.
): { client: any; deliveries: Delivery[]; cleared: string[]; calls: string[] } {
  const deliveries: Delivery[] = devices.map((d, i) => ({
    id: `delivery-${i}`,
    hash: d.hash,
    status: 'pending',
    attempts: 0,
    lastRunId: null,
    errorCode: null,
    language: null,
    nextAttemptAt: null,
  }));
  const cleared: string[] = [];
  const calls: string[] = [];
  const claimable = (x: Delivery, scheduled: boolean) =>
    ['pending', 'failed'].includes(x.status) && x.attempts < 5 &&
    (!scheduled || x.nextAttemptAt === null || x.nextAttemptAt <= clock.now);
  const client = {
    rpc(fn: string, args: Record<string, unknown>) {
      calls.push(fn);
      if (fn === 'push_broadcast_retry_due') {
        const due = deliveries.some((x) => claimable(x, true));
        return Promise.resolve({ data: due ? [{ broadcast_id: BROADCAST_ID }] : [], error: null });
      }
      if (fn === 'claim_push_broadcast_deliveries' || fn === 'claim_push_broadcast_retry_deliveries') {
        const scheduled = fn === 'claim_push_broadcast_retry_deliveries';
        if (scheduled) assertEquals(args.p_actor, undefined);
        else assertEquals(args.p_actor, ADMIN);
        const picked = deliveries
          .filter((x) => claimable(x, scheduled) && x.lastRunId !== args.p_run_id)
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
          x.nextAttemptAt = x.status !== 'failed' || args.p_exhaust
            ? null
            : clock.now + (args.p_count_attempt ? 10 * MIN * 2 ** (x.attempts - 1) : 30 * MIN);
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
  return { client, deliveries, cleared, calls };
}

type Sent = Parameters<typeof sendApnsAlert>[0];

function deps(
  // deno-lint-ignore no-explicit-any -- test double
  client: any,
  sendAlert: SendPushBroadcastDependencies['sendAlert'],
  admin = true,
  extra: Partial<SendPushBroadcastDependencies> = {},
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
    workerSecret: () => WORKER_SECRET,
    apnsConfigured: () => true,
    now: () => clock.now,
    ...extra,
  };
}

// Test-only value, shaped like `openssl rand -hex 32`.
const WORKER_SECRET = '3f9a1c7e5b2d8046af13ce97b5d20e8c41f6a9d3b7c05e2819f4ad6c3b8e7051';

const b64url = (v: unknown) => btoa(JSON.stringify(v)).replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
// Structurally a JWT (the stubbed authenticateAdmin decides whether it is valid).
const ADMIN_JWT = `${b64url({ alg: 'HS256', typ: 'JWT' })}.${b64url({ sub: 'admin' })}.c2lnbmF0dXJl`;

const scheduledRequest = (secret = WORKER_SECRET) =>
  new Request('http://local/send-push-broadcast', {
    method: 'POST',
    headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
    body: JSON.stringify({ mode: 'scheduled' }),
  });

const fail = (reason: string, httpStatus: number, errorCode: string) => () =>
  Promise.resolve({ ok: false as const, reason, httpStatus, errorCode });

const request = (broadcastId = BROADCAST_ID) =>
  new Request('http://local/send-push-broadcast', {
    method: 'POST',
    headers: { authorization: `Bearer ${ADMIN_JWT}`, 'content-type': 'application/json' },
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

Deno.test('a dead token is cleared and its row skipped for good', async () => {
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
  assertEquals([store.deliveries[0].status, store.deliveries[0].errorCode], ['skipped', 'apns_410_Unregistered']);
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

Deno.test('BadDeviceToken and DeviceTokenNotForTopic are skipped, only the dead token is cleared', async () => {
  const store = fakeStore([device('bad'), device('topic')]);
  await handleSendPushBroadcast(
    request(),
    deps(
      store.client,
      (m: Sent) =>
        m.token === 'tok-bad'
          ? fail('apns_400_BadDeviceToken', 400, 'BadDeviceToken')()
          : fail('apns_400_DeviceTokenNotForTopic', 400, 'DeviceTokenNotForTopic')(),
    ),
  );
  assertEquals(store.deliveries.map((d) => d.status), ['skipped', 'skipped']);
  assertEquals(store.cleared, ['bad']);
  // Neither path picks a skipped row up again, however much later.
  clock.now += 24 * 60 * MIN;
  const manual = await (await handleSendPushBroadcast(request(), deps(store.client, accept([])))).json();
  const scheduled = await (await handleSendPushBroadcast(scheduledRequest(), deps(store.client, accept([])))).json();
  assertEquals([manual.claimed, scheduled.claimed], [0, 0]);
});

Deno.test('scheduled run: worker secret, no admin auth, backoff-aware claim', async () => {
  const store = fakeStore([device('a')]);
  let calls = 0;
  let adminChecks = 0;
  const d = deps(
    store.client,
    (m: Sent) => {
      calls++;
      return calls === 1 ? fail('apns_503_ServiceUnavailable', 503, 'ServiceUnavailable')() : accept([])(m);
    },
    true,
    {
      authenticateAdmin: () => {
        adminChecks++;
        return Promise.resolve({ ok: true as const, userId: ADMIN });
      },
    },
  );
  const first = await (await handleSendPushBroadcast(scheduledRequest(), d)).json();
  assertEquals([first.mode, first.broadcasts, first.failed], ['scheduled', 1, 1]);
  assert(store.calls.includes('claim_push_broadcast_retry_deliveries'));
  assert(!store.calls.includes('claim_push_broadcast_deliveries'));
  assertEquals(adminChecks, 0);

  // Inside the 10-minute backoff nothing is due.
  clock.now += 5 * MIN;
  const early = await (await handleSendPushBroadcast(scheduledRequest(), d)).json();
  assertEquals([early.broadcasts, early.claimed, calls], [0, 0, 1]);

  clock.now += 6 * MIN;
  const later = await (await handleSendPushBroadcast(scheduledRequest(), d)).json();
  assertEquals([later.sent, calls, store.deliveries[0].status], [1, 2, 'sent']);
});

Deno.test('a wrong or empty worker secret never reaches the scheduled path', async () => {
  const store = fakeStore([device('a')]);
  const sent: Sent[] = [];
  const refuse = {
    authenticateAdmin: () => Promise.resolve({ ok: false as const, status: 401, error: 'unauthenticated' }),
  };
  const wrong = await handleSendPushBroadcast(scheduledRequest('nope'), deps(store.client, accept(sent), true, refuse));
  assertEquals(wrong.status, 401);
  const unset = await handleSendPushBroadcast(
    scheduledRequest(''),
    deps(store.client, accept(sent), true, { ...refuse, workerSecret: () => '' }),
  );
  assertEquals(unset.status, 401);
  assertEquals([sent.length, store.calls.length], [0, 0]);
});

Deno.test('scheduled run claims nothing while APNs is not configured', async () => {
  const store = fakeStore([device('a')]);
  const res = await (await handleSendPushBroadcast(
    scheduledRequest(),
    deps(store.client, accept([]), true, { apnsConfigured: () => false }),
  )).json();
  assertEquals(res.skipped, 'apns_not_configured');
  assertEquals(store.calls, []);
  assertEquals([store.deliveries[0].status, store.deliveries[0].attempts], ['pending', 0]);
});

Deno.test('a manual run during a scheduled run cannot take or resend its rows', async () => {
  const store = fakeStore([device('a'), device('b')]);
  const sent: Sent[] = [];
  let manualClaimed = -1;
  const manualDeps = deps(store.client, accept(sent));
  const scheduledDeps = deps(store.client, async (m: Sent) => {
    // The admin presses the button while the scheduler is mid-send.
    if (manualClaimed < 0) {
      manualClaimed = (await (await handleSendPushBroadcast(request(), manualDeps)).json()).claimed;
    }
    return accept(sent)(m);
  });
  await handleSendPushBroadcast(scheduledRequest(), scheduledDeps);
  assertEquals(manualClaimed, 0);
  assertEquals(sent.map((m) => m.token).sort(), ['tok-a', 'tok-b']);
});

Deno.test('no new batch is claimed once the claim budget is spent', async () => {
  // Each APNs call takes 1 s. Batch 1 (100 rows) ends at +100 s, inside the
  // 120 s budget, so batch 2 is claimed; batch 3 is not.
  const store = fakeStore(Array.from({ length: 250 }, (_, i) => device(`e${i}`)));
  const d = deps(store.client, (m: Sent) => {
    clock.now += 1_000;
    return accept([])(m);
  });
  const res = await (await handleSendPushBroadcast(request(), d)).json();
  assertEquals(res.claimed, 200);
  assertEquals(store.deliveries.filter((x) => x.status === 'pending').length, 50);
});

// ─── Hardening: secret strength and no forwarding of near-miss secrets ─────

const spyAdmin = () => {
  const seen: string[] = [];
  return {
    seen,
    authenticateAdmin: (_: unknown, token: string) => {
      seen.push(token);
      return Promise.resolve({ ok: false as const, status: 401, error: 'unauthenticated' });
    },
  };
};

Deno.test('worker secret strength: missing, short and weak secrets are treated as unset', () => {
  assertEquals(usableWorkerSecret(''), '');
  assertEquals(usableWorkerSecret(WORKER_SECRET.slice(0, 31)), '');
  assertEquals(usableWorkerSecret('a'.repeat(64)), '');
  assertEquals(usableWorkerSecret('ab'.repeat(32)), '');
  assertEquals(usableWorkerSecret(WORKER_SECRET.slice(0, 32)), WORKER_SECRET.slice(0, 32));
  assertEquals(usableWorkerSecret(WORKER_SECRET), WORKER_SECRET);
});

for (
  const [label, configured] of [
    ['missing', ''],
    ['31 characters', WORKER_SECRET.slice(0, 31)],
    ['weak (one repeated character)', 'x'.repeat(48)],
  ] as const
) {
  Deno.test(`a ${label} configured secret never opens the scheduled path, even when presented exactly`, async () => {
    const store = fakeStore([device('a')]);
    const sent: Sent[] = [];
    const spy = spyAdmin();
    const res = await handleSendPushBroadcast(
      scheduledRequest(configured),
      deps(store.client, accept(sent), true, {
        workerSecret: () => configured,
        authenticateAdmin: spy.authenticateAdmin,
      }),
    );
    assertEquals(res.status, 401);
    assertEquals([sent.length, store.calls.length, spy.seen.length], [0, 0, 0]);
  });
}

Deno.test('the exact strong secret opens the scheduled path without any login check', async () => {
  const store = fakeStore([device('a')]);
  const spy = spyAdmin();
  const res = await handleSendPushBroadcast(
    scheduledRequest(),
    deps(store.client, accept([]), true, { authenticateAdmin: spy.authenticateAdmin }),
  );
  assertEquals(res.status, 200);
  assertEquals(spy.seen.length, 0);
});

Deno.test('near-miss secrets get 401 and never reach the login check', async () => {
  const flipped = WORKER_SECRET.slice(0, -1) + (WORKER_SECRET.endsWith('0') ? '1' : '0');
  for (
    const presented of [
      flipped,
      WORKER_SECRET.slice(0, -1),
      WORKER_SECRET + 'a',
      WORKER_SECRET.toUpperCase(),
      ` ${WORKER_SECRET}`,
      'nope',
      'a.b',
      'a.b.c.d',
      `${b64url({ typ: 'JWT' })}.e30.sig`, // header without alg
      'bm90anNvbg.e30.sig', // header is not JSON
    ]
  ) {
    const store = fakeStore([device('a')]);
    const spy = spyAdmin();
    const res = await handleSendPushBroadcast(
      scheduledRequest(presented),
      deps(store.client, accept([]), true, { authenticateAdmin: spy.authenticateAdmin }),
    );
    assertEquals(res.status, 401, presented.length.toString());
    assertEquals([spy.seen.length, store.calls.length], [0, 0]);
  }
});

Deno.test('a JWT-shaped token is forwarded to the login check', async () => {
  const store = fakeStore([device('a')]);
  const spy = spyAdmin();
  const res = await handleSendPushBroadcast(
    request(),
    deps(store.client, accept([]), true, { authenticateAdmin: spy.authenticateAdmin }),
  );
  assertEquals(res.status, 401);
  assertEquals(spy.seen, [ADMIN_JWT]);
  assert(looksLikeJwt(ADMIN_JWT));
});
