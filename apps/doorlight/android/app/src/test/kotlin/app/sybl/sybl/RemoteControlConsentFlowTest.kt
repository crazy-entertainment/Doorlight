package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

private fun source(revision: Long = 1) = AndroidRemoteControlSourceIdentity(
    "call", revision, 100, 200, 100, 200, 0, 0, 100, 200, 0,
)

private fun binding(
    call: String = "call",
    account: String = "acct",
    device: String = "device",
    revision: Long = 1,
) = AndroidRemoteControlBinding(
    call, account, "controller", device, source(revision).copy(callId = call),
)

class RemoteControlConsentFlowTest {
    private fun request(
        binding: AndroidRemoteControlBinding = binding(),
        generation: Long = 1,
        caps: Int = 1,
    ) = RemoteControlConsentRequest(binding, "me", caps, caps, generation, false, "#fff")

    private class Harness {
        val lock = Any()
        var authority = true
        var lease = false
        var source: AndroidRemoteControlSourceIdentity? = null
        var service = true
        var active = false
        var refuseShow = false
        var onActivated: () -> Unit = {}
        var onActivate: () -> Unit = {}
        var dialog: Long? = null
        val revalidated = ArrayList<AndroidRemoteControlBinding>()
        val verifications = ArrayList<(Boolean) -> Unit>()
        val shown = ArrayList<Long>()
        val hidden = ArrayList<Long>()
        val denies = ArrayList<Pair<String, String>>()
        val timeouts = ArrayList<Pair<Long, () -> Unit>>()
        val activations = ArrayList<RemoteControlConsentRequest>()
        val activatedCalls = ArrayList<RemoteControlConsentRequest>()
        val states = ArrayList<Triple<Long, String, String>>()

        val flow = RemoteControlConsentFlow(
            lock = lock,
            authorityCurrent = { authority },
            leaseCurrent = { lease },
            currentSource = { source },
            serviceAttached = { service },
            sessionActive = { active },
            revalidate = { binding, done ->
                revalidated += binding
                verifications += done
            },
            showConsent = {
                if (refuseShow || dialog != null) {
                    false
                } else {
                    dialog = it.generation
                    shown += it.generation
                    true
                }
            },
            hideConsent = {
                hidden += it
                if (dialog == it) dialog = null
            },
            sendDeny = { call, reason -> denies += call to reason },
            scheduleTimeout = { generation, block -> timeouts += generation to block },
            activate = { activations += it; onActivate() },
            activated = { activatedCalls += it; onActivated() },
            emitState = { r, state, reason -> states += Triple(r.generation, state, reason) },
        )

        fun ready(binding: AndroidRemoteControlBinding = binding()) {
            source = binding.source
        }
    }

    private fun Harness.assertNothingActivated() {
        assertTrue(activations.isEmpty())
        assertTrue(activatedCalls.isEmpty())
    }

    /** m: after any exit the host accepts a fresh request. */
    private fun Harness.assertAcceptsFresh() {
        authority = true
        service = true
        active = false
        refuseShow = false
        val fresh = request(binding(call = "fresh", revision = 9), generation = 900)
        source = fresh.binding.source
        val before = shown.size
        flow.request(fresh)
        assertEquals(before + 1, shown.size)
        assertEquals(900L, flow.current()?.generation)
        assertTrue(denies.none { it.first == "fresh" })
        flow.deny(900)
    }

    @Test
    fun `a cold request shows consent once and schedules the timeout without a lease`() {
        val h = Harness().apply { ready() }
        assertFalse(h.lease)
        h.flow.request(request())
        h.flow.request(request())
        assertEquals(listOf(1L), h.shown)
        assertEquals(1, h.timeouts.size)
        assertTrue(h.denies.isEmpty())
        assertEquals(1L, h.flow.current()?.generation)
    }

    @Test
    fun `allow revalidates the exact binding and activates once on success`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1)
        assertEquals(listOf(binding()), h.revalidated)
        assertTrue(h.activations.isEmpty())
        h.lease = true
        h.verifications.single()(true)
        assertEquals(1, h.activations.size)
        assertEquals(1, h.activatedCalls.size)
        assertNull(h.flow.current())
        h.verifications.single()(true)
        assertEquals(1, h.activations.size)
        h.assertAcceptsFresh()
    }

    @Test
    fun `persistent allow is rejected and revalidation failure denies`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1, persistDevice = true)
        assertTrue(h.revalidated.isEmpty())
        assertEquals(1L, h.flow.current()?.generation)
        h.flow.allow(1)
        h.verifications.single()(false)
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertEquals(listOf(1L), h.hidden)
        assertNull(h.flow.current())
        h.assertNothingActivated()
        h.assertAcceptsFresh()
    }

    @Test
    fun `deny sends deny and clears pending`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.deny(1)
        assertEquals(listOf("call" to "user"), h.denies)
        assertNull(h.flow.current())
        h.flow.deny(1)
        assertEquals(1, h.denies.size)
        h.assertAcceptsFresh()
    }

    @Test
    fun `timeout denies hides and clears pending`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.timeouts.single().second()
        assertEquals(listOf("call" to "timeout"), h.denies)
        assertEquals(listOf(1L), h.hidden)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `source change while displayed blocks activation`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1)
        h.source = source(revision = 2)
        h.lease = true
        h.verifications.single()(true)
        h.assertNothingActivated()
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `account or call replaced while displayed blocks activation`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1)
        h.authority = false
        h.lease = true
        h.verifications.single()(true)
        h.assertNothingActivated()
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `late verification after deny timeout stop or replacement changes nothing`() {
        val h = Harness().apply { ready() }
        h.lease = true

        h.flow.request(request(generation = 1))
        h.flow.allow(1)
        h.flow.deny(1)
        h.verifications.last()(true)

        h.flow.request(request(generation = 2))
        h.flow.allow(2)
        h.timeouts.last().second()
        h.verifications.last()(true)

        h.flow.request(request(generation = 3))
        h.flow.allow(3)
        assertTrue(h.flow.stop("local"))
        h.verifications.last()(true)
        h.assertNothingActivated()

        // Same identifiers, newer object: the old result must not touch it.
        h.flow.request(request(generation = 4))
        h.flow.allow(4)
        val stale = h.verifications.last()
        h.flow.deny(4)
        h.flow.request(request(generation = 5))
        val denies = h.denies.size
        stale(true)
        h.assertNothingActivated()
        assertEquals(denies, h.denies.size)
        assertEquals(5L, h.flow.current()?.generation)
        h.flow.deny(5)
        h.assertAcceptsFresh()
    }

    @Test
    fun `stop while verification is pending prevents activation`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1)
        assertTrue(h.flow.stop("call-ended"))
        assertEquals(listOf("call" to "user"), h.denies)
        h.lease = true
        h.verifications.single()(true)
        h.assertNothingActivated()
        assertFalse(h.flow.stop("again"))
        h.assertAcceptsFresh()
    }

    @Test
    fun `service detached before or during consent denies and clears pending`() {
        val before = Harness().apply { ready(); service = false }
        before.flow.request(request())
        assertEquals(listOf("call" to "unsupported"), before.denies)
        assertTrue(before.shown.isEmpty())
        assertNull(before.flow.current())
        before.assertAcceptsFresh()

        val during = Harness().apply { ready() }
        during.flow.request(request())
        during.flow.allow(1)
        during.service = false
        during.lease = true
        during.verifications.single()(true)
        during.assertNothingActivated()
        assertEquals(listOf("call" to "user"), during.denies)
        assertEquals(listOf(Triple(1L, "denied", "user")), during.states)
        assertNull(during.flow.current())
        during.assertAcceptsFresh()

        val stopped = Harness().apply { ready() }
        stopped.flow.request(request())
        stopped.service = false
        assertTrue(stopped.flow.stop("accessibility-disabled"))
        assertEquals(listOf("call" to "user"), stopped.denies)
        stopped.assertAcceptsFresh()
    }

    @Test
    fun `lease expired between verification and activation blocks activation`() {
        val h = Harness().apply { ready() }
        h.flow.request(request())
        h.flow.allow(1)
        h.lease = false
        h.verifications.single()(true)
        h.assertNothingActivated()
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `a different binding is busy and an identical repeat is ignored`() {
        val h = Harness().apply { ready() }
        h.flow.request(request(generation = 1))
        h.flow.request(request(generation = 2))
        assertTrue(h.denies.isEmpty())
        val other = binding(device = "other")
        h.flow.request(request(binding = other, generation = 3))
        assertEquals(listOf("call" to "busy"), h.denies)
        assertEquals(1L, h.flow.current()?.generation)
        assertEquals(listOf(1L), h.shown)
        assertEquals(1, h.timeouts.size)
        h.flow.deny(1)
        h.assertAcceptsFresh()
    }

    @Test
    fun `an active session makes new requests busy`() {
        val h = Harness().apply { ready(); active = true }
        h.flow.request(request())
        assertEquals(listOf("call" to "busy"), h.denies)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `consent that refuses to show denies unsupported and clears pending`() {
        val h = Harness().apply { ready(); refuseShow = true }
        h.flow.request(request())
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertNull(h.flow.current())
        assertTrue(h.timeouts.isEmpty())
        h.assertAcceptsFresh()
    }

    @Test
    fun `a request whose source is not current is never displayed`() {
        val h = Harness().apply { source = source(revision = 5) }
        h.flow.request(request())
        assertTrue(h.shown.isEmpty())
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `dialog is hidden once on activation even if the session ends before activated runs`() {
        val h = Harness().apply { ready() }
        h.lease = true
        h.flow.request(request())
        h.flow.allow(1)
        // The session is revoked (call end) inside activation, before the completion step.
        h.onActivate = {
            h.authority = false
            h.active = false
            assertFalse(h.flow.stop("call-ended"))
        }
        h.onActivated = { assertEquals(listOf(1L), h.hidden) }
        h.verifications.single()(true)
        assertEquals(1, h.activations.size)
        assertEquals(1, h.activatedCalls.size)
        assertEquals(listOf(1L), h.hidden)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
        assertEquals(listOf(1L, 900L), h.shown)
    }

    @Test
    fun `failed verification wins over a lost service`() {
        val h = Harness().apply { ready() }
        h.lease = true
        h.flow.request(request())
        h.flow.allow(1)
        h.service = false
        h.verifications.single()(false)
        h.assertNothingActivated()
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `allow for a stale generation revalidates nothing and leaves the pending request`() {
        val h = Harness().apply { ready() }
        h.lease = true
        h.flow.request(request(generation = 2))
        h.flow.allow(1)
        assertTrue(h.revalidated.isEmpty())
        h.assertNothingActivated()
        assertEquals(2L, h.flow.current()?.generation)
        assertTrue(h.denies.isEmpty())
        assertTrue(h.hidden.isEmpty())
    }

    @Test
    fun `a false verification denies even when lease authority and source are current`() {
        val h = Harness().apply { ready() }
        h.lease = true
        h.flow.request(request())
        h.flow.allow(1)
        h.verifications.single()(false)
        h.assertNothingActivated()
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertEquals(listOf(1L), h.hidden)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }

    @Test
    fun `a timeout for an older generation leaves a newer pending request alone`() {
        val h = Harness().apply { ready() }
        h.flow.request(request(generation = 1))
        val stale = h.timeouts.single().second
        h.flow.deny(1)
        h.flow.request(request(generation = 2))
        val denies = h.denies.size
        stale()
        assertEquals(2L, h.flow.current()?.generation)
        assertEquals(denies, h.denies.size)
        assertEquals(listOf(1L), h.hidden)
        h.flow.deny(2)
        h.assertAcceptsFresh()
    }

    @Test
    fun `an active session at allow completion blocks activation`() {
        val h = Harness().apply { ready() }
        h.lease = true
        h.flow.request(request())
        h.flow.allow(1)
        h.active = true
        h.verifications.single()(true)
        h.assertNothingActivated()
        assertEquals(listOf("call" to "unsupported"), h.denies)
        assertEquals(listOf(1L), h.hidden)
        assertNull(h.flow.current())
        h.assertAcceptsFresh()
    }
}
