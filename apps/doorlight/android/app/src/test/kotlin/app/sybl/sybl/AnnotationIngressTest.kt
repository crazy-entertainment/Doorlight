package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AnnotationIngressTest {
    @Test fun stalledUiAndSustainedFloodHaveIndependentBounds() {
        val queue = AnnotationIngress()
        repeat(128) { assertTrue(queue.admit(100, 0)) }
        assertFalse(queue.admit(100, 100_000))
        repeat(128) { queue.delivered(100) }
        assertTrue(queue.admit(100, 100_000))
        val rate = AnnotationIngress()
        repeat(128) { assertTrue(rate.admit(100, 0)); rate.delivered(100) }
        assertFalse(rate.admit(100, 0))
        assertTrue(rate.admit(100, 1000))
        assertFalse(rate.admit(65537, 1000))
        val bytes = AnnotationIngress()
        repeat(16) { assertTrue(bytes.admit(65536, 0)) }
        assertFalse(bytes.admit(1, 1000))
        repeat(16) { bytes.delivered(65536) }
        assertTrue(bytes.admit(6000, 1000))
    }
}
