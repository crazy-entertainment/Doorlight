package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PendingRequestGateTest {
    @Test
    fun `duplicate is free and a new request is admitted after the rate window`() {
        val gate = PendingRequestGate(maxPending = 3, maxAdmissionsPerWindow = 2, windowMs = 100)
        assertEquals(PendingRequestAdmission.NEW, gate.admit("a", 0))
        assertEquals(PendingRequestAdmission.DUPLICATE, gate.admit("a", 1))
        assertEquals(PendingRequestAdmission.NEW, gate.admit("b", 2))
        assertEquals(PendingRequestAdmission.REJECTED, gate.admit("c", 3))
        assertEquals(PendingRequestAdmission.NEW, gate.admit("c", 100))
    }

    @Test
    fun `pending count is bounded and failed decisions keep their reserved slot`() {
        val gate = PendingRequestGate(maxPending = 2, maxAdmissionsPerWindow = 4)
        assertEquals(PendingRequestAdmission.NEW, gate.admit("a", 0))
        assertEquals(PendingRequestAdmission.NEW, gate.admit("b", 1))
        assertEquals(PendingRequestAdmission.REJECTED, gate.admit("c", 2))
        assertTrue(gate.remove("a"))
        assertTrue(gate.restore("a"))
        assertFalse(gate.restore("c"))
    }

    @Test
    fun `reservation remains visible until the decision completes`() {
        val gate = PendingRequestGate(maxPending = 1, maxAdmissionsPerWindow = 1)

        assertEquals(PendingRequestAdmission.NEW, gate.admit("a", 0))
        assertTrue(gate.contains("a"))
        assertTrue(gate.remove("a"))
        assertFalse(gate.contains("a"))
    }
}
