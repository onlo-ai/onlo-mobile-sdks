package ai.onlo.sdk.protocol

import ai.onlo.sdk.config.MobileConfig
import ai.onlo.sdk.config.MobileConfigCodec
import org.json.JSONArray
import org.json.JSONObject

/** The only JSON codec used for mobile-v1 request construction and session envelopes. */
internal object ProtocolJsonCodec {
    fun encodeSessionRequest(value: SessionRequest): String = JSONObject().apply {
        put("sdkKey", value.sdkKey)
        put("appIdentifier", value.appIdentifier)
        put("client", encodeClient(value.client))
        put("operation", encodeOperation(value.operation))
    }.toString()

    fun encodePushTokenRequest(value: PushTokenRequest): String = JSONObject().apply {
        when (value) {
            is PushTokenRequest.Register -> {
                put("action", "register")
                put("provider", value.provider.wireValue)
                put("token", value.token)
                value.notificationPreference?.let { put("notificationPreference", it.wireValue) }
                value.locale?.let { put("locale", it) }
            }

            PushTokenRequest.Unregister -> put("action", "unregister")
        }
    }.toString()

    fun encodeAttachmentIntentRequest(value: AttachmentIntentRequest): String = JSONObject().apply {
        put("conversationId", value.conversationId)
        put("mimeType", value.mimeType.wireValue)
        put("byteSize", value.byteSize)
        put("sha256", value.sha256)
        put("filename", value.filename)
    }.toString()

    fun encodeChatRequest(value: ChatRequest): String = JSONObject().apply {
        put("sessionId", value.sessionId)
        put("clientMessageId", value.clientMessageId)
        put("message", value.message)
        if (value.attachments.isNotEmpty()) {
            put("attachments", JSONArray().apply {
                value.attachments.forEach { attachment -> put(encodeChatAttachment(attachment)) }
            })
        }
    }.toString()

    fun encodeChatAttachment(value: ChatAttachment): JSONObject = JSONObject().apply {
        value.id?.let { put("id", it) }
        put("url", value.url)
        put("type", value.type)
        put("name", value.name)
        put("size", value.size)
        value.sha256?.let { put("sha256", it) }
        value.receipt?.let { put("receipt", it) }
    }

    fun decodeChatAttachment(value: JSONObject): ChatAttachment = ChatAttachment(
        id = value.optionalString("id"),
        url = value.requiredString("url"),
        type = value.requiredString("type"),
        name = value.requiredString("name"),
        size = value.requiredLong("size"),
        sha256 = value.optionalString("sha256"),
        receipt = value.optionalString("receipt"),
    )

    fun decodeSessionEnvelope(raw: String): ApiEnvelope<SessionResult> {
        return decodeEnvelope(raw, ::decodeSessionResult)
    }

    fun decodeConfigEnvelope(raw: String): ApiEnvelope<MobileConfig> = decodeEnvelope(raw) { value -> MobileConfigCodec.decode(value) }

    fun decodePushRegisterEnvelope(raw: String): ApiEnvelope<PushRegistrationResult> = decodeEnvelope(raw) { value ->
        val expected = setOf("state", "provider", "environment", "fingerprint", "registeredAt")
        if (value.keySet() != expected) throw ProtocolViolation("push_register")
        PushRegistrationResult(value.requiredString("state"), value.requiredString("provider"), value.requiredString("environment"), value.requiredString("fingerprint"), value.requiredString("registeredAt")).also {
            if (it.state !in setOf("active", "muted") || it.provider != "fcm" || it.environment !in setOf("sandbox", "production") || it.fingerprint.isBlank() || it.registeredAt.isBlank()) throw ProtocolViolation("push_register")
        }
    }

    fun decodePushUnregisterEnvelope(raw: String): ApiEnvelope<PushUnregistrationResult> = decodeEnvelope(raw) { value ->
        if (value.keySet() != setOf("state")) throw ProtocolViolation("push_unregister")
        PushUnregistrationResult(value.requiredString("state")).also { if (it.state != "inactive") throw ProtocolViolation("push_unregister") }
    }

    private fun <T> decodeEnvelope(raw: String, decodeResult: (JSONObject) -> T): ApiEnvelope<T> {
        val objectValue = try {
            JSONObject(raw)
        } catch (_: Exception) {
            throw ProtocolViolation("malformed_envelope")
        }

        val common = EnvelopeCommon(
            requestId = objectValue.requiredString("requestId"),
            serverTime = objectValue.requiredString("serverTime"),
            protocolVersion = objectValue.requiredInt("protocolVersion"),
            minimumProtocolVersion = objectValue.requiredInt("minimumProtocolVersion"),
        )

        return when (objectValue.requiredBoolean("ok")) {
            true -> ApiSuccess(
                requestId = common.requestId,
                serverTime = common.serverTime,
                protocolVersion = common.protocolVersion,
                minimumProtocolVersion = common.minimumProtocolVersion,
                result = decodeResult(objectValue.requiredObject("result")),
            )

            false -> {
                val error = objectValue.requiredObject("error")
                val retry = error.requiredObject("retry")
                val retryAfterMs = retry.optionalLong("retryAfterMs")
                if (retryAfterMs != null && retryAfterMs < 0) throw ProtocolViolation("retry_after_ms")
                ApiFailure(
                    requestId = common.requestId,
                    serverTime = common.serverTime,
                    protocolVersion = common.protocolVersion,
                    minimumProtocolVersion = common.minimumProtocolVersion,
                    error = ApiError(
                        code = ErrorCode.fromWire(error.requiredString("code")),
                        message = error.requiredString("message"),
                        retry = ApiRetry(
                            directive = RetryDirective.fromWire(retry.requiredString("directive")),
                            retryAfterMs = retryAfterMs,
                        ),
                    ),
                )
            }
        }
    }

    private fun encodeClient(value: SdkClientDescriptor): JSONObject = JSONObject().apply {
        put("protocolVersion", value.protocolVersion)
        put("installationId", value.installationId)
        put("runtimePlatform", value.runtimePlatform.wireValue)
        put("sdkFamily", value.sdkFamily.wireValue)
        put("sdkVersion", value.sdkVersion)
        value.appVersion?.let { put("appVersion", it) }
        value.appBuild?.let { put("appBuild", it) }
        put("capabilities", JSONArray(value.capabilities.map(Capability::wireValue)))
    }

    private fun encodeOperation(value: SessionOperation): JSONObject = JSONObject().apply {
        when (value) {
            is SessionOperation.Bootstrap -> {
                put("type", "bootstrap")
                put("transitionId", value.transitionId)
                put("proposedCredential", value.proposedCredential)
                value.userJwt?.let { put("userJwt", it) }
            }

            is SessionOperation.Resume -> {
                put("type", "resume")
                put("transitionId", value.transitionId)
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
                put("proposedCredential", value.proposedCredential)
            }

            is SessionOperation.Identify -> {
                put("type", "identify")
                put("transitionId", value.transitionId)
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
                put("proposedCredential", value.proposedCredential)
                put("userJwt", value.userJwt)
            }

            is SessionOperation.Logout -> {
                put("type", "logout")
                put("transitionId", value.transitionId)
                put("expectedGeneration", value.expectedGeneration)
                put("presentedCredential", value.presentedCredential)
                put("proposedCredential", value.proposedCredential)
            }
        }
    }

    private fun decodeSessionResult(value: JSONObject): SessionResult = SessionResult(
        sessionId = value.requiredString("sessionId"),
        chatToken = value.requiredString("chatToken"),
        installationId = value.requiredString("installationId"),
        generation = value.requiredLong("generation"),
        proposedCredential = value.requiredString("proposedCredential"),
        identityClass = IdentityClass.fromWire(value.requiredString("identityClass")),
        publicationState = PublicationState.fromWire(value.requiredString("publicationState")),
        attestationState = value.requiredString("attestationState"),
        configRevision = value.requiredString("configRevision"),
        configSchemaVersion = value.requiredInt("configSchemaVersion"),
        configEtag = value.requiredString("configEtag"),
    )

    private data class EnvelopeCommon(
        val requestId: String,
        val serverTime: String,
        val protocolVersion: Int,
        val minimumProtocolVersion: Int,
    )
}

internal fun JSONObject.requiredObject(name: String): JSONObject = try {
    get(name) as? JSONObject ?: throw ProtocolViolation(name)
} catch (_: ProtocolViolation) {
    throw ProtocolViolation(name)
} catch (_: Exception) {
    throw ProtocolViolation(name)
}

internal fun JSONObject.requiredString(name: String): String = try {
    get(name) as? String ?: throw ProtocolViolation(name)
} catch (_: ProtocolViolation) {
    throw ProtocolViolation(name)
} catch (_: Exception) {
    throw ProtocolViolation(name)
}

internal fun JSONObject.optionalString(name: String): String? {
    if (!has(name) || isNull(name)) return null
    return requiredString(name)
}

internal fun JSONObject.requiredBoolean(name: String): Boolean = try {
    get(name) as? Boolean ?: throw ProtocolViolation(name)
} catch (_: ProtocolViolation) {
    throw ProtocolViolation(name)
} catch (_: Exception) {
    throw ProtocolViolation(name)
}

internal fun JSONObject.requiredInt(name: String): Int {
    val number = requiredNumber(name)
    if (number.toLong().toDouble() != number.toDouble() || number.toLong() !in Int.MIN_VALUE..Int.MAX_VALUE) {
        throw ProtocolViolation(name)
    }
    return number.toInt()
}

internal fun JSONObject.requiredLong(name: String): Long {
    val number = requiredNumber(name)
    if (number.toLong().toDouble() != number.toDouble()) throw ProtocolViolation(name)
    return number.toLong()
}

internal fun JSONObject.optionalLong(name: String): Long? {
    if (!has(name) || isNull(name)) return null
    return requiredLong(name)
}

private fun JSONObject.requiredNumber(name: String): Number = try {
    get(name) as? Number ?: throw ProtocolViolation(name)
} catch (_: ProtocolViolation) {
    throw ProtocolViolation(name)
} catch (_: Exception) {
    throw ProtocolViolation(name)
}
