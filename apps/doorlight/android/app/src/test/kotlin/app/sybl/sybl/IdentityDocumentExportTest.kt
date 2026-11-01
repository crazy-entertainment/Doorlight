package app.sybl.sybl

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class IdentityDocumentExportTest {
    @Test fun `retired Activity or account during a successful close still cleans destination`() {
        var current = true
        val destination = object : ByteArrayOutputStream() {
            override fun close() { current = false }
        }
        assertEquals(IdentityDocumentExportResult.CLEANED, IdentityDocumentExport.copy(
            { ByteArrayInputStream(byteArrayOf(1, 2)) }, { destination },
            { destination.reset(); true }, { false }, { current }))
        assertEquals(0, destination.size())
        assertEquals(IdentityDocumentExportResult.RESIDUE, IdentityDocumentExport.copy(
            { ByteArrayInputStream(byteArrayOf(1, 2)) }, { destination },
            { false }, { false }, { current }))
    }
    @Test fun `late close failure deletes destination after all bytes were accepted`() {
        val destination = object : ByteArrayOutputStream() {
            override fun close() { throw IOException("synthetic close failure") }
        }
        val outcome = IdentityDocumentExport.copy(
            { ByteArrayInputStream(byteArrayOf(1, 2, 3)) }, { destination },
            { destination.reset(); true }, { error("unneeded truncation") })
        assertEquals(IdentityDocumentExportResult.CLEANED, outcome)
        assertEquals(0, destination.size())
    }

    @Test fun `partial writes and failed deletion fall back to verified truncation`() {
        for (offset in 0..3) {
            val destination = object : ByteArrayOutputStream() {
                override fun write(bytes: ByteArray, start: Int, count: Int) {
                    super.write(bytes, start, offset)
                    throw IOException("synthetic write failure")
                }
            }
            val outcome = IdentityDocumentExport.copy(
                { ByteArrayInputStream(byteArrayOf(1, 2, 3)) }, { destination },
                { throw IOException("unsupported deletion") }, { destination.reset(); true })
            assertEquals(IdentityDocumentExportResult.CLEANED, outcome)
            assertEquals(0, destination.size())
        }
    }

    @Test fun `cleanup failure remains distinct from safe failure and successful backup`() {
        assertEquals(IdentityDocumentExportResult.RESIDUE, IdentityDocumentExport.copy(
            { ByteArrayInputStream(byteArrayOf(1)) }, { null }, { false }, { false }))
        val destination = ByteArrayOutputStream()
        assertEquals(IdentityDocumentExportResult.SAVED, IdentityDocumentExport.copy(
            { ByteArrayInputStream(byteArrayOf(1, 2)) }, { destination },
            { error("unexpected deletion") }, { error("unexpected truncation") }))
        assertArrayEquals(byteArrayOf(1, 2), destination.toByteArray())
    }
}
