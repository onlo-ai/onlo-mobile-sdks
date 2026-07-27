# Onlo Mobile SDKs

This is the client-only workspace for Onlo’s native mobile messenger. It reuses the Onlo WebChat AI pipeline; it does not contain or change the Onlo server, database, AI pipeline, or Operator backend.

## Development status

| Area | Role | Current state |
| --- | --- | --- |
| `packages/protocol` | Versioned client/server types and fixtures | v1 route types, redacted fixtures, and lifecycle scenarios are in place |
| `packages/ios` | Native Swift SDK | Public SwiftPM/CocoaPods package; current source version is `0.2.0`. |
| `packages/android` | Native Kotlin SDK | Public Maven Central package; current source version is `0.2.0`. |
| `packages/react-native` | `@onlo-ai/react-native` package | Public npm package over the native cores; current source version is `0.2.0`. |
| `packages/flutter` | `onlo_flutter` package | Public pub.dev package over the native cores; current source version is `0.2.0`. |
| `sdk/react-native` | Legacy prototype migration reference | Excluded from root workspaces and never a supported runtime fallback. |
| `conformance` | Cross-client lifecycle and protocol checks | Redacted v1 fixtures and lifecycle scenarios; platform runners pending |
| `examples` | Host-app integration samples | Merchant-facing Android, iOS, React Native, and Flutter examples, plus a separate SDK-team-only synthetic merchant-backend simulator. |

> The complete v1 contract is [canonical](docs/api-contract.md). Local
> implementation uses redacted fixtures and synthetic test data.

Public distribution does not replace the platform qualification and device
evidence required for each release.

## Publication identities

| Surface | Versioned identity | Distribution |
| --- | --- | --- |
| iOS | `OnloSDK` `0.2.0` | SwiftPM repository tag and CocoaPods |
| Android | `ai.onlo:onlo-android-sdk:0.2.0` | Maven Central |
| React Native | `@onlo-ai/react-native@0.2.0` | npm |
| Flutter | `onlo_flutter 0.2.0` | pub.dev |

All four use the same coordinated release version. Historical `0.1.0`
qualification evidence remains in the
[release manifest](docs/release-conformance-0.1.0.md).

[`VERSION`](VERSION) is the canonical release version. Gradle generates the
Android runtime value from it; `npm run generate:version` generates the Swift
runtime constant because SwiftPM does not expose the package tag to source.
CocoaPods and registry manifests read or are checked against the same version;
`npm run check:versions` rejects drift.

## Prerequisites

- [ ] Work from the local `dev` integration branch; `main` is the protected release branch.
- [ ] Use the approved v1 wire contract in [docs/api-contract.md](docs/api-contract.md) and [packages/protocol](packages/protocol/src/index.ts).
- [ ] Keep the Onlo server repository and Operator backend out of scope for this workspace.
- [ ] Obtain a short-lived user JWT from an Operator backend when testing identified flows; never add it, a signing secret, a chat token, or customer data to this repository.

## Concepts

| Term | Meaning |
| --- | --- |
| SDK key | A public Operator/app integration key. It is not customer identity or a signing secret. |
| User JWT | A short-lived proof minted by the Operator backend after its own customer login. The SDK exchanges it but never signs or persists it. |
| Native core | The iOS or Android implementation that owns secure storage, durable outbox, lifecycle, permissions, transport, and messenger UI. |
| Framework bridge | The React Native or Flutter facade over the native core. It must not duplicate session, storage, outbox, transport, push, or UI logic. |
| Conformance | Shared scenarios that prove every client has the same server-visible lifecycle and account-boundary behavior. |
| Release origin | Production is `https://onlo.ai`; staging/review receives an exact release-configured HTTPS origin. The SDK never guesses one. |

## Workspace layout

```text
docs/              Product, integration, architecture, and v1 API contract
contracts/v1/      Language-neutral request and response examples
packages/protocol/ Shared TypeScript contract types
packages/ios/      Native iOS core foundation
packages/android/  Native Android core foundation
packages/react-native/ Canonical @onlo-ai/react-native facade
packages/flutter/  Canonical onlo_flutter facade
sdk/react-native/  Legacy reference only; excluded from root workspaces
conformance/       Cross-SDK lifecycle and protocol scenarios
examples/          Local host foundations (no keys, JWTs, or signing code)
examples/merchant-backend/ SDK-team-only synthetic Merchant authentication/JWT simulator
examples/ios-local-e2e/ SDK-team-only installable iPhone Simulator E2E host
```

## Development sequence

1. Read the canonical contract and select the build origin → production uses `https://onlo.ai`; staging/review injects its exact HTTPS origin through release configuration.
2. Implement and test native behavior with redacted fixtures and mock transport → no live customer data, credentials, or attachment URLs are required.
3. Verify the implemented React Native and Flutter native adapters in real host builds → JavaScript and Dart remain free of credentials and identified state.
4. Run shared manifest checks, then platform conformance when native toolchains are available → public-service E2E uses an enabled testing target and synthetic data.

The canonical public host API is documented in the [integration guide](docs/integration-guide.md). It includes `initialize({ sdkKey })`, `loginUnidentifiedUser()`, `loginIdentifiedUser({ userJwt })`, host-controlled `present()`, and awaited `logout()`.

## Safety rules

- Reuse the existing WebChat AI pipeline; do not create a mobile-only AI pipeline.
- Store rotating credentials only in native protected storage. Do not use AsyncStorage, plain files, JavaScript/Dart state, or logs for credentials or identified data.
- Retain one stable `clientMessageId` across every retry. Do not drop queued messages to make room.
- Revoke and partition User A’s state before User B can access the SDK after logout or account switch.
- The v1 contract limits images to JPEG, PNG, or WebP, 8 MiB each, and five per message.
- Do not commit, push, publish, deploy, release, or modify GitHub settings without explicit approval.

## Local checks

```bash
npm run typecheck
npm run test:protocol-fixtures
npm run test:conformance
npm run test:hygiene
npm run check:hygiene
```

The shared commands validate types, fixtures, conformance manifests, and repository hygiene; they do not replace native/device evidence. Package-specific commands and exact current gates are in the [development and go-live guide](docs/development-and-go-live-guide.md). The legacy React Native prototype is not a supported package or fallback.

Merchant app integration needs only the [iOS merchant example](examples/ios/README.md): a public SDK key, the merchant backend’s authenticated JWT callback, and a host-owned Support action. The separate [merchant-backend simulator](examples/merchant-backend/README.md) is SDK-team local test infrastructure, not part of that integration.

## Success criteria

- iOS and Android implement the same confirmed v1 flows and pass shared conformance scenarios.
- React Native and Flutter delegate all secure/session/outbox/UI behavior to the native core on the active OS.
- An Operator app presents the messenger from a host-owned entry point and never ships a signing secret.
- Logout and account switching make old identified history, outbox rows, credentials, read state, and push associations inaccessible before another account can use the messenger.

## Troubleshooting

| Symptom | Cause | Action |
| --- | --- | --- |
| A wire flow is described but has no exact fixture or type | The contract needs reconciliation | Stop only that narrow flow and report the exact discrepancy; do not invent fields. |
| The moved React Native code appears to work | Its legacy endpoint and AsyncStorage behavior are still present | Use it only as historical reference; implement the approved native bridge instead. |
| A platform requires its own session or outbox code | The framework boundary is being crossed | Put state ownership in the iOS/Android core and expose a typed bridge method/event. |

## Related docs

- [Contributor quick start](CONTRIBUTING.md)
- [Integration guide](docs/integration-guide.md)
- [Development and go-live guide](docs/development-and-go-live-guide.md)
- [v1 API contract](docs/api-contract.md)
- [Client contract gap review](docs/client-contract-gaps.md)
- [Architecture](docs/architecture.md)
- [Four-client delivery plan](docs/delivery-plan.md)
- [Conformance scope](conformance/README.md)
