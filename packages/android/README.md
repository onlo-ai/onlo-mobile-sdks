# Onlo Android SDK

Kotlin native-core foundation for the Onlo mobile v1 contract. It owns protected session state and the owner-scoped SQLite outbox; framework bridges must not duplicate either.

## Public entry points

| API | Behavior |
| --- | --- |
| `Onlo.initialize(context, sdkKey)` | Derives the Android application ID, restores protected state asynchronously, targets production, and never asks for permissions or presents UI. |
| `loginUnidentifiedUser()` | Restores or bootstraps anonymous continuity; it refuses to replace an identified account. |
| `loginIdentifiedUser(userJwt)` | Checks only compact JWT shape, then exchanges the proof without persisting or verifying it locally. |
| `logout()` | Blocks the old partition before revocation; returns a typed pending result when a retry is needed. |
| `state` / `presentationIntent` | `StateFlow` values for Compose and View adapters. `present()` only emits an intent; it installs no overlay. |

## Storage and protocol invariants

| Concern | Foundation behavior |
| --- | --- |
| Rotating credential | AES-GCM encrypted with a non-exportable Android Keystore key; ciphertext only is stored in the app's no-backup directory. |
| Lost session response | The protected record atomically retains the exact non-secret transition fields for bootstrap, resume, identify, or logout. A lost identify response requires the host to supply a JWT again; the JWT itself is never stored. |
| Chat token and user JWT | Memory-only. Neither appears in the protected record, SQLite, or structured logs. |
| Account boundary | An opaque protected owner-partition ID survives resume/token rotation but is replaced after logout. Old outbox work is blocked before another account can use the core. |
| Outbox | A no-backup SQLite database inserts a UUID `clientMessageId` before sending. Message, attachment, local conversation, and server message values are AES-GCM ciphertext under a separate Android Keystore key; unreadable ciphertext atomically purges the outbox. Retries and interrupted-send recovery retain the same ID. |
| Wire shapes | `protocol/` builds only the contract's `/api/sdk/v1/*` and `/api/widget/*` requests, including bounded transcript and attachment validation. |
| Logs | Only safe code, request ID, SDK version, runtime, and duration are emitted. |

## Origin configuration

The public initializer is fixed to `https://onlo.ai`. Staging/review builds use an internal release-configured HTTPS origin seam; hosts cannot select an arbitrary endpoint and the SDK never guesses a staging hostname. No local-development origin is part of the public initializer contract.

## Local checks

The module is standalone and requires JDK 17 plus an Android SDK:

```bash
gradle -p packages/android test
```

This is a native-core foundation, not a released AAR or a completed Compose/View messenger.
