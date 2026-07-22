package ai.onlo.sdk

import ai.onlo.sdk.chat.ConversationSummary
import ai.onlo.sdk.protocol.ProtocolViolation
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class UnreadCountTest {
    @Test
    fun `sums canonical conversation unread counts without exposing conversation data`() {
        assertEquals(3, totalUnreadCount(listOf(summary(1), summary(2))))
    }

    @Test
    fun `rejects a total that would overflow the framework safe integer`() {
        assertFailsWith<ProtocolViolation> {
            totalUnreadCount(listOf(summary(Int.MAX_VALUE), summary(1)))
        }
    }

    private fun summary(unreadCount: Int) = ConversationSummary(
        id = "fixture-conversation",
        sessionId = "fixture-session",
        title = "[redacted]",
        unread = unreadCount > 0,
        unreadCount = unreadCount,
        status = "open",
        updatedAt = "2026-01-01T00:00:00Z",
        messageCount = unreadCount,
        lastMessageRole = null,
    )
}
