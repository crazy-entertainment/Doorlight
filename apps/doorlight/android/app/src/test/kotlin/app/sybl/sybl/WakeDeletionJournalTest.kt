package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class WakeDeletionJournalTest {
    private class Fixture {
        var disk: ByteArray? = null
        var memory: ByteArray? = null
        var writesSucceed = true
        var removesSucceed = true
        var credential: WakeCapability? = null
        var clearCredentialSucceeds = true
        var transportSucceeds = true
        var random = 0
        val requests = mutableListOf<WakeRelayRequest>()
        fun registration(restart: Boolean = false): WakeRegistration {
            if (restart) memory = disk?.copyOf()
            return WakeRegistration(
                object : WakeRegistrationStore {
                    override fun load() = credential
                    override fun save(capability: WakeCapability) { credential = capability }
                    override fun clear() { check(clearCredentialSucceeds); credential = null }
                },
                { requests += it; transportSucceeds },
                SealedWakeDeletionJournal(
                    read = { memory?.copyOf() },
                    write = {
                        memory = it.copyOf()
                        if (writesSucceed) disk = it.copyOf()
                        writesSucceed
                    },
                    remove = {
                        memory = null
                        if (removesSucceed) disk = null
                        removesSucceed
                    },
                ),
                { size -> ByteArray(size) { (++random).toByte() } },
            )
        }
    }

    @Test fun `registered capability is bound to the exact relay and account`() {
        val f = Fixture()
        val r = f.registration()
        assertNotNull(r.enable(RELAY, TOKEN, "account-a"))
        assertNull(r.enable(RELAY, TOKEN, "account-b"))
        assertNull(r.enable("https://other.example", TOKEN, "account-a"))
        assertFalse(r.disable(RELAY, "account-b"))
        assertFalse(r.disable("https://other.example", "account-a"))
        assertEquals(1, f.requests.size)
    }

    @Test fun `delete requires durable journal and cannot rotate after failed persistence`() {
        val f = Fixture()
        val r = f.registration()
        assertNotNull(r.enable(RELAY, TOKEN, "account-a"))
        f.writesSucceed = false
        assertTrue(runCatching { r.disable(RELAY, "account-a") }.isFailure)
        assertEquals(listOf("PUT"), f.requests.map { it.method })
        assertNull(r.enable(RELAY, TOKEN, "account-a"))
        f.writesSucceed = true
        assertTrue(f.registration(restart = true).disable(RELAY, "account-a"))
        assertEquals(listOf("PUT", "DELETE"), f.requests.map { it.method })
    }

    @Test fun `failed remote delete survives restart and blocks every new registration`() {
        val f = Fixture()
        var r = f.registration()
        r.enable(RELAY, TOKEN, "account-a")
        val original = f.credential
        f.transportSucceeds = false
        assertFalse(r.disable(RELAY, "account-a"))
        r = f.registration(restart = true)
        assertEquals(original, r.pendingDeletion()?.capability)
        assertNull(r.enable(RELAY, TOKEN, "account-b"))
        f.transportSucceeds = true
        assertTrue(r.disable(RELAY, "account-a"))
        assertEquals(f.requests[1], f.requests[2])
    }

    @Test fun `local credential clear failure retries exact deletion after restart`() {
        val f = Fixture()
        val r = f.registration()
        r.enable(RELAY, TOKEN, "account-a")
        f.clearCredentialSucceeds = false
        assertTrue(runCatching { r.disable(RELAY, "account-a") }.isFailure)
        f.clearCredentialSucceeds = true
        assertTrue(f.registration(restart = true).disable(RELAY, "account-a"))
        assertEquals(f.requests[1], f.requests[2])
        assertNull(f.credential)
    }

    @Test fun `journal clear failure retains deletion authority after credential is gone`() {
        val f = Fixture()
        var r = f.registration()
        r.enable(RELAY, TOKEN, "account-a")
        f.removesSucceed = false
        assertTrue(runCatching { r.disable(RELAY, "account-a") }.isFailure)
        assertNull(f.credential)
        assertNull(r.enable(RELAY, TOKEN, "account-a"))
        r = f.registration(restart = true)
        assertNotNull(r.pendingDeletion())
        f.removesSucceed = true
        assertTrue(r.disable(RELAY, "account-a"))
        assertEquals(f.requests[1], f.requests[2])
        assertNull(r.pendingDeletion())
    }

    @Test fun `corrupt protected journal never becomes absent`() {
        val f = Fixture().apply { memory = "{}".toByteArray() }
        val r = f.registration()
        assertTrue(runCatching { r.enable(RELAY, TOKEN, "account-a") }.isFailure)
        assertTrue(runCatching { r.disable(RELAY, "account-a") }.isFailure)
        assertTrue(f.requests.isEmpty())
    }

    private companion object {
        const val RELAY = "https://wake.example"
        const val TOKEN = "synthetic-token-1234567890"
    }
}
