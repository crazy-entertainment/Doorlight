package app.sybl.sybl

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.junit.Assert.*
import org.junit.Test

class WakeRegistrationPersistenceTest {
    private class Preferences {
        val values = mutableMapOf<String, String>()
        var succeeds = true
        var commits = 0
        val native = Proxy.newProxyInstance(SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java)) { _, method, arguments ->
            when (method.name) {
                "getString" -> values[arguments!![0]] ?: arguments[1]
                "edit" -> editor()
                else -> error("Unexpected preference operation ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val staged = mutableMapOf<String, String?>()
            lateinit var editor: SharedPreferences.Editor
            editor = Proxy.newProxyInstance(SharedPreferences.Editor::class.java.classLoader,
                arrayOf(SharedPreferences.Editor::class.java)) { _, method, arguments ->
                when (method.name) {
                    "putString" -> { staged[arguments!![0] as String] = arguments[1] as String; editor }
                    "remove" -> { staged[arguments!![0] as String] = null; editor }
                    "apply", "commit" -> {
                        // SharedPreferences changes its process map even when
                        // the synchronous disk write subsequently fails.
                        for ((key, value) in staged) if (value == null) values.remove(key) else values[key] = value
                        if (method.name == "commit") { commits += 1; succeeds } else null
                    }
                    else -> error("Unexpected editor operation ${method.name}")
                }
            } as SharedPreferences.Editor
            return editor
        }
    }

    @Test fun `relay PUT requires acknowledged secret persistence including after a failed save`() {
        val preferences = Preferences()
        val requests = mutableListOf<WakeRelayRequest>()
        var random = 0
        val registration = WakeRegistration(SharedPreferencesWakeRegistrationStore(preferences.native),
            { requests += it; true }, MemoryWakeDeletionJournal(), { size -> ByteArray(size) { (++random).toByte() } })
        preferences.succeeds = false
        assertTrue(runCatching { registration.enable("https://wake.example", TOKEN) }.isFailure)
        assertTrue(requests.isEmpty())
        assertEquals(1, preferences.commits)
        preferences.succeeds = true
        assertNotNull(registration.enable("https://wake.example", TOKEN))
        assertEquals(2, preferences.commits)
        assertEquals(1, requests.size)
    }

    @Test fun `failed local clear retains the exact deletion credential and does not claim completion`() {
        val preferences = Preferences()
        val store = SharedPreferencesWakeRegistrationStore(preferences.native)
        val capability = WakeCapability("A".repeat(43), "B".repeat(43))
        store.save(capability)
        val requests = mutableListOf<WakeRelayRequest>()
        val registration = WakeRegistration(store, { requests += it; true }, MemoryWakeDeletionJournal())
        preferences.succeeds = false
        assertTrue(runCatching { registration.disable("https://wake.example") }.isFailure)
        assertEquals(capability, store.load())
        preferences.succeeds = true
        assertTrue(registration.disable("https://wake.example"))
        assertEquals(2, requests.size)
        assertTrue(requests.all { it.bearer == capability.secret && it.url.endsWith(capability.handle) })
        assertNull(store.load())
    }

    @Test fun `partial or corrupt saved credentials cannot prove remote deletion or mint a replacement`() {
        val invalid = listOf(
            mapOf("wakeHandle" to "A".repeat(43)),
            mapOf("wakeSecret" to "B".repeat(43)),
            mapOf("wakeHandle" to "invalid", "wakeSecret" to "B".repeat(43)),
            mapOf("wakeHandle" to "A".repeat(43), "wakeSecret" to "A".repeat(43)),
        )
        for (values in invalid) {
            val preferences = Preferences()
            preferences.values.putAll(values)
            val requests = mutableListOf<WakeRelayRequest>()
            val registration = WakeRegistration(SharedPreferencesWakeRegistrationStore(preferences.native),
                { requests += it; true }, MemoryWakeDeletionJournal())
            assertTrue("Corrupt credentials are not absent: $values",
                runCatching { registration.disable("https://wake.example") }.isFailure)
            assertTrue(runCatching { registration.enable("https://wake.example", TOKEN) }.isFailure)
            assertTrue(requests.isEmpty())
            assertEquals(values, preferences.values)
        }
    }

    @Test fun `a store with neither credential key is absent and permits fresh registration`() {
        val preferences = Preferences()
        val requests = mutableListOf<WakeRelayRequest>()
        var random = 0
        val registration = WakeRegistration(SharedPreferencesWakeRegistrationStore(preferences.native),
            { requests += it; true }, MemoryWakeDeletionJournal(), { size -> ByteArray(size) { (++random).toByte() } })
        assertTrue(registration.disable("https://wake.example"))
        assertTrue(requests.isEmpty())
        assertNotNull(registration.enable("https://wake.example", TOKEN))
        assertEquals(listOf("PUT"), requests.map { it.method })
    }

    private companion object { const val TOKEN = "synthetic-token-1234567890" }
}
