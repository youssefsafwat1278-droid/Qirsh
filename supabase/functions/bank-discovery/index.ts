import { bumpCaptureEndpointRateLimit, serviceClient } from '../_shared/capture_auth.ts';
import { geminiRequestBody } from '../_shared/gemini_request.ts';
import {
  apiError,
  consentError,
  correlationId,
  fetchWithTimeout,
  readJsonBody,
  resolveVerifiedIdentity,
  safeLog,
  schemaError,
} from '../_shared/ai_endpoint.ts';
import {
  IBAN_DETECT_PATTERN,
  redactPii,
  redactSenderForAi,
  redactThirdPartyNames,
} from '../_shared/sms_redaction.ts';

const MAX_BODY_BYTES = 8192;
const MAX_SMS_LENGTH = 2000;
const GEMINI_TIMEOUT_MS = 12000;

const GEMINI_MODEL = Deno.env.get('GEMINI_MODEL') ?? 'gemini-2.5-flash-lite';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
// Bank discovery only fires for a genuinely unknown sender (see
// bank_discovery_service.dart — known profiles, confirmed/pending/cooldown
// mappings all short-circuit before this call), so a real user hits this
// rarely. The cap exists to bound cost/abuse from a direct caller using the
// public anon key, not to constrain normal usage — same pattern and limit
// class as enrich-merchant's DAILY_LIMIT_PER_INSTALL.
const DAILY_LIMIT_PER_IDENTITY = 50;

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface DiscoveryRequest {
  senderId: string;
  sanitizedSms: string;
  detectedCurrency?: string;
  localeHint?: string;
  installId?: string;
}

interface DiscoverySuggestion {
  suggestedBankName: string;
  bankKeySuggestion?: string;
  country: string;
  confidence: number;
  reason: string;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return json({ error: 'method_not_allowed' }, 405);
  }

  const cid = correlationId();
  const supabase = serviceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const rec = bodyRes.body;
  const schemaBad = schemaError(rec, cid);
  if (schemaBad) return schemaBad;

  const parsedRequest = parseRequest(rec);
  if ('error' in parsedRequest) {
    safeLog({ event: 'bank_discovery_rejected', reason: parsedRequest.error, correlation_id: cid });
    return apiError('invalid_payload', { correlationId: cid });
  }
  const request = parsedRequest.request;

  // MALI-060n — bank discovery sends the (sanitized) SMS to Gemini: verified
  // identity + AI consent required; rate limit keyed on the verified identity,
  // never the caller-supplied install_id.
  const identity = await resolveVerifiedIdentity(req, supabase, rec, cid);
  if (!identity.ok) return identity.response;
  const consentBad = consentError(identity.identity, 'ai', cid);
  if (consentBad) return consentBad;
  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'bank-discovery',
    DAILY_LIMIT_PER_IDENTITY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  if (request.sanitizedSms.length > MAX_SMS_LENGTH) {
    return apiError('payload_too_large', { correlationId: cid });
  }

  const safeSms = reSanitize(request.sanitizedSms);
  const senderHash = await shortHash(request.senderId);
  if (containsUnsafeRawData(safeSms)) {
    safeLog({ event: 'bank_discovery_unsafe_payload', senderHash, textLength: safeSms.length, correlation_id: cid });
    return apiError('invalid_payload', { correlationId: cid });
  }

  safeLog({ event: 'bank_discovery_request', senderHash, textLength: safeSms.length, correlation_id: cid });

  if (!GEMINI_API_KEY) {
    safeLog({ event: 'bank_discovery_ai_unconfigured', correlation_id: cid });
    return apiError('upstream_unavailable', { correlationId: cid, retryable: true });
  }

  try {
    const geminiRes = await fetchWithTimeout(`${GEMINI_URL}?key=${GEMINI_API_KEY}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: geminiRequestBody({
        contents: [{ parts: [{ text: buildPrompt(request, safeSms) }] }],
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 256,
          responseMimeType: 'application/json',
        },
      }),
    }, GEMINI_TIMEOUT_MS);
    safeLog({
      event: 'bank_discovery_gemini_response',
      senderHash,
      status: geminiRes.status,
      ok: geminiRes.ok,
      model: GEMINI_MODEL,
      correlation_id: cid,
    });

    if (!geminiRes.ok) {
      return json({ error: 'ai_request_failed' }, 200);
    }

    const geminiJson = await geminiRes.json();
    const text: string = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
    const suggestion = parseSuggestion(text);
    if (!suggestion) {
      return json({ error: 'no_suggestion' }, 200);
    }

    safeLog({
      event: 'bank_discovery_suggestion',
      senderHash,
      country: suggestion.country,
      confidence: suggestion.confidence,
      hasBankKeySuggestion: Boolean(suggestion.bankKeySuggestion),
      correlation_id: cid,
    });

    return json(suggestion);
  } catch (_error) {
    // Never log the raw error text (may embed upstream/body detail).
    safeLog({ event: 'bank_discovery_failed', senderHash, correlation_id: cid });
    return json({ error: 'ai_discovery_failed' }, 200);
  }
});

function parseRequest(body: unknown):
  | { request: DiscoveryRequest }
  | { error: string } {
  if (!body || typeof body !== 'object') return { error: 'invalid_json' };
  const data = body as Record<string, unknown>;
  const senderId = readString(data, 'senderId', 'sender_id');
  const sanitizedSms = readString(data, 'sanitizedSms', 'sanitized_sms');
  const detectedCurrency = readOptionalString(
    data,
    'detectedCurrency',
    'detected_currency',
  );
  const localeHint = readOptionalString(data, 'localeHint', 'locale_hint');
  const installId = readOptionalString(data, 'installId', 'install_id');

  if (!senderId || !sanitizedSms) return { error: 'missing_fields' };
  if (senderId.length > 64) return { error: 'sender_too_long' };
  if (sanitizedSms.length > 1200) return { error: 'sms_too_long' };

  return {
    request: {
      senderId,
      sanitizedSms,
      detectedCurrency,
      localeHint,
      installId: installId || undefined,
    },
  };
}

function readString(data: Record<string, unknown>, ...keys: string[]): string {
  for (const key of keys) {
    const value = data[key];
    if (typeof value === 'string' && value.trim().length > 0) {
      return value.trim();
    }
  }
  return '';
}

function readOptionalString(
  data: Record<string, unknown>,
  ...keys: string[]
): string | undefined {
  const value = readString(data, ...keys);
  return value.length > 0 ? value : undefined;
}

function buildPrompt(request: DiscoveryRequest, safeSms: string): string {
  return `You identify the likely bank behind a sanitized SMS sender.

Task:
- Identify bank identity only.
- Do NOT parse transactions.
- Do NOT return amounts, balances, card numbers, account numbers, or merchant names.
- If the bank is unclear, return confidence below 0.95.

Return ONLY this JSON shape:
{
  "suggestedBankName": "Full official/common bank name",
  "bankKeySuggestion": "lower_snake_key_with_country_suffix",
  "country": "ISO-3166 alpha-2 country code",
  "confidence": 0.0,
  "reason": "Short reason based on sender and wording, no SMS content quote"
}

Sender ID: ${redactSenderForAi(request.senderId)}
Detected currency: ${request.detectedCurrency ?? 'unknown'}
Locale hint: ${request.localeHint ?? 'unknown'}
Sanitized SMS:
${safeSms}`;
}

function parseSuggestion(rawText: string): DiscoverySuggestion | null {
  const cleaned = rawText
    .replace(/```json\n?/gi, '')
    .replace(/```\n?/g, '')
    .trim();
  if (!cleaned) return null;

  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(cleaned);
  } catch {
    return null;
  }

  const suggestedBankName = readString(
    parsed,
    'suggestedBankName',
    'bankName',
    'bank_name',
  );
  const country = readString(parsed, 'country').toUpperCase();
  const reason = readString(parsed, 'reason');
  const bankKeySuggestion = normalizeBankKey(
    readOptionalString(parsed, 'bankKeySuggestion', 'bank_key_suggestion'),
    country,
  );
  const rawConfidence = parsed.confidence;
  const confidence = typeof rawConfidence === 'number' ? Math.max(0, Math.min(1, rawConfidence)) : Number.NaN;

  if (!suggestedBankName || !country || !reason || !Number.isFinite(confidence)) {
    return null;
  }
  if (!/^[A-Z]{2}$/.test(country)) return null;

  return {
    suggestedBankName: suggestedBankName.slice(0, 120),
    bankKeySuggestion,
    country,
    confidence,
    reason: reason.slice(0, 240),
  };
}

function normalizeBankKey(
  rawKey: string | undefined,
  country: string,
): string | undefined {
  if (!rawKey) return undefined;
  const key = rawKey
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '');
  if (!key) return undefined;
  const countrySuffix = country.toLowerCase();
  return key.endsWith(`_${countrySuffix}`) ? key : `${key}_${countrySuffix}`;
}

function reSanitize(text: string): string {
  // Shared floor first (card, phone, IBAN, OTP, account) — this copy was
  // missing IBAN and OTP while forwarding the result to Gemini. The two cue
  // rules below are additions on top, not a substitute: they catch short
  // masked account tails that the 10-20 digit rule does not reach.
  return redactThirdPartyNames(redactPii(text))
    .replace(/(A\/C\s*NO\s*:?\s*)\*?\d{4,}/gi, '$1[ACCOUNT]')
    .replace(/(account|acct|a\/c)\s*:?\s*\*?\d{4,}/gi, '$1 [ACCOUNT]')
    .trim();
}

function containsUnsafeRawData(text: string): boolean {
  return [
    /\b\d{4}[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{4}\b/,
    /\b\d{10,20}\b/,
    /\+\d{7,15}\b/,
    /\b05\d{8}\b/,
    /\b01[0125]\d{8}\b/,
    // An IBAN survived this gate before: it is alphanumeric, so none of the
    // digit patterns above can match one.
    IBAN_DETECT_PATTERN,
  ].some((pattern) => pattern.test(text));
}

async function shortHash(value: string): Promise<string> {
  const data = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest('SHA-256', data);
  return Array.from(new Uint8Array(hash))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
    .slice(0, 12);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders,
      'Content-Type': 'application/json',
    },
  });
}
