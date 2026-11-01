package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Test

class ConferenceInfoIngressTest {
    @Test fun burstKeepsOneTimerAndOneWorkerTaskThenDeliversLatestState() {
        val timers = ArrayDeque<Runnable>()
        val worker = ArrayDeque<Runnable>()
        val delivered = mutableListOf<Int>()
        val ingress = ConferenceInfoIngress(
            schedule = { timers.addLast(it); true },
            dispatch = { worker.addLast(it) },
        )

        repeat(1_000) { value -> ingress.offer(Runnable { delivered.add(value) }) }
        assertEquals(1, timers.size)
        timers.removeFirst().run()
        assertEquals(1, worker.size)
        repeat(1_000) { value -> ingress.offer(Runnable { delivered.add(value + 1_000) }) }
        assertEquals(0, timers.size)
        assertEquals(1, worker.size)

        worker.removeFirst().run()
        assertEquals(listOf(999), delivered)
        assertEquals(1, timers.size)
        timers.removeFirst().run()
        worker.removeFirst().run()
        assertEquals(listOf(999, 1_999), delivered)
        assertEquals(0, timers.size)
        assertEquals(0, worker.size)

        ingress.offer(Runnable { delivered.add(2_000) })
        assertEquals(1, timers.size)
        timers.removeFirst().run()
        worker.removeFirst().run()
        assertEquals(listOf(999, 1_999, 2_000), delivered)
    }

    @Test fun failedQueryReleasesTheGate() {
        val timers = ArrayDeque<Runnable>()
        val worker = ArrayDeque<Runnable>()
        val ingress = ConferenceInfoIngress(
            schedule = { timers.addLast(it); true },
            dispatch = { worker.addLast(it) },
        )
        ingress.offer(Runnable { error("daemon query failed") })
        timers.removeFirst().run()
        try { worker.removeFirst().run() } catch (_: IllegalStateException) {}
        ingress.offer(Runnable {})
        assertEquals(1, timers.size)
    }
}
