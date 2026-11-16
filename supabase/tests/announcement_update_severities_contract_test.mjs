// Static contract for 20261116120000_announcement_update_severities.
// Credential-free; the live proof is announcement_update_severities_20261116.sql.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');
const name = '20261116120000_announcement_update_severities';
const sql = stripComments(read(`supabase/migrations/${name}.sql`));

test('the severity check accepts update_available and release_notes', () => {
  assert.match(sql, /ADD CONSTRAINT announcements_severity_check/);
  for (const s of ['info', 'warning', 'maintenance', 'force_update', 'update_available', 'release_notes']) {
    assert.match(sql, new RegExp(`'${s}'`), s);
  }
});

test('force_update stays the only blocking severity', () => {
  // Every migration that (re)defines the blocking predicate must compare to
  // force_update alone; the new severities never arm the trigger.
  const dir = new URL('supabase/migrations/', root);
  const defs = readdirSync(dir)
    .filter((f) => f.endsWith('.sql'))
    .map((f) => stripComments(readFileSync(new URL(f, dir), 'utf8')))
    .filter((s) => /FUNCTION public\.announcement_blocks_clients/i.test(s));
  assert.ok(defs.length >= 1);
  for (const s of defs) {
    const fn = s.slice(s.search(/FUNCTION public\.announcement_blocks_clients/i));
    const body = fn.slice(0, fn.indexOf('$$;', fn.indexOf('$$') + 2));
    assert.match(body, /p_severity = 'force_update'/);
    assert.doesNotMatch(body, /update_available|release_notes/);
  }
});

test('the migration ships a rollback', () => {
  const rb = read(`supabase/rollback/${name}_rollback.sql`);
  assert.match(rb, /'force_update'\)\)/);
});
