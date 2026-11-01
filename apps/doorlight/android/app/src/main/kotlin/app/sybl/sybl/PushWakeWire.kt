package app.sybl.sybl

import java.util.LinkedHashMap
import java.util.Locale

internal enum class PushWakeKind { CALL, MESSAGE, RELAY, IGNORE }

internal class PushWakeWire {
    private val callIds = boundedSet(256)
    private val messageIds = boundedSet(2_048)

    fun classify(data: Map<String, String>): PushWakeKind {
        if (data.size == 1 && data["w"] == "1") return PushWakeKind.RELAY
        if ("exp" in data) return PushWakeKind.IGNORE
        val rawTypes = data["pt"] ?: return PushWakeKind.IGNORE
        if (rawTypes.length > MAX_FIELD_LENGTH) return PushWakeKind.IGNORE
        val types = rawTypes.split(',')
        if (types.size > MAX_TYPES) return PushWakeKind.IGNORE
        val rawIds = data["ids"].orEmpty()
        if (rawIds.length > MAX_FIELD_LENGTH) return PushWakeKind.IGNORE
        val ids = if (rawIds.isEmpty()) emptyList() else rawIds.split(',')
        val scope = "${bounded(data["to"])}:${bounded(data["key"])}"
        var call = false
        var message = false
        types.forEachIndexed { index, rawType ->
            val type = rawType.trim().lowercase(Locale.ROOT)
            val kind = when {
                type == "audiocall" || type == "videocall" -> PushWakeKind.CALL
                type == "application/im-gitmessage-id" ||
                    type.startsWith("application/im-gitmessage-id/") ||
                    type == "application/invite" ||
                    type.startsWith("application/invite+") ||
                    type == "application/x-sybl-call-request" ||
                    type == "sync" -> PushWakeKind.MESSAGE
                else -> PushWakeKind.IGNORE
            }
            if (kind == PushWakeKind.IGNORE) return@forEachIndexed
            val id = ids.getOrNull(index)?.trim().orEmpty()
            val isNew = id.isEmpty() || synchronized(this) {
                val seen = if (kind == PushWakeKind.CALL) callIds else messageIds
                seen.put("$scope:$id", Unit) == null
            }
            if (isNew && kind == PushWakeKind.CALL) call = true
            if (isNew && kind == PushWakeKind.MESSAGE) message = true
        }
        return when {
            call -> PushWakeKind.CALL
            message -> PushWakeKind.MESSAGE
            else -> PushWakeKind.IGNORE
        }
    }

    private fun bounded(value: String?): String =
        value.orEmpty().take(MAX_SCOPE_LENGTH)

    private fun boundedSet(maxSize: Int) =
        object : LinkedHashMap<String, Unit>(64, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Unit>) =
                size > maxSize
        }

    private companion object {
        const val MAX_FIELD_LENGTH = 4_096
        const val MAX_SCOPE_LENGTH = 256
        const val MAX_TYPES = 64
    }
}
