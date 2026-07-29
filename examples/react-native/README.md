# React Native example app

Run the repository’s React Native 0.86 host against the local bridge and one local native core per platform. The example covers anonymous and identified login, native Support presentation, logout, push forwarding, and deep links.

## Prerequisites

- [ ] Node.js 20 and the React Native iOS/Android toolchains.
- [ ] A public test Mobile SDK key.
- [ ] For identified login, an authenticated Operator-backend URL.
- [ ] A development or release build; Expo Go cannot load this native module.

## Concepts

| Item | Purpose |
| --- | --- |
| `file:../../packages/react-native` | Uses the local typed bridge instead of the published npm package |
| `onlo.config.ts` | Checked-in placeholder shape for the public key and backend URL; never a signing secret or JWT |
| Native core | Owns session, protected storage, transcript, offline work, push, and messenger UI |

## Run the example step by step

1. Install JavaScript dependencies from this directory:

   ```bash
   npm ci
   ```

   Expected result: the app resolves `file:../../packages/react-native`.

2. Follow the [monorepo native-link instructions](../../packages/react-native/README.md#repository-development) for the platform you want to run.

   Expected result: iOS or Android contains exactly one local native Onlo core, not a local-plus-published duplicate.

3. In your local working copy, replace the empty values in `onlo.config.ts` with a public test SDK key and authenticated backend URL. Restore the placeholders before sharing the change, or generate this public configuration in your own CI.

   Expected result: the config contains only the two expected runtime values and no identity signing secret, saved user JWT, or service-origin override.

4. Build a native host:

   ```bash
   npm run build:android:release
   npm run build:ios:release
   ```

   Expected result: each selected host compiles with native diagnostics off in release mode.

5. Run the app and select **Continue anonymously**, then **Support**.

   Expected result: native anonymous state becomes ready and the contained native messenger opens.

6. Select **Complete host login**, then **Support**.

   Expected result: the host backend returns a short-lived JWT, JavaScript passes it directly to native code, and identified Support becomes ready.

7. Select **Log out / switch account** before using another test account.

   Expected result: native logout blocks the previous owner before another account can open Support.

## Add push for a release build

The example does not install a Firebase/APNs library because the host app owns
that choice. Connect your existing library to `forwardPushTokenToOnlo` after
`anonymousReady` or `identifiedReady` and on every token refresh. Ask for permission from a clear
customer action, not during `Onlo.initialize`.

For a notification tap, wait for either ready state, then call
`forwardOnloNotification`. If it returns `deferred`, retry after the next
foreground/network recovery. Do not persist the token, payload, or customer
state in JavaScript. Test both signed iOS and Android builds before release.
Token or provider errors must remain push-only; Support and logout stay usable.

## Success criteria

- Both native hosts build with one bridge and one matching native core.
- JavaScript contains no session, credential, transcript, or outbox implementation.
- Anonymous and identified flows present the same native messenger.
- Logout completes, or Support remains disabled while logout recovery is pending, before account switching.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Native bridge is unavailable | The native app was not rebuilt or is running in Expo Go | Use a development/release build and rebuild the platform host |
| Duplicate iOS symbols or Android classes | Both local and published native cores are linked | Keep only the sibling native core described in the repository-development section |
| Support stays disabled | SDK key, initialization, or selected login flow failed | Check the safe on-screen state and verify the ignored public configuration |
| Identified login fails | Backend URL/session is missing or JWT expired | Authenticate the example and request a fresh JWT |

The SDK production origin is `https://onlo.ai`; staging/review origins are release-configured only.

Next: use the [React Native package guide](../../packages/react-native/README.md) to move the same lifecycle into your app.
