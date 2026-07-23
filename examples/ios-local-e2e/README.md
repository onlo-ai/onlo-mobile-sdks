# SDK-team iOS local E2E app

Open `OnloLocalE2EApp.xcodeproj`, select an iPhone 17 simulator, and press Run. The app is an installable local test host: customer login → SDK identity exchange → native Support messenger → SDK logout.

## Prerequisites

- [ ] The SDK-team local merchant backend is running at `https://127.0.0.1:8444`. Its `npm start` command creates its ignored local certificate automatically; this Debug project adds it to the selected simulator during build.
- [ ] Its local Onlo service settings accept bundle ID `ai.onlo.locale2e` and the public SDK key it returns after test login.
- [ ] The local Onlo server uses the matching mobile identity signing secret. Its HTTP local origin is accepted by the harness, which exposes an HTTPS-only proxy to the SDK.

## Run on iPhone 17 simulator

1. In Finder, open `OnloLocalE2EApp.xcodeproj`.

   Expected result: Xcode resolves the local `../../packages/ios` Swift package and shows the `OnloLocalE2EApp` scheme.

2. In the Xcode run-destination menu, select **iPhone 17**, then press **Run**.

   Expected result: Xcode installs the debug app in the simulator and opens its Login screen.

3. Enter the local test login code, then tap **Log in**.

   Expected result: the app asks the local merchant backend for a temporary merchant session and user JWT, initializes the SDK against the explicit Debug HTTPS origin returned by that backend, and identifies the fixed synthetic test subject.

4. Tap **Support**.

   Expected result: the SDK presents its native messenger screen. The app does not render a second chat UI.

5. With **Voice input** enabled in WebChat Behaviour, tap the microphone and grant the two requested permissions.

   Expected result: speech recognition fills the normal composer. The message still uses the existing text chat pipeline.

6. Tap the speaker in the Support header, then send a message.

   Expected result: the speaker changes to its enabled state and reads the completed AI reply. It does not speak historical or human-agent messages.

7. Tap **Log out**.

   Expected result: SDK logout completes before the Login screen returns; another account cannot access the prior account’s SDK state.

## Safe diagnostics

When a login or Support action fails, the app shows a safe error code instead
of a raw server error. Its disposable simulator-app log contains only operation
names and safe codes. In Xcode, select **Window → Devices and Simulators**,
select the simulator and `OnloLocalE2EApp`, then download its container. The
file is at `AppData/Library/Caches/onlo-e2e-diagnostics.log`.

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
