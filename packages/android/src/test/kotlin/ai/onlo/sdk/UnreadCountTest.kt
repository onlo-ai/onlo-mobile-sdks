package ai.onlo.sdk

import ai.onlo.sdk.chat.ConversationSummary
import kotlin.test.Test
import kotlin.test.assertEquals

class UnreadCountTest {
    @Test
    fun `customer unread metadata preserves its row badge`() {
        val summary = ConversationSummary(
            id = "synthetic-conversation",
            sessionId = "synthetic-session",
            title = "Support",
            unread = true,
            unreadCount = 2,
            status = "open",
            updatedAt = "2026-01-01T00:00:00Z",
            messageCount = 3,
            lastMessageRole = null,
        )

        assertEquals(true, summary.unread)
        assertEquals(2, summary.unreadCount)
    }
}
