package app.sybl.sybl

import org.json.JSONObject

internal data class CallRequestPacket(val timestampMs: Long)

internal object CallRequestWire {
    private const val VERSION = 1
    private const val MAX_BODY_BYTES = 256
    private const val MAX_AGE_MS = 120_000L
    private const val MAX_FUTURE_SKEW_MS = 30_000L

    fun encode(timestampMs: Long): String =
        JSONObject().put("v", VERSION).put("ts", timestampMs).toString()

    fun decode(body: String, nowMs: Long): CallRequestPacket? {
        if (body.toByteArray(Charsets.UTF_8).size > MAX_BODY_BYTES) return null
        return try {
            val value = JSONObject(body)
            if (value.length() != 2 || value.optInt("v", 0) != VERSION) return null
            val timestamp = value.optLong("ts", Long.MIN_VALUE)
            if (timestamp == Long.MIN_VALUE ||
                timestamp < nowMs - MAX_AGE_MS ||
                timestamp > nowMs + MAX_FUTURE_SKEW_MS) return null
            CallRequestPacket(timestamp)
        } catch (_: Throwable) {
            null
        }
    }
}
