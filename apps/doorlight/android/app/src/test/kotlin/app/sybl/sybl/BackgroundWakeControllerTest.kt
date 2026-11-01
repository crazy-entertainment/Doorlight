package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentLinkedDeque
import java.util.concurrent.atomic.AtomicBoolean

class BackgroundWakeControllerTest {
    private class Fixture {
        var saved = SavedBackgroundWake()
        var owner: String? = "account-a"
        var capability: WakeCapability? = null
        var sequence = 0
        var wallNow = 1_000_000L
        var monotonicNow = 0L
        var succeeds = true
        var saveSucceeds = true
        var transportHook: ((WakeRelayRequest) -> Unit)? = null
        var enabledHook: ((Boolean) -> Unit)? = null
        var reconciliations = 0
        val published = mutableListOf<Pair<String, String>>()
        val readied = mutableListOf<Pair<String, String>>()
        val requests = mutableListOf<WakeRelayRequest>()
        val work = ConcurrentLinkedDeque<() -> Unit>()
        val replies = ConcurrentLinkedDeque<() -> Unit>()
        val tokenReplies = ArrayDeque<(String?) -> Unit>()
        val deletionReplies = ArrayDeque<(Boolean) -> Unit>()
        val deletionJournal = MemoryWakeDeletionJournal()
        var controller = createController()
        fun createController() = BackgroundWakeController(
            registration = WakeRegistration(object : WakeRegistrationStore {
                override fun load() = capability
                override fun save(capability: WakeCapability) { this@Fixture.capability = capability }
                override fun clear() { capability = null }
            }, { request -> requests += request; transportHook?.invoke(request); succeeds }, deletionJournal, { size ->
                sequence += 1
                ByteArray(size) { (it + sequence).toByte() }
            }),
            tokens = object : BackgroundWakeTokens {
                override fun setEnabled(enabled: Boolean) { enabledHook?.invoke(enabled) }
                override fun get(callback: (String?) -> Unit) { tokenReplies += callback }
                override fun delete(callback: (Boolean) -> Unit) { deletionReplies += callback }
            },
            load = { saved }, save = { if (saveSucceeds) saved = it; saveSucceeds },
            available = { true }, account = { owner },
            worker = { work += it }, main = { replies += it }, clearDaemonToken = {},
            publish = { account, handle -> published += account to handle },
            ready = { account, handle -> readied += account to handle },
            reconcileLifetime = { reconciliations += 1 },
            wallClockMs = { wallNow }, monotonicMs = { monotonicNow },
        )

        fun drain() {
            while (work.isNotEmpty() || replies.isNotEmpty()) {
                while (work.isNotEmpty()) work.removeFirst()()
                while (replies.isNotEmpty()) replies.removeFirst()()
            }
        }

        fun enable() {
            controller.configure(true, "jami", "https://wake.example") {}
            tokenReplies.removeFirst()(TOKEN)
            drain()
            assertTrue(controller.enabled())
        }
    }

    @Test fun `foreground renewal is daily single flight and failure retry is bounded`() {
        val f = Fixture()
        f.enable()
        f.controller.resumed()
        f.drain()
        assertTrue(f.tokenReplies.isEmpty())
        f.wallNow += 86_400_000L
        f.monotonicNow += 86_400_000L
        repeat(10) { f.controller.resumed() }
        f.drain()
        assertEquals(1, f.tokenReplies.size)
        f.succeeds = false
        f.tokenReplies.removeFirst()(TOKEN)
        f.drain()
        assertFalse(f.controller.enabled())
        repeat(10) { f.controller.resumed() }
        f.drain()
        assertTrue(f.tokenReplies.isEmpty())
        f.monotonicNow += 1_800_000L
        f.controller.resumed()
        f.drain()
        assertEquals(1, f.tokenReplies.size)
        f.succeeds = true
        f.tokenReplies.removeFirst()(TOKEN)
        f.drain()
        assertTrue(f.controller.enabled())
        assertEquals(f.wallNow, f.saved.renewedAtMs)
    }

    @Test fun `expired or legacy renewal does not retain local push authority`() {
        val f = Fixture()
        f.enable()
        f.wallNow += 2_592_000_000L
        assertFalse(f.controller.enabled())
        f.saved = f.saved.copy(renewedAtMs = 0)
        f.controller = f.createController()
        assertFalse(f.controller.enabled())
        f.controller.resumed()
        f.drain()
        assertEquals(1, f.tokenReplies.size)
    }

    @Test fun `old token completion after disable cannot register or publish`() {
        val f = Fixture()
        f.controller.configure(true, "jami", "https://wake.example") {}
        val oldToken = f.tokenReplies.removeFirst()
        f.controller.configure(false, "jami", "https://wake.example") {}
        f.drain()
        oldToken(TOKEN)
        f.drain()
        assertTrue(f.requests.none { it.method == "PUT" })
        assertTrue(f.published.isEmpty())
        assertTrue(f.readied.isEmpty())
        assertFalse(f.saved.registered)
    }

    @Test fun `refresh failure promptly restores lifetime fallback and a later token can recover`() {
        val f = Fixture()
        f.enable()
        val before = f.reconciliations
        f.succeeds = false
        f.controller.refresh("$TOKEN-refreshed")
        f.drain()
        assertFalse(f.controller.enabled())
        assertTrue(f.reconciliations > before)
        f.succeeds = true
        f.controller.refresh("$TOKEN-recovered")
        f.drain()
        assertTrue(f.controller.enabled())
        assertTrue(f.requests.last().body.contains("$TOKEN-recovered"))
    }

    @Test fun `profile ABA never revives a token request from the first profile`() {
        val f = Fixture()
        val results = mutableListOf<Boolean>()
        f.controller.configure(true, "jami", "https://wake.example") { results += it }
        val old = f.tokenReplies.removeFirst()
        f.controller.configure(true, "lan", "https://wake.example") {}
        f.controller.configure(true, "jami", "https://wake.example") {}
        old(TOKEN)
        f.drain()
        assertEquals(listOf(false), results)
        assertTrue(f.requests.none { it.method == "PUT" })
        assertTrue(f.tokenReplies.isEmpty()) // Waits for the old Firebase deletion.
        f.deletionReplies.removeFirst()(true)
        f.tokenReplies.removeFirst()("$TOKEN-new")
        f.drain()
        assertTrue(f.controller.enabled())
        assertEquals(1, f.published.size)
    }

    @Test fun `disable before queued relay work prevents the PUT`() {
        val f = Fixture()
        f.controller.configure(true, "jami", "https://wake.example") {}
        f.tokenReplies.removeFirst()(TOKEN)
        f.controller.configure(false, "jami", "https://wake.example") {}
        f.drain()
        assertTrue(f.requests.none { it.method == "PUT" })
        assertFalse(f.controller.enabled())
    }

    @Test fun `disable during an already submitted PUT deletes it before completion and never publishes`() {
        val f = Fixture()
        var disabled: Boolean? = null
        f.transportHook = { request ->
            if (request.method == "PUT") {
                f.controller.configure(false, "jami", "https://wake.example") { disabled = it }
            }
        }
        f.controller.configure(true, "jami", "https://wake.example") {}
        f.tokenReplies.removeFirst()(TOKEN)
        f.drain()
        assertEquals(listOf("PUT", "DELETE"), f.requests.map { it.method })
        assertNull(disabled)
        f.deletionReplies.removeFirst()(true)
        f.drain()
        assertEquals(true, disabled)
        assertNull(f.capability)
        assertTrue(f.published.isEmpty())
        assertTrue(f.readied.isEmpty())
    }

    @Test fun `failed Firebase cleanup does not report successful withdrawal`() {
        val f = Fixture()
        f.enable()
        var disabled: Boolean? = null
        f.controller.configure(false, "jami", "https://wake.example") { disabled = it }
        f.drain()
        assertFalse(f.controller.enabled())
        assertNull(disabled)
        f.deletionReplies.removeFirst()(false)
        f.drain()
        assertEquals(false, disabled)
        assertNull(f.capability)
    }

    @Test fun `late main completion cannot mark a disabled registration ready`() {
        val f = Fixture()
        f.controller.configure(true, "jami", "https://wake.example") {}
        f.tokenReplies.removeFirst()(TOKEN)
        f.work.removeFirst()()
        assertTrue(f.saved.registered)
        f.controller.configure(false, "jami", "https://wake.example") {}
        f.drain()
        assertFalse(f.saved.registered)
        assertTrue(f.readied.isEmpty())
        assertEquals("", f.controller.handle())
    }

    @Test fun `account ABA retires the old capability and cannot publish the old completion`() {
        val f = Fixture()
        f.enable()
        val oldHandle = f.capability!!.handle
        f.controller.configure(true, "jami", "https://wake.example") {}
        val old = f.tokenReplies.removeFirst()
        f.controller.accountChanged("account-b")
        f.owner = "account-b"
        f.controller.accountChanged("account-a")
        f.owner = "account-a"
        f.drain()
        old("$TOKEN-stale")
        f.drain()
        assertFalse(f.requests.any { it.body.contains("$TOKEN-stale") })
        // Two queued adoption callbacks may ask for a token; only the latest
        // operation can use its result.
        while (f.tokenReplies.isNotEmpty()) f.tokenReplies.removeFirst()("$TOKEN-current")
        f.drain()
        assertTrue(f.controller.enabled())
        assertNotEquals(oldHandle, f.capability!!.handle)
        assertEquals("account-a", f.published.last().first)
    }

    @Test fun `native authorization reduction deletes before asking for a new token`() {
        val f = Fixture()
        f.enable()
        val old = f.capability!!.handle
        f.controller.rotate()
        assertEquals("", f.controller.handle())
        f.drain()
        assertEquals("DELETE", f.requests.last().method)
        assertTrue(f.requests.last().url.endsWith(old))
        assertNull(f.capability)
        assertEquals(1, f.tokenReplies.size)
        f.tokenReplies.removeFirst()(null)
        f.drain()
        assertFalse(f.controller.enabled())
        assertTrue(f.controller.desired())
    }

    @Test fun `failed native retirement survives reconstruction and cannot advertise the old handle`() {
        val f = Fixture()
        f.enable()
        val old = f.capability!!.handle
        f.succeeds = false
        var result: Boolean? = null
        f.controller.rotate { result = it }
        f.drain()
        assertEquals(false, result)
        assertEquals("https://wake.example", f.saved.retiringRelay)
        assertEquals(old, f.capability!!.handle)
        f.controller = f.createController()
        assertEquals("", f.controller.handle())
        f.succeeds = true
        f.controller.refresh("$TOKEN-retry")
        f.drain()
        assertNull(f.saved.retiringRelay)
        assertNotEquals(old, f.capability!!.handle)
        assertTrue(f.controller.enabled())
    }

    @Test fun `late rotation token is ignored after disable and failure does not fabricate deletion`() {
        val f = Fixture()
        f.enable()
        f.controller.rotate()
        f.drain()
        val old = f.tokenReplies.removeFirst()
        f.controller.configure(false, "jami", "https://wake.example") {}
        f.drain()
        val before = f.requests.size
        old("$TOKEN-late")
        f.drain()
        assertEquals(before, f.requests.size)
        assertFalse(f.saved.registered)

        val failed = Fixture()
        failed.enable()
        failed.succeeds = false
        var disabled: Boolean? = null
        failed.controller.configure(false, "jami", "https://wake.example") { disabled = it }
        failed.drain()
        assertEquals(false, disabled)
        assertNotNull(failed.saved.retiringRelay)
        assertNotNull(failed.capability)
    }

    @Test fun `failed policy persistence cannot publish or claim readiness`() {
        val f = Fixture()
        f.saveSucceeds = false
        var result: Boolean? = null
        f.controller.configure(true, "jami", "https://wake.example") { result = it }
        f.drain()
        assertEquals(false, result)
        assertTrue(f.tokenReplies.isEmpty())
        assertTrue(f.requests.isEmpty())
        assertFalse(f.controller.enabled())
    }

    @Test fun `cold wake keeps its scope only when native boot adopts the persisted registered owner`() {
        val f = Fixture()
        f.enable()
        f.owner = null
        f.controller = f.createController()
        val scope = f.controller.scope()
        assertTrue(f.controller.enabled())
        f.controller.accountChanged("account-a")
        f.owner = "account-a"
        assertTrue(f.controller.owns(scope, "account-a"))
        f.controller.accountChanged("account-b")
        f.owner = "account-b"
        assertFalse(f.controller.owns(scope, "account-a"))
    }

    @Test fun `headless token refresh queued behind boot retains the stored account owner`() {
        val f = Fixture()
        f.enable()
        f.owner = null
        f.controller = f.createController()
        f.controller.refresh("$TOKEN-headless")
        f.controller.accountChanged("account-a")
        f.owner = "account-a"
        f.drain()
        assertTrue(f.requests.last().body.contains("$TOKEN-headless"))
        assertTrue(f.controller.enabled())
    }

    @Test fun `retirement persistence failure still attempts known relay deletion and reports failure`() {
        val f = Fixture()
        f.enable()
        val original = f.capability!!
        f.saveSucceeds = false
        var result: Boolean? = null
        f.controller.rotate { result = it }
        f.drain()
        assertEquals(false, result)
        assertFalse(f.controller.enabled())
        assertEquals("DELETE", f.requests.last().method)
        assertTrue(f.requests.last().url.endsWith(original.handle))
        assertEquals(original.secret, f.requests.last().bearer)
    }

    @Test fun `Firebase enable submission cannot finish after a later opt out submission`() {
        val f = Fixture()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val disabling = CountDownLatch(1)
        val autoEnabled = AtomicBoolean(false)
        f.enabledHook = { enabled ->
            if (enabled) { entered.countDown(); check(release.await(5, TimeUnit.SECONDS)) }
            autoEnabled.set(enabled)
        }
        val enabling = Thread { f.controller.configure(true, "jami", "https://wake.example") {} }.apply { isDaemon = true }
        val disablingThread = Thread {
            disabling.countDown()
            f.controller.configure(false, "jami", "https://wake.example") {}
        }.apply { isDaemon = true }
        try {
            enabling.start()
            assertTrue(entered.await(5, TimeUnit.SECONDS))
            disablingThread.start()
            assertTrue(disabling.await(5, TimeUnit.SECONDS))
            val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
            while (disablingThread.state != Thread.State.BLOCKED && disablingThread.isAlive && System.nanoTime() < deadline) {
                Thread.yield()
            }
            assertTrue(disablingThread.state == Thread.State.BLOCKED || !disablingThread.isAlive)
            release.countDown()
            enabling.join(5_000)
            disablingThread.join(5_000)
            assertFalse(enabling.isAlive)
            assertFalse(disablingThread.isAlive)
            assertFalse(autoEnabled.get())
        } finally {
            release.countDown()
            enabling.join(5_000)
            if (disablingThread.state != Thread.State.NEW) disablingThread.join(5_000)
        }
    }

    @Test fun `account adoption deletes its predecessor before Firebase token acquisition`() {
        val f = Fixture()
        f.enable()
        val old = f.capability!!
        f.controller.accountChanged("account-b")
        f.owner = "account-b"
        f.drain()
        assertEquals("DELETE", f.requests.last().method)
        assertEquals(old.secret, f.requests.last().bearer)
        assertNull(f.capability)
        f.tokenReplies.removeFirst()(null)
        f.drain()
        assertFalse(f.controller.enabled())
    }

    @Test fun `account adoption still attempts known deletion when retirement persistence fails`() {
        val f = Fixture()
        f.enable()
        val old = f.capability!!
        f.saveSucceeds = false
        f.controller.accountChanged("account-b")
        f.owner = "account-b"
        f.drain()
        assertEquals("DELETE", f.requests.last().method)
        assertEquals(old.secret, f.requests.last().bearer)
        assertFalse(f.controller.enabled())
    }

    private companion object { const val TOKEN = "synthetic-token-1234567890" }
}
