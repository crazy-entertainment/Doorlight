package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CallRequestWireTest {
    @Test
    fun `fresh version one request is accepted`() {
        val now = 1_800_000L
        val encoded = CallRequestWire.encode(now - 5_000L)

        assertEquals(now - 5_000L, CallRequestWire.decode(encoded, now)?.timestampMs)
    }

    @Test
    fun `stale future malformed and oversized requests are rejected`() {
        val now = 1_800_000L

        assertNull(CallRequestWire.decode(CallRequestWire.encode(now - 120_001L), now))
        assertNull(CallRequestWire.decode(CallRequestWire.encode(now + 30_001L), now))
        assertNull(CallRequestWire.decode("{\"v\":2,\"ts\":$now}", now))
        assertNull(CallRequestWire.decode("x".repeat(257), now))
    }
}
