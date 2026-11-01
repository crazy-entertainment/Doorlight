package app.sybl.sybl

/** Projects only daemon-folded search results. Scope and membership are supplied
 * by the owning request; this never authorizes a conversation or a channel. */
internal object HistorySearchProjection {
    private val identity = Regex("[0-9a-f]{40}")
    private val legacyRoom = Regex("^\\[#([a-z0-9][a-z0-9-]{0,31})] ")
    private const val MAX_SNIPPET = 512
    const val MAX_CALLBACK_BYTES = 8 * 1024 * 1024
    private val fieldLimits = linkedMapOf(
        "id" to 40, "author" to 40, "type" to 128, "timestamp" to 32,
        "body" to TimelineWireBounds.MAX_TEXT_CODE_UNITS,
        "displayName" to TimelineWireBounds.MAX_DISPLAY_NAME_CODE_UNITS,
        "react-to" to 40, "edit" to 40, DmTopicWire.ITEM_FIELD to 32, "sybl-room-v1" to 32,
    )

    /** Copy only recognized fields while SWIG owns the source. Budget includes
     * UTF-8 keys and values and is shared across the whole callback. */
    fun copyFields(remainingBytes: Int, read: (String) -> String?): Pair<Map<String, String>, Int>? {
        if (remainingBytes !in 0..MAX_CALLBACK_BYTES) return null
        var remaining = remainingBytes
        val copied = mutableMapOf<String, String>()
        for ((field, limit) in fieldLimits) {
            val value = read(field) ?: continue
            val bytes = TimelineWireBounds.utf8Bytes(value, limit) ?: return null
            if (field.length > remaining || bytes > remaining - field.length) return null
            remaining -= field.length + bytes
            copied[field] = value
        }
        return copied to remaining
    }

    fun literalPattern(input: String): String? {
        if (input.isEmpty() || input.length > 256 || !validText(input, true)) return null
        val syntax = "\\^$.|?*+()[]{}"
        return buildString {
            for (char in input) {
                if (char in syntax) append('\\')
                append(char)
            }
        }
    }

    fun project(raw: Map<String, String>, group: Boolean, literal: String): Map<String, Any>? {
        if (literal.isEmpty() || literal.length > 256 || !validText(literal, true)) return null
        val id = raw["id"] ?: return null
        val author = raw["author"] ?: return null
        if (!identity.matches(id) || !identity.matches(author) ||
            !raw["react-to"].isNullOrEmpty() || !raw["edit"].isNullOrEmpty()) return null
        val file = when (raw["type"]) {
            "text/plain" -> false
            "application/data-transfer+json" -> true
            else -> return null
        }
        val timestamp = raw["timestamp"]?.toLongOrNull() ?: return null
        if (timestamp !in 0L..8640000000000L) return null
        var content = raw[if (file) "displayName" else "body"] ?: return null
        val channel = if (group) {
            if (!raw[DmTopicWire.ITEM_FIELD].isNullOrEmpty()) return null
            // File names are literal names, never the legacy text-room codec.
            val room = GroupPolicy.messageRoom(if (file) "" else content, raw["sybl-room-v1"])
                ?: return null
            if (!file) content = content.replaceFirst(legacyRoom, "")
            room
        } else {
            if (raw.containsKey("sybl-room-v1")) return null
            val tag = raw[DmTopicWire.ITEM_FIELD]
            if (tag != null && !DmTopicWire.itemTag(tag).tagged) return null
            tag ?: DmTopicWire.MAIN
        }
        // Matching the stripped visible content prevents a room prefix from
        // becoming a false result. No secondary history or search index is kept.
        val match = content.indexOf(literal, ignoreCase = true)
        if (match < 0) return null
        var start = (match - 96).coerceAtLeast(0)
        if (start > 0 && content[start].isLowSurrogate()) start--
        var end = (start + MAX_SNIPPET).coerceAtMost(content.length)
        if (end < content.length && content[end - 1].isHighSurrogate()) end--
        val snippet = content.substring(start, end)
        if (!validText(snippet, false)) return null
        return mapOf(
            "messageId" to id, "authorId" to author, "channelId" to channel,
            "timestampSeconds" to timestamp, "snippet" to snippet,
            "contentKind" to if (file) "file" else "text",
        )
    }

    private fun validText(value: String, singleLine: Boolean): Boolean {
        var index = 0
        while (index < value.length) {
            val char = value[index++]
            if ((char.code < 32 && (singleLine || char !in "\t\r\n")) || char.code == 127) return false
            if (char.isHighSurrogate()) {
                if (index == value.length || !value[index++].isLowSurrogate()) return false
            } else if (char.isLowSurrogate()) return false
        }
        return true
    }
}
