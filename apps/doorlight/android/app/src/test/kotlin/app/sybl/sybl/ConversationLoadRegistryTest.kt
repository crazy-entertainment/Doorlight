package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationLoadRegistryTest {
    private fun chat(peer: String = "peer") =
        ChatConversationLoad(peer, "conversation", "", 50)

    private fun folder(peer: String = "peer") =
        FolderConversationLoad(peer, "conversation", 200)

    private fun dmTopicState(peer: String = "peer") =
        DmTopicStateConversationLoad(peer, "conversation", "cursor", 200)

    @Test
    fun completedCancelledAndExpiredIdsCanNeverBeReused() {
        var now = 0L
        val registry = ConversationLoadRegistry(
            deadlineMs = 100,
            monotonicMs = { now },
        )

        assertTrue(registry.register(7, chat()))
        assertEquals(ConversationLoadKind.CHAT, registry.take(7)?.kind)
        assertFalse(registry.register(7, chat("other")))
        assertNull(registry.take(7))

        assertTrue(registry.register(8, chat()))
        assertTrue(registry.cancelChat(8))
        assertFalse(registry.register(8, chat()))

        assertTrue(registry.register(9, chat()))
        now = 100
        assertNull(registry.take(9))
        assertFalse(registry.register(9, chat()))
        assertEquals(3, registry.rememberedSize())
    }

    @Test
    fun kindPeerAndActiveLimitAllFailClosed() {
        var now = 0L
        val registry = ConversationLoadRegistry(
            deadlineMs = 100,
            maxActiveLoads = 2,
            maxRememberedIds = 8,
            monotonicMs = { now },
        )

        assertTrue(registry.register(1, folder()))
        assertFalse(registry.cancelChat(1))
        assertTrue(registry.register(2, chat("other")))
        assertFalse(registry.canStart())

        registry.removePeer("peer")
        assertEquals(1, registry.activeSize())
        assertTrue(registry.canStart())

        now = 100
        assertTrue(registry.canStart())
        assertEquals(0, registry.activeSize())
    }

    @Test
    fun dmTopicStateIsDistinctFromVisibleChatHistory() {
        val registry = ConversationLoadRegistry(monotonicMs = { 0 })

        assertTrue(registry.register(3, dmTopicState()))
        assertFalse(registry.cancelChat(3))
        assertEquals(ConversationLoadKind.DM_TOPIC_STATE, registry.take(3)?.kind)
        assertTrue(registry.register(4, dmTopicState()))
        assertTrue(registry.cancelDmTopicState(4))
        assertNull(registry.take(4))
        assertFalse(registry.register(4, dmTopicState()))
        assertTrue(registry.register(5, chat()))
        assertFalse(registry.cancelDmTopicState(5))
        assertEquals(ConversationLoadKind.CHAT, registry.take(5)?.kind)
    }

    @Test
    fun rememberedIdBudgetNeverFallsBackToRecycling() {
        val registry = ConversationLoadRegistry(
            maxActiveLoads = 1,
            maxRememberedIds = 2,
            monotonicMs = { 0 },
        )
        assertTrue(registry.register(1, chat()))
        assertTrue(registry.take(1) != null)
        assertTrue(registry.register(2, chat()))
        assertTrue(registry.take(2) != null)
        assertFalse(registry.canStart())
        assertFalse(registry.register(3, chat()))
        assertNull(registry.take(3))
    }

    private fun searchLoad(
        answers: MutableList<Map<String, Any>?>,
        peer: String = "peer",
    ) = SearchMessageConversationLoad(
        "acc", NativeAccountScope("acc", Any()), peer, "c".repeat(40), "m".repeat(40), false, 0L,
    ) { answers.add(it) }

    private fun retiredAnswering(
        deadlineMs: Long = 100,
        maxActiveLoads: Int = 64,
        maxRememberedIds: Int = 64 * 1024,
        now: () -> Long = { 0 },
    ) = ConversationLoadRegistry(
        deadlineMs = deadlineMs,
        maxActiveLoads = maxActiveLoads,
        maxRememberedIds = maxRememberedIds,
        monotonicMs = now,
        onRetired = { (it as? SearchMessageConversationLoad)?.answer(null) },
    )

    @Test
    fun searchMessageLoadIsTakenOnceAndALateCallbackIsRejected() {
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering()
        val load = searchLoad(answers)
        assertTrue(registry.register(11, load))
        assertFalse(registry.cancelChat(11))
        assertTrue(registry.take(11) === load)
        assertNull(registry.take(11))
        assertFalse(registry.register(11, searchLoad(answers)))
        assertEquals(ConversationLoadKind.SEARCH_MESSAGE, load.kind)
        assertTrue(answers.isEmpty())
    }

    @Test
    fun searchMessageLoadAnswersUnavailableExactlyOnceOnExpiry() {
        var now = 0L
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering(now = { now })
        assertTrue(registry.register(1, searchLoad(answers)))
        now = 100
        registry.sweepExpired()
        registry.sweepExpired()
        assertNull(registry.take(1))
        assertEquals(listOf<Map<String, Any>?>(null), answers)
    }

    @Test
    fun clearAndPeerRemovalHoldSearchMessageLoadsUntilTheDaemonAnswers() {
        var now = 0L
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering(now = { now })
        val gone = searchLoad(answers, "gone")
        val kept = searchLoad(answers, "kept")
        assertTrue(registry.register(1, gone))
        assertTrue(registry.register(2, kept))
        assertTrue(registry.register(3, chat("gone")))
        assertTrue(registry.register(4, folder("gone")))
        assertTrue(registry.register(5, dmTopicState("gone")))
        registry.removePeer("gone")
        assertEquals(2, registry.activeSize())
        assertTrue(answers.isEmpty())
        assertTrue(registry.register(6, chat("kept")))
        assertTrue(registry.register(7, folder("kept")))
        assertTrue(registry.register(8, dmTopicState("kept")))
        registry.clearActive()
        registry.clearActive()
        assertEquals(2, registry.activeSize())
        assertTrue(answers.isEmpty())
        for (id in 3L..8L) assertNull(registry.take(id))
        // The daemon's later answer takes the held load once; the other expires once.
        assertTrue(registry.take(1) === gone)
        assertNull(registry.take(1))
        assertTrue(gone.answer(null))
        assertFalse(gone.answer(emptyMap()))
        now = 99
        registry.sweepExpired()
        assertEquals(1, answers.size)
        now = 100
        registry.sweepExpired()
        registry.sweepExpired()
        assertNull(registry.take(2))
        assertEquals(listOf<Map<String, Any>?>(null, null), answers)
    }

    @Test
    fun heldSearchMessageLoadsStillCountAgainstTheStartCap() {
        var now = 0L
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering(maxActiveLoads = 2, now = { now })
        assertTrue(registry.register(1, searchLoad(answers)))
        assertTrue(registry.register(2, searchLoad(answers)))
        registry.clearActive()
        registry.removePeer("peer")
        assertFalse(registry.canStart())
        assertFalse(registry.register(3, chat()))
        assertTrue(answers.isEmpty())
        now = 100
        assertTrue(registry.canStart())
        assertEquals(listOf<Map<String, Any>?>(null, null), answers)
    }

    @Test
    fun heldSearchMessageLoadCompletedAfterRetirementIsUnavailable() {
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering()
        val load = searchLoad(answers)
        assertTrue(registry.register(9, load))
        registry.clearActive()
        registry.removePeer("peer")
        assertTrue(answers.isEmpty())
        val taken = registry.take(9) as SearchMessageConversationLoad
        // The retirement advanced the search epoch from the load's 0 to 1.
        val retired = SearchMessageLoadFacts(true, true, true, 1L, false)
        var projected = false
        SearchMessageLoadPolicy.dispatch(taken, "acc", "c".repeat(40), retired, listOf("m".repeat(40)),
            onProject = { projected = true; taken.answer(mapOf("items" to listOf<Any>())) },
            onUnavailable = { taken.answer(null) })
        assertFalse(projected)
        assertEquals(listOf<Map<String, Any>?>(null), answers)
        val current = SearchMessageLoadFacts(true, true, true, 0L, false)
        assertEquals(0, SearchMessageLoadPolicy.complete(taken, "acc", "c".repeat(40), current, listOf("m".repeat(40))))
    }

    @Test
    fun searchMessageLoadIsAnsweredWhenAnIdIsDuplicatedOrTheRegistryIsExhausted() {
        val answers = mutableListOf<Map<String, Any>?>()
        val registry = retiredAnswering(maxRememberedIds = 2)
        assertTrue(registry.register(5, searchLoad(answers)))
        assertFalse(registry.register(5, chat()))
        assertEquals(1, answers.size)

        answers.clear()
        assertTrue(registry.register(6, searchLoad(answers)))
        assertFalse(registry.register(7, chat()))
        assertEquals(listOf<Map<String, Any>?>(null), answers)
        assertNull(registry.take(6))
    }
}
