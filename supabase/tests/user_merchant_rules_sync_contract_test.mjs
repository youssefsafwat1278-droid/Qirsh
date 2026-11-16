// Static contract for 20261116180000_user_merchant_rules_sync. Credential-free;
// the live proof is user_merchant_rules_sync_20261116.sql (rolled back).
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');
const name = '20261116180000_user_merchant_rules_sync';
const raw = read(`supabase/migrations/${name}.sql`);
const sql = stripComments(raw);
const rollback = read(`supabase/rollback/${name}_rollback.sql`);
const fence = read('supabase/migrations/0117_account_deletion_fence.sql');

/** The body of `fnName` from `create [or replace] function` to its `$$;`. */
function body(src, fnName) {
  const re = new RegExp(`create (or replace )?function ${fnName.replace('.', '\\.')}\\(`);
  const m = re.exec(src);
  assert.ok(m, `${fnName} not found`);
  const rest = src.slice(m.index);
  return rest.slice(0, rest.indexOf('\n$$;') + 4).replace(/^create (or replace )?function/, 'FN');
}

test('the table holds keys, timestamps and a tombstone only', () => {
  const t = sql.slice(sql.indexOf('create table public.user_merchant_rules'));
  const cols = t.slice(0, t.indexOf(';'));
  for (const c of ['user_id', 'merchant_key', 'category_key', 'updated_at', 'deleted_at', 'sync_seq']) {
    assert.match(cols, new RegExp(`\\b${c}\\b`), c);
  }
  assert.doesNotMatch(cols, /amount|message|body|note|currency|account|card|install|device/i);
  assert.match(cols, /unique \(user_id, merchant_key\)/);
  assert.match(cols, /references auth\.users\(id\) on delete cascade/);
});

test('per-user RLS; clients may tombstone but never hard-delete', () => {
  assert.match(sql, /alter table public\.user_merchant_rules enable row level security/);
  assert.match(sql, /revoke all on table public\.user_merchant_rules from public, anon, authenticated/);
  for (const p of ['select_own', 'insert_own', 'update_own']) {
    const pol = sql.slice(sql.indexOf(`user_merchant_rules_${p}`));
    assert.match(pol.slice(0, pol.indexOf(';')), /auth\.uid\(\) = user_id/, p);
  }
  assert.doesNotMatch(sql, /grant[^;]*\bdelete\b[^;]*to authenticated/i);
  assert.doesNotMatch(sql, /to anon/i);
  // Server-owned columns are not client-writable.
  for (const g of sql.match(/grant (insert|update) \([^)]*\)/g) ?? []) {
    assert.doesNotMatch(g, /updated_at|sync_seq|created_at|\bid\b/, g);
  }
});

test('writes go through stamp_sync_seq: server-owned updated_at + fence admission', () => {
  assert.match(sql, /before insert or update on public\.user_merchant_rules\s+for each row execute function public\.stamp_sync_seq\(\)/);
});

test('account deletion erases the table and its closure check covers it', () => {
  assert.match(sql, /grant select, delete on table public\.user_merchant_rules to account_fence_owner/);
  assert.match(sql, /create policy account_fence_erasure on public\.user_merchant_rules[\s\S]*?using \(user_id = account_fence\.erasure_uid\(\)\)/);
  assert.match(body(sql, 'account_fence.erase_user_data'), /delete from public\.user_merchant_rules\s+where user_id = p_uid/);
  assert.match(body(sql, 'account_fence.erase_verify'), /'user_merchant_rules'::text as tbl where exists \(select 1 from public\.user_merchant_rules where user_id = p_uid\)/);
});

test('the restated erasure functions equal 0117 plus exactly one line each', () => {
  for (const fn of ['account_fence.erase_user_data', 'account_fence.erase_verify']) {
    const mine = body(raw, fn).split('\n');
    const orig = body(fence, fn).split('\n');
    const added = mine.filter((l) => !orig.includes(l));
    const removed = orig.filter((l) => !mine.includes(l));
    assert.deepEqual(removed, [], `${fn} lost lines`);
    assert.equal(added.length, 1, `${fn}: ${added.join(' | ')}`);
    assert.match(added[0], /user_merchant_rules/);
  }
});

test('the temporary owner membership is revoked in the same transaction', () => {
  const g = sql.indexOf('grant account_fence_owner to current_user;');
  const r = sql.indexOf('revoke account_fence_owner from current_user;');
  assert.ok(g > 0 && r > g && r < sql.lastIndexOf('commit;'));
});

test('capability: every 0114 key preserved, merchant_rules_sync added', () => {
  const caps = body(sql, 'public.qirsh_server_capabilities');
  for (const k of ['awaiting_fx_transactions', 'capture_contract_v2', 'sync_seq', 'revision_cas',
    'replica_epoch', 'min_supported_seq', 'min_client_build']) {
    assert.match(caps, new RegExp(`'${k}'`), k);
  }
  assert.match(caps, /'merchant_rules_sync', true/);
  assert.match(sql, /grant execute on function public\.qirsh_server_capabilities\(\) to authenticated/);
});

test('rollback restores 0117 erasure bodies and the 0114 capability set, drops the table', () => {
  for (const fn of ['account_fence.erase_user_data', 'account_fence.erase_verify']) {
    assert.equal(body(rollback, fn), body(fence, fn), fn);
  }
  assert.doesNotMatch(rollback, /merchant_rules_sync/);
  assert.match(rollback, /drop table if exists public\.user_merchant_rules/);
  assert.match(rollback, /revoke account_fence_owner from current_user;/);
});
