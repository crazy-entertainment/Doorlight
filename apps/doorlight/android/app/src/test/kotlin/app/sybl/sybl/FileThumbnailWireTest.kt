package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FileThumbnailWireTest {
    @Test fun `empty identifiers are rejected for previews and declines`() {
        for ((conversationId, fileId) in listOf("" to "file", "conversation" to "")) {
            assertNull(FileThumbnailWire.encode(conversationId, fileId, "AAAA", 0))
            assertNull(FileThumbnailWire.decode("SYBLTHUMB1\n$conversationId\n$fileId\n0\nAAAA", 0))
            assertNull(FileThumbnailWire.encodeDeclined(conversationId, fileId))
            assertNull(FileThumbnailWire.decodeDeclined("SYBLDECLINED1\n$conversationId\n$fileId"))
        }
    }

    @Test fun `declines admit exact limits and reject oversized fields bodies and delimiter floods`() {
        val maximum = FileThumbnailWire.encodeDeclined("c".repeat(4096), "f".repeat(4096))!!
        assertEquals(FileThumbnailWire.MAX_DECLINED_BODY_BYTES, maximum.length)
        assertEquals(FileDeclinedPacket("c".repeat(4096), "f".repeat(4096)), FileThumbnailWire.decodeDeclined(maximum))
        assertNull(FileThumbnailWire.decodeDeclined(maximum + "x"))
        assertNull(FileThumbnailWire.decodeDeclined("SYBLDECLINED1\n" + "c".repeat(4097) + "\nf"))
        assertNull(FileThumbnailWire.decodeDeclined("\n".repeat(100_000)))
        val unicode = "é".repeat(2048)
        assertEquals(FileDeclinedPacket(unicode, unicode), FileThumbnailWire.decodeDeclined("SYBLDECLINED1\n$unicode\n$unicode"))
        assertNull(FileThumbnailWire.decodeDeclined("SYBLDECLINED1\n$unicode\n${unicode}é"))
    }
    @Test
    fun `fresh bounded packet round trips and malformed input fails closed`() {
        val now = 80_000L
        val png = "A".repeat(128)
        val encoded = FileThumbnailWire.encode("conversation", "file-id", png, now)!!

        assertEquals("SYBLTHUMB1\nconversation\nfile-id\n80000\n$png", encoded)
        assertEquals(
            FileThumbnailPacket("conversation", "file-id", png),
            FileThumbnailWire.decode(encoded, now),
        )
        assertNull(FileThumbnailWire.decode(encoded, now + FileThumbnailWire.MAX_AGE_MS + 1))
        assertNull(FileThumbnailWire.encode("bad\nconversation", "file", png, now))
        assertNull(FileThumbnailWire.encode("conversation", "bad\u007ffile", png, now))
        assertNull(FileThumbnailWire.encode("conversation", "file", "not base64", now))
        assertNull(FileThumbnailWire.encode("conversation", "file", png, -1))
        assertNull(
            FileThumbnailWire.decode(
                "x".repeat(FileThumbnailWire.MAX_BODY_BYTES + 1),
                now,
            ),
        )

        val declined = FileThumbnailWire.encodeDeclined("conversation", "file-id")!!
        assertEquals("SYBLDECLINED1\nconversation\nfile-id", declined)
        assertEquals(
            FileDeclinedPacket("conversation", "file-id"),
            FileThumbnailWire.decodeDeclined(declined),
        )
        assertNull(FileThumbnailWire.decodeDeclined("SYBLDECLINED1\nconversation\nbad\nfile"))
        assertNull(FileThumbnailWire.encodeDeclined("bad\nconversation", "file"))
    }
}
