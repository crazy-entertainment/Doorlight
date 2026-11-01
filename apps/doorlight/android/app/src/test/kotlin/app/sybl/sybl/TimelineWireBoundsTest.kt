package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TimelineWireBoundsTest {
    @Test
    fun countsUtf16AndUtf8WithoutAcceptingMalformedSurrogates() {
        assertEquals(5, TimelineWireBounds.utf8Bytes("hello", 5))
        assertEquals(2, TimelineWireBounds.utf8Bytes("\u00e9", 1))
        assertEquals(4, TimelineWireBounds.utf8Bytes("\ud83d\ude00", 2))
        assertNull(TimelineWireBounds.utf8Bytes("\ud83d\ude00", 1))
        assertNull(TimelineWireBounds.utf8Bytes("\ud800", 1))
        assertNull(TimelineWireBounds.utf8Bytes("\udc00", 1))
    }

    @Test
    fun enforcesExactTimelineFieldAndSnapshotBounds() {
        assertTrue(
            TimelineWireBounds.required(
                "x".repeat(TimelineWireBounds.MAX_TEXT_CODE_UNITS),
                TimelineWireBounds.MAX_TEXT_CODE_UNITS,
            ),
        )
        assertFalse(
            TimelineWireBounds.required(
                "x".repeat(TimelineWireBounds.MAX_TEXT_CODE_UNITS + 1),
                TimelineWireBounds.MAX_TEXT_CODE_UNITS,
            ),
        )
        assertFalse(TimelineWireBounds.required("", 1))
        assertTrue(TimelineWireBounds.optional("", 1))
        assertTrue(TimelineWireBounds.canAppendTimelineItem(0, 1, 128))
        assertFalse(
            TimelineWireBounds.canAppendTimelineItem(
                TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_ITEMS,
                1,
                1,
            ),
        )
        assertFalse(
            TimelineWireBounds.canAppendTimelineItem(
                1,
                TimelineWireBounds.MAX_TIMELINE_SNAPSHOT_BYTES - 1,
                1,
            ),
        )
    }
}
