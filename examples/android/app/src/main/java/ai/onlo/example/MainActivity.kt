package ai.onlo.example

import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OnloDevelopmentSupport
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.messenger.OnloMessenger
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.push.PushPayloadOutcome
import android.content.Intent
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.Dispatchers
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
    private lateinit var status: TextView
    private lateinit var loginCode: EditText
    private var hostOperationError: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        supportButton = Button(this).apply { text = "Support"; isEnabled = false }
        loginCode = EditText(this).apply { hint = "Host login code" }
        val anonymousButton = Button(this).apply { text = "Continue anonymously" }
        val identifiedButton = Button(this).apply { text = "Complete host login" }
        val logoutButton = Button(this).apply { text = "Log out / switch account" }
        status = TextView(this).apply { text = "Local mock host: SDK key not configured" }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(status)
            addView(loginCode)
            addView(anonymousButton)
            addView(identifiedButton)
            addView(supportButton)
            addView(logoutButton)
        })
        supportButton.setOnClickListener { OnloMessenger.present(this, Onlo.instance()) }

        // The public key is supplied by ignored local.properties in this example. It is safe to
        // embed in an app, but a real value does not belong in this shared repository.
        val publicSdkKey = BuildConfig.ONLO_SDK_KEY.takeIf(String::isNotBlank) ?: return
        val client = initializeOnlo(publicSdkKey)
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
        logoutButton.setOnClickListener {
            lifecycleScope.launch {
                hostOperationError = null
                try {
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
                status.text = hostOperationError ?: "Native state: ${state.phase.name.lowercase()}"
            }
        }
        forwardIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        forwardIntent(intent)
    }

    /** Call only after the host app has authenticated its own customer. */
    private suspend fun identifyFromOperatorBackend(hostLoginCode: String) {
        val userJwt = OperatorBackend().fetchShortLivedOnloUserJwt(hostLoginCode)
        Onlo.instance().loginIdentifiedUser(userJwt)
    }

    @OptIn(OnloDevelopmentSupport::class)
    private fun initializeOnlo(publicSdkKey: String) =
        if (BuildConfig.ONLO_DEVELOPMENT_ORIGIN.isBlank()) {
            Onlo.initialize(applicationContext, publicSdkKey)
        } else {
            Onlo.initializeDevelopment(
                applicationContext,
                publicSdkKey,
                BuildConfig.ONLO_DEVELOPMENT_ORIGIN,
            )
        }

    /** Call from FirebaseMessagingService; the host never stores the token. */
    suspend fun forwardFcmToken(token: String) {
        Onlo.instance().registerPushToken(PushProvider.FCM, token)
    }

    private fun forwardIntent(intent: Intent) {
        val push = listOf("conversationId", "messageId", "notificationType")
            .associateWithNotNull { intent.getStringExtra(it) }
        if (push.size == 3) {
            lifecycleScope.launch {
                when (val outcome = Onlo.instance().handlePushPayload(push)) {
                    is PushPayloadOutcome.NavigationIntent ->
                        OnloMessenger.openConversation(this@MainActivity, outcome.conversationId)
                    else -> Unit
                }
            }
            return
        }
        val segments = intent.data?.pathSegments ?: return
        if (intent.data?.host == "support" && segments.size == 2 && segments[0] == "conversations") {
            lifecycleScope.launch {
                OnloMessenger.openConversation(this@MainActivity, segments[1])
            }
        }
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
