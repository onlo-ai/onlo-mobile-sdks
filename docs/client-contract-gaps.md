# Client contract gap review

Internal review log for client behavior that cannot be derived from the current v1 wire contract. The [API contract](api-contract.md) remains authoritative; this document does not extend it.

## Sources and ownership

| Source | Role |
| --- | --- |
| [API contract](api-contract.md) | Authoritative wire shapes and behavior |
| [`@onlo/protocol`](../packages/protocol/src/index.ts) | Typed client mirror of the contract |
| [Architectural invariants](invariants.md) | Required client behavior across native cores and framework bridges |

Wire gaps must be resolved by the Onlo server/contract owner in the canonical API contract before clients implement dependent protocol behavior. If no wire change is intended, the client requirement must align with the existing contract.

## Wire gaps

| Gap | Current contract | Impact | Narrow safe client behavior | Resolution required |
| --- | --- | --- | --- | --- |
| Pre-accept conversation targeting | `ChatRequest` contains `sessionId`, `clientMessageId`, `message`, and optional `attachments`; it has no `conversationId`. | Before an accepted response supplies a conversation ID, clients cannot target a conversation or safely partition sends for per-conversation parallelism. | Use a conservative FIFO per authorized owner/session, preserve one stable `clientMessageId` through retries, and bind the returned `conversationId` only after acceptance. Do not add a client-only request field. | The server/contract owner must define targeting and ordering semantics, or add a canonical field, before per-conversation scheduling is implemented. |
| Widget HTTP failure classification | Widget failures are plain `{ error: string }`, without a retry directive or a canonical HTTP-status-to-action mapping. | Clients cannot infer bearer refresh, terminal failure, or retry/backoff behavior from the response. | Do not manufacture a `RetryDirective` or status mapping. Preserve durable work and its stable ID, reconcile authoritative state before resending, and expose a safe failure until the contract supplies an action. | The server/contract owner must document an error/status mapping or extend the canonical response before automatic refresh and classified retry behavior is implemented. |
| Foreground stream resumption | Stream events are refetch hints and provide no cursor or resume token. | A client cannot resume from a known position or prove that it did not miss hints across a disconnect. | Treat SSE as non-authoritative: refetch authorized config/transcript state after hints and lifecycle or network recovery, then reconnect without inventing a cursor. | The server/contract owner must define cursor/resume semantics if they become a requirement; otherwise clients retain refetch-only behavior. |
| Push signature verification | The push payload contains `conversationId`, `messageId`, and `notificationType`; it has no signature field or verification scheme. | Clients cannot cryptographically verify the payload at the SDK layer. | Validate the declared shape, treat identifiers only as hints, and re-authorize/refetch before display or navigation. Never trust payload data as proof of content or ownership, and do not invent signature verification. | The server/push contract owner must add a documented signature scheme before signature verification becomes a client requirement. |
| Dashboard avatar validation | Mobile projection accepts only bounded PNG/JPEG/GIF/WebP data URLs, while the Dashboard currently accepts unrestricted `image/*` without the same 350,000-character limit. | A Dashboard save can succeed but project as initials on mobile without warning. | Render only the validated `headerAvatar` returned by `/api/sdk/v1/config`; never bypass the projection with Dashboard data. | Dashboard validation and error text must match the mobile projection before logo parity is promised. |
| Status-only notification coverage | `message_available` delivery covers durable customer-visible replies, proactive inserts, and ticket-resolution messages for anonymous and identified installations. The contract defines no notification type for a status transition that creates no customer-visible message. | A status-only ticket event is recovered by foreground sync but does not generate a push notification. | Keep push payload handling generic and refetch-authorised. Do not invent notification types or manufacture local notifications. | The server/contract owner must decide whether status-only events require a notification before adding another payload type. |

## Implementation gaps

These are local SDK work, not reasons to wait for a public server release.

| Area | Current implementation / remaining verification | Safe release boundary |
| --- | --- | --- |
| Attachments | Widget upload grants now bind installation generation, canonical owner, routing session, optional conversation, and exact attachment metadata. Native iOS and Android reuse the Widget upload/chat path. | Automated contract/native coverage passes; physical picker, camera, expiry, policy-toggle, restart, and account-switch evidence remains required. |
| Push | APNs/FCM protected registration, token lifecycle, retry, payload re-authorisation, and open-reconciliation tests are implemented. Native Android FCM registration and notification delivery have also been verified end to end. | Physical APNs delivery remains required. React Native and Flutter bridge tests and host builds pass, but each wrapper still needs provider-configured device evidence on its applicable iOS/APNs and Android/FCM runtime. |
| Messenger UI | Host-controlled native Android and iOS presentation, automated tests, iOS simulator journeys, Android example build, and framework host builds are implemented. | Physical-device lifecycle and interaction evidence remains required; simulator or build evidence does not replace it. |
| React Native and Flutter adapters | Typed facades, Android/iOS thin adapters, tests, and representative Android/iOS host builds are implemented against the sibling native cores. | Both native links remain monorepo-local and unpublished. Provider-configured device journeys remain required; JavaScript and Dart must retain no sensitive state. |

Local implementation should continue with synthetic conformance fixtures and mock transport. Any future wire change must first update the canonical API contract, then `@onlo/protocol`, fixtures, conformance tests, and dependent client behavior in that order.
