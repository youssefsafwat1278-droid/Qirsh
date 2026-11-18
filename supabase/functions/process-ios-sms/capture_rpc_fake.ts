// Test helper (not a test): an in-memory model of the capture_* RPCs from
// migration 0111 (the SQL proofs in supabase/tests/capture_state_machine_p1.sql are
// the authority; this mirrors their semantics so handler logic can be pinned in
// Deno). Also records every table touched, so tests can assert that the capture
// path never reads or writes user_transactions (I-2 runtime guard).

type Row = Record<string, unknown>;

// F1 (migration 0112): content is live iff the DATABASE clock_timestamp() < created_at + 168 h. The
// fake's database clock is Date.now() + state.dbSkewMs, so a test moves it (or a row's created_ms)
// to put a row at an exact boundary; the handler's own clock is never consulted.
export const CAPTURE_RETENTION_MS = 7 * 24 * 3600 * 1000;
export const captureContentLive = (createdMs: number, nowMs: number): boolean => nowMs < createdMs + CAPTURE_RETENTION_MS;

export type FakeDevice = {
  user_id: string | null;
  consent_owner_uid: string | null;
  cloud: boolean;
  ai: boolean;
  version: number;
  revoked: boolean;
  apns_token: string | null;
  // 0110 (H1): the trusted install owner history row; null = missing. Defaults to a proven
  // single-owner install (trusted, never transitioned, first owner = the device's user_id).
  history: { trusted: boolean; transitioned: boolean; first_owner_uid: string | null } | null;
};

export function fakeCapture(opts: {
  device?: Partial<FakeDevice>;
  duplicateOf?: string;
  /// user_merchant_rules rows: { user_id, merchant_key, category_key, deleted_at? }.
  merchantRules?: Row[];
  /// Makes the user_merchant_rules read fail.
  merchantRulesError?: boolean;
  onBeforeDispatch?: (state: ReturnType<typeof fakeCapture>['state']) => void;
  onDispatch?: (state: ReturnType<typeof fakeCapture>['state']) => void;
  onFinalize?: (state: ReturnType<typeof fakeCapture>['state']) => void;
  /// consume_ai_global_budget (migration 20261117120000): 'allow' (default),
  /// 'ceiling' after `budgetLimit` units, 'absent' (migration not applied:
  /// PostgREST PGRST202) or 'error' (any other RPC failure).
  budget?: 'allow' | 'ceiling' | 'absent' | 'error';
  budgetLimit?: number;
} = {}) {
  const device: FakeDevice = {
    user_id: null,
    consent_owner_uid: null,
    cloud: true,
    ai: true,
    version: 0,
    revoked: false,
    apns_token: null,
    history: undefined as unknown as FakeDevice['history'],
    ...opts.device,
  };
  if (device.history === undefined) {
    device.history = { trusted: true, transitioned: false, first_owner_uid: device.user_id };
  }
  const rows = new Map<string, Row>();
  const state = {
    device,
    rows,
    claims: 0,
    dispatches: 0,
    finalizes: 0,
    logs: [] as Row[],
    writes: [] as Array<{ table: string; op: string; row?: Row; opts?: Row; filters: Array<[string, unknown]> }>,
    tablesTouched: new Set<string>(),
    rateLimited: false,
    dbSkewMs: 0,
    dbFixedMs: null as number | null, // pin the database clock for exact-boundary tests
    budgetCalls: 0,
  };
  const dbNow = () => state.dbFixedMs ?? Date.now() + state.dbSkewMs;
  const liveRow = (r: Row) => captureContentLive(r.created_ms as number, dbNow());
  // capture_expire_row: content nulled, state expired; consumed / expired rows untouched.
  const expireRow = (r: Row) => {
    if (['processing', 'processed', 'retryable', 'rejected'].includes(r.state as string) && !liveRow(r)) {
      Object.assign(r, {
        state: 'expired',
        parsed: {},
        notification: {},
        sanitized_text: null,
        lease_until: null,
        next_attempt_at: null,
      });
    }
  };
  let seq = 0;

  // capture_row_json: no content past the fence, state reported as expired (tombstones stay consumed).
  const rowJson = (r: Row): Row => ({
    payload_id: r.payload_id,
    status: r.status,
    parsed: liveRow(r) ? r.parsed : {},
    notification: liveRow(r) ? r.notification : {},
    created_at: '2026-09-07T19:30:00Z',
    apns_push_sent_at: r.apns_push_sent_at ?? null,
    push_attempted_at: r.push_attempted_at ?? null,
    notification_log_id: r.notification_log_id ?? null,
    state: liveRow(r) || r.state === 'consumed' ? r.state : 'expired',
    attempts: r.attempts,
    next_attempt_at: r.next_attempt_at ?? null,
    failure_reason: r.failure_reason ?? null,
  });
  const queuePush = (r: Row, installId: string, type: unknown) => {
    // 0112: a capture's push is handed off at most once (push_attempted_at).
    if (!device.apns_token || r.push_attempted_at || !liveRow(r)) return null;
    r.push_attempted_at = new Date().toISOString();
    const id = (r.notification_log_id as string) ?? `log-${++seq}`;
    r.notification_log_id = id;
    state.logs.push({ id, install_id: installId, type });
    return { notification_log_id: id, apns_token: device.apns_token, apns_environment: 'sandbox' };
  };

  const rpcImpl = (fn: string, a: Row): unknown => {
    if (fn === 'bump_capture_rate_limit') return state.rateLimited;
    if (fn === 'capture_claim') {
      const contract = a.p_contract as number;
      if (device.revoked) return { outcome: 'denied', code: 'credential_revoked' };
      let ownerless = false;
      if (contract === 2 || a.p_owner_uid) {
        // owner-bound on ANY schema version
        if (
          !a.p_owner_uid || !device.user_id || !device.consent_owner_uid || a.p_owner_uid !== device.user_id ||
          device.user_id !== device.consent_owner_uid
        ) return { outcome: 'denied', code: 'capture_owner_mismatch' };
      } else if (device.consent_owner_uid !== device.user_id) {
        return { outcome: 'denied', code: 'consent_required' };
      } else {
        ownerless = true;
      }
      if (!device.cloud) return { outcome: 'denied', code: 'consent_required' };
      // OWNERLESS (build 50), H1 option B: mirrors capture_claim (0111). Only the trusted install
      // history counts; nothing the client sends (no received_at).
      const h = device.history;
      if (
        ownerless &&
        !(h && h.trusted && !h.transitioned && h.first_owner_uid !== null && h.first_owner_uid === device.user_id &&
          device.user_id === device.consent_owner_uid)
      ) return { outcome: 'owner_conflict', reason: 'ownerless_not_eligible' };
      const key = a.p_payload_id as string;
      const ex = rows.get(key);
      const take = (r: Row) => ({
        outcome: 'claimed',
        lease_token: r.lease_token,
        attempts: r.attempts,
        claimed_user_id: device.user_id,
        consent_owner_uid: device.consent_owner_uid,
        consent_version: device.version,
        ai_allowed: device.ai,
      });
      if (!ex) {
        const r: Row = {
          payload_id: key,
          status: 'rejected',
          state: 'processing',
          parsed: {},
          notification: {},
          raw_fingerprint: a.p_raw_fingerprint,
          created_ms: dbNow(),
          claimed_user_id: device.user_id,
          owner_uid: a.p_owner_uid ?? null,
          client_owner_generation: a.p_owner_generation ?? null,
          consent_owner_uid: device.consent_owner_uid,
          consent_version: device.version,
          lease_token: 1,
          attempts: 1,
          lease_until: Date.now() + 60_000,
        };
        rows.set(key, r);
        state.claims++;
        return take(r);
      }
      if (ex.claimed_user_id !== device.user_id) return { outcome: 'owner_conflict' };
      if (ex.raw_fingerprint && ex.raw_fingerprint !== a.p_raw_fingerprint) return { outcome: 'id_conflict' };
      if (!liveRow(ex)) {
        expireRow(ex);
        return { outcome: 'replay', row: rowJson(ex) };
      }
      if (ex.state === 'processing' && (ex.lease_until as number) > Date.now()) return { outcome: 'in_progress' };
      if (ex.state === 'processing' || ex.state === 'retryable') {
        if (ex.state === 'retryable' && (ex.next_attempt_at as number) > Date.now()) {
          return { outcome: 'replay', row: rowJson(ex) };
        }
        if ((ex.attempts as number) >= 5) {
          Object.assign(ex, { state: 'rejected', status: 'rejected', failure_reason: 'attempts_exhausted' });
          return { outcome: 'replay', row: rowJson(ex) };
        }
        Object.assign(ex, {
          state: 'processing',
          lease_until: Date.now() + 60_000,
          lease_token: (ex.lease_token as number) + 1,
          attempts: (ex.attempts as number) + 1,
          consent_owner_uid: device.consent_owner_uid,
          consent_version: device.version,
        });
        state.claims++;
        return take(ex);
      }
      const push = (ex.state === 'processed' || ex.state === 'rejected') && !ex.apns_push_sent_at &&
          (ex.notification as Row)?.title && ex.consent_version === device.version
        ? queuePush(ex, `raw`, (ex.notification as Row).type)
        : null;
      return { outcome: 'replay', row: rowJson(ex), push };
    }
    const r = rows.get(a.p_payload_id as string);
    if (fn === 'capture_ai_dispatch') {
      state.dispatches++;
      opts.onBeforeDispatch?.(state);
      if (!r || r.lease_token !== a.p_lease_token || r.state !== 'processing') {
        return { allowed: false, reason: 'lease_lost' };
      }
      if (!liveRow(r)) {
        expireRow(r);
        return { allowed: false, reason: 'expired' };
      }
      const revoked = device.revoked || !device.cloud || !device.ai || device.version !== r.consent_version;
      const moved = device.user_id !== r.claimed_user_id || device.consent_owner_uid !== r.consent_owner_uid ||
        device.consent_owner_uid !== device.user_id;
      const reason = moved ? 'owner_changed' : revoked ? 'consent_revoked' : null;
      if (reason) {
        Object.assign(r, { state: 'retryable', failure_reason: reason, next_attempt_at: Date.now() + 30_000 });
        return { allowed: false, reason };
      }
      Object.assign(r, { ai_started_at: Date.now(), ai_invoked: true, ai_consent_version: device.version });
      opts.onDispatch?.(state);
      return { allowed: true };
    }
    if (fn === 'capture_finalize') {
      state.finalizes++;
      opts.onFinalize?.(state);
      if (!r || r.lease_token !== a.p_lease_token || r.state !== 'processing') {
        return { written: false, push_allowed: false, reason: 'lease_lost' };
      }
      if (!liveRow(r)) {
        expireRow(r);
        return { written: false, push_allowed: false, reason: 'expired' };
      }
      const revoked = device.revoked || !device.cloud || device.version !== r.consent_version;
      const moved = device.user_id !== r.claimed_user_id || device.consent_owner_uid !== r.consent_owner_uid ||
        device.consent_owner_uid !== device.user_id;
      const reason = moved ? 'owner_changed' : revoked ? 'consent_revoked' : null;
      if (reason) {
        Object.assign(r, { state: 'retryable', failure_reason: reason, next_attempt_at: Date.now() + 30_000 });
        return { written: false, push_allowed: false, reason };
      }
      if (a.p_state === 'retryable') {
        Object.assign(r, {
          state: 'retryable',
          failure_reason: a.p_failure_reason,
          next_attempt_at: Date.now() + 30_000,
        });
        return { written: true, push_allowed: false, state: 'retryable', row: rowJson(r) };
      }
      Object.assign(r, {
        state: a.p_state,
        status: a.p_status,
        parsed: a.p_parsed ?? {},
        notification: a.p_notification ?? {},
        sanitized_text: a.p_sanitized_text,
        failure_reason: a.p_failure_reason,
        possible_duplicate: a.p_possible_duplicate,
      });
      const push = (a.p_notification as Row | null)?.title
        ? queuePush(r, a.p_install_id as string, (a.p_notification as Row).type)
        : null;
      return { written: true, push_allowed: true, state: a.p_state, row: rowJson(r), push };
    }
    throw new Error(`unexpected rpc ${fn}`);
  };

  const from = (table: string) => {
    state.tablesTouched.add(table);
    const f: { op: string; row?: Row; opts?: Row } = { op: 'select' };
    const filters: Array<[string, unknown]> = [];
    const record = () => state.writes.push({ table, op: f.op, row: f.row, opts: f.opts, filters });
    const result = (): { data: unknown; error: unknown } => {
      if (table === 'capture_fingerprints') {
        if (f.op === 'insert') {
          return opts.duplicateOf
            ? { data: null, error: { code: '23505', message: 'dup' } }
            : { data: null, error: null };
        }
        return { data: opts.duplicateOf ? [{ payload_id: opts.duplicateOf, fingerprint: 'x' }] : [], error: null };
      }
      if (table === 'user_merchant_rules') {
        if (opts.merchantRulesError) return { data: null, error: { message: 'boom' } };
        const hit = (opts.merchantRules ?? []).find((r) =>
          filters.every(([c, v]) => (c === 'deleted_at' ? (r.deleted_at ?? null) === v : r[c] === v))
        );
        return { data: hit ? { category_key: hit.category_key } : null, error: null };
      }
      return { data: null, error: null };
    };
    const b: Record<string, unknown> = {
      select: () => b,
      insert: (row: Row) => {
        f.op = 'insert';
        f.row = row;
        return b;
      },
      update: (row: Row) => {
        f.op = 'update';
        f.row = row;
        record();
        return b;
      },
      upsert: (row: Row, opts: Row) => {
        f.op = 'upsert';
        f.row = row;
        f.opts = opts;
        record();
        return b;
      },
      eq: (c: string, v: unknown) => (filters.push([c, v]), b),
      is: (c: string, v: unknown) => (filters.push([c, v]), b),
      in: () => b,
      maybeSingle: () => Promise.resolve(result()),
      single: () => Promise.resolve(result()),
      then: (resolve: (v: unknown) => unknown) => Promise.resolve(result()).then(resolve),
    };
    return b;
  };

  return {
    state,
    client: {
      from,
      rpc: (fn: string, args: Row) => {
        state.tablesTouched.add(`rpc:${fn}`);
        if (fn === 'consume_ai_global_budget') {
          state.budgetCalls++;
          const mode = opts.budget ?? 'allow';
          if (mode === 'absent') {
            return Promise.resolve({ data: null, error: { code: 'PGRST202', message: 'function not found' } });
          }
          if (mode === 'error') return Promise.resolve({ data: null, error: { code: '57014', message: 'timeout' } });
          const limit = mode === 'ceiling' ? opts.budgetLimit ?? 0 : 3000;
          const allowed = state.budgetCalls <= limit;
          return Promise.resolve({
            data: { allowed, reason: allowed ? 'ok' : 'ceiling', used: Math.min(state.budgetCalls, limit), limit },
            error: null,
          });
        }
        return Promise.resolve({ data: rpcImpl(fn, args), error: null });
      },
    },
  };
}
