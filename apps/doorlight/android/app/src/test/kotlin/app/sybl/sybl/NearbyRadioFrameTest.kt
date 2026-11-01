package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class NearbyRadioFrameTest {
    @Test fun envelopeUsesNetworkByteOrderAndPreservesPayload() {
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 9, 8), NearbyRadioFrame.encode(0x01020304, byteArrayOf(9, 8)))
        assertTrue(NearbyRadioFrame.valid(NearbyRadioFrame.encode(-1, ByteArray(508))))
        assertFalse(NearbyRadioFrame.valid(ByteArray(4)))
        assertFalse(NearbyRadioFrame.valid(ByteArray(513)))
    }
    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizePayload() { NearbyRadioFrame.encode(1, ByteArray(509)) }
    @Test(expected = IllegalArgumentException::class)
    fun rejectsEmptyPayload() { NearbyRadioFrame.encode(1, byteArrayOf()) }
}
