package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WakeRegistrationTest {
    private class MemoryStore : WakeRegistrationStore {
        var saved: WakeCapability? = null
        override fun load() = saved
        override fun save(capability: WakeCapability) { saved = capability }
        override fun clear() { saved = null }
    }

    private class RecordingTransport : WakeRegistrationTransport {
        val requests = mutableListOf<WakeRelayRequest>()
        var succeeds = true
        val putStatuses = mutableListOf<Int>()
        override fun execute(request: WakeRelayRequest): Boolean {
            requests += request
            return succeeds
        }
        override fun status(request: WakeRelayRequest): Int {
            requests += request
            return if (putStatuses.isNotEmpty()) putStatuses.removeAt(0)
                else if (succeeds) 204 else 503
        }
    }

    private fun registration(
        store: MemoryStore = MemoryStore(),
        transport: RecordingTransport = RecordingTransport(),
    ): Triple<WakeRegistration, MemoryStore, RecordingTransport> {
        var generation = 0
        return Triple(
            WakeRegistration(store, transport, MemoryWakeDeletionJournal()) { size ->
                generation += 1
                ByteArray(size) { index -> (index + generation).toByte() }
            },
            store,
            transport,
        )
    }

    @Test
    fun `enable creates separate stable handle and secret then updates the same registration`() {
        val (registration, store, transport) = registration()

        val handle = registration.enable("https://wake.example", "token-one-123456789012345")
        assertEquals(43, handle?.length)
        assertEquals(43, store.saved?.secret?.length)
        assertFalse(handle == store.saved?.secret)
        assertEquals("PUT", transport.requests.single().method)
        assertEquals("https://wake.example/v1/registrations/$handle", transport.requests.single().url)
        assertEquals(store.saved?.secret, transport.requests.single().bearer)

        assertEquals(handle, registration.enable("https://wake.example", "token-two-123456789012345"))
        assertEquals(handle, store.saved?.handle)
        assertEquals(2, transport.requests.size)
        assertEquals(handle, transport.requests.last().url.substringAfterLast('/'))
    }

    @Test
    fun `failed registration returns no public handle and keeps foreground fallback possible`() {
        val (registration, store, transport) = registration()
        transport.succeeds = false

        assertNull(registration.enable("https://wake.example", "token-one-123456789012345"))
        assertTrue(store.saved != null)
        assertFalse(registration.registered)
    }

    @Test
    fun `disable clears only after relay deletion succeeds`() {
        val (registration, store, transport) = registration()
        assertTrue(registration.enable("https://wake.example", "token-one-123456789012345") != null)
        transport.succeeds = false
        assertFalse(registration.disable("https://wake.example"))
        assertTrue(store.saved != null)

        transport.succeeds = true
        assertTrue(registration.disable("https://wake.example"))
        assertNull(store.saved)
        assertEquals("DELETE", transport.requests.last().method)
    }

    @Test
    fun `rotation deletes the old registration before it creates a new one`() {
        val (registration, store, transport) = registration()
        val old = registration.enable("https://wake.example", "token-one-123456789012345")
        assertTrue(registration.disable("https://wake.example"))
        val fresh = registration.enable("https://wake.example", "token-one-123456789012345")

        assertTrue(fresh != null && fresh != old)
        assertEquals(listOf("PUT", "DELETE", "PUT"), transport.requests.map { it.method })
        assertEquals(fresh, store.saved?.handle)
    }

    @Test
    fun `deleted handle rotates once after definitive relay tombstone`() {
        val (registration, store, transport) = registration()
        val old = registration.enable("https://wake.example", "token-one-123456789012345")
        transport.putStatuses.addAll(listOf(410, 204))

        val fresh = registration.enable("https://wake.example", "token-two-123456789012345")

        assertTrue(fresh != null && fresh != old)
        assertEquals(fresh, store.saved?.handle)
        assertEquals(listOf("PUT", "PUT", "PUT"), transport.requests.map { it.method })
        assertEquals(old, transport.requests[1].url.substringAfterLast('/'))
        assertEquals(fresh, transport.requests[2].url.substringAfterLast('/'))
        assertTrue(registration.registered)
    }

    @Test
    fun `temporary relay failure retains the same credential`() {
        val (registration, store, transport) = registration()
        val old = registration.enable("https://wake.example", "token-one-123456789012345")
        transport.putStatuses.add(503)

        assertNull(registration.enable("https://wake.example", "token-two-123456789012345"))
        assertEquals(old, store.saved?.handle)
        assertFalse(registration.registered)
    }

    @Test
    fun `invalid relay URL and token fail closed without network`() {
        val (registration, _, transport) = registration()
        assertNull(registration.enable("http://wake.example", "token-one-123456789012345"))
        assertNull(registration.enable("https://wake.example/path", "token-one-123456789012345"))
        assertNull(registration.enable("https://wake.example", "short"))
        assertTrue(transport.requests.isEmpty())
    }
}
