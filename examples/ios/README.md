# iOS merchant integration

Embed `SupportView` in the merchant’s existing iOS app. The app supplies a public SDK key and obtains a short-lived proof from its own authenticated backend; every other session, storage, retry, and messenger concern belongs to `OnloSDK`.

> **Example format:** this directory contains copy-ready integration source, not a standalone Xcode app. Add the files to an existing iOS app target by following the steps below.

> **APNs setup is not included automatically.** Basic chat works without APNs, but push notifications cannot be tested until you have an Apple Developer account, a push-enabled App ID matching the app, an APNs `.p8` authentication key configured in Onlo Dashboard, and a signed physical device. Follow Apple’s [Push Notifications capability](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/#enable-push-notifications) and [APNs authentication-key](https://developer.apple.com/help/account/capabilities/communicate-with-apns-using-authentication-tokens/) instructions.

## Prerequisites

- [ ] An iOS 15+ app target with `packages/ios` added as a local Swift Package during development.
- [ ] A public SDK key issued for the merchant’s iOS integration.
- [ ] An existing merchant-backend endpoint that returns a fresh contract-valid user JWT for the app’s currently authenticated customer.
- [ ] For push, an Apple Developer App ID with Push Notifications enabled, an APNs `.p8` key uploaded to Onlo Dashboard, and a signed physical device.

## Concepts

| Item | Merchant iOS app responsibility | Never put here |
| --- | --- | --- |
| `sdkKey` | Supply the public Operator/app integration key to `initialize`. | A signing secret or customer identity. |
| `fetchOnloUserJwt` | Call the merchant’s existing authenticated backend after its normal customer login. | JWT signing, JWT persistence, claim decoding, or a second Onlo login. |
| `Support` action | Choose where to present the messenger. | A global launcher or an Onlo-controlled app route. |
| Logout | Await SDK logout before allowing a different merchant account to use support. | Direct manipulation of Onlo credential/storage state. |

## Run the example step by step

1. In Xcode, select the blue app project icon, select the app target, open **Package Dependencies**, click **+**, choose **Add Local…**, select `../../packages/ios`, and add the `OnloSDK` product.

   Expected result: `import OnloSDK` resolves in the merchant app target. A Swift package alone is not an installable app.

2. Copy [`SupportView.swift`](OnloExample/SupportView.swift) into the merchant app and present it from the merchant-owned support route.

   Expected result: the host app controls where customers open messenger.

3. Supply the public key and the merchant backend callback from the app’s existing configuration and login layer.

   ```swift
   SupportView(
       sdkKey: merchantConfiguration.onloPublicSdkKey,
       fetchOnloUserJwt: {
           try await authenticatedMerchantBackend.fetchOnloUserJwt()
       }
   )
   ```

   Expected result: after the merchant’s own login succeeds, the app passes a fresh JWT directly to `identify(userJwt:)`. The app neither signs nor persists it.

4. Run the app, select **Connect signed-in customer**, and then select **Support**.

   Expected result: the callback fetches a fresh user JWT and the example presents the native messenger from the host-controlled view.

5. On merchant-app logout or account switch, await `OnloSDK.logout()` through the provided view before starting support for another customer.

   Expected result: old Onlo state is inaccessible before another customer can use the messenger.

6. Copy [`OnloExampleApp.swift`](OnloExample/OnloExampleApp.swift) push
   callbacks into the app delegate, then select **Enable support notifications**
   after anonymous or signed-in Support is ready.

   Expected result: the app asks at that moment, forwards the current and
   rotated APNs token, and retains one cold-start notification tap until native
   customer authorization can complete. The `.p8` provider key remains only in
   Onlo Dashboard.

## Success criteria

- The app initializes with only the public SDK key.
- The merchant backend, not the app, mints the user JWT after customer authentication.
- The SDK handles protected state and messenger UI; the host controls presentation.
- Notification permission is requested only from the host action, and a tapped
  route opens only after native customer authorization.
- A second customer cannot use support until the prior SDK logout completes or remains safely pending.

## Troubleshooting

| Symptom | Cause | Action |
| --- | --- | --- |
| Support is unavailable at startup | SDK key, bundle identity, network, or service availability is invalid. | Inspect only safe SDK error codes and verify the integration configuration with the Onlo administrator. |
| Identified support does not connect | The merchant backend did not return a fresh valid user JWT. | Refresh the merchant app login/backend session, then request a new proof. Do not alter or decode the proof in the app. |
| Customer changed accounts | Host logout did not await SDK logout. | Block the new support action until SDK logout finishes; a pending logout intentionally keeps old state inaccessible. |

SDK-team-only local harnesses, including signing and development-origin mechanics, are documented separately in the [development and go-live guide](../../docs/development-and-go-live-guide.md#sdk-team-local-full-stack-ios-simulator).

Next: validate this integration with the merchant app’s normal customer-login flow.
