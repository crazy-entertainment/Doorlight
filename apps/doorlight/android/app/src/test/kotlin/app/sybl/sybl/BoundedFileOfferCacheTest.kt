package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class BoundedFileOfferCacheTest {
    @Test
    fun distinctSignedInteractionsCannotReplaceEachOthersPolicy() {
        val cache = BoundedFileCache<FileOfferKey, FileOffer>(2)
        val first = FileOfferKey("account", "peer", "conversation", "first", "same-file")
        val second = first.copy(interactionId = "second")
        val safe = FileOffer(12, "safe.txt", "peer", false, null)
        val media = FileOffer(24, "clip.gif", "peer", false, "{\"v\":1,\"kind\":\"gif\"}")
        assertNull(cache.putIfAbsent(first, safe))
        assertNull(cache.putIfAbsent(second, media))
        assertEquals(safe, cache.get(first))
        assertEquals(media, cache.get(second))
        assertEquals(safe, cache.putIfAbsent(first, media))
        assertEquals(safe, cache.get(first))
    }

    @Test
    fun adversarialHistoryCannotGrowTheOfferCache() {
        val cache = BoundedFileCache<FileOfferKey, FileOffer>(8)
        repeat(100_000) { index ->
            cache.putIfAbsent(
                FileOfferKey("account", "peer", "conversation", "$index", "file-$index"),
                FileOffer(index.toLong(), "file", "peer", false, null),
            )
        }
        assertEquals(8, cache.size())
        assertNull(cache.get(FileOfferKey("account", "peer", "conversation", "0", "file-0")))
        cache.removeWhere { it.peerId == "peer" }
        assertEquals(0, cache.size())
    }
}
