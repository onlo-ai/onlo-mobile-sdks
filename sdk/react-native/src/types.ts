export type OnloLogLevel = 'none' | 'error' | 'warning' | 'verbose';

export interface OnloInitOptions {
  /** Platform SDK key from Onlo Dashboard → Chat widget → Install → mobile. */
  apiKey: string;
  /** Override the Onlo API origin (staging / self-hosted). Default: https://app.onlo.ai */
  baseUrl?: string;
  logLevel?: OnloLogLevel;
  /** Label overrides for the built-in messenger UI (localization). */
  strings?: Partial<OnloStrings>;
  /** iOS bundle ID / Android package name — required only when the SDK key is bundle-bound. */
  bundleId?: string;
}

export interface OnloStrings {
  headerTitle: string;
  inputPlaceholder: string;
  send: string;
  newConversation: string;
  conversationsTitle: string;
  offlineNotice: string;
  errorNotice: string;
  close: string;
}

export interface OnloIdentifyOptions {
  /** Short-lived user JWT minted by your backend after authenticating the user. */
  userJwt: string;
}

export interface OnloTheme {
  accent: string;
  botName: string;
  botSubtitle: string;
  greeting: string;
  chatBackground: string;
  outgoingColor: string;
  outgoingTextColor: string;
  incomingColor: string;
  incomingTextColor: string;
  darkMode: boolean;
  darkBackground: string;
  darkOutgoingColor: string;
  darkOutgoingTextColor: string;
  darkIncomingColor: string;
  darkIncomingTextColor: string;
  showTimestamps: boolean;
  headerLogoText: string;
}

export interface OnloSession {
  sessionId: string;
  chatToken: string;
}

export interface OnloConversationSummary {
  id: string;
  sessionId: string;
  title: string;
  unread: boolean;
  unreadCount: number;
  status: string;
  updatedAt: string;
  messageCount: number;
  lastMessageRole: string | null;
}

export interface OnloMessage {
  id: string;
  role: 'user' | 'assistant' | string;
  content: string;
  createdAt: string;
  /** Local-only flag for optimistic/queued sends. */
  pending?: boolean;
}

/** SSE frames emitted by POST /api/widget/chat. */
export type OnloChatEvent =
  | { type: 'text'; content: string }
  | { type: 'done'; conversationId?: string; gated?: boolean; reason?: string; identityGate?: unknown }
  | { type: 'error'; error: string };
