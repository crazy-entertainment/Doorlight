package app.sybl.sybl

import java.nio.charset.CharacterCodingException
import java.util.Base64

/**
 * Wire contract for the Jami account-profile fields Doorlight currently consumes.
 *
 * Values are rejected, never truncated, so Unicode grapheme clusters cannot
 * be split. [TimelineWireBounds.utf8Bytes] provides the shared strict Unicode
 * validation used by the other daemon-to-Flutter text surfaces.
 */
internal object ProfileWireBounds {
    const val MAX_DISPLAY_NAME_UTF8_BYTES = 256
    const val MAX_AVATAR_BYTES = 256 * 1024
    const val MAX_AVATAR_BASE64_CHARS = 350 * 1024
    const val MAX_VCARD_BYTES = MAX_AVATAR_BASE64_CHARS + 4096

    data class Profile(
        val displayName: String,
        val avatarBase64: String,
    )

    fun displayName(value: String): String? {
        val bytes = TimelineWireBounds.utf8Bytes(
            value,
            MAX_DISPLAY_NAME_UTF8_BYTES,
        ) ?: return null
        return value.takeIf { bytes <= MAX_DISPLAY_NAME_UTF8_BYTES }
    }

    fun avatar(value: String): String? {
        if (value.length > MAX_AVATAR_BASE64_CHARS) return null
        if (value.isEmpty()) return ""
        val bytes = try {
            Base64.getDecoder().decode(value)
        } catch (_: IllegalArgumentException) {
            return null
        }
        return value.takeIf { bytes.size <= MAX_AVATAR_BYTES }
    }

    fun profileVcard(bytes: ByteArray): Profile? {
        if (bytes.size > MAX_VCARD_BYTES) return null
        val content = try {
            bytes.decodeToString(throwOnInvalidSequence = true)
        } catch (_: CharacterCodingException) {
            return null
        }
        var displayName = ""
        var avatarBase64 = ""
        var sawDisplayName = false
        var sawAvatar = false
        for (rawLine in content.lineSequence()) {
            val line = rawLine.removeSuffix("\r")
            val separator = line.indexOf(':')
            if (separator <= 0) continue
            val key = line.substring(0, separator)
            val value = line.substring(separator + 1)
            if (!sawDisplayName && key == "FN") {
                displayName = value
                sawDisplayName = true
            } else if (!sawAvatar && (key == "PHOTO" || key.startsWith("PHOTO;"))) {
                avatarBase64 = value
                sawAvatar = true
            }
        }
        if (!sawDisplayName) return null
        return Profile(
            displayName = displayName(displayName) ?: return null,
            avatarBase64 = avatar(avatarBase64) ?: "",
        )
    }
}
