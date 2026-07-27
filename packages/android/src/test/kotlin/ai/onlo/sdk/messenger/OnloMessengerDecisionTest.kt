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
    fun `dark palette requires both dashboard support and system dark mode`() {
        assertTrue(messengerUsesDarkPalette(serverDarkEnabled = true, systemDarkMode = true))
        assertFalse(messengerUsesDarkPalette(serverDarkEnabled = true, systemDarkMode = false))
        assertFalse(messengerUsesDarkPalette(serverDarkEnabled = false, systemDarkMode = true))
    }

    @Test
    fun `messenger defaults to a contained host presentation`() {
        assertEquals(
            OnloMessengerPresentationMode.CONTAINED,
            OnloMessengerOptions().presentationMode,
        )
    }

    @Test
    fun `back dismisses home and returns nested surfaces to home`() {
        assertEquals(MessengerBackAction.DISMISS, messengerBackAction(isHome = true))
        assertEquals(MessengerBackAction.RETURN_HOME, messengerBackAction(isHome = false))
    }

    @Test
    fun `end user messages align right and every support role aligns left`() {
        assertEquals(MessengerMessageAlignment.END, messengerMessageAlignment("user"))
        assertEquals(MessengerMessageAlignment.END, messengerMessageAlignment("USER"))
        assertEquals(MessengerMessageAlignment.START, messengerMessageAlignment("assistant"))
        assertEquals(MessengerMessageAlignment.START, messengerMessageAlignment("operator"))
    }

    @Test
    fun `composer creates widget parity code and link markdown`() {
        assertEquals(
            ComposerInsertion(text = "```\n\n```", cursorOffset = 4),
            codeComposerInsertion(selectedText = ""),
        )
        assertEquals("```\nval value = 1\n```", codeComposerInsertion("val value = 1").text)
        assertEquals(
            "[Onlo](https://onlo.ai/docs)",
            markdownLinkComposerInsertion(" Onlo ", " https://onlo.ai/docs "),
        )
        assertEquals(
            "[https://onlo.ai](https://onlo.ai)",
            markdownLinkComposerInsertion("", "https://onlo.ai"),
        )
    }
}
