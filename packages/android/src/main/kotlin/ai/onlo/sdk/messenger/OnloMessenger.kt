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
import ai.onlo.sdk.chat.HelpCenterTopic
import ai.onlo.sdk.config.MobileConfig
import android.Manifest
import android.animation.ObjectAnimator
import android.animation.PropertyValuesHolder
import android.animation.ValueAnimator
import android.app.Activity
import android.app.AlertDialog
import android.app.Dialog
import android.app.Fragment
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.drawable.ColorDrawable
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
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.Base64
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowInsets
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.graphics.Typeface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.Locale
import java.util.TimeZone
import java.io.ByteArrayOutputStream
import java.text.SimpleDateFormat

/**
 * Host-controlled Android Views presentation for the SDK-owned messenger. It creates no manifest
 * component, overlay, launcher, or permission prompt. Call it from a host-controlled support
 * action after [Onlo.initialize].
 */
public enum class OnloMessengerPresentationMode {
    /** A rounded, inset-safe modal surface inside the host Activity. */
    CONTAINED,

    /** An edge-to-edge host Activity surface whose content still respects system bars. */
    FULL_SCREEN,
}

public data class OnloMessengerOptions(
    public val presentationMode: OnloMessengerPresentationMode = OnloMessengerPresentationMode.CONTAINED,
)

public object OnloMessenger {
    private var active: MessengerDialog? = null

    @JvmStatic
    public fun present(activity: Activity, client: OnloClient = Onlo.instance()) {
        present(activity, OnloMessengerOptions(), client)
    }

    @JvmStatic
    public fun present(
        activity: Activity,
        options: OnloMessengerOptions,
        client: OnloClient = Onlo.instance(),
    ) {
        require(!activity.isFinishing && !activity.isDestroyed) { "activity_unavailable" }
        client.present()
        showAuthorisedTarget(activity, client, options)
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
    ): OpenConversationOutcome = openConversation(
        activity = activity,
        conversationId = conversationId,
        options = OnloMessengerOptions(),
        client = client,
    )

    @JvmStatic
    public suspend fun openConversation(
        activity: Activity,
        conversationId: String,
        options: OnloMessengerOptions,
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
            if (decision.attachMessenger) showAuthorisedTarget(activity, client, options)
            decision.outcome
        }
    }

    private fun showAuthorisedTarget(
        activity: Activity,
        client: OnloClient,
        options: OnloMessengerOptions,
    ) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            activity.runOnUiThread { showAuthorisedTarget(activity, client, options) }
            return
        }
        if (activity.isFinishing || activity.isDestroyed) {
            client.dismiss()
            return
        }
        active?.takeIf { !it.isShowing }?.let { active = null }
        // Presentation options are fixed for the lifetime of one visible messenger. A host can
        // dismiss and present again to change mode without duplicating SDK surfaces.
        active?.takeIf { it.activity === activity && it.client === client }?.showCurrentTarget()
            ?: MessengerDialog(activity, client, options) { closed -> if (active === closed) active = null }
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

internal data class MessengerSurfaceVisibility(
    val faq: Boolean,
    val helpCenter: Boolean,
)

internal fun messengerSurfaceVisibility(
    faqEnabled: Boolean,
    validFaqCount: Int,
    helpCenterTopicCount: Int?,
): MessengerSurfaceVisibility = MessengerSurfaceVisibility(
    faq = faqEnabled && validFaqCount > 0,
    helpCenter = helpCenterTopicCount?.let { it > 0 } == true,
)

internal fun messengerUsesDarkPalette(
    serverDarkEnabled: Boolean,
    systemDarkMode: Boolean,
): Boolean = serverDarkEnabled && systemDarkMode

internal enum class MessengerBackAction { DISMISS, RETURN_HOME }

internal fun messengerBackAction(isHome: Boolean): MessengerBackAction =
    if (isHome) MessengerBackAction.DISMISS else MessengerBackAction.RETURN_HOME

internal enum class MessengerMessageAlignment { START, END }

internal fun messengerMessageAlignment(role: String): MessengerMessageAlignment =
    if (role.equals("user", ignoreCase = true)) {
        MessengerMessageAlignment.END
    } else {
        MessengerMessageAlignment.START
    }

internal data class ComposerInsertion(val text: String, val cursorOffset: Int = text.length)

internal fun codeComposerInsertion(selectedText: String): ComposerInsertion = if (selectedText.isEmpty()) {
    ComposerInsertion(text = "```\n\n```", cursorOffset = 4)
} else {
    ComposerInsertion(text = "```\n$selectedText\n```")
}

internal fun markdownLinkComposerInsertion(label: String, url: String): String =
    "[${label.trim().ifEmpty { url.trim() }}](${url.trim()})"

/** Kept internal so framework bridges cannot gain a headless transcript or composer API. */
internal class MessengerDialog(
    internal val activity: Activity,
    internal val client: OnloClient,
    internal val options: OnloMessengerOptions,
    private val onClosed: (MessengerDialog) -> Unit,
) : Dialog(activity, android.R.style.Theme_Material_Light_NoActionBar) {
    private enum class Surface { HOME, CONVERSATIONS, FAQ, HELP_CENTER }

    private val uiScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var stateJob: Job? = null
    private var activeConversationId: String? = null
    private var activeSessionId: String? = null
    private val pendingAttachments = mutableListOf<OnloClient.PendingNativeAttachment>()
    private lateinit var title: TextView
    private lateinit var status: TextView
    private lateinit var body: LinearLayout
    private lateinit var scroll: ScrollView
    private lateinit var composer: EditText
    private lateinit var send: Button
    private lateinit var voice: Button
    private lateinit var attach: Button
    private lateinit var code: Button
    private lateinit var link: Button
    private lateinit var speaker: Button
    private lateinit var composerRow: LinearLayout
    private lateinit var windowContainer: FrameLayout
    private lateinit var root: LinearLayout
    private lateinit var header: LinearLayout
    private lateinit var headerAvatar: ImageView
    private lateinit var headerInitials: TextView
    private lateinit var headerName: TextView
    private lateinit var headerSubtitle: TextView
    private lateinit var headerStatusDot: View
    private lateinit var back: Button
    private lateinit var refresh: Button
    private lateinit var footer: LinearLayout
    private lateinit var footerPrefix: TextView
    private lateinit var footerName: TextView
    private lateinit var footerMark: OnloMarkView
    private var activeSurface = Surface.HOME
    private var lastInbox: List<ai.onlo.sdk.chat.ConversationSummary> = emptyList()
    private var helpCenterTopics: List<HelpCenterTopic>? = null
    private var helpCenterAvailabilityLoading = false
    private val streamedReplies = mutableMapOf<String, TextView>()
    private val typingIndicators = mutableMapOf<String, TypingIndicatorView>()
    private var showingEmptyState = false
    private var speechRecognizer: SpeechRecognizer? = null
    private var textToSpeech: TextToSpeech? = null
    private var isListening = false
    private var speaksReplies = false
    private var composerBusy = false
    private var skeletonAnimator: ObjectAnimator? = null
    private var platformConnected = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        setContentView(buildContent())
        setCanceledOnTouchOutside(options.presentationMode == OnloMessengerPresentationMode.CONTAINED)
        setOnCancelListener { client.dismiss() }
        setOnDismissListener {
            stopVoice()
            stopSkeleton()
            clearTypingIndicators()
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
            client.platformConnected.collect { connected ->
                platformConnected = connected
                updateConnectionDot()
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
                    updateComposerControls()
                    enforceSurfaceAvailability()
                    if (activeSurface == Surface.HOME) renderHome(lastInbox)
                    refreshHelpCenterAvailability()
                }
            }
        }
    }

    override fun onStart() {
        super.onStart()
        window?.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))
        window?.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE)
        window?.setLayout(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window?.setDecorFitsSystemWindows(false)
        }
        applyAppearance()
        windowContainer.requestApplyInsets()
    }

    @Suppress("DEPRECATION")
    override fun onBackPressed() {
        when (messengerBackAction(activeSurface == Surface.HOME)) {
            MessengerBackAction.DISMISS -> dismissFromHost()
            MessengerBackAction.RETURN_HOME -> navigateBack()
        }
    }

    fun showCurrentTarget() {
        if (!isShowing) show()
        enforceSurfaceAvailability()
        refreshHelpCenterAvailability()
        when (val target = client.presentationTarget.value) {
            MessengerPresentationTarget.Inbox -> loadInbox(Surface.HOME)
            is MessengerPresentationTarget.Conversation -> loadConversation(target.conversationId)
        }
    }

    fun dismissFromHost() {
        client.dismiss()
        if (isShowing) dismiss()
    }

    private fun buildContent(): View {
        windowContainer = FrameLayout(context).apply {
            setBackgroundColor(Color.TRANSPARENT)
            setOnApplyWindowInsetsListener { view, insets ->
                applySystemInsets(view, insets)
                insets
            }
        }
        root = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            background = rounded(Color.WHITE, containerCornerRadius())
            clipToOutline = options.presentationMode == OnloMessengerPresentationMode.CONTAINED
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        }
        header = LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(14), dp(10), dp(10), dp(10))
            setBackgroundColor(Color.WHITE)
        }
        back = chromeButton("‹", "Back").apply {
            visibility = View.GONE
            setOnClickListener { navigateBack() }
        }
        header.addView(back, LinearLayout.LayoutParams(dp(32), dp(36)))
        headerAvatar = ImageView(context).apply {
            contentDescription = "Support avatar"
            scaleType = ImageView.ScaleType.CENTER_CROP
            background = rounded(Color.TRANSPARENT, dp(5))
            clipToOutline = true
            visibility = View.GONE
        }
        headerInitials = TextView(context).apply {
            gravity = Gravity.CENTER
            setTextColor(Color.WHITE)
            textSize = 11f
            background = rounded(Color.rgb(27, 25, 23), dp(5))
            contentDescription = "Support avatar"
        }
        val avatarSize = LinearLayout.LayoutParams(dp(24), dp(24)).apply {
            marginEnd = dp(8)
        }
        header.addView(headerAvatar, avatarSize)
        header.addView(headerInitials, LinearLayout.LayoutParams(dp(24), dp(24)).apply {
            marginEnd = dp(8)
        })
        headerName = TextView(context).apply {
            text = "Support"
            setTextColor(Color.rgb(27, 25, 23))
            textSize = 13f
            setTypeface(typeface, Typeface.BOLD)
            contentDescription = "Onlo support messenger"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
        }
        headerSubtitle = TextView(context).apply {
            setTextColor(Color.rgb(100, 100, 100))
            textSize = 11f
        }
        headerStatusDot = View(context).apply {
            contentDescription = "Onlo connection status"
        }
        val headerStatus = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            addView(headerStatusDot, LinearLayout.LayoutParams(dp(6), dp(6)).apply {
                marginEnd = dp(5)
            })
            addView(headerSubtitle)
        }
        val headerLabels = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            addView(headerName)
            addView(headerStatus)
        }
        title = headerName
        refresh = chromeButton("↻", "Refresh support").apply {
            setOnClickListener { refreshCurrentSurface() }
        }
        val close = chromeButton("×", "Close support messenger").apply {
            contentDescription = "Close support messenger"
            setOnClickListener { dismissFromHost() }
        }
        header.addView(headerLabels, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        speaker = chromeButton("◖", "Speak completed support replies").apply {
            contentDescription = "Speak completed support replies"
            visibility = View.GONE
            setOnClickListener {
                speaksReplies = !speaksReplies
                updateVoiceControls()
                announce(if (speaksReplies) "Spoken replies enabled." else "Spoken replies disabled.")
            }
        }
        header.addView(speaker)
        header.addView(refresh, LinearLayout.LayoutParams(dp(36), dp(36)))
        header.addView(close, LinearLayout.LayoutParams(dp(36), dp(36)))
        root.addView(header)
        root.addView(divider())

        status = TextView(context).apply {
            setPadding(dp(16), dp(8), dp(16), dp(8))
            textSize = 14f
            visibility = View.GONE
            accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
            contentDescription = "Messenger status"
        }
        root.addView(status)

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
            setPadding(dp(12), dp(8), dp(8), dp(8))
        }
        composer = EditText(context).apply {
            hint = "Write a message"
            contentDescription = "Message support"
            minLines = 1
            maxLines = 5
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 13.5f)
            setPadding(0, dp(3), 0, dp(3))
            inputType = InputType.TYPE_CLASS_TEXT or
                InputType.TYPE_TEXT_FLAG_CAP_SENTENCES or
                InputType.TYPE_TEXT_FLAG_MULTI_LINE
            background = null
            addTextChangedListener(object : TextWatcher {
                override fun beforeTextChanged(value: CharSequence?, start: Int, count: Int, after: Int) = Unit
                override fun onTextChanged(value: CharSequence?, start: Int, before: Int, count: Int) {
                    updateComposerControls()
                }
                override fun afterTextChanged(value: Editable?) = Unit
            })
        }
        send = iconButton("➤", "Send message").apply {
            contentDescription = "Send message"
            setTextColor(Color.WHITE)
            background = rounded(Color.rgb(27, 25, 23), dp(6))
            setOnClickListener { enqueueComposer() }
        }
        voice = iconButton("●", "Start voice input").apply {
            contentDescription = "Start voice input"
            visibility = View.GONE
            setOnClickListener { toggleVoiceInput() }
        }
        attach = iconButton("📎", "Add image").apply {
            contentDescription = "Add image"
            setOnClickListener { chooseImageSource() }
        }
        code = iconButton("‹›", "Insert code").apply {
            contentDescription = "Insert code"
            setOnClickListener { insertCode() }
        }
        link = iconButton("🔗", "Insert link").apply {
            contentDescription = "Insert link"
            setOnClickListener { insertLink() }
        }
        composerRow.addView(composer, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
        composerRow.addView(voice, LinearLayout.LayoutParams(dp(28), dp(28)))
        composerRow.addView(attach, LinearLayout.LayoutParams(dp(28), dp(28)))
        composerRow.addView(code, LinearLayout.LayoutParams(dp(28), dp(28)))
        composerRow.addView(link, LinearLayout.LayoutParams(dp(28), dp(28)))
        composerRow.addView(send, LinearLayout.LayoutParams(dp(28), dp(28)))
        root.addView(divider())
        root.addView(composerRow, LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT).apply {
            setMargins(dp(14), dp(12), dp(14), dp(12))
        })
        footerPrefix = TextView(context).apply {
            text = "Powered by"
            textSize = 10.5f
        }
        footerMark = OnloMarkView(context)
        footerName = TextView(context).apply {
            text = "Onlo"
            textSize = 10.5f
            setTypeface(typeface, Typeface.BOLD)
        }
        footer = LinearLayout(context).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
            setPadding(dp(12), dp(8), dp(12), dp(8))
            contentDescription = "Powered by Onlo"
            addView(footerPrefix)
            addView(footerMark, LinearLayout.LayoutParams(dp(11), dp(11)).apply {
                marginStart = dp(5)
                marginEnd = dp(2)
            })
            addView(footerName)
        }
        root.addView(divider())
        root.addView(footer)
        applyAppearance()
        updateVoiceControls()
        updateAttachmentControl()
        updateComposerControls()
        enforceSurfaceAvailability()
        windowContainer.addView(
            root,
            FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
                Gravity.CENTER,
            ),
        )
        return windowContainer
    }

    private fun applySystemInsets(view: View, insets: WindowInsets) {
        val left: Int
        val top: Int
        val right: Int
        val bottom: Int
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val systemBars = insets.getInsets(WindowInsets.Type.systemBars())
            left = systemBars.left
            top = systemBars.top
            right = systemBars.right
            bottom = systemBars.bottom
        } else {
            @Suppress("DEPRECATION")
            left = insets.systemWindowInsetLeft
            @Suppress("DEPRECATION")
            top = insets.systemWindowInsetTop
            @Suppress("DEPRECATION")
            right = insets.systemWindowInsetRight
            @Suppress("DEPRECATION")
            bottom = insets.systemWindowInsetBottom
        }
        val containedMargin = if (
            options.presentationMode == OnloMessengerPresentationMode.CONTAINED
        ) dp(14) else 0
        val availableWidth = (view.width.takeIf { it > 0 }
            ?: context.resources.displayMetrics.widthPixels) - left - right - (containedMargin * 2)
        val width = if (options.presentationMode == OnloMessengerPresentationMode.CONTAINED) {
            availableWidth.coerceAtMost(dp(520)).coerceAtLeast(dp(280))
        } else {
            ViewGroup.LayoutParams.MATCH_PARENT
        }
        root.layoutParams = FrameLayout.LayoutParams(
            width,
            ViewGroup.LayoutParams.MATCH_PARENT,
            Gravity.CENTER,
        ).apply {
            leftMargin = left + containedMargin
            topMargin = top + containedMargin
            rightMargin = right + containedMargin
            bottomMargin = bottom + containedMargin
        }
    }

    private fun containerCornerRadius(): Int = if (
        options.presentationMode == OnloMessengerPresentationMode.CONTAINED
    ) dp(16) else 0

    private fun loadInbox(destination: Surface = Surface.HOME) {
        clearTypingIndicators()
        activeSurface = destination
        updateChrome()
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
            if (activeSurface != destination) return@launch
            when (result) {
                is MessengerInboxResult.Ready -> {
                    lastInbox = result.conversations
                    if (destination == Surface.HOME) renderHome(result.conversations)
                    else renderInbox(result.conversations)
                }
                is MessengerInboxResult.Stale -> {
                    lastInbox = result.conversations
                    if (destination == Surface.HOME) renderHome(result.conversations)
                    else renderInbox(result.conversations)
                    showStatus("Offline. Showing saved conversations.")
                }
                MessengerInboxResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerInboxResult.Unavailable -> renderUnavailable("Offline. No saved conversations are available yet.")
            }
        }
    }

    private fun loadConversation(conversationId: String, showLoading: Boolean = true) {
        activeSurface = Surface.CONVERSATIONS
        updateChrome()
        activeConversationId = conversationId
        title.text = client.mobileConfig?.value?.config?.appearance?.botName ?: "Support"
        applyAppearance()
        updateVoiceControls()
        composerRow.visibility = View.VISIBLE
        composer.visibility = View.VISIBLE
        send.visibility = View.VISIBLE
        if (showLoading) renderLoading("Loading conversation")
        uiScope.launch {
            val result = client.loadMessengerTranscript(conversationId)
            if (activeSurface != Surface.CONVERSATIONS || activeConversationId != conversationId) return@launch
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
                MessengerTranscriptResult.Unavailable -> {
                    if (showLoading) renderUnavailable("Offline. Conversation refresh is unavailable.")
                    else showStatus("Offline. Showing current conversation.")
                }
            }
        }
    }

    private fun enqueueComposer() {
        val message = composer.text?.toString()?.trim().orEmpty()
        if (message.isEmpty() && pendingAttachments.isEmpty()) {
            announce("Enter a message before sending.")
            return
        }
        if (activeSurface != Surface.CONVERSATIONS) {
            activeConversationId = null
            activeSessionId = null
        }
        composerBusy = true
        updateComposerControls()
        activeSurface = Surface.CONVERSATIONS
        updateChrome()
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
                    appendMessage(liveMessage(message, outgoing = true))
                    removeTypingIndicator(clientMessageId)
                    streamedReplies.remove(clientMessageId)
                }
                announce("Message queued for delivery.")
            } catch (_: IllegalArgumentException) {
                announce("Message could not be queued.")
            } catch (_: IllegalStateException) {
                announce("Support is not ready. Try again shortly.")
            } finally {
                composerBusy = false
                updateComposerControls()
            }
        }
    }

    private fun insertCode() {
        val start = composer.selectionStart.coerceAtLeast(0)
        val end = composer.selectionEnd.coerceAtLeast(start)
        val selected = composer.text.substring(start, end)
        val insertion = codeComposerInsertion(selected)
        composer.text.replace(start, end, insertion.text)
        composer.setSelection((start + insertion.cursorOffset).coerceAtMost(composer.text.length))
        composer.requestFocus()
    }

    private fun insertLink() {
        val start = composer.selectionStart.coerceAtLeast(0)
        val end = composer.selectionEnd.coerceAtLeast(start)
        val selected = composer.text.substring(start, end)
        val labelInput = EditText(context).apply {
            hint = "Link text"
            setText(selected)
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
        }
        val urlInput = EditText(context).apply {
            hint = "https://…"
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_URI
        }
        val fields = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), 0, dp(20), 0)
            addView(labelInput)
            addView(urlInput)
        }
        AlertDialog.Builder(activity)
            .setTitle("Insert link")
            .setView(fields)
            .setNegativeButton("Cancel", null)
            .setPositiveButton("Insert") { _, _ ->
                val url = urlInput.text.toString().trim()
                if (url.isNotEmpty()) {
                    val insertion = markdownLinkComposerInsertion(labelInput.text.toString(), url)
                    composer.text.replace(start, end, insertion)
                    composer.setSelection((start + insertion.length).coerceAtMost(composer.text.length))
                    composer.requestFocus()
                }
            }
            .show()
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
        attach.text = if (pendingAttachments.isEmpty()) "📎" else pendingAttachments.size.toString()
        updateComposerControls()
    }

    private fun updateComposerControls() {
        if (!::composer.isInitialized || !::send.isInitialized || !::code.isInitialized || !::link.isInitialized) return
        val features = client.mobileConfig?.value?.config?.features
        code.visibility = if (features?.insertCode == true) View.VISIBLE else View.GONE
        link.visibility = if (features?.insertLink == true) View.VISIBLE else View.GONE
        code.isEnabled = !composerBusy
        link.isEnabled = !composerBusy
        composer.isEnabled = !composerBusy
        send.isEnabled = !composerBusy &&
            (composer.text.toString().trim().isNotEmpty() || pendingAttachments.isNotEmpty())
        val foreground = incomingTextColor()
        send.setTextColor(if (send.isEnabled) Color.WHITE else withAlpha(foreground, 0.35f))
        send.background = rounded(
            if (send.isEnabled) accentColor() else withAlpha(foreground, 0.1f),
            dp(6),
        )
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
        val visibility = currentSurfaceVisibility()
        if (surface == Surface.FAQ && !visibility.faq) return
        if (surface != Surface.CONVERSATIONS) stopVoice()
        if (surface != Surface.CONVERSATIONS) clearTypingIndicators()
        activeSurface = surface
        composerRow.visibility = View.VISIBLE
        updateChrome()
        updateVoiceControls()
        when (surface) {
            Surface.HOME -> loadInbox(Surface.HOME)
            Surface.CONVERSATIONS -> loadInbox(Surface.CONVERSATIONS)
            Surface.FAQ -> renderFaqs()
            Surface.HELP_CENTER -> loadHelpCenter()
        }
    }

    private fun renderHome(conversations: List<ai.onlo.sdk.chat.ConversationSummary>) {
        stopSkeleton()
        body.removeAllViews()
        showingEmptyState = false
        hideStatus()

        val firstName = client.identifiedFirstName
        body.addView(TextView(context).apply {
            text = firstName?.let { "Hi $it 👋" } ?: "Hi there 👋"
            textSize = 22f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(incomingTextColor())
        })
        body.addView(TextView(context).apply {
            text = if (firstName != null && conversations.isNotEmpty()) {
                "Pick up where you left off, or ask something new."
            } else {
                cleanedGreeting()
            }
            textSize = 14f
            setTextColor(withAlpha(incomingTextColor(), 0.65f))
            setPadding(0, dp(2), 0, dp(18))
        })

        if (conversations.isNotEmpty()) {
            body.addView(divider())
            body.addView(sectionHeader("Recent conversations", "See all →") {
                loadInbox(Surface.CONVERSATIONS)
            })
            conversations.take(3).forEach { conversation ->
                body.addView(conversationRow(conversation))
            }
        }

        val questions = configuredQuestions()
        if (questions.isNotEmpty()) {
            body.addView(divider())
            body.addView(sectionHeader("Quick questions", "Browse all →") {
                selectSurface(Surface.HELP_CENTER)
            })
            questions.take(3).forEach { faq -> body.addView(questionRow(faq)) }
        } else if (!helpCenterTopics.isNullOrEmpty()) {
            body.addView(divider())
            body.addView(questionRow("Browse the help center") { selectSurface(Surface.HELP_CENTER) })
        }
    }

    private fun sectionHeader(title: String, action: String?, onAction: () -> Unit): View =
        LinearLayout(context).apply {
            layoutParams = LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(10), 0, dp(4))
            addView(TextView(context).apply {
                text = title.uppercase(Locale.getDefault())
                textSize = 10f
                setTypeface(typeface, Typeface.BOLD)
                setTextColor(withAlpha(incomingTextColor(), 0.55f))
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            if (action != null) {
                addView(Button(context).apply {
                    text = action
                    textSize = 11f
                    setAllCaps(false)
                    setTextColor(withAlpha(incomingTextColor(), 0.65f))
                    background = null
                    minHeight = 0
                    minimumHeight = 0
                    setPadding(dp(4), dp(2), dp(4), dp(2))
                    setOnClickListener { onAction() }
                })
            }
        }

    private fun conversationRow(conversation: ai.onlo.sdk.chat.ConversationSummary): View =
        LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            setPadding(dp(8), dp(9), dp(8), dp(9))
            contentDescription = buildString {
                append("Conversation: ").append(conversation.title.ifBlank { "Support conversation" })
                if (conversation.unreadCount > 0) append(", ${conversation.unreadCount} unread")
            }
            val dot = TextView(context).apply {
                text = if (conversation.unreadCount > 0) "●" else ""
                textSize = 8f
                setTextColor(accentColor())
            }
            addView(dot, LinearLayout.LayoutParams(dp(14), ViewGroup.LayoutParams.WRAP_CONTENT))
            addView(TextView(context).apply {
                text = conversation.title.ifBlank { "Support conversation" }
                textSize = 12.5f
                setTextColor(incomingTextColor())
                if (conversation.unreadCount > 0) setTypeface(typeface, Typeface.BOLD)
                maxLines = 1
                ellipsize = android.text.TextUtils.TruncateAt.END
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply {
                text = relativeTime(conversation.updatedAt)
                textSize = 10.5f
                setTextColor(withAlpha(incomingTextColor(), 0.5f))
            })
            setOnClickListener { loadConversation(conversation.id) }
        }

    private fun questionRow(faq: MobileConfig.Faq): View = questionRow(faq.question) { openFaq(faq) }

    private fun questionRow(question: String, action: () -> Unit): View =
        LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            setPadding(dp(8), dp(9), dp(8), dp(9))
            contentDescription = question
            addView(TextView(context).apply {
                text = question
                textSize = 12.5f
                setTextColor(incomingTextColor())
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply {
                text = "→"
                textSize = 12f
                setTextColor(withAlpha(incomingTextColor(), 0.55f))
            })
            setOnClickListener { action() }
        }

    private fun surfaceHeading(value: String): TextView = TextView(context).apply {
        text = value.uppercase(Locale.getDefault())
        textSize = 10f
        setTypeface(typeface, Typeface.BOLD)
        setTextColor(withAlpha(incomingTextColor(), 0.55f))
        setPadding(dp(4), dp(2), dp(4), dp(12))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
    }

    private fun emptyState(title: String, detail: String): View =
        LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(dp(18), dp(28), dp(18), dp(28))
            addView(TextView(context).apply {
                text = title
                textSize = 13.5f
                setTypeface(typeface, Typeface.BOLD)
                gravity = Gravity.CENTER
                setTextColor(incomingTextColor())
            })
            addView(TextView(context).apply {
                text = detail
                textSize = 12.5f
                gravity = Gravity.CENTER
                setTextColor(withAlpha(incomingTextColor(), 0.65f))
                setPadding(0, dp(4), 0, 0)
            })
        }

    private fun helpTopicRow(topic: HelpCenterTopic, action: () -> Unit): View =
        LinearLayout(context).apply {
            gravity = Gravity.CENTER_VERTICAL
            isClickable = true
            isFocusable = true
            setPadding(dp(8), dp(9), dp(8), dp(9))
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "${topic.name}, ${topic.count} articles"
            addView(TextView(context).apply {
                text = "▤"
                textSize = 12f
                gravity = Gravity.CENTER
                setTextColor(withAlpha(incomingTextColor(), 0.6f))
            }, LinearLayout.LayoutParams(dp(28), dp(28)).apply { marginEnd = dp(8) })
            addView(LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                addView(TextView(context).apply {
                    text = topic.name
                    textSize = 12.5f
                    setTextColor(incomingTextColor())
                    setTypeface(typeface, Typeface.BOLD)
                })
                addView(TextView(context).apply {
                    text = "${topic.count} ${if (topic.count == 1) "article" else "articles"}"
                    textSize = 10.5f
                    setTextColor(withAlpha(incomingTextColor(), 0.55f))
                })
            }, LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f))
            addView(TextView(context).apply {
                text = "→"
                textSize = 12f
                setTextColor(withAlpha(incomingTextColor(), 0.55f))
            })
            setOnClickListener { action() }
        }

    private fun openFaq(faq: MobileConfig.Faq) {
        if (!faq.answer.isNullOrBlank()) {
            activeSurface = Surface.FAQ
            updateChrome()
            renderFaqAnswer(faq)
            return
        }
        activeConversationId = null
        activeSessionId = null
        composer.setText(faq.question)
        enqueueComposer()
    }

    private fun navigateBack() {
        when {
            activeSurface == Surface.CONVERSATIONS && activeConversationId != null -> loadInbox(Surface.HOME)
            activeSurface == Surface.HELP_CENTER -> loadInbox(Surface.HOME)
            activeSurface == Surface.FAQ -> loadInbox(Surface.HOME)
            activeSurface == Surface.CONVERSATIONS -> loadInbox(Surface.HOME)
        }
    }

    private fun refreshCurrentSurface() {
        when {
            activeSurface == Surface.CONVERSATIONS && activeConversationId != null -> loadConversation(checkNotNull(activeConversationId))
            activeSurface == Surface.CONVERSATIONS -> loadInbox(Surface.CONVERSATIONS)
            activeSurface == Surface.FAQ -> renderFaqs()
            activeSurface == Surface.HELP_CENTER -> loadHelpCenter()
            else -> loadInbox(Surface.HOME)
        }
    }

    private fun updateChrome() {
        if (!::back.isInitialized) return
        back.visibility = if (activeSurface == Surface.HOME) View.GONE else View.VISIBLE
        speaker.visibility = if (voiceEnabled() && activeSurface == Surface.CONVERSATIONS && activeConversationId != null) View.VISIBLE else View.GONE
    }

    private fun renderFaqs() {
        stopSkeleton()
        body.removeAllViews()
        hideStatus()
        val faqs = configuredQuestions()
        if (faqs.isEmpty()) {
            loadInbox(Surface.HOME)
            return
        }
        faqs.forEach { faq ->
            body.addView(
                Button(context).apply {
                    text = faq.question
                    setAllCaps(false)
                    contentDescription = faq.question
                    setOnClickListener { openFaq(faq) }
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(8) },
            )
        }
    }

    private fun renderFaqAnswer(faq: MobileConfig.Faq) {
        stopSkeleton()
        body.removeAllViews()
        body.addView(TextView(context).apply {
            text = "FAQ"
            textSize = 10f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(withAlpha(incomingTextColor(), 0.55f))
            setPadding(0, dp(2), 0, dp(6))
        })
        body.addView(TextView(context).apply {
            text = faq.question
            textSize = 18f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(incomingTextColor())
            setPadding(0, 0, 0, dp(8))
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) isAccessibilityHeading = true
        })
        body.addView(TextView(context).apply {
            text = faq.answer.orEmpty()
            textSize = 14f
            setTextColor(incomingTextColor())
        })
    }

    private fun loadHelpCenter() {
        helpCenterTopics?.let {
            renderHelpTopics(it)
            return
        }
        renderLoading("Loading Help Center")
        uiScope.launch {
            val result = client.loadMessengerHelpCenter()
            if (activeSurface != Surface.HELP_CENTER) return@launch
            when (result) {
                is MessengerHelpCenterResult.Ready -> {
                    helpCenterTopics = result.topics
                    enforceSurfaceAvailability()
                    renderHelpTopics(result.topics)
                }
                MessengerHelpCenterResult.NoActiveSession -> renderUnavailable("Session changed. Reopen support to continue.")
                MessengerHelpCenterResult.Unavailable -> renderUnavailable("Help Center is temporarily unavailable.")
            }
        }
    }

    private fun renderHelpTopics(topics: List<ai.onlo.sdk.chat.HelpCenterTopic>) {
        stopSkeleton()
        body.removeAllViews()
        hideStatus()
        body.addView(surfaceHeading("Help center"))
        if (topics.isEmpty()) {
            body.addView(emptyState(
                title = "No articles yet",
                detail = "Articles will appear here once your team publishes them.",
            ))
            return
        }
        topics.forEach { topic ->
            body.addView(helpTopicRow(topic) { renderHelpArticles(topic, topics) })
        }
    }

    private fun configuredQuestions(): List<MobileConfig.Faq> {
        val config = client.mobileConfig?.value?.config ?: return emptyList()
        if (!config.features.faqButton.enabled) return emptyList()
        return config.content.faqs.filter { it.question.isNotBlank() }
    }

    private fun currentSurfaceVisibility(): MessengerSurfaceVisibility {
        val config = client.mobileConfig?.value?.config
        return messengerSurfaceVisibility(
            faqEnabled = config?.features?.faqButton?.enabled == true,
            validFaqCount = configuredQuestions().size,
            helpCenterTopicCount = helpCenterTopics?.size,
        )
    }

    private fun enforceSurfaceAvailability() {
        val visibility = currentSurfaceVisibility()
        if (activeSurface == Surface.FAQ && !visibility.faq) {
            loadInbox(Surface.HOME)
        }
    }

    private fun refreshHelpCenterAvailability() {
        if (helpCenterAvailabilityLoading) return
        helpCenterAvailabilityLoading = true
        uiScope.launch {
            when (val result = client.loadMessengerHelpCenter()) {
                is MessengerHelpCenterResult.Ready -> helpCenterTopics = result.topics
                MessengerHelpCenterResult.NoActiveSession,
                MessengerHelpCenterResult.Unavailable,
                -> Unit
            }
            helpCenterAvailabilityLoading = false
            enforceSurfaceAvailability()
            if (activeSurface == Surface.HOME) renderHome(lastInbox)
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
                    stopSkeleton()
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
                if (event.duplicate) {
                    removeTypingIndicator(event.clientMessageId)
                    loadConversation(event.conversationId, showLoading = false)
                } else {
                    showTypingIndicator(event.clientMessageId)
                }
            }
            is NativeMessengerEvent.Text -> {
                removeTypingIndicator(event.clientMessageId)
                val reply = streamedReplies.getOrPut(event.clientMessageId) {
                    liveMessage("", outgoing = false).also(::appendMessage)
                }
                reply.append(event.content)
                scrollToBottom()
            }
            is NativeMessengerEvent.Done -> {
                removeTypingIndicator(event.clientMessageId)
                val completedReply = streamedReplies.remove(event.clientMessageId)?.text?.toString()
                if (speaksReplies && !completedReply.isNullOrBlank()) {
                    speakCompletedReply(completedReply)
                }
                loadConversation(event.conversationId, showLoading = false)
            }
            is NativeMessengerEvent.Failed -> {
                removeTypingIndicator(event.clientMessageId)
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
        stopSkeleton()
        if (activeConversationId == null || showingEmptyState) {
            body.removeAllViews()
            showingEmptyState = false
        }
        val outgoing = view.tag == MESSAGE_OUTGOING
        val row = LinearLayout(context).apply {
            gravity = if (outgoing) Gravity.END else Gravity.START
            addView(
                view,
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        body.addView(
            row,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(8) },
        )
        scrollToBottom()
    }

    private fun showTypingIndicator(clientMessageId: String) {
        removeTypingIndicator(clientMessageId)
        if (activeConversationId == null || showingEmptyState) {
            body.removeAllViews()
            showingEmptyState = false
        }
        val indicator = TypingIndicatorView(
            context,
            withAlpha(incomingTextColor(), 0.55f),
        )
        typingIndicators[clientMessageId] = indicator
        body.addView(
            indicator,
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { bottomMargin = dp(8) },
        )
        scrollToBottom()
    }

    private fun removeTypingIndicator(clientMessageId: String) {
        val indicator = typingIndicators.remove(clientMessageId) ?: return
        indicator.stop()
        (indicator.parent as? ViewGroup)?.removeView(indicator)
    }

    private fun clearTypingIndicators() {
        typingIndicators.values.forEach(TypingIndicatorView::stop)
        typingIndicators.clear()
    }

    private fun scrollToBottom() {
        scroll.post { scroll.fullScroll(View.FOCUS_DOWN) }
    }

    private fun renderInbox(conversations: List<ai.onlo.sdk.chat.ConversationSummary>) {
        stopSkeleton()
        body.removeAllViews()
        body.addView(surfaceHeading("Conversations"))
        if (conversations.isEmpty()) {
            showingEmptyState = true
            body.addView(emptyState(
                title = "No conversations yet",
                detail = "Start one by typing below.",
            ))
            hideStatus()
            return
        }
        showingEmptyState = false
        hideStatus()
        conversations.forEach { conversation ->
            body.addView(conversationRow(conversation))
        }
    }

    private fun renderTranscript(transcript: ai.onlo.sdk.chat.ConversationDetail) {
        stopSkeleton()
        clearTypingIndicators()
        streamedReplies.clear()
        showingEmptyState = false
        body.removeAllViews()
        hideStatus()
        if (transcript.messages.isEmpty()) body.addView(label("No messages yet."))
        transcript.messages.forEach { message ->
            body.addView(
                transcriptMessage(message),
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { bottomMargin = dp(12) },
            )
        }
        if (transcript.isHumanTakeover) announce("A support team member is handling this conversation.")
    }

    private fun transcriptMessage(message: ai.onlo.sdk.chat.TranscriptMessage): View {
        val alignment = messengerMessageAlignment(message.role)
        val mine = alignment == MessengerMessageAlignment.END
        val childGravity = if (mine) Gravity.END else Gravity.START
        val row = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = childGravity
            contentDescription = if (mine) "Your message" else "Support message"
        }
        val author = if (mine) {
            "You"
        } else {
            message.senderName?.takeIf { it.isNotBlank() }
                ?: client.mobileConfig?.value?.config?.appearance?.botName?.takeIf { it.isNotBlank() }
                ?: "Support"
        }
        val time = if (client.mobileConfig?.value?.config?.features?.showTimestamps != false) {
            formatMessageTime(message.timestamp)
        } else {
            ""
        }
        val team = if (mine) "" else message.senderTeam?.trim().orEmpty()
        val metaText = if (mine) {
            listOf(time, author).filter(String::isNotEmpty).joinToString("  ")
        } else {
            listOf(author, team, time).filter(String::isNotEmpty).joinToString("  ")
        }
        if (metaText.isNotEmpty()) {
            row.addView(
                TextView(context).apply {
                    text = metaText
                    setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 11f)
                    setTextColor(withAlpha(incomingTextColor(), 0.5f))
                    setPadding(dp(4), 0, dp(4), dp(4))
                    includeFontPadding = false
                    paint.isSubpixelText = true
                },
                LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ).apply { gravity = childGravity },
            )
        }
        row.addView(
            TextView(context).apply {
                tag = if (mine) MESSAGE_OUTGOING else MESSAGE_INCOMING
                text = message.text
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 15f)
                setTextColor(if (mine) outgoingTextColor() else incomingTextColor())
                setPadding(dp(12), dp(8), dp(12), dp(8))
                background = messageBubble(mine)
                maxWidth = ((if (body.width > 0) body.width else context.resources.displayMetrics.widthPixels) * 0.78f).toInt()
                includeFontPadding = false
                setLineSpacing(dp(2).toFloat(), 1f)
                paint.isSubpixelText = true
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    breakStrategy = android.text.Layout.BREAK_STRATEGY_HIGH_QUALITY
                    hyphenationFrequency = android.text.Layout.HYPHENATION_FREQUENCY_NORMAL
                }
            },
            LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT,
            ).apply { gravity = childGravity },
        )
        return row
    }

    private fun formatMessageTime(timestamp: Long): String {
        if (timestamp <= 0L) return ""
        return SimpleDateFormat("h:mm a", Locale.getDefault()).format(java.util.Date(timestamp))
    }

    private fun renderLoading(label: String) {
        showingEmptyState = false
        stopSkeleton()
        body.removeAllViews()
        hideStatus()
        val skeleton = skeletonFor(label)
        body.addView(skeleton)
        skeletonAnimator = ObjectAnimator.ofFloat(skeleton, View.ALPHA, 0.42f, 1f).apply {
            duration = 700
            repeatMode = ValueAnimator.REVERSE
            repeatCount = ValueAnimator.INFINITE
            start()
        }
    }

    private fun skeletonFor(label: String): LinearLayout = LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        contentDescription = label
        importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        val color = withAlpha(incomingTextColor(), 0.11f)
        fun bar(width: Int, height: Int, gravity: Int = Gravity.START): View = View(context).apply {
            background = rounded(color, dp(4))
            layoutParams = LinearLayout.LayoutParams(dp(width), dp(height)).apply {
                this.gravity = gravity
                bottomMargin = dp(7)
            }
        }
        if (label.contains("conversation", ignoreCase = true)) {
            addView(bar(170, 11))
            addView(bar(220, 11))
            addView(bar(155, 11, Gravity.END))
            addView(bar(110, 11, Gravity.END))
            addView(bar(190, 11))
            addView(bar(135, 11))
        } else if (label.contains("article", ignoreCase = true)) {
            addView(bar(72, 9))
            addView(bar(220, 17))
            addView(bar(290, 11))
            addView(bar(260, 11))
            addView(bar(285, 11))
            addView(bar(190, 11))
        } else {
            addView(bar(175, 18))
            addView(bar(270, 11))
            addView(View(context), LinearLayout.LayoutParams(1, dp(14)))
            repeat(3) {
                addView(bar(if (it == 0) 230 else 275, 11))
                addView(bar(if (it == 0) 285 else 240, 9))
            }
        }
    }

    private fun stopSkeleton() {
        skeletonAnimator?.cancel()
        skeletonAnimator = null
    }

    private fun renderUnavailable(message: String) {
        showingEmptyState = false
        stopSkeleton()
        body.removeAllViews()
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
        background = messageBubble(outgoing)
        contentDescription = if (outgoing) "Your message" else "Support message"
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
    }

    private fun liveMessage(value: String, outgoing: Boolean): TextView = TextView(context).apply {
        tag = if (outgoing) MESSAGE_OUTGOING else MESSAGE_INCOMING
        text = value
        setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 15f)
        setTextColor(if (outgoing) outgoingTextColor() else incomingTextColor())
        setPadding(dp(12), dp(8), dp(12), dp(8))
        background = messageBubble(outgoing)
        maxWidth = ((if (body.width > 0) body.width else context.resources.displayMetrics.widthPixels) * 0.78f).toInt()
        includeFontPadding = false
        setLineSpacing(dp(2).toFloat(), 1f)
        paint.isSubpixelText = true
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
        speaker.visibility = if (available && activeSurface == Surface.CONVERSATIONS && activeConversationId != null) View.VISIBLE else View.GONE
        voice.text = if (isListening) "■" else "●"
        voice.contentDescription = if (isListening) "Stop voice input" else "Start voice input"
        speaker.text = if (speaksReplies) "◖̸" else "◖"
        speaker.contentDescription = if (speaksReplies) "Disable spoken replies" else "Enable spoken replies"
    }

    private fun voiceEnabled(): Boolean =
        client.mobileConfig?.value?.config?.features?.voice == true

    private fun applyAppearance() {
        if (!::root.isInitialized || !::header.isInitialized) return
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = usesDarkPalette()
        val background = if (darkMode) appearance?.dark?.background else appearance?.light?.background
        val foreground = incomingTextColor()
        val surface = parseColor(background, if (darkMode) Color.BLACK else Color.WHITE)
        root.background = rounded(surface, containerCornerRadius())
        root.foreground = if (options.presentationMode == OnloMessengerPresentationMode.CONTAINED) {
            outlined(Color.TRANSPARENT, withAlpha(foreground, 0.24f), containerCornerRadius())
        } else null
        status.setTextColor(foreground)
        footerPrefix.setTextColor(withAlpha(foreground, 0.55f))
        footerName.setTextColor(withAlpha(foreground, 0.82f))
        footerMark.markColor = withAlpha(foreground, 0.82f)
        composer.setTextColor(foreground)
        composer.setHintTextColor(Color.argb(160, Color.red(foreground), Color.green(foreground), Color.blue(foreground)))
        composerRow.background = outlined(surface, withAlpha(foreground, 0.14f), dp(8))
        listOf(attach, code, link, voice).forEach { it.setTextColor(withAlpha(foreground, 0.65f)) }
        header.setBackgroundColor(surface)
        window?.statusBarColor = surface
        window?.navigationBarColor = surface
        applySystemBarIconContrast(surface)
        title.text = appearance?.botName?.ifBlank { "Support" } ?: "Support"
        title.setTextColor(foreground)
        headerSubtitle.setTextColor(withAlpha(foreground, 0.65f))
        headerSubtitle.text = appearance?.botSubtitle?.ifBlank { "Typically replies in seconds" }
            ?: "Typically replies in seconds"
        headerSubtitle.visibility = View.VISIBLE
        updateConnectionDot()
        headerInitials.text = appearance?.headerAvatar?.text.orEmpty()
        val avatarBitmap = appearance?.headerAvatar?.data?.let(::decodeDataImage)
        val showsImage = appearance?.headerAvatar?.mode ==
            ai.onlo.sdk.config.MobileConfig.HeaderAvatarMode.IMAGE && avatarBitmap != null
        headerAvatar.visibility = if (showsImage) View.VISIBLE else View.GONE
        headerInitials.visibility = if (showsImage) View.GONE else View.VISIBLE
        headerAvatar.setImageBitmap(avatarBitmap)
        val avatarDescription = appearance?.botName?.ifBlank { "Support" } ?: "Support"
        headerAvatar.contentDescription = "$avatarDescription avatar"
        headerInitials.contentDescription = if (
            appearance?.headerAvatar?.mode == ai.onlo.sdk.config.MobileConfig.HeaderAvatarMode.IMAGE
        ) {
            "$avatarDescription avatar unavailable, showing initials"
        } else {
            "$avatarDescription initials"
        }
        headerInitials.background = rounded(accentColor(), dp(5))
        updateChrome()
        updateComposerControls()
        if (::body.isInitialized) applyMessageAppearance(body)
    }

    private fun applyMessageAppearance(view: View) {
        if (view is TextView) {
            when (view.tag) {
                MESSAGE_OUTGOING -> {
                    view.setTextColor(outgoingTextColor())
                    view.background = messageBubble(outgoing = true)
                }
                MESSAGE_INCOMING -> {
                    view.setTextColor(incomingTextColor())
                    view.background = messageBubble(outgoing = false)
                }
            }
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) applyMessageAppearance(view.getChildAt(index))
        }
    }

    private fun updateConnectionDot() {
        if (!::headerStatusDot.isInitialized) return
        val dotColor = if (platformConnected) Color.rgb(22, 163, 74) else Color.rgb(115, 115, 115)
        headerStatusDot.background = rounded(dotColor, dp(3))
        headerStatusDot.contentDescription = if (platformConnected) {
            "Connected to Onlo"
        } else {
            "Disconnected from Onlo"
        }
    }

    private fun outgoingColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = usesDarkPalette()
        return parseColor(if (darkMode) appearance?.dark?.outgoing else appearance?.light?.outgoing, Color.rgb(20, 89, 140))
    }

    private fun outgoingTextColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = usesDarkPalette()
        return parseColor(if (darkMode) appearance?.dark?.outgoingText else appearance?.light?.outgoingText, Color.WHITE)
    }

    private fun incomingColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = usesDarkPalette()
        return parseColor(if (darkMode) appearance?.dark?.incoming else appearance?.light?.incoming, Color.rgb(239, 241, 243))
    }

    private fun incomingTextColor(): Int {
        val appearance = client.mobileConfig?.value?.config?.appearance
        val darkMode = usesDarkPalette()
        return parseColor(if (darkMode) appearance?.dark?.incomingText else appearance?.light?.incomingText, Color.rgb(25, 25, 25))
    }

    private fun usesDarkPalette(): Boolean {
        val serverDarkEnabled = client.mobileConfig?.value?.config?.appearance?.dark?.enabled == true
        val systemDarkMode = (context.resources.configuration.uiMode and
            Configuration.UI_MODE_NIGHT_MASK) == Configuration.UI_MODE_NIGHT_YES
        return messengerUsesDarkPalette(serverDarkEnabled, systemDarkMode)
    }

    private fun parseColor(value: String?, fallback: Int): Int =
        runCatching { Color.parseColor(value) }.getOrDefault(fallback)

    private fun accentColor(): Int = parseColor(
        client.mobileConfig?.value?.config?.appearance?.accent,
        Color.rgb(27, 25, 23),
    )

    @Suppress("DEPRECATION")
    private fun applySystemBarIconContrast(surface: Int) {
        if (!isShowing) return
        val useDarkIcons = Color.luminance(surface) >= 0.5f
        val dialogWindow = window ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val appearanceMask =
                android.view.WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS or
                    android.view.WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS
            dialogWindow.insetsController?.setSystemBarsAppearance(
                if (useDarkIcons) appearanceMask else 0,
                appearanceMask,
            )
            return
        }
        val darkIconFlags = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR
            } else {
                0
            }
        val current = dialogWindow.decorView.systemUiVisibility
        dialogWindow.decorView.systemUiVisibility = if (useDarkIcons) {
            current or darkIconFlags
        } else {
            current and darkIconFlags.inv()
        }
    }

    private fun withAlpha(color: Int, alpha: Float): Int = Color.argb(
        (255 * alpha.coerceIn(0f, 1f)).toInt(),
        Color.red(color),
        Color.green(color),
        Color.blue(color),
    )

    private fun cleanedGreeting(): String {
        val raw = client.mobileConfig?.value?.config?.appearance?.greeting.orEmpty().trim()
        val cleaned = raw.replace(Regex("^\\s*Hi[^\\n]*?👋\\s*[-—:.,]*\\s*", RegexOption.IGNORE_CASE), "").trim()
        return cleaned.ifBlank { "How can we help?" }
    }

    private fun relativeTime(value: String): String {
        val parsed = listOf("yyyy-MM-dd'T'HH:mm:ss.SSSX", "yyyy-MM-dd'T'HH:mm:ssX")
            .firstNotNullOfOrNull { pattern ->
                runCatching {
                    SimpleDateFormat(pattern, Locale.US).apply { timeZone = TimeZone.getTimeZone("UTC") }.parse(value)
                }.getOrNull()
            } ?: return ""
        val minutes = ((System.currentTimeMillis() - parsed.time).coerceAtLeast(0L) / 60_000L).toInt()
        if (minutes < 1) return "now"
        if (minutes < 60) return "${minutes}m"
        val hours = minutes / 60
        if (hours < 24) return "${hours}h"
        val days = hours / 24
        return if (days < 7) "${days}d" else "${days / 7}w"
    }

    private fun chromeButton(label: String, description: String): Button = Button(context).apply {
        text = label
        textSize = 20f
        contentDescription = description
        setAllCaps(false)
        background = null
        minWidth = 0
        minimumWidth = 0
        minHeight = 0
        minimumHeight = 0
        setPadding(0, 0, 0, 0)
    }

    private fun iconButton(label: String, description: String): Button = chromeButton(label, description).apply {
        textSize = 15f
    }

    private fun divider(): View = View(context).apply {
        setBackgroundColor(Color.argb(24, 27, 25, 23))
        layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(1))
    }

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
    private fun messageBubble(outgoing: Boolean): GradientDrawable = GradientDrawable().apply {
        setColor(if (outgoing) outgoingColor() else incomingColor())
        val large = dp(14).toFloat()
        val small = dp(4).toFloat()
        cornerRadii = if (outgoing) {
            floatArrayOf(large, large, large, large, small, small, large, large)
        } else {
            floatArrayOf(large, large, large, large, large, large, small, small)
        }
    }
    private fun outlined(fill: Int, stroke: Int, radius: Int): GradientDrawable = GradientDrawable().apply {
        setColor(fill)
        setStroke(dp(1), stroke)
        cornerRadius = radius.toFloat()
    }
    private fun dp(value: Int): Int = (value * context.resources.displayMetrics.density).toInt()

    private companion object {
        const val VOICE_PERMISSION_REQUEST = 0x0A10
        const val MESSAGE_OUTGOING = "onlo_message_outgoing"
        const val MESSAGE_INCOMING = "onlo_message_incoming"
    }
}

private class TypingIndicatorView(
    context: android.content.Context,
    dotColor: Int,
) : LinearLayout(context) {
    private val dots = List(3) {
        View(context).apply {
            alpha = 0.5f
            scaleX = 0.8f
            scaleY = 0.8f
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(dotColor)
            }
        }
    }
    private val animators = mutableListOf<ObjectAnimator>()

    init {
        orientation = HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        setPadding(0, dp(4), 0, dp(4))
        contentDescription = "Support is typing"
        accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE
        dots.forEachIndexed { index, dot ->
            addView(
                dot,
                LayoutParams(dp(6), dp(6)).apply {
                    if (index < dots.lastIndex) marginEnd = dp(3)
                },
            )
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        start()
    }

    override fun onDetachedFromWindow() {
        stop()
        super.onDetachedFromWindow()
    }

    fun stop() {
        animators.forEach(ObjectAnimator::cancel)
        animators.clear()
    }

    private fun start() {
        if (animators.isNotEmpty()) return
        dots.forEachIndexed { index, dot ->
            ObjectAnimator.ofPropertyValuesHolder(
                dot,
                PropertyValuesHolder.ofFloat(View.SCALE_X, 0.8f, 1f, 0.8f, 0.8f),
                PropertyValuesHolder.ofFloat(View.SCALE_Y, 0.8f, 1f, 0.8f, 0.8f),
                PropertyValuesHolder.ofFloat(View.ALPHA, 0.5f, 1f, 0.5f, 0.5f),
            ).apply {
                duration = 1_400
                startDelay = index * 160L
                repeatCount = ValueAnimator.INFINITE
                repeatMode = ValueAnimator.RESTART
                start()
                animators += this
            }
        }
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()
}

private class OnloMarkView(context: android.content.Context) : View(context) {
    var markColor: Int = Color.rgb(27, 25, 23)
        set(value) {
            field = value
            invalidate()
        }

    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val size = minOf(width, height).toFloat()
        if (size <= 0f) return
        paint.color = markColor
        paint.strokeWidth = size * 0.16f
        val inset = paint.strokeWidth / 2f
        val oval = RectF(inset, inset, size - inset, size - inset)
        canvas.drawArc(oval, 136f, 151f, false, paint)
        canvas.drawArc(oval, 316f, 151f, false, paint)
    }
}
