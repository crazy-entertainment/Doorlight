package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class NativeAccountAuthorityTest {
    @Test fun `queued profile and offline commands cannot target an account selected again later`() {
        val authority = NativeAccountAuthority()
        authority.select("a")
        val scope = authority.capture("a")
        var nativeCalls = 0
        val queued = { authority.invoke(scope) { nativeCalls += 1 } }
        authority.select("b")
        authority.select("a")
        assertFalse(queued())
        assertEquals(0, nativeCalls)
        assertTrue(authority.invoke(authority.capture("a")) { nativeCalls += 1 })
        assertEquals(1, nativeCalls)
    }

    @Test fun `expected owner mismatch is rejected while same owner selection preserves a command`() {
        val authority = NativeAccountAuthority()
        authority.select("a")
        assertNull(authority.capture("b"))
        val scope = authority.capture("a")
        authority.select("a")
        assertTrue(authority.invoke(scope) {})
    }
}
