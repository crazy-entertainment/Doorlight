package app.sybl.sybl

import org.json.JSONObject
import org.json.JSONTokener

internal data class PresencePacket(
    val version: Int,
    val type: String,
    val foreground: Int,
    val timestampMs: Long,
    val platform: String,
    val activity: String,
    val color: String,
    val wake: String,
)

/**
 * Small, bounded ping/pong contract shared with the Windows bridge.
 *
 * Activity is an optional friendly application name supplied by an opted-in
 * Windows peer. Android never discovers or transmits another app's identity.
 */
internal object PresenceWire {
    const val VERSION = 3
    const val MAX_BODY_BYTES = 512
    const val MAX_ACTIVITY_BYTES = 96
    const val MAX_CLOCK_DELTA_MS = 60_000L
    private val keys = setOf("v", "t", "fg", "ts", "platform", "activity", "color", "wake")
    private val wakeHandle = Regex("^[A-Za-z0-9_-]{43}$")
    private val integer = Regex("-?(?:0|[1-9][0-9]*)")

    fun encode(
        type: String,
        foreground: Boolean,
        timestampMs: Long,
        platform: String = "android",
        activity: String = "",
        color: String,
        wake: String = "",
    ): String {
        require(type == "ping" || type == "pong" || type == "wake")
        require(timestampMs > 0)
        val safePlatform = platform.takeIf { it == "android" || it == "windows" } ?: ""
        val safeActivity = decodeActivity(activity) ?: ""
        require(IdentityColorWire.valid(color))
        require((wake.isEmpty() && type != "wake") || wakeHandle.matches(wake))
        return JSONObject()
            .put("v", VERSION)
            .put("t", type)
            .put("fg", if (foreground) 1 else 0)
            .put("ts", timestampMs)
            .put("platform", safePlatform)
            .put("activity", safeActivity)
            .put("color", color)
            .put("wake", wake)
            .toString()
    }

    fun decode(body: String, nowMs: Long = System.currentTimeMillis()): PresencePacket? {
        if (body == "1") return PresencePacket(0, "ping", -1, 0, "", "", "", "")
        if (body.length > MAX_BODY_BYTES) return null
        if (body.toByteArray(Charsets.UTF_8).size > MAX_BODY_BYTES) return null
        val value = decodeObject(body) ?: return null
        val version = when (val raw = value["v"]) {
            null -> 0
            is Long -> raw.toInt().takeIf { it.toLong() == raw } ?: return null
            else -> return null
        }
        if (version !in 0..VERSION) return null
        val expected = when (version) {
            VERSION -> setOf("v", "t", "fg", "ts", "platform", "activity", "color", "wake")
            2 -> setOf("v", "t", "fg", "ts", "platform", "activity", "color")
            1 -> setOf("v", "t", "fg", "ts", "platform", "activity")
            else -> setOf("t", "fg", "ts", "platform", "activity")
        }
        if (value.keys != expected) return null
        val type = value["t"] as? String ?: return null
        if (type != "ping" && type != "pong" && (version != VERSION || type != "wake")) return null
        val foreground = (value["fg"] as? Long)
            ?.toInt()
            ?.takeIf { it.toLong() == value["fg"] && (it == 0 || it == 1) }
            ?: return null
        val timestamp = (value["ts"] as? Long)?.takeIf { it > 0 } ?: return null
        if (nowMs <= 0 ||
            (timestamp < nowMs && nowMs - timestamp > MAX_CLOCK_DELTA_MS) ||
            (timestamp > nowMs && timestamp - nowMs > MAX_CLOCK_DELTA_MS)
        ) return null
        val platform = (value["platform"] as? String).orEmpty().takeIf {
            it == "android" || it == "windows"
        } ?: return null
        val activityValue = value["activity"] as? String ?: return null
        val activity = decodeActivity(activityValue) ?: return null
        val color = if (version >= 2) {
            (value["color"] as? String)?.takeIf(IdentityColorWire::valid) ?: return null
        } else {
            ""
        }
        val wake = if (version == VERSION) {
            (value["wake"] as? String)?.takeIf {
                (it.isEmpty() && type != "wake") || wakeHandle.matches(it)
            } ?: return null
        } else {
            ""
        }
        return PresencePacket(version, type, foreground, timestamp, platform, activity, color, wake)
    }

    /** Strict, duplicate-aware parser for this one flat JSON object. `JSONObject(String)` is intentionally
     * lenient (single quotes, unquoted names, trailing separators), which is wrong at a peer trust boundary. */
    private fun decodeObject(body: String): Map<String, Any>? = try {
        val input = JSONTokener(body)
        if (input.nextClean() != '{') return null
        val values = HashMap<String, Any>(keys.size)
        if (input.nextClean() == '}') return values
        input.back()
        while (true) {
            if (input.nextClean() != '"') return null
            val key = readString(input) ?: return null
            if (key !in keys || values.containsKey(key) || input.nextClean() != ':') return null
            values[key] = when (key) {
                "t", "platform", "activity", "color", "wake" -> {
                    if (input.nextClean() != '"') return null
                    readString(input) ?: return null
                }
                else -> readInteger(input) ?: return null
            }
            when (input.nextClean()) {
                '}' -> break
                ',' -> {
                    val next = input.nextClean()
                    if (next == '}' || next == '\u0000') return null
                    input.back()
                }
                else -> return null
            }
        }
        values.takeIf { input.nextClean() == '\u0000' }
    } catch (_: Throwable) {
        null
    }

    private fun readInteger(input: JSONTokener): Long? {
        val token = StringBuilder()
        var next = input.nextClean()
        while (next != '\u0000' && next != ',' && next != '}' && !next.isWhitespace()) {
            token.append(next)
            next = input.next()
        }
        if (next != '\u0000') input.back()
        val value = token.toString()
        return value.takeIf(integer::matches)?.toLongOrNull()
    }

    /** Reads a double-quoted RFC 8259 string after the opening quote. */
    private fun readString(input: JSONTokener): String? {
        val value = StringBuilder()
        while (true) {
            when (val next = input.next()) {
                '\u0000' -> return null
                '"' -> return value.toString()
                '\\' -> when (val escaped = input.next()) {
                    '"', '\\', '/' -> value.append(escaped)
                    'b' -> value.append('\b')
                    'f' -> value.append('\u000c')
                    'n' -> value.append('\n')
                    'r' -> value.append('\r')
                    't' -> value.append('\t')
                    'u' -> {
                        val hex = buildString(4) { repeat(4) { append(input.next()) } }
                        val code = hex.toIntOrNull(16) ?: return null
                        value.append(code.toChar())
                    }
                    else -> return null
                }
                else -> {
                    if (next.code < 0x20) return null
                    value.append(next)
                }
            }
        }
    }

    private fun decodeActivity(value: String): String? {
        if (value.any { it.code < 0x20 || it.code == 0x7f || it == '"' || it == '\\' }) {
            return null
        }
        var index = 0
        while (index < value.length) {
            val unit = value[index]
            when {
                unit.isHighSurrogate() -> {
                    if (++index >= value.length || !value[index].isLowSurrogate()) return null
                }
                unit.isLowSurrogate() -> return null
            }
            index++
        }
        val trimmed = value.trim()
        if (trimmed.toByteArray(Charsets.UTF_8).size > MAX_ACTIVITY_BYTES) return null
        return trimmed
    }
}
