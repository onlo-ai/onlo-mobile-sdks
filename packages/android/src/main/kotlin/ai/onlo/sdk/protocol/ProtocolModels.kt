package ai.onlo.sdk.protocol

/** Exact mobile v1 transport model. Names map directly to the server contract. */
public const val PROTOCOL_VERSION: Int = 1
public const val MAX_MOBILE_IMAGE_BYTES: Long = 8L * 1024L * 1024L
public const val MAX_MOBILE_SOURCE_IMAGE_BYTES: Long = 25L * 1024L * 1024L
public const val MAX_MOBILE_IMAGES_PER_MESSAGE: Int = 5

public enum class RuntimePlatform(public val wireValue: String) {
    ANDROID("android"),
}

public enum class SdkFamily(public val wireValue: String) {
    ANDROID("android"),
    REACT_NATIVE("react-native"),
    FLUTTER("flutter"),
}

/** Values accepted by the v1 discovery manifest. Do not declare a capability speculatively. */
public enum class Capability(public val wireValue: String) {
    SECURE_STORAGE("secure_storage"),
    PERSISTENT_OUTBOX("persistent_outbox"),
    FOREGROUND_STREAM("foreground_stream"),
    FCM("fcm"),
    MEDIA_PICKER("media_picker"),
    ATTACHMENT_UPLOAD("attachment_upload"),
    CONFIG_SCHEMA_V1("config_schema_v1"),
    IDENTITY_JWT("identity_jwt"),
    APP_ATTESTATION("app_attestation"),
    DEEP_LINK_ROUTING("deep_link_routing"),
}

public enum class IdentityClass(public val wireValue: String) {
    ANONYMOUS("anonymous"),
    IDENTIFIED("identified"),
    ;

    internal companion object {
        fun fromWire(value: String): IdentityClass = entries.firstOrNull { it.wireValue == value }
            ?: throw ProtocolViolation("identity_class")
    }
}

public enum class PublicationState(public val wireValue: String) {
    TESTING("testing"),
    PRODUCTION("production"),
    ;

    internal companion object {
        fun fromWire(value: String): PublicationState = entries.firstOrNull { it.wireValue == value }
            ?: throw ProtocolViolation("publication_state")
    }
}

public enum class ImageMimeType(public val wireValue: String) {
    JPEG("image/jpeg"),
    PNG("image/png"),
    WEBP("image/webp"),
}

public data class SdkClientDescriptor(
    val protocolVersion: Int = PROTOCOL_VERSION,
    val installationId: String,
    val runtimePlatform: RuntimePlatform = RuntimePlatform.ANDROID,
    val sdkFamily: SdkFamily = SdkFamily.ANDROID,
    val sdkVersion: String,
    val appVersion: String? = null,
    val appBuild: String? = null,
    val capabilities: List<Capability>,
)

public enum class RetryDirective(public val wireValue: String) {
    NEVER("never"),
    AFTER_TOKEN_REFRESH("after_token_refresh"),
    AFTER_ATTESTATION("after_attestation"),
    AFTER_BACKOFF("after_backoff"),
    AFTER_FULL_SYNC("after_full_sync");

    internal companion object {
        fun fromWire(value: String): RetryDirective = entries.firstOrNull { it.wireValue == value }
            ?: throw ProtocolViolation("retry_directive")
    }
}

/** Error codes emitted by the v1 envelope. Unknown values are a protocol violation. */
public enum class ErrorCode(public val wireValue: String) {
    INVALID_REQUEST("invalid_request"),
    INVALID_TARGET_KEY("invalid_target_key"),
    SDK_NOT_AVAILABLE("sdk_not_available"),
    TARGET_DISABLED("target_disabled"),
    INCOMPATIBLE_CLIENT("incompatible_client"),
    PROOF_REQUIRED("proof_required"),
    INVALID_PROOF("invalid_proof"),
    EXPIRED_PROOF("expired_proof"),
    IDENTITY_DISABLED("identity_disabled"),
    ATTESTATION_REQUIRED("attestation_required"),
    INVALID_ATTESTATION("invalid_attestation"),
    SESSION_EXPIRED("session_expired"),
    SESSION_REVOKED("session_revoked"),
    FORBIDDEN_PRINCIPAL("forbidden_principal"),
    STALE_CURSOR("stale_cursor"),
    IDEMPOTENCY_CONFLICT("idempotency_conflict"),
    CONFIG_UNAVAILABLE("config_unavailable"),
    MEDIA_UNAVAILABLE("media_unavailable"),
    RATE_LIMITED("rate_limited"),
    DEPENDENCY_UNAVAILABLE("dependency_unavailable");

    internal companion object {
        fun fromWire(value: String): ErrorCode = entries.firstOrNull { it.wireValue == value }
            ?: throw ProtocolViolation("error_code")
    }
}

public data class ApiRetry(
    val directive: RetryDirective,
    val retryAfterMs: Long? = null,
)

public data class ApiError(
    val code: ErrorCode,
    val message: String,
    val retry: ApiRetry,
)

public sealed interface ApiEnvelope<out T> {
    val requestId: String
    val serverTime: String
    val protocolVersion: Int
    val minimumProtocolVersion: Int
}

public data class ApiSuccess<T>(
    override val requestId: String,
    override val serverTime: String,
    override val protocolVersion: Int,
    override val minimumProtocolVersion: Int,
    val result: T,
) : ApiEnvelope<T>

public data class ApiFailure(
    override val requestId: String,
    override val serverTime: String,
    override val protocolVersion: Int,
    override val minimumProtocolVersion: Int,
    val error: ApiError,
) : ApiEnvelope<Nothing>

public sealed interface SessionOperation {
    public val transitionId: String
    public val proposedCredential: String

    public data class Bootstrap(
        override val transitionId: String,
        override val proposedCredential: String,
        val userJwt: String? = null,
    ) : SessionOperation

    public data class Resume(
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
    ) : SessionOperation

    public data class Identify(
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
        val userJwt: String,
    ) : SessionOperation

    public data class Logout(
        override val transitionId: String,
        val expectedGeneration: Long,
        val presentedCredential: String,
        override val proposedCredential: String,
    ) : SessionOperation
}

public data class SessionRequest(
    val sdkKey: String,
    val appIdentifier: String,
    val client: SdkClientDescriptor,
    val operation: SessionOperation,
)

public data class SessionResult(
    val sessionId: String,
    val chatToken: String,
    val installationId: String,
    val generation: Long,
    val proposedCredential: String,
    val identityClass: IdentityClass,
    val publicationState: PublicationState,
    val attestationState: String,
    val configRevision: String,
    val configSchemaVersion: Int,
    val configEtag: String,
)

public sealed interface PushTokenRequest {
    public data class Register(
        val provider: PushProvider,
        val token: String,
        val notificationPreference: NotificationPreference? = null,
        val locale: String? = null,
    ) : PushTokenRequest

    public data object Unregister : PushTokenRequest
}

public enum class PushProvider(public val wireValue: String) {
    APNS("apns"),
    FCM("fcm"),
}

public enum class NotificationPreference(public val wireValue: String) {
    ENABLED("enabled"),
    MUTED("muted"),
    ;

    internal companion object {
        fun fromWire(value: String): NotificationPreference = entries.firstOrNull { it.wireValue == value }
            ?: throw ProtocolViolation("notification_preference")
    }
}

internal data class PushRegistrationResult(
    val state: String,
    val provider: String,
    val environment: String,
    val fingerprint: String,
    val registeredAt: String,
)

internal data class PushUnregistrationResult(val state: String)

public data class AttachmentIntentRequest(
    val conversationId: String,
    val mimeType: ImageMimeType,
    val byteSize: Long,
    val sha256: String,
    val filename: String,
) {
    init {
        require(byteSize in 1..MAX_MOBILE_IMAGE_BYTES) { "attachment_size" }
    }
}

public data class ChatAttachment(
    val id: String? = null,
    val url: String,
    val type: String,
    val name: String,
    val size: Long,
    val sha256: String? = null,
    val receipt: String? = null,
)

public data class ChatRequest(
    val sessionId: String,
    val clientMessageId: String,
    val message: String,
    val attachments: List<ChatAttachment> = emptyList(),
) {
    init {
        require(attachments.size <= MAX_MOBILE_IMAGES_PER_MESSAGE) { "attachment_count" }
    }
}

public sealed interface ConversationPageQuery {
    public val limit: Int?

    public data class Before(val before: String, override val limit: Int? = null) : ConversationPageQuery
    public data class After(val after: String, override val limit: Int? = null) : ConversationPageQuery
    public data class Latest(override val limit: Int? = null) : ConversationPageQuery
}

public class ProtocolViolation(public val safeCode: String) : IllegalArgumentException(safeCode)
