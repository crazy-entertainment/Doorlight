package app.sybl.sybl

import java.security.MessageDigest

internal object AndroidRemoteControlProtocol {
    const val CAP_MOUSE = 1
    const val CAP_KEYBOARD = 2
    const val CAP_TEXT = 4
    const val CAP_CLIPBOARD = 8
    const val CAP_BACK = 16
    const val CAP_HOME = 32
    const val CAP_RECENTS = 64
    const val ANDROID_CAPABILITIES =
        CAP_MOUSE or CAP_TEXT or CAP_BACK or CAP_HOME or CAP_RECENTS

    const val MAX_PACKET_BYTES = 6_000
    const val MAX_JSON_DEPTH = 20
    const val MAX_EVENTS = 64
    const val MAX_TEXT_BYTES = 256
}

internal sealed interface AndroidRemoteControlPacket

internal data class AndroidRemoteControlRequest(
    val capabilities: Int,
    val sourceRevision: Long,
    val identityColor: String,
) : AndroidRemoteControlPacket

internal data class AndroidRemoteControlInput(
    val token: ByteArray,
    val epoch: Long,
    val sequence: Long,
    val sourceRevision: Long,
    val events: List<AndroidRemoteControlEvent>,
) : AndroidRemoteControlPacket

internal data object AndroidRemoteControlEnd : AndroidRemoteControlPacket

internal sealed interface AndroidRemoteControlEvent
internal data class AndroidRemoteControlMove(
    val x: Double,
    val y: Double,
) : AndroidRemoteControlEvent
internal data class AndroidRemoteControlButton(
    val name: String,
    val down: Boolean,
) : AndroidRemoteControlEvent
internal data class AndroidRemoteControlWheel(val delta: Int) : AndroidRemoteControlEvent
internal data class AndroidRemoteControlText(val value: String) : AndroidRemoteControlEvent
internal data class AndroidRemoteControlAction(val name: String) : AndroidRemoteControlEvent

/**
 * Immutable authority snapshot. Geometry is part of the grant rather than an
 * incidental property of the latest projection callback.
 */
internal data class AndroidRemoteControlSourceIdentity(
    val callId: String,
    val revision: Long,
    val frameWidth: Int,
    val frameHeight: Int,
    val displayWidth: Int,
    val displayHeight: Int,
    val safeLeft: Int,
    val safeTop: Int,
    val safeRight: Int,
    val safeBottom: Int,
    val rotation: Int,
)

internal data class AndroidRemoteControlBinding(
    val callId: String,
    val localAccount: String,
    val controllerAccount: String,
    val controllerDevice: String,
    val source: AndroidRemoteControlSourceIdentity,
)

/**
 * Pure policy used by the production controllee and JVM mutation tests.
 */
internal object AndroidRemoteControlPolicy {
    fun sourceAnnouncement(owner: String, revision: Long, kind: String): String? {
        if (revision <= 0 || (kind != "camera" && kind != "screen") ||
            owner.length != 40 || owner.any { it !in "0123456789abcdef" }
        ) {
            return null
        }
        return "{\"v\":1,\"t\":\"src\",\"sourceKind\":\"$kind\",\"platform\":\"android\"," +
            "\"sourceOwner\":\"$owner\",\"sourceRevision\":$revision}"
    }

    fun packageAllowed(
        packageName: String?,
        ownPackage: String,
        allowOwnPackage: Boolean = false,
    ): Boolean =
        !packageName.isNullOrEmpty() &&
            (allowOwnPackage || packageName != ownPackage)

    fun negotiatedCapabilities(requested: Int): Int =
        requested and AndroidRemoteControlProtocol.ANDROID_CAPABILITIES

    fun ownsFullDisplay(
        capturedWidth: Int,
        capturedHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
    ): Boolean =
        capturedWidth > 0 &&
            capturedHeight > 0 &&
            capturedWidth == displayWidth &&
            capturedHeight == displayHeight

    fun fullDisplayGestureBounds(width: Int, height: Int): IntArray =
        intArrayOf(0, 0, width, height)

    fun localTouchFeedbackAvailable(
        sdk: Int,
        hostActive: Boolean,
        identityColor: String,
    ): Boolean =
        sdk >= 33 && hostActive && IdentityColorWire.valid(identityColor)

    fun directSystemControlAllowed(
        systemWindow: Boolean,
        packageName: String?,
        ownPackage: String,
        visible: Boolean,
        clickable: Boolean,
    ): Boolean =
        systemWindow && visible && clickable &&
            packageAllowed(packageName, ownPackage)

    fun threeButtonNavigationAction(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        bottomInset: Int,
        threeButtonMode: Boolean,
    ): String? {
        if (!threeButtonMode || width <= 0 || height <= 0 ||
            bottomInset <= 0 || bottomInset > height ||
            x !in 0 until width || y !in (height - bottomInset) until height
        ) {
            return null
        }
        // ponytail: tested devices use Android's standard Back/Home/Recents
        // order; add an OEM order adapter when a target device reverses it.
        return when ((x.toLong() * 3 / width).toInt()) {
            0 -> "back"
            1 -> "home"
            else -> "recents"
        }
    }

    fun navigationBottomInset(
        systemInset: Int,
        displayHeight: Int,
        applicationBottom: Int,
    ): Int = maxOf(systemInset, displayHeight - applicationBottom)
        .coerceIn(0, displayHeight)

    fun needsSourceActivation(
        currentAttemptGeneration: Long,
        currentRevision: Long,
        attemptGeneration: Long,
    ): Boolean =
        currentRevision <= 0 || currentAttemptGeneration != attemptGeneration

    fun ownsPointer(
        pointerGeneration: Long,
        pointerSource: AndroidRemoteControlSourceIdentity?,
        generation: Long,
        source: AndroidRemoteControlSourceIdentity,
    ): Boolean =
        pointerGeneration > 0 &&
            pointerGeneration == generation &&
            pointerSource == source

    fun mapSharedFramePoint(
        x: Double,
        y: Double,
        frameWidth: Int,
        frameHeight: Int,
        displayWidth: Int,
        displayHeight: Int,
    ): Pair<Double, Double>? {
        if (!x.isFinite() || !y.isFinite() ||
            x !in 0.0..1.0 || y !in 0.0..1.0 ||
            frameWidth <= 0 || frameHeight <= 0 ||
            displayWidth <= 0 || displayHeight <= 0) {
            return null
        }
        val scale = minOf(
            frameWidth.toDouble() / displayWidth,
            frameHeight.toDouble() / displayHeight,
        )
        val contentWidth = displayWidth * scale
        val contentHeight = displayHeight * scale
        val left = (frameWidth - contentWidth) / 2.0
        val top = (frameHeight - contentHeight) / 2.0
        val frameX = x * frameWidth
        val frameY = y * frameHeight
        if (frameX < left || frameX > left + contentWidth ||
            frameY < top || frameY > top + contentHeight) {
            return null
        }
        return (frameX - left) / scale to (frameY - top) / scale
    }

    fun eventsMatchCapabilities(
        events: List<AndroidRemoteControlEvent>,
        capabilities: Int,
    ): Boolean = events.all { event ->
        when (event) {
            is AndroidRemoteControlMove,
            is AndroidRemoteControlButton,
            is AndroidRemoteControlWheel,
            -> capabilities and AndroidRemoteControlProtocol.CAP_MOUSE != 0
            is AndroidRemoteControlText ->
                capabilities and AndroidRemoteControlProtocol.CAP_TEXT != 0
            is AndroidRemoteControlAction -> when (event.name) {
                "back" -> capabilities and AndroidRemoteControlProtocol.CAP_BACK != 0
                "home" -> capabilities and AndroidRemoteControlProtocol.CAP_HOME != 0
                "recents" -> capabilities and AndroidRemoteControlProtocol.CAP_RECENTS != 0
                else -> false
            }
        }
    }

    fun authenticatedSequenceGap(
        expectedBinding: AndroidRemoteControlBinding,
        presentedBinding: AndroidRemoteControlBinding,
        expectedToken: ByteArray,
        presentedToken: ByteArray,
        expectedEpoch: Long,
        presentedEpoch: Long,
        lastSequence: Long,
        presentedSequence: Long,
    ): Boolean = expectedBinding == presentedBinding &&
        expectedEpoch == presentedEpoch &&
        MessageDigest.isEqual(expectedToken, presentedToken) &&
        lastSequence < Long.MAX_VALUE && presentedSequence > lastSequence + 1

    fun authorizesInput(
        expectedBinding: AndroidRemoteControlBinding?,
        presentedBinding: AndroidRemoteControlBinding,
        expectedToken: ByteArray,
        presentedToken: ByteArray,
        expectedEpoch: Long,
        presentedEpoch: Long,
        lastSequence: Long,
        presentedSequence: Long,
        capabilities: Int,
        events: List<AndroidRemoteControlEvent>,
    ): Boolean =
        expectedBinding != null &&
            expectedBinding == presentedBinding &&
            expectedEpoch == presentedEpoch &&
            presentedSequence == lastSequence + 1 &&
            MessageDigest.isEqual(expectedToken, presentedToken) &&
            eventsMatchCapabilities(events, capabilities)
}

/**
 * Strict, dependency-free parser for controller-to-controllee packets.
 *
 * Keeping this parser free of Android framework classes makes the exact
 * production wire grammar executable in local JVM tests. It rejects duplicate
 * and unknown fields, non-canonical token text, trailing JSON, oversized
 * packets/events/text, unsupported event kinds, and non-positive authority
 * counters.
 */
internal object AndroidRemoteControlPacketParser {
    fun parse(packet: String): AndroidRemoteControlPacket? {
        val bytes = packet.toByteArray(Charsets.UTF_8)
        if (bytes.isEmpty() || bytes.size > AndroidRemoteControlProtocol.MAX_PACKET_BYTES) {
            return null
        }
        return try {
            val root = StrictJson(packet).parseObjectDocument()
            val version = root.requiredNumber("v").asInt()
            if (version != 1) fail("version")
            when (root.requiredString("t")) {
                "req" -> parseRequest(root)
                "input" -> parseInput(root)
                "end" -> {
                    root.requireExactKeys(setOf("v", "t"))
                    AndroidRemoteControlEnd
                }
                else -> fail("direction/type")
            }
        } catch (_: Throwable) {
            null
        }
    }

    private fun parseRequest(root: Map<String, JsonValue>): AndroidRemoteControlRequest {
        root.requireExactKeys(setOf("v", "t", "caps", "sourceRevision", "color"))
        val identityColor = root.requiredString("color")
        if (!IdentityColorWire.valid(identityColor)) fail("identity color")
        return AndroidRemoteControlRequest(
            readCapabilities(root.requiredArray("caps")),
            root.requiredNumber("sourceRevision").asPositiveLong(),
            identityColor,
        )
    }

    private fun parseInput(root: Map<String, JsonValue>): AndroidRemoteControlInput {
        root.requireExactKeys(
            setOf("v", "t", "token", "epoch", "seq", "sourceRevision", "ev"),
        )
        return AndroidRemoteControlInput(
            readToken(root.requiredString("token")),
            root.requiredNumber("epoch").asPositiveLong(),
            root.requiredNumber("seq").asPositiveLong(),
            root.requiredNumber("sourceRevision").asPositiveLong(),
            readEvents(root.requiredArray("ev")),
        )
    }

    private fun readCapabilities(values: List<JsonValue>): Int {
        if (values.isEmpty() || values.size > 7) fail("capability count")
        var bits = 0
        for (value in values) {
            val bit = when (value.asString()) {
                "mouse" -> AndroidRemoteControlProtocol.CAP_MOUSE
                "keyboard" -> AndroidRemoteControlProtocol.CAP_KEYBOARD
                "text" -> AndroidRemoteControlProtocol.CAP_TEXT
                "clipboard" -> AndroidRemoteControlProtocol.CAP_CLIPBOARD
                "back" -> AndroidRemoteControlProtocol.CAP_BACK
                "home" -> AndroidRemoteControlProtocol.CAP_HOME
                "recents" -> AndroidRemoteControlProtocol.CAP_RECENTS
                else -> fail("capability")
            }
            if (bits and bit != 0) fail("duplicate capability")
            bits = bits or bit
        }
        return bits
    }

    private fun readToken(value: String): ByteArray {
        if (value.length !in 32..128 || value.length % 2 != 0) fail("token")
        val out = ByteArray(value.length / 2)
        for (index in out.indices) {
            val highChar = value[index * 2]
            val lowChar = value[index * 2 + 1]
            if (highChar !in '0'..'9' && highChar !in 'a'..'f' ||
                lowChar !in '0'..'9' && lowChar !in 'a'..'f'
            ) {
                fail("token")
            }
            val high = highChar.digitToInt(16)
            val low = lowChar.digitToInt(16)
            out[index] = ((high shl 4) or low).toByte()
        }
        return out
    }

    private fun readEvents(values: List<JsonValue>): List<AndroidRemoteControlEvent> {
        if (values.isEmpty() || values.size > AndroidRemoteControlProtocol.MAX_EVENTS) {
            fail("event count")
        }
        return values.map(::readEvent)
    }

    private fun readEvent(value: JsonValue): AndroidRemoteControlEvent {
        val fields = value.asArray()
        if (fields.isEmpty()) fail("event fields")
        return when (fields[0].asString()) {
            "m" -> {
                if (fields.size != 3) fail("event fields")
                val x = fields[1].asNumber().asDouble()
                val y = fields[2].asNumber().asDouble()
                if (!x.isFinite() || !y.isFinite() || x !in 0.0..1.0 || y !in 0.0..1.0) {
                    fail("move")
                }
                AndroidRemoteControlMove(x, y)
            }
            "d", "u" -> {
                if (fields.size != 2) fail("event fields")
                val name = fields[1].asString()
                if (name !in setOf("left", "right")) fail("button")
                AndroidRemoteControlButton(name, fields[0].asString() == "d")
            }
            "w" -> {
                if (fields.size != 2) fail("event fields")
                val delta = fields[1].asNumber().asInt()
                if (delta == 0 || delta !in -12_000..12_000) fail("wheel")
                AndroidRemoteControlWheel(delta)
            }
            "t" -> {
                if (fields.size != 2) fail("event fields")
                val text = fields[1].asString()
                val bytes = text.toByteArray(Charsets.UTF_8)
                if (text.isEmpty() ||
                    bytes.size > AndroidRemoteControlProtocol.MAX_TEXT_BYTES ||
                    text.any { it == '\u0000' || it.code < 0x20 && it !in "\t\n\r" }
                ) {
                    fail("text")
                }
                AndroidRemoteControlText(text)
            }
            "a" -> {
                if (fields.size != 2) fail("event fields")
                val action = fields[1].asString()
                if (action !in setOf("back", "home", "recents")) fail("action")
                AndroidRemoteControlAction(action)
            }
            // Android never grants arbitrary virtual-key injection.
            "k" -> fail("keyboard unsupported")
            else -> fail("event type")
        }
    }
}

internal sealed interface JsonValue {
    fun asString(): String = (this as? JsonString)?.value ?: fail("string")
    fun asNumber(): JsonNumber = this as? JsonNumber ?: fail("number")
    fun asArray(): List<JsonValue> = (this as? JsonArray)?.values ?: fail("array")
}

private data class JsonString(val value: String) : JsonValue
internal data class JsonNumber(val text: String) : JsonValue {
    fun asInt(): Int {
        if (text.any { it == '.' || it == 'e' || it == 'E' }) fail("integer")
        return text.toIntOrNull() ?: fail("integer")
    }

    fun asPositiveLong(): Long {
        if (text.any { it == '.' || it == 'e' || it == 'E' }) fail("positive")
        val value = text.toLongOrNull() ?: fail("positive")
        if (value <= 0) fail("positive")
        return value
    }

    fun asDouble(): Double = text.toDoubleOrNull() ?: fail("number")
}
private data class JsonBoolean(val value: Boolean) : JsonValue
private data class JsonArray(val values: List<JsonValue>) : JsonValue
private data class JsonObject(val values: Map<String, JsonValue>) : JsonValue

private fun Map<String, JsonValue>.requireExactKeys(expected: Set<String>) {
    if (keys != expected) fail("fields")
}

private fun Map<String, JsonValue>.requiredString(name: String): String =
    this[name]?.asString() ?: fail("missing $name")

private fun Map<String, JsonValue>.requiredNumber(name: String): JsonNumber =
    this[name]?.asNumber() ?: fail("missing $name")

private fun Map<String, JsonValue>.requiredArray(name: String): List<JsonValue> =
    this[name]?.asArray() ?: fail("missing $name")

private fun fail(reason: String): Nothing = throw IllegalArgumentException(reason)

internal class StrictJson(private val source: String) {
    private var index = 0

    fun parseObjectDocument(): Map<String, JsonValue> {
        skipWhitespace()
        val root = parseValue() as? JsonObject ?: fail("root")
        skipWhitespace()
        if (index != source.length) fail("trailing JSON")
        return root.values
    }

    private fun parseValue(depth: Int = 1): JsonValue {
        // JsonCpp counts the root and each nested value as one level.
        if (depth > AndroidRemoteControlProtocol.MAX_JSON_DEPTH) fail("JSON depth")
        skipWhitespace()
        if (index >= source.length) fail("value")
        return when (source[index]) {
            '{' -> parseObject(depth)
            '[' -> parseArray(depth)
            '"' -> JsonString(parseString())
            't' -> {
                requireLiteral("true")
                JsonBoolean(true)
            }
            'f' -> {
                requireLiteral("false")
                JsonBoolean(false)
            }
            '-', in '0'..'9' -> JsonNumber(parseNumber())
            else -> fail("value")
        }
    }

    private fun parseObject(depth: Int): JsonObject {
        requireChar('{')
        skipWhitespace()
        val result = LinkedHashMap<String, JsonValue>()
        if (consumeChar('}')) return JsonObject(result)
        while (true) {
            skipWhitespace()
            if (index >= source.length || source[index] != '"') fail("object key")
            val key = parseString()
            if (result.containsKey(key)) fail("duplicate key")
            skipWhitespace()
            requireChar(':')
            result[key] = parseValue(depth + 1)
            skipWhitespace()
            if (consumeChar('}')) return JsonObject(result)
            requireChar(',')
        }
    }

    private fun parseArray(depth: Int): JsonArray {
        requireChar('[')
        skipWhitespace()
        val result = ArrayList<JsonValue>()
        if (consumeChar(']')) return JsonArray(result)
        while (true) {
            result += parseValue(depth + 1)
            skipWhitespace()
            if (consumeChar(']')) return JsonArray(result)
            requireChar(',')
        }
    }

    private fun parseString(): String {
        requireChar('"')
        val result = StringBuilder()
        while (index < source.length) {
            val current = source[index++]
            when {
                current == '"' -> return result.toString()
                current == '\\' -> appendEscape(result)
                current.code < 0x20 -> fail("string control")
                Character.isHighSurrogate(current) -> {
                    if (index >= source.length || !Character.isLowSurrogate(source[index])) {
                        fail("surrogate")
                    }
                    result.append(current)
                    result.append(source[index++])
                }
                Character.isLowSurrogate(current) -> fail("surrogate")
                else -> result.append(current)
            }
        }
        fail("unterminated string")
    }

    private fun appendEscape(result: StringBuilder) {
        if (index >= source.length) fail("escape")
        when (val escaped = source[index++]) {
            '"', '\\', '/' -> result.append(escaped)
            'b' -> result.append('\b')
            'f' -> result.append('\u000c')
            'n' -> result.append('\n')
            'r' -> result.append('\r')
            't' -> result.append('\t')
            'u' -> {
                val first = readHexQuad()
                when {
                    Character.isHighSurrogate(first) -> {
                        if (index + 1 >= source.length ||
                            source[index] != '\\' ||
                            source[index + 1] != 'u'
                        ) {
                            fail("surrogate")
                        }
                        index += 2
                        val second = readHexQuad()
                        if (!Character.isLowSurrogate(second)) fail("surrogate")
                        result.append(first)
                        result.append(second)
                    }
                    Character.isLowSurrogate(first) -> fail("surrogate")
                    else -> result.append(first)
                }
            }
            else -> fail("escape")
        }
    }

    private fun readHexQuad(): Char {
        if (index + 4 > source.length) fail("unicode escape")
        var value = 0
        repeat(4) {
            val digit = source[index++].digitToIntOrNull(16) ?: fail("unicode escape")
            value = (value shl 4) or digit
        }
        return value.toChar()
    }

    private fun parseNumber(): String {
        val start = index
        consumeChar('-')
        if (index >= source.length) fail("number")
        if (source[index] == '0') {
            index++
            if (index < source.length && source[index] in '0'..'9') fail("number")
        } else {
            if (source[index] !in '1'..'9') fail("number")
            while (index < source.length && source[index] in '0'..'9') index++
        }
        if (consumeChar('.')) {
            val fractionStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == fractionStart) fail("number")
        }
        if (index < source.length && source[index] in "eE") {
            index++
            if (index < source.length && source[index] in "+-") index++
            val exponentStart = index
            while (index < source.length && source[index] in '0'..'9') index++
            if (index == exponentStart) fail("number")
        }
        return source.substring(start, index)
    }

    private fun requireLiteral(literal: String) {
        if (!source.regionMatches(index, literal, 0, literal.length)) fail("literal")
        index += literal.length
    }

    private fun requireChar(expected: Char) {
        skipWhitespace()
        if (index >= source.length || source[index] != expected) fail("expected $expected")
        index++
    }

    private fun consumeChar(expected: Char): Boolean {
        if (index < source.length && source[index] == expected) {
            index++
            return true
        }
        return false
    }

    private fun skipWhitespace() {
        while (index < source.length && source[index] in " \t\r\n") index++
    }
}
