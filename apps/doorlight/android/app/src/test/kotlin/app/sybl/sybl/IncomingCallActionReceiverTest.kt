package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IncomingCallActionReceiverTest {
    @Test
    fun mapsOnlyExplicitNotificationActions() {
        assertEquals(
            IncomingCallNotificationAction.accept,
            incomingCallNotificationAction(ACTION_ACCEPT_INCOMING_CALL),
        )
        assertEquals(
            IncomingCallNotificationAction.decline,
            incomingCallNotificationAction(ACTION_DECLINE_INCOMING_CALL),
        )
        assertEquals(
            IncomingCallNotificationAction.ignore,
            incomingCallNotificationAction(ACTION_IGNORE_INCOMING_CALL),
        )
        assertNull(incomingCallNotificationAction(null))
        assertNull(incomingCallNotificationAction("app.sybl.sybl.UNKNOWN"))
    }
}
