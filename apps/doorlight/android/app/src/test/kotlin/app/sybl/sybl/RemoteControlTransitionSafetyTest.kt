package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlTransitionSafetyTest {
    @Test
    fun `screen authority is announced when consent is reserved`() {
        val source = File(
            "src/main/kotlin/app/sybl/sybl/JamiCore.kt",
        ).readText()
        val reserve = source.substringAfter("fun reserveScreenConsent(")
            .substringBefore("fun cancelScreenConsent")
        assertTrue(reserve.contains("sourceAnnouncement(myJamiId(), epoch, \"screen\")"))
        assertTrue(reserve.contains("sendCallMessage(expectedCallId, it)"))

        val activation = source.substringAfter("private fun activateRemoteControlSource")
            .substringBefore("private fun retireRemoteControlSource")
        assertTrue(activation.contains("remoteControlSourceRevision = attempt.epoch"))
    }

    @Test
    fun `granted control has no Syb-L surface denylist`() {
        val source = File(
            "src/main/kotlin/app/sybl/sybl/AndroidRemoteControlHost.kt",
        ).readText()
        val handler = source.substringAfter("override fun onAccessibilityEvent")
            .substringBefore("override fun onInterrupt")

        assertFalse(handler.contains("isProtectedSurface"))
        assertTrue(handler.contains("refreshPointerVisibility()"))

        assertFalse(source.contains("hasActiveSurface"))
        assertFalse(source.contains("mayQueueInput"))

        val inputHandler = source.substringAfter("private fun handleInput")
            .substringBefore("private fun handleEnd")
        assertFalse(inputHandler.contains("isProtectedSurface"))

        val consent = source.substringAfter("fun showConsent")
            .substringBefore("fun hideConsent")
        assertFalse(consent.contains("rootInActiveWindow"))

        val pointerVisibility = source.substringAfter("private fun refreshPointerVisibility")
            .substringBefore("internal fun applyEvents")
        assertTrue(pointerVisibility.contains("pointerGeneration > 0"))
        assertFalse(pointerVisibility.contains("rootInActiveWindow"))

        val queue = source.substringAfter("internal fun applyEvents")
            .substringBefore("private fun drainRemoteEvent")
        assertFalse(queue.contains("rootInActiveWindow"))

        val dispatch = source.substringAfter("private fun drainRemoteEvent")
            .substringBefore("private fun applyButton")
        assertFalse(dispatch.contains("rootInActiveWindow"))

        val editable = source.substringAfter("private fun safeEditableNode")
            .substringBefore("private fun mapPoint")
        assertFalse(editable.contains("isPassword"))
        assertFalse(editable.contains("packageAllowed"))

        val textInput = source.substringAfter("private fun applyText")
            .substringBefore("private fun applyGlobal")
        assertFalse(textInput.contains("TYPE_APPLICATION"))
    }

    @Test
    fun `gesture cancellation target cannot cover the controlled screen`() {
        val source = File(
            "src/main/kotlin/app/sybl/sybl/AndroidRemoteControlHost.kt",
        ).readText()
        val target = source.substringAfter("fun showCancellationTarget")
            .substringBefore("fun hideCancellationTarget")

        assertTrue(target.contains("addOverlay(target, Gravity.TOP or Gravity.END, 1, 1)"))
    }

    private fun sourceWithoutComments(name: String): String = File(
        "src/main/kotlin/app/sybl/sybl/$name",
    ).readText()
        .replace(Regex("""/\*[\s\S]*?\*/"""), "")
        .replace(Regex("""//[^\n]*"""), "")

    @Test
    fun `cold request reaches consent without requiring a lease`() {
        val host = sourceWithoutComments("AndroidRemoteControlHost.kt")
        val request = host.substringAfter("private fun handleRequest")
            .substringBefore("fun allowPending")
        assertTrue(request.contains("consent.request("))
        assertFalse(request.contains("LeaseCurrent"))
        assertFalse(request.contains("bindingIsCurrent"))
        assertFalse(request.contains("pendingIsCurrent"))
        assertFalse(host.contains("fun pendingIsCurrent"))
    }

    @Test
    fun `activation requires a lease and production wires the flow by name`() {
        val host = sourceWithoutComments("AndroidRemoteControlHost.kt")
        assertTrue(Regex("""authorityCurrent\s*=\s*\{[^}]*JamiCore\.remoteControlAuthorityCurrent""")
            .containsMatchIn(host))
        assertTrue(Regex("""leaseCurrent\s*=\s*\{[^}]*JamiCore\.remoteControlLeaseCurrent""")
            .containsMatchIn(host))
        assertTrue(Regex("""revalidate\s*=""").containsMatchIn(host))
        assertTrue(host.contains("JamiCore.revalidateRemoteControlBinding"))

        val flow = sourceWithoutComments("RemoteControlConsentFlow.kt")
        val show = flow.substringAfter("fun request(").substringBefore("fun allow(")
        assertFalse(show.contains("leaseCurrent"))
        val activation = flow.substringAfter("private fun finishAllow(")
            .substringBefore("fun deny(")
        assertTrue(activation.contains("leaseCurrent(request.binding)"))
        assertTrue(activation.indexOf("leaseCurrent(") < activation.indexOf("activate("))
    }

    /** Named arguments of the single flow construction, or null if not exactly one call. */
    private fun flowArguments(host: String): Map<String, String>? {
        val marker = "RemoteControlConsentFlow("
        val start = host.indexOf(marker)
        if (start < 0 || host.indexOf(marker, start + 1) >= 0) return null
        var depth = 1
        var end = start + marker.length
        while (end < host.length && depth > 0) {
            when (host[end]) {
                '(', '{', '[' -> depth++
                ')', '}', ']' -> depth--
            }
            end++
        }
        if (depth != 0) return null
        val body = host.substring(start + marker.length, end - 1)
        val arguments = LinkedHashMap<String, String>()
        var name: String? = null
        var valueStart = 0
        var level = 0
        var index = 0
        val head = Regex("""\G\s*(\w+)\s*=(?!=)""")
        while (index <= body.length) {
            if (level == 0 && name == null) {
                val match = head.find(body, index) ?: break
                name = match.groupValues[1]
                index = match.range.last + 1
                valueStart = index
                continue
            }
            val c = if (index < body.length) body[index] else ','
            when (c) {
                '(', '{', '[' -> level++
                ')', '}', ']' -> level--
                ',' -> if (level == 0) {
                    arguments[name!!] = body.substring(valueStart, index)
                        .replace(Regex("""\s+"""), "")
                    name = null
                }
            }
            index++
        }
        return arguments
    }

    private val REVALIDATE = "{binding,verified->JamiCore.submit(DaemonOperation.READ_PEER," +
        "binding.callId,{JamiCore.revalidateRemoteControlBinding(binding)},){verified(it==true)}}"

    /** Wiring faults in the host's single flow construction; empty means correct. */
    private fun wiringFaults(host: String): List<String> {
        val statement = "private val consent = RemoteControlConsentFlow("
        if (host.split(statement).size != 2 ||
            Regex("""\bRemoteControlConsentFlow\b""").findAll(host).count() != 1) {
            return listOf("consent is not the only flow construction")
        }
        val arguments = flowArguments(host) ?: return listOf("not exactly one flow construction")
        val exact = mapOf(
            "authorityCurrent" to "{JamiCore.remoteControlAuthorityCurrent(it)}",
            "leaseCurrent" to "{JamiCore.remoteControlLeaseCurrent(it)}",
            "currentSource" to "{JamiCore.remoteControlSource()?.let(::sourceIdentity)}",
            "serviceAttached" to "{service!=null}",
            "sessionActive" to "{active!=null}",
        )
        val faults = ArrayList<String>()
        for ((name, expected) in exact) {
            if (arguments[name] != expected) faults += "$name is ${arguments[name]}"
        }
        for (name in exact.keys + "revalidate") {
            val value = arguments[name] ?: continue
            if (Regex("""^\{(\w+->)?(true|false|null)\}$""").matches(value)) {
                faults += "$name is constant"
            }
        }
        val revalidate = arguments["revalidate"] ?: ""
        if (revalidate != REVALIDATE) faults += "revalidate is $revalidate"
        return faults
    }

    @Test
    fun `flow construction binds every collaborator to its named source`() {
        val host = sourceWithoutComments("AndroidRemoteControlHost.kt")
        assertEquals(emptyList<String>(), wiringFaults(host))
    }

    @Test
    fun `wrong flow wirings are rejected`() {
        val host = sourceWithoutComments("AndroidRemoteControlHost.kt")
        val leaseBinding = "leaseCurrent = { JamiCore.remoteControlLeaseCurrent(it) },"
        val mutants = mapOf(
            "unused val beside a constant binding" to host.replace(
                leaseBinding,
                "leaseCurrent = { true },",
            ).replace(
                "private val consent =",
                "private val leaseCurrent = { b: Any -> JamiCore.remoteControlLeaseCurrent(b) }\n" +
                    "    private val consent =",
            ),
            "revalidate always verifies" to host.replace("verified(it == true)", "verified(true)"),
            "session never active" to host.replace("sessionActive = { active != null }",
                "sessionActive = { false }"),
            "no current source" to host.replace(
                "currentSource = { JamiCore.remoteControlSource()?.let(::sourceIdentity) }",
                "currentSource = { null }",
            ),
        )
        val submit = "JamiCore.submit("
        val call = "{ JamiCore.revalidateRemoteControlBinding(binding) }"
        val more = mapOf(
            "verified before submit" to host.replace(
                "revalidate = { binding, verified ->",
                "revalidate = { binding, verified ->\n            verified(true)",
            ),
            "dead lambda beside a live verified(true)" to host.replace(
                "{ verified(it == true) }",
                "{ verified(true) }.also { { verified(it == true) } }",
            ),
            "native call replaced by a constant" to host.replace(
                call,
                "$call.let { { true } }",
            ),
            "substituted binding" to host.replace(
                "revalidateRemoteControlBinding(binding)",
                "revalidateRemoteControlBinding(binding.copy(callId = \"other\"))",
            ),
            "typealias construction beside an unused correct decoy" to host.replace(
                "private val consent = RemoteControlConsentFlow(",
                "private val decoy = RemoteControlConsentFlow(",
            ).replace(
                "    private val decoy =",
                "    private val consent = Alias(lock = lock, leaseCurrent = { true })\n" +
                    "    private val decoy =",
            ) + "\ntypealias Alias = RemoteControlConsentFlow\n",
        )
        assertTrue(host.contains(submit))
        for ((label, mutant) in mutants + more) {
            assertTrue("$label must differ from the real file", mutant != host)
            assertFalse("$label must be rejected", wiringFaults(mutant).isEmpty())
        }
        val doubled = host + "\nval again = RemoteControlConsentFlow(lock = lock)"
        assertFalse(wiringFaults(doubled).isEmpty())
    }
}
