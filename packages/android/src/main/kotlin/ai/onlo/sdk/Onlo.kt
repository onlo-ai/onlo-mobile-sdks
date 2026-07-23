package ai.onlo.sdk

import ai.onlo.sdk.logging.AndroidSafeLogger
import ai.onlo.sdk.security.KeystoreCredentialStore
import ai.onlo.sdk.config.KeystoreConfigStore
import ai.onlo.sdk.config.MobileConfigController
import ai.onlo.sdk.storage.SQLiteOutboxStore
import ai.onlo.sdk.transport.OkHttpOnloTransport
import ai.onlo.sdk.transport.OnloSessionApi
import ai.onlo.sdk.transport.ProtocolRequestFactory
import ai.onlo.sdk.chat.WidgetChatApi
import ai.onlo.sdk.chat.ForegroundStream
import ai.onlo.sdk.push.KeystorePushTokenStore
import ai.onlo.sdk.push.PushRegistry
import ai.onlo.sdk.transport.OnloPushApi
import android.content.Context
import okhttp3.HttpUrl.Companion.toHttpUrl
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

/** Application-scoped Onlo SDK entry point. It declares no manifest components. */
public object Onlo {
    private val monitor = Any()
    private var client: OnloClient? = null
    private var lifecycleBinding: NativeLifecycleBinding? = null

    /** Controls structured, PII-free diagnostics for this app process. */
    @JvmStatic
    public fun setLogLevel(level: OnloLogLevel) {
        AndroidSafeLogger.setLevel(level)
    }

    /**
     * Validates local configuration and starts protected-session restoration asynchronously. It
     * never presents UI or requests a permission.
     */
    @JvmStatic
    public fun initialize(
        context: Context,
        sdkKey: String,
    ): OnloClient = initializeInternal(context, sdkKey, PRODUCTION_ORIGIN, ai.onlo.sdk.protocol.SdkFamily.ANDROID)

    /** Used only by the public, fixed-family bridge facades below. */
    internal fun initializeForReactNative(context: Context, sdkKey: String): OnloClient =
        initializeInternal(context, sdkKey, PRODUCTION_ORIGIN, ai.onlo.sdk.protocol.SdkFamily.REACT_NATIVE)

    internal fun initializeForFlutter(context: Context, sdkKey: String): OnloClient =
        initializeInternal(context, sdkKey, PRODUCTION_ORIGIN, ai.onlo.sdk.protocol.SdkFamily.FLUTTER)

    /** Build/release and fixture seam. It is not part of the host integration API. */
    internal fun initializeInternal(
        context: Context,
        sdkKey: String,
        serviceOrigin: String,
        sdkFamily: ai.onlo.sdk.protocol.SdkFamily = ai.onlo.sdk.protocol.SdkFamily.ANDROID,
    ): OnloClient = synchronized(monitor) {
        require(sdkKey.isNotBlank() && sdkKey.none(Char::isWhitespace)) { "sdk_key" }
        val origin = serviceOrigin.toHttpUrl()
        require(origin.isHttps) { "service_origin" }
        require(origin.encodedPath == "/") { "service_origin" }
        client?.let { return@synchronized it }

        val configuration = OnloConfiguration(
            sdkKey = sdkKey,
            appIdentifier = context.applicationContext.packageName,
            sdkFamily = sdkFamily,
            capabilities = listOf(
                ai.onlo.sdk.protocol.Capability.SECURE_STORAGE,
                ai.onlo.sdk.protocol.Capability.PERSISTENT_OUTBOX,
                ai.onlo.sdk.protocol.Capability.FOREGROUND_STREAM,
                ai.onlo.sdk.protocol.Capability.FCM,
                ai.onlo.sdk.protocol.Capability.IDENTITY_JWT,
                ai.onlo.sdk.protocol.Capability.CONFIG_SCHEMA_V1,
            ),
        )
        val transport = OkHttpOnloTransport()
        val requests = ProtocolRequestFactory(origin)
        val sdkScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        OnloClient(
            configuration = configuration,
            credentialStore = KeystoreCredentialStore(context),
            outboxStore = SQLiteOutboxStore(context),
            sessionApi = OnloSessionApi(transport, requests),
            configController = MobileConfigController(ai.onlo.sdk.transport.OnloConfigApi(transport, requests), KeystoreConfigStore(context), scope = sdkScope),
            widgetChatApi = WidgetChatApi(transport, requests),
            foregroundStream = ForegroundStream(transport, requests),
            pushRegistry = PushRegistry(KeystorePushTokenStore(context), OnloPushApi(transport, requests)),
            logger = AndroidSafeLogger(),
            scope = sdkScope,
        ).also {
            client = it
            lifecycleBinding = NativeLifecycleBinding(
                context = context.applicationContext,
                onForeground = it::onAppForeground,
                onNetworkRecovered = it::onNetworkRecovered,
            ).also(NativeLifecycleBinding::install)
            it.startRestoration()
        }
    }

    /** Returns the previously initialized client, failing safely when initialization was skipped. */
    @JvmStatic
    public fun instance(): OnloClient = synchronized(monitor) {
        checkNotNull(client) { "onlo_not_initialized" }
    }

    /** Test-only teardown seam. Production hosts never need to call this. */
    internal fun resetForTests() = synchronized(monitor) {
        lifecycleBinding?.close()
        lifecycleBinding = null
        client = null
    }

    private const val PRODUCTION_ORIGIN = "https://onlo.ai/"
}

/** Cross-module React Native bridge initializer. The descriptor family is deliberately fixed. */
public object OnloReactNativeBridge {
    @JvmStatic
    public fun initialize(context: Context, sdkKey: String): OnloClient = Onlo.initializeForReactNative(context, sdkKey)
}

/** Cross-module Flutter bridge initializer. The descriptor family is deliberately fixed. */
public object OnloFlutterBridge {
    @JvmStatic
    public fun initialize(context: Context, sdkKey: String): OnloClient = Onlo.initializeForFlutter(context, sdkKey)
}
