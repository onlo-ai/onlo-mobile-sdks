# Android example app

Run a small Android host against the sibling Onlo SDK. The example demonstrates anonymous login, backend-proven identified login, a host-owned Support button, logout, FCM forwarding, and account-safe navigation.

> **Firebase setup is not included automatically.** Basic chat works without Firebase, but push notifications cannot be tested until you create or select a Firebase project, register the example’s Android application ID, add its `google-services.json` to `app/`, and upload the matching service-account JSON to Onlo Dashboard. Follow Firebase’s [Android project setup](https://firebase.google.com/docs/android/setup) and [FCM HTTP v1 credential](https://firebase.google.com/docs/cloud-messaging/send/v1-api#provide-credentials-manually) instructions.

## Prerequisites

- [ ] JDK 17, Android API 35, and build-tools 35.0.0.
- [ ] A public test Mobile SDK key.
- [ ] For identified login, a test account on an authenticated Operator-backend endpoint.
- [ ] For FCM testing, a Firebase project containing `ai.onlo.example`, the matching configuration and service-account files, and a Google Play-enabled emulator or physical device.

## Concepts

| File | Purpose | May contain |
| --- | --- | --- |
| `local.properties` | Machine-local build and test configuration | Android SDK path, public test key, authenticated backend URL |
| `MerchantApplication.kt` | Initializes one native Onlo client | Public SDK key only |
| `MainActivity.kt` | Demonstrates login, Support, logout, and tap routing | Safe UI state; never JWT persistence |
| `OnloFirebaseMessagingService.kt` | Forwards tokens and creates host notifications | FCM token in memory; never provider credentials |

## Run the basic flow

1. Complete the Android setup in the [go-live guide](../../docs/development-and-go-live-guide.md#tool-and-account-setup).

   Expected result: `java -version` reports Java 17 and Android API/build-tools 35 are installed after licence acceptance.

2. Copy `local.properties.example` to `local.properties`. If that file already exists, add only the example’s `ONLO_*` lines and preserve the existing `sdk.dir`.

   Expected result: the ignored file contains an Android SDK path, public test key, and authenticated backend URL. It contains no signing secret or saved JWT.

3. Keep `ONLO_USE_DEVELOPMENT_ORIGIN=false` for production `https://onlo.ai`. Enable it only for an approved Debug origin.

   Expected result: the host never guesses or ships a staging hostname.

4. Open `examples/android` in Android Studio, or build from this directory:

   ```bash
   ../../packages/android/gradlew -p . :app:assembleDebug
   ```

   Expected result: the app compiles against `../../packages/android` and initializes Onlo in `MerchantApplication`.

5. Run the app and select **Continue anonymously**.

   Expected result: the Support button enables for an anonymous native session and opens the messenger.

6. Enter a synthetic host login code and select **Complete host login**.

   Expected result: the example backend returns a short-lived JWT, Android passes it directly to native Core, and identified Support becomes ready.

7. Select **Log out / switch account** before using another test account.

   Expected result: the old transcript, outbox, unread state, and push association are blocked before the next account uses Support.

## Enable FCM

1. Register `ai.onlo.example` using Firebase’s [Android project setup](https://firebase.google.com/docs/android/setup), then place the downloaded `google-services.json` in `app/`.

   Expected result: the conditional Google Services plugin configures this host. Keep the file out of source control.

2. Generate the corresponding [FCM HTTP v1 service-account JSON](https://firebase.google.com/docs/cloud-messaging/send/v1-api#provide-credentials-manually) and upload it to the Mobile target in Onlo Dashboard. Never add it to the app.

   Expected result: Onlo can send for the example while the private provider credential remains server-side.

3. Start anonymous or signed-in Support, select **Enable support notifications**, and grant notification
   permission on a Google Play-enabled emulator or physical device.

   Expected result: the example fetches the current FCM token after anonymous
   or identified readiness, `OnloFirebaseMessagingService` forwards later rotations, and no
   permission prompt appears during SDK initialization.

4. Tap an Onlo notification.

   Expected result: `MainActivity` retains one cold-start tap until an
   anonymous or identified session is ready, forwards only `conversationId`, `messageId`,
   and `notificationType`, and Core re-authorises the current owner before
   opening the conversation.

The example pins Firebase Messaging `24.1.2` because its token callback matches protocol v1. Do not upgrade to a different targeting model without a coordinated server/protocol change.

## Success criteria

- Anonymous and identified login both enable the same native Support button.
- The example never signs, stores, decodes, or logs the user JWT.
- FCM provider credentials remain in Onlo Dashboard, not the app.
- Logout completes or safely keeps Support blocked before account switching.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Gradle cannot find the Android SDK | `sdk.dir` is missing or invalid | Preserve/add the correct SDK path in ignored `local.properties` |
| Support stays disabled | Public key, backend login, or Onlo session setup failed | Check the on-screen safe state and verify only the non-secret local configuration |
| Identified login fails | Test backend URL/session is missing or JWT expired | Authenticate the example host and request a fresh JWT |
| FCM callback never runs | Firebase app, Google Services file, or device support is incomplete | Verify `ai.onlo.example`, rebuild, and use a Google Play-enabled device |
| Notification opens no conversation | Payload or current installation failed native validation | Verify the three v1 fields and test while the authorized anonymous or identified session is active |

Next: use the [Android package guide](../../packages/android/README.md) to move the same lifecycle into your app.
