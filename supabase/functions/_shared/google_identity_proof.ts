import { createRemoteJWKSet, errors, jwtVerify } from 'npm:jose@6.1.0';

const keys = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));
const iosAudience = '881903820931-c4cttgekf9d3tcv3j2lt10ao2upk4b1m.apps.googleusercontent.com';
const webAudience = '881903820931-vhhlh6t1587uioq5pgp8faaaa2esgfm2.apps.googleusercontent.com';

export async function verifyGoogleProof(
  token: string,
  nonce: string,
): Promise<string | null> {
  return await verifyGoogleIdentity(token, iosAudience, nonce);
}

export async function verifyGoogleEnrollment(
  token: string,
  nonce: string | null,
): Promise<string | null> {
  if (nonce === null) return await verifyGoogleIdentity(token, webAudience, null);
  if (!/^[0-9a-f]{64}$/.test(nonce)) return null;
  return await verifyGoogleIdentity(token, iosAudience, nonce);
}

async function verifyGoogleIdentity(
  token: string,
  audience: string,
  nonce: string | null,
): Promise<string | null> {
  try {
    const { payload } = await jwtVerify(token, keys, {
      algorithms: ['RS256'],
      issuer: ['https://accounts.google.com', 'accounts.google.com'],
      audience,
      requiredClaims: ['exp', 'iat', 'sub', ...(nonce === null ? [] : ['nonce'])],
      maxTokenAge: '5 minutes',
      clockTolerance: 10,
    });
    return (nonce === null || payload.nonce === nonce) &&
        typeof payload.sub === 'string' && /^[0-9]{1,255}$/.test(payload.sub)
      ? payload.sub
      : null;
  } catch (error) {
    if (error instanceof errors.JOSEError &&
        !(error instanceof errors.JWKSTimeout) &&
        !(error instanceof errors.JWKSInvalid) &&
        error.code !== 'ERR_JOSE_GENERIC') return null;
    throw new Error('google_key_unavailable');
  }
}
