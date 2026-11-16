// Shared category learning — admin review: structure + validation.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";

import {
  mapReviewError,
  validateReviewPayload,
  validateRevokePayload,
} from "../lib/shared-learning-validation.mjs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");
const route = read("app/api/merchant-category-candidates/route.ts");
const page = read("app/(admin)/merchants/shared-learning/page.tsx");

test("every handler requires an admin before any RPC, and passes the verified id", () => {
  const handlers = [...route.matchAll(/export async function (GET|POST|DELETE)[\s\S]*?(?=export async function|$)/g)];
  assert.equal(handlers.length, 3);
  for (const [body, name] of handlers) {
    const guard = body.indexOf("requireAdmin()");
    const rpc = body.indexOf(".rpc(");
    assert.ok(guard > 0 && rpc > guard, `${name}: requireAdmin must precede the RPC`);
    assert.match(body, /p_actor: admin\.id/, `${name}: actor is the verified admin`);
  }
  assert.match(page, /await requireAdmin\(\)/);
  assert.match(page, /p_actor: admin\.id/);
});

test("the admin never reads raw contributions or writes the catalog directly", () => {
  for (const src of [route, page]) {
    assert.doesNotMatch(src, /merchant_category_contributions|merchant_contribution_secret/);
    assert.doesNotMatch(src, /from\("merchant_keywords"\)/);
  }
  assert.match(route, /rpc\("admin_review_merchant_category_candidate"/);
  assert.match(route, /rpc\("admin_list_merchant_category_candidates"/);
});

test("the page states 5 is a review threshold, not a privacy guarantee", () => {
  assert.match(page, /5 مستخدمين مختلفين على الأقل/);
  assert.match(page, /ليس ضمانًا للخصوصية/);
});

test("validation: approve, approve with edit, reject", () => {
  const base = { merchant_key: "HALA BOUTIQUE", category_key: "shopping" };
  assert.deepEqual(validateReviewPayload({ ...base, decision: "approved" }).value, {
    ...base, decision: "approved", published_category_key: null,
  });
  assert.equal(
    validateReviewPayload({ ...base, decision: "approved", published_category_key: "restaurants" })
      .value.published_category_key,
    "restaurants",
  );
  assert.equal(validateReviewPayload({ ...base, decision: "rejected" }).ok, true);
});

test("validation refuses bad decisions, people categories and edits on reject", () => {
  const base = { merchant_key: "HALA BOUTIQUE", category_key: "shopping" };
  for (const body of [
    { ...base, decision: "maybe" },
    { ...base, decision: "approved", published_category_key: "transfers" },
    { ...base, category_key: "income", decision: "approved" },
    { ...base, decision: "rejected", published_category_key: "restaurants" },
    { ...base, merchant_key: "AB", decision: "approved" },
    null,
  ]) {
    assert.equal(validateReviewPayload(body).ok, false, JSON.stringify(body));
  }
  // Unknown keys are dropped, never forwarded.
  const v = validateReviewPayload({ ...base, decision: "approved", p_actor: "spoof" }).value;
  assert.deepEqual(Object.keys(v).sort(), ["category_key", "decision", "merchant_key", "published_category_key"]);
});

test("RPC errors map to HTTP: non-admin is 403, non-candidate 409", () => {
  assert.equal(mapReviewError("P0403").status, 403);
  assert.equal(mapReviewError("P0409").status, 409);
  assert.equal(mapReviewError("P0422").status, 400);
  assert.equal(mapReviewError("XX000").status, 500);
});

const manager = read("app/(admin)/merchants/shared-learning/candidates-manager.tsx");

test("auto-approved mappings are badged and revocable through the admin-checked RPC", () => {
  assert.match(page, /rpc\("admin_list_merchant_category_published", \{ p_actor: admin\.id \}\)/);
  assert.match(page, /<PublishedManager published=\{publishedRows\} \/>/);
  assert.match(manager, /r\.auto_approved \? \(\s*<StatusBadge label="معتمد تلقائيًا"/);
  assert.match(manager, /review\(\{ merchant_key: r\.merchant_key, category_key: r\.category_key \}, "DELETE"\)/);
  const del = route.slice(route.indexOf("export async function DELETE"));
  assert.ok(del.indexOf("requireAdmin()") < del.indexOf(".rpc("), "DELETE: requireAdmin precedes the RPC");
  assert.match(del, /rpc\("admin_revoke_merchant_category_mapping"/);
  assert.match(del, /p_actor: admin\.id/);
});

test("the page states the auto rule: 6+ users and at least 75%", () => {
  assert.match(page, /6 مستخدمين أو أكثر/);
  assert.match(page, /75% على الأقل/);
  assert.match(page, /معتمد تلقائيًا/);
});

test("revoke validation passes only the pair; a non-admin revoke maps to 403", () => {
  assert.deepEqual(
    validateRevokePayload({ merchant_key: "HALA BOUTIQUE", category_key: "shopping", p_actor: "spoof" }).value,
    { merchant_key: "HALA BOUTIQUE", category_key: "shopping" },
  );
  for (const body of [null, { merchant_key: "AB", category_key: "shopping" }, { merchant_key: "HALA", category_key: "transfers" }]) {
    assert.equal(validateRevokePayload(body).ok, false, JSON.stringify(body));
  }
  assert.equal(mapReviewError("P0403").status, 403);
  assert.equal(mapReviewError("P0409").status, 409);
});
