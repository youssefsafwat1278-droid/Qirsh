import { AI_PRIMARY_MODE, checkPrimaryAmount, runPrimaryAi } from '../_shared/ai_primary.ts';
import { REDACTION_PLACEHOLDER, validateAiCandidate } from '../_shared/ai_candidate_validator.ts';
import { geminiRequestBody } from '../_shared/gemini_request.ts';
import { bumpCaptureEndpointRateLimit, corsHeaders, readString, serviceClient } from '../_shared/capture_auth.ts';
import {
  apiError,
  claimIdempotency,
  completeIdempotency,
  consentError,
  correlationId,
  fetchWithTimeout,
  isAbortError,
  payloadHash,
  readJsonBody,
  resolveVerifiedIdentity,
  safeLog,
  schemaError,
} from '../_shared/ai_endpoint.ts';
import { validateEvidenceSpans } from '../_shared/evidence_spans.ts';
import { redactPii, redactThirdPartyNames } from '../_shared/sms_redaction.ts';
import { resolveGeminiRoute } from '../_shared/proof_contract.ts';
import { amountFromText, withValidatedModelAmountText } from './money.ts';

const MAX_BODY_BYTES = 8192;
const MAX_SMS_LENGTH = 2000;
const GEMINI_TIMEOUT_MS = 12000;

function jsonResponse(obj: Record<string, unknown>): Response {
  return new Response(JSON.stringify(obj), {
    headers: { 'Content-Type': 'application/json', ...corsHeaders },
  });
}

const GEMINI_MODEL = Deno.env.get('GEMINI_SMS_MODEL') ?? 'gemini-3.8-flash';
const GEMINI_API_KEY = Deno.env.get('GEMINI_API_KEY') ?? '';

// PHASE 7 — the DEDICATED shadow credential. Deliberately a separate variable
// with NO fallback to GEMINI_API_KEY.
//
// The whole point of the shadow arm's isolation is that it must never consume
// the capacity the production path needs. A `?? GEMINI_API_KEY` here would
// silently undo that, and would do so exactly when someone is misconfiguring
// under pressure — which is when the damage would be worst.
//
// Both keys are read here and then handed to `resolveGeminiRoute`, which is the
// ONLY thing that decides which one serves a request. Neither is used directly
// at the call site: an earlier version refused correctly on a missing shadow
// key and then issued every request — shadow included — with GEMINI_API_KEY.
const GEMINI_SHADOW_API_KEY = Deno.env.get('GEMINI_SHADOW_API_KEY') ?? '';
const GEMINI_URL = `https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent`;
const RATE_LIMIT_PER_DAY = 500;

const BANK_ATM_ALIASES = [
  'BDC',
  'CIB',
  'NBE',
  'AHLYBANK',
  'NATBANK',
  'BM',
  'BMISR',
  'BANQUEMISR',
  'QNB',
  'QNBALAHLI',
  'ALEXBANK',
  'AAIB',
  'HDB',
  'FAISAL',
];

// Server-side re-sanitization mirrors Dart SmsSanitizer — belt-and-suspenders
// in case the client-side sanitizer is bypassed or has a bug. The PII floor
// (card, phone, IBAN, OTP, account) is shared; the beneficiary rules below are
// this endpoint's addition, because it is the one that feeds a categorizing
// prompt and must not hand a third party's name to the model.
function reSanitize(text: string): string {
  return redactThirdPartyNames(redactPii(text)).trim();
}

function compactToken(value: string): string {
  return value.toUpperCase().replace(/[^A-Z0-9]/g, '');
}

function looksLikeBankAtmLocation(location: string): boolean {
  const compact = compactToken(location);
  return BANK_ATM_ALIASES.some((alias) => compact.startsWith(alias));
}

function cleanLocation(value: string): string {
  return value
    .replace(/\s+\bon\b.+$/i, '')
    .replace(/\s+\bat\b\s*\d{1,2}:\d{2}.*$/i, '')
    .replace(/\s+\d{1,2}[/-]\d{1,2}.*$/i, '')
    .replace(/[.;،]+$/g, '')
    .trim();
}

function fallbackParse(text: string): Record<string, unknown> | null {
  const amount = amountFromText(text);
  if (!amount || Number.isNaN(amount.amount)) return null;
  const lower = text.toLowerCase();
  const isIpn = looksLikePersonTransfer(text);
  if (isIpn) {
    return {
      amount: amount.amount,
      ...(amount.amount_text == null ? {} : { amount_text: amount.amount_text }),
      currency: amount.currency,
      type: 'transfer',
      category_key: 'transfers',
      direction: lower.includes('sent') || lower.includes('debited') ? 'debit' : 'credit',
    };
  }

  const locationMatch = text.match(/[@]\s*([^,.;\n]+)|\bat\s+([^,.;\n]+)/i);
  const location = cleanLocation(locationMatch?.[1] ?? locationMatch?.[2] ?? '');
  const debitCardAtm = lower.includes('debit card') &&
    (lower.includes('successful transaction') || lower.includes('transaction of')) &&
    location.length > 0 &&
    looksLikeBankAtmLocation(location);
  if (debitCardAtm) {
    return {
      amount: amount.amount,
      ...(amount.amount_text == null ? {} : { amount_text: amount.amount_text }),
      currency: amount.currency,
      type: 'withdrawal',
      category_key: 'cash',
      direction: 'debit',
    };
  }
  const looksLikePayment = lower.includes('purchase') ||
    lower.includes('payment') ||
    lower.includes('successful transaction') ||
    lower.includes('transaction of') ||
    lower.includes('خصم') ||
    lower.includes('شراء') ||
    lower.includes('مشتريات');
  if (looksLikePayment && location.length > 0) {
    return normalizeParsedCategory({
      amount: amount.amount,
      ...(amount.amount_text == null ? {} : { amount_text: amount.amount_text }),
      currency: amount.currency,
      merchant_name: location,
      type: 'payment',
      category_key: 'other',
      direction: 'debit',
    }, text);
  }
  return null;
}

function looksLikePersonTransfer(text: string): boolean {
  const lower = text.toLowerCase();
  const hasTransferWord = lower.includes('ipn transfer') ||
    lower.includes('transfer sent') ||
    lower.includes('transfer received') ||
    lower.includes('outward transfer') ||
    lower.includes('inward transfer') ||
    lower.includes('internal transfer') ||
    lower.includes('تحويل') ||
    lower.includes('حوالة');
  const hasIpnReference = lower.includes('ipn ref') ||
    lower.includes('ipn ref#') ||
    lower.includes('instapay') ||
    lower.includes('انستاباي');
  const hasPersonCounterparty = /\bfrom\s+\*{0,2}[\p{L}]/iu.test(text) ||
    /\bto\s+\*{0,2}[\p{L}]/iu.test(text) ||
    /(?:من|إلى|الى)\s+\*{0,2}[\p{L}]/iu.test(text);
  const hasCreditDebitTransferWording = lower.includes('credited by') ||
    lower.includes('credited with') ||
    lower.includes('debited by') ||
    lower.includes('sent to') ||
    lower.includes('received from');
  return hasTransferWord ||
    (hasIpnReference && (hasPersonCounterparty || hasCreditDebitTransferWording));
}

function inferCategory(parsed: Record<string, unknown>): string | null {
  const type = typeof parsed.type === 'string' ? parsed.type : '';
  if (type === 'transfer') return 'transfers';
  if (type === 'withdrawal') return 'cash';
  if (type === 'income') return 'income';

  const merchant = typeof parsed.merchant_name === 'string' ? parsed.merchant_name.toUpperCase() : '';
  if (!merchant) return null;
  const rules: Array<[string, string]> = [
    ['STARBUCKS', 'cafes'],
    ['COSTA', 'cafes'],
    ['CARREFOUR', 'groceries'],
    ['KAZION', 'groceries'],
    ['KAZYON', 'groceries'],
    ['BIM', 'groceries'],
    ['NOON', 'shopping'],
    ['AMAZON', 'shopping'],
    ['JUMIA', 'shopping'],
    ['UBER', 'transport'],
    ['CAREEM', 'transport'],
    ['DIDI', 'transport'],
    ['SWVL', 'transport'],
    ['ORANGE', 'bills'],
    ['VODAFONE', 'bills'],
    ['WE ', 'bills'],
    ['ETISALAT', 'bills'],
    ['ADNOC', 'fuel'],
    ['TOTAL', 'fuel'],
    ['SHELL', 'fuel'],
    ['NETFLIX', 'subscriptions'],
    ['SPOTIFY', 'subscriptions'],
    ['YOUTUBE', 'subscriptions'],
    ['APPLE', 'subscriptions'],
    ['AIRBNB', 'travel'],
    ['BOOKING', 'travel'],
    ['EXPEDIA', 'travel'],
  ];
  for (const [needle, category] of rules) {
    if (merchant.includes(needle)) return category;
  }
  return null;
}

function normalizeParsedCategory(
  parsed: Record<string, unknown>,
  text = '',
): Record<string, unknown> {
  if (text && looksLikePersonTransfer(text)) {
    const next: Record<string, unknown> = { ...parsed, type: 'transfer', category_key: 'transfers' };
    if (!next.direction || next.direction === 'unknown') {
      next.direction = /\b(sent|debited|to)\b/i.test(text) ? 'debit' : 'credit';
    }
    delete next.merchant_name;
    return next;
  }
  const current = typeof parsed.category_key === 'string' ? parsed.category_key : '';
  if (current && current !== 'other') return parsed;
  const inferred = inferCategory(parsed);
  if (inferred) return { ...parsed, category_key: inferred };
  return parsed;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: corsHeaders });
  }

  const cid = correlationId();
  const supabase = serviceClient();

  const bodyRes = await readJsonBody(req, MAX_BODY_BYTES);
  if (!bodyRes.ok) return apiError(bodyRes.code, { correlationId: cid });
  const body = bodyRes.body;

  const schemaBad = schemaError(body, cid);
  if (schemaBad) return schemaBad;

  // MALI-060n — raw bank SMS goes to Gemini: a verified identity (device secret
  // or user JWT), never the caller-supplied install_id, is required, and the AI
  // processing consent is enforced server-side. A missing verified identity or
  // consent returns a typed failure and the client falls back to local parsing.
  const identity = await resolveVerifiedIdentity(req, supabase, body, cid);
  if (!identity.ok) return identity.response;

  const consentBad = consentError(identity.identity, 'ai', cid);
  if (consentBad) return consentBad;

  if (typeof body.sanitized_sms !== 'string' || !body.sanitized_sms.trim()) {
    return apiError('invalid_payload', { correlationId: cid });
  }
  if ((body.sanitized_sms as string).length > MAX_SMS_LENGTH) {
    return apiError('payload_too_large', { correlationId: cid });
  }

  const today = new Date().toISOString().slice(0, 10);

  // Atomic per-verified-identity daily cap (replaces the racy read-then-upsert
  // on ai_rate_limits keyed by a caller-supplied install_id).
  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'parse-sms',
    RATE_LIMIT_PER_DAY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  // PHASE 7 — the additive proof-v1 contract.
  //
  // A request WITHOUT this marker is handled exactly as before: the v1 path is
  // byte-identical, which is what makes deploying this function inert.
  //
  // A request WITH it is the shadow arm, and it is served ONLY from the
  // dedicated shadow credential. When that credential is absent the request is
  // refused outright — never quietly downgraded to the v1 path, because a
  // "successful" shadow call funded by production quota is the precise failure
  // this design exists to prevent.
  //
  // The decision lives in `_shared/proof_contract.ts` and RETURNS THE
  // CREDENTIAL, so "which key" cannot drift away from "which contract". A
  // previous version consulted a shared module for the accept/refuse decision
  // only and then used GEMINI_API_KEY unconditionally at the call site, which
  // is a defect no amount of gate testing can see.
  // `readString` returns '' for an absent field; absent means v1 (the shipping
  // app never sends a contract), so it must reach the router as null.
  const contract = readString(body, 'contract') || null;
  const route = resolveGeminiRoute(contract, {
    productionKey: GEMINI_API_KEY,
    shadowKey: GEMINI_SHADOW_API_KEY,
  });
  if (route.refused) {
    if (contract === 'proof-v1') {
      // The credential itself is never logged — only the fact of its absence.
      safeLog({
        event: 'proof_shadow_refused_no_credential',
        fn: 'parse-sms',
        correlation_id: cid,
      });
    }
    return apiError(route.code, {
      correlationId: cid,
      retryable: route.retryable,
    });
  }

  // Re-sanitize server-side before sending to Gemini
  const reSanitized = reSanitize(body.sanitized_sms as string);

  // PHASE 6 — if the caller supplied evidence spans, they must describe THIS
  // text, not the client's copy of it. Verified before any upstream call, so a
  // stale-offset payload costs nothing and proves nothing.
  const spans = validateEvidenceSpans((body as Record<string, unknown>).evidence, reSanitized);
  if (!spans.ok) {
    // The reason is logged, not returned: a caller probing which of its spans
    // failed would be probing the sanitized text it is not entitled to see.
    safeLog({ event: 'evidence_span_rejected', fn: 'parse-sms', correlation_id: cid, reason: spans.reason });
    return apiError('invalid_payload', { correlationId: cid });
  }

  // The production route with no production key configured. Checked HERE rather
  // than in the router so a malformed v1 request still receives the error it
  // received before Phase 7 (span/sanitize failures are decided first). The
  // shadow route can never reach this line with an empty key: it refused above.
  if (!route.key) {
    return apiError('upstream_unavailable', { correlationId: cid, retryable: true });
  }

  // Idempotency (MALI-060n): a stable client request_id makes a retry never
  // repeat the paid Gemini call. Only a payload HASH is stored (never the raw
  // SMS), plus the bounded result which expires by TTL.
  const requestId = readString(body, 'request_id', 'requestId');
  let idempotencyClaimed = false;
  if (requestId) {
    const hash = await payloadHash([identity.identity.ownerKey, 'parse-sms', reSanitized]);
    const claim = await claimIdempotency(supabase, identity.identity.ownerKey, 'parse-sms', requestId, hash);
    if (claim.outcome === 'mismatch') {
      return apiError('request_replay_mismatch', { correlationId: cid });
    }
    if (claim.outcome === 'exists') {
      if (claim.status === 'succeeded' && Object.keys(claim.result).length > 0) {
        return jsonResponse(claim.result);
      }
      // A concurrent duplicate is mid-flight (or a prior attempt failed): never
      // re-pay. Ask the client to retry shortly (it may parse locally meanwhile).
      return apiError('upstream_unavailable', { correlationId: cid, retryable: true, retryAfterSeconds: 3 });
    }
    idempotencyClaimed = claim.outcome === 'claimed';
  }

  const finish = async (result: Record<string, unknown>): Promise<Response> => {
    // A sanitizer placeholder ("[NAME]") is never a merchant; the client's
    // grounding check would accept it because the placeholder IS in the text.
    const obj = typeof result.merchant_name === 'string' && REDACTION_PLACEHOLDER.test(result.merchant_name)
      ? Object.fromEntries(Object.entries(result).filter(([k]) => k !== 'merchant_name'))
      : result;
    if (idempotencyClaimed) {
      await completeIdempotency(supabase, identity.identity.ownerKey, 'parse-sms', requestId, 'succeeded', obj);
    }
    return jsonResponse(obj);
  };
  const failUpstream = async (code: 'upstream_rejected' | 'upstream_timeout'): Promise<Response> => {
    if (idempotencyClaimed) {
      await completeIdempotency(supabase, identity.identity.ownerKey, 'parse-sms', requestId, 'failed', {});
    }
    return apiError(code, { correlationId: cid, retryable: code === 'upstream_timeout' });
  };

  const prompt = `You are a bank SMS parser. Extract transaction details from this sanitized bank SMS.
Return ONLY a JSON object. Omit fields you cannot determine. Amount MUST appear in the message.
Current date for missing year/month inference: ${today}.

FIRST: decide if this is a real financial transaction.
If the message is NOT a real financial transaction — e.g. it is an OTP/verification code,
a balance enquiry reply, a marketing/promotional offer, a fraud alert with no actual debit/credit,
a general bank notification, or any non-transactional communication — return ONLY:
{"is_transaction": false}
Do NOT attempt to extract amount or other fields for non-transaction messages.

Fields (for transaction messages only):
- amount: number (required legacy compatibility value)
- amount_text: string (required exact decimal token, for example "19.99"; plain ASCII digits with an optional
  decimal point, no exponent, no currency symbol, and no rounding; preserve all fractional digits from the SMS)
- currency: ISO code like "SAR", "EGP", "AED" (required)
  Example money shape: {"amount":19.99,"amount_text":"19.99","currency":"EGP"}
- merchant_name: string (business name for payment/POS only — omit for transfers).
  Payment gateways/aggregators (e.g. "Fawry", "Fawateer", "Fawateerak") are intermediaries,
  NOT the merchant. When the text reads "<gateway> <real merchant>", return the REAL merchant
  (e.g. the restaurant/store), never the gateway name. Do not assume category "bills" just because
  a gateway is involved — categorize by the real merchant.
  Bracketed placeholders ([NAME], [CARD], [ACCOUNT], [PHONE], [IBAN], [OTP], [REF], [EMAIL],
  [REDACTED]) mark removed personal data: never return one as merchant_name.
- type: "payment" | "withdrawal" | "transfer" | "income" | "refund" | "unknown"
- direction: "credit" | "debit" | "unknown" (credit means money/card balance increased; debit means decreased)
- occurred_at: ISO-8601 local datetime if the SMS contains a date/time. Infer
  the current year when only day/month is present. If only day + time appears
  (e.g. Arabic "يوم 06 الساعة 13:29"), infer the current month/year unless
  that would be in the future, then use the previous month. Omit only when no
  date/time clue exists. Write it as "YYYY-MM-DDTHH:MM:SS" in 24-hour time with
  NO "Z" and NO offset. Convert 12-hour times exactly: AM/ص/صباحا = morning,
  PM/م/مساء = afternoon/evening; 12:xx AM = 00:xx, 12:xx PM = 12:xx,
  01:43 PM = 13:43. Never invent a time that is not written.
- category_key: "restaurants" | "groceries" | "transport" | "fuel" | "bills" | "shopping" | "health" | "education" | "entertainment" | "subscriptions" | "transfers" | "cash" | "travel" | "gifts" | "kids" | "home" | "cafes" | "maintenance" | "fitness" | "beauty" | "charity" | "pets" | "insurance" | "income" | "other"

Category rules:
- Always choose the closest category_key. Use "other" only when the merchant/type
  cannot reasonably fit any listed category.
- Transfers must be category_key="transfers"; ATM/cash withdrawals must be
  category_key="cash"; salary/income must be category_key="income".
- If wording says the account/card was credited, topped up, added to, received
  from, or funded, direction="credit". If wording says sent, paid, debited,
  spent, withdrawn, or deducted, direction="debit".
- IPN/InstaPay/person-to-person messages are transfers, not income and not
  merchants. If the SMS contains "IPN REF", "IPN transfer", "Instapay",
  "credited by ... from <person>", "received from <person>", or "sent to
  <person>", return type="transfer", category_key="transfers", and omit
  merchant_name even if a person name appears. Use direction="credit" for
  incoming/credited/received transfers and direction="debit" for sent/outgoing
  transfers.
- Only use type="income" for salary, payroll, interest, reward, cashback, or
  business income. A credited account from a named person via IPN/InstaPay is
  an incoming transfer, not income.
- Coffee shops/cafes (Starbucks, Costa, local cafe names) should be "cafes",
  supermarkets "groceries", ride-hailing/taxis "transport", telco/top-up bills
  "bills", online stores "shopping", recurring digital services
  "subscriptions".

Important ATM/bank-location rule:
- If a debit-card SMS says "successful transaction" / "transaction of" and the
  location after "@" or "at" is a bank/ATM branch or bank abbreviation (examples:
  BDC OROBA, CIB, NBE, AHLYBANK, BMISR, QNBALAHLI), classify it as
  type="withdrawal" and category_key="cash". Do not treat the bank branch as a
  shopping merchant, bills, or other.
- Only classify as payment when the location is a real merchant/store (examples:
  Orange, Noon, Starbucks, Carrefour).

SMS: ${reSanitized}

Return ONLY valid JSON. No markdown, no explanation.`;

  if (body.analysis_mode === AI_PRIMARY_MODE) {
    const validate = (value: Record<string, unknown>) => {
      if (value.is_transaction !== true) return 'is_transaction_required';
      if (typeof value.category_key !== 'string' || !value.category_key) return 'category_required';
      const checked = validateAiCandidate({ candidate: value,
        sanitizedText: reSanitized, receivedAt: new Date().toISOString(), local: null });
      return checked.accepted ? checkPrimaryAmount(value, reSanitized) : checked.reason;
    };
    const result = await runPrimaryAi({ prompt, key: route.key, model: GEMINI_MODEL,
      validate, beforeAttempt: async () => {
        const fresh = await resolveVerifiedIdentity(req, supabase, body, cid);
        return fresh.ok && fresh.identity.ownerKey === identity.identity.ownerKey &&
          consentError(fresh.identity, 'ai', cid) == null;
      } });
    if (!result.ok) {
      if (result.reason === 'denied') return apiError('consent_required', { correlationId: cid });
      return failUpstream(result.reason === 'unavailable' ? 'upstream_timeout' : 'upstream_rejected');
    }
    if (result.value.is_transaction === false) return finish({ is_transaction: false });
    return finish({ ...result.value, model_used: GEMINI_MODEL });
  }

  let parsed: Record<string, unknown> | null = null;
  try {
    // THE routing fix: the credential comes from the contract router, never
    // from the module-level production constant. proof-v1 is billed to the
    // shadow project or it does not happen at all.
    const geminiRes = await fetchWithTimeout(`${GEMINI_URL}?key=${route.key}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: geminiRequestBody({
        contents: [{ parts: [{ text: prompt }] }],
        generationConfig: {
          temperature: 0,
          maxOutputTokens: 1024,
          responseMimeType: 'application/json',
          ...(GEMINI_MODEL === 'gemini-3.8-flash'
            ? { thinkingConfig: { thinkingLevel: 'low' } }
            : {}),
        },
      }),
    }, GEMINI_TIMEOUT_MS);
    if (!geminiRes.ok) throw new Error(`gemini_${geminiRes.status}`);
    const geminiJson = await geminiRes.json();
    const text: string = geminiJson?.candidates?.[0]?.content?.parts?.[0]?.text ?? '';
    const cleaned = text.replace(/```json\n?/g, '').replace(/```\n?/g, '').trim();
    parsed = JSON.parse(cleaned);
  } catch (error) {
    // A timeout is distinct from a genuine rejection; the client may retry.
    if (isAbortError(error)) return await failUpstream('upstream_timeout');
    const fallback = fallbackParse(reSanitized);
    if (fallback) return await finish({ ...fallback, model_used: `${GEMINI_MODEL}+fallback` });
    return await failUpstream('upstream_rejected');
  }

  if (parsed?.is_transaction === false) {
    return await finish({ is_transaction: false });
  }

  const withExactText = parsed && typeof parsed === 'object' ? withValidatedModelAmountText(parsed) : null;
  if (!withExactText || typeof withExactText.amount !== 'number' || !withExactText.currency) {
    const fallback = fallbackParse(reSanitized);
    if (fallback) return await finish({ ...fallback, model_used: `${GEMINI_MODEL}+fallback` });
    return await failUpstream('upstream_rejected');
  }

  return await finish({ ...normalizeParsedCategory(withExactText, reSanitized), model_used: GEMINI_MODEL });
});
