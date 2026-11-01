package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimelineMessageSemanticsTest {
    @Test
    fun liveEffectsRejectReplayEditAdminAndSaturationWithoutEviction() {
        val gate = LiveMessageEffects(2)
        fun message(id: String) = mapOf<String, Any?>(
            "daemonId" to id, "versionId" to id, "mimeType" to "text/plain")
        assertFalse(gate.admit("a", "c", message("edit") + ("versionId" to "edition")))
        assertFalse(gate.admit("a", "c", message("admin") + ("mimeType" to DmTopicWire.EVENT_MIME)))
        assertTrue(gate.admit("a", "c", message("one")))
        assertFalse(gate.admit("a", "c", message("one")))
        assertTrue(gate.admit("a", "other", message("one")))
        assertFalse(gate.admit("a", "c", message("two")))
        assertFalse(gate.admit("a", "c", message("one")))
    }

    @Test
    fun usesLatestEditionAsVersionForLiveTextEdit() {
        val semantics = timelineMessageSemantics(
            daemonId = "original",
            latestEditionId = "edition-2",
            mimeType = "text/plain",
            body = mapOf("body" to "edited"),
            liveUpdate = true,
        )

        assertEquals("edition-2", semantics?.versionId)
        assertEquals("edit", semantics?.operation)
        assertFalse(semantics!!.deleted)
    }

    @Test
    fun fallsBackToStableIdForUneditedSnapshot() {
        val semantics = timelineMessageSemantics(
            daemonId = "original",
            latestEditionId = "",
            mimeType = "text/plain",
            body = mapOf("body" to "hello"),
            liveUpdate = false,
        )

        assertEquals("original", semantics?.versionId)
        assertNull(semantics?.operation)
        assertFalse(semantics!!.deleted)
    }

    @Test
    fun exposesFoldedTextAndFileRemovalsAsTombstones() {
        val deletedText = timelineMessageSemantics(
            daemonId = "text",
            latestEditionId = "text-delete",
            mimeType = "text/plain",
            body = mapOf("body" to ""),
            liveUpdate = true,
        )
        val deletedFile = timelineMessageSemantics(
            daemonId = "file",
            latestEditionId = "file-delete",
            mimeType = "application/data-transfer+json",
            body = mapOf("fileId" to ""),
            liveUpdate = true,
        )

        assertTrue(deletedText!!.deleted)
        assertEquals("edit", deletedText.operation)
        assertTrue(deletedFile!!.deleted)
        assertEquals("file-delete", deletedFile.versionId)
        assertEquals("edit", deletedFile.operation)
    }

    @Test
    fun rejectsImpossibleLiveFileReplacement() {
        assertNull(
            timelineMessageSemantics(
                daemonId = "file",
                latestEditionId = "edition",
                mimeType = "application/data-transfer+json",
                body = mapOf("fileId" to "replacement"),
                liveUpdate = true,
            ),
        )
    }

    @Test
    fun acceptsOnlyImmutableDmTopicEvents() {
        val event = timelineMessageSemantics(
            daemonId = "event",
            latestEditionId = "",
            mimeType = DmTopicWire.EVENT_MIME,
            body = mapOf("body" to "{\"v\":1}"),
            liveUpdate = false,
        )

        assertEquals("event", event?.versionId)
        assertFalse(event!!.deleted)
        assertNull(
            timelineMessageSemantics(
                daemonId = "event",
                latestEditionId = "edition",
                mimeType = DmTopicWire.EVENT_MIME,
                body = mapOf("body" to "{\"v\":1}"),
                liveUpdate = true,
            ),
        )
        assertNull(
            timelineMessageSemantics(
                daemonId = "event",
                latestEditionId = "edition",
                mimeType = DmTopicWire.EVENT_MIME,
                body = mapOf("body" to "{\"v\":1}"),
                liveUpdate = false,
            ),
        )
    }
}
