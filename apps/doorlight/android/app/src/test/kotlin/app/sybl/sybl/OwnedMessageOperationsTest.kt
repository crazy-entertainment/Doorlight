package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class OwnedMessageOperationsTest {
    @Test fun `unknown callbacks retain correlation for late commitment`() {
        val registry = OwnedMessageOperations()
        val operation = OwnedMessageOperation(NativeAccountScope("account", Any()), "peer", "conversation", "a".repeat(32))
        assertTrue(registry.begin(operation))
        assertEquals(operation, registry.complete("account", "conversation", operation.operationId, false))
        assertFalse(registry.begin(operation))
        assertEquals(operation, registry.complete("account", "conversation", operation.operationId))
        assertNull(registry.complete("account", "conversation", operation.operationId))
    }
    @Test fun `callbacks require exact account conversation and operation`() {
        val registry = OwnedMessageOperations()
        val scope = NativeAccountScope("account-a", Any())
        val operation = OwnedMessageOperation(scope, "peer", "conversation", "a".repeat(32))
        assertTrue(registry.begin(operation))
        assertFalse(registry.begin(operation))
        assertNull(registry.complete("account-b", "conversation", operation.operationId))
        assertNull(registry.complete("account-a", "other", operation.operationId))
        assertEquals(operation, registry.complete("account-a", "conversation", operation.operationId))
        assertNull(registry.complete("account-a", "conversation", operation.operationId))
        assertFalse(registry.begin(operation))
    }

    @Test fun `pending operations are bounded without evicting unresolved work`() {
        val registry = OwnedMessageOperations()
        val scope = NativeAccountScope("account", Any())
        for (index in 0 until 256) assertTrue(registry.begin(OwnedMessageOperation(
            scope, "peer", "conversation", index.toString(16).padStart(32, '0'))))
        assertFalse(registry.begin(OwnedMessageOperation(scope, "peer", "conversation", "f".repeat(32))))
        assertNotNull(registry.complete("account", "conversation", "0".repeat(32)))
        assertTrue(registry.begin(OwnedMessageOperation(scope, "peer", "conversation", "f".repeat(32))))
    }
}
