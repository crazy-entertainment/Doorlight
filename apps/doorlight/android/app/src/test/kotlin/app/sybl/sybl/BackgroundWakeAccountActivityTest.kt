package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class BackgroundWakeAccountActivityTest {
    @Test fun `a new wake policy cannot mistake an unsubmitted command for native acknowledgement`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Pair<String, Boolean>>()
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { owner, active -> calls += owner to active }, {})
        activity.select("account", false)
        activity.request("account", true, Any())
        activity.request("account", true, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(listOf("account" to true), calls)
        assertEquals(true, activity.acknowledgedActive())
    }

    @Test fun `failed native command remains unknown rather than claiming the opposite state`() {
        val work = ArrayDeque<() -> Unit>()
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, _ -> error("synthetic native failure") }, {})
        activity.select("account", false)
        activity.request("account", true, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertNull(activity.acknowledgedActive())
    }

    @Test fun `opposing intent before submission cancels the unused native command`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, active -> calls += active }, {})
        activity.select("account", false)
        activity.request("account", true, Any())
        assertEquals(false, activity.acknowledgedActive())
        activity.request("account", false, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertTrue(calls.isEmpty())
        assertEquals(false, activity.acknowledgedActive())
    }

    @Test fun `intent changed during native command is corrected after its acknowledgement`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        lateinit var activity: BackgroundWakeAccountActivity
        activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, active ->
                calls += active
                if (active) activity.request("account", false, Any())
            }, {})
        activity.select("account", false)
        activity.request("account", true, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(listOf(true, false), calls)
        assertEquals(false, activity.acknowledgedActive())
    }

    @Test fun `account replacement and ABA discard queued commands and late acknowledgements`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Pair<String, Boolean>>()
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { owner, active -> calls += owner to active }, {})
        activity.select("a", false)
        activity.request("a", true, Any())
        activity.select("b", false)
        activity.select("a", false)
        while (work.isNotEmpty()) work.removeFirst()()
        assertTrue(calls.isEmpty())
        assertEquals(false, activity.acknowledgedActive())
        activity.request("a", true, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(listOf("a" to true), calls)
    }

    @Test fun `failure is bounded for one intent and a new intent can retry`() {
        val work = ArrayDeque<() -> Unit>()
        var failure = true
        var calls = 0
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, _ -> calls += 1; if (failure) error("failure") }, {})
        activity.select("account", false)
        val first = Any()
        activity.request("account", true, first)
        while (work.isNotEmpty()) work.removeFirst()()
        repeat(5) { activity.request("account", true, first) }
        assertTrue(work.isEmpty())
        assertEquals(1, calls)
        assertNull(activity.acknowledgedActive())
        failure = false
        activity.request("account", true, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(2, calls)
        assertEquals(true, activity.acknowledgedActive())
    }

    @Test fun `an external visibility transition can retry failed activation without changing wake policy`() {
        val work = ArrayDeque<() -> Unit>()
        var failure = true
        var calls = 0
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, _ -> calls += 1; if (failure) error("failure") }, {})
        activity.select("account", false)
        val policy = Any()
        activity.request("account", true, policy, retryKey = Any())
        while (work.isNotEmpty()) work.removeFirst()()
        failure = false
        activity.request("account", true, policy, retryKey = Any())
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(2, calls)
        assertEquals(true, activity.acknowledgedActive())
    }

    @Test fun `external revival cannot preserve a stale sleep acknowledgement`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        val activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, active -> calls += active }, {})
        activity.select("account", false)
        activity.request("account", true, Any())
        activity.request("account", false, Any())
        // reviveActive has now changed the daemon while the earlier command is queued.
        activity.acknowledge("account", true)
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(listOf(false), calls)
        assertEquals(false, activity.acknowledgedActive())
    }

    @Test fun `external revival after queued command cancellation restores latest sleep intent`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        val policy = Any()
        lateinit var activity: BackgroundWakeAccountActivity
        activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, active -> calls += active }, { activity.request("account", false, policy) })
        activity.select("account", false)
        activity.request("account", true, Any())
        activity.request("account", false, Any())
        while (work.isNotEmpty()) work.removeFirst()()
        activity.acknowledge("account", true)
        while (work.isNotEmpty()) work.removeFirst()()
        assertEquals(listOf(false), calls)
        assertEquals(false, activity.acknowledgedActive())
    }

    @Test fun `external activation reconciles current push intent instead of the previous sleep intent`() {
        val work = ArrayDeque<() -> Unit>()
        val main = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        var currentTarget = false
        val policy = Any()
        lateinit var activity: BackgroundWakeAccountActivity
        activity = BackgroundWakeAccountActivity({ work += it }, { main += it },
            { _, active -> calls += active }, { activity.request("account", currentTarget, policy) })
        activity.select("account", false)
        activity.request("account", false, policy)
        currentTarget = true
        activity.acknowledge("account", true)
        while (main.isNotEmpty()) main.removeFirst()()
        while (work.isNotEmpty()) work.removeFirst()()
        assertTrue(calls.isEmpty())
        assertEquals(true, activity.acknowledgedActive())
    }

    @Test fun `explicit offline intent retires a queued activation before external deactivation`() {
        val work = ArrayDeque<() -> Unit>()
        val calls = mutableListOf<Boolean>()
        val policy = Any()
        lateinit var activity: BackgroundWakeAccountActivity
        activity = BackgroundWakeAccountActivity({ work += it }, { it() },
            { _, active -> calls += active }, { activity.request("account", false, policy) })
        activity.select("account", false)
        activity.request("account", true, policy)
        activity.request("account", false, policy, retryKey = Any())
        activity.acknowledge("account", false)
        while (work.isNotEmpty()) work.removeFirst()()
        assertTrue(calls.isEmpty())
        assertEquals(false, activity.acknowledgedActive())
    }
}
