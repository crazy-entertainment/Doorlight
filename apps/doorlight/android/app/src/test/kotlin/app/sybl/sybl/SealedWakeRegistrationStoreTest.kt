package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class SealedWakeRegistrationStoreTest {
    private val capability = WakeCapability("A".repeat(43), "B".repeat(43))
    private class Legacy(var value: WakeCapability?) : WakeRegistrationStore {
        var clears = 0
        var allowClear = true
        override fun load() = value
        override fun save(capability: WakeCapability) { value = capability }
        override fun clear() {
            check(allowClear)
            value = null
            clears++
        }
    }
    private class Blob {
        var memory: ByteArray? = null
        var disk: ByteArray? = null
        var writesSucceed = true
        var readFails = false
        fun read(): ByteArray? { check(!readFails); return memory?.copyOf() }
        fun write(value: ByteArray): Boolean {
            memory = value.copyOf()
            if (writesSucceed) disk = value.copyOf()
            return writesSucceed
        }
        fun remove(): Boolean {
            memory = null
            if (writesSucceed) disk = null
            return writesSucceed
        }
        fun restart() { memory = disk?.copyOf() }
    }
    private fun store(old: Legacy, blob: Blob) =
        SealedWakeRegistrationStore(old, blob::read, blob::write, blob::remove)

    @Test fun `migration verifies decryptable persistence before removing plaintext`() {
        val old = Legacy(capability)
        val blob = Blob()
        assertEquals(capability, store(old, blob).load())
        assertNull(old.value)
        blob.restart()
        assertEquals(capability, store(old, blob).load())
    }

    @Test fun `unacknowledged sealed writes cannot retire legacy even on retry`() {
        val old = Legacy(capability)
        val blob = Blob().apply { writesSucceed = false }
        val value = store(old, blob)
        repeat(2) {
            assertTrue(runCatching { value.load() }.isFailure)
            assertEquals(capability, old.value)
            assertEquals(0, old.clears)
        }
        blob.restart()
        blob.writesSucceed = true
        assertEquals(capability, value.load())
        assertNull(old.value)
    }

    @Test fun `failed plaintext removal keeps matching sealed authority across restart`() {
        val old = Legacy(capability).apply { allowClear = false }
        val blob = Blob()
        assertTrue(runCatching { store(old, blob).load() }.isFailure)
        blob.restart()
        old.allowClear = true
        assertEquals(capability, store(old, blob).load())
    }

    @Test fun `corrupt or unreadable sealed record cannot be overwritten using legacy`() {
        val old = Legacy(capability)
        val blob = Blob().apply { memory = byteArrayOf(1) }
        assertTrue(runCatching { store(old, blob).load() }.isFailure)
        blob.readFails = true
        assertTrue(runCatching { store(old, blob).load() }.isFailure)
        assertEquals(capability, old.value)
        assertEquals(0, old.clears)
    }

    @Test fun `failed removal retains exact credential for retry and restart`() {
        val old = Legacy(null)
        val blob = Blob()
        val value = store(old, blob)
        value.save(capability)
        blob.writesSucceed = false
        assertTrue(runCatching { value.clear() }.isFailure)
        assertEquals(capability, value.load())
        blob.restart()
        assertEquals(capability, store(old, blob).load())
        blob.writesSucceed = true
        value.clear()
        assertNull(store(old, blob).load())
    }
}
