package ai.onlo.sdk

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class NativeLifecycleBindingTest {
    @Test
    fun `network recovery fires only after observed offline to online transition`() {
        val gate = NetworkRecoveryGate()

        assertFalse(gate.onAvailable(true))
        assertFalse(gate.onAvailable(true))
        assertFalse(gate.onAvailable(false))
        assertTrue(gate.onAvailable(true))
        assertFalse(gate.onAvailable(true))
    }

    @Test
    fun `initial offline observation is not a recovery`() {
        val gate = NetworkRecoveryGate()

        assertFalse(gate.onAvailable(false))
        assertTrue(gate.onAvailable(true))
    }
}
