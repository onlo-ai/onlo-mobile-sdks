package ai.onlo.sdk.storage

import ai.onlo.sdk.protocol.ChatAttachment
import ai.onlo.sdk.protocol.MAX_MOBILE_IMAGES_PER_MESSAGE
import java.util.UUID

/** A partition key is never derived from unsigned profile data. */
internal sealed interface OwnerScope {
    fun storageKey(): String

    data class Anonymous(val opaqueId: String) : OwnerScope {
        override fun storageKey(): String = "anonymous:$opaqueId"
    }

    data class Identified(val opaqueId: String) : OwnerScope {
        override fun storageKey(): String = "identified:$opaqueId"
    }
}

internal enum class OutboxState {
    QUEUED,
    SENDING,
    ACCEPTED,
    RECONCILED,
    FAILED_RETRYABLE,
    FAILED_TERMINAL,
    CANCELLED,
}

internal data class PersistenceAuthority(
    val ownerScope: OwnerScope,
    val sessionGeneration: Long,
    val sessionId: String,
    val bearerContext: String,
)

/**
 * Durable send record. The id is generated once before any network work and is immutable across
 * state transitions and retries.
 */
internal data class OutboxEntry(
    val ownerScope: OwnerScope,
    val clientMessageId: String,
    val localConversationId: String,
    val message: String,
    val attachments: List<ChatAttachment>,
    val stagedAttachments: List<StagedAttachment> = emptyList(),
    val createdAtMs: Long,
    val orderingKey: Long,
    val state: OutboxState = OutboxState.QUEUED,
    val attemptCount: Int = 0,
    val nextAttemptAtMs: Long? = null,
    val lastErrorCode: String? = null,
    val serverMessageId: String? = null,
    val serverConversationId: String? = null,
) {
    init {
        require(runCatching { UUID.fromString(clientMessageId) }.isSuccess) { "client_message_id" }
        require(localConversationId.isNotBlank()) { "local_conversation_id" }
        require(attemptCount >= 0) { "attempt_count" }
        require(attachments.size <= MAX_MOBILE_IMAGES_PER_MESSAGE) { "attachment_count" }
    }
}

internal data class StagedAttachment(
    val dataBase64: String,
    val mimeType: String,
    val fileName: String,
    val conversationId: String?,
    val grantExpiresAtMs: Long,
)

internal object OutboxEntryFactory {
    fun create(
        ownerScope: OwnerScope,
        localConversationId: String,
        message: String,
        attachments: List<ChatAttachment>,
        nowMs: Long,
        stagedAttachments: List<StagedAttachment> = emptyList(),
    ): OutboxEntry = OutboxEntry(
        ownerScope = ownerScope,
        clientMessageId = UUID.randomUUID().toString(),
        localConversationId = localConversationId,
        message = message,
        attachments = attachments,
        stagedAttachments = stagedAttachments,
        createdAtMs = nowMs,
        orderingKey = nowMs,
    )
}

/**
 * Persistence contract used by the native send pipeline. A blocked owner cannot return work and
 * therefore cannot send User A's queued work under User B's authenticated session.
 */
internal interface OwnerScopedOutboxStore {
    suspend fun enqueue(entry: OutboxEntry)
    suspend fun eligible(ownerScope: OwnerScope, nowMs: Long, limit: Int): List<OutboxEntry>
    suspend fun markSending(ownerScope: OwnerScope, clientMessageId: String): Boolean
    suspend fun markSendingIfAuthorised(
        authority: PersistenceAuthority,
        clientMessageId: String,
    ): Boolean = markSending(authority.ownerScope, clientMessageId)
    suspend fun replacePendingIfAuthorised(
        authority: PersistenceAuthority,
        entry: OutboxEntry,
    ): Boolean = false
    suspend fun markAccepted(ownerScope: OwnerScope, clientMessageId: String, serverMessageId: String, conversationId: String): Boolean
    suspend fun markAcceptedIfSending(
        authority: PersistenceAuthority,
        clientMessageId: String,
        expectedAttemptCount: Int,
        serverMessageId: String,
        conversationId: String,
    ): Boolean = markAccepted(authority.ownerScope, clientMessageId, serverMessageId, conversationId)
    suspend fun acceptedAwaitingReconciliation(ownerScope: OwnerScope): List<OutboxEntry>
    suspend fun markReconciled(ownerScope: OwnerScope, clientMessageId: String)
    suspend fun markReconciledIfAccepted(
        authority: PersistenceAuthority,
        clientMessageId: String,
        expectedAttemptCount: Int,
    ): Boolean {
        markReconciled(authority.ownerScope, clientMessageId)
        return true
    }
    suspend fun markRetryableFailure(
        ownerScope: OwnerScope,
        clientMessageId: String,
        errorCode: String,
        nextAttemptAtMs: Long,
    )
    suspend fun markRetryableFailureIfSending(
        authority: PersistenceAuthority,
        clientMessageId: String,
        expectedAttemptCount: Int,
        errorCode: String,
        nextAttemptAtMs: Long,
    ): Boolean {
        markRetryableFailure(authority.ownerScope, clientMessageId, errorCode, nextAttemptAtMs)
        return true
    }

    suspend fun markTerminalFailure(ownerScope: OwnerScope, clientMessageId: String, errorCode: String)
    suspend fun markTerminalFailureIfSending(
        authority: PersistenceAuthority,
        clientMessageId: String,
        expectedAttemptCount: Int,
        errorCode: String,
    ): Boolean {
        markTerminalFailure(authority.ownerScope, clientMessageId, errorCode)
        return true
    }
    suspend fun recoverInterruptedSends(ownerScope: OwnerScope, nowMs: Long)
    suspend fun recoverInterruptedSendsIfAuthorised(
        authority: PersistenceAuthority,
        nowMs: Long,
    ): Boolean {
        recoverInterruptedSends(authority.ownerScope, nowMs)
        return true
    }
    suspend fun blockOwner(ownerScope: OwnerScope)
    /** Atomically makes a retiring partition inaccessible and removes its queued payloads. */
    suspend fun blockAndPurgeOwner(ownerScope: OwnerScope)
    suspend fun purgeOwner(ownerScope: OwnerScope)
    suspend fun clearAll()
    suspend fun replaceTranscript(ownerScope: OwnerScope, conversationId: String, payload: String)
    suspend fun activateAuthority(authority: PersistenceAuthority) = Unit
    suspend fun revokeAuthority(ownerScope: OwnerScope) = Unit
    suspend fun replaceTranscriptIfAuthorised(
        authority: PersistenceAuthority,
        conversationId: String,
        payload: String,
    ): Boolean {
        replaceTranscript(authority.ownerScope, conversationId, payload)
        return true
    }
    suspend fun reconcileAcceptedIfAuthorised(
        authority: PersistenceAuthority,
        clientMessageId: String,
        expectedServerMessageId: String,
        conversationId: String,
        payload: String,
    ): Boolean {
        replaceTranscript(authority.ownerScope, conversationId, payload)
        markReconciled(authority.ownerScope, clientMessageId)
        return true
    }
    suspend fun transcript(ownerScope: OwnerScope, conversationId: String): String?
}

internal class OwnerBlockedException : IllegalStateException("owner_blocked")
internal class TranscriptStorageUnreadableException : IllegalStateException("transcript_unreadable")
