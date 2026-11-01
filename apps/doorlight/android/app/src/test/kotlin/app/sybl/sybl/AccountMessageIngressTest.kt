package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AccountMessageIngressTest {
    private val me = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    private val alice = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private val bob = "cccccccccccccccccccccccccccccccccccccccc"
    private val carol = "dddddddddddddddddddddddddddddddddddddddd"
    private val stranger = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    private val now = 1_000L
    private val handle = "A".repeat(43)

    private fun snapshot(bobRole: String = "member", carolRole: String = "banned") = buildRoutingSnapshot(
        "account", 1, me,
        listOf(mapOf("id" to alice, "added" to "2", "removed" to "0", "banned" to "false",
            "confirmed" to "true", "conversationId" to "")),
        mapOf("group" to listOf(
            mapOf("uri" to me, "role" to "member"),
            mapOf("uri" to bob, "role" to bobRole),
            mapOf("uri" to carol, "role" to carolRole),
        )),
        mapOf("group" to mapOf("mode" to "2")),
    )

    private fun wake() = PresenceWire.encode("wake", false, now, color = "amber", wake = handle)
    private fun ping() = PresenceWire.encode("ping", true, now, color = "amber")
    private fun pong() = PresenceWire.encode("pong", true, now, color = "amber")
    private fun decide(from: String, payloads: Map<String, String>, snapshot: RoutingSnapshot = snapshot()) =
        classifyAccountMessage(snapshot, from, payloads, now)

    @Test
    fun `direct contact is handled in full for any payload`() {
        assertEquals(AccountMessageIngress.FULL, decide(alice, mapOf(PROBE_MIME to ping())))
        assertEquals(AccountMessageIngress.FULL, decide(alice, mapOf(PROBE_MIME to wake())))
        assertEquals(AccountMessageIngress.FULL, decide(alice, mapOf(HologramWire.MIME to "{}")))
    }

    @Test
    fun `active group member with only a wake packet is wake-only`() {
        assertEquals(AccountMessageIngress.WAKE_ONLY, decide(bob, mapOf(PROBE_MIME to wake())))
    }

    @Test
    fun `wake packet plus any additional key is dropped even when unrecognised`() {
        for (extra in listOf("text/x-vcard", "application/x-unknown", "")) {
            assertEquals(extra, AccountMessageIngress.DROP,
                decide(bob, mapOf(PROBE_MIME to wake(), extra to "BEGIN:VCARD")))
        }
    }

    private class Calls {
        val log = mutableListOf<String>()
        var args: Pair<String, Map<String, String>>? = null
    }

    private fun route(from: String, payloads: Map<String, String>, snapshot: RoutingSnapshot = snapshot()): Calls {
        val calls = Calls()
        routeAccountMessage(
            snapshot = snapshot,
            from = from,
            payloads = payloads,
            onFull = { f, p -> calls.log += "full"; calls.args = f to p },
            onWakeOnly = { f, p -> calls.log += "wake"; calls.args = f to p },
            onDrop = { f -> calls.log += "drop"; calls.args = f to emptyMap() },
            nowMs = now,
        )
        return calls
    }

    @Test
    fun `routing runs exactly one handler once with the same arguments`() {
        val wakeOnly = mapOf(PROBE_MIME to wake())
        val ping = mapOf(PROBE_MIME to ping())
        val full = route(alice, ping)
        assertEquals(listOf("full"), full.log)
        assertEquals(alice to ping, full.args)
        val wakeCall = route(bob, wakeOnly)
        assertEquals(listOf("wake"), wakeCall.log)
        assertEquals(bob to wakeOnly, wakeCall.args)
        val dropped = route(bob, ping)
        assertEquals(listOf("drop"), dropped.log)
        assertEquals(bob, dropped.args?.first)
        assertEquals(listOf("drop"), route(stranger, wakeOnly).log)
        assertEquals(listOf("drop"), route(bob, wakeOnly + ("text/x-vcard" to "x")).log)
        assertEquals(listOf("full"), route(alice, wakeOnly).log)
    }

    @Test
    fun `active group member is dropped for every non-wake payload`() {
        val others = listOf(
            mapOf(PROBE_MIME to ping()),
            mapOf(PROBE_MIME to pong()),
            mapOf(PROBE_MIME to "garbage"),
            mapOf(HologramWire.MIME to "{}"),
            mapOf(CALL_REQUEST_MIME to "{}"),
            mapOf(FILE_DECLINED_MIME to "{}"),
            mapOf(FILE_THUMBNAIL_MIME to "{}"),
            mapOf(GroupCallWire.PRESENCE_MIME to "{}"),
            emptyMap(),
        )
        for (payloads in others) {
            assertEquals(payloads.keys.toString(), AccountMessageIngress.DROP, decide(bob, payloads))
        }
    }

    @Test
    fun `wake packet plus any other recognised payload is dropped`() {
        for (mime in listOf(HologramWire.MIME, CALL_REQUEST_MIME, FILE_DECLINED_MIME,
            FILE_THUMBNAIL_MIME, GroupCallWire.PRESENCE_MIME)) {
            assertEquals(mime, AccountMessageIngress.DROP,
                decide(bob, mapOf(PROBE_MIME to wake(), mime to "{}")))
        }
    }

    @Test
    fun `removed banned invited and unrelated peers are dropped`() {
        assertEquals(AccountMessageIngress.DROP, decide(carol, mapOf(PROBE_MIME to wake())))
        assertEquals(AccountMessageIngress.DROP, decide(stranger, mapOf(PROBE_MIME to wake())))
        val invited = snapshot(bobRole = "invited")
        assertEquals(AccountMessageIngress.DROP, decide(bob, mapOf(PROBE_MIME to wake()), invited))
        val left = snapshot(bobRole = "left")
        assertEquals(AccountMessageIngress.DROP, decide(bob, mapOf(PROBE_MIME to wake()), left))
    }

    @Test
    fun `decision recomputed after membership removal drops`() {
        val payloads = mapOf(PROBE_MIME to wake())
        assertEquals(AccountMessageIngress.WAKE_ONLY, decide(bob, payloads, snapshot()))
        assertEquals(AccountMessageIngress.DROP, decide(bob, payloads, snapshot(bobRole = "banned")))
        assertEquals(AccountMessageIngress.DROP, decide(bob, payloads, RoutingSnapshot.empty("account")))
    }

    @Test
    fun `decorated sender forms normalise like bare ids`() {
        val payloads = mapOf(PROBE_MIME to wake())
        for (from in listOf("jami:$bob", "$bob@ring.dht", bob.uppercase())) {
            assertEquals(from, AccountMessageIngress.WAKE_ONLY, decide(from, payloads))
        }
        assertEquals(AccountMessageIngress.FULL, decide("jami:$alice", payloads))
        assertEquals(AccountMessageIngress.FULL, decide("$alice@ring.dht", payloads))
        assertEquals(AccountMessageIngress.DROP, decide("jami:$stranger", payloads))
        assertEquals(AccountMessageIngress.DROP, decide("", payloads))
    }
}
