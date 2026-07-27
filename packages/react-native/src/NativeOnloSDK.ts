import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';
import type { EventEmitter } from 'react-native/Libraries/Types/CodegenTypes';

export interface NativeInitializeOptions {
  sdkKey: string;
}

export interface NativeLoginIdentifiedUserOptions {
  userJwt: string;
}

export interface NativePresentOptions {
  conversationId?: string;
  presentationMode?: string;
}

export interface NativePushTokenOptions {
  provider: string;
  token: string;
  notificationPreference?: string;
  locale?: string;
}

export interface NativePushNotificationPayload {
  conversationId: string;
  messageId: string;
  notificationType: string;
}

export interface NativeRetry {
  directive: string;
  retryAfterMs?: number;
}

export interface NativeError {
  code: string;
  retry?: NativeRetry;
  requestId?: string;
}

/**
 * The native cores emit this one code-generated event stream. The facade
 * validates and narrows it before giving it to host JavaScript.
 */
export interface NativeOnloEvent {
  type: string;
  state?: string;
  identity?: string;
  connection?: string;
  unreadCount?: number | null;
  error?: NativeError;
}

export interface Spec extends TurboModule {
  setLogLevel(level: string): Promise<void>;
  initialize(options: NativeInitializeOptions): Promise<void>;
  loginUnidentifiedUser(): Promise<void>;
  loginIdentifiedUser(options: NativeLoginIdentifiedUserOptions): Promise<void>;
  logout(): Promise<void>;
  present(options?: NativePresentOptions): Promise<void>;
  dismiss(): Promise<void>;
  openConversation(conversationId: string): Promise<void>;
  setPushToken(options: NativePushTokenOptions): Promise<void>;
  handlePushNotification(payload: NativePushNotificationPayload): Promise<string>;
  readonly onOnloEvent: EventEmitter<NativeOnloEvent>;
}

export default TurboModuleRegistry.getEnforcing<Spec>('OnloSDK');
