package app.sybl.sybl

import java.nio.charset.StandardCharsets
import java.util.Base64
import org.json.JSONObject

internal object GroupPolicy {
    const val MAX_TITLE_UTF8_BYTES = 128
    const val MAX_LAYOUT_UTF8_BYTES = 8192
    const val MAX_MEMBERS = 64
    private const val LAYOUT_PREFIX = "sybl-group-layout:v1:"
    private val LAYOUT = Regex("^sybl-group-layout:v1:[A-Za-z0-9_-]+$")
    private val roomId = Regex("^[a-z0-9][a-z0-9-]{0,31}$")
    private val messagePrefix = Regex("^\\[#([a-z0-9][a-z0-9-]{0,31})] ")
    private val defaultTextRooms = setOf("general", "games", "clips")

    fun messageRoom(body: String, richRoom: String? = null): String? {
        val legacy = messagePrefix.find(body)?.groupValues?.get(1)
        if (richRoom != null && (!roomId.matches(richRoom) ||
                (legacy != null && legacy != richRoom))) return null
        return richRoom ?: legacy ?: "general"
    }

    fun replyBody(room: String, text: String): String? =
        if (!roomId.matches(room)) null else "[#$room] $text"

    /** Mirrors the existing Dart layout projection, including its legacy fallback. */
    fun textRooms(description: String): Set<String> = try {
        require(layout(description) != null)
        val bytes = Base64.getUrlDecoder().decode(description.removePrefix(LAYOUT_PREFIX))
        val value = JSONObject(StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString())
        val collections = value.getJSONArray("c")
        val rooms = value.getJSONArray("r")
        require(collections.length() <= 16 && rooms.length() in 1..64)
        val ids = mutableSetOf<String>()
        fun name(entry: JSONObject): String {
            val name = entry.get("n") as? String ?: error("Invalid name")
            require(name.isNotEmpty() && name == name.trim() &&
                name.toByteArray(StandardCharsets.UTF_8).size <= 64 &&
                name.none { it.code < 0x20 || it.code == 0x7f })
            return name
        }
        fun identifier(entry: JSONObject): String {
            val id = entry.get("i") as? String ?: error("Invalid room")
            require(roomId.matches(id) && ids.add(id))
            name(entry)
            return id
        }
        for (i in 0 until collections.length()) identifier(collections.getJSONObject(i))
        val collectionIds = ids.toSet()
        val result = linkedSetOf<String>()
        for (i in 0 until rooms.length()) {
            val room = rooms.getJSONObject(i)
            val id = identifier(room)
            val kind = room.get("k") as? String ?: error("Invalid kind")
            require(kind == "text" || kind == "voice")
            if (room.has("c")) require(room.get("c") is String && room.getString("c") in collectionIds)
            if (kind == "text") result.add(id)
        }
        require(result.isNotEmpty())
        result.toSet()
    } catch (_: Exception) { defaultTextRooms }

    fun title(value: String): String? {
        val normalized = value.trim()
        if (normalized.isEmpty() ||
            normalized.any { it.code < 0x20 || it.code == 0x7f } ||
            normalized.toByteArray(StandardCharsets.UTF_8).size > MAX_TITLE_UTF8_BYTES
        ) return null
        return normalized
    }

    fun layout(value: String): String? =
        value.takeIf {
            it.startsWith(LAYOUT_PREFIX) &&
                it.toByteArray(StandardCharsets.UTF_8).size <= MAX_LAYOUT_UTF8_BYTES &&
                LAYOUT.matches(it)
        }

    fun newMemberIds(
        requested: Collection<String>,
        selfId: String,
        trustedIds: Set<String>,
        existingIds: Set<String> = emptySet(),
    ): List<String>? {
        val self = bareJamiId(selfId)
        val result = linkedSetOf<String>()
        for (raw in requested) {
            val id = bareJamiId(raw)
            if (id.isEmpty() || id == self || !trustedIds.contains(id) ||
                existingIds.contains(id) || !result.add(id)
            ) return null
        }
        if (result.isEmpty() || existingIds.size + result.size + 1 > MAX_MEMBERS) {
            return null
        }
        return result.sorted()
    }
}
