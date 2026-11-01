package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class NativeAuthorityLeaseTest {
    @Test fun `reads cannot renew a snapshot past its maximum age`() {
        var now = 1000L
        val lease = NativeAuthorityLease<String> { now }
        assertTrue(lease.publish("owner", now))
        now += 99
        assertFalse(lease.refreshDue())
        now++
        assertTrue(lease.refreshDue())
        now += 149
        assertEquals("owner", lease.current())
        now++
        assertNull(lease.current())
        assertNull(lease.current())
    }

    @Test fun `a stalled verification cannot create fresh authority on completion`() {
        var now = 1000L
        val lease = NativeAuthorityLease<String> { now }
        val started = now
        now += 251
        assertFalse(lease.publish("late", started))
        assertNull(lease.current())
        assertTrue(lease.publish("fresh", now))
        lease.clear()
        assertNull(lease.current())
    }

    @Test fun `clock reversal never extends authority`() {
        var now = 1000L
        val lease = NativeAuthorityLease<String> { now }
        lease.publish("owner", now)
        now--
        assertNull(lease.current())
        assertTrue(lease.refreshDue())
    }
}
