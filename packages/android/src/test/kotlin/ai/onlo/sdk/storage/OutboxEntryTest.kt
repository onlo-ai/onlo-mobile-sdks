package ai.onlo.sdk.storage

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class OutboxEntryTest {
    @Test
    fun `retry transition retains original client message id`() {
        val queued = OutboxEntryFactory.create(
            ownerScope = OwnerScope.Identified("opaque-owner-a"),
            localConversationId = "local-conversation-1",
            message = "test message",
            attachments = emptyList(),
            nowMs = 100,
        )

        val retry = queued.copy(
            state = OutboxState.FAILED_RETRYABLE,
            attemptCount = 1,
            nextAttemptAtMs = 200,
            lastErrorCode = "network_unavailable",
        )

        assertEquals(queued.clientMessageId, retry.clientMessageId)
        assertEquals(queued.ownerScope, retry.ownerScope)
    }

    @Test
    fun `opaque owner partition survives session credential rotation`() {
        val beforeRotation = OwnerScope.Identified("opaque-owner-a")
        val afterRotation = OwnerScope.Identified("opaque-owner-a")

        assertEquals(beforeRotation.storageKey(), afterRotation.storageKey())
    }

    @Test
    fun `anonymous and identified partitions are distinct even for one installation lifecycle`() {
        val anonymous = OwnerScope.Anonymous("opaque-anonymous-owner")
        val identified = OwnerScope.Identified("opaque-identified-owner")

        assertEquals(false, anonymous.storageKey() == identified.storageKey())
    }

    @Test
    fun `outbox rejects a non uuid client id before persistence`() {
        assertFailsWith<IllegalArgumentException> {
            OutboxEntry(
                ownerScope = OwnerScope.Anonymous("opaque-owner"),
                clientMessageId = "not-a-uuid",
                localConversationId = "local-conversation-1",
                message = "test message",
                attachments = emptyList(),
                createdAtMs = 1,
                orderingKey = 1,
            )
        }
    }
}
