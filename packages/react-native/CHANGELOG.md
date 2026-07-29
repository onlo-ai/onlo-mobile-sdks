# Changelog

## 0.3.0

- Clarified production push integration for current-token registration,
  token rotation, customer-triggered permission, and deferred cold-start taps.
- Enabled the native bridge's existing push calls for both anonymous and
  identified sessions with push-only failure isolation.
- Kept the React Native API and native bridge contract unchanged.

## 0.2.0

- Added the optional `presentationMode` setting for contained and full-screen
  Messenger presentation.
- Matched the native Android and iOS Messenger layout, navigation, caching,
  typing indicators, loading states, and branding.

## 0.1.0

- Initial public release of `@onlo-ai/react-native`.
- Delegates identity, transport, persistence, recovery, and messenger UI to
  the published native iOS and Android SDKs.
