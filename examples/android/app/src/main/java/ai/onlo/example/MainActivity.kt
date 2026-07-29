package ai.onlo.example

import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.messenger.OnloMessenger
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.push.PushPayloadOutcome
import ai.onlo.sdk.push.PushRegistrationOutcome
import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.lifecycle.lifecycleScope
import com.google.firebase.messaging.FirebaseMessaging
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

/**
 * Local host foundation. It deliberately has no SDK key, JWT, or signing
 * implementation in source. Wire the identity provider to an authenticated
 * Operator backend only in a private host app configuration.
 */
class MainActivity : AppCompatActivity() {
    private lateinit var supportButton: Button
    private lateinit var notificationsButton: Button
    private lateinit var status: TextView
    private lateinit var diagnostics: TextView
    private lateinit var loginCode: EditText
    private var hostOperationError: String? = null
    private var pendingPushPayload: Map<String, String>? = null
    private var pushRoutingJob: Job? = null
    private var syncedCurrentTokenForReadySession = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        supportButton = Button(this).apply { text = "Support"; isEnabled = false }
        loginCode = EditText(this).apply { hint = "Host login code" }
        val anonymousButton = Button(this).apply { text = "Continue anonymously" }
        val identifiedButton = Button(this).apply { text = "Complete host login" }
        notificationsButton = Button(this).apply {
            text = "Enable support notifications"
            isEnabled = false
        }
        val logoutButton = Button(this).apply { text = "Log out / switch account" }
        val clearDiagnosticsButton = Button(this).apply { text = "Clear diagnostics" }
        status = TextView(this).apply { text = "Local mock host: SDK key not configured" }
        diagnostics = TextView(this).apply {
            text = "No FCM diagnostics yet."
            setTextIsSelectable(true)
            setPadding(24, 24, 24, 24)
            setBackgroundColor(0xffeeeeee.toInt())
        }
        val content = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(status)
            addView(loginCode)
            addView(anonymousButton)
            addView(identifiedButton)
            addView(supportButton)
            addView(notificationsButton)
            addView(logoutButton)
            addView(TextView(this@MainActivity).apply { text = "FCM diagnostics (safe)" })
            addView(clearDiagnosticsButton)
            addView(diagnostics)
        }
        setContentView(ScrollView(this).apply { addView(content) })
        supportButton.setOnClickListener { OnloMessenger.present(this, Onlo.instance()) }
        clearDiagnosticsButton.setOnClickListener { OnloFcmDiagnostics.clear() }

        // The public key is supplied by ignored local.properties in this example. It is safe to
        // embed in an app, but a real value does not belong in this shared repository.
        val client = (application as MerchantApplication).onloClient ?: return
        anonymousButton.setOnClickListener {
            lifecycleScope.launch {
                hostOperationError = null
                try {
                    client.loginUnidentifiedUser()
                } catch (_: Exception) {
                    hostOperationError = "Anonymous support is unavailable"
                    status.text = hostOperationError
                }
            }
        }
        identifiedButton.setOnClickListener {
            lifecycleScope.launch {
                hostOperationError = null
                try {
                    identifyFromOperatorBackend(loginCode.text.toString())
                } catch (_: Exception) {
                    hostOperationError = "Identified support is unavailable"
                    status.text = hostOperationError
                }
            }
        }
        notificationsButton.setOnClickListener { enableSupportNotifications() }
        logoutButton.setOnClickListener {
            lifecycleScope.launch {
                hostOperationError = null
                try {
                    pendingPushPayload = null
                    pushRoutingJob?.cancel()
                    client.logout()
                    loginCode.text.clear()
                } catch (_: Exception) {
                    hostOperationError = "Support logout is pending"
                    status.text = hostOperationError
                }
            }
        }
        lifecycleScope.launch {
            client.state.collectLatest { state ->
                supportButton.isEnabled = state.phase == OnloPhase.ANONYMOUS_READY ||
                    state.phase == OnloPhase.IDENTIFIED_READY
                val supportSessionReady = state.phase == OnloPhase.ANONYMOUS_READY ||
                    state.phase == OnloPhase.IDENTIFIED_READY
                notificationsButton.isEnabled = supportSessionReady
                if (supportSessionReady) {
                    if (!syncedCurrentTokenForReadySession &&
                        SupportNotificationPreference.isEnabled(this@MainActivity)
                    ) {
                        syncedCurrentTokenForReadySession = true
                        syncCurrentFcmToken()
                    }
                    routePendingPush()
                } else {
                    syncedCurrentTokenForReadySession = false
                }
                status.text = hostOperationError ?: "Native state: ${state.phase.name.lowercase()}"
            }
        }
        lifecycleScope.launch {
            OnloFcmDiagnostics.lines.collectLatest { lines ->
                diagnostics.text = lines.takeIf(List<String>::isNotEmpty)
                    ?.joinToString("\n")
                    ?: "No FCM diagnostics yet."
            }
        }
        forwardIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        forwardIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        routePendingPush()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        OnloFcmDiagnostics.info("event=notification_permission_result granted=$granted")
        SupportNotificationPreference.setEnabled(this, granted)
        if (granted) syncCurrentFcmToken()
        else {
            hostOperationError = "Notifications were not enabled"
            status.text = hostOperationError
        }
    }

    /** Call only after the host app has authenticated its own customer. */
    private suspend fun identifyFromOperatorBackend(hostLoginCode: String) {
        val userJwt = OperatorBackend().fetchShortLivedOnloUserJwt(hostLoginCode)
        Onlo.instance().loginIdentifiedUser(userJwt)
    }

    private fun enableSupportNotifications() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            OnloFcmDiagnostics.info("event=notification_permission_requested")
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST,
            )
            return
        }
        OnloFcmDiagnostics.info("event=notification_permission_already_granted")
        SupportNotificationPreference.setEnabled(this, true)
        syncCurrentFcmToken()
    }

    private fun syncCurrentFcmToken() {
        if (!SupportNotificationPreference.isEnabled(this)) {
            OnloFcmDiagnostics.info("event=current_token_sync_skipped reason=notifications_disabled")
            return
        }
        val client = (application as? MerchantApplication)?.onloClient
        if (client == null) {
            OnloFcmDiagnostics.warn("event=current_token_sync_skipped reason=client_unavailable")
            return
        }
        OnloFcmDiagnostics.info("event=current_token_fetch_started")
        FirebaseMessaging.getInstance().token
            .addOnSuccessListener { token ->
                if (token.isBlank()) {
                    OnloFcmDiagnostics.warn("event=current_token_fetch_failed errorClass=blank_token")
                    return@addOnSuccessListener
                }
                OnloFcmDiagnostics.info("event=current_token_fetch_succeeded")
                lifecycleScope.launch {
                    try {
                        val outcome = client.registerPushToken(PushProvider.FCM, token)
                        OnloFcmDiagnostics.info("event=current_token_registration_completed outcome=${outcome.javaClass.simpleName}")
                        when (outcome) {
                            PushRegistrationOutcome.Registered,
                            PushRegistrationOutcome.QueuedForReconciliation -> {
                                hostOperationError = null
                                status.text = "Support notifications are ready"
                            }
                            else -> {
                                hostOperationError = "Notifications will retry when Support reconnects"
                                status.text = hostOperationError
                            }
                        }
                    } catch (error: Exception) {
                        OnloFcmDiagnostics.warn("event=current_token_registration_failed errorClass=${error.javaClass.simpleName}")
                        hostOperationError = "Notifications will retry when Support reconnects"
                        status.text = hostOperationError
                    }
                }
            }
            .addOnFailureListener { error ->
                OnloFcmDiagnostics.warn("event=current_token_fetch_failed errorClass=${error.javaClass.simpleName}")
                hostOperationError = "Could not prepare support notifications"
                status.text = hostOperationError
            }
    }

    private fun forwardIntent(intent: Intent) {
        val push = listOf("conversationId", "messageId", "notificationType")
            .associateWithNotNull { intent.getStringExtra(it) }
        if (push.size == 3) {
            pendingPushPayload = push
            routePendingPush()
            return
        }
        val segments = intent.data?.pathSegments ?: return
        if (intent.data?.host == "support" && segments.size == 2 && segments[0] == "conversations") {
            lifecycleScope.launch {
                OnloMessenger.openConversation(this@MainActivity, segments[1])
            }
        }
    }

    private fun routePendingPush() {
        val push = pendingPushPayload ?: return
        val client = (application as? MerchantApplication)?.onloClient ?: return
        if (client.state.value.phase !in setOf(
                OnloPhase.ANONYMOUS_READY,
                OnloPhase.IDENTIFIED_READY,
            ) || pushRoutingJob?.isActive == true
        ) return
        OnloFcmDiagnostics.info("event=push_route_started")
        pushRoutingJob = lifecycleScope.launch {
            val outcome = client.handlePushPayload(push)
            OnloFcmDiagnostics.info("event=push_route_completed outcome=${outcome.javaClass.simpleName}")
            when (outcome) {
                is PushPayloadOutcome.NavigationIntent -> {
                    pendingPushPayload = null
                    OnloMessenger.openConversation(this@MainActivity, outcome.conversationId, client)
                }
                PushPayloadOutcome.NotOnlo,
                PushPayloadOutcome.Malformed,
                PushPayloadOutcome.NotAuthorised -> pendingPushPayload = null
                PushPayloadOutcome.NoActiveSession,
                PushPayloadOutcome.RefetchFailed -> Unit
            }
        }
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST = 7100
    }
}

private class OperatorBackend {
    suspend fun fetchShortLivedOnloUserJwt(hostLoginCode: String): String = withContext(Dispatchers.IO) {
        require(BuildConfig.ONLO_OPERATOR_BACKEND_URL.isNotBlank()) {
            "Configure an authenticated Operator-backend URL."
        }
        val connection = URL("${BuildConfig.ONLO_OPERATOR_BACKEND_URL}/v1/test-login")
            .openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.setRequestProperty("Content-Type", "application/json")
            connection.doOutput = true
            connection.outputStream.use {
                it.write(JSONObject(mapOf("loginCode" to hostLoginCode)).toString().toByteArray())
            }
            check(connection.responseCode in 200..299) { "Operator backend rejected the host session." }
            val value = connection.inputStream.bufferedReader().use { JSONObject(it.readText()) }
            value.getString("userJwt")
        } finally {
            connection.disconnect()
        }
    }
}

private inline fun <K, V : Any> Iterable<K>.associateWithNotNull(value: (K) -> V?): Map<K, V> =
    mapNotNull { key -> value(key)?.let { key to it } }.toMap()
