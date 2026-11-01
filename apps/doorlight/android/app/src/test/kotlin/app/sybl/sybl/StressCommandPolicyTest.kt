package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class StressCommandPolicyTest {
    @Test fun commandsAreClosedAndPeerSelectionIsExact() {
        for (command in listOf("ping", "voice", "video", "answer", "hangup", "chat:1", "chat:9")) {
            assertEquals("", StressCommandPolicy.peer(command, null))
        }
        for (command in listOf("", "chat:0", "chat:10", "voice;hangup", "VOICE", "camera:any")) {
            assertNull(StressCommandPolicy.peer(command, null))
        }
        assertEquals("a".repeat(40), StressCommandPolicy.peer("select", "A".repeat(40)))
        assertEquals("select:${"a".repeat(40)}", StressCommandPolicy.dispatchCommand("select", "A".repeat(40)))
        assertEquals("voice", StressCommandPolicy.dispatchCommand("voice", null))
        for (peer in listOf(null, "", "a".repeat(39), "a".repeat(41), "g".repeat(40))) {
            assertNull(StressCommandPolicy.peer("select", peer))
            assertNull(StressCommandPolicy.dispatchCommand("select", peer))
        }
    }
}
