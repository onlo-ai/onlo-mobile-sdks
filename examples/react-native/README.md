# React Native local host

This is the version-controlled React Native 0.86 iOS/Android host. It uses
`file:../../packages/react-native`, one native Core per platform, and safe
placeholder configuration.

## Run foundation

1. Run `npm ci` in this directory.

   Expected result: the checked-in iOS and Android shells resolve the local bridge.

2. Follow the monorepo-local native-link instructions in [`@onlo/react-native`](../../packages/react-native/README.md#monorepo-local-native-linking). Use a development build, not Expo Go.

   Expected result: Android and iOS use their fixed-family native bridge source and checked-in native core. Both host-native builds remain separate verification gates; neither link is a published artifact.

3. Put only a synthetic public SDK key and authenticated Operator-backend URL
   in a local generated `onlo.config.ts`.

   Expected result: initialization runs in the background and the Support button remains disabled only while native authority is restoring.

4. Build with `npm run build:android:release` or
   `npm run build:ios:release`.

   Expected result: the host demonstrates anonymous and identified login,
   native presentation/picker/camera, push/deep-link forwarding, logout/account
   switching, native-owned lifecycle recovery, and native diagnostics set to
   `off` because `__DEV__` is false.

`Onlo.present()` is called only from the host Support button. The SDK production origin is `https://onlo.ai`; staging/review origin is release-configured only. Do not put an identity signing secret or user JWT in `onlo.config.ts` or an app `.env`.
