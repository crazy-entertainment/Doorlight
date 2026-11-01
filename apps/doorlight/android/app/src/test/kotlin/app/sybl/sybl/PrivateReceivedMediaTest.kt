package app.sybl.sybl

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class PrivateReceivedMediaTest {
    @Test fun generatedDestinationsAreDistinctAndRejectExternalFiles() {
        val root = Files.createTempDirectory("private-media-test").toFile()
        try {
            val first = reserveReceivedMediaFile(root, false)
            val second = reserveReceivedMediaFile(root, false)
            val gif = reserveReceivedMediaFile(root, true)
            assertNotEquals(first, second)
            assertEquals("voice.m4a", first.name)
            assertEquals("media.gif", gif.name)
            assertFalse(first.exists())
            assertFalse(gif.exists())
            assertTrue(first.parentFile.isDirectory)
            assertTrue(first.createNewFile())
            assertTrue(gif.createNewFile())
            assertTrue(isPrivateReceivedMediaFile(root, first))
            assertTrue(isPrivateReceivedMediaFile(root, gif))
            assertFalse(isPrivateReceivedMediaFile(root.parentFile, first))
            assertFalse(isPrivateReceivedMediaFile(root, root))
            assertEquals(0L, first.length())
        } finally { root.deleteRecursively() }
    }
}
