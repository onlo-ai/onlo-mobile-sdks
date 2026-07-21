# Conformance

Conformance proves that iOS, Android, React Native, and Flutter produce the same server-visible lifecycle. Native cores implement the behavior; framework bridges inherit it on their active OS.

## Contract coverage

| Flow | Canonical source | Shared type | JSON fixture | Scenario | Readiness |
| --- | --- | --- | --- | --- | --- |
| Anonymous bootstrap, resume, identify, logout | `docs/api-contract.md` session lifecycle | `SessionRequest` / `SessionResult` / `SessionOperation` | Present | `session-lifecycle` | Ready for native implementation |
| Compatible config fetch | `docs/api-contract.md` configuration | `MobileConfig`, config refresh types | Present | `config-refresh` | Ready for native implementation and mock conformance |
| Chat, transcript, and foreground SSE | `docs/api-contract.md` shared chat path | `ChatRequest`, `ChatEvent`, transcript, and stream types | Present | `outbox-idempotency` | Ready for native implementation |
| Push registration and handling | `docs/api-contract.md` push token registration | `PushTokenRequest`, result, and payload types | Present | `push-and-attachment` | Ready for native implementation |
| Attachment intent, completion, and send | `docs/api-contract.md` image attachment flow | Intent, completion, and chat attachment types | Present | `push-and-attachment` | Ready for native implementation |
| Production endpoint selection | `docs/api-contract.md` transport conventions | `PRODUCTION_ORIGIN`, `ReleaseConfiguredHttpsOrigin` | Boundary test | Production is `https://onlo.ai`; staging/review requires explicit release configuration |

The [v1 API contract](../docs/api-contract.md) and [`@onlo/protocol`](../packages/protocol/src/index.ts) remain the client/server source of truth. Do not create a fixture, type, or client fallback for an unknown field.

## Required invariants

| Scenario | Invariant |
| --- | --- |
| Offline send and process restart | The durable row retains one `clientMessageId` and sends once when eligible. |
| Response lost after acceptance | Retrying the same ID does not create another customer message or AI turn. |
| Anonymous-to-identified transition | Only the server-authorised installation history is promoted. |
| Logout or account switch | User A’s history, outbox, read state, credentials, and push association are inaccessible before User B can use the SDK. |
| Config refresh while offline | Use last-known-good config; conditionally refresh after foreground/network recovery and apply `after_backoff` for `config_unavailable`. |
| Dropped push or stream gap | The client refetches the authorised transcript; hints never become source of truth. |

## Adding conformance coverage

1. Obtain the server-approved request, response, error, and state-transition shape → the canonical API contract can describe the flow exactly.
2. Add the language-neutral fixture under `contracts/v1` and corresponding `@onlo/protocol` type → every native core has identical input and expectation.
3. Add a scenario with observable client, local-state, and server-visible assertions → iOS and Android can run it directly.
4. Run it on React Native and Flutter on both OS targets → bridge behavior cannot diverge from the native core.

## Completion criteria

- Every publicly supported `/api/sdk/v1` flow has success, failure, and retry fixtures.
- Chat, transcript, SSE, push, and attachment payloads have exact schema coverage before native implementation claims support.
- Each required invariant passes on iOS and Android; React Native and Flutter pass it through their native bridge.
- Tests never include a real JWT, session/chat token, customer data, message text, push token, or attachment URL.

## Local verification

```bash
npm run typecheck
npm run test:protocol-fixtures
npm run test:conformance
npm run test:hygiene
npm run check:hygiene
```

`test:conformance` validates scenario manifests, fixture references, JSON syntax, and the synthetic/redacted data boundary. It does not execute native SDK behavior. A legacy prototype test never establishes v1 conformance.
