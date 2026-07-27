# SDK-team iOS local E2E app

Open `OnloLocalE2EApp.xcodeproj`, select an iPhone 17 simulator, and press Run. The app is an installable local test host: customer login → SDK identity exchange → native Support messenger → SDK logout.

## Prerequisites

- [ ] Open the ignored `Onlo.local.xcconfig` beside this README and replace
  `paste-your-public-ios-sdk-key-here` with the public iOS SDK key. The Debug
  target already includes this file through `OnloExample.xcconfig.example`.
  `ONLO_USE_DEVELOPMENT_ORIGIN = NO` uses production `https://onlo.ai`.
- [ ] Only for local SDK-team testing, set `ONLO_USE_DEVELOPMENT_ORIGIN = YES`.
  The app then uses `ONLO_DEVELOPMENT_ORIGIN`; Release builds always use the
  SDK's fixed production origin.
- [ ] For identified local E2E, the SDK-team local merchant backend is running at `https://127.0.0.1:8444`. Its `npm start` command creates its ignored local certificate automatically; this Debug project adds it to the selected simulator during build.
- [ ] Its local Onlo service settings accept bundle ID `ai.onlo.locale2e` and the public SDK key it returns after test login.
- [ ] The local Onlo server uses the matching mobile identity signing secret. Its HTTP local origin is accepted by the harness, which exposes an HTTPS-only proxy to the SDK.

## Run on iPhone 17 simulator

1. In Finder, open `OnloLocalE2EApp.xcodeproj`.

   Expected result: Xcode resolves the local `../../packages/ios` Swift package and shows the `OnloLocalE2EApp` scheme.

2. In the Xcode run-destination menu, select **iPhone 17**, then press **Run**.

   Expected result: Xcode installs the debug app in the simulator and opens its Login screen.

3. For production-backed anonymous testing, tap **Continue anonymously**. For
   local identified E2E, enable the development-origin flag, enter the local
   test login code, then tap **Log in**.

   Expected result: the default path initializes against `https://onlo.ai` and
   loads live Operator data. The explicit development path uses the configured
   Debug HTTPS origin and synthetic local identity flow.

4. Tap **Support**.

   Expected result: the SDK presents its native messenger screen. The app does not render a second chat UI.

   **Continue anonymously** exercises the installation-scoped anonymous path.
   The messenger’s configuration-controlled attachment actions use the native
   picker and camera.

5. With **Voice input** enabled in WebChat Behaviour, tap the microphone and grant the two requested permissions.

   Expected result: speech recognition fills the normal composer. The message still uses the existing text chat pipeline.

6. Tap the speaker in the Support header, then send a message.

   Expected result: the speaker changes to its enabled state and reads the completed AI reply. It does not speak historical or human-agent messages.

7. Tap **Log out**.

   Expected result: SDK logout completes before the Login screen returns; another account cannot access the prior account’s SDK state.

The app delegate requests notification permission, registers with APNs, and
forwards APNs tokens and notification taps to the same `OnloSDK` instance.
`onlo-example://support/conversations/<id>` demonstrates host deep-link
forwarding; Core re-authorises the conversation before the native messenger
opens. Native lifecycle binding owns foreground/background recovery.

## Inject a Simulator notification

1. Create a local `.apns` file with `aps.alert` plus the exact
   `conversationId`, `messageId`, and
   `notificationType: "message_available"` fields.

   Expected result: the file contains only synthetic IDs and no message
   content beyond a generic notification label.

2. Terminate or background the app, then run:

   ```bash
   xcrun simctl push booted ai.onlo.locale2e /path/to/payload.apns
   ```

   Expected result: Simulator displays the notification without an APNs key.

3. Tap the notification while the synthetic identified customer is current.

   Expected result: Core refetches the authoritative transcript and opens only
   the owner-authorized conversation. Replaying it after logout opens nothing.

Simulator injection validates host parsing, authority checks, and navigation.
It does not validate the APNs provider credential or production delivery.

## Safe diagnostics

When a login or Support action fails, the app shows a safe error code instead
of a raw server error. Its disposable simulator-app log contains only operation
names and safe codes. In Xcode, select **Window → Devices and Simulators**,
select the simulator and `OnloLocalE2EApp`, then download its container. The
file is at `AppData/Library/Caches/onlo-e2e-diagnostics.log`.

SDK and host-network events also include safe request IDs when available and
`durationMs`, so the final checklist can record evidence and timing without
content.
For a running simulator, resolve the current container with:

```bash
xcrun simctl get_app_container booted ai.onlo.locale2e data
```

Then inspect `Library/Caches/onlo-e2e-diagnostics.log` beneath that path. The
container UUID changes whenever the app is reinstalled, so do not hard-code it.
The merchant simulator writes its corresponding safe backend/proxy events to
`examples/merchant-backend/.local/merchant-backend.log`. Neither file contains
the login code, API key, JWT, signing secret, message content, headers, or raw
customer identifiers.

## Boundaries

| Component | Responsibility |
| --- | --- |
| This app | Test-only login and host-owned Support entry point. |
| Local merchant backend | Authenticates the local test flow and returns public SDK configuration plus a short-lived proof. |
| `OnloSDK` | Protected session state, outbox, lifecycle, and messenger UI. |
| Local Onlo service | Identifies the Operator from the SDK key and validates the signed customer proof. |

This is SDK-team test infrastructure, not a distributed merchant app or public SDK example. It holds entered account data and temporary credentials only in process memory and never logs them.
