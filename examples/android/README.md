# Android local host

`app/` is a minimal Android application that uses the sibling native core by a local Gradle project dependency. It builds a host-owned Support button; no key, JWT, endpoint override, signing code, customer data, or generated dependency is checked in.

## Run foundation

1. Complete the Android tool setup in the [go-live guide](../../docs/development-and-go-live-guide.md#tool-and-account-setup).

   Expected result: JDK 17 and Android API 35/build-tools 35.0.0 are installed after explicit licence acceptance.

2. Open `examples/android` in Android Studio, or run `../../packages/android/gradlew -p . :app:assembleDebug` from this directory.

   Expected result: the local host compiles against `../../packages/android`; it does not call Onlo because its public key is deliberately `null`.

3. In a private host build configuration, supply the public Operator SDK key and replace the `publicSdkKey` seam in `MainActivity`.

   Expected result: initialization uses the native Android core and enables Support only in anonymous or identified ready state.

4. Implement `OperatorBackend.fetchShortLivedOnloUserJwt()` as an authenticated call to the Operator backend, then call it only after the host app login succeeds.

   Expected result: the backend returns a short-lived JWT for `loginIdentifiedUser`; the app never signs, logs, or stores it.

Call `logout()` before a host account switch. If it returns `Pending`, keep the old partition blocked until native recovery completes. Production uses `https://onlo.ai`; staging/review must be injected by release configuration, never guessed by the host.
