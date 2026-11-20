// Gemini-first phase 4: the shared, non-personal analysis memory.
//
// 1. Shape memory (templates). After Gemini read the same message shape of one
//    bank sender 3 times with the same result (from at least 2 devices), the
//    shape is stored as a template: the masked wording with every figure and
//    the merchant replaced by a typed slot. A later message of exactly that
//    shape is read from the template instead of calling Gemini; 1 in 50 still
//    goes to Gemini, and a disagreement drops the template.
// 2. Merchant memory. A merchant code the model classified as a merchant
//    ("SAOOD MARKET", "PAYMOB RAF SPECIALIT") is remembered once for all users
//    with the model's category, and later with a display name from Google
//    Places (looked up once, in the background, never blocking a record).
//
// Nothing personal is stored: a template holds no amount, number, name or
// merchant value (only slots); a message carrying a masked person ([NAME]) is
// never a template; a merchant code is stored only when the model said
// "merchant", never a placeholder, a person, a channel alias or an identifier.
import { REDACTION_PLACEHOLDER } from './ai_candidate_validator.ts';
import { channelIn } from './analysis_reasons.ts';
import { canonicalMoneyText } from './money_text.ts';
import { redactPii } from './sms_redaction.ts';

/** Gemini reads of one shape before it becomes a template. */
export const TEMPLATE_MIN_READS = 3;
/** Distinct devices among those reads: one person's wording never becomes shared. */
export const TEMPLATE_MIN_SOURCES = 2;
/** 1 in [TEMPLATE_CHECK_EVERY] template matches is still read by Gemini. */
export const TEMPLATE_CHECK_EVERY = 50;

export type ShapeReading = {
  currency: string;
  type: string;
  direction: string;
  counterparty_kind: string;
  /** Only for a shape with no merchant slot (the merchant decides otherwise). */
  category?: string;
};

export type ShapeTemplate = { hash: string; skeleton: string; reading: ShapeReading };

export type MerchantMemory = {
  category: string | null;
  displayName: string | null;
  lookupState: string;
};

export interface AnalysisMemoryReader {
  templates(senderKey: string): Promise<ShapeTemplate[]>;
  merchant(codeKey: string): Promise<MerchantMemory | null>;
}

const NUMBER = /[0-9]+(?:[.,][0-9]+)*/g;
const NAME_PLACEHOLDER = /\[NAME\]/i;
const LETTER = /[A-Za-z؀-ۿ]/;
const WORD_CHAR = /[A-Za-z0-9؀-ۿ]/;
/** A status word is never part of a merchant slot ("CARREFOUR pending"). */
const STATUS_WORD =
  /(?<![a-z])(?:pending|declined|rejected|failed|reversed|reversal|refund(?:ed)?|cancell?ed|canceled|hold|processing|scheduled)(?![a-z])|معلق|مرفوض|فشل|[اإ]لغاء|استرداد|مسترد|قيد الانتظار/i;

function foldDigits(input: string): string {
  return Array.from(input).map((char) => {
    const code = char.charCodeAt(0);
    if (code >= 0x0660 && code <= 0x0669) return String(code - 0x0660);
    if (code >= 0x06F0 && code <= 0x06F9) return String(code - 0x06F0);
    return char;
  }).join('');
}

/** The text a shape is read from: digits folded, whitespace collapsed. */
export function shapeText(text: string): string {
  return foldDigits(text).replace(/\s+/g, ' ').trim();
}

/** The bank sender a template belongs to, or null (a phone number or an empty sender never has one). */
export function senderKey(sender: string | undefined | null): string | null {
  const key = (sender ?? '').trim().toUpperCase();
  if (key.length < 2 || key.length > 32 || !LETTER.test(key)) return null;
  if (/[0-9]{6,}|@/.test(foldDigits(key))) return null;
  return key;
}

/** The merchant-memory key: the device's merchant key (upper case, no digits). */
export function merchantCodeKey(raw: string): string {
  return raw.toUpperCase().replace(/[0-9]/g, '').replace(/\s+/g, ' ').trim();
}

/** A merchant code that may enter (or be looked up in) the shared memory. */
export function merchantCodeEligible(raw: unknown): raw is string {
  if (typeof raw !== 'string') return false;
  const value = raw.trim();
  if (value.length < 2 || value.length > 60 || !LETTER.test(value)) return false;
  if (REDACTION_PLACEHOLDER.test(value) || /[\[\]{}]/.test(value)) return false;
  if (STATUS_WORD.test(value)) return false;
  // An identifier (card, phone, account, e-mail …) is not a business name.
  if (redactPii(value) !== value) return false;
  // A payment channel ("IPN" -> InstaPay) is already a static alias.
  if (channelIn(value) !== undefined) return false;
  return merchantCodeKey(value).replace(/[^A-Za-z؀-ۿ]/g, '').length >= 2;
}

type Slot = { start: number; end: number; tag: 'A' | 'M' | 'L' | 'N' };

/**
 * The skeleton of [text] for a reading: the merchant becomes {M}, the
 * amount {A}, the card's last 4 digits {L}, every other figure {N}. Null when
 * the reading cannot be placed exactly once (the amount twice, the merchant
 * twice or inside a word …) or the text carries a masked person.
 */
export function buildShape(
  text: string,
  reading: { amountText: string; merchant?: string; last4?: string },
): string | null {
  const t = shapeText(text);
  if (!t || /[{}]/.test(t) || NAME_PLACEHOLDER.test(t)) return null;
  const amount = canonicalMoneyText(reading.amountText);
  if (amount == null) return null;
  const slots: Slot[] = [];
  if (reading.merchant != null) {
    const needle = shapeText(reading.merchant).toLowerCase();
    if (!needle) return null;
    const hay = t.toLowerCase();
    const first = hay.indexOf(needle);
    if (first < 0 || hay.indexOf(needle, first + 1) >= 0) return null;
    const end = first + needle.length;
    if ((first > 0 && WORD_CHAR.test(t[first - 1])) || (end < t.length && WORD_CHAR.test(t[end]))) return null;
    slots.push({ start: first, end, tag: 'M' });
  }
  const merchantSlot = slots[0];
  let amounts = 0;
  let last4s = 0;
  for (const m of t.matchAll(NUMBER)) {
    const start = m.index!;
    const end = start + m[0].length;
    if (merchantSlot && start < merchantSlot.end && end > merchantSlot.start) {
      if (start < merchantSlot.start || end > merchantSlot.end) return null;
      continue;
    }
    let tag: Slot['tag'] = 'N';
    if (canonicalMoneyText(m[0]) === amount) {
      tag = 'A';
      amounts++;
    } else if (reading.last4 != null && m[0] === reading.last4) {
      tag = 'L';
      last4s++;
    }
    slots.push({ start, end, tag });
  }
  if (amounts !== 1 || (reading.last4 != null && last4s !== 1)) return null;
  slots.sort((a, b) => a.start - b.start);
  let out = '';
  let cursor = 0;
  for (const s of slots) {
    out += t.slice(cursor, s.start) + `{${s.tag}}`;
    cursor = s.end;
  }
  return out + t.slice(cursor);
}

const SLOT_PATTERN: Record<string, string> = {
  A: '([0-9]+(?:[.,][0-9]+)*)',
  N: '[0-9]+(?:[.,][0-9]+)*',
  L: '([0-9]{4})',
  M: '([^\\[\\]{}]{2,60}?)',
};

/**
 * The slot values of [text] when it has exactly the shape [skeleton], else
 * null. Exact: the whole message, same case, same wording; the values found
 * must rebuild the very same skeleton.
 */
export function matchShape(
  skeleton: string,
  text: string,
): { amountText: string; merchant?: string; last4?: string } | null {
  const t = shapeText(text);
  if (!t || /[{}]/.test(t) || NAME_PLACEHOLDER.test(t)) return null;
  const order: string[] = [];
  const source = skeleton.split(/(\{[AMLN]\})/).map((part) => {
    const slot = /^\{([AMLN])\}$/.exec(part);
    if (!slot) return part.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    if (slot[1] !== 'N') order.push(slot[1]);
    return SLOT_PATTERN[slot[1]];
  }).join('');
  const m = new RegExp(`^${source}$`, 'u').exec(t);
  if (!m) return null;
  const values: Record<string, string> = {};
  order.forEach((tag, i) => (values[tag] = m[i + 1]));
  const amountText = canonicalMoneyText(values.A ?? '');
  if (amountText == null) return null;
  const reading = {
    amountText,
    ...(values.M != null ? { merchant: values.M } : {}),
    ...(values.L != null ? { last4: values.L } : {}),
  };
  if (values.M != null && (values.M !== values.M.trim() || !merchantCodeEligible(values.M))) return null;
  return buildShape(text, reading) === skeleton ? reading : null;
}

// ── Storage (service role; migration 20261120130000) ────────────────────────

type Client = {
  from: (table: string) => unknown;
  rpc: (fn: string, args: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;
};

type Reply = PromiseLike<{ data: unknown; error: unknown }>;
type Query = {
  select(columns: string): Query;
  eq(column: string, value: unknown): Query;
  limit(count: number): Reply;
  maybeSingle(): Reply;
};

function readingOf(value: unknown): ShapeReading | null {
  if (!value || typeof value !== 'object') return null;
  const r = value as Record<string, unknown>;
  if (typeof r.currency !== 'string' || typeof r.type !== 'string' || typeof r.direction !== 'string' ||
    typeof r.counterparty_kind !== 'string') return null;
  return {
    currency: r.currency, type: r.type, direction: r.direction, counterparty_kind: r.counterparty_kind,
    ...(typeof r.category === 'string' ? { category: r.category } : {}),
  };
}

/** Reads of the shared memory. Any failure reads as "nothing known": Gemini is called. */
export function analysisMemoryReader(client: Client): AnalysisMemoryReader {
  return {
    async templates(key) {
      try {
        const { data, error } = await (client.from('sms_shape_templates') as Query)
          .select('skeleton_hash, skeleton, reading')
          .eq('sender_key', key)
          .eq('status', 'active')
          .limit(50);
        if (error || !Array.isArray(data)) return [];
        return (data as Record<string, unknown>[]).flatMap((row) => {
          const reading = readingOf(row.reading);
          return reading && typeof row.skeleton === 'string' && typeof row.skeleton_hash === 'string'
            ? [{ hash: row.skeleton_hash, skeleton: row.skeleton, reading }]
            : [];
        });
      } catch {
        return [];
      }
    },
    async merchant(key) {
      try {
        const { data, error } = await (client.from('merchant_code_memory') as Query)
          .select('category_key, category_state, display_name, lookup_state')
          .eq('code_key', key)
          .maybeSingle();
        if (error || !data || typeof data !== 'object') return null;
        const row = data as Record<string, unknown>;
        return {
          category: row.category_state === 'agreed' && typeof row.category_key === 'string' ? row.category_key : null,
          displayName: typeof row.display_name === 'string' && row.display_name ? row.display_name : null,
          lookupState: typeof row.lookup_state === 'string' ? row.lookup_state : 'none',
        };
      } catch {
        return null;
      }
    },
  };
}

/** One best-effort RPC: a memory write never fails or delays a capture. */
async function call(client: Client, fn: string, args: Record<string, unknown>): Promise<unknown> {
  try {
    const { data, error } = await client.rpc(fn, args);
    return error ? null : data;
  } catch {
    return null;
  }
}

export type AnalysisCounter =
  | 'model_read'
  | 'template_hit'
  | 'template_check'
  | 'template_drop'
  | 'template_activated'
  | 'merchant_lookup';

export const bumpAnalysisCounter = (client: Client, counter: AnalysisCounter) =>
  call(client, 'bump_sms_analysis_daily', { p_counter: counter });

/** Records one Gemini read of a shape; returns the template's state ('activated' when it just became one). */
export async function observeShape(client: Client, input: {
  senderKey: string;
  skeleton: string;
  reading: ShapeReading;
  installIdHash: string;
}): Promise<string | null> {
  const hash = await sha256(`${input.senderKey}\n${input.skeleton}`);
  // Distinct devices are counted by a tag that is unlinkable across shapes.
  const tag = (await sha256(`${input.installIdHash}|${hash}`)).slice(0, 16);
  const state = await call(client, 'sms_template_observe', {
    p_sender_key: input.senderKey,
    p_skeleton_hash: hash,
    p_source_tag: tag,
    p_reading: input.reading,
    p_skeleton: input.skeleton,
    p_min_reads: TEMPLATE_MIN_READS,
    p_min_sources: TEMPLATE_MIN_SOURCES,
  });
  return typeof state === 'string' ? state : null;
}

export const dropShape = (client: Client, hash: string) =>
  call(client, 'sms_template_drop', { p_skeleton_hash: hash });

export const observeMerchant = (client: Client, codeKey: string, category: string) =>
  call(client, 'merchant_code_observe', { p_code_key: codeKey, p_category: category });

export const claimMerchantLookup = async (client: Client, codeKey: string) =>
  (await call(client, 'merchant_code_claim_lookup', { p_code_key: codeKey })) === true;

export const resolveMerchant = (client: Client, codeKey: string, displayName: string | null) =>
  call(client, 'merchant_code_resolve', { p_code_key: codeKey, p_display_name: displayName });

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}
