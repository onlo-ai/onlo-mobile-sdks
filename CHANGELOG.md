# Changelog

## 0.3.4

- iOS: fence delayed push callbacks; retain refresh gates until a fresh bearer, including repeated token registration.

- Fence targeted recovery to the original owner; retain terminal non-401 behavior and one retry.
- Add safe native diagnostics without changing bridge error payloads.
- Fence late iOS refresh success/failure across logout and serialize protected writes.

## 0.3.3

### Fixed

- Android and iOS no longer stay unusable after the server rejects a stored
  installation credential (`session_expired` or `session_revoked`). The SDK
  retires the old local owner and starts a fresh anonymous installation, the
  state a reinstall used to be needed for. Devices already stuck on 0.3.2
  recover on their first launch with 0.3.3.
- A rejected identify replay now identifies a replacement installation with
  the host's JWT instead of failing every later login.
- A logout whose credential the server rejects now completes instead of
  staying pending.
- `openConversation` and Messenger transcript loads refresh an expired chat
  token once instead of failing with `native_operation_failed`.
- iOS shares one native core per process across the `Onlo` facade and the
  React Native and Flutter bridges, and coalesces overlapping session
  resumes, so two rotations of the same credential can no longer race.
- Background SDK work on Android can no longer crash the host app.
- Flutter treats an omitted optional argument as absent, so `Onlo.present()`
  without a conversation and `setPushToken` without a locale no longer fail
  with `invalid_argument`.

### Compatibility

- No public API or wire-protocol changes.
- An identified customer whose credential was rejected is anonymous until the
  host's next `loginIdentifiedUser`, the same as after a fresh install.

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
