package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DaemonWorkerDiagnosticsTest {
    @Test
    fun `queued running and finished task records wait and run without a stall`() {
        val events = ArrayList<String>()
        val tracker = DiagnosticTaskTracker("worker", sink = events::add)

        val sequence = tracker.queued("PLACE_CALL", "c1", 5_000, nowMs = 100)
        tracker.started(sequence, nowMs = 130)
        assertTrue(tracker.pollStalls(nowMs = 4_999).isEmpty())
        tracker.finished(sequence, nowMs = 180)

        assertEquals(3, events.size)
        assertTrue(events[0].contains("QUEUE lane=worker seq=1 op=PLACE_CALL call=c1 depth=1"))
        assertTrue(events[1].contains("waitMs=30"))
        assertTrue(events[2].contains("runMs=50 outcome=ok depth=0"))
        assertEquals("none", tracker.pendingSummary())
    }

    @Test
    fun `queued stall is reported once and exposes the operation ahead of it`() {
        val tracker = DiagnosticTaskTracker("worker")
        val first = tracker.queued("PLACE_CALL", null, 5_000, nowMs = 0)
        tracker.started(first, nowMs = 1)
        tracker.queued("HANG_UP", "c1", 5_000, nowMs = 10)

        val stalls = tracker.pollStalls(nowMs = 5_010)

        assertEquals(2, stalls.size)
        assertEquals(DiagnosticPhase.RUNNING, stalls[0].phase)
        assertEquals("PLACE_CALL", stalls[0].operation)
        assertEquals(DiagnosticPhase.QUEUED, stalls[1].phase)
        assertEquals("HANG_UP", stalls[1].operation)
        assertEquals("c1", stalls[1].callToken)
        assertTrue(tracker.pollStalls(nowMs = 50_000).isEmpty())
        assertEquals("1:PLACE_CALL:R,2:HANG_UP:c1:Q", tracker.pendingSummary())
    }

    @Test
    fun `running stall retains the observed worker thread`() {
        val tracker = DiagnosticTaskTracker("worker")
        val sequence = tracker.queued("REFUSE_CALL", "c2", 100, nowMs = 5)
        val thread = Thread.currentThread()
        tracker.started(sequence, nowMs = 10, thread = thread)

        val stall = tracker.pollStalls(nowMs = 110).single()

        assertEquals(DiagnosticPhase.RUNNING, stall.phase)
        assertEquals(100, stall.elapsedMs)
        assertEquals(thread, stall.thread)
    }

    @Test
    fun `failure is bounded to its class name and still finishes the task`() {
        val events = ArrayList<String>()
        val tracker = DiagnosticTaskTracker("worker", sink = events::add)
        val sequence = tracker.queued("HANG_UP", "c3", 5_000, nowMs = 0)
        tracker.started(sequence, nowMs = 1)

        tracker.finished(sequence, nowMs = 2, failure = IllegalStateException("secret payload"))

        assertTrue(events.last().contains("outcome=IllegalStateException"))
        assertFalse(events.last().contains("secret payload"))
        assertTrue(tracker.pollStalls(nowMs = 10_000).isEmpty())
    }

    @Test
    fun `call tokens are stable opaque bounded labels`() {
        val tokens = DiagnosticCallTokens(limit = 2)

        assertNull(tokens.token(""))
        assertEquals("c1", tokens.token("raw-call-a"))
        assertEquals("c1", tokens.token("raw-call-a"))
        val second = tokens.token("raw-call-b")
        val third = tokens.token("raw-call-c")

        assertEquals("c2", second)
        assertEquals("c3", third)
        assertNotEquals("raw-call-a", tokens.token("raw-call-a"))
    }
}
