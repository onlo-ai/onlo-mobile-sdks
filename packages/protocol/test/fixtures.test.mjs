import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const root = new URL('../../../', import.meta.url);

async function fixture(name) {
  return JSON.parse(await readFile(new URL(`contracts/v1/${name}`, root), 'utf8'));
}

const capabilities = new Set([
  'secure_storage', 'persistent_outbox', 'foreground_stream', 'apns', 'fcm',
  'media_picker', 'attachment_upload', 'config_schema_v1', 'identity_jwt',
  'app_attestation', 'deep_link_routing',
]);
const errorCodes = new Set([
  'invalid_request', 'invalid_target_key', 'sdk_not_available', 'target_disabled',
  'incompatible_client', 'proof_required', 'invalid_proof', 'expired_proof',
  'identity_disabled', 'attestation_required', 'invalid_attestation', 'session_expired',
  'session_revoked', 'forbidden_principal', 'stale_cursor', 'idempotency_conflict',
  'config_unavailable', 'media_unavailable', 'rate_limited', 'dependency_unavailable',
]);
const retryDirectives = new Set([
  'never', 'after_token_refresh', 'after_attestation', 'after_backoff', 'after_full_sync',
]);

test('discovery fixture is a v1 envelope with only declared capabilities', async () => {
  const value = await fixture('discovery.response.json');
  assert.equal(value.ok, true);
  assert.equal(value.protocolVersion, 1);
  assert.equal(value.minimumProtocolVersion, 1);
  assert.equal(value.result.manifest.manifestVersion, 1);
  for (const capability of value.result.manifest.capabilities) assert.ok(capabilities.has(capability.id));
});

test('failure and retry fixtures stay within the complete v1 unions', async () => {
  const failure = await fixture('error.response.json');
  const retries = await fixture('error.retry-directives.json');
  assert.equal(failure.ok, false);
  assert.ok(errorCodes.has(failure.error.code));
  for (const retry of retries) {
    assert.ok(retryDirectives.has(retry.directive));
    if (retry.retryAfterMs !== undefined) {
      assert.ok(Number.isInteger(retry.retryAfterMs) && retry.retryAfterMs >= 0);
    }
  }
});

test('conditional config fixtures preserve the documented cache boundary', async () => {
  const request = await fixture('config.request.json');
  const response = await fixture('config.response.json');
  const notModified = await fixture('config.not-modified.response.json');
  assert.equal(request.path, '/api/sdk/v1/config');
  assert.equal(request.headers['X-Onlo-Config-Schema'], '1');
  assert.equal(response.ok, true);
  assert.equal(response.result.schemaVersion, 1);
  assert.deepEqual(response.result.mediaPolicy, {
    enabled: true,
    maximumImagesPerMessage: 5,
    maximumImageBytes: 8 * 1024 * 1024,
  });
  assert.deepEqual(notModified, {
    status: 304,
    headers: { ETag: 'W/"mobile-config-example"' },
    body: null,
  });
  for (const capability of response.result.compatibility.capabilities) assert.ok(capabilities.has(capability));
});

test('attachment fixture enforces the image-only v1 boundary', async () => {
  const config = await fixture('config.response.json');
  const policy = config.result.mediaPolicy;
  const intents = await Promise.all([
    fixture('attachments.intent.request.json'),
    fixture('attachments.intent.png.request.json'),
    fixture('attachments.intent.webp.request.json'),
  ]);
  assert.deepEqual(intents.map((intent) => intent.mimeType), ['image/jpeg', 'image/png', 'image/webp']);
  assert.equal(intents[1].byteSize, 1);
  assert.equal(intents[2].byteSize, 8 * 1024 * 1024);
  for (const intent of intents) {
    assert.ok(intent.byteSize > 0 && intent.byteSize <= policy.maximumImageBytes);
    assert.match(intent.sha256, /^[a-f0-9]{64}$/);
  }
  assert.ok(policy.maximumImagesPerMessage >= 0 && policy.maximumImagesPerMessage <= 5);
  assert.ok(policy.maximumImageBytes >= 1 && policy.maximumImageBytes <= 8 * 1024 * 1024);
});

test('chat and foreground stream fixtures cover every declared event variant', async () => {
  const chatEvents = await fixture('chat.events.json');
  const streamEvents = await fixture('stream.events.json');
  assert.deepEqual(new Set(chatEvents.map((event) => event.type)), new Set(['accepted', 'text', 'done', 'error']));
  assert.ok(chatEvents.some((event) => event.type === 'accepted' && event.duplicate === true));
  assert.ok(chatEvents.some((event) => event.type === 'done' && event.gated === true && typeof event.reason === 'string'));
  assert.deepEqual(streamEvents.map((event) => event.type), [
    'ready', 'config_changed', 'inbox.conversation', 'inbox.message',
  ]);
  assert.deepEqual(await fixture('widget.error.response.json'), { error: 'synthetic_widget_error' });
});

test('identified unread fixtures preserve render-before-acknowledgement semantics', async () => {
  const list = await fixture('conversations.list.response.json');
  const request = await fixture('conversations.read.request.json');
  const response = await fixture('conversations.read.response.json');
  assert.ok(Number.isInteger(list.totalUnreadCount) && list.totalUnreadCount >= 0);
  for (const conversation of list.conversations) {
    assert.ok(Number.isInteger(conversation.unreadCount) && conversation.unreadCount >= 0);
    assert.equal(conversation.unread, conversation.unreadCount > 0);
  }
  assert.equal(request.throughMessageId, response.readThroughMessageId);
  assert.equal(response.unread, false);
  assert.equal(response.unreadCount, 0);
});

test('push fixtures cover APNs, FCM, and unregister variants', async () => {
  const requests = await Promise.all([
    fixture('push-token.register.request.json'),
    fixture('push-token.register-fcm.request.json'),
  ]);
  const responses = await Promise.all([
    fixture('push-token.register.response.json'),
    fixture('push-token.register-fcm.response.json'),
  ]);
  assert.deepEqual(requests.map((request) => request.provider), ['apns', 'fcm']);
  assert.deepEqual(responses.map((response) => response.result.provider), ['apns', 'fcm']);
  assert.deepEqual(await fixture('push-token.unregister.request.json'), { action: 'unregister' });
  assert.deepEqual((await fixture('push-token.unregister.response.json')).result, { state: 'inactive' });
});

test('lost session responses retry the exact v1 operation without persisting identity proof', async () => {
  const operations = await fixture('session.idempotent-retry.operations.json');
  const exactKeys = {
    bootstrap: ['proposedCredential', 'transitionId', 'type'],
    resume: ['expectedGeneration', 'presentedCredential', 'proposedCredential', 'transitionId', 'type'],
    identify: ['expectedGeneration', 'presentedCredential', 'proposedCredential', 'transitionId', 'type', 'userJwt'],
    logout: ['expectedGeneration', 'presentedCredential', 'proposedCredential', 'transitionId', 'type'],
  };

  for (const [name, expectedKeys] of Object.entries(exactKeys)) {
    const attempts = operations[name];
    assert.deepEqual(attempts.retry, attempts.initial, `${name} retry must be the same logical operation`);
    assert.deepEqual(Object.keys(attempts.initial).sort(), expectedKeys.sort(), `${name} must use only declared operation fields`);
    assert.equal(attempts.initial.type, name);
  }

  assert.equal(operations.identify.initial.userJwt, 'synthetic.in-memory.signature');
  assert.deepEqual(Object.keys(operations.identify.initial).sort(), exactKeys.identify.sort());
});
