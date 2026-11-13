/**
 * WP5-Lite — feature-flag registry and change planner.
 *
 * THE SOURCE OF TRUTH for "who reads this flag, and what does a rollout mean for
 * it". It is deliberately code, not a database table: the readers live in code
 * (app/lib FeatureFlagService, supabase/functions) and
 * tests/flag-registry.test.mjs RE-DERIVES the reader inventory from those sources
 * on every run, so this file cannot silently drift from reality.
 *
 * No imports: this module is loaded by the Next.js bundler AND run directly by
 * `node --test` (type stripping), so keep it dependency-free and enum-free.
 */

export type FlagGroup =
  | "smart_capture_ai"
  | "sync"
  | "planning"
  | "monetization"
  | "experimental_high_risk"
  | "not_wired";
export type FlagReader = "app" | "server";
export type FlagStatus = "app_read" | "server_read" | "both" | "not_wired" | "retired_but_read";
export type FlagRisk = "low" | "medium" | "high";
export type RolloutSemantics = "app_percent_country" | "server_all_or_nothing" | "none";
export type ValueType = "boolean" | "number" | "string" | "json";

export type FlagMeta = {
  group: FlagGroup;
  readers: FlagReader[];
  status: FlagStatus;
  risk: FlagRisk;
  rolloutSemantics: RolloutSemantics;
  notes: string;
  dependencies?: string[];
  /** Type a missing row is created with (only for flags that have a reader). */
  valueType?: ValueType;
  /** Value a missing row is created with. */
  defaultValue?: string;
  /** Inclusive integer range the reader accepts (number flags). */
  intRange?: [number, number];
  /** Arming is HARD-BLOCKED (planner + RPC) until the underlying engine is wired. */
  unsafeToArm?: boolean;
};

const OVERRIDE_NOTE =
  " ملاحظة: يمكن لـ feature_flag_overrides (لكل مستخدم) فرض هذا المفتاح تاريخيًا — لا تُنشئ overrides لهذا المفتاح؛ التطبيق يتجاهلها له.";

const NO_EFFECT = "لا يوجد قارئ لهذا المفتاح في التطبيق أو الخادم — تغييره لا يؤثر على أي سلوك.";

const appBool = (
  group: FlagGroup,
  risk: FlagRisk,
  notes: string,
  extra: Partial<FlagMeta> = {},
): FlagMeta => ({
  group,
  readers: ["app"],
  status: "app_read",
  risk,
  // NB: "country" only applies when catalog-flags receives a country from the
  // client (syncFlags countryCode); without one the server does not filter.
  rolloutSemantics: "app_percent_country",
  notes,
  valueType: "boolean",
  defaultValue: "false",
  ...extra,
});

const notWired = (group: FlagGroup, notes = NO_EFFECT): FlagMeta => ({
  group,
  readers: [],
  status: "not_wired",
  risk: "low",
  rolloutSemantics: "none",
  notes,
});

const BANNER_NOTE = "تُقرأ في التطبيق عبر AdPlacement.flagKey. تعمل فقط مع تفعيل enable_banner_ads.";
export const FLAG_REGISTRY: Record<string, FlagMeta> = {
  // ── App-read (FeatureFlagService.getBool / getInt) ──────────────────────────
  enable_coupons: appBool("monetization", "low", "يُظهر قسم الكوبونات والعروض في التطبيق."),
  enable_referrals: appBool("monetization", "medium", "يُظهر دعوة الأصدقاء ومكافآتها (مكافآت فعلية للمستخدمين)."),
  enable_report_ads: appBool("monetization", "low", "يُظهر الإعلانات داخل شاشة التقارير."),
  enable_banner_ads: appBool("monetization", "low", "المفتاح الرئيسي لكل الإعلانات الشريطية."),
  enable_banner_transactions_list: appBool("monetization", "low", BANNER_NOTE),
  enable_banner_dashboard: appBool("monetization", "low", BANNER_NOTE),
  enable_banner_goals: appBool("monetization", "low", BANNER_NOTE),
  enable_banner_subscriptions: appBool("monetization", "low", BANNER_NOTE),
  enable_banner_reports: appBool("monetization", "low", BANNER_NOTE),
  enable_banner_achievements: appBool("monetization", "low", BANNER_NOTE),
  enable_offers_merchants: appBool("monetization", "low", "كتالوج التجار وصفحاتهم وقسم «لك»."),
  enable_affiliate_links: appBool("monetization", "medium", "مسار روابط الشراكة المُتتبَّعة؛ إيقافه يجعل كل زر رابطًا عاديًا."),
  enable_proof_autocommit: appBool(
    "experimental_high_risk",
    "high",
    "خطر مرتفع — غير آمن للتفعيل حاليًا: محرك الإثبات (proof) غير مُغذّى (proofResult يبقى null)، فالتفعيل يمنع التأكيد التلقائي المحلي (المسار القديم) أو يُسقط الالتقاطات إلى صندوق المراجعة الذكي (local_auto_confirm_v2). التفعيل محظور في الواجهة والخادم؛ يُرفع الحظر فقط عند ربط محرك الإثبات." + OVERRIDE_NOTE,
    { unsafeToArm: true },
  ),
  proof_parser_confidence_min: appBool(
    "smart_capture_ai",
    "high",
    "حدّ ثقة المحلل بالألف (permille). يقبل التطبيق 991 إلى 1000 فقط؛ أي قيمة أخرى تعود إلى 990.",
    { valueType: "number", defaultValue: "1000", intRange: [991, 1000] },
  ),
  local_auto_confirm_v2: appBool(
    "smart_capture_ai",
    "high",
    "سلوك التأكيد التلقائي للالتقاط المحلي (يؤثر على تسجيل المعاملات المالية).",
  ),
  ai_sender_mapping_auto: appBool(
    "smart_capture_ai",
    "medium",
    "قبول ربط المُرسِل بالبنك تلقائيًا بعد تحقق الذكاء الاصطناعي." + OVERRIDE_NOTE,
    {
      dependencies: [
        "يتطلب نشر المهاجرة المؤجلة 0100 (sender_bank_mappings.accepted_by) قبل التفعيل — يمنع الخادم التفعيل بدونها.",
      ],
    },
  ),
  capture_ai_fallback_enabled: appBool(
    "smart_capture_ai",
    "medium",
    "بديل الذكاء الاصطناعي عند فشل المحلل المحلي في الالتقاط.",
  ),

  capture_import_v3: appBool(
    "smart_capture_ai",
    "high",
    "مسار استيراد الالتقاطات المحلي الجديد على iOS؛ يؤثر على إدخال المعاملات إلى قاعدة بيانات الجهاز.",
  ),

  capture_notify_v2: appBool(
    "smart_capture_ai",
    "medium",
    "مسار إشعارات الالتقاطات الجديد على iOS؛ يغيّر قرارات الإشعار ومحتوى التنبيه المحلي.",
  ),

  android_capture_ai_enabled: appBool(
    "smart_capture_ai",
    "medium",
    "تحليل الذكاء الاصطناعي لرسائل الالتقاط على Android داخل التطبيق؛ إيقافه يُبقي التحليل محليًا فقط.",
  ),

  // ── Not wired: no reader anywhere ──────────────────────────────────────────
  ledger_dual_write: { ...notWired("experimental_high_risk", `متقاعد. ${NO_EFFECT}`), risk: "high" },
  capture_direct_supabase_write: { ...notWired("experimental_high_risk", `متقاعد. ${NO_EFFECT}`), risk: "high" },
  transactions_supabase_primary: { ...notWired("experimental_high_risk", `متقاعد. ${NO_EFFECT}`), risk: "high" },
  enable_goals: notWired("planning"),
  enable_announcements: notWired("not_wired"),
  parser_engine_version: notWired("not_wired"),
  enable_offers_personalization: notWired("monetization"),
  enable_savings_claims: notWired("monetization"),
  ledger_push_sync: notWired("sync"),
  ledger_pull_sync: notWired("sync"),
  smart_inbox_pull_sync: notWired("sync"),
  capture_direct_ledger_write: notWired("sync"),
  planning_accounts_sync: notWired("planning"),
  planning_budgets_sync: notWired("planning"),
  planning_subscriptions_sync: notWired("planning"),
  planning_goals_sync: notWired("planning"),
  planning_plans_sync: notWired("planning"),
  accounts_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  budgets_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  goals_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  plans_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  subscriptions_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  smart_inbox_supabase_primary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  dashboard_supabase_summary: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
  budget_progress_supabase_rpc: notWired("not_wired", `متقاعد. ${NO_EFFECT}`),
};

const UNREGISTERED: FlagMeta = {
  group: "not_wired",
  readers: [],
  status: "not_wired",
  risk: "low",
  rolloutSemantics: "none",
  notes: "مفتاح غير مسجَّل في السجل — لا قارئ معروف له، لذا التعديل معطّل إلا للوصف.",
};

export function flagMeta(key: string): FlagMeta {
  return FLAG_REGISTRY[key] ?? UNREGISTERED;
}
export const isRegistered = (key: string) => Object.prototype.hasOwnProperty.call(FLAG_REGISTRY, key);

export const GROUP_ORDER: FlagGroup[] = [
  "smart_capture_ai",
  "monetization",
  "experimental_high_risk",
  "sync",
  "planning",
  "not_wired",
];

/** A flag a bulk operation may touch: has a real reader and is not high risk. */
const EDITABLE_STATUSES: FlagStatus[] = ["app_read", "server_read", "both", "retired_but_read"];
const BULK_STATUSES: FlagStatus[] = ["app_read", "server_read", "both"];

export const isEditable = (key: string) => EDITABLE_STATUSES.includes(flagMeta(key).status);
export const isBulkEligible = (key: string) => {
  const m = flagMeta(key);
  return BULK_STATUSES.includes(m.status) && m.risk !== "high";
};
export const requiresTypedConfirmation = (key: string) => flagMeta(key).risk === "high";
export const isServerRead = (key: string) => flagMeta(key).readers.includes("server");
export const supportsPartialRollout = (key: string) => flagMeta(key).rolloutSemantics === "app_percent_country";

export type EditableField = "is_active" | "value" | "rollout_percent" | "target_countries" | "description";

export function editableFields(key: string): EditableField[] {
  const m = flagMeta(key);
  if (!EDITABLE_STATUSES.includes(m.status)) return ["description"];
  if (m.rolloutSemantics === "app_percent_country") {
    return ["is_active", "value", "rollout_percent", "target_countries", "description"];
  }
  return ["is_active", "value", "rollout_percent", "description"];
}

/** Registry keys that have a reader but no feature_flags row yet. */
export function missingRowKeys(existingKeys: string[]): string[] {
  const have = new Set(existingKeys);
  return Object.keys(FLAG_REGISTRY).filter((k) => isEditable(k) && !have.has(k));
}

// ─── change planning (shared by /preview and /apply; the RPC re-validates) ────

export type FlagRow = {
  key: string;
  value_type: string;
  value: string;
  description: string | null;
  rollout_percent: number;
  target_countries: unknown;
  is_active: boolean;
  updated_at: string;
};

export type ChangeRequest = {
  key: string;
  create?: boolean;
  expected_updated_at?: string | null;
  set?: Partial<Record<EditableField, unknown>>;
};

export type PlanError = { key: string; code: string; detail?: string };
export type Diff = { key: string; field: string; old: unknown; new: unknown };
export type RpcChange = {
  key: string;
  create?: boolean;
  value_type?: string;
  expected_updated_at?: string | null;
  server_read: boolean;
  set: Record<string, unknown>;
};
export type Plan = {
  ok: boolean;
  errors: PlanError[];
  warnings: { key: string; code: string; detail: string }[];
  diffs: Diff[];
  rpcChanges: RpcChange[];
  highRiskKeys: string[];
};

const COUNTRY = /^[A-Z]{2}$/;
const MAX_CHANGES = 50;

/** Validates one value against a value_type. Returns an error code or null. */
export function validateValue(valueType: string, value: unknown): string | null {
  if (typeof value !== "string") return "value_invalid";
  if (valueType === "boolean") return value === "true" || value === "false" ? null : "value_type_mismatch";
  if (valueType === "number") return /^-?[0-9]+(\.[0-9]+)?$/.test(value) ? null : "value_type_mismatch";
  if (valueType === "json") {
    try {
      JSON.parse(value);
      return null;
    } catch {
      return "value_type_mismatch";
    }
  }
  return value.length <= 1000 ? null : "value_too_long";
}

function pick(o: Record<string, unknown>, keys: string[]) {
  return Object.fromEntries(keys.filter((k) => k in o).map((k) => [k, o[k]]));
}

function sameJson(a: unknown, b: unknown) {
  return JSON.stringify(a) === JSON.stringify(b);
}

export function buildPlan(
  rows: FlagRow[],
  requests: ChangeRequest[],
  ctx: { typedConfirmation?: string | null; skipTypedCheck?: boolean } = {},
): Plan {
  const plan: Plan = { ok: false, errors: [], warnings: [], diffs: [], rpcChanges: [], highRiskKeys: [] };
  const err = (key: string, code: string, detail?: string) => plan.errors.push({ key, code, detail });
  const byKey = new Map(rows.map((r) => [r.key, r]));

  if (!Array.isArray(requests) || requests.length === 0 || requests.length > MAX_CHANGES) {
    err("*", "changes_invalid");
    return plan;
  }
  if (new Set(requests.map((r) => r?.key)).size !== requests.length) {
    err("*", "duplicate_key_in_changes");
    return plan;
  }

  for (const req of requests) {
    const key = typeof req?.key === "string" ? req.key : "";
    const set = (req?.set && typeof req.set === "object" ? req.set : {}) as Record<string, unknown>;
    if (!key) {
      err("*", "key_invalid");
      continue;
    }
    if (!isRegistered(key)) {
      err(key, "unregistered_flag", "المفتاح غير مسجَّل في السجل");
      continue;
    }
    const meta = flagMeta(key);
    const allowed = editableFields(key);
    const unknownField = Object.keys(set).find((f) => !allowed.includes(f as EditableField));
    if (unknownField) {
      err(key, meta.status === "not_wired" ? "not_wired_description_only" : "field_not_editable", unknownField);
      continue;
    }
    if (requests.length > 1 && !isBulkEligible(key)) {
      err(key, "bulk_ineligible", "المفتاح غير مؤهل للتعديل الجماعي (غير مربوط أو عالي الخطورة)");
      continue;
    }

    const existing = byKey.get(key);
    const create = req.create === true;
    if (create) {
      if (existing) {
        err(key, "flag_exists");
        continue;
      }
      if (!isEditable(key)) {
        err(key, "not_wired_cannot_create");
        continue;
      }
      if (set.is_active === true) {
        err(key, "create_must_be_inactive");
        continue;
      }
      if ("rollout_percent" in set || "target_countries" in set) {
        err(key, "create_takes_defaults_only");
        continue;
      }
    } else if (!existing) {
      err(key, "flag_not_found");
      continue;
    } else if (!req.expected_updated_at) {
      err(key, "expected_updated_at_required");
      continue;
    }

    const valueType = existing?.value_type ?? meta.valueType ?? "boolean";
    const before = {
      is_active: existing?.is_active ?? false,
      value: existing?.value ?? meta.defaultValue ?? "false",
      rollout_percent: existing?.rollout_percent ?? 0,
      target_countries: (existing?.target_countries as unknown[] | undefined) ?? [],
      description: existing?.description ?? null,
    };
    const after: Record<string, unknown> = { ...before, ...set };

    if ("is_active" in set && typeof set.is_active !== "boolean") err(key, "is_active_invalid");
    if ("value" in set || create) {
      const v = validateValue(valueType, after.value);
      if (v) err(key, v, `value_type=${valueType}`);
      else if (meta.intRange) {
        const n = Number(after.value);
        if (!Number.isInteger(n) || n < meta.intRange[0] || n > meta.intRange[1]) {
          err(key, "value_out_of_range", `${meta.intRange[0]}..${meta.intRange[1]}`);
        }
      }
    }
    if ("rollout_percent" in set) {
      const r = set.rollout_percent;
      if (typeof r !== "number" || !Number.isInteger(r) || r < 0 || r > 100) err(key, "rollout_percent_invalid");
    }
    if ("target_countries" in set) {
      const c = set.target_countries;
      if (
        !Array.isArray(c) ||
        c.length > 250 ||
        c.some((x) => typeof x !== "string" || !COUNTRY.test(x)) ||
        new Set(c).size !== c.length
      ) {
        err(key, "target_country_invalid");
      }
    }
    if ("description" in set) {
      const d = set.description;
      if (!(d === null || (typeof d === "string" && d.length <= 500))) err(key, "description_invalid");
    }

    if (isServerRead(key)) {
      const r = after.rollout_percent as number;
      const c = after.target_countries as unknown[];
      if (("rollout_percent" in set && r > 0 && r < 100) || ("target_countries" in set && c.length > 0)) {
        err(key, "server_read_partial_rollout_unsupported");
      } else if (after.is_active === true && (r < 100 || c.length > 0)) {
        err(key, "server_read_requires_full_rollout", "فعّل مع نسبة إطلاق 100 وبدون دول");
      }
    }

    // Hard block, no typed-key override. Turning it off / editing the description is fine.
    if (
      meta.unsafeToArm &&
      after.is_active === true &&
      String(after.value).toLowerCase() === "true" &&
      (after.rollout_percent as number) > 0 &&
      ("is_active" in set || "value" in set || "rollout_percent" in set)
    ) {
      err(key, "unsafe_to_arm", meta.notes);
    }
    if (meta.dependencies?.length && after.is_active === true && String(after.value).toLowerCase() === "true") {
      plan.warnings.push({ key, code: "has_dependency", detail: meta.dependencies.join(" ") });
    }

    const diffs: Diff[] = [];
    if (create) {
      diffs.push({ key, field: "_created", old: null, new: { value_type: valueType, value: after.value, is_active: false } });
    } else {
      for (const f of Object.keys(set)) {
        if (!sameJson((before as Record<string, unknown>)[f], after[f])) {
          diffs.push({ key, field: f, old: (before as Record<string, unknown>)[f], new: after[f] });
        }
      }
    }
    plan.diffs.push(...diffs);
    if (requiresTypedConfirmation(key) && diffs.length > 0) plan.highRiskKeys.push(key);

    plan.rpcChanges.push({
      key,
      ...(create ? { create: true, value_type: valueType } : { expected_updated_at: req.expected_updated_at }),
      server_read: isServerRead(key),
      set: create ? pick(set, ["value", "description"]) : set,
    });
  }

  if (plan.errors.length === 0 && plan.diffs.length === 0) err("*", "no_effective_changes");

  if (plan.errors.length === 0 && plan.highRiskKeys.length > 0 && !ctx.skipTypedCheck) {
    if (plan.highRiskKeys.length > 1) err(plan.highRiskKeys[0], "high_risk_single_only");
    else if (ctx.typedConfirmation !== plan.highRiskKeys[0]) {
      err(plan.highRiskKeys[0], "typed_confirmation_required", "اكتب اسم المفتاح للتأكيد");
    }
  }

  plan.ok = plan.errors.length === 0;
  return plan;
}

/** /preview reports validity and the diff; the typed-confirmation gate is enforced by /apply. */
export function previewPlan(rows: FlagRow[], requests: ChangeRequest[]): Plan {
  return buildPlan(rows, requests, { skipTypedCheck: true });
}
