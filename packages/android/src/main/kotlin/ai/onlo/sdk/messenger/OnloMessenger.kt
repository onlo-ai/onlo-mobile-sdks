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
import ai.onlo.sdk.OnloException
import ai.onlo.sdk.OpenConversationOutcome
import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.app.Fragment
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Bundle
import android.os.Build
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.text.Html
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.widget.Button
import android.widget.EditText
import android.widget.ImageView
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
import java.util.Locale
import java.io.ByteArrayOutputStream

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

@Suppress("DEPRECATION")
internal class AttachmentPickerFragment : Fragment() {
    enum class Source { LIBRARY, CAMERA }

    var onImage: ((Bitmap) -> Unit)? = null
    var onFailure: (() -> Unit)? = null
    private var pendingSource: Source? = null

    fun launch(source: Source) {
        pendingSource = source
        if (
            source == Source.CAMERA &&
            checkNotNull(activity).checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION)
            return
        }
        launchIntent(source)
    }

    private fun launchIntent(source: Source) {
        val intent = if (source == Source.LIBRARY) {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "image/*"
            }
        } else {
            Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE)
        }
        runCatching { startActivityForResult(intent, if (source == Source.LIBRARY) LIBRARY else CAMERA) }
            .onFailure { onFailure?.invoke() }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != CAMERA_PERMISSION) return
        if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
            launchIntent(Source.CAMERA)
        } else {
            onFailure?.invoke()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (resultCode != Activity.RESULT_OK) return
        val bitmap = when (requestCode) {
            LIBRARY -> data?.data?.let(::decodeLibraryImage)
            CAMERA -> if (Build.VERSION.SDK_INT >= 33) {
                data?.getParcelableExtra("data", Bitmap::class.java)
            } else {
                @Suppress("DEPRECATION")
                data?.getParcelableExtra("data") as? Bitmap
            }
            else -> null
        }
        if (bitmap != null) onImage?.invoke(bitmap) else onFailure?.invoke()
    }

    private fun decodeLibraryImage(uri: Uri): Bitmap? {
        val resolver = activity?.contentResolver ?: return null
        val source = resolver.openInputStream(uri)?.use { input ->
            val output = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                output.write(buffer, 0, read)
                if (output.size() > MAX_SOURCE_IMAGE_BYTES) return null
            }
            output.toByteArray()
        } ?: return null
        if (source.isEmpty()) return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        var sample = 1
        while (
            bounds.outWidth / sample > 4_096 ||
            bounds.outHeight / sample > 4_096 ||
            (bounds.outWidth.toLong() / sample) * (bounds.outHeight.toLong() / sample) > 16_000_000L
        ) {
            sample *= 2
        }
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(source, 0, source.size, options)
    }

    private companion object {
        const val LIBRARY = 0x0A21
        const val CAMERA = 0x0A22
        const val CAMERA_PERMISSION = 0x0A23
        const val MAX_SOURCE_IMAGE_BYTES = 25 * 1024 * 1024
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
    private var activeSessionId: String? = null
    private val pendingAttachments = mutableListOf<OnloClient.PendingNativeAttachment>()
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var body: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var progress: ProgressBar
    private lateinit var composer: EditText
    private lateinit var send: Button
    private lateinit var voice: Button
    private lateinit var attach: Button
    private lateinit var speaker: Button
    private lateinit var composerRow: LinearLayout
    private lateinit var root: LinearLayout
    private lateinit var header: LinearLayout
    private lateinit var headerAvatar: ImageView
    private lateinit var headerInitials: TextView
    private lateinit var headerName: TextView
    private lateinit var headerSubtitle: TextView
    private var activeSurface = Surface.CONVERSATIONS
    private val streamedReplies = mutableMapOf<String, TextView>()
    private var showingEmptyState = false
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var isListening = false
    private var speaksReplies = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(buildContent())
        setCanceledOnTouchOutside(true)
        setOnCancelListener { client.dismiss() }
        setOnDismissListener {
            stopVoice()
            speechRecognizer?.destroy()
            speechRecognizer = null
            textToSpeech?.shutdown()
            textToSpeech = null
            uiScope.cancel()
            client.dismiss()
            onClosed(this)
        }
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
        client.mobileConfig?.let { snapshots ->
            uiScope.launch {
                snapshots.collect {
                    applyAppearance()
                    updateVoiceControls()
                    updateAttachmentControl()
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
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(Color.WHITE)
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(16), dp(12), dp(12), dp(12))
            background = rounded(Color.rgb(20, 89, 140), 0)
        }
        headerAvatar = ImageView(context).apply {
            contentDescription = "Support avatar"
            scaleType = ImageView.ScaleType.CENTER_CROP
            visibility = View.GONE
        }
        headerInitials = TextView(context).apply {
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            textSize = 13f
            background = rounded(Color.rgb(20, 89, 140), dp(16))
            contentDescription = "Support avatar"
        }
        val avatarSize = LinearLayout.LayoutParams(dp(32), dp(32)).apply {
            marginEnd = dp(8)
        }
        header.addView(headerAvatar, avatarSize)
        header.addView(headerInitials, LinearLayout.LayoutParams(dp(32), dp(32)).apply {
            marginEnd = dp(8)
        })
        headerName = TextView(context).apply {
            text = "Support"
            setTextColor(Color.WHITE)
            textSize = 20f
            contentDescription = "Onlo support messenger"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
        }
        headerSubtitle = TextView(context).apply {
            setTextColor(Color.WHITE)
            textSize = 12f
            visibility = View.GONE
        }
        val headerLabels = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(headerName)
            addView(headerSubtitle)
        }
        title = headerName
        val close = Button(context).apply {
            text = "Close"
            contentDescription = "Close support messenger"
            setOnClickListener { dismissFromHost() }
        }
        header.addView(headerLabels, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        speaker = Button(context).apply {
            text = "Speak"
            contentDescription = "Speak completed support replies"
            visibility = View.GONE
            setOnClickListener {
                speaksReplies = !speaksReplies
                updateVoiceControls()
                announce(if (speaksReplies) "Spoken replies enabled." else "Spoken replies disabled.")
            }
        }
        header.addView(speaker)
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
        voice = Button(context).apply {
            text = "Voice"
            contentDescription = "Start voice input"
            visibility = View.GONE
            setOnClickListener { toggleVoiceInput() }
        }
        attach = Button(context).apply {
            text = "Image"
            contentDescription = "Add image"
            setOnClickListener { chooseImageSource() }
        }
        composerRow.addView(attach)
        composerRow.addView(composer, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        composerRow.addView(voice)
        composerRow.addView(send)
        root.addView(composerRow)
        applyAppearance()
        updateVoiceControls()
        updateAttachmentControl()
        return root
    }

    private fun loadInbox() {
        activeSurface = Surface.CONVERSATIONS
        activeConversationId = null
        activeSessionId = null
        pendingAttachments.clear()
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        applyAppearance()
        updateVoiceControls()
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
        applyAppearance()
        updateVoiceControls()
        composerRow.visibility = View.VISIBLE
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        renderLoading("Loading conversation")
        uiScope.launch {
            val result = client.loadMessengerTranscript(conversationId)
            if (activeSurface != Surface.CONVERSATIONS) return@launch
            when (result) {
                is MessengerTranscriptResult.Ready -> {
                    activeSessionId = result.transcript.sessionId
                    renderTranscript(result.transcript)
                    result.transcript.messages.maxByOrNull { it.timestamp }?.let {
                        runCatching {
                            client.acknowledgeRenderedConversation(result.transcript.id, it.id)
                        }
                    }
                }
                is MessengerTranscriptResult.Stale -> {
                    activeSessionId = result.transcript.sessionId
                    renderTranscript(result.transcript)
                    showStatus("Offline. Showing saved conversation.")
                }
                MessengerTranscriptResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerTranscriptResult.NotAuthorised -> renderUnavailable("This conversation is unavailable.")
                MessengerTranscriptResult.Unavailable -> renderUnavailable("Offline. Conversation refresh is unavailable.")
            }
        }
    }

    private fun enqueueComposer() {
        val message = composer.text?.toString()?.trim().orEmpty()
        if (message.isEmpty() && pendingAttachments.isEmpty()) {
            announce("Enter a message before sending.")
            return
        }
        send.isEnabled = false
        uiScope.launch {
            try {
                client.sendTextFromNativeUi(
                    message = message,
                    routingSessionId = activeSessionId,
                    attachments = pendingAttachments.toList(),
                ) { clientMessageId ->
                    composer.setText("")
                    pendingAttachments.clear()
                    updateAttachmentControl()
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

    private fun attachmentsEnabled(): Boolean {
        val config = client.mobileConfig?.value?.config ?: return false
        return config.features.fileUpload &&
            config.mediaPolicy.enabled &&
            config.compatibility.capabilities.contains(ai.onlo.sdk.protocol.Capability.MEDIA_PICKER) &&
            config.compatibility.capabilities.contains(ai.onlo.sdk.protocol.Capability.ATTACHMENT_UPLOAD)
    }

    private fun updateAttachmentControl() {
        if (!::attach.isInitialized) return
        val config = client.mobileConfig?.value?.config
        attach.visibility = if (attachmentsEnabled()) View.VISIBLE else View.GONE
        attach.isEnabled = attachmentsEnabled() &&
            pendingAttachments.size < (config?.mediaPolicy?.effectiveMaximumImagesPerMessage ?: 0)
        attach.text = if (pendingAttachments.isEmpty()) "Image" else "Image (${pendingAttachments.size})"
    }

    private fun chooseImageSource() {
        if (!attachmentsEnabled()) return
        AlertDialog.Builder(activity)
            .setItems(arrayOf("Photo library", "Camera")) { _, index ->
                pickerFragment().launch(
                    if (index == 0) AttachmentPickerFragment.Source.LIBRARY
                    else AttachmentPickerFragment.Source.CAMERA,
                )
            }
            .setNegativeButton("Cancel", null)
            .show()
    }

    private fun pickerFragment(): AttachmentPickerFragment {
        val tag = "onlo-attachment-picker"
        val existing = activity.fragmentManager.findFragmentByTag(tag) as? AttachmentPickerFragment
        return (existing ?: AttachmentPickerFragment().also {
            activity.fragmentManager.beginTransaction().add(it, tag).commitNow()
        }).apply {
            onImage = ::prepareAndUpload
            onFailure = { showStatus("Image could not be added.") }
        }
    }

    private fun prepareAndUpload(bitmap: Bitmap) {
        uiScope.launch {
            try {
                val config = client.mobileConfig?.value?.config ?: throw IllegalStateException()
                val edgeScale = minOf(
                    1.0,
                    4_096.0 / bitmap.width.toDouble(),
                    4_096.0 / bitmap.height.toDouble(),
                    kotlin.math.sqrt(16_000_000.0 / (bitmap.width.toDouble() * bitmap.height.toDouble())),
                )
                val candidate = if (edgeScale < 1.0) Bitmap.createScaledBitmap(
                    bitmap,
                    maxOf(1, (bitmap.width * edgeScale).toInt()),
                    maxOf(1, (bitmap.height * edgeScale).toInt()),
                    true,
                ) else bitmap
                var prepared: ByteArray? = null
                for (quality in listOf(90, 82, 74)) {
                    val output = ByteArrayOutputStream()
                    candidate.compress(Bitmap.CompressFormat.JPEG, quality, output)
                    if (output.size() <= config.mediaPolicy.effectiveMaximumImageBytes) {
                        prepared = output.toByteArray()
                        break
                    }
                }
                val bytes = prepared ?: throw IllegalArgumentException("attachment_size")
                pendingAttachments += client.uploadImageFromNativeUi(
                    conversationId = activeConversationId,
                    bytes = bytes,
                    mimeType = "image/jpeg",
                    fileName = "onlo-image-${java.util.UUID.randomUUID()}.jpg",
                )
                updateAttachmentControl()
                showStatus("Image ready to send.")
            } catch (error: OnloException.Server) {
                showStatus(if (error.code == "media_unavailable") "Image upload is disabled." else "Image is unauthorized.")
            } catch (_: Exception) {
                showStatus("Image could not be added.")
            }
        }
    }

    private fun selectSurface(surface: Surface) {
        if (surface != Surface.CONVERSATIONS) stopVoice()
        activeSurface = surface
        composerRow.visibility = if (surface == Surface.CONVERSATIONS) View.VISIBLE else View.GONE
        updateVoiceControls()
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
                val completedReply = streamedReplies.remove(event.clientMessageId)?.text?.toString()
                if (speaksReplies && !completedReply.isNullOrBlank()) {
                    speakCompletedReply(completedReply)
                }
                loadConversation(event.conversationId)
            }
            is NativeMessengerEvent.Failed -> {
                streamedReplies.remove(event.clientMessageId)
                announce(
                    when {
                        event.retryable -> "Message is queued and will retry."
                        event.safeCode == "attachment_grant_expired" -> "Image authorization expired. Add the image again."
                        event.safeCode == "media_unavailable" -> "Image upload is disabled."
                        event.safeCode == "invalid_attachment_grant" -> "Image is no longer authorized."
                        else -> "Message could not be delivered."
                    },
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
            val greeting = client.mobileConfig?.value?.config?.appearance?.greeting
                ?.takeIf { it.isNotBlank() }
                ?: "No conversations yet. Send a message to start one."
            body.addView(label(greeting))
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
        tag = if (outgoing) MESSAGE_OUTGOING else MESSAGE_INCOMING
        text = value
        textSize = 16f
        setTextColor(if (outgoing) outgoingTextColor() else incomingTextColor())
        setPadding(dp(12), dp(10), dp(12), dp(10))
        background = rounded(if (outgoing) outgoingColor() else incomingColor(), dp(12))
        contentDescription = if (outgoing) "Your message" else "Support message"
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    private fun toggleVoiceInput() {
        if (!voiceEnabled()) return
        if (isListening) {
            stopVoice()
            return
        }
        if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            activity.requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), VOICE_PERMISSION_REQUEST)
            announce("Allow microphone access, then tap Voice again.")
            return
        }
        if (!SpeechRecognizer.isRecognitionAvailable(activity)) {
            announce("Voice input is unavailable. Text chat remains available.")
            return
        }
        val recognizer = speechRecognizer ?: SpeechRecognizer.createSpeechRecognizer(activity).also {
            speechRecognizer = it
            it.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = Unit
                override fun onBeginningOfSpeech() = Unit
                override fun onRmsChanged(rmsdB: Float) = Unit
                override fun onBufferReceived(buffer: ByteArray?) = Unit
                override fun onEndOfSpeech() = Unit
                override fun onEvent(eventType: Int, params: Bundle?) = Unit
                override fun onPartialResults(partialResults: Bundle?) {
                    applyRecognizedText(partialResults)
                }
                override fun onResults(results: Bundle?) {
                    applyRecognizedText(results)
                    isListening = false
                    updateVoiceControls()
                }
                override fun onError(error: Int) {
                    isListening = false
                    updateVoiceControls()
                    announce("Voice input stopped. Text chat remains available.")
                }
            })
        }
        isListening = true
        updateVoiceControls()
        recognizer.startListening(
            Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
                putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            },
        )
    }

    private fun applyRecognizedText(results: Bundle?) {
        val value = results
            ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
            ?.firstOrNull()
            ?.trim()
            .orEmpty()
        if (value.isNotEmpty()) composer.setText(value)
    }

    private fun stopVoice() {
        if (isListening) speechRecognizer?.stopListening()
        isListening = false
        if (::voice.isInitialized) updateVoiceControls()
    }

    private fun speakCompletedReply(reply: String) {
        val existing = textToSpeech
        if (existing != null) {
            existing.speak(reply, TextToSpeech.QUEUE_FLUSH, null, "onlo-completed-reply")
            return
        }
        var created: TextToSpeech? = null
        created = TextToSpeech(activity) { status ->
            if (status != TextToSpeech.SUCCESS) {
                speaksReplies = false
                updateVoiceControls()
                announce("Spoken replies are unavailable. Text chat remains available.")
            } else {
                created?.language = Locale.getDefault()
                created?.speak(reply, TextToSpeech.QUEUE_FLUSH, null, "onlo-completed-reply")
            }
        }
        textToSpeech = created
    }

    private fun updateVoiceControls() {
        if (!::voice.isInitialized || !::speaker.isInitialized) return
        val available = voiceEnabled()
        voice.visibility = if (available && activeSurface == Surface.CONVERSATIONS) View.VISIBLE else View.GONE
        speaker.visibility = if (available && activeSurface == Surface.CONVERSATIONS) View.VISIBLE else View.GONE
        voice.text = if (isListening) "Stop" else "Voice"
        voice.contentDescription = if (isListening) "Stop voice input" else "Start voice input"
        speaker.text = if (speaksReplies) "Mute" else "Speak"
        speaker.contentDescription = if (speaksReplies) "Disable spoken replies" else "Enable spoken replies"
    }

    private fun voiceEnabled(): Boolean =
        client.mobileConfig?.value?.config?.features?.voice == true

    private fun applyAppearance() {
        if (!::root.isInitialized || !::header.isInitialized) return
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES && appearance?.dark?.enabled == true
        val background = if (darkMode) appearance?.dark?.background else appearance?.light?.background
        root.setBackgroundColor(parseColor(background, if (darkMode) Color.BLACK else Color.WHITE))
        header.background = rounded(parseColor(appearance?.accent, Color.rgb(20, 89, 140)), 0)
        title.text = appearance?.botName?.ifBlank { "Support" } ?: "Support"
        headerSubtitle.text = appearance?.botSubtitle.orEmpty()
        headerSubtitle.visibility = if (headerSubtitle.text.isBlank()) View.GONE else View.VISIBLE
        headerInitials.text = appearance?.headerAvatar?.text.orEmpty()
        val avatarBitmap = appearance?.headerAvatar?.data?.let(::decodeDataImage)
        val showsImage = appearance?.headerAvatar?.mode ==
            ai.onlo.sdk.config.MobileConfig.HeaderAvatarMode.IMAGE && avatarBitmap != null
        headerAvatar.visibility = if (showsImage) View.VISIBLE else View.GONE
        headerInitials.visibility = if (showsImage) View.GONE else View.VISIBLE
        headerAvatar.setImageBitmap(avatarBitmap)
        val avatarDescription = appearance?.botName?.ifBlank { "Support" } ?: "Support"
        headerAvatar.contentDescription = "$avatarDescription avatar"
        headerInitials.contentDescription = "$avatarDescription avatar"
        if (::body.isInitialized) {
            for (index in 0 until body.childCount) {
                val message = body.getChildAt(index) as? TextView ?: continue
                when (message.tag) {
                    MESSAGE_OUTGOING -> {
                        message.setTextColor(outgoingTextColor())
                        message.background = rounded(outgoingColor(), dp(12))
                    }
                    MESSAGE_INCOMING -> {
                        message.setTextColor(incomingTextColor())
                        message.background = rounded(incomingColor(), dp(12))
                    }
                }
            }
        }
    }

    private fun outgoingColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES && appearance?.dark?.enabled == true
        return parseColor(if (darkMode) appearance?.dark?.outgoing else appearance?.light?.outgoing, Color.rgb(20, 89, 140))
    }

    private fun outgoingTextColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES && appearance?.dark?.enabled == true
        return parseColor(if (darkMode) appearance?.dark?.outgoingText else appearance?.light?.outgoingText, Color.WHITE)
    }

    private fun incomingColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES && appearance?.dark?.enabled == true
        return parseColor(if (darkMode) appearance?.dark?.incoming else appearance?.light?.incoming, Color.rgb(239, 241, 243))
    }

    private fun incomingTextColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = context.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK ==
            Configuration.UI_MODE_NIGHT_YES && appearance?.dark?.enabled == true
        return parseColor(if (darkMode) appearance?.dark?.incomingText else appearance?.light?.incomingText, Color.rgb(25, 25, 25))
    }

    private fun parseColor(value: String?, fallback: Int): Int =
        runCatching { Color.parseColor(value) }.getOrDefault(fallback)

    private fun decodeDataImage(value: String): android.graphics.Bitmap? {
        val payload = value.substringAfter(',', missingDelimiterValue = "")
        if (!value.startsWith("data:image/") || !value.substringBefore(',').endsWith(";base64") ||
            payload.isEmpty()
        ) return null
        return runCatching {
            val bytes = Base64.decode(payload, Base64.DEFAULT)
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
        }.getOrNull()
    }

    private fun rounded(color: Int, radius: Int): GradientDrawable = GradientDrawable().apply { setColor(color); cornerRadius = radius.toFloat() }
    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()

    private companion object {
        const val VOICE_PERMISSION_REQUEST = 0x0A10
        const val MESSAGE_OUTGOING = "onlo_message_outgoing"
        const val MESSAGE_INCOMING = "onlo_message_incoming"
    }
}
