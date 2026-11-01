package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class KnownDeviceWireTest {
    private val current = "a".repeat(40)
    private val other = "b".repeat(64)

    @Test
    fun `project bounds and puts current device first`() {
        val known = linkedMapOf(
            other to "Phone",
            "not-a-device" to "Bad",
            current to "This PC",
        )

        val projected = KnownDeviceWire.project(known, current)

        assertEquals(listOf(current, other), projected.map { it["id"] })
        assertEquals(true, projected.first()["current"])
        assertEquals(false, projected.last()["current"])
    }

    @Test
    fun `names reject controls surrogates and oversized utf8`() {
        assertEquals("Phone B", KnownDeviceWire.boundedName(" Phone B "))
        assertEquals("", KnownDeviceWire.boundedName("bad\nname"))
        assertEquals("", KnownDeviceWire.boundedName("\uD800"))
        assertEquals("", KnownDeviceWire.boundedName("é".repeat(65)))
    }

    @Test
    fun `revocation requires an exact known noncurrent fingerprint`() {
        val known = listOf(current, other)
        assertTrue(KnownDeviceWire.canRevoke(other, current, known))
        assertFalse(KnownDeviceWire.canRevoke(current, current, known))
        assertFalse(KnownDeviceWire.canRevoke(current, "", known))
        assertFalse(KnownDeviceWire.canRevoke(other, "", known))
        assertFalse(KnownDeviceWire.canRevoke(other, "unavailable", known))
        assertFalse(KnownDeviceWire.canRevoke("b".repeat(40), current, known))
        assertFalse(KnownDeviceWire.canRevoke("../$other", current, known))
        assertFalse(KnownDeviceWire.canRevoke(other.uppercase(), current, known))
    }
}
