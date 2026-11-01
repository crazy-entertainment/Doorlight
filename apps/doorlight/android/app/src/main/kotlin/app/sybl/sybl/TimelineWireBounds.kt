package app.sybl.sybl

/**
 * Native mirror of Dart's TimelineWireContract.
 *
 * Kotlin [String.length] is already measured in UTF-16 code units, but Java
 * strings can still contain unpaired surrogates. The Flutter codec must never
 * receive those, so validation also computes the strict UTF-8 byte count
 * without allocating a second string.
 */
internal object TimelineWireBounds {
    const val MAX_DAEMON_ID_CODE_UNITS = 1024
    const val MAX_AUTHOR_ID_CODE_UNITS = 1024
    const val MAX_TEXT_CODE_UNITS = 64 * 1024
    const val MAX_FILE_ID_CODE_UNITS = 4096
    const val MAX_DISPLAY_NAME_CODE_UNITS = 1024
    const val MAX_HASH_CODE_UNITS = 256
    const val MAX_TIMELINE_SNAPSHOT_ITEMS = 500
    const val MAX_TIMELINE_SNAPSHOT_BYTES = 8 * 1024 * 1024

    fun utf8Bytes(value: String, maxCodeUnits: Int): Int? {
        if (value.length > maxCodeUnits) return null
        var bytes = 0L
        var index = 0
        while (index < value.length) {
            val unit = value[index]
            when {
                unit.isHighSurrogate() -> {
                    if (index + 1 >= value.length || !value[index + 1].isLowSurrogate()) return null
                    bytes += 4
                    index += 2
                }
                unit.isLowSurrogate() -> return null
                unit.code <= 0x7f -> {
                    bytes += 1
                    index += 1
                }
                unit.code <= 0x7ff -> {
                    bytes += 2
                    index += 1
                }
                else -> {
                    bytes += 3
                    index += 1
                }
            }
            if (bytes > Int.MAX_VALUE) return null
        }
        return bytes.toInt()
    }

    fun required(value: String, maxCodeUnits: Int): Boolean =
        value.isNotEmpty() && utf8Bytes(value, maxCodeUnits) != null

    fun optional(value: String, maxCodeUnits: Int): Boolean =
        utf8Bytes(value, maxCodeUnits) != null

    fun canAppendTimelineItem(itemCount: Int, currentBytes: Int, itemBytes: Int): Boolean {
        if (itemCount !in 0 until MAX_TIMELINE_SNAPSHOT_ITEMS ||
            currentBytes < 0 || currentBytes > MAX_TIMELINE_SNAPSHOT_BYTES ||
            itemBytes < 0) return false
        val overhead = if (itemCount == 0) 0 else 1
        return itemBytes.toLong() + overhead + 1 <=
            (MAX_TIMELINE_SNAPSHOT_BYTES - currentBytes).toLong()
    }
}

internal data class TimelineWireItem(
    val value: Map<String, Any?>,
    val encodedBytes: Int,
)
