// F-017 — the force-update kill switch must never publish on a single click.
//
// QA evidence (demo QA, DEMO_FINDINGS F-017): `severity=force_update` — the
// one control that can block every installed client — published with no guard
// beyond a non-empty Arabic title, while plain DELETE had a typed
// confirmation (inverted risk gradient). These tests exercise the REAL shared
// guard the API route now enforces, plus structural contracts proving the
// route and the form actually use it.

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import {
  FORCE_UPDATE_ACTION_URL_REQUIRED,
  FORCE_UPDATE_CONFIRMATION_REQUIRED,
  FORCE_UPDATE_CONFIRM_PHRASE,
  armsForceUpdate,
  blocksClients,
  validateAnnouncementPublish,
} from "../lib/announcement-guard.mjs";

const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), "utf8");

// ── behavioural: the guard itself ──────────────────────────────────────────

test("an unconfirmed force-update arm is refused — accidental single click cannot publish", () => {
  const armed = { severity: "force_update", is_active: true };
  assert.equal(armsForceUpdate(armed), true);
  assert.deepEqual(validateAnnouncementPublish(armed), {
    ok: false,
    error: FORCE_UPDATE_CONFIRMATION_REQUIRED,
  });
  // No options object at all — the plain legacy call — is also refused.
  assert.equal(validateAnnouncementPublish(armed, {}).ok, false);
});

test("a confirmed force-update arm is allowed", () => {
  // C-2a added a second precondition: an arm must carry a working action_url,
  // because ForceUpdateScreen otherwise falls back to a placeholder store URL
  // with a fake app id. The confirmed-arm path is asserted WITH one; the
  // without-one case is covered by its own test below.
  const armed = {
    severity: "force_update",
    is_active: true,
    action_url: "https://example.test/app",
  };
  assert.deepEqual(
    validateAnnouncementPublish(armed, { confirmForceUpdate: true }),
    { ok: true },
  );
});

test("ordinary announcements keep single-click semantics", () => {
  for (const payload of [
    { severity: "info", is_active: true },
    { severity: "warning", is_active: true },
    { severity: "maintenance", is_active: true },
  ]) {
    assert.deepEqual(validateAnnouncementPublish(payload), { ok: true });
  }
});

test("DISARMING a force-update needs no confirmation — that direction unblocks users", () => {
  assert.deepEqual(
    validateAnnouncementPublish({ severity: "force_update", is_active: false }),
    { ok: true },
  );
});

test("the confirmation token cannot be smuggled as a truthy non-boolean", () => {
  const armed = { severity: "force_update", is_active: true };
  for (const bad of ["true", 1, {}, []]) {
    assert.equal(
      validateAnnouncementPublish(armed, { confirmForceUpdate: bad }).ok,
      false,
      `confirmForceUpdate=${JSON.stringify(bad)} must not arm`,
    );
  }
});

// ── structural: the route and the form actually enforce/use the guard ──────

test("the announcements API enforces the guard on BOTH create and update", () => {
  const route = read("app/api/announcements/route.ts");
  assert.match(route, /announcement-guard\.mjs/);
  const posts = /export async function POST[\s\S]*?(?=export async function)/.exec(route);
  const patches = /export async function PATCH[\s\S]*?(?=export async function)/.exec(route);
  assert.match(posts[0], /validateAnnouncementPublish/, "POST must run the guard");
  assert.match(patches[0], /validateAnnouncementPublish/, "PATCH must run the guard");
  assert.match(route, /confirm_force_update/);
});

test("the form arms only through the typed consequence dialog and states the version constraint", () => {
  const page = read("app/(admin)/announcements/page.tsx");
  assert.match(page, /typeToConfirm:\s*FORCE_UPDATE_CONFIRM_PHRASE/,
    "arming must require typing the confirmation phrase");
  assert.match(page, /يمنع المستخدمين من متابعة استخدام التطبيق/,
    "the dialog must state the consequence, not «هل أنت متأكد؟»");
  assert.match(page, /min_app_version[\s\S]*max_app_version/,
    "the dialog/form must carry the actual version constraint being published");
  assert.match(page, /بدون قيود إصدار — سيُحجب كل مستخدم/,
    "an unbounded constraint must be called out as blocking everyone");
  assert.match(page, /onClick=\{requestSave\}/,
    "the save button must route through the gate, never straight to save()");
  assert.equal(FORCE_UPDATE_CONFIRM_PHRASE, "تحديث إجباري");
});

// ── C-2 — the guard must judge the EFFECTIVE post-write state ──────────────
//
// Independent review (docs/plans/QIRSH_MASTER_PLAN_V2.md §9.1) found the guard evaluates
// only the incoming payload and never reads the stored row. `armsForceUpdate`
// needs severity AND is_active in the SAME object, and a partial PATCH omits
// one of them — so a force-update can be armed with no token at all:
//
//   PATCH {id, is_active:true}        on a dormant force_update row
//   PATCH {id, severity:'force_update'} on an already-active row
//
// Both arm a control that blocks every installed client.

test("C-2: arming a DORMANT force-update by flipping is_active alone is refused", () => {
  const stored = { severity: "force_update", is_active: false };
  const patch = { is_active: true }; // severity absent — untouched, stays force_update

  assert.equal(
    armsForceUpdate({ ...stored, ...patch }),
    true,
    "the effective post-write row IS an armed force-update",
  );
  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "the guard must refuse it without the typed token",
  );
});

test("C-2: arming by setting severity on an ALREADY-ACTIVE row is refused", () => {
  const stored = { severity: "info", is_active: true };
  const patch = { severity: "force_update" }; // is_active absent — stays true

  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
  );
});

test("C-2: a partial edit that does NOT arm stays frictionless", () => {
  const stored = { severity: "force_update", is_active: false };
  // Editing the copy of a dormant force-update must not demand the token.
  assert.deepEqual(
    validateAnnouncementPublish({ title_ar: "x" }, { stored }),
    { ok: true },
  );
  // Disarming must never require it — that direction unblocks users.
  assert.deepEqual(
    validateAnnouncementPublish(
      { is_active: false },
      { stored: { severity: "force_update", is_active: true } },
    ),
    { ok: true },
  );
});

test("C-2: an already-armed row edited without re-arming stays frictionless", () => {
  const stored = { severity: "force_update", is_active: true };
  assert.deepEqual(
    validateAnnouncementPublish({ title_ar: "new copy" }, { stored }),
    { ok: true },
    "the documented contract: editing an armed force-update is not re-arming",
  );
});

test("C-2: the PATCH route reads the stored row before judging", () => {
  const route = read("app/api/announcements/route.ts");
  const patchBody = route.slice(route.indexOf("export async function PATCH"));
  assert.match(
    patchBody,
    /\.from\("announcements"\)[\s\S]*?\.select\([\s\S]*?\.eq\("id"/,
    "PATCH must load the existing row — a payload-only guard is bypassable",
  );
  assert.match(
    patchBody,
    /validateAnnouncementPublish\([\s\S]*?stored/,
    "and must pass it to the guard",
  );
});

// ── C-2a — "armed" must mean "blocking clients", not just severity+is_active ──
//
// Fable review, 2026-08-28. `catalog-announcements` only serves a row when
// `valid_from <= now` AND (`valid_until` IS NULL OR `valid_until >= now`)
// (supabase/functions/catalog-announcements/index.ts). So a force_update row
// that is severity=force_update AND is_active=true but whose valid_until is in
// the PAST blocks nobody.
//
// The transition guard therefore had a hole: such a row is already
// `armsForceUpdate() === true`, so extending valid_until back into the future
// was treated as "editing an already-armed row" — frictionless — even though it
// takes the row from blocking NOBODY to blocking EVERY client.
//
// Correct rule: confirmation is required whenever a write causes a force-update
// row to block clients it was not already blocking.

const PAST = "2020-01-01T00:00:00.000Z";
const FUTURE = "2099-01-01T00:00:00.000Z";
const NOW = new Date("2026-08-28T00:00:00.000Z");

test("C-2a: resurrecting an EXPIRED armed force-update requires confirmation", () => {
  const stored = {
    severity: "force_update",
    is_active: true,
    valid_from: PAST,
    valid_until: PAST, // expired -> serves nobody
    action_url: "https://example.test/app",
  };
  const patch = { valid_until: FUTURE }; // resurrect: now blocks everyone

  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored, now: NOW }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "expired -> live is an ARMING, not an edit",
  );
});

test("C-2a: clearing valid_until on an expired armed row requires confirmation", () => {
  const stored = {
    severity: "force_update",
    is_active: true,
    valid_until: PAST,
    action_url: "https://example.test/app",
  };
  assert.deepEqual(
    validateAnnouncementPublish({ valid_until: null }, { stored, now: NOW }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "null means 'never expires' — that is arming",
  );
});

test("C-2a: a SCHEDULED arm (valid_from in the future) still requires confirmation", () => {
  const stored = { severity: "info", is_active: true };
  const patch = {
    severity: "force_update",
    valid_from: FUTURE,
    action_url: "https://example.test/app",
  };
  assert.deepEqual(
    validateAnnouncementPublish(patch, { stored, now: NOW }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "a delayed block is still a block",
  );
});

test("C-2a: editing copy on a LIVE armed row stays frictionless", () => {
  const stored = {
    severity: "force_update",
    is_active: true,
    valid_until: FUTURE,
    action_url: "https://example.test/app",
  };
  assert.deepEqual(
    validateAnnouncementPublish({ title_ar: "new copy" }, { stored, now: NOW }),
    { ok: true },
  );
});

test("C-2a: shortening the window on a live armed row stays frictionless", () => {
  const stored = {
    severity: "force_update",
    is_active: true,
    valid_until: FUTURE,
    action_url: "https://example.test/app",
  };
  // Narrowing blast radius must never be harder than widening it.
  assert.deepEqual(
    validateAnnouncementPublish({ valid_until: PAST }, { stored, now: NOW }),
    { ok: true },
  );
});

test("C-2a: widening the audience of a live armed row requires confirmation", () => {
  const stored = {
    severity: "force_update",
    is_active: true,
    valid_until: FUTURE,
    target_countries: ["SA"],
    action_url: "https://example.test/app",
  };
  // [] means "every country" in catalog-announcements' filter.
  assert.deepEqual(
    validateAnnouncementPublish({ target_countries: [] }, { stored, now: NOW }),
    { ok: false, error: FORCE_UPDATE_CONFIRMATION_REQUIRED },
    "SA-only -> worldwide blocks clients it was not blocking",
  );
});

test("C-2a: arming without a working action_url is refused outright", () => {
  // ForceUpdateScreen falls back to a PLACEHOLDER store URL with a fake app id
  // (app/lib/features/onboarding/force_update_screen.dart: id0000000000).
  // Arming with no action_url bricks every client behind a dead button, so this
  // is a genuine safety precondition — unlike version bounds, which cannot work
  // at all while no build defines APP_VERSION.
  const armed = {
    severity: "force_update",
    is_active: true,
    valid_until: FUTURE,
    action_url: null,
  };
  const result = validateAnnouncementPublish(armed, {
    confirmForceUpdate: true,
    now: NOW,
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, FORCE_UPDATE_ACTION_URL_REQUIRED);
});

test("C-2a: PATCH selects the fields the guard needs to judge blocking", () => {
  // Selecting only severity/is_active silently reintroduces the temporal
  // bypass: the guard cannot see a window it is not given.
  const route = read("app/api/announcements/route.ts");
  const patchBody = route.slice(route.indexOf("export async function PATCH"));
  const select = patchBody.match(/\.select\("([^"]+)"\)/);
  assert.ok(select, "PATCH must load the stored row");
  for (const field of [
    "severity",
    "is_active",
    "valid_until",
    "target_countries",
    "action_url",
  ]) {
    assert.match(select[1], new RegExp(`\\b${field}\\b`), `stored row must include ${field}`);
  }
});

test("C-2a-2: an arming PATCH is routed to the audited RPC, never the generic update", () => {
  const route = read("app/api/announcements/route.ts");
  const patchBody = route.slice(route.indexOf("export async function PATCH"));
  assert.match(
    patchBody,
    /const isArming\s*=\s*\n?\s*blocksClients\(\{ \.\.\.stored, \.\.\.payload \}\) && !blocksClients\(stored\)/,
    "the route must detect the arming TRANSITION itself",
  );
  assert.match(
    patchBody,
    /supabase\.rpc\(\s*\n?\s*"arm_force_update"/,
    "arming must go through the SECURITY DEFINER RPC that audits + sets the sentinel",
  );
  assert.match(
    patchBody,
    /force_update_arm_reason_required/,
    "an arm must carry a reason for the audit row",
  );
});

test("C-2a-2: a missing RPC fails CLOSED — it must not fall back", () => {
  // A fallback to the generic update would silently restore the unaudited path
  // the RPC exists to replace, and it would do so exactly when the database
  // protection is absent — the worst possible moment.
  const route = read("app/api/announcements/route.ts");
  const armStart = route.indexOf("if (isArming)");
  const armBlock = route.slice(
    armStart,
    route.indexOf("const { data, error } = await supabase", armStart),
  );
  assert.match(armBlock, /force_update_arming_unavailable/);
  assert.match(armBlock, /503/, "an undeployed migration is a service state, not a bad request");
  assert.doesNotMatch(
    armBlock,
    /\.update\(payload\)/,
    "the arm path must never fall through to the generic update",
  );
});

// ── optional update + What's new: non-blocking types ───────────────────────

test("update_available and release_notes never need the force-update confirmation", () => {
  for (const severity of ["update_available", "release_notes"]) {
    const payload = { severity, is_active: true };
    assert.equal(armsForceUpdate(payload), false, severity);
    assert.equal(blocksClients(payload), false, severity);
    assert.deepEqual(validateAnnouncementPublish(payload), { ok: true }, severity);
  }
});

test("the form offers both new types with version targeting and a store link", () => {
  const labels = read("lib/labels.ts");
  assert.match(labels, /value: "update_available", label: "تحديث متاح/);
  assert.match(labels, /value: "release_notes", label: "ما الجديد/);
  const page = read("app/(admin)/announcements/page.tsx");
  assert.match(page, /VERSION_TARGETED = \["force_update", "update_available", "release_notes"\]/,
    "update_available must be targetable with max_app_version");
  assert.match(page, /VERSION_TARGETED\.includes\(form\.severity\)/);
  assert.match(page, /form\.severity === "update_available" && !form\.action_url\.trim\(\)/,
    "an update banner without a store link would open the placeholder app id");
});
