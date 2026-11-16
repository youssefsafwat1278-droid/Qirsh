// Static contract for 20261116210000_profile_photo_backup. Credential-free;
// the live proof is profile_photo_backup_20261116.sql (rolled back).
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');
const name = '20261116210000_profile_photo_backup';
const sql = stripComments(read(`supabase/migrations/${name}.sql`));
const rollback = stripComments(read(`supabase/rollback/${name}_rollback.sql`));
const erasure = read('supabase/functions/_shared/storage_erasure.ts');

const policy = (src, polName) => {
  const at = src.indexOf(`create policy "${polName}"`);
  assert.ok(at >= 0, polName);
  return src.slice(at, src.indexOf(';', at));
};

test('the bucket is private, size-capped and images only', () => {
  const ins = sql.slice(sql.indexOf('insert into storage.buckets'));
  const stmt = ins.slice(0, ins.indexOf(';'));
  assert.match(stmt, /'profile-photos', 'profile-photos', false, 5242880/);
  assert.match(stmt, /set public = false/);
  for (const t of (stmt.match(/'[a-z]+\/[a-z+.-]+'/g) ?? [])) {
    assert.match(t, /^'image\/(jpeg|png|heic|heif|webp)'$/, t);
  }
});

test('writes: exact <uid>/avatar name, live Auth row, no pending deletion', () => {
  for (const p of ['own profile photo write', 'own profile photo update']) {
    const body = policy(sql, p);
    assert.match(body, /to authenticated/, p);
    assert.match(body, /bucket_id = 'profile-photos'/, p);
    assert.match(body, /name = \(select auth\.uid\(\)\)::text \|\| '\/avatar'/, p);
    assert.match(body, /public\.backups_owner_is_live\(\)/, p);
  }
});

test('reads and deletes: the owner folder only, never anon or public', () => {
  for (const p of ['own profile photo read', 'own profile photo delete']) {
    const body = policy(sql, p);
    assert.match(body, /to authenticated/, p);
    assert.match(body, /\(storage\.foldername\(name\)\)\[1\] = \(select auth\.uid\(\)\)::text/, p);
  }
  assert.doesNotMatch(sql, /to anon|to public/i);
});

test('account deletion sweeps the bucket in the deletion worker', () => {
  assert.match(erasure, /ERASURE_BUCKETS = \['backups', 'profile-photos'\]/);
});

test('the capability is advertised, and every later restatement keeps it', () => {
  assert.match(sql, /'profile_photo_backup', true/);
  assert.match(sql, /'merchant_rules_sync', true/);
  const later = readdirSync(new URL('supabase/migrations/', root))
    .filter((f) => f.endsWith('.sql') && f > `${name}.sql`)
    .map((f) => stripComments(read(`supabase/migrations/${f}`)))
    .filter((s) => /function public\.qirsh_server_capabilities\(\)/.test(s));
  for (const s of later) assert.match(s, /'profile_photo_backup', true/);
});

test('the rollback drops the policies, the capability and the empty bucket', () => {
  for (const p of ['read', 'write', 'update', 'delete']) {
    assert.match(rollback, new RegExp(`drop policy if exists "own profile photo ${p}" on storage\\.objects`));
  }
  assert.doesNotMatch(rollback, /profile_photo_backup/);
  assert.match(rollback, /'merchant_rules_sync', true/);
  assert.match(rollback, /delete from storage\.buckets where id = 'profile-photos'/);
});
