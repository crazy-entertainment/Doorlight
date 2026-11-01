package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class HistorySearchRequestTest {
    private val conversation = "c".repeat(40)
    private fun request(limit: Int = 20) = HistorySearchRequest("account", conversation, false, "private", limit)
    private fun hit(id: Int = 1) = mapOf(
        "id" to id.toString(16).padStart(40, '0'), "author" to "b".repeat(40),
        "type" to "text/plain", "timestamp" to "1700000000", "body" to "private content",
    )

    @Test fun onlyExactOwnerTerminalPublishes() {
        val request = request()
        request.accept("account", conversation, 1) { hit() }
        assertNull(request.result())
        request.accept("other", "", 0) { error("Must not read") }
        assertFalse(request.terminal)
        request.accept("account", "d".repeat(40), 1) { error("Must not read") }
        request.accept("account", "", 0) { error("Must not read") }
        assertTrue(request.terminal)
        assertEquals(1, (request.result()!!["hits"] as List<*>).size)
    }

    @Test fun errorsAndRetirementDoNotReleaseTheWorker() {
        for (retire in listOf(false, true)) {
            val request = request()
            request.accept("account", conversation, 1) { hit() }
            if (retire) request.retire()
            else request.accept("account", "", 1) { mapOf("sybl-search-error" to "unavailable") }
            assertFalse(request.terminal)
            assertNull(request.result())
            request.accept("account", "", 0) { error("Must not read") }
            assertTrue(request.terminal)
            assertNull(request.result())
        }
    }

    @Test fun nativeBoundsAreCheckedBeforeReading() {
        val request = request(2)
        request.accept("account", conversation, Int.MAX_VALUE) { error("Must not read") }
        assertTrue(request.failed)
        assertFalse(request.terminal)
        val bounded = request(2)
        bounded.accept("account", conversation, 3) { hit(it + 1) }
        bounded.accept("account", "", 0) { error("Must not read") }
        assertEquals(true, bounded.result()!!["truncated"])
        assertEquals(2, (bounded.result()!!["hits"] as List<*>).size)
    }

    @Test fun conflictingCommitResultsFailClosed() {
        val request = request()
        request.accept("account", conversation, 1) { hit() }
        request.accept("account", conversation, 1) { hit() + ("body" to "different private content") }
        assertTrue(request.failed)
        request.accept("account", "", 0) { error("Must not read") }
        assertNull(request.result())
        assertFalse(request.toString().contains("content"))
    }

    @Test fun nativeReadFailureWaitsForTerminalWithoutExposingPayload() {
        val request = request()
        request.accept("account", conversation, 1) { throw IllegalStateException("private payload") }
        assertTrue(request.failed)
        assertFalse(request.terminal)
        request.accept("account", "", 0) { error("Must not read") }
        assertTrue(request.terminal)
        assertNull(request.result())
    }
}
