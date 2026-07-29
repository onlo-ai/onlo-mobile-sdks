package ai.onlo.sdk.push

import ai.onlo.sdk.protocol.NotificationPreference
import ai.onlo.sdk.protocol.ProtocolViolation
import ai.onlo.sdk.protocol.PushProvider
import ai.onlo.sdk.protocol.PushTokenRequest
import ai.onlo.sdk.protocol.ApiFailure
import ai.onlo.sdk.protocol.ApiSuccess
import ai.onlo.sdk.protocol.RetryDirective
import ai.onlo.sdk.transport.OnloPushApi
import ai.onlo.sdk.storage.OwnerScope
import java.io.IOException
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** The token store is a protected native boundary; it must never be backed by SQLite or preferences. */
internal interface PushTokenStore {
    suspend fun load(): StoredPushToken?
    suspend fun save(value: StoredPushToken)
    suspend fun clear()
}

/** Raw provider tokens remain only in [PushTokenStore]. Bearer tokens are deliberately absent. */
internal data class StoredPushToken(
    val ownerScopeId: String,
    val token: String,
    val registered: Boolean,
    val pendingUnregister: Boolean,
    val retryDirective: RetryDirective? = null,
    val retryEligibleAtMs: Long? = null,
    val retryAttempt: Int = 0,
    val notificationPreference: NotificationPreference? = null,
    val locale: String? = null,
    val transportPending: Boolean = false,
)

internal data class PushAuthority(
    val owner: OwnerScope,
    val chatToken: String,
    val sessionGeneration: Long = 0,
    val sessionId: String = "",
    val bearerVersion: Long = 0,
) {
    val ownerScopeId: String get() = owner.storageKey()
}

public sealed interface PushRegistrationOutcome {
    data object Registered : PushRegistrationOutcome
    data object Unregistered : PushRegistrationOutcome
    data object QueuedForReconciliation : PushRegistrationOutcome
    data object NoToken : PushRegistrationOutcome
    data object NoActiveSession : PushRegistrationOutcome
    data object UnsupportedProvider : PushRegistrationOutcome
    data object InvalidToken : PushRegistrationOutcome
    data object InvalidResponse : PushRegistrationOutcome
    /** A retiring owner's association is retained until an explicit unlink can complete. */
    data object BlockedByRetiringOwner : PushRegistrationOutcome
    data class PendingServer(val directive: RetryDirective) : PushRegistrationOutcome
    data object TerminalServerFailure : PushRegistrationOutcome
}

public sealed interface PushPayloadOutcome {
    data object NotOnlo : PushPayloadOutcome
    data object Malformed : PushPayloadOutcome
    data object NoActiveSession : PushPayloadOutcome
    data object NotAuthorised : PushPayloadOutcome
    data object RefetchFailed : PushPayloadOutcome
    data class NavigationIntent(val conversationId: String, val messageId: String) : PushPayloadOutcome
}

/**
 * Android-only FCM registration and payload boundary. It intentionally does not depend on Firebase:
 * an optional host adapter supplies a token to [register].
 */
internal class PushRegistry(
    private val store: PushTokenStore,
    private val api: OnloPushApi,
    private val nowMs: () -> Long = { System.currentTimeMillis() },
) {
    private val mutex = Mutex()
    private var activeAuthority: PushAuthority? = null

    suspend fun activateAuthority(authority: PushAuthority?) = mutex.withLock {
        activeAuthority = authority
    }

    /**
     * Drops only the retiring owner's local push work after the server session
     * transition becomes the authoritative registration boundary.
     */
    suspend fun discardOwner(ownerScopeId: String) = mutex.withLock {
        if (activeAuthority?.ownerScopeId == ownerScopeId) activeAuthority = null
        if (store.load()?.ownerScopeId == ownerScopeId) store.clear()
    }

    suspend fun hasPendingUnregister(ownerScopeId: String): Boolean = mutex.withLock {
        store.load()?.let { it.ownerScopeId == ownerScopeId && it.pendingUnregister } == true
    }

    /** True only when restoration may safely acquire an old bearer to perform exactly one unlink. */
    suspend fun needsFreshBearerNow(ownerScopeId: String): Boolean = mutex.withLock {
        val value = store.load() ?: return@withLock false
        if (!value.pendingUnregister || value.ownerScopeId != ownerScopeId) return@withLock false
        when (value.retryDirective) {
            RetryDirective.AFTER_TOKEN_REFRESH -> value.retryAttempt <= 1
            RetryDirective.AFTER_BACKOFF -> (value.retryEligibleAtMs ?: Long.MAX_VALUE) <= nowMs()
            // A freshly persisted unlink intent has no bearer after process restoration and may
            // resume immediately. Transport-ambiguous attempts still honour their local backoff.
            null -> !value.transportPending || (value.retryEligibleAtMs ?: Long.MAX_VALUE) <= nowMs()
            else -> false
        }
    }

    suspend fun requiresFreshBearer(ownerScopeId: String): Boolean = mutex.withLock {
        store.load()?.let { it.ownerScopeId == ownerScopeId && it.pendingUnregister && it.retryDirective == RetryDirective.AFTER_TOKEN_REFRESH && it.retryAttempt <= 1 } == true
    }

    suspend fun register(
        authority: PushAuthority?,
        provider: PushProvider,
        token: String,
        notificationPreference: NotificationPreference? = null,
        locale: String? = null,
    ): PushRegistrationOutcome {
        if (provider != PushProvider.FCM) return PushRegistrationOutcome.UnsupportedProvider
        if (token.isBlank()) return PushRegistrationOutcome.InvalidToken
        val active = authority ?: return PushRegistrationOutcome.NoActiveSession
        val prerequisite = mutex.withLock {
            val existing = store.load()
            if (existing != null && existing.ownerScopeId != active.ownerScopeId) {
                return@withLock PushRegistrationOutcome.BlockedByRetiringOwner
            }
            if (activeAuthority != active) return@withLock PushRegistrationOutcome.NoActiveSession
            if (existing?.pendingUnregister == true) return@withLock PushRegistrationOutcome.BlockedByRetiringOwner
            if (existing?.ownerScopeId == active.ownerScopeId && existing.token == token && existing.registered && !existing.pendingUnregister) {
                return@withLock PushRegistrationOutcome.Registered
            }
            store.save(StoredPushToken(active.ownerScopeId, token, registered = false, pendingUnregister = false, retryEligibleAtMs = nowMs(), notificationPreference = notificationPreference, locale = locale, transportPending = true))
            null
        }
        if (prerequisite != null) return prerequisite
        if (mutex.withLock { activeAuthority != active }) return PushRegistrationOutcome.NoActiveSession
        return try {
            val result = api.register(active.chatToken, token, notificationPreference, locale)
            mutex.withLock {
                if (activeAuthority != active) return@withLock PushRegistrationOutcome.NoActiveSession
                val current = store.load()
                if (current?.ownerScopeId != active.ownerScopeId ||
                    current.token != token ||
                    current.pendingUnregister ||
                    current.registered
                ) return@withLock PushRegistrationOutcome.NoActiveSession
                when (result) {
                    is ApiSuccess -> {
                        store.save(current.copy(registered = true, retryDirective = null, retryEligibleAtMs = null, retryAttempt = 0, transportPending = false))
                        PushRegistrationOutcome.Registered
                    }
                    is ApiFailure -> persistServerFailure(active.ownerScopeId, token, false, result.error.retry.directive, result.error.retry.retryAfterMs)
                }
            }
        } catch (_: IOException) {
            mutex.withLock {
                if (activeAuthority != active) return@withLock PushRegistrationOutcome.NoActiveSession
                val current = store.load()
                if (current?.ownerScopeId != active.ownerScopeId || current.token != token ||
                    current.pendingUnregister || current.registered
                ) return@withLock PushRegistrationOutcome.NoActiveSession
                store.save(current.copy(retryEligibleAtMs = nowMs() + localBackoffMs(1), retryAttempt = 1, transportPending = true))
                PushRegistrationOutcome.QueuedForReconciliation
            }
        } catch (_: ProtocolViolation) {
            PushRegistrationOutcome.InvalidResponse
        }
    }

    /** Blocks any later association with this owner before session logout/account switch proceeds. */
    suspend fun retireOwner(authority: PushAuthority?): PushRegistrationOutcome = mutex.withLock {
        val existing = store.load() ?: return@withLock PushRegistrationOutcome.NoToken
        if (authority == null || existing.ownerScopeId != authority.ownerScopeId) {
            // A stale caller may never unregister a token under a different owner.
            return@withLock PushRegistrationOutcome.NoActiveSession
        }
        if (activeAuthority == authority) activeAuthority = null
        val retiring = existing.copy(pendingUnregister = true)
        store.save(retiring)
        return@withLock try {
            when (val result = api.unregister(authority.chatToken)) {
                is ApiSuccess -> { store.clear(); PushRegistrationOutcome.Unregistered }
                is ApiFailure -> persistServerFailure(existing.ownerScopeId, existing.token, true, result.error.retry.directive, result.error.retry.retryAfterMs)
            }
        } catch (_: IOException) {
            store.save(
                retiring.copy(
                    transportPending = true,
                    retryEligibleAtMs = nowMs() + localBackoffMs(retiring.retryAttempt + 1),
                    retryAttempt = retiring.retryAttempt + 1,
                ),
            )
            PushRegistrationOutcome.QueuedForReconciliation
        } catch (_: ProtocolViolation) {
            PushRegistrationOutcome.InvalidResponse
        }
    }

    /** Recovery-only unlink. Server gates are honoured before any old-session bearer is used. */
    suspend fun reconcileUnregister(authority: PushAuthority, freshBearer: Boolean): PushRegistrationOutcome = mutex.withLock {
        val existing = store.load() ?: return@withLock PushRegistrationOutcome.NoToken
        if (!existing.pendingUnregister || existing.ownerScopeId != authority.ownerScopeId) return@withLock PushRegistrationOutcome.NoActiveSession
        when (existing.retryDirective) {
            RetryDirective.NEVER, RetryDirective.AFTER_ATTESTATION, RetryDirective.AFTER_FULL_SYNC -> return@withLock PushRegistrationOutcome.PendingServer(checkNotNull(existing.retryDirective))
            RetryDirective.AFTER_TOKEN_REFRESH -> if (!freshBearer || existing.retryAttempt > 1) return@withLock PushRegistrationOutcome.PendingServer(RetryDirective.AFTER_TOKEN_REFRESH)
            RetryDirective.AFTER_BACKOFF -> if ((existing.retryEligibleAtMs ?: Long.MAX_VALUE) > nowMs()) return@withLock PushRegistrationOutcome.PendingServer(RetryDirective.AFTER_BACKOFF)
            null -> if (existing.transportPending && (existing.retryEligibleAtMs ?: Long.MAX_VALUE) > nowMs()) return@withLock PushRegistrationOutcome.QueuedForReconciliation
        }
        try {
            when (val result = api.unregister(authority.chatToken)) {
                is ApiSuccess -> { store.clear(); PushRegistrationOutcome.Unregistered }
                is ApiFailure -> persistServerFailure(existing.ownerScopeId, existing.token, true, result.error.retry.directive, result.error.retry.retryAfterMs)
            }
        } catch (_: IOException) {
            val attempt = existing.retryAttempt + 1
            store.save(existing.copy(transportPending = true, retryEligibleAtMs = nowMs() + localBackoffMs(attempt), retryAttempt = attempt))
            PushRegistrationOutcome.QueuedForReconciliation
        } catch (_: ProtocolViolation) { PushRegistrationOutcome.InvalidResponse }
    }

    private suspend fun persistServerFailure(ownerScopeId: String, token: String, pendingUnregister: Boolean, directive: RetryDirective, retryAfterMs: Long?): PushRegistrationOutcome {
        val previous = store.load()
        val attempt = (previous?.retryAttempt ?: 0) + 1
        val eligible = if (directive == RetryDirective.AFTER_BACKOFF) nowMs() + (retryAfterMs ?: (1_000L shl (attempt - 1).coerceAtMost(5))) else null
        store.save(StoredPushToken(ownerScopeId, token, registered = false, pendingUnregister = pendingUnregister, retryDirective = directive, retryEligibleAtMs = eligible, retryAttempt = attempt, notificationPreference = previous?.notificationPreference, locale = previous?.locale))
        return if (directive == RetryDirective.NEVER) PushRegistrationOutcome.TerminalServerFailure
        else PushRegistrationOutcome.PendingServer(directive)
    }

    /** Lifecycle may retry only the documented safe registration/backoff case; it never resumes logout. */
    suspend fun reconcileEligible(authority: PushAuthority?): PushRegistrationOutcome {
        val active = authority ?: return PushRegistrationOutcome.NoActiveSession
        val existing = mutex.withLock {
            if (activeAuthority != active) return@withLock null
            store.load()
        } ?: return PushRegistrationOutcome.NoToken
        if (existing.ownerScopeId != active.ownerScopeId || existing.pendingUnregister) return PushRegistrationOutcome.BlockedByRetiringOwner
        if ((existing.retryDirective != RetryDirective.AFTER_BACKOFF && !existing.transportPending) || (existing.retryEligibleAtMs ?: Long.MAX_VALUE) > nowMs()) {
            return existing.retryDirective?.let(PushRegistrationOutcome::PendingServer) ?: PushRegistrationOutcome.NoToken
        }
        if (mutex.withLock { activeAuthority != active || store.load() != existing }) {
            return PushRegistrationOutcome.NoActiveSession
        }
        return try {
            val result = api.register(active.chatToken, existing.token, existing.notificationPreference, existing.locale)
            mutex.withLock {
                if (activeAuthority != active || store.load() != existing) return@withLock PushRegistrationOutcome.NoActiveSession
                when (result) {
                    is ApiSuccess -> {
                        store.save(existing.copy(registered = true, retryDirective = null, retryEligibleAtMs = null, transportPending = false))
                        PushRegistrationOutcome.Registered
                    }
                    is ApiFailure -> persistServerFailure(existing.ownerScopeId, existing.token, false, result.error.retry.directive, result.error.retry.retryAfterMs)
                }
            }
        } catch (_: IOException) {
            mutex.withLock {
                if (activeAuthority != active || store.load() != existing) return@withLock PushRegistrationOutcome.NoActiveSession
                val attempt = existing.retryAttempt + 1
                store.save(existing.copy(transportPending = true, retryEligibleAtMs = nowMs() + localBackoffMs(attempt), retryAttempt = attempt))
                PushRegistrationOutcome.QueuedForReconciliation
            }
        } catch (_: ProtocolViolation) {
            PushRegistrationOutcome.InvalidResponse
        }
    }

    private fun localBackoffMs(attempt: Int): Long = 1_000L shl (attempt - 1).coerceIn(0, 5)

    suspend fun handlePayload(
        payload: Map<String, String>,
        authority: PushAuthority?,
        refetchTranscript: suspend (PushAuthority, String, String) -> Boolean,
        isStillAuthorised: suspend (PushAuthority) -> Boolean = { true },
    ): PushPayloadOutcome {
        if (!payload.keys.any { it in ONLO_KEYS }) return PushPayloadOutcome.NotOnlo
        if (payload.keys != ONLO_KEYS) return PushPayloadOutcome.Malformed
        val conversationId = payload[CONVERSATION_ID]?.takeIf(String::isNotBlank) ?: return PushPayloadOutcome.Malformed
        val messageId = payload[MESSAGE_ID]?.takeIf(String::isNotBlank) ?: return PushPayloadOutcome.Malformed
        if (payload[NOTIFICATION_TYPE] != MESSAGE_AVAILABLE) return PushPayloadOutcome.Malformed
        val active = authority ?: return PushPayloadOutcome.NoActiveSession
        return try {
            if (!refetchTranscript(active, conversationId, messageId)) PushPayloadOutcome.NotAuthorised
            else if (!isStillAuthorised(active)) PushPayloadOutcome.NoActiveSession
            else PushPayloadOutcome.NavigationIntent(conversationId, messageId)
        } catch (_: IOException) {
            PushPayloadOutcome.RefetchFailed
        } catch (_: ProtocolViolation) {
            PushPayloadOutcome.RefetchFailed
        }
    }

    private companion object {
        const val CONVERSATION_ID = "conversationId"
        const val MESSAGE_ID = "messageId"
        const val NOTIFICATION_TYPE = "notificationType"
        const val MESSAGE_AVAILABLE = "message_available"
        val ONLO_KEYS = setOf(CONVERSATION_ID, MESSAGE_ID, NOTIFICATION_TYPE)
    }
}
