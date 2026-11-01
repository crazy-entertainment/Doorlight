package app.sybl.sybl

import java.security.SecureRandom

internal data class MessageActionOwner(
    val account: NativeAccountScope,
    val identity: String,
    val ownerKey: String,
    val conversationId: String,
    val topicId: String,
    val startCall: Boolean = false,
    val replyAllowed: Boolean = true,
)

/** Process-local capabilities. A restarted receiver cannot revive an orphan intent. */
internal class MessageActionTokens(
    private val random: () -> String = {
        val bytes = ByteArray(32).also { SecureRandom().nextBytes(it) }
        bytes.joinToString("") { "%02x".format(it.toInt() and 255) }
    },
) {
    private val actions = linkedMapOf<String, MessageActionOwner>()

    @Synchronized fun issue(owner: MessageActionOwner): String? {
        val previous = actions.entries.firstOrNull {
            it.value.conversationId == owner.conversationId && it.value.startCall == owner.startCall &&
                it.value.replyAllowed == owner.replyAllowed
        }?.key
        if (previous == null && actions.size >= 128) return null
        val token = random()
        if (!TOKEN.matches(token) || actions.containsKey(token)) return null
        if (previous != null) actions.remove(previous)
        actions[token] = owner
        return token
    }

    @Synchronized fun resolve(token: String): MessageActionOwner? =
        if (TOKEN.matches(token)) actions[token] else null

    @Synchronized fun consume(token: String, expected: MessageActionOwner): Boolean {
        if (actions[token] != expected) return false
        actions.remove(token)
        return true
    }

    @Synchronized fun retireConversation(conversation: String) {
        actions.entries.removeAll { it.value.conversationId == conversation }
    }

    @Synchronized fun clear() { actions.clear() }

    private companion object { val TOKEN = Regex("^[0-9a-f]{64}$") }
}
