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
import {
  analysisOutcomeAlert,
  analysisStateOf,
  type AnalysisState,
  type CaptureOutcome,
  captureStatusLine,
  clearDeadApnsToken,
  enqueueNotificationRetry,
  capturePushContent,
  transactionPushAlert,
  isDeadApnsToken,
  safeLast4,
  withPushDelivery,
} from '../_shared/capture_push.ts';
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
import { isDeclinedText, messageMeaning, type ParseOutcome, type ParsedCapture, parseSms } from './parse.ts';
import { dispositionOf, MAX_TEXT_LENGTH } from './message_meaning.ts';
import { gatedMeaning, meaningRejectionOf } from './meaning_gate.ts';
import { AI_PRIMARY_MODE } from '../_shared/ai_primary.ts';
import { UNDERSTANDING_SYSTEM_VERSION } from '../_shared/ai_understanding.ts';
import { reserveAiBudget } from '../_shared/ai_budget_gate.ts';
import { meaningReasonCode } from '../_shared/analysis_reasons.ts';
import {
  analysisMemoryReader,
  bumpAnalysisCounter,
  dropShape,
  merchantCodeEligible,
  merchantCodeKey,
  observeMerchant,
  observeShape,
} from '../_shared/sms_shape_memory.ts';
import { lookUpMerchantOnce } from '../_shared/merchant_lookup.ts';

export type { ParsedCapture };

export type CaptureStatus = 'processed' | 'needs_review' | 'duplicate' | 'rejected';
type NotificationPayload = {
  localDelivery?: boolean;
  pushAlert?: { title: string; body: string };
  pushLanguage?: 'ar' | 'en';
  title: string;
  body: string;
  type: 'new_transaction' | 'needs_review' | 'suspicious_duplicate' | 'received';
  /// 3.12: what the server knows about the capture (additive; build 147
  /// ignores it). Picks the wording of a push sent without details.
  captureOutcome?: CaptureOutcome;
  /// Gemini-first phase 2 (AI-primary path, additive): the visible outcome
  /// this push states, its reason code, and (after the push attempt) whether
  /// APNs took it. The importing device notifies itself only when the push
  /// did not go out or its own outcome differs.
  analysisState?: AnalysisState;
  reasonCode?: string | null;
  pushed?: boolean;
};

/// A parse plus the category of the owner's saved merchant rule, the only
/// category the server may present as final (3.12, 4.5).
type ShownCapture = ParsedCapture & { ruleCategory?: string };

const CAPTURE_RATE_LIMIT_PER_DAY = 300;
const LEASE_SECONDS = 60; // above the AI time per message: 3.5 s (rule path, parse.ts), AI_TOTAL_BUDGET_MS 38 s (AI-primary)
// Waits before re-trying capture_ai_dispatch after a transient 55P03 (0.75 s in all).
const DISPATCH_BUSY_RETRY_MS = [250, 500];
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

type Rpc = (fn: string, args: Record<string, unknown>) =>
  Promise<{ data: unknown; error: { code?: string } | null }>;
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
  // LEN-1: the device decides "over length" on the message as received, in
  // UTF-16 code units (Dart and JS `String.length`), before redaction shortens
  // it. A client that sends that length lets the server use the same measure.
  // It can only move a capture to review, never to recorded.
  const rawTextLength = body.textLength ?? body.text_length;
  const deviceTextLength = typeof rawTextLength === 'number' && Number.isInteger(rawTextLength) && rawTextLength >= 0
    ? rawTextLength
    : null;

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
  // Gemini-first phase 3: a device may hold smart-analysis consent without
  // Cloud consent (20261120120000). Such a capture is analysed, but nothing of
  // the account's Cloud data (synced merchant rules, server budgets) is read or
  // acted on for it. A server reply without the field is the pre-phase-3 claim,
  // which admitted Cloud devices only.
  const cloudAllowed = claim.cloud_allowed !== false;
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

    const memoryReader = analysisMemoryReader(supabase);
    let dispatchDenied: string | null = null;
    // V1-022: the global AI budget refused a provider request (no call made).
    let budgetRefused = false;
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
      // Gemini-first phase 4: the shared, non-personal shape and merchant
      // memory (no account data: read for Cloud and smart-analysis-only alike).
      memory: aiPrimary ? memoryReader : undefined,
      beforeAi: async () => {
        const dispatchOnce = () => rpc('capture_ai_dispatch', {
          p_install_id_hash: auth.installIdHash,
          p_payload_id: payloadId,
          p_lease_token: leaseToken,
        });
        // A 55P03 is a momentary lock held by another request of the same
        // account (e.g. sync-captures): retried briefly before the capture is
        // released as account_busy. Each call re-checks consent, ownership,
        // the lease and the quota; nothing is reserved until one is allowed.
        let dispatch = await dispatchOnce();
        for (const delayMs of DISPATCH_BUSY_RETRY_MS) {
          if (dispatch.error?.code !== '55P03') break;
          await new Promise((resolve) => setTimeout(resolve, delayMs));
          dispatch = await dispatchOnce();
        }
        const data = dispatch.data as Json | null;
        if (!dispatch.error && data?.allowed === true) {
          // After consent, ownership and the quota (capture_claim, bumpRateLimit,
          // capture_ai_dispatch), immediately before each provider request.
          if ((await reserveAiBudget(supabase, 'gemini')).allowed) return true;
          budgetRefused = true;
          return false;
        }
        dispatchDenied = dispatch.error?.code === '55P03'
          ? 'account_busy'
          : String(data?.reason ?? 'dispatch_failed');
        return false;
      },
    });
    if (dispatchDenied && dispatchDenied !== 'analysis_exhausted') {
      console.log(JSON.stringify({ event: 'capture_ai_not_dispatched', reason: dispatchDenied }));
      if (dispatchDenied === 'account_busy') {
        // Postgres rolled back dispatch before AI started. Release the claim
        // as retryable so replay can recheck consent and authorize a new try.
        const released = await finalize({
          state: 'retryable',
          status: 'rejected',
          parsed: null,
          notification: null,
          sanitized: null,
          failureReason: 'account_busy',
          possibleDuplicate: false,
        });
        const saved = released.data as Json | null;
        if (saved?.reason === 'owner_changed') return refusal('capture_owner_mismatch', cid);
        if (saved?.reason === 'consent_revoked') return refusal('consent_required', cid);
        if (saved?.reason === 'expired') return json({ error: 'capture_expired', state: 'expired', correlation_id: cid }, 409);
        // On another busy response or a stale lease, the next claimant can
        // recover the existing lease. No analysis or push has been handed off.
        return pending(responseV2, saved?.written === true ? 'retryable' : 'in_progress', cid);
      }
      if (dispatchDenied === 'lease_lost') return pending(responseV2, 'in_progress', cid);
      if (dispatchDenied === 'expired') return json({ error: 'capture_expired', state: 'expired', correlation_id: cid }, 409);
      return refusal(dispatchDenied === 'owner_changed' ? 'capture_owner_mismatch' : 'consent_required', cid);
    }
    // V1-058: which model and which system instruction produced an AI
    // result travel with the stored parse (processed_captures.parsed is
    // jsonb, so no migration). Never on a parse no AI request was made for.
    const parsed: ParsedCapture & { aiModel?: string; aiSystemVersion?: string; reviewReason?: string } =
      outcome.aiInvoked
      ? {
        ...outcome.parsed,
        aiModel: Deno.env.get('GEMINI_SMS_MODEL') ?? 'gemini-3.8-flash',
        aiSystemVersion: UNDERSTANDING_SYSTEM_VERSION,
      }
      : outcome.parsed;

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
    // Closure round (parser meaning, owner brief 4.1 / §5), both analysis
    // modes: a clear notice, an OTP or a review kind (not completed, an ATM
    // cash deposit, own accounts, several movements) is never processed money
    // because a model (or any later step) answered with a transaction. It is
    // kept for review with the reason; the device applies the same meaning.
    let meaning = gatedMeaning(sanitizedText, outcome.meaning ?? messageMeaning(sanitizedText), parsed.amount ?? null);
    if (
      deviceTextLength !== null && deviceTextLength > MAX_TEXT_LENGTH && meaning.kind !== 'otp' &&
      meaning.disposition === 'record'
    ) {
      meaning = { ...meaning, kind: 'uncertain', disposition: dispositionOf('uncertain'), reason: 'over_length' };
    }
    // Follow-up 15 (VAL-1): the single rule decides (not-completed first);
    // nothing is processed without passing it.
    if (status === 'processed' && meaningRejectionOf(sanitizedText, parsed.amount ?? null, meaning) != null) {
      status = 'rejected';
      parsed.reviewReason = meaning.reason;
    }
    // Gemini-first phase 1 (additive field): every kept-for-review capture
    // with a known reason carries its closed code; the app words it.
    if (status === 'rejected' && parsed.reasonCode == null && parsed.reviewReason) {
      parsed.reasonCode = meaningReasonCode(parsed.reviewReason);
    }

    if (status !== 'rejected') {
      const duplicate = await detectDuplicate(supabase, auth.installIdHash, payloadId, parsed, ownerUid);
      if (duplicate) {
        status = 'duplicate';
        parsed.reasonCode = 'duplicate';
        parsed.duplicateStatus = 'suspicious_duplicate';
        parsed.possibleDuplicateOfPayloadId = duplicate;
      } else {
        parsed.duplicateStatus = 'normal';
      }
    }

    // Gemini-first phase 4: the merchant code's clean display name, when the
    // shared memory has one (looked up once, in the background, after an
    // earlier message). The code itself stays in `merchant`.
    if (aiPrimary && status !== 'rejected' && parsed.counterpartyKind === 'merchant' &&
      merchantCodeEligible(parsed.merchant)) {
      const known = await memoryReader.merchant(merchantCodeKey(parsed.merchant));
      if (known?.displayName) parsed.merchantDisplay = known.displayName;
    }

    // The app files this capture under the user's own merchant rule
    // (learnedRuleCategoryFor), so the alert says the same. Display only: the
    // stored parse is unchanged and the device still applies the rule itself.
    const ruled: ShownCapture = status !== 'rejected' && ownerUid && cloudAllowed
      ? await withUserMerchantRule(supabase, ownerUid, parsed)
      : parsed;
    const shown: ShownCapture = parsed.merchantDisplay ? { ...ruled, merchant: parsed.merchantDisplay } : ruled;
    // Each primary analysis already made its bounded provider attempts. A
    // model answer the validator rejected is terminal and preserved for
    // review, with no push. A provider that could not be reached at all never
    // judged the capture: that stays retryable (bounded by capture_claim's
    // attempt cap and backoff), so a later client replay analyses it instead
    // of replaying a stored rejection forever.
    // A budget refusal is handled like a provider outage: the capture was never
    // judged, so it stays a retryable pending item for review — never dropped,
    // never saved from an unvalidated local reading.
    const transient = budgetRefused || (outcome.aiTransientFailure === true &&
      (!aiPrimary || (outcome as { aiProviderUnavailable?: boolean }).aiProviderUnavailable === true));
    const captureOutcome = outcomeOf(status, sanitizedText, { ...outcome, meaning });
    // Gemini-first phase 2: on the AI-primary path the push states the
    // outcome (saved / not added / needs your confirmation); a clearly
    // non-financial message gets none (as every rejected capture had before).
    // A capture the provider never judged is "awaiting analysis" (no push).
    const analysisState = aiPrimary && !transient ? analysisStateOf(status, parsed.reasonCode) : null;
    const notification: NotificationPayload = aiPrimary
      ? analysisNotification(analysisState, status, shown, locale, parsed.reasonCode ?? null)
      : buildNotification(status, shown, sender, receivedAt, tzOffsetMinutes, locale, captureOutcome);
    notification.pushLanguage = locale.toLowerCase().startsWith('ar') ? 'ar' : 'en';
    if (body.localNotification === true && !background) notification.localDelivery = true;
    if (analysisState) {
      // The detailed alert only when the user did not hide details; the
      // stored state words the generic one (capturePushContent).
      if (body.notificationDetails === true) {
        notification.pushAlert = { title: notification.title, body: notification.body };
      }
    } else if (body.notificationDetails === true && notification.title) {
      notification.pushAlert = transactionPushAlert(shown, locale,
        { receivedAt, tzOffsetMinutes, outcome: captureOutcome, finalCategory: shown.ruleCategory,
          includeLast4: true });
    }
    const fin = await finalize({
      state: transient ? 'retryable' : status === 'rejected' ? 'rejected' : 'processed',
      status,
      parsed,
      notification: aiPrimary && !analysisState ? null : notification,
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
    if (aiPrimary) {
      // Gemini-first phase 4: memory writes and counts after the record, never
      // delaying or failing it. Only a recorded reading teaches the memory.
      const recorded = status === 'processed' || status === 'duplicate';
      const memoryWork = rememberAnalysis(supabase, {
        outcome, recorded, parsed, installIdHash: auth.installIdHash,
        // A Places lookup is cloud processing, as in enrich-merchant.
        lookUp: cloudAllowed,
      }).catch(() => undefined);
      const runtime = (globalThis as unknown as {
        EdgeRuntime?: { waitUntil: (work: Promise<unknown>) => void }
      }).EdgeRuntime;
      runtime?.waitUntil(memoryWork);
    }
    if (status === 'processed' && ownerUid && cloudAllowed) {
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
    if (done.push_allowed === true && push == null && analysisState) {
      // No push was handed off (no APNs token on this install): the device
      // notifies on import.
      await supabase.from('processed_captures').update(withPushDelivery(notification, false))
        .eq('install_id_hash', auth.installIdHash).eq('payload_id', payloadId);
    }
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

/**
 * Gemini-first phase 4: what one AI-primary analysis teaches the shared memory
 * (sms_shape_memory.ts) and its daily counts. Best effort throughout.
 */
async function rememberAnalysis(
  supabase: ReturnType<typeof serviceClient>,
  input: { outcome: ParseOutcome; recorded: boolean; parsed: ParsedCapture; installIdHash: string; lookUp: boolean },
): Promise<void> {
  const effects = input.outcome.memory ?? {};
  if (input.outcome.aiInvoked) await bumpAnalysisCounter(supabase, 'model_read');
  if (effects.templateHit) await bumpAnalysisCounter(supabase, 'template_hit');
  if (effects.checked) await bumpAnalysisCounter(supabase, 'template_check');
  if (effects.drop) {
    await dropShape(supabase, effects.drop);
    await bumpAnalysisCounter(supabase, 'template_drop');
  }
  if (!input.recorded) return;
  if (effects.merchant) await observeMerchant(supabase, effects.merchant.codeKey, effects.merchant.category);
  if (effects.shape && !effects.drop) {
    const state = await observeShape(supabase, { ...effects.shape, installIdHash: input.installIdHash });
    if (state === 'activated') await bumpAnalysisCounter(supabase, 'template_activated');
  }
  const code = input.parsed.merchant;
  if (input.lookUp && !input.parsed.merchantDisplay && input.parsed.counterpartyKind === 'merchant' &&
    merchantCodeEligible(code)) {
    await lookUpMerchantOnce(supabase, {
      codeKey: merchantCodeKey(code), code, currency: input.parsed.currency,
      apiKey: Deno.env.get('GOOGLE_MAPS_API_KEY') ?? '',
    });
  }
}

/// The device's merchant key (AppDatabase.normalizeMerchant), which is also
/// the shape user_merchant_rules.merchant_key is constrained to.
export function merchantRuleKey(raw: string): string {
  return raw.toUpperCase().replace(/[0-9]/g, '').replace(/\s+/g, ' ').trim();
}

/// `parsed` with the category of the owner's synced merchant rule, if any.
/// Only Cloud users sync rules, so for everyone else this is a no-op. Any read
/// failure keeps the server's own reading: a wrong label beats a lost alert.
async function withUserMerchantRule(
  supabase: ReturnType<typeof serviceClient>,
  ownerUid: string,
  parsed: ParsedCapture,
): Promise<ShownCapture> {
  // The code the message names first, then its display name (phase 4: the
  // app may file the transaction under the display name).
  const keys = [...new Set([parsed.merchant, parsed.merchantDisplay]
    .map((m) => (m ? merchantRuleKey(m) : '')).filter((k) => k))];
  try {
    let category: string | null = null;
    for (const key of keys) {
      const { data, error } = await supabase
        .from('user_merchant_rules')
        .select('category_key')
        .eq('user_id', ownerUid)
        .eq('merchant_key', key)
        .is('deleted_at', null)
        .maybeSingle();
      category = !error && typeof data?.category_key === 'string' ? data.category_key : null;
      if (category) break;
    }
    if (!category) return parsed;
    // The app names the cash category "سحب نقدي"; the title says so too.
    const type = category === 'cash' && parsed.direction !== 'credit' ? 'withdrawal' : parsed.type;
    return { ...parsed, category, type, ruleCategory: category };
  } catch {
    return parsed;
  }
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

/// 3.12: what the server can truthfully say about a capture it is about to
/// notify. Nothing here is "recorded": the device records on import.
export function outcomeOf(
  status: CaptureStatus,
  text: string,
  outcome: Pick<ParseOutcome, 'parsed' | 'meaning'>,
): CaptureOutcome {
  if (status === 'processed') return 'queued';
  if (status === 'duplicate') return 'duplicate';
  if (status === 'needs_review') return 'review';
  if (isDeclinedText(text)) return 'declined';
  const meaning = outcome.meaning ?? messageMeaning(text);
  if (outcome.parsed.parserSource === 'ai_ignored' || meaning.kind === 'not_completed' ||
      meaning.kind === 'no_movement_notice' || meaning.kind === 'otp') return 'excluded';
  // A cash deposit, own-account move or several movements: kept for review.
  if (meaning.disposition === 'review') return 'review';
  // Not understood by the server (the V1-088 class): the matching device
  // build keeps it for review, so it is "not recorded yet", never "recorded".
  return 'unread';
}

const DEFAULT_OUTCOME: Record<CaptureStatus, CaptureOutcome> = {
  processed: 'queued', duplicate: 'duplicate', needs_review: 'review', rejected: 'unread',
};

/// An alphanumeric sender is the bank's registered brand ("SNB") and may be
/// shown; a phone number or numeric short code identifies no bank and may be
/// a person, so it is never shown (the alert reaches the lock screen).
function senderBrand(sender: string): string | null {
  return sender && redactSenderForAi(sender) === sender.trim() ? sender.trim() : null;
}

export function buildNotification(
  status: CaptureStatus,
  parsed: ShownCapture,
  sender: string,
  receivedAt: string,
  tzOffsetMinutes: number | null,
  locale = 'en',
  captureOutcome: CaptureOutcome = DEFAULT_OUTCOME[status],
): NotificationPayload {
  const ar = locale.toLowerCase().startsWith('ar');
  const statusLine = captureStatusLine(captureOutcome, ar);
  const brand = senderBrand(sender);
  if (!ar) {
    const detail = transactionPushAlert(parsed, 'en',
      { receivedAt, tzOffsetMinutes, outcome: captureOutcome, finalCategory: parsed.ruleCategory, includeLast4: true });
    const summary = detail ? `${detail.title}\n${detail.body}` : statusLine;
    if (status === 'duplicate') {
      return { title: 'Similar transaction ⚠️', type: 'suspicious_duplicate', body: summary, captureOutcome };
    }
    if (status === 'needs_review') {
      return { title: 'Transaction needs review ⚠️', type: 'needs_review', body: summary, captureOutcome };
    }
    if (status === 'processed') {
      return { title: detail?.title ?? 'Bank message received', type: 'new_transaction',
        body: detail?.body ?? statusLine, captureOutcome };
    }
    return {
      title: captureOutcome === 'unread' ? 'Bank message received' : 'Bank message not recorded',
      type: 'received',
      body: [brand ? `Message from ${brand}.` : null, detail ? `${detail.title}\n${detail.body}` : statusLine]
        .filter(Boolean).join('\n'),
      captureOutcome,
    };
  }
  const details = parsed.amount && parsed.currency ? detailLines(parsed, receivedAt, tzOffsetMinutes) : null;
  const body = [details, statusLine].filter(Boolean).join('\n');
  if (status === 'duplicate') {
    return { title: 'عملية مشابهة ⚠️', body, type: 'suspicious_duplicate', captureOutcome };
  }
  if (status === 'needs_review') {
    return { title: 'عملية تحتاج مراجعة ⚠️', body, type: 'needs_review', captureOutcome };
  }
  if (status === 'processed') {
    return { title: `تم رصد ${typeTitle(parsed)} ${typeEmoji(parsed)}`, body, type: 'new_transaction', captureOutcome };
  }
  return {
    title: captureOutcome === 'unread' ? 'قِرش رصد رسالة بنك' : 'رسالة بنك لم تُسجَّل',
    body: [brand ? `رسالة من ${brand}.` : null, body].filter(Boolean).join('\n'),
    type: 'received',
    captureOutcome,
  };
}

/// Gemini-first phase 2 (AI-primary path): the one push of an analysed
/// capture, stating its outcome; an empty title (no push queued) when it gets
/// none. The tap routes as before: a saved one as a new transaction, a
/// duplicate as one, anything to confirm as a review.
export function analysisNotification(
  state: AnalysisState | null,
  status: CaptureStatus,
  parsed: ShownCapture,
  locale: string,
  reasonCode: string | null,
): NotificationPayload {
  if (!state) return { title: '', body: '', type: 'received' };
  // The category the app files it under: the owner's merchant rule, else the
  // analysed category (capture_sync_service: learned rule ?? parsed.category).
  const alert = analysisOutcomeAlert(parsed, locale,
    { state, reasonCode, finalCategory: parsed.ruleCategory ?? parsed.category });
  return {
    ...alert,
    type: state === 'saved' ? 'new_transaction'
      : status === 'duplicate' || reasonCode === 'duplicate' ? 'suspicious_duplicate'
      : state === 'needs_confirmation' ? 'needs_review' : 'received',
    analysisState: state,
    reasonCode,
  };
}

// قائمة التفاصيل — سطر لكل معلومة متاحة. الرصيد لا يظهر أبداً (شاشة القفل).
function detailLines(
  parsed: ShownCapture,
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
    const merchant = parsed.merchant.replace(/[\r\n\t]/g, ' ').trim().slice(0, 80);
    lines.push(parsed.direction === 'credit' ? `المصدر: ${merchant}` : `التاجر: ${merchant}`);
  }
  const last4 = safeLast4(parsed.last4);
  if (last4) lines.push(`البطاقة: ****${last4}`);
  const time = timeLabel(parsed.occurredAt ?? receivedAt, tzOffsetMinutes);
  if (time) lines.push(`الوقت: ${time}`);
  // 3.12: only a category the user decided (their saved rule) is shown; a
  // parser's or model's category is a proposal until the device applies it.
  const category = parsed.ruleCategory ? categoryLabelAr(parsed.ruleCategory) : null;
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
      return 'سحب نقدي 💵';
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
        ...withPushDelivery(notification, true),
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

  const transientFailure = isTransientApnsFailure(result.httpStatus, result.errorCode);
  await supabase
    .from('processed_captures')
    // A push that will not be retried leaves the alert to the importing device.
    .update({ apns_push_error: result.reason, ...(transientFailure ? {} : withPushDelivery(notification, false)) })
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

  if (transientFailure) {
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
