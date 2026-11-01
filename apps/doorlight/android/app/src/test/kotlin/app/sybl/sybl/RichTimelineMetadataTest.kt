package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class RichTimelineMetadataTest {
    @Test fun reactionCommitsNeverBecomeOrdinaryMessagesIncludingFoldedRemoval() {
        for (body in listOf("👍", "")) {
            assertNull(RichTimelineMetadata.project(mapOf("react-to" to "a".repeat(40), "body" to body), false))
            assertNull(RichTimelineMetadata.project(mapOf("react-to" to "a".repeat(40), "body" to body), true))
        }
        assertNotNull(RichTimelineMetadata.project(mapOf("body" to "ordinary", "react-to" to ""), false))
    }
    @Test fun replyReferencesAreBoundedCommitMetadata() {
        assertEquals(mapOf("replyTo" to "a".repeat(40)),
            RichTimelineMetadata.project(mapOf("reply-to" to "a".repeat(40), "quotedText" to "untrusted"), false))
        assertNull(RichTimelineMetadata.project(mapOf("reply-to" to "x".repeat(1025)), false))
        assertNull(RichTimelineMetadata.project(mapOf("reply-to" to "\uD800"), false))
    }
    @Test fun onlyOrdinaryWellFormedStickersProduceNotificationCards() {
        val inline = """{"v":1,"assetId":"sybl.chubby-cats.angry.v1","presentation":"inline"}"""
        assertEquals("Sticker", RichTimelineMetadata.stickerNotification(inline))
        assertEquals("Sticker", RichTimelineMetadata.stickerNotification(
            """{"presentation":"inline","assetId":"unknown.asset.v1","v":1}"""))
        assertNull(RichTimelineMetadata.stickerNotification(inline.replace("inline", "hologram")))
        assertNull(RichTimelineMetadata.stickerNotification(inline.replace("\"v\":1", "\"v\":2")))
        assertNull(RichTimelineMetadata.stickerNotification(inline.replace("inline", "unsupported")))
        assertNull(RichTimelineMetadata.stickerNotification(
            inline.dropLast(1) + """, "presentation":"hologram"}"""))
        assertNull(RichTimelineMetadata.stickerNotification(inline.replace("sybl.chubby-cats.angry.v1", "../outside")))
        assertNull(RichTimelineMetadata.stickerNotification("x".repeat(1025)))
    }

    @Test fun exactRoutingAndOperation() {
        val fields = mapOf("sybl-room-v1" to "games", "sybl-op-v1" to "a".repeat(32))
        assertEquals(mapOf("roomId" to "games", "operationId" to "a".repeat(32)),
            RichTimelineMetadata.project(fields, true))
        assertNull(RichTimelineMetadata.project(fields, false))
        assertNull(RichTimelineMetadata.project(fields + (DmTopicWire.ITEM_FIELD to "main"), true))
        assertNull(RichTimelineMetadata.project(mapOf("sybl-op-v1" to "bad"), false))
    }

    @Test fun boundedUnsupportedMetadataAndImmutableSticker() {
        assertNotNull(RichTimelineMetadata.project(mapOf("sybl-media-v1" to "{\"v\":2}"), false))
        assertNull(RichTimelineMetadata.project(mapOf("sybl-media-v1" to "😀".repeat(257)), false))
        val body = mapOf("body" to "{\"v\":2}")
        assertNotNull(timelineMessageSemantics("id", null, RichTimelineMetadata.STICKER_MIME, body, false))
        assertNull(timelineMessageSemantics("id", "edit", RichTimelineMetadata.STICKER_MIME, body, false))
        assertNull(timelineMessageSemantics("id", null, RichTimelineMetadata.STICKER_MIME, body, true))
    }
}
