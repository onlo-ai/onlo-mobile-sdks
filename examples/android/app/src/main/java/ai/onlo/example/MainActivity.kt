package ai.onlo.example

import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.messenger.OnloMessenger
import android.os.Bundle
import android.view.Gravity
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import androidx.appcompat.app.AppCompatActivity
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Local host foundation. It deliberately has no SDK key, JWT, or signing
 * implementation in source. Wire the two provider functions to an
 * authenticated Operator backend only in a private host app configuration.
 */
class MainActivity : AppCompatActivity() {
    private lateinit var supportButton: Button
    private lateinit var status: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        supportButton = Button(this).apply { text = "Support"; isEnabled = false }
        status = TextView(this).apply { text = "Local mock host: SDK key not configured" }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(48, 48, 48, 48)
            addView(status)
            addView(supportButton)
        })
        supportButton.setOnClickListener { OnloMessenger.present(this, Onlo.instance()) }

        // Replace this synthetic placeholder through private build configuration.
        // It is intentionally not an app secret and must never be a customer JWT.
        val publicSdkKey: String? = null
        if (publicSdkKey == null) return
        val client = Onlo.initialize(applicationContext, publicSdkKey)
        lifecycleScope.launch {
            client.state.collectLatest { state ->
                supportButton.isEnabled = state.phase == OnloPhase.ANONYMOUS_READY ||
                    state.phase == OnloPhase.IDENTIFIED_READY
                status.text = "Native state: ${state.phase.name.lowercase()}"
            }
        }
    }

    /** Call only after the host app has authenticated its own customer. */
    private suspend fun identifyFromOperatorBackend() {
        val userJwt = OperatorBackend(this).fetchShortLivedOnloUserJwt()
        Onlo.instance().loginIdentifiedUser(userJwt)
    }
}

private class OperatorBackend(private val activity: MainActivity) {
    suspend fun fetchShortLivedOnloUserJwt(): String =
        error("Implement a private authenticated Operator-backend call; never sign a JWT in the app.")
}
