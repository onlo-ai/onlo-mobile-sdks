package ai.onlo.sdk.messenger

import ai.onlo.sdk.OpenConversationOutcome
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class OnloMessengerDecisionTest {
    @Test
    fun `open outcome is preserved and only opened attaches the messenger`() {
        val outcomes = listOf(
            OpenConversationOutcome.Opened,
            OpenConversationOutcome.NoActiveSession,
            OpenConversationOutcome.NotAuthorised,
            OpenConversationOutcome.Unavailable,
        )

        outcomes.forEach { outcome ->
            val decision = conversationOpenDecision(outcome)
            assertEquals(outcome, decision.outcome)
            assertFalse(decision.clearPendingPresentation)
            if (outcome is OpenConversationOutcome.Opened) {
                assertTrue(decision.attachMessenger)
            } else {
                assertFalse(decision.attachMessenger)
            }
        }
    }

    @Test
    fun `activity invalidation after authorization clears pending presentation`() {
        val decision = conversationOpenDecision(
            OpenConversationOutcome.Opened,
            hostAvailable = false,
        )

        assertEquals(OpenConversationOutcome.Unavailable, decision.outcome)
        assertFalse(decision.attachMessenger)
        assertTrue(decision.clearPendingPresentation)
    }

    @Test
    fun `empty or unknown optional surfaces stay hidden`() {
        assertEquals(
            MessengerSurfaceVisibility(faq = false, helpCenter = false),
            messengerSurfaceVisibility(
                faqEnabled = true,
                validFaqCount = 0,
                helpCenterTopicCount = null,
            ),
        )
        assertEquals(
            MessengerSurfaceVisibility(faq = true, helpCenter = false),
            messengerSurfaceVisibility(
                faqEnabled = true,
                validFaqCount = 1,
                helpCenterTopicCount = 0,
            ),
        )
        assertEquals(
            MessengerSurfaceVisibility(faq = true, helpCenter = true),
            messengerSurfaceVisibility(
                faqEnabled = true,
                validFaqCount = 1,
                helpCenterTopicCount = 1,
            ),
        )
    }

    @Test
    fun `dashboard dark mode selects the native dark palette independent of OS mode`() {
        assertTrue(messengerUsesDarkPalette(serverDarkEnabled = true))
        assertFalse(messengerUsesDarkPalette(serverDarkEnabled = false))
    }
}
