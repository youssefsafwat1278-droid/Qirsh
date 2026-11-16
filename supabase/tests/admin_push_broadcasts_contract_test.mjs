// Static contract for 20261116150000_admin_push_broadcasts.
// Credential-free; the live proof is admin_push_broadcasts_20261116.sql.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');
const name = '20261116150000_admin_push_broadcasts';
const sql = stripComments(read(`supabase/migrations/${name}.sql`));

const fnBody = (fn) => {
  const start = sql.search(new RegExp(`FUNCTION public\\.${fn}\\(`));
  assert.ok(start >= 0, `${fn} defined`);
  const open = sql.indexOf('$$', start);
  return sql.slice(open, sql.indexOf('$$;', open + 2));
};

test('exactly one delivery row per (broadcast, device)', () => {
  assert.match(sql, /CONSTRAINT push_broadcast_deliveries_one_per_device UNIQUE \(broadcast_id, install_id_hash\)/);
  assert.match(fnBody('admin_create_push_broadcast'),
    /ON CONFLICT ON CONSTRAINT push_broadcast_deliveries_one_per_device DO NOTHING/);
});

test('create is idempotent on operation_id and re-checks the typed count', () => {
  assert.match(sql, /operation_id\s+UUID NOT NULL UNIQUE/);
  const body = fnBody('admin_create_push_broadcast');
  assert.match(body, /pg_advisory_xact_lock/);
  assert.match(body, /'replayed', true/);
  assert.match(body, /p_confirm_devices IS DISTINCT FROM v_devices/);
});

test('the claim never re-takes a delivered or skipped row and skips locked rows', () => {
  const body = fnBody('claim_push_broadcast_deliveries');
  assert.match(body, /x\.status IN \('pending', 'failed'\) AND x\.attempt_count < 5/);
  assert.match(body, /FOR UPDATE SKIP LOCKED/);
  assert.match(body, /x\.last_run_id IS DISTINCT FROM p_run_id/);
  assert.doesNotMatch(body, /'sent'|'skipped'/);
  assert.match(fnBody('finish_push_broadcast_delivery'), /WHERE id = p_delivery_id AND status = 'sending'/);
});

test('audience is the server Cloud choice plus the device projection', () => {
  const body = fnBody('push_broadcast_audience_devices');
  for (const re of [
    /s\.cloud_processing_enabled IS TRUE/, /s\.consent_version > 0/, /d\.consent_owner_uid = d\.user_id/,
    /d\.cloud_processing_enabled IS TRUE/, /d\.revoked_at IS NULL/, /d\.apns_token IS NOT NULL/,
    /NOT account_fence\.is_pending\(d\.user_id\)/,
  ]) assert.match(body, re);
  assert.match(fnBody('push_broadcast_messages_enabled'), /'marketingMessages'/);
});

test('every admin RPC checks admin_users; nothing is client-reachable', () => {
  for (const fn of ['admin_push_broadcast_dry_run', 'admin_create_push_broadcast', 'admin_push_broadcast_history',
    'claim_push_broadcast_deliveries']) {
    assert.match(fnBody(fn), /PERFORM public\.push_broadcast_require_admin\(p_actor\)/, fn);
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION public\\.${fn}\\([^)]*\\)\\s+FROM PUBLIC, anon, authenticated`), fn);
    assert.match(sql, new RegExp(`GRANT EXECUTE ON FUNCTION public\\.${fn}\\([^)]*\\)\\s+TO service_role;`), fn);
  }
  for (const t of ['push_broadcasts', 'push_broadcast_deliveries']) {
    assert.match(sql, new RegExp(`ALTER TABLE public\\.${t} ENABLE ROW LEVEL SECURITY`));
    assert.match(sql, new RegExp(`REVOKE ALL ON TABLE public\\.${t} FROM PUBLIC, anon, authenticated`));
    assert.doesNotMatch(sql, new RegExp(`CREATE POLICY[^;]*ON public\\.${t}`, 'i'));
    assert.doesNotMatch(sql, new RegExp(`GRANT [A-Z, ]+ ON TABLE public\\.${t} TO (anon|authenticated)`, 'i'));
  }
});

test('each broadcast is stored as an info announcement', () => {
  assert.match(fnBody('admin_create_push_broadcast'), /INSERT INTO public\.announcements[\s\S]*'info'/);
});

test('the migration ships a rollback', () => {
  const rb = read(`supabase/rollback/${name}_rollback.sql`);
  assert.match(rb, /DROP TABLE IF EXISTS public\.push_broadcast_deliveries/);
  assert.match(rb, /DROP TABLE IF EXISTS public\.push_broadcasts/);
});
