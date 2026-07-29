# Changelog

## 0.3.2

### Fixed

- Native Messenger now acknowledges rendered replies for installation-authorized
  anonymous sessions so foreground push notifications are suppressed while the
  customer is actively viewing the conversation.

### Compatibility

- No public API or wire-protocol changes.

## 0.3.1

### Fixed

- Android Messenger now stays above the software keyboard and treats the IME
  send action as message submission.

### Compatibility

- No public API or wire-protocol changes.

## 0.3.0

### Added

- Push registration and authorized notification routing now work for both
  anonymous and identified customer sessions.

### Fixed

- iOS retains one user-tapped Onlo notification during session restoration and
  retries it after either customer session is ready.
- Native examples request notification permission from a customer action,
  refresh the current provider token after login/restoration, and keep a
  cold-start tap until native authorization can finish.
- Invalid tokens and registration/provider failures remain isolated from chat,
  Messenger, transcript synchronization, logout, and account switching.
- Push registration no longer holds Android lifecycle/session locking or delays
  iOS session completion; stale iOS token-rotation responses are fenced.
- iOS pending-identify recovery clears the prior anonymous push intent without
  allowing protected-store failures to abort session recovery.

### Compatibility

- No public API or wire-protocol changes.
- Existing 0.2.x integrations remain compatible.

## 0.2.0

### Added

- Contained and full-screen Messenger presentation options for React Native
  and Flutter.
- Native back navigation and typing indicators across supported platforms.

### Fixed

- Messenger layout, safe-area handling, footer branding, loading states,
  cached conversations, message alignment, and section controls.
- React Native and Flutter behavior now matches the native Android and iOS
  Messenger implementations.

### Compatibility

- No breaking public API changes.
- The mobile wire protocol remains v1.

## 0.1.0

- Initial public release of the Onlo iOS, Android, React Native, and Flutter
  SDKs.
