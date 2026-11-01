package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class DmTopicWireTest {
    @Test
    fun `item topics preserve valid tags and map all other content to main`() {
        val custom = "0123456789abcdef0123456789abcdef"

        assertEquals(DmTopicTag("main", false), DmTopicWire.itemTag(null))
        assertEquals(DmTopicTag("main", false), DmTopicWire.itemTag("BAD"))
        assertEquals(DmTopicTag("main", true), DmTopicWire.itemTag("main"))
        assertEquals(DmTopicTag(custom, true), DmTopicWire.itemTag(custom))
        assertTrue(DmTopicWire.validOutgoingTopic(""))
        assertTrue(DmTopicWire.validOutgoingTopic("main"))
        assertTrue(DmTopicWire.validOutgoingTopic(custom))
        assertFalse(DmTopicWire.validOutgoingTopic("BAD"))
    }

    @Test
    fun `state projection is minimal bounded and type specific`() {
        val custom = "0123456789abcdef0123456789abcdef"
        val common = mapOf(
            "author" to "alice",
            "linearizedParent" to "spoofed-parent",
            DmTopicWire.ITEM_FIELD to custom,
        )

        val text = DmTopicWire.stateEnvelope(
            "message-a",
            "text/plain",
            "parent-a",
            common,
            daemonRead = true,
        )!!
        assertEquals("message-a", text.commitId)
        assertEquals("alice", text.authorId)
        assertEquals(custom, text.topicId)
        assertTrue(text.topicTagged)
        assertEquals("parent-a", text.linearizedParent)
        assertNull(text.eventBody)
        assertFalse(text.toMap().containsKey("body"))
        assertTrue(text.daemonRead)
        assertEquals(true, text.toMap()["daemonRead"])

        val legacy = DmTopicWire.stateEnvelope(
            "legacy",
            "text/plain",
            "parent-a",
            common - DmTopicWire.ITEM_FIELD,
        )!!
        assertEquals("main", legacy.topicId)
        assertFalse(legacy.topicTagged)
        val bad = DmTopicWire.stateEnvelope(
            "bad",
            "text/plain",
            "parent-a",
            common + (DmTopicWire.ITEM_FIELD to "BAD"),
        )!!
        assertEquals("main", bad.topicId)
        assertFalse(bad.topicTagged)

        val eventBody = "{\"v\":1}"
        val control = DmTopicWire.stateEnvelope(
            "event-a",
            DmTopicWire.EVENT_MIME,
            "parent-a",
            common - DmTopicWire.ITEM_FIELD + ("body" to eventBody),
        )!!
        assertEquals("main", control.topicId)
        assertFalse(control.topicTagged)
        assertEquals(eventBody, control.eventBody)
        assertTrue(control.toMap().containsKey("eventBody"))
        assertNull(
            DmTopicWire.stateEnvelope(
                "large",
                DmTopicWire.EVENT_MIME,
                "parent-a",
                common + ("body" to "x".repeat(DmTopicWire.MAX_EVENT_BYTES + 1)),
            ),
        )
        assertNull(DmTopicWire.stateEnvelope("foreign", "member", "parent-a", common))
    }
}
