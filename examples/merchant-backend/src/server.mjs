import { request as httpRequest } from 'node:http';
import { createServer, request as httpsRequest } from 'node:https';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { appendFileSync, readFileSync } from 'node:fs';

import { mintOnloUserJwt } from './jwt.mjs';

const MAX_BODY_BYTES = 4096;
const MAX_SESSION_RESPONSE_INSPECTION_BYTES = 64 * 1024;
const SESSION_LIFETIME_MS = 5 * 60 * 1000;
const LOCAL_TEST_SUBJECT = 'sdk-local-test-user';
const configuration = loadConfiguration(process.env);
const merchantSessions = new Map();

createServer(
  {
    cert: readFileSync(configuration.tlsCertificatePath),
    key: readFileSync(configuration.tlsKeyPath),
    minVersion: 'TLSv1.2',
  },
  async (request, response) => {
    const startedAt = Date.now();
    response.once('finish', () => {
      safeLog('merchant_http', safeHTTPStatus(response.statusCode), elapsedMs(startedAt));
    });
    try {
      await handle(request, response);
    } catch {
      safeLog('merchant_request', 'unexpected_error');
      respond(response, 500, { error: 'local_merchant_backend_error' });
    }
  },
).listen(configuration.port, '127.0.0.1', () => {
  console.log(`Local merchant backend listening on https://127.0.0.1:${configuration.port}`);
  safeLog('merchant_backend_started', 'ready');
});

createServer(
  {
    cert: readFileSync(configuration.tlsCertificatePath),
    key: readFileSync(configuration.tlsKeyPath),
    minVersion: 'TLSv1.2',
  },
  proxyToLocalOnlo,
).listen(configuration.onloProxyPort, '127.0.0.1', () => {
  console.log(`Local Onlo HTTPS proxy listening on https://127.0.0.1:${configuration.onloProxyPort}`);
  console.log(`Safe diagnostics: ${configuration.safeLogPath}`);
  safeLog('onlo_proxy_started', 'ready');
});

async function handle(request, response) {
  if (request.method !== 'POST') return respond(response, 405, { error: 'method_not_allowed' });

  if (request.url === '/v1/test-login') {
    safeLog('merchant_login', 'requested');
    const body = await readJson(request);
    if (!isLoginCodeValid(body.loginCode, configuration.loginCode)) {
      safeLog('merchant_login', 'rejected');
      return respond(response, 401, { error: 'unauthorized' });
    }
    const merchantSession = randomBytes(32).toString('base64url');
    merchantSessions.set(merchantSession, { customer: LOCAL_TEST_SUBJECT, expiresAt: Date.now() + SESSION_LIFETIME_MS });
    safeLog('merchant_login', 'issued_jwt');
    return respond(response, 200, {
      merchantSession,
      sdkKey: configuration.sdkKey,
      onloDevelopmentOrigin: configuration.onloDevelopmentOrigin,
      userJwt: mintOnloUserJwt({ subject: LOCAL_TEST_SUBJECT, signingSecret: configuration.onloIdentitySecret, profile: configuration.localTestProfile }),
    });
  }

  if (request.url === '/v1/onlo-user-jwt') {
    await readJson(request);
    const merchantSession = bearer(request.headers.authorization);
    const session = merchantSession ? merchantSessions.get(merchantSession) : undefined;
    if (!session || session.expiresAt <= Date.now()) {
      if (merchantSession) merchantSessions.delete(merchantSession);
      safeLog('merchant_jwt', 'rejected');
      return respond(response, 401, { error: 'unauthorized' });
    }
    safeLog('merchant_jwt', 'issued');
    return respond(response, 200, {
      userJwt: mintOnloUserJwt({ subject: session.customer, signingSecret: configuration.onloIdentitySecret, profile: configuration.localTestProfile }),
    });
  }

  return respond(response, 404, { error: 'not_found' });
}

function loadConfiguration(environment) {
  const nodeEnvironment = environment.NODE_ENVIRONMENT;
  if (nodeEnvironment !== 'development') {
    throw new Error('fixed-user local merchant backend supports development only');
  }
  const port = Number(environment.MERCHANT_BACKEND_PORT ?? '8444');
  const onloProxyPort = Number(environment.ONLO_TLS_PROXY_PORT ?? '8443');
  const required = [
    'MERCHANT_BACKEND_TLS_CERT_PATH',
    'MERCHANT_BACKEND_TLS_KEY_PATH',
    'MERCHANT_BACKEND_LOGIN_CODE',
    'MERCHANT_BACKEND_LOGIN_USERNAME',
    'MERCHANT_BACKEND_LOGIN_EMAIL',
    'ONLO_MOBILE_IDENTITY_SECRET',
    'ONLO_SDK_KEY',
    'ONLO_DEVELOPMENT_ORIGIN',
    'MERCHANT_BACKEND_SAFE_LOG_PATH',
  ];
  for (const name of required) {
    if (typeof environment[name] !== 'string' || environment[name].trim() === '') {
      throw new Error(`missing required local configuration: ${name}`);
    }
  }
  if (!Number.isInteger(port) || port < 1024 || port > 65535 ||
      !Number.isInteger(onloProxyPort) || onloProxyPort < 1024 || onloProxyPort > 65535 ||
      port === onloProxyPort) {
    throw new Error('invalid local proxy or merchant backend port');
  }
  if (environment.MERCHANT_BACKEND_LOGIN_USERNAME.length > 200 ||
      environment.MERCHANT_BACKEND_LOGIN_EMAIL.length > 254) {
    throw new Error('local test profile exceeds the mobile identity contract');
  }
  const onloUpstreamOrigin = new URL(environment.ONLO_DEVELOPMENT_ORIGIN);
  if (onloUpstreamOrigin.protocol !== 'http:' && onloUpstreamOrigin.protocol !== 'https:') {
    throw new Error('local Onlo upstream origin must use HTTP or HTTPS');
  }
  return {
    nodeEnvironment,
    port,
    tlsCertificatePath: environment.MERCHANT_BACKEND_TLS_CERT_PATH,
    tlsKeyPath: environment.MERCHANT_BACKEND_TLS_KEY_PATH,
    loginCode: environment.MERCHANT_BACKEND_LOGIN_CODE,
    onloIdentitySecret: environment.ONLO_MOBILE_IDENTITY_SECRET,
    sdkKey: environment.ONLO_SDK_KEY,
    localTestProfile: Object.freeze({
      name: environment.MERCHANT_BACKEND_LOGIN_USERNAME,
      email: environment.MERCHANT_BACKEND_LOGIN_EMAIL,
      locale: 'en',
    }),
    onloDevelopmentOrigin: `https://127.0.0.1:${onloProxyPort}`,
    onloProxyPort,
    onloUpstreamOrigin,
    safeLogPath: environment.MERCHANT_BACKEND_SAFE_LOG_PATH,
  };
}

function proxyToLocalOnlo(request, response) {
  const startedAt = Date.now();
  const upstream = configuration.onloUpstreamOrigin;
  const route = safeRouteCategory(request.url);
  safeLog(`proxy_${route}`, 'started');
  const requester = upstream.protocol === 'https:' ? httpsRequest : httpRequest;
  const upstreamPath = `${upstream.pathname.replace(/\/$/, '')}${request.url ?? '/'}`;
  const upstreamRequest = requester({
    protocol: upstream.protocol,
    hostname: upstream.hostname,
    port: upstream.port || undefined,
    method: request.method,
    path: upstreamPath,
    headers: { ...request.headers, host: upstream.host },
  }, (upstreamResponse) => {
    safeLog(`proxy_${route}`, safeHTTPStatus(upstreamResponse.statusCode), elapsedMs(startedAt));
    const sessionResponse = route === 'session' ? createSafeSessionResponseInspector() : null;
    if (sessionResponse) {
      upstreamResponse.on('data', (chunk) => sessionResponse.observe(chunk));
      upstreamResponse.on('end', () => safeLog('proxy_session_result', sessionResponse.classification(), elapsedMs(startedAt)));
      upstreamResponse.on('error', () => safeLog('proxy_session_result', 'stream_error', elapsedMs(startedAt)));
    }
    response.writeHead(upstreamResponse.statusCode ?? 502, upstreamResponse.headers);
    upstreamResponse.pipe(response);
  });
  upstreamRequest.on('error', () => {
    safeLog(`proxy_${route}`, 'upstream_unavailable', elapsedMs(startedAt));
    if (!response.headersSent) respond(response, 502, { error: 'local_onlo_unavailable' });
    else response.destroy();
  });
  request.pipe(upstreamRequest);
}

function createSafeSessionResponseInspector() {
  const chunks = [];
  let byteLength = 0;
  let exceededLimit = false;
  return {
    observe(chunk) {
      if (exceededLimit) return;
      byteLength += chunk.length;
      if (byteLength > MAX_SESSION_RESPONSE_INSPECTION_BYTES) {
        exceededLimit = true;
        chunks.length = 0;
        return;
      }
      chunks.push(Buffer.from(chunk));
    },
    classification() {
      if (exceededLimit) return 'body_too_large';
      try {
        const payload = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (payload?.ok === false && typeof payload.error?.code === 'string') {
          return `error_${safeContractCode(payload.error.code)}`;
        }
        if (payload?.ok !== true) return 'invalid_envelope';
        if (payload.result?.identityClass === 'identified') return 'identified';
        if (payload.result?.identityClass === 'anonymous') return 'anonymous';
        return 'invalid_identity_class';
      } catch {
        return 'invalid_json';
      }
    },
  };
}

function safeContractCode(value) {
  return /^[a-z_]{1,64}$/.test(value) ? value : 'invalid_code';
}

function safeRouteCategory(rawPath) {
  const path = typeof rawPath === 'string' ? rawPath.split('?', 1)[0] : '';
  if (path === '/api/sdk/v1/session') return 'session';
  if (path === '/api/sdk/v1/config') return 'config';
  if (path === '/api/sdk/v1/push-token') return 'push';
  if (path.includes('/attachments')) return 'attachment';
  if (path.includes('/stream')) return 'stream';
  if (path.includes('/conversations')) return 'conversation';
  if (path.includes('/chat')) return 'chat';
  return 'other';
}

function safeHTTPStatus(status) {
  return Number.isInteger(status) && status >= 100 && status <= 599 ? `http_${status}` : 'invalid_status';
}

function safeLog(operation, code, durationMs) {
  const durationField = Number.isFinite(durationMs)
    ? ` durationMs=${Math.max(0, Math.round(durationMs))}`
    : '';
  try {
    appendFileSync(
      configuration.safeLogPath,
      `${new Date().toISOString()} operation=${operation} code=${code}${durationField}\n`,
      { encoding: 'utf8', mode: 0o600 },
    );
  } catch {
    // Diagnostics must never change the simulated merchant flow.
  }
}

function elapsedMs(startedAt) {
  return Date.now() - startedAt;
}

function isLoginCodeValid(candidate, expected) {
  if (typeof candidate !== 'string') return false;
  const candidateBytes = Buffer.from(candidate);
  const expectedBytes = Buffer.from(expected);
  return candidateBytes.length === expectedBytes.length && timingSafeEqual(candidateBytes, expectedBytes);
}

function bearer(value) {
  if (typeof value !== 'string' || !value.startsWith('Bearer ')) return null;
  const valueAfterPrefix = value.slice('Bearer '.length);
  return valueAfterPrefix.length > 0 ? valueAfterPrefix : null;
}

async function readJson(request) {
  const chunks = [];
  let byteLength = 0;
  for await (const chunk of request) {
    byteLength += chunk.length;
    if (byteLength > MAX_BODY_BYTES) throw new Error('request_too_large');
    chunks.push(chunk);
  }
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (!value || Array.isArray(value) || typeof value !== 'object') throw new Error('invalid_json');
    return value;
  } catch {
    throw new Error('invalid_json');
  }
}

function respond(response, status, body) {
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(JSON.stringify(body));
}
