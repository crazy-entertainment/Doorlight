package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class MessagingCaptureAuthorityTest {
    @Test fun callThatStartsAndEndsStillInvalidatesTheCameraRequest() {
        val accounts = NativeAccountAuthority().apply { select("a") }
        val captures = MessagingCaptureAuthority(accounts::owns)
        val first = captures.begin(accounts.capture())!!
        assertTrue(captures.owns(first))
        captures.setBlocked(MessagingCaptureBlocker.RESERVED, true)
        captures.setBlocked(MessagingCaptureBlocker.RESERVED, false)
        assertFalse(captures.owns(first))
        assertNull(captures.begin(accounts.capture()))
        captures.retire(first)
        val second = captures.begin(accounts.capture())!!
        captures.retire(first)
        assertTrue(captures.owns(second))
    }

    @Test fun accountAbaCannotAttachToAReplacementIdentity() {
        val accounts = NativeAccountAuthority().apply { select("a") }
        val captures = MessagingCaptureAuthority(accounts::owns)
        val lease = captures.begin(accounts.capture())!!
        accounts.select("b")
        accounts.select("a")
        assertFalse(captures.owns(lease))
    }

    @Test fun everyReservationAndRecordingBlocksInitiation() {
        val accounts = NativeAccountAuthority().apply { select("a") }
        for (blocker in MessagingCaptureBlocker.values()) {
            val captures = MessagingCaptureAuthority(accounts::owns)
            captures.setBlocked(blocker, true)
            assertNull(captures.begin(accounts.capture()))
            captures.setBlocked(blocker, false)
            assertNotNull(captures.begin(accounts.capture()))
        }
    }
}
