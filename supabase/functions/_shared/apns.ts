import { buildApnsCollapseId } from './apns_collapse_id.ts';

export type ApnsEnvironment = 'sandbox' | 'production';

type ApnsMessage = {
  token: string;
  environment: ApnsEnvironment;
  payloadId: string;
  /// Empty omits the alert title (generic capture pushes carry a body only).
  title: string;
  body: string;
  notificationType: string;
  transactionId?: string;
  smartInboxItemId?: string;
  /// The `notification_logs.id` this push was logged under.
  ///
  /// Without it a TAP cannot be attributed: the client's open-sync upserts by
  /// this exact server id (`onConflict: 'id'`), and the device has no other way
  /// to learn it. A real iPhone tap was observed routing correctly while
  /// `opened_at` stayed null for every APNs row, because this key was missing.
  /// Optional so a caller that genuinely has no log row still sends the push.
  notificationLogId?: string;
};

export type ApnsResult =
  | { ok: true; apnsId: string | null }
  | { ok: false; reason: string; httpStatus: number | null; errorCode: string };

const encoder = new TextEncoder();
let cachedJwt: { token: string; expiresAt: number } | null = null;

export function sendCapturePush(message: ApnsMessage): Promise<ApnsResult> {
  return sendApnsAlert({
    token: message.token,
    environment: message.environment,
    collapseKey: message.payloadId,
    title: message.title,
    body: message.body,
    data: {
      payloadId: message.payloadId,
      transactionId: message.transactionId ?? '',
      smartInboxItemId: message.smartInboxItemId ?? '',
      notificationLogId: message.notificationLogId ?? '',
      notificationType: message.notificationType,
      source: 'ios_shortcut',
    },
  });
}

/// One APNs alert. `data` is the custom payload placed beside `aps`; capture
/// pushes and admin broadcasts differ only there. Fails closed with
/// `apns_not_configured` when any credential is missing (nothing is sent).
export async function sendApnsAlert(message: {
  token: string;
  environment: ApnsEnvironment;
  /// Hashed into apns-collapse-id: a resend with the same key replaces the banner.
  collapseKey: string;
  /// Empty omits the alert title.
  title: string;
  body: string;
  data: Record<string, string>;
}): Promise<ApnsResult> {
  const keyId = Deno.env.get('APNS_KEY_ID') ?? '';
  const teamId = Deno.env.get('APNS_TEAM_ID') ?? '';
  const bundleId = Deno.env.get('APNS_BUNDLE_ID') ?? '';
  const privateKey = Deno.env.get('APNS_PRIVATE_KEY') ?? '';
  if (!keyId || !teamId || !bundleId || !privateKey) {
    return {
      ok: false,
      reason: 'apns_not_configured',
      httpStatus: null,
      errorCode: 'not_configured',
    };
  }

  try {
    const jwt = await apnsJwt({ keyId, teamId, privateKey });
    const collapseId = await buildApnsCollapseId(message.collapseKey);
    const host = message.environment === 'sandbox'
      ? 'https://api.sandbox.push.apple.com'
      : 'https://api.push.apple.com';
    // Bounded so the whole process-ios-sms request stays inside the App
    // Intent's 8s client budget — an APNs hang otherwise guarantees a client
    // timeout and a duplicate local fallback banner.
    const response = await fetch(`${host}/3/device/${message.token}`, {
      signal: AbortSignal.timeout(2500),
      method: 'POST',
      headers: {
        authorization: `bearer ${jwt}`,
        'apns-topic': bundleId,
        'apns-push-type': 'alert',
        'apns-priority': '10',
        'apns-collapse-id': collapseId,
        'content-type': 'application/json',
      },
      body: JSON.stringify({
        aps: {
          alert: message.title
            ? { title: message.title, body: message.body }
            : { body: message.body },
          sound: 'default',
        },
        ...message.data,
      }),
    });
    if (!response.ok) {
      const reason = await safeReason(response);
      return {
        ok: false,
        reason: `apns_${response.status}_${reason}`,
        httpStatus: response.status,
        errorCode: reason,
      };
    }
    return { ok: true, apnsId: response.headers.get('apns-id') };
  } catch (error) {
    const isTimeout = error instanceof DOMException && error.name === 'TimeoutError';
    return {
      ok: false,
      // The error text can embed the request URL, which contains the device token.
      reason: `apns_exception_${error instanceof Error ? error.name : 'unknown'}`,
      httpStatus: null,
      errorCode: isTimeout ? 'timeout' : 'network_exception',
    };
  }
}

async function apnsJwt(input: {
  keyId: string;
  teamId: string;
  privateKey: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && cachedJwt.expiresAt > now + 60) return cachedJwt.token;

  const header = base64UrlJson({ alg: 'ES256', kid: input.keyId });
  const claims = base64UrlJson({ iss: input.teamId, iat: now });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToArrayBuffer(input.privateKey),
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['sign'],
  );
  const derSignature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      key,
      encoder.encode(signingInput),
    ),
  );
  const jwt = `${signingInput}.${base64Url(derSignature)}`;
  cachedJwt = { token: jwt, expiresAt: now + 20 * 60 };
  return jwt;
}

function base64UrlJson(value: Record<string, unknown>): string {
  return base64Url(encoder.encode(JSON.stringify(value)));
}

function base64Url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, '')
    .replace(/-----END PRIVATE KEY-----/g, '')
    .replace(/\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function safeReason(response: Response): Promise<string> {
  try {
    const data = await response.json();
    return String(data?.reason ?? 'failed').slice(0, 80);
  } catch (_) {
    return 'failed';
  }
}
