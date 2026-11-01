package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class CallMessageAuthorityTest {
    private val peer = "b".repeat(40)
    private val other = "c".repeat(40)
    private val route = RoutingSnapshot(
        "local", "a".repeat(40), 1,
        mapOf(peer to FriendRoute(peer, true, "dm", setOf("dm"))),
        emptyMap(), mapOf("dm" to peer),
    )

    @Test
    fun `remove then re-add cannot revive a queued packet`() {
        val authority = CallMessageAuthority()
        authority.updateRouting(route)
        val queued = authority.capture("local", "call", peer)!!
        authority.updateRouting(route.copy(revision = 2, friends = emptyMap()))
        assertFalse(authority.current(queued))
        authority.updateRouting(route.copy(revision = 3))
        assertFalse("old queued packet crossed a retired trust lifetime", authority.current(queued))
        assertTrue(authority.current(authority.capture("local", "call", peer)!!))
    }

    @Test
    fun `unrelated routing changes preserve a current packet`() {
        val authority = CallMessageAuthority()
        authority.updateRouting(route)
        val queued = authority.capture("local", "call", peer)!!
        authority.updateRouting(route.copy(revision = 2, friends = route.friends +
            (other to FriendRoute(other, true, "other", setOf("other")))))
        assertTrue(authority.current(queued))
        authority.updateRouting(route.copy(revision = 3))
        assertTrue(authority.current(queued))
    }

    @Test
    fun `account replacement cannot borrow previous queued ownership`() {
        val authority = CallMessageAuthority()
        authority.updateRouting(route)
        val queued = authority.capture("local", "call", peer)!!
        authority.updateRouting(route.copy(accountId = "replacement"))
        assertFalse(authority.current(queued))
        assertNull(authority.capture("local", "call", peer))
        authority.updateRouting(route.copy(revision = 3))
        assertFalse("returning to an account cannot revive its old queue", authority.current(queued))
    }
}
