// Coupons Phase C2 — static contract checks for migration 0082 (coupon
// analytics) and the catalog-coupons Edge contract. No credentials required;
// the live behaviour matrix is in coupon_metrics_live_node_test.mjs.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const raw = read('supabase/migrations/0082_coupon_metrics.sql');
const edge = read('supabase/functions/catalog-coupons/index.ts');

const stripComments = (sql) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .join('\n');
const sql = stripComments(raw);

const SIG = /public\.record_coupon_event\s*\(\s*UUID,\s*TEXT\s*\)/i;

// ---------------------------------------------------------------------------
// Aggregate table
// ---------------------------------------------------------------------------
test('0082: coupon_metrics_daily is keyed by (day, coupon_id, event)', () => {
  assert.match(sql, /CREATE TABLE IF NOT EXISTS coupon_metrics_daily\s*\(/i);
  assert.match(sql, /PRIMARY KEY \(day, coupon_id, event\)/i);
  assert.match(sql, /day\s+DATE NOT NULL/i);
  assert.match(sql, /count\s+BIGINT NOT NULL DEFAULT 0/i);
});

test('0082: coupon FK cascades so deleted catalog leaves no dangling metrics', () => {
  assert.match(sql, /coupon_id UUID NOT NULL REFERENCES coupons\(id\) ON DELETE CASCADE/i);
});

test('0082: exactly the four approved events; none of the forbidden ones', () => {
  assert.match(
    sql,
    /CONSTRAINT coupon_metrics_event_shape CHECK \(\s*event IN \('impression', 'detail_view', 'code_copy', 'cta_click'\)/i,
  );
  for (const forbidden of ['save', 'redeem', 'favorite']) {
    assert.doesNotMatch(
      sql,
      new RegExp(`'${forbidden}'`, 'i'),
      `'${forbidden}' is not a V1 event`,
    );
  }
});

test('0082: stores no identity, country or financial context', () => {
  for (const forbidden of [
    'install_id', 'device_id', 'user_id', 'country', 'category', 'spend',
    'amount', 'transaction', 'merchant',
  ]) {
    assert.doesNotMatch(sql, new RegExp(`\\b${forbidden}\\b`, 'i'), `must not store ${forbidden}`);
  }
});

test('0082: count is protected against invalid state', () => {
  assert.match(sql, /CONSTRAINT coupon_metrics_count_positive CHECK \(count > 0\)/i);
  // BIGINT makes overflow operationally irrelevant — no rollover logic needed.
  assert.doesNotMatch(sql, /count\s+(INT|INTEGER|SMALLINT)\b/i);
});

// ---------------------------------------------------------------------------
// RPC: atomicity, validation, day authority, hardening
// ---------------------------------------------------------------------------
test('0082: the increment is ONE atomic upsert (no read-modify-write)', () => {
  assert.match(
    sql,
    /INSERT INTO public\.coupon_metrics_daily AS m \(day, coupon_id, event, count\)[\s\S]*?ON CONFLICT \(day, coupon_id, event\)[\s\S]*?DO UPDATE SET count = m\.count \+ 1/i,
  );
  // No SELECT-then-UPDATE anywhere in the function body.
  assert.doesNotMatch(sql, /SELECT\s+count\s+FROM\s+public\.coupon_metrics_daily/i);
  assert.doesNotMatch(sql, /UPDATE public\.coupon_metrics_daily\s+SET count\s*=\s*\d/i);
});

test('0082: unknown events raise a controlled error (no silent coercion)', () => {
  assert.match(
    sql,
    /IF p_event IS NULL OR p_event NOT IN\s*\n?\s*\('impression', 'detail_view', 'code_copy', 'cta_click'\) THEN[\s\S]*?RAISE EXCEPTION/i,
  );
  assert.match(sql, /ERRCODE = 'invalid_parameter_value'/i);
});

test('0082: the coupon must exist — arbitrary UUIDs cannot mint metric rows', () => {
  assert.match(
    sql,
    /NOT EXISTS \(SELECT 1 FROM public\.coupons c WHERE c\.id = p_coupon_id\)[\s\S]*?RAISE EXCEPTION/i,
  );
  // Existence is the ONLY catalog gate: a live-only rule would drop legitimate
  // interactions that race expiry (documented trade-off).
  assert.doesNotMatch(sql, /coupon_is_live\(/i);
});

test('0082: the SERVER owns the aggregation day (no client-supplied day)', () => {
  assert.match(sql, /\(now\(\) AT TIME ZONE 'utc'\)::date/i);
  // The signature takes only (coupon_id, event) — there is no day parameter.
  assert.match(sql, /record_coupon_event\(\s*\n?\s*p_coupon_id UUID,\s*\n?\s*p_event\s+TEXT\s*\n?\s*\)/i);
  assert.doesNotMatch(sql, /p_day|p_date/i);
});

test('0082: definer-rights RPC is hardened exactly like 0080', () => {
  assert.match(sql, /SECURITY DEFINER/i);
  assert.match(sql, /SET search_path = pg_catalog, public, pg_temp/i);
  assert.match(raw, new RegExp(`REVOKE ALL ON FUNCTION ${SIG.source} FROM PUBLIC;`, 'i'));
  assert.match(raw, new RegExp(`REVOKE ALL ON FUNCTION ${SIG.source} FROM anon;`, 'i'));
  assert.match(raw, new RegExp(`GRANT EXECUTE ON FUNCTION ${SIG.source} TO authenticated;`, 'i'));
  // Never grants execute to anon/public.
  assert.doesNotMatch(sql, /GRANT EXECUTE ON FUNCTION[^;]*TO\s+[^;]*\b(anon|public)\b/i);
  // Fully schema-qualified inside the body.
  assert.match(sql, /INSERT INTO public\.coupon_metrics_daily/i);
  assert.match(sql, /FROM public\.coupons/i);
});

test('0082: the aggregate is never client-readable or client-writable', () => {
  assert.match(sql, /ALTER TABLE coupon_metrics_daily ENABLE ROW LEVEL SECURITY/i);
  assert.match(sql, /REVOKE ALL ON TABLE coupon_metrics_daily FROM anon, authenticated/i);
  // RLS on + zero policies => every direct client statement is denied.
  assert.doesNotMatch(sql, /CREATE POLICY[\s\S]*?ON coupon_metrics_daily/i);
  assert.doesNotMatch(sql, /GRANT (SELECT|INSERT|UPDATE|DELETE|ALL) ON TABLE coupon_metrics_daily/i);
});

test('0082: analytics trust classification is documented in the migration', () => {
  assert.match(raw, /PRODUCT \/ DIRECTIONAL ANALYTICS/i);
  assert.match(raw, /NOT billing-grade/i);
  assert.match(raw, /anti-abuse/i);
});

// ---------------------------------------------------------------------------
// Edge contract (source-level equivalences that need no live DB)
// ---------------------------------------------------------------------------
test('catalog-coupons mirrors the canonical 0081 live predicate exactly', () => {
  const m0081 = read('supabase/migrations/0081_coupons.sql');
  // 0081: valid_from inclusive, valid_until exclusive.
  assert.match(m0081, /p_valid_from <= now\(\)/i);
  assert.match(m0081, /p_valid_until IS NULL OR p_valid_until > now\(\)/i);
  // Edge: the same boundaries, expressed as PostgREST filters.
  assert.match(edge, /\.lte\('valid_from', now\)/);
  assert.match(edge, /valid_until\.is\.null,valid_until\.gt\.\$\{now\}/);
  assert.doesNotMatch(edge, /valid_until\.gte\./);
  assert.match(edge, /\.eq\('is_active', true\)/);
  // The category-active rule is enforced in the mapper, not via an embedded
  // filter (no unverifiable PostgREST alias syntax on the hot path).
  assert.match(edge, /coupon_categories!inner/);
  assert.match(edge, /if \(cat\.is_active === false\) return null;/);
});

test('catalog-coupons performs no write and emits no analytics event', () => {
  const code = edge
    .split('\n')
    .map((l) => l.replace(/(^|[^:])\/\/.*$/, '$1'))
    .filter((l) => {
      const t = l.trim();
      return !t.startsWith('*') && !t.startsWith('/*') && !t.startsWith('*/');
    })
    .join('\n');
  for (const forbidden of [
    'record_coupon_event', 'coupon_metrics_daily', 'record_engagement_event',
    '.insert(', '.update(', '.upsert(', '.delete(', '.rpc(',
  ]) {
    assert.ok(!code.includes(forbidden), `catalog-coupons must not use ${forbidden}`);
  }
});

// ---------------------------------------------------------------------------
// Isolation & phase boundaries
// ---------------------------------------------------------------------------
test('C2 touches no closed contract and bumps no client schema', () => {
  for (const token of [
    'user_transactions', 'user_accounts', 'user_budgets', 'user_goals',
    'user_settings', 'revision', 'amount_minor', 'planning', 'backup',
    'capture_devices', 'notification',
  ]) {
    assert.doesNotMatch(sql, new RegExp(`\\b${token}\\b`, 'i'), `0082 must not touch ${token}`);
  }
  const alters = sql.match(/ALTER TABLE (\w+)/gi) || [];
  assert.deepEqual(alters, ['ALTER TABLE coupon_metrics_daily']);
  // The client schema is owned by the mobile phases; this SERVER migration never
  // bumps or references it. The version pin tracks the current APPROVED value —
  // v33 is owned by Proof-Carrying (capture_work_items, capture_review_labels).
  // A literal pin here rots on every legitimate bump, so the load-bearing claim
  // is the SQL assertion below; this line only catches an UNAPPROVED bump.
  // Schema 35 -> 38. The pin is an ABSOLUTE version by design: it fails if a
  // SERVER migration bumps the CLIENT schema. It also has to be re-pinned
  // whenever the client legitimately migrates, which is what went stale here —
  // the client reached 38 on 2026-09-06 (cd7174a0, correctness provenance) and
  // 39 with WP-3a (replica_meta, per-UID replicas) and
  // 40 with WP-6 (versioned per-replica consent columns on user_settings),
  // 41 with WP-5 (outbox operation_id/base_revision columns + sync_conflicts),
  // weeks after these tests were last touched, and none of those bumps came
  // from the server migration under test. Assertion unchanged, value current.
  // Pinned to the current client schema. v44 (2026-11) is the device-only rule
  // deletion history for merge restore; this server feature still bumps nothing.
  assert.match(read('app/lib/data/db/app_database.dart'), /const int _targetSchemaVersion = 45;/);
  assert.doesNotMatch(sql, /_targetSchemaVersion|drift/i);
});

test('migration numbering: the original Coupon pair is immutable and unique', () => {
  const files = readdirSync(new URL('supabase/migrations/', root)).filter((f) => f.endsWith('.sql'));
  assert.ok(files.includes('0081_coupons.sql'));
  assert.ok(files.includes('0082_coupon_metrics.sql'));
  assert.equal(files.filter((f) => f.startsWith('0082')).length, 1);

  // This previously asserted that 0081/0082 were the ONLY coupon migrations —
  // "0082 is the Coupon ceiling". That stopped being true when Phase 1
  // legitimately extended the domain (0095 adds structured offer economics to
  // the same table), and the assertion was failing on correct work.
  //
  // The durable invariant was never "the domain stops here". It is that the two
  // SHIPPED migrations are never renumbered or repurposed, and that later coupon
  // work arrives as NEW files numbered above them — because editing an applied
  // migration changes what a fresh database gets without changing what an
  // existing one has.
  const coupon = files.filter((f) => /coupon/i.test(f)).sort();
  assert.deepEqual(coupon.slice(0, 2), ['0081_coupons.sql', '0082_coupon_metrics.sql']);
  for (const later of coupon.slice(2)) {
    assert.ok(Number(later.split('_', 1)[0]) > 82,
      `a coupon migration must be numbered above the shipped pair: ${later}`);
  }

  const numbers = files.map((f) => f.split('_', 1)[0]);
  assert.equal(new Set(numbers).size, numbers.length, 'no duplicate migration number');
});
