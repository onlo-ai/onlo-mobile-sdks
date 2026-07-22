# Flutter local host

`lib/main.dart` and `pubspec.yaml` are a local Flutter host foundation with a path dependency on `../../packages/flutter`. It contains no key, JWT, signing secret, customer data, endpoint override, `.dart_tool`, or build output.

## Run foundation

1. From this directory, run `flutter pub get` and then `flutter run` after completing the [tool setup](../../docs/development-and-go-live-guide.md#tool-and-account-setup).

   Expected result: Flutter resolves the local path plugin and builds a host-owned Support button. The button remains disabled until a private build supplies the public SDK key.

2. Implement `_fetchShortLivedOnloUserJwtFromOperatorBackend` with the host's authenticated Operator-backend call and invoke it after the host account login.

   Expected result: the short-lived JWT is passed directly to `Onlo.loginIdentifiedUser`; Dart neither signs nor persists it.

3. Use `Onlo.present()` only from the host-owned Support action.

   Expected result: native Android/iOS owns messenger UI, credentials, outbox, and recovery. Both adapter sources are present, but host-native compile evidence remains a separate gate.
