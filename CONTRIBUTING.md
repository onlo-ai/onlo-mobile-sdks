# Contributing to Onlo Mobile SDKs

Use this guide to make safe, reviewable changes to the client-only mobile SDK workspace. The native iOS and Android cores own sensitive state; React Native and Flutter remain thin bridges.

## Prerequisites

- [ ] Work from `dev`; `main` is the protected release branch.
- [ ] Read [AGENTS.md](AGENTS.md), the canonical [API contract](docs/api-contract.md), and the relevant package code before editing.
- [ ] Use synthetic fixtures and mock transport only. Keep real JWTs, tokens, customer data, message text, and attachment URLs out of the workspace and logs.
- [ ] Have the appropriate local toolchain for the package you change. Exact setup and current platform gates are in the [development and go-live guide](docs/development-and-go-live-guide.md).

## Concepts

| Term | Meaning |
| --- | --- |
| Native core | The iOS or Android SDK. It owns protected storage, session state, outbox, lifecycle, push, and messenger UI. |
| Framework bridge | The React Native or Flutter API layer. It delegates to its platform-native core and cannot persist sensitive or identified state. |
| SDK key | A public Operator/app integration key, not a customer identity or signing secret. |
| User JWT | A short-lived, Operator-backend-signed proof passed to `loginIdentifiedUser`. It is never signed or persisted by the app. |
| Canonical contract | [docs/api-contract.md](docs/api-contract.md) and [packages/protocol](packages/protocol/src/index.ts), the sole source for wire shapes and retry behavior. |
| Legacy prototype | `sdk/react-native`; historical reference only, never a supported runtime fallback. |

## Quick start from the repository root

1. Clone the repository and select the integration branch.

   ```bash
   git clone git@github.com:onlo-ai/onlo-mobile-sdks.git
   cd onlo-mobile-sdks
   git switch dev
   ```

   Expected result: `git status --short --branch` reports `dev`. Do not work directly on `main`.

2. Install the root JavaScript tooling.

   ```bash
   npm install
   ```

   Expected result: root protocol, hygiene, and conformance commands are available. The root workspace does not install a publishable mobile SDK.

3. Install optional package-local tooling only for the SDK you are testing.

   | SDK area | Command from repository root | Expected result |
   | --- | --- | --- |
   | Flutter | `cd packages/flutter && flutter pub get && cd ../..` | Flutter dependencies are resolved for local facade tests. |
   | Legacy React Native reference | `npm --prefix sdk/react-native ci` | Reference-only test dependencies are installed. This is not the supported `@onlo/react-native` package. |
   | Android | `cd packages/android && ./gradlew --version && cd ../..` | The checked-in Gradle wrapper reports Gradle 8.7 and JDK 17. It downloads build dependencies when the Android SDK is licensed. |
   | iOS | `swift build --package-path packages/ios --target OnloSDK` | The local Swift package core builds; full tests require full Xcode/XCTest. |

## Run and test

1. Run the root quality gate.

   ```bash
   npm run typecheck
   npm run test:protocol-fixtures
   npm run test:conformance
   npm run test:hygiene
   npm run check:hygiene
   ```

   Expected result: all shared checks pass using redacted fixtures; these checks do not call the public Onlo service.

2. Run the React Native package checks.

   ```bash
   npm --prefix packages/react-native run typecheck
   npm --prefix packages/react-native test
   ```

   Expected result: the typed facade and Android/iOS adapter-boundary tests pass. A real React Native host build remains a separate validation step.

3. Run the Flutter package checks.

   ```bash
   cd packages/flutter
   flutter analyze
   flutter test
   cd ../..
   ```

   Expected result: Dart facade and native-adapter source checks pass. A real Flutter host build remains a separate validation step.

4. Run native core tests when the platform toolchain is ready.

   ```bash
   swift test --package-path packages/ios

   cd packages/android
   ./gradlew testDebugUnitTest
   cd ../..
   ```

   Expected result: iOS tests require full Xcode/XCTest; Android tests require accepted Android SDK API 35/build-tools 35 licences. Neither command requires public-service access.

5. Build the local Android example after the Android core tests are available.

   ```bash
   cd examples/android
   ../../packages/android/gradlew -p . :app:assembleDebug
   ```

   Expected result: a debug host APK is assembled using local SDK sources. Do not put real keys or customer credentials in the example.

## Non-negotiable boundaries

| Area | Required behavior | Never do |
| --- | --- | --- |
| Server contract | Use confirmed fields, capabilities, retry directives, and origins only. | Invent a field, retry rule, staging hostname, or capability. |
| Customer identity | The Operator backend mints the short-lived JWT. | Put a signing secret, OTP flow, or second Onlo login in a mobile app. |
| Sensitive state | Keep credentials and identified data in native protected storage only. | Use AsyncStorage, plain files, JavaScript/Dart storage, or logs. |
| Account boundary | Make User A's state inaccessible before User B can use the SDK. | Reuse old transcripts, outbox rows, credentials, read state, or push association. |
| Attachments | Keep attachment sending disabled until the documented conversation-binding gap is resolved. | Declare media capabilities or guess a conversation ID. |
| Releases | Changes stay local until explicitly approved. | Commit, push, publish, deploy, release, tag, or change GitHub/remotes without approval. |

## Contribution workflow

1. Check the branch and existing changes.

   ```bash
   git status --short --branch
   ```

   Expected result: work begins from `dev`, and unrelated local changes are identified and preserved.

2. Locate the ownership boundary before coding.

   | Change | Primary location |
   | --- | --- |
   | Wire type, fixture, or scenario | `packages/protocol/`, `contracts/v1/`, `conformance/` |
   | iOS state, storage, transport, push, or UI | `packages/ios/` |
   | Android state, storage, transport, push, or UI | `packages/android/` |
   | React Native public API or native adapter | `packages/react-native/` |
   | Flutter public API or native adapter | `packages/flutter/` |
   | Local host behavior | `examples/` |

   Expected result: one native core remains the source of truth for each OS; no bridge duplicates its behavior.

3. Reconcile any wire-level change before implementation.

   Expected result: the field or behavior already exists in [docs/api-contract.md](docs/api-contract.md). If it does not, stop that narrow flow and report the discrepancy instead of adding a client-only protocol extension.

4. Make the smallest complete change and add focused tests.

   Expected result: untrusted input is validated at the boundary, logs are PII-free, and the test uses only redacted/synthetic data.

5. Run the focused checks, then the shared checks.

   | Area | Command | Expected result |
   | --- | --- | --- |
   | Shared TypeScript | `npm run typecheck` | Contract types compile. |
   | Protocol fixtures | `npm run test:protocol-fixtures` | Declared v1 fixture variants pass. |
   | Conformance manifests | `npm run test:conformance` | Scenarios, fixture references, and redaction boundaries validate. |
   | Hygiene | `npm run test:hygiene && npm run check:hygiene` | Sensitive/generated paths and content are rejected. |
   | React Native | `npm --prefix packages/react-native run typecheck && npm --prefix packages/react-native test` | Facade and adapter-boundary tests pass. |
   | Flutter | `cd packages/flutter && flutter analyze && flutter test` | Dart facade and bridge checks pass. |
   | iOS | `swift test --package-path packages/ios` | Core tests pass when full Xcode/XCTest is available. |
   | Android | `cd packages/android && ./gradlew testDebugUnitTest` | Native tests pass after API 35 licences and tools are installed. |

   Expected result: report commands actually run and distinguish passing local checks from unavailable platform/device checks.

6. Update the canonical documentation when public behavior changes.

   Expected result: update the existing source of truth rather than creating a conflicting parallel document. Keep [docs/api-contract.md](docs/api-contract.md) unchanged unless the server/contract owner has supplied the confirmed contract update.

7. Prepare a reviewable handoff without committing.

   Expected result: provide changed files, behavior, checks, known gates, and contract gaps. Wait for explicit approval before any Git or release action.

## Environment rules

| Environment | Allowed work | Constraint |
| --- | --- | --- |
| Local | Fixtures, mock transport, native/unit checks, and example foundations. | No real customer data or credentials. |
| Staging/review | Exact release-configured HTTPS origin and controlled E2E after approval. | Never guess or hard-code a hostname. |
| Production | `https://onlo.ai` after release authorization. | No package publication, deployment, or release without explicit approval. |

## Publishing and deployment

This repository is a monorepo, but each SDK has an independent release artifact and version. Publishing and deployment are intentionally disabled today: no publish script, registry credentials, release tag, deployment command, or GitHub automation may be run without explicit approval.

| SDK | Intended artifact | Version location | Current release state |
| --- | --- | --- | --- |
| iOS | Swift Package and/or CocoaPod | `packages/ios/Package.swift` | Local Swift Package only; distribution packaging and Xcode/device evidence remain required. |
| Android | Maven/AAR | `packages/android/build.gradle.kts` | Local Gradle library only; Maven publishing configuration and Android test evidence remain required. |
| React Native | npm `@onlo/react-native` | `packages/react-native/package.json` | `private: true`; local native sibling links must be replaced with distributable dependencies before publication. |
| Flutter | pub.dev `onlo_flutter` | `packages/flutter/pubspec.yaml` | `publish_to: none`; local native sibling links must be replaced with distributable dependencies before publication. |

1. Inspect package versions without changing them.

   ```bash
   node -p "require('./packages/react-native/package.json').version"
   rg -n '^version:' packages/flutter/pubspec.yaml
   rg -n 'version|publishing' packages/android/build.gradle.kts packages/ios/Package.swift
   ```

   Expected result: the intended version source and any missing release configuration are visible before a release plan is proposed.

2. Complete package-specific release prerequisites before requesting approval.

   ```bash
   npm --prefix packages/react-native run typecheck
   npm --prefix packages/react-native test
   cd packages/flutter && flutter analyze && flutter test && cd ../..
   swift test --package-path packages/ios
   cd packages/android && ./gradlew testDebugUnitTest && cd ../..
   ```

   Expected result: package checks and native/device evidence are recorded. The iOS and Android commands must complete successfully, not merely reach an environment gate.

3. Obtain explicit approval for the exact package, version, registry, tag, release notes, and deployment target.

   Expected result: an approved release plan exists. Only then may a designated release engineer add or run package-specific publishing configuration and commands.

> Production only: do not infer approval from a green test run. The current workspace deliberately has no supported publish or deployment command.

## Success criteria

- A change preserves one native source of truth per platform.
- Affected focused tests and shared hygiene checks pass, or a precise environment gate is recorded.
- No secret, customer data, raw message, JWT, chat/push token, or attachment URL is added.
- User A's local data cannot become visible to User B across logout or account switching.
- Documentation accurately distinguishes implemented source, verified behavior, and release-gated E2E.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| A required field is missing from the contract | The server handoff does not define the behavior. | Stop that flow and document the exact gap in [docs/client-contract-gaps.md](docs/client-contract-gaps.md); do not invent a field. |
| Android tests stop before compiling | Android API 35/build-tools licences are not accepted. | Follow the explicit developer-owned licence steps in the [go-live guide](docs/development-and-go-live-guide.md). |
| iOS tests cannot start | Full Xcode/XCTest or simulator tooling is unavailable. | Install/select full Xcode, then rerun the focused Swift test command. |
| A framework layer needs session, storage, or outbox logic | Ownership has crossed the native boundary. | Move the behavior into the iOS/Android core and expose only a typed bridge method or event. |
| A public-service test returns `sdk_not_available` | The server release state is still internal. | Continue with fixtures/mock transport; request controlled E2E only after the server owner opens the release gate. |
| A secret or customer datum appears | Test input or logging is unsafe. | Stop work, remove it through the approved process, rotate it if real, and replace it with a redacted fixture. |

## Related

- [Workspace overview](README.md)
- [API contract](docs/api-contract.md)
- [Architecture](docs/architecture.md)
- [Development and go-live guide](docs/development-and-go-live-guide.md)
- [Contract-gap review](docs/client-contract-gaps.md)

Next: update the architecture or delivery plan when a contribution changes SDK ownership or delivery scope.
