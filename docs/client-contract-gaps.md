# Client contract gap review

Internal review log for delivery-plan behavior that cannot be derived from the current v1 wire contract. The [API contract](api-contract.md) remains authoritative; this document does not extend it.

## Sources and ownership

| Source | Role |
| --- | --- |
| [API contract](api-contract.md) | Authoritative wire shapes and behavior |
| [`@onlo/protocol`](../packages/protocol/src/index.ts) | Typed client mirror of the contract |
| [Delivery plan](delivery-plan.md) | Target SDK behavior and remaining implementation work |

Wire gaps must be resolved by the Onlo server/contract owner in the canonical API contract before clients implement dependent protocol behavior. If no wire change is intended, the delivery-plan owner must align the requirement with the existing contract.

## Wire gaps

| Gap | Current contract | Impact | Narrow safe client behavior | Resolution required |
| --- | --- | --- | --- | --- |
| Pre-accept conversation targeting | `ChatRequest` contains `sessionId`, `clientMessageId`, `message`, and optional `attachments`; it has no `conversationId`. | Before an accepted response supplies a conversation ID, clients cannot target a conversation or safely partition sends for per-conversation parallelism. | Use a conservative FIFO per authorized owner/session, preserve one stable `clientMessageId` through retries, and bind the returned `conversationId` only after acceptance. Do not add a client-only request field. | The server/contract owner must define targeting and ordering semantics, or add a canonical field, before per-conversation scheduling is implemented. |
| Widget HTTP failure classification | Widget failures are plain `{ error: string }`, without a retry directive or a canonical HTTP-status-to-action mapping. | Clients cannot infer bearer refresh, terminal failure, or retry/backoff behavior from the response. | Do not manufacture a `RetryDirective` or status mapping. Preserve durable work and its stable ID, reconcile authoritative state before resending, and expose a safe failure until the contract supplies an action. | The server/contract owner must document an error/status mapping or extend the canonical response before automatic refresh and classified retry behavior is implemented. |
| Foreground stream resumption | Stream events are refetch hints and provide no cursor or resume token. | A client cannot resume from a known position or prove that it did not miss hints across a disconnect. | Treat SSE as non-authoritative: refetch authorized config/transcript state after hints and lifecycle or network recovery, then reconnect without inventing a cursor. | The server/contract owner must define cursor/resume semantics if they remain a delivery requirement; otherwise the delivery plan must retain refetch-only behavior. |
| Push signature verification | The push payload contains `conversationId`, `messageId`, and `notificationType`; it has no signature field or verification scheme, despite the delivery plan mentioning signature checks. | Clients cannot cryptographically verify the payload at the SDK layer. | Validate the declared shape, treat identifiers only as hints, and re-authorize/refetch before display or navigation. Never trust payload data as proof of content or ownership, and do not invent signature verification. | The server/push contract owner must add a documented signature scheme to the canonical contract, or the delivery-plan owner must remove the signature prerequisite. |

## Implementation gaps

These are local SDK work, not reasons to wait for a public server release.

| Area | Remaining work | Safe release boundary |
| --- | --- | --- |
| Attachments | Native selection, validation, upload lifecycle, durable retry, reconciliation, and tests remain to be completed. | Do not advertise or expose attachment capability until the real native path and conformance tests pass. |
| Push | Native provider registration, token lifecycle, open reconciliation, and tests remain to be completed. | Do not advertise APNs/FCM capability until its provider implementation passes; use only the shape-and-refetch behavior above. |
| Messenger UI | Native presentation and runnable example foundations remain to be completed. | Keep presentation host-controlled and backed by real native session/transcript state. |
| React Native and Flutter adapters | Thin adapters to the native implementations remain to be completed. | Do not return stub success or store credentials or identified data in JavaScript or Dart. |

Local implementation should continue with synthetic conformance fixtures and mock transport. Any future wire change must first update the canonical API contract, then `@onlo/protocol`, fixtures, conformance tests, and dependent client behavior in that order.
