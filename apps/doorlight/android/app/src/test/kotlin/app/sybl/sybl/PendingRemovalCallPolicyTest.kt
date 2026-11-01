package app.sybl.sybl

import android.content.SharedPreferences
import java.lang.reflect.Proxy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class PendingRemovalCallPolicyTest {
    private val peer = "b".repeat(40)
    private val other = "c".repeat(40)
    private var document: Any? = null
    private var readFailure = false
    private val preferences = Proxy.newProxyInstance(
        SharedPreferences::class.java.classLoader, arrayOf(SharedPreferences::class.java),
    ) { _, method, arguments ->
        check(method.name == "getString")
        check(arguments!![0] == PendingRemovalCallPolicy.KEY)
        if (readFailure) error("synthetic read failure")
        document as String?
    } as SharedPreferences
    private val policy = PendingRemovalCallPolicy(preferences)
    private fun routing(conversation: String? = "conversation") = RoutingSnapshot(
        accountId = "account", selfId = "a".repeat(40), revision = 1,
        friends = mapOf(peer to FriendRoute(peer, true, conversation, setOfNotNull(conversation))),
        groups = emptyMap(), peerByConversation = emptyMap(),
    )
    private fun marker(account: String = "account", from: String = peer, conversation: String = "conversation") =
        JSONObject().put("accountId", account).put("peerId", from)
            .put("conversationId", conversation).put("deadlineMs", 1L)
    private fun save(vararg entries: JSONObject) { document = JSONArray(entries.toList()).toString() }
    private fun allows(conversation: String? = "conversation", from: String = peer, account: String = "account") =
        policy.allows(account, from, routing(conversation))

    @Test fun absentAndEmptyPreserveTrustedCalls() {
        assertTrue(allows())
        document = "[]"
        assertTrue(allows())
        assertFalse(allows(from = other))
        assertFalse(allows(account = "other-account"))
    }
    @Test fun matchingRemovalNeverExpires() { save(marker()); assertFalse(allows()) }
    @Test fun authenticatedPeerAliasesCannotBypassRemoval() {
        save(marker())
        assertFalse(allows(from = "jami:${peer.uppercase()}@device"))
    }
    @Test fun unrelatedAccountAndPeerRemainAllowed() {
        save(marker(account = "other"), marker(from = other)); assertTrue(allows())
    }
    @Test fun readdedConversationRemainsAllowed() { save(marker(conversation = "old")); assertTrue(allows()) }
    @Test fun unknownCanonicalConversationCannotEstablishReadd() {
        save(marker(conversation = "old")); assertFalse(allows(conversation = null))
    }
    @Test fun emptyConversationIsExactNotWildcard() {
        save(marker(conversation = ""))
        assertTrue(allows())
        assertFalse(allows(conversation = ""))
    }
    @Test fun malformedAndAmbiguousDocumentsDeny() {
        val good = marker().toString()
        for (bad in listOf("", "null", "{}", "[null]", "[$good] trailing", "[$good,]",
            "[$good,$good]", "[{\"accountId\":\"other\",\"accountId\":\"account\"}]",
            "[{'accountId':'account'}]", "[/*comment*/$good]", " ".repeat(65537))) {
            document = bad
            assertFalse("Accepted invalid removal state", allows())
        }
    }
    @Test fun invalidFieldsDenyEvenWhenForAnotherAccount() {
        for (key in listOf("accountId", "peerId", "conversationId", "deadlineMs")) {
            val value = marker(account = "other"); value.remove(key); save(value); assertFalse(allows())
        }
        for (value in listOf(1.5, "1", JSONObject.NULL, true)) {
            save(marker().put("deadlineMs", value)); assertFalse(allows())
        }
        for (value in listOf(7, "x".repeat(129))) {
            save(marker().put("noticeCommitId", value)); assertFalse(allows())
        }
        save(marker(from = "jami:$peer")); assertFalse(allows())
        save(marker(account = "")); assertFalse(allows())
    }
    @Test fun optionalNoticeAndLongDeadlineAreValid() {
        save(marker(account = "other").put("noticeCommitId", JSONObject.NULL).put("deadlineMs", Long.MAX_VALUE))
        assertTrue(allows())
        save(marker(account = "other").put("noticeCommitId", "notice")); assertTrue(allows())
    }
    @Test fun boundedListRejectsOverflow() {
        document = JSONArray((0..64).map { marker(account = "account-$it") }).toString()
        assertFalse(allows())
        document = JSONArray((0..63).map { marker(account = "account-$it") }).toString()
        assertTrue(allows())
    }
    @Test fun wrongStoredTypeAndReadFailureDeny() {
        document = false; assertFalse(allows())
        document = null; readFailure = true; assertFalse(allows())
    }
    @Test fun byteBoundAndNestedInputDeny() {
        document = JSONArray(listOf(marker(account = "other").put("extra", "é".repeat(33000)))).toString()
        assertFalse(allows())
        document = "[".repeat(22) + "0" + "]".repeat(22); assertFalse(allows())
    }

    private fun answer(
        calls: IncomingCallRegistry,
        prepare: () -> Boolean = { true },
        submitted: (PendingIncomingCall) -> Boolean,
    ) = answerRetainedIncomingCall("call", "account", calls,
        allowed = { account, from -> policy.allows(account, from, routing()) }, prepare = prepare,
        denied = { calls.remove("call") }, submit = submitted)
    private fun calls() = IncomingCallRegistry().apply { put("call", "account", peer, listOf(mapOf("video" to "off"))) }

    @Test fun ordinaryAnswerPreservesAuthenticatedOffer() {
        val calls = calls(); val expected = calls["call"]
        assertTrue(answer(calls) { assertSame(expected, it); true })
    }
    @Test fun ringThenRemovalDeniesAndRetiresAnswer() {
        val calls = calls(); save(marker())
        assertFalse(answer(calls, prepare = { fail("Must not prepare a revoked Answer"); true }) {
            fail("Must not submit a revoked Answer"); true
        })
        assertNull(calls["call"])
    }
    @Test fun removalDuringRecorderStopDeniesSubmission() {
        val calls = calls()
        assertFalse(answer(calls, prepare = { save(marker()); true }) { fail("Late revocation bypass"); true })
        assertNull(calls["call"])
    }
    @Test fun missingAndChangedRingOwnershipNeverSubmit() {
        assertFalse(answer(IncomingCallRegistry()) { fail("Missing ring bypass"); true })
        val calls = calls()
        assertFalse(answer(calls, prepare = { calls.put("call", "account", peer, emptyList()); true }) {
            fail("Replaced ring bypass"); true
        })
        calls.put("call", "other-account", peer, emptyList())
        assertFalse(answer(calls) { fail("Account bypass"); true })
    }
    @Test fun failedPreparationAndSubmissionPropagate() {
        assertFalse(answer(calls(), prepare = { false }) { fail("Failed preparation bypass"); true })
        assertFalse(answer(calls()) { false })
    }
    @Test fun changedOwnershipDuringPolicyReadCannotSubmit() {
        val calls = calls()
        assertFalse(answerRetainedIncomingCall("call", "account", calls,
            allowed = { _, _ -> calls.put("call", "account", peer, emptyList()); true },
            prepare = { fail("Replaced ownership must not prepare"); true },
            submit = { fail("Replaced ownership must not submit"); true }))
    }
}
