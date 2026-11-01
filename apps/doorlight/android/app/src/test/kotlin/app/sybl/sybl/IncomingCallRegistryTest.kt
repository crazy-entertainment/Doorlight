package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class IncomingCallRegistryTest {
    @Test
    fun unansweredRingRemovalReleasesWakeOwnershipAfterGrace() {
        lateinit var registry: IncomingCallRegistry
        var keepAwake = false
        var reconciliations = 0
        registry = IncomingCallRegistry {
            reconciliations++
            keepAwake = BackgroundWakeLifetime.decide(
                nowMs = 100_000L, pushEnabled = true, appVisible = false,
                accountEnabled = true, callActive = registry.snapshot().isNotEmpty(),
                taskRemoved = false, backgroundAtMs = 0L,
                messagePushAtMs = null, callPushAtMs = 0L,
            ).keepAccountActive
        }
        registry.put("ring", "account", "peer", emptyList())
        assertEquals(true, keepAwake)
        registry.put("other-ring", "account", "other-peer", emptyList())
        registry.remove("ring")
        assertEquals(true, keepAwake)
        registry.remove("other-ring")
        assertEquals(false, keepAwake)
        registry.remove("already-gone")
        assertEquals(4, reconciliations)
    }

    @Test
    fun pendingRingsRemainCallScopedAndTerminalRemovalPreventsReplay() {
        val registry = IncomingCallRegistry()
        registry.put("audio", "old-account", "peer", listOf(mapOf("MEDIA_TYPE" to "audio")))
        registry.put("video", "active-account", "peer", listOf(mapOf("MEDIA_TYPE" to "video")))

        registry.remove("audio")
        val replay = registry.snapshot()

        assertNull(registry["audio"])
        assertEquals(setOf("video"), replay.keys)
        assertEquals("active-account", replay["video"]?.accountId)
        assertEquals("video", replay["video"]?.offer?.single()?.get("MEDIA_TYPE"))
    }
}
