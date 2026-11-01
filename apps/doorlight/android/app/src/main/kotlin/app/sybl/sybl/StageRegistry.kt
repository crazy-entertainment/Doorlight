package app.sybl.sybl

import org.json.JSONArray
import org.json.JSONObject

internal data class StageRecord(
    val path: String,
    val account: String = "",
    val peer: String = "",
    val conversation: String = "",
    val operation: String = "",
    val recording: Boolean = false,
) { val issued get() = operation.isNotEmpty() }

/** Durable ownership only, never message content. An uncertain write blocks all
 * subsequent changes until restart reloads the authoritative encrypted state. */
internal class StageRegistry(source: String?, private val persist: (String) -> Boolean) {
    private var entries = linkedMapOf<String, StageRecord>()
    var healthy = true
        private set

    init {
        try {
            if (source != null) {
                require(source.toByteArray(Charsets.UTF_8).size <= MAX_BYTES)
                val root = JSONObject(source)
                require(root.length() == 2 && root.get("v") == 1)
                val stages = root.getJSONArray("stages")
                require(stages.length() <= MAX_STAGES)
                val operations = mutableSetOf<String>()
                for (index in 0 until stages.length()) {
                    val value = stages.getJSONObject(index)
                    require(value.length() == 6 && value.get("recording") is Boolean)
                    for (key in listOf("path", "account", "peer", "conversation", "operation"))
                        require(value.get(key) is String)
                    val record = StageRecord(value.getString("path"), value.getString("account"),
                        value.getString("peer"), value.getString("conversation"), value.getString("operation"),
                        value.getBoolean("recording"))
                    require(valid(record) && record.path !in entries && (!record.issued || operations.add(record.operation)))
                    entries[record.path] = record
                }
            }
        } catch (_: Throwable) { healthy = false; entries.clear() }
    }

    @Synchronized fun records(): List<StageRecord> = entries.values.toList()
    @Synchronized fun find(operation: String): StageRecord? =
        if (healthy && operation.isNotEmpty()) entries.values.firstOrNull { it.operation == operation } else null
    @Synchronized fun ownsIssued(path: String): Boolean = !healthy || entries[path]?.issued == true

    @Synchronized fun reserveRecording(path: String): Boolean {
        val record = StageRecord(path, recording = true)
        if (!valid(record) || path in entries) return false
        return save(LinkedHashMap(entries).apply { put(path, record) })
    }

    @Synchronized fun issue(record: StageRecord): Boolean {
        if (!valid(record) || !record.issued || find(record.operation) != null || entries[record.path]?.issued == true) return false
        val issued = record.copy(recording = entries[record.path]?.recording ?: record.recording)
        return save(LinkedHashMap(entries).apply { put(record.path, issued) })
    }

    @Synchronized fun forget(path: String): Boolean {
        if (path !in entries) return healthy
        return save(LinkedHashMap(entries).apply { remove(path) })
    }

    private fun save(next: LinkedHashMap<String, StageRecord>): Boolean {
        if (!healthy || next.size > MAX_STAGES) return false
        val stages = JSONArray()
        next.values.forEach { record -> stages.put(JSONObject().put("path", record.path)
            .put("account", record.account).put("peer", record.peer).put("conversation", record.conversation)
            .put("operation", record.operation).put("recording", record.recording)) }
        val encoded = JSONObject().put("v", 1).put("stages", stages).toString()
        if (encoded.toByteArray(Charsets.UTF_8).size > MAX_BYTES) return false
        val saved = try { persist(encoded) } catch (_: Throwable) { false }
        if (!saved) { healthy = false; return false }
        entries = next
        return true
    }

    private fun valid(record: StageRecord): Boolean {
        if (record.path.isEmpty() || record.path.length > 32768 || '\u0000' in record.path) return false
        if (!record.issued) return record.recording && record.account.isEmpty() && record.peer.isEmpty() && record.conversation.isEmpty()
        return Regex("^[0-9a-f]{32}$").matches(record.operation) &&
            listOf(record.account, record.peer, record.conversation).all { it.isNotEmpty() && it.length <= 1024 && '\u0000' !in it }
    }

    private companion object { const val MAX_BYTES = 1024 * 1024; const val MAX_STAGES = 256 }
}
