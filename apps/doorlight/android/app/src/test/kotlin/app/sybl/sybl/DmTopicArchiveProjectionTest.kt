package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DmTopicArchiveProjectionTest {
    private val local = "a".repeat(40)
    private val peer = "b".repeat(40)
    private val topic = "0123456789abcdef0123456789abcdef"

    private fun event(revision: Int, archived: Boolean): String =
        """{"v":1,"op":"archive","topic":"$topic","revision":$revision,"archived":$archived}"""

    @Test
    fun `unknown topic stays silent until authenticated creation and archive still wins`() {
        val projection = DmTopicArchiveProjection()
        assertTrue(projection.admits("dm", "main"))
        assertFalse(projection.admits("dm", topic))
        projection.apply("dm", "archive", local, local, event(1, true))
        val create = """{"v":1,"op":"create","topic":"$topic","revision":1,"name":"Trip","order":0}"""
        assertTrue(projection.apply("dm", "create", peer, local, create))
        assertFalse(projection.admits("dm", topic))
        projection.apply("dm", "unarchive", local, local, event(2, false))
        assertTrue(projection.admits("dm", topic))
        assertFalse(projection.admits("other", topic))
        projection.clear()
        assertFalse(projection.admits("dm", topic))
    }

    @Test
    fun `only the local signed archive register suppresses a topic`() {
        val projection = DmTopicArchiveProjection()
        assertFalse(projection.apply("dm", "peer-1", peer, local, event(1, true)))
        assertFalse(projection.isArchived("dm", topic))

        assertTrue(projection.apply("dm", "local-1", local, local, event(1, true)))
        assertTrue(projection.isArchived("dm", topic))
        assertTrue(projection.apply("dm", "local-2", local, local, event(2, false)))
        assertFalse(projection.isArchived("dm", topic))
    }

    @Test
    fun `revision and commit id make archive merge deterministic`() {
        val projection = DmTopicArchiveProjection()
        assertTrue(projection.apply("dm", "b", local, local, event(2, true)))
        assertFalse(projection.apply("dm", "z", local, local, event(1, false)))
        assertTrue(projection.isArchived("dm", topic))
        assertTrue(projection.apply("dm", "c", local, local, event(2, false)))
        assertFalse(projection.isArchived("dm", topic))
    }

    @Test
    fun `malformed archive events and main do nothing`() {
        val projection = DmTopicArchiveProjection()
        assertFalse(projection.apply("dm", "one", local, local, "{}"))
        assertFalse(
            projection.apply(
                "dm",
                "two",
                local,
                local,
                """{"v":1,"op":"archive","topic":"main","revision":1,"archived":true}""",
            ),
        )
        assertFalse(projection.isArchived("dm", topic))
    }
}
