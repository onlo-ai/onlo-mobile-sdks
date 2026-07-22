import assert from 'node:assert/strict';
import test from 'node:test';

import { mintOnloUserJwt } from '../src/jwt.mjs';

test('mints a short-lived HS256 Onlo proof with only required claims', () => {
  const jwt = mintOnloUserJwt({
    subject: 'synthetic-customer-a',
    signingSecret: 'synthetic-local-signing-material',
    nowSeconds: 1_700_000_000,
  });
  const [encodedHeader, encodedPayload, signature] = jwt.split('.');
  const header = JSON.parse(Buffer.from(encodedHeader, 'base64url').toString('utf8'));
  const payload = JSON.parse(Buffer.from(encodedPayload, 'base64url').toString('utf8'));

  assert.deepEqual(header, { alg: 'HS256', typ: 'JWT' });
  assert.deepEqual(payload, {
    aud: 'onlo-messenger',
    sub: 'synthetic-customer-a',
    iat: 1_700_000_000,
    exp: 1_700_000_180,
  });
  assert.ok(signature.length > 0);
});
