// Phase R1 — static contract checks for 0083_referral_rewards.sql.
//
// These run WITHOUT credentials and WITHOUT a local Postgres: they assert the
// SOURCE contract (schema shape, invariants, privilege lockdown, isolation).
// Runtime behaviour — actually applying the migration and exercising RLS/RPCs —
// is deliberately NOT claimed here and is deferred to the staging phase.
//
// The contract asserted is docs/REFERRAL_REWARDS_SYSTEM.md r3.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const M = 'supabase/migrations/0083_referral_rewards.sql';
const raw = read(M);

/** Strip `--` comment lines so structural assertions test SQL, not prose. */
const sql = raw
  .split('\n')
  .filter((line) => !line.trimStart().startsWith('--'))
  .join('\n');

/**
 * The part of 0083 this migration AUTHORS. The tail re-declares 0065's
 * purge_user_data, whose inherited body legitimately names financial and
 * capture tables (install_id_hash, user_transactions, …); isolation guards must
 * scan only the referral-owned portion or they would flag 0065's own code.
 */
const referralOwned = sql.slice(
  0, sql.indexOf('create or replace function public.purge_user_data'));

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------
test('0083 creates exactly the eight approved tables', () => {
  for (const t of [
    'referral_codes', 'referrals', 'referral_reward_rules',
    'referral_reward_progress', 'user_entitlement_state',
    'entitlement_events', 'referral_reward_grants', 'referral_admin_audit',
  ]) {
    assert.match(sql, new RegExp(`CREATE TABLE IF NOT EXISTS public\\.${t}\\s*\\(`, 'i'), t);
  }
  // r3 eliminated the report-ads config table; 0084 must not be implied.
  assert.doesNotMatch(sql, /report_ads_config/i);
});

// ---------------------------------------------------------------------------
// Hard invariants — the ones that make the product claims true
// ---------------------------------------------------------------------------
test('one referred account may have at most one referrer, ever', () => {
  assert.match(sql, /referred_user_id\s+UUID NULL UNIQUE REFERENCES auth\.users\(id\) ON DELETE SET NULL/i);
});

test('self-referral is impossible at the database level', () => {
  assert.match(sql, /CONSTRAINT referrals_no_self CHECK \(referrer_user_id <> referred_user_id\)/i);
});

test('one milestone grants at most once (exactly-once invariant)', () => {
  assert.match(sql, /UNIQUE \(referrer_user_id, rule_id, cycle_index\)/i);
});

test('one current entitlement per user + type', () => {
  assert.match(sql, /PRIMARY KEY \(user_id, entitlement_type\)/i);
});

test('operation_id is unique and bound to a canonical fingerprint', () => {
  assert.match(sql, /operation_id\s+TEXT NOT NULL UNIQUE/i);
  assert.match(sql, /operation_fingerprint\s+TEXT NOT NULL/i);
  // A replay with a different intent must be refused, not silently answered.
  assert.match(sql, /idempotency_mismatch/);
  const mismatches = sql.match(/idempotency_mismatch/g) ?? [];
  assert.ok(mismatches.length >= 2, 'checked before AND after the claim');
});

test('R1.1: the fingerprint is a canonical SHA-256 of the REQUESTED intent', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const fp = body.slice(body.indexOf('v_fingerprint :='),
                        body.indexOf("'hex');") + 7);

  // SHA-256 via pgcrypto — MD5 is gone.
  assert.match(fp, /digest\(/);
  assert.match(fp, /'sha256'/);
  assert.doesNotMatch(body, /md5\(/i);
  assert.match(fp, /convert_to\([\s\S]*?'UTF8'\)/);
  assert.match(fp, /encode\(/);

  // Canonical structured payload, NOT delimiter-joined concatenation — with a
  // separator, ('a|b','c') and ('a','b|c') would collide onto one fingerprint.
  assert.match(fp, /jsonb_build_object\(/);
  assert.doesNotMatch(fp, /concat_ws/);

  // Every field needed to distinguish one mutation from another is bound in.
  for (const field of ['actor', 'target_user', 'entitlement_type', 'event_type',
                       'source', 'duration_days', 'source_reference',
                       'rule_id', 'rule_version', 'cycle_index', 'reason']) {
    assert.ok(fp.includes(`'${field}'`), `fingerprint must bind ${field}`);
  }

  // …and NOTHING derived from current state, or a replay would never match.
  for (const derived of ['resulting_ends_at', 'resulting_status', 'v_new_ends',
                         'v_new_status', 'v_prev', 'now()']) {
    assert.equal(fp.includes(derived), false, `fingerprint must exclude ${derived}`);
  }

  // Normalization: canonical case for enums/uuids, deterministic reason.
  assert.match(fp, /lower\(p_user_id::text\)/);
  assert.match(fp, /lower\(p_entitlement_type\)/);
  assert.match(fp, /lower\(p_event_type\)/);
  assert.match(fp, /lower\(p_actor_admin_id::text\), 'system'/);
  assert.match(fp, /btrim\(regexp_replace\(coalesce\(p_reason, ''\), '\\s\+', ' ', 'g'\)\)/);
});

test('R1.1: replay/mismatch semantics are enforced on both paths', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));

  // Pre-claim path: existing row with a DIFFERENT intent → mismatch, no write.
  const pre = body.slice(0, body.indexOf('INSERT INTO public.entitlement_events'));
  assert.match(pre, /operation_fingerprint <> v_fingerprint[\s\S]{0,160}idempotency_mismatch/i);
  assert.match(pre, /'duplicate', true/); // same intent → stored result
  // The mismatch raises BEFORE any state mutation is computed or applied.
  assert.ok(pre.indexOf('idempotency_mismatch')
          < body.indexOf('INSERT INTO public.user_entitlement_state'));

  // Post-claim path (the concurrent racer that lost the unique claim) repeats
  // the same comparison, so a conflicting concurrent intent also mismatches.
  const post = body.slice(body.indexOf('GET DIAGNOSTICS v_rowcount = ROW_COUNT'));
  assert.match(post, /v_rowcount = 0[\s\S]*?operation_fingerprint <> v_fingerprint[\s\S]{0,160}idempotency_mismatch/i);

  // A duplicate never reaches the state upsert.
  const dupReturn = post.indexOf("'duplicate', true");
  const stateUpsert = post.indexOf('INSERT INTO public.user_entitlement_state');
  assert.ok(dupReturn !== -1 && dupReturn < stateUpsert,
    'the duplicate path returns before the state upsert');
});

test('at most one active rule per reward type is structurally enforced', () => {
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS referral_rules_one_active_per_type[\s\S]*?WHERE is_active/i);
  // …and the reader still fails closed rather than picking an arbitrary row.
  assert.match(sql, /ambiguous_rule_configuration/);
});

test('rule values cannot be nonsensical', () => {
  assert.match(sql, /required_referrals > 0/i);
  assert.match(sql, /reward_days > 0/i);
  assert.match(sql, /effective_until IS NULL OR effective_until > effective_from/i);
});

// ---------------------------------------------------------------------------
// Referral code
// ---------------------------------------------------------------------------
test('referral codes are 8 chars, canonical, and exclude ambiguous glyphs', () => {
  const check = sql.match(/CONSTRAINT referral_codes_shape CHECK \(code ~ '([^']+)'\)/i);
  assert.ok(check, 'code shape CHECK present');
  const pattern = check[1];
  assert.equal(pattern, '^[2-9A-HJKMNP-TV-Z]{8}$');
  const re = new RegExp(pattern);
  assert.ok(re.test('QK7F9X2M'), 'accepts a canonical code');
  for (const bad of ['qk7f9x2m', 'QK7F9X2', 'QK7F9X2MM', 'QKOF9X2M', 'QK0F9X2M',
                     'QKIF9X2M', 'QK1F9X2M', 'QKLF9X2M']) {
    assert.equal(re.test(bad), false, `must reject ${bad}`);
  }
});

test('R1.1: code generation is CSPRNG + UNBIASED rejection sampling', () => {
  assert.match(sql, /gen_random_bytes\(/);
  assert.doesNotMatch(sql, /\brandom\(\)/); // never the non-crypto PRNG

  const fn = sql.slice(sql.indexOf('FUNCTION public.generate_referral_code'));
  const body = fn.slice(0, fn.indexOf('END $$;'));

  // A rejection boundary must exist and must be a multiple of the alphabet
  // size — that is exactly what removes the modulo bias.
  const limit = Number(body.match(/v_limit\s+CONSTANT INTEGER := (\d+)/)[1]);
  const n = Number(body.match(/v_n\s+CONSTANT INTEGER := (\d+)/)[1]);
  assert.equal(n, 30, 'alphabet size');
  assert.equal(limit % n, 0, 'rejection boundary divides the alphabet evenly');
  assert.equal(limit, 240, 'largest multiple of 30 within a byte');
  assert.ok(limit <= 256);
  // Bytes at or above the boundary are discarded, not folded in.
  assert.match(body, /CONTINUE WHEN v_byte >= v_limit/i);
  // Naive biased mapping over the full byte range must not reappear.
  assert.doesNotMatch(body, /get_byte\([^)]*\) % 30/);
  // The invariants are asserted at runtime too, not just trusted here.
  assert.match(body, /char_length\(v_alphabet\) <> v_n OR v_limit % v_n <> 0/);
  assert.match(body, /referral_code_alphabet_invalid/);
  // Exactly 8 characters, and a bounded loop guard.
  assert.match(body, /char_length\(v_code\) < 8 LOOP/);
  assert.match(body, /char_length\(v_code\) >= 8/);
  assert.match(body, /guard > 64/);
  assert.match(body, /referral_code_generation_failed/);

  // The alphabet literal is exactly the approved 30 symbols, no ambiguity.
  const alphabet = body.match(/v_alphabet CONSTANT TEXT\s+:= '([^']+)'/)[1];
  assert.equal(alphabet.length, 30);
  assert.equal(new Set(alphabet).size, 30, 'no duplicate symbols');
  for (const ambiguous of ['O', '0', 'I', '1', 'L']) {
    assert.equal(alphabet.includes(ambiguous), false, ambiguous);
  }
  assert.match(alphabet, /^[2-9A-HJKMNP-TV-Z]+$/);
});

test('R1.1: the DB UNIQUE remains the final collision authority', () => {
  assert.match(sql, /code       TEXT NOT NULL UNIQUE/i);
  // ensure_referral_code retries on collision, bounded, and never degrades.
  const fn = sql.slice(sql.indexOf('FUNCTION public.ensure_referral_code'));
  const body = fn.slice(0, fn.indexOf('END $$;'));
  assert.match(body, /WHILE attempt < 5 LOOP/i);
  assert.match(body, /EXCEPTION WHEN unique_violation/i);
  assert.match(body, /referral_code_generation_failed/);
});

test('a user cannot choose or derive their own code', () => {
  // No client write path exists to referral_codes, and generation is definer-only.
  assert.doesNotMatch(sql, /CREATE POLICY[^;]*referral_codes[^;]*FOR (INSERT|UPDATE|DELETE|ALL)/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.generate_referral_code\(\)\s+FROM PUBLIC, anon, authenticated/i);
  assert.match(sql, /REVOKE ALL ON FUNCTION public\.ensure_referral_code\(UUID\)\s+FROM PUBLIC, anon, authenticated/i);
});

// ---------------------------------------------------------------------------
// Statuses / cycle semantics
// ---------------------------------------------------------------------------
test('referral statuses are exactly the approved four', () => {
  assert.match(sql, /status IN \('attributed', 'qualified', 'rejected', 'reversed'\)/i);
});

/**
 * Parse the real qualified_at CHECK out of the migration into
 * `{ statuses[], requiresTimestamp }` clauses, so the lifecycle table below is
 * DERIVED from the shipped SQL rather than restated alongside it.
 */
function qualifiedAtClauses() {
  const block = sql.slice(sql.indexOf('CONSTRAINT referrals_qualified_at_shape'));
  const body = block.slice(0, block.indexOf('\n  )') + 3);
  const clauses = [...body.matchAll(
    /status IN \(([^)]*)\)\s+AND qualified_at IS (NOT )?NULL/gi)]
    .map((m) => ({
      statuses: m[1].split(',').map((x) => x.trim().replace(/'/g, '')),
      requiresTimestamp: Boolean(m[2]),
    }));
  assert.equal(clauses.length, 2, 'exactly two lifecycle clauses');
  return clauses;
}

/** Evaluate the parsed CHECK for one (status, qualified_at) pair. */
function checkAllows(status, hasTimestamp) {
  return qualifiedAtClauses().some(
    (c) => c.statuses.includes(status) && c.requiresTimestamp === hasTimestamp);
}

test('lifecycle: qualified_at is required exactly for qualified and reversed', () => {
  // A–D: valid combinations
  assert.equal(checkAllows('attributed', false), true, 'A attributed + NULL');
  assert.equal(checkAllows('rejected',   false), true, 'B rejected + NULL');
  assert.equal(checkAllows('qualified',  true),  true, 'C qualified + timestamp');
  assert.equal(checkAllows('reversed',   true),  true, 'D reversed + timestamp');
  // E–H: rejected combinations
  assert.equal(checkAllows('qualified',  false), false, 'E qualified + NULL');
  assert.equal(checkAllows('reversed',   false), false, 'F reversed + NULL');
  assert.equal(checkAllows('attributed', true),  false, 'G attributed + timestamp');
  assert.equal(checkAllows('rejected',   true),  false, 'H rejected + timestamp');
});

test('fraud reversal preserves the original qualification timestamp', () => {
  // 'reversed' REQUIRES qualified_at, so a reversal that cleared it would be
  // rejected by the database — the evidence cannot be erased.
  assert.equal(checkAllows('reversed', false), false);
  // …and nothing in the migration ever nulls qualified_at.
  assert.doesNotMatch(sql, /qualified_at\s*=\s*NULL/i);
  assert.doesNotMatch(sql, /SET[^;]*qualified_at\s*=\s*null/i);
});

test('V1 attribution is manual_code (direct_link reserved, not used)', () => {
  assert.match(sql, /attribution_method IN \('manual_code', 'direct_link'\)/i);
  assert.match(sql, /attribution_method\s+TEXT NOT NULL DEFAULT 'manual_code'/i);
  assert.match(sql, /'manual_code', 'attributed'\)/);
});

test('cycle state models open / awaiting_rule / completed, and pins a rule when open', () => {
  assert.match(sql, /cycle_state IN \('open', 'awaiting_rule', 'completed'\)/i);
  assert.match(sql, /CONSTRAINT referral_progress_open_is_pinned[\s\S]*?cycle_state = 'open'\s+AND pinned_rule_id IS NOT NULL/i);
});

test('progress is a stored counter, never recomputed from referral rows', () => {
  // The advance is an increment on the progress row…
  assert.match(sql, /SET qualified_in_cycle = qualified_in_cycle \+ 1/i);
  // …and qualification never counts referral rows to derive progress.
  assert.doesNotMatch(sql, /count\(\*\)[\s\S]{0,120}FROM public\.referrals/i);
});

test('no open cycle + no active rule returns awaiting_active_rule and keeps the attribution', () => {
  assert.match(sql, /'awaiting_active_rule'/);
  // The guarded flip to qualified must come AFTER that early return.
  const idxAwaiting = sql.indexOf("'awaiting_active_rule'");
  const idxFlip = sql.indexOf("SET status = 'qualified'");
  assert.ok(idxAwaiting < idxFlip,
    'the awaiting_active_rule exit precedes any qualified transition');
});

// ---------------------------------------------------------------------------
// Exactly-once qualification ordering
// ---------------------------------------------------------------------------
test('qualification follows the approved atomic ordering', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.qualify_referral_internal'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const order = [
    "SET status = 'qualified'",                    // 1 guarded transition
    'SET qualified_in_cycle = qualified_in_cycle + 1', // 2 progress advance
    'INSERT INTO public.referral_reward_grants',   // 3 unique milestone claim
    'public.apply_entitlement_mutation',           // 4 event + state
    'UPDATE public.referral_reward_grants',        // 5 complete grant record
  ];
  let cursor = -1;
  for (const step of order) {
    const at = body.indexOf(step);
    assert.ok(at > cursor, `step out of order: ${step}`);
    cursor = at;
  }
  // The guarded transition proves ownership via ROW_COUNT before advancing.
  assert.match(body, /GET DIAGNOSTICS v_rowcount = ROW_COUNT;[\s\S]{0,200}IF v_rowcount = 0 THEN/i);
});

test('the fifth grants once and the sixth starts the next cycle at 0', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.qualify_referral_internal'));
  assert.match(fn, /ON CONFLICT \(referrer_user_id, rule_id, cycle_index\) DO NOTHING/i);
  assert.match(fn, /SET cycle_index = cycle_index \+ 1, qualified_in_cycle = 0/i);
  // Non-repeatable terminates instead of opening a new cycle.
  assert.match(fn, /cycle_state = 'completed'/i);
});

test('there is ONE qualification algorithm, reused inline and on request', () => {
  const inline = sql.slice(sql.indexOf('FUNCTION public.apply_referral_code'));
  assert.match(inline, /public\.qualify_referral_internal\(v_uid\)/);
  const deferred = sql.slice(sql.indexOf('FUNCTION public.request_referral_qualification'));
  assert.match(deferred, /public\.qualify_referral_internal\(v_uid\)/);
});

// ---------------------------------------------------------------------------
// Verified identity authority
// ---------------------------------------------------------------------------
test('verified identity is read from server auth truth, never a client claim', () => {
  assert.match(sql, /auth\.users u[\s\S]{0,120}email_confirmed_at IS NOT NULL/i);
  assert.match(sql, /auth\.identities i[\s\S]{0,120}provider IN \('google', 'apple'\)/i);
  // No client-asserted verification or onboarding boolean anywhere.
  assert.doesNotMatch(sql, /is_?verified/i);
  assert.doesNotMatch(sql, /onboarding/i);
});

test('request_referral_qualification is argument-free and self-only', () => {
  assert.match(sql, /FUNCTION public\.request_referral_qualification\(\)/);
  const fn = sql.slice(sql.indexOf('FUNCTION public.request_referral_qualification'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /v_uid\s+UUID := auth\.uid\(\)/);
  assert.doesNotMatch(body, /p_user_id|p_target/i); // no caller-supplied target
});

// ---------------------------------------------------------------------------
// Entitlement stacking & atomicity
// ---------------------------------------------------------------------------
test('stacking extends from max(now, active ends_at) and never shortens on grant', () => {
  assert.match(sql, /v_new_ends := greatest\(\s*now\(\),[\s\S]{0,200}make_interval\(days => p_duration_days\)/i);
  assert.match(sql, /v_prev\.status = 'active'[\s\S]{0,60}THEN v_prev\.ends_at ELSE now\(\) END/i);
});

test('event and state mutate in one transaction via an atomic upsert', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_entitlement_mutation'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  // claim → event insert → state upsert, all inside the one function body
  assert.match(body, /INSERT INTO public\.entitlement_events[\s\S]*?ON CONFLICT \(operation_id\) DO NOTHING/i);
  assert.match(body, /INSERT INTO public\.user_entitlement_state[\s\S]*?ON CONFLICT \(user_id, entitlement_type\) DO UPDATE/i);
  assert.ok(body.indexOf('INSERT INTO public.entitlement_events')
          < body.indexOf('INSERT INTO public.user_entitlement_state'),
    'the operation claim precedes the state change');
});

test('entitlement_events is append-only for clients and models all mutations', () => {
  assert.match(sql, /event_type IN \('grant', 'extend', 'shorten', 'revoke'\)/i);
  assert.doesNotMatch(sql, /CREATE POLICY[^;]*entitlement_events/i); // RLS on, zero policies
});

// ---------------------------------------------------------------------------
// RLS + privilege matrix
// ---------------------------------------------------------------------------
test('RLS is enabled on all eight tables', () => {
  for (const t of [
    'referral_codes', 'referrals', 'referral_reward_rules',
    'referral_reward_progress', 'user_entitlement_state',
    'entitlement_events', 'referral_reward_grants', 'referral_admin_audit',
  ]) {
    assert.match(sql, new RegExp(`ALTER TABLE public\\.${t}\\s+ENABLE ROW LEVEL SECURITY`, 'i'), t);
  }
});

test('R1.1: there is NO direct table read surface — RPC only', () => {
  // RLS is enabled everywhere with ZERO policies, so a direct table read
  // returns nothing no matter who asks.
  assert.doesNotMatch(sql, /CREATE POLICY/i);
  assert.doesNotMatch(sql, /GRANT SELECT ON TABLE/i);
  assert.match(sql, /REVOKE ALL ON TABLE[\s\S]*?FROM anon, authenticated/i);
});

test('R1.1: referrer/referee cannot read referrals and learn the other party', () => {
  // A referrals row necessarily holds BOTH user ids, so any owner-read policy
  // would disclose a cross-account identifier. There must be none.
  assert.doesNotMatch(sql, /referrals_party_select/i);
  assert.doesNotMatch(sql, /referrer_user_id = auth\.uid\(\) OR referred_user_id = auth\.uid\(\)/i);
  // The self-only summary RETURNS counts/status — never a counterpart id.
  // (Column names may legitimately appear in WHERE clauses that filter to the
  //  CALLER's own id; what matters is the payload that leaves the function.)
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_referral_summary'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const payload = body.slice(body.lastIndexOf('RETURN jsonb_build_object'));
  for (const leak of ['referrer_user_id', 'referred_user_id', 'user_id',
                      'email', 'phone', 'uuid']) {
    assert.doesNotMatch(payload, new RegExp(leak, 'i'), leak);
  }
  // Every referrals/progress read is scoped to the caller.
  for (const m of body.match(/referred_user_id\s*=\s*\S+/g) ?? []) {
    assert.match(m, /=\s*v_uid/, `unscoped referrals read: ${m}`);
  }
  for (const m of body.match(/referrer_user_id\s*=\s*\S+/g) ?? []) {
    assert.match(m, /=\s*v_uid/, `unscoped progress read: ${m}`);
  }
  // The referee's own attribution is exposed as a STATUS, not an identity.
  assert.match(payload, /'attribution_status'/);
});

test('NO client write policy exists on any referral table', () => {
  assert.doesNotMatch(sql, /CREATE POLICY/i); // no policies at all (R1.1)
  assert.match(sql, /REVOKE ALL ON TABLE[\s\S]*?FROM anon, authenticated/i);
  assert.doesNotMatch(sql, /GRANT (SELECT|INSERT|UPDATE|DELETE|ALL)[^;]*TO (anon|authenticated)/i);
});

// The §17 three-class EXECUTE matrix. Roles are PARSED out of the shipped
// REVOKE/GRANT statements rather than pattern-spotted, so a function that
// silently gains a role — or is added without any classification — fails here.
const INTERNAL_ONLY = [
  'generate_referral_code', 'ensure_referral_code', 'active_referral_rule',
  'qualify_referral_internal', 'referral_audit_allowlist',
  'referral_norm_reason', 'referral_admin_require_reason',
  'referral_admin_fingerprint', 'referral_admin_claim',
  'apply_entitlement_mutation',
];
const AUTHENTICATED_SELF_RPC = [
  'apply_referral_code', 'request_referral_qualification',
  'get_referral_summary', 'get_entitlement_decision',
];
const SERVICE_ROLE_ADMIN_RPC = [
  'admin_mutate_entitlement', 'admin_reject_referral', 'admin_reverse_referral',
  'admin_adjust_referral_progress', 'admin_rotate_referral_code',
  'admin_publish_reward_rule', 'admin_deactivate_reward_rule',
];

/** Roles a statement names, parsed from within a single `;`-terminated stmt. */
function roles(kind, name, keyword) {
  const re = new RegExp(
    `${kind} ON FUNCTION public\\.${name}\\([^;]*?${keyword}\\s+([A-Za-z_, \\n]+);`, 'i');
  const m = sql.match(re);
  return m ? new Set(m[1].split(',').map((r) => r.trim()).filter(Boolean)) : null;
}
const revoked = (n) => roles('REVOKE ALL', n, 'FROM');
const granted = (n) => roles('GRANT EXECUTE', n, 'TO');

test('R1.1 §17: INTERNAL_ONLY functions are executable by NO role', () => {
  for (const fn of INTERNAL_ONLY) {
    assert.deepEqual(revoked(fn), new Set(['PUBLIC', 'anon', 'authenticated', 'service_role']),
      `${fn} must be revoked from every role`);
    assert.equal(granted(fn), null, `${fn} must have no GRANT at all`);
  }
});

test('R1.1 §1: the entitlement primitive did NOT become the Admin entry point', () => {
  // The gap could have been "fixed" by granting this to service_role. That was
  // explicitly rejected: it would be a generic, unaudited state-update endpoint.
  assert.ok(revoked('apply_entitlement_mutation').has('service_role'));
  assert.doesNotMatch(sql, /GRANT EXECUTE ON FUNCTION public\.apply_entitlement_mutation/i);
  // …and the audited wrapper is the only thing that calls it.
  const callers = [...sql.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)\(/g)]
    .map((m) => m[1])
    .filter((fn) => {
      const body = sql.slice(sql.indexOf(`FUNCTION public.${fn}(`));
      return body.slice(0, body.indexOf('$$;')).includes('public.apply_entitlement_mutation(');
    });
  assert.deepEqual(callers.sort(),
    ['admin_mutate_entitlement', 'apply_entitlement_mutation', 'qualify_referral_internal']);
});

test('R1.1 §17: the four user RPCs are the entire authenticated surface', () => {
  for (const fn of AUTHENTICATED_SELF_RPC) {
    assert.deepEqual(revoked(fn), new Set(['PUBLIC', 'anon', 'service_role']), fn);
    assert.deepEqual(granted(fn), new Set(['authenticated']), fn);
  }
  const allGrantedToAuth = [...sql.matchAll(
    /GRANT EXECUTE ON FUNCTION public\.(\w+)\([^;]*?TO[^;]*?authenticated[^;]*?;/gi)].map((m) => m[1]);
  assert.deepEqual(allGrantedToAuth.sort(), [...AUTHENTICATED_SELF_RPC].sort());
});

test('R1.1 §17: Admin RPCs are service-role only, never authenticated', () => {
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    assert.deepEqual(revoked(fn), new Set(['PUBLIC', 'anon', 'authenticated']), fn);
    assert.deepEqual(granted(fn), new Set(['service_role']), fn);
  }
});

test('R1.1 §17: every function in 0083 is classified exactly once', () => {
  const defined = [...sql.matchAll(/CREATE OR REPLACE FUNCTION public\.(\w+)\(/g)]
    .map((m) => m[1]);
  const classified = [...INTERNAL_ONLY, ...AUTHENTICATED_SELF_RPC, ...SERVICE_ROLE_ADMIN_RPC];
  assert.equal(new Set(classified).size, classified.length, 'no function in two classes');
  for (const fn of defined) {
    if (fn === 'purge_user_data') continue; // inherited 0065 authority
    assert.ok(classified.includes(fn), `${fn} is not covered by the EXECUTE matrix`);
  }
});

test('every function pins search_path and is definer where it must be', () => {
  const fns = raw.split('CREATE OR REPLACE FUNCTION ').slice(1);
  assert.ok(fns.length >= 8);
  for (const fn of fns) {
    const name = fn.slice(0, fn.indexOf('('));
    const head = fn.slice(0, fn.indexOf('AS $$'));
    assert.match(head, /SET search_path/i, `${name} must pin search_path`);
  }
});

// ---------------------------------------------------------------------------
// Enumeration safety
// ---------------------------------------------------------------------------
test('apply_referral_code leaks no referrer identity and is self-only', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.apply_referral_code'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /v_uid\s+UUID := auth\.uid\(\)/);
  assert.match(body, /'invalid_code'/);
  // The returned objects carry only outcome fields — never referrer identity.
  for (const leak of ['email', 'phone', 'referrer_user_id', 'v_owner::text', 'display_name']) {
    assert.doesNotMatch(body, new RegExp(`jsonb_build_object[^;]*${leak}`, 'i'), leak);
  }
  assert.match(body, /'no_active_rule'/);
});

test('get_referral_summary returns counts and status, not referee identities', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_referral_summary'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  const payload = body.slice(body.lastIndexOf('RETURN jsonb_build_object'));
  assert.match(payload, /'server_now',\s+now\(\)/);
  for (const leak of ['email', 'phone', 'referred_user_id', 'referrer_user_id']) {
    assert.doesNotMatch(payload, new RegExp(leak, 'i'), leak);
  }
});

test('get_entitlement_decision exposes server_now and never encodes failure as inactive', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.get_entitlement_decision'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  assert.match(body, /'server_now', now\(\)/);
  assert.match(body, /'active',\s+coalesce\(v_ent\.status = 'active' AND v_ent\.ends_at > now\(\), false\)/i);
  // Unauthenticated raises rather than returning a decision.
  assert.match(body, /unauthenticated/);
});

// ---------------------------------------------------------------------------
// Audit privacy
// ---------------------------------------------------------------------------
test('audit before/after are allowlisted, never arbitrary dumps', () => {
  const fn = sql.slice(sql.indexOf('FUNCTION public.referral_audit_allowlist'));
  const body = fn.slice(0, fn.indexOf('$$;'));
  for (const k of ['entitlement_type', 'status', 'ends_at', 'duration_days',
                   'rule_id', 'rule_version', 'required_referrals', 'reward_days',
                   'repeatable', 'is_active', 'cycle_index', 'qualified_in_cycle',
                   'referral_status', 'rejection_reason']) {
    assert.ok(body.includes(`'${k}'`), `allowlist must contain ${k}`);
  }
  for (const forbidden of ['email', 'phone', 'balance', 'amount', 'transaction']) {
    assert.doesNotMatch(body, new RegExp(forbidden, 'i'), forbidden);
  }
});

test('admin reason is bounded plain text, validated in the database', () => {
  const shapes = sql.match(/char_length\(reason\) BETWEEN 4 AND 500/gi) ?? [];
  assert.ok(shapes.length >= 2, 'both audit and event reason are bounded');
  const ctrl = sql.match(/reason !~ '\[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F\]'/g) ?? [];
  assert.ok(ctrl.length >= 2, 'control characters rejected on both');
});

// ---------------------------------------------------------------------------
// Account deletion
// ---------------------------------------------------------------------------
test('purge extends the ONE existing deletion authority and keeps its body', () => {
  assert.match(sql, /create or replace function public\.purge_user_data\(p_user_id uuid\)/i);
  assert.match(sql, /security invoker/i);           // 0065's mode preserved
  assert.match(sql, /grant execute on function public\.purge_user_data\(uuid\) to service_role/i);
  // A representative slice of the original body must survive untouched.
  for (const line of ['user_transactions', 'capture_rate_limits', 'profiles', 'backups']) {
    assert.match(sql, new RegExp(`delete from public\\.${line}`, 'i'), line);
  }
  // No second deletion system.
  assert.doesNotMatch(sql, /purge_referral_domain/i);
});

test('referee deletion de-identifies a qualified referral instead of deleting it', () => {
  assert.match(sql, /delete from public\.referrals\s+where referred_user_id = p_user_id and status in \('attributed', 'rejected'\)/i);
  assert.match(sql, /update public\.referrals\s+set referred_user_id = null, referred_user_deleted_at = now\(\)/i);
});

test('audit rows survive user purge de-identified', () => {
  assert.match(sql, /update public\.referral_admin_audit\s+set target_user_id = null, target_ref = null/i);
});

// ---------------------------------------------------------------------------
// Isolation guards (R1 scope discipline)
// ---------------------------------------------------------------------------
test('R1 stores no install-id / device fingerprint', () => {
  for (const forbidden of ['install_id', 'installid', 'device_id', 'device_hash',
                           'idfa', 'advertising_id', 'gaid']) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
  // 'fingerprint' appears ONLY as operation_fingerprint — the Admin idempotency
  // key — and never as a device/install correlation value.
  for (const m of referralOwned.match(/\w*fingerprint\w*/gi) ?? []) {
    assert.ok(['operation_fingerprint', 'v_fingerprint',
               'referral_admin_fingerprint', 'p_fingerprint',
               'v_fp'].includes(m.toLowerCase()),
      `unexpected fingerprint identifier: ${m}`);
  }
});

test('the referral domain touches no financial table or money concept', () => {
  for (const forbidden of [
    'user_transactions', 'user_accounts', 'user_budgets', 'user_goals',
    'amount_minor', 'balance', 'currency', 'money',
  ]) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
});

test('0083 alters no Coupon, Planning, CAS or capture object', () => {
  for (const forbidden of ['coupon', 'server_revision', 'planning', 'capture_devices', 'ledger_sync']) {
    assert.doesNotMatch(referralOwned, new RegExp(forbidden, 'i'), forbidden);
  }
  // No PRE-EXISTING table is altered. (0083's own ALTER TABLE … ENABLE RLS
  // statements target only tables this migration just created.)
  const preExisting = [
    'user_transactions', 'user_accounts', 'user_settings', 'user_budgets',
    'user_goals', 'user_plans', 'user_cards', 'profiles', 'coupons',
    'coupon_categories', 'coupon_tags', 'capture_devices', 'backups',
  ];
  for (const t of preExisting) {
    assert.doesNotMatch(sql, new RegExp(`ALTER TABLE (public\\.)?${t}\\b`, 'i'), t);
  }
});

test('feature-flag seeds exist and are fail-closed', () => {
  assert.match(sql, /INSERT INTO public\.feature_flags[\s\S]*?'enable_referrals',\s+'boolean', 'false'[\s\S]*?0, true/i);
  assert.match(sql, /'enable_report_ads', 'boolean', 'false'[\s\S]*?0, true/i);
  assert.match(sql, /ON CONFLICT \(key\) DO NOTHING/i);
});

test('the client Drift schema is untouched by this SERVER migration', () => {
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
  assert.match(read('app/lib/data/db/app_database.dart'), /const int _targetSchemaVersion = 44;/);
  assert.doesNotMatch(sql, /_targetSchemaVersion|drift/i);
});

test('R1 changes no report generation code', () => {
  const controller = read('app/lib/features/reporting/services/report_generation_controller.dart');
  for (const forbidden of ['entitlement', 'AdGate', 'interstitial', 'referral']) {
    assert.doesNotMatch(controller, new RegExp(forbidden, 'i'), forbidden);
  }
  // Renamed sheet -> page when the report configuration step became a
  // full-screen route; the invariant is unchanged — the report configuration
  // UI must carry no entitlement/ad logic.
  const configUi = read('app/lib/features/reporting/ui/report_config_page.dart');
  assert.doesNotMatch(configUi, /entitlement|interstitial|adGate/i);
});

test('google_mobile_ads is pinned to exactly 9.0.0 (R4 report-export ads)', () => {
  // R4 (approved) integrated the report-export interstitial and added
  // google_mobile_ads. R5 pinned the version EXACTLY: 9.1.0 pulls GoogleMobileAds
  // iOS SDK 13.8.0, whose non-modular GoogleMobileAds_Beta.h breaks the iOS
  // build; 9.0.0 (SDK 13.3.0) builds clean. The pin (no caret) is the contract.
  assert.match(
    read('app/pubspec.yaml'),
    /^\s*google_mobile_ads:\s*9\.0\.0\s*$/m,
    'google_mobile_ads must be pinned to exactly 9.0.0 (no caret)',
  );
});

// ===========================================================================
// R1.1 §23 — Admin mutation authority regressions
// ===========================================================================

/** The body of one function, comments already stripped by `sql`. */
function fnBody(name) {
  const i = sql.indexOf(`FUNCTION public.${name}(`);
  assert.ok(i > 0, `${name} must exist`);
  const rest = sql.slice(i);
  return rest.slice(0, rest.indexOf('$$;'));
}

// ── A/B: rotation history is retained and unambiguous ──────────────────────
test('R1.1 §23A/B: a rotated code is retained, and exactly one code is active', () => {
  const t = sql.slice(sql.indexOf('CREATE TABLE IF NOT EXISTS public.referral_codes'));
  const table = t.slice(0, t.indexOf('\n);'));

  // The ROW is the identity now — a user_id PK could not hold history at all.
  assert.match(table, /id\s+UUID PRIMARY KEY DEFAULT gen_random_uuid\(\)/i);
  assert.match(table, /user_id\s+UUID NOT NULL REFERENCES auth\.users\(id\) ON DELETE CASCADE/i);
  assert.doesNotMatch(table, /user_id\s+UUID PRIMARY KEY/i);

  // …and "active" is still single-valued, via a PARTIAL unique index.
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS referral_codes_one_active_per_user\s+ON public\.referral_codes \(user_id\)\s+WHERE status = 'active'/i);

  // rotated_at pairs with status in BOTH directions.
  assert.match(table, /CONSTRAINT referral_codes_rotated_at_shape CHECK \(\s*\(status = 'active'\s+AND rotated_at IS NULL\)\s*OR\s*\(status = 'rotated' AND rotated_at IS NOT NULL\)\)/i);
});

test('R1.1 §23A: a retired code keeps its UNIQUE reservation forever', () => {
  const t = sql.slice(sql.indexOf('CREATE TABLE IF NOT EXISTS public.referral_codes'));
  const table = t.slice(0, t.indexOf('\n);'));
  // Global, status-independent: the reservation covers rotated rows too, which
  // is what stops a retired code being re-issued to a different person.
  assert.match(table, /code\s+TEXT NOT NULL UNIQUE/i);
  assert.doesNotMatch(sql, /UNIQUE INDEX[^;]*\(code\)[^;]*WHERE/i);
});

// ── C/D: only an ACTIVE code attributes ────────────────────────────────────
test('R1.1 §23C/D: apply_referral_code accepts active codes only', () => {
  const body = fnBody('apply_referral_code');
  assert.match(body, /FROM public\.referral_codes\s+WHERE code = v_code AND status = 'active'/i);
  // A rotated code must be indistinguishable from a nonexistent one.
  assert.match(body, /IF v_owner IS NULL THEN\s*RETURN jsonb_build_object\('ok', false, 'reason', 'invalid_code'\)/i);

  // The user-facing code lookup is likewise active-scoped.
  const ensure = fnBody('ensure_referral_code');
  assert.match(ensure, /WHERE user_id = p_user_id AND status = 'active'/i);
  assert.match(ensure, /ON CONFLICT \(user_id\) WHERE status = 'active' DO NOTHING/i);
});

// ── E/F: rotation replay + mismatch ────────────────────────────────────────
test('R1.1 §23E: a rotation replay does not rotate a second time', () => {
  const body = fnBody('admin_rotate_referral_code');
  const claim = body.indexOf('public.referral_admin_claim(');
  const dup = body.indexOf("'duplicate', true");
  const retire = body.indexOf("SET status = 'rotated'");
  const mint = body.indexOf('INSERT INTO public.referral_codes');
  assert.ok(claim < dup && dup < retire && dup < mint,
    'the replay return must precede both the retirement and the new code');
  // A replay reports live state and never re-mints.
  assert.match(body, /'current_active_code', v_current/);
});

test('R1.1 §23F: rotation binds the target, so a reused id with a new target mismatches', () => {
  const body = fnBody('admin_rotate_referral_code');
  const fp = body.slice(body.indexOf('v_fp :='), body.indexOf('SELECT * INTO v_old'));
  assert.match(fp, /'action',\s*'rotate_code'/);
  assert.match(fp, /'target_user', lower\(p_user_id::text\)/);
  assert.match(fp, /'actor',\s*lower\(p_actor_admin_id::text\)/);
  assert.match(fp, /'reason',\s*v_reason/);
  // No derived state in the digest, or a genuine retry would never match.
  for (const derived of ['now()', 'v_old.id', 'v_code', 'v_new_id']) {
    assert.equal(fp.includes(derived), false, `fingerprint must exclude ${derived}`);
  }
});

test('R1.1 §23: the operator can never choose the replacement code', () => {
  const body = fnBody('admin_rotate_referral_code');
  const sig = sql.slice(sql.indexOf('FUNCTION public.admin_rotate_referral_code('));
  assert.doesNotMatch(sig.slice(0, sig.indexOf(')')), /p_code|p_new_code/i);
  assert.match(body, /v_code := public\.generate_referral_code\(\)/);
});

// ── G/H: entitlement replay + mismatch ─────────────────────────────────────
test('R1.1 §23G/H: an Admin entitlement replay applies exactly one mutation', () => {
  const body = fnBody('admin_mutate_entitlement');
  const claim = body.indexOf('public.referral_admin_claim(');
  const dup = body.indexOf("'duplicate', true");
  const apply = body.indexOf('public.apply_entitlement_mutation(');
  assert.ok(claim < dup && dup < apply,
    'the replay return must precede the entitlement mutation');

  const fp = body.slice(body.indexOf('v_fp :='), body.indexOf('SELECT * INTO v_prev'));
  for (const field of ['action', 'actor', 'duration_days', 'entitlement_type',
                       'reason', 'target_user']) {
    assert.ok(fp.includes(`'${field}'`), `fingerprint must bind ${field}`);
  }
  // Only the four enumerated actions exist — no generic state write.
  assert.match(body, /p_action NOT IN \('grant', 'extend', 'shorten', 'revoke'\)/);
  assert.doesNotMatch(body, /UPDATE public\.user_entitlement_state/);
});

// ── I/J/K/L: reject and reverse ────────────────────────────────────────────
test('R1.1 §23I: rejection is a guarded transition and never a delete', () => {
  const body = fnBody('admin_reject_referral');
  assert.match(body, /UPDATE public\.referrals\s+SET status = 'rejected', rejection_reason = v_reason\s+WHERE id = p_referral_id AND status = 'attributed'/i);
  assert.match(body, /v_rowcount = 0 THEN\s*RAISE EXCEPTION 'referral_not_rejectable'/);
  assert.doesNotMatch(body, /DELETE FROM public\.referrals/i);
  const claim = body.indexOf('public.referral_admin_claim(');
  assert.ok(claim < body.indexOf('UPDATE public.referrals'));
});

test('R1.1 §23J/K/L: reversal records the finding and nothing else', () => {
  const body = fnBody('admin_reverse_referral');
  assert.match(body, /WHERE id = p_referral_id AND status = 'qualified'/i);
  assert.match(body, /v_rowcount = 0 THEN\s*RAISE EXCEPTION 'referral_not_reversible'/);
  // qualified_at survives — the CHECK requires it for 'reversed'.
  assert.doesNotMatch(body, /qualified_at\s*=/);

  // K + L: no implicit entitlement change, no implicit progress adjustment,
  // and no rewriting of immutable reward history.
  for (const forbidden of ['user_entitlement_state', 'entitlement_events',
                           'referral_reward_progress', 'referral_reward_grants',
                           'apply_entitlement_mutation']) {
    assert.equal(body.includes(forbidden), false,
      `reversal must not touch ${forbidden} — that is a separate operator intent`);
  }
});

// ── M: progress adjustment invariants ──────────────────────────────────────
test('R1.1 §23M: progress adjustment cannot cross a milestone or a closed cycle', () => {
  const body = fnBody('admin_adjust_referral_progress');
  assert.match(body, /v_prog\.cycle_state <> 'open' THEN\s*RAISE EXCEPTION 'cycle_not_adjustable'/);
  assert.match(body, /p_qualified_in_cycle < 0 OR p_qualified_in_cycle >= v_rule\.required_referrals[\s\S]{0,120}adjustment_crosses_milestone/);
  // Only the counter moves: the cycle and its pinned rule are history.
  const upd = body.slice(body.indexOf('UPDATE public.referral_reward_progress'));
  const stmt = upd.slice(0, upd.indexOf(';'));
  assert.match(stmt, /SET qualified_in_cycle = p_qualified_in_cycle/);
  for (const frozen of ['cycle_index', 'pinned_rule_id', 'pinned_rule_version', 'cycle_state']) {
    assert.equal(stmt.includes(frozen), false, `adjustment must not rewrite ${frozen}`);
  }
});

// ── N/O/P: rule publication ────────────────────────────────────────────────
test('R1.1 §23N: rule publication is one atomic, serialized operation', () => {
  const body = fnBody('admin_publish_reward_rule');
  // Serialized per reward_type so version numbering cannot race even when no
  // rule rows exist yet to lock.
  assert.match(body, /pg_advisory_xact_lock\(hashtext\('referral_rule_publish:' \|\| p_reward_type\)\)/);
  assert.match(body, /SELECT coalesce\(max\(version\), 0\) \+ 1 INTO v_version/);
  // Deactivate-old and insert-new live in the SAME function body: the partial
  // unique index makes two separate PostgREST calls unsafe.
  const off = body.indexOf('SET is_active = false');
  const ins = body.indexOf('INSERT INTO public.referral_reward_rules');
  assert.ok(off > 0 && ins > off, 'the old rule is deactivated before the new one is inserted');

  // A used rule is never rewritten — only its is_active flag flips.
  const stmt = body.slice(off - 60, body.indexOf(';', off));
  for (const frozen of ['required_referrals', 'reward_days', 'repeatable', 'version =']) {
    assert.equal(stmt.includes(frozen), false, `publication must not rewrite ${frozen}`);
  }
});

test('R1.1 §23O/P: rule publication replays and rejects a reused id', () => {
  for (const fn of ['admin_publish_reward_rule', 'admin_deactivate_reward_rule']) {
    const body = fnBody(fn);
    const claim = body.indexOf('public.referral_admin_claim(');
    const dup = body.indexOf("'duplicate', true");
    const write = body.search(/(?:UPDATE|INSERT INTO) public\.referral_reward_rules/);
    assert.ok(claim < dup && dup < write, `${fn} must return the stored result before writing`);
  }
  // Deactivation stops NEW attribution only; pinned cycles are untouched.
  const de = fnBody('admin_deactivate_reward_rule');
  assert.doesNotMatch(de, /referral_reward_progress/);
  assert.match(de, /v_prev\.id IS NULL THEN\s*RAISE EXCEPTION 'no_active_rule'/);
});

test('R1.1 §13: ambiguous rule configuration stays impossible and fail-closed', () => {
  assert.match(sql, /CREATE UNIQUE INDEX IF NOT EXISTS referral_rules_one_active_per_type/i);
  assert.match(fnBody('active_referral_rule'), /v_count > 1 THEN\s*RAISE EXCEPTION 'ambiguous_rule_configuration'/);
});

// ── Q/R: audit coverage and the system/Admin split ─────────────────────────
test('R1.1 §23Q: every Admin action writes exactly one audit row, via the gate', () => {
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    const body = fnBody(fn);
    assert.equal((body.match(/public\.referral_admin_claim\(/g) || []).length, 1, fn);
    assert.equal((body.match(/INSERT INTO public\.referral_admin_audit/g) || []).length, 0,
      `${fn} must not write its own audit row`);
    assert.equal((body.match(/UPDATE public\.referral_admin_audit/g) || []).length, 1,
      `${fn} must complete exactly one audit row`);
  }
  // The gate is the sole inserter, and the claim is the serialization point.
  const gate = fnBody('referral_admin_claim');
  assert.equal((gate.match(/INSERT INTO public\.referral_admin_audit/g) || []).length, 1);
  assert.match(gate, /ON CONFLICT \(operation_id\) DO NOTHING/);
  assert.equal((gate.match(/idempotency_mismatch/g) || []).length, 2,
    'mismatch is checked on both the pre-claim and lost-race paths');

  // The audit action vocabulary is exactly the approved set.
  const action = sql.match(/CONSTRAINT referral_audit_action_shape CHECK \(action IN \(([\s\S]*?)\)\)/);
  const allowed = action[1].split(',').map((a) => a.trim().replace(/'/g, '')).filter(Boolean);
  assert.deepEqual(allowed.sort(), [
    'adjust_progress', 'extend', 'grant', 'reject_referral', 'reverse_referral',
    'revoke', 'rotate_code', 'rule_change', 'shorten'].sort());
});

test('R1.1 §23R/§16: a system referral reward writes NO Admin audit row', () => {
  const q = fnBody('qualify_referral_internal');
  assert.doesNotMatch(q, /referral_admin_audit/);
  assert.doesNotMatch(q, /p_actor_admin_id/);
  // …but the entitlement event is still mandatory for the system path.
  assert.match(q, /public\.apply_entitlement_mutation\(/);
  assert.match(q, /p_source\s*=>\s*'referral_reward'/);
  // Admin traffic is the mirror image: actor present, source admin_grant.
  assert.match(fnBody('admin_mutate_entitlement'), /p_source\s*=>\s*'admin_grant'/);
  assert.match(fnBody('admin_mutate_entitlement'), /p_actor_admin_id\s*=>\s*p_actor_admin_id/);
});

// ── Cross-cutting: claim-before-mutate, the invariant replay safety rests on ─
test('R1.1 §15: every Admin wrapper claims BEFORE it mutates anything', () => {
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    const body = fnBody(fn);
    const dup = body.indexOf("'duplicate', true");
    assert.ok(dup > body.indexOf('public.referral_admin_claim('), fn);

    const marks = [...body.matchAll(/(?:UPDATE|INSERT INTO) public\.(\w+)/g)]
      .filter((m) => m[1] !== 'referral_admin_audit')
      .map((m) => m.index);
    const call = body.indexOf('public.apply_entitlement_mutation(');
    if (call > 0) marks.push(call);
    assert.ok(marks.length > 0, `${fn} should mutate something`);
    for (const at of marks) {
      assert.ok(at > dup, `${fn} mutates before returning the stored replay result`);
    }
  }
});

test('R1.1 §3/§4: the Admin fingerprint is canonical SHA-256 over intent', () => {
  const fp = fnBody('referral_admin_fingerprint');
  assert.match(fp, /digest\(convert_to\(p_intent::text, 'UTF8'\), 'sha256'\)/);
  assert.doesNotMatch(sql, /md5\(/i);
  // Reason normalization is defined once and reused, so cosmetic whitespace
  // cannot make a retry look like a new intent.
  assert.match(fnBody('referral_admin_require_reason'), /public\.referral_norm_reason\(p_reason\)/);
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    assert.match(fnBody(fn), /v_reason := public\.referral_admin_require_reason\(p_reason\)/, fn);
    assert.match(fnBody(fn), /'reason',\s*v_reason/, `${fn} binds the normalized reason`);
  }
});

test('R1.1 §18: the amendment did not weaken the zero-policy client model', () => {
  assert.equal((sql.match(/CREATE POLICY/g) || []).length, 0);
  assert.equal((sql.match(/GRANT [A-Z]+ ON TABLE/g) || []).length, 0);
  assert.match(sql, /REVOKE ALL ON TABLE/);
});

// ── §19: account deletion after the referral_codes redesign ────────────────
test('R1.1 §19: purge still removes every code row and leaves nothing dangling', () => {
  const purge = raw.slice(raw.indexOf('create or replace function public.purge_user_data'));
  // user_id survived the redesign as a plain column, so the existing purge
  // clause still reaches BOTH the active row and the rotation history.
  assert.match(purge, /delete from public\.referral_codes\s+where user_id = p_user_id;/i);
  // The referrer's referral rows go with them, so no retained row can point at
  // a code string whose reservation has just been released.
  assert.match(purge, /delete from public\.referrals\s+where referrer_user_id = p_user_id;/i);
  // Audit rows survive de-identified; they never stored a code string, only the
  // retired ROW id, which this clears.
  assert.match(purge, /update public\.referral_admin_audit\s+set target_user_id = null, target_ref = null/i);
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    const body = fnBody(fn);
    assert.doesNotMatch(body, /'code',\s*v_code/, `${fn} must not persist a code string`);
  }
});

test('R1.1 §24: the Admin authority raises controlled tokens, never raw SQL', () => {
  const admin = sql.slice(sql.indexOf('FUNCTION public.referral_norm_reason'));
  const raises = [...admin.matchAll(/RAISE EXCEPTION '([^']+)'([^;]*);/g)];
  assert.ok(raises.length >= 12);
  for (const [, token, tail] of raises) {
    // A stable snake_case token the Admin route can map to a message…
    assert.match(token, /^[a-z][a-z0-9_]*$/, `${token} must be a mappable token`);
    // …carrying a deliberate SQLSTATE, never an unclassified server error.
    assert.match(tail, /USING ERRCODE = 'data_exception'/, token);
  }
  // Admin-surface tokens are consumed by the Next.js route, which has no
  // PrivacyRedactor; the >=24-char redaction trap applies only to tokens the
  // FLUTTER client can observe, and no Admin RPC is client-reachable.
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    assert.deepEqual(granted(fn), new Set(['service_role']), fn);
  }
});

// ===========================================================================
// R2 §0 — client-reachable error tokens must survive Flutter's PrivacyRedactor
// ===========================================================================

test('referral_user_error_tokens_are_redactor_safe', () => {
  // app/lib/core/observability/privacy_redactor.dart rewrites any run of
  // [A-Za-z0-9_-]{24,} to '[id]'. A machine token at or over that length is
  // therefore erased from mobile diagnostics precisely when it matters, which
  // is the same defect class as C4.1's 'invalid_redemption_shape'.
  const REDACTOR = /^[A-Za-z0-9_-]{24,}$/;

  // Everything the mobile client can provoke: the four granted RPCs plus the
  // shared qualification path, whose jsonb reasons are returned through them.
  const clientReachable = [
    'apply_referral_code', 'request_referral_qualification',
    'get_referral_summary', 'get_entitlement_decision',
    'qualify_referral_internal',
  ];

  const seen = new Set();
  for (const fn of clientReachable) {
    const body = fnBody(fn);
    const tokens = [
      ...[...body.matchAll(/RAISE EXCEPTION '([a-z0-9_]+)'/g)].map((m) => m[1]),
      ...[...body.matchAll(/'reason',\s*'([a-z0-9_]+)'/g)].map((m) => m[1]),
    ];
    for (const t of tokens) {
      seen.add(t);
      assert.doesNotMatch(t, REDACTOR,
        `${fn} raises '${t}' (${t.length} chars) — the redactor would erase it`);
    }
  }

  // Guard the guard: if the extraction ever stops finding tokens the assertion
  // above becomes vacuous, so pin the ones we know are reachable.
  assert.ok(seen.size >= 8, `expected several tokens, found ${[...seen]}`);
  for (const t of ['bad_entitlement_type', 'unauthenticated', 'invalid_code',
                   'awaiting_active_rule', 'identity_unverified']) {
    assert.ok(seen.has(t), `expected '${t}' among client-reachable tokens`);
  }
  // The renamed token must not come back.
  assert.doesNotMatch(sql, /invalid_entitlement_type/);
});

test('R2 §0: Admin-only tokens are exempt and were left alone', () => {
  // Admin RPCs are service_role only and are consumed by the Next.js route,
  // which has no PrivacyRedactor — so length is irrelevant there and the long
  // descriptive names were deliberately NOT shortened.
  const adminOnly = ['missing_operation_arguments', 'adjustment_crosses_milestone',
                     'referral_code_generation_failed'];
  for (const t of adminOnly) {
    assert.ok(sql.includes(`'${t}'`), `${t} should still exist verbatim`);
    assert.ok(t.length >= 24, `${t} is the exempt long-token case`);
  }
  for (const fn of SERVICE_ROLE_ADMIN_RPC) {
    assert.deepEqual(granted(fn), new Set(['service_role']), fn);
  }
});
