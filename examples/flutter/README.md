# Flutter local host

`lib/main.dart` and `pubspec.yaml` are a local Flutter host foundation with a path dependency on `../../packages/flutter`. It contains no key, JWT, signing secret, customer data, endpoint override, `.dart_tool`, or build output.

## Run foundation

1. Copy `config/onlo.example.json` to `config/onlo.local.json` and replace the placeholder with a synthetic/test public SDK key.

   Expected result: the ignored local file contains public app configuration only; it has no signing secret or JWT.

2. Run `flutter pub get`, then `flutter run --dart-define-from-file=config/onlo.local.json` after completing the [tool setup](../../docs/development-and-go-live-guide.md#tool-and-account-setup).

   Expected result: Flutter resolves the local plugin, initializes native authority in the background, and enables the host-owned Support button only when ready.

3. Implement `_fetchShortLivedOnloUserJwtFromOperatorBackend` with the host's authenticated Operator-backend call and invoke it after the host account login.

   Expected result: host login is not blocked by Onlo; the short-lived JWT is passed directly to `Onlo.loginIdentifiedUser`, and Dart neither signs nor persists it.

4. Use `Onlo.present()` only from the host-owned Support action.

   Expected result: native Android/iOS owns messenger UI, credentials, outbox, and recovery. Both adapter sources are present, but host-native compile evidence remains a separate gate.
