# Android host integration

The Android core derives the app identifier from `Context`; a host supplies only its public Android SDK key. Do not ship an Onlo signing secret or mint a user JWT in the app.

```kotlin
class SupportApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        Onlo.initialize(this, sdkKey = BuildConfig.ONLO_SDK_KEY)
    }
}
```

Observe native state before enabling a support entry point:

```kotlin
lifecycleScope.launch {
    Onlo.instance().state.collect { state ->
        supportButton.isEnabled = state.phase == OnloPhase.ANONYMOUS_READY ||
            state.phase == OnloPhase.IDENTIFIED_READY
    }
}
```

When the Operator app has already authenticated its own customer, ask its backend for a short-lived user JWT and exchange it. The host backend—not the Android app—signs the token.

```kotlin
lifecycleScope.launch {
    val userJwt = operatorBackend.fetchOnloUserJwtForCurrentCustomer()
    Onlo.instance().loginIdentifiedUser(userJwt)
}
```

Call `logout()` before the host switches accounts. If it returns `Pending`, the old partition remains blocked and the core will retry revocation on a future initialization; do not make another account's messenger available through that client state.

Production uses `https://onlo.ai` by default. A staging/review build receives its exact HTTPS origin from an internal release configuration; the host initializer cannot select an endpoint and the SDK never guesses a hostname.
