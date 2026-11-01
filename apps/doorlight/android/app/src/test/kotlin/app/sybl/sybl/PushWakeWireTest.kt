package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Test

class PushWakeWireTest {
    private val wire = PushWakeWire()

    @Test
    fun `classifies call payloads before message payloads`() {
        assertEquals(PushWakeKind.CALL, wire.classify(mapOf("pt" to "audioCall", "ids" to "1")))
        assertEquals(PushWakeKind.CALL, wire.classify(mapOf("pt" to "videoCall", "ids" to "2")))
        assertEquals(
            PushWakeKind.CALL,
            wire.classify(mapOf("pt" to "application/invite,audioCall", "ids" to "3,4")),
        )
    }

    @Test
    fun `classifies messages invites and account sync`() {
        assertEquals(
            PushWakeKind.MESSAGE,
            wire.classify(mapOf("pt" to "application/im-gitmessage-id", "ids" to "5")),
        )
        assertEquals(
            PushWakeKind.MESSAGE,
            wire.classify(mapOf("pt" to "application/invite+json", "ids" to "6")),
        )
        assertEquals(PushWakeKind.MESSAGE, wire.classify(mapOf("pt" to "sync", "ids" to "7")))
        assertEquals(
            PushWakeKind.MESSAGE,
            wire.classify(mapOf("pt" to "application/x-sybl-call-request", "ids" to "8")),
        )
    }

    @Test
    fun `rejects expired unknown and over-sized payloads`() {
        assertEquals(PushWakeKind.IGNORE, wire.classify(mapOf("pt" to "audioCall", "exp" to "1")))
        assertEquals(PushWakeKind.IGNORE, wire.classify(emptyMap()))
        assertEquals(PushWakeKind.IGNORE, wire.classify(mapOf("pt" to "future-kind")))
        assertEquals(PushWakeKind.IGNORE, wire.classify(mapOf("pt" to "a".repeat(4097))))
        assertEquals(
            PushWakeKind.IGNORE,
            wire.classify(mapOf("pt" to List(65) { "sync" }.joinToString(","))),
        )
    }

    @Test
    fun `deduplicates scoped value ids but accepts known types without ids`() {
        val first = mapOf("pt" to "audioCall", "ids" to "8", "to" to "device", "key" to "call")
        assertEquals(PushWakeKind.CALL, wire.classify(first))
        assertEquals(PushWakeKind.IGNORE, wire.classify(first))
        assertEquals(PushWakeKind.CALL, wire.classify(first + ("key" to "other")))
        assertEquals(PushWakeKind.MESSAGE, wire.classify(mapOf("pt" to "sync")))
    }

    @Test
    fun `accepts only the exact opaque relay marker`() {
        assertEquals(PushWakeKind.RELAY, wire.classify(mapOf("w" to "1")))
        assertEquals(PushWakeKind.IGNORE, wire.classify(mapOf("w" to "0")))
        assertEquals(PushWakeKind.IGNORE, wire.classify(mapOf("w" to "1", "extra" to "1")))
    }
}
