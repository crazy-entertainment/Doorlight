package app.sybl.sybl

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeoutException
import org.junit.Assert.*
import org.junit.Test

class NativeTransactionCompletionTest {
    @Test fun failedPlacementPreservesCrossedWinnerAndRetainedLegs() {
        for (boundary in listOf("winner", "leg", "ring", "different-peer")) {
            val owner = CountDownLatch(1)
            var reservation: String? = if (boundary == "different-peer") "other" else "peer"
            withOutgoingPlacementCompletion(owner, Any(), { owner }, {
                if (canReleaseCallReservation(
                        reservation, "peer", false,
                        if (boundary == "winner") "incoming-current" else null,
                        boundary == "leg", boundary == "ring",
                    )) reservation = null
            }) { false }
            assertNotNull(boundary, reservation)
        }
        assertTrue(canReleaseCallReservation("peer", "peer", false, null, false, false))
        assertFalse(canReleaseCallReservation("peer", "peer", true, null, false, false))
    }

    @Test fun recorderRejectionRetiresPlacementBeforeAnotherAttempt() {
        val lock = Any()
        val owner = CountDownLatch(1)
        var current: CountDownLatch? = owner
        var placing = true
        var dialed = false
        val result = withOutgoingPlacementCompletion(owner, lock, { current }, {
            assertTrue(Thread.holdsLock(lock))
            placing = false
            current = null
        }) {
            val recorderReleased = false
            if (!recorderReleased) return@withOutgoingPlacementCompletion false
            dialed = true
            true
        }
        assertFalse(result)
        assertFalse(dialed)
        assertFalse(placing)
        assertNull(current)
        assertEquals(0L, owner.count)
        val next = CountDownLatch(1)
        current = next
        assertTrue(withOutgoingPlacementCompletion(next, lock, { current }, { current = null }) { true })
        assertEquals(0L, next.count)
    }

    @Test fun exceptionalRecorderFailureAlsoRetiresAndWakesWaiters() {
        val owner = CountDownLatch(1)
        val timeout = TimeoutException("synthetic recorder timeout")
        var retired = false
        try {
            withOutgoingPlacementCompletion(owner, Any(), { owner }, { retired = true }) {
                throw timeout
            }
            fail("Expected timeout")
        } catch (actual: TimeoutException) {
            assertSame(timeout, actual)
        }
        assertTrue(retired)
        assertEquals(0L, owner.count)
    }

    @Test fun retiredPlacementCannotClearReplacementOwner() {
        val old = CountDownLatch(1)
        val replacement = CountDownLatch(1)
        var current = old
        var cleanupCalls = 0
        withOutgoingPlacementCompletion(old, Any(), { current }, { cleanupCalls++ }) {
            current = replacement
        }
        assertSame(replacement, current)
        assertEquals(0, cleanupCalls)
        assertEquals(0L, old.count)
        assertEquals(1L, replacement.count)
    }

    @Test fun cleanupFailureStillWakesPlacementWaiters() {
        val owner = CountDownLatch(1)
        try {
            withOutgoingPlacementCompletion(owner, Any(), { owner }, { error("cleanup") }) { true }
            fail("Expected cleanup error")
        } catch (_: IllegalStateException) { }
        assertEquals(0L, owner.count)
    }

    @Test fun offlineRestorePublishesExistingContactsOnlyAfterBothBarriersRetire() {
        var committing = true
        var pending = true
        val events = mutableListOf<String>()
        var visibleContacts = emptyList<String>()
        val result = completeRestoreRoutingPublication(
            retireBarrier = { committing = false; events.add("retire") },
            publish = {
                assertFalse(committing)
                assertFalse(pending)
                visibleContacts = listOf("existing-peer")
                events.add("publish")
            },
        ) {
            assertTrue(committing)
            assertTrue(pending)
            events.add("commit-privacy-offline")
            pending = false
            mapOf("status" to "ok", "enabled" to false)
        }
        assertEquals(false, result["enabled"])
        assertEquals(listOf("existing-peer"), visibleContacts)
        assertEquals(listOf("commit-privacy-offline", "retire", "publish"), events)
    }

    @Test fun failedRestoreRetiresBusyBarrierWithoutPublishingOrRemovingRecoveryBarrier() {
        var committing = true
        val pending = true
        var published = false
        val result = completeRestoreRoutingPublication(
            retireBarrier = { committing = false },
            publish = { published = true },
        ) { mapOf("status" to "error") }
        assertEquals("error", result["status"])
        assertFalse(committing)
        assertTrue(pending)
        assertFalse(published)
    }

    @Test fun throwingRestoreDoesNotPublish() {
        var retired = false
        var published = false
        val failure = IllegalStateException("journal failure")
        try {
            completeRestoreRoutingPublication(
                retireBarrier = { retired = true },
                publish = { published = true },
            ) { throw failure }
            fail("Expected restore failure")
        } catch (actual: IllegalStateException) {
            assertSame(failure, actual)
        }
        assertTrue(retired)
        assertFalse(published)
    }
}
