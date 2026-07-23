import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(process.env.ONLO_FACADE_PATH, 'utf8');

function loadFacade(nativeModule) {
  const exports = {};
  new Function('exports', 'require', source)(exports, (name) => {
    assert.equal(name, './NativeOnloSDK');
    return { __esModule: true, default: nativeModule };
  });
  return exports;
}

function createNativeModule() {
  const calls = [];
  const listeners = new Set();
  return {
    calls,
    setLogLevel: async (level) => calls.push(['setLogLevel', level]),
    initialize: async (options) => calls.push(['initialize', options]),
    loginUnidentifiedUser: async () => calls.push(['loginUnidentifiedUser']),
    loginIdentifiedUser: async (options) => calls.push(['loginIdentifiedUser', options]),
    logout: async () => calls.push(['logout']),
    present: async (options) => calls.push(['present', options]),
    dismiss: async () => calls.push(['dismiss']),
    openConversation: async (conversationId) => calls.push(['openConversation', conversationId]),
    setPushToken: async (options) => calls.push(['setPushToken', options]),
    handlePushNotification: async (payload) => {
      calls.push(['handlePushNotification', payload]);
      return 'handled';
    },
    onOnloEvent: (callback) => {
      listeners.add(callback);
      return { remove() { listeners.delete(callback); } };
    },
    emit: (event) => listeners.forEach((listener) => listener(event)),
  };
}

test('validates initialization and forwards valid calls directly to native', async () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);

  await Onlo.setLogLevel('verbose');
  await assert.rejects(Onlo.initialize({ sdkKey: ' ' }), { code: 'invalid_argument' });
  await Onlo.initialize({ sdkKey: 'onlo_rn_sk_example' });
  await Onlo.loginUnidentifiedUser();
  await Onlo.loginIdentifiedUser({ userJwt: 'header.payload.signature' });
  await Onlo.present({ conversationId: 'synthetic-conversation' });
  await Onlo.dismiss();
  await Onlo.openConversation('synthetic-conversation');
  await Onlo.setPushToken({
    provider: 'apns',
    token: 'synthetic-push-token',
    notificationPreference: 'enabled',
    locale: 'en',
  });
  const pushResult = await Onlo.handlePushNotification({
    conversationId: 'synthetic-conversation',
    messageId: 'synthetic-message',
    notificationType: 'message_available',
  });
  await Onlo.logout();

  assert.equal(pushResult, 'handled');

  assert.deepEqual(native.calls, [
    ['setLogLevel', 'verbose'],
    ['initialize', { sdkKey: 'onlo_rn_sk_example' }],
    ['loginUnidentifiedUser'],
    ['loginIdentifiedUser', { userJwt: 'header.payload.signature' }],
    ['present', { conversationId: 'synthetic-conversation' }],
    ['dismiss'],
    ['openConversation', 'synthetic-conversation'],
    ['setPushToken', {
      provider: 'apns',
      token: 'synthetic-push-token',
      notificationPreference: 'enabled',
      locale: 'en',
    }],
    ['handlePushNotification', {
      conversationId: 'synthetic-conversation',
      messageId: 'synthetic-message',
      notificationType: 'message_available',
    }],
    ['logout'],
  ]);
});

test('rejects non-compact JWTs without calling native', async () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.loginIdentifiedUser({ userJwt: 'not-a-jwt' }), { code: 'invalid_argument' });
  assert.deepEqual(native.calls, []);
});

test('rejects unsupported log levels before calling native', async () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.setLogLevel('trace'), { code: 'invalid_argument' });
  assert.deepEqual(native.calls, []);
});

test('rejects invalid presentation and push input before calling native', async () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.present({ conversationId: ' ' }), { code: 'invalid_argument' });
  await assert.rejects(Onlo.openConversation(''), { code: 'invalid_argument' });
  await assert.rejects(Onlo.setPushToken({ provider: 'web', token: 'synthetic' }), { code: 'invalid_argument' });
  await assert.rejects(Onlo.setPushToken({ provider: 'fcm', token: ' ' }), { code: 'invalid_argument' });
  await assert.rejects(Onlo.setPushToken({
    provider: 'fcm',
    token: 'synthetic',
    notificationPreference: 'unknown',
  }), { code: 'invalid_argument' });
  await assert.rejects(Onlo.handlePushNotification({
    conversationId: 'synthetic-conversation',
    messageId: 'synthetic-message',
    notificationType: 'unexpected',
  }), { code: 'invalid_argument' });

  assert.deepEqual(native.calls, []);
});

test('forwards only valid native events and removes subscriptions', () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);
  const events = [];
  const subscription = Onlo.addListener((event) => events.push(event));

  native.emit({ type: 'stateChanged', state: 'identifiedReady' });
  native.emit({ type: 'identityChanged', identity: 'identified' });
  native.emit({ type: 'connectionChanged', connection: 'ready' });
  native.emit({ type: 'unreadCountChanged', unreadCount: 2 });
  native.emit({ type: 'stateChanged', state: 'unknown' });
  subscription.remove();
  native.emit({ type: 'connectionChanged', connection: 'offline' });

  assert.deepEqual(events, [
    { type: 'stateChanged', state: 'identifiedReady' },
    { type: 'identityChanged', identity: 'identified' },
    { type: 'connectionChanged', connection: 'ready' },
    { type: 'unreadCountChanged', unreadCount: 2 },
  ]);
});

test('observes validated unread totals and anonymous badge clearing', () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);
  const values = [];
  const subscription = Onlo.observeUnreadCount((value) => values.push(value));

  native.emit({ type: 'unreadCountChanged', unreadCount: 3 });
  native.emit({ type: 'unreadCountChanged', unreadCount: -1 });
  native.emit({ type: 'unreadCountChanged', unreadCount: null });
  subscription.remove();

  assert.deepEqual(values, [3, null]);
});

test('provides focused identity and connection observations without retaining state in JS', () => {
  const native = createNativeModule();
  const { Onlo } = loadFacade(native);
  const identity = [];
  const connection = [];

  const identitySubscription = Onlo.observeIdentityState((value) => identity.push(value));
  const connectionSubscription = Onlo.observeConnectionState((value) => connection.push(value));

  native.emit({ type: 'identityChanged', identity: 'anonymous' });
  native.emit({ type: 'connectionChanged', connection: 'offline' });

  assert.deepEqual(identity, ['anonymous']);
  assert.deepEqual(connection, ['offline']);

  identitySubscription.remove();
  connectionSubscription.remove();
});

test('rejects an invalid native push handling result', async () => {
  const native = createNativeModule();
  native.handlePushNotification = async () => 'unknown';
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.handlePushNotification({
    conversationId: 'synthetic-conversation',
    messageId: 'synthetic-message',
    notificationType: 'message_available',
  }), { code: 'native_operation_failed' });
});

test('maps native failures to safe codes without exposing a native message', async () => {
  const native = createNativeModule();
  native.present = async () => {
    throw {
      code: 'session_expired',
      message: 'unexpected raw native detail',
      retry: { directive: 'after_token_refresh' },
      requestId: 'synthetic-request-id',
    };
  };
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.present(), (error) => {
    assert.equal(error.code, 'session_expired');
    assert.equal(error.message, 'Onlo operation failed (session_expired).');
    assert.deepEqual(error.retry, { directive: 'after_token_refresh' });
    assert.equal(error.requestId, 'synthetic-request-id');
    return true;
  });
});

test('reads retry metadata from React Native rejection userInfo', async () => {
  const native = createNativeModule();
  native.setPushToken = async () => {
    throw {
      code: 'native_operation_failed',
      userInfo: { retry: { directive: 'after_backoff' } },
    };
  };
  const { Onlo } = loadFacade(native);

  await assert.rejects(Onlo.setPushToken({ provider: 'fcm', token: 'synthetic' }), (error) => {
    assert.equal(error.code, 'native_operation_failed');
    assert.deepEqual(error.retry, { directive: 'after_backoff' });
    return true;
  });
});
