// Capture-push hygiene shared by process-ios-sms (first attempt) and
// process-notification-retries (retries). CAP-3, manifest §4.8 / Q3.
//
// * Old clients and hidden-content captures use a generic APNs alert. New
//   clients explicitly opt in to a bounded transaction summary.
//   SMS text, balances and full account/card numbers never enter that summary;
//   decision 3.12 allows the masked last four ("••1234") the parser identified.
// * A dead token is cleared by compare-and-swap, so a token the app re-registered in
//   the meantime is never wiped.
// * A retry is enqueued at most once per notification (UNIQUE(notification_log_id)).

import { serviceClient } from './capture_auth.ts';

type SupabaseClientLike = ReturnType<typeof serviceClient>;

// Q3 wording, verbatim from the manifest. Title is omitted (iOS shows the app name).
export const GENERIC_CAPTURE_PUSH = { title: '', body: 'New transaction captured' } as const;

// Decision 3.12: what the server knows about a capture when it pushes. The
// server never records anything in the user's ledger — the device does that
// when it imports the row, and may still send it to review (V1-086/088) — so
// no server push says "recorded". Wording mirrors the native banners
// (app/ios/BankMessageShortcuts/BankMessageShortcuts.swift `captureBanner`).
//   queued    — analysed; Qirsh checks it before adding it
//   review    — needs the user's review before it is recorded
//   duplicate — looks like one already recorded; needs review
//   declined  — the message says the operation was declined or failed: not recorded
//   excluded  — no completed movement (pending, scheduled, a notice …): not recorded
//   unread    — not understood here; kept for the user to check: not recorded yet
export type CaptureOutcome = 'queued' | 'review' | 'duplicate' | 'declined' | 'excluded' | 'unread';

const STATUS_LINES: Record<CaptureOutcome, [string, string]> = {
  queued: ['Not recorded yet: Qirsh checks it before adding it.',
    'لم تُسجَّل بعد: يتحقق منها قِرش قبل إضافتها.'],
  review: ['Needs your review in Qirsh before it is recorded.', 'تحتاج مراجعتك في قِرش قبل تسجيلها.'],
  duplicate: ['Possible duplicate: needs your review in Qirsh before it is recorded.',
    'قد تكون مكررة: تحتاج مراجعتك في قِرش قبل تسجيلها.'],
  declined: ['Not recorded: the message says it was declined or failed.',
    'لم تُسجَّل: تفيد الرسالة بأن العملية مرفوضة أو لم تتم.'],
  excluded: ['Not recorded: no completed transaction in this message (for example pending or a notice).',
    'لم تُسجَّل: لا توجد عملية مكتملة في هذه الرسالة (مثل عملية معلّقة أو إشعار).'],
  unread: ['Not recorded yet: open Qirsh to check this bank message.',
    'لم تُسجَّل بعد: افتح قِرش للتحقق من رسالة البنك هذه.'],
};

export function captureStatusLine(outcome: CaptureOutcome, ar: boolean): string {
  return STATUS_LINES[outcome][ar ? 1 : 0];
}

/** Generic (no-detail) alert for a stored notification, by outcome then by type. */
function genericCapturePush(n: { type?: unknown; captureOutcome?: unknown } | null, ar: boolean) {
  const outcome = typeof n?.captureOutcome === 'string' && n.captureOutcome in STATUS_LINES
    ? n.captureOutcome as CaptureOutcome
    : n?.type === 'suspicious_duplicate' ? 'duplicate'
    : n?.type === 'needs_review' ? 'review'
    : n?.type === 'received' ? 'unread' : null;
  // A plain new transaction keeps the manifest Q3 wording (it claims no record).
  if (outcome == null || outcome === 'queued') {
    return ar ? { title: '', body: 'تم رصد عملية جديدة' } : GENERIC_CAPTURE_PUSH;
  }
  return { title: '', body: captureStatusLine(outcome, ar) };
}

/** Old captures without an explicit push summary retain their privacy contract. */
export function capturePushContent(notification: unknown): { title: string; body: string } {
  const n = notification as {
    pushAlert?: { title?: unknown; body?: unknown }; pushLanguage?: string;
    type?: unknown; captureOutcome?: unknown;
  } | null;
  const alert = n?.pushAlert;
  return alert && typeof alert.title === 'string' && typeof alert.body === 'string' &&
      alert.title.length > 0 && alert.title.length <= 120 && alert.body.length > 0 && alert.body.length <= 600
    ? { title: alert.title, body: alert.body }
    : genericCapturePush(n, n?.pushLanguage === 'ar');
}

/// Exactly four ASCII digits, or nothing: never a longer card/account number.
export function safeLast4(value: unknown): string | undefined {
  return typeof value === 'string' && /^[0-9]{4}$/.test(value) ? value : undefined;
}

export function transactionPushAlert(
  parsed: { amount?: number | null; currency?: string | null; merchant?: string | null;
    direction?: string | null; type?: string | null; last4?: string | null;
    occurredAt?: string; comparisonTimestamp?: string; rawMessage?: string;
    counterpartyKind?: string | null }, locale: string,
  context: { tzOffsetMinutes?: number | null; receivedAt?: string;
    /// What the server knows (3.12); default: analysed, not yet recorded.
    outcome?: CaptureOutcome;
    /// A category the user decided (their saved merchant rule). A model's or
    /// parser's category is a proposal and is never shown as final.
    finalCategory?: string | null;
    /// Masked last four of the card/account the parser identified (decision
    /// 3.12: shown when details are shown; never a longer number).
    includeLast4?: boolean } = {},
): { title: string; body: string } | undefined {
  if (typeof parsed.amount !== 'number' || !Number.isFinite(parsed.amount) || parsed.amount <= 0 ||
      !/^[A-Z]{3}$/.test(parsed.currency ?? '')) return undefined;
  const ar = locale.toLowerCase().startsWith('ar');
  // Gemini-first phase 1: a transfer to or from a person never names them.
  const friend = parsed.type === 'transfer' && parsed.counterpartyKind === 'person' &&
    (parsed.direction === 'credit' || parsed.direction === 'debit');
  const title = parsed.type === 'refund' ? (ar ? 'استرداد' : 'Refund received')
    : friend ? (parsed.direction === 'credit'
      ? (ar ? 'تحويل من صديق' : 'Transfer from a friend') : (ar ? 'تحويل لصديق' : 'Transfer to a friend'))
    : parsed.type === 'transfer' ? (parsed.direction === 'credit'
      ? (ar ? 'تحويل وارد' : 'Transfer received') : parsed.direction === 'debit'
      ? (ar ? 'تحويل صادر' : 'Transfer sent') : (ar ? 'تحويل' : 'Transfer'))
    : parsed.type === 'withdrawal' ? (ar ? 'سحب نقدي' : 'Cash withdrawal')
    : parsed.direction === 'credit' || parsed.type === 'income' ? (ar ? 'إيداع وارد' : 'Deposit received')
    : parsed.type === 'payment' ? (ar ? 'عملية شراء' : 'Purchase')
    : (ar ? 'معاملة جديدة' : 'New transaction');
  const amount = parsed.amount.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  // A run of five or more digits is never a merchant name (a card, IBAN or
  // account number that slipped through): it is masked, never shown.
  const merchant = parsed.merchant?.replace(/[\r\n\t]/g, ' ')
    .replace(/[0-9\u0660-\u0669\u06F0-\u06F9]{5,}/g, '•••').trim().slice(0, 80);
  // Only the network name leaves this function, never the SMS or its identifiers.
  const network = parsed.type === 'transfer' && /\b(?:ipn|instapay)\b/i.test(parsed.rawMessage ?? '')
    ? (ar ? 'عبر InstaPay' : 'Via InstaPay') : undefined;
  const category = PUSH_CATEGORIES[context.finalCategory ?? '']?.[ar ? 1 : 0];
  const last4 = context.includeLast4 ? safeLast4(parsed.last4) : undefined;
  const card = last4 ? (ar ? `البطاقة/الحساب: ••${last4}` : `Card/account ••${last4}`) : undefined;
  const when = pushLocalTime(parsed.occurredAt ?? parsed.comparisonTimestamp ?? context.receivedAt,
    context.tzOffsetMinutes, ar);
  const details = [category, when].filter(Boolean).join(' · ');
  return { title: `${title} · ${amount} ${parsed.currency}`,
    body: [network ?? merchant, card, details, captureStatusLine(context.outcome ?? 'queued', ar)]
      .filter(Boolean).join('\n') };
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
