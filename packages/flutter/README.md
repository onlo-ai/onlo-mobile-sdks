# `onlo_flutter`

Typed Flutter facade over the iOS and Android Onlo native cores. Dart owns no session, credential, transcript, outbox, push registry, transport, or messenger UI state.

> **Status:** RC ready; publication pending native publication and
> physical-device qualification.

## Install

Requirements:

| Requirement | Minimum |
| --- | --- |
| Flutter | 3.27 |
| Dart | 3.6 |
| iOS | 15 |
| Android | API 24 with compile SDK 35 |
| Android Java | 17 |

```yaml
dependencies:
  onlo_flutter: 0.1.0
```

Run `flutter pub get`, then build the host normally. The plugin resolves
`OnloSDK` 0.1.0 through CocoaPods on iOS and
`ai.onlo:onlo-android-sdk:0.1.0` through Maven Central on Android. Do not add a
second native Core manually.

The package is prepared but not published. Installation succeeds only after
the native iOS/Android artifacts and then the pub.dev package are released.

## Typed surface

| Area | Facade API | Current boundary |
| --- | --- | --- |
| Lifecycle | `initialize(sdkKey:)`, `loginUnidentifiedUser()`, `loginIdentifiedUser(userJwt:)`, `logout()` | Both adapters forward to the native session core; Dart retains no session state. |
| Presentation | `present(conversationId: optional)`, `dismiss()`, `openConversation(conversationId)` | Android uses the host activity; iOS uses the current Flutter presentation host. Conversation ownership remains native. |
| Push | `setPushToken(provider:token:notificationPreference:locale:)`, `handlePushNotification(payload)` | Android accepts FCM and iOS accepts APNs; both delegate protected registration/reconciliation and authorised opening to the core. |
| Observation | `observeState()`, `observeIdentityState()`, `observeConnectionState()`, `observeUnreadCount()` | The event channel exposes native-derived lifecycle and identified-customer aggregate unread state; no inbox or credential state is retained in Dart. |
| Types | Session, identity, connection, push-result, error-code, and retry-directive types | Typed boundary values and native-safe error mapping. |
| Diagnostics | `Onlo.setLogLevel(kReleaseMode ? OnloLogLevel.off : OnloLogLevel.verbose)` | Controls native structured logging without moving diagnostic data into Dart; release hosts select `off`. |

`observeUnreadCount()` emits the server's exact aggregate for identified
users. It emits `null` for anonymous sessions and immediately at
logout/account switch. Per-conversation badges remain native.

Pass the platform token when APNs/FCM supplies it. Native memory retains a
pre-login token without contacting Onlo anonymously, then registers it after
identified login and re-registers it after an account switch.

The host obtains `userJwt` from its Operator backend. Never generate or persist it in Dart.

## Repository development

Local examples may replace the published dependencies with one sibling native
Core while developing the monorepo.

| Platform | Local link | Verification gate |
| --- | --- | --- |
| Android | Sibling `:onlo-android-sdk` Gradle project from `packages/android` | The local project replaces, rather than supplements, the Maven dependency. |
| iOS | `onlo_flutter` pod plus one root-level local `OnloSDK` pod | Do not also add the SwiftPM product. |

See the [API contract](../../docs/api-contract.md), [`@onlo/protocol`](../protocol/src/index.ts), and [delivery plan](../../docs/delivery-plan.md).
