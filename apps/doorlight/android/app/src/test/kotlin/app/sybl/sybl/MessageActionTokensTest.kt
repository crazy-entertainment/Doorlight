package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class MessageActionTokensTest {
    private var sequence = 0
    private fun registry() = MessageActionTokens { (++sequence).toString(16).padStart(64, '0') }
    private fun owner(scope: NativeAccountScope, conversation: String = "conversation", topic: String = "main") =
        MessageActionOwner(scope, "identity", "peer", conversation, topic)

    @Test fun staleIdentityAndTopicCannotReuseAnIntent() {
        val account = NativeAccountAuthority().apply { select("A") }
        val tokens = registry()
        val first = owner(account.capture()!!)
        val token = tokens.issue(first)!!
        account.select("B")
        account.select("A")
        assertFalse(account.owns(tokens.resolve(token)?.account))
        val replacement = owner(account.capture()!!, topic = "topic-2")
        val next = tokens.issue(replacement)!!
        assertNull(tokens.resolve(token))
        assertFalse(tokens.consume(next, first))
        assertTrue(tokens.consume(next, replacement))
        assertFalse(tokens.consume(next, replacement))
    }

    @Test fun admissionDoesNotSurviveTrustOrRestoreRetirement() {
        val account = NativeAccountAuthority().apply { select("A") }
        val tokens = registry()
        val token = tokens.issue(owner(account.capture()!!))!!
        val admitted = tokens.resolve(token)!!
        tokens.clear()
        assertFalse(tokens.consume(token, admitted))
        assertNull(registry().resolve(token))
    }

    @Test fun boundedAdmissionNeverEvictsAnotherConversation() {
        val scope = NativeAccountScope("A", Any())
        val tokens = registry()
        val first = tokens.issue(owner(scope, "first"))!!
        repeat(127) { assertNotNull(tokens.issue(owner(scope, "conversation-$it"))) }
        assertNull(tokens.issue(owner(scope, "overflow")))
        assertNotNull(tokens.resolve(first))
        tokens.retireConversation("first")
        assertNull(tokens.resolve(first))
        assertNotNull(tokens.issue(owner(scope, "overflow")))
    }
}
