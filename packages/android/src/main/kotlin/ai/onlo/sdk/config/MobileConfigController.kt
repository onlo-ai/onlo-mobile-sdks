package ai.onlo.sdk.config

import ai.onlo.sdk.protocol.ApiFailure
import ai.onlo.sdk.protocol.ApiSuccess
import ai.onlo.sdk.protocol.ErrorCode
import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.protocol.RetryDirective
import ai.onlo.sdk.transport.ConfigFetchResult
import ai.onlo.sdk.transport.OnloConfigApi
import java.io.IOException
import kotlin.math.min
import kotlin.random.Random
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

public data class MobileConfigSnapshot(val config: MobileConfig?, val revision: String?, val isLastKnownGood: Boolean, val safeErrorCode: String? = null)
internal sealed interface ConfigRefreshResult { data object Updated : ConfigRefreshResult; data object Unchanged : ConfigRefreshResult; data class RetainedLastKnownGood(val safeErrorCode: String) : ConfigRefreshResult; data object ReauthenticationRequired : ConfigRefreshResult; data object IncompatibleClient : ConfigRefreshResult; data object SessionSuperseded : ConfigRefreshResult }

/** Network calls occur outside the mutex; only the matching session generation may publish results. */
internal class MobileConfigController(
    private val api: OnloConfigApi,
    private val store: ProtectedConfigStore,
    private val nowMs: () -> Long = { System.currentTimeMillis() },
    private val scope: CoroutineScope? = null,
    private val fallbackBackoffJitter: () -> Double = { Random.nextDouble() },
) {
    private val mutex = Mutex()
    private var etag: String? = null
    private var rawConfig: String? = null
    private var retryAtMs: Long? = null
    private var retryAttempt = 0
    private var sessionVersion = 0L
    private var retryJob: Job? = null
    private val mutableSnapshot = MutableStateFlow(MobileConfigSnapshot(null, null, false))
    val snapshot: StateFlow<MobileConfigSnapshot> = mutableSnapshot.asStateFlow()

    suspend fun onSessionBoundary(): Long = mutex.withLock { sessionVersion += 1; retryJob?.cancel(); retryJob = null; sessionVersion }

    suspend fun restoreLastKnownGood() = mutex.withLock {
        val stored = store.load() ?: return@withLock
        try {
            stored.raw?.let { raw ->
                val config = MobileConfigCodec.decode(raw)
                etag = stored.etag
                rawConfig = raw
                mutableSnapshot.value = MobileConfigSnapshot(config, config.revision, true)
            }
            retryAtMs = stored.retryEligibleAtMs; retryAttempt = stored.retryAttempt
        } catch (_: Exception) { store.clear(); etag = null; rawConfig = null; retryAtMs = null; retryAttempt = 0 }
    }

    suspend fun refresh(chatToken: String, version: Long, allowTokenRefresh: Boolean = true): ConfigRefreshResult {
        val request = mutex.withLock {
            if (version != sessionVersion) return ConfigRefreshResult.SessionSuperseded
            if ((retryAtMs ?: Long.MIN_VALUE) > nowMs()) return retainedLocked("config_backoff")
            RequestState(etag, version)
        }
        return try {
            when (val fetched = api.fetch(chatToken, request.etag)) {
                ConfigFetchResult.NotModified -> mutex.withLock {
                    if (request.version != sessionVersion) ConfigRefreshResult.SessionSuperseded
                    else if (mutableSnapshot.value.config == null || etag.isNullOrBlank()) retainedLocked("config_not_modified_without_lkg")
                    else { retryAtMs = null; retryAttempt = 0; persistLocked(); ConfigRefreshResult.Unchanged }
                }
                is ConfigFetchResult.Modified -> when (val envelope = fetched.envelope) {
                    is ApiSuccess -> mutex.withLock {
                        if (request.version != sessionVersion) ConfigRefreshResult.SessionSuperseded else applyValidatedLocked(fetched.raw, fetched.etag)
                    }
                    is ApiFailure -> mutex.withLock {
                        if (request.version != sessionVersion) ConfigRefreshResult.SessionSuperseded else handleFailureLocked(envelope.error.code, envelope.error.retry.directive, envelope.error.retry.retryAfterMs, chatToken, request.version, allowTokenRefresh)
                    }
                }
            }
        } catch (_: IOException) { mutex.withLock { if (request.version == sessionVersion) retainedLocked("config_offline") else ConfigRefreshResult.SessionSuperseded } }
        catch (_: ProtocolViolation) { mutex.withLock { if (request.version == sessionVersion) retainedLocked("invalid_protocol") else ConfigRefreshResult.SessionSuperseded } }
    }

    suspend fun applyValidated(raw: String, responseEtag: String?): ConfigRefreshResult = mutex.withLock { applyValidatedLocked(raw, responseEtag) }

    private suspend fun applyValidatedLocked(raw: String, responseEtag: String?): ConfigRefreshResult {
        if (responseEtag.isNullOrBlank()) throw ProtocolViolation("config_etag")
        val result = org.json.JSONObject(raw).getJSONObject("result").toString()
        val config = MobileConfigCodec.decode(result)
        store.save(StoredMobileConfig(responseEtag, result))
        etag = responseEtag; rawConfig = result; retryAtMs = null; retryAttempt = 0
        mutableSnapshot.value = MobileConfigSnapshot(config, config.revision, false)
        return ConfigRefreshResult.Updated
    }

    private suspend fun handleFailureLocked(code: ErrorCode, directive: RetryDirective, retryAfterMs: Long?, chatToken: String, version: Long, allowTokenRefresh: Boolean): ConfigRefreshResult = when {
        code == ErrorCode.INCOMPATIBLE_CLIENT && directive == RetryDirective.NEVER -> ConfigRefreshResult.IncompatibleClient
        code == ErrorCode.CONFIG_UNAVAILABLE && directive == RetryDirective.AFTER_BACKOFF -> {
            retryAttempt = min(MAX_TOTAL_CONFIG_ATTEMPTS, retryAttempt + 1)
            val delayMs = retryAfterMs ?: fallbackBackoffDelayMs(retryAttempt)
            retryAtMs = saturatingAdd(nowMs(), delayMs)
            persistLocked()
            if (retryAttempt < MAX_TOTAL_CONFIG_ATTEMPTS) scheduleRetryLocked(chatToken, version, delayMs)
            retainedLocked(code.wireValue)
        }
        directive == RetryDirective.AFTER_TOKEN_REFRESH && allowTokenRefresh -> ConfigRefreshResult.ReauthenticationRequired
        else -> retainedLocked(code.wireValue)
    }

    private suspend fun persistLocked() { store.save(StoredMobileConfig(etag, rawConfig, retryAtMs, retryAttempt)) }
    private fun retainedLocked(code: String): ConfigRefreshResult { mutableSnapshot.value = mutableSnapshot.value.copy(isLastKnownGood = mutableSnapshot.value.config != null, safeErrorCode = code); return ConfigRefreshResult.RetainedLastKnownGood(code) }
    private fun fallbackBackoffDelayMs(attempt: Int): Long { val base = min(30_000L, 500L shl min(attempt - 1, 5)); return (base * (0.75 + fallbackBackoffJitter().coerceIn(0.0, 1.0) * 0.5)).toLong() }
    private fun scheduleRetryLocked(chatToken: String, version: Long, delayMs: Long) {
        if (retryJob?.isActive == true) return
        retryJob = scope?.launch {
            delay(delayMs) // Server-supplied delay is intentionally exact.
            val stillCurrent = mutex.withLock {
                if (version != sessionVersion) false else { retryJob = null; true }
            }
            if (stillCurrent) refresh(chatToken, version)
        }
    }
    private fun saturatingAdd(value: Long, delay: Long): Long = if (delay > 0 && value > Long.MAX_VALUE - delay) Long.MAX_VALUE else value + delay
    private data class RequestState(val etag: String?, val version: Long)
    private companion object { const val MAX_TOTAL_CONFIG_ATTEMPTS = 3 }
}
