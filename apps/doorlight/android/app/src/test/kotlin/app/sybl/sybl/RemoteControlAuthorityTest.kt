package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlAuthorityTest {
    private val peer = "b".repeat(40)
    private val device = "1".repeat(64)
    private val source = AndroidRemoteControlSourceIdentity(
        "call", 7, 100, 200, 100, 200, 0, 0, 100, 200, 0,
    )
    private val binding = AndroidRemoteControlBinding("call", "local", peer, device, source)
    private val route = RoutingSnapshot(
        "local", "a".repeat(40), 1,
        mapOf(peer to FriendRoute(peer, true, "dm", setOf("dm"))),
        emptyMap(), mapOf("dm" to peer),
    )

    private fun current(
        account: String? = "local",
        active: String? = "call",
        winner: String? = "call",
        admitted: String? = peer,
        terminal: Boolean = false,
        routing: RoutingSnapshot = route,
    ) = RemoteControlAuthority.current(binding, account, active, winner, admitted, terminal, routing)

    @Test
    fun `only the current admitted trusted direct call can submit`() {
        assertTrue(current())
        assertFalse(current(account = "replacement"))
        assertFalse(current(active = "replacement"))
        assertFalse(current(winner = "replacement"))
        assertFalse(current(winner = null))
        assertFalse(current(admitted = "c".repeat(40)))
        assertFalse(current(admitted = null))
        assertFalse(current(terminal = true))
        assertFalse(current(routing = route.copy(accountId = "replacement")))
        assertFalse(current(routing = route.copy(friends = emptyMap())))
    }

    @Test
    fun `removing another peer preserves current authority`() {
        val other = "c".repeat(40)
        val withOther = route.copy(friends = route.friends +
            (other to FriendRoute(other, true, "other-dm", setOf("other-dm"))))
        assertTrue(current(routing = withOther.copy(friends = withOther.friends - other)))
        assertFalse(current(routing = withOther.copy(friends = withOther.friends - peer)))
    }

    @Test
    fun `Allow certificate check requires exact account and device`() {
        val details = mapOf(
            "AUTHENTICATED_PEER_ACCOUNT_ID" to peer,
            "AUTHENTICATED_PEER_DEVICE_ID" to device,
        )
        assertTrue(RemoteControlAuthority.authenticated(binding, details))
        assertFalse(RemoteControlAuthority.authenticated(binding, emptyMap()))
        assertFalse(RemoteControlAuthority.authenticated(binding,
            details + ("AUTHENTICATED_PEER_DEVICE_ID" to "2".repeat(64))))
        assertFalse(RemoteControlAuthority.authenticated(binding,
            details + ("AUTHENTICATED_PEER_ACCOUNT_ID" to "c".repeat(40))))
        assertFalse(RemoteControlAuthority.authenticated(binding,
            details - "AUTHENTICATED_PEER_DEVICE_ID"))
    }
}
