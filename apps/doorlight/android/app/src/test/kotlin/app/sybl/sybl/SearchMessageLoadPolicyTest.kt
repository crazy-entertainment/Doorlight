package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SearchMessageLoadPolicyTest {
    private val conversation = "c".repeat(40)
    private val message = "a".repeat(40)

    private fun facts(
        owned: Boolean = true,
        active: Boolean = true,
        routing: Boolean = true,
        epoch: Long = 3L,
        restore: Boolean = false,
    ) = SearchMessageLoadFacts(owned, active, routing, epoch, restore)

    private fun admit(
        account: String = "acc",
        peer: String = "peer",
        conv: String = conversation,
        id: String = message,
        f: SearchMessageLoadFacts = facts(),
        canStart: Boolean = true,
    ) = SearchMessageLoadPolicy.admit(account, peer, conv, id, 3L, f, canStart)

    private fun load(scope: NativeAccountScope = NativeAccountScope("acc", Any())) =
        SearchMessageConversationLoad("acc", scope, "peer", conversation, message, false, 3L) { }

    private fun complete(
        load: SearchMessageConversationLoad = load(),
        f: SearchMessageLoadFacts = facts(),
        ids: List<String> = listOf(message),
        account: String = "acc",
        conv: String = conversation,
    ) = SearchMessageLoadPolicy.complete(load, account, conv, f, ids)

    @Test
    fun admissionAcceptsOnlyAValidOwnedRequest() {
        assertTrue(admit())
        assertFalse(admit(account = ""))
        assertFalse(admit(peer = ""))
        assertFalse(admit(f = facts(owned = false)))
        assertFalse(admit(f = facts(active = false)))
        assertFalse(admit(f = facts(routing = false)))
        assertFalse(admit(f = facts(epoch = 4L)))
        assertFalse(admit(f = facts(restore = true)))
        assertFalse(admit(canStart = false))
        for (bad in listOf("", "z".repeat(40), "a".repeat(39), "a".repeat(41), "A".repeat(40))) {
            assertFalse("conversation $bad", admit(conv = bad))
            assertFalse("message $bad", admit(id = bad))
        }
    }

    @Test
    fun completionProjectsOnlyTheOneRequestedMessage() {
        assertEquals(0, complete())
        assertNull(complete(ids = emptyList()))
        assertNull(complete(ids = listOf("b".repeat(40))))
        assertNull(complete(ids = listOf(message, message)))
        assertNull(complete(ids = listOf(message, "b".repeat(40))))
        assertNull(complete(account = "other"))
        assertNull(complete(conv = "d".repeat(40)))
    }

    @Test
    fun completionRecheckesEveryFactAgainstTheStoredRequest() {
        assertNull(complete(f = facts(owned = false)))
        assertNull(complete(f = facts(active = false)))
        assertNull(complete(f = facts(routing = false)))
        assertNull(complete(f = facts(epoch = 4L)))
        assertNull(complete(f = facts(restore = true)))
    }

    @Test
    fun aToBToAStillAnswersUnavailable() {
        val authority = NativeAccountAuthority()
        authority.select("acc")
        val scope = authority.capture("acc")!!
        val stored = load(scope)
        assertEquals(0, complete(stored, facts(owned = authority.owns(scope))))
        authority.select("other")
        authority.select("acc")
        assertTrue(authority.capture("acc") != null)
        assertFalse(authority.owns(scope))
        assertNull(complete(stored, facts(owned = authority.owns(scope))))
    }

    @Test
    fun dispatchRunsExactlyOneNamedHandler() {
        var projected = -1
        var unavailable = 0
        SearchMessageLoadPolicy.dispatch(load(), "acc", conversation, facts(), listOf(message),
            onProject = { projected = it }, onUnavailable = { unavailable += 1 })
        assertEquals(0, projected)
        assertEquals(0, unavailable)
        projected = -1
        SearchMessageLoadPolicy.dispatch(load(), "acc", conversation, facts(restore = true), listOf(message),
            onProject = { projected = it }, onUnavailable = { unavailable += 1 })
        assertEquals(-1, projected)
        assertEquals(1, unavailable)
    }

    @Test
    fun aLoadAnswersAtMostOnce() {
        val answers = mutableListOf<Map<String, Any>?>()
        val stored = SearchMessageConversationLoad(
            "acc", NativeAccountScope("acc", Any()), "peer", conversation, message, true, 3L,
        ) { answers.add(it) }
        assertTrue(stored.answer(null))
        assertFalse(stored.answer(mapOf("kind" to "group")))
        assertEquals(listOf<Map<String, Any>?>(null), answers)
        assertEquals("SearchMessageConversationLoad(<private>)", stored.toString())
    }
}
