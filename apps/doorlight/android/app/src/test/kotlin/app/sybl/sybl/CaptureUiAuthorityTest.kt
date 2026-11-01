package app.sybl.sybl

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureUiAuthorityTest {
    @Test fun headlessAndReplacementUiCannotInheritPendingCapture() {
        val authority = CaptureUiAuthority()
        assertFalse(authority.owns(authority.capture()))
        authority.attach()
        val first = authority.capture()
        assertTrue(authority.owns(first))
        authority.detach()
        assertFalse(authority.owns(first))
        authority.attach()
        assertFalse(authority.owns(first))
        assertTrue(authority.owns(authority.capture()))
    }
}
