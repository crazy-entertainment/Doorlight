package app.sybl.sybl

/** Only projects daemon-authenticated folded reaction maps, never message text. */
internal object ReactionProjection {
    const val MAX_ENTRIES = 512
    val palette = setOf("👍", "❤️", "😂", "😮", "😢", "🙏")
    private val identity = Regex("[0-9a-f]{40}")
    fun validIdentity(value: String): Boolean = identity.matches(value)

    fun project(
        messageId: String,
        size: Int,
        read: (Int) -> Map<String, String>,
        acceptsAuthor: (String) -> Boolean,
    ): Map<String, Any> {
        var complete = size in 0..MAX_ENTRIES
        val entries = sortedMapOf<String, Map<String, String>>()
        val ambiguous = mutableSetOf<String>()
        for (index in 0 until size.coerceIn(0, MAX_ENTRIES)) {
            val raw = read(index)
            val emoji = raw["body"] ?: continue
            if (emoji !in palette) continue
            val id = raw["id"].orEmpty()
            val author = raw["author"].orEmpty()
            if (!identity.matches(id) || id == messageId || !identity.matches(author) ||
                raw["react-to"] != messageId || !acceptsAuthor(author)) {
                complete = false
                continue
            }
            if (id in ambiguous) continue
            val entry = mapOf("commitId" to id, "authorId" to author, "emoji" to emoji)
            val previous = entries[id]
            if (previous != null && previous != entry) {
                entries.remove(id)
                ambiguous.add(id)
                complete = false
            } else entries[id] = entry
        }
        return mapOf("messageId" to messageId, "complete" to complete, "entries" to entries.values.toList())
    }
}
