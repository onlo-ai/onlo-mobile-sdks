# Onlo Mobile SDKs

Add Onlo’s ready-made support Messenger to an iOS, Android, React Native, or Flutter app.

## Choose your SDK

| Platform | Complete guide | Example app |
| --- | --- | --- |
| iOS | [iOS guide](packages/ios/README.md) | [iOS example](examples/ios/README.md) |
| Android | [Android guide](packages/android/README.md) | [Android example](examples/android/README.md) |
| React Native | [React Native guide](packages/react-native/README.md) | [React Native example](examples/react-native/README.md) |
| Flutter | [Flutter guide](packages/flutter/README.md) | [Flutter example](examples/flutter/README.md) |

> **Release status:** version `0.3.2` is prepared in this repository, but the public packages are not published yet. Install only a version marked as available in **Onlo Dashboard → WebChat → Install → Mobile app**.

## Prerequisites

- An Onlo account with **Owner** or **Admin** access to WebChat.
- For push notifications, a Firebase account and project for Android FCM or an Apple Developer account with APNs access for iOS.

## Concepts

| Value | Purpose | Where it belongs |
| --- | --- | --- |
| Public SDK key | Connects the app to one Onlo Mobile SDK integration | App configuration; this value is not a secret |
| Identity secret | Signs short-lived customer identity tokens | Your backend secret manager only; never put it in the app or repository |
| User JWT | Proves which customer is signed in | Created by your backend and passed directly to the SDK; do not store or log it |

## Start in five minutes

1. Open **Onlo Dashboard → WebChat → Install → Mobile app**.
2. Choose your platform and select **Generate key**.
3. Open the platform guide above, install the package, and copy the SDK key into your app.
4. Follow this common SDK flow using the exact syntax from your platform guide:

```ts
await Onlo.initialize({ sdkKey: "<PUBLIC_SDK_KEY>" });

// Choose one login method for the current customer.
await Onlo.loginUnidentifiedUser();
// await Onlo.loginIdentifiedUser({ userJwt });

await Onlo.present();

// Call before your app logs out or changes accounts.
await Onlo.logout();
```

5. Build the app, open Messenger, and send a test message.
6. Return to the Mobile SDK page in Dashboard and check the connection status.

Expected result: the message reaches your Onlo workspace and Dashboard automatically reports a successful connection.

The snippet shows the shared flow, not copy-paste platform syntax. The complete guides include the correct imports, lifecycle setup, identity example, push registration, and Messenger presentation code.

## Features

| Feature | What it provides |
| --- | --- |
| Ready-made Messenger | Native conversation list, transcript, composer, loading, retry, and offline states |
| Send and receive messages | Durable message sending, streamed replies, conversation history, and unread state |
| Shared WebChat configuration | Supported greetings, bot details, FAQs, Help Center content, and feature settings refresh automatically |
| Themes | Supported light, dark, and brand colors are shared with the mobile Messenger |
| Anonymous and signed-in customers | Start anonymously or identify an existing app customer with a short-lived backend-signed JWT |
| Automatic connection recovery | Restores the session and refreshes conversations when the app starts, returns to the foreground, or reconnects |
| Push notifications | APNs on iOS and FCM on Android, including React Native and Flutter native runtimes |
| Image messages | Native image selection, upload progress, retry, and server-validated limits |
| Secure logout | Removes access to the previous customer’s support state before another account can use Messenger |

## You are ready when

- Messenger opens from your app’s Support button.
- A test message reaches the correct Onlo workspace.
- Dashboard confirms the SDK connection.
- Logout finishes before another customer can open Support.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| The package cannot be downloaded | Install only a version marked as available in Dashboard. |
| Messenger does not open | Confirm initialization and one login method completed, then inspect the SDK error code. |
| Dashboard does not confirm the connection | Send a test message and confirm the app uses the SDK key from the selected integration. |
| Push does not register | Follow the platform guide for APNs or FCM credentials, permission, and device-token registration. |
| Another customer cannot open Support | Keep Support disabled until the previous Onlo logout finishes. |
