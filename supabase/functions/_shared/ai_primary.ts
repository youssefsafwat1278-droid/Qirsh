import { amountTextGrounded } from './ai_candidate_validator.ts';
import { geminiRequestBody } from './gemini_request.ts';
import {
  checkUnderstanding,
  nonTransactionVerdict,
  STRUCTURED_PROPERTIES,
  UNDERSTANDING_SYSTEM_INSTRUCTION,
} from './ai_understanding.ts';

// AI owns interpretation. Validation constrains evidence/shape, never substitutes
// a rule-based transaction. No payload, credential or provider body is logged.
export const AI_PRIMARY_MODE = 'ai_primary_v1';
export const MAX_AI_ATTEMPTS = 3;
export type PrimaryAiResult =
  | { ok: true; value: Record<string, unknown>; attempts: number }
  | {
    ok: false;
    reason: 'unavailable' | 'invalid_result' | 'denied' | 'budget';
    attempts: number;
    /** invalid_result only: the validator code of the last answer, and that answer (server-side use only). */
    invalid?: string;
    value?: Record<string, unknown>;
  };

const TRANSACTION_PROPERTIES: Record<string, unknown> = {
  is_transaction: { type: 'boolean' },
  amount: { type: 'number' },
  amount_text: { type: 'string' },
  currency: { type: 'string' },
  merchant_name: { type: 'string' },
  merchant: { type: 'string' },
  type: { type: 'string', enum: ['payment', 'withdrawal', 'transfer', 'income', 'refund', 'unknown'] },
  direction: { type: 'string', enum: ['credit', 'debit', 'unknown'] },
  category_key: { type: 'string' },
  category: { type: 'string' },
  occurred_at: { type: 'string' },
  occurredAt: { type: 'string' },
  last4: { type: 'string' },
  // 4.2: message type, status, evidence quotes, original vs charged amount.
  ...STRUCTURED_PROPERTIES,
};

/**
 * Gemini-first phase 2: the schema requires every field the validator reads
 * for a transaction, so an answer can no longer leave out `type` or
 * `direction`. One plain object at the root (not an `anyOf` of a transaction
 * and a non-transaction variant): the structured-output docs could not be
 * checked offline for a root-level `anyOf`, and a schema the API refused would
 * fail every request. A non-transaction answers `unknown` / empty values,
 * which the verdict path never reads (`nonTransactionVerdict`). The category
 * is not required: the two prompts name it differently (`category` /
 * `category_key`).
 */
export const TRANSACTION_SCHEMA = {
  type: 'object',
  properties: TRANSACTION_PROPERTIES,
  required: ['is_transaction', 'message_type', 'status', 'amount', 'amount_text', 'currency', 'type', 'direction'],
  additionalProperties: false,
};

/** One provider request's limit: answered requests took p50 7.3 s, p95 11.8 s. */
export const AI_ATTEMPT_TIMEOUT_MS = 20000;
/**
 * All requests for one message, repairs and the one timeout retry included:
 * under the 45 s the app waits for parse-sms and well under the 60 s
 * process-ios-sms lease (and the Edge Function wall clock).
 */
export const AI_TOTAL_BUDGET_MS = 38000;
/** A request with less time than this left is not started. */
const MIN_ATTEMPT_MS = 5000;

export function checkPrimaryAmount(value: Record<string, unknown>, sms: string): string | null {
  const amount = value.amount_text;
  if (typeof amount !== 'string') return 'amount_text_missing';
  const balance = /(?:\b(?:available|remaining|current|new|closing|updated|ledger)\s+balance\b|\bbalance\s*(?:is|:)|الرصيد\s*(?:المتاح|المتبقي|الحالي|الجديد|[:：])|متاح\s+للشراء)/iu.exec(sms);
  if (balance) {
    const valueStart = balance.index + balance[0].length;
    const balanceValue = /^\s*(?:is\s*|[:：=]\s*)?(?:[A-Z]{3}\s*|(?:جنيه|ريال|درهم)\s*)?[+-]?[0-9٠-٩۰-۹][0-9٠-٩۰-۹.,٬٫]*/iu
      .exec(sms.slice(valueStart));
    if (balanceValue && amountTextGrounded(amount, balanceValue[0])) {
      const transactionEvidence = sms.slice(0, balance.index) +
        sms.slice(valueStart + balanceValue[0].length);
      if (!amountTextGrounded(amount, transactionEvidence)) {
        return 'transaction_amount_not_balance';
      }
    }
  }
  const type = value.type;
  const direction = value.direction;
  if (((type === 'income' || type === 'refund') && direction === 'debit') ||
      ((type === 'payment' || type === 'withdrawal') && direction === 'credit')) {
    return 'direction_type_conflict';
  }
  return null;
}

export async function runPrimaryAi(options: {
  prompt: string;
  key: string;
  model: string;
  beforeAttempt: () => Promise<boolean>;
  /// V1-022: reserves one unit of the global AI budget, after [beforeAttempt]
  /// and immediately before each provider request (repairs included). False
  /// means the provider is not called and the result is `budget`.
  reserveAttempt?: () => Promise<boolean>;
  validate: (value: Record<string, unknown>) => string | null;
  /// The sanitized message, when the caller passes it apart from [prompt]:
  /// the structured evidence checks (ai_understanding.ts) then run on it.
  message?: string;
  timeoutMs?: number;
  fetcher?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}): Promise<PrimaryAiResult> {
  if (!options.key) return { ok: false, reason: 'unavailable', attempts: 0 };
  const send = options.fetcher ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  let correction = '';
  let reason: 'unavailable' | 'invalid_result' = 'unavailable';
  let lastInvalid: { invalid: string; value: Record<string, unknown> } | undefined;
  const now = options.now ?? Date.now;
  const deadline = now() + AI_TOTAL_BUDGET_MS;
  let timedOut = false;
  let attempts = 0;
  for (let attempt = 1; attempt <= MAX_AI_ATTEMPTS; attempt++) {
    // The time left for this message; a timed-out message stays retryable.
    const left = deadline - now();
    if (left < MIN_ATTEMPT_MS) break;
    if (!(await options.beforeAttempt())) return { ok: false, reason: 'denied', attempts: attempt - 1 };
    if (options.reserveAttempt && !(await options.reserveAttempt())) {
      return { ok: false, reason: 'budget', attempts: attempt - 1 };
    }
    let retryAfter = 0;
    attempts = attempt;
    try {
      const response = await send(
        `https://generativelanguage.googleapis.com/v1beta/models/${options.model}:generateContent`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-goog-api-key': options.key },
          signal: AbortSignal.timeout(Math.min(options.timeoutMs ?? AI_ATTEMPT_TIMEOUT_MS, left)),
          body: geminiRequestBody({
            // Every caller: the message is untrusted data, never instructions.
            systemInstruction: { parts: [{ text: UNDERSTANDING_SYSTEM_INSTRUCTION }] },
            contents: [{ parts: [{ text: options.prompt + correction }] }],
            generationConfig: {
              temperature: 0,
              maxOutputTokens: 1536,
              responseMimeType: 'application/json',
              responseJsonSchema: TRANSACTION_SCHEMA,
              // Repairs too: a correction is a short re-read, not a harder question.
              ...(options.model === 'gemini-3.8-flash'
                ? { thinkingConfig: { thinkingLevel: 'low' } } : {}),
            },
          }),
        });
      if (!response.ok) {
        const retryable = [408, 429, 500, 502, 503, 504].includes(response.status);
        if (!retryable) return { ok: false, reason: 'unavailable', attempts: attempt };
        const header = response.headers.get('Retry-After');
        if (header) {
          const seconds = Number(header);
          retryAfter = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(header) - Date.now();
          // A long provider wait belongs to a durable later retry, not a lease.
          if (retryAfter > 6000) return { ok: false, reason: 'unavailable', attempts: attempt };
        }
        reason = 'unavailable';
      } else {
        const body = await response.json();
        const text = body?.candidates?.[0]?.content?.parts?.[0]?.text;
        let value: Record<string, unknown> | null = null;
        try {
          const parsed = typeof text === 'string' ? JSON.parse(text.replace(/^```(?:json)?\s*|\s*```$/g, '')) : null;
          if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) value = parsed;
        } catch { /* Ask AI to repair its own invalid JSON; no local substitute. */ }
        // Not a completed movement (declined, pending, a notice, an advert …):
        // a terminal verdict, normalized to is_transaction=false, never retried.
        const verdict = value ? nonTransactionVerdict(value) : null;
        if (verdict) return { ok: true, value: verdict, attempts: attempt };
        const invalid = value
          ? options.validate(value) ??
            (options.message == null ? null : checkUnderstanding(value, options.message))
          : 'valid_json_required';
        if (value && !invalid) return { ok: true, value, attempts: attempt };
        reason = 'invalid_result';
        lastInvalid = value ? { invalid: invalid ?? 'invalid_result', value } : undefined;
        // The correction is a bounded validator code, not raw provider output.
        correction = '\nReview your extraction again. Return valid transaction JSON with exact amount_text, currency and direction. '
          + 'Distinguish the transaction amount from remaining balance, card/account numbers and reference codes. '
          + `Correction required: ${invalid ?? 'invalid_result'}. Do not invent missing facts.`;
      }
    } catch (error) {
      reason = 'unavailable';
      // At most one retry after a timeout: a second slow answer is retried
      // later (the message stays retryable), not within this request.
      if (error instanceof DOMException && error.name === 'TimeoutError') {
        if (timedOut) break;
        timedOut = true;
      }
    }
    if (attempt < MAX_AI_ATTEMPTS) await sleep(Math.max(retryAfter, attempt * 400));
  }
  return reason === 'invalid_result' && lastInvalid
    ? { ok: false, reason, attempts, ...lastInvalid }
    : { ok: false, reason, attempts };
}
