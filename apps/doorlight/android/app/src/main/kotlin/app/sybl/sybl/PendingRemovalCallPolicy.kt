package app.sybl.sybl

import android.content.SharedPreferences
import org.json.JSONObject

/** Direct-call revocation only. Daemon trust remains available to deliver the removal notice. */
internal class PendingRemovalCallPolicy(private val preferences: SharedPreferences) {
    fun allows(accountId: String, peerId: String, routing: RoutingSnapshot): Boolean {
        if (routing.accountId != accountId) return false
        val peer = bareJamiId(peerId).takeIf { it.isNotEmpty() } ?: return false
        val friend = routing.friend(peer) ?: return false
        return try {
            // getString throws for a wrong stored type. An absent key is the legacy, unrestricted case.
            val document = preferences.getString(KEY, null) ?: return true
            val entries = settingsJsonArray(document)
            require(entries.length() <= 64)
            val seen = mutableSetOf<Pair<String, String>>()
            var denied = false
            for (index in 0 until entries.length()) {
                val marker = entries.opt(index) as? JSONObject ?: error("Invalid removal marker")
                val account = marker.opt("accountId") as? String ?: error("Invalid removal account")
                val from = marker.opt("peerId") as? String ?: error("Invalid removal peer")
                val conversation = marker.opt("conversationId") as? String ?: error("Invalid removal conversation")
                require(account.isNotEmpty() && from.isNotEmpty())
                require(from == bareJamiId(from))
                val deadline = marker.opt("deadlineMs")
                require(deadline is Int || deadline is Long)
                val notice = marker.opt("noticeCommitId")
                require(notice == null || notice === JSONObject.NULL || (notice is String && notice.length <= 128))
                require(seen.add(account to from))
                if (account == accountId && from == peer) {
                    // The deadline schedules removal; it never expires the revocation.
                    // Unknown routing cannot prove this is a different, re-added friendship.
                    denied = denied || friend.canonicalConversationId == null ||
                        friend.canonicalConversationId == conversation
                }
            }
            !denied
        } catch (_: Exception) {
            // Ambiguous or unreadable authority must not reopen a direct call.
            false
        }
    }

    companion object {
        const val KEY = "flutter.doorlight.pendingFriendRemovals.v1"
    }
}

/** Both native Answer entries use the retained, authenticated ring, including after recorder teardown. */
internal fun answerRetainedIncomingCall(
    callId: String,
    accountId: String,
    calls: IncomingCallRegistry,
    allowed: (String, String) -> Boolean,
    prepare: () -> Boolean,
    denied: (PendingIncomingCall) -> Unit = {},
    submit: (PendingIncomingCall) -> Boolean,
): Boolean {
    val pending = calls[callId] ?: return false
    fun current(): Boolean {
        if (calls[callId] !== pending || pending.accountId != accountId) return false
        if (allowed(accountId, pending.fromJamiId)) return calls[callId] === pending
        denied(pending)
        return false
    }
    if (!current() || !prepare() || !current()) return false
    return submit(pending)
}
