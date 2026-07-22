# Onlo iOS SDK

`OnloSDK` is a Swift Package foundation for the native iOS core (iOS 15+). It implements the v1 session lifecycle, protected Keychain credential rotation, contract DTOs/request construction, ownership-gated outbox interfaces, and adapter-safe presentation intents.

The package intentionally has no file/UserDefaults credential fallback and no SwiftUI/UIKit renderer yet. Its SDK-owned SQLite outbox encrypts sensitive payloads with an AES-GCM key held in Keychain, uses iOS file protection, and is excluded from backups. The included in-memory stores are test-only.

The public host lifecycle is deliberately limited to the SDK key and the
Operator-issued proof:

```swift
try await sdk.initialize(apiKey: sdkKey)
try await sdk.loginUnidentifiedUser()
try await sdk.identify(userJwt: userJwt)
try await sdk.logout()
let intent = try await sdk.present(conversationId: nil)
```

`initialize(apiKey:)` uses the canonical production origin `https://onlo.ai`
and derives the app identifier from the host bundle. Staging/review builds must
inject an explicit release-configured HTTPS origin through the internal native
configuration path; the SDK never guesses a staging hostname. Internal tests
inject HTTPS mock origins without making live requests.

SDK-team Debug harnesses alone expose `@_spi(DevelopmentSupport) initializeDevelopment(sdkKey:onloDevelopmentOrigin:)` for an explicit local HTTPS service. It is not a merchant integration API, is not compiled into release builds, accepts no persistence or transport injection, and must never be used as production configuration.

The public `OnloSDK()` initializer never accepts a host persistence store. Its
transactional owner-scoped SQLite store blocks an owner before logout network
work and purges that owner only after logout completes; no ordinary-file,
UserDefaults, or host-provided fallback is used.

`present(conversationId:)` fetches the transcript first when a conversation is supplied, so a notification or deep-link ID cannot bypass server authorization. A UIKit/SwiftUI adapter consumes the resulting `OnloPresentationIntent`.

Wire behavior is defined by [`@onlo/protocol`](../protocol/src/index.ts) and the versioned fixtures in [`contracts/v1`](../../contracts/v1).
