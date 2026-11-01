package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class HistorySearchProjectionTest {
    @Test fun callbackCopiesHaveAnAggregateUtf8BudgetAndFieldBounds() {
        val raw = mapOf("body" to "👍", "unrecognized" to "private ignored metadata")
        val copied = HistorySearchProjection.copyFields(8) { raw[it] }!!
        assertEquals(mapOf("body" to "👍"), copied.first)
        assertEquals(0, copied.second)
        assertNull(HistorySearchProjection.copyFields(7) { raw[it] })
        assertNull(HistorySearchProjection.copyFields(copied.second) { raw[it] })
        assertNull(HistorySearchProjection.copyFields(1024) { if (it == "author") "x".repeat(41) else null })
        assertNull(HistorySearchProjection.copyFields(1024) { if (it == "body") "\uD800" else null })
    }
    @Test fun nativePatternsTreatEveryQueryAsALiteral() {
        val input = "a.b+[c](d)? {e} ^f$ | g\\h"
        val pattern = HistorySearchProjection.literalPattern(input)!!
        assertTrue(Regex(pattern).containsMatchIn(input))
        for (bad in listOf("", "x".repeat(257), "a\nb", "\uD800")) {
            assertNull(HistorySearchProjection.literalPattern(bad))
        }
    }
    private fun message(body: String = "A visible message") = mapOf(
        "id" to "a".repeat(40), "author" to "b".repeat(40),
        "type" to "text/plain", "body" to body, "timestamp" to "1700000000",
    )

    @Test fun stripsRoomCodecBeforeMatching() {
        val raw = message("[#games] A visible message")
        assertNull(HistorySearchProjection.project(raw, true, "games"))
        val hit = HistorySearchProjection.project(raw, true, "visible")!!
        assertEquals("games", hit["channelId"])
        assertEquals("A visible message", hit["snippet"])
        assertNull(HistorySearchProjection.project(raw + ("sybl-room-v1" to "clips"), true, "visible"))
    }

    @Test fun rejectsControlsAndMalformedTopics() {
        for (extra in listOf(
            "react-to" to "c".repeat(40), "edit" to "c".repeat(40),
            "sybl-topic-v1" to "unknown", "sybl-room-v1" to "general",
            "author" to "untrusted name", "timestamp" to "-1",
            "type" to "application/x-sybl-dm-topic+json",
        )) assertNull(HistorySearchProjection.project(message() + extra, false, "visible"))
        assertEquals("main", HistorySearchProjection.project(message(), false, "VISIBLE")!!["channelId"])
        assertNull(HistorySearchProjection.project(message(), false, "[.*]"))
    }

    @Test fun snippetsAreBoundedWithoutSplittingUnicode() {
        val text = "x".repeat(700) + "👍 visible " + "y".repeat(700)
        val snippet = HistorySearchProjection.project(message(text), false, "visible")!!["snippet"] as String
        assertTrue(snippet.length <= 512)
        assertTrue(snippet.contains("👍 visible"))
        assertEquals(snippet, snippet.toByteArray(Charsets.UTF_8).toString(Charsets.UTF_8))
        assertNull(HistorySearchProjection.project(message("visible\u0000"), false, "visible"))
    }

    @Test fun fileNamesDoNotBecomeRoomPrefixes() {
        val raw = message() + mapOf("type" to "application/data-transfer+json", "displayName" to "[#games] visible.txt")
        val hit = HistorySearchProjection.project(raw, true, "games")!!
        assertEquals("general", hit["channelId"])
        assertEquals("file", hit["contentKind"])
        assertEquals("[#games] visible.txt", hit["snippet"])
    }
}
