// Capture-push hygiene shared by process-ios-sms (first attempt) and
// process-notification-retries (retries). CAP-3, manifest §4.8 / Q3.
//
// * Old clients and hidden-content captures use a generic APNs alert. New
//   clients explicitly opt in to a bounded transaction summary.
//   SMS text, balances and account/card identifiers never enter that summary.
// * A dead token is cleared by compare-and-swap, so a token the app re-registered in
//   the meantime is never wiped.
// * A retry is enqueued at most once per notification (UNIQUE(notification_log_id)).

import { serviceClient } from './capture_auth.ts';

type SupabaseClientLike = ReturnType<typeof serviceClient>;

// Q3 wording, verbatim from the manifest. Title is omitted (iOS shows the app name).
export const GENERIC_CAPTURE_PUSH = { title: '', body: 'New transaction captured' } as const;

/** Old captures without an explicit push summary retain their privacy contract. */
export function capturePushContent(notification: unknown): { title: string; body: string } {
  const n = notification as { pushAlert?: { title?: unknown; body?: unknown }; pushLanguage?: string } | null;
  const alert = n?.pushAlert;
  return alert && typeof alert.title === 'string' && typeof alert.body === 'string' &&
      alert.title.length > 0 && alert.title.length <= 120 && alert.body.length > 0 && alert.body.length <= 600
    ? { title: alert.title, body: alert.body }
    : n?.pushLanguage === 'ar' ? { title: '', body: 'تم رصد عملية جديدة' } : GENERIC_CAPTURE_PUSH;
}

export function transactionPushAlert(
  parsed: { amount?: number | null; currency?: string | null; merchant?: string | null;
    direction?: string | null; type?: string | null; category?: string | null;
    occurredAt?: string; comparisonTimestamp?: string; rawMessage?: string }, locale: string,
  context: { tzOffsetMinutes?: number | null; receivedAt?: string } = {},
): { title: string; body: string } | undefined {
  if (typeof parsed.amount !== 'number' || !Number.isFinite(parsed.amount) || parsed.amount <= 0 ||
      !/^[A-Z]{3}$/.test(parsed.currency ?? '')) return undefined;
  const ar = locale.toLowerCase().startsWith('ar');
  const title = parsed.type === 'refund' ? (ar ? 'استرداد' : 'Refund received')
    : parsed.type === 'transfer' ? (parsed.direction === 'credit'
      ? (ar ? 'تحويل وارد' : 'Transfer received') : parsed.direction === 'debit'
      ? (ar ? 'تحويل صادر' : 'Transfer sent') : (ar ? 'تحويل' : 'Transfer'))
    : parsed.type === 'withdrawal' ? (ar ? 'سحب نقدي' : 'Cash withdrawal')
    : parsed.direction === 'credit' || parsed.type === 'income' ? (ar ? 'إيداع وارد' : 'Deposit received')
    : parsed.type === 'payment' ? (ar ? 'عملية شراء' : 'Purchase')
    : (ar ? 'معاملة جديدة' : 'New transaction');
  const amount = parsed.amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const merchant = parsed.merchant?.replace(/[\r\n\t]/g, ' ').trim().slice(0, 80);
  // Only the network name leaves this function, never the SMS or its identifiers.
  const network = parsed.type === 'transfer' && /\b(?:ipn|instapay)\b/i.test(parsed.rawMessage ?? '')
    ? (ar ? 'عبر InstaPay' : 'Via InstaPay') : undefined;
  const category = PUSH_CATEGORIES[parsed.category ?? '']?.[ar ? 1 : 0];
  const when = pushLocalTime(parsed.occurredAt ?? parsed.comparisonTimestamp ?? context.receivedAt,
    context.tzOffsetMinutes, ar);
  const details = [category, when].filter(Boolean).join(' · ');
  return { title: `${title} · ${amount} ${parsed.currency}`,
    body: [network ?? merchant, details].filter(Boolean).join('\n') ||
      (ar ? 'افتح قرش لعرض المعاملة' : 'Open Qirsh to view transaction') };
}

const PUSH_CATEGORIES: Record<string, [string, string]> = {
  restaurants: ['Restaurants', 'مطاعم'], cafes: ['Cafés', 'مقاهي'],
  groceries: ['Groceries', 'بقالة'], transport: ['Transport', 'مواصلات'],
  fuel: ['Fuel', 'وقود'], bills: ['Bills', 'فواتير'], shopping: ['Shopping', 'تسوق'],
  health: ['Health', 'صحة'], education: ['Education', 'تعليم'],
  entertainment: ['Entertainment', 'ترفيه'], subscriptions: ['Subscriptions', 'اشتراكات'],
  transfers: ['Transfers', 'تحويلات'], cash: ['Cash', 'نقدي'], travel: ['Travel', 'سفر'],
  gifts: ['Gifts', 'هدايا'], kids: ['Kids', 'أطفال'], home: ['Home', 'منزل'],
  maintenance: ['Maintenance', 'صيانة'], fitness: ['Fitness', 'لياقة'],
  beauty: ['Beauty', 'عناية شخصية'], charity: ['Charity', 'تبرعات'], pets: ['Pets', 'حيوانات أليفة'],
  insurance: ['Insurance', 'تأمين'], income: ['Income', 'دخل'], other: ['Other', 'أخرى'],
};

function pushLocalTime(iso: string | undefined, offset: number | null | undefined, ar: boolean): string | undefined {
  if (!iso || !/(?:z|[+-]\d{2}:?\d{2})$/i.test(iso) || typeof offset !== 'number' ||
      !Number.isInteger(offset) || Math.abs(offset) > 840) return undefined;
  const local = new Date(new Date(iso).getTime() + offset * 60_000);
  if (Number.isNaN(local.getTime())) return undefined;
  const month = new Intl.DateTimeFormat(ar ? 'ar-EG' : 'en', { month: 'short', timeZone: 'UTC' }).format(local);
  const hour = local.getUTCHours();
  const period = ar ? (hour < 12 ? 'ص' : 'م') : (hour < 12 ? 'AM' : 'PM');
  return `${local.getUTCDate()} ${month}${ar ? '،' : ','} ${hour % 12 || 12}:${String(local.getUTCMinutes()).padStart(2, '0')} ${period}`;
}

const DEAD_TOKEN_CODES = new Set(['BadDeviceToken', 'Unregistered', 'ExpiredToken']);

export function isDeadApnsToken(result: { httpStatus: number | null; errorCode: string }): boolean {
  return result.httpStatus === 410 || DEAD_TOKEN_CODES.has(result.errorCode);
}

/** Nulls the token only where it still equals the failing one. */
export async function clearDeadApnsToken(
  supabase: SupabaseClientLike,
  installIdHash: string,
  failingToken: string,
): Promise<void> {
  await supabase
    .from('capture_devices')
    .update({ apns_token: null, apns_environment: null, token_updated_at: new Date().toISOString() })
    .eq('install_id_hash', installIdHash)
    .eq('apns_token', failingToken);
}

/** Idempotent: a second enqueue for the same notification is a no-op. */
export async function enqueueNotificationRetry(
  supabase: SupabaseClientLike,
  row: {
    notificationLogId: string;
    installIdHash: string;
    payloadId: string;
    maxAttempts: number;
    nextAttemptAt: string;
    lastErrorCode: string;
  },
): Promise<void> {
  await supabase.from('notification_retry_queue').upsert({
    notification_log_id: row.notificationLogId,
    install_id_hash: row.installIdHash,
    payload_id: row.payloadId,
    attempt_number: 1,
    max_attempts: row.maxAttempts,
    next_attempt_at: row.nextAttemptAt,
    last_error_code: row.lastErrorCode,
  }, { onConflict: 'notification_log_id', ignoreDuplicates: true });
}
