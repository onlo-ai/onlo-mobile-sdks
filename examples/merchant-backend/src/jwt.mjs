import { createHmac } from 'node:crypto';

function base64url(value) {
  return Buffer.from(value).toString('base64url');
}

/**
 * Creates only the HS256 proof accepted by the documented mobile v1 contract.
 * The secret belongs to this local merchant service, never to a mobile app.
 */
export function mintOnloUserJwt({ subject, signingSecret, nowSeconds, profile }) {
  if (!isValidSubject(subject) || typeof signingSecret !== 'string' || signingSecret.length === 0) {
    throw new Error('invalid local merchant configuration');
  }

  const issuedAt = nowSeconds ?? Math.floor(Date.now() / 1000);
  const profileClaims = validatedProfileClaims(profile);
  const header = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const payload = base64url(JSON.stringify({
    aud: 'onlo-messenger',
    sub: subject,
    iat: issuedAt,
    exp: issuedAt + 180,
    ...profileClaims,
  }));
  const signingInput = `${header}.${payload}`;
  const signature = createHmac('sha256', signingSecret).update(signingInput).digest('base64url');
  return `${signingInput}.${signature}`;
}

function validatedProfileClaims(profile) {
  if (profile === undefined) return {};
  if (!profile || typeof profile !== 'object' || Array.isArray(profile)) {
    throw new Error('invalid local merchant profile');
  }
  const claims = {};
  if (profile.name !== undefined) {
    if (typeof profile.name !== 'string' || profile.name.length > 200) throw new Error('invalid local merchant profile');
    claims.name = profile.name;
  }
  if (profile.email !== undefined) {
    if (typeof profile.email !== 'string' || profile.email.length > 254) throw new Error('invalid local merchant profile');
    claims.email = profile.email;
  }
  if (profile.locale !== undefined) {
    if (typeof profile.locale !== 'string' || profile.locale.length > 35) throw new Error('invalid local merchant profile');
    claims.locale = profile.locale;
  }
  return claims;
}

function isValidSubject(value) {
  return typeof value === 'string' &&
    value.length >= 1 &&
    value.length <= 255 &&
    value.trim() === value &&
    !/[\u0000-\u001f\u007f]/.test(value);
}
