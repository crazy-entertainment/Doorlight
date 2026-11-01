package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class ControlMessageIngressTest {
    @Test fun `size and all packet rate admission precede downstream work`() {
        val admission = ControlMessageAdmission()
        val peer = listOf("local", "call", "peer")
        assertFalse(admission.admit(peer, 6001, 1000))
        repeat(64) { assertTrue(admission.admit(peer, 6000, 1000)) }
        assertFalse(admission.admit(peer, 1, 1000))
        assertTrue(admission.admit(listOf("local", "call", "other"), 1, 1000))
        assertTrue(admission.admit(peer, 1, 1010))
    }

    @Test fun `one bounded drain yields to local Stop and preserves admitted order`() {
        val main = java.util.ArrayDeque<Runnable>()
        val ingress = ControlMessageQueue { main.add(it); true }
        val peer = listOf("local", "call", "account", "device")
        val delivered = mutableListOf<Int>()
        repeat(10_000) { index -> ingress.offer(peer, null, Runnable { delivered.add(index) }) }
        assertEquals(32, ingress.pending)
        assertEquals(1, main.size)
        var stopped = false
        main.add(Runnable { stopped = true })
        main.removeFirst().run()
        assertEquals((0..7).toList(), delivered)
        main.removeFirst().run()
        assertTrue(stopped)
        while (main.isNotEmpty()) main.removeFirst().run()
        assertEquals((0..31).toList(), delivered)
        assertEquals(0, ingress.pending)
    }

    @Test fun `requests coalesce and responses cannot fill stalled executor`() {
        val main = java.util.ArrayDeque<Runnable>()
        val ingress = ControlMessageQueue { main.add(it); true }
        repeat(10_000) { ingress.offer(listOf("a", "c", "p", "d"), "request", Runnable {}) }
        assertEquals(1, ingress.pending)
        val responses = ControlResponseAdmission()
        assertTrue(responses.acquire(1000, true))
        repeat(10_000) { assertFalse(responses.acquire(1000, true)) }
        repeat(7) { assertTrue(responses.acquire(1000, false)) }
        assertFalse(responses.acquire(2000, true))
        repeat(8) { responses.delivered() }
        assertTrue(responses.acquire(2000, true))
    }
}
