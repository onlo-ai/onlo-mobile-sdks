# React Native local host

`App.tsx` and `package.json` are a local React Native host foundation. They use `file:../../packages/react-native`; no package is installed, no lockfile is generated, and the source contains no public key, JWT, signing secret, customer data, or endpoint override.

## Run foundation

1. Generate a normal React Native 0.79+ host shell outside this repository, then copy `App.tsx` and add the local dependency from this directory.

   Expected result: the host owns its Support button; it never adds a global overlay launcher.

2. Follow the monorepo-local native-link instructions in [`@onlo/react-native`](../../packages/react-native/README.md#monorepo-local-native-linking). Use a development build, not Expo Go.

   Expected result: Android and iOS use their fixed-family native bridge source and checked-in native core. Both host-native builds remain separate verification gates; neither link is a published artifact.

3. Put a synthetic/test public SDK key in `onlo.config.ts`, or generate the equivalent file from the host’s normal build configuration.

   Expected result: initialization runs in the background and the Support button remains disabled only while native authority is restoring.

4. Implement `fetchShortLivedOnloUserJwtFromOperatorBackend` after the host's own authenticated login.

   Expected result: host login is not blocked by Onlo; JavaScript passes the short-lived proof directly to native code and never signs or persists it.

`Onlo.present()` is called only from the host Support button. The SDK production origin is `https://onlo.ai`; staging/review origin is release-configured only. Do not put an identity signing secret or user JWT in `onlo.config.ts` or an app `.env`.
