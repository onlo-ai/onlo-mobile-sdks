# Onlo React Native SDK

Add Onlo’s native support messenger to a React Native app. JavaScript calls a typed facade; the iOS and Android cores own credentials, sessions, offline messages, push, and UI.

## Prerequisites

- [ ] React Native 0.79 or newer, React 19 or newer, and Node.js 20 or newer.
- [ ] A native iOS 15+ and/or Android API 24+ project. Expo Go is not supported; use a development or release build.
- [ ] A public Mobile SDK key from Onlo Dashboard.
- [ ] For signed-in support, an authenticated backend endpoint that returns a fresh Onlo user JWT.

## Concepts

| Term | Meaning |
| --- | --- |
| SDK key | Public key that selects your Onlo organisation/app integration. It is safe in app configuration and is not customer identity. |
| User JWT | Short-lived proof minted by your backend for the customer already signed in to your app. JavaScript passes it directly to native code. |
| Native core | Onlo’s iOS or Android SDK. It owns protected state, retries, transcript, push, permissions, and messenger UI. |
| Facade | `@onlo-ai/react-native`; it validates typed inputs and forwards calls/events without recreating native state in JavaScript. |

Never store a user JWT or Onlo session data in AsyncStorage, Redux, Zustand, app files, or logs.

## Step 1: Install the package

```bash
npm install @onlo-ai/react-native@0.3.0
cd ios && pod install
```

The package resolves `OnloSDK` 0.3.0 on iOS and `ai.onlo:onlo-android-sdk:0.3.0` on Android. Do not add either native core manually.

Expected result: this import resolves in TypeScript and both native projects build:

```ts
import {Onlo} from '@onlo-ai/react-native';
```

> Expo: create a development build after installing the package. Expo Go cannot load custom native modules.

## Step 2: Initialize once

Initialize near the root of the app. Keep the rest of the app usable if Support is temporarily unavailable.

```tsx
import React, {useEffect} from 'react';
import {Onlo} from '@onlo-ai/react-native';

export function App() {
  useEffect(() => {
    void Onlo.setLogLevel(__DEV__ ? 'verbose' : 'off')
      .then(() => Onlo.initialize({sdkKey: '<YOUR_PUBLIC_SDK_KEY>'}))
      .catch(() => {
        // Show a safe "Support unavailable" state if needed.
      });
  }, []);

  return <YourAppRoutes />;
}
```

Expected result: native code restores protected state without presenting UI or requesting permissions.

## Step 3: Choose a login path

Call one login method after your app knows whether the current customer is signed in.

### Anonymous customer

```ts
await Onlo.loginUnidentifiedUser();
```

Expected result: Support uses an installation-scoped anonymous session with no customer identifier.

### Signed-in customer

```ts
// Your endpoint authenticates the existing app session. Your backend derives
// the stable customer ID and signs a short-lived Onlo JWT.
const response = await fetch('https://your-api.example.com/onlo/user-jwt', {
  method: 'POST',
  credentials: 'include',
});

if (!response.ok) throw new Error('Could not prepare Support');
const {userJwt} = (await response.json()) as {userJwt: string};

// Pass it directly to native Onlo. Do not decode, save, or log it.
await Onlo.loginIdentifiedUser({userJwt});
```

Expected result: the native session is attached to the customer already authenticated by your app. There is no Onlo OTP or second login.

Your backend must use an immutable, opaque customer ID for the JWT `sub`. See the [exact claim rules](../../docs/api-contract.md#operator-user-jwt).

## Step 4: Present Support

Subscribe to native state, enable your Support button when ready, and remove the subscription on unmount:

```tsx
import React, {useEffect, useState} from 'react';
import {Button} from 'react-native';
import {Onlo, type OnloSessionState} from '@onlo-ai/react-native';

export function SupportButton() {
  const [state, setState] = useState<OnloSessionState>('uninitialized');

  useEffect(() => {
    const subscription = Onlo.observeState(setState);
    return () => subscription.remove();
  }, []);

  const ready = state === 'anonymousReady' || state === 'identifiedReady';

  return (
    <Button
      title="Support"
      disabled={!ready}
      onPress={() => void Onlo.present()}
    />
  );
}
```

Expected result: tapping the host-owned button opens the contained native messenger. Onlo does not add a floating launcher or render chat in JavaScript.

Use full-screen presentation only when your navigation design requires it:

```ts
await Onlo.present({presentationMode: 'fullScreen'});
```

## Step 5: Handle logout and account switching

Disable Support, await Onlo logout, then finish your app’s account transition:

```ts
async function logoutCustomer() {
  setSupportEnabled(false);

  try {
    await Onlo.logout();
  } finally {
    await merchantAuth.logout();
  }
}
```

Expected result: the old native owner partition is blocked before another customer can use Support. If `Onlo.logout()` fails or native state becomes `logoutPending`, keep Support disabled until recovery completes.

## Step 6: Add optional features

### Unread badge

```ts
useEffect(() => {
  const subscription = Onlo.observeUnreadCount(count => {
    // null means anonymous, logout, or account switch.
    setSupportBadge(count ?? 0);
  });
  return () => subscription.remove();
}, []);
```

Expected result: identified customers see the exact server unread total and all account-boundary states clear it.

### Push notifications

Onlo does not install a push-provider library or ask for permission. Use your
app's existing APNs/FCM library, ask from a customer action, and forward the
current native token after anonymous or identified readiness plus every later token rotation:

```ts
import {Platform} from 'react-native';

await Onlo.setPushToken({
  provider: Platform.OS === 'ios' ? 'apns' : 'fcm',
  token,
});
```

When a customer taps an Onlo notification, forward the three v1 routing values:

```ts
const result = await Onlo.handlePushNotification({
  conversationId: data.conversationId,
  messageId: data.messageId,
  notificationType: 'message_available',
});
```

Expected result: native code re-authorises the current customer and conversation before navigation. Handle `notOnlo` with your app’s normal notification router and `deferred` without forcing a stale screen open.

For a background or cold-start tap, wait until `observeState` reports
`anonymousReady` or `identifiedReady` before forwarding the payload. If the native result is
`deferred` because the network is unavailable, retry from the next foreground
recovery. Keep only the one transient callback value; do not persist push
payloads, tokens, or customer state in JavaScript.

Treat token and provider errors as push-only failures. The active chat session,
Messenger UI, transcript synchronization, and logout remain usable; forward
the current token again to re-register that installation.

### Deep links and known conversations

```ts
await Onlo.openConversation(conversationId);
```

Expected result: native code presents the conversation only after ownership validation and transcript refresh.

Images, camera, voice, themes, FAQs, and Help Center content are native and Dashboard-controlled. Do not build a parallel JavaScript composer or transcript store.

## API summary

| Task | API |
| --- | --- |
| Initialize | `Onlo.initialize({sdkKey})` |
| Anonymous login | `Onlo.loginUnidentifiedUser()` |
| Identified login | `Onlo.loginIdentifiedUser({userJwt})` |
| Present/dismiss | `Onlo.present(options?)`, `Onlo.dismiss()` |
| Open conversation | `Onlo.openConversation(conversationId)` |
| Logout | `Onlo.logout()` |
| Push | `Onlo.setPushToken(options)`, `Onlo.handlePushNotification(payload)` |
| Observe | `observeState`, `observeIdentityState`, `observeConnectionState`, `observeUnreadCount` |
| Safe diagnostics | `Onlo.setLogLevel('off' | 'error' | 'info' | 'verbose')` |

## Success criteria

- iOS and Android builds contain exactly one matching native Onlo core.
- Anonymous and identified login both reach a ready state.
- The messenger opens only from a host-owned action and is rendered natively.
- JavaScript never signs, stores, logs, or decodes the user JWT.
- Logout finishes, or Support remains disabled while native logout recovery is pending, before an account switch.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Native module is unavailable | The app is running in Expo Go or was not rebuilt after installation | Use a development/release build, run `pod install` for iOS, and rebuild both native apps |
| iOS reports duplicate Onlo symbols | `OnloSDK` was added separately | Remove the manual SwiftPM/CocoaPods core; the npm package already resolves it |
| Android reports duplicate classes | The Maven core was added separately | Remove the manual `ai.onlo:onlo-android-sdk` dependency |
| Identified login fails | Backend JWT is invalid or expired | Fetch a fresh JWT and verify the contract claims; do not modify it in JavaScript |
| Support button never enables | Initialization/login failed or state is still restoring | Observe `OnloSessionState` and inspect only typed safe errors |
| Old badge remains after logout | Host retained derived UI state | Treat `null` from `observeUnreadCount` as an immediate badge clear |

## Run the example

See the [React Native host example](../../examples/react-native/README.md) for local iOS and Android builds.

## Repository development

Local examples replace published dependencies with one sibling native core per platform. Android uses the sibling Gradle project; iOS uses `OnloReactNative` plus one root-level local `OnloSDK` pod. Never add both the local and published core.

For protocol details and advanced behavior, see the [complete integration guide](../../docs/integration-guide.md) and [API contract](../../docs/api-contract.md).

Next: run the [React Native example](../../examples/react-native/README.md) on each native platform you support.
