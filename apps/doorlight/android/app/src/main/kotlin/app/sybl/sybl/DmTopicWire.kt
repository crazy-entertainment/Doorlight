package app.sybl.sybl

internal data class DmTopicTag(val topicId: String, val tagged: Boolean)

internal data class DmTopicStateEnvelope(
    val commitId: String,
    val authorId: String,
    val mimeType: String,
    val topicId: String,
    val topicTagged: Boolean,
    val linearizedParent: String,
    val eventBody: String?,
    val daemonRead: Boolean,
) {
    fun toMap(): Map<String, Any?> = buildMap {
        put("commitId", commitId)
        put("authorId", authorId)
        put("mimeType", mimeType)
        put("topicId", topicId)
        put("topicTagged", topicTagged)
        put("daemonRead", daemonRead)
        put("linearizedParent", linearizedParent)
        eventBody?.let { put("eventBody", it) }
    }
}

internal object DmTopicWire {
    const val MAIN = "main"
    const val ITEM_FIELD = "sybl-topic-v1"
    const val EVENT_MIME = "application/x-sybl-dm-topic+json"
    const val MAX_EVENT_BYTES = 4096
    const val MAX_STATE_PAGE_ITEMS = 200
    private const val MAX_ID_BYTES = 1024
    private val customId = Regex("^[a-f0-9]{32}$")

    fun itemTag(value: String?): DmTopicTag = when {
        value == MAIN -> DmTopicTag(MAIN, true)
        value != null && customId.matches(value) -> DmTopicTag(value, true)
        else -> DmTopicTag(MAIN, false)
    }

    fun validOutgoingTopic(value: String): Boolean = value.isEmpty() || itemTag(value).tagged

    fun stateEnvelope(
        commitId: String,
        mimeType: String,
        linearizedParent: String,
        body: Map<String, String>,
        daemonRead: Boolean = false,
    ): DmTopicStateEnvelope? {
        val author = body["author"].orEmpty()
        if (!boundedId(commitId) || !boundedId(author)) return null
        if (linearizedParent.toByteArray(Charsets.UTF_8).size > MAX_ID_BYTES) return null
        if (mimeType == EVENT_MIME) {
            val event = body["body"].orEmpty()
            if (event.isEmpty() || event.toByteArray(Charsets.UTF_8).size > MAX_EVENT_BYTES) {
                return null
            }
            return DmTopicStateEnvelope(
                commitId,
                author,
                mimeType,
                MAIN,
                false,
                linearizedParent,
                event,
                false,
            )
        }
        if (mimeType != "text/plain" && mimeType != "application/data-transfer+json") {
            return null
        }
        val tag = itemTag(body[ITEM_FIELD])
        return DmTopicStateEnvelope(
            commitId,
            author,
            mimeType,
            tag.topicId,
            tag.tagged,
            linearizedParent,
            null,
            daemonRead,
        )
    }

    private fun boundedId(value: String): Boolean =
        value.isNotEmpty() && value.toByteArray(Charsets.UTF_8).size <= MAX_ID_BYTES
}
