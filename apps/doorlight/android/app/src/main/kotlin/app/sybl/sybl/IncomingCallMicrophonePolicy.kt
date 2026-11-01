package app.sybl.sybl

import android.content.SharedPreferences
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

internal const val MAX_SETTINGS_DOCUMENT_BYTES = 64 * 1024

private data class IncomingMicrophoneScope(
    val accountId: String,
    val peerId: String,
    val conversationId: String,
    val kind: String,
)

/** Only persisted microphone choices; libjami still owns accounts, friends and call routing. */
internal class IncomingCallMicrophonePolicy private constructor(
    private val globalMuted: Boolean,
    private val overrides: Map<IncomingMicrophoneScope, Boolean> = emptyMap(),
    val reviewRequired: Boolean = false,
) {
    fun initialAudioMuted(accountId: String, peerId: String, conversationId: String?): Boolean =
        conversationId?.let {
            overrides[IncomingMicrophoneScope(accountId, peerId, it, "direct")]
        } ?: globalMuted

    companion object {
        fun legacy(value: String): IncomingCallMicrophonePolicy? = when (value) {
            "open" -> IncomingCallMicrophonePolicy(false)
            "ptt" -> IncomingCallMicrophonePolicy(true)
            else -> null
        }

        fun decode(document: String): IncomingCallMicrophonePolicy? = try {
            val value = settingsJsonObject(document)
            val versionValue = value.opt("schemaVersion")
            val version = if (versionValue == null || versionValue === JSONObject.NULL) {
                if (value.has("microphoneMode")) 1 else null
            } else versionValue as? Int
            // Keep this ceiling aligned with AppSettings.currentSchemaVersion.
            require(version != null && version in 1..22)
            if (version >= 17) require(FriendPreferencePolicy.decode(document) != null)
            if (version == 1) {
                legacy(value.opt("microphoneMode") as? String ?: error("Invalid legacy mode"))
            } else {
                val microphone = value.opt("microphone") as? JSONObject ?: error("Missing microphone policy")
                val reviewRequired = if (version >= 15) microphone.opt("reviewRequired") as? Boolean
                    ?: error("Missing microphone review policy") else false
                val global = mode(microphone.opt("globalDefault")) ?: error("Invalid microphone mode")
                val entries = microphone.opt("conversationOverrides") as? JSONArray
                    ?: error("Missing microphone overrides")
                val overrides = mutableMapOf<IncomingMicrophoneScope, Boolean>()
                for (index in 0 until entries.length()) {
                    val entry = entries.opt(index) as? JSONObject ?: error("Invalid microphone override")
                    val account = identifier(entry, "accountId")
                    val peer = identifier(entry, "peerId")
                    val conversation = identifier(entry, "conversationId")
                    val kind = if (entry.has("kind")) entry.opt("kind") as? String
                        else if (peer.startsWith("group:")) "group" else "direct"
                    require(kind == "direct" || kind == "group")
                    val scope = IncomingMicrophoneScope(account, peer, conversation, kind)
                    require(!overrides.containsKey(scope))
                    overrides[scope] = mode(entry.opt("mode")) ?: error("Invalid microphone override mode")
                }
                IncomingCallMicrophonePolicy(global, overrides, reviewRequired)
            }
        } catch (_: Exception) {
            null
        }

        private fun identifier(value: JSONObject, key: String): String =
            (value.opt(key) as? String)?.takeIf { it.isNotEmpty() } ?: error("Invalid microphone scope")

        private fun mode(value: Any?): Boolean? = when (value) {
            "pushToTalk" -> true
            // Dart normalizes the unsupported legacy voice-activation preference to Open.
            "open", "voiceActivated" -> false
            else -> null
        }
    }
}

/**
 * SharedPreferences.getInstance() uses this store in the pinned Flutter plugin.
 * Read at answer time, without a cached mirror. A DataStore/prefix migration must update this adapter.
 */
internal class CanonicalIncomingCallMicrophonePolicy(private val preferences: SharedPreferences) {
    private val authority = Any()
    private val writeRevision = AtomicLong(0L)
    private val savedRevision = AtomicLong(0L)
    private var completedWriteRevision = 0L

    /** Admission and answer submission share one boundary; disk I/O stays outside it. */
    fun prepareSave(document: String): () -> Boolean {
        val revision = synchronized(authority) { writeRevision.incrementAndGet() }
        return { save(document, revision) }
    }

    @Synchronized
    private fun save(document: String, revision: Long): Boolean {
        if (revision <= completedWriteRevision) return false
        completedWriteRevision = revision
        val saved = try {
            IncomingCallMicrophonePolicy.decode(document) != null &&
                preferences.edit().putString(DOCUMENT_KEY, document).commit()
        } catch (_: Exception) {
            false
        }
        // An older completion cannot clear a newer pending or failed write.
        if (saved) synchronized(authority) { savedRevision.set(revision) }
        return saved
    }

    inner class Read internal constructor(
        private val revision: Long,
        private val policy: IncomingCallMicrophonePolicy,
    ) {
        fun submit(answer: (IncomingCallMicrophonePolicy?) -> Boolean): Boolean = synchronized(authority) {
            // Admission cannot pass between this check and native answer submission.
            answer(policy.takeIf {
                !it.reviewRequired && revision == writeRevision.get() && revision == savedRevision.get()
            })
        }
    }

    fun load(): Read? = try {
        val revision = writeRevision.get()
        val document = if (revision != savedRevision.get()) null
            else preferences.getString(DOCUMENT_KEY, null)
        val policy = document?.let(IncomingCallMicrophonePolicy::decode)
        // Android can hide a backing XML read failure as an empty map. Also reject a write
        // admitted during this read. Final use also checks under the submission boundary.
        policy?.takeIf { revision == writeRevision.get() && revision == savedRevision.get() }
            ?.let { Read(revision, it) }
    } catch (_: Exception) {
        null
    }

    /** Restored privacy and account activation share the same write-admission boundary as notification answers. */
    fun currentDocument(): String? = synchronized(authority) {
        try {
            if (writeRevision.get() != savedRevision.get()) null
            else preferences.getString(DOCUMENT_KEY, null)
        } catch (_: Exception) { null }
    }

    fun withCurrentDocument(document: String, action: () -> Boolean): Boolean = synchronized(authority) {
        try {
            writeRevision.get() == savedRevision.get() &&
                preferences.getString(DOCUMENT_KEY, null) == document && action()
        } catch (_: Exception) { false }
    }

    companion object {
        const val PREFERENCES_NAME = "FlutterSharedPreferences"
        private const val DOCUMENT_KEY = "flutter.appSettings"
    }
}

/** One strict bounded parser for native microphone policy and the restore/export envelope. */
internal fun settingsJsonObject(document: String): JSONObject {
    return settingsJsonValue(document) as? JSONObject ?: error("Invalid settings object")
}

internal fun settingsJsonArray(document: String): JSONArray =
    settingsJsonValue(document) as? JSONArray ?: error("Invalid settings array")

private fun settingsJsonValue(document: String): Any {
    require(document.length <= MAX_SETTINGS_DOCUMENT_BYTES &&
        document.toByteArray(Charsets.UTF_8).size <= MAX_SETTINGS_DOCUMENT_BYTES)
    SettingsJsonSyntax(document).validate()
    val parser = JSONTokener(document)
    val value = parser.nextValue()
    require(parser.nextClean() == '\u0000')
    return value
}

/** Run on the existing daemon worker; notification extras supply only the call ID. */
internal fun answerNotificationWithMicrophonePolicy(
    callId: String,
    accountId: String?,
    calls: IncomingCallRegistry,
    routing: RoutingSnapshot,
    readPolicy: () -> CanonicalIncomingCallMicrophonePolicy.Read?,
    restorePending: Boolean = false,
    answer: (String, Boolean) -> Boolean,
): Boolean {
    if (restorePending) return false
    val pending = calls[callId] ?: return false
    if (accountId.isNullOrEmpty() || pending.accountId != accountId || routing.accountId != accountId) return false
    val peer = bareJamiId(pending.fromJamiId)
    val friend = routing.friend(peer) ?: return false
    val policy = try { readPolicy() } catch (_: Exception) { null }
    if (calls[callId] !== pending) return false
    val conversation = friend.canonicalConversationId?.takeIf { friend.confirmed && it.isNotEmpty() }
    // Unknown policy must never open a sender. Lock/Flutter visibility does not override a known Open choice.
    return policy?.submit { current ->
        if (calls[callId] !== pending) false
        else answer(callId, current?.initialAudioMuted(accountId, peer, conversation) ?: true)
    } ?: answer(callId, true)
}

/** Validate JSON grammar before Android's permissive, recursive JSONTokener. */
private class SettingsJsonSyntax(private val source: String) {
    private var index = 0

    fun validate() {
        value(1)
        whitespace()
        require(index == source.length) { "Trailing settings JSON" }
    }

    private fun value(depth: Int) {
        // Current settings use at most five nested values. Leave a bounded margin for known migrations.
        require(depth <= 20) { "Settings JSON depth" }
        whitespace()
        when (peek()) {
            '{' -> {
                index++
                whitespace()
                if (take('}')) return
                val keys = mutableSetOf<String>()
                while (true) {
                    whitespace()
                    val key = JSONTokener(string()).nextValue() as String
                    require(keys.add(key)) { "Duplicate settings key" }
                    whitespace()
                    require(take(':'))
                    value(depth + 1)
                    whitespace()
                    if (take('}')) return
                    require(take(','))
                }
            }
            '[' -> {
                index++
                whitespace()
                if (take(']')) return
                while (true) {
                    value(depth + 1)
                    whitespace()
                    if (take(']')) return
                    require(take(','))
                }
            }
            '"' -> string()
            't' -> literal("true")
            'f' -> literal("false")
            'n' -> literal("null")
            else -> number()
        }
    }

    private fun string(): String {
        val start = index
        require(take('"'))
        while (index < source.length) {
            val current = source[index++]
            if (current == '"') return source.substring(start, index)
            require(current.code >= 0x20)
            if (current == '\\') {
                require(index < source.length)
                when (source[index++]) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' -> Unit
                    'u' -> {
                        require(index + 4 <= source.length)
                        repeat(4) { require(source[index++] in "0123456789abcdefABCDEF") }
                    }
                    else -> error("Invalid settings string escape")
                }
            }
        }
        error("Unterminated settings string")
    }

    private fun number() {
        take('-')
        if (!take('0')) {
            require(peek() in '1'..'9')
            digits()
        }
        if (take('.')) digits()
        if (peek() == 'e' || peek() == 'E') {
            index++
            if (peek() == '+' || peek() == '-') index++
            digits()
        }
    }

    private fun digits() {
        require(peek() in '0'..'9')
        while (peek() in '0'..'9') index++
    }

    private fun literal(expected: String) {
        require(source.startsWith(expected, index))
        index += expected.length
    }

    private fun peek(): Char = source.getOrNull(index) ?: '\u0000'

    private fun take(expected: Char): Boolean {
        if (peek() != expected) return false
        index++
        return true
    }

    private fun whitespace() {
        while (peek() in " \t\r\n") index++
    }
}
