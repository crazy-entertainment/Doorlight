package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class OwnedFileOperationsTest {
    @Test fun `verified repair retires failed or missing ready callback without retiring another scope`() {
        val registry = OwnedFileOperations()
        val entry = entry()
        val id = entry.command.operationId
        assertTrue(registry.begin(entry))
        registry.seeded("account", "conversation", id, "commit", "file", false)
        assertFalse(registry.acknowledgeVerified("other", "conversation", id, "commit"))
        assertFalse(registry.acknowledgeVerified("account", "other", id, "commit"))
        assertFalse(registry.acknowledgeVerified("account", "conversation", id, "other"))
        assertTrue(registry.ownsPath(entry.path))
        assertTrue(registry.acknowledgeVerified("account", "conversation", id, "commit"))
        assertFalse(registry.ownsPath(entry.path))
        assertFalse(registry.begin(entry))
        assertTrue(registry.acknowledgeVerified("account", "conversation", id, "commit"))

        val second = entry.copy(command = entry.command.copy(operationId = "b".repeat(32)))
        assertTrue(registry.begin(second))
        assertTrue(registry.acknowledgeVerified("account", "conversation", second.command.operationId, "commit"))
        assertFalse(registry.ownsPath(second.path))
    }

    private fun entry() = OwnedFileOperation(
        OwnedMessageOperation(NativeAccountScope("account", Any()), "peer", "conversation", "a".repeat(32)),
        "/private/stage",
    )

    @Test fun `commit does not acknowledge seed and failed setup preserves repair ownership`() {
        val registry = OwnedFileOperations()
        val entry = entry()
        val id = entry.command.operationId
        assertTrue(registry.begin(entry))
        assertNotNull(registry.committed("account", "conversation", id, "commit"))
        assertNull(registry.ready("account", id, "commit"))
        assertNotNull(registry.seeded("account", "conversation", id, "commit", "file", false))
        assertTrue(registry.ownsPath(entry.path))
        assertFalse(registry.begin(entry))
        assertNull(registry.ready("account", id, "commit"))
    }

    @Test fun `seed evidence requires exact scope commit and transfer and cannot regress`() {
        val registry = OwnedFileOperations()
        val entry = entry()
        val id = entry.command.operationId
        registry.begin(entry)
        assertNull(registry.seeded("other", "conversation", id, "commit", "file", true))
        assertNotNull(registry.seeded("account", "conversation", id, "commit", "file", true))
        assertNull(registry.seeded("account", "conversation", id, "other", "file", true))
        assertNull(registry.seeded("account", "conversation", id, "commit", "other", true))
        registry.seeded("account", "conversation", id, "commit", "file", false)
        val ready = registry.ready("account", id, "commit")!!
        assertFalse(registry.removeExact(entry))
        assertTrue(registry.removeExact(ready))
        assertFalse(registry.ownsPath(entry.path))
        assertFalse(registry.begin(entry))
    }

    @Test fun `unknown completion retains a source and same path cannot be issued twice`() {
        val registry = OwnedFileOperations()
        val entry = entry()
        registry.begin(entry)
        assertNotNull(registry.committed("account", "conversation", entry.command.operationId, ""))
        assertFalse(registry.begin(entry.copy(command = entry.command.copy(operationId = "b".repeat(32)))))
        assertTrue(registry.ownsPath(entry.path))
    }
}
