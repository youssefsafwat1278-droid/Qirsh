// Admin push broadcasts — route, page and allowlist contracts.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  BROADCAST_DEEP_LINKS,
  parseTestTarget,
  parseTypedConfirmation,
  validateBroadcastDraft,
} from "../lib/push-broadcast.mjs";

const read = (p) => readFileSync(new URL(`../${p}`, import.meta.url), "utf8");

const ROUTES = [
  "app/api/push-broadcasts/route.ts",
  "app/api/push-broadcasts/dry-run/route.ts",
  "app/api/push-broadcasts/send/route.ts",
  "app/api/push-broadcasts/test/route.ts",
];

test("every push-broadcast handler requires an admin and maps auth errors", () => {
  for (const path of ROUTES) {
    const src = read(path);
    const handlers = [...src.matchAll(/export async function (GET|POST|PATCH|DELETE)[\s\S]*?(?=export async function|$)/g)];
    assert.ok(handlers.length > 0, path);
    for (const h of handlers) {
      assert.match(h[0], /try\s*{\s*(user = )?await requireAdmin\(\);\s*}\s*catch \(e\) {\s*return adminAuthErrorResponse\(e\);/,
        `${path} ${h[1]}`);
    }
  }
});

test("writes go only through the admin RPCs with the admin's id", () => {
  const src = read("app/api/push-broadcasts/route.ts");
  assert.match(src, /rpc\("admin_create_push_broadcast"/);
  assert.match(src, /p_actor: user\.id/);
  assert.match(src, /p_operation_id: body\.operation_id/);
  assert.match(src, /p_confirm_devices: confirmed/);
  assert.match(src, /validateBroadcastDraft\(body\)/);
  for (const path of ROUTES) {
    assert.doesNotMatch(read(path), /from\("(push_broadcasts|push_broadcast_deliveries|announcements)"\)/, path);
  }
  assert.match(read("app/api/push-broadcasts/dry-run/route.ts"), /rpc\("admin_push_broadcast_dry_run", \{ p_actor: user\.id \}\)/);
});

test("the sender is invoked with the admin's own session, never the service key", () => {
  const src = read("lib/push-broadcast-server.ts");
  assert.match(src, /functions\/v1\/send-push-broadcast/);
  assert.match(src, /Bearer \$\{session\.access_token\}/);
  assert.doesNotMatch(src, /SERVICE_ROLE/);
});

test("the page gates sending on a dry run and a typed device count", () => {
  const page = read("app/(admin)/push/page.tsx");
  assert.match(page, /fetch\("\/api\/push-broadcasts\/dry-run"/);
  assert.match(page, /typeToConfirm: String\(dryRun\.devices\)/);
  assert.match(page, /disabled=\{!dryRun \|\| busy\}/);
  // Editing the draft drops the preview, so the confirmed count is always current.
  assert.match(page, /setDraft\(\(prev\) => \(\{ \.\.\.prev, \[field\]: value \}\)\);\s*\/\/[^\n]*\n\s*setDryRun\(null\);/);
  assert.match(page, /operation_id: operationId/);
  for (const k of ["pending", "sent", "failed"]) assert.match(page, new RegExp(`b\\.${k}`));
  assert.match(read("lib/nav.ts"), /href:\s*"\/push"/);
});

test("typed confirmation accepts only a plain count", () => {
  assert.equal(parseTypedConfirmation("12"), 12);
  assert.equal(parseTypedConfirmation(" 3 "), 3);
  for (const bad of ["", "12a", "-1", "1.5", null, 12, "٣"]) assert.equal(parseTypedConfirmation(bad), null, String(bad));
});

test("drafts need both languages within the length limits and an allowed link", () => {
  const ok = { title_ar: "ع", title_en: "t", body_ar: "ن", body_en: "b" };
  assert.ok(validateBroadcastDraft(ok).ok);
  assert.deepEqual(validateBroadcastDraft({ ...ok, title_en: " " }).errors, ["title_en_required"]);
  assert.deepEqual(validateBroadcastDraft({ ...ok, body_ar: "x".repeat(601) }).errors, ["body_ar_too_long"]);
  assert.deepEqual(validateBroadcastDraft({ ...ok, deep_link: "https://example.com" }).errors, ["deep_link_not_allowed"]);
  assert.equal(validateBroadcastDraft({ ...ok, deep_link: "/budgets" }).value.deep_link, "/budgets");
  assert.equal(validateBroadcastDraft({ ...ok, deep_link: "" }).value.deep_link, null);
});

test("the deep-link allowlist is identical in the admin, the database and the app", () => {
  const admin = BROADCAST_DEEP_LINKS.map((l) => l.value).sort();
  const sql = read("../supabase/migrations/20261116160000_admin_push_broadcasts.sql");
  const check = sql.match(/deep_link IS NULL OR deep_link IN \(([^)]*)\)/);
  assert.ok(check);
  assert.deepEqual([...check[1].matchAll(/'([^']+)'/g)].map((m) => m[1]).sort(), admin);
  const rpc = sql.match(/v_link NOT IN \(([^)]*)\)/);
  assert.deepEqual([...rpc[1].matchAll(/'([^']+)'/g)].map((m) => m[1]).sort(), admin);
  const dart = read("../app/lib/features/app/capture_notification_actions.dart");
  const set = dart.match(/const kBroadcastRoutes = <String>\{([^}]*)\}/);
  assert.ok(set, "kBroadcastRoutes defined in the app");
  assert.deepEqual([...set[1].matchAll(/'([^']+)'/g)].map((m) => m[1]).sort(), admin);
});

test("a test send targets one account by email or user id only", () => {
  assert.equal(parseTestTarget("  me@example.com "), "me@example.com");
  assert.equal(parseTestTarget("11111111-2222-3333-4444-555555555555"), "11111111-2222-3333-4444-555555555555");
  for (const bad of ["", "%", "everyone", "a b@c", null, 12, "x".repeat(250) + "@a.co"]) {
    assert.equal(parseTestTarget(bad), null, String(bad));
  }
  const route = read("app/api/push-broadcasts/test/route.ts");
  assert.match(route, /admin_create_push_broadcast_test/);
  assert.doesNotMatch(route, /admin_create_push_broadcast"/);
});
