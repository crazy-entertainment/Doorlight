package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Test

class AuthenticatedCallPeerTest {
    @Test fun sipIdentityCannotReplaceTransportAuthentication() {
        val peer = "a".repeat(40)
        val device = "b".repeat(64)
        assertEquals("", authenticatedCallPeer(mapOf("PEER_NUMBER" to peer)))
        assertEquals("", authenticatedCallPeer(mapOf("AUTHENTICATED_PEER_ACCOUNT_ID" to peer)))
        assertEquals(peer, authenticatedCallPeer(mapOf(
            "AUTHENTICATED_PEER_ACCOUNT_ID" to peer,
            "AUTHENTICATED_PEER_DEVICE_ID" to device,
            "PEER_NUMBER" to "c".repeat(40),
        )))
        assertEquals("", authenticatedCallPeer(mapOf(
            "AUTHENTICATED_PEER_ACCOUNT_ID" to peer,
            "AUTHENTICATED_PEER_DEVICE_ID" to "\n$device",
        )))
    }
}
