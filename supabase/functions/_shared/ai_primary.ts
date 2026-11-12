import { amountTextGrounded } from './ai_candidate_validator.ts';
import { geminiRequestBody } from './gemini_request.ts';

// AI owns interpretation. Validation constrains evidence/shape, never substitutes
// a rule-based transaction. No payload, credential or provider body is logged.
export const AI_PRIMARY_MODE = 'ai_primary_v1';
export const MAX_AI_ATTEMPTS = 3;
export type PrimaryAiResult =
  | { ok: true; value: Record<string, unknown>; attempts: number }
  | { ok: false; reason: 'unavailable' | 'invalid_result' | 'denied'; attempts: number };

export const TRANSACTION_SCHEMA = {
  type: 'object',
  properties: {
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
  },
  required: ['is_transaction'],
  additionalProperties: false,
};

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
  validate: (value: Record<string, unknown>) => string | null;
  timeoutMs?: number;
  fetcher?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
}): Promise<PrimaryAiResult> {
  if (!options.key) return { ok: false, reason: 'unavailable', attempts: 0 };
  const send = options.fetcher ?? fetch;
  const sleep = options.sleep ?? ((ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms)));
  let correction = '';
  let reason: 'unavailable' | 'invalid_result' = 'unavailable';
  for (let attempt = 1; attempt <= MAX_AI_ATTEMPTS; attempt++) {
    if (!(await options.beforeAttempt())) return { ok: false, reason: 'denied', attempts: attempt - 1 };
    let retryAfter = 0;
    try {
      const response = await send(
        `https://generativelanguage.googleapis.com/v1beta/models/${options.model}:generateContent`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', 'x-goog-api-key': options.key },
          signal: AbortSignal.timeout(options.timeoutMs ?? 12000),
          body: geminiRequestBody({
            contents: [{ parts: [{ text: options.prompt + correction }] }],
            generationConfig: {
              temperature: 0,
              maxOutputTokens: 1536,
              responseMimeType: 'application/json',
              responseJsonSchema: TRANSACTION_SCHEMA,
              ...(options.model === 'gemini-3.8-flash'
                ? { thinkingConfig: { thinkingLevel: attempt === 1 ? 'low' : 'medium' } } : {}),
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
        if (value && value.is_transaction === false) return { ok: true, value, attempts: attempt };
        const invalid = value ? options.validate(value) : 'valid_json_required';
        if (value && !invalid) return { ok: true, value, attempts: attempt };
        reason = 'invalid_result';
        // The correction is a bounded validator code, not raw provider output.
        correction = '\nReview your extraction again. Return valid transaction JSON with exact amount_text, currency and direction. '
          + 'Distinguish the transaction amount from remaining balance, card/account numbers and reference codes. '
          + `Correction required: ${invalid ?? 'invalid_result'}. Do not invent missing facts.`;
      }
    } catch {
      reason = 'unavailable';
    }
    if (attempt < MAX_AI_ATTEMPTS) await sleep(Math.max(retryAfter, attempt * 400));
  }
  return { ok: false, reason, attempts: MAX_AI_ATTEMPTS };
}
