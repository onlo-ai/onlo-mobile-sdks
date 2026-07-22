# Mobile SDK development and go-live guide

Use this guide to prepare the Operator account, backend, mobile hosts, and local tooling for Onlo mobile SDK development. It is a readiness reference, not a deployment authorization: no package is published and no production connection is enabled from this workspace.

## Current status

| Environment | What can be done now | What is blocked |
| --- | --- | --- |
| Local | Implement and mock-test native/bridge behavior with synthetic fixtures, mock transport, and redacted data. Local host foundations are available under `examples/`. | Android native test execution awaits Android API 35/build-tools licence acceptance; full iOS XCTest/simulator execution awaits full Xcode. React Native/Flutter host-native compilation remains unverified. Local implementation is not server-gated. |
| Staging | Configure the exact HTTPS origin injected by release configuration. | Public-service E2E alone is server release-gated while the release state remains `internal`. Never guess a hostname. |
| Production | Use `https://onlo.ai` only after release authorization. | Launch, publishing, deployment, and release actions remain prohibited without explicit approval. |

## Concepts

| Term | Meaning | Owner |
| --- | --- | --- |
| SDK key | Public Operator/app integration key. It selects the Operator integration; it is not an end-customer identity or signing secret. | Operator admin / mobile host |
| User JWT | Short-lived signed proof minted by the Operator backend after its own customer login. The SDK exchanges it but never signs or persists it. | Operator backend |
| Native core | iOS or Android implementation that owns credentials, outbox, lifecycle, permissions, transport, and messenger UI. | SDK team |
| Framework bridge | React Native or Flutter API that delegates to a native core. It cannot own sensitive state. | SDK team |
| Monorepo-local native link | React Native and Flutter compile sibling iOS/Android core source during local development. These links are unpublished and are not installable release artifacts. | SDK team |
| WebChat pipeline | The existing Onlo AI/chat pipeline used by web and mobile. Mobile must not create a separate AI path. | Onlo server team |
| Release origin | Production is `https://onlo.ai`; staging/review uses an exact release-configured HTTPS origin. Local overrides are development-only. | Release configuration |
| E2E release gate | A public session returns `503 sdk_not_available` while the service release state is `internal`; this is not an identity failure. | Onlo server owner |

## Prerequisites

- [ ] Work from local `dev`; leave `main` as the protected release branch.
- [ ] Read the [API contract](api-contract.md) and [integration guide](integration-guide.md).
- [ ] Assign an Operator admin, Operator backend engineer, mobile host engineer, and Onlo server owner.
- [ ] JDK 17, Gradle, and `adb` are installed for Android work; platform 35/build tools require explicit Android licence acceptance.
- [ ] Use Swift Package Manager outside the nested sandbox for iOS package checks; full Xcode/simulator tooling is not installed or selected.
- [ ] Keep real JWTs, signing secrets, chat tokens, push tokens, customer data, messages, and attachment URLs out of the repository, fixtures, logs, and issue text.

## Tool and account setup

1. Have the Operator admin create or locate the public SDK key, and have the mobile host engineer record the iOS bundle ID and Android application ID outside source control.

   Expected result: the host has a public integration key and stable app identifiers; no customer identity or signing secret is placed in the app.

2. Accept Android SDK licences, then install the required platform and build tools.

   ```bash
   sdkmanager --licenses
   sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"
   java -version
   adb version
   gradle --version
   sdkmanager --list
   ```

   Expected result: JDK 17, `adb`, and Gradle report versions, and `platforms;android-35` plus `build-tools;35.0.0` appear in the installed SDK packages. Licence acceptance is an explicit local developer action; do not automate it in repository scripts.

3. Install the full Xcode application through the approved macOS distribution, launch it once, accept its licence, and select it as the active developer directory.

   ```bash
   sudo xcodebuild -license accept
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -runFirstLaunch
   xcodebuild -version
   xcrun simctl list devices available
   ```

   Expected result: `xcodebuild` reports the selected full Xcode installation and `simctl` lists available simulators. These commands require local administrator authority and must be run by the developer, not an SDK test.

4. Verify the JavaScript and Flutter toolchains before running their focused tests.

   ```bash
   node --version
   npm --version
   flutter --version
   flutter doctor -v
   ```

   Expected result: Node/npm and Flutter report usable versions; any Flutter platform warning is resolved before device or simulator validation.

## Account and integration setup

The dashboard's exact screens and mobile-integration controls are [VERIFY]. Use the actions below, not assumed UI labels.

| Owner | Manual action | Expected result | Never do |
| --- | --- | --- | --- |
| Operator admin | Confirm the existing WebChat AI configuration is the experience mobile should reuse. | Mobile is scoped to the same Operator/WebChat pipeline. | Create a separate mobile AI pipeline. |
| Operator admin | Create or obtain the public mobile SDK key for the intended Operator/app integration. Record its owner, app identifiers, and rotation contact outside source control. | A public integration key is available to the app build. | Treat the key as customer identity or use it as a signing secret. |
| Mobile host engineer | Confirm the iOS bundle ID and Android application ID that will be sent during session bootstrap. | Stable app identifiers are ready for the native build. | Substitute a customer identifier or arbitrary host endpoint. |
| Operator backend engineer | Prepare an authenticated backend endpoint that mints the contract-required short-lived HS256 user JWT for the current app customer. | The backend, not the device, owns the signing secret and proof creation. | Put the signing secret in an app, test fixture, log, CI variable visible to clients, or JavaScript/Dart storage. |
| Release engineer | Inject the exact approved HTTPS staging/review origin into the release configuration when needed. | Native cores receive an explicit origin; production stays `https://onlo.ai`. | Guess a hostname or let a host app choose the Onlo API origin. |

## Contract and origin boundary

The [API contract](api-contract.md) is complete and authoritative. Additive server behavior must first be reconciled there; if a field is absent or conflicts, stop only that flow and report the exact discrepancy.

| Environment | Origin rule | Local test rule |
| --- | --- | --- |
| Local | Explicit development-only override; never ship it. | Use synthetic fixtures, mock transport, and redacted identities. |
| Staging/review | Inject the exact release-configured HTTPS origin. | Do not guess or hard-code a hostname. |
| Production | `https://onlo.ai` | Public-service E2E is release-gated while discovery reports `internal`. |

## Local development workflow

1. Check the branch and workspace state.

   ```bash
   git status --short --branch
   ```

   Expected result: work is on `dev`; generated dependencies and build outputs are ignored.

2. Review the contract before changing a client boundary.

   Expected result: every new request, response, error, and state transition has a server-confirmed shape. Stop if it does not.

3. Run the focused checks for the code you changed. Shared checks are local evidence; platform commands are evidence only when their toolchain actually completes.

   | Area | Command | Expected result |
   | --- | --- | --- |
   | Shared types | `npm run typecheck` | Strict TypeScript contract check passes. |
   | Protocol fixtures | `npm run test:protocol-fixtures` | Declared protocol fixture variants and boundaries pass focused validation. |
   | Conformance manifests | `npm run test:conformance` | Scenario shape, fixture references, JSON parsing, and synthetic/redacted policy pass; native behavior is not executed. |
   | Hygiene unit tests | `npm run test:hygiene` | Deterministic path/content-boundary tests pass. |
   | Repository hygiene | `npm run check:hygiene` | Tracked and non-ignored files pass the safe path/content preflight. |
   | New React Native facade | `npm --prefix packages/react-native run typecheck && npm --prefix packages/react-native test` | Typed facade and adapter boundary checks pass; a real RN host-native build is still required. |
   | Legacy React Native prototype | `npm --prefix sdk/react-native run typecheck && npm --prefix sdk/react-native test` | Reference-only regression tests pass; this is not v1 conformance. |
   | Flutter facade | `(cd packages/flutter && flutter test)` | Dart facade tests pass without Dart-held SDK state. |
   | iOS core | `swift test --package-path packages/ios` | Requires full Xcode/XCTest for complete execution; source package build is a narrower check. |
   | Android core | `packages/android/gradlew -p packages/android testDebugUnitTest` | The checked-in Gradle 8.7 wrapper runs Android tests after JDK 17 and Android API 35/build tools are installed through accepted licences. |
   | Fixture syntax | `find contracts/v1 conformance/scenarios -type f -name '*.json' -print0 \| xargs -0 jq empty` | All redacted JSON fixtures parse. |

   Expected result: shared checks provide local contract/fixture/hygiene evidence. Native behavioral evidence is recorded only after the platform-specific command actually runs.

4. Test with synthetic data and mock transport before public-service E2E.

   Expected result: local work uses no real customer messages, JWTs, tokens, push tokens, or attachment URLs; native behavior counts as evidence only after its focused test runs.

5. Keep the host boundary narrow.

   Expected result: the host calls `initialize`, one login method, `present`, `dismiss`, and `logout`; native code remains the only owner of credentials, outbox, messenger state, and recovery.

6. Link framework hosts only to the checked-in sibling native cores during local development.

   Expected result: React Native and Flutter exercise one native core per platform. These path/project/pod links are not installable release packages and must not be presented as publication artifacts.

## SDK-team local full-stack iOS simulator

The local merchant-backend simulator is **SDK-team-only** integration infrastructure. It does not alter the Onlo server contract and uses one fixed synthetic test subject held in process memory. Merchant app developers do not configure or call it; they use their existing authenticated backend as described in the [iOS merchant integration](../examples/ios/README.md).

| Component | Local responsibility | Must not contain |
| --- | --- | --- |
| iOS host app | Presents merchant login UI, retains an ephemeral merchant session, calls the SDK. | Onlo signing secret, persistent user JWT, customer data. |
| Merchant simulator | Authenticates a local test login code for its fixed synthetic test subject and creates the documented HS256 proof. | Production data, an Onlo chat token, Onlo server logic. |
| Local Onlo service | Selects the Operator from the public SDK key and verifies the user JWT after identity exchange. | A separate mobile AI pipeline. |
| Onlo iOS SDK | Exchanges the proof, owns protected credentials/outbox/UI, and presents messenger. | A signing key or host-customer authentication implementation. |

1. Configure the local Onlo service with the intended public SDK key, iOS bundle ID, and mobile identity secret. Keep the exact local service origin HTTPS.

   Expected result: anonymous bootstrap identifies the intended Operator before any customer proof is supplied.

2. Configure and start [`examples/merchant-backend`](../examples/merchant-backend/README.md) using only local terminal values and a simulator-trusted TLS certificate.

   Expected result: the merchant simulator can authenticate the local test login code and sign a 180-second HS256 proof for its fixed synthetic subject.

3. In the iOS app target’s Debug Info.plist, set `ONLO_SDK_KEY`, `ONLO_DEVELOPMENT_ORIGIN`, and `MERCHANT_BACKEND_ORIGIN` from a private `.xcconfig`. Do not add those values to source control.

   Expected result: `initializeDevelopment` is available only in Debug and receives exact HTTPS origins; a Release build uses only `https://onlo.ai`.

4. Start the [installable iOS E2E host](../examples/ios-local-e2e/README.md), then enter the local merchant login code.

   Expected result: the host calls the merchant simulator, receives a short-lived proof, calls `loginIdentifiedUser`, and the local Onlo service resolves the signed opaque subject for that Operator.

5. Use the host’s **Log out** action, then sign in again and open Support.

   Expected result: the prior customer’s transcript, outbox, unread state, push intent, and protected session are inaccessible before the second customer becomes usable.

## Manual test matrix

| Test | Setup | Pass condition | Current availability |
| --- | --- | --- | --- |
| Anonymous lifecycle | Redacted session fixtures and a native test transport. | Bootstrap/resume preserve protected credential rotation and never expose a chat token to a framework bridge. | Platform-specific test status; public-service E2E release-gated |
| Identified lifecycle | Synthetic compact JWT fixture and mock transport. | `loginIdentifiedUser({ userJwt })` exchanges proof without a second customer login or local JWT persistence. | Platform-specific test status; public-service E2E release-gated |
| Account switch | Two synthetic test accounts; invoke logout before the second login. | Old history, outbox work, credentials, read state, and push association are inaccessible before the next account uses the SDK. | Platform-specific test status; public-service E2E release-gated |
| Offline outbox | Disable network after creating a synthetic send. | One stable `clientMessageId` survives retry and a duplicate acceptance does not create another turn. | Platform-specific test status; public-service E2E release-gated |
| Transcript/deep link | Synthetic conversation ID and authorised transcript response. | The core fetches the transcript before presentation; push/deep-link data is only a hint. | Native source/mock coverage; device evidence pending |
| Attachments | Synthetic JPEG, PNG, or WebP up to 8 MiB; no more than three. | Intent, completion, receipt, and chat payload follow the confirmed fixture. | Blocked: `ChatRequest` has no required `conversationId` for attachment intent; do not implement until contract reconciliation |
| Push | Synthetic APNs/FCM token fixture after explicit host-controlled permission and intent. | Opening a notification re-syncs the authorised transcript before showing content. | Native source/mock coverage; device evidence pending |
| Configuration | Redacted configuration, ETag, and 304 fixtures. | Compatible revision applies atomically; offline cache remains valid. | Native source/mock coverage; platform execution evidence pending |

## Staging readiness procedure

1. Add the exact approved staging origin through release configuration.

   Expected result: the host app cannot override the origin, and the legacy prototype endpoint is never reused.

2. Run the manual matrix on real iOS and Android devices using synthetic Operator accounts after the release gate permits public-service E2E. Exclude attachment sending until its contract gap is resolved.

   Expected result: evidence covers anonymous use, identity exchange, logout/account switch, offline recovery, push, config refresh, and deep-link authorization. Attachment evidence remains excluded until contract reconciliation.

3. Review logs and artifacts for privacy.

   Expected result: logs contain only safe code, request ID, SDK/runtime version, and duration; no end-customer content or credentials remains.

## Production go-live checklist

- [ ] The Onlo server owner has approved the production origin and set the public mobile release state.
- [ ] The exact configuration, retry, JWT, and capability contracts are versioned and covered by redacted fixtures.
- [ ] iOS and Android native cores have completed protected-storage, outbox, config, push, UI, lifecycle, and account-boundary device/conformance evidence.
- [ ] React Native and Flutter native bindings have completed host-native compile and device evidence and hold no sensitive state in JavaScript or Dart.
- [ ] The attachment `conversationId` contract gap is reconciled and attachment implementation has its own fixture/conformance/device evidence.
- [ ] Operator backend signing stays server-only and has been security reviewed.
- [ ] Real-device staging evidence shows no User A data can appear for User B after logout or account switch.
- [ ] Package names are confirmed (`@onlo/react-native` and `onlo_flutter`); publishing remains disabled until explicit approval.
- [ ] A designated approver has explicitly authorized publication, deployment, release creation, and any GitHub changes.

## Safe rollback and support posture

| Situation | Action | Expected result |
| --- | --- | --- |
| Server rejects sessions | Surface the safe server error and stop automatic guessing/retries. | No false customer identity failure or endpoint fallback. |
| Suspected account-boundary defect | Hide the messenger, block the old owner partition, and escalate to the SDK/server owners. | No further access to old local state. |
| Signing-key concern | Disable or rotate server-side credentials through the Operator/Onlo control plane. | No secret is changed or distributed through a mobile app. |
| Production incident | Use the server-approved release control; preserve only PII-free diagnostic metadata. | Mobile does not fall back to the prototype or a separate AI pipeline. |

## Troubleshooting

| Symptom | Cause | Action |
| --- | --- | --- |
| `config_unavailable` | The server cannot currently provide configuration. | Retain last-known-good configuration and follow the contract's `after_backoff` directive. |
| `sdk_not_available` | The server mobile release state is still internal. | Ask the Onlo server owner to complete the controlled release state change. |
| Identified login fails | The backend token violates the contract or server verification rejected it. | Mint a fresh backend token under the documented HS256 claim requirements; do not alter it in the app. |
| Android tests cannot start | Android platform 35/build tools have not been installed because licences are not accepted. | Accept the required Android SDK licences, then install the requested platform/build tools. |
| iOS simulator tests cannot start | Full Xcode/simulator tooling is not installed or selected. | Run Swift package tests outside the nested sandbox, or select/install Xcode when simulator evidence is needed. |
| A legacy prototype test passes | It validates historical behavior only. | Use it as a parsing/regression reference; do not use its endpoint, storage, or session design. |
| A secret or customer datum appears in output | Test data or logging is unsafe. | Stop, remove it from the workspace through the approved process, rotate affected credentials if real, and replace it with a redacted fixture. |

## Success criteria

- An Operator can prepare the same WebChat-backed mobile integration without placing a signing secret in an app.
- Developers can run local checks and know which tests are fixtures versus real-device evidence.
- Local implementation and fixture/mock-transport coverage run without public-service access.
- Public-service E2E begins only when the Onlo server release state is public and an explicit staging/review origin is configured where applicable.
- Production cannot proceed without explicit approval and complete native/bridge conformance evidence.

Next: run the platform conformance matrix against mock transport, then collect controlled public-service E2E evidence after the release gate opens.
