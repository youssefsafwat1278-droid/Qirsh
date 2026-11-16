import type { Tone } from "@/components/ui/primitives";

/**
 * Presentation-only Arabic vocabulary.
 *
 * The database keeps its enum values exactly as they are — nothing here is
 * written back, parsed, or compared server-side. This module exists so a raw
 * value like `force_update` or `balance_inquiry` never reaches the operator's
 * screen as the primary label.
 *
 * Every lookup falls back to the raw value, so a new enum member added on the
 * backend shows up untranslated instead of disappearing.
 */
function pick(map: Record<string, string>, key: string | null | undefined): string {
  if (!key) return "—";
  return map[key] ?? key;
}

/* ─────────────────────────────────────────── parsers / catalog ── */

const VALIDATION: Record<string, string> = {
  passed: "اجتازت الفحص",
  pending: "بانتظار الفحص",
  failed: "فشل الفحص",
};
const VALIDATION_TONE: Record<string, Tone> = {
  passed: "success",
  pending: "warning",
  failed: "danger",
};
export const validationLabel = (v: string | null | undefined) => pick(VALIDATION, v);
export const validationTone = (v: string | null | undefined): Tone =>
  (v && VALIDATION_TONE[v]) || "neutral";

const TXN_TYPE: Record<string, string> = {
  debit: "خصم",
  credit: "إيداع",
  balance_inquiry: "استعلام رصيد",
};
const TXN_TONE: Record<string, Tone> = {
  debit: "danger",
  credit: "success",
  balance_inquiry: "neutral",
};
export const txnTypeLabel = (v: string | null | undefined) => pick(TXN_TYPE, v);
export const txnTypeTone = (v: string | null | undefined): Tone => (v && TXN_TONE[v]) || "neutral";
export const TXN_TYPE_OPTIONS = Object.entries(TXN_TYPE).map(([value, label]) => ({ value, label }));

const LANGUAGE: Record<string, string> = {
  ar: "عربي",
  en: "إنجليزي",
  ar_en: "عربي وإنجليزي",
};
export const languageLabel = (v: string | null | undefined) => pick(LANGUAGE, v);
export const LANGUAGE_OPTIONS = Object.entries(LANGUAGE).map(([value, label]) => ({ value, label }));

const CATEGORY_TYPE: Record<string, string> = {
  expense: "مصروفات",
  income: "دخل",
  transfer: "تحويلات",
  saving: "ادخار",
};
export const categoryTypeLabel = (v: string | null | undefined) => pick(CATEGORY_TYPE, v);

/* ───────────────────────────────────────────────── announcements ── */

const SEVERITY: Record<string, string> = {
  info: "معلومة",
  warning: "تنبيه",
  maintenance: "صيانة",
  force_update: "تحديث إجباري",
  update_available: "تحديث متاح",
  release_notes: "ما الجديد",
};
const SEVERITY_TONE: Record<string, Tone> = {
  info: "info",
  warning: "warning",
  maintenance: "brand",
  force_update: "danger",
  update_available: "info",
  release_notes: "brand",
};
export const severityLabel = (v: string | null | undefined) => pick(SEVERITY, v);
export const severityTone = (v: string | null | undefined): Tone => (v && SEVERITY_TONE[v]) || "neutral";
export const SEVERITY_OPTIONS = [
  { value: "info", label: "معلومة — لافتة عادية" },
  { value: "warning", label: "تنبيه — أمر يحتاج انتباه المستخدم" },
  { value: "maintenance", label: "صيانة — عمل مجدول على الخدمة" },
  { value: "force_update", label: "تحديث إجباري — يمنع استخدام التطبيق" },
  { value: "update_available", label: "تحديث متاح — لافتة اختيارية تدعو للتحديث" },
  { value: "release_notes", label: "ما الجديد — ملاحظات في صفحة «ما الجديد»" },
];

/* ─────────────────────────────────────────────────────── campaigns ── */

const CAMPAIGN_TYPE: Record<string, string> = {
  notification: "إشعار",
  dashboard_banner: "لافتة في الشاشة الرئيسية",
  settings_card: "بطاقة داخل الإعدادات",
  modal: "نافذة منبثقة",
};
export const campaignTypeLabel = (v: string | null | undefined) => pick(CAMPAIGN_TYPE, v);
export const CAMPAIGN_TYPE_OPTIONS = Object.entries(CAMPAIGN_TYPE).map(([value, label]) => ({
  value,
  label,
}));

const SEGMENT: Record<string, string> = {
  all: "كل المستخدمين",
  new_user: "مستخدم جديد",
  no_shortcut: "لم يفعّل الاختصار بعد",
  has_first_transaction: "سجّل أول عملية",
  inactive_3_days: "لم يفتح التطبيق منذ 3 أيام",
  active_user: "مستخدم نشِط",
  budget_user: "يستخدم الميزانيات",
};
export const segmentLabel = (v: string | null | undefined) => pick(SEGMENT, v);
export const SEGMENT_OPTIONS = Object.entries(SEGMENT).map(([value, label]) => ({ value, label }));

/* ───────────────────────────────────────────────── offers / coupons ── */

const COUPON_STATUS: Record<string, string> = {
  live: "معروض الآن",
  scheduled: "مجدول",
  expired: "منتهي",
  disabled: "متوقف",
};
const COUPON_STATUS_TONE: Record<string, Tone> = {
  live: "success",
  scheduled: "info",
  expired: "neutral",
  disabled: "warning",
};
export const couponStatusLabel = (v: string | null | undefined) => pick(COUPON_STATUS, v);
export const couponStatusTone = (v: string | null | undefined): Tone =>
  (v && COUPON_STATUS_TONE[v]) || "neutral";

const REDEMPTION: Record<string, string> = {
  code: "كود خصم",
  link: "رابط مباشر",
};
export const redemptionLabel = (v: string | null | undefined) => pick(REDEMPTION, v);

/* ────────────────────────────────────────────── referrals / rewards ── */

const REFERRAL_STATUS: Record<string, string> = {
  attributed: "مُسجَّلة",
  qualified: "مُحتسَبة",
  rejected: "مرفوضة",
  reversed: "أُلغيت",
};
const REFERRAL_STATUS_TONE: Record<string, Tone> = {
  attributed: "info",
  qualified: "success",
  rejected: "danger",
  reversed: "danger",
};
export const referralStatusLabel = (v: string | null | undefined) => pick(REFERRAL_STATUS, v);
export const referralStatusTone = (v: string | null | undefined): Tone =>
  (v && REFERRAL_STATUS_TONE[v]) || "neutral";

const ATTRIBUTION: Record<string, string> = {
  code: "بإدخال الكود",
  link: "عبر رابط الدعوة",
  deferred_deeplink: "عبر رابط مؤجَّل",
  manual: "يدويًا من الإدارة",
};
export const attributionLabel = (v: string | null | undefined) => pick(ATTRIBUTION, v);

const ENTITLEMENT_STATUS: Record<string, string> = {
  active: "سارية",
  expired: "منتهية",
  revoked: "مسحوبة",
  inactive: "غير مفعّلة",
};
export const entitlementStatusLabel = (v: string | null | undefined) => pick(ENTITLEMENT_STATUS, v);

const ENTITLEMENT_TYPE: Record<string, string> = {
  report_export_ad_free: "تصدير التقارير بدون إعلان",
};
export const entitlementTypeLabel = (v: string | null | undefined) => pick(ENTITLEMENT_TYPE, v);

const CYCLE_STATE: Record<string, string> = {
  open: "دورة مفتوحة",
  completed: "دورة مكتملة",
  closed: "دورة مغلقة",
};
export const cycleStateLabel = (v: string | null | undefined) => pick(CYCLE_STATE, v);

const AUDIT_ACTION: Record<string, string> = {
  grant: "منح ميزة",
  extend: "تمديد ميزة",
  shorten: "تقصير مدة ميزة",
  revoke: "سحب ميزة",
  adjust_progress: "تعديل عدد الدعوات",
  rotate_code: "تدوير كود الدعوة",
  reject_referral: "رفض دعوة",
  reverse_referral: "إلغاء احتساب دعوة",
  publish_rule: "نشر قاعدة جديدة",
  deactivate_rule: "إيقاف القاعدة السارية",
};
export const auditActionLabel = (v: string | null | undefined) => pick(AUDIT_ACTION, v);

/* ──────────────────────────────────────────────────── feature flags ── */

const VALUE_TYPE: Record<string, string> = {
  bool: "تشغيل/إيقاف",
  boolean: "تشغيل/إيقاف",
  string: "نص",
  int: "رقم",
  number: "رقم",
  json: "إعداد متقدم",
};
export const valueTypeLabel = (v: string | null | undefined) => pick(VALUE_TYPE, v);

/* ────────────────────────────────────── UX-021 — flag descriptions ── */

/**
 * UX-021 — raw English engineering notes were shown to a business operator.
 *
 * `feature_flags.description` is seeded from the migrations, and several rows
 * read like commit messages: *"Phase 2: AccountRepository reads/writes go
 * direct to Supabase instead of Drift."* An operator deciding whether to flip a
 * switch cannot act on that, and it is in the wrong language for this panel.
 *
 * This maps the known keys to what flipping the switch actually DOES. It is a
 * presentation layer on purpose: rewriting the seeded rows would need a
 * migration against a database this pass does not touch, and the descriptions
 * would still be wrong for any deployment already carrying the old text.
 */
const FLAG_DESCRIPTION: Record<string, string> = {
  enable_goals: "إظهار قسم الأهداف داخل التطبيق.",
  enable_coupons: "إظهار قسم الكوبونات والعروض داخل التطبيق.",
  enable_announcements: "السماح بظهور لافتات الإعلانات على الشاشة الرئيسية.",
  enable_referrals: "إظهار دعوة الأصدقاء ومكافآتها داخل التطبيق.",
  enable_report_ads: "إظهار الإعلانات داخل شاشة التقارير.",
  parser_engine_version: "إصدار محرك قراءة رسائل البنوك المستخدَم.",
  ledger_dual_write: "كتابة العمليات إلى السحابة بالتوازي مع الجهاز.",
  ledger_push_sync: "رفع عمليات الجهاز إلى السحابة.",
  ledger_pull_sync: "تنزيل العمليات من السحابة إلى الجهاز.",
  smart_inbox_pull_sync: "تنزيل عناصر صندوق المراجعة من السحابة.",
  capture_direct_supabase_write: "كتابة الرسائل الملتقطة إلى السحابة مباشرة.",
  planning_budgets_sync: "مزامنة الميزانيات بين الأجهزة.",
  planning_goals_sync: "مزامنة الأهداف بين الأجهزة.",
  planning_plans_sync: "مزامنة الخطط بين الأجهزة.",
  planning_subscriptions_sync: "مزامنة الاشتراكات والفواتير بين الأجهزة.",
};

/**
 * Keys the app no longer reads at all (MALI-034 retired the Supabase-primary
 * routing). Verified against the client source: no `featureFlag(...)` call site
 * references them. Flipping one of these changes nothing, and an operator has
 * no way to discover that from the panel — so the panel says it.
 *
 * WP5-Lite: `transactions_supabase_primary` (and `capture_direct_supabase_write`)
 * were listed here but the Edge Functions still read them
 * (supabase/functions/_shared/ledger.ts). They are "retired but still read" — see
 * lib/flag-registry.ts, the source of truth — and must NOT be labelled as having
 * no effect.
 */
const RETIRED_FLAG_KEYS = new Set([
  "accounts_supabase_primary",
  "budgets_supabase_primary",
  "goals_supabase_primary",
  "plans_supabase_primary",
  "subscriptions_supabase_primary",
  "smart_inbox_supabase_primary",
]);

export const isRetiredFlag = (key: string) => RETIRED_FLAG_KEYS.has(key);

/**
 * The operator-facing description for a flag.
 *
 * Falls back to whatever the row stores when the key is unknown — a flag added
 * later must not silently lose its description just because this map has not
 * caught up. Returning `undefined` lets the caller keep its own empty-state
 * copy rather than this file inventing one.
 */
export function flagDescription(
  key: string,
  stored: string | null | undefined,
): string | undefined {
  return FLAG_DESCRIPTION[key] ?? stored ?? undefined;
}

/**
 * UX-018 — keys that live in `categories` but are not spendable categories.
 *
 * `all_expenses` is the scope marker an "all expenses" budget stores in place
 * of a category id. The client filters it out of every user-facing picker; the
 * Admin list showed it as category 1 of 21.
 */
const SENTINEL_CATEGORY_KEYS = new Set(["all_expenses"]);

export const isSentinelCategory = (key: string) => SENTINEL_CATEGORY_KEYS.has(key);
