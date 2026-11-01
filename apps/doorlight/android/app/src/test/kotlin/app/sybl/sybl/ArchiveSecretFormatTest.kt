package app.sybl.sybl

import java.nio.charset.StandardCharsets
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ArchiveSecretFormatTest {
    @Test
    fun generatesIndependentUrlSafe256BitSecrets() {
        val first = ArchiveSecretFormat.generate()
        val second = ArchiveSecretFormat.generate()

        assertEquals(43, first.length)
        assertTrue(first.matches(Regex("^[A-Za-z0-9_-]+$")))
        assertNotEquals(first, second)
        assertEquals(first, ArchiveSecretFormat.decode(first.toByteArray(StandardCharsets.US_ASCII)))
    }

    @Test
    fun rejectsTruncatedMalformedAndNonAsciiRecords() {
        for (value in listOf("", "a".repeat(42), "a".repeat(44), "a".repeat(42) + "=", " ".repeat(43))) {
            assertThrows(IllegalArgumentException::class.java) {
                ArchiveSecretFormat.decode(value.toByteArray(StandardCharsets.US_ASCII))
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            ArchiveSecretFormat.decode(ByteArray(43) { 0xff.toByte() })
        }
    }
}
