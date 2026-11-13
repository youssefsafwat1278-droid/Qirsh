import {
  corsHeaders,
  json,
  readBoundedJsonBody,
  readString,
  serviceClient,
  sha256Hex,
  verifyDevice,
} from '../_shared/capture_auth.ts';
import { sendCapturePush } from '../_shared/apns.ts';
import { clearDeadApnsToken, enqueueNotificationRetry, capturePushContent, transactionPushAlert, isDeadApnsToken } from '../_shared/capture_push.ts';
import { fingerprintTimeKeys } from '../_shared/capture_fingerprint.ts';
import { redactPii, redactSenderForAi, redactThirdPartyNames } from '../_shared/sms_redaction.ts';
import { markApnsLogFailed, markApnsLogSent } from '../_shared/notification_logs.ts';
import {
  isTransientApnsFailure,
  MAX_NOTIFICATION_RETRY_ATTEMPTS,
  nextRetryDelayMs,
} from '../_shared/notification_retry_policy.ts';
import { type FingerprintReservationStore, reserveCaptureFingerprint } from '../_shared/fingerprint_reservation.ts';
import { apiError, correlationId } from '../_shared/ai_endpoint.ts';
import { type ParsedCapture, parseSms } from './parse.ts';
import { AI_PRIMARY_MODE } from '../_shared/ai_primary.ts';

export type { ParsedCapture };

export type CaptureStatus = 'processed' | 'needs_review' | 'duplicate' | 'rejected';
type NotificationPayload = {
  localDelivery?: boolean;
  pushAlert?: { title: string; body: string };
  pushLanguage?: 'ar' | 'en';
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
};

const CAPTURE_RATE_LIMIT_PER_DAY = 300;
const LEASE_SECONDS = 60; // must stay well above the 3.5 s AI timeout (parse.ts)
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type ProcessIosSmsDependencies = {
  createServiceClient: typeof serviceClient;
  verifyDevice: typeof verifyDevice;
  waitUntil?: (work: Promise<unknown>) => void;
};

const defaultDependencies: ProcessIosSmsDependencies = {
  createServiceClient: serviceClient,
  verifyDevice,
};

type Rpc = (fn: string, args: Record<string, unknown>) => Promise<{ data: unknown; error: unknown }>;
type Json = Record<string, unknown>;
type PushInfo = { notification_log_id: string; apns_token: string; apns_environment: 'sandbox' | 'production' };

// Legacy (build-50) response keys; v2 adds `state`.
const LEGACY_CAPTURE_KEYS = [
  'payload_id',
  'status',
  'parsed',
  'notification',
  'created_at',
  'apns_push_sent_at',
  'notification_log_id',
] as const;

function captureForResponse(row: Json, v2: boolean): Json {
  const out: Json = {};
  for (const key of LEGACY_CAPTURE_KEYS) out[key] = row[key] ?? null;
  if (v2) out.state = row.state ?? null;
  return out;
}

// In-flight / not-yet-due: v2 gets 202; the legacy client treats any 2xx as a
// terminal acknowledgement (it would drop its queued item), so it gets 503.
function pending(v2: boolean, state: 'in_progress' | 'retryable', cid: string): Response {
  const body = { error: state === 'retryable' ? 'retry_later' : 'in_progress', state, correlation_id: cid };
  if (v2) return json(body, 202);
  return new Response(JSON.stringify(body), {
    status: 503,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Retry-After': '5' },
  });
}

function refusal(reason: string, cid: string): Response {
  if (reason === 'credential_revoked') return apiError('credential_revoked', { correlationId: cid });
  if (reason === 'consent_required' || reason === 'consent_revoked') {
    return apiError('consent_required', { correlationId: cid });
  }
  return json({ error: 'capture_owner_mismatch', correlation_id: cid }, 409);
}

export async function handleProcessIosSms(
  req: Request,
  dependencies: ProcessIosSmsDependencies = defaultDependencies,
): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);
  const cid = correlationId();

  // MALI-060n — gate ordering. Every gate below completes BEFORE any Gemini
  // (paid upstream) call, which lives in parseSms():
  //   1. body-size   → readBoundedJsonBody (does not trust Content-Length)
  //   2. schema      → schema_version 1 (legacy) or 2; owner_uid (any version) is owner-bound
  //   2b. length     → bounded SMS / sender / field lengths
  //   3. device auth → verifyDevice (device secret; revoked refused)
  //   4. claim       → capture_claim RPC: ownership + consent gate, replay,
  //                    owner/fingerprint conflicts and the lease, in ONE
  //                    FOR SHARE snapshot of the capture_devices row
  //   5. quota       → bumpRateLimit (replays above do not consume quota)
  //   6. AI dispatch → capture_ai_dispatch RPC (the AI linearization point),
  //                    only when the deterministic parse is unresolved
  //   7. finalize    → capture_finalize RPC: terminal fence + result + queued
  //                    notification row in one transaction; APNs only after it
  const MAX_BODY_BYTES = 16 * 1024; // one SMS + metadata; generous, bounded.
  const bodyResult = await readBoundedJsonBody(req, MAX_BODY_BYTES);
  if (!bodyResult.ok) {
    const status = bodyResult.reason === 'too_large' ? 413 : bodyResult.reason === 'unsupported_media_type' ? 415 : 400;
    return json({ error: bodyResult.reason }, status);
  }
  const body = bodyResult.body;

  // Strict schema version (reject unexpected/expensive modes early).
  const schemaVersion = typeof body.schema_version === 'number'
    ? body.schema_version
    : typeof body.schemaVersion === 'number'
    ? body.schemaVersion
    : 1;
  if (schemaVersion !== 1 && schemaVersion !== 2) return json({ error: 'unsupported_schema_version' }, 400);
  const v2 = schemaVersion === 2;

  const installId = readString(body, 'installId', 'install_id');
  const deviceSecret = readString(body, 'deviceSecret', 'device_secret');
  const payloadId = readString(body, 'payloadId', 'payload_id');
  const ownerUid = readString(body, 'ownerUid', 'owner_uid');
  const sanitizedText = reSanitize(readString(body, 'sanitizedText', 'sanitized_text', 'smsText', 'sms_text'));
  // Sanitized too. This was taken VERBATIM from the body and copied into
  // `parsed.rawMessage`, which is persisted for every capture — not only the
  // needs_review/rejected ones that store `sanitized_text`. Both shipping
  // clients sanitize before sending, so this was the missing defence-in-depth
  // layer rather than a live leak, but it is exactly the layer `07_SECURITY.md`
  // says must be preserved, and a wire probe confirmed the raw text came
  // straight back in the response.
  const rawText = reSanitize(readString(body, 'smsText', 'sms_text')) || sanitizedText;
  const sender = readString(body, 'sender', 'senderId', 'sender_id', 'senderName', 'sender_name');
  const rawReceivedAt = readString(body, 'receivedAt', 'received_at');
  const receivedAt = rawReceivedAt || new Date().toISOString();
  // Diagnostics only (the server cannot verify the client's local generation).
  const rawOwnerGeneration = body.ownerGeneration ?? body.owner_generation;
  const ownerGeneration = typeof rawOwnerGeneration === 'number' && Number.isSafeInteger(rawOwnerGeneration) &&
      rawOwnerGeneration >= 0
    ? rawOwnerGeneration
    : null;
  const tzOffsetMinutes = typeof body.tzOffsetMinutes === 'number' ? body.tzOffsetMinutes : null;
  const locale = readString(body, 'locale', 'deviceLocale', 'device_locale');
  const allowAi = body.allowAi === true || body.allow_ai === true;

  if (!payloadId || !sanitizedText) {
    return json({ error: 'missing_fields' }, 400);
  }
  // Bounded field lengths (defence in depth beyond the byte cap).
  const MAX_SMS_CHARS = 2000;
  const MAX_SENDER_CHARS = 64;
  const MAX_PAYLOAD_ID_CHARS = 200;
  if (sanitizedText.length > MAX_SMS_CHARS || rawText.length > MAX_SMS_CHARS) {
    return json({ error: 'payload_too_large' }, 413);
  }
  if (sender.length > MAX_SENDER_CHARS || payloadId.length > MAX_PAYLOAD_ID_CHARS) {
    return json({ error: 'invalid_fields' }, 400);
  }
  if (ownerUid && !UUID_RE.test(ownerUid)) return json({ error: 'invalid_fields' }, 400);

  const supabase = dependencies.createServiceClient();
  const auth = await dependencies.verifyDevice(supabase, installId, deviceSecret);
  if (!auth.ok) return json({ error: auth.error }, auth.status);
  const rpc: Rpc = (fn, args) => supabase.rpc(fn, args) as unknown as ReturnType<Rpc>;

  const rawFingerprint = await sha256Hex(`${auth.installIdHash}|${payloadId}|${sanitizedText}`);
  const aiPrimary = body.analysis_mode === AI_PRIMARY_MODE;
  const backgroundRequested = aiPrimary && body.backgroundAnalysis === true;
  const responseV2 = v2 || backgroundRequested;
  const claimRes = await rpc('capture_claim', {
    p_install_id_hash: auth.installIdHash,
    p_install_id: installId,
    p_payload_id: payloadId,
    p_raw_fingerprint: rawFingerprint,
    // Owner-bound on ANY schema version when owner_uid is present; ownerless (build 50) is
    // judged by capture_claim from the server's own install owner history (H1), never from
    // anything the client sends (no received_at).
    p_owner_uid: ownerUid || null,
    p_contract: v2 ? 2 : 1,
    p_lease_seconds: LEASE_SECONDS,
    p_owner_generation: ownerGeneration,
  });
  const claim = claimRes.data as Json | null;
  if (claimRes.error || !claim) return json({ error: 'store_failed' }, 500);

  switch (claim.outcome) {
    case 'denied':
      return refusal(String(claim.code), cid);
    case 'owner_conflict':
      return json({ error: 'capture_owner_conflict', correlation_id: cid }, 409);
    case 'id_conflict':
      return json({ error: 'capture_id_conflict', correlation_id: cid }, 409);
    case 'in_progress':
      return pending(responseV2, 'in_progress', cid);
    case 'replay':
      return await replayResponse(supabase, auth.installIdHash, payloadId, claim, responseV2, cid);
    case 'claimed':
      break;
    default:
      return json({ error: 'store_failed' }, 500);
  }
  const leaseToken = claim.lease_token as number;
  const aiAllowed = allowAi && claim.ai_allowed === true;
  const background = backgroundRequested && aiAllowed;

  const finalize = (args: {
    state: 'processed' | 'rejected' | 'retryable';
    status: string;
    parsed: ParsedCapture | null;
    notification: NotificationPayload | null;
    sanitized: string | null;
    failureReason: string | null;
    possibleDuplicate: boolean;
  }) =>
    rpc('capture_finalize', {
      p_install_id_hash: auth.installIdHash,
      p_install_id: installId,
      p_payload_id: payloadId,
      p_lease_token: leaseToken,
      p_state: args.state,
      p_status: args.status,
      p_parsed: args.parsed,
      p_notification: args.notification,
      p_sanitized_text: args.sanitized,
      p_failure_reason: args.failureReason,
      p_possible_duplicate: args.possibleDuplicate,
      p_validator_result: null,
    });

  const analyzeClaim = async (): Promise<Response> => {
    const limited = await bumpRateLimit(supabase, auth.installIdHash);
    if (limited) {
      await finalize({
        state: 'retryable',
        status: 'rejected',
        parsed: null,
        notification: null,
        sanitized: null,
        failureReason: 'rate_limited',
        possibleDuplicate: false,
      });
      return json({ error: 'rate_limit_exceeded' }, 429);
    }

    let dispatchDenied: string | null = null;
    // The client requested AI, but the claim may see a newer consent snapshot.
    // Preserve the reviewable capture without sending to AI or substituting a
    // deterministic transaction under the client's requested AI-only mode.
    const outcome = aiPrimary && allowAi && !aiAllowed
      ? { accepted: false, parsed: {
          parserSource: 'ai_pending' as const, rawMessage: sanitizedText, senderId: sender,
        } as ParsedCapture, aiInvoked: false, aiTransientFailure: false }
      : await parseSms({
      text: sanitizedText,
      rawText,
      sender,
      receivedAt,
      tzOffsetMinutes,
      locale,
      // Server-authoritative: never the raw caller flag.
      allowAi: aiAllowed,
      aiPrimary,
      beforeAi: async () => {
        const dispatch = await rpc('capture_ai_dispatch', {
          p_install_id_hash: auth.installIdHash,
          p_payload_id: payloadId,
          p_lease_token: leaseToken,
        });
        const data = dispatch.data as Json | null;
        if (!dispatch.error && data?.allowed === true) return true;
        dispatchDenied = String(data?.reason ?? 'dispatch_failed');
        return false;
      },
    });
    if (dispatchDenied && dispatchDenied !== 'analysis_exhausted') {
      console.log(JSON.stringify({ event: 'capture_ai_not_dispatched', reason: dispatchDenied }));
      if (dispatchDenied === 'lease_lost') return pending(responseV2, 'in_progress', cid);
      if (dispatchDenied === 'expired') return json({ error: 'capture_expired', state: 'expired', correlation_id: cid }, 409);
      return refusal(dispatchDenied === 'owner_changed' ? 'capture_owner_mismatch' : 'consent_required', cid);
    }
    const parsed = outcome.parsed;

    // Metadata only — never the raw SMS, sender, amount, merchant, secret, or body.
    console.log(JSON.stringify({
      event: 'sms_parse_result',
      hasAmount: parsed.amount != null,
      hasCurrency: parsed.currency != null,
      type: parsed.type ?? null,
      hasMerchant: parsed.merchant != null,
      confidence: parsed.confidence ?? null,
      parserSource: parsed.parserSource ?? null,
      aiRequested: allowAi,
      aiApplied: aiAllowed,
      aiInvoked: outcome.aiInvoked ?? false,
    }));

    // Binary outcome: parseSms decides accepted/rejected deterministically (AI
    // confidence never matters). New captures are never 'needs_review'; that
    // value stays in CaptureStatus only because legacy rows/clients still carry it.
    let status = (outcome.accepted && parsed.amount && parsed.currency ? 'processed' : 'rejected') as CaptureStatus;

    if (status !== 'rejected') {
      const duplicate = await detectDuplicate(supabase, auth.installIdHash, payloadId, parsed, ownerUid);
      if (duplicate) {
        status = 'duplicate';
        parsed.duplicateStatus = 'suspicious_duplicate';
        parsed.possibleDuplicateOfPayloadId = duplicate;
      } else {
        parsed.duplicateStatus = 'normal';
      }
    }

    const notification: NotificationPayload = aiPrimary && status === 'rejected'
      ? { title: '', body: '', type: 'received' }
      : buildNotification(status, parsed, sender, receivedAt, tzOffsetMinutes, locale);
    notification.pushLanguage = locale.toLowerCase().startsWith('ar') ? 'ar' : 'en';
    if (body.localNotification === true && !background) notification.localDelivery = true;
    if (body.notificationDetails === true && status === 'processed') {
      notification.pushAlert = transactionPushAlert(parsed, locale, { receivedAt, tzOffsetMinutes });
    }
    // Each primary analysis already made its bounded provider attempts. A
    // model answer the validator rejected is terminal and preserved for
    // review, with no push. A provider that could not be reached at all never
    // judged the capture: that stays retryable (bounded by capture_claim's
    // attempt cap and backoff), so a later client replay analyses it instead
    // of replaying a stored rejection forever.
    const transient = outcome.aiTransientFailure === true &&
      (!aiPrimary || (outcome as { aiProviderUnavailable?: boolean }).aiProviderUnavailable === true);
    const fin = await finalize({
      state: transient ? 'retryable' : status === 'rejected' ? 'rejected' : 'processed',
      status,
      parsed,
      notification: aiPrimary && status === 'rejected' ? null : notification,
      sanitized: status === 'rejected' ? sanitizedText : null,
      failureReason: dispatchDenied === 'analysis_exhausted'
        ? 'analysis_exhausted'
        : transient ? 'ai_unavailable' : status === 'rejected' ? 'not_parseable' : null,
      possibleDuplicate: status === 'duplicate',
    });
    const done = fin.data as Json | null;
    if (fin.error || !done) return json({ error: 'store_failed' }, 500);
    if (done.written !== true) {
      // Fenced out: nothing was stored and nothing may be sent.
      console.log(JSON.stringify({ event: 'capture_fenced', reason: done.reason ?? null }));
      if (done.reason === 'lease_lost') return pending(responseV2, 'in_progress', cid);
      if (done.reason === 'expired') return json({ error: 'capture_expired', state: 'expired', correlation_id: cid }, 409);
      return refusal(done.reason === 'owner_changed' ? 'capture_owner_mismatch' : 'consent_required', cid);
    }

    console.log(JSON.stringify({ event: 'capture_stored', status, retryable: transient }));
    if (status === 'processed' && ownerUid) {
      const secret = Deno.env.get('ENGAGEMENT_WORKER_SECRET');
      const url = Deno.env.get('SUPABASE_URL');
      const runtime = (globalThis as unknown as {
        EdgeRuntime?: { waitUntil: (work: Promise<unknown>) => void }
      }).EdgeRuntime;
      const wait = dependencies.waitUntil ?? runtime?.waitUntil.bind(runtime);
      if (secret && url && wait) {
        wait(fetch(`${url}/functions/v1/evaluate-budgets`, {
          method: 'POST', signal: AbortSignal.timeout(10000),
          headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' },
          body: JSON.stringify({ record: { user_id: ownerUid }, capturePayloadId: payloadId,
            locale, tzOffsetMinutes }),
        }).then((response) => {
          if (!response.ok) console.error('capture_budget_evaluation_failed', response.status);
        }).catch(() => console.error('capture_budget_evaluation_unavailable')));
      }
    }
    // I-1: the durable result is committed; only now may APNs be attempted.
    const push = done.push_allowed === true ? (done.push as PushInfo | null) : null;
    const pushSent = push
      ? await sendFinalizedPush(supabase, auth.installIdHash, payloadId, push, notification, parsed)
      : false;
    console.log(JSON.stringify({ event: 'process_ios_sms_complete', status, pushSent }));
    const row = done.row as Json;
    return json({
      capture: {
        ...captureForResponse(row, v2),
        // Content is returned to the requester; a retryable result stores none.
        parsed,
        notification: aiPrimary && status === 'rejected'
          ? notification : transient ? notification : row.notification,
        apns_push_sent_at: pushSent ? new Date().toISOString() : row.apns_push_sent_at ?? null,
      },
      pushSent,
      // v2 only (legacy shape unchanged): an APNs request was handed off for this capture
      // (now or earlier), so the App Intent must not also show a local banner.
      ...(responseV2 ? { state: done.state, push_attempted: push != null || Boolean(row.push_attempted_at) } : {}),
    });
  };
  if (background) {
    const runtime = (globalThis as typeof globalThis & {
      EdgeRuntime?: { waitUntil: (work: Promise<unknown>) => void }
    }).EdgeRuntime;
    const wait = dependencies.waitUntil ?? runtime?.waitUntil.bind(runtime);
    if (wait) {
      wait(analyzeClaim().catch(async () => {
        // A runtime/provider failure leaves the durable lease retryable. A new
        // claimant re-checks current owner/consent before doing any work.
        try {
          await finalize({ state: 'retryable', status: 'rejected', parsed: null,
            notification: null, sanitized: sanitizedText,
            failureReason: 'analysis_deferred', possibleDuplicate: false });
        } catch { /* The existing processing lease remains recoverable. */ }
      }));
      return pending(true, 'in_progress', cid);
    }
  }
  return analyzeClaim();
}

if (import.meta.main) Deno.serve((req) => handleProcessIosSms(req));

// Replay of an already-stored payload (the App Intent retries after a client
// timeout). The claim RPC already decided, under the same FOR SHARE snapshot,
// whether a push may be offered (`claim.push`): only one never handed off, because
// capture_queue_push hands a capture's push off at most once (no re-push, CAP-3).
async function replayResponse(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
  claim: Json,
  v2: boolean,
  cid: string,
): Promise<Response> {
  const row = (claim.row ?? {}) as Json;
  switch (row.state) {
    case 'consumed':
      return json({ error: 'already_consumed', state: 'consumed', correlation_id: cid }, 409);
    case 'expired':
      return json({ error: 'capture_expired', state: 'expired', correlation_id: cid }, 409);
    case 'retryable':
    case 'processing':
      return pending(v2, row.state === 'processing' ? 'in_progress' : 'retryable', cid);
  }
  let pushSent = Boolean(row.apns_push_sent_at);
  const notification = row.notification as NotificationPayload | null;
  const parsed = (row.parsed ?? {}) as ParsedCapture;
  const push = claim.push as PushInfo | null | undefined;
  if (!pushSent && push && notification?.title && notification?.body) {
    pushSent = await sendFinalizedPush(supabase, installIdHash, payloadId, push, notification, parsed);
  }
  console.log(JSON.stringify({ event: 'capture_idempotent_replay', pushSent }));
  return json({
    capture: {
      ...captureForResponse(row, v2),
      apns_push_sent_at: pushSent ? (row.apns_push_sent_at ?? new Date().toISOString()) : row.apns_push_sent_at ?? null,
    },
    idempotent: true,
    pushSent,
    ...(v2 ? { state: row.state, push_attempted: push != null || Boolean(row.push_attempted_at) } : {}),
  });
}

async function bumpRateLimit(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
): Promise<boolean> {
  // Atomic increment via RPC (migration 0028). Falls back to the legacy
  // read-then-upsert if the function is not deployed yet, so the endpoint
  // never breaks on migration-ordering during rollout.
  const atomic = await supabase.rpc('bump_capture_rate_limit', {
    p_install_id_hash: installIdHash,
    p_limit: CAPTURE_RATE_LIMIT_PER_DAY,
  });
  if (!atomic.error && typeof atomic.data === 'boolean') {
    return atomic.data;
  }
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('capture_rate_limits')
    .select('call_count')
    .eq('install_id_hash', installIdHash)
    .eq('date', today)
    .maybeSingle();
  const current = (data?.call_count ?? 0) as number;
  if (current >= CAPTURE_RATE_LIMIT_PER_DAY) return true;
  await supabase.from('capture_rate_limits').upsert({
    install_id_hash: installIdHash,
    date: today,
    call_count: current + 1,
  }, { onConflict: 'install_id_hash,date' });
  return false;
}

/**
 * The part of the duplicate fingerprint that does not depend on time. An
 * owner-bound capture is scoped to its account: the same bank message captured
 * by two accounts on one device is two transactions, not a duplicate, and one
 * account never learns what another captured. An ownerless (legacy) capture
 * keeps the device-wide fingerprint it always had.
 */
export function duplicateFingerprintBase(
  parsed: { amount?: number | null; currency?: string | null; merchant?: string | null;
    rawMessage?: string | null; last4?: string | null },
  ownerUid = '',
): string {
  const fields = [
    (parsed.amount ?? 0).toFixed(2),
    (parsed.currency ?? '').toUpperCase(),
    normalizeMerchant(parsed.merchant ?? parsed.rawMessage ?? ''),
    parsed.last4 ?? '',
  ];
  const owner = ownerUid.trim().toLowerCase();
  return (owner ? [`owner:${owner}`, ...fields] : fields).join('|');
}

async function detectDuplicate(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
  parsed: ParsedCapture,
  ownerUid = '',
): Promise<string | null> {
  if (!parsed.amount || !parsed.currency || !parsed.comparisonTimestamp) return null;
  const base = duplicateFingerprintBase(parsed, ownerUid);

  // Exact timestamps for both sources; stable payload IDs handle retries.
  const timeKeys = fingerprintTimeKeys(
    parsed.comparisonTimestamp,
    parsed.comparisonTimestampSource,
  );

  const fingerprints = await Promise.all(
    timeKeys.map((key) => sha256Hex(`${base}|${key}`)),
  );
  const store: FingerprintReservationStore = {
    async insert(row) {
      const { error } = await supabase.from('capture_fingerprints').insert(row);
      return { error };
    },
    async find(hash, keys) {
      const { data, error } = await supabase
        .from('capture_fingerprints')
        .select('payload_id,fingerprint')
        .eq('install_id_hash', hash)
        .in('fingerprint', keys);
      return { data, error };
    },
  };
  return reserveCaptureFingerprint(
    store,
    installIdHash,
    payloadId,
    fingerprints,
  );
}

export function buildNotification(
  status: CaptureStatus,
  parsed: ParsedCapture,
  sender: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
  locale = 'en',
): NotificationPayload {
  if (!locale.toLowerCase().startsWith('ar')) {
    const detail = transactionPushAlert(parsed, 'en', { receivedAt, tzOffsetMinutes });
    const summary = detail ? `${detail.title}\n${detail.body}\n` : '';
    if (status === 'duplicate') return {
      title: 'Similar transaction ⚠️', type: 'suspicious_duplicate',
      body: `${summary}Already recorded? Open Qirsh to review.`,
    };
    if (status === 'needs_review') return {
      title: 'Transaction needs review ⚠️', type: 'needs_review',
      body: `${summary}Open Qirsh to review and confirm.`,
    };
    if (status === 'processed') return {
      title: detail?.title ?? 'Transaction captured', type: 'new_transaction',
      body: detail?.body ?? 'Open Qirsh to view transaction',
    };
    return { title: 'Bank message captured', type: 'received',
      body: "Couldn't analyze this bank message. Paste it in Qirsh to add it manually." };
  }
  if (status === 'duplicate') {
    return {
      title: 'عملية مشابهة ⚠️',
      body: `${detailLines(parsed, receivedAt, tzOffsetMinutes)}\nموجودة مسبقاً؟ افتح قرش للمراجعة.`,
      type: 'suspicious_duplicate',
    };
  }
  if (status === 'needs_review') {
    return {
      title: 'عملية تحتاج مراجعة ⚠️',
      body: parsed.amount && parsed.currency
        ? `${detailLines(parsed, receivedAt, tzOffsetMinutes)}\nافتح قرش للمراجعة والتأكيد.`
        : 'افتح قرش لمراجعة الرسالة.',
      type: 'needs_review',
    };
  }
  if (status === 'processed') {
    return {
      title: `تم رصد ${typeTitle(parsed)} ${typeEmoji(parsed)}`,
      body: detailLines(parsed, receivedAt, tzOffsetMinutes),
      type: 'new_transaction',
    };
  }
  // rejected: لا يُنشأ أي عنصر داخل التطبيق (الـ relay يُحذف بعد الـ ack)،
  // فلا نَعِد المستخدم بمراجعة غير موجودة — نرشده للّصق اليدوي بدلاً منها.
  return {
    title: 'قِرش رصد رسالة بنك',
    // The alert travels through APNs and shows on the lock screen. An
    // alphanumeric sender is the bank's registered brand ("SNB") and is
    // shown; a phone number or numeric short code identifies no bank and may
    // be a person, so it falls back to the generic label.
    body: sender && redactSenderForAi(sender) === sender.trim()
      ? `رسالة من ${sender.trim()} لم نتمكن من تحليلها. الصقها يدوياً في قرش لإضافتها.`
      : 'رسالة بنكية لم نتمكن من تحليلها. الصقها يدوياً في قرش لإضافتها.',
    type: 'received',
  };
}

// قائمة التفاصيل — سطر لكل معلومة متاحة. الرصيد لا يظهر أبداً (شاشة القفل).
function detailLines(
  parsed: ParsedCapture,
  receivedAt: string,
  tzOffsetMinutes: number | null,
): string {
  const lines = [`المبلغ: ${formatAmount(parsed.amount ?? 0)} ${parsed.currency ?? ''}`.trim()];
  // The transaction's NATURE, on every template.
  //
  // `typeTitle` already exposes this, but only inside the `processed` title;
  // `duplicate` and `needs_review` hardcode their titles, so a real iPhone
  // showed "عملية مشابهة" with the amount, merchant, card and time and no hint
  // of whether money left or entered the account — data the parse already had.
  // Putting it in detailLines fixes all three templates at once instead of
  // patching two more titles.
  const nature = natureLabelAr(parsed);
  if (nature) lines.push(`النوع: ${nature}`);
  if (parsed.merchant) {
    lines.push(parsed.direction === 'credit' ? `المصدر: ${parsed.merchant}` : `التاجر: ${parsed.merchant}`);
  }
  if (parsed.last4) lines.push(`البطاقة: ****${parsed.last4}`);
  const time = timeLabel(parsed.occurredAt ?? receivedAt, tzOffsetMinutes);
  if (time) lines.push(`الوقت: ${time}`);
  const category = categoryLabelAr(parsed.category);
  if (category) lines.push(`التصنيف: ${category}`);
  return lines.join('\n');
}

/// The nature of the movement, from the same `direction`/`type` the parser
/// already produces. Direction wins because it is the grounded signal
/// (`detectDirection`); `type` only refines it.
///
/// Returns null when the parse could not classify, so an unknown movement stays
/// silent rather than being asserted as an expense.
function natureLabelAr(parsed: ParsedCapture): string | null {
  if (parsed.direction === 'credit' || parsed.type === 'income') return 'دخل';
  switch (parsed.type) {
    case 'transfer':
      return 'تحويل';
    case 'refund':
      return 'استرداد';
    case 'withdrawal':
      return 'سحب نقدي';
    case 'payment':
      return 'مصروف';
    default:
      return parsed.direction === 'debit' ? 'مصروف' : null;
  }
}

function typeTitle(parsed: ParsedCapture): string {
  if (parsed.direction === 'credit') return 'إيداع';
  switch (parsed.type) {
    case 'withdrawal':
      return 'سحب نقدي';
    case 'transfer':
      return 'تحويل';
    case 'refund':
      return 'استرداد';
    case 'payment':
      return 'عملية شراء';
    default:
      return 'عملية';
  }
}

function typeEmoji(parsed: ParsedCapture): string {
  if (parsed.direction === 'credit') return '💰';
  switch (parsed.type) {
    case 'withdrawal':
      return '🏧';
    case 'transfer':
      return '🔁';
    case 'refund':
      return '↩️';
    case 'payment':
      return '🛒';
    default:
      return '💳';
  }
}

// "اليوم 9:41 م" بتوقيت الجهاز (عبر tzOffsetMinutes). بدون offset لا نعرض وقتاً
// حتى لا نعرض توقيت UTC مضللاً.
function timeLabel(iso: string, tzOffsetMinutes: number | null): string | null {
  if (tzOffsetMinutes == null) return null;
  const utc = new Date(iso);
  if (Number.isNaN(utc.getTime())) return null;
  const local = new Date(utc.getTime() + tzOffsetMinutes * 60_000);
  const nowLocal = new Date(Date.now() + tzOffsetMinutes * 60_000);
  const hour24 = local.getUTCHours();
  const hour12 = hour24 % 12 === 0 ? 12 : hour24 % 12;
  const minute = String(local.getUTCMinutes()).padStart(2, '0');
  const suffix = hour24 < 12 ? 'ص' : 'م';
  const time = `${hour12}:${minute} ${suffix}`;
  const sameDay = local.getUTCFullYear() === nowLocal.getUTCFullYear() &&
    local.getUTCMonth() === nowLocal.getUTCMonth() &&
    local.getUTCDate() === nowLocal.getUTCDate();
  if (sameDay) return `اليوم ${time}`;
  const yesterday = new Date(nowLocal.getTime() - 86_400_000);
  const isYesterday = local.getUTCFullYear() === yesterday.getUTCFullYear() &&
    local.getUTCMonth() === yesterday.getUTCMonth() &&
    local.getUTCDate() === yesterday.getUTCDate();
  if (isYesterday) return `أمس ${time}`;
  return `${local.getUTCDate()}/${local.getUTCMonth() + 1} ${time}`;
}

// نفس تسميات lib/features/capture/services/capture_notification_content.dart.
function categoryLabelAr(key: string | undefined): string | null {
  switch (key) {
    case 'restaurants':
      return 'مطاعم 🍔';
    case 'cafes':
      return 'مقاهي ☕';
    case 'groceries':
      return 'بقالة 🛒';
    case 'transport':
      return 'مواصلات 🚗';
    case 'fuel':
      return 'وقود ⛽';
    case 'bills':
      return 'فواتير 📱';
    case 'shopping':
      return 'تسوق 🛍';
    case 'health':
      return 'صحة 🏥';
    case 'education':
      return 'تعليم 📚';
    case 'entertainment':
      return 'ترفيه 🎬';
    case 'subscriptions':
      return 'اشتراكات 📲';
    case 'transfers':
      return 'تحويل 💸';
    case 'cash':
      return 'كاش 💵';
    case 'travel':
      return 'سفر ✈️';
    case 'gifts':
      return 'هدايا 🎁';
    case 'kids':
      return 'أطفال 👶';
    case 'home':
      return 'منزل 🏠';
    case 'maintenance':
      return 'صيانة 🔧';
    case 'fitness':
      return 'رياضة 💪';
    case 'beauty':
      return 'جمال 💅';
    case 'charity':
      return 'خيرية 🤲';
    case 'pets':
      return 'حيوانات 🐾';
    case 'insurance':
      return 'تأمين 🛡️';
    case 'income':
      return 'دخل 💰';
    default:
      return null;
  }
}

// Sends the push for a result that finalize / claim already committed and fenced
// (the notification_logs row is queued in that same transaction). The alert text is
// generic (Q3), a dead token is cleared by CAS, and a retry is enqueued at most once.
async function sendFinalizedPush(
  supabase: ReturnType<typeof serviceClient>,
  installIdHash: string,
  payloadId: string,
  push: PushInfo,
  notification: NotificationPayload,
  parsed: ParsedCapture,
): Promise<boolean> {
  // The capturing intent owns the banner, including when Flutter is closed.
  // Persisted in notification JSON so idempotent replay cannot send a late
  // generic push or enqueue a retry over the detailed local notification.
  if (notification.localDelivery === true) {
    await markApnsLogFailed(supabase, push.notification_log_id, {
      errorCode: 'native_notification_owner',
      errorReason: 'Capture banner is delivered locally by the intent',
      retryCount: 0,
    });
    return false;
  }
  const notificationLogId = push.notification_log_id;
  const environment = push.apns_environment;
  console.log(JSON.stringify({
    event: 'notification_created',
    notificationLogId,
    channel: 'apns',
    notificationType: notification.type,
    platform: 'ios',
  }));

  const result = await sendCapturePush({
    token: push.apns_token,
    environment,
    payloadId,
    notificationLogId,
    ...capturePushContent(notification),
    notificationType: notification.type,
    smartInboxItemId: notification.type === 'needs_review' ||
        notification.type === 'suspicious_duplicate'
      ? payloadId
      : undefined,
    transactionId: typeof parsed.possibleDuplicateOfTransactionId === 'string'
      ? parsed.possibleDuplicateOfTransactionId
      : undefined,
  });
  if (result.ok) {
    console.log(JSON.stringify({
      event: 'apns_sent',
      environment,
    }));
    await supabase
      .from('processed_captures')
      .update({
        apns_push_sent_at: new Date().toISOString(),
        apns_push_error: null,
      })
      .eq('install_id_hash', installIdHash)
      .eq('payload_id', payloadId);
    await markApnsLogSent(supabase, notificationLogId, result.apnsId);
    console.log(JSON.stringify({
      event: 'notification_sent',
      notificationLogId,
      channel: 'apns',
      notificationType: notification.type,
    }));
    return true;
  }

  await supabase
    .from('processed_captures')
    .update({ apns_push_error: result.reason })
    .eq('install_id_hash', installIdHash)
    .eq('payload_id', payloadId);
  await markApnsLogFailed(supabase, notificationLogId, {
    errorCode: result.errorCode,
    errorReason: result.reason,
    retryCount: 0,
  });
  console.warn(JSON.stringify({
    event: 'notification_failed',
    notificationLogId,
    channel: 'apns',
    notificationType: notification.type,
    attempt: 1,
    errorCode: result.errorCode,
  }));

  if (isDeadApnsToken(result)) await clearDeadApnsToken(supabase, installIdHash, push.apns_token);

  if (isTransientApnsFailure(result.httpStatus, result.errorCode)) {
    await enqueueNotificationRetry(supabase, {
      notificationLogId,
      installIdHash,
      payloadId,
      maxAttempts: MAX_NOTIFICATION_RETRY_ATTEMPTS,
      nextAttemptAt: new Date(Date.now() + nextRetryDelayMs(1)).toISOString(),
      lastErrorCode: result.errorCode,
    });
    console.log(JSON.stringify({
      event: 'notification_retry_scheduled',
      notificationLogId,
      attempt: 1,
    }));
  } else {
    console.log(JSON.stringify({
      event: 'notification_retry_exhausted',
      notificationLogId,
      reason: 'permanent_failure',
      errorCode: result.errorCode,
    }));
  }
  return false;
}

function reSanitize(text: string): string {
  // This copy was missing the IBAN and OTP rules while forwarding the result
  // to Gemini, so a full IBAN reached the model. Delegated to the shared floor
  // rather than re-typed, so the three server copies cannot drift again.
  return redactThirdPartyNames(redactPii(text)).trim();
}

function normalizeMerchant(value: string): string {
  return value.toLowerCase().replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}

function formatAmount(value: number): string {
  return Number.isInteger(value) ? String(value) : value.toFixed(2);
}
