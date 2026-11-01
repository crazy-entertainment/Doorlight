package app.sybl.sybl

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class IncomingCallMicrophonePolicyTest {
    private val account = "local-account"
    private val peer = "b".repeat(40)
    private val conversation = "direct-conversation"

    private class Preferences {
        val values = mutableMapOf<String, Any>()
        val reads = mutableListOf<String>()
        var failure: Throwable? = null
        var commitResult = true
        var commitFailure: Throwable? = null
        var duringCommit: (() -> Unit)? = null
        val native = Proxy.newProxyInstance(
            SharedPreferences::class.java.classLoader,
            arrayOf(SharedPreferences::class.java),
        ) { _, method, arguments ->
            when (method.name) {
                "getString" -> {
                    val key = arguments!![0] as String
                    reads += key
                    failure?.let { throw it }
                    values[key]?.let { it as String } ?: arguments[1]
                }
                "edit" -> editor()
                else -> error("Unexpected preference operation: ${method.name}")
            }
        } as SharedPreferences

        private fun editor(): SharedPreferences.Editor {
            val writes = mutableMapOf<String, String>()
            lateinit var editor: SharedPreferences.Editor
            editor = Proxy.newProxyInstance(
                SharedPreferences.Editor::class.java.classLoader,
                arrayOf(SharedPreferences.Editor::class.java),
            ) { _, method, arguments ->
                when (method.name) {
                    "putString" -> {
                        writes[arguments!![0] as String] = arguments[1] as String
                        editor
                    }
                    "commit" -> {
                        // Android commits to its process map before it knows the disk result.
                        values.putAll(writes)
                        duringCommit?.invoke()
                        commitFailure?.let { throw it }
                        commitResult
                    }
                    else -> error("Unexpected preference editor operation: ${method.name}")
                }
            } as SharedPreferences.Editor
            return editor
        }
    }

    private fun settings(mode: String = "open", overrides: List<JSONObject> = emptyList()): String =
        JSONObject().put("schemaVersion", 14).put(
            "microphone",
            JSONObject().put("globalDefault", mode).put("conversationOverrides", JSONArray(overrides)),
        ).toString()

    private fun scopedMode(
        mode: String = "pushToTalk",
        owner: String = account,
        from: String = peer,
        conversationId: String = conversation,
        kind: String = "direct",
    ): JSONObject = JSONObject()
        .put("accountId", owner).put("peerId", from).put("conversationId", conversationId)
        .put("kind", kind).put("mode", mode)

    private inner class Call {
        val preferences = Preferences()
        val store = CanonicalIncomingCallMicrophonePolicy(preferences.native)
        val registry = IncomingCallRegistry().apply { put("ring", account, peer, emptyList()) }
        var activeAccount: String? = account
        var restorePending = false
        var routing = RoutingSnapshot(
            account, "a".repeat(40), 1,
            mapOf(peer to FriendRoute(peer, true, conversation, setOf(conversation))),
            emptyMap(), mapOf(conversation to peer),
        )
        val answers = mutableListOf<Pair<String, Boolean>>()
        var answerResult = true

        fun save(document: String): Boolean = store.prepareSave(document)()

        fun answer(): Boolean = answerNotificationWithMicrophonePolicy(
            "ring", activeAccount, registry, routing, store::load, restorePending,
        ) { callId, muted ->
            answers += callId to muted
            answerResult
        }
    }

    @Test
    fun profileColorSchemaKeepsMicrophoneChoicesAndRejectsFutureSchemas() {
        for (version in listOf(17, 18, 19, 20, 21, 22, 23)) {
            val value = JSONObject(settings("pushToTalk", listOf(scopedMode("open"))))
                .put("schemaVersion", version)
                .put("notifications", JSONObject().put("hologramPresentationEnabled", true)
                    .put("messageAlertsEnabled", true))
                .put("friendPreferences", JSONObject().put("reviewRequired", false)
                    .put("overrides", JSONArray()))
            value.getJSONObject("microphone").put("reviewRequired", false)
            val policy = IncomingCallMicrophonePolicy.decode(value.toString())
            if (version == 23) {
                assertEquals(null, policy)
            } else {
                assertFalse(policy!!.initialAudioMuted(account, peer, conversation))
                assertTrue(policy.initialAudioMuted(account, peer, "another-conversation"))
            }
        }
    }

    @Test
    fun openNotificationAnswerNeedsNoFlutterOrUnlockedSurface() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        call.preferences.values["flutter.appLockEnabled.v1"] = true
        assertTrue(call.answer())
        assertEquals(listOf("ring" to false), call.answers)
        assertEquals(listOf("flutter.appSettings"), call.preferences.reads)
    }

    @Test
    fun globalAndExactConversationPttStartMuted() {
        for (document in listOf(settings("pushToTalk"), settings(overrides = listOf(scopedMode())))) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = document
            assertTrue(call.answer())
            assertEquals(listOf("ring" to true), call.answers)
        }
    }

    @Test
    fun overridesUseAllNativeScopeFieldsAndCanSelectOpen() {
        for (unrelated in listOf(
            scopedMode(owner = "another-account"), scopedMode(from = "c".repeat(40)),
            scopedMode(conversationId = "another-conversation"), scopedMode(kind = "group"),
        )) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = settings(overrides = listOf(unrelated))
            assertTrue(call.answer())
            assertEquals(listOf("ring" to false), call.answers)
        }
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings("pushToTalk", listOf(scopedMode("open")))
        assertTrue(call.answer())
        assertEquals(listOf("ring" to false), call.answers)
    }

    @Test
    fun missingOrReplacedNativeCallOwnershipCannotAnswer() {
        for (replace in listOf<(Call) -> Unit>(
            { it.registry.remove("ring") },
            { it.registry.put("ring", "another-account", peer, emptyList()) },
            { it.activeAccount = null },
            { it.routing = it.routing.copy(accountId = "another-account") },
            { it.routing = it.routing.copy(friends = emptyMap()) },
        )) {
            val call = Call()
            replace(call)
            assertFalse(call.answer())
            assertTrue(call.answers.isEmpty())
            assertTrue(call.preferences.reads.isEmpty())
        }
    }

    @Test
    fun failedOrMalformedCanonicalReadCannotOpenTheMicrophone() {
        for (invalid in listOf<Any>(
            "", "{", "null", "[]", true,
            settings().replace("\"schemaVersion\":14", "\"schemaVersion\":15"),
            settings().replace("\"schemaVersion\":14", "\"schemaVersion\":\"14\""),
            settings("future-mode"),
            settings(overrides = listOf(scopedMode(), scopedMode())),
            settings(overrides = listOf(scopedMode(owner = ""))),
            settings(overrides = listOf(scopedMode(kind = "unknown"))),
            " ".repeat(65_537),
        )) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = invalid
            assertTrue(call.answer())
            assertEquals(listOf("ring" to true), call.answers)
            assertEquals(listOf("flutter.appSettings"), call.preferences.reads)
        }
        val call = Call()
        call.preferences.failure = IllegalStateException("synthetic read failure")
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true), call.answers)
    }

    @Test
    fun absentDocumentIsUnknownUntilSetupSavesAnExplicitDefault() {
        val call = Call()
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true), call.answers)
        assertEquals(listOf("flutter.appSettings"), call.preferences.reads)
    }

    @Test
    fun restoredUnknownOwnerPolicyIsDurableAndCannotOpenNotificationAnswer() {
        val call = Call()
        val document = JSONObject(settings(overrides = listOf(scopedMode(owner = "backup-owner"))))
            .put("schemaVersion", 15).apply {
                getJSONObject("microphone").put("reviewRequired", true)
            }.toString()
        assertTrue("A valid review-required policy must be saved, not discarded", call.save(document))
        assertEquals(document, call.preferences.values["flutter.appSettings"])
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true), call.answers)
        assertTrue(call.save(JSONObject(document).apply {
            getJSONObject("microphone").put("reviewRequired", false)
        }.toString()))
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true, "ring" to false), call.answers)
    }

    @Test
    fun schema15KnownPolicyKeepsExactRestoredPttAndOrdinaryOpen() {
        for ((overrides, expectedMuted) in listOf(
            emptyList<JSONObject>() to false,
            listOf(scopedMode()) to true,
        )) {
            val call = Call()
            val document = JSONObject(settings(overrides = overrides)).put("schemaVersion", 15).apply {
                getJSONObject("microphone").put("reviewRequired", false)
            }.toString()
            assertTrue(call.save(document))
            assertTrue(call.answer())
            assertEquals(listOf("ring" to expectedMuted), call.answers)
        }
    }

    private fun restoredSettings(reviewRequired: Boolean = false): String =
        JSONObject(settings(overrides = listOf(scopedMode()))).put("schemaVersion", 16).apply {
            getJSONObject("microphone").put("reviewRequired", reviewRequired)
            put("appLock", JSONObject().put("enabled", true))
            put("notifications", JSONObject().put("showMessage", false).put("hologramPresentationEnabled", true))
        }.toString()

    @Test
    fun restoreInstallsCanonicalAndNotificationPrivacyBeforeActivationAndAnswer() {
        val call = Call()
        val document = restoredSettings()
        val effects = mutableListOf<String>()
        val saved = call.store.prepareSave(document)
        assertTrue(commitRestoredPrivacy(document, true,
            { effects += "canonical"; saved() },
            { preview, locked ->
                assertFalse(preview)
                assertTrue(locked)
                effects += "notification"
                true
            },
        ) {
            call.store.withCurrentDocument(document) {
                effects += "activate"
                call.answer()
            }
        })
        assertEquals(listOf("canonical", "notification", "activate"), effects)
        assertEquals(listOf("ring" to true), call.answers)
    }

    @Test
    fun pendingRestoreBlocksOldAccountNotificationAnswerEvenAfterPartialOpenCommit() {
        val call = Call()
        call.restorePending = true
        assertTrue(call.save(settings()))
        assertFalse(call.answer())
        assertTrue(call.answers.isEmpty())
        call.restorePending = false
        assertTrue(call.answer())
        assertEquals(listOf("ring" to false), call.answers)
    }

    @Test
    fun failedPrivacyWritesOrChangedRevisionCannotActivateRestoredAccount() {
        for (failure in listOf("canonical", "notification", "newer-write", "lock", "missing-lock")) {
            val call = Call()
            val document = restoredSettings()
            call.preferences.commitResult = failure != "canonical"
            var activated = false
            val saved = call.store.prepareSave(document)
            assertFalse(failure, commitRestoredPrivacy(document,
                when (failure) { "lock" -> false; "missing-lock" -> null; else -> true },
                saved,
                { _, _ ->
                    if (failure == "newer-write") call.store.prepareSave(restoredSettings(true))
                    failure != "notification"
                },
            ) {
                call.store.withCurrentDocument(document) { activated = true; true }
            })
            assertFalse(failure, activated)
        }
    }

    @Test
    fun nonJsonSyntaxCannotTurnAnInvalidPolicyIntoOpen() {
        for (invalid in listOf(
            settings().replace('"', '\''),
            settings().replace("\"schemaVersion\"", "schemaVersion"),
            settings().replace("{", "{/* comment */"),
            settings().replace("{", "{# comment\n"),
            settings().replace(":", "="),
            settings().replace(",", ";"),
            settings().dropLast(1) + ",}",
            settings().replace("[]", "[,]"),
            settings().dropLast(1) + ",\"extra\":01}",
            settings().dropLast(1) + ",\"extra\":NaN}",
            settings().dropLast(1) + ",\"extra\":\"raw\nline\"}",
            settings().dropLast(1) + ",\"extra\":\"\\x41\"}",
            settings() + " false",
            "\u000b" + settings(),
            settings().dropLast(1) + ",\"schemaVersion\":14}",
        )) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = invalid
            assertTrue(call.answer())
            assertEquals(invalid, listOf("ring" to true), call.answers)
        }
    }

    @Test
    fun grammarCheckSupportsCanonicalJsonAndBoundsUnknownFieldDepth() {
        val valid = settings().dropLast(1) +
            ",\"extra\":{\"escaped\\u004bey\":[null,true,false,-1.25e+2,\"quote\\\" slash\\\\ tab\\t unicode\\u263a\"]}}"
        val call = Call()
        call.preferences.values["flutter.appSettings"] = valid
        assertTrue(call.answer())
        assertEquals(listOf("ring" to false), call.answers)

        val deep = Call()
        deep.preferences.values["flutter.appSettings"] = settings().dropLast(1) +
            ",\"extra\":" + "[".repeat(19_000) + "0" + "]".repeat(19_000) + "}"
        assertTrue(deep.answer())
        assertEquals(listOf("ring" to true), deep.answers)
    }

    @Test
    fun existingDocumentVersionsAndLegacyVoiceActivationMatchDart() {
        for ((document, expectedMuted) in listOf(
            "{\"microphoneMode\":\"ptt\"}" to true,
            "{\"schemaVersion\":1,\"microphoneMode\":\"open\"}" to false,
            "{\"schemaVersion\":null,\"microphoneMode\":\"open\"}" to false,
            settings("pushToTalk").replace("\"schemaVersion\":14", "\"schemaVersion\":2") to true,
            settings("voiceActivated") to false,
        )) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = document
            assertTrue(call.answer())
            assertEquals(listOf("ring" to expectedMuted), call.answers)
        }
    }

    @Test
    fun queuedAnswerReadsCommittedPolicyWhenItExecutesAndPreservesDaemonFailure() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        val queuedWorkerAction = call::answer
        call.preferences.values["flutter.appSettings"] = settings("pushToTalk")
        call.answerResult = false
        assertFalse(queuedWorkerAction())
        assertEquals(listOf("ring" to true), call.answers)
    }

    @Test
    fun falseOrThrowingCommitCannotExposeTheUnsavedOpenCache() {
        for (throws in listOf(false, true)) {
            val call = Call()
            call.preferences.values["flutter.appSettings"] = settings("pushToTalk")
            call.preferences.commitResult = false
            if (throws) call.preferences.commitFailure = IllegalStateException("synthetic disk failure")
            assertFalse(call.save(settings()))
            assertEquals(settings(), call.preferences.values["flutter.appSettings"])
            assertTrue(call.answer())
            assertEquals(listOf("ring" to true), call.answers)
        }
    }

    @Test
    fun writeGuardStartsBeforeCacheMutationAndClearsOnlyAfterCommitSuccess() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        call.preferences.duringCommit = { assertTrue(call.answer()) }
        assertTrue(call.save(settings()))
        assertEquals(listOf("ring" to true), call.answers)
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true, "ring" to false), call.answers)
    }

    @Test
    fun invalidWriteKeepsTheGuardUntilAValidCanonicalSaveRecovers() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        assertFalse(call.save("invalid"))
        assertEquals(settings(), call.preferences.values["flutter.appSettings"])
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true), call.answers)
        assertTrue(call.save(settings("pushToTalk")))
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true, "ring" to true), call.answers)
        assertTrue(call.save(settings()))
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true, "ring" to true, "ring" to false), call.answers)
        assertEquals(setOf("flutter.appSettings"), call.preferences.values.keys)
    }

    @Test
    fun admissionGuardsQueuedAnswersAndOldCompletionsCannotClearNewerWrites() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        val queue = java.util.ArrayDeque<Runnable>()
        val worker = ObservedSerialExecutor(
            java.util.concurrent.Executor { queue.addLast(it) },
            DiagnosticTaskTracker("synthetic"), { false }, { 0L },
        )
        worker.execute(DaemonOperation.GENERIC) { assertTrue(call.answer()) }
        val firstSave = call.store.prepareSave(settings())
        worker.execute(DaemonOperation.GENERIC) { assertTrue(firstSave()) }
        worker.execute(DaemonOperation.GENERIC) { assertTrue(call.answer()) }
        val secondSave = call.store.prepareSave(settings("pushToTalk"))
        worker.execute(DaemonOperation.GENERIC) { assertTrue(secondSave()) }
        worker.execute(DaemonOperation.GENERIC) { assertTrue(call.answer()) }
        while (queue.isNotEmpty()) queue.removeFirst().run()
        assertEquals(listOf("ring" to true, "ring" to true, "ring" to true), call.answers)
        assertEquals(settings("pushToTalk"), call.preferences.values["flutter.appSettings"])
    }

    @Test
    fun staleOrRepeatedWriteCannotReplaceTheLatestCompletedCanonicalDocument() {
        val call = Call()
        val old = call.store.prepareSave(settings())
        val latest = call.store.prepareSave(settings("pushToTalk"))
        assertTrue(latest())
        assertFalse(old())
        assertFalse(latest())
        assertEquals(settings("pushToTalk"), call.preferences.values["flutter.appSettings"])
        assertTrue(call.answer())
        assertEquals(listOf("ring" to true), call.answers)
    }

    @Test
    fun activationCannotReadAPendingOrUnacknowledgedCanonicalWrite() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        assertEquals(settings(), call.store.currentDocument())
        val save = call.store.prepareSave(settings("pushToTalk"))
        assertEquals(null, call.store.currentDocument())
        assertTrue(save())
        assertEquals(settings("pushToTalk"), call.store.currentDocument())
        call.store.prepareSave(settings())
        assertFalse(call.store.withCurrentDocument(settings("pushToTalk")) { error("pending policy activated") })
    }

    @Test
    fun registryRemovalDuringPolicyReadCannotAnswerTheRetiredRing() {
        val call = Call()
        val answered = answerNotificationWithMicrophonePolicy(
            "ring", account, call.registry, call.routing,
            readPolicy = { call.registry.remove("ring"); call.store.load() },
        ) { _, _ -> error("retired ring reached answer") }
        assertFalse(answered)
    }

    @Test
    fun saveAdmittedAfterPolicyReadCannotAnswerWithTheOldOpenPolicy() {
        val call = Call()
        call.preferences.values["flutter.appSettings"] = settings()
        val answered = answerNotificationWithMicrophonePolicy(
            "ring", account, call.registry, call.routing,
            readPolicy = {
                val previous = call.store.load()
                call.store.prepareSave(settings("pushToTalk"))
                previous
            },
        ) { callId, muted ->
            call.answers += callId to muted
            true
        }
        assertTrue(answered)
        assertEquals(listOf("ring" to true), call.answers)
    }
}
