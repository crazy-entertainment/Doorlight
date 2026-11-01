package app.sybl.sybl

import java.security.MessageDigest

/** Bounded process-lifetime replay memory; saturation suppresses effects rather
 * than forgetting old commits. Timeline/history delivery remains independent. */
internal class LiveMessageEffects(private val capacity: Int = 32768) {
    private val seen = HashSet<String>()

    @Synchronized
    fun admit(account: String, conversation: String, value: Map<String, Any?>): Boolean {
        val id = value["daemonId"] as? String ?: return false
        if (id.isEmpty() || id.length > 128 || account.length > 128 || conversation.length > 1024 ||
            value["versionId"] != id || value["deleted"] == true || value["operation"] != null ||
            value["mimeType"] !in setOf("text/plain", "application/data-transfer+json", RichTimelineMetadata.STICKER_MIME)) return false
        val digest = MessageDigest.getInstance("SHA-256")
        for (part in listOf(account, conversation, id)) {
            val bytes = part.toByteArray(Charsets.UTF_8)
            digest.update(byteArrayOf((bytes.size ushr 24).toByte(), (bytes.size ushr 16).toByte(),
                (bytes.size ushr 8).toByte(), bytes.size.toByte()))
            digest.update(bytes)
        }
        val key = digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
        if (seen.size >= capacity || key in seen) return false
        return seen.add(key)
    }
}

/**
 * The mutation metadata attached to one daemon-owned, folded swarm message.
 *
 * libjami keeps the original interaction id stable and exposes the commit that
 * produced its current body through `latestEditionId`. File-message editions
 * are removals: libjami folds them by clearing `fileId`.
 */
internal data class TimelineMessageSemantics(
    val versionId: String,
    val operation: String?,
    val deleted: Boolean,
)

internal fun timelineMessageSemantics(
    daemonId: String?,
    latestEditionId: String?,
    mimeType: String?,
    body: Map<String, String>,
    liveUpdate: Boolean,
): TimelineMessageSemantics? {
    val stableId = daemonId?.takeIf(String::isNotEmpty) ?: return null
    val versionId = latestEditionId?.takeIf(String::isNotEmpty) ?: stableId
    val operation = if (liveUpdate) "edit" else null

    return when (mimeType) {
        "text/plain" -> {
            val text = body["body"] ?: return null
            TimelineMessageSemantics(versionId, operation, text.isEmpty())
        }

        "application/data-transfer+json" -> {
            val fileId = body["fileId"].orEmpty()
            when {
                fileId.isEmpty() ->
                    TimelineMessageSemantics(versionId, operation, deleted = true)
                liveUpdate ->
                    // libjami only supports removing an existing data-transfer
                    // interaction, not replacing it with a different file.
                    null
                else ->
                    TimelineMessageSemantics(versionId, operation = null, deleted = false)
            }
        }

        RichTimelineMetadata.STICKER_MIME -> if (
            !liveUpdate && latestEditionId.isNullOrEmpty() &&
            body["body"]?.let(RichTimelineMetadata::boundedBody) == true
        ) {
            TimelineMessageSemantics(stableId, operation = null, deleted = false)
        } else {
            null
        }

        DmTopicWire.EVENT_MIME -> if (
            !liveUpdate && latestEditionId.isNullOrEmpty() && body["body"] != null
        ) {
            TimelineMessageSemantics(stableId, operation = null, deleted = false)
        } else {
            null
        }

        else -> null
    }
}
