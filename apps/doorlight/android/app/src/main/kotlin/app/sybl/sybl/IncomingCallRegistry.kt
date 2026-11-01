package app.sybl.sybl

import java.util.concurrent.ConcurrentHashMap

/** Native ownership for rings that have not yet been accepted, refused, or terminated. */
internal data class PendingIncomingCall(
    val accountId: String,
    val fromJamiId: String,
    val offer: List<Map<String, String>>,
)

internal class IncomingCallRegistry(private val changed: () -> Unit = {}) {
    private val calls = ConcurrentHashMap<String, PendingIncomingCall>()

    operator fun get(callId: String): PendingIncomingCall? = calls[callId]

    fun put(callId: String, accountId: String, fromJamiId: String, offer: List<Map<String, String>>) {
        calls[callId] = PendingIncomingCall(accountId, fromJamiId, offer.map { it.toMap() })
        changed()
    }

    fun remove(callId: String): PendingIncomingCall? = calls.remove(callId)?.also { changed() }

    fun snapshot(): Map<String, PendingIncomingCall> = calls.toMap()
}
