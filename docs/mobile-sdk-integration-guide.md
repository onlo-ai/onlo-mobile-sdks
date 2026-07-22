# Onlo Mobile SDK integration guide

This is the concise merchant-facing guide. The definitive wire contract remains
[api-contract.md](api-contract.md); this guide does not add protocol fields.

## What the merchant app needs

- A public Onlo SDK API key for its mobile app integration.
- Its normal authenticated backend endpoint that returns a short-lived Onlo
  user JWT for the current customer.
- A host-owned place to open Support.

The API key identifies the Operator app. It is safe to embed in an app, but is
not an end-customer identity. The user JWT identifies the already authenticated
customer and is minted only by the Operator backend. Never put the HS256
signing secret in the app.

## iOS (Swift)

During local development, add [`packages/ios`](../packages/ios) as a local
Swift Package and import `OnloSDK`. No package is published yet.

```swift
import OnloSDK
import UIKit

let onlo = OnloSDK()

// App launch: the API key is the public Operator/app integration key.
try await onlo.initialize(apiKey: merchantConfiguration.onloApiKey)

// After the merchant app's normal customer login, obtain a fresh JWT from its
// own authenticated backend. The app never signs, stores, or decodes it.
let userJwt = try await merchantBackend.fetchOnloUserJwt()
try await onlo.identify(userJwt: userJwt)

// The merchant decides where Support opens. UIKit supplies the host screen.
let messenger = OnloMessengerPresenter(sdk: onlo)
try await messenger.present(from: hostViewController)

// Await this during merchant-app logout/account switch before another account
// can use Support.
try await onlo.logout()
```

For anonymous support, replace `identify(userJwt:)` with
`loginUnidentifiedUser()` after initialization. Do not call a second Onlo
login, OTP flow, `identify(userId:userHash:)`, or send profile attributes from
the app: those legacy patterns are not part of the v1 contract.

`OnloMessengerPresenter` deliberately receives a `UIViewController`; the host
chooses the button, tab, or route that opens the messenger, while the SDK owns
the actual messenger UI.

## Android, React Native, and Flutter

The intended lifecycle is the same on every platform:

```text
initialize(public API key)
loginUnidentifiedUser() OR identify(short-lived backend user JWT)
host-controlled present
logout() during account switch
```

The repository has no published Android, React Native, or Flutter release
package yet. Their native adapters must remain thin wrappers around the native
cores and may not own credentials, outbox data, JWTs, or customer data.

## Local full-stack simulator

The installable iOS simulator app and its fixed synthetic merchant backend are
SDK-team testing infrastructure, not merchant setup. Follow
[its runbook](../examples/ios-local-e2e/README.md) to verify a local server,
merchant backend, SDK, and customer-facing simulator together.

## Troubleshooting

- A backend login rejection means the locally entered test code was not
  accepted; it is unrelated to the SDK key or JWT exchange.
- `merchant_network_unavailable` means the iOS simulator cannot reach the
  local merchant backend.
- `invalid_user_jwt`, `invalid_response`, or an API error after merchant login
  means the backend and Onlo server configuration need to be compared without
  copying their secret values into the app.
- The iOS simulator keyboard haptic warning about `hapticpatternlibrary.plist`
  is an Apple Simulator environment warning. It is not emitted by Onlo and is
  unrelated to login or messenger presentation.

The local test host records only operation names and safe error codes to its
cache diagnostics file. The local merchant simulator records route categories
and HTTP statuses in its ignored `.local/merchant-backend.log`; neither log
contains login input, keys, JWTs, message text, headers, or URLs with customer
identifiers.
