package ai.onlo.sdk.messenger

import ai.onlo.sdk.MessengerInboxResult
import ai.onlo.sdk.MessengerPresentationIntent
import ai.onlo.sdk.MessengerPresentationTarget
import ai.onlo.sdk.MessengerTranscriptResult
import ai.onlo.sdk.Onlo
import ai.onlo.sdk.OnloClient
import ai.onlo.sdk.OnloPhase
import ai.onlo.sdk.OpenConversationOutcome
import android.app.Activity
import android.app.Dialog
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Build
import android.os.Looper
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Host-controlled Android Views presentation for the SDK-owned messenger. It creates no manifest
 * component, overlay, launcher, or permission prompt. Call it from a host-controlled support
 * action after [Onlo.initialize].
 */
public object OnloMessenger {
    private var active: MessengerDialog? = null

    @JvmStatic
    public fun present(activity: Activity, client: OnloClient = Onlo.instance()) {
        require(!activity.isFinishing && !activity.isDestroyed) { "activity_unavailable" }
        client.present()
        showAuthorisedTarget(activity, client)
    }

    /** Dismisses only the SDK dialog associated with this process; it never changes host navigation. */
    @JvmStatic
    public fun dismiss() {
        val dialog = active ?: return
        runOnMain(dialog.activity) {
            dialog.dismissFromHost()
            active = null
        }
    }

    @JvmStatic
    public suspend fun openConversation(
        activity: Activity,
        conversationId: String,
        client: OnloClient = Onlo.instance(),
    ): OpenConversationOutcome {
        val authorised = client.openConversation(conversationId)
        return withContext(Dispatchers.Main.immediate) {
            val decision = conversationOpenDecision(
                authorised,
                hostAvailable = !activity.isFinishing && !activity.isDestroyed,
            )
            // openConversation has already authorised and selected the target. Calling present()
            // here would reset it to Inbox, so only attach/show the native dialog.
            if (decision.clearPendingPresentation) client.dismiss()
            if (decision.attachMessenger) showAuthorisedTarget(activity, client)
            decision.outcome
        }
    }

    private fun showAuthorisedTarget(activity: Activity, client: OnloClient) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            activity.runOnUiThread { showAuthorisedTarget(activity, client) }
            return
        }
        if (activity.isFinishing || activity.isDestroyed) {
            client.dismiss()
            return
        }
        active?.takeIf { !it.isShowing }?.let { active = null }
        active?.takeIf { it.activity === activity && it.client === client }?.showCurrentTarget()
            ?: MessengerDialog(activity, client) { closed -> if (active === closed) active = null }
                .also { dialog -> active = dialog; dialog.showCurrentTarget() }
    }

    private fun runOnMain(activity: Activity, block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else activity.runOnUiThread(block)
    }
}

internal data class ConversationOpenDecision(
    val outcome: OpenConversationOutcome,
    val attachMessenger: Boolean,
    val clearPendingPresentation: Boolean,
)

internal fun conversationOpenDecision(
    outcome: OpenConversationOutcome,
    hostAvailable: Boolean = true,
): ConversationOpenDecision = when {
    outcome is OpenConversationOutcome.Opened && !hostAvailable -> ConversationOpenDecision(
        outcome = OpenConversationOutcome.Unavailable,
        attachMessenger = false,
        clearPendingPresentation = true,
    )
    else -> ConversationOpenDecision(
        outcome = outcome,
        attachMessenger = outcome is OpenConversationOutcome.Opened,
        clearPendingPresentation = false,
    )
}

/** Kept internal so framework bridges cannot gain a headless transcript or composer API. */
internal class MessengerDialog(
    internal val activity: Activity,
    internal val client: OnloClient,
    private val onClosed: (MessengerDialog) -> Unit,
) : Dialog(activity) {
    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var activeConversationId: String? = null
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var body: LinearLayout
    private lateinit var progress: ProgressBar
    private lateinit var composer: EditText
    private lateinit var send: Button

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(buildContent())
        setCanceledOnTouchOutside(true)
        setOnCancelListener { client.dismiss() }
        setOnDismissListener { uiScope.cancel(); client.dismiss(); onClosed(this) }
        stateJob = uiScope.launch {
            client.presentationIntent.collect { intent ->
                if (intent == MessengerPresentationIntent.HIDDEN && isShowing) dismiss()
            }
        }
        uiScope.launch {
            client.state.collect { state ->
                if (state.phase !in setOf(OnloPhase.ANONYMOUS_READY, OnloPhase.IDENTIFIED_READY) && isShowing) {
                    // Account boundaries win over a visible, stale transcript.
                    dismiss()
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
    }

    fun showCurrentTarget() {
        if (!isShowing) show()
        when (val target = client.presentationTarget.value) {
            MessengerPresentationTarget.Inbox -> loadInbox()
            is MessengerPresentationTarget.Conversation -> loadConversation(target.conversationId)
        }
    }

    fun dismissFromHost() {
        client.dismiss()
        if (isShowing) dismiss()
    }

    private fun buildContent(): View {
        val root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        val header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(12), dp(12), dp(12))
            background = rounded(Color.rgb(20, 89, 140), 0)
        }
        title = TextView(context).apply {
            text = "Support"
            setTextColor(Color.WHITE)
            textSize = 20f
            contentDescription = "Onlo support messenger"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
        }
        val close = Button(context).apply {
            text = "Close"
            contentDescription = "Close support messenger"
            setOnClickListener { dismissFromHost() }
        }
        header.addView(title, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        header.addView(close)
        root.addView(header)

        status = TextView(context).apply {
            setPadding(dp(16), dp(8), dp(16), dp(8))
            textSize = 14f
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            contentDescription = "Messenger status"
        }
        root.addView(status)
        progress = ProgressBar(context).apply {
            isIndeterminate = true
            contentDescription = "Loading messenger content"
            visibility = View.GONE
        }
        root.addView(progress, LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { gravity = Gravity.CENTER_HORIZONTAL })

        val scroll = ScrollView(context).apply {
            isFillViewport = true
            contentDescription = "Messenger conversation content"
        }
        body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        scroll.addView(body)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        val composerRow = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.BOTTOM
            setPadding(dp(12), dp(8), dp(12), dp(12))
        }
        composer = EditText(context).apply {
            hint = "Message support"
            contentDescription = "Message support"
            minLines = 1
            maxLines = 5
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 16f)
        }
        send = Button(context).apply {
            text = "Send"
            contentDescription = "Send message"
            setOnClickListener { enqueueComposer() }
        }
        composerRow.addView(composer, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        composerRow.addView(send)
        root.addView(composerRow)
        return root
    }

    private fun loadInbox() {
        activeConversationId = null
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        renderLoading("Loading conversations")
        uiScope.launch {
            when (val result = client.loadMessengerInbox()) {
                is MessengerInboxResult.Ready -> renderInbox(result.conversations)
                MessengerInboxResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerInboxResult.Unavailable -> renderUnavailable("Offline. Cached conversations will appear when available.")
            }
        }
    }

    private fun loadConversation(conversationId: String) {
        activeConversationId = conversationId
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        renderLoading("Loading conversation")
        uiScope.launch {
            when (val result = client.loadMessengerTranscript(conversationId)) {
                is MessengerTranscriptResult.Ready -> renderTranscript(result.transcript)
                is MessengerTranscriptResult.Stale -> { renderTranscript(result.transcript); showStatus("Offline. Showing saved conversation.") }
                MessengerTranscriptResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerTranscriptResult.NotAuthorised -> renderUnavailable("This conversation is unavailable.")
                MessengerTranscriptResult.Unavailable -> renderUnavailable("Offline. Conversation refresh is unavailable.")
            }
        }
    }

    private fun enqueueComposer() {
        val message = composer.text?.toString()?.trim().orEmpty()
        if (message.isEmpty()) {
            announce("Enter a message before sending.")
            return
        }
        send.isEnabled = false
        uiScope.launch {
            try {
                client.sendTextFromNativeUi(message)
                composer.setText("")
                announce("Message queued for delivery.")
            } catch (_: IllegalArgumentException) {
                announce("Message could not be queued.")
            } catch (_: IllegalStateException) {
                announce("Support is not ready. Try again shortly.")
            } finally {
                send.isEnabled = true
            }
        }
    }

    private fun renderInbox(conversations: List<ai.onlo.sdk.chat.ConversationSummary>) {
        progress.visibility = View.GONE
        body.removeAllViews()
        if (conversations.isEmpty()) {
            body.addView(label("No conversations yet. Send a message to start one."))
            hideStatus()
            return
        }
        hideStatus()
        conversations.forEach { conversation ->
            val item = Button(context).apply {
                text = conversation.title.ifBlank { "Support conversation" }
                contentDescription = buildString {
                    append("Conversation: ").append(conversation.title.ifBlank { "Support conversation" })
                    if (conversation.unreadCount > 0) append(", ").append(conversation.unreadCount).append(" unread")
                }
                setAllCaps(false)
                setOnClickListener { loadConversation(conversation.id) }
            }
            body.addView(item, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
        }
    }

    private fun renderTranscript(transcript: ai.onlo.sdk.chat.ConversationDetail) {
        progress.visibility = View.GONE
        body.removeAllViews()
        hideStatus()
        if (transcript.messages.isEmpty()) body.addView(label("No messages yet."))
        transcript.messages.forEach { message ->
            val mine = message.role.equals("user", ignoreCase = true)
            body.addView(label(message.text, mine), LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
        }
        if (transcript.isHumanTakeover) announce("A support team member is handling this conversation.")
    }

    private fun renderLoading(label: String) {
        body.removeAllViews()
        progress.visibility = View.VISIBLE
        showStatus(label)
    }

    private fun renderUnavailable(message: String) {
        progress.visibility = View.GONE
        body.removeAllViews()
        body.addView(label(message))
        showStatus(message)
    }

    private fun announce(message: String) = showStatus(message)
    private fun showStatus(message: String) { status.text = message; status.visibility = View.VISIBLE }
    private fun hideStatus() { status.visibility = View.GONE }

    private fun label(value: String, outgoing: Boolean = false): TextView = TextView(context).apply {
        text = value
        textSize = 16f
        setTextColor(if (outgoing) Color.WHITE else Color.rgb(25, 25, 25))
        setPadding(dp(12), dp(10), dp(12), dp(10))
        background = rounded(if (outgoing) Color.rgb(20, 89, 140) else Color.rgb(239, 241, 243), dp(12))
        contentDescription = if (outgoing) "Your message" else "Support message"
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    private fun rounded(color: Int, radius: Int): GradientDrawable = GradientDrawable().apply { setColor(color); cornerRadius = radius.toFloat() }
    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()
}
