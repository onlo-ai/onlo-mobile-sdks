/** Shared v1 transport contract mirrored from the server validation boundary. */
export const PROTOCOL_VERSION = 1 as const;
export const PRODUCTION_ORIGIN = 'https://onlo.ai' as const;
export const CONFIG_SCHEMA_VERSION = 1 as const;

/** Staging/review builds must receive an explicit HTTPS origin from release configuration. */
export type ReleaseConfiguredHttpsOrigin = `https://${string}`;

export type RuntimePlatform = 'ios' | 'android';
export type SdkFamily = 'ios' | 'android' | 'react-native' | 'flutter';
export type PublicationState = 'testing' | 'production';
export type IdentityClass = 'anonymous' | 'identified';
export type PushProvider = 'apns' | 'fcm';
export type PushEnvironment = 'sandbox' | 'production';
export type ImageMimeType = 'image/jpeg' | 'image/png' | 'image/webp';
export type Capability =
  | 'secure_storage'
  | 'persistent_outbox'
  | 'foreground_stream'
  | 'apns'
  | 'fcm'
  | 'media_picker'
  | 'attachment_upload'
  | 'config_schema_v1'
  | 'identity_jwt'
  | 'app_attestation'
  | 'deep_link_routing';
export type CapabilityEvidence = 'client_declared' | 'server_validated' | 'provider_validated';
export type RetryDirective =
  | 'never'
  | 'after_token_refresh'
  | 'after_attestation'
  | 'after_backoff'
  | 'after_full_sync';
export type ErrorCode =
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
  | 'dependency_unavailable';

export interface ManifestCapability {
  id: Capability;
  evidence: CapabilityEvidence;
  securityRelevant: boolean;
  description: string;
}

export interface Manifest {
  manifestVersion: typeof PROTOCOL_VERSION;
  protocolVersion: typeof PROTOCOL_VERSION;
  minimumProtocolVersion: typeof PROTOCOL_VERSION;
  configSchema: { minimum: typeof CONFIG_SCHEMA_VERSION; maximum: typeof CONFIG_SCHEMA_VERSION };
  capabilities: ManifestCapability[];
}

export interface DiscoveryResult {
  releaseState: 'internal' | 'public';
  manifest: Manifest;
}

export interface SdkClientDescriptor {
  protocolVersion: typeof PROTOCOL_VERSION;
  installationId: string;
  runtimePlatform: RuntimePlatform;
  sdkFamily: SdkFamily;
  sdkVersion: string;
  appVersion?: string;
  appBuild?: string;
  capabilities: Capability[];
}

export interface ApiRetry {
  directive: RetryDirective;
  retryAfterMs?: number;
}

export interface ApiError {
  code: ErrorCode;
  message: string;
  retry: ApiRetry;
}

export interface ApiSuccess<T> {
  requestId: string;
  serverTime: string;
  protocolVersion: typeof PROTOCOL_VERSION;
  minimumProtocolVersion: typeof PROTOCOL_VERSION;
  ok: true;
  result: T;
}

export interface ApiFailure {
  requestId: string;
  serverTime: string;
  protocolVersion: typeof PROTOCOL_VERSION;
  minimumProtocolVersion: typeof PROTOCOL_VERSION;
  ok: false;
  error: ApiError;
}

export type ApiEnvelope<T> = ApiSuccess<T> | ApiFailure;

interface CredentialTransition {
  transitionId: string;
  proposedCredential: string;
}

interface CredentialRotation extends CredentialTransition {
  expectedGeneration: number;
  presentedCredential: string;
}

export type SessionOperation =
  | ({ type: 'bootstrap'; userJwt?: string } & CredentialTransition)
  | ({ type: 'resume' } & CredentialRotation)
  | ({ type: 'identify'; userJwt: string } & CredentialRotation)
  | ({ type: 'logout' } & CredentialRotation);

export interface SessionRequest {
  sdkKey: string;
  appIdentifier: string;
  client: SdkClientDescriptor;
  operation: SessionOperation;
  /** Opaque platform proof; its platform-specific shape is server-defined. */
  attestation?: unknown;
}

export interface SessionResult {
  sessionId: string;
  chatToken: string;
  installationId: string;
  generation: number;
  proposedCredential: string;
  identityClass: IdentityClass;
  publicationState: PublicationState;
  attestationState: string;
  configRevision: string;
  configSchemaVersion: number;
  configEtag: string;
}

export type PushTokenRequest =
  | {
      action: 'register';
      provider: PushProvider;
      token: string;
      notificationPreference?: 'enabled' | 'muted';
      locale?: string;
    }
  | { action: 'unregister' };

export type PushTokenResult =
  | {
      state: 'active' | 'muted';
      provider: PushProvider;
      environment: PushEnvironment;
      fingerprint: string;
      registeredAt: string;
    }
  | { state: 'inactive' };

export interface PushNotificationPayload {
  conversationId: string;
  messageId: string;
  notificationType: 'message_available';
}

export interface AttachmentIntentRequest {
  conversationId: string;
  mimeType: ImageMimeType;
  byteSize: number;
  sha256: string;
  filename: string;
}

export interface AttachmentIntentResult {
  attachmentId: string;
  intent: string;
  expiresAt: string;
  completion: {
    method: 'POST';
    endpoint: '/api/sdk/v1/attachments/complete';
  };
}

export interface CompletedAttachment {
  id: string;
  url: string;
  type: ImageMimeType;
  name: string;
  size: number;
  sha256: string;
}

export interface AttachmentCompleteResult {
  attachment: CompletedAttachment;
  receipt: string;
  receiptExpiresAt: string;
  authenticatedDownload: string;
}

export interface UnsupportedSetting {
  code: string;
  setting: string;
  reason: string;
  requiredCapabilities?: Capability[];
}

export interface ColorTheme {
  background: string;
  outgoing: string;
  outgoingText: string;
  incoming: string;
  incomingText: string;
}

export interface Faq {
  question: string;
  answer?: string;
}

export interface Tabs {
  enabled: boolean;
  tabs: Array<{ id: string; label: string; icon: string; enabled: boolean }>;
  defaultTab: string;
}

export interface Search {
  enabled: boolean;
  placeholder: string;
  showSearchInHome: boolean;
}

export interface Onboarding {
  enabled: boolean;
  title: string;
  showProgress: boolean;
  items: Array<{ id: string; title: string; description?: string; completed: boolean; actionUrl?: string }>;
}

export interface HomeSection {
  id: string;
  type: 'welcome' | 'search' | 'faqs' | 'checklist' | 'custom';
  title?: string;
  content?: string;
  enabled: boolean;
  order: number;
}

export interface MobileConfig {
  schemaVersion: typeof CONFIG_SCHEMA_VERSION;
  revision: string;
  compatibility: {
    requestedSchemaVersion: number;
    appliedSchemaVersion: typeof CONFIG_SCHEMA_VERSION;
    capabilities: Capability[];
    unsupportedSettings: UnsupportedSetting[];
  };
  securityPolicy: {
    minimumProtocolVersion: typeof PROTOCOL_VERSION;
    minimumSdkVersion: string | null;
    identityMode: 'sdk_interface';
    anonymousScope: 'installation_generation';
    nativePlacement: 'host_app';
  };
  appearance: {
    accent: string;
    botName: string;
    botSubtitle: string;
    greeting: string;
    headerAvatar: { mode: 'image' | 'initials'; text: string; data: string | null };
    light: ColorTheme;
    dark: ColorTheme & { enabled: boolean };
  };
  features: {
    insertLink: boolean;
    insertCode: boolean;
    emoji: boolean;
    gifs: boolean;
    voice: boolean;
    fileUpload: boolean;
    transcriptDownload: boolean;
    soundNotifications: boolean;
    showTimestamps: boolean;
    faqButton: { enabled: boolean; label: string };
  };
  mediaPolicy: {
    enabled: boolean;
    maximumImagesPerMessage: number;
    maximumImageBytes: number;
  };
  content: { faqs: Faq[]; tabs: Tabs; search: Search; onboarding: Onboarding; homeSections: HomeSection[] };
  identityMode: 'sdk_interface';
  unsupportedWidgetSettings: Array<{ setting: string; reason: string }>;
}

/** Conditional configuration-refresh input; property names map to the documented headers. */
export interface ConfigFetchRequest {
  configSchemaVersion?: typeof CONFIG_SCHEMA_VERSION;
  ifNoneMatch?: string;
}

export interface ConfigFetchResponse {
  etag: string;
  cacheControl: 'private, no-cache, must-revalidate';
  vary: 'Authorization, X-Onlo-Config-Schema';
  body: ApiEnvelope<MobileConfig>;
}

export interface ConfigNotModifiedResponse {
  status: 304;
  etag?: string;
}

/** Constraints for host-created JWTs. The SDK forwards a compact token; it never signs or persists one. */
export const OPERATOR_USER_JWT_REQUIREMENTS = {
  algorithm: 'HS256',
  audience: 'onlo-messenger',
  maximumLifetimeSeconds: 300,
  clockToleranceSeconds: 30,
  subject: { minimumLength: 1, maximumLength: 255, forbidsControlCharacters: true, trimsRequired: true },
  nameMaximumLength: 200,
  emailMaximumLength: 254,
  phoneMaximumLength: 40,
  localeMaximumLength: 35,
  customAttributes: { maximumEntries: 20, maximumKeyLength: 64, maximumStringValueLength: 500 },
} as const;

/** Rejects only malformed compact-token syntax; Onlo verifies claims and signature. */
export function isCompactJwt(value: string): boolean {
  return /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(value);
}

export interface ChatAttachment {
  id?: string;
  url: string;
  type: string;
  name: string;
  size: number;
  sha256?: string;
  receipt?: string;
}

export interface ChatRequest {
  sessionId: string;
  clientMessageId: string;
  message: string;
  attachments?: ChatAttachment[];
}

export type ChatEvent =
  | {
      type: 'accepted';
      clientMessageId: string;
      messageId: string;
      conversationId: string;
      acceptedAt: string;
      duplicate: boolean;
      processingStatus: string;
    }
  | { type: 'text'; content: string }
  | {
      type: 'done';
      conversationId: string;
      duplicate?: boolean;
      processingStatus?: string;
      gated?: boolean;
      reason?: string;
    }
  | { type: 'error'; error: string; retryable: boolean };

export interface WidgetErrorResponse {
  error: string;
}

export interface ConversationSummary {
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

export interface ConversationListResult {
  conversations: ConversationSummary[];
  totalUnreadCount: number;
}

export interface ConversationReadRequest {
  throughMessageId: string;
}

export interface ConversationReadResult {
  conversationId: string;
  readThroughMessageId: string;
  unread: boolean;
  unreadCount: number;
}

export interface HelpCenterArticleSummary {
  id: string;
  title: string;
  updatedAt: string;
}

export interface HelpCenterTopic {
  id: string;
  name: string;
  count: number;
  articles: HelpCenterArticleSummary[];
}

export interface HelpCenterCatalog {
  topics: HelpCenterTopic[];
}

export interface HelpCenterArticle {
  id: string;
  title: string;
  topic: string | null;
  body: string;
  sourceType: string;
  faqQuestion: string | null;
  updatedAt: string;
  related: Array<{ id: string; title: string; topic: string | null }>;
}

export interface HelpCenterArticleResult {
  article: HelpCenterArticle;
}

export interface ConversationDetail {
  id: string;
  sessionId: string;
  status: string;
  isHumanTakeover: boolean;
}

export interface TranscriptMessage {
  id: string;
  externalId: string | null;
  role: string;
  senderType: string | null;
  senderName: string | null;
  senderTeam: string | null;
  text: string;
  attachments: unknown[];
  timestamp: number;
}

export interface TranscriptSync {
  previousCursor: string | null;
  nextCursor: string | null;
  limit: number;
}

export interface ConversationTranscriptResult {
  conversation: ConversationDetail;
  messages: TranscriptMessage[];
  sync: TranscriptSync;
}

export type ConversationPageQuery =
  | { before: string; after?: never; limit?: number }
  | { after: string; before?: never; limit?: number }
  | { before?: never; after?: never; limit?: number };

export type StreamEvent =
  | { type: 'ready' }
  | { type: 'config_changed'; revision: string }
  | { type: 'inbox.conversation'; conversationId: string }
  | { type: 'inbox.message'; conversationId: string };

export const MAX_MOBILE_IMAGES_PER_MESSAGE = 5 as const;
export const MAX_MOBILE_IMAGE_BYTES = 8 * 1024 * 1024;
export const MAX_MOBILE_SOURCE_IMAGE_BYTES = 25 * 1024 * 1024;
