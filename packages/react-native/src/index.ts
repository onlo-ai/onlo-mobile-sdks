/**
 * React Native facade for the native Onlo SDK. Native iOS and Android cores
 * own session, credentials, outbox, transcripts, push, lifecycle, and UI.
 */

import NativeOnloSDK, { type NativeOnloEvent, type Spec as NativeOnloModule } from './NativeOnloSDK';

export interface InitializeOptions {
  sdkKey: string;
}

export interface LoginIdentifiedUserOptions {
  /** A short-lived JWT minted by the Operator backend. It is never stored by JS. */
  userJwt: string;
}

export interface PresentOptions {
  conversationId?: string;
}

export type OnloPushProvider = 'apns' | 'fcm';
export type OnloNotificationPreference = 'enabled' | 'muted';

export interface SetPushTokenOptions {
  provider: OnloPushProvider;
  token: string;
  notificationPreference?: OnloNotificationPreference;
  locale?: string;
}

export interface OnloPushNotificationPayload {
  conversationId: string;
  messageId: string;
  notificationType: 'message_available';
}

export type OnloPushHandlingResult = 'handled' | 'deferred' | 'notOnlo';

export type OnloSessionState =
  | 'uninitialized'
  | 'restoring'
  | 'anonymousReady'
  | 'identifiedReady'
  | 'offlineReady'
  | 'identifying'
  | 'refreshing'
  | 'logoutPending'
  | 'reauthRequired';

export type OnloIdentityState = 'unknown' | 'anonymous' | 'identified';

export type OnloConnectionState = 'uninitialized' | 'ready' | 'offline' | 'unavailable';
export type OnloLogLevel = 'off' | 'error' | 'info' | 'verbose';

export type KnownOnloErrorCode =
  | 'invalid_request'
  | 'invalid_target_key'
  | 'sdk_not_available'
  | 'target_disabled'
  | 'incompatible_client'
  | 'proof_required'
  | 'invalid_proof'
  | 'expired_proof'
  | 'identity_disabled'
  | 'attestation_required'
  | 'invalid_attestation'
  | 'session_expired'
  | 'session_revoked'
  | 'forbidden_principal'
  | 'stale_cursor'
  | 'idempotency_conflict'
  | 'config_unavailable'
  | 'media_unavailable'
  | 'rate_limited'
  | 'dependency_unavailable'
  | 'invalid_argument'
  | 'native_bridge_unavailable'
  | 'native_operation_failed';

export type OnloErrorCode = KnownOnloErrorCode;

export type OnloRetryDirective =
  | 'never'
  | 'after_token_refresh'
  | 'after_attestation'
  | 'after_backoff'
  | 'after_full_sync';

export class OnloError extends Error {
  public readonly name = 'OnloError';

  public constructor(
    public readonly code: OnloErrorCode,
    message: string,
    public readonly retry?: { directive: OnloRetryDirective; retryAfterMs?: number },
    public readonly requestId?: string,
  ) {
    super(message);
  }
}

export type OnloEvent =
  | { type: 'stateChanged'; state: OnloSessionState }
  | { type: 'identityChanged'; identity: OnloIdentityState }
  | { type: 'connectionChanged'; connection: OnloConnectionState }
  | { type: 'unreadCountChanged'; unreadCount: number | null }
  | { type: 'error'; error: OnloError };

export type OnloEventListener = (event: OnloEvent) => void;
export type OnloStateListener = (state: OnloSessionState) => void;
export type OnloIdentityStateListener = (state: OnloIdentityState) => void;
export type OnloConnectionStateListener = (state: OnloConnectionState) => void;
export type OnloUnreadCountListener = (unreadCount: number | null) => void;

export interface OnloSubscription {
  remove(): void;
}

const COMPACT_JWT = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

function bridgeError(code: OnloErrorCode, message: string): OnloError {
  return new OnloError(code, message, { directive: 'never' });
}

function validateInitializeOptions(value: InitializeOptions): void {
  if (!value || typeof value.sdkKey !== 'string' || value.sdkKey.trim().length === 0) {
    throw bridgeError('invalid_argument', 'initialize requires a non-empty sdkKey.');
  }
}

function validateIdentifiedLoginOptions(value: LoginIdentifiedUserOptions): void {
  if (!value || typeof value.userJwt !== 'string' || !COMPACT_JWT.test(value.userJwt)) {
    throw bridgeError('invalid_argument', 'loginIdentifiedUser requires a compact userJwt.');
  }
}

function validatePresentOptions(value: PresentOptions | undefined): void {
  if (value === undefined) return;
  if (typeof value !== 'object' || value === null) {
    throw bridgeError('invalid_argument', 'present options must be an object.');
  }
  if (value.conversationId !== undefined) {
    requireNonEmptyString(value.conversationId, 'present requires a non-empty conversationId when supplied.');
  }
}

function validatePushTokenOptions(value: SetPushTokenOptions): void {
  if (typeof value !== 'object' || value === null) {
    throw bridgeError('invalid_argument', 'setPushToken options must be an object.');
  }
  if (value.provider !== 'apns' && value.provider !== 'fcm') {
    throw bridgeError('invalid_argument', 'setPushToken provider must be apns or fcm.');
  }
  requireNonEmptyString(value.token, 'setPushToken requires a non-empty token.');
  if (value.notificationPreference !== undefined
    && value.notificationPreference !== 'enabled'
    && value.notificationPreference !== 'muted') {
    throw bridgeError('invalid_argument', 'notificationPreference must be enabled or muted.');
  }
  if (value.locale !== undefined) {
    requireNonEmptyString(value.locale, 'locale cannot be empty when supplied.');
  }
}

function validatePushNotificationPayload(value: OnloPushNotificationPayload): void {
  if (typeof value !== 'object' || value === null) {
    throw bridgeError('invalid_argument', 'push payload must be an object.');
  }
  requireNonEmptyString(value.conversationId, 'push payload requires a non-empty conversationId.');
  requireNonEmptyString(value.messageId, 'push payload requires a non-empty messageId.');
  if (value.notificationType !== 'message_available') {
    throw bridgeError('invalid_argument', 'push payload notificationType is not supported.');
  }
}

function requireNonEmptyString(value: unknown, message: string): asserts value is string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw bridgeError('invalid_argument', message);
  }
}

function parseNativeError(error: unknown): OnloError {
  if (error instanceof OnloError) return error;
  if (typeof error === 'object' && error !== null) {
    const value = error as Record<string, unknown>;
    if (typeof value.code === 'string') {
      const code = isKnownErrorCode(value.code) ? value.code : 'native_operation_failed';
      const userInfo = typeof value.userInfo === 'object' && value.userInfo !== null
        ? value.userInfo as Record<string, unknown>
        : undefined;
      const retry = parseRetry(value.retry ?? userInfo?.retry);
      const requestId = typeof value.requestId === 'string'
        ? value.requestId
        : typeof userInfo?.requestId === 'string' ? userInfo.requestId : undefined;
      return new OnloError(code, `Onlo operation failed (${code}).`, retry, requestId);
    }
  }
  return bridgeError('native_bridge_unavailable', 'The Onlo native bridge returned an invalid error.');
}

function parseRetry(value: unknown): OnloError['retry'] {
  if (typeof value !== 'object' || value === null) return undefined;
  const retry = value as Record<string, unknown>;
  if (!isRetryDirective(retry.directive)) return undefined;
  return typeof retry.retryAfterMs === 'number' && Number.isFinite(retry.retryAfterMs) && retry.retryAfterMs >= 0
    ? { directive: retry.directive, retryAfterMs: retry.retryAfterMs }
    : { directive: retry.directive };
}

function isRetryDirective(value: unknown): value is OnloRetryDirective {
  return value === 'never' || value === 'after_token_refresh' || value === 'after_attestation'
    || value === 'after_backoff' || value === 'after_full_sync';
}

function isKnownErrorCode(value: string): value is OnloErrorCode {
  return value === 'invalid_request' || value === 'invalid_target_key' || value === 'sdk_not_available'
    || value === 'target_disabled' || value === 'incompatible_client' || value === 'proof_required'
    || value === 'invalid_proof' || value === 'expired_proof' || value === 'identity_disabled'
    || value === 'attestation_required' || value === 'invalid_attestation' || value === 'session_expired'
    || value === 'session_revoked' || value === 'forbidden_principal' || value === 'stale_cursor'
    || value === 'idempotency_conflict' || value === 'config_unavailable' || value === 'media_unavailable'
    || value === 'rate_limited' || value === 'dependency_unavailable' || value === 'invalid_argument'
    || value === 'native_bridge_unavailable' || value === 'native_operation_failed';
}

function parseEvent(payload: NativeOnloEvent): OnloEvent | undefined {
  if (typeof payload !== 'object' || payload === null) return undefined;
  const event = payload as unknown as Record<string, unknown>;
  if (event.type === 'stateChanged' && isSessionState(event.state)) {
    return { type: 'stateChanged', state: event.state };
  }
  if (event.type === 'identityChanged' && isIdentityState(event.identity)) {
    return { type: 'identityChanged', identity: event.identity };
  }
  if (event.type === 'connectionChanged' && isConnectionState(event.connection)) {
    return { type: 'connectionChanged', connection: event.connection };
  }
  if (event.type === 'unreadCountChanged'
    && (event.unreadCount === null
      || (typeof event.unreadCount === 'number'
        && Number.isInteger(event.unreadCount)
        && event.unreadCount >= 0))) {
    return { type: 'unreadCountChanged', unreadCount: event.unreadCount as number | null };
  }
  if (event.type === 'error') return { type: 'error', error: parseNativeError(event.error) };
  return undefined;
}

function isSessionState(value: unknown): value is OnloSessionState {
  return value === 'uninitialized' || value === 'restoring' || value === 'anonymousReady' || value === 'identifiedReady' || value === 'offlineReady' || value === 'identifying' || value === 'refreshing' || value === 'logoutPending' || value === 'reauthRequired';
}

function isIdentityState(value: unknown): value is OnloIdentityState {
  return value === 'unknown' || value === 'anonymous' || value === 'identified';
}

function isConnectionState(value: unknown): value is OnloConnectionState {
  return value === 'uninitialized' || value === 'ready' || value === 'offline' || value === 'unavailable';
}

function isPushHandlingResult(value: unknown): value is OnloPushHandlingResult {
  return value === 'handled' || value === 'deferred' || value === 'notOnlo';
}

async function callNative(operation: (native: NativeOnloModule) => Promise<void>): Promise<void> {
  try {
    await operation(NativeOnloSDK);
  } catch (error) {
    throw parseNativeError(error);
  }
}

async function callNativeForResult<T>(operation: (native: NativeOnloModule) => Promise<unknown>, validate: (value: unknown) => value is T): Promise<T> {
  try {
    const value = await operation(NativeOnloSDK);
    if (!validate(value)) {
      throw bridgeError('native_operation_failed', 'The Onlo native bridge returned an invalid result.');
    }
    return value;
  } catch (error) {
    throw parseNativeError(error);
  }
}

function subscribe(listener: OnloEventListener): OnloSubscription {
  if (typeof listener !== 'function') {
    throw bridgeError('invalid_argument', 'listener must be a function.');
  }
  try {
    const subscription = NativeOnloSDK.onOnloEvent((payload) => {
      const event = parseEvent(payload);
      if (event) listener(event);
    });
    return { remove: () => subscription.remove() };
  } catch (error) {
    throw parseNativeError(error);
  }
}

export const Onlo = {
  setLogLevel(level: OnloLogLevel): Promise<void> {
    if (level !== 'off' && level !== 'error' && level !== 'info' && level !== 'verbose') {
      return Promise.reject(bridgeError('invalid_argument', 'setLogLevel requires off, error, info, or verbose.'));
    }
    return callNative((native) => native.setLogLevel(level));
  },

  initialize(options: InitializeOptions): Promise<void> {
    try {
      validateInitializeOptions(options);
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNative((native) => native.initialize(options));
  },

  loginUnidentifiedUser(): Promise<void> {
    return callNative((native) => native.loginUnidentifiedUser());
  },

  loginIdentifiedUser(options: LoginIdentifiedUserOptions): Promise<void> {
    try {
      validateIdentifiedLoginOptions(options);
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNative((native) => native.loginIdentifiedUser(options));
  },

  logout(): Promise<void> {
    return callNative((native) => native.logout());
  },

  present(options?: PresentOptions): Promise<void> {
    try {
      validatePresentOptions(options);
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNative((native) => native.present(options));
  },

  dismiss(): Promise<void> {
    return callNative((native) => native.dismiss());
  },

  openConversation(conversationId: string): Promise<void> {
    try {
      requireNonEmptyString(conversationId, 'openConversation requires a non-empty conversationId.');
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNative((native) => native.openConversation(conversationId));
  },

  setPushToken(options: SetPushTokenOptions): Promise<void> {
    try {
      validatePushTokenOptions(options);
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNative((native) => native.setPushToken(options));
  },

  handlePushNotification(payload: OnloPushNotificationPayload): Promise<OnloPushHandlingResult> {
    try {
      validatePushNotificationPayload(payload);
    } catch (error) {
      return Promise.reject(parseNativeError(error));
    }
    return callNativeForResult((native) => native.handlePushNotification(payload), isPushHandlingResult);
  },

  addListener(listener: OnloEventListener): OnloSubscription {
    return subscribe(listener);
  },

  observeState(listener: OnloStateListener): OnloSubscription {
    requireListener(listener, 'observeState');
    return subscribe((event) => {
      if (event.type === 'stateChanged') listener(event.state);
    });
  },

  observeIdentityState(listener: OnloIdentityStateListener): OnloSubscription {
    requireListener(listener, 'observeIdentityState');
    return subscribe((event) => {
      if (event.type === 'identityChanged') listener(event.identity);
    });
  },

  observeConnectionState(listener: OnloConnectionStateListener): OnloSubscription {
    requireListener(listener, 'observeConnectionState');
    return subscribe((event) => {
      if (event.type === 'connectionChanged') listener(event.connection);
    });
  },

  observeUnreadCount(listener: OnloUnreadCountListener): OnloSubscription {
    requireListener(listener, 'observeUnreadCount');
    return subscribe((event) => {
      if (event.type === 'unreadCountChanged') listener(event.unreadCount);
    });
  },
} as const;

function requireListener(value: unknown, operation: string): asserts value is (...args: never[]) => unknown {
  if (typeof value !== 'function') {
    throw bridgeError('invalid_argument', `${operation} requires a function.`);
  }
}
