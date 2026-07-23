# Mobile SDK v1 API contract

Authoritative server handoff for iOS, Android, React Native, and Flutter. Do not add protocol fields or accept undeclared capability values.

## Transport and origin

| Item | Contract |
| --- | --- |
| Production origin | `https://onlo.ai` |
| Staging origin | No server-supported staging hostname is declared. A staging/review build must receive its exact HTTPS origin from release configuration; do not guess or hard-code one. |
| Local origin | Explicit development-only override; never ship it in a release build. |
| SDK routes | `/api/sdk/v1/*` use the envelope below. |
| Shared chat routes | `/api/widget/*` use plain JSON or SSE, never the v1 envelope. |
| Authentication | Session exchange uses the public SDK key. Every later call sends `Authorization: Bearer <chatToken>`. |

Persist the rotating `proposedCredential` in native protected storage. Keep `chatToken` and an Operator `userJwt` in memory only. Persist each outbox item's UUID `clientMessageId` unchanged until the server accepts it.

## Standard v1 envelope and retry directives

```ts
type Envelope<T> =
  | { requestId: string; serverTime: string; protocolVersion: 1; minimumProtocolVersion: 1; ok: true; result: T }
  | { requestId: string; serverTime: string; protocolVersion: 1; minimumProtocolVersion: 1; ok: false;
      error: { code: ErrorCode; message: string; retry: { directive: RetryDirective; retryAfterMs?: number } } };

type RetryDirective =
  | 'never' | 'after_token_refresh' | 'after_attestation' | 'after_backoff' | 'after_full_sync';
```

| Directive | Required client action |
| --- | --- |
| `never` | Do not automatically repeat the request. Surface a safe state or wait for a new host action/configuration. |
| `after_token_refresh` | Obtain fresh authority before one bounded retry: refresh the Onlo session for bearer-route failures; obtain a new Operator JWT for identity-proof failures. Reuse the same idempotency/transition ID only when retrying the same logical operation. |
| `after_attestation` | Obtain a fresh platform attestation proof, then make one bounded retry. |
| `after_backoff` | Wait `retryAfterMs` when supplied; otherwise use bounded exponential backoff with jitter. Retry only safe/idempotent work. |
| `after_full_sync` | Reconcile the authorised transcript/session state, discard the stale local cursor, then retry only the dependent sync operation. |

`ErrorCode` values: `invalid_request`, `invalid_target_key`, `sdk_not_available`, `target_disabled`, `incompatible_client`, `proof_required`, `invalid_proof`, `expired_proof`, `identity_disabled`, `attestation_required`, `invalid_attestation`, `session_expired`, `session_revoked`, `forbidden_principal`, `stale_cursor`, `idempotency_conflict`, `config_unavailable`, `media_unavailable`, `rate_limited`, `dependency_unavailable`.

## Discovery and supported capabilities

`GET /api/sdk/v1` is unauthenticated discovery and returns `Envelope<{ releaseState: 'internal' | 'public'; manifest: Manifest }>`.

```ts
type Capability =
  | 'secure_storage' | 'persistent_outbox' | 'foreground_stream'
  | 'apns' | 'fcm' | 'media_picker' | 'attachment_upload'
  | 'config_schema_v1' | 'identity_jwt' | 'app_attestation' | 'deep_link_routing';
type Manifest = {
  manifestVersion: 1; protocolVersion: 1; minimumProtocolVersion: 1;
  configSchema: { minimum: 1; maximum: 1 };
  capabilities: Array<{ id: Capability; evidence: 'client_declared' | 'server_validated' | 'provider_validated'; securityRelevant: boolean; description: string }>;
};
```

Declare a capability only when the running SDK can provide it. `apns` is iOS-only and `fcm` Android-only. Image upload requires both `media_picker` and `attachment_upload`; push registration requires the matching provider capability. `identity_jwt` means the SDK can exchange the host-provided JWT—it never signs one.

## Session lifecycle

`POST /api/sdk/v1/session` has no bearer token.

```ts
type ClientDescriptor = {
  protocolVersion: 1; installationId: string; // UUID
  runtimePlatform: 'ios' | 'android'; sdkFamily: 'ios' | 'android' | 'react-native' | 'flutter';
  sdkVersion: string; // semver, <= 40 chars
  appVersion?: string; appBuild?: string; capabilities: Capability[];
};
type Operation =
  | { type: 'bootstrap'; transitionId: string; proposedCredential: string; userJwt?: string }
  | { type: 'resume'; transitionId: string; expectedGeneration: number; presentedCredential: string; proposedCredential: string }
  | { type: 'identify'; transitionId: string; expectedGeneration: number; presentedCredential: string; proposedCredential: string; userJwt: string }
  | { type: 'logout'; transitionId: string; expectedGeneration: number; presentedCredential: string; proposedCredential: string };
type SessionRequest = { sdkKey: string; appIdentifier: string; client: ClientDescriptor; operation: Operation; attestation?: unknown };
type SessionResult = {
  sessionId: string; chatToken: string; installationId: string; generation: number; proposedCredential: string;
  identityClass: 'anonymous' | 'identified'; publicationState: 'testing' | 'production'; attestationState: string;
  configRevision: string; configSchemaVersion: number; configEtag: string;
};
```

Bootstrap creates/replays an installation. Resume rotates its credential. Identify exchanges the Operator JWT. Logout returns it to anonymous. Re-send the same `transitionId` after a lost response for the same transition. Current server release state is `internal`, so public session attempts return `503 sdk_not_available`; this is not an identity error.

## Operator user JWT

The Operator backend creates this compact JWT only after it authenticates its own customer. It signs with the mobile identity secret configured in Onlo for that Operator; the SDK never receives that secret.

| Claim | Requirement |
| --- | --- |
| Algorithm | `HS256` only |
| `aud` | Exactly `onlo-messenger` |
| `sub` | Required opaque external customer ID: 1–255 characters, no control characters, no leading/trailing whitespace. Onlo does not normalize it. |
| `iat`, `exp` | Both required numeric seconds. `exp > iat`; lifetime must be ≤5 minutes; server clock tolerance is 30 seconds. |
| `name` | Optional string or `null`, max 200 characters. |
| `email` | Optional string or `null`, max 254 characters. |
| `phone` | Optional string or `null`, max 40 characters. |
| `customAttributes` | Optional object, max 20 entries; key max 64 chars; each value string (max 500), number, boolean, or `null`. |
| `locale` | Optional string or `null`, max 35 chars; stored as a custom attribute. |

The SDK passes `userJwt` only to bootstrap/identify, then discards it. Onlo validates signature and claims only after the SDK key has selected the Operator; it resolves `sub` against that Operator’s contact external ID and stores the signed profile on that contact. No mobile OTP, WebChat HMAC, or second login exists.

## Configuration

`GET /api/sdk/v1/config` requires bearer authentication.

| Request | Response |
| --- | --- |
| Optional `X-Onlo-Config-Schema: 1` (omitted means 1) | `Envelope<MobileConfig>` plus `ETag`, `Cache-Control: private, no-cache, must-revalidate`, `Vary: Authorization, X-Onlo-Config-Schema` |
| Optional `If-None-Match: <ETag>` | `304` with no body when unchanged |

```ts
type MobileConfig = {
  schemaVersion: 1; revision: string;
  compatibility: { requestedSchemaVersion: number; appliedSchemaVersion: 1; capabilities: Capability[];
    unsupportedSettings: Array<{ code: string; setting: string; reason: string; requiredCapabilities?: Capability[] }> };
  securityPolicy: { minimumProtocolVersion: 1; minimumSdkVersion: string | null; identityMode: 'sdk_interface'; anonymousScope: 'installation_generation'; nativePlacement: 'host_app' };
  appearance: { accent: string; botName: string; botSubtitle: string; greeting: string;
    headerAvatar: { mode: 'image' | 'initials'; text: string; data: string | null };
    light: ColorTheme; dark: ColorTheme & { enabled: boolean } };
  features: { insertLink: boolean; insertCode: boolean; emoji: boolean; gifs: boolean; voice: boolean; fileUpload: boolean;
    transcriptDownload: boolean; soundNotifications: boolean; showTimestamps: boolean; faqButton: { enabled: boolean; label: string } };
  mediaPolicy: { enabled: boolean; maximumImagesPerMessage: number; maximumImageBytes: number };
  content: { faqs: Faq[]; tabs: Tabs; search: Search; onboarding: Onboarding; homeSections: HomeSection[] };
  identityMode: 'sdk_interface'; unsupportedWidgetSettings: Array<{ setting: string; reason: string }>;
};
type ColorTheme = { background: string; outgoing: string; outgoingText: string; incoming: string; incomingText: string };
type Faq = { question: string; answer?: string };
type Tabs = { enabled: boolean; tabs: Array<{ id: string; label: string; icon: string; enabled: boolean }>; defaultTab: string };
type Search = { enabled: boolean; placeholder: string; showSearchInHome: boolean };
type Onboarding = { enabled: boolean; title: string; showProgress: boolean; items: Array<{ id: string; title: string; description?: string; completed: boolean; actionUrl?: string }> };
type HomeSection = { id: string; type: 'welcome' | 'search' | 'faqs' | 'checklist' | 'custom'; title?: string; content?: string; enabled: boolean; order: number };
```

Known nested fields are stable; ignore unknown additive fields. On `config_changed` or foreground/network recovery, fetch conditionally with the last ETag. Use last-known-good config offline. `incompatible_client` means requested schema is invalid/unsupported; `config_unavailable` means keep last-known-good and follow `after_backoff`.

`mediaPolicy.maximumImagesPerMessage` is an integer from `0...3`.
`mediaPolicy.maximumImageBytes` is an integer from `1...8388608` bytes.
The client must use `min(server-configured value, SDK safety maximum)`. The
server independently enforces the effective policy at image intent, completion,
and chat submission. These fields do not replace server-side AI-credit budgets
or request rate limits.

## Chat, transcript, and foreground stream

| Endpoint | Contract |
| --- | --- |
| `POST /api/widget/chat` | Bearer JSON request; SSE response. |
| `GET /api/widget/conversations?limit=1..50` | Bearer JSON conversation list. |
| `GET /api/widget/conversations/:id?before=<opaque>&limit=1..100` | Older transcript page. Use `after` for newer; never both. |
| `GET /api/widget/stream` | Bearer foreground SSE refetch hints. |

```ts
type ChatRequest = { sessionId: string; clientMessageId: string; message: string;
  attachments?: Array<{ id?: string; url: string; type: string; name: string; size: number; sha256?: string; receipt?: string }> };
type ChatEvent =
  | { type: 'accepted'; clientMessageId: string; messageId: string; conversationId: string; acceptedAt: string; duplicate: boolean; processingStatus: string }
  | { type: 'text'; content: string }
  | { type: 'done'; conversationId: string; duplicate?: boolean; processingStatus?: string; gated?: boolean; reason?: string }
  | { type: 'error'; error: string; retryable: boolean };
type ConversationDetail = { conversation: { id: string; sessionId: string; status: string; isHumanTakeover: boolean };
  messages: Array<{ id: string; externalId: string | null; role: string; senderType: string | null; senderName: string | null; senderTeam: string | null; text: string; attachments: unknown[]; timestamp: number }>;
  sync: { previousCursor: string | null; nextCursor: string | null; limit: number } };
```

`accepted` is durable-send acknowledgement. Duplicate acceptance requires transcript sync, never a new message ID. Stream events are only `{type:'ready'}`, `{type:'config_changed',revision}`, `{type:'inbox.conversation',conversationId}`, `{type:'inbox.message',conversationId}`; all require refetch. Widget-route failures are `{ error: string }` rather than v1 envelopes.

## Images and push

| Flow | Contract |
| --- | --- |
| Image intent | `POST /api/sdk/v1/attachments/intent`: `{ conversationId, mimeType: 'image/jpeg'|'image/png'|'image/webp', byteSize, sha256, filename }` → `{ attachmentId, intent, expiresAt, completion: { method: 'POST', endpoint: '/api/sdk/v1/attachments/complete' } }`. `byteSize` must not exceed `mediaPolicy.maximumImageBytes` or the 8 MiB SDK ceiling. Intent lasts 5 minutes. |
| Image completion | Bearer `multipart/form-data`: `intent`, `file` → `{ attachment: { id,url,type,name,size,sha256 }, receipt, receiptExpiresAt, authenticatedDownload }`. Receipt lasts 24 hours. Render only `authenticatedDownload`; include attachment data plus receipt in chat. Chat must not exceed `mediaPolicy.maximumImagesPerMessage` or the 3-image SDK ceiling. |
| Push register | `POST /api/sdk/v1/push-token`: `{ action:'register', provider:'apns'|'fcm', token, notificationPreference?:'enabled'|'muted', locale?:string }` → `{ state:'active'|'muted', provider, environment:'sandbox'|'production', fingerprint, registeredAt }`. |
| Push unregister | `{ action:'unregister' }` → `{ state:'inactive' }`. |
| Push payload | `{ conversationId, messageId, notificationType:'message_available' }`. Re-authorise/refetch transcript before displaying or navigating. |

## Implementation rules

- Do not log tokens, JWTs, message text, PII, attachment URLs, or raw push tokens.
- Session credentials and identity state must be cleared before a different host-app user can use the SDK.
- Image-only v1: reject PDF, text, GIF, SVG, video, and arbitrary remote URLs.
- Apply `min(mediaPolicy, SDK safety maximum)` locally; never interpret server values as permission to exceed 3 images or 8 MiB.
- This contract is server-owned. Any server discrepancy blocks client implementation until corrected here.
