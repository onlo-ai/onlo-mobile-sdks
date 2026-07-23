package ai.onlo.sdk.messenger

import ai.onlo.sdk.MessengerInboxResult
import ai.onlo.sdk.MessengerHelpArticleResult
import ai.onlo.sdk.MessengerHelpCenterResult
import ai.onlo.sdk.MessengerPresentationIntent
import ai.onlo.sdk.MessengerPresentationTarget
import ai.onlo.sdk.MessengerTranscriptResult
import ai.onlo.sdk.NativeMessengerEvent
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
import android.text.Html
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
    private enum class Surface { CONVERSATIONS, FAQ, HELP_CENTER }

    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var activeConversationId: String? = null
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var body: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var progress: ProgressBar
    private lateinit var composer: EditText
    private lateinit var send: Button
    private lateinit var composerRow: LinearLayout
    private var activeSurface = Surface.CONVERSATIONS
    private val streamedReplies = mutableMapOf<String, TextView>()
    private var showingEmptyState = false

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
        uiScope.launch {
            client.messengerEvents.collect(::renderMessengerEvent)
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

        val surfaces = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            setPadding(dp(8), dp(8), dp(8), 0)
        }
        listOf(
            "Conversations" to Surface.CONVERSATIONS,
            "FAQ" to Surface.FAQ,
            "Help Center" to Surface.HELP_CENTER,
        ).forEach { (label, surface) ->
            surfaces.addView(
                Button(context).apply {
                    text = label
                    setAllCaps(false)
                    contentDescription = "$label section"
                    setOnClickListener { selectSurface(surface) }
                },
                LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f),
            )
        }
        root.addView(surfaces)

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

        scroll = ScrollView(context).apply {
            isFillViewport = true
            contentDescription = "Messenger conversation content"
        }
        body = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(16), dp(12), dp(16), dp(12))
        }
        scroll.addView(body)
        root.addView(scroll, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f))

        composerRow = LinearLayout(context).apply {
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
        activeSurface = Surface.CONVERSATIONS
        activeConversationId = null
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        composerRow.visibility = View.VISIBLE
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        renderLoading("Loading conversations")
        uiScope.launch {
            val result = client.loadMessengerInbox()
            if (activeSurface != Surface.CONVERSATIONS) return@launch
            when (result) {
                is MessengerInboxResult.Ready -> renderInbox(result.conversations)
                MessengerInboxResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerInboxResult.Unavailable -> renderUnavailable("Offline. Cached conversations will appear when available.")
            }
        }
    }

    private fun loadConversation(conversationId: String) {
        activeSurface = Surface.CONVERSATIONS
        activeConversationId = conversationId
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        composerRow.visibility = View.VISIBLE
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        renderLoading("Loading conversation")
        uiScope.launch {
            val result = client.loadMessengerTranscript(conversationId)
            if (activeSurface != Surface.CONVERSATIONS) return@launch
            when (result) {
                is MessengerTranscriptResult.Ready -> {
                    renderTranscript(result.transcript)
                    result.transcript.messages.maxByOrNull { it.timestamp }?.let {
                        runCatching {
                            client.acknowledgeRenderedConversation(result.transcript.id, it.id)
                        }
                    }
                }
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
                client.sendTextFromNativeUi(message) { clientMessageId ->
                    composer.setText("")
                    appendMessage(label(message, outgoing = true))
                    streamedReplies.remove(clientMessageId)
                }
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

    private fun selectSurface(surface: Surface) {
        activeSurface = surface
        composerRow.visibility = if (surface == Surface.CONVERSATIONS) View.VISIBLE else View.GONE
        when (surface) {
            Surface.CONVERSATIONS -> loadInbox()
            Surface.FAQ -> renderFaqs()
            Surface.HELP_CENTER -> loadHelpCenter()
        }
    }

    private fun renderFaqs() {
        progress.visibility = View.GONE
        body.removeAllViews()
        hideStatus()
        val config = client.mobileConfig?.value?.config
        val faqs = if (config?.features?.faqButton?.enabled == true) {
            config.content.faqs.filter { it.question.isNotBlank() && !it.answer.isNullOrBlank() }
        } else {
            emptyList()
        }
        if (faqs.isEmpty()) {
            body.addView(label("No FAQs are available yet."))
            return
        }
        faqs.forEach { faq ->
            body.addView(
                label("${faq.question}\n\n${faq.answer.orEmpty()}"),
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) },
            )
        }
    }

    private fun loadHelpCenter() {
        renderLoading("Loading Help Center")
        uiScope.launch {
            val result = client.loadMessengerHelpCenter()
            if (activeSurface != Surface.HELP_CENTER) return@launch
            when (result) {
                is MessengerHelpCenterResult.Ready -> renderHelpTopics(result.topics)
                MessengerHelpCenterResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerHelpCenterResult.Unavailable -> renderUnavailable("Help Center is temporarily unavailable.")
            }
        }
    }

    private fun renderHelpTopics(topics: List<ai.onlo.sdk.chat.HelpCenterTopic>) {
        progress.visibility = View.GONE
        body.removeAllViews()
        hideStatus()
        if (topics.isEmpty()) {
            body.addView(label("No Help Center articles are available yet."))
            return
        }
        topics.forEach { topic ->
            body.addView(
                Button(context).apply {
                    text = "${topic.name} (${topic.count})"
                    setAllCaps(false)
                    contentDescription = "${topic.name}, ${topic.count} articles"
                    setOnClickListener { renderHelpArticles(topic, topics) }
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) },
            )
        }
    }

    private fun renderHelpArticles(
        topic: ai.onlo.sdk.chat.HelpCenterTopic,
        topics: List<ai.onlo.sdk.chat.HelpCenterTopic>,
    ) {
        body.removeAllViews()
        body.addView(backButton("All topics") { renderHelpTopics(topics) })
        topic.articles.forEach { article ->
            body.addView(
                Button(context).apply {
                    text = article.title
                    setAllCaps(false)
                    contentDescription = article.title
                    setOnClickListener { loadHelpArticle(article.id, topic, topics) }
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) },
            )
        }
    }

    private fun loadHelpArticle(
        articleId: String,
        topic: ai.onlo.sdk.chat.HelpCenterTopic,
        topics: List<ai.onlo.sdk.chat.HelpCenterTopic>,
    ) {
        renderLoading("Loading article")
        uiScope.launch {
            val result = client.loadMessengerHelpArticle(articleId)
            if (activeSurface != Surface.HELP_CENTER) return@launch
            when (result) {
                is MessengerHelpArticleResult.Ready -> {
                    progress.visibility = View.GONE
                    body.removeAllViews()
                    hideStatus()
                    body.addView(backButton(topic.name) { renderHelpArticles(topic, topics) })
                    body.addView(label(result.article.title))
                    body.addView(
                        label(
                            Html.fromHtml(
                                result.article.body,
                                Html.FROM_HTML_MODE_LEGACY,
                            ).toString(),
                        ),
                    )
                }
                MessengerHelpArticleResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerHelpArticleResult.NotAuthorised -> renderUnavailable("This article is unavailable.")
                MessengerHelpArticleResult.Unavailable -> renderUnavailable("Help Center is temporarily unavailable.")
            }
        }
    }

    private fun backButton(text: String, action: () -> Unit): Button = Button(context).apply {
        this.text = "‹ $text"
        setAllCaps(false)
        contentDescription = "Back to $text"
        setOnClickListener { action() }
    }

    private fun renderMessengerEvent(event: NativeMessengerEvent) {
        if (activeSurface != Surface.CONVERSATIONS) return
        when (event) {
            is NativeMessengerEvent.Accepted -> {
                activeConversationId = event.conversationId
                announce("Message sent.")
            }
            is NativeMessengerEvent.Text -> {
                val reply = streamedReplies.getOrPut(event.clientMessageId) {
                    label("").also(::appendMessage)
                }
                reply.append(event.content)
                scrollToBottom()
            }
            is NativeMessengerEvent.Done -> {
                streamedReplies.remove(event.clientMessageId)
                loadConversation(event.conversationId)
            }
            is NativeMessengerEvent.Failed -> {
                streamedReplies.remove(event.clientMessageId)
                announce(
                    if (event.retryable) "Message is queued and will retry."
                    else "Message could not be delivered.",
                )
            }
        }
    }

    private fun appendMessage(view: TextView) {
        progress.visibility = View.GONE
        if (activeConversationId == null || showingEmptyState) {
            body.removeAllViews()
            showingEmptyState = false
        }
        body.addView(
            view,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(8) },
        )
        scrollToBottom()
    }

    private fun scrollToBottom() {
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun renderInbox(conversations: List<ai.onlo.sdk.chat.ConversationSummary>) {
        progress.visibility = View.GONE
        body.removeAllViews()
        if (conversations.isEmpty()) {
            showingEmptyState = true
            body.addView(label("No conversations yet. Send a message to start one."))
            hideStatus()
            return
        }
        showingEmptyState = false
        hideStatus()
        conversations.forEach { conversation ->
            val item = Button(context).apply {
                val baseTitle = conversation.title.ifBlank { "Support conversation" }
                text = if (conversation.unreadCount > 0) "$baseTitle  ${conversation.unreadCount}" else baseTitle
                contentDescription = buildString {
                    append("Conversation: ").append(baseTitle)
                    if (conversation.unreadCount > 0) append(", ${conversation.unreadCount} unread")
                }
                setAllCaps(false)
                setOnClickListener { loadConversation(conversation.id) }
            }
            body.addView(item, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply { bottomMargin = dp(8) })
        }
    }

    private fun renderTranscript(transcript: ai.onlo.sdk.chat.ConversationDetail) {
        progress.visibility = View.GONE
        streamedReplies.clear()
        showingEmptyState = false
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
        showingEmptyState = false
        body.removeAllViews()
        progress.visibility = View.VISIBLE
        showStatus(label)
    }

    private fun renderUnavailable(message: String) {
        showingEmptyState = false
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
