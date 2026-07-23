package ai.onlo.sdk.transport

import ai.onlo.sdk.protocol.ApiEnvelope
import ai.onlo.sdk.protocol.ApiFailure
import ai.onlo.sdk.protocol.ApiSuccess
import ai.onlo.sdk.protocol.AttachmentIntentRequest
import ai.onlo.sdk.protocol.ChatRequest
import ai.onlo.sdk.protocol.ConversationPageQuery
import ai.onlo.sdk.protocol.ProtocolJsonCodec
import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.protocol.PROTOCOL_VERSION
import ai.onlo.sdk.protocol.PushTokenRequest
import ai.onlo.sdk.protocol.SessionRequest
import ai.onlo.sdk.protocol.SessionResult
import ai.onlo.sdk.config.MobileConfig
import ai.onlo.sdk.config.MobileConfigCodec
import java.io.IOException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.launch
import okhttp3.Call
import okhttp3.Headers.Companion.toHeaders
import okhttp3.HttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.MultipartBody
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okio.BufferedSource

internal data class OnloHttpRequest(
    val method: String,
    val url: HttpUrl,
    val headers: Map<String, String>,
    val body: RequestBody? = null,
)

internal data class OnloHttpResponse(
    val status: Int,
    val headers: Map<String, String>,
    val body: String,
)

internal interface OnloTransport {
    suspend fun execute(request: OnloHttpRequest): OnloHttpResponse
}

/** Cancellable line streaming for SSE; responses are never assembled into an AI-response String. */
internal interface OnloSseTransport {
    suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult
}

internal sealed interface SseStreamResult {
    data class Success(val status: Int) : SseStreamResult
    data class Failure(val status: Int, val errorBody: String) : SseStreamResult
}

internal class OkHttpOnloTransport(
    private val client: OkHttpClient = OkHttpClient(),
) : OnloTransport, OnloSseTransport {
    override suspend fun execute(request: OnloHttpRequest): OnloHttpResponse = suspendCancellableCoroutine { continuation ->
        val call = client.newCall(
            Request.Builder()
                .url(request.url)
                .headers(request.headers.toHeaders())
                .method(request.method, request.body)
                .build(),
        )
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: Call, exception: IOException) {
                if (continuation.isActive) continuation.resumeWithException(exception)
            }

            override fun onResponse(call: Call, response: Response) {
                response.use {
                    if (!continuation.isActive) return
                    continuation.resume(
                        OnloHttpResponse(
                            status = response.code,
                            headers = response.headers.toMultimap().mapValues { (_, values) -> values.joinToString(",") },
                            body = response.body?.string().orEmpty(),
                        ),
                    )
                }
            }
        })
    }

    override suspend fun stream(request: OnloHttpRequest, onLine: suspend (String) -> Unit): SseStreamResult = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
        val call = client.newCall(Request.Builder().url(request.url).headers(request.headers.toHeaders()).method(request.method, request.body).build())
        kotlinx.coroutines.currentCoroutineContext()[kotlinx.coroutines.Job]?.invokeOnCompletion { if (it is kotlinx.coroutines.CancellationException) call.cancel() }
        call.execute().use { response ->
            if (response.code !in 200..299) {
                val source = response.body?.source()
                val body = if (source == null) "" else okio.Buffer().let { sink -> source.read(sink, 8_192); sink.readUtf8() }
                return@use SseStreamResult.Failure(response.code, body)
            }
            val source: BufferedSource = checkNotNull(response.body).source()
            while (!source.exhausted()) onLine(source.readUtf8Line() ?: break)
            SseStreamResult.Success(response.code)
        }
    }
}

internal class ProtocolRequestFactory(
    private val baseUrl: HttpUrl,
) {
    fun session(value: SessionRequest): OnloHttpRequest = jsonPost(
        path = "api/sdk/v1/session",
        body = ProtocolJsonCodec.encodeSessionRequest(value),
    )

    fun pushToken(chatToken: String, value: PushTokenRequest): OnloHttpRequest = jsonPost(
        path = "api/sdk/v1/push-token",
        body = ProtocolJsonCodec.encodePushTokenRequest(value),
        bearerToken = chatToken,
    )

    fun attachmentIntent(chatToken: String, value: AttachmentIntentRequest): OnloHttpRequest = jsonPost(
        path = "api/sdk/v1/attachments/intent",
        body = ProtocolJsonCodec.encodeAttachmentIntentRequest(value),
        bearerToken = chatToken,
    )

    fun attachmentComplete(
        chatToken: String,
        intent: String,
        fileName: String,
        mimeType: String,
        file: java.io.File,
    ): OnloHttpRequest = OnloHttpRequest(
        method = "POST",
        url = endpoint("api/sdk/v1/attachments/complete"),
        headers = mapOf("Authorization" to "Bearer $chatToken"),
        body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .addFormDataPart("intent", intent)
            .addFormDataPart("file", fileName, file.asRequestBody(mimeType.toMediaType()))
            .build(),
    )

    fun widgetAttachmentUpload(
        chatToken: String,
        conversationId: String?,
        previousGrant: String? = null,
        fileName: String,
        mimeType: String,
        file: java.io.File,
    ): OnloHttpRequest = OnloHttpRequest(
        method = "POST",
        url = endpoint("api/widget/attachments"),
        headers = mapOf("Authorization" to "Bearer $chatToken"),
        body = MultipartBody.Builder()
            .setType(MultipartBody.FORM)
            .apply {
                conversationId?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("conversationId", it)
                }
                previousGrant?.takeIf(String::isNotBlank)?.let {
                    addFormDataPart("previousGrant", it)
                }
            }
            .addFormDataPart("files", fileName, file.asRequestBody(mimeType.toMediaType()))
            .build(),
    )

    fun chat(chatToken: String, value: ChatRequest): OnloHttpRequest = jsonPost(
        path = "api/widget/chat",
        body = ProtocolJsonCodec.encodeChatRequest(value),
        bearerToken = chatToken,
        accept = "text/event-stream",
    )

    fun conversations(chatToken: String, limit: Int?): OnloHttpRequest {
        require(limit == null || limit in 1..50) { "conversation_limit" }
        val url = endpoint("api/widget/conversations").newBuilder().apply {
            limit?.let { addQueryParameter("limit", it.toString()) }
        }.build()
        return bearerGet(url, chatToken)
    }

    fun helpCenter(chatToken: String): OnloHttpRequest =
        bearerGet(endpoint("api/widget/articles"), chatToken)

    fun helpCenterArticle(chatToken: String, articleId: String): OnloHttpRequest {
        require(articleId.isNotBlank()) { "article_id" }
        return bearerGet(
            endpoint("api/widget/articles").newBuilder().addPathSegment(articleId).build(),
            chatToken,
        )
    }

    fun transcript(
        chatToken: String,
        conversationId: String,
        page: ConversationPageQuery,
    ): OnloHttpRequest {
        require(page.limit == null || page.limit in 1..100) { "transcript_limit" }
        val url = endpoint("api/widget/conversations").newBuilder()
            .addPathSegment(conversationId)
            .apply {
                when (page) {
                    is ConversationPageQuery.After -> addQueryParameter("after", page.after)
                    is ConversationPageQuery.Before -> addQueryParameter("before", page.before)
                    is ConversationPageQuery.Latest -> Unit
                }
                page.limit?.let { addQueryParameter("limit", it.toString()) }
            }
            .build()
        return bearerGet(url, chatToken)
    }

    fun acknowledgeRead(
        chatToken: String,
        conversationId: String,
        throughMessageId: String,
    ): OnloHttpRequest {
        require(conversationId.isNotBlank()) { "conversation_id" }
        require(throughMessageId.isNotBlank()) { "message_id" }
        val url = endpoint("api/widget/conversations").newBuilder()
            .addPathSegment(conversationId)
            .addPathSegment("read")
            .build()
        return OnloHttpRequest(
            method = "PUT",
            url = url,
            headers = mapOf(
                "Authorization" to "Bearer $chatToken",
                "Accept" to "application/json",
            ),
            body = org.json.JSONObject()
                .put("throughMessageId", throughMessageId)
                .toString()
                .toRequestBody(JSON_MEDIA_TYPE),
        )
    }

    fun stream(chatToken: String): OnloHttpRequest = OnloHttpRequest(
        method = "GET",
        url = endpoint("api/widget/stream"),
        headers = mapOf(
            "Authorization" to "Bearer $chatToken",
            "Accept" to "text/event-stream",
        ),
    )

    fun config(chatToken: String, etag: String?): OnloHttpRequest = OnloHttpRequest(
        method = "GET",
        url = endpoint("api/sdk/v1/config"),
        headers = buildMap {
            put("Authorization", "Bearer $chatToken")
            put("Accept", "application/json")
            put("X-Onlo-Config-Schema", "1")
            etag?.let { put("If-None-Match", it) }
        },
    )

    private fun jsonPost(
        path: String,
        body: String,
        bearerToken: String? = null,
        accept: String = "application/json",
    ): OnloHttpRequest = OnloHttpRequest(
        method = "POST",
        url = endpoint(path),
        headers = buildMap {
            put("Accept", accept)
            if (bearerToken != null) put("Authorization", "Bearer $bearerToken")
        },
        body = body.toRequestBody(JSON_MEDIA_TYPE),
    )

    private fun bearerGet(url: HttpUrl, chatToken: String): OnloHttpRequest = OnloHttpRequest(
        method = "GET",
        url = url,
        headers = mapOf("Authorization" to "Bearer $chatToken", "Accept" to "application/json"),
    )

    private fun endpoint(path: String): HttpUrl = baseUrl.newBuilder().addPathSegments(path).build()

    private companion object {
        val JSON_MEDIA_TYPE = "application/json; charset=utf-8".toMediaType()
    }
}

internal class OnloSessionApi(
    private val transport: OnloTransport,
    private val requests: ProtocolRequestFactory,
) {
    suspend fun exchange(value: SessionRequest): ApiEnvelope<SessionResult> {
        val response = transport.execute(requests.session(value))
        val envelope = ProtocolJsonCodec.decodeSessionEnvelope(response.body)
        if (envelope.protocolVersion != PROTOCOL_VERSION || envelope.minimumProtocolVersion > PROTOCOL_VERSION) {
            throw ProtocolViolation("unsupported_protocol")
        }
        if (response.status !in 200..299 && envelope is ApiSuccess) {
            throw ProtocolViolation("unexpected_success_status")
        }
        return envelope
    }
}

/** Push routes use standard v1 envelopes; their result shapes remain exact. */
internal class OnloPushApi(
    private val transport: OnloTransport,
    private val requests: ProtocolRequestFactory,
) {
    suspend fun register(
        chatToken: String,
        token: String,
        notificationPreference: ai.onlo.sdk.protocol.NotificationPreference?,
        locale: String?,
    ): ApiEnvelope<ai.onlo.sdk.protocol.PushRegistrationResult> {
        val response = transport.execute(
            requests.pushToken(chatToken, PushTokenRequest.Register(ai.onlo.sdk.protocol.PushProvider.FCM, token, notificationPreference, locale)),
        )
        val envelope = ProtocolJsonCodec.decodePushRegisterEnvelope(response.body)
        if (envelope.protocolVersion != PROTOCOL_VERSION || envelope.minimumProtocolVersion > PROTOCOL_VERSION) throw ProtocolViolation("unsupported_protocol")
        if (response.status !in 200..299 && envelope is ApiSuccess) throw ProtocolViolation("unexpected_success_status")
        return envelope
    }

    suspend fun unregister(chatToken: String): ApiEnvelope<ai.onlo.sdk.protocol.PushUnregistrationResult> {
        val response = transport.execute(requests.pushToken(chatToken, PushTokenRequest.Unregister))
        val envelope = ProtocolJsonCodec.decodePushUnregisterEnvelope(response.body)
        if (envelope.protocolVersion != PROTOCOL_VERSION || envelope.minimumProtocolVersion > PROTOCOL_VERSION) throw ProtocolViolation("unsupported_protocol")
        if (response.status !in 200..299 && envelope is ApiSuccess) throw ProtocolViolation("unexpected_success_status")
        return envelope
    }
}

internal sealed interface ConfigFetchResult {
    data class Modified(val envelope: ApiEnvelope<MobileConfig>, val raw: String, val etag: String?) : ConfigFetchResult
    data object NotModified : ConfigFetchResult
}

internal class OnloConfigApi(
    private val transport: OnloTransport,
    private val requests: ProtocolRequestFactory,
) {
    suspend fun fetch(chatToken: String, etag: String?): ConfigFetchResult {
        val response = transport.execute(requests.config(chatToken, etag))
        if (response.status == 304) {
            if (response.body.isNotEmpty()) throw ProtocolViolation("config_304_body")
            return ConfigFetchResult.NotModified
        }
        val envelope = ProtocolJsonCodec.decodeConfigEnvelope(response.body)
        if (envelope.protocolVersion != PROTOCOL_VERSION || envelope.minimumProtocolVersion > PROTOCOL_VERSION) throw ProtocolViolation("unsupported_protocol")
        if (response.status !in 200..299 && envelope is ApiSuccess) throw ProtocolViolation("unexpected_success_status")
        val responseEtag = response.headers.entries.firstOrNull { it.key.equals("ETag", ignoreCase = true) }?.value
        if (envelope is ApiSuccess && responseEtag.isNullOrBlank()) throw ProtocolViolation("config_etag")
        return ConfigFetchResult.Modified(envelope, response.body, responseEtag)
    }
}
