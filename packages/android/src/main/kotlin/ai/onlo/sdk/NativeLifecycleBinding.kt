package ai.onlo.sdk

import android.app.Activity
import android.app.Application
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Decides whether an OS lifecycle signal represents a useful recovery point.
 * Kept Android-free so the transition rules stay deterministic in unit tests.
 */
internal class NetworkRecoveryGate {
    private var observedPath = false
    private var wasAvailable = false

    fun onAvailable(available: Boolean): Boolean {
        val shouldRecover = observedPath && !wasAvailable && available
        observedPath = true
        wasAvailable = available
        return shouldRecover
    }
}

/**
 * SDK-owned application observer. It retains neither an Activity nor any host
 * callback. The normal ACCESS_NETWORK_STATE permission is solely for this
 * optional recovery signal; failure to register leaves normal host operations
 * usable and does not request a permission.
 */
internal class NativeLifecycleBinding(
    context: Context,
    private val onForeground: () -> Unit,
    private val onNetworkRecovered: () -> Unit,
) {
    private val application = context.applicationContext as? Application
    private val installed = AtomicBoolean(false)
    private val recoveryGate = NetworkRecoveryGate()
    private var startedActivities = 0
    private var connectivityManager: ConnectivityManager? = null

    private val activities = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityStarted(activity: Activity) {
            startedActivities += 1
            if (startedActivities == 1) onForeground()
        }

        override fun onActivityStopped(activity: Activity) {
            startedActivities = (startedActivities - 1).coerceAtLeast(0)
        }

        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) = Unit
        override fun onActivityResumed(activity: Activity) = Unit
        override fun onActivityPaused(activity: Activity) = Unit
        override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) = Unit
        override fun onActivityDestroyed(activity: Activity) = Unit
    }

    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) = evaluateNetwork()
        override fun onLost(network: Network) { recoveryGate.onAvailable(false) }
        override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) = evaluateNetwork()
    }

    fun install() {
        if (!installed.compareAndSet(false, true)) return
        val app = application ?: run {
            installed.set(false)
            return
        }
        app.registerActivityLifecycleCallbacks(activities)
        val manager = app.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
        connectivityManager = manager
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                manager.registerDefaultNetworkCallback(networkCallback)
            }
        } catch (_: SecurityException) {
            // Hosts can omit ACCESS_NETWORK_STATE. Foreground recovery remains available.
            connectivityManager = null
        }
    }

    fun close() {
        if (!installed.compareAndSet(true, false)) return
        application?.unregisterActivityLifecycleCallbacks(activities)
        val manager = connectivityManager
        connectivityManager = null
        if (manager != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                manager.unregisterNetworkCallback(networkCallback)
            } catch (_: IllegalArgumentException) {
                // Registration may have been rejected or already removed by the OS.
            }
        }
    }

    private fun evaluateNetwork() {
        val manager = connectivityManager ?: return
        val available = try {
            val network = manager.activeNetwork
            if (network == null) {
                recoveryGate.onAvailable(false)
                return
            }
            val capabilities = manager.getNetworkCapabilities(network)
            capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
        } catch (_: SecurityException) {
            false
        }
        if (recoveryGate.onAvailable(available)) onNetworkRecovered()
    }
}
