// Gemini-first phase 3 (owner decision 2026-11-20): smart analysis without
// Cloud. Static contract of migration 20261120120000 and its rollback: the four
// capture functions change exactly one consent condition each, keep every
// account-deletion fence and owner/consent-version check, stay service-only,
// and process-ios-sms keeps Cloud data out of an AI-only capture.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

const root = new URL('../../', import.meta.url);
const read = (p) => readFileSync(new URL(p, root), 'utf8');
const name = '20261120120000_smart_analysis_without_cloud';
const migration = read(`supabase/migrations/${name}.sql`);
const rollback = read(`supabase/rollback/${name}_rollback.sql`);

function fn(sql, signature) {
  const start = sql.toLowerCase().indexOf(`function public.${signature}(`);
  assert.ok(start > 0, `${signature} is defined`);
  const ends = [sql.indexOf('$$;', start), sql.indexOf('$function$;', start)].filter((i) => i > 0);
  const end = Math.min(...ends);
  return sql.slice(start, end);
}

test('capture_claim: Cloud OR smart-analysis consent admits; neither refuses', () => {
  const claim = fn(migration, 'capture_claim');
  assert.match(claim, /if d\.cloud_processing_enabled is not true and d\.ai_consent_granted is not true then\s+return jsonb_build_object\('outcome', 'denied', 'code', 'consent_required'\)/);
  assert.doesNotMatch(claim, /if d\.cloud_processing_enabled is not true then/);
  // Additive reply field, both claimed branches.
  assert.equal((claim.match(/'cloud_allowed', d\.cloud_processing_enabled is true/g) ?? []).length, 2);
  // Everything else that guards a claim is kept.
  for (const kept of [
    'perform account_fence.admit_install(p_install_id_hash);',
    'perform account_fence.admit(p_owner_uid);',
    "'credential_revoked'",
    "'capture_owner_mismatch'",
    'ownerless_not_eligible',
    "'ai_allowed', d.ai_consent_granted",
    'consent_version',
  ]) assert.ok(claim.includes(kept), kept);
});

test('capture_ai_dispatch: the model runs only with the AI consent', () => {
  const dispatch = fn(migration, 'capture_ai_dispatch');
  assert.match(dispatch, /elsif d\.revoked_at is not null\s+or d\.ai_consent_granted is not true\s+or d\.consent_version is distinct from r\.consent_version then\s+v_reason := 'consent_revoked'/);
  assert.doesNotMatch(dispatch, /cloud_processing_enabled/);
  assert.ok(dispatch.includes('perform account_fence.admit_install(p_install_id_hash);'));
  assert.ok(dispatch.includes("r.ai_attempts >= 3"), 'three AI attempts per capture');
});

test('capture_finalize and capture_retry_fence: Cloud OR AI keeps the result', () => {
  const finalize = fn(migration, 'capture_finalize');
  assert.match(finalize, /or \(d\.cloud_processing_enabled is not true and d\.ai_consent_granted is not true\)/);
  assert.ok(finalize.includes('perform account_fence.admit_install(p_install_id_hash);'));
  const fence = fn(migration, 'capture_retry_fence');
  assert.match(fence, /if d\.cloud_processing_enabled is not true and d\.ai_consent_granted is not true then\s+return jsonb_build_object\('allowed', false, 'reason', 'consent_revoked'\)/);
});

test('service-only, transactional, and the rollback restores the Cloud rule', () => {
  for (const sig of [
    'capture_claim(text, text, text, text, uuid, integer, integer, bigint)',
    'capture_ai_dispatch(text, text, integer)',
    'capture_finalize(text, text, text, integer, text, text, jsonb, jsonb, text, text, boolean, jsonb)',
    'capture_retry_fence(text, text)',
  ]) {
    for (const sql of [migration, rollback]) {
      assert.ok(sql.includes(`revoke all on function public.${sig} from public, anon, authenticated;`), sig);
      assert.ok(sql.includes(`grant execute on function public.${sig} to service_role;`), sig);
    }
  }
  assert.match(migration, /^begin;$/m);
  assert.match(migration, /^commit;$/m);
  assert.match(fn(rollback, 'capture_claim'), /if d\.cloud_processing_enabled is not true then/);
  assert.match(fn(rollback, 'capture_ai_dispatch'), /d\.cloud_processing_enabled is not true\s+or d\.ai_consent_granted is not true/);
  assert.doesNotMatch(rollback, /cloud_allowed/);
});

test('process-ios-sms: an AI-only capture never reads or acts on Cloud data; caps unchanged', () => {
  const handler = read('supabase/functions/process-ios-sms/index.ts');
  assert.match(handler, /const cloudAllowed = claim\.cloud_allowed !== false;/);
  assert.match(handler, /if \(status === 'processed' && ownerUid && cloudAllowed\) \{/);
  assert.match(handler, /status !== 'rejected' && ownerUid && cloudAllowed\s+\? await withUserMerchantRule/);
  // The per-install quota and the global AI ceiling still guard every request.
  assert.match(handler, /const limited = await bumpRateLimit\(supabase, auth\.installIdHash\);/);
  assert.match(handler, /reserveAiBudget\(supabase, 'gemini'\)/);
  assert.match(handler, /const aiAllowed = allowAi && claim\.ai_allowed === true;/);
});
