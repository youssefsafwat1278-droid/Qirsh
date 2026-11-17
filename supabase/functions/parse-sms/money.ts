import { amountGrounded } from '../_shared/ai_candidate_validator.ts';
import { canonicalMoneyText, modelMoneyText } from '../_shared/money_text.ts';

export const PARSE_SMS_CURRENCY_CODES = [
  'EGP',
  'SAR',
  'AED',
  'USD',
  'EUR',
  'GBP',
  'KWD',
  'QAR',
  'BHD',
  'OMR',
  'JOD',
  'JPY',
];

export interface ExtractedAmount {
  amount: number;
  amount_text?: string;
  currency: string;
}

function extractedAmount(token: string, currency: string): ExtractedAmount {
  const amountText = canonicalMoneyText(token, currency);
  return {
    amount: Number(amountText ?? token.replace(/,/g, '')),
    ...(amountText == null ? {} : { amount_text: amountText }),
    currency,
  };
}

export function amountFromText(text: string): ExtractedAmount | null {
  const escapedCurrencies = PARSE_SMS_CURRENCY_CODES.join('|');
  const currencyBefore = new RegExp(`\\b(${escapedCurrencies})\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)`, 'i');
  const currencyAfter = new RegExp(`([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*\\b(${escapedCurrencies})\\b`, 'i');
  const egyptianPoundAfter = /([0-9][0-9,]*(?:\.[0-9]+)?)\s*(?:جم|جنيه)/i;
  const withAmountWord = new RegExp(
    `(?:amount(?:\\s+of)?|مبلغ)\\s*(?:of\\s*)?\\b(${escapedCurrencies})\\b\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)`,
    'i',
  );
  const match = text.match(withAmountWord) ?? text.match(currencyBefore);
  if (match) return extractedAmount(match[2], match[1].toUpperCase());

  const reverse = text.match(currencyAfter);
  if (reverse) return extractedAmount(reverse[1], reverse[2].toUpperCase());

  const egp = text.match(egyptianPoundAfter);
  if (egp) return extractedAmount(egp[1], 'EGP');
  return null;
}

export function withValidatedModelAmountText(parsed: Record<string, unknown>): Record<string, unknown> {
  const next = { ...parsed };
  delete next.amount_text;
  const amountText = modelMoneyText(parsed);
  if (amountText != null) {
    next.amount_text = amountText;
    next.amount = Number(amountText);
  }
  return next;
}

/**
 * V1-060: [withValidatedModelAmountText], then the amount must be a whole
 * numeric token of the sanitized [text] (the same grounding as
 * validateAiCandidate and the app's GroundingCheck). An ungrounded amount is
 * dropped, so the caller falls back to the amount read from the text itself.
 */
export function groundedModelAmount(parsed: Record<string, unknown>, text: string): Record<string, unknown> {
  const next = withValidatedModelAmountText(parsed);
  if (amountGrounded(next.amount, text)) return next;
  delete next.amount;
  delete next.amount_text;
  return next;
}
