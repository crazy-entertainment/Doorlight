package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class NearbyRadioAnnouncementsTest {
    private val ping = NearbyRadioFrame.encode(1, ByteArray(60) { 7 })
    private val normal = NearbyRadioFrame.encode(2, byteArrayOf(8))

    @Test fun heartbeatDoesNotReplacePendingPingAndCompletedReadRestoresPresence() {
        val box = NearbyRadioAnnouncements()
        box.put(ping, true, 0)
        box.put(normal, false, 1500)
        assertArrayEquals(ping, box.read("a", 2000))
        box.servedRead("a", ping, 0, 23, true, 2000)
        assertArrayEquals(ping, box.read("a", 2100)) // interrupted long read retries
        box.servedRead("a", ping, 44, 23, false, 2200)
        assertArrayEquals(ping, box.read("a", 2300))
        box.servedRead("a", ping, 44, 23, true, 2400)
        assertArrayEquals(normal, box.read("a", 2500))
        assertArrayEquals(ping, box.read("b", 2500))
    }

    @Test fun expiryAndHideCannotReplayPing() {
        val box = NearbyRadioAnnouncements()
        box.put(ping, true, 0)
        assertArrayEquals(ping, box.read("a", 29999))
        assertTrue(box.read("a", 30000).isEmpty())
        box.put(normal, false, 30001)
        assertArrayEquals(normal, box.read("a", 30002))
        box.put(ping, true, 30003)
        box.clear()
        assertTrue(box.read("a", 30004).isEmpty())
    }

    @Test fun newerPingReplacesPendingWaveAndOldReadCannotConsumeIt() {
        val box = NearbyRadioAnnouncements()
        box.put(ping, true, 0)
        val next = NearbyRadioFrame.encode(3, byteArrayOf(9))
        box.put(next, true, 1)
        box.served("a", ping, 2)
        assertArrayEquals(next, box.read("a", 3))
        box.served("a", next, 4)
        box.put(ping, true, 5)
        assertArrayEquals(ping, box.read("a", 6))
    }

    @Test fun readerLimitNeverSuppressesOrdinaryPresence() {
        val box = NearbyRadioAnnouncements()
        box.put(ping, true, 0)
        box.put(normal, false, 1)
        repeat(64) { box.served("peer$it", box.read("peer$it", 2), 2) }
        assertArrayEquals(normal, box.read("overflow", 3))
        box.put(ping, true, 4)
        assertArrayEquals(ping, box.read("overflow", 5))
    }
}
