# Onlo Flutter SDK

Add Onlo’s native support messenger to a Flutter app. Dart calls a typed plugin; the iOS and Android cores own credentials, sessions, offline messages, push, and UI.

## Prerequisites

- [ ] Flutter 3.27 or newer and Dart 3.6 or newer.
- [ ] An iOS 15+ and/or Android API 24+ host. Android builds require compile SDK 35 and Java 17.
- [ ] A public Mobile SDK key from Onlo Dashboard.
- [ ] For signed-in support, an authenticated backend endpoint that returns a fresh Onlo user JWT.

## Concepts

| Term | Meaning |
| --- | --- |
| SDK key | Public key that selects your Onlo organisation/app integration. It is safe in app configuration and is not customer identity. |
| User JWT | Short-lived proof minted by your backend for the customer already signed in to your app. Dart passes it directly to native code. |
| Native core | Onlo’s iOS or Android SDK. It owns protected state, retries, transcript, push, permissions, and messenger UI. |
| Flutter plugin | `onlo_flutter`; it forwards typed calls and native state without recreating the session in Dart. |

Never store a user JWT or Onlo session data in shared preferences, providers, blocs, Dart databases, app files, or logs.

## Step 1: Install the plugin

Add the package to `pubspec.yaml`:

```yaml
dependencies:
  onlo_flutter: 0.3.0
```

Run:

```bash
flutter pub get
```

The plugin resolves `OnloSDK` 0.3.0 on iOS and `ai.onlo:onlo-android-sdk:0.3.0` on Android. Do not add either native core manually.

Expected result: the following import resolves and both native hosts build:

```dart
import 'package:onlo_flutter/onlo_flutter.dart';
```

## Step 2: Initialize once

Initialize when the root widget starts. Keep the rest of the app usable if Support is temporarily unavailable.

```dart
class _AppState extends State<App> {
  String? supportError;

  @override
  void initState() {
    super.initState();
    _initializeOnlo();
  }

  Future<void> _initializeOnlo() async {
    try {
      await Onlo.setLogLevel(
        kReleaseMode ? OnloLogLevel.off : OnloLogLevel.verbose,
      );
      await Onlo.initialize(sdkKey: '<YOUR_PUBLIC_SDK_KEY>');
    } catch (_) {
      if (mounted) {
        setState(() => supportError = 'Support is temporarily unavailable.');
      }
    }
  }
}
```

Expected result: native code restores protected state without presenting UI or requesting permissions.

## Step 3: Choose a login path

Call one login method after your app knows whether the current customer is signed in.

### Anonymous customer

```dart
await Onlo.loginUnidentifiedUser();
```

Expected result: Support uses an installation-scoped anonymous session with no customer identifier.

### Signed-in customer

```dart
// Your authenticated app client calls your backend. The backend derives the
// stable customer ID and returns a short-lived Onlo JWT.
final userJwt = await merchantBackend.fetchOnloUserJwt();

// Pass it directly to native Onlo. Do not decode, save, or log it.
await Onlo.loginIdentifiedUser(userJwt: userJwt);
```

Expected result: the native session is attached to the customer already authenticated by your app. There is no Onlo OTP or second login.

Your backend must use an immutable, opaque customer ID for the JWT `sub`. See the [exact claim rules](../../docs/api-contract.md#operator-user-jwt).

## Step 4: Present Support

Listen to native state and enable the host button only when the session is ready:

```dart
StreamBuilder<OnloStateSnapshot>(
  stream: Onlo.observeState(),
  builder: (context, snapshot) {
    final state = snapshot.data?.session;
    final ready = state == OnloSessionState.anonymousReady ||
        state == OnloSessionState.identifiedReady;

    return FilledButton(
      onPressed: ready ? () => Onlo.present() : null,
      child: const Text('Support'),
    );
  },
)
```

Expected result: tapping the host-owned button opens the contained native messenger. Onlo does not add a floating launcher or render chat in Dart.

Use full-screen presentation only when your navigation design requires it:

```dart
await Onlo.present(presentationMode: OnloPresentationMode.fullScreen);
```

## Step 5: Handle logout and account switching

Disable Support, await Onlo logout, then finish your app’s account transition:

```dart
Future<void> logoutCustomer() async {
  setState(() => supportEnabled = false);

  try {
    await Onlo.logout();
  } finally {
    await merchantAuth.logout();
  }
}
```

Expected result: the old native owner partition is blocked before another customer can use Support. If logout throws or native state becomes `logoutPending`, keep Support disabled until recovery completes.

## Step 6: Add optional features

### Unread badge

```dart
final unreadSubscription = Onlo.observeUnreadCount().listen((count) {
  // null means anonymous, logout, or account switch.
  setSupportBadge(count ?? 0);
});

// Cancel unreadSubscription from dispose().
```

Expected result: identified customers see the exact server unread total and all account-boundary states clear it.

### Push notifications

Onlo does not install a push-provider plugin or ask for permission. Use your
app's existing APNs/FCM plugin, ask from a customer action, and forward the
current native token after anonymous or identified readiness plus every later token rotation:

```dart
import 'dart:io';

await Onlo.setPushToken(
  provider: Platform.isIOS ? OnloPushProvider.apns : OnloPushProvider.fcm,
  token: token,
);
```

When a customer taps an Onlo notification, forward the three v1 routing values:

```dart
final result = await Onlo.handlePushNotification(
  OnloPushNotificationPayload(
    conversationId: data['conversationId']!,
    messageId: data['messageId']!,
    notificationType: 'message_available',
  ),
);
```

Expected result: native code re-authorises the current customer and conversation before navigation. Route `notOnlo` through your app and do not force a stale screen open for `deferred`.

For a background or cold-start tap, wait until `observeState` reports
`OnloSessionState.anonymousReady` or `OnloSessionState.identifiedReady` before forwarding the payload. If the native
result is `deferred` because the network is unavailable, retry from the next
foreground recovery. Keep only the one transient callback value; do not persist
push payloads, tokens, or customer state in Dart.

Treat token and provider errors as push-only failures. The active chat session,
Messenger UI, transcript synchronization, and logout remain usable; forward
the current token again to re-register that installation.

### Deep links and known conversations

```dart
await Onlo.openConversation(conversationId);
```

Expected result: native code presents the conversation only after ownership validation and transcript refresh.

Images, camera, voice, themes, FAQs, and Help Center content are native and Dashboard-controlled. Do not build a parallel Dart composer or transcript store.

## API summary

| Task | API |
| --- | --- |
| Initialize | `Onlo.initialize(sdkKey:)` |
| Anonymous login | `Onlo.loginUnidentifiedUser()` |
| Identified login | `Onlo.loginIdentifiedUser(userJwt:)` |
| Present/dismiss | `Onlo.present(...)`, `Onlo.dismiss()` |
| Open conversation | `Onlo.openConversation(conversationId)` |
| Logout | `Onlo.logout()` |
| Push | `Onlo.setPushToken(...)`, `Onlo.handlePushNotification(...)` |
| Observe | `observeState`, `observeIdentityState`, `observeConnectionState`, `observeUnreadCount` |
| Safe diagnostics | `Onlo.setLogLevel(OnloLogLevel...)` |

## Success criteria

- iOS and Android builds contain exactly one matching native Onlo core.
- Anonymous and identified login both reach a ready state.
- The messenger opens only from a host-owned action and is rendered natively.
- Dart never signs, stores, logs, or decodes the user JWT.
- Logout finishes, or Support remains disabled while native logout recovery is pending, before an account switch.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `OnloBridgeUnavailableException` | The native plugin was not registered in the current build | Run `flutter clean`, `flutter pub get`, and rebuild the native host |
| iOS reports duplicate Onlo symbols | `OnloSDK` was added separately | Remove the manual SwiftPM/CocoaPods core; the Flutter plugin already resolves it |
| Android reports duplicate classes | The Maven core was added separately | Remove the manual `ai.onlo:onlo-android-sdk` dependency |
| Identified login fails | Backend JWT is invalid or expired | Fetch a fresh JWT and verify the contract claims; do not modify it in Dart |
| Support button never enables | Initialization/login failed or state is still restoring | Observe `OnloStateSnapshot` and inspect only typed safe errors |
| Old badge remains after logout | Host retained derived UI state | Treat `null` from `observeUnreadCount` as an immediate badge clear |

## Run the example

See the [Flutter host example](../../examples/flutter/README.md) for local iOS and Android builds.

## Repository development

Local examples replace published dependencies with one sibling native core per platform. Android uses the sibling Gradle project; iOS uses the plugin pod plus one root-level local `OnloSDK` pod. Never add both the local and published core.

For protocol details and advanced behavior, see the [complete integration guide](../../docs/integration-guide.md) and [API contract](../../docs/api-contract.md).

Next: run the [Flutter example](../../examples/flutter/README.md) on each native platform you support.
