package app.sybl.sybl

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class DirectorCallbackGuardTest {
    @Test
    fun `callback and diagnostic throwables stay contained`() {
        val failure = AssertionError("callback")
        var observed: Throwable? = null

        guardDirectorCallback(onFailure = { observed = it }) { throw failure }
        guardDirectorCallback(onFailure = { throw LinkageError("diagnostic") }) {
            throw failure
        }

        assertSame(failure, observed)
    }

    @Test
    fun `production default records failures without retaining payloads`() {
        val before = DirectorCallbackFailures.count()

        guardDirectorCallback { throw AssertionError("private callback payload") }

        assertEquals(before + 1, DirectorCallbackFailures.count())
    }

    @Test
    fun `fill callback clears stale and partial output`() {
        val output = mutableListOf("stale")

        guardDirectorFillCallback(clear = output::clear) {
            output += "partial"
            throw AssertionError("callback")
        }

        assertTrue(output.isEmpty())
    }

    @Test
    fun `all owned director overrides use the common guard`() {
        val source = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText()
        val classes = listOf("ConfigCb", "CallCb", "PtVideoCallback", "PresenceCb", "DataCb", "ConvCb")
        var overrideCount = 0
        var fillGuardCount = 0

        classes.forEachIndexed { classIndex, className ->
            val start = source.indexOf("private class $className")
            val end = if (classIndex + 1 < classes.size) {
                source.indexOf("private class ${classes[classIndex + 1]}", start)
            } else {
                source.lastIndexOf("\n}")
            }
            assertTrue("missing $className source section", start >= 0 && end > start)
            val section = source.substring(start, end)
            val overrides = Regex("(?m)^\\s*override fun ").findAll(section).toList()
            overrideCount += overrides.size
            fillGuardCount += Regex("\\bguardDirectorFillCallback\\b").findAll(section).count()

            overrides.forEachIndexed { overrideIndex, match ->
                val next = overrides.getOrNull(overrideIndex + 1)?.range?.first ?: section.length
                val implementation = section.substring(match.range.first, next)
                assertTrue(
                    "$className override is not wholly guarded: ${implementation.lineSequence().first().trim()}",
                    Regex(
                        "(?s)^\\s*override fun .*?(?:=\\s*guardDirector(?:Fill)?Callback|\\{\\s*guardDirector(?:Fill)?Callback)",
                    ).containsMatchIn(implementation),
                )
            }
        }

        assertEquals(51, overrideCount) // Includes device pairing, reactions and private history search.
        assertEquals(3, fillGuardCount)
    }

    private fun accountMessageCallback(source: String): String {
        val start = source.indexOf("override fun incomingAccountMessage")
        assertTrue("missing incomingAccountMessage", start >= 0)
        val end = source.indexOf("override fun composingStatusChanged", start)
        assertTrue(end > start)
        return source.substring(start, end)
            .replace(Regex("/\\*.*?\\*/", RegexOption.DOT_MATCHES_ALL), "")
            .replace(Regex("//[^\n]*"), "")
    }

    private fun assertAccountMessageRouting(source: String) {
        var body = accountMessageCallback(source)
        assertEquals(
            "callback must call the routing function exactly once",
            1,
            Regex("\\brouteAccountMessage\\(").findAll(body).count(),
        )
        for ((param, handler) in listOf("onFull" to "onAccountMessage", "onWakeOnly" to "onWakeOnlyMessage")) {
            val binding = Regex(
                "\\b$param\\s*=\\s*\\{\\s*(\\w+),\\s*(\\w+)\\s*->\\s*JamiCore\\.$handler\\(accountId,\\s*\\1,\\s*\\2\\)\\s*\\}",
            )
            assertEquals("$param must be bound to JamiCore.$handler", 1, binding.findAll(body).count())
            body = body.replace(binding, "")
        }
        for (forbidden in listOf("onAccountMessage(", "onWakeOnlyMessage(", "classifyAccountMessage(", "isTrustedPeer(")) {
            assertFalse("callback calls $forbidden outside the routing bindings", body.contains(forbidden))
        }
    }

    private fun assertRejected(label: String, source: String) {
        val failed = try {
            assertAccountMessageRouting(source)
            false
        } catch (_: AssertionError) {
            true
        }
        assertTrue("$label passed the routing source check", failed)
    }

    @Test
    fun `account message callback reaches handlers only through the routing function`() {
        val source = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText().replace("\r\n", "\n")
        assertAccountMessageRouting(source)
        assertEquals(1, Regex("(?<!fun )onAccountMessage[(]").findAll(source).count())
        assertEquals(1, Regex("(?<!fun )onWakeOnlyMessage[(]").findAll(source).count())

        // The reviewer's two wrong edits, rebuilt in memory from the real source: both must be rejected.
        val call = Regex("(?s)routeAccountMessage\\(.*?\n {16}\\)")
        assertTrue(call.containsMatchIn(source))
        val discarded = source.replace(
            call,
            "classifyAccountMessage(JamiCore.routingSnapshot, from, nativePayloads)\n" +
                "                JamiCore.onAccountMessage(accountId, from, nativePayloads)" +
                " // routeAccountMessage( AccountMessageIngress.FULL WAKE_ONLY",
        )
        assertTrue(discarded != source)
        assertRejected("classify-and-discard with unconditional full handler", discarded)
        val fullArm = "onFull = { f, p -> JamiCore.onAccountMessage(accountId, f, p) }"
        val wakeArm = "onWakeOnly = { f, p -> JamiCore.onWakeOnlyMessage(accountId, f, p) }"
        assertTrue(source.contains(fullArm) && source.contains(wakeArm))
        val swapped = source
            .replace(fullArm, "onFull = { f, p -> JamiCore.onWakeOnlyMessage(accountId, f, p) }")
            .replace(wakeArm, "onWakeOnly = { f, p -> JamiCore.onAccountMessage(accountId, f, p) }")
        assertRejected("swapped handler arms", swapped)
    }

    /** Removes Kotlin comments without treating comment markers inside string literals as comments. */
    private fun stripComments(source: String): String {
        val text = source.replace("\r\n", "\n")
        val out = StringBuilder()
        var i = 0
        while (i < text.length) {
            when {
                text.startsWith("\"\"\"", i) -> {
                    val end = text.indexOf("\"\"\"", i + 3).let { if (it < 0) text.length - 3 else it }
                    out.append(text, i, end + 3)
                    i = end + 3
                }
                text[i] == '"' || text[i] == '\'' -> {
                    val quote = text[i]
                    out.append(quote)
                    i += 1
                    while (i < text.length && text[i] != quote && text[i] != '\n') {
                        if (text[i] == '\\' && i + 1 < text.length) out.append(text[i++])
                        out.append(text[i++])
                    }
                    if (i < text.length && text[i] == quote) out.append(text[i++])
                }
                text.startsWith("//", i) -> while (i < text.length && text[i] != '\n') i += 1
                text.startsWith("/*", i) -> {
                    var depth = 0
                    do {
                        if (text.startsWith("/*", i)) { depth += 1; i += 2 }
                        else if (text.startsWith("*/", i)) { depth -= 1; i += 2 }
                        else i += 1
                    } while (depth > 0 && i < text.length)
                    out.append(' ')
                }
                else -> out.append(text[i++])
            }
        }
        return out.toString()
    }

    private fun between(source: String, start: String, end: String): String {
        val from = source.indexOf(start)
        assertTrue("missing $start", from >= 0)
        val to = source.indexOf(end, from)
        assertTrue("missing $end after $start", to > from)
        return source.substring(from, to)
    }

    private fun normalized(text: String) = text.replace(Regex("\\s+"), " ").trim()

    /** Whole function text (signature through the matching closing brace) of the first `fun name(` in [source]. */
    private fun functionText(source: String, name: String): String {
        val start = source.indexOf("fun $name(")
        assertTrue("missing fun $name", start >= 0)
        var depth = 0
        var i = source.indexOf('(', start)
        do {
            if (source[i] == '(') depth += 1 else if (source[i] == ')') depth -= 1
            i += 1
        } while (depth > 0 && i < source.length)
        i = source.indexOf('{', i)
        val open = i
        depth = 0
        while (i < source.length) {
            when (source[i]) {
                '"' -> {
                    i += 1
                    while (i < source.length && source[i] != '"' && source[i] != '\n') {
                        if (source[i] == '\\') i += 1
                        i += 1
                    }
                }
                '{' -> depth += 1
                '}' -> { depth -= 1; if (depth == 0) return source.substring(start, i + 1) }
            }
            i += 1
        }
        throw AssertionError("unterminated fun $name after $open")
    }

    private fun simpleCalls(body: String, core: String): Set<String> =
        Regex("(?<![.\\w])([A-Za-z_]\\w*)\\(").findAll(body).map { it.groupValues[1] }
            .filter { Regex("\\bfun $it\\(").containsMatchIn(core) }.toSet()

    /** No function reachable by simple name from the search-message code, other than those the ordinary chat
     *  path already calls, may mention a read receipt. */
    private fun assertNoReadThroughHelpers(core: String) {
        val stripped = stripComments(core)
        val swarm = functionText(stripped, "onSwarmLoaded")
        val ordinary = functionText(stripped, "loadChat") + swarm.substringAfter("if (pendingLoad.conversationId != conv")
        val ordinaryNames = simpleCalls(ordinary, stripped)
        val pending = ArrayDeque(listOf("loadSearchMessage", "completeSearchMessage"))
        val seen = HashSet<String>()
        while (pending.isNotEmpty()) {
            val name = pending.removeFirst()
            if (!seen.add(name)) continue
            val body = functionText(stripped, name)
            assertFalse("$name mentions setMessageDisplayed", body.contains("setMessageDisplayed"))
            val searchPart = if (name == "onSwarmLoaded") swarm.substringBefore("if (pendingLoad.conversationId != conv") else body
            simpleCalls(searchPart, stripped).filter { it !in ordinaryNames }.forEach { pending.add(it) }
        }
        assertTrue("helper walk reached the search functions", "completeSearchMessage" in seen)
    }

    private val loadSearchMessageText = """
        fun loadSearchMessage(scope: NativeAccountScope?, peer: String, conversation: String,
                                       messageId: String, reply: (Map<String, Any>?) -> Unit) {
            val epoch = historySearchEpoch.get()
            try {
                worker.execute(DaemonOperation.LOAD_CHAT) {
                    val account = scope?.accountId.orEmpty()
                    val owner = normalizeOwnerKey(peer)
                    if (scope == null) {
                        main.post { reply(null) }
                        return@execute
                    }
                    val load = SearchMessageConversationLoad(
                        account, scope, owner, conversation, messageId, groupConversationId(owner) != null, epoch,
                    ) { value -> main.post { reply(value) } }
                    try {
                        synchronized(loadRegistrationLock) {
                            if (!SearchMessageLoadPolicy.admit(account, owner, conversation, messageId, epoch,
                                    searchMessageFacts(account, scope, owner, conversation),
                                    conversationLoads.canStart())) {
                                load.answer(null)
                                return@synchronized
                            }
                            val loadId = JamiService.loadSybLMessage(account, conversation, messageId)
                            if (loadId == 0L || !conversationLoads.register(loadId, load)) {
                                load.answer(null)
                                return@synchronized
                            }
                            main.postDelayed({ conversationLoads.sweepExpired() },
                                ConversationLoadRegistry.DEFAULT_DEADLINE_MS + 1_000L)
                        }
                    } catch (e: Throwable) {
                        Log.e(TAG, "loadSearchMessage", e)
                        load.answer(null)
                    }
                }
            } catch (_: Throwable) {
                main.post { reply(null) }
            }
        }
    """

    private val completeSearchMessageText = """
        fun completeSearchMessage(load: SearchMessageConversationLoad, acc: String, conv: String,
                                          messages: SwarmMessageVect) {
            try {
                val ids = ArrayList<String>()
                for (i in 0 until minOf(messages.size, 2)) ids.add(messages.get(i).id.orEmpty())
                SearchMessageLoadPolicy.dispatch(
                    load, acc, conv, searchMessageFacts(load.account, load.owner, load.peerId, load.conversationId), ids,
                    onProject = { index ->
                        val item = timelineItem(acc, load.peerId, conv, messages.get(index), myJamiId(), false)
                        load.answer(if (item == null || item.value["daemonId"] != load.messageId) null else mapOf(
                            "accountId" to acc,
                            "peerId" to load.peerId,
                            "conversationId" to conv,
                            "messageId" to load.messageId,
                            "kind" to if (load.group) "group" else "direct",
                            "items" to listOf(item.value),
                        ))
                    },
                    onUnavailable = { load.answer(null) },
                )
            } catch (e: Throwable) {
                Log.e(TAG, "loadSearchMessage completion", e)
                load.answer(null)
            }
        }
    """

    private val swarmSearchBranchText = """
        internal fun onSwarmLoaded(loadId: Long, acc: String, conv: String, messages: SwarmMessageVect) {
            val pendingLoad = synchronized(loadRegistrationLock) {
                conversationLoads.take(loadId)
            } ?: return
            if (pendingLoad is SearchMessageConversationLoad) {
                completeSearchMessage(pendingLoad, acc, conv, messages)
                return
            }
    """

    private val activityBranchText = """
        "loadSearchMessage" -> {
            val account = call.argument<String>("accountId") ?: ""
            JamiCore.loadSearchMessage(JamiCore.captureAccountScope(account),
                call.argument<String>("peerJamiId") ?: "",
                call.argument<String>("conversationId") ?: "",
                call.argument<String>("messageId") ?: "") { result.success(it) }
        }
    """

    private fun assertSearchMessageWiring(activity: String, core: String) {
        val activityStripped = stripComments(activity)
        assertEquals("activity branch text", normalized(activityBranchText),
            normalized(between(activityStripped, "\"loadSearchMessage\" ->", "\"retireHistorySearch\" ->")))
        val coreStripped = stripComments(core)
        assertEquals("loadSearchMessage text", normalized(loadSearchMessageText),
            normalized(functionText(coreStripped, "loadSearchMessage")))
        assertEquals("completeSearchMessage text", normalized(completeSearchMessageText),
            normalized(functionText(coreStripped, "completeSearchMessage")))
        assertEquals("onSwarmLoaded search branch text", normalized(swarmSearchBranchText),
            normalized(between(coreStripped, "internal fun onSwarmLoaded(", "if (pendingLoad.conversationId != conv")))
        assertNoReadThroughHelpers(core)
        val branch = between(stripComments(activity), "\"loadSearchMessage\" ->", "\"retireHistorySearch\" ->")
        val argument = { key: String -> "call\\.argument<String>\\(\"$key\"\\)\\s*\\?:\\s*\"\"" }
        assertTrue(
            "activity branch must pass the four argument keys to the core function",
            Regex(
                "^\\s*\\{\\s*val account = ${argument("accountId")}\\s*" +
                    "JamiCore\\.loadSearchMessage\\(JamiCore\\.captureAccountScope\\(account\\),\\s*" +
                    "${argument("peerJamiId")},\\s*${argument("conversationId")},\\s*${argument("messageId")}\\)" +
                    "\\s*\\{ result\\.success\\(it\\) \\}\\s*\\}\\s*$",
            ).matches(branch.substringAfter("->")),
        )
        val stripped = stripComments(core)
        val entry = between(stripped, "internal fun loadSearchMessage(", "private fun completeSearchMessage(")
        val completion = between(stripped, "private fun completeSearchMessage(", "private fun onHistorySearch(")
        assertEquals(1, Regex("JamiService\\.loadSybLMessage\\(account, conversation, messageId\\)").findAll(entry).count())
        for (forbidden in listOf("setMessageDisplayed", "snippet", "loadConversation")) {
            assertFalse("entry references $forbidden", entry.contains(forbidden))
            assertFalse("completion references $forbidden", completion.contains(forbidden))
        }
        assertEquals(1, Regex("SearchMessageLoadPolicy\\.dispatch\\(").findAll(completion).count())
        assertEquals(1, Regex("\\bonProject = \\{ index ->").findAll(completion).count())
        assertEquals(1, Regex("\\bonUnavailable = \\{ load\\.answer\\(null\\) \\},").findAll(completion).count())
        assertEquals(1, Regex("timelineItem\\(acc, load\\.peerId, conv, messages\\.get\\(index\\), myJamiId\\(\\), false\\)")
            .findAll(completion).count())
        val swarm = between(stripped, "internal fun onSwarmLoaded(", "if (pendingLoad.conversationId != conv")
        assertTrue(
            "onSwarmLoaded must dispatch the kind before any silent return",
            Regex(
                "\\}\\s*\\?:\\s*return\\s*if \\(pendingLoad is SearchMessageConversationLoad\\) \\{\\s*" +
                    "completeSearchMessage\\(pendingLoad, acc, conv, messages\\)\\s*return\\s*\\}\\s*$",
            ).containsMatchIn(swarm),
        )
    }

    private fun assertSearchMessageRejected(label: String, activity: String, core: String) {
        val failed = try {
            assertSearchMessageWiring(activity, core)
            false
        } catch (_: AssertionError) {
            true
        }
        assertTrue("$label passed the search-message source check", failed)
    }

    @Test
    fun `search message load is wired from the channel to the daemon answer`() {
        val activity = File("src/main/kotlin/app/sybl/sybl/MainActivity.kt").readText().replace("\r\n", "\n")
        val core = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText().replace("\r\n", "\n")
        assertSearchMessageWiring(activity, core)

        val branch = "\"loadSearchMessage\" ->"
        assertSearchMessageRejected("missing branch", activity.replace(branch, "\"loadSearchMessageX\" ->"), core)
        assertSearchMessageRejected("dropped key", activity.replace(
            "call.argument<String>(\"messageId\") ?: \"\") { result.success(it) }",
            "\"\") { result.success(it) }"), core)
        assertSearchMessageRejected("wrong daemon call", activity,
            core.replace("JamiService.loadSybLMessage(account, conversation, messageId)",
                "JamiService.loadConversation(account, conversation, messageId, 1L)"))
        assertSearchMessageRejected("read receipt", activity,
            core.replace("val loadId = JamiService.loadSybLMessage(account, conversation, messageId)",
                "val loadId = JamiService.loadSybLMessage(account, conversation, messageId)\n" +
                    "JamiService.setMessageDisplayed(account, conversation, messageId, 3)"))
        assertSearchMessageRejected("swapped handler", activity,
            core.replace("onUnavailable = { load.answer(null) },", "onUnavailable = { load.answer(emptyMap()) },"))
        assertSearchMessageRejected("dispatch after silent return", activity,
            core.replace("if (pendingLoad is SearchMessageConversationLoad) {",
                "if (pendingLoad.conversationId != conv) return\n        if (pendingLoad is SearchMessageConversationLoad) {"))
        val load = "val loadId = JamiService.loadSybLMessage(account, conversation, messageId)"
        val helperRead = core.replace(load, "$load\n                            markShown(account, conversation, messageId)")
            .replace("    private fun completeSearchMessage(",
                "    private fun markShown(a: String, c: String, m: String) { JamiService.setMessageDisplayed(a, c, m, 3) }\n\n" +
                    "    private fun completeSearchMessage(")
        assertTrue(helperRead != core)
        assertSearchMessageRejected("read receipt through a helper", activity, helperRead)
        val helperOnly = try { assertNoReadThroughHelpers(helperRead); false } catch (_: AssertionError) { true }
        assertTrue("helper rule alone missed the helper read receipt", helperOnly)
        val deadCode = core.replace(load,
            "val loadId = JamiService.loadSwarmUntil(account, conversation, messageId, \"\", 1L)\n" +
                "                            if (false) JamiService.loadSybLMessage(account, conversation, messageId)")
        assertTrue(deadCode != core)
        assertSearchMessageRejected("dead loadSybLMessage beside a live ordinary load", activity, deadCode)
        val ordinaryLoad = core.replace(load, "val loadId = JamiService.loadConversation(account, conversation, messageId, 1L)\n" +
            "                            if (false) JamiService.loadSybLMessage(account, conversation, messageId)")
        assertTrue(ordinaryLoad != core)
        assertSearchMessageRejected("dead loadSybLMessage beside loadConversation", activity, ordinaryLoad)
        val alwaysNull = core.replace("load.answer(if (item == null || item.value[\"daemonId\"] != load.messageId) null else mapOf(",
            "load.answer(if (true) null else mapOf(")
        assertTrue(alwaysNull != core)
        assertSearchMessageRejected("onProject always answers null", activity, alwaysNull)
        val constantIds = core.replace("ids.add(messages.get(i).id.orEmpty())", "ids.add(load.messageId)")
        assertTrue(constantIds != core)
        assertSearchMessageRejected("ids built from constants", activity, constantIds)
        // A comment naming a forbidden call is not a reference.
        assertSearchMessageWiring(activity, core.replace(
            "JamiService.loadSybLMessage(account, conversation, messageId)",
            "JamiService.loadSybLMessage(account, conversation, messageId) // never setMessageDisplayed or snippet"))
    }

    private val retireHistorySearchText = """
        fun retireHistorySearch(scope: NativeAccountScope?) {
            if (!accountAuthority.owns(scope)) return
            historySearchEpoch.incrementAndGet()
            historySearchEntry?.takeIf { it.owner == scope }?.request?.retire()
        }
    """

    private val onRetiredWiringText = """
        private val conversationLoads = ConversationLoadRegistry(
            onRetired = { (it as? SearchMessageConversationLoad)?.answer(null) },
        )
    """

    /** Retirement advances the epoch only: a selected-message load keeps its lease until the daemon answers. */
    private fun assertSearchLeaseHeld(core: String) {
        val stripped = stripComments(core)
        val retire = functionText(stripped, "retireHistorySearch")
        assertEquals("retireHistorySearch text", normalized(retireHistorySearchText), normalized(retire))
        for (release in listOf("conversationLoads", "answer(", "retireMatching", "clearActive", "removePeer",
                "SearchMessageConversationLoad", "reply(")) {
            assertFalse("retireHistorySearch releases a selected-message load via $release", retire.contains(release))
        }
        assertEquals("one conversationLoads registry", 1, Regex("ConversationLoadRegistry\\(").findAll(stripped).count())
        val registry = between(stripped, "private val conversationLoads = ConversationLoadRegistry(", "\n    )\n")
        assertEquals("onRetired wiring", normalized(onRetiredWiringText), normalized("$registry\n)"))
    }

    @Test
    fun `retirement keeps the selected-message scan lease until native completion`() {
        val core = File("src/main/kotlin/app/sybl/sybl/JamiCore.kt").readText().replace("\r\n", "\n")
        assertSearchLeaseHeld(core)
        val start = core.indexOf("    internal fun retireHistorySearch(")
        val end = core.indexOf("\n    }\n", start) + "\n    }\n".length
        assertTrue(start >= 0 && end > start)
        val withRetire = { body: String -> core.replaceRange(start, end, body) }
        val preChange = """
            |    internal fun retireHistorySearch(scope: NativeAccountScope?) {
            |        if (!accountAuthority.owns(scope)) return
            |        historySearchEpoch.incrementAndGet()
            |        historySearchEntry?.takeIf { it.owner == scope }?.request?.retire()
            |        conversationLoads.retireMatching { it is SearchMessageConversationLoad && it.owner == scope }
            |    }
            |""".trimMargin()
        val rejected = { label: String, mutant: String ->
            assertTrue("$label did not apply", mutant != core)
            val failed = try { assertSearchLeaseHeld(mutant); false } catch (_: AssertionError) { true }
            assertTrue("$label passed the lease check", failed)
        }
        rejected("pre-change retirement", withRetire(preChange))
        rejected("clear on retirement", withRetire(preChange.replace(
            "conversationLoads.retireMatching { it is SearchMessageConversationLoad && it.owner == scope }",
            "conversationLoads.clearActive()")))
        rejected("onRetired no longer answers", core.replace(
            "onRetired = { (it as? SearchMessageConversationLoad)?.answer(null) },", "onRetired = {},"))
        rejected("onRetired answers content", core.replace(
            "onRetired = { (it as? SearchMessageConversationLoad)?.answer(null) },",
            "onRetired = { (it as? SearchMessageConversationLoad)?.answer(emptyMap()) },"))
        // A release named only in a comment is not a call.
        assertSearchLeaseHeld(withRetire(preChange.replace(
            "conversationLoads.retireMatching { it is SearchMessageConversationLoad && it.owner == scope }",
            "// conversationLoads.retireMatching { it is SearchMessageConversationLoad }")))
    }
}
