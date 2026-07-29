# Onlo Android SDK

Add Onlo’s native support messenger to an Android app. The normal integration is **install → initialize → login → present → logout**.

## Prerequisites

- [ ] Android API 24 or newer, compile SDK 35, Java 17, and a Kotlin 2.0-compatible host.
- [ ] A public Mobile SDK key from Onlo Dashboard.
- [ ] A host-owned Support button or route.
- [ ] For signed-in support, an authenticated backend endpoint that returns a fresh Onlo user JWT.

## Concepts

| Term | Meaning |
| --- | --- |
| SDK key | Public key that selects your Onlo organisation/app integration. It is safe to include in the app, but it is not customer identity. |
| User JWT | Short-lived identity proof created by your backend after the customer signs in to your app. The Android app passes it directly to Onlo. |
| `OnloClient` | Application-scoped native client that owns the protected session, offline outbox, transcript, unread state, and push registration. |
| `OnloMessenger` | Native messenger UI that your Activity presents from a host-controlled action. |

Do not put the user-JWT signing secret in the Android app, `BuildConfig`, resources, or source control.

## Step 1: Install the SDK

Add Maven Central and the SDK to the app module:

```kotlin
// app/build.gradle.kts
repositories {
    google()
    mavenCentral()
}

dependencies {
    implementation("ai.onlo:onlo-android-sdk:0.3.0")
}
```

Add network access to the host manifest:

```xml
<uses-permission android:name="android.permission.INTERNET" />
```

Sync Gradle.

Expected result: `import ai.onlo.sdk.Onlo` and `import ai.onlo.sdk.messenger.OnloMessenger` resolve.

## Step 2: Add the public SDK key

Expose a different public key for each build environment:

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
                "\"<YOUR_TEST_PUBLIC_SDK_KEY>\"",
            )
        }
        release {
            buildConfigField(
                "String",
                "ONLO_SDK_KEY",
                "\"<YOUR_PRODUCTION_PUBLIC_SDK_KEY>\"",
            )
        }
    }
}
```

Expected result: `BuildConfig.ONLO_SDK_KEY` contains only a public integration key. Never place a signing secret, user JWT, or customer attribute in `BuildConfig`.

## Step 3: Initialize once

Initialize from your `Application` so lifecycle recovery is installed before a notification or Activity uses Onlo:

```kotlin
import ai.onlo.sdk.Onlo
import android.app.Application

class MerchantApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Onlo.initialize(this, BuildConfig.ONLO_SDK_KEY)
    }
}
```

Register the `Application` if your app does not already have one:

```xml
<application
    android:name=".MerchantApplication"
    ... />
```

Expected result: Onlo begins restoring protected state in the background. Initialization does not show UI or ask for permissions.

## Step 4: Choose a login path

Run login from a coroutine after your app knows whether the customer is signed in.

### Anonymous customer

```kotlin
lifecycleScope.launch {
    Onlo.instance().loginUnidentifiedUser()
}
```

Expected result: Support uses an installation-scoped anonymous session. No email, phone number, or customer ID is required.

### Signed-in customer

```kotlin
lifecycleScope.launch {
    // This endpoint authenticates the existing app session. Your backend
    // derives the stable customer ID and signs a short-lived Onlo JWT.
    val userJwt = merchantBackend.fetchOnloUserJwt()

    // Pass it directly to Onlo. Do not decode, save, or log it.
    Onlo.instance().loginIdentifiedUser(userJwt)
}
```

Expected result: the current installation is attached to the verified customer. There is no Onlo OTP or second login.

Your backend must derive the JWT `sub` from its authenticated session. Use an immutable, opaque customer ID—not an email address or phone number. See the [exact JWT claim rules](../../docs/api-contract.md#operator-user-jwt).

## Step 5: Enable and present Support

Observe state and enable the host button only when the session is ready:

```kotlin
import ai.onlo.sdk.OnloPhase

lifecycleScope.launch {
    Onlo.instance().state.collect { state ->
        supportButton.isEnabled = state.phase == OnloPhase.ANONYMOUS_READY ||
            state.phase == OnloPhase.IDENTIFIED_READY
    }
}
```

Present from the current Activity:

```kotlin
supportButton.setOnClickListener {
    OnloMessenger.present(this, Onlo.instance())
}
```

Expected result: tapping Support opens the contained native messenger inside the current Activity. Onlo never adds a floating button, overlay, or Activity to the host app.

To intentionally use the full Activity content area:

```kotlin
OnloMessenger.present(
    activity = this,
    options = OnloMessengerOptions(
        presentationMode = OnloMessengerPresentationMode.FULL_SCREEN,
    ),
)
```

## Step 6: Handle logout and account switching

Disable Support first, then await Onlo before activating a different customer:

```kotlin
lifecycleScope.launch {
    supportButton.isEnabled = false

    when (Onlo.instance().logout()) {
        LogoutOutcome.Completed,
        LogoutOutcome.AlreadyAnonymous -> merchantAuth.finishLogout()
        is LogoutOutcome.Pending -> {
            // Keep Support disabled. Native recovery will retry safely.
            merchantAuth.finishLogout()
        }
    }
}
```

Expected result: the previous customer’s transcript, outbox, unread state, and push association are blocked before another customer can use Onlo. If logout is pending, keep Support disabled for the next account.

## Step 7: Add optional features

Complete the basic send/receive flow before enabling optional features.

### Unread badge

```kotlin
lifecycleScope.launch {
    Onlo.instance().unreadCount.collect { count ->
        // null means anonymous, logout, or account switch.
        updateSupportBadge(count ?: 0)
    }
}
```

Expected result: identified customers see the exact server unread total; anonymous and logged-out states clear the badge.

### FCM push

1. Add Firebase Messaging to the host app. Request Android 13+ notification
   permission only after the customer selects an action such as **Enable
   support notifications**; initialization must not prompt.

   Expected result: the host receives an FCM registration token. Onlo does not force Firebase on chat-only apps.

2. Upload the matching FCM HTTP v1 service-account credential in Onlo Dashboard. Keep it server-side.

   Expected result: Onlo can send notifications for this app without embedding provider credentials in the APK.

3. Forward every rotated token from `FirebaseMessagingService.onNewToken`:

   ```kotlin
   Onlo.instance().registerPushToken(PushProvider.FCM, fcmToken)
   ```

   Expected result: the native client registers for the installation's current anonymous or identified session, or safely retries after session readiness.

4. After anonymous or identified login/restoration, also fetch and forward the current
   token. This covers a token callback that happened before the process or
   customer session was ready:

   ```kotlin
   FirebaseMessaging.getInstance().token.addOnSuccessListener { currentToken ->
       lifecycleScope.launch {
           Onlo.instance().registerPushToken(PushProvider.FCM, currentToken)
       }
   }
   ```

5. When a customer taps a contract-shaped Onlo notification, forward only `conversationId`, `messageId`, and `notificationType` to `handlePushPayload`.

   Expected result: Onlo re-authorises and refreshes the conversation before
   your Activity opens it. If the result is `NoActiveSession` or
   `RefetchFailed`, keep one bounded native tap in the Activity and retry after
   `ANONYMOUS_READY` or `IDENTIFIED_READY`; never open the unverified route directly. See the
   [Android example service and tap routing](../../examples/android/README.md#enable-fcm).

Invalid tokens, registration failures, and FCM errors return a push-only outcome. They do not change the active session, interrupt Messenger, or block chat/logout; obtain the current token and register the installation again.

### Images and voice

The Onlo Dashboard controls whether images and voice are available. The SDK uses the system photo picker, requests camera or microphone permission only after the customer selects that action, and keeps sending/retry behavior native.

Expected result: disabling a feature in Dashboard removes its control after configuration refresh; the host does not need a second composer implementation.

## Safe diagnostics

```kotlin
Onlo.setLogLevel(
    if (BuildConfig.DEBUG) OnloLogLevel.VERBOSE else OnloLogLevel.OFF,
)
```

Logs contain only safe codes, request IDs, SDK/runtime versions, and durations. Never log SDK keys, JWTs, customer fields, message text, push tokens, or attachment URLs.

## Success criteria

- The app builds with one `ai.onlo:onlo-android-sdk` dependency.
- Anonymous and identified sessions both reach a ready state.
- Support opens only from a host-owned button or route.
- A signed-in customer’s JWT is created only by the authenticated backend and is never stored by the app.
- Logout completes or remains safely pending with Support disabled before an account switch.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `Onlo.instance()` throws `onlo_not_initialized` | `Onlo.initialize` did not run first | Initialize from `Application.onCreate()` and register that Application in the manifest |
| Support remains disabled | Protected state is restoring or login failed | Observe `state`; verify the public key and inspect only safe SDK error codes |
| Identified login fails | JWT is invalid or expired | Request a fresh backend JWT and verify the contract claims; never modify it in the app |
| Messenger opens from the wrong place | Presentation was not triggered by the active Activity | Call `OnloMessenger.present(this, Onlo.instance())` from the current Activity’s Support action |
| Next customer cannot open Support | Previous logout is pending | Keep Support disabled and allow native foreground/network recovery to finish the boundary |
| Push arrives but does not navigate | Payload, active identity, or conversation ownership failed validation | Forward only the three v1 routing fields after a user tap and handle non-navigation outcomes safely |

## Run the example

Use the [Android host example](../../examples/android/README.md) to test the same sequence against this repository’s local SDK project.

## Repository verification

From the repository root:

```bash
packages/android/gradlew -p packages/android testDebugUnitTest assembleRelease
```

For deeper integration, push, media, environment, and release checks, use the [complete integration guide](../../docs/integration-guide.md) and [development and go-live guide](../../docs/development-and-go-live-guide.md).

Next: run the [Android example](../../examples/android/README.md) with your test integration.
