package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class HologramWireTest {
    private val conversation = "a".repeat(40)
    private val peer = "b".repeat(40)
    private val operation = "c".repeat(32)
    private val prepare = """{"v":1,"t":"prepare","conversation":"$conversation","op":"$operation"}"""

    @Test fun `strict live packets accept only exact shapes`() {
        assertEquals("prepare", HologramWire.decode(prepare)?.type)
        val ready = prepare.replace("prepare", "ready").dropLast(1) + ""","nonce":"$operation"}"""
        assertEquals(operation, HologramWire.decode(ready)?.nonce)
        val present = ready.replace("ready", "present").dropLast(1) + ""","commit":"$conversation"}"""
        assertEquals(conversation, HologramWire.decode(present)?.commit)
        for (bad in listOf(
            prepare + "junk", prepare + "{}", prepare.dropLast(1) + ",}",
            prepare.replace("\"v\":1", "\"v\":1.0"),
            prepare.replace("\"v\":1", "\"v\":1,\"v\":1"),
            prepare.replace("\"v\"", "\"\\u0076\""),
            prepare.replace('"', '\''), prepare.replace("\"v\"", "v"),
            prepare.replace("prepare", "ready"), prepare.replace("prepare", "present"),
            prepare.replace(conversation, conversation.uppercase()),
            prepare.dropLast(1) + ""","extra":1}""", "x".repeat(1025),
        )) assertNull(bad, HologramWire.decode(bad))
    }

    @Test fun `only confirmed canonical direct chats authorize controls`() {
        val friend = FriendRoute(peer, true, conversation, setOf(conversation))
        val snapshot = RoutingSnapshot("account", "d".repeat(40), 1, mapOf(peer to friend), emptyMap(), mapOf(conversation to peer))
        assertTrue(HologramWire.authorized(snapshot, "account", peer, conversation))
        assertFalse(HologramWire.authorized(snapshot, "other", peer, conversation))
        assertFalse(HologramWire.authorized(snapshot, "account", snapshot.selfId, conversation))
        assertFalse(HologramWire.authorized(snapshot, "account", peer, "e".repeat(40)))
        assertFalse(HologramWire.authorized(snapshot.copy(friends = mapOf(peer to friend.copy(confirmed = false))), "account", peer, conversation))
        val group = GroupRoute(conversation, listOf(peer), setOf(peer), emptySet(), emptySet(), "member")
        assertFalse(HologramWire.authorized(snapshot.copy(groups = mapOf(conversation to group)), "account", peer, conversation))
    }
}
