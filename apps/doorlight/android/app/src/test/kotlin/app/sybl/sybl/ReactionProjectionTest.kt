package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class ReactionProjectionTest {
    private val message = "a".repeat(40)
    private val author = "b".repeat(40)
    private fun reaction(id: String = "1", emoji: String = "👍") =
        mapOf("id" to id.repeat(40), "author" to author, "body" to emoji, "react-to" to message)

    @Test fun projectsExactReactionCommitsAndDeduplicates() {
        val raw = listOf(reaction(), reaction(), reaction("2", "❤️"), reaction("3", "unsupported"))
        val result = ReactionProjection.project(message, raw.size, raw::get) { it == author }
        assertEquals(true, result["complete"])
        val entries = result["entries"] as List<*>
        assertEquals(2, entries.size)
        assertEquals("1".repeat(40), (entries.first() as Map<*, *>)["commitId"])
    }

    @Test fun conflictingOrForeignTargetsCannotSupplyCompleteHistory() {
        val raw = listOf(reaction(), reaction(emoji = "❤️"), reaction(),
            reaction("2") + ("react-to" to "other"), reaction("3") + ("author" to "c".repeat(40)))
        val result = ReactionProjection.project(message, raw.size, raw::get) { it == author }
        assertEquals(false, result["complete"])
        assertTrue((result["entries"] as List<*>).isEmpty())
    }

    @Test fun readsOnlyBoundedNativeEntries() {
        var reads = 0
        val result = ReactionProjection.project(message, Int.MAX_VALUE, {
            reads++
            reaction()
        }) { true }
        assertEquals(ReactionProjection.MAX_ENTRIES, reads)
        assertEquals(false, result["complete"])
    }
}
