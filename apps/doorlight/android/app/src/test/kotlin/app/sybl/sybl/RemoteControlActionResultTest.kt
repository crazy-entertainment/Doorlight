package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class RemoteControlActionResultTest {
    @Test fun actualBooleanRefusalIsNotAuthoritySuccess() {
        val guard: (() -> Unit) -> Boolean = { action -> action(); true }
        assertEquals(RemoteControlActionResult.REFUSED, executeRemoteControlAction(guard) { false })
        assertEquals(RemoteControlActionResult.APPLIED, executeRemoteControlAction(guard) { true })
        assertEquals(RemoteControlActionResult.REFUSED, executeRemoteControlAction(guard) {
            throw IllegalStateException("private-input-sentinel")
        })
    }

    @Test fun retiredAuthorityNeverInvokesTheAdapter() {
        var calls = 0
        assertEquals(RemoteControlActionResult.STALE, executeRemoteControlAction({ false }) {
            calls++
            true
        })
        assertEquals(0, calls)
    }
}
