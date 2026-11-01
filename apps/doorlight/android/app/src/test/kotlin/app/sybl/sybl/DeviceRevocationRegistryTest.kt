package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class DeviceRevocationRegistryTest {
    private val device = "b".repeat(64)
    private val otherDevice = "c".repeat(64)
    private val owner = Any()

    private fun registry() = DeviceRevocationRegistry().apply { selectAccount("account-a") }

    private fun DeviceRevocationRegistry.begin(deviceId: String = device, now: Long = 0) =
        begin("account-a", deviceId, now, owner) {}

    @Test
    fun `true initiation waits for exact authoritative completion`() = initiationWaits(true)

    @Test
    fun `false initiation waits for exact authoritative completion`() = initiationWaits(false)

    private fun initiationWaits(accepted: Boolean) {
        val registry = registry()
        val first = registry.begin()
        assertNotEquals(0L, first.ticket)
        assertTrue(registry.hasPendingReplies())
        var invoked = false
        registry.invoke(first.ticket, 1) { invoked = true; accepted }
        assertTrue(invoked)
        assertTrue(registry.takeReady(2).isEmpty())
        registry.ended("different-account", device, 0, 3)
        registry.ended("account-a", otherDevice, 0, 3)
        assertTrue(registry.takeReady(3).isEmpty())
        registry.ended("account-a", device, 0, 4)
        val reply = registry.takeReady(4).single().result
        assertEquals(DeviceRevocationStatus.REVOKED, reply.status)
        assertEquals(mapOf("accountId" to "account-a", "deviceId" to device, "status" to "revoked"), reply.toWire())
        assertTrue(registry.takeReady(5).isEmpty())
        assertFalse(registry.hasPendingReplies())
    }

    @Test
    fun `timeout retains exact pair until old callback is consumed`() {
        val registry = registry()
        val old = registry.begin()
        registry.invoke(old.ticket, 1) { true }
        assertEquals(DeviceRevocationStatus.TIMEOUT,
            registry.takeReady(DeviceRevocationRegistry.TIMEOUT_MS).single().result.status)
        assertFalse(registry.hasPendingReplies())  // The native tombstone needs no polling timer.
        assertEquals(0L, registry.begin(now = 40_000).ticket)
        assertEquals(DeviceRevocationStatus.PENDING, registry.begin(now = 40_000).status)
        val independent = registry.begin(otherDevice, 40_001)
        assertNotEquals(0L, independent.ticket)
        registry.ended("account-a", device, 0, 40_002)
        assertTrue(registry.takeReady(40_002).isEmpty())
        val retry = registry.begin(now = 40_003)
        assertNotEquals(0L, retry.ticket)
        assertNotEquals(old.ticket, retry.ticket)
        var staleInvoked = false
        registry.invoke(old.ticket, 40_004) { staleInvoked = true; true }
        assertFalse(staleInvoked)
        registry.invoke(retry.ticket, 40_004) { false }
        assertTrue(registry.takeReady(40_005).isEmpty())
        registry.ended("account-a", device, 2, 40_006)
        assertEquals(DeviceRevocationStatus.NETWORK, registry.takeReady(40_006).single().result.status)
    }

    @Test
    fun `late callback cannot beat an overdue main-thread timer`() {
        val registry = registry()
        val first = registry.begin()
        registry.invoke(first.ticket, 1) { true }
        registry.ended("account-a", device, 0, DeviceRevocationRegistry.TIMEOUT_MS + 1)
        assertEquals(DeviceRevocationStatus.TIMEOUT, registry.takeReady(40_000).single().result.status)
    }

    @Test
    fun `queued and issued requests cannot cross account A B A`() {
        val registry = registry()
        val queued = registry.begin()
        registry.selectAccount("account-b")
        registry.selectAccount("account-a")
        var invoked = false
        registry.invoke(queued.ticket, 1) { invoked = true; true }
        assertFalse(invoked)
        assertEquals(DeviceRevocationStatus.ACCOUNT_CHANGED, registry.takeReady(2).single().result.status)
        val issued = registry.begin(now = 3)
        registry.invoke(issued.ticket, 4) { true }
        registry.selectAccount(null)
        registry.selectAccount("account-a")
        assertEquals(DeviceRevocationStatus.ACCOUNT_CHANGED, registry.takeReady(5).single().result.status)
        assertEquals(0L, registry.begin(now = 6).ticket)
        registry.ended("account-a", device, 0, 7)
        assertTrue(registry.takeReady(7).isEmpty())
    }

    @Test
    fun `synchronous callback precedes a false return`() {
        val registry = registry()
        val first = registry.begin()
        registry.invoke(first.ticket, 1) {
            registry.ended("account-a", device, 1, 1)
            false
        }
        assertEquals(DeviceRevocationStatus.CREDENTIALS, registry.takeReady(2).single().result.status)
        assertNotEquals(0L, registry.begin(now = 3).ticket)
    }

    @Test
    fun `throw after invocation remains ambiguous until callback`() {
        val registry = registry()
        val first = registry.begin()
        registry.invoke(first.ticket, 1) { error("fixture native exception") }
        assertEquals(DeviceRevocationStatus.UNAVAILABLE, registry.takeReady(2).single().result.status)
        assertEquals(0L, registry.begin(now = 3).ticket)
        registry.ended("account-a", device, 2, 4)
        assertTrue(registry.takeReady(4).isEmpty())
        assertNotEquals(0L, registry.begin(now = 5).ticket)
    }

    @Test
    fun `activity cancellation preserves another activity and the native tombstone`() {
        val registry = registry()
        val newerOwner = Any()
        var cancelledReplies = 0
        val issued = registry.begin("account-a", device, 0, owner) {
            assertEquals(DeviceRevocationStatus.UNAVAILABLE, it.status)
            cancelledReplies++
        }
        registry.invoke(issued.ticket, 1) { true }
        val fresh = registry.begin("account-a", otherDevice, 2, newerOwner) {}
        registry.cancelOwner(owner)
        val cancelled = registry.takeReady(3).single()
        cancelled.reply!!.invoke(cancelled.result)
        assertEquals(1, cancelledReplies)
        assertTrue(registry.pending(fresh.ticket))
        assertEquals(0L, registry.begin("account-a", device, 4, newerOwner) {}.ticket)
        registry.cancelOwner(owner)
        assertTrue(registry.takeReady(5).isEmpty())
        registry.ended("account-a", device, 0, 6)
        assertTrue(registry.takeReady(6).isEmpty())
        assertNotEquals(0L, registry.begin("account-a", device, 7, newerOwner) {}.ticket)
    }

    @Test
    fun `preflight rejection and queued timeout do not occupy native callback slots`() {
        val registry = registry()
        val first = registry.begin()
        registry.refuse(first.ticket, DeviceRevocationStatus.REFUSED)
        assertEquals(DeviceRevocationStatus.REFUSED, registry.takeReady(1).single().result.status)
        val queued = registry.begin(now = 2)
        var invoked = false
        registry.invoke(queued.ticket, 2 + DeviceRevocationRegistry.TIMEOUT_MS) { invoked = true; true }
        assertFalse(invoked)
        assertEquals(DeviceRevocationStatus.TIMEOUT, registry.takeReady(40_000).single().result.status)
        assertNotEquals(0L, registry.begin(now = 40_001).ticket)
    }

    @Test
    fun `request storage uses the existing device bound and rejects invalid identities`() {
        val registry = registry()
        assertEquals(DeviceRevocationStatus.REFUSED, registry.begin("../device").status)
        assertEquals(DeviceRevocationStatus.ACCOUNT_CHANGED,
            registry.begin("different-account", device, 0, owner) {}.status)
        assertEquals(0L, registry.begin(now = Long.MAX_VALUE).ticket)
        for (index in 0 until KnownDeviceWire.MAX_DEVICES) {
            assertNotEquals(0L, registry.begin("a".repeat(40) + index).ticket)
        }
        assertEquals(0L, registry.begin().ticket)
        registry.cancelOwner(owner)
        assertEquals(KnownDeviceWire.MAX_DEVICES, registry.takeReady(1).size)
        assertNotEquals(0L, registry.begin(now = 2).ticket)
    }

    @Test
    fun `timer failure completes every reply and preserves only issued callback tombstones`() {
        val registry = registry()
        val issued = registry.begin()
        registry.invoke(issued.ticket, 1) { true }
        val queued = registry.begin(otherDevice, 2)
        registry.failPending()
        val ready = registry.takeReady(3)
        assertEquals(2, ready.size)
        assertTrue(ready.all { it.result.status == DeviceRevocationStatus.UNAVAILABLE })
        assertFalse(registry.hasPendingReplies())
        var invoked = false
        registry.invoke(queued.ticket, 4) { invoked = true; true }
        assertFalse(invoked)
        assertNotEquals(0L, registry.begin(otherDevice, 4).ticket)
        assertEquals(0L, registry.begin(now = 4).ticket)
        registry.ended("account-a", device, 0, 5)
        assertTrue(registry.takeReady(5).isEmpty())
        assertNotEquals(0L, registry.begin(now = 6).ticket)
    }
}
