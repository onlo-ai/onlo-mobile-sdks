# Flutter example app

Run the repository’s Flutter host against the local plugin and one local native core per platform. The example covers anonymous and identified login, native Support presentation, logout, push forwarding, and deep links.

> **Push-provider dependencies are not included.** Basic chat works without them, but push notifications do not. Android requires your own Firebase project, Android app configuration, FCM plugin, and service-account credentials; iOS requires an Apple Developer account, push-enabled App ID, APNs plugin callbacks, and an APNs authentication key. Follow the official [Firebase Android setup](https://firebase.google.com/docs/android/setup), [FCM credential setup](https://firebase.google.com/docs/cloud-messaging/send/v1-api#provide-credentials-manually), and [Apple APNs setup](https://developer.apple.com/documentation/UserNotifications/registering-your-app-with-apns) before testing push.

## Prerequisites

- [ ] Flutter 3.27+, Dart 3.6+, and the iOS/Android toolchains for the host you want to run.
- [ ] A public test Mobile SDK key.
- [ ] For identified login, an authenticated Operator-backend URL.
- [ ] For push, the external Firebase/FCM setup on Android or Apple/APNs setup on iOS described above.

## Concepts

| Item | Purpose |
| --- | --- |
| `../../packages/flutter` | Local path dependency for the typed Flutter plugin |
| `config/onlo.local.json` | Ignored public test key and backend URL; never a signing secret or JWT |
| Native core | Owns session, protected storage, transcript, offline work, push, and messenger UI |

## Run the example step by step

1. Copy `config/onlo.example.json` to `config/onlo.local.json` and replace the placeholders with a public test SDK key and, for identified login, the authenticated backend URL.

   Expected result: the ignored file contains public/runtime configuration only and no signing secret or saved JWT.

2. Install dependencies:

   ```bash
   flutter pub get
   ```

   Expected result: Flutter resolves the plugin from `../../packages/flutter`.

3. Run the selected native host:

   ```bash
   flutter run --dart-define-from-file=config/onlo.local.json
   ```

   Expected result: Onlo initializes in native code and the host shows the current native session state.

4. Select **Continue anonymously**, then **Support**.

   Expected result: native anonymous state becomes ready and the contained native messenger opens.

5. Select **Complete host login**, then **Support**.

   Expected result: the host backend returns a short-lived JWT, Dart passes it directly to native code, and identified Support becomes ready.

6. Select **Log out / switch account** before using another test account.

   Expected result: native logout blocks the previous owner before another account can open Support.

7. Verify release hosts:

   ```bash
   flutter build apk --release --dart-define-from-file=config/onlo.local.json
   flutter build ios --release --no-codesign --dart-define-from-file=config/onlo.local.json
   ```

   Expected result: each selected host compiles with native diagnostics off because `kReleaseMode` is true.

## Add push for a release build

The example does not install a Firebase/APNs plugin because the host app owns
that choice. Without that external provider setup, push cannot work. Connect your existing plugin to `forwardPushTokenToOnlo` after
`OnloSessionState.anonymousReady` or `OnloSessionState.identifiedReady` and on every token refresh. Ask for
permission from a clear customer action, not during `Onlo.initialize`.

For a notification tap, wait for either ready state, then call
`forwardOnloNotification`. If it returns `deferred`, retry after the next
foreground/network recovery. Do not persist the token, payload, or customer
state in Dart. Test both signed iOS and Android builds before release.
Token or provider errors must remain push-only; Support and logout stay usable.

## Success criteria

- Both native hosts resolve one plugin and one matching native core.
- Dart contains no session, credential, transcript, or outbox implementation.
- Anonymous and identified flows present the same native messenger.
- Logout completes, or Support remains disabled while logout recovery is pending, before account switching.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Plugin is unavailable | Dependencies or the native host were not rebuilt | Run `flutter clean`, `flutter pub get`, and rebuild the platform host |
| Duplicate iOS symbols or Android classes | A native core was added beside the plugin | Remove the manual native dependency; the plugin resolves the core |
| Support stays disabled | SDK key, initialization, or selected login flow failed | Check the safe on-screen state and verify `onlo.local.json` |
| Identified login fails | Backend URL/session is missing or JWT expired | Authenticate the example and request a fresh JWT |

Next: use the [Flutter package guide](../../packages/flutter/README.md) to move the same lifecycle into your app.
