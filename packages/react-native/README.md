# `@onlo-ai/react-native`

Typed React Native facade over the iOS and Android Onlo native cores. JavaScript owns no session, credential, transcript, outbox, push registry, transport, or messenger UI state.

> **Status:** RC ready; publication pending native publication and
> physical-device qualification.

The typed native-event API requires React Native 0.79 or newer.

## Install

```bash
npm install @onlo-ai/react-native@0.1.0
cd ios && pod install
```

The npm package resolves `OnloSDK` 0.1.0 through CocoaPods on iOS and
`ai.onlo:onlo-android-sdk:0.1.0` through Maven Central on Android. Do not add a
second native Core manually. Expo Go cannot load this native module; use a
development or release build.

The package is prepared but not published. Installation succeeds only after
the native iOS/Android artifacts and then the npm package are released.

## Typed surface

| Area | Facade API | Current boundary |
| --- | --- | --- |
| Lifecycle | `initialize({ sdkKey })`, `loginUnidentifiedUser()`, `loginIdentifiedUser({ userJwt })`, `logout()` | Both adapters use the fixed `react-native` family initializer and native protected state. |
| Presentation | `present({ conversationId?, presentationMode? })`, `dismiss()`, `openConversation(conversationId)` | `presentationMode` is `contained` by default or explicitly `fullScreen`. Android attaches to the current Activity; iOS uses the current React Native presentation host. Targeted presentation resolves only after native ownership validation and presenter attachment. |
| Push | `setPushToken({ provider, token, notificationPreference?, locale? })`, `handlePushNotification(payload)` | Android supports FCM; iOS supports APNs. Both use durable reconciliation and re-authorise payloads before opening a native messenger. |
| Observation | `addListener(listener)`, `observeState(listener)`, `observeIdentityState(listener)`, `observeConnectionState(listener)`, `observeUnreadCount(listener)` | Both adapters emit native-derived lifecycle and identified-customer aggregate unread state; no inbox or credential state is retained in JavaScript. |
| Types | Session, identity, connection, push-result, error-code, and retry-directive types | Typed facade validation plus native-safe error mapping. |
| Diagnostics | `setLogLevel('off' \| 'error' \| 'info' \| 'verbose')` | Controls native structured logging without moving diagnostic data into JavaScript; release hosts select `off`. |

`observeUnreadCount` emits the server's exact aggregate for identified users.
It emits `null` for anonymous sessions and immediately at logout/account
switch, so the host can clear its application badge. Per-conversation badges
remain inside the native messenger.

The Messenger UI is always rendered by the native Onlo core, so the widget-parity layout, cached conversations, typing indicator, message alignment, skeleton loading, connectivity badge, and fixed Onlo footer branding stay identical in native and React Native hosts. Use `Onlo.present()` for the contained host-app surface, or `Onlo.present({ presentationMode: 'fullScreen' })` only when the host intentionally wants a full-screen experience.

Pass the platform token when APNs/FCM supplies it. Native memory retains a
pre-login token without contacting Onlo anonymously, then registers it after
identified login and re-registers it after an account switch.

## Repository development

Local examples may replace the published dependencies with one sibling native
Core while developing the monorepo.

| Platform | Local link | Host constraint |
| --- | --- | --- |
| Android | Sibling `:onlo-android-sdk` Gradle project from `packages/android` | The local project replaces, rather than supplements, the Maven dependency. |
| iOS | `OnloReactNative` pod plus one root-level local `OnloSDK` pod | Do not also add the SwiftPM product. |

The host obtains `userJwt` from its Operator backend. Never generate or persist
it in JavaScript.

See the [API contract](../../docs/api-contract.md), [integration guide](../../docs/integration-guide.md), and [delivery plan](../../docs/delivery-plan.md).
