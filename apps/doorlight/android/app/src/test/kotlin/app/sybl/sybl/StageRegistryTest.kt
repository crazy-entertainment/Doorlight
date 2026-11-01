package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class StageRegistryTest {
    @Test fun `restart retains issued recordings and prevents operation reuse`() {
        var saved: String? = null
        val registry = StageRegistry(null) { saved = it; true }
        assertTrue(registry.reserveRecording("voice"))
        assertFalse(registry.ownsIssued("voice"))
        val issued = StageRecord("voice", "account", "peer", "conversation", "a".repeat(32))
        assertTrue(registry.issue(issued))
        val restarted = StageRegistry(saved) { true }
        assertTrue(restarted.healthy)
        assertTrue(restarted.find(issued.operation)!!.recording)
        assertTrue(restarted.ownsIssued("voice"))
        assertFalse(restarted.issue(issued))
        assertFalse(restarted.issue(issued.copy(path = "other")))
        assertTrue(restarted.forget("voice"))
        assertNull(restarted.find(issued.operation))
    }

    @Test fun `corrupt and uncertain persistence block cleanup and publication`() {
        val corrupt = StageRegistry("broken") { error("must not overwrite") }
        assertFalse(corrupt.healthy)
        assertTrue(corrupt.ownsIssued("anything"))
        assertFalse(corrupt.reserveRecording("anything"))
        val failed = StageRegistry(null) { false }
        assertFalse(failed.reserveRecording("voice"))
        assertFalse(failed.healthy)
        assertTrue(failed.ownsIssued("voice"))
    }

    @Test fun `capacity never evicts retained sources`() {
        val registry = StageRegistry(null) { true }
        repeat(256) { assertTrue(registry.reserveRecording("voice$it")) }
        assertFalse(registry.reserveRecording("overflow"))
        assertEquals(256, registry.records().size)
    }
}
