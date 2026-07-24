# Flutter local host

This is the version-controlled Flutter iOS/Android host with a path dependency
on `../../packages/flutter` and exactly one native Core per platform.

## Run foundation

1. Copy `config/onlo.example.json` to `config/onlo.local.json` and replace the placeholder with a synthetic/test public SDK key.

   Expected result: the ignored local file contains public app configuration only; it has no signing secret or JWT.

2. Run `flutter pub get`, then `flutter run --dart-define-from-file=config/onlo.local.json` after completing the [tool setup](../../docs/development-and-go-live-guide.md#tool-and-account-setup).

   Expected result: Flutter resolves the local plugin, initializes native authority in the background, and enables the host-owned Support button only when ready.

3. Use the example host’s Operator-backend call only after host authentication.

   Expected result: host login is not blocked by Onlo; the short-lived JWT is passed directly to `Onlo.loginIdentifiedUser`, and Dart neither signs nor persists it.

4. Run `flutter build apk --release` and
   `flutter build ios --release --no-codesign`.

   Expected result: both hosts demonstrate anonymous and identified login,
   native presentation/picker/camera, push/deep-link forwarding, logout/account
   switching, native-owned lifecycle recovery, and native diagnostics set to
   `off` because `kReleaseMode` is true.
