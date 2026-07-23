# `@onlo/react-native`

Typed React Native facade over the iOS and Android Onlo native cores. JavaScript owns no session, credential, transcript, outbox, push registry, transport, or messenger UI state.

> **Status:** Unpublished (`private: true`). Android and iOS adapters are implemented against their sibling native cores. Release-host validation still requires local native dependency declarations until publication coordinates exist.

The typed native-event API requires React Native 0.79 or newer.

## Typed surface

| Area | Facade API | Current boundary |
| --- | --- | --- |
| Lifecycle | `initialize({ sdkKey })`, `loginUnidentifiedUser()`, `loginIdentifiedUser({ userJwt })`, `logout()` | Both adapters use the fixed `react-native` family initializer and native protected state. |
| Presentation | `present({ conversationId? })`, `dismiss()`, `openConversation(conversationId)` | Android attaches to the current Activity; iOS uses the current React Native presentation host. Targeted presentation resolves only after native ownership validation and presenter attachment. |
| Push | `setPushToken({ provider, token, notificationPreference?, locale? })`, `handlePushNotification(payload)` | Android supports FCM; iOS supports APNs. Both use durable reconciliation and re-authorise payloads before opening a native messenger. |
| Observation | `addListener(listener)`, `observeState(listener)`, `observeIdentityState(listener)`, `observeConnectionState(listener)`, `observeUnreadCount(listener)` | Both adapters emit native-derived lifecycle and identified-customer aggregate unread state; no inbox or credential state is retained in JavaScript. |
| Types | Session, identity, connection, push-result, error-code, and retry-directive types | Typed facade validation plus native-safe error mapping. |
| Diagnostics | `setLogLevel('off' \| 'error' \| 'info' \| 'verbose')` | Controls native structured logging without moving diagnostic data into JavaScript. |

`observeUnreadCount` emits the server's exact aggregate for identified users.
It emits `null` for anonymous sessions and immediately at logout/account
switch, so the host can clear its application badge. Per-conversation badges
remain inside the native messenger.

Pass the platform token when APNs/FCM supplies it. Native memory retains a
pre-login token without contacting Onlo anonymously, then registers it after
identified login and re-registers it after an account switch.

## Monorepo-local native linking

Neither native link is an installable distribution artifact. The package is not published.

| Platform | Local link | Host constraint |
| --- | --- | --- |
| Android | Sibling `:onlo-android-sdk` Gradle project from `packages/android` | A local host/example must include the same project dependency until release artifacts exist. |
| iOS | `OnloReactNative` pod plus one sibling `OnloSDK` pod from `packages/ios` | Declare the local `OnloSDK` pod in the host Podfile; do not also add the SwiftPM product. |

The host obtains `userJwt` from its Operator backend. Never generate or persist it in JavaScript. Expo Go cannot load this custom native module; use a development build.

See the [API contract](../../docs/api-contract.md), [integration guide](../../docs/integration-guide.md), and [delivery plan](../../docs/delivery-plan.md).
