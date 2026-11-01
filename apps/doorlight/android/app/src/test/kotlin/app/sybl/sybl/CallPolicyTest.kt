package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CallPolicyTest {
    @Test
    fun `missing or false second-call policy is pinned true`() {
        val missing = mutableMapOf<String, String>()
        val disabled = mutableMapOf(DENY_SECOND_CALL_KEY to "false")

        assertTrue(pinDenySecondCall(missing))
        assertTrue(pinDenySecondCall(disabled))
        assertEquals("true", missing[DENY_SECOND_CALL_KEY])
        assertEquals("true", disabled[DENY_SECOND_CALL_KEY])
    }

    @Test
    fun `already pinned policy does not request an account rewrite`() {
        val details = mutableMapOf(DENY_SECOND_CALL_KEY to "true")

        assertFalse(pinDenySecondCall(details))
        assertEquals("true", details[DENY_SECOND_CALL_KEY])
    }

    @Test
    fun `system incoming notification stays behind the foreground app and active native leg`() {
        assertTrue(shouldShowIncomingCallNotification(null, activityResumed = false))
        assertFalse(shouldShowIncomingCallNotification(null, activityResumed = true))
        assertFalse(shouldShowIncomingCallNotification("displayed-or-placing-call", activityResumed = false))
    }

    @Test
    fun `terminal recovery surfaces a pending ring only after native becomes idle`() {
        assertTrue(shouldSurfacePendingIncomingCall(isTerminal = true, activeCallId = null))
        assertFalse(shouldSurfacePendingIncomingCall(isTerminal = false, activeCallId = null))
        assertFalse(shouldSurfacePendingIncomingCall(isTerminal = true, activeCallId = "surviving-call"))
    }

    @Test
    fun `cross-peer admission reserves one global pre-CURRENT slot without stealing daemon glare`() {
        assertEquals(
            IncomingCallAdmission.REJECT_UNTRUSTED,
            incomingCallAdmission(false, "peer-a", null),
        )
        assertEquals(
            IncomingCallAdmission.ACCEPT_FIRST,
            incomingCallAdmission(true, "peer-a", null),
        )
        assertEquals(
            IncomingCallAdmission.SAME_PEER_GLARE,
            incomingCallAdmission(true, "peer-a", "peer-a"),
        )
        assertEquals(
            IncomingCallAdmission.REJECT_CROSS_PEER_BUSY,
            incomingCallAdmission(true, "peer-b", "peer-a"),
        )
    }

    @Test
    fun `a CURRENT winner retires every other peer leg`() {
        assertEquals(
            setOf("same-peer", "other-peer"),
            allSiblingCallIds(
                mapOf("winner" to "peer-a", "same-peer" to "peer-a", "other-peer" to "peer-b"),
                "winner",
            ),
        )
    }

    @Test
    fun `camera adoption requires the winner to own the exact active non-held source`() {
        fun video(source: String, muted: String = "false", hold: String = "false") = mapOf(
            "MEDIA_TYPE" to "MEDIA_TYPE_VIDEO", "ENABLED" to "true", "MUTED" to muted,
            "HOLD" to hold, "SOURCE" to source,
        )

        assertTrue(mediaOwnsLocalCamera(listOf(video("camera://front")), "camera://front"))
        assertFalse(mediaOwnsLocalCamera(listOf(video("camera://back")), "camera://front"))
        assertFalse(mediaOwnsLocalCamera(listOf(video("camera://front", muted = "true")), "camera://front"))
        assertFalse(mediaOwnsLocalCamera(listOf(video("camera://front", hold = "true")), "camera://front"))
        assertFalse(mediaOwnsLocalCamera(
            listOf(mapOf("MEDIA_TYPE" to "MEDIA_TYPE_VIDEO", "SOURCE" to "camera://front")), "camera://front",
        ))
        assertFalse(mediaOwnsLocalCamera(
            listOf(mapOf("MEDIA_TYPE" to "MEDIA_TYPE_AUDIO", "ENABLED" to "true")), "camera://front",
        ))
    }
}
