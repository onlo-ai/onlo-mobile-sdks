# `onlo_flutter`

Typed Flutter facade over the iOS and Android Onlo native cores. Dart owns no session, credential, transcript, outbox, push registry, transport, or messenger UI state.

> **Status:** Unpublished (`publish_to: none`). Both release-mode example hosts
> build against exactly one sibling native Core. Publisher and repository
> approval remain pending.

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

## Monorepo-local native linking

Neither native link is an installable distribution artifact. The plugin is not published.

| Platform | Local link | Verification gate |
| --- | --- | --- |
| Android | Sibling `:onlo-android-sdk` Gradle project from `packages/android` | Android API 35 licence acceptance and a real Flutter Android host build. |
| iOS | `onlo_flutter` pod plus one sibling `OnloSDK` pod from `packages/ios` | Declare the local `OnloSDK` pod in the host Podfile; do not also add the SwiftPM product. |

For a packaged-source Android consumer, supply the approved
`onlo.android.group`, `onlo.android.artifact`, and `onlo.android.version`
Gradle properties. The plugin intentionally has no default public coordinate.

See the [API contract](../../docs/api-contract.md), [`@onlo/protocol`](../protocol/src/index.ts), and [delivery plan](../../docs/delivery-plan.md).
