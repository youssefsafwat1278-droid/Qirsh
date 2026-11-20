// Gemini-first phase 4: one Google Places lookup of a merchant code's display
// name, for the shared merchant memory (sms_shape_memory.ts). Same provider,
// endpoint, field mask and global 'places' budget bucket as enrich-merchant;
// no new paid provider. Runs in the background after a capture is recorded,
// at most once per code (merchant_code_claim_lookup), never blocking it.
import { reserveAiBudget } from './ai_budget_gate.ts';
import type { AiBudgetRpcClient } from './ai_spend_guard.ts';
import { redactPii } from './sms_redaction.ts';
import { claimMerchantLookup, bumpAnalysisCounter, resolveMerchant } from './sms_shape_memory.ts';

const PLACES_URL = 'https://places.googleapis.com/v1/places:searchText';
const PLACES_TIMEOUT_MS = 8000;

/** The region of the account currency, so "SAOOD MARKET" is searched where it was paid. */
const CURRENCY_REGION: Record<string, string> = {
  EGP: 'EG', SAR: 'SA', AED: 'AE', KWD: 'KW', QAR: 'QA', BHD: 'BH', OMR: 'OM', JOD: 'JO',
};

/** Payment-gateway prefixes on a terminal name ("PAYMOB RAF SPECIALIT", "KASHIERFast"). */
const GATEWAY_PREFIX = /^(?:paymob|kashier)[\s*_.-]*/i;

/** The text searched for [code]: without a gateway prefix when a name remains. */
export function lookupQuery(code: string): string {
  const rest = code.replace(GATEWAY_PREFIX, '').trim();
  return rest.replace(/[^A-Za-z؀-ۿ]/g, '').length >= 3 ? rest : code.trim();
}

function words(value: string): string[] {
  return value.toLowerCase().split(/[^a-z؀-ۿ]+/).filter((w) => w.length >= 3);
}

/**
 * A Places name is kept only when it plausibly names the code: one word of
 * 3+ letters in common (in either direction, spaces ignored in the code), a
 * short plain name and no identifier. Otherwise the raw code stays.
 */
export function plausibleDisplayName(code: string, name: unknown): string | null {
  if (typeof name !== 'string') return null;
  const clean = name.replace(/\s+/g, ' ').trim();
  if (clean.length < 2 || clean.length > 60 || redactPii(clean) !== clean || /[\[\]{}]/.test(clean)) return null;
  const compactCode = code.toLowerCase().replace(/[^a-z؀-ۿ]+/g, '');
  const compactName = clean.toLowerCase().replace(/[^a-z؀-ۿ]+/g, '');
  const shared = words(clean).some((w) => compactCode.includes(w)) ||
    words(code).some((w) => compactName.includes(w));
  return shared ? clean : null;
}

type Client = AiBudgetRpcClient & { from: (table: string) => unknown };

/**
 * Looks [code] up once and stores the result for all users. Returns the
 * display name stored, or null. Every failure leaves the raw code in use.
 */
export async function lookUpMerchantOnce(client: Client, input: {
  codeKey: string;
  code: string;
  currency?: string;
  apiKey: string;
  fetcher?: typeof fetch;
}): Promise<string | null> {
  if (!input.apiKey) return null;
  if (!(await claimMerchantLookup(client, input.codeKey))) return null;
  if (!(await reserveAiBudget(client, 'places')).allowed) {
    // Not looked up: released for a later message.
    await resolveMerchant(client, input.codeKey, null).catch(() => null);
    return null;
  }
  await bumpAnalysisCounter(client, 'merchant_lookup');
  let display: string | null = null;
  try {
    const region = CURRENCY_REGION[(input.currency ?? '').toUpperCase()];
    const response = await (input.fetcher ?? fetch)(PLACES_URL, {
      method: 'POST',
      signal: AbortSignal.timeout(PLACES_TIMEOUT_MS),
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': input.apiKey,
        'X-Goog-FieldMask': 'places.displayName',
      },
      body: JSON.stringify({ textQuery: lookupQuery(input.code), maxResultCount: 1,
        ...(region ? { regionCode: region } : {}) }),
    });
    if (response.ok) {
      const json = await response.json();
      display = plausibleDisplayName(input.code, json?.places?.[0]?.displayName?.text);
    }
  } catch { /* the raw code stays */ }
  await resolveMerchant(client, input.codeKey, display ?? '');
  return display;
}
