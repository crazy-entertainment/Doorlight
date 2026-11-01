package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class ConsentWakeTokensTest {
    private class Fixture {
        var pending = false
        var writable = true
        val events = mutableListOf<String>()
        lateinit var token: (String?) -> Unit
        lateinit var deleted: (Boolean) -> Unit
        fun create() = ConsentWakeTokens(
            loadCleanupPending = { pending },
            saveCleanupPending = { if (writable) pending = it; writable },
            backend = object : BackgroundWakeTokens {
                override fun setEnabled(enabled: Boolean) { events += "enabled:$enabled" }
                override fun get(callback: (String?) -> Unit) { events += "get"; token = callback }
                override fun delete(callback: (Boolean) -> Unit) { events += "delete"; deleted = callback }
            },
        )
    }

    @Test fun `never enabled installation makes no SDK calls including cleanup`() {
        val f = Fixture()
        val tokens = f.create()
        repeat(3) {
            tokens.setEnabled(false)
            var completed = false
            tokens.delete { completed = it }
            assertTrue(completed)
        }
        assertTrue(f.events.isEmpty())
        assertFalse(f.pending)
    }

    @Test fun `failed consent persistence prevents SDK access`() {
        val f = Fixture()
        f.writable = false
        assertThrows(IllegalStateException::class.java) { f.create().setEnabled(true) }
        assertTrue(f.events.isEmpty())
    }

    @Test fun `token acquisition requires explicit enablement`() {
        val f = Fixture()
        val tokens = f.create()
        assertThrows(IllegalStateException::class.java) { tokens.get {} }
        tokens.setEnabled(true)
        assertTrue(f.pending)
        var result: String? = null
        tokens.get { result = it }
        f.token("token")
        assertEquals("token", result)
    }

    @Test fun `withdrawal waits for submitted token work then deletes its result`() {
        val f = Fixture()
        val tokens = f.create()
        tokens.setEnabled(true)
        var result: String? = "unset"
        tokens.get { result = it }
        tokens.setEnabled(false)
        var completed = false
        tokens.delete { completed = it }
        assertFalse(f.events.contains("delete"))
        f.token("late")
        assertNull(result)
        assertEquals("delete", f.events.last())
        f.deleted(true)
        assertTrue(completed)
        assertFalse(f.pending)
    }

    @Test fun `failed deletion remains pending across restart`() {
        val f = Fixture()
        f.pending = true
        val tokens = f.create()
        tokens.setEnabled(false)
        tokens.delete { assertFalse(it) }
        f.deleted(false)
        assertTrue(f.pending)
        val restarted = f.create()
        restarted.setEnabled(false)
        restarted.delete { assertTrue(it) }
        f.deleted(true)
        assertFalse(f.pending)
    }

    @Test fun `failed cleanup persistence is not successful deletion`() {
        val f = Fixture()
        f.pending = true
        f.writable = false
        f.create().delete { assertFalse(it) }
        f.deleted(true)
        assertTrue(f.pending)
    }
}
