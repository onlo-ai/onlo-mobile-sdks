# Changelog

## 0.3.2

- Acknowledged replies rendered in anonymous Messenger sessions so the server
  can suppress their foreground push notifications.
- Preserved the anonymous contract: no unread count or unread flags are exposed.
- Kept the iOS public API and v1 protocol unchanged.

## 0.3.1

- Lockstep patch release; no iOS runtime or public API changes.

## 0.3.0

- Fixed user-tapped notifications arriving during restoration so one bounded
  native tap is retried after either anonymous or identified readiness.
- Added anonymous-session APNs registration and tap authorization.
- Isolated invalid tokens and registration/provider failures from chat,
  Messenger, transcript synchronization, logout, and account switching.
- Moved APNs reconciliation off session completion, fenced stale token-rotation
  responses, and cleared anonymous push intent during pending-identify recovery.
- Kept the existing public API and v1 notification payload unchanged.

## 0.2.0

- Added contained and full-screen Messenger presentation support and native
  back navigation.
- Fixed Messenger layout, safe areas, branding, typing indicators, cached
  conversations, loading states, and message alignment.

## 0.1.0

- Initial public release of `OnloSDK`.
- Includes the native messenger, protected identity/session state, durable
  outbox, configuration, media, push, and lifecycle recovery.
