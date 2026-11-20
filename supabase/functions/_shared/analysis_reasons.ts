// Gemini-first analysis, phase 1: why a message was not recorded, as a closed
// set of codes the app turns into its own Arabic/English sentence (free text
// from the model is never shown), who the other side of a movement is, and
// the known payment-channel aliases used as the merchant's display name.

/** Codes the model may return for a message that is not a completed movement. */
export const MODEL_REASON_CODES = [
  'otp',
  'promo',
  'declined',
  'pending',
  'balance_only',
  'payment_reminder',
  'own_account',
  'not_financial',
  'unclear',
] as const;

/** Codes only the server sets (the model never decides these). */
export const SERVER_REASON_CODES = ['duplicate', 'amount_mismatch', 'direction_conflict'] as const;

export type ReasonCode = typeof MODEL_REASON_CODES[number] | typeof SERVER_REASON_CODES[number];

export const COUNTERPARTY_KINDS = ['person', 'merchant', 'own_account', 'unknown'] as const;
export type CounterpartyKind = typeof COUNTERPARTY_KINDS[number];

/** A model-supplied reason code, or null when it is not one of [MODEL_REASON_CODES]. */
export function modelReasonCode(value: unknown): ReasonCode | null {
  return typeof value === 'string' && (MODEL_REASON_CODES as readonly string[]).includes(value)
    ? value as ReasonCode
    : null;
}

export function counterpartyKindOf(value: unknown): CounterpartyKind {
  return typeof value === 'string' && (COUNTERPARTY_KINDS as readonly string[]).includes(value)
    ? value as CounterpartyKind
    : 'unknown';
}

/** The structured verdict's message_type (ai_understanding.ts) as a reason code. */
const BY_MESSAGE_TYPE: Record<string, ReasonCode> = {
  otp_or_security: 'otp',
  marketing: 'promo',
  declined_or_failed: 'declined',
  pending_or_scheduled: 'pending',
  expected_income: 'pending',
  balance_or_limit_notice: 'balance_only',
  bill_or_reminder: 'payment_reminder',
  own_account_transfer: 'own_account',
  other_non_transaction: 'not_financial',
  multiple_transactions: 'unclear',
  ambiguous: 'unclear',
};

/** The reason code of a "not a transaction" verdict: the model's own code, else its message_type. */
export function verdictReasonCode(value: Record<string, unknown>): ReasonCode {
  return modelReasonCode(value.reason_code) ??
    BY_MESSAGE_TYPE[typeof value.message_type === 'string' ? value.message_type : ''] ?? 'unclear';
}

/** The parser's held meaning reason (message_meaning.ts) as a reason code. */
const BY_MEANING_REASON: Record<string, ReasonCode> = {
  otp_code: 'otp',
  offer: 'promo',
  declined_or_failed: 'declined',
  cheque_returned: 'declined',
  pending: 'pending',
  scheduled_or_expected: 'pending',
  bill_due: 'payment_reminder',
  summary: 'balance_only',
  no_event_amount: 'not_financial',
  own_accounts: 'own_account',
  card_repayment: 'own_account',
  direction_contradiction: 'direction_conflict',
};

export function meaningReasonCode(reason: string | undefined | null): ReasonCode {
  return BY_MEANING_REASON[reason ?? ''] ?? 'unclear';
}

/**
 * A validator rejection of the model's last answer that a person can settle
 * with one tap: the figure is not in the text, or the direction contradicts
 * the wording. Null for any other rejection (the answer stays unusable).
 */
export function confirmationReasonCode(invalid: string | undefined): ReasonCode | null {
  switch (invalid) {
    case 'amount_not_grounded':
    case 'amount_text_not_grounded':
    case 'amount_text_mismatch':
    case 'currency_not_grounded':
    case 'amount_is_account_figure':
    case 'transaction_amount_not_balance':
      return 'amount_mismatch';
    case 'direction_contradiction':
      return 'direction_conflict';
    default:
      return null;
  }
}

/**
 * Known payment-channel aliases (display name of the merchant). Only aliases
 * the acceptance data justifies: Egyptian IPN transfer messages name the
 * InstaPay network by its abbreviation.
 */
const CHANNEL_ALIASES: Array<{ pattern: RegExp; name: string }> = [
  { pattern: /\bipn\b|insta ?pay|إنستا ?باي|انستا ?باي/i, name: 'InstaPay' },
  // Gemini-first phase 2: Egyptian mobile wallets (Arabic and English spellings).
  { pattern: /vodafone ?cash|فودافون ?كاش/i, name: 'Vodafone Cash' },
  { pattern: /orange ?(?:cash|money)|[اأ]ورا?نج ?(?:كاش|موني)/i, name: 'Orange Cash' },
  { pattern: /e& ?money|etisalat ?cash|اتصالات ?كاش|إي ?آند ?(?:موني|ماني)/i, name: 'e& money' },
];

/** The payment channel a message names, as its display name. */
export function channelIn(text: string): string | undefined {
  return CHANNEL_ALIASES.find((a) => a.pattern.test(text))?.name;
}

/** [merchant] under its channel display name when it is a known alias ("IPN" -> "InstaPay"). */
export function channelDisplayName(merchant: string | undefined): string | undefined {
  if (merchant == null) return undefined;
  const alias = CHANNEL_ALIASES.find((a) => a.pattern.test(merchant) && merchant.trim().length <= 14);
  return alias?.name ?? merchant;
}
