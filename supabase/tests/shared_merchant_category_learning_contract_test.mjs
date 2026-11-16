// Static contract for 20261116150000_shared_merchant_category_learning and the
// merchant-category-contribution function. Credential-free; the live proof is
// shared_merchant_category_learning_20261116.sql.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const stripComments = (sql) =>
  sql.split('\n').filter((l) => !l.trimStart().startsWith('--')).join('\n');
const name = '20261116150000_shared_merchant_category_learning';
const sql = stripComments(read(`supabase/migrations/${name}.sql`));
const fn = read('supabase/functions/merchant-category-contribution/index.ts');

test('contributions store a salted hash per user, never a user id or timestamp', () => {
  const table = sql.slice(sql.indexOf('CREATE TABLE IF NOT EXISTS public.merchant_category_contributions'));
  const cols = table.slice(0, table.indexOf(');'));
  assert.match(cols, /contributor_hash/);
  assert.doesNotMatch(cols, /user_id|install|device|_at\b|amount|TIMESTAMPTZ/i);
  assert.match(cols, /PRIMARY KEY \(merchant_key, contributor_hash\)/);
  assert.match(sql, /extensions\.hmac\(/);
});

test('no API role can read the salt or the raw contributions', () => {
  for (const t of ['merchant_contribution_secret', 'merchant_category_contributions', 'merchant_category_reviews']) {
    assert.match(sql, new RegExp(`REVOKE ALL ON TABLE public\\.${t}\\s+FROM PUBLIC, anon, authenticated, service_role`), t);
    assert.doesNotMatch(sql, new RegExp(`GRANT [A-Z, ]+ ON TABLE public\\.${t}`, 'i'), t);
  }
});

test('admin RPCs check admin_users membership and are service-role only', () => {
  for (const f of ['admin_list_merchant_category_candidates', 'admin_review_merchant_category_candidate']) {
    const body = sql.slice(sql.indexOf(`FUNCTION public.${f}(`));
    assert.match(body.slice(0, body.indexOf('$$;')), /FROM public\.admin_users a WHERE a\.id = p_actor/, f);
    assert.match(sql, new RegExp(`REVOKE ALL ON FUNCTION public\\.${f}\\([^)]*\\)\\s+FROM PUBLIC, anon, authenticated`), f);
  }
});

test('the candidate threshold starts at 5 and gates both listing and approval', () => {
  assert.match(sql, /merchant_category_candidate_min_users\(\)\s+RETURNS INTEGER LANGUAGE sql IMMUTABLE AS \$\$ SELECT 5 \$\$/);
  assert.equal(sql.match(/>= public\.merchant_category_candidate_min_users\(\)/g)?.length, 1);
  assert.match(sql, /v_count < public\.merchant_category_candidate_min_users\(\)/);
});

test('only an approval writes to the shared catalog', () => {
  const writes = sql.match(/(INSERT INTO|UPDATE) public\.merchant_keywords/g) ?? [];
  assert.equal(writes.length, 2);
  const review = sql.slice(sql.indexOf('FUNCTION public.admin_review_merchant_category_candidate('));
  const approvedBranch = review.slice(review.indexOf("IF p_decision = 'approved' THEN"), review.indexOf('INSERT INTO public.merchant_category_reviews'));
  assert.match(approvedBranch, /INSERT INTO public\.merchant_keywords/);
  assert.match(approvedBranch, /UPDATE public\.merchant_keywords/);
});

test('the function accepts exactly merchant_key + category_key, user JWT, Cloud AND AI', () => {
  assert.match(fn, /const ALLOWED_KEYS = \['category_key', 'merchant_key'\];/);
  assert.match(fn, /resolveIdentity\(req, supabase, \{\}, cid\)/);
  assert.match(fn, /consentError\(identity\.identity, 'ai', cid\)/);
  assert.match(fn, /kind !== 'user'/);
});

test('the retired merchant-feedback route stays retired', () => {
  assert.match(read('supabase/functions/merchant-feedback/index.ts'), /'retired'/);
});

test('the migration ships a rollback', () => {
  const rb = read(`supabase/rollback/${name}_rollback.sql`);
  assert.match(rb, /DROP TABLE IF EXISTS public\.merchant_category_contributions/);
  assert.match(rb, /DROP TRIGGER IF EXISTS on_auth_user_deleted_erase_merchant_contributions ON auth\.users/);
});

// ── 20261116170000: auto-approval ───────────────────────────────────────────
const autoName = '20261116170000_shared_learning_auto_approve';
const autoSql = stripComments(read(`supabase/migrations/${autoName}.sql`));
const evaluate = autoSql.slice(autoSql.indexOf('FUNCTION public.evaluate_merchant_category_auto_approval('));
const evaluateBody = evaluate.slice(0, evaluate.indexOf('$$;', evaluate.indexOf('$$') + 2));

test('auto-approval: 6 users AND >= 75% of the merchant, as named constants', () => {
  assert.match(autoSql, /merchant_category_auto_min_users\(\)\s+RETURNS INTEGER LANGUAGE sql IMMUTABLE AS \$\$ SELECT 6 \$\$/);
  assert.match(autoSql, /merchant_category_auto_min_percent\(\)\s+RETURNS INTEGER LANGUAGE sql IMMUTABLE AS \$\$ SELECT 75 \$\$/);
  assert.match(evaluateBody, /v_count < public\.merchant_category_auto_min_users\(\)/);
  assert.match(evaluateBody, /v_count \* 100 < v_total \* public\.merchant_category_auto_min_percent\(\)/);
});

test('auto-approval never overrides a review, another approval or a catalog keyword', () => {
  assert.match(evaluateBody, /r\.merchant_key = p_merchant_key AND r\.category_key = v_category\)/);
  assert.match(evaluateBody, /r\.merchant_key = p_merchant_key AND r\.decision = 'approved'\)/);
  assert.match(evaluateBody, /k\.category_key <> v_category\)/);
});

test('auto and manual approval publish through one function; auto is marked', () => {
  assert.equal((autoSql.match(/(INSERT INTO|UPDATE) public\.merchant_keywords\b/g) ?? []).length, 3,
    'publish (insert + update) and revoke (update) only');
  assert.match(evaluateBody, /PERFORM public\.merchant_category_publish\(p_merchant_key, v_category\)/);
  assert.match(evaluateBody, /'approved', v_category, v_count, NULL, TRUE\)/);
  const review = autoSql.slice(autoSql.indexOf('FUNCTION public.admin_review_merchant_category_candidate('));
  assert.match(review.slice(0, review.indexOf('$$;')), /PERFORM public\.merchant_category_publish\(p_merchant_key, v_final\)/);
});

test('evaluation runs from a contribution trigger (no cron)', () => {
  assert.match(autoSql, /AFTER INSERT OR UPDATE ON public\.merchant_category_contributions\s+FOR EACH ROW EXECUTE FUNCTION public\.trg_merchant_category_auto_approval\(\)/);
});

test('revoke is admin-only, soft-deletes the keyword and rejects the pair', () => {
  const revoke = autoSql.slice(autoSql.indexOf('FUNCTION public.admin_revoke_merchant_category_mapping('));
  const body = revoke.slice(0, revoke.indexOf('$$;', revoke.indexOf('$$') + 2));
  assert.match(body, /FROM public\.admin_users a WHERE a\.id = p_actor/);
  assert.match(body, /SET is_active = FALSE, is_deleted = TRUE/);
  assert.match(body, /SET decision = 'rejected'/);
  assert.match(autoSql, /REVOKE ALL ON FUNCTION public\.admin_revoke_merchant_category_mapping\(UUID, TEXT, TEXT\)\s+FROM PUBLIC, anon, authenticated/);
});

test('the auto-approval migration ships a rollback and leaves 20261116150000 alone', () => {
  assert.match(read(`supabase/rollback/${autoName}_rollback.sql`), /DROP TRIGGER IF EXISTS trg_merchant_category_contributions_auto_approve/);
  assert.doesNotMatch(sql, /auto_approv/);
});

// ── 20261116190000: shared-mapping marker ───────────────────────────────────
const markerName = '20261116190000_shared_mapping_marker';
const markerSql = stripComments(read(`supabase/migrations/${markerName}.sql`));
const markerPublish = markerSql.slice(markerSql.indexOf('FUNCTION public.merchant_category_publish('));
const markerPublishBody = markerPublish.slice(0, markerPublish.indexOf('$$;', markerPublish.indexOf('$$') + 2));

test('shared mappings are published with the reserved priority 1000', () => {
  assert.match(markerSql, /merchant_category_shared_priority\(\)\s+RETURNS INTEGER LANGUAGE sql IMMUTABLE AS \$\$ SELECT 1000 \$\$/);
  // both the insert and the update path set the marker
  assert.equal((markerPublishBody.match(/public\.merchant_category_shared_priority\(\)/g) ?? []).length, 2);
  assert.match(markerPublishBody, /priority = public\.merchant_category_shared_priority\(\)/);
  assert.match(markerSql, /REVOKE ALL ON FUNCTION public\.merchant_category_publish\(TEXT, TEXT\)\s+FROM PUBLIC, anon, authenticated, service_role/);
});

test('the marker backfill touches only approved shared-learning mappings', () => {
  const backfill = markerSql.slice(markerSql.indexOf('UPDATE public.merchant_keywords k'));
  assert.match(backfill, /r\.decision = 'approved'/);
  assert.match(backfill, /upper\(k\.keyword\) = r\.merchant_key/);
  assert.match(backfill, /k\.category_key = r\.published_category_key/);
});

test('no other writer uses the reserved priority', () => {
  const enrich = read('supabase/functions/enrich-merchant/index.ts');
  assert.match(enrich, /priority: 0,/);
  assert.doesNotMatch(enrich, /priority: 1000/);
});

test('the device reads the same reserved priority', () => {
  const dart = read('app/lib/domain/services/learned_rule_precedence.dart');
  assert.match(dart, /sharedLearningKeywordPriority = 1000;/);
});

test('the marker migration ships a rollback and leaves 20261116170000 alone', () => {
  assert.match(read(`supabase/rollback/${markerName}_rollback.sql`),
    /DROP FUNCTION IF EXISTS public\.merchant_category_shared_priority\(\)/);
  assert.doesNotMatch(autoSql, /shared_priority/);
});
