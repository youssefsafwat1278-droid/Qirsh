/**
 * Admin push broadcasts — shared by the API routes (authority) and the page
 * (UX). The database is the final authority: admin_create_push_broadcast()
 * re-checks the content, the deep-link allowlist and the confirmed count
 * (migration 20261116160000).
 */

/**
 * In-app routes a broadcast may open. Must equal the CHECK on
 * push_broadcasts.deep_link and the app's kBroadcastRoutes (contract-tested).
 */
export const BROADCAST_DEEP_LINKS = [
  { value: "/announcements", label: "صفحة الإعلانات" },
  { value: "/budgets", label: "الميزانيات" },
  { value: "/goals", label: "الأهداف" },
  { value: "/subscriptions", label: "الاشتراكات والفواتير" },
  { value: "/reports", label: "التقارير" },
  { value: "/achievements", label: "الإنجازات" },
  { value: "/settings", label: "الإعدادات" },
  { value: "/privacy", label: "الخصوصية" },
];

export const TITLE_MAX = 120;
export const BODY_MAX = 600;

/**
 * @param {{title_ar?: string, title_en?: string, body_ar?: string, body_en?: string, deep_link?: string | null}} draft
 * @returns {{ok: true, value: {title_ar: string, title_en: string, body_ar: string, body_en: string, deep_link: string | null}} | {ok: false, errors: string[]}}
 */
export function validateBroadcastDraft(draft) {
  const errors = [];
  const text = (v) => (typeof v === "string" ? v.trim() : "");
  const value = {
    title_ar: text(draft?.title_ar),
    title_en: text(draft?.title_en),
    body_ar: text(draft?.body_ar),
    body_en: text(draft?.body_en),
    deep_link: text(draft?.deep_link) || null,
  };
  for (const k of ["title_ar", "title_en"]) {
    if (value[k].length === 0) errors.push(`${k}_required`);
    else if (value[k].length > TITLE_MAX) errors.push(`${k}_too_long`);
  }
  for (const k of ["body_ar", "body_en"]) {
    if (value[k].length === 0) errors.push(`${k}_required`);
    else if (value[k].length > BODY_MAX) errors.push(`${k}_too_long`);
  }
  if (value.deep_link !== null && !BROADCAST_DEEP_LINKS.some((l) => l.value === value.deep_link)) {
    errors.push("deep_link_not_allowed");
  }
  return errors.length ? { ok: false, errors } : { ok: true, value };
}

/**
 * The typed confirmation is the recipient DEVICE count from the dry run, typed
 * digit for digit. Returns the number to send to the RPC, or null.
 * @param {unknown} typed
 * @returns {number | null}
 */
export function parseTypedConfirmation(typed) {
  if (typeof typed !== "string") return null;
  const t = typed.trim();
  if (!/^[0-9]{1,9}$/.test(t)) return null;
  return Number(t);
}

/** Arabic text for the error codes the routes and RPCs return. */
export function broadcastErrorMessage(code) {
  switch (code) {
    case "recipient_count_changed":
      return "تغيّر عدد المستلمين منذ المعاينة. أعد المعاينة واكتب العدد الجديد.";
    case "no_recipients":
      return "لا يوجد مستلمون حاليًا — لن يُرسل شيء.";
    case "confirmation_invalid":
      return "اكتب عدد الأجهزة كما يظهر في المعاينة بالضبط.";
    case "deep_link_not_allowed":
      return "الوجهة المختارة غير مسموح بها.";
    case "validation_failed":
      return "العنوان والنص مطلوبان باللغتين وضمن الطول المسموح.";
    case "send_unavailable":
      return "تم إنشاء الرسالة لكن تعذّر تشغيل الإرسال الآن. استخدم «إعادة المحاولة» من السجل.";
    default:
      return "تعذّر تنفيذ العملية.";
  }
}
