package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

class ProfileWireBoundsTest {
    @Test
    fun acceptsCompleteUnicodeValuesAtTheUtf8Boundary() {
        assertEquals(
            "x".repeat(ProfileWireBounds.MAX_DISPLAY_NAME_UTF8_BYTES),
            ProfileWireBounds.displayName(
                "x".repeat(ProfileWireBounds.MAX_DISPLAY_NAME_UTF8_BYTES),
            ),
        )
        val emojiBoundary = "\ud83d\ude00".repeat(
            ProfileWireBounds.MAX_DISPLAY_NAME_UTF8_BYTES / 4,
        )
        assertEquals(emojiBoundary, ProfileWireBounds.displayName(emojiBoundary))
    }

    @Test
    fun rejectsOversizedAndMalformedValuesInsteadOfTruncating() {
        assertNull(
            ProfileWireBounds.displayName(
                "x".repeat(ProfileWireBounds.MAX_DISPLAY_NAME_UTF8_BYTES + 1),
            ),
        )
        assertNull(ProfileWireBounds.displayName("\ud800"))
        assertNull(ProfileWireBounds.displayName("\udc00"))
    }

    @Test
    fun avatarRejectsMalformedAndOversizedPayloads() {
        val valid = Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3))
        assertEquals(valid, ProfileWireBounds.avatar(valid))
        assertNull(ProfileWireBounds.avatar("not base64"))
        assertNull(
            ProfileWireBounds.avatar(
                Base64.getEncoder().encodeToString(
                    ByteArray(ProfileWireBounds.MAX_AVATAR_BYTES + 1),
                ),
            ),
        )
    }

    @Test
    fun profileVcardProjectsThePeerNameAndAvatar() {
        val avatar = Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3))
        val profile = ProfileWireBounds.profileVcard(
            """
            BEGIN:VCARD
            VERSION:2.1
            FN:Mara 😀
            PHOTO;ENCODING=BASE64;TYPE=JPEG:$avatar
            END:VCARD
            """.trimIndent().encodeToByteArray(),
        )

        assertEquals("Mara 😀", profile?.displayName)
        assertEquals(avatar, profile?.avatarBase64)
    }

    @Test
    fun profileVcardRejectsInvalidUtf8AndBoundViolations() {
        assertNull(ProfileWireBounds.profileVcard("VERSION:2.1".encodeToByteArray()))
        assertNull(ProfileWireBounds.profileVcard(byteArrayOf(0xc3.toByte(), 0x28)))
        assertNull(
            ProfileWireBounds.profileVcard(
                "FN:${"x".repeat(ProfileWireBounds.MAX_DISPLAY_NAME_UTF8_BYTES + 1)}"
                    .encodeToByteArray(),
            ),
        )
        assertNull(
            ProfileWireBounds.profileVcard(
                ByteArray(ProfileWireBounds.MAX_VCARD_BYTES + 1),
            ),
        )
        assertEquals(
            "",
            ProfileWireBounds.profileVcard(
                "FN:Mara\nPHOTOGRAPH:not base64".encodeToByteArray(),
            )?.avatarBase64,
        )
        val invalidAvatar = ProfileWireBounds.profileVcard(
            "FN:Mara\nPHOTO:not base64".encodeToByteArray(),
        )
        assertEquals("Mara", invalidAvatar?.displayName)
        assertEquals("", invalidAvatar?.avatarBase64)
    }
}
