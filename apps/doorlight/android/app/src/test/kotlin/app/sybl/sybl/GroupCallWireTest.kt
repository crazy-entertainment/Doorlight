package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class GroupCallWireTest {
    @Test fun conferenceMetadataHasAnAggregateBudgetBeforeProjection() {
        val row = mapOf("uri" to "a".repeat(40), "device" to "b".repeat(64), "sinkId" to "video")
        assertEquals(listOf(row), GroupCallWire.boundedConference(listOf(row)))
        assertNull(GroupCallWire.boundedConference(List(129) { row }))
        assertNull(GroupCallWire.boundedConference(listOf(row + ("name" to "x".repeat(1025)))))
        assertNull(GroupCallWire.boundedConference(listOf(row + ("name" to "界".repeat(400)))))
        val heavy = (1..32).associate { "k$it" to "x".repeat(1024) }
        assertNull(GroupCallWire.boundedConference(List(3) { heavy }))
        assertNull(GroupCallWire.boundedConference(listOf((1..33).associate { "k$it" to "x" })))
    }

    @Test
    fun `a joined conference negotiates media on its call leg`() {
        assertEquals("leg", GroupCallWire.mediaTarget("conference", "leg", hosting = false))
        assertEquals("conference", GroupCallWire.mediaTarget("conference", "", hosting = false))
        assertEquals("conference", GroupCallWire.mediaTarget("conference", "leg", hosting = true))
    }

    @Test
    fun `a group video sink can use its conference or call leg id`() {
        assertTrue(GroupCallWire.ownsMediaSink("conference", "leg", "conference"))
        assertTrue(GroupCallWire.ownsMediaSink("conference", "leg", "leg"))
        assertFalse(GroupCallWire.ownsMediaSink("conference", "leg", "other"))
    }

    @Test
    fun `a local group host sends screen frames through the conference mixer`() {
        assertTrue(GroupCallWire.screenShareNeedsRawFrames("conference", hosting = true))
        assertFalse(GroupCallWire.screenShareNeedsRawFrames("conference", hosting = false))
        assertFalse(GroupCallWire.screenShareNeedsRawFrames("", hosting = true))
    }

    @Test
    fun `a host claims an admitted current leg before Jami attaches it`() {
        assertEquals(
            "conference",
            GroupCallWire.hostConferenceForCurrent("conference", hosting = true, rejected = false, state = "CURRENT"),
        )
        assertNull(GroupCallWire.hostConferenceForCurrent("conference", true, true, "CURRENT"))
        assertNull(GroupCallWire.hostConferenceForCurrent("conference", true, false, "INCOMING"))
    }

    @Test
    fun `conference ids map only Syb-L group voice rooms`() {
        assertEquals("voice", GroupCallWire.roomId("syblv1-voice-42"))
        assertEquals("games-room", GroupCallWire.roomId("syblv1-games-room-9"))
        assertNull(GroupCallWire.roomId("ordinary-call"))
        assertNull(GroupCallWire.roomId("syblv1-Voice-1"))
        assertNull(GroupCallWire.roomId("syblv1-voice-0"))
        assertNull(GroupCallWire.roomId("syblv1-${"a".repeat(33)}-1"))
    }

    @Test
    fun `presence ingress requires an active group member and a bounded body`() {
        val member = "a".repeat(40)
        val route = GroupRoute(
            conversationId = "b".repeat(40),
            memberIds = listOf(member),
            activeMemberIds = setOf(member),
            adminMemberIds = emptySet(),
            invitedMemberIds = emptySet(),
            localRole = "member",
        )
        val snapshot = RoutingSnapshot(
            accountId = "c".repeat(40),
            selfId = "d".repeat(40),
            revision = 1,
            friends = emptyMap(),
            groups = mapOf(route.conversationId to route),
            peerByConversation = emptyMap(),
        )

        assertTrue(GroupCallWire.acceptPresence(snapshot, member, "{}"))
        assertFalse(GroupCallWire.acceptPresence(snapshot, "e".repeat(40), "{}"))
        assertFalse(
            GroupCallWire.acceptPresence(
                snapshot,
                member,
                "x".repeat(GroupCallWire.MAX_PRESENCE_BYTES + 1),
            ),
        )
    }
}
