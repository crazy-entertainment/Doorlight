package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

/** Exercises removal of legacy sealed grants; none can supply session authority. */
class RemoteControlGrantRepositoryTest {
    private val local = "a".repeat(40)
    private val peer = "b".repeat(40)
    private val device = "1".repeat(64)

    private class Storage {
        var bytes: ByteArray? = null
        var failRead = false
        var failWrite = false
        val repository = AndroidRemoteControlGrantRepository(
            {
                check(!failRead) { "fixture read failure" }
                bytes?.copyOf()
            },
            {
                if (failWrite) false else { bytes = it.copyOf(); true }
            },
        )
        fun seed(vararg grants: AndroidRemoteControlGrant) {
            bytes = AndroidRemoteControlGrantPolicy.encode(grants.toList())
        }
        fun records() = AndroidRemoteControlGrantPolicy.decode(bytes ?: byteArrayOf())
    }

    private fun grant(localId: String = local, peerId: String = peer, deviceId: String = device) =
        AndroidRemoteControlGrant(localId, peerId, deviceId, 1000, 1000)

    @Test
    fun `trust removal deletes every peer device and preserves unrelated legacy grants`() {
        val store = Storage()
        val otherPeer = "c".repeat(40)
        val otherLocal = "d".repeat(40)
        val retained = listOf(grant(peerId = otherPeer), grant(localId = otherLocal))
        store.seed(grant(), grant(deviceId = "2".repeat(64)), *retained.toTypedArray())
        assertTrue(store.repository.removePeer(local, peer))
        assertTrue(store.repository.removePeer(local, peer))
        assertEquals(retained, store.records())
        assertFalse(store.repository.revocationFailed)
    }

    @Test
    fun `read failure preserves bytes and remains visible after successful retry`() {
        val store = Storage()
        store.seed(grant())
        val original = store.bytes!!.copyOf()
        store.failRead = true
        assertFalse(store.repository.removePeer(local, peer))
        assertTrue(store.repository.revocationFailed)
        store.failRead = false
        assertArrayEquals(original, store.bytes)
        assertTrue(store.repository.removePeer(local, peer))
        assertTrue(store.records().isEmpty())
        assertTrue(store.repository.revocationFailed)
    }

    @Test
    fun `failed purge stays visible and can be retried`() {
        val store = Storage()
        store.seed(grant())
        store.failWrite = true
        assertFalse(store.repository.removePeer(local, peer))
        store.failWrite = false
        assertEquals(listOf(grant()), store.records())
        assertTrue(store.repository.revocationFailed)
        assertTrue(store.repository.removePeer(local, peer))
        assertTrue(store.records().isEmpty())
        assertTrue(store.repository.revocationFailed)
    }

    @Test
    fun `invalid identities and malformed legacy data cannot report cleanup success`() {
        val store = Storage()
        assertFalse(store.repository.removePeer("invalid", peer))
        store.bytes = "malformed".toByteArray()
        assertFalse(store.repository.removePeer(local, peer))
        assertTrue(store.repository.revocationFailed)
        assertEquals("malformed", store.bytes!!.toString(Charsets.US_ASCII))
    }
}
