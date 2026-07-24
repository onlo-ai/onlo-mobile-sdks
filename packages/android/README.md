# Onlo Android SDK

Kotlin native-core foundation for the Onlo mobile v1 contract. It owns protected session state and the owner-scoped SQLite outbox; framework bridges must not duplicate either.

> **Status:** RC ready; publication pending physical-device qualification.

## Install

Requirements:

| Requirement | Minimum |
| --- | --- |
| Android | API 24 |
| Compile SDK | 35 |
| Java | 17 |
| Kotlin | 2.0-compatible host |

Use Maven Central and add the native Core once:

```kotlin
repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("ai.onlo:onlo-android-sdk:0.1.0")
}
```

The artifact is prepared but not published. The dependency resolves only after
physical-device qualification and Maven Central release.

## Public entry points

| API | Behavior |
| --- | --- |
| `Onlo.initialize(context, sdkKey)` | Derives the Android application ID, restores protected state asynchronously, targets production, and never asks for permissions or presents UI. |
| `loginUnidentifiedUser()` | Restores or bootstraps anonymous continuity; it refuses to replace an identified account. |
| `loginIdentifiedUser(userJwt)` | Checks only compact JWT shape, then exchanges the proof without persisting or verifying it locally. |
| `logout()` | Blocks the old partition before revocation; returns a typed pending result when a retry is needed. |
| `state` / `unreadCount` / `presentationIntent` | Native `StateFlow` values. `unreadCount` is the exact identified-user aggregate and becomes `null` for anonymous/logout/account switch. `present()` only emits an intent; it installs no overlay. |
| `OnloMessenger.present(activity)` | Presents the SDK-owned Android Views messenger from a host-controlled entry point. It never adds an overlay, manifest component, or permission prompt. |
| `OnloMessenger.openConversation(activity, id)` | Re-authorises and refreshes the requested conversation before presenting it; an unauthorised target is not shown. |

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

## Advanced configuration

### Environment keys

Configure public keys in the merchant app module:

```kotlin
// app/build.gradle.kts
android {
    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        debug {
            buildConfigField(
                "String",
                "ONLO_SDK_KEY",
                "\"<STAGING_PUBLIC_MOBILE_SDK_KEY>\"",
            )
        }
        release {
            buildConfigField(
                "String",
                "ONLO_SDK_KEY",
                "\"<PRODUCTION_PUBLIC_MOBILE_SDK_KEY>\"",
            )
        }
    }
}
```

Initialize from `Application`:

```kotlin
class MerchantApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Onlo.initialize(this, BuildConfig.ONLO_SDK_KEY)
    }
}
```

The key selects the Operator integration, not the service hostname. Production
is fixed to `https://onlo.ai`; staging origins are part of release
configuration. Never put a signing secret, user JWT, or customer attributes in
`BuildConfig`.

### Safe diagnostics

```kotlin
Onlo.setLogLevel(
    if (BuildConfig.DEBUG) OnloLogLevel.VERBOSE else OnloLogLevel.OFF,
)
```

| Level | Output |
| --- | --- |
| `OFF` | No SDK diagnostics; the default |
| `ERROR` | Safe failures requiring retry, recovery, or host action |
| `INFO` | Errors plus request/lifecycle completion summaries |
| `VERBOSE` | Info plus additional native timing milestones |

Output is restricted to safe code, request ID, SDK/runtime version, and
duration. Every level excludes keys, identity data, JWTs, customer fields,
message text, push tokens, and attachment URLs. The level can change before or
after initialization.

### Custom customer attributes

The merchant backend includes bounded `customAttributes` in the same
short-lived signed JWT as the opaque customer `sub`. Android passes that JWT
directly:

```kotlin
val userJwt = merchantBackend.fetchOnloUserJwt()
Onlo.instance().loginIdentifiedUser(userJwt)
```

The app must not construct, decode, edit, sign, persist, or log the JWT.

### Open a known conversation

```kotlin
when (OnloMessenger.openConversation(activity, conversationId, Onlo.instance())) {
    OpenConversationOutcome.Opened -> Unit
    OpenConversationOutcome.NotAuthorised -> showUnavailable()
    OpenConversationOutcome.NoActiveSession,
    OpenConversationOutcome.Unavailable -> showRetry()
}
```

The native core re-authorises and refreshes the conversation before the
messenger is presented.

### Unread badge and FCM

```kotlin
lifecycleScope.launch {
    Onlo.instance().unreadCount.collect { count ->
        // null means anonymous/logout/account switch.
        updateSupportBadge(count ?: 0)
    }
}

// Pass the token whenever FCM supplies it. Anonymous sessions queue it only
// in native memory; the SDK registers/re-registers after identified login.
Onlo.instance().registerPushToken(PushProvider.FCM, fcmToken)
```

The native messenger shows each conversation's server-provided row count,
acknowledges only after a fresh transcript is rendered, and refetches the
aggregate. Anonymous sessions neither register Onlo push nor expose persistent
unread state.

## Local checks

The module is standalone and requires JDK 17 plus an Android SDK:

```bash
packages/android/gradlew -p packages/android testDebugUnitTest assembleRelease
```

The module publishes the release AAR, sources JAR, Dokka Javadoc JAR, and
Maven Central metadata to an isolated qualification repository:

```bash
packages/android/gradlew -p packages/android \
  publishReleasePublicationToQualificationRepository \
  -Ponlo.maven.repository=/tmp/onlo-maven
```

The release coordinate is `ai.onlo:onlo-android-sdk:0.1.0`. Maven Central
namespace ownership, publisher credentials, and artifact signing remain
external release inputs.
