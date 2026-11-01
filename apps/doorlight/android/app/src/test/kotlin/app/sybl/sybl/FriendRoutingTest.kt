package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FriendRoutingTest {
    private val me = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private val alice = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private val bob = "cccccccccccccccccccccccccccccccccccccccc"
    private val carol = "dddddddddddddddddddddddddddddddddddddddd"

    private fun contact(
        id: String,
        added: String = "2",
        removed: String = "0",
        banned: String = "false",
        confirmed: String = "false",
        conversationId: String = "",
    ) = mapOf(
        "id" to id,
        "added" to added,
        "removed" to removed,
        "banned" to banned,
        "confirmed" to confirmed,
        "conversationId" to conversationId,
    )

    private fun members(vararg ids: String) = ids.map { mapOf("uri" to it) }
    private fun membersWithRoles(vararg entries: Pair<String, String>) =
        entries.map { (id, role) -> mapOf("uri" to id, "role" to role) }

    @Test
    fun `active contacts are trusted independently of confirmation and sorted`() {
        val snapshot = buildRoutingSnapshot(
            "account", 7, me,
            listOf(
                contact(bob, confirmed = "false"),
                contact(alice, confirmed = "true"),
                contact("not-an-id"),
                contact("dddddddddddddddddddddddddddddddddddddddd", added = "1", removed = "2"),
                contact("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", banned = "true"),
            ),
            emptyMap(),
        )

        assertEquals(listOf(alice, bob), snapshot.friends.keys.toList())
        assertTrue(snapshot.isTrusted(alice))
        assertTrue(snapshot.friend(alice)!!.confirmed)
        assertTrue(snapshot.isTrusted(bob))
        assertFalse(snapshot.friend(bob)!!.confirmed)
    }

    @Test
    fun `canonical contact mapping wins while duplicate one-to-one swarms remain owned`() {
        val snapshot = buildRoutingSnapshot(
            "account", 8, me,
            listOf(contact(alice, conversationId = "z-canonical")),
            mapOf(
                "a-duplicate" to members(me, alice),
                "z-canonical" to members(me, alice),
            ),
        )

        val route = snapshot.friend(alice)!!
        assertEquals("z-canonical", route.canonicalConversationId)
        assertEquals(setOf("a-duplicate", "z-canonical"), route.conversationIds)
        assertTrue(snapshot.owns(alice, "a-duplicate"))
        assertTrue(snapshot.owns(alice, "z-canonical"))
        assertTrue(snapshot.acceptsComposerActivity("account", "z-canonical", alice, 1))
        assertTrue(snapshot.acceptsComposerActivity("account", "z-canonical", alice, 0))
        assertFalse(snapshot.acceptsComposerActivity("other", "z-canonical", alice, 1))
        assertFalse(snapshot.acceptsComposerActivity("account", "missing", alice, 1))
        assertFalse(snapshot.acceptsComposerActivity("account", "z-canonical", me, 1))
        assertFalse(snapshot.acceptsComposerActivity("account", "z-canonical", alice, 2))
    }

    @Test
    fun `smallest one-to-one swarm is a deterministic transient fallback`() {
        val snapshot = buildRoutingSnapshot(
            "account", 9, me,
            listOf(contact(alice)),
            mapOf(
                "z-last" to members(me, alice),
                "a-first" to members(me, alice),
            ),
        )

        assertEquals("a-first", snapshot.friend(alice)!!.canonicalConversationId)
    }

    @Test
    fun `group stranger and ambiguous conversations never enter an owner route`() {
        val snapshot = buildRoutingSnapshot(
            "account", 10, me,
            listOf(contact(alice), contact(bob)),
            mapOf(
                "group" to members(me, alice, bob),
                "stranger" to members(me, "dddddddddddddddddddddddddddddddddddddddd"),
                "alice" to members(me, alice),
            ),
        )

        assertNull(snapshot.peerByConversation["group"])
        assertNull(snapshot.peerByConversation["stranger"])
        assertEquals(alice, snapshot.peerByConversation["alice"])
        assertFalse(snapshot.owns(bob, "alice"))
    }

    @Test
    fun `a malformed canonical id shared by several contacts stays fail closed`() {
        val snapshot = buildRoutingSnapshot(
            "account", 11, me,
            listOf(
                contact(alice, conversationId = "collision"),
                contact(bob, conversationId = "collision"),
                contact(carol, conversationId = "collision"),
            ),
            emptyMap(),
        )

        assertNull(snapshot.peerByConversation["collision"])
        assertFalse(snapshot.owns(alice, "collision"))
        assertFalse(snapshot.owns(bob, "collision"))
        assertFalse(snapshot.owns(carol, "collision"))
    }

    @Test
    fun `owned group is a separate route with role constrained authors`() {
        val conversationId = "group-conversation"
        val snapshot = buildRoutingSnapshot(
            "account", 12, me,
            listOf(contact(alice), contact(bob), contact(carol)),
            mapOf(
                conversationId to membersWithRoles(
                    me to "admin",
                    alice to "admin",
                    bob to "invited",
                    carol to "banned",
                ),
            ),
            mapOf(conversationId to mapOf("mode" to "2", "title" to "The Crew")),
        )

        val group = snapshot.group(conversationId)!!
        assertEquals(groupOwnerKey(conversationId), group.ownerKey)
        assertEquals(listOf(alice, bob), group.memberIds)
        assertEquals(setOf(alice), group.activeMemberIds)
        assertEquals(setOf(alice), group.adminMemberIds)
        assertEquals(setOf(bob), group.invitedMemberIds)
        assertEquals(3, group.memberCount)
        assertTrue(group.canManageMembers)
        assertTrue(snapshot.owns(group.ownerKey, conversationId))
        assertEquals(group.ownerKey, snapshot.ownerKey(conversationId))
        assertTrue(snapshot.acceptsAuthor(group.ownerKey, conversationId, alice))
        assertFalse(snapshot.acceptsAuthor(group.ownerKey, conversationId, bob))
        assertFalse(snapshot.acceptsAuthor(group.ownerKey, conversationId, carol))
        assertNull(snapshot.peerByConversation[conversationId])

        val receipt = foldGroupReceipt(
            group,
            mapOf(
                alice to 2,
                "jami:$alice" to 3,
                bob to 3,
                carol to 9,
            ),
        )
        assertEquals(3, receipt.deliveryState)
        assertEquals(setOf(alice), receipt.readBy)
    }

    @Test
    fun `group without an active local role is not authorized`() {
        val conversationId = "pending-group"
        val snapshot = buildRoutingSnapshot(
            "account", 13, me,
            listOf(contact(alice)),
            mapOf(
                conversationId to membersWithRoles(
                    me to "invited",
                    alice to "admin",
                ),
            ),
            mapOf(conversationId to mapOf("mode" to "2")),
        )

        assertNull(snapshot.group(conversationId))
        assertFalse(snapshot.owns(groupOwnerKey(conversationId), conversationId))
    }

    @Test
    fun `wake peer is a direct contact or active shared group member only`() {
        val conversationId = "wake-group"
        val snapshot = buildRoutingSnapshot(
            "account", 14, me,
            listOf(contact(alice)),
            mapOf(
                conversationId to membersWithRoles(
                    me to "member",
                    bob to "member",
                    carol to "invited",
                ),
            ),
            mapOf(conversationId to mapOf("mode" to "2")),
        )

        assertTrue(snapshot.acceptsWakePeer(alice))
        assertTrue(snapshot.acceptsWakePeer(bob))
        assertFalse(snapshot.acceptsWakePeer(carol))
        assertFalse(snapshot.acceptsWakePeer("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"))
    }
}
