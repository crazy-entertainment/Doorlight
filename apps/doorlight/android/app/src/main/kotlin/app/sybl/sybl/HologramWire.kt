package app.sybl.sybl

import org.json.JSONObject

internal object HologramWire {
    const val MIME = "application/x-sybl-hologram-live+json"
    private val id = Regex("^[0-9a-f]{40}$")
    private val nonce = Regex("^[0-9a-f]{32}$")
    private val key = Regex("\"(?:v|t|conversation|op|nonce|commit)\"\\s*:")
    // This protocol has no escaped strings, nested values, or optional fields.
    // Gate JSONObject's deliberately lenient parser with the exact JSON grammar.
    private val field = "(?:\"v\"[ \\t\\r\\n]*:[ \\t\\r\\n]*1|\"(?:t|conversation|op|nonce|commit)\"[ \\t\\r\\n]*:[ \\t\\r\\n]*\"[a-z0-9]+\")"
    private val objectSyntax = Regex("[ \\t\\r\\n]*\\{[ \\t\\r\\n]*$field(?:[ \\t\\r\\n]*,[ \\t\\r\\n]*$field)*[ \\t\\r\\n]*\\}[ \\t\\r\\n]*")
    data class Packet(val type: String, val conversation: String, val operation: String,
                      val nonce: String = "", val commit: String = "")

    fun decode(body: String): Packet? {
        if (body.length > 1024 || body.toByteArray(Charsets.UTF_8).size > 1024) return null
        if (!objectSyntax.matches(body)) return null
        return try {
            val value = JSONObject(body)
            if (value.opt("v") !is Int || value.getInt("v") != 1) return null
            val type = value.opt("t") as? String ?: return null
            val fields = when (type) {
                "prepare" -> setOf("v", "t", "conversation", "op")
                "ready" -> setOf("v", "t", "conversation", "op", "nonce")
                "present" -> setOf("v", "t", "conversation", "op", "nonce", "commit")
                else -> return null
            }
            if (value.keys().asSequence().toSet() != fields || key.findAll(body).count() != fields.size) return null
            val conversation = value.opt("conversation") as? String ?: return null
            val operation = value.opt("op") as? String ?: return null
            if (!id.matches(conversation) || !nonce.matches(operation)) return null
            val random = if ("nonce" in fields) value.opt("nonce") as? String ?: return null else ""
            val commit = if ("commit" in fields) value.opt("commit") as? String ?: return null else ""
            if (("nonce" in fields && !nonce.matches(random)) || ("commit" in fields && !id.matches(commit))) return null
            Packet(type, conversation, operation, random, commit)
        } catch (_: Exception) { null }
    }

    fun authorized(snapshot: RoutingSnapshot, account: String, peer: String, conversation: String): Boolean {
        if (snapshot.accountId != account || peer.isEmpty() || peer == snapshot.selfId) return false
        if (snapshot.group(conversation) != null) return false
        val friend = snapshot.friend(peer) ?: return false
        return friend.confirmed && friend.canonicalConversationId == conversation
    }
}
