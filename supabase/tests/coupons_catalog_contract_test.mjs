// Coupons Phase C1 — static contract checks for migration 0081 (coupon catalog,
// RLS and Storage foundation). These run WITHOUT credentials; the live
// behavioural matrix is in coupons_rls_live_node_test.mjs (credential-gated).
//
// The contract asserted here is the approved r2 specification:
// docs/COUPONS_ADMIN_SYSTEM.md + docs/COUPONS_APP_EXPERIENCE.md.
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const M = 'supabase/migrations/0081_coupons.sql';
const raw = read(M);

/** Strip `--` comment lines so structural assertions test SQL, not prose. */
const stripComments = (sql) =>
  sql
    .split('\n')
    .filter((line) => !line.trimStart().startsWith('--'))
    .join('\n');
const sql = stripComments(raw);

// ---------------------------------------------------------------------------
// Tables & ownership
// ---------------------------------------------------------------------------
test('0081 creates exactly the four approved catalog tables', () => {
  for (const t of ['coupon_categories', 'coupon_tags', 'coupons', 'coupon_tag_links']) {
    assert.match(sql, new RegExp(`CREATE TABLE IF NOT EXISTS ${t}\\s*\\(`, 'i'), t);
  }
  // Analytics belongs to a later phase (0082) — must NOT appear here.
  assert.doesNotMatch(sql, /coupon_metrics_daily/i);
  assert.doesNotMatch(sql, /record_coupon_event/i);
});

test('tags use the normalized join model — no tags[] array column on coupons', () => {
  assert.doesNotMatch(sql, /^\s*tags\s+TEXT\[\]/im);
  assert.match(sql, /CREATE TABLE IF NOT EXISTS coupon_tag_links[\s\S]*?PRIMARY KEY \(coupon_id, tag_id\)/i);
  assert.match(sql, /coupon_id\s+UUID NOT NULL REFERENCES coupons\(id\)\s+ON DELETE CASCADE/i);
  assert.match(sql, /tag_id\s+UUID NOT NULL REFERENCES coupon_tags\(id\) ON DELETE CASCADE/i);
  assert.match(sql, /key\s+TEXT NOT NULL UNIQUE/i); // coupon_tags.key uniqueness
});

test('display category is Coupon-owned; spend hints carry NO foreign key', () => {
  assert.match(
    sql,
    /display_category_key TEXT NOT NULL REFERENCES coupon_categories\(key\)/i,
  );
  // The hints array must never reference a financial category table.
  assert.match(sql, /spend_hint_category_keys TEXT\[\] NOT NULL DEFAULT '\{\}'/i);
  assert.doesNotMatch(sql, /spend_hint_category_keys[^,]*REFERENCES/i);
});

// ---------------------------------------------------------------------------
// Constraints
// ---------------------------------------------------------------------------
test('redemption shapes are enforced at the database', () => {
  assert.match(sql, /redemption_type TEXT NOT NULL CHECK \(redemption_type IN \('code', 'link'\)\)/i);
  const c = sql.match(/CONSTRAINT coupons_redemption_shape CHECK \(([\s\S]*?)\n  \),/i);
  assert.ok(c, 'coupons_redemption_shape present');
  // code: non-empty code required. link: code must be NULL, destination required.
  assert.match(c[1], /redemption_type = 'code' AND code IS NOT NULL AND btrim\(code\) <> ''/i);
  assert.match(c[1], /redemption_type = 'link' AND code IS NULL AND partner_url IS NOT NULL/i);
});

test('destination URLs are https-only (no dangerous schemes)', () => {
  assert.match(
    sql,
    /CONSTRAINT coupons_url_https CHECK \(\s*partner_url IS NULL OR partner_url LIKE 'https:\/\/%'/i,
  );
});

test('country targeting: empty array = global, else ISO alpha-2 uppercase', () => {
  const c = sql.match(/CONSTRAINT coupons_country_codes_shape CHECK \(([\s\S]*?)\n  \),/i);
  assert.ok(c, 'coupons_country_codes_shape present');
  assert.match(c[1], /country_codes = '\{\}'::text\[\]/i);
  assert.match(c[1], /\^\[A-Z\]\{2\}\(,\[A-Z\]\{2\}\)\*\$/);
  // The demo's 'ALL' literal must not survive anywhere in the schema.
  assert.doesNotMatch(sql, /'ALL'/);
});

test('normalized keys, presentation and window constraints are deterministic', () => {
  assert.match(sql, /CONSTRAINT coupon_categories_key_shape CHECK \(key ~ '\^\[a-z0-9_\]\{2,32\}\$'\)/i);
  assert.match(sql, /CONSTRAINT coupon_tags_key_shape CHECK \(key ~ '\^\[a-z0-9_/i);
  assert.match(sql, /CONSTRAINT coupons_accent_hex_shape CHECK/i);
  assert.match(sql, /CONSTRAINT coupons_window_order CHECK/i);
  // Storage paths are server-derived: no client-shaped or traversing path.
  assert.match(sql, /CONSTRAINT coupons_image_path_shape CHECK/i);
  assert.match(sql, /\^coupons\/\[0-9a-f-\]\{36\}\//i);
});

// ---------------------------------------------------------------------------
// Canonical live predicate + scheduling
// ---------------------------------------------------------------------------
test('ONE canonical live predicate exists and RLS uses it', () => {
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.coupon_is_live\(/i);
  assert.match(sql, /p_valid_from <= now\(\)/i);                       // inclusive start
  assert.match(sql, /p_valid_until IS NULL OR p_valid_until > now\(\)/i); // exclusive end
  assert.match(sql, /COALESCE\(p_is_active, false\)/i);
  // Both coupon SELECT policies must delegate to it (never re-spell the rule).
  const uses = sql.match(/public\.coupon_is_live\(is_active, valid_from, valid_until\)/gi) || [];
  assert.ok(uses.length >= 2, `policies use coupon_is_live (found ${uses.length})`);
});

test('activation is the soft-delete: no deleted_at column in the coupon domain', () => {
  assert.doesNotMatch(sql, /deleted_at/i);
  assert.match(sql, /is_active      BOOLEAN NOT NULL DEFAULT true/i);
});

// ---------------------------------------------------------------------------
// RLS
// ---------------------------------------------------------------------------
test('RLS is enabled on all four tables', () => {
  for (const t of ['coupons', 'coupon_categories', 'coupon_tags', 'coupon_tag_links']) {
    assert.match(sql, new RegExp(`ALTER TABLE ${t}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), t);
  }
});

test('read policies name anon AND authenticated explicitly (no inheritance assumed)', () => {
  // coupons
  assert.match(sql, /CREATE POLICY coupons_live_select_anon ON coupons\s+FOR SELECT TO anon/i);
  assert.match(sql, /CREATE POLICY coupons_live_select_authenticated ON coupons\s+FOR SELECT TO authenticated/i);
  // categories
  assert.match(sql, /coupon_categories_active_select_anon[\s\S]*?FOR SELECT TO anon USING \(is_active = true\)/i);
  assert.match(sql, /coupon_categories_active_select_authenticated[\s\S]*?FOR SELECT TO authenticated USING \(is_active = true\)/i);
  // tags + links (least exposure: only via a live coupon)
  for (const p of [
    'coupon_tags_linked_select_anon',
    'coupon_tags_linked_select_authenticated',
    'coupon_tag_links_live_select_anon',
    'coupon_tag_links_live_select_authenticated',
  ]) {
    assert.match(sql, new RegExp(`CREATE POLICY ${p} ON`, 'i'), p);
  }
});

test('NO client write policy exists on any coupon table', () => {
  const writePolicy = /CREATE POLICY[\s\S]*?FOR (INSERT|UPDATE|DELETE|ALL)/i;
  assert.doesNotMatch(sql, writePolicy);
  // …and privileges are SELECT-only for both client roles.
  assert.match(
    sql,
    /REVOKE ALL ON TABLE coupons, coupon_categories, coupon_tags, coupon_tag_links\s+FROM anon, authenticated/i,
  );
  assert.match(
    sql,
    /GRANT SELECT ON TABLE coupons, coupon_categories, coupon_tags, coupon_tag_links\s+TO anon, authenticated/i,
  );
  assert.doesNotMatch(sql, /GRANT (INSERT|UPDATE|DELETE|ALL)[^;]*TO (anon|authenticated)/i);
});

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------
test('coupon-assets bucket is public-read with a size limit and MIME allowlist', () => {
  assert.match(sql, /INSERT INTO storage\.buckets[\s\S]*?'coupon-assets'/i);
  assert.match(sql, /524288/); // <= 512 KB
  assert.match(sql, /ARRAY\['image\/webp', 'image\/png', 'image\/jpeg'\]/i);
  assert.doesNotMatch(sql, /image\/svg/i); // SVG is rejected outright
});

test('storage: public read only — no client insert/update/delete policy', () => {
  assert.match(
    sql,
    /CREATE POLICY "coupon assets public read" ON storage\.objects\s+FOR SELECT TO anon, authenticated/i,
  );
  const storagePolicies = sql.match(/CREATE POLICY "[^"]*" ON storage\.objects[\s\S]*?FOR (\w+)/gi) || [];
  for (const p of storagePolicies) {
    assert.match(p, /FOR SELECT/i, `only SELECT policies on storage.objects: ${p}`);
  }
});

// ---------------------------------------------------------------------------
// Security posture
// ---------------------------------------------------------------------------
test('0081 adds no definer-rights function and pins search_path on its functions', () => {
  assert.doesNotMatch(sql, /SECURITY\s+DEFINER/i);
  const fns = sql.match(/CREATE OR REPLACE FUNCTION public\.\w+/gi) || [];
  assert.equal(fns.length, 2, 'exactly coupon_is_live + the deactivation guard');
  const setSearchPath = sql.match(/SET search_path = pg_catalog, public, pg_temp/gi) || [];
  assert.equal(setSearchPath.length, 2, 'both functions pin search_path');
});

test('category deactivation while live coupons use it is blocked by a trigger', () => {
  assert.match(sql, /CREATE OR REPLACE FUNCTION public\.coupon_categories_block_deactivate_in_use\(\)/i);
  assert.match(sql, /IF OLD\.is_active AND NOT NEW\.is_active THEN/i);
  assert.match(sql, /RAISE EXCEPTION[\s\S]*?cannot deactivate/i);
  assert.match(sql, /CREATE TRIGGER trg_coupon_categories_block_deactivate/i);
  // Deleting a category in use is blocked by the FK (no ON DELETE action).
  assert.doesNotMatch(sql, /REFERENCES coupon_categories\(key\)\s+ON DELETE/i);
});

test('updated_at reuses the existing project trigger convention', () => {
  const triggers = sql.match(/EXECUTE FUNCTION set_updated_at\(\)/gi) || [];
  assert.equal(triggers.length, 3, 'coupons + categories + tags');
  assert.doesNotMatch(sql, /CREATE OR REPLACE FUNCTION\s+(public\.)?set_updated_at/i);
});

// ---------------------------------------------------------------------------
// Architecture isolation — 0081 must not touch any closed contract
// ---------------------------------------------------------------------------
test('0081 modifies no financial / sync / backup / capture contract', () => {
  const forbidden = [
    'user_transactions', 'user_accounts', 'user_budgets', 'user_goals',
    'user_subscriptions', 'user_plans', 'user_cards', 'user_categories',
    'user_settings', 'user_goal_contributions', 'user_bill_payments',
    'user_plan_transaction_links', 'backup', 'capture_devices', 'captures',
    'revision', 'amount_minor', 'planning',
  ];
  for (const token of forbidden) {
    assert.doesNotMatch(
      sql,
      new RegExp(`\\b${token}\\b`, 'i'),
      `0081 must not reference ${token}`,
    );
  }
  // No ALTER/DROP of anything pre-existing: the migration only creates its own
  // domain (the sole ALTERs are ENABLE ROW LEVEL SECURITY on its own tables).
  const alters = sql.match(/ALTER TABLE (\w+)/gi) || [];
  for (const a of alters) {
    assert.match(
      a,
      /ALTER TABLE coupon/i,
      `only coupon-domain ALTERs allowed, found: ${a}`,
    );
  }
  assert.doesNotMatch(sql, /\bDROP TABLE\b/i);
  assert.doesNotMatch(sql, /\bALTER COLUMN\b/i);
});

test('the catalog migration exists and the client schema is untouched by it', () => {
  const files = readdirSync(new URL('supabase/migrations/', root)).filter((f) => f.endsWith('.sql'));
  assert.ok(files.includes('0081_coupons.sql'));
  // Analytics live in their own migration (0082, Phase C2) — never folded into
  // the catalog one. The C2 contract test owns the next phase boundary.
  assert.doesNotMatch(sql, /coupon_metrics_daily|record_coupon_event/i);
  // The client schema is owned by the mobile phases; this SERVER migration never
  // bumps or references it. The version pin tracks the current APPROVED value —
  // v33 is owned by Proof-Carrying (capture_work_items, capture_review_labels).
  // A literal pin here rots on every legitimate bump, so the load-bearing claim
  // is the SQL assertion below; this line only catches an UNAPPROVED bump.
  const db = read('app/lib/data/db/app_database.dart');
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
  assert.match(db, /const int _targetSchemaVersion = 44;/);
  assert.doesNotMatch(sql, /_targetSchemaVersion|drift/i);
});
