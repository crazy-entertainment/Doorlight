package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class NearbyRadioStartsTest {
    @Test fun hideStopsFirstLateSuccessBeforeSecondTaskCompletes() {
        val starts = NearbyRadioStarts()
        starts.begin(); starts.submitted(); starts.submitted()
        assertTrue(starts.finished(success = true, current = false))
        assertEquals(1, starts.pending)
        assertThrows(IllegalStateException::class.java) { starts.begin() }
        assertTrue(starts.finished(success = true, current = false))
        assertEquals(0, starts.pending)
        starts.begin(); starts.submitted(); starts.submitted()
        assertFalse(starts.finished(success = true, current = true))
        assertFalse(starts.finished(success = true, current = true))
    }

    @Test fun oneFailedStartStopsItsSuccessfulSibling() {
        val starts = NearbyRadioStarts()
        starts.begin(); starts.submitted(); starts.submitted()
        assertTrue(starts.finished(success = false, current = true))
        assertTrue(starts.finished(success = true, current = true))
        assertEquals(0, starts.pending)
        starts.begin()
        assertFalse(starts.failed)
    }
}
