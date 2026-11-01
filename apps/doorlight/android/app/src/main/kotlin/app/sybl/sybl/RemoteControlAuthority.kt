package app.sybl.sybl

/** Native direct-call admission at consent and at every queued OS submission. */
internal object RemoteControlAuthority {
    fun current(
        binding: AndroidRemoteControlBinding,
        accountId: String?,
        activeCallId: String?,
        winnerCallId: String?,
        admittedPeer: String?,
        terminal: Boolean,
        routing: RoutingSnapshot,
    ): Boolean = binding.localAccount.isNotEmpty() && binding.callId.isNotEmpty() &&
        binding.controllerDevice.isNotEmpty() && binding.localAccount == accountId &&
        binding.callId == activeCallId && binding.callId == winnerCallId &&
        !terminal && binding.controllerAccount == admittedPeer &&
        routing.accountId == accountId && routing.isTrusted(binding.controllerAccount)

    fun authenticated(
        binding: AndroidRemoteControlBinding,
        details: Map<String, String>,
    ): Boolean = bareJamiId(details["AUTHENTICATED_PEER_ACCOUNT_ID"].orEmpty()) ==
        binding.controllerAccount &&
        details["AUTHENTICATED_PEER_DEVICE_ID"] == binding.controllerDevice &&
        binding.controllerDevice.isNotEmpty()
}

internal data class CallMessageScope(
    val accountId: String,
    val callId: String,
    val peer: String,
    internal val trustLifetime: Any,
)

/** Native ownership carried from method admission into the daemon queue. */
internal class CallMessageAuthority {
    private var routing = RoutingSnapshot.empty()
    // Only current trusted peers have a lifetime. A queued scope retains its
    // original object, which cannot match a later removal/re-add or account switch.
    private val lifetimes = mutableMapOf<String, Any>()

    @Synchronized
    fun updateRouting(snapshot: RoutingSnapshot) {
        if (routing.accountId != snapshot.accountId) lifetimes.clear()
        lifetimes.keys.retainAll(snapshot.friends.keys)
        for (peer in snapshot.friends.keys) lifetimes.getOrPut(peer) { Any() }
        routing = snapshot
    }

    @Synchronized
    fun capture(accountId: String, callId: String, peer: String): CallMessageScope? =
        if (accountId.isNotEmpty() && callId.isNotEmpty() &&
            routing.accountId == accountId && routing.isTrusted(peer)) {
            lifetimes[peer]?.let { CallMessageScope(accountId, callId, peer, it) }
        } else null

    @Synchronized
    fun current(scope: CallMessageScope): Boolean =
        routing.accountId == scope.accountId && routing.isTrusted(scope.peer) &&
            lifetimes[scope.peer] === scope.trustLifetime
}
