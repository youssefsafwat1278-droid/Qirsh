// Enriches an unknown merchant name with a spending category (and optional
// metadata) using the Google Places API — server-side ONLY, so the app never
// calls Maps per-transaction (privacy + cost). The resolved row is written to
// `merchant_keywords`, which devices sync via catalog-delta and then reuse
// offline forever.
//
// Trigger: called directly from the app's normal transaction flow whenever
// an unknown merchant is encountered (see app_providers.dart /
// captured_message_processor.dart), not just an admin panel button. Auth
// (MALI-060n): a server-verified device secret or a real user JWT — never the
// caller-supplied install_id — selects the owner; cloud-processing consent is
// enforced server-side; the daily cap is keyed on that verified identity.
//
// Required secrets:
//   GOOGLE_MAPS_API_KEY        (Places API enabled)
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY
import { bumpCaptureEndpointRateLimit, corsHeaders, readString, serviceClient } from '../_shared/capture_auth.ts';
import { redactPii } from '../_shared/sms_redaction.ts';
import {
  apiError,
  claimIdempotency,
  completeIdempotency,
  consentError,
  correlationId,
  fetchWithTimeout,
  payloadHash,
  readJsonBody,
  resolveVerifiedIdentity,
  schemaError,
} from '../_shared/ai_endpoint.ts';

const MAX_BODY_BYTES = 4096;
const MAX_MERCHANT_LENGTH = 200;
const PLACES_TIMEOUT_MS = 8000;

// MALI-060n — per-VERIFIED-IDENTITY daily cap (device/user), not per
// caller-supplied install_id. Enrichment happens organically as unknown
// merchants show up during normal use, so this is looser than parse-sms's
// AI-call cap; it bounds worst-case Google Places spend + catalog-write volume
// from one verified caller.
const DAILY_LIMIT_PER_IDENTITY = 200;

const MAPS_API_KEY = Deno.env.get('GOOGLE_MAPS_API_KEY') ?? '';
const PLACES_URL = 'https://places.googleapis.com/v1/places:searchText';

// Google Place type → our category key. First match wins (most specific first).
const TYPE_TO_CATEGORY: Array<[string, string]> = [
  ['cafe', 'cafes'],
  ['coffee_shop', 'cafes'],
  ['bakery', 'cafes'],
  ['restaurant', 'restaurants'],
  ['meal_takeaway', 'restaurants'],
  ['meal_delivery', 'restaurants'],
  ['fast_food_restaurant', 'restaurants'],
  ['food', 'restaurants'],
  ['supermarket', 'groceries'],
  ['grocery_store', 'groceries'],
  ['grocery_or_supermarket', 'groceries'],
  ['convenience_store', 'groceries'],
  ['gas_station', 'fuel'],
  ['pharmacy', 'health'],
  ['drugstore', 'health'],
  ['hospital', 'health'],
  ['doctor', 'health'],
  ['dentist', 'health'],
  ['physiotherapist', 'health'],
  ['medical_lab', 'health'],
  ['gym', 'fitness'],
  ['fitness_center', 'fitness'],
  ['beauty_salon', 'beauty'],
  ['hair_care', 'beauty'],
  ['hair_salon', 'beauty'],
  ['spa', 'beauty'],
  ['pet_store', 'pets'],
  ['veterinary_care', 'pets'],
  ['movie_theater', 'entertainment'],
  ['amusement_park', 'entertainment'],
  ['school', 'education'],
  ['primary_school', 'education'],
  ['secondary_school', 'education'],
  ['university', 'education'],
  ['book_store', 'education'],
  ['lodging', 'travel'],
  ['hotel', 'travel'],
  ['travel_agency', 'travel'],
  ['airport', 'travel'],
  ['insurance_agency', 'insurance'],
  ['electronics_store', 'shopping'],
  ['clothing_store', 'shopping'],
  ['shoe_store', 'shopping'],
  ['jewelry_store', 'shopping'],
  ['furniture_store', 'shopping'],
  ['home_goods_store', 'shopping'],
  ['department_store', 'shopping'],
  ['shopping_mall', 'shopping'],
  ['store', 'shopping'],
  ['car_repair', 'maintenance'],
  ['electrician', 'maintenance'],
  ['plumber', 'maintenance'],
  ['taxi_stand', 'transport'],
  ['transit_station', 'transport'],
  ['bus_station', 'transport'],
  ['subway_station', 'transport'],
  ['atm', 'cash'],
  ['bank', 'cash'],
];

function categoryForTypes(types: string[], primaryType?: string): string {
  if (primaryType) {
    for (const [type, category] of TYPE_TO_CATEGORY) {
      if (primaryType === type) return category;
    }
  }
  for (const [type, category] of TYPE_TO_CATEGORY) {
    if (types.includes(type)) return category;
  }
  return 'other';
}

function bestEffortCategoryForMerchant(merchantName: string): string {
  const upper = merchantName.toUpperCase();
  const hasAny = (needles: string[]) => needles.some((needle) => upper.includes(needle));

  if (hasAny(['CAFE', 'COFFEE', 'ESPRESSO', 'BAKERY', 'PATISSERIE', 'كافيه', 'قهوة', 'مخبز'])) {
    return 'cafes';
  }
  if (
    hasAny([
      'RESTAURANT',
      'REST',
      'BURGER',
      'PIZZA',
      'CHICKEN',
      'GRILL',
      'KITCHEN',
      'FOOD',
      'مطعم',
      'بيتزا',
      'برجر',
      'مشويات',
    ])
  ) {
    return 'restaurants';
  }
  if (hasAny(['MARKET', 'MART', 'GROCERY', 'SUPERMARKET', 'HYPER', 'BAQALA', 'بقالة', 'سوبر', 'ماركت'])) {
    return 'groceries';
  }
  if (hasAny(['PHARMACY', 'PHARMA', 'CLINIC', 'HOSPITAL', 'MEDICAL', 'صيدلية', 'عيادة', 'مستشفى'])) {
    return 'health';
  }
  if (hasAny(['PETROL', 'FUEL', 'GAS', 'STATION', 'بنزين', 'وقود'])) {
    return 'fuel';
  }
  if (hasAny(['UBER', 'CAREEM', 'TAXI', 'BUS', 'METRO', 'TRAIN', 'TRANSPORT', 'تاكسي', 'مترو', 'مواصلات'])) {
    return 'transport';
  }
  if (hasAny(['TELECOM', 'MOBILE', 'INTERNET', 'ELECTRIC', 'WATER', 'UTILITY', 'فاتورة', 'كهرباء', 'مياه', 'انترنت'])) {
    return 'bills';
  }
  if (hasAny(['GYM', 'FITNESS', 'SPORT', 'نادي', 'جيم'])) {
    return 'fitness';
  }
  if (hasAny(['SALON', 'BEAUTY', 'BARBER', 'SPA', 'صالون', 'حلاق'])) {
    return 'beauty';
  }
  if (hasAny(['HOTEL', 'AIR', 'TRAVEL', 'FLIGHT', 'TOUR', 'فندق', 'طيران', 'سفر'])) {
    return 'travel';
  }
  if (hasAny(['CINEMA', 'MOVIE', 'GAME', 'PLAY', 'سينما', 'العاب'])) {
    return 'entertainment';
  }
  return 'shopping';
}

const BANK_ATM_ALIASES = [
  'ATM',
  'BDC',
  'BDCBANK',
  'BANQUEDUCAIRE',
  'CIB',
  'CIBBANK',
  'CIBEG',
  'NBE',
  'AHLYBANK',
  'ALAHLYBANK',
  'NBEBANK',
  'NATBANK',
  'BM',
  'BMISR',
  'BANQUEMISR',
  'QNB',
  'QNBA',
  'QNBALAHLI',
  'ALEXBANK',
  'BOALEX',
  'AAIB',
  'HDB',
  'HDBANK',
  'FIB',
  'FIBEG',
  'ADIB',
  'ENBD',
  'HSBC',
  'SAIB',
  'FAB',
  'CAE',
  'EGB',
  'AUB',
];

function compactToken(value: string): string {
  return value.toUpperCase().replace(/[^A-Z0-9\u0600-\u06ff]+/g, '');
}

function looksLikeBankAtmQuery(value: string): boolean {
  const compact = compactToken(value);
  if (!compact) return false;
  return BANK_ATM_ALIASES.some((alias) => {
    const compactAlias = compactToken(alias);
    return compact === compactAlias || compact.startsWith(compactAlias);
  });
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

  // MALI-060n — a verified identity (device secret or user JWT), never the
  // caller-supplied install_id, selects the owner and rate-limit namespace.
  const identity = await resolveVerifiedIdentity(req, supabase, body, cid);
  if (!identity.ok) return identity.response;

  // Merchant enrichment sends the merchant name to Google Places (cloud
  // processing) — require the cloud-processing consent server-side.
  const consentBad = consentError(identity.identity, 'cloud', cid);
  if (consentBad) return consentBad;

  const limited = await bumpCaptureEndpointRateLimit(
    supabase,
    identity.identity.ownerKey,
    'enrich-merchant',
    DAILY_LIMIT_PER_IDENTITY,
  );
  if (limited) return apiError('rate_limited', { correlationId: cid, retryable: true });

  const merchantName = (body.merchant_name as string | undefined)?.trim();
  if (!merchantName) {
    return apiError('invalid_payload', { correlationId: cid });
  }
  if (merchantName.length > MAX_MERCHANT_LENGTH) {
    return apiError('payload_too_large', { correlationId: cid });
  }
  // The name goes to Google Places and into the GLOBAL merchant_keywords
  // catalogue. A "merchant" that carries an identifier (card, phone, IBAN,
  // account, reference, e-mail) is not a business name — refuse it before
  // either egress rather than store a person's identifier for every device.
  if (redactPii(merchantName) !== merchantName) {
    return apiError('invalid_payload', { correlationId: cid });
  }
  const countryCode = ((body.country_code as string | undefined) ?? 'ALL')
    .toUpperCase();
  const write = body.write !== false; // default true
  const bankAtmLike = looksLikeBankAtmQuery(merchantName);

  // Idempotency (MALI-060n): a stable request_id makes a retry reuse the stored
  // category instead of re-calling the paid Places API. Only a payload hash +
  // the small {category} result are stored, expiring by TTL.
  const requestId = readString(body, 'request_id', 'requestId');
  let idempotencyClaimed = false;
  if (requestId) {
    const hash = await payloadHash([
      identity.identity.ownerKey,
      'enrich-merchant',
      merchantName.toUpperCase(),
      countryCode,
    ]);
    const claim = await claimIdempotency(supabase, identity.identity.ownerKey, 'enrich-merchant', requestId, hash);
    if (claim.outcome === 'mismatch') {
      return apiError('request_replay_mismatch', { correlationId: cid });
    }
    if (claim.outcome === 'exists') {
      if (claim.status === 'succeeded' && typeof claim.result.category === 'string') {
        return new Response(
          JSON.stringify({
            merchant_name: merchantName,
            category: claim.result.category,
            matched: true,
            written: false,
          }),
          { headers: { 'Content-Type': 'application/json', ...corsHeaders } },
        );
      }
      return apiError('upstream_unavailable', { correlationId: cid, retryable: true, retryAfterSeconds: 3 });
    }
    idempotencyClaimed = claim.outcome === 'claimed';
  }
  let placeName = '';
  let category = 'other';

  if (!MAPS_API_KEY) {
    category = bestEffortCategoryForMerchant(merchantName);
    placeName = merchantName;
  } else {
    // ── Google Places Text Search ──────────────────────────────────────────────
    try {
      const region = countryCode.length === 2 ? countryCode : undefined;
      const placesRes = await fetchWithTimeout(PLACES_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': MAPS_API_KEY,
          'X-Goog-FieldMask': 'places.displayName,places.primaryType,places.types',
        },
        body: JSON.stringify({
          textQuery: merchantName,
          maxResultCount: 1,
          ...(region ? { regionCode: region } : {}),
        }),
      }, PLACES_TIMEOUT_MS);
      if (!placesRes.ok) throw new Error(`places_${placesRes.status}`);
      const json = await placesRes.json();
      const place = json?.places?.[0];
      if (!place) {
        placeName = merchantName;
        category = bankAtmLike ? 'cash' : bestEffortCategoryForMerchant(merchantName);
      } else {
        placeName = place?.displayName?.text ?? merchantName;
        category = categoryForTypes(
          (place?.types as string[]) ?? [],
          place?.primaryType as string | undefined,
        );
        if (bankAtmLike && (category === 'other' || category === 'bills')) {
          category = 'cash';
        }
        if (category === 'other') {
          category = bestEffortCategoryForMerchant(merchantName);
        }
      }
    } catch {
      placeName = merchantName;
      category = bankAtmLike ? 'cash' : bestEffortCategoryForMerchant(merchantName);
    }
  }

  // ── Upsert into merchant_keywords (admin-managed catalog) ───────────────────
  if (write) {
    const keyword = merchantName.toUpperCase();
    const { data: existing } = await supabase
      .from('merchant_keywords')
      .select('id')
      .eq('keyword', keyword)
      .maybeSingle();

    const row = {
      keyword,
      category_key: category,
      country_code: countryCode,
      language: 'any',
      priority: 0,
      is_active: true,
      is_deleted: false,
      updated_at: new Date().toISOString(),
    };
    const { error: writeError } = existing?.id
      ? await supabase.from('merchant_keywords').update(row).eq('id', existing.id)
      : await supabase.from('merchant_keywords').insert(row);
    if (writeError) {
      // MALI-060n/039 — never echo the merchant name or upstream error text.
      if (idempotencyClaimed) {
        await completeIdempotency(supabase, identity.identity.ownerKey, 'enrich-merchant', requestId, 'failed', {});
      }
      return apiError('internal_error', { correlationId: cid });
    }
  }

  if (idempotencyClaimed) {
    await completeIdempotency(supabase, identity.identity.ownerKey, 'enrich-merchant', requestId, 'succeeded', {
      category,
    });
  }

  return new Response(
    JSON.stringify({
      merchant_name: merchantName,
      place_name: placeName,
      category,
      matched: true,
      written: write,
    }),
    { headers: { 'Content-Type': 'application/json', ...corsHeaders } },
  );
});
