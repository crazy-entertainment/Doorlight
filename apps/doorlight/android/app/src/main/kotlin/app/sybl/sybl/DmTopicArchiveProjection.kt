package app.sybl.sybl

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject

internal data class DmTopicArchiveRegister(
    val revision: Int,
    val commitId: String,
    val archived: Boolean,
)

internal class DmTopicArchiveProjection {
    companion object {
        private const val MAX_CONVERSATIONS = 256
        private const val MAX_TOPICS_PER_CONVERSATION = 64
        private val customId = Regex("^[a-f0-9]{32}$")
    }

    private val records = linkedMapOf<String, LinkedHashMap<String, DmTopicArchiveRegister>>()
    // Rebuilt exclusively from authenticated daemon events/history, never from
    // arbitrary notification extras or the archive cache on disk.
    private val known = linkedMapOf<String, MutableSet<String>>()

    fun apply(
        conversationId: String,
        commitId: String,
        authorId: String,
        localAuthorId: String,
        body: String,
    ): Boolean {
        if (conversationId.isEmpty() || conversationId.length > 1024 ||
            commitId.isEmpty() || commitId.length > 128 ||
            authorId.isEmpty() || body.toByteArray().size > DmTopicWire.MAX_EVENT_BYTES) {
            return false
        }
        val json = try {
            JSONObject(body)
        } catch (_: Throwable) {
            return false
        }
        if (json.opt("v") != 1) return false
        if (json.optString("op") == "create") {
            val topic = json.opt("topic") as? String ?: return false
            val revision = json.opt("revision") as? Int ?: return false
            val order = json.opt("order") as? Int ?: return false
            val name = json.opt("name") as? String ?: return false
            if (json.length() != 6 || !customId.matches(topic) || revision < 1 ||
                order < 0 || name.isEmpty() || name != name.trim() ||
                name.toByteArray(Charsets.UTF_8).size > 64 ||
                name.any { it.code < 0x20 || it.code == 0x7f }) return false
            val topics = known[conversationId] ?: run {
                if (known.size >= MAX_CONVERSATIONS) return false
                linkedSetOf<String>().also { known[conversationId] = it }
            }
            if (topic !in topics && topics.size >= MAX_TOPICS_PER_CONVERSATION) return false
            return topics.add(topic)
        }
        if (authorId != localAuthorId || json.length() != 5 || json.optInt("v", -1) != 1 ||
            json.optString("op") != "archive") return false
        val topicId = json.optString("topic")
        val revision = json.opt("revision") as? Int ?: return false
        val archived = json.opt("archived") as? Boolean ?: return false
        if (!customId.matches(topicId) || revision < 1) return false
        val topics = records[conversationId] ?: run {
            if (records.size >= MAX_CONVERSATIONS) return false
            linkedMapOf<String, DmTopicArchiveRegister>().also {
                records[conversationId] = it
            }
        }
        val current = topics[topicId]
        val next = DmTopicArchiveRegister(revision, commitId, archived)
        if (current != null &&
            (revision < current.revision ||
                (revision == current.revision && commitId <= current.commitId))) return false
        if (current == null && topics.size >= MAX_TOPICS_PER_CONVERSATION) return false
        topics[topicId] = next
        return true
    }

    fun isArchived(conversationId: String, topicId: String): Boolean =
        records[conversationId]?.get(topicId)?.archived == true

    fun admits(conversationId: String, topicId: String): Boolean =
        (topicId == DmTopicWire.MAIN || known[conversationId]?.contains(topicId) == true) &&
            !isArchived(conversationId, topicId)

    fun archivedTopics(conversationId: String): Set<String> =
        records[conversationId].orEmpty()
            .filterValues { it.archived }
            .keys

    fun retainConversations(conversationIds: Set<String>): Boolean {
        val before = records.size
        records.keys.retainAll(conversationIds)
        known.keys.retainAll(conversationIds)
        return records.size != before
    }

    fun clear() { records.clear(); known.clear() }

    fun snapshot(): Map<String, Map<String, DmTopicArchiveRegister>> =
        records.mapValues { (_, topics) -> topics.toMap() }

    fun restore(snapshot: Map<String, Map<String, DmTopicArchiveRegister>>) {
        records.clear()
        for ((conversationId, topics) in snapshot.entries.take(MAX_CONVERSATIONS)) {
            if (conversationId.isEmpty() || conversationId.length > 1024) continue
            val valid = linkedMapOf<String, DmTopicArchiveRegister>()
            for ((topicId, register) in topics.entries.take(MAX_TOPICS_PER_CONVERSATION)) {
                if (customId.matches(topicId) && register.revision >= 1 &&
                    register.commitId.isNotEmpty() && register.commitId.length <= 128) {
                    valid[topicId] = register
                }
            }
            if (valid.isNotEmpty()) records[conversationId] = valid
        }
    }
}

internal class DmTopicArchiveStore(context: Context) {
    companion object {
        private const val PREFS = "sybl_dm_topic_archives_v1"
        private const val ACCOUNT = "account"
        private const val RECORDS = "records"
        private const val MAX_RECORDS = 4096
        private const val MAX_ENCODED_CHARS = 512 * 1024
    }

    private val preferences: SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    private val projection = DmTopicArchiveProjection()
    private var accountId = ""

    @Synchronized
    fun selectAccount(nextAccountId: String) {
        if (nextAccountId == accountId) return
        accountId = nextAccountId
        projection.clear()
        if (preferences.getString(ACCOUNT, "") != nextAccountId) {
            preferences.edit().clear().putString(ACCOUNT, nextAccountId).commit()
            return
        }
        restore(preferences.getString(RECORDS, null))
    }

    @Synchronized
    fun apply(
        conversationId: String,
        commitId: String,
        authorId: String,
        localAuthorId: String,
        body: String,
    ): Boolean {
        val changed = projection.apply(
            conversationId,
            commitId,
            authorId,
            localAuthorId,
            body,
        )
        if (changed) save()
        return changed
    }

    @Synchronized
    fun isArchived(conversationId: String, topicId: String): Boolean =
        projection.isArchived(conversationId, topicId)

    @Synchronized
    fun admits(conversationId: String, topicId: String): Boolean =
        projection.admits(conversationId, topicId)

    @Synchronized
    fun archivedTopics(conversationId: String): Set<String> =
        projection.archivedTopics(conversationId)

    @Synchronized
    fun retainConversations(conversationIds: Set<String>) {
        if (projection.retainConversations(conversationIds)) save()
    }

    private fun save() {
        val records = JSONArray()
        recordLoop@ for ((conversationId, topics) in projection.snapshot()) {
            for ((topicId, register) in topics) {
                if (records.length() >= MAX_RECORDS) break@recordLoop
                records.put(
                    JSONObject()
                        .put("conversation", conversationId)
                        .put("topic", topicId)
                        .put("revision", register.revision)
                        .put("commit", register.commitId)
                        .put("archived", register.archived),
                )
            }
        }
        val encoded = records.toString()
        if (encoded.length <= MAX_ENCODED_CHARS) {
            preferences.edit().putString(ACCOUNT, accountId).putString(RECORDS, encoded).commit()
        }
    }

    private fun restore(encoded: String?) {
        if (encoded == null || encoded.length > MAX_ENCODED_CHARS) return
        val values = try {
            JSONArray(encoded)
        } catch (_: Throwable) {
            return
        }
        val restored = linkedMapOf<String, MutableMap<String, DmTopicArchiveRegister>>()
        for (index in 0 until minOf(values.length(), MAX_RECORDS)) {
            val value = values.optJSONObject(index) ?: continue
            val conversationId = value.optString("conversation")
            val topicId = value.optString("topic")
            val revision = value.optInt("revision", -1)
            val commitId = value.optString("commit")
            val archived = value.opt("archived") as? Boolean ?: continue
            restored.getOrPut(conversationId, ::linkedMapOf)[topicId] =
                DmTopicArchiveRegister(revision, commitId, archived)
        }
        projection.restore(restored)
    }
}
