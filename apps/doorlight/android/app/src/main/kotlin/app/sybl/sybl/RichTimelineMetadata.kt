package app.sybl.sybl

import org.json.JSONObject

internal object RichTimelineMetadata {
    const val STICKER_MIME = "application/x-sybl-sticker+json"
    private val operation = Regex("[0-9a-f]{32}")
    private val room = Regex("[a-z0-9][a-z0-9-]{0,31}")
    private val stickerField = "(?:\"v\"\\s*:\\s*1|\"assetId\"\\s*:\\s*\"[a-z0-9]+(?:[.-][a-z0-9]+)*\"|\"presentation\"\\s*:\\s*\"(?:inline|hologram)\")"
    // Android uses ICU regex: literal closing braces must be escaped too.
    private val stickerSyntax = Regex("\\s*\\{\\s*$stickerField(?:\\s*,\\s*$stickerField){2}\\s*\\}\\s*")

    /** A durable hologram never becomes an ordinary notification, including
     * malformed or duplicate-key representations of its presentation field. */
    fun stickerNotification(body: String): String? {
        if (!boundedBody(body) || !stickerSyntax.matches(body)) return null
        return try {
            val value = JSONObject(body)
            if (value.keys().asSequence().toSet() != setOf("v", "assetId", "presentation") ||
                value.getString("assetId").length > 128 || value.getString("presentation") != "inline") null
            else "Sticker"
        } catch (_: Exception) { null }
    }

    /** Only called on daemon-authenticated commit fields, never a content body. */
    fun project(body: Map<String, String>, group: Boolean): Map<String, String>? {
        // Reaction additions and folded removals belong only to reaction metadata.
        if (!body["react-to"].isNullOrEmpty()) return null
        val topic = body[DmTopicWire.ITEM_FIELD]
        val roomId = body["sybl-room-v1"]
        val operationId = body["sybl-op-v1"]
        val media = body["sybl-media-v1"]
        val replyTo = body["reply-to"]
        if ((group && !topic.isNullOrEmpty()) ||
            (!group && roomId != null) ||
            (roomId != null && !room.matches(roomId)) ||
            (operationId != null && !operation.matches(operationId)) ||
            (media != null && !boundedBody(media)) ||
            (replyTo != null && !TimelineWireBounds.optional(replyTo, TimelineWireBounds.MAX_DAEMON_ID_CODE_UNITS))) return null
        return buildMap {
            roomId?.let { put("roomId", it) }
            operationId?.let { put("operationId", it) }
            media?.let { put("mediaMetadata", it) }
            replyTo?.let { put("replyTo", it) }
        }
    }

    fun boundedBody(body: String): Boolean = body.isNotEmpty() &&
        body.length <= 1024 &&
        (TimelineWireBounds.utf8Bytes(body, 1024)?.let { it <= 1024 } == true)
}
