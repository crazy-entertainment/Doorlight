package app.sybl.sybl

import java.util.Locale
import org.json.JSONArray
import org.json.JSONObject

/** Canonical settings only. A preference never establishes trust or runtime authority. */
internal class FriendPreferencePolicy private constructor(
    private val globalHolograms: Boolean,
    private val globalAlerts: Boolean,
    private val reviewRequired: Boolean,
    private val overrides: Map<Pair<String, String>, Preference>,
) {
    private data class Preference(val holograms: String, val alerts: String)

    fun allowsHolograms(account: String, peer: String): Boolean {
        if (reviewRequired || !validAccount(account) || !validPeer(peer)) return false
        return when (overrides[account to peer.lowercase(Locale.ROOT)]?.holograms) {
            "allow" -> true
            "block" -> false
            else -> globalHolograms
        }
    }

    fun allowsMessageAlerts(account: String, peer: String): Boolean =
        !reviewRequired && globalAlerts && validAccount(account) && validPeer(peer) &&
            overrides[account to peer.lowercase(Locale.ROOT)]?.alerts != "mute"

    fun allowsGroupMessageAlerts(account: String): Boolean =
        !reviewRequired && globalAlerts && validAccount(account)

    companion object {
        private fun validAccount(value: String): Boolean = value.isNotEmpty() && value.length <= 128 &&
            // Dart's canonical owner trim additionally treats NEL and BOM as whitespace.
            value.trim { it.isWhitespace() || it == '\u0085' || it == '\ufeff' } == value &&
            value.none { it.code < 32 || it.code == 127 }
        private fun validPeer(value: String): Boolean = value.matches(Regex("[0-9a-fA-F]{40}"))

        fun decode(document: String): FriendPreferencePolicy? = try {
            val root = settingsJsonObject(document)
            val version = root.opt("schemaVersion") as? Int ?: error("Missing settings version")
            require(version in 1..22)
            val notifications = root.opt("notifications") as? JSONObject
            val holograms = if (version >= 16)
                notifications?.opt("hologramPresentationEnabled") as? Boolean ?: error("Missing Hologram policy")
                else true
            if (version < 17) {
                FriendPreferencePolicy(holograms, true, false, emptyMap())
            } else {
                val globalAlerts = notifications?.opt("messageAlertsEnabled") as? Boolean
                    ?: error("Missing message alerts policy")
                val friends = root.opt("friendPreferences") as? JSONObject ?: error("Missing friend policy")
                val review = friends.opt("reviewRequired") as? Boolean ?: error("Missing friend review policy")
                val entries = friends.opt("overrides") as? JSONArray ?: error("Missing friend overrides")
                require(entries.length() <= 256)
                val overrides = mutableMapOf<Pair<String, String>, Preference>()
                for (index in 0 until entries.length()) {
                    val entry = entries.opt(index) as? JSONObject ?: error("Invalid friend override")
                    val account = entry.opt("accountId") as? String ?: error("Missing friend owner")
                    val peer = entry.opt("peerId") as? String ?: error("Missing friend peer")
                    require(validAccount(account) && validPeer(peer))
                    val key = account to peer.lowercase(Locale.ROOT)
                    require(!overrides.containsKey(key))
                    val choice = entry.opt("holograms") as? String
                    val alerts = entry.opt("messageAlerts") as? String
                    require(choice in setOf("useGlobalDefault", "allow", "block"))
                    require(alerts in setOf("useGlobalDefault", "mute"))
                    overrides[key] = Preference(choice!!, alerts!!)
                }
                FriendPreferencePolicy(holograms, globalAlerts, review, overrides)
            }
        } catch (_: Exception) { null }
    }
}
