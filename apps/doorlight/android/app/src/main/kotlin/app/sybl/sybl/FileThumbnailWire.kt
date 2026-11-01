package app.sybl.sybl

internal data class FileThumbnailPacket(
    val conversationId: String,
    val fileId: String,
    val pngBase64: String,
)

internal data class FileDeclinedPacket(
    val conversationId: String,
    val fileId: String,
)

/** Tiny, ephemeral preview packet for an already-authenticated file offer. */
internal object FileThumbnailWire {
    private const val PREFIX = "SYBLTHUMB1"
    private const val DECLINED_PREFIX = "SYBLDECLINED1"
    const val MAX_PNG_BYTES = 24 * 1024
    const val MAX_BASE64_CHARS = 32 * 1024
    const val MAX_ID_BYTES = 4096
    const val MAX_DECLINED_BODY_BYTES = 13 + 2 + MAX_ID_BYTES * 2
    const val MAX_BODY_BYTES = MAX_BASE64_CHARS + MAX_ID_BYTES * 2 + 96
    const val MAX_AGE_MS = 60_000L

    private fun validId(value: String): Boolean {
        if (value.isEmpty() || value.length > MAX_ID_BYTES) return false
        val bytes = value.toByteArray(Charsets.UTF_8)
        return bytes.size <= MAX_ID_BYTES &&
            value.none { it.code < 0x20 || it.code == 0x7f || it == '"' || it == '\\' }
    }

    private fun validBase64(value: String): Boolean =
        value.isNotEmpty() &&
            value.length <= MAX_BASE64_CHARS &&
            value.length % 4 == 0 &&
            value.matches(Regex("""[A-Za-z0-9+/]*={0,2}"""))

    fun encode(
        conversationId: String,
        fileId: String,
        pngBase64: String,
        nowMs: Long,
    ): String? {
        if (nowMs < 0 ||
            !validId(conversationId) ||
            !validId(fileId) ||
            !validBase64(pngBase64)
        ) {
            return null
        }
        return "$PREFIX\n$conversationId\n$fileId\n$nowMs\n$pngBase64"
            .takeIf { it.toByteArray(Charsets.UTF_8).size <= MAX_BODY_BYTES }
    }

    fun decode(body: String, nowMs: Long): FileThumbnailPacket? {
        if (body.length > MAX_BODY_BYTES) return null
        if (body.toByteArray(Charsets.UTF_8).size > MAX_BODY_BYTES) return null
        val parts = body.split('\n')
        if (parts.size != 5 || parts[0] != PREFIX) return null
        val conversationId = parts[1]
        val fileId = parts[2]
        val sentAt = parts[3].toLongOrNull() ?: return null
        val pngBase64 = parts[4]
        if (!validId(conversationId) ||
            !validId(fileId) ||
            !validBase64(pngBase64) ||
            sentAt < 0 ||
            sentAt < nowMs - MAX_AGE_MS ||
            sentAt > nowMs + MAX_AGE_MS
        ) {
            return null
        }
        return FileThumbnailPacket(conversationId, fileId, pngBase64)
    }

    fun encodeDeclined(conversationId: String, fileId: String): String? =
        if (validId(conversationId) && validId(fileId)) {
            "$DECLINED_PREFIX\n$conversationId\n$fileId"
        } else {
            null
        }

    fun decodeDeclined(body: String): FileDeclinedPacket? {
        // UTF-8 has at least as many bytes as UTF-16 units. Bound the conversion
        // itself before measuring bytes or allocating parsed fields.
        if (body.length > MAX_DECLINED_BODY_BYTES ||
            body.toByteArray(Charsets.UTF_8).size > MAX_DECLINED_BODY_BYTES) return null
        val parts = body.split('\n')
        if (parts.size != 3 || parts[0] != DECLINED_PREFIX) return null
        return if (validId(parts[1]) && validId(parts[2])) {
            FileDeclinedPacket(parts[1], parts[2])
        } else {
            null
        }
    }
}
