# Changelog

## 0.3.2

- Acknowledged replies rendered in anonymous Messenger sessions so the server
  can suppress their foreground push notifications.
- Preserved the anonymous contract: no unread count or unread flags are exposed.
- Kept the Android core API and v1 protocol unchanged.

## 0.3.1

- Kept the Messenger composer above the software keyboard on edge-to-edge
  Android hosts.
- Wired the keyboard send action to the same guarded native send path as the
  visible send button.
- Kept the Android core API and v1 protocol unchanged.

## 0.3.0

- Updated the native host example to request notification permission from a
  customer action, fetch the current FCM token after anonymous or identified restoration,
  and retry a cold-start tap after native authorization is ready.
- Added anonymous-session FCM registration and tap authorization.
- Isolated invalid tokens and registration/provider failures from chat,
  Messenger, transcript synchronization, logout, and account switching.
- Moved FCM registration network work outside the lifecycle/session mutex.
- Kept the Android core API and v1 notification payload unchanged.

## 0.2.0

- Added contained and full-screen Messenger presentation options and native
  back navigation.
- Fixed Messenger layout, safe areas, branding, typing indicators, cached
  conversations, loading states, and message alignment.

## 0.1.0

- Initial public release of `ai.onlo:onlo-android-sdk`.
- Includes the native messenger, protected identity/session state, durable
  outbox, configuration, media, push, and lifecycle recovery.
