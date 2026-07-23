package ai.onlo.sdk

import ai.onlo.sdk.logging.SafeLogCode
import ai.onlo.sdk.logging.SafeLogEvent
import ai.onlo.sdk.logging.requiredLevel
import ai.onlo.sdk.logging.safeLogField
import kotlin.test.Test
import kotlin.test.assertEquals

class LoggingTest {
    @Test
    fun `safe event codes map to bounded public levels`() {
        assertEquals(
            OnloLogLevel.VERBOSE,
            SafeLogEvent(SafeLogCode.SESSION_EXCHANGE_STARTED, "0.1.0").requiredLevel(),
        )
        assertEquals(
            OnloLogLevel.INFO,
            SafeLogEvent(SafeLogCode.SESSION_EXCHANGE_SUCCEEDED, "0.1.0").requiredLevel(),
        )
        assertEquals(
            OnloLogLevel.ERROR,
            SafeLogEvent(SafeLogCode.SESSION_EXCHANGE_FAILED, "0.1.0").requiredLevel(),
        )
        assertEquals("request_injected", "request\ninjected".safeLogField())
    }
}
